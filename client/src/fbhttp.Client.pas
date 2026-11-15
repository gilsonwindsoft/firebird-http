unit fbhttp.Client;

{ ws-fbclient.dll core: Firebird legacy API calls served through the fbhttp
  gateway. Round-trip rules (design D8, docs/api-surface.md):
  - statement allocation, describe, stmt_type/records/relation_alias info,
    fetch inside a batch and static database info are local;
  - free_statement and blob close/cancel are deferred to the next request;
  - a transaction start is deferred and sent with its first use;
  - an execute that opens a cursor brings the first batch of rows;
  - a PREPARE of a SQL already prepared on this connection is answered from
    the cache and sent with the first operation that uses the statement
    (design D3); the gateway checks the description still matches;
  - commit/rollback of a transaction that wrote nothing is deferred (D5)
    and flushed by the next request, after deferred_flush_ms idle, or on detach.
  Every exported function locks its attachment, so one connection can be
  used from several threads (the driver does this). ASCII only. }

interface

uses
  System.SysUtils, fbhttp.IBase, fbhttp.Transport;

// Exported API. All stdcall like ibase.h, except isc_start_transaction (cdecl varargs).
function W_isc_attach_database(st: PISC_STATUS; namelen: SmallInt; name: PAnsiChar; db: PFB_API_HANDLE; dpblen: SmallInt; dpb: PAnsiChar): ISC_STATUS; stdcall;
function W_isc_detach_database(st: PISC_STATUS; db: PFB_API_HANDLE): ISC_STATUS; stdcall;
function W_isc_database_info(st: PISC_STATUS; db: PFB_API_HANDLE; itemlen: SmallInt; items: PAnsiChar; buflen: SmallInt; buf: PAnsiChar): ISC_STATUS; stdcall;
function W_isc_start_multiple(st: PISC_STATUS; tr: PFB_API_HANDLE; count: SmallInt; teb: PISC_TEB): ISC_STATUS; stdcall;
function W_isc_start_transaction(st: PISC_STATUS; tr: PFB_API_HANDLE; count: SmallInt; db: PFB_API_HANDLE; tpblen: SmallInt; tpb: PAnsiChar): ISC_STATUS; cdecl;
function W_isc_commit_transaction(st: PISC_STATUS; tr: PFB_API_HANDLE): ISC_STATUS; stdcall;
function W_isc_rollback_transaction(st: PISC_STATUS; tr: PFB_API_HANDLE): ISC_STATUS; stdcall;
function W_isc_commit_retaining(st: PISC_STATUS; tr: PFB_API_HANDLE): ISC_STATUS; stdcall;
function W_isc_rollback_retaining(st: PISC_STATUS; tr: PFB_API_HANDLE): ISC_STATUS; stdcall;
function W_isc_transaction_info(st: PISC_STATUS; tr: PFB_API_HANDLE; itemlen: SmallInt; items: PAnsiChar; buflen: SmallInt; buf: PAnsiChar): ISC_STATUS; stdcall;
function W_isc_dsql_allocate_statement(st: PISC_STATUS; db: PFB_API_HANDLE; stmt: PFB_API_HANDLE): ISC_STATUS; stdcall;
function W_isc_dsql_alloc_statement2(st: PISC_STATUS; db: PFB_API_HANDLE; stmt: PFB_API_HANDLE): ISC_STATUS; stdcall;
function W_isc_dsql_prepare(st: PISC_STATUS; tr, stmt: PFB_API_HANDLE; len: Word; sql: PAnsiChar; dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
function W_isc_dsql_describe(st: PISC_STATUS; stmt: PFB_API_HANDLE; dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
function W_isc_dsql_describe_bind(st: PISC_STATUS; stmt: PFB_API_HANDLE; dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
function W_isc_dsql_execute(st: PISC_STATUS; tr, stmt: PFB_API_HANDLE; dialect: Word; inda: PXSQLDA): ISC_STATUS; stdcall;
function W_isc_dsql_execute2(st: PISC_STATUS; tr, stmt: PFB_API_HANDLE; dialect: Word; inda, outda: PXSQLDA): ISC_STATUS; stdcall;
function W_isc_dsql_execute_immediate(st: PISC_STATUS; db, tr: PFB_API_HANDLE; len: Word; sql: PAnsiChar; dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
function W_isc_dsql_exec_immed2(st: PISC_STATUS; db, tr: PFB_API_HANDLE; len: Word; sql: PAnsiChar; dialect: Word; inda, outda: PXSQLDA): ISC_STATUS; stdcall;
function W_isc_dsql_fetch(st: PISC_STATUS; stmt: PFB_API_HANDLE; dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
function W_isc_dsql_free_statement(st: PISC_STATUS; stmt: PFB_API_HANDLE; option: Word): ISC_STATUS; stdcall;
function W_isc_dsql_set_cursor_name(st: PISC_STATUS; stmt: PFB_API_HANDLE; name: PAnsiChar; typ: Word): ISC_STATUS; stdcall;
function W_isc_dsql_sql_info(st: PISC_STATUS; stmt: PFB_API_HANDLE; itemlen: SmallInt; items: PAnsiChar; buflen: SmallInt; buf: PAnsiChar): ISC_STATUS; stdcall;
function W_isc_open_blob2(st: PISC_STATUS; db, tr, blob: PFB_API_HANDLE; id: PISC_QUAD; bpblen: Word; bpb: PByte): ISC_STATUS; stdcall;
function W_isc_open_blob(st: PISC_STATUS; db, tr, blob: PFB_API_HANDLE; id: PISC_QUAD): ISC_STATUS; stdcall;
function W_isc_create_blob2(st: PISC_STATUS; db, tr, blob: PFB_API_HANDLE; id: PISC_QUAD; bpblen: SmallInt; bpb: PAnsiChar): ISC_STATUS; stdcall;
function W_isc_create_blob(st: PISC_STATUS; db, tr, blob: PFB_API_HANDLE; id: PISC_QUAD): ISC_STATUS; stdcall;
function W_isc_get_segment(st: PISC_STATUS; blob: PFB_API_HANDLE; actual: PWord; buflen: Word; buf: PAnsiChar): ISC_STATUS; stdcall;
function W_isc_put_segment(st: PISC_STATUS; blob: PFB_API_HANDLE; len: Word; buf: PAnsiChar): ISC_STATUS; stdcall;
function W_isc_close_blob(st: PISC_STATUS; blob: PFB_API_HANDLE): ISC_STATUS; stdcall;
function W_isc_cancel_blob(st: PISC_STATUS; blob: PFB_API_HANDLE): ISC_STATUS; stdcall;
function W_isc_blob_info(st: PISC_STATUS; blob: PFB_API_HANDLE; itemlen: SmallInt; items: PAnsiChar; buflen: SmallInt; buf: PAnsiChar): ISC_STATUS; stdcall;

// Local helpers and error texts.
function W_isc_vax_integer(p: PByte; len: SmallInt): ISC_LONG; stdcall;
function W_isc_portable_integer(p: PByte; len: SmallInt): Int64; stdcall;
procedure W_isc_get_client_version(buf: PAnsiChar); stdcall;
function W_isc_get_client_major_version: Integer; stdcall;
function W_isc_get_client_minor_version: Integer; stdcall;
function W_fb_interpret(buf: PAnsiChar; buflen: Cardinal; pp: PPISC_STATUS): ISC_LONG; stdcall;
function W_isc_interprete(buf: PAnsiChar; pp: PPISC_STATUS): ISC_LONG; stdcall;
function W_isc_sqlcode(st: PISC_STATUS): ISC_LONG; stdcall;
procedure W_isc_sql_interprete(sqlcode: SmallInt; buf: PAnsiChar; len: SmallInt); stdcall;
procedure W_fb_sqlstate(buf: PAnsiChar; st: PISC_STATUS); stdcall;
function W_isc_print_status(st: PISC_STATUS): ISC_STATUS; stdcall;

// Date helpers (struct tm from the C runtime: 9 ints).
type
  TCTm = record
    tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst: Integer;
  end;
  PCTm = ^TCTm;
  ISC_DATE = Integer;
  ISC_TIME = Cardinal;
  ISC_TIMESTAMP = record
    timestamp_date: ISC_DATE;
    timestamp_time: ISC_TIME;
  end;
  PISC_DATE = ^ISC_DATE;
  PISC_TIME = ^ISC_TIME;
  PISC_TIMESTAMP = ^ISC_TIMESTAMP;

procedure W_isc_decode_sql_date(d: PISC_DATE; tm: PCTm); stdcall;
procedure W_isc_encode_sql_date(tm: PCTm; d: PISC_DATE); stdcall;
procedure W_isc_decode_sql_time(t: PISC_TIME; tm: PCTm); stdcall;
procedure W_isc_encode_sql_time(tm: PCTm; t: PISC_TIME); stdcall;
procedure W_isc_decode_timestamp(ts: PISC_TIMESTAMP; tm: PCTm); stdcall;
procedure W_isc_encode_timestamp(tm: PCTm; ts: PISC_TIMESTAMP); stdcall;
procedure W_isc_decode_date(q: PISC_QUAD; tm: PCTm); stdcall;
procedure W_isc_encode_date(tm: PCTm; q: PISC_QUAD); stdcall;

// ws-fbclient only: fills Stats (caller sets Stats.Size) with the process
// network counters. Returns 0. Used by client/compare to count requests.
function W_ws_fbclient_stats(Stats: PWsFbStats): Integer; stdcall;

// Called by the generated stubs of functions this DLL does not implement.
function NotSupported(st: PISC_STATUS): ISC_STATUS; stdcall;

implementation

uses
  System.Classes, System.SyncObjs, System.Generics.Collections, System.Math, System.AnsiStrings,
  fbhttp.Protocol, fbhttp.Status, fbhttp.Handles, fbhttp.Config, fbhttp.PrepCache;

const
  CLIENT_VERSION = 'WI-V4.0.5 ws-fbclient (fbhttp 1)';
  STMT_SELECT = 1;
  STMT_SELECT_FOR_UPD = 12;
  // sql_info item lists the Devart driver uses (docs/api-surface.md).
  PREPARE_INFO_ITEMS: array[0..4] of Byte = (4, 7, 9, 25, 8);
  PREPARE_INFO_BUFLEN = 1024;
  // Ids the client chooses for transactions and statements it creates in
  // the same request that uses them (docs/protocol.md). One counter for both.
  CLIENT_ID_BASE = $80000000;
  DESCRIPTION_CHANGED = 'fbhttp: statement description changed';
  // isc_database_info items that never change during a connection.
  STATIC_DB_ITEMS: set of Byte = [4, 11, 12, 13, 14, 32, 33, 62, 101, 103];
  PUT_FLUSH_BYTES = 1 shl 20;

type
  TFbTransaction = class;
  TFbStatement = class;

  // One queued operation. Tr: a START, so its transaction learns the
  // outcome. Stmt: a PREPARE answered from the cache. Both nil otherwise.
  TFbPendingOp = record
    Op: TFbOp;
    Tr: TFbTransaction;
    Stmt: TFbStatement;
  end;

  TFbAttachment = class
    Lock: TCriticalSection;
    Transport: TFbTransport;
    ServerId: Cardinal;
    Pending: TList<TFbPendingOp>;   // sent before the next operations, in order
    DbInfo: TDictionary<RawByteString, TBytes>;
    PrepCache: TFbPrepCache;
    Closed: Boolean;
    constructor Create(const Cfg: TFbHttpConfig);
    destructor Destroy; override;
    // Queues an operation whose failure does not matter (frees, closes,
    // read-only commits): it goes with the next request.
    procedure Defer(Code: Word; const W: TFbWriter);
    procedure Queue(const Op: TFbOp; Tr: TFbTransaction; Stmt: TFbStatement);
    // Queues the START of T once, before the operations that need it.
    procedure QueueStart(T: TFbTransaction);
    // Drops the references of pending ops to an object about to be freed.
    procedure Forget(Obj: TObject);
    // Sends the pending ops, the START of Tr when it was not started yet,
    // then Ops. Returns the results of Ops. Raises on the first failed
    // non-deferred op; Tr.Started is set as soon as its START succeeded.
    // Pending ops the gateway did not reach are queued again.
    function Send(const Ops: array of TFbOp; Tr: TObject = nil): TFbResults;
  end;

  TFbTransaction = class
    Att: TFbAttachment;
    Id: Cardinal;          // client-chosen gateway id
    Tpb: TBytes;
    Started: Boolean;      // START already accepted by the gateway
    StartQueued: Boolean;  // START is in Pending
    Wrote: Boolean;        // something that may write ran in it (D5)
  end;

  TFbStatement = class
    Att: TFbAttachment;
    ServerId: Cardinal;
    StmtType: Integer;
    Prepared: Boolean;
    OutDesc, InDesc: TFbVars;
    PrepInfo: TBytes;
    CacheKey: RawByteString;  // dialect + SQL of the last prepare
    PrepPending: Boolean;     // the PREPARE is still in Pending
    FromCache: Boolean;       // described from the cache; first EXECUTE sends the expected description
    Records: TBytes;
    Rows: TArray<TFbRow>;
    RowPos: Integer;
    Eof: Boolean;
    CursorOpen: Boolean;
    CursorName: RawByteString;
    // Layout the rows are fetched with. The describe layout until the driver
    // fetches with a different XSQLDA (coercion); then the driver's layout,
    // kept for the next executions of the same prepared statement.
    FetchLayout: TFbLayout;
    HasFetchLayout: Boolean;
    LayoutChecked: Boolean;   // first fetch of the current cursor compared
    // Last cursor execution, to reopen the cursor with the driver's layout.
    LastTrId: Cardinal;
    LastDialect: Word;
    LastInput: TBytes;
    function RowLayout: TFbLayout;
  end;

  TFbBlob = class
    Att: TFbAttachment;
    ServerId: Cardinal;    // 0 = fully read already (inline)
    Writing: Boolean;
    Info: TBytes;
    Data: TBytes;          // read buffer
    DataPos: Integer;
    ServerEof: Boolean;
    Segments: TList<TBytes>; // write buffer
    Buffered: Integer;
    destructor Destroy; override;
  end;

  TKeepAlive = class(TThread)
  protected
    procedure Execute; override;
  end;

var
  GTrCounter: Integer;
  GAttachments: TList<TFbAttachment>;
  GAttLock: TCriticalSection;
  GKeepAlive: TKeepAlive;
  GStop: TEvent;

{ helpers }

function LayoutText(const L: TFbLayout): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(L) do
    Result := Result + Format('[%d:%d/%d/%d/%d]', [i, L[i].SqlType, L[i].SubType, L[i].Scale, L[i].Len]);
end;

function SameLayout(const A, B: TFbLayout): Boolean;
var
  i: Integer;
begin
  Result := Length(A) = Length(B);
  if Result then
    for i := 0 to High(A) do
      // The nullable bit only adds the NULL indicator; the data is the same.
      if ((A[i].SqlType or 1) <> (B[i].SqlType or 1)) or (A[i].Scale <> B[i].Scale) or
        (A[i].SubType <> B[i].SubType) or (A[i].Len <> B[i].Len) then
        Exit(False);
end;

function TrStartOp(T: TFbTransaction): TFbOp;
var
  w: TFbWriter;
begin
  w.U32(T.Att.ServerId);
  w.Bytes(T.Tpb);
  w.U32(T.Id);
  Result := MakeOp(OP_START_TRANSACTION, w);
end;

function NextClientId: Cardinal;
begin
  Result := CLIENT_ID_BASE or Cardinal(AtomicIncrement(GTrCounter) and $7FFFFFFF);
end;

// True for the gateway's "expected description differs" error (D4).
function IsDescriptionChanged(const E: TFbError): Boolean;
begin
  Result := (E.Category = CAT_PROTOCOL) and (Length(E.Messages) > 0) and
    SameText(string(E.Messages[0]), DESCRIPTION_CHANGED);
end;

function GetAtt(H: PFB_API_HANDLE): TFbAttachment;
begin
  if H = nil then
    raise EFbCode.Create(isc_bad_db_handle, 'invalid database handle (no active connection)');
  Result := TFbAttachment(Handles.Get(H^, TFbAttachment, isc_bad_db_handle));
  if Result.Closed then
    raise EFbCode.Create(isc_bad_db_handle, 'invalid database handle (no active connection)');
end;

function GetTr(H: PFB_API_HANDLE): TFbTransaction;
begin
  if H = nil then
    raise EFbCode.Create(isc_bad_trans_handle, 'invalid transaction handle (expecting explicit transaction start)');
  Result := TFbTransaction(Handles.Get(H^, TFbTransaction, isc_bad_trans_handle));
end;

function GetStmt(H: PFB_API_HANDLE): TFbStatement;
begin
  if H = nil then
    raise EFbCode.Create(isc_bad_stmt_handle, 'invalid statement handle');
  Result := TFbStatement(Handles.Get(H^, TFbStatement, isc_bad_stmt_handle));
end;

function GetBlob(H: PFB_API_HANDLE): TFbBlob;
begin
  if H = nil then
    raise EFbCode.Create(isc_bad_segstr_handle, 'invalid BLOB handle');
  Result := TFbBlob(Handles.Get(H^, TFbBlob, isc_bad_segstr_handle));
end;

// Runs Ops after the START of T when T was not started on the gateway yet.
function SendWithTr(T: TFbTransaction; A: TFbAttachment; const Ops: array of TFbOp): TFbResults;
begin
  Result := A.Send(Ops, T);
end;

function Reader(const R: TFbResult): TFbReader;
begin
  Result := TFbReader.Create(R.Payload);
end;

procedure CopyInfo(const Src: TBytes; buf: PAnsiChar; buflen: SmallInt);
var
  n: Integer;
begin
  if (buf = nil) or (buflen <= 0) then
    Exit;
  FillChar(buf^, buflen, 0);
  n := Min(Length(Src), buflen);
  if n > 0 then
    Move(Src[0], buf^, n);
end;

function ItemsKey(items: PAnsiChar; itemlen: SmallInt; buflen: SmallInt): RawByteString;
begin
  SetString(Result, items, Max(itemlen, 0));
  Result := Result + RawByteString(Format('/%d', [buflen]));
end;

{ XSQLDA <-> rows }

function LayoutOf(da: PXSQLDA): TFbLayout;
var
  i: Integer;
  v: PXSQLVAR;
begin
  SetLength(Result, da^.sqld);
  for i := 0 to da^.sqld - 1 do
  begin
    v := SqlVar(da, i);
    Result[i].SqlType := v^.sqltype;
    Result[i].Scale := v^.sqlscale;
    Result[i].SubType := v^.sqlsubtype;
    Result[i].Len := v^.sqllen;
  end;
end;

function RowOf(da: PXSQLDA): TFbRow;
var
  i, n: Integer;
  v: PXSQLVAR;
begin
  SetLength(Result, da^.sqld);
  for i := 0 to da^.sqld - 1 do
  begin
    v := SqlVar(da, i);
    Result[i].IsNull := ((v^.sqltype and 1) = 1) and (v^.sqlind <> nil) and (v^.sqlind^ < 0);
    if Result[i].IsNull or (v^.sqldata = nil) then
      Continue;
    if (v^.sqltype and not 1) = SQL_VARYING then
    begin
      n := Min(PWord(v^.sqldata)^, Word(v^.sqllen));
      SetLength(Result[i].Data, n);
      if n > 0 then
        Move((v^.sqldata + 2)^, Result[i].Data[0], n);
    end
    else
    begin
      n := Word(v^.sqllen);
      SetLength(Result[i].Data, n);
      if n > 0 then
        Move(v^.sqldata^, Result[i].Data[0], n);
    end;
  end;
end;

procedure WriteInput(var W: TFbWriter; da: PXSQLDA);
begin
  if (da = nil) or (da^.sqld = 0) then
  begin
    WriteLayout(W, nil, False);
    Exit;
  end;
  WriteLayout(W, LayoutOf(da), True);
  WriteRow(W, LayoutOf(da), RowOf(da));
end;

// Copies a row into the client's output XSQLDA (the only place that writes it).
procedure PutRow(da: PXSQLDA; const Row: TFbRow);
var
  i, n: Integer;
  v: PXSQLVAR;
begin
  if da = nil then
    Exit;
  for i := 0 to Min(da^.sqld, Length(Row)) - 1 do
  begin
    v := SqlVar(da, i);
    if Row[i].IsNull then
    begin
      if v^.sqlind <> nil then
        v^.sqlind^ := -1;
      // Like the native client: the value buffer of a NULL is zeroed. The
      // Devart driver converts it even for NULL (garbage = invalid BCD).
      if v^.sqldata <> nil then
        if (v^.sqltype and not 1) = SQL_VARYING then
          FillChar(v^.sqldata^, Word(v^.sqllen) + 2, 0)
        else
          FillChar(v^.sqldata^, Word(v^.sqllen), 0);
      Continue;
    end;
    if v^.sqlind <> nil then
      v^.sqlind^ := 0;
    if v^.sqldata = nil then
      Continue;
    if (v^.sqltype and not 1) = SQL_VARYING then
    begin
      n := Min(Length(Row[i].Data), Word(v^.sqllen));
      PWord(v^.sqldata)^ := n;
      if n > 0 then
        Move(Row[i].Data[0], (v^.sqldata + 2)^, n);
    end
    else
    begin
      n := Min(Length(Row[i].Data), Word(v^.sqllen));
      if n > 0 then
        Move(Row[i].Data[0], v^.sqldata^, n);
    end;
  end;
end;

// Fills an XSQLDA from a description, like isc_dsql_describe.
procedure PutDesc(da: PXSQLDA; const D: TFbVars);
var
  i: Integer;
  v: PXSQLVAR;

  procedure Name(const S: RawByteString; var Len: SmallInt; var Buf: array of AnsiChar);
  var
    n: Integer;
  begin
    n := Min(Length(S), Length(Buf));
    FillChar(Buf[0], Length(Buf), 0);
    if n > 0 then
      Move(S[1], Buf[0], n);
    Len := n;
  end;

begin
  if da = nil then
    Exit;
  if da^.version <> SQLDA_VERSION1 then
    raise EFbCode.Create(isc_random, 'unsupported XSQLDA version');
  da^.sqld := Length(D);
  for i := 0 to Min(da^.sqln, Length(D)) - 1 do
  begin
    v := SqlVar(da, i);
    v^.sqltype := D[i].SqlType;
    v^.sqlscale := D[i].Scale;
    v^.sqlsubtype := D[i].SubType;
    v^.sqllen := D[i].Len;
    Name(D[i].Name, v^.sqlname_length, v^.sqlname);
    Name(D[i].RelName, v^.relname_length, v^.relname);
    Name(D[i].OwnName, v^.ownname_length, v^.ownname);
    Name(D[i].AliasName, v^.aliasname_length, v^.aliasname);
  end;
end;

{ TFbAttachment }

constructor TFbAttachment.Create(const Cfg: TFbHttpConfig);
begin
  Lock := TCriticalSection.Create;
  Transport := TFbTransport.Create(Cfg);
  Pending := TList<TFbPendingOp>.Create;
  DbInfo := TDictionary<RawByteString, TBytes>.Create;
  PrepCache := TFbPrepCache.Create(Cfg.PrepareCache);
end;

destructor TFbAttachment.Destroy;
begin
  PrepCache.Free;
  DbInfo.Free;
  Pending.Free;
  Transport.Free;
  Lock.Free;
  inherited;
end;

procedure TFbAttachment.Defer(Code: Word; const W: TFbWriter);
begin
  Queue(MakeOp(Code, W, FLAG_DEFERRED), nil, nil);
end;

procedure TFbAttachment.Queue(const Op: TFbOp; Tr: TFbTransaction; Stmt: TFbStatement);
var
  p: TFbPendingOp;
begin
  p.Op := Op;
  p.Tr := Tr;
  p.Stmt := Stmt;
  Pending.Add(p);
end;

procedure TFbAttachment.QueueStart(T: TFbTransaction);
begin
  if (T = nil) or T.Started or T.StartQueued then
    Exit;
  Queue(TrStartOp(T), T, nil);
  T.StartQueued := True;
end;

procedure TFbAttachment.Forget(Obj: TObject);
var
  i: Integer;
  p: TFbPendingOp;
begin
  for i := 0 to Pending.Count - 1 do
  begin
    p := Pending[i];
    if (TObject(p.Tr) = Obj) or (TObject(p.Stmt) = Obj) then
    begin
      p.Tr := nil;
      p.Stmt := nil;
      Pending[i] := p;
    end;
  end;
end;

function TFbAttachment.Send(const Ops: array of TFbOp; Tr: TObject): TFbResults;
var
  pend: TArray<TFbPendingOp>;
  all: TArray<TFbOp>;
  i, j, startIdx, firstOp: Integer;
  raw: TFbResults;
  t: TFbTransaction;
  e: TFbError;

  procedure Requeue(From: Integer);
  var
    k: Integer;
  begin
    // The gateway stops at the first failed non-deferred op: what it did
    // not reach goes with the next request, in the same order.
    for k := From to High(pend) do
      Pending.Add(pend[k]);
  end;

begin
  t := TFbTransaction(Tr);
  pend := Pending.ToArray;
  Pending.Clear;
  SetLength(all, Length(pend));
  for i := 0 to High(pend) do
    all[i] := pend[i].Op;
  startIdx := -1;
  if (t <> nil) and not t.Started and not t.StartQueued then
  begin
    startIdx := Length(all);
    all := all + [TrStartOp(t)];
  end;
  firstOp := Length(all);
  for i := 0 to High(Ops) do
    all := all + [Ops[i]];
  SetLength(Result, 0);
  if Length(all) = 0 then
    Exit;
  try
    raw := Transport.CallRaw(all);
  except
    Requeue(0);
    raise;
  end;
  for i := 0 to High(raw) do
  begin
    if raw[i].Status = STATUS_OK then
    begin
      if i = startIdx then
        t.Started := True;
      if i <= High(pend) then
      begin
        if pend[i].Tr <> nil then
        begin
          pend[i].Tr.Started := True;
          pend[i].Tr.StartQueued := False;
        end;
        if pend[i].Stmt <> nil then
          pend[i].Stmt.PrepPending := False;
      end;
      if i >= firstOp then
        Result := Result + [raw[i]];
      Continue;
    end;
    if all[i].Flags and FLAG_DEFERRED <> 0 then
    begin
      // Deferred frees, closes and read-only commits: the error does not matter.
      if DecodeError(raw[i].Payload, e) then
        DebugLog(Format('deferred op %d failed: %s', [all[i].Code, e.FirstMessage]));
      Continue;
    end;
    if not DecodeError(raw[i].Payload, e) then
      raise EFbTransport.Create('malformed error from gateway');
    if i <= High(pend) then
    begin
      if pend[i].Tr <> nil then
        pend[i].Tr.StartQueued := False; // the next use sends START again
      if pend[i].Stmt <> nil then
      begin
        // Cached description no longer prepares: forget it, the driver gets
        // the real error on the call that sent the request.
        pend[i].Stmt.Prepared := False;
        pend[i].Stmt.PrepPending := False;
        pend[i].Stmt.FromCache := False;
        PrepCache.Drop(pend[i].Stmt.CacheKey);
      end;
      Requeue(i + 1);
    end
    else
      Requeue(Length(pend)); // nothing pending was skipped
    raise EFbRemote.Create(e);
  end;
  if Length(raw) < Length(pend) then
  begin
    // Unreachable by protocol (the gateway only stops on an error), but
    // never lose a queued op.
    for j := Length(raw) to High(pend) do
      Pending.Add(pend[j]);
  end;
  if Length(Result) <> Length(Ops) then
    raise EFbTransport.Create('missing results from gateway');
end;

destructor TFbBlob.Destroy;
begin
  Segments.Free;
  inherited;
end;

{ keep-alive }

procedure TKeepAlive.Execute;
var
  list: TArray<TFbAttachment>;
  a: TFbAttachment;
begin
  while GStop.WaitFor(250) = wrTimeout do
  begin
    GAttLock.Enter;
    try
      list := GAttachments.ToArray;
    finally
      GAttLock.Leave;
    end;
    for a in list do
      try
        if a.Closed then
          Continue;
        // Deferred commits and frees of an idle connection: send them now so
        // the Firebird transaction does not stay open (D5). TryEnter: never
        // block the application thread; it flushes on its next call anyway.
        if (a.Pending.Count > 0) and (a.Transport.IdleMs >= a.Transport.Config.DeferredFlushMs) and
          a.Lock.TryEnter then
          try
            if a.Pending.Count > 0 then
              a.Send([]);
          finally
            a.Lock.Leave;
          end;
        if (a.Transport.Config.KeepAliveSeconds > 0) and
          (a.Transport.IdleSeconds >= a.Transport.Config.KeepAliveSeconds) then
          a.Transport.Ping;
      except
        // A failed ping or flush is reported by the next real call.
      end;
  end;
end;

procedure StartKeepAlive;
begin
  GAttLock.Enter;
  try
    if GKeepAlive = nil then
    begin
      GKeepAlive := TKeepAlive.Create(True);
      GKeepAlive.FreeOnTerminate := True;
      GKeepAlive.Start;
    end;
  finally
    GAttLock.Leave;
  end;
end;

{ attachment }

function W_isc_attach_database(st: PISC_STATUS; namelen: SmallInt; name: PAnsiChar; db: PFB_API_HANDLE; dpblen: SmallInt; dpb: PAnsiChar): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    var
      cfg: TFbHttpConfig;
      msg, dbname: RawByteString;
      w: TFbWriter;
      a: TFbAttachment;
      r: TFbReader;
    begin
      if namelen > 0 then
        SetString(dbname, name, namelen)
      else
        dbname := System.AnsiStrings.StrPas(name);
      cfg := LoadDefaultConfig;
      // No url in the .ini or environment: the Database host is the gateway.
      if cfg.Url = '' then
        cfg.Url := GatewayUrlFromDatabase(string(dbname));
      msg := RawByteString(cfg.Validate);
      if msg <> '' then
        raise EFbCode.Create(isc_random, string(msg));
      w.Str(dbname);
      w.Bytes(dpb, Max(dpblen, 0));
      a := TFbAttachment.Create(cfg);
      try
        r := TFbReader.Create(a.Transport.Attach(MakeOp(OP_ATTACH, w)));
        a.Transport.Token := string(r.Str);
        a.ServerId := r.U32;
        if r.Err then
          raise EFbTransport.Create('malformed ATTACH response');
      except
        a.Free;
        raise;
      end;
      db^ := Handles.Add(a);
      GAttLock.Enter;
      try
        GAttachments.Add(a);
      finally
        GAttLock.Leave;
      end;
      StartKeepAlive;
    end);
end;

function W_isc_detach_database(st: PISC_STATUS; db: PFB_API_HANDLE): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    var
      a: TFbAttachment;
      w: TFbWriter;
    begin
      a := GetAtt(db);
      a.Lock.Enter;
      try
        w.U32(a.ServerId);
        a.Send([MakeOp(OP_DETACH, w)]);
        a.Closed := True;
      finally
        a.Lock.Leave;
      end;
      GAttLock.Enter;
      try
        GAttachments.Remove(a);
      finally
        GAttLock.Leave;
      end;
      // Child objects keep a reference to a; the attachment object stays
      // alive (Closed) so stale child handles fail cleanly.
      db^ := 0;
    end);
end;

function W_isc_database_info(st: PISC_STATUS; db: PFB_API_HANDLE; itemlen: SmallInt; items: PAnsiChar; buflen: SmallInt; buf: PAnsiChar): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    var
      a: TFbAttachment;
      key: RawByteString;
      cached: TBytes;
      isStatic: Boolean;
      i: Integer;
      w: TFbWriter;
      r: TFbReader;
    begin
      a := GetAtt(db);
      key := ItemsKey(items, itemlen, buflen);
      isStatic := itemlen > 0;
      for i := 0 to itemlen - 1 do
        if not (Byte(items[i]) in STATIC_DB_ITEMS) and (Byte(items[i]) <> isc_info_end) then
          isStatic := False;
      a.Lock.Enter;
      try
        if isStatic and a.DbInfo.TryGetValue(key, cached) then
        begin
          CopyInfo(cached, buf, buflen);
          Exit;
        end;
        w.U32(a.ServerId);
        w.Bytes(items, Max(itemlen, 0));
        w.U32(Max(buflen, 0));
        r := Reader(a.Send([MakeOp(OP_DATABASE_INFO, w)])[0]);
        cached := r.Bytes;
        if isStatic then
          a.DbInfo.AddOrSetValue(key, cached);
      finally
        a.Lock.Leave;
      end;
      CopyInfo(cached, buf, buflen);
    end);
end;

{ transactions }

function NewTransaction(st: PISC_STATUS; tr, db: PFB_API_HANDLE; tpb: PAnsiChar; tpblen: Integer): ISC_STATUS;
begin
  Result := Guarded(st, procedure
    var
      t: TFbTransaction;
    begin
      if tr = nil then
        raise EFbCode.Create(isc_bad_trans_handle, 'invalid transaction handle (expecting explicit transaction start)');
      t := TFbTransaction.Create;
      t.Att := GetAtt(db);
      t.Id := NextClientId;
      SetLength(t.Tpb, Max(tpblen, 0));
      if Length(t.Tpb) > 0 then
        Move(tpb^, t.Tpb[0], Length(t.Tpb));
      // The START goes with the first operation that uses the transaction.
      tr^ := Handles.Add(t);
    end);
end;

function W_isc_start_multiple(st: PISC_STATUS; tr: PFB_API_HANDLE; count: SmallInt; teb: PISC_TEB): ISC_STATUS; stdcall;
begin
  if (count <> 1) or (teb = nil) then
  begin
    SetStatusCode(st, isc_wish_list, 'ws-fbclient: transactions over more than one database are not supported');
    Exit(isc_wish_list);
  end;
  Result := NewTransaction(st, tr, teb^.db_ptr, teb^.tpb_ptr, teb^.tpb_len);
end;

function W_isc_start_transaction(st: PISC_STATUS; tr: PFB_API_HANDLE; count: SmallInt; db: PFB_API_HANDLE; tpblen: SmallInt; tpb: PAnsiChar): ISC_STATUS; cdecl;
begin
  if count <> 1 then
  begin
    SetStatusCode(st, isc_wish_list, 'ws-fbclient: transactions over more than one database are not supported');
    Exit(isc_wish_list);
  end;
  Result := NewTransaction(st, tr, db, tpb, tpblen);
end;

function EndTransaction(st: PISC_STATUS; tr: PFB_API_HANDLE; Code: Word; Final: Boolean): ISC_STATUS;
begin
  Result := Guarded(st, procedure
    var
      t: TFbTransaction;
      w: TFbWriter;
    begin
      t := GetTr(tr);
      t.Att.Lock.Enter;
      try
        // Never started on the server: nothing to commit or roll back.
        if t.Started or t.StartQueued then
        begin
          w.U32(t.Id);
          if t.Att.Transport.Config.DeferReadOnlyCommit and not t.Wrote then
            // Nothing to make durable: the end goes with the next request,
            // in order, or when the connection is idle (D5).
            t.Att.Defer(Code, w)
          else
            t.Att.Send([MakeOp(Code, w)]);
        end;
        if Final then
          t.Att.Forget(t);
      finally
        t.Att.Lock.Leave;
      end;
      if Final then
      begin
        Handles.Remove(tr^);
        tr^ := 0;
      end;
    end);
end;

function W_isc_commit_transaction(st: PISC_STATUS; tr: PFB_API_HANDLE): ISC_STATUS; stdcall;
begin
  Result := EndTransaction(st, tr, OP_COMMIT, True);
end;

function W_isc_rollback_transaction(st: PISC_STATUS; tr: PFB_API_HANDLE): ISC_STATUS; stdcall;
begin
  Result := EndTransaction(st, tr, OP_ROLLBACK, True);
end;

function W_isc_commit_retaining(st: PISC_STATUS; tr: PFB_API_HANDLE): ISC_STATUS; stdcall;
begin
  Result := EndTransaction(st, tr, OP_COMMIT_RETAINING, False);
end;

function W_isc_rollback_retaining(st: PISC_STATUS; tr: PFB_API_HANDLE): ISC_STATUS; stdcall;
begin
  Result := EndTransaction(st, tr, OP_ROLLBACK_RETAINING, False);
end;

function W_isc_transaction_info(st: PISC_STATUS; tr: PFB_API_HANDLE; itemlen: SmallInt; items: PAnsiChar; buflen: SmallInt; buf: PAnsiChar): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    var
      t: TFbTransaction;
      w: TFbWriter;
      data: TBytes;
    begin
      t := GetTr(tr);
      t.Att.Lock.Enter;
      try
        w.U32(t.Id);
        w.Bytes(items, Max(itemlen, 0));
        w.U32(Max(buflen, 0));
        data := Reader(SendWithTr(t, t.Att, [MakeOp(OP_TRANSACTION_INFO, w)])[0]).Bytes;
      finally
        t.Att.Lock.Leave;
      end;
      CopyInfo(data, buf, buflen);
    end);
end;

{ statements }

function AllocStatement(st: PISC_STATUS; db, stmt: PFB_API_HANDLE): ISC_STATUS;
begin
  Result := Guarded(st, procedure
    var
      s: TFbStatement;
    begin
      if stmt = nil then
        raise EFbCode.Create(isc_bad_stmt_handle, 'invalid statement handle');
      s := TFbStatement.Create;
      s.Att := GetAtt(db);
      stmt^ := Handles.Add(s); // allocated on the gateway with the first PREPARE
    end);
end;

function W_isc_dsql_allocate_statement(st: PISC_STATUS; db: PFB_API_HANDLE; stmt: PFB_API_HANDLE): ISC_STATUS; stdcall;
begin
  Result := AllocStatement(st, db, stmt);
end;

function W_isc_dsql_alloc_statement2(st: PISC_STATUS; db: PFB_API_HANDLE; stmt: PFB_API_HANDLE): ISC_STATUS; stdcall;
begin
  Result := AllocStatement(st, db, stmt);
end;

procedure ResetCursor(s: TFbStatement);
var
  w: TFbWriter;
begin
  s.Rows := nil;
  s.RowPos := 0;
  s.Eof := False;
  if s.CursorOpen then
  begin
    // The server cursor stays open until closed, even after the last row.
    w.U32(s.ServerId);
    w.U16(DSQL_close);
    s.Att.Defer(OP_FREE, w);
    s.CursorOpen := False;
  end;
end;

function W_isc_dsql_prepare(st: PISC_STATUS; tr, stmt: PFB_API_HANDLE; len: Word; sql: PAnsiChar; dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    var
      s: TFbStatement;
      t: TFbTransaction;
      text: RawByteString;
      w: TFbWriter;
      r: TFbReader;
      entry: TFbPrepEntry;
    begin
      s := GetStmt(stmt);
      t := GetTr(tr);
      if len = 0 then
        text := System.AnsiStrings.StrPas(sql)
      else
        SetString(text, sql, len);
      s.Att.Lock.Enter;
      try
        ResetCursor(s);
        s.CacheKey := TFbPrepCache.KeyOf(dialect, text);
        entry := s.Att.PrepCache.Find(s.CacheKey);
        if (entry <> nil) and not s.PrepPending then
        begin
          // Known SQL: describe from the cache and send the PREPARE with the
          // first operation that uses the statement (D3). A statement never
          // seen by the gateway gets an id of ours.
          if s.ServerId = 0 then
            s.ServerId := NextClientId;
          s.Att.QueueStart(t);
          w.U32(s.Att.ServerId);
          w.U32(t.Id);
          w.U32(s.ServerId);
          w.U16(dialect);
          w.Str(text);
          w.Bytes(@PREPARE_INFO_ITEMS[0], Length(PREPARE_INFO_ITEMS));
          w.U32(PREPARE_INFO_BUFLEN);
          s.Att.Queue(MakeOp(OP_PREPARE, w), nil, s);
          s.PrepPending := True;
          s.FromCache := True;
          s.StmtType := entry.StmtType;
          s.OutDesc := Copy(entry.OutDesc);
          s.InDesc := Copy(entry.InDesc);
          s.PrepInfo := Copy(entry.PrepInfo);
        end
        else
        begin
          w.U32(s.Att.ServerId);
          w.U32(t.Id);
          w.U32(s.ServerId);
          w.U16(dialect);
          w.Str(text);
          w.Bytes(@PREPARE_INFO_ITEMS[0], Length(PREPARE_INFO_ITEMS));
          w.U32(PREPARE_INFO_BUFLEN);
          r := Reader(SendWithTr(t, s.Att, [MakeOp(OP_PREPARE, w)])[0]);
          s.ServerId := r.U32;
          s.StmtType := r.I32;
          s.OutDesc := ReadDesc(r);
          s.InDesc := ReadDesc(r);
          s.PrepInfo := r.Bytes;
          if r.Err then
            raise EFbTransport.Create('malformed PREPARE response');
          s.FromCache := False;
          s.Att.PrepCache.Store(s.CacheKey, s.StmtType, s.OutDesc, s.InDesc, s.PrepInfo);
        end;
        s.Records := nil;
        s.HasFetchLayout := False;
        s.FetchLayout := nil;
        s.Prepared := True;
      finally
        s.Att.Lock.Leave;
      end;
      PutDesc(da, s.OutDesc);
    end);
end;

function W_isc_dsql_describe(st: PISC_STATUS; stmt: PFB_API_HANDLE; dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    begin
      PutDesc(da, GetStmt(stmt).OutDesc);
    end);
end;

function W_isc_dsql_describe_bind(st: PISC_STATUS; stmt: PFB_API_HANDLE; dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    begin
      PutDesc(da, GetStmt(stmt).InDesc);
    end);
end;

function DescLayout(const D: TFbVars): TFbLayout;
var
  i: Integer;
begin
  SetLength(Result, Length(D));
  for i := 0 to High(D) do
  begin
    Result[i].SqlType := D[i].SqlType;
    Result[i].Scale := D[i].Scale;
    Result[i].SubType := D[i].SubType;
    Result[i].Len := D[i].Len;
  end;
end;

function TFbStatement.RowLayout: TFbLayout;
begin
  if HasFetchLayout then
    Result := FetchLayout
  else
    Result := DescLayout(OutDesc);
end;

procedure ReadBatch(s: TFbStatement; var R: TFbReader);
var
  n, i: Integer;
  layout: TFbLayout;
begin
  layout := s.RowLayout;
  n := R.U32;
  if R.Err or (n < 0) then
    raise EFbTransport.Create('malformed row batch');
  SetLength(s.Rows, n);
  for i := 0 to n - 1 do
    if not ReadRow(R, layout, s.Rows[i]) then
      raise EFbTransport.Create('malformed row batch');
  s.RowPos := 0;
  s.Eof := R.U8 = 1;
end;

// isc_dsql_execute / execute2. A nil outda on a cursor statement opens the
// cursor and brings the first batch with the described layout (the driver
// never changes the layout before fetching: docs/api-surface.md).
// Expected description (D4): sent with the first EXECUTE of a statement
// described from the cache, so the gateway refuses a stale description.
procedure WriteExpected(var W: TFbWriter; S: TFbStatement);
begin
  if not S.FromCache then
  begin
    W.U8(0);
    Exit;
  end;
  W.U8(1);
  WriteLayout(W, DescLayout(S.OutDesc), True);
  WriteLayout(W, DescLayout(S.InDesc), True);
end;

// The gateway refused a stale cached description (DDL since): drop the
// entry and give the driver the error the native client gives for a wrong
// XSQLDA. The next prepare of this SQL goes to the gateway.
function StaleDescription(S: TFbStatement): EFbCode;
begin
  S.Att.PrepCache.Drop(S.CacheKey);
  S.Prepared := False;
  S.FromCache := False;
  Result := EFbCode.Create(isc_dsql_sqlda_err, DESCRIPTION_CHANGED + ' (schema changed since the statement was cached; prepare again)');
end;

function DoExecute(st: PISC_STATUS; tr, stmt: PFB_API_HANDLE; dialect: Word; inda, outda: PXSQLDA): ISC_STATUS;
begin
  Result := Guarded(st, procedure
    var
      s: TFbStatement;
      t: TFbTransaction;
      w, input: TFbWriter;
      r: TFbReader;
      cursor: Boolean;
      kind: Byte;
      row: TFbRow;
      fetch: Integer;
    begin
      s := GetStmt(stmt);
      t := GetTr(tr);
      if not s.Prepared then
        raise EFbCode.Create(isc_bad_stmt_handle, 'statement not prepared');
      cursor := ((s.StmtType = STMT_SELECT) or (s.StmtType = STMT_SELECT_FOR_UPD)) and (outda = nil);
      fetch := 0;
      if cursor then
        fetch := s.Att.Transport.Config.FetchRows;
      s.Att.Lock.Enter;
      try
        ResetCursor(s);
        // Anything but a plain SELECT may write (FOR UPDATE, procedures, DML, DDL).
        if s.StmtType <> STMT_SELECT then
          t.Wrote := True;
        WriteInput(input, inda);
        w.U32(t.Id);
        w.U32(s.ServerId);
        w.U16(dialect);
        w.Raw(Pointer(input.ToBytes), input.Len);
        if cursor then
          WriteLayout(w, s.RowLayout, True)
        else if outda <> nil then
          WriteLayout(w, LayoutOf(outda), True)
        else
          WriteLayout(w, nil, False);
        w.U32(fetch);
        WriteExpected(w, s);
        try
          r := Reader(SendWithTr(t, s.Att, [MakeOp(OP_EXECUTE, w)])[0]);
        except
          on E: EFbRemote do
            if IsDescriptionChanged(E.Error) then
              raise StaleDescription(s)
            else
              raise;
        end;
        s.FromCache := False;
        kind := r.U8;
        case kind of
          0:
            s.Records := r.Bytes;
          1:
            begin
              if r.U8 = 1 then
              begin
                if not ReadRow(r, LayoutOf(outda), row) then
                  raise EFbTransport.Create('malformed EXECUTE response');
                PutRow(outda, row);
              end;
              s.Records := r.Bytes;
            end;
          2:
            begin
              s.Records := r.Bytes;
              ReadBatch(s, r);
              s.CursorOpen := True;
              s.LayoutChecked := False;
              s.LastTrId := t.Id;
              s.LastDialect := dialect;
              s.LastInput := input.ToBytes;
            end;
        else
          raise EFbTransport.Create('malformed EXECUTE response');
        end;
        if r.Err then
          raise EFbTransport.Create('malformed EXECUTE response');
      finally
        s.Att.Lock.Leave;
      end;
    end);
end;

function W_isc_dsql_execute(st: PISC_STATUS; tr, stmt: PFB_API_HANDLE; dialect: Word; inda: PXSQLDA): ISC_STATUS; stdcall;
begin
  Result := DoExecute(st, tr, stmt, dialect, inda, nil);
end;

function W_isc_dsql_execute2(st: PISC_STATUS; tr, stmt: PFB_API_HANDLE; dialect: Word; inda, outda: PXSQLDA): ISC_STATUS; stdcall;
begin
  Result := DoExecute(st, tr, stmt, dialect, inda, outda);
end;

function W_isc_dsql_exec_immed2(st: PISC_STATUS; db, tr: PFB_API_HANDLE; len: Word; sql: PAnsiChar; dialect: Word; inda, outda: PXSQLDA): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    var
      a: TFbAttachment;
      t: TFbTransaction;
      text: RawByteString;
      w: TFbWriter;
      r: TFbReader;
      newTr: Cardinal;
      row: TFbRow;
    begin
      a := GetAtt(db);
      t := nil;
      if (tr <> nil) and (tr^ <> 0) then
        t := GetTr(tr);
      if len = 0 then
        text := System.AnsiStrings.StrPas(sql)
      else
        SetString(text, sql, len);
      a.Lock.Enter;
      try
        if t <> nil then
          t.Wrote := True; // EXECUTE IMMEDIATE is DDL or DML in practice
        w.U32(a.ServerId);
        if t = nil then w.U32(0) else w.U32(t.Id);
        w.U16(dialect);
        w.Str(text);
        WriteInput(w, inda);
        if outda <> nil then
          WriteLayout(w, LayoutOf(outda), True)
        else
          WriteLayout(w, nil, False);
        r := Reader(SendWithTr(t, a, [MakeOp(OP_EXECUTE_IMMEDIATE, w)])[0]);
        newTr := r.U32;
        if r.U8 = 1 then
        begin
          if not ReadRow(r, LayoutOf(outda), row) then
            raise EFbTransport.Create('malformed EXECUTE_IMMEDIATE response');
          PutRow(outda, row);
        end;
      finally
        a.Lock.Leave;
      end;
      // SET TRANSACTION / COMMIT inside the statement change the handle.
      if (t <> nil) and (newTr = 0) then
      begin
        Handles.Remove(tr^);
        tr^ := 0;
      end
      else if (t = nil) and (newTr <> 0) and (tr <> nil) then
      begin
        t := TFbTransaction.Create;
        t.Att := a;
        t.Id := newTr;
        t.Started := True;
        tr^ := Handles.Add(t);
      end;
    end);
