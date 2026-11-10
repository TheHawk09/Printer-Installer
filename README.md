# Printer-Installer

Enterprise-grade utility for mapping, testing, and managing shared network printers and copiers on Windows.

## Quick Start

### 1. Standard Run (End Users)
Double-click **[`Kopiator.bat`](Kopiator.bat)**.
* Automatically verifies network connectivity to `gtcps001.gtc.local`.
* Connects the 3 copiers (`L-Kopiator`, `TB-Kopiator`, `PB-Kopiator`).
* Displays a detailed status summary and logs results.

---

## Features & PowerShell CLI Options

[`Install-Printers.ps1`](Install-Printers.ps1) is self-contained with no external script dependencies.

### 1. Test Page Printing (`-PrintTestPage`)
Sends a physical Windows test page to the newly mapped printer to verify driver rendering and physical printing:
```powershell
.\Install-Printers.ps1 -PrintTestPage -DefaultPrinter "L-Kopiator"
```

### 2. Point-and-Print / PrintNightmare Trust Fix (`-FixPointAndPrint`)
On modern Windows 10/11 computers, Microsoft restricts non-admin users from downloading printer drivers from servers. Run this once as **Administrator** to whitelist the school print server in the registry:
```powershell
.\Install-Printers.ps1 -FixPointAndPrint
```

### 3. List Currently Installed Printers (`-ListInstalled`)
Lists all network printers mapped in your user profile:
```powershell
.\Install-Printers.ps1 -ListInstalled
```

### 4. Discover Printers on the Server (`-ListAvailable`)
Queries the print server to see all shared queues:
```powershell
.\Install-Printers.ps1 -ListAvailable
```

### 5. Clean Uninstaller (`-Uninstall`)
Unmaps the copiers cleanly:
```powershell
.\Install-Printers.ps1 -Uninstall
```

### 6. Persistent File Logging (`-LogPath`)
All runs log timestamped actions, network interface state, and error codes to `%TEMP%\PrinterInstaller.log` (or your custom `-LogPath`):
```powershell
Get-Content "$env:TEMP\PrinterInstaller.log" -Tail 30
```

---

## Redundancy & Reliability
The installer features a 4-tier fallback engine:
1. **Engine 1**: Native PowerShell PrintManagement (`Add-PrinterConnection`)
2. **Engine 2**: Windows Script Host COM (`WScript.Network.AddWindowsPrinterConnection`)
3. **Engine 3**: WMI / CIM (`Win32_Printer.AddPrinterConnection`)
4. **Engine 4**: Windows API directly via `rundll32 printui.dll,PrintUIEntry /in`