[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [string]$SessionName = 'winsmux-orchestra',
    [string]$StartupToken = '',
    [int]$OperatorPollInterval = 20,
    [int]$AgentWatchdogInterval = 30,
    [ValidateRange(5, 10)][int]$ServerWatchdogInterval = 5,
    [int]$IdleThreshold = 120,
    [int]$MaxRestartAttempts = 3,
    [int]$RestartWindowMinutes = 10
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'operator-poll.ps1') -ManifestPath $ManifestPath -StartupToken $StartupToken -Interval $OperatorPollInterval
. (Join-Path $scriptDir 'agent-watchdog.ps1') -ManifestPath $ManifestPath -SessionName $SessionName -StartupToken $StartupToken -IdleThreshold $IdleThreshold -PollInterval $AgentWatchdogInterval
. (Join-Path $scriptDir 'server-watchdog.ps1') -ManifestPath $ManifestPath -SessionName $SessionName -StartupToken $StartupToken -PollInterval $ServerWatchdogInterval -MaxRestartAttempts $MaxRestartAttempts -RestartWindowMinutes $RestartWindowMinutes

function Write-OrchestraSupervisorWarning {
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Write-Warning ("Orchestra supervisor {0} failed for session {1}: {2}" -f $Component, $SessionName, $Message)
}

function Invoke-OrchestraSupervisorLoop {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [int]$OperatorPollInterval = 20,
        [int]$AgentWatchdogInterval = 30,
        [int]$ServerWatchdogInterval = 5,
        [int]$IdleThreshold = 120,
        [int]$MaxRestartAttempts = 3,
        [int]$RestartWindowMinutes = 10
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Manifest not found: $ManifestPath"
    }

    $initialManifest = Read-OperatorPollManifest -Path $ManifestPath
    $projectDir = Get-OperatorPollProjectDir -Manifest $initialManifest -ManifestPath $ManifestPath
    $eventsPath = Get-OperatorPollEventsPath -ProjectDir $projectDir
    $processedLineCount = 0
    $processedEventSignatures = [ordered]@{}
    if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
        $processedLineCount = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8).Count
    }

    Send-OperatorTelegramNotification -ProjectDir $projectDir `
        -SessionName (Get-OperatorPollSessionName -Manifest $initialManifest) `
        -Event 'operator.started' -Message "Operator Poll 開始。間隔: ${OperatorPollInterval}秒"

    $operatorState = 'starting'
    $commitReadySha = ''
    $agentPreviousResults = [ordered]@{}
    $serverState = New-ServerWatchdogState -MaxRestartAttempts $MaxRestartAttempts -RestartWindowMinutes $RestartWindowMinutes
    $nextOperatorPollAt = Get-Date
    $nextAgentWatchdogAt = Get-Date
    $nextServerWatchdogAt = Get-Date

    while ($true) {
        $now = Get-Date

        if ($now -ge $nextOperatorPollAt) {
            try {
                $cycleResult = Invoke-OperatorPollCycle `
                    -ManifestPath $ManifestPath `
                    -ProcessedLineCount $processedLineCount `
                    -ProcessedEventSignatures $processedEventSignatures

                $processedLineCount = [int]$cycleResult['ProcessedLineCount']
                $processedEventSignatures = $cycleResult['ProcessedEventSignatures']
                $currentManifest = Read-OperatorPollManifest -Path $ManifestPath
                $stateResult = Invoke-OperatorStateMachine `
                    -CurrentState $operatorState `
                    -CycleSummary ($cycleResult['Summary']) `
                    -ProjectDir $projectDir `
                    -SessionName (Get-OperatorPollSessionName -Manifest $currentManifest) `
                    -ManifestPath $ManifestPath `
                    -CommitReadySha $commitReadySha

                $operatorState = [string]$stateResult['State']
                $commitReadySha = [string]$stateResult['CommitReadySha']
                $summaryOutput = $cycleResult['Summary']
                $summaryOutput['operator_state'] = $operatorState
                Write-Output ($summaryOutput | ConvertTo-Json -Compress -Depth 10)
            } catch {
                Write-OrchestraSupervisorWarning -Component 'operator-poll' -Message $_.Exception.Message
            }

            $nextOperatorPollAt = $now.AddSeconds($OperatorPollInterval)
        }

        if ($now -ge $nextAgentWatchdogAt) {
            try {
                $agentResult = Invoke-AgentWatchdogCycle -ManifestPath $ManifestPath -SessionName $SessionName -IdleThreshold $IdleThreshold -PreviousResults $agentPreviousResults
                $agentPreviousResults = [ordered]@{}
                if ($null -ne $agentResult -and $null -ne $agentResult.CurrentResults) {
                    foreach ($entry in $agentResult.CurrentResults.GetEnumerator()) {
                        $agentPreviousResults[$entry.Key] = $entry.Value
                    }
                }

                $agentSummary = Get-AgentWatchdogSummary -CycleResult $agentResult -ManifestPath $ManifestPath -SessionName $SessionName
                Write-Output ($agentSummary | ConvertTo-Json -Depth 8 -Compress)
            } catch {
                Write-OrchestraSupervisorWarning -Component 'agent-watchdog' -Message $_.Exception.Message
            }

            $nextAgentWatchdogAt = $now.AddSeconds($AgentWatchdogInterval)
        }

        if ($now -ge $nextServerWatchdogAt) {
            try {
                $serverResult = Invoke-ServerWatchdogCycle -ManifestPath $ManifestPath -SessionName $SessionName -State $serverState
                $serverState = $serverResult.State
                Write-Output ($serverResult | ConvertTo-Json -Depth 8 -Compress)
            } catch {
                Write-OrchestraSupervisorWarning -Component 'server-watchdog' -Message $_.Exception.Message
            }

            $nextServerWatchdogAt = $now.AddSeconds($ServerWatchdogInterval)
        }

        Start-Sleep -Seconds 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-OrchestraSupervisorLoop `
        -ManifestPath $ManifestPath `
        -SessionName $SessionName `
        -OperatorPollInterval $OperatorPollInterval `
        -AgentWatchdogInterval $AgentWatchdogInterval `
        -ServerWatchdogInterval $ServerWatchdogInterval `
        -IdleThreshold $IdleThreshold `
        -MaxRestartAttempts $MaxRestartAttempts `
        -RestartWindowMinutes $RestartWindowMinutes
}
