[CmdletBinding()]
param(
    [string]$BacklogPath = '',

    [string]$RoadmapPath = '',

    [string]$RoadmapTitleJaPath = ''
)

. (Join-Path $PSScriptRoot 'planning-paths.ps1')

function Resolve-WorkspacePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path (Get-Location).Path $Path
}

function ConvertFrom-YamlScalar {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $trimmed = $Value.Trim()

    if ($trimmed.Length -ge 2) {
        if (($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))) {
            return $trimmed.Substring(1, $trimmed.Length - 2)
        }
    }

    return $trimmed
}

function ConvertFrom-YamlInlineList {
    param(
        [string]$Value
    )

    $trimmed = $Value.Trim()
    if ($trimmed -eq '[]') {
        return @()
    }

    if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
        return @((ConvertFrom-YamlScalar -Value $trimmed))
    }

    $inner = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
    if ([string]::IsNullOrWhiteSpace($inner)) {
        return @()
    }

    $items = @()
    foreach ($part in ($inner -split ',')) {
        $parsed = ConvertFrom-YamlScalar -Value $part
        if (-not [string]::IsNullOrWhiteSpace($parsed)) {
            $items += $parsed
        }
    }

    return $items
}

function Get-TaskBlocks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $normalized = $Content -replace "`r`n", "`n"
    $lines = $normalized -split "`n"
    $blocks = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($line in $lines) {
        if ($line -match '^[ \t]*-[ \t]+id:[ \t]*(?<id>\S+)[ \t]*$') {
            if ($null -ne $current -and $current.Count -gt 0) {
                $blocks.Add([pscustomobject]@{
                    Lines = @($current.ToArray())
                })
            }

            $current = New-Object System.Collections.Generic.List[string]
            $current.Add($line)
            continue
        }

        if ($null -ne $current) {
            $current.Add($line)
        }
    }

    if ($null -ne $current -and $current.Count -gt 0) {
        $blocks.Add([pscustomobject]@{
            Lines = @($current.ToArray())
        })
    }

    return $blocks
}

function Get-VersionTitleMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $normalized = $Content -replace "`r`n", "`n"
    $versionTitles = [ordered]@{}

    foreach ($line in ($normalized -split "`n")) {
        if ($line -match '^[ \t]*#[ \t]*===[ \t]*(?<version>v\d+\.\d+\.\d+):[ \t]*(?<title>.+?)[ \t]*===[ \t]*$') {
            $versionTitles[$Matches['version']] = $Matches['title'].Trim()
        }
    }

    return $versionTitles
}

function Get-RoadmapLocalizationMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @{
            VersionTitles = @{}
            TaskTitles    = @{}
        }
    }

    $data = Import-PowerShellDataFile -LiteralPath $Path
    return @{
        VersionTitles = if ($null -ne $data.VersionTitles) { $data.VersionTitles } else { @{} }
        TaskTitles    = if ($null -ne $data.TaskTitles) { $data.TaskTitles } else { @{} }
    }
}

function Get-VersionSortTuple {
    param(
        [AllowNull()]
        [string]$Version
    )

    if ($Version -match '^v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$') {
        return @([int]$Matches['major'], [int]$Matches['minor'], [int]$Matches['patch'])
    }

    return @([int]::MaxValue, [int]::MaxValue, [int]::MaxValue)
}

function Test-VersionGreaterOrEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$MinimumVersion
    )

    $left = Get-VersionSortTuple -Version $Version
    $right = Get-VersionSortTuple -Version $MinimumVersion

    for ($index = 0; $index -lt 3; $index++) {
        if ($left[$index] -gt $right[$index]) {
            return $true
        }

        if ($left[$index] -lt $right[$index]) {
            return $false
        }
    }

    return $true
}

function Test-RequiresJapaneseVersionTitle {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if ($Version -like 'post-v1.0.0*') {
        return $true
    }

    if ($Version -match '^v\d+\.\d+\.\d+$') {
        return Test-VersionGreaterOrEqual -Version $Version -MinimumVersion 'v0.20.0'
    }

    return $false
}

