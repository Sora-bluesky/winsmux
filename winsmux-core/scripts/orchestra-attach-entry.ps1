[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'orchestra-ui-attach.ps1')

$defaultSessionName = 'winsmux-orchestra'
$launchRequestId = [string]$env:WINSMUX_ATTACH_REQUEST_ID
$projectDir = if ([string]::IsNullOrWhiteSpace($env:WINSMUX_ATTACH_PROJECT_DIR)) { (Get-Location).Path } else { [string]$env:WINSMUX_ATTACH_PROJECT_DIR }

try {
    if ([string]::IsNullOrWhiteSpace($launchRequestId)) {
        throw 'Attach entry is missing its immutable request ID.'
    }
    $state = Read-OrchestraAttachState -SessionName $defaultSessionName -ProjectDir $projectDir
    if ($null -eq $state) {
        throw "Attach state file was not found for session '$defaultSessionName'."
    }
    if ((Get-OrchestraAttachRequestId -State $state) -ne $launchRequestId) {
        exit 0
    }

    $sessionName = [string]$state.session_name
    $winsmuxPath = [string]$state.winsmux_path
    $projectDir = [string]$state.project_dir
    if ([string]::IsNullOrWhiteSpace($sessionName)) {
        $sessionName = $defaultSessionName
    }
    if ([string]::IsNullOrWhiteSpace($winsmuxPath)) {
        throw "winsmux executable path missing from attach state for session '$sessionName'."
    }
    if ([string]::IsNullOrWhiteSpace($projectDir)) {
        throw "Project directory missing from attach state for session '$sessionName'."
    }
    $attachRequestId = Get-OrchestraAttachRequestId -State $state
    $renderReceiptPath = Get-OrchestraAttachStateString -State $state -Name 'render_receipt_path'
    $renderSessionIdentity = Get-OrchestraAttachStateString -State $state -Name 'render_session_identity'
    if ([string]::IsNullOrWhiteSpace($renderSessionIdentity)) {
        $renderSessionIdentity = $sessionName
    }
    $bridgeNamespaceL = Get-OrchestraAttachStateString -State $state -Name 'bridge_namespace_l'
    $bridgeSocketS = Get-OrchestraAttachStateString -State $state -Name 'bridge_socket_s'
    $bridgeSessionNamespace = Get-OrchestraAttachStateString -State $state -Name 'bridge_session_namespace'
    if ([string]::IsNullOrWhiteSpace($attachRequestId) -or [string]::IsNullOrWhiteSpace($renderReceiptPath)) {
        throw "Render receipt metadata missing from attach state for session '$sessionName'."
    }

    $baselineClientCount = 0
    if ($state.PSObject.Properties.Name -contains 'baseline_client_count') {
        [void][int]::TryParse([string]$state.baseline_client_count, [ref]$baselineClientCount)
    }

    $entryState = Write-OrchestraAttachState -SessionName $sessionName -ProjectDir $projectDir -ExpectedRequestId $launchRequestId -Properties @{
        attach_status     = 'attach_entry_started'
        attach_process_id = $PID
        started_at        = (Get-Date).ToString('o')
        ui_attach_source  = 'none'
        error             = ''
    }
    if ((Get-OrchestraAttachRequestId -State $entryState) -ne $launchRequestId) {
        exit 0
    }

    $previousRenderReceiptPath = $env:WINSMUX_RENDER_RECEIPT_PATH
    $previousRenderRequestId = $env:WINSMUX_RENDER_REQUEST_ID
    $previousRenderSessionName = $env:WINSMUX_RENDER_SESSION_NAME
    $previousPsmuxActive = $env:PSMUX_ACTIVE
    $previousPsmuxSession = $env:PSMUX_SESSION
    $previousBridgeNamespaceL = $env:WINSMUX_BRIDGE_NAMESPACE_L
    $previousBridgeSocketS = $env:WINSMUX_BRIDGE_SOCKET_S
    $previousBridgeSessionNamespace = $env:WINSMUX_BRIDGE_SESSION_NAMESPACE
    try {
        $env:WINSMUX_RENDER_RECEIPT_PATH = $renderReceiptPath
        $env:WINSMUX_RENDER_REQUEST_ID = $attachRequestId
        $env:WINSMUX_RENDER_SESSION_NAME = $renderSessionIdentity
        foreach ($selector in @(
            @{ Name = 'WINSMUX_BRIDGE_NAMESPACE_L'; Value = $bridgeNamespaceL },
            @{ Name = 'WINSMUX_BRIDGE_SOCKET_S'; Value = $bridgeSocketS },
            @{ Name = 'WINSMUX_BRIDGE_SESSION_NAMESPACE'; Value = $bridgeSessionNamespace }
        )) {
            if ([string]::IsNullOrWhiteSpace([string]$selector.Value)) {
                Remove-Item ("Env:{0}" -f $selector.Name) -ErrorAction SilentlyContinue
            } else {
                Set-Item ("Env:{0}" -f $selector.Name) -Value ([string]$selector.Value)
            }
        }
        $pwshPath = Get-OrchestraPowerShellPath
        $confirmScriptPath = Get-OrchestraAttachConfirmScriptPath
        Start-Process -FilePath $pwshPath -ArgumentList @(
            '-NoProfile',
            '-File',
            $confirmScriptPath,
            '-SessionName', $sessionName,
            '-WinsmuxPath', $winsmuxPath,
            '-ProjectDir', $projectDir,
            '-RequestId', $launchRequestId,
            '-BaselineClientCount', $baselineClientCount
        ) -WindowStyle Hidden | Out-Null
        Remove-Item Env:PSMUX_ACTIVE -ErrorAction SilentlyContinue
        Remove-Item Env:PSMUX_SESSION -ErrorAction SilentlyContinue
        Invoke-WinsmuxBridgeCommand -WinsmuxBin $winsmuxPath -Arguments @('attach-session', '-t', $sessionName)
    } finally {
        foreach ($entry in @(
            @{ Name = 'WINSMUX_RENDER_RECEIPT_PATH'; Value = $previousRenderReceiptPath },
            @{ Name = 'WINSMUX_RENDER_REQUEST_ID'; Value = $previousRenderRequestId },
            @{ Name = 'WINSMUX_RENDER_SESSION_NAME'; Value = $previousRenderSessionName },
            @{ Name = 'PSMUX_ACTIVE'; Value = $previousPsmuxActive },
            @{ Name = 'PSMUX_SESSION'; Value = $previousPsmuxSession },
            @{ Name = 'WINSMUX_BRIDGE_NAMESPACE_L'; Value = $previousBridgeNamespaceL },
            @{ Name = 'WINSMUX_BRIDGE_SOCKET_S'; Value = $previousBridgeSocketS },
            @{ Name = 'WINSMUX_BRIDGE_SESSION_NAMESPACE'; Value = $previousBridgeSessionNamespace }
        )) {
            if ($null -eq $entry.Value) {
                Remove-Item ("Env:{0}" -f $entry.Name) -ErrorAction SilentlyContinue
            } else {
                Set-Item ("Env:{0}" -f $entry.Name) -Value ([string]$entry.Value)
            }
        }
    }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-OrchestraAttachState -SessionName $sessionName -ProjectDir $projectDir -ExpectedRequestId $launchRequestId -Properties @{
            attach_status = 'attach_failed'
            ui_attach_source = 'none'
            error = "winsmux attach-session exited with code $exitCode."
        } | Out-Null
        exit $exitCode
    }
} catch {
    if (-not [string]::IsNullOrWhiteSpace($launchRequestId)) {
        Write-OrchestraAttachState -SessionName $defaultSessionName -ProjectDir $projectDir -ExpectedRequestId $launchRequestId -Properties @{
            attach_status     = 'attach_failed'
            ui_attach_source  = 'none'
            attach_process_id = $PID
            error             = $_.Exception.Message
        } | Out-Null
    }
    throw
}
