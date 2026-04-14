---
paths: ["winsmux-core/scripts/**", ".claude/**"]
---

# Commander Dispatch Procedure

## Orchestra restore preflight
1. If restoration state is `needs-startup`, do not triage PRs, plan merges, read backlog, or dispatch work yet.
2. First run `pwsh -NoProfile -File winsmux-core/scripts/orchestra-start.ps1`.
3. Then run `pwsh -NoProfile -File scripts/winsmux-core.ps1 orchestra-smoke --json`.
4. Verify `operator_contract.operator_state`, `operator_contract.can_dispatch`, and `operator_contract.requires_startup` from the smoke JSON before any PR triage, merge action, backlog reading, or task dispatch.
5. Allowed dispatchable states are:
   - `ready`
   - `ready-with-ui-warning`
   Any other state is fail-closed.
6. If the state is `ready-with-ui-warning`, run `pwsh -NoProfile -File scripts/winsmux-core.ps1 orchestra-attach --json` once, then continue from the first pending `Next actions` item in `.claude/local/operator-handoff.md`.
7. Never ask the user which task to begin when the live handoff already lists ordered next actions.
8. Once `operator_contract.can_dispatch=true`, do not use Explore subagents for PR/task analysis. Use `pwsh -NoProfile -File scripts/winsmux-core.ps1 dispatch-task "<task text>"` or `dispatch-review`.
9. Explore subagents are reserved for orchestra startup/status diagnosis only.
10. Never use `psmux --version`, `Get-Process psmux-server`, or similar legacy probe commands for operator-side startup diagnosis.
11. If pane expansion does not succeed, treat the session as `blocked` and report the smoke/startup failure.
12. Do not plan merge work while the orchestra session is still not dispatchable.

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

## Standard Dispatch
1. Use `pwsh -NoProfile -File scripts/winsmux-core.ps1 dispatch-task "<task text>"` as the default operator-to-pane dispatch path.
2. Use `dispatch-review` only when the next action is to request a formal review-state transition.
3. Verify the chosen pane with `winsmux capture-pane -t <pane_id> -p | tail -15` before reporting that work was dispatched.

## Post-Review Commit
1. Verify `review-state.json` has PASS
2. Run: `NO_COLOR=1 pwsh -Command "Invoke-Pester tests/ -Output Minimal"`
3. Collect worktree changes, commit with conventional message

## Prohibited
- Agent subagent for implementation (#273)
- Explore subagents for PR/task analysis once `operator_contract.can_dispatch=true`
- Report pane status without capture verification (#280)
- Commit without Reviewer PASS (#279)
