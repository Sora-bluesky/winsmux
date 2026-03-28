---
name: winsmux
description: |
  Control psmux panes and communicate between AI agents on Windows.
  Use this skill whenever the user mentions pane control, cross-pane communication,
  sending messages to other agents, reading other panes, or managing psmux sessions on Windows.
---

# winsmux

Psmux pane control and cross-pane agent communication on Windows. Use `psmux-bridge` (the high-level CLI) for all cross-pane interactions. Fall back to raw psmux commands only when you need low-level control.

## psmux-bridge — Cross-Pane Communication

A CLI that lets any AI agent interact with any other psmux pane. Works via PowerShell. Every command is **atomic**: `type` types text (no Enter), `keys` sends special keys, `read` captures pane content.

### DO NOT WAIT OR POLL

Other panes have agents that will reply to you via psmux-bridge. Their reply appears directly in YOUR pane as a `[psmux-bridge from:...]` message. Do not sleep, poll, read the target pane for a response, or loop. Type your message, press Enter, and move on.

The ONLY time you read a target pane is:
- **Before** interacting with it (enforced by the read guard)
- **After typing** to verify your text landed before pressing Enter
- When interacting with a **non-agent pane** (plain shell, running process)

### Read Guard

The CLI enforces read-before-act. You cannot `type` or `keys` to a pane unless you have read it first.

1. `psmux-bridge read <target>` marks the pane as "read"
2. `psmux-bridge type/keys <target>` checks for that mark — errors if you haven't read
3. After a successful `type`/`keys`, the mark is cleared — you must read again before the next interaction

Read marks are stored in `$env:TEMP\winsmux\read_marks\`.

```
PS> psmux-bridge type codex "hello"
error: must read the pane before interacting. Run: psmux-bridge read codex
```

### Command Reference

| Command | Description | Example |
|---|---|---|
| `psmux-bridge list` | Show all panes with target, pid, command, size, label | `psmux-bridge list` |
| `psmux-bridge type <target> <text>` | Type text without pressing Enter | `psmux-bridge type codex "hello"` |
| `psmux-bridge message <target> <text>` | Type text with auto sender info and reply target | `psmux-bridge message codex "review src/auth.ts"` |
| `psmux-bridge read <target> [lines]` | Read last N lines (default 50) | `psmux-bridge read codex 100` |
| `psmux-bridge keys <target> <key>...` | Send special keys | `psmux-bridge keys codex Enter` |
| `psmux-bridge name <target> <label>` | Label a pane | `psmux-bridge name %3 codex` |
| `psmux-bridge resolve <label>` | Print pane target for a label | `psmux-bridge resolve codex` |
| `psmux-bridge id` | Print this pane's ID | `psmux-bridge id` |

### Target Resolution

Targets can be:
- **psmux native**: pane ID (`%3`), or window index (`0`)
- **label**: Any string set via `psmux-bridge name` — resolved automatically

Labels are stored in `$env:APPDATA\winsmux\labels.json`.

### Read-Act-Read Cycle

Every interaction follows **read → act → read**. The CLI enforces this.

**Sending a message to an agent:**
```powershell
psmux-bridge read codex 20                    # 1. READ — satisfy read guard
psmux-bridge message codex 'Please review src/auth.ts'
                                              # 2. MESSAGE — auto-prepends sender info, no Enter
psmux-bridge read codex 20                    # 3. READ — verify text landed
psmux-bridge keys codex Enter                 # 4. KEYS — submit
# STOP. Do NOT read codex for a reply. The agent replies into YOUR pane.
```

**Approving a prompt (non-agent pane):**
```powershell
psmux-bridge read worker 10                   # 1. READ — see the prompt
psmux-bridge type worker "y"                  # 2. TYPE
psmux-bridge read worker 10                   # 3. READ — verify
psmux-bridge keys worker Enter                # 4. KEYS — submit
psmux-bridge read worker 20                   # 5. READ — see the result
```

### Messaging Convention

The `message` command auto-prepends sender info and location:

```
[psmux-bridge from:claude pane:%4 at:s:w.p -- load the winsmux skill to reply]
```

The receiver gets: who sent it (`from`), the exact pane to reply to (`pane`), and the session/window location (`at`). When you see this header, reply using psmux-bridge to the pane ID from the header.

### Agent-to-Agent Workflow

```powershell
# 1. Label yourself
psmux-bridge name (psmux-bridge id) claude