function Convert-TitleFallbackToJapanese {
    param(
        [AllowNull()]
        [string]$Title
    )

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return ''
    }

    $converted = $Title -replace '→', '→'
    $converted = $converted -replace ' +— +', ' — '
    $converted = $converted -replace '^Fix (.+)$', '$1 を修正'
    $converted = $converted -replace '^Add (.+)$', '$1 を追加'
    $converted = $converted -replace '^Create (.+)$', '$1 を作成'
    $converted = $converted -replace '^Implement (.+)$', '$1 を実装'
    $converted = $converted -replace '^Sync (.+)$', '$1 を同期'
    $converted = $converted -replace '^Document (.+)$', '$1 を文書化'
    $converted = $converted -replace '^Write (.+)$', '$1 を作成'
    $converted = $converted -replace '^Run (.+)$', '$1 を実行'
    $converted = $converted -replace '^Release (.+)$', '$1 をリリース'
    $converted = $converted -replace '^Rewrite (.+)$', '$1 を書き直し'
    $converted = $converted -replace '^Remove (.+)$', '$1 を削除'
    $converted = $converted -replace '^Replace (.+)$', '$1 を置換'
    $converted = $converted -replace '^Prevent (.+)$', '$1 を防止'
    $converted = $converted -replace '^Restore (.+)$', '$1 を復元'
    $converted = $converted -replace '^Audit (.+)$', '$1 を監査'
    $converted = $converted -replace '^Complete (.+)$', '$1 を完了'
    $converted = $converted -replace '^Prepare and submit PR to (.+)$', '$1 への PR を準備して提出'

    return $converted
}

function Get-RoadmapVersionTitle {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [AllowNull()]
        [string]$DefaultTitle,

        [Parameter(Mandatory = $true)]
        [hashtable]$Localization
    )

    if ($Localization.ContainsKey($Version)) {
        return [string]$Localization[$Version]
    }

    return $DefaultTitle
}

function Get-RoadmapTaskTitle {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Task,

        [Parameter(Mandatory = $true)]
        [hashtable]$Localization
    )

    $hasOverride = $Localization.ContainsKey($Task.Id)
    $title = if ($hasOverride) { [string]$Localization[$Task.Id] } else { Convert-TitleFallbackToJapanese -Title $Task.Title }

    return [pscustomobject]@{
        Title       = $title
        HasOverride = $hasOverride
    }
}

function ConvertFrom-TaskBlock {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    if ($Lines[0] -notmatch '^[ \t]*-[ \t]+id:[ \t]*(?<id>\S+)[ \t]*$') {
        return $null
    }

    $values = @{
        id            = $Matches['id']
        title         = ''
        status        = ''
        priority      = ''
        target_version = ''
        repo          = ''
        files         = @()
        paths         = @()
        artifacts     = @()
        changed_files = @()
    }

    $listKeys = @('files', 'paths', 'artifacts', 'changed_files')
    $currentListKey = $null

    for ($index = 1; $index -lt $Lines.Count; $index++) {
        $line = $Lines[$index]

        if ($line -match '^[ \t]{4}(?<key>[a-z_]+):[ \t]*(?<value>.*)$') {
            $key = $Matches['key']
            $value = $Matches['value']
            $currentListKey = $null

            if ($key -in $listKeys) {
                if ([string]::IsNullOrWhiteSpace($value)) {
                    $values[$key] = @()
                    $currentListKey = $key
                    continue
                }

                $values[$key] = ConvertFrom-YamlInlineList -Value $value
                continue
            }

            if ($value -in @('>', '|')) {
                continue
            }

            $values[$key] = ConvertFrom-YamlScalar -Value $value
            continue
        }

        if ($null -ne $currentListKey -and $line -match '^[ \t]{6}-[ \t]*(?<item>.+)$') {
            $values[$currentListKey] += ConvertFrom-YamlScalar -Value $Matches['item']
        }
    }

    $taskIdNumber = [int]::MaxValue
    if ($values['id'] -match 'TASK-(?<number>\d+)$') {
        $taskIdNumber = [int]$Matches['number']
    }

    return [pscustomobject]@{
        Id            = $values['id']
        IdNumber      = $taskIdNumber
        Title         = $values['title']
        Status        = $values['status']
        Priority      = $values['priority']
        TargetVersion = $values['target_version']
        Repo          = $values['repo']
        Files         = @($values['files'])
        Paths         = @($values['paths'])
        Artifacts     = @($values['artifacts'])
        ChangedFiles  = @($values['changed_files'])
    }
}

