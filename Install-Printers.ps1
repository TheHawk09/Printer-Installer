<#
.SYNOPSIS
    Enterprise-grade installer, manager, and troubleshooter for network printers/copiers.

.DESCRIPTION
    Installs, maps, tests, uninstalls, and diagnoses shared network printers.
    Built for Intune / Company Portal automated deployment, standalone execution,
    and administrative IT troubleshooting.
    Includes:
    - Automatic server resolution with direct IP fallback (172.16.0.32) for custom/NextDNS setups
    - 4-layer connection redundancy (WMI, Add-PrinterConnection, WScript.Network COM, printui.dll)
    - Friendly human error translation for common Windows Spooler and RPC error codes
    - Self-elevation for administrator-required tasks (e.g. -FixPointAndPrint, -RestartSpooler)
    - Print queue flusher and Spooler restarter (-RestartSpooler)
    - Windows Printers & Scanners settings launcher (-OpenSettings)
    - Execution stopwatch / duration benchmark
    - Auto-detect GTG Wi-Fi with interactive retry loop for terminal users
    - Optional interactive menu mode (-Menu)
    - Automated test page printing (/k)
    - Printer discovery and status listing (-ListAvailable, -ListInstalled)
    - Clean uninstallation mode (-Uninstall)
    - Persistent timestamped file logging with automatic size rotation and -ShowLog
    - Fast pre-flight network diagnostics (DNS, ICMP, SMB port 445)
    - Dynamic box-drawing TUI with auto-scaling width

.PARAMETER PrintServer
    UNC or hostname of the print server. Default is "\\gtcps001.gtc.local".

.PARAMETER FallbackIP
    Direct internal IP of the print server if custom DNS (NextDNS/DoH) is active. Default is "172.16.0.32".

.PARAMETER InternalDNSServers
    Array of internal Domain Controller DNS servers to query if primary DNS fails. Default: @("172.16.0.7", "172.16.0.8").

.PARAMETER Printers
    Array of printer shares to install. Default: @("L-Kopiator", "TB-Kopiator", "PB-Kopiator").

.PARAMETER DefaultPrinter
    Optionally designate a printer to set as the user's default.

.PARAMETER PrintTestPage
    Sends a Windows test page to the newly mapped printer(s) to verify driver/printing functionality.

.PARAMETER FixPointAndPrint
    Applies Point-and-Print server trust in the registry to prevent PrintNightmare / driver block errors.
    Automatically self-elevates if not running as Administrator.

.PARAMETER RestartSpooler
    Flushes stuck print jobs from spool directory and restarts the Print Spooler service.
    Automatically self-elevates if not running as Administrator.

.PARAMETER OpenSettings
    Opens the Windows Printers & Scanners Settings page (ms-settings:printers).

.PARAMETER Menu
    Launches an interactive numbered terminal menu to select operations.

.PARAMETER ShowLog
    Opens the persistent installer log file directly in the default text editor.

.PARAMETER Uninstall
    Uninstalls/unmaps the specified printers (or all printers from this server) from the user's profile.

.PARAMETER ListInstalled
    Displays all network printers currently connected to this machine.

.PARAMETER ListAvailable
    Queries the print server to list all publicly visible shared printers.

.PARAMETER LogPath
    Path to write a persistent diagnostic log file. Default: "$env:LOCALAPPDATA\GTG-Printers\PrinterInstaller.log".

.PARAMETER RemoveExisting
    Removes existing printer connections matching the given names before reconnecting.

.PARAMETER ForceInstall
    Bypasses pre-flight network reachability guards.

.PARAMETER NoPause
    Suppresses the "Press any key to close..." prompt upon completion (automatic in non-interactive/Intune runs).

.EXAMPLE
    .\Install-Printers.ps1
    Standard unattended installation of all 3 copiers.

.EXAMPLE
    .\Install-Printers.ps1 -Menu
    Launches the interactive menu.

.EXAMPLE
    .\Install-Printers.ps1 -ShowLog
    Displays the log file.

.EXAMPLE
    .\Install-Printers.ps1 -FixPointAndPrint
    Configures Point-and-Print trust policies (self-elevates via UAC if needed).

.EXAMPLE
    .\Install-Printers.ps1 -RestartSpooler
    Flushes stuck spool files and restarts the Print Spooler service.

.EXAMPLE
    .\Install-Printers.ps1 -Uninstall
    Uninstalls all 3 GTG network copiers.
#>

[CmdletBinding(DefaultParameterSetName = "Install")]
param(
    [Parameter(ParameterSetName = "Install")]
    [Parameter(ParameterSetName = "Uninstall")]
    [Parameter(ParameterSetName = "ListAvailable")]
    [string]$PrintServer = "\\gtcps001.gtc.local",

    [Parameter(ParameterSetName = "Install")]
    [Parameter(ParameterSetName = "Uninstall")]
    [Parameter(ParameterSetName = "ListAvailable")]
    [string]$FallbackIP = "172.16.0.32",

    [string[]]$InternalDNSServers = @("172.16.0.7", "172.16.0.8"),

    [Parameter(ParameterSetName = "Install")]
    [Parameter(ParameterSetName = "Uninstall")]
    [string[]]$Printers = @("L-Kopiator", "TB-Kopiator", "PB-Kopiator"),

    [Parameter(ParameterSetName = "Install")]
    [string]$DefaultPrinter = "",

    [Parameter(ParameterSetName = "Install")]
    [switch]$PrintTestPage,

    [Parameter(ParameterSetName = "Install")]
    [switch]$StartPaperCut,

    [Parameter(ParameterSetName = "Install")]
    [switch]$Duplex = $true,

    [Parameter(ParameterSetName = "Install")]
    [switch]$RemoveExisting,

    [Parameter(ParameterSetName = "Install")]
    [switch]$ForceInstall,

    [Parameter(ParameterSetName = "Uninstall")]
    [switch]$Uninstall,

    [Parameter(ParameterSetName = "ListInstalled")]
    [switch]$ListInstalled,

    [Parameter(ParameterSetName = "ListAvailable")]
    [switch]$ListAvailable,

    [Parameter(ParameterSetName = "FixPointAndPrint")]
    [switch]$FixPointAndPrint,

    [Parameter(ParameterSetName = "RestartSpooler")]
    [switch]$RestartSpooler,

    [Parameter(ParameterSetName = "OpenSettings")]
    [switch]$OpenSettings,

    [Parameter(ParameterSetName = "Menu")]
    [switch]$Menu,

    [Parameter(ParameterSetName = "ShowLog")]
    [switch]$ShowLog,

    [int]$MaxRetries = 1,
    [int]$RetryDelaySeconds = 2,
    [string]$LogPath = "",
    [switch]$NoPause
)

# Start execution stopwatch for performance telemetry
$scriptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# -------------------------------------------------------------
# PRE-FLIGHT INPUT VALIDATION & SECURITY HARDENING (CWE-20)
# -------------------------------------------------------------
function Test-IsPrivateIPAddress([string]$ipStr) {
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($ipStr, [ref]$ip)) { return $false }
    if ([System.Net.IPAddress]::IsLoopback($ip)) { return $true }
    $bytes = $ip.GetAddressBytes()
    if ($bytes.Length -ne 4) { return $false } # IPv4 only
    # RFC 1918 private ranges & APIPA (CWE-200/CWE-300 NetNTLM theft prevention)
    if ($bytes[0] -eq 10) { return $true }
    if ($bytes[0] -eq 172 -and ($bytes[1] -ge 16 -and $bytes[1] -le 31)) { return $true }
    if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $true }
    if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $true }
    return $false
}

function Test-IsLocalFixedDrivePath([string]$filePath) {
    try {
        if (-not $filePath -or $filePath.StartsWith("\\")) { return $false }
        $root = [System.IO.Path]::GetPathRoot($filePath)
        if (-not $root -or $root.StartsWith("\\")) { return $false }
        $drive = [System.IO.DriveInfo]::new($root)
        return ($drive.DriveType -eq [System.IO.DriveType]::Fixed)
    } catch [System.Exception] {
        return $false
    }
}

if ($PrintServer -and $PrintServer -notmatch '^[\\a-zA-Z0-9_\-\.]+$') {
    Write-Error "Invalid characters in -PrintServer parameter: '$PrintServer'."
    exit 1
}

