<#
.SYNOPSIS
Agent idle/crash detection with auto-respawn for Orchestra panes.

.DESCRIPTION
Monitors Orchestra panes for agent health. Detects crashed, hung, or empty
panes and respawns agents automatically.

Dot-source this script to load the helpers:

    . "$PSScriptRoot/agent-monitor.ps1"

Or run directly for a single monitoring cycle:

    pwsh -NoProfile -File agent-monitor.ps1 [-ProjectDir <path>] [-SessionName <name>]
#>

[CmdletBinding()]
param(
    [string]$ProjectDir,
    [string]$SessionName = 'winsmux-orchestra',
    [int]$HungThresholdSeconds = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = $PSScriptRoot
. "$scriptDir/settings.ps1"
. "$scriptDir/agent-readiness.ps1"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$script:HungSnapshotDir = Join-Path $env:TEMP 'winsmux\monitor_snapshots'
$script:IdleStateDir = Join-Path $env:TEMP 'winsmux\monitor_idle'
$script:AgentMonitorDefaultHungThreshold = 60
$script:IdleAlertRepeatSeconds = 300
$script:MonitorTelegramEnvPath = 'C:\Users\komei\.claude\channels\telegram\.env'
$script:MonitorTelegramChatId = '8642321094'
$script:BuilderStallHistory = @{}
$script:BuilderStallThresholdCycles = 3

# ---------------------------------------------------------------------------
# Psmux wrapper (same pattern as orchestra-start.ps1)
# ---------------------------------------------------------------------------

function Invoke-MonitorWinsmux {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$CaptureOutput
    )

    $winsmuxBin = Get-WinsmuxBin
    if (-not $winsmuxBin) {
        throw 'Could not find a winsmux binary. Tried: winsmux, pmux, tmux.'
    }

    if ($CaptureOutput) {
        $output = & $winsmuxBin @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            $message = ($output | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = 'unknown winsmux error'
            }

            throw "winsmux $($Arguments -join ' ') failed: $message"
        }

        return $output
    }

    & $winsmuxBin @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "winsmux $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

# ---------------------------------------------------------------------------
# Snapshot persistence (for hung detection)
# ---------------------------------------------------------------------------

function Get-MonitorSnapshotPath {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    $safe = $PaneId -replace '[%:]', '_'
    return Join-Path $script:HungSnapshotDir "$safe.json"
}

function Get-MonitorSnapshot {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    $path = Get-MonitorSnapshotPath -PaneId $PaneId
    if (-not (Test-Path $path -PathType Leaf)) {
        return $null
    }

    try {
        $raw = Get-Content -Path $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }

        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Save-MonitorSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Hash,
        [Parameter(Mandatory = $true)][string]$Timestamp
    )

    if (-not (Test-Path $script:HungSnapshotDir)) {
        New-Item -ItemType Directory -Path $script:HungSnapshotDir -Force | Out-Null
    }

    $path = Get-MonitorSnapshotPath -PaneId $PaneId
    $record = [ordered]@{
        hash      = $Hash
        timestamp = $Timestamp
    }

    ($record | ConvertTo-Json -Compress) | Set-Content -Path $path -Encoding UTF8 -NoNewline
}

function Get-MonitorIdleStatePath {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    return Join-Path $script:IdleStateDir "$PaneId.json"
}

function Get-MonitorIdleState {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    if ([string]::IsNullOrWhiteSpace($script:IdleStateDir)) {
        return $null
    }

    $path = Get-MonitorIdleStatePath -PaneId $PaneId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }

        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Save-MonitorIdleState {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)]$ReadySince,
        [Parameter(Mandatory = $true)][bool]$AlertSent,
        [AllowNull()]$LastAlertAt = $null
    )

    if ([string]::IsNullOrWhiteSpace($script:IdleStateDir)) {
        throw 'IdleStateDir is not configured.'
    }

    if (-not (Test-Path -LiteralPath $script:IdleStateDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:IdleStateDir -Force | Out-Null
    }

    $readySinceValue = if ($ReadySince -is [datetime]) {
        $ReadySince.ToString('o')
    } else {
        [string]$ReadySince
    }

    $lastAlertAtValue = ''
    if ($null -ne $LastAlertAt) {
        $lastAlertAtValue = if ($LastAlertAt -is [datetime]) {
            $LastAlertAt.ToString('o')
        } else {
            [string]$LastAlertAt
        }
    }

    $record = [ordered]@{
        ReadySince = $readySinceValue
        AlertSent  = $AlertSent
        LastAlertAt = $lastAlertAtValue
    }

    $path = Get-MonitorIdleStatePath -PaneId $PaneId
    ($record | ConvertTo-Json -Compress) | Set-Content -LiteralPath $path -Encoding UTF8 -NoNewline
}

