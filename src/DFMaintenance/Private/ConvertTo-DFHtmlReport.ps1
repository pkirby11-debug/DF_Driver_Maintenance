function ConvertTo-DFHtmlReport {
    <#
    .SYNOPSIS
        Renders a compliance snapshot as a self-contained HTML summary.

    .DESCRIPTION
        Self-contained on purpose: no external CSS or fonts, because these
        machines sit on an isolated VLAN and cannot reach a CDN. The report has
        to render correctly with no network at all.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Snapshot
    )

    $statusColor = switch ($Snapshot.OverallStatus) {
        'Critical' { '#b91c1c' }
        'Warning'  { '#b45309' }
        'Info'     { '#1d4ed8' }
        default    { '#15803d' }
    }

    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

    $findingRows = foreach ($f in $Snapshot.Findings) {
        $color = switch ($f.Severity) {
            'Critical' { '#b91c1c' }
            'Warning'  { '#b45309' }
            default    { '#1d4ed8' }
        }
        "<tr><td style='color:$color;font-weight:600'>$(& $enc $f.Severity)</td><td>$(& $enc $f.Code)</td><td>$(& $enc $f.Message)</td></tr>"
    }
    if (-not $findingRows) { $findingRows = "<tr><td colspan='3'>No findings.</td></tr>" }

    $problemRows = foreach ($p in $Snapshot.Drivers.ProblemDevices) {
        "<tr><td>$(& $enc $p.Name)</td><td>$(& $enc $p.ErrorCode)</td></tr>"
    }
    if (-not $problemRows) { $problemRows = "<tr><td colspan='2'>None.</td></tr>" }

@"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>DF Maintenance - $(& $enc $Snapshot.Computer)</title>
<style>
 body{font-family:Segoe UI,system-ui,sans-serif;margin:2rem;color:#111;background:#fff}
 h1{font-size:1.4rem;margin:0 0 .25rem}
 .status{display:inline-block;padding:.25rem .75rem;border-radius:.25rem;color:#fff;background:$statusColor;font-weight:600}
 table{border-collapse:collapse;width:100%;margin:1rem 0}
 th,td{text-align:left;padding:.4rem .6rem;border-bottom:1px solid #e5e7eb;font-size:.9rem;vertical-align:top}
 th{background:#f3f4f6}
 .meta{color:#6b7280;font-size:.85rem}
</style></head><body>
<h1>$(& $enc $Snapshot.Computer)</h1>
<p><span class="status">$(& $enc $Snapshot.OverallStatus)</span></p>
<p class="meta">Generated $(& $enc $Snapshot.Timestamp)<br>
Freeze state: <strong>$(& $enc $Snapshot.FreezeState.State)</strong> &middot;
OS $(& $enc $Snapshot.WindowsUpdate.OSCaption) $(& $enc $Snapshot.WindowsUpdate.DisplayVersion) (build $(& $enc $Snapshot.WindowsUpdate.OSBuild))<br>
Uptime $(& $enc $Snapshot.WindowsUpdate.UptimeDays) days</p>

<h2>Findings</h2>
<table><tr><th>Severity</th><th>Code</th><th>Detail</th></tr>
$($findingRows -join "`n")
</table>

<h2>Devices in error state</h2>
<table><tr><th>Device</th><th>Error code</th></tr>
$($problemRows -join "`n")
</table>

<p class="meta">Drivers: $(& $enc $Snapshot.Drivers.TotalDrivers) total,
$(& $enc $Snapshot.Drivers.StaleCount) stale &middot;
Software entries: $(& $enc $Snapshot.Software.TotalCount)</p>
</body></html>
"@
}
