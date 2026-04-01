#!/usr/bin/env bash
# orchestra-dispatch.sh — Launch Codex in a psmux pane via prompt file
# Usage: bash orchestra-dispatch.sh <pane-id> <prompt-file> [model]
set -euo pipefail

PANE_ID="${1:?Usage: orchestra-dispatch.sh <pane-id> <prompt-file> [model]}"
PROMPT_FILE="${2:?Usage: orchestra-dispatch.sh <pane-id> <prompt-file> [model]}"
MODEL="${3:-gpt-5.4}"

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

# Detect project root (parent of .orchestra-prompts or current dir)
PROJECT_DIR="$(to_win_path "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"

psmux send-keys -t "$PANE_ID" "cd $PROJECT_DIR; pwsh -File $LAUNCHER $ABS_PROMPT $MODEL" Enter

echo "$PANE_ID <- $PROMPT_FILE (model: $MODEL)"
