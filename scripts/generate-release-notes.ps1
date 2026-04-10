[CmdletBinding()]
param(
    [string]$Version,
    [string]$BacklogPath = '',
    [string]$OutputPath = 'release/release-body.md'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot '..') 'winsmux-core\scripts\planning-paths.ps1')

function Resolve-RepoPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $script:RepoRoot $Path
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
        id             = $Matches['id']
        title          = ''
        status         = ''
        priority       = ''
        target_version = ''
    }

    for ($index = 1; $index -lt $Lines.Count; $index++) {
        $line = $Lines[$index]
        if ($line -match '^[ \t]{4}(?<key>[a-z_]+):[ \t]*(?<value>.*)$') {
            $key = $Matches['key']
            $value = $Matches['value']

            if ($key -in @('files', 'paths', 'artifacts', 'changed_files')) {
                $values[$key] = ConvertFrom-YamlInlineList -Value $value
                continue
            }

            if ($value -in @('>', '|')) {
                continue
            }

            $values[$key] = ConvertFrom-YamlScalar -Value $value
        }
    }

    return [pscustomobject]@{
        Id            = $values['id']
        Title         = $values['title']
        Status        = $values['status']
        Priority      = $values['priority']
        TargetVersion = $values['target_version']
    }
}

function Get-PreviousTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentTag
    )

    $allTags = @(git tag --sort=-v:refname)
    for ($index = 0; $index -lt $allTags.Count; $index++) {
        if ($allTags[$index] -eq $CurrentTag) {
            if ($index + 1 -lt $allTags.Count) {
                return $allTags[$index + 1]
            }

            return $null
        }
    }

    return $null
}

function Test-MatchesAny {
    param(
        [AllowNull()]
        [string]$Text,
        [string[]]$Patterns
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    foreach ($pattern in $Patterns) {
        if ($Text -match $pattern) {
            return $true
        }
    }

    return $false
}

function ConvertTo-UserBenefit {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    switch -Regex ($Text) {
        'gate enforcement tests|test: move fixture temp dirs out of repo root|fix\(tests\): harden PowerShell native-exit handling' {
            return 'Improved CI and test stability while preventing temporary test artifacts from polluting the repo root'
        }
        'runtime state machine|closed-loop dispatch/review/commit|closed-loop orchestra startup' {
            return 'Established the closed-loop runtime required for dispatch -> review -> commit orchestration'
        }
        'Direct Commander.?Reviewer review flow|direct review flow' {
            return 'Added a direct review handoff from the operator to the reviewer path'
        }
        'bootstrap invariants|bootstrap verification|cwd|WINSMUX_ROLE|pane_id mismatch|stale manifest invalidation' {
            return 'Validate pane cwd / role / pane_id at startup and fail closed when bootstrap state drifts'
        }
        'Builder isolation|outside worktree|delegated write bypass|write-capable' {
            return 'Blocked direct write bypass and out-of-worktree writes from managed builder flows'
        }
        'first-class task and review state model|first-class pane state model|changed-files' {
            return 'Promoted task, review, branch, and changed-files metadata to first-class runtime state'
        }
        'winsmux send silent failure|target pane.*not found|focus_pane_by_id|fail when target pane is missing' {
            return 'Stop silent success when a target pane does not exist and fail explicitly instead'
        }
        'Monitoring stack non-functional|watchdog.?Commander delivery path missing' {
            return 'Restored watchdog-to-operator delivery for monitoring events'
        }
        'false success|pane creation does not actually occur|detached orchestra layout reliability' {
            return 'Reduced false-success paths where orchestra startup reported success without a real pane launch'
        }
        'Manifest convergence|split-brain schema|CLM-safe writes' {
            return 'Converged the manifest schema and unified CLM-safe write paths'
        }
        'Commander first-class defaults|default Commander pane|commanders=1' {
            return 'Clarified the default operator pane assumptions and minimum startup layout'
        }
        'defaults alignment and pane status in manifest' {
            return 'Aligned default operator state and pane status initialization in the manifest'
        }
        'Reviewer-only|review-approve' {
            return 'Restricted review-approve to the reviewer path to close accidental approval routes'
        }
        'review-fail command|blocked_no_reviewer|review-fail' {
            return 'Made review-failure and no-reviewer stop conditions explicit'
        }
        'Guard settings\.local\.json|hook disable' {
            return 'Made dangerous hook-disable changes harder to land without an explicit approval path'
        }
        'Commander Telegram dense notifications' {
            return 'Reduced noisy operator notifications and improved visibility into approvals and state changes'
        }
        'pane\.completed|PostToolUse pane monitor hook' {
            return 'Surfaced pane completion events so the operator can make the next decision faster'
        }
        'complete psmux.?winsmux rename|send buffer overflow' {
            return 'Continued the winsmux naming convergence and stabilized the send pipeline'
        }
        'bump version|sync backlog and roadmap' {
            return $null
        }
        default {
            $cleaned = ($Text -replace '^\w+(?:\([\w-]+\))?:\s*', '').Trim()
            $cleaned = $cleaned -replace '\s*\(#\d+.*$', ''
            $cleaned = $cleaned -replace '\s*\(TASK-[^)]+\)', ''
            if ($cleaned -match 'tests?|manifest|roadmap|backlog') {
                return $null
            }
            return $cleaned
        }
    }
}

function Get-UniqueBenefits {
    param(
        [string[]]$Values,
        [int]$Limit = 5
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $results = New-Object System.Collections.Generic.List[string]

    foreach ($value in $Values) {
        $normalized = ConvertTo-UserBenefit -Text $value
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }

        if ($seen.Add($normalized)) {
            $results.Add($normalized)
        }

        if ($results.Count -ge $Limit) {
            break
        }
    }

    return @($results.ToArray())
}

function Get-MatchedCommits {
    param(
        [string[]]$Subjects,
        [string[]]$Patterns
    )

    return @($Subjects | Where-Object { Test-MatchesAny -Text $_ -Patterns $Patterns })
}

function Remove-ExistingBenefits {
    param(
        [string[]]$Items,
        [string[]]$Existing
    )

    if ($Items.Count -eq 0 -or $Existing.Count -eq 0) {
        return $Items
    }

    $existingSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $Existing) {
        [void]$existingSet.Add($item)
    }

    return @($Items | Where-Object { -not $existingSet.Contains($_) })
}

