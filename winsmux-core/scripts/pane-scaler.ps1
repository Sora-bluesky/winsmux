$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'settings.ps1')
. (Join-Path $scriptDir 'agent-monitor.ps1')
. (Join-Path $scriptDir 'builder-worktree.ps1')

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
        '^(?i)builder(?:$|[-_:/\s])' { return 'Builder' }
        '^(?i)researcher(?:$|[-_:/\s])' { return 'Researcher' }
        '^(?i)reviewer(?:$|[-_:/\s])' { return 'Reviewer' }
        '^(?i)commander(?:$|[-_:/\s])' { return 'Commander' }
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

    $manifest = [PSCustomObject]@{
        Version = 1
        SavedAt = ''
        Session = [ordered]@{}
        Panes   = [ordered]@{}
    }

    $section = ''
    $currentPane = $null

    function Save-PaneScalerPane {
        param($Pane)

        if ($null -eq $Pane) {
            return
        }

        $label = [string]$Pane.label
        if ([string]::IsNullOrWhiteSpace($label)) {
            return
        }

        $paneObject = [PSCustomObject]@{}
        foreach ($entry in $Pane.GetEnumerator()) {
            Add-Member -InputObject $paneObject -MemberType NoteProperty -Name $entry.Key -Value $entry.Value
        }

        $manifest.Panes[$label] = $paneObject
    }

    foreach ($rawLine in ($content -split "\r?\n")) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
            continue
        }

        if ($line -match '^version:\s*(.+?)\s*$') {
            $manifest.Version = [int](ConvertFrom-PaneScalerYamlScalar $Matches[1])
            continue
        }

        if ($line -match '^saved_at:\s*(.*?)\s*$') {
            $manifest.SavedAt = [string](ConvertFrom-PaneScalerYamlScalar $Matches[1])
            continue
        }

        if ($line -match '^(session|panes):\s*$') {
            if ($section -eq 'panes') {
                Save-PaneScalerPane -Pane $currentPane
                $currentPane = $null
            }

            $section = $Matches[1]
            continue
        }

        if ($section -eq 'session' -and $line -match '^\s{2}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
            $manifest.Session[$Matches[1]] = ConvertFrom-PaneScalerYamlScalar $Matches[2]
            continue
        }

        if ($section -ne 'panes') {
            continue
        }

        if ($line -match '^\s{2}-\s+label:\s*(.*?)\s*$') {
            Save-PaneScalerPane -Pane $currentPane
            $currentPane = [ordered]@{
                label = ConvertFrom-PaneScalerYamlScalar $Matches[1]
            }
            continue
        }

        if ($null -ne $currentPane -and $line -match '^\s{4}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
            $currentPane[$Matches[1]] = ConvertFrom-PaneScalerYamlScalar $Matches[2]
        }
    }

    Save-PaneScalerPane -Pane $currentPane
    return $manifest
}

function Save-PaneScalerManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("version: $($Manifest.Version)") | Out-Null

    $savedAt = if ([string]::IsNullOrWhiteSpace([string]$Manifest.SavedAt)) {
        Get-Date -Format o
    } else {
        [string]$Manifest.SavedAt
    }
    $lines.Add(("saved_at: {0}" -f (ConvertTo-PaneScalerYamlScalar -Value $savedAt))) | Out-Null

    $lines.Add('session:') | Out-Null
    foreach ($entry in $Manifest.Session.GetEnumerator()) {
        $lines.Add(("  {0}: {1}" -f $entry.Key, (ConvertTo-PaneScalerYamlScalar -Value $entry.Value))) | Out-Null
    }

    $lines.Add('panes:') | Out-Null
    foreach ($label in $Manifest.Panes.Keys) {
        $pane = $Manifest.Panes[$label]
        $lines.Add(("  - label: {0}" -f (ConvertTo-PaneScalerYamlScalar -Value $label))) | Out-Null

        $properties = if ($pane -is [System.Collections.IDictionary]) {
            @($pane.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = $_.Key; Value = $_.Value } })
        } else {
            @($pane.PSObject.Properties | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Value = $_.Value } })
        }

        foreach ($property in $properties) {
            if ($property.Name -eq 'label') {
                continue
            }

            $lines.Add(("    {0}: {1}" -f $property.Name, (ConvertTo-PaneScalerYamlScalar -Value $property.Value))) | Out-Null
        }
    }

    Set-Content -Path $ManifestPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8 -NoNewline
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

