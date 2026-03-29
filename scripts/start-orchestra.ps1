# start-orchestra.ps1 — 4-pane orchestra setup (run AFTER psmux is started)
# Usage: pwsh scripts/start-orchestra.ps1 [options]
#
# Prerequisite: user has already started psmux in their terminal.
# This script splits panes and launches agents into the running session.

[CmdletBinding()]
param(
    [string]$ProjectDir = (Get-Location).Path,
    [string]$Commander  = "claude --model opus --channels plugin:telegram@claude-plugins-official",
    [string]$Researcher = "claude --model sonnet",
    [string]$Builder    = "codex",
    [string]$Reviewer   = "codex",
    [switch]$ShieldHarness
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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

# --- Detect running session ---
$session = (psmux list-sessions -F '#{session_name}' 2>$null | Select-Object -First 1)
if (-not $session) {
    Write-Error "No psmux session found. Start psmux first, then run this script."
    exit 1
}
$session = $session.Trim()

# --- Create 2x2 grid ---
psmux split-window -h -t $session -c $ProjectDir
psmux split-window -v -t "${session}:0.0" -c $ProjectDir
psmux split-window -v -t "${session}:0.2" -c $ProjectDir

Start-Sleep -Milliseconds 500

# --- Get pane IDs ---
$panes = psmux list-panes -t $session -F '#{pane_id}' 2>$null
$paneIds = ($panes | Out-String).Trim() -split "`n" | ForEach-Object { $_.Trim() }

$cmdPane  = $paneIds[0]  # Top-left
$resPane  = $paneIds[1]  # Bottom-left
$bldPane  = $paneIds[2]  # Top-right
$revPane  = $paneIds[3]  # Bottom-right

# --- Commander system prompt ---
$commanderPrompt = @"
You are the COMMANDER in a 4-pane winsmux Orchestra. Load the winsmux skill immediately.

## Pane Assignments
- $cmdPane (top-left) = YOU (Commander)
- $resPane (bottom-left) = Researcher — Agent Mode
- $bldPane (top-right) = Builder — Non-Agent Mode, POLL required
- $revPane (bottom-right) = Reviewer — Non-Agent Mode, POLL required

## Rules
1. NEVER write code yourself. Delegate to Builder ($bldPane).
2. Use Researcher ($resPane) for investigation, test, lint, docs.
3. Use Reviewer ($revPane) for code review after Builder completes.
4. Follow the Commander workflow: Plan -> Build -> Poll -> Review -> Poll -> Judge -> Commit -> Next.
5. Use psmux-bridge commands for all cross-pane communication.
6. Label panes on first use: psmux-bridge name $resPane researcher && psmux-bridge name $bldPane builder && psmux-bridge name $revPane reviewer
"@

$escapedPrompt = $commanderPrompt -replace "'","''"

# --- Start agents ---
psmux send-keys -t $cmdPane "cd $ProjectDir && $Commander --append-system-prompt '$escapedPrompt'" Enter
psmux send-keys -t $resPane "cd $ProjectDir && $Researcher" Enter
psmux send-keys -t $bldPane "cd $ProjectDir && $Builder" Enter
psmux send-keys -t $revPane "cd $ProjectDir && $Reviewer" Enter

# --- Summary ---
Write-Output ""
Write-Output "Orchestra started in session '$session'"
Write-Output "  Commander:  $cmdPane  ($Commander)"
Write-Output "  Researcher: $resPane  ($Researcher)"
Write-Output "  Builder:    $bldPane  ($Builder)"
Write-Output "  Reviewer:   $revPane  ($Reviewer)"
if ($shieldActive) {
    Write-Output "  Shield:     ACTIVE (approval-free mode with 22 security hooks)"
} else {
    Write-Output "  Shield:     OFF (manual approval mode)"
}
