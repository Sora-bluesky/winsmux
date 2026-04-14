[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SessionName,
    [string]$WinsmuxPath = '',
    [switch]$AttachOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($WinsmuxPath)) {
    $WinsmuxPath = Get-Command 'winsmux' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
}

if ([string]::IsNullOrWhiteSpace($WinsmuxPath)) {
    throw 'winsmux executable not found for orchestra bootstrap.'
}

& $WinsmuxPath 'has-session' '-t' $SessionName 1>$null 2>$null
$sessionExists = ($LASTEXITCODE -eq 0)

if ($sessionExists) {
    & $WinsmuxPath 'attach-session' '-t' $SessionName
    exit $LASTEXITCODE
}

if ($AttachOnly) {
    throw "winsmux session '$SessionName' was not found for UI attach."
}

& $WinsmuxPath 'new-session' '-s' $SessionName
exit $LASTEXITCODE
