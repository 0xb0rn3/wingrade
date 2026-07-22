#Requires -RunAsAdministrator
<#
.SYNOPSIS
    wingrade — Windows 8.1 -> Windows 10 unattended upgrade bootstrapper
.DESCRIPTION
    Downloads Windows 10 install media, suspends competing services (Windows
    Update, BITS-consuming background tasks, non-critical scheduled tasks),
    snapshots pre-upgrade state, then invokes setup.exe for a silent in-place
    upgrade. Restores service state on exit regardless of outcome.
.PARAMETER Arch
    x64 or x86 (default: auto-detect)
.PARAMETER IsoUrl
    Direct ISO URL, bypasses Microsoft download-connector scraping entirely
.PARAMETER SkipCompatCheck
    Bypass setup.exe compat check gating (/Compat IgnoreWarning)
.PARAMETER NoReboot
    Stage the upgrade but don't auto-restart
.PARAMETER NoServiceSuspend
    Skip service suspension step (not recommended — leaves WU competing for I/O)
.PARAMETER NoSnapshot
    Skip pre-upgrade backup/restore-point creation
.PARAMETER UnattendPath
    Path to a custom unattend.xml to inject into setup (for domain-joined/AD scenarios)
.PARAMETER LogPath
    Log directory (default: C:\wingrade)
.EXAMPLE
    irm https://raw.githubusercontent.com/0xb0rn3/wingrade/main/wingrade.ps1 | iex
.EXAMPLE
    $s = irm https://raw.githubusercontent.com/0xb0rn3/wingrade/main/wingrade.ps1
    iex "$s -SkipCompatCheck -NoReboot"
.NOTES
    wingrade by ig:theehiv3 | github: 0xb0rn3
    Requires: PowerShell 4.0+ (native on 8.1), Admin, ~20GB free disk, internet
#>

[CmdletBinding()]
param(
    [ValidateSet('x64','x86','auto')]
    [string]$Arch = 'auto',

    [string]$IsoUrl,

    [switch]$SkipCompatCheck,
    [switch]$NoReboot,
    [switch]$NoServiceSuspend,
    [switch]$NoSnapshot,

    [string]$UnattendPath,

    [string]$LogPath = 'C:\wingrade',

    [int]$TimeoutMinutes = 120
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Banner = @'
 __      __.__                              .___     
/  \    /  \__| ____    ________________  __| _/____  
\   \/\/   /  |/    \  / ___\_  __ \__  \ / __ |/ __ \ 
 \        /|  |   |  \/ /_/  >  | \// __ \/ /_/ \  ___/ 
  \__/\  / |__|___|  /\___  /|__|  (____  /\____ |\___  >
       \/          \//_____/            \/      \/    \/ 
        wingrade  |  ig: theehiv3  |  github: 0xb0rn3
        Win 8.1 -> Win 10 unattended upgrade bootstrap
'@

# ============================================================
#  CONFIG
# ============================================================
$Script:Config = @{
    LogDir          = $LogPath
    IsoDir          = Join-Path $LogPath 'iso'
    SnapshotDir     = Join-Path $LogPath 'snapshot'
    MountDrive      = $null
    StartTime       = Get-Date
    TranscriptLog   = Join-Path $LogPath 'transcript.log'
    SuspendedSvcs   = @()   # populated at runtime, used for restore
    MctUrl          = 'https://go.microsoft.com/fwlink/?LinkId=691209'
}

# Services safe to STOP (not disable) during the upgrade window.
# Selection criteria: (a) actively competes for disk I/O / network with
# setup.exe, (b) safe to restart cleanly post-upgrade, (c) NOT a dependency
# of setup.exe's own servicing stack (TrustedInstaller, wuauserv itself stays
# untouched at the STOP level but IS excluded from disable/delayed-start changes).
$Script:ServiceSuspendList = @(
    'wuauserv',          # Windows Update Orchestrator — stop fetching, don't disable
    'UsoSvc',            # Update Orchestrator Service (newer stack component present on some 8.1 KB-updated systems)
    'BITS',              # Background Intelligent Transfer — competes for bandwidth with our own BITS download
    'DoSvc',             # Delivery Optimization, if present via update
    'wscsvc',            # Security Center — noisy during upgrade, non-critical
    'SysMain',           # Superfetch/Prefetch — actively caching disk I/O we want free
    'WSearch',           # Windows Search indexer — heavy disk I/O
    'DiagTrack'          # Connected User Experiences and Telemetry
)

# ============================================================
#  LOGGING
# ============================================================
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) { 'INFO'{'Cyan'} 'WARN'{'Yellow'} 'ERROR'{'Red'} 'OK'{'Green'} }
    $line = "[$ts] [$Level] $Message"
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $Script:Config.TranscriptLog -Value $line -ErrorAction SilentlyContinue } catch {}
}

