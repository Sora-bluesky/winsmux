[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [Parameter(Mandatory = $true)]
    [string]$Status,

    [string]$BacklogPath = 'tasks/backlog.yaml'
)

$resolvedBacklogPath = if ([System.IO.Path]::IsPathRooted($BacklogPath)) {
    $BacklogPath
} else {
    Join-Path (Get-Location).Path $BacklogPath
}

if (-not (Test-Path -LiteralPath $resolvedBacklogPath)) {
    Write-Warning "Backlog not found: $resolvedBacklogPath"
    exit 0
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$content = [System.IO.File]::ReadAllText($resolvedBacklogPath, $utf8NoBom)

$taskPattern = '(?m)^[ \t]*-[ \t]+id:[ \t]*' + [regex]::Escape($TaskId) + '[ \t]*$'
$taskMatch = [regex]::Match($content, $taskPattern)

if (-not $taskMatch.Success) {
    Write-Warning "TaskId not found in backlog: $TaskId"
    exit 0
}

$searchStart = $taskMatch.Index + $taskMatch.Length
$remainingContent = $content.Substring($searchStart)
$nextTaskMatch = [regex]::Match($remainingContent, '(?m)^[ \t]*-[ \t]+id:[ \t]*')
$taskBlockLength = if ($nextTaskMatch.Success) { $nextTaskMatch.Index } else { $remainingContent.Length }
$taskBlock = $remainingContent.Substring(0, $taskBlockLength)

$statusPattern = '(?m)^(?<indent>[ \t]*)status:[ \t]*(?<value>[^#\r\n]*?)(?<suffix>[ \t]*(?:#.*)?)$'
$statusMatch = [regex]::Match($taskBlock, $statusPattern)

if (-not $statusMatch.Success) {
    Write-Warning "status line not found for task: $TaskId"
    exit 0
}

$newStatusLine = '{0}status: {1}{2}' -f $statusMatch.Groups['indent'].Value, $Status, $statusMatch.Groups['suffix'].Value
$updatedTaskBlock = [regex]::Replace($taskBlock, $statusPattern, [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)
    $newStatusLine
}, 1)

$updatedContent = $content.Substring(0, $searchStart) + $updatedTaskBlock + $remainingContent.Substring($taskBlockLength)
[System.IO.File]::WriteAllText($resolvedBacklogPath, $updatedContent, $utf8NoBom)

Write-Output ("Updated {0}: backlog → {1}" -f $TaskId, $Status)
