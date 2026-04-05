[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Command,
    [Parameter(Position=1)][string]$Target,
    [Parameter(Position=2, ValueFromRemainingArguments=$true)][string[]]$Rest
)

# --- Config ---
$VERSION = "0.19.0"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$ReadMarkDir    = Join-Path $env:TEMP "winsmux\read_marks"
$WatermarkDir   = Join-Path $env:TEMP "winsmux\watermarks"
$LockDir        = Join-Path $env:TEMP "winsmux\locks"
$FocusPolicyFile = Join-Path $env:TEMP "winsmux\focus-policy-stack.json"
$LabelsFile     = Join-Path $env:APPDATA "winsmux\labels.json"
$BridgeSettingsScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\settings.ps1'))
$PaneControlScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\pane-control.ps1'))

if (Test-Path $BridgeSettingsScript -PathType Leaf) {
    . $BridgeSettingsScript
}

if (Test-Path $PaneControlScript -PathType Leaf) {
    . $PaneControlScript
}

# --- Windows Credential Manager P/Invoke ---
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class WinCred {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool CredFree(IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredEnumerate(string filter, uint flags, out int count, out IntPtr credentials);

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
    public const uint CRED_PERSIST_LOCAL_MACHINE = 2;
}
'@ -ErrorAction SilentlyContinue

# --- Helper: Stop-WithError ---
function Stop-WithError {
    param([string]$Message)
    Write-Error $Message
    exit 1
}

# --- Helper: Dispatch prompt paths ---
function Get-DispatchPromptDirectory {
    param([string]$ProjectDir = (Get-Location).Path)

    return Join-Path $ProjectDir '.winsmux\dispatch-prompts'
}

function New-DispatchPromptFile {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [string]$ProjectDir = (Get-Location).Path,
        [string]$Prefix = 'dispatch-prompt'
    )

    $promptDir = Get-DispatchPromptDirectory -ProjectDir $ProjectDir
    if (-not (Test-Path $promptDir)) {
        New-Item -ItemType Directory -Path $promptDir -Force | Out-Null
    }

    $fileName = '{0}-{1}.txt' -f $Prefix, ([guid]::NewGuid().ToString('N'))
    $path = Join-Path $promptDir $fileName
    $Content | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Convert-MsysTmpPathToWindowsPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path -notmatch '^/tmp(?:/|$)') {
        return $Path
    }

    $tempRoot = [System.IO.Path]::GetTempPath().TrimEnd('\')
    $relative = $Path.Substring(4).TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return $tempRoot
    }

    return Join-Path $tempRoot ($relative -replace '/', '\')
}

function Normalize-DispatchText {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    if ($Text -notmatch '/tmp(?:/|$)') {
        return $Text
    }

    return [regex]::Replace($Text, '(?<quote>["''])(?<path>/tmp(?:/|$)(?:(?!\k<quote>).)*)\k<quote>|(?<path>/tmp(?:/[^''"`\s|;,)]*)?)', {
        param($match)
        $normalizedPath = Convert-MsysTmpPathToWindowsPath -Path $match.Groups['path'].Value
        if ($match.Groups['quote'].Success) {
            return $match.Groups['quote'].Value + $normalizedPath + $match.Groups['quote'].Value
        }

        return $normalizedPath
    })
}

# --- Helper: Labels ---
function Get-Labels {
    if (Test-Path $LabelsFile) {
        $raw = Get-Content -Path $LabelsFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
        $ht = @{}
        $obj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
        return $ht
    }
    return @{}
}

function Save-Labels {
    param([hashtable]$Labels)
    $dir = Split-Path $LabelsFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Labels | ConvertTo-Json | Set-Content -Path $LabelsFile -Encoding UTF8
}

# --- Helper: Resolve-Target ---
function Resolve-Target {
    param([string]$RawTarget)
    $labels = Get-Labels
    if ($labels.ContainsKey($RawTarget)) {
        return $labels[$RawTarget]
    }
    return $RawTarget
}

# --- Helper: Confirm-Target ---
function Confirm-Target {
    param([string]$PaneId)
    # display-message -t ignores the -t flag in winsmux v3.3.1, so validate via list-panes
    $allPanes = (& winsmux list-panes -a -F '#{pane_id}' | Out-String).Trim() -split "`n" | ForEach-Object { $_.Trim() }
    if ($PaneId -notin $allPanes) {
        Stop-WithError "invalid target: $PaneId"
    }
    return $PaneId
}

# --- Helper: Read Mark ---
function Get-ReadMarkPath {
    param([string]$PaneId)
    $safe = $PaneId -replace '[%:]', '_'
    return Join-Path $ReadMarkDir $safe
}

function Set-ReadMark {
    param([string]$PaneId)
    $path = Get-ReadMarkPath $PaneId
    if (-not (Test-Path $ReadMarkDir)) {
        New-Item -ItemType Directory -Path $ReadMarkDir -Force | Out-Null
    }
    New-Item -ItemType File -Path $path -Force | Out-Null
}

function Assert-ReadMark {
    param([string]$PaneId)
    $path = Get-ReadMarkPath $PaneId
    if (-not (Test-Path $path)) {
        Stop-WithError "error: must read the pane before interacting. Run: winsmux read $PaneId"
    }
}

function Clear-ReadMark {
    param([string]$PaneId)
    $path = Get-ReadMarkPath $PaneId
    if (Test-Path $path) {
        Remove-Item -Path $path -Force
    }
}

# --- Helper: Watermark (change detection for read-after-send) ---
function Get-WatermarkPath {
    param([string]$PaneId)
    $safe = $PaneId -replace '[%:]', '_'
    return Join-Path $WatermarkDir $safe
}

function Save-Watermark {
    param([string]$PaneId, [string]$Content)
    if (-not (Test-Path $WatermarkDir)) {
        New-Item -ItemType Directory -Path $WatermarkDir -Force | Out-Null
    }
    $hash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Content)
        )
    ) -replace '-', ''
    $path = Get-WatermarkPath $PaneId
    Set-Content -Path $path -Value $hash -Encoding UTF8 -NoNewline
}

function Test-WatermarkChanged {
    param([string]$PaneId, [string]$CurrentContent)
    $path = Get-WatermarkPath $PaneId
    if (-not (Test-Path $path)) { return $true }
    $savedHash = Get-Content -Path $path -Raw -Encoding UTF8
    $currentHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($CurrentContent)
        )
    ) -replace '-', ''
    return $currentHash -ne $savedHash
}

function Clear-Watermark {
    param([string]$PaneId)
    $path = Get-WatermarkPath $PaneId
    if (Test-Path $path) {
        Remove-Item -Path $path -Force
    }
}

function Get-LastNonEmptyLine {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $lines = $Text -split "\r?\n"
    for ($i = $lines.Length - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            return $line
        }
    }

    return $null
}

function Get-TextHash {
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

function Test-CodexReadyPromptText {
    param([string]$Text)

    $lastLine = Get-LastNonEmptyLine $Text
    if ($null -eq $lastLine) {
        return $false
    }

    return $lastLine.TrimStart().StartsWith('>')
}

function Test-CodexReadyPrompt {
    param([string]$PaneId)

    $output = & winsmux capture-pane -t $PaneId -p -J -S -50
    return Test-CodexReadyPromptText (($output | Out-String).TrimEnd())
}

function Wait-PaneShellReady {
    param([string]$PaneId, [int]$TimeoutSeconds = 15)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $snapshot = (& winsmux capture-pane -t $PaneId -p -J -S -50 2>$null | Out-String).TrimEnd()
        $lastLine = Get-LastNonEmptyLine $snapshot
        if ($lastLine -and $lastLine.Trim() -match '^PS ') {
            return
        }

        Start-Sleep -Milliseconds 500
    }

    Stop-WithError "timed out waiting for shell prompt in $PaneId"
}

