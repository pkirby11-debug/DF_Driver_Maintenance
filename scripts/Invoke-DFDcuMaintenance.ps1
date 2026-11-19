#Requires -Version 5.1
<#
.SYNOPSIS
    Runs Dell Command | Update inside the nightly Deep Freeze maintenance window -- only while
    the machine is Thawed -- and restarts inside the window when DCU needs a restart.

.DESCRIPTION
    One self-contained file, so it can be pushed from the Deep Freeze Cloud console as a single
    script. Four modes:

      Install    The default. Copies this file to %ProgramFiles%\DFMaintenance\DCU, writes
                 config.json beside it, sets DCU's own scheduler to manual and its pop-up
                 notifications off, and registers the scheduled task
                 \DFMaintenance-DellCommandUpdate, which runs as SYSTEM.
                 Run Install while the machine is THAWED. A task created on a Frozen machine is
                 discarded at the next restart, so Install refuses (exit 20). Otherwise it would
                 report a success that disappears.

      Run        What the task executes. Does nothing unless the time is inside the window AND
                 DFC.exe reports the machine Thawed. Then: dcu-cli /scan, dcu-cli /applyUpdates,
                 and if DCU needs a restart, a restart -- inside the window, still Thawed --
                 after which the at-startup trigger runs the next pass.

      Status     Prints the last result, the schedule and the current freeze state.

      Uninstall  Removes the task and the installed files. Also needs a Thawed machine.

    THE SCHEDULE IT REGISTERS (defaults)
      * Daily at WindowStart + 10 min, repeating every 60 min until the install cutoff, so a
        run that found the machine still Frozen is retried later in the window.
      * At startup (+5 min). Continues a restart chain, and catches Deep Freeze's own Thawed
        restart at the start of the window.
      Every run decides for itself whether there is anything to do, so the extra triggers cost
      a few seconds each. The first pass of a night waits a random 0-20 min so a fleet that
      Deep Freeze thawed at the same minute does not download from Dell at the same minute.

    WHY IT CHECKS THE FREEZE STATE
      Anything installed on a Frozen machine is thrown away at the next restart, and DCU then
      offers the same updates the next night, restarts included, forever. A run on a Frozen
      machine installs nothing and records SkippedFrozen. If that repeats every night, the
      Deep Freeze Thawed Period is not covering the window.

    WHY IT RESTARTS THE MACHINE ITSELF
      BIOS and many driver updates finish during the restart after they are installed. If that
      restart is Deep Freeze's end-of-window restart, it boots Frozen and the finishing work is
      discarded. Restarting inside the window, while still Thawed, keeps it.

    WHY NOT DCU'S BUILT-IN SCHEDULER
      It knows nothing about Deep Freeze. It would install while Frozen, at times of its own
      choosing, with pop-ups on a patient-facing screen.

    WHY NOT A DEEP FREEZE BATCH FILE TASK
      Deep Freeze restarts the machine Frozen as soon as the batch file finishes, so the
      restart DCU asks for would always land on a Frozen boot.

    Logs and status go to a ThawSpace volume when one is found or -StatePath names one, so
    they survive Frozen restarts:
      <state>\dcu\dcu-status.json          last meaningful result (what a collector reads)
      <state>\dcu\logs\dfdcu-YYYYMM.jsonl  full history, one JSON object per line
      <state>\dcu\dcu-logs\                copies of DCU's own logs and scan reports

    Windows PowerShell 5.1, no external modules, ASCII-only source. Never needs the Deep Freeze
    password: DFC.exe "get /ISFROZEN" is a read-only query.

.PARAMETER Mode
    Install (default), Run, Status or Uninstall.

.PARAMETER WindowStart
    Start of the maintenance window, local 24-hour HH:mm. Default 22:00. It must match the
    Deep Freeze Thawed Period that thaws these machines.

.PARAMETER WindowEnd
    End of the window, HH:mm. Default 06:00. The window may cross midnight.

.PARAMETER UpdateType
    DCU update types: bios, firmware, driver, application, others. Default bios,firmware,driver.

.PARAMETER UpdateSeverity
    DCU severities: security, critical, recommended, optional. Default security,critical,recommended.

.PARAMETER UpdateDeviceCategory
    Optional DCU device-category filter: audio, video, network, storage, input, chipset, others.
    Empty (default) = all categories.

.PARAMETER StatePath
    Durable base directory for logs and status, e.g. T:\DFMaintenance (files go in its dcu
    subfolder). Default: the first fixed volume labelled like -ThawSpaceLabelPattern, else
    %ProgramData%\DFMaintenance, which does NOT survive a Frozen restart. Install pins the
    resolved path, and its volume serial, into config.json.

.PARAMETER NoReboot
    Never restart. Not recommended: the restart that finishes BIOS and driver installs then
    becomes Deep Freeze's Frozen restart, which discards that work.

.PARAMETER SkipFreezeCheck
    Install/Uninstall only: proceed even when the machine is Frozen or its state is unreadable.
    For lab use. The change is discarded at the next Frozen restart.

.PARAMETER DryRun
    Run only: scan and report what DCU would install. Never installs or restarts, never touches
    the pass counter, and writes dcu-status-dryrun.json instead of dcu-status.json. Also works
    on a Frozen machine, since it changes nothing.

.PARAMETER IgnoreWindow
    Run only: skip the time-window check (the freeze check still applies). For testing a full
    pass, including the restart, on a Thawed machine during the day.

.PARAMETER ConfigPath
    Run/Status/Uninstall: read this config.json instead of the installed one. For testing.

.EXAMPLE
    # Deep Freeze Cloud > Applications > Scripts, PowerShell, System Account, run on a THAWED
    # machine with an empty command line: installs with the defaults (22:00-06:00,
    # BIOS + firmware + drivers).
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-DFDcuMaintenance.ps1

.EXAMPLE
    # A different window and a pinned ThawSpace path:
    .\Invoke-DFDcuMaintenance.ps1 -WindowStart 02:05 -WindowEnd 06:00 -StatePath T:\DFMaintenance

.EXAMPLE
    # On a test machine at any time: show what DCU would install, change nothing.
    & "$env:ProgramFiles\DFMaintenance\DCU\Invoke-DFDcuMaintenance.ps1" -Mode Run -DryRun -IgnoreWindow

.EXAMPLE
    & "$env:ProgramFiles\DFMaintenance\DCU\Invoke-DFDcuMaintenance.ps1" -Mode Status

.NOTES
    Exit codes, Run mode (Task Scheduler "Last Run Result"):
        0     Done: updates applied with no restart needed, already up to date, or already
              finished tonight
     3010     A restart was scheduled to finish installing; the next pass runs after it
        1     Skipped: outside the window, or too close to its end to start
        2     Skipped: machine Frozen, or freeze state could not be confirmed
        3     Skipped: pass limit reached with updates left, servicing busy, or another run active
        4     DCU unavailable: not installed, too old, untrusted binary, service missing or
              disabled, not a Dell, or model unsupported
        5     DCU failed (scan/apply/download error, timeout, low disk); retried next trigger
        6     Configuration or command-line error that retrying will not fix
        7     DCU still needs a restart but the window is nearly over (or NoReboot is set)
        9     Unexpected script error

    Exit codes, Install/Uninstall:
        0     Done
       20     Refused: machine Frozen or freeze state unknown -- the change would be discarded
       21     DCU missing, older than MinimumDcuVersion, untrusted, or its service unusable
       22     Not elevated, or the script cannot locate its own file
       23     Copying files, writing config or registering the task failed
       24     Invalid parameters (nothing was changed)
       29     Unexpected script error
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Run', 'Status', 'Uninstall')]
    [string] $Mode = 'Install',

    # Settings. When omitted, the defaults in $script:DcuDefaults below apply.
    [string]   $WindowStart,
    [string]   $WindowEnd,
    [string[]] $UpdateType,
    [string[]] $UpdateSeverity,
    [string[]] $UpdateDeviceCategory,
    [int]      $StartDelayMinutes,
    [int]      $RandomDelayMinutes,
    [int]      $RetryIntervalMinutes,
    [int]      $InstallCutoffMinutes,
    [int]      $RebootCutoffMinutes,
    [int]      $MaxPassesPerNight,
    [int]      $RebootDelaySeconds,
    [int]      $ScanTimeoutMinutes,
    [int]      $ApplyTimeoutMinutes,
    [int]      $ServicingWaitMinutes,
    [int]      $MinFreeSpaceGB,
    [int]      $LogRetentionDays,
    [string]   $StatePath,
    [string]   $ThawSpaceLabelPattern,
    [string]   $DFCPath,
    [string]   $MinimumDcuVersion,
    [switch]   $NoReboot,
    [switch]   $LeaveDcuSettings,
    [switch]   $RunWithoutDeepFreeze,
    [switch]   $WakeToRun,

    # Mode-specific switches. These are never written to config.json.
    [switch]   $SkipFreezeCheck,
    [switch]   $DryRun,
    [switch]   $IgnoreWindow,
    [string]   $ConfigPath
)

$ErrorActionPreference = 'Stop'

# =================================================================================================
# DEFAULTS. Edit these to change what every machine gets when this file is pushed with an empty
# command line. Values passed on the command line at Install override them. The result is written
# to config.json, which is all the nightly runs read.
# =================================================================================================
$script:DcuDefaults = [ordered]@{
    WindowStart           = '22:00'      # Deep Freeze maintenance window start, local 24h HH:mm
    WindowEnd             = '06:00'      # ...and end. May cross midnight.
    UpdateType            = @('bios', 'firmware', 'driver')            # + application, others
    UpdateSeverity        = @('security', 'critical', 'recommended')   # + optional
    UpdateDeviceCategory  = @()          # empty = all categories
    StartDelayMinutes     = 10           # first scheduled run = WindowStart + this
    RandomDelayMinutes    = 20           # first pass of a night waits a random 0..this
    RetryIntervalMinutes  = 60           # re-check through the window; 0 = no repeats
    InstallCutoffMinutes  = 90           # no new DCU pass this close to WindowEnd
    RebootCutoffMinutes   = 30           # no restart this close to WindowEnd
    MaxPassesPerNight     = 3            # BIOS + drivers usually needs two; a third confirms
    RebootDelaySeconds    = 120          # on-screen warning before the restart
    NoReboot              = $false       # never restart (not recommended -- see .DESCRIPTION)
    ScanTimeoutMinutes    = 30
    ApplyTimeoutMinutes   = 120
    ServicingWaitMinutes  = 30           # wait this long for Windows servicing / MSI to go idle
    MinFreeSpaceGB        = 2
    LogRetentionDays      = 60
    StatePath             = $null        # e.g. 'T:\DFMaintenance'; empty = find ThawSpace by label
    ThawSpaceLabelPattern = 'ThawSpace*'
    DFCPath               = $null        # explicit DFC.exe; honoured only under Program Files/Windows
    MinimumDcuVersion     = '5.0'
    LeaveDcuSettings      = $false       # $true = never run dcu-cli /configure (ADMX/Intune-managed)
    RunWithoutDeepFreeze  = $false       # $true = run even when Deep Freeze is not detected at all
    WakeToRun             = $false       # wake the machine for the scheduled trigger
}

# Written by Install, read by Run. Not user settings.
$script:DcuInstallKeys = @('PinnedStatePath', 'PinnedVolumeSerial', 'InstalledAt', 'InstalledVersion')

$script:DcuIntRanges = @{
    StartDelayMinutes    = @(0, 240)
    RandomDelayMinutes   = @(0, 120)
    RetryIntervalMinutes = @(0, 240)
    InstallCutoffMinutes = @(0, 1380)
    RebootCutoffMinutes  = @(0, 1380)
    MaxPassesPerNight    = @(1, 10)
    RebootDelaySeconds   = @(0, 600)
    ScanTimeoutMinutes   = @(5, 240)
    ApplyTimeoutMinutes  = @(10, 480)
    ServicingWaitMinutes = @(0, 120)
    MinFreeSpaceGB       = @(0, 500)
    LogRetentionDays     = @(1, 3650)
}
$script:DcuListValues = @{
    UpdateType           = @('bios', 'firmware', 'driver', 'application', 'others')
    UpdateSeverity       = @('security', 'critical', 'recommended', 'optional')
    UpdateDeviceCategory = @('audio', 'video', 'network', 'storage', 'input', 'chipset', 'others')
}
$script:DcuBoolKeys = @('NoReboot', 'LeaveDcuSettings', 'RunWithoutDeepFreeze', 'WakeToRun')

$script:DcuScriptVersion        = '1.0.0'
$script:DcuScriptFileName       = 'Invoke-DFDcuMaintenance.ps1'
$script:DcuTaskName             = 'DFMaintenance-DellCommandUpdate'
$script:DcuEventSource          = 'DFMaintenance-DCU'
$script:DcuMutexName            = 'Global\DFMaintenance-DCU'
$script:DcuServiceName          = 'DellClientManagementService'
$script:DcuStartupDelayMinutes  = 5
$script:DcuBusyRetries          = 3
$script:DcuBusyDelaySeconds     = 180
$script:DcuServicingPollSeconds = 30
$script:DcuScriptPath           = $PSCommandPath
$script:DcuRunId                = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
$script:DcuMode                 = $Mode
$script:DcuLogFile              = $null
$script:DcuRetentionDays        = 60
$script:DcuRunStarted           = $null

# =================================================================================================
# Small utilities
# =================================================================================================

function Get-DcuNow {
    # Single clock source, so the tests can pin the time.
    Get-Date
}

function Get-DcuValue {
    # Reads a key from a dictionary ($PSBoundParameters, hashtable) or a property from a
    # PSCustomObject (parsed JSON), returning $null when absent. Arrays are returned intact.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if (@($Object.Keys) -contains $Name) { return , $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return , $property.Value }
    return $null
}

function ConvertTo-DcuList {
    # 'bios,firmware' / @('bios','firmware') / @('bios,firmware') -> lowercase, de-duplicated array.
    # A Deep Freeze command line hands -File arrays over as one comma-joined string, hence the split.
    param($Value)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        foreach ($part in ([string]$item -split '[,;\s]+')) {
            $token = $part.Trim().ToLowerInvariant()
            if ($token -and -not $out.Contains($token)) { $out.Add($token) }
        }
    }
    return $out.ToArray()
}

