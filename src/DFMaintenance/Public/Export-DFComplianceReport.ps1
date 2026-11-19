function Export-DFComplianceReport {
    <#
    .SYNOPSIS
        Writes a compliance snapshot to persistent storage as JSON and optional HTML.

    .DESCRIPTION
        Writes two files per run:

          reports\<COMPUTER>_<timestamp>.json  - the full historical record
          reports\latest.json                  - a stable path for a collector to read

        On this isolated VLAN there is no file share to report into, so the machine's own
        ThawSpace is the system of record and a collector picks the files up out-of-band.
        'latest.json' exists so the collector does not have to sort filenames.

        Both files are staged to a temporary file and then moved into place, so a collector
        never reads a half-written report.

        All text is written as BOM-less UTF-8 via Write-DFTextFile. Set-Content -Encoding
        UTF8 would prefix a BOM on Windows PowerShell 5.1 (but not on 7.x), which is
        exactly what a non-PowerShell JSON parser chokes on.

        Retention runs BEFORE the write: the volume filling up is a real failure mode on a
        machine nobody visits, and pruning first lets a full volume recover on its own
        instead of failing every subsequent write.

    .OUTPUTS
        PSCustomObject describing where the report was written. On a write failure it still
        returns an object, with JsonPath = $null and WriteError set, so the caller can
        report the failure rather than losing the findings entirely.

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

        [string] $ConfigPath,

        # Also render a human-readable HTML summary for local viewing.
        [switch] $IncludeHtml,

        # Reports and logs older than this are pruned. Defaults to the configured
        # LogRetentionDays.
        [ValidateRange(1, 3650)]
        [int] $RetentionDays
    )

    process {
        $config = Get-DFConfig -ConfigPath $ConfigPath

        $effectiveStatePath = if ($StatePath) { $StatePath } else { $config.StatePath }
        $state = Set-DFStateContext -StatePath $effectiveStatePath `
                                    -ThawSpaceLabelPattern $config.ThawSpaceLabelPattern

        $reportDir = Join-Path $state.Path 'reports'
        New-Item -Path $reportDir -ItemType Directory -Force | Out-Null

        if (-not $state.IsPersistent) {
            Write-Warning "State path '$($state.Path)' is NOT persistent across a Frozen reboot ($($state.Source)). This report will be discarded on the next reboot."
        }

        $stamp      = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $jsonPath   = Join-Path $reportDir "$($env:COMPUTERNAME)_$stamp.json"
        $latestPath = Join-Path $reportDir 'latest.json'

        if (-not $PSCmdlet.ShouldProcess($jsonPath, 'Write compliance report')) { return }

        # $RetentionDays carries a [ValidateRange] attribute, and PowerShell attaches
        # validation to the VARIABLE -- assigning a config value straight back into it
        # re-runs validation and throws for anything outside 1..3650. Nothing range-checks
        # LogRetentionDays in the config file, so "LogRetentionDays": 0 (a plausible way to
        # try to disable pruning) would abort the scan. Clamp into an unvalidated local.
        $effectiveRetention = 90
        if ($PSBoundParameters.ContainsKey('RetentionDays')) {
            $effectiveRetention = $RetentionDays
        } else {
            $configured = $config.LogRetentionDays
            if ($configured -is [int] -and $configured -ge 1 -and $configured -le 3650) {
                $effectiveRetention = $configured
            } else {
                Write-DFLog -Level 'Warning' -Component 'Report' `
                    -Message "LogRetentionDays '$configured' is out of range 1-3650; using 90."
            }
        }

        $pruned = 0
        try {
            $pruned = Invoke-DFRetention -StatePath $state.Path -RetentionDays $effectiveRetention
        } catch {
            Write-DFLog -Level 'Warning' -Component 'Report' `
                -Message "Retention sweep failed: $($_.Exception.Message)"
        }

        $htmlPath   = $null
        $writeError = $null

        # The findings were computed in memory before this point. A write failure must be
        # reported, not allowed to propagate and discard them.
        try {
            $json = $Snapshot | ConvertTo-Json -Depth 8

            $temp = "$jsonPath.tmp"
            Write-DFTextFile -Path $temp -Content $json
            Move-Item -LiteralPath $temp -Destination $jsonPath -Force

            # latest.json is staged and moved too. A direct copy is not atomic, and a
            # collector reading mid-copy would see a truncated file.
            $latestTemp = "$latestPath.tmp"
            Write-DFTextFile -Path $latestTemp -Content $json
            Move-Item -LiteralPath $latestTemp -Destination $latestPath -Force

            if ($IncludeHtml) {
                $htmlPath = Join-Path $reportDir 'latest.html'
                $htmlTemp = "$htmlPath.tmp"
                Write-DFTextFile -Path $htmlTemp -Content (ConvertTo-DFHtmlReport -Snapshot $Snapshot)
                Move-Item -LiteralPath $htmlTemp -Destination $htmlPath -Force
            }

            Write-DFLog -Component 'Report' -Message "Report written to $jsonPath" `
                -Data @{ Path = $jsonPath; Persistent = $state.IsPersistent }
        } catch {
            $writeError = $_.Exception.Message
            $jsonPath   = $null
            Write-DFLog -Level 'Error' -Component 'Report' -Message "Report write failed: $writeError"
            Write-Warning "Report write failed: $writeError"
        }

        return [PSCustomObject]@{
            JsonPath     = $jsonPath
            LatestPath   = if ($writeError) { $null } else { $latestPath }
            HtmlPath     = $htmlPath
            StatePath    = $state.Path
            IsPersistent = $state.IsPersistent
            PrunedFiles  = $pruned
            WriteError   = $writeError
        }
    }
}
