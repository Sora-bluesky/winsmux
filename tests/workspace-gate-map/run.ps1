# Runs check-map.mjs against a tree-ish, proves the committed gate-map.json is what build-map.mjs regenerates
# from that tree, and records the result.
# Usage: pwsh -NoProfile -File run.ps1 [-Ref <tree-ish>] [-SummaryPath <file>] [-Release] [-VaultRoot <dir>]
# check-map and build-map read gate-map.json and every anchor from -Ref, so this script first proves that the
# scripts it is about to execute are byte-identical to the ones stored at -Ref. -Release is the form release
# evidence is taken in: it requires -VaultRoot (or WINSMUX_GATE_MAP_VAULT) and fails unless every preserved
# file and the preservation basis document match the pins. Without -Release the pins are still verified
# against git blobs; the vault is compared only when a root is given, and its absence is reported, not failed.
param(
    [string]$Ref = 'HEAD',
    [string]$SummaryPath = '',
    [switch]$Release,
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
# A checkout with core.autocrlf rewrites line endings; the identity check compares the scripts' text, not their newlines.
function Get-TextSha256Hex([byte[]]$Bytes) {
    return Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes([Text.Encoding]::UTF8.GetString($Bytes).Replace("`r`n", "`n")))
}

$scripts = @('tests/workspace-gate-map/check-map.mjs', 'tests/workspace-gate-map/build-map.mjs', 'tests/workspace-gate-map/dispositions.mjs')
$scriptDigests = [ordered]@{}
foreach ($script in $scripts) {
    $atRef = Get-TextSha256Hex (Read-GitBytes @('show', "${Ref}:$script"))
    $inTree = Get-TextSha256Hex ([IO.File]::ReadAllBytes((Join-Path $repo $script)))
    $scriptDigests[$script] = $inTree
    if ($atRef -cne $inTree) { $failures.Add("$script in the working tree differs from ${Ref}:$script") }
}

$mapSummary = $null
$rebuild = $null
if ($failures.Count -eq 0) {
    $mapLines = @(& $node (Join-Path $repo 'tests/workspace-gate-map/check-map.mjs') --ref $Ref 2>&1 | ForEach-Object { "$_" })
    $mapExit = $LASTEXITCODE
    try { $mapSummary = ($mapLines -join "`n") | ConvertFrom-Json -Depth 20 } catch { $failures.Add('check-map printed no JSON summary') }
    if ($mapExit -ne 0) { $failures.Add("check-map exited $mapExit") }

    $rebuildLines = @(& $node (Join-Path $repo 'tests/workspace-gate-map/build-map.mjs') --ref $Ref --check 2>&1 | ForEach-Object { "$_" })
    $rebuildExit = $LASTEXITCODE
    $rebuild = [ordered]@{ exit = $rebuildExit; output = ($rebuildLines -join "`n") }
    if ($rebuildExit -ne 0) { $failures.Add("build-map --check exited ${rebuildExit}: the committed gate-map.json is not what build-map regenerates at $Ref") }
}

$gateMap = [Text.Encoding]::UTF8.GetString((Read-GitBytes @('show', "${Ref}:tests/workspace-gate-map/gate-map.json"))) | ConvertFrom-Json -Depth 50
if ([string]::IsNullOrWhiteSpace($VaultRoot) -and -not [string]::IsNullOrWhiteSpace($env:WINSMUX_GATE_MAP_VAULT)) { $VaultRoot = $env:WINSMUX_GATE_MAP_VAULT }
$vault = [ordered]@{ root = $VaultRoot; status = 'absent'; files = @() }
if ($Release -and [string]::IsNullOrWhiteSpace($VaultRoot)) { $failures.Add('-Release requires -VaultRoot or WINSMUX_GATE_MAP_VAULT') }
if (-not [string]::IsNullOrWhiteSpace($VaultRoot)) {
    $vault.status = 'verified'
    $files = [Collections.Generic.List[object]]::new()
    $expected = [Collections.Generic.List[object]]::new()
    foreach ($pin in $gateMap.pins) { $expected.Add([ordered]@{ path = [string]$pin.path; vault_path = [string]$pin.vault_path; bytes = [int]$pin.bytes; sha256 = [string]$pin.sha256 }) }
    if ($null -ne $gateMap.preservation_basis) {
        $basis = $gateMap.preservation_basis
        $expected.Add([ordered]@{ path = 'preservation_basis'; vault_path = [string]$basis.vault_path; bytes = [int]$basis.bytes; sha256 = [string]$basis.sha256 })
    }
    foreach ($item in $expected) {
        $file = Join-Path $VaultRoot $item.vault_path
        $state = 'missing'
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $bytes = [IO.File]::ReadAllBytes($file)
            $state = if ($bytes.Length -eq $item.bytes -and (Get-Sha256Hex $bytes) -ceq $item.sha256) { 'same' } else { 'differs' }
        }
        if ($state -ne 'same') { $vault.status = 'differs'; $failures.Add("preserved bytes ${state}: $($item.vault_path)") }
        $files.Add([ordered]@{ path = $item.path; vault_path = $item.vault_path; state = $state })
    }
    $vault.files = $files.ToArray()
}

$summary = [ordered]@{
    ref = $Ref
    release = [bool]$Release
    script_sha256 = $scriptDigests
    map = $mapSummary
    rebuild = $rebuild
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
