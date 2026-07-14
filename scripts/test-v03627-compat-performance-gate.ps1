param(
    [switch]$Json,
    [switch]$RequireEvidence
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'test-v03627-compat-performance-gate: failed to determine repository root.'
}

function Get-RepoPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    return (Join-Path $repoRoot $RelativePath)
}

function Get-RepoContent {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Get-RepoPath $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8
}

function Get-RepoJson {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $content = Get-RepoContent $RelativePath
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }
    return ($content | ConvertFrom-Json)
}

function Get-JsonPropertyValue {
    param(
        [Parameter(Mandatory = $false)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return $Default
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
}

function Test-JsonBooleanTrue {
    param([Parameter(Mandatory = $false)]$Value)
    return ($Value -is [bool] -and [bool]$Value)
}

function Get-DesktopEvidenceStatus {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $raw = Get-RepoContent $RelativePath
    $json = Get-RepoJson $RelativePath
    $ok = Test-JsonBooleanTrue (Get-JsonPropertyValue -InputObject $json -Name 'ok' -Default $false)

    return [pscustomobject][ordered]@{
        ok           = $ok
        hasDuration  = ($raw -match '"durationMs"\s*:')
        relativePath = $RelativePath
    }
}

function Test-StaticGateWithCommand {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return $false
    }

    $executable = if (-not [string]::IsNullOrWhiteSpace($command.Path)) { $command.Path } else { $command.Source }
    if ([string]::IsNullOrWhiteSpace($executable)) {
        return $false
    }

    $output = & $executable @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    try {
        $result = ($output | Out-String | ConvertFrom-Json)
        return (Test-JsonBooleanTrue (Get-JsonPropertyValue -InputObject $result -Name 'all_pass' -Default $false))
    } catch {
        return $false
    }
}

function Invoke-ReleaseInputCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Class,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$DisplayCommand
    )

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return [pscustomobject][ordered]@{
            class           = $Class
            command         = $DisplayCommand
            passed          = $false
            exit_code       = $null
            output_tail     = @("command not found: $CommandName")
        }
    }

    $executable = if (-not [string]::IsNullOrWhiteSpace($command.Path)) { $command.Path } else { $command.Source }
    if ([string]::IsNullOrWhiteSpace($executable)) {
        return [pscustomobject][ordered]@{
            class           = $Class
            command         = $DisplayCommand
            passed          = $false
            exit_code       = $null
            output_tail     = @("command path not found: $CommandName")
        }
    }

    Push-Location -LiteralPath $repoRoot
    try {
        $output = & $executable @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $lines = @($output | ForEach-Object { [string]$_ })
    return [pscustomobject][ordered]@{
        class           = $Class
        command         = $DisplayCommand
        passed          = ($exitCode -eq 0)
        exit_code       = $exitCode
        output_tail     = @($lines | Select-Object -Last 10)
    }
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

function Add-ExistingFileCheck {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    Add-Check "required file exists: $RelativePath" (Test-Path -LiteralPath (Get-RepoPath $RelativePath) -PathType Leaf) $RelativePath
}

$packageJson = Get-RepoJson 'winsmux-app/package.json'
if ($null -eq $packageJson) {
    throw 'test-v03627-compat-performance-gate: failed to read winsmux-app/package.json.'
}
$packageScripts = Get-JsonPropertyValue -InputObject $packageJson -Name 'scripts'

$requiredPackageScripts = @(
    [ordered]@{ name = 'test:common-contract-package'; patterns = @('generate-common-contract-bindings\.mjs --check', 'common-contract-package-check\.mjs'); evidence = 'common contract package drift and current-contract-migration metadata' },
    [ordered]@{ name = 'test:automation-driver-pool'; patterns = @('automation-driver-pool-check\.mjs'); evidence = 'process registry automation driver pool check' },
    [ordered]@{ name = 'test:bakeoff-runner'; patterns = @('bakeoff-runner-check\.mjs'); evidence = 'benchmark runner latency and command-row contract check' },
    [ordered]@{ name = 'test:v03627-compat-performance-static'; patterns = @('test-v03627-compat-performance-gate\.ps1'); evidence = 'v0.36.27 static release gate aggregator' },
    [ordered]@{ name = 'test:v03627-compat-performance-gate'; patterns = @('test-v03627-compat-performance-gate\.ps1', '-RequireEvidence'); evidence = 'v0.36.27 evidence-required release gate aggregator' }
)

foreach ($scriptSpec in $requiredPackageScripts) {
    $scriptValue = [string](Get-JsonPropertyValue -InputObject $packageScripts -Name $scriptSpec.name -Default '')
    Add-ContainsAllCheck "npm script $($scriptSpec.name) is wired for $($scriptSpec.evidence)" $scriptValue $scriptSpec.patterns 'winsmux-app/package.json'
}

$workflow = Get-RepoContent '.github/workflows/test.yml'
$whitelist = Get-RepoContent '.githooks/pre-commit-whitelist.ps1'
$gitignore = Get-RepoContent '.gitignore'
$commonContractCheck = Get-RepoContent 'winsmux-app/scripts/common-contract-package-check.mjs'
$commonContractRust = Get-RepoContent 'core/tests-rs/common_contract.rs'
$fixtureComparison = Get-RepoContent 'core/tests-rs/fixture_comparison.rs'
$testParity = Get-RepoContent 'core/tests-rs/test_parity.rs'
$bakeoffPreflight = Get-RepoContent 'scripts/test-cli-bakeoff-preflight.ps1'
$benchmarkPackRaw = Get-RepoContent 'tasks/cli-bakeoff/v1/benchmark-pack.json'
$bakeoffRunnerCheck = Get-RepoContent 'winsmux-app/scripts/bakeoff-runner-check.mjs'
$automationPoolCheck = Get-RepoContent 'winsmux-app/scripts/automation-driver-pool-check.mjs'
$desktopSplitGate = Get-RepoContent 'scripts/test-v03626-desktop-split-gate.ps1'

Add-ContainsAllCheck 'CI runs common contract and process pool drift checks' $workflow @(
    'Common Contract Drift Gate',
    'npm run test:common-contract-package',
    'npm run test:automation-driver-pool'
) '.github/workflows/test.yml'

Add-ContainsAllCheck 'CI Pester matrix runs worker benchmark and v0.36.27 gate suites' $workflow @(
    'worker-benchmark',
    'tests/CliBakeoff\.Tests\.ps1',
    'compat-performance-v03627',
    'tests/V03627CompatPerformanceGate\.Tests\.ps1'
) '.github/workflows/test.yml'

Add-ContainsAllCheck 'CI keeps full core and desktop backend cargo tests in release gate' $workflow @(
    'cargo test --manifest-path core/Cargo\.toml',
    'cargo test --manifest-path winsmux-app/src-tauri/Cargo\.toml'
) '.github/workflows/test.yml'

Add-ContainsAllCheck 'common contract package keeps current fixture and breaking migration metadata' $commonContractCheck @(
    'common-contract-package-v0\.36\.28\.json',
    'common-contract-backend-migration-v0\.36\.28\.json',
    'backendMigration\.from_versions',
    'backendMigration\.breaking',
    'backendMigration\.source_commit'
) 'winsmux-app/scripts/common-contract-package-check.mjs'

Add-ContainsAllCheck 'Rust common-contract test validates current-contract-migration boundaries' $commonContractRust @(
    'common-contract-package-v0\.36\.28\.json',
    'common-contract-backend-migration-v0\.36\.28\.json',
    'common_contract_v03628_records_breaking_backend_migration',
    'common_contract_rejects_older_versions_without_implicit_migration',
    'common_contract_rejects_an_unexpected_backend_capability',
    '0\.36\.24.*0\.36\.25.*0\.36\.26.*0\.36\.27'
) 'core/tests-rs/common_contract.rs'

Add-ContainsAllCheck 'Rust projection fixtures compare against the PowerShell golden corpus' $fixtureComparison @(
    'read_power_shell_golden',
    'fixture_comparison_harness_loads_power_shell_golden_corpus',
    'fixture_comparison_harness_diffs_modeled_projection_payloads',
    'PowerShell golden corpus'
) 'core/tests-rs/fixture_comparison.rs'

Add-ContainsAllCheck 'Rust parity fixtures cover public read-heavy payloads' $testParity @(
    'rust_parity_board_fixture_deserializes',
    'rust_parity_inbox_fixture_deserializes',
    'rust_parity_digest_fixture_deserializes',
    'rust_parity_explain_fixture_deserializes'
) 'core/tests-rs/test_parity.rs'

Add-ContainsAllCheck 'benchmark preflight enforces 27-task same-condition governance' $bakeoffPreflight @(
    'harness_bench_27_tasks_required',
    'same_timeout_for_all_workers',
    'same_workspace_for_all_workers',
    'worker-to-worker messaging is disabled',
    'official Harness Bench task count is met'
) 'scripts/test-cli-bakeoff-preflight.ps1'

$benchmarkPack = $null
if (-not [string]::IsNullOrWhiteSpace($benchmarkPackRaw)) {
    $benchmarkPack = $benchmarkPackRaw | ConvertFrom-Json
}

$benchmarkWorkers = @()
$benchmarkTasks = @()
if ($null -ne $benchmarkPack) {
    $benchmarkWorkers = @(Get-JsonPropertyValue -InputObject $benchmarkPack -Name 'default_workers' -Default @())
    $benchmarkTasks = @(Get-JsonPropertyValue -InputObject $benchmarkPack -Name 'tasks' -Default @())
}

Add-Check 'benchmark pack declares 27 official tasks' (
    $null -ne $benchmarkPack -and
    [int](Get-JsonPropertyValue -InputObject $benchmarkPack -Name 'official_task_count_target' -Default 0) -eq 27 -and
    $benchmarkTasks.Count -eq 27
) ("tasks={0}" -f $benchmarkTasks.Count)

Add-Check 'benchmark pack declares six default workers' ($benchmarkWorkers.Count -eq 6) ("workers={0}" -f $benchmarkWorkers.Count)
Add-Check 'benchmark pack default timeout remains 3600 seconds' (
    $null -ne $benchmarkPack -and [int](Get-JsonPropertyValue -InputObject $benchmarkPack -Name 'default_timeout_seconds' -Default 0) -eq 3600
) ("timeout={0}" -f (Get-JsonPropertyValue -InputObject $benchmarkPack -Name 'default_timeout_seconds' -Default 'missing'))

$runGovernance = Get-JsonPropertyValue -InputObject $benchmarkPack -Name 'run_governance'
Add-Check 'benchmark pack requires same task set' (Test-JsonBooleanTrue (Get-JsonPropertyValue -InputObject $runGovernance -Name 'same_task_set_for_all_workers')) 'tasks/cli-bakeoff/v1/benchmark-pack.json'
Add-Check 'benchmark pack requires same timeout' (Test-JsonBooleanTrue (Get-JsonPropertyValue -InputObject $runGovernance -Name 'same_timeout_for_all_workers')) 'tasks/cli-bakeoff/v1/benchmark-pack.json'
Add-Check 'benchmark pack requires same workspace' (Test-JsonBooleanTrue (Get-JsonPropertyValue -InputObject $runGovernance -Name 'same_workspace_for_all_workers')) 'tasks/cli-bakeoff/v1/benchmark-pack.json'
Add-Check 'benchmark pack disables worker-to-worker messaging' ([string](Get-JsonPropertyValue -InputObject $runGovernance -Name 'worker_to_worker_messaging' -Default '') -eq 'disabled') 'tasks/cli-bakeoff/v1/benchmark-pack.json'

Add-ContainsAllCheck 'benchmark runner check covers elapsed-time rounding and command rows' $bakeoffRunnerCheck @(
    'elapsedSeconds: 12\.3456',
    'elapsed_seconds',
    'buildCommandRow must round elapsed_seconds to 3 decimal places',
    'winsmux benchmark ready-check',
    'winsmux benchmark dispatch task WB-001'
) 'winsmux-app/scripts/bakeoff-runner-check.mjs'

Add-ContainsAllCheck 'process pool check covers reuse, pool-full, heartbeat, and active-lease probe behavior' $automationPoolCheck @(
    'active_lease',
    'pool_full',
    'heartbeatAutomationDriverLease',
    'releaseAutomationDriverLease',
    'active_lease_probe_requires_metrics',
    'automation driver pool lock'
) 'winsmux-app/scripts/automation-driver-pool-check.mjs'

Add-ContainsAllCheck 'desktop split gate still provides latency evidence contract' $desktopSplitGate @(
    'performance evidence includes measured durationMs',
    'durationMs',
    'test:desktop-status-e2e'
) 'scripts/test-v03626-desktop-split-gate.ps1'

foreach ($path in @('scripts/test-v03627-compat-performance-gate.ps1', 'tests/V03627CompatPerformanceGate.Tests.ps1')) {
    Add-Check "pre-commit whitelist allows $path" ($whitelist -match [regex]::Escape($path)) '.githooks/pre-commit-whitelist.ps1'
}

Add-Check 'gitignore allows the v0.36.27 compat performance Pester wrapper' ($gitignore -match [regex]::Escape('!tests/V03627CompatPerformanceGate.Tests.ps1')) '.gitignore'

foreach ($path in @(
    'tests/fixtures/rust-parity/common-contract-package.json',
    'tests/fixtures/rust-parity/common-contract-package-v0.36.28.json',
    'tests/fixtures/rust-parity/common-contract-backend-migration-v0.36.28.json',
    'tasks/cli-bakeoff/v1/benchmark-pack.json'
)) {
    Add-ExistingFileCheck $path
}

$evidenceMode = if ($RequireEvidence) { 'required' } else { 'static-wiring' }
$gateScriptPath = Get-RepoPath 'scripts/test-v03627-compat-performance-gate.ps1'
$powershell7Validated = (
    $PSVersionTable.PSEdition -eq 'Core' -or (
        $RequireEvidence -and
        (Test-StaticGateWithCommand 'pwsh' @('-NoProfile', '-File', $gateScriptPath, '-Json'))
    )
)
$powershell5Validated = (
    $PSVersionTable.PSEdition -eq 'Desktop' -or (
        $RequireEvidence -and
        (Test-StaticGateWithCommand 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gateScriptPath, '-Json'))
    )
)
$releaseCommandResults = @()

