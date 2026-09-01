@echo off
rem SCCMAppHelper - starts the tool in Windows PowerShell 5.1.
rem -STA because the dialogs are WPF; -ExecutionPolicy Bypass so a fresh
rem server does not refuse the script; the window stays open on an error
rem so the message can be read.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0start-SCCMAppHelper.ps1" %*
if errorlevel 1 (
    echo.
    echo SCCMAppHelper ended with error level %errorlevel%. The log is in %~dp0Logs
    pause
)
endlocal
