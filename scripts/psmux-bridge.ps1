[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Command,
    [Parameter(Position=1)][string]$Target,
    [Parameter(Position=2, ValueFromRemainingArguments=$true)][string[]]$Rest
)

# --- Config ---
$VERSION = "0.2.0"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$ReadMarkDir = Join-Path $env:TEMP "winsmux\read_marks"
$LabelsFile  = Join-Path $env:APPDATA "winsmux\labels.json"

# --- Helper: Stop-WithError ---
function Stop-WithError {
    param([string]$Message)
    Write-Error $Message
    exit 1
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
    # display-message -t ignores the -t flag in psmux v3.3.1, so validate via list-panes
    $allPanes = (& psmux list-panes -a -F '#{pane_id}' | Out-String).Trim() -split "`n" | ForEach-Object { $_.Trim() }
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
        Stop-WithError "error: must read the pane before interacting. Run: psmux-bridge read $PaneId"
    }
}

function Clear-ReadMark {
    param([string]$PaneId)
    $path = Get-ReadMarkPath $PaneId
    if (Test-Path $path) {
        Remove-Item -Path $path -Force
    }
}

# --- Commands ---

function Invoke-Id {
    if ($env:TMUX_PANE) {
        Write-Output $env:TMUX_PANE
    } else {
        $id = & psmux display-message -p '#{pane_id}'
        Write-Output ($id | Out-String).Trim()
    }
}

function Invoke-List {
    $raw = & psmux list-panes -a -F '#{pane_id} #{pane_pid} #{pane_current_command} #{pane_width}x#{pane_height} #{pane_title}'
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
            $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $panePid" -ErrorAction SilentlyContinue
            if ($children) {
                $child = $children | Select-Object -First 1
                $childCmd = $child.Name
            }
        } catch { }

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
    if (-not $Target) { Stop-WithError "usage: psmux-bridge read <target> [lines]" }

    $lines = 50
    if ($Rest -and $Rest.Count -gt 0) {
        $lines = [int]$Rest[0]
    }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    $output = & psmux capture-pane -t $paneId -p -J -S "-$lines"
    Write-Output ($output | Out-String).TrimEnd()

    Set-ReadMark $paneId
}

function Invoke-Type {
    if (-not $Target) { Stop-WithError "usage: psmux-bridge type <target> <text>" }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: psmux-bridge type <target> <text>" }

    $text = $Rest -join ' '
    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    & psmux send-keys -t $paneId -l -- "$text"

    Clear-ReadMark $paneId
}

function Invoke-Keys {
    if (-not $Target) { Stop-WithError "usage: psmux-bridge keys <target> <key>..." }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: psmux-bridge keys <target> <key>..." }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    foreach ($key in $Rest) {
        & psmux send-keys -t $paneId $key
    }

    Clear-ReadMark $paneId
}

