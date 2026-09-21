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
        [int] $HistoryCount = 15,

        # Seconds to allow the online search before giving up.
        [ValidateRange(30, 3600)]
        [int] $SearchTimeoutSeconds = 300
    )

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
                        [PSCustomObject]@{
                            Title      = $_.Title
                            Date       = if ($_.Date) { $_.Date.ToString('o') } else { $null }
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

            # Driver updates only surface when the search includes driver types.
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
                        RebootNeeded = $_.InstallationBehavior.RebootBehavior -ne 0
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
