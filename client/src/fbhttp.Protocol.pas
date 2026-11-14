unit fbhttp.Protocol;

{ fbhttp v1 wire format (docs/protocol.md). Mirrors
  gateway/internal/protocol/codec.go. ASCII only. }

interface

uses
  System.SysUtils;

const
  PROTOCOL_VERSION = 1;

  OP_ATTACH = 1;
  OP_DETACH = 2;
  OP_DATABASE_INFO = 3;
  OP_START_TRANSACTION = 10;
  OP_COMMIT = 11;
  OP_ROLLBACK = 12;
  OP_COMMIT_RETAINING = 13;
  OP_ROLLBACK_RETAINING = 14;
  OP_TRANSACTION_INFO = 15;
  OP_PREPARE = 20;
  OP_FREE = 21;
  OP_EXECUTE = 22;
  OP_EXECUTE_IMMEDIATE = 23;
  OP_FETCH = 24;
  OP_SET_CURSOR_NAME = 25;
  OP_SQL_INFO = 26;
  OP_OPEN_BLOB = 30;
  OP_GET_SEGMENTS = 31;
  OP_CREATE_BLOB = 32;
  OP_PUT_SEGMENTS = 33;
  OP_CLOSE_BLOB = 34;
  OP_CANCEL_BLOB = 35;
  OP_BLOB_INFO = 36;

  CAT_FIREBIRD = 1;
  CAT_SESSION = 2;
  CAT_PROTOCOL = 3;
  CAT_LIMIT = 4;
  CAT_INTERNAL = 5;

  STATUS_OK = 0;
  STATUS_ERROR = 1;
  FLAG_DEFERRED = 1;
  NO_LAYOUT = $FFFF;

type
  EFbProtocol = class(Exception);

  // Only a managed field, so a local TFbWriter variable starts empty
  // (non-managed record fields would start with garbage).
  TFbWriter = record
  private
    FData: TBytes;
    function GetLen: Integer;
  public
    procedure U8(V: Byte);
    procedure U16(V: Word);
    procedure U32(V: Cardinal);
    procedure I16(V: SmallInt);
    procedure I32(V: Integer);
    procedure I64(V: Int64);
    procedure Raw(P: Pointer; N: Integer);
    procedure Bytes(const B: TBytes); overload;
    procedure Bytes(P: Pointer; N: Integer); overload;
    procedure Str(const S: RawByteString);
    function ToBytes: TBytes;
    property Len: Integer read GetLen;
  end;

  // First failure sticks in Err; later reads return zero values.
  TFbReader = record
  private
    FData: TBytes;
    FPos: Integer;
    FErr: Boolean;
    function Take(N: Integer): Integer;
  public
    class function Create(const B: TBytes): TFbReader; static;
    function U8: Byte;
    function U16: Word;
    function U32: Cardinal;
    function I16: SmallInt;
    function I32: Integer;
    function I64: Int64;
    // Copies N raw bytes to Dest. Returns False on truncation.
    function Raw(Dest: Pointer; N: Integer): Boolean;
    function RawBytes(N: Integer): TBytes;
    function Bytes: TBytes;
    function Str: RawByteString;
    function Remaining: Integer;
    property Err: Boolean read FErr;
  end;

  TFbOp = record
    Code: Word;
    Flags: Byte;
    Payload: TBytes;
  end;

  TFbResult = record
    Code: Word;
    Status: Byte;
    Payload: TBytes;
  end;
  TFbResults = TArray<TFbResult>;

  TFbStatusItem = record
    Tag: Cardinal;
    Num: Int64;
    Str: RawByteString;
  end;

  TFbError = record
    Category: Byte;
    SQLCode: Integer;
    Status: TArray<TFbStatusItem>;
    Messages: TArray<RawByteString>;
    // isc_sql_interprete(SQLCode) from the gateway; empty from older gateways.
    SQLText: RawByteString;
    function FirstMessage: string;
  end;

  TFbVar = record
    SqlType, Scale, SubType, Len: SmallInt;
    Name, RelName, OwnName, AliasName: RawByteString;
  end;
  TFbVars = TArray<TFbVar>;
  // Nil layout = "no XSQLDA" (NO_LAYOUT on the wire).
  TFbLayout = TArray<TFbVar>;

  TFbValue = record
    IsNull: Boolean;
    Data: TBytes;   // SQL_VARYING: text only, without the length prefix
  end;
  TFbRow = TArray<TFbValue>;

function EncodeRequest(Seq: Cardinal; const Ops: array of TFbOp): TBytes;
function DecodeRequest(const B: TBytes; out Version, Seq: Cardinal; out Ops: TArray<TFbOp>): Boolean;
function DecodeResponse(const B: TBytes; out Results: TFbResults): Boolean;
function DecodeError(const B: TBytes; out E: TFbError): Boolean;
function IsStringTag(Tag: Cardinal): Boolean;