function ConvertTo-DcuVersion {
    param([string] $Text)
    if ($Text -and $Text -match '^\s*(\d+(\.\d+){1,3})') { return [version]$Matches[1] }
    return $null
}

function Write-DcuTextFile {
    # BOM-less UTF-8 on both 5.1 and 7.x. Set-Content -Encoding UTF8 writes a BOM on 5.1, which
    # breaks every non-PowerShell JSON reader of the status files.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content,
        [switch] $Append
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    if ($Append) { [System.IO.File]::AppendAllText($Path, $Content, $encoding) }
    else { [System.IO.File]::WriteAllText($Path, $Content, $encoding) }
}

function Write-DcuJsonFile {
    # Write to a temp file and move it into place, so a reader never sees half a file.
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $InputObject)
    $json = ConvertTo-Json -InputObject $InputObject -Depth 8
    $temp = $Path + '.tmp'
    Write-DcuTextFile -Path $temp -Content $json
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Write-DcuLog {
    # Console line plus one JSON Lines record. Never throws: a run must not fail over its log.
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Info', 'Warning', 'Error')] [string] $Level = 'Info',
        [System.Collections.IDictionary] $Data
    )
    $prefix = switch ($Level) { 'Warning' { 'WARN ' } 'Error' { 'ERROR' } default { 'INFO ' } }
    Write-Host ('{0} {1}' -f $prefix, $Message)
    if (-not $script:DcuLogFile) { return }
    $record = [ordered]@{
        Timestamp = (Get-Date).ToString('o')
        Level     = $Level
        Computer  = $env:COMPUTERNAME
        RunId     = $script:DcuRunId
        Mode      = $script:DcuMode
        Message   = $Message
    }
    if ($Data) { $record['Data'] = $Data }
    try {
        $line = ConvertTo-Json -InputObject $record -Depth 8 -Compress
        Write-DcuTextFile -Path $script:DcuLogFile -Content ($line + [Environment]::NewLine) -Append
    } catch {
        Write-Host ('WARN  Log write failed ({0}): {1}' -f $script:DcuLogFile, $_.Exception.Message)
    }
}

function Initialize-DcuLog {
    param([Parameter(Mandatory)] [string] $StateDir)
    try {
        $dir = Join-Path $StateDir 'logs'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $script:DcuLogFile = Join-Path $dir ('dfdcu-{0}.jsonl' -f (Get-Date -Format 'yyyyMM'))
    } catch {
        $script:DcuLogFile = $null
        Write-Host ('WARN  Persistent logging unavailable under {0}: {1}' -f $StateDir, $_.Exception.Message)
    }
}

function Get-DcuInstallDir { Join-Path $env:ProgramFiles 'DFMaintenance\DCU' }

function Get-DcuWorkDir {
    # DCU 5.x refuses -outputLog/-report paths under Windows, Program Files and Users\Public, and
    # documents C:\ProgramData\Dell as a valid place for its logs. DCU writes here; the run then
    # copies what matters to the durable state directory.
    param([string] $Child)
    $base = Join-Path $env:ProgramData 'Dell\DFMaintenance'
    if ($Child) { return (Join-Path $base $Child) }
    return $base
}

function Test-DcuElevated {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Test-DcuSamePath {
    param([string] $A, [string] $B)
    try {
        return [string]::Equals([System.IO.Path]::GetFullPath($A), [System.IO.Path]::GetFullPath($B),
                                [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

# =================================================================================================
# Configuration
# =================================================================================================

function ConvertTo-DcuTimeOfDay {
    param([Parameter(Mandatory)] [string] $Text)
    $parts = $Text.Split(':')
    return New-TimeSpan -Hours ([int]$parts[0]) -Minutes ([int]$parts[1])
}

function Get-DcuWindowLengthMinutes {
    param([Parameter(Mandatory)] $Config)
    $start = ConvertTo-DcuTimeOfDay $Config.WindowStart
    $end = ConvertTo-DcuTimeOfDay $Config.WindowEnd
    $minutes = [int]($end - $start).TotalMinutes
    if ($minutes -le 0) { $minutes += 1440 }
    return $minutes
}

function ConvertTo-DcuConfig {
    <#
        Merges raw values -- $PSBoundParameters at Install, parsed config.json at Run -- over the
        defaults, validating every value. Returns @{ Config; Problems }. Never throws.

        Install refuses on any problem, because a typo on a Deep Freeze command line should fail
        loudly on the first machine, not quietly on every machine. Run logs the problems and
        carries on with corrected values.
    #>
    param($Raw)

    $problems = New-Object System.Collections.Generic.List[string]
    $config = [ordered]@{}
    foreach ($key in $script:DcuDefaults.Keys) { $config[$key] = $script:DcuDefaults[$key] }
    foreach ($key in $script:DcuInstallKeys) { $config[$key] = $null }

    foreach ($key in @($config.Keys)) {
        $value = Get-DcuValue -Object $Raw -Name $key
        if ($null -eq $value) { continue }

        if ($script:DcuIntRanges.ContainsKey($key)) {
            $number = 0
            if ($value -is [bool] -or -not [int]::TryParse([string]$value, [ref]$number)) {
                $problems.Add("$key '$value' is not a whole number; using $($config[$key]).")
                continue
            }
            $range = $script:DcuIntRanges[$key]
            if ($number -lt $range[0] -or $number -gt $range[1]) {
                $problems.Add("$key $number is outside $($range[0])-$($range[1]); using $($config[$key]).")
                continue
            }
            $config[$key] = $number
            continue
        }

        if ($script:DcuListValues.ContainsKey($key)) {
            $allowed = $script:DcuListValues[$key]
            $items = @(ConvertTo-DcuList $value)
            $unknown = @($items | Where-Object { $allowed -notcontains $_ })
            $valid = @($items | Where-Object { $allowed -contains $_ })
            if ($unknown.Count -gt 0) {
                $problems.Add("$key value(s) '$($unknown -join ',')' not supported. Allowed: $($allowed -join ', ').")
            }
            if ($valid.Count -eq 0 -and $key -ne 'UpdateDeviceCategory') {
                if ($unknown.Count -eq 0) { $problems.Add("$key is empty; using $($config[$key] -join ',').") }
                continue
            }
            $config[$key] = $valid
            continue
        }

        if ($script:DcuBoolKeys -contains $key) {
            if ($value -is [System.Management.Automation.SwitchParameter]) { $config[$key] = $value.IsPresent }
            elseif ($value -is [bool]) { $config[$key] = $value }
            elseif ([string]$value -match '^(true|false)$') { $config[$key] = ([string]$value -eq 'true') }
            else { $problems.Add("$key '$value' is not true/false; using $($config[$key]).") }
            continue
        }

        $text = ([string]$value).Trim()
        if ($key -eq 'WindowStart' -or $key -eq 'WindowEnd') {
            if ($text -match '^([01]\d|2[0-3]):[0-5]\d$') { $config[$key] = $text }
            else { $problems.Add("$key '$text' is not a 24-hour HH:mm time; using $($config[$key]).") }
        } elseif ($key -eq 'MinimumDcuVersion') {
            $parsed = $null
            if ([version]::TryParse($text, [ref]$parsed)) { $config[$key] = $parsed.ToString() }
            else { $problems.Add("MinimumDcuVersion '$text' is not a version; using $($config[$key]).") }
        } elseif ($key -eq 'StatePath') {
            if ($text -eq '') { $config[$key] = $null }
            elseif ([System.IO.Path]::IsPathRooted($text) -and $text.IndexOfAny([char[]]'*?<>|"') -lt 0) {
                $config[$key] = $text.TrimEnd('\')
            } else { $problems.Add("StatePath '$text' must be an absolute path, e.g. T:\DFMaintenance.") }
        } elseif ($key -eq 'ThawSpaceLabelPattern') {
            if ($text.Length -ge 1 -and $text.Length -le 64) { $config[$key] = $text }
            else { $problems.Add("ThawSpaceLabelPattern must be 1-64 characters; using $($config[$key]).") }
        } else {
            $config[$key] = if ($text -eq '') { $null } else { $text }
        }
    }

    # Cross-field checks. The window comes first because every other limit is measured against it.
    if ($config.WindowStart -eq $config.WindowEnd) {
        $problems.Add("WindowStart and WindowEnd are both $($config.WindowStart); using $($script:DcuDefaults.WindowStart)-$($script:DcuDefaults.WindowEnd).")
        $config.WindowStart = $script:DcuDefaults.WindowStart
        $config.WindowEnd = $script:DcuDefaults.WindowEnd
    }
    $length = Get-DcuWindowLengthMinutes -Config $config
    if ($length -lt 60) {
        $problems.Add("The window $($config.WindowStart)-$($config.WindowEnd) is $length min; at least 60 is needed for a scan, an install and a restart. Using $($script:DcuDefaults.WindowStart)-$($script:DcuDefaults.WindowEnd).")
        $config.WindowStart = $script:DcuDefaults.WindowStart
        $config.WindowEnd = $script:DcuDefaults.WindowEnd
        $length = Get-DcuWindowLengthMinutes -Config $config
    }
    if ($config.RetryIntervalMinutes -gt 0 -and $config.RetryIntervalMinutes -lt 15) {
        $problems.Add("RetryIntervalMinutes $($config.RetryIntervalMinutes) is below 15; using 15.")
        $config.RetryIntervalMinutes = 15
    }
    $maxInstallCutoff = $length - 30
    if ($config.InstallCutoffMinutes -gt $maxInstallCutoff) {
        $problems.Add("InstallCutoffMinutes $($config.InstallCutoffMinutes) leaves less than 30 min of a $length-min window; using $maxInstallCutoff.")
        $config.InstallCutoffMinutes = $maxInstallCutoff
    }
    if ($config.RebootCutoffMinutes -gt $config.InstallCutoffMinutes) {
        $problems.Add("RebootCutoffMinutes $($config.RebootCutoffMinutes) is larger than InstallCutoffMinutes $($config.InstallCutoffMinutes), so a pass could finish with no time left to restart; using $($config.InstallCutoffMinutes).")
        $config.RebootCutoffMinutes = $config.InstallCutoffMinutes
    }
    $maxStartDelay = $length - $config.InstallCutoffMinutes - 1
    if ($config.StartDelayMinutes -gt $maxStartDelay) {
        $problems.Add("StartDelayMinutes $($config.StartDelayMinutes) starts after the install cutoff; using $maxStartDelay.")
        $config.StartDelayMinutes = $maxStartDelay
    }

    return @{ Config = $config; Problems = $problems.ToArray() }
}

function Read-DcuInstalledConfig {
    param([string] $Path)
    if (-not $Path) { $Path = Join-Path (Get-DcuInstallDir) 'config.json' }

    $raw = $null
    $note = $null
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $note = "No config.json at '$Path'; using built-in defaults."
    } else {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $note = "config.json at '$Path' is unreadable ($($_.Exception.Message)); using built-in defaults."
        }
    }

    $built = ConvertTo-DcuConfig -Raw $raw
    $problems = @($built.Problems)
    if ($note) { $problems = @($note) + $problems }
    return @{ Config = $built.Config; Problems = $problems; Path = $Path; Found = ($null -ne $raw) }
}

# =================================================================================================
# Time window
# =================================================================================================

function Get-DcuWindowState {
    <#
        Where $Now sits relative to the window. Handles windows that cross midnight -- the
        22:00-06:00 default does -- which a naive "start <= now < end" test gets wrong.

        NightId is the date the window OPENED, so 23:30 and 03:30 belong to the same night and
        share one pass counter.
    #>
    param([Parameter(Mandatory)] [datetime] $Now, [Parameter(Mandatory)] $Config)

    $start = ConvertTo-DcuTimeOfDay $Config.WindowStart
    $end = ConvertTo-DcuTimeOfDay $Config.WindowEnd
    $time = $Now.TimeOfDay
    $crossesMidnight = $start -gt $end

    if ($crossesMidnight) { $inWindow = ($time -ge $start) -or ($time -lt $end) }
    else { $inWindow = ($time -ge $start) -and ($time -lt $end) }

    $nightDate = $Now.Date
    if ($crossesMidnight -and $time -lt $end) { $nightDate = $Now.Date.AddDays(-1) }
    $opens = $nightDate.Add($start)
    $closes = $nightDate.Add($end)
    if ($crossesMidnight) { $closes = $closes.AddDays(1) }

    $minutesLeft = $null
    if ($inWindow) { $minutesLeft = [int][math]::Floor(($closes - $Now).TotalMinutes) }

    return [pscustomobject]@{
        NightId           = $nightDate.ToString('yyyy-MM-dd')
        InWindow          = $inWindow
        Opens             = $opens.ToString('yyyy-MM-ddTHH:mm')
        Closes            = $closes.ToString('yyyy-MM-ddTHH:mm')
        MinutesUntilClose = $minutesLeft
        CanStartInstall   = [bool]($inWindow -and $minutesLeft -gt $Config.InstallCutoffMinutes)
        CanReboot         = [bool]($inWindow -and $minutesLeft -gt $Config.RebootCutoffMinutes)
    }
}

function Get-DcuSchedulePlan {
    # The trigger times Install registers, derived from the window and the cutoffs.
    param([Parameter(Mandatory)] $Config)

    $start = ConvertTo-DcuTimeOfDay $Config.WindowStart
    $length = Get-DcuWindowLengthMinutes -Config $Config
    $installStopsAfter = $length - $Config.InstallCutoffMinutes
    $rebootStopsAfter = $length - $Config.RebootCutoffMinutes

    $format = {
        param([int] $minutesAfterStart)
        $t = New-TimeSpan -Minutes ((([int]$start.TotalMinutes) + $minutesAfterStart) % 1440)
        '{0:00}:{1:00}' -f $t.Hours, $t.Minutes
    }

    $repeatFor = $installStopsAfter - $Config.StartDelayMinutes
    $repeat = ($Config.RetryIntervalMinutes -gt 0) -and ($repeatFor -gt $Config.RetryIntervalMinutes)

    return [pscustomobject]@{
        FirstStart         = (& $format $Config.StartDelayMinutes)
        FirstStartSpan     = New-TimeSpan -Minutes ((([int]$start.TotalMinutes) + $Config.StartDelayMinutes) % 1440)
        RepeatEveryMinutes = $(if ($repeat) { $Config.RetryIntervalMinutes } else { 0 })
        RepeatForMinutes   = $(if ($repeat) { $repeatFor } else { 0 })
        InstallCutoff      = (& $format $installStopsAfter)
        RebootCutoff       = (& $format $rebootStopsAfter)
        WindowMinutes      = $length
    }
}

# =================================================================================================
# State directory, trust and permissions
# =================================================================================================

function Test-DcuTrustedPath {
    <#
        $true only for a path under an administrator-controlled root (Program Files, Windows),
        optionally with a required file name. Everything this script executes as SYSTEM --
        DFC.exe, dcu-cli.exe, and this script itself via the task -- must pass, so a
        user-writable copy can never be what runs.
    #>
    param([AllowEmptyString()] [string] $Path, [string] $ExpectedLeaf)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    if ($ExpectedLeaf -and ([System.IO.Path]::GetFileName($full) -ne $ExpectedLeaf)) { return $false }

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:SystemRoot) | Where-Object { $_ }
    foreach ($root in $roots) {
        try { $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/') } catch { continue }
        # Root + separator, so 'C:\Program FilesEvil' cannot pass as 'C:\Program Files'.
        if ($full.StartsWith($rootFull + $separator, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-DcuPathRoot {
    param([string] $Path)
    try { return [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path)) } catch { return $null }
}

function Test-DcuPersistentPath {
    # Anything on the system volume is Frozen with it. A different volume is assumed to be a
    # ThawSpace or otherwise excluded from the freeze.
    param([string] $Path)
    $root = Get-DcuPathRoot $Path
    if (-not $root) { return $false }
    if (-not $env:SystemDrive) { return $true }
    $systemRoot = Get-DcuPathRoot ($env:SystemDrive + '\')
    return -not [string]::Equals($root, $systemRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Find-DcuThawSpaceVolume {
    param([string] $LabelPattern)
    $volumes = @()
    try {
        $volumes = @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop |
            Where-Object { $_.DriveType -eq 3 -and $_.VolumeName -and $_.VolumeName -like $LabelPattern -and
                           $_.DeviceID -ne $env:SystemDrive } |
            Sort-Object DeviceID)
    } catch {
        return $null
    }
    if ($volumes.Count -eq 0) { return $null }
    $pick = $volumes[0]
    return [pscustomobject]@{
        DeviceID           = [string]$pick.DeviceID
        VolumeName         = [string]$pick.VolumeName
        VolumeSerialNumber = [string]$pick.VolumeSerialNumber
        Ambiguous          = ($volumes.Count -gt 1)
        All                = @($volumes | ForEach-Object { [string]$_.DeviceID })
    }
}

function Get-DcuVolumeSerial {
    param([string] $Path)
    $root = Get-DcuPathRoot $Path
    if (-not $root) { return $null }
    $id = $root.TrimEnd('\')
    if ($id -notmatch '^[A-Za-z]:$') { return $null }
    try {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $id) -ErrorAction Stop
        if ($disk) { return [string]$disk.VolumeSerialNumber }
    } catch { }
    return $null
}

function Set-DcuDirectorySecurity {
    <#
        SYSTEM and Administrators full control, Users read-only, inheritance off. Never throws.

        Install applies this to the state directory and the DCU work directory. Both hold files a
        SYSTEM process writes on a machine the public uses. Left with ProgramData's default ACL,
        which lets Users create files, a user could plant a link where dcu-cli.exe will write its
        log, or edit the pass counter. Well-known SIDs, so it also works on non-English Windows.
    #>
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $sid = {
            param($type)
            New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::$type, $null)
        }
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $propagate = [System.Security.AccessControl.PropagationFlags]::None
        $allow = [System.Security.AccessControl.AccessControlType]::Allow

        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($existing in @($acl.Access)) { [void]$acl.RemoveAccessRule($existing) }
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((& $sid 'LocalSystemSid'), 'FullControl', $inherit, $propagate, $allow)))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((& $sid 'BuiltinAdministratorsSid'), 'FullControl', $inherit, $propagate, $allow)))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((& $sid 'BuiltinUsersSid'), 'ReadAndExecute', $inherit, $propagate, $allow)))
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        return $true
    } catch {
        Write-DcuLog -Level Warning -Message "Could not restrict permissions on '$Path': $($_.Exception.Message). Restrict it to SYSTEM and Administrators by hand."
        return $false
    }
}

function Resolve-DcuStatePath {
    <#
        Where logs, status and the pass counter live.

        Install resolves it once -- explicit -StatePath, else a ThawSpace found by label, else the
        ProgramData fallback -- and pins the result and its volume serial in config.json. Runs use
        the pinned path, so a USB disk someone labels "ThawSpace" can never become the state
        volume, and a swapped volume is reported rather than trusted.

        Only logs and status are written here. No setting is ever read back from it: config.json
        lives in Program Files.
    #>
    param([Parameter(Mandatory)] $Config, [switch] $ForInstall, [switch] $NoCreate)

    $fallback = Join-Path $env:ProgramData 'DFMaintenance\dcu'
    $warning = $null
    $serial = $null

    if (-not $ForInstall -and $Config.PinnedStatePath) {
        $dir = $Config.PinnedStatePath
        $source = 'Pinned at install'
        $root = Get-DcuPathRoot $dir
        if (-not $root -or -not (Test-Path -LiteralPath $root)) {
            $warning = "State volume for '$dir' is not present; using $fallback, which does not survive a Frozen restart."
            $dir = $fallback
            $source = 'ProgramData fallback'
        } else {
            $serial = Get-DcuVolumeSerial -Path $dir
            if ($Config.PinnedVolumeSerial -and $serial -and ($serial -ne $Config.PinnedVolumeSerial)) {
                $warning = "Volume $root has serial $serial, not $($Config.PinnedVolumeSerial) as recorded at install -- it may have been swapped. Using $fallback instead."
                $dir = $fallback
                $source = 'ProgramData fallback'
                $serial = $null
            }
        }
    } elseif ($Config.StatePath) {
        $dir = Join-Path $Config.StatePath 'dcu'
        $source = 'Configured StatePath'
        $serial = Get-DcuVolumeSerial -Path $Config.StatePath
    } else {
        $volume = Find-DcuThawSpaceVolume -LabelPattern $Config.ThawSpaceLabelPattern
        if ($volume) {
            $dir = Join-Path ($volume.DeviceID + '\') 'DFMaintenance\dcu'
            $source = "ThawSpace $($volume.DeviceID) '$($volume.VolumeName)'"
            $serial = $volume.VolumeSerialNumber
            if ($volume.Ambiguous) {
                $warning = "Several volumes match '$($Config.ThawSpaceLabelPattern)' ($($volume.All -join ', ')); using $($volume.DeviceID). Pass -StatePath to choose explicitly."
            }
        } else {
            $dir = $fallback
            $source = 'ProgramData fallback'
        }
    }

    if ($NoCreate) {
        # Status mode: report where things are without creating anything, possibly unelevated.
        return [pscustomobject]@{
            Path         = $dir
            Source       = $source
            IsPersistent = (Test-DcuPersistentPath -Path $dir)
            VolumeSerial = $serial
            Warning      = $warning
        }
    }

    $created = -not (Test-Path -LiteralPath $dir)
    try {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    } catch {
        $warning = "Could not create '$dir' ($($_.Exception.Message)); using $fallback."
        $dir = $fallback
        $source = 'ProgramData fallback'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if ($created -and -not $ForInstall) { [void](Set-DcuDirectorySecurity -Path $dir) }

    return [pscustomobject]@{
        Path         = $dir
        Source       = $source
        IsPersistent = (Test-DcuPersistentPath -Path $dir)
        VolumeSerial = $serial
        Warning      = $warning
    }
}

# =================================================================================================
# Deep Freeze
# =================================================================================================

function Get-DcuDfcPath {
    <#
        Locates DFC.exe. Every candidate, including an operator-supplied DFCPath, must be a DFC.exe
        under Program Files or Windows: whatever this returns is executed as SYSTEM. There is
        deliberately no PATH search.
    #>
    param([string] $ConfiguredPath)

    if ($ConfiguredPath) {
        if (-not (Test-DcuTrustedPath -Path $ConfiguredPath -ExpectedLeaf 'DFC.exe')) {
            Write-DcuLog -Level Warning -Message "Configured DFCPath '$ConfiguredPath' is not a DFC.exe under Program Files or Windows; ignoring it."
        } elseif (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $ConfiguredPath).ProviderPath
        }
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:SystemRoot) {
        $candidates.Add((Join-Path $env:SystemRoot 'SysWOW64\DFC.exe'))
        $candidates.Add((Join-Path $env:SystemRoot 'System32\DFC.exe'))
    }
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles) | Where-Object { $_ }) {
        $candidates.Add((Join-Path $base 'Faronics\Deep Freeze\DFC.exe'))
        $candidates.Add((Join-Path $base 'Faronics\Deep Freeze Enterprise\DFC.exe'))
    }
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and
            (Test-DcuTrustedPath -Path $candidate -ExpectedLeaf 'DFC.exe')) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }
    return $null
}

