[English](README.md) | [日本語](README.ja.md)

<p align="center">
  <img src="docs/banner.png" alt="WINSMUX" width="600">
</p>

# winsmux

`winsmux` helps one human operator run and supervise several CLI agents on Windows.

You keep local control. `winsmux` starts the panes, lets you read what each agent is doing, sends instructions to the right pane, compares results, and keeps enough evidence for review.

`winsmux` does not sign in to AI services for you. Each agent CLI keeps using its own official sign-in or API key setup.

## What It Does

- Starts a managed Windows Terminal workspace for multiple CLI agents.
- Lets an operator read, send, interrupt, and check pane health.
- Keeps worker agents in separate git worktrees when isolation is enabled.
- Compares recorded runs and highlights shared changed files before you choose a winner.
- Stores selected credentials with Windows DPAPI instead of writing repository `.env` files.
- Records review and verification evidence for later audit.

## When To Use It

Use `winsmux` when you want to run more than one coding agent on a Windows PC and still keep a single operator in control.

It is especially useful when you want to:

- Compare work from different agents or providers.
- Keep each worker's file changes separated.
- See live pane output instead of waiting for a final summary.
- Require review evidence before accepting changes.
- Avoid tying the workflow to one model vendor.

If you only need a terminal multiplexer, see the runtime docs under [`core/docs`](core/docs).

## Requirements

- Windows 10 or Windows 11
- PowerShell 7+
- Windows Terminal
- The CLI agents you want to run, such as Codex CLI, Claude Code, or Gemini CLI

Rust is only needed when you build the runtime from source.

## Get Started

Install the current release from PowerShell:

```powershell
irm https://raw.githubusercontent.com/Sora-bluesky/winsmux/main/install.ps1 | iex
```

Then create project settings and start the default workspace:

```powershell
winsmux init
winsmux launch
```

Choose a workspace lifecycle policy when you want isolated worker directories:

```powershell
winsmux init --workspace-lifecycle managed-worktree
```

Inspect launcher presets before starting a compare-oriented run:

```powershell
winsmux launcher presets --json
```

`/winsmux-start` is only used to test this repository itself. Public usage should start from `winsmux init` and `winsmux launch`.

## Main Commands

```powershell
winsmux list
winsmux read worker-1 30
winsmux send worker-2 "Review the latest auth changes."
winsmux health-check
winsmux compare runs <left_run_id> <right_run_id>
winsmux compare preflight <left_ref> <right_ref>
winsmux compare promote <run_id>
```

| Command | Purpose |
| ------- | ------- |
| `winsmux init` | Create the default project config |
| `winsmux launch` | Run checks and start the default managed workspace |
| `winsmux launcher presets` | Show launcher presets and pair templates |
| `winsmux launcher lifecycle` | Choose the workspace lifecycle policy |
| `winsmux compare runs` | Compare evidence and confidence between two recorded runs |
| `winsmux compare preflight` | Check two refs before merge or compare review |
| `winsmux compare promote` | Export a successful run as input for the next run |
| `winsmux read` | Read a pane before acting |
| `winsmux send` | Send text to a pane |
| `winsmux vault set` | Store a credential with Windows DPAPI |
| `winsmux vault inject` | Inject a stored credential into a target pane |

`winsmux conflict-preflight` remains available as a compatibility command behind `winsmux compare preflight`.

## Authentication Support

| Tool | Authentication mode | winsmux support |
| ------- | ------- | ------- |
| Claude Code | API key or documented enterprise auth | Officially supported |
| Claude Code | Pro / Max OAuth | Unsupported |
| Codex CLI | API key | Officially supported |
| Codex CLI | ChatGPT OAuth | This PC only, interactive use |
| Gemini CLI | Gemini API key | Officially supported |
| Gemini CLI | Vertex AI | Officially supported |
| Gemini CLI | Google OAuth | Unsupported |

See [Authentication Support](docs/authentication-support.md) for the full policy.

## Security Notes

- Read a pane before sending instructions to it.
- Keep one human operator responsible for final accept or reject decisions.
- Use worker worktree isolation when agents edit files in parallel.
- Do not paste API keys into pane chat or issue comments.
- Use `winsmux vault` for credentials that must be injected into a pane.
- Treat compare results and release evidence as review inputs, not automatic approval.

## Related Docs

- [Operator model](docs/operator-model.md)
- [Authentication support](docs/authentication-support.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Repository surface policy](docs/repo-surface-policy.md)
- [Runtime features](core/docs/features.md)
- [Runtime configuration](core/docs/configuration.md)
- [tmux compatibility](core/docs/compatibility.md)

Developer and contributor rules are intentionally kept out of this README. Start from [Repository surface policy](docs/repo-surface-policy.md) if you are changing the repository itself.

## License

Apache License 2.0
