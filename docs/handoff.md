# Handoff

> Updated: 2026-04-10T17:33:35+09:00
> Source of truth: this file

## Current state

- `v0.19.5`, `v0.19.6`, and `v0.19.7` are released.
- `v0.19.6 hardening` is implemented, merged, released, and tracked as `100% (6/6)` in the external planning backlog/roadmap.
- `v0.19.7 visible orchestration` is implemented, merged, released, and tracked as `100% (7/7)` in the external planning backlog/roadmap.
- `v0.19.8 External Operator & Agent Slots` is implemented in order; private planning now tracks `TASK-259`, `TASK-261`, `TASK-262`, `TASK-263`, and `TASK-264` as done, and the external roadmap is synced accordingly.
- PR [#370](https://github.com/Sora-bluesky/winsmux/pull/370), PR [#371](https://github.com/Sora-bluesky/winsmux/pull/371), PR [#372](https://github.com/Sora-bluesky/winsmux/pull/372), PR [#374](https://github.com/Sora-bluesky/winsmux/pull/374), PR [#375](https://github.com/Sora-bluesky/winsmux/pull/375), PR [#376](https://github.com/Sora-bluesky/winsmux/pull/376), PR [#379](https://github.com/Sora-bluesky/winsmux/pull/379), PR [#380](https://github.com/Sora-bluesky/winsmux/pull/380), PR [#381](https://github.com/Sora-bluesky/winsmux/pull/381), PR [#382](https://github.com/Sora-bluesky/winsmux/pull/382), PR [#383](https://github.com/Sora-bluesky/winsmux/pull/383), and PR [#384](https://github.com/Sora-bluesky/winsmux/pull/384) are merged into `main`.
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
- Merged `TASK-285` via PR [#379](https://github.com/Sora-bluesky/winsmux/pull/379), landing the first Tauri operator workspace shell scaffold on `main`.
- Updated the private planning backlog/roadmap so `v0.19.8`, `v0.20.x`, `v0.21.x`, `v0.22.x`, and `v0.24.x` follow the `Operator / slot / provider / verification / security monitor / Tauri shell` model.
- Updated `TASK-257` planning notes to be channel-agnostic (`external channel` instead of `Telegram` as the design anchor) and documented the Claude Code channels abstraction in `.references`.
- Started the repo-side `TASK-261` slice on `codex/task261-agent-slots-20260410`, adding `agent_slots[]` parsing, worker-count synthesis, setup-wizard emission, and the default project slot array.
- Merged the repo-side `TASK-261` slice via PR [#381](https://github.com/Sora-bluesky/winsmux/pull/381), making `agent_slots[]` the project settings source of truth, rejecting malformed slot definitions fail-closed, and binding setup-wizard / orchestra-start to the canonical project root.
- Started the repo-side `TASK-262` slice on `codex/task262-slot-provider-model-20260410`, wiring slot-level `agent/model` selection into orchestra startup, restart plans, monitor cycles, and pane scaling paths.
- Merged the repo-side `TASK-262` slice via PR [#382](https://github.com/Sora-bluesky/winsmux/pull/382), wiring slot-level `agent/model` selection through startup, restart, monitor, and scale paths.
- Merged the repo-side `TASK-263` slice via PR [#383](https://github.com/Sora-bluesky/winsmux/pull/383), changing legacy role layout handling from implicit count-based activation to explicit `legacy_role_layout=true` opt-in only.
- Merged the repo-side `TASK-264` starter slice via PR [#384](https://github.com/Sora-bluesky/winsmux/pull/384), moving review-state and pipeline wording from dedicated `reviewer` targets toward generic `review target` semantics while keeping legacy `target_reviewer_*` keys readable.
- Reworked the Tauri prototype toward `TASK-285`: `winsmux-app` now renders an operator workspace shell scaffold with conversation timeline, sticky composer with inline attachments, context toggle, and a terminal utility drawer instead of a PTY-first full-window layout.
- Added Figma high-fi anchors for `Operator Home / Inbox`, `Run Explain / Evidence`, and `Editor Secondary Surface`, and clarified how Explorer/Editor/Pane map into the new shell.
- Tightened the `TASK-285` shell slice locally: `winsmux-app` now uses a workspace sidebar instead of generic nav, adds a Codex-style footer/status lane, keeps wrapping summary-first, and separates sidebar / conversation / editor surface / context side sheet / terminal drawer more explicitly.
- Updated private planning notes so `TASK-101`, `TASK-285`, `TASK-287`, `TASK-292`, `TASK-294`, `TASK-297`, `TASK-107`, `TASK-138`, `TASK-286`, and `TASK-288` reflect the Codex-TUI-plus-cmux synthesis, then re-synced the external roadmap.
- Updated the Figma `winsmux Tauri Operator Workspace` file so the high-fi home screen shows the workspace sidebar, sticky composer, and footer/status lane together.
- Added [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and a matching `AGENTS.md` rule so direct Codex OSS UI reuse keeps Apache-2.0 attribution plus upstream source-path tracking in-repo, and documented the MIT-licensed legacy `psmux` compatibility surface from the core upstream for provenance.

## Validation

- Release workflow passed for `v0.19.6`.
- Release workflow passed for `v0.19.7`.
- `TASK-244` PR CI passed before merge.
- `TASK-245` PR CI passed before merge.
- `TASK-246` focused regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `101/101 PASS`.
- `TASK-253` focused regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `103/103 PASS`.
- Current Tauri shell scaffold passes frontend build: `npm run build` in `winsmux-app`.
- Composer scaffold matches the intended keyboard contract (`Enter` sends, `Shift+Enter` inserts newline, IME composition Enter does not send), and Context/Terminal toggles expose disclosure semantics via `aria-controls` plus `aria-expanded`.
- `TASK-261` settings/layout regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `110/110 PASS`.
- Current `TASK-262` slot wiring regression passes locally: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `113/113 PASS`.
- `TASK-263` explicit legacy opt-in regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `115/115 PASS`.
- `TASK-264` starter regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `116/116 PASS`.
- Current Tauri workspace-sidebar slice passes frontend build: `npm run build` in `winsmux-app`.

## Next actions

1. Release `v0.19.8` now that `TASK-259/261/262/263/264` are tracked as done and synced in the external roadmap.
2. Continue `v0.21.0` with `TASK-297` plus `TASK-292/293/294`, then align `TASK-107` implementation to the explicit secondary editor surface and workspace sidebar model.
3. Preserve the private planning sync flow: user/agent visible, auto-synced, but not committed to the public repo.
4. Track GitHub Actions Node runtime warnings and update workflows before the Node 24 switch becomes mandatory.
5. Run the next retro-review tranche over recent merged PRs after each milestone-close sequence.

## Notes

- `HANDOFF.md` at the repository root is historical context and no longer authoritative.
- Public tracked files must not contain personal paths or private planning roots.
- External planning source of truth stays outside the public repository and is resolved via the configured planning root.
- Public docs may refer to the external planning contract, but must not embed machine-specific absolute paths.
- Public GitHub Release titles and bodies are standardized in English, even when the working session is conducted in Japanese.
