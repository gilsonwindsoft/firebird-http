unit fbhttp.Transport;

{ HTTP transport to the gateway: one THTTPClient (WinHTTP on Windows) per
  attachment, sequence numbers, retry with the same seq, keep-alive ping,
  request counters and the diagnostic log (FBHTTP_DEBUG_LOG). ASCII only. }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Net.HttpClient,
  System.Net.URLClient, System.NetConsts, fbhttp.Config, fbhttp.Protocol;

type
  // Network counters. Size lets callers of ws_fbclient_stats version the record.
  TWsFbStats = record
    Size: Cardinal;
    Requests: Int64;   // HTTP requests sent (rpc and ping), including retries
    NetMs: Int64;      // time waiting for the gateway, in milliseconds
    BytesOut: Int64;   // request bodies
    BytesIn: Int64;    // response bodies as received (before gunzip)
  end;
  PWsFbStats = ^TWsFbStats;

  TFbTransport = class
  private
    FConfig: TFbHttpConfig;
    FClient: THTTPClient;
    FPingClient: THTTPClient;
    FLock: TCriticalSection;
    FToken: string;
    FSeq: Cardinal;
    FLastActivity: UInt64;
    FStats: TWsFbStats;
    function NewClient: THTTPClient;
    procedure ValidateCertificate(const Sender: TObject; const ARequest: TURLRequest;
      const Certificate: TCertificate; var Accepted: Boolean);
    procedure Count(Requests, Ms, BytesOut, BytesIn: Int64);
    function Post(const Body: TBytes; const OpsText: string): TBytes;
  public
    constructor Create(const Config: TFbHttpConfig);
    destructor Destroy; override;
    // ATTACH (seq 1, no session). Returns the result payload or raises.
    function Attach(const Op: TFbOp): TBytes;
    // Sends a batch and returns every result the gateway produced (it stops
    // after the first failed non-deferred op). Raises only EFbTransport.
    function CallRaw(const Ops: array of TFbOp): TFbResults;
    // Sends a batch. Raises EFbTransport on network failure and EFbRemote
    // for the first failed non-deferred operation. Results of deferred
    // operations that failed are dropped.
    function Call(const Ops: array of TFbOp): TFbResults;
    // Sends one operation and returns a reader over its result.
    function CallOne(const Op: TFbOp): TFbReader;
    // POST /v1/ping. False when the session no longer exists.
    function Ping: Boolean;
    function IdleSeconds: Int64;
    function IdleMs: Int64;
    property Config: TFbHttpConfig read FConfig;
    // Session token returned by ATTACH.
    property Token: string read FToken write FToken;
    // Counters of this attachment (read under the attachment lock).
    property Stats: TWsFbStats read FStats;
  end;

// gzip body (Content-Encoding: gzip from the gateway) to raw bytes.
function Gunzip(const B: TBytes): TBytes;
// Process-wide counters, summed over every transport.
function GlobalStats: TWsFbStats;
// Optional diagnostics: FBHTTP_DEBUG_LOG=<file>. Never logs SQL, data or passwords.
procedure DebugLog(const Msg: string);
// "20,22" for a batch of PREPARE and EXECUTE.
function OpList(const Ops: array of TFbOp): string;

implementation

uses
  Winapi.Windows, System.ZLib, fbhttp.IBase, fbhttp.Status;

const
  CONTENT_TYPE = 'application/x-fbhttp';
  MAX_RETRIES = 2;

var
  GDebugPath: string;
  GDebugLock: TCriticalSection;
  GStats: TWsFbStats;
  GStatsLock: TCriticalSection;

procedure DebugLog(const Msg: string);
var
  f: TextFile;
begin
  if GDebugPath = '' then
    Exit;
  GDebugLock.Enter;
  try
    AssignFile(f, GDebugPath);
    if FileExists(GDebugPath) then
      Append(f)
    else
      Rewrite(f);
    try
      Writeln(f, FormatDateTime('hh:nn:ss.zzz', Now), ' t', TThread.CurrentThread.ThreadID, ' ', Msg);
    finally
      CloseFile(f);
    end;
  except
  end;
  GDebugLock.Leave;
end;

function OpList(const Ops: array of TFbOp): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Ops) do
  begin
    if i > 0 then
      Result := Result + ',';
    Result := Result + IntToStr(Ops[i].Code);
    if Ops[i].Flags and FLAG_DEFERRED <> 0 then
      Result := Result + 'd';
  end;
end;

function GlobalStats: TWsFbStats;
begin
  GStatsLock.Enter;
  try
    Result := GStats;
  finally
    GStatsLock.Leave;
  end;
end;