end;

function W_isc_dsql_execute_immediate(st: PISC_STATUS; db, tr: PFB_API_HANDLE; len: Word; sql: PAnsiChar; dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
begin
  Result := W_isc_dsql_exec_immed2(st, db, tr, len, sql, dialect, da, nil);
end;

function W_isc_dsql_fetch(st: PISC_STATUS; stmt: PFB_API_HANDLE; dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
var
  atEnd: Boolean;
begin
  atEnd := False;
  Result := Guarded(st, procedure
    var
      s: TFbStatement;
      w: TFbWriter;
      r: TFbReader;
    begin
      s := GetStmt(stmt);
      s.Att.Lock.Enter;
      try
        if not s.CursorOpen then
          raise EFbCode.Create(isc_random, 'Attempt to fetch from a closed cursor');
        if not s.LayoutChecked and (da <> nil) then
        begin
          s.LayoutChecked := True;
          if not SameLayout(LayoutOf(da), s.RowLayout) then
          begin
            // The driver coerces types: reopen the cursor with its layout so
            // the server converts, like the native client.
            DebugLog(Format('stmt %d: fetch layout differs from describe; reopening. described=%s driver=%s',
              [s.ServerId, LayoutText(s.RowLayout), LayoutText(LayoutOf(da))]));
            s.FetchLayout := LayoutOf(da);
            s.HasFetchLayout := True;
            ResetCursor(s);
            w.U32(s.LastTrId);
            w.U32(s.ServerId);
            w.U16(s.LastDialect);
            w.Raw(Pointer(s.LastInput), Length(s.LastInput));
            WriteLayout(w, s.FetchLayout, True);
            w.U32(s.Att.Transport.Config.FetchRows);
            w.U8(0); // already executed once: description checked then
            r := Reader(s.Att.Send([MakeOp(OP_EXECUTE, w)])[0]);
            if r.U8 <> 2 then
              raise EFbTransport.Create('malformed EXECUTE response');
            s.Records := r.Bytes;
            ReadBatch(s, r);
            s.CursorOpen := True;
            w := Default(TFbWriter);
          end;
        end;
        if (s.RowPos >= Length(s.Rows)) and not s.Eof then
        begin
          w.U32(s.ServerId);
          WriteLayout(w, nil, False);
          w.U32(s.Att.Transport.Config.FetchRows);
          r := Reader(s.Att.Send([MakeOp(OP_FETCH, w)])[0]);
          ReadBatch(s, r);
        end;
        if s.RowPos >= Length(s.Rows) then
        begin
          atEnd := True;
          Exit;
        end;
        PutRow(da, s.Rows[s.RowPos]);
        s.Rows[s.RowPos] := nil; // release memory as rows are consumed
        Inc(s.RowPos);
      finally
        s.Att.Lock.Leave;
      end;
    end);
  if (Result = 0) and atEnd then
    Result := 100;
end;

// Removes the queued PREPARE of S (caller holds the attachment lock).
procedure DropPendingPrepare(S: TFbStatement);
var
  i: Integer;
begin
  for i := S.Att.Pending.Count - 1 downto 0 do
    if (S.Att.Pending[i].Stmt = S) and (S.Att.Pending[i].Op.Code = OP_PREPARE) then
      S.Att.Pending.Delete(i);
  S.PrepPending := False;
  S.FromCache := False;
end;

function W_isc_dsql_free_statement(st: PISC_STATUS; stmt: PFB_API_HANDLE; option: Word): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    var
      s: TFbStatement;
      w: TFbWriter;
    begin
      s := GetStmt(stmt);
      s.Att.Lock.Enter;
      try
        if option = DSQL_close then
          ResetCursor(s)
        else
        begin
          s.CursorOpen := False; // drop/unprepare close the cursor too
          s.Rows := nil;
          if s.PrepPending then
          begin
            // Prepared from the cache and never used: the gateway never saw
            // it. Drop the queued PREPARE instead of sending PREPARE + FREE.
            DropPendingPrepare(s);
            s.ServerId := 0;
          end;
          if s.ServerId <> 0 then
          begin
            w.U32(s.ServerId);
            w.U16(option);
            s.Att.Defer(OP_FREE, w);
          end;
          if option = DSQL_unprepare then
            s.Prepared := False;
          if option = DSQL_drop then
            s.Att.Forget(s);
        end;
      finally
        s.Att.Lock.Leave;
      end;
      if option = DSQL_drop then
      begin
        Handles.Remove(stmt^);
        stmt^ := 0;
      end;
    end);
end;

function W_isc_dsql_set_cursor_name(st: PISC_STATUS; stmt: PFB_API_HANDLE; name: PAnsiChar; typ: Word): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    var
      s: TFbStatement;
      w: TFbWriter;
    begin
      s := GetStmt(stmt);
      s.Att.Lock.Enter;
      try
        s.CursorName := System.AnsiStrings.StrPas(name);
        w.U32(s.ServerId);
        w.Str(s.CursorName);
        s.Att.Send([MakeOp(OP_SET_CURSOR_NAME, w)]);
      finally
        s.Att.Lock.Leave;
      end;
    end);
