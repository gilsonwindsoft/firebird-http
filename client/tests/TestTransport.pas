unit TestTransport;

{ TFbTransport against a fake gateway (Indy TIdHTTPServer on a free port):
  request counters, per-request log, no real Firebird involved. }

interface

uses
  DUnitX.TestFramework, IdHTTPServer, IdContext, IdCustomHTTPServer;

type
  [TestFixture]
  TTransportTests = class
  private
    FServer: TIdHTTPServer;
    FRequests: Integer;
    procedure OnCommand(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
    function Url: string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure CountersGrowPerRequest;
    [Test] procedure DebugLogHasOneLinePerRequest;
    [Test] procedure OpListMarksDeferred;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, IdGlobal, IdSocketHandle,
  fbhttp.Config, fbhttp.Protocol, fbhttp.Transport;

function OkResponse(const Payload: TBytes): TBytes;
var
  w: TFbWriter;
begin
  w.U16(1);
  w.U16(OP_ATTACH);
  w.U8(STATUS_OK);
  w.Bytes(Payload);
  Result := w.ToBytes;
end;

procedure TTransportTests.OnCommand(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  w: TFbWriter;
  body: TBytes;
begin
  Inc(FRequests);
  if ARequestInfo.Document = '/v1/ping' then
  begin
    AResponseInfo.ResponseNo := 204;
    Exit;
  end;
  // ATTACH answer (token, db id) is also a fine answer for any other op here.
  w.Str('token-1');
  w.U32(7);
  body := OkResponse(w.ToBytes);
  AResponseInfo.ContentType := 'application/x-fbhttp';
  AResponseInfo.ContentStream := TBytesStream.Create(body);
  AResponseInfo.FreeContentStream := True;
end;

procedure TTransportTests.Setup;
var
  b: TIdSocketHandle;
begin
  FRequests := 0;
  FServer := TIdHTTPServer.Create(nil);
  b := FServer.Bindings.Add;
  b.IP := '127.0.0.1';
  b.Port := 0; // free port, read back after Active
  FServer.OnCommandOther := OnCommand;
  FServer.OnCommandGet := OnCommand;
  FServer.Active := True;
end;

procedure TTransportTests.TearDown;
begin
  FServer.Active := False;
  FServer.Free;
end;

function TTransportTests.Url: string;
begin
  Result := Format('http://127.0.0.1:%d', [FServer.Bindings[0].Port]);
end;

function FakeConfig(const Url: string): TFbHttpConfig;
begin
  Result := LoadConfig('',
    function(const Name: string): string
    begin
      if Name = 'FBHTTP_URL' then Result := Url
      else if Name = 'FBHTTP_ALLOW_PLAIN_HTTP' then Result := '1'
      else Result := '';
    end);
end;

procedure TTransportTests.CountersGrowPerRequest;
var
  t: TFbTransport;
  w: TFbWriter;
  before, g: TWsFbStats;
  r: TFbReader;
begin
  before := GlobalStats;
  t := TFbTransport.Create(FakeConfig(Url));
  try
    w.Str('db');
    w.Bytes(nil);
    r := TFbReader.Create(t.Attach(MakeOp(OP_ATTACH, w)));
    t.Token := string(r.Str);
    Assert.AreEqual(Cardinal(7), r.U32);
    t.CallRaw([MakeOp(OP_COMMIT, w)]);
    t.CallRaw([MakeOp(OP_COMMIT, w, FLAG_DEFERRED), MakeOp(OP_FETCH, w)]);
    Assert.IsTrue(t.Ping);
    Assert.AreEqual(4, FRequests, 'requests seen by the fake gateway');
    Assert.AreEqual(Int64(4), t.Stats.Requests);
    Assert.IsTrue(t.Stats.BytesOut > 0, 'bytes out');
    Assert.IsTrue(t.Stats.BytesIn > 0, 'bytes in');
    Assert.IsTrue(t.Stats.NetMs >= 0, 'net ms');
    g := GlobalStats;
    Assert.AreEqual(Int64(4), g.Requests - before.Requests, 'global requests');
    Assert.AreEqual(t.Stats.BytesOut, g.BytesOut - before.BytesOut, 'global bytes out');
  finally
    t.Free;
  end;
end;

procedure TTransportTests.DebugLogHasOneLinePerRequest;
var
  t: TFbTransport;
  w: TFbWriter;
  path: string;
  lines: TArray<string>;
  n, i: Integer;
begin
  // The log path is read when the unit loads; the test process must start
  // with FBHTTP_DEBUG_LOG set (build.bat does). Skip otherwise.
  path := GetEnvironmentVariable('FBHTTP_DEBUG_LOG');
  if path = '' then
  begin
    Assert.Pass('FBHTTP_DEBUG_LOG not set');
    Exit;
  end;
  if TFile.Exists(path) then
    TFile.Delete(path);
  t := TFbTransport.Create(FakeConfig(Url));
  try
    w.Str('db');
    w.Bytes(nil);
    t.Attach(MakeOp(OP_ATTACH, w));
    w.U32(1);
    t.CallRaw([MakeOp(OP_PREPARE, w), MakeOp(OP_EXECUTE, w)]);
  finally
    t.Free;
  end;
  lines := TFile.ReadAllLines(path);
  n := 0;
  for i := 0 to High(lines) do
    if lines[i].Contains(' req seq=') then
      Inc(n);
  Assert.AreEqual(2, n, 'one line per request');
  Assert.IsTrue(lines[High(lines)].Contains('ops=20,22'), lines[High(lines)]);
  Assert.IsFalse(lines[High(lines)].Contains('db'), 'payload must not be logged');
end;

procedure TTransportTests.OpListMarksDeferred;
var
  w: TFbWriter;
begin
  Assert.AreEqual('21d,11,22', OpList([MakeOp(OP_FREE, w, FLAG_DEFERRED), MakeOp(OP_COMMIT, w), MakeOp(OP_EXECUTE, w)]));
  Assert.AreEqual('', OpList([]));
end;

initialization
  TDUnitX.RegisterTestFixture(TTransportTests);
end.