function Update-MonitorIdleAlertState {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][string]$SnapshotTail,
        [Parameter(Mandatory = $true)][int]$IdleThresholdSeconds,
        [Parameter(Mandatory = $true)][datetime]$Now
    )

    $result = [ordered]@{
        ShouldAlert = $false
        Message     = ''
    }

    if ($Status -ne 'ready') {
        $path = Get-MonitorIdleStatePath -PaneId $PaneId
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }

        return $result
    }

    $state = Get-MonitorIdleState -PaneId $PaneId
    $readySince = $Now
    $alertSent = $false
    $lastAlertAt = $null

    if ($null -ne $state) {
        $alertSent = [bool](Get-MonitorPropertyValue -InputObject $state -Name 'AlertSent' -Default $false)
        $savedReadySince = [string](Get-MonitorPropertyValue -InputObject $state -Name 'ReadySince' -Default '')
        $savedLastAlertAt = [string](Get-MonitorPropertyValue -InputObject $state -Name 'LastAlertAt' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($savedReadySince)) {
            try {
                $readySince = [System.DateTimeOffset]::Parse($savedReadySince).DateTime
            } catch {
                $readySince = $Now
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($savedLastAlertAt)) {
            try {
                $lastAlertAt = [System.DateTimeOffset]::Parse($savedLastAlertAt).DateTime
            } catch {
                $lastAlertAt = $null
            }
        }
    }

    $repeatAlertDue = $false
    if ($alertSent) {
        if ($null -eq $lastAlertAt) {
            $repeatAlertDue = $true
            $alertSent = $false
        } elseif ((($Now - $lastAlertAt).TotalSeconds) -ge $script:IdleAlertRepeatSeconds) {
            $repeatAlertDue = $true
            $alertSent = $false
            $lastAlertAt = $null
        }
    }

    $elapsedSeconds = ($Now - $readySince).TotalSeconds
    if (($elapsedSeconds -ge $IdleThresholdSeconds) -and ((-not $alertSent) -or $repeatAlertDue)) {
        $message = "Commander alert: idle pane $Label ($PaneId, role=$Role)"
        Save-MonitorIdleState -PaneId $PaneId -ReadySince $readySince -AlertSent $true -LastAlertAt $Now
        $result.ShouldAlert = $true
        $result.Message = $message
        return $result
    }

    Save-MonitorIdleState -PaneId $PaneId -ReadySince $readySince -AlertSent $alertSent -LastAlertAt $lastAlertAt
    return $result
}

function Clear-BuilderStallState {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    if ($script:BuilderStallHistory.ContainsKey($PaneId)) {
        $script:BuilderStallHistory.Remove($PaneId)
    }
}

function Test-BuilderStall {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][string]$SnapshotHash,
        [int]$RequiredCycles = $script:BuilderStallThresholdCycles
    )

    if ($Role -ne 'Builder' -or $Status -ne 'busy' -or [string]::IsNullOrWhiteSpace($SnapshotHash)) {
        Clear-BuilderStallState -PaneId $PaneId
        return $false
    }

    if (-not $script:BuilderStallHistory.ContainsKey($PaneId)) {
        $script:BuilderStallHistory[$PaneId] = [System.Collections.Generic.List[string]]::new()
    }

    $hashHistory = [System.Collections.Generic.List[string]]$script:BuilderStallHistory[$PaneId]
    $hashHistory.Add($SnapshotHash)
    while ($hashHistory.Count -gt $RequiredCycles) {
        $hashHistory.RemoveAt(0)
    }

    if ($hashHistory.Count -lt $RequiredCycles) {
        return $false
    }

    foreach ($hash in $hashHistory) {
        if ($hash -ne $SnapshotHash) {
            return $false
        }
    }

    return $true
}

function Get-ContentHash {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        $Text = ''
    }

    return [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Text)
        )
    ) -replace '-', ''
}

function Get-MonitorPropertyValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }

        return $Default
    }

    if ($null -ne $InputObject.PSObject -and ($InputObject.PSObject.Properties.Name -contains $Name)) {
        return $InputObject.$Name
    }

    return $Default
}