end;

function SameItems(items: PAnsiChar; itemlen: SmallInt; const Expected: array of Byte): Boolean;
var
  i: Integer;
begin
  Result := itemlen = Length(Expected);
  if Result then
    for i := 0 to itemlen - 1 do
      if Byte(items[i]) <> Expected[i] then
        Exit(False);
end;

function W_isc_dsql_sql_info(st: PISC_STATUS; stmt: PFB_API_HANDLE; itemlen: SmallInt; items: PAnsiChar; buflen: SmallInt; buf: PAnsiChar): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    var
      s: TFbStatement;
      w: TFbWriter;
      data: TBytes;
      typ: Integer;
    begin
      s := GetStmt(stmt);
      if s.Prepared and SameItems(items, itemlen, [isc_info_sql_stmt_type]) then
      begin
        typ := s.StmtType;
        data := TBytes.Create(isc_info_sql_stmt_type, 4, 0, 0, 0, 0, 0, isc_info_end);
        Move(typ, data[3], 4);
      end
      else if s.Prepared and SameItems(items, itemlen, PREPARE_INFO_ITEMS) and (buflen = PREPARE_INFO_BUFLEN) then
        data := s.PrepInfo
      else if (s.Records <> nil) and SameItems(items, itemlen, [isc_info_sql_records]) then
        data := s.Records
      else
      begin
        s.Att.Lock.Enter;
        try
          w.U32(s.ServerId);
          w.Bytes(items, Max(itemlen, 0));
          w.U32(Max(buflen, 0));
          data := Reader(s.Att.Send([MakeOp(OP_SQL_INFO, w)])[0]).Bytes;
        finally
          s.Att.Lock.Leave;
        end;
      end;
      CopyInfo(data, buf, buflen);
    end);
