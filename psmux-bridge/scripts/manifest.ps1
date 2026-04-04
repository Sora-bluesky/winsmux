<#
.SYNOPSIS
Session manifest reader/writer for winsmux Orchestra.

.DESCRIPTION
Manages .winsmux/manifest.yaml — the single source of truth for a running
Orchestra session (panes, tasks, worktrees).

Uses simple line-by-line YAML serialization; no external modules required.

Dot-source this script to load the helpers:

    . "$PSScriptRoot/manifest.ps1"
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:ManifestFileName = 'manifest.yaml'
$script:ManifestDirName  = '.winsmux'

# ---------------------------------------------------------------------------
# YAML helpers (minimal, project-local)
# ---------------------------------------------------------------------------

function ConvertTo-ManifestYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    $text = $Value.ToString()
    if ($text -eq '') {
        return '""'
    }

    if ($text -match '^[A-Za-z0-9._/\\:-]+$') {
        return $text
    }

    return '"' + ($text -replace '"', '\"') + '"'
}

function ConvertFrom-ManifestYamlScalar {
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

    return $text
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

function Get-ManifestDir {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path $ProjectDir $script:ManifestDirName
}

function Get-ManifestPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path (Get-ManifestDir -ProjectDir $ProjectDir) $script:ManifestFileName
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function New-WinsmuxManifest {
    <#
    .SYNOPSIS
    Creates a fresh .winsmux/manifest.yaml for a new Orchestra session.
    #>
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $dir = Get-ManifestDir -ProjectDir $ProjectDir
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $now = [System.DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz')

    $manifest = [PSCustomObject]@{
        version   = 1
        session   = [PSCustomObject]@{
            started = $now
            ended   = ''
        }
        panes     = [ordered]@{}
        tasks     = [PSCustomObject]@{
            queued      = @()
            in_progress = @()
            completed   = @()
        }
        worktrees = [ordered]@{}
    }

    Save-WinsmuxManifest -ProjectDir $ProjectDir -Manifest $manifest

    return $manifest
}

function Get-WinsmuxManifest {
    <#
    .SYNOPSIS
    Reads .winsmux/manifest.yaml and returns a PSCustomObject, or $null if absent.
    #>
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $path = Get-ManifestPath -ProjectDir $ProjectDir
    if (-not (Test-Path $path)) {
        return $null
    }

    $raw = Get-Content -Raw -Path $path -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ConvertFrom-ManifestYaml -Content $raw
}

function Save-WinsmuxManifest {
    <#
    .SYNOPSIS
    Writes a manifest PSCustomObject back to .winsmux/manifest.yaml.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $dir = Get-ManifestDir -ProjectDir $ProjectDir
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $path = Get-ManifestPath -ProjectDir $ProjectDir
    $yaml = ConvertTo-ManifestYaml -Manifest $Manifest
    Set-Content -Path $path -Value $yaml -Encoding UTF8 -NoNewline
}

function Update-ManifestPanes {
    <#
    .SYNOPSIS
    Replaces the panes section of the manifest.

    .PARAMETER PaneSummaries
    Array of objects with: Label, PaneId, Role, BuilderWorktreePath
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][array]$PaneSummaries
    )

    $projectDir = Split-Path (Split-Path $ManifestPath -Parent) -Parent
    $manifest = Get-WinsmuxManifest -ProjectDir $projectDir
    if ($null -eq $manifest) {
        throw "Manifest not found at: $ManifestPath"
    }

    $panes = [ordered]@{}
    foreach ($pane in $PaneSummaries) {
        $label = $pane.Label
        $panes[$label] = [PSCustomObject]@{
            pane_id               = $pane.PaneId
            role                  = $pane.Role
            builder_worktree_path = if ($pane.BuilderWorktreePath) { $pane.BuilderWorktreePath } else { '' }
        }
    }

    $manifest.panes = $panes
    Save-WinsmuxManifest -ProjectDir $projectDir -Manifest $manifest
}

function Update-ManifestTasks {
    <#
    .SYNOPSIS
    Replaces the tasks section of the manifest.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$InProgress,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Completed
    )

    $projectDir = Split-Path (Split-Path $ManifestPath -Parent) -Parent
    $manifest = Get-WinsmuxManifest -ProjectDir $projectDir
    if ($null -eq $manifest) {
        throw "Manifest not found at: $ManifestPath"
    }

    $manifest.tasks = [PSCustomObject]@{
        in_progress = @($InProgress)
        completed   = @($Completed)
    }

    Save-WinsmuxManifest -ProjectDir $projectDir -Manifest $manifest
}

