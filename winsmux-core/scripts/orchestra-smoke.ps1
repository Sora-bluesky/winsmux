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
    $workers = [int]$settings.worker_count
    $agentSlots = @()
    if ($settings -is [System.Collections.IDictionary]) {
        if ($settings.Contains('agent_slots')) {
            $agentSlots = @($settings.agent_slots)
        }
    } elseif ($null -ne $settings -and $null -ne $settings.PSObject -and ($settings.PSObject.Properties.Name -contains 'agent_slots')) {
        $agentSlots = @($settings.agent_slots)
    }

    if ([bool]$settings.legacy_role_layout) {
        return [ordered]@{
            Commanders  = [int]$settings.commanders
            Workers     = 0
            Builders    = [int]$settings.builders
            Researchers = [int]$settings.researchers
            Reviewers   = [int]$settings.reviewers
        }
    }

    if ($agentSlots.Count -gt 0) {
        $workers = $agentSlots.Count
    }

    return [ordered]@{
        Commanders = if ([bool]$settings.external_commander) { 0 } else { 1 }
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

function ConvertTo-OrchestraSmokeBoolean {
    param([AllowNull()]$Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = ([string]$Value).Trim().ToLowerInvariant()
    switch ($text) {
        'true' { return $true }
        'false' { return $false }
        '1' { return $true }
        '0' { return $false }
        '' { return $false }
        default { return [bool]$Value }
    }
}

function Get-OrchestraOperatorContract {
    param(
        [Parameter(Mandatory = $true)][bool]$SmokeOk,
        [Parameter(Mandatory = $true)][bool]$SessionReady,
        [Parameter(Mandatory = $true)][bool]$UiAttachLaunched,
        [Parameter(Mandatory = $true)][bool]$UiAttached,
        [Parameter(Mandatory = $true)][string]$UiAttachStatus,
        [Parameter(Mandatory = $true)][int]$PaneCount,
        [Parameter(Mandatory = $true)][int]$ExpectedPaneCount,
        [Parameter(Mandatory = $true)][string[]]$SmokeErrors
    )

    $state = 'blocked'
    $message = 'Orchestra startup is blocked. Inspect smoke_errors before continuing.'
    $canDispatch = $false
    $requiresStartup = $true
    $uiWarning = $false
    $nextAction = 'Inspect smoke_errors and rerun orchestra-start before dispatching work.'

    if ($SmokeOk) {
        $state = 'ready'
        $message = 'Orchestra session is ready for dispatch.'
        $canDispatch = $true
        $requiresStartup = $false
        $nextAction = 'Dispatch work or continue operator flow.'

        if ($SessionReady -and ($UiAttachLaunched -or -not $UiAttached)) {
            $uiAttachWarningStatuses = @(
                'attach_launched',
                'attach_launched_pwsh',
                'attach_launched_wt_fallback',
                'wt_alias_stub',
                'wt_unavailable',
                'attach_exited_early',
                'attach_failed',
                'winsmux_unresolved'
            )
            if ($uiAttachWarningStatuses -contains $UiAttachStatus -or -not $UiAttached) {
                $state = 'ready-with-ui-warning'
                $message = 'Orchestra session is ready, but UI attach needs attention.'
                $uiWarning = $true
                $nextAction = 'Dispatch may continue; retry UI attach only if a visible operator window is required.'
            }
        }
    } elseif ($PaneCount -lt $ExpectedPaneCount -or -not $SessionReady) {
        $state = 'blocked'
        $message = 'Orchestra startup did not reach session-ready.'
        $canDispatch = $false
        $requiresStartup = $true
        $nextAction = 'Fix startup blockers and rerun orchestra-start, then recheck orchestra-smoke.'
    }

    return [ordered]@{
        contract_version = 1
        operator_state   = $state
        operator_message = $message
        can_dispatch     = $canDispatch
        requires_startup = $requiresStartup
        ui_warning       = $uiWarning
        next_action      = $nextAction
        smoke_errors     = @($SmokeErrors)
    }
}

if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
    $ProjectDir = (Get-Location).Path
}

$ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)
$SessionName = 'winsmux-orchestra'
$startScript = Join-Path $scriptsRoot 'orchestra-start.ps1'
$winsmuxCorePath = Join-Path (Split-Path -Parent $scriptsRoot) '..\scripts\winsmux-core.ps1'
$winsmuxCorePath = [System.IO.Path]::GetFullPath($winsmuxCorePath)
$layoutSettings = Get-OrchestraSmokeLayoutSettings -Root $ProjectDir
$expectedPaneCount = Get-OrchestraSmokeExpectedPaneCount -LayoutSettings $layoutSettings
$manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
$manifestFound = Test-Path -LiteralPath $manifestPath

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

$startOutput = ''
$startExitCode = 0
$sessionAlreadyHealthy = $paneProbeOk -and $paneCount -ge $expectedPaneCount -and $manifestFound
if ($sessionAlreadyHealthy) {
    $startOutput = 'Skipped orchestra-start; existing orchestra session already meets the smoke prerequisites.'
} else {
    $startOutput = & pwsh -NoProfile -Command "Set-Location -LiteralPath '$ProjectDir'; & '$startScript'" 2>&1
    $startExitCode = $LASTEXITCODE
    $manifestFound = Test-Path -LiteralPath $manifestPath
    if (-not [string]::IsNullOrWhiteSpace($winsmuxBin)) {
        try {
            $paneLines = & $winsmuxBin list-panes -t $SessionName 2>&1
            if ($LASTEXITCODE -eq 0) {
                $paneCount = @($paneLines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
                $paneProbeOk = $true
                $paneProbeError = ''
            } else {
                $paneProbeOk = $false
                $paneProbeError = ($paneLines | Out-String).Trim()
            }
        } catch {
            $paneProbeOk = $false
            $paneProbeError = $_.Exception.Message
        }
    }
}

$sessionReady = $false
$uiAttachLaunched = $false
$uiAttached = $false
$uiAttachStatus = ''
$uiAttachReason = ''

if ($manifestFound) {
    $manifest = Get-WinsmuxManifest -ProjectDir $ProjectDir
    if ($null -ne $manifest -and $null -ne $manifest.session) {
        $sessionReady = ConvertTo-OrchestraSmokeBoolean $manifest.session.session_ready
        $uiAttachLaunched = ConvertTo-OrchestraSmokeBoolean $manifest.session.ui_attach_launched
        $uiAttached = ConvertTo-OrchestraSmokeBoolean $manifest.session.ui_attached
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
$operatorContract = Get-OrchestraOperatorContract `
    -SmokeOk ($smokeErrors.Count -eq 0) `
    -SessionReady $sessionReady `
    -UiAttachLaunched $uiAttachLaunched `
    -UiAttached $uiAttached `
    -UiAttachStatus $uiAttachStatus `
    -PaneCount $paneCount `
    -ExpectedPaneCount $expectedPaneCount `
    -SmokeErrors @($smokeErrors)

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
    operator_contract   = $operatorContract
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
