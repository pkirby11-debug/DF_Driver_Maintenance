function Initialize-DFMaintenance {
    <#
    .SYNOPSIS
        Prepares a machine for DFMaintenance: state directory, config file and scan schedule.

    .DESCRIPTION
        Run this once per machine while the machine is THAWED. Everything this
        function creates lands on the persistent volume precisely so that it
        survives the refreeze; if it is run while Frozen the setup is discarded
        on the next reboot and the function warns about exactly that.

        The scheduled task is registered against the frozen volume's task store,
        which means it must be created during the same Thawed window in which
        the baseline is captured. That is a Deep Freeze constraint, not a design
        choice: scheduled tasks are part of the image, so they have to be baked
        into the frozen baseline.

    .EXAMPLE
        Initialize-DFMaintenance -Verbose

    .EXAMPLE
        Initialize-DFMaintenance -StatePath 'T:\DFMaintenance' -RegisterScheduledTask -ScanTime '03:30'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [string] $StatePath,

        # Register the daily compliance scan as a scheduled task.
        [switch] $RegisterScheduledTask,

        # Local time of day for the daily scan, HH:mm.
        [ValidatePattern('^\d{2}:\d{2}$')]
        [string] $ScanTime = '03:00',

        # Overwrite an existing config file.
        [switch] $Force,

        # Explicit path to Invoke-DFComplianceScan.ps1. Needed whenever the module is
        # deployed somewhere other than an intact copy of the repository tree.
        [string] $ScanScriptPath
    )

    $state = Set-DFStateContext -StatePath $StatePath
    Write-Verbose "State directory: $($state.Path) [$($state.Source)]"

    if (-not $state.IsPersistent) {
        Write-Warning @"
State path '$($state.Path)' is on the system volume and will NOT survive a Frozen reboot.
Configure a Deep Freeze ThawSpace volume and re-run with -StatePath pointing at it,
otherwise every scan result is discarded on the next reboot.
"@
    }

    $freeze = Get-DFFreezeState
    if ($freeze.State -eq 'Frozen') {
        Write-Warning 'This machine is currently FROZEN. Setup performed now will be discarded on the next reboot. Thaw the machine, re-run setup, then refreeze.'
    }

    foreach ($sub in 'reports', 'logs') {
        New-Item -Path (Join-Path $state.Path $sub) -ItemType Directory -Force | Out-Null
    }

    # The config file written below carries DFCPath, which the nightly scan executes as
    # SYSTEM. A directory created with inherited defaults at a volume root is often
    # writable by authenticated users, so lock it down before the config lands in it.
    $secured = Set-DFDirectorySecurity -Path $state.Path
    if (-not $secured) {
        Write-Warning "State directory '$($state.Path)' could not be secured automatically. Restrict it to SYSTEM and Administrators before relying on this deployment."
    }

    $configPath = Join-Path $state.Path 'dfmaintenance.json'
    if ((Test-Path -LiteralPath $configPath) -and -not $Force) {
        Write-Verbose "Config already present at $configPath (use -Force to overwrite)."
    } elseif ($PSCmdlet.ShouldProcess($configPath, 'Write default configuration')) {
        $defaultConfig = [ordered]@{
            StatePath             = $state.Path
            ThawSpaceLabelPattern = 'ThawSpace*'
            DFCPath               = (Get-DFCPath)
            LogRetentionDays      = 90
            DriverAgeWarningDays  = 1095
            TrackedSoftware       = @()
        } | ConvertTo-Json -Depth 4
        # BOM-free: Set-Content -Encoding UTF8 would prefix a BOM on 5.1.
        Write-DFTextFile -Path $configPath -Content $defaultConfig
        Write-Verbose "Wrote default config to $configPath"
    }

    $taskRegistered = $false
    if ($RegisterScheduledTask -and $PSCmdlet.ShouldProcess('DFMaintenance-ComplianceScan', 'Register scheduled task')) {
        if ($ScanScriptPath) {
            $scanScript = $ScanScriptPath
        } else {
            # $PSScriptRoot here is src/DFMaintenance/Public, so three '..' reach the repo
            # root. That arithmetic is correct, but it only holds while the module sits in
            # an intact repository tree -- which is not how this gets deployed to a kiosk.
            $scanScript = Join-Path $PSScriptRoot '..\..\..\scripts\Invoke-DFComplianceScan.ps1'
        }
        $scanScript = [System.IO.Path]::GetFullPath($scanScript)

        # Registering a task that points at a non-existent script produces a task that
        # fails silently every night while this function reports TaskRegistered = $true.
        if (-not (Test-Path -LiteralPath $scanScript)) {
            Write-Warning "Scan script not found at '$scanScript'. Task NOT registered. Pass -ScanScriptPath, or deploy scripts\Invoke-DFComplianceScan.ps1 alongside the module."
            return [PSCustomObject]@{
                StatePath      = $state.Path
                StateSource    = $state.Source
                IsPersistent   = $state.IsPersistent
                ConfigPath     = $configPath
                FreezeState    = $freeze.State
                TaskRegistered = $false
                ScanScriptPath = $scanScript
            }
        }

        try {
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scanScript`" -StatePath `"$($state.Path)`""
            $trigger = New-ScheduledTaskTrigger -Daily -At $ScanTime
            # SYSTEM because a classroom machine has no logged-on admin at 03:00.
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd `
                -ExecutionTimeLimit (New-TimeSpan -Hours 2)

            Register-ScheduledTask -TaskName 'DFMaintenance-ComplianceScan' `
                -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
                -Description 'Daily Deep Freeze maintenance compliance scan.' -Force | Out-Null

            $taskRegistered = $true
            Write-Verbose "Registered scheduled task for $ScanTime daily."
        } catch {
            Write-Warning "Could not register scheduled task: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{
        StatePath      = $state.Path
        StateSource    = $state.Source
        IsPersistent   = $state.IsPersistent
        ConfigPath     = $configPath
        FreezeState    = $freeze.State
        TaskRegistered = $taskRegistered
        DirectorySecured = $secured
    }
}
