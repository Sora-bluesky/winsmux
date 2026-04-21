[CmdletBinding()]
param(
    [string]$Source = '.',

    [string]$LogOpts = '--all'
)

$ErrorActionPreference = 'Stop'

$gitleaks = Get-Command gitleaks -ErrorAction SilentlyContinue
if ($null -eq $gitleaks) {
    throw 'gitleaks is required for full-history secret scanning. Install gitleaks and retry.'
}

$sourcePath = (Resolve-Path -LiteralPath $Source).Path

& $gitleaks.Source detect --source $sourcePath --log-opts $LogOpts --redact --exit-code 1
if ($LASTEXITCODE -ne 0) {
    throw "gitleaks full-history scan failed with exit code $LASTEXITCODE."
}