# If PrintServer is directly specified as an IP address, enforce RFC 1918 private address (CWE-200/CWE-300)
$serverHostPre = $PrintServer.Trim().TrimEnd('\').TrimEnd('/').TrimStart('\')
$parsedServerIp = $null
if ([System.Net.IPAddress]::TryParse($serverHostPre, [ref]$parsedServerIp)) {
    if (-not (Test-IsPrivateIPAddress $serverHostPre)) {
        Write-Error "Security Policy Violation (CWE-200/CWE-300): -PrintServer IP '$serverHostPre' is a public IP. Print server targets must belong to private internal subnets (RFC 1918)."
        exit 1
    }
}

if ($FallbackIP) {
    if ($FallbackIP -notmatch '^(\d{1,3}\.){3}\d{1,3}$') {
        Write-Error "Invalid IP address format in -FallbackIP parameter: '$FallbackIP'."
        exit 1
    }
    if (-not (Test-IsPrivateIPAddress $FallbackIP)) {
        Write-Error "Security Policy Violation (CWE-200/CWE-300): -FallbackIP '$FallbackIP' is a public IP address. Print server targets must belong to private internal subnets (RFC 1918)."
        exit 1
    }
}

foreach ($dns in $InternalDNSServers) {
    if ($dns -notmatch '^(\d{1,3}\.){3}\d{1,3}$') {
        Write-Error "Invalid IP address format in -InternalDNSServers parameter: '$dns'."
        exit 1
    }
    if (-not (Test-IsPrivateIPAddress $dns)) {
        Write-Error "Security Policy Violation (CWE-200/CWE-300): Internal DNS server '$dns' must belong to private internal subnets (RFC 1918)."
        exit 1
    }
}

foreach ($p in $Printers) {
    if ($p -notmatch '^[a-zA-Z0-9_\-\.\s\\]+$') {
        Write-Error "Invalid characters in printer name: '$p'."
        exit 1
    }
}
if ($DefaultPrinter -and $DefaultPrinter -notmatch '^[a-zA-Z0-9_\-\.\s\\]+$') {
    Write-Error "Invalid characters in -DefaultPrinter parameter: '$DefaultPrinter'."
    exit 1
}

# Pin canonical system paths against search path vulnerabilities (CWE-426/CWE-427)
$script:SYSTEM32 = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::System)
if (-not $script:SYSTEM32 -or -not (Test-Path $script:SYSTEM32)) { $script:SYSTEM32 = "$env:SystemRoot\System32" }
$script:RUNDLL32_EXE = Join-Path $script:SYSTEM32 "rundll32.exe"
$script:NET_EXE = Join-Path $script:SYSTEM32 "net.exe"
$script:NOTEPAD_EXE = Join-Path $script:SYSTEM32 "notepad.exe"
$script:POWERSHELL_EXE = Join-Path $script:SYSTEM32 "WindowsPowerShell\v1.0\powershell.exe"

