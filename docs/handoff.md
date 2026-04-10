# Handoff

> Updated: 2026-04-10T12:21:30+09:00
> Source of truth: this file

## Current state

- `v0.19.5` and `v0.19.6` are released.
- `v0.19.6 hardening` is implemented, merged, released, and tracked as `100% (6/6)` in the external planning backlog/roadmap.
- PR [#370](https://github.com/Sora-bluesky/winsmux/pull/370) and PR [#371](https://github.com/Sora-bluesky/winsmux/pull/371) are merged into `main`.
- Planning source of truth is externalized outside the public repository and syncs automatically into the private planning root.
- `v0.19.7 visible orchestration` has `TASK-243`, `TASK-244`, `TASK-245`, `TASK-246`, `TASK-256`, and `TASK-257` merged into `main`, and private planning is now `86% (6/7)`.
- `v0.24.0: Rust runtime convergence` exists in external planning as the pre-`v1.0.0` Rust unification milestone.

## This session

- Merged the repo-side `TASK-244` session board surface via PR [#371](https://github.com/Sora-bluesky/winsmux/pull/371).
- Released `v0.19.6` from tag `eac8615` and updated the public GitHub Release body to `/release-notes` format.
- Merged `TASK-245` via PR [#372](https://github.com/Sora-bluesky/winsmux/pull/372), adding `winsmux inbox` as the first actionable approval/review/blocker surface.
- Merged the repo-side `TASK-256` primitives via PR [#374](https://github.com/Sora-bluesky/winsmux/pull/374): `winsmux runs [--json]` and `winsmux explain <run_id> [--json] [--follow]`.
- Merged `TASK-257` via PR [#375](https://github.com/Sora-bluesky/winsmux/pull/375), tightening notification profiles so Telegram defaults to external-facing events only.
- Merged `TASK-246` via PR [#376](https://github.com/Sora-bluesky/winsmux/pull/376), adding `winsmux digest [--json]` and evidence digest fields for `explain`.
- Updated external planning so `v0.19.8` remains visible, `v0.20.1` contains `TASK-272/273/274`, and `v0.24.0` keeps the Rust runtime convergence plan.

## Validation

- Release workflow passed: `Release Core Binary` for `v0.19.6`
- `TASK-244` PR CI passed before merge
- `TASK-245` PR CI passed before merge
- `TASK-256` focused regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `93/93 PASS`
- `TASK-257` focused regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `98/98 PASS`
- `TASK-246` focused regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `101/101 PASS`
- PR [#376](https://github.com/Sora-bluesky/winsmux/pull/376) CI passed before merge

## Next actions

1. Continue `v0.19.7` with stream-facing summary UX (`watch --stream / inbox --stream / explain --follow`) after `TASK-246`.
2. Decide whether to close `v0.19.7` with `TASK-253` deferred or implement the delegation-contract slice next.
3. Keep future backlog aligned with the `Operator / slot / provider / verification / security monitor` model.
4. Preserve the private planning sync flow: user/agent visible, auto-synced, but not committed to the public repo.
5. Track GitHub Actions Node runtime warnings and update workflows before the Node 24 switch becomes mandatory.

## Notes

- `HANDOFF.md` at the repository root is historical context and no longer authoritative.
- Public tracked files must not contain personal paths or private planning roots.
- External planning source of truth stays outside the public repository and is resolved via the configured planning root.
- Public docs may refer to the external planning contract, but must not embed machine-specific absolute paths.
- Public GitHub Release titles and bodies are standardized in English, even when the working session is conducted in Japanese.