function Test-CodexApprovalPromptText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $hasPrimaryYes = $Text -match '(?im)^[>\s\u203A\u276F\u25B6]*1\.\s*Yes\b'
    $hasSecondaryOption = $Text -match '(?im)^[>\s\u203A\u276F\u25B6]*2\.\s*'
    $hasPersistentYes = $Text -match "(?im)^[>\s\u203A\u276F\u25B6]*2\.\s*Yes,\s*and don't ask again\b"
    $hasProceedQuestion = $Text -match '(?im)Do you want to proceed\?'
    $hasCancelHint = $Text -match '(?im)Esc to cancel'
    $hasShellConfirm = $Text -match '(?im)\[(?:Y/n|y/N)\]'

    if ($hasShellConfirm -or $hasPersistentYes) {
        return $true
    }

    if ($hasPrimaryYes -and ($hasProceedQuestion -or $hasCancelHint -or $hasSecondaryOption)) {
        return $true
    }

    return $hasProceedQuestion -and $hasCancelHint
}

function Test-CodexContextExhaustionText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $tailText = (@(Get-RecentNonEmptyLines -Text $Text -MaxCount 20) -join [Environment]::NewLine)
    if ([string]::IsNullOrWhiteSpace($tailText)) {
        return $false
    }

    $patterns = @(
        '(?im)\bcontext exhaustion\b',
        '(?im)\bcontext(?:\s+window)?\s+exhausted\b',
        '(?im)\bcontext(?:\s+window|\s+length)?\s+limit\s+(?:reached|exceeded)\b',
        '(?im)\bmaximum\s+context(?:\s+window|\s+length)?\b',
        '(?im)\binput(?:\s+is)?\s+too\s+long\b'
    )

    foreach ($pattern in $patterns) {
        if ($tailText -match $pattern) {
            return $true
        }
    }

    return $false
}

function Wait-MonitorPaneShellReady {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $snapshot = Invoke-MonitorWinsmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') -CaptureOutput
            $text = ($snapshot | Out-String).TrimEnd()
            if ($null -ne (Get-LastNonEmptyLine -Text $text)) {
                return
            }
        } catch {
        }

        Start-Sleep -Milliseconds 250
    }

    throw "Timed out waiting for pane $PaneId shell prompt after respawn."
}

function Send-MonitorBridgeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $bridgeScript = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..\..\scripts\winsmux-core.ps1'))
    & pwsh -NoProfile -File $bridgeScript 'send' $PaneId $Text 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to send command to pane $PaneId"
    }
}

