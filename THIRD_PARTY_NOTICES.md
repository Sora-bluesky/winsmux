# Third-Party Notices

This repository may reuse selected UI/UX assets and implementation patterns from external open-source projects.

## winsmux core / legacy psmux compatibility surface

- Upstream: https://github.com/winsmux/winsmux
- License: MIT
- Copyright: Josh

### winsmux usage policy

winsmux retains selected legacy compatibility surfaces that still expose or reference `psmux`, `pmux`, or `tmux` names through the MIT-licensed core upstream.

This includes:

- legacy binary aliases
- legacy CLI/help compatibility
- legacy data-path and terminal-multiplexer compatibility behavior

MIT does not require a separate NOTICE file in the same way Apache-2.0 often does, but winsmux keeps this entry anyway for provenance, auditability, and rename-debt tracking.

### Current tracked source references

- `core/Cargo.toml`
- `core/src/main.rs`
- `core/src/cli.rs`

## openai/codex

- Upstream: https://github.com/openai/codex
- License: Apache-2.0
- Copyright: OpenAI

### winsmux usage policy

winsmux may directly reuse or adapt selected Codex UI assets for the Tauri operator shell, including:

- typography and color/style direction
- wrapping and footer/status-lane behavior
- settings/menu display affordances
- conversation-shell interaction patterns

When code or UI definitions are directly copied or closely adapted from `openai/codex`, the implementing change must:

1. keep this notice file updated,
2. record the upstream source path(s) in the pull request or handoff,
3. preserve Apache-2.0 attribution in the repository.

### Current tracked source references

These upstream areas are the current reference set for Codex-derived UI work:

- `codex-rs/tui/`
- `codex-rs/tui/src/wrapping.rs`
- `codex-rs/tui/src/bottom_pane/footer.rs`
- `codex-rs/tui/src/bottom_pane/slash_command.rs`
- `codex-rs/tui/src/bottom_pane/history_search.rs`
- `codex-rs/tui/styles.md`
- `codex-rs/AGENTS.md`

This notice covers attribution and provenance tracking. It does not imply that winsmux reproduces Codex verbatim end-to-end.
