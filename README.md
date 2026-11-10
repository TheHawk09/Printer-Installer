# Printer-Installer (Microsoft Intune / Company Portal)

Enterprise network printer deployment package for Microsoft Intune, Company Portal, and standalone administrative management across GTG.

---

## Repository File Manifest

| File | Purpose | Description |
| :--- | :--- | :--- |
| [`Install-Printers.ps1`](Install-Printers.ps1) | **Core Engine & Installer** | PowerShell deployment engine with dynamic CP437 box-drawing TUI, bracketless progress bars, 4-tier connection fallback, pre-flight diagnostics, self-healing, uninstallation, and 11 CLI operations. |
| [`Kopiator.bat`](Kopiator.bat) | **Zero-Config Launcher** | Double-clickable batch launcher with execution policy bypass. Automatically provisions and dynamically verifies `Install-Printers.ps1` against GitHub's authoritative Git object SHA if missing. |
| [`Detect-Printers.ps1`](Detect-Printers.ps1) | **Intune Detection Script** | Lightweight detection rule script for Microsoft Intune Win32 app deployment, validating active mapping of all required copiers in the user profile. |
| [`.gitattributes`](.gitattributes) | **Git Normalization** | Enforces strict Windows line endings (`CRLF`) for PowerShell and Batch scripts, and `LF` for Markdown documentation. |

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

Administrators, students, and technicians can run [`Install-Printers.ps1`](Install-Printers.ps1) directly using command-line tags or double-clicking [`Kopiator.bat`](Kopiator.bat):

> **Auto-Provisioning Launcher**: If [`Kopiator.bat`](Kopiator.bat) is executed in an environment without `Install-Printers.ps1` (e.g. distributed standalone or copied to Desktop), it automatically fetches `Install-Printers.ps1` from the official repository and enforces a 4-phase integrity and security verification:
> 1. **Size Guard**: Verifies file size exceeds 10 KB to prevent truncated or empty downloads.
> 2. **PowerShell AST Parsing**: Invokes `[System.Management.Automation.Language.Parser]` to guarantee zero syntax or script parsing errors.
> 3. **Content Signature**: Validates authentic GTG script tokens (`ENTERPRISE NETWORK PRINTER MANAGER`, `L-Kopiator`) to reject captive portal HTML intercepts.
> 4. **Dynamic Cryptographic Git SHA**: Dynamically queries GitHub's REST API (`/contents/Install-Printers.ps1`) to verify that the downloaded payload's Git blob SHA bit-for-bit matches GitHub's authoritative repository object hash on `main`. No hardcoded hash files needed.
>
> **Automation-Aware Execution**: Passing `-NoPause` to [`Kopiator.bat`](Kopiator.bat) (e.g. `Kopiator.bat -NoPause` or `Kopiator.bat -Uninstall -NoPause`) automatically suppresses the terminal pause prompt for headless task runners and CI/CD pipelines.
>
> **Real-Time Visual Progress**: Displays clean bracketless progress bars (`████████████░░░░░░░░ 60%`) with simultaneous overall and per-copier tracking, alongside native Windows PowerShell `Write-Progress` taskbar integration.

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
Opens the timestamped log file (`%LOCALAPPDATA%\GTG-Printers\PrinterInstaller.log`) directly in Notepad for instant review. The log automatically archives and rotates when exceeding 2 MB:
```powershell
.\Install-Printers.ps1 -ShowLog
```