function Send-MonitorTelegramAlert {
    param([Parameter(Mandatory = $true)][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $script:MonitorTelegramEnvPath -PathType Leaf)) {
        return $false
    }

    try {
        $envLines = Get-Content -LiteralPath $script:MonitorTelegramEnvPath -Encoding UTF8
    } catch {
        return $false
    }

    $token = $null
    foreach ($line in $envLines) {
        if ($line -match '^\s*TELEGRAM_BOT_TOKEN\s*=\s*(.+?)\s*$') {
            $token = $Matches[1].Trim()
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        return $false
    }

    if (($token.StartsWith('"') -and $token.EndsWith('"')) -or ($token.StartsWith("'") -and $token.EndsWith("'"))) {
        $token = $token.Substring(1, $token.Length - 2)
    }

    $uri = "https://api.telegram.org/bot$token/sendMessage"
    $body = @{
        chat_id = $script:MonitorTelegramChatId
        text    = $Message
    }

    try {
        $response = Invoke-RestMethod -Method Post -Uri $uri -Body $body -ErrorAction Stop
        return [bool](Get-MonitorPropertyValue -InputObject $response -Name 'ok' -Default $true)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# 1. Get-PaneAgentStatus
# ---------------------------------------------------------------------------

function Get-PaneAgentStatus {
    <#
    .SYNOPSIS
    Captures pane output and returns the agent status.

    .OUTPUTS
    PSCustomObject with: Status (ready|busy|approval_waiting|crashed|hung|empty), PaneId, SnapshotTail, ExitReason
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [string]$Agent = 'codex',
        [string]$Role = '',
        [int]$HungThreshold = $script:AgentMonitorDefaultHungThreshold
    )

    $snapshot = $null
    try {
        $snapshot = Invoke-MonitorWinsmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') -CaptureOutput
    } catch {
        return [PSCustomObject]@{
            Status       = 'empty'
            PaneId       = $PaneId
            SnapshotTail = ''
            ExitReason   = ''
        }
    }

    $text = ($snapshot | Out-String).TrimEnd()

    # empty: pane has no content
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [PSCustomObject]@{
            Status       = 'empty'
            PaneId       = $PaneId
            SnapshotTail = ''
            ExitReason   = ''
        }
    }

    # Find last non-empty line
    $lastLine = Get-LastNonEmptyLine -Text $text

    if ($null -eq $lastLine) {
        return [PSCustomObject]@{
            Status       = 'empty'
            PaneId       = $PaneId
            SnapshotTail = ''
            ExitReason   = ''
        }
    }

    $lines = $text -split "\r?\n"
    $trimmed = $lastLine.TrimStart()
    $tail = if ($lines.Length -le 12) {
        $text
    } else {
        ($lines[($lines.Length - 12)..($lines.Length - 1)] -join [Environment]::NewLine)
    }
    $exitReason = ''
    $snapshotHash = Get-ContentHash -Text $text

    if (Test-CodexApprovalPromptText -Text $text) {
        return [PSCustomObject]@{
            Status       = 'approval_waiting'
            PaneId       = $PaneId
            SnapshotTail = $tail
            SnapshotHash = $snapshotHash
            ExitReason   = ''
        }
    }

    if ($Agent -eq 'codex' -and (Test-CodexContextExhaustionText -Text $tail)) {
        $exitReason = 'context_exhausted'
    }

    # ready: agent prompt visible
    if (Test-AgentPromptText -Text $tail -Agent $Agent) {
        Save-MonitorSnapshot -PaneId $PaneId -Hash (Get-ContentHash -Text $text) -Timestamp (Get-Date -Format o)
        return [PSCustomObject]@{
            Status       = 'ready'
            PaneId       = $PaneId
            SnapshotTail = $tail
            SnapshotHash = $snapshotHash
            ExitReason   = ''
        }
    }

    # crashed: PowerShell prompt visible (PS C:\) - Codex exited
    if ($trimmed -match '^PS [A-Z]:\\') {
        if ($Role -eq 'Builder') {
            Save-MonitorSnapshot -PaneId $PaneId -Hash (Get-ContentHash -Text $text) -Timestamp (Get-Date -Format o)
            return [PSCustomObject]@{
                Status       = 'ready'
                PaneId       = $PaneId
                SnapshotTail = $tail
                SnapshotHash = $snapshotHash
                ExitReason   = 'exec_completed'
            }
        }

        return [PSCustomObject]@{
            Status       = 'crashed'
            PaneId       = $PaneId
            SnapshotTail = $tail
            SnapshotHash = $snapshotHash
            ExitReason   = $exitReason
        }
    }

    # hung: no output change for threshold seconds
    $currentHash = $snapshotHash
    $now = Get-Date
    $previous = Get-MonitorSnapshot -PaneId $PaneId

    if ($null -ne $previous -and $previous.hash -eq $currentHash) {
        try {
            $previousTime = [System.DateTimeOffset]::Parse($previous.timestamp)
            $elapsed = ($now - $previousTime.LocalDateTime).TotalSeconds
            if ($elapsed -ge $HungThreshold) {
                return [PSCustomObject]@{
                    Status       = 'hung'
                    PaneId       = $PaneId
                    SnapshotTail = $tail
                    SnapshotHash = $snapshotHash
                    ExitReason   = ''
                }
            }
        } catch {
            # If timestamp parse fails, treat as first observation
        }
    } else {
        # Output changed - save new snapshot
        Save-MonitorSnapshot -PaneId $PaneId -Hash $currentHash -Timestamp ($now.ToString('o'))
    }

    # busy: Codex running a task (no prompt, output changing)
    return [PSCustomObject]@{
        Status       = 'busy'
        PaneId       = $PaneId
        SnapshotTail = $tail
        SnapshotHash = $snapshotHash
        ExitReason   = ''
    }
}

# ---------------------------------------------------------------------------
# 2. Invoke-AgentRespawn
# ---------------------------------------------------------------------------

function Invoke-AgentRespawn {
    <#
    .SYNOPSIS
    Restarts an agent (Codex/Claude) in a crashed pane.

    .OUTPUTS
    PSCustomObject with: Success (bool), PaneId, Message
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [string]$ManifestPath = '',
        [int]$ReadyTimeoutSeconds = 60
    )

    # Build launch command (same logic as orchestra-start Get-AgentLaunchCommand)
    $launchCommand = $null
    $paneExecMode = $false
    $paneRole = ''
    switch ($Agent.Trim().ToLowerInvariant()) {
        'codex' {
            $escapedProject = "'" + ($ProjectDir -replace "'", "''") + "'"
            $escapedWorktree = "'" + ($GitWorktreeDir -replace "'", "''") + "'"
            $launchCommand = "codex -c model=$Model --full-auto -C $escapedProject --add-dir $escapedWorktree"
        }
        'claude' {
            $launchCommand = 'claude --permission-mode bypassPermissions'
        }
        default {
            return [PSCustomObject]@{
                Success = $false
                PaneId  = $PaneId
                Message = "Unsupported agent: $Agent"
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ManifestPath) -and (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        try {
            $manifestContent = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
            $manifest = ConvertFrom-MonitorManifest -Content $manifestContent
            foreach ($manifestPane in $manifest.Panes.GetEnumerator()) {
                $manifestPaneValue = $manifestPane.Value
                $manifestPaneId = [string](Get-MonitorPropertyValue -InputObject $manifestPaneValue -Name 'pane_id' -Default '')
                if ($manifestPaneId -ne $PaneId) {
                    continue
                }

                $paneRole = [string](Get-MonitorPropertyValue -InputObject $manifestPaneValue -Name 'role' -Default '')
                $execModeValue = [string](Get-MonitorPropertyValue -InputObject $manifestPaneValue -Name 'exec_mode' -Default '')
                $paneExecMode = $execModeValue.Trim().ToLowerInvariant() -eq 'true'
                break
            }
        } catch {
        }
    }

    try {
        Invoke-MonitorWinsmux -Arguments @('respawn-pane', '-k', '-t', $PaneId, '-c', $ProjectDir)
        Wait-MonitorPaneShellReady -PaneId $PaneId
        if (-not $paneExecMode) {
            Send-MonitorBridgeCommand -PaneId $PaneId -Text $launchCommand
        }
    } catch {
        return [PSCustomObject]@{
            Success = $false
            PaneId  = $PaneId
            Message = "Exception respawning pane ${PaneId}: $($_.Exception.Message)"
        }
    }

    # Poll for ready state
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $status = Get-PaneAgentStatus -PaneId $PaneId -Agent $Agent -Role $paneRole
        if ($status.Status -eq 'ready') {
            $successMessage = if ($paneExecMode) {
                "Pane respawned successfully in exec_mode for pane $PaneId"
            } else {
                "Agent respawned successfully in pane $PaneId"
            }
            return [PSCustomObject]@{
                Success = $true
                PaneId  = $PaneId
                Message = $successMessage
            }
        }
    }

    return [PSCustomObject]@{
        Success = $false
        PaneId  = $PaneId
        Message = "Timed out waiting for agent ready in pane $PaneId after ${ReadyTimeoutSeconds}s"
    }
}

# ---------------------------------------------------------------------------
# 3. Invoke-AgentMonitorCycle
# ---------------------------------------------------------------------------

function Invoke-AgentMonitorCycle {
    <#
    .SYNOPSIS
    Runs one monitoring cycle: check all panes, respawn crashed ones.

    .OUTPUTS
    PSCustomObject with: Checked (int), Crashed (int), Respawned (int), IdleAlerts (int), Stalls (int), Results (array)
    #>
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [string]$SessionName = 'winsmux-orchestra',
        [Alias('HungThreshold')]
        [int]$IdleThreshold = $script:AgentMonitorDefaultHungThreshold
    )

    $projectDir = Split-Path (Split-Path $ManifestPath -Parent) -Parent

    # Read manifest to get pane assignments
    if (-not (Test-Path $ManifestPath -PathType Leaf)) {
        throw "Manifest not found: $ManifestPath"
    }

    $content = Get-Content -Path $ManifestPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Manifest is empty: $ManifestPath"
    }

    # Parse manifest (orchestra-start format: session + panes list)
    $manifest = ConvertFrom-MonitorManifest -Content $content

    if ($null -eq $manifest -or $manifest.Panes.Count -eq 0) {
        return [PSCustomObject]@{
            Checked   = 0
            Crashed   = 0
            Respawned = 0
            ApprovalWaiting = 0
            Results   = @()
        }
    }

    # Load logger for structured logging
    $loggerScript = Join-Path $scriptDir 'logger.ps1'
    $loggerAvailable = $false
    if (Test-Path $loggerScript -PathType Leaf) {
        try {
            . $loggerScript
            $loggerAvailable = $true
        } catch {
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $checkedCount = 0
    $crashedCount = 0
    $respawnedCount = 0
    $approvalWaitingCount = 0
    $idleAlertCount = 0
    $stallCount = 0
    $cycleNow = Get-Date

    foreach ($label in $manifest.Panes.Keys) {
        $pane = $manifest.Panes[$label]
        $paneId = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'pane_id' -Default '')
        $role = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'role' -Default '')

        if ([string]::IsNullOrWhiteSpace($paneId)) {
            continue
        }

        # Determine agent config for this role
        $roleAgentConfig = $null
        try {
            $roleAgentConfig = Get-RoleAgentConfig -Role $role -Settings $Settings
        } catch {
            # Fallback to default settings
            $roleAgentConfig = [PSCustomObject]@{
                Agent = [string]$Settings.agent
                Model = [string]$Settings.model
            }
        }

        $agentName = [string]$roleAgentConfig.Agent
        $modelName = [string]$roleAgentConfig.Model

        $checkedCount++
        $status = Get-PaneAgentStatus -PaneId $paneId -Agent $agentName -Role $role -HungThreshold $IdleThreshold
        $statusName = [string](Get-MonitorPropertyValue -InputObject $status -Name 'Status' -Default '')
        $statusExitReason = [string](Get-MonitorPropertyValue -InputObject $status -Name 'ExitReason' -Default '')
        $statusSnapshotTail = [string](Get-MonitorPropertyValue -InputObject $status -Name 'SnapshotTail' -Default '')
        $statusSnapshotHash = [string](Get-MonitorPropertyValue -InputObject $status -Name 'SnapshotHash' -Default '')

        $result = [PSCustomObject]@{
            Label      = $label
            PaneId     = $paneId
            Role       = $role
            Status     = $statusName
            ExitReason = $statusExitReason
            Respawned  = $false
            IdleAlerted = $false
            StallDetected = $false
            Message    = ''
        }

        if ($statusName -eq 'approval_waiting') {
            $approvalWaitingCount++
            $approvalMessage = "Commander alert: $label ($paneId) awaiting approval"
            $result.Message = $approvalMessage
            Write-Output $approvalMessage
            try {
                Send-MonitorTelegramAlert -Message $approvalMessage | Out-Null
            } catch {
            }
        }

        $idleAlert = Update-MonitorIdleAlertState `
            -PaneId $paneId `
            -Label $label `
            -Role $role `
            -Status $statusName `
            -SnapshotTail $statusSnapshotTail `
            -IdleThresholdSeconds $IdleThreshold `
            -Now $cycleNow

        if ($idleAlert.ShouldAlert) {
            $idleAlertCount++
            $result.IdleAlerted = $true
            $result.Message = $idleAlert.Message
            Write-Output $idleAlert.Message
            try {
                Send-MonitorTelegramAlert -Message $idleAlert.Message | Out-Null
            } catch {
            }
        }

        $stallDetected = Test-BuilderStall -PaneId $paneId -Role $role -Status $statusName -SnapshotHash $statusSnapshotHash
        if ($stallDetected) {
            $stallCount++
            $result.StallDetected = $true
            $stallMessage = "Commander alert: stalled Builder pane $label ($paneId)"
            $result.Message = $stallMessage
            Write-Output $stallMessage
            try {
                Send-MonitorTelegramAlert -Message $stallMessage | Out-Null
            } catch {
            }
        }

        # Log the status check
        if ($loggerAvailable) {
            try {
                    Write-OrchestraLog -ProjectDir $projectDir -SessionName $SessionName `
                    -Event 'monitor.status' -Level 'debug' `
                    -Message "Pane $label ($paneId): $statusName" `
                    -Role $role -PaneId $paneId `
                    -Data ([ordered]@{ status = $statusName; exit_reason = $statusExitReason }) | Out-Null
            } catch {
            }
        }

        if ($statusName -eq 'crashed' -or ($statusName -eq 'ready' -and $statusExitReason -eq 'exec_completed')) {
            $crashedCount++

            # Determine launch directory and git worktree dir
            $launchDir = $projectDir
            $launchGitWorktreeDir = $null
            $launchGitWorktreeDir = [string](Get-MonitorPropertyValue -InputObject $manifest.Session -Name 'git_worktree_dir' -Default '')

            # Builder panes use their worktree path
            $builderWorktreePath = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'builder_worktree_path' -Default '')

            if (-not [string]::IsNullOrWhiteSpace($builderWorktreePath) -and (Test-Path $builderWorktreePath -PathType Container)) {
                $launchDir = $builderWorktreePath
                # Derive git worktree dir for the builder worktree
                $dotGitPath = Join-Path $builderWorktreePath '.git'
                if (Test-Path $dotGitPath -PathType Leaf) {
                    $raw = (Get-Content -Path $dotGitPath -Raw -Encoding UTF8).Trim()
                    if ($raw -match '^gitdir:\s*(.+)$') {
                        $launchGitWorktreeDir = [System.IO.Path]::GetFullPath($Matches[1].Trim())
                    }
                } elseif (Test-Path $dotGitPath -PathType Container) {
                    $launchGitWorktreeDir = (Get-Item -LiteralPath $dotGitPath -Force).FullName
                }
            }

            if ([string]::IsNullOrWhiteSpace($launchGitWorktreeDir)) {
                $launchGitWorktreeDir = $launchDir
            }

            # Log respawn attempt
            if ($loggerAvailable) {
                try {
                    $respawnMessage = if ($statusExitReason -eq 'exec_completed') {
                        "Respawning Builder after exec completion in pane $label ($paneId)"
                    } elseif ($statusExitReason -eq 'context_exhausted' -and $role -eq 'Builder') {
                        "Respawning Builder worktree after context exhaustion in pane $label ($paneId)"
                    } else {
                        "Respawning crashed agent in pane $label ($paneId)"
                    }
                    Write-OrchestraLog -ProjectDir $projectDir -SessionName $SessionName `
                        -Event 'monitor.respawn.start' -Level 'warn' `
                        -Message $respawnMessage `
                        -Role $role -PaneId $paneId `
                        -Data ([ordered]@{ agent = $agentName; model = $modelName; launch_dir = $launchDir; exit_reason = $statusExitReason }) | Out-Null
                } catch {
                }
            }

            $respawnResult = Invoke-AgentRespawn `
                -PaneId $paneId `
                -Agent $agentName `
                -Model $modelName `
                -ProjectDir $launchDir `
                -GitWorktreeDir $launchGitWorktreeDir `
                -ManifestPath $ManifestPath

            $result.Respawned = $respawnResult.Success
            $result.Message = $respawnResult.Message

            if ($respawnResult.Success) {
                $respawnedCount++
            }

            # Log respawn result
            if ($loggerAvailable) {
                $logLevel = if ($respawnResult.Success) { 'info' } else { 'error' }
                try {
                    Write-OrchestraLog -ProjectDir $projectDir -SessionName $SessionName `
                        -Event 'monitor.respawn.result' -Level $logLevel `
                        -Message $respawnResult.Message `
                        -Role $role -PaneId $paneId `
                        -Data ([ordered]@{ success = $respawnResult.Success }) | Out-Null
                } catch {
                }
            }
        }

        $results.Add($result)
    }

    # Log cycle summary
    if ($loggerAvailable) {
        try {
                Write-OrchestraLog -ProjectDir $projectDir -SessionName $SessionName `
                    -Event 'monitor.cycle' -Level 'info' `
                -Message "Monitor cycle: checked=$checkedCount crashed=$crashedCount respawned=$respawnedCount approval_waiting=$approvalWaitingCount idle_alerts=$idleAlertCount stalls=$stallCount" `
                -Data ([ordered]@{ checked = $checkedCount; crashed = $crashedCount; respawned = $respawnedCount; approval_waiting = $approvalWaitingCount; idle_alerts = $idleAlertCount; stalls = $stallCount }) | Out-Null
        } catch {
        }
    }

    return [PSCustomObject]@{
        Checked   = $checkedCount
        Crashed   = $crashedCount
        Respawned = $respawnedCount
        ApprovalWaiting = $approvalWaitingCount
        IdleAlerts = $idleAlertCount
        Stalls = $stallCount
        Results   = @($results)
    }
}

