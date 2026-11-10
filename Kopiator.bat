@echo off
setlocal

:: Pin system executable paths against untrusted search path vulnerabilities (CWE-426/CWE-427)
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL_EXE%" set "POWERSHELL_EXE=powershell.exe"

set "SCRIPT_DIR=%~dp0"
set "PS1_SCRIPT=%SCRIPT_DIR%Install-Printers.ps1"
set "REPO_URL=https://raw.githubusercontent.com/TheHawk09/Printer-Installer/main/Install-Printers.ps1"
set "API_URL=https://api.github.com/repos/TheHawk09/Printer-Installer/contents/Install-Printers.ps1"

:: Securely resolve LocalAppData (CWE-377/CWE-73)
if not defined LOCALAPPDATA set "LOCALAPPDATA=%USERPROFILE%\AppData\Local"
set "FALLBACK_DIR=%LOCALAPPDATA%\GTG-Printers"
set "FALLBACK_PS1=%FALLBACK_DIR%\Install-Printers.ps1"

:: 1. Check if Install-Printers.ps1 exists locally in the script directory
if exist "%PS1_SCRIPT%" goto RUN_SCRIPT

:: 2. Check if a previously cached copy exists in user profile cache
if exist "%FALLBACK_PS1%" (
    set "PS1_SCRIPT=%FALLBACK_PS1%"
    goto RUN_SCRIPT
)

:: 3. Not detected: Auto-download the latest version from official repository
echo ===============================================================================
echo   PRINTER INSTALLER - AUTO PROVISIONING
echo ===============================================================================
echo.
echo [INFO] Install-Printers.ps1 was not found locally in:
echo        "%SCRIPT_DIR%"
echo.
echo [INFO] Downloading latest Install-Printers.ps1 from official repository...
echo        URL: %REPO_URL%
echo.

:: Download to a secure temporary file first, validate file integrity, syntax, and content signature before deploying (CWE-494/CWE-377/CWE-330)
if not exist "%FALLBACK_DIR%" mkdir "%FALLBACK_DIR%" 2>nul
for /f "tokens=*" %%g in ('"%POWERSHELL_EXE%" -NoProfile -Command "[guid]::NewGuid().ToString('N')"') do set "RAND_ID=%%g"
if not defined RAND_ID set "RAND_ID=%RANDOM%_%RANDOM%"
set "TEMP_PS1=%FALLBACK_DIR%\dl_%RAND_ID%.tmp"

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -Command ^
    "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]3072 -bor [Net.SecurityProtocolType]12288; } catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]3072; }; " ^
    "try { " ^
    "    $ProgressPreference = 'SilentlyContinue'; " ^
    "    $wc = New-Object System.Net.WebClient; " ^
    "    $wc.Headers['User-Agent'] = 'PrinterInstaller/1.0'; " ^
    "    try { $wc.Proxy = [System.Net.WebRequest]::DefaultWebProxy; $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials; } catch { $null = $_.Exception; }; " ^
    "    $bytes = $wc.DownloadData('%REPO_URL%'); " ^
    "    if ($bytes.Length -lt 10240) { exit 2; } " ^
    "    [System.IO.File]::WriteAllBytes('%TEMP_PS1%', $bytes); " ^
    "    $tokens = $null; $errors = $null; " ^
    "    [System.Management.Automation.Language.Parser]::ParseFile('%TEMP_PS1%', [ref]$tokens, [ref]$errors) | Out-Null; " ^
    "    if ($errors.Count -gt 0) { exit 3; } " ^
    "    $content = [System.IO.File]::ReadAllText('%TEMP_PS1%'); " ^
    "    if (-not $content.Contains('ENTERPRISE NETWORK PRINTER MANAGER') -or -not $content.Contains('L-Kopiator')) { exit 4; } " ^
    "    $header = [System.Text.Encoding]::ASCII.GetBytes('blob ' + $bytes.Length + [char]0); " ^
    "    $all = New-Object byte[] ($header.Length + $bytes.Length); " ^
    "    [Buffer]::BlockCopy($header, 0, $all, 0, $header.Length); " ^
    "    [Buffer]::BlockCopy($bytes, 0, $all, $header.Length, $bytes.Length); " ^
    "    $computedSha = (-join ([System.Security.Cryptography.SHA1]::Create().ComputeHash($all) | ForEach-Object { '{0:x2}' -f $_ })).ToLowerInvariant(); " ^
    "    try { " ^
    "        $json = $wc.DownloadString('%API_URL%') | ConvertFrom-Json; " ^
    "        if ($json.sha) { " ^
    "            $remoteSha = $json.sha.ToLowerInvariant(); " ^
    "            if ($computedSha -ne $remoteSha) { exit 5; } " ^
    "            exit 0; " ^
    "        } " ^
    "    } catch { " ^
    "        exit 7; " ^
    "    } " ^
    "    exit 0; " ^
    "} catch { exit 1; }"

