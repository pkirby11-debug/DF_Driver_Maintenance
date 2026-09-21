function Write-DFLog {
    <#
    .SYNOPSIS
        Appends a structured log record to the persistent state directory.

    .DESCRIPTION
        Records are written as JSON Lines (one JSON object per line) so that a
        collector can parse a log without loading the whole file, and so that a
        partially written file from an interrupted maintenance cycle is still
        readable up to the last complete line.

        Logging never throws. A maintenance run must not fail because its log
        target went away mid-cycle.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Message,

        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string] $Level = 'Info',

        [string] $Component = 'DFMaintenance',

        [hashtable] $Data,

        [string] $LogPath = $script:DFLogPath
    )

    $record = [ordered]@{
        Timestamp = (Get-Date).ToString('o')
        Level     = $Level
        Component = $Component
        Computer  = $env:COMPUTERNAME
        Message   = $Message
    }
    if ($Data) { $record['Data'] = $Data }

    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error'   { Write-Error $Message -ErrorAction Continue }
        'Debug'   { Write-Verbose $Message }
        default   { Write-Verbose $Message }
    }

    if (-not $LogPath) { return }

    try {
        $line = ($record | ConvertTo-Json -Depth 6 -Compress)
        Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Warning "Log write failed ($LogPath): $($_.Exception.Message)"
    }
}
