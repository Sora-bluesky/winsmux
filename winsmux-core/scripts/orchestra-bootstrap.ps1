[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SessionName,
    [string]$WinsmuxPath = '',
    [switch]$AttachOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'settings.ps1')

if ([string]::IsNullOrWhiteSpace($WinsmuxPath)) {
    $WinsmuxPath = Get-Command 'winsmux' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
}

if ([string]::IsNullOrWhiteSpace($WinsmuxPath)) {
    throw 'winsmux executable not found for orchestra bootstrap.'
}

Invoke-WinsmuxBridgeCommand -WinsmuxBin $WinsmuxPath -Arguments @('has-session', '-t', $SessionName) 1>$null 2>$null
$sessionExists = ($LASTEXITCODE -eq 0)

if ($sessionExists) {
    Invoke-WinsmuxBridgeCommand -WinsmuxBin $WinsmuxPath -Arguments @('attach-session', '-t', $SessionName)
    exit $LASTEXITCODE
}

if ($AttachOnly) {
    throw "winsmux session '$SessionName' was not found for UI attach."
}

Invoke-WinsmuxBridgeCommand -WinsmuxBin $WinsmuxPath -Arguments @('new-session', '-s', $SessionName)
exit $LASTEXITCODE
