# psmux-bridge reference

> Version: 0.9.0

psmux-bridge is a PowerShell CLI that wraps psmux (tmux-compatible multiplexer) with label resolution, Read Guard safety, and inter-agent messaging.

## Commands

### id

Show the current pane ID.

```powershell
psmux-bridge id
```

If `$env:TMUX_PANE` is set, returns it directly. Otherwise queries psmux for the active pane ID.

**Output:**

```
%0
```

---

### list

List all panes with their ID, PID, current command, dimensions, title, child process, and label.

```powershell
psmux-bridge list
```

For each pane, the command also detects the first child process (via `Win32_Process` parent PID lookup) and appends it in parentheses. If a label is assigned, it is appended in brackets.

**Output format:**

```
%0 12345 pwsh 120x30 pane %0 (claude.exe) [claude]
%1 67890 pwsh 120x30 pane %1
```

Fields: `pane_id pane_pid pane_current_command pane_widthxpane_height pane_title (child_process) [label]`

---

### read

Capture recent output from a pane. Sets the Read Guard mark for that pane.

```powershell
psmux-bridge read <target> [lines]
```

| Parameter | Required | Default | Description                   |
| --------- | -------- | ------- | ----------------------------- |
| `target`  | Yes      | --      | Pane ID, label, or coordinate |
| `lines`   | No       | `50`    | Number of lines to capture    |

**Examples:**

```powershell
psmux-bridge read %1           # Last 50 lines from pane %1
psmux-bridge read %1 100       # Last 100 lines from pane %1
psmux-bridge read claude       # Read from pane labeled "claude"
```

Uses `psmux capture-pane -t <paneId> -p -J -S -<lines>` internally.

---

### type

Send literal text to a pane. Requires Read Guard.

```powershell
psmux-bridge type <target> <text>
```

| Parameter | Required | Description                                               |
| --------- | -------- | --------------------------------------------------------- |
| `target`  | Yes      | Pane ID, label, or coordinate                             |
| `text`    | Yes      | Literal text to send (all remaining args joined by space) |

**Examples:**

```powershell
psmux-bridge type %1 echo hello world
psmux-bridge type claude ls -la
```

Uses `psmux send-keys -t <paneId> -l -- "<text>"` internally. The `-l` flag sends the text literally (no key name interpretation). Clears the Read Guard mark after sending.

---

### keys

Send key sequences (named keys) to a pane. Requires Read Guard.

```powershell
psmux-bridge keys <target> <key>...
```

| Parameter | Required | Description                                        |
| --------- | -------- | -------------------------------------------------- |
| `target`  | Yes      | Pane ID, label, or coordinate                      |
| `key`     | Yes      | One or more key names (e.g. `Enter`, `C-c`, `Tab`) |

**Examples:**

```powershell
psmux-bridge keys %1 Enter                  # Press Enter
psmux-bridge keys %1 C-c                    # Send Ctrl+C
psmux-bridge keys %1 C-c Enter              # Ctrl+C then Enter
psmux-bridge keys claude Up Up Enter         # Arrow up twice, then Enter
```

Each key argument is sent as a separate `psmux send-keys` call (without `-l`, so key names are interpreted). Clears the Read Guard mark after sending.

---

### message

Send a tagged inter-agent message to a pane. Requires Read Guard.

```powershell
psmux-bridge message <target> <text>
```

| Parameter | Required | Description                                       |
| --------- | -------- | ------------------------------------------------- |
| `target`  | Yes      | Pane ID, label, or coordinate                     |
| `text`    | Yes      | Message body (all remaining args joined by space) |

**Examples:**

```powershell
psmux-bridge message %2 please run the tests
psmux-bridge message claude check the build output
```

The message is prefixed with a structured header:

```
[psmux-bridge from:<agent_name> pane:<my_pane_id> at:<session>:<window>.<pane> -- load the winsmux skill to reply] <text>
```

- `agent_name` is taken from `$env:WINSMUX_AGENT_NAME` (defaults to `"unknown"`)
- `my_pane_id` and coordinates are resolved from the sender's current pane

Clears the Read Guard mark after sending.

---

### name

Assign a label to a pane. Also sets the pane title (best-effort).

```powershell
psmux-bridge name <target> <label>
```

