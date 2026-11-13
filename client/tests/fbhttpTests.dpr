program fbhttpTests;

{ DUnitX tests for the ws-fbclient.dll units that do not need the gateway.
  Build: build.bat (Win32 console). Run: ..\bin\tests\fbhttpTests.exe
  Protocol fixtures come from the Go tests (gateway: go test ./internal/protocol). }

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.TestFramework,
  fbhttp.IBase in '..\src\fbhttp.IBase.pas',
  fbhttp.Protocol in '..\src\fbhttp.Protocol.pas',
  fbhttp.Status in '..\src\fbhttp.Status.pas',
  fbhttp.Config in '..\src\fbhttp.Config.pas',
  fbhttp.Handles in '..\src\fbhttp.Handles.pas',
  TestProtocol in 'TestProtocol.pas',
  TestStatus in 'TestStatus.pas',
  TestConfig in 'TestConfig.pas';

var
  runner: ITestRunner;
  results: IRunResults;
begin
  ReportMemoryLeaksOnShutdown := True;
  runner := TDUnitX.CreateRunner;
  runner.UseRTTI := True;
  runner.AddLogger(TDUnitXConsoleLogger.Create(True));
  results := runner.Execute;
  if not results.AllPassed then
    System.ExitCode := 1;
end.
