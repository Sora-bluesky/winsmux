# start-orchestra.ps1 — 4-pane orchestra setup (run AFTER psmux is started)
# Usage: From another terminal, run:
#   pwsh scripts/start-orchestra.ps1 [project-dir]
#
# Prerequisite: user has already started psmux in their terminal.
# This script splits panes and launches agents into the running session.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$projectDir = if ($args[0]) { $args[0] } else { (Get-Location).Path }

# Detect running session
$session = (psmux list-sessions -F '#{session_name}' 2>$null | Select-Object -First 1).Trim()
if (-not $session) {
    Write-Error "No psmux session found. Start psmux first, then run this script."
    exit 1
}

# Create 2x2 grid
psmux split-window -h -t $session -c $projectDir
psmux split-window -v -t "${session}:0.0" -c $projectDir
psmux split-window -v -t "${session}:0.2" -c $projectDir

Start-Sleep -Milliseconds 500

# Get pane IDs
$panes = psmux list-panes -t $session -F '#{pane_id}' 2>$null
$paneIds = ($panes | Out-String).Trim() -split "`n" | ForEach-Object { $_.Trim() }

# Start agents
# Top-left: Commander (Opus)
psmux send-keys -t $paneIds[0] "cd $projectDir && claude --model opus --channels plugin:telegram@claude-plugins-official" Enter
# Bottom-left: Researcher (Sonnet)
psmux send-keys -t $paneIds[1] "cd $projectDir && claude --model sonnet" Enter
# Top-right: Builder (Codex)
psmux send-keys -t $paneIds[2] "cd $projectDir && codex" Enter
# Bottom-right: Reviewer (Codex)
psmux send-keys -t $paneIds[3] "cd $projectDir && codex" Enter

Write-Output "Orchestra started in session '$session' ($($paneIds.Count) panes)"