end;

{ blobs }

function W_isc_open_blob2(st: PISC_STATUS; db, tr, blob: PFB_API_HANDLE; id: PISC_QUAD; bpblen: Word; bpb: PByte): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    var
      a: TFbAttachment;
      t: TFbTransaction;
      w: TFbWriter;
      r: TFbReader;
      b: TFbBlob;
    begin
      a := GetAtt(db);
      t := GetTr(tr);
      if (blob = nil) or (id = nil) then
        raise EFbCode.Create(isc_bad_segstr_handle, 'invalid BLOB handle');
      b := TFbBlob.Create;
      try
        b.Att := a;
        a.Lock.Enter;
        try
          w.U32(a.ServerId);
          w.U32(t.Id);
          w.Raw(id, 8);
          w.Bytes(bpb, bpblen);
          w.U32(a.Transport.Config.InlineBlobBytes);
          r := Reader(SendWithTr(t, a, [MakeOp(OP_OPEN_BLOB, w)])[0]);
          b.ServerId := r.U32;
          b.Info := r.Bytes;
          b.ServerEof := r.U8 = 1;
          b.Data := r.Bytes;
          if r.Err then
            raise EFbTransport.Create('malformed OPEN_BLOB response');
        finally
          a.Lock.Leave;
        end;
      except
        b.Free;
        raise;
      end;
      blob^ := Handles.Add(b);
    end);
