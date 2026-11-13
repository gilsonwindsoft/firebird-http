@echo off
rem Builds ws-fbclient.dll (Win32). Run from a "RAD Studio Command Prompt".
rem If src\fbhttp.Client.pas exports change: python ..\tools\gen_wsfbclient.py
setlocal
cd /d "%~dp0"
if not exist ..\bin\ws-fbclient mkdir ..\bin\ws-fbclient
if not exist ..\bin\dcu\ws-fbclient mkdir ..\bin\dcu\ws-fbclient
dcc32 -B -Q -NSSystem;Winapi;System.Win -E..\bin\ws-fbclient -NU..\bin\dcu\ws-fbclient wsfbclient.dpr || goto :fail
rem Pascal project names cannot contain '-': rename the output.
move /y ..\bin\ws-fbclient\wsfbclient.dll ..\bin\ws-fbclient\ws-fbclient.dll >nul || goto :fail
copy /y ws-fbclient.example.ini ..\bin\ws-fbclient\ws-fbclient.example.ini >nul
echo OK: ..\bin\ws-fbclient\ws-fbclient.dll
exit /b 0
:fail
echo BUILD FAILED
exit /b 1
