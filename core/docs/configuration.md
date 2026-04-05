# Configuration

psmux reads its config on startup from the **first file found** (in order):

1. `~/.psmux.conf`
2. `~/.psmuxrc`
3. `~/.tmux.conf`
4. `~/.config/psmux/psmux.conf`

Config syntax is **tmux-compatible**. Most `.tmux.conf` lines work as-is.

You can also specify a custom config file path with the `-f` flag:

```powershell
# Use a specific config file instead of default search
psmux -f ~/.config/psmux/custom.conf

# Use an empty config (no settings loaded)
psmux -f NUL
```

This sets the `PSMUX_CONFIG_FILE` environment variable internally, which the server checks before searching the default locations.

## Basic Config Example

Create `~/.psmux.conf`:

```tmux
# Change prefix key to Ctrl+a
set -g prefix C-a

# Enable mouse
set -g mouse on

# Window numbering base (default is 1)
set -g base-index 1

# Customize status bar
set -g status-left "[#S] "
set -g status-right "%H:%M %d-%b-%y"
set -g status-style "bg=green,fg=black"

# Cursor style: block, underline, or bar
set -g cursor-style bar
set -g cursor-blink on

# Scrollback history
set -g history-limit 5000

# Prediction dimming (disable for apps like Neovim)
set -g prediction-dimming off

# Key bindings
bind-key -T prefix h split-window -h
bind-key -T prefix v split-window -v
```

## Choosing a Shell

psmux launches **PowerShell 7 (pwsh)** by default. You can change this:

```tmux
# Use cmd.exe
set -g default-shell cmd

# Use PowerShell 5 (Windows built-in)
set -g default-shell powershell

# Use PowerShell 7 (explicit path)
set -g default-shell "C:/Program Files/PowerShell/7/pwsh.exe"

# Use Git Bash
set -g default-shell "C:/Program Files/Git/bin/bash.exe"

# Use Nushell
set -g default-shell nu

# Use Windows Subsystem for Linux (via wsl.exe)
set -g default-shell wsl
```

You can also launch a window with a specific command without changing the default:

```powershell
psmux new-window -- cmd /K echo hello
psmux new-session -s py -- python
psmux split-window -- "C:/Program Files/Git/bin/bash.exe"
```

## All Set Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `prefix` | Key | `C-b` | Prefix key |
| `prefix2` | Key | `none` | Secondary prefix key (optional) |
| `base-index` | Int | `0` | First window number |
| `pane-base-index` | Int | `0` | First pane number |
| `escape-time` | Int | `500` | Escape delay (ms) |
| `repeat-time` | Int | `500` | Repeat key timeout (ms) |
| `history-limit` | Int | `2000` | Scrollback lines per pane |
| `display-time` | Int | `750` | Message display time (ms) |
| `display-panes-time` | Int | `1000` | Pane overlay time (ms) |
| `status-interval` | Int | `15` | Status refresh (seconds) |
| `mouse` | Bool | `on` | Mouse support |
| `status` | Bool/Int | `on` | Show status bar (number = line count) |
| `status-position` | Str | `bottom` | `top` or `bottom` |
| `status-justify` | Str | `left` | `left`, `centre`, `right`, `absolute-centre` |
| `status-left-length` | Int | `10` | Max width of status-left |
| `status-right-length` | Int | `40` | Max width of status-right |
| `focus-events` | Bool | `off` | Pass focus events to apps |
| `mode-keys` | Str | `emacs` | `vi` or `emacs` |
| `renumber-windows` | Bool | `off` | Auto-renumber windows on close |
| `automatic-rename` | Bool | `on` | Rename windows from foreground process |
| `monitor-activity` | Bool | `off` | Flag windows with new output |
| `monitor-silence` | Int | `0` | Seconds before silence flag (0=off) |
| `visual-activity` | Bool | `off` | Visual indicator for activity |
| `synchronize-panes` | Bool | `off` | Send input to all panes |
| `remain-on-exit` | Bool | `off` | Keep panes after process exits |
| `aggressive-resize` | Bool | `off` | Resize to smallest client |
| `window-size` | Str | `latest` | `largest`, `smallest`, `manual`, `latest` |
| `destroy-unattached` | Bool | `off` | Exit server when no clients attached |
| `exit-empty` | Bool | `on` | Exit server when all windows closed |
| `set-titles` | Bool | `off` | Update terminal title |
| `set-titles-string` | Str | | Terminal title format |
| `default-shell` | Str | `pwsh` | Shell to launch |
| `default-command` | Str | | Alias for default-shell |
| `word-separators` | Str | `" -_@"` | Copy-mode word delimiters |
| `activity-action` | Str | `other` | Action on window activity: `any`, `none`, `current`, `other` |
| `silence-action` | Str | `other` | Action on window silence: `any`, `none`, `current`, `other` |
| `bell-action` | Str | `any` | Bell action: controls audible bell forwarding and status bar flag (`any`, `none`, `current`, `other`) |
| `visual-bell` | Bool | `off` | Visual bell indicator |
| `allow-passthrough` | Str | `off` | Allow terminal passthrough sequences (`on`/`off`/`all`) |
| `allow-rename` | Bool | `on` | Allow programs to set window title via escape sequences |
| `allow-predictions` | Bool | `off` | Preserve PSReadLine prediction settings (see below) |
| `default-terminal` | Str | | Terminal type string (sets `TERM` env var in panes) |
| `update-environment` | Str | *(tmux defaults)* | Space-separated list of env vars to refresh on client attach |
| `warm` | Bool | `on` | Pre-spawn shells for instant window/pane creation (see [warm-sessions.md](warm-sessions.md)) |
| `copy-command` | Str | | Shell command for clipboard pipe |
| `set-clipboard` | Str | `on` | Clipboard interaction (`on`/`off`/`external`) |
| `main-pane-width` | Int | `0` | Main pane width in main-vertical layout |
| `main-pane-height` | Int | `0` | Main pane height in main-horizontal layout |

