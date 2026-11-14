unit fbhttp.Config;

{ Client configuration: ws-fbclient.ini in the DLL folder, overridden by
  FBHTTP_* environment variables. Both are optional: without a url, the
  gateway is https://<host> taken from the connection's Database
  (host:alias or host/port:path). ASCII only.

  [gateway]
  url=https://gateway.example.com:8443
  connect_timeout_ms=10000
  response_timeout_ms=1800000
  fetch_rows=200
  inline_blob_bytes=65536
  keepalive_seconds=300
  allow_plain_http=0
  allow_invalid_certificate=0 }

interface

type
  TFbHttpConfig = record
    Url: string;
    ConnectTimeoutMs: Integer;
    ResponseTimeoutMs: Integer;
    FetchRows: Integer;
    InlineBlobBytes: Integer;
    KeepAliveSeconds: Integer;
    AllowPlainHttp: Boolean;
    AllowInvalidCertificate: Boolean;
    IniPath: string;
    // Empty when valid, otherwise a message for the application.
    function Validate: string;
  end;

  TEnvFunc = reference to function(const Name: string): string;

function LoadConfig(const IniPath: string; const Env: TEnvFunc): TFbHttpConfig;
function LoadDefaultConfig: TFbHttpConfig;
// 'https://host' from a Database string 'host[/port]:path', or '' when it
// has no host (local path, C:\ path, URL forms).
function GatewayUrlFromDatabase(const Database: string): string;

implementation

uses
  System.SysUtils, System.IniFiles, Winapi.Windows;

function LoadConfig(const IniPath: string; const Env: TEnvFunc): TFbHttpConfig;
var
  ini: TMemIniFile;

  function Str(const Key, EnvName, Default: string): string;
  begin
    Result := Env(EnvName);
    if (Result = '') and (ini <> nil) then
      Result := ini.ReadString('gateway', Key, Default);
    if Result = '' then
      Result := Default;
  end;

  function Int(const Key, EnvName: string; Default: Integer): Integer;
  begin
    Result := StrToIntDef(Str(Key, EnvName, ''), Default);
  end;

  function Bool(const Key, EnvName: string): Boolean;
  var
    v: string;
  begin
    v := LowerCase(Str(Key, EnvName, '0'));
    Result := (v = '1') or (v = 'true') or (v = 'yes');
  end;

begin
  ini := nil;
  if FileExists(IniPath) then
    ini := TMemIniFile.Create(IniPath);
  try
    Result.IniPath := IniPath;
    Result.Url := Str('url', 'FBHTTP_URL', '');
    while (Result.Url <> '') and (Result.Url[Length(Result.Url)] = '/') do
      Delete(Result.Url, Length(Result.Url), 1);
    Result.ConnectTimeoutMs := Int('connect_timeout_ms', 'FBHTTP_CONNECT_TIMEOUT_MS', 10000);
    Result.ResponseTimeoutMs := Int('response_timeout_ms', 'FBHTTP_RESPONSE_TIMEOUT_MS', 30 * 60 * 1000);
    Result.FetchRows := Int('fetch_rows', 'FBHTTP_FETCH_ROWS', 200);
    Result.InlineBlobBytes := Int('inline_blob_bytes', 'FBHTTP_INLINE_BLOB_BYTES', 64 * 1024);
    Result.KeepAliveSeconds := Int('keepalive_seconds', 'FBHTTP_KEEPALIVE_SECONDS', 300);
    Result.AllowPlainHttp := Bool('allow_plain_http', 'FBHTTP_ALLOW_PLAIN_HTTP');
    Result.AllowInvalidCertificate := Bool('allow_invalid_certificate', 'FBHTTP_ALLOW_INVALID_CERTIFICATE');
  finally
    ini.Free;
  end;
end;

function TFbHttpConfig.Validate: string;
var
  lower: string;
begin
  Result := '';
  lower := LowerCase(Url);
  if Url = '' then
    Result := Format('ws-fbclient: gateway URL not configured. Use host:database in the ' +
      'connection Database, url= in [gateway] of %s or the FBHTTP_URL environment variable.', [IniPath])
  else if lower.StartsWith('http://') and not AllowPlainHttp then
    Result := 'ws-fbclient: plain HTTP refused. Use https:// or set allow_plain_http=1 (test networks only).'
  else if not lower.StartsWith('https://') and not lower.StartsWith('http://') then
    Result := 'ws-fbclient: gateway URL must start with https://'
  else if (FetchRows < 1) or (ConnectTimeoutMs < 1) or (ResponseTimeoutMs < 1) or (InlineBlobBytes < 0) then
    Result := 'ws-fbclient: invalid numeric value in configuration';
end;

function GatewayUrlFromDatabase(const Database: string): string;
var
  p, i: Integer;
  host: string;
begin
  Result := '';
  p := Pos(':', Database);
  // No host, or a drive letter (C:\data\x.fdb).
  if p <= 2 then
    Exit;
  // URL forms (inet://host/path) are not host:path.
  if Copy(Database, p + 1, 2) = '//' then
    Exit;
  host := Copy(Database, 1, p - 1);
  i := Pos('/', host);
  if i > 0 then
    host := Copy(host, 1, i - 1); // host/port: the port is Firebird's, HTTPS uses 443
  if host = '' then
    Exit;
  for i := 1 to Length(host) do
    if not CharInSet(host[i], ['a'..'z', 'A'..'Z', '0'..'9', '.', '-']) then
      Exit;
  Result := 'https://' + host;
end;

function LoadDefaultConfig: TFbHttpConfig;
var
  buf: array[0..MAX_PATH] of Char;
  path: string;
begin
  SetString(path, buf, GetModuleFileName(HInstance, buf, Length(buf)));
  Result := LoadConfig(ExtractFilePath(path) + 'ws-fbclient.ini',
    function(const Name: string): string
    begin
      Result := GetEnvironmentVariable(Name);
    end);
end;

end.
