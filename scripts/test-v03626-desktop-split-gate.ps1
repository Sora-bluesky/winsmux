param(
    [switch]$Json,
    [switch]$RequireEvidence
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'test-v03626-desktop-split-gate: failed to determine repository root.'
}

function Get-RepoContent {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }
    return Get-Content -LiteralPath $path -Raw
}

function Get-RepoJson {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $content = Get-RepoContent $RelativePath
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }
    return ($content | ConvertFrom-Json -AsHashtable)
}

function Get-RepoJsonEvidence {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable)
    } catch {
        return $null
    }
}

function Get-PhysicalLineCount {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return -1
    }

    $count = 0
    foreach ($line in [System.IO.File]::ReadLines($path)) {
        $count += 1
    }
    return $count
}

$checks = @()

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Pass,
        [string]$Evidence = ''
    )

    $script:checks += , [pscustomobject][ordered]@{
        name     = $Name
        pass     = $Pass
        evidence = $Evidence
    }
}

function Add-ContainsAllCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string[]]$Patterns,
        [Parameter(Mandatory = $true)][string]$Evidence
    )

    $missing = @($Patterns | Where-Object { $Content -notmatch $_ })
    Add-Check $Name ($missing.Count -eq 0) ("{0}; missing={1}" -f $Evidence, ($missing -join ', '))
}

function Add-JsonOkEvidenceCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $json = Get-RepoJsonEvidence $RelativePath
    $ok = $false
    if ($null -ne $json -and $json.ContainsKey('ok')) {
        $ok = [bool]$json['ok']
    }

    Add-Check $Name $ok $RelativePath
}

function Invoke-DesktopStatusBehaviorCheck {
    $checkerRelativePath = 'winsmux-app/scripts/desktop-status-e2e-check.mjs'
    $result = [ordered]@{
        pass     = $false
        evidence = "$checkerRelativePath; result=execution-failed"
    }

    try {
        $nodeCommand = Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1
    } catch {
        $result.evidence = "$checkerRelativePath; result=node-unavailable"
        return [pscustomobject]$result
    }

    $nodePath = [string]$nodeCommand.Path
    $checkerPath = Join-Path $repoRoot $checkerRelativePath
    $workingDirectory = Join-Path $repoRoot 'winsmux-app'
    if (
        [string]::IsNullOrWhiteSpace($nodePath) -or
        -not (Test-Path -LiteralPath $nodePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $checkerPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $workingDirectory -PathType Container)
    ) {
        $result.evidence = "$checkerRelativePath; result=entrypoint-unavailable"
        return [pscustomobject]$result
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $nodePath
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $null = $startInfo.ArgumentList.Add($checkerPath)

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            $result.evidence = "$checkerRelativePath; result=start-failed"
            return [pscustomobject]$result
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    } catch {
        $result.evidence = "$checkerRelativePath; result=process-failed"
        return [pscustomobject]$result
    } finally {
        $process.Dispose()
    }

    if ($exitCode -ne 0) {
        $result.evidence = "$checkerRelativePath; result=child-exit-nonzero"
        return [pscustomobject]$result
    }
    if ([string]::IsNullOrWhiteSpace($stdout)) {
        $result.evidence = "$checkerRelativePath; result=stdout-empty"
        return [pscustomobject]$result
    }

    try {
        $parsed = $stdout | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        $result.evidence = "$checkerRelativePath; result=stdout-invalid-json"
        return [pscustomobject]$result
    }

    if ($parsed -isnot [System.Collections.IDictionary]) {
        $result.evidence = "$checkerRelativePath; result=contract-invalid"
        return [pscustomobject]$result
    }

    $okIsTrueBoolean = (
        $parsed.ContainsKey('ok') -and
        $parsed['ok'] -is [System.Boolean] -and
        $parsed['ok'] -eq $true
    )
    $checkCountIsPositiveInteger = $false
    if ($parsed.ContainsKey('check_count')) {
        $checkCount = $parsed['check_count']
        $checkCountIsPositiveInteger = (
            ($checkCount -is [System.Int64] -or $checkCount -is [System.Numerics.BigInteger]) -and
            $checkCount -gt 0
        )
    }
    $checksIsCollection = (
        $parsed.ContainsKey('checks') -and
        $parsed['checks'] -is [System.Collections.ICollection]
    )

    if (-not ($okIsTrueBoolean -and $checkCountIsPositiveInteger -and $checksIsCollection)) {
        $result.evidence = "$checkerRelativePath; result=contract-invalid"
        return [pscustomobject]$result
    }

    $result.pass = $true
    $result.evidence = "$checkerRelativePath; result=ok"
    return [pscustomobject]$result
}

