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
    [int]$HungThresholdSeconds = 60,
    [int]$ContextResetThresholdPercent = 10
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = $PSScriptRoot
. "$scriptDir/settings.ps1"
. "$scriptDir/agent-readiness.ps1"
. "$scriptDir/pane-control.ps1"
. "$scriptDir/orchestra-state.ps1"
. "$scriptDir/clm-safe-io.ps1"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$script:HungSnapshotDir = Join-Path $env:TEMP 'winsmux\monitor_snapshots'
$script:IdleStateDir = Join-Path $env:TEMP 'winsmux\monitor_idle'
$script:AgentMonitorDefaultHungThreshold = 60
$script:IdleAlertRepeatSeconds = 300
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
        throw (Get-WinsmuxOperatorNotFoundMessage)
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

    Write-WinsmuxTextFile -Path $path -Content ($record | ConvertTo-Json -Compress)
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
    Write-WinsmuxTextFile -Path $path -Content ($record | ConvertTo-Json -Compress)
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
        $message = "Operator alert: idle pane $Label ($PaneId, role=$Role)"
        Save-MonitorIdleState -PaneId $PaneId -ReadySince $readySince -AlertSent $true -LastAlertAt $Now
        $result['ShouldAlert'] = $true
        $result['Message'] = $message
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

function Test-MonitorAutoApprovePromptText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $tailText = (@(Get-RecentNonEmptyLines -Text $Text -MaxCount 20) -join [Environment]::NewLine)
    if ([string]::IsNullOrWhiteSpace($tailText)) {
        return $false
    }

    $patterns = @(
        '(?im)\btrust\s+this\s+folder\b',
        '(?im)\benter\s+to\s+confirm\b',
        '(?im)\byes,\s*i\s+trust\b'
    )

    foreach ($pattern in $patterns) {
        if ($tailText -match $pattern) {
            return $true
        }
    }

    return $false
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

function Get-MonitorContextRemainingPercent {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $patterns = @(
        '(?im)(?<value>\d+(?:\.\d+)?)%\s+(?:context\s+)?left\b',
        '(?im)\b(?:context\s+left|tokens?\s+remaining)\s*[:=]\s*(?<value>\d+(?:\.\d+)?)%\b'
    )

    foreach ($pattern in $patterns) {
        $matches = [regex]::Matches($Text, $pattern)
        if ($matches.Count -gt 0) {
            $rawValue = $matches[$matches.Count - 1].Groups['value'].Value
            $parsedValue = 0.0
            if ([double]::TryParse($rawValue, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedValue)) {
                return $parsedValue
            }
        }
    }

    return $null
}

function Test-PowerShellPromptText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $lastLine = Get-LastNonEmptyLine -Text $Text
    if ($null -eq $lastLine) {
        return $false
    }

    return $lastLine.TrimStart() -match '^PS [A-Z]:\\'
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

function Invoke-MonitorAutoApprovePrompt {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    Invoke-MonitorWinsmux -Arguments @('send-keys', '-t', $PaneId, 'Enter')

    return [ordered]@{
        Success = $true
        PaneId  = $PaneId
        Message = "Auto-approved trust prompt in pane $PaneId"
    }
}

function Get-MonitorEventsPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path (Join-Path $ProjectDir '.winsmux') 'events.jsonl'
}

function Get-MonitorProjectDir {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $projectDir = [string](Get-MonitorPropertyValue -InputObject $Manifest.Session -Name 'project_dir' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($projectDir)) {
        return $projectDir
    }

    return Split-Path (Split-Path $ManifestPath -Parent) -Parent
}

