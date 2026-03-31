[English](README.md) | [日本語](README.ja.md)

# winsmux

Native Windows terminal multiplexer with cross-pane AI agent communication — no WSL2 required.

- **For you** — keyboard-driven pane management with Alt-key bindings on PowerShell
- **For agents** — `psmux-bridge` CLI lets any agent read, type, and send keys to any pane
- **Agent-to-agent** — Claude Code can prompt Codex in the next pane, and Codex replies back. Any agent that can run shell commands can participate.

```powershell
psmux-bridge read codex 20              # read the pane
psmux-bridge type codex "review src/auth.ts"  # type into it
psmux-bridge keys codex Enter           # press Enter
```

## Install

```powershell
irm https://raw.githubusercontent.com/Sora-bluesky/winsmux/main/install.ps1 | iex
```

This installs:

- **psmux** if not already installed (via winget, scoop, cargo, or chocolatey)
- **psmux-bridge** CLI for cross-pane agent communication
- **.psmux.conf** with Alt-key bindings, mouse support, and pane labels

Everything lives in `~\.winsmux\`.

## Quick Start

```powershell
# 1. Start a session
psmux new-session -s work

# 2. Split a pane (Alt+n also works)
psmux split-window -h

# 3. Label the panes
psmux-bridge name %1 claude
psmux-bridge name %2 codex

# 4. Send a message
psmux-bridge read codex 20
psmux-bridge message codex "review src/auth.ts"
psmux-bridge read codex 20
psmux-bridge keys codex Enter
```

## Keybindings

All keybindings use **Alt** with no prefix required.

### Panes

| Key           | Action                       |
| ------------- | ---------------------------- |
| `Alt+i/k/j/l` | Navigate up/down/left/right  |
| `Alt+n`       | New pane (split + auto-tile) |
| `Alt+w`       | Close pane                   |
| `Alt+o`       | Cycle layouts                |
| `Alt+g`       | Mark pane                    |
| `Alt+y`       | Swap with marked pane        |

### Windows

| Key     | Action          |
| ------- | --------------- |
| `Alt+m` | New window      |
| `Alt+u` | Next window     |
| `Alt+h` | Previous window |

### Scrolling

| Key             | Action             |
| --------------- | ------------------ |
| `Alt+Tab`       | Toggle scroll mode |
| `i/k`           | Scroll up/down     |
| `Shift+I/K`     | Half-page up/down  |
| `q` or `Escape` | Exit scroll mode   |

### Mouse

- Click to select panes
- Drag to select text (auto-copies to clipboard)
- Scroll wheel to scroll

## psmux-bridge

A CLI for cross-pane communication on Windows. Any tool that can run shell commands can use it — Claude Code, Codex, Gemini CLI, or a plain PowerShell script.

| Command                                 | Description                                |
| --------------------------------------- | ------------------------------------------ |
| `psmux-bridge list`                     | Show all panes with target, process, label |
| `psmux-bridge read <target> [lines]`    | Read last N lines from a pane (default 50) |
| `psmux-bridge type <target> <text>`     | Type text into a pane (no Enter)           |
| `psmux-bridge keys <target> <key>...`   | Send keys (Enter, Escape, C-c, etc.)       |
| `psmux-bridge message <target> <text>`  | Send tagged message with sender info       |
| `psmux-bridge name <target> <label>`    | Label a pane for easy addressing           |
| `psmux-bridge resolve <label>`          | Look up a pane by label                    |
| `psmux-bridge id`                       | Print this pane's ID                       |
| `psmux-bridge ime-input <target>`       | Open GUI dialog for Japanese IME input     |
| `psmux-bridge image-paste <target>`     | Save clipboard image and send path to pane |
| `psmux-bridge clipboard-paste <target>` | Send clipboard text to pane                |
| `psmux-bridge send <target> <text>`     | Send text and press Enter (recommended)    |
| `psmux-bridge focus <label\|target>`    | Switch active pane (from outside psmux)    |
| `psmux-bridge doctor`                   | Check environment and IME diagnostics      |
| `psmux-bridge version`                  | Show version                               |

### Read Guard

The CLI enforces a **read-before-act** rule. You cannot `type` or `keys` to a pane unless you have read it first. After each `type`/`keys`, the mark clears and you must read again.

```powershell
psmux-bridge type codex "hello"
# error: must read the pane before interacting. Run: psmux-bridge read codex
```

This prevents agents from blindly typing into the wrong pane.

### Targeting

Panes can be addressed by:

- **Pane ID** — `%3`, `%5` (psmux native IDs)
- **Label** — any name set via `psmux-bridge name`

Labels are resolved automatically in every command. Stored in `$env:APPDATA\winsmux\labels.json`.

## Orchestra

The Orchestra workflow uses a Commander (in a separate terminal) orchestrating background agents in psmux panes. Supports any grid size and mixed CLI agents (Claude Code, Codex, Gemini CLI).

### Default (2×2)

```powershell
# 1. Open a terminal and start psmux
psmux