function Get-DcuFreezeState {
    <#
        Frozen / Thawed / Unknown / NotInstalled, from "DFC.exe get /ISFROZEN".

        - The literal 'get' is part of the documented syntax: "DFC <password|get> /COMMAND".
        - The exit code is INVERTED from the usual convention: 1 = Frozen, 0 = Thawed.
        - stderr is merged with the preference set to Continue. On 5.1, a stderr line under
          'Stop' becomes a terminating error before $LASTEXITCODE is read, which would turn a
          readable answer into Unknown.
    #>
    param([string] $DfcPath)

    $result = [ordered]@{
        State        = 'Unknown'
        Method       = 'None'
        DfcPath      = $null
        ExitCode     = $null
        ServiceFound = $false
        Detail       = $null
    }

    $service = $null
    try { $service = @(Get-Service -Name 'DFServ', 'DeepFreeze*' -ErrorAction SilentlyContinue) | Select-Object -First 1 } catch { }
    if ($service) { $result.ServiceFound = $true }

    $dfc = Get-DcuDfcPath -ConfiguredPath $DfcPath
    if (-not $dfc) {
        if ($service) { $result.Detail = "Deep Freeze service '$($service.Name)' is present but DFC.exe was not found." }
        else {
            $result.State = 'NotInstalled'
            $result.Detail = 'No Deep Freeze service and no DFC.exe were found.'
        }
        return [pscustomobject]$result
    }

    $result.DfcPath = $dfc
    $result.Method = 'DFC.exe get /ISFROZEN'
    $output = $null
    $code = $null
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = (& $dfc 'get' '/ISFROZEN' 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    } catch {
        $result.Detail = "DFC.exe could not be run: $($_.Exception.Message)"
        return [pscustomobject]$result
    } finally {
        $ErrorActionPreference = $previous
    }

    $result.ExitCode = $code
    switch ($code) {
        1 { $result.State = 'Frozen' }
        0 { $result.State = 'Thawed' }
        default {
            $result.Detail = "DFC.exe returned unexpected exit code '$code'."
            if ($output) { $result.Detail += " Output: $output" }
        }
    }
    return [pscustomobject]$result
}

function Get-DcuFreezeRefusal {
    param([Parameter(Mandatory)] $Freeze, [Parameter(Mandatory)] $Config)
    switch ($Freeze.State) {
        'Frozen' {
            return "Machine is FROZEN, so nothing was run: anything DCU installed now would be discarded at the next restart. If this repeats every night, the Deep Freeze Thawed Period is not covering $($Config.WindowStart)-$($Config.WindowEnd)."
        }
        'NotInstalled' {
            return 'Deep Freeze was not detected (no DFServ service, no DFC.exe), so the freeze state cannot be confirmed and nothing was run. If these machines are not protected, install with -RunWithoutDeepFreeze.'
        }
        default {
            return "Freeze state could not be determined ($($Freeze.Detail)), so nothing was run: 'could not tell' is not the same as Thawed. Pass -DFCPath at install if DFC.exe lives somewhere unusual."
        }
    }
}

# =================================================================================================
# Dell Command | Update
# =================================================================================================

# Return codes from the Dell Command | Update 5.x Reference Guide (Rev. A14, Feb 2026),
# "Command Line Interface Error codes". The category decides what the run does next.
$script:DcuExitCodes = @{
    0    = 'Success|Command execution was successful.'
    1    = 'RebootRequired|A reboot was required from the execution of an operation.'
    2    = 'Transient|An unknown application error has occurred.'
    3    = 'Unavailable|The current system manufacturer is not Dell.'
    4    = 'UsageError|The CLI was not launched with administrative privilege.'
    5    = 'RebootRequired|A reboot was pending from a previous operation.'
    6    = 'Busy|Another instance of the same application (UI or CLI) is already running.'
    7    = 'Unavailable|The application does not support the current system model.'
    8    = 'UsageError|No update filters have been applied or configured.'
    100  = 'UsageError|No parameters were detected.'
    101  = 'UsageError|No commands were detected.'
    102  = 'UsageError|Invalid commands were detected.'
    103  = 'UsageError|Duplicate commands were detected.'
    104  = 'UsageError|The command syntax was incorrect.'
    105  = 'UsageError|The option syntax was incorrect.'
    106  = 'UsageError|Invalid options were detected.'
    107  = 'UsageError|One or more values provided to an option were invalid.'
    108  = 'UsageError|Mandatory options were not detected.'
    109  = 'UsageError|An invalid combination of options was detected.'
    110  = 'UsageError|Multiple commands were detected.'
    111  = 'UsageError|Duplicate options were detected.'
    112  = 'UsageError|An invalid catalog was detected.'
    113  = 'UsageError|One or more values exceed the length limit.'
    500  = 'UpToDate|No updates were found (the system is up to date, or nothing matches the filters).'
    501  = 'Transient|An error occurred while determining the available updates.'
    502  = 'Transient|The scan was cancelled.'
    503  = 'Transient|A file download failed during the scan (check network access to Dell).'
    1000 = 'Transient|An error occurred when retrieving the result of the apply operation.'
    1001 = 'Transient|The apply operation was cancelled.'
    1002 = 'Transient|A file download failed during the apply operation (check network access to Dell).'
    1505 = 'UsageError|An error occurred while exporting the application settings.'
    1506 = 'UsageError|An error occurred while importing the application settings.'
    2500 = 'UsageError|An error occurred while encrypting the password.'
    2501 = 'UsageError|An error occurred while encrypting the password with the key provided.'
    2502 = 'UsageError|The encrypted password does not match the current encryption method.'
    3000 = 'ServiceStopped|The Dell Client Management Service is not running.'
    3001 = 'Unavailable|The Dell Client Management Service is not installed.'
    3002 = 'Unavailable|The Dell Client Management Service is disabled.'
    3003 = 'Busy|The Dell Client Management Service is busy.'
    3004 = 'Busy|The Dell Client Management Service is self-updating the application.'
    3005 = 'Busy|The Dell Client Management Service is installing pending updates.'
}