### Style Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `status-left` | Str | `[#S] ` | Left status bar content |
| `status-right` | Str | | Right status bar content |
| `status-style` | Str | `bg=green,fg=black` | Status bar style |
| `status-left-style` | Str | | Left status style |
| `status-right-style` | Str | | Right status style |
| `message-style` | Str | `bg=yellow,fg=black` | Message style |
| `message-command-style` | Str | `bg=black,fg=yellow` | Command prompt style |
| `mode-style` | Str | `bg=yellow,fg=black` | Copy-mode highlight |
| `pane-border-style` | Str | | Inactive border style |
| `pane-active-border-style` | Str | `fg=green` | Active border style |
| `pane-border-format` | Str | | Pane border format string |
| `pane-border-status` | Str | | Pane border status position (`top`/`bottom`) |
| `window-status-format` | Str | `#I:#W#F` | Inactive tab format |
| `window-status-current-format` | Str | `#I:#W#F` | Active tab format |
| `window-status-separator` | Str | `" "` | Tab separator |
| `window-status-style` | Str | | Inactive tab style |
| `window-status-current-style` | Str | | Active tab style |
| `window-status-activity-style` | Str | `reverse` | Activity tab style |
| `window-status-bell-style` | Str | `reverse` | Bell tab style |
| `window-status-last-style` | Str | | Last-active tab style |

### Bell

When a program inside a pane emits BEL (`\x07`), psmux forwards the bell character to your host terminal so you hear the audible beep. The `bell-action` option controls when this happens and when the status bar tab gets a bell flag (`!`):

```tmux
# Forward bell from any window (default)
set -g bell-action any

# Forward bell only from the active window
set -g bell-action current

# Forward bell only from non-active windows
set -g bell-action other

# Mute bell completely (no sound, no status bar flag)
set -g bell-action none
```

The `window-status-bell-style` option controls how the tab looks when flagged:

```tmux
set -g window-status-bell-style "fg=red,bold"
```

PowerShell example to test:

```powershell
# These should all produce an audible beep inside psmux:
Write-Host "`a"
[Console]::Beep()
[char]7
```

### psmux Extensions (Windows-specific)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `prediction-dimming` | Bool | `off` | Dim predictive/speculative text |
| `cursor-style` | Str | | Cursor shape: `block`, `underline`, or `bar` |
| `cursor-blink` | Bool | `off` | Cursor blinking |
| `env-shim` | Bool | `on` | Inject Unix-compatible `env` function in PowerShell panes |
| `claude-code-fix-tty` | Bool | `on` | Patch Node.js process.stdout.isTTY for Claude Code |
| `claude-code-force-interactive` | Bool | `on` | Set CLAUDE_CODE_FORCE_INTERACTIVE=1 in panes |

Style format: `"fg=colour,bg=colour,bold,dim,underscore,italics,reverse,strikethrough"`

Colours: `default`, `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, `colour0`–`colour255`, `#RRGGBB`

## Environment Variables

```powershell
# Default session name used when not explicitly provided
$env:PSMUX_DEFAULT_SESSION = "work"

# Enable prediction dimming (off by default; dims predictive/speculative text)
$env:PSMUX_DIM_PREDICTIONS = "1"

# Disable warm pane pre-spawning (same as set -g warm off)
$env:PSMUX_NO_WARM = "1"

# Override the config file path (same effect as -f flag)
$env:PSMUX_CONFIG_FILE = "C:\Users\me\.psmux-alt.conf"

# These are set INSIDE psmux panes (tmux-compatible):
# TMUX       - socket path and server info
# TMUX_PANE  - current pane ID (%0, %1, etc.)
```

## Managing Environment Variables

Use `set-environment` to set env vars that are inherited by newly created panes:

```powershell
# Set a global env var (inherited by all new panes)
psmux set-environment -g EDITOR vim

# Set a session-scoped env var
psmux set-environment MY_VAR value

# Unset an env var
psmux set-environment -gu MY_VAR

# Show all environment variables
psmux show-environment
psmux show-environment -g
```

Environment variables set this way are injected at the process level when new panes spawn, so they are completely invisible (no commands echoed in the shell).

## PSReadLine Predictions (Intellisense / Autocompletion)

By default, psmux disables PSReadLine inline predictions (the grayed-out autocompletion/intellisense suggestions that appear as you type) to avoid additional unexpected bugs caused by the interaction between predictions and ConPTY. This means `PredictionSource` defaults to `None` inside psmux, even if your profile sets it to `HistoryAndPlugin` ([#150](https://github.com/psmux/psmux/issues/150)).

If enough people test predictions and the community supports enabling them by default, this will be changed in a future release.

To preserve your prediction/autocompletion settings, enable `allow-predictions`:

```tmux
set -g allow-predictions on
```

With this enabled:
- If your profile sets `PredictionSource`, psmux respects your choice
- If your profile does not set it, psmux restores the system default (typically `HistoryAndPlugin`)

## Prediction Dimming

Prediction dimming is off by default. If you want psmux to dim predictive/speculative text (e.g. shell autosuggestions), you can enable it in `~/.psmux.conf`:

```tmux
set -g prediction-dimming on
```

You can also enable it for the current shell only:

```powershell
$env:PSMUX_DIM_PREDICTIONS = "1"
psmux
```

To make it persistent for new shells:

```powershell
setx PSMUX_DIM_PREDICTIONS 1
```
