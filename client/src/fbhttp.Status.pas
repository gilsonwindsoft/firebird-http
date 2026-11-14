unit fbhttp.Status;

{ Status vectors for ws-fbclient.dll.

  The DLL fills the caller's ISC_STATUS array the same way fbclient.dll does.
  String arguments must outlive the call, so each thread keeps the strings of
  its last error (fbclient.dll also keeps them per thread). Message texts come
  already formatted from the gateway (fb_interpret on the server) and are
  served back by fb_interpret / isc_interprete here. ASCII only. }

interface

uses
  System.SysUtils, fbhttp.IBase, fbhttp.Protocol;

type
  // Error from the gateway (category Firebird, session, protocol, limit, internal).
  EFbRemote = class(Exception)
  public
    Error: TFbError;
    constructor Create(const E: TFbError);
  end;

  // Network or HTTP failure talking to the gateway.
  EFbTransport = class(Exception);

  // Local Firebird error with a single gds code (for example a bad handle).
  EFbCode = class(Exception)
  public
    Code: ISC_STATUS;
    constructor Create(ACode: ISC_STATUS; const Msg: string);
  end;

const
  STATUS_LEN = 20; // ISC_STATUS_ARRAY

procedure ClearStatus(st: PISC_STATUS);
procedure SetStatusFromError(st: PISC_STATUS; const E: TFbError);
procedure SetStatusCode(st: PISC_STATUS; Code: ISC_STATUS; const Msg: string);
procedure SetNetworkError(st: PISC_STATUS; const Host, Detail: string);

// Runs Body and converts any exception into the status vector.
// Returns st[1] like the native API (0 on success).
function Guarded(st: PISC_STATUS; const Body: TProc): ISC_STATUS;

// fb_interpret / isc_interprete: next message of the vector at pp^.
function InterpretNext(Buf: PAnsiChar; BufLen: Integer; pp: PPISC_STATUS): Integer;
function SqlCodeOf(st: PISC_STATUS): Integer;
// isc_sql_interprete text the gateway sent for this SQLCODE; empty if none yet.
function SqlInterpreteText(SQLCode: Integer): RawByteString;

implementation

uses
  System.Classes, System.SyncObjs, System.Generics.Collections, Winapi.Windows;

type
  TMsg = record
    Code: ISC_STATUS;
    Text: RawByteString;
  end;

  TThreadError = class
    Strings: TList<RawByteString>; // keeps PAnsiChar arguments alive
    Msgs: TArray<TMsg>;
    SQLCode: Integer;
    FirstCode: ISC_STATUS;
    constructor Create;
    destructor Destroy; override;
  end;

var
  GLock: TCriticalSection;
  GThreads: TObjectDictionary<Cardinal, TThreadError>;
  GSqlTexts: TDictionary<Integer, RawByteString>; // SQLCODE -> isc_sql_interprete text, under GLock

constructor TThreadError.Create;
begin
  Strings := TList<RawByteString>.Create;
end;

destructor TThreadError.Destroy;
begin
  Strings.Free;
  inherited;
end;

constructor EFbRemote.Create(const E: TFbError);
begin
  inherited Create(E.FirstMessage);
  Error := E;
end;

constructor EFbCode.Create(ACode: ISC_STATUS; const Msg: string);
begin
  inherited Create(Msg);
  Code := ACode;
end;

// Returns the cleared per-thread record. Caller holds GLock.
function ThreadRecord: TThreadError;
var
  id: Cardinal;
begin
  id := GetCurrentThreadId;
  if not GThreads.TryGetValue(id, Result) then
  begin
    Result := TThreadError.Create;
    GThreads.Add(id, Result);
  end;
end;

function Keep(T: TThreadError; const S: RawByteString): ISC_STATUS;
begin
  T.Strings.Add(S);
  // Strings in a TList keep their reference count; the pointer stays valid
  // until the list is cleared at this thread's next error.
  Result := ISC_STATUS(PAnsiChar(T.Strings.Last)); // never nil, even for ''
