param(
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'test-v03619-repo-audit: failed to determine repository root.'
}

function Get-RepoContent {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }
    return Get-Content -LiteralPath $path -Raw
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

$testWorkflow = Get-RepoContent '.github/workflows/test.yml'
$releaseNpm = Get-RepoContent '.github/workflows/release-npm.yml'
$releaseDesktop = Get-RepoContent '.github/workflows/release-desktop.yml'
$releaseCore = Get-RepoContent '.github/workflows/release-core.yml'
$buildCore = Get-RepoContent '.github/workflows/build-core.yml'
$buildDesktop = Get-RepoContent '.github/workflows/build-desktop.yml'
$installEn = Get-RepoContent 'docs/installation.md'
$installJa = Get-RepoContent 'docs/installation.ja.md'
$mainTs = Get-RepoContent 'winsmux-app/src/main.ts'
$modelCapabilities = Get-RepoContent 'winsmux-app/src/modelCapabilities.ts'
$settings = Get-RepoContent 'winsmux-core/scripts/settings.ps1'
$auditDoc = Get-RepoContent 'docs/project/v03619-repo-audit.md'
$whitelist = Get-RepoContent '.githooks/pre-commit-whitelist.ps1'

Add-Check 'audit document exists' (-not [string]::IsNullOrWhiteSpace($auditDoc)) 'docs/project/v03619-repo-audit.md'
foreach ($findingId in @('A-001', 'A-002', 'CI-01', 'CI-05', 'C2-VULN-001', 'C2-ASSET-002', 'C2-DOC-003')) {
    Add-Check "audit document records $findingId" ($auditDoc -match [regex]::Escape($findingId)) 'docs/project/v03619-repo-audit.md'
}
foreach ($deferredId in @('A-003', 'CI-03', 'CI-04', 'CI-06', 'TST-07', 'WIN-08')) {
    Add-Check "audit document defers $deferredId" ($auditDoc -match [regex]::Escape($deferredId)) 'docs/project/v03619-repo-audit.md'
}

Add-Check 'Pester matrix guards bridge file union coverage' ($testWorkflow -match 'assert-pester-shard-coverage\.ps1' -and $testWorkflow -match 'Bridge shard coverage gate failed') '.github/workflows/test.yml'
Add-Check 'Pester matrix executes resolved files without FullName filters' ($testWorkflow -match '\$config\.Run\.Path = \$resolvedPaths' -and $testWorkflow -notmatch '\$config\.Filter\.FullName') '.github/workflows/test.yml'
Add-Check 'Pester matrix includes v0.36.19 audit tests' ($testWorkflow -match 'V03619RepoAudit\.Tests\.ps1') '.github/workflows/test.yml'
foreach ($workflow in @(
    @{ name = 'test'; content = $testWorkflow },
    @{ name = 'release-npm'; content = $releaseNpm },
    @{ name = 'release-desktop'; content = $releaseDesktop },
    @{ name = 'release-core'; content = $releaseCore },
    @{ name = 'build-core'; content = $buildCore },
    @{ name = 'build-desktop'; content = $buildDesktop }
)) {
    Add-Check "$($workflow.name) workflow has explicit timeout" ($workflow.content -match 'timeout-minutes:') ".github/workflows/$($workflow.name).yml"
}

Add-Check 'npm release rejects placeholder staged version' ($releaseNpm -match '0\.0\.0-development' -and $releaseNpm -match 'Staged npm package still has the development placeholder version') '.github/workflows/release-npm.yml'
Add-Check 'npm release asserts staged version equals requested version' ($releaseNpm -match 'does not match requested version') '.github/workflows/release-npm.yml'
Add-Check 'desktop release validates setup filename' ($releaseDesktop -match 'winsmux_\$\{version\}_x64-setup\.exe' -and $releaseDesktop -match 'Required desktop release asset') '.github/workflows/release-desktop.yml'
Add-Check 'desktop release validates MSI filename' ($releaseDesktop -match 'winsmux_\$\{version\}_x64_en-US\.msi' -and $releaseDesktop -match 'Required desktop release asset') '.github/workflows/release-desktop.yml'
Add-Check 'core release publishes arm64 portable binary' ($releaseCore -match 'winsmux-arm64\.exe') '.github/workflows/release-core.yml'
Add-Check 'English install docs mention arm64 fallback' ($installEn -match 'winsmux-arm64\.exe') 'docs/installation.md'
Add-Check 'Japanese install docs mention arm64 fallback' ($installJa -match 'winsmux-arm64\.exe') 'docs/installation.ja.md'

Add-Check 'desktop RuntimeProviderId excludes retired standalone gemini provider' ($mainTs -notmatch 'type RuntimeProviderId = [^\r\n]*"gemini"') 'winsmux-app/src/main.ts'
Add-Check 'desktop runtime access note excludes standalone Gemini provider branch' ($mainTs -notmatch 'preference\.provider === "gemini"') 'winsmux-app/src/main.ts'
Add-Check 'desktop Claude reasoning order treats Ultra as highest' ($mainTs -match 'claude:\s*\["provider-default",\s*"low",\s*"medium",\s*"high",\s*"max",\s*"xhigh"\]') 'winsmux-app/src/main.ts'
Add-Check 'capability registry has no standalone gemini provider id' ($modelCapabilities -notmatch 'id:\s*"gemini"') 'winsmux-app/src/modelCapabilities.ts'
Add-Check 'reasoning effort validators reject none and minimal' ($settings -notmatch "reasoning_effort[^\r\n]+none" -and $settings -notmatch "reasoning_effort[^\r\n]+minimal" -and $settings -notmatch "reasoning_efforts[^\r\n]+none" -and $settings -notmatch "reasoning_efforts[^\r\n]+minimal") 'winsmux-core/scripts/settings.ps1'

foreach ($path in @('docs/project/v03619-repo-audit.md', 'scripts/test-v03619-repo-audit.ps1', 'tests/V03619RepoAudit.Tests.ps1')) {
    Add-Check "pre-commit whitelist allows $path" ($whitelist -match [regex]::Escape($path)) '.githooks/pre-commit-whitelist.ps1'
}

$failed = @($checks | Where-Object { -not $_.pass })
$result = [ordered]@{
    gate_id      = 'v03619-repo-audit'
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
