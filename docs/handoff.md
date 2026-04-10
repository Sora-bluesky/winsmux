# Handoff

> Updated: 2026-04-10T22:10:00+09:00
> Source of truth: this file

## Current state

- `v0.19.5`, `v0.19.6`, and `v0.19.7` are released.
- `v0.19.6 hardening` is implemented, merged, released, and tracked as `100% (6/6)` in the external planning backlog/roadmap.
- `v0.19.7 visible orchestration` is implemented, merged, released, and tracked as `100% (7/7)` in the external planning backlog/roadmap.
- PR [#370](https://github.com/Sora-bluesky/winsmux/pull/370), PR [#371](https://github.com/Sora-bluesky/winsmux/pull/371), PR [#372](https://github.com/Sora-bluesky/winsmux/pull/372), PR [#374](https://github.com/Sora-bluesky/winsmux/pull/374), PR [#375](https://github.com/Sora-bluesky/winsmux/pull/375), PR [#376](https://github.com/Sora-bluesky/winsmux/pull/376), and PR [#380](https://github.com/Sora-bluesky/winsmux/pull/380) are merged into `main`.
- Planning source of truth is externalized outside the public repository and syncs automatically into the private planning root.
- `v0.21.x` private planning is aligned to a conversation-first Tauri operator shell, with Codex-App-like shell rules reflected in Figma and backlog notes.
- `v0.24.x` private planning is split into schema, ledger, machine contract, cutover, and canary phases for Rust runtime convergence before `v1.0.0`.

## This session

- Merged the repo-side `TASK-244` session board surface via PR [#371](https://github.com/Sora-bluesky/winsmux/pull/371).
- Released `v0.19.6` from tag `eac8615` and updated the public GitHub Release body to `/release-notes` format.
- Merged `TASK-245` via PR [#372](https://github.com/Sora-bluesky/winsmux/pull/372), adding `winsmux inbox` as the first actionable approval/review/blocker surface.
- Merged the repo-side `TASK-256` primitives via PR [#374](https://github.com/Sora-bluesky/winsmux/pull/374): `winsmux runs [--json]` and `winsmux explain <run_id> [--json] [--follow]`.
- Merged `TASK-257` via PR [#375](https://github.com/Sora-bluesky/winsmux/pull/375), tightening notification profiles so Telegram defaults to external-facing events only.
- Merged `TASK-246` via PR [#376](https://github.com/Sora-bluesky/winsmux/pull/376), adding `winsmux digest [--json]` and evidence digest fields for `explain`.
- Merged `TASK-253` via PR [#380](https://github.com/Sora-bluesky/winsmux/pull/380), extending manifest/status/board aggregation into first-class `run_packet` and `result_packet` surfaces for `winsmux runs --json` and `winsmux explain --json`.
- Released `v0.19.7` from tag `833249a` and updated the public GitHub Release body to the standardized English `/release-notes` format.
- Updated the private planning backlog/roadmap so `v0.19.8`, `v0.20.x`, `v0.21.x`, `v0.22.x`, and `v0.24.x` follow the `Operator / slot / provider / verification / security monitor / Tauri shell` model.
- Reworked the Tauri prototype toward `TASK-285`: `winsmux-app` now renders an operator workspace shell scaffold with conversation timeline, sticky composer with inline attachments, context toggle, and a terminal utility drawer instead of a PTY-first full-window layout.
- Added Figma high-fi anchors for `Operator Home / Inbox`, `Run Explain / Evidence`, and `Editor Secondary Surface`, and clarified how Explorer/Editor/Pane map into the new shell.

## Validation

- Release workflow passed for `v0.19.6`.
- Release workflow passed for `v0.19.7`.
- `TASK-244` PR CI passed before merge.
- `TASK-245` PR CI passed before merge.
- `TASK-246` focused regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `101/101 PASS`.
- `TASK-253` focused regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `103/103 PASS`.
- Current Tauri shell scaffold passes frontend build: `npm run build` in `winsmux-app`.
- Composer scaffold matches the intended keyboard contract (`Enter` sends, `Shift+Enter` inserts newline, IME composition Enter does not send), and Context/Terminal toggles expose disclosure semantics via `aria-controls` plus `aria-expanded`.

## Next actions

1. Land the repo-side `TASK-285` starter via PR [#379](https://github.com/Sora-bluesky/winsmux/pull/379) after rebasing it onto the now-released `v0.19.7` state.
2. Start `v0.19.8` in order once the current Tauri starter branch is settled.
3. Continue `v0.21.0` with `TASK-292/293/294`, then align `TASK-107` implementation to the explicit secondary editor surface and workspace sidebar model.
4. Preserve the private planning sync flow: user/agent visible, auto-synced, but not committed to the public repo.
5. Track GitHub Actions Node runtime warnings and update workflows before the Node 24 switch becomes mandatory.

## Notes

- `HANDOFF.md` at the repository root is historical context and no longer authoritative.
- Public tracked files must not contain personal paths or private planning roots.
- External planning source of truth stays outside the public repository and is resolved via the configured planning root.
- Public docs may refer to the external planning contract, but must not embed machine-specific absolute paths.
- Public GitHub Release titles and bodies are standardized in English, even when the working session is conducted in Japanese.