function Write-MonitorEvent {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [string]$SessionName = 'winsmux-orchestra',
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$Message = '',
        [string]$Label = '',
        [string]$PaneId = '',
        [string]$Role = '',
        [string]$Status = '',
        [string]$ExitReason = '',
        [AllowNull()]$Data = $null
    )

    if ([string]::IsNullOrWhiteSpace($ProjectDir) -or [string]::IsNullOrWhiteSpace($Event)) {
        return $null
    }

    try {
        $eventsPath = Get-MonitorEventsPath -ProjectDir $ProjectDir

        $record = [ordered]@{
            timestamp   = (Get-Date).ToString('o')
            session     = if ([string]::IsNullOrWhiteSpace($SessionName)) { 'winsmux-orchestra' } else { $SessionName }
            event       = $Event
            message     = if ($null -eq $Message) { '' } else { $Message }
            label       = if ($null -eq $Label) { '' } else { $Label }
            pane_id     = if ($null -eq $PaneId) { '' } else { $PaneId }
            role        = if ($null -eq $Role) { '' } else { $Role }
            status      = if ($null -eq $Status) { '' } else { $Status }
            exit_reason = if ($null -eq $ExitReason) { '' } else { $ExitReason }
            data        = if ($null -eq $Data) { [ordered]@{} } else { $Data }
        }

        $line = ($record | ConvertTo-Json -Compress -Depth 10)
        Write-WinsmuxTextFile -Path $eventsPath -Content $line -Append
        return $record
    } catch {
        return $null
    }
}

function Get-MonitorOperatorMailboxChannel {
    param([string]$SessionName = 'winsmux-orchestra')

    $resolvedSessionName = if ([string]::IsNullOrWhiteSpace($SessionName)) {
        'winsmux-orchestra'
    } else {
        $SessionName.Trim()
    }

    $safeSessionName = [regex]::Replace($resolvedSessionName, '[^A-Za-z0-9_-]', '-')
    return "$safeSessionName-operator"
}

function Send-MonitorOperatorMailboxMessage {
    param(
        [string]$SessionName = 'winsmux-orchestra',
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$Message = '',
        [string]$Label = '',
        [string]$PaneId = '',
        [string]$Role = '',
        [string]$Status = '',
        [string]$ExitReason = '',
        [AllowNull()]$Data = $null
    )

    if ([string]::IsNullOrWhiteSpace($Event)) {
        return $false
    }

    $bridgeScript = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..\..\scripts\winsmux-core.ps1'))
    $channel = Get-MonitorOperatorMailboxChannel -SessionName $SessionName
    $payload = [ordered]@{
        from      = if ([string]::IsNullOrWhiteSpace($Label)) { 'agent-monitor' } else { $Label }
        to        = 'Operator'
        content   = [ordered]@{
            session     = if ([string]::IsNullOrWhiteSpace($SessionName)) { 'winsmux-orchestra' } else { $SessionName }
            event       = $Event
            message     = if ($null -eq $Message) { '' } else { $Message }
            label       = if ($null -eq $Label) { '' } else { $Label }
            pane_id     = if ($null -eq $PaneId) { '' } else { $PaneId }
            role        = if ($null -eq $Role) { '' } else { $Role }
            status      = if ($null -eq $Status) { '' } else { $Status }
            exit_reason = if ($null -eq $ExitReason) { '' } else { $ExitReason }
            data        = if ($null -eq $Data) { [ordered]@{} } else { $Data }
        }
        timestamp = (Get-Date).ToString('o')
    }

    $payloadJson = $payload | ConvertTo-Json -Compress -Depth 10
    & pwsh -NoProfile -File $bridgeScript 'mailbox-send' $channel $payloadJson 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to send mailbox message on channel $channel."
    }

    return $true
}

function Get-MonitorStateEventName {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$ExitReason = ''
    )

    switch ($Status) {
        'approval_waiting' { return 'pane.approval_waiting' }
        'busy' { return 'pane.busy' }
        'crashed' { return 'pane.crashed' }
        'empty' { return 'pane.empty' }
        'bootstrap_invalid' { return 'pane.bootstrap_invalid' }
        'hung' { return 'pane.hung' }
        'ready' {
            if ($ExitReason -eq 'exec_completed') {
                return 'pane.completed'
            }

            return 'pane.ready'
        }
        'waiting_for_dispatch' { return 'pane.waiting_for_dispatch' }
        default { return '' }
    }
}

