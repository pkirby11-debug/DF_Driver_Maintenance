function Test-DFTrustedExecutablePath {
    <#
    .SYNOPSIS
        Returns $true only for a path under an administrator-controlled program directory.

    .DESCRIPTION
        The scan runs as SYSTEM, and Get-DFFreezeState invokes whatever path this module
        hands it. Anything that reaches that invocation is therefore SYSTEM code execution,
        so the set of acceptable paths has to be closed rather than open.

        Accepts only: a real .exe, named DFC.exe, resolving under %ProgramFiles%,
        %ProgramFiles(x86)% or %SystemRoot%. Those directories are writable only by
        administrators on a correctly configured Windows install, which is the property
        being relied on.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Path,

        [string] $ExpectedLeaf = 'DFC.exe'
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $false
    }

    if ([System.IO.Path]::GetFileName($full) -ne $ExpectedLeaf) { return $false }
    if ([System.IO.Path]::GetExtension($full) -ne '.exe') { return $false }

    $allowedRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:SystemRoot) |
        Where-Object { $_ }

    foreach ($root in $allowedRoots) {
        try {
            $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
        } catch {
            continue
        }
        # Compare against root + separator so 'C:\Program FilesEvil' cannot match
        # 'C:\Program Files'.
        if ($full.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar,
                             [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-DFCPath {
    <#
    .SYNOPSIS
        Locates the Deep Freeze command line control executable (DFC.exe).

    .DESCRIPTION
        DFC.exe ships with the Deep Freeze client but its location varies by version and by
        whether the install is 32- or 64-bit. Checks the configured path first, then the
        documented install locations.

        SECURITY: every path returned here is executed as SYSTEM by Get-DFFreezeState, so
        each one is validated against Test-DFTrustedExecutablePath first -- including the
        operator-supplied ConfiguredPath, which originates in dfmaintenance.json on a
        volume that a kiosk user may be able to write.

        Without that check, "DFCPath": "C:\\Users\\Public\\anything.exe" in the config file
        is a local privilege escalation to SYSTEM on a machine students physically use, and
        the resulting freeze state reads merely 'Unknown' (DF002 Warning), so the scan looks
        unremarkable while the payload runs nightly.

        A ConfiguredPath that fails validation is logged and IGNORED, falling through to the
        built-in candidates -- never executed.

        The previous unqualified `Get-Command DFC.exe` PATH search has been removed: any
        user-writable directory on the machine PATH would have become a SYSTEM execution
        source whenever Deep Freeze was absent or renamed.

    .OUTPUTS
        The validated full path to DFC.exe, or $null. Callers degrade to the service-based
        probe rather than failing.
    #>
    [CmdletBinding()]
    param(
        [string] $ConfiguredPath
    )

    if ($ConfiguredPath) {
        if (-not (Test-DFTrustedExecutablePath -Path $ConfiguredPath)) {
            Write-DFLog -Level 'Warning' -Component 'FreezeState' `
                -Message "Configured DFCPath '$ConfiguredPath' is not a trusted location; ignoring it." `
                -Data @{ Rejected = $ConfiguredPath }
            Write-Warning "Configured DFCPath '$ConfiguredPath' is rejected: it must be a DFC.exe under Program Files or Windows. Ignoring."
        } elseif (Test-Path -LiteralPath $ConfiguredPath) {
            return (Resolve-Path -LiteralPath $ConfiguredPath).Path
        }
    }

    # Join-Path throws a terminating parameter-binding error when -Path is null, and under
    # the module's $ErrorActionPreference='Stop' that kills the entire scan.
    # ${env:ProgramFiles(x86)} is null on a 32-bit OS, so the roots must be filtered BEFORE
    # they are joined -- filtering the joined results afterwards is too late.
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
        if ((Test-Path -LiteralPath $candidate) -and
            (Test-DFTrustedExecutablePath -Path $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}
