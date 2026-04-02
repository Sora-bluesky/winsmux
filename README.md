[English](README.md) | [日本語](README.ja.md)

<p align="center">
  <img src="docs/banner.png" alt="WINSMUX" width="600">
</p>

# winsmux

**winsmux is the runtime and orchestration layer that Claude Code provides, minus the model lock-in.**

winsmux is a multi-vendor agent orchestration platform for Windows. It gives you a Windows-native runtime for running Claude, Codex, Gemini, and your own CLI agents side by side, with live pane-level visibility, enforced read-before-act control, and enterprise-grade governance.

- **Multi-vendor orchestration**: run Claude, Codex, and Gemini simultaneously in one coordinated workspace
- **Visual real-time orchestration**: supervise agents through live `psmux` panes with `Read Guard` enforcing observe-before-act
- **Enterprise-grade security governance**: combine Shield Harness, Credential Vault, and Evidence Ledger patterns for controlled, auditable execution

```powershell
psmux-bridge read codex 20                    # inspect the pane state
psmux-bridge type codex "review src/auth.ts" # type into it
psmux-bridge keys codex Enter                # press Enter
```

## Why winsmux

Most agent tooling gives you one vendor's runtime with one vendor's operating model. winsmux gives you the runtime and orchestration layer itself:

- **Windows-native**: no WSL2, no Linux detour, no hidden tmux dependency
- **Vendor-neutral**: Claude Code, Codex CLI, Gemini CLI, and custom shell-based agents can share the same workflow
- **Operator-visible**: every agent runs in a real pane you can read, inspect, interrupt, and redirect in real time
- **Governable**: safety hooks, read-before-act controls, DPAPI-backed secret handling, and audit-oriented workflows fit enterprise teams

## Platform Architecture

```text
winsmux (platform)
├── psmux-bridge CLI
├── Shield Harness (22 hooks)
├── Orchestra (Commander/Builder/Reviewer)
├── Credential Vault (DPAPI)
└── MCP Server (planned)
```

- **`psmux-bridge` CLI**: pane targeting, pane I/O, signaling, health checks, and operator controls
- **Shield Harness**: policy hooks and guarded approval-free execution
- **Orchestra**: Commander/Builder/Reviewer coordination across multiple agents
- **Credential Vault**: machine-local secret storage and pane injection via Windows DPAPI
- **MCP Server (planned)**: expose winsmux as a vendor-neutral orchestration substrate for external agent runtimes

## Competitive Positioning

| Product | Core position | Vendor model | Orchestration model | Visual supervision | Governance posture |
| ------- | ------------- | ------------ | ------------------- | ------------------ | ------------------ |
| **winsmux** | Multi-vendor orchestration platform for Windows | Claude + Codex + Gemini + custom CLIs | Pane-native Commander/Builder/Reviewer orchestration | Live `psmux` panes + `Read Guard` | Shield Harness + Evidence Ledger + DPAPI vault |
| **Codex App** | OpenAI-native coding surface | OpenAI-centric | OpenAI agent workflows | App-level task UI | OpenAI-native controls |
| **Claude Code** | Anthropic-native terminal coding runtime | Anthropic-centric | Strong single-vendor terminal workflow | Terminal-native, but not a Windows pane orchestration platform | Anthropic-native controls |

winsmux is not trying to replace model-specific coding tools. It sits underneath them as the Windows runtime, coordination fabric, and governance layer when you need multiple vendors to work together in one operator-controlled environment.

## Install

```powershell
irm https://raw.githubusercontent.com/Sora-bluesky/winsmux/main/install.ps1 | iex
```

This installs:

- **psmux** if not already installed (via winget, scoop, cargo, or chocolatey)
- **psmux-bridge** CLI for cross-pane agent communication
- **.psmux.conf** with Alt-key bindings, mouse support, and pane labels
- **Windows Terminal Fragment** — adds a "winsmux Orchestra" profile to the WT dropdown menu

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

A CLI for cross-pane communication on Windows. Any tool that can run shell commands can use it: Claude Code, Codex, Gemini CLI, or a plain PowerShell script.

