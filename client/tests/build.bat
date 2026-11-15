@echo off
rem Builds and runs the DUnitX tests (Win32). Run from a "RAD Studio Command Prompt".
rem Protocol fixtures: run "go test ./internal/protocol" in gateway\ first
rem (or the docker test compose), which writes tests\protocol-fixtures\.
setlocal
cd /d "%~dp0"
if not exist ..\bin\tests mkdir ..\bin\tests
if not exist ..\bin\dcu\tests mkdir ..\bin\dcu\tests
dcc32 -B -Q -NSSystem;Winapi;System.Win -E..\bin\tests -NU..\bin\dcu\tests -U"%BDS%\source\DUnitX" fbhttpTests.dpr || exit /b 1
rem TestTransport checks the per-request diagnostic log.
set FBHTTP_DEBUG_LOG=%CD%\..\bin\tests\ws-fbclient-debug.log
..\bin\tests\fbhttpTests.exe
