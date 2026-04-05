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
    [int]$IdleThresholdSeconds = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = $PSScriptRoot
. "$scriptDir/settings.ps1"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$script:HungSnapshotDir = Join-Path $env:TEMP 'winsmux\monitor_snapshots'
$script:IdleStateDir = Join-Path $env:TEMP 'winsmux\monitor_idle'
$script:AgentMonitorDefaultHungThreshold = 60
$script:AgentMonitorDefaultIdleThreshold = 120

# ---------------------------------------------------------------------------
# Idle state persistence
# ---------------------------------------------------------------------------

function Get-MonitorIdleStatePath {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    $safe = $PaneId -replace '[%:]', '_'
    return Join-Path $script:IdleStateDir "$safe.json"
}

function Get-MonitorIdleState {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    $path = Get-MonitorIdleStatePath -PaneId $PaneId
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

function Save-MonitorIdleState {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$ReadySince,
        [Parameter(Mandatory = $true)][bool]$AlertSent
    )

    if (-not (Test-Path $script:IdleStateDir)) {
        New-Item -ItemType Directory -Path $script:IdleStateDir -Force | Out-Null
    }

    $path = Get-MonitorIdleStatePath -PaneId $PaneId
    $record = [ordered]@{
        ready_since = $ReadySince
        alert_sent  = $AlertSent
    }

    ($record | ConvertTo-Json -Compress) | Set-Content -Path $path -Encoding UTF8 -NoNewline
}

function Clear-MonitorIdleState {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    $path = Get-MonitorIdleStatePath -PaneId $PaneId
    if (Test-Path $path -PathType Leaf) {
        Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
    }
}

function Update-MonitorIdleAlertState {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][string]$SnapshotTail = '',
        [int]$IdleThresholdSeconds = $script:AgentMonitorDefaultIdleThreshold,
        [datetime]$Now = (Get-Date)
    )

    if ($Status -ne 'ready') {
        Clear-MonitorIdleState -PaneId $PaneId
        return [PSCustomObject]@{
            ShouldAlert = $false
            IdleSeconds = 0
            Message     = ''
        }
    }

    $state = Get-MonitorIdleState -PaneId $PaneId
    $readySince = $Now
    $alertSent = $false

    if ($null -ne $state) {
        try {
            $readySince = [System.DateTimeOffset]::Parse([string]$state.ready_since).LocalDateTime
        } catch {
            $readySince = $Now
        }

        $alertSent = [bool](Get-MonitorPropertyValue -InputObject $state -Name 'alert_sent' -Default $false)
    }

    $idleSeconds = [int][Math]::Floor(($Now - $readySince).TotalSeconds)

    if ($null -eq $state) {
        Save-MonitorIdleState -PaneId $PaneId -ReadySince ($Now.ToString('o')) -AlertSent $false
        return [PSCustomObject]@{
            ShouldAlert = $false
            IdleSeconds = 0
            Message     = ''
        }
    }

    if ($idleSeconds -lt $IdleThresholdSeconds) {
        return [PSCustomObject]@{
            ShouldAlert = $false
            IdleSeconds = $idleSeconds
            Message     = ''
        }
    }

    if ($alertSent) {
        return [PSCustomObject]@{
            ShouldAlert = $false
            IdleSeconds = $idleSeconds
            Message     = ''
        }
    }

    Save-MonitorIdleState -PaneId $PaneId -ReadySince ($readySince.ToString('o')) -AlertSent $true

    $message = "Commander alert: idle pane $Label ($PaneId, role=$Role) has been ready for ${idleSeconds}s without a new task."
    if (-not [string]::IsNullOrWhiteSpace($SnapshotTail)) {
        $message += " Tail: " + (($SnapshotTail -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 2) -join ' | ')
    }

    return [PSCustomObject]@{
        ShouldAlert = $true
        IdleSeconds = $idleSeconds
        Message     = $message
    }
}

