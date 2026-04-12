# Handoff

> Updated: 2026-04-12T20:53:00+09:00
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

- Audited `v0.21.1` against the actual repo state before release closure.
- Confirmed baseline-only shipped truth and rebaselined external planning so non-shipped work moved out of `v0.21.1`.
- Implemented the missing shipped-baseline CLI required for honest closure:
  - `winsmux compare-runs <left> <right> [--json]`
  - `winsmux promote-tactic <run_id> [--title ...] [--kind ...] [--json]`
  - `.winsmux/playbook-candidates/` file-backed candidate export
- Expanded regression coverage for compare/promote surfaces.
- Reviewer `Ptolemy` returned `FAIL` on compare winner health and promote guard conditions.
- Fixed the findings by:
  - suppressing `compare-runs` winner selection unless both sides are recommendable
  - rejecting `promote-tactic` for non-promotable runs
  - adding regression tests for both guards
- Reviewer `Halley` returned `FAIL` on the stricter closure criteria.
- Fixed the findings by:
  - requiring completed task state, review pass, verification pass, and explicit security allow/pass for recommend/promote
  - teaching the read model to recognize allow-side security events
  - adding regression coverage for missing-security promotion and strict healthy-winner selection
- Fresh reviewer `Ohm` timed out after two waits, so the final merge used the documented fallback gate.
- Merged PR #407 and released `v0.21.1` with curated notes and cleaned release assets.

## Validation

- `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `161/161 PASS`
- PowerShell parser check for `scripts/winsmux-core.ps1` and `tests/psmux-bridge.Tests.ps1` -> PASS
- `git diff --check` -> no substantive diff-check failures
- Review gate history for the active `v0.21.1` closure slice:
  - explorer audit established release-scope drift
  - fresh reviewer `Parfit` -> `no result yet` after 30s wait; closed without result
  - fresh reviewer `Ptolemy` -> `FAIL`, findings fixed locally
  - fresh reviewer `Halley` -> `FAIL`, stricter guard findings fixed locally
  - fresh reviewer `Ohm` -> `no result yet` after two 35s waits on the final diff; closed without result
  - manual diff review completed on the compare/promote slice
- PR #407 CI -> green (`Pester Tests`)
- release workflow -> success (`v0.21.1`)

## Next actions

1. Start `v0.21.2` closure work.
2. At `v0.21.2` release time, update `README.md` and `README.ja.md` to mark the terminal-based final form before `v0.22.0`.
3. Keep GitHub Releases in Codex format with inline issue/PR refs visible.

## Notes

- `v0.21.1` is a baseline release, not the full advanced workflow/runtime roadmap.
- `TASK-168`, `TASK-169`, `TASK-192`, and `TASK-307` are being moved out so the release truth matches shipped code.
- Public GitHub Releases stay English, use Codex-style headings, and keep inline issue/PR refs visible.
- `README.md` and `README.ja.md` must be updated again at `v0.21.2` release time to mark the terminal-based final form as the last pre-Tauri shape.