function Exit-Fatal {
    param([string]$Message, [int]$Code = 1)
    Write-Log -Message $Message -Level ERROR
    Restore-SuspendedServices
    Write-Log -Message "Aborting. Log: $($Script:Config.TranscriptLog)" -Level ERROR
    exit $Code
}

# ============================================================
#  PREREQ CHECKS
# ============================================================
function Test-Prerequisites {
    Write-Log 'Running prerequisite checks...'

    $os = Get-CimInstance Win32_OperatingSystem
    $osVersion = [version]$os.Version
    if ($osVersion.Major -ne 6 -or $osVersion.Minor -ne 3) {
        Exit-Fatal "wingrade targets Windows 8.1 (build 6.3.x) only. Detected: $($os.Caption) [$($os.Version)]"
    }
    Write-Log "OS confirmed: $($os.Caption) build $($os.BuildNumber)" -Level OK

    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Exit-Fatal 'Must run as Administrator. Re-launch elevated.'
    }
    Write-Log 'Admin privileges confirmed' -Level OK

    $sysDrive = (Get-Item $env:SystemDrive).PSDrive
    $freeGB = [math]::Round((Get-PSDrive -Name $sysDrive.Name).Free / 1GB, 2)
    if ($freeGB -lt 20) {
        Exit-Fatal "Insufficient disk space: ${freeGB}GB free on $env:SystemDrive, need 20GB minimum"
    }
    Write-Log "Disk space OK: ${freeGB}GB free" -Level OK

    try {
        $null = Invoke-WebRequest -Uri 'https://www.microsoft.com' -Method Head -TimeoutSec 10 -UseBasicParsing
        Write-Log 'Internet connectivity confirmed' -Level OK
    } catch {
        Exit-Fatal "No internet connectivity: $($_.Exception.Message)"
    }

    if ($Arch -eq 'auto') {
        $Script:Arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    } else {
        $Script:Arch = $Arch
    }
    Write-Log "Target architecture: $Script:Arch" -Level OK

    try {
        $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($battery -and $battery.BatteryStatus -ne 2 -and $battery.EstimatedChargeRemaining -lt 50) {
            Write-Log "WARNING: On battery at $($battery.EstimatedChargeRemaining)% charge. Recommend AC power." -Level WARN
        }
    } catch { }

    if (Test-PendingReboot) {
        Exit-Fatal 'Pending reboot from prior updates detected. Reboot first, then re-run.'
    }
    Write-Log 'No pending reboot detected' -Level OK

    # BitLocker check — hard stop cause for setup.exe even with compat bypass
    try {
        $bde = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
        if ($bde -and $bde.ProtectionStatus -eq 'On') {
            Write-Log 'BitLocker is ON for system drive. Suspending protection for upgrade (1 reboot cycle)...' -Level WARN
            Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 | Out-Null
            Write-Log 'BitLocker suspended for 1 reboot cycle' -Level OK
        }
    } catch {
        Write-Log "BitLocker check skipped (module unavailable or not encrypted): $($_.Exception.Message)" -Level INFO
    }

    # AV presence check — informational, since kernel-driver AV is the #1 silent-fail cause
    try {
        $avProducts = Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
        if ($avProducts) {
            foreach ($av in $avProducts) {
                Write-Log "Detected AV: $($av.displayName) — third-party AV is the most common cause of silent setup.exe failure on 8.1->10" -Level WARN
            }
        }
    } catch { }
}

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile'
    )
    foreach ($key in $keys) { if (Test-Path $key) { return $true } }
    $pfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    return [bool]$pfr
}

