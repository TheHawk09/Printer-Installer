# Printer-Installer (Microsoft Intune / Company Portal)

Enterprise network printer deployment package for Microsoft Intune, Company Portal, and standalone administrative management across GTG.

---

## Microsoft Intune / Company Portal Deployment Guide

When packaging this repository as a Win32 App (`.intunewin`) in the Microsoft Intune Admin Center:

### 1. App Information
* **Name**: GTG Kopiatorer (L, TB, PB)
* **Description**: Installs and maps network copiers for GTG students and staff (`L-Kopiator`, `TB-Kopiator`, `PB-Kopiator`).
* **Publisher**: GTG IT

### 2. Program Setup
* **Install command**:
  ```cmd
  powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File .\Install-Printers.ps1 -NoPause
  ```
* **Uninstall command**:
  ```cmd
  powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File .\Install-Printers.ps1 -Uninstall -NoPause
  ```
* **Install behavior**: **User** (Network printer connections are per-user, not machine-wide).
* **Device restart behavior**: Determine behavior based on return codes (No restart).

### 3. Return Codes (Exit Codes)

| Return Code | Type | Meaning in Intune |
| :--- | :--- | :--- |
| **`0`** | **Success** | All requested copiers mapped successfully. |
| **`1`** | **Hard Error** | One or more printer connections failed. |
| **`2`** | **Fast-Fail / Retry** | Device is not on GTG network (SMB 445 unreachable). Intune will retry on next sync interval. |

### 4. Detection Rule
* **Rules format**: Use a custom script
* **Script file**: Select [`Detect-Printers.ps1`](Detect-Printers.ps1)
* **Run script as 32-bit process on 64-bit clients**: No
* **Enforce script signature check and display**: No
* *(Detects whether `L-Kopiator`, `TB-Kopiator`, and `PB-Kopiator` are all active in the user profile)*.

---

## Standalone / Manual Usage (CLI Tags)

Administrators and technicians can run [`Install-Printers.ps1`](Install-Printers.ps1) directly using command-line tags or double-clicking [`Kopiator.bat`](Kopiator.bat):

### 1. Default Run (Install All Copiers)
Installs and maps all three GTG network copiers (`L-Kopiator`, `TB-Kopiator`, `PB-Kopiator`) for the current user:
```powershell
.\Install-Printers.ps1
```
* Runs automated pre-flight self-healing (verifies Print Spooler, checks Point-and-Print driver policies, flushes stale spool cache).
* Resolves print server via internal DNS (`172.16.0.7`/`8`) or direct IP (`172.16.0.32`).
* Maps queues with 4-tier engine fallback (WMI, PowerShell, COM, Windows C API).

### 2. Install Specific Queues Only (`-Printers` / `-DefaultPrinter`)
Allows installing only the copier for a specific building or campus department, and optionally setting it as default:
```powershell
# Install L-Kopiator only and set as default:
.\Install-Printers.ps1 -Printers @("L-Kopiator") -DefaultPrinter "L-Kopiator"

# Install TB and PB copiers only:
.\Install-Printers.ps1 -Printers @("TB-Kopiator", "PB-Kopiator")
```

### 3. Install and Send Physical Test Page (`-PrintTestPage`)
Connects the queues and immediately sends a native Windows test page via `rundll32 printui.dll,PrintUIEntry /k` to verify physical printing and driver rendering on the hardware:
```powershell
.\Install-Printers.ps1 -PrintTestPage
```

### 4. Clean Uninstallation Mode (`-Uninstall`)
Unmaps and removes the GTG copier connections from the current user profile. Useful during student offboarding, computer reallocation, or troubleshooting corrupted printer user-profiles:
```powershell
.\Install-Printers.ps1 -Uninstall
```
*(Can also be invoked via `Kopiator.bat -Uninstall`)*.

### 5. Check Installed Queues (`-ListInstalled`)
Queries both the Windows Print Spooler and WMI `Win32_Printer` subsystem to display which network copiers are currently active in the user profile, marking which one is the system default:
```powershell
.\Install-Printers.ps1 -ListInstalled
```

### 6. Discover Available Server Queues (`-ListAvailable`)
Queries the remote print server (`gtcps001.gtc.local` / `172.16.0.32`) to dynamically list all publicly visible shared print queues:
```powershell
.\Install-Printers.ps1 -ListAvailable
```

