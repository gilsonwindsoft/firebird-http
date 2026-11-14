program fbcompare;

{ Comparison test (task 7.1) and timing (task 7.3).
  Runs a fixed script through TSQLConnection + Devart dbExpress driver and writes
  a deterministic text dump. Run it once with the native fbclient.dll and once
  with ws-fbclient.dll (renamed fbclient.dll) and compare the two dumps with fc.
  Needs tests\schema.sql (and tests\schema-fb4.sql on FB 4/5) loaded in the database.

  fbcompare.exe <database> <user> <password> <out.txt> [Name=Value ...]
  Extra Name=Value pairs go to TSQLConnection.Params (Charset, UseUnicode, ...).
  Timings go to <out.txt>.timing.txt (not compared). }

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.TypInfo,
  System.Hash,
  System.Diagnostics,
  Data.DB,
  Data.FMTBcd,
  Data.SqlExpr,
  Data.DBXCommon,
  Datasnap.DBClient,
  Datasnap.Provider,
  MidasLib,
  DbxDevartInterBase;

var
  Conn: TSQLConnection;
  Dump, Timing: TStreamWriter;
  Failures: Integer;

procedure W(const S: string);
begin
  Dump.WriteLine(S);
end;

function OneLine(const S: string): string;
begin
  Result := StringReplace(StringReplace(Trim(S), #13#10, ' | ', [rfReplaceAll]), #10, ' | ', [rfReplaceAll]);
end;

function BytesText(const B: TBytes): string;
var
  H: THashMD5;
  I: Integer;
begin
  if Length(B) <= 64 then
  begin
    Result := '';
    for I := 0 to High(B) do
      Result := Result + IntToHex(B[I], 2);
    Result := Format('len=%d hex=%s', [Length(B), Result]);
  end
  else
  begin
    H := THashMD5.Create;
    H.Update(B);
    Result := Format('len=%d md5=%s', [Length(B), H.HashAsString]);
  end;
end;

function FieldText(F: TField): string;
begin
  if F.IsNull then
    Exit('<NULL>');
  case F.DataType of
    ftDate:
      Result := FormatDateTime('yyyy-mm-dd', F.AsDateTime);
    ftTime:
      Result := FormatDateTime('hh:nn:ss.zzz', F.AsDateTime);
    ftDateTime, ftTimeStamp:
      Result := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', F.AsDateTime);
    ftFloat, ftSingle, ftExtended:
      Result := FloatToStr(F.AsFloat, TFormatSettings.Invariant);
    ftBlob, ftGraphic, ftBytes, ftVarBytes, ftTypedBinary:
      Result := BytesText(F.AsBytes);
    ftMemo, ftWideMemo, ftFmtMemo:
      Result := Format('len=%d text=%s', [Length(F.AsString), OneLine(F.AsString)]);
  else
    Result := '[' + F.AsString + ']';
  end;
end;

procedure DumpFields(DS: TDataSet);
var
  F: TField;
begin
  for F in DS.Fields do
    W(Format('  field %s %s size=%d', [F.FieldName, GetEnumName(TypeInfo(TFieldType), Ord(F.DataType)), F.Size]));
end;

procedure DumpRows(DS: TDataSet);
var
  F: TField;
  N: Integer;
begin
  N := 0;
  while not DS.Eof do
  begin
    Inc(N);
    W(Format('  row %d', [N]));
    for F in DS.Fields do
      W(Format('    %s=%s', [F.FieldName, FieldText(F)]));
    DS.Next;
  end;
  W(Format('  rows=%d', [N]));
end;

function NewQuery(const SQL: string): TSQLQuery;
begin
  Result := TSQLQuery.Create(nil);
  Result.SQLConnection := Conn;
  Result.SQL.Text := SQL;
end;

{ Opens SQL through TSQLQuery (unidirectional). }
procedure SelectDirect(const SQL: string);
var
  Q: TSQLQuery;
begin
  Q := NewQuery(SQL);
  try
    Q.Open;
    DumpFields(Q);
    DumpRows(Q);
  finally
    Q.Free;
  end;
end;

{ Opens SQL through TSQLQuery + TDataSetProvider + TClientDataSet, as the application does. }
procedure SelectClient(const SQL: string);
var
  Q: TSQLQuery;
  P: TDataSetProvider;
  C: TClientDataSet;
begin
  Q := NewQuery(SQL);
  P := TDataSetProvider.Create(nil);
  C := TClientDataSet.Create(nil);
  try
    P.DataSet := Q;
    C.SetProvider(P);
    C.Open;
    DumpFields(C);
    DumpRows(C);
  finally
    C.Free;
    P.Free;
    Q.Free;
  end;
end;

procedure Exec(const SQL: string);
var
  Q: TSQLQuery;
begin
  Q := NewQuery(SQL);
  try
    W(Format('  rowsaffected=%d', [Q.ExecSQL]));
  finally
    Q.Free;
  end;
end;

function TableExists(const Name: string): Boolean;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    Conn.GetTableNames(L, False);
    Result := L.IndexOf(Name) >= 0;
  finally
    L.Free;
  end;
end;

{ Runs one step; an exception is part of the expected output, not a failure. }
procedure Step(const Name: string; Proc: TProc);
var
  SW: TStopwatch;
begin
  W('== ' + Name);
  SW := TStopwatch.StartNew;
  try
    Proc;
  except
    on E: Exception do
      W('  error ' + E.ClassName + ': ' + OneLine(E.Message));
  end;
  Timing.WriteLine(Format('%-28s %8d ms', [Name, SW.ElapsedMilliseconds]));
  Timing.Flush;
end;

procedure Check(Cond: Boolean; const What: string);
begin
  if Cond then
    W('  ok ' + What)
  else
  begin
    W('  FAIL ' + What);
    Inc(Failures);
  end;
end;

procedure RunAll;
begin
  Step('metadata', procedure
    var
      L: TStringList;
      S: string;
    begin
      L := TStringList.Create;
      try
        Conn.GetTableNames(L, False);
        L.Sort;
        for S in L do
          if S.StartsWith('T_') then
            W('  table ' + S);
        Conn.GetFieldNames('T_TYPES', L);
        for S in L do
          W('  column ' + S);
      finally
        L.Free;
      end;
    end);

  Step('types direct', procedure begin SelectDirect('select * from T_TYPES order by ID') end);
  Step('types clientdataset', procedure begin SelectClient('select * from T_TYPES order by ID') end);

  if TableExists('T_TYPES_FB4') then
  begin
    Step('types fb4 direct', procedure begin SelectDirect('select * from T_TYPES_FB4 order by ID') end);
    Step('types fb4 clientdataset', procedure begin SelectClient('select * from T_TYPES_FB4 order by ID') end);
  end;

  // SUM(NUMERIC) is INT128 on FB 4/5 without set_bind; type must match the native client.
  Step('aggregates', procedure
    begin
      SelectDirect('select sum(C_NUM_18_4) S, count(*) N, cast(''2026-11-13 10:00:00'' as timestamp) T from T_TYPES');
    end);

  Step('params', procedure
    var
      Q: TSQLQuery;
    begin
      Q := NewQuery('select ID from T_TYPES where C_INTEGER = :A and C_VARCHAR_100 = :B and C_DATE = :C ' +
        'and C_NUM_9_2 = :D and C_BOOLEAN = :E');
      try
        Q.ParamByName('A').AsInteger := 123456;
        Q.ParamByName('B').AsString := 'texto simples';
        Q.ParamByName('C').AsDate := EncodeDate(2026, 11, 13);
        Q.ParamByName('D').AsFMTBCD := StrToBcd('1234.56', TFormatSettings.Invariant);
        Q.ParamByName('E').AsBoolean := True;
        Q.Open;
        DumpRows(Q);
      finally
        Q.Free;
      end;
    end);

  Step('procedure select', procedure begin SelectDirect('select count(*) N, sum(I) S from P_SERIES(1000)') end);
  Step('procedure execute', procedure begin SelectDirect('execute procedure P_ADD(2, 3)') end);

  Step('fetch 10000 rows', procedure
    var
      Q: TSQLQuery;
      N: Integer;
      Sum: Int64;
    begin
      Q := NewQuery('select I from P_SERIES(10000)');
      try
        Q.Open;
        N := 0;
        Sum := 0;
        while not Q.Eof do
        begin
          Inc(N);
          Inc(Sum, Q.Fields[0].AsInteger);
          Q.Next;
        end;
        W(Format('  rows=%d sum=%d', [N, Sum]));
      finally
        Q.Free;
      end;
    end);

  Step('error unknown table', procedure begin SelectDirect('select * from NO_SUCH_TABLE') end);
  Step('error syntax', procedure begin SelectDirect('selec 1 from RDB$DATABASE') end);
  Step('error conversion', procedure begin SelectDirect('select cast(''abc'' as integer) from RDB$DATABASE') end);

  Step('transactions', procedure
    var
      T: TDBXTransaction;
    begin
      Exec('delete from T_KV');
      T := Conn.BeginTransaction(TDBXIsolations.ReadCommitted);
      Exec('insert into T_KV values (1, ''rollback'')');
      Conn.RollbackFreeAndNil(T);
      SelectDirect('select count(*) N from T_KV');
      T := Conn.BeginTransaction(TDBXIsolations.ReadCommitted);
      Exec('insert into T_KV values (2, ''commit'')');
      Conn.CommitFreeAndNil(T);
      SelectDirect('select * from T_KV order by ID');
    end);

  Step('error primary key', procedure begin Exec('insert into T_KV values (2, ''dup'')') end);

  Step('clientdataset applyupdates', procedure
    var
      Q: TSQLQuery;
      P: TDataSetProvider;
      C: TClientDataSet;
    begin
      Q := NewQuery('select * from T_KV order by ID');
      P := TDataSetProvider.Create(nil);
      C := TClientDataSet.Create(nil);
      try
        Q.Open;
        Q.FieldByName('ID').ProviderFlags := [pfInUpdate, pfInWhere, pfInKey];
        P.DataSet := Q;
        P.UpdateMode := upWhereKeyOnly;
        C.SetProvider(P);
        C.Open;
        C.AppendRecord([3, 'cds insert']);
        C.First;
        C.Edit;
        C.FieldByName('V').AsString := 'cds update';
        C.Post;
        W(Format('  applyupdates errors=%d', [C.ApplyUpdates(0)]));
      finally
        C.Free;
        P.Free;
        Q.Free;
      end;
      SelectDirect('select * from T_KV order by ID');
    end);

  Step('blob 2 MB roundtrip', procedure
    var
      Q: TSQLQuery;
      B, Back: TBytes;
      Txt: string;
      I: Integer;
    begin
      SetLength(B, 2 * 1024 * 1024);
      for I := 0 to High(B) do
        B[I] := Byte(I * 31 + I shr 8);
      Txt := StringOfChar('x', 100000) + 'fim';
      Exec('delete from T_TYPES where ID = 100');
      Q := NewQuery('insert into T_TYPES (ID, C_BLOB_BIN, C_BLOB_TEXT) values (100, :B, :T)');
      try
        Q.ParamByName('B').DataType := ftBlob;
        Q.ParamByName('B').AsBytes := B;
        Q.ParamByName('T').AsMemo := Txt;
        Q.ExecSQL;
      finally
        Q.Free;
      end;
      Q := NewQuery('select C_BLOB_BIN, C_BLOB_TEXT from T_TYPES where ID = 100');
      try
        Q.Open;
        Back := Q.Fields[0].AsBytes;
        W('  ' + BytesText(Back));
        Check((Length(Back) = Length(B)) and CompareMem(@Back[0], @B[0], Length(B)), 'blob binary equal');
        Check(Q.Fields[1].AsString = Txt, 'blob text equal');
      finally
        Q.Free;
      end;
      Exec('delete from T_TYPES where ID = 100');
    end);
end;

{ Prints which client library the driver really loaded (console only, not compared). }
procedure ShowClientModules;
const
  Names: array[0..2] of string = ('fbclient.dll', 'gds32.dll', 'ws-fbclient.dll');
var
  Name: string;
  H: HMODULE;
  Buf: array[0..MAX_PATH] of Char;
begin
  for Name in Names do
  begin
    H := GetModuleHandle(PChar(Name));
    if H <> 0 then
    begin
      GetModuleFileName(H, Buf, Length(Buf));
      Writeln('  loaded ', string(Buf));
    end;
  end;
end;

var
  I: Integer;
  Total: TStopwatch;
begin
  if ParamCount < 4 then
  begin
    Writeln('fbcompare <database> <user> <password> <out.txt> [Name=Value ...]');
    Halt(2);
  end;
  FormatSettings := TFormatSettings.Invariant;
  Dump := TStreamWriter.Create(ParamStr(4), False, TEncoding.UTF8);
  Timing := TStreamWriter.Create(ParamStr(4) + '.timing.txt', False, TEncoding.UTF8);
  Conn := TSQLConnection.Create(nil);
  try
    Conn.LoginPrompt := False;
    Conn.DriverName := 'DevartInterBase';
    Conn.Params.Values['Database'] := ParamStr(1);
    Conn.Params.Values['User_Name'] := ParamStr(2);
    Conn.Params.Values['Password'] := ParamStr(3);
    // Full path: the driver must load the fbclient.dll next to this exe, not one from PATH or the dbxdrivers.ini default.
    Conn.Params.Values['LibraryName'] := 'dbexpida40.dll';
    Conn.Params.Values['VendorLib'] := ExtractFilePath(ParamStr(0)) + 'fbclient.dll';
    for I := 5 to ParamCount do
      Conn.Params.Values[Copy(ParamStr(I), 1, Pos('=', ParamStr(I)) - 1)] :=
        Copy(ParamStr(I), Pos('=', ParamStr(I)) + 1, MaxInt);
    Total := TStopwatch.StartNew;
    try
      try
        Conn.Open;
        Timing.WriteLine(Format('%-28s %8d ms', ['connect', Total.ElapsedMilliseconds]));
        RunAll;
        Conn.Close;
      finally
        ShowClientModules;
      end;
    except
      on E: Exception do
      begin
        W('FATAL ' + E.ClassName + ': ' + OneLine(E.Message));
        Inc(Failures);
      end;
    end;
    Timing.WriteLine(Format('%-28s %8d ms', ['total', Total.ElapsedMilliseconds]));
  finally
    Conn.Free;
    Timing.Free;
    Dump.Free;
  end;
  Writeln(Format('%s: failures=%d', [ParamStr(4), Failures]));
  if Failures > 0 then
    ExitCode := 1;
end.
