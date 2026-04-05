#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  WORKTREE=/path/to/worktree ./researcher.sh "Investigate TASK-140 agent template conventions"
  printf '%s\n' "Investigate TASK-140 agent template conventions" | WORKTREE=/path/to/worktree ./researcher.sh

Outputs a Researcher agent prompt with fixed structured-findings guardrails embedded.
EOF
}

read_topic() {
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

require_single_line_env() {
  local name="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    printf '%s\n' "researcher.sh requires $name to be set." >&2
    exit 1
  fi

  case "$value" in
    *$'\n'*|*$'\r'*)
      printf '%s\n' "researcher.sh requires $name to be a single-line value." >&2
      exit 1
      ;;
  esac
}

shell_quote() {
  printf '%q' "$1"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

topic="$(read_topic "$@")" || {
  usage >&2
  exit 1
}

require_single_line_env "WORKTREE" "${WORKTREE:-}"
worktree_display="$(shell_quote "$WORKTREE")"

cat <<'PROMPT'
Investigate the following topic and return structured findings.

Topic:
PROMPT
printf '%s\n\n' "$topic"
cat <<'PROMPT'
Working context:
PROMPT
printf '%s\n\n' "- workspace: $worktree_display"
cat <<'PROMPT'
Instructions:
PROMPT
printf '%s\n' "- Start by running: cd $worktree_display"
cat <<'PROMPT'
- Investigate the codebase and the provided task context before making assumptions.
- Separate confirmed facts from assumptions or open questions.
- Prefer findings that a builder or reviewer can act on immediately.
- Cite relevant files, commands, or artifacts when useful.

Reply with these sections:
- summary
- key findings
- evidence
- risks or open questions
- recommended next steps

End with exactly one line:
STATUS: RESEARCH_DONE

If blocked, end with:
STATUS: BLOCKED
PROMPT