function Set-TaskStatusInContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    $taskPattern = '(?m)^[ \t]*-[ \t]+id:[ \t]*' + [regex]::Escape($TaskId) + '[ \t]*$'
    $taskMatch = [regex]::Match($Content, $taskPattern)

    if (-not $taskMatch.Success) {
        return $Content
    }

    $searchStart = $taskMatch.Index + $taskMatch.Length
    $remainingContent = $Content.Substring($searchStart)
    $nextTaskMatch = [regex]::Match($remainingContent, '(?m)^[ \t]*-[ \t]+id:[ \t]*')
    $taskBlockLength = if ($nextTaskMatch.Success) { $nextTaskMatch.Index } else { $remainingContent.Length }
    $taskBlock = $remainingContent.Substring(0, $taskBlockLength)

    $statusPattern = '(?m)^(?<indent>[ \t]*)status:[ \t]*(?<value>[^#\r\n]*?)(?<suffix>[ \t]*(?:#.*)?)$'
    $statusMatch = [regex]::Match($taskBlock, $statusPattern)
    if (-not $statusMatch.Success) {
        return $Content
    }

    $newStatusLine = '{0}status: {1}{2}' -f $statusMatch.Groups['indent'].Value, $Status, $statusMatch.Groups['suffix'].Value
    $updatedTaskBlock = [regex]::Replace($taskBlock, $statusPattern, [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $newStatusLine
    }, 1)

    return $Content.Substring(0, $searchStart) + $updatedTaskBlock + $remainingContent.Substring($taskBlockLength)
}

function Get-NormalizedTokens {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $stopWords = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($word in @(
        'add', 'all', 'and', 'auto', 'before', 'build', 'change', 'changes', 'command', 'commands',
        'create', 'detect', 'document', 'enforce', 'feature', 'files', 'fix', 'for', 'from', 'full',
        'implement', 'integration', 'local', 'make', 'next', 'not', 'part', 'public', 'run', 'runtime',
        'system', 'task', 'tasks', 'test', 'tests', 'the', 'use', 'with', 'without', 'write'
    )) {
        $null = $stopWords.Add($word)
    }

    $normalized = $Text.ToLowerInvariant() -replace '[^a-z0-9]+', ' '
    $tokens = foreach ($token in ($normalized -split '\s+')) {
        if ($token.Length -lt 3) {
            continue
        }

        if ($stopWords.Contains($token)) {
            continue
        }

        $token
    }

    return @($tokens | Select-Object -Unique)
}

function Get-PathScore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $titleTokens = Get-NormalizedTokens -Text $Title
    if ($titleTokens.Count -eq 0) {
        return 0
    }

    $pathTokens = Get-NormalizedTokens -Text ($Path -replace '\\', '/')
    if ($pathTokens.Count -eq 0) {
        return 0
    }

    $pathTokenSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($token in $pathTokens) {
        $null = $pathTokenSet.Add($token)
    }

    $fileStem = [System.IO.Path]::GetFileNameWithoutExtension($Path).ToLowerInvariant()
    $score = 0
    foreach ($token in $titleTokens) {
        if ($pathTokenSet.Contains($token)) {
            $score += 1
        }

        if ($fileStem.Contains($token)) {
            $score += 2
        }
    }

    return $score
}

