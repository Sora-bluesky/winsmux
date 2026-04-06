#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet("PASS", "FAIL")]
    [string]$Status = "PASS",
    [string]$Reason = "",
    [string]$Branch,
    [string]$ProjectDir = (Get-Location).Path,
    [string]$ReviewerLabel = 'reviewer-1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Branch)) {
    $Branch = (git branch --show-current 2>&1).Trim()
}

$stateDir = Join-Path $ProjectDir '.winsmux'
$statePath = Join-Path $stateDir 'review-state.json'

if (-not (Test-Path $stateDir -PathType Container)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

$state = @{}
if (Test-Path $statePath -PathType Leaf) {
    try {
        $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
        foreach ($prop in $parsed.PSObject.Properties) {
            $state[$prop.Name] = $prop.Value
        }
    } catch {}
}

$state[$Branch] = [PSCustomObject]@{
    status = $Status
    reason = $Reason
    reviewer = $ReviewerLabel
    timestamp = (Get-Date -Format 'o')
    branch = $Branch
}

$state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
Write-Host "[review-approve] Branch '$Branch' marked as $Status by $ReviewerLabel" -ForegroundColor Green
