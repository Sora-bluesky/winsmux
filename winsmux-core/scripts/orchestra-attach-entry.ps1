[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'orchestra-ui-attach.ps1')

$defaultSessionName = 'winsmux-orchestra'

try {
    $state = Read-OrchestraAttachState -SessionName $defaultSessionName
    if ($null -eq $state) {
        throw "Attach state file was not found for session '$defaultSessionName'."
    }

    $sessionName = [string]$state.session_name
    $winsmuxPath = [string]$state.winsmux_path
    if ([string]::IsNullOrWhiteSpace($sessionName)) {
        $sessionName = $defaultSessionName
    }
    if ([string]::IsNullOrWhiteSpace($winsmuxPath)) {
        throw "winsmux executable path missing from attach state for session '$sessionName'."
    }
    $attachRequestId = Get-OrchestraAttachRequestId -State $state
    $renderReceiptPath = Get-OrchestraAttachStateString -State $state -Name 'render_receipt_path'
    if ([string]::IsNullOrWhiteSpace($attachRequestId) -or [string]::IsNullOrWhiteSpace($renderReceiptPath)) {
        throw "Render receipt metadata missing from attach state for session '$sessionName'."
    }

    $baselineClientCount = 0
    if ($state.PSObject.Properties.Name -contains 'baseline_client_count') {
        [void][int]::TryParse([string]$state.baseline_client_count, [ref]$baselineClientCount)
    }

    Write-OrchestraAttachState -SessionName $sessionName -Properties @{
        attach_status     = 'attach_entry_started'
        attach_process_id = $PID
        started_at        = (Get-Date).ToString('o')
        ui_attach_source  = 'none'
        error             = ''
    } | Out-Null

    $pwshPath = Get-OrchestraPowerShellPath
    $confirmScriptPath = Get-OrchestraAttachConfirmScriptPath
    Start-Process -FilePath $pwshPath -ArgumentList @(
        '-NoProfile',
        '-File',
        $confirmScriptPath,
        '-SessionName', $sessionName,
        '-WinsmuxPath', $winsmuxPath,
        '-BaselineClientCount', $baselineClientCount
    ) -WindowStyle Hidden | Out-Null

    $previousRenderReceiptPath = $env:WINSMUX_RENDER_RECEIPT_PATH
    $previousRenderRequestId = $env:WINSMUX_RENDER_REQUEST_ID
    $previousRenderSessionName = $env:WINSMUX_RENDER_SESSION_NAME
    $previousPsmuxActive = $env:PSMUX_ACTIVE
    $previousPsmuxSession = $env:PSMUX_SESSION
    try {
        $env:WINSMUX_RENDER_RECEIPT_PATH = $renderReceiptPath
        $env:WINSMUX_RENDER_REQUEST_ID = $attachRequestId
        $env:WINSMUX_RENDER_SESSION_NAME = $sessionName
        Remove-Item Env:PSMUX_ACTIVE -ErrorAction SilentlyContinue
        Remove-Item Env:PSMUX_SESSION -ErrorAction SilentlyContinue
        Invoke-WinsmuxBridgeCommand -WinsmuxBin $winsmuxPath -Arguments @('attach-session', '-t', $sessionName)
    } finally {
        foreach ($entry in @(
            @{ Name = 'WINSMUX_RENDER_RECEIPT_PATH'; Value = $previousRenderReceiptPath },
            @{ Name = 'WINSMUX_RENDER_REQUEST_ID'; Value = $previousRenderRequestId },
            @{ Name = 'WINSMUX_RENDER_SESSION_NAME'; Value = $previousRenderSessionName },
            @{ Name = 'PSMUX_ACTIVE'; Value = $previousPsmuxActive },
            @{ Name = 'PSMUX_SESSION'; Value = $previousPsmuxSession }
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
        Write-OrchestraAttachState -SessionName $sessionName -Properties @{
            attach_status = 'attach_failed'
            ui_attach_source = 'none'
            error = "winsmux attach-session exited with code $exitCode."
        } | Out-Null
        exit $exitCode
    }
} catch {
    Write-OrchestraAttachState -SessionName $defaultSessionName -Properties @{
        attach_status     = 'attach_failed'
        ui_attach_source  = 'none'
        attach_process_id = $PID
        error             = $_.Exception.Message
    } | Out-Null
    throw
}
