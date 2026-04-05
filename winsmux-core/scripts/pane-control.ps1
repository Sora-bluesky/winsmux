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

function Get-PaneControlCanonicalRole {
    param([AllowNull()][string]$Role, [AllowNull()][string]$Label)

    $candidate = if ([string]::IsNullOrWhiteSpace($Role)) { $Label } else { $Role }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return 'Commander'
    }

    switch -Regex ($candidate.Trim()) {
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
            return "codex -c model=$Model --full-auto -C $(ConvertTo-PaneControlPowerShellLiteral -Value $ProjectDir) --add-dir $(ConvertTo-PaneControlPowerShellLiteral -Value $GitWorktreeDir)"
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

    $manifest = [PSCustomObject]@{
        Session = [ordered]@{}
        Panes   = [ordered]@{}
    }

    $section = $null
    $currentPane = $null

    function Save-PaneControlPane {
        param($Pane)

        if ($null -eq $Pane) {
            return
        }

        $label = [string]$Pane.label
        if ([string]::IsNullOrWhiteSpace($label)) {
            return
        }

        $paneObject = [PSCustomObject]@{}
        foreach ($property in $Pane.GetEnumerator()) {
            Add-Member -InputObject $paneObject -MemberType NoteProperty -Name $property.Key -Value $property.Value
        }

        $manifest.Panes[$label] = $paneObject
    }

    foreach ($rawLine in ($Content -split "\r?\n")) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
            continue
        }

        if ($line -match '^(session|panes):\s*$') {
            if ($section -eq 'panes') {
                Save-PaneControlPane -Pane $currentPane
                $currentPane = $null
            }

            $section = $Matches[1]
            continue
        }

        if ($section -eq 'session' -and $line -match '^\s{2}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
            $manifest.Session[$Matches[1]] = ConvertFrom-PaneControlYamlScalar $Matches[2]
            continue
        }

        if ($section -ne 'panes') {
            continue
        }

        if ($line -match '^\s{2}-\s+label:\s*(.*?)\s*$') {
            Save-PaneControlPane -Pane $currentPane
            $currentPane = [ordered]@{
                label = ConvertFrom-PaneControlYamlScalar $Matches[1]
            }
            continue
        }

        if ($line -match '^\s{2}(.+?):\s*$') {
            Save-PaneControlPane -Pane $currentPane
            $currentPane = [ordered]@{
                label = ConvertFrom-PaneControlYamlScalar $Matches[1]
            }
            continue
        }

        if ($null -ne $currentPane -and $line -match '^\s{4}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
            $currentPane[$Matches[1]] = ConvertFrom-PaneControlYamlScalar $Matches[2]
        }
    }

    Save-PaneControlPane -Pane $currentPane
    return $manifest
}

function Get-PaneControlManifestContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$PaneId
    )

    $manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
    if (-not (Test-Path $manifestPath -PathType Leaf)) {
        throw "Manifest not found: $manifestPath"
    }

    $content = Get-Content -Path $manifestPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Manifest is empty: $manifestPath"
    }

    $manifest = ConvertFrom-PaneControlManifestContent -Content $content
    foreach ($label in $manifest.Panes.Keys) {
        $pane = $manifest.Panes[$label]
        if ([string]$pane.pane_id -ne $PaneId) {
            continue
        }

        $projectRoot = [string]$manifest.Session.project_dir
        if ([string]::IsNullOrWhiteSpace($projectRoot)) {
            $projectRoot = $ProjectDir
        }

        $role = Get-PaneControlCanonicalRole -Role ([string]$pane.role) -Label $label
        $launchDir = [string]$pane.launch_dir
        $builderWorktreePath = [string]$pane.builder_worktree_path

        if ([string]::IsNullOrWhiteSpace($launchDir) -and -not [string]::IsNullOrWhiteSpace($builderWorktreePath)) {
            $launchDir = $builderWorktreePath
        }

        if ([string]::IsNullOrWhiteSpace($launchDir)) {
            $launchDir = $projectRoot
        }

        $gitWorktreeDir = [string]$manifest.Session.git_worktree_dir
        if ($role -eq 'Builder' -or [string]::IsNullOrWhiteSpace($gitWorktreeDir)) {
            $gitWorktreeDir = Get-PaneControlGitWorktreeDir -ProjectDir $launchDir
        }

        return [PSCustomObject]@{
            ManifestPath         = $manifestPath
            ProjectDir           = $projectRoot
            Label                = $label
            PaneId               = $PaneId
            Role                 = $role
            LaunchDir            = $launchDir
            BuilderWorktreePath  = $builderWorktreePath
            GitWorktreeDir       = $gitWorktreeDir
        }
    }

    throw "Pane $PaneId was not found in manifest: $manifestPath"
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
    $roleAgentConfig = $null
    if (Get-Command Get-RoleAgentConfig -ErrorAction SilentlyContinue) {
        $roleAgentConfig = Get-RoleAgentConfig -Role $context.Role -Settings $Settings
    } else {
        $roleAgentConfig = [PSCustomObject]@{
            Agent = [string]$Settings.agent
            Model = [string]$Settings.model
        }
    }

    $launchCommand = Get-PaneControlLaunchCommand -Agent $roleAgentConfig.Agent -Model $roleAgentConfig.Model -ProjectDir $context.LaunchDir -GitWorktreeDir $context.GitWorktreeDir

    return [PSCustomObject]@{
        PaneId         = $context.PaneId
        Label          = $context.Label
        Role           = $context.Role
        ProjectDir     = $context.ProjectDir
        LaunchDir      = $context.LaunchDir
        GitWorktreeDir = $context.GitWorktreeDir
        Agent          = [string]$roleAgentConfig.Agent
        Model          = [string]$roleAgentConfig.Model
        LaunchCommand  = $launchCommand
    }
}
