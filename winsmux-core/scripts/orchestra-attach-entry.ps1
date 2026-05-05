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

    Invoke-WinsmuxBridgeCommand -WinsmuxBin $winsmuxPath -Arguments @('attach-session', '-t', $sessionName)
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
