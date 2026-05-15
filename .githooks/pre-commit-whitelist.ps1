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
    'Cargo.toml',
    'Cargo.lock',
    'install.ps1',
    'core/Cargo.toml',
    'core/Cargo.lock',
    'core/src/*.rs',
    'core/src/bin/*.rs',
    'core/tests-rs/*.rs',
    'git-graph/**',
    '.gitignore',
    'GUARDRAILS.md',
    '.winsmux.conf',
    '.winsmux.yaml.example',
    'docs/brand-hero.svg',
    'docs/dogfood.md',
    'docs/pane-border-guide.md',
    'docs/README.md',
    'docs/README.ja.md',
    'docs/quickstart.md',
    'docs/quickstart.ja.md',
    'docs/installation.md',
    'docs/installation.ja.md',
    'docs/customization.md',
    'docs/customization.ja.md',
    'docs/google-colab-workers.md',
    'docs/google-colab-workers.ja.md',
    'docs/TROUBLESHOOTING.md',
    'docs/TROUBLESHOOTING.ja.md',
    'docs/operator-model.md',
    'docs/meta-planning-layer-design.md',
    'docs/authentication-support.md',
    'docs/authentication-support.ja.md',
    'docs/provider-and-model-support.md',
    'docs/provider-and-model-support.ja.md',
    'docs/external-control-plane.md',
    'docs/external-control-plane.ja.md',
    'docs/repo-surface-policy.md',
    'docs/project/pester-suite-inventory.json',
    'docs/project/pester-suite-reduction-plan.md',
    'docs/project/legacy-compat-surface-inventory.json',
    'docs/project/legacy-compat-surface-inventory.md',
    'docs/project/powershell-adapter-inventory.md',
    'docs/project/rust-schema-freeze-inventory.md',
    'docs/project/local-first-ui-contract.md',
    'docs/project/upstream-reevaluation-gate.md',
    'docs/project/upstream-snapshot-baseline.md',
    '.agents/README.md',
    'scripts/bootstrap-git-guard.ps1',
    'scripts/bump-version.ps1',
    'scripts/git-guard.ps1',
    'scripts/gitleaks-history.ps1',
    'scripts/gitleaks-history-baseline.txt',
    'scripts/audit-public-surface.ps1',
    'scripts/codex-subagent-worktree-guard.ps1',
    'scripts/validate-pester-reduction-plan.ps1',
    'scripts/validate-legacy-compat-inventory.ps1',
    'scripts/stage-npm-release.mjs',
    '.githooks/**',
    '.gitattributes',
    'tests/PublicSurfacePolicy.Tests.ps1',
    'tests/GitHubWritePreflight.Tests.ps1',
    'tests/McpServerContract.Tests.ps1',
    'tests/codex-subagent-worktree-guard.Tests.ps1',
    'tests/HarnessContract.Tests.ps1',
    'tests/ColabWorkerTemplates.Tests.ps1',
    'tests/ColabAcceptance.Tests.ps1',
    'tests/NpmReleasePackage.Tests.ps1',
    'tests/VersionSurface.Tests.ps1',
    'tests/fixtures/rust-parity/*.json',
    'tests/fixtures/rust-parity/*.jsonl',
    'tests/fixtures/rust-parity/*.yaml',
    'tests/test_support/rust_parity.rs',
    'packages/winsmux/**',
    'winsmux-app/scripts/*.mjs',
    'winsmux-app/public/**',
    'winsmux-app/package.json',
    'winsmux-app/package-lock.json',
    'winsmux-app/src/composerText.ts',
    'winsmux-app/src/sourceGraph.ts',
    'winsmux-app/src-tauri/Cargo.toml',
    'winsmux-app/src-tauri/Cargo.lock',
    'winsmux-app/src-tauri/tauri.conf.json',
    'winsmux-app/src-tauri/capabilities/*.json',
    'winsmux-app/src-tauri/src/control_pipe.rs',
    'workers/colab/*.py',
    'winsmux-core/**',
    '.claude/CLAUDE.md',
    '.claude/hooks/**',
    '.claude/settings.json',
    '.github/workflows/build-core.yml',
    '.github/workflows/build-desktop.yml',
    '.github/workflows/release-core.yml',
    '.github/workflows/release-desktop.yml',
    '.github/workflows/release-npm.yml',
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
