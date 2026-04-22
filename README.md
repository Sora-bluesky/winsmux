[English](README.md) | [日本語](README.ja.md)

<p align="center">
  <img src="docs/banner.png" alt="WINSMUX" width="600">
</p>

# winsmux

**winsmux is a Windows-native operating platform for safely running multiple CLI agents under one operator.**

It provides the runtime and coordination layer for running multiple agent CLIs in one operator-controlled workspace on Windows. Instead of locking teams into a single model vendor, winsmux combines pane-based execution, compare-oriented review surfaces, live supervision, and governance controls that fit real engineering workflows.

`v0.21.2` is the terminal-first final-form release before the desktop handoff. `v0.22.0` begins the Tauri desktop handoff, and `v0.24.0` starts the Rust contract-alignment lane for the future desktop/backend shape.

## What winsmux does

- **Multi-vendor support**: run Codex, Claude, Gemini, and other CLI agents side by side in the same session
- **Real-time visibility**: supervise every agent through live `winsmux` panes instead of waiting for post-hoc summaries
- **Enterprise governance**: keep one external operator in control, isolate managed pane agents in git worktrees, and preserve an evidence trail for review and audit

```powershell
winsmux read worker-1 20
winsmux send worker-2 "Review the latest auth changes."
winsmux health-check
```

## Authentication support

winsmux is a platform for safely operating multiple CLI agents. For that reason, winsmux does **not** act as an OAuth login broker, and support is defined by **authentication mode**, not only by tool name.

| Tool | Authentication mode | winsmux support level |
| ------- | ------- | ------- |
| Claude Code | API key / documented enterprise auth | Supported |
| Claude Code | Pro / Max OAuth | Unsupported |
| Codex CLI | API key | Supported |
| Codex CLI | ChatGPT OAuth | This PC only, interactive use |
| Gemini CLI | Gemini API key | Supported |
| Gemini CLI | Vertex AI | Supported |
| Gemini CLI | Google OAuth | Unsupported |

### Terms

- **Supported**  
  This authentication mode is part of the standard winsmux workflow. It can be used for launch, compare, and multi-agent operation.

- **This PC only, interactive use**  
  The CLI itself may complete its own official login flow on that same PC, and winsmux may then launch or observe that already-authenticated local CLI. winsmux does not complete the login on its behalf, extract the token, or share that authenticated state with other panes or users.

- **Unsupported**  
  winsmux does not present this authentication mode as part of its standard workflow. It is stopped during preflight checks instead of being treated as a normal launch path.

Even when a CLI supports a given authentication mode, that does not automatically mean winsmux formally supports that mode.

See [docs/authentication-support.md](docs/authentication-support.md) for the detailed policy.

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
Contributor/runtime contracts for repository-operated panes remain in repository contributor docs and are not part of the primary public product guide.

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

### Available today

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

### Planned installation paths

- `winsmux init` and `winsmux launch` are now the public first-run entrypoints
- `winsmux conflict-preflight` is now the public coordination guard before compare UI lands
- `winsmux compare` remains a planned public-first entrypoint
- npm-based installation is planned
- the public npm install surface will be a **single `winsmux` package**
- the planned public command is `npm install -g winsmux`
- the planned npm contract is **Windows only**
- the planned npm commands are `winsmux install`, `winsmux update`, `winsmux uninstall`, `winsmux version`, and `winsmux help`
- the npm package version is expected to pin `install.ps1` to the same GitHub release tag
- npm publish will remain blocked until the staged package passes Windows verification and the tag-driven release workflow is enabled
- current internal packages such as `winsmux-mcp` and the private `winsmux-app` build are **not** the public npm install contract
- the npm package name `winsmux` is already reserved, but repository-driven npm release remains gated until the public installer contract is ready

The planned installer profile names are:

| Profile | Contents |
| ------- | ------- |
| `core` | runtime binary, wrapper scripts, `PATH` setup, and base config |
| `orchestra` | `core` plus orchestration scripts and the Windows Terminal profile |
| `security` | `core` plus vault, redaction, and audit-oriented scripts |
| `full` | `core`, `orchestra`, and `security` contents |

The future npm command will keep one package name and pass the profile to the
bundled installer:

```powershell
winsmux install --profile full
```

If `winsmux update` does not receive a new profile, it keeps the previously
recorded profile from `~\.winsmux\install-profile`.
The installer enforces this scope, so `core` does not install orchestration
scripts, vault support, or the Windows Terminal profile.
When a later install or update switches profiles, support scripts that no longer
belong to the selected profile are removed.

## Quick start

The current public quick start uses `winsmux init` and `winsmux launch`. `winsmux compare` remains planned, while `/winsmux-start` remains a Claude Code dogfooding-only flow.

```powershell
# Create the default first-run config
winsmux init

# Run checks and start the default orchestra layout
winsmux launch
```

`winsmux init` writes the default `.winsmux.yaml` for the current project.
`winsmux launch` then folds the old `doctor -> orchestra-start` flow into one public entrypoint.
Before the compare surface lands, `winsmux conflict-preflight <left_ref> <right_ref>` is the public CLI guard for merge-risk checks.

If `winsmux doctor` reports the Windows worktree git sandbox limitation, keep using the managed pane for edits and tests, but run `git add`, `git commit`, and `git push` from a regular shell outside the sandboxed pane when `.git/worktrees/*/index.lock` cannot be created.

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for the Windows `ConstrainedLanguageMode` workaround details.

The default layout is now:

- external operator terminal outside the managed window
- 6 managed `worker-*` panes inside the orchestra window
- legacy `Operator / Builder / Researcher / Reviewer` pane layouts only when explicitly enabled for compatibility

This is the last release line where the terminal surface is the primary operator surface. The next train (`v0.22.0`) keeps the terminal runtime, but shifts primary desktop orchestration toward the Tauri desktop shell.

The desktop roadmap is currently organized around these planned UX layers:

- **Decision Cockpit**: compare runs, inspect evidence, browse code, and review localhost previews
- **Fast Start + Launcher + Coordination Guard**: shorten first-run setup, launch multi-agent work quickly, and surface conflict risk before merge
- **Managed Team Intelligence**: durable run memory, follow-up playbooks, and diversity-aware team strategies

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
- **Evidence-first verification**: representative tool output such as `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`, and `cargo audit` should be handled as reusable review evidence instead of prompt-only commentary
- **Operator-owned final judgement**: review-capable panes may report findings and evidence, but the final accept/reject decision stays with the external operator

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

Apache License 2.0
