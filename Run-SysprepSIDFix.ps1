<#
.SYNOPSIS
    Automates the Sysprep SID fix process for remote execution.

.DESCRIPTION
    This script handles the entire sysprep /generalize workflow to fix duplicate SIDs:
      1. Captures machine identity (hostname, timezone, SID) and prompts for admin password
      2. Saves network configuration for restore after reboot
      3. Generates and deploys unattend.xml with captured settings
      4. Disables BitLocker if enabled (and waits for decryption)
      5. Pauses Windows Update to prevent reserved storage conflicts
      6. Checks for pending reboot (auto-reboots and resumes if needed)
      7. Runs sysprep, automatically retrying and removing any conflicting
         packages that appear in the error log
      8. Machine reboots with a new SID; OOBE is fully bypassed via unattend.xml

.NOTES
    Must be run as Administrator.
    Compatible with Windows 10 Pro and Windows 11 Pro.
#>

param(
    # Maximum number of sysprep retry attempts (each attempt removes newly found conflicting packages)
    [int]$MaxRetries = 10,

    # Skip the confirmation prompt and run immediately
    [switch]$Force,

    # Administrator password for the machine after sysprep (prompted if not specified)
    [string]$AdminPassword,

    # Hostname to assign after sysprep (auto-captured from current machine if not specified)
    [string]$Hostname,

    # Timezone (auto-captured from current machine if not specified)
    [string]$TimeZone,

    # Network configuration overrides (auto-captured from current config if not specified)
    [string]$IPAddress,
    [string]$SubnetPrefix,
    [string]$Gateway,
    [string[]]$DNS,

    # Skip network config restore after sysprep (leave on DHCP)
    [switch]$SkipNetworkRestore,

    # Resume after a pending-reboot restart (set automatically, not for manual use)
    [switch]$Resume
)

$ErrorActionPreference = "Stop"

# Manual admin check (works for both interactive users and SYSTEM service accounts,
# unlike #Requires -RunAsAdministrator which rejects SYSTEM)
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $currentIdentity.IsSystem -and
    -not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  [FAIL] This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

$thisScriptPath = $MyInvocation.MyCommand.Path
$resumeFilePath = Join-Path $env:SystemRoot "System32\Sysprep\SysprepResume.flag"
$resumeTaskName = "SysprepSIDFixResume"
$skipToSysprep = $false

# ============================================================
# Helper functions
# ============================================================

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] " -ForegroundColor DarkGray -NoNewline
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ("-" * 60) -ForegroundColor DarkGray
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor White
}

function Test-PendingReboot {
    $reasons = @()
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $reasons += "Windows Update requires reboot"
    }
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $reasons += "Component servicing requires reboot"
    }
    $smProps = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -ErrorAction SilentlyContinue
    if ($smProps -and $smProps.PendingFileRenameOperations) {
        $reasons += "Pending file rename operations"
    }
    return $reasons
}

