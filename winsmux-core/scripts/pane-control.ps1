 . (Join-Path $PSScriptRoot 'settings.ps1')
 . (Join-Path $PSScriptRoot 'manifest.ps1')

function ConvertFrom-PaneControlYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = $Value.ToString().Trim()
    if ($text.Length -ge 2) {
        if (($text.StartsWith('"') -and $text.EndsWith('"')) -or ($text.StartsWith("'") -and $text.EndsWith("'"))) {
            $text = $text.Substring(1, $text.Length - 2)
        }
    }

    if ($text -eq 'null') {
        return $null
    }

    return $text
}

function ConvertTo-PaneControlYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [bool]) {
        if ($Value) {
            return 'true'
        }

        return 'false'
    }

    $text = [string]$Value
    if ($text.Length -eq 0) {
        return "''"
    }

    return "'" + $text.Replace("'", "''") + "'"
}

function Get-PaneControlValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($Name)) {
        return $InputObject[$Name]
    }

    if ($null -ne $InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }

    return $Default
}

function ConvertFrom-PaneControlChangedFiles {
    param([AllowNull()]$Value)

    $normalize = {
        param($Items)

        return @(
            @($Items) |
                Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { [string]$_ }
        )
    }

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return & $normalize $Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    try {
        $parsed = $text | ConvertFrom-Json -ErrorAction Stop
        if ($parsed -is [System.Array]) {
            return & $normalize $parsed
        }

        return & $normalize @($parsed)
    } catch {
        return & $normalize @($text)
    }
}

function ConvertFrom-PaneControlStringArray {
    param([AllowNull()]$Value)

    $normalize = {
        param($Items)

        return @(
            @($Items) |
                Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { [string]$_ }
        )
    }

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return & $normalize $Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    try {
        $parsed = $text | ConvertFrom-Json -ErrorAction Stop
        if ($parsed -is [System.Array]) {
            return & $normalize $parsed
        }

        return & $normalize @($parsed)
    } catch {
        return & $normalize @($text)
    }
}

function ConvertFrom-PaneControlBoolean {
    param([AllowNull()]$Value, [bool]$Default = $false)

    if ($null -eq $Value) {
        return $Default
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Default
    }

    switch ($text.Trim().ToLowerInvariant()) {
        'true' { return $true }
        '1' { return $true }
        'yes' { return $true }
        'y' { return $true }
        'false' { return $false }
        '0' { return $false }
        'no' { return $false }
        'n' { return $false }
        default { return $Default }
    }
}

function Get-PaneControlCanonicalRole {
    param([AllowNull()][string]$Role, [AllowNull()][string]$Label)

    $candidate = if ([string]::IsNullOrWhiteSpace($Role)) { $Label } else { $Role }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return 'Commander'
    }

    switch -Regex ($candidate.Trim()) {
        '^(?i)worker(?:$|[-_:/\s])' { return 'Worker' }
        '^(?i)builder(?:$|[-_:/\s])' { return 'Builder' }
        '^(?i)researcher(?:$|[-_:/\s])' { return 'Researcher' }
        '^(?i)reviewer(?:$|[-_:/\s])' { return 'Reviewer' }
        '^(?i)commander(?:$|[-_:/\s])' { return 'Commander' }
        default { return 'Commander' }
    }
}

function Get-PaneControlGitWorktreeDir {
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

function ConvertTo-PaneControlPowerShellLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-PaneControlLaunchCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir
    )

    switch ($Agent.Trim().ToLowerInvariant()) {
        'codex' {
            return "codex -c model=$Model --sandbox danger-full-access -C $(ConvertTo-PaneControlPowerShellLiteral -Value $ProjectDir) --add-dir $(ConvertTo-PaneControlPowerShellLiteral -Value $GitWorktreeDir)"
        }
        'claude' {
            return 'claude --permission-mode bypassPermissions'
        }
        default {
            throw "Unsupported agent setting: $Agent"
        }
    }
}

