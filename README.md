# Enterprise Network Printer Deployment & Management Suite

Enterprise network printer deployment package for Microsoft Intune, Company Portal, and cross-platform administrative management across GTG. Supports automated deployment, self-healing diagnostics, multi-tier connection redundancy, and enterprise security hardening for Windows, traditional Linux, and NixOS.

---

## Repository File Manifest

| File | Platform | Role | Description |
| :--- | :--- | :--- | :--- |
| [`Install-Printers.ps1`](Install-Printers.ps1) | Windows | **Core Deployment Engine** | PowerShell deployment engine with dynamic CP437 box-drawing TUI, bracketless progress bars, 4-tier connection fallback, pre-flight diagnostics, automated self-healing, uninstallation, and 11 CLI operations. |
| [`Kopiator.bat`](Kopiator.bat) | Windows | **Zero-Config Launcher** | Double-clickable batch launcher with execution policy bypass. Automatically provisions and dynamically verifies `Install-Printers.ps1` against GitHub's authoritative Git object SHA if missing locally. |
| [`install-printers.sh`](install-printers.sh) | FHS Linux | **Universal CUPS Engine** | Distro-agnostic Bash deployment and diagnostic engine for Arch Linux, Debian, Ubuntu, Fedora, and openSUSE. Automates CUPS queue configuration with dual-server and 3-tier driver fallback. |
| [`gtg-printers.nix`](gtg-printers.nix) | NixOS | **Declarative NixOS Module** | Idiomatic, declarative NixOS configuration module provisioning CUPS queues, enabling Samba backends, and configuring default copiers with zero state drift. |
| [`flake.nix`](flake.nix) | NixOS / Nix | **Flake Packaging** | Exposes `nixosModules.default` and `nixosModules.gtg-printers` for drop-in inclusion into Flake-based NixOS configurations. |
| [`Detect-Printers.ps1`](Detect-Printers.ps1) | Windows | **Intune Detection Rule** | Lightweight detection rule script for Microsoft Intune Win32 app deployment, validating active mapping of all required copiers in the user profile with spooler health guards. |
| [`.gitattributes`](.gitattributes) | All | **Git Normalization** | Enforces strict Windows line endings (`CRLF`) for PowerShell and Batch scripts, and `LF` for Bash scripts, Nix expressions, and Markdown documentation. |

---

## Microsoft Intune / Company Portal Deployment Guide

When packaging this repository as a Win32 App (`.intunewin`) in the Microsoft Intune Admin Center:

### 1. Win32 App Packaging (`IntuneWinAppUtil.exe`)

Place the repository files into a source directory (e.g., `C:\IntuneSource\GTG-Printers`) and package using the official Microsoft Win32 Content Prep Tool:

```cmd
IntuneWinAppUtil.exe -c "C:\IntuneSource\GTG-Printers" -s "Install-Printers.ps1" -o "C:\IntuneOutput" -q
```

### 2. App Information
* **Name**: GTG Kopiatorer (L, TB, PB)
* **Description**: Enterprise network copier deployment for GTG students and staff (`L-Kopiator`, `TB-Kopiator`, `PB-Kopiator`).
* **Publisher**: GTG IT
* **Category**: Productivity / Utilities

### 3. Program Configuration

| Property | Value | Notes |
| :--- | :--- | :--- |
| **Install command** | `powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File .\Install-Printers.ps1 -NoPause` | Silent per-user deployment. |
| **Uninstall command** | `powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File .\Install-Printers.ps1 -Uninstall -NoPause` | Clean removal from user profile. |
| **Install behavior** | **User** | Network printer connections reside in `HKCU`, not machine-wide. |
| **Device restart behavior** | **Determine behavior based on return codes** | No system reboot required. |

### 4. Return Codes (Exit Codes)

| Return Code | Type | Meaning in Intune |
| :--- | :--- | :--- |
| **`0`** | **Success** | All requested copiers mapped and verified successfully. |
| **`1`** | **Hard Error** | One or more printer connections failed to configure. |
| **`2`** | **Fast-Fail / Retry** | Device is off-campus (SMB 445 unreachable). Intune schedules retry on next network sync. |

