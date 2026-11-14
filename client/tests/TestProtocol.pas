unit TestProtocol;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TProtocolTests = class
  public
    [Test] procedure RequestRoundTrip;
    [Test] procedure TruncatedRequestFails;
    [Test] procedure HugeLengthFails;
    [Test] procedure RowRoundTripKeepsNullAndEmpty;
    [Test] procedure VaryingLongerThanSqllenFails;
    [Test] procedure GoFixtureError;
    [Test] procedure GoFixtureRow;
    [Test] procedure GoFixtureRequest;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, fbhttp.Protocol;

function Fixture(const Name: string): TBytes;
var
  dir: string;
begin
  dir := GetEnvironmentVariable('FBHTTP_FIXTURES');
  if dir = '' then
    dir := TPath.Combine(ExtractFilePath(ParamStr(0)), '..\..\..\tests\protocol-fixtures');
  Result := TFile.ReadAllBytes(TPath.Combine(dir, Name));
end;

function SampleLayout: TFbLayout;
begin
  SetLength(Result, 4);
  Result[0].SqlType := 497; Result[0].Len := 4;
  Result[1].SqlType := 449; Result[1].Len := 10;
  Result[2].SqlType := 581; Result[2].Scale := -4; Result[2].Len := 8;
  Result[3].SqlType := 453; Result[3].Len := 3;
end;

function SampleRow: TFbRow;
begin
  SetLength(Result, 4);
  Result[0].Data := TBytes.Create(1, 0, 0, 0);
  Result[1].Data := nil;          // empty VARCHAR, not NULL
  Result[2].IsNull := True;
  Result[3].Data := TEncoding.ANSI.GetBytes('abc');
end;

procedure CheckSampleRow(const Row: TFbRow);
begin
  Assert.AreEqual(4, Length(Row));
  Assert.AreEqual(1, Integer(Row[0].Data[0]));
  Assert.IsFalse(Row[1].IsNull, 'empty varchar must not be NULL');
  Assert.AreEqual(0, Length(Row[1].Data));
  Assert.IsTrue(Row[2].IsNull);
  Assert.AreEqual('abc', TEncoding.ANSI.GetString(Row[3].Data));
end;

procedure TProtocolTests.RequestRoundTrip;
var
  w: TFbWriter;
  b: TBytes;
  v, seq: Cardinal;
  ops: TArray<TFbOp>;
begin
  w.U32(5);
  w.U16(2);
  b := EncodeRequest(7, [MakeOp(OP_FREE, w, FLAG_DEFERRED), MakeOp(OP_FETCH, w)]);
  Assert.IsTrue(DecodeRequest(b, v, seq, ops));
  Assert.AreEqual(Cardinal(PROTOCOL_VERSION), v);
  Assert.AreEqual(Cardinal(7), seq);
  Assert.AreEqual(2, Length(ops));
  Assert.AreEqual(Integer(OP_FREE), Integer(ops[0].Code));
  Assert.AreEqual(Integer(FLAG_DEFERRED), Integer(ops[0].Flags));
  Assert.AreEqual(6, Length(ops[1].Payload));
end;

procedure TProtocolTests.TruncatedRequestFails;
var
  w: TFbWriter;
  b: TBytes;
  i: Integer;
  v, seq: Cardinal;
  ops: TArray<TFbOp>;
begin
  w.Str('abc');
  b := EncodeRequest(1, [MakeOp(OP_ATTACH, w)]);
  for i := 0 to Length(b) - 1 do
    Assert.IsFalse(DecodeRequest(Copy(b, 0, i), v, seq, ops), Format('%d bytes', [i]));
end;

procedure TProtocolTests.HugeLengthFails;
var
  r: TFbReader;
begin
  r := TFbReader.Create(TBytes.Create($FF, $FF, $FF, $FF, 1));
  r.Bytes;
  Assert.IsTrue(r.Err);
end;

procedure TProtocolTests.RowRoundTripKeepsNullAndEmpty;
var
  w: TFbWriter;
  r: TFbReader;
  l: TFbLayout;
  has: Boolean;
  row: TFbRow;
begin
  WriteLayout(w, SampleLayout, True);
  WriteRow(w, SampleLayout, SampleRow);
  r := TFbReader.Create(w.ToBytes);
  l := ReadLayout(r, has);
  Assert.IsTrue(has);
  Assert.IsTrue(ReadRow(r, l, row));
  CheckSampleRow(row);
  Assert.AreEqual(0, r.Remaining);
end;

procedure TProtocolTests.VaryingLongerThanSqllenFails;
var
  w: TFbWriter;
  r: TFbReader;
  l: TFbLayout;
  row: TFbRow;
begin
  SetLength(l, 1);
  l[0].SqlType := 448;
  l[0].Len := 5;
  SetLength(row, 1);
  row[0].Data := TEncoding.ANSI.GetBytes('abcdef');
  WriteRow(w, l, row);
  l[0].Len := 2;
  r := TFbReader.Create(w.ToBytes);
  Assert.IsFalse(ReadRow(r, l, row));
end;

procedure TProtocolTests.GoFixtureError;
var
  e: TFbError;
begin
  Assert.IsTrue(DecodeError(Fixture('error.bin'), e));
  Assert.AreEqual(Integer(CAT_FIREBIRD), Integer(e.Category));
  Assert.AreEqual(-803, e.SQLCode);
  Assert.AreEqual(4, Length(e.Status));
  Assert.AreEqual(Int64(335544665), e.Status[0].Num);
  Assert.AreEqual('PK_T', string(e.Status[1].Str));
  Assert.AreEqual('23000', string(e.Status[3].Str));
  Assert.IsTrue(e.FirstMessage.StartsWith('violation of PRIMARY'));
  Assert.IsTrue(string(e.SQLText).StartsWith('Attempt to store duplicate value'));
end;

procedure TProtocolTests.GoFixtureRow;
var
  r: TFbReader;
  l: TFbLayout;
  has: Boolean;
  row: TFbRow;
begin
  r := TFbReader.Create(Fixture('row.bin'));
  l := ReadLayout(r, has);
  Assert.IsTrue(ReadRow(r, l, row));
  CheckSampleRow(row);
end;

procedure TProtocolTests.GoFixtureRequest;
var
  v, seq: Cardinal;
  ops: TArray<TFbOp>;
  free, fetch: TFbWriter;
  mine, go: TBytes;
begin
  go := Fixture('request.bin');
  Assert.IsTrue(DecodeRequest(go, v, seq, ops));
  Assert.AreEqual(Cardinal(2), seq);
  Assert.AreEqual(2, Length(ops));
  // Delphi must produce the same bytes for the same request.
  free.U32(5); free.U16(2);
  fetch.U32(5); fetch.U32(200);
  mine := EncodeRequest(2, [MakeOp(OP_FREE, free, FLAG_DEFERRED), MakeOp(OP_FETCH, fetch)]);
  Assert.AreEqual(Length(go), Length(mine));
  Assert.IsTrue(CompareMem(@go[0], @mine[0], Length(go)), 'bytes differ from the Go encoder');
end;

initialization
  TDUnitX.RegisterTestFixture(TProtocolTests);
end.