| Parameter | Required | Description                         |
| --------- | -------- | ----------------------------------- |
| `target`  | Yes      | Pane ID or coordinate to label      |
| `label`   | Yes      | Label string (first extra arg only) |

**Examples:**

```powershell
psmux-bridge name %0 claude
psmux-bridge name %1 codex
```

**Output:**

```
Labeled pane %0 as 'claude'
```

Labels are persisted to `labels.json`. Also calls `psmux select-pane -t <paneId> -T "<label>"` to set the pane title (errors are silently ignored).

---

### resolve

Resolve a label to its pane ID.

```powershell
psmux-bridge resolve <label>
```

| Parameter | Required | Description      |
| --------- | -------- | ---------------- |
| `label`   | Yes      | Label to look up |

**Examples:**

```powershell
psmux-bridge resolve claude    # Output: %0
psmux-bridge resolve codex     # Output: %1
```

Exits with error if the label is not found.

---

### send

Send text to a pane and auto-press Enter in one step. Unlike `message`, no header is prepended (headers break TUI agents like Claude Code). After sending, a watermark is saved for change detection in subsequent `read` calls.

```powershell
psmux-bridge send <target> <text>
```

| Parameter | Required | Description                                       |
| --------- | -------- | ------------------------------------------------- |
| `target`  | Yes      | Pane ID, label, or coordinate                     |
| `text`    | Yes      | Text to send (all remaining args joined by space) |

**Examples:**

```powershell
psmux-bridge send codex "review src/auth.ts"
psmux-bridge send builder implement rate limiting
```

Does NOT require Read Guard (sets the mark after sending). This is the **recommended** way to send a task to another agent.

**Output:**

```
sent to %1
```

---

### focus

Switch pane focus to the specified target.

```powershell
psmux-bridge focus <target>
```

| Parameter | Required | Description                   |
| --------- | -------- | ----------------------------- |
| `target`  | Yes      | Pane ID, label, or coordinate |

**Examples:**

```powershell
psmux-bridge focus codex
psmux-bridge focus %2
```

**Output:**

```
Focused pane %2 (codex)
```

---

### ime-input

Open a GUI input dialog (Windows Forms) for IME text entry and send the result to a pane. Requires Read Guard.

```powershell
psmux-bridge ime-input <target>
```

| Parameter | Required | Description                   |
| --------- | -------- | ----------------------------- |
| `target`  | Yes      | Pane ID, label, or coordinate |

Useful for entering Japanese/CJK text that cannot be typed via `send-keys`. If the dialog is cancelled, outputs `cancelled` and no text is sent.

---

### image-paste

Save the clipboard image to a temp file and send the file path to a pane. Requires Read Guard.

```powershell
psmux-bridge image-paste <target>
```

| Parameter | Required | Description                   |
| --------- | -------- | ----------------------------- |
| `target`  | Yes      | Pane ID, label, or coordinate |

The image is saved as `$env:TEMP\winsmux\images\<timestamp>.png`. Errors if no image is in the clipboard.

**Output:**

```
image saved: C:\Users\...\winsmux\images\20260331_120000.png
path sent to %1
```

---

### clipboard-paste

Paste clipboard text content to a pane. Requires Read Guard.

```powershell
psmux-bridge clipboard-paste <target>
```

| Parameter | Required | Description                   |
| --------- | -------- | ----------------------------- |
| `target`  | Yes      | Pane ID, label, or coordinate |

Errors if the clipboard is empty.

---

### vault set

Store a credential securely using Windows Credential Manager (DPAPI backend).

```powershell
psmux-bridge vault set <key> [value]
```

| Parameter | Required | Description                                                |
| --------- | -------- | ---------------------------------------------------------- |
| `key`     | Yes      | Credential name (stored as `winsmux:<key>`)                |
| `value`   | No       | Value to store. If omitted, prompts securely via Read-Host |

**Examples:**

```powershell
psmux-bridge vault set OPENAI_API_KEY sk-...
psmux-bridge vault set SECRET_TOKEN              # interactive secure input
```

**Output:**

```
Stored credential: OPENAI_API_KEY
```

---

### vault get

Retrieve a stored credential by key.

```powershell
psmux-bridge vault get <key>
```