| Command                                 | Description                                    |
| --------------------------------------- | ---------------------------------------------- |
| `psmux-bridge list`                     | Show all panes with target, process, label     |
| `psmux-bridge read <target> [lines]`    | Read last N lines from a pane (default 50)     |
| `psmux-bridge type <target> <text>`     | Type text into a pane (no Enter)               |
| `psmux-bridge keys <target> <key>...`   | Send keys (Enter, Escape, C-c, etc.)           |
| `psmux-bridge message <target> <text>`  | Send tagged message with sender info           |
| `psmux-bridge name <target> <label>`    | Label a pane for easy addressing               |
| `psmux-bridge resolve <label>`          | Look up a pane by label                        |
| `psmux-bridge id`                       | Print this pane's ID                           |
| `psmux-bridge ime-input <target>`       | Open GUI dialog for Japanese IME input         |
| `psmux-bridge image-paste <target>`     | Save clipboard image and send path to pane     |
| `psmux-bridge clipboard-paste <target>` | Send clipboard text to pane                    |
| `psmux-bridge send <target> <text>`     | Send text and press Enter (recommended)        |
| `psmux-bridge focus <label\|target>`    | Switch active pane (from outside psmux)        |
| `psmux-bridge wait <channel> [timeout]` | Block until signal received (replaces polling) |
| `psmux-bridge signal <channel>`         | Send signal to unblock a waiting process       |
| `psmux-bridge watch <label> [sil] [to]` | Block until pane output is silent              |
| `psmux-bridge vault set <key> [value]`  | Store a credential securely (DPAPI)            |
| `psmux-bridge vault get <key>`          | Retrieve a stored credential                   |
| `psmux-bridge vault inject <pane>`      | Inject all credentials as env vars into a pane |
| `psmux-bridge vault list`               | List stored credential keys                    |
| `psmux-bridge profile [name] [agents]`  | Show or register WT dropdown profile           |
| `psmux-bridge wait-ready <target> [to]` | Wait for agent idle prompt (default 30s)       |
| `psmux-bridge health-check`             | Report READY/BUSY/HUNG/DEAD for labeled panes  |
| `psmux-bridge doctor`                   | Check environment and IME diagnostics          |
| `psmux-bridge version`                  | Show version                                   |

### Read Guard

`Read Guard` is the core operator safety rule behind winsmux's visual orchestration model. You cannot `type` or `keys` to a pane unless you have read it first. After each `type` or `keys`, the mark clears and you must read again.

```powershell
psmux-bridge type codex "hello"
# error: must read the pane before interacting. Run: psmux-bridge read codex
```

This prevents agents from blindly typing into the wrong pane and gives human operators a clear inspection point before every action.

### Targeting

Panes can be addressed by:

- **Pane ID** — `%3`, `%5` (psmux native IDs)
- **Label** — any name set via `psmux-bridge name`

Labels are resolved automatically in every command. Stored in `$env:APPDATA\winsmux\labels.json`.

### Pane Border Labels

In v0.9.5, winsmux supports two psmux features for visible pane labels:

- `pane-border-format` controls the text rendered in each pane border
- `pane-border-status` enables that border text and places it at the `top` or `bottom`

Use `#{pane_title}` inside `pane-border-format` to show the pane label. That title can be set directly with `select-pane -T` or through `psmux-bridge name`.

Example config:

```tmux
set -g pane-border-status top
set -g pane-border-format " #{pane_index} #{pane_title} "

# Either command below will set the label shown in the border.
select-pane -T claude
psmux-bridge name %2 codex
```

## Security Governance

winsmux is designed for environments where agent execution has to be observable, controllable, and defensible.

- **Shield Harness (22 hooks)** adds policy enforcement around approval-free execution paths
- **Read Guard** forces read-before-act interactions on every pane
- **Credential Vault** stores secrets with Windows DPAPI and injects them into target panes without writing `.env` files into the repo
- **Evidence Ledger** is the governance pattern for capturing prompts, approvals, outputs, and review evidence around agent work

### Credential Vault

Store secrets securely and inject them into agent panes with no `.env` files in your repo.

```powershell
# Store credentials (DPAPI-encrypted, Windows Credential Manager)
psmux-bridge vault set OPENAI_API_KEY sk-...
psmux-bridge vault set ANTHROPIC_API_KEY sk-ant-...

# Inject all credentials into a builder pane as $env: variables
psmux-bridge read builder 10
psmux-bridge vault inject builder
```

Credentials are stored per-machine using Windows DPAPI. `vault inject` sends `$env:KEY = 'value'` commands into the target pane, so the agent process gets them as environment variables without ever touching disk.

## Windows Terminal Integration

The installer registers a **winsmux Orchestra** profile in the Windows Terminal dropdown via [Fragments](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions). One click launches `psmux-bridge doctor`, creates a psmux session, and starts the Orchestra script.

Create custom profiles:

```powershell
psmux-bridge profile mysetup builder:codex reviewer:claude
```

## Orchestra

Orchestra is winsmux's role-based coordination layer. One Commander manages multiple AI agents in parallel while builders and reviewers run in visible `psmux` panes. You tell the Commander what to build; Orchestra splits the work, tracks progress, routes finished work to review, and checks for conflicts before committing.

