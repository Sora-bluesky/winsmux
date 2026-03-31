# start-orchestra.ps1 — Flexible N-pane orchestra setup (run AFTER psmux is started)
# Usage:
#   # Default 2x2 (backward compatible):
#   pwsh scripts/start-orchestra.ps1
#
#   # Custom 3x2 with mixed agents:
#   pwsh scripts/start-orchestra.ps1 -Rows 2 -Cols 3 -Agents @(
#     @{label="builder-1"; command="codex --full-auto"},
#     @{label="builder-2"; command="codex --full-auto"},
#     @{label="builder-3"; command="gemini --model gemini-3.1-pro-preview --yolo"},
#     @{label="researcher"; command="claude --model sonnet"},
#     @{label="builder-4"; command="gemini --model gemini-3-flash-preview --yolo"},
#     @{label="reviewer"; command="codex --full-auto"}
#   ) -ShieldHarness
#
# Prerequisite: user has already started psmux in their terminal.
# This script splits panes and launches agents into the running session.

[CmdletBinding()]
param(
    [string]$ProjectDir = (Get-Location).Path,
    [int]$Rows = 2,
    [int]$Cols = 2,
    [hashtable[]]$Agents,
    [string]$CommanderPromptFile,
    [switch]$ShieldHarness
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Show-WinsmuxBanner {
    $bannerScript = Join-Path $PSScriptRoot "banner.mjs"
    if ((Get-Command node -ErrorAction SilentlyContinue) -and (Test-Path $bannerScript)) {
        node $bannerScript 2>$null
    } else {
        $esc = [char]27
        Write-Host "${esc}[38;2;29;161;242mWINSMUX${esc}[0m — Orchestra bootstrap"
    }
}

Show-WinsmuxBanner

# --- Default agents (backward compatible 2x2) ---
if (-not $Agents -or $Agents.Count -eq 0) {
    $Agents = @(
        @{ label = "builder";    command = "codex" },
        @{ label = "researcher"; command = "claude --model sonnet" },
        @{ label = "reviewer";   command = "codex" },
        @{ label = "monitor";    command = "pwsh" }
    )
}

# --- Validate grid ---
$expectedPanes = $Rows * $Cols
if ($Agents.Count -ne $expectedPanes) {
    Write-Error "Grid is ${Rows}x${Cols} ($expectedPanes panes) but $($Agents.Count) agents provided."
    exit 1
}

# --- Shield Harness (opt-in) ---
$shieldActive = $false
if ($ShieldHarness) {
    $markerFile = Join-Path $ProjectDir ".claude\hooks\sh-gate.js"
    if (Test-Path $markerFile) {
        Write-Output "[shield-harness] Detected in $ProjectDir"
        $shieldActive = $true
    } else {
        Write-Output "[shield-harness] Initializing in $ProjectDir ..."
        Push-Location $ProjectDir
        try {
            npx shield-harness init --profile standard
            if ($LASTEXITCODE -eq 0) {
                Write-Output "[shield-harness] Initialized successfully"
                $shieldActive = $true
            } else {
                Write-Warning "[shield-harness] Init failed (exit code $LASTEXITCODE). Continuing without shield-harness."
            }
        } catch {
            Write-Warning "[shield-harness] Init failed: $_. Continuing without shield-harness."
        }
        Pop-Location
    }
}

# --- Approval-free mode flags (only with ShieldHarness) ---
function Get-ApprovalFreeCommand {
    param([string]$Cmd)
    if (-not $shieldActive) { return $Cmd }

    if ($Cmd -match '^claude\b' -and $Cmd -notmatch '--permission-mode') {
        return "$Cmd --permission-mode bypassPermissions"
    }
    if ($Cmd -match '^codex\b' -and $Cmd -notmatch '--full-auto') {
        return "$Cmd --full-auto"
    }
    if ($Cmd -match '^gemini\b' -and $Cmd -notmatch '--yolo') {
        return "$Cmd --yolo"
    }
    return $Cmd
}

# --- Detect running session ---
$session = (psmux list-sessions -F '#{session_name}' 2>$null | Select-Object -First 1)
if (-not $session) {
    Write-Error "No psmux session found. Start psmux first, then run this script."
    exit 1
}
$session = $session.Trim()

function Get-ColumnMajorPaneIds {
    param([string]$TargetSession)

    return @(psmux list-panes -t $TargetSession -F '#{pane_id},#{pane_left},#{pane_top}' 2>$null |
        ForEach-Object {
            $line = $_.Trim()
            if (-not $line) { return }

            $parts = $line -split ','
            if ($parts.Count -ne 3) { return }

            [PSCustomObject]@{
                Id   = $parts[0]
                Left = [int]$parts[1]
                Top  = [int]$parts[2]
            }
        } |
        Sort-Object Left, Top |
        ForEach-Object { $_.Id })
}

# --- Reset state before creating the grid ---
$labelsFile = Join-Path $env:APPDATA "winsmux\labels.json"
$labelsDir = Split-Path -Path $labelsFile -Parent
if (-not (Test-Path $labelsDir)) {
    New-Item -ItemType Directory -Path $labelsDir -Force | Out-Null
}
Set-Content -Path $labelsFile -Value '{}' -Encoding UTF8
Write-Output "[orchestra] Cleared labels.json"

$existingPaneIds = @(psmux list-panes -t $session -F '#{pane_id}' 2>$null |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ })
if ($existingPaneIds.Count -gt 1) {
    Write-Output "[orchestra] Cleaning up $($existingPaneIds.Count - 1) existing pane(s)..."
    foreach ($paneId in ($existingPaneIds | Select-Object -Skip 1)) {
        psmux kill-pane -t $paneId 2>$null
    }
    Start-Sleep -Milliseconds 300
}

