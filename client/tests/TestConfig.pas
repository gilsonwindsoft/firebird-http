unit TestConfig;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TConfigTests = class
  public
    [Test] procedure MissingUrlNamesTheIniFile;
    [Test] procedure EnvironmentWinsOverIni;
    [Test] procedure PlainHttpNeedsOptIn;
    [Test] procedure GatewayFromDatabaseHost;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, fbhttp.Config;

function EmptyEnv(const Name: string): string;
begin
  Result := '';
end;

procedure TConfigTests.MissingUrlNamesTheIniFile;
var
  c: TFbHttpConfig;
begin
  c := LoadConfig('C:\nowhere\ws-fbclient.ini', EmptyEnv);
  Assert.Contains(c.Validate, 'ws-fbclient.ini');
  Assert.Contains(c.Validate, 'FBHTTP_URL');
end;

procedure TConfigTests.EnvironmentWinsOverIni;
var
  ini: string;
  c: TFbHttpConfig;
begin
  ini := TPath.Combine(TPath.GetTempPath, 'fbhttp-test.ini');
  TFile.WriteAllText(ini, '[gateway]'#13#10'url=https://ini.example/'#13#10'fetch_rows=50'#13#10);
  try
    c := LoadConfig(ini,
      function(const Name: string): string
      begin
        if Name = 'FBHTTP_URL' then Result := 'https://env.example' else Result := '';
      end);
    Assert.AreEqual('https://env.example', c.Url);
    Assert.AreEqual(50, c.FetchRows);
    Assert.AreEqual(30 * 60 * 1000, c.ResponseTimeoutMs);
    Assert.AreEqual('', c.Validate);
  finally
    TFile.Delete(ini);
  end;
end;

procedure TConfigTests.PlainHttpNeedsOptIn;
var
  c: TFbHttpConfig;
begin
  c := LoadConfig('',
    function(const Name: string): string
    begin
      if Name = 'FBHTTP_URL' then Result := 'http://gw:8080' else Result := '';
    end);
  Assert.Contains(c.Validate, 'plain HTTP refused');
  c.AllowPlainHttp := True;
  Assert.AreEqual('', c.Validate);
end;

procedure TConfigTests.GatewayFromDatabaseHost;
begin
  Assert.AreEqual('https://fb.windsoft.me', GatewayUrlFromDatabase('fb.windsoft.me:ws-windsoft'));
  Assert.AreEqual('https://fb.windsoft.me', GatewayUrlFromDatabase('fb.windsoft.me/3151:/data/x.fdb'));
  Assert.AreEqual('https://10.0.0.5', GatewayUrlFromDatabase('10.0.0.5:C:\data\x.fdb'));
  Assert.AreEqual('', GatewayUrlFromDatabase('ws-windsoft'));
  Assert.AreEqual('', GatewayUrlFromDatabase('C:\data\x.fdb'));
  Assert.AreEqual('', GatewayUrlFromDatabase('inet://fb.windsoft.me/x.fdb'));
  Assert.AreEqual('', GatewayUrlFromDatabase(':x.fdb'));
end;

initialization
  TDUnitX.RegisterTestFixture(TConfigTests);
end.
