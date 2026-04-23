[CmdletBinding()]
param(
    [string]$BacklogPath = '',
    [string]$RoadmapTitleJaPath = '',
    [string]$FeatureInventoryPath = '',
    [string]$ManualChecklistPath = '',
    [string]$MetaPath = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'planning-paths.ps1')

function Resolve-WorkspacePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path (Get-Location).Path $Path
}

function ConvertFrom-YamlScalar {
    param([AllowNull()][string]$Value)

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
    param([string]$Value)

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
    param([Parameter(Mandatory = $true)][string]$Content)

    $normalized = $Content -replace "`r`n", "`n"
    $lines = $normalized -split "`n"
    $blocks = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($line in $lines) {
        if ($line -match '^[ \t]*-[ \t]+id:[ \t]*(?<id>\S+)[ \t]*$') {
            if ($null -ne $current -and $current.Count -gt 0) {
                $blocks.Add([pscustomobject]@{ Lines = @($current.ToArray()) })
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
        $blocks.Add([pscustomobject]@{ Lines = @($current.ToArray()) })
    }

    return $blocks
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
        id = $Matches['id']
        title = ''
        status = ''
        target_version = ''
    }

    for ($index = 1; $index -lt $Lines.Count; $index++) {
        $line = $Lines[$index]
        if ($line -match '^[ \t]{4}(?<key>[a-z_]+):[ \t]*(?<value>.*)$') {
            $key = $Matches['key']
            $value = $Matches['value']

            if ($value -in @('>', '|')) {
                continue
            }

            $values[$key] = if ($value.Trim().StartsWith('[')) { ConvertFrom-YamlInlineList -Value $value } else { ConvertFrom-YamlScalar -Value $value }
        }
    }

    return [pscustomobject]@{
        Id = $values['id']
        Title = $values['title']
        Status = $values['status']
        TargetVersion = $values['target_version']
    }
}

function Get-VersionTitleMap {
    param([Parameter(Mandatory = $true)][string]$Content)

    $normalized = $Content -replace "`r`n", "`n"
    $versionTitles = [ordered]@{}
    foreach ($line in ($normalized -split "`n")) {
        if ($line -match '^[ \t]*#[ \t]*===[ \t]*(?<version>[^:]+):[ \t]*(?<title>.+?)[ \t]*===[ \t]*$') {
            $versionTitles[$Matches['version'].Trim()] = $Matches['title'].Trim()
        }
    }

    return $versionTitles
}

function Get-RoadmapLocalizationMap {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ VersionTitles = @{}; TaskTitles = @{} }
    }

    $data = Import-PowerShellDataFile -LiteralPath $Path
    return @{
        VersionTitles = if ($null -ne $data.VersionTitles) { $data.VersionTitles } else { @{} }
        TaskTitles = if ($null -ne $data.TaskTitles) { $data.TaskTitles } else { @{} }
    }
}

function Get-VersionSortTuple {
    param([AllowNull()][string]$Version)

    if ($Version -match '^v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$') {
        return @([int]$Matches['major'], [int]$Matches['minor'], [int]$Matches['patch'], $Version)
    }

    if ($Version -eq 'pending') {
        return @(9998, 0, 0, $Version)
    }

    return @(9997, 0, 0, ($Version ?? ''))
}

function Get-PlanningState {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$TaskIds,
        [Parameter(Mandatory = $true)][hashtable]$TasksById
    )

    $statuses = @()
    foreach ($taskId in $TaskIds) {
        if ($TasksById.ContainsKey($taskId)) {
            $statuses += ($TasksById[$taskId].Status ?? '')
        }
    }

    if ($statuses.Count -eq 0) {
        return '今後予定'
    }

    foreach ($status in $statuses) {
        if ($status -eq 'done') {
            return '公開済み'
        }
    }

    foreach ($status in $statuses) {
        if ($status -in @('active', 'review', 'in-progress', 'in_progress', 'doing')) {
            return '進行中'
        }
    }

    return '今後予定'
}

function Get-VersionLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][hashtable]$VersionTitles,
        [Parameter(Mandatory = $true)][hashtable]$LocalizedVersionTitles
    )

    if ($LocalizedVersionTitles.ContainsKey($Version)) {
        return ('{0}: {1}' -f $Version, [string]$LocalizedVersionTitles[$Version])
    }

    if ($VersionTitles.ContainsKey($Version)) {
        return ('{0}: {1}' -f $Version, [string]$VersionTitles[$Version])
    }

    return $Version
}