function Add-Section {
    param(
        [System.Text.StringBuilder]$Builder,
        [string]$Title,
        [string[]]$Items,
        [System.Collections.Generic.HashSet[string]]$Seen
    )

    $uniqueItems = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Items) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }

        if ($null -eq $Seen -or $Seen.Add($item)) {
            $uniqueItems.Add($item)
        }
    }

    if ($uniqueItems.Count -eq 0) {
        return
    }

    [void]$Builder.AppendLine("### $Title")
    [void]$Builder.AppendLine()
    foreach ($item in $uniqueItems) {
        [void]$Builder.AppendLine("- $item")
    }
    [void]$Builder.AppendLine()
}

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if ([string]::IsNullOrWhiteSpace($BacklogPath)) {
    $BacklogPath = Resolve-WinsmuxPlanningFilePath -RepoRoot $script:RepoRoot -LocalRelativePath 'tasks/backlog.yaml' -EnvironmentVariable 'WINSMUX_BACKLOG_PATH' -DefaultFileName 'backlog.yaml'
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $rawVersion = (Get-Content -Path (Join-Path $script:RepoRoot 'VERSION') -Raw -Encoding UTF8).Trim()
    $Version = if ($rawVersion.StartsWith('v')) { $rawVersion } else { "v$rawVersion" }
}

if (-not $Version.StartsWith('v')) {
    $Version = "v$Version"
}

$backlogFullPath = Resolve-RepoPath -Path $BacklogPath
$outputFullPath = Resolve-RepoPath -Path $OutputPath
$outputDirectory = Split-Path -Parent $outputFullPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}

$tasks = @()
if (Test-Path $backlogFullPath) {
    try {
        $backlogContent = Get-Content -Path $backlogFullPath -Raw -Encoding UTF8
        $taskBlocks = @(Get-TaskBlocks -Content $backlogContent)
        $tasks = @(
            foreach ($taskBlock in $taskBlocks) {
                if ($null -eq $taskBlock -or -not $taskBlock.PSObject.Properties.Match('Lines')) {
                    continue
                }

                $task = ConvertFrom-TaskBlock -Lines @($taskBlock.Lines)
                if ($null -ne $task) {
                    $task
                }
            }
        )
    } catch {
        Write-Warning "[release-notes] backlog parse failed: $($_.Exception.Message)"
    }
} else {
    Write-Warning "[release-notes] backlog not found at $backlogFullPath; generating from git history only."
}
$doneTasksForVersion = @($tasks | Where-Object { $_.TargetVersion -eq $Version -and $_.Status -eq 'done' })

$previousTag = Get-PreviousTag -CurrentTag $Version
$commitRange = if ($null -ne $previousTag) { "$previousTag..$Version" } else { $Version }
$commitSubjects = @(git log $commitRange --pretty=format:%s --no-merges)

$securityPatterns = @('gate', 'guard', 'security', 'bypass', 'review-approve', 'reviewer', 'write', 'block', 'deny', 'isolation', 'approval', 'hook disable')
$fixPatterns = @('fix', 'failure', 'crash', 'false success', 'silent', 'invalid', 'mismatch', 'stale', 'not found', 'rename', 'harden', 'verification')

$highlightCandidates = @()
if ($commitSubjects | Where-Object { $_ -match 'runtime state machine|closed-loop dispatch/review/commit|closed-loop orchestra startup' } | Select-Object -First 1) {
    $highlightCandidates += 'runtime state machine'
}
if ($commitSubjects | Where-Object { $_ -match 'bootstrap invariants|bootstrap verification|cwd|WINSMUX_ROLE|pane_id mismatch|stale manifest invalidation' } | Select-Object -First 1) {
    $highlightCandidates += 'bootstrap verification'
}
if ($commitSubjects | Where-Object { $_ -match 'Builder isolation|outside worktree|delegated write bypass|write-capable' } | Select-Object -First 1) {
    $highlightCandidates += 'Builder isolation'
}
if ($commitSubjects | Where-Object { $_ -match 'first-class task and review state model|first-class pane state model|changed-files' } | Select-Object -First 1) {
    $highlightCandidates += 'first-class pane state model'
}
if ($commitSubjects | Where-Object { $_ -match 'winsmux send silent failure|target pane.*not found|focus_pane_by_id' } | Select-Object -First 1) {
    $highlightCandidates += 'winsmux send silent failure'
}