### 7. Fix Point-and-Print Driver Policy (`-FixPointAndPrint`)
Windows 10 and 11 block non-administrative users from downloading shared printer drivers from remote servers (PrintNightmare security mitigation). This command whitelists `gtcps001.gtc.local` and `172.16.0.32` in `HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint`:
```powershell
.\Install-Printers.ps1 -FixPointAndPrint
```
> **Self-Elevation**: Automatically requests a Windows UAC prompt if executed in a standard user terminal.

### 8. Flush Stuck Spool Queues & Restart Spooler (`-RestartSpooler`)
Fixes hung printing by safely stopping the local Spooler service, purging corrupted or abandoned `.SPL` and `.SHD` spool files from `C:\Windows\System32\spool\PRINTERS`, and restarting the service:
```powershell
.\Install-Printers.ps1 -RestartSpooler
```
> **Self-Elevation**: Automatically requests a Windows UAC prompt if executed in a standard user terminal.

### 9. Open Windows Printers & Scanners GUI (`-OpenSettings`)
Directly launches the modern Windows 10/11 Settings app to the "Printers & Scanners" page (`ms-settings:printers`) for quick visual verification:
```powershell
.\Install-Printers.ps1 -OpenSettings
```

### 10. Interactive Terminal Menu (`-Menu`)
Presents a user-friendly numbered console menu to let technicians or students select operations without memorizing flags:
```powershell
.\Install-Printers.ps1 -Menu
```
```text
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
  [9]  Flush Queue & Restart Print Spooler (Requires Admin)
  [10] Fix Point-and-Print Driver Policy (Requires Admin)
  [11] Open Windows Printers & Scanners Settings
  [12] Open Diagnostic Log
  [0]  Exit
```

### 11. View Diagnostic Log (`-ShowLog`)
Opens the timestamped log file (`%TEMP%\PrinterInstaller.log`) directly in Notepad for instant review. The log automatically archives and rotates when exceeding 2 MB:
```powershell
.\Install-Printers.ps1 -ShowLog
```

---

## Troubleshooting Guide

| Issue | Cause | Solution |
| :--- | :--- | :--- |
| **Primary DNS Unresolved** | Client uses NextDNS, Cloudflare (`1.1.1.1`), or Google DNS which cannot resolve internal `.gtc.local` domains. | **Handled automatically.** The script queries internal domain controllers (`172.16.0.7` / `172.16.0.8`) and falls back to direct IP `\\172.16.0.32`. |
| **SMB Port 445 Unreachable** | You are connected to a restricted Wi-Fi network that isolates clients (e.g. certain Guest SSIDs). | Switch Wi-Fi to **`GTC Student`**, **`GTC Staff`**, or connect via school VPN. |
| **Access Denied (0x80070005)** | Windows blocked driver installation due to Point-and-Print security policy. | Run `.\Install-Printers.ps1 -FixPointAndPrint` once to whitelist the server (self-elevates). |
| **Print Jobs Stuck in Queue** | A corrupted document or driver lock froze the queue. | Run `.\Install-Printers.ps1 -RestartSpooler` to clear spool storage and restart the service. |
| **PaperCut Login Required** | Printing is mapped, but jobs don't release at the physical copier. | Start the school PaperCut client (`pc-client.exe`) and sign in with your student/staff credentials. |

---

## Architecture & Fallback Mechanics

1. **Automated Self-Healing in Default Run**:
   * Automatically inspects Spooler service status and recovers it if stopped.
   * If running with elevated rights, automatically whitelists Point-and-Print driver trust policies in registry and purges stuck `.SPL` spool files.
2. **Intelligent DNS Fallback**:
   * Resolves `gtcps001.gtc.local` through standard DNS.
   * If using custom DoH (NextDNS, Cloudflare, home VPN), automatically queries internal domain controllers (`172.16.0.7`, `172.16.0.8`) and falls back directly to `172.16.0.32`.
3. **4-Tier Connection Engine**:
   * **Engine 1**: WMI / CIM (`Win32_Printer.AddPrinterConnection`)
   * **Engine 2**: Native PowerShell PrintManagement (`Add-PrinterConnection`)
   * **Engine 3**: Windows Script Host COM (`WScript.Network.AddWindowsPrinterConnection`)
   * **Engine 4**: Direct Windows C API (`rundll32 printui.dll,PrintUIEntry /in`)
4. **Automated Log Rotation**:
   * Logs timestamped actions to `%TEMP%\PrinterInstaller.log`.
   * Automatically rotates and backs up to `.old` when exceeding 2 MB.