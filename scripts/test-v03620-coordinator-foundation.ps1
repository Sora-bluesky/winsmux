[CmdletBinding()]
param(
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    $repoRoot = Split-Path $PSScriptRoot -Parent
}

function Get-RepoContent {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8
}

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

$checks = @()
$router = Get-RepoContent 'winsmux-core/scripts/coordinator-router.ps1'
$tests = Get-RepoContent 'tests/V03620CoordinatorFoundation.Tests.ps1'
$doc = Get-RepoContent 'docs/project/v03620-coordinator-foundation.md'
$baselineReport = Get-RepoContent 'docs/project/v03620-coordinator-baseline.md'
$workflow = Get-RepoContent '.github/workflows/test.yml'
$whitelist = Get-RepoContent '.githooks/pre-commit-whitelist.ps1'

Add-Check 'coordinator router script exists' (-not [string]::IsNullOrWhiteSpace($router)) 'winsmux-core/scripts/coordinator-router.ps1'
Add-Check 'coordinator Pester tests exist' (-not [string]::IsNullOrWhiteSpace($tests)) 'tests/V03620CoordinatorFoundation.Tests.ps1'
Add-Check 'coordinator design document exists' (-not [string]::IsNullOrWhiteSpace($doc)) 'docs/project/v03620-coordinator-foundation.md'
Add-Check 'coordinator baseline report exists' (-not [string]::IsNullOrWhiteSpace($baselineReport)) 'docs/project/v03620-coordinator-baseline.md'

foreach ($functionName in @(
    'New-WinsmuxRouteContext',
    'Invoke-WinsmuxDeterministicRoute',
    'Get-WinsmuxCoordinatorRoleContract',
    'Write-WinsmuxRouteTrace',
    'Invoke-WinsmuxOfflineRouteEvaluator'
)) {
    Add-Check "router exposes $functionName" ($router -match "function\s+$([regex]::Escape($functionName))\b") 'winsmux-core/scripts/coordinator-router.ps1'
}

foreach ($token in @(
    'schema_version',
    'policy_revision',
    'raw_prompt_stored',
    'no_learning_router',
    'no_default_behavior_replacement',
    'router_cannot_merge_or_release',
    'provider_calls_allowed'
)) {
    Add-Check "RouteContext carries $token" ($router -match [regex]::Escape($token)) 'winsmux-core/scripts/coordinator-router.ps1'
}

foreach ($reason in @(
    'slot_unavailable',
    'role_mismatch',
    'write_scope_conflict',
    'failed_route_retry_blocked',
    'verifier_capability_missing'
)) {
    Add-Check "router records exclusion reason $reason" ($router -match [regex]::Escape($reason)) 'winsmux-core/scripts/coordinator-router.ps1'
}

foreach ($role in @('Thinker', 'Worker', 'Verifier')) {
    Add-Check "role contract includes $role" ($router -match [regex]::Escape($role)) 'winsmux-core/scripts/coordinator-router.ps1'
}

foreach ($baselineName in @(
    'deterministic_capability_router',
    'strongest_single_slot',
    'round_robin',
    'random_seeded',
    'static_task_type_rule'
)) {
    Add-Check "offline evaluator includes $baselineName" ($router -match [regex]::Escape($baselineName)) 'winsmux-core/scripts/coordinator-router.ps1'
}

foreach ($forbidden in @('Invoke-RestMethod', 'Invoke-WebRequest', 'Start-Process', 'OPENROUTER_API_KEY', 'ANTHROPIC_API_KEY')) {
    Add-Check "router does not call or store $forbidden" ($router -notmatch [regex]::Escape($forbidden)) 'winsmux-core/scripts/coordinator-router.ps1'
}

foreach ($taskId in @('TASK-598', 'TASK-599', 'TASK-600', 'TASK-601', 'TASK-602')) {
    Add-Check "design document maps $taskId" ($doc -match [regex]::Escape($taskId)) 'docs/project/v03620-coordinator-foundation.md'
}

foreach ($token in @(
    'Structured RouteContext',
    'deterministic router',
    'shadow trace',
    'manual dispatch remains the user-facing path',
    'no online training',
    'offline evaluator'
)) {
    Add-Check "design document records $token" ($doc -match [regex]::Escape($token)) 'docs/project/v03620-coordinator-foundation.md'
}

foreach ($token in @(
    'provider calls',
    'deterministic success rate',
    'fixture cases',
    'Harness Bench result',
    'not a live-provider benchmark'
)) {
    Add-Check "baseline report records $token" ($baselineReport -match [regex]::Escape($token)) 'docs/project/v03620-coordinator-baseline.md'
}

Add-Check 'CI runs v0.36.20 coordinator tests' ($workflow -match 'V03620CoordinatorFoundation\.Tests\.ps1') '.github/workflows/test.yml'
Add-Check 'pre-commit whitelist allows coordinator router' ($whitelist -match [regex]::Escape('winsmux-core/**')) '.githooks/pre-commit-whitelist.ps1'
Add-Check 'pre-commit whitelist allows v0.36.20 gate script' ($whitelist -match [regex]::Escape('scripts/test-v03620-coordinator-foundation.ps1')) '.githooks/pre-commit-whitelist.ps1'
Add-Check 'pre-commit whitelist allows v0.36.20 tests' ($whitelist -match [regex]::Escape('tests/V03620CoordinatorFoundation.Tests.ps1')) '.githooks/pre-commit-whitelist.ps1'
Add-Check 'pre-commit whitelist allows v0.36.20 document' ($whitelist -match [regex]::Escape('docs/project/v03620-coordinator-foundation.md')) '.githooks/pre-commit-whitelist.ps1'
Add-Check 'pre-commit whitelist allows v0.36.20 baseline report' ($whitelist -match [regex]::Escape('docs/project/v03620-coordinator-baseline.md')) '.githooks/pre-commit-whitelist.ps1'

$failed = @($checks | Where-Object { -not $_.pass })
$result = [ordered]@{
    gate_id      = 'v03620-coordinator-foundation'
    all_pass     = ($failed.Count -eq 0)
    check_count  = $checks.Count
    failed_count = $failed.Count
    checks       = @($checks)
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