function Get-DcuExitInfo {
    param([Parameter(Mandatory)] [int] $Code)
    $entry = $script:DcuExitCodes[$Code]
    if ($entry) {
        $parts = $entry -split '\|', 2
        return [pscustomobject]@{ Code = $Code; Category = $parts[0]; Meaning = $parts[1] }
    }
    return [pscustomobject]@{ Code = $Code; Category = 'Unknown'; Meaning = "Unrecognised Dell Command | Update return code $Code." }
}

function Get-DcuSignatureStatus {
    # Defence in depth on top of the Program Files location check. Blocks only clear-cut problems:
    # a revocation check that cannot reach the internet must not stop the nightly run.
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Status = 'NotChecked'; Problem = $null }
    }
    try { $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop }
    catch { return [pscustomobject]@{ Status = 'CheckFailed'; Problem = $null } }

    $status = [string]$signature.Status
    $subject = ''
    if ($signature.SignerCertificate) { $subject = [string]$signature.SignerCertificate.Subject }
    if ($status -eq 'HashMismatch' -or $status -eq 'NotSigned' -or $status -eq 'NotSupportedFileFormat') {
        return [pscustomobject]@{ Status = $status; Problem = "dcu-cli.exe signature status is $status; refusing to run it as SYSTEM." }
    }
    if ($status -eq 'Valid' -and $subject -notmatch 'Dell') {
        return [pscustomobject]@{ Status = $status; Problem = "dcu-cli.exe is signed by '$subject', not Dell; refusing to run it as SYSTEM." }
    }
    return [pscustomobject]@{ Status = $status; Problem = $null }
}

function Find-DcuCli {
    # dcu-cli.exe lives under Program Files (x86) for the classic installer and under Program Files
    # for the Universal app. If both are present, the newer one wins.
    $bases = @(${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramFiles) | Where-Object { $_ } | Select-Object -Unique
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($base in $bases) {
        $path = Join-Path $base 'Dell\CommandUpdate\dcu-cli.exe'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        if (-not (Test-DcuTrustedPath -Path $path -ExpectedLeaf 'dcu-cli.exe')) { continue }
        $item = Get-Item -LiteralPath $path
        $version = $null
        if ($item.VersionInfo) {
            $version = ConvertTo-DcuVersion ([string]$item.VersionInfo.ProductVersion)
            if (-not $version) { $version = ConvertTo-DcuVersion ([string]$item.VersionInfo.FileVersion) }
        }
        $found.Add([pscustomobject]@{ Path = $item.FullName; Version = $version })
    }
    if ($found.Count -eq 0) { return $null }

    $best = $found | Sort-Object -Property @{ Expression = { if ($_.Version) { $_.Version } else { [version]'0.0' } } } -Descending |
        Select-Object -First 1
    $signature = Get-DcuSignatureStatus -Path $best.Path
    $best | Add-Member -NotePropertyName Signature -NotePropertyValue $signature.Status
    $best | Add-Member -NotePropertyName SignatureProblem -NotePropertyValue $signature.Problem
    return $best
}

function Get-DcuServiceState {
    $service = $null
    try { $service = Get-Service -Name $script:DcuServiceName -ErrorAction Stop } catch { }
    if (-not $service) { return [pscustomobject]@{ Installed = $false; Status = $null; StartType = $null } }
    $startType = $null
    try { $startType = [string]$service.StartType } catch { }
    return [pscustomobject]@{ Installed = $true; Status = [string]$service.Status; StartType = $startType }
}

function Start-DcuService {
    try {
        Start-Service -Name $script:DcuServiceName -ErrorAction Stop
    } catch {
        Write-DcuLog -Level Warning -Message "Could not start $($script:DcuServiceName): $($_.Exception.Message)"
        return $false
    }
    for ($i = 0; $i -lt 30; $i++) {
        if ((Get-DcuServiceState).Status -eq 'Running') { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function New-DcuOption {
    # -name=value, quoted only when the value contains a space (the DCU guide's own rule).
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Value)
    if ($Value -match '\s') { return ('-{0}="{1}"' -f $Name, $Value) }
    return ('-{0}={1}' -f $Name, $Value)
}

function Get-DcuFilterOptions {
    # Passed explicitly on every /scan and /applyUpdates, so what is installed never depends on
    # whatever someone last set in the DCU UI.
    param([Parameter(Mandatory)] $Config)
    $options = @(
        ('-updateType=' + (@($Config.UpdateType) -join ',')),
        ('-updateSeverity=' + (@($Config.UpdateSeverity) -join ','))
    )
    if (@($Config.UpdateDeviceCategory).Count -gt 0) {
        $options += ('-updateDeviceCategory=' + (@($Config.UpdateDeviceCategory) -join ','))
    }
    return $options
}

function Get-DcuFileTail {
    param([string] $Path, [int] $Lines = 15)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $text = @(Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop) -join "`n"
        if ($text.Length -gt 2000) { $text = $text.Substring($text.Length - 2000) }
        return $text.Trim()
    } catch {
        return $null
    }
}

function Invoke-DcuCli {
    <#
        Runs dcu-cli.exe once with a timeout. Start-Process with redirected output -- not & -- so a
        hung DCU cannot hold the run past the window, and stderr chatter cannot abort it.
    #>
    param(
        [Parameter(Mandatory)] [string] $DcuPath,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [double] $TimeoutMinutes,
        [Parameter(Mandatory)] [string] $Tag
    )

    $workDir = Get-DcuWorkDir 'work'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $stamp = (Get-DcuNow).ToString('yyyyMMdd-HHmmss')
    $stdout = Join-Path $workDir ('{0}-{1}.stdout.txt' -f $stamp, $Tag)
    $stderr = Join-Path $workDir ('{0}-{1}.stderr.txt' -f $stamp, $Tag)
    $argumentLine = $Arguments -join ' '

    $result = [ordered]@{
        Tag             = $Tag
        CommandLine     = ('"{0}" {1}' -f $DcuPath, $argumentLine)
        ExitCode        = $null
        TimedOut        = $false
        StartError      = $null
        DurationSeconds = 0
        OutputTail      = $null
    }
    Write-DcuLog -Message "Running: $($result.CommandLine)"

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $process = Start-Process -FilePath $DcuPath -ArgumentList $argumentLine -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
        # Reading Handle before the process exits keeps ExitCode available afterwards; without it,
        # Windows PowerShell 5.1 can report a null exit code for Start-Process -PassThru.
        $null = $process.Handle
        $timeoutMs = [int][math]::Min([double][int]::MaxValue, [double]$TimeoutMinutes * 60000)
        if ($process.WaitForExit($timeoutMs)) {
            $process.WaitForExit()
            $result.ExitCode = $process.ExitCode
        } else {
            $result.TimedOut = $true
            try { $process.Kill() } catch { }
            Write-DcuLog -Level Error -Message "dcu-cli.exe did not finish within $TimeoutMinutes min and was stopped."
        }
    } catch {
        $result.StartError = $_.Exception.Message
        Write-DcuLog -Level Error -Message "dcu-cli.exe could not be started: $($result.StartError)"
    }
    $watch.Stop()
    $result.DurationSeconds = [int]$watch.Elapsed.TotalSeconds

    $tail = @((Get-DcuFileTail -Path $stdout), (Get-DcuFileTail -Path $stderr)) | Where-Object { $_ }
    if ($tail) { $result.OutputTail = ($tail -join "`n") }
    return [pscustomobject]$result
}

function Invoke-DcuCliWithRetry {
    # Waits out "busy" codes (another DCU instance, the service self-updating) and starts a stopped
    # service once. Everything else is returned for the caller to classify.
    param(
        [Parameter(Mandatory)] [string] $DcuPath,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [double] $TimeoutMinutes,
        [Parameter(Mandatory)] [string] $Tag
    )
    $attempt = 0
    $serviceStartTried = $false
    while ($true) {
        $attempt++
        $r = Invoke-DcuCli -DcuPath $DcuPath -Arguments $Arguments -TimeoutMinutes $TimeoutMinutes -Tag $Tag
        if ($r.TimedOut) { $info = [pscustomobject]@{ Category = 'TimedOut'; Meaning = "dcu-cli.exe did not finish within $TimeoutMinutes minutes and was stopped." } }
        elseif ($null -eq $r.ExitCode) { $info = [pscustomobject]@{ Category = 'StartFailed'; Meaning = "dcu-cli.exe could not be started: $($r.StartError)" } }
        else { $info = Get-DcuExitInfo -Code $r.ExitCode }

        if ($info.Category -eq 'Busy' -and $attempt -le $script:DcuBusyRetries) {
            Write-DcuLog -Level Warning -Message "DCU is busy ($($r.ExitCode): $($info.Meaning)); retrying in $($script:DcuBusyDelaySeconds) s."
            Start-Sleep -Seconds $script:DcuBusyDelaySeconds
            continue
        }
        if ($info.Category -eq 'ServiceStopped' -and -not $serviceStartTried) {
            $serviceStartTried = $true
            Write-DcuLog -Level Warning -Message 'Dell Client Management Service is not running; starting it and retrying.'
            [void](Start-DcuService)
            continue
        }

        $r | Add-Member -NotePropertyName Category -NotePropertyValue $info.Category
        $r | Add-Member -NotePropertyName Meaning -NotePropertyValue $info.Meaning
        $r | Add-Member -NotePropertyName Attempts -NotePropertyValue $attempt
        Write-DcuLog -Message ("dcu-cli {0} -> {1} [{2}] {3}" -f $Tag, $r.ExitCode, $info.Category, $info.Meaning)
        return $r
    }
}

function Copy-DcuArtifact {
    param([string] $Path, [Parameter(Mandatory)] [string] $StateDir)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    try {
        $target = Join-Path $StateDir 'dcu-logs'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Copy-Item -LiteralPath $Path -Destination $target -Force
    } catch {
        Write-DcuLog -Level Warning -Message "Could not copy '$Path' to the state directory: $($_.Exception.Message)"
    }
}

function Invoke-DcuOperation {
    # One dcu-cli command with its own -outputLog (and -report for /scan), both copied to the
    # durable state directory afterwards.
    param(
        [Parameter(Mandatory)] $Dcu,
        [Parameter(Mandatory)] [string] $Command,
        [string[]] $Options = @(),
        [Parameter(Mandatory)] [double] $TimeoutMinutes,
        [Parameter(Mandatory)] [string] $Tag,
        [Parameter(Mandatory)] [string] $StateDir,
        [switch] $WithReport
    )
    $logDir = Get-DcuWorkDir 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $stamp = (Get-DcuNow).ToString('yyyyMMdd-HHmmss')
    $log = Join-Path $logDir ('{0}-{1}.log' -f $stamp, $Tag)
    $report = $null

    $arguments = @("/$Command") + @($Options) + @(New-DcuOption -Name 'outputLog' -Value $log)
    if ($WithReport) {
        $report = Join-Path $logDir ('{0}-{1}-report.xml' -f $stamp, $Tag)
        if (Test-Path -LiteralPath $report) { Remove-Item -LiteralPath $report -Force }
        $arguments += (New-DcuOption -Name 'report' -Value $report)
    }

    $r = Invoke-DcuCliWithRetry -DcuPath $Dcu.Path -Arguments $arguments -TimeoutMinutes $TimeoutMinutes -Tag $Tag
    $r | Add-Member -NotePropertyName LogPath -NotePropertyValue $log
    $r | Add-Member -NotePropertyName ReportPath -NotePropertyValue $report
    Copy-DcuArtifact -Path $log -StateDir $StateDir
    if ($report) { Copy-DcuArtifact -Path $report -StateDir $StateDir }
    return $r
}

function Read-DcuScanReport {
    # The /scan -report XML, flattened to one object per update. Parsed with DTDs prohibited and
    # no resolver; the work directory is ACL'd and the file is deleted before each scan.
    param([string] $Path)
    $list = New-Object System.Collections.Generic.List[object]
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $list.ToArray() }
    try {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [System.Xml.XmlReader]::Create($Path, $settings)
        try {
            $xml = New-Object System.Xml.XmlDocument
            $xml.XmlResolver = $null
            $xml.Load($reader)
        } finally {
            $reader.Dispose()
        }
    } catch {
        Write-DcuLog -Level Warning -Message "Could not read the DCU scan report '$Path': $($_.Exception.Message)"
        return $list.ToArray()
    }

    foreach ($node in @($xml.SelectNodes("//*[local-name()='update' or local-name()='Update']"))) {
        $item = [ordered]@{}
        foreach ($child in @($node.ChildNodes)) {
            if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            $name = $child.LocalName
            if ($item.Contains($name)) { continue }
            $text = ([string]$child.InnerText).Trim()
            if ($text.Length -gt 300) { $text = $text.Substring(0, 300) }
            $item[$name] = $text
        }
        if ($item.Count -gt 0) { $list.Add([pscustomobject]$item) }
        if ($list.Count -ge 100) { break }
    }
    return $list.ToArray()
}

