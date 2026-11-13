unit fbhttp.Transport;

{ HTTP transport to the gateway: one THTTPClient (WinHTTP on Windows) per
  attachment, sequence numbers, retry with the same seq, keep-alive ping.
  ASCII only. }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Net.HttpClient,
  System.Net.URLClient, System.NetConsts, fbhttp.Config, fbhttp.Protocol;

type
  TFbTransport = class
  private
    FConfig: TFbHttpConfig;
    FClient: THTTPClient;
    FPingClient: THTTPClient;
    FLock: TCriticalSection;
    FToken: string;
    FSeq: Cardinal;
    FLastActivity: UInt64;
    function NewClient: THTTPClient;
    procedure ValidateCertificate(const Sender: TObject; const ARequest: TURLRequest;
      const Certificate: TCertificate; var Accepted: Boolean);
    function Post(const Body: TBytes): TBytes;
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
    property Config: TFbHttpConfig read FConfig;
    // Session token returned by ATTACH.
    property Token: string read FToken write FToken;
  end;

implementation

uses
  Winapi.Windows, fbhttp.IBase, fbhttp.Status;

const
  CONTENT_TYPE = 'application/x-fbhttp';
  MAX_RETRIES = 2;

constructor TFbTransport.Create(const Config: TFbHttpConfig);
begin
  FConfig := Config;
  FLock := TCriticalSection.Create;
  FClient := NewClient;
  FPingClient := NewClient;
  FLastActivity := GetTickCount64;
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
begin
  // Called only when Windows rejected the certificate.
  Accepted := FConfig.AllowInvalidCertificate;
end;

function TFbTransport.Post(const Body: TBytes): TBytes;
var
  attempt: Integer;
  req: TBytesStream;
  resp: IHTTPResponse;
  headers: TNetHeaders;
begin
  if FToken <> '' then
    headers := [TNameValuePair.Create('X-Session', FToken)]
  else
    headers := [];
  attempt := 0;
  while True do
  begin
    req := TBytesStream.Create(Body);
    try
      try
        resp := FClient.Post(FConfig.Url + '/v1/rpc', req, nil, headers);
        Break;
      except
        on E: ENetHTTPCertificateException do
          raise EFbTransport.Create('TLS certificate rejected: ' + E.Message);
        on E: ENetException do
        begin
          // Same body, same seq: the gateway answers a repeated request with
          // the stored response instead of executing it again.
          Inc(attempt);
          if attempt > MAX_RETRIES then
            raise EFbTransport.Create(E.Message);
        end;
      end;
    finally
      req.Free;
    end;
  end;
  FLastActivity := GetTickCount64;
  case resp.StatusCode of
    200:
      begin
        SetLength(Result, resp.ContentStream.Size);
        resp.ContentStream.Position := 0;
        if Length(Result) > 0 then
          resp.ContentStream.ReadBuffer(Result[0], Length(Result));
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
    if not DecodeResponse(Post(EncodeRequest(FSeq, [Op])), res) then
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
    if not DecodeResponse(Post(EncodeRequest(FSeq, Ops)), Result) then
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
begin
  // Separate client: the main one may be busy with a long request.
  empty := TBytesStream.Create(nil);
  try
    resp := FPingClient.Post(FConfig.Url + '/v1/ping', empty, nil,
      [TNameValuePair.Create('X-Session', FToken)]);
  finally
    empty.Free;
  end;
  Result := resp.StatusCode = 204;
end;

function TFbTransport.IdleSeconds: Int64;
begin
  Result := Int64((GetTickCount64 - FLastActivity) div 1000);
end;

end.
