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

    $candidates = @(
        (Join-Path $env:ProgramFiles          'Faronics\Deep Freeze\DFC.exe')
        (Join-Path $env:ProgramFiles          'Faronics\Deep Freeze Enterprise\DFC.exe')
        (Join-Path ${env:ProgramFiles(x86)}   'Faronics\Deep Freeze\DFC.exe')
        (Join-Path ${env:ProgramFiles(x86)}   'Faronics\Deep Freeze Enterprise\DFC.exe')
        (Join-Path $env:SystemRoot            'System32\DFC.exe')
        (Join-Path $env:SystemRoot            'SysWOW64\DFC.exe')
    ) | Where-Object { $_ }

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
