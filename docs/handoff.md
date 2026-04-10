# Handoff

> Updated: 2026-04-10T12:30:00+09:00
> Source of truth: this file

## Current state

- `v0.19.5` and `v0.19.6` are released.
- `v0.19.6 hardening` is implemented, merged, released, and tracked as `100% (6/6)` in the external planning backlog/roadmap.
- PR [#370](https://github.com/Sora-bluesky/winsmux/pull/370) and PR [#371](https://github.com/Sora-bluesky/winsmux/pull/371) are merged into `main`.
- Planning source of truth is externalized outside the public repository and syncs automatically into the private planning root.
- `v0.19.7 visible orchestration` is now `2/7` complete. `TASK-243` and `TASK-244` are done in external planning, and repo-side work has started on `TASK-245`.
- `v0.24.0: Rust runtime convergence` exists in external planning as the pre-`v1.0.0` Rust unification milestone.

## This session

- Merged the repo-side `TASK-244` session board surface via PR [#371](https://github.com/Sora-bluesky/winsmux/pull/371).
- Released `v0.19.6` from tag `eac8615` and updated the public GitHub Release body to `/release-notes` format.
- Added `winsmux inbox` as the first `TASK-245` surface: snapshot/json/stream for actionable approvals, review requests, failures, and blockers.
- Updated external planning so `v0.19.8` remains visible, `v0.20.1` contains `TASK-272/273/274`, and `v0.24.0` keeps the Rust runtime convergence plan.

## Validation

- Release workflow passed: `Release Core Binary` for `v0.19.6`
- `TASK-244` PR CI passed before merge
- Current `TASK-245` focused regression passed: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `88/88 PASS`
- Current uncommitted `TASK-245` touches:
  - `scripts/winsmux-core.ps1`
  - `winsmux-core/scripts/role-gate.ps1`
  - `tests/psmux-bridge.Tests.ps1`

## Next actions

1. Commit and PR the repo-side `TASK-245` inbox surface.
2. Continue `v0.19.7` with `TASK-256` explain/run-ledger follow-up after inbox lands.
3. Keep future backlog aligned with the `Operator / slot / provider / verification / security monitor` model.
4. Preserve the private planning sync flow: user/agent visible, auto-synced, but not committed to the public repo.

## Notes

- `HANDOFF.md` at the repository root is historical context and no longer authoritative.
- Public tracked files must not contain personal paths or private planning roots.
- External planning source of truth stays outside the public repository and is resolved via the configured planning root.
- Public docs may refer to the external planning contract, but must not embed machine-specific absolute paths.
- Public GitHub Release titles and bodies are standardized in English, even when the working session is conducted in Japanese.