$packageJson = Get-RepoJson 'winsmux-app/package.json'
if ($null -eq $packageJson) {
    throw 'test-v03626-desktop-split-gate: failed to read winsmux-app/package.json.'
}
$packageScripts = $packageJson['scripts']

$requiredScripts = @(
    @{ name = 'build'; patterns = @('tsc', 'vite build'); evidence = 'typecheck and Vite production build' },
    @{ name = 'test:viewport-harness'; patterns = @('viewport-harness\.mjs'); evidence = 'visual and accessibility browser harness' },
    @{ name = 'test:clickable-coverage'; patterns = @('clickable-coverage-harness\.mjs'); evidence = 'clickable UI coverage harness' },
    @{ name = 'test:desktop-pane-e2e'; patterns = @('desktop-pane-e2e\.mjs'); evidence = 'native desktop pane E2E harness' },
    @{ name = 'test:desktop-status-e2e'; patterns = @('desktop-status-e2e\.mjs'); evidence = 'MSVC-initialized focused worker-status desktop E2E wrapper' },
    @{ name = 'test:desktop-release-popout-e2e'; patterns = @('desktop-pane-e2e\.mjs', '--release-popout-only'); evidence = 'packaged popout E2E path' },
    @{ name = 'test:desktop-split-static'; patterns = @('test-v03626-desktop-split-gate\.ps1'); evidence = 'v0.36.26 static wiring gate aggregator' },
    @{ name = 'test:desktop-split-gate'; patterns = @('test-v03626-desktop-split-gate\.ps1', '-RequireEvidence'); evidence = 'v0.36.26 release gate aggregator with required evidence' },
    @{ name = 'test:conversation-timeline'; patterns = @('conversation-timeline-check\.mjs'); evidence = 'extracted conversation timeline module check' },
    @{ name = 'test:composer-text'; patterns = @('composer-text-check\.mjs'); evidence = 'extracted composer text module check' },
    @{ name = 'test:project-explorer-tree'; patterns = @('project-explorer-tree-check\.mjs'); evidence = 'extracted project explorer module check' },
    @{ name = 'test:source-graph'; patterns = @('source-graph-check\.mjs'); evidence = 'extracted source graph module check' },
    @{ name = 'test:worker-pane-routing'; patterns = @('worker-pane-routing-check\.mjs'); evidence = 'extracted worker pane routing module check' },
    @{ name = 'test:worker-start-planning'; patterns = @('worker-start-planning-check\.mjs'); evidence = 'extracted worker start planning module check' }
)

foreach ($scriptSpec in $requiredScripts) {
    $scriptValue = [string]$packageScripts[$scriptSpec.name]
    Add-ContainsAllCheck "npm script $($scriptSpec.name) is wired for $($scriptSpec.evidence)" $scriptValue $scriptSpec.patterns 'winsmux-app/package.json'
}

$splitModules = @(
    'winsmux-app/src/conversationTimeline.ts',
    'winsmux-app/src/composerText.ts',
    'winsmux-app/src/projectExplorerTree.ts',
    'winsmux-app/src/sourceGraph.ts',
    'winsmux-app/src/workerPaneRouting.ts',
    'winsmux-app/src/workerStartPlanning.ts',
    'winsmux-app/src/desktopSummaryScheduler.ts',
    'winsmux-app/src/settingsNavigation.ts',
    'winsmux-app/src/settingsPreferenceOptions.ts'
)

foreach ($modulePath in $splitModules) {
    Add-Check "desktop split module exists: $modulePath" (Test-Path -LiteralPath (Join-Path $repoRoot $modulePath) -PathType Leaf) $modulePath
}

$viewportHarness = Get-RepoContent 'winsmux-app/scripts/viewport-harness.mjs'
$clickableHarness = Get-RepoContent 'winsmux-app/scripts/clickable-coverage-harness.mjs'
$desktopE2e = Get-RepoContent 'winsmux-app/scripts/desktop-pane-e2e.mjs'
$desktopStatusE2e = Get-RepoContent 'winsmux-app/scripts/desktop-status-e2e.mjs'
$windowsMsvcEnv = Get-RepoContent 'winsmux-app/scripts/windows-msvc-env.mjs'
$desktopStatusImplementation = $desktopStatusE2e + "`n" + $windowsMsvcEnv
$viteConfig = Get-RepoContent 'winsmux-app/vite.config.ts'

Add-ContainsAllCheck 'desktop status E2E wrapper and canonical stage table preserve the runner mode' $desktopStatusImplementation @(
    'windows-msvc-env\.mjs',
    'desktop-pane-e2e\.mjs',
    '--stop-after-worker-status',
    'projectRunResult'
) 'winsmux-app/scripts/desktop-status-e2e.mjs'

