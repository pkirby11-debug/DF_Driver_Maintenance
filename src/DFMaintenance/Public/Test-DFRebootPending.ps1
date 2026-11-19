function Test-DFRebootPending {
    <#
    .SYNOPSIS
        Determines whether Windows is holding a pending reboot.

    .DESCRIPTION
        Checks the standard pending-reboot indicators. This matters more under
        Deep Freeze than on a normal machine: a pending reboot that is satisfied
        by a *Frozen* reboot discards the work that created it, so a machine can
        sit in a loop of installing the same update forever and never report an
        error. Detecting the pending flag before refreezing is what breaks that
        loop.

    .OUTPUTS
        PSCustomObject with IsPending and the list of reasons.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $reasons = [System.Collections.Generic.List[string]]::new()

    $keyChecks = @{
        'Component Based Servicing' = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'Windows Update'            = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        'Post Reboot Reporting'     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PostRebootReporting'
    }

    foreach ($check in $keyChecks.GetEnumerator()) {
        if (Test-Path -LiteralPath $check.Value -ErrorAction SilentlyContinue) {
            $reasons.Add($check.Key)
        }
    }

    $pendingRename = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
        -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pendingRename) { $reasons.Add('Pending file rename operations') }

    $computerName = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' `
        -Name 'ComputerName' -ErrorAction SilentlyContinue
    $pendingName = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
        -Name 'ComputerName' -ErrorAction SilentlyContinue
    if ($computerName -and $pendingName -and $computerName.ComputerName -ne $pendingName.ComputerName) {
        $reasons.Add('Pending computer rename')
    }

    return [PSCustomObject]@{
        IsPending = ($reasons.Count -gt 0)
        Reasons   = $reasons.ToArray()
    }
}
