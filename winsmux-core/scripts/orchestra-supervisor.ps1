[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [string]$SessionName = 'winsmux-orchestra',
    [Parameter(Mandatory = $true)][string]$GenerationId,
    [Parameter(Mandatory = $true)][string]$ServerSessionId,
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
. (Join-Path $scriptDir 'manifest.ps1')
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

function New-OrchestraSupervisorRuntimePanes {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$GenerationId,
        [Parameter(Mandatory = $true)][string]$ServerSessionId,
        [Parameter(Mandatory = $true)][scriptblock]$ProcessResolver
    )

    $runtimePanes = [System.Collections.Generic.List[object]]::new()
    $paneMap = ConvertTo-ManifestPropertyMap -Value (Get-WinsmuxRuntimeValue -InputObject $Manifest -Name 'panes' -Default $null)
    foreach ($label in $paneMap.Keys) {
        $pane = $paneMap[$label]
        $slotId = [string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'slot_id' -Default '')
        $paneId = [string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'pane_id' -Default '')
        $backend = [string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'worker_backend' -Default '')
        $role = Resolve-WinsmuxRuntimeRole `
            -WorkerRole ([string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'worker_role' -Default '')) `
            -CanonicalRole ([string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'role' -Default ''))
        $title = [string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'title' -Default '')
        $status = [string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'status' -Default '')
        $runtimeReady = (Get-WinsmuxRuntimeValue -InputObject $pane -Name 'runtime_ready' -Default $false) -eq $true
        if ([string]::IsNullOrWhiteSpace($slotId) -or [string]::IsNullOrWhiteSpace($paneId) -or
            [string]::IsNullOrWhiteSpace($backend) -or [string]::IsNullOrWhiteSpace($role) -or
            [string]::IsNullOrWhiteSpace($title)) {
            throw "Runtime pane seed is incomplete for $label."
        }

        $statusClassification = Get-WinsmuxRuntimeStatusClassification -Status $status
        $deferred = [bool]$statusClassification.IsDeferred
        $markerPath = [string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'bootstrap_marker_path' -Default '')
        $markerExists = -not [string]::IsNullOrWhiteSpace($markerPath) -and (Test-Path -LiteralPath $markerPath -PathType Leaf)
        $promoteDeferredStarting = [bool]$statusClassification.IsStarting -and $markerExists
        $runtimeState = if ($promoteDeferredStarting) {
            'live'
        } elseif ($deferred) {
            'deferred'
        } elseif ($runtimeReady) {
            'live'
        } else {
            'bootstrap_pending'
        }
        $runtimePane = [PSCustomObject][ordered]@{
            label                        = [string]$label
            slot_id                      = $slotId
            pane_id                      = $paneId
            backend                      = $backend
            role                         = $role
            title                        = $title
            state                        = $runtimeState
            bootstrap_pid                = 0
            bootstrap_process_started_at = ''
            marker_path                  = $markerPath
        }

        if (-not $deferred -or $promoteDeferredStarting) {
            if ([string]::IsNullOrWhiteSpace($runtimePane.marker_path) -or -not (Test-Path -LiteralPath $runtimePane.marker_path -PathType Leaf)) {
                throw "Live runtime pane marker is missing for $label."
            }
            try {
                $marker = Get-Content -LiteralPath $runtimePane.marker_path -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch {
                throw "Live runtime pane marker is malformed for $label."
            }
            $markerPid = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $marker -Name 'bootstrap_pid' -Default $null)
            $markerStartedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value (Get-WinsmuxRuntimeValue -InputObject $marker -Name 'bootstrap_process_started_at' -Default '')
            if ([string](Get-WinsmuxRuntimeValue -InputObject $marker -Name 'state' -Default '') -cne 'bootstrap_pending' -or
                -not [string]::Equals(
                    [string](Get-WinsmuxRuntimeValue -InputObject $marker -Name 'generation_id' -Default ''),
                    $GenerationId,
                    [System.StringComparison]::Ordinal) -or
                [string](Get-WinsmuxRuntimeValue -InputObject $marker -Name 'server_session_id' -Default '') -cne $ServerSessionId -or
                [string](Get-WinsmuxRuntimeValue -InputObject $marker -Name 'slot_id' -Default '') -cne $slotId -or
                [string](Get-WinsmuxRuntimeValue -InputObject $marker -Name 'pane_id' -Default '') -cne $paneId -or
                [string](Get-WinsmuxRuntimeValue -InputObject $marker -Name 'backend' -Default '') -cne $backend -or
                [string](Get-WinsmuxRuntimeValue -InputObject $marker -Name 'role' -Default '') -cne $role -or
                [string](Get-WinsmuxRuntimeValue -InputObject $marker -Name 'title' -Default '') -cne $title -or
                $null -eq $markerPid -or [string]::IsNullOrWhiteSpace($markerStartedAt) -or
                -not (Test-WinsmuxStrictProcessIdentity -ProcessId $markerPid -ExpectedStartTime $markerStartedAt -ProcessResolver $ProcessResolver)) {
                throw "Live runtime pane marker identity does not match $label."
            }
            $runtimePane.bootstrap_pid = $markerPid
            $runtimePane.bootstrap_process_started_at = $markerStartedAt
        }
        $runtimePanes.Add($runtimePane) | Out-Null
    }

    return @($runtimePanes)
}

