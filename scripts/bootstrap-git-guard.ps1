[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$hooksPath = Join-Path $repoRoot '.githooks'

if (-not (Test-Path -LiteralPath $hooksPath -PathType Container)) {
    throw "Missing hooks directory: $hooksPath"
}

git config core.hooksPath $hooksPath
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to configure core.hooksPath.'
}

Write-Output "Configured core.hooksPath -> $hooksPath"
