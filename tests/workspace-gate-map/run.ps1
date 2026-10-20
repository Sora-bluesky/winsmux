param(
    [string]$Ref = 'HEAD',
    [string]$SummaryPath = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$mapPath = Join-Path $PSScriptRoot 'gate-map.json'
$gateMap = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50
$node = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$failures = [Collections.Generic.List[string]]::new()

function Read-GitBytes([string[]]$GitArguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new('git')
    foreach ($item in @('-C', $repo) + $GitArguments) { $startInfo.ArgumentList.Add($item) }
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($startInfo)
    $buffer = [IO.MemoryStream]::new()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardOutput.BaseStream.CopyTo($buffer)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw ("git {0} failed: {1}" -f ($GitArguments -join ' '), $stderrTask.Result) }
    return $buffer.ToArray()
}
function Get-Sha256Hex([byte[]]$Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

$mapLines = @(& $node (Join-Path $PSScriptRoot 'check-map.mjs') --ref $Ref 2>&1 | ForEach-Object { "$_" })
$mapExit = $LASTEXITCODE
$mapSummary = $null
try { $mapSummary = ($mapLines -join "`n") | ConvertFrom-Json -Depth 20 } catch { $failures.Add('check-map printed no JSON summary') }
if ($mapExit -ne 0) { $failures.Add("check-map exited $mapExit") }

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('winsmux-gate-map-' + [Guid]::NewGuid().ToString('N'))
$replay = $null
try {
    $inputs = [Collections.Generic.List[object]]::new()
    foreach ($pin in $gateMap.pins) {
        $bytes = Read-GitBytes @('cat-file', 'blob', [string]$pin.blob)
        if ($bytes.Length -ne [int]$pin.bytes -or (Get-Sha256Hex $bytes) -cne [string]$pin.sha256) {
            $failures.Add("pinned blob differs: $($pin.path)")
        }
        $inputs.Add(@{ Path = [string]$pin.path; Bytes = $bytes })
    }
    # The threat model replay checks the candidate's injection categories, not the c34d6d9b^ ones.
    $patternsPath = '.claude/patterns/injection-patterns.json'
    $inputs.Add(@{ Path = $patternsPath; Bytes = (Read-GitBytes @('show', "${Ref}:$patternsPath")) })
    foreach ($item in $inputs) {
        $destination = Join-Path $fixtureRoot $item.Path
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        [IO.File]::WriteAllBytes($destination, $item.Bytes)
    }

    Import-Module Pester -RequiredVersion 5.7.1 -ErrorAction Stop
    $configuration = New-PesterConfiguration
    $configuration.Run.Container = New-PesterContainer -Path (Join-Path $PSScriptRoot 'preserved-contracts.test.ps1') -Data @{ FixtureRoot = $fixtureRoot }
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    $replay = Invoke-Pester -Configuration $configuration
    $expected = @($gateMap.replays).Count
    if ($replay.FailedCount -ne 0) { $failures.Add("replay failed $($replay.FailedCount)") }
    if ($replay.SkippedCount -ne 0 -or $replay.NotRunCount -ne 0) { $failures.Add("replay skipped $($replay.SkippedCount) not-run $($replay.NotRunCount)") }
    if ($replay.PassedCount -ne $expected) { $failures.Add("replay passed $($replay.PassedCount) of $expected") }
    if (@($replay.Containers | Where-Object { $_.Result -ne 'Passed' }).Count -ne 0) { $failures.Add('replay container did not pass') }
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

$summary = [ordered]@{
    ref = $Ref
    map = $mapSummary
    replay = if ($null -eq $replay) { $null } else { [ordered]@{ passed = $replay.PassedCount; failed = $replay.FailedCount; skipped = $replay.SkippedCount; not_run = $replay.NotRunCount } }
    failures = @($failures) + @(if ($null -ne $mapSummary) { @($mapSummary.failures) })
}
$json = $summary | ConvertTo-Json -Depth 20
Write-Output $json
if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($SummaryPath), $json + "`n", [Text.UTF8Encoding]::new($false))
}
if (@($summary.failures).Count -gt 0) { exit 1 }
exit 0
