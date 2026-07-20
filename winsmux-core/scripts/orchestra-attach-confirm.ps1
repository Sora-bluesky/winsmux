[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SessionName,
    [Parameter(Mandatory = $true)][string]$WinsmuxPath,
    [Parameter(Mandatory = $true)][string]$ProjectDir,
    [Parameter(Mandatory = $true)][string]$RequestId,
    [int]$BaselineClientCount = 0,
    [int]$TimeoutMilliseconds = 12000,
    [int]$PollMilliseconds = 250
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'orchestra-ui-attach.ps1')

try {
    $currentState = Read-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir
    if ((Get-OrchestraAttachRequestId -State $currentState) -ne $RequestId) {
        exit 0
    }
    $confirmState = Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -ExpectedRequestId $RequestId -Properties @{
        session_name       = $SessionName
        winsmux_path       = $WinsmuxPath
        attach_status      = 'attach_confirming'
        ui_attach_source   = 'none'
        confirm_process_id = $PID
        confirm_started_at = (Get-Date).ToString('o')
        client_count_seen  = $BaselineClientCount
        error              = ''
    }
    if ((Get-OrchestraAttachRequestId -State $confirmState) -ne $RequestId) {
        exit 0
    }

    $null = Wait-OrchestraAttachHandshake -SessionName $SessionName -WinsmuxBin $WinsmuxPath -BaselineClientCount $BaselineClientCount -ProjectDir $ProjectDir -ExpectedRequestId $RequestId -TimeoutMilliseconds $TimeoutMilliseconds -PollMilliseconds $PollMilliseconds
} catch {
    Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -ExpectedRequestId $RequestId -Properties @{
        attach_status     = 'attach_failed'
        ui_attach_source  = 'none'
        confirm_process_id = $PID
        client_count_seen = $BaselineClientCount
        error             = $_.Exception.Message
    } | Out-Null
}
