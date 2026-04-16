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