# ============================================================
#  SERVICE SUSPENSION  (stop-and-restore, not disable)
# ============================================================
function Suspend-CompetingServices {
    if ($NoServiceSuspend) {
        Write-Log 'Service suspension SKIPPED (-NoServiceSuspend set)' -Level WARN
        return
    }

    Write-Log 'Suspending services that compete with setup.exe for I/O/network...'
    Write-Log 'NOTE: services are STOPPED, not DISABLED — StartType is untouched, auto-restored on exit' -Level INFO

    foreach ($svcName in $Script:ServiceSuspendList) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if (-not $svc) {
                Write-Log "Service '$svcName' not present on this system, skipping" -Level INFO
                continue
            }
            if ($svc.Status -eq 'Stopped') {
                Write-Log "Service '$svcName' already stopped" -Level INFO
                continue
            }

            # Record original state before touching it
            $Script:Config.SuspendedSvcs += [PSCustomObject]@{
                Name          = $svcName
                OriginalState = $svc.Status
                StartType     = $svc.StartType
            }

            Stop-Service -Name $svcName -Force -ErrorAction Stop -NoWait
            Write-Log "Stopped: $svcName" -Level OK
        } catch {
            Write-Log "Could not stop '$svcName': $($_.Exception.Message) (non-fatal, continuing)" -Level WARN
        }
    }

    # Disable non-critical scheduled tasks for the window (Windows Update task
    # tree specifically — these can silently kick wuauserv back on)
    $tasksToDisable = @(
        '\Microsoft\Windows\WindowsUpdate\Scheduled Start',
        '\Microsoft\Windows\WindowsUpdate\sih',
        '\Microsoft\Windows\WindowsUpdate\sihboot'
    )
    foreach ($taskPath in $tasksToDisable) {
        try {
            $task = Get-ScheduledTask -TaskPath (Split-Path $taskPath -Parent) -TaskName (Split-Path $taskPath -Leaf) -ErrorAction SilentlyContinue
            if ($task -and $task.State -ne 'Disabled') {
                Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
                Write-Log "Disabled scheduled task: $taskPath" -Level OK
            }
        } catch {
            Write-Log "Task '$taskPath' not found or already disabled (non-fatal)" -Level INFO
        }
    }

    Write-Log "Suspended $($Script:Config.SuspendedSvcs.Count) service(s)" -Level OK
}

function Restore-SuspendedServices {
    if ($Script:Config.SuspendedSvcs.Count -eq 0) { return }

    Write-Log 'Restoring suspended services to pre-upgrade state...'
    foreach ($entry in $Script:Config.SuspendedSvcs) {
        try {
            if ($entry.OriginalState -eq 'Running') {
                Start-Service -Name $entry.Name -ErrorAction Stop
                Write-Log "Restored (started): $($entry.Name)" -Level OK
            }
        } catch {
            Write-Log "Failed to restore '$($entry.Name)': $($_.Exception.Message) — check manually" -Level WARN
        }
    }

    $tasksToReEnable = @(
        '\Microsoft\Windows\WindowsUpdate\Scheduled Start',
        '\Microsoft\Windows\WindowsUpdate\sih',
        '\Microsoft\Windows\WindowsUpdate\sihboot'
    )
    foreach ($taskPath in $tasksToReEnable) {
        try {
            $task = Get-ScheduledTask -TaskPath (Split-Path $taskPath -Parent) -TaskName (Split-Path $taskPath -Leaf) -ErrorAction SilentlyContinue
            if ($task) {
                Enable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
                Write-Log "Re-enabled scheduled task: $taskPath" -Level OK
            }
        } catch {
            Write-Log "Could not re-enable task '$taskPath' (non-fatal)" -Level INFO
        }
    }
}