function Get-MonitorStateEventMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Status
    )

    switch ($Event) {
        'pane.approval_waiting' { return "Pane $Label ($PaneId) awaiting approval." }
        'pane.busy' { return "Pane $Label ($PaneId) is busy." }
        'pane.completed' { return "Pane $Label ($PaneId) completed." }
        'pane.crashed' { return "Pane $Label ($PaneId) crashed." }
        'pane.empty' { return "Pane $Label ($PaneId) is empty." }
        'pane.bootstrap_invalid' { return "Pane $Label ($PaneId) failed bootstrap verification." }
        'pane.hung' { return "Pane $Label ($PaneId) is hung." }
        'pane.ready' { return "Pane $Label ($PaneId) is ready." }
        'pane.waiting_for_dispatch' { return "Pane $Label ($PaneId) is waiting for dispatch." }
        default { return "Pane $Label ($PaneId) detected as $Status." }
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
    PSCustomObject with: Status (ready|waiting_for_dispatch|busy|approval_waiting|crashed|hung|empty), PaneId, SnapshotTail, ExitReason
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [string]$Agent = '',
        [string]$Role = '',
        [bool]$ExecMode = $false,
        [int]$HungThreshold = $script:AgentMonitorDefaultHungThreshold
    )

    $snapshot = $null
    try {
        $snapshot = Invoke-MonitorWinsmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') -CaptureOutput
    } catch {
        Write-Warning "TASK-231: pane $PaneId not reachable via capture-pane (may be dead). Error: $($_.Exception.Message)"
        return [ordered]@{
            Status       = 'empty'
            PaneId       = $PaneId
            SnapshotTail = ''
            ExitReason   = ''
        }
    }

    $text = ($snapshot | Out-String).TrimEnd()

    # empty: pane has no content
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [ordered]@{
            Status       = 'empty'
            PaneId       = $PaneId
            SnapshotTail = ''
            ExitReason   = ''
        }
    }

    # Find last non-empty line
    $lastLine = Get-LastNonEmptyLine -Text $text

    if ($null -eq $lastLine) {
        return [ordered]@{
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
    $approvalAction = ''

    if (Test-MonitorAutoApprovePromptText -Text $text) {
        $approvalAction = 'enter'
    }

    if ($approvalAction -eq 'enter' -or ($Agent -eq 'codex' -and (Test-CodexApprovalPromptText -Text $text))) {
        return [ordered]@{
            Status         = 'approval_waiting'
            PaneId         = $PaneId
            SnapshotTail   = $tail
            SnapshotHash   = $snapshotHash
            ApprovalAction = $approvalAction
            ExitReason     = ''
        }
    }

    if ($Agent -eq 'codex' -and (Test-CodexContextExhaustionText -Text $tail)) {
        $exitReason = 'context_exhausted'
    }

    # ready: agent prompt visible
    if (Test-AgentPromptText -Text $tail -Agent $Agent) {
        Save-MonitorSnapshot -PaneId $PaneId -Hash (Get-ContentHash -Text $text) -Timestamp (Get-Date -Format o)
        return [ordered]@{
            Status       = 'ready'
            PaneId       = $PaneId
            SnapshotTail = $tail
            SnapshotHash = $snapshotHash
            ExitReason   = ''
        }
    }

    # crashed: PowerShell prompt visible (PS C:\) - Codex exited
    if (Test-PowerShellPromptText -Text $text) {
        if ($ExecMode) {
            Save-MonitorSnapshot -PaneId $PaneId -Hash (Get-ContentHash -Text $text) -Timestamp (Get-Date -Format o)
            return [ordered]@{
                Status       = 'waiting_for_dispatch'
                PaneId       = $PaneId
                SnapshotTail = $tail
                SnapshotHash = $snapshotHash
                ExitReason   = ''
            }
        }

        if ($Role -eq 'Builder') {
            Save-MonitorSnapshot -PaneId $PaneId -Hash (Get-ContentHash -Text $text) -Timestamp (Get-Date -Format o)
            return [ordered]@{
                Status       = 'ready'
                PaneId       = $PaneId
                SnapshotTail = $tail
                SnapshotHash = $snapshotHash
                ExitReason   = 'exec_completed'
            }
        }

        return [ordered]@{
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
                return [ordered]@{
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
    return [ordered]@{
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
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [string]$RootPath = '',
        [string]$ManifestPath = '',
        [int]$ReadyTimeoutSeconds = 60
    )

    $launchCommand = $null
    $paneExecMode = $false
    $paneRole = ''

    $capabilityRootPath = $RootPath
    if ([string]::IsNullOrWhiteSpace($capabilityRootPath)) {
        $capabilityRootPath = $ProjectDir
        if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
            $manifestDir = Split-Path -Parent $ManifestPath
            if (-not [string]::IsNullOrWhiteSpace($manifestDir) -and (Split-Path -Leaf $manifestDir) -eq '.winsmux') {
                $capabilityRootPath = Split-Path -Parent $manifestDir
            }
        }
    }

    $statusAgentName = $Agent
    try {
        $providerCapability = Resolve-BridgeProviderCapability -ProviderId $Agent -RootPath $capabilityRootPath -RequireWhenRegistryPresent
        $capabilityAdapter = [string](Get-BridgeProviderCapabilityValue -Capability $providerCapability -Name 'adapter' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($capabilityAdapter)) {
            $statusAgentName = $capabilityAdapter
        }

        $launchCommand = Get-BridgeProviderLaunchCommand `
            -ProviderId $Agent `
            -Model $Model `
            -ProjectDir $ProjectDir `
            -GitWorktreeDir $GitWorktreeDir `
            -RootPath $capabilityRootPath
    } catch {
        return [ordered]@{
            Success = $false
            PaneId  = $PaneId
            Message = $_.Exception.Message
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
                $manifestCapabilityAdapter = [string](Get-MonitorPropertyValue -InputObject $manifestPaneValue -Name 'capability_adapter' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($manifestCapabilityAdapter)) {
                    $statusAgentName = $manifestCapabilityAdapter
                }
                break
            }
        } catch {
        }
    }

    if ($paneExecMode) {
        $currentStatus = Get-PaneAgentStatus -PaneId $PaneId -Agent $statusAgentName -Role $paneRole -ExecMode $true
        if ($currentStatus.Status -eq 'waiting_for_dispatch') {
            return [ordered]@{
                Success = $true
                PaneId  = $PaneId
                Message = "Pane $PaneId is waiting for dispatch in exec_mode; skipping respawn"
            }
        }
    }

    try {
        Invoke-MonitorWinsmux -Arguments @('respawn-pane', '-k', '-t', $PaneId, '-c', $ProjectDir)
        Wait-MonitorPaneShellReady -PaneId $PaneId
        if (-not $paneExecMode) {
            Send-MonitorBridgeCommand -PaneId $PaneId -Text $launchCommand
        }
    } catch {
        return [ordered]@{
            Success = $false
            PaneId  = $PaneId
            Message = "Exception respawning pane ${PaneId}: $($_.Exception.Message)"
        }
    }

    # Poll for ready state
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $status = Get-PaneAgentStatus -PaneId $PaneId -Agent $statusAgentName -Role $paneRole -ExecMode $paneExecMode
        if ($status.Status -eq 'ready') {
            if (-not [string]::IsNullOrWhiteSpace($ManifestPath) -and (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
                try {
                    $paneLabel = Get-MonitorPaneTitle -PaneId $PaneId
                    if (-not [string]::IsNullOrWhiteSpace($paneLabel)) {
                        Update-MonitorManifestPaneLabel -ManifestPath $ManifestPath -PaneId $PaneId -Label $paneLabel | Out-Null
                    }
                } catch {
                }
            }

            $successMessage = if ($paneExecMode) {
                "Pane respawned successfully in exec_mode for pane $PaneId"
            } else {
                "Agent respawned successfully in pane $PaneId"
            }
            return [ordered]@{
                Success = $true
                PaneId  = $PaneId
                Message = $successMessage
            }
        }
    }

    return [ordered]@{
        Success = $false
        PaneId  = $PaneId
        Message = "Timed out waiting for agent ready in pane $PaneId after ${ReadyTimeoutSeconds}s"
    }
}

function ConvertFrom-MonitorYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return ''
    }

    $text = $Value.ToString().Trim()
    if ($text.Length -ge 2) {
        if (($text.StartsWith('"') -and $text.EndsWith('"')) -or
            ($text.StartsWith("'") -and $text.EndsWith("'"))) {
            $text = $text.Substring(1, $text.Length - 2)
        }
    }

    if ($text -eq 'null') {
        return ''
    }

    return $text
}

function ConvertTo-MonitorYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    $text = $Value.ToString()
    if ($text -eq '') {
        return '""'
    }

    if ($text -match '^[A-Za-z0-9._/\\:-]+$') {
        return $text
    }

    return '"' + ($text -replace '"', '\"') + '"'
}

function Get-MonitorPaneTitle {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    $titleOutput = Invoke-MonitorWinsmux -Arguments @('display-message', '-p', '-t', $PaneId, '#{pane_title}') -CaptureOutput
    return (($titleOutput | Out-String).Trim() -split "\r?\n" | Select-Object -Last 1).Trim()
}

function Update-MonitorManifestPaneLabel {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Label) -or -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return $false
    }

    try {
        Set-PaneControlManifestPaneProperties -ManifestPath $ManifestPath -PaneId $PaneId -Properties ([ordered]@{ label = $Label })
        return $true
    } catch {
        return $false
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
        [int]$IdleThreshold = $script:AgentMonitorDefaultHungThreshold,
        [int]$ContextResetThresholdPercent = 10,
        [AllowNull()][System.Collections.IDictionary]$PreviousResults = $null
    )

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
        return [ordered]@{
            Checked   = 0
            Crashed   = 0
            Respawned = 0
            ApprovalWaiting = 0
            ContextResets = 0
            IdleAlerts = 0
            Stalls = 0
            CurrentResults = [ordered]@{}
            Results   = @()
        }
    }

    # Load logger for structured logging
    # NOTE: dot-source logger BEFORE computing $projectDir because
    # logger.ps1 has a param($ProjectDir) that would overwrite our local variable.
    $loggerScript = Join-Path $scriptDir 'logger.ps1'
    $loggerAvailable = $false
    if (Test-Path $loggerScript -PathType Leaf) {
        try {
            . $loggerScript
            $loggerAvailable = $true
        } catch {
        }
    }

    $projectDir = Get-MonitorProjectDir -Manifest $manifest -ManifestPath $ManifestPath
    $paneStateModels = [ordered]@{}
    try {
        $paneStateModels = Sync-OrchestraPaneStateModels -ProjectDir $projectDir -Manifest $manifest
    } catch {
        $paneStateModels = [ordered]@{}
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $currentResults = [ordered]@{}
    $checkedCount = 0
    $crashedCount = 0
    $respawnedCount = 0
    $approvalWaitingCount = 0
    $contextResetCount = 0
    $idleAlertCount = 0
    $stallCount = 0
    $cycleNow = Get-Date

    foreach ($label in $manifest.Panes.Keys) {
        $pane = $manifest.Panes[$label]
        $paneId = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'pane_id' -Default '')
        $role = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'role' -Default '')
        $paneExecMode = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'exec_mode' -Default '').Trim().ToLowerInvariant() -eq 'true'
        $paneStateModel = Get-OrchestraPaneStateModelFromCollection -StateModels $paneStateModels -Label $label -PaneId $paneId

        if ([string]::IsNullOrWhiteSpace($paneId)) {
            continue
        }

        # Determine agent config for this role
        $roleAgentConfig = $null
        if (Get-Command Get-SlotAgentConfig -ErrorAction SilentlyContinue) {
            $roleAgentConfig = Get-SlotAgentConfig -Role $role -SlotId $label -Settings $Settings -RootPath $projectDir
        } else {
            try {
                $roleAgentConfig = Get-RoleAgentConfig -Role $role -Settings $Settings
            } catch {
                # Fallback to default settings when only the legacy role helper is unavailable or malformed.
                $roleAgentConfig = [ordered]@{
                    Agent = [string]$Settings.agent
                    Model = [string]$Settings.model
                }
            }
        }

        $agentName = [string]$roleAgentConfig.Agent
        $modelName = [string]$roleAgentConfig.Model
        $statusAgentName = [string](Get-MonitorPropertyValue -InputObject $roleAgentConfig -Name 'CapabilityAdapter' -Default '')
        if ([string]::IsNullOrWhiteSpace($statusAgentName)) {
            $statusAgentName = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'capability_adapter' -Default '')
        }
        if ([string]::IsNullOrWhiteSpace($statusAgentName)) {
            $statusAgentName = $agentName
        }
        $launchDirFromManifest = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'launch_dir' -Default '')
        $builderWorktreePath = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'builder_worktree_path' -Default '')

        $checkedCount++
        $status = Get-PaneAgentStatus -PaneId $paneId -Agent $statusAgentName -Role $role -ExecMode $paneExecMode -HungThreshold $IdleThreshold
        $statusName = [string](Get-MonitorPropertyValue -InputObject $status -Name 'Status' -Default '')

        # TASK-240: override empty with bootstrap_invalid if manifest says so
        if ($statusName -eq 'empty') {
            $mfStatus = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'status' -Default '')
            if ($mfStatus -eq 'bootstrap_invalid') {
                $statusName = 'bootstrap_invalid'
            }
        }

        $statusExitReason = [string](Get-MonitorPropertyValue -InputObject $status -Name 'ExitReason' -Default '')
        $statusSnapshotTail = [string](Get-MonitorPropertyValue -InputObject $status -Name 'SnapshotTail' -Default '')
        $statusSnapshotHash = [string](Get-MonitorPropertyValue -InputObject $status -Name 'SnapshotHash' -Default '')
        $statusApprovalAction = [string](Get-MonitorPropertyValue -InputObject $status -Name 'ApprovalAction' -Default '')
        $previousStatusName = ''
        if ($null -ne $PreviousResults -and $PreviousResults.Contains($paneId)) {
            $previousStatusName = [string]$PreviousResults[$paneId]
        }
        $currentResults[$paneId] = $statusName

        $result = [ordered]@{
            Label      = $label
            PaneId     = $paneId
            Role       = $role
            Status     = $statusName
            ExitReason = $statusExitReason
            Respawned  = $false
            ContextReset = $false
            ContextRemainingPercent = $null
            IdleAlerted = $false
            StallDetected = $false
            Message    = ''
        }

        if ($previousStatusName -eq 'busy' -and $statusName -eq 'waiting_for_dispatch') {
            $transitionEventData = [ordered]@{
                agent           = $agentName
                model           = $modelName
                exec_mode       = $paneExecMode
                snapshot_hash   = $statusSnapshotHash
                previous_status = $previousStatusName
                current_status  = $statusName
            }
            if (-not [string]::IsNullOrWhiteSpace($launchDirFromManifest)) {
                $transitionEventData['launch_dir'] = $launchDirFromManifest
            }
            if (-not [string]::IsNullOrWhiteSpace($builderWorktreePath)) {
                $transitionEventData['builder_worktree_path'] = $builderWorktreePath
            }

            $transitionEventMessage = Get-MonitorStateEventMessage -Event 'pane.completed' -Label $label -PaneId $paneId -Status $statusName
            Write-MonitorEvent -ProjectDir $projectDir -SessionName $SessionName `
                -Event 'pane.completed' -Message $transitionEventMessage `
                -Label $label -PaneId $paneId -Role $role -Status $statusName -ExitReason $statusExitReason `
                -Data (Merge-OrchestraPaneEventData -StateModel $paneStateModel -Data $transitionEventData) | Out-Null
        }

        $stateEventName = Get-MonitorStateEventName -Status $statusName -ExitReason $statusExitReason
        if (-not [string]::IsNullOrWhiteSpace($stateEventName)) {
            $stateEventData = [ordered]@{
                agent         = $agentName
                model         = $modelName
                exec_mode     = $paneExecMode
                snapshot_hash = $statusSnapshotHash
            }
            if (-not [string]::IsNullOrWhiteSpace($launchDirFromManifest)) {
                $stateEventData['launch_dir'] = $launchDirFromManifest
            }
            if (-not [string]::IsNullOrWhiteSpace($builderWorktreePath)) {
                $stateEventData['builder_worktree_path'] = $builderWorktreePath
            }

            $stateEventMessage = Get-MonitorStateEventMessage -Event $stateEventName -Label $label -PaneId $paneId -Status $statusName
            Write-MonitorEvent -ProjectDir $projectDir -SessionName $SessionName `
                -Event $stateEventName -Message $stateEventMessage `
                -Label $label -PaneId $paneId -Role $role -Status $statusName -ExitReason $statusExitReason `
                -Data (Merge-OrchestraPaneEventData -StateModel $paneStateModel -Data $stateEventData) | Out-Null
        }

        if ($statusName -eq 'approval_waiting') {
            $approvalWaitingCount++
            if ($statusApprovalAction -eq 'enter') {
                try {
                    $approvalResult = Invoke-MonitorAutoApprovePrompt -PaneId $paneId
                    $result['Message'] = [string](Get-MonitorPropertyValue -InputObject $approvalResult -Name 'Message' -Default "Auto-approved trust prompt in pane $paneId")
                    Write-Output $result['Message']
                } catch {
                    $approvalMessage = "Operator alert: $label ($paneId) awaiting approval (auto-approve failed: $($_.Exception.Message))"
                    $result['Message'] = $approvalMessage
                    Write-Output $approvalMessage
                }
            } else {
                $approvalMessage = "Operator alert: $label ($paneId) awaiting approval"
                $result['Message'] = $approvalMessage
                Write-Output $approvalMessage
            }

            try {
                Send-MonitorOperatorMailboxMessage -SessionName $SessionName `
                    -Event 'pane.approval_waiting' -Message $result['Message'] `
                    -Label $label -PaneId $paneId -Role $role -Status $statusName -ExitReason $statusExitReason `
                    -Data (Merge-OrchestraPaneEventData -StateModel $paneStateModel -Data $stateEventData) | Out-Null
            } catch {
            }
        }

        $contextRemainingPercent = Get-MonitorContextRemainingPercent -Text $statusSnapshotTail
        if ($statusAgentName -eq 'codex' -and $statusName -eq 'ready' -and $null -ne $contextRemainingPercent) {
            $result['ContextRemainingPercent'] = $contextRemainingPercent
            if ($contextRemainingPercent -le $ContextResetThresholdPercent) {
                try {
                    Send-MonitorBridgeCommand -PaneId $paneId -Text '/new'
                    $contextResetCount++
                    $result['ContextReset'] = $true
                    Write-MonitorEvent -ProjectDir $projectDir -SessionName $SessionName `
                        -Event 'pane.context_reset' -Message "Reset Codex context in pane $label ($paneId)." `
                        -Label $label -PaneId $paneId -Role $role -Status $statusName -ExitReason $statusExitReason `
                        -Data (Merge-OrchestraPaneEventData -StateModel $paneStateModel -Data ([ordered]@{
                            agent                     = $agentName
                            model                     = $modelName
                            command                   = '/new'
                            context_remaining_percent = $contextRemainingPercent
                            threshold_percent         = $ContextResetThresholdPercent
                            snapshot_hash             = $statusSnapshotHash
                        })) | Out-Null

                    $results.Add($result)
                    continue
                } catch {
                    $result['Message'] = "Failed to reset context for pane $label ($paneId): $($_.Exception.Message)"
                }
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
            $result['IdleAlerted'] = $true
            $result['Message'] = $idleAlert.Message
            Write-Output $idleAlert.Message
            Write-MonitorEvent -ProjectDir $projectDir -SessionName $SessionName `
                -Event 'pane.idle' -Message $idleAlert.Message `
                -Label $label -PaneId $paneId -Role $role -Status $statusName -ExitReason $statusExitReason `
                -Data (Merge-OrchestraPaneEventData -StateModel $paneStateModel -Data ([ordered]@{
                    agent                  = $agentName
                    model                  = $modelName
                    idle_threshold_seconds = $IdleThreshold
                    snapshot_hash          = $statusSnapshotHash
                })) | Out-Null
            try {
                Send-MonitorOperatorMailboxMessage -SessionName $SessionName `
                    -Event 'pane.idle' -Message $idleAlert.Message `
                    -Label $label -PaneId $paneId -Role $role -Status $statusName -ExitReason $statusExitReason `
                    -Data (Merge-OrchestraPaneEventData -StateModel $paneStateModel -Data ([ordered]@{
                        agent                  = $agentName
                        model                  = $modelName
                        idle_threshold_seconds = $IdleThreshold
                        snapshot_hash          = $statusSnapshotHash
                    })) | Out-Null
            } catch {
            }
        }

        $stallDetected = Test-BuilderStall -PaneId $paneId -Role $role -Status $statusName -SnapshotHash $statusSnapshotHash
        if ($stallDetected) {
            $stallCount++
            $result['StallDetected'] = $true
            $stallMessage = "Operator alert: stalled Builder pane $label ($paneId)"
            $result['Message'] = $stallMessage
            Write-Output $stallMessage
            Write-MonitorEvent -ProjectDir $projectDir -SessionName $SessionName `
                -Event 'pane.stalled' -Message $stallMessage `
                -Label $label -PaneId $paneId -Role $role -Status $statusName -ExitReason $statusExitReason `
                -Data (Merge-OrchestraPaneEventData -StateModel $paneStateModel -Data ([ordered]@{
                    agent            = $agentName
                    model            = $modelName
                    required_cycles  = $script:BuilderStallThresholdCycles
                    snapshot_hash    = $statusSnapshotHash
                })) | Out-Null
            try {
                Send-MonitorOperatorMailboxMessage -SessionName $SessionName `
                    -Event 'pane.stalled' -Message $stallMessage `
                    -Label $label -PaneId $paneId -Role $role -Status $statusName -ExitReason $statusExitReason `
                    -Data (Merge-OrchestraPaneEventData -StateModel $paneStateModel -Data ([ordered]@{
                        agent            = $agentName
                        model            = $modelName
                        required_cycles  = $script:BuilderStallThresholdCycles
                        snapshot_hash    = $statusSnapshotHash
                    })) | Out-Null
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
                    -Data (Merge-OrchestraPaneEventData -StateModel $paneStateModel -Data ([ordered]@{ status = $statusName; exit_reason = $statusExitReason })) | Out-Null
            } catch {
            }
        }

        $shouldRespawn = $statusName -eq 'crashed' -or ($statusName -eq 'ready' -and $statusExitReason -eq 'exec_completed')
        if ($paneExecMode -and $statusName -eq 'waiting_for_dispatch') {
            $shouldRespawn = $false
        }

        # TASK-240: do not respawn bootstrap_invalid panes
        $manifestPaneStatus = [string](Get-MonitorPropertyValue -InputObject $pane -Name 'status' -Default '')
        if ($manifestPaneStatus -eq 'bootstrap_invalid') {
            $shouldRespawn = $false
        }

        if ($shouldRespawn) {
            $crashedCount++

            # Determine launch directory and git worktree dir
            $launchDir = $projectDir
            $launchGitWorktreeDir = $null
            $launchGitWorktreeDir = [string](Get-MonitorPropertyValue -InputObject $manifest.Session -Name 'git_worktree_dir' -Default '')

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
                -RootPath $projectDir `
                -ManifestPath $ManifestPath

            $result['Respawned'] = $respawnResult.Success
            $result['Message'] = $respawnResult.Message

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

    return [ordered]@{
        Checked   = $checkedCount
        Crashed   = $crashedCount
        Respawned = $respawnedCount
        ApprovalWaiting = $approvalWaitingCount
        ContextResets = $contextResetCount
        IdleAlerts = $idleAlertCount
        Stalls = $stallCount
        CurrentResults = $currentResults
        Results   = @($results)
    }
}

# ---------------------------------------------------------------------------
# Manifest parser (orchestra-start format)
# ---------------------------------------------------------------------------

function ConvertFrom-MonitorManifest {
    <#
    .SYNOPSIS
    Parses the orchestra manifest using the shared pane-control reader.
    #>
    param([Parameter(Mandatory = $true)][string]$Content)

    return ConvertFrom-PaneControlManifestContent -Content $Content
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

    $settings = Get-BridgeSettings -RootPath $resolvedProjectDir
    $result = Invoke-AgentMonitorCycle `
        -Settings $settings `
        -ManifestPath $manifestPath `
        -SessionName $SessionName `
        -HungThreshold $HungThresholdSeconds `
        -ContextResetThresholdPercent $ContextResetThresholdPercent

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