end;

function W_isc_open_blob(st: PISC_STATUS; db, tr, blob: PFB_API_HANDLE; id: PISC_QUAD): ISC_STATUS; stdcall;
begin
  Result := W_isc_open_blob2(st, db, tr, blob, id, 0, nil);
end;

function W_isc_create_blob2(st: PISC_STATUS; db, tr, blob: PFB_API_HANDLE; id: PISC_QUAD; bpblen: SmallInt; bpb: PAnsiChar): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    var
      a: TFbAttachment;
      t: TFbTransaction;
      w: TFbWriter;
      r: TFbReader;
      b: TFbBlob;
    begin
      a := GetAtt(db);
      t := GetTr(tr);
      if (blob = nil) or (id = nil) then
        raise EFbCode.Create(isc_bad_segstr_handle, 'invalid BLOB handle');
      b := TFbBlob.Create;
      try
        b.Att := a;
        b.Writing := True;
        b.Segments := TList<TBytes>.Create;
        a.Lock.Enter;
        try
          t.Wrote := True;
          w.U32(a.ServerId);
          w.U32(t.Id);
          w.Bytes(bpb, Max(bpblen, 0));
          r := Reader(SendWithTr(t, a, [MakeOp(OP_CREATE_BLOB, w)])[0]);
          b.ServerId := r.U32;
          if not r.Raw(id, 8) then
            raise EFbTransport.Create('malformed CREATE_BLOB response');
        finally
          a.Lock.Leave;
        end;
      except
        b.Free;
        raise;
      end;
      blob^ := Handles.Add(b);
    end);
