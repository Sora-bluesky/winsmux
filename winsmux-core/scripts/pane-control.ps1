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

    $manifest = [ordered]@{
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

        $paneObject = [ordered]@{}
        foreach ($property in $Pane.GetEnumerator()) {
            $paneObject[[string]$property.Key] = $property.Value
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
    $projectRoot = [string]$manifest.Session.project_dir
    if ([string]::IsNullOrWhiteSpace($projectRoot)) {
        $projectRoot = $ProjectDir
    }

    $sessionGitWorktreeDir = [string]$manifest.Session.git_worktree_dir
    $entries = @()

    foreach ($label in $manifest.Panes.Keys) {
        $pane = $manifest.Panes[$label]
        $role = Get-PaneControlCanonicalRole -Role ([string]$pane.role) -Label $label
        $launchDir = [string]$pane.launch_dir
        $builderWorktreePath = [string]$pane.builder_worktree_path

        if ([string]::IsNullOrWhiteSpace($launchDir) -and -not [string]::IsNullOrWhiteSpace($builderWorktreePath)) {
            $launchDir = $builderWorktreePath
        }

        if ([string]::IsNullOrWhiteSpace($launchDir)) {
            $launchDir = $projectRoot
        }

        $gitWorktreeDir = $sessionGitWorktreeDir
        if ($role -eq 'Builder' -or [string]::IsNullOrWhiteSpace($gitWorktreeDir)) {
            $gitWorktreeDir = Get-PaneControlGitWorktreeDir -ProjectDir $launchDir
        }

        $entries += [ordered]@{
            ManifestPath        = $manifestPath
            ProjectDir          = $projectRoot
            Label               = $label
            PaneId              = [string]$pane.pane_id
            Role                = $role
            LaunchDir           = $launchDir
            BuilderWorktreePath = $builderWorktreePath
            GitWorktreeDir      = $gitWorktreeDir
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

    $lines = @(Get-Content -Path $ManifestPath -Encoding UTF8)
    $inPanesSection = $false
    $currentPane = $null
    $paneBlocks = [System.Collections.Generic.List[object]]::new()

    function Add-PaneControlPaneBlock {
        param($PaneBlock)

        if ($null -eq $PaneBlock) {
            return
        }

        if ([string]::IsNullOrWhiteSpace([string]$PaneBlock.PaneId) -and [string]::IsNullOrWhiteSpace([string]$PaneBlock.Label)) {
            return
        }

        $paneBlocks.Add([ordered]@{
            Label  = [string]$PaneBlock.Label
            PaneId = [string]$PaneBlock.PaneId
            Start  = [int]$PaneBlock.Start
            End    = [int]$PaneBlock.End
            IsList = [bool]$PaneBlock.IsList
        }) | Out-Null
    }

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]

        if (-not $inPanesSection) {
            if ($line -match '^panes:\s*$') {
                $inPanesSection = $true
            }

            continue
        }

        if ($line -match '^[A-Za-z0-9_.-]+:\s*$') {
            if ($null -ne $currentPane) {
                $currentPane['End'] = $index - 1
                Add-PaneControlPaneBlock -PaneBlock $currentPane
                $currentPane = $null
            }

            break
        }

        if ($line -match '^\s{2}-\s+label:\s*(.*?)\s*$') {
            if ($null -ne $currentPane) {
                $currentPane['End'] = $index - 1
                Add-PaneControlPaneBlock -PaneBlock $currentPane
            }

            $currentPane = [ordered]@{
                Label  = ConvertFrom-PaneControlYamlScalar $Matches[1]
                PaneId = ''
                Start  = $index
                End    = $index
                IsList = $true
            }
            continue
        }

        if ($line -match '^\s{2}([^:\s][^:]*):\s*$') {
            if ($null -ne $currentPane) {
                $currentPane['End'] = $index - 1
                Add-PaneControlPaneBlock -PaneBlock $currentPane
            }

            $currentPane = [ordered]@{
                Label  = ConvertFrom-PaneControlYamlScalar $Matches[1]
                PaneId = ''
                Start  = $index
                End    = $index
                IsList = $false
            }
            continue
        }

        if ($null -ne $currentPane -and $line -match '^\s{4}pane_id:\s*(.*?)\s*$') {
            $currentPane['PaneId'] = ConvertFrom-PaneControlYamlScalar $Matches[1]
            continue
        }
    }

    if ($null -ne $currentPane) {
        $currentPane['End'] = $lines.Count - 1
        Add-PaneControlPaneBlock -PaneBlock $currentPane
    }

    $paneBlock = $paneBlocks | Where-Object { $_.PaneId -eq $PaneId } | Select-Object -First 1
    if ($null -eq $paneBlock) {
        throw "Pane $PaneId was not found in manifest: $ManifestPath"
    }

    $updatedBlockLines = [System.Collections.Generic.List[string]]::new()
    $pendingProperties = [ordered]@{}
    foreach ($entry in $Properties.GetEnumerator()) {
        $pendingProperties[[string]$entry.Key] = $entry.Value
    }

    foreach ($blockLine in @($lines[$paneBlock.Start..$paneBlock.End])) {
        if ($blockLine -match '^\s{4}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
            $propertyName = $Matches[1]
            if ($pendingProperties.Contains($propertyName)) {
                $updatedValue = ConvertTo-PaneControlYamlScalar -Value $pendingProperties[$propertyName]
                $updatedBlockLines.Add("    ${propertyName}: $updatedValue") | Out-Null
                $pendingProperties.Remove($propertyName)
                continue
            }
        }

        $updatedBlockLines.Add($blockLine) | Out-Null
    }

    foreach ($propertyName in $pendingProperties.Keys) {
        $updatedValue = ConvertTo-PaneControlYamlScalar -Value $pendingProperties[$propertyName]
        $updatedBlockLines.Add("    ${propertyName}: $updatedValue") | Out-Null
    }

    $before = if ($paneBlock.Start -gt 0) { @($lines[0..($paneBlock.Start - 1)]) } else { @() }
    $after = if ($paneBlock.End + 1 -lt $lines.Count) { @($lines[($paneBlock.End + 1)..($lines.Count - 1)]) } else { @() }
    $updatedLines = @($before + @($updatedBlockLines) + $after)
    $updatedContent = ($updatedLines -join [Environment]::NewLine)
    $quotedManifestPath = '"' + $ManifestPath.Replace('"', '""') + '"'
    $updatedContent | cmd /d /c "more > $quotedManifestPath" | Out-Null
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
    $roleAgentConfig = $null
    if (Get-Command Get-RoleAgentConfig -ErrorAction SilentlyContinue) {
        $roleAgentConfig = Get-RoleAgentConfig -Role $context.Role -Settings $Settings
    } else {
        $roleAgentConfig = [ordered]@{
            Agent = [string]$Settings.agent
            Model = [string]$Settings.model
        }
    }

    $launchCommand = Get-PaneControlLaunchCommand -Agent $roleAgentConfig.Agent -Model $roleAgentConfig.Model -ProjectDir $context.LaunchDir -GitWorktreeDir $context.GitWorktreeDir

    return [ordered]@{
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