function Set-DcuQuietSettings {
    <#
        Turns off the two DCU behaviours that are wrong for a Deep Freeze kiosk:
          - its own scheduler, which installs while Frozen at times of its own choosing
          - toast notifications on a patient-facing screen
        and turns on BitLocker auto-suspend, without which DCU 5.x silently drops BIOS updates on
        BitLocker machines.

        No -userConsent: that option was removed from DCU 5.x, and an unknown option makes DCU
        reject the whole /configure call (106).
    #>
    param([Parameter(Mandatory)] $Dcu, [Parameter(Mandatory)] [string] $Tag, [Parameter(Mandatory)] [string] $StateDir)
    $options = @('-silent', '-scheduleManual', '-updatesNotification=disable', '-autoSuspendBitLocker=enable')
    return Invoke-DcuOperation -Dcu $Dcu -Command 'configure' -Options $options -TimeoutMinutes 10 -Tag $Tag -StateDir $StateDir
}

# =================================================================================================
# Machine checks
# =================================================================================================

function Get-DcuFreeSpaceGB {
    if (-not $env:SystemDrive) { return $null }
    try {
        $drive = New-Object System.IO.DriveInfo($env:SystemDrive)
        return [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    } catch {
        return $null
    }
}

function Test-DcuServicingBusy {
    # TiWorker.exe means Windows servicing is installing (often Deep Freeze's own Windows Update
    # task); _MSIExecute means an MSI install is in progress, which makes driver installers fail
    # with 1618.
    $reasons = New-Object System.Collections.Generic.List[string]
    try {
        if (Get-Process -Name 'TiWorker' -ErrorAction SilentlyContinue) { $reasons.Add('Windows servicing (TiWorker.exe) is running') }
    } catch { }
    try {
        $mutex = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute')
        $mutex.Dispose()
        $reasons.Add('Windows Installer is busy (_MSIExecute)')
    } catch [System.UnauthorizedAccessException] {
        $reasons.Add('Windows Installer is busy (_MSIExecute)')
    } catch { }
    return $reasons.ToArray()
}

function Wait-DcuServicingIdle {
    param([Parameter(Mandatory)] [int] $MaxMinutes)
    $deadline = (Get-Date).AddMinutes($MaxMinutes)
    $waited = 0
    while ($true) {
        $reasons = @(Test-DcuServicingBusy)
        if ($reasons.Count -eq 0) { return [pscustomobject]@{ Idle = $true; WaitedSeconds = $waited; Reasons = @() } }
        if ((Get-Date) -ge $deadline) { return [pscustomobject]@{ Idle = $false; WaitedSeconds = $waited; Reasons = $reasons } }
        if ($waited -eq 0) { Write-DcuLog -Message "Waiting up to $MaxMinutes min: $($reasons -join '; ')." }
        Start-Sleep -Seconds $script:DcuServicingPollSeconds
        $waited += $script:DcuServicingPollSeconds
    }
}

function Get-DcuPendingReboot {
    $reasons = New-Object System.Collections.Generic.List[string]
    $keys = [ordered]@{
        'Component Based Servicing' = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'Windows Update'            = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    }
    foreach ($name in $keys.Keys) {
        try { if (Test-Path -LiteralPath $keys[$name]) { $reasons.Add($name) } } catch { }
    }
    try {
        $value = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Stop).PendingFileRenameOperations
        if ($value) { $reasons.Add('Pending file rename operations') }
    } catch { }
    return $reasons.ToArray()
}

function Invoke-DcuReboot {
    # shutdown.exe rather than Restart-Computer: it gives logged-on users a warning and a delay,
    # and writes the reason to the System log (event 1074).
    param([Parameter(Mandatory)] [int] $DelaySeconds, [Parameter(Mandatory)] [string] $Comment)
    $exe = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    $text = $Comment.Replace('"', "'")
    if ($text.Length -gt 500) { $text = $text.Substring(0, 500) }
    $arguments = '/r /t {0} /d p:4:2 /c "{1}"' -f $DelaySeconds, $text
    try {
        $process = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru -NoNewWindow -ErrorAction Stop
        $code = $process.ExitCode
    } catch {
        return [pscustomobject]@{ Scheduled = $false; ExitCode = $null; Detail = $_.Exception.Message }
    }
    # 1190: a shutdown is already scheduled. 1115: one is in progress. Either way it restarts.
    $ok = ($code -eq 0) -or ($code -eq 1115) -or ($code -eq 1190)
    return [pscustomobject]@{ Scheduled = $ok; ExitCode = $code; Detail = "shutdown.exe exit code $code" }
}

# =================================================================================================
# Per-night state (the pass counter)
# =================================================================================================

function New-DcuNightState {
    param([Parameter(Mandatory)] [string] $NightId)
    return [ordered]@{
        SchemaVersion     = 1
        NightId           = $NightId
        Passes            = 0
        InProgress        = $false
        Completed         = $false
        InterruptedPasses = 0
        LastOutcome       = $null
        AppliedTonight    = @()     # "name version" of each update DCU reported applying tonight
        UpdatedAt         = $null
    }
}

function Read-DcuNightState {
    <#
        Returns tonight's state, or a fresh one when the file is missing, from another night, or
        not what this script writes. Every field is type- and range-checked: the file sits on a
        volume the public can reach, and a bad value must cost at most one extra pass.
    #>
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $NightId)
    $fresh = New-DcuNightState -NightId $NightId
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $fresh }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-DcuLog -Level Warning -Message "Pass state '$Path' is unreadable; starting the night fresh."
        return $fresh
    }
    if ([string](Get-DcuValue $raw 'NightId') -ne $NightId) { return $fresh }

    $passes = 0
    if (-not [int]::TryParse([string](Get-DcuValue $raw 'Passes'), [ref]$passes) -or $passes -lt 0 -or $passes -gt 100) {
        Write-DcuLog -Level Warning -Message "Pass state '$Path' has an invalid pass count; starting the night fresh."
        return $fresh
    }
    $interrupted = 0
    [void][int]::TryParse([string](Get-DcuValue $raw 'InterruptedPasses'), [ref]$interrupted)

    $fresh.Passes = $passes
    $fresh.InterruptedPasses = [math]::Max(0, [math]::Min($interrupted, 100))
    $fresh.InProgress = ((Get-DcuValue $raw 'InProgress') -is [bool]) -and (Get-DcuValue $raw 'InProgress')
    $fresh.Completed = ((Get-DcuValue $raw 'Completed') -is [bool]) -and (Get-DcuValue $raw 'Completed')
    $last = [string](Get-DcuValue $raw 'LastOutcome')
    if ($last -match '^[A-Za-z]{1,40}$') { $fresh.LastOutcome = $last }
    # Assign first, then pipe: Get-DcuValue returns arrays intact, so @(Get-DcuValue ...) would nest.
    $applied = Get-DcuValue $raw 'AppliedTonight'
    $fresh.AppliedTonight = @(@($applied) | Where-Object { $_ -is [string] -and $_.Length -le 200 } | Select-Object -First 50)
    return $fresh
}

function Add-DcuAppliedUpdates {
    # Records what an apply that succeeded (or wants a restart) covered, so the final status of
    # the night can say what went in on earlier passes.
    param([Parameter(Mandatory)] $Night, [object[]] $Updates)
    $names = foreach ($update in @($Updates)) {
        $name = if ($update.PSObject.Properties['name']) { [string]$update.name } else { '' }
        $version = if ($update.PSObject.Properties['version']) { [string]$update.version } else { '' }
        $text = ('{0} {1}' -f $name, $version).Trim()
        if ($text) { if ($text.Length -gt 200) { $text.Substring(0, 200) } else { $text } }
    }
    $Night.AppliedTonight = @(@($Night.AppliedTonight) + @($names) | Select-Object -Unique | Select-Object -First 50)
}

function Save-DcuNightState {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $State)
    $State.UpdatedAt = (Get-DcuNow).ToString('o')
    try {
        Write-DcuJsonFile -Path $Path -InputObject $State
        return $true
    } catch {
        Write-DcuLog -Level Error -Message "Could not save pass state to '$Path': $($_.Exception.Message)"
        return $false
    }
}

# =================================================================================================
# Run records, status file, event log
# =================================================================================================

function New-DcuRunRecord {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $StateInfo, [bool] $DryRun)
    $script:DcuRunStarted = Get-DcuNow
    return [ordered]@{
        SchemaVersion       = 1
        ScriptVersion       = $script:DcuScriptVersion
        Computer            = $env:COMPUTERNAME
        RunId               = $script:DcuRunId
        DryRun              = $DryRun
        StartedAt           = $script:DcuRunStarted.ToString('o')
        FinishedAt          = $null
        DurationSeconds     = $null
        Outcome             = $null
        Severity            = $null
        ExitCode            = $null
        Message             = $null
        NightId             = $null
        Pass                = $null
        MaxPassesPerNight   = $Config.MaxPassesPerNight
        Window              = $null
        FreezeState         = $null
        FreezeDetail        = $null
        StatePath           = $StateInfo.Path
        StateIsPersistent   = $StateInfo.IsPersistent
        PendingRebootBefore = @()
        AppliedTonight      = @()
        Dcu                 = [ordered]@{ Path = $null; Version = $null; Configure = $null; Scan = $null; Apply = $null; Updates = @() }
        Reboot              = $null
        LastSuccess         = $null
    }
}

function ConvertTo-DcuResultSummary {
    param($Result)
    if (-not $Result) { return $null }
    return [ordered]@{
        ExitCode        = $Result.ExitCode
        Category        = $Result.Category
        Meaning         = $Result.Meaning
        TimedOut        = $Result.TimedOut
        DurationSeconds = $Result.DurationSeconds
        Attempts        = $Result.Attempts
        Log             = $Result.LogPath
        OutputTail      = $Result.OutputTail
    }
}

function Write-DcuStatusFile {
    # dcu-status.json is the one file a collector needs. LastSuccess is carried forward from the
    # previous file so "when did this machine last finish cleanly?" survives failed nights.
    param([Parameter(Mandatory)] $Run, [Parameter(Mandatory)] [string] $StateDir)
    $name = 'dcu-status.json'
    if ($Run.DryRun) { $name = 'dcu-status-dryrun.json' }
    $path = Join-Path $StateDir $name

    if (-not $Run.DryRun) {
        if ($Run.Outcome -eq 'UpToDate' -or $Run.Outcome -eq 'Applied') {
            $Run.LastSuccess = [ordered]@{ NightId = $Run.NightId; Outcome = $Run.Outcome; At = $Run.FinishedAt }
        } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $previous = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $last = Get-DcuValue $previous 'LastSuccess'
                if ($last) {
                    $Run.LastSuccess = [ordered]@{
                        NightId = [string](Get-DcuValue $last 'NightId')
                        Outcome = [string](Get-DcuValue $last 'Outcome')
                        At      = [string](Get-DcuValue $last 'At')
                    }
                }
            } catch { }
        }
    }
    try { Write-DcuJsonFile -Path $path -InputObject $Run }
    catch { Write-DcuLog -Level Warning -Message "Could not write '$path': $($_.Exception.Message)" }
}

function Register-DcuEventSource {
    if (-not (Get-Command New-EventLog -ErrorAction SilentlyContinue)) { return }
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($script:DcuEventSource)) {
            New-EventLog -LogName Application -Source $script:DcuEventSource -ErrorAction Stop
        }
    } catch {
        Write-DcuLog -Level Warning -Message "Could not register event source '$($script:DcuEventSource)': $($_.Exception.Message)"
    }
}

function Write-DcuEvent {
    # Application log, best effort. Survives Frozen restarts when the Deep Freeze policy has
    # "Retain Windows Event Logs" on, and is where remote tooling tends to look first.
    param([Parameter(Mandatory)] [int] $EventId, [Parameter(Mandatory)] [string] $Severity, [Parameter(Mandatory)] [string] $Message)
    if (-not (Get-Command Write-EventLog -ErrorAction SilentlyContinue)) { return }
    $type = switch ($Severity) { 'Error' { 'Error' } 'Warning' { 'Warning' } default { 'Information' } }
    try {
        Write-EventLog -LogName Application -Source $script:DcuEventSource -EventId $EventId -EntryType $type -Message $Message -ErrorAction Stop
    } catch { }
}

function Invoke-DcuRetention {
    param([string[]] $Directories, [Parameter(Mandatory)] [int] $Days)
    $cutoff = (Get-Date).AddDays(-$Days)
    $removed = 0
    foreach ($dir in $Directories) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
            if ($file.LastWriteTime -ge $cutoff) { continue }
            if (@('.log', '.xml', '.txt', '.jsonl') -notcontains $file.Extension.ToLowerInvariant()) { continue }
            try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop; $removed++ } catch { }
        }
    }
    return $removed
}

function Complete-DcuRun {
    <#
        Finalises a run: log line, status file, event log entry, retention. Returns the exit code.
        -NoOp outcomes (outside the window, already done tonight) are logged only, so a restart at
        10:00 does not overwrite the night's real result in dcu-status.json.
    #>
    param(
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] [string] $StateDir,
        [Parameter(Mandatory)] [string] $Outcome,
        [Parameter(Mandatory)] [int] $ExitCode,
        [Parameter(Mandatory)] [ValidateSet('Info', 'Warning', 'Error')] [string] $Severity,
        [Parameter(Mandatory)] [string] $Message,
        [switch] $NoOp
    )
    $finished = Get-DcuNow
    $Run.Outcome = $Outcome
    $Run.ExitCode = $ExitCode
    $Run.Severity = $Severity
    $Run.Message = $Message
    $Run.FinishedAt = $finished.ToString('o')
    if ($script:DcuRunStarted) { $Run.DurationSeconds = [int]($finished - $script:DcuRunStarted).TotalSeconds }

    if ($NoOp) {
        Write-DcuLog -Level $Severity -Message "[$Outcome] $Message"
        return $ExitCode
    }

    Write-DcuLog -Level $Severity -Message "[$Outcome] $Message" -Data ([ordered]@{ Run = $Run })
    Write-DcuStatusFile -Run $Run -StateDir $StateDir
    Write-DcuEvent -EventId (1000 + $ExitCode) -Severity $Severity -Message ('{0}: {1}' -f $Outcome, $Message)
    $directories = @((Join-Path $StateDir 'logs'), (Join-Path $StateDir 'dcu-logs'), (Get-DcuWorkDir 'logs'), (Get-DcuWorkDir 'work'))
    $removed = Invoke-DcuRetention -Directories $directories -Days $script:DcuRetentionDays
    if ($removed -gt 0) { Write-DcuLog -Message "Retention: removed $removed file(s) older than $($script:DcuRetentionDays) days." }
    return $ExitCode
}