### 5. Detection Rule
* **Rules format**: Use a custom script
* **Script file**: Select [`Detect-Printers.ps1`](Detect-Printers.ps1)
* **Run script as 32-bit process on 64-bit clients**: No
* **Enforce script signature check and display**: No
* *(Detects whether `L-Kopiator`, `TB-Kopiator`, and `PB-Kopiator` are all active in the user profile)*.

---

## Standalone / Manual Usage (Windows)

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
Windows 10 and 11 block non-administrative users from downloading shared printer drivers from remote servers (PrintNightmare security mitigation). This command whitelists `gtcps001.gtc.local` and `172.16.0.32` in `HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint` and suppresses driver installation elevation prompts:
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
  [13] Check / Launch PaperCut MF Client
  [14] Lock Offline-Safe Default (Microsoft Print to PDF)
  [0]  Exit
```

### 11. View Diagnostic Log (`-ShowLog`)
Opens the timestamped log file (`%LOCALAPPDATA%\GTG-Printers\PrinterInstaller.log`) directly in Notepad for instant review. The log automatically archives and rotates when exceeding 2 MB:
```powershell
.\Install-Printers.ps1 -ShowLog
```

### 12. Offline Crash Guard & Zero-Lag Print Dialogs (`-SetSafeDefault`)
When network copiers are set as the Windows default printer, opening print dialogs (`Ctrl+P`) or clicking "Export as PDF" while off-campus triggers a synchronous 30-60 second SMB/RPC timeout that freezes or crashes applications (Word, Chrome, Edge, Acrobat). Furthermore, Windows 10/11 auto-manages the default printer by default, silently promoting the school copier to default after on-campus printing.

`Install-Printers.ps1` automatically eliminates this issue during installation by:
1. Locking `LegacyDefaultPrinterMode = 1` in the user registry to disable automatic default printer hijacking.
2. Setting `Microsoft Print to PDF` (or a local virtual printer) as the persistent default so print dialogs and PDF exports initialize instantly in 0 ms offline.

To enforce this crash-guard policy manually at any time:
```powershell
.\Install-Printers.ps1 -SetSafeDefault
```

### 13. Dynamic Cryptographic Audit (Git Object SHA)
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

### 14. PaperCut MF Client Integration (`-StartPaperCut`)
GTG network copiers require the PaperCut MF Client (`pc-client.exe`) to be running on the user's workstation in order to release print jobs at physical copier terminals. If stopped or not installed, users cannot authenticate at the badge reader or release their print queue.
The installer automatically inspects the status of `pc-client` in Step 1. Passing `-StartPaperCut` (or `--start-papercut` on Linux) will automatically detect installed client paths and launch it:
```powershell
.\Install-Printers.ps1 -StartPaperCut
```

### 15. Duplex Long-Edge Policy Enforcement (`-Duplex`)
To minimize paper waste and ensure eco-friendly school operations, print tickets are automatically configured for two-sided (duplex) long-edge printing upon queue creation.
* Enabled by default (`-Duplex:$true` on Windows, `--duplex` on Linux).
* Can be overridden by passing `-Duplex:$false` on Windows or `--no-duplex` on Linux.

---

## Linux Deployment: Architectural Approaches

Linux distributions operate under fundamentally different paradigms. To ensure maximum reliability and adhere strictly to system architecture best practices, this repository provides distinct paths:

1. **On-Demand / Hermetic (Nix Flake App `nix run`)**: **Recommended for mobile/laptop users.** Completely isolated from system options; does not touch or mutate `/etc/nixos/configuration.nix`.
2. **Declarative & Immutable (NixOS Module `gtg-printers.nix`)**: For users who require persistent, declarative queue definitions across system rebuilds.
3. **Traditional FHS Linux (`install-printers.sh`)**: Native Bash engine for Arch, Debian, Ubuntu, Fedora, and openSUSE.

---

### Approach 1: On-Demand Standalone via Flake (`nix run`)

> **Best Practice for Nix Users**: Intermittent school/work network printers should remain separate from core system configurations. If a printer queue is declared via `hardware.printers.ensurePrinters` with network discovery, running `nixos-rebuild switch` while off-campus or offline can fail or hang the build process.

Running via `nix run` packages the deployment engine into an isolated Nix closure without modifying system options:

```bash
# Direct print shortcut via Flake app (Zero host mutation, no root):
nix run github:TheHawk09/Printer-Installer#print -- mydoc.pdf