function Get-MonitorCredentialValue {
    param(
        [Parameter(Mandatory = $true)][string]$PrimaryEnvName,
        [string[]]$FallbackEnvNames = @(),
        [string]$VaultKey = $PrimaryEnvName
    )

    foreach ($envName in @($PrimaryEnvName) + @($FallbackEnvNames)) {
        if ([string]::IsNullOrWhiteSpace($envName)) {
            continue
        }

        $value = [Environment]::GetEnvironmentVariable($envName)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    if (-not ('WinCred' -as [type])) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class WinCred {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool CredFree(IntPtr credential);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public const uint CRED_TYPE_GENERIC = 1;
}
'@ -ErrorAction Stop
        } catch {
            return $null
        }
    }

    $credPtr = [IntPtr]::Zero
    $ok = [WinCred]::CredRead("winsmux:$VaultKey", [WinCred]::CRED_TYPE_GENERIC, 0, [ref]$credPtr)
    if (-not $ok) {
        return $null
    }

    try {
        $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($credPtr, [Type][WinCred+CREDENTIAL])
        if ($cred.CredentialBlobSize -le 0) {
            return $null
        }

        $bytes = New-Object byte[] $cred.CredentialBlobSize
        [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
        return [System.Text.Encoding]::Unicode.GetString($bytes)
    } finally {
        [WinCred]::CredFree($credPtr) | Out-Null
    }
}