end;

function W_isc_create_blob(st: PISC_STATUS; db, tr, blob: PFB_API_HANDLE; id: PISC_QUAD): ISC_STATUS; stdcall;
begin
  Result := W_isc_create_blob2(st, db, tr, blob, id, 0, nil);
end;

function PutSegmentsOp(b: TFbBlob): TFbOp;
var
  w: TFbWriter;
  seg: TBytes;
begin
  w.U32(b.ServerId);
  w.U32(b.Segments.Count);
  for seg in b.Segments do
    w.Bytes(seg);
  b.Segments.Clear;
  b.Buffered := 0;
  Result := MakeOp(OP_PUT_SEGMENTS, w);
end;

function W_isc_get_segment(st: PISC_STATUS; blob: PFB_API_HANDLE; actual: PWord; buflen: Word; buf: PAnsiChar): ISC_STATUS; stdcall;
var
  eof: Boolean;
begin
  eof := False;
  Result := Guarded(st, procedure
    var
      b: TFbBlob;
      w: TFbWriter;
      r: TFbReader;
      n: Integer;
    begin
      b := GetBlob(blob);
      if actual <> nil then
        actual^ := 0;
      b.Att.Lock.Enter;
      try
        if (b.DataPos >= Length(b.Data)) and not b.ServerEof then
        begin
          w.U32(b.ServerId);
          w.U32(1 shl 20);
          r := Reader(b.Att.Send([MakeOp(OP_GET_SEGMENTS, w)])[0]);
          b.Data := r.Bytes;
          b.DataPos := 0;
          b.ServerEof := r.U8 = 1;
        end;
      finally
        b.Att.Lock.Leave;
      end;
      n := Min(Length(b.Data) - b.DataPos, buflen);
      if n <= 0 then
      begin
        eof := True;
        Exit;
      end;
      Move(b.Data[b.DataPos], buf^, n);
      Inc(b.DataPos, n);
      if actual <> nil then
        actual^ := n;
    end);
  if (Result = 0) and eof then
  begin
    SetStatusCode(st, isc_segstr_eof, 'segment buffer length shorter than expected');
    Result := isc_segstr_eof;
  end;
