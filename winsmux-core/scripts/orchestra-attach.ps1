[CmdletBinding()]
param(
    [string]$ProjectDir = '',
    [string]$SessionName = 'winsmux-orchestra',
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
    $ProjectDir = (Get-Location).Path
}

$ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)
$scriptsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $scriptsRoot 'orchestra-ui-attach.ps1')

function New-OrchestraAttachResult {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][bool]$SessionExists,
        [Parameter(Mandatory = $true)][bool]$RequiresStartup,
        [Parameter(Mandatory = $true)][bool]$Attempted,
        [Parameter(Mandatory = $true)][bool]$Launched,
        [Parameter(Mandatory = $true)][bool]$Attached,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Reason,
        [AllowEmptyString()][string]$Path = '',
        [int]$AttachedClientCount = 0,
        [AllowEmptyString()][string]$AttachSource = 'none'
    )

    return [ordered]@{
        session_name          = $SessionName
        session_exists        = $SessionExists
        requires_startup      = $RequiresStartup
        attempted             = $Attempted
        launched              = $Launched
        attached              = $Attached
        attached_client_count = $AttachedClientCount
        status                = $Status
        reason                = $Reason
        path                  = $Path
        ui_attach_source      = $AttachSource
    }
}

$winsmuxPath = Get-Command 'winsmux' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($winsmuxPath)) {
    $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $false -RequiresStartup $true -Attempted $false -Launched $false -Attached $false -Status 'winsmux_unresolved' -Reason 'winsmux executable could not be resolved.'
} else {
    & $winsmuxPath 'has-session' '-t' $SessionName 1>$null 2>$null
    $sessionExists = ($LASTEXITCODE -eq 0)
    if (-not $sessionExists) {
        $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $false -RequiresStartup $true -Attempted $false -Launched $false -Attached $false -Status 'session_missing' -Reason "winsmux session '$SessionName' was not found. Run orchestra-start.ps1 first."
    } else {
        $clientSnapshot = Get-OrchestraAttachedClientSnapshot -WinsmuxBin $winsmuxPath -SessionName $SessionName
        $baselineClientCount = if ([bool]$clientSnapshot.Ok) { [int]$clientSnapshot.Count } else { 0 }
        if ([bool]$clientSnapshot.Ok -and $baselineClientCount -ge 1) {
            Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                session_name       = $SessionName
                winsmux_path       = $winsmuxPath
                attach_status      = 'attach_confirmed'
                attach_confirmed_at = (Get-Date).ToString('o')
                client_count_seen  = $baselineClientCount
                ui_attach_source   = 'client-probe'
                error              = "Detected $baselineClientCount attached client(s) for session '$SessionName'."
            } | Out-Null

            $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $true -RequiresStartup $false -Attempted $false -Launched $false -Attached $true -Status 'attach_already_present' -Reason "Detected $baselineClientCount attached client(s) for session '$SessionName'; skipped spawning another visible attach window." -AttachedClientCount $baselineClientCount -AttachSource 'client-probe'
        } else {
            $terminalInfo = Get-OrchestraWindowsTerminalInfo
            if (-not [bool]$terminalInfo.Available) {
                $reason = if ([bool]$terminalInfo.IsAliasStub) {
                    'WindowsApps wt.exe alias was found, but no canonical Windows Terminal binary could be resolved.'
                } else {
                    'Windows Terminal is not installed or not on PATH.'
                }

                Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                    session_name       = $SessionName
                    winsmux_path       = $winsmuxPath
                    attach_status      = 'attach_failed'
                    requested_at       = (Get-Date).ToString('o')
                    baseline_client_count = $baselineClientCount
                    client_count_seen  = $baselineClientCount
                    ui_attach_source   = 'none'
                    error              = $reason
                } | Out-Null

                $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $true -RequiresStartup $false -Attempted $false -Launched $false -Attached $false -Status 'attach_failed' -Reason $reason -Path ([string]$terminalInfo.Path) -AttachedClientCount $baselineClientCount -AttachSource 'none'
            } else {
                $profile = Ensure-OrchestraAttachProfile -ProjectDir $ProjectDir
                $state = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                    session_name          = $SessionName
                    winsmux_path          = $winsmuxPath
                    project_dir           = $ProjectDir
                    requested_at          = (Get-Date).ToString('o')
                    request_id            = [guid]::NewGuid().ToString('N')
                    baseline_client_count = $baselineClientCount
                    client_count_seen     = $baselineClientCount
                    attach_status         = 'attach_requested'
                    ui_attach_source      = 'none'
                    error                 = ''
                }

                try {
                    $attachProcess = Start-Process -FilePath ([string]$terminalInfo.Path) -ArgumentList @('-w', '-1', 'new-tab', '-p', [string]$profile.ProfileName) -PassThru
                    $launchedPath = [string]$terminalInfo.Path
                } catch {
                    Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                        attach_status     = 'attach_failed'
                        ui_attach_source  = 'none'
                        error             = $_.Exception.Message
                    } | Out-Null

                    $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $true -RequiresStartup $false -Attempted $true -Launched $false -Attached $false -Status 'attach_failed' -Reason $_.Exception.Message -Path ([string]$terminalInfo.Path) -AttachedClientCount $baselineClientCount -AttachSource 'none'
                }

                if ($null -eq $result) {
                    $confirmed = Wait-OrchestraAttachHandshake -SessionName $SessionName -WinsmuxBin $winsmuxPath -BaselineClientCount $baselineClientCount
                    $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $true -RequiresStartup $false -Attempted $true -Launched $true -Attached ([bool]$confirmed.Confirmed) -Status ([string]$confirmed.Status) -Reason ([string]$confirmed.Reason) -Path $launchedPath -AttachedClientCount ([int]$confirmed.AttachedClientCount) -AttachSource ([string]$confirmed.Source)
                }
            }
        }
    }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 8
} else {
    $result.GetEnumerator() | ForEach-Object {
        '{0}: {1}' -f $_.Key, $_.Value
    }
}

if ($result.status -notin @('attach_confirmed', 'attach_already_present')) {
    exit 1
}
