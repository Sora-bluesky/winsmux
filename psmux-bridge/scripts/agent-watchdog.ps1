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
        [Parameter(Mandatory = $true)][int]$IdleThreshold
    )

    $settings = Get-BridgeSettings
    return (Invoke-AgentMonitorCycle -Settings $settings -ManifestPath $ManifestPath -SessionName $SessionName -IdleThreshold $IdleThreshold)
}

function Start-AgentWatchdogLoop {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [int]$IdleThreshold = 120,
        [int]$PollInterval = 30
    )

    while ($true) {
        try {
            $result = Invoke-AgentWatchdogCycle -ManifestPath $ManifestPath -SessionName $SessionName -IdleThreshold $IdleThreshold
            Write-Output ($result | ConvertTo-Json -Depth 8 -Compress)
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