function ConvertTo-PaneScalerPowerShellLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-PaneScalerLaunchCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir
    )

    switch ($Agent.Trim().ToLowerInvariant()) {
        'codex' {
            return "codex -c model=$Model --full-auto -C $(ConvertTo-PaneScalerPowerShellLiteral -Value $ProjectDir) --add-dir $(ConvertTo-PaneScalerPowerShellLiteral -Value $GitWorktreeDir)"
        }
        'claude' {
            return 'claude --permission-mode bypassPermissions'
        }
        default {
            throw "Unsupported agent setting: $Agent"
        }
    }
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

    if ($null -eq $Settings) {
        $Settings = Get-BridgeSettings
    }

    $manifest = Read-PaneScalerManifest -ManifestPath $ManifestPath
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
        try {
            $roleAgentConfig = Get-RoleAgentConfig -Role 'Builder' -Settings $Settings
        } catch {
            $roleAgentConfig = [PSCustomObject]@{
                Agent = [string]$Settings.agent
                Model = [string]$Settings.model
            }
        }

        $status = Get-PaneAgentStatus -PaneId $paneId -Agent ([string]$roleAgentConfig.Agent) -Role 'Builder' -HungThreshold $HungThreshold
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
        ProjectDir   = Get-PaneScalerProjectDir -Manifest $manifest -ManifestPath $ManifestPath
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

    if ($null -eq $Settings) {
        $Settings = Get-BridgeSettings
    }

    $manifest = Read-PaneScalerManifest -ManifestPath $ManifestPath
    $projectDir = Get-PaneScalerProjectDir -Manifest $manifest -ManifestPath $ManifestPath
    $builderPanes = @(Get-PaneScalerBuilderPanes -Manifest $manifest)
    if ($builderPanes.Count -eq 0) {
        throw 'Cannot add a Builder pane because no existing Builder pane was found.'
    }

    $nextIndex = 1
    foreach ($builderPane in $builderPanes) {
        $nextIndex = [Math]::Max($nextIndex, (Get-PaneScalerBuilderIndex -Label $builderPane.Label) + 1)
    }

    $seedPane = $builderPanes | Sort-Object { Get-PaneScalerBuilderIndex -Label $_.Label } | Select-Object -Last 1
    $seedPaneId = [string](Get-MonitorPropertyValue -InputObject $seedPane.Pane -Name 'pane_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($seedPaneId)) {
        throw 'Cannot add a Builder pane because the seed pane has no pane_id.'
    }

    $worktree = $null
    $newPaneId = ''
    try {
        $worktree = New-PaneScalerBuilderWorktree -ProjectDir $projectDir -BuilderIndex $nextIndex
        $splitOutput = Invoke-MonitorPsmux -Arguments @('split-window', '-t', $seedPaneId, '-h', '-c', $worktree.WorktreePath, '-P', '-F', '#{pane_id}') -CaptureOutput
        $newPaneId = (($splitOutput | Out-String).Trim() -split "\r?\n" | Where-Object { $_ -match '^%\d+$' } | Select-Object -Last 1)
        if ([string]::IsNullOrWhiteSpace($newPaneId)) {
            throw 'winsmux split-window did not return a pane id.'
        }

        $newLabel = "builder-$nextIndex"
        Invoke-MonitorPsmux -Arguments @('select-pane', '-t', $newPaneId, '-T', $newLabel) | Out-Null

        $roleAgentConfig = $null
        try {
            $roleAgentConfig = Get-RoleAgentConfig -Role 'Builder' -Settings $Settings
        } catch {
            $roleAgentConfig = [PSCustomObject]@{
                Agent = [string]$Settings.agent
                Model = [string]$Settings.model
            }
        }

        Wait-MonitorPaneShellReady -PaneId $newPaneId
        Send-MonitorBridgeCommand -PaneId $newPaneId -Text (Get-PaneScalerLaunchCommand -Agent ([string]$roleAgentConfig.Agent) -Model ([string]$roleAgentConfig.Model) -ProjectDir $worktree.WorktreePath -GitWorktreeDir $worktree.GitWorktreeDir)

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
                Invoke-MonitorPsmux -Arguments @('kill-pane', '-t', $newPaneId) | Out-Null
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

    if ($null -eq $Settings) {
        $Settings = Get-BridgeSettings
    }

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
        Invoke-MonitorPsmux -Arguments @('kill-pane', '-t', $paneId) | Out-Null
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

    if ($null -eq $Settings) {
        $Settings = Get-BridgeSettings
    }

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