# 2. From another terminal, run the orchestra setup
pwsh scripts/start-orchestra.ps1 -ProjectDir C:\path\to\project
```

### Custom (e.g. 3×2 with 6 agents)

```powershell
pwsh scripts/start-orchestra.ps1 -ProjectDir C:\my\project -Rows 2 -Cols 3 -Agents @(
  @{label="builder-1"; command="codex"},
  @{label="researcher"; command="claude --model sonnet"},
  @{label="builder-2"; command="codex"},
  @{label="builder-3"; command="gemini --model gemini-3.1-pro-preview"},
  @{label="builder-4"; command="gemini --model gemini-3-flash-preview"},
  @{label="reviewer"; command="codex"}
) -ShieldHarness
```

```
┌──────────┬──────────┬──────────┐
│builder-1 │builder-2 │builder-3 │
├──────────┼──────────┼──────────┤
│researcher│builder-4 │reviewer  │
└──────────┴──────────┴──────────┘
```

The Commander runs in a separate terminal with full keyboard access:

```powershell
cd C:\my\project
claude --model claude-opus-4-6 --permission-mode bypassPermissions --append-system-prompt-file .commander-prompt.txt
```

| Parameter        | Default           | Description                       |
| ---------------- | ----------------- | --------------------------------- |
| `-ProjectDir`    | Current directory | Working directory for all panes   |
| `-Rows`          | 2                 | Grid rows                         |
| `-Cols`          | 2                 | Grid columns                      |
| `-Agents`        | 4-pane default    | Array of `@{label; command}` maps |
| `-ShieldHarness` | Off               | Enable approval-free mode         |

### Approval-Free Mode (Shield Harness)

Add `-ShieldHarness` to enable approval-free operation. [Shield Harness](https://github.com/Sora-bluesky/shield-harness) provides security hooks so agents operate without approval dialogs while dangerous operations are blocked.

When enabled, the script automatically appends the appropriate flag per CLI:

| CLI         | Flag added                            |
| ----------- | ------------------------------------- |
| Claude Code | `--permission-mode bypassPermissions` |
| Codex CLI   | `--full-auto`                         |
| Gemini CLI  | `--yolo`                              |

Without `-ShieldHarness`: no flags are added (manual approval mode).

### Multi-Builder Coordination

The Commander follows a strict protocol for parallel builders:

1. **Split** — Assign independent file sets per builder (avoid overlapping files)
2. **Poll** — Cycle `psmux-bridge read builder-1`, `read builder-2`, etc.
3. **Review** — Send completed work to reviewer as each builder finishes
4. **Conflict check** — `git diff --name-only` before merging
5. **Commit** — Merge and commit after review passes

See [SKILL.md](skills/winsmux/SKILL.md) for the full Commander workflow.

## AI Agent Skills

Install the winsmux skill to teach your agents how to use psmux-bridge:

```powershell
npx skills add Sora-bluesky/winsmux
```

Works with Claude Code, Codex, Cursor, Copilot, and [other agents](https://skills.sh).

## Update

```powershell
winsmux update
```

## Uninstall

```powershell
winsmux uninstall
```

## Requirements

- Windows 10/11
- PowerShell 7+ (pwsh)
- [psmux](https://github.com/psmux/psmux) (installed automatically)

## Acknowledgments

winsmux is the Windows-native counterpart of [smux](https://github.com/ShawnPana/smux) by [@ShawnPana](https://github.com/ShawnPana). smux provides the same terminal multiplexer + AI agent communication workflow for macOS/Linux using tmux. winsmux brings that experience to Windows natively via psmux, without requiring WSL2.

## License

MIT
