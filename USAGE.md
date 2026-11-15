# Sysprep Duplicate SID Fix - Usage Guide

## Overview

Automates the Windows Sysprep `/generalize` process to fix duplicate SIDs across machines. Designed for fully remote execution with no on-site intervention required.

**Compatible with:** Windows 10 Pro and Windows 11 Pro

## Prerequisites

- Administrator access on the target machine
- Remote access (RDP, or any other remote tool you prefer) to the target machine
- Copy the script files to the target machine

## Quick Start

1. Copy `Run-SysprepSIDFix.ps1` and `Run-SysprepSIDFix.bat` to the target machine
2. Right-click `Run-SysprepSIDFix.bat` and select **Run as administrator**
3. Enter the Administrator password when prompted
4. Confirm the settings and let the script run
5. If a pending reboot is detected, the script reboots and resumes automatically
6. After sysprep succeeds, the machine reboots one final time with the new SID
7. Reconnect via RDP and check `SysprepResult.txt` on the desktop

## Parameters

All parameters are optional. The script auto-captures hostname, timezone, and network config from the current machine.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-AdminPassword` | Administrator password for auto-logon after sysprep | Prompted at runtime |
| `-Hostname` | Computer name to assign | Current hostname |
| `-TimeZone` | Timezone ID (e.g. `Eastern Standard Time`) | Current timezone |
| `-IPAddress` | Static IP address to restore | Auto-captured |
| `-SubnetPrefix` | Subnet prefix length (e.g. `24`) | Auto-captured |
| `-Gateway` | Default gateway | Auto-captured |
| `-DNS` | DNS server(s) | Auto-captured |
| `-SkipNetworkRestore` | Leave network on DHCP after sysprep | `$false` |
| `-MaxRetries` | Max sysprep retry attempts | `10` |
| `-Force` | Skip confirmation prompts and auto-reboot if needed | `$false` |
| `-Resume` | Used internally by the auto-resume mechanism; do not pass manually | `$false` |

## Examples

**Basic usage (recommended):**
```powershell
.\Run-SysprepSIDFix.ps1
```

**Pre-specify password (no prompt):**
```powershell
.\Run-SysprepSIDFix.ps1 -AdminPassword "YourPassword"
```

**Override network config:**
```powershell
.\Run-SysprepSIDFix.ps1 -IPAddress "192.168.1.100" -SubnetPrefix "24" -Gateway "192.168.1.1" -DNS "8.8.8.8","8.8.4.4"
```

**Skip network restore (use DHCP):**
```powershell
.\Run-SysprepSIDFix.ps1 -SkipNetworkRestore
```

**Fully unattended (no prompts, auto-reboot if needed):**
```powershell
.\Run-SysprepSIDFix.ps1 -AdminPassword "YourPassword" -Force
```

## What the Script Does

1. **Captures machine identity** — Hostname, timezone, SID, and network config
2. **Saves network config** — Creates a restore script matched by MAC address (survives adapter renames after generalize)
3. **Generates unattend.xml** — Deploys answer file to bypass all OOBE screens, with network restore in the specialize pass
4. **Handles BitLocker** — Decrypts the drive if BitLocker is enabled (waits for full decryption)
5. **Pauses Windows Update** — Prevents reserved storage conflicts during sysprep
6. **Checks for pending reboot** — If Windows updates require a reboot before sysprep can run, the script reboots and resumes automatically
7. **Runs Sysprep** — Executes `/generalize /oobe /reboot /quiet` with automatic retry loop that removes conflicting packages as reported in the sysprep log

## After Reboot

- Network config is restored during the **specialize pass** (before OOBE), so the machine is reachable immediately
- The machine boots straight to the desktop (auto-logon runs once)
- RDP is enabled
- `SysprepResult.txt` on the desktop contains the new SID, hostname, and IP addresses
- The auto-logon session logs off automatically after FirstLogonCommands complete
- Auto-logon credentials are removed after first boot
- The `unattend.xml` is deleted after first boot

## Auto-Resume Behavior

If a pending reboot is detected (Windows updates, component servicing, or pending file renames), the script:

1. Saves its state to `C:\Windows\System32\Sysprep\SysprepResume.flag`
2. Copies itself and the prepared `unattend.xml` to the Sysprep directory
3. If the Administrator password is available: sets up auto-logon and creates an **interactive** scheduled task (visible PowerShell window on the desktop)
4. If no password is available: creates a **SYSTEM** scheduled task (runs in the background)
5. Reboots the machine
6. After reboot, the script resumes and jumps directly to the sysprep step
7. All temporary artifacts (auto-logon, scheduled task, flag file, script copy) are cleaned up

Resume is capped at **3 reboot attempts** to prevent infinite loops. Progress is logged to `C:\Windows\System32\Sysprep\SysprepResume.log`.

## Files Produced

| File | Location | Description |
|------|----------|-------------|
| `SysprepResult.txt` | Administrator Desktop | New SID, hostname, IP addresses |
| `SysprepResume.log` | `C:\Windows\System32\Sysprep\` | Resume transcript (only if auto-resume was triggered) |
| `RestoreNetwork.ps1` | `C:\Windows\System32\Sysprep\` | Network restore script (cleaned up after use) |

## Notes

- **BitLocker** must fully decrypt before sysprep can run. The script handles this automatically but large drives may take time.
- **Conflicting packages** (Store apps) are removed only when sysprep specifically reports them as blockers. You will be prompted before removal unless `-Force` is used.
- The network restore script matches the adapter by **MAC address**, not by name, because sysprep `/generalize` can rename network adapters.
- The `unattend.xml` is generated dynamically at runtime and deleted after first boot to remove the plaintext Administrator password.
- Any machine-ID-dependent software installed on the machine (e.g. TeamViewer, some licensing systems) will register a new ID after sysprep — plan accordingly.
