#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  WORKTREE=/path/to/worktree ./reviewer.sh "Review TASK-140"
  printf '%s\n' "Review TASK-140" | WORKTREE=/path/to/worktree ./reviewer.sh

Outputs a Reviewer agent prompt with fixed diff-review guardrails embedded.
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

require_single_line_env() {
  local name="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    printf '%s\n' "reviewer.sh requires $name to be set." >&2
    exit 1
  fi

  case "$value" in
    *$'\n'*|*$'\r'*)
      printf '%s\n' "reviewer.sh requires $name to be a single-line value." >&2
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

task="$(read_task "$@")" || {
  usage >&2
  exit 1
}

require_single_line_env "WORKTREE" "${WORKTREE:-}"
diff_base="${DIFF_BASE:-HEAD}"
require_single_line_env "DIFF_BASE" "$diff_base"

worktree_display="$(shell_quote "$WORKTREE")"
diff_base_display="$(shell_quote "$diff_base")"

cat <<'PROMPT'
Review the latest builder result without editing code.

Task:
PROMPT
printf '%s\n\n' "$task"
cat <<'PROMPT'
Workspace:
PROMPT
printf '%s\n\n' "$worktree_display"
cat <<'PROMPT'
Required review steps:
PROMPT
printf '%s\n' "- Start by running: cd $worktree_display"
printf '%s\n' "- Inspect the current diff with: git diff $diff_base_display"
cat <<'PROMPT'
- Review for correctness, regressions, missing verification, and security issues.
- Call out any credential exposure, injection risks, auth or authz mistakes, path handling issues, or unsafe shell usage.
- Explicitly evaluate design impact, not just local diff correctness:
  - What downstream behavior, workflow, or monitoring capability does this change disable or alter?
  - Was any removed or changed capability replaced elsewhere, or does it create a blind spot?
  - Are there orphaned artifacts such as dead mocks, stale helpers, or unused state transitions that indicate an incomplete change?
- Separate direct code issues from architecture or operational risks.
- Do not edit code during this review.

Respond with:
- verdict
- findings
- security review
- design impact
- replacement check
- orphaned artifacts
- recommended follow-ups

If there are no blocking findings, end with exactly:
REVIEW_PASS

If there are blocking findings, end with exactly:
REVIEW_FAIL
PROMPT