# --- Create dynamic grid ---
# Step 1: Horizontal splits to create columns
for ($c = 0; $c -lt $Cols - 1; $c++) {
    psmux split-window -h -t $session -c $ProjectDir
}

# Step 2: Even out column widths
psmux select-layout -t $session even-horizontal

Start-Sleep -Milliseconds 300

# Step 3: Vertical splits within each column
$colPanes = psmux list-panes -t $session -F '#{pane_id}' 2>$null
$colPaneIds = ($colPanes | Out-String).Trim() -split "`n" | ForEach-Object { $_.Trim() }

foreach ($colPane in $colPaneIds) {
    for ($r = 0; $r -lt $Rows - 1; $r++) {
        psmux split-window -v -t $colPane -c $ProjectDir
    }
}

Start-Sleep -Milliseconds 500

# --- Get final pane IDs (sorted by visual position: column-major) ---
$paneIds = Get-ColumnMajorPaneIds -TargetSession $session

if ($paneIds.Count -ne $expectedPanes) {
    Write-Warning "Expected $expectedPanes panes but got $($paneIds.Count). Layout may be incorrect."
}

# --- Assign labels ---
$bridgePath = Join-Path $PSScriptRoot "psmux-bridge.ps1"
$paneMap = @{}

for ($i = 0; $i -lt [Math]::Min($Agents.Count, $paneIds.Count); $i++) {
    $label = $Agents[$i].label
    $paneId = $paneIds[$i]
    $paneMap[$label] = $paneId
    pwsh $bridgePath name $paneId $label 2>$null | Out-Null
}

# --- Generate commander prompt ---
$promptFile = $CommanderPromptFile
if (-not $promptFile) {
    $promptFile = Join-Path $ProjectDir ".commander-prompt.txt"
}

$builderLabels = ($Agents | Where-Object { $_.label -match 'builder' } | ForEach-Object { $_.label }) -join ', '
$researcherLabels = ($Agents | Where-Object { $_.label -match 'researcher' } | ForEach-Object { $_.label }) -join ', '
$reviewerLabels = ($Agents | Where-Object { $_.label -match 'reviewer' } | ForEach-Object { $_.label }) -join ', '

$agentRows = $Agents | ForEach-Object {
    "| $($_.label) | $($paneMap[$_.label]) | $($_.command) |"
}

$promptContent = @"
You are the COMMANDER in a winsmux Orchestra. You run directly in the user's terminal. $($Agents.Count) background agents run in psmux panes.

## Background Agents

| Label | Pane | Command |
|-------|------|---------|
$($agentRows -join "`n")

## Communication (psmux-bridge)

``````powershell
# Send task to an agent
pwsh $bridgePath send <label> "<instruction>"

# Read agent output (polling)
pwsh $bridgePath read <label>
``````

