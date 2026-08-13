#Requires -Version 7.0
<#
.SYNOPSIS
  TASK-800 shared operator full-test leaf for Builder / Post-Review entries.
.DESCRIPTION
  Top-level launches scripts/run-tests.ps1 exactly once (or WINSMUX_TASK800_RUNNER_PATH override for contract probes).
  Does not merge, discover, or invoke Pester directly. Exit code is passthrough.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResultsDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$override = [string]$env:WINSMUX_TASK800_RUNNER_PATH
$runner = $null
$useOverride = $false

if (-not [string]::IsNullOrWhiteSpace($override)) {
    $runner = $override
    $useOverride = $true
}
else {
    $runner = Join-Path -Path $PSScriptRoot -ChildPath 'run-tests.ps1'
}

if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    Write-Host ("TASK800_RUNNER_MISSING: {0}" -f $runner)
    [System.Environment]::Exit(2)
}

# Override stubs used by contract probes accept no -ResultsDirectory; production runner requires it.
if ($useOverride) {
    & $runner
}
else {
    & $runner -ResultsDirectory $ResultsDirectory
}

$code = $LASTEXITCODE
if ($null -eq $code) { $code = 1 }
[System.Environment]::Exit([int]$code)
