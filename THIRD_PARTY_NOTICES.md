# Third-Party Notices

This repository may reuse selected UI/UX assets and implementation patterns from external open-source projects.

## winsmux core / legacy psmux compatibility surface

- Upstream: https://github.com/winsmux/winsmux
- License: MIT
- Copyright: Josh

### winsmux usage policy

winsmux currently retains selected legacy compatibility surfaces that still expose or reference `psmux`, `pmux`, or `tmux` names through the MIT-licensed core upstream.

This includes:

- legacy binary aliases
- legacy CLI/help compatibility
- legacy data-path and terminal-multiplexer compatibility behavior

MIT does not require a separate NOTICE file in the same way Apache-2.0 often does, but winsmux keeps this entry anyway for provenance, auditability, and rename-debt tracking.

### Sunset policy

This section is tied to the active compatibility contract.

- While legacy `psmux` compatibility remains in the public product surface, keep this notice entry and keep the tracked source references current.
- When the compatibility sunset is completed before `v1.0.0`, update this section to reflect the post-sunset reality:
  - remove references that no longer ship in the public surface,
  - keep attribution only for code or assets that still remain in-repo,
  - or remove this section entirely if no MIT-derived `psmux` compatibility surface remains.

In other words, this entry is not permanent. It should evolve with the compatibility contract and be reduced or removed once the sunset work is complete.

### Current tracked source references

- `core/Cargo.toml`
- `core/src/main.rs`
- `core/src/cli.rs`

## openai/codex

- Upstream: https://github.com/openai/codex
- Pinned snapshot: `1dc3535e17666884800ada37d7eb94cf974d38fe`
- License: Apache-2.0
- Copyright: OpenAI

### winsmux usage policy

winsmux may directly reuse or adapt selected public `openai/codex` TUI assets for the Tauri operator shell, including:

- typography and color/style direction
- wrapping and footer/status-lane behavior
- settings/menu display affordances
- conversation-shell interaction patterns

When code or UI definitions are directly copied or closely adapted from `openai/codex`, the implementing change must:

1. keep this notice file updated,
2. record the upstream source path(s) in the pull request or handoff,
3. preserve Apache-2.0 attribution in the repository.

### Current tracked source references

These upstream areas are the current reference set for public `openai/codex` TUI-derived UI work:

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

The contributor-facing snapshot contract is documented in `docs/project/upstream-snapshot-baseline.md`.
That document defines the pinned commit, local reference checkout, overlay boundary, and update rule.

### Current winsmux adaptation scope

The current `winsmux-app` shell work tracks these public `openai/codex` TUI-derived areas most closely:

- typography and semantic theme token direction
- conversation-shell wrapping behavior
- footer/status-lane affordances
- settings/menu surface affordances

### Adaptation guardrails

Public `openai/codex` TUI-derived UI reuse in winsmux follows the active release-train acceptance rules for utility-first surfaces, real-data-first release paths, minimal chrome, and Playwright viewport verification evidence recorded in backlog notes, pull requests, or handoff.

These are project adaptation guardrails, not additional license terms.

This notice covers attribution and provenance tracking. It does not imply that winsmux reproduces Codex verbatim end-to-end, or that winsmux incorporates non-public Codex App desktop source code.