function ConvertFrom-PaneControlManifestContent {
    param([Parameter(Mandatory = $true)][string]$Content)

    $parsed = ConvertFrom-ManifestYaml -Content $Content
    return [ordered]@{
        Session = $parsed.session
        Panes   = $parsed.panes
        Tasks   = $parsed.tasks
        Worktrees = $parsed.worktrees
    }
}

function ConvertFrom-PaneControlSecurityPolicy {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return $Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $parseCandidates = @($text)
    if ($text.Contains('\"')) {
        $parseCandidates += ($text -replace '\\"', '"')
    }

    foreach ($candidate in $parseCandidates | Select-Object -Unique) {
        try {
            return ($candidate | ConvertFrom-Json -AsHashtable -Depth 8)
        } catch {
        }
    }

    return [ordered]@{ raw = $text }
}

function Get-PaneControlManifestEntries {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
    if (-not (Test-Path $manifestPath -PathType Leaf)) {
        throw "Manifest not found: $manifestPath"
    }

    $content = Get-Content -Path $manifestPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Manifest is empty: $manifestPath"
    }

    $manifest = ConvertFrom-PaneControlManifestContent -Content $content
    $projectRoot = [string](Get-PaneControlValue -InputObject $manifest.Session -Name 'project_dir' -Default '')
    if ([string]::IsNullOrWhiteSpace($projectRoot)) {
        $projectRoot = $ProjectDir
    }

    $sessionGitWorktreeDir = [string](Get-PaneControlValue -InputObject $manifest.Session -Name 'git_worktree_dir' -Default '')
    $entries = @()

    foreach ($label in $manifest.Panes.Keys) {
        $pane = $manifest.Panes[$label]
        $role = Get-PaneControlCanonicalRole -Role ([string](Get-PaneControlValue -InputObject $pane -Name 'role' -Default '')) -Label $label
        $launchDir = [string](Get-PaneControlValue -InputObject $pane -Name 'launch_dir' -Default '')
        $builderWorktreePath = [string](Get-PaneControlValue -InputObject $pane -Name 'builder_worktree_path' -Default '')

        if ([string]::IsNullOrWhiteSpace($launchDir) -and -not [string]::IsNullOrWhiteSpace($builderWorktreePath)) {
            $launchDir = $builderWorktreePath
        }

        if ([string]::IsNullOrWhiteSpace($launchDir)) {
            $launchDir = $projectRoot
        }

        $gitWorktreeDir = $sessionGitWorktreeDir
        if ($role -in @('Builder', 'Worker') -or [string]::IsNullOrWhiteSpace($gitWorktreeDir)) {
            $gitWorktreeDir = Get-PaneControlGitWorktreeDir -ProjectDir $launchDir
        }

        $entries += [ordered]@{
            ManifestPath        = $manifestPath
            ProjectDir          = $projectRoot
            Label               = $label
            PaneId              = [string](Get-PaneControlValue -InputObject $pane -Name 'pane_id' -Default '')
            Role                = $role
            LaunchDir           = $launchDir
            BuilderWorktreePath = $builderWorktreePath
            GitWorktreeDir      = $gitWorktreeDir
            TaskId              = [string](Get-PaneControlValue -InputObject $pane -Name 'task_id' -Default '')
            Task                = [string](Get-PaneControlValue -InputObject $pane -Name 'task' -Default '')
            TaskState           = [string](Get-PaneControlValue -InputObject $pane -Name 'task_state' -Default '')
            TaskOwner           = [string](Get-PaneControlValue -InputObject $pane -Name 'task_owner' -Default '')
            ReviewState         = [string](Get-PaneControlValue -InputObject $pane -Name 'review_state' -Default '')
            Branch              = [string](Get-PaneControlValue -InputObject $pane -Name 'branch' -Default '')
            HeadSha             = [string](Get-PaneControlValue -InputObject $pane -Name 'head_sha' -Default '')
            ChangedFileCount    = [int](Get-PaneControlValue -InputObject $pane -Name 'changed_file_count' -Default 0)
            ChangedFiles        = @(ConvertFrom-PaneControlChangedFiles -Value (Get-PaneControlValue -InputObject $pane -Name 'changed_files' -Default @()))
            LastEvent           = [string](Get-PaneControlValue -InputObject $pane -Name 'last_event' -Default '')
            LastEventAt         = [string](Get-PaneControlValue -InputObject $pane -Name 'last_event_at' -Default '')
            ParentRunId         = [string](Get-PaneControlValue -InputObject $pane -Name 'parent_run_id' -Default '')
            Goal                = [string](Get-PaneControlValue -InputObject $pane -Name 'goal' -Default '')
            TaskType            = [string](Get-PaneControlValue -InputObject $pane -Name 'task_type' -Default '')
            Priority            = [string](Get-PaneControlValue -InputObject $pane -Name 'priority' -Default '')
            Blocking            = ConvertFrom-PaneControlBoolean -Value (Get-PaneControlValue -InputObject $pane -Name 'blocking' -Default $false) -Default $false
            WriteScope          = @(ConvertFrom-PaneControlStringArray -Value (Get-PaneControlValue -InputObject $pane -Name 'write_scope' -Default @()))
            ReadScope           = @(ConvertFrom-PaneControlStringArray -Value (Get-PaneControlValue -InputObject $pane -Name 'read_scope' -Default @()))
            Constraints         = @(ConvertFrom-PaneControlStringArray -Value (Get-PaneControlValue -InputObject $pane -Name 'constraints' -Default @()))
            ExpectedOutput      = [string](Get-PaneControlValue -InputObject $pane -Name 'expected_output' -Default '')
            VerificationPlan    = @(ConvertFrom-PaneControlStringArray -Value (Get-PaneControlValue -InputObject $pane -Name 'verification_plan' -Default @()))
            ReviewRequired      = ConvertFrom-PaneControlBoolean -Value (Get-PaneControlValue -InputObject $pane -Name 'review_required' -Default $false) -Default $false
            ProviderTarget      = [string](Get-PaneControlValue -InputObject $pane -Name 'provider_target' -Default '')
            AgentRole           = [string](Get-PaneControlValue -InputObject $pane -Name 'agent_role' -Default '')
            TimeoutPolicy       = [string](Get-PaneControlValue -InputObject $pane -Name 'timeout_policy' -Default '')
            HandoffRefs         = @(ConvertFrom-PaneControlStringArray -Value (Get-PaneControlValue -InputObject $pane -Name 'handoff_refs' -Default @()))
            SecurityPolicy      = ConvertFrom-PaneControlSecurityPolicy -Value (Get-PaneControlValue -InputObject $pane -Name 'security_policy' -Default $null)
        }
    }

    return @($entries)
}