| Parameter | Required | Description     |
| --------- | -------- | --------------- |
| `key`     | Yes      | Credential name |

Outputs the credential value to stdout. Errors if the key is not found.

---

### vault list

List all stored credential keys (with `winsmux:` prefix removed).

```powershell
psmux-bridge vault list
```

**Output:**

```
OPENAI_API_KEY
SECRET_TOKEN
```

Or `(no credentials stored)` if empty.

---

### vault inject

Inject all stored credentials as environment variables (`$env:NAME = 'value'`) into a target pane. Requires Read Guard.

```powershell
psmux-bridge vault inject <pane>
```

| Parameter | Required | Description                   |
| --------- | -------- | ----------------------------- |
| `pane`    | Yes      | Pane ID, label, or coordinate |

**Examples:**

```powershell
psmux-bridge vault inject builder
```

For each credential, sends `$env:KEY = 'value'` + Enter to the target pane with 100ms intervals. Single quotes in values are escaped (`'` → `''`).

**Output:**

```
injected 3 credentials into %2
```

---

### profile

Show or register a Windows Terminal dropdown profile via the Fragments extension point.

```powershell
psmux-bridge profile [name] [agents...]
```

| Parameter | Required | Description                                              |
| --------- | -------- | -------------------------------------------------------- |
| `name`    | No       | Profile name. If omitted, shows current fragment JSON    |
| `agents`  | No       | Agent definitions (e.g. `builder:codex reviewer:claude`) |

**Examples:**

```powershell
psmux-bridge profile                                    # Show current fragment
psmux-bridge profile mysetup builder:codex reviewer:claude
```

The fragment is written to `$env:LOCALAPPDATA\Microsoft\Windows Terminal\Fragments\winsmux\winsmux.json`. The generated profile launches `psmux-bridge doctor`, creates a psmux session, and starts the orchestra script.

**Output:**

```
Registered WT profile: winsmux mysetup
Fragment: C:\Users\...\Fragments\winsmux\winsmux.json
Agents: builder:codex, reviewer:claude
```

---

### doctor

Run environment diagnostics.

```powershell
psmux-bridge doctor
```

**Output example:**

```
=== psmux-bridge doctor ===
psmux: psmux 0.5.0
TMUX_PANE: %0
WINSMUX_AGENT_NAME: claude
Panes: 3
Labels: 2 in %APPDATA%\winsmux\labels.json
Read marks: 1 in %TEMP%\winsmux\read_marks
```

Checks performed:

- psmux installation and version
- `TMUX_PANE` environment variable
- `WINSMUX_AGENT_NAME` environment variable
- Total pane count
- Label count and file path
- Read mark count and directory path

---

### version

Show the bridge version.

```powershell
psmux-bridge version
```

**Output:**

```
psmux-bridge 1.0.0
```

---

### wait

Block until a signal is received on the named channel. Used for instant completion detection instead of polling.

```powershell
psmux-bridge wait <channel> [timeout_seconds]
```

| Parameter         | Required | Default | Description                          |
| ----------------- | -------- | ------- | ------------------------------------ |
| `channel`         | Yes      | --      | Signal channel name (any string)     |
| `timeout_seconds` | No       | `120`   | Seconds to wait before timeout error |

**Examples:**

```powershell
psmux-bridge wait builder-1-done          # Wait up to 120s
psmux-bridge wait builder-1-done 60       # Wait up to 60s
```