function Get-PaneRuntimeMap {
    $paneMap = @{}
    $raw = & winsmux list-panes -a -F '#{pane_id} #{pane_pid}'
    $lines = ($raw | Out-String).Trim() -split "`n"

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        $parts = $trimmed -split '\s+', 3
        if ($parts.Count -lt 2) { continue }

        $paneId = $parts[0]
        $panePid = $parts[1]
        $isRunning = $false

        if ($panePid -match '^\d+$') {
            try {
                $null = Get-Process -Id ([int]$panePid) -ErrorAction Stop
                $isRunning = $true
            } catch {
                $isRunning = $false
            }
        }

        $paneMap[$paneId] = [PSCustomObject]@{
            PaneId    = $paneId
            PanePid   = $panePid
            IsRunning = $isRunning
        }
    }

    return $paneMap
}

function Get-PaneSnapshotText {
    param([string]$PaneId, [int]$Lines = 50)

    $output = & winsmux capture-pane -t $PaneId -p -J -S "-$Lines"
    return ($output | Out-String).TrimEnd()
}

# --- Helper: Focus Policy Stack ---
function Get-FocusPolicyStack {
    if (-not (Test-Path $FocusPolicyFile)) {
        return @()
    }

    $raw = Get-Content -Path $FocusPolicyFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Stop-WithError "invalid focus policy stack: $FocusPolicyFile"
    }

    if ($parsed -is [System.Array]) {
        return @($parsed)
    }

    return @($parsed)
}

function Save-FocusPolicyStack {
    param([object[]]$Stack)

    $dir = Split-Path $FocusPolicyFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ($null -eq $Stack -or $Stack.Count -eq 0) {
        if (Test-Path $FocusPolicyFile) {
            Remove-Item -Path $FocusPolicyFile -Force
        }
        return
    }

    $Stack | ConvertTo-Json -Depth 4 | Set-Content -Path $FocusPolicyFile -Encoding UTF8
}

function Get-ActiveFocusPolicy {
    $stack = Get-FocusPolicyStack
    if (-not $stack -or $stack.Count -eq 0) {
        return $null
    }

    return $stack[$stack.Count - 1]
}

function Push-FocusPolicy {
    param(
        [string]$PaneId,
        [string]$TargetName
    )

    $stack = @(Get-FocusPolicyStack)
    $entry = [PSCustomObject]@{
        paneId      = $PaneId
        target      = $TargetName
        lockedBy    = $env:WINSMUX_PANE_ID
        lockedAt    = (Get-Date).ToString("o")
    }

    $stack += $entry
    Save-FocusPolicyStack -Stack $stack
    return $entry
}

function Pop-FocusPolicy {
    $stack = @(Get-FocusPolicyStack)
    if (-not $stack -or $stack.Count -eq 0) {
        return $null
    }

    $entry = $stack[$stack.Count - 1]
    if ($stack.Count -eq 1) {
        Save-FocusPolicyStack -Stack @()
    } else {
        Save-FocusPolicyStack -Stack $stack[0..($stack.Count - 2)]
    }

    return $entry
}

function Assert-FocusAllowed {
    param(
        [string]$PaneId,
        [string]$RawTarget
    )

    $policy = Get-ActiveFocusPolicy
    if ($null -eq $policy) {
        return
    }

    if ($policy.paneId -ne $PaneId) {
        Stop-WithError "focus denied: locked to $($policy.paneId) ($($policy.target)). Run: winsmux focus-unlock"
    }
}

# --- Helper: File Locks ---
function Ensure-LockDir {
    if (-not (Test-Path $LockDir)) {
        New-Item -ItemType Directory -Path $LockDir -Force | Out-Null
    }
}

function Resolve-LockFileTarget {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        Stop-WithError "lock target file must not be empty"
    }

    try {
        $resolved = Resolve-Path -LiteralPath $FilePath -ErrorAction Stop
        return $resolved.ProviderPath
    } catch {
        return [System.IO.Path]::GetFullPath($FilePath)
    }
}

function Get-LockHash {
    param([string]$FilePath)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($FilePath.ToLowerInvariant())
    return ([System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    ) -replace '-', '').ToLowerInvariant()
}

function Get-LockPath {
    param([string]$FilePath)

    $resolvedFile = Resolve-LockFileTarget $FilePath
    $hash = Get-LockHash $resolvedFile
    return Join-Path $LockDir "$hash.lock"
}

function Read-LockInfo {
    param([string]$LockPath)

    if (-not (Test-Path $LockPath)) { return $null }
    try {
        return (Get-Content -Path $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Remove-ExpiredLocks {
    Ensure-LockDir
    $now = Get-Date
    $expired = @()

    foreach ($item in Get-ChildItem -Path $LockDir -Filter '*.lock' -File -ErrorAction SilentlyContinue) {
        $info = Read-LockInfo $item.FullName
        if ($null -eq $info) {
            Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
            continue
        }

        try {
            $acquiredAt = [DateTimeOffset]::Parse($info.acquiredAt)
        } catch {
            Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
            continue
        }

        if (($now - $acquiredAt.LocalDateTime).TotalMinutes -ge 30) {
            Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
            $expired += [PSCustomObject]@{
                Label      = $info.label
                File       = $info.file
                AcquiredAt = $acquiredAt.ToString("o")
            }
        }
    }

    return $expired
}

function Invoke-Lock {
    if (-not $Target) { Stop-WithError "usage: winsmux lock <label> <file>..." }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux lock <label> <file>..." }

    $label = $Target
    $expired = Remove-ExpiredLocks
    foreach ($entry in $expired) {
        Write-Warning "expired lock released: $($entry.File) [$($entry.Label)]"
    }

    $pending = @()
    foreach ($file in $Rest) {
        $resolvedFile = Resolve-LockFileTarget $file
        $lockPath = Get-LockPath $resolvedFile
        $info = Read-LockInfo $lockPath

        if ($null -ne $info -and $info.label -ne $label) {
            Stop-WithError "lock denied: $resolvedFile is already locked by $($info.label)"
        }

        $pending += [PSCustomObject]@{
            File     = $resolvedFile
            LockPath = $lockPath
        }
    }

    Ensure-LockDir
    $timestamp = (Get-Date).ToString("o")
    foreach ($entry in $pending) {
        $payload = [ordered]@{
            label      = $label
            file       = $entry.File
            acquiredAt = $timestamp
        }
        $json = $payload | ConvertTo-Json
        # Atomic lock acquisition: CreateNew fails if file already exists (race-safe)
        try {
            $fs = [IO.File]::Open($entry.LockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $writer = [IO.StreamWriter]::new($fs, [Text.Encoding]::UTF8)
            $writer.Write($json)
            $writer.Close()
            $fs.Close()
            Write-Output "locked $($entry.File) [$label]"
        } catch [IO.IOException] {
            # File was created by another process between check and write
            $rival = Read-LockInfo $entry.LockPath
            $rivalLabel = if ($rival) { $rival.label } else { "unknown" }
            Stop-WithError "lock denied (race): $($entry.File) is already locked by $rivalLabel"
        }
    }
}

function Invoke-Unlock {
    if (-not $Target) { Stop-WithError "usage: winsmux unlock <label> <file>..." }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux unlock <label> <file>..." }

    $label = $Target
    foreach ($file in $Rest) {
        $resolvedFile = Resolve-LockFileTarget $file
        $lockPath = Get-LockPath $resolvedFile

        if (-not (Test-Path $lockPath)) {
            Write-Output "not locked: $resolvedFile"
            continue
        }

        $info = Read-LockInfo $lockPath
        if ($null -eq $info) {
            Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
            Write-Output "unlocked $resolvedFile [$label]"
            continue
        }

        if ($info.label -ne $label) {
            Stop-WithError "unlock denied: $resolvedFile is locked by $($info.label)"
        }

        Remove-Item -Path $lockPath -Force
        Write-Output "unlocked $resolvedFile [$label]"
    }
}

function Invoke-Locks {
    $expired = Remove-ExpiredLocks
    foreach ($entry in $expired) {
        Write-Warning "expired lock released: $($entry.File) [$($entry.Label)]"
    }

    Ensure-LockDir
    $locks = Get-ChildItem -Path $LockDir -Filter '*.lock' -File -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $locks -or $locks.Count -eq 0) {
        Write-Output "(no locks)"
        return
    }

    foreach ($item in $locks) {
        $info = Read-LockInfo $item.FullName
        if ($null -eq $info) { continue }
        Write-Output "$($info.label)`t$($info.file)`t$($info.acquiredAt)"
    }
}

# --- Commands ---

function Invoke-Id {
    if ($env:TMUX_PANE) {
        Write-Output $env:TMUX_PANE
    } else {
        $id = & winsmux display-message -p '#{pane_id}'
        Write-Output ($id | Out-String).Trim()
    }
}

function Invoke-List {
    $raw = & winsmux list-panes -a -F '#{pane_id} #{pane_pid} #{pane_current_command} #{pane_width}x#{pane_height} #{pane_title}'
    $labels = Get-Labels
    # Build reverse lookup: paneId -> label
    $reverseLabels = @{}
    foreach ($key in $labels.Keys) {
        $reverseLabels[$labels[$key]] = $key
    }

    $lines = ($raw | Out-String).Trim() -split "`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        # Parse pane_id and pane_pid from the line
        $parts = $trimmed -split '\s+', 5
        $paneId  = $parts[0]
        $panePid = $parts[1]

        # Detect child process name
        $childCmd = ""
        try {
            $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $panePid" -OperationTimeoutSec 10 -ErrorAction SilentlyContinue)
            if ($children) {
                $child = $children | Select-Object -First 1
                $childCmd = $child.Name
            }
        } catch {
            try {
                $children = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Parent -and $_.Parent.Id -eq [int]$panePid })
                if ($children) {
                    $child = $children | Select-Object -First 1
                    $childCmd = $child.ProcessName
                }
            } catch { }
        }

        # Build output line
        $output = $trimmed
        if ($childCmd) {
            $output += " ($childCmd)"
        }
        if ($reverseLabels.ContainsKey($paneId)) {
            $output += " [$($reverseLabels[$paneId])]"
        }
        Write-Output $output
    }
}

