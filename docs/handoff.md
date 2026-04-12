# Handoff

> Updated: 2026-04-12T22:15:00+09:00
> Source of truth: this file

## Current state

- `v0.20.0`, `v0.20.1`, `v0.20.2`, `v0.20.3`, `v0.21.0`, and `v0.21.1` are released.
- `v0.21.1` shipped as a workflow-baseline release for:
  - `TASK-163` phase-gated workflow baseline
  - `TASK-164` structured chaining baseline
  - `TASK-167` provider/model slot metadata baseline
  - `TASK-254` provider capability metadata baseline
  - `TASK-303` compare-runs baseline
  - `TASK-304` promote-tactic baseline
- Non-shipped `v0.21.1` work was moved out of the release:
  - `TASK-168`
  - `TASK-169`
  - `TASK-192`
  - `TASK-307`

## This session

- Started `v0.21.2: Terminal-Based Final Form & Session Ergonomics`.
- Scoped `TASK-216` to a low-risk first slice that consolidates raw terminal CLI calls in leaf hot-path scripts instead of the central bridge file.
- Implemented wrapper-based terminal calls in:
  - `winsmux-core/scripts/commander-poll.ps1`
  - `winsmux-core/scripts/pane-status.ps1`
  - `winsmux-core/scripts/pane-control.ps1`
- Added regression coverage for:
  - commander review dispatch using wrappers
  - pane status default snapshot capture through its wrapper
  - pane title reads through the pane-control wrapper
- Integrated explorer review findings from `Aristotle` and closed that subagent after use.
- Fresh reviewer `Mill` returned `no result yet` after two 35s waits and was closed.
- Merged PR #408 for the `TASK-216` leaf-wrapper first slice.

## Validation

- `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `164/164 PASS`
- PowerShell parser check for:
  - `winsmux-core/scripts/commander-poll.ps1`
  - `winsmux-core/scripts/pane-status.ps1`
  - `winsmux-core/scripts/pane-control.ps1`
  - `tests/psmux-bridge.Tests.ps1`
  -> PASS
- `git diff --check` -> warnings only, no substantive diff-check failures
- Explorer review `Aristotle` completed and recommended the leaf-script-first `TASK-216` slice
- PR #408 CI -> green (`Pester Tests`)
- Fresh reviewer `Mill` -> `no result yet` after two 35s waits; closed without result
- Manual diff review completed for the `TASK-216` leaf-wrapper slice

## Next actions

1. Continue `TASK-216` with the next densest wrapper consolidation target after the leaf-wrapper slice.
2. Decide whether the next `v0.21.2` slice is `orchestra-layout` wrapper consolidation or a different terminal-ergonomics task.
3. At `v0.21.2` release time, update `README.md` and `README.ja.md` to mark the terminal-based final form before `v0.22.0`.

## Notes

- `v0.21.1` is a baseline release, not the full advanced workflow/runtime roadmap.
- `TASK-216` is being landed as small hot-path wrapper slices rather than a single bridge-file refactor.
- Public GitHub Releases stay English, use Codex-style headings, and keep inline issue/PR refs visible.
- `README.md` and `README.ja.md` must be updated again at `v0.21.2` release time to mark the terminal-based final form as the last pre-Tauri shape.