# ---------------------------------------------------------------------------
# Manifest parser (orchestra-start format)
# ---------------------------------------------------------------------------

function ConvertFrom-MonitorManifest {
    <#
    .SYNOPSIS
    Parses the orchestra-start manifest format (session metadata + panes list).
    #>
    param([Parameter(Mandatory = $true)][string]$Content)

    $manifest = [PSCustomObject]@{
        Session = [ordered]@{}
        Panes   = [ordered]@{}
    }

    $section = $null
    $currentPane = $null

    foreach ($rawLine in ($Content -split "\r?\n")) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
            continue
        }

        # Top-level key
        if ($line -match '^version:\s*') {
            continue
        }

        if ($line -match '^(session|panes):\s*$') {
            if ($section -eq 'panes' -and $null -ne $currentPane) {
                $label = [string]$currentPane.label
                if (-not [string]::IsNullOrWhiteSpace($label)) {
                    $paneObj = [PSCustomObject]@{}
                    foreach ($entry in $currentPane.GetEnumerator()) {
                        Add-Member -InputObject $paneObj -MemberType NoteProperty -Name $entry.Key -Value $entry.Value
                    }
                    $manifest.Panes[$label] = $paneObj
                }
                $currentPane = $null
            }

            $section = $Matches[1]
            continue
        }

        # Session properties (2-space indent)
        if ($section -eq 'session' -and $line -match '^\s{2}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
            $value = $Matches[2]
            # Strip surrounding quotes
            if ($value.Length -ge 2) {
                if (($value.StartsWith("'") -and $value.EndsWith("'")) -or
                    ($value.StartsWith('"') -and $value.EndsWith('"'))) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
            }
            $manifest.Session[$Matches[1]] = $value
            continue
        }

        # Pane list item start
        if ($section -eq 'panes' -and $line -match '^\s{2}-\s+label:\s*(.*?)\s*$') {
            if ($null -ne $currentPane) {
                $label = [string]$currentPane.label
                if (-not [string]::IsNullOrWhiteSpace($label)) {
                    $paneObj = [PSCustomObject]@{}
                    foreach ($entry in $currentPane.GetEnumerator()) {
                        Add-Member -InputObject $paneObj -MemberType NoteProperty -Name $entry.Key -Value $entry.Value
                    }
                    $manifest.Panes[$label] = $paneObj
                }
            }

            $value = $Matches[1]
            if ($value.Length -ge 2) {
                if (($value.StartsWith("'") -and $value.EndsWith("'")) -or
                    ($value.StartsWith('"') -and $value.EndsWith('"'))) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
            }
            $currentPane = [ordered]@{ label = $value }
            continue
        }

        # Pane properties (4-space indent)
        if ($section -eq 'panes' -and $line -match '^\s{4}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
            if ($null -eq $currentPane) {
                continue
            }

            $value = $Matches[2]
            if ($value.Length -ge 2) {
                if (($value.StartsWith("'") -and $value.EndsWith("'")) -or
                    ($value.StartsWith('"') -and $value.EndsWith('"'))) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
            }
            if ($value -eq 'null') {
                $value = ''
            }
            $currentPane[$Matches[1]] = $value
            continue
        }
    }

    # Save last pane
    if ($section -eq 'panes' -and $null -ne $currentPane) {
        $label = [string]$currentPane.label
        if (-not [string]::IsNullOrWhiteSpace($label)) {
            $paneObj = [PSCustomObject]@{}
            foreach ($entry in $currentPane.GetEnumerator()) {
                Add-Member -InputObject $paneObj -MemberType NoteProperty -Name $entry.Key -Value $entry.Value
            }
            $manifest.Panes[$label] = $paneObj
        }
    }

    return $manifest
}