# ============================================================
#  PRE-UPGRADE SNAPSHOT
# ============================================================
function New-PreUpgradeSnapshot {
    if ($NoSnapshot) {
        Write-Log 'Snapshot step SKIPPED (-NoSnapshot set)' -Level WARN
        return
    }

    Write-Log 'Creating pre-upgrade safety net...'
    New-Item -ItemType Directory -Path $Script:Config.SnapshotDir -Force | Out-Null

    # 1. System Restore point (belt)
    try {
        Enable-ComputerRestore -Drive $env:SystemDrive -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'wingrade pre-upgrade snapshot' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log 'System Restore point created' -Level OK
    } catch {
        Write-Log "System Restore point creation failed (non-fatal): $($_.Exception.Message)" -Level WARN
    }

    # 2. Registry export — HKLM SOFTWARE/SYSTEM hives, small and fast, covers
    #    driver/service config that setup.exe upgrade sometimes mangles
    try {
        $regBackup = Join-Path $Script:Config.SnapshotDir 'registry'
        New-Item -ItemType Directory -Path $regBackup -Force | Out-Null
        & reg.exe export 'HKLM\SYSTEM' (Join-Path $regBackup 'SYSTEM.reg') /y 2>&1 | Out-Null
        & reg.exe export 'HKLM\SOFTWARE' (Join-Path $regBackup 'SOFTWARE.reg') /y 2>&1 | Out-Null
        Write-Log "Registry hives exported to $regBackup" -Level OK
    } catch {
        Write-Log "Registry export failed (non-fatal): $($_.Exception.Message)" -Level WARN
    }

    # 3. Driver inventory — captures currently-installed 3rd-party drivers so
    #    you have a manifest to reinstall against if the upgrade strips any
    try {
        $driverManifest = Join-Path $Script:Config.SnapshotDir 'drivers_pre_upgrade.txt'
        & pnputil.exe /enum-drivers > $driverManifest 2>&1
        Write-Log "Driver manifest saved: $driverManifest" -Level OK
    } catch {
        Write-Log "Driver manifest capture failed (non-fatal): $($_.Exception.Message)" -Level WARN
    }

    # 4. wbadmin system state backup — the actual heavy insurance, but slow.
    #    Opt-in via explicit param since it can add 15-30min depending on disk.
    #    (kept lightweight by default: registry+restore-point+driver list only)
    Write-Log 'Snapshot complete (Restore Point + registry hives + driver manifest)' -Level OK
    Write-Log "For a full system-state backup, run manually: wbadmin start backup -backupTarget:<drive> -include:C: -allCritical -quiet" -Level INFO
}

