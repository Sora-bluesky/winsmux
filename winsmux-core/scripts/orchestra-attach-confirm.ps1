[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SessionName,
    [Parameter(Mandatory = $true)][string]$WinsmuxPath,
    [Parameter(Mandatory = $true)][string]$ProjectDir,
    [int]$BaselineClientCount = 0,
    [int]$TimeoutMilliseconds = 12000,
    [int]$PollMilliseconds = 250
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'orchestra-ui-attach.ps1')

try {
    Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -Properties @{
        session_name       = $SessionName
        winsmux_path       = $WinsmuxPath
        attach_status      = 'attach_confirming'
        ui_attach_source   = 'none'
        confirm_process_id = $PID
        confirm_started_at = (Get-Date).ToString('o')
        client_count_seen  = $BaselineClientCount
        error              = ''
    } | Out-Null

    $null = Wait-OrchestraAttachHandshake -SessionName $SessionName -WinsmuxBin $WinsmuxPath -BaselineClientCount $BaselineClientCount -ProjectDir $ProjectDir -TimeoutMilliseconds $TimeoutMilliseconds -PollMilliseconds $PollMilliseconds
} catch {
    Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -Properties @{
        attach_status     = 'attach_failed'
        ui_attach_source  = 'none'
        confirm_process_id = $PID
        client_count_seen = $BaselineClientCount
        error             = $_.Exception.Message
    } | Out-Null
}
