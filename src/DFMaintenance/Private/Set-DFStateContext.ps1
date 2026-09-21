function Set-DFStateContext {
    <#
    .SYNOPSIS
        Resolves the state path for this run and points logging at it.

    .DESCRIPTION
        The log path used to be resolved once at module import with no arguments, which
        meant -StatePath and the config file's StatePath were honoured for reports but
        silently ignored for logs. On a machine whose ThawSpace volume is labelled
        something other than 'ThawSpace*' -- exactly the case that makes an operator pass
        -StatePath explicitly -- reports landed on the durable volume while every log line
        went to the frozen volume and was destroyed on the next reboot. Retention then
        pruned the empty log directory under the real state path.

        Resolving the context per run, from the same inputs the reports use, keeps logs
        and reports on the same volume.

    .OUTPUTS
        The resolved state object from Resolve-DFStatePath.
    #>
    [CmdletBinding()]
    param(
        [string] $StatePath,

        [string] $ThawSpaceLabelPattern = 'ThawSpace*'
    )

    $state = Resolve-DFStatePath -StatePath $StatePath -ThawSpaceLabelPattern $ThawSpaceLabelPattern
    $script:DFState = $state

    try {
        $logDir = Join-Path $state.Path 'logs'
        New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        $script:DFLogPath = Join-Path $logDir ("dfmaintenance-{0}.jsonl" -f (Get-Date -Format 'yyyyMM'))
    } catch {
        # Logging is best effort. A scan must never fail because its log target is gone.
        $script:DFLogPath = $null
        Write-Verbose "Persistent logging unavailable under '$($state.Path)': $($_.Exception.Message)"
    }

    return $state
}
