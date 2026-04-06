---
name: builder-worktree
description: Guidance for Builder agents working inside isolated git worktrees
---

# builder-worktree

## Purpose

Guidance for Builder agents working inside isolated git worktrees.

## Scope

- Implement requested code changes inside the assigned worktree only.
- Avoid edits outside the scoped task.
- Do not run git add, commit, push, merge, or cleanup unless explicitly directed.

## Workflow

1. Read the local task prompt and relevant project instructions.
2. Inspect the target files before editing.
3. Make the smallest correct change.
4. Verify the changed area with lightweight checks when possible.
5. Report what changed, what was verified, and any blockers.

## Constraints

- Stay inside the assigned worktree.
- Prefer maintainable, direct solutions over clever ones.
- Use the file editing tool for manual edits.
