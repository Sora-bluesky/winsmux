[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PlanFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'manifest.ps1')

if (-not (Test-Path -LiteralPath $PlanFile)) {
    throw "Orchestra pane bootstrap plan not found: $PlanFile"
}

$plan = Get-Content -LiteralPath $PlanFile -Raw -Encoding UTF8 | ConvertFrom-Json

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
$readyMarkerPath = [string]$plan.ready_marker_path
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

if (-not [string]::IsNullOrWhiteSpace($readyMarkerPath)) {
    $markerDir = Split-Path -Parent $readyMarkerPath
    if (-not [string]::IsNullOrWhiteSpace($markerDir) -and -not (Test-Path -LiteralPath $markerDir)) {
        New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
    }

    $markerJson = ([ordered]@{
        state                       = 'bootstrap_pending'
        generation_id               = [string]$plan.generation_id
        server_session_id           = [string]$plan.server_session_id
        slot_id                      = [string]$plan.slot_id
        pane_id                      = [string]$plan.pane_id
        backend                      = [string]$plan.worker_backend
        role                         = [string]$plan.worker_role
        title                        = [string]$plan.pane_title
        bootstrap_pid                = $PID
        bootstrap_process_started_at = Get-WinsmuxRuntimeProcessStartedAt -ProcessId $PID
        launch_dir                   = $launchDir
        current_dir                  = (Get-Location).Path
        written_at                   = (Get-Date).ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    } | ConvertTo-Json -Depth 6)
    Write-WinsmuxTextFile -Path $readyMarkerPath -Content $markerJson
}

Invoke-Expression $launchCommand
