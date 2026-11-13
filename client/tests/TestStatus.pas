unit TestStatus;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TStatusTests = class
  public
    [Test] procedure FirebirdErrorFillsVectorAndMessages;
    [Test] procedure NetworkError;
    [Test] procedure GuardedConvertsExceptions;
    [Test] procedure VectorNeverOverflows;
    [Test] procedure StaleHandleRaisesBadHandle;
  end;

implementation

uses
  System.SysUtils, fbhttp.IBase, fbhttp.Protocol, fbhttp.Status, fbhttp.Handles;

type
  TVector = array[0..STATUS_LEN - 1] of ISC_STATUS;

function PkError: TFbError;
begin
  Result.Category := CAT_FIREBIRD;
  Result.SQLCode := -803;
  SetLength(Result.Status, 4);
  Result.Status[0].Tag := isc_arg_gds; Result.Status[0].Num := 335544665;
  Result.Status[1].Tag := isc_arg_string; Result.Status[1].Str := 'PK_T';
  Result.Status[2].Tag := isc_arg_string; Result.Status[2].Str := 'T';
  Result.Status[3].Tag := isc_arg_gds; Result.Status[3].Num := 335545072;
  Result.Messages := ['violation of PRIMARY or UNIQUE KEY constraint "PK_T" on table "T"', 'Problematic key value is ("ID" = 1)'];
end;

procedure TStatusTests.FirebirdErrorFillsVectorAndMessages;
var
  v: TVector;
  p: PISC_STATUS;
  buf: array[0..1023] of AnsiChar;
begin
  SetStatusFromError(@v[0], PkError);
  Assert.AreEqual(ISC_STATUS(1), v[0]);
  Assert.AreEqual(ISC_STATUS(335544665), v[1]);
  Assert.AreEqual(ISC_STATUS(isc_arg_string), v[2]);
  Assert.AreEqual('PK_T', string(AnsiString(PAnsiChar(v[3]))));
  Assert.AreEqual(ISC_STATUS(isc_arg_end), v[8]);
  Assert.AreEqual(-803, SqlCodeOf(@v[0]));
  p := @v[0];
  Assert.IsTrue(InterpretNext(buf, SizeOf(buf), @p) > 0);
  Assert.AreEqual('violation of PRIMARY or UNIQUE KEY constraint "PK_T" on table "T"', string(AnsiString(buf)));
  Assert.IsTrue(InterpretNext(buf, SizeOf(buf), @p) > 0);
  Assert.AreEqual('Problematic key value is ("ID" = 1)', string(AnsiString(buf)));
  Assert.AreEqual(0, InterpretNext(buf, SizeOf(buf), @p));
end;

procedure TStatusTests.NetworkError;
var
  v: TVector;
begin
  SetNetworkError(@v[0], 'gw', 'timeout');
  Assert.AreEqual(ISC_STATUS(isc_network_error), v[1]);
  Assert.AreEqual(ISC_STATUS(isc_net_read_err), v[5]);
  Assert.AreEqual(-902, SqlCodeOf(@v[0]));
end;

procedure TStatusTests.GuardedConvertsExceptions;
var
  v: TVector;
begin
  Assert.AreEqual(ISC_STATUS(0), Guarded(@v[0], procedure begin end));
  Assert.AreEqual(ISC_STATUS(0), v[1]);
  Assert.AreEqual(ISC_STATUS(isc_network_error),
    Guarded(@v[0], procedure begin raise EFbTransport.Create('down') end));
  Assert.AreEqual(ISC_STATUS(isc_random),
    Guarded(@v[0], procedure begin raise EAccessViolation.Create('boom') end));
  Assert.AreEqual(ISC_STATUS(335544665),
    Guarded(@v[0], procedure begin raise EFbRemote.Create(PkError) end));
end;

procedure TStatusTests.VectorNeverOverflows;
var
  v: array[0..STATUS_LEN + 9] of ISC_STATUS;
  e: TFbError;
  i: Integer;
begin
  for i := 0 to High(v) do
    v[i] := 12345;
  e := PkError;
  SetLength(e.Status, 30);
  for i := 4 to 29 do
  begin
    e.Status[i].Tag := isc_arg_number;
    e.Status[i].Num := i;
  end;
  SetStatusFromError(@v[0], e);
  Assert.AreEqual(ISC_STATUS(isc_arg_end), v[STATUS_LEN - 1]);
  for i := STATUS_LEN to High(v) do
    Assert.AreEqual(ISC_STATUS(12345), v[i], 'wrote past ISC_STATUS_ARRAY');
end;

procedure TStatusTests.StaleHandleRaisesBadHandle;
var
  h: FB_API_HANDLE;
  v: TVector;
begin
  h := Handles.Add(TObject.Create);
  Handles.Remove(h);
  Assert.AreEqual(ISC_STATUS(isc_bad_stmt_handle),
    Guarded(@v[0], procedure begin Handles.Get(h, TObject, isc_bad_stmt_handle) end));
end;

initialization
  TDUnitX.RegisterTestFixture(TStatusTests);
end.