function Get-PaneControlManifestContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$PaneId
    )

    $entries = Get-PaneControlManifestEntries -ProjectDir $ProjectDir
    foreach ($entry in $entries) {
        if ($entry.PaneId -ne $PaneId) {
            continue
        }

        return $entry
    }

    $manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
    throw "Pane $PaneId was not found in manifest: $manifestPath"
}

function Set-PaneControlManifestPaneProperties {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Properties
    )

    if (-not (Test-Path $ManifestPath -PathType Leaf)) {
        throw "Manifest not found: $ManifestPath"
    }

    $projectDir = Split-Path (Split-Path $ManifestPath -Parent) -Parent
    $manifest = Get-WinsmuxManifest -ProjectDir $projectDir
    if ($null -eq $manifest) {
        throw "Pane $PaneId was not found in manifest: $ManifestPath"
    }

    $originalLabel = $null
    $updatedPanes = [ordered]@{}
    foreach ($label in $manifest.panes.Keys) {
        $pane = $manifest.panes[$label]
        if ([string]$pane.pane_id -ne $PaneId) {
            $updatedPanes[$label] = $pane
            continue
        }

        $originalLabel = $label
        $newLabel = if ($Properties.Contains('label')) { [string]$Properties['label'] } else { $label }
        $updatedPane = [ordered]@{}
        $paneMap = ConvertTo-ManifestPropertyMap -Value $pane
        foreach ($propertyName in $paneMap.Keys) {
            $updatedPane[$propertyName] = $paneMap[$propertyName]
        }

        foreach ($entry in $Properties.GetEnumerator()) {
            $propertyName = [string]$entry.Key
            if ($propertyName -eq 'label') {
                continue
            }

            $updatedPane[$propertyName] = $entry.Value
        }

        $updatedPanes[$newLabel] = [PSCustomObject]$updatedPane
    }

    if ($null -eq $originalLabel) {
        throw "Pane $PaneId was not found in manifest: $ManifestPath"
    }

    $manifest.panes = $updatedPanes
    Save-WinsmuxManifest -ProjectDir $projectDir -Manifest $manifest
}

