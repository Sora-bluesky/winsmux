param(
    [switch]$Json,
    [switch]$RequireEvidence,
    [string]$EvidencePath = '.winsmux/evidence/v03628-runtime-reliability/runtime-reliability-report.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'test-v03628-runtime-reliability-gate: failed to determine repository root.'
}
$currentGitHead = (& git -C $repoRoot rev-parse HEAD 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($currentGitHead)) {
    throw 'test-v03628-runtime-reliability-gate: failed to determine current git head.'
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

function ConvertTo-ReportPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
    $fullRepo = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\')
    if ($fullPath.StartsWith($fullRepo, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $fullPath.Substring($fullRepo.Length).TrimStart('\') -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($relative)) {
            return '<repo-root>'
        }
        return "<repo-root>/$relative"
    }
    return '<local-path>'
}

function Get-JsonPropertyValue {
    param(
        [Parameter(Mandatory = $false)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)]$Default = $null
    )

    if ($null -eq $InputObject) {
        return ,$Default
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return ,$InputObject[$Name]
        }
        return ,$Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return ,$Default
    }
    return ,$property.Value
}

function Test-JsonPropertyExists {
    param(
        [Parameter(Mandatory = $false)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $false
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function Test-JsonBooleanTrue {
    param([Parameter(Mandatory = $false)]$Value)
    return ($Value -is [bool] -and [bool]$Value)
}

function Test-JsonBooleanFalse {
    param([Parameter(Mandatory = $false)]$Value)
    return ($Value -is [bool] -and -not [bool]$Value)
}

function Test-JsonNumber {
    param([Parameter(Mandatory = $false)]$Value)
    return ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal])
}

function Test-JsonIntegerAtLeast {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $true)][int]$Minimum
    )

    if (-not (Test-JsonNumber $Value)) {
        return $false
    }

    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        return $false
    }

    return ([math]::Abs($number - [math]::Round($number)) -lt 0.0000001 -and [int64]$number -ge $Minimum)
}

function Test-NonEmptyString {
    param([Parameter(Mandatory = $false)]$Value)
    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Test-NonEmptyTimestamp {
    param([Parameter(Mandatory = $false)]$Value)
    return (
        ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)) -or
        ($Value -is [datetime])
    )
}

function Test-EmptyObservedValue {
    param([Parameter(Mandatory = $false)]$Value)
    return ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)))
}

function Test-RuntimeTargetIdentity {
    param([Parameter(Mandatory = $false)]$Target)

    $kind = Get-JsonPropertyValue -InputObject $Target -Name 'kind' -Default $null
    $processId = Get-JsonPropertyValue -InputObject $Target -Name 'process_id' -Default $null
    $executable = Get-JsonPropertyValue -InputObject $Target -Name 'executable' -Default $null
    $allowedKinds = @('desktop-app', 'winsmux-core', 'orchestra', 'worker')

    return (
        (Test-NonEmptyString $kind) -and
        ($allowedKinds -contains $kind) -and
        (Test-JsonIntegerAtLeast $processId 1) -and
        (Test-NonEmptyString $executable)
    )
}

