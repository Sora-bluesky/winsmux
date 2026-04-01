#!/usr/bin/env bash
# orchestra-dispatch.sh — Launch Codex in a psmux pane via prompt file
# Usage: bash orchestra-dispatch.sh <pane-id> <prompt-file> [model]
set -euo pipefail

PANE_ID="${1:?Usage: orchestra-dispatch.sh <pane-id> <prompt-file> [model] [project-dir]}"
PROMPT_FILE="${2:?Usage: orchestra-dispatch.sh <pane-id> <prompt-file> [model] [project-dir]}"
MODEL="${3:-gpt-5.4}"
PROJECT_OVERRIDE="${4:-}"

if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "Error: Prompt file not found: $PROMPT_FILE" >&2
    exit 1
fi

# Convert MSYS paths (/c/...) to Windows paths (C:/...)
to_win_path() {
    local p
    p="$(cd "$(dirname "$1")" && pwd -W)/$(basename "$1")"
    echo "${p//\\//}"
}

LAUNCHER="$(to_win_path "$(dirname "$0")/codex-launch.ps1")"
ABS_PROMPT="$(to_win_path "$PROMPT_FILE")"

# Detect project root or use override
if [[ -n "$PROJECT_OVERRIDE" ]]; then
    PROJECT_DIR="$(to_win_path "$PROJECT_OVERRIDE")"
else
    PROJECT_DIR="$(to_win_path "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
fi

psmux send-keys -t "$PANE_ID" "cd $PROJECT_DIR; pwsh -File $LAUNCHER $ABS_PROMPT $MODEL" Enter

echo "$PANE_ID <- $PROMPT_FILE (model: $MODEL)"
