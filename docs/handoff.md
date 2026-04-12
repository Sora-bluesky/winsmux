# Handoff

> Updated: 2026-04-12T19:20:00+09:00
> Source of truth: this file

## Current state

- `v0.20.0`, `v0.20.1`, `v0.20.2`, `v0.20.3`, and `v0.21.0` are released.
- `v0.21.1` closure is in progress on `codex/v0211-compare-promote-close-20260412`.
- Current `v0.21.1` shipped-baseline scope is being rebaselined to:
  - `TASK-163` phase-gated workflow baseline
  - `TASK-164` structured chaining baseline
  - `TASK-167` provider/model slot metadata baseline
  - `TASK-254` provider capability metadata baseline
  - `TASK-303` compare-runs baseline
  - `TASK-304` promote-tactic baseline
- Non-shipped `v0.21.1` work is being moved out of the release:
  - `TASK-168`
  - `TASK-169`
  - `TASK-192`
  - `TASK-307`

## This session

- Audited `v0.21.1` against the actual repo state before release closure.
- Confirmed baseline-only shipped truth:
  - `TASK-163`, `TASK-164`, `TASK-167`, `TASK-254`, `TASK-288` were only partially implemented
  - `TASK-168`, `TASK-169`, `TASK-192`, `TASK-307` were not implemented
- Implemented the missing shipped-baseline CLI for honest closure:
  - `winsmux compare-runs <left> <right> [--json]`
  - `winsmux promote-tactic <run_id> [--title ...] [--kind ...] [--json]`
  - `.winsmux/playbook-candidates/` file-backed candidate export
- Expanded regression coverage for compare/promote surfaces.
- Rebased external planning so `v0.21.1` closes on shipped baseline and moved non-shipped items out.
- Fresh reviewer timed out after the required wait and was closed. A second fresh reviewer will be run on the PR before merge.

## Validation

- `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `158/158 PASS`
- `git diff --check` -> no substantive diff-check failures
- Review gate history for the active `v0.21.1` closure slice:
  - explorer audit established release-scope drift
  - fresh reviewer `Parfit` -> `no result yet` after 30s wait; closed without result
  - manual diff review completed on the compare/promote slice

## Next actions

1. Open PR for the `v0.21.1` compare/promote closure slice and run a fresh `/review`.
2. Merge the closure slice if CI is green and the review gate passes or times out into documented fallback.
3. Publish `v0.21.1` with curated release notes after the roadmap truth is synchronized.

## Notes

- `v0.21.1` will also be a baseline release, not the full advanced workflow/runtime roadmap.
- `TASK-168`, `TASK-169`, `TASK-192`, and `TASK-307` are being moved out so the release truth matches shipped code.
- Public GitHub Releases stay English, use Codex-style headings, and keep inline issue/PR refs visible.
- `README.md` and `README.ja.md` must be updated again at `v0.21.2` release time to mark the terminal-based final form as the last pre-Tauri shape.
