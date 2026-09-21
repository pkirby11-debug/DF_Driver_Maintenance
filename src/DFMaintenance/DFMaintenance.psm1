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

# The logging target is NOT resolved here. It is established per run by
# Set-DFStateContext, which the entry-point functions call with the same -StatePath and
# ThawSpaceLabelPattern the reports use.
#
# Resolving it at import with no arguments was a bug: -StatePath and the config file's
# StatePath were honoured for reports but ignored for logs, so on a machine whose
# ThawSpace volume is labelled anything other than 'ThawSpace*' the reports landed on
# the durable volume while every log line went to the frozen volume and was destroyed
# on the next reboot.
#
# Until a context is set, Write-DFLog has no target and silently skips writing; a
# missing log is never a reason to fail a maintenance scan.
$script:DFLogPath = $null
$script:DFState   = $null

Export-ModuleMember -Function $public.BaseName
