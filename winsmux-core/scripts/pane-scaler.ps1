$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'settings.ps1')
# agent-monitor.ps1 is dual-mode: param() binds when dotted and would clobber
# a caller $ProjectDir (DW15 rollback probe, other send helpers).
$monitorCallerVars = [ordered]@{}
foreach ($name in @('ProjectDir', 'SessionName', 'HungThresholdSeconds', 'ContextResetThresholdPercent')) {
    $existing = Get-Variable -Name $name -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        $monitorCallerVars[$name] = [pscustomobject]@{ Present = $true; Value = $existing.Value }
    } else {
        $monitorCallerVars[$name] = [pscustomobject]@{ Present = $false; Value = $null }
    }
}
. (Join-Path $scriptDir 'agent-monitor.ps1')
foreach ($name in @($monitorCallerVars.Keys)) {
    $saved = $monitorCallerVars[$name]
    if ([bool]$saved.Present) {
        Set-Variable -Name $name -Value $saved.Value
    } else {
        Remove-Variable -Name $name -ErrorAction SilentlyContinue
    }
}
. (Join-Path $scriptDir 'builder-worktree.ps1')
. (Join-Path $scriptDir 'clm-safe-io.ps1')
. (Join-Path $scriptDir 'manifest.ps1')

function ConvertFrom-PaneScalerYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = $Value.ToString().Trim()
    if ($text.Length -ge 2) {
        if (($text.StartsWith('"') -and $text.EndsWith('"')) -or
            ($text.StartsWith("'") -and $text.EndsWith("'"))) {
            $text = $text.Substring(1, $text.Length - 2)
        }
    }

    if ($text -eq 'null') {
        return $null
    }

    return $text
}

function ConvertTo-PaneScalerYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    $text = $Value.ToString()
    if ($text -eq '') {
        return '""'
    }

    if ($text -match '^[A-Za-z0-9._/\\:%@+-]+$') {
        return $text
    }

    return "'" + ($text -replace "'", "''") + "'"
}

function Get-PaneScalerCanonicalRole {
    param([AllowNull()][string]$Role, [AllowNull()][string]$Label)

    $candidate = if ([string]::IsNullOrWhiteSpace($Role)) { $Label } else { $Role }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return ''
    }

    switch -Regex ($candidate.Trim()) {
        '^(?i)worker(?:$|[-_:/\s])' { return 'Worker' }
        '^(?i)builder(?:$|[-_:/\s])' { return 'Builder' }
        '^(?i)researcher(?:$|[-_:/\s])' { return 'Researcher' }
        '^(?i)reviewer(?:$|[-_:/\s])' { return 'Reviewer' }
        '^(?i)operator(?:$|[-_:/\s])' { return 'Operator' }
        default { return $candidate.Trim() }
    }
}

function Read-PaneScalerManifest {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Manifest not found: $ManifestPath"
    }

    $content = Get-Content -Path $ManifestPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Manifest is empty: $ManifestPath"
    }

    $parsed = ConvertFrom-ManifestYaml -Content $content
    $manifest = [PSCustomObject]@{
        version   = $parsed.version
        saved_at  = $parsed.saved_at
        session   = $parsed.session
        panes     = $parsed.panes
        tasks     = $parsed.tasks
        worktrees = $parsed.worktrees
    }
    $manifest | Add-Member -NotePropertyName 'Version' -NotePropertyValue $parsed.version -Force
    $manifest | Add-Member -NotePropertyName 'SavedAt' -NotePropertyValue $parsed.saved_at -Force
    $manifest | Add-Member -NotePropertyName 'Session' -NotePropertyValue $parsed.session -Force
    $manifest | Add-Member -NotePropertyName 'Panes' -NotePropertyValue $parsed.panes -Force
    $manifest | Add-Member -NotePropertyName 'Tasks' -NotePropertyValue $parsed.tasks -Force
    $manifest | Add-Member -NotePropertyName 'Worktrees' -NotePropertyValue $parsed.worktrees -Force
    return $manifest
}

function Save-PaneScalerManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)]$Manifest,
        [AllowEmptyString()][string]$ExpectedGenerationId = '',
        [AllowEmptyString()][string]$RuntimePaneId = '',
        [ValidateSet('auto', 'dispatch', 'start_deferred', 'caller_ack', 'stop_transition')][string]$RuntimeOperation = 'auto',
        [switch]$AcceptPlannedPaneSet
    )

    $projectDir = Split-Path (Split-Path $ManifestPath -Parent) -Parent
    $version = Get-MonitorPropertyValue -InputObject $Manifest -Name 'Version' -Default (Get-MonitorPropertyValue -InputObject $Manifest -Name 'version' -Default 1)
    $savedAt = Get-MonitorPropertyValue -InputObject $Manifest -Name 'SavedAt' -Default (Get-MonitorPropertyValue -InputObject $Manifest -Name 'saved_at' -Default '')
    if ([string]::IsNullOrWhiteSpace([string]$savedAt)) {
        $savedAt = Get-Date -Format o
    }

    $canonicalManifest = [PSCustomObject]@{
        version   = $version
        saved_at  = [string]$savedAt
        session   = Get-MonitorPropertyValue -InputObject $Manifest -Name 'Session' -Default (Get-MonitorPropertyValue -InputObject $Manifest -Name 'session' -Default ([PSCustomObject]@{}))
        panes     = Get-MonitorPropertyValue -InputObject $Manifest -Name 'Panes' -Default (Get-MonitorPropertyValue -InputObject $Manifest -Name 'panes' -Default ([ordered]@{}))
        tasks     = Get-MonitorPropertyValue -InputObject $Manifest -Name 'Tasks' -Default (Get-MonitorPropertyValue -InputObject $Manifest -Name 'tasks' -Default ([PSCustomObject]@{ queued = @(); in_progress = @(); completed = @() }))
        worktrees = Get-MonitorPropertyValue -InputObject $Manifest -Name 'Worktrees' -Default (Get-MonitorPropertyValue -InputObject $Manifest -Name 'worktrees' -Default ([ordered]@{}))
    }

    Save-PaneControlManifestDocument -ManifestPath $ManifestPath -Manifest $canonicalManifest `
        -ExpectedGenerationId $ExpectedGenerationId -RuntimePaneId $RuntimePaneId `
        -RuntimeOperation $RuntimeOperation -AcceptPlannedPaneSet:$AcceptPlannedPaneSet
}

function Assert-PaneScalerPaneCountMutationSupported {
    param([Parameter(Mandatory = $true)]$Manifest)

    $version = Get-MonitorPropertyValue -InputObject $Manifest -Name 'Version' -Default (Get-MonitorPropertyValue -InputObject $Manifest -Name 'version' -Default 1)
    if ([int]$version -eq 2) {
        throw 'runtime dispatch refused (manifest_regeneration_required): v2 pane-count changes require a supervisor-owned manifest, registry, and server transition.'
    }
}

function Get-PaneScalerProjectDir {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $projectDir = [string](Get-MonitorPropertyValue -InputObject $Manifest.Session -Name 'project_dir' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($projectDir)) {
        return $projectDir
    }

    return Split-Path (Split-Path $ManifestPath -Parent) -Parent
}