function Get-OrchestraSupervisorRuntimePaneSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$GenerationId,
        [Parameter(Mandatory = $true)][string]$ServerSessionId,
        [Parameter(Mandatory = $true)][scriptblock]$ProcessResolver
    )

    try {
        $panes = @(New-OrchestraSupervisorRuntimePanes -Manifest $Manifest -GenerationId $GenerationId `
            -ServerSessionId $ServerSessionId -ProcessResolver $ProcessResolver)
        return [PSCustomObject][ordered]@{
            valid      = $true
            panes      = $panes
            diagnostic = ''
        }
    } catch {
        return [PSCustomObject][ordered]@{
            valid      = $false
            panes      = @()
            diagnostic = [string]$_.Exception.Message
        }
    }
}

function Initialize-OrchestraSupervisorRuntimeRegistry {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$GenerationId,
        [Parameter(Mandatory = $true)][string]$ServerSessionId,
        [Parameter(Mandatory = $true)][string]$SupervisorProcessStartedAt
    )

    $projectDir = Split-Path (Split-Path $ManifestPath -Parent) -Parent
    $manifest = Get-WinsmuxManifest -ProjectDir $projectDir
    $session = Get-WinsmuxRuntimeValue -InputObject $manifest -Name 'session'
    $bootstrapPaneId = [string](Get-WinsmuxRuntimeValue -InputObject $session -Name 'bootstrap_pane_id' -Default '')
    $expectedPaneCount = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $session -Name 'expected_pane_count' -Default $null)
    if ($null -eq $manifest -or
        [string](Get-WinsmuxRuntimeValue -InputObject $session -Name 'name' -Default '') -cne $SessionName -or
        -not [string]::Equals(
            [string](Get-WinsmuxRuntimeValue -InputObject $session -Name 'generation_id' -Default ''),
            $GenerationId,
            [System.StringComparison]::Ordinal) -or
        [string](Get-WinsmuxRuntimeValue -InputObject $session -Name 'server_session_id' -Default '') -cne $ServerSessionId -or
        $null -eq $expectedPaneCount -or $expectedPaneCount -lt 1 -or
        ((-not [string]::IsNullOrWhiteSpace($bootstrapPaneId)) -and $bootstrapPaneId -cnotmatch '^%[0-9]+$')) {
        throw 'Supervisor runtime seed does not match the manifest session identity.'
    }

    $processResolver = New-WinsmuxProcessSnapshotResolver
    $runtimePanes = New-OrchestraSupervisorRuntimePanes -Manifest $manifest -GenerationId $GenerationId -ServerSessionId $ServerSessionId -ProcessResolver $processResolver
    $existingRegistry = Read-WinsmuxRuntimeRegistry -ProjectDir $projectDir
    if (-not (Test-WinsmuxRuntimeRegistryReplacementAllowed -Registry $existingRegistry -ProcessResolver $processResolver)) {
        throw 'A live or unverifiable runtime registry owner already controls this project.'
    }
    $registry = New-WinsmuxRuntimeRegistryDocument -SessionName $SessionName -ServerSessionId $ServerSessionId -BootstrapPaneId $bootstrapPaneId `
        -GenerationId $GenerationId -SupervisorPid $PID -SupervisorProcessStartedAt $SupervisorProcessStartedAt `
        -ExpectedPaneCount $expectedPaneCount -Panes $runtimePanes -LeaseSeconds 15
    Save-WinsmuxRuntimeRegistry -ProjectDir $projectDir -Registry $registry | Out-Null
    return $projectDir
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
    $supervisorProcessStartedAt = Get-WinsmuxRuntimeProcessStartedAt -ProcessId $PID
    if ([string]::IsNullOrWhiteSpace($supervisorProcessStartedAt)) {
        throw 'Supervisor process StartTime is unavailable.'
    }
    $runtimeProjectDir = Initialize-OrchestraSupervisorRuntimeRegistry -ManifestPath $ManifestPath -SessionName $SessionName `
        -GenerationId $GenerationId -ServerSessionId $ServerSessionId -SupervisorProcessStartedAt $supervisorProcessStartedAt

    while ($true) {
        $now = Get-Date
        $runtimeManifest = Get-WinsmuxManifest -ProjectDir $runtimeProjectDir
        $processResolver = New-WinsmuxProcessSnapshotResolver
        $runtimeSnapshot = Get-OrchestraSupervisorRuntimePaneSnapshot -Manifest $runtimeManifest `
            -GenerationId $GenerationId -ServerSessionId $ServerSessionId -ProcessResolver $processResolver
        if ([bool]$runtimeSnapshot.valid) {
            Update-WinsmuxRuntimeRegistryLease -ProjectDir $runtimeProjectDir -GenerationId $GenerationId `
                -SupervisorPid $PID -SupervisorProcessStartedAt $supervisorProcessStartedAt -Panes @($runtimeSnapshot.panes) `
                -Now $now -LeaseSeconds 15 | Out-Null
        } else {
            Write-OrchestraSupervisorWarning -Component 'runtime-registry' -Message ([string]$runtimeSnapshot.diagnostic)
        }

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
    $supervisorProcessStartedAt = Get-WinsmuxRuntimeProcessStartedAt -ProcessId $PID
    try {
        Invoke-OrchestraSupervisorLoop `
            -ManifestPath $ManifestPath `
            -SessionName $SessionName `
            -OperatorPollInterval $OperatorPollInterval `
            -AgentWatchdogInterval $AgentWatchdogInterval `
            -ServerWatchdogInterval $ServerWatchdogInterval `
            -IdleThreshold $IdleThreshold `
            -MaxRestartAttempts $MaxRestartAttempts `
            -RestartWindowMinutes $RestartWindowMinutes
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($supervisorProcessStartedAt)) {
            $runtimeProjectDir = Split-Path (Split-Path $ManifestPath -Parent) -Parent
            try {
                Close-WinsmuxRuntimeRegistry -ProjectDir $runtimeProjectDir -GenerationId $GenerationId `
                    -SupervisorPid $PID -SupervisorProcessStartedAt $supervisorProcessStartedAt | Out-Null
            } catch {
                Write-OrchestraSupervisorWarning -Component 'runtime-registry-close' -Message $_.Exception.Message
            }
        }
    }
}