function Test-DependencyGateReport {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $true)][string]$ExpectedGateId,
        [Parameter(Mandatory = $true)][string]$ExpectedHead
    )

    $gateId = Get-JsonPropertyValue -InputObject $Value -Name 'gate_id' -Default $null
    $releaseReady = Get-JsonPropertyValue -InputObject $Value -Name 'release_ready' -Default $null
    $headShaExists = Test-JsonPropertyExists -InputObject $Value -Name 'head_sha'
    $headSha = Get-JsonPropertyValue -InputObject $Value -Name 'head_sha' -Default $null
    $source = Get-JsonPropertyValue -InputObject $Value -Name 'source'
    $sourceGitHeadExists = Test-JsonPropertyExists -InputObject $source -Name 'git_head'
    $sourceGitHead = Get-JsonPropertyValue -InputObject $source -Name 'git_head' -Default $null
    $commandExists = Test-JsonPropertyExists -InputObject $Value -Name 'command'
    $command = Get-JsonPropertyValue -InputObject $Value -Name 'command' -Default $null
    $evidencePathExists = Test-JsonPropertyExists -InputObject $Value -Name 'evidence_path'
    $evidencePath = Get-JsonPropertyValue -InputObject $Value -Name 'evidence_path' -Default $null
    $allPass = Get-JsonPropertyValue -InputObject $Value -Name 'all_pass' -Default $null
    $failedCount = Get-JsonPropertyValue -InputObject $Value -Name 'failed_count' -Default $null
    $releaseInputsCompleteExists = Test-JsonPropertyExists -InputObject $Value -Name 'release_gate_inputs_complete'
    $releaseInputsComplete = Get-JsonPropertyValue -InputObject $Value -Name 'release_gate_inputs_complete' -Default $null
    $missingReleaseInputsExists = Test-JsonPropertyExists -InputObject $Value -Name 'missing_release_gate_inputs'
    $missingReleaseInputsRaw = Get-JsonPropertyValue -InputObject $Value -Name 'missing_release_gate_inputs' -Default @()
    $missingReleaseInputs = @()
    if ($null -ne $missingReleaseInputsRaw) {
        $missingReleaseInputs = @($missingReleaseInputsRaw)
    }

    $headMatches = if ($headShaExists) {
        (Test-NonEmptyString $headSha) -and $headSha -eq $ExpectedHead -and ((-not $sourceGitHeadExists) -or ((Test-NonEmptyString $sourceGitHead) -and $sourceGitHead -eq $ExpectedHead))
    } else {
        $sourceGitHeadExists -and (Test-NonEmptyString $sourceGitHead) -and $sourceGitHead -eq $ExpectedHead
    }
    $commandValid = ((-not $commandExists) -or (Test-NonEmptyString $command))
    $evidencePathValid = ((-not $evidencePathExists) -or ((Test-NonEmptyString $evidencePath) -and $evidencePath.StartsWith('<repo-root>/', [System.StringComparison]::Ordinal)))
    $allPassValid = Test-JsonBooleanTrue $allPass
    $failedCountValid = ((Test-JsonNumber $failedCount) -and [double]$failedCount -eq 0)
    $releaseInputsValid = $true
    $missingReleaseInputsValid = $true
    if ($ExpectedGateId -eq 'v03627-compat-performance-gate') {
        $releaseInputsValid = ($releaseInputsCompleteExists -and (Test-JsonBooleanTrue $releaseInputsComplete))
        $missingReleaseInputsValid = ($missingReleaseInputsExists -and $missingReleaseInputs.Count -eq 0)
    }

    return (
        (Test-NonEmptyString $gateId) -and
        $gateId -eq $ExpectedGateId -and
        (Test-JsonBooleanTrue $releaseReady) -and
        $headMatches -and
        $commandValid -and
        $evidencePathValid -and
        $allPassValid -and
        $failedCountValid -and
        $releaseInputsValid -and
        $missingReleaseInputsValid
    )
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

$requiredEvidenceClasses = @(
    'cpu',
    'memory',
    'event-loss',
    'compatibility-report',
    'no-diagnostic-override'
)

$packageJson = Get-RepoJson 'winsmux-app/package.json'
if ($null -eq $packageJson) {
    throw 'test-v03628-runtime-reliability-gate: failed to read winsmux-app/package.json.'
}
$packageScripts = Get-JsonPropertyValue -InputObject $packageJson -Name 'scripts'
$workflow = Get-RepoContent '.github/workflows/test.yml'
$gitignore = Get-RepoContent '.gitignore'
$whitelist = Get-RepoContent '.githooks/pre-commit-whitelist.ps1'
$raceGate = Get-RepoContent 'scripts/test-v03628-race-abnormal-soak.ps1'
$compatGate = Get-RepoContent 'scripts/test-v03627-compat-performance-gate.ps1'

