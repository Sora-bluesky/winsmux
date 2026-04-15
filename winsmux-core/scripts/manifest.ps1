<#
.SYNOPSIS
Session manifest reader/writer for winsmux Orchestra.

.DESCRIPTION
Manages .winsmux/manifest.yaml as the single source of truth for a running
Orchestra session. Supports both the legacy list-style pane schema and the
current dictionary-style pane schema used by orchestra-start.ps1.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'clm-safe-io.ps1')

$script:ManifestFileName = 'manifest.yaml'
$script:ManifestDirName = '.winsmux'

function ConvertTo-ManifestYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [bool]) {
        return $(if ($Value) { 'true' } else { 'false' })
    }

    $text = [string]$Value
    if ($text.Length -eq 0) {
        return "''"
    }

    return "'" + $text.Replace("'", "''") + "'"
}

function Split-ManifestYamlInlineList {
    param([Parameter(Mandatory = $true)][string]$Value)

    $items = [System.Collections.Generic.List[string]]::new()
    $builder = New-Object System.Text.StringBuilder
    $quote = [char]0

    for ($index = 0; $index -lt $Value.Length; $index++) {
        $char = $Value[$index]

        if ($quote -ne [char]0) {
            [void]$builder.Append($char)

            if ($char -eq $quote) {
                if ($quote -eq "'" -and $index + 1 -lt $Value.Length -and $Value[$index + 1] -eq "'") {
                    $index++
                    [void]$builder.Append($Value[$index])
                    continue
                }

                $quote = [char]0
            }

            continue
        }

        if ($char -eq "'" -or $char -eq '"') {
            $quote = $char
            [void]$builder.Append($char)
            continue
        }

        if ($char -eq ',') {
            $items.Add($builder.ToString().Trim()) | Out-Null
            [void]$builder.Clear()
            continue
        }

        [void]$builder.Append($char)
    }

    $items.Add($builder.ToString().Trim()) | Out-Null
    return @($items)
}

function ConvertTo-ManifestYamlValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [string] -or $Value -is [bool]) {
        return ConvertTo-ManifestYamlScalar -Value $Value
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary])) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            return '[]'
        }

        $encodedItems = foreach ($item in $items) {
            if ($null -ne $item -and ($item -is [System.Collections.IDictionary] -or (($null -ne $item.PSObject) -and -not ($item -is [string]) -and -not ($item -is [bool]) -and -not ($item -is [System.ValueType])))) {
                ConvertTo-ManifestYamlScalar -Value ($item | ConvertTo-Json -Compress -Depth 8)
            } else {
                ConvertTo-ManifestYamlScalar -Value $item
            }
        }

        return '[' + ($encodedItems -join ', ') + ']'
    }

    return ConvertTo-ManifestYamlScalar -Value $Value
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

    if ($text -eq 'null') {
        return $null
    }

    return $text
}

function ConvertFrom-ManifestYamlValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = $Value.ToString().Trim()
    if ($text -eq '[]') {
        return @()
    }

    if ($text.Length -ge 2 -and $text.StartsWith('[') -and $text.EndsWith(']')) {
        $inner = $text.Substring(1, $text.Length - 2).Trim()
        if ([string]::IsNullOrWhiteSpace($inner)) {
            return @()
        }

        return @((Split-ManifestYamlInlineList -Value $inner | ForEach-Object {
            ConvertFrom-ManifestYamlScalar -Value $_
        }))
    }

    return ConvertFrom-ManifestYamlScalar -Value $Value
}

function ConvertTo-ManifestPropertyMap {
    param([AllowNull()]$Value)

    $result = [ordered]@{}
    if ($null -eq $Value) {
        return $result
    }

    if ($Value -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = $Value[$key]
        }

        return $result
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) {
            $result[[string]$entry.Key] = $entry.Value
        }

        return $result
    }

    if ($null -ne $Value.PSObject) {
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = $property.Value
        }
    }

    return $result
}

function ConvertTo-ManifestKeyName {
    param([Parameter(Mandatory = $true)][string]$Name)

    switch ($Name) {
        'PaneId' { return 'pane_id' }
        'Role' { return 'role' }
        'ExecMode' { return 'exec_mode' }
        'LaunchDir' { return 'launch_dir' }
        'BuilderBranch' { return 'builder_branch' }
        'BuilderWorktreePath' { return 'builder_worktree_path' }
        'Task' { return 'task' }
        'Status' { return 'status' }
        'BootstrapFailures' { return 'bootstrap_failures' }
        default {
            $snake = [regex]::Replace($Name, '([a-z0-9])([A-Z])', '$1_$2')
            return $snake.ToLowerInvariant()
        }
    }
}