# Or specify custom default copier:
nix run github:TheHawk09/Printer-Installer#print -- mydoc.pdf --default "TB-Kopiator"

# Run interactive diagnostics:
nix run github:TheHawk09/Printer-Installer

# Query local CUPS inventory:
nix run github:TheHawk09/Printer-Installer -- --list-installed

# Format all Nix files using official RFC 0101 standard:
nix fmt
```

* **Zero System Impact**: Does not touch `/etc/nixos/configuration.nix` or system options.
* **Direct Server-Side Spooling**: Sends print jobs directly to PaperCut via hermetic Samba client tools in `/nix/store`.
* **Never Breaks Rebuilds**: Offline `nixos-rebuild switch` operations are completely decoupled.
* **Hermetic Dependencies**: Automatically wraps `cups`, `samba` (`smbclient`), and diagnostic utilities directly from `/nix/store`.

---

### Approach 2: NixOS Declarative Module (`gtg-printers.nix`)

For users who explicitly want permanent, declarative queue enforcement in their system configuration:

#### 1. Best Practices & Safety Hardening in `gtg-printers.nix`
* **Pure Store Driver Architecture & Zero Bloat**: Unlike naive configurations, it **does not** set `services.samba.enable = true` (which would launch an SMB file server on ports 139 and 445) and avoids bloating system packages with 150 MB of Samba server daemons. It packages `smbspool` into an isolated store derivation loaded purely via `services.printing.drivers = [ smbBackend ];`.
* **Selective Provisioning with Assertions**: Queues are declared via `printers = [ "L-Kopiator" ... ]`, verified at evaluation time by NixOS assertions so misconfigured default queues are caught immediately.
* **Offline-Safe Raw Queues (`model = "raw"`)**: Naive setups using `model = "everywhere"` force `lpadmin` to perform live IPP network handshakes at build time. If you are off-campus, `nixos-rebuild switch` crashes with an activation error. `gtg-printers.nix` uses `model = "raw"`, which configures in < 0.05 seconds locally with zero network requests. Rendering is offloaded to the Windows Print Server and PaperCut.

#### 2. Standard NixOS (`/etc/nixos/configuration.nix`)
Copy [`gtg-printers.nix`](gtg-printers.nix) into `/etc/nixos/`:
```bash
sudo cp ./gtg-printers.nix /etc/nixos/
```
Then import and enable it in `/etc/nixos/configuration.nix`:
```nix
{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./gtg-printers.nix
  ];

  # Explicitly enable the GTG printers module:
  services.gtg-printers = {
    enable = true;
    printers = [ "L-Kopiator" "TB-Kopiator" "PB-Kopiator" ]; # Select queues
    defaultPrinter = "L-Kopiator";
    duplex = true;
    useDirectIp = true; # Direct fallback to 172.16.0.32
  };
}
```
Apply the configuration:
```bash
sudo nixos-rebuild switch
```

#### 3. Flake-Based NixOS (`flake.nix`)
```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    gtg-printers.url = "github:TheHawk09/Printer-Installer";
  };

  outputs = { self, nixpkgs, gtg-printers, ... }: {
    nixosConfigurations.my-laptop = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        gtg-printers.nixosModules.default
        {
          services.gtg-printers.enable = true;
        }
      ];
    };
  };
}
```

#### 4. Home Manager Declarative Preferences (`gtg-home.nix`)
For users who manage user configurations with [Home Manager](https://github.com/nix-community/home-manager) without altering system files:
```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    gtg-printers.url = "github:TheHawk09/Printer-Installer";
  };

  outputs = { home-manager, gtg-printers, ... }: {
    homeConfigurations."student" = home-manager.lib.homeManagerConfiguration {
      modules = [
        gtg-printers.homeManagerModules.default
        {
          programs.gtg-printers = {
            enable = true;
            defaultPrinter = "L-Kopiator";
            duplex = true; # Declaratively configures ~/.cups/lpoptions
            autostartPaperCut = true; # Auto-launches PaperCut MF client on desktop login
          };
        }
      ];
    };
  };
}
```
Or copy [`gtg-home.nix`](gtg-home.nix) locally and import directly in `home.nix`:
```nix
imports = [ ./gtg-home.nix ];
programs.gtg-printers = {
  enable = true;
  autostartPaperCut = true;
};
```

---

### Traditional FHS Linux Deployment (`install-printers.sh`)

For standard distributions conforming to FHS, [`install-printers.sh`](install-printers.sh) provides a native Bash deployment engine. It detects distro-specific quirks and configures CUPS queues via `lpadmin` with 3-tier driver resolution.

#### 1. Distribution Specifics & Prerequisites

| Distribution Family | Package Installation | Backend Path | CUPS Group | Daemon Service |
| :--- | :--- | :--- | :--- | :--- |
| **Arch Linux / Manjaro / EndeavourOS** | `sudo pacman -S --needed cups samba` | `/usr/lib/cups/backend/smb`<br>*(Auto-symlinked by script)* | `lp` | `cups.service` |
| **Debian / Ubuntu / Mint / Pop!_OS** | `sudo apt update && sudo apt install -y cups smbclient` | `/usr/lib/cups/backend/smb` | `lpadmin` | `cups` |
| **Fedora / RHEL / Rocky / AlmaLinux** | `sudo dnf install -y cups samba-client` | `/usr/libexec/cups/backend/smb` or `/usr/lib` | `wheel` / `sys` | `cups` |
| **openSUSE / SLES** | `sudo zypper install -y cups samba-client` | `/usr/lib/cups/backend/smb` | `lp` | `cups` |
| **Fedora Silverblue / Kinoite (ostree)** | `rpm-ostree install samba-client` *(reboot required)* | `/usr/lib/cups/backend/smb` | `wheel` | `cups` |

> **Arch Linux Quirk**: On Arch Linux, the `samba` package provides `/usr/bin/smbspool`, but does not create the symlink `/usr/lib/cups/backend/smb` by default. [`install-printers.sh`](install-printers.sh) automatically detects Arch and creates this link if missing.

#### 2. Linux CLI Usage

Make the script executable and run:
```bash
chmod +x ./install-printers.sh