Add-ContainsAllCheck 'npm script test:v03628-runtime-reliability-static is wired' ([string](Get-JsonPropertyValue -InputObject $packageScripts -Name 'test:v03628-runtime-reliability-static' -Default '')) @(
    'test-v03628-runtime-reliability-gate\.ps1',
    '-Json'
) 'winsmux-app/package.json'

Add-ContainsAllCheck 'npm script test:v03628-runtime-reliability-gate requires evidence' ([string](Get-JsonPropertyValue -InputObject $packageScripts -Name 'test:v03628-runtime-reliability-gate' -Default '')) @(
    'test-v03628-runtime-reliability-gate\.ps1',
    '-Json',
    '-RequireEvidence'
) 'winsmux-app/package.json'

Add-ContainsAllCheck 'CI runs the v0.36.28 runtime reliability contract' $workflow @(
    'runtime-reliability-v03628',
    'tests/V03628RuntimeReliabilityGate\.Tests\.ps1'
) '.github/workflows/test.yml'

Add-Check 'public surface allowlists include the v0.36.28 runtime reliability files' (
    $gitignore -match [regex]::Escape('!tests/V03628RuntimeReliabilityGate.Tests.ps1') -and
    $whitelist -match [regex]::Escape('scripts/test-v03628-runtime-reliability-gate.ps1') -and
    $whitelist -match [regex]::Escape('tests/V03628RuntimeReliabilityGate.Tests.ps1')
) '.gitignore / .githooks/pre-commit-whitelist.ps1'

Add-ContainsAllCheck 'race abnormal soak gate remains required-evidence capable' $raceGate @(
    'v03628-race-abnormal-soak',
    'RequireEvidence',
    'release_ready',
    'startup-cleanup-concurrency',
    'hundred-run-soak',
    'long-running'
) 'scripts/test-v03628-race-abnormal-soak.ps1'

Add-ContainsAllCheck 'compat performance gate remains release-ready evidence capable' $compatGate @(
    'v03627-compat-performance-gate',
    'release_gate_inputs',
    'release_ready',
    'compat-performance-v03627',
    'powershell-5',
    'powershell-7'
) 'scripts/test-v03627-compat-performance-gate.ps1'

$releaseGateInputs = @(
    [ordered]@{
        class                 = 'cpu'
        evidence              = 'runtime report records CPU samples and marks CPU budget within bounds'
        required_for_release  = $true
        validated_in_this_run = $false
    },
    [ordered]@{
        class                 = 'memory'
        evidence              = 'runtime report records memory samples and marks memory budget within bounds'
        required_for_release  = $true
        validated_in_this_run = $false
    },
    [ordered]@{
        class                 = 'event-loss'
        evidence              = 'runtime report records expected/received event counts with zero lost events'
        required_for_release  = $true
        validated_in_this_run = $false
    },
    [ordered]@{
        class                 = 'compatibility-report'
        evidence              = 'runtime report includes compatibility gate and race/soak gate release-ready summaries'
        required_for_release  = $true
        validated_in_this_run = $false
    },
    [ordered]@{
        class                 = 'no-diagnostic-override'
        evidence              = 'runtime report proves no diagnostic override was used'
        required_for_release  = $true
        validated_in_this_run = $false
    }
)

