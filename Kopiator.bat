@echo off
setlocal

:: Resolve directory of this script to safely locate Install-Printers.ps1
set "SCRIPT_DIR=%~dp0"
set "PS1_SCRIPT=%SCRIPT_DIR%Install-Printers.ps1"

if not exist "%PS1_SCRIPT%" (
    echo [ERROR] Could not find "%PS1_SCRIPT%".
    echo Please make sure Install-Printers.ps1 is in the same folder as this file.
    pause
    exit /b 1
)

:: Run PowerShell script with ExecutionPolicy Bypass to allow execution on all client machines
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1_SCRIPT%" %*

echo.
pause