Uses file-based signaling (`$env:TEMP\winsmux\signals\`). Polls at 100ms intervals for <200ms latency. If the signal file already exists when `wait` is called, it returns immediately.

**On timeout:**

```
error: timeout waiting for signal: builder-1-done (120s)
```

---

### signal

Send a signal to unblock a waiting process on the named channel.

```powershell
psmux-bridge signal <channel>
```

| Parameter | Required | Description                      |
| --------- | -------- | -------------------------------- |
| `channel` | Yes      | Signal channel name (any string) |

**Examples:**

```powershell
psmux-bridge signal builder-1-done        # Unblock whoever is waiting
```

Creates a signal file in `$env:TEMP\winsmux\signals\` with a timestamp. The corresponding `wait` command detects the file and returns.

**Output:**

```
sent signal: builder-1-done
```

---

### watch

Monitor a pane and block until its output is silent for a specified duration. Useful for detecting completion of agents that cannot send signals.

```powershell
psmux-bridge watch <label> [silence_seconds] [timeout_seconds]
```

| Parameter         | Required | Default | Description                               |
| ----------------- | -------- | ------- | ----------------------------------------- |
| `label`           | Yes      | --      | Pane label or ID to monitor               |
| `silence_seconds` | No       | `10`    | Seconds of no output to consider "silent" |
| `timeout_seconds` | No       | `120`   | Overall timeout before giving up          |

**Examples:**

```powershell
psmux-bridge watch builder-1              # 10s silence, 120s timeout
psmux-bridge watch builder-1 15           # 15s silence, 120s timeout
psmux-bridge watch builder-1 10 60        # 10s silence, 60s timeout
```

Internally captures the pane output every 1 second and compares SHA256 hashes. When the hash remains unchanged for `silence_seconds` consecutive checks, the command returns.

**On success:**

```
silence detected: builder-1 (no output for 10s)
```

**On timeout:**

```
error: timeout watching builder-1 (120s, needed 10s silence)
```

Note: Silence detection is not the same as completion detection. An agent waiting for approval input is also silent. After `watch` returns, read the pane to confirm the agent's state.

---

## Environment Variables

| Variable             | Description                                                                                                              |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `WINSMUX_AGENT_NAME` | Agent name used in `message` command headers. Defaults to `"unknown"` if not set.                                        |
| `TMUX_PANE`          | Current pane ID. If set, `id` command returns this value directly without querying psmux. Set by psmux on pane creation. |

## File Locations

| Path                                                                     | Purpose                                                                             |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| `$env:APPDATA\winsmux\labels.json`                                       | Pane label-to-ID mappings (JSON object). Created on first `name` command.           |
| `$env:TEMP\winsmux\read_marks\`                                          | Read Guard state files. One empty file per pane (with `%` and `:` replaced by `_`). |
| `$env:TEMP\winsmux\signals\`                                             | Signal files for wait/signal coordination. One file per channel.                    |
| `$env:TEMP\winsmux\images\`                                              | Clipboard images saved by `image-paste` command.                                    |
| `$env:LOCALAPPDATA\Microsoft\Windows Terminal\Fragments\winsmux\`        | Windows Terminal Fragment JSON for dropdown profile registration.                   |

## Read Guard

Read Guard is a safety mechanism that prevents blind interaction with panes. It enforces a **read-before-write** discipline:

1. **`read`** sets a mark file in `$env:TEMP\winsmux\read_marks\` for the target pane.
2. **`type`**, **`keys`**, and **`message`** require the mark to exist (via `Assert-ReadMark`). If the mark is missing, the command fails with:
   ```
   error: must read the pane before interacting. Run: psmux-bridge read <paneId>
   ```
3. After a successful write operation (`type`, `keys`, `message`), the mark is **cleared**, requiring another `read` before the next interaction.

This ensures agents always observe the current pane state before sending input, preventing stale-state mistakes.

**Mark file naming:** The pane ID has `%` and `:` characters replaced with `_` to form a safe filename (e.g., `%0` becomes `_0`).

## Target Resolution

The `<target>` parameter in commands supports 4 formats, resolved in order:

| Format          | Example    | Description                                                                        |
| --------------- | ---------- | ---------------------------------------------------------------------------------- |
| **Label**       | `claude`   | Looked up in `labels.json`. If a matching key exists, its value (pane ID) is used. |
| **Pane ID**     | `%0`       | Direct psmux pane identifier.                                                      |
| **Coordinate**  | `main:0.1` | psmux target format: `session:window.pane`.                                        |
| **Window.Pane** | `0.1`      | Short coordinate within the current session.                                       |

Resolution flow:

1. Check if the target string is a key in `labels.json` (via `Resolve-Target`).
2. If found, substitute with the mapped pane ID.
3. If not found, pass the string through as-is (assumed to be a pane ID or coordinate).
4. Validate the resolved target by calling `psmux display-message -t <target> -p '#{pane_id}'` (via `Confirm-Target`). If this fails, exit with `"invalid target"` error.