procedure TFbTransport.Count(Requests, Ms, BytesOut, BytesIn: Int64);
begin
  // FStats is only touched by the thread holding the attachment lock (Post)
  // or by the keep-alive thread (Ping), so only the global copy needs a lock.
  Inc(FStats.Requests, Requests);
  Inc(FStats.NetMs, Ms);
  Inc(FStats.BytesOut, BytesOut);
  Inc(FStats.BytesIn, BytesIn);
  GStatsLock.Enter;
  try
    Inc(GStats.Requests, Requests);
    Inc(GStats.NetMs, Ms);
    Inc(GStats.BytesOut, BytesOut);
    Inc(GStats.BytesIn, BytesIn);
  finally
    GStatsLock.Leave;
  end;
end;

constructor TFbTransport.Create(const Config: TFbHttpConfig);
begin
  FConfig := Config;
  FLock := TCriticalSection.Create;
  FClient := NewClient;
  FPingClient := NewClient;
  FLastActivity := GetTickCount64;
  FStats.Size := SizeOf(FStats);
end;

destructor TFbTransport.Destroy;
begin
  FPingClient.Free;
  FClient.Free;
  FLock.Free;
  inherited;
end;

function TFbTransport.NewClient: THTTPClient;
begin
  Result := THTTPClient.Create;
  Result.ConnectionTimeout := FConfig.ConnectTimeoutMs;
  Result.ResponseTimeout := FConfig.ResponseTimeoutMs;
  Result.ContentType := CONTENT_TYPE;
  Result.OnValidateServerCertificate := ValidateCertificate;
end;

procedure TFbTransport.ValidateCertificate(const Sender: TObject; const ARequest: TURLRequest;
  const Certificate: TCertificate; var Accepted: Boolean);
var
  reasons: THTTPSecureFailureReasons;
begin
  // Delphi also calls this before each request on a certificate Windows
  // accepted (no failure reasons). A revocation check that could not reach
  // the CRL/OCSP server is accepted, as browsers do; a revoked, untrusted,
  // expired or wrong-name certificate is not.
  reasons := (Sender as THTTPClient).SecureFailureReasons;
  Accepted := (reasons = []) or (reasons = [THTTPSecureFailureReason.CertRevFailed]) or
    FConfig.AllowInvalidCertificate;
end;

function Gunzip(const B: TBytes): TBytes;
var
  src: TBytesStream;
  z: TZDecompressionStream;
  dst: TBytesStream;
  buf: array[0..65535] of Byte;
  n: Integer;
begin
  src := TBytesStream.Create(B);
  dst := TBytesStream.Create;
  try
    z := TZDecompressionStream.Create(src, 15 + 16); // 15 + 16: gzip header
    try
      // Read until 0: CopyFrom(z, 0) would ask the decompression stream for its Size.
      repeat
        n := z.Read(buf, SizeOf(buf));
        if n > 0 then
          dst.WriteBuffer(buf, n);
      until n = 0;
    finally
      z.Free;
    end;
    Result := Copy(dst.Bytes, 0, dst.Size);
  finally
    dst.Free;
    src.Free;
  end;
end;

function TFbTransport.Post(const Body: TBytes; const OpsText: string): TBytes;
var
  attempt: Integer;
  req: TBytesStream;
  resp: IHTTPResponse;
  headers: TNetHeaders;
  started: UInt64;
  ms: Int64;
begin
  // The gateway gzips large responses; decompressed below (works on any Windows/Delphi version).
  headers := [TNameValuePair.Create('Accept-Encoding', 'gzip')];
  if FToken <> '' then
    headers := headers + [TNameValuePair.Create('X-Session', FToken)];
  attempt := 0;
  started := GetTickCount64;
  while True do
  begin
    req := TBytesStream.Create(Body);
    try
      try
        resp := FClient.Post(FConfig.Url + '/v1/rpc', req, nil, headers);
        Break;
      except
        on E: ENetHTTPCertificateException do
        begin
          Count(1, Int64(GetTickCount64 - started), Length(Body), 0);
          raise EFbTransport.Create('TLS certificate rejected: ' + E.Message);
        end;
        on E: ENetException do
        begin
          // Same body, same seq: the gateway answers a repeated request with
          // the stored response instead of executing it again.
          Inc(attempt);
          Count(1, 0, Length(Body), 0);
          if attempt > MAX_RETRIES then
          begin
            Count(0, Int64(GetTickCount64 - started), 0, 0);
            DebugLog(Format('req seq=%d ops=%s out=%d FAILED after %d attempts: %s',
              [FSeq, OpsText, Length(Body), attempt, E.Message]));
            raise EFbTransport.Create(E.Message);
          end;
        end;
      end;
    finally
      req.Free;
    end;
  end;
  FLastActivity := GetTickCount64;
  ms := Int64(FLastActivity - started);
  Count(1, ms, Length(Body), resp.ContentStream.Size);
  DebugLog(Format('req seq=%d ops=%s out=%d in=%d ms=%d http=%d',
    [FSeq, OpsText, Length(Body), resp.ContentStream.Size, ms, resp.StatusCode]));
  case resp.StatusCode of
    200:
      begin
        SetLength(Result, resp.ContentStream.Size);
        resp.ContentStream.Position := 0;
        if Length(Result) > 0 then
          resp.ContentStream.ReadBuffer(Result[0], Length(Result));
        // Check the gzip magic too: a WinHTTP that already decompressed keeps the header.
        if SameText(resp.HeaderValue['Content-Encoding'], 'gzip') and (Length(Result) >= 2) and
          (Result[0] = $1F) and (Result[1] = $8B) then
          Result := Gunzip(Result);
      end;
    413:
      raise EFbCode.Create(isc_random, 'fbhttp: request larger than the gateway limit (max_body_bytes)');
  else
    raise EFbTransport.Create(Format('gateway answered HTTP %d %s', [resp.StatusCode, resp.StatusText]));
  end;
