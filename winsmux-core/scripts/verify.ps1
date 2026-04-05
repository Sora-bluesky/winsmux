#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PRNumber,
    [string]$ProjectDir = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$checks = @()
$allPassed = $true

# Check 1: Pester tests
Write-Host "[verify] Running Pester tests..." -ForegroundColor Cyan
try {
    $testDir = Join-Path $ProjectDir 'tests'
    if (Test-Path $testDir -PathType Container) {
        $pesterResult = Invoke-Pester -Path $testDir -Output Minimal -PassThru
        if ($pesterResult.FailedCount -eq 0) {
            $checks += [PSCustomObject]@{ Name = 'Pester'; Status = 'PASS'; Detail = "$($pesterResult.PassedCount) passed" }
        } else {
            $checks += [PSCustomObject]@{ Name = 'Pester'; Status = 'FAIL'; Detail = "$($pesterResult.FailedCount) failed" }
            $allPassed = $false
        }
    } else {
        $checks += [PSCustomObject]@{ Name = 'Pester'; Status = 'SKIP'; Detail = 'No tests/ directory' }
    }
} catch {
    $checks += [PSCustomObject]@{ Name = 'Pester'; Status = 'FAIL'; Detail = $_.Exception.Message }
    $allPassed = $false
}

# Check 2: Working tree clean
$gitStatus = git status --porcelain 2>&1
if ([string]::IsNullOrWhiteSpace($gitStatus)) {
    $checks += [PSCustomObject]@{ Name = 'Clean worktree'; Status = 'PASS'; Detail = '' }
} else {
    $uncommitted = ($gitStatus -split "`n").Count
    $checks += [PSCustomObject]@{ Name = 'Clean worktree'; Status = 'FAIL'; Detail = "$uncommitted uncommitted changes" }
    $allPassed = $false
}

# Check 3: Branch is up to date with remote
try {
    git fetch origin main --quiet 2>&1 | Out-Null
    $behind = git rev-list --count HEAD..origin/main 2>&1
    if ([int]$behind -eq 0) {
        $checks += [PSCustomObject]@{ Name = 'Up to date'; Status = 'PASS'; Detail = '' }
    } else {
        $checks += [PSCustomObject]@{ Name = 'Up to date'; Status = 'FAIL'; Detail = "$behind commits behind origin/main" }
        $allPassed = $false
    }
} catch {
    $checks += [PSCustomObject]@{ Name = 'Up to date'; Status = 'SKIP'; Detail = 'fetch failed' }
}

# Check 4: PR CI status
try {
    $ciOutput = gh pr checks $PRNumber --json name,state 2>&1
    $ciChecks = $ciOutput | ConvertFrom-Json
    $failedCI = @($ciChecks | Where-Object { $_.state -ne 'SUCCESS' -and $_.state -ne 'SKIPPED' })
    if ($failedCI.Count -eq 0) {
        $checks += [PSCustomObject]@{ Name = 'CI checks'; Status = 'PASS'; Detail = "$($ciChecks.Count) checks passed" }
    } else {
        $checks += [PSCustomObject]@{ Name = 'CI checks'; Status = 'FAIL'; Detail = "$($failedCI.Count) checks failed" }
        $allPassed = $false
    }
} catch {
    $checks += [PSCustomObject]@{ Name = 'CI checks'; Status = 'FAIL'; Detail = 'gh command failed' }
    $allPassed = $false
}

# Output results
Write-Host ""
Write-Host "[verify] Results:" -ForegroundColor Cyan
foreach ($check in $checks) {
    $color = switch ($check.Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        default { 'Gray' }
    }
    $detail = if ([string]::IsNullOrWhiteSpace($check.Detail)) { '' } else { " ($($check.Detail))" }
    Write-Host "  [$($check.Status)] $($check.Name)$detail" -ForegroundColor $color
}

Write-Host ""
if ($allPassed) {
    Write-Host "[verify] All checks passed. Safe to merge." -ForegroundColor Green
    exit 0
} else {
    Write-Host "[verify] Some checks failed. Fix before merging." -ForegroundColor Red
    exit 1
}
