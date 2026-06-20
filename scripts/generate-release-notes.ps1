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

function Get-LatestVersionTag {
    $allTags = @(git tag --sort=-v:refname)
    foreach ($tag in $allTags) {
        if ($tag -match '^v\d+\.\d+\.\d+$') {
            return $tag
        }
    }

    return $null
}

function Test-GitRefExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Ref
    )

    & git rev-parse --verify --quiet $Ref *> $null
    return ($LASTEXITCODE -eq 0)
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
        'Direct Operator.?Reviewer review flow|direct review flow' {
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
        'Monitoring stack non-functional|watchdog.?Operator delivery path missing' {
            return 'Restored watchdog-to-operator delivery for monitoring events'
        }
        'false success|pane creation does not actually occur|detached orchestra layout reliability' {
            return 'Reduced false-success paths where orchestra startup reported success without a real pane launch'
        }
        'Manifest convergence|split-brain schema|CLM-safe writes' {
            return 'Converged the manifest schema and unified CLM-safe write paths'
        }
        'Operator first-class defaults|default Operator pane|operators=1' {
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
        'Operator Telegram dense notifications' {
            return 'Reduced noisy operator notifications and improved visibility into approvals and state changes'
        }
        'pane\.completed|PostToolUse pane monitor hook' {
            return 'Surfaced pane completion events so the operator can make the next decision faster'
        }
        'desktop shutdown|child[- ]process cleanup|worker-pane child|PTY.*shutdown|shutdown.*PTY' {
            return 'Cleaned up worker-pane child processes when the desktop app exits'
        }
        'complete winsmux-surface rename|send buffer overflow' {
            return 'Continued the winsmux naming convergence and stabilized the send pipeline'
        }
        'migrate worker path to Antigravity CLI|Antigravity CLI' {
            return 'Migrated one-shot worker execution to the Antigravity CLI route while preserving explicit backend metadata'
        }
        'worker model picker benchmark surface|Worker-pane major model selection|Agent benchmark comparison surface|model picker' {
            return 'Added the worker-pane model picker and benchmark comparison surface without making reference-only models selectable'
        }
        'v0\.36\.15 bakeoff rubric and tracked task packet|bakeoff rubric|tracked task packet' {
            return 'Tracked the CLI bakeoff task pack with fixed scoring axes, shared packets, QC gates, and worker profiles'
        }
        'CLI bakeoff preflight and summary harness|bakeoff preflight|summary harness' {
            return 'Added preflight and summary scripts for Claude Code, Codex, and Antigravity CLI comparison evidence'
        }
        'Existing CLI bakeoff evidence classification|evidence classification' {
            return 'Classified existing local bakeoff evidence and withheld automatic assignment recommendations when publishable recordings were missing'
        }
        'Model-task fit and assignment policy outputs|assignment policy outputs|model-task fit' {
            return 'Generated model-task fit and assignment policy outputs that keep worker defaults unchanged without reviewer-approved evidence'
        }
        'v0\.36\.15 release catch-up gate|release catch-up' {
            return 'Brought the public release train forward from v0.36.10 to v0.36.15 with release-grade notes and version-surface checks'
        }
        'harden operator runtime controls|operator runtime controls' {
            return 'Hardened desktop operator runtime controls used by managed worker sessions'
        }
        'release note quality|release body quality|release notes quality' {
            return 'Kept GitHub Release publication behind concrete release-note quality gates'
        }
        'api llm openai-compatible runner|api_llm worker contract|api_llm backend contract' {
            return 'Added the api_llm hosted OpenAI-compatible worker backend and execution contract'
        }
        'External API secret and public-surface gate' {
            return 'Expanded public-surface checks so external API credentials and provider metadata stay out of release materials'
        }
        'External API worker E2E evidence and review gate' {
            return 'Captured hosted API worker E2E evidence and tied it to the release review path'
        }
        'Hosted open-model API E2E release lane' {
            return 'Made hosted open-model execution the v0.36.9 release lane instead of the deferred Colab local-model path'
        }
        'Persist winsmux planning source-of-truth paths locally' {
            return $null
        }
        'OpenRouter/OpenAI-compatible runner and auth contract' {
            return 'Added the OpenRouter runner contract with environment-variable credentials and OpenAI-compatible requests'
        }
        'skip unconfigured api_llm readiness|block api_llm start without bootstrap|defer api_llm pane launch' {
            return 'Stopped unconfigured api_llm workers before pane launch or network access'
        }
        'require explicit api_llm provider metadata|expose api_llm in machine contract|tighten api_llm exec contract' {
            return 'Required explicit provider, model, adapter, and execution metadata for api_llm workers'
        }
        'preserve colab task-json forwarding' {
            return 'Preserved existing Colab task-json forwarding while adding the hosted worker path'
        }
        'refresh public docs for v0\.36\.8' {
            return 'Refreshed public setup documentation for the hosted API worker release'
        }
        'guard parent tracking|guard mesh parent|parent_tracking|TASK-390' {
            return 'Added machine-readable guard mesh parent tracking for architecture, security, evidence, and release gating acceptance'
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

function Get-RepoReferenceSuffix {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $matches = [regex]::Matches($Text, '#\d+')
    if ($matches.Count -eq 0) {
        return ''
    }

    $refs = New-Object System.Collections.Generic.List[string]
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($match in $matches) {
        $token = [string]$match.Value
        if ($seen.Add($token)) {
            $refs.Add($token)
        }
    }

    if ($refs.Count -eq 0) {
        return ''
    }

    return ' (' + (($refs.ToArray()) -join ', ') + ')'
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

function Get-UniqueBenefitsWithRefs {
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

        if (-not $seen.Add($normalized)) {
            continue
        }

        $suffix = Get-RepoReferenceSuffix -Text $value
        $display = if ([string]::IsNullOrWhiteSpace($suffix)) { $normalized } else { $normalized + $suffix }
        $results.Add($display)

        if ($results.Count -ge $Limit) {
            break
        }
    }

    return @($results.ToArray())
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

    [void]$Builder.AppendLine("## $Title")
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
$doneTaskTitlesForVersion = @(
    $doneTasksForVersion |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Title) } |
        Select-Object -ExpandProperty Title
)

$versionRefExists = Test-GitRefExists -Ref $Version
$previousTag = if ($versionRefExists) { Get-PreviousTag -CurrentTag $Version } else { Get-LatestVersionTag }
$commitRange = if ($versionRefExists -and $null -ne $previousTag) {
    "$previousTag..$Version"
} elseif ($versionRefExists) {
    $Version
} elseif ($null -ne $previousTag) {
    "$previousTag..HEAD"
} else {
    'HEAD'
}
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
$featureSource += @($doneTaskTitlesForVersion | Where-Object { $_ -notmatch '#\d+' })
$featureSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('Direct Operator.?Reviewer review flow')
$featureSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('runtime state machine', 'closed-loop orchestra startup')
$featureSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('bootstrap verification', 'bootstrap invariants')
$featureSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('Operator first-class defaults', 'defaults alignment')
$featureSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('first-class task and review state model', 'first-class pane state model')
$featureSource += @($commitSubjects | Where-Object { $_ -match '^feat' })
$fixSource = @()
$fixSource += @($doneTaskTitlesForVersion | Where-Object { $_ -match '#\d+' })
$fixSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('winsmux send silent failure', 'target pane.*not found', 'fail when target pane is missing')
$fixSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('Monitoring stack non-functional', 'watchdog.?Operator delivery path missing')
$fixSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('false success', 'pane creation does not actually occur', 'detached orchestra layout reliability')
$fixSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('Manifest convergence', 'CLM-safe writes')
$fixSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('native-exit handling', 'fixture temp dirs out of repo root', 'review-gate CI')
$fixSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('release note quality', 'release body quality', 'release notes quality')
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
                'Direct Operator.?Reviewer review flow',
                'first-class task and review state model',
                'first-class pane state model',
                'Operator first-class defaults',
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
$docsSource = @(
    $commitSubjects |
        Where-Object {
            $_ -match '^docs' -and
            -not (Test-MatchesAny -Text $_ -Patterns @('bump version', 'sync backlog and roadmap'))
        }
)
$choreSource = @()
$choreSource += Get-MatchedCommits -Subjects $commitSubjects -Patterns @('Operator Telegram dense notifications', 'pane\.completed', 'winsmux-surface rename')
$choreSource += @(
    $commitSubjects |
        Where-Object {
            $_ -match '^(chore|ci|test)' -and
            -not (Test-MatchesAny -Text $_ -Patterns @('bump version', 'sync backlog and roadmap'))
        }
)

$highlights = @(Get-UniqueBenefitsWithRefs -Values $highlightCandidates -Limit 3)
$features = @(Get-UniqueBenefitsWithRefs -Values $featureSource -Limit 5)
$features = @($highlights + (Remove-ExistingBenefits -Items $features -Existing $highlights))
$features = @($features | Select-Object -First 6)
$fixes = @(Get-UniqueBenefitsWithRefs -Values $fixSource -Limit 5)
$security = @(Get-UniqueBenefitsWithRefs -Values $securitySource -Limit 2)
$documentation = @(Get-UniqueBenefitsWithRefs -Values $docsSource -Limit 4)
$chores = @(Get-UniqueBenefitsWithRefs -Values $choreSource -Limit 6)
$chores = @($security + (Remove-ExistingBenefits -Items $chores -Existing $security))
$chores = @($chores | Select-Object -First 4)

$builder = New-Object System.Text.StringBuilder
$seenBenefits = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

$highlightItems = @($features + $fixes + $documentation | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 6)
if ($highlightItems.Count -eq 0) {
    $highlightItems = @('Prepared the release from the recorded task and commit history')
}
if ($highlightItems.Count -lt 3) {
    foreach ($fallbackHighlight in @(
        'Release scope is derived from the public version-tag commit range when private planning metadata is not available in CI',
        'Release publication remains blocked by release-note quality checks and public-surface audit checks',
        'Secret-like values, local private paths, and provider request metadata stay out of generated release materials'
    )) {
        if ($highlightItems -notcontains $fallbackHighlight) {
            $highlightItems += $fallbackHighlight
        }

        if ($highlightItems.Count -ge 3) {
            break
        }
    }
}
Add-Section -Builder $builder -Title 'Highlights' -Items $highlightItems -Seen $seenBenefits

$changeItems = @($features + $fixes + $documentation + $chores | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$changeItems = @(Remove-ExistingBenefits -Items $changeItems -Existing $highlightItems | Select-Object -First 8)
if ($changeItems.Count -eq 0) {
    $changeItems = @(
        'Release scope is derived from the version tag commit range and filtered to public-facing changes',
        'Version bump, roadmap sync, and planning-only commits are excluded from public highlights',
        'The generated body remains usable when private planning metadata is not available in CI'
    )
}
Add-Section -Builder $builder -Title 'Release scope' -Items $changeItems -Seen $null

$safetyItems = New-Object System.Collections.Generic.List[string]
foreach ($item in @($security + $chores)) {
    if (-not [string]::IsNullOrWhiteSpace($item)) {
        $safetyItems.Add($item)
    }
}
$safetyItems.Add('Release notes are checked by the public-surface audit before GitHub Release publication')
$safetyItems.Add('Secret-like values, local private paths, and provider request metadata remain blocked from release materials')
$safetyItems.Add('A failed release-note quality check stops the release workflow before GitHub Release publication')
Add-Section -Builder $builder -Title 'Safety and operations' -Items @($safetyItems.ToArray()) -Seen $null

$distributionItems = @(
    'Release workflow downloads the completed Windows x64 and arm64 core binary artifacts before assembling assets',
    'Core binaries are published as `winsmux-x64.exe` and `winsmux-arm64.exe`',
    'Release assets include `SHA256SUMS` generated from the core executables',
    'GitHub Release publication consumes the checked `release/release-body.md` and `release/*` asset set only after quality and public-surface gates pass'
)
Add-Section -Builder $builder -Title 'Distribution' -Items $distributionItems -Seen $null

$validationItems = @(
    'Release workflow builds the Windows x64 core binary before release assets are assembled',
    'Release workflow builds the Windows arm64 core binary before release assets are assembled',
    'Generated release notes must pass `scripts/assert-release-notes-quality.ps1` before publication',
    'Generated release notes must pass `scripts/audit-public-surface.ps1` before publication',
    'The release job depends on successful build jobs before release assets can be uploaded'
)
Add-Section -Builder $builder -Title 'Validation' -Items $validationItems -Seen $null

[void]$builder.AppendLine('## Full Changelog')
[void]$builder.AppendLine()
if ($null -ne $previousTag) {
    [void]$builder.AppendLine("- [$previousTag...$Version](https://github.com/Sora-bluesky/winsmux/compare/$previousTag...$Version)")
} else {
    [void]$builder.AppendLine("- [$Version](https://github.com/Sora-bluesky/winsmux/releases/tag/$Version)")
}

$builder.ToString() | Set-Content -Path $outputFullPath -Encoding UTF8
Write-Host "[release-notes] wrote $outputFullPath"