## Rules
1. NEVER write code yourself. Delegate to builders ($builderLabels).
2. Use researchers ($researcherLabels) for investigation, testing, docs.
3. Use reviewers ($reviewerLabels) for code review after builders complete.
4. Assign each builder INDEPENDENT file sets to avoid conflicts.
5. Poll all agents with ``read`` to check progress. Agents cannot push to you.

## Multi-Builder Coordination Protocol
1. SPLIT: Assign independent tasks with explicit file boundaries per builder.
2. POLL: Cycle through all builders. "waiting for response..." = still working.
3. REVIEW: Send completed work to reviewer as each builder finishes (don't wait for all).
4. CONFLICT CHECK: After all builders complete, run ``git diff --name-only`` to detect overlaps.
5. MERGE: If no conflicts, commit. If conflicts, resolve manually then commit.
"@

Set-Content -Path $promptFile -Value $promptContent -Encoding UTF8
Write-Output "[orchestra] Commander prompt written to $promptFile"

# --- Codex MCP URL quarantine (workaround: v0.117.0 "url not supported for stdio") ---
$hasCodex = ($Agents | Where-Object { $_.command -match 'codex' }).Count -gt 0
$codexConfigPath = Join-Path $HOME ".codex" "config.toml"
$codexConfigBackup = $null

if ($hasCodex -and (Test-Path $codexConfigPath)) {
    $codexConfigBackup = Get-Content $codexConfigPath -Raw
    $quarantined = @()
    $currentSection = $null

    foreach ($line in (Get-Content $codexConfigPath)) {
        if ($line -match '^\[mcp_servers\.([^\]]+)\]') {
            $currentSection = $Matches[1]
        }
        elseif ($currentSection -and $line -match '^\s*url\s*=\s*"http://') {
            $quarantined += $currentSection
            $currentSection = $null
        }
        elseif ($line -match '^\[' -and $line -notmatch '\.env_http_headers') {
            $currentSection = $null
        }
    }

    if ($quarantined.Count -gt 0) {
        foreach ($s in $quarantined) {
            codex mcp remove $s 2>$null | Out-Null
            Write-Output "[codex-mcp] Quarantined '$s' (http:// URL not supported for stdio)"
        }
    } else {
        $codexConfigBackup = $null
    }
}

# --- Start agents ---
for ($i = 0; $i -lt $Agents.Count; $i++) {
    $agent = $Agents[$i]
    $paneId = $paneIds[$i]
    $cmd = Get-ApprovalFreeCommand $agent.command
    psmux send-keys -t $paneId "cd $ProjectDir && $cmd" Enter
}

# --- Startup verification ---
Write-Output ""
Write-Output "Waiting for agents to start..."
Start-Sleep -Seconds 5

# --- Restore Codex MCP config ---
if ($codexConfigBackup) {
    Start-Sleep -Seconds 3
    Set-Content -Path $codexConfigPath -Value $codexConfigBackup -Encoding UTF8 -NoNewline
    Write-Output "[codex-mcp] Config restored (quarantined servers back in place)"
}

# --- Summary ---
Write-Output ""
Write-Output "Orchestra started in session '$session' (${Rows}x${Cols} grid)"
foreach ($agent in $Agents) {
    $pad = ($agent.label).PadRight(14)
    Write-Output "  ${pad} $($paneMap[$agent.label])  ($($agent.command))"
}
if ($shieldActive) {
    Write-Output "  Shield:        ACTIVE (approval-free mode with security hooks)"
} else {
    Write-Output "  Shield:        OFF (manual approval mode)"
}

# --- Gemini cleanup hint ---
$hasGemini = ($Agents | Where-Object { $_.command -match 'gemini' }).Count -gt 0

Write-Output ""
Write-Output "Navigation (pane switching from outside psmux):"
foreach ($agent in $Agents) {
    Write-Output "  pwsh $bridgePath focus $($agent.label)"
}

Write-Output ""
Write-Output "Commander:"
Write-Output "  cd $ProjectDir"
Write-Output "  claude --model claude-opus-4-6 --permission-mode bypassPermissions --append-system-prompt-file $promptFile"

if ($hasGemini) {
    Write-Output ""
    Write-Output "Cleanup (if gemini processes linger after session end):"
    Write-Output "  taskkill /F /IM node.exe /FI `"WINDOWTITLE eq gemini*`" 2>`$null"
}