function Test-GitTrackedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    & git ls-files --error-unmatch -- $Path 1>$null 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-GitIgnoredPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    & git check-ignore --quiet -- $Path 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-TaskReferenceFiles {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Task,

        [Parameter(Mandatory = $true)]
        [string]$RoadmapPath
    )

    $explicitFiles = @(
        @($Task.Files)
        @($Task.Paths)
        @($Task.Artifacts)
        @($Task.ChangedFiles)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    if ($explicitFiles.Count -gt 0) {
        return @($explicitFiles)
    }

    $ignoredBookkeeping = @(
        'tasks/backlog.yaml',
        'docs/project/ROADMAP.md',
        ($RoadmapPath -replace '\\', '/')
    )

    $commitIdsOutput = & git log --all --format=%H --grep $Task.Id -n 20 2>$null
    $commitIds = @($commitIdsOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($commitIds.Count -eq 0) {
        return @()
    }

    $fallbackPaths = @()

    foreach ($commitId in $commitIds) {
        $pathsOutput = & git show --name-only --format= $commitId 2>$null
        $paths = @($pathsOutput | ForEach-Object { $_.Trim() } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and ($ignoredBookkeeping -notcontains ($_ -replace '\\', '/'))
        } | Select-Object -Unique)

        if ($paths.Count -eq 0) {
            continue
        }

        if ($fallbackPaths.Count -eq 0) {
            $fallbackPaths = @($paths)
        }

        $scoredPaths = foreach ($path in $paths) {
            [pscustomobject]@{
                Path  = $path
                Score = Get-PathScore -Title $Task.Title -Path $path
            }
        }

        $bestScore = ($scoredPaths | Measure-Object -Property Score -Maximum).Maximum
        if ($bestScore -gt 0) {
            return @($scoredPaths | Where-Object { $_.Score -eq $bestScore } | Select-Object -ExpandProperty Path -Unique)
        }
    }

    return @($fallbackPaths | Select-Object -Unique)
}

function Get-StatusSymbol {
    param(
        [AllowNull()]
        [string]$Status
    )

    switch (($Status ?? '').ToLowerInvariant()) {
        'done' { return '[x]' }
        'review' { return '[R]' }
        'in-progress' { return '[-]' }
        'in_progress' { return '[-]' }
        'doing' { return '[-]' }
        'active' { return '[-]' }
        'cancelled' { return '[~]' }
        default { return '[ ]' }
    }
}

function Get-PriorityRank {
    param(
        [AllowNull()]
        [string]$Priority
    )

    switch (($Priority ?? '').ToUpperInvariant()) {
        'P0' { return 0 }
        'P1' { return 1 }
        'P2' { return 2 }
        'P3' { return 3 }
        default { return 9 }
    }
}

function Get-VersionSortKey {
    param(
        [AllowNull()]
        [string]$Version
    )

    if ($Version -match '^v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$') {
        return [pscustomobject]@{
            Major = [int]$Matches['major']
            Minor = [int]$Matches['minor']
            Patch = [int]$Matches['patch']
            Raw   = $Version
        }
    }

    return [pscustomobject]@{
        Major = [int]::MaxValue
        Minor = [int]::MaxValue
        Patch = [int]::MaxValue
        Raw   = ($Version ?? '')
    }
}

