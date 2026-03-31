---
name: winsmux
description: |
  Cross-pane AI agent communication on Windows via psmux-bridge CLI.
  Use when the user mentions pane control, cross-pane communication,
  sending messages to other agents, reading other panes, managing
  psmux sessions, or multi-agent orchestration on Windows.
  Triggered by "psmux-bridge", "cross-pane", "pane communication",
  "winsmux", "agent orchestration", "multi-pane", "commander workflow",
  or "pane read/type/keys".
  Key capabilities: read-guard-enforced pane I/O, labeled pane targeting,
  structured inter-agent messaging, commander orchestration workflow
  with builder/reviewer/monitor roles, POLL loop with auto-approve,
  and dangerous-command protection.
metadata:
  author: Sora-bluesky
  version: "0.9.0"
  os: win32
  requires: psmux, psmux-bridge
---

# winsmux

Cross-pane AI agent communication on Windows. Use `psmux-bridge` for all pane interactions.

## Communication Modes

Identify the mode **before** communicating with a pane.

| Mode               | Condition                                                 | Rule                                                                  |
| ------------------ | --------------------------------------------------------- | --------------------------------------------------------------------- |
| **Agent Mode**     | Peer has winsmux skill (Claude Code, skill-enabled Codex) | DO NOT POLL. Reply arrives in YOUR pane via `[psmux-bridge from:...]` |
| **Non-Agent Mode** | Codex CLI (no skill), plain shell, dev server             | POLL REQUIRED. You must `read` periodically to check status           |

**Agent Mode** -- send your message, press Enter, and move on. The reply appears directly in your pane. Do not sleep, poll, or loop.

**Non-Agent Mode** -- after sending a task, enter the POLL loop (see Commander Orchestration below). Read the target pane at intervals to detect completion, approval prompts, or errors.

The ONLY reasons to read a target pane in Agent Mode:

- **Before** interacting (enforced by Read Guard)
- **After typing** to verify text landed before pressing Enter

## Core Commands

| Command                                 | Description                                                   | Example                                           |
| --------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------- |
| `psmux-bridge list`                     | Show all panes with target, pid, command, size, label         | `psmux-bridge list`                               |
| `psmux-bridge read <target> [lines]`    | Read last N lines (default 50), sets Read Guard mark          | `psmux-bridge read codex 100`                     |
| `psmux-bridge type <target> <text>`     | Type literal text (no Enter), requires Read Guard             | `psmux-bridge type codex "hello"`                 |
| `psmux-bridge send <target> <text>`     | **Recommended.** Send tagged message + auto Enter in one step | `psmux-bridge send codex "review src/auth.ts"`    |
| `psmux-bridge message <target> <text>`  | Type text with sender header (no Enter -- use `send` instead) | `psmux-bridge message codex "review src/auth.ts"` |
| `psmux-bridge keys <target> <key>...`   | Send special keys, requires Read Guard                        | `psmux-bridge keys codex Enter`                   |
| `psmux-bridge name <target> <label>`    | Label a pane                                                  | `psmux-bridge name %3 codex`                      |
| `psmux-bridge resolve <label>`          | Print pane ID for a label                                     | `psmux-bridge resolve codex`                      |
| `psmux-bridge id`                       | Print this pane's ID                                          | `psmux-bridge id`                                 |
| `psmux-bridge wait <channel> [timeout]` | Block until signal received (default 120s timeout)            | `psmux-bridge wait builder-1-done 60`             |
| `psmux-bridge signal <channel>`         | Send signal to unblock a waiting process                      | `psmux-bridge signal builder-1-done`              |
| `psmux-bridge watch <label> [sil] [to]` | Block until pane output is silent (default 10s silence)       | `psmux-bridge watch builder-1 10 120`             |
| `psmux-bridge doctor`                   | Run environment diagnostics                                   | `psmux-bridge doctor`                             |

For full parameter details, see [psmux-bridge CLI Reference](references/psmux-bridge.md).

## Read Guard

The CLI enforces **read-before-act**. You cannot `type`, `keys`, or `message` to a pane unless you have read it first.

1. `psmux-bridge read <target>` -- sets the mark
2. `psmux-bridge type/keys/message <target>` -- checks the mark; errors if missing
3. After a successful write, the mark is **cleared** -- you must read again before the next interaction

If you skip the read:

```
PS> psmux-bridge type codex "hello"
error: must read the pane before interacting. Run: psmux-bridge read codex
```

## Read-Act-Read Cycle

Every interaction follows **read -> act -> read**.

**Sending a message to an agent (Agent Mode):**

```powershell
psmux-bridge read codex 20                    # 1. READ -- satisfy Read Guard
psmux-bridge message codex "Please review src/auth.ts"
                                              # 2. MESSAGE -- auto-prepends sender info
psmux-bridge read codex 20                    # 3. READ -- verify text landed
psmux-bridge keys codex Enter                 # 4. KEYS -- submit
# STOP. Do NOT poll. The agent replies into YOUR pane.
```

**Approving a prompt (Non-Agent pane):**

