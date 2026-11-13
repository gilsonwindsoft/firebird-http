unit fbproxy.Core;

{ Logging proxy core: loads the real fbclient.dll, writes one log line per
  call and returns the real entry point to the asm stubs.

  Configuration (environment variables, optional):
    FBPROXY_REAL  full path of the real client library
                  (default: fbclient.dll in the proxy folder)
    FBPROXY_LOG   log file (default: fbclient_proxy.log in the proxy folder)

  The log never contains passwords. SQL text is logged (needed for the
  API survey); do not run the proxy against production data you cannot log.
  ASCII only (Windows-1252 safe). }

interface

uses
  Winapi.Windows, fbhttp.IBase;

type
  TNameArray = array of PAnsiChar;

procedure ProxyInit(const Names: TNameArray);
function Hook(Index: Integer; Frame: PByte): Pointer; stdcall;
function RealProc(const Name: AnsiString): Pointer;

// Typed wrappers: they log the output XSQLDA and the status after the call.
function W_isc_dsql_prepare(st: PISC_STATUS; tr, stmt: PFB_API_HANDLE; len: Word;
  sql: PAnsiChar; dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
function W_isc_dsql_describe(st: PISC_STATUS; stmt: PFB_API_HANDLE; dialect: Word;
  da: PXSQLDA): ISC_STATUS; stdcall;
function W_isc_dsql_describe_bind(st: PISC_STATUS; stmt: PFB_API_HANDLE; dialect: Word;
  da: PXSQLDA): ISC_STATUS; stdcall;
function W_isc_attach_database(st: PISC_STATUS; namelen: SmallInt; name: PAnsiChar;
  db: PFB_API_HANDLE; dpblen: SmallInt; dpb: PAnsiChar): ISC_STATUS; stdcall;

implementation

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  System.Math, System.AnsiStrings;

var
  GNames: TNameArray;
  GProcs: array of Pointer;
  GCounts: array of Integer;
  GLib: HMODULE;
  GLog: THandle = INVALID_HANDLE_VALUE;
  GLock: TCriticalSection;
  GStart: UInt64;
  // per statement handle: fetch calls since the last execute
  GFetches: TDictionary<FB_API_HANDLE, Integer>;
  // per blob handle: segment calls and bytes
  GSegCalls: TDictionary<FB_API_HANDLE, Integer>;
  GSegBytes: TDictionary<FB_API_HANDLE, Int64>;

function ModuleDir: string;
var
  buf: array[0..MAX_PATH] of Char;
begin
  SetString(Result, buf, GetModuleFileName(HInstance, buf, Length(buf)));
  Result := ExtractFilePath(Result);
end;

procedure WriteLine(const S: AnsiString);
var
  line: AnsiString;
  written: DWORD;
begin
  if GLog = INVALID_HANDLE_VALUE then
    Exit;
  line := AnsiString(Format('%.3f t%d ', [(GetTickCount64 - GStart) / 1000, GetCurrentThreadId])) + S + #13#10;
  GLock.Enter;
  try
    WriteFile(GLog, PAnsiChar(line)^, Length(line), written, nil);
  finally
    GLock.Leave;
  end;
end;

function Arg(Frame: PByte; i: Integer): NativeUInt; inline;
begin
  // Frame points at the caller return address; arguments follow it.
  Result := PNativeUInt(Frame + 4 + 4 * i)^;
end;

function Hex(P: PByte; Len: Integer; Limit: Integer = 256): AnsiString;
const
  Digits: array[0..15] of AnsiChar = '0123456789ABCDEF';
var
  i: Integer;
begin
  Result := '';
  if (P = nil) or (Len <= 0) then
    Exit('-');
  for i := 0 to Min(Len, Limit) - 1 do
  begin
    Result := Result + Digits[P[i] shr 4] + Digits[P[i] and 15];
    if i < Min(Len, Limit) - 1 then
      Result := Result + ' ';
  end;
  if Len > Limit then
    Result := Result + AnsiString(Format(' ...(%d bytes)', [Len]));
end;

function Bytes(P: PAnsiChar; Len: Integer; Limit: Integer = 4000): AnsiString;
begin
  if P = nil then
    Exit('<nil>');
  if Len <= 0 then
    Len := System.AnsiStrings.StrLen(P);
  SetString(Result, P, Min(Len, Limit));
  if Len > Limit then
    Result := Result + AnsiString(Format('...(%d bytes)', [Len]));
end;

// Clumplet list "tag=value" for version1 parameter blocks (DPB/TPB/BPB).
// Passwords are masked. Wide (version2) blocks are logged as hex.
function ParamBlock(P: PByte; Len: Integer; IsDpb: Boolean): AnsiString;
var
  i, n: Integer;
  tag: Byte;
  val: AnsiString;
begin
  if (P = nil) or (Len <= 0) then
    Exit('-');
  if IsDpb and (P[0] <> isc_dpb_version1) then
    Exit('v' + AnsiString(IntToStr(P[0])) + ' ' + Hex(P, Len, 0) + AnsiString(Format('(%d bytes)', [Len])));
  Result := 'v' + AnsiString(IntToStr(P[0]));
  i := 1;
  while i < Len do
  begin
    tag := P[i];
    if not IsDpb then
    begin
      // TPB/BPB: most tags have no value; isc_tpb_lock_read/write (10/11)
      // and BPB tags carry a length byte.
      Result := Result + ' ' + AnsiString(IntToStr(tag));
      Inc(i);
      Continue;
    end;
    if i + 1 >= Len then
      Break;
    n := P[i + 1];
    if (tag = isc_dpb_password) or (tag = isc_dpb_password_enc) then
      val := '***'
    else if tag in [isc_dpb_user_name, isc_dpb_lc_ctype, isc_dpb_sql_role_name, 63 {process_name}, 79 {utf8_filename}, 90 {auth_plugin_list}] then
      SetString(val, PAnsiChar(@P[i + 2]), n)
    else
      val := Hex(@P[i + 2], n, 16);
    Result := Result + AnsiString(Format(' %d=', [tag])) + val;
    Inc(i, 2 + n);
  end;
end;

function DescribeDA(da: PXSQLDA; WithNames: Boolean): AnsiString;
var
  i: Integer;
  v: PXSQLVAR;
  s: AnsiString;
begin
  if da = nil then
    Exit('nil');
  Result := AnsiString(Format('sqln=%d sqld=%d', [da^.sqln, da^.sqld]));
  for i := 0 to Min(da^.sqld, da^.sqln) - 1 do
  begin
    v := SqlVar(da, i);
    Result := Result + AnsiString(Format(' [%d:%d/%d/%d/%d', [i, v^.sqltype, v^.sqlsubtype, v^.sqlscale, v^.sqllen]));
    if WithNames then
    begin
      SetString(s, v^.aliasname, Min(Max(v^.aliasname_length, 0), 32));
      Result := Result + ' ' + s;
    end;
    Result := Result + ']';
  end;
end;

function DescribeTeb(teb: PISC_TEB; Count: Integer): AnsiString;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to Count - 1 do
  begin
    Result := Result + AnsiString(Format(' db#%d tpb=', [i])) + ParamBlock(PByte(teb^.tpb_ptr), teb^.tpb_len, False);
    Inc(teb);
  end;
end;

function StatusText(st: PISC_STATUS): AnsiString;
var
  p: PISC_STATUS;
  i: Integer;
  tag: ISC_STATUS;
begin
  if st = nil then
    Exit('ok');
  p := st;
  if (PISC_STATUS(PByte(p) + 4)^ = 0) then
    Exit('ok');
  // Walk "tag value" pairs; isc_arg_cstring has two values.
  Result := 'ERROR';
  i := 0;
  while i < 20 do
  begin
    tag := PISC_STATUS(PByte(p) + 4 * i)^;
    if tag = isc_arg_end then
      Break;
    if (tag = isc_arg_string) or (tag = isc_arg_interpreted) or (tag = isc_arg_sql_state) then
      Result := Result + ' ' + AnsiString(PAnsiChar(PISC_STATUS(PByte(p) + 4 * (i + 1))^))
    else if tag = isc_arg_cstring then
    begin
      Result := Result + ' ' + Bytes(PAnsiChar(PISC_STATUS(PByte(p) + 4 * (i + 2))^), PISC_STATUS(PByte(p) + 4 * (i + 1))^);
      Inc(i);
    end
    else
      Result := Result + ' ' + AnsiString(IntToStr(PISC_STATUS(PByte(p) + 4 * (i + 1))^));
    Inc(i, 2);
  end;
end;

procedure CountFetch(stmt: FB_API_HANDLE; Reset: Boolean; out Before: Integer);
begin
  GLock.Enter;
  try
    if not GFetches.TryGetValue(stmt, Before) then
      Before := 0;
    if Reset then
      GFetches.Remove(stmt)
    else
      GFetches.AddOrSetValue(stmt, Before + 1);
  finally
    GLock.Leave;
  end;
end;

procedure CountSegment(blob: FB_API_HANDLE; Size: Integer);
var
  c: Integer;
  b: Int64;
begin
  GLock.Enter;
  try
    if not GSegCalls.TryGetValue(blob, c) then
      c := 0;
    if not GSegBytes.TryGetValue(blob, b) then
      b := 0;
    GSegCalls.AddOrSetValue(blob, c + 1);
    GSegBytes.AddOrSetValue(blob, b + Size);
  finally
    GLock.Leave;
  end;
end;

function TakeSegments(blob: FB_API_HANDLE): AnsiString;
var
  c: Integer;
  b: Int64;
begin
  GLock.Enter;
  try
    if not GSegCalls.TryGetValue(blob, c) then
      c := 0;
    if not GSegBytes.TryGetValue(blob, b) then
      b := 0;
    GSegCalls.Remove(blob);
    GSegBytes.Remove(blob);
  finally
    GLock.Leave;
  end;
  Result := AnsiString(Format(' segment_calls=%d buffer_bytes=%d', [c, b]));
end;

function Handle(Frame: PByte; i: Integer): FB_API_HANDLE;
var
  p: PFB_API_HANDLE;
begin
  p := PFB_API_HANDLE(Arg(Frame, i));
  if p = nil then
    Result := 0
  else
    Result := p^;
end;

// Details per function, decoded from the stack before the real call.
function Details(const Name: AnsiString; Frame: PByte): AnsiString;
var
  n: Integer;
begin
  Result := '';
  if Name = 'isc_start_transaction' then
    // cdecl varargs: status, tr*, count, then (db*, tpb_len, tpb) per database
    Result := AnsiString(Format(' count=%d', [SmallInt(Arg(Frame, 2))])) + ' tpb=' +
      ParamBlock(PByte(Arg(Frame, 5)), SmallInt(Arg(Frame, 4)), False)
  else if Name = 'isc_start_multiple' then
    Result := AnsiString(Format(' count=%d', [SmallInt(Arg(Frame, 2))])) +
      DescribeTeb(PISC_TEB(Arg(Frame, 3)), SmallInt(Arg(Frame, 2)))
  else if (Name = 'isc_commit_transaction') or (Name = 'isc_rollback_transaction') or
    (Name = 'isc_commit_retaining') or (Name = 'isc_rollback_retaining') then
    Result := AnsiString(Format(' tr=%d', [Handle(Frame, 1)]))
  else if Name = 'isc_dsql_allocate_statement' then
    Result := AnsiString(Format(' db=%d', [Handle(Frame, 1)]))
  else if Name = 'isc_dsql_alloc_statement2' then
    Result := AnsiString(Format(' db=%d', [Handle(Frame, 1)]))
  else if Name = 'isc_dsql_execute' then
  begin
    CountFetch(Handle(Frame, 2), True, n);
    Result := AnsiString(Format(' tr=%d stmt=%d dialect=%d in=', [Handle(Frame, 1), Handle(Frame, 2), Word(Arg(Frame, 3))])) +
      DescribeDA(PXSQLDA(Arg(Frame, 4)), False);
    if n > 0 then
      Result := Result + AnsiString(Format(' previous_fetch_calls=%d', [n]));
  end
  else if Name = 'isc_dsql_execute2' then
  begin
    CountFetch(Handle(Frame, 2), True, n);
    Result := AnsiString(Format(' tr=%d stmt=%d dialect=%d in=', [Handle(Frame, 1), Handle(Frame, 2), Word(Arg(Frame, 3))])) +
      DescribeDA(PXSQLDA(Arg(Frame, 4)), False) + ' out=' + DescribeDA(PXSQLDA(Arg(Frame, 5)), False);
  end
  else if Name = 'isc_dsql_fetch' then
  begin
    CountFetch(Handle(Frame, 1), False, n);
    if n = 0 then // first fetch after execute: the client output layout
      Result := AnsiString(Format(' stmt=%d first_fetch out=', [Handle(Frame, 1)])) + DescribeDA(PXSQLDA(Arg(Frame, 3)), False)
    else
      Result := '#quiet';
  end
  else if Name = 'isc_dsql_free_statement' then
  begin
    CountFetch(Handle(Frame, 1), True, n);
    Result := AnsiString(Format(' stmt=%d option=%d fetch_calls=%d', [Handle(Frame, 1), Word(Arg(Frame, 2)), n]));
  end
  else if (Name = 'isc_dsql_execute_immediate') or (Name = 'isc_dsql_exec_immed2') then
  begin
    Result := AnsiString(Format(' db=%d tr=%d dialect=%d sql=', [Handle(Frame, 1), Handle(Frame, 2), Word(Arg(Frame, 5))])) +
      Bytes(PAnsiChar(Arg(Frame, 4)), Word(Arg(Frame, 3))) + ' in=' + DescribeDA(PXSQLDA(Arg(Frame, 6)), False);
    if Name = 'isc_dsql_exec_immed2' then
      Result := Result + ' out=' + DescribeDA(PXSQLDA(Arg(Frame, 7)), False);
  end
  else if Name = 'isc_dsql_set_cursor_name' then
    Result := AnsiString(Format(' stmt=%d name=', [Handle(Frame, 1)])) + Bytes(PAnsiChar(Arg(Frame, 2)), 0)
  else if Name = 'isc_dsql_sql_info' then
    Result := AnsiString(Format(' stmt=%d items=', [Handle(Frame, 1)])) +
      Hex(PByte(Arg(Frame, 3)), SmallInt(Arg(Frame, 2))) + AnsiString(Format(' buflen=%d', [SmallInt(Arg(Frame, 4))]))
  else if Name = 'isc_database_info' then
    Result := AnsiString(Format(' db=%d items=', [Handle(Frame, 1)])) +
      Hex(PByte(Arg(Frame, 3)), SmallInt(Arg(Frame, 2))) + AnsiString(Format(' buflen=%d', [SmallInt(Arg(Frame, 4))]))
  else if Name = 'isc_transaction_info' then
    Result := AnsiString(Format(' tr=%d items=', [Handle(Frame, 1)])) +
      Hex(PByte(Arg(Frame, 3)), SmallInt(Arg(Frame, 2))) + AnsiString(Format(' buflen=%d', [SmallInt(Arg(Frame, 4))]))
  else if Name = 'isc_blob_info' then
    Result := AnsiString(Format(' blob=%d items=', [Handle(Frame, 1)])) +
      Hex(PByte(Arg(Frame, 3)), SmallInt(Arg(Frame, 2))) + AnsiString(Format(' buflen=%d', [SmallInt(Arg(Frame, 4))]))
  else if Name = 'isc_open_blob2' then
    Result := AnsiString(Format(' db=%d tr=%d bpb=', [Handle(Frame, 1), Handle(Frame, 2)])) +
      Hex(PByte(Arg(Frame, 6)), Word(Arg(Frame, 5)))
  else if Name = 'isc_create_blob2' then
    Result := AnsiString(Format(' db=%d tr=%d bpb=', [Handle(Frame, 1), Handle(Frame, 2)])) +
      Hex(PByte(Arg(Frame, 6)), SmallInt(Arg(Frame, 5)))
  else if Name = 'isc_get_segment' then
  begin
    CountSegment(Handle(Frame, 1), Word(Arg(Frame, 3)));
    Result := '#quiet';
  end
  else if Name = 'isc_put_segment' then
  begin
    CountSegment(Handle(Frame, 1), Word(Arg(Frame, 2)));
    Result := '#quiet';
  end
  else if (Name = 'isc_close_blob') or (Name = 'isc_cancel_blob') then
    Result := AnsiString(Format(' blob=%d', [Handle(Frame, 1)])) + TakeSegments(Handle(Frame, 1))
  else if Name = 'isc_detach_database' then
    Result := AnsiString(Format(' db=%d', [Handle(Frame, 1)]))
  else if Name = 'isc_expand_dpb' then
    Result := ' (varargs, not decoded)';
end;

procedure Count(Index: Integer);
begin
  if (Index >= 0) and (Index < Length(GCounts)) then
    InterlockedIncrement(GCounts[Index]);
end;

function IndexOfName(const Name: AnsiString): Integer;
var
  i: Integer;
begin
  for i := 0 to High(GNames) do
    if AnsiString(GNames[i]) = Name then
      Exit(i);
  Result := -1;
end;

var
  GRealPath: string;
  GLoaded: Boolean;

procedure ProxyInit(const Names: TNameArray);
var
  dir, logName: string;
begin
  // Runs under the loader lock: only open the log here. The real library
  // is loaded on the first call (EnsureLoaded).
  GNames := Names;
  SetLength(GProcs, Length(Names));
  SetLength(GCounts, Length(Names));
  GStart := GetTickCount64;
  dir := ModuleDir;
  // Real library: FBPROXY_REAL, else fbclient_real.dll (proxy installed as
  // fbclient.dll), else fbclient.dll (proxy installed as fbclient_proxy.dll).
  GRealPath := GetEnvironmentVariable('FBPROXY_REAL');
  if (GRealPath = '') and FileExists(dir + 'fbclient_real.dll') then
    GRealPath := dir + 'fbclient_real.dll';
  if GRealPath = '' then
    GRealPath := dir + 'fbclient.dll';
  logName := GetEnvironmentVariable('FBPROXY_LOG');
  if logName = '' then
    logName := dir + 'fbclient_proxy.log';
  GLog := CreateFile(PChar(logName), FILE_APPEND_DATA, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
    OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  WriteLine('=== proxy loaded, real library: ' + AnsiString(GRealPath) + ', process: ' + AnsiString(ParamStr(0)));
end;

procedure EnsureLoaded;
var
  i, missing: Integer;
  lib: HMODULE;
begin
  if GLoaded then
    Exit;
  GLock.Enter;
  try
    if GLoaded then
      Exit;
    lib := LoadLibrary(PChar(GRealPath));
    if lib = HInstance then
    begin
      // Loading ourselves would make every stub call itself forever.
      FreeLibrary(lib);
      WriteLine('FATAL real library is the proxy itself; set FBPROXY_REAL or use fbclient_real.dll');
      Exit;
    end;
    if lib = 0 then
    begin
      WriteLine(AnsiString(Format('FATAL cannot load real library (error %d)', [GetLastError])));
      Exit;
    end;
    missing := 0;
    for i := 0 to High(GNames) do
    begin
      GProcs[i] := GetProcAddress(lib, GNames[i]);
      if GProcs[i] = nil then
      begin
        Inc(missing);
        WriteLine('note: real library does not export ' + AnsiString(GNames[i]));
      end;
    end;
    WriteLine(AnsiString(Format('resolved %d of %d exports', [Length(GNames) - missing, Length(GNames)])));
    GLib := lib;
    MemoryBarrier;
    GLoaded := True;
  finally
    GLock.Leave;
  end;
end;

function RealProc(const Name: AnsiString): Pointer;
begin
  Result := GetProcAddress(GLib, PAnsiChar(Name));
end;

function Hook(Index: Integer; Frame: PByte): Pointer; stdcall;
var
  name, det: AnsiString;
begin
  EnsureLoaded;
  name := AnsiString(GNames[Index]);
  Count(Index);
  try
    det := Details(name, Frame);
  except
    on E: Exception do
      det := ' (decode error: ' + AnsiString(E.Message) + ')';
  end;
  if det <> '#quiet' then
    WriteLine(name + det);
  Result := GProcs[Index];
  if Result = nil then
    WriteLine('FATAL real library does not export ' + name);
end;

type
  TPrepare = function(st: PISC_STATUS; tr, stmt: PFB_API_HANDLE; len: Word; sql: PAnsiChar;
    dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
  TDescribe = function(st: PISC_STATUS; stmt: PFB_API_HANDLE; dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
  TAttach = function(st: PISC_STATUS; namelen: SmallInt; name: PAnsiChar; db: PFB_API_HANDLE;
    dpblen: SmallInt; dpb: PAnsiChar): ISC_STATUS; stdcall;

function W_isc_dsql_prepare(st: PISC_STATUS; tr, stmt: PFB_API_HANDLE; len: Word;
  sql: PAnsiChar; dialect: Word; da: PXSQLDA): ISC_STATUS; stdcall;
var
  i: Integer;
begin
  EnsureLoaded;
  i := IndexOfName('isc_dsql_prepare');
  Count(i);
  WriteLine(AnsiString(Format('isc_dsql_prepare tr=%d stmt=%d dialect=%d sql=', [tr^, stmt^, dialect])) + Bytes(sql, len));
  Result := TPrepare(GProcs[i])(st, tr, stmt, len, sql, dialect, da);
  WriteLine('  -> isc_dsql_prepare ' + StatusText(st) + ' described out=' + DescribeDA(da, True));
end;

function W_isc_dsql_describe(st: PISC_STATUS; stmt: PFB_API_HANDLE; dialect: Word;
  da: PXSQLDA): ISC_STATUS; stdcall;
var
  i: Integer;
begin
  EnsureLoaded;
  i := IndexOfName('isc_dsql_describe');
  Count(i);
  Result := TDescribe(GProcs[i])(st, stmt, dialect, da);
  WriteLine(AnsiString(Format('isc_dsql_describe stmt=%d ', [stmt^])) + StatusText(st) + ' out=' + DescribeDA(da, True));
end;

function W_isc_dsql_describe_bind(st: PISC_STATUS; stmt: PFB_API_HANDLE; dialect: Word;
  da: PXSQLDA): ISC_STATUS; stdcall;
var
  i: Integer;
begin
  EnsureLoaded;
  i := IndexOfName('isc_dsql_describe_bind');
  Count(i);
  Result := TDescribe(GProcs[i])(st, stmt, dialect, da);
  WriteLine(AnsiString(Format('isc_dsql_describe_bind stmt=%d ', [stmt^])) + StatusText(st) + ' in=' + DescribeDA(da, True));
end;

function W_isc_attach_database(st: PISC_STATUS; namelen: SmallInt; name: PAnsiChar;
  db: PFB_API_HANDLE; dpblen: SmallInt; dpb: PAnsiChar): ISC_STATUS; stdcall;
var
  i: Integer;
begin
  EnsureLoaded;
  i := IndexOfName('isc_attach_database');
  Count(i);
  WriteLine('isc_attach_database name=' + Bytes(name, namelen) + ' dpb=' + ParamBlock(PByte(dpb), dpblen, True));
  Result := TAttach(GProcs[i])(st, namelen, name, db, dpblen, dpb);
  WriteLine(AnsiString(Format('  -> isc_attach_database db=%d ', [db^])) + StatusText(st));
end;

procedure WriteSummary;
var
  i: Integer;
begin
  WriteLine('=== summary: calls per function (only called functions)');
  for i := 0 to High(GNames) do
    if GCounts[i] > 0 then
      WriteLine(AnsiString(Format('summary %s %d', [GNames[i], GCounts[i]])));
end;

initialization
  GLock := TCriticalSection.Create;
  GFetches := TDictionary<FB_API_HANDLE, Integer>.Create;
  GSegCalls := TDictionary<FB_API_HANDLE, Integer>.Create;
  GSegBytes := TDictionary<FB_API_HANDLE, Int64>.Create;

finalization
  WriteSummary;
  if GLog <> INVALID_HANDLE_VALUE then
    CloseHandle(GLog);
  // GLib is not freed: other threads may still be inside real calls at exit.
end.
