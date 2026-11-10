<#
.SYNOPSIS
    Enterprise-grade installer, manager, and troubleshooter for network printers/copiers.

.DESCRIPTION
    Installs, maps, tests, uninstalls, and diagnoses shared network printers.
    Includes:
    - Automatic server resolution with direct IP fallback (172.16.0.32) for custom/NextDNS setups
    - 4-layer connection redundancy (PrintManagement, WScript.Network COM, WMI, printui.dll)
    - PrintNightmare / Point-and-Print driver trust fix for Windows 10/11
    - Automated test page printing (/k)
    - Printer discovery and status listing (-ListAvailable, -ListInstalled)
    - Clean uninstallation mode (-Uninstall)
    - Timestamped persistent file logging
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
    Requires running as Administrator.

.PARAMETER Uninstall
    Uninstalls/unmaps the specified printers (or all printers from this server) from the user's profile.

.PARAMETER ListInstalled
    Displays all network printers currently connected to this machine.

.PARAMETER ListAvailable
    Queries the print server to list all publicly visible shared printers.

.PARAMETER LogPath
    Path to write a persistent diagnostic log file. Default: "$env:TEMP\PrinterInstaller.log".

.PARAMETER RemoveExisting
    Removes existing printer connections matching the given names before reconnecting.

.PARAMETER ForceInstall
    Bypasses pre-flight network reachability guards.

.PARAMETER NoPause
    Suppresses the "Press any key to close..." prompt upon completion.
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

    [int]$MaxRetries = 1,
    [int]$RetryDelaySeconds = 2,
    [string]$LogPath = "$env:TEMP\PrinterInstaller.log",
    [switch]$NoPause
)

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
}

$MIN_TUI_WIDTH = 75
$MAX_TUI_WIDTH = 100

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

