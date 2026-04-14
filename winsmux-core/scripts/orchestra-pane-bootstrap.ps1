[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PlanFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $PlanFile)) {
    throw "Orchestra pane bootstrap plan not found: $PlanFile"
}

$plan = Get-Content -LiteralPath $PlanFile -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 8

if ([string]::IsNullOrWhiteSpace([string]$plan.launch_dir)) {
    throw "launch_dir missing in orchestra pane bootstrap plan: $PlanFile"
}

if ([string]::IsNullOrWhiteSpace([string]$plan.launch_command)) {
    throw "launch_command missing in orchestra pane bootstrap plan: $PlanFile"
}

$role = [string]$plan.role
$label = [string]$plan.label
$model = [string]$plan.model
$launchDir = [string]$plan.launch_dir
$launchCommand = [string]$plan.launch_command
$environment = $plan.environment

Set-Location -LiteralPath $launchDir

Get-ChildItem Env: | Where-Object { $_.Name -like 'WINSMUX_*' } | ForEach-Object {
    Remove-Item -LiteralPath ('Env:' + $_.Name) -ErrorAction SilentlyContinue
}

if ($null -ne $environment.PSObject) {
    foreach ($property in $environment.PSObject.Properties) {
        $name = [string]$property.Name
        $value = [string]$property.Value
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            Set-Item -LiteralPath ('Env:' + $name) -Value $value
        }
    }
}

$summaryParts = @()
if (-not [string]::IsNullOrWhiteSpace($label)) { $summaryParts += $label }
if (-not [string]::IsNullOrWhiteSpace($role)) { $summaryParts += "role=$role" }
if (-not [string]::IsNullOrWhiteSpace($model)) { $summaryParts += "model=$model" }
$summaryParts += "dir=$launchDir"
Write-Host ("[winsmux] pane bootstrap: " + ($summaryParts -join ' / '))

Invoke-Expression $launchCommand
