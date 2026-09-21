function Resolve-DFStatePath {
    <#
    .SYNOPSIS
        Locates a writable state directory that survives a Deep Freeze reboot.

    .DESCRIPTION
        Under Deep Freeze, anything written to the frozen volume is discarded on
        the next Frozen boot. State therefore has to live on a ThawSpace volume
        (or another volume excluded from the freeze).

        Resolution order:
          1. An explicit path from configuration / the -StatePath parameter.
          2. A volume whose label matches the ThawSpace label pattern.
          3. Fallback to $env:ProgramData, flagged as NON-PERSISTENT.

        The fallback exists so that a scan still produces output on a machine
        without ThawSpace configured, but callers are expected to surface the
        IsPersistent flag rather than silently trusting the path.

    .OUTPUTS
        PSCustomObject with Path, Source and IsPersistent.
    #>
    [CmdletBinding()]
    param(
        [string] $StatePath,

        [string] $ThawSpaceLabelPattern = 'ThawSpace*'
    )

    if ($StatePath) {
        # An operator-supplied path is taken at face value for location, but we
        # still confirm it is not on the system volume before calling it durable.
        $isSystemVolume = $false
        try {
            $sysRoot = [System.IO.Path]::GetPathRoot($env:SystemDrive + '\')
            $target  = [System.IO.Path]::GetPathRoot((New-Item -Path $StatePath -ItemType Directory -Force).FullName)
            $isSystemVolume = ($target -eq $sysRoot)
        } catch {
            Write-Verbose "Could not evaluate volume for '$StatePath': $($_.Exception.Message)"
        }

        return [PSCustomObject]@{
            Path         = $StatePath
            Source       = 'Configured'
            IsPersistent = -not $isSystemVolume
        }
    }

    $thawSpace = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.VolumeName -like $ThawSpaceLabelPattern -and $_.DriveType -eq 3 } |
        Select-Object -First 1

    if ($thawSpace) {
        $path = Join-Path $thawSpace.DeviceID 'DFMaintenance'
        New-Item -Path $path -ItemType Directory -Force | Out-Null
        return [PSCustomObject]@{
            Path         = $path
            Source       = "ThawSpace ($($thawSpace.VolumeName))"
            IsPersistent = $true
        }
    }

    $fallback = Join-Path $env:ProgramData 'DFMaintenance'
    New-Item -Path $fallback -ItemType Directory -Force | Out-Null
    return [PSCustomObject]@{
        Path         = $fallback
        Source       = 'ProgramData fallback'
        IsPersistent = $false
    }
}