Add-ContainsAllCheck 'desktop status MSVC resolver exposes the frozen stage and process-result tables' $windowsMsvcEnv @(
    'DESKTOP_STATUS_STAGE_TABLE',
    'PROCESS_RESULT_DECISION_TABLE',
    'resolveMsvcEnvironment',
    'sanitizeStatusEnvironment'
) 'winsmux-app/scripts/windows-msvc-env.mjs'

$desktopStatusBehavior = Invoke-DesktopStatusBehaviorCheck
Add-Check 'desktop status behavioral contract executes successfully' `
    ([bool]$desktopStatusBehavior.pass) `
    ([string]$desktopStatusBehavior.evidence)

Add-ContainsAllCheck 'visual harness writes replayable viewport evidence' $viewportHarness @(
    'OUTPUT_DIR',
    'viewport-harness\.json',
    'viewport-harness-failure\.png',
    'WINSMUX_PLAYWRIGHT_CHROMIUM_EXECUTABLE',
    'assertFullyVisible',
    'assertNoOverlap'
) 'winsmux-app/scripts/viewport-harness.mjs'

Add-ContainsAllCheck 'accessibility harness covers stateful desktop controls' $viewportHarness @(
    'desktop voice input accessibility coverage',
    'aria-label',
    'aria-pressed',
    'aria-expanded'
) 'winsmux-app/scripts/viewport-harness.mjs'

Add-ContainsAllCheck 'clickable coverage harness covers narrow and wide layouts' $clickableHarness @(
    'const VIEWPORTS',
    'name: "narrow"',
    'name: "wide"',
    'WINSMUX_PLAYWRIGHT_CHROMIUM_EXECUTABLE',
    'clickable-coverage\.json',
    'clickable-coverage-failure\.png',
    'aria-disabled'
) 'winsmux-app/scripts/clickable-coverage-harness.mjs'

Add-ContainsAllCheck 'desktop E2E records native window, worker-status, and timing evidence' $desktopE2e @(
    'assertNoFixedViewportBlank',
    'assertVisibleStartupGeometry',
    'durationMs',
    'worker-status-only',
    'desktop-pane-e2e\.json',
    'desktop-pane-e2e-worker-status\.png'
) 'winsmux-app/scripts/desktop-pane-e2e.mjs'

Add-ContainsAllCheck 'desktop E2E artifacts are not watched by the Vite dev server' $viteConfig @(
    '\*\*/src-tauri/\*\*',
    '\*\*/output/\*\*'
) 'winsmux-app/vite.config.ts'

$moduleBudgets = @(
    [ordered]@{ name = 'bridge entrypoint'; path = 'scripts/winsmux-core.ps1'; baseline = 19989; allowed_growth = 200; require_not_above_baseline = $true },
    [ordered]@{ name = 'desktop frontend entrypoint'; path = 'winsmux-app/src/main.ts'; baseline = 19172; allowed_growth = 200; require_not_above_baseline = $true },
    [ordered]@{ name = 'rust operator cli'; path = 'core/src/operator_cli.rs'; baseline = 11658; allowed_growth = 199; require_not_above_baseline = $true },
    [ordered]@{ name = 'desktop backend shell'; path = 'winsmux-app/src-tauri/src/desktop_backend.rs'; baseline = 6152; allowed_growth = 56; require_not_above_baseline = $true },
    [ordered]@{ name = 'desktop control-plane params'; path = 'winsmux-app/src-tauri/src/desktop_control_plane_params.rs'; baseline = 158; allowed_growth = 40; require_not_above_baseline = $true },
    [ordered]@{ name = 'desktop team profile bridge'; path = 'winsmux-app/src-tauri/src/desktop_team_profile.rs'; baseline = 210; allowed_growth = 40; require_not_above_baseline = $true }
)

$moduleBudgetResults = @()
foreach ($budget in $moduleBudgets) {
    $lineCount = Get-PhysicalLineCount $budget.path
    $limit = [int]$budget.baseline + [int]$budget.allowed_growth
    $moduleBudgetResults += , [pscustomobject][ordered]@{
        name           = $budget.name
        path           = $budget.path
        physical_lines = $lineCount
        baseline       = [int]$budget.baseline
        allowed_growth = [int]$budget.allowed_growth
        limit          = $limit
    }
    Add-Check "$($budget.name) stays within design-freeze growth budget" ($lineCount -ge 0 -and $lineCount -le $limit) ("{0}: {1}/{2}" -f $budget.path, $lineCount, $limit)
    if ([bool]$budget.require_not_above_baseline) {
        Add-Check "$($budget.name) is not above v0.36.24 baseline" ($lineCount -ge 0 -and $lineCount -le [int]$budget.baseline) ("{0}: {1}/{2}" -f $budget.path, $lineCount, $budget.baseline)
    }
}

