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
$shadow = Get-RepoContent 'winsmux-core/scripts/local-router-shadow.ps1'
$manifestText = Get-RepoContent 'winsmux-core/router/local-small-router-v03621.manifest.json'
$weightsText = Get-RepoContent 'winsmux-core/router/local-small-router-v03621.weights.json'
$tests = Get-RepoContent 'tests/V03621LocalRouterShadow.Tests.ps1'
$doc = Get-RepoContent 'docs/project/v03621-local-router-shadow.md'
$profileDoc = Get-RepoContent 'docs/project/v03621-local-router-shadow-profile.md'
$appMain = Get-RepoContent 'winsmux-app/src/main.ts'
$appStyles = Get-RepoContent 'winsmux-app/src/styles.css'
$workflow = Get-RepoContent '.github/workflows/test.yml'
$whitelist = Get-RepoContent '.githooks/pre-commit-whitelist.ps1'

Add-Check 'local router shadow script exists' (-not [string]::IsNullOrWhiteSpace($shadow)) 'winsmux-core/scripts/local-router-shadow.ps1'
Add-Check 'local router manifest exists' (-not [string]::IsNullOrWhiteSpace($manifestText)) 'winsmux-core/router/local-small-router-v03621.manifest.json'
Add-Check 'local router weights exist' (-not [string]::IsNullOrWhiteSpace($weightsText)) 'winsmux-core/router/local-small-router-v03621.weights.json'
Add-Check 'v0.36.21 Pester tests exist' (-not [string]::IsNullOrWhiteSpace($tests)) 'tests/V03621LocalRouterShadow.Tests.ps1'
Add-Check 'local router design document exists' (-not [string]::IsNullOrWhiteSpace($doc)) 'docs/project/v03621-local-router-shadow.md'
Add-Check 'local router resource profile document exists' (-not [string]::IsNullOrWhiteSpace($profileDoc)) 'docs/project/v03621-local-router-shadow-profile.md'

foreach ($functionName in @(
    'Resolve-WinsmuxLocalRouterArtifact',
    'ConvertTo-WinsmuxLocalRouterFeatureVector',
    'Invoke-WinsmuxLocalRouterShadow',
    'Measure-WinsmuxLocalRouterShadowProfile',
    'Write-WinsmuxLocalRouterShadowTrace'
)) {
    Add-Check "shadow script exposes $functionName" ($shadow -match "function\s+$([regex]::Escape($functionName))\b") 'winsmux-core/scripts/local-router-shadow.ps1'
}

foreach ($token in @(
    'winsmux-local-router-shadow-v03621',
    'shadow_only',
    'provider_calls_allowed',
    'auto_update_allowed',
    'raw_prompt_storage_allowed',
    'weights_sha256',
    'Apache-2.0 AND MIT'
)) {
    Add-Check "manifest records $token" ($manifestText -match [regex]::Escape($token)) 'winsmux-core/router/local-small-router-v03621.manifest.json'
}

try {
    $manifest = $manifestText | ConvertFrom-Json
    $weightsPath = Join-Path (Join-Path $repoRoot 'winsmux-core/router') ([string]$manifest.weights_path)
    $actualWeightsHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $weightsPath).Hash.ToLowerInvariant()
    Add-Check 'manifest weights hash matches checked artifact' ($actualWeightsHash -eq [string]$manifest.weights_sha256) 'winsmux-core/router/local-small-router-v03621.weights.json'
    Add-Check 'manifest forbids provider calls' (-not [bool]$manifest.provider_calls_allowed) 'winsmux-core/router/local-small-router-v03621.manifest.json'
    Add-Check 'manifest forbids automatic updates' (-not [bool]$manifest.auto_update_allowed) 'winsmux-core/router/local-small-router-v03621.manifest.json'
    Add-Check 'manifest forbids raw prompt storage' (-not [bool]$manifest.raw_prompt_storage_allowed) 'winsmux-core/router/local-small-router-v03621.manifest.json'
} catch {
    Add-Check 'manifest parses and verifies hash' $false $_.Exception.Message
}

foreach ($token in @(
    'slot_logits',
    'role_logits',
    'availability_mask',
    'fallback_required',
    'deterministic_fallback',
    'shadow_proposal_only',
    'privacy_safe_route_state_projection'
)) {
    Add-Check "shadow script records $token" ($shadow -match [regex]::Escape($token)) 'winsmux-core/scripts/local-router-shadow.ps1'
}

foreach ($forbidden in @(
    'Invoke-RestMethod',
    'Invoke-WebRequest',
    'Start-Process',
    'OPENROUTER_API_KEY',
    'ANTHROPIC_API_KEY',
    'provider_request_id'
)) {
    Add-Check "shadow path does not call or store $forbidden" (($shadow + $manifestText + $weightsText + $doc + $profileDoc) -notmatch [regex]::Escape($forbidden)) 'winsmux-core/scripts/local-router-shadow.ps1'
}

foreach ($taskId in @('TASK-603', 'TASK-604', 'TASK-605', 'TASK-606', 'TASK-607', 'TASK-608', 'TASK-609')) {
    Add-Check "design document maps $taskId" ($doc -match [regex]::Escape($taskId)) 'docs/project/v03621-local-router-shadow.md'
}

foreach ($token in @(
    'Shadow Mode only',
    'manual dispatch remains the user-facing path',
    'artifact hash',
    'availability mask',
    'confidence',
    'deterministic fallback',
    'no provider calls',
    'no raw prompt storage'
)) {
    Add-Check "design document records $token" ($doc -match [regex]::Escape($token)) 'docs/project/v03621-local-router-shadow.md'
}

foreach ($token in @(
    'provider calls',
    'GPU required',
    'raw prompt stored',
    'workspace writes',
    'privacy boundary'
)) {
    Add-Check "resource profile records $token" ($profileDoc -match [regex]::Escape($token)) 'docs/project/v03621-local-router-shadow-profile.md'
}

foreach ($token in @(
    'LOCAL_ROUTER_SHADOW_PROPOSAL_STORAGE_KEY',
    'readLocalRouterShadowProposal',
    'normalizeLocalRouterShadowNumber',
    'formatLocalRouterShadowPercent',
    'renderLocalRouterShadowProposal',
    'Shadow proposal',
    'shadow-proposal'
)) {
    Add-Check "desktop UI includes $token" (($appMain + $appStyles) -match [regex]::Escape($token)) 'winsmux-app/src/main.ts'
}

Add-Check 'CI runs v0.36.21 router shadow tests' ($workflow -match 'V03621LocalRouterShadow\.Tests\.ps1') '.github/workflows/test.yml'
Add-Check 'pre-commit whitelist allows v0.36.21 gate script' ($whitelist -match [regex]::Escape('scripts/test-v03621-local-router-shadow.ps1')) '.githooks/pre-commit-whitelist.ps1'
Add-Check 'pre-commit whitelist allows v0.36.21 tests' ($whitelist -match [regex]::Escape('tests/V03621LocalRouterShadow.Tests.ps1')) '.githooks/pre-commit-whitelist.ps1'
Add-Check 'pre-commit whitelist allows local router artifact directory' ($whitelist -match [regex]::Escape('winsmux-core/router/**')) '.githooks/pre-commit-whitelist.ps1'
Add-Check 'pre-commit whitelist allows v0.36.21 documents' ($whitelist -match [regex]::Escape('docs/project/v03621-local-router-shadow.md')) '.githooks/pre-commit-whitelist.ps1'

$failed = @($checks | Where-Object { -not $_.pass })
$result = [ordered]@{
    gate_id      = 'v03621-local-router-shadow'
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
