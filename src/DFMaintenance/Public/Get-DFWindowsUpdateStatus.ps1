function Get-DFWindowsUpdateStatus {
    <#
    .SYNOPSIS
        Reports Windows Update posture: OS build, pending updates, and recent install history.

    .DESCRIPTION
        Uses the Windows Update Agent COM API (Microsoft.Update.Session) directly
        rather than a module such as PSWindowsUpdate.

        That is a deliberate constraint of the Deep Freeze environment: an
        installed module lives on the frozen volume and is discarded on the next
        Frozen reboot, so any dependency installed at runtime is gone by the time
        the next maintenance cycle runs. The COM API is part of Windows and is
        always present.

        The online search requires network access and can take 30-120 seconds.
        Use -SkipOnlineSearch for a fast, purely local snapshot.

    .OUTPUTS
        PSCustomObject describing OS build, pending update counts and history.

    .EXAMPLE
        Get-DFWindowsUpdateStatus -SkipOnlineSearch

    .EXAMPLE
        Get-DFWindowsUpdateStatus -HistoryCount 25
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        # Skip the network round trip and report only locally known state.
        [switch] $SkipOnlineSearch,

        # How many past update-history entries to return.
        [ValidateRange(0, 200)]
        [int] $HistoryCount = 15
    )

    # NOTE ON TIMEOUTS
    # This function previously declared a -SearchTimeoutSeconds parameter that was never
    # read by anything -- a promise to the operator that the code did not keep.
    # IUpdateSearcher.Search() is a synchronous, blocking COM call with no timeout argument,
    # so honouring such a parameter requires the asynchronous BeginSearch/RequestAbort path.
    # Rather than keep an inert knob, the parameter is removed: the real bound on this call
    # is the scheduled task's ExecutionTimeLimit (2 hours as registered by
    # Initialize-DFMaintenance). See docs/VALIDATION.md.

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue

    $status = [ordered]@{
        Computer          = $env:COMPUTERNAME
        Timestamp         = (Get-Date).ToString('o')
        OSCaption         = $os.Caption
        OSVersion         = $os.Version
        OSBuild           = $os.BuildNumber
        DisplayVersion    = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion' -ErrorAction SilentlyContinue).DisplayVersion
        LastBootTime      = if ($os.LastBootUpTime) { $os.LastBootUpTime.ToString('o') } else { $null }
        UptimeDays        = if ($os.LastBootUpTime) { [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2) } else { $null }
        RebootPending     = Test-DFRebootPending
        SearchPerformed   = $false
        SearchError       = $null
        PendingCount      = $null
        PendingCritical   = $null
        PendingDriver     = $null
        PendingUpdates    = @()
        History           = @()
    }

    try {
        $session  = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()

        if ($HistoryCount -gt 0) {
            $total = $searcher.GetTotalHistoryCount()
            if ($total -gt 0) {
                $take = [math]::Min($HistoryCount, $total)
                $status.History = @(
                    $searcher.QueryHistory(0, $take) | ForEach-Object {
                        # IUpdateHistoryEntry.Date is UTC, but COM marshals it with
                        # DateTimeKind.Unspecified. Tagging it explicitly keeps the
                        # 'days since last successful install' maths from drifting by the
                        # machine's UTC offset, which on a -06:00 site silently shifts
                        # every comparison by a quarter of a day.
                        $utcDate = $null
                        if ($_.Date) {
                            $utcDate = [datetime]::SpecifyKind($_.Date, [DateTimeKind]::Utc)
                        }
                        [PSCustomObject]@{
                            Title      = $_.Title
                            Date       = if ($utcDate) { $utcDate.ToString('o') } else { $null }
                            # UpdateOperation: 1 = Installation, 2 = Uninstallation.
                            # A successful UNINSTALL must not count as a successful install,
                            # or a machine whose only recent history is a rolled-back update
                            # looks freshly patched.
                            Operation   = $_.Operation
                            IsInstall   = ($_.Operation -eq 1)
                            # ResultCode 2 = Succeeded, 3 = Succeeded with errors, 4 = Failed
                            ResultCode = $_.ResultCode
                            Succeeded  = ($_.ResultCode -in 2, 3)
                            HResult    = $_.HResult
                        }
                    }
                )
            }
        }

        if (-not $SkipOnlineSearch) {
            Write-DFLog -Component 'WindowsUpdate' -Message 'Starting online update search.'

            # This criteria returns SOFTWARE updates. The WUA default ServerSelection does
            # not reliably return driver updates -- those generally require the Microsoft
            # Update service and an explicit Type='Driver' search. PendingDriver below is
            # therefore a best-effort count of whatever drivers this search happens to
            # return, and may legitimately be 0 on a machine with pending driver updates.
            # docs/VALIDATION.md carries a step to confirm the real behaviour on an
            # endpoint before anyone relies on this number.
            $criteria = "IsInstalled=0 and IsHidden=0"
            $searchResult = $searcher.Search($criteria)

            $status.SearchPerformed = $true
            $pending = @($searchResult.Updates)

            $status.PendingCount    = $pending.Count
            $status.PendingCritical = @($pending | Where-Object { $_.MsrcSeverity -in 'Critical', 'Important' }).Count
            $status.PendingDriver   = @($pending | Where-Object { $_.Type -eq 2 }).Count  # 2 = Driver

            $status.PendingUpdates = @(
                $pending | ForEach-Object {
                    [PSCustomObject]@{
                        Title        = $_.Title
                        KB           = @($_.KBArticleIDs) -join ','
                        Severity     = $_.MsrcSeverity
                        IsDriver     = ($_.Type -eq 2)
                        SizeMB       = [math]::Round($_.MaxDownloadSize / 1MB, 2)
                        # IUpdate::get_InstallationBehavior can return a null pointer even
                        # on success -- the documented case for BUNDLES, which is what
                        # Windows 10/11 cumulative updates are. Dereferencing null yields
                        # $null -ne 0 -> $true, so every bundled update was reported as
                        # requiring a reboot. Keep 'unknown' as $null rather than guessing.
                        RebootNeeded = $(
                            $ib = $_.InstallationBehavior
                            if ($null -eq $ib) { $null } else { $ib.RebootBehavior -ne 0 }
                        )
                    }
                }
            )

            Write-DFLog -Component 'WindowsUpdate' -Message "Search complete: $($status.PendingCount) pending." `
                -Data @{ Pending = $status.PendingCount; Critical = $status.PendingCritical }
        }
    } catch {
        $status.SearchError = $_.Exception.Message
        Write-DFLog -Level 'Error' -Component 'WindowsUpdate' `
            -Message "Windows Update query failed: $($_.Exception.Message)"
    }

    return [PSCustomObject]$status
}
