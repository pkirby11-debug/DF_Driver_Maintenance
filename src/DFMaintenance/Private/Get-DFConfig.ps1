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
        StateVolumeSerial     = $null
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

    # Numeric keys are bound to [ValidateRange] parameters downstream, and PowerShell
    # re-validates on assignment -- so an out-of-range or non-numeric value from this file
    # throws mid-scan rather than being ignored. The config sits on a volume a kiosk user
    # may be able to write, so every numeric value is type-checked and range-checked HERE,
    # once, and falls back to the default rather than propagating.
    $numericRanges = @{
        LogRetentionDays     = @{ Min = 1; Max = 3650 }
        DriverAgeWarningDays = @{ Min = 0; Max = 10000 }
    }

    foreach ($key in @($defaults.Keys)) {
        $property = $raw.PSObject.Properties[$key]
        if ($null -eq $property -or $null -eq $property.Value) { continue }
        $value = $property.Value

        if ($numericRanges.ContainsKey($key)) {
            $parsed = 0
            if (-not [int]::TryParse([string]$value, [ref]$parsed)) {
                Write-DFLog -Level 'Warning' -Component 'Config' `
                    -Message "Config '$key' value '$value' is not an integer; using default $($defaults[$key])."
                continue
            }
            $range = $numericRanges[$key]
            if ($parsed -lt $range.Min -or $parsed -gt $range.Max) {
                Write-DFLog -Level 'Warning' -Component 'Config' `
                    -Message "Config '$key' value $parsed is outside $($range.Min)-$($range.Max); using default $($defaults[$key])."
                continue
            }
            $defaults[$key] = $parsed
            continue
        }

        $defaults[$key] = $value
    }

    return [PSCustomObject]$defaults
}