function New-FeatureInventorySection {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [Parameter(Mandatory = $true)][hashtable]$TasksById,
        [Parameter(Mandatory = $true)][hashtable]$VersionTitles,
        [Parameter(Mandatory = $true)][hashtable]$LocalizedVersionTitles,
        [Parameter(Mandatory = $true)][int]$StartNumber
    )

    $filtered = @($Entries | Where-Object { (Get-PlanningState -TaskIds $_.TaskIds -TasksById $TasksById) -eq $State } | Sort-Object Order)
    $builder = [System.Text.StringBuilder]::new()
    $currentCategory = ''
    $number = $StartNumber

    foreach ($entry in $filtered) {
        if ($entry.Category -ne $currentCategory) {
            if ($builder.Length -gt 0) {
                [void]$builder.AppendLine()
            }
            [void]$builder.AppendLine(("### {0}" -f $entry.Category))
            [void]$builder.AppendLine()
            $currentCategory = $entry.Category
        }

        $taskLabel = ($entry.TaskIds -join ', ')
        [void]$builder.AppendLine(("#### {0}. {1}" -f $number, $entry.Title))
        [void]$builder.AppendLine('利用者ができること:')
        [void]$builder.AppendLine($entry.UserValue)
        [void]$builder.AppendLine()
        [void]$builder.AppendLine('どんな場面で使うか:')
        [void]$builder.AppendLine($entry.UseCase)
        [void]$builder.AppendLine()
        [void]$builder.AppendLine(("今の状態: {0}  " -f $State))
        [void]$builder.AppendLine(("実装版: {0}  " -f $entry.ImplementationVersion))
        [void]$builder.AppendLine(("根拠作業番号: {0}" -f $taskLabel))
        [void]$builder.AppendLine()
        $number += 1
    }

    return [pscustomobject]@{
        Content = $builder.ToString().TrimEnd()
        NextNumber = $number
    }
}

function New-DynamicAppendixRows {
    param(
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [Parameter(Mandatory = $true)][hashtable]$TasksById
    )

    $rows = foreach ($entry in ($Entries | Sort-Object Order)) {
        $state = Get-PlanningState -TaskIds $entry.TaskIds -TasksById $TasksById
        $taskLabel = ($entry.TaskIds -join ',')
        ('| {0} | {1} | {2} | {3} | {4} |' -f $entry.AppendixName, $state, $entry.ImplementationVersion, $taskLabel, $entry.TestFocus)
    }

    return ($rows -join "`r`n")
}

function New-ChecklistRows {
    param(
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [Parameter(Mandatory = $true)][hashtable]$TasksById,
        [Parameter(Mandatory = $true)][hashtable]$VersionTitles,
        [Parameter(Mandatory = $true)][hashtable]$LocalizedVersionTitles
    )

    $rows = foreach ($entry in ($Entries | Sort-Object Order)) {
        $state = Get-PlanningState -TaskIds $entry.TaskIds -TasksById $TasksById
        $versionLabel = Get-VersionLabel -Version $entry.Version -VersionTitles $VersionTitles -LocalizedVersionTitles $LocalizedVersionTitles
        ('| {0} | {1} | {2} | {3} | [ ] 未 | [ ] | {4} |' -f $versionLabel, $state, $entry.Focus, $entry.Example, $entry.Memo)
    }

    return ($rows -join "`r`n")
}

function Set-UpdatedDateLine {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$DateText
    )

    $regex = [regex]::new('(?m)^更新日:\s*.+$')
    return $regex.Replace($Content, "更新日: $DateText", 1)
}

function Replace-Section {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$StartHeader,
        [Parameter(Mandatory = $true)][string]$EndHeader,
        [Parameter(Mandatory = $true)][string]$ReplacementBody
    )

    $pattern = "(?s)(^## $([regex]::Escape($StartHeader))\r?\n\r?\n).*?(?=^## $([regex]::Escape($EndHeader))\r?\n)"
    $regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    return $regex.Replace($Content, ('$1' + $ReplacementBody.TrimEnd() + "`r`n`r`n"), 1)
}

function Replace-MarkerBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$MarkerName,
        [Parameter(Mandatory = $true)][string]$ReplacementBody
    )

    $start = "<!-- AUTO-GENERATED:$MarkerName:start -->"
    $end = "<!-- AUTO-GENERATED:$MarkerName:end -->"
    $startIndex = $Content.IndexOf($start, [System.StringComparison]::Ordinal)
    if ($startIndex -lt 0) {
        return $Content
    }

    $endIndex = $Content.IndexOf($end, $startIndex, [System.StringComparison]::Ordinal)
    if ($endIndex -lt 0) {
        return $Content
    }

    $replacement = $start + "`r`n" + $ReplacementBody.TrimEnd() + "`r`n" + $end
    $prefix = $Content.Substring(0, $startIndex)
    $suffix = $Content.Substring($endIndex + $end.Length)
    return $prefix + $replacement + $suffix
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($BacklogPath)) {
    $BacklogPath = Resolve-WinsmuxPlanningFilePath -RepoRoot $repoRoot -LocalRelativePath 'tasks/backlog.yaml' -EnvironmentVariable 'WINSMUX_BACKLOG_PATH' -DefaultFileName 'backlog.yaml'
}
if ([string]::IsNullOrWhiteSpace($RoadmapTitleJaPath)) {
    $RoadmapTitleJaPath = Resolve-WinsmuxPlanningFilePath `
        -RepoRoot $repoRoot `
        -LocalRelativePath 'tasks/roadmap-title-ja.example.psd1' `
        -EnvironmentVariable 'WINSMUX_ROADMAP_TITLE_JA_PATH' `
        -DefaultFileName 'roadmap-title-ja.psd1'
}
if ([string]::IsNullOrWhiteSpace($FeatureInventoryPath)) {
    $FeatureInventoryPath = Join-Path $repoRoot 'docs\internal\winsmux-feature-inventory.md'
}
if ([string]::IsNullOrWhiteSpace($ManualChecklistPath)) {
    $ManualChecklistPath = Join-Path $repoRoot 'docs\internal\winsmux-manual-checklist-by-version.md'
}
if ([string]::IsNullOrWhiteSpace($MetaPath)) {
    $MetaPath = Join-Path $PSScriptRoot 'internal-docs-meta.psd1'
}

