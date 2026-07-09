[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$RequireEvidence,
    [string]$EvidencePath = '.winsmux/evidence/v03628-race-abnormal-soak/soak-summary.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'test-v03628-race-abnormal-soak: failed to determine repository root.'
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

$sessionReadiness = Get-RepoContent 'scripts/test-v03623-session-readiness.ps1'
$sessionCore = Get-RepoContent 'core/src/session.rs'
$shellLifecycle = Get-RepoContent 'core/src/shell_lifecycle.rs'
$workflow = Get-RepoContent '.github/workflows/test.yml'
$gitignore = Get-RepoContent '.gitignore'
$whitelist = Get-RepoContent '.githooks/pre-commit-whitelist.ps1'

Add-Check 'session readiness gate supports bounded 100-run soak' (
    $sessionReadiness -match '\[ValidateRange\(1,\s*1000\)\]\s*\r?\n\s*\[int\]\$MaxRuns' -and
    $sessionReadiness -match 'MaxRuns'
) 'scripts/test-v03623-session-readiness.ps1'
Add-Check 'session readiness gate covers registry startup variants' (
    @('fresh', 'stale', 'orphan-key', 'orphan-port') | ForEach-Object { $sessionReadiness -match [regex]::Escape($_) } | Where-Object { -not $_ } | Measure-Object | ForEach-Object { $_.Count -eq 0 }
) 'scripts/test-v03623-session-readiness.ps1'
Add-Check 'session readiness gate covers abnormal exit variants' (
    @('normal', 'early-child-exit', 'forced-server-kill') | ForEach-Object { $sessionReadiness -match [regex]::Escape($_) } | Where-Object { -not $_ } | Measure-Object | ForEach-Object { $_.Count -eq 0 }
) 'scripts/test-v03623-session-readiness.ps1'
Add-Check 'session cleanup has startup cleanup concurrency coverage' (
    $sessionCore -match 'cleanup_stale_port_files_tolerates_concurrent_startup_cleanup_passes'
) 'core/src/session.rs'
Add-Check 'shell lifecycle has property-style spawn matrix coverage' (
    $shellLifecycle -match 'property_matrix_rejects_unsafe_warm_transplants'
) 'core/src/shell_lifecycle.rs'
Add-Check 'shell lifecycle has 100-run restore exit soak coverage' (
    $shellLifecycle -match 'hundred_run_soak_keeps_restore_exit_invariants' -and
    $shellLifecycle -match '0\.\.100'
) 'core/src/shell_lifecycle.rs'
Add-Check 'shell lifecycle has concurrent classifier coverage' (
    $shellLifecycle -match 'concurrent_matrix_classification_is_deterministic'
) 'core/src/shell_lifecycle.rs'
Add-Check 'Pester contract test is present' (
    Test-Path -LiteralPath (Get-RepoPath 'tests/V03628RaceAbnormalSoak.Tests.ps1') -PathType Leaf
) 'tests/V03628RaceAbnormalSoak.Tests.ps1'
Add-Check 'CI runs the v0.36.28 race abnormal soak contract' (
    $workflow -match 'race-abnormal-soak-v03628' -and
    $workflow -match 'tests/V03628RaceAbnormalSoak\.Tests\.ps1'
) '.github/workflows/test.yml'
Add-Check 'public surface allowlists include the v0.36.28 gate files' (
    $gitignore -match [regex]::Escape('!tests/V03628RaceAbnormalSoak.Tests.ps1') -and
    $whitelist -match [regex]::Escape('scripts/test-v03628-race-abnormal-soak.ps1') -and
    $whitelist -match [regex]::Escape('tests/V03628RaceAbnormalSoak.Tests.ps1')
) '.gitignore / .githooks/pre-commit-whitelist.ps1'

$requiredEvidenceClasses = @(
    'startup-cleanup-concurrency',
    'property-matrix',
    'hundred-run-soak',
    'abnormal-exit',
    'long-running'
)

if ($RequireEvidence) {
    $resolvedEvidencePath = Join-Path $repoRoot $EvidencePath
    $evidenceExists = Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf
    Add-Check 'soak evidence file exists' $evidenceExists (ConvertTo-ReportPath $EvidencePath)

    $evidence = $null
    if ($evidenceExists) {
        try {
            $evidence = (Get-Content -LiteralPath $resolvedEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json)
            Add-Check 'soak evidence is valid JSON' $true (ConvertTo-ReportPath $EvidencePath)
        } catch {
            Add-Check 'soak evidence is valid JSON' $false $_.Exception.Message
        }
    }

    $okValue = Get-JsonPropertyValue -InputObject $evidence -Name 'ok' -Default $null
    $ok = ($okValue -is [bool] -and $okValue -eq $true)
    $runCount = [int](Get-JsonPropertyValue -InputObject $evidence -Name 'run_count' -Default 0)
    $classes = @(Get-JsonPropertyValue -InputObject $evidence -Name 'classes' -Default @())
    $failures = @(Get-JsonPropertyValue -InputObject $evidence -Name 'failures' -Default @())

    Add-Check 'soak evidence reports boolean ok true' ($ok -eq $true) (ConvertTo-ReportPath $EvidencePath)
    Add-Check 'soak evidence records at least 100 runs' ($runCount -ge 100) "run_count=$runCount"
    foreach ($requiredClass in $requiredEvidenceClasses) {
        Add-Check "soak evidence includes $requiredClass" ($classes -contains $requiredClass) (ConvertTo-ReportPath $EvidencePath)
    }
    Add-Check 'soak evidence has no recorded failures' ($failures.Count -eq 0) "failure_count=$($failures.Count)"
}

$failed = @($checks | Where-Object { -not $_.pass })
$allPass = ($failed.Count -eq 0)
$result = [pscustomobject][ordered]@{
    gate_id                   = 'v03628-race-abnormal-soak'
    evidence_mode             = if ($RequireEvidence) { 'required-evidence' } else { 'static-wiring' }
    all_pass                  = $allPass
    release_ready             = ($RequireEvidence -and $allPass)
    failed_count              = $failed.Count
    check_count               = $checks.Count
    required_evidence_classes = $requiredEvidenceClasses
    evidence_path             = ConvertTo-ReportPath $EvidencePath
    checks                    = $checks
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
} else {
    foreach ($check in $checks) {
        $mark = if ($check.pass) { 'PASS' } else { 'FAIL' }
        Write-Output ("[{0}] {1} {2}" -f $mark, $check.name, $check.evidence)
    }
    Write-Output ("all_pass={0}; release_ready={1}; failed_count={2}" -f $result.all_pass, $result.release_ready, $result.failed_count)
}

if (-not $allPass) {
    exit 1
}