function Complete-DcuNight {
    # Records the outcome in the pass state, then finalises the run. -Final marks the night done,
    # so the hourly retries stop; leave it off for failures worth retrying tonight.
    param(
        [Parameter(Mandatory)] $Run,
        $Night,
        [Parameter(Mandatory)] [string] $StateFile,
        [Parameter(Mandatory)] [string] $StateDir,
        [Parameter(Mandatory)] [string] $Outcome,
        [Parameter(Mandatory)] [int] $ExitCode,
        [Parameter(Mandatory)] [string] $Severity,
        [Parameter(Mandatory)] [string] $Message,
        [switch] $Final
    )
    if ($Night -and -not $Run.DryRun) {
        $Night.InProgress = $false
        if ($Final) { $Night.Completed = $true }
        $Night.LastOutcome = $Outcome
        [void](Save-DcuNightState -Path $StateFile -State $Night)
    }
    return Complete-DcuRun -Run $Run -StateDir $StateDir -Outcome $Outcome -ExitCode $ExitCode -Severity $Severity -Message $Message
}

function Complete-DcuFailure {
    # Maps a failed dcu-cli result to an outcome. Not-a-Dell and bad-arguments are final for the
    # night (retrying cannot help); download errors, timeouts and busy codes are retried.
    param(
        [Parameter(Mandatory)] $Run,
        $Night,
        [Parameter(Mandatory)] [string] $StateFile,
        [Parameter(Mandatory)] [string] $StateDir,
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] [string] $Command
    )
    $detail = "dcu-cli /$Command returned $($Result.ExitCode): $($Result.Meaning) Log: $($Result.LogPath)"
    $phase = if ($Command -eq 'scan') { 'Scan' } else { 'Apply' }
    $common = @{ Run = $Run; Night = $Night; StateFile = $StateFile; StateDir = $StateDir }
    switch ($Result.Category) {
        'Unavailable' { return Complete-DcuNight @common -Outcome 'DcuUnsupported' -ExitCode 4 -Severity 'Error' -Message $detail -Final }
        'UsageError'  { return Complete-DcuNight @common -Outcome 'DcuUsageError' -ExitCode 6 -Severity 'Error' -Message "$detail Retrying will not help; check the DCU log." -Final }
        'TimedOut'    { return Complete-DcuNight @common -Outcome "${phase}TimedOut" -ExitCode 5 -Severity 'Error' -Message $detail }
        default       { return Complete-DcuNight @common -Outcome "${phase}Failed" -ExitCode 5 -Severity 'Error' -Message $detail }
    }
}

function Invoke-DcuRebootStep {
    # DCU wants a restart. Take it inside the window while still Thawed, so whatever finishes during
    # the restart is kept; past the reboot cutoff, record that the work is left pending instead.
    param(
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] $Night,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $StateFile,
        [Parameter(Mandatory)] [string] $StateDir,
        [Parameter(Mandatory)] [string] $Reason,
        [switch] $IgnoreWindow
    )
    $common = @{ Run = $Run; Night = $Night; StateFile = $StateFile; StateDir = $StateDir }
    if ($Config.NoReboot) {
        return Complete-DcuNight @common -Outcome 'RebootRequiredNoReboot' -ExitCode 7 -Severity 'Warning' -Final `
            -Message "DCU needs a restart ($Reason) and NoReboot is set. The next restart will be Deep Freeze's Frozen one, which discards the work that finishes during a restart."
    }
    $window = Get-DcuWindowState -Now (Get-DcuNow) -Config $Config
    if (-not $IgnoreWindow -and -not $window.CanReboot) {
        return Complete-DcuNight @common -Outcome 'RebootPendingAtWindowEnd' -ExitCode 7 -Severity 'Warning' -Final `
            -Message "DCU needs a restart ($Reason) but only $($window.MinutesUntilClose) min of the window remain (restart cutoff $($Config.RebootCutoffMinutes) min). It will finish on a later Thawed night."
    }

    # Record everything BEFORE asking for the restart. With a short RebootDelaySeconds, Windows can
    # end this process before another line runs, and the night's result would be lost.
    $Night.InProgress = $false
    $Night.LastOutcome = 'RebootScheduled'
    [void](Save-DcuNightState -Path $StateFile -State $Night)
    $next = 'A final scan runs after it.'
    if ($Night.Passes -lt $Config.MaxPassesPerNight) { $next = "Pass $($Night.Passes + 1) runs after it." }
    $Run.Reboot = [ordered]@{ Requested = $true; DelaySeconds = $Config.RebootDelaySeconds; ShutdownExitCode = $null; Detail = $null }
    $exitCode = Complete-DcuRun -Run $Run -StateDir $StateDir -Outcome 'RebootScheduled' -ExitCode 3010 -Severity 'Info' `
        -Message "DCU needs a restart ($Reason); restarting in $($Config.RebootDelaySeconds) s. $next"

    $comment = 'Dell Command | Update maintenance: restarting in {0} seconds to finish installing BIOS/driver updates.' -f $Config.RebootDelaySeconds
    $reboot = Invoke-DcuReboot -DelaySeconds $Config.RebootDelaySeconds -Comment $comment
    $Run.Reboot.ShutdownExitCode = $reboot.ExitCode
    $Run.Reboot.Detail = $reboot.Detail
    if (-not $reboot.Scheduled) {
        $Night.LastOutcome = 'RebootFailed'
        [void](Save-DcuNightState -Path $StateFile -State $Night)
        return Complete-DcuRun -Run $Run -StateDir $StateDir -Outcome 'RebootFailed' -ExitCode 5 -Severity 'Error' `
            -Message "DCU needs a restart ($Reason) but it could not be scheduled: $($reboot.Detail)"
    }
    return $exitCode
}

# =================================================================================================
# Run mode
# =================================================================================================

function Invoke-DcuRunCore {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $StateInfo,
        [string[]] $ConfigProblems = @(),
        [switch] $DryRun,
        [switch] $IgnoreWindow
    )

    $script:DcuRetentionDays = $Config.LogRetentionDays
    $stateDir = $StateInfo.Path
    $run = New-DcuRunRecord -Config $Config -StateInfo $StateInfo -DryRun ([bool]$DryRun)
    foreach ($problem in @($ConfigProblems)) { if ($problem) { Write-DcuLog -Level Warning -Message "Config: $problem" } }
    if (-not $StateInfo.IsPersistent) {
        Write-DcuLog -Level Warning -Message "State directory '$stateDir' is on the system volume: logs written while Frozen are lost at restart. Pass -StatePath pointing at a ThawSpace."
    }

    # --- 1. Window --------------------------------------------------------------------------------
    $now = Get-DcuNow
    $window = Get-DcuWindowState -Now $now -Config $Config
    $nightId = $window.NightId
    if ($IgnoreWindow -and -not $window.InWindow) {
        # Its own pass counter, so a daytime test can never mark tonight as already done.
        $nightId = 'adhoc-' + $now.ToString('yyyyMMdd-HHmmss')
    }
    $run.NightId = $nightId
    $run.Window = [ordered]@{
        Start             = $Config.WindowStart
        End               = $Config.WindowEnd
        InWindow          = $window.InWindow
        MinutesUntilClose = $window.MinutesUntilClose
        CanStartInstall   = $window.CanStartInstall
        CanReboot         = $window.CanReboot
        IgnoreWindow      = [bool]$IgnoreWindow
    }

    if ($IgnoreWindow) {
        Write-DcuLog -Level Warning -Message 'Window check bypassed (-IgnoreWindow). The freeze check still applies.'
    } elseif (-not $window.InWindow) {
        return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'OutsideWindow' -ExitCode 1 -Severity 'Info' -NoOp `
            -Message "Outside the maintenance window ($($Config.WindowStart)-$($Config.WindowEnd)); nothing to do."
    } elseif (-not $window.CanStartInstall) {
        return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'PastInstallCutoff' -ExitCode 1 -Severity 'Info' -NoOp `
            -Message "$($window.MinutesUntilClose) min of the window remain; no new pass starts within $($Config.InstallCutoffMinutes) min of the end."
    }

    # --- 2. Tonight's pass state ------------------------------------------------------------------
    $stateFile = Join-Path $stateDir 'dcu-state.json'
    $night = Read-DcuNightState -Path $stateFile -NightId $nightId
    $verifyOnly = $false
    if (-not $DryRun) {
        if ($night.InProgress) {
            $night.InProgress = $false
            $night.InterruptedPasses++
            Write-DcuLog -Level Warning -Message "Pass $($night.Passes) never recorded a result: it was interrupted (DCU restarting for a BIOS update, the task time limit, a power loss, or a Deep Freeze restart)."
            [void](Save-DcuNightState -Path $stateFile -State $night)
        }
        if ($night.Completed) {
            return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'AlreadyCompleted' -ExitCode 0 -Severity 'Info' -NoOp `
                -Message "Already finished for the night of $nightId ($($night.LastOutcome))."
        }
        if ($night.Passes -ge $Config.MaxPassesPerNight) {
            $verifyOnly = $true
            Write-DcuLog -Message "All $($Config.MaxPassesPerNight) passes used tonight; running one final scan to report what is left."
        }
    }
    $run.Pass = $night.Passes
    $run.AppliedTonight = @($night.AppliedTonight)

    # --- 3. Freeze state --------------------------------------------------------------------------
    $freeze = Get-DcuFreezeState -DfcPath $Config.DFCPath
    $run.FreezeState = $freeze.State
    $run.FreezeDetail = $freeze.Detail
    Write-DcuLog -Message "Deep Freeze state: $($freeze.State) via $($freeze.Method)"
    $mayRun = ($freeze.State -eq 'Thawed') -or ($freeze.State -eq 'NotInstalled' -and $Config.RunWithoutDeepFreeze)
    if (-not $mayRun) {
        if ($DryRun) {
            Write-DcuLog -Level Warning -Message "Machine is $($freeze.State). A real run would stop here; -DryRun continues because it installs nothing."
        } else {
            $outcome = 'SkippedFreezeStateUnknown'
            if ($freeze.State -eq 'Frozen') { $outcome = 'SkippedFrozen' }
            return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome $outcome -ExitCode 2 -Severity 'Warning' `
                -Message (Get-DcuFreezeRefusal -Freeze $freeze -Config $Config)
        }
    }

    # --- 4. DCU present, trusted, recent, service usable ------------------------------------------
    $dcu = Find-DcuCli
    if (-not $dcu) {
        return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'DcuNotInstalled' -ExitCode 4 -Severity 'Error' `
            -Message 'dcu-cli.exe was not found under Program Files. Install Dell Command | Update 5.x while Thawed.'
    }
    $run.Dcu.Path = $dcu.Path
    if ($dcu.Version) { $run.Dcu.Version = $dcu.Version.ToString() }
    if ($dcu.SignatureProblem) {
        return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'DcuUntrusted' -ExitCode 4 -Severity 'Error' -Message $dcu.SignatureProblem
    }
    if (-not $dcu.Version -or $dcu.Version -lt [version]$Config.MinimumDcuVersion) {
        return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'DcuTooOld' -ExitCode 4 -Severity 'Error' `
            -Message "DCU $($run.Dcu.Version) is older than the minimum $($Config.MinimumDcuVersion) this script is written for."
    }
    $service = Get-DcuServiceState
    if (-not $service.Installed) {
        return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'DcuServiceMissing' -ExitCode 4 -Severity 'Error' `
            -Message "$($script:DcuServiceName) is not installed; DCU 5.x cannot run without it. Reinstall DCU."
    }
    if ($service.StartType -eq 'Disabled') {
        return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'DcuServiceDisabled' -ExitCode 4 -Severity 'Error' `
            -Message "$($script:DcuServiceName) is disabled. It is left alone in case that is deliberate; set it to Automatic while Thawed to let this run."
    }
    if ($service.Status -ne 'Running') {
        Write-DcuLog -Message "$($script:DcuServiceName) is $($service.Status); starting it."
        if (-not (Start-DcuService)) { Write-DcuLog -Level Warning -Message "$($script:DcuServiceName) did not reach Running; DCU will report it if that matters." }
    }

    # --- 5. Pre-flight ----------------------------------------------------------------------------
    $free = Get-DcuFreeSpaceGB
    if ($null -ne $free -and $free -lt $Config.MinFreeSpaceGB) {
        return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'LowDiskSpace' -ExitCode 5 -Severity 'Warning' `
            -Message "Only $free GB free on $($env:SystemDrive); at least $($Config.MinFreeSpaceGB) GB is required."
    }
    if (-not $DryRun -and -not $IgnoreWindow -and $night.Passes -eq 0 -and $Config.RandomDelayMinutes -gt 0) {
        $jitter = Get-Random -Minimum 0 -Maximum ($Config.RandomDelayMinutes * 60 + 1)
        Write-DcuLog -Message "First pass tonight: waiting $jitter s so the fleet does not all download at once."
        Start-Sleep -Seconds $jitter
        $window = Get-DcuWindowState -Now (Get-DcuNow) -Config $Config
        if (-not $window.CanStartInstall) {
            return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'PastInstallCutoff' -ExitCode 1 -Severity 'Info' -NoOp `
                -Message 'The install cutoff passed during the start delay.'
        }
    }
    if (-not $DryRun) {
        $idle = Wait-DcuServicingIdle -MaxMinutes $Config.ServicingWaitMinutes
        if (-not $idle.Idle) {
            return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'SkippedServicingBusy' -ExitCode 3 -Severity 'Warning' `
                -Message "Still busy after $($Config.ServicingWaitMinutes) min ($($idle.Reasons -join '; ')) -- most likely a Windows Update install. Not starting DCU on top of it; the next trigger tries again."
        }
    }
    $run.PendingRebootBefore = @(Get-DcuPendingReboot)

    # --- 6. Count the pass BEFORE running it, so a pass killed by a restart still counts ----------
    if (-not $DryRun) {
        if (-not $verifyOnly) { $night.Passes++ }
        $night.InProgress = $true
        if (-not (Save-DcuNightState -Path $stateFile -State $night)) {
            return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'StateWriteFailed' -ExitCode 5 -Severity 'Error' `
                -Message "Could not record the pass in '$stateFile'. Not running DCU: without a pass counter a restart chain has no bound."
        }
    }
    $run.Pass = $night.Passes
    $common = @{ Run = $run; Night = $night; StateFile = $stateFile; StateDir = $stateDir }

    # --- 7. Quiet DCU settings, once a night -------------------------------------------------------
    if (-not $DryRun -and -not $verifyOnly -and -not $Config.LeaveDcuSettings -and $night.Passes -eq 1) {
        $configure = Set-DcuQuietSettings -Dcu $dcu -Tag 'p1-configure' -StateDir $stateDir
        $run.Dcu.Configure = ConvertTo-DcuResultSummary $configure
        if ($configure.Category -ne 'Success') {
            Write-DcuLog -Level Warning -Message "dcu-cli /configure returned $($configure.ExitCode) ($($configure.Meaning)). Continuing: the update filters are passed explicitly on every scan and apply."
        }
    }

    # --- 8. Scan ------------------------------------------------------------------------------------
    $tag = 'p' + $night.Passes
    if ($DryRun) { $tag = 'dryrun' } elseif ($verifyOnly) { $tag = 'verify' }
    $scan = Invoke-DcuOperation -Dcu $dcu -Command 'scan' -Options (@('-silent') + @(Get-DcuFilterOptions -Config $Config)) `
        -TimeoutMinutes $Config.ScanTimeoutMinutes -Tag "$tag-scan" -StateDir $stateDir -WithReport
    $run.Dcu.Scan = ConvertTo-DcuResultSummary $scan
    $updates = @()
    if ($scan.Category -eq 'Success') { $updates = @(Read-DcuScanReport -Path $scan.ReportPath) }
    $run.Dcu.Updates = $updates
    $updateNames = (@($updates | ForEach-Object { if ($_.PSObject.Properties['name']) { $_.name } }) | Select-Object -First 10) -join '; '

    if ($DryRun) {
        if ($scan.Category -eq 'UpToDate') {
            return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'DryRun' -ExitCode 0 -Severity 'Info' -Message 'Dry run: no applicable updates.'
        }
        if ($scan.Category -eq 'Success') {
            return Complete-DcuRun -Run $run -StateDir $stateDir -Outcome 'DryRun' -ExitCode 0 -Severity 'Info' `
                -Message ("Dry run: {0} applicable update(s). {1}" -f $updates.Count, $updateNames)
        }
        return Complete-DcuFailure @common -Result $scan -Command 'scan'
    }

    switch ($scan.Category) {
        'UpToDate' {
            $message = "Up to date after $($night.Passes) pass(es)."
            if (@($night.AppliedTonight).Count -gt 0) { $message += ' Applied tonight: ' + (@($night.AppliedTonight) -join '; ') + '.' }
            return Complete-DcuNight @common -Outcome 'UpToDate' -ExitCode 0 -Severity 'Info' -Final -Message $message
        }
        'Success' {
            if ($verifyOnly) {
                return Complete-DcuNight @common -Outcome 'MaxPassesReached' -ExitCode 3 -Severity 'Warning' -Final `
                    -Message ("{0} update(s) still applicable after {1} passes: {2}. They will be retried on the next Thawed night; check the DCU logs if the same ones keep failing." -f $updates.Count, $Config.MaxPassesPerNight, $updateNames)
            }
            Write-DcuLog -Message ("{0} applicable update(s): {1}" -f $updates.Count, $updateNames)
        }
        'RebootRequired' {
            if ($verifyOnly) {
                return Complete-DcuNight @common -Outcome 'MaxPassesReached' -ExitCode 3 -Severity 'Warning' -Final `
                    -Message "A restart is still pending after $($Config.MaxPassesPerNight) passes; not restarting again tonight."
            }
            return Invoke-DcuRebootStep @common -Config $Config -Reason "scan: $($scan.Meaning)" -IgnoreWindow:$IgnoreWindow
        }
        default { return Complete-DcuFailure @common -Result $scan -Command 'scan' }
    }

    # --- 9. Apply -----------------------------------------------------------------------------------
    # -reboot=disable: the restart is this script's decision, made against the window.
    # -autoSuspendBitLocker=enable: without it DCU skips BIOS updates on BitLocker machines. With it,
    # DCU restarts by itself after a BIOS update; the next run records that as an interrupted pass.
    $applyOptions = @('-silent', '-reboot=disable', '-autoSuspendBitLocker=enable') + @(Get-DcuFilterOptions -Config $Config)
    $apply = Invoke-DcuOperation -Dcu $dcu -Command 'applyUpdates' -Options $applyOptions `
        -TimeoutMinutes $Config.ApplyTimeoutMinutes -Tag "$tag-apply" -StateDir $stateDir
    $run.Dcu.Apply = ConvertTo-DcuResultSummary $apply
    if ($apply.Category -eq 'Success' -or $apply.Category -eq 'RebootRequired') {
        Add-DcuAppliedUpdates -Night $night -Updates $updates
        $run.AppliedTonight = @($night.AppliedTonight)
    }

    switch ($apply.Category) {
        'Success' {
            return Complete-DcuNight @common -Outcome 'Applied' -ExitCode 0 -Severity 'Info' -Final `
                -Message ("Applied {0} update(s); no restart needed. {1}" -f $updates.Count, $updateNames)
        }
        'UpToDate' {
            return Complete-DcuNight @common -Outcome 'UpToDate' -ExitCode 0 -Severity 'Info' -Final -Message 'Nothing left to apply.'
        }
        'RebootRequired' {
            return Invoke-DcuRebootStep @common -Config $Config -Reason "apply: $($apply.Meaning)" -IgnoreWindow:$IgnoreWindow
        }
        default { return Complete-DcuFailure @common -Result $apply -Command 'applyUpdates' }
    }
}

