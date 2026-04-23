# Upstream Snapshot Baseline

Purpose: contributor-facing contract for `TASK-363`.

This document defines how winsmux pins public upstream source snapshots for Rust/Tauri operator-shell reuse.
It is not a user-facing product guide.

## Current Baseline

- Upstream repository: `https://github.com/openai/codex`
- Local reference path: `.references/codex`
- Pinned commit: `1dc3535e17666884800ada37d7eb94cf974d38fe`
- Upstream commit summary: `[codex] Add marketplace/remove app-server RPC (#17751)`
- License: `Apache-2.0`
- Primary tracked area: `codex-rs/tui/`

The `.references/codex` checkout is local reference material.
Do not vendor it into the public repository.

## Tracked Source Areas

The current reusable source areas are limited to public `openai/codex` TUI code and documentation:

- `codex-rs/tui/`
- `codex-rs/tui/src/app.rs`
- `codex-rs/tui/src/chatwidget.rs`
- `codex-rs/tui/src/wrapping.rs`
- `codex-rs/tui/src/bottom_pane/chat_composer.rs`
- `codex-rs/tui/src/bottom_pane/footer.rs`
- `codex-rs/tui/src/bottom_pane/slash_commands.rs`
- `codex-rs/tui/src/bottom_pane/chat_composer_history.rs`
- `codex-rs/tui/src/theme_picker.rs`
- `codex-rs/tui/styles.md`
- `codex-rs/tui/src/bottom_pane/AGENTS.md`

Do not use non-public Codex App desktop source as an upstream source.

## winsmux Overlay Boundary

winsmux may adapt these upstream areas for:

- typography and semantic theme tokens
- conversation-shell wrapping behavior
- footer and status-lane affordances
- composer behavior and command discovery patterns
- settings and menu display affordances

winsmux must keep these as local overlay or adapter work:

- Tauri command wiring
- PowerShell bridge integration
- named-pipe control-plane routing
- winsmux provider and authentication policy
- workspace lifecycle behavior
- release and evidence gates

Do not edit upstream snapshots in place to create product behavior.
Implement winsmux behavior in tracked winsmux files.

## Update Rule

Do not follow upstream automatically.

Refresh this baseline only when all of these are true:

1. The upstream change has a clear security, maintainability, or user-facing value.
2. The source area is public and covered by an OSS license.
3. The expected winsmux overlay change is documented before implementation.
4. `THIRD_PARTY_NOTICES.md` remains accurate.
5. The reevaluation result is recorded through `TASK-315` or a narrower implementation task.

## Required Pull Request Evidence

When a change directly copies or closely adapts upstream UI code or styles, record:

- the upstream repository,
- the pinned commit,
- the upstream source path,
- the winsmux target path,
- whether the change is copy, close adaptation, or behavioral reference,
- and the validation command used for the winsmux side.

If the change only uses upstream as a loose design reference, say so explicitly.
