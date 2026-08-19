param(
    [switch]$Release
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$srcTauriDir = Split-Path -Parent $PSScriptRoot
$appDir = Split-Path -Parent $srcTauriDir
$repoRoot = Split-Path -Parent $appDir
$binariesDir = Join-Path $srcTauriDir 'binaries'
New-Item -ItemType Directory -Force -Path $binariesDir | Out-Null

$cargoArgs = @('build', '-p', 'winsmux')
if ($Release) {
    $cargoArgs += '--release'
}

& cargo @cargoArgs
if ($LASTEXITCODE -ne 0) {
    throw "cargo build -p winsmux failed with exit $LASTEXITCODE"
}

$profile = if ($Release) { 'release' } else { 'debug' }
$targetRoot = if (-not [string]::IsNullOrWhiteSpace($env:CARGO_TARGET_DIR)) {
    $env:CARGO_TARGET_DIR
} else {
    Join-Path $repoRoot 'target'
}
$source = Join-Path $targetRoot $profile 'winsmux.exe'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "companion CLI was not built: $source"
}

$hostTriple = (& rustc -vV | Select-String -Pattern '^host: ').ToString().Substring(6).Trim()
if ([string]::IsNullOrWhiteSpace($hostTriple)) {
    throw 'rustc host triple was not available'
}

$destination = Join-Path $binariesDir ("winsmux-{0}.exe" -f $hostTriple)
Copy-Item -LiteralPath $source -Destination $destination -Force

# Bridge scripts are bundled from the source tree via tauri.conf.json
# (`scripts/winsmux-core.ps1` + `winsmux-core/scripts/*`) so $PSScriptRoot\..\winsmux-core\scripts
# still resolves in packaged installs. Do not copy a flat sibling entry next to the sidecar.
$legacyFlat = Join-Path $binariesDir 'winsmux-core.ps1'
if (Test-Path -LiteralPath $legacyFlat -PathType Leaf) {
    Remove-Item -LiteralPath $legacyFlat -Force
}

Write-Host "prepared companion sidecar $destination"