function Write-ManifestTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Content = ''
    )

    Write-WinsmuxTextFile -Path $Path -Content $Content
}

function Get-ManifestDir {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path $ProjectDir $script:ManifestDirName
}

function Get-ManifestPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path (Get-ManifestDir -ProjectDir $ProjectDir) $script:ManifestFileName
}

function Clear-WinsmuxManifest {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $path = Get-ManifestPath -ProjectDir $ProjectDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $false
    }

    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    return $true
}

function New-WinsmuxManifest {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $now = [System.DateTimeOffset]::Now.ToString('o')
    $manifest = [PSCustomObject]@{
        version  = 1
        saved_at = $now
        session  = [PSCustomObject]@{
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
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $path = Get-ManifestPath -ProjectDir $ProjectDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ConvertFrom-ManifestYaml -Content $raw
}

function Save-WinsmuxManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $path = Get-ManifestPath -ProjectDir $ProjectDir
    $yaml = ConvertTo-ManifestYaml -Manifest $Manifest
    Write-ManifestTextFile -Path $path -Content $yaml
}

function ConvertTo-ManifestPaneEntry {
    param([Parameter(Mandatory = $true)]$PaneSummary)

    $entry = [ordered]@{}
    $paneMap = ConvertTo-ManifestPropertyMap -Value $PaneSummary
    foreach ($key in $paneMap.Keys) {
        if ($key -eq 'Label') {
            continue
        }

        $entry[(ConvertTo-ManifestKeyName -Name $key)] = $paneMap[$key]
    }

    return $entry
}

function Update-ManifestPanes {
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
        $panes[[string]$pane.Label] = ConvertTo-ManifestPaneEntry -PaneSummary $pane
    }

    $manifest.panes = $panes
    Save-WinsmuxManifest -ProjectDir $projectDir -Manifest $manifest
}

function Update-ManifestTasks {
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

    $queued = @()
    if ($null -ne $manifest.tasks -and $null -ne $manifest.tasks.queued) {
        $queued = @($manifest.tasks.queued)
    }

    $manifest.tasks = [PSCustomObject]@{
        queued      = @($queued)
        in_progress = @($InProgress)
        completed   = @($Completed)
    }

    Save-WinsmuxManifest -ProjectDir $projectDir -Manifest $manifest
}

function ConvertTo-ManifestYaml {
    param([Parameter(Mandatory = $true)]$Manifest)

    $manifestMap = ConvertTo-ManifestPropertyMap -Value $Manifest
    $sessionMap = ConvertTo-ManifestPropertyMap -Value $manifestMap['session']
    $panesMap = ConvertTo-ManifestPropertyMap -Value $manifestMap['panes']
    $tasksMap = ConvertTo-ManifestPropertyMap -Value $manifestMap['tasks']
    $worktreesMap = ConvertTo-ManifestPropertyMap -Value $manifestMap['worktrees']

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(('version: {0}' -f (ConvertTo-ManifestYamlScalar -Value $(if ($manifestMap.Contains('version')) { $manifestMap['version'] } else { 1 })))) | Out-Null
    $lines.Add(('saved_at: {0}' -f (ConvertTo-ManifestYamlScalar -Value $(if ($manifestMap.Contains('saved_at')) { $manifestMap['saved_at'] } else { [System.DateTimeOffset]::Now.ToString('o') })))) | Out-Null
    $lines.Add('session:') | Out-Null
    foreach ($key in $sessionMap.Keys) {
        $lines.Add(('  {0}: {1}' -f $key, (ConvertTo-ManifestYamlValue -Value $sessionMap[$key]))) | Out-Null
    }

    $lines.Add('panes:') | Out-Null
    if ($panesMap.Count -eq 0) {
        $lines[$lines.Count - 1] = 'panes: {}'
    } else {
        foreach ($label in $panesMap.Keys) {
            $lines.Add(('  {0}:' -f (ConvertTo-ManifestYamlScalar -Value $label))) | Out-Null
            $paneMap = ConvertTo-ManifestPropertyMap -Value $panesMap[$label]
            foreach ($key in $paneMap.Keys) {
                $lines.Add(('    {0}: {1}' -f $key, (ConvertTo-ManifestYamlValue -Value $paneMap[$key]))) | Out-Null
            }
        }
    }

    $lines.Add('tasks:') | Out-Null
    foreach ($taskKey in @('queued', 'in_progress', 'completed')) {
        $lines.Add(('  {0}:' -f $taskKey)) | Out-Null
        $items = @()
        if ($tasksMap.Contains($taskKey) -and $null -ne $tasksMap[$taskKey]) {
            $items = @($tasksMap[$taskKey])
        }

        if ($items.Count -eq 0) {
            $lines[$lines.Count - 1] = ('  {0}: []' -f $taskKey)
        } else {
            foreach ($item in $items) {
                $lines.Add(('    - {0}' -f (ConvertTo-ManifestYamlScalar -Value $item))) | Out-Null
            }
        }
    }

    $lines.Add('worktrees:') | Out-Null
    if ($worktreesMap.Count -eq 0) {
        $lines[$lines.Count - 1] = 'worktrees: {}'
    } else {
        foreach ($label in $worktreesMap.Keys) {
            $lines.Add(('  {0}:' -f (ConvertTo-ManifestYamlScalar -Value $label))) | Out-Null
            $worktreeEntry = ConvertTo-ManifestPropertyMap -Value $worktreesMap[$label]
            foreach ($key in $worktreeEntry.Keys) {
                $lines.Add(('    {0}: {1}' -f $key, (ConvertTo-ManifestYamlValue -Value $worktreeEntry[$key]))) | Out-Null
            }
        }
    }

    return ($lines -join "`n") + "`n"
}