function Enter-DcuMutex {
    try { $mutex = New-Object System.Threading.Mutex($false, $script:DcuMutexName) }
    catch {
        # The task's MultipleInstances=IgnoreNew still prevents overlap; this is belt and braces.
        Write-DcuLog -Level Warning -Message "Could not create mutex '$($script:DcuMutexName)': $($_.Exception.Message)"
        return @{ Mutex = $null; Acquired = $true }
    }
    $acquired = $false
    try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        $mutex.Dispose()
        return @{ Mutex = $null; Acquired = $false }
    }
    return @{ Mutex = $mutex; Acquired = $true }
}

function Exit-DcuMutex {
    param($Handle)
    if ($Handle -and $Handle.Mutex) {
        try { $Handle.Mutex.ReleaseMutex() } catch { }
        $Handle.Mutex.Dispose()
    }
}

function Invoke-DcuRunMode {
    param([string] $ConfigPath, [switch] $DryRun, [switch] $IgnoreWindow)
    $loaded = Read-DcuInstalledConfig -Path $ConfigPath
    $config = $loaded.Config
    $state = Resolve-DcuStatePath -Config $config
    Initialize-DcuLog -StateDir $state.Path
    if ($state.Warning) { Write-DcuLog -Level Warning -Message $state.Warning }

    $lock = Enter-DcuMutex
    if (-not $lock.Acquired) {
        Write-DcuLog -Message 'Another DCU maintenance run is already in progress; exiting.'
        return 3
    }
    try {
        return Invoke-DcuRunCore -Config $config -StateInfo $state -ConfigProblems $loaded.Problems -DryRun:$DryRun -IgnoreWindow:$IgnoreWindow
    } finally {
        Exit-DcuMutex $lock
    }
}

# =================================================================================================
# Install / Uninstall / Status
# =================================================================================================

function Register-DcuTask {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] [string] $ScriptPath)

    $plan = Get-DcuSchedulePlan -Config $Config
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode Run' -f $ScriptPath
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $argument -WorkingDirectory (Split-Path -Parent $ScriptPath)

    $daily = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.Add($plan.FirstStartSpan))
    if ($plan.RepeatEveryMinutes -gt 0) {
        # A daily trigger cannot take a repetition pattern directly in 5.1; borrow one from -Once.
        $pattern = New-ScheduledTaskTrigger -Once -At ([datetime]::Today.Add($plan.FirstStartSpan)) `
            -RepetitionInterval (New-TimeSpan -Minutes $plan.RepeatEveryMinutes) `
            -RepetitionDuration (New-TimeSpan -Minutes $plan.RepeatForMinutes)
        $daily.Repetition = $pattern.Repetition
    }
    $startup = New-ScheduledTaskTrigger -AtStartup
    $startup.Delay = 'PT{0}M' -f $script:DcuStartupDelayMinutes

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # Long enough for jitter + servicing wait + scan + apply, short enough that a wedged run ends.
    $limit = New-TimeSpan -Minutes ($Config.RandomDelayMinutes + $Config.ServicingWaitMinutes + $Config.ScanTimeoutMinutes + $Config.ApplyTimeoutMinutes + 45)
    $settingsArgs = @{
        StartWhenAvailable         = $true    # machine was off at the trigger: run when it comes on (the window check decides)
        AllowStartIfOnBatteries    = $true    # carts and tablets; DCU itself enforces AC power for BIOS
        DontStopIfGoingOnBatteries = $true    # never kill an install half way
        DontStopOnIdleEnd          = $true
        MultipleInstances          = 'IgnoreNew'
        ExecutionTimeLimit         = $limit
        Compatibility              = 'Win8'
    }
    if ($Config.WakeToRun) { $settingsArgs['WakeToRun'] = $true }
    $settings = New-ScheduledTaskSettingsSet @settingsArgs

    $description = ('Dell Command | Update during the Deep Freeze maintenance window {0}-{1}, only while Thawed. ' +
                    'Installed by {2} {3}. Re-run the installer while Thawed to change it.') -f `
                    $Config.WindowStart, $Config.WindowEnd, $script:DcuScriptFileName, $script:DcuScriptVersion
    Register-ScheduledTask -TaskName $script:DcuTaskName -TaskPath '\' -Action $action -Trigger @($daily, $startup) `
        -Principal $principal -Settings $settings -Description $description -Force | Out-Null

    $registered = Get-ScheduledTask -TaskName $script:DcuTaskName -ErrorAction Stop
    return [pscustomobject]@{
        Name     = $script:DcuTaskName
        Triggers = @($registered.Triggers).Count
        Plan     = ($plan | Select-Object FirstStart, RepeatEveryMinutes, RepeatForMinutes, InstallCutoff, RebootCutoff, WindowMinutes)
        Limit    = $limit.ToString()
    }
}

function Write-DcuInstallStatus {
    param(
        [Parameter(Mandatory)] [string] $StateDir,
        [Parameter(Mandatory)] [string] $Outcome,
        [Parameter(Mandatory)] [int] $ExitCode,
        [Parameter(Mandatory)] [string] $Message,
        $Freeze, $Dcu, $Config, $Task
    )
    $record = [ordered]@{
        SchemaVersion = 1
        ScriptVersion = $script:DcuScriptVersion
        Computer      = $env:COMPUTERNAME
        Mode          = $script:DcuMode
        Timestamp     = (Get-Date).ToString('o')
        Outcome       = $Outcome
        ExitCode      = $ExitCode
        Message       = $Message
        FreezeState   = $(if ($Freeze) { $Freeze.State } else { $null })
        DcuPath       = $(if ($Dcu) { $Dcu.Path } else { $null })
        DcuVersion    = $(if ($Dcu -and $Dcu.Version) { $Dcu.Version.ToString() } else { $null })
        Task          = $Task
        Config        = $Config
    }
    try { Write-DcuJsonFile -Path (Join-Path $StateDir 'dcu-install.json') -InputObject $record } catch { }
}

