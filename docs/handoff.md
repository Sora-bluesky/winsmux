# Handoff

> Updated: 2026-04-11T03:20:00+09:00
> Source of truth: this file

## Current state

- `v0.19.5`, `v0.19.6`, `v0.19.7`, and `v0.19.8` are released.
- `v0.19.6 hardening` is implemented, merged, released, and tracked as `100% (6/6)` in the external planning backlog/roadmap.
- `v0.19.7 visible orchestration` is implemented, merged, released, and tracked as `100% (7/7)` in the external planning backlog/roadmap.
- `v0.19.8 External Operator & Agent Slots` is implemented in order; private planning now tracks `TASK-259`, `TASK-261`, `TASK-262`, `TASK-263`, and `TASK-264` as done, and the external roadmap is synced accordingly.
- Private planning now swaps `v0.20.0` and `v0.21.0` to match actual implementation order: `v0.20.0` is `Desktop UX Foundation`, and `v0.21.0` is `Operator Core & Slot Dispatch`.
- PR [#370](https://github.com/Sora-bluesky/winsmux/pull/370), PR [#371](https://github.com/Sora-bluesky/winsmux/pull/371), PR [#372](https://github.com/Sora-bluesky/winsmux/pull/372), PR [#374](https://github.com/Sora-bluesky/winsmux/pull/374), PR [#375](https://github.com/Sora-bluesky/winsmux/pull/375), PR [#376](https://github.com/Sora-bluesky/winsmux/pull/376), PR [#379](https://github.com/Sora-bluesky/winsmux/pull/379), PR [#380](https://github.com/Sora-bluesky/winsmux/pull/380), PR [#381](https://github.com/Sora-bluesky/winsmux/pull/381), PR [#382](https://github.com/Sora-bluesky/winsmux/pull/382), PR [#383](https://github.com/Sora-bluesky/winsmux/pull/383), PR [#384](https://github.com/Sora-bluesky/winsmux/pull/384), PR [#385](https://github.com/Sora-bluesky/winsmux/pull/385), PR [#386](https://github.com/Sora-bluesky/winsmux/pull/386), PR [#387](https://github.com/Sora-bluesky/winsmux/pull/387), PR [#388](https://github.com/Sora-bluesky/winsmux/pull/388), PR [#389](https://github.com/Sora-bluesky/winsmux/pull/389), and PR [#390](https://github.com/Sora-bluesky/winsmux/pull/390) are merged into `main`.
- `v0.20.0` now tracks desktop UX work directly; `TASK-101` is merged, `TASK-292`, `TASK-286`, and `TASK-299` are active on the current branch, and `TASK-298` tracks public-repo vs maintainer-dogfooding cleanup.
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
- Released `v0.19.8` from tag `6ec6522a6a9b91810a84ab97e4483cb8658e2f19`; the public GitHub Release is published at [v0.19.8](https://github.com/Sora-bluesky/winsmux/releases/tag/v0.19.8) and the binary workflow run `24234569692` completed successfully.
- Saved `v0.19.8` post drafts to `C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\ChangeLogs\winsmux\v0.19.8\release-notes.md` and `C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\ChangeLogs\winsmux\v0.19.8\x-thread-draft.md`.
- Reworked the Tauri prototype toward `TASK-285`: `winsmux-app` now renders an operator workspace shell scaffold with conversation timeline, sticky composer with inline attachments, context toggle, and a terminal utility drawer instead of a PTY-first full-window layout.
- Added Figma high-fi anchors for `Operator Home / Inbox`, `Run Explain / Evidence`, and `Editor Secondary Surface`, and clarified how Explorer/Editor/Pane map into the new shell.
- Tightened the `TASK-285` shell slice locally: `winsmux-app` now uses a workspace sidebar instead of generic nav, adds a Codex-style footer/status lane, keeps wrapping summary-first, and separates sidebar / conversation / editor surface / context side sheet / terminal drawer more explicitly.
- Updated private planning notes so `TASK-101`, `TASK-285`, `TASK-287`, `TASK-292`, `TASK-294`, `TASK-297`, `TASK-107`, `TASK-138`, `TASK-286`, and `TASK-288` reflect the Codex-TUI-plus-cmux synthesis, then re-synced the external roadmap.
- Updated the Figma `winsmux Tauri Operator Workspace` file so the high-fi home screen shows the workspace sidebar, sticky composer, and footer/status lane together.
- Added [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and a matching `AGENTS.md` rule so direct Codex OSS UI reuse keeps Apache-2.0 attribution plus upstream source-path tracking in-repo, and documented the MIT-licensed legacy `psmux` compatibility surface from the core upstream for provenance.
- Merged the `TASK-285` workspace-sidebar shell slice via PR [#385](https://github.com/Sora-bluesky/winsmux/pull/385), replacing the generic left-nav with a workspace sidebar and landing in-repo third-party UI provenance tracking.
- Started the next `v0.21.0` UI slice on `codex/task297-sidebar-composer-responsive-20260410`, adding workspace-sidebar responsive behavior, composer mode chips, log semantics, and a settings/menu surface to advance `TASK-297`, `TASK-292`, `TASK-293`, and `TASK-294`.
- Merged the `TASK-297/292/293/294` starter slice via PR [#386](https://github.com/Sora-bluesky/winsmux/pull/386), adding a responsive workspace sidebar overlay, composer mode chips, settings/menu sheet, and conversation log semantics.
- Started the next `TASK-107` editor slice on `codex/task107-editor-secondary-surface-20260410`, wiring changed files and source context into the secondary editor surface.
- Merged the `TASK-107` editor slice via PR [#387](https://github.com/Sora-bluesky/winsmux/pull/387), connecting the secondary editor surface to explorer selections and source-context changed files.
- Started the workflow maintenance slice on `codex/node24-workflow-actions-20260410`, upgrading GitHub Actions core actions to Node-24-capable majors to remove runner deprecation warnings.
- Added a durable subagent review-gate rule to [AGENTS.md](../AGENTS.md): close completed review agents promptly, prefer fresh agents per PR slice, wait longer before declaring timeout, and record fallback review grounds explicitly when timeouts persist.
- Merged the workflow maintenance slice via PR [#388](https://github.com/Sora-bluesky/winsmux/pull/388), upgrading core GitHub Actions dependencies to Node-24-capable majors and landing the durable subagent review-gate workflow rule in [AGENTS.md](../AGENTS.md).
- Swapped `v0.20.0` and `v0.21.0` in the private planning backlog/roadmap so release numbering matches actual implementation order, then re-synced [ROADMAP.md](C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\Projects\winsmux\planning\ROADMAP.md).
- Started the next `v0.20.0` desktop UX slice on top of `TASK-138`, unifying source-control/worktree mock data into a single `sourceControlState` view model and wiring sidebar source summary, source-entry filters, context overview cards, and changed-file rows to the same state.
- Merged the `TASK-138` source-control context slice via PR [#389](https://github.com/Sora-bluesky/winsmux/pull/389), making the desktop UX source-control surface worktree-aware and editor-linked from a single `sourceControlState`.
- Started the `TASK-101` theme-contract slice on `codex/task101-theme-contract-20260411`, adding semantic theme tokens, Codex-derived typography tokens, and `Theme / Density / Wrap` state to the settings sheet.
- Merged the `TASK-101` theme-contract slice via PR [#390](https://github.com/Sora-bluesky/winsmux/pull/390), adding semantic theme tokens, theme/density/wrap controls, and Codex OSS attribution for reused styling patterns.
- Started the active `v0.20.0` desktop UX slice on `codex/v0200-operator-timeline-public-docs-20260411`, combining `TASK-292`, `TASK-286`, and public operator-doc cleanup: composer attachments now support paste/drag-drop/file-picker, the conversation shell is moving to a concise filtered activity feed, and public operator docs are being split from contributor dogfooding docs.
- Expanded the active slice to include `TASK-299`, adding strict public operator/pane role-definition docs (`.claude/CLAUDE.md`, `AGENT-BASE.md`, `AGENT.md`, `GEMINI.md`, `docs/operator-model.md`) and aligning the timeline grammar with pane result reports.

## Validation

- Release workflow passed for `v0.19.6`.
- Release workflow passed for `v0.19.7`.
- Release workflow passed for `v0.19.8`: GitHub Actions run `24234569692` published `winsmux-x64.exe`, `winsmux-arm64.exe`, and `SHA256SUMS`.
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
- Current `TASK-297/292/293/294` starter slice passes frontend build: `npm run build` in `winsmux-app`.
- Current `TASK-107` editor slice is merged via PR [#387](https://github.com/Sora-bluesky/winsmux/pull/387).
- PR [#388](https://github.com/Sora-bluesky/winsmux/pull/388) merged cleanly and the repo is back to `main == origin/main`.
- Current `TASK-138` source-control slice passes frontend build: `npm run build` in `winsmux-app`.
- Current `TASK-101` theme-contract slice passes frontend build: `npm run build` in `winsmux-app`.
- Active `TASK-292/TASK-286/TASK-299` slice passes frontend build: `npm run build` in `winsmux-app`.

## Next actions

1. Publish the active `TASK-292/TASK-286/TASK-299` desktop UX slice, then continue `v0.20.0: Desktop UX Foundation` toward `TASK-287` and the remaining public-surface cleanup in `TASK-298`.
2. Preserve the private planning sync flow: user/agent visible, auto-synced, but not committed to the public repo.
3. Run the next retro-review tranche over recent merged PRs after each milestone-close sequence.

## Notes

- `HANDOFF.md` at the repository root is historical context and no longer authoritative.
- Public tracked files must not contain personal paths or private planning roots.
- External planning source of truth stays outside the public repository and is resolved via the configured planning root.
- Public docs may refer to the external planning contract, but must not embed machine-specific absolute paths.
- Public GitHub Release titles and bodies are standardized in English, even when the working session is conducted in Japanese.
- Before each release, explicitly re-check the boundary between public product docs/config and maintainer dogfooding material.
