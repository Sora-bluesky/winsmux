$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    Write-Error 'pre-commit-whitelist: failed to determine repository root.'
    exit 1
}

Set-Location -LiteralPath $repoRoot

$whitelistPatterns = @(
    'README.md',
    'README.ja.md',
    'VERSION',
    'install.ps1',
    '.gitignore',
    'AGENTS.md',
    '.winsmux.conf',
    '.winsmux.yaml.example',
    'docs/banner.png',
    'docs/pane-border-guide.md',
    'docs/operator-model.md',
    'docs/repo-surface-policy.md',
    'scripts/bootstrap-git-guard.ps1',
    'scripts/git-guard.ps1',
    'scripts/audit-public-surface.ps1',
    '.githooks/**',
    'tests/PublicSurfacePolicy.Tests.ps1',
    'winsmux-core/**',
    '.claude/CLAUDE.md',
    '.claude/hooks/**',
    '.claude/settings.json',
    '.github/workflows/test.yml',
    'tasks/roadmap-title-ja.example.psd1'
)

function Convert-WhitelistPatternToRegex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $normalized = $Pattern.Replace('\', '/')
    $escaped = [Regex]::Escape($normalized)
    $escaped = $escaped.Replace('\*\*', '.*')
    $escaped = $escaped.Replace('\*', '[^/]*')
    return '^' + $escaped + '$'
}

function Test-IsWhitelistedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string[]]$WhitelistRegexes
    )

    $normalizedPath = ($Path.Replace('\', '/') -replace '^\./', '')
    foreach ($regex in $WhitelistRegexes) {
        if ($normalizedPath -match $regex) {
            return $true
        }
    }

    return $false
}

$whitelistRegexes = @($whitelistPatterns | ForEach-Object { Convert-WhitelistPatternToRegex -Pattern $_ })

$stagedNewFiles = @(
    & git diff --cached --name-only --diff-filter=A -- 2>$null |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

if ($stagedNewFiles.Count -eq 0) {
    exit 0
}

$nonWhitelistedFiles = @(
    $stagedNewFiles |
        Where-Object { -not (Test-IsWhitelistedPath -Path $_ -WhitelistRegexes $whitelistRegexes) }
)

if ($nonWhitelistedFiles.Count -eq 0) {
    exit 0
}

foreach ($file in $nonWhitelistedFiles) {
    Write-Warning "Staged file is not in the pre-commit whitelist: $file"
}

$canPrompt = $true
try {
    $canPrompt = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
} catch {
    $canPrompt = $false
}

if (-not $canPrompt) {
    Write-Warning 'pre-commit-whitelist: no interactive terminal detected, refusing unwhitelisted staged files.'
    exit 1
}

$response = Read-Host 'Continue commit with non-whitelisted staged files? Type yes to continue'
if ($response -notin @('y', 'Y', 'yes', 'YES', 'Yes')) {
    Write-Host 'pre-commit-whitelist: commit aborted.'
    exit 1
}

Write-Host 'pre-commit-whitelist: continuing after confirmation.'
exit 0