function Get-PaneScalerGitWorktreeDir {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $dotGitPath = Join-Path $ProjectDir '.git'
    if (Test-Path $dotGitPath -PathType Leaf) {
        $raw = (Get-Content -Path $dotGitPath -Raw -Encoding UTF8).Trim()
        if ($raw -match '^gitdir:\s*(.+)$') {
            return [System.IO.Path]::GetFullPath($Matches[1].Trim())
        }
    }

    if (Test-Path $dotGitPath -PathType Container) {
        return (Get-Item -LiteralPath $dotGitPath -Force).FullName
    }

    return $ProjectDir
}

function Get-PaneScalerLaunchCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Model,
        [AllowEmptyString()][string]$ModelSource = '',
        [AllowEmptyString()][string]$ReasoningEffort = '',
        [AllowEmptyString()][string]$McpMode = '',
        [AllowEmptyString()][string]$SlotId = '',
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [string]$RootPath = ''
    )

    return Get-BridgeProviderLaunchCommand `
        -ProviderId $Agent `
        -Model $Model `
        -ModelSource $ModelSource `
        -ReasoningEffort $ReasoningEffort `
        -McpMode $McpMode `
        -SlotId $SlotId `
        -ProjectDir $ProjectDir `
        -GitWorktreeDir $GitWorktreeDir `
        -RootPath $RootPath
}

function Get-PaneScalerBuilderPanes {
    param([Parameter(Mandatory = $true)]$Manifest)

    $builders = [System.Collections.Generic.List[object]]::new()
    foreach ($label in $Manifest.Panes.Keys) {
        $pane = $Manifest.Panes[$label]
        $role = Get-PaneScalerCanonicalRole -Role ([string](Get-MonitorPropertyValue -InputObject $pane -Name 'role' -Default '')) -Label $label
        if ($role -ne 'Builder') {
            continue
        }

        $builders.Add([PSCustomObject]@{
            Label = $label
            Pane  = $pane
        }) | Out-Null
    }

    return @($builders)
}

function Get-PaneScalerBuilderIndex {
    param([Parameter(Mandatory = $true)][string]$Label)

    if ($Label -match '(?i)^builder-(\d+)$') {
        return [int]$Matches[1]
    }

    return 0
}

function Get-PaneScalerNextBuilderLabel {
    param([Parameter(Mandatory = $true)]$Manifest)

    $nextIndex = 1
    foreach ($builderPane in @(Get-PaneScalerBuilderPanes -Manifest $Manifest)) {
        $nextIndex = [Math]::Max($nextIndex, (Get-PaneScalerBuilderIndex -Label $builderPane.Label) + 1)
    }

    return "builder-$nextIndex"
}

function Get-PaneScalerSlotAgentConfig {
    param(
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    if (Get-Command Get-SlotAgentConfig -ErrorAction SilentlyContinue) {
        return Get-SlotAgentConfig -Role 'Builder' -SlotId $SlotId -Settings $Settings -RootPath $ProjectDir
    }

    try {
        return Get-RoleAgentConfig -Role 'Builder' -Settings $Settings -RootPath $ProjectDir
    } catch {
        return [PSCustomObject]@{
            Agent = [string]$Settings.agent
            Model = [string]$Settings.model
        }
    }
}

function Test-PaneScalerParallelRunsAvailable {
    param([AllowNull()]$SlotAgentConfig)

    if ($null -eq $SlotAgentConfig) {
        return $true
    }

    $capabilityAdapter = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'CapabilityAdapter' -Default '')
    $capabilityCommand = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'CapabilityCommand' -Default '')
    if ([string]::IsNullOrWhiteSpace($capabilityAdapter) -and [string]::IsNullOrWhiteSpace($capabilityCommand)) {
        return $true
    }

    return [bool](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'SupportsParallelRuns' -Default $false)
}

function Get-PaneScalerReadinessAgent {
    param(
        [AllowNull()]$SlotAgentConfig,
        [string]$FallbackAgent = ''
    )

    $readinessAgent = ''
    if ($null -ne $SlotAgentConfig) {
        $readinessAgent = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'CapabilityAdapter' -Default '')
        if ([string]::IsNullOrWhiteSpace($readinessAgent)) {
            $readinessAgent = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'Agent' -Default '')
        }
    }
    if ([string]::IsNullOrWhiteSpace($readinessAgent)) {
        $readinessAgent = [string]$FallbackAgent
    }

    return $readinessAgent
}

function New-PaneScalerWorkerLaunchApproval {
    param(
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)]$SlotAgentConfig,
        [bool]$AutoLaunch = $false
    )

    if (Get-Command New-OrchestraWorkerLaunchApproval -ErrorAction SilentlyContinue) {
        return New-OrchestraWorkerLaunchApproval -SlotId $SlotId -SlotAgentConfig $SlotAgentConfig -AutoLaunch:$AutoLaunch
    }

    return [ordered]@{
        packet_type             = 'worker_launch_approval'
        source                  = 'user_approved_worker_config'
        slot_id                 = $SlotId
        worker_backend          = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'WorkerBackend' -Default '')
        worker_role             = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'WorkerRole' -Default '')
        agent                   = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'Agent' -Default '')
        model                   = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'Model' -Default '')
        model_source            = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'ModelSource' -Default '')
        reasoning_effort        = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'ReasoningEffort' -Default '')
        prompt_transport        = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'PromptTransport' -Default '')
        auth_mode               = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'AuthMode' -Default '')
        credential_requirements = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'CredentialRequirements' -Default '')
        execution_profile       = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'ExecutionProfile' -Default '')
        execution_backend       = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'ExecutionBackend' -Default '')
        analysis_posture        = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'AnalysisPosture' -Default '')
        auto_launch             = [bool]$AutoLaunch
    }
}

function New-PaneScalerBuilderWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][int]$BuilderIndex
    )

    $branchName = "worktree-builder-$BuilderIndex"
    $worktreeRoot = Join-Path $ProjectDir '.worktrees'
    $worktreePath = Join-Path $worktreeRoot "builder-$BuilderIndex"
    $worktreeRelativePath = ".worktrees/builder-$BuilderIndex"

    New-Item -ItemType Directory -Path $worktreeRoot -Force | Out-Null

    if (Test-Path -LiteralPath $worktreePath) {
        throw "Builder worktree path already exists: $worktreePath"
    }

    $existingBranch = Invoke-BuilderWorktreeGit -ProjectDir $ProjectDir -Arguments @('branch', '--list', '--format', '%(refname:short)', $branchName)
    if (-not [string]::IsNullOrWhiteSpace($existingBranch.Output)) {
        throw "Builder worktree branch already exists: $branchName"
    }

    Invoke-BuilderWorktreeGit -ProjectDir $ProjectDir -Arguments @('worktree', 'add', $worktreeRelativePath, '-b', $branchName) | Out-Null

    return [PSCustomObject]@{
        BranchName     = $branchName
        WorktreePath   = $worktreePath
        GitWorktreeDir = Get-PaneScalerGitWorktreeDir -ProjectDir $worktreePath
    }
}

function Remove-PaneScalerBuilderWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [AllowNull()][string]$WorktreePath,
        [AllowNull()][string]$BranchName
    )

    $worktreeRoot = Join-Path $ProjectDir '.worktrees'
    if (-not [string]::IsNullOrWhiteSpace($WorktreePath)) {
        $resolvedPath = [System.IO.Path]::GetFullPath($WorktreePath)
        if (-not (Test-BuilderWorktreePathUnderRoot -Path $resolvedPath -Root $worktreeRoot)) {
            throw "Refusing to remove Builder worktree outside ${worktreeRoot}: $resolvedPath"
        }

        if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
            $status = Invoke-BuilderWorktreeGit -ProjectDir $resolvedPath -Arguments @('status', '--porcelain', '--untracked-files=all')
            if (-not [string]::IsNullOrWhiteSpace([string]$status.Output)) {
                throw "Refusing to remove Builder worktree with uncommitted changes: $resolvedPath"
            }

            Invoke-BuilderWorktreeGit -ProjectDir $ProjectDir -Arguments @('worktree', 'remove', $resolvedPath) | Out-Null
            if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
                throw "Builder worktree removal did not remove the directory: $resolvedPath"
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($BranchName)) {
        Invoke-BuilderWorktreeGit -ProjectDir $ProjectDir -Arguments @('branch', '-d', $BranchName) | Out-Null
    }
}

function Get-PaneWorkload {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        $Settings = $null,
        [int]$HungThreshold = 120
    )

    $manifest = Read-PaneScalerManifest -ManifestPath $ManifestPath
    $projectDir = Get-PaneScalerProjectDir -Manifest $manifest -ManifestPath $ManifestPath
    if ($null -eq $Settings) {
        $Settings = Get-BridgeSettings -RootPath $projectDir
    }

    $builderPanes = @(Get-PaneScalerBuilderPanes -Manifest $manifest)
    $statusResults = [System.Collections.Generic.List[object]]::new()
    $busyCount = 0

    foreach ($builderPane in $builderPanes) {
        $label = [string]$builderPane.Label
        $pane = $builderPane.Pane
        $paneId = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'pane_id' -Default '')
        if ([string]::IsNullOrWhiteSpace($paneId)) {
            continue
        }

        $roleAgentConfig = $null
        if (Get-Command Get-SlotAgentConfig -ErrorAction SilentlyContinue) {
            $roleAgentConfig = Get-SlotAgentConfig -Role 'Builder' -SlotId $label -Settings $Settings -RootPath $projectDir
        } else {
            try {
                $roleAgentConfig = Get-RoleAgentConfig -Role 'Builder' -Settings $Settings -RootPath $projectDir
            } catch {
                $roleAgentConfig = [PSCustomObject]@{
                    Agent = [string]$Settings.agent
                    Model = [string]$Settings.model
                }
            }
        }

        $statusAgent = Get-PaneScalerReadinessAgent -SlotAgentConfig $roleAgentConfig
        $status = Get-PaneAgentStatus -PaneId $paneId -Agent $statusAgent -Role 'Builder' -HungThreshold $HungThreshold
        $statusName = [string](Get-MonitorPropertyValue -InputObject $status -Name 'Status' -Default '')
        if ($statusName -in @('busy', 'approval_waiting')) {
            $busyCount++
        }

        $statusResults.Add([PSCustomObject]@{
            Label      = $label
            PaneId     = $paneId
            Status     = $statusName
            ExitReason = [string](Get-MonitorPropertyValue -InputObject $status -Name 'ExitReason' -Default '')
        }) | Out-Null
    }

    $totalCount = $statusResults.Count
    $busyRatio = if ($totalCount -gt 0) {
        [double]($busyCount / $totalCount)
    } else {
        0.0
    }

    return [PSCustomObject]@{
        Manifest     = $manifest
        ProjectDir   = $projectDir
        SessionName  = [string](Get-MonitorPropertyValue -InputObject $manifest.Session -Name 'name' -Default 'winsmux-orchestra')
        BusyPanes    = $busyCount
        TotalPanes   = $totalCount
        BusyRatio    = $busyRatio
        BuilderCount = $totalCount
        Results      = @($statusResults)
    }
}


function Get-PaneScalerSeedPane {
    param([Parameter(Mandatory = $true)]$Manifest)

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($label in @($Manifest.Panes.Keys)) {
        $pane = $Manifest.Panes[$label]
        $paneId = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'pane_id' -Default '')
        if ([string]::IsNullOrWhiteSpace($paneId)) {
            continue
        }
        $role = Get-PaneScalerCanonicalRole -Role ([string](Get-MonitorPropertyValue -InputObject $pane -Name 'role' -Default '')) -Label $label
        $candidates.Add([PSCustomObject]@{
            Label  = [string]$label
            PaneId = $paneId
            Role   = $role
            Pane   = $pane
        }) | Out-Null
    }

    $workerSeed = @($candidates | Where-Object { $_.Role -eq 'Worker' } | Select-Object -Last 1)
    if ($workerSeed.Count -gt 0) {
        return $workerSeed[0]
    }
    $any = @($candidates | Select-Object -Last 1)
    if ($any.Count -eq 0) {
        throw 'Cannot spawn a Worker pane because no live seed pane was found.'
    }
    return $any[0]
}

function Get-PaneScalerWorkerIndex {
    param([Parameter(Mandatory = $true)][string]$Label)

    if ($Label -match '(?i)^worker-(\d+)$') {
        return [int]$Matches[1]
    }
    return 0
}

function New-PaneScalerWorkerWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][int]$WorkerIndex
    )

    if (Get-Command New-BuilderWorktree -ErrorAction SilentlyContinue) {
        return New-BuilderWorktree -ProjectDir $ProjectDir -BuilderIndex $WorkerIndex
    }

    return New-PaneScalerBuilderWorktree -ProjectDir $ProjectDir -BuilderIndex $WorkerIndex
}

function Update-PaneScalerLiveExpectedPaneCount {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [AllowEmptyString()][string]$ManifestPath = '',
        [AllowEmptyString()][string]$ExpectedGenerationId = '',
        [AllowEmptyString()][string]$RuntimePaneId = '',
        [bool]$RestoreOnFailure = $true
    )

    $liveCount = @($Manifest.Panes.Keys).Count
    if (-not [string]::IsNullOrWhiteSpace($ManifestPath) -and (Get-Command Save-OrchestraLivePaneSetTransition -ErrorAction SilentlyContinue)) {
        return Save-OrchestraLivePaneSetTransition -ManifestPath $ManifestPath -Manifest $Manifest `
            -ProjectDir $ProjectDir -ExpectedGenerationId $ExpectedGenerationId `
            -RuntimePaneId $RuntimePaneId -RestoreOnFailure $RestoreOnFailure
    }
    if (Get-Command Set-OrchestraLiveExpectedPaneCount -ErrorAction SilentlyContinue) {
        return Set-OrchestraLiveExpectedPaneCount -Manifest $Manifest -ExpectedPaneCount $liveCount -ProjectDir $ProjectDir
    }

    if ($liveCount -lt 1) {
        throw 'Live expected pane count must be 1 or greater.'
    }
    $session = $Manifest.Session
    if ($null -ne $session) {
        if ($session -is [System.Collections.IDictionary]) {
            $session['expected_pane_count'] = $liveCount
        } else {
            $session | Add-Member -NotePropertyName 'expected_pane_count' -NotePropertyValue $liveCount -Force
        }
    }
    return $liveCount
}

function Test-OrchestraArchiveRemovesLastRequiredWorker {
    param(
        [AllowNull()]$Manifest = $null,
        [AllowEmptyString()][string]$Label = ''
    )

    $min = 1
    if (Get-Command Get-OrchestraMinLiveWorkerPaneCount -ErrorAction SilentlyContinue) {
        $min = [int](Get-OrchestraMinLiveWorkerPaneCount)
    }
    $liveWorkers = 0
    if (Get-Command Get-OrchestraLiveWorkerRolePaneCount -ErrorAction SilentlyContinue) {
        $liveWorkers = [int](Get-OrchestraLiveWorkerRolePaneCount -Manifest $Manifest)
    }
    if ($liveWorkers -gt $min) {
        return $false
    }

    if ($null -eq $Manifest -or [string]::IsNullOrWhiteSpace($Label)) {
        return ($liveWorkers -le $min)
    }

    $map = ConvertTo-ManifestPropertyMap -Value (
        Get-WinsmuxRuntimeValue -InputObject $Manifest -Name 'panes' -Default (
            Get-WinsmuxRuntimeValue -InputObject $Manifest -Name 'Panes' -Default $null
        )
    )
    if (-not $map.Contains($Label)) {
        return $false
    }
    $pane = $map[$Label]
    $paneId = [string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'pane_id' -Default '')
    $role = [string](Get-OrchestraCanonicalPaneRole -Pane $pane -Label $Label)
    return ($role -eq 'Worker' -and -not [string]::IsNullOrWhiteSpace($paneId))
}

function Wait-OrchestraSpawnAgentReady {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Agent,
        [int]$TimeoutSeconds = 60,
        [int]$PollMilliseconds = 2000
    )

    if (-not (Get-Command Get-PaneAgentStatus -ErrorAction SilentlyContinue)) {
        throw 'Worker spawn requires Get-PaneAgentStatus after the bootstrap marker is present.'
    }

    $timeoutSeconds = [Math]::Max(0, $TimeoutSeconds)
    $pollMilliseconds = [Math]::Max(1, $PollMilliseconds)
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ($true) {
        $status = Get-PaneAgentStatus -PaneId $PaneId -Agent $Agent -Role 'Worker'
        $statusName = [string](Get-MonitorPropertyValue -InputObject $status -Name 'Status' -Default '')
        if ($statusName -ceq 'ready') {
            return
        }

        if ((Get-Date) -ge $deadline) {
            throw ("Worker spawn timed out waiting for agent ready in pane {0}." -f $PaneId)
        }

        Start-Sleep -Milliseconds $pollMilliseconds
    }
}

function Add-OrchestraWorkerPane {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SlotId,
        $Settings = $null,
        $SlotAgentConfig = $null,
        $Assignment = $null,
        $Projection = $null,
        [int]$AgentReadyTimeoutSeconds = 60,
        [int]$AgentReadyPollMilliseconds = 2000
    )

    $manifest = Read-PaneScalerManifest -ManifestPath $ManifestPath
    $expectedGenerationId = [string](Get-MonitorPropertyValue -InputObject $manifest.Session -Name 'generation_id' -Default '')
    $serverSessionId = [string](Get-MonitorPropertyValue -InputObject $manifest.Session -Name 'server_session_id' -Default '')
    $startupToken = [string](Get-MonitorPropertyValue -InputObject $manifest.Session -Name 'startup_token' -Default '')
    $sessionName = [string](Get-MonitorPropertyValue -InputObject $manifest.Session -Name 'name' -Default 'winsmux-orchestra')
    if ([string]::IsNullOrWhiteSpace($sessionName)) {
        $sessionName = 'winsmux-orchestra'
    }
    $projectDir = Get-PaneScalerProjectDir -Manifest $manifest -ManifestPath $ManifestPath
    if ($null -eq $Settings) {
        $Settings = Get-BridgeSettings -RootPath $projectDir
    }
    if ([string]::IsNullOrWhiteSpace($expectedGenerationId) -or [string]::IsNullOrWhiteSpace($serverSessionId)) {
        throw 'Worker spawn requires a verified session generation and server session identity.'
    }
    if ((-not (Get-Command New-OrchestraPaneBootstrapPlan -ErrorAction SilentlyContinue)) -or
        (-not (Get-Command Get-OrchestraPaneBootstrapMarkerPath -ErrorAction SilentlyContinue)) -or
        (-not (Get-Command Start-OrchestraPaneBootstrap -ErrorAction SilentlyContinue))) {
        if (Get-Command Import-Task789OrchestraHelpers -ErrorAction SilentlyContinue) {
            Import-Task789OrchestraHelpers -IncludePaneScaler
        }
    }
    if ((-not (Get-Command New-OrchestraPaneBootstrapPlan -ErrorAction SilentlyContinue)) -or
        (-not (Get-Command Get-OrchestraPaneBootstrapMarkerPath -ErrorAction SilentlyContinue)) -or
        (-not (Get-Command Start-OrchestraPaneBootstrap -ErrorAction SilentlyContinue))) {
        throw 'Worker spawn requires the orchestra bootstrap plan helpers.'
    }

    if ([string]::IsNullOrWhiteSpace($SlotId)) {
        throw 'Worker spawn requires a Team Profile slot id.'
    }
    if ($manifest.Panes.Contains($SlotId)) {
        $existing = $manifest.Panes[$SlotId]
        $existingPaneId = [string](Get-MonitorPropertyValue -InputObject $existing -Name 'pane_id' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($existingPaneId)) {
            return [PSCustomObject]@{
                Changed = $false
                Action  = 'already_live'
                Label   = $SlotId
                PaneId  = $existingPaneId
            }
        }
    }

    if ($null -eq $SlotAgentConfig -and $null -ne $Assignment -and (Get-Command New-TeamProfileSlotAgentConfig -ErrorAction SilentlyContinue)) {
        $SlotAgentConfig = New-TeamProfileSlotAgentConfig -Role 'Worker' -SlotId $SlotId -Assignment $Assignment -Settings $Settings -RootPath $projectDir
    }

    $seed = Get-PaneScalerSeedPane -Manifest $manifest
    $workerIndex = Get-PaneScalerWorkerIndex -Label $SlotId
    if ($workerIndex -lt 1) {
        $workerIndex = @($manifest.Panes.Keys).Count + 1
    }

    $manifestVersion = ConvertTo-WinsmuxRuntimeInteger -Value (
        Get-MonitorPropertyValue -InputObject $manifest -Name 'version' -Default (
            Get-MonitorPropertyValue -InputObject $manifest -Name 'Version' -Default $null
        )
    )
    if ($manifestVersion -eq 2) {
        if (-not (Get-Command Test-PaneControlRuntimeContext -ErrorAction SilentlyContinue)) {
            throw 'Worker spawn requires live runtime validation before the server pane set is mutated.'
        }
        $seedEntry = $null
        if (Get-Command New-OrchestraLiveTransitionManifestEntry -ErrorAction SilentlyContinue) {
            $seedEntry = New-OrchestraLiveTransitionManifestEntry -Manifest $manifest -RuntimePaneId $seed.PaneId
        }
        if ($null -eq $seedEntry) {
            throw 'Worker spawn requires a tracked seed pane in the current v2 pane set.'
        }
        $preflight = Test-PaneControlRuntimeContext -ProjectDir $projectDir -ManifestEntry $seedEntry -Operation stop_transition
        if ($null -eq $preflight -or -not [bool]$preflight.valid) {
            $reasonCode = [string](Get-MonitorPropertyValue -InputObject $preflight -Name 'reason_code' -Default 'runtime_target_mismatch')
            $diagnostic = [string](Get-MonitorPropertyValue -InputObject $preflight -Name 'diagnostic' -Default 'Current live pane set is not consistent.')
            throw ("Worker spawn refused ({0}): {1}" -f $reasonCode, $diagnostic)
        }
    }

    $worktree = $null
    $newPaneId = ''
    try {
        $worktree = New-PaneScalerWorkerWorktree -ProjectDir $projectDir -WorkerIndex $workerIndex
        if (Get-Command Invoke-TeamProfileLaunchProjection -ErrorAction SilentlyContinue) {
            try {
                $worktreeProjection = Invoke-TeamProfileLaunchProjection -ProjectDir $projectDir -SessionId $sessionName -SlotId $SlotId -Worktree $worktree.WorktreePath -ReadWriteScope 'session' -Force
                if ($null -ne $worktreeProjection) {
                    $Projection = $worktreeProjection
                }
            } catch {
                # Keep the caller projection when regeneration after worktree is unavailable.
            }
        }
        $splitOutput = Invoke-MonitorWinsmux -Arguments @('split-window', '-t', $seed.PaneId, '-h', '-c', $worktree.WorktreePath, '-P', '-F', '#{pane_id}') -CaptureOutput
        $newPaneId = (($splitOutput | Out-String).Trim() -split "\r?\n" | Where-Object { $_ -match '^%\d+$' } | Select-Object -Last 1)
        if ([string]::IsNullOrWhiteSpace($newPaneId)) {
            throw 'winsmux split-window did not return a pane id.'
        }

        $agent = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'Agent' -Default ([string]$Settings.agent))
        $model = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'Model' -Default ([string]$Settings.model))
        $modelSource = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'ModelSource' -Default '')
        $effort = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'ReasoningEffort' -Default '')
        $mcpMode = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'McpMode' -Default '')
        $workerBackend = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'WorkerBackend' -Default 'local')
        if ($null -ne $Assignment) {
            $assignmentBackend = [string](Get-MonitorPropertyValue -InputObject $Assignment -Name 'worker_backend' -Default '')
            if ([string]::IsNullOrWhiteSpace($assignmentBackend)) {
                $assignmentBackend = [string](Get-MonitorPropertyValue -InputObject $Assignment -Name 'worker-backend' -Default '')
            }
            if (-not [string]::IsNullOrWhiteSpace($assignmentBackend)) {
                $workerBackend = $assignmentBackend
            }
        }

        Wait-MonitorPaneShellReady -PaneId $newPaneId
        if ([string]::IsNullOrWhiteSpace($agent)) {
            throw 'Worker spawn requires a Team Profile agent for the orchestra bootstrap launch command.'
        }
        $launchCommand = Get-PaneScalerLaunchCommand -Agent $agent -Model $model -ModelSource $modelSource -ReasoningEffort $effort -McpMode $mcpMode -SlotId $SlotId -ProjectDir $worktree.WorktreePath -GitWorktreeDir $worktree.GitWorktreeDir -RootPath $projectDir
        if ([string]::IsNullOrWhiteSpace($launchCommand)) {
            throw 'Worker spawn requires a non-empty orchestra bootstrap launch command.'
        }
        if ($null -ne $Projection) {
            if (-not (Get-Command Add-TeamProfileBundleToLaunchCommand -ErrorAction SilentlyContinue)) {
                if (Get-Command Import-Task789OrchestraHelpers -ErrorAction SilentlyContinue) {
                    Import-Task789OrchestraHelpers -IncludePaneScaler
                }
            }
            if (-not (Get-Command Add-TeamProfileBundleToLaunchCommand -ErrorAction SilentlyContinue)) {
                throw 'Worker spawn requires Add-TeamProfileBundleToLaunchCommand to attach the Team Profile bundle.'
            }
            $launchCommand = Add-TeamProfileBundleToLaunchCommand -LaunchCommand $launchCommand -Projection $Projection -ProjectDir $projectDir
        }

        $paneTitle = [string](Get-MonitorPropertyValue -InputObject $SlotAgentConfig -Name 'PaneTitle' -Default $SlotId)
        if ([string]::IsNullOrWhiteSpace($paneTitle)) {
            $paneTitle = $SlotId
        }
        Invoke-MonitorWinsmux -Arguments @('select-pane', '-t', $newPaneId, '-T', $paneTitle) | Out-Null
        $runtimeWorkerRole = 'worker'
        if (Get-Command Resolve-WinsmuxRuntimeRole -ErrorAction SilentlyContinue) {
            $runtimeWorkerRole = Resolve-WinsmuxRuntimeRole -WorkerRole 'worker' -CanonicalRole 'Worker'
        }
        $capabilityAdapter = Get-PaneScalerReadinessAgent -SlotAgentConfig $SlotAgentConfig -FallbackAgent $agent
        $approvedLaunch = $null
        if ($null -ne $SlotAgentConfig) {
            $approvedLaunch = New-PaneScalerWorkerLaunchApproval -SlotId $SlotId -SlotAgentConfig $SlotAgentConfig -AutoLaunch $true
        }
        $cleanPtyEnv = [pscustomobject]@{ Environment = [ordered]@{} }
        if (Get-Command Get-CleanPtyEnv -ErrorAction SilentlyContinue) {
            try {
                $allowedEnvironment = $null
                if (Get-Command Get-WinsmuxPaneEnvironment -ErrorAction SilentlyContinue) {
                    $allowedEnvironment = Get-WinsmuxPaneEnvironment -Role 'Worker' -PaneId $newPaneId -SessionName $sessionName -ProjectDir $projectDir -SlotId $SlotId -BuilderWorktreePath $worktree.WorktreePath -AssignedBranch $worktree.BranchName -GitWorktreeDir $worktree.GitWorktreeDir
                }
                if ($null -ne $allowedEnvironment) {
                    $cleanPtyEnv = Get-CleanPtyEnv -AllowedEnvironment $allowedEnvironment
                }
            } catch {
                $cleanPtyEnv = [pscustomobject]@{ Environment = [ordered]@{} }
            }
        }

        $bootstrapPlanPath = New-OrchestraPaneBootstrapPlan `
            -ProjectDir $projectDir `
            -PaneId $newPaneId `
            -Label $SlotId `
            -SlotId $SlotId `
            -Role 'Worker' `
            -WorkerBackend $workerBackend `
            -WorkerRole $runtimeWorkerRole `
            -PaneTitle $paneTitle `
            -GenerationId $expectedGenerationId `
            -ServerSessionId $serverSessionId `
            -Agent $agent `
            -Model $model `
            -StartupToken $startupToken `
            -LaunchDir $worktree.WorktreePath `
            -CleanPtyEnv $cleanPtyEnv `
            -LaunchCommand $launchCommand `
            -ApprovedLaunch $approvedLaunch
        Start-OrchestraPaneBootstrap -PaneId $newPaneId -PlanPath $bootstrapPlanPath -SessionName $sessionName
        $bootstrapMarkerPath = Get-OrchestraPaneBootstrapMarkerPath -PlanPath $bootstrapPlanPath -GenerationId $expectedGenerationId
        $runtimeReady = $false
        $paneStatus = 'deferred_starting'
        if (-not [string]::IsNullOrWhiteSpace($bootstrapMarkerPath)) {
            for ($waitAttempt = 1; $waitAttempt -le 20; $waitAttempt++) {
                if (Test-Path -LiteralPath $bootstrapMarkerPath -PathType Leaf) {
                    break
                }
                Start-Sleep -Milliseconds 100
            }
            if (Test-Path -LiteralPath $bootstrapMarkerPath -PathType Leaf) {
                $markerPid = $null
                try {
                    $marker = Get-Content -LiteralPath $bootstrapMarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if (Get-Command ConvertTo-WinsmuxRuntimeInteger -ErrorAction SilentlyContinue) {
                        $markerPid = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $marker -Name 'bootstrap_pid' -Default $null)
                    } else {
                        $markerPid = [int](Get-MonitorPropertyValue -InputObject $marker -Name 'bootstrap_pid' -Default 0)
                    }
                } catch {
                    $markerPid = $null
                }
                if ($null -ne $markerPid -and $markerPid -gt 0) {
                    $readinessAgent = Get-PaneScalerReadinessAgent -SlotAgentConfig $SlotAgentConfig -FallbackAgent $agent
                    Wait-OrchestraSpawnAgentReady -PaneId $newPaneId -Agent $readinessAgent `
                        -TimeoutSeconds $AgentReadyTimeoutSeconds `
                        -PollMilliseconds $AgentReadyPollMilliseconds
                    $runtimeReady = $true
                    $paneStatus = 'ready'
                }
            }
        }

        $newPane = [ordered]@{
            label                  = $SlotId
            slot_id                = $SlotId
            pane_id                = $newPaneId
            role                   = 'Worker'
            worker_role            = $runtimeWorkerRole
            worker_backend         = $workerBackend
            title                  = $paneTitle
            exec_mode              = 'false'
            launch_dir             = $worktree.WorktreePath
            builder_branch         = $worktree.BranchName
            builder_worktree_path  = $worktree.WorktreePath
            task                   = $null
            status                 = $paneStatus
            runtime_ready          = $runtimeReady
            bootstrap_plan_path    = $bootstrapPlanPath
            bootstrap_marker_path  = $bootstrapMarkerPath
        }
        if ($null -ne $approvedLaunch) {
            $newPane['approved_launch'] = $approvedLaunch
        }
        if (-not [string]::IsNullOrWhiteSpace($capabilityAdapter)) {
            $newPane['capability_adapter'] = $capabilityAdapter
        }
        if ($null -ne $Projection) {
            $projRoot = $Projection
            $nestedProjection = Get-WinsmuxRuntimeValue -InputObject $Projection -Name 'projection'
            if ($null -ne $nestedProjection) {
                $projRoot = $nestedProjection
            }
            $projectedPane = Get-WinsmuxRuntimeValue -InputObject $projRoot -Name 'pane'
            $projectedAssignment = Get-WinsmuxRuntimeValue -InputObject $projectedPane -Name 'assignment'
            $projectedBundle = Get-WinsmuxRuntimeValue -InputObject $projectedPane -Name 'prompt_bundle'
            if ($null -ne $projectedAssignment) {
                $newPane['assignment'] = $projectedAssignment
            }
            if ($null -ne $projectedBundle) {
                $newPane['prompt_bundle'] = $projectedBundle
            }
            $projectedSession = Get-WinsmuxRuntimeValue -InputObject $projRoot -Name 'session'
            $projectedTeamProfile = Get-WinsmuxRuntimeValue -InputObject $projectedSession -Name 'team_profile'
            if ($null -ne $projectedTeamProfile) {
                if ($null -eq $manifest.Session) {
                    $manifest | Add-Member -NotePropertyName 'Session' -NotePropertyValue ([pscustomobject]@{}) -Force
                }
                $manifest.Session | Add-Member -NotePropertyName 'team_profile' -NotePropertyValue $projectedTeamProfile -Force
            }
        }
        $paneObject = [PSCustomObject]@{}
        foreach ($entry in $newPane.GetEnumerator()) {
            Add-Member -InputObject $paneObject -MemberType NoteProperty -Name $entry.Key -Value $entry.Value
        }
        $manifest.Panes[$SlotId] = $paneObject
        $manifest.SavedAt = Get-Date -Format o
        Update-PaneScalerLiveExpectedPaneCount -Manifest $manifest -ProjectDir $projectDir `
            -ManifestPath $ManifestPath -ExpectedGenerationId $expectedGenerationId `
            -RuntimePaneId $seed.PaneId -RestoreOnFailure $true | Out-Null

        return [PSCustomObject]@{
            Changed      = $true
            Action       = 'spawn_worker'
            Label        = $SlotId
            PaneId       = $newPaneId
            WorktreePath = $worktree.WorktreePath
            BranchName   = $worktree.BranchName
        }
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($newPaneId)) {
            try {
                Invoke-MonitorWinsmux -Arguments @('kill-pane', '-t', $newPaneId) | Out-Null
            } catch {
            }
        }
        if ($null -ne $worktree) {
            try {
                Remove-PaneScalerBuilderWorktree -ProjectDir $projectDir -WorktreePath $worktree.WorktreePath -BranchName $worktree.BranchName
            } catch {
            }
        }
        throw
    }
}

