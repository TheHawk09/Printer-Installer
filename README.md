# Printer-Installer

Enterprise-grade utility for mapping, testing, diagnosing, and managing shared network printers and copiers across GTG on Windows.

---

## Quick Start

### 1. Default Run (Install All Copiers)
Double-click **[`Kopiator.bat`](Kopiator.bat)** or run from PowerShell:
```powershell
.\Install-Printers.ps1
```
* Checks local Print Spooler service health.
* Resolves print server (`gtcps001.gtc.local` $\rightarrow$ `172.16.0.32`) with automatic DNS fallback if using NextDNS, VPN, or custom DoH.
* Verifies SMB port 445 connectivity.
* Maps **`L-Kopiator`**, **`TB-Kopiator`**, and **`PB-Kopiator`** with multi-tier engine fallback.

---

## Interactive Menu Mode (`-Menu`)

Run with `-Menu` to open an interactive terminal selector:
```powershell
.\Install-Printers.ps1 -Menu
```

```text
╔═════════════════════════════════════════════════════════════════════════╗
║                NETWORK PRINTER MANAGER - INTERACTIVE MENU               ║
╚═════════════════════════════════════════════════════════════════════════╝

  === INSTALLATION OPTIONS ===
  [1]  Install All Copiers (L-Kopiator, TB-Kopiator, PB-Kopiator)
  [2]  Install L-Kopiator only
  [3]  Install TB-Kopiator only
  [4]  Install PB-Kopiator only
  [5]  Install All & Print Test Page

  === MANAGEMENT & TOOLS ===
  [6]  List Installed Network Printers
  [7]  Discover Available Shares on Server
  [8]  Uninstall All Copiers
  [9]  Fix Point-and-Print Driver Policy (Requires Admin)
  [10] Open Diagnostic Log
  [0]  Exit
```

---

## Advanced CLI Commands & Switches

### 1. Test Page Printing (`-PrintTestPage`)
Sends a physical Windows test page (`printui.dll /k`) to verified printer(s) to confirm driver rendering:
```powershell
.\Install-Printers.ps1 -PrintTestPage -DefaultPrinter "L-Kopiator"
```

### 2. Point-and-Print Driver Trust Fix (`-FixPointAndPrint`)
Windows 10/11 blocks non-admin users from downloading printer drivers from remote servers (PrintNightmare mitigation). This command whitelists `gtcps001.gtc.local` and `172.16.0.32` in the Windows registry:
```powershell
.\Install-Printers.ps1 -FixPointAndPrint
```
> **Self-Elevation**: If run from a standard user terminal, the script automatically triggers a UAC elevation prompt and applies the policy.

### 3. List Installed Network Printers (`-ListInstalled`)
Lists all network printers mapped in your current Windows user profile:
```powershell
.\Install-Printers.ps1 -ListInstalled
```

### 4. Discover Shared Printers on Server (`-ListAvailable`)
Queries the print server to list all active print queues:
```powershell
.\Install-Printers.ps1 -ListAvailable
```

### 5. Uninstall Copiers (`-Uninstall`)
Unmaps the copiers cleanly:
```powershell
.\Install-Printers.ps1 -Uninstall
```
*(You can also pass `-Uninstall` via `Kopiator.bat -Uninstall`)*.

### 6. View Diagnostic Log (`-ShowLog`)
Opens the timestamped installer log file in Notepad:
```powershell
.\Install-Printers.ps1 -ShowLog
```
* Logs auto-rotate when exceeding 2 MB (`.old` archive created).

---

## Troubleshooting Guide

| Issue | Cause | Solution |
| :--- | :--- | :--- |
| **Primary DNS Unresolved** | Client uses NextDNS, Cloudflare (`1.1.1.1`), or Google DNS which cannot resolve internal `.gtc.local` domains. | **Handled automatically.** The script queries internal domain controllers (`172.16.0.7` / `172.16.0.8`) and falls back to direct IP `\\172.16.0.32`. |
| **SMB Port 445 Unreachable** | You are connected to a restricted Wi-Fi network that isolates clients (e.g. certain Guest SSIDs). | Switch Wi-Fi to **`GTC Student`**, **`GTC Staff`**, or connect via school VPN. |
| **Access Denied (0x80070005)** | Windows blocked driver installation due to Point-and-Print security policy. | Run `.\Install-Printers.ps1 -FixPointAndPrint` once to whitelist the server. |
| **PaperCut Login Required** | Printing is mapped, but jobs don't release at the physical copier. | Start the school PaperCut client (`pc-client.exe`) and sign in with your student/staff credentials. |

---

## Redundancy & Reliability
The installer features a 4-tier fallback engine:
1. **Engine 1**: WMI / CIM (`Win32_Printer.AddPrinterConnection`)
2. **Engine 2**: Native PowerShell PrintManagement (`Add-PrinterConnection`)
3. **Engine 3**: Windows Script Host COM (`WScript.Network.AddWindowsPrinterConnection`)
4. **Engine 4**: Direct Windows C API (`rundll32 printui.dll,PrintUIEntry /in`)