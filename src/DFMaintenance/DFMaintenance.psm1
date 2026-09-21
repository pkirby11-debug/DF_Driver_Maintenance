#Requires -Version 5.1

<#
    DFMaintenance
    Compliance and verification tooling for Deep Freeze protected endpoints.

    Design constraints this module is built around:
      - Windows PowerShell 5.1 only. No PS7 dependency: these machines are
        frozen, so anything installed at runtime is discarded on reboot.
      - No external module dependencies, for the same reason.
      - All durable state lives on a ThawSpace volume, never on C:.
#>

$ErrorActionPreference = 'Stop'

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private\*.ps1') -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public\*.ps1')  -ErrorAction SilentlyContinue)

foreach ($file in @($private + $public)) {
    try {
        . $file.FullName
    } catch {
        throw "Failed to import $($file.FullName): $($_.Exception.Message)"
    }
}

# Logging target is resolved once at import. If nothing persistent is available
# the module still loads and simply does not write a log file; a missing log is
# not a reason to fail a maintenance scan.
$script:DFLogPath = $null
try {
    $state  = Resolve-DFStatePath
    $logDir = Join-Path $state.Path 'logs'
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    $script:DFLogPath = Join-Path $logDir ("dfmaintenance-{0}.jsonl" -f (Get-Date -Format 'yyyyMM'))
} catch {
    Write-Verbose "Persistent logging unavailable: $($_.Exception.Message)"
}

Export-ModuleMember -Function $public.BaseName
