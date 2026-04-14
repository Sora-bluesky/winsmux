[CmdletBinding()]
param(
    [string]$ProjectDir = '',
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptsRoot 'settings.ps1')
. (Join-Path $scriptsRoot 'manifest.ps1')

function Get-OrchestraSmokeLayoutSettings {
    param([string]$Root)

    $settings = Get-BridgeSettings -ProjectDir $Root
    $rawWorkers = [string](Get-RoleAgentConfig -Role 'worker' -Settings $settings).count
    $workers = if ([string]::IsNullOrWhiteSpace($rawWorkers)) { 6 } else { [int]$rawWorkers }

    return [ordered]@{
        Commanders = 0
        Workers    = $workers
        Builders   = 0
        Researchers = 0
        Reviewers   = 0
    }
}

function Get-OrchestraSmokeExpectedPaneCount {
    param($LayoutSettings)

    return [int]$LayoutSettings.Commanders +
        [int]$LayoutSettings.Workers +
        [int]$LayoutSettings.Builders +
        [int]$LayoutSettings.Researchers +
        [int]$LayoutSettings.Reviewers
}

if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
    $ProjectDir = (Get-Location).Path
}

$ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)
$SessionName = 'winsmux-orchestra'
$startScript = Join-Path $scriptsRoot 'orchestra-start.ps1'
$winsmuxCorePath = Join-Path (Split-Path -Parent $scriptsRoot) '..\scripts\winsmux-core.ps1'
$winsmuxCorePath = [System.IO.Path]::GetFullPath($winsmuxCorePath)

$startOutput = & pwsh -NoProfile -Command "Set-Location -LiteralPath '$ProjectDir'; & '$startScript'" 2>&1
$startExitCode = $LASTEXITCODE

$winsmuxBin = ''
try {
    $winsmuxBin = (Get-Command 'winsmux' -ErrorAction Stop).Source
} catch {
}

$paneCount = 0
$paneProbeOk = $false
$paneProbeError = ''
if (-not [string]::IsNullOrWhiteSpace($winsmuxBin)) {
    try {
        $paneLines = & $winsmuxBin list-panes -t $SessionName 2>&1
        if ($LASTEXITCODE -eq 0) {
            $paneCount = @($paneLines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
            $paneProbeOk = $true
        } else {
            $paneProbeError = ($paneLines | Out-String).Trim()
        }
    } catch {
        $paneProbeError = $_.Exception.Message
    }
} else {
    $paneProbeError = 'winsmux executable could not be resolved.'
}

$layoutSettings = Get-OrchestraSmokeLayoutSettings -Root $ProjectDir
$expectedPaneCount = Get-OrchestraSmokeExpectedPaneCount -LayoutSettings $layoutSettings
$manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
$manifestFound = Test-Path -LiteralPath $manifestPath
$sessionReady = $false
$uiAttachLaunched = $false
$uiAttached = $false
$uiAttachStatus = ''
$uiAttachReason = ''

if ($manifestFound) {
    $manifest = Read-WinsmuxManifest -ProjectDir $ProjectDir
    if ($null -ne $manifest -and $null -ne $manifest.session) {
        $sessionReady = [bool]$manifest.session.session_ready
        $uiAttachLaunched = [bool]$manifest.session.ui_attach_launched
        $uiAttached = [bool]$manifest.session.ui_attached
        $uiAttachStatus = [string]$manifest.session.ui_attach_status
        $uiAttachReason = [string]$manifest.session.ui_attach_reason
    }
}

$smokeErrors = [System.Collections.Generic.List[string]]::new()
if ($startExitCode -ne 0) { $smokeErrors.Add("orchestra-start exited with code $startExitCode.") | Out-Null }
if (-not $manifestFound) { $smokeErrors.Add('manifest missing after startup.') | Out-Null }
if (-not $sessionReady) { $smokeErrors.Add('session_ready is false.') | Out-Null }
if (-not $paneProbeOk) { $smokeErrors.Add("pane probe failed: $paneProbeError") | Out-Null }
if ($paneProbeOk -and $paneCount -lt $expectedPaneCount) { $smokeErrors.Add("pane count $paneCount is below expected $expectedPaneCount.") | Out-Null }

$result = [ordered]@{
    project_dir         = $ProjectDir
    session_name        = $SessionName
    start_exit_code     = $startExitCode
    winsmux_bin         = $winsmuxBin
    pane_count          = $paneCount
    pane_probe_ok       = $paneProbeOk
    pane_probe_error    = $paneProbeError
    expected_pane_count = $expectedPaneCount
    manifest_found      = $manifestFound
    session_ready       = $sessionReady
    ui_attach_launched  = $uiAttachLaunched
    ui_attached         = $uiAttached
    ui_attach_status    = $uiAttachStatus
    ui_attach_reason    = $uiAttachReason
    smoke_ok            = ($smokeErrors.Count -eq 0)
    smoke_errors        = @($smokeErrors)
    startup_output      = ($startOutput | Out-String).Trim()
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 8
} else {
    $result.GetEnumerator() | ForEach-Object {
        '{0}: {1}' -f $_.Key, $_.Value
    }
}

if ($smokeErrors.Count -gt 0) {
    exit 1
}
