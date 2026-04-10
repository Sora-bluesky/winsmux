# Handoff

> Updated: 2026-04-10T10:05:33+09:00
> Source of truth: this file

## Current state

- `v0.19.5` is released.
- `v0.19.6 hardening` is implemented, merged, and tracked as `100% (6/6)` in the external planning backlog/roadmap.
- PR [#370](https://github.com/Sora-bluesky/winsmux/pull/370) is merged into `main`.
- Planning source of truth is externalized outside the public repository and syncs automatically into the private planning root.
- `v0.19.7 visible orchestration` is now `2/7` complete. `TASK-243` and `TASK-244` are done in external planning.
- `v0.24.0: Rust runtime convergence` exists in external planning as the pre-`v1.0.0` Rust unification milestone.

## This session

- Merged the repo-side `v0.19.6` hardening closure.
- Added a durable handoff maintenance rule to `AGENTS.md` so new sessions must refresh `docs/handoff.md` at milestone boundaries and before autonomous git progression.
- Implemented `winsmux board` as the first visible orchestration surface for `TASK-244`.
- Updated external planning so `TASK-244` is `done`, `v0.19.7` is `2/7`, and `v0.24.0` contains the Rust runtime convergence plan.

## Validation

- Full local Pester suite passed: `171/171 PASS`
- Targeted hardening suite passed earlier: `133/133 PASS`
- `TASK-244` focused regression passed: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `82/82 PASS`
- Current uncommitted board surface touches:
  - `scripts/winsmux-core.ps1`
  - `winsmux-core/scripts/role-gate.ps1`
  - `tests/psmux-bridge.Tests.ps1`

## Next actions

1. Commit and PR the repo-side `TASK-244` board surface.
2. Release `v0.19.6` and prepare the release post draft.
3. Continue `v0.19.7` with `TASK-245` or `TASK-256` after the board surface lands.
4. Keep future backlog aligned with the `Operator / slot / provider` model and the new `v0.24.0` Rust convergence plan.

## Notes

- `HANDOFF.md` at the repository root is historical context and no longer authoritative.
- Public tracked files must not contain personal paths or private planning roots.
- External planning source of truth:
  - `C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\Projects\winsmux\planning\backlog.yaml`
  - `C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\Projects\winsmux\planning\ROADMAP.md`