end;

procedure ClearStatus(st: PISC_STATUS);
var
  v: PISC_STATUS;
begin
  if st = nil then
    Exit;
  v := st;
  v^ := isc_arg_gds;
  Inc(v);
  v^ := 0;
  Inc(v);
  v^ := isc_arg_end;
end;

procedure Put(var V: PISC_STATUS; var N: Integer; X: ISC_STATUS);
begin
  if N >= STATUS_LEN - 1 then
    Exit; // keep the last slot for isc_arg_end
  V^ := X;
  Inc(V);
  Inc(N);
end;

procedure SetStatusFromError(st: PISC_STATUS; const E: TFbError);
var
  t: TThreadError;
  v: PISC_STATUS;
  n, i, m: Integer;
  it: TFbStatusItem;
begin
  if st = nil then
    Exit;
  if Length(E.Status) = 0 then
  begin
    // Session, protocol, limit and internal errors carry only text.
    SetStatusCode(st, isc_random, E.FirstMessage);
    Exit;
  end;
  GLock.Enter;
  try
    t := ThreadRecord;
    t.Strings.Clear;
    SetLength(t.Msgs, 0);
    t.SQLCode := E.SQLCode;
    if E.SQLText <> '' then
      GSqlTexts.AddOrSetValue(E.SQLCode, E.SQLText);
    t.FirstCode := 0;
    v := st;
    n := 0;
    m := 0;
    for i := 0 to High(E.Status) do
    begin
      it := E.Status[i];
      Put(v, n, it.Tag);
      if it.Tag = isc_arg_cstring then
      begin
        Put(v, n, Length(it.Str));
        Put(v, n, Keep(t, it.Str));
      end
      else if IsStringTag(it.Tag) then
        Put(v, n, Keep(t, it.Str))
      else
        Put(v, n, ISC_STATUS(it.Num));
      if (it.Tag = isc_arg_gds) or (it.Tag = isc_arg_warning) then
      begin
        if t.FirstCode = 0 then
          t.FirstCode := ISC_STATUS(it.Num);
        // fb_interpret on the gateway produced one line per gds/warning code.
        SetLength(t.Msgs, Length(t.Msgs) + 1);
        t.Msgs[High(t.Msgs)].Code := ISC_STATUS(it.Num);
        if m <= High(E.Messages) then
          t.Msgs[High(t.Msgs)].Text := E.Messages[m];
        Inc(m);
      end;
    end;
    v^ := isc_arg_end;
  finally
    GLock.Leave;
  end;
end;

procedure SetStatusCode(st: PISC_STATUS; Code: ISC_STATUS; const Msg: string);
var
  e: TFbError;
begin
  e.Category := CAT_FIREBIRD;
  e.SQLCode := -902;
  SetLength(e.Status, 1);
  e.Status[0].Tag := isc_arg_gds;
  e.Status[0].Num := Code;
  if Code = isc_random then
  begin
    // isc_random formats its string argument: "%s"
    SetLength(e.Status, 2);
    e.Status[1].Tag := isc_arg_string;
    e.Status[1].Str := RawByteString(Msg);
  end;
  e.Messages := [RawByteString(Msg)];
  SetStatusFromError(st, e);
end;

procedure SetNetworkError(st: PISC_STATUS; const Host, Detail: string);
var
  e: TFbError;
begin
  e.Category := CAT_FIREBIRD;
  e.SQLCode := -902;
  SetLength(e.Status, 3);
  e.Status[0].Tag := isc_arg_gds;
  e.Status[0].Num := isc_network_error;
  e.Status[1].Tag := isc_arg_string;
  e.Status[1].Str := RawByteString(Host);
  e.Status[2].Tag := isc_arg_gds;
  e.Status[2].Num := isc_net_read_err;
  e.Messages := [RawByteString(Format('Unable to complete network request to host "%s".', [Host])),
    RawByteString('Error reading data from the connection: ' + Detail)];
  SetStatusFromError(st, e);