if ($RequireEvidence) {
    $resolvedEvidencePath = Join-Path $repoRoot $EvidencePath
    $evidenceExists = Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf
    Add-Check 'runtime reliability evidence file exists' $evidenceExists (ConvertTo-ReportPath $EvidencePath)

    $evidence = $null
    if ($evidenceExists) {
        try {
            $evidence = (Get-Content -LiteralPath $resolvedEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json)
            Add-Check 'runtime reliability evidence is valid JSON' $true (ConvertTo-ReportPath $EvidencePath)
        } catch {
            Add-Check 'runtime reliability evidence is valid JSON' $false $_.Exception.Message
        }
    }

    $okValue = Get-JsonPropertyValue -InputObject $evidence -Name 'ok' -Default $null
    Add-Check 'runtime reliability evidence reports boolean ok true' (Test-JsonBooleanTrue $okValue) (ConvertTo-ReportPath $EvidencePath)

    $source = Get-JsonPropertyValue -InputObject $evidence -Name 'source'
    $sourceGitHead = Get-JsonPropertyValue -InputObject $source -Name 'git_head' -Default $null
    $sourceCommand = Get-JsonPropertyValue -InputObject $source -Name 'command' -Default $null
    $sourceGeneratedAt = Get-JsonPropertyValue -InputObject $source -Name 'generated_at_utc' -Default $null
    Add-Check 'runtime reliability evidence matches current git head' ((Test-NonEmptyString $sourceGitHead) -and $sourceGitHead -eq $currentGitHead) "report=$sourceGitHead current=$currentGitHead"
    Add-Check 'runtime reliability evidence records generation command' (Test-NonEmptyString $sourceCommand) 'source.command'
    Add-Check 'runtime reliability evidence records generation timestamp' (Test-NonEmptyTimestamp $sourceGeneratedAt) 'source.generated_at_utc'

    $classesValue = Get-JsonPropertyValue -InputObject $evidence -Name 'classes' -Default @()
    $classes = @($classesValue)
    foreach ($requiredClass in $requiredEvidenceClasses) {
        Add-Check "runtime reliability evidence includes $requiredClass" ($classes -contains $requiredClass) (ConvertTo-ReportPath $EvidencePath)
    }

    $diagnosticOverride = Get-JsonPropertyValue -InputObject $evidence -Name 'diagnostic_override' -Default $null
    $diagnosticOverridesValue = Get-JsonPropertyValue -InputObject $evidence -Name 'diagnostic_overrides' -Default @()
    $diagnosticOverrides = @($diagnosticOverridesValue)
    $diagnosticObservations = Get-JsonPropertyValue -InputObject $evidence -Name 'diagnostic_override_observations'
    $diagnosticEnv = Get-JsonPropertyValue -InputObject $diagnosticObservations -Name 'env'
    $diagnosticCliArgsValue = Get-JsonPropertyValue -InputObject $diagnosticObservations -Name 'cli_args' -Default @()
    $diagnosticCliArgs = @($diagnosticCliArgsValue)
    $diagnosticObservationsComplete = (
        (Test-JsonPropertyExists -InputObject $diagnosticObservations -Name 'env') -and
        (Test-JsonPropertyExists -InputObject $diagnosticObservations -Name 'cli_args') -and
        (Test-JsonPropertyExists -InputObject $diagnosticEnv -Name 'WINSMUX_RUNTIME_GATE_OVERRIDE') -and
        (Test-JsonPropertyExists -InputObject $diagnosticEnv -Name 'WINSMUX_DIAGNOSTIC_OVERRIDE')
    )
    $overrideEnvClean = (
        (Test-EmptyObservedValue (Get-JsonPropertyValue -InputObject $diagnosticEnv -Name 'WINSMUX_RUNTIME_GATE_OVERRIDE' -Default $null)) -and
        (Test-EmptyObservedValue (Get-JsonPropertyValue -InputObject $diagnosticEnv -Name 'WINSMUX_DIAGNOSTIC_OVERRIDE' -Default $null))
    )
    $noDiagnosticOverride = ((Test-JsonBooleanFalse $diagnosticOverride) -and $diagnosticOverrides.Count -eq 0 -and $diagnosticCliArgs.Count -eq 0 -and $diagnosticObservationsComplete -and $overrideEnvClean)
    Add-Check 'runtime reliability evidence uses no diagnostic override' $noDiagnosticOverride "diagnostic_overrides=$($diagnosticOverrides.Count); cli_args=$($diagnosticCliArgs.Count); observations_complete=$diagnosticObservationsComplete"

    $metrics = Get-JsonPropertyValue -InputObject $evidence -Name 'metrics'
    $cpu = Get-JsonPropertyValue -InputObject $metrics -Name 'cpu'
    $memory = Get-JsonPropertyValue -InputObject $metrics -Name 'memory'
    $eventLoss = Get-JsonPropertyValue -InputObject $metrics -Name 'event_loss'

    $cpuPeak = Get-JsonPropertyValue -InputObject $cpu -Name 'peak_percent' -Default $null
    $cpuBudget = Get-JsonPropertyValue -InputObject $cpu -Name 'budget_peak_percent' -Default $null
    $cpuSampleCount = Get-JsonPropertyValue -InputObject $cpu -Name 'sample_count' -Default $null
    $cpuSampleDuration = Get-JsonPropertyValue -InputObject $cpu -Name 'sample_duration_ms' -Default $null
    $cpuWithinBudget = Get-JsonPropertyValue -InputObject $cpu -Name 'within_budget' -Default $null
    $cpuTarget = Get-JsonPropertyValue -InputObject $cpu -Name 'target'
    $cpuValidated = ((Test-JsonNumber $cpuPeak) -and [double]$cpuPeak -ge 0 -and [double]$cpuPeak -le 100 -and (Test-JsonNumber $cpuBudget) -and [double]$cpuBudget -gt 0 -and [double]$cpuBudget -le 100 -and [double]$cpuPeak -le [double]$cpuBudget -and (Test-JsonIntegerAtLeast $cpuSampleCount 1) -and (Test-JsonIntegerAtLeast $cpuSampleDuration 1000) -and (Test-JsonBooleanTrue $cpuWithinBudget) -and (Test-RuntimeTargetIdentity $cpuTarget))
    Add-Check 'CPU evidence has target samples and is within budget' $cpuValidated "peak_percent=$cpuPeak; budget_peak_percent=$cpuBudget; sample_count=$cpuSampleCount; sample_duration_ms=$cpuSampleDuration"

    $memoryPeak = Get-JsonPropertyValue -InputObject $memory -Name 'peak_mb' -Default $null
    $memoryBudget = Get-JsonPropertyValue -InputObject $memory -Name 'budget_peak_mb' -Default $null
    $memorySampleCount = Get-JsonPropertyValue -InputObject $memory -Name 'sample_count' -Default $null
    $memorySampleDuration = Get-JsonPropertyValue -InputObject $memory -Name 'sample_duration_ms' -Default $null
    $memoryWithinBudget = Get-JsonPropertyValue -InputObject $memory -Name 'within_budget' -Default $null
    $memoryTarget = Get-JsonPropertyValue -InputObject $memory -Name 'target'
    $memoryValidated = ((Test-JsonNumber $memoryPeak) -and [double]$memoryPeak -gt 0 -and (Test-JsonNumber $memoryBudget) -and [double]$memoryBudget -gt 0 -and [double]$memoryPeak -le [double]$memoryBudget -and (Test-JsonIntegerAtLeast $memorySampleCount 1) -and (Test-JsonIntegerAtLeast $memorySampleDuration 1000) -and (Test-JsonBooleanTrue $memoryWithinBudget) -and (Test-RuntimeTargetIdentity $memoryTarget))
    Add-Check 'memory evidence has target samples and is within budget' $memoryValidated "peak_mb=$memoryPeak; budget_peak_mb=$memoryBudget; sample_count=$memorySampleCount; sample_duration_ms=$memorySampleDuration"

    $eventScenario = Get-JsonPropertyValue -InputObject $eventLoss -Name 'scenario' -Default $null
    $eventSource = Get-JsonPropertyValue -InputObject $eventLoss -Name 'source' -Default $null
    $eventDuration = Get-JsonPropertyValue -InputObject $eventLoss -Name 'duration_ms' -Default $null
    $expectedEvents = Get-JsonPropertyValue -InputObject $eventLoss -Name 'expected_events' -Default $null
    $receivedEvents = Get-JsonPropertyValue -InputObject $eventLoss -Name 'received_events' -Default $null
    $lostEvents = Get-JsonPropertyValue -InputObject $eventLoss -Name 'lost_events' -Default $null
    $eventLossValidated = ((Test-NonEmptyString $eventScenario) -and (Test-NonEmptyString $eventSource) -and $eventSource -eq 'pty-output' -and (Test-JsonIntegerAtLeast $eventDuration 1) -and (Test-JsonIntegerAtLeast $expectedEvents 100) -and (Test-JsonIntegerAtLeast $receivedEvents 0) -and (Test-JsonIntegerAtLeast $lostEvents 0) -and [int64]$lostEvents -eq 0 -and [int64]$receivedEvents -eq [int64]$expectedEvents)
    Add-Check 'event-loss evidence records zero dropped PTY events' $eventLossValidated "scenario=$eventScenario; expected=$expectedEvents; received=$receivedEvents; lost=$lostEvents"

    $compatibilityReport = Get-JsonPropertyValue -InputObject $evidence -Name 'compatibility_report'
    $compatGate = Get-JsonPropertyValue -InputObject $compatibilityReport -Name 'compat_performance_gate'
    $soakGate = Get-JsonPropertyValue -InputObject $compatibilityReport -Name 'race_abnormal_soak_gate'
    $compatValidated = (
        (Test-JsonBooleanTrue (Get-JsonPropertyValue -InputObject $compatibilityReport -Name 'ok' -Default $null)) -and
        (Test-NonEmptyTimestamp (Get-JsonPropertyValue -InputObject $compatibilityReport -Name 'generated_at_utc' -Default $null)) -and
        (Test-DependencyGateReport -Value $compatGate -ExpectedGateId 'v03627-compat-performance-gate' -ExpectedHead $currentGitHead) -and
        (Test-DependencyGateReport -Value $soakGate -ExpectedGateId 'v03628-race-abnormal-soak' -ExpectedHead $currentGitHead)
    )
    Add-Check 'compatibility report includes release-ready dependency gates' $compatValidated (ConvertTo-ReportPath $EvidencePath)

    foreach ($gateInput in $releaseGateInputs) {
        if ($gateInput.class -eq 'cpu') { $gateInput['validated_in_this_run'] = $cpuValidated }
        if ($gateInput.class -eq 'memory') { $gateInput['validated_in_this_run'] = $memoryValidated }
        if ($gateInput.class -eq 'event-loss') { $gateInput['validated_in_this_run'] = $eventLossValidated }
        if ($gateInput.class -eq 'compatibility-report') { $gateInput['validated_in_this_run'] = $compatValidated }
        if ($gateInput.class -eq 'no-diagnostic-override') { $gateInput['validated_in_this_run'] = $noDiagnosticOverride }
    }
}

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

$result = [pscustomobject][ordered]@{
    gate_id                      = 'v03628-runtime-reliability-gate'
    evidence_mode                = if ($RequireEvidence) { 'required-evidence' } else { 'static-wiring' }
    all_pass                     = ($failed.Count -eq 0)
    release_ready                = $releaseReady
    release_gate_inputs_complete = $allRequiredInputsValidated
    missing_release_gate_inputs  = @($missingReleaseInputClasses)
    failed_count                 = $failed.Count
    check_count                  = $checks.Count
    required_evidence_classes    = $requiredEvidenceClasses
    evidence_path                = ConvertTo-ReportPath $EvidencePath
    release_gate_inputs          = @($releaseGateInputs)
    checks                       = @($checks)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    foreach ($check in $checks) {
        $mark = if ($check.pass) { 'PASS' } else { 'FAIL' }
        Write-Output ("[{0}] {1} {2}" -f $mark, $check.name, $check.evidence)
    }
    Write-Output ("all_pass={0}; release_ready={1}; failed_count={2}" -f $result.all_pass, $result.release_ready, $result.failed_count)
}

if ($failed.Count -gt 0 -or ($RequireEvidence -and -not $releaseReady)) {
    exit 1
}