```powershell
psmux-bridge read worker 10                   # 1. READ -- see the prompt
psmux-bridge type worker "y"                  # 2. TYPE
psmux-bridge read worker 10                   # 3. READ -- verify
psmux-bridge keys worker Enter                # 4. KEYS -- submit
psmux-bridge read worker 20                   # 5. READ -- see the result
```

## Message Protocol

The `message` command auto-prepends a structured header:

```
[psmux-bridge from:claude pane:%4 at:s:w.p -- load the winsmux skill to reply]
```

Fields: who sent it (`from`), reply-to pane (`pane`), session/window/pane coordinates (`at`).

When you receive this header, reply using `psmux-bridge message` to the pane ID from the header.

## Commander Orchestration

When you are the **commander** orchestrating builder/reviewer/researcher/monitor panes, load the management protocol:

- [Orchestra Management Protocol](references/orchestra-management.md) -- roles, workflow cycle, pipeline operation, multi-builder coordination, POLL/auto-approve, researcher/reviewer protocols, prohibitions
- [Agent Selection Guide](references/agent-selection.md) -- which CLI to assign for each task type, approval-free flags, known limitations

**Key rules (read the full protocol for details):**

1. **Never write code yourself** -- delegate to builders
2. **Never skip reconnaissance** -- send researcher before builders
3. **Never let agents idle** -- pipeline operation, assign next task within 10 seconds
4. **Never skip POLL** -- always poll after BUILD and REVIEW
5. **Split by file boundary** -- each builder gets explicit, non-overlapping files

## Examples

### Example 1: Agent-to-Agent Communication

```powershell
# Label yourself
psmux-bridge name (psmux-bridge id) claude

# Discover panes
psmux-bridge list

# Send a message (Read-Act-Read)
psmux-bridge read codex 20
psmux-bridge message codex "What is the test coverage for src/auth.ts?"
psmux-bridge read codex 20
psmux-bridge keys codex Enter
# STOP -- reply arrives in your pane (Agent Mode)
```

The receiving agent sees:

```
[psmux-bridge from:claude pane:%4 at:s:w.p -- load the winsmux skill to reply] What is the test coverage for src/auth.ts?
```

And replies:

```powershell
psmux-bridge read %4 20
psmux-bridge message %4 "87% line coverage. Missing OAuth refresh path (lines 142-168)."
psmux-bridge read %4 20
psmux-bridge keys %4 Enter
```

### Example 2: Commander Orchestration Cycle

```powershell
# 1. PLAN -- decide task
# "Implement rate limiting middleware"

# 2. BUILD -- instruct builder
psmux-bridge read builder 20
psmux-bridge message builder "Implement rate limiting middleware in src/middleware/rate-limit.ts. Use sliding window, 100 req/min per IP."
psmux-bridge read builder 20
psmux-bridge keys builder Enter

# 3. POLL -- wait for builder (10s intervals, max 12 rounds)
Start-Sleep 10
psmux-bridge read builder 20
# ... repeat until completion detected ...

# 4. REVIEW -- send to reviewer
psmux-bridge read reviewer 20
psmux-bridge message reviewer "Review uncommitted changes via git diff HEAD. Focus: security, performance, tests."
psmux-bridge read reviewer 20
psmux-bridge keys reviewer Enter

# 5. POLL -- wait for reviewer
Start-Sleep 10
psmux-bridge read reviewer 50
# ... repeat until completion detected ...

# 6. JUDGE -- LGTM received
# 7. COMMIT
git add src/middleware/rate-limit.ts
git commit -m "feat: add rate limiting middleware"

# 8. NEXT -- proceed to next task
```

## Troubleshooting

| Problem                                        | Cause                                   | Solution                                                                   |
| ---------------------------------------------- | --------------------------------------- | -------------------------------------------------------------------------- |
| `error: must read the pane before interacting` | Read Guard not satisfied                | Run `psmux-bridge read <target>` first                                     |
| `invalid target`                               | Label not found or pane ID wrong        | Run `psmux-bridge list` to verify panes; re-label with `psmux-bridge name` |
| `psmux: command not found`                     | psmux not installed or not in PATH      | Install psmux; verify with `psmux -V`                                      |
| Message sent but no reply (Agent Mode)         | Peer does not have winsmux skill loaded | Switch to Non-Agent Mode with POLL                                         |
| POLL times out after 120 seconds               | Builder/reviewer stuck or errored       | Read last 20 lines, report state to user                                   |
| Auto-approve triggered on dangerous command    | Pattern not caught                      | Add pattern to dangerous-command list; report to user                      |
| `psmux-bridge doctor` shows warnings           | Environment misconfigured               | Fix reported issues (TMUX_PANE, WINSMUX_AGENT_NAME, etc.)                  |

## References

- [psmux-bridge CLI Reference](references/psmux-bridge.md) -- full command parameters, environment variables, file locations, target resolution details
- [Orchestra Management Protocol](references/orchestra-management.md) -- roles, workflow, pipeline operation, multi-builder coordination, POLL patterns
- [Agent Selection Guide](references/agent-selection.md) -- CLI-to-task mapping, approval-free flags, known limitations
