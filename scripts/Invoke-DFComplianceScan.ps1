#Requires -Version 5.1
<#
.SYNOPSIS
    Scheduled-task entry point: runs a compliance scan and writes the report.

.DESCRIPTION
    Designed to run unattended as SYSTEM on a Deep Freeze protected machine.

    Exit codes are meaningful so that a collector or monitoring wrapper can act
    on them without parsing the report:
        0 - Healthy or informational findings only
        1 - Warning-level findings present
        2 - Critical findings present (including THAWED state)
        3 - The scan itself failed

    The script never throws out of the top level. An unattended task that dies
    with an unhandled exception produces no report at all, which is the one
    outcome worse than a bad report.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Invoke-DFComplianceScan.ps1

.EXAMPLE
    .\Invoke-DFComplianceScan.ps1 -StatePath 'T:\DFMaintenance' -SkipOnlineSearch
#>
[CmdletBinding()]
param(
    [string] $StatePath,

    [string] $ConfigPath,

    # Skip the Windows Update network search; much faster, purely local snapshot.
    [switch] $SkipOnlineSearch,

    # Also render the HTML summary alongside the JSON report.
    [switch] $IncludeHtml
)

$ErrorActionPreference = 'Stop'

try {
    $modulePath = Join-Path $PSScriptRoot '..\src\DFMaintenance\DFMaintenance.psd1'
    $modulePath = [System.IO.Path]::GetFullPath($modulePath)
    Import-Module $modulePath -Force -ErrorAction Stop

    $snapshot = Get-DFComplianceSnapshot -SkipOnlineSearch:$SkipOnlineSearch -ConfigPath $ConfigPath
    $report   = $snapshot | Export-DFComplianceReport -StatePath $StatePath -IncludeHtml:$IncludeHtml

    Write-Output "Status : $($snapshot.OverallStatus)"
    Write-Output "Report : $($report.JsonPath)"
    Write-Output "Durable: $($report.IsPersistent)"

    foreach ($finding in $snapshot.Findings) {
        Write-Output ("  [{0}] {1} {2}" -f $finding.Severity, $finding.Code, $finding.Message)
    }

    # Retention pruning is handled inside Export-DFComplianceReport, which owns
    # report lifecycle and can read module configuration directly.
    if ($report.PrunedFiles -gt 0) {
        Write-Output "Pruned : $($report.PrunedFiles) expired file(s)"
    }

    switch ($snapshot.OverallStatus) {
        'Critical' { exit 2 }
        'Warning'  { exit 1 }
        default    { exit 0 }
    }
} catch {
    Write-Error "Compliance scan failed: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
    exit 3
}