function New-ProgressBar {
    param(
        [int]$DoneCount,

        [int]$TotalCount
    )

    if ($TotalCount -le 0) {
        return '[--------------------] 0% (0/0)'
    }

    $percentage = [int][math]::Round(($DoneCount / $TotalCount) * 100, 0, [System.MidpointRounding]::AwayFromZero)
    $filledCount = [int][math]::Round(($DoneCount / $TotalCount) * 20, 0, [System.MidpointRounding]::AwayFromZero)
    $filledCount = [Math]::Min([Math]::Max($filledCount, 0), 20)
    $emptyCount = 20 - $filledCount

    $bar = ('=' * $filledCount) + ('-' * $emptyCount)
    return '[{0}] {1}% ({2}/{3})' -f $bar, $percentage, $DoneCount, $TotalCount
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($BacklogPath)) {
    $BacklogPath = Resolve-WinsmuxPlanningFilePath -RepoRoot $repoRoot -LocalRelativePath 'tasks/backlog.yaml' -EnvironmentVariable 'WINSMUX_BACKLOG_PATH' -DefaultFileName 'backlog.yaml'
}
if ([string]::IsNullOrWhiteSpace($RoadmapPath)) {
    $RoadmapPath = Resolve-WinsmuxPlanningFilePath -RepoRoot $repoRoot -LocalRelativePath 'docs/project/ROADMAP.md' -EnvironmentVariable 'WINSMUX_ROADMAP_PATH' -DefaultFileName 'ROADMAP.md'
}
if ([string]::IsNullOrWhiteSpace($RoadmapTitleJaPath)) {
    $RoadmapTitleJaPath = Resolve-WinsmuxPlanningFilePath `
        -RepoRoot $repoRoot `
        -LocalRelativePath 'tasks/roadmap-title-ja.example.psd1' `
        -EnvironmentVariable 'WINSMUX_ROADMAP_TITLE_JA_PATH' `
        -DefaultFileName 'roadmap-title-ja.psd1'
}

$resolvedBacklogPath = Resolve-WorkspacePath -Path $BacklogPath
$resolvedRoadmapPath = Resolve-WorkspacePath -Path $RoadmapPath
$resolvedRoadmapTitleJaPath = Resolve-WorkspacePath -Path $RoadmapTitleJaPath
$roadmapRelativePath = [System.IO.Path]::GetRelativePath((Get-Location).Path, $resolvedRoadmapPath) -replace '\\', '/'

if (-not (Test-Path -LiteralPath $resolvedBacklogPath)) {
    Write-Warning "Backlog not found: $resolvedBacklogPath"
    exit 0
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$backlogContent = [System.IO.File]::ReadAllText($resolvedBacklogPath, $utf8NoBom)
$versionTitles = Get-VersionTitleMap -Content $backlogContent
$roadmapLocalization = Get-RoadmapLocalizationMap -Path $resolvedRoadmapTitleJaPath
$taskBlocks = @(Get-TaskBlocks -Content $backlogContent)
$tasks = @(
foreach ($taskBlock in $taskBlocks) {
    $parsedTask = ConvertFrom-TaskBlock -Lines @($taskBlock.Lines)
    if ($null -ne $parsedTask) {
        $parsedTask
    }
}
)

$downgradedTasks = New-Object System.Collections.Generic.List[object]
$validationWarnings = New-Object System.Collections.Generic.List[string]
$missingJapaneseTitles = New-Object System.Collections.Generic.List[string]
$missingJapaneseVersionTitles = New-Object System.Collections.Generic.List[string]

foreach ($task in $tasks | Where-Object { $_.Status -eq 'review' }) {
    $referenceFiles = Get-TaskReferenceFiles -Task $task -RoadmapPath $roadmapRelativePath
    if ($referenceFiles.Count -eq 0) {
        $validationWarnings.Add("Review validation warning for $($task.Id): no candidate files found.")
        continue
    }

    $trackedFiles = @()
    $ignoredFiles = @()
    $otherFiles = @()

    foreach ($path in $referenceFiles) {
        if (Test-GitTrackedPath -Path $path) {
            $trackedFiles += $path
            continue
        }

        if (Test-GitIgnoredPath -Path $path) {
            $ignoredFiles += $path
            continue
        }

        $otherFiles += $path
    }

    if ($trackedFiles.Count -gt 0) {
        continue
    }

    if ($ignoredFiles.Count -gt 0) {
        $task.Status = 'backlog'
        $backlogContent = Set-TaskStatusInContent -Content $backlogContent -TaskId $task.Id -Status 'backlog'
        $downgradedTasks.Add([pscustomobject]@{
            Id    = $task.Id
            Files = @($ignoredFiles)
        })
        continue
    }

    $validationWarnings.Add("Review validation warning for $($task.Id): no tracked files found. Candidates: $($otherFiles -join ', ')")
}

if ($downgradedTasks.Count -gt 0) {
    [System.IO.File]::WriteAllText($resolvedBacklogPath, $backlogContent, $utf8NoBom)
}

$tasksWithoutTargetVersion = @($tasks | Where-Object { [string]::IsNullOrWhiteSpace($_.TargetVersion) })
foreach ($task in $tasksWithoutTargetVersion) {
    $validationWarnings.Add(("Roadmap sync warning for {0}: empty target_version. Skipping from version-grouped roadmap output." -f $task.Id))
}

$tasksWithTargetVersion = @($tasks | Where-Object { -not [string]::IsNullOrWhiteSpace($_.TargetVersion) })

$versionGroupMap = [ordered]@{}
foreach ($group in ($tasksWithTargetVersion | Group-Object -Property TargetVersion)) {
    $versionGroupMap[$group.Name] = [pscustomobject]@{
        Name  = $group.Name
        Group = @($group.Group)
    }
}

foreach ($version in $versionTitles.Keys) {
    if (-not $versionGroupMap.Contains($version)) {
        $versionGroupMap[$version] = [pscustomobject]@{
            Name  = $version
            Group = @()
        }
    }
}

$versionGroups = @($versionGroupMap.Values) |
    Sort-Object @{ Expression = { (Get-VersionSortKey -Version $_.Name).Major } }, @{ Expression = { (Get-VersionSortKey -Version $_.Name).Minor } }, @{ Expression = { (Get-VersionSortKey -Version $_.Name).Patch } }, @{ Expression = { (Get-VersionSortKey -Version $_.Name).Raw } }

$builder = [System.Text.StringBuilder]::new()

[void]$builder.AppendLine('# ロードマップ')
[void]$builder.AppendLine()
[void]$builder.AppendLine('> planning backlog から自動生成 — 手動編集禁止')
[void]$builder.AppendLine(('> 最終同期: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm (zzz)')))
[void]$builder.AppendLine()
[void]$builder.AppendLine('## バージョン概要')
[void]$builder.AppendLine()
[void]$builder.AppendLine('| バージョン | タスク数 | 進捗 |')
[void]$builder.AppendLine('|-----------|---------|------|')