function Send-MonitorTelegramAlert {
    param([Parameter(Mandatory = $true)][string]$Message)

    $botToken = Get-MonitorCredentialValue -PrimaryEnvName 'WINSMUX_TELEGRAM_BOT_TOKEN' -FallbackEnvNames @('TELEGRAM_BOT_TOKEN') -VaultKey 'TELEGRAM_BOT_TOKEN'
    $chatId = Get-MonitorCredentialValue -PrimaryEnvName 'WINSMUX_TELEGRAM_CHAT_ID' -FallbackEnvNames @('TELEGRAM_CHAT_ID') -VaultKey 'TELEGRAM_CHAT_ID'

    if ([string]::IsNullOrWhiteSpace($botToken) -or [string]::IsNullOrWhiteSpace($chatId)) {
        return $false
    }

    try {
        $payload = @{
            chat_id = $chatId
            text    = $Message
        }
        Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$botToken/sendMessage" -Body $payload | Out-Null
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Psmux wrapper (same pattern as orchestra-start.ps1)
# ---------------------------------------------------------------------------

function Invoke-MonitorPsmux {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$CaptureOutput
    )

    $psmuxBin = Get-PsmuxBin
    if (-not $psmuxBin) {
        throw 'Could not find a psmux binary. Tried: psmux, pmux, tmux.'
    }

    if ($CaptureOutput) {
        $output = & $psmuxBin @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            $message = ($output | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = 'unknown psmux error'
            }

            throw "psmux $($Arguments -join ' ') failed: $message"
        }

        return $output
    }

    & $psmuxBin @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "psmux $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
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

# ---------------------------------------------------------------------------
# 1. Get-PaneAgentStatus
# ---------------------------------------------------------------------------

function Get-PaneAgentStatus {
    <#
    .SYNOPSIS
    Captures pane output and returns the agent status.

    .OUTPUTS
    PSCustomObject with: Status (ready|busy|crashed|hung|empty), PaneId, SnapshotTail
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [string]$Agent = 'codex',
        [int]$HungThreshold = $script:AgentMonitorDefaultHungThreshold
    )

    $snapshot = $null
    try {
        $snapshot = Invoke-MonitorPsmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') -CaptureOutput
    } catch {
        return [PSCustomObject]@{
            Status       = 'empty'
            PaneId       = $PaneId
            SnapshotTail = ''
        }
    }

    $text = ($snapshot | Out-String).TrimEnd()

    # empty: pane has no content
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [PSCustomObject]@{
            Status       = 'empty'
            PaneId       = $PaneId
            SnapshotTail = ''
        }
    }

    # Find last non-empty line
    $lastLine = $null
    $lines = $text -split "\r?\n"
    for ($i = $lines.Length - 1; $i -ge 0; $i--) {
        if (-not [string]::IsNullOrWhiteSpace($lines[$i])) {
            $lastLine = $lines[$i]
            break
        }
    }

    if ($null -eq $lastLine) {
        return [PSCustomObject]@{
            Status       = 'empty'
            PaneId       = $PaneId
            SnapshotTail = ''
        }
    }

    $trimmed = $lastLine.TrimStart()
    $tail = if ($lines.Length -le 12) {
        $text
    } else {
        ($lines[($lines.Length - 12)..($lines.Length - 1)] -join [Environment]::NewLine)
    }

    if (Test-CodexApprovalPromptText -Text $text) {
        return [PSCustomObject]@{
            Status       = 'busy'
            PaneId       = $PaneId
            SnapshotTail = $tail
        }
    }

    # ready: Codex prompt visible (> or U+203A) or "% left" model indicator
    $rightChevron = [string][char]8250
    if ($trimmed.StartsWith('>') -or $trimmed.StartsWith($rightChevron)) {
        Save-MonitorSnapshot -PaneId $PaneId -Hash (Get-ContentHash -Text $text) -Timestamp (Get-Date -Format o)
        return [PSCustomObject]@{
            Status       = 'ready'
            PaneId       = $PaneId
            SnapshotTail = $tail
        }
    }

    if ($Agent -eq 'codex' -and $text -match '(?im)\bgpt-[A-Za-z0-9._-]+\b.*\b\d+% left\b') {
        Save-MonitorSnapshot -PaneId $PaneId -Hash (Get-ContentHash -Text $text) -Timestamp (Get-Date -Format o)
        return [PSCustomObject]@{
            Status       = 'ready'
            PaneId       = $PaneId
            SnapshotTail = $tail
        }
    }

    # crashed: PowerShell prompt visible (PS C:\) - Codex exited
    if ($trimmed -match '^PS [A-Z]:\\') {
        return [PSCustomObject]@{
            Status       = 'crashed'
            PaneId       = $PaneId
            SnapshotTail = $tail
        }
    }

    # hung: no output change for threshold seconds
    $currentHash = Get-ContentHash -Text $text
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
        [int]$ReadyTimeoutSeconds = 60
    )

    # Build launch command (same logic as orchestra-start Get-AgentLaunchCommand)
    $launchCommand = $null
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

    # Send launch command via psmux-bridge send
    $bridgeScript = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..\..\scripts\psmux-bridge.ps1'))
    try {
        & pwsh -NoProfile -File $bridgeScript 'send' $PaneId $launchCommand 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{
                Success = $false
                PaneId  = $PaneId
                Message = "Failed to send launch command to pane $PaneId"
            }
        }
    } catch {
        return [PSCustomObject]@{
            Success = $false
            PaneId  = $PaneId
            Message = "Exception sending to pane ${PaneId}: $($_.Exception.Message)"
        }
    }

    # Poll for ready state
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $status = Get-PaneAgentStatus -PaneId $PaneId -Agent $Agent
        if ($status.Status -eq 'ready') {
            return [PSCustomObject]@{
                Success = $true
                PaneId  = $PaneId
                Message = "Agent respawned successfully in pane $PaneId"
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
    PSCustomObject with: Checked (int), Crashed (int), Respawned (int), Results (array)
    #>
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [string]$SessionName = 'winsmux-orchestra',
        [int]$HungThreshold = $script:AgentMonitorDefaultHungThreshold,
        [int]$IdleThreshold = $script:AgentMonitorDefaultIdleThreshold
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
    $idleAlertCount = 0

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
        $status = Get-PaneAgentStatus -PaneId $paneId -Agent $agentName -HungThreshold $HungThreshold

        $result = [PSCustomObject]@{
            Label      = $label
            PaneId     = $paneId
            Role       = $role
            Status     = $status.Status
            Respawned  = $false
            IdleAlerted = $false
            Message    = ''
        }

        # Log the status check
        if ($loggerAvailable) {
            try {
                Write-OrchestraLog -ProjectDir $projectDir -SessionName $SessionName `
                    -Event 'monitor.status' -Level 'debug' `
                    -Message "Pane $label ($paneId): $($status.Status)" `
                    -Role $role -PaneId $paneId `
                    -Data ([ordered]@{ status = $status.Status }) | Out-Null
            } catch {
            }
        }

        $idleTransition = Update-MonitorIdleAlertState `
            -PaneId $paneId `
            -Label $label `
            -Role $role `
            -Status $status.Status `
            -SnapshotTail $status.SnapshotTail `
            -IdleThresholdSeconds $IdleThreshold

        if ($idleTransition.ShouldAlert) {
            $idleAlertCount++
            $result.IdleAlerted = $true
            $result.Message = $idleTransition.Message
            Write-Output $idleTransition.Message

            $telegramSent = Send-MonitorTelegramAlert -Message $idleTransition.Message
            if ($loggerAvailable) {
                try {
                    Write-OrchestraLog -ProjectDir $projectDir -SessionName $SessionName `
                        -Event 'monitor.idle.alert' -Level 'warn' `
                        -Message $idleTransition.Message `
                        -Role $role -PaneId $paneId -Target 'commander' `
                        -Data ([ordered]@{ idle_seconds = $idleTransition.IdleSeconds; telegram_sent = $telegramSent }) | Out-Null
                } catch {
                }
            }
        }

        if ($status.Status -eq 'crashed') {
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
                    Write-OrchestraLog -ProjectDir $projectDir -SessionName $SessionName `
                        -Event 'monitor.respawn.start' -Level 'warn' `
                        -Message "Respawning crashed agent in pane $label ($paneId)" `
                        -Role $role -PaneId $paneId `
                        -Data ([ordered]@{ agent = $agentName; model = $modelName; launch_dir = $launchDir }) | Out-Null
                } catch {
                }
            }

            $respawnResult = Invoke-AgentRespawn `
                -PaneId $paneId `
                -Agent $agentName `
                -Model $modelName `
                -ProjectDir $launchDir `
                -GitWorktreeDir $launchGitWorktreeDir

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
                -Message "Monitor cycle: checked=$checkedCount crashed=$crashedCount respawned=$respawnedCount idle_alerts=$idleAlertCount" `
                -Data ([ordered]@{ checked = $checkedCount; crashed = $crashedCount; respawned = $respawnedCount; idle_alerts = $idleAlertCount }) | Out-Null
        } catch {
        }
    }

    return [PSCustomObject]@{
        Checked   = $checkedCount
        Crashed   = $crashedCount
        Respawned = $respawnedCount
        IdleAlerts = $idleAlertCount
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
        -HungThreshold $HungThresholdSeconds `
        -IdleThreshold $IdleThresholdSeconds

    Write-Output "Monitor cycle complete: checked=$($result.Checked) crashed=$($result.Crashed) respawned=$($result.Respawned) idle_alerts=$($result.IdleAlerts)"
    foreach ($r in $result.Results) {
        $respawnTag = if ($r.Respawned) { ' [RESPAWNED]' } else { '' }
        $messageTag = if ($r.Message) { " ($($r.Message))" } else { '' }
        Write-Output ("  {0,-14} {1,-8} {2,-10} {3}{4}" -f $r.Label, $r.PaneId, $r.Status, $respawnTag, $messageTag)
    }

    if ($result.Crashed -gt 0 -and $result.Respawned -lt $result.Crashed) {
        exit 1
    }
}
