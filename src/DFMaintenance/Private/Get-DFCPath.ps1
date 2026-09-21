function Get-DFCPath {
    <#
    .SYNOPSIS
        Locates the Deep Freeze command line control executable (DFC.exe).

    .DESCRIPTION
        DFC.exe ships with the Deep Freeze client but its location varies by
        version and by whether the install is 32- or 64-bit. Checks the
        configured path first, then the documented install locations, then PATH.

        Returns $null when DFC.exe cannot be found; callers degrade to the
        service-based freeze state probe rather than failing.
    #>
    [CmdletBinding()]
    param(
        [string] $ConfiguredPath
    )

    if ($ConfiguredPath -and (Test-Path -LiteralPath $ConfiguredPath)) {
        return (Resolve-Path -LiteralPath $ConfiguredPath).Path
    }

    # Join-Path throws a terminating parameter-binding error when -Path is null, and
    # under the module's $ErrorActionPreference='Stop' that kills the entire scan.
    # ${env:ProgramFiles(x86)} is null on a 32-bit OS, so the roots must be filtered
    # BEFORE they are joined -- filtering the joined results afterwards is too late.
    $roots = @(
        @{ Base = $env:ProgramFiles        ; Leaves = @('Faronics\Deep Freeze\DFC.exe', 'Faronics\Deep Freeze Enterprise\DFC.exe') }
        @{ Base = ${env:ProgramFiles(x86)} ; Leaves = @('Faronics\Deep Freeze\DFC.exe', 'Faronics\Deep Freeze Enterprise\DFC.exe') }
        @{ Base = $env:SystemRoot          ; Leaves = @('System32\DFC.exe', 'SysWOW64\DFC.exe') }
    )

    $candidates = foreach ($root in $roots) {
        if (-not $root.Base) { continue }
        foreach ($leaf in $root.Leaves) { Join-Path $root.Base $leaf }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $onPath = Get-Command -Name 'DFC.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }

    return $null
}