procedure WriteLayout(var W: TFbWriter; const L: TFbLayout; HasLayout: Boolean);
function ReadLayout(var R: TFbReader; out HasLayout: Boolean): TFbLayout;
function ReadDesc(var R: TFbReader): TFbVars;
procedure WriteRow(var W: TFbWriter; const L: TFbLayout; const Row: TFbRow);
function ReadRow(var R: TFbReader; const L: TFbLayout; out Row: TFbRow): Boolean;

function MakeOp(Code: Word; const W: TFbWriter; Flags: Byte = 0): TFbOp;

implementation

const
  SQL_VARYING_T = 448;
  ARG_END = 0;

{ TFbWriter }

function TFbWriter.GetLen: Integer;
begin
  Result := Length(FData);
end;

procedure TFbWriter.Raw(P: Pointer; N: Integer);
var
  old: Integer;
begin
  if N <= 0 then
    Exit;
  old := Length(FData);
  SetLength(FData, old + N);
  Move(P^, FData[old], N);
end;

procedure TFbWriter.U8(V: Byte);
begin
  Raw(@V, 1);
end;

procedure TFbWriter.U16(V: Word);
begin
  Raw(@V, 2); // x86 is little-endian, like the wire format
end;

procedure TFbWriter.U32(V: Cardinal);
begin
  Raw(@V, 4);
end;

procedure TFbWriter.I16(V: SmallInt);
begin
  Raw(@V, 2);
end;

procedure TFbWriter.I32(V: Integer);
begin
  Raw(@V, 4);
end;

procedure TFbWriter.I64(V: Int64);
begin
  Raw(@V, 8);
end;

procedure TFbWriter.Bytes(const B: TBytes);
begin
  U32(Length(B));
  if Length(B) > 0 then
    Raw(@B[0], Length(B));
end;

procedure TFbWriter.Bytes(P: Pointer; N: Integer);
begin
  if (P = nil) or (N < 0) then
    N := 0;
  U32(N);
  Raw(P, N);
end;

procedure TFbWriter.Str(const S: RawByteString);
begin
  Bytes(PAnsiChar(S), Length(S));
end;

function TFbWriter.ToBytes: TBytes;
begin
  Result := FData;
end;

{ TFbReader }

class function TFbReader.Create(const B: TBytes): TFbReader;
begin
  Result.FData := B;
  Result.FPos := 0;
  Result.FErr := False;
end;

function TFbReader.Take(N: Integer): Integer;
begin
  if FErr or (N < 0) or (N > Length(FData) - FPos) then
  begin
    FErr := True;
    Exit(-1);
  end;
  Result := FPos;
  Inc(FPos, N);
end;

function TFbReader.Raw(Dest: Pointer; N: Integer): Boolean;
var
  p: Integer;
begin
  p := Take(N);
  Result := p >= 0;
  if Result and (N > 0) then
    Move(FData[p], Dest^, N);
end;

function TFbReader.RawBytes(N: Integer): TBytes;
begin
  SetLength(Result, 0);
  if (N < 0) or (N > Remaining) then
  begin
    FErr := True;
    Exit;
  end;
  SetLength(Result, N);
  if not Raw(Pointer(Result), N) then
    SetLength(Result, 0);
end;

function TFbReader.U8: Byte;
begin
  Result := 0;
  Raw(@Result, 1);
end;

function TFbReader.U16: Word;
begin
  Result := 0;
  Raw(@Result, 2);
end;

function TFbReader.U32: Cardinal;
begin
  Result := 0;
  Raw(@Result, 4);
end;

function TFbReader.I16: SmallInt;
begin
  Result := SmallInt(U16);
end;

function TFbReader.I32: Integer;
begin
  Result := Integer(U32);
end;

function TFbReader.I64: Int64;
begin
  Result := 0;
  Raw(@Result, 8);
end;

function TFbReader.Bytes: TBytes;
var
  n: Cardinal;
begin
  n := U32;
  if FErr or (n > Cardinal(Remaining)) then
  begin
    FErr := True;
    Exit(nil);
  end;
  Result := RawBytes(Integer(n));
end;

function TFbReader.Str: RawByteString;
var
  b: TBytes;
begin
  b := Bytes;
  SetString(Result, PAnsiChar(b), Length(b));
end;

function TFbReader.Remaining: Integer;
begin
  Result := Length(FData) - FPos;
end;

{ TFbError }

function TFbError.FirstMessage: string;
begin
  if Length(Messages) > 0 then
    Result := string(Messages[0])
  else
    Result := 'fbhttp error';
end;

function IsStringTag(Tag: Cardinal): Boolean;
begin
  // string, cstring, interpreted, sql_state
  Result := (Tag = 2) or (Tag = 3) or (Tag = 5) or (Tag = 19);
end;

function MakeOp(Code: Word; const W: TFbWriter; Flags: Byte): TFbOp;
begin
  Result.Code := Code;
  Result.Flags := Flags;
  Result.Payload := W.ToBytes;
end;

function EncodeRequest(Seq: Cardinal; const Ops: array of TFbOp): TBytes;
var
  w: TFbWriter;
  i: Integer;
begin
  w.U32(PROTOCOL_VERSION);
  w.U32(Seq);
  w.U16(Length(Ops));
  for i := 0 to High(Ops) do
  begin
    w.U16(Ops[i].Code);
    w.U8(Ops[i].Flags);
    w.Bytes(Ops[i].Payload);
  end;
  Result := w.ToBytes;
