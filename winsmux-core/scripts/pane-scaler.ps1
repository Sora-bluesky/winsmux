$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'settings.ps1')
. (Join-Path $scriptDir 'agent-monitor.ps1')
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
        [Parameter(Mandatory = $true)]$Manifest
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

    Save-WinsmuxManifest -ProjectDir $projectDir -Manifest $canonicalManifest
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
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [string]$RootPath = ''
    )

    return Get-BridgeProviderLaunchCommand `
        -ProviderId $Agent `
        -Model $Model `
        -ModelSource $ModelSource `
        -ReasoningEffort $ReasoningEffort `
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
            Invoke-BuilderWorktreeGit -ProjectDir $ProjectDir -Arguments @('worktree', 'remove', '--force', $resolvedPath) -AllowFailure | Out-Null
            if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
                Remove-Item -LiteralPath $resolvedPath -Recurse -Force
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($BranchName)) {
        Invoke-BuilderWorktreeGit -ProjectDir $ProjectDir -Arguments @('branch', '-D', $BranchName) -AllowFailure | Out-Null
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

        $statusAgent = [string](Get-MonitorPropertyValue -InputObject $roleAgentConfig -Name 'CapabilityAdapter' -Default '')
        if ([string]::IsNullOrWhiteSpace($statusAgent)) {
            $statusAgent = [string]$roleAgentConfig.Agent
        }

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

function Add-OrchestraPane {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        $Settings = $null
    )

    $manifest = Read-PaneScalerManifest -ManifestPath $ManifestPath
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
        Send-MonitorBridgeCommand -PaneId $newPaneId -Text (Get-PaneScalerLaunchCommand -Agent ([string]$roleAgentConfig.Agent) -Model ([string]$roleAgentConfig.Model) -ModelSource ([string]$roleAgentConfig.ModelSource) -ReasoningEffort ([string]$roleAgentConfig.ReasoningEffort) -ProjectDir $worktree.WorktreePath -GitWorktreeDir $worktree.GitWorktreeDir -RootPath $projectDir)

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
        Save-PaneScalerManifest -ManifestPath $ManifestPath -Manifest $manifest

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
        [int]$MinimumBuilders = 2
    )

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
    $projectDir = $workload.ProjectDir
    $pane = $manifest.Panes[[string]$idleBuilder.Label]
    $paneId = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'pane_id' -Default '')
    $worktreePath = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'builder_worktree_path' -Default '')
    $branchName = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'builder_branch' -Default '')

    if (-not [string]::IsNullOrWhiteSpace($paneId)) {
        Invoke-MonitorWinsmux -Arguments @('kill-pane', '-t', $paneId) | Out-Null
    }

    Remove-PaneScalerBuilderWorktree -ProjectDir $projectDir -WorktreePath $worktreePath -BranchName $branchName
    [void]$manifest.Panes.Remove([string]$idleBuilder.Label)
    $manifest.SavedAt = Get-Date -Format o
    Save-PaneScalerManifest -ManifestPath $ManifestPath -Manifest $manifest

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
