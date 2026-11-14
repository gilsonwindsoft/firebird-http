@echo off
rem Builds fbcompare.exe (Win32). Run from a "RAD Studio Command Prompt".
rem DEVART_DBX = folder with DbxDevartInterBase.dcu (Devart dbExpress install, Lib for your Delphi version).
setlocal
cd /d "%~dp0"
if not defined DEVART_DBX goto nodevart
rem Accept the path with or without quotes; "(x86)" breaks a quoted value inside if (...).
set DEVART_DBX=%DEVART_DBX:"=%
if not exist ..\bin\compare mkdir ..\bin\compare
if not exist ..\bin\dcu\compare mkdir ..\bin\dcu\compare
dcc32 -B -Q -NSSystem;Winapi;Data;Datasnap -E..\bin\compare -NU..\bin\dcu\compare -U"%DEVART_DBX%" fbcompare.dpr || (echo BUILD FAILED & exit /b 1)
echo OK: ..\bin\compare\fbcompare.exe
exit /b 0
:nodevart
echo Set DEVART_DBX to the folder with DbxDevartInterBase.dcu
exit /b 1