end;

function DecodeRequest(const B: TBytes; out Version, Seq: Cardinal; out Ops: TArray<TFbOp>): Boolean;
var
  r: TFbReader;
  i, n: Integer;
begin
  r := TFbReader.Create(B);
  Version := r.U32;
  Seq := r.U32;
  n := r.U16;
  SetLength(Ops, 0);
  for i := 0 to n - 1 do
  begin
    if r.Err then
      Break;
    SetLength(Ops, i + 1);
    Ops[i].Code := r.U16;
    Ops[i].Flags := r.U8;
    Ops[i].Payload := r.Bytes;
  end;
  Result := not r.Err and (r.Remaining = 0);
end;

function DecodeResponse(const B: TBytes; out Results: TFbResults): Boolean;
var
  r: TFbReader;
  i, n: Integer;
begin
  r := TFbReader.Create(B);
  n := r.U16;
  SetLength(Results, 0);
  for i := 0 to n - 1 do
  begin
    if r.Err then
      Break;
    SetLength(Results, i + 1);
    Results[i].Code := r.U16;
    Results[i].Status := r.U8;
    Results[i].Payload := r.Bytes;
  end;
  Result := not r.Err;
end;

function DecodeError(const B: TBytes; out E: TFbError): Boolean;
var
  r: TFbReader;
  tag: Cardinal;
  it: TFbStatusItem;
  i, n: Integer;
begin
  r := TFbReader.Create(B);
  E.Category := r.U8;
  E.SQLCode := r.I32;
  SetLength(E.Status, 0);
  SetLength(E.Messages, 0);
  while not r.Err do
  begin
    tag := r.U32;
    if (tag = ARG_END) or r.Err then
      Break;
    it.Tag := tag;
    it.Num := 0;
    it.Str := '';
    if IsStringTag(tag) then
      it.Str := r.Str
    else
      it.Num := r.I64;
    E.Status := E.Status + [it];
  end;
  n := r.U16;
  for i := 0 to n - 1 do
  begin
    if r.Err then
      Break;
    E.Messages := E.Messages + [r.Str];
  end;
  E.SQLText := '';
  if not r.Err and (r.Remaining > 0) then
    E.SQLText := r.Str;
  Result := not r.Err;
end;

procedure WriteLayout(var W: TFbWriter; const L: TFbLayout; HasLayout: Boolean);
var
  i: Integer;
begin
  if not HasLayout then
  begin
    W.U16(NO_LAYOUT);
    Exit;
  end;
  W.U16(Length(L));
  for i := 0 to High(L) do
  begin
    W.I16(L[i].SqlType);
    W.I16(L[i].Scale);
    W.I16(L[i].SubType);
    W.I16(L[i].Len);
  end;
end;

function ReadLayout(var R: TFbReader; out HasLayout: Boolean): TFbLayout;
var
  n, i: Integer;
begin
  SetLength(Result, 0);
  n := R.U16;
  HasLayout := (n <> NO_LAYOUT) and not R.Err;
  if not HasLayout then
    Exit;
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    Result[i].SqlType := R.I16;
    Result[i].Scale := R.I16;
    Result[i].SubType := R.I16;
    Result[i].Len := R.I16;
  end;
end;

function ReadDesc(var R: TFbReader): TFbVars;
var
  n, i: Integer;
begin
  n := R.U16;
  if R.Err then
    Exit(nil);
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    Result[i].SqlType := R.I16;
    Result[i].Scale := R.I16;
    Result[i].SubType := R.I16;
    Result[i].Len := R.I16;
    Result[i].Name := R.Str;
    Result[i].RelName := R.Str;
    Result[i].OwnName := R.Str;
    Result[i].AliasName := R.Str;
  end;
end;

procedure WriteRow(var W: TFbWriter; const L: TFbLayout; const Row: TFbRow);
var
  i: Integer;
begin
  for i := 0 to High(Row) do
  begin
    if Row[i].IsNull then
    begin
      W.U8(1);
      Continue;
    end;
    W.U8(0);
    if (L[i].SqlType and not 1) = SQL_VARYING_T then
      W.U16(Length(Row[i].Data));
    if Length(Row[i].Data) > 0 then
      W.Raw(@Row[i].Data[0], Length(Row[i].Data));
  end;
end;

function ReadRow(var R: TFbReader; const L: TFbLayout; out Row: TFbRow): Boolean;
var
  i, n: Integer;
begin
  SetLength(Row, Length(L));
  for i := 0 to High(L) do
  begin
    Row[i].IsNull := R.U8 = 1;
    Row[i].Data := nil;
    if Row[i].IsNull then
      Continue;
    n := Word(L[i].Len);
    if (L[i].SqlType and not 1) = SQL_VARYING_T then
    begin
      n := R.U16;
      if n > Word(L[i].Len) then
        Exit(False);
    end;
    Row[i].Data := R.RawBytes(n);
    if R.Err then
      Exit(False);
  end;
  Result := not R.Err;
end;

end.