function Test-OrchestraLiveServerPanePresent {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    if ([string]::IsNullOrWhiteSpace($PaneId) -or [string]::IsNullOrWhiteSpace($SessionName)) {
        return $null
    }

    try {
        $format = "#{session_id}`t#{session_name}`t#{pane_id}`t#{pane_title}"
        $output = $null
        if (Get-Command Invoke-PaneControlWinsmux -ErrorAction SilentlyContinue) {
            $output = Invoke-PaneControlWinsmux -Arguments @('list-panes', '-a', '-t', $SessionName, '-F', $format)
        } elseif (Get-Command Invoke-MonitorWinsmux -ErrorAction SilentlyContinue) {
            $output = Invoke-MonitorWinsmux -Arguments @('list-panes', '-a', '-t', $SessionName, '-F', $format) -CaptureOutput
        } else {
            return $null
        }

        foreach ($line in @((($output | Out-String).Trim()) -split "\r?\n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split "`t", 4
            if ($parts.Count -ge 3 -and $parts[2] -ceq $PaneId) {
                return $true
            }
            if ($line.Trim() -ceq $PaneId) {
                return $true
            }
        }
        return $false
    } catch {
        return $null
    }
}

function Remove-OrchestraWorkerPane {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$Label,
        $Settings = $null
    )

    $manifest = Read-PaneScalerManifest -ManifestPath $ManifestPath
    $expectedGenerationId = [string](Get-MonitorPropertyValue -InputObject $manifest.Session -Name 'generation_id' -Default '')
    $sessionName = [string](Get-MonitorPropertyValue -InputObject $manifest.Session -Name 'name' -Default 'winsmux-orchestra')
    if ([string]::IsNullOrWhiteSpace($sessionName)) {
        $sessionName = 'winsmux-orchestra'
    }
    $projectDir = Get-PaneScalerProjectDir -Manifest $manifest -ManifestPath $ManifestPath
    if (-not $manifest.Panes.Contains($Label)) {
        return [PSCustomObject]@{
            Changed = $false
            Action  = 'no_change'
            Reason  = 'pane_not_live'
            Label   = $Label
        }
    }

    $pane = $manifest.Panes[$Label]
    $canonicalRole = ''
    if (Get-Command Get-OrchestraCanonicalPaneRole -ErrorAction SilentlyContinue) {
        $canonicalRole = [string](Get-OrchestraCanonicalPaneRole -Pane $pane -Label $Label)
    } else {
        $canonicalRole = [string](Get-PaneScalerCanonicalRole -Role ([string](Get-MonitorPropertyValue -InputObject $pane -Name 'role' -Default '')) -Label $Label)
    }
    if ($canonicalRole -cne 'Worker') {
        return [PSCustomObject]@{
            Changed = $false
            Action  = 'no_change'
            Reason  = 'archive_role_not_worker'
            Label   = $Label
        }
    }
    if (Test-OrchestraArchiveRemovesLastRequiredWorker -Manifest $manifest -Label $Label) {
        return [PSCustomObject]@{
            Changed = $false
            Action  = 'no_change'
            Reason  = 'last_required_worker'
            Label   = $Label
        }
    }

    $paneId = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'pane_id' -Default '')
    $worktreePath = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'builder_worktree_path' -Default '')
    $branchName = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'builder_branch' -Default '')
    $manifestVersion = ConvertTo-WinsmuxRuntimeInteger -Value (
        Get-MonitorPropertyValue -InputObject $manifest -Name 'version' -Default (
            Get-MonitorPropertyValue -InputObject $manifest -Name 'Version' -Default $null
        )
    )
    if ($manifestVersion -eq 2 -and -not [string]::IsNullOrWhiteSpace($paneId) -and
        (Get-Command Test-PaneControlRuntimeContext -ErrorAction SilentlyContinue)) {
        $ownedEntry = $null
        if (Get-Command New-OrchestraLiveTransitionManifestEntry -ErrorAction SilentlyContinue) {
            $ownedEntry = New-OrchestraLiveTransitionManifestEntry -Manifest $manifest -RuntimePaneId $paneId
        }
        if ($null -eq $ownedEntry) {
            return [PSCustomObject]@{
                Changed = $false
                Action  = 'no_change'
                Reason  = 'runtime_target_mismatch'
                Label   = $Label
            }
        }
        $preflight = Test-PaneControlRuntimeContext -ProjectDir $projectDir -ManifestEntry $ownedEntry -Operation stop_transition
        if ($null -eq $preflight -or -not [bool]$preflight.valid) {
            $reasonCode = [string](Get-MonitorPropertyValue -InputObject $preflight -Name 'reason_code' -Default 'runtime_target_mismatch')
            return [PSCustomObject]@{
                Changed = $false
                Action  = 'no_change'
                Reason  = $reasonCode
                Label   = $Label
            }
        }
    }

    [void]$manifest.Panes.Remove($Label)
    $manifest.SavedAt = Get-Date -Format o
    $remainingPaneId = ''
    foreach ($remainingLabel in @($manifest.Panes.Keys | Sort-Object)) {
        $remainingId = [string](Get-MonitorPropertyValue -InputObject $manifest.Panes[$remainingLabel] -Name 'pane_id' -Default '')
        if ($remainingId -cmatch '^%[0-9]+$') {
            $remainingPaneId = $remainingId
            break
        }
    }

    $serverRemoved = $false
    if ([string]::IsNullOrWhiteSpace($paneId)) {
        $serverRemoved = $true
    } else {
        $killThrew = $false
        try {
            Invoke-MonitorWinsmux -Arguments @('kill-pane', '-t', $paneId) | Out-Null
        } catch {
            $killThrew = $true
        }
        $stillPresent = Test-OrchestraLiveServerPanePresent -PaneId $paneId -SessionName $sessionName
        if ($stillPresent -eq $true) {
            throw ("archive-pane kill-pane failed; pane {0} is still live." -f $paneId)
        }
        if ($killThrew -and $stillPresent -ne $false) {
            throw ("archive-pane kill-pane failed; live presence of pane {0} is unconfirmed." -f $paneId)
        }
        $serverRemoved = $true
    }

    $restoreOnFailure = -not $serverRemoved
    $persistError = $null
    try {
        Update-PaneScalerLiveExpectedPaneCount -Manifest $manifest -ProjectDir $projectDir `
            -ManifestPath $ManifestPath -ExpectedGenerationId $expectedGenerationId `
            -RuntimePaneId $remainingPaneId -RestoreOnFailure $restoreOnFailure | Out-Null
    } catch {
        $persistError = $_
        if ($serverRemoved) {
            try {
                Update-PaneScalerLiveExpectedPaneCount -Manifest $manifest -ProjectDir $projectDir `
                    -ManifestPath $ManifestPath -ExpectedGenerationId $expectedGenerationId `
                    -RuntimePaneId $remainingPaneId -RestoreOnFailure $false | Out-Null
                $persistError = $null
            } catch {
                $persistError = $_
            }
        }
    }

    if ($serverRemoved -and -not [string]::IsNullOrWhiteSpace($worktreePath)) {
        try {
            Remove-PaneScalerBuilderWorktree -ProjectDir $projectDir -WorktreePath $worktreePath -BranchName $branchName
        } catch {
        }
    }

    if ($null -ne $persistError) {
        if ($serverRemoved) {
            throw ("archive-pane removed pane {0} but failed to persist the new pane set: {1}" -f $paneId, $persistError.Exception.Message)
        }
        throw $persistError
    }

    return [PSCustomObject]@{
        Changed      = $true
        Action       = 'archive'
        Label        = $Label
        PaneId       = $paneId
        WorktreePath = $worktreePath
        BranchName   = $branchName
    }
}

function Add-OrchestraPane {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        $Settings = $null,
        [ValidateSet('Builder', 'Worker')][string]$Role = 'Builder',
        [AllowEmptyString()][string]$SlotId = '',
        $SlotAgentConfig = $null,
        $Assignment = $null,
        $Projection = $null
    )

    if ($Role -eq 'Worker') {
        return Add-OrchestraWorkerPane -ManifestPath $ManifestPath -SlotId $SlotId -Settings $Settings -SlotAgentConfig $SlotAgentConfig -Assignment $Assignment -Projection $Projection
    }

    $manifest = Read-PaneScalerManifest -ManifestPath $ManifestPath
    Assert-PaneScalerPaneCountMutationSupported -Manifest $manifest
    $expectedGenerationId = [string](Get-MonitorPropertyValue -InputObject $manifest.Session -Name 'generation_id' -Default '')
    $projectDir = Get-PaneScalerProjectDir -Manifest $manifest -ManifestPath $ManifestPath
    if ($null -eq $Settings) {
        $Settings = Get-BridgeSettings -RootPath $projectDir
    }

    $builderPanes = @(Get-PaneScalerBuilderPanes -Manifest $manifest)
    if ($builderPanes.Count -eq 0) {
        throw 'Cannot add a Builder pane because no existing Builder pane was found.'
    }

    $newLabel = Get-PaneScalerNextBuilderLabel -Manifest $manifest
    $nextIndex = Get-PaneScalerBuilderIndex -Label $newLabel

    $seedPane = $builderPanes | Sort-Object { Get-PaneScalerBuilderIndex -Label $_.Label } | Select-Object -Last 1
    $seedPaneId = [string](Get-MonitorPropertyValue -InputObject $seedPane.Pane -Name 'pane_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($seedPaneId)) {
        throw 'Cannot add a Builder pane because the seed pane has no pane_id.'
    }

    $roleAgentConfig = Get-PaneScalerSlotAgentConfig -SlotId $newLabel -Settings $Settings -ProjectDir $projectDir
    if (-not (Test-PaneScalerParallelRunsAvailable -SlotAgentConfig $roleAgentConfig)) {
        throw "Provider '$([string]$roleAgentConfig.Agent)' does not support parallel Builder panes."
    }

    $worktree = $null
    $newPaneId = ''
    try {
        $worktree = New-PaneScalerBuilderWorktree -ProjectDir $projectDir -BuilderIndex $nextIndex
        $splitOutput = Invoke-MonitorWinsmux -Arguments @('split-window', '-t', $seedPaneId, '-h', '-c', $worktree.WorktreePath, '-P', '-F', '#{pane_id}') -CaptureOutput
        $newPaneId = (($splitOutput | Out-String).Trim() -split "\r?\n" | Where-Object { $_ -match '^%\d+$' } | Select-Object -Last 1)
        if ([string]::IsNullOrWhiteSpace($newPaneId)) {
            throw 'winsmux split-window did not return a pane id.'
        }

        Invoke-MonitorWinsmux -Arguments @('select-pane', '-t', $newPaneId, '-T', $newLabel) | Out-Null

        Wait-MonitorPaneShellReady -PaneId $newPaneId
        Send-MonitorBridgeCommand -PaneId $newPaneId -Text (Get-PaneScalerLaunchCommand -Agent ([string]$roleAgentConfig.Agent) -Model ([string]$roleAgentConfig.Model) -ModelSource ([string]$roleAgentConfig.ModelSource) -ReasoningEffort ([string]$roleAgentConfig.ReasoningEffort) -McpMode ([string]$roleAgentConfig.McpMode) -SlotId $newLabel -ProjectDir $worktree.WorktreePath -GitWorktreeDir $worktree.GitWorktreeDir -RootPath $projectDir) -DeliveryClass 'launch'

        $newPane = [ordered]@{
            label                = $newLabel
            pane_id              = $newPaneId
            role                 = 'Builder'
            exec_mode            = 'false'
            launch_dir           = $worktree.WorktreePath
            builder_branch       = $worktree.BranchName
            builder_worktree_path = $worktree.WorktreePath
            task                 = $null
        }

        $paneObject = [PSCustomObject]@{}
        foreach ($entry in $newPane.GetEnumerator()) {
            Add-Member -InputObject $paneObject -MemberType NoteProperty -Name $entry.Key -Value $entry.Value
        }

        $manifest.Panes[$newLabel] = $paneObject
        $manifest.SavedAt = Get-Date -Format o
        Save-PaneScalerManifest -ManifestPath $ManifestPath -Manifest $manifest -ExpectedGenerationId $expectedGenerationId

        return [PSCustomObject]@{
            Changed      = $true
            Action       = 'scale_up'
            Label        = $newLabel
            PaneId       = $newPaneId
            WorktreePath = $worktree.WorktreePath
            BranchName   = $worktree.BranchName
        }
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($newPaneId)) {
            try {
                Invoke-MonitorWinsmux -Arguments @('kill-pane', '-t', $newPaneId) | Out-Null
            } catch {
            }
        }

        if ($null -ne $worktree) {
            try {
                Remove-PaneScalerBuilderWorktree -ProjectDir $projectDir -WorktreePath $worktree.WorktreePath -BranchName $worktree.BranchName
            } catch {
            }
        }

        throw
    }
}

function Remove-OrchestraPane {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        $Settings = $null,
        [int]$MinimumBuilders = 2,
        [ValidateSet('Builder', 'Worker')][string]$Role = 'Builder',
        [AllowEmptyString()][string]$Label = ''
    )

    if ($Role -eq 'Worker') {
        return Remove-OrchestraWorkerPane -ManifestPath $ManifestPath -Label $Label -Settings $Settings
    }

    $currentManifest = Read-PaneScalerManifest -ManifestPath $ManifestPath
    Assert-PaneScalerPaneCountMutationSupported -Manifest $currentManifest
    $workload = Get-PaneWorkload -ManifestPath $ManifestPath -Settings $Settings
    if ($workload.BuilderCount -le $MinimumBuilders) {
        return [PSCustomObject]@{
            Changed = $false
            Action  = 'no_change'
            Reason  = 'minimum_builders'
        }
    }

    $idleBuilder = $workload.Results |
        Where-Object { $_.Status -eq 'ready' } |
        Sort-Object { Get-PaneScalerBuilderIndex -Label $_.Label } |
        Select-Object -Last 1

    if ($null -eq $idleBuilder) {
        return [PSCustomObject]@{
            Changed = $false
            Action  = 'no_change'
            Reason  = 'no_idle_builder'
        }
    }

    $manifest = $workload.Manifest
    $expectedGenerationId = [string](Get-MonitorPropertyValue -InputObject $manifest.Session -Name 'generation_id' -Default '')
    $projectDir = $workload.ProjectDir
    $pane = $manifest.Panes[[string]$idleBuilder.Label]
    $paneId = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'pane_id' -Default '')
    $worktreePath = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'builder_worktree_path' -Default '')
    $branchName = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'builder_branch' -Default '')

    [void]$manifest.Panes.Remove([string]$idleBuilder.Label)
    $manifest.SavedAt = Get-Date -Format o
    Save-PaneScalerManifest -ManifestPath $ManifestPath -Manifest $manifest -ExpectedGenerationId $expectedGenerationId

    if (-not [string]::IsNullOrWhiteSpace($paneId)) {
        Invoke-MonitorWinsmux -Arguments @('kill-pane', '-t', $paneId) | Out-Null
    }

    Remove-PaneScalerBuilderWorktree -ProjectDir $projectDir -WorktreePath $worktreePath -BranchName $branchName

    return [PSCustomObject]@{
        Changed      = $true
        Action       = 'scale_down'
        Label        = [string]$idleBuilder.Label
        PaneId       = $paneId
        WorktreePath = $worktreePath
        BranchName   = $branchName
    }
}

function Invoke-PaneScalingCheck {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        $Settings = $null,
        [double]$ScaleUpThreshold = 0.8,
        [double]$ScaleDownThreshold = 0.3,
        [int]$MinimumBuilders = 2
    )

    $workload = Get-PaneWorkload -ManifestPath $ManifestPath -Settings $Settings
    if ($workload.TotalPanes -eq 0) {
        return [PSCustomObject]@{
            Action   = 'no_change'
            Reason   = 'no_builder_panes'
            Workload = $workload
            Changed  = $false
        }
    }

    if ($workload.BusyRatio -gt $ScaleUpThreshold) {
        $resolvedSettings = $Settings
        if ($null -eq $resolvedSettings) {
            $resolvedSettings = Get-BridgeSettings -RootPath $workload.ProjectDir
        }

        $newLabel = Get-PaneScalerNextBuilderLabel -Manifest $workload.Manifest
        $slotAgentConfig = Get-PaneScalerSlotAgentConfig -SlotId $newLabel -Settings $resolvedSettings -ProjectDir $workload.ProjectDir
        if (-not (Test-PaneScalerParallelRunsAvailable -SlotAgentConfig $slotAgentConfig)) {
            return [PSCustomObject]@{
                Action   = 'no_change'
                Reason   = 'parallel_runs_unsupported'
                Provider = [string]$slotAgentConfig.Agent
                SlotId   = $newLabel
                Workload = $workload
                Changed  = $false
            }
        }

        $result = Add-OrchestraPane -ManifestPath $ManifestPath -Settings $Settings
        $result | Add-Member -MemberType NoteProperty -Name Workload -Value $workload -Force
        return $result
    }

    if (($workload.BusyRatio -lt $ScaleDownThreshold) -and ($workload.BuilderCount -gt $MinimumBuilders)) {
        $result = Remove-OrchestraPane -ManifestPath $ManifestPath -Settings $Settings -MinimumBuilders $MinimumBuilders
        $result | Add-Member -MemberType NoteProperty -Name Workload -Value $workload -Force
        return $result
    }

    return [PSCustomObject]@{
        Action   = 'no_change'
        Reason   = 'threshold_not_met'
        Workload = $workload
        Changed  = $false
    }
}
