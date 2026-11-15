# Sysprep Duplicate SID Fix

Automates the Windows Sysprep `/generalize` process to fix duplicate SIDs across machines that were cloned without proper image preparation. Designed for **fully remote execution** with no on-site intervention required.

## The Problem

Windows updates released August 29, 2025 and later introduced security protections that enforce SID (Security Identifier) uniqueness checks during Kerberos and NTLM authentication:

- **[KB5064081](https://support.microsoft.com/en-us/topic/kerberos-and-ntlm-authentication-failures-due-to-duplicate-sids-76f7394d-c460-4882-9ed1-d27e0960f949)** (August 29, 2025) — Preview update, OS Build 26100.5074
- **[KB5065426](https://support.microsoft.com/en-us/topic/kerberos-and-ntlm-authentication-failures-due-to-duplicate-sids-76f7394d-c460-4882-9ed1-d27e0960f949)** (September 9, 2025) — General availability, OS Build 26100.6584

Machines cloned or imaged without running `sysprep /generalize` share the same machine SID. After these updates, authentication between machines with duplicate SIDs fails — users are repeatedly prompted for credentials, file shares break, and network resources become inaccessible. Failed requests are logged as **Event ID 6167** (lsasrv.dll) in the System event log.

**Affected systems:** Windows 11 24H2, Windows 11 25H2, Windows Server 2025

## What This Tool Does

The script handles the entire sysprep workflow in a single run:

1. **Captures machine identity** — Hostname, timezone, current SID, and network configuration
2. **Saves network config** — Creates a restore script matched by MAC address (survives adapter renames after generalize)
3. **Generates unattend.xml** — Dynamically builds the answer file to bypass all OOBE screens
4. **Handles BitLocker** — Decrypts the drive if BitLocker is enabled (waits for full decryption)
5. **Pauses Windows Update** — Prevents reserved storage conflicts during sysprep
6. **Checks for pending reboot** — If Windows updates require a reboot before sysprep can run, the script automatically reboots and resumes where it left off
7. **Runs Sysprep with auto-retry** — Automatically removes conflicting packages reported in the sysprep error log and retries (up to 10 attempts by default)

After sysprep completes, the machine reboots with a new unique SID. The network config is restored during the specialize pass (before OOBE), so the machine is reachable via RDP as soon as Windows is up. A `SysprepResult.txt` file is placed on the Administrator desktop with the new SID and IP addresses.

## Requirements

- Windows 10 Pro or Windows 11 Pro
- Administrator access on the target machine
- Remote access (RDP, or any other remote tool you prefer)

## Quick Start

1. Copy `Run-SysprepSIDFix.ps1` and `Run-SysprepSIDFix.bat` to the target machine
2. Right-click `Run-SysprepSIDFix.bat` and select **Run as administrator**
3. Enter the Administrator password when prompted
4. Confirm the settings and let the script run
5. If a pending reboot is required, the script reboots and resumes automatically
6. After sysprep succeeds, the machine reboots one final time with the new SID
7. Reconnect via RDP and check `SysprepResult.txt` on the desktop

## Usage

The easiest way to run the tool is with the `.bat` launcher — right-click `Run-SysprepSIDFix.bat` and select **Run as administrator**. It handles execution policy and launches the script automatically.

For advanced usage with parameters, run the `.ps1` script directly from an elevated PowerShell prompt:

```powershell
# Pre-specify password (skips the prompt)
.\Run-SysprepSIDFix.ps1 -AdminPassword "YourPassword"

# Override network config
.\Run-SysprepSIDFix.ps1 -IPAddress "192.168.1.100" -SubnetPrefix "24" -Gateway "192.168.1.1" -DNS "8.8.8.8","8.8.4.4"

# Skip network restore (use DHCP after reboot)
.\Run-SysprepSIDFix.ps1 -SkipNetworkRestore

# Fully unattended (no confirmation prompts, auto-reboot if needed)
.\Run-SysprepSIDFix.ps1 -AdminPassword "YourPassword" -Force
```

See [USAGE.md](USAGE.md) for the full parameter reference.

## How to Verify Duplicate SIDs

Before running, confirm the machines actually share a SID:

```
whoami /user
```

Compare the output from each machine. The SID will look something like:

```
S-1-5-21-1234567890-1234567890-1234567890-500
|_____________machine SID_______________|  |_RID (ignore this part)
```

If the numbers before the last dash match across machines, the SIDs are duplicated.

## How the Auto-Resume Works

If Windows updates are pending a reboot (a common blocker for sysprep), the script:

1. Saves its state and the prepared unattend.xml
2. Sets up a temporary auto-logon for the Administrator account
3. Creates a scheduled task that runs the script in a **visible PowerShell window** after reboot
4. Reboots the machine
5. After reboot, Administrator auto-logs in, the script resumes in a visible window, and runs sysprep
6. All temporary auto-logon credentials and scheduled tasks are cleaned up automatically

If no password is available during the resume (e.g., during a retry-loop reboot), it falls back to running as SYSTEM in the background. Progress is logged to `C:\Windows\System32\Sysprep\SysprepResume.log`.

The resume is capped at 3 reboot attempts to prevent infinite loops.

## Troubleshooting

### Machine not reachable after sysprep reboot

The network config is restored during the Windows specialize pass (before OOBE and user logon). If the machine is not reachable:

- **Try pinging the original static IP** — the specialize-pass restore should have applied it
- **Check DHCP leases on the router** — if the network restore failed, the machine may have fallen back to DHCP with a different IP
- **Physical access may be needed** — the machine may be stuck at an OOBE screen or waiting for driver installation. Log in manually and the FirstLogonCommands will run

### Sysprep fails with "Windows updates that require a reboot"

The script detects this automatically (error `0x139f`) and offers to reboot and resume. If running with `-Force`, it reboots without prompting.

### Sysprep fails with conflicting packages

The script automatically identifies the blocking package from the sysprep log, prompts for removal (or auto-removes with `-Force`), and retries. This may take several attempts as sysprep reports one blocker at a time. Increase `-MaxRetries` if you have many pre-installed Store apps.

### Sysprep fails with reserved storage error (0x800F0975)

The script automatically disables reserved storage via DISM, stops Windows Update services, and retries. If it persists:

1. Open Settings > Windows Update > Pause updates for 1 week
2. Run: `DISM /Online /Set-ReserveStorageState /State:Disabled`
3. Reboot the machine
4. Re-run the script

### Sysprep fails with BitLocker error (0x80310039)

The script waits for full BitLocker decryption before running sysprep. If this error still appears, run `manage-bde -off C:` manually and wait for decryption to complete.

### "Session blocked by Local Session Manager" when connecting via RDP

This occurs if you connect while the auto-logon session is still running its FirstLogonCommands. Click **Yes** to sign out that session. On newer versions of the script, the session logs off automatically when done.

## Notes

- **BitLocker** must fully decrypt before sysprep runs; the script handles this but large drives may take time
- **Conflicting packages** (Store apps) are only removed when sysprep specifically reports them as blockers; you are prompted before removal unless `-Force` is used
- The `unattend.xml` is generated dynamically at runtime — it enables RDP, restores the hostname/timezone, sets up auto-logon for one boot, and is deleted after first use
- The network restore script matches the adapter by **MAC address**, not by name, because sysprep `/generalize` can rename network adapters
- Any machine-ID-dependent software installed on the machine (e.g. TeamViewer, some licensing systems) will register a new ID after sysprep — plan accordingly

## References

- [Microsoft: Kerberos and NTLM authentication failures due to duplicate SIDs](https://support.microsoft.com/en-us/topic/kerberos-and-ntlm-authentication-failures-due-to-duplicate-sids-76f7394d-c460-4882-9ed1-d27e0960f949)
- [Microsoft Q&A: Duplicate SIDs discussion](https://learn.microsoft.com/en-us/answers/questions/5596430/kerberos-and-ntlm-authentication-failures-due-to-d)