function Invoke-RebootAndResume {
    param(
        [int]$RebootAttempt = 0,
        [string]$Password
    )

    if ($RebootAttempt -ge 3) {
        Write-Fail "Already rebooted $RebootAttempt time(s) but pending reboot persists."
        Write-Fail "Manual intervention required. Reboot the machine manually, then re-run this script."
        exit 1
    }

    Write-Info "Saving state and scheduling resume after reboot..."

    # Store reboot attempt count in the resume flag
    "Attempt:$($RebootAttempt + 1)" | Out-File -FilePath $resumeFilePath -Encoding UTF8 -Force

    # Copy script to a guaranteed-local path for the scheduled task
    $resumeScriptPath = Join-Path $env:SystemRoot "System32\Sysprep\Run-SysprepSIDFix.ps1"
    if ($thisScriptPath -ne $resumeScriptPath) {
        Copy-Item $thisScriptPath $resumeScriptPath -Force
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$resumeScriptPath`" -Force -Resume -MaxRetries $MaxRetries"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    if ($Password) {
        # Set up temporary auto-logon so resume runs in an interactive session (visible window)
        $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        Set-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon" -Value "1"
        Set-ItemProperty -Path $winlogonPath -Name "DefaultUserName" -Value "Administrator"
        Set-ItemProperty -Path $winlogonPath -Name "DefaultPassword" -Value $Password
        Set-ItemProperty -Path $winlogonPath -Name "AutoLogonCount" -Value 1

        $trigger = New-ScheduledTaskTrigger -AtLogOn -User "Administrator"
        $principal = New-ScheduledTaskPrincipal -UserId "Administrator" -RunLevel Highest -LogonType Interactive
        Register-ScheduledTask -TaskName $resumeTaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force | Out-Null

        Write-Success "Scheduled interactive resume after reboot."
        Write-Info "The machine will auto-logon as Administrator and resume with a visible window."
    } else {
        # No password available — fall back to SYSTEM (background, no visible window)
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest -LogonType ServiceAccount
        Register-ScheduledTask -TaskName $resumeTaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force | Out-Null

        Write-Success "Scheduled background resume after reboot."
        Write-Info "Progress will be logged to: $(Join-Path $env:SystemRoot 'System32\Sysprep\SysprepResume.log')"
    }

    Write-Host ""
    Write-Host "  Rebooting in 10 seconds..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    Restart-Computer -Force
    Start-Sleep -Seconds 30
    exit 0
}

# ============================================================
# Resume handling
# ============================================================

$rebootAttemptCount = 0

if ($Resume -or (Test-Path $resumeFilePath)) {
    $skipToSysprep = $true

    # Read reboot attempt count from resume flag
    if (Test-Path $resumeFilePath) {
        $flagContent = Get-Content $resumeFilePath -Raw -ErrorAction SilentlyContinue
        if ($flagContent -match 'Attempt:(\d+)') {
            $rebootAttemptCount = [int]$Matches[1]
        }
    }

    # Start logging for unattended resume
    $resumeLogPath = Join-Path $env:SystemRoot "System32\Sysprep\SysprepResume.log"
    Start-Transcript -Path $resumeLogPath -Force -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Sysprep SID Fix - Resuming After Reboot" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    # Clean up resume artifacts
    if (Test-Path $resumeFilePath) {
        Remove-Item $resumeFilePath -Force -ErrorAction SilentlyContinue
    }
    Unregister-ScheduledTask -TaskName $resumeTaskName -Confirm:$false -ErrorAction SilentlyContinue

    # Clean up temporary auto-logon credentials from the pre-sysprep reboot
    $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Remove-ItemProperty -Path $winlogonPath -Name "DefaultPassword" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon" -Value "0" -ErrorAction SilentlyContinue

    # Set required variables for the sysprep step
    $sysprepDir = Join-Path $env:SystemRoot "System32\Sysprep"
    $destPath = Join-Path $sysprepDir "unattend.xml"

    if (-not (Test-Path $destPath)) {
        Write-Fail "unattend.xml not found at $destPath"
        Write-Fail "Cannot resume. Please re-run the script from scratch."
        Stop-Transcript -ErrorAction SilentlyContinue
        exit 1
    }

    Write-Success "Resume state loaded (reboot attempt $rebootAttemptCount). Skipping to sysprep..."
    Write-Info "unattend.xml verified at $destPath"

    $pendingReasons = Test-PendingReboot
    if ($pendingReasons.Count -gt 0) {
        Write-Warn "Pending reboot still detected after restart:"
        foreach ($reason in $pendingReasons) { Write-Info "  - $reason" }

        # Clear PendingFileRenameOperations — these are processed during boot,
        # but the registry key can linger with stale entries that block sysprep
        $smPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
        $smProps = Get-ItemProperty $smPath -ErrorAction SilentlyContinue
        if ($smProps -and $smProps.PendingFileRenameOperations) {
            Remove-ItemProperty $smPath -Name PendingFileRenameOperations -Force -ErrorAction SilentlyContinue
            Write-Success "Cleared stale PendingFileRenameOperations registry entry."
        }

        # Re-check after clearing
        $pendingReasons = Test-PendingReboot
        if ($pendingReasons.Count -gt 0) {
            Write-Warn "Remaining pending reboot reasons:"
            foreach ($reason in $pendingReasons) { Write-Info "  - $reason" }
            Write-Info "Attempting sysprep anyway..."
        } else {
            Write-Success "Pending reboot cleared. Ready for sysprep."
        }
    } else {
        Write-Success "No pending reboot detected. Ready for sysprep."
    }
}

# ============================================================
# Steps 1-6: Preparation (skipped on resume)
# ============================================================

if (-not $skipToSysprep) {

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Sysprep SID Fix - Automated Remote Workflow" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ============================================================
# Step 1: Show current SID and gather machine identity
# ============================================================

Write-Step "Step 1: Current machine identity"

$sidOutput = whoami /user /fo csv | ConvertFrom-Csv
$currentSID = $sidOutput.SID
$machineSID = $currentSID -replace '-\d+$', ''
Write-Info "Current user SID : $currentSID"
Write-Info "Machine SID      : $machineSID"
Write-Info "Hostname         : $env:COMPUTERNAME"

# Auto-capture hostname if not specified
if (-not $Hostname) {
    $Hostname = $env:COMPUTERNAME
}
Write-Info "Hostname (after) : $Hostname"

# Auto-capture timezone if not specified
if (-not $TimeZone) {
    $TimeZone = (Get-TimeZone).Id
}
Write-Info "Timezone         : $TimeZone"

# Prompt for admin password if not specified
if (-not $AdminPassword) {
    Write-Host ""
    $securePass = Read-Host "  Enter Administrator password for after sysprep" -AsSecureString
    $AdminPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
    )
    if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
        Write-Fail "Password cannot be empty."
        exit 1
    }
}

# ============================================================
# Confirmation
# ============================================================

if (-not $Force) {
    Write-Host ""
    Write-Host "  WARNING: This will run sysprep /generalize on this machine." -ForegroundColor Yellow
    Write-Host "  The machine will:" -ForegroundColor Yellow
    Write-Host "    - Get a NEW SID, hostname, and IP address" -ForegroundColor Yellow
    Write-Host "    - Reboot automatically" -ForegroundColor Yellow
    Write-Host "    - Auto-logon once to the Administrator account" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "  Type YES to continue"
    if ($confirm -ne "YES") {
        Write-Host "  Aborted." -ForegroundColor Red
        exit 0
    }
}

# ============================================================
# Step 2: Capture network configuration
# ============================================================

Write-Step "Step 2: Network configuration"

$networkRestoreScript = $null

if (-not $SkipNetworkRestore) {
    # Find the active network adapter (the one with a default gateway)
    $activeAdapter = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric |
        Select-Object -First 1

    if ($activeAdapter) {
        $ifIndex = $activeAdapter.InterfaceIndex
        $adapterName = (Get-NetAdapter -InterfaceIndex $ifIndex).Name
        $currentIP = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -ne "WellKnown" } |
            Select-Object -First 1
        $currentGateway = $activeAdapter.NextHop
        $currentDNS = (Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4).ServerAddresses

        # Use manual overrides if provided, otherwise use captured values
        $restoreIP = if ($IPAddress) { $IPAddress } elseif ($currentIP) { $currentIP.IPAddress } else { $null }
        $restorePrefix = if ($SubnetPrefix) { $SubnetPrefix } elseif ($currentIP) { $currentIP.PrefixLength.ToString() } else { $null }
        $restoreGateway = if ($Gateway) { $Gateway } elseif ($currentGateway) { $currentGateway } else { $null }
        $restoreDNS = if ($DNS) { $DNS } elseif ($currentDNS) { $currentDNS } else { $null }

        if ($restoreIP) {
            Write-Info "Adapter          : $adapterName"
            Write-Info "IP Address       : $restoreIP/$restorePrefix"
            Write-Info "Gateway          : $restoreGateway"
            Write-Info "DNS              : $($restoreDNS -join ', ')"

            if ($IPAddress -or $SubnetPrefix -or $Gateway -or $DNS) {
                Write-Info "(Using manual overrides where specified)"
            } else {
                Write-Info "(Auto-captured from current config)"
            }

            if (-not $Force) {
                Write-Host ""
                $response = Read-Host "  Restore this network config after sysprep? (Y/N)"
                if ($response -ne "Y" -and $response -ne "y") {
                    Write-Info "Network config will NOT be restored. Machine will use DHCP."
                    $restoreIP = $null
                }
            }

            if ($restoreIP) {
                # Get the adapter's MAC address for reliable matching after sysprep
                # (adapter names can change after generalize)
                $adapterMAC = (Get-NetAdapter -InterfaceIndex $ifIndex).MacAddress

                # Build the restore script
                $dnsCommands = ""
                if ($restoreDNS -and $restoreDNS.Count -gt 0) {
                    $dnsList = ($restoreDNS | ForEach-Object { "'$_'" }) -join ","
                    $dnsCommands = @"

Set-DnsClientServerAddress -InterfaceAlias `$adapter -ServerAddresses @($dnsList)
"@
                }

                $networkRestoreScript = @"
# Find the adapter by MAC address (adapter name may change after sysprep generalize)
`$nic = Get-NetAdapter | Where-Object { `$_.MacAddress -eq '$adapterMAC' -and `$_.Status -eq 'Up' } | Select-Object -First 1
if (-not `$nic) {
    `$nic = Get-NetAdapter | Where-Object { `$_.MacAddress -eq '$adapterMAC' } | Select-Object -First 1
}
if (-not `$nic) {
    `$nic = Get-NetAdapter -Physical | Where-Object { `$_.Status -eq 'Up' } | Select-Object -First 1
}
if (-not `$nic) {
    Write-Host 'No suitable network adapter found' -ForegroundColor Red
    exit 1
}
`$adapter = `$nic.Name
Write-Host "Restoring network config on adapter: `$adapter"
# Remove existing IP config
Get-NetIPAddress -InterfaceAlias `$adapter -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:`$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceAlias `$adapter -AddressFamily IPv4 -Confirm:`$false -ErrorAction SilentlyContinue
# Apply saved config
New-NetIPAddress -InterfaceAlias `$adapter -IPAddress '$restoreIP' -PrefixLength $restorePrefix -DefaultGateway '$restoreGateway' -ErrorAction Stop$dnsCommands
"@

                # Save the restore script to the Sysprep directory (survives reboot)
                $restoreScriptPath = Join-Path $env:SystemRoot "System32\Sysprep\RestoreNetwork.ps1"
                $networkRestoreScript | Out-File -FilePath $restoreScriptPath -Encoding UTF8 -Force
                Write-Success "Network restore script saved to $restoreScriptPath"
            }
        } else {
            Write-Info "No static IP detected. Machine appears to be on DHCP."
            Write-Info "Network config will not be modified after sysprep."
        }
    } else {
        Write-Warn "Could not detect active network adapter."
        Write-Info "Network config will not be modified after sysprep."
    }
} else {
    Write-Info "Network restore skipped (-SkipNetworkRestore)."
}

# ============================================================
# Step 3: Generate and deploy unattend.xml
# ============================================================

Write-Step "Step 3: Generating unattend.xml"

$sysprepDir = Join-Path $env:SystemRoot "System32\Sysprep"
$destPath = Join-Path $sysprepDir "unattend.xml"

# Escape XML special characters in password
$xmlPassword = $AdminPassword -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'","&apos;"

$unattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend
  xmlns="urn:schemas-microsoft-com:unattend"
  xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

  <settings pass="specialize">

    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>

    <component name="Microsoft-Windows-Firewall"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <FirewallGroups>
        <FirewallGroup wcm:action="add">
          <Group>Remote Desktop</Group>
          <Profile>all</Profile>
          <Active>true</Active>
        </FirewallGroup>
      </FirewallGroups>
    </component>

    <component name="Microsoft-Windows-TerminalServices-RDP-WinStationExtensions"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <UserAuthentication>0</UserAuthentication>
    </component>

    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <ComputerName>$Hostname</ComputerName>
      <TimeZone>$TimeZone</TimeZone>
    </component>

    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Restore network config early (before OOBE) so machine is reachable via RDP</Description>
          <Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "if (Test-Path 'C:\Windows\System32\Sysprep\RestoreNetwork.ps1') { &amp; 'C:\Windows\System32\Sysprep\RestoreNetwork.ps1' }"</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>

  </settings>

  <settings pass="oobeSystem">

    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UILanguageFallback>en-US</UILanguageFallback>
      <UserLocale>en-US</UserLocale>
    </component>

    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">

      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <ProtectYourPC>3</ProtectYourPC>
        <NetworkLocation>Work</NetworkLocation>
      </OOBE>

      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
        <Password>
          <Value>$xmlPassword</Value>
          <PlainText>true</PlainText>
        </Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>

      <UserAccounts>
        <AdministratorPassword>
          <Value>$xmlPassword</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>Administrator</Name>
            <Group>Administrators</Group>
            <Password>
              <Value>$xmlPassword</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>

      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Restore network configuration if saved</Description>
          <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "if (Test-Path 'C:\Windows\System32\Sysprep\RestoreNetwork.ps1') { &amp; 'C:\Windows\System32\Sysprep\RestoreNetwork.ps1'; Remove-Item 'C:\Windows\System32\Sysprep\RestoreNetwork.ps1' -Force }"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Set network profile to private</Description>
          <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Log new machine identity to desktop</Description>
          <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$info = @(); `$info += 'Sysprep completed: ' + (Get-Date).ToString(); `$info += 'Hostname: ' + `$env:COMPUTERNAME; `$info += 'SID: ' + (whoami /user /fo csv | ConvertFrom-Csv).SID; `$info += ''; `$info += 'IP Addresses:'; Get-NetIPAddress -AddressFamily IPv4 | Where-Object {`$_.IPAddress -ne '127.0.0.1'} | ForEach-Object { `$info += '  ' + `$_.InterfaceAlias + ': ' + `$_.IPAddress }; `$info | Out-File -FilePath ([Environment]::GetFolderPath('Desktop') + '\SysprepResult.txt') -Encoding UTF8"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Description>Disable auto-logon after first use</Description>
          <CommandLine>reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>5</Order>
          <Description>Delete unattend.xml to remove plaintext password</Description>
          <CommandLine>cmd.exe /c del /f /q "C:\Windows\System32\Sysprep\unattend.xml"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>6</Order>
          <Description>Log off auto-logon session so RDP is not blocked</Description>
          <CommandLine>shutdown.exe /l /f</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>

    </component>
  </settings>

</unattend>
"@

$unattendXml | Out-File -FilePath $destPath -Encoding UTF8 -Force
Write-Success "Generated unattend.xml with captured settings"
Write-Info "  Hostname : $Hostname"
Write-Info "  Timezone : $TimeZone"
Write-Info "  Password : ********"
Write-Info "  Deployed to $destPath"

# ============================================================
# Step 4: Handle BitLocker
# ============================================================

Write-Step "Step 4: Checking BitLocker status"

try {
    $blStatus = manage-bde -status C: 2>&1
    $blStatusText = $blStatus | Out-String

    # Check if BitLocker needs attention — protection on OR not fully decrypted
    $needsDecrypt = $false

    if ($blStatusText -match "Protection Status:\s+Protection On") {
        Write-Info "BitLocker protection is ON - disabling..."
        manage-bde -off C: | Out-Null
        $needsDecrypt = $true
    }
    elseif ($blStatusText -match "Conversion Status:\s+Fully Decrypted") {
        Write-Success "BitLocker is fully off."
    }
    elseif ($blStatusText -match "Protection Status:\s+Protection Off") {
        # Protection is off but drive may still be encrypted/decrypting
        if ($blStatusText -match "Percentage Encrypted:\s+(\d+(\.\d+)?)%" -and [double]$Matches[1] -gt 0) {
            Write-Info "BitLocker protection is off but drive is still encrypted ($($Matches[1])%)."
            manage-bde -off C: 2>&1 | Out-Null
            $needsDecrypt = $true
        } else {
            Write-Success "BitLocker is already off."
        }
    }
    else {
        Write-Success "BitLocker does not appear to be active."
    }

    if ($needsDecrypt) {
        Write-Info "Waiting for BitLocker decryption to complete..."
        $decrypting = $true
        while ($decrypting) {
            Start-Sleep -Seconds 10
            $status = manage-bde -status C: | Out-String
            if ($status -match "Percentage Encrypted:\s+(\d+(\.\d+)?)%") {
                $pct = $Matches[1]
                Write-Host "`r  Decryption progress: $pct% remaining...    " -NoNewline -ForegroundColor White
                if ([double]$pct -eq 0) {
                    $decrypting = $false
                }
            }
            if ($status -match "Conversion Status:\s+Fully Decrypted") {
                $decrypting = $false
            }
        }
        Write-Host ""
        Write-Success "BitLocker decryption complete."
    }
} catch {
    Write-Warn "Could not check BitLocker status: $_"
    Write-Warn "If sysprep fails with error 0x80310039, run: manage-bde -off C:"
}

# ============================================================
# Step 5: Pause Windows Update
# ============================================================

Write-Step "Step 5: Pausing Windows Update"

try {
    # Pause updates for 7 days by setting the pause feature update start date
    $pauseDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $regPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"

    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }

    Set-ItemProperty -Path $regPath -Name "PauseFeatureUpdatesStartTime" -Value $pauseDate
    Set-ItemProperty -Path $regPath -Name "PauseQualityUpdatesStartTime" -Value $pauseDate
    Set-ItemProperty -Path $regPath -Name "PauseUpdatesStartTime" -Value $pauseDate

    # Also calculate the expiry date (7 days from now)
    $expiryDate = (Get-Date).AddDays(7).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Set-ItemProperty -Path $regPath -Name "PauseFeatureUpdatesEndTime" -Value $expiryDate
    Set-ItemProperty -Path $regPath -Name "PauseQualityUpdatesEndTime" -Value $expiryDate
    Set-ItemProperty -Path $regPath -Name "PauseUpdatesExpiryTime" -Value $expiryDate

    # Stop the Windows Update service to release any reserved storage locks
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Write-Success "Windows Update paused for 7 days and service stopped."
} catch {
    Write-Warn "Could not fully pause Windows Update: $_"
    Write-Warn "If sysprep fails with error 0x800F0975, pause updates manually in Settings."
}

