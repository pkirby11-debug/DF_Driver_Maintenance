function Export-DFComplianceReport {
    <#
    .SYNOPSIS
        Writes a compliance snapshot to persistent storage as JSON and optional HTML.

    .DESCRIPTION
        Writes two files per run:

          reports\<COMPUTER>_<timestamp>.json  - the full historical record
          reports\latest.json                  - a stable path for a collector to read

        On this isolated VLAN there is no file share to report into, so the
        machine's own ThawSpace is the system of record and a collector picks the
        files up out-of-band. 'latest.json' exists so the collector does not have
        to sort filenames to find the current state.

        Writes are staged to a temporary file and then moved into place, so a
        collector never reads a half-written report.

    .OUTPUTS
        PSCustomObject describing where the report was written.

    .EXAMPLE
        Get-DFComplianceSnapshot | Export-DFComplianceReport

    .EXAMPLE
        Get-DFComplianceSnapshot | Export-DFComplianceReport -IncludeHtml
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject] $Snapshot,

        [string] $StatePath,

        # Also render a human-readable HTML summary for local viewing.
        [switch] $IncludeHtml,

        # Reports and logs older than this are pruned. Defaults to the
        # configured LogRetentionDays. A ThawSpace volume that fills up on a
        # machine nobody visits is a real failure mode, so pruning lives here
        # with the writer rather than in a caller that might forget.
        [ValidateRange(1, 3650)]
        [int] $RetentionDays
    )

    process {
        $state = Resolve-DFStatePath -StatePath $StatePath
        $reportDir = Join-Path $state.Path 'reports'
        New-Item -Path $reportDir -ItemType Directory -Force | Out-Null

        if (-not $state.IsPersistent) {
            Write-Warning "State path '$($state.Path)' is NOT persistent across a Frozen reboot ($($state.Source)). This report will be discarded on the next reboot."
        }

        $stamp      = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $jsonPath   = Join-Path $reportDir "$($env:COMPUTERNAME)_$stamp.json"
        $latestPath = Join-Path $reportDir 'latest.json'

        if (-not $PSCmdlet.ShouldProcess($jsonPath, 'Write compliance report')) { return }

        $json = $Snapshot | ConvertTo-Json -Depth 8

        # Stage then move, so a collector never sees a partial file.
        $temp = "$jsonPath.tmp"
        Set-Content -LiteralPath $temp -Value $json -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $jsonPath -Force
        Copy-Item -LiteralPath $jsonPath -Destination $latestPath -Force

        $htmlPath = $null
        if ($IncludeHtml) {
            $htmlPath = Join-Path $reportDir 'latest.html'
            ConvertTo-DFHtmlReport -Snapshot $Snapshot | Set-Content -LiteralPath $htmlPath -Encoding UTF8
        }

        Write-DFLog -Component 'Report' -Message "Report written to $jsonPath" `
            -Data @{ Path = $jsonPath; Persistent = $state.IsPersistent }

        if (-not $PSBoundParameters.ContainsKey('RetentionDays')) {
            # Read the config that belongs to the state path actually in use,
            # rather than re-resolving independently and possibly reading a
            # different machine's config when -StatePath was passed explicitly.
            $RetentionDays = (Get-DFConfig -ConfigPath (Join-Path $state.Path 'dfmaintenance.json')).LogRetentionDays
        }
        $pruned = Invoke-DFRetention -StatePath $state.Path -RetentionDays $RetentionDays

        return [PSCustomObject]@{
            JsonPath     = $jsonPath
            LatestPath   = $latestPath
            HtmlPath     = $htmlPath
            StatePath    = $state.Path
            IsPersistent = $state.IsPersistent
            PrunedFiles  = $pruned
        }
    }
}
