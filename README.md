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

| Key | Action |
|---|---|
| `Alt+i/k/j/l` | Navigate up/down/left/right |
| `Alt+n` | New pane (split + auto-tile) |
| `Alt+w` | Close pane |
| `Alt+o` | Cycle layouts |
| `Alt+g` | Mark pane |
| `Alt+y` | Swap with marked pane |

### Windows

| Key | Action |
|---|---|
| `Alt+m` | New window |
| `Alt+u` | Next window |
| `Alt+h` | Previous window |

### Scrolling

| Key | Action |
|---|---|
| `Alt+Tab` | Toggle scroll mode |
| `i/k` | Scroll up/down |
| `Shift+I/K` | Half-page up/down |
| `q` or `Escape` | Exit scroll mode |

### Mouse

- Click to select panes
- Drag to select text (auto-copies to clipboard)
- Scroll wheel to scroll

## psmux-bridge

A CLI for cross-pane communication on Windows. Any tool that can run shell commands can use it — Claude Code, Codex, Gemini CLI, or a plain PowerShell script.

| Command | Description |
|---|---|
| `psmux-bridge list` | Show all panes with target, process, label |
| `psmux-bridge read <target> [lines]` | Read last N lines from a pane (default 50) |
| `psmux-bridge type <target> <text>` | Type text into a pane (no Enter) |
| `psmux-bridge keys <target> <key>...` | Send keys (Enter, Escape, C-c, etc.) |
| `psmux-bridge message <target> <text>` | Send tagged message with sender info |
| `psmux-bridge name <target> <label>` | Label a pane for easy addressing |
| `psmux-bridge resolve <label>` | Look up a pane by label |
| `psmux-bridge id` | Print this pane's ID |
| `psmux-bridge ime-input <target>` | Open GUI dialog for Japanese IME input |
| `psmux-bridge image-paste <target>` | Save clipboard image and send path to pane |
| `psmux-bridge clipboard-paste <target>` | Send clipboard text to pane |
| `psmux-bridge doctor` | Check environment and IME diagnostics |
| `psmux-bridge version` | Show version |

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

## Orchestra (4-Pane Setup)

The Orchestra workflow uses a 2×2 grid where Claude Code orchestrates multiple agents:

```
┌──────────────┬──────────────┐
│  Commander   │   Builder    │
│ Claude Opus  │  Codex CLI   │
├──────────────┼──────────────┤
│  Researcher  │   Reviewer   │
│ Claude Sonnet│  Codex CLI   │
└──────────────┴──────────────┘
```

| Pane | Role | Responsibility |
|---|---|---|
| Commander | Design & orchestrate | Task decomposition, instructions, git operations |
| Builder | Implement | Code implementation, fix reviewer findings |
| Researcher | Investigate | Research, test, lint, documentation |
| Reviewer | Review | Security, architecture, and quality review |

### Quick launch

```powershell
# 1. Open a terminal and start psmux
psmux

# 2. From another terminal, run the orchestra setup
pwsh scripts/start-orchestra.ps1 -ProjectDir C:\path\to\your\project
```

Commander auto-receives its role, pane assignments, and workflow rules via `--append-system-prompt`.

> **Important:** Always start psmux manually in a terminal first. Do not launch psmux via `Start-Process` — it breaks color rendering.

### Customization

All roles are configurable via parameters:

```powershell
pwsh scripts/start-orchestra.ps1 `
  -ProjectDir C:\my\project `
  -Commander "claude --model opus" `
  -Researcher "claude --model sonnet" `
  -Builder "codex" `
  -Reviewer "claude --model haiku"
```

| Parameter | Default |
|---|---|
| `-ProjectDir` | Current directory |
| `-Commander` | `claude --model opus --channels plugin:telegram@claude-plugins-official` |
| `-Researcher` | `claude --model sonnet` |
| `-Builder` | `codex` |
| `-Reviewer` | `codex` |
| `-ShieldHarness` | Off (switch) |

### Approval-Free Mode (Shield Harness)

Add `-ShieldHarness` to enable approval-free operation for Commander and Researcher. [Shield Harness](https://github.com/Sora-bluesky/shield-harness) provides 22 security hooks, deny rules, and evidence recording — so agents operate without approval dialogs while dangerous operations are automatically blocked.

```powershell
pwsh scripts/start-orchestra.ps1 -ProjectDir C:\my\project -ShieldHarness
```

- First run: auto-initializes shield-harness in the project (`npx shield-harness init --profile standard`)
- Subsequent runs: detects existing installation and skips init
- Without `-ShieldHarness`: works exactly as before (manual approval mode)

The workflow cycle: **Plan → Build → Poll → Review → Poll → Judge → Commit → Next**.

Commander never writes code directly — it delegates to builder and sends reviewer findings back to builder for fixes.

See [SKILL.md](skills/winsmux/SKILL.md) for the full Commander workflow, poll patterns, and auto-approval rules.

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
