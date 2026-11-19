function Write-DFTextFile {
    <#
    .SYNOPSIS
        Writes text as BOM-less UTF-8, identically on Windows PowerShell 5.1 and 7.x.

    .DESCRIPTION
        Set-Content -Encoding UTF8 means UTF-8 WITH a BOM on Windows PowerShell 5.1 and
        UTF-8 WITHOUT a BOM on PowerShell 6+. That difference is invisible when authoring
        on 7.x and fatal on the 5.1 target: a leading EF BB BF makes latest.json unreadable
        to every non-PowerShell JSON parser, and latest.json is the system of record that
        the out-of-band collector picks up.

        -Encoding utf8NoBOM is NOT available on 5.1, so the encoding is constructed
        explicitly instead. This path behaves the same on both editions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content,

        # Append instead of overwrite (used by the JSON Lines log).
        [switch] $Append
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if ($Append) {
        [System.IO.File]::AppendAllText($Path, $Content, $utf8NoBom)
    } else {
        [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
    }
}