if ($RequireEvidence) {
    $releaseCommandResults += , (Invoke-ReleaseInputCommand 'current-contract-migration' 'npm.cmd' @('--prefix', 'winsmux-app', 'run', 'test:common-contract-package') 'npm --prefix winsmux-app run test:common-contract-package')
    $releaseCommandResults += , (Invoke-ReleaseInputCommand 'current-contract-migration' 'cargo' @('test', '--manifest-path', 'core/Cargo.toml', '--test', 'common_contract') 'cargo test --manifest-path core/Cargo.toml --test common_contract')
    $releaseCommandResults += , (Invoke-ReleaseInputCommand 'current-contract-migration' 'cargo' @('test', '--manifest-path', 'core/Cargo.toml', '--test', 'fixture_comparison') 'cargo test --manifest-path core/Cargo.toml --test fixture_comparison')
    $releaseCommandResults += , (Invoke-ReleaseInputCommand 'latency' 'npm.cmd' @('--prefix', 'winsmux-app', 'run', 'test:bakeoff-runner') 'npm --prefix winsmux-app run test:bakeoff-runner')
    $releaseCommandResults += , (Invoke-ReleaseInputCommand 'latency' 'npm.cmd' @('--prefix', 'winsmux-app', 'run', 'test:desktop-status-e2e') 'npm --prefix winsmux-app run test:desktop-status-e2e')
    $releaseCommandResults += , (Invoke-ReleaseInputCommand 'process-benchmark' 'npm.cmd' @('--prefix', 'winsmux-app', 'run', 'test:automation-driver-pool') 'npm --prefix winsmux-app run test:automation-driver-pool')
    $releaseCommandResults += , (Invoke-ReleaseInputCommand 'worker-benchmark' 'pwsh' @('-NoProfile', '-File', (Get-RepoPath 'scripts/test-cli-bakeoff-preflight.ps1'), '-PackPath', (Get-RepoPath 'tasks/cli-bakeoff/v1/benchmark-pack.json'), '-Json') 'pwsh -NoProfile -File scripts/test-cli-bakeoff-preflight.ps1 -PackPath tasks/cli-bakeoff/v1/benchmark-pack.json -Json')

    foreach ($commandResult in $releaseCommandResults) {
        Add-Check "release input command passed: $($commandResult.command)" ([bool]$commandResult.passed) ("exit_code={0}" -f $commandResult.exit_code)
    }
}

