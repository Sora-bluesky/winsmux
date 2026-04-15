[CmdletBinding()]
param(
    [string]$ProjectDir = '',
    [switch]$AsJson,
    [switch]$AutoStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptsRoot 'settings.ps1')
. (Join-Path $scriptsRoot 'manifest.ps1')
. (Join-Path $scriptsRoot 'orchestra-ui-attach.ps1')

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

function Get-OrchestraAttachedClientSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$WinsmuxBin,
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    $clients = @()
    $error = ''
    $ok = $false

    if ([string]::IsNullOrWhiteSpace($WinsmuxBin)) {
        return [PSCustomObject][ordered]@{
            Ok      = $false
            Count   = 0
            Error   = 'winsmux executable could not be resolved.'
            Clients = @()
        }
    }

    try {
        $clientLines = & $WinsmuxBin list-clients -t $SessionName 2>&1
        if ($LASTEXITCODE -eq 0) {
            $clients = @(
                $clientLines |
                    ForEach-Object { [string]$_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            $ok = $true
        } else {
            $error = ($clientLines | Out-String).Trim()
        }
    } catch {
        $error = $_.Exception.Message
    }

    [PSCustomObject][ordered]@{
        Ok      = $ok
        Count   = $clients.Count
        Error   = $error
        Clients = @($clients)
    }
}

function Get-OrchestraOperatorContract {
    param(
        [Parameter(Mandatory = $true)][bool]$SmokeOk,
        [Parameter(Mandatory = $true)][bool]$SessionReady,
        [Parameter(Mandatory = $true)][bool]$UiAttachLaunched,
        [Parameter(Mandatory = $true)][bool]$UiAttached,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$UiAttachStatus,
        [Parameter(Mandatory = $true)][bool]$ExternalOperatorMode,
        [Parameter(Mandatory = $true)][int]$PaneCount,
        [Parameter(Mandatory = $true)][int]$ExpectedPaneCount,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SmokeErrors
    )

    $state = 'blocked'
    $message = 'Orchestra startup is blocked. Inspect smoke_errors before continuing.'
    $canDispatch = $false
    $requiresStartup = $true
    $uiWarning = $false
    $nextAction = 'Inspect smoke_errors and rerun orchestra-start before dispatching work.'

    if ($SmokeOk) {
        $state = 'ready-with-ui-warning'
        $canDispatch = -not $ExternalOperatorMode
        $requiresStartup = $false
        $message = if ($ExternalOperatorMode) {
            'Orchestra session is session-ready, but external operator dispatch stays blocked until attached-client confirmation succeeds.'
        } else {
            'Orchestra session is session-ready. Visible attach is still unconfirmed, but internal operator mode may continue dispatch.'
        }
        $nextAction = if ($ExternalOperatorMode) { 'Run the visible attach step and wait for attached-client confirmation before dispatching work.' } else { 'Dispatch work or continue operator flow.' }

        if ($SessionReady -and $UiAttached) {
            $state = 'ready'
            $message = 'Orchestra session is ready for dispatch.'
            $canDispatch = $true
            $requiresStartup = $false
            $uiWarning = $false
            $nextAction = 'Dispatch work or continue operator flow.'
        } elseif ($SessionReady) {
            $uiWarning = $true
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

function Get-OrchestraSmokeProbeState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][int]$ExpectedPaneCount,
        [AllowEmptyString()][string]$WinsmuxBin = ''
    )

    $manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
    $manifestFound = Test-Path -LiteralPath $manifestPath
    $manifestReadable = $true
    $manifestReadError = ''

    $paneCount = 0
    $paneProbeOk = $false
    $paneProbeError = ''
    if (-not [string]::IsNullOrWhiteSpace($WinsmuxBin)) {
        try {
            $paneLines = & $WinsmuxBin list-panes -t $SessionName 2>&1
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

    $sessionReady = $false
    $uiAttachLaunched = $false
    $uiAttached = $false
    $uiAttachStatus = ''
    $uiAttachReason = ''
    $uiAttachSource = 'none'

    if ($manifestFound) {
        try {
            $manifest = Get-WinsmuxManifest -ProjectDir $ProjectDir
            if ($null -ne $manifest -and $null -ne $manifest.session) {
                $sessionReady = ConvertTo-OrchestraSmokeBoolean $manifest.session.session_ready
                $uiAttachLaunched = ConvertTo-OrchestraSmokeBoolean $manifest.session.ui_attach_launched
                $uiAttached = ConvertTo-OrchestraSmokeBoolean $manifest.session.ui_attached
                $uiAttachStatus = [string]$manifest.session.ui_attach_status
                $uiAttachReason = [string]$manifest.session.ui_attach_reason
                if ($manifest.session.PSObject.Properties.Name -contains 'ui_attach_source') {
                    $uiAttachSource = [string]$manifest.session.ui_attach_source
                }
            }
        } catch {
            $manifestReadable = $false
            $manifestReadError = $_.Exception.Message
        }
    }

    return [ordered]@{
        ManifestPath      = $manifestPath
        ManifestFound     = $manifestFound
        ManifestReadable  = $manifestReadable
        ManifestReadError = $manifestReadError
        PaneCount         = $paneCount
        PaneProbeOk       = $paneProbeOk
        PaneProbeError    = $paneProbeError
        SessionReady      = $sessionReady
        UiAttachLaunched  = $uiAttachLaunched
        UiAttached        = $uiAttached
        UiAttachStatus    = $uiAttachStatus
        UiAttachReason    = $uiAttachReason
        UiAttachSource    = $uiAttachSource
        ExpectedPaneCount = $ExpectedPaneCount
    }
}

function Wait-OrchestraSmokeConvergence {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][int]$ExpectedPaneCount,
        [AllowEmptyString()][string]$WinsmuxBin = '',
        [int]$TimeoutSeconds = 10
    )

    $state = Get-OrchestraSmokeProbeState -ProjectDir $ProjectDir -SessionName $SessionName -ExpectedPaneCount $ExpectedPaneCount -WinsmuxBin $WinsmuxBin
    $needsConvergence = (-not $state.ManifestFound) -or (-not $state.ManifestReadable) -or (-not $state.SessionReady) -or ((-not [string]::IsNullOrWhiteSpace($WinsmuxBin)) -and ((-not $state.PaneProbeOk) -or ($state.PaneCount -lt $ExpectedPaneCount)))
    if (-not $needsConvergence) {
        return $state
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        $state = Get-OrchestraSmokeProbeState -ProjectDir $ProjectDir -SessionName $SessionName -ExpectedPaneCount $ExpectedPaneCount -WinsmuxBin $WinsmuxBin
        if ($state.ManifestFound -and $state.ManifestReadable -and $state.SessionReady -and $state.PaneProbeOk -and $state.PaneCount -ge $ExpectedPaneCount) {
            return $state
        }
    }

    return $state
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
$externalOperatorMode = ([int]$layoutSettings.Commanders -eq 0)
$expectedPaneCount = Get-OrchestraSmokeExpectedPaneCount -LayoutSettings $layoutSettings

$winsmuxBin = ''
try {
    $winsmuxBin = (Get-Command 'winsmux' -ErrorAction Stop).Source
} catch {
}

$probeState = Get-OrchestraSmokeProbeState -ProjectDir $ProjectDir -SessionName $SessionName -ExpectedPaneCount $expectedPaneCount -WinsmuxBin $winsmuxBin
$manifestPath = [string]$probeState.ManifestPath
$manifestFound = [bool]$probeState.ManifestFound
$manifestReadable = [bool]$probeState.ManifestReadable
$manifestReadError = [string]$probeState.ManifestReadError
$paneCount = [int]$probeState.PaneCount
$paneProbeOk = [bool]$probeState.PaneProbeOk
$paneProbeError = [string]$probeState.PaneProbeError

$clientSnapshot = if ([string]::IsNullOrWhiteSpace($winsmuxBin)) {
    [PSCustomObject][ordered]@{
        Ok      = $false
        Count   = 0
        Error   = 'winsmux executable could not be resolved.'
        Clients = @()
    }
} else {
    Get-OrchestraAttachedClientSnapshot -WinsmuxBin $winsmuxBin -SessionName $SessionName
}
$clientProbeOk = [bool]$clientSnapshot.Ok
$clientProbeError = [string]$clientSnapshot.Error
$attachedClientCount = [int]$clientSnapshot.Count

$startOutput = ''
$startExitCode = 0
$sessionAlreadyHealthy = $paneProbeOk -and $paneCount -ge $expectedPaneCount -and $manifestFound -and $manifestReadable
if ($sessionAlreadyHealthy) {
    $startOutput = 'Skipped orchestra-start; existing orchestra session already meets the smoke prerequisites.'
} elseif ($AutoStart) {
    $startOutput = & pwsh -NoProfile -Command "Set-Location -LiteralPath '$ProjectDir'; & '$startScript'" 2>&1
    $startExitCode = $LASTEXITCODE
    $probeState = Wait-OrchestraSmokeConvergence -ProjectDir $ProjectDir -SessionName $SessionName -ExpectedPaneCount $expectedPaneCount -WinsmuxBin $winsmuxBin -TimeoutSeconds 10
    $manifestPath = [string]$probeState.ManifestPath
    $manifestFound = [bool]$probeState.ManifestFound
    $manifestReadable = [bool]$probeState.ManifestReadable
    $manifestReadError = [string]$probeState.ManifestReadError
    $paneCount = [int]$probeState.PaneCount
    $paneProbeOk = [bool]$probeState.PaneProbeOk
    $paneProbeError = [string]$probeState.PaneProbeError
} else {
    $startOutput = 'Skipped orchestra-start; run orchestra-start.ps1 when operator_contract.requires_startup is true.'
}

$sessionReady = [bool]$probeState.SessionReady
$uiAttachLaunched = [bool]$probeState.UiAttachLaunched
$uiAttached = $false
$uiAttachStatus = [string]$probeState.UiAttachStatus
$uiAttachReason = [string]$probeState.UiAttachReason
$uiAttachSource = [string]$probeState.UiAttachSource

$attachState = Read-OrchestraAttachState -SessionName $SessionName
if ($null -eq $attachState) {
    $uiAttached = $false
    if ($uiAttachLaunched) {
        $uiAttachStatus = 'attach_unconfirmed'
        $uiAttachReason = 'Visible attach state is missing; runtime attach confirmation is unavailable.'
    } else {
        $uiAttachStatus = ''
        $uiAttachReason = ''
    }
    $uiAttachSource = 'none'
} else {
    $attachStateStatus = [string]$attachState.attach_status
    if (($attachStateStatus -eq 'attach_confirmed') -and [bool]$clientProbeOk -and (Test-OrchestraLiveVisibleAttachState -State $attachState -SessionName $SessionName)) {
        $uiAttached = $true
        $uiAttachStatus = 'attach_confirmed'
        $uiAttachReason = [string]$attachState.error
        $uiAttachSource = if ([string]::IsNullOrWhiteSpace([string]$attachState.ui_attach_source)) { 'handshake' } else { [string]$attachState.ui_attach_source }
    } elseif (($attachStateStatus -eq 'attach_confirmed') -and [bool]$clientProbeOk -and (Test-OrchestraAttachClientSnapshotMatch -ExpectedClients $attachState.attached_client_snapshot -CurrentClients $clientSnapshot.Clients)) {
        $uiAttached = $true
        $uiAttachStatus = 'attach_confirmed'
        $uiAttachReason = if ([string]::IsNullOrWhiteSpace([string]$attachState.error)) {
            'Attached-client registry matches the current runtime client snapshot.'
        } else {
            [string]$attachState.error
        }
        $uiAttachSource = 'attached-client-registry'
    } elseif ($attachStateStatus -eq 'attach_confirmed') {
        $uiAttached = $false
        $uiAttachStatus = 'attach_unconfirmed'
        $uiAttachReason = if (-not [bool]$clientProbeOk) {
            'Attach state exists, but the runtime client probe is unavailable.'
        } else {
            'Attach state exists, but no live visible attach process is associated with it.'
        }
        $uiAttachSource = if ([string]::IsNullOrWhiteSpace([string]$attachState.ui_attach_source)) { 'none' } else { [string]$attachState.ui_attach_source }
    } elseif ($attachStateStatus -eq 'attach_failed') {
        $uiAttachStatus = 'attach_failed'
        $uiAttachReason = [string]$attachState.error
        $uiAttachSource = 'none'
    } elseif ($attachStateStatus -in @('attach_requested', 'attach_entry_started', 'attach_confirming')) {
        $uiAttached = $false
        $uiAttachStatus = 'attach_pending'
        $uiAttachReason = if ([string]::IsNullOrWhiteSpace([string]$attachState.error)) {
            'Visible attach is still pending confirmation.'
        } else {
            [string]$attachState.error
        }
        $uiAttachSource = 'none'
    }
}

$smokeErrors = [System.Collections.Generic.List[string]]::new()
if ($startExitCode -ne 0) { $smokeErrors.Add("orchestra-start exited with code $startExitCode.") | Out-Null }
if (-not $manifestFound) {
    $smokeErrors.Add('manifest missing after startup.') | Out-Null
} elseif (-not $manifestReadable) {
    $smokeErrors.Add("manifest read failed during startup convergence: $manifestReadError") | Out-Null
}
if (-not $sessionReady) { $smokeErrors.Add('session_ready is false.') | Out-Null }
if (-not $paneProbeOk) { $smokeErrors.Add("pane probe failed: $paneProbeError") | Out-Null }
if ($paneProbeOk -and $paneCount -lt $expectedPaneCount) { $smokeErrors.Add("pane count $paneCount is below expected $expectedPaneCount.") | Out-Null }
$operatorContract = Get-OrchestraOperatorContract `
    -SmokeOk ($smokeErrors.Count -eq 0) `
    -SessionReady $sessionReady `
    -UiAttachLaunched $uiAttachLaunched `
    -UiAttached $uiAttached `
    -UiAttachStatus $uiAttachStatus `
    -ExternalOperatorMode $externalOperatorMode `
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
    client_probe_ok     = $clientProbeOk
    client_probe_error  = $clientProbeError
    attached_client_count = $attachedClientCount
    expected_pane_count = $expectedPaneCount
    manifest_found      = $manifestFound
    session_ready       = $sessionReady
    ui_attach_launched  = $uiAttachLaunched
    ui_attached         = $uiAttached
    ui_attach_status    = $uiAttachStatus
    ui_attach_reason    = $uiAttachReason
    ui_attach_source    = $uiAttachSource
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