### 12. Dynamic Cryptographic Audit (Git Object SHA)
To manually audit and verify that your local copy of `Install-Printers.ps1` matches GitHub's authoritative blob SHA without relying on static files:
```powershell
# 1. Fetch remote authoritative SHA dynamically from GitHub API:
$wc = New-Object System.Net.WebClient
$wc.Headers['User-Agent'] = 'PrinterInstaller/1.0'
$remoteSha = ($wc.DownloadString('https://api.github.com/repos/TheHawk09/Printer-Installer/contents/Install-Printers.ps1') | ConvertFrom-Json).sha

# 2. Compute Git blob SHA of local file:
$bytes = [System.IO.File]::ReadAllBytes('.\Install-Printers.ps1')
$header = [System.Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
$all = New-Object byte[] ($header.Length + $bytes.Length)
[Buffer]::BlockCopy($header, 0, $all, 0, $header.Length)
[Buffer]::BlockCopy($bytes, 0, $all, $header.Length, $bytes.Length)
$localSha = -join ([System.Security.Cryptography.SHA1]::Create().ComputeHash($all) | ForEach-Object { '{0:x2}' -f $_ })

if ($remoteSha -eq $localSha) {
    Write-Host "Integrity Verified: Local file matches GitHub main blob ($localSha)" -ForegroundColor Green
} else {
    Write-Host "Notice: Local file differs from GitHub main (Remote: $remoteSha, Local: $localSha)" -ForegroundColor Yellow
}
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
   * Logs timestamped actions to `%LOCALAPPDATA%\GTG-Printers\PrinterInstaller.log`.
   * Automatically rotates and backs up to `.old` when exceeding 2 MB.

---

## Enterprise Security & Reliability Hardening

All deployment scripts implement rigorous security defenses against common software vulnerabilities (CWEs) and enterprise attack vectors:

| Vulnerability / CWE | Mitigation Architecture |
| :--- | :--- |
| **CWE-200 / CWE-300 / CWE-918**<br>(NetNTLM Hash Coercion / SMB Leak) | Rejects public IP addresses in `-FallbackIP`, `-InternalDNSServers`, and DNS resolution. All SMB and RPC target addresses must strictly belong to private RFC 1918 subnets (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) or loopback. |
| **CWE-426 / CWE-427**<br>(Untrusted Search Path / Binary Planting) | Pins absolute executable paths to `%SystemRoot%\System32` for `notepad.exe`, `rundll32.exe`, `net.exe`, and `powershell.exe`. |
| **CWE-829 / CWE-250**<br>(Untrusted Elevation Sphere / UAC Escalation) | Restricts self-elevation (`-Verb RunAs`) to scripts residing on local fixed drives (`DriveType.Fixed`), blocking elevated execution from untrusted network shares (UNC) or removable USB media. |
| **CWE-732**<br>(Insecure Resource Permissions) | Hardens NTFS ACLs on `%LOCALAPPDATA%\GTG-Printers` with inheritance disabled, granting full control exclusively to the current user, local Administrators, and SYSTEM. |
| **CWE-59 / CWE-367**<br>(Symlink Traversal & TOCTOU Attacks) | Verifies that log files, destination script caches, and spooler files are not Windows Reparse Points / junctions before writing, rotating, or purging. |
| **CWE-494 / CWE-353 / CWE-377 / CWE-330**<br>(Code Provisioning, Dynamic Git SHA Verification & Temp Files) | In `Kopiator.bat`, auto-downloaded scripts are staged in a cryptographically unique GUID temp file, validated for minimum size (> 10 KB), parsed via PowerShell AST for 0 syntax errors, checked for authentic GTG code tokens, and dynamically verified against GitHub's authoritative Git object SHA via the GitHub REST API on the fly without requiring any hardcoded checksum files. |
| **CWE-400 / CWE-404 / CWE-775**<br>(Resource Starvation & COM Leaks) | Disables socket linger (`LingerState = ($true, 0)`) on SMB pre-flight checks and explicitly releases COM subsystem objects (`[Marshal]::ReleaseComObject`). |
| **CWE-642 / CWE-73**<br>(Registry Type Confusion & Injection) | Enforces explicit `REG_SZ` and `REG_DWORD` types in `HKLM` policies, purging any pre-existing values to neutralize `REG_EXPAND_SZ` environment variable injection. |
| **CWE-88 / CWE-20**<br>(Argument Injection & Parameter Validation) | Sanitizes printer paths against embedded quotation marks and control characters before passing to native binaries, and validates all CLI parameters with strict regex. |
| **CWE-1188**<br>(Insecure Protocol Negotiation) | Safe, fault-tolerant TLS 1.2 / TLS 1.3 protocol configuration without crashing on older .NET Framework installations. |