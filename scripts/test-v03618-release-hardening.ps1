[CmdletBinding()]
param(
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    $repoRoot = Split-Path $PSScriptRoot -Parent
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-RepoContent {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = Resolve-RepoPath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        return ''
    }
    return Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
}

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Pass,
        [string]$Detail = ''
    )
    $script:checks.Add([pscustomobject]@{
            name   = $Name
            pass   = $Pass
            detail = $Detail
        }) | Out-Null
}

$checks = [System.Collections.Generic.List[object]]::new()

$contract = Get-RepoContent 'docs/project/v03618-release-hardening.md'
$core = Get-RepoContent 'scripts/winsmux-core.ps1'
$teamPipeline = Get-RepoContent 'winsmux-core/scripts/team-pipeline.ps1'
$orchestraStart = Get-RepoContent 'winsmux-core/scripts/orchestra-start.ps1'
$orchestraPreflight = Get-RepoContent 'winsmux-core/scripts/orchestra-preflight.ps1'
$orchestraSmoke = Get-RepoContent 'winsmux-core/scripts/orchestra-smoke.ps1'
$subagentGuard = Get-RepoContent 'scripts/codex-subagent-worktree-guard.ps1'
$publicSurfaceAudit = Get-RepoContent 'scripts/audit-public-surface.ps1'
$workflow = Get-RepoContent '.github/workflows/test.yml'
$desktopBuildWorkflow = Get-RepoContent '.github/workflows/build-desktop.yml'
$versionSurfaceTests = Get-RepoContent 'tests/VersionSurface.Tests.ps1'
$contextMenuE2e = Get-RepoContent 'winsmux-app/scripts/windows-context-menu-e2e.ps1'
$v1ReleaseGate = Get-RepoContent 'docs/project/v1-release-gate.md'

Add-Check 'contract document exists' (-not [string]::IsNullOrWhiteSpace($contract)) 'docs/project/v03618-release-hardening.md'
foreach ($token in @('TASK-596', 'TASK-597', 'TASK-578', 'TASK-616', 'TASK-579', 'claim_level', 'scope_circuit_breaker', 'two-strike retry limit', 'process_contract', 'subagents', 'browser instances', 'temp files')) {
    Add-Check "contract includes $token" ($contract -match [regex]::Escape($token))
}
foreach ($token in @('Medium/Low Finding Disposition', 'fixed and verified', 'defer to v0.36.19', 'defer to v0.36.22', 'Baseline Tauri Installer Smoke', 'winsmux_${VERSION}_x64-setup.exe', 'Release Polish And CI Hygiene', 'least-privilege read permissions', 'post-release smoke', 'branch cleanup')) {
    Add-Check "contract includes release polish requirement $token" ($contract -match [regex]::Escape($token))
}

foreach ($token in @('function Get-RunClaimLevel', 'claim_level', 'loop_control', 'two_strike_limit', 'one_hypothesis_one_change_required', 'scope_circuit_breaker', 'two_strike_retry_limit_reached')) {
    Add-Check "run packet exposes $token" ($core -match [regex]::Escape($token)) 'scripts/winsmux-core.ps1'
}

Add-Check 'team pipeline keeps a two-fix-round default' ($teamPipeline -match '\[int\]\$MaxFixRounds\s*=\s*2') 'winsmux-core/scripts/team-pipeline.ps1'
foreach ($token in @('pipeline.escalate.required', 'VERIFY_BLOCKED', 'VERIFY_PARTIAL', 'VERIFY_FAIL')) {
    Add-Check "team pipeline records $token" ($teamPipeline -match [regex]::Escape($token))
}

foreach ($token in @('Stop-OrchestraBackgroundProcessesFromManifest', 'Start-OrchestraSupervisorJob', '-WindowStyle Hidden', 'Supervisor PID')) {
    Add-Check "orchestra start owns helper lifecycle: $token" ($orchestraStart -match [regex]::Escape($token))
}

foreach ($token in @('Get-AncestorProcessIds', 'protectedIds', 'Test-OrchestraSessionServerProcess', 'Remove-OrchestraSessionServerProcesses', 'Test-OrchestraWarmProcess', 'Remove-OrchestraExcessWarmProcesses', 'SessionName')) {
    Add-Check "orchestra preflight scopes cleanup: $token" ($orchestraPreflight -match [regex]::Escape($token))
}

foreach ($token in @('process_contract', 'background_helpers', 'warm_process_count', 'stale_process_count')) {
    Add-Check "orchestra smoke reports $token" ($orchestraSmoke -match [regex]::Escape($token))
}

foreach ($token in @('shared operator checkout', 'dedicated git worktree', '#666')) {
    Add-Check "subagent worktree guard enforces $token" ($subagentGuard -match [regex]::Escape($token)) 'scripts/codex-subagent-worktree-guard.ps1'
}