# ============================================================
# Step 6: Check for pending reboot
# ============================================================

Write-Step "Step 6: Checking for pending reboot"

$pendingReasons = Test-PendingReboot
if ($pendingReasons.Count -gt 0) {
    Write-Warn "Pending reboot detected:"
    foreach ($reason in $pendingReasons) { Write-Info "  - $reason" }
    Write-Host ""
    Write-Warn "Sysprep cannot run while a reboot is pending."
    Write-Info "The machine will reboot to clear the pending state, then sysprep"
    Write-Info "will run automatically after restart."

    if (-not $Force) {
        Write-Host ""
        $response = Read-Host "  Reboot now and auto-resume? (Y/N)"
        if ($response -ne "Y" -and $response -ne "y") {
            Write-Warn "Please reboot manually and re-run this script."
            exit 1
        }
    }

    Invoke-RebootAndResume -RebootAttempt $rebootAttemptCount -Password $AdminPassword
} else {
    Write-Success "No pending reboot. Ready for sysprep."
}

} # end if (-not $skipToSysprep)

# ============================================================
# Step 7: Run Sysprep with automatic retry
# ============================================================

Write-Step "Step 7: Running Sysprep"

$sysprepExe = Join-Path $sysprepDir "sysprep.exe"
$pantherDir = Join-Path $sysprepDir "Panther"
$setupActLog = Join-Path $pantherDir "setupact.log"
$setupErrLog = Join-Path $pantherDir "setuperr.log"
$attempt = 0
$sysprepSuccess = $false
$reservedStorageAttempted = $false