# ---------------------------------------------------------------------------
# Direct invocation: run one monitoring cycle
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    $resolvedProjectDir = $ProjectDir
    if ([string]::IsNullOrWhiteSpace($resolvedProjectDir)) {
        $resolvedProjectDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    }

    $manifestPath = Join-Path (Join-Path $resolvedProjectDir '.winsmux') 'manifest.yaml'
    if (-not (Test-Path $manifestPath -PathType Leaf)) {
        Write-Error "No manifest found at $manifestPath. Is an Orchestra session running?"
        exit 1
    }

    $settings = Get-BridgeSettings
    $result = Invoke-AgentMonitorCycle `
        -Settings $settings `
        -ManifestPath $manifestPath `
        -SessionName $SessionName `
        -HungThreshold $HungThresholdSeconds

    Write-Output "Monitor cycle complete: checked=$($result.Checked) crashed=$($result.Crashed) respawned=$($result.Respawned)"
    foreach ($r in $result.Results) {
        $respawnTag = if ($r.Respawned) { ' [RESPAWNED]' } else { '' }
        $reasonTag = if ($r.ExitReason) { " [$($r.ExitReason)]" } else { '' }
        $messageTag = if ($r.Message) { " ($($r.Message))" } else { '' }
        Write-Output ("  {0,-14} {1,-8} {2,-10} {3}{4}{5}" -f $r.Label, $r.PaneId, $r.Status, $respawnTag, $reasonTag, $messageTag)
    }

    if ($result.Crashed -gt 0 -and $result.Respawned -lt $result.Crashed) {
        exit 1
    }
}
