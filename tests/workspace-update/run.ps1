param([string]$SummaryPath = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
    $SummaryPath = Join-Path $repo ('.evidence/workspace-update/gates-' + [Guid]::NewGuid().ToString('N') + '.json')
}
$SummaryPath = [IO.Path]::GetFullPath($SummaryPath)
$pwsh = (Get-Process -Id $PID).Path
$node = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

function Get-NodeTestCount([string[]]$Lines) {
    $counts = @($Lines | ForEach-Object { if ($_ -match '^\S+\s+tests\s+(\d+)\s*$') { [int]$Matches[1] } })
    if ($counts.Count -ne 1) { return 'node --test summary line not found exactly once' }
    if ($counts[0] -eq 0) { return 'node --test reported 0 tests' }
    return ''
}
function Get-LifecycleSourceCaseCount([string[]]$Lines) {
    $last = @($Lines | Where-Object { $_.TrimStart().StartsWith('{') })
    if ($last.Count -eq 0) { return 'install-lifecycle-source printed no JSON summary' }
    $summary = $last[-1] | ConvertFrom-Json
    if (([int]$summary.passed + [int]$summary.failed) -eq 0) { return 'install-lifecycle-source reported 0 cases' }
    return ''
}

$gates = @(
    @{ Name = 'install-lifecycle'; File = $pwsh; Arguments = @('-NoLogo', '-NoProfile', '-File', 'tests/workspace-update/install-lifecycle.test.ps1'); Check = $null }
    @{ Name = 'install-lifecycle-source'; File = $pwsh; Arguments = @('-NoLogo', '-NoProfile', '-File', 'tests/workspace-package/install-lifecycle-source.test.ps1'); Check = ${function:Get-LifecycleSourceCaseCount} }
    @{ Name = 'install-generation'; File = $pwsh; Arguments = @('-NoLogo', '-NoProfile', '-File', 'tests/workspace-package/install-generation.test.ps1'); Check = $null }
    @{ Name = 'install-transport'; File = $node; Arguments = @('--test', 'tests/workspace-package/install-transport.test.mjs'); Check = ${function:Get-NodeTestCount} }
)

$results = [Collections.Generic.List[object]]::new()
Push-Location -LiteralPath $repo
try {
    foreach ($gate in $gates) {
        $lines = @(& $gate.File @($gate.Arguments) 2>&1 | ForEach-Object { $line = "$_"; Write-Host $line; $line })
        $exitCode = $LASTEXITCODE
        $problem = if ($gate.Check) { & $gate.Check $lines } else { '' }
        $results.Add([ordered]@{ name = $gate.Name; exit_code = $exitCode; problem = $problem })
    }
} finally {
    Pop-Location
}

$failed = @($results | Where-Object { $_.exit_code -ne 0 -or $_.problem })
$summary = ConvertTo-Json -Compress -Depth 4 ([ordered]@{
        schema = 'winsmux-workspace-update-gates/v1'; installer_e2e = 'not_run: runs in .github/workflows/test.yml'
        passed = $results.Count - $failed.Count; failed = $failed.Count; gates = $results.ToArray() })
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($SummaryPath))
[IO.File]::WriteAllText($SummaryPath, $summary + "`n", [Text.UTF8Encoding]::new($false))
Write-Output $summary
if ($failed.Count) { exit 1 }
