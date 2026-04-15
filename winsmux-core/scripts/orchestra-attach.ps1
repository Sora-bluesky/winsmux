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
        [AllowEmptyString()][string]$AttachSource = 'none',
        [AllowEmptyString()][string]$AttachRequestId = '',
        [AllowEmptyCollection()][string[]]$AttachedClientSnapshot = @(),
        [AllowEmptyString()][string]$UiHostKind = ''
    )

    return [ordered]@{
        session_name          = $SessionName
        session_exists        = $SessionExists
        requires_startup      = $RequiresStartup
        attempted             = $Attempted
        launched              = $Launched
        attached              = $Attached
        attached_client_count = $AttachedClientCount
        attach_request_id     = $AttachRequestId
        attached_client_snapshot = @($AttachedClientSnapshot)
        status                = $Status
        reason                = $Reason
        path                  = $Path
        ui_attach_source      = $AttachSource
        ui_host_kind          = $UiHostKind
    }
}

$winsmuxPath = Get-Command 'winsmux' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
$result = $null
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
        $baselineClients = if ([bool]$clientSnapshot.Ok) { @($clientSnapshot.Clients) } else { @() }
        $existingAttachState = Read-OrchestraAttachState -SessionName $SessionName
        $existingAttachSource = if ($null -eq $existingAttachState) { '' } else { [string]$existingAttachState.ui_attach_source }
        if ([string]::IsNullOrWhiteSpace($existingAttachSource)) {
            $existingAttachSource = 'handshake'
        }
        $hasLiveVisibleAttach = (Test-OrchestraLiveVisibleAttachState -State $existingAttachState -SessionName $SessionName)
        if ($hasLiveVisibleAttach -and [bool]$clientSnapshot.Ok -and $baselineClientCount -ge 1) {
            $existingAttachState = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                session_name       = $SessionName
                winsmux_path       = $winsmuxPath
                attach_status      = 'attach_confirmed'
                attach_confirmed_at = (Get-Date).ToString('o')
                client_count_seen  = $baselineClientCount
                ui_attach_source   = $existingAttachSource
                error              = "Detected $baselineClientCount attached client(s) for session '$SessionName'."
            }

            $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $true -RequiresStartup $false -Attempted $false -Launched $false -Attached $true -Status 'attach_already_present' -Reason "Detected an existing live visible attach for session '$SessionName'; skipped spawning another visible attach window." -AttachedClientCount $baselineClientCount -AttachSource $existingAttachSource -AttachRequestId (Get-OrchestraAttachRequestId -State $existingAttachState) -AttachedClientSnapshot @(Get-OrchestraAttachStateStringArray -State $existingAttachState -Name 'attached_client_snapshot') -UiHostKind (Get-OrchestraAttachStateString -State $existingAttachState -Name 'ui_host_kind')
        } else {
            $terminalInfo = Get-OrchestraWindowsTerminalInfo
            $attachRequestId = [guid]::NewGuid().ToString('N')
            if (-not [bool]$terminalInfo.Available) {
                $state = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                    session_name          = $SessionName
                    winsmux_path          = $winsmuxPath
                    requested_at          = (Get-Date).ToString('o')
                    attach_request_id     = $attachRequestId
                    baseline_client_count = $baselineClientCount
                    baseline_clients      = @($baselineClients)
                    client_count_seen     = $baselineClientCount
                    attach_process_id     = 0
                    attach_status         = 'attach_requested'
                    attach_confirmed_at   = ''
                    started_at            = ''
                    ui_attach_source      = 'none'
                    error                 = ''
                } | Out-Null

                try {
                    $attachLaunch = Start-OrchestraPowerShellVisibleAttach
                    if ($null -ne $attachLaunch.Process -and $null -ne $attachLaunch.Process.PSObject -and ($attachLaunch.Process.PSObject.Properties.Name -contains 'Id')) {
                        Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                            attach_process_id = $attachLaunch.Process.Id
                            started_at        = (Get-Date).ToString('o')
                            ui_host_kind      = [string]$attachLaunch.HostKind
                        } | Out-Null
                    }
                    $confirmed = Wait-OrchestraAttachHandshake -SessionName $SessionName -WinsmuxBin $winsmuxPath -BaselineClientCount $baselineClientCount -BaselineClients $baselineClients
                    $confirmedState = if ($null -ne $confirmed.State) { $confirmed.State } else { $state }
                    $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $true -RequiresStartup $false -Attempted $true -Launched $true -Attached ([bool]$confirmed.Confirmed) -Status ([string]$confirmed.Status) -Reason ([string]$confirmed.Reason) -Path ([string]$attachLaunch.Path) -AttachedClientCount ([int]$confirmed.AttachedClientCount) -AttachSource ([string]$confirmed.Source) -AttachRequestId (Get-OrchestraAttachRequestId -State $confirmedState) -AttachedClientSnapshot @(Get-OrchestraAttachStateStringArray -State $confirmedState -Name 'attached_client_snapshot') -UiHostKind (Get-OrchestraAttachStateString -State $confirmedState -Name 'ui_host_kind')
                } catch {
                    $reason = if ([bool]$terminalInfo.IsAliasStub) {
                        'WindowsApps wt.exe alias was found, but no canonical Windows Terminal binary could be resolved.'
                    } else {
                        'Windows Terminal is not installed or not on PATH.'
                    }

                    $failureReason = "$reason Fallback host launch failed: $($_.Exception.Message)"
                    Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                        attach_status     = 'attach_failed'
                        ui_attach_source  = 'none'
                        error             = $failureReason
                    } | Out-Null

                    $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $true -RequiresStartup $false -Attempted $true -Launched $false -Attached $false -Status 'attach_failed' -Reason $failureReason -Path '' -AttachedClientCount $baselineClientCount -AttachSource 'none' -AttachRequestId $attachRequestId -AttachedClientSnapshot @() -UiHostKind ''
                }
            } else {
                $profile = Ensure-OrchestraAttachProfile -ProjectDir $ProjectDir
                $state = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                    session_name          = $SessionName
                    winsmux_path          = $winsmuxPath
                    project_dir           = $ProjectDir
                    requested_at          = (Get-Date).ToString('o')
                    attach_request_id     = $attachRequestId
                    baseline_client_count = $baselineClientCount
                    baseline_clients      = @($baselineClients)
                    client_count_seen     = $baselineClientCount
                    attach_process_id     = 0
                    attach_status         = 'attach_requested'
                    attach_confirmed_at   = ''
                    started_at            = ''
                    ui_attach_source      = 'none'
                    error                 = ''
                }

                try {
                    $attachLaunch = Start-OrchestraWindowsTerminalVisibleAttach -TerminalPath ([string]$terminalInfo.Path) -ProfileName ([string]$profile.ProfileName)
                    $launchedPath = [string]$attachLaunch.Path
                    if ($null -ne $attachLaunch.Process -and $null -ne $attachLaunch.Process.PSObject -and ($attachLaunch.Process.PSObject.Properties.Name -contains 'Id')) {
                        Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                            attach_process_id = $attachLaunch.Process.Id
                            started_at        = (Get-Date).ToString('o')
                            ui_host_kind      = [string]$attachLaunch.HostKind
                        } | Out-Null
                    }
                } catch {
                    try {
                        $attachLaunch = Start-OrchestraPowerShellVisibleAttach
                        $launchedPath = [string]$attachLaunch.Path
                        if ($null -ne $attachLaunch.Process -and $null -ne $attachLaunch.Process.PSObject -and ($attachLaunch.Process.PSObject.Properties.Name -contains 'Id')) {
                            Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                                attach_process_id = $attachLaunch.Process.Id
                                started_at        = (Get-Date).ToString('o')
                                ui_host_kind      = [string]$attachLaunch.HostKind
                            } | Out-Null
                        }
                    } catch {
                        Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                            attach_status     = 'attach_failed'
                            ui_attach_source  = 'none'
                            error             = $_.Exception.Message
                        } | Out-Null

                        $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $true -RequiresStartup $false -Attempted $true -Launched $false -Attached $false -Status 'attach_failed' -Reason $_.Exception.Message -Path ([string]$terminalInfo.Path) -AttachedClientCount $baselineClientCount -AttachSource 'none' -AttachRequestId (Get-OrchestraAttachRequestId -State $state) -AttachedClientSnapshot @(Get-OrchestraAttachStateStringArray -State $state -Name 'attached_client_snapshot') -UiHostKind (Get-OrchestraAttachStateString -State $state -Name 'ui_host_kind')
                    }
                }

                if ($null -eq $result) {
                    if ($launchedPath -eq [string]$terminalInfo.Path) {
                        $launchObserved = Wait-OrchestraAttachLaunchObservation -SessionName $SessionName -WinsmuxBin $winsmuxPath -BaselineClientCount $baselineClientCount -BaselineClients $baselineClients
                        if (-not [bool]$launchObserved.Observed) {
                            try {
                                $attachLaunch = Start-OrchestraPowerShellVisibleAttach
                                $launchedPath = [string]$attachLaunch.Path
                                if ($null -ne $attachLaunch.Process -and $null -ne $attachLaunch.Process.PSObject -and ($attachLaunch.Process.PSObject.Properties.Name -contains 'Id')) {
                                    Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                                        attach_process_id = $attachLaunch.Process.Id
                                        started_at        = (Get-Date).ToString('o')
                                        ui_host_kind      = [string]$attachLaunch.HostKind
                                    } | Out-Null
                                }
                            } catch {
                                Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                                    attach_status     = 'attach_failed'
                                    ui_attach_source  = 'none'
                                    error             = $_.Exception.Message
                                } | Out-Null

                                $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $true -RequiresStartup $false -Attempted $true -Launched $false -Attached $false -Status 'attach_failed' -Reason $_.Exception.Message -Path ([string]$terminalInfo.Path) -AttachedClientCount $baselineClientCount -AttachSource 'none' -AttachRequestId (Get-OrchestraAttachRequestId -State $state) -AttachedClientSnapshot @(Get-OrchestraAttachStateStringArray -State $state -Name 'attached_client_snapshot') -UiHostKind (Get-OrchestraAttachStateString -State $state -Name 'ui_host_kind')
                            }
                        }
                    }
                }

                if ($null -eq $result) {
                    $confirmed = Wait-OrchestraAttachHandshake -SessionName $SessionName -WinsmuxBin $winsmuxPath -BaselineClientCount $baselineClientCount -BaselineClients $baselineClients
                    $confirmedState = if ($null -ne $confirmed.State) { $confirmed.State } else { $state }
                    $result = New-OrchestraAttachResult -SessionName $SessionName -SessionExists $true -RequiresStartup $false -Attempted $true -Launched $true -Attached ([bool]$confirmed.Confirmed) -Status ([string]$confirmed.Status) -Reason ([string]$confirmed.Reason) -Path $launchedPath -AttachedClientCount ([int]$confirmed.AttachedClientCount) -AttachSource ([string]$confirmed.Source) -AttachRequestId (Get-OrchestraAttachRequestId -State $confirmedState) -AttachedClientSnapshot @(Get-OrchestraAttachStateStringArray -State $confirmedState -Name 'attached_client_snapshot') -UiHostKind (Get-OrchestraAttachStateString -State $confirmedState -Name 'ui_host_kind')
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