# 2. Discover other panes
psmux-bridge list

# 3. Send a message (read-act-read)
psmux-bridge read codex 20
psmux-bridge message codex 'Please review the changes in src/auth.ts'
psmux-bridge read codex 20
psmux-bridge keys codex Enter
```

### Example Conversation

**Agent A (claude) sends:**
```powershell
psmux-bridge read codex 20
psmux-bridge message codex 'What is the test coverage for src/auth.ts?'
psmux-bridge read codex 20
psmux-bridge keys codex Enter
```

**Agent B (codex) sees in their prompt:**
```
[psmux-bridge from:claude pane:%4 at:s:w.p -- load the winsmux skill to reply] What is the test coverage for src/auth.ts?
```

**Agent B replies using the pane ID from the header:**
```powershell
psmux-bridge read %4 20
psmux-bridge message %4 '87% line coverage. Missing the OAuth refresh token path (lines 142-168).'
psmux-bridge read %4 20
psmux-bridge keys %4 Enter
```

---

## Raw psmux Commands

Use these when you need direct psmux control beyond what psmux-bridge provides — session management, window navigation, creating panes, or low-level scripting.

### Capture Output

```powershell
psmux capture-pane -t shared | Select-Object -Last 20    # Last 20 lines
psmux capture-pane -t shared                              # Entire scrollback
psmux capture-pane -t 'shared:0.0'                        # Specific pane
```

### Send Keys

```powershell
psmux send-keys -t shared -l "text here"     # Type text (literal mode)
psmux send-keys -t shared Enter              # Press Enter
psmux send-keys -t shared Escape             # Press Escape
psmux send-keys -t shared C-c                # Ctrl+C
psmux send-keys -t shared C-d               # Ctrl+D (EOF)
```

For interactive TUIs, split text and Enter into separate sends:
```powershell
psmux send-keys -t shared -l "Please apply the patch"
Start-Sleep -Milliseconds 100
psmux send-keys -t shared Enter
```

### Panes and Windows

```powershell
# Create panes (prefer over new windows)
psmux split-window -h -t SESSION              # Horizontal split
psmux split-window -v -t SESSION              # Vertical split
psmux select-layout -t SESSION tiled          # Re-balance

# Navigate
psmux select-window -t shared:0
psmux select-pane -t 'shared:0.1'
psmux list-windows -t shared
```

### Session Management

```powershell
psmux list-sessions
psmux new-session -d -s newsession
psmux kill-session -t sessionname
psmux rename-session -t old new
```

### Claude Code Patterns

```powershell
# Check if session needs input
psmux capture-pane -t worker-3 | Select-Object -Last 10 |
  Select-String -Pattern '❯|Yes.*No|proceed|permission'

# Approve a prompt
psmux send-keys -t worker-3 -l 'y'
psmux send-keys -t worker-3 Enter

# Check all sessions
foreach ($s in @('shared','worker-2','worker-3','worker-4')) {
    Write-Host "=== $s ==="
    psmux capture-pane -t $s 2>$null | Select-Object -Last 5
}
```

## Tips

- **Read guard is enforced** — you MUST read before every `type`/`keys`
- **Every action clears the read mark** — after `type`, read again before `keys`
- **Never wait or poll** — agent panes reply via psmux-bridge into YOUR pane
- **Label panes early** — easier than using `%N` IDs
- **`type` uses literal mode** — special characters are typed as-is
- **`read` defaults to 50 lines** — pass a higher number for more context
- **Non-agent panes** are the exception — you DO need to read them to see output
- **Labels** are stored in `$env:APPDATA\winsmux\labels.json` — persistent across sessions
- **Read marks** are stored in `$env:TEMP\winsmux\read_marks\` — cleared on reboot
- Use `capture-pane` to get output as strings (essential for scripting)
- Use **Alt** key combinations for psmux shortcuts (e.g., `Alt+1` to select window 1)