$desktopEvidenceStatus = $null
if ($RequireEvidence) {
    $desktopEvidenceStatus = Get-DesktopEvidenceStatus 'winsmux-app/output/playwright/desktop-pane-e2e/desktop-pane-e2e.json'
    Add-Check 'latency evidence reports ok true' ([bool]$desktopEvidenceStatus.ok) $desktopEvidenceStatus.relativePath
    Add-Check 'latency evidence includes measured durationMs' ([bool]$desktopEvidenceStatus.hasDuration) $desktopEvidenceStatus.relativePath
}

function Test-ReleaseCommandClassPassed {
    param([Parameter(Mandatory = $true)][string]$Class)

    if (-not $RequireEvidence) {
        return $false
    }

    $classResults = @($releaseCommandResults | Where-Object { $_.class -eq $Class })
    return ($classResults.Count -gt 0 -and @($classResults | Where-Object { -not $_.passed }).Count -eq 0)
}

$latencyEvidencePassed = (
    $RequireEvidence -and
    $null -ne $desktopEvidenceStatus -and
    [bool]$desktopEvidenceStatus.ok -and
    [bool]$desktopEvidenceStatus.hasDuration
)

$releaseGateInputs = @(
    [ordered]@{
        class                 = 'current-contract-migration'
        command               = 'npm --prefix winsmux-app run test:common-contract-package; cargo test --manifest-path core/Cargo.toml --test common_contract; cargo test --manifest-path core/Cargo.toml --test fixture_comparison'
        evidence              = 'current-contract-migration validation for the current fixture and explicit metadata, plus Rust PowerShell golden corpus comparison'
        required_for_release  = $true
        validated_in_this_run = (Test-ReleaseCommandClassPassed 'current-contract-migration')
    },
    [ordered]@{
        class                 = 'powershell-7'
        command               = 'pwsh -NoProfile -File scripts/test-v03627-compat-performance-gate.ps1 -Json'
        evidence              = 'gate executes under PowerShell 7'
        required_for_release  = $true
        validated_in_this_run = $powershell7Validated
    },
    [ordered]@{
        class                 = 'powershell-5'
        command               = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-v03627-compat-performance-gate.ps1 -Json'
        evidence              = 'gate executes under Windows PowerShell 5.1 when present'
        required_for_release  = $true
        validated_in_this_run = $powershell5Validated
    },
    [ordered]@{
        class                 = 'latency'
        command               = 'npm --prefix winsmux-app run test:bakeoff-runner; npm --prefix winsmux-app run test:desktop-status-e2e'
        evidence              = 'benchmark elapsed_seconds rounding and desktop durationMs evidence'
        required_for_release  = $true
        validated_in_this_run = ((Test-ReleaseCommandClassPassed 'latency') -and $latencyEvidencePassed)
    },
    [ordered]@{
        class                 = 'process-benchmark'
        command               = 'npm --prefix winsmux-app run test:automation-driver-pool'
        evidence              = 'automation driver pool reuse, pool-full, heartbeat, release, and active-lease probe checks'
        required_for_release  = $true
        validated_in_this_run = (Test-ReleaseCommandClassPassed 'process-benchmark')
    },
    [ordered]@{
        class                 = 'worker-benchmark'
        command               = 'pwsh -NoProfile -File scripts/test-cli-bakeoff-preflight.ps1 -PackPath tasks/cli-bakeoff/v1/benchmark-pack.json -Json'
        evidence              = '27-task benchmark pack and same-condition governance preflight'
        required_for_release  = $true
        validated_in_this_run = (Test-ReleaseCommandClassPassed 'worker-benchmark')
    }
)