end;

function Guarded(st: PISC_STATUS; const Body: TProc): ISC_STATUS;
begin
  try
    Body();
    ClearStatus(st);
  except
    on E: EFbRemote do
      SetStatusFromError(st, E.Error);
    on E: EFbCode do
      SetStatusCode(st, E.Code, E.Message);
    on E: EFbTransport do
      SetNetworkError(st, 'fbhttp gateway', E.Message);
    on E: Exception do
      SetStatusCode(st, isc_random, 'ws-fbclient internal error: ' + E.ClassName + ': ' + E.Message);
  end;
  if st = nil then
    Result := 0
  else
    Result := PISC_STATUS(PByte(st) + SizeOf(ISC_STATUS))^;
end;

function At(P: PISC_STATUS; I: Integer): ISC_STATUS; inline;
begin
  Result := PISC_STATUS(PByte(P) + I * SizeOf(ISC_STATUS))^;
end;

function InterpretNext(Buf: PAnsiChar; BufLen: Integer; pp: PPISC_STATUS): Integer;
var
  p: PISC_STATUS;
  code, tag: ISC_STATUS;
  t: TThreadError;
  text: RawByteString;
  i: Integer;
begin
  Result := 0;
  if (pp = nil) or (pp^ = nil) or (Buf = nil) or (BufLen <= 0) then
    Exit;
  p := pp^;
  tag := At(p, 0);
  if (tag <> isc_arg_gds) and (tag <> isc_arg_warning) then
    Exit;
  code := At(p, 1);
  if code = 0 then
    Exit;
  text := '';
  GLock.Enter;
  try
    if GThreads.TryGetValue(GetCurrentThreadId, t) then
      for i := 0 to High(t.Msgs) do
        if t.Msgs[i].Code = code then
        begin
          text := t.Msgs[i].Text;
          Break;
        end;
  finally
    GLock.Leave;
  end;
  if text = '' then
    text := RawByteString(Format('Firebird error %d', [code]));
  // Advance to the next gds/warning item.
  i := 2;
  while i < STATUS_LEN do
  begin
    tag := At(p, i);
    if (tag = isc_arg_end) or (tag = isc_arg_gds) or (tag = isc_arg_warning) then
      Break;
    if tag = isc_arg_cstring then
      Inc(i, 3)
    else
      Inc(i, 2);
  end;
  pp^ := PISC_STATUS(PByte(p) + i * SizeOf(ISC_STATUS));
  Result := Length(text);
  if Result > BufLen - 1 then
    Result := BufLen - 1;
  Move(PAnsiChar(text)^, Buf^, Result);
  Buf[Result] := #0;
end;

function SqlCodeOf(st: PISC_STATUS): Integer;
var
  t: TThreadError;
begin
  Result := 0;
  if (st = nil) or (At(st, 1) = 0) then
    Exit;
  Result := -999;
  GLock.Enter;
  try
    if GThreads.TryGetValue(GetCurrentThreadId, t) and (t.FirstCode = At(st, 1)) then
      Result := t.SQLCode;
  finally
    GLock.Leave;
  end;
end;

function SqlInterpreteText(SQLCode: Integer): RawByteString;
begin
  GLock.Enter;
  try
    if not GSqlTexts.TryGetValue(SQLCode, Result) then
      Result := '';
  finally
    GLock.Leave;
  end;
end;

initialization
  GLock := TCriticalSection.Create;
  GSqlTexts := TDictionary<Integer, RawByteString>.Create;
  GThreads := TObjectDictionary<Cardinal, TThreadError>.Create([doOwnsValues]);

finalization
  GSqlTexts.Free;
  GThreads.Free;
  GLock.Free;
end.