# Securely pin LocalAppData directory and harden NTFS ACLs (CWE-377/CWE-732)
$secureLocalAppDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if (-not $secureLocalAppDir -or -not (Test-Path $secureLocalAppDir)) {
    $secureLocalAppDir = if ($env:LOCALAPPDATA -and (Test-Path $env:LOCALAPPDATA)) {
        $env:LOCALAPPDATA
    } elseif ($env:USERPROFILE) {
        Join-Path $env:USERPROFILE "AppData\Local"
    } else {
        $env:TEMP
    }
}
$script:GTG_DATA_DIR = Join-Path $secureLocalAppDir "GTG-Printers"
try {
    if (-not (Test-Path $script:GTG_DATA_DIR)) {
        New-Item -Path $script:GTG_DATA_DIR -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
    # Enforce strict NTFS permissions: Owner/User + Admins + SYSTEM only (CWE-732)
    if (Test-Path $script:GTG_DATA_DIR) {
        $acl = Get-Acl -LiteralPath $script:GTG_DATA_DIR -ErrorAction SilentlyContinue
        if ($acl) {
            $userRef = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $adminSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
            $systemSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
            
            $acl.SetAccessRuleProtection($true, $false)
            $ruleUser = New-Object System.Security.AccessControl.FileSystemAccessRule($userRef, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit", [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
            $ruleAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule($adminSid, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit", [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
            $ruleSys = New-Object System.Security.AccessControl.FileSystemAccessRule($systemSid, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit", [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
            
            $acl.ResetAccessRule($ruleUser)
            $acl.AddAccessRule($ruleAdmin)
            $acl.AddAccessRule($ruleSys)
            Set-Acl -LiteralPath $script:GTG_DATA_DIR -AclObject $acl -ErrorAction SilentlyContinue
        }
    }
} catch [System.Exception] {
    Write-Verbose "Could not secure GTG data directory: $($_.Exception.Message)"
}

if (-not $LogPath) {
    $LogPath = Join-Path $script:GTG_DATA_DIR "PrinterInstaller.log"
}

# Registry security: enforce strict REG_SZ and REG_DWORD to prevent REG_EXPAND_SZ environment injection (CWE-642/CWE-73)
function Set-SecureRegistryString {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Value
    )
    try {
        if (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue
        }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force -ErrorAction Stop | Out-Null
    } catch [System.Exception] {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type String -Force -ErrorAction SilentlyContinue
    }
}

function Set-SecureRegistryDWord {
    param(
        [string]$Path,
        [string]$Name,
        [int]$Value
    )
    try {
        if (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue
        }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    } catch [System.Exception] {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord -Force -ErrorAction SilentlyContinue
    }
}

# COM Object lifecycle management (CWE-404/CWE-775)
$wshellNetwork = $null

function Get-WScriptNetwork {
    if (-not $script:wshellNetwork) {
        try {
            $script:wshellNetwork = New-Object -ComObject WScript.Network
        } catch [System.Exception] {
            Write-Verbose "Could not instantiate WScript.Network COM object: $($_.Exception.Message)"
        }
    }
    return $script:wshellNetwork
}

function Release-WScriptNetwork {
    if ($script:wshellNetwork) {
        try {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:wshellNetwork) | Out-Null
        } catch [System.Exception] {
            Write-Verbose "Could not release WScript.Network COM object: $($_.Exception.Message)"
        } finally {
            $script:wshellNetwork = $null
            try {
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
            } catch [System.Exception] {
                Write-Verbose "Garbage collection encountered: $($_.Exception.Message)"
            }
        }
    }
}

function Get-PaperCutClientStatus {
    $proc = Get-Process -Name "pc-client" -ErrorAction SilentlyContinue
    if ($proc) {
        $pId = if ($proc -is [array]) { $proc[0].Id } else { $proc.Id }
        return @{ Running = $true; ProcessId = $pId; Path = "" }
    }
    $candidatePaths = @(
        "$env:LOCALAPPDATA\Programs\PaperCut MF Client\pc-client.exe",
        "$env:ProgramFiles\PaperCut MF Client\pc-client.exe",
        "${env:ProgramFiles(x86)}\PaperCut MF Client\pc-client.exe",
        "C:\PaperCut\client\win\pc-client.exe"
    )
    $foundPath = ""
    foreach ($p in $candidatePaths) {
        if ($p -and (Test-Path $p)) {
            $foundPath = $p
            break
        }
    }
    return @{ Running = $false; ProcessId = $null; Path = $foundPath }
}

function Start-PaperCutClientSafe {
    $status = Get-PaperCutClientStatus
    if ($status.Running) { return $true }
    if ($status.Path -and (Test-Path $status.Path)) {
        try {
            Start-Process -FilePath $status.Path
            Start-Sleep -Milliseconds 600
            $procCheck = Get-Process -Name "pc-client" -ErrorAction SilentlyContinue
            return ($null -ne $procCheck)
        } catch [System.Exception] {
            Write-Verbose "Could not launch PaperCut client: $($_.Exception.Message)"
        }
    }
    return $false
}

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch [System.Exception] {
    Write-Verbose "Could not set Console::OutputEncoding to UTF8: $($_.Exception.Message)"
}

$ErrorActionPreference = "Continue"

# -------------------------------------------------------------
# DYNAMIC TUI ENGINE (Box-Drawing Characters)
# -------------------------------------------------------------
$BOX = @{
    D_TL = [char]0x2554  # ╔
    D_TR = [char]0x2557  # ╗
    D_BL = [char]0x255A  # ╚
    D_BR = [char]0x255D  # ╝
    D_H  = [char]0x2550  # ═
    D_V  = [char]0x2551  # ║
    D_LT = [char]0x2560  # ╠
    D_RT = [char]0x2563  # ╣

    S_TL = [char]0x250C  # ┌
    S_TR = [char]0x2510  # ┐
    S_BL = [char]0x2514  # └
    S_BR = [char]0x2518  # ┘
    S_H  = [char]0x2500  # ─
    S_V  = [char]0x2502  # │
    S_LT = [char]0x251C  # ├
    S_RT = [char]0x2524  # ┤

    CHECK = [char]0x2714 # ✔
    CROSS = [char]0x2718 # ✘
    ARROW = [char]0x25B8 # ▸

    BLOCK_FULL  = [char]0x2588 # █
    BLOCK_LIGHT = [char]0x2591 # ░
}

$MIN_TUI_WIDTH = 75
$MAX_TUI_WIDTH = 100

function Get-ProgressBarString {
    param(
        [int]$Percent,
        [int]$Width = 20
    )
    $Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
    $filled = [int][Math]::Round(($Percent / 100.0) * $Width)
    $empty = [Math]::Max(0, $Width - $filled)
    $fillStr = if ($filled -gt 0) { [string]::new([char]0x2588, $filled) } else { "" }
    $emptyStr = if ($empty -gt 0) { [string]::new([char]0x2591, $empty) } else { "" }
    return "{0}{1} {2,3}%" -f $fillStr, $emptyStr, $Percent
}

function Get-DynamicWidth {
    param([string[]]$Lines, [int]$MinWidth = $script:MIN_TUI_WIDTH, [int]$MaxWidth = $script:MAX_TUI_WIDTH)
    $maxLen = $MinWidth
    foreach ($l in $Lines) {
        if ($l -and $l.Length + 6 -gt $maxLen) {
            $maxLen = $l.Length + 6
        }
    }
    return [Math]::Min($maxLen, $MaxWidth)
}

# -------------------------------------------------------------
# LOGGING & ROTATION ENGINE
# -------------------------------------------------------------
$MAX_LOG_SIZE_BYTES = 2MB

function Rotate-LogFileIfNeeded {
    try {
        if (Test-Path $LogPath) {
            $file = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
            if ($file) {
                # Protect against symlink / reparse point attacks (CWE-59/CWE-367)
                if ($file.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                    Write-Verbose "Security Alert: Reparse point detected at $LogPath. Refusing log rotation."
                    return
                }
                if ($file.Length -gt $MAX_LOG_SIZE_BYTES) {
                    $archive = "$LogPath.old"
                    if (Test-Path $archive) {
                        $archItem = Get-Item -LiteralPath $archive -ErrorAction SilentlyContinue
                        if ($archItem -and $archItem.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                            Write-Verbose "Security Alert: Reparse point detected at archive $archive. Aborting rotation."
                            return
                        }
                        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
                    }
                    Rename-Item -LiteralPath $LogPath -NewName (Split-Path $archive -Leaf) -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } catch [System.Exception] {
        Write-Verbose "Log rotation check encountered: $($_.Exception.Message)"
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,
        [switch]$NoConsole,
        [switch]$NoNewLine
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logEntry = "[$timestamp] $Message"

    Rotate-LogFileIfNeeded

    try {
        # Verify target is not a symlink/reparse point before appending (CWE-59)
        if (Test-Path $LogPath) {
            $existing = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
            if ($existing -and $existing.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                return
            }
        }
        Add-Content -LiteralPath $LogPath -Value $logEntry -ErrorAction SilentlyContinue
    } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
        Write-Verbose "Non-fatal log write error on ${LogPath}: $($_.Exception.Message)"
    } catch [System.Exception] {
        Write-Verbose "Logging failure to ${LogPath}: $($_.Exception.Message)"
    }

    if (-not $NoConsole) {
        if ($NoNewLine) {
            Write-Host $Message -ForegroundColor $ForegroundColor -NoNewline
        } else {
            Write-Host $Message -ForegroundColor $ForegroundColor
        }
    }
}

# -------------------------------------------------------------
# FRIENDLY ERROR TRANSLATOR
# -------------------------------------------------------------
function Get-FriendlyErrorMessage([string]$rawError) {
    if (-not $rawError) { return "Unknown error occurred" }

    # Common Windows Print Spooler, RPC, and WMI error patterns
    switch -Regex ($rawError) {
        "0x80070005|Access is denied|E_ACCESSDENIED|error code:\s*5\b" {
            return "ACCESS DENIED - Windows Point-and-Print policy blocked driver download. Run script with -FixPointAndPrint as Admin."
        }
        "0x80070035|The network path was not found|error code:\s*53\b" {
            return "NETWORK PATH NOT FOUND - Server is offline or inaccessible on this network."
        }
        "0x8007007B|The filename, directory name, or volume label syntax is incorrect|error code:\s*123\b" {
            return "INVALID SHARE SYNTAX - Printer share name is malformed or invalid."
        }
        "0x800706BA|The RPC server is unavailable|error code:\s*1722\b" {
            return "RPC SERVER UNAVAILABLE - The Print Spooler service on the server or client is not responding."
        }
        "0x800706BE|The remote procedure call failed" {
            return "RPC CALL FAILED - The remote print spooler terminated unexpectedly during negotiation."
        }
        "0x80070034|The name was not found on the network|error code:\s*52\b" {
            return "NAME NOT FOUND - Hostname cannot be resolved on local network segment."
        }
        "0x8007003A|The specified server cannot perform the requested operation|error code:\s*58\b" {
            return "SERVER BUSY/UNSUPPORTED - The print server refused or cannot process the connection request."
        }
        "0x800704C7|The operation was canceled by the user|error code:\s*1223\b" {
            return "OPERATION CANCELED - Driver installation prompt was dismissed or canceled by the user."
        }
        "0x80041001|Generic failure" {
            return "WMI GENERIC FAILURE - Windows Management Instrumentation failed to process printer query."
        }
        "0x80070006|The handle is invalid|error code:\s*6\b" {
            return "INVALID HANDLE - Printer device context was closed or invalidated prematurely."
        }
        "0x8007007A|The data area passed to a system call is too small|error code:\s*122\b" {
            return "BUFFER UNDERFLOW - Printer configuration buffer size mismatch."
        }
        "0x80070002|The system cannot find the file specified|error code:\s*2\b" {
            return "DRIVER/FILE NOT FOUND - A required driver package or inf file is missing from the print server."
        }
        "3012|No printers were found" {
            return "QUEUE NOT FOUND (3012) - Printer queue does not exist on the specified server share."
        }
        "0x80010108|The object invoked has disconnected from its clients" {
            return "COM TIMEOUT - Windows Script Host or Spooler disconnected during execution."
        }
        default {
            return $rawError
        }
    }
}

# -------------------------------------------------------------
# TUI VISUAL BUILDERS
# -------------------------------------------------------------
function Show-BoxTitle {
    param(
        [string]$Title,
        [string[]]$Lines = @(),
        [ConsoleColor]$BorderColor = [ConsoleColor]::Cyan,
        [ConsoleColor]$TextColor = [ConsoleColor]::White
    )
    $w = Get-DynamicWidth -Lines (@($Title) + $Lines)
    $script:CURRENT_TUI_WIDTH = $w
    $innerW = $w - 2

    Write-Log ("{0}{1}{2}" -f $BOX.D_TL, ($BOX.D_H.ToString() * $innerW), $BOX.D_TR) -ForegroundColor $BorderColor
    $leftPad = [Math]::Max(0, [int][Math]::Floor(($innerW - $Title.Length) / 2))
    $rightPad = [Math]::Max(0, $innerW - $Title.Length - $leftPad)
    Write-Log ("{0}{1}{2}{3}{4}" -f $BOX.D_V, (' ' * $leftPad), $Title, (' ' * $rightPad), $BOX.D_V) -ForegroundColor $BorderColor

    if ($Lines.Count -gt 0) {
        Write-Log ("{0}{1}{2}" -f $BOX.D_LT, ($BOX.D_H.ToString() * $innerW), $BOX.D_RT) -ForegroundColor $BorderColor
        foreach ($line in $Lines) {
            $linePad = [Math]::Max(0, $innerW - $line.Length - 2)
            Write-Log ("{0} {1}{2} {3}" -f $BOX.D_V, $line, (' ' * $linePad), $BOX.D_V) -ForegroundColor $TextColor
        }
    }
    Write-Log ("{0}{1}{2}" -f $BOX.D_BL, ($BOX.D_H.ToString() * $innerW), $BOX.D_BR) -ForegroundColor $BorderColor
}

function Show-SectionHeader {
    param(
        [string]$StepTitle,
        [ConsoleColor]$Color = [ConsoleColor]::Cyan,
        [int]$Width = 0
    )
    if ($Width -le 0) {
        $Width = if ($script:CURRENT_TUI_WIDTH) { $script:CURRENT_TUI_WIDTH } else { $script:MIN_TUI_WIDTH }
    }
    $innerW = $Width - 2
    Write-Log ""
    Write-Log ("{0}{1}{2}" -f $BOX.S_TL, ($BOX.S_H.ToString() * $innerW), $BOX.S_TR) -ForegroundColor $Color
    $titlePad = [Math]::Max(0, $innerW - $StepTitle.Length - 2)
    Write-Log ("{0} {1}{2} {3}" -f $BOX.S_V, $StepTitle, (' ' * $titlePad), $BOX.S_V) -ForegroundColor $Color
    Write-Log ("{0}{1}{2}" -f $BOX.S_BL, ($BOX.S_H.ToString() * $innerW), $BOX.S_BR) -ForegroundColor $Color
}

function Show-NoticeBox {
    param(
        [string]$Header,
        [string[]]$BodyLines,
        [ConsoleColor]$Color = [ConsoleColor]::Yellow
    )
    $w = Get-DynamicWidth -Lines (@($Header) + $BodyLines)
    $innerW = $w - 2

    Write-Log ""
    Write-Log ("{0}{1}{2}" -f $BOX.S_TL, ($BOX.S_H.ToString() * $innerW), $BOX.S_TR) -ForegroundColor $Color
    $headerPad = [Math]::Max(0, $innerW - $Header.Length - 2)
    Write-Log ("{0} {1}{2} {3}" -f $BOX.S_V, $Header, (' ' * $headerPad), $BOX.S_V) -ForegroundColor $Color
    Write-Log ("{0}{1}{2}" -f $BOX.S_LT, ($BOX.S_H.ToString() * $innerW), $BOX.S_RT) -ForegroundColor $Color
    foreach ($line in $BodyLines) {
        $linePad = [Math]::Max(0, $innerW - $line.Length - 2)
        Write-Log ("{0} {1}{2} {3}" -f $BOX.S_V, $line, (' ' * $linePad), $BOX.S_V) -ForegroundColor $Color
    }
    Write-Log ("{0}{1}{2}" -f $BOX.S_BL, ($BOX.S_H.ToString() * $innerW), $BOX.S_BR) -ForegroundColor $Color
}

# -------------------------------------------------------------
# ACTION: Show-Log Switch
# -------------------------------------------------------------
if ($ShowLog) {
    if (Test-Path $LogPath) {
        Write-Host "Opening log file: $LogPath" -ForegroundColor Cyan
        Start-Process -FilePath $script:NOTEPAD_EXE -ArgumentList "`"$LogPath`""
    } else {
        Write-Host "Log file does not exist yet at: $LogPath" -ForegroundColor Yellow
    }
    Release-WScriptNetwork
    exit 0
}

# -------------------------------------------------------------
# ACTION: Open Windows Printer Settings
# -------------------------------------------------------------
if ($OpenSettings) {
    Write-Host "Opening Windows Printers & Scanners Settings..." -ForegroundColor Cyan
    Start-Process "ms-settings:printers"
    Release-WScriptNetwork
    exit 0
}

# -------------------------------------------------------------
# ENVIRONMENT & IDENTITY
# -------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$serverClean = $PrintServer.Trim().TrimEnd('\')
if (-not $serverClean.StartsWith("\\")) {
    $serverClean = "\\$serverClean"
}
$serverHost = $serverClean.TrimStart('\')

function Get-ActiveSSID {
    $name = ((Get-NetConnectionProfile | Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue) -join ', ')
    if (-not $name) { return "Disconnected / Unknown" }
    return $name
}

# -------------------------------------------------------------
# ACTION: Restart Print Spooler & Flush Stuck Jobs
# -------------------------------------------------------------
if ($RestartSpooler) {
    Show-SectionHeader -StepTitle "SERVICE MAINTENANCE: FLUSH & RESTART PRINT SPOOLER" -Color Yellow

    if (-not $isAdmin) {
        $scriptPath = $MyInvocation.MyCommand.Path
        # Block elevation from untrusted UNC shares or removable media (CWE-829/CWE-250)
        if (-not (Test-IsLocalFixedDrivePath -filePath $scriptPath)) {
            Write-Log "  $($BOX.CROSS) Elevation Blocked: Script must run from a local fixed drive (CWE-829/CWE-250)." -ForegroundColor Red
            Show-NoticeBox -Header "ELEVATION SECURITY RESTRICTION" -BodyLines @(
                "Self-elevation from network shares (UNC) or removable drives is blocked",
                "to prevent privilege escalation and binary planting vulnerabilities.",
                "Path: $scriptPath",
                "Please copy Install-Printers.ps1 to a local fixed drive (e.g. C:) and re-run."
            ) -Color Red
            if (-not $NoPause -and $Host.Name -eq "ConsoleHost") {
                Write-Host "`nPress any key to close..." -ForegroundColor DarkGray
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
            Release-WScriptNetwork
            exit 1
        }

        Write-Log "  $($BOX.ARROW) Administrative rights required. Requesting UAC elevation... " -NoNewLine
        try {
            $process = Start-Process -FilePath $script:POWERSHELL_EXE `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -RestartSpooler -NoPause" `
                -Verb RunAs -PassThru -Wait
            if ($process.ExitCode -eq 0) {
                Write-Log "ELEVATED OK $($BOX.CHECK)" -ForegroundColor Green
            } else {
                Write-Log "FAILED ($($process.ExitCode)) $($BOX.CROSS)" -ForegroundColor Red
            }
        } catch [System.Exception] {
            Write-Log "FAILED $($BOX.CROSS)" -ForegroundColor Red
        }

        if (-not $NoPause -and $Host.Name -eq "ConsoleHost") {
            Write-Host "`nPress any key to close..." -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        Release-WScriptNetwork
        exit 0
    }

    # Running elevated: Stop spooler, purge spool dir, start spooler
    Write-Log "  $($BOX.ARROW) Stopping Print Spooler service... " -NoNewLine
    try {
        Stop-Service -Name "Spooler" -Force -ErrorAction Stop
        Write-Log "STOPPED $($BOX.CHECK)" -ForegroundColor Green
    } catch [System.Exception] {
        Write-Log "FAILED ($($_.Exception.Message)) $($BOX.CROSS)" -ForegroundColor Red
    }

    Write-Log "  $($BOX.ARROW) Purging stuck print jobs from spool directory... " -NoNewLine
    try {
        $spoolDir = Join-Path $script:SYSTEM32 "spool\PRINTERS"
        if (Test-Path $spoolDir) {
            Get-ChildItem -Path $spoolDir -Force -ErrorAction SilentlyContinue | Where-Object {
                -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)
            } | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        Write-Log "CLEARED $($BOX.CHECK)" -ForegroundColor Green
    } catch [System.Exception] {
        Write-Log "SKIPPED ($($_.Exception.Message))" -ForegroundColor Yellow
    }

    Write-Log "  $($BOX.ARROW) Restarting Print Spooler service... " -NoNewLine
    try {
        Start-Service -Name "Spooler" -ErrorAction Stop
        Write-Log "RUNNING $($BOX.CHECK)" -ForegroundColor Green
        Show-NoticeBox -Header "PRINT SPOOLER RESET COMPLETE" -BodyLines @(
            "Print Spooler service was successfully restarted and stuck queues were cleared."
        ) -Color Green
    } catch [System.Exception] {
        Write-Log "FAILED ($($_.Exception.Message)) $($BOX.CROSS)" -ForegroundColor Red
    }

    if (-not $NoPause -and $Host.Name -eq "ConsoleHost") {
        Write-Host "`nPress any key to close..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    Release-WScriptNetwork
    exit 0
}

# -------------------------------------------------------------
# ACTION: Interactive Menu Mode (-Menu)
# -------------------------------------------------------------
if ($Menu) {
    Clear-Host
    Show-BoxTitle -Title "NETWORK PRINTER MANAGER - INTERACTIVE MENU" -Lines @(
        "Server  : $serverClean (Fallback IP: $FallbackIP)",
        "User    : $env:USERDOMAIN\$env:USERNAME",
        "Network : $(Get-ActiveSSID)"
    ) -BorderColor Cyan -TextColor DarkCyan

    Write-Host ""
    Write-Host "  === INSTALLATION OPTIONS ===" -ForegroundColor Cyan
    Write-Host "  [1]  Install All Copiers (L-Kopiator, TB-Kopiator, PB-Kopiator)" -ForegroundColor White
    Write-Host "  [2]  Install L-Kopiator only" -ForegroundColor White
    Write-Host "  [3]  Install TB-Kopiator only" -ForegroundColor White
    Write-Host "  [4]  Install PB-Kopiator only" -ForegroundColor White
    Write-Host "  [5]  Install All & Print Test Page" -ForegroundColor White
    Write-Host ""
    Write-Host "  === MANAGEMENT & TOOLS ===" -ForegroundColor Cyan
    Write-Host "  [6]  List Installed Network Printers" -ForegroundColor White
    Write-Host "  [7]  Discover Available Shares on Server" -ForegroundColor White
    Write-Host "  [8]  Uninstall All Copiers" -ForegroundColor White
    Write-Host "  [9]  Flush Queue & Restart Print Spooler (Requires Admin)" -ForegroundColor White
    Write-Host "  [10] Fix Point-and-Print Driver Policy (Requires Admin)" -ForegroundColor White
    Write-Host "  [11] Open Windows Printers & Scanners Settings" -ForegroundColor White
    Write-Host "  [12] Open Diagnostic Log" -ForegroundColor White
    Write-Host "  [13] Check / Launch PaperCut MF Client" -ForegroundColor White
    Write-Host "  [0]  Exit" -ForegroundColor DarkGray
    Write-Host ""
    $choice = Read-Host "  Select an option [0-13]"

    switch ($choice) {
        "1"  { & $MyInvocation.MyCommand.Path -NoPause; exit 0 }
        "2"  { & $MyInvocation.MyCommand.Path -Printers @("L-Kopiator") -DefaultPrinter "L-Kopiator" -NoPause; exit 0 }
        "3"  { & $MyInvocation.MyCommand.Path -Printers @("TB-Kopiator") -DefaultPrinter "TB-Kopiator" -NoPause; exit 0 }
        "4"  { & $MyInvocation.MyCommand.Path -Printers @("PB-Kopiator") -DefaultPrinter "PB-Kopiator" -NoPause; exit 0 }
        "5"  { & $MyInvocation.MyCommand.Path -PrintTestPage -NoPause; exit 0 }
        "6"  { & $MyInvocation.MyCommand.Path -ListInstalled -NoPause; exit 0 }
        "7"  { & $MyInvocation.MyCommand.Path -ListAvailable -NoPause; exit 0 }
        "8"  { & $MyInvocation.MyCommand.Path -Uninstall -NoPause; exit 0 }
        "9"  { & $MyInvocation.MyCommand.Path -RestartSpooler -NoPause; exit 0 }
        "10" { & $MyInvocation.MyCommand.Path -FixPointAndPrint -NoPause; exit 0 }
        "11" { & $MyInvocation.MyCommand.Path -OpenSettings; exit 0 }
        "12" { & $MyInvocation.MyCommand.Path -ShowLog; exit 0 }
        "13" {
            $ok = Start-PaperCutClientSafe
            if ($ok) {
                Write-Host "`nPaperCut Client started successfully." -ForegroundColor Green
            } else {
                Write-Host "`nPaperCut Client not found or could not be launched automatically." -ForegroundColor Yellow
            }
            Start-Sleep -Seconds 2
            & $MyInvocation.MyCommand.Path -Menu; exit 0
        }
        default { exit 0 }
    }
}

$headerInfo = @(
    "Server    : $serverClean (Fallback IP: $FallbackIP)",
    "User      : $env:USERDOMAIN\$env:USERNAME",
    "Privilege : $(if ($isAdmin) { 'Administrator (Elevated)' } else { 'Standard User' })",
    "Network   : $(Get-ActiveSSID)",
    "Log File  : $LogPath"
)

Write-Log ""
Show-BoxTitle -Title "ENTERPRISE NETWORK PRINTER MANAGER" -Lines $headerInfo -BorderColor Cyan -TextColor DarkCyan

# -------------------------------------------------------------
# ACTION: Fix Point-and-Print (Self-Elevating)
# -------------------------------------------------------------
if ($FixPointAndPrint) {
    Show-SectionHeader -StepTitle "POLICY CONFIGURATION: POINT-AND-PRINT TRUST" -Color Yellow

    # Self-Elevation: Relaunch with elevation if running as standard user
    if (-not $isAdmin) {
        $scriptPath = $MyInvocation.MyCommand.Path
        # Block elevation from untrusted UNC shares or removable media (CWE-829/CWE-250)
        if (-not (Test-IsLocalFixedDrivePath -filePath $scriptPath)) {
            Write-Log "  $($BOX.CROSS) Elevation Blocked: Script must run from a local fixed drive (CWE-829/CWE-250)." -ForegroundColor Red
            Show-NoticeBox -Header "ELEVATION SECURITY RESTRICTION" -BodyLines @(
                "Self-elevation from network shares (UNC) or removable drives is blocked",
                "to prevent privilege escalation and binary planting vulnerabilities.",
                "Path: $scriptPath",
                "Please copy Install-Printers.ps1 to a local fixed drive (e.g. C:) and re-run."
            ) -Color Red
            if (-not $NoPause -and $Host.Name -eq "ConsoleHost") {
                Write-Host "`nPress any key to close..." -ForegroundColor DarkGray
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
            Release-WScriptNetwork
            exit 1
        }

        Write-Log "  $($BOX.ARROW) Administrative rights required. Requesting UAC elevation... " -NoNewLine
        try {
            $process = Start-Process -FilePath $script:POWERSHELL_EXE `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -FixPointAndPrint -NoPause" `
                -Verb RunAs -PassThru -Wait
            if ($process.ExitCode -eq 0) {
                Write-Log "ELEVATED OK $($BOX.CHECK)" -ForegroundColor Green
                Show-NoticeBox -Header "ELEVATED CONFIGURATION COMPLETE" -BodyLines @(
                    "Point-and-Print registry policies were applied successfully in elevated session."
                ) -Color Green
            } else {
                Write-Log "FAILED ($($process.ExitCode)) $($BOX.CROSS)" -ForegroundColor Red
            }
        } catch [System.Exception] {
            Write-Log "FAILED $($BOX.CROSS)" -ForegroundColor Red
            Show-NoticeBox -Header "ELEVATION CANCELLED OR BLOCKED" -BodyLines @(
                "UAC prompt was denied or could not be initiated: $($_.Exception.Message)"
            ) -Color Red
        }

        if (-not $NoPause -and $Host.Name -eq "ConsoleHost") {
            Write-Host "`nPress any key to close..." -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        Release-WScriptNetwork
        exit 0
    }

    # Running Elevated - Apply Policies
    try {
        $policiesPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
        if (-not (Test-Path $policiesPath)) {
            New-Item -Path $policiesPath -Force | Out-Null
        }

        Set-SecureRegistryDWord -Path $policiesPath -Name "RestrictDriverInstallationToAdministrators" -Value 0
        Set-SecureRegistryDWord -Path $policiesPath -Name "PackagePointAndPrintServerList" -Value 1
        Set-SecureRegistryDWord -Path $policiesPath -Name "NoWarningNoElevationOnInstall" -Value 1
        Set-SecureRegistryDWord -Path $policiesPath -Name "UpdatePromptSettings" -Value 2

        $serverListPath = "$policiesPath\ListofServers"
        if (-not (Test-Path $serverListPath)) {
            New-Item -Path $serverListPath -Force | Out-Null
        }
        Set-SecureRegistryString -Path $serverListPath -Name $serverHost -Value $serverHost
        if ($FallbackIP) {
            Set-SecureRegistryString -Path $serverListPath -Name $FallbackIP -Value $FallbackIP
        }

        Show-NoticeBox -Header "SUCCESSFULLY CONFIGURED" -BodyLines @(
            "Registered '$serverHost' and '$FallbackIP' as trusted Point-and-Print servers.",
            "Standard users can now download and install drivers without UAC block."
        ) -Color Green
    } catch [System.Exception] {
        Show-NoticeBox -Header "CONFIGURATION ERROR" -BodyLines @("Failed to apply registry policy: $($_.Exception.Message)") -Color Red
    }

    if (-not $NoPause -and $Host.Name -eq "ConsoleHost") {
        Write-Host "`nPress any key to close..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    Release-WScriptNetwork
    exit 0
}

# -------------------------------------------------------------
# ACTION: List Installed Network Printers
# -------------------------------------------------------------
if ($ListInstalled) {
    Show-SectionHeader -StepTitle "LOCAL INVENTORY: INSTALLED NETWORK PRINTERS" -Color Cyan
    $installed = @()

    try {
        if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
            $installed = Get-Printer | Where-Object { $_.Type -eq "Connection" -or $_.PortName -like "\\*" }
        }
    } catch [System.Exception] {
        Write-Verbose "Get-Printer query failed: $($_.Exception.Message)"
    }

    if ($installed.Count -eq 0) {
        try {
            $installed = Get-CimInstance -ClassName Win32_Printer | Where-Object { $_.Network -eq $true }
        } catch [System.Exception] {
            Write-Verbose "Win32_Printer CIM query failed: $($_.Exception.Message)"
        }
    }

    if ($installed.Count -gt 0) {
        $printerLines = @()
        foreach ($p in $installed) {
            $isDef = if ($p.Default) { " [DEFAULT]" } else { "" }
            $printerLines += ("$($BOX.CHECK)  {0,-35} {1}" -f $p.Name, $isDef)
        }
        $printerLines += ""
        $printerLines += "Total Network Printers: $($installed.Count)"
        Show-NoticeBox -Header "MAPPED PRINTER CONNECTIONS" -BodyLines $printerLines -Color Green
    } else {
        Show-NoticeBox -Header "NO NETWORK PRINTERS FOUND" -BodyLines @(
            "No shared network printers are currently installed in this user profile."
        ) -Color Yellow
    }

    if (-not $NoPause -and $Host.Name -eq "ConsoleHost") {
        Write-Host "`nPress any key to close..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    Release-WScriptNetwork
    exit 0
}

# -------------------------------------------------------------
# ACTION: List Available Printers on Remote Server
# -------------------------------------------------------------
if ($ListAvailable) {
    Show-SectionHeader -StepTitle "REMOTE DISCOVERY: SHARED QUEUES ON $serverClean" -Color Cyan

    $targets = @($serverClean)
    if ($FallbackIP) { $targets += "\\$FallbackIP" }

    $foundPrinters = @()
    foreach ($target in $targets) {
        try {
            $cleanTarget = $target -replace '["\r\n]', ''
            $netView = & $script:NET_EXE view $cleanTarget 2>&1
            $printerLines = $netView | Where-Object { $_ -match "Print|Skrivare" }
            foreach ($line in $printerLines) {
                $parts = $line -split '\s{2,}'
                if ($parts.Count -ge 1) {
                    $item = $parts[0].Trim()
                    if ($item -and -not ($foundPrinters -contains $item)) {
                        $foundPrinters += $item
                    }
                }
            }
            if ($foundPrinters.Count -gt 0) { break }
        } catch [System.Exception] {
            Write-Verbose "net view query failed for ${target}: $($_.Exception.Message)"
        }
    }

    if ($foundPrinters.Count -gt 0) {
        $queueLines = $foundPrinters | ForEach-Object { "$($BOX.ARROW) $_" }
        Show-NoticeBox -Header "AVAILABLE SHARED PRINTERS" -BodyLines $queueLines -Color Green
    } else {
        Show-NoticeBox -Header "DISCOVERY FAILED" -BodyLines @(
            "Could not enumerate shares on '$serverClean' or '$FallbackIP'.",
            "Verify that you are connected to the internal network and server is online."
        ) -Color Yellow
    }

    if (-not $NoPause -and $Host.Name -eq "ConsoleHost") {
        Write-Host "`nPress any key to close..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    Release-WScriptNetwork
    exit 0
}

# -------------------------------------------------------------
# CORE COMMON ENGINES
# -------------------------------------------------------------
function Test-PrinterExists([string]$printerPath) {
    try {
        if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
            $p = Get-Printer -Name $printerPath -ErrorAction SilentlyContinue
            if ($p) { return $true }
        }
    } catch [System.Exception] {
        Write-Verbose "Get-Printer check failed: $($_.Exception.Message)"
    }
    try {
        $escPath = $printerPath -replace '\\', '\\'
        $cp = Get-CimInstance -ClassName Win32_Printer -Filter "Name = '$escPath'" -ErrorAction SilentlyContinue
        if ($cp) { return $true }
    } catch [System.Exception] {
        Write-Verbose "Win32_Printer check failed: $($_.Exception.Message)"
    }
    return $false
}

function Disconnect-PrinterSafe([string]$printerPath) {
    if (-not (Test-PrinterExists -printerPath $printerPath)) {
        return $false
    }

    $unmapped = $false
    try {
        if (Get-Command Remove-PrinterConnection -ErrorAction SilentlyContinue) {
            Remove-PrinterConnection -Name $printerPath -ErrorAction Stop
            $unmapped = -not (Test-PrinterExists -printerPath $printerPath)
        }
    } catch [System.Exception] {
        Write-Verbose "Remove-PrinterConnection failed for ${printerPath}: $($_.Exception.Message)"
    }

    if (-not $unmapped) {
        try {
            $net = Get-WScriptNetwork
            if ($net) {
                $net.RemovePrinterConnection($printerPath, $true, $true)
                $unmapped = -not (Test-PrinterExists -printerPath $printerPath)
            }
        } catch [System.Exception] {
            Write-Verbose "WScript.Network RemovePrinterConnection failed for ${printerPath}: $($_.Exception.Message)"
        }
    }

    if (-not $unmapped) {
        try {
            $cleanPath = $printerPath -replace '["\r\n]', ''
            $proc = Start-Process -FilePath $script:RUNDLL32_EXE -ArgumentList "printui.dll,PrintUIEntry /dn /n `"$cleanPath`" /q" -Wait -PassThru
            Start-Sleep -Milliseconds 300
            $unmapped = -not (Test-PrinterExists -printerPath $printerPath)
        } catch [System.Exception] {
            Write-Verbose "printui.dll disconnect failed for ${printerPath}: $($_.Exception.Message)"
        }
    }

    return $unmapped
}

# -------------------------------------------------------------
# ACTION: Uninstall Printers
# -------------------------------------------------------------
if ($Uninstall) {
    Show-SectionHeader -StepTitle "UNINSTALLATION: REMOVING PRINTER CONNECTIONS" -Color Yellow

    $uninstallResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $uninstalledCount = 0

    # Query currently installed network printers to avoid network/DNS timeouts
    $installedNetworkPrinters = @()
    try {
        if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
            $installedNetworkPrinters = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq "Connection" -or $_.PortName -like "\\*" })
        }
    } catch [System.Exception] {
        Write-Verbose "Get-Printer query failed: $($_.Exception.Message)"
    }
    if ($installedNetworkPrinters.Count -eq 0) {
        try {
            $installedNetworkPrinters = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue | Where-Object { $_.Network -eq $true })
        } catch [System.Exception] {
            Write-Verbose "Win32_Printer CIM query failed: $($_.Exception.Message)"
        }
    }

    foreach ($printer in $Printers) {
        $printerClean = $printer.Trim().TrimStart('\')
        
        # Match any installed printer ending in \$printerClean or equal to $printerClean
        $matches = @($installedNetworkPrinters | Where-Object { $_.Name -like "*\$printerClean" -or $_.Name -eq $printerClean })

        $wasRemoved = $false
        if ($matches.Count -gt 0) {
            foreach ($m in $matches) {
                $ok = Disconnect-PrinterSafe -printerPath $m.Name
                if ($ok) { $wasRemoved = $true }
            }
        } else {
            # Check direct fallback IP path just in case
            $directPath = "\\$FallbackIP\$printerClean"
            if (Test-PrinterExists -printerPath $directPath) {
                $ok = Disconnect-PrinterSafe -printerPath $directPath
                if ($ok) { $wasRemoved = $true }
            }
        }

        if ($wasRemoved) {
            $uninstalledCount++
            Write-Log ("  {0} {1,-14} : UNINSTALLED {2}" -f $BOX.ARROW, $printerClean, $BOX.CHECK) -ForegroundColor Green
            $uninstallResults.Add([PSCustomObject]@{
                Printer = $printerClean
                Status  = "Uninstalled"
                Mark    = $BOX.CHECK
            })
        } else {
            Write-Log ("  {0} {1,-14} : NOT INSTALLED" -f $BOX.ARROW, $printerClean) -ForegroundColor DarkGray
            $uninstallResults.Add([PSCustomObject]@{
                Printer = $printerClean
                Status  = "Not Installed"
                Mark    = "-"
            })
        }
    }

    $elapsedSeconds = $scriptStopwatch.Elapsed.TotalSeconds.ToString("F1")
    $summaryLines = @()
    foreach ($r in $uninstallResults) {
        $summaryLines += ("{0}  {1,-14} : {2}" -f $r.Mark, $r.Printer, $r.Status)
    }
    $summaryLines += ""
    $summaryLines += "Total: $($Printers.Count)  |  Uninstalled: $uninstalledCount  |  Duration: ${elapsedSeconds}s"
    $summaryLines += "Log Saved to: $LogPath"

    Show-NoticeBox -Header "UNINSTALLATION OUTCOME" -BodyLines $summaryLines -Color Green

    if (-not $NoPause -and $Host.Name -eq "ConsoleHost") {
        Write-Host "`nPress any key to close..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    Release-WScriptNetwork
    exit 0
}

# -------------------------------------------------------------
# ACTION: Install Printers (Default Flow)
# -------------------------------------------------------------

# Step 1: Automated Self-Healing & Spooler Health Diagnostic
Show-SectionHeader -StepTitle "STEP 1/4: LOCAL PRINT SPOOLER HEALTH & CLEANUP" -Color Cyan

# 1a. If running with admin privileges, ensure Point-and-Print policy is automatically configured
if ($isAdmin) {
    try {
        $policiesPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
        if (-not (Test-Path $policiesPath)) { New-Item -Path $policiesPath -Force | Out-Null }
        Set-SecureRegistryDWord -Path $policiesPath -Name "RestrictDriverInstallationToAdministrators" -Value 0
        Set-SecureRegistryDWord -Path $policiesPath -Name "PackagePointAndPrintServerList" -Value 1
        Set-SecureRegistryDWord -Path $policiesPath -Name "NoWarningNoElevationOnInstall" -Value 1
        Set-SecureRegistryDWord -Path $policiesPath -Name "UpdatePromptSettings" -Value 2
        $serverListPath = "$policiesPath\ListofServers"
        if (-not (Test-Path $serverListPath)) { New-Item -Path $serverListPath -Force | Out-Null }
        Set-SecureRegistryString -Path $serverListPath -Name $serverHost -Value $serverHost
        if ($FallbackIP) { Set-SecureRegistryString -Path $serverListPath -Name $FallbackIP -Value $FallbackIP }
        Write-Verbose "Automated Point-and-Print policy verification: Applied"
    } catch [System.Exception] {
        Write-Verbose "Automated Point-and-Print policy check encountered: $($_.Exception.Message)"
    }
}

# 1b. Check local Print Spooler service status and auto-recover
Write-Log "  $($BOX.ARROW) Spooler Service Status : " -NoNewLine
$spoolerOk = $false
try {
    $spoolerService = Get-Service -Name "Spooler" -ErrorAction Stop
    if ($spoolerService.Status -eq [ServiceProcess.ServiceControllerStatus]::Running) {
        Write-Log "RUNNING $($BOX.CHECK)" -ForegroundColor Green
        $spoolerOk = $true
    } else {
        Write-Log "STOPPED ($($spoolerService.Status))" -ForegroundColor Yellow
        Write-Log "  $($BOX.ARROW) Auto-recovering Print Spooler... " -NoNewLine
        try {
            Start-Service -Name "Spooler" -ErrorAction Stop
            Write-Log "STARTED $($BOX.CHECK)" -ForegroundColor Green
            $spoolerOk = $true
        } catch [System.Exception] {
            Write-Log "FAILED $($BOX.CROSS)" -ForegroundColor Red
            Write-Log "    Note: Starting the spooler requires Administrator rights: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
} catch [System.Exception] {
    Write-Log "WARNING (Could not query service: $($_.Exception.Message))" -ForegroundColor Yellow
}

# 1c. Clear corrupted stuck spooler files if elevated
if ($isAdmin -and $spoolerOk) {
    try {
        $spoolDir = Join-Path $script:SYSTEM32 "spool\PRINTERS"
        if (Test-Path $spoolDir) {
            $stuckFiles = Get-ChildItem -Path $spoolDir -Force -ErrorAction SilentlyContinue | Where-Object {
                -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)
            }
            if ($stuckFiles.Count -gt 0) {
                Write-Log "  $($BOX.ARROW) Flushing $($stuckFiles.Count) stale spool files... " -NoNewLine
                Stop-Service -Name "Spooler" -Force -ErrorAction SilentlyContinue
                $stuckFiles | Remove-Item -Force -ErrorAction SilentlyContinue
                Start-Service -Name "Spooler" -ErrorAction SilentlyContinue
                Write-Log "CLEARED $($BOX.CHECK)" -ForegroundColor Green
            }
        }
    } catch [System.Exception] {
        Write-Verbose "Automated spool flush skipped: $($_.Exception.Message)"
    }
}

# 1d. PaperCut MF Client diagnostic
Write-Log "  $($BOX.ARROW) PaperCut MF Client     : " -NoNewLine
$pcStatus = Get-PaperCutClientStatus
if ($pcStatus.Running) {
    Write-Log "RUNNING (PID $($pcStatus.ProcessId)) $($BOX.CHECK)" -ForegroundColor Green
} elseif ($pcStatus.Path) {
    Write-Log "STOPPED (Found at $($pcStatus.Path))" -ForegroundColor Yellow
    if ($StartPaperCut) {
        Write-Log "  $($BOX.ARROW) Launching PaperCut... " -NoNewLine
        if (Start-PaperCutClientSafe) {
            Write-Log "STARTED $($BOX.CHECK)" -ForegroundColor Green
        } else {
            Write-Log "FAILED $($BOX.CROSS)" -ForegroundColor Red
        }
    } else {
        Write-Log "    Note: PaperCut client must be running to release jobs at copiers." -ForegroundColor DarkGray
    }
} else {
    Write-Log "NOT DETECTED (Run pc-client to release jobs)" -ForegroundColor DarkGray
}

# Step 2: Network & Server Reachability with Interactive Retry Loop
Show-SectionHeader -StepTitle "STEP 2/4: NETWORK & SERVER REACHABILITY" -Color Cyan

$networkLoopActive = $true

while ($networkLoopActive) {
    Write-Log "  $($BOX.ARROW) DNS Host Resolution   : " -NoNewLine
    $activeServer = ""
    $resolvedIPs = @()

    try {
        $dnsTask = [System.Net.Dns]::GetHostAddressesAsync($serverHost)
        if ($dnsTask.Wait(2000)) {
            $rawIPs = @($dnsTask.Result | ForEach-Object { $_.IPAddressToString })
            # Block public IPs from DNS to prevent NetNTLM hash capture (CWE-200/CWE-300)
            $privateIPs = @($rawIPs | Where-Object { Test-IsPrivateIPAddress $_ })
            if ($privateIPs.Count -gt 0) {
                $resolvedIPs = $privateIPs
                Write-Log "OK ($($resolvedIPs -join ', ')) $($BOX.CHECK)" -ForegroundColor Green
                $activeServer = $serverClean
            } else {
                Write-Log "REJECTED (DNS returned public IP: $($rawIPs -join ', ')) $($BOX.CROSS)" -ForegroundColor Yellow
            }
        } else {
            Write-Log "PRIMARY DNS UNRESOLVED" -ForegroundColor Yellow
        }
    } catch [System.Exception] {
        Write-Log "PRIMARY DNS UNRESOLVED" -ForegroundColor Yellow
    }

    # 2b. Secondary DNS Check against Internal Domain Controllers
    $resolvedInternalIP = ""
    if ($resolvedIPs.Count -eq 0) {
        Write-Log "  $($BOX.ARROW) Querying Internal DNS : " -NoNewLine
        foreach ($dc in $InternalDNSServers) {
            try {
                $internalDnsRes = Resolve-DnsName -Name $serverHost -Server $dc -QuickTimeout -ErrorAction Stop
                if ($internalDnsRes) {
                    $ips = @($internalDnsRes | Where-Object IPAddress | Select-Object -ExpandProperty IPAddress | Where-Object { Test-IsPrivateIPAddress $_ })
                    if ($ips.Count -gt 0) {
                        $resolvedInternalIP = $ips[0]
                        Write-Log "RESOLVED via $dc ($($ips -join ', ')) $($BOX.CHECK)" -ForegroundColor Green
                        break
                    }
                }
            } catch [System.Exception] {
                Write-Verbose "Internal DNS query to $dc failed: $($_.Exception.Message)"
            }
        }
        if (-not $resolvedInternalIP) {
            Write-Log "NOT DIRECTLY RESOLVABLE (Custom DNS / DoH active)" -ForegroundColor Yellow
        }
    }

    # 2c. Target selection: If primary DNS cannot resolve the FQDN in Windows, target the IP directly
    if (-not $activeServer) {
        $ipTarget = if ($resolvedInternalIP) { $resolvedInternalIP } else { $FallbackIP }
        Write-Log "  $($BOX.ARROW) Direct Server Target  : USING IP DIRECTLY ($ipTarget) $($BOX.CHECK)" -ForegroundColor Cyan
        $activeServer = "\\$ipTarget"
    }

    # 2d. SMB Port 445 Handshake
    $targetHostForSMB = $activeServer.TrimStart('\')
    Write-Log "  $($BOX.ARROW) Port 445 (SMB) Check  : " -NoNewLine
    $tcpClient = New-Object System.Net.Sockets.TcpClient
    # Disable socket linger to immediately free OS socket descriptors upon close (CWE-400)
    $tcpClient.LingerState = New-Object System.Net.Sockets.LingerOption($true, 0)
    $smbReachable = $false
    try {
        $connectTask = $tcpClient.ConnectAsync($targetHostForSMB, 445)
        if ($connectTask.Wait(2500)) {
            $smbReachable = $true
            Write-Log "OPEN on $targetHostForSMB $($BOX.CHECK)" -ForegroundColor Green
        } else {
            Write-Log "TIMEOUT ($targetHostForSMB:445 unreachable) $($BOX.CROSS)" -ForegroundColor Yellow
        }
    } catch [System.Exception] {
        $errMsg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        Write-Log "UNREACHABLE ($errMsg) $($BOX.CROSS)" -ForegroundColor Yellow
    } finally {
        try {
            if ($tcpClient.Client) { $tcpClient.Client.Close(0) }
            $tcpClient.Close()
            $tcpClient.Dispose()
        } catch [System.Exception] {
            Write-Verbose "Socket cleanup: $($_.Exception.Message)"
        }
    }

    # 2e. Ping ICMP RTT Latency Telemetry
    Write-Log "  $($BOX.ARROW) Ping Latency (ICMP)   : " -NoNewLine
    try {
        $pinger = New-Object System.Net.NetworkInformation.Ping
        $reply = $pinger.Send($targetHostForSMB, 1500)
        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            Write-Log "$($reply.RoundtripTime) ms ($targetHostForSMB) $($BOX.CHECK)" -ForegroundColor Green
        } else {
            Write-Log "FILTERED ($($reply.Status))" -ForegroundColor Yellow
        }
        $pinger.Dispose()
    } catch [System.Exception] {
        Write-Log "SKIPPED ($($_.Exception.Message))" -ForegroundColor DarkGray
    }

    if ($smbReachable -or $ForceInstall) {
        $networkLoopActive = $false
    } else {
        # Check if running interactively in a console vs automated background (Intune / Company Portal)
        $isInteractiveConsole = ($Host.Name -eq "ConsoleHost" -and [Environment]::UserInteractive)

        if ($isInteractiveConsole -and -not $NoPause) {
            Show-NoticeBox -Header "NETWORK NOT REACHABLE: RETRY?" -BodyLines @(
                "Cannot reach print server '$targetHostForSMB' on Port 445 (SMB).",
                "Current SSID: $(Get-ActiveSSID)",
                "",
                "Please connect to the GTG school Wi-Fi (GTC Student / Staff) or VPN.",
                "Type 'R' and press Enter to retry, or press Enter / 'Q' to exit."
            ) -Color Yellow

            $choice = Read-Host "`n  Action: Enter 'R' to Retry, or press Enter/Q to Exit"
            if ($choice -and $choice.Trim() -match '^(r|retry)$') {
                Write-Host "`nRefreshing network interfaces and retrying...`n" -ForegroundColor Cyan
                try {
                    Clear-DnsClientCache -ErrorAction SilentlyContinue
                } catch [System.Exception] {
                    Write-Verbose "Clear-DnsClientCache failed: $($_.Exception.Message)"
                }
                Start-Sleep -Seconds 2
                continue
            } else {
                Release-WScriptNetwork
                exit 2
            }
        } else {
            # Non-interactive / Company Portal mode: log diagnostic and exit immediately with exit code 2
            Show-NoticeBox -Header "CONNECTION BLOCKED: SERVER UNREACHABLE" -BodyLines @(
                "Cannot reach print server '$targetHostForSMB' on Port 445 (SMB).",
                "",
                "DIAGNOSTICS:",
                " * Active Network SSID : $(Get-ActiveSSID)",
                " * Target Server       : $activeServer",
                " * SMB Port 445        : BLOCKED / Unreachable",
                "",
                "REASON & SOLUTION:",
                " Device must be connected to the GTG school network (GTC Student/Staff).",
                " (To attempt installation anyway, re-run with: .\Install-Printers.ps1 -ForceInstall)"
            ) -Color Red
            Release-WScriptNetwork
            exit 2
        }
    }
}

# Step 3: Multi-layer Connection Engines
Show-SectionHeader -StepTitle "STEP 3/4: INSTALLING & MAPPING PRINTERS" -Color Cyan

function Connect-PrinterSafe {
    param(
        [string]$printerPath,
        [scriptblock]$OnProgress = $null
    )
    $errors = @{}

    # Engine 1: WMI Win32_Printer Method
    if ($OnProgress) { & $OnProgress 25 "Connecting via Engine 1/4 (WMI)..." }
    try {
        $wmiPrinterClass = [wmiclass]"Win32_Printer"
        $result = $wmiPrinterClass.AddPrinterConnection($printerPath)
        if ($result.ReturnValue -eq 0) {
            return @{ Success = $true; Engine = "Win32_Printer.AddPrinterConnection (WMI)" }
        } else {
            $errors["Engine1_WMI"] = "WMI error code: $($result.ReturnValue)"
        }
    } catch [System.Exception] {
        $errors["Engine1_WMI"] = $_.Exception.Message
    }

    # Engine 2: Windows PrintManagement PowerShell Cmdlet
    if ($OnProgress) { & $OnProgress 50 "Connecting via Engine 2/4 (Add-PrinterConnection)..." }
    try {
        if (Get-Command Add-PrinterConnection -ErrorAction SilentlyContinue) {
            Add-PrinterConnection -Name $printerPath -ErrorAction Stop
            return @{ Success = $true; Engine = "Add-PrinterConnection (PowerShell)" }
        }
    } catch [System.Exception] {
        $errors["Engine2_Cmdlet"] = $_.Exception.Message
    }

    # Engine 3: WScript.Network COM Object
    if ($OnProgress) { & $OnProgress 75 "Connecting via Engine 3/4 (WScript.Network COM)..." }
    try {
        $net = Get-WScriptNetwork
        if ($net) {
            $net.AddWindowsPrinterConnection($printerPath)
            return @{ Success = $true; Engine = "WScript.Network (COM)" }
        }
    } catch [System.Exception] {
        $errors["Engine3_COM"] = $_.Exception.Message
    }

    # Engine 4: printui.dll Windows API
    if ($OnProgress) { & $OnProgress 90 "Connecting via Engine 4/4 (printui.dll API)..." }
    try {
        $cleanPath = $printerPath -replace '["\r\n]', ''
        $proc = Start-Process -FilePath $script:RUNDLL32_EXE -ArgumentList "printui.dll,PrintUIEntry /in /n `"$cleanPath`" /q" -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            Start-Sleep -Milliseconds 500
            return @{ Success = $true; Engine = "printui.dll /in (Windows API)" }
        } else {
            $errors["Engine4_PrintUI"] = "rundll32 printui.dll exit code $($proc.ExitCode)"
        }
    } catch [System.Exception] {
        $errors["Engine4_PrintUI"] = $_.Exception.Message
    }

    return @{ Success = $false; Errors = $errors }
}

function Set-DefaultPrinterSafe([string]$printerPath) {
    try {
        $net = Get-WScriptNetwork
        if ($net) {
            $net.SetDefaultPrinter($printerPath)
            return $true
        }
    } catch [System.Exception] {
        Write-Verbose "WScript.Network SetDefaultPrinter failed for ${printerPath}: $($_.Exception.Message)"
    }

    try {
        $escPath = $printerPath -replace '\\', '\\'
        $cimPrinter = Get-CimInstance -ClassName Win32_Printer -Filter "Name = '$escPath'" -ErrorAction Stop
        if ($cimPrinter) {
            Invoke-CimMethod -InputObject $cimPrinter -MethodName SetDefaultPrinter | Out-Null
            return $true
        }
    } catch [System.Exception] {
        Write-Verbose "CIM SetDefaultPrinter failed for ${printerPath}: $($_.Exception.Message)"
    }

    return $false
}

function Send-TestPageSafe([string]$printerPath) {
    try {
        $cleanPath = $printerPath -replace '["\r\n]', ''
        $proc = Start-Process -FilePath $script:RUNDLL32_EXE -ArgumentList "printui.dll,PrintUIEntry /k /n `"$cleanPath`"" -Wait -PassThru
        return ($proc.ExitCode -eq 0)
    } catch [System.Exception] {
        Write-Verbose "Send-TestPageSafe failed for ${printerPath}: $($_.Exception.Message)"
        return $false
    }
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$totalPrinters = $Printers.Count
$isInteractiveTerminal = ($Host.Name -eq "ConsoleHost" -and [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected)

for ($pIdx = 0; $pIdx -lt $totalPrinters; $pIdx++) {
    $printer = $Printers[$pIdx]
    $printerClean = $printer.Trim().TrimStart('\')
    $copierNum = $pIdx + 1

    $overallPct = [int][Math]::Round(($pIdx / $totalPrinters) * 100)
    Write-Log ""
    Write-Log "  Overall  : $(Get-ProgressBarString $overallPct) (Copier $copierNum of $totalPrinters)" -ForegroundColor Cyan

    if ($isInteractiveTerminal) {
        try {
            Write-Progress -Activity "GTG Printer Installation" -Status "Overall: $overallPct% (Copier $copierNum of $totalPrinters)" -PercentComplete $overallPct -Id 1
        } catch [System.Exception] {
            Write-Verbose "Write-Progress overall error: $($_.Exception.Message)"
        }
    }

    $candidatePaths = @("$activeServer\$printerClean")
    if ($FallbackIP -and $activeServer -ne "\\$FallbackIP") {
        $candidatePaths += "\\$FallbackIP\$printerClean"
    }

    Write-Log "  $($BOX.ARROW) [$copierNum/$totalPrinters] $printerClean" -ForegroundColor White
    Write-Log "    Target : $($candidatePaths[0])" -ForegroundColor DarkGray

    $installSuccess = $false
    $usedEngine = ""
    $usedUNC = ""
    $attemptErrors = @{}

    $onProgress = {
        param([int]$pct, [string]$stage)
        if ($isInteractiveTerminal) {
            Write-Host ("`r    Status : {0}  {1}      " -f (Get-ProgressBarString $pct), $stage) -ForegroundColor DarkCyan -NoNewline
            try {
                Write-Progress -Activity "GTG Printer Installation" -Status "[$copierNum/$totalPrinters] ${printerClean}: $stage" -PercentComplete $pct -Id 2 -ParentId 1
            } catch [System.Exception] {
                Write-Verbose "Write-Progress copier error: $($_.Exception.Message)"
            }
        }
    }

    foreach ($uncPath in $candidatePaths) {
        if ($RemoveExisting) {
            $null = Disconnect-PrinterSafe -printerPath $uncPath
        }

        for ($attempt = 1; $attempt -le ($MaxRetries + 1); $attempt++) {
            if ($attempt -gt 1) {
                if ($isInteractiveTerminal) { Write-Host "" }
                Write-Log "    [Retry $attempt/$($MaxRetries + 1)] Waiting $RetryDelaySeconds s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $RetryDelaySeconds
            }

            $res = Connect-PrinterSafe -printerPath $uncPath -OnProgress $onProgress
            if ($res.Success) {
                $installSuccess = $true
                $usedEngine = $res.Engine
                $usedUNC = $uncPath
                break
            } else {
                $attemptErrors = $res.Errors
            }
        }

        if ($installSuccess) { break }
    }

    if ($installSuccess) {
        if ($isInteractiveTerminal) {
            Write-Host ("`r    Status : {0}  CONNECTED {1} ({2})                                " -f (Get-ProgressBarString 100), $BOX.CHECK, $usedEngine) -ForegroundColor Green
        }
        Write-Log "    Status : $(Get-ProgressBarString 100) CONNECTED $($BOX.CHECK)" -ForegroundColor Green -NoConsole:$isInteractiveTerminal
        Write-Log "    Path   : $usedUNC" -ForegroundColor DarkCyan
        Write-Log "    Engine : $usedEngine" -ForegroundColor DarkCyan

        $isDefault = $false
        if ($DefaultPrinter -and ($DefaultPrinter -eq $printerClean -or $DefaultPrinter -eq $usedUNC -or $DefaultPrinter -eq $printer)) {
            Write-Log "    Default: " -NoNewLine
            if (Set-DefaultPrinterSafe -printerPath $usedUNC) {
                Write-Log "SET $($BOX.CHECK)" -ForegroundColor Green
                $isDefault = $true
            } else {
                Write-Log "FAILED $($BOX.CROSS)" -ForegroundColor Yellow
            }
        }

        if ($Duplex -and (Get-Command Set-PrintConfiguration -ErrorAction SilentlyContinue)) {
            try {
                Set-PrintConfiguration -PrinterName $usedUNC -DuplexingMode TwoSidedLongEdge -ErrorAction SilentlyContinue
                Write-Log "    Policy : Duplex (Two-Sided Long-Edge) $($BOX.CHECK)" -ForegroundColor DarkCyan
            } catch [System.Exception] {
                Write-Verbose "Could not configure duplex print ticket: $($_.Exception.Message)"
            }
        }

        $testPageSent = $false
        if ($PrintTestPage) {
            Write-Log "    TestPage: " -NoNewLine
            if (Send-TestPageSafe -printerPath $usedUNC) {
                Write-Log "SENT $($BOX.CHECK)" -ForegroundColor Green
                $testPageSent = $true
            } else {
                Write-Log "FAILED $($BOX.CROSS)" -ForegroundColor Yellow
            }
        }

        $results.Add([PSCustomObject]@{
            Printer   = $printerClean
            UNCPath   = $usedUNC
            Status    = "Connected"
            Engine    = $usedEngine
            IsDefault = $isDefault
            TestPage  = $testPageSent
            Error     = ""
        })
    } else {
        if ($isInteractiveTerminal) {
            Write-Host ("`r    Status : {0}  FAILED {1}                                         " -f (Get-ProgressBarString 0), $BOX.CROSS) -ForegroundColor Red
        }
        Write-Log "    Status : $(Get-ProgressBarString 0) FAILED $($BOX.CROSS)" -ForegroundColor Red -NoConsole:$isInteractiveTerminal
        
        $translatedErrors = @()
        foreach ($key in $attemptErrors.Keys) {
            $rawMsg = $attemptErrors[$key]
            $friendlyMsg = Get-FriendlyErrorMessage -rawError $rawMsg
            Write-Log "    Details: $key -> $friendlyMsg" -ForegroundColor Red
            $translatedErrors += "${key}: $friendlyMsg"
        }

        $results.Add([PSCustomObject]@{
            Printer   = $printerClean
            UNCPath   = $candidatePaths[0]
            Status    = "Failed"
            Engine    = "None"
            IsDefault = $false
            TestPage  = $false
            Error     = ($translatedErrors -join " | ")
        })
    }
}

if ($isInteractiveTerminal) {
    try {
        Write-Progress -Activity "GTG Printer Installation" -Completed -Id 2
        Write-Progress -Activity "GTG Printer Installation" -Completed -Id 1
    } catch [System.Exception] {
        Write-Verbose "Write-Progress complete error: $($_.Exception.Message)"
    }
}

Write-Log ""
Write-Log "  Overall  : $(Get-ProgressBarString 100) (All $totalPrinters copiers processed)" -ForegroundColor Green

# Step 4: Final Summary Report
Show-SectionHeader -StepTitle "STEP 4/4: FINAL INSTALLATION SUMMARY" -Color Cyan

$successCount = @($results | Where-Object { $_.Status -eq "Connected" }).Count
$failCount = @($results | Where-Object { $_.Status -eq "Failed" }).Count
$elapsedSeconds = $scriptStopwatch.Elapsed.TotalSeconds.ToString("F1")

$summaryLines = @()
foreach ($r in $results) {
    $mark = if ($r.Status -eq "Connected") { $BOX.CHECK } else { $BOX.CROSS }
    $defaultMark = if ($r.IsDefault) { " [DEFAULT]" } else { "" }
    $testMark = if ($r.TestPage) { " [TEST PAGE SENT]" } else { "" }
    $summaryLines += ("$mark  {0,-14} : {1}{2}{3} ({4})" -f $r.Printer, $r.Status, $defaultMark, $testMark, $r.Engine)
}
$summaryLines += ""
$summaryLines += "Total: $($results.Count)  |  Succeeded: $successCount  |  Failed: $failCount  |  Duration: ${elapsedSeconds}s"
$summaryLines += "Log Saved to: $LogPath"

$summaryColor = if ($failCount -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green }
Show-NoticeBox -Header "INSTALLATION OUTCOME" -BodyLines $summaryLines -Color $summaryColor

if (-not $NoPause -and $Host.Name -eq "ConsoleHost") {
    Write-Host "`nPress any key to close this window..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

Release-WScriptNetwork

if ($failCount -gt 0) { exit 1 } else { exit 0 }