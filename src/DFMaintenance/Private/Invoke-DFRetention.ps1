function Invoke-DFRetention {
    <#
    .SYNOPSIS
        Prunes expired reports and logs from the persistent state directory.

    .DESCRIPTION
        ThawSpace is a fixed-size volume on a machine nobody visits. Without
        pruning, months of unattended daily scans will eventually fill it, and
        the first symptom is that scans silently stop being able to write their
        results - the exact failure this tool exists to catch.

        The 'latest.*' pointer files are never pruned regardless of age: a
        machine that has not scanned in a long time should still present its
        last known state to a collector rather than nothing at all.

        Never throws. Failing to prune is not a reason to fail a scan.

    .OUTPUTS
        [int] the number of files removed.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $StatePath,

        [ValidateRange(1, 3650)]
        [int] $RetentionDays = 90
    )

    $keep   = @('latest.json', 'latest.html')
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $count  = 0

    foreach ($sub in 'reports', 'logs') {
        $dir = Join-Path $StatePath $sub
        if (-not (Test-Path -LiteralPath $dir)) { continue }

        try {
            $expired = Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop |
                Where-Object { $_.LastWriteTime -lt $cutoff -and $_.Name -notin $keep }

            foreach ($file in $expired) {
                try {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    $count++
                } catch {
                    Write-Verbose "Could not remove '$($file.FullName)': $($_.Exception.Message)"
                }
            }
        } catch {
            Write-DFLog -Level 'Warning' -Component 'Retention' `
                -Message "Retention sweep failed for '$dir': $($_.Exception.Message)"
        }
    }

    if ($count -gt 0) {
        Write-DFLog -Component 'Retention' -Message "Pruned $count expired file(s)." -Data @{ Removed = $count }
    }
    return $count
}
