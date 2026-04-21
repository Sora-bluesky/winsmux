# start-orchestra.ps1 — Flexible N-pane orchestra setup (run AFTER winsmux is started)
# Usage:
#   # Default 2x2 (backward compatible):
#   pwsh scripts/start-orchestra.ps1
#
#   # Custom 3x2 with mixed agents:
#   pwsh scripts/start-orchestra.ps1 -Rows 2 -Cols 3 -Agents @(
#     @{label="builder-1"; command="codex --sandbox danger-full-access"},
#     @{label="builder-2"; command="codex --sandbox danger-full-access"},
#     @{label="builder-3"; command="gemini --model gemini-3.1-pro-preview --yolo"},
#     @{label="researcher"; command="claude --model sonnet"},
#     @{label="builder-4"; command="gemini --model gemini-3-flash-preview --yolo"},
#     @{label="reviewer"; command="codex --sandbox danger-full-access"}
#   ) -ShieldHarness
#
# Prerequisite: user has already started winsmux in their terminal.
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
$paneEnvScript = Join-Path $PSScriptRoot '..\winsmux-core\scripts\pane-env.ps1'
if (Test-Path $paneEnvScript -PathType Leaf) {
    . $paneEnvScript
}

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

$currentBranch = $null
try {
    $currentBranch = (git -C $ProjectDir rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
    if ($currentBranch) {
        $currentBranch = $currentBranch.Trim()
    }
} catch {
    $currentBranch = $null
}

if ($currentBranch -eq 'main') {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $orchestraBranch = "orchestra/$timestamp"
    Write-Output "[orchestra] Current branch is main. Creating and switching to $orchestraBranch"
    git -C $ProjectDir checkout -b $orchestraBranch | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create orchestra branch from main."
        exit 1
    }
    $currentBranch = $orchestraBranch
} elseif (-not $currentBranch) {
    $currentBranch = '(unknown)'
}

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
$hookProfile = 'standard'
if (Get-Command Resolve-WinsmuxHookProfile -ErrorAction SilentlyContinue) {
    $hookProfile = Resolve-WinsmuxHookProfile -ProjectDir $ProjectDir
}
if ($ShieldHarness) {
    $markerFile = Join-Path $ProjectDir ".claude\hooks\sh-gate.js"
    if (Test-Path $markerFile) {
        Write-Output "[shield-harness] Detected in $ProjectDir (profile: $hookProfile)"
        $shieldActive = $true
    } else {
        Write-Output "[shield-harness] Initializing in $ProjectDir (profile: $hookProfile) ..."
        Push-Location $ProjectDir
        try {
            npx shield-harness init --profile $hookProfile
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

$governanceMode = 'standard'
if (Get-Command Resolve-WinsmuxGovernanceMode -ErrorAction SilentlyContinue) {
    $governanceMode = Resolve-WinsmuxGovernanceMode -ProjectDir $ProjectDir
}

# --- Approval-free mode flags (only with ShieldHarness) ---
function Get-ApprovalFreeCommand {
    param([string]$Cmd)
    if (-not $shieldActive) { return $Cmd }

    if ($Cmd -match '^claude\b' -and $Cmd -notmatch '--permission-mode') {
        return "$Cmd --permission-mode bypassPermissions"
    }
    if ($Cmd -match '^codex\b' -and $Cmd -notmatch '--sandbox') {
        return "$Cmd --sandbox danger-full-access"
    }
    if ($Cmd -match '^gemini\b' -and $Cmd -notmatch '--yolo') {
        return "$Cmd --yolo"
    }
    return $Cmd
}

# --- Detect running session ---
$session = (winsmux list-sessions -F '#{session_name}' 2>$null | Select-Object -First 1)
if (-not $session) {
    Write-Error "No winsmux session found. Start winsmux first, then run this script."
    exit 1
}
$session = $session.Trim()

function Get-ColumnMajorPaneIds {
    param([string]$TargetSession)

    return @(winsmux list-panes -t $TargetSession -F '#{pane_id},#{pane_left},#{pane_top}' 2>$null |
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

$existingPaneIds = @(winsmux list-panes -t $session -F '#{pane_id}' 2>$null |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ })
if ($existingPaneIds.Count -gt 1) {
    Write-Output "[orchestra] Cleaning up $($existingPaneIds.Count - 1) existing pane(s)..."
    foreach ($paneId in ($existingPaneIds | Select-Object -Skip 1)) {
        winsmux kill-pane -t $paneId 2>$null
    }
    Start-Sleep -Milliseconds 300
}

# --- Create dynamic grid ---
# Step 1: Horizontal splits to create columns
for ($c = 0; $c -lt $Cols - 1; $c++) {
    winsmux split-window -h -t $session -c $ProjectDir
}

# Step 2: Even out column widths
winsmux select-layout -t $session even-horizontal

Start-Sleep -Milliseconds 300

# Step 3: Vertical splits within each column
$colPanes = winsmux list-panes -t $session -F '#{pane_id}' 2>$null
$colPaneIds = ($colPanes | Out-String).Trim() -split "`n" | ForEach-Object { $_.Trim() }

foreach ($colPane in $colPaneIds) {
    for ($r = 0; $r -lt $Rows - 1; $r++) {
        winsmux split-window -v -t $colPane -c $ProjectDir
    }
}

Start-Sleep -Milliseconds 500

# --- Get final pane IDs (sorted by visual position: column-major) ---
$paneIds = Get-ColumnMajorPaneIds -TargetSession $session

if ($paneIds.Count -ne $expectedPanes) {
    Write-Warning "Expected $expectedPanes panes but got $($paneIds.Count). Layout may be incorrect."
}

# --- Assign labels ---
$bridgePath = Join-Path $PSScriptRoot "winsmux-core.ps1"
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
You are the COMMANDER in a winsmux Orchestra. You run directly in the user's terminal. $($Agents.Count) background agents run in winsmux panes.

## Background Agents

| Label | Pane | Command |
|-------|------|---------|
$($agentRows -join "`n")

## Communication (winsmux)

``````powershell
# Send task to an agent
pwsh $bridgePath send <label> "<instruction>"

# Read agent output (polling)
pwsh $bridgePath read <label>
``````

## Rules
1. You are on branch $currentBranch. All commits go here. Create PR to merge to main.
2. NEVER write code yourself. Delegate to builders ($builderLabels).
3. Use researchers ($researcherLabels) for investigation, testing, docs.
4. Use reviewers ($reviewerLabels) for code review after builders complete.
5. Assign each builder INDEPENDENT file sets to avoid conflicts.
6. Poll all agents with ``read`` to check progress. Agents cannot push to you.

## Git Operations
Builders NEVER run git commands. Commander handles all staging, committing, and pushing sequentially.

## Builder Agents
All builder tasks must target files within the project directory. Do not instruct builders to clone, cd, or operate outside the project root.

## Multi-Builder Coordination Protocol
1. SPLIT: Assign independent tasks with explicit file boundaries per builder.
2. POLL: Cycle through all builders. "waiting for response..." = still working.
3. REVIEW: Send completed work to reviewer as each builder finishes (don't wait for all).
4. CONFLICT CHECK: After all builders complete, run ``git diff --name-only`` to detect overlaps.
5. MERGE: If no conflicts, commit. If conflicts, resolve manually then commit.

## POLL Guard (anti-hang protocol)
1. Before sending any task via winsmux send, ALWAYS run ``winsmux read <label>`` first and verify that the pane is idle for its configured agent.
2. If ``wait-ready`` command is available, use it: ``winsmux wait-ready <label> 60``.
3. If an agent appears hung (no output change after 30 seconds), run ``respawn-pane -k`` and restart the configured agent command for that label.
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
    $envPrefix = @(
        ('$env:WINSMUX_ORCHESTRA_SESSION = ''{0}''' -f ($session -replace "'", "''"))
        ('$env:WINSMUX_ORCHESTRA_PROJECT_DIR = ''{0}''' -f ($ProjectDir -replace "'", "''"))
        ('$env:WINSMUX_HOOK_PROFILE = ''{0}''' -f ($hookProfile -replace "'", "''"))
        ('$env:WINSMUX_GOVERNANCE_MODE = ''{0}''' -f ($governanceMode -replace "'", "''"))
    ) -join '; '
    winsmux send-keys -t $paneId "$envPrefix; cd $ProjectDir; $cmd" Enter
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
if (Get-Command Resolve-WinsmuxHookProfile -ErrorAction SilentlyContinue) {
    try {
        Write-Output "  Hook profile:  $(Resolve-WinsmuxHookProfile -ProjectDir $ProjectDir)"
    } catch {
        Write-Warning "Hook profile resolution failed: $($_.Exception.Message)"
    }
}
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
Write-Output "Navigation (pane switching from outside winsmux):"
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