function ConvertFrom-ManifestYaml {
    param([Parameter(Mandatory = $true)][string]$Content)

    $manifest = [PSCustomObject]@{
        version  = 1
        saved_at = ''
        session  = [PSCustomObject]@{}
        panes    = [ordered]@{}
        tasks    = [PSCustomObject]@{
            queued      = @()
            in_progress = @()
            completed   = @()
        }
        worktrees = [ordered]@{}
    }

    $section = ''
    $currentLabel = ''
    $currentMode = ''
    $taskListKey = ''

    foreach ($rawLine in ($Content -split "\r?\n")) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
            continue
        }

        if ($line -match '^version:\s*(.*?)\s*$') {
            $manifest.version = [int](ConvertFrom-ManifestYamlScalar $Matches[1])
            continue
        }

        if ($line -match '^saved_at:\s*(.*?)\s*$') {
            $manifest.saved_at = [string](ConvertFrom-ManifestYamlScalar $Matches[1])
            continue
        }

        if ($line -match '^(session|panes|tasks|worktrees):\s*(\{\})?\s*$') {
            $section = $Matches[1]
            $currentLabel = ''
            $currentMode = ''
            $taskListKey = ''
            continue
        }

        if ($section -eq 'session' -and $line -match '^\s{2}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
            $manifest.session | Add-Member -NotePropertyName $Matches[1] -NotePropertyValue (ConvertFrom-ManifestYamlValue $Matches[2]) -Force
            continue
        }

        if ($section -eq 'panes') {
            if ($line -match '^\s{2}-\s+label:\s*(.*?)\s*$') {
                $currentLabel = [string](ConvertFrom-ManifestYamlScalar $Matches[1])
                if (-not $manifest.panes.Contains($currentLabel)) {
                    $manifest.panes[$currentLabel] = [ordered]@{ label = $currentLabel }
                }
                $currentMode = 'list'
                continue
            }

            if ($line -match '^\s{2}(.+?):\s*$') {
                $currentLabel = [string](ConvertFrom-ManifestYamlScalar $Matches[1])
                if (-not $manifest.panes.Contains($currentLabel)) {
                    $manifest.panes[$currentLabel] = [ordered]@{}
                }
                $currentMode = 'dict'
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($currentLabel) -and $line -match '^\s{4}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
                $manifest.panes[$currentLabel][$Matches[1]] = ConvertFrom-ManifestYamlValue $Matches[2]
                continue
            }
        }

        if ($section -eq 'tasks') {
            if ($line -match '^\s{2}(queued|in_progress|completed):\s*(\[\])?\s*$') {
                $taskListKey = $Matches[1]
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($taskListKey) -and $line -match '^\s{4}-\s*(.*?)\s*$') {
                $items = @($manifest.tasks.$taskListKey)
                $manifest.tasks.$taskListKey = @($items + (ConvertFrom-ManifestYamlScalar $Matches[1]))
                continue
            }
        }

        if ($section -eq 'worktrees') {
            if ($line -match '^\s{2}(.+?):\s*$') {
                $currentLabel = [string](ConvertFrom-ManifestYamlScalar $Matches[1])
                if (-not $manifest.worktrees.Contains($currentLabel)) {
                    $manifest.worktrees[$currentLabel] = [ordered]@{}
                }
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($currentLabel) -and $line -match '^\s{4}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
                $manifest.worktrees[$currentLabel][$Matches[1]] = ConvertFrom-ManifestYamlValue $Matches[2]
                continue
            }
        }
    }

    foreach ($label in @($manifest.panes.Keys)) {
        if ($manifest.panes[$label].Contains('label')) {
            $manifest.panes[$label].Remove('label')
        }
    }

    return $manifest
}