function Invoke-Read {
    if (-not $Target) { Stop-WithError "usage: winsmux read <target> [lines]" }

    $lines = 200
    if ($Rest -and $Rest.Count -gt 0) {
        $lines = [int]$Rest[0]
    }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    $output = & winsmux capture-pane -t $paneId -p -J -S "-$lines"
    $currentText = ($output | Out-String).TrimEnd()

    # Watermark-based change detection: if a watermark exists (set by send),
    # only return content when the pane buffer has actually changed.
    $wmPath = Get-WatermarkPath $paneId
    if (Test-Path $wmPath) {
        if (-not (Test-WatermarkChanged $paneId $currentText)) {
            Write-Output "[winsmux] waiting for response..."
            Set-ReadMark $paneId
            return
        }
        # Buffer changed — agent has produced new output
        Clear-Watermark $paneId
    }

    Write-Output $currentText
    Set-ReadMark $paneId
}

function Invoke-Type {
    if (-not $Target) { Stop-WithError "usage: winsmux type <target> <text>" }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux type <target> <text>" }

    $text = $Rest -join ' '
    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    & winsmux send-keys -t $paneId -l -- "$text"

    Clear-ReadMark $paneId
}

function Invoke-Keys {
    if (-not $Target) { Stop-WithError "usage: winsmux keys <target> <key>..." }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux keys <target> <key>..." }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    foreach ($key in $Rest) {
        & winsmux send-keys -t $paneId $key
    }

    Clear-ReadMark $paneId
}

