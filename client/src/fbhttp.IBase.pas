unit fbhttp.IBase;

{ Firebird legacy client API types and constants (ibase.h), Win32 layout.
  Shared by the logging proxy and ws-fbclient.dll. ASCII only. }

interface

type
  ISC_STATUS = NativeInt;            // intptr_t
  PISC_STATUS = ^ISC_STATUS;
  PPISC_STATUS = ^PISC_STATUS;
  ISC_LONG = Integer;
  ISC_SHORT = SmallInt;
  ISC_USHORT = Word;
  FB_API_HANDLE = Cardinal;          // unsigned int (FB_API_VER >= 20)
  PFB_API_HANDLE = ^FB_API_HANDLE;
  PISC_SHORT = ^ISC_SHORT;

  ISC_QUAD = record
    gds_quad_high: Integer;
    gds_quad_low: Cardinal;
  end;
  PISC_QUAD = ^ISC_QUAD;

  // C layout: sizeof = 152 on Win32.
  XSQLVAR = record
    sqltype: ISC_SHORT;
    sqlscale: ISC_SHORT;
    sqlsubtype: ISC_SHORT;
    sqllen: ISC_SHORT;
    sqldata: PAnsiChar;
    sqlind: PISC_SHORT;
    sqlname_length: ISC_SHORT;
    sqlname: array[0..31] of AnsiChar;
    relname_length: ISC_SHORT;
    relname: array[0..31] of AnsiChar;
    ownname_length: ISC_SHORT;
    ownname: array[0..31] of AnsiChar;
    aliasname_length: ISC_SHORT;
    aliasname: array[0..31] of AnsiChar;
  end;
  PXSQLVAR = ^XSQLVAR;

  // C layout: sqlvar starts at offset 20 on Win32.
  XSQLDA = record
    version: ISC_SHORT;
    sqldaid: array[0..7] of AnsiChar;
    sqldabc: ISC_LONG;
    sqln: ISC_SHORT;
    sqld: ISC_SHORT;
    sqlvar: array[0..0] of XSQLVAR;
  end;
  PXSQLDA = ^XSQLDA;

  // isc_start_multiple
  ISC_TEB = record
    db_ptr: PFB_API_HANDLE;
    tpb_len: Integer;   // long
    tpb_ptr: PAnsiChar;
  end;
  PISC_TEB = ^ISC_TEB;

const
  SQLDA_VERSION1 = 1;

  SQL_TEXT = 452;
  SQL_VARYING = 448;
  SQL_SHORT = 500;
  SQL_LONG = 496;
  SQL_FLOAT = 482;
  SQL_DOUBLE = 480;
  SQL_D_FLOAT = 530;
  SQL_TIMESTAMP = 510;
  SQL_BLOB = 520;
  SQL_ARRAY = 540;
  SQL_QUAD = 550;
  SQL_TYPE_TIME = 560;
  SQL_TYPE_DATE = 570;
  SQL_INT64 = 580;
  SQL_BOOLEAN = 32764;
  SQL_NULL = 32766;

  isc_arg_end = 0;
  isc_arg_gds = 1;
  isc_arg_string = 2;
  isc_arg_cstring = 3;
  isc_arg_number = 4;
  isc_arg_interpreted = 5;
  isc_arg_warning = 18;
  isc_arg_sql_state = 19;

  isc_dpb_version1 = 1;
  isc_dpb_version2 = 2;
  isc_dpb_user_name = 28;
  isc_dpb_password = 29;
  isc_dpb_password_enc = 30;
  isc_dpb_lc_ctype = 48;
  isc_dpb_sql_role_name = 60;

  isc_info_end = 1;
  isc_info_truncated = 2;
  isc_info_sql_stmt_type = 21;
  isc_info_sql_records = 23;

  DSQL_close = 1;
  DSQL_drop = 2;
  DSQL_unprepare = 4;

  isc_bad_db_handle = 335544324;
  isc_bad_segstr_handle = 335544328;
  isc_bad_trans_handle = 335544332;
  isc_segment = 335544366;
  isc_segstr_eof = 335544367;
  isc_bad_stmt_handle = 335544485;
  isc_network_error = 335544721;
  isc_net_read_err = 335544726;
  isc_net_write_err = 335544727;
  isc_wish_list = 335544378;
  isc_random = 335544382;

function XSQLDA_LENGTH(n: Integer): Integer; inline;
function SqlVar(da: PXSQLDA; i: Integer): PXSQLVAR; inline;

implementation

function XSQLDA_LENGTH(n: Integer): Integer;
begin
  if n < 1 then
    n := 1;
  Result := SizeOf(XSQLDA) + (n - 1) * SizeOf(XSQLVAR);
end;

function SqlVar(da: PXSQLDA; i: Integer): PXSQLVAR;
begin
  Result := PXSQLVAR(PByte(@da^.sqlvar[0]) + i * SizeOf(XSQLVAR));
end;

initialization
  // Fail fast if the record layout ever differs from ibase.h on Win32.
  Assert(SizeOf(XSQLVAR) = 152, 'XSQLVAR layout');
  Assert(NativeInt(@PXSQLDA(nil)^.sqlvar) = 20, 'XSQLDA layout');
  Assert(SizeOf(ISC_STATUS) = 4, 'Win32 only');
end.
