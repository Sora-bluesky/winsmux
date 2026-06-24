[CmdletBinding()]
param(
    [string]$EvidencePath = '.winsmux/evidence/v03617-launch-soak/launch-soak-summary.json',
    [int]$MinimumRuns = 10,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
}

function Resolve-LocalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function ConvertTo-SafeDetail {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $text = $text -replace [regex]::Escape($RepoRoot), '<repo>'
    $text = $text -replace '(?i)[A-Z]:\\[^,"\r\n]+', '<local-path>'
    return $text
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
            detail = (ConvertTo-SafeDetail $Detail)
        }) | Out-Null
}

function Get-CollectionCount {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return 0
    }
    return @($Value).Count
}

$checks = [System.Collections.Generic.List[object]]::new()
$resolvedEvidencePath = Resolve-LocalPath $EvidencePath
$summary = $null

Add-Check 'launch soak summary exists' (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf) $resolvedEvidencePath

if (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf) {
    $summary = Get-Content -LiteralPath $resolvedEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
}

if ($null -ne $summary) {
    $results = @($summary.results)
    Add-Check 'summary reports ok' ([bool]$summary.ok) "ok=$($summary.ok)"
    Add-Check 'minimum run count is met' ([int]$summary.runs -ge $MinimumRuns) "$($summary.runs)/$MinimumRuns"
    Add-Check 'all summary runs passed' ([int]$summary.passed -eq [int]$summary.runs -and [int]$summary.failed -eq 0) "passed=$($summary.passed); failed=$($summary.failed)"
    Add-Check 'per-run evidence count matches run count' ($results.Count -eq [int]$summary.runs) "$($results.Count)/$($summary.runs)"

    $runNumbers = @($results | ForEach-Object { [int]$_.run })
    $expectedRunNumbers = 1..([Math]::Max(1, [int]$summary.runs))
    $missingRunNumbers = @($expectedRunNumbers | Where-Object { $runNumbers -notcontains $_ })
    Add-Check 'run numbers are continuous from one' ($missingRunNumbers.Count -eq 0) (($missingRunNumbers -join ','))

    foreach ($run in $results) {
        $runId = [string]$run.run
        Add-Check "run $runId reports ok" ([bool]$run.ok)
        Add-Check "run $runId has six worker panes" ([int]$run.paneCount -eq 6) "paneCount=$($run.paneCount)"
        Add-Check "run $runId has six visible worker panes" ([int]$run.visiblePaneCount -eq 6) "visiblePaneCount=$($run.visiblePaneCount)"
        Add-Check "run $runId hides worker status by default" ([bool]$run.workerStatusHidden)
        Add-Check "run $runId closes debug port after cleanup" ([bool]$run.portClosedAfterCleanup)
        Add-Check "run $runId leaves zero owned orphan processes" ([int]$run.orphanProcessCount -eq 0) "orphanProcessCount=$($run.orphanProcessCount)"
        Add-Check "run $runId leaves zero stale state files" ([int]$run.stateFileCount -eq 0) "stateFileCount=$($run.stateFileCount)"
        Add-Check "run $runId records no orphan process details" ((Get-CollectionCount $run.orphanProcesses) -eq 0)
        Add-Check "run $runId records no stale state file details" ((Get-CollectionCount $run.stateFiles) -eq 0)
    }
}

$failed = @($checks | Where-Object { -not $_.pass })
$result = [pscustomobject]@{
    version      = 1
    gate_id      = 'v03617-reliability-launch-soak'
    all_pass     = ($failed.Count -eq 0)
    check_count  = $checks.Count
    failed_count = $failed.Count
    evidence     = (ConvertTo-SafeDetail $resolvedEvidencePath)
    minimum_runs = $MinimumRuns
    checks       = @($checks)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 20
} else {
    foreach ($check in $checks) {
        $status = if ($check.pass) { 'PASS' } else { 'FAIL' }
        Write-Host ("[{0}] {1} {2}" -f $status, $check.name, $check.detail)
    }
}

if (-not $result.all_pass) {
    exit 1
}
