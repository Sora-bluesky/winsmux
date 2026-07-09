$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    Write-Error 'pre-commit-whitelist: failed to determine repository root.'
    exit 1
}

Set-Location -LiteralPath $repoRoot

# Keep routine public maintenance paths explicit so non-interactive commits fail closed.
$whitelistPatterns = @(
    'README.md',
    'README.ja.md',
    'CODE_OF_CONDUCT.md',
    'CONTRIBUTING.md',
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
    '.github/workflows/test.yml',
    '.github/ISSUE_TEMPLATE/**',
    '.github/PULL_REQUEST_TEMPLATE.md',
    '.gitignore',
    'GUARDRAILS.md',
    '.winsmux.conf',
    '.winsmux.yaml.example',
    'docs/brand-hero.svg',
    'docs/dogfood.md',
    'docs/pane-border-guide.md',
    'docs/README.md',
    'docs/README.ja.md',
    'docs/source-access.md',
    'docs/source-access.ja.md',
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
    'docs/cli-comparison-bakeoff.md',
    'docs/benchmarks/*.html',
    'docs/provider-and-model-support.md',
    'docs/provider-and-model-support.ja.md',
    'docs/external-control-plane.md',
    'docs/external-control-plane.ja.md',
    'docs/repo-surface-policy.md',
    'docs/incidents/**',
    'docs/project/ARCHITECTURE.md',
    'docs/project/DETAILED_DESIGN.md',
    'docs/project/THREAT_MODEL.md',
    'docs/project/THREAT_MODEL_AUDIT.md',
    'docs/project/pester-suite-inventory.json',
    'docs/project/pester-suite-reduction-plan.md',
    'docs/project/legacy-compat-surface-inventory.json',
    'docs/project/legacy-compat-surface-inventory.md',
    'docs/project/powershell-adapter-inventory.md',
    'docs/project/rust-schema-freeze-inventory.md',
    'docs/project/component-map.md',
    'docs/project/contract-source-of-truth-inventory.md',
    'docs/project/metrics-baseline.md',
    'docs/project/compatibility-deprecation-policy.md',
    'docs/project/design-freeze-gate.md',
    'docs/project/local-first-ui-contract.md',
    'docs/project/review-latency-hardening.md',
    'docs/project/upstream-reevaluation-gate.md',
    'docs/project/upstream-snapshot-baseline.md',
    'docs/project/enterprise-strategy-roadmap-alignment.md',
    'docs/project/v1-release-gate.md',
    'docs/project/v03618-release-hardening.md',
    'docs/project/v03619-repo-audit.md',
    'docs/project/v03620-coordinator-foundation.md',
    'docs/project/v03620-coordinator-baseline.md',
    'docs/project/v03621-local-router-shadow.md',
    'docs/project/v03621-local-router-shadow-profile.md',
    'docs/project/v03622-context-continuity.md',
    'docs/project/v03622-context-continuity.ja.md',
    'docs/project/pre-ga-v10-planning-sync.md',
    '.agents/README.md',
    'scripts/bootstrap-git-guard.ps1',
    'scripts/bump-version.ps1',
    'scripts/git-guard.ps1',
    'scripts/gitleaks-history.ps1',
    'scripts/gitleaks-history-baseline.txt',
    'scripts/audit-public-surface.ps1',
    'scripts/assert-release-notes-quality.ps1',
    'scripts/codex-subagent-worktree-guard.ps1',
    'scripts/run-cli-bakeoff-openrouter.ps1',
    'scripts/run-cli-bakeoff-local-workers.ps1',
    'scripts/start-cli-bakeoff-desktop.ps1',
    'scripts/summarize-cli-bakeoff.ps1',
    'scripts/test-cli-bakeoff-preflight.ps1',
    'scripts/test-v03617-reliability-gate.ps1',
    'scripts/test-v03618-release-hardening.ps1',
    'scripts/test-v03619-repo-audit.ps1',
    'scripts/test-v03620-coordinator-foundation.ps1',
    'scripts/test-v03621-local-router-shadow.ps1',
    'scripts/test-v03623-session-readiness.ps1',
    'scripts/test-v03626-desktop-split-gate.ps1',
    'scripts/test-v03627-compat-performance-gate.ps1',
    'scripts/test-v03628-race-abnormal-soak.ps1',
    'scripts/upstream-reevaluation.ps1',
    'scripts/validate-pester-reduction-plan.ps1',
    'scripts/validate-legacy-compat-inventory.ps1',
    'scripts/stage-npm-release.mjs',
    '.githooks/**',
    '.gitattributes',
    'tests/PublicSurfacePolicy.Tests.ps1',
    'tests/GitGuard.Tests.ps1',
    'tests/GitHubWritePreflight.Tests.ps1',
    'tests/McpServerContract.Tests.ps1',
    'tests/codex-subagent-worktree-guard.Tests.ps1',
    'tests/HarnessContract.Tests.ps1',
    'tests/ColabWorkerTemplates.Tests.ps1',
    'tests/ColabAcceptance.Tests.ps1',
    'tests/NpmReleasePackage.Tests.ps1',
    'tests/VersionSurface.Tests.ps1',
    'tests/CliBakeoff.Tests.ps1',
    'tests/ThreatModelContract.Tests.ps1',
    'tests/Integration.PluginHookLoader.Tests.ps1',
    'tests/UpstreamReevaluation.Tests.ps1',
    'tests/EnterpriseStrategyAlignment.Tests.ps1',
    'tests/ReviewLatencyHardening.Tests.ps1',
    'tests/V03618ReleaseHardening.Tests.ps1',
    'tests/V03619RepoAudit.Tests.ps1',
    'tests/V03620CoordinatorFoundation.Tests.ps1',
    'tests/V03621LocalRouterShadow.Tests.ps1',
    'tests/V03626DesktopSplitGate.Tests.ps1',
    'tests/V03627CompatPerformanceGate.Tests.ps1',
    'tests/V03628RaceAbnormalSoak.Tests.ps1',
    'tests/fixtures/rust-parity/*.json',
    'tests/fixtures/rust-parity/*.jsonl',
    'tests/fixtures/rust-parity/*.yaml',
    'tests/test_support/rust_parity.rs',
    'packages/winsmux/**',
    'winsmux-app/scripts/*.mjs',
    'winsmux-app/scripts/*.ps1',
    'winsmux-app/public/**',
    'winsmux-app/package.json',
    'winsmux-app/package-lock.json',
    'winsmux-app/src/main.ts',
    'winsmux-app/src/composerText.ts',
    'winsmux-app/src/modelCapabilities.ts',
    'winsmux-app/src/sourceGraph.ts',
    'winsmux-app/src/workerPaneRouting.ts',
    'winsmux-app/src/styles.css',
    'winsmux-app/src-tauri/Cargo.toml',
    'winsmux-app/src-tauri/Cargo.lock',
    'winsmux-app/src-tauri/*.nsh',
    'winsmux-app/src-tauri/*.wxl',
    'winsmux-app/src-tauri/*.wxs',
    'winsmux-app/src-tauri/tauri.conf.json',
    'winsmux-app/src-tauri/tauri.ci.conf.json',
    'winsmux-app/src-tauri/capabilities/*.json',
    'winsmux-app/src-tauri/scripts/*.ps1',
    'winsmux-app/src-tauri/src/control_pipe.rs',
    'workers/colab/*.py',
    'winsmux-core/router/**',
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
    'tasks/roadmap-title-ja.example.psd1',
    'tasks/cli-bakeoff/v1/**'
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
