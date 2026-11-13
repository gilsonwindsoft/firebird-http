@echo off
rem Builds the logging proxy (Win32). Run from a "RAD Studio Command Prompt"
rem (rsvars.bat already applied). Output: ..\bin\proxy\ and ..\bin\proxy-no-oo\
setlocal
cd /d "%~dp0"
if not exist ..\bin\proxy mkdir ..\bin\proxy
if not exist ..\bin\proxy-no-oo mkdir ..\bin\proxy-no-oo
if not exist ..\bin\dcu\proxy mkdir ..\bin\dcu\proxy
if not exist ..\bin\dcu\proxy-no-oo mkdir ..\bin\dcu\proxy-no-oo
dcc32 -B -Q -NSSystem;Winapi;System.Win -E..\bin\proxy -NU..\bin\dcu\proxy fbclient_proxy.dpr || goto :fail
dcc32 -B -Q -NSSystem;Winapi;System.Win -DNO_OO_API -E..\bin\proxy-no-oo -NU..\bin\dcu\proxy-no-oo fbclient_proxy.dpr || goto :fail
echo OK: ..\bin\proxy\fbclient_proxy.dll and ..\bin\proxy-no-oo\fbclient_proxy.dll
exit /b 0
:fail
echo BUILD FAILED
exit /b 1