foreach ($token in @('browser', 'screenshot', 'recording', 'evidence_surfaces')) {
    Add-Check "team pipeline keeps bounded evidence surface $token" ($teamPipeline -match [regex]::Escape($token)) 'winsmux-core/scripts/team-pipeline.ps1'
}

foreach ($token in @('tracked generated/runtime artifact', 'contributor/runtime', 'logs')) {
    Add-Check "public surface audit excludes unowned runtime output $token" ($publicSurfaceAudit -match [regex]::Escape($token)) 'scripts/audit-public-surface.ps1'
}

Add-Check 'CI runs v0.36.18 release hardening tests' ($workflow -match 'V03618ReleaseHardening\.Tests\.ps1') '.github/workflows/test.yml'
Add-Check 'CI runs subagent worktree guard tests' ($workflow -match 'codex-subagent-worktree-guard\.Tests\.ps1') '.github/workflows/test.yml'
Add-Check 'test workflow uses least privilege read permission' ($workflow -match "(?ms)^permissions:\s*\r?\n\s*contents:\s*read") '.github/workflows/test.yml'
Add-Check 'test workflow cancels duplicate branch runs' ($workflow -match "(?ms)^concurrency:\s*\r?\n\s*group:\s*\$\{\{\s*github\.workflow\s*\}\}-\$\{\{\s*github\.ref\s*\}\}\s*\r?\n\s*cancel-in-progress:\s*true") '.github/workflows/test.yml'
foreach ($token in @('Get-PSRepository -Name PSGallery', 'Register-PSRepository -Default', 'Install-Module Pester', '-Repository PSGallery', 'Start-Sleep -Seconds (5 * $attempt)', 'Import-Module Pester')) {
    Add-Check "test workflow hardens Pester install: $token" ($workflow -match [regex]::Escape($token)) '.github/workflows/test.yml'
}
Add-Check 'desktop build workflow uses least privilege read permission' ($desktopBuildWorkflow -match "(?ms)^permissions:\s*\r?\n\s*contents:\s*read") '.github/workflows/build-desktop.yml'
Add-Check 'desktop build workflow cancels duplicate branch runs' ($desktopBuildWorkflow -match "(?ms)^concurrency:\s*\r?\n\s*group:\s*\$\{\{\s*github\.workflow\s*\}\}-\$\{\{\s*github\.ref\s*\}\}\s*\r?\n\s*cancel-in-progress:\s*true") '.github/workflows/build-desktop.yml'
$coreBuildWorkflow = Get-RepoContent '.github/workflows/build-core.yml'
Add-Check 'core build workflow uses least privilege read permission' ($coreBuildWorkflow -match "(?ms)^permissions:\s*\r?\n\s*contents:\s*read") '.github/workflows/build-core.yml'
Add-Check 'core build workflow cancels duplicate branch runs' ($coreBuildWorkflow -match "(?ms)^concurrency:\s*\r?\n\s*group:\s*\$\{\{\s*github\.workflow\s*\}\}-\$\{\{\s*github\.ref\s*\}\}\s*\r?\n\s*cancel-in-progress:\s*true") '.github/workflows/build-core.yml'

foreach ($token in @('derives desktop installer E2E artifact names from VERSION', 'winsmux_$($script:ProductVersion)_x64-setup.exe')) {
    Add-Check "version surface covers desktop installer artifact: $token" ($versionSurfaceTests -match [regex]::Escape($token)) 'tests/VersionSurface.Tests.ps1'
}
foreach ($token in @('winsmux_$($script:ProductVersion)_x64-setup.exe', '/S', '/D=$installPath', 'uninstall.exe', 'Open with winsmux', 'winsmuxで開く', 'Remove-TestDirectory', 'Restore-DesktopShortcut')) {
    Add-Check "context menu E2E covers installer smoke: $token" ($contextMenuE2e -match [regex]::Escape($token)) 'winsmux-app/scripts/windows-context-menu-e2e.ps1'
}
foreach ($token in @('winsmux_<version>_x64-setup.exe', 'SHA256SUMS-desktop', 'English and Japanese installer UI', 'desktop update path', 'worker-pane child processes', 'Post-release smoke')) {
    Add-Check "release gate documents desktop baseline: $token" ($v1ReleaseGate -match [regex]::Escape($token)) 'docs/project/v1-release-gate.md'
}

$failed = @($checks | Where-Object { -not $_.pass })
$result = [pscustomobject]@{
    version      = 1
    gate_id      = 'v03618-release-hardening'
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
        Write-Host ("[{0}] {1} {2}" -f $status, $check.name, $check.detail)
    }
}

if (-not $result.all_pass) {
    exit 1
}