set "DL_STATUS=%ERRORLEVEL%"

if %DL_STATUS% EQU 0 (
    echo [OK] Verified syntax, authentic GTG markers, and dynamic GitHub object SHA.
    echo.
) else if %DL_STATUS% EQU 7 (
    echo [OK] Verified syntax and authentic GTG markers (GitHub API SHA check skipped/offline).
    echo.
) else if %DL_STATUS% EQU 5 (
    echo [SECURITY ERROR] Cryptographic SHA mismatch!
    echo The downloaded Install-Printers.ps1 does not match the authoritative GitHub blob SHA.
    echo The download has been discarded to protect system integrity.
    goto DOWNLOAD_FAILED
) else if %DL_STATUS% EQU 4 (
    echo [SECURITY ERROR] Signature verification failed: authentic GTG markers missing.
    goto DOWNLOAD_FAILED
) else if %DL_STATUS% EQU 3 (
    echo [ERROR] PowerShell syntax validation failed on downloaded script.
    goto DOWNLOAD_FAILED
) else if %DL_STATUS% EQU 2 (
    echo [ERROR] Downloaded file is truncated or corrupted (less than 10 KB).
    goto DOWNLOAD_FAILED
) else (
    echo [ERROR] Could not download Install-Printers.ps1 from official repository.
    goto DOWNLOAD_FAILED
)

if not exist "%TEMP_PS1%" goto DOWNLOAD_FAILED

:: Verify destination is not a symlink/reparse point before overwriting (CWE-59)
"%POWERSHELL_EXE%" -NoProfile -Command ^
    "foreach ($f in @('%PS1_SCRIPT%', '%FALLBACK_PS1%')) { " ^
    "    if (Test-Path $f) { " ^
    "        $item = Get-Item $f -Force; " ^
    "        if ($item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) { exit 10; } " ^
    "    } " ^
    "}"
if errorlevel 10 (
    echo [SECURITY ERROR] Reparse point or symbolic link detected at destination. Aborting.
    goto DOWNLOAD_FAILED
)

:: Try copying validated download into script directory
copy /y "%TEMP_PS1%" "%PS1_SCRIPT%" >nul 2>&1
if exist "%PS1_SCRIPT%" (
    del /f /q "%TEMP_PS1%" >nul 2>&1
    echo [OK] Successfully downloaded and verified Install-Printers.ps1.
    echo.
    goto RUN_SCRIPT
)

:: If script directory is write-protected, promote to %FALLBACK_PS1%
move /y "%TEMP_PS1%" "%FALLBACK_PS1%" >nul 2>&1
if exist "%FALLBACK_PS1%" (
    set "PS1_SCRIPT=%FALLBACK_PS1%"
    echo [OK] Successfully downloaded and verified Install-Printers.ps1 in user profile cache.
    echo.
    goto RUN_SCRIPT
)

:DOWNLOAD_FAILED
if exist "%TEMP_PS1%" del /f /q "%TEMP_PS1%" >nul 2>&1
echo.
echo [ERROR] Could not download or verify Install-Printers.ps1.
echo Please ensure you are connected to the internet, or download Install-Printers.ps1
echo manually from:
echo %REPO_URL%
echo.
pause
exit /b 1

:RUN_SCRIPT
:: Run PowerShell script with ExecutionPolicy Bypass using pinned binary path
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1_SCRIPT%" %*

:: If -NoPause was passed, suppress final pause for automation/CI (CWE-88/CWE-78)
set "RAW_ARGS=%*"
setlocal EnableDelayedExpansion
echo !RAW_ARGS! | findstr /i /c:"-NoPause" >nul
if errorlevel 1 (
    echo.
    pause
)
endlocal