# ---------------------------------------------------------------------------
# YAML serializer
# ---------------------------------------------------------------------------

function ConvertTo-ManifestYaml {
    param([Parameter(Mandatory = $true)]$Manifest)

    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add("version: $($Manifest.version)")
    $lines.Add('session:')
    $lines.Add("  started: $(ConvertTo-ManifestYamlScalar $Manifest.session.started)")
    $lines.Add("  ended: $(ConvertTo-ManifestYamlScalar $Manifest.session.ended)")

    # panes
    $lines.Add('panes:')
    $paneEntries = $null
    if ($Manifest.panes -is [System.Collections.IDictionary]) {
        $paneEntries = $Manifest.panes
    }

    if ($null -ne $paneEntries -and $paneEntries.Count -gt 0) {
        foreach ($label in $paneEntries.Keys) {
            $pane = $paneEntries[$label]
            $lines.Add("  $(ConvertTo-ManifestYamlScalar $label):")
            $lines.Add("    pane_id: $(ConvertTo-ManifestYamlScalar $pane.pane_id)")
            $lines.Add("    role: $(ConvertTo-ManifestYamlScalar $pane.role)")
            $lines.Add("    builder_worktree_path: $(ConvertTo-ManifestYamlScalar $pane.builder_worktree_path)")
        }
    } else {
        $lines[$lines.Count - 1] = 'panes: {}'
    }

    # tasks
    $lines.Add('tasks:')

    $lines.Add('  queued:')
    $queued = @()
    if ($null -ne $Manifest.tasks -and $null -ne $Manifest.tasks.queued) {
        $queued = @($Manifest.tasks.queued)
    }

    if ($queued.Count -gt 0) {
        foreach ($task in $queued) {
            $lines.Add("    - $(ConvertTo-ManifestYamlScalar $task)")
        }
    } else {
        $lines[$lines.Count - 1] = '  queued: []'
    }

    $lines.Add('  in_progress:')
    $inProgress = @()
    if ($null -ne $Manifest.tasks -and $null -ne $Manifest.tasks.in_progress) {
        $inProgress = @($Manifest.tasks.in_progress)
    }

    if ($inProgress.Count -gt 0) {
        foreach ($task in $inProgress) {
            $lines.Add("    - $(ConvertTo-ManifestYamlScalar $task)")
        }
    } else {
        $lines[$lines.Count - 1] = '  in_progress: []'
    }

    $lines.Add('  completed:')
    $completed = @()
    if ($null -ne $Manifest.tasks -and $null -ne $Manifest.tasks.completed) {
        $completed = @($Manifest.tasks.completed)
    }

    if ($completed.Count -gt 0) {
        foreach ($task in $completed) {
            $lines.Add("    - $(ConvertTo-ManifestYamlScalar $task)")
        }
    } else {
        $lines[$lines.Count - 1] = '  completed: []'
    }

    # worktrees
    $lines.Add('worktrees:')
    $wtEntries = $null
    if ($Manifest.worktrees -is [System.Collections.IDictionary]) {
        $wtEntries = $Manifest.worktrees
    }

    if ($null -ne $wtEntries -and $wtEntries.Count -gt 0) {
        foreach ($label in $wtEntries.Keys) {
            $wt = $wtEntries[$label]
            $lines.Add("  $(ConvertTo-ManifestYamlScalar $label):")
            if ($wt -is [System.Collections.IDictionary]) {
                foreach ($key in $wt.Keys) {
                    $lines.Add("    ${key}: $(ConvertTo-ManifestYamlScalar $wt[$key])")
                }
            } elseif ($null -ne $wt -and $null -ne $wt.PSObject) {
                foreach ($prop in $wt.PSObject.Properties) {
                    $lines.Add("    $($prop.Name): $(ConvertTo-ManifestYamlScalar $prop.Value)")
                }
            }
        }
    } else {
        $lines[$lines.Count - 1] = 'worktrees: {}'
    }

    return ($lines -join "`n") + "`n"
}

# ---------------------------------------------------------------------------
# YAML deserializer
# ---------------------------------------------------------------------------

