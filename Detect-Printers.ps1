# Detection Script for Microsoft Intune / Company Portal
# Checks if the required GTG network copiers are mapped in the user profile

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch [System.Exception] {
    Write-Verbose "Could not set Console::OutputEncoding to UTF8: $($_.Exception.Message)"
}

$RequiredPrinters = @(
    "L-Kopiator",
    "TB-Kopiator",
    "PB-Kopiator"
)

# Input validation for required printers (CWE-20)
foreach ($req in $RequiredPrinters) {
    if ($req -notmatch '^[a-zA-Z0-9_\-\.\s\\]+$') {
        Write-Error "Invalid printer name in detection configuration: '$req'."
        exit 1
    }
}

# Pre-flight check: Verify Print Spooler service is active
try {
    $spooler = Get-Service -Name "Spooler" -ErrorAction SilentlyContinue
    if ($spooler -and $spooler.Status -ne [ServiceProcess.ServiceControllerStatus]::Running) {
        # Spooler is stopped; printer queries cannot succeed
        exit 1
    }
} catch [System.Exception] {
    Write-Verbose "Spooler check failed: $($_.Exception.Message)"
}

$installedPrinters = @()

# Query installed printers via Get-Printer cmdlet
try {
    if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
        $installedPrinters = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { 
            $_.Type -eq "Connection" -or $_.PortName -like "\\*" 
        })
    }
} catch [System.Exception] {
    Write-Verbose "Get-Printer detection query failed: $($_.Exception.Message)"
}

# Fallback to WMI if cmdlet returned nothing
if ($installedPrinters.Count -eq 0) {
    try {
        $installedPrinters = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue | Where-Object { 
            $_.Network -eq $true 
        })
    } catch [System.Exception] {
        Write-Verbose "Win32_Printer detection query failed: $($_.Exception.Message)"
    }
}

# Verify that each required printer is mapped
$missingCount = 0
foreach ($req in $RequiredPrinters) {
    $found = $installedPrinters | Where-Object { $_.Name -like "*\$req" -or $_.Name -eq $req }
    if (-not $found) {
        $missingCount++
    }
}

# Intune detection rule logic:
# - Emit string and exit 0 = Detected (Installed)
# - No output or non-zero exit = Not Detected (Triggers installation)
if ($missingCount -eq 0) {
    Write-Output "Installed"
    exit 0
} else {
    exit 1
}