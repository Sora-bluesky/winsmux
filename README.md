[English](README.md) | [日本語](README.ja.md)

<p align="center">
  <img src="docs/brand-hero.svg" alt="winsmux: One control desk for every AI coding agent on Windows" width="100%">
</p>

# winsmux

`winsmux` is **one control desk for every AI coding agent on Windows** — a single human-run cockpit for people who already run multiple coding CLIs and need to keep the work accountable.

Instead of hiding agents behind a black-box orchestrator, `winsmux` opens each worker in a real pane, keeps file changes isolated in git worktrees, lets you send or interrupt instructions, and compares completed runs with evidence such as changed-file overlap, review state, verification state, and checkpoints before you decide what to keep.

Use it when one Claude Code, Codex, Antigravity CLI, Grok Build, or legacy Gemini session is not enough, but you still want one human operator, local credentials, and a review trail.

For example: run the same task through two agents, watch both panes live, stop the one going off track, then compare the recorded evidence before accepting either result.

`winsmux` does not sign in to AI services for you. Each agent CLI keeps using its own official sign-in or API key setup.

## Why It Exists

Most tools solve only one part of this workflow.

- Terminal multiplexers show panes, but they do not know which agent changed which files.
- IDE chat surfaces are good for one conversation, but they do not give you a control plane for several official CLIs.
- Agent frameworks can automate agents, but they often move the work into code or cloud services instead of keeping a human operator in the loop.

`winsmux` sits between those categories: it keeps the official CLI agents visible, separates their work into independent working directories, records the evidence, and leaves the final choice with you.

## What It Does

- Starts a managed Windows Terminal workspace for multiple CLI agents.
- Lets an operator read, send, interrupt, and check pane health.
- Initializes six managed worker slots by default, with a worker backend
  contract for local, Codex, Antigravity, Grok Build, hosted API models via OpenRouter,
  Google Colab, and placeholder workers. The first generated slot is a Codex reviewer
  slot; the remaining slots keep the selected worker backend.
- Keeps worker agents in separate git worktrees when isolation is enabled.
- Compares recorded runs and highlights shared changed files before you choose a winner.
- Shows review, verification, architecture, checkpoint, and follow-up evidence for recorded runs.
- Captures structured end-of-run snapshots without storing raw terminal transcripts or private local paths.
- Searches recorded sessions in Agent Vault and restores a selected run by dragging it into a worker pane.
- Links Feed and notification state to worker panes, with a View menu toggle for the worker status strip.
- Stores selected credentials with Windows DPAPI instead of writing repository `.env` files.
- Records review and verification evidence for later audit.

## When To Use It

Use `winsmux` when you want to run more than one coding agent on a Windows PC and still keep a single operator in control.

It is especially useful when you want to:

- Compare work from different agents or providers.
- Keep each worker's file changes separated.
- See live pane output instead of waiting for a final summary.
- Require review evidence before accepting changes.
- Preserve enough structured context to resume or compare runs later.
- Avoid tying the workflow to one model vendor.

If you only need a terminal multiplexer, see the runtime docs under [`core/docs`](core/docs).

## Requirements

- Windows 10 or Windows 11
- PowerShell 7+
- Windows Terminal
- The official agent CLIs you want to run, such as Claude Code, Codex, Antigravity CLI, or Grok Build

Rust is only needed when you build the runtime from source.

## Get Started

For most users, start with the desktop app. Download `winsmux_<version>_x64-setup.exe` from the matching GitHub Release, run it, open the installed winsmux app, and choose the project folder you want agents to work in.

Use the npm package when you want a CLI-first, scripted, or headless setup. This path starts a managed Windows Terminal workspace; it does not open the desktop app.

```powershell
npm install -g winsmux
winsmux install --profile full
winsmux init
winsmux launch
```

See [Quickstart](docs/quickstart.md) for a guided first run.
See [Installation](docs/installation.md) for the recommended desktop installer path, CLI profiles, updates, and uninstall steps.
See [Customization](docs/customization.md) for launcher presets, worktree policy, slots, credentials, and desktop settings.
See [Public Distribution Boundary](docs/source-access.md) for the `v1.0.0` public distribution and redistribution boundary.
See [External control plane API](docs/external-control-plane.md) for the local named-pipe JSON-RPC contract used by external automation clients.

## Main Commands

```powershell
winsmux list
winsmux read worker-1 30
winsmux send worker-2 "Review the latest auth changes."
winsmux health-check
winsmux workers status
winsmux workers doctor
winsmux workers exec w1 --task-json tasks/api-worker-task.json --run-id api-demo-1 --json
winsmux workers exec w2 --script workers/colab/impl_worker.py --run-id demo-1 -- --task-json-inline '{"task_id":"demo-1","title":"Implement this change"}' --worker-id worker-2 --run-id demo-1
winsmux workers upload w2 data/input.json --remote /content/input.json
winsmux workers download w2 /content/output.json
winsmux workers sandbox baseline w2 --run-id demo-1 --json
winsmux workers broker baseline w2 --run-id demo-1 --endpoint https://broker.example.invalid/worker --json
winsmux workers broker token issue w2 --run-id demo-1 --ttl-seconds 900 --json
winsmux workers policy baseline w2 --run-id demo-1 --network broker-only --write workspace-artifacts --provider configured --json
winsmux review-pack <run_id> --json
winsmux compare runs <left_run_id> <right_run_id>
winsmux compare preflight <left_ref> <right_ref>
winsmux compare promote <run_id>
winsmux meta-plan --task "Plan this change" --json
winsmux meta-plan --task "Plan this change" --roles .winsmux/meta-plan-roles.yaml --review-rounds 2 --json
winsmux skills --json
```