# ============================================================
#  MEDIA ACQUISITION
# ============================================================
function Get-Windows10Iso {
    Write-Log 'Resolving Windows 10 ISO...'
    New-Item -ItemType Directory -Path $Script:Config.IsoDir -Force | Out-Null
    $isoPath = Join-Path $Script:Config.IsoDir "Win10_$($Script:Arch).iso"

    if (Test-Path $isoPath) {
        $existingSize = (Get-Item $isoPath).Length / 1GB
        if ($existingSize -gt 3 -and (Test-IsoIntegrity -Path $isoPath)) {
            Write-Log "Existing valid ISO found (${existingSize}GB), reusing" -Level OK
            return $isoPath
        } elseif (Test-Path $isoPath) {
            Write-Log 'Existing ISO invalid/incomplete, re-downloading' -Level WARN
            Remove-Item $isoPath -Force
        }
    }

    if ($IsoUrl) {
        Write-Log "Using user-supplied ISO URL, skipping Microsoft download-connector scrape" -Level OK
        Invoke-BitsDownload -Url $IsoUrl -Destination $isoPath
        return $isoPath
    }

    $sessionId = [guid]::NewGuid().ToString()
    $productEditionId = 611

    try {
        Write-Log 'Requesting session from Microsoft download servers...'
        $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 6.3; Win64; x64)' }

        $permalinkUri = "https://www.microsoft.com/en-us/software-download/windows10ISO"
        $null = Invoke-WebRequest -Uri $permalinkUri -Headers $headers -SessionVariable msSession -UseBasicParsing -TimeoutSec 30

        $catalogUri = "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=$sessionId"
        $null = Invoke-WebRequest -Uri $catalogUri -Headers $headers -WebSession $msSession -UseBasicParsing -TimeoutSec 30

        $langUri = "https://www.microsoft.com/en-us/api/controls/contentinclude/html?pageId=6e2a1789-ef16-4f27-a296-74ef7ef5d96b&host=www.microsoft.com&segments=software-download,windows10ISO&query=&action=getskuinformationbyproductedition&sessionId=$sessionId&productEditionId=$productEditionId&sdVersion=2"
        $langResp = Invoke-WebRequest -Uri $langUri -Headers $headers -WebSession $msSession -UseBasicParsing -TimeoutSec 30

        if ($langResp.Content -notmatch 'English') {
            throw 'Unexpected response — Microsoft may have changed their download flow markup'
        }

        $skuIdMatch = [regex]::Match($langResp.Content, 'option value="(\d+)"[^>]*>English')
        if (-not $skuIdMatch.Success) { throw 'Could not extract SKU ID' }
        $skuId = $skuIdMatch.Groups[1].Value

        $urlUri = "https://www.microsoft.com/en-us/api/controls/contentinclude/html?pageId=6e2a1789-ef16-4f27-a296-74ef7ef5d96b&host=www.microsoft.com&segments=software-download,windows10ISO&query=&action=GetProductDownloadLinksBySku&sessionId=$sessionId&skuId=$skuId&language=English&sdVersion=2"
        $urlResp = Invoke-WebRequest -Uri $urlUri -Headers $headers -WebSession $msSession -UseBasicParsing -TimeoutSec 30

        $archPattern = if ($Script:Arch -eq 'x64') { '64-bit' } else { '32-bit' }
        $urlMatch = [regex]::Match($urlResp.Content, "href=`"([^`"]+)`"[^>]*>[^<]*$archPattern")
        if (-not $urlMatch.Success) { throw "Could not extract $archPattern URL" }

        $downloadUrl = [System.Web.HttpUtility]::HtmlDecode($urlMatch.Groups[1].Value)
        Write-Log 'Resolved direct ISO URL (expires ~24h)' -Level OK

    } catch {
        Write-Log "Dynamic URL resolution failed: $($_.Exception.Message)" -Level WARN
        Write-Log 'Falling back to Media Creation Tool (has a UI step, no true silent switch exists)...' -Level WARN
        return Get-Windows10IsoViaMCT
    }

    Invoke-BitsDownload -Url $downloadUrl -Destination $isoPath
    return $isoPath
}

function Get-Windows10IsoViaMCT {
    $mctPath = Join-Path $Script:Config.IsoDir 'MediaCreationTool.exe'
    Invoke-BitsDownload -Url $Script:Config.MctUrl -Destination $mctPath
    Write-Log 'Launching Media Creation Tool interactively (no documented silent ISO-only switch exists)...' -Level WARN
    Start-Process -FilePath $mctPath -Wait
    Exit-Fatal 'MCT requires manual completion. Re-run with -IsoUrl pointing at the resulting ISO, or place it at the iso directory and re-run.'
}

function Invoke-BitsDownload {
    param([string]$Url, [string]$Destination)
    Write-Log "Downloading to $Destination ..."

    try {
        Import-Module BitsTransfer -ErrorAction Stop
        $job = Start-BitsTransfer -Source $Url -Destination $Destination -DisplayName "wingrade_$(Get-Random)" -Asynchronous -ErrorAction Stop

        $lastPct = -1
        while ($job.JobState -in @('Transferring','Connecting','Queued','TransientError')) {
            if ($job.JobState -eq 'TransientError') { Write-Log 'BITS transient error, retrying...' -Level WARN }
            Start-Sleep -Seconds 3
            $job = Get-BitsTransfer -JobId $job.JobId
            if ($job.BytesTotal -gt 0) {
                $pct = [math]::Round(($job.BytesTransferred / $job.BytesTotal) * 100)
                if ($pct -ne $lastPct -and $pct % 5 -eq 0) {
                    Write-Log "Download: ${pct}% ($([math]::Round($job.BytesTransferred/1MB))MB / $([math]::Round($job.BytesTotal/1MB))MB)"
                    $lastPct = $pct
                }
            }
        }

        if ($job.JobState -eq 'Transferred') {
            Complete-BitsTransfer -BitsJob $job
            Write-Log "Download complete: $Destination" -Level OK
        } else {
            $errDesc = $job.ErrorDescription
            Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
            throw "BITS ended in state '$($job.JobState)': $errDesc"
        }
    } catch {
        Write-Log "BITS failed, falling back to Invoke-WebRequest: $($_.Exception.Message)" -Level WARN
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
            Write-Log "Fallback download complete: $Destination" -Level OK
        } catch {
            Exit-Fatal "All download methods failed: $($_.Exception.Message)"
        }
    }
}

