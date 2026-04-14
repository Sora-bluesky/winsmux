[English](README.md) | [日本語](README.ja.md)

<p align="center">
  <img src="docs/banner.png" alt="WINSMUX" width="600">
</p>

# winsmux

**winsmux is a Windows-native AI agent orchestration platform.**

It provides the runtime and coordination layer for running multiple agent CLIs in one operator-controlled workspace on Windows. Instead of locking teams into a single model vendor, winsmux combines pane-based execution, live supervision, and governance controls that fit real engineering workflows.

`v0.21.2` is the terminal-based final form release. It closes the pre-Tauri runtime shape around the Windows-native terminal surface, external operator model, managed worker panes, and evidence/review controls. `v0.22.0` begins the desktop control-plane handoff into the Tauri backend and frontend adapter layers.

## What winsmux does

- **Multi-vendor support**: run Codex, Claude, Gemini, and other CLI agents side by side in the same session
- **Real-time visibility**: supervise every agent through live `winsmux` panes instead of waiting for post-hoc summaries
- **Enterprise governance**: keep one external operator in control, isolate managed pane agents in git worktrees, and preserve an evidence trail for review and audit

```powershell
winsmux read worker-1 20
winsmux send worker-2 "Review the latest auth changes."
winsmux health-check
```

## Why teams use it

Most agent tooling is optimized for a single vendor and a single execution model. winsmux is designed for teams that need to coordinate multiple agents on Windows while keeping the system observable and governable.

- **Vendor-neutral orchestration**: mix Codex, Claude, Gemini, and future local models behind one operator control loop
- **Pane-native operations**: inspect, interrupt, redirect, and relabel live panes through `winsmux`
- **Controlled execution**: combine read-before-act interaction, review-capable worker gates, and isolated worker workspaces
- **Windows-first deployment**: no WSL2 dependency, no Linux detour, no hidden tmux requirement

## Platform model

```text
winsmux
├── winsmux CLI
├── Orchestra
├── Role Gates
├── Worker Worktree Isolation
├── Credential Vault (DPAPI)
└── Evidence Ledger
```

- **`winsmux`** handles pane targeting, messaging, health checks, vault injection, and operator controls
- **Orchestra** defaults to one external operator plus managed pane agents
- **Role gates** restrict which actions the operator and managed pane agents can perform
- **Worker worktree isolation** gives each managed worker pane a separate git worktree to reduce cross-agent collisions
- **Evidence Ledger** supports audit-oriented capture of agent activity and review outcomes

For the public operator/pane architecture, see [docs/operator-model.md](docs/operator-model.md).
The default operator is Claude Code, described in [`.claude/CLAUDE.md`](.claude/CLAUDE.md).
The pane-side runtime contracts in [`AGENT-BASE.md`](AGENT-BASE.md), [`AGENT.md`](AGENT.md), and [`GEMINI.md`](GEMINI.md) are dogfooding/runtime documents for managed agents, not the primary public operator guide.

## Core runtime

Under the orchestration layer, winsmux ships a Windows-native terminal multiplexer runtime written in Rust.

- **tmux-compatible runtime**: runs tmux-style commands, reads `~/.tmux.conf`, and supports existing tmux themes
- **Windows-native UX**: full mouse support, ConPTY-based panes, and no WSL/Cygwin/MSYS2 dependency
- **Multiple entrypoints**: the runtime is available as `winsmux`, `pmux`, and `tmux`
- **Automation-ready**: 76 tmux-compatible commands and 126+ format variables back the pane operations used by Orchestra and agent tooling

| Runtime docs | Description |
| ------- | ------- |
| [Features](core/docs/features.md) | Mouse support, copy mode, layouts, formats, and scripting surface |
| [Compatibility](core/docs/compatibility.md) | tmux compatibility matrix and command coverage |
| [Configuration](core/docs/configuration.md) | Config files, options, environment variables, and `.tmux.conf` support |
| [Key Bindings](core/docs/keybindings.md) | Default keyboard and mouse interactions |
| [Mouse over SSH](core/docs/mouse-ssh.md) | SSH mouse behavior and Windows version requirements |
| [Claude Code](core/docs/claude-code.md) | How teammate panes run on top of the runtime |

## Install

```powershell
irm https://raw.githubusercontent.com/Sora-bluesky/winsmux/main/install.ps1 | iex
```

The installer:

- installs the Rust runtime if `winsmux` is not already available
- installs the `winsmux` wrapper scripts into `~\.winsmux\bin`
- configures `.winsmux.conf`
- registers a **winsmux Orchestra** profile in Windows Terminal

If you only need the tmux-compatible runtime, you can also install it directly:

```powershell
winget install winsmux
cargo install winsmux
scoop bucket add winsmux https://github.com/winsmux/scoop-winsmux
scoop install winsmux
choco install winsmux
```

You can also download a release `.zip` from GitHub Releases or build from source in [`core/`](core).

## Quick start

```powershell
# Verify the environment
winsmux doctor

# Start a winsmux session
winsmux new-session -s orchestra

# Launch the default orchestra layout
pwsh winsmux-core/scripts/orchestra-start.ps1
```

If `winsmux doctor` reports the Windows worktree git sandbox limitation, keep using the managed pane for edits and tests, but run `git add`, `git commit`, and `git push` from a regular shell outside the sandboxed pane when `.git/worktrees/*/index.lock` cannot be created.

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for the Windows `ConstrainedLanguageMode` workaround details.

The default layout is now:

- external operator terminal outside the managed window
- 6 managed `worker-*` panes inside the orchestra window
- legacy `Commander / Builder / Researcher / Reviewer` pane layouts only when explicitly enabled for compatibility

This is the last release line where the terminal surface is the primary control plane. The next train (`v0.22.0`) keeps the terminal runtime, but hands primary desktop orchestration to the Tauri control plane.

Inside the session, label and inspect panes:

```powershell
winsmux list
winsmux read worker-1 30
winsmux send worker-3 "Summarize the upstream issue."
```

## Governance highlights

- **Role gates**: the external operator and managed pane agents do not get the same command surface
- **Read Guard**: panes must be read before interaction, reducing blind input into the wrong target
- **Worktree isolation**: each managed worker pane can run in its own git worktree branch and directory
- **Credential Vault**: secrets are stored with Windows DPAPI and injected into panes without writing repo `.env` files
- **Evidence Ledger**: prompts, actions, and review evidence can be captured for audit and compliance workflows

## Core commands

| Command | Purpose |
| ------- | ------- |
| `winsmux list` | Show panes, labels, and processes |
| `winsmux read <target> [lines]` | Read pane output before acting |
| `winsmux send <target> <text>` | Send text and press Enter |
| `winsmux health-check` | Report READY/BUSY/HUNG/DEAD for labeled panes |
| `winsmux vault set <key> [value]` | Store a credential in DPAPI-backed vault |
| `winsmux vault inject <pane>` | Inject stored credentials into a target pane |
| `winsmux update` | Update winsmux to the latest version |
| `winsmux uninstall` | Remove winsmux |

## Requirements

- Windows 10/11
- PowerShell 7+
- Windows Terminal recommended

## License

MIT
