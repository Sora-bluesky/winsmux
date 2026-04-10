# Handoff

> Updated: 2026-04-10T16:45:00+09:00
> Source of truth: this file

## Current state

- `v0.19.5` and `v0.19.6` are released.
- `v0.19.6 hardening` is implemented, merged, released, and tracked as `100% (6/6)` in the external planning backlog/roadmap.
- PR [#370](https://github.com/Sora-bluesky/winsmux/pull/370) and PR [#371](https://github.com/Sora-bluesky/winsmux/pull/371) are merged into `main`.
- Planning source of truth is externalized outside the public repository and syncs automatically into the private planning root.
- `v0.19.7 visible orchestration` has `TASK-243`, `TASK-244`, `TASK-245`, `TASK-246`, `TASK-256`, and `TASK-257` merged into `main`, and private planning is now `86% (6/7)`.
- `v0.24.0: Rust runtime convergence` exists in external planning as the pre-`v1.0.0` Rust unification milestone.
- `v0.21.x` private planning is now aligned to a conversation-first Tauri operator shell, with Codex-App-like shell rules reflected in Figma and backlog notes.

## This session

- Merged the repo-side `TASK-244` session board surface via PR [#371](https://github.com/Sora-bluesky/winsmux/pull/371).
- Released `v0.19.6` from tag `eac8615` and updated the public GitHub Release body to `/release-notes` format.
- Merged `TASK-245` via PR [#372](https://github.com/Sora-bluesky/winsmux/pull/372), adding `winsmux inbox` as the first actionable approval/review/blocker surface.
- Merged the repo-side `TASK-256` primitives via PR [#374](https://github.com/Sora-bluesky/winsmux/pull/374): `winsmux runs [--json]` and `winsmux explain <run_id> [--json] [--follow]`.
- Merged `TASK-257` via PR [#375](https://github.com/Sora-bluesky/winsmux/pull/375), tightening notification profiles so Telegram defaults to external-facing events only.
- Merged `TASK-246` via PR [#376](https://github.com/Sora-bluesky/winsmux/pull/376), adding `winsmux digest [--json]` and evidence digest fields for `explain`.
- Updated external planning so `v0.19.8` remains visible, `v0.20.1` contains `TASK-272/273/274`, and `v0.24.0` keeps the Rust runtime convergence plan.
- Added the next stream-first UX slice locally: `winsmux digest --stream` now tails event deltas and emits high-signal digest updates only for materially affected runs.
- Reworked the Tauri prototype toward `TASK-285`: `winsmux-app` now renders an operator workspace shell scaffold with left nav, conversation timeline, sticky composer with inline attachments, context panel toggle, and a terminal utility drawer instead of a PTY-first full-window layout.
- Added Figma high-fi anchors for `Operator Home / Inbox`, `Run Explain / Evidence`, and `Editor Secondary Surface`, and clarified how Explorer/Editor/Pane map into the new shell.

## Validation

- Release workflow passed: `Release Core Binary` for `v0.19.6`
- `TASK-244` PR CI passed before merge
- `TASK-245` PR CI passed before merge
- `TASK-256` focused regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `93/93 PASS`
- `TASK-257` focused regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `98/98 PASS`
- `TASK-246` focused regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `101/101 PASS`
- PR [#376](https://github.com/Sora-bluesky/winsmux/pull/376) CI passed before merge
- Current local stream UX regression passes: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `103/103 PASS`
- Current Tauri shell scaffold passes frontend build: `npm run build` in `winsmux-app`
- Composer scaffold now matches the advertised keyboard contract (`Enter` sends, `Shift+Enter` inserts newline, IME composition Enter does not send), and Context/Terminal toggles expose disclosure semantics via `aria-controls` + `aria-expanded`

## Next actions

1. Land the repo-side `TASK-285` starter (`winsmux-app` conversation shell scaffold) via branch/PR if the current build-only validation is acceptable.
2. Decide whether `v0.19.7` should close with `TASK-253` deferred or whether to implement the minimal first-class `run_id` slice next.
3. Continue `v0.21.0` with `TASK-292/293/294`, then align `TASK-107` implementation to the now-explicit secondary editor surface.
4. Preserve the private planning sync flow: user/agent visible, auto-synced, but not committed to the public repo.
5. Track GitHub Actions Node runtime warnings and update workflows before the Node 24 switch becomes mandatory.

## Notes

- `HANDOFF.md` at the repository root is historical context and no longer authoritative.
- Public tracked files must not contain personal paths or private planning roots.
- External planning source of truth stays outside the public repository and is resolved via the configured planning root.
- Public docs may refer to the external planning contract, but must not embed machine-specific absolute paths.
- Public GitHub Release titles and bodies are standardized in English, even when the working session is conducted in Japanese.