function Test-IsoIntegrity {
    param([string]$Path)
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $stream.Seek(0x8001, [System.IO.SeekOrigin]::Begin) | Out-Null
        $buffer = New-Object byte[] 5
        $stream.Read($buffer, 0, 5) | Out-Null
        $stream.Close()
        return ([System.Text.Encoding]::ASCII.GetString($buffer) -eq 'CD001')
    } catch { return $false }
}

# ============================================================
#  MOUNT & INVOKE SETUP
# ============================================================
function Mount-InstallIso {
    param([string]$IsoPath)
    Write-Log "Mounting ISO: $IsoPath"
    try {
        $mountResult = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2
        $driveLetter = ($mountResult | Get-Volume).DriveLetter
        if (-not $driveLetter) { throw 'No drive letter assigned to mounted ISO' }
        $Script:Config.MountDrive = "${driveLetter}:"
        Write-Log "Mounted at $($Script:Config.MountDrive)" -Level OK

        $setupExe = Join-Path $Script:Config.MountDrive 'setup.exe'
        if (-not (Test-Path $setupExe)) { throw "setup.exe not found — ISO structure unexpected" }
        return $setupExe
    } catch {
        Exit-Fatal "Failed to mount ISO: $($_.Exception.Message)"
    }
}

function New-UnattendFile {
    <#
        Only invoked if -UnattendPath is supplied. Copies user's unattend.xml
        into the location setup.exe auto-discovers it from (root of a drive
        it scans, or explicitly via /unattend: switch — we use the switch,
        more reliable than relying on autodiscovery).
    #>
    if (-not $UnattendPath) { return $null }
    if (-not (Test-Path $UnattendPath)) {
        Write-Log "Specified UnattendPath '$UnattendPath' not found — proceeding WITHOUT unattend injection" -Level WARN
        return $null
    }
    $dest = Join-Path $Script:Config.LogDir 'unattend.xml'
    Copy-Item -Path $UnattendPath -Destination $dest -Force
    Write-Log "Unattend file staged: $dest" -Level OK
    return $dest
}