$resolvedBacklogPath = Resolve-WorkspacePath -Path $BacklogPath
$resolvedRoadmapTitleJaPath = Resolve-WorkspacePath -Path $RoadmapTitleJaPath
$resolvedFeatureInventoryPath = Resolve-WorkspacePath -Path $FeatureInventoryPath
$resolvedManualChecklistPath = Resolve-WorkspacePath -Path $ManualChecklistPath
$resolvedMetaPath = Resolve-WorkspacePath -Path $MetaPath

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$backlogContent = [System.IO.File]::ReadAllText($resolvedBacklogPath, $utf8NoBom)
$versionTitles = Get-VersionTitleMap -Content $backlogContent
$localization = Get-RoadmapLocalizationMap -Path $resolvedRoadmapTitleJaPath
$meta = Import-PowerShellDataFile -LiteralPath $resolvedMetaPath

$tasks = @()
foreach ($block in (Get-TaskBlocks -Content $backlogContent)) {
    $task = ConvertFrom-TaskBlock -Lines @($block.Lines)
    if ($null -ne $task) {
        $tasks += $task
    }
}

$tasksById = @{}
foreach ($task in $tasks) {
    $tasksById[$task.Id] = $task
}

$dateText = Get-Date -Format 'yyyy-MM-dd'
$activeSection = New-FeatureInventorySection -State '進行中' -Entries $meta.FeatureInventoryEntries -TasksById $tasksById -VersionTitles $versionTitles -LocalizedVersionTitles $localization.VersionTitles -StartNumber 26
$plannedSection = New-FeatureInventorySection -State '今後予定' -Entries $meta.FeatureInventoryEntries -TasksById $tasksById -VersionTitles $versionTitles -LocalizedVersionTitles $localization.VersionTitles -StartNumber $activeSection.NextNumber
$checklistRows = $(
    foreach ($entry in ($meta.ManualChecklistEntries | Sort-Object Order)) {
        $state = Get-PlanningState -TaskIds $entry.TaskIds -TasksById $tasksById
        $versionLabel = Get-VersionLabel -Version $entry.Version -VersionTitles $versionTitles -LocalizedVersionTitles $localization.VersionTitles
        ('| {0} | {1} | {2} | {3} | [ ] 未 | [ ] | {4} |' -f $versionLabel, $state, $entry.Focus, $entry.Example, $entry.Memo)
    }
) -join "`r`n"

$featureContent = [System.IO.File]::ReadAllText($resolvedFeatureInventoryPath, $utf8NoBom)
$featureContent = Set-UpdatedDateLine -Content $featureContent -DateText $dateText
$featureContent = Replace-Section -Content $featureContent -StartHeader '進行中（未公開）' -EndHeader '今後実装予定' -ReplacementBody ($activeSection.Content + "`r`n`r`n> この章は backlog から自動同期されます。")
$featureContent = Replace-Section -Content $featureContent -StartHeader '今後実装予定' -EndHeader '付録' -ReplacementBody ($plannedSection.Content + "`r`n`r`n> この章は backlog から自動同期されます。")
[System.IO.File]::WriteAllText($resolvedFeatureInventoryPath, $featureContent, $utf8NoBom)

$checklistContent = [System.IO.File]::ReadAllText($resolvedManualChecklistPath, $utf8NoBom)
$checklistContent = Set-UpdatedDateLine -Content $checklistContent -DateText $dateText
$checklistSection = @"
| 版 | 状態 | 実装後に重点確認すること | 確認例 | 結果 | 収録候補 | メモ |
| --- | --- | --- | --- | --- | --- | --- |
$checklistRows

> この章は backlog から自動同期されます。
"@
$checklistContent = Replace-Section -Content $checklistContent -StartHeader '進行中・今後予定の確認表' -EndHeader '総合確認の進め方' -ReplacementBody $checklistSection
[System.IO.File]::WriteAllText($resolvedManualChecklistPath, $checklistContent, $utf8NoBom)

Write-Output ("Generated internal docs: {0}, {1}" -f $resolvedFeatureInventoryPath, $resolvedManualChecklistPath)