foreach ($versionGroup in $versionGroups) {
    $versionTasks = @($versionGroup.Group)
    $totalCount = $versionTasks.Count
    $doneCount = @($versionTasks | Where-Object { $_.Status -eq 'done' }).Count
    $progress = New-ProgressBar -DoneCount $doneCount -TotalCount $totalCount
    [void]$builder.AppendLine(('| {0} | {1} | {2} |' -f $versionGroup.Name, $totalCount, $progress))
}

[void]$builder.AppendLine()
[void]$builder.AppendLine('## タスク詳細')
[void]$builder.AppendLine()

foreach ($versionGroup in $versionGroups) {
    $vName = $versionGroup.Name
    $defaultVersionTitle = if ($versionTitles.Contains($vName)) { $versionTitles[$vName] } else { '' }
    $localizedVersionTitle = Get-RoadmapVersionTitle -Version $vName -DefaultTitle $defaultVersionTitle -Localization $roadmapLocalization.VersionTitles
    $titleSuffix = if (-not [string]::IsNullOrWhiteSpace($localizedVersionTitle)) { ': ' + $localizedVersionTitle } else { '' }
    [void]$builder.AppendLine(('### {0}{1}' -f $vName, $titleSuffix))
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('| | ID | Title | Priority | Repo | Status |')
    [void]$builder.AppendLine('|-|-----|-------|----------|------|--------|')

    $sortedTasks = @($versionGroup.Group | Sort-Object @{ Expression = { Get-PriorityRank -Priority $_.Priority } }, @{ Expression = { $_.IdNumber } }, @{ Expression = { $_.Id } })
    foreach ($task in $sortedTasks) {
        $localizedTaskTitle = Get-RoadmapTaskTitle -Task $task -Localization $roadmapLocalization.TaskTitles
        [void]$builder.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f (Get-StatusSymbol -Status $task.Status), $task.Id, $localizedTaskTitle.Title, $task.Priority, $task.Repo, $task.Status))
    }

    [void]$builder.AppendLine()
}

