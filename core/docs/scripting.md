# Scripting & Automation

winsmux supports tmux-compatible commands for scripting and automation.

## Window & Pane Control

```powershell
# Create a new window
winsmux new-window

# Split panes
winsmux split-window -v          # Split vertically (top/bottom)
winsmux split-window -h          # Split horizontally (side by side)

# Navigate panes
winsmux select-pane -U           # Select pane above
winsmux select-pane -D           # Select pane below
winsmux select-pane -L           # Select pane to the left
winsmux select-pane -R           # Select pane to the right

# Navigate windows
winsmux select-window -t 1       # Select window by index (default base-index is 1)
winsmux next-window              # Go to next window
winsmux previous-window          # Go to previous window
winsmux last-window              # Go to last active window

# Kill panes and windows
winsmux kill-pane
winsmux kill-window
winsmux kill-session
```

## Sending Keys

```powershell
# Send text directly
winsmux send-keys "ls -la" Enter

# Send keys literally (no parsing)
winsmux send-keys -l "literal text"

# Special keys supported:
# Enter, Tab, Escape, Space, Backspace
# Up, Down, Left, Right, Home, End
# PageUp, PageDown, Delete, Insert
# F1-F12, C-a through C-z (Ctrl+key)
```

## Pane Information

```powershell
# List all panes in current window
winsmux list-panes

# List all windows
winsmux list-windows

# Capture pane content
winsmux capture-pane

# Display formatted message with variables
winsmux display-message "#S:#I:#W"   # Session:Window Index:Window Name
```

## Paste Buffers

```powershell
# Set paste buffer content
winsmux set-buffer "text to paste"

# Paste buffer to active pane
winsmux paste-buffer

# List all buffers
winsmux list-buffers

# Show buffer content
winsmux show-buffer

# Delete buffer
winsmux delete-buffer
```

## Pane Layout

```powershell
# Resize panes
winsmux resize-pane -U 5         # Resize up by 5
winsmux resize-pane -D 5         # Resize down by 5
winsmux resize-pane -L 10        # Resize left by 10
winsmux resize-pane -R 10        # Resize right by 10

# Swap panes
winsmux swap-pane -U             # Swap with pane above
winsmux swap-pane -D             # Swap with pane below

# Rotate panes in window
winsmux rotate-window

# Toggle pane zoom
winsmux zoom-pane
```

## Session Management

```powershell
# Check if session exists (exit code 0 = exists)
winsmux has-session -t mysession

# Rename session
winsmux rename-session newname

# Respawn pane (restart shell)
winsmux respawn-pane
```

## Environment Variables

```powershell
# Set a global env var (inherited by all new panes)
winsmux set-environment -g EDITOR vim

# Set a session-scoped env var
winsmux set-environment MY_VAR value

# Unset a global env var
winsmux set-environment -gu MY_VAR

# Show all environment variables
winsmux show-environment
winsmux show-environment -g
```

## Format Variables

The `display-message` command supports these variables:

| Variable | Description |
|----------|-------------|
| `#S` | Session name |
| `#I` | Window index |
| `#W` | Window name |
| `#P` | Pane ID |
| `#T` | Pane title |
| `#H` | Hostname |

## Advanced Commands

```powershell
# Discover supported commands
winsmux list-commands

# Server/session management
winsmux kill-server
winsmux list-clients
winsmux switch-client -t other-session

# Config at runtime
winsmux source-file ~/.winsmux.conf
winsmux show-options
winsmux set-option -g status-left "[#S]"

# Layout/history/stream control
winsmux next-layout
winsmux previous-layout
winsmux clear-history
winsmux pipe-pane -o "cat > pane.log"

# Hooks
winsmux set-hook -g after-new-window "display-message created"
winsmux show-hooks
```

## Target Syntax (`-t`)

winsmux supports tmux-style targets:

```powershell
# window by index in session
winsmux select-window -t work:2

# specific pane by index
winsmux send-keys -t work:2.1 "echo hi" Enter

# pane by pane id
winsmux send-keys -t %3 "pwd" Enter

# window by window id
winsmux select-window -t @4
```