while ($attempt -lt $MaxRetries -and -not $sysprepSuccess) {
    $attempt++
    Write-Info "Attempt $attempt of $MaxRetries..."

    # Clear old logs so we only parse fresh errors
    foreach ($log in @($setupActLog, $setupErrLog)) {
        if (Test-Path $log) {
            Remove-Item $log -Force -ErrorAction SilentlyContinue
        }
    }

    # Run sysprep (/quiet suppresses error dialogs that hang non-interactive sessions)
    $process = Start-Process -FilePath $sysprepExe `
        -ArgumentList "/generalize", "/oobe", "/reboot", "/quiet", "/unattend:$destPath" `
        -Wait -PassThru -NoNewWindow

    Write-Info "Sysprep exited with code: $($process.ExitCode)"

    # Don't trust exit code alone — check the logs for errors regardless,
    # because sysprep can return 0 even when it fails (after clicking OK on the error dialog)
    Start-Sleep -Seconds 3

    # Read log files from the Sysprep Panther directory only
    # (C:\Windows\Panther\ contains stale logs from previous runs — do not read those)
    $logContent = ""
    $logSources = @()
    foreach ($log in @($setupActLog, $setupErrLog)) {
        if (Test-Path $log) {
            $logContent += (Get-Content $log -Raw) + "`n"
            $logSources += $log
        }
    }

    if ($logSources.Count -gt 0) {
        Write-Info "Log files found: $($logSources -join ', ')"
    } else {
        Write-Info "No log files found"
    }

    # Check if logs contain errors
    $hasErrors = $logContent -match 'SYSPRP.*Error|Error.*SYSPRP'

    if (-not $hasErrors -and $process.ExitCode -eq 0) {
        Write-Success "Sysprep started successfully! The machine will reboot shortly."
        Write-Host ""
        Write-Host "  =========================================" -ForegroundColor Green
        Write-Host "  SYSPREP SUCCEEDED" -ForegroundColor Green
        Write-Host "  The PC will reboot with a new SID." -ForegroundColor Green
        Write-Host "  After reboot:" -ForegroundColor Green
        Write-Host "    - It will auto-logon once as Administrator" -ForegroundColor Green
        Write-Host "    - A SysprepResult.txt will appear on the desktop" -ForegroundColor Green
        Write-Host "    - Find the PC by its new IP on the network" -ForegroundColor Green
        Write-Host "  =========================================" -ForegroundColor Green
        $sysprepSuccess = $true

        # Clean up any resume artifacts
        if (Test-Path $resumeFilePath) { Remove-Item $resumeFilePath -Force -ErrorAction SilentlyContinue }
        Unregister-ScheduledTask -TaskName $resumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
        $resumeScriptCopy = Join-Path $env:SystemRoot "System32\Sysprep\Run-SysprepSIDFix.ps1"
        if ($thisScriptPath -ne $resumeScriptCopy -and (Test-Path $resumeScriptCopy)) {
            Remove-Item $resumeScriptCopy -Force -ErrorAction SilentlyContinue
        }
        Stop-Transcript -ErrorAction SilentlyContinue
    } else {
        Write-Warn "Sysprep failed. Analyzing logs..."

        if ($logContent.Length -gt 0) {
            # Look for conflicting Appx package errors using multiple patterns
            $packageMatches = [regex]::Matches($logContent, 'SYSPRP\s+Package\s+([\w\.\-]+_[\d\.]+_[\w]+__[\w]+)\s+was installed')
            if ($packageMatches.Count -eq 0) {
                $packageMatches = [regex]::Matches($logContent, 'SYSPRP\s+.*?remove\s+.*?([\w\.\-]+_[\d\.]+_[\w]+__[\w]+)')
            }
            if ($packageMatches.Count -eq 0) {
                $packageMatches = [regex]::Matches($logContent, 'Error\s+.*?([\w\.\-]+_[\d\.]+_[\w]+__[\w]+)')
            }

            $newPackagesFound = $false
            $foundPackageNames = @()

            foreach ($match in $packageMatches) {
                $pkgName = $match.Groups[1].Value
                if ($pkgName -and $pkgName -notin $foundPackageNames) {
                    $foundPackageNames += $pkgName
                }
            }

            if ($foundPackageNames.Count -gt 0) {
                Write-Host ""
                Write-Host "  Sysprep is blocked by the following package(s):" -ForegroundColor Yellow
                Write-Host ""
                foreach ($pkgName in $foundPackageNames) {
                    $baseName = ($pkgName -split '_')[0]
                    Write-Host "    - $baseName" -ForegroundColor White
                }
                Write-Host ""

                $doRemove = $true
                if (-not $Force) {
                    $response = Read-Host "  Remove and retry? (Y/N)"
                    if ($response -ne "Y" -and $response -ne "y") {
                        Write-Warn "Skipping removal. Sysprep cannot continue with these packages installed."
                        break
                    }
                }

                foreach ($pkgName in $foundPackageNames) {
                    Write-Info "Removing: $pkgName"
                    try {
                        $pkg = Get-AppxPackage -AllUsers | Where-Object { $_.PackageFullName -eq $pkgName }
                        if (-not $pkg) {
                            $baseName = ($pkgName -split '_')[0]
                            $pkg = Get-AppxPackage -AllUsers -Name "*$baseName*"
                        }
                        foreach ($p in $pkg) {
                            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
                            Write-Success "Removed $($p.Name)"
                            $newPackagesFound = $true
                        }
                    } catch {
                        try {
                            Remove-AppxPackage -Package $pkgName -AllUsers -ErrorAction Stop
                            Write-Success "Removed $pkgName"
                            $newPackagesFound = $true
                        } catch {
                            Write-Warn "Could not remove package: $_"
                        }
                    }
                }
            }

            # Check for BitLocker error
            if ($logContent -match "0x80310039") {
                Write-Warn "BitLocker is blocking sysprep."

                # Kick off decryption if not already started
                manage-bde -off C: 2>&1 | Out-Null

                # Poll until fully decrypted
                Write-Info "Waiting for BitLocker decryption to complete..."
                $decrypting = $true
                while ($decrypting) {
                    Start-Sleep -Seconds 10
                    $blStatus = manage-bde -status C: | Out-String
                    if ($blStatus -match "Percentage Encrypted:\s+(\d+(\.\d+)?)%") {
                        $pct = $Matches[1]
                        Write-Host "`r  Decryption progress: $pct% remaining...    " -NoNewline -ForegroundColor White
                        if ([double]$pct -eq 0) {
                            $decrypting = $false
                        }
                    }
                    if ($blStatus -match "Conversion Status:\s+Fully Decrypted") {
                        $decrypting = $false
                    }
                }
                Write-Host ""
                Write-Success "BitLocker decryption complete."
                $newPackagesFound = $true  # Trigger a retry
            }

            # Check for reserved storage error
            if ($logContent -match "0x800F0975") {
                if ($reservedStorageAttempted) {
                    Write-Fail "Reserved storage conflict persists after mitigation."
                    Write-Info "Try these manual steps, then re-run the script:"
                    Write-Host ""
                    Write-Host "    1. Open Settings > Windows Update > Pause updates for 1 week" -ForegroundColor White
                    Write-Host "    2. Run: DISM /Online /Set-ReserveStorageState /State:Disabled" -ForegroundColor White
                    Write-Host "    3. Reboot the machine" -ForegroundColor White
                    Write-Host "    4. Re-run this script" -ForegroundColor White
                    Write-Host ""
                    break
                }

                Write-Warn "Reserved storage conflict detected. Applying mitigations..."

                # Stop all Windows Update related services
                foreach ($svc in @("wuauserv", "TrustedInstaller", "bits", "dosvc", "UsoSvc")) {
                    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                }
                Write-Info "Stopped Windows Update services."

                # Disable reserved storage via DISM (more reliable than registry)
                try {
                    $dismResult = & DISM /Online /Set-ReserveStorageState /State:Disabled 2>&1
                    Write-Info "DISM: Reserved storage disabled."
                } catch {
                    Write-Warn "DISM failed: $_"
                }

                # Also set the registry key as a fallback
                try {
                    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" -Name "ShippedWithReserves" -Value 0 -ErrorAction Stop
                    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" -Name "PassedPolicy" -Value 0 -ErrorAction SilentlyContinue
                } catch {
                    Write-Warn "Could not modify reserved storage registry setting."
                }

                # Clear Windows Update cache
                $wuCache = Join-Path $env:SystemRoot "SoftwareDistribution\Download"
                if (Test-Path $wuCache) {
                    Remove-Item "$wuCache\*" -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Info "Cleared Windows Update download cache."
                }

                Write-Info "Waiting 10 seconds for services to fully stop..."
                Start-Sleep -Seconds 10

                $reservedStorageAttempted = $true
                $newPackagesFound = $true  # Trigger a retry
            }

            # Check for pending reboot error (0x139f / 0x36b7)
            if ($logContent -match "0x139f|0x000036b7|Windows updates that require a reboot") {
                Write-Warn "Sysprep failed because a reboot is required to complete pending updates."

                if (-not $Force -and -not $Resume) {
                    Write-Host ""
                    $response = Read-Host "  Reboot now and auto-resume? (Y/N)"
                    if ($response -ne "Y" -and $response -ne "y") {
                        Write-Warn "Please reboot manually and re-run this script."
                        break
                    }
                }

                Invoke-RebootAndResume -RebootAttempt $rebootAttemptCount -Password $AdminPassword
            }

            if (-not $newPackagesFound) {
                Write-Fail "Could not identify removable conflicting packages from the log."
                Write-Info "Dumping recent error lines from logs:"
                Write-Host ""
                foreach ($log in @($setupActLog, $setupErrLog)) {
                    if (Test-Path $log) {
                        Get-Content $log -Tail 30 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
                    }
                }
                Write-Host ""
                Write-Fail "Manual intervention may be required. Review the log output above."
                break
            }
        } else {
            Write-Fail "No sysprep log files found in $pantherDir"
            break
        }
    }
}

if (-not $sysprepSuccess) {
    Write-Host ""
    Write-Host "  =========================================" -ForegroundColor Red
    Write-Host "  SYSPREP FAILED after $attempt attempt(s)" -ForegroundColor Red
    Write-Host "  Review: $setupActLog" -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    Stop-Transcript -ErrorAction SilentlyContinue
    exit 1
}