end;

function W_isc_put_segment(st: PISC_STATUS; blob: PFB_API_HANDLE; len: Word; buf: PAnsiChar): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    var
      b: TFbBlob;
      seg: TBytes;
    begin
      b := GetBlob(blob);
      if not b.Writing then
        raise EFbCode.Create(isc_bad_segstr_handle, 'invalid BLOB handle');
      SetLength(seg, len);
      if len > 0 then
        Move(buf^, seg[0], len);
      b.Att.Lock.Enter;
      try
        b.Segments.Add(seg);
        Inc(b.Buffered, len);
        if b.Buffered >= PUT_FLUSH_BYTES then
          b.Att.Send([PutSegmentsOp(b)]);
      finally
        b.Att.Lock.Leave;
      end;
    end);
end;

function EndBlob(st: PISC_STATUS; blob: PFB_API_HANDLE; Cancel: Boolean): ISC_STATUS;
begin
  Result := Guarded(st, procedure
    var
      b: TFbBlob;
      w: TFbWriter;
    begin
      b := GetBlob(blob);
      b.Att.Lock.Enter;
      try
        if b.ServerId <> 0 then
        begin
          w.U32(b.ServerId);
          if b.Writing and not Cancel then
            b.Att.Send([PutSegmentsOp(b), MakeOp(OP_CLOSE_BLOB, w)]) // the id must be valid after close
          else if Cancel then
            b.Att.Defer(OP_CANCEL_BLOB, w)
          else
            b.Att.Defer(OP_CLOSE_BLOB, w);
        end;
      finally
        b.Att.Lock.Leave;
      end;
      Handles.Remove(blob^);
      blob^ := 0;
    end);
end;

function W_isc_close_blob(st: PISC_STATUS; blob: PFB_API_HANDLE): ISC_STATUS; stdcall;
begin
  Result := EndBlob(st, blob, False);
end;

function W_isc_cancel_blob(st: PISC_STATUS; blob: PFB_API_HANDLE): ISC_STATUS; stdcall;
begin
  // isc_cancel_blob accepts a zero handle.
  if (blob <> nil) and (blob^ = 0) then
  begin
    ClearStatus(st);
    Exit(0);
  end;
  Result := EndBlob(st, blob, True);
end;

// Rebuilds an info answer in the order the caller asked, from a cached block.
function InfoFromCache(const Cache: TBytes; items: PAnsiChar; itemlen: SmallInt; out Data: TBytes): Boolean;
var
  i, p, n: Integer;
  item: Byte;
  found: Boolean;
begin
  Data := nil;
  for i := 0 to itemlen - 1 do
  begin
    item := Byte(items[i]);
    if item = isc_info_end then
      Break;
    found := False;
    p := 0;
    while p + 3 <= Length(Cache) do
    begin
      if Cache[p] = isc_info_end then
        Break;
      n := Cache[p + 1] or (Cache[p + 2] shl 8);
      if Cache[p] = item then
      begin
        Data := Data + Copy(Cache, p, 3 + n);
        found := True;
        Break;
      end;
      Inc(p, 3 + n);
    end;
    if not found then
      Exit(False);
  end;
  Data := Data + [isc_info_end];
  Result := True;
end;

function W_isc_blob_info(st: PISC_STATUS; blob: PFB_API_HANDLE; itemlen: SmallInt; items: PAnsiChar; buflen: SmallInt; buf: PAnsiChar): ISC_STATUS; stdcall;
begin
  Result := Guarded(st, procedure
    var
      b: TFbBlob;
      data: TBytes;
      w: TFbWriter;
    begin
      b := GetBlob(blob);
      if b.Writing or not InfoFromCache(b.Info, items, itemlen, data) then
      begin
        if b.ServerId = 0 then
          raise EFbCode.Create(isc_wish_list, 'ws-fbclient: blob info item not available');
        b.Att.Lock.Enter;
        try
          if b.Writing and (b.Segments.Count > 0) then
            b.Att.Send([PutSegmentsOp(b)]);
          w.U32(b.ServerId);
          w.Bytes(items, Max(itemlen, 0));
          w.U32(Max(buflen, 0));
          data := Reader(b.Att.Send([MakeOp(OP_BLOB_INFO, w)])[0]).Bytes;
        finally
          b.Att.Lock.Leave;
        end;
      end;
      CopyInfo(data, buf, buflen);
    end);
end;

{ local helpers }

function W_isc_vax_integer(p: PByte; len: SmallInt): ISC_LONG; stdcall;
var
  i, shift: Integer;