function Write-Log {
    param(
        [string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,
        [switch]$NoConsole,
        [switch]$NoNewLine
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logEntry = "[$timestamp] $Message"

    try {
        Add-Content -Path $LogPath -Value $logEntry -ErrorAction SilentlyContinue
    } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
        # Non-fatal log write error
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

function Show-BoxTitle {
    param(
        [string]$Title,
        [string[]]$Lines = @(),
        [ConsoleColor]$BorderColor = [ConsoleColor]::Cyan,
        [ConsoleColor]$TextColor = [ConsoleColor]::White
    )
    $w = Get-DynamicWidth -Lines (@($Title) + $Lines)
    # Store global TUI width so all subsequent section headers match the outer banner
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

$ssidName = ((Get-NetConnectionProfile | Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue) -join ', ')
if (-not $ssidName) { $ssidName = "Disconnected / Unknown" }

$headerInfo = @(
    "Server    : $serverClean (Fallback IP: $FallbackIP)",
    "User      : $env:USERDOMAIN\$env:USERNAME",
    "Privilege : $(if ($isAdmin) { 'Administrator (Elevated)' } else { 'Standard User' })",
    "Network   : $ssidName",
    "Log File  : $LogPath"
)

Write-Log ""
Show-BoxTitle -Title "ENTERPRISE NETWORK PRINTER MANAGER" -Lines $headerInfo -BorderColor Cyan -TextColor DarkCyan

# -------------------------------------------------------------
# ACTION: Fix Point-and-Print (PrintNightmare Registry Policy)
# -------------------------------------------------------------
if ($FixPointAndPrint) {
    Show-SectionHeader -StepTitle "POLICY CONFIGURATION: POINT-AND-PRINT TRUST" -Color Yellow
    if (-not $isAdmin) {
        Show-NoticeBox -Header "ADMINISTRATIVE PRIVILEGES REQUIRED" -BodyLines @(
            "Applying Point-and-Print policies requires elevation.",
            "Please re-launch PowerShell as Administrator with:",
            "powershell -ExecutionPolicy Bypass -File .\Install-Printers.ps1 -FixPointAndPrint"
        ) -Color Red
        exit 1
    }

    try {
        $policiesPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
        if (-not (Test-Path $policiesPath)) {
            New-Item -Path $policiesPath -Force | Out-Null
        }

        Set-ItemProperty -Path $policiesPath -Name "RestrictDriverInstallationToAdministrators" -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $policiesPath -Name "PackagePointAndPrintServerList" -Value 1 -Type DWord -Force

        $serverListPath = "$policiesPath\ListofServers"
        if (-not (Test-Path $serverListPath)) {
            New-Item -Path $serverListPath -Force | Out-Null
        }
        Set-ItemProperty -Path $serverListPath -Name $serverHost -Value $serverHost -Type String -Force
        if ($FallbackIP) {
            Set-ItemProperty -Path $serverListPath -Name $FallbackIP -Value $FallbackIP -Type String -Force
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
            $netView = net.exe view $target 2>&1
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
    exit 0
}

# -------------------------------------------------------------
# CORE COMMON ENGINES
# -------------------------------------------------------------
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

function Disconnect-PrinterSafe([string]$printerPath) {
    $unmapped = $false
    try {
        if (Get-Command Remove-PrinterConnection -ErrorAction SilentlyContinue) {
            Remove-PrinterConnection -Name $printerPath -ErrorAction Stop
            $unmapped = $true
        }
    } catch [System.Exception] {
        Write-Verbose "Remove-PrinterConnection failed for ${printerPath}: $($_.Exception.Message)"
    }

    if (-not $unmapped) {
        try {
            $net = Get-WScriptNetwork
            if ($net) {
                $net.RemovePrinterConnection($printerPath, $true, $true)
                $unmapped = $true
            }
        } catch [System.Exception] {
            Write-Verbose "WScript.Network RemovePrinterConnection failed for ${printerPath}: $($_.Exception.Message)"
        }
    }

    if (-not $unmapped) {
        try {
            $proc = Start-Process rundll32.exe -ArgumentList "printui.dll,PrintUIEntry /dn /n `"$printerPath`" /q" -Wait -PassThru
            if ($proc.ExitCode -eq 0) { $unmapped = $true }
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

    $uninstalledCount = 0
    foreach ($printer in $Printers) {
        $printerClean = $printer.Trim().TrimStart('\')
        # Try both server names and IP formats
        $possiblePaths = @(
            "$serverClean\$printerClean",
            "\\$FallbackIP\$printerClean"
        )

        foreach ($pPath in $possiblePaths) {
            Write-Log "  $($BOX.ARROW) Removing: $pPath ... " -NoNewLine
            $ok = Disconnect-PrinterSafe -printerPath $pPath
            if ($ok) {
                Write-Log "REMOVED" -ForegroundColor Green
                $uninstalledCount++
            } else {
                Write-Log "NOT FOUND / SKIPPED" -ForegroundColor DarkGray
            }
        }
    }

    Show-NoticeBox -Header "UNINSTALLATION COMPLETE" -BodyLines @(
        "Successfully removed $uninstalledCount printer connection(s)."
    ) -Color Green

    if (-not $NoPause -and $Host.Name -eq "ConsoleHost") {
        Write-Host "`nPress any key to close..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    exit 0
}

# -------------------------------------------------------------
# ACTION: Install Printers (Default Flow)
# -------------------------------------------------------------

# Step 1: Spooler Health Diagnostic
Show-SectionHeader -StepTitle "STEP 1/4: LOCAL PRINT SPOOLER DIAGNOSTIC" -Color Cyan
Write-Log "  $($BOX.ARROW) Spooler Service Status: " -NoNewLine
try {
    $spoolerService = Get-Service -Name "Spooler" -ErrorAction Stop
    if ($spoolerService.Status -eq [ServiceProcess.ServiceControllerStatus]::Running) {
        Write-Log "RUNNING $($BOX.CHECK)" -ForegroundColor Green
    } else {
        Write-Log "STOPPED ($($spoolerService.Status))" -ForegroundColor Yellow
        Write-Log "  $($BOX.ARROW) Attempting to start Print Spooler... " -NoNewLine
        try {
            Start-Service -Name "Spooler" -ErrorAction Stop
            Write-Log "STARTED $($BOX.CHECK)" -ForegroundColor Green
        } catch [System.Exception] {
            Write-Log "FAILED $($BOX.CROSS)" -ForegroundColor Red
            Write-Log "    Note: Starting the spooler requires Administrator rights: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
} catch [System.Exception] {
    Write-Log "WARNING (Could not query service: $($_.Exception.Message))" -ForegroundColor Yellow
}

# Step 2: Network & Server Reachability
Show-SectionHeader -StepTitle "STEP 2/4: NETWORK & SERVER REACHABILITY" -Color Cyan

# 2a. Primary DNS Resolution
Write-Log "  $($BOX.ARROW) DNS Host Resolution   : " -NoNewLine
$activeServer = ""
$resolvedIPs = @()

try {
    $dnsTask = [System.Net.Dns]::GetHostAddressesAsync($serverHost)
    if ($dnsTask.Wait(2000)) {
        $resolvedIPs = $dnsTask.Result | ForEach-Object { $_.IPAddressToString }
        Write-Log "OK ($($resolvedIPs -join ', ')) $($BOX.CHECK)" -ForegroundColor Green
        $activeServer = $serverClean
    } else {
        Write-Log "PRIMARY DNS UNRESOLVED" -ForegroundColor Yellow
    }
} catch [System.Exception] {
    Write-Log "PRIMARY DNS UNRESOLVED" -ForegroundColor Yellow
}

# 2b. Secondary DNS Check against Internal Domain Controllers (172.16.0.7 / 172.16.0.8)
$resolvedInternalIP = ""
if ($resolvedIPs.Count -eq 0) {
    Write-Log "  $($BOX.ARROW) Querying Internal DNS : " -NoNewLine
    foreach ($dc in $InternalDNSServers) {
        try {
            $internalDnsRes = Resolve-DnsName -Name $serverHost -Server $dc -QuickTimeout -ErrorAction Stop
            if ($internalDnsRes) {
                $ips = @($internalDnsRes | Where-Object IPAddress | Select-Object -ExpandProperty IPAddress)
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
    $tcpClient.Close()
    $tcpClient.Dispose()
}

if (-not $smbReachable -and -not $ForceInstall) {
    Show-NoticeBox -Header "CONNECTION BLOCKED: SERVER UNREACHABLE" -BodyLines @(
        "Cannot reach print server '$targetHostForSMB' on Port 445 (SMB).",
        "",
        "DIAGNOSTICS:",
        " * Active Network SSID : $ssidName",
        " * Target Server       : $activeServer",
        " * SMB Port 445        : BLOCKED / Unreachable",
        "",
        "REASON & SOLUTION:",
        " Ensure you are connected to the school network (GTC Student/Staff).",
        " (To attempt installation anyway, re-run with: .\Install-Printers.ps1 -ForceInstall)"
    ) -Color Red

    if (-not $NoPause -and $Host.Name -eq "ConsoleHost") {
        Write-Host "`nPress any key to exit..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    exit 2
}

# Step 3: Multi-layer Connection Engines
Show-SectionHeader -StepTitle "STEP 3/4: INSTALLING & MAPPING PRINTERS" -Color Cyan

function Connect-PrinterSafe([string]$printerPath) {
    $errors = @{}

    # Engine 1: WMI Win32_Printer Method (Highest reliability across IP & FQDN shares)
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
    try {
        if (Get-Command Add-PrinterConnection -ErrorAction SilentlyContinue) {
            Add-PrinterConnection -Name $printerPath -ErrorAction Stop
            return @{ Success = $true; Engine = "Add-PrinterConnection (PowerShell)" }
        }
    } catch [System.Exception] {
        $errors["Engine2_Cmdlet"] = $_.Exception.Message
    }

    # Engine 3: WScript.Network COM Object
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
    try {
        $proc = Start-Process -FilePath "rundll32.exe" -ArgumentList "printui.dll,PrintUIEntry /in /n `"$printerPath`" /q" -Wait -PassThru
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
        $proc = Start-Process rundll32.exe -ArgumentList "printui.dll,PrintUIEntry /k /n `"$printerPath`"" -Wait -PassThru
        return ($proc.ExitCode -eq 0)
    } catch [System.Exception] {
        Write-Verbose "Send-TestPageSafe failed for ${printerPath}: $($_.Exception.Message)"
        return $false
    }
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($printer in $Printers) {
    $printerClean = $printer.Trim().TrimStart('\')
    
    # Try primary target (FQDN or resolved server), with fallback to direct IP if different
    $candidatePaths = @("$activeServer\$printerClean")
    if ($FallbackIP -and $activeServer -ne "\\$FallbackIP") {
        $candidatePaths += "\\$FallbackIP\$printerClean"
    }

    Write-Log ""
    Write-Log "  $($BOX.ARROW) Mapping: $printerClean (Target: $($candidatePaths[0]))" -ForegroundColor White

    $installSuccess = $false
    $usedEngine = ""
    $usedUNC = ""
    $attemptErrors = @{}

    foreach ($uncPath in $candidatePaths) {
        if ($RemoveExisting) {
            $null = Disconnect-PrinterSafe -printerPath $uncPath
        }

        for ($attempt = 1; $attempt -le ($MaxRetries + 1); $attempt++) {
            if ($attempt -gt 1) {
                Write-Log "    [Retry $attempt/$($MaxRetries + 1)] Waiting $RetryDelaySeconds s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $RetryDelaySeconds
            }

            $res = Connect-PrinterSafe -printerPath $uncPath
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
        Write-Log "    Status : CONNECTED $($BOX.CHECK)" -ForegroundColor Green
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
        Write-Log "    Status : FAILED $($BOX.CROSS)" -ForegroundColor Red
        foreach ($key in $attemptErrors.Keys) {
            Write-Log "    Details: $key -> $($attemptErrors[$key])" -ForegroundColor Red
        }

        $results.Add([PSCustomObject]@{
            Printer   = $printerClean
            UNCPath   = $candidatePaths[0]
            Status    = "Failed"
            Engine    = "None"
            IsDefault = $false
            TestPage  = $false
            Error     = ($attemptErrors.Values -join " | ")
        })
    }
}

# Step 4: Final Summary Report
Show-SectionHeader -StepTitle "STEP 4/4: FINAL INSTALLATION SUMMARY" -Color Cyan

$successCount = ($results | Where-Object { $_.Status -eq "Connected" }).Count
$failCount = ($results | Where-Object { $_.Status -eq "Failed" }).Count

$summaryLines = @()
foreach ($r in $results) {
    $mark = if ($r.Status -eq "Connected") { $BOX.CHECK } else { $BOX.CROSS }
    $defaultMark = if ($r.IsDefault) { " [DEFAULT]" } else { "" }
    $testMark = if ($r.TestPage) { " [TEST PAGE SENT]" } else { "" }
    $summaryLines += ("$mark  {0,-14} : {1}{2}{3} ({4})" -f $r.Printer, $r.Status, $defaultMark, $testMark, $r.Engine)
}
$summaryLines += ""
$summaryLines += "Total: $($results.Count)  |  Succeeded: $successCount  |  Failed: $failCount"
$summaryLines += "Log Saved to: $LogPath"

$summaryColor = if ($failCount -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green }
Show-NoticeBox -Header "INSTALLATION OUTCOME" -BodyLines $summaryLines -Color $summaryColor

if (-not $NoPause -and $Host.Name -eq "ConsoleHost") {
    Write-Host "`nPress any key to close this window..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

if ($failCount -gt 0) { exit 1 } else { exit 0 }
