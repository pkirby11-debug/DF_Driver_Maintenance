function Get-DFComplianceSnapshot {
    <#
    .SYNOPSIS
        Produces a single maintenance-compliance snapshot for this machine.

    .DESCRIPTION
        Combines freeze state, Windows Update posture, driver inventory and
        software inventory into one record, then evaluates a small set of
        findings against it.

        The findings are the point of the whole exercise. On an isolated,
        public-facing VLAN nobody is watching these machines interactively, so
        the questions that matter are the ones a human would never think to ask:

          - Did this machine come back Frozen after its last maintenance window?
          - Is it stuck in a reboot-pending loop that a Frozen reboot silently discards?
          - Has it actually succeeded at installing anything recently?
          - Is a device sitting in a driver error state that nobody has reported?

        Severity is deliberately coarse (Critical / Warning / Info) because the
        output is meant to be triaged at a glance across a room of machines.

    .OUTPUTS
        PSCustomObject containing the full snapshot plus a Findings collection.

    .EXAMPLE
        Get-DFComplianceSnapshot -SkipOnlineSearch

    .EXAMPLE
        (Get-DFComplianceSnapshot).Findings | Where-Object Severity -eq 'Critical'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch] $SkipOnlineSearch,

        [string] $ConfigPath,

        [string] $StatePath,

        # Consider maintenance overdue if nothing installed successfully in this many days.
        [ValidateRange(1, 365)]
        [int] $MaintenanceOverdueDays = 45
    )

    $config = Get-DFConfig -ConfigPath $ConfigPath

    # Resolve the state path the same way Export does, so logs from this scan land on the
    # same volume as its report rather than on the frozen volume.
    $effectiveStatePath = if ($StatePath) { $StatePath } else { $config.StatePath }
    $state = Set-DFStateContext -StatePath $effectiveStatePath `
                                -ThawSpaceLabelPattern $config.ThawSpaceLabelPattern

    Write-DFLog -Component 'Compliance' -Message 'Starting compliance snapshot.'

    # -StaleAfterDays carries [ValidateRange(0,10000)]; binding an out-of-range config
    # value would throw and abort the whole scan. Clamp first.
    $driverAgeDays = 1095
    if ($config.DriverAgeWarningDays -is [int] -and
        $config.DriverAgeWarningDays -ge 0 -and $config.DriverAgeWarningDays -le 10000) {
        $driverAgeDays = $config.DriverAgeWarningDays
    }

    $freeze   = Get-DFFreezeState -DFCPath $config.DFCPath
    $updates  = Get-DFWindowsUpdateStatus -SkipOnlineSearch:$SkipOnlineSearch
    $drivers  = Get-DFDriverInventory -StaleAfterDays $driverAgeDays
    $software = Get-DFSoftwareInventory -TrackedSoftware $config.TrackedSoftware

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    function Add-Finding {
        param($Severity, $Code, $Message)
        $findings.Add([PSCustomObject]@{
            Severity = $Severity
            Code     = $Code
            Message  = $Message
        })
    }

    # --- Freeze state -------------------------------------------------------
    # A public-facing machine left Thawed has lost the protection it exists for.
    # This is the single most important finding the tool produces.
    if ($freeze.State -eq 'Thawed') {
        Add-Finding 'Critical' 'DF001' 'Machine is THAWED. Deep Freeze protection is not active on a public-facing device.'
    } elseif ($freeze.State -eq 'Unknown') {
        Add-Finding 'Warning' 'DF002' "Freeze state could not be determined ($($freeze.Detail)). Treat as unverified."
    }
    if (-not $freeze.DeepFreezeInstalled) {
        Add-Finding 'Critical' 'DF003' 'Deep Freeze client not detected on this machine.'
    }

    # --- State durability ---------------------------------------------------
    # A Write-Warning is invisible under Task Scheduler as SYSTEM, so a machine with no
    # ThawSpace would otherwise scan clean, report Healthy, and have the whole report
    # destroyed on the next Frozen reboot -- nightly, forever, with nothing to show for it.
    if (-not $state.IsPersistent) {
        Add-Finding 'Critical' 'DF004' "State path '$($state.Path)' is not persistent ($($state.Source)); this report will be discarded on the next Frozen reboot."
    }

    # --- Reboot loop --------------------------------------------------------
    # Pending reboot + Frozen means the pending work will be discarded, not applied.
    if ($updates.RebootPending.IsPending -and $freeze.State -eq 'Frozen') {
        Add-Finding 'Warning' 'WU001' ("Reboot pending while Frozen ({0}); the pending work will be discarded on reboot, not applied." -f ($updates.RebootPending.Reasons -join ', '))
    }

    # --- Update posture -----------------------------------------------------
    if ($updates.SearchPerformed) {
        if ($updates.PendingCritical -gt 0) {
            Add-Finding 'Critical' 'WU002' "$($updates.PendingCritical) critical/important update(s) pending."
        } elseif ($updates.PendingCount -gt 0) {
            Add-Finding 'Info' 'WU003' "$($updates.PendingCount) update(s) pending."
        }
    }
    if ($updates.SearchError) {
        Add-Finding 'Warning' 'WU004' "Windows Update query failed: $($updates.SearchError)"
    }

    # Operation must be an INSTALL. A successful *uninstallation* (a rolled-back update)
    # otherwise satisfies "last successful install" and suppresses WU005/WU006 on exactly
    # the machine that most needs them.
    # History dates are tagged UTC at the source, so compare against UtcNow -- comparing a
    # UTC timestamp against local Get-Date skewed this by the site's offset.
    $lastSuccess = $updates.History |
        Where-Object { $_.Succeeded -and $_.Date -and $_.IsInstall } |
        Sort-Object { [datetime]$_.Date } -Descending |
        Select-Object -First 1

    if ($lastSuccess) {
        $daysSince = [math]::Round(((Get-Date).ToUniversalTime() - ([datetime]$lastSuccess.Date).ToUniversalTime()).TotalDays)
        if ($daysSince -gt $MaintenanceOverdueDays) {
            Add-Finding 'Critical' 'WU005' "No successful update install in $daysSince days. Maintenance window is not doing its job."
        }
    } else {
        Add-Finding 'Warning' 'WU006' 'No successful update install found in the recorded history.'
    }

    # --- Drivers ------------------------------------------------------------
    if ($drivers.ProblemCount -gt 0) {
        Add-Finding 'Warning' 'DRV001' "$($drivers.ProblemCount) device(s) in an error state: $(($drivers.ProblemDevices | Select-Object -First 3 -ExpandProperty Name) -join '; ')"
    }
    if ($drivers.StaleCount -gt 0) {
        Add-Finding 'Info' 'DRV002' "$($drivers.StaleCount) third-party driver(s) older than $driverAgeDays days."
    }
    # Both inventories swallow their exceptions into an Error property and leave every
    # count at 0. Without these checks a machine whose entire driver inventory failed --
    # the thing this project exists to collect -- reports Healthy with exit code 0.
    if ($drivers.Error) {
        Add-Finding 'Warning' 'DRV003' "Driver inventory failed: $($drivers.Error)"
    }
    if ($software.Error) {
        Add-Finding 'Warning' 'SW001' "Software inventory failed: $($software.Error)"
    }

    $severityRank = @{ 'Critical' = 3; 'Warning' = 2; 'Info' = 1 }
    $worst = ($findings | ForEach-Object { $severityRank[$_.Severity] } | Measure-Object -Maximum).Maximum
    $overall = switch ($worst) {
        3       { 'Critical' }
        2       { 'Warning' }
        1       { 'Info' }
        default { 'Healthy' }
    }

    Write-DFLog -Component 'Compliance' -Message "Snapshot complete. Overall: $overall, $($findings.Count) finding(s)." `
        -Data @{ Overall = $overall; FindingCount = $findings.Count }

    return [PSCustomObject]@{
        Computer       = $env:COMPUTERNAME
        Timestamp      = (Get-Date).ToString('o')
        SchemaVersion  = 2
        OverallStatus  = $overall
        StatePath      = $state.Path
        StateSource    = $state.Source
        IsPersistent   = $state.IsPersistent
        Findings       = $findings.ToArray()
        FreezeState    = $freeze
        WindowsUpdate  = $updates
        Drivers        = $drivers
        Software       = $software
    }
}