| Command | Purpose |
| ------- | ------- |
| `winsmux init` | Create the default project config |
| `winsmux launch` | Run CLI checks and start the default managed Windows Terminal workspace; it does not open the desktop app |
| `winsmux launcher presets` | Show launcher presets and pair templates |
| `winsmux launcher lifecycle` | Choose the workspace lifecycle policy |
| `winsmux workers status` | Show backend, state, GPU, session, and last command for worker slots |
| `winsmux workers attach` | Prepare a Colab-backed worker slot for desktop visibility without starting an unbounded loop |
| `winsmux workers doctor` | Diagnose worker config, Colab CLI, auth, uv, and session-state paths |
| `winsmux workers exec` | Run Colab-backed tasks, hosted `api_llm` tasks, or Antigravity CLI one-shot workers; missing API key env vars stop before network access |
| `winsmux workers logs` | Read the stored log for a worker run, or ask the Colab CLI for it |
| `winsmux workers upload` | Upload explicit files or allowlisted directories while excluding unsafe paths |
| `winsmux workers download` | Download a remote artifact into a project-local output directory |
| `winsmux workers sandbox baseline` | Define the restricted-token and ACL baseline for a prepared isolated run |
| `winsmux workers broker baseline` | Define the single external broker node contract for a prepared isolated run |
| `winsmux workers broker token` | Issue or check short-lived broker run tokens without printing token values |
| `winsmux workers policy baseline` | Define enterprise execution policy outside prompts for a prepared isolated run |
| `winsmux review-pack` | Write a bounded reviewer packet with changed files, test results, risks, commands, and artifact refs |
| `winsmux compare runs` | Compare evidence and confidence between two recorded runs |
| `winsmux compare preflight` | Check two refs before merge or compare review |
| `winsmux compare promote` | Export a successful run as input for the next run |
| `winsmux meta-plan` | Draft a read-only multi-role planning packet before execution |
| `winsmux skills` | Print agent-readable command skill contracts |
| `winsmux read` | Read a pane before acting |
| `winsmux send` | Send text to a pane |
| `winsmux vault set` | Store a credential with Windows DPAPI |
| `winsmux vault inject` | Inject a stored credential into a target pane |

`winsmux conflict-preflight` remains available as a compatibility command behind `winsmux compare preflight`.

Legacy binary aliases `psmux`, `pmux`, and `tmux` are no longer shipped.
Use `winsmux` for scripts and docs. This does not remove tmux-compatible configuration, targets, or commands where documented.

## Authentication Support

| Tool | Authentication mode | winsmux support |
| ------- | ------- | ------- |
| Claude Code | API key or documented enterprise auth | Officially supported |
| Claude Code | Pro / Max OAuth | This PC only, interactive use |
| Codex | API key | Officially supported |
| Codex | ChatGPT OAuth | This PC only, interactive use |
| Antigravity CLI | Official Antigravity CLI sign-in | This PC only, interactive use |
| Grok Build | Grok Build headless (local) | This PC only, interactive use |
| OpenRouter (hosted models) | API key via `OPENROUTER_API_KEY` | Officially supported |
| Gemini | Gemini API key | Officially supported |
| Gemini | Gemini API in Vertex AI | Officially supported |
| Gemini | Google OAuth | Legacy / tier-limited, this PC only |

Google's published migration notice says Gemini CLI and Gemini Code Assist IDE extensions stopped serving requests for Gemini Code Assist for individuals, Google AI Pro, and Google AI Ultra on 2026-06-18. Affected users should use Antigravity CLI; Google AI Standard and Enterprise tiers are not treated as sunset by this winsmux policy.

See [Authentication Support](docs/authentication-support.md) for the full policy.
See [Provider and Model Support](docs/provider-and-model-support.md) for hosted, Colab, and future local LLM runtime policy.
See [CLI comparison bakeoff](docs/cli-comparison-bakeoff.md) for Claude Code, Codex, and Antigravity CLI evidence gates.
See [Google Colab Workers](docs/google-colab-workers.md) for the H100/A100 worker setup.

## Security Notes

- Use `winsmux read` to check the target pane output before sending instructions.
- Keep one human operator responsible for final accept or reject decisions.
- Keep the managed worktree lifecycle enabled when agents edit files in parallel.
- Do not paste API keys into pane chat or issue comments.
- Use `winsmux vault` for credentials that must be injected into a pane.
- Treat compare results and release evidence as review inputs, not automatic approval.

## Related Docs

- [Operator model](docs/operator-model.md)
- [Documentation overview](docs/README.md)
- [Quickstart](docs/quickstart.md)
- [Installation](docs/installation.md)
- [Customization](docs/customization.md)
- [Authentication support](docs/authentication-support.md)
- [Provider and model support](docs/provider-and-model-support.md)
- [CLI comparison bakeoff](docs/cli-comparison-bakeoff.md)
- [External control plane API](docs/external-control-plane.md)
- [Google Colab workers](docs/google-colab-workers.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Repository surface policy](docs/repo-surface-policy.md)
- [Runtime features](core/docs/features.md)
- [Runtime configuration](core/docs/configuration.md)
- [tmux compatibility](core/docs/compatibility.md)

Developer and contributor rules are intentionally kept out of this README. Start from [Repository surface policy](docs/repo-surface-policy.md) if you are changing the repository itself.

## License

Apache License 2.0.

Some runtime compatibility code keeps an upstream MIT notice under `core/LICENSE`.
See [Third-party notices](THIRD_PARTY_NOTICES.md) for the split.
