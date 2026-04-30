[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'audit-public-surface: failed to determine repository root.'
}

Set-Location -LiteralPath $repoRoot

function Get-TrackedFiles {
    $files = @(
        & git ls-files -- 2>$null |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($LASTEXITCODE -ne 0) {
        throw 'audit-public-surface: failed to list tracked files.'
    }

    return $files
}

function Test-IsPublicDoc {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('\', '/')
    return $normalized -in @(
        'README.md',
        'README.ja.md',
        'THIRD_PARTY_NOTICES.md',
        'docs/README.md',
        'docs/README.ja.md',
        'docs/operator-model.md',
        'docs/quickstart.md',
        'docs/quickstart.ja.md',
        'docs/installation.md',
        'docs/installation.ja.md',
        'docs/customization.md',
        'docs/customization.ja.md',
        'docs/TROUBLESHOOTING.md',
        'docs/TROUBLESHOOTING.ja.md',
        'packages/winsmux/README.md'
    )
}

function Test-IsTrackedTextSurface {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('\', '/')
    if ($normalized -match '^\.claude/logs/') { return $false }
    if ($normalized -match '^docs/internal/') { return $false }
    return $normalized -match '(^README(\.ja)?\.md$)|(^AGENTS?(-BASE)?\.md$)|(^GEMINI\.md$)|(^docs/.+\.md$)|(^\.claude/CLAUDE\.md$)|(^\.agents/.+\.md$)|(^tests/.+\.(ps1|md|json|txt)$)|(^\.github/workflows/.+\.ya?ml$)|(^\.githooks/.+$)|(^scripts/.+\.ps1$)'
}

function Test-IsMaintainerPathScanSurface {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('\', '/')
    if ($normalized -match '^tests/') { return $false }
    if ($normalized -match '^scripts/') { return $false }
    if ($normalized -match '^\.githooks/') { return $false }
    if ($normalized -match '^\.github/workflows/') { return $false }
    if ($normalized -eq 'docs/repo-surface-policy.md') { return $false }
    return Test-IsTrackedTextSurface -Path $Path
}

function Test-IsMaintainerIdentityScanSurface {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('\', '/')
    if ($normalized -in @(
        'docs/repo-surface-policy.md',
        'scripts/audit-public-surface.ps1',
        'scripts/git-guard.ps1'
    )) {
        return $false
    }
    return Test-IsTrackedTextSurface -Path $Path
}

$failures = New-Object System.Collections.Generic.List[string]

$trackedIgnored = @(
    & git ls-files -ci --exclude-standard 2>$null |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($LASTEXITCODE -ne 0) {
    throw 'audit-public-surface: failed to evaluate tracked/ignore overlap.'
}
if ($trackedIgnored.Count -gt 0) {
    $failures.Add("tracked files also matched .gitignore: $($trackedIgnored -join ', ')")
}

$trackedFiles = Get-TrackedFiles

$forbiddenTracked = @(
    'HANDOFF.md',
    'docs/HANDOFF.md',
    'docs/handoff.md',
    'testResults.xml',
    'tasks/roadmap-title-ja.psd1'
)
foreach ($path in $forbiddenTracked) {
    if ($trackedFiles -contains $path) {
        $failures.Add("tracked live-ops file must not be committed: $path")
    }
}

$forbiddenTrackedPrefixes = @(
    '.playwright-mcp/'
)
foreach ($file in $trackedFiles) {
    $normalized = $file.Replace('\', '/')
    foreach ($prefix in $forbiddenTrackedPrefixes) {
        if ($normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $failures.Add("tracked generated/runtime artifact must not be committed: $file")
        }
    }

    if ($normalized -match '[\uE000-\uF8FF]') {
        $failures.Add("tracked path contains a private-use Unicode character and must be renamed or removed: $file")
    }
}

$trackedPrivateSkillFiles = @(
    $trackedFiles |
        Where-Object { $_.Replace('\', '/') -match '^\.agents/skills/' }
)
if ($trackedPrivateSkillFiles.Count -gt 0) {
    $failures.Add("private maintainer skill pack must not be tracked in the public repo: $($trackedPrivateSkillFiles -join ', ')")
}

$personalPathPatterns = @(
    'C:\\Users\\',
    'iCloudDrive',
    'MainVault'
)
foreach ($file in ($trackedFiles | Where-Object { Test-IsMaintainerPathScanSurface -Path $_ })) {
    $content = Get-Content -LiteralPath $file -Raw -ErrorAction Stop
    foreach ($pattern in $personalPathPatterns) {
        if ($content -match [Regex]::Escape($pattern)) {
            $failures.Add("tracked text surface contains maintainer-local path pattern '$pattern': $file")
        }
    }
}

$personalIdentityPatterns = @(
    ('C:\Users\' + 'komei'),
    'iCloudDrive',
    'MainVault'
)
foreach ($file in ($trackedFiles | Where-Object { Test-IsMaintainerIdentityScanSurface -Path $_ })) {
    $content = Get-Content -LiteralPath $file -Raw -ErrorAction Stop
    foreach ($pattern in $personalIdentityPatterns) {
        if ($content -match [Regex]::Escape($pattern)) {
            $failures.Add("tracked text surface contains maintainer-local identity pattern '$pattern': $file")
        }
    }
}

$forbiddenPublicRefs = @(
    '.claude/CLAUDE.md',
    'AGENT.md',
    'GEMINI.md',
    'docs/internal/',
    'docs/handoff.md',
    'tasks/roadmap-title-ja.psd1',
    '.agents/skills/'
)
$forbiddenPublicProductFragments = @(
    '/winsmux-start',
    'test this repository itself',
    '動作確認専用',
    'dogfooding',
    'Repository-operated',
    'contributor/runtime'
)
foreach ($file in ($trackedFiles | Where-Object { Test-IsPublicDoc -Path $_ })) {
    $content = Get-Content -LiteralPath $file -Raw -ErrorAction Stop
    foreach ($reference in $forbiddenPublicRefs) {
        if ($content -match [Regex]::Escape($reference)) {
            $failures.Add("public doc directly references private/contributor surface '$reference': $file")
        }
    }
    foreach ($fragment in $forbiddenPublicProductFragments) {
        if ($content -match [Regex]::Escape($fragment)) {
            $failures.Add("public doc exposes repository-only startup wording '$fragment': $file")
        }
    }
}

$claudeContractPath = Join-Path $repoRoot '.claude/CLAUDE.md'
if (Test-Path -LiteralPath $claudeContractPath) {
    $claudeContract = Get-Content -LiteralPath $claudeContractPath -Raw -ErrorAction Stop
    $legacyProbeLines = @(
        ($claudeContract -split "`r?`n") |
            Where-Object { $_ -match 'psmux --version|Get-Process psmux-server' }
    )
    $nonNegatedLegacyProbeLines = @(
        $legacyProbeLines |
            Where-Object { $_ -notmatch 'Do not|禁止|使わない|use only the structured smoke states' }
    )
    if ($nonNegatedLegacyProbeLines.Count -gt 0) {
        $failures.Add('.claude/CLAUDE.md still contains legacy startup probe guidance outside explicit prohibition.')
    }
    if ($claudeContract -notmatch 'winsmux orchestra-smoke --json') {
        $failures.Add('.claude/CLAUDE.md must reference winsmux orchestra-smoke --json as startup source of truth.')
    }
    if ($claudeContract -notmatch 'operator_contract') {
        $failures.Add('.claude/CLAUDE.md must reference operator_contract as startup source of truth.')
    }
}

$hooksPath = (& git config --get core.hooksPath 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($hooksPath)) {
    $failures.Add('core.hooksPath is not configured. Run scripts/bootstrap-git-guard.ps1.')
} else {
    $normalizedHooksPath = $hooksPath.Replace('\', '/')
    if ($normalizedHooksPath -notmatch '(^|/)\.githooks$') {
        $failures.Add("core.hooksPath must point to .githooks, found '$hooksPath'.")
    }
}

if ($failures.Count -gt 0) {
    Write-Error ("audit-public-surface blocked:`n- " + ($failures -join "`n- "))
    exit 1
}

Write-Output 'audit-public-surface passed'
