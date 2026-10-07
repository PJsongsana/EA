@echo off
rem Compile an MQL5 file with MetaEditor from the command line.
rem
rem Usage:   compile.bat [file.mq5]
rem Default: MQL5\Experts\EdgeTester\EdgeTester.mq5
rem
rem Overrides (optional environment variables):
rem   METAEDITOR   path to MetaEditor64.exe
rem   MQL5_INCLUDE MQL5 folder that contains Include\Trade\Trade.mqh
rem                (default: first MT5 Data Folder found under %APPDATA%)

setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "SRC=%~1"
if "%SRC%"=="" set "SRC=MQL5\Experts\EdgeTester\EdgeTester.mq5"
if not exist "%SRC%" (
  echo [compile] source not found: %SRC%
  exit /b 2
)
for %%F in ("%SRC%") do (
  set "SRC=%%~fF"
  set "LOG=%%~dpnF.compile.log"
)

if "%METAEDITOR%"=="" set "METAEDITOR=C:\Program Files\MetaTrader 5\MetaEditor64.exe"
if not exist "%METAEDITOR%" (
  echo [compile] MetaEditor not found: %METAEDITOR%
  echo           set METAEDITOR=^<path to MetaEditor64.exe^>
  exit /b 2
)

if "%MQL5_INCLUDE%"=="" (
  for /d %%D in ("%APPDATA%\MetaQuotes\Terminal\*") do (
    if "!MQL5_INCLUDE!"=="" if exist "%%D\MQL5\Include\Trade\Trade.mqh" set "MQL5_INCLUDE=%%D\MQL5"
  )
)
if "%MQL5_INCLUDE%"=="" (
  echo [compile] MT5 Data Folder not found under %APPDATA%\MetaQuotes\Terminal
  echo           set MQL5_INCLUDE=^<Data Folder^>\MQL5
  exit /b 2
)

echo [compile] %SRC%
echo [compile] include: %MQL5_INCLUDE%
"%METAEDITOR%" /compile:"%SRC%" /include:"%MQL5_INCLUDE%" /log:"%LOG%"

rem The log is UTF-16; "type" converts it so findstr can read it.
type "%LOG%" | findstr /r /c:": error" /c:": warning" /c:"^Result:"
type "%LOG%" | findstr /r /c:"^Result: 0 errors" >nul
if errorlevel 1 (
  echo [compile] FAILED - see %LOG%
  exit /b 1
)
echo [compile] OK
exit /b 0
