---
paths: ["winsmux-core/scripts/**", ".claude/**"]
---

# Commander Dispatch Procedure

## Builder Dispatch
1. Check pane state: `winsmux capture-pane -t <pane> -p | tail -5`
2. Write `.builder-prompt.txt` to Builder worktree (from manifest.yaml launch_dir)
3. Send: `winsmux send -t <pane> "Read .builder-prompt.txt and implement"` + Enter via `pwsh -NoProfile -File scripts/winsmux-core.ps1 keys <pane> Enter`
4. Monitor: `winsmux capture-pane -t <pane> -p | tail -15`
5. Verify: `git -C <worktree> diff --stat HEAD`
6. **Commander runs tests** (Builder cannot — CLM #319): `NO_COLOR=1 pwsh -Command "Invoke-Pester <worktree>/tests/ -Output Minimal"`

## Reviewer Dispatch
1. Send review request: `winsmux send -t reviewer-1 "Review diffs in .worktrees/builder-N"` + Enter
2. Wait for PASS/FAIL in capture output
3. On PASS: proceed to commit. On FAIL: re-dispatch fix to Builder

## Post-Review Commit
1. Verify `review-state.json` has PASS
2. Run: `NO_COLOR=1 pwsh -Command "Invoke-Pester tests/ -Output Minimal"`
3. Collect worktree changes, commit with conventional message

## Prohibited
- Agent subagent for implementation (#273)
- Report pane status without capture verification (#280)
- Commit without Reviewer PASS (#279)
