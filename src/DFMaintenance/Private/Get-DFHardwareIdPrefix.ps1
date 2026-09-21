function Get-DFHardwareIdPrefix {
    <#
    .SYNOPSIS
        Reduces a PnP DeviceID to its hardware-class prefix, dropping the instance id.

    .DESCRIPTION
        A DeviceID looks like:

            USB\VID_046D&PID_C52B\5&1F2E3D4C&0&2
            ^ enumerator ^ hardware ids        ^ instance id

        For many devices the instance id IS the hardware serial number -- a stable,
        per-unit identifier. The README states these reports contain no user or device
        identifying data, and emitting serials for every device on a hospital endpoint
        contradicts that.

        The first two segments are what driver triage actually needs (vendor and product),
        so the instance id is dropped.

    .OUTPUTS
        [string] the truncated identifier, or $null when there is nothing to report.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $DeviceID
    )

    if ([string]::IsNullOrWhiteSpace($DeviceID)) { return $null }

    $segments = $DeviceID -split '\\'
    if ($segments.Count -le 2) { return $DeviceID }
    return ($segments[0..1] -join '\')
}