# Standard installation of all 3 copiers:
./install-printers.sh

# Target custom server and fallback IP:
./install-printers.sh --server "gtcps001.gtc.local" --fallback-ip "172.16.0.32"

# Install specific copier and set as default:
./install-printers.sh --printers "L-Kopiator" --default "L-Kopiator"

# Send a physical test page:
./install-printers.sh --print-test-page

# Clean uninstallation of copiers:
./install-printers.sh --uninstall

# List currently installed CUPS queues:
./install-printers.sh --list-installed

# Restart local CUPS print daemon:
./install-printers.sh --restart-cups

# Interactive console menu:
./install-printers.sh --menu

# Headless / automation execution (suppress pauses):
./install-printers.sh --no-pause
```

#### 3. CUPS 3-Tier Driver Fallback Architecture

Linux handles print drivers through CUPS filters and PPDs. When mapping queues, [`install-printers.sh`](install-printers.sh) tests candidate target servers (`active_server`, then `FALLBACK_IP`) with an intelligent 3-tier driver fallback:

```
[ Queue Connection Attempt ]
             │
             ├──► Tier 1: Driverless IPP Everywhere (-m everywhere)
             │      Query queue directly for hardware capabilities (no local PPD)
             │
             ├──► Tier 2: Generic PostScript (-m drv:///sample.drv/generic.ppd)
             │      Standard Adobe PostScript PPD bundled with CUPS
             │
             └──► Tier 3: Raw Spool Queue (-m raw)
                    Offload rendering & paper accounting to server-side Windows Spooler
```

---

## Cross-Platform Architecture & Redundancy Matrix

| Feature | Windows (`Install-Printers.ps1`) | Linux (`install-printers.sh`) | NixOS (`gtg-printers.nix`) |
| :--- | :--- | :--- | :--- |
| **Paradigm** | Imperative / Scripted | Imperative / FHS Scripted | Declarative / Immutable Module |
| **Target Print Servers** | Dual: `gtcps001.gtc.local` $\rightarrow$ `172.16.0.32` | Dual: `gtcps001.gtc.local` $\rightarrow$ `172.16.0.32` | Dual: Direct IP or FQDN option |
| **DNS Resolution Fallback** | Primary DNS $\rightarrow$ Internal DCs (`172.16.0.7/8`) $\rightarrow$ Direct IP | Primary `getent` $\rightarrow$ Internal DCs (`dig @172.16.0.7/8`) $\rightarrow$ Direct IP | System `services.resolved` or Direct IP |
| **Pre-Flight Network Probe** | .NET `TcpClient.ConnectAsync` on Port 445 (SMB) | Native `/dev/tcp/$host/445` socket test with 2s timeout | Systemd socket activation |
| **Network Failure Retry Loop** | Interactive `R` retry with `Clear-DnsClientCache` | Interactive `R` retry with `resolvectl flush-caches` | Handled at rebuild / network online |
| **Driver Fallback Tiers** | **4 Tiers**: WMI $\rightarrow$ PowerShell $\rightarrow$ COM $\rightarrow$ `printui.dll` | **3 Tiers**: IPP Everywhere $\rightarrow$ Generic PostScript $\rightarrow$ Raw Queue | Offline-safe `model = "raw"` with duplex PPD options |
| **Spooler Auto-Recovery** | Inspects `Spooler` service; restarts if stopped | Inspects `cups.service`; starts via systemctl if stopped | Managed declaratively via systemd |
| **Backend Self-Healing** | Purges stuck `.SPL` / `.SHD` spool files | Detects missing `smb` backend; auto-links `smbspool` | `environment.systemPackages = [ pkgs.samba ]` |
| **Execution Logging** | `%LOCALAPPDATA%\GTG-Printers\PrinterInstaller.log` | `~/.local/share/GTG-Printers/PrinterInstaller.log` | Systemd journal (`journalctl -u cups`) |
| **Exit Codes** | `0` = Success, `1` = Hard Error, `2` = Offline/Fast-Fail | `0` = Success, `1` = Hard Error, `2` = Offline/Fast-Fail | Nix rebuild exit status |

---

## Enterprise Security & CWE Compliance Matrix

All scripts implement rigorous defenses against common software vulnerabilities (CWEs) and enterprise attack vectors:

| Vulnerability / CWE | Mitigation Architecture | Platforms |
| :--- | :--- | :--- |
| **CWE-200 / CWE-300 / CWE-918**<br>(NetNTLM Hash Coercion / SMB Leak) | Rejects public IP addresses in `-FallbackIP`, `-InternalDNSServers`, and DNS resolution. All SMB and RPC target addresses must strictly belong to private RFC 1918 subnets (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) or loopback. Prevents coerced authentication relay attacks. | Windows & Linux |
| **CWE-426 / CWE-427**<br>(Untrusted Search Path / Binary Planting) | Pins absolute executable paths to `%SystemRoot%\System32` for `notepad.exe`, `rundll32.exe`, `net.exe`, and `powershell.exe`. Prevents local binary hijacking from the current working directory. | Windows |
| **CWE-829 / CWE-250**<br>(Untrusted Elevation Sphere / UAC Escalation) | Restricts self-elevation (`-Verb RunAs`) to scripts residing on local fixed drives (`DriveType.Fixed`), blocking elevated execution from untrusted network shares (UNC) or removable USB media. | Windows |
| **CWE-732**<br>(Insecure Resource Permissions) | Hardens NTFS ACLs on `%LOCALAPPDATA%\GTG-Printers` with inheritance disabled, granting full control exclusively to the current user, local Administrators, and SYSTEM. On Linux, creates `~/.local/share/GTG-Printers` with `0700` mode. | Windows & Linux |
| **CWE-59 / CWE-367**<br>(Symlink Traversal & TOCTOU Attacks) | Verifies that log files, destination script caches, and spooler files are not Windows Reparse Points / junctions or Linux symlinks before writing, rotating, or purging. | Windows & Linux |
| **CWE-494 / CWE-353 / CWE-377 / CWE-330**<br>(Code Provisioning, Dynamic Git SHA Verification & Temp Files) | In `Kopiator.bat`, auto-downloaded scripts are staged in a cryptographically unique GUID temp file, validated for minimum size (> 10 KB), parsed via PowerShell AST for 0 syntax errors, checked for authentic GTG code tokens, and dynamically verified against GitHub's authoritative Git object SHA via the GitHub REST API on the fly without requiring any hardcoded checksum files. | Windows |
| **CWE-400 / CWE-404 / CWE-775**<br>(Resource Starvation & COM Leaks) | Disables socket linger (`LingerState = ($true, 0)`) on SMB pre-flight checks, explicitly releases COM subsystem objects (`[Marshal]::ReleaseComObject`), and triggers garbage collection to prevent handle exhaustion. | Windows |
| **CWE-642 / CWE-73**<br>(Registry Type Confusion & Injection) | Enforces explicit `REG_SZ` and `REG_DWORD` types in `HKLM` policies, purging any pre-existing values to neutralize `REG_EXPAND_SZ` environment variable injection. | Windows |
| **CWE-88 / CWE-78 / CWE-20**<br>(Argument Injection & Command Safety) | Sanitizes printer paths against embedded quotation marks and control characters before passing to native binaries, validates CLI parameters with strict regex, and isolates batch parameters using delayed expansion (`!RAW_ARGS!`). | Windows & Linux |
| **CWE-1188**<br>(Insecure Protocol Negotiation) | Safe, fault-tolerant TLS 1.2 / TLS 1.3 protocol configuration with proxy auto-discovery (`DefaultWebProxy` & `DefaultNetworkCredentials`) for seamless execution behind corporate firewalls. | Windows |

---

## Troubleshooting & Error Translation Matrix

| Error Pattern | Friendly Translation | Root Cause | Solution |
| :--- | :--- | :--- | :--- |
| **`0x80070005`** | **ACCESS DENIED** | Windows Point-and-Print policy blocked driver download (PrintNightmare). | Run `.\Install-Printers.ps1 -FixPointAndPrint` as Admin to whitelist server policies. |
| **`0x80070035`** | **NETWORK PATH NOT FOUND** | Print server is offline or unreachable on Port 445 (SMB). | Connect to GTG Wi-Fi (`GTC Student` / `GTC Staff`) or school VPN. |
| **`0x8007007B`** | **INVALID SHARE SYNTAX** | Printer share name is malformed or invalid. | Check copier name spelling in `-Printers` parameter. |
| **`0x800706BA`** | **RPC SERVER UNAVAILABLE** | The Print Spooler service on client or server is not responding. | Run `.\Install-Printers.ps1 -RestartSpooler` to reset the local Spooler. |
| **`0x800706BE`** | **RPC CALL FAILED** | Remote print spooler crashed or terminated during negotiation. | Retry installation; if persistent, contact IT to verify server spooler. |
| **`0x80070034`** | **NAME NOT FOUND** | Hostname cannot be resolved on local network segment. | Script automatically falls back to internal DCs (`172.16.0.7/8`) and IP (`172.16.0.32`). |
| **`0x800704C7`** | **OPERATION CANCELED** | Driver installation prompt was dismissed or canceled by the user. | Re-run script and allow driver installation, or run `-FixPointAndPrint`. |
| **`0x80070002`** | **DRIVER/FILE NOT FOUND** | A required driver package or `.inf` is missing from the server share. | Contact IT administrator to refresh the driver package on the print server. |
| **`3012`** | **QUEUE NOT FOUND** | Printer queue does not exist on the specified server share. | Run `.\Install-Printers.ps1 -ListAvailable` to see valid shared queues. |
| **`CUPS SMB Missing`** | **BACKEND NOT FOUND** | Linux CUPS lacks the `smb` backend (`smbspool`). | Script auto-links `/usr/bin/smbspool` if present; on NixOS set `services.samba.enable = true`. |
| **`PaperCut Stopped`** | **JOB NOT RELEASING** | Printer mapped, but jobs do not release at the physical copier. | Launch the PaperCut client (`pc-client.exe` / `pc-client`) and sign in with GTG credentials. |