$workflow = Get-RepoContent '.github/workflows/test.yml'
$whitelist = Get-RepoContent '.githooks/pre-commit-whitelist.ps1'
$gitignore = Get-RepoContent '.gitignore'

Add-ContainsAllCheck 'CI Pester matrix includes the v0.36.26 desktop split gate' $workflow @(
    'desktop-split-v03626',
    'V03626DesktopSplitGate\.Tests\.ps1'
) '.github/workflows/test.yml'

foreach ($path in @('scripts/test-v03626-desktop-split-gate.ps1', 'tests/V03626DesktopSplitGate.Tests.ps1')) {
    Add-Check "pre-commit whitelist allows $path" ($whitelist -match [regex]::Escape($path)) '.githooks/pre-commit-whitelist.ps1'
}

Add-Check 'gitignore allows the v0.36.26 desktop split Pester wrapper' ($gitignore -match [regex]::Escape('!tests/V03626DesktopSplitGate.Tests.ps1')) '.gitignore'

$evidenceMode = if ($RequireEvidence) { 'required' } else { 'static-wiring' }

if ($RequireEvidence) {
    Add-JsonOkEvidenceCheck 'visual evidence file exists and reports ok' 'winsmux-app/output/playwright/viewport-harness/viewport-harness.json'
    Add-JsonOkEvidenceCheck 'clickable coverage evidence file exists and reports ok' 'winsmux-app/output/playwright/clickable-coverage/clickable-coverage.json'
    Add-JsonOkEvidenceCheck 'desktop E2E evidence file exists and reports ok' 'winsmux-app/output/playwright/desktop-pane-e2e/desktop-pane-e2e.json'

    $desktopEvidence = Get-RepoContent 'winsmux-app/output/playwright/desktop-pane-e2e/desktop-pane-e2e.json'
    Add-Check 'performance evidence includes measured durationMs' ($desktopEvidence -match '"durationMs"\s*:') 'winsmux-app/output/playwright/desktop-pane-e2e/desktop-pane-e2e.json'
}

$releaseGateInputs = @(
    [ordered]@{
        class                 = 'visual'
        command               = 'npm --prefix winsmux-app run test:viewport-harness'
        evidence              = 'winsmux-app/output/playwright/viewport-harness/viewport-harness.json'
        required_for_release  = $true
        validated_in_this_run = [bool]$RequireEvidence
    },
    [ordered]@{
        class                 = 'accessibility'
        command               = 'npm --prefix winsmux-app run test:viewport-harness'
        evidence              = 'desktop voice input accessibility coverage step'
        required_for_release  = $true
        validated_in_this_run = [bool]$RequireEvidence
    },
    [ordered]@{
        class                 = 'clickable-coverage'
        command               = 'npm --prefix winsmux-app run test:clickable-coverage'
        evidence              = 'winsmux-app/output/playwright/clickable-coverage/clickable-coverage.json'
        required_for_release  = $true
        validated_in_this_run = [bool]$RequireEvidence
    },
    [ordered]@{
        class                 = 'desktop-e2e'
        command               = 'npm --prefix winsmux-app run test:desktop-status-e2e'
        evidence              = 'winsmux-app/output/playwright/desktop-pane-e2e/desktop-pane-e2e.json'
        required_for_release  = $true
        validated_in_this_run = [bool]$RequireEvidence
    },
    [ordered]@{
        class                 = 'module-budget'
        command               = 'pwsh -NoProfile -File scripts/test-v03626-desktop-split-gate.ps1 -Json'
        evidence              = 'module_budget_results'
        required_for_release  = $true
        validated_in_this_run = $true
    },
    [ordered]@{
        class                 = 'performance'
        command               = 'npm --prefix winsmux-app run test:desktop-status-e2e'
        evidence              = 'desktop-pane-e2e step durationMs and viewport fill assertions'
        required_for_release  = $true
        validated_in_this_run = [bool]$RequireEvidence
    }
)

$failed = @($checks | Where-Object { -not $_.pass })
$releaseReady = ($failed.Count -eq 0 -and [bool]$RequireEvidence)
$result = [ordered]@{
    gate_id             = 'v03626-desktop-split-gate'
    evidence_mode       = $evidenceMode
    release_ready       = $releaseReady
    all_pass            = ($failed.Count -eq 0)
    check_count         = $checks.Count
    failed_count        = $failed.Count
    release_gate_inputs = @($releaseGateInputs)
    module_budgets      = @($moduleBudgetResults)
    checks              = @($checks)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    foreach ($check in $checks) {
        $status = if ($check.pass) { 'PASS' } else { 'FAIL' }
        Write-Host ("[{0}] {1} :: {2}" -f $status, $check.name, $check.evidence)
    }
}

if ($failed.Count -gt 0) {
    exit 1
}
