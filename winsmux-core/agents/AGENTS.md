# winsmux-core Agent Templates

This directory contains bash wrappers that generate fixed user prompts for winsmux orchestration roles.

## Files

- `builder.sh`
  - Purpose: emit a Builder prompt for implementation work in a dedicated worktree.
  - Guardrails: requires `WORKTREE`, tells the agent to `cd` into it, mirrors the current `New-BuilderQueueDispatchPrompt` format from `winsmux-core/scripts/builder-queue.ps1`, requires tests or checks before finishing, and requires Conventional Commits if a commit is created.
  - Completion markers: `STATUS: EXEC_DONE` or `STATUS: BLOCKED`

- `reviewer.sh`
  - Purpose: emit a Reviewer prompt for diff-based review without editing code.
  - Guardrails: requires `WORKTREE`, tells the agent to `cd` into it, review `git diff`, explicitly check for security issues, and always audit downstream design impact / replacement coverage / orphaned artifacts.
  - Completion markers: `REVIEW_PASS` or `REVIEW_FAIL`
  - Optional env var: `DIFF_BASE` to override the diff target. Defaults to `HEAD`.
  - Optional env var: `DIFF_PATHSPEC` to narrow the diff target. When a dispatcher uses it, the pathspec must include files that define functions called by the scoped files.
  - Safety contract for `DIFF_BASE`: it must be a trusted, single-line Git diff target such as `HEAD`, `HEAD~1`, or `origin/main...HEAD`. Do not pass shell fragments, command substitutions, or newline-delimited content. The script renders `DIFF_BASE` as shell-escaped display text only.
  - Safety contract for `DIFF_PATHSPEC`: it must be trusted, single-line pathspec text. Do not pass shell fragments, command substitutions, or newline-delimited content. Prefer a generated review manifest when multiple paths are needed.

- `researcher.sh`
  - Purpose: emit a Researcher prompt for codebase or task investigation.
  - Guardrails: requires `WORKTREE`, tells the agent to `cd` into it, asks for structured findings, separates confirmed facts from assumptions, and pushes toward actionable output for builders or reviewers.
  - Completion markers: `STATUS: RESEARCH_DONE` or `STATUS: BLOCKED`

## Usage

Builder:

```bash
WORKTREE=/path/to/worktree ./builder.sh "Implement TASK-140"
```

Reviewer:

```bash
WORKTREE=/path/to/worktree DIFF_BASE=HEAD ./reviewer.sh "Review TASK-140"
```

Reviewer with narrowed diff:

```bash
WORKTREE=/path/to/worktree DIFF_BASE=origin/main...HEAD DIFF_PATHSPEC='scripts/foo.ps1 winsmux-core/scripts/settings.ps1' ./reviewer.sh "Review TASK-140"
```

Researcher:

```bash
WORKTREE=/path/to/worktree ./researcher.sh "Investigate TASK-140 prompt format"
```

All three scripts also accept input from stdin:

```bash
printf '%s\n' "Implement TASK-140" | WORKTREE=/path/to/worktree ./builder.sh
```

## Notes

- `WORKTREE` is required for all three roles. Dispatchers must provide a trusted, single-line workspace path.
- This stdin support belongs to the shell wrappers in this directory. It is separate from the repository-level `.winsmux.yaml` `prompt_transport` setting, whose stable pane-dispatch contract currently supports only `argv` and `file`.
- These scripts generate prompts only. They do not dispatch panes on their own.
- `builder.sh` attempts to source `winsmux-core/scripts/builder-queue.ps1` through `pwsh` to stay aligned with the current Builder queue prompt. If that is not available, it falls back to an embedded prompt with the same structure.