begin
  // Same rule as Firebird: little-endian, last byte signed, up to 8 bytes
  // (bits beyond 32 are lost, like the native ISC_LONG result).
  Result := 0;
  if (p = nil) or (len <= 0) or (len > 8) then
    Exit;
  shift := 0;
  for i := 0 to len - 2 do
  begin
    if shift < 32 then
      Result := Result + (Integer(p[i]) shl shift);
    Inc(shift, 8);
  end;
  if shift < 32 then
    Result := Result + (Integer(ShortInt(p[len - 1])) shl shift);
end;

function W_isc_portable_integer(p: PByte; len: SmallInt): Int64; stdcall;
var
  i: Integer;
  v: UInt64;
begin
  Result := 0;
  if (p = nil) or (len <= 0) or (len > 8) then
    Exit;
  v := 0;
  for i := len - 1 downto 0 do
    v := (v shl 8) or p[i];
  if (len < 8) and ((p[len - 1] and $80) <> 0) then
    v := v or (UInt64($FFFFFFFFFFFFFFFF) shl (8 * len));
  Result := Int64(v);
end;

procedure W_isc_get_client_version(buf: PAnsiChar); stdcall;
begin
  if buf <> nil then
    System.AnsiStrings.StrCopy(buf, CLIENT_VERSION);
end;

function W_isc_get_client_major_version: Integer; stdcall;
begin
  Result := 4;
end;

function W_isc_get_client_minor_version: Integer; stdcall;
begin
  Result := 0;
end;

function W_fb_interpret(buf: PAnsiChar; buflen: Cardinal; pp: PPISC_STATUS): ISC_LONG; stdcall;
begin
  try
    Result := InterpretNext(buf, Integer(Min(buflen, Cardinal(MaxInt))), pp);
  except
    Result := 0;
  end;
end;

function W_isc_interprete(buf: PAnsiChar; pp: PPISC_STATUS): ISC_LONG; stdcall;
begin
  // Deprecated API without buffer size; Firebird documents 512 bytes as the minimum.
  try
    Result := InterpretNext(buf, 512, pp);
  except
    Result := 0;
  end;
end;

function W_isc_sqlcode(st: PISC_STATUS): ISC_LONG; stdcall;
begin
  try
    Result := SqlCodeOf(st);
  except
    Result := -999;
  end;
end;

procedure W_isc_sql_interprete(sqlcode: SmallInt; buf: PAnsiChar; len: SmallInt); stdcall;
var
  s: AnsiString;
begin
  if (buf = nil) or (len <= 0) then
    Exit;
  // Text from the gateway (firebird.msg on the server), cached per SQLCODE.
  s := AnsiString(SqlInterpreteText(sqlcode));
  if s = '' then
    s := AnsiString(Format('SQL error code = %d', [sqlcode]));
  System.AnsiStrings.StrLCopy(buf, PAnsiChar(s), len - 1);
end;

procedure W_fb_sqlstate(buf: PAnsiChar; st: PISC_STATUS); stdcall;
var
  i: Integer;
  p: PISC_STATUS;
  tag: ISC_STATUS;
begin
  if buf = nil then
    Exit;
  System.AnsiStrings.StrCopy(buf, '00000');
  if (st = nil) or (PISC_STATUS(PByte(st) + 4)^ = 0) then
    Exit;
  System.AnsiStrings.StrCopy(buf, 'HY000');
  p := st;
  i := 0;
  while i < STATUS_LEN - 1 do
  begin
    tag := PISC_STATUS(PByte(p) + 4 * i)^;
    if tag = isc_arg_end then
      Break;
    if tag = isc_arg_sql_state then
    begin
      System.AnsiStrings.StrLCopy(buf, PAnsiChar(PISC_STATUS(PByte(p) + 4 * (i + 1))^), 5);
      Exit;
    end;
    if tag = isc_arg_cstring then
      Inc(i, 3)
    else
      Inc(i, 2);
  end;
end;

function W_isc_print_status(st: PISC_STATUS): ISC_STATUS; stdcall;
begin
  // No console in a GUI process; keep the status for the caller.
  if st = nil then
    Result := 0
  else
    Result := PISC_STATUS(PByte(st) + 4)^;
end;

{ date helpers: same algorithms as Firebird (NoThrowTimeStamp) }

const
  ISC_TIME_SECONDS_PRECISION = 10000;
  MJD_OFFSET = 1721119 - 2400001; // ISC_DATE day 0 = 17 Nov 1858

function EncodeDay(Year, Month, Day: Integer): Integer;
var
  c, ya: Integer;
begin
  if Month > 2 then
    Dec(Month, 3)
  else
  begin
    Inc(Month, 9);
    Dec(Year);
  end;
  c := Year div 100;
  ya := Year - 100 * c;
  Result := Integer((Int64(146097) * c) div 4 + (1461 * ya) div 4 + (153 * Month + 2) div 5 + Day + MJD_OFFSET);
end;

procedure DecodeDay(nday: Integer; tm: PCTm);
var
  orig, century, day, month, year: Integer;
begin
  orig := nday;
  nday := nday - MJD_OFFSET;
  century := (4 * nday - 1) div 146097;
  nday := 4 * nday - 1 - 146097 * century;
  day := nday div 4;
  nday := (4 * day + 3) div 1461;
  day := 4 * day + 3 - 1461 * nday;
  day := (day + 4) div 4;
  month := (5 * day - 3) div 153;
  day := 5 * day - 3 - 153 * month;
  day := (day + 5) div 5;
  year := 100 * century + nday;
  if month < 10 then
    Inc(month, 3)
  else
  begin
    Dec(month, 9);
    Inc(year);
  end;
  tm^.tm_mday := day;
  tm^.tm_mon := month - 1;
  tm^.tm_year := year - 1900;
  tm^.tm_wday := ((orig + 3) mod 7 + 7) mod 7;
  tm^.tm_yday := orig - EncodeDay(year, 1, 1);
  tm^.tm_isdst := -1;
end;

procedure DecodeTime(t: ISC_TIME; tm: PCTm);
var
  minutes: Cardinal;
begin
  minutes := t div (ISC_TIME_SECONDS_PRECISION * 60);
  tm^.tm_hour := minutes div 60;
  tm^.tm_min := minutes mod 60;
  tm^.tm_sec := (t div ISC_TIME_SECONDS_PRECISION) mod 60;
end;

function EncodeTime(tm: PCTm): ISC_TIME;
begin
  Result := ((tm^.tm_hour * 60 + tm^.tm_min) * 60 + tm^.tm_sec) * ISC_TIME_SECONDS_PRECISION;
end;

procedure W_isc_decode_sql_date(d: PISC_DATE; tm: PCTm); stdcall;
begin
  if (d = nil) or (tm = nil) then
    Exit;
  FillChar(tm^, SizeOf(tm^), 0);
  DecodeDay(d^, tm);
end;

procedure W_isc_encode_sql_date(tm: PCTm; d: PISC_DATE); stdcall;
begin
  if (d <> nil) and (tm <> nil) then
    d^ := EncodeDay(tm^.tm_year + 1900, tm^.tm_mon + 1, tm^.tm_mday);
end;

procedure W_isc_decode_sql_time(t: PISC_TIME; tm: PCTm); stdcall;
begin
  if (t = nil) or (tm = nil) then
    Exit;
  FillChar(tm^, SizeOf(tm^), 0);
  DecodeTime(t^, tm);
end;

procedure W_isc_encode_sql_time(tm: PCTm; t: PISC_TIME); stdcall;
begin
  if (t <> nil) and (tm <> nil) then
    t^ := EncodeTime(tm);
end;

procedure W_isc_decode_timestamp(ts: PISC_TIMESTAMP; tm: PCTm); stdcall;
begin
  if (ts = nil) or (tm = nil) then
    Exit;
  FillChar(tm^, SizeOf(tm^), 0);
  DecodeDay(ts^.timestamp_date, tm);
  DecodeTime(ts^.timestamp_time, tm);
end;

procedure W_isc_encode_timestamp(tm: PCTm; ts: PISC_TIMESTAMP); stdcall;
begin
  if (ts = nil) or (tm = nil) then
    Exit;
  ts^.timestamp_date := EncodeDay(tm^.tm_year + 1900, tm^.tm_mon + 1, tm^.tm_mday);
  ts^.timestamp_time := EncodeTime(tm);
end;

// ISC_QUAD here holds an ISC_TIMESTAMP (legacy date API).
procedure W_isc_decode_date(q: PISC_QUAD; tm: PCTm); stdcall;
begin
  W_isc_decode_timestamp(PISC_TIMESTAMP(q), tm);
end;

procedure W_isc_encode_date(tm: PCTm; q: PISC_QUAD); stdcall;
begin
  W_isc_encode_timestamp(tm, PISC_TIMESTAMP(q));
end;

function NotSupported(st: PISC_STATUS): ISC_STATUS; stdcall;
begin
  try
    SetStatusCode(st, isc_wish_list, 'not supported by ws-fbclient');
  except
  end;
  Result := isc_wish_list;
end;

function W_ws_fbclient_stats(Stats: PWsFbStats): Integer; stdcall;
var
  g: TWsFbStats;
  n: Cardinal;
begin
  Result := 0;
  if Stats = nil then
    Exit;
  g := GlobalStats;
  n := Stats^.Size;
  if n > SizeOf(g) then
    n := SizeOf(g);
  Move(g, Stats^, n);
  Stats^.Size := n;
end;

initialization
  GAttachments := TList<TFbAttachment>.Create;
  GAttLock := TCriticalSection.Create;
  GStop := TEvent.Create(nil, True, False, '');

finalization
  // Do not wait for the keep-alive thread: this runs under the loader lock.
  GStop.SetEvent;
end.