function Invoke-Message {
    if (-not $Target) { Stop-WithError "usage: winsmux message <target> <text>" }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux message <target> <text>" }

    $text = $Rest -join ' '
    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    $myId = (& winsmux display-message -p '#{pane_id}' | Out-String).Trim()
    $myCoord = (& winsmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' | Out-String).Trim()
    $agentName = if ($env:WINSMUX_AGENT_NAME) { $env:WINSMUX_AGENT_NAME } else { "unknown" }

    $header = "[winsmux from:$agentName pane:$myId at:$myCoord -- load the winsmux skill to reply]"
    & winsmux send-keys -t $paneId -l -- "$header $text"

    Clear-ReadMark $paneId
}

function Invoke-Send {
    if (-not $Target) { Stop-WithError "usage: winsmux send <target> <text>" }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux send <target> <text>" }

    # Normalize Git Bash /tmp paths before dispatching PowerShell-oriented commands.
    $text = Normalize-DispatchText -Text ($Rest -join ' ')
    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    # Step 1: Type text directly (no header — headers break TUI agents like Claude Code)
    & winsmux send-keys -t $paneId -l -- "$text"

    # Step 2: Verify text landed
    Start-Sleep -Milliseconds 300

    # Step 3: Submit with Enter
    & winsmux send-keys -t $paneId Enter
    Start-Sleep -Milliseconds 500
    $postEnterSnapshot = & winsmux capture-pane -t $paneId -p -J -S "-200"
    $postEnterText = ($postEnterSnapshot | Out-String).TrimEnd()
    if ($postEnterText -match '\[Pasted Content') {
        & winsmux send-keys -t $paneId Enter
    }

    # Step 4: Save watermark for change detection in subsequent read calls
    Start-Sleep -Milliseconds 800
    $snapshot = & winsmux capture-pane -t $paneId -p -J -S "-200"
    $snapshotText = ($snapshot | Out-String).TrimEnd()
    Save-Watermark $paneId $snapshotText

    # Reset read mark so next read works without guard error
    Set-ReadMark $paneId

    Write-Output "sent to $paneId"
}

function Invoke-Name {
    if (-not $Target) { Stop-WithError "usage: winsmux name <target> <label>" }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: winsmux name <target> <label>" }

    $label = $Rest[0]
    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    $labels = Get-Labels
    $labels[$label] = $paneId
    Save-Labels $labels

    # Also set pane title (best-effort)
    try {
        & winsmux select-pane -t $paneId -T "$label" 2>$null
    } catch { }

    Write-Output "Labeled pane $paneId as '$label'"
}

function Invoke-Resolve {
    if (-not $Target) { Stop-WithError "usage: winsmux resolve <label>" }

    $labels = Get-Labels
    if ($labels.ContainsKey($Target)) {
        Write-Output $labels[$Target]
    } else {
        Stop-WithError "label not found: $Target"
    }
}

function Invoke-AutoRebalance {
    $projectDir = (Get-Location).Path
    $manifestPath = Join-Path $projectDir ".winsmux\manifest.yaml"
    if (-not (Test-Path $manifestPath)) {
        Stop-WithError "manifest not found: $manifestPath"
    }

    $labels = Get-Labels
    $builderLabels = @($labels.Keys | Where-Object { $_ -match '^builder-' })

    $idleBuilders = @()
    foreach ($label in $builderLabels) {
        $paneId = $labels[$label]
        $snapshot = (& winsmux capture-pane -t $paneId -p 2>$null | Out-String).TrimEnd()
        $lastLine = ($snapshot -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        $isIdle = $lastLine -and ($lastLine.Trim() -match '\d+% left' -or $lastLine.Trim() -match '^[>›]')
        if ($isIdle) { $idleBuilders += $label }
    }

    $queueDepth = 0
    try {
        $queueScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\builder-queue.ps1'))
        if (Test-Path $queueScript) {
            $out = & pwsh -NoProfile -File $queueScript -Action list -ProjectDir $projectDir -BuilderLabel '' -AsJson 2>$null
            if ($out) { $parsed = $out | ConvertFrom-Json -ErrorAction SilentlyContinue; if ($parsed) { $queueDepth = @($parsed.Queued).Count } }
        }
    } catch {}

    $suggestion = if ($queueDepth -gt 0) { "キューにタスクあり — Builder 維持" }
                  elseif ($idleBuilders.Count -gt 0) { "アイドル $($idleBuilders.Count) 台を Researcher に切替可能" }
                  else { "全 Builder 稼働中" }

    Write-Output "アイドル Builder: $($idleBuilders.Count)/$($builderLabels.Count)"
    Write-Output "キュー深度: $queueDepth"
    Write-Output "提案: $suggestion"
    if ($idleBuilders.Count -gt 0) { Write-Output "アイドル: $($idleBuilders -join ', ')" }
}

function Invoke-Role {
    if (-not $Target -or -not $Rest -or $Rest.Count -lt 1) {
        Stop-WithError "usage: winsmux role <pane_label_or_id> <new_role>`n  roles: builder, researcher, reviewer"
    }

    $newRole = $Rest[0].Trim().ToLowerInvariant()
    if ($newRole -notin @('builder', 'researcher', 'reviewer')) {
        Stop-WithError "invalid role: $newRole. Must be builder, researcher, or reviewer."
    }

    # Resolve pane ID
    $paneId = $Target
    $labels = Get-Labels
    if ($labels.ContainsKey($Target)) {
        $paneId = $labels[$Target]
    } elseif ($Target -notmatch '^%\d+$') {
        Stop-WithError "unknown pane: $Target"
    }

    # Read manifest to find current label
    $projectDir = (Get-Location).Path
    $manifestPath = Join-Path $projectDir ".winsmux\manifest.yaml"
    $oldLabel = $Target

    # Count existing panes with new role to generate label number
    $existingLabels = @()
    if (Test-Path $manifestPath) {
        $manifestContent = Get-Content $manifestPath -Raw
        $existingLabels = @([regex]::Matches($manifestContent, "label:\s*'($newRole-\d+)'") | ForEach-Object { $_.Groups[1].Value })
    }
    $nextNum = 1
    while ("$newRole-$nextNum" -in $existingLabels) { $nextNum++ }
    $newLabel = "$newRole-$nextNum"

    # Rename pane first (before respawn)
    & winsmux select-pane -t $paneId -T $newLabel

    # Update labels
    $labels[$newLabel] = $paneId
    if ($labels.ContainsKey($oldLabel)) { $labels.Remove($oldLabel) }
    Save-Labels $labels

    # Respawn pane (kills current process + restarts shell in one step, #174)
    & winsmux respawn-pane -k -t $paneId

    # Wait for shell ready (poll for PS prompt)
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $snapshot = (& winsmux capture-pane -t $paneId -p 2>$null | Out-String).TrimEnd()
        $lastLine = ($snapshot -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        if ($lastLine -and $lastLine.Trim() -match '^PS ') { break }
        Start-Sleep -Milliseconds 500
    }

    # Launch Codex agent
    $gitDir = Join-Path $projectDir ".git"
    $launchCmd = "codex --full-auto -C '$projectDir' --add-dir '$gitDir'"
    & winsmux send-keys -t $paneId -l $launchCmd
    & winsmux send-keys -t $paneId Enter

    Write-Output "Role changed: $oldLabel -> $newLabel ($paneId)"
}

function Invoke-Verify {
    if (-not $Target) { Stop-WithError "usage: winsmux verify <pr-number>" }
    if ($Rest -and $Rest.Count -gt 0) { Stop-WithError "usage: winsmux verify <pr-number>" }

    $prNumber = $Target
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $testsDir = Join-Path $repoRoot 'tests'

    if (-not (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) {
        Stop-WithError "Invoke-Pester not found. Install/import Pester before running verify."
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Stop-WithError "gh CLI not found. Install GitHub CLI before running verify."
    }

    if (-not (Test-Path -LiteralPath $testsDir -PathType Container)) {
        Stop-WithError "tests directory not found: $testsDir"
    }

    $testFiles = Get-ChildItem -Path $testsDir -Recurse -File -Include '*.Tests.ps1','*.ps1' |
        Sort-Object FullName

    if (-not $testFiles -or $testFiles.Count -eq 0) {
        Stop-WithError "no test files found under $testsDir"
    }

    Write-Output "Running Pester tests from $testsDir"
    $result = Invoke-Pester -Path ($testFiles.FullName) -PassThru

    if ($null -eq $result) {
        Stop-WithError "Invoke-Pester returned no result."
    }

    $failedTests = @()
    if ($result.PSObject.Properties.Name -contains 'Failed' -and $result.Failed) {
        $failedTests = @($result.Failed)
    } elseif ($result.PSObject.Properties.Name -contains 'TestResult' -and $result.TestResult) {
        $failedTests = @($result.TestResult | Where-Object { -not $_.Passed })
    }

    $failedCount = 0
    if ($result.PSObject.Properties.Name -contains 'FailedCount') {
        $failedCount = [int]$result.FailedCount
    } elseif ($failedTests) {
        $failedCount = $failedTests.Count
    }

    if ($failedCount -gt 0) {
        Write-Error "Pester verify failed. Failed tests:"
        foreach ($failedTest in $failedTests) {
            $failedName = $null
            foreach ($propertyName in 'ExpandedPath','Path','Name') {
                if ($failedTest.PSObject.Properties.Name -contains $propertyName) {
                    $failedName = $failedTest.$propertyName
                    if (-not [string]::IsNullOrWhiteSpace($failedName)) {
                        break
                    }
                }
            }

            if ([string]::IsNullOrWhiteSpace($failedName)) {
                $failedName = ($failedTest | Out-String).Trim()
            }

            Write-Error " - $failedName"
        }
        exit 1
    }

    Write-Output "Pester PASS. Merging PR #$prNumber"
    & gh pr merge $prNumber --squash --delete-branch
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

function Invoke-Doctor {
    Write-Output "=== winsmux doctor ==="

    # winsmux binary check
    try {
        $ver = & winsmux -V 2>&1
        Write-Output "winsmux: $($ver | Out-String)".Trim()
    } catch {
        Write-Output "winsmux: NOT FOUND"
    }

    # TMUX_PANE
    if ($env:TMUX_PANE) {
        Write-Output "TMUX_PANE: $env:TMUX_PANE"
    } else {
        Write-Output "TMUX_PANE: (not set)"
    }

    # WINSMUX_AGENT_NAME
    if ($env:WINSMUX_AGENT_NAME) {
        Write-Output "WINSMUX_AGENT_NAME: $env:WINSMUX_AGENT_NAME"
    } else {
        Write-Output "WINSMUX_AGENT_NAME: (not set)"
    }

    # Pane count
    try {
        $panes = & winsmux list-panes -a -F '#{pane_id}'
        $count = (($panes | Out-String).Trim() -split "`n" | Where-Object { $_.Trim() }).Count
        Write-Output "Panes: $count"
    } catch {
        Write-Output "Panes: (error listing)"
    }

    # Labels
    $labels = Get-Labels
    Write-Output "Labels: $($labels.Count) in $LabelsFile"

    # Read marks
    if (Test-Path $ReadMarkDir) {
        $marks = (Get-ChildItem -Path $ReadMarkDir -File).Count
        Write-Output "Read marks: $marks in $ReadMarkDir"
    } else {
        Write-Output "Read marks: 0 (directory not created yet)"
    }

    # IME diagnostics
    Write-Output ""
    Write-Output "=== IME diagnostics ==="

    # escape-time check
    try {
        $escTime = (& winsmux show-options -g -v escape-time 2>&1 | Out-String).Trim()
        if ($escTime -match '^\d+$' -and [int]$escTime -gt 50) {
            Write-Output "escape-time: $escTime ms [WARNING: >50ms causes IME lag. Set to 0 in .winsmux.conf]"
        } else {
            Write-Output "escape-time: $escTime ms [OK]"
        }
    } catch {
        Write-Output "escape-time: (could not read)"
    }

    # Windows Terminal atlas engine check
    $wtSettingsPath = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    if (Test-Path $wtSettingsPath) {
        try {
            $wtSettings = Get-Content -Path $wtSettingsPath -Raw | ConvertFrom-Json
            $atlasEngine = $wtSettings.profiles.defaults.useAtlasEngine
            if ($null -eq $atlasEngine) {
                Write-Output "WT useAtlasEngine: not set [TIP: set to false for better CJK IME]"
            } elseif ($atlasEngine -eq $true) {
                Write-Output "WT useAtlasEngine: true [WARNING: disable for better CJK IME]"
            } else {
                Write-Output "WT useAtlasEngine: false [OK]"
            }
        } catch {
            Write-Output "WT settings: (parse error)"
        }
    } else {
        Write-Output "WT settings: not found (not using Windows Terminal?)"
    }

    # Clipboard image test
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $img = [System.Windows.Forms.Clipboard]::GetImage()
        if ($img) {
            Write-Output "Clipboard image: available ($($img.Width)x$($img.Height))"
            $img.Dispose()
        } else {
            Write-Output "Clipboard image: none"
        }
    } catch {
        Write-Output "Clipboard image: (check failed)"
    }

    # TASK-116: Startup diagnostics
    Write-Output ""
    Write-Output "=== Startup diagnostics ==="

    # Codex sandbox
    $codexConfig = Join-Path $env:USERPROFILE '.codex' 'config.toml'
    if (Test-Path $codexConfig) {
        $sandbox = (Select-String -Path $codexConfig -Pattern 'sandbox\s*=\s*"([^"]+)"' -ErrorAction SilentlyContinue)
        if ($sandbox) {
            $val = $sandbox.Matches[0].Groups[1].Value
            if ($val -eq 'elevated') {
                Write-Output "Codex sandbox: $val [WARNING: use 'unelevated' to fix --full-auto]"
            } else {
                Write-Output "Codex sandbox: $val [OK]"
            }
        }
    } else {
        Write-Output "Codex config: not found"
    }

    # Manifest
    $manifestPath = Join-Path (Get-Location).Path '.winsmux' 'manifest.yaml'
    Write-Output "Manifest: $(if (Test-Path $manifestPath) { 'exists' } else { 'not found' })"

    # Lock file
    $lockFile = Join-Path (Get-Location).Path '.winsmux' 'orchestra.lock'
    if (Test-Path $lockFile) {
        Write-Output "Startup lock: EXISTS [WARNING: stale lock? Remove to unblock]"
    } else {
        Write-Output "Startup lock: none [OK]"
    }

    # Shield harness
    $shDir = Join-Path (Get-Location).Path '.shield-harness'
    Write-Output "Shield-harness: $(if (Test-Path $shDir) { 'initialized' } else { 'not found' })"

    # Hooks count
    $hooksDir = Join-Path (Get-Location).Path '.claude' 'hooks'
    if (Test-Path $hooksDir) {
        $hookCount = @(Get-ChildItem $hooksDir -Filter '*.js').Count
        Write-Output "Hooks: $hookCount scripts"
    }
}

function Invoke-ImeInput {
    if (-not $Target) { Stop-WithError "usage: winsmux ime-input <target>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName Microsoft.VisualBasic

    $text = [Microsoft.VisualBasic.Interaction]::InputBox(
        "winsmux ペイン $paneId に送信するテキストを入力してください",
        "winsmux IME Input",
        ""
    )

    if ([string]::IsNullOrEmpty($text)) {
        Write-Output "cancelled"
        return
    }

    & winsmux send-keys -t $paneId -l -- "$text"
    Clear-ReadMark $paneId
    Write-Output "sent to $paneId"
}

function Invoke-ImagePaste {
    if (-not $Target) { Stop-WithError "usage: winsmux image-paste <target>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    Add-Type -AssemblyName System.Windows.Forms

    $img = [System.Windows.Forms.Clipboard]::GetImage()
    if (-not $img) {
        Stop-WithError "no image in clipboard"
    }

    $imgDir = Join-Path $env:TEMP "winsmux\images"
    if (-not (Test-Path $imgDir)) {
        New-Item -ItemType Directory -Path $imgDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $imgPath = Join-Path $imgDir "$timestamp.png"
    $img.Save($imgPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $img.Dispose()

    # Send file path as text to the target pane
    & winsmux send-keys -t $paneId -l -- "$imgPath"
    Clear-ReadMark $paneId
    Write-Output "image saved: $imgPath"
    Write-Output "path sent to $paneId"
}

function Invoke-ClipboardPaste {
    if (-not $Target) { Stop-WithError "usage: winsmux clipboard-paste <target>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    $text = Get-Clipboard -Raw
    if ([string]::IsNullOrEmpty($text)) {
        Stop-WithError "clipboard is empty"
    }

    & winsmux send-keys -t $paneId -l -- "$text"
    Clear-ReadMark $paneId
    Write-Output "sent to $paneId"
}

function Get-SignalDir {
    $dir = Join-Path $env:TEMP "winsmux\signals"
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Invoke-Wait {
    if (-not $Target) { Stop-WithError "usage: winsmux wait <channel> [timeout_seconds]" }

    $channel = $Target
    $timeoutSec = 120
    if ($Rest -and $Rest.Count -gt 0) {
        $timeoutSec = [int]$Rest[0]
    }

    $signalDir = Get-SignalDir
    $signalFile = Join-Path $signalDir "$channel.signal"

    # Check if already signaled
    if (Test-Path $signalFile) {
        Remove-Item $signalFile -Force
        Write-Output "received signal: $channel"
        return
    }

    # Poll at 100ms intervals
    $elapsed = 0
    $intervalMs = 100
    $timeoutMs = $timeoutSec * 1000

    while ($elapsed -lt $timeoutMs) {
        if (Test-Path $signalFile) {
            Remove-Item $signalFile -Force
            Write-Output "received signal: $channel"
            return
        }
        Start-Sleep -Milliseconds $intervalMs
        $elapsed += $intervalMs
    }

    Stop-WithError "timeout waiting for signal: $channel (${timeoutSec}s)"
}

function Invoke-Signal {
    if (-not $Target) { Stop-WithError "usage: winsmux signal <channel>" }

    $channel = $Target
    $signalDir = Get-SignalDir
    $signalFile = Join-Path $signalDir "$channel.signal"

    Set-Content -Path $signalFile -Value (Get-Date -Format o) -Encoding UTF8
    Write-Output "sent signal: $channel"
}

function Invoke-Watch {
    if (-not $Target) { Stop-WithError "usage: winsmux watch <label> [silence_seconds] [timeout_seconds]" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    $silenceSec = 10
    $timeoutSec = 120
    if ($Rest -and $Rest.Count -gt 0) { $silenceSec = [int]$Rest[0] }
    if ($Rest -and $Rest.Count -gt 1) { $timeoutSec = [int]$Rest[1] }

    # Initial snapshot
    $output = & winsmux capture-pane -t $paneId -p -J -S -50
    $prevHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes(($output | Out-String))
        )
    ) -replace '-', ''

    $silenceCounter = 0
    $elapsed = 0

    while ($elapsed -lt $timeoutSec) {
        Start-Sleep -Seconds 1
        $elapsed++

        $output = & winsmux capture-pane -t $paneId -p -J -S -50
        $currentHash = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes(($output | Out-String))
            )
        ) -replace '-', ''

        if ($currentHash -eq $prevHash) {
            $silenceCounter++
        } else {
            $silenceCounter = 0
            $prevHash = $currentHash
        }

        if ($silenceCounter -ge $silenceSec) {
            Write-Output "silence detected: $Target (no output for ${silenceSec}s)"
            return
        }
    }

    Stop-WithError "timeout watching $Target (${timeoutSec}s, needed ${silenceSec}s silence)"
}

function Invoke-WaitReady {
    if (-not $Target) { Stop-WithError "usage: winsmux wait-ready <target> [timeout_seconds]" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    $timeoutSec = 60
    if ($Rest -and $Rest.Count -gt 0) { $timeoutSec = [int]$Rest[0] }

    $intervalSec = 2
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $printedDot = $false

    while ((Get-Date) -lt $deadline) {
        if (Test-CodexReadyPrompt $paneId) {
            if ($printedDot) { Write-Host "" }
            exit 0
        }

        Write-Host "." -NoNewline
        $printedDot = $true
        Start-Sleep -Seconds $intervalSec
    }

    if (Test-CodexReadyPrompt $paneId) {
        if ($printedDot) { Write-Host "" }
        exit 0
    }

    if ($printedDot) { Write-Host "" }
    exit 1
}

function Invoke-HealthCheck {
    if ($Target -or ($Rest -and $Rest.Count -gt 0)) {
        Stop-WithError "usage: winsmux health-check"
    }

    $labels = Get-Labels
    if ($labels.Count -eq 0) {
        return
    }

    $orderedLabels = $labels.Keys | Sort-Object
    $initialRuntime = Get-PaneRuntimeMap
    $firstSnapshots = @{}

    foreach ($label in $orderedLabels) {
        $paneId = $labels[$label]
        if (-not $initialRuntime.ContainsKey($paneId) -or -not $initialRuntime[$paneId].IsRunning) {
            continue
        }

        try {
            $firstSnapshots[$label] = Get-PaneSnapshotText -PaneId $paneId
        } catch {
            $firstSnapshots[$label] = $null
        }
    }

    Start-Sleep -Seconds 10

    $finalRuntime = Get-PaneRuntimeMap

    foreach ($label in $orderedLabels) {
        $paneId = $labels[$label]
        $status = 'DEAD'

        if ($finalRuntime.ContainsKey($paneId) -and $finalRuntime[$paneId].IsRunning) {
            try {
                $secondSnapshot = Get-PaneSnapshotText -PaneId $paneId
                if (Test-CodexReadyPromptText $secondSnapshot) {
                    $status = 'READY'
                } else {
                    $firstSnapshot = $null
                    if ($firstSnapshots.ContainsKey($label)) {
                        $firstSnapshot = $firstSnapshots[$label]
                    }

                    if ((Get-TextHash $firstSnapshot) -eq (Get-TextHash $secondSnapshot)) {
                        $status = 'HUNG'
                    } else {
                        $status = 'BUSY'
                    }
                }
            } catch {
                $status = 'DEAD'
            }
        }

        Write-Output "$label $paneId $status"
    }
}

function Invoke-Focus {
    param([string]$FocusTarget = $Target)

    if (-not $FocusTarget) { Stop-WithError "usage: winsmux focus <label|target>" }

    $paneId = Resolve-Target $FocusTarget
    $paneId = Confirm-Target $paneId
    Assert-FocusAllowed -PaneId $paneId -RawTarget $FocusTarget

    & winsmux select-pane -t $paneId
    Write-Output "Focused pane $paneId ($FocusTarget)"
}

function Invoke-FocusLock {
    param([string]$FocusTarget = $Target)

    if (-not $FocusTarget) { Stop-WithError "usage: winsmux focus-lock <label|target>" }

    $paneId = Resolve-Target $FocusTarget
    $paneId = Confirm-Target $paneId
    $entry = Push-FocusPolicy -PaneId $paneId -TargetName $FocusTarget

    Write-Output "Focus locked to $($entry.paneId) ($($entry.target))"
}

function Invoke-FocusUnlock {
    param(
        [string]$FocusTarget = $Target,
        [string[]]$ExtraArgs = $Rest
    )

    if ($FocusTarget -or ($ExtraArgs -and $ExtraArgs.Count -gt 0)) {
        Stop-WithError "usage: winsmux focus-unlock"
    }

    $entry = Pop-FocusPolicy
    if ($null -eq $entry) {
        Write-Output "(no focus lock)"
        return
    }

    Write-Output "Focus unlocked $($entry.paneId) ($($entry.target))"
}

function Invoke-Profile {
    $fragmentDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments\winsmux"
    $fragmentFile = Join-Path $fragmentDir "winsmux.json"

    if (-not $Target) {
        # Show current fragment
        if (Test-Path $fragmentFile) {
            Get-Content $fragmentFile -Raw
        } else {
            Write-Host "No Windows Terminal fragment registered. Run: winsmux install"
        }
        return
    }

    # Generate custom profile fragment
    # $Target = profile name, $Rest = agent definitions like "builder:codex" "reviewer:claude"
    $profileName = $Target
    $agents = @()
    if ($Rest -and $Rest.Count -gt 0) {
        foreach ($def in $Rest) {
            $agents += $def
        }
    }

    $agentComment = ""
    if ($agents.Count -gt 0) {
        $agentComment = " # agents: $($agents -join ', ')"
    }

    if (-not (Test-Path $fragmentDir)) {
        New-Item -ItemType Directory -Path $fragmentDir -Force | Out-Null
    }

    $fragment = @{
        profiles = @(
            @{
                name             = "winsmux $profileName"
                commandline      = "pwsh -NoProfile -Command `"& '%USERPROFILE%\.winsmux\bin\winsmux-core.ps1' doctor; winsmux new-session -s $profileName; pwsh '%USERPROFILE%\.winsmux\bin\start-orchestra.ps1'`""
                icon             = "`u{1F3BC}"
                startingDirectory = "%USERPROFILE%"
                tabTitle         = "winsmux $profileName"
            }
        )
    }

    $json = $fragment | ConvertTo-Json -Depth 4
    Set-Content -Path $fragmentFile -Value $json -Encoding UTF8
    Write-Output "Registered WT profile: winsmux $profileName"
    Write-Output "Fragment: $fragmentFile"
    if ($agents.Count -gt 0) {
        Write-Output "Agents: $($agents -join ', ')"
    }
}

# --- Vault Commands ---

function Invoke-VaultSet {
    $key = $Target
    $value = if ($Rest) { $Rest -join ' ' } else { '' }
    if (-not $key) { Stop-WithError "usage: winsmux vault set <key> [value]" }
    if (-not $value) {
        $secure = Read-Host -AsSecureString "Enter value for '$key'"
        $value = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    }

    $credTarget = "winsmux:$key"
    $valueBytes = [System.Text.Encoding]::Unicode.GetBytes($value)
    $blobPtr = [Runtime.InteropServices.Marshal]::AllocHGlobal($valueBytes.Length)
    [Runtime.InteropServices.Marshal]::Copy($valueBytes, 0, $blobPtr, $valueBytes.Length)

    $cred = New-Object WinCred+CREDENTIAL
    $cred.Type = [WinCred]::CRED_TYPE_GENERIC
    $cred.TargetName = $credTarget
    $cred.UserName = "winsmux"
    $cred.CredentialBlobSize = $valueBytes.Length
    $cred.CredentialBlob = $blobPtr
    $cred.Persist = [WinCred]::CRED_PERSIST_LOCAL_MACHINE

    try {
        $ok = [WinCred]::CredWrite([ref]$cred, 0)
        if (-not $ok) {
            $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Stop-WithError "CredWrite failed (error $errCode)"
        }
        Write-Host "Stored credential: $key"
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($blobPtr)
    }
}

function Invoke-VaultGet {
    $key = $Target
    if (-not $key) { Stop-WithError "usage: winsmux vault get <key>" }

    $credTarget = "winsmux:$key"
    $credPtr = [IntPtr]::Zero

    $ok = [WinCred]::CredRead($credTarget, [WinCred]::CRED_TYPE_GENERIC, 0, [ref]$credPtr)
    if (-not $ok) {
        $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errCode -eq 1168) {
            Stop-WithError "credential not found: $key"
        }
        Stop-WithError "CredRead failed (error $errCode)"
    }

    try {
        $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($credPtr, [Type][WinCred+CREDENTIAL])
        if ($cred.CredentialBlobSize -gt 0) {
            $bytes = New-Object byte[] $cred.CredentialBlobSize
            [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
            $value = [System.Text.Encoding]::Unicode.GetString($bytes)
            Write-Output $value
        }
    } finally {
        [WinCred]::CredFree($credPtr) | Out-Null
    }
}

function Invoke-VaultList {
    $filter = "winsmux:*"
    $count = 0
    $credsPtr = [IntPtr]::Zero

    $ok = [WinCred]::CredEnumerate($filter, 0, [ref]$count, [ref]$credsPtr)
    if (-not $ok) {
        $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errCode -eq 1168) {
            Write-Output "(no credentials stored)"
            return
        }
        Stop-WithError "CredEnumerate failed (error $errCode)"
    }

    try {
        $ptrSize = [Runtime.InteropServices.Marshal]::SizeOf([Type][IntPtr])
        for ($i = 0; $i -lt $count; $i++) {
            $entryPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($credsPtr, $i * $ptrSize)
            $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($entryPtr, [Type][WinCred+CREDENTIAL])
            $name = $cred.TargetName -replace '^winsmux:', ''
            Write-Output $name
        }
    } finally {
        [WinCred]::CredFree($credsPtr) | Out-Null
    }
}

function Invoke-VaultInject {
    if (-not $Target) { Stop-WithError "usage: winsmux vault inject <pane>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId
    Assert-ReadMark $paneId

    # Enumerate all winsmux:* credentials
    $filter = "winsmux:*"
    $count = 0
    $credsPtr = [IntPtr]::Zero

    $ok = [WinCred]::CredEnumerate($filter, 0, [ref]$count, [ref]$credsPtr)
    if (-not $ok) {
        $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errCode -eq 1168) {
            Write-Output "no credentials to inject"
            return
        }
        Stop-WithError "CredEnumerate failed (error $errCode)"
    }

    $injected = 0
    try {
        $ptrSize = [Runtime.InteropServices.Marshal]::SizeOf([Type][IntPtr])
        for ($i = 0; $i -lt $count; $i++) {
            $entryPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($credsPtr, $i * $ptrSize)
            $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($entryPtr, [Type][WinCred+CREDENTIAL])
            $envName = $cred.TargetName -replace '^winsmux:', ''

            $value = ''
            if ($cred.CredentialBlobSize -gt 0) {
                $bytes = New-Object byte[] $cred.CredentialBlobSize
                [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
                $value = [System.Text.Encoding]::Unicode.GetString($bytes)
            }

            # Escape single quotes in value for safe injection
            $escapedValue = $value -replace "'", "''"
            $setCmd = "`$env:$envName = '$escapedValue'"
            & winsmux send-keys -t $paneId -l -- "$setCmd"
            & winsmux send-keys -t $paneId Enter
            Start-Sleep -Milliseconds 100
            $injected++
        }
    } finally {
        [WinCred]::CredFree($credsPtr) | Out-Null
    }

    Clear-ReadMark $paneId
    Write-Output "injected $injected credential(s) into $paneId"
}

function Invoke-Version {
    Write-Output "winsmux $VERSION"
}

function Show-Usage {
    Write-Output @"
winsmux $VERSION - winsmux bridge for winsmux

Commands:
  id                        Show current pane ID
  list                      List all panes
  read <target> [lines]     Capture pane output (default 50 lines)
  type <target> <text>      Send literal text to pane
  keys <target> <key>...    Send key sequences to pane
  message <target> <text>   Send a tagged message to pane (no Enter)
  send <target> <text>      Send a tagged message AND press Enter (recommended)
  name <target> <label>     Label a pane
  resolve <label>           Resolve label to pane ID
  ime-input <target>        Open GUI dialog for Japanese IME input
  image-paste <target>      Save clipboard image and send path to pane
  clipboard-paste <target>  Send clipboard text to pane
  focus <label|target>      Switch active pane (use from outside winsmux)
  focus-lock <target>       Push a focus lock for a pane target
  focus-unlock              Pop the latest focus lock
  lock <label> <file>...    Acquire file lock(s) for a label
  unlock <label> <file>...  Release file lock(s) for a label
  locks                     List active file locks
  verify <pr-number>        Run Pester in tests/ and merge PR only on PASS
  wait <channel> [timeout]  Block until signal received (replaces polling)
  wait-ready <target> [timeout_seconds]  Wait for Codex prompt in pane
  health-check              Report READY/BUSY/HUNG/DEAD for labeled panes
  signal <channel>          Send signal to unblock a waiting process
  watch <label> [silence_s] [timeout_s]  Block until pane output is silent
  dispatch-route <text>   Route text to appropriate pane by keyword detection
  pipeline <task>       Run plan-exec-verify-fix loop for a task
  builder-queue <action> [args]  Manage Builder queue and auto-dispatch next work
  vault set <key> [value]   Store a credential securely (DPAPI)
  vault get <key>           Retrieve a stored credential
  vault inject <pane>       Inject all credentials as env vars into a pane
  vault list                List stored credential keys
  profile [name] [agents]   Show or register WT dropdown profile
  mailbox-create <ch>       Create Named Pipe mailbox listener
  mailbox-send <ch> <json>  Send JSON message to mailbox channel
  mailbox-listen <ch>       Alias for mailbox-create
  kill <target>             Stop pane process and respawn its shell
  restart <target>          Restart the pane agent using manifest context
  doctor                    Check environment and IME diagnostics
  version                   Show version
"@
}

# --- Named Pipe Mailbox ---
function Get-MailboxPipeName {
    param([string]$Channel)

    if ([string]::IsNullOrWhiteSpace($Channel)) {
        Stop-WithError "mailbox channel must not be empty"
    }
    # Sanitize: allow only alphanumeric, hyphen, underscore
    if ($Channel -notmatch '^[a-zA-Z0-9_-]+$') {
        Stop-WithError "mailbox channel name must be alphanumeric (with - and _ allowed)"
    }

    return "winsmux-mailbox-$Channel"
}

function Invoke-MailboxCreate {
    if (-not $Target) { Stop-WithError "usage: winsmux mailbox-create <channel>" }

    $pipeName = Get-MailboxPipeName $Target
    Write-Output "mailbox listening: $pipeName"

    while ($true) {
        $server = $null
        try {
            $server = [System.IO.Pipes.NamedPipeServerStream]::new(
                $pipeName,
                [System.IO.Pipes.PipeDirection]::In,
                [System.IO.Pipes.NamedPipeServerStream]::MaxAllowedServerInstances,
                [System.IO.Pipes.PipeTransmissionMode]::Byte,
                [System.IO.Pipes.PipeOptions]::None
            )

            $server.WaitForConnection()
            $reader = [System.IO.StreamReader]::new($server, [System.Text.Encoding]::UTF8)
            try {
                $payload = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }

            if ([string]::IsNullOrWhiteSpace($payload)) {
                continue
            }

            try {
                $message = $payload | ConvertFrom-Json -ErrorAction Stop
                [ordered]@{
                    from      = $message.from
                    to        = $message.to
                    content   = $message.content
                    timestamp = $message.timestamp
                } | ConvertTo-Json -Compress | Write-Output
            } catch {
                Write-Warning "invalid mailbox payload on $pipeName"
            }
        } catch {
            Write-Warning "mailbox connection error on ${pipeName}: $($_.Exception.Message)"
            Start-Sleep -Milliseconds 500
        } finally {
            if ($server) { $server.Dispose() }
        }
    }
}

function Invoke-MailboxSend {
    if (-not $Target) { Stop-WithError "usage: winsmux mailbox-send <channel> <json>" }
    if (-not $Rest -or $Rest.Count -eq 0) {
        Stop-WithError "usage: winsmux mailbox-send <channel> <json>"
    }

    $pipeName = Get-MailboxPipeName $Target
    $payload = $Rest -join ' '

    # Validate JSON
    try {
        $null = $payload | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Stop-WithError "mailbox-send: payload must be valid JSON"
    }

    $client = [System.IO.Pipes.NamedPipeClientStream]::new(
        ".",
        $pipeName,
        [System.IO.Pipes.PipeDirection]::Out
    )

    try {
        $client.Connect(5000)
        $writer = [System.IO.StreamWriter]::new($client, [System.Text.Encoding]::UTF8)
        try {
            $writer.AutoFlush = $true
            $writer.Write($payload)
        } finally {
            $writer.Dispose()
        }
    } catch {
        Stop-WithError "failed to send mailbox message to ${pipeName}: $($_.Exception.Message)"
    } finally {
        $client.Dispose()
    }

    Write-Output "mailbox sent: $pipeName"
}

function Invoke-MailboxListen {
    Invoke-MailboxCreate
}

# --- Kill / Restart ---
function Invoke-Kill {
    if (-not $Target) { Stop-WithError "usage: winsmux kill <target>" }
    if ($Rest -and $Rest.Count -gt 0) { Stop-WithError "usage: winsmux kill <target>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    & winsmux respawn-pane -k -t $paneId
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "failed to kill pane process: $paneId"
    }

    Clear-ReadMark $paneId
    Clear-Watermark $paneId
    Write-Output "killed $paneId"
}

function Invoke-Restart {
    if (-not $Target) { Stop-WithError "usage: winsmux restart <target>" }
    if ($Rest -and $Rest.Count -gt 0) { Stop-WithError "usage: winsmux restart <target>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId
    $projectDir = (Get-Location).Path

    $settings = $null
    if (Get-Command Get-BridgeSettings -ErrorAction SilentlyContinue) {
        $settings = Get-BridgeSettings
    }

    $plan = Get-PaneControlRestartPlan -ProjectDir $projectDir -PaneId $paneId -Settings $settings

    & winsmux respawn-pane -k -t $paneId -c $plan.LaunchDir
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "failed to restart pane shell: $paneId"
    }

    Wait-PaneShellReady -PaneId $paneId
    & winsmux send-keys -t $paneId -l -- "$($plan.LaunchCommand)"
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "failed to send launch command to $paneId"
    }
    & winsmux send-keys -t $paneId Enter
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "failed to submit launch command to $paneId"
    }

    Clear-ReadMark $paneId
    Clear-Watermark $paneId

    if ($plan.Agent.Trim().ToLowerInvariant() -eq 'codex') {
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            if (Test-CodexReadyPrompt $paneId) {
                Write-Output "restarted $paneId ($($plan.Label))"
                return
            }

            Start-Sleep -Seconds 2
        }

        Stop-WithError "timed out waiting for Codex after restart in $paneId"
    }

    Write-Output "restarted $paneId ($($plan.Label))"
}

# --- Dispatch ---
switch ($Command) {
    'id'              { Invoke-Id }
    'list'            { Invoke-List }
    'read'            { Invoke-Read }
    'type'            { Invoke-Type }
    'keys'            { Invoke-Keys }
    'message'         { Invoke-Message }
    'send'            { Invoke-Send }
    'name'            { Invoke-Name }
    'resolve'         { Invoke-Resolve }
    'ime-input'       { Invoke-ImeInput }
    'image-paste'     { Invoke-ImagePaste }
    'clipboard-paste' { Invoke-ClipboardPaste }
    'focus'           { Invoke-Focus }
    'focus-lock'      { Invoke-FocusLock }
    'focus-unlock'    { Invoke-FocusUnlock }
    'lock'            { Invoke-Lock }
    'unlock'          { Invoke-Unlock }
    'locks'           { Invoke-Locks }
    'verify'          { Invoke-Verify }
    'dispatch-route'  {
        $routerScript = Join-Path $PSScriptRoot '..\winsmux-core\scripts\dispatch-router.ps1'
        $fullText = @($Target) + @($Rest) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        & $routerScript -Text ($fullText -join ' ')
    }
    'task-split' {
        $splitterScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\task-splitter.ps1'))
        $taskText = (@($Target) + @($Rest) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
        if (-not $taskText) {
            Stop-WithError "usage: winsmux task-split <task text>"
        }

        & pwsh -NoProfile -File $splitterScript -Task $taskText -AsJson
    }
    'pipeline' {
        $pipelineScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\team-pipeline.ps1'))
        $taskText = (@($Target) + @($Rest) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
        if ($taskText) {
            & pwsh -NoProfile -File $pipelineScript -Task $taskText
        } else {
            & pwsh -NoProfile -File $pipelineScript
        }
    }
    'builder-queue' {
        $queueScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\builder-queue.ps1'))
        switch ($Target) {
            'add' {
                if (-not $Rest -or $Rest.Count -lt 2) {
                    Stop-WithError "usage: winsmux builder-queue add <builder-label> <task>"
                }

                $builderLabel = $Rest[0]
                $taskText = (@($Rest | Select-Object -Skip 1) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
                & pwsh -NoProfile -File $queueScript -Action add -ProjectDir (Get-Location).Path -BuilderLabel $builderLabel -Task $taskText
            }
            'list' {
                $builderLabel = if ($Rest -and $Rest.Count -gt 0) { $Rest[0] } else { '' }
                & pwsh -NoProfile -File $queueScript -Action list -ProjectDir (Get-Location).Path -BuilderLabel $builderLabel
            }
            'dispatch-next' {
                if (-not $Rest -or $Rest.Count -lt 1) {
                    Stop-WithError "usage: winsmux builder-queue dispatch-next <builder-label>"
                }

                & pwsh -NoProfile -File $queueScript -Action 'dispatch-next' -ProjectDir (Get-Location).Path -BuilderLabel $Rest[0]
            }
            'complete' {
                if (-not $Rest -or $Rest.Count -lt 1) {
                    Stop-WithError "usage: winsmux builder-queue complete <builder-label> [task]"
                }

                $builderLabel = $Rest[0]
                $taskText = (@($Rest | Select-Object -Skip 1) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
                if ($taskText) {
                    & pwsh -NoProfile -File $queueScript -Action complete -ProjectDir (Get-Location).Path -BuilderLabel $builderLabel -Task $taskText
                } else {
                    & pwsh -NoProfile -File $queueScript -Action complete -ProjectDir (Get-Location).Path -BuilderLabel $builderLabel
                }
            }
            default {
                Stop-WithError "usage: winsmux builder-queue [add|list|dispatch-next|complete] ..."
            }
        }
    }
    'vault'           {
        switch ($Target) {
            'set'    { $Target = $Rest[0]; $Rest = @($Rest | Select-Object -Skip 1); Invoke-VaultSet }
            'get'    { $Target = $Rest[0]; Invoke-VaultGet }
            'inject' { $Target = $Rest[0]; Invoke-VaultInject }
            'list'   { Invoke-VaultList }
            default  { Stop-WithError "usage: winsmux vault [set|get|inject|list]" }
        }
    }
    'wait'            { Invoke-Wait }
    'wait-ready'      { Invoke-WaitReady }
    'health-check'    { Invoke-HealthCheck }
    'signal'          { Invoke-Signal }
    'mailbox-create'  { Invoke-MailboxCreate }
    'mailbox-send'    { Invoke-MailboxSend }
    'mailbox-listen'  { Invoke-MailboxListen }
    'watch'           { Invoke-Watch }
    'profile'         { Invoke-Profile }
    'doctor'          { Invoke-Doctor }
    'version'         { Invoke-Version }
    'monitor' {
        $monitorScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\winsmux-core\scripts\agent-monitor.ps1'))
        & pwsh -NoProfile -File $monitorScript
    }
    'role'            { Invoke-Role }
    'auto-rebalance'  { Invoke-AutoRebalance }
    'kill'            { Invoke-Kill }
    'restart'         { Invoke-Restart }
    ''                { Show-Usage }
    default           { Stop-WithError "unknown command: $Command. Run without arguments for usage." }
}
