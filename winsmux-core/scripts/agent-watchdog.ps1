[CmdletBinding()]
param(
    [string]$ManifestPath = '',
    [string]$SessionName = 'winsmux-orchestra',
    [int]$IdleThreshold = 120,
    [int]$PollInterval = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'agent-monitor.ps1')

function Invoke-AgentWatchdogCycle {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][int]$IdleThreshold,
        [AllowNull()][System.Collections.IDictionary]$PreviousResults = $null
    )

    $settings = Get-BridgeSettings
    return (Invoke-AgentMonitorCycle -Settings $settings -ManifestPath $ManifestPath -SessionName $SessionName -IdleThreshold $IdleThreshold -PreviousResults $PreviousResults)
}

function Get-AgentWatchdogSummary {
    param(
        [Parameter(Mandatory = $true)]$CycleResult,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    return [ordered]@{
        session          = $SessionName
        manifest_path    = $ManifestPath
        events_path      = Join-Path (Split-Path -Parent $ManifestPath) 'events.jsonl'
        checked          = [int]$CycleResult.Checked
        crashed          = [int]$CycleResult.Crashed
        respawned        = [int]$CycleResult.Respawned
        approval_waiting = [int]$CycleResult.ApprovalWaiting
        idle_alerts      = [int]$CycleResult.IdleAlerts
        stalls           = [int]$CycleResult.Stalls
        results          = @($CycleResult.Results)
    }
}

function Start-AgentWatchdogLoop {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [int]$IdleThreshold = 120,
        [int]$PollInterval = 30
    )

    $previousResults = [ordered]@{}

    while ($true) {
        try {
            $result = Invoke-AgentWatchdogCycle -ManifestPath $ManifestPath -SessionName $SessionName -IdleThreshold $IdleThreshold -PreviousResults $previousResults
            $previousResults = [ordered]@{}
            if ($null -ne $result -and $null -ne $result.CurrentResults) {
                foreach ($entry in $result.CurrentResults.GetEnumerator()) {
                    $previousResults[$entry.Key] = $entry.Value
                }
            }
            # Invoke-AgentMonitorCycle persists pane events into events.jsonl; the watchdog publishes only the cycle summary.
            $summary = Get-AgentWatchdogSummary -CycleResult $result -ManifestPath $ManifestPath -SessionName $SessionName
            Write-Output ($summary | ConvertTo-Json -Depth 8 -Compress)
        } catch {
            Write-Warning ("Watchdog cycle failed for session {0}: {1}" -f $SessionName, $_.Exception.Message)
        }

        Start-Sleep -Seconds $PollInterval
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        throw 'ManifestPath is required.'
    }

    Start-AgentWatchdogLoop -ManifestPath $ManifestPath -SessionName $SessionName -IdleThreshold $IdleThreshold -PollInterval $PollInterval
}
