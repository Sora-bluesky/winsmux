---
paths: ["winsmux-core/scripts/**", ".claude/**"]
---

# Commander Dispatch Procedure

## Orchestra restore preflight
1. If restoration state is `needs-startup`, do not triage PRs, plan merges, read backlog, or dispatch work yet.
2. First run `pwsh -NoProfile -File scripts/winsmux-core.ps1 harness-check --json`.
3. If `harness-check` fails, stop and repair the harness contract before startup.
4. Then run `pwsh -NoProfile -File winsmux-core/scripts/orchestra-start.ps1`.
5. Then run `pwsh -NoProfile -File scripts/winsmux-core.ps1 orchestra-smoke --json`.
6. Verify `operator_contract.operator_state`, `operator_contract.can_dispatch`, and `operator_contract.requires_startup` from the smoke JSON before any PR triage, merge action, backlog reading, or task dispatch.
7. Allowed structured startup states are:
   - `ready`
   - `ready-with-ui-warning`
   Any other state is fail-closed.
8. `ready-with-ui-warning` is not dispatch-ready. It means the session is healthy, but attached-client confirmation is still missing.
9. If the state is `ready-with-ui-warning`, run `pwsh -NoProfile -File scripts/winsmux-core.ps1 orchestra-attach --json` once, rerun `orchestra-smoke --json`, and continue only after `operator_contract.can_dispatch=true`.
10. External operator mode is fail-closed: visible attach unconfirmed means no dispatch.
11. Treat `called MCP`, plugin initialization chatter, and channel notifications as side output only. They must not be used as readiness evidence and must not override `operator_contract`.
12. If hook validation noise, schema warnings, or an `Interrupted` result prevents a clean `orchestra-smoke --json` result from being obtained, treat startup as `blocked` and rerun the startup contract instead of continuing.
13. Never ask the user which task to begin when the live handoff already lists ordered next actions.
14. Once `operator_contract.can_dispatch=true`, do not use Explore subagents for PR/task analysis. Use `pwsh -NoProfile -File scripts/winsmux-core.ps1 dispatch-task "<task text>"` or `dispatch-review`.
15. Explore subagents are reserved for orchestra startup/status diagnosis only.
16. Never use `psmux --version`, `Get-Process psmux-server`, or similar legacy probe commands for operator-side startup diagnosis.
17. If pane expansion or attach confirmation does not succeed, treat the session as `blocked` and report the smoke/startup failure.
18. Do not plan merge work while the orchestra session is still not dispatchable.

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
