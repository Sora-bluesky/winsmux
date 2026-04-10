# Third-Party Notices

This repository may reuse selected UI/UX assets and implementation patterns from external open-source projects.

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
