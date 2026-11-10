# Detection Script for Microsoft Intune / Company Portal
# Checks if the required GTG network copiers are mapped in the user profile

$RequiredPrinters = @(
    "L-Kopiator",
    "TB-Kopiator",
    "PB-Kopiator"
)

$installedPrinters = @()

# Query installed printers via Get-Printer cmdlet
try {
    if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
        $installedPrinters = Get-Printer -ErrorAction SilentlyContinue | Where-Object { 
            $_.Type -eq "Connection" -or $_.PortName -like "\\*" 
        }
    }
} catch {}

# Fallback to WMI if cmdlet returned nothing
if ($installedPrinters.Count -eq 0) {
    try {
        $installedPrinters = Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue | Where-Object { 
            $_.Network -eq $true 
        }
    } catch {}
}

# Verify that each required printer is mapped
$missingCount = 0
foreach ($req in $RequiredPrinters) {
    $found = $installedPrinters | Where-Object { $_.Name -like "*$req*" }
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