function Get-DFFreezeState {
    <#
    .SYNOPSIS
        Reports whether Deep Freeze currently has this machine Frozen or Thawed.

    .DESCRIPTION
        Primary probe is DFC.exe /ISFROZEN.

        NOTE THE INVERTED EXIT CODE: Deep Freeze returns exit code 1 when the
        machine is FROZEN and 0 when it is THAWED. That is the opposite of the
        usual "0 means success" convention and is an easy way to write a check
        that reports the exact wrong answer. Do not "simplify" the mapping below.

        If DFC.exe is unavailable, falls back to detecting the Deep Freeze
        service, which establishes that Deep Freeze is installed but cannot
        determine the freeze state. That case returns State = 'Unknown' rather
        than guessing, because "we could not tell" and "it is Thawed" call for
        very different responses on a public-facing machine.

    .OUTPUTS
        PSCustomObject with State, IsFrozen, Method, DeepFreezeInstalled and Detail.

    .EXAMPLE
        Get-DFFreezeState

    .EXAMPLE
        if ((Get-DFFreezeState).State -eq 'Thawed') { Send-MaintenanceAlert }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $DFCPath
    )

    $result = [ordered]@{
        Computer            = $env:COMPUTERNAME
        Timestamp           = (Get-Date).ToString('o')
        State               = 'Unknown'
        IsFrozen            = $null
        Method              = 'None'
        DeepFreezeInstalled = $false
        Detail              = $null
    }

    $service = Get-Service -Name 'DFServ', 'DeepFreeze*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($service) {
        $result.DeepFreezeInstalled = $true
        $result.Detail = "Service '$($service.Name)' status $($service.Status)"
    }

    $dfc = Get-DFCPath -ConfiguredPath $DFCPath
    if (-not $dfc) {
        Write-DFLog -Level 'Warning' -Component 'FreezeState' -Message 'DFC.exe not found; freeze state undetermined.'
        return [PSCustomObject]$result
    }

    $result.DeepFreezeInstalled = $true
    $result.Method = 'DFC.exe /ISFROZEN'

    try {
        # Output is discarded deliberately; the exit code carries the answer.
        $null = & $dfc '/ISFROZEN' 2>&1
        $exitCode = $LASTEXITCODE

        switch ($exitCode) {
            1 { $result.State = 'Frozen'; $result.IsFrozen = $true }
            0 { $result.State = 'Thawed'; $result.IsFrozen = $false }
            default {
                $result.State  = 'Unknown'
                $result.Detail = "DFC.exe returned unexpected exit code $exitCode"
                Write-DFLog -Level 'Warning' -Component 'FreezeState' `
                    -Message "Unexpected DFC.exe exit code: $exitCode"
            }
        }
    } catch {
        $result.State  = 'Unknown'
        $result.Detail = "DFC.exe invocation failed: $($_.Exception.Message)"
        Write-DFLog -Level 'Error' -Component 'FreezeState' -Message $result.Detail
    }

    Write-DFLog -Component 'FreezeState' -Message "Freeze state: $($result.State)" -Data @{ State = $result.State }
    return [PSCustomObject]$result
}