if ($highlightCandidates.Count -eq 0) {
    $highlightCandidates = @($doneTasksForVersion | Sort-Object Priority, Title | Select-Object -ExpandProperty Title)
}

$featureSource = @()
$featureSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('Direct Commander.?Reviewer review flow')
$featureSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('runtime state machine', 'closed-loop orchestra startup')
$featureSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('bootstrap verification', 'bootstrap invariants')
$featureSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('Commander first-class defaults', 'defaults alignment')
$featureSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('first-class task and review state model', 'first-class pane state model')
$featureSource += @($commitSubjects | Where-Object { $_ -match '^feat' })
$fixSource = @()
$fixSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('winsmux send silent failure', 'target pane.*not found', 'fail when target pane is missing')
$fixSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('Monitoring stack non-functional', 'watchdog.?Commander delivery path missing')
$fixSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('false success', 'pane creation does not actually occur', 'detached orchestra layout reliability')
$fixSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('Manifest convergence', 'CLM-safe writes')
$fixSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('native-exit handling', 'fixture temp dirs out of repo root', 'review-gate CI')
$fixSource += @(
    $commitSubjects |
        Where-Object {
            (($_ -match '^fix') -or (Test-MatchesAny -Text $_ -Patterns $fixPatterns)) -and
            -not (Test-MatchesAny -Text $_ -Patterns @(
                'Builder isolation',
                'delegated write bypass',
                'Reviewer-only',
                'review-approve',
                'bootstrap verification',
                'bootstrap invariants',
                'Direct Commander.?Reviewer review flow',
                'first-class task and review state model',
                'first-class pane state model',
                'Commander first-class defaults',
                'defaults alignment'
            ))
        }
)
$securitySource = @()
$securitySource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('Builder isolation')
$securitySource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('delegated write bypass', 'write-capable')
$securitySource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('Reviewer-only', 'review-approve')
$securitySource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('Guard settings\.local\.json', 'hook disable')
$securitySource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('review-fail command', 'blocked_no_reviewer', 'review-fail')
$otherSource = @()
$otherSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('Commander Telegram dense notifications', 'pane\.completed', 'psmux.?winsmux rename')
$otherSource += @(
    $commitSubjects |
        Where-Object {
            $_ -match '^(chore|docs|test|ci)' -and
            -not (Test-MatchesAny -Text $_ -Patterns @('bump version', 'sync backlog and roadmap'))
        }
)

$highlights = Get-UniqueBenefits -Values $highlightCandidates -Limit 3
$features = Get-UniqueBenefits -Values $featureSource -Limit 5
$fixes = Get-UniqueBenefits -Values $fixSource -Limit 5
$security = Get-UniqueBenefits -Values $securitySource -Limit 2
$other = Get-UniqueBenefits -Values $otherSource -Limit 3

$builder = New-Object System.Text.StringBuilder
[void]$builder.AppendLine("## winsmux $Version")
[void]$builder.AppendLine()
$seenBenefits = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
Add-Section -Builder $builder -Title 'Highlights' -Items $highlights -Seen $seenBenefits
Add-Section -Builder $builder -Title 'Features' -Items $features -Seen $seenBenefits
Add-Section -Builder $builder -Title 'Fixes' -Items $fixes -Seen $seenBenefits
Add-Section -Builder $builder -Title 'Security / Guardrails' -Items $security -Seen $seenBenefits
Add-Section -Builder $builder -Title 'Other' -Items $other -Seen $seenBenefits

[void]$builder.AppendLine('### Change Scope')
[void]$builder.AppendLine()
[void]$builder.AppendLine("- Commit range: ``$commitRange``")
if ($doneTasksForVersion.Count -gt 0) {
    [void]$builder.AppendLine("- Completed backlog tasks for this version: $($doneTasksForVersion.Count)")
}
[void]$builder.AppendLine("- Published assets: ``winsmux-x64.exe``, ``winsmux-arm64.exe``, ``SHA256SUMS``")
[void]$builder.AppendLine()
[void]$builder.AppendLine('### Full Changelog')
[void]$builder.AppendLine()
if ($null -ne $previousTag) {
    [void]$builder.AppendLine("- https://github.com/Sora-bluesky/winsmux/compare/$previousTag...$Version")
} else {
    [void]$builder.AppendLine("- https://github.com/Sora-bluesky/winsmux/releases/tag/$Version")
}

$builder.ToString() | Set-Content -Path $outputFullPath -Encoding UTF8
Write-Host "[release-notes] wrote $outputFullPath"