### What the Commander does for you

1. **Splits work** — Assigns independent file sets to each builder so they do not step on each other
2. **Polls progress** — Cycles `psmux-bridge read` across all agents to detect completion
3. **Reviews incrementally** — Sends completed work to the reviewer as each builder finishes instead of waiting for the whole batch
4. **Detects conflicts** — Runs `git diff --name-only` before merging to catch overlapping changes
5. **Commits safely** — Only after review passes and no conflicts

### Multi-vendor support

Mix different CLI agents in the same Orchestra. The script auto-detects each CLI and handles their differences:

| CLI | Approval-free flag (with `-ShieldHarness`) |
| --- | ------------------------------------------ |
| Claude Code | `--permission-mode bypassPermissions` |
| Codex CLI | `--full-auto` |
| Gemini CLI | `--yolo` |

Without `-ShieldHarness`, no approval-free flags are added.

### Quick start

```powershell
# 1. Open a terminal and start psmux
psmux

# 2. From another terminal, set up the Orchestra
pwsh scripts/start-orchestra.ps1 -ProjectDir C:\path\to\project

# 3. Launch the Commander (in yet another terminal)
cd C:\path\to\project
claude --model claude-opus-4-6 --append-system-prompt-file .commander-prompt.txt
```

### Scaling up (for example, 4 builders + researcher + reviewer)

```powershell
pwsh scripts/start-orchestra.ps1 -ProjectDir C:\my\project -Rows 2 -Cols 3 -Agents @(
  @{label="builder-1"; command="codex"},
  @{label="builder-2"; command="codex"},
  @{label="builder-3"; command="gemini --model gemini-3.1-pro-preview"},
  @{label="researcher"; command="claude --model sonnet"},
  @{label="builder-4"; command="gemini --model gemini-3-flash-preview"},
  @{label="reviewer"; command="codex"}
) -ShieldHarness
```

```text
┌──────────┬──────────┬──────────┐
│builder-1 │builder-2 │builder-3 │
├──────────┼──────────┼──────────┤
│researcher│builder-4 │reviewer  │
└──────────┴──────────┴──────────┘
```

The `.commander-prompt.txt` is auto-generated with actual pane IDs, agent labels, and the coordination protocol so the Commander always knows exactly who to talk to.

| Parameter | Default | Description |
| --------- | ------- | ----------- |
| `-ProjectDir` | Current directory | Working directory for all panes |
| `-Rows` | 2 | Grid rows |
| `-Cols` | 2 | Grid columns |
| `-Agents` | 4-pane default | Array of `@{label; command}` maps |
| `-ShieldHarness` | Off | Enable approval-free mode with [Shield Harness](https://github.com/Sora-bluesky/shield-harness) |

See [SKILL.md](skills/winsmux/SKILL.md) for the full Commander workflow. Management protocols such as pipeline operation, researcher recon, reviewer batching, and agent selection are bundled as skill references and loaded on demand by agents.

## AI Agent Skills

Install the winsmux skill to teach your agents how to use `psmux-bridge`:

```powershell
npx skills add Sora-bluesky/winsmux
```

The skill includes:

- Core `psmux-bridge` usage ([SKILL.md](skills/winsmux/SKILL.md))
- Orchestra management protocol ([references/orchestra-management.md](skills/winsmux/references/orchestra-management.md))
- Agent selection guide ([references/agent-selection.md](skills/winsmux/references/agent-selection.md))

Works with Claude Code, Codex, Cursor, Copilot, and [other agents](https://skills.sh).

### Orchestra Layout Skill

For Claude Code users, the `orchestra-layout` skill creates deterministic `psmux` grid layouts in one command, eliminating manual split-window trial and error:

```bash
bash .claude/skills/orchestra-layout/scripts/orchestra-layout.sh 4b1r1v
# Creates 2x3 grid: 4 builders + 1 researcher + 1 reviewer
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
- PowerShell 7+ (`pwsh`)
- [psmux](https://github.com/psmux/psmux) (installed automatically)

## Acknowledgments

winsmux is the Windows-native counterpart of [smux](https://github.com/ShawnPana/smux) by [@ShawnPana](https://github.com/ShawnPana). smux provides the same terminal multiplexer and AI agent communication workflow for macOS and Linux using tmux. winsmux brings that experience to Windows natively via psmux, without requiring WSL2.

Terminal banner powered by [oh-my-logo](https://github.com/shinshin86/oh-my-logo) (MIT AND CC0-1.0).

## License

MIT
