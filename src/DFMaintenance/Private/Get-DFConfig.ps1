function Get-DFConfig {
    <#
    .SYNOPSIS
        Loads module configuration, merging a JSON config file over built-in defaults.

    .DESCRIPTION
        Config is deliberately file-based rather than registry-based: on a frozen
        machine the registry is reverted on reboot, so a config file on ThawSpace
        is the only thing that reliably survives.

        No secret should ever be placed in this file. The Deep Freeze password in
        particular belongs in the Cloud console, not on a public-facing endpoint.
    #>
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $defaults = [ordered]@{
        StatePath             = $null
        ThawSpaceLabelPattern = 'ThawSpace*'
        DFCPath               = $null
        LogRetentionDays      = 90
        DriverAgeWarningDays  = 1095   # ~3 years; a driver older than this is worth a look
        TrackedSoftware       = @()    # empty = report everything found
    }

    if (-not $ConfigPath) {
        $probe = Resolve-DFStatePath
        $ConfigPath = Join-Path $probe.Path 'dfmaintenance.json'
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Verbose "No config file at '$ConfigPath'; using defaults."
        return [PSCustomObject]$defaults
    }

    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Config at '$ConfigPath' is unreadable, falling back to defaults: $($_.Exception.Message)"
        return [PSCustomObject]$defaults
    }

    foreach ($key in @($defaults.Keys)) {
        $value = $raw.PSObject.Properties[$key]
        if ($null -ne $value -and $null -ne $value.Value) {
            $defaults[$key] = $value.Value
        }
    }

    return [PSCustomObject]$defaults
}