[void]$builder.AppendLine('## 凡例')
[void]$builder.AppendLine()
[void]$builder.AppendLine('| 記号 | 意味 |')
[void]$builder.AppendLine('|------|------|')
[void]$builder.AppendLine('| [x] | 完了 |')
[void]$builder.AppendLine('| [-] | 作業中 |')
[void]$builder.AppendLine('| [R] | レビュー中 |')
[void]$builder.AppendLine('| [ ] | 未着手 |')
[void]$builder.AppendLine()
[void]$builder.AppendLine('| 優先度 | 意味 |')
[void]$builder.AppendLine('|--------|------|')
[void]$builder.AppendLine('| P0 | 最重要 |')
[void]$builder.AppendLine('| P1 | 高 |')
[void]$builder.AppendLine('| P2 | 中 |')
[void]$builder.AppendLine('| P3 | 低 |')

foreach ($downgradedTask in $downgradedTasks) {
    Write-Output ("Downgraded {0}: review -> backlog (gitignored: {1})" -f $downgradedTask.Id, ($downgradedTask.Files -join ', '))
}

foreach ($warning in $validationWarnings) {
    Write-Warning $warning
}

foreach ($task in $tasksWithTargetVersion) {
    if (-not (Test-VersionGreaterOrEqual -Version $task.TargetVersion -MinimumVersion 'v0.20.0')) {
        continue
    }

    $localizedTaskTitle = Get-RoadmapTaskTitle -Task $task -Localization $roadmapLocalization.TaskTitles
    if (-not $localizedTaskTitle.HasOverride) {
        $missingJapaneseTitles.Add(('{0} ({1})' -f $task.Id, $task.Title))
    }
}

foreach ($versionGroup in $versionGroups) {
    if (-not (Test-RequiresJapaneseVersionTitle -Version $versionGroup.Name)) {
        continue
    }

    if (-not $roadmapLocalization.VersionTitles.ContainsKey($versionGroup.Name)) {
        $missingJapaneseVersionTitles.Add($versionGroup.Name)
    }
}

if ($missingJapaneseVersionTitles.Count -gt 0) {
    $missingVersionList = $missingJapaneseVersionTitles | Sort-Object
    Write-Error ("Roadmap Japanese version-title gate failed. Add version title overrides to {0} for: {1}" -f $resolvedRoadmapTitleJaPath, ($missingVersionList -join ', '))
    exit 1
}

if ($missingJapaneseTitles.Count -gt 0) {
    $missingList = $missingJapaneseTitles | Sort-Object
    Write-Error ("Roadmap Japanese title gate failed. Add task title overrides to {0} for: {1}" -f $resolvedRoadmapTitleJaPath, ($missingList -join ', '))
    exit 1
}

$roadmapDirectory = Split-Path -Parent $resolvedRoadmapPath
if (-not [string]::IsNullOrWhiteSpace($roadmapDirectory)) {
    New-Item -ItemType Directory -Force -Path $roadmapDirectory 1>$null
}

[System.IO.File]::WriteAllText($resolvedRoadmapPath, $builder.ToString(), $utf8NoBom)

$syncInternalDocsScript = Join-Path $PSScriptRoot 'sync-internal-docs.ps1'
if (Test-Path -LiteralPath $syncInternalDocsScript) {
    try {
        & $syncInternalDocsScript -BacklogPath $resolvedBacklogPath -RoadmapTitleJaPath $resolvedRoadmapTitleJaPath
    } catch {
        Write-Error ("Internal docs sync failed via {0}: {1}" -f $syncInternalDocsScript, $_.Exception.Message)
        exit 1
    }
}

Write-Output ("Generated roadmap: {0}" -f $resolvedRoadmapPath)