function Install-DcuMaintenance {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Bound, [switch] $SkipFreezeCheck)

    Write-Host ("DFMaintenance DCU {0} -- Install on {1}" -f $script:DcuScriptVersion, $env:COMPUTERNAME)
    $built = ConvertTo-DcuConfig -Raw $Bound
    $config = $built.Config
    if (@($built.Problems).Count -gt 0) {
        foreach ($problem in $built.Problems) { Write-DcuLog -Level Error -Message "Invalid setting: $problem" }
        Write-DcuLog -Level Error -Message 'Nothing was changed. Fix the command line (or the defaults at the top of the script) and push again.'
        return 24
    }
    if (-not (Test-DcuElevated)) {
        Write-DcuLog -Level Error -Message 'Install must run elevated: as SYSTEM (the Deep Freeze Cloud "System Account" option) or as an administrator.'
        return 22
    }
    $source = $script:DcuScriptPath
    if (-not $source -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
        Write-DcuLog -Level Error -Message 'Cannot locate this script file to copy it. Run it with -File, not as pasted text or -Command.'
        return 22
    }

    # State directory first, so even a refusal is recorded somewhere that survives a restart.
    $state = Resolve-DcuStatePath -Config $config -ForInstall
    Initialize-DcuLog -StateDir $state.Path
    Write-DcuLog -Message "State directory: $($state.Path) [$($state.Source)]"
    if ($state.Warning) { Write-DcuLog -Level Warning -Message $state.Warning }
    if (-not $state.IsPersistent) {
        Write-DcuLog -Level Warning -Message "'$($state.Path)' is on the system volume, so logs written while Frozen are lost at restart. A ThawSpace (and -StatePath) is strongly recommended."
    }

    $freeze = Get-DcuFreezeState -DfcPath $config.DFCPath
    Write-DcuLog -Message "Deep Freeze state: $($freeze.State) via $($freeze.Method)"
    $freezeOk = ($freeze.State -eq 'Thawed') -or ($freeze.State -eq 'NotInstalled' -and $config.RunWithoutDeepFreeze)
    if (-not $freezeOk) {
        if ($SkipFreezeCheck) {
            Write-DcuLog -Level Warning -Message "Machine is $($freeze.State); continuing because of -SkipFreezeCheck. If it is Frozen, all of this is discarded at the next restart."
        } else {
            $why = switch ($freeze.State) {
                'Frozen' { 'This machine is FROZEN. A scheduled task created now would be discarded at the next restart, so nothing was installed. Push again while it is Thawed: during the Thawed Period, or after a Reboot Thawed from the console.' }
                'NotInstalled' { 'Deep Freeze was not detected. If these machines really are unprotected, push again with -RunWithoutDeepFreeze.' }
                default { "Could not confirm the machine is Thawed ($($freeze.Detail)). Nothing was installed. Pass -DFCPath if DFC.exe is somewhere unusual, or -SkipFreezeCheck if you are sure it is Thawed." }
            }
            Write-DcuLog -Level Error -Message $why
            Write-DcuInstallStatus -StateDir $state.Path -Outcome 'RefusedNotThawed' -ExitCode 20 -Message $why -Freeze $freeze -Config $config
            Write-DcuEvent -EventId 2020 -Severity 'Error' -Message $why
            return 20
        }
    }

    $dcu = Find-DcuCli
    $dcuProblem = $null
    $service = Get-DcuServiceState
    if (-not $dcu) { $dcuProblem = 'Dell Command | Update (dcu-cli.exe) was not found under Program Files. Install DCU 5.x first, while Thawed, then push this again.' }
    elseif ($dcu.SignatureProblem) { $dcuProblem = $dcu.SignatureProblem }
    elseif (-not $dcu.Version -or $dcu.Version -lt [version]$config.MinimumDcuVersion) { $dcuProblem = "DCU at $($dcu.Path) is version $($dcu.Version); $($config.MinimumDcuVersion) or later is required." }
    elseif (-not $service.Installed) { $dcuProblem = "$($script:DcuServiceName) is not installed; DCU 5.x cannot run without it. Reinstall DCU." }
    elseif ($service.StartType -eq 'Disabled') { $dcuProblem = "$($script:DcuServiceName) is disabled. Set it to Automatic (while Thawed) and push again." }
    if ($dcuProblem) {
        Write-DcuLog -Level Error -Message $dcuProblem
        Write-DcuInstallStatus -StateDir $state.Path -Outcome 'DcuUnavailable' -ExitCode 21 -Message $dcuProblem -Freeze $freeze -Dcu $dcu -Config $config
        Write-DcuEvent -EventId 2021 -Severity 'Error' -Message $dcuProblem
        return 21
    }
    Write-DcuLog -Message "DCU: $($dcu.Path) version $($dcu.Version), signature $($dcu.Signature)"

    $installDir = Get-DcuInstallDir
    $destination = Join-Path $installDir $script:DcuScriptFileName
    try {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        if (-not (Test-DcuSamePath $source $destination)) { Copy-Item -LiteralPath $source -Destination $destination -Force }
        try { Unblock-File -LiteralPath $destination -ErrorAction Stop } catch { }
        if (-not (Test-DcuTrustedPath -Path $destination -ExpectedLeaf $script:DcuScriptFileName)) {
            throw "Install location '$destination' is not under Program Files."
        }
        foreach ($dir in @((Get-DcuWorkDir 'logs'), (Get-DcuWorkDir 'work'))) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $workSecured = Set-DcuDirectorySecurity -Path (Get-DcuWorkDir)
        $stateSecured = Set-DcuDirectorySecurity -Path $state.Path

        $config.PinnedStatePath = $state.Path
        $config.PinnedVolumeSerial = $state.VolumeSerial
        $config.InstalledAt = (Get-Date).ToString('o')
        $config.InstalledVersion = $script:DcuScriptVersion
        Write-DcuJsonFile -Path (Join-Path $installDir 'config.json') -InputObject $config
    } catch {
        $message = "Could not install files to '$installDir': $($_.Exception.Message)"
        Write-DcuLog -Level Error -Message $message
        Write-DcuInstallStatus -StateDir $state.Path -Outcome 'InstallFailed' -ExitCode 23 -Message $message -Freeze $freeze -Dcu $dcu -Config $config
        return 23
    }
    if (-not $workSecured -or -not $stateSecured) {
        Write-DcuLog -Level Warning -Message 'Could not restrict one of the directories to SYSTEM/Administrators (see above). Fix it by hand before relying on this machine.'
    }

    Register-DcuEventSource

    $configureNote = 'left alone (-LeaveDcuSettings)'
    if (-not $config.LeaveDcuSettings) {
        $configure = Set-DcuQuietSettings -Dcu $dcu -Tag 'install-configure' -StateDir $state.Path
        if ($configure.Category -eq 'Success') { $configureNote = 'own schedule set to manual, notifications off, BitLocker auto-suspend on' }
        else {
            $configureNote = "dcu-cli /configure returned $($configure.ExitCode) ($($configure.Meaning)); each night's first pass tries again"
            Write-DcuLog -Level Warning -Message "DCU settings: $configureNote"
        }
    }

    try {
        $task = Register-DcuTask -Config $config -ScriptPath $destination
    } catch {
        $message = "Could not register the scheduled task: $($_.Exception.Message)"
        Write-DcuLog -Level Error -Message $message
        Write-DcuInstallStatus -StateDir $state.Path -Outcome 'InstallFailed' -ExitCode 23 -Message $message -Freeze $freeze -Dcu $dcu -Config $config
        return 23
    }

    $plan = $task.Plan
    $repeat = 'no repeats'
    if ($plan.RepeatEveryMinutes -gt 0) { $repeat = "repeating every $($plan.RepeatEveryMinutes) min until $($plan.InstallCutoff)" }
    $persistence = 'NOT persistent -- lost at each Frozen restart'
    if ($state.IsPersistent) { $persistence = 'persistent' }
    $lines = @(
        ''
        "  Task      : \$($task.Name) as SYSTEM -- daily $($plan.FirstStart), $repeat; and at startup +$($script:DcuStartupDelayMinutes) min"
        "  Window    : $($config.WindowStart)-$($config.WindowEnd); no new pass after $($plan.InstallCutoff), no restart after $($plan.RebootCutoff), up to $($config.MaxPassesPerNight) passes a night"
        "  Updates   : $(@($config.UpdateType) -join ',') / $(@($config.UpdateSeverity) -join ',')$(if (@($config.UpdateDeviceCategory).Count) { ' / ' + (@($config.UpdateDeviceCategory) -join ',') })"
        "  DCU       : $($dcu.Path) $($dcu.Version) -- $configureNote"
        "  Logs      : $($state.Path) ($persistence)"
        "  Installed : $destination"
        "  Freeze    : $($freeze.State). Let the Thawed Period end (or Reboot Frozen) so the task becomes part of the Frozen baseline."
        ''
    )
    foreach ($line in $lines) { Write-Host $line }
    $summary = "Installed. Task \$($task.Name): daily $($plan.FirstStart) ($repeat) and at startup; window $($config.WindowStart)-$($config.WindowEnd)."
    Write-DcuLog -Message $summary
    Write-DcuInstallStatus -StateDir $state.Path -Outcome 'Installed' -ExitCode 0 -Message $summary -Freeze $freeze -Dcu $dcu -Config $config -Task $task
    Write-DcuEvent -EventId 2000 -Severity 'Info' -Message $summary
    return 0
}

function Uninstall-DcuMaintenance {
    param([string] $ConfigPath, [switch] $SkipFreezeCheck)
    if (-not (Test-DcuElevated)) {
        Write-DcuLog -Level Error -Message 'Uninstall must run elevated (as SYSTEM or an administrator).'
        return 22
    }
    $loaded = Read-DcuInstalledConfig -Path $ConfigPath
    $config = $loaded.Config
    $state = Resolve-DcuStatePath -Config $config
    Initialize-DcuLog -StateDir $state.Path

    $freeze = Get-DcuFreezeState -DfcPath $config.DFCPath
    if (($freeze.State -eq 'Frozen' -or $freeze.State -eq 'Unknown') -and -not $SkipFreezeCheck) {
        $why = "Machine is $($freeze.State): removing the task now would be undone at the next restart. Nothing was removed; uninstall while Thawed."
        Write-DcuLog -Level Error -Message $why
        return 20
    }

    $failures = 0
    try {
        if (Get-ScheduledTask -TaskName $script:DcuTaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $script:DcuTaskName -Confirm:$false -ErrorAction Stop
            Write-DcuLog -Message "Removed scheduled task \$($script:DcuTaskName)."
        } else {
            Write-DcuLog -Message "Scheduled task \$($script:DcuTaskName) was not registered."
        }
    } catch {
        $failures++
        Write-DcuLog -Level Error -Message "Could not remove the scheduled task: $($_.Exception.Message)"
    }
    foreach ($dir in @((Get-DcuInstallDir), (Get-DcuWorkDir))) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        try {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
            Write-DcuLog -Message "Removed $dir."
        } catch {
            $failures++
            Write-DcuLog -Level Error -Message "Could not remove '$dir': $($_.Exception.Message)"
        }
    }
    Write-DcuLog -Message "Logs and status were kept in $($state.Path). DCU's own schedule stays on manual; to hand scheduling back to DCU, run: dcu-cli.exe /configure -scheduleAuto"
    if ($failures -gt 0) { return 23 }
    return 0
}

function Show-DcuStatus {
    param([string] $ConfigPath)
    $loaded = Read-DcuInstalledConfig -Path $ConfigPath
    $config = $loaded.Config
    $state = Resolve-DcuStatePath -Config $config -NoCreate
    $plan = Get-DcuSchedulePlan -Config $config

    $configNote = ''
    if (-not $loaded.Found) { $configNote = ' (not found -- showing defaults)' }
    $persistence = 'NOT persistent'
    if ($state.IsPersistent) { $persistence = 'persistent' }
    Write-Host ("Config     : {0}{1}" -f $loaded.Path, $configNote)
    Write-Host ("Window     : {0}-{1}; no new pass after {2}, no restart after {3}" -f $config.WindowStart, $config.WindowEnd, $plan.InstallCutoff, $plan.RebootCutoff)
    Write-Host ("State/logs : {0} ({1})" -f $state.Path, $persistence)

    $freeze = Get-DcuFreezeState -DfcPath $config.DFCPath
    Write-Host ("Freeze     : {0} {1}" -f $freeze.State, $(if ($freeze.Detail) { "($($freeze.Detail))" }))
    $dcu = Find-DcuCli
    if ($dcu) { Write-Host ("DCU        : {0} {1}" -f $dcu.Path, $dcu.Version) } else { Write-Host 'DCU        : not found' }
    try {
        $task = Get-ScheduledTask -TaskName $script:DcuTaskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop
        Write-Host ("Task       : {0}; last run {1} (result {2}); next run {3}" -f $task.State, $info.LastRunTime, $info.LastTaskResult, $info.NextRunTime)
    } catch {
        Write-Host 'Task       : not registered (or not readable without elevation)'
    }
    foreach ($name in @('dcu-status.json', 'dcu-state.json', 'dcu-install.json')) {
        $path = Join-Path $state.Path $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Write-Host ''
            Write-Host "--- $name"
            Write-Host (Get-Content -LiteralPath $path -Raw)
        }
    }
    return 0
}

# =================================================================================================
# Entry point
# =================================================================================================

function Invoke-DcuNativeRelaunch {
    <#
        A 32-bit host -- some management agents launch 32-bit PowerShell, as Intune's does -- sees
        Program Files (x86) as $env:ProgramFiles and a redirected System32 and registry. Re-run in
        64-bit PowerShell before touching anything. Returns the child's exit code, or $null when no
        relaunch was needed.
    #>
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Bound)
    if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::Is64BitProcess) { return $null }
    if (-not $env:SystemRoot -or -not $script:DcuScriptPath) { return $null }
    $native = Join-Path $env:SystemRoot 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $native)) { return $null }

    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:DcuScriptPath) +
                 @(ConvertTo-DcuRelaunchArguments -Bound $Bound)
    Write-Host "INFO  32-bit PowerShell on 64-bit Windows: relaunching in $native"
    & $native @arguments
    return $LASTEXITCODE
}

function ConvertTo-DcuRelaunchArguments {
    # Bound parameters back into -File arguments. Arrays travel as one comma-joined value (which
    # ConvertTo-DcuList splits again), switches only when present, and empty values not at all:
    # Windows PowerShell 5.1 drops an empty native argument, which would shift every one after it.
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Bound)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($Bound.Keys)) {
        $value = $Bound[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $list.Add("-$key") }
            continue
        }
        if ($null -eq $value) { continue }
        $text = (@($value) | ForEach-Object { [string]$_ }) -join ','
        if ($text -eq '') { continue }
        $list.Add("-$key")
        $list.Add($text)
    }
    return $list.ToArray()
}

function Invoke-DcuMain {
    param(
        [Parameter(Mandatory)] [string] $Mode,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Bound,
        [switch] $SkipFreezeCheck,
        [switch] $DryRun,
        [switch] $IgnoreWindow,
        [string] $ConfigPath
    )
    $relaunched = Invoke-DcuNativeRelaunch -Bound $Bound
    if ($null -ne $relaunched) { return [int]$relaunched }

    $failureCode = 29
    if ($Mode -eq 'Run') { $failureCode = 9 }
    try {
        switch ($Mode) {
            'Install'   { return [int](Install-DcuMaintenance -Bound $Bound -SkipFreezeCheck:$SkipFreezeCheck) }
            'Run'       { return [int](Invoke-DcuRunMode -ConfigPath $ConfigPath -DryRun:$DryRun -IgnoreWindow:$IgnoreWindow) }
            'Status'    { return [int](Show-DcuStatus -ConfigPath $ConfigPath) }
            'Uninstall' { return [int](Uninstall-DcuMaintenance -ConfigPath $ConfigPath -SkipFreezeCheck:$SkipFreezeCheck) }
        }
    } catch {
        Write-DcuLog -Level Error -Message ("Unexpected error in {0} mode: {1}" -f $Mode, $_.Exception.Message) `
            -Data ([ordered]@{ At = [string]$_.InvocationInfo.PositionMessage; Stack = [string]$_.ScriptStackTrace })
        return $failureCode
    }
    return $failureCode
}

# Dot-sourcing (the tests) defines the functions without running anything.
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = Invoke-DcuMain -Mode $Mode -Bound $PSBoundParameters -SkipFreezeCheck:$SkipFreezeCheck `
        -DryRun:$DryRun -IgnoreWindow:$IgnoreWindow -ConfigPath $ConfigPath
    exit $exitCode
}
