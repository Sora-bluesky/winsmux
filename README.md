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
# TODO: installer
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

### Windows

| Key | Action |
|---|---|
| `Alt+m` | New window |
| `Alt+u` | Next window |
| `Alt+h` | Previous window |

## psmux-bridge

A CLI for cross-pane communication on Windows. Any tool that can run shell commands can use it — Claude Code, Codex, Gemini CLI, or a plain PowerShell script.

| Command | Description |
|---|---|
| `psmux-bridge list` | Show all panes with target, process, label |
| `psmux-bridge read <target> [lines]` | Read last N lines from a pane |
| `psmux-bridge type <target> <text>` | Type text into a pane (no Enter) |
| `psmux-bridge keys <target> <key>...` | Send keys (Enter, Escape, Ctrl+C, etc.) |
| `psmux-bridge name <target> <label>` | Label a pane for easy addressing |
| `psmux-bridge resolve <label>` | Look up a pane by label |
| `psmux-bridge id` | Print this pane's ID |

## Requirements

- Windows 10/11
- PowerShell 5.1+ or PowerShell 7+
- [psmux](https://github.com/nickcox/psmux) (installed automatically)

## Acknowledgments

This project is the Windows-native counterpart of [smux](https://github.com/ShawnPana/smux) by [@ShawnPana](https://github.com/ShawnPana). smux provides the same terminal multiplexer + AI agent communication workflow for macOS/Linux using tmux. winsmux brings that experience to Windows natively via psmux, without requiring WSL2.

## License

MIT
