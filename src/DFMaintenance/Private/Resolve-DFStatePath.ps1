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

        [string] $ThawSpaceLabelPattern = 'ThawSpace*',

        # Volume serial recorded at setup. When supplied, a label match on a volume with a
        # different serial is reported as untrusted -- see the label-trust note below.
        [string] $ExpectedVolumeSerial
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
            Path          = $StatePath
            Source        = 'Configured'
            IsPersistent  = -not $isSystemVolume
            VolumeSerial  = $null
            VolumeTrusted = $true   # an explicit path is an operator decision, not a guess
        }
    }

    # LABEL TRUST
    # Matching on a volume LABEL alone means anything a user can attach and name can become
    # the state volume -- and the state volume holds the config, which steers a
    # SYSTEM-executed path and where reports are written. DriveType 3 excludes removable
    # media, but a USB hard disk can still present as a fixed disk.
    #
    # Mitigations: multiple matches are never silently resolved, the selection is
    # deterministic rather than enumeration-order dependent, and the chosen volume's serial
    # is recorded so a swap is detectable against the serial pinned at setup.
    # An explicit -StatePath (above) bypasses all of this and is the recommended
    # configuration for a managed deployment.
    $candidates = @(
        Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.VolumeName -like $ThawSpaceLabelPattern -and $_.DriveType -eq 3 } |
            Sort-Object DeviceID
    )

    if ($candidates.Count -gt 1) {
        Write-DFLog -Level 'Warning' -Component 'StatePath' `
            -Message "Multiple volumes match '$ThawSpaceLabelPattern' ($(($candidates.DeviceID) -join ', ')); using $($candidates[0].DeviceID). Set StatePath explicitly." `
            -Data @{ Matches = @($candidates.DeviceID) }
        Write-Warning "Multiple volumes match '$ThawSpaceLabelPattern': $(($candidates.DeviceID) -join ', '). Using $($candidates[0].DeviceID). Set StatePath explicitly to remove the ambiguity."
    }

    $thawSpace = $candidates | Select-Object -First 1

    if ($thawSpace) {
        $serial  = $thawSpace.VolumeSerialNumber
        $trusted = $true
        if ($ExpectedVolumeSerial -and $serial -and
            $ExpectedVolumeSerial -ne $serial) {
            $trusted = $false
            Write-DFLog -Level 'Warning' -Component 'StatePath' `
                -Message "Volume serial '$serial' does not match the pinned serial '$ExpectedVolumeSerial'." `
                -Data @{ Found = $serial; Expected = $ExpectedVolumeSerial }
        }

        $path = Join-Path $thawSpace.DeviceID 'DFMaintenance'
        New-Item -Path $path -ItemType Directory -Force | Out-Null
        return [PSCustomObject]@{
            Path          = $path
            Source        = "ThawSpace ($($thawSpace.VolumeName))"
            IsPersistent  = $true
            VolumeSerial  = $serial
            VolumeTrusted = $trusted
        }
    }

    $fallback = Join-Path $env:ProgramData 'DFMaintenance'
    New-Item -Path $fallback -ItemType Directory -Force | Out-Null
    return [PSCustomObject]@{
        Path          = $fallback
        Source        = 'ProgramData fallback'
        IsPersistent  = $false
        VolumeSerial  = $null
        VolumeTrusted = $true
    }
}