end;

function FirstResult(const Res: TFbResults): TFbResult;
var
  e: TFbError;
begin
  if Length(Res) = 0 then
    raise EFbTransport.Create('empty response from gateway');
  Result := Res[0];
  if Result.Status <> STATUS_OK then
  begin
    if not DecodeError(Result.Payload, e) then
      raise EFbTransport.Create('malformed error from gateway');
    raise EFbRemote.Create(e);
  end;
end;

function TFbTransport.Attach(const Op: TFbOp): TBytes;
var
  res: TFbResults;
begin
  FLock.Enter;
  try
    FToken := '';
    FSeq := 1;
    if not DecodeResponse(Post(EncodeRequest(FSeq, [Op]), OpList([Op])), res) then
      raise EFbTransport.Create('malformed response from gateway');
    Result := FirstResult(res).Payload;
  finally
    FLock.Leave;
  end;
end;

function TFbTransport.CallRaw(const Ops: array of TFbOp): TFbResults;
begin
  FLock.Enter;
  try
    Inc(FSeq);
    if not DecodeResponse(Post(EncodeRequest(FSeq, Ops), OpList(Ops)), Result) then
      raise EFbTransport.Create('malformed response from gateway');
  finally
    FLock.Leave;
  end;
end;

function TFbTransport.Call(const Ops: array of TFbOp): TFbResults;
var
  res: TFbResults;
  i: Integer;
  e: TFbError;
begin
  res := CallRaw(Ops);
  SetLength(Result, 0);
  for i := 0 to High(res) do
  begin
    if res[i].Status = STATUS_OK then
    begin
      Result := Result + [res[i]];
      Continue;
    end;
    if (i <= High(Ops)) and (Ops[i].Flags and FLAG_DEFERRED <> 0) then
      Continue;
    if not DecodeError(res[i].Payload, e) then
      raise EFbTransport.Create('malformed error from gateway');
    raise EFbRemote.Create(e);
  end;
end;

function TFbTransport.CallOne(const Op: TFbOp): TFbReader;
var
  res: TFbResults;
begin
  res := Call([Op]);
  if Length(res) = 0 then
    raise EFbTransport.Create('missing result from gateway');
  Result := TFbReader.Create(res[High(res)].Payload);
end;

function TFbTransport.Ping: Boolean;
var
  resp: IHTTPResponse;
  empty: TBytesStream;
  started: UInt64;
begin
  // Separate client: the main one may be busy with a long request.
  started := GetTickCount64;
  empty := TBytesStream.Create(nil);
  try
    resp := FPingClient.Post(FConfig.Url + '/v1/ping', empty, nil,
      [TNameValuePair.Create('X-Session', FToken)]);
  finally
    empty.Free;
  end;
  FLastActivity := GetTickCount64;
  Count(1, Int64(FLastActivity - started), 0, 0);
  DebugLog(Format('ping http=%d ms=%d', [resp.StatusCode, Int64(FLastActivity - started)]));
  Result := resp.StatusCode = 204;
end;

function TFbTransport.IdleSeconds: Int64;
begin
  Result := IdleMs div 1000;
end;

function TFbTransport.IdleMs: Int64;
begin
  Result := Int64(GetTickCount64 - FLastActivity);
end;

initialization
  GDebugLock := TCriticalSection.Create;
  GStatsLock := TCriticalSection.Create;
  GDebugPath := GetEnvironmentVariable('FBHTTP_DEBUG_LOG');
  GStats.Size := SizeOf(GStats);

finalization
  GStatsLock.Free;
  GDebugLock.Free;
end.
