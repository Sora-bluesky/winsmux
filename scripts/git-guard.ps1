[CmdletBinding()]
param(
    [ValidateSet('staged', 'full')]
    [string]$Mode = 'full'
)

$ErrorActionPreference = 'Stop'

function Get-TrackedOrStagedFiles {
    param([Parameter(Mandatory = $true)][string]$SelectedMode)

    if ($SelectedMode -eq 'staged') {
        $output = git diff --cached --name-only --diff-filter=ACMR
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to list staged files for git-guard.'
        }
        return @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $output = git ls-files
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to list tracked files for git-guard.'
    }

    return @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-PathLikeSecretPattern {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path -replace '\\', '/'
    $leaf = [System.IO.Path]::GetFileName($normalized)

    $blockedNames = @(
        '.env',
        'credentials.json',
        'secrets.json',
        'token.json'
    )

    if ($blockedNames -contains $leaf) {
        return $true
    }

    $blockedRegexes = @(
        '(^|/)\.env(\.|$)',
        '\.pem$',
        '\.p12$',
        '\.pfx$',
        '\.key$',
        '\.secret$',
        '(^|/)tokens(/|$)',
        '(^|/)\.winsmux(/|$)',
        '(^|/)\.orchestra-prompts(/|$)',
        '(^|/)docs/handoff\.md$',
        '(^|/)tasks/roadmap-title-ja\.psd1$',
        '(^|/)\.claude/local(/|$)',
        '(^|/)\.agents/skills(/|$)'
    )

    foreach ($pattern in $blockedRegexes) {
        if ($normalized -match $pattern) {
            return $true
        }
    }

    return $false
}

function Test-ContentLeak {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    if ($Path -eq 'docs/repo-surface-policy.md') {
        return $null
    }

    $docCandidate = $Path -match '(^|/)(README(\.ja)?\.md|AGENTS\.md|AGENT(-BASE)?\.md|GEMINI\.md|GUARDRAILS\.md|docs/.*\.md|\.claude/CLAUDE\.md|\.agents/.*\.md)$'
    if (-not $docCandidate) {
        return $null
    }

    $patterns = @(
        'C:\\Users\\',
        'iCloudDrive',
        'MainVault'
    )

    foreach ($pattern in $patterns) {
        if ($Content -match [regex]::Escape($pattern)) {
            return "maintainer-local path leak ($pattern)"
        }
    }

    return $null
}

function Test-EvidenceAuthLeak {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $normalized = $Path -replace '\\', '/'
    if ($normalized -notmatch '(?i)(^|/|[-_])evidence([-_/]|$)') {
        return $null
    }

    $patterns = @(
        [pscustomobject]@{ Name = 'OpenRouter API key'; Pattern = ('sk-or-' + 'v1-[A-Za-z0-9_-]{16,}') },
        [pscustomobject]@{ Name = 'GitHub token'; Pattern = '\bgh[pousr]_[A-Za-z0-9_]{20,}\b' },
        [pscustomobject]@{ Name = 'Bearer token'; Pattern = '(?i)\bAuthorization\s*:\s*Bearer\s+[A-Za-z0-9._~+/=-]{20,}' },
        [pscustomobject]@{ Name = 'API key assignment'; Pattern = '(?i)\b(?:openrouter|openai|anthropic|gemini|github|gh)[-_ ]?(?:api[-_ ]?)?key\s*[:=]\s*[''"]?[A-Za-z0-9._~+/=-]{12,}' },
        [pscustomobject]@{ Name = 'secret assignment'; Pattern = '(?i)\b(?:token|secret|credential|oauth)[-_ ]?(?:value|token|secret|key)?\s*[:=]\s*[''"]?[A-Za-z0-9._~+/=-]{20,}' }
    )

    foreach ($pattern in $patterns) {
        if ($Content -match $pattern.Pattern) {
            return "evidence/auth secret leak ($($pattern.Name))"
        }
    }

    return $null
}

