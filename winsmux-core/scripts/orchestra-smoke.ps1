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
. (Join-Path $scriptsRoot 'worker-isolation.ps1')

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
            Operators  = [int]$settings.operators
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
        Operators = if ([bool]$settings.external_operator) { 0 } else { 1 }
        Workers    = $workers
        Builders   = 0
        Researchers = 0
        Reviewers   = 0
    }
}

function Get-OrchestraSmokeExpectedPaneCount {
    param($LayoutSettings)

    return [int]$LayoutSettings.Operators +
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
    $uiHostKind = ''
    $attachRequestId = ''
    $attachAdapterTrace = @()

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
                if ($manifest.session.PSObject.Properties.Name -contains 'ui_host_kind') {
                    $uiHostKind = [string]$manifest.session.ui_host_kind
                }
                if ($manifest.session.PSObject.Properties.Name -contains 'attach_request_id') {
                    $attachRequestId = [string]$manifest.session.attach_request_id
                }
                if ($manifest.session.PSObject.Properties.Name -contains 'attach_adapter_trace') {
                    $attachAdapterTrace = @($manifest.session.attach_adapter_trace)
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
        UiHostKind        = $uiHostKind
        AttachRequestId   = $attachRequestId
        AttachAdapterTrace = @($attachAdapterTrace)
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

function Resolve-OrchestraSmokeAttachState {
    param(
        [Parameter(Mandatory = $true)]$ProbeState,
        [AllowNull()]$AttachState,
        [Parameter(Mandatory = $true)][bool]$ClientProbeOk,
        [AllowNull()]$ClientSnapshot
    )

    $uiAttached = $false
    $uiAttachStatus = [string]$ProbeState.UiAttachStatus
    $uiAttachReason = [string]$ProbeState.UiAttachReason
    $uiAttachSource = [string]$ProbeState.UiAttachSource
    $uiHostKind = [string]$ProbeState.UiHostKind
    $attachRequestId = [string]$ProbeState.AttachRequestId
    $attachedClientRegistryCount = 0
    $attachedClientSnapshot = @()
    $attachAdapterTrace = @()

    if ($null -eq $AttachState) {
        if ($ProbeState.PSObject.Properties.Name -contains 'AttachAdapterTrace') {
            $attachAdapterTrace = @($ProbeState.AttachAdapterTrace)
        }
        if ([bool]$ProbeState.UiAttachLaunched) {
            $uiAttachStatus = 'attach_unconfirmed'
            $uiAttachReason = 'Visible attach state is missing; runtime attach confirmation is unavailable.'
        } else {
            $uiAttachStatus = ''
            $uiAttachReason = ''
        }

        $uiAttachSource = 'none'
    } else {
        $attachStateStatus = if ($null -ne $AttachState.PSObject.Properties['attach_status']) { [string]$AttachState.attach_status } else { '' }
        $attachRequestId = if ($null -ne $AttachState.PSObject.Properties['attach_request_id']) {
            [string]$AttachState.attach_request_id
        } elseif ($null -ne $AttachState.PSObject.Properties['request_id']) {
            [string]$AttachState.request_id
        } else {
            ''
        }
        $uiHostKind = if ($null -ne $AttachState.PSObject.Properties['ui_host_kind']) { [string]$AttachState.ui_host_kind } else { '' }

        if ($null -ne $AttachState.PSObject.Properties['attached_client_count']) {
            [void][int]::TryParse(([string]$AttachState.attached_client_count), [ref]$attachedClientRegistryCount)
        } elseif ($null -ne $AttachState.PSObject.Properties['client_count_seen']) {
            [void][int]::TryParse(([string]$AttachState.client_count_seen), [ref]$attachedClientRegistryCount)
        }

        if ($null -ne $AttachState.PSObject.Properties['attached_client_snapshot']) {
            $attachedClientSnapshot = @($AttachState.attached_client_snapshot | ForEach-Object { [string]$_ })
        }
        $attachAdapterTrace = @(Get-OrchestraAttachTraceEntries -State $AttachState)

        $attachStateError = if ($null -ne $AttachState.PSObject.Properties['error']) { [string]$AttachState.error } else { '' }
        $attachStateSource = if ($null -ne $AttachState.PSObject.Properties['ui_attach_source']) { [string]$AttachState.ui_attach_source } else { '' }
        $currentClients = if ($null -ne $ClientSnapshot -and $null -ne $ClientSnapshot.PSObject.Properties['Clients']) { @($ClientSnapshot.Clients) } else { @() }

        if (($attachStateStatus -eq 'attach_confirmed') -and $ClientProbeOk -and (Test-OrchestraLiveVisibleAttachState -State $AttachState -SessionName ([string]$ProbeState.SessionName))) {
            $uiAttached = $true
            $uiAttachStatus = 'attach_confirmed'
            $uiAttachReason = $attachStateError
            $uiAttachSource = if ([string]::IsNullOrWhiteSpace($attachStateSource)) { 'handshake' } else { $attachStateSource }
        } elseif (($attachStateStatus -eq 'attach_confirmed') -and $ClientProbeOk -and (Test-OrchestraAttachClientSnapshotMatch -ExpectedClients $attachedClientSnapshot -CurrentClients $currentClients)) {
            $uiAttached = $true
            $uiAttachStatus = 'attach_confirmed'
            $uiAttachReason = if ([string]::IsNullOrWhiteSpace($attachStateError)) {
                'Attached-client registry matches the current runtime client snapshot.'
            } else {
                $attachStateError
            }
            $uiAttachSource = 'attached-client-registry'
        } elseif ($attachStateStatus -eq 'attach_confirmed') {
            $uiAttached = $false
            $uiAttachStatus = 'attach_unconfirmed'
            $uiAttachReason = if (-not $ClientProbeOk) {
                'Attach state exists, but the runtime client probe is unavailable.'
            } else {
                'Attach state exists, but no live visible attach process is associated with it.'
            }
            $uiAttachSource = if ([string]::IsNullOrWhiteSpace($attachStateSource)) { 'none' } else { $attachStateSource }
        } elseif ($attachStateStatus -eq 'attach_failed') {
            $uiAttachStatus = 'attach_failed'
            $uiAttachReason = $attachStateError
            $uiAttachSource = 'none'
        } elseif ($attachStateStatus -in @('attach_requested', 'attach_entry_started', 'attach_confirming')) {
            $uiAttached = $false
            $uiAttachStatus = 'attach_pending'
            $uiAttachReason = if ([string]::IsNullOrWhiteSpace($attachStateError)) {
                'Visible attach is still pending confirmation.'
            } else {
                $attachStateError
            }
            $uiAttachSource = 'none'
        }
    }

    return [ordered]@{
        UiAttached                  = $uiAttached
        UiAttachStatus              = $uiAttachStatus
        UiAttachReason              = $uiAttachReason
        UiAttachSource              = $uiAttachSource
        UiHostKind                  = $uiHostKind
        AttachRequestId             = $attachRequestId
        AttachedClientRegistryCount = $attachedClientRegistryCount
        AttachedClientSnapshot      = @($attachedClientSnapshot)
        AttachAdapterTrace          = @($attachAdapterTrace)
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
$externalOperatorMode = ([int]$layoutSettings.Operators -eq 0)
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
$attachState = Read-OrchestraAttachState -SessionName $SessionName
$attachResolution = Resolve-OrchestraSmokeAttachState -ProbeState ([pscustomobject]@{
    SessionName       = $SessionName
    UiAttachLaunched  = $uiAttachLaunched
    UiAttachStatus    = $probeState.UiAttachStatus
    UiAttachReason    = $probeState.UiAttachReason
    UiAttachSource    = $probeState.UiAttachSource
    UiHostKind        = $probeState.UiHostKind
    AttachRequestId   = $probeState.AttachRequestId
    AttachAdapterTrace = @($probeState.AttachAdapterTrace)
}) -AttachState $attachState -ClientProbeOk $clientProbeOk -ClientSnapshot $clientSnapshot
$uiAttached = [bool]$attachResolution.UiAttached
$uiAttachStatus = [string]$attachResolution.UiAttachStatus
$uiAttachReason = [string]$attachResolution.UiAttachReason
$uiAttachSource = [string]$attachResolution.UiAttachSource
$uiHostKind = [string]$attachResolution.UiHostKind
$attachRequestId = [string]$attachResolution.AttachRequestId
$attachedClientRegistryCount = [int]$attachResolution.AttachedClientRegistryCount
$attachedClientSnapshot = @($attachResolution.AttachedClientSnapshot)
$attachAdapterTrace = @($attachResolution.AttachAdapterTrace)

$gitPath = ''
try {
    $gitPath = (Get-Command 'git' -ErrorAction Stop).Source
} catch {
}

$manifestObject = $null
if ($manifestFound -and $manifestReadable) {
    try {
        $manifestObject = Get-WinsmuxManifest -ProjectDir $ProjectDir
    } catch {
        $manifestObject = $null
    }
}

$workerIsolation = Get-WinsmuxWorkerIsolationReport -ProjectDir $ProjectDir -Manifest $manifestObject -GitPath $gitPath

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
if (-not [bool]$workerIsolation.ok) {
    foreach ($finding in @($workerIsolation.findings)) {
        $smokeErrors.Add("worker isolation drift: $($finding.label): $($finding.message)") | Out-Null
    }
}
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
    runtime_attached_client_count = $attachedClientCount
    attached_client_count = $attachedClientCount
    attached_client_registry_count = $attachedClientRegistryCount
    attached_client_snapshot = @($attachedClientSnapshot)
    attach_adapter_trace = @($attachAdapterTrace)
    attach_request_id   = $attachRequestId
    external_operator_mode = $externalOperatorMode
    expected_pane_count = $expectedPaneCount
    manifest_found      = $manifestFound
    session_ready       = $sessionReady
    ui_attach_launched  = $uiAttachLaunched
    ui_attached         = $uiAttached
    ui_attach_status    = $uiAttachStatus
    ui_attach_reason    = $uiAttachReason
    ui_attach_source    = $uiAttachSource
    ui_host_kind        = $uiHostKind
    worker_isolation    = $workerIsolation
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
