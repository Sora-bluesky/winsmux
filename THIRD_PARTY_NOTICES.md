# Third-Party Notices

This repository may reuse selected UI/UX assets and implementation patterns from external open-source projects.

## winsmux core / legacy psmux compatibility surface

- Upstream: https://github.com/winsmux/winsmux
- License: MIT
- Copyright: Josh

### winsmux usage policy

winsmux retains selected MIT-derived compatibility implementation from the original terminal runtime, but it no longer ships the legacy binary aliases `psmux`, `pmux`, or `tmux`.
Operators should use `winsmux` in scripts and docs.

This includes:

- legacy data-path and terminal-multiplexer compatibility behavior
- tmux-compatible command, target, format, and configuration behavior

MIT does not require a separate NOTICE file in the same way Apache-2.0 often does, but winsmux keeps this entry anyway for provenance, auditability, and rename-debt tracking.

### Sunset policy

This section remains because MIT-derived runtime code and compatibility behavior still remain in the repository. It no longer describes shipped legacy binary aliases.

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

## microsoft/vscode

- Upstream: https://github.com/microsoft/vscode
- Pinned snapshot: `98b4a731eefbb5358e44dcc7dea03651baee00aa`
- License: MIT
- Copyright: Microsoft Corporation

### winsmux usage policy

winsmux may closely adapt selected public Visual Studio Code workbench density and styling references for the Tauri operator shell, including:

- workbench typography, spacing, and row-density direction
- activity bar, side bar, status bar, and settings surface affordances
- terminal colors, gutter behavior, selection, and cursor styling

When code or UI definitions are directly copied or closely adapted from `microsoft/vscode`, the implementing change must:

1. keep this notice file updated,
2. record the upstream source path(s) in the pull request or handoff,
3. preserve MIT attribution in the repository.

### Current tracked source references

These upstream areas are the current reference set for public `microsoft/vscode` workbench-derived UI work:

- `src/vs/workbench/browser/parts/activitybar/media/activitybarpart.css`
- `src/vs/workbench/browser/parts/activitybar/media/activityaction.css`
- `src/vs/workbench/browser/parts/editor/media/editortitlecontrol.css`
- `src/vs/workbench/browser/parts/statusbar/media/statusbarpart.css`
- `src/vs/workbench/contrib/preferences/browser/media/settingsEditor2.css`
- `src/vs/workbench/contrib/terminal/browser/media/terminal.css`
- `src/vs/workbench/contrib/terminal/browser/media/xterm.css`

### Current winsmux adaptation scope

The current `winsmux-app` density work tracks these public `microsoft/vscode` areas most closely:

- compact side-bar row heights and indentation
- compact status bar layout
- settings editor field and tab density
- terminal header density and dark terminal colors
- terminal left gutter and scrollbar behavior

This notice covers attribution and provenance tracking. It does not imply that winsmux reproduces Visual Studio Code verbatim end-to-end.