function ConvertFrom-ManifestYaml {
    param([Parameter(Mandatory = $true)][string]$Content)

    $manifest = [PSCustomObject]@{
        version   = 1
        session   = [PSCustomObject]@{ started = ''; ended = '' }
        panes     = [ordered]@{}
        tasks     = [PSCustomObject]@{ queued = @(); in_progress = @(); completed = @() }
        worktrees = [ordered]@{}
    }

    $section      = ''
    $subSection   = ''
    $currentLabel = ''
    $taskListKey  = ''

    foreach ($rawLine in ($Content -split "\r?\n")) {
        # Skip comments and blank lines
        $line = $rawLine
        if ($line -match '^\s*#') { continue }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Top-level scalar: version
        if ($line -match '^version:\s*(.+?)\s*$') {
            $manifest.version = [int](ConvertFrom-ManifestYamlScalar $Matches[1])
            $section = ''
            continue
        }

        # Section headers (0-indent)
        if ($line -match '^(session|panes|tasks|worktrees):\s*(\{?\}?)\s*$') {
            $section      = $Matches[1]
            $subSection   = ''
            $currentLabel = ''
            $taskListKey  = ''
            continue
        }

        # 2-space indent
        if ($line -match '^  (\S.*)$') {
            $inner = $Matches[1]

            switch ($section) {
                'session' {
                    if ($inner -match '^(started|ended):\s*(.*?)\s*$') {
                        $manifest.session.($Matches[1]) = ConvertFrom-ManifestYamlScalar $Matches[2]
                    }
                }
                'panes' {
                    if ($inner -match '^(.+?):\s*$') {
                        # Pane label header
                        $currentLabel = ConvertFrom-ManifestYamlScalar $Matches[1]
                        $manifest.panes[$currentLabel] = [PSCustomObject]@{
                            pane_id               = ''
                            role                  = ''
                            builder_worktree_path = ''
                        }
                    }
                }
                'tasks' {
                    if ($inner -match '^(queued|in_progress|completed):\s*(\[?\]?)\s*$') {
                        $taskListKey = $Matches[1]
                    } elseif ($inner -match '^-\s+(.+?)\s*$' -and $taskListKey) {
                        $value = ConvertFrom-ManifestYamlScalar $Matches[1]
                        if ($taskListKey -eq 'queued') {
                            $manifest.tasks.queued = @($manifest.tasks.queued) + @($value)
                        } elseif ($taskListKey -eq 'in_progress') {
                            $manifest.tasks.in_progress = @($manifest.tasks.in_progress) + @($value)
                        } else {
                            $manifest.tasks.completed = @($manifest.tasks.completed) + @($value)
                        }
                    }
                }
                'worktrees' {
                    if ($inner -match '^(.+?):\s*$') {
                        $currentLabel = ConvertFrom-ManifestYamlScalar $Matches[1]
                        $manifest.worktrees[$currentLabel] = [ordered]@{}
                    }
                }
            }

            continue
        }

        # 4-space indent
        if ($line -match '^    (\S.*)$') {
            $inner = $Matches[1]

            if ($section -eq 'panes' -and $currentLabel -and $manifest.panes.Contains($currentLabel)) {
                if ($inner -match '^(pane_id|role|builder_worktree_path):\s*(.*?)\s*$') {
                    $manifest.panes[$currentLabel].($Matches[1]) = ConvertFrom-ManifestYamlScalar $Matches[2]
                }
            }

            if ($section -eq 'tasks' -and $taskListKey) {
                if ($inner -match '^-\s+(.+?)\s*$') {
                    $value = ConvertFrom-ManifestYamlScalar $Matches[1]
                    if ($taskListKey -eq 'in_progress') {
                        $manifest.tasks.in_progress = @($manifest.tasks.in_progress) + @($value)
                    } else {
                        $manifest.tasks.completed = @($manifest.tasks.completed) + @($value)
                    }
                }
            }

            if ($section -eq 'worktrees' -and $currentLabel -and $manifest.worktrees.Contains($currentLabel)) {
                if ($inner -match '^(\S+?):\s*(.*?)\s*$') {
                    $manifest.worktrees[$currentLabel][$Matches[1]] = ConvertFrom-ManifestYamlScalar $Matches[2]
                }
            }

            continue
        }
    }

    return $manifest
}