function Get-PaneControlPaneTitle {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    $titleOutput = & winsmux display-message -p -t $PaneId '#{pane_title}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "failed to read pane title for $PaneId"
    }

    return (($titleOutput | Out-String).Trim() -split "\r?\n" | Select-Object -Last 1).Trim()
}

function Update-PaneControlManifestPaneLabel {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [AllowNull()][string]$Label = $null
    )

    $context = Get-PaneControlManifestContext -ProjectDir $ProjectDir -PaneId $PaneId
    $resolvedLabel = if ([string]::IsNullOrWhiteSpace($Label)) {
        Get-PaneControlPaneTitle -PaneId $PaneId
    } else {
        $Label
    }

    if ([string]::IsNullOrWhiteSpace($resolvedLabel)) {
        return $false
    }

    if ([string]$context.Label -eq $resolvedLabel) {
        return $false
    }

    $properties = [ordered]@{
        label = $resolvedLabel
    }
    Set-PaneControlManifestPaneProperties -ManifestPath $context.ManifestPath -PaneId $PaneId -Properties $properties
    return $true
}

function Set-PaneControlManifestPanePaths {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$LaunchDir,
        [AllowNull()][string]$BuilderWorktreePath = $null
    )

    $manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
    $properties = [ordered]@{
        launch_dir = $LaunchDir
    }

    if (-not [string]::IsNullOrWhiteSpace($BuilderWorktreePath)) {
        $properties['builder_worktree_path'] = $BuilderWorktreePath
    }

    Set-PaneControlManifestPaneProperties -ManifestPath $manifestPath -PaneId $PaneId -Properties $properties
}

function Get-PaneControlRestartPlan {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$PaneId,
        $Settings
    )

    if ($null -eq $Settings) {
        if (Get-Command Get-BridgeSettings -ErrorAction SilentlyContinue) {
            $Settings = Get-BridgeSettings
        } else {
            $Settings = [ordered]@{
                agent = 'codex'
                model = 'gpt-5.4'
                roles = [ordered]@{}
            }
        }
    }

    $context = Get-PaneControlManifestContext -ProjectDir $ProjectDir -PaneId $PaneId
    $agentConfig = $null
    if (Get-Command Get-SlotAgentConfig -ErrorAction SilentlyContinue) {
        $agentConfig = Get-SlotAgentConfig -Role $context.Role -SlotId $context.Label -Settings $Settings
    } elseif (Get-Command Get-RoleAgentConfig -ErrorAction SilentlyContinue) {
        $agentConfig = Get-RoleAgentConfig -Role $context.Role -Settings $Settings
    } else {
        $agentConfig = [ordered]@{
            Agent = [string]$Settings.agent
            Model = [string]$Settings.model
        }
    }

    $launchCommand = Get-PaneControlLaunchCommand -Agent $agentConfig.Agent -Model $agentConfig.Model -ProjectDir $context.LaunchDir -GitWorktreeDir $context.GitWorktreeDir

    return [ordered]@{
        PaneId         = $context.PaneId
        Label          = $context.Label
        Role           = $context.Role
        ProjectDir     = $context.ProjectDir
        LaunchDir      = $context.LaunchDir
        GitWorktreeDir = $context.GitWorktreeDir
        Agent          = [string]$agentConfig.Agent
        Model          = [string]$agentConfig.Model
        PromptTransport = [string]$agentConfig.PromptTransport
        LaunchCommand  = $launchCommand
    }
}
