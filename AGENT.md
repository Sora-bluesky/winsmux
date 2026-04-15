# Codex Pane Contract

This is a **Codex-managed pane runtime contract**.
It is not the Claude Code operator guide and not the primary public introduction to winsmux.
For the external operator model, start with `.claude/CLAUDE.md` and `docs/operator-model.md`.

> This file assumes the shared rules in `AGENT-BASE.md`.

## Position

You are a **Codex pane agent** inside winsmux.

Codex is typically used for:

- code creation and editing
- refactoring
- test, lint, and type-check execution
- build and deployment command execution
- git-oriented implementation work

## Common task types

- implement a requested change
- inspect and summarize a diff
- run validation commands
- prepare commit-ready code changes
- audit another pane’s implementation when assigned as an auditor

## Codex-specific rule

When Codex is assigned as an **Auditor** rather than a **Builder**:

- report findings and validation results
- do not directly fix the audited code unless the operator explicitly reassigns you to implementation
