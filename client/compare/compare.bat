@echo off
rem Task 7.1: runs fbcompare with the native fbclient.dll and with ws-fbclient.dll, then compares.
rem The Devart driver ignores VendorLib and loads fbclient.dll from the exe folder,
rem so each run uses its own folder under run\<label>\.
rem
rem compare.bat <label> <native_database> <http_database> [Name=Value ...]
rem   label            name for this run, e.g. fb5 or fb5-30ms
rem   native_database  e.g. 192.168.0.10/3050:/var/lib/firebird/data/test.fdb
rem   http_database    e.g. localhost:test (with ws-fbclient.ini url=...)
rem Environment:
rem   NATIVE_FBCLIENT  native fbclient.dll (same one the application ships)
rem   DRIVER_DLL       Devart driver DLL (e.g. dbexpida40.dll)
rem   WS_INI           ws-fbclient.ini for the HTTP run (optional)
rem   FB_USER, FB_PASSWORD  (default SYSDBA / masterkey)
setlocal
cd /d "%~dp0"
if "%~3"=="" (echo usage: compare.bat label native_database http_database [Name=Value ...] & exit /b 2)
set LABEL=%~1
rem The label names a folder: a database string here means the label was forgotten.
echo %LABEL%| findstr /r "[:/\\]" >nul && (echo First argument is the run label ^(e.g. fb3^), not a database. & echo usage: compare.bat label native_database http_database [Name=Value ...] & exit /b 2)
set NATIVE_DB=%~2
set HTTP_DB=%~3
shift & shift & shift
set EXTRA=
:args
if "%~1"=="" goto argsdone
set EXTRA=%EXTRA% "%~1"
shift
goto args
:argsdone
rem Paths may be set with or without quotes.
if defined NATIVE_FBCLIENT set NATIVE_FBCLIENT=%NATIVE_FBCLIENT:"=%
if defined DRIVER_DLL set DRIVER_DLL=%DRIVER_DLL:"=%
if defined WS_INI set WS_INI=%WS_INI:"=%
if "%FB_USER%"=="" set FB_USER=SYSDBA
if "%FB_PASSWORD%"=="" set FB_PASSWORD=masterkey
if not defined NATIVE_FBCLIENT (echo Set NATIVE_FBCLIENT to the native fbclient.dll & exit /b 1)
if not defined DRIVER_DLL (echo Set DRIVER_DLL to the Devart driver DLL, e.g. dbexpida40.dll & exit /b 1)
for %%F in ("%NATIVE_FBCLIENT%" "%DRIVER_DLL%" ..\bin\compare\fbcompare.exe ..\bin\ws-fbclient\ws-fbclient.dll) do if not exist %%F (echo missing %%F & exit /b 1)

set OUT=run\%LABEL%
if not exist %OUT%\native mkdir %OUT%\native
if not exist %OUT%\http mkdir %OUT%\http
copy /y ..\bin\compare\fbcompare.exe %OUT%\native >nul
copy /y "%DRIVER_DLL%" %OUT%\native >nul
copy /y "%NATIVE_FBCLIENT%" %OUT%\native\fbclient.dll >nul
rem Without firebird.msg the native client cannot format SQLCODE texts and every error differs.
for %%D in ("%NATIVE_FBCLIENT%") do if exist "%%~dpDfirebird.msg" (copy /y "%%~dpDfirebird.msg" %OUT%\native >nul) else (echo WARNING: no firebird.msg next to %%~D)
copy /y ..\bin\compare\fbcompare.exe %OUT%\http >nul
copy /y "%DRIVER_DLL%" %OUT%\http >nul
copy /y ..\bin\ws-fbclient\ws-fbclient.dll %OUT%\http\fbclient.dll >nul
if defined WS_INI copy /y "%WS_INI%" %OUT%\http\ws-fbclient.ini >nul

set FAILED=
%OUT%\native\fbcompare.exe "%NATIVE_DB%" %FB_USER% %FB_PASSWORD% %OUT%\native.txt %EXTRA%
if errorlevel 1 set FAILED=1
%OUT%\http\fbcompare.exe "%HTTP_DB%" %FB_USER% %FB_PASSWORD% %OUT%\http.txt %EXTRA%
if errorlevel 1 set FAILED=1

echo.
echo --- timings native / http
type %OUT%\native.txt.timing.txt
echo.
type %OUT%\http.txt.timing.txt
echo.
fc %OUT%\native.txt %OUT%\http.txt > %OUT%\diff.txt
set DIFF=%errorlevel%
rem FATAL or FAIL lines (e.g. login refused on both sides) make an equal dump meaningless.
if defined FAILED (echo FAILED: see FATAL/FAIL lines in %OUT%\native.txt and %OUT%\http.txt & exit /b 1)
if not "%DIFF%"=="0" (echo DIFFERENT: see %OUT%\diff.txt & exit /b 1)
echo SAME: %OUT%\native.txt = %OUT%\http.txt
