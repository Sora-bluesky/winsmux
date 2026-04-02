[English](README.md) | [日本語](README.ja.md)

<p align="center">
  <img src="docs/banner.png" alt="WINSMUX" width="600">
</p>

# winsmux

**winsmux is a Windows-native AI agent orchestration platform.**

It provides the runtime and coordination layer for running multiple agent CLIs in one operator-controlled workspace on Windows. Instead of locking teams into a single model vendor, winsmux combines pane-based execution, live supervision, and governance controls that fit real engineering workflows.

## What winsmux does

- **Multi-vendor support**: run Codex, Claude, Gemini, and other CLI agents side by side in the same session
- **Real-time visibility**: supervise every agent through live `psmux` panes instead of waiting for post-hoc summaries
- **Enterprise governance**: enforce role gates, isolate Builder work in git worktrees, and preserve an evidence trail for review and audit

```powershell
psmux-bridge read builder-1 20
psmux-bridge send reviewer "Review the latest auth changes."
psmux-bridge health-check
```

## Why teams use it

Most agent tooling is optimized for a single vendor and a single execution model. winsmux is designed for teams that need to coordinate multiple agents on Windows while keeping the system observable and governable.

- **Vendor-neutral orchestration**: mix Codex for implementation, Claude for review, and Gemini for research in one session
- **Pane-native operations**: inspect, interrupt, redirect, and relabel live panes through `psmux`
- **Controlled execution**: combine read-before-act interaction, role-aware command gates, and isolated Builder workspaces
- **Windows-first deployment**: no WSL2 dependency, no Linux detour, no hidden tmux requirement

## Platform model

```text
winsmux
├── psmux-bridge CLI
├── Orchestra
├── Role Gates
├── Builder Worktree Isolation
├── Credential Vault (DPAPI)
└── Evidence Ledger
```

- **`psmux-bridge`** handles pane targeting, messaging, health checks, vault injection, and operator controls
- **Orchestra** coordinates Commander, Builder, Researcher, and Reviewer panes
- **Role gates** restrict which actions each role can perform
- **Builder worktree isolation** gives each Builder pane a separate git worktree to reduce cross-agent collisions
- **Evidence Ledger** supports audit-oriented capture of agent activity and review outcomes

## Install

```powershell
irm https://raw.githubusercontent.com/Sora-bluesky/winsmux/main/install.ps1 | iex
```

The installer:

- installs the `sora-psmux` fork if `psmux` is not already available
- installs `psmux-bridge` and `winsmux` command wrappers into `~\.winsmux\bin`
- configures `.psmux.conf`
- registers a **winsmux Orchestra** profile in Windows Terminal

## Quick start

```powershell
# Verify the environment
psmux-bridge doctor

# Start a psmux session
psmux new-session -s orchestra

# Launch the default orchestra layout
pwsh psmux-bridge/scripts/orchestra-start.ps1
```

Inside the session, label and inspect panes:

```powershell
psmux-bridge list
psmux-bridge read builder-1 30
psmux-bridge send researcher "Summarize the upstream issue."
```

## Governance highlights

- **Role gates**: builders, researchers, reviewers, and commanders do not all get the same command surface
- **Read Guard**: panes must be read before interaction, reducing blind input into the wrong target
- **Worktree isolation**: each Builder pane can run in its own git worktree branch and directory
- **Credential Vault**: secrets are stored with Windows DPAPI and injected into panes without writing repo `.env` files
- **Evidence Ledger**: prompts, actions, and review evidence can be captured for audit and compliance workflows

## Core commands

| Command | Purpose |
| ------- | ------- |
| `psmux-bridge list` | Show panes, labels, and processes |
| `psmux-bridge read <target> [lines]` | Read pane output before acting |
| `psmux-bridge send <target> <text>` | Send text and press Enter |
| `psmux-bridge health-check` | Report READY/BUSY/HUNG/DEAD for labeled panes |
| `psmux-bridge vault set <key> [value]` | Store a credential in DPAPI-backed vault |
| `psmux-bridge vault inject <pane>` | Inject stored credentials into a target pane |
| `winsmux update` | Update winsmux to the latest version |
| `winsmux uninstall` | Remove winsmux |

## Requirements

- Windows 10/11
- PowerShell 7+
- Windows Terminal recommended

## License

MIT
