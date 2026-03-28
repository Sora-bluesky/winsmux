# winsmux

Native Windows terminal multiplexer with cross-pane AI agent communication — no WSL2 required.

- **For you** — keyboard-driven pane management with Alt-key bindings on PowerShell
- **For agents** — `psmux-bridge` CLI lets any agent read, type, and send keys to any pane
- **Agent-to-agent** — Claude Code can prompt Codex in the next pane, and Codex replies back. Any agent that can run shell commands can participate.

```powershell
psmux-bridge read codex 20              # read the pane
psmux-bridge type codex "review src/auth.ts"  # type into it
psmux-bridge keys codex Enter           # press enter
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
| `psmux-bridge doctor` | Check environment and diagnostics |

## AI Agent Skills

Install the winsmux skill to teach your agents how to use psmux-bridge:

```powershell
npx skills add Sora-bluesky/winsmux
```

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

This project is the Windows-native counterpart of [smux](https://github.com/ShawnPana/smux) by [@ShawnPana](https://github.com/ShawnPana). smux provides the same terminal multiplexer + AI agent communication workflow for macOS/Linux using tmux. winsmux brings that experience to Windows natively via psmux, without requiring WSL2.

## License

MIT