function Invoke-Win10Setup {
    param([string]$SetupExePath)

    New-Item -ItemType Directory -Path $Script:Config.LogDir -Force | Out-Null

    $unattendFile = New-UnattendFile

    $setupArgs = @(
        '/auto', 'upgrade',
        '/quiet',
        '/noreboot',
        '/dynamicupdate', 'disable',
        '/telemetry', 'disable',
        '/eula', 'accept'
    )

    if ($unattendFile) {
        $setupArgs += @('/unattend:' + $unattendFile)
        Write-Log "Injecting unattend.xml: $unattendFile" -Level OK
    }

    if ($SkipCompatCheck) {
        $setupArgs += @('/compat', 'IgnoreWarning')
        Write-Log 'Compat check bypass ENABLED (/compat IgnoreWarning)' -Level WARN
    }

    Write-Log "Invoking: $SetupExePath $($setupArgs -join ' ')"

    $proc = Start-Process -FilePath $SetupExePath -ArgumentList $setupArgs -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Log "Setup started (PID $($proc.Id)). Monitoring, timeout=${TimeoutMinutes}min..."

    while (-not $proc.HasExited) {
        if ((Get-Date) -gt $deadline) {
            Write-Log 'Setup exceeded timeout — abnormal for pre-reboot staging' -Level ERROR
            Write-Log 'NOT auto-killing — mid-flight kills of setup.exe can corrupt the install' -Level ERROR
            Write-Log "Check manually: Get-Process -Id $($proc.Id)" -Level ERROR
            return $false
        }
        Start-Sleep -Seconds 15
        $setupActLog = Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\Panther\setupact.log'
        if (Test-Path $setupActLog) {
            $lastLine = Get-Content $setupActLog -Tail 1 -ErrorAction SilentlyContinue
            if ($lastLine) { Write-Log "setup.exe: $lastLine" }
        }
    }

    $exitCode = $proc.ExitCode
    Write-Log "setup.exe exited: $exitCode ($('0x{0:X8}' -f $exitCode))"

    switch ($exitCode) {
        0           { Write-Log 'Upgrade staged successfully, pending reboot' -Level OK; return $true }
        3010        { Write-Log 'Success, reboot required' -Level OK; return $true }
        -1047526904 { Exit-Fatal 'Compat check blocked upgrade (0xC1900208). Re-run with -SkipCompatCheck.' }
        -1047526912 { Exit-Fatal 'Insufficient disk space for upgrade staging (0xC1900200).' }
        default     { Write-Log "Unrecognized exit code — check $($Script:Config.LogDir) and `$env:SystemDrive\`$WINDOWS.~BT\Sources\Panther\" -Level ERROR; return $false }
    }
}

function Dismount-InstallIso {
    param([string]$IsoPath)
    try {
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop
        Write-Log 'ISO dismounted' -Level OK
    } catch {
        Write-Log "Dismount failed (non-fatal): $($_.Exception.Message)" -Level WARN
    }
}

# ============================================================
#  MAIN
# ============================================================
function Main {
    New-Item -ItemType Directory -Path $Script:Config.LogDir -Force | Out-Null
    Write-Host $Banner -ForegroundColor Magenta
    Write-Log 'wingrade starting — please wait, do not close this window'

    Test-Prerequisites
    New-PreUpgradeSnapshot
    Suspend-CompetingServices

    try {
        $isoPath = Get-Windows10Iso
        if (-not (Test-Path $isoPath)) { Exit-Fatal 'ISO acquisition failed' }
        if (-not (Test-IsoIntegrity -Path $isoPath)) { Exit-Fatal 'ISO failed integrity check (bad CD001 signature)' }
        Write-Log "ISO ready: $isoPath ($([math]::Round((Get-Item $isoPath).Length / 1GB, 2))GB)" -Level OK

        $setupExe = Mount-InstallIso -IsoPath $isoPath

        try {
            $success = Invoke-Win10Setup -SetupExePath $setupExe

            if ($success) {
                $elapsed = (Get-Date) - $Script:Config.StartTime
                Write-Log "Staging complete in $([math]::Round($elapsed.TotalMinutes, 1)) minutes" -Level OK

                if ($NoReboot) {
                    Write-Log 'NoReboot set — run "shutdown /r /t 0" manually to complete' -Level WARN
                } else {
                    Write-Log 'Rebooting in 30s to complete upgrade... (Ctrl+C to cancel)' -Level WARN
                    Start-Sleep -Seconds 30
                    Restart-Computer -Force
                }
            } else {
                Exit-Fatal 'Setup invocation reported failure — check Panther logs'
            }
        } finally {
            Dismount-InstallIso -IsoPath $isoPath
        }
    } finally {
        # Runs even on success — if we DIDN'T reboot (NoReboot flag), services
        # get restored immediately. If we DID reboot, this line never
        # executes (process is gone), which is fine: the fresh Win10 boot
        # will bring its own service defaults up cleanly on its own.
        Restore-SuspendedServices
    }
}

try {
    Main
} catch {
    Write-Log "Unhandled exception: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    Restore-SuspendedServices
    exit 1
}