$failed = @($checks | Where-Object { -not $_.pass })
$requiredReleaseInputs = @($releaseGateInputs | Where-Object {
    Test-JsonBooleanTrue (Get-JsonPropertyValue -InputObject $_ -Name 'required_for_release' -Default $false)
})
$missingReleaseInputClasses = @($requiredReleaseInputs | Where-Object {
    -not (Test-JsonBooleanTrue (Get-JsonPropertyValue -InputObject $_ -Name 'validated_in_this_run' -Default $false))
} | ForEach-Object {
    [string](Get-JsonPropertyValue -InputObject $_ -Name 'class' -Default '')
})
$allRequiredInputsValidated = ($missingReleaseInputClasses.Count -eq 0)
$releaseReady = ($failed.Count -eq 0 -and [bool]$RequireEvidence -and $allRequiredInputsValidated)
$result = [ordered]@{
    gate_id                     = 'v03627-compat-performance-gate'
    evidence_mode               = $evidenceMode
    release_ready               = $releaseReady
    release_gate_inputs_complete = $allRequiredInputsValidated
    missing_release_gate_inputs = @($missingReleaseInputClasses)
    all_pass                    = ($failed.Count -eq 0)
    check_count                 = $checks.Count
    failed_count                = $failed.Count
    powershell_edition          = $PSVersionTable.PSEdition
    powershell_version          = $PSVersionTable.PSVersion.ToString()
    release_gate_inputs         = @($releaseGateInputs)
    release_command_results     = @($releaseCommandResults)
    checks                      = @($checks)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    foreach ($check in $checks) {
        $status = if ($check.pass) { 'PASS' } else { 'FAIL' }
        Write-Host ("[{0}] {1} :: {2}" -f $status, $check.name, $check.evidence)
    }
}

if ($failed.Count -gt 0 -or ($RequireEvidence -and -not $releaseReady)) {
    exit 1
}
