#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  WORKTREE=/path/to/worktree ./builder.sh "Implement TASK-140"
  printf '%s\n' "Implement TASK-140" | WORKTREE=/path/to/worktree ./builder.sh

Outputs a Builder agent prompt with fixed guardrails embedded.
EOF
}

read_task() {
  if (($# > 0)); then
    printf '%s' "$*"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    cat
    return 0
  fi

  return 1
}

pick_pwsh() {
  if command -v pwsh >/dev/null 2>&1; then
    printf '%s' "pwsh"
    return 0
  fi

  if command -v pwsh.exe >/dev/null 2>&1; then
    printf '%s' "pwsh.exe"
    return 0
  fi

  return 1
}

to_native_path() {
  local path="$1"

  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$path"
    return 0
  fi

  printf '%s' "$path"
}

default_builder_prompt() {
  local task="$1"

  cat <<EOF
Implement the next queued Builder task in your assigned workspace.

Task:
$task

Before finishing:
- run the relevant checks or tests
- summarize changed files
- summarize the verification you performed

End with exactly one line:
STATUS: EXEC_DONE

If blocked, end with:
STATUS: BLOCKED
EOF
}

base_builder_prompt() {
  local task="$1"
  local script_dir repo_root builder_queue_ps1 builder_queue_ps1_native pwsh_bin

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  repo_root="$(cd -- "$script_dir/../.." && pwd -P)"
  builder_queue_ps1="$repo_root/psmux-bridge/scripts/builder-queue.ps1"

  if [[ ! -f "$builder_queue_ps1" ]]; then
    default_builder_prompt "$task"
    return 0
  fi

  if ! pwsh_bin="$(pick_pwsh)"; then
    default_builder_prompt "$task"
    return 0
  fi

  builder_queue_ps1_native="$(to_native_path "$builder_queue_ps1")"

  if ! BRIDGE_BUILDER_QUEUE_PS1="$builder_queue_ps1_native" TASK_PAYLOAD="$task" "$pwsh_bin" -NoProfile -Command '
    $script = $env:BRIDGE_BUILDER_QUEUE_PS1
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        exit 11
    }

    . $script
    [Console]::Out.Write((New-BuilderQueueDispatchPrompt -Task $env:TASK_PAYLOAD))
  ' 2>/dev/null; then
    default_builder_prompt "$task"
  fi
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

task="$(read_task "$@")" || {
  usage >&2
  exit 1
}

if [[ -z "${WORKTREE:-}" ]]; then
  echo "builder.sh requires WORKTREE to be set." >&2
  exit 1
fi

base_prompt="$(base_builder_prompt "$task")"

cat <<EOF
$base_prompt

Additional fixed guardrails for this builder run:
- Start by running: cd "$WORKTREE"
- Treat WORKTREE as the only workspace you may modify for this task.
- Do not finish until you have run the relevant tests or checks from that workspace, unless you are blocked.
- In the verification summary, include the exact commands you ran and whether they passed or failed.
- If you create a commit, use a Conventional Commits message.
- Do NOT run git add, git commit, git push, or any git write commands. Your role is code editing only. Git operations are handled by the Researcher or Commander.

Respond with:
- implementation summary
- changed files
- verification summary

The final line must be exactly one of:
STATUS: EXEC_DONE
STATUS: BLOCKED
EOF
