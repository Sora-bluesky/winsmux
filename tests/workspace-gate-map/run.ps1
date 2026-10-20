# Runs check-map.mjs against a tree-ish and records the result.
# Usage: pwsh -NoProfile -File run.ps1 [-Ref <tree-ish>] [-SummaryPath <file>] [-VaultRoot <dir>]
# check-map reads gate-map.json and every anchor from -Ref, so this script first proves that the
# check-map.mjs it is about to execute is byte-identical to the one stored at -Ref. -VaultRoot (default:
# .references/operator-plans/rebuild-v0380-20260906/task882-gate-map when present) compares the
# preserved original bytes with the pins; when the root is absent the summary says so instead of passing.
param(
    [string]$Ref = 'HEAD',
    [string]$SummaryPath = '',
    [string]$VaultRoot = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
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

$checker = 'tests/workspace-gate-map/check-map.mjs'
$atRef = Get-Sha256Hex (Read-GitBytes @('show', "${Ref}:$checker"))
$inTree = Get-Sha256Hex ([IO.File]::ReadAllBytes((Join-Path $repo $checker)))
if ($atRef -cne $inTree) { $failures.Add("check-map.mjs in the working tree differs from ${Ref}:$checker") }

$mapSummary = $null
$mapExit = $null
if ($failures.Count -eq 0) {
    $mapLines = @(& $node (Join-Path $repo $checker) --ref $Ref 2>&1 | ForEach-Object { "$_" })
    $mapExit = $LASTEXITCODE
    try { $mapSummary = ($mapLines -join "`n") | ConvertFrom-Json -Depth 20 } catch { $failures.Add('check-map printed no JSON summary') }
    if ($mapExit -ne 0) { $failures.Add("check-map exited $mapExit") }
}

$gateMap = [Text.Encoding]::UTF8.GetString((Read-GitBytes @('show', "${Ref}:tests/workspace-gate-map/gate-map.json"))) | ConvertFrom-Json -Depth 50
if ([string]::IsNullOrWhiteSpace($VaultRoot)) {
    $candidate = Join-Path $repo '.references/operator-plans/rebuild-v0380-20260906/task882-gate-map'
    if (Test-Path -LiteralPath $candidate -PathType Container) { $VaultRoot = $candidate }
}
$vault = [ordered]@{ root = $VaultRoot; status = 'absent'; files = @() }
if (-not [string]::IsNullOrWhiteSpace($VaultRoot)) {
    $vault.status = 'verified'
    $files = [Collections.Generic.List[object]]::new()
    foreach ($pin in $gateMap.pins) {
        $file = Join-Path $VaultRoot ([string]$pin.vault_path)
        $state = 'missing'
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $bytes = [IO.File]::ReadAllBytes($file)
            $state = if ($bytes.Length -eq [int]$pin.bytes -and (Get-Sha256Hex $bytes) -ceq [string]$pin.sha256) { 'same' } else { 'differs' }
        }
        if ($state -ne 'same') { $vault.status = 'differs'; $failures.Add("preserved bytes ${state}: $($pin.vault_path)") }
        $files.Add([ordered]@{ path = [string]$pin.path; vault_path = [string]$pin.vault_path; state = $state })
    }
    $vault.files = $files.ToArray()
}

$summary = [ordered]@{
    ref = $Ref
    checker_sha256 = $inTree
    map = $mapSummary
    vault = $vault
    failures = @($failures) + @(if ($null -ne $mapSummary) { @($mapSummary.failures) })
}
$json = $summary | ConvertTo-Json -Depth 20
Write-Output $json
if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($SummaryPath), $json + "`n", [Text.UTF8Encoding]::new($false))
}
if (@($summary.failures).Count -gt 0) { exit 1 }
exit 0