function Invoke-Message {
    if (-not $Target) { Stop-WithError "usage: psmux-bridge message <target> <text>" }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: psmux-bridge message <target> <text>" }

    $text = $Rest -join ' '
    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    $myId = (& psmux display-message -p '#{pane_id}' | Out-String).Trim()
    $myCoord = (& psmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' | Out-String).Trim()
    $agentName = if ($env:WINSMUX_AGENT_NAME) { $env:WINSMUX_AGENT_NAME } else { "unknown" }

    $header = "[psmux-bridge from:$agentName pane:$myId at:$myCoord -- load the winsmux skill to reply]"
    & psmux send-keys -t $paneId -l -- "$header $text"

    Clear-ReadMark $paneId
}

function Invoke-Send {
    if (-not $Target) { Stop-WithError "usage: psmux-bridge send <target> <text>" }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: psmux-bridge send <target> <text>" }

    $text = $Rest -join ' '
    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    # Step 1: READ (satisfy read guard)
    $output = & psmux capture-pane -t $paneId -p -J -S "-5"
    Set-ReadMark $paneId

    # Step 2: MESSAGE (type header + text)
    $myId = (& psmux display-message -p '#{pane_id}' | Out-String).Trim()
    $myCoord = (& psmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' | Out-String).Trim()
    $agentName = if ($env:WINSMUX_AGENT_NAME) { $env:WINSMUX_AGENT_NAME } else { "unknown" }

    $header = "[psmux-bridge from:$agentName pane:$myId at:$myCoord -- load the winsmux skill to reply]"
    & psmux send-keys -t $paneId -l -- "$header $text"
    Clear-ReadMark $paneId

    # Step 3: READ (verify text landed)
    Start-Sleep -Milliseconds 200
    $verify = & psmux capture-pane -t $paneId -p -J -S "-3"
    Set-ReadMark $paneId

    # Step 4: KEYS Enter (submit)
    & psmux send-keys -t $paneId Enter
    Clear-ReadMark $paneId

    Write-Output "sent to $paneId"
}

function Invoke-Name {
    if (-not $Target) { Stop-WithError "usage: psmux-bridge name <target> <label>" }
    if (-not $Rest -or $Rest.Count -eq 0) { Stop-WithError "usage: psmux-bridge name <target> <label>" }

    $label = $Rest[0]
    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    $labels = Get-Labels
    $labels[$label] = $paneId
    Save-Labels $labels

    # Also set pane title (best-effort)
    try {
        & psmux select-pane -t $paneId -T "$label" 2>$null
    } catch { }

    Write-Output "Labeled pane $paneId as '$label'"
}

function Invoke-Resolve {
    if (-not $Target) { Stop-WithError "usage: psmux-bridge resolve <label>" }

    $labels = Get-Labels
    if ($labels.ContainsKey($Target)) {
        Write-Output $labels[$Target]
    } else {
        Stop-WithError "label not found: $Target"
    }
}

function Invoke-Doctor {
    Write-Output "=== psmux-bridge doctor ==="

    # psmux install check
    try {
        $ver = & psmux -V 2>&1
        Write-Output "psmux: $($ver | Out-String)".Trim()
    } catch {
        Write-Output "psmux: NOT FOUND"
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
        $panes = & psmux list-panes -a -F '#{pane_id}'
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
        $escTime = (& psmux show-options -g -v escape-time 2>&1 | Out-String).Trim()
        if ($escTime -match '^\d+$' -and [int]$escTime -gt 50) {
            Write-Output "escape-time: $escTime ms [WARNING: >50ms causes IME lag. Set to 0 in .psmux.conf]"
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
}

function Invoke-ImeInput {
    if (-not $Target) { Stop-WithError "usage: psmux-bridge ime-input <target>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName Microsoft.VisualBasic

    $text = [Microsoft.VisualBasic.Interaction]::InputBox(
        "psmux ペイン $paneId に送信するテキストを入力してください",
        "winsmux IME Input",
        ""
    )

    if ([string]::IsNullOrEmpty($text)) {
        Write-Output "cancelled"
        return
    }

    & psmux send-keys -t $paneId -l -- "$text"
    Clear-ReadMark $paneId
    Write-Output "sent to $paneId"
}

function Invoke-ImagePaste {
    if (-not $Target) { Stop-WithError "usage: psmux-bridge image-paste <target>" }

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
    & psmux send-keys -t $paneId -l -- "$imgPath"
    Clear-ReadMark $paneId
    Write-Output "image saved: $imgPath"
    Write-Output "path sent to $paneId"
}

function Invoke-ClipboardPaste {
    if (-not $Target) { Stop-WithError "usage: psmux-bridge clipboard-paste <target>" }

    $paneId = Resolve-Target $Target
    $paneId = Confirm-Target $paneId

    Assert-ReadMark $paneId

    $text = Get-Clipboard -Raw
    if ([string]::IsNullOrEmpty($text)) {
        Stop-WithError "clipboard is empty"
    }

    & psmux send-keys -t $paneId -l -- "$text"
    Clear-ReadMark $paneId
    Write-Output "sent to $paneId"
}

function Invoke-Version {
    Write-Output "psmux-bridge $VERSION"
}

function Show-Usage {
    Write-Output @"
psmux-bridge $VERSION - psmux bridge for winsmux

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
  doctor                    Check environment and IME diagnostics
  version                   Show version
"@
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
    'doctor'          { Invoke-Doctor }
    'version'         { Invoke-Version }
    ''                { Show-Usage }
    default           { Stop-WithError "unknown command: $Command. Run without arguments for usage." }
}