function Test-ExternalRoadmapFreshness {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $planningPaths = Join-Path $RepoRoot 'winsmux-core\scripts\planning-paths.ps1'
    if (-not (Test-Path -LiteralPath $planningPaths -PathType Leaf)) {
        return $null
    }

    try {
        . $planningPaths
        $backlogPath = Resolve-WinsmuxPlanningFilePath -RepoRoot $RepoRoot -LocalRelativePath 'tasks/backlog.yaml' -EnvironmentVariable 'WINSMUX_BACKLOG_PATH' -DefaultFileName 'backlog.yaml'
        $roadmapPath = Resolve-WinsmuxPlanningFilePath -RepoRoot $RepoRoot -LocalRelativePath 'docs/project/ROADMAP.md' -EnvironmentVariable 'WINSMUX_ROADMAP_PATH' -DefaultFileName 'ROADMAP.md'

        $hasBacklog = Test-Path -LiteralPath $backlogPath -PathType Leaf
        $hasRoadmap = Test-Path -LiteralPath $roadmapPath -PathType Leaf

        if (-not $hasBacklog -and -not $hasRoadmap) {
            return $null
        }

        if ($hasBacklog -and -not $hasRoadmap) {
            return 'external ROADMAP is missing while backlog.yaml exists; run winsmux-core/scripts/sync-roadmap.ps1'
        }

        if (-not $hasBacklog) {
            return $null
        }

        $backlogItem = Get-Item -LiteralPath $backlogPath
        $roadmapItem = Get-Item -LiteralPath $roadmapPath
        if ($roadmapItem.LastWriteTimeUtc -lt $backlogItem.LastWriteTimeUtc.AddSeconds(-2)) {
            return 'external ROADMAP is older than backlog.yaml; run winsmux-core/scripts/sync-roadmap.ps1'
        }
    } catch {
        return 'external planning sync check failed; verify planning paths and run winsmux-core/scripts/sync-roadmap.ps1'
    }

    return $null
}

function Test-ExcessTrailingBlankLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $criticalPaths = @(
        '.claude/hooks/lib/sh-utils.js',
        '.claude/settings.json'
    )

    if ($criticalPaths -notcontains $Path) {
        return $null
    }

    if ($Content -match '(?:\r?\n){2,}$') {
        return 'extra trailing blank lines'
    }

    return $null
}

$repoRoot = (Resolve-Path '.').Path
$files = Get-TrackedOrStagedFiles -SelectedMode $Mode
$failures = [System.Collections.Generic.List[string]]::new()

$roadmapFreshnessFailure = Test-ExternalRoadmapFreshness -RepoRoot $repoRoot
if ($roadmapFreshnessFailure) {
    $failures.Add($roadmapFreshnessFailure) | Out-Null
}

foreach ($file in $files) {
    $normalized = $file -replace '\\', '/'
    if (Test-PathLikeSecretPattern -Path $normalized) {
        $failures.Add("blocked path: $normalized") | Out-Null
        continue
    }

    $absolutePath = Join-Path $repoRoot $file
    if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
        continue
    }

    $extension = [System.IO.Path]::GetExtension($absolutePath)
    if ($extension -in @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.icns', '.zip', '.exe', '.dll')) {
        continue
    }

    $content = Get-Content -LiteralPath $absolutePath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) {
        continue
    }

    $contentFailure = Test-ContentLeak -Path $normalized -Content $content
    if ($contentFailure) {
        $failures.Add("${contentFailure}: $normalized") | Out-Null
    }

    $evidenceAuthFailure = Test-EvidenceAuthLeak -Path $normalized -Content $content
    if ($evidenceAuthFailure) {
        $failures.Add("${evidenceAuthFailure}: $normalized") | Out-Null
    }

    $trailingBlankLineFailure = Test-ExcessTrailingBlankLines -Path $normalized -Content $content
    if ($trailingBlankLineFailure) {
        $failures.Add("${trailingBlankLineFailure}: $normalized") | Out-Null
    }
}

if ($failures.Count -gt 0) {
    Write-Error ("git-guard blocked:`n- " + ($failures -join "`n- "))
    exit 1
}

Write-Output "git-guard passed ($Mode)"
