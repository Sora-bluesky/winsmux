# Customization

Use customization to make winsmux fit your local operator workflow without turning it into a shared credential broker.

## Workspace lifecycle

`winsmux init` defaults to managed worker worktrees:

```powershell
winsmux init --workspace-lifecycle managed-worktree
```

Use managed worktrees when multiple agents may edit files in parallel. They keep changes separated until the operator chooses what to accept.

## Execution profiles

`execution-profile` describes the run policy lane. It is separate from
`worker-backend`, which describes where a worker slot is hosted, and from
`execution_backend`, which describes the provider capability runtime path.

The default is `local-windows`. It preserves the normal Windows managed-pane
behavior. `isolated-enterprise` is opt-in and should only be selected when the
operator explicitly wants the enterprise isolation lane. Later releases attach
the isolated workspace, credential, heartbeat, and Windows sandbox behavior to
that profile.

## Launcher presets

Inspect the presets before launching a compare-oriented run:

```powershell
winsmux launcher presets --json
winsmux launcher lifecycle --json
```

Presets describe the intended workspace shape. They should not execute arbitrary project setup or teardown scripts.

## Agent slots

winsmux uses slot and capability concepts rather than permanent vendor roles. A slot may advertise work, review, or consultation capability. The operator chooses which pane receives each task.

`winsmux init` creates six managed worker slots by default. When `agent-slots`
is present, that list is the source of truth and `worker_count` is derived from
the number of entries. The top-level `worker-backend` value defaults to `local`,
and each slot can override it with one of the contract values:

- `local`: current local managed pane behavior
- `codex`: Codex reviewer or worker metadata
- `colab_cli`: `google-colab-cli` worker state metadata
- `noop`: disabled or placeholder worker metadata

Starting in `v0.32.4`, winsmux records Colab backend availability under
`.winsmux/state/colab_sessions.json`. Missing `google-colab-cli`, missing auth,
and unavailable `H100` / `A100` GPUs are recorded as degraded worker state.
Renamed sessions are marked stale. winsmux does not silently fall back to a
local CPU or local LLM runtime for Colab model work.
Use `winsmux workers status`, `winsmux workers attach`, `winsmux workers start`,
`winsmux workers stop`, and `winsmux workers doctor` to inspect and control the
six configured worker slots.

Colab-backed slots also support file-backed one-shot execution and safe artifact
movement:

```powershell
winsmux workers exec w2 --script workers/colab/impl_worker.py --run-id demo-1 -- --task-json-inline '{"task_id":"demo-1","title":"Implement this change"}' --worker-id worker-2 --run-id demo-1
winsmux workers logs w2 --run-id <run_id>
winsmux workers upload w2 data/input.json --remote /content/input.json
winsmux workers upload w2 data --remote /content/data --allow-dir data
winsmux workers download w2 /content/output.json --output artifacts/worker-output
```

The tracked templates under `workers/colab/` are:

- `impl_worker.py`
- `critic_worker.py`
- `scout_worker.py`
- `test_worker.py`
- `heavy_judge_worker.py`

Each template accepts task JSON through `--task-json`, `--task-json-inline`, or
`WINSMUX_TASK_JSON`. It writes a role-specific artifact under
`/content/winsmux_artifacts/<worker_id>/<run_id>/` by default and prints a
structured JSON result. Pass the same `--run-id` after the script-argument
delimiter so remote artifacts stay aligned with the winsmux run metadata.
Invalid input exits non-zero and still returns `status: failed` with an `errors`
array.

Directory uploads require `--allow-dir`. The upload manifest excludes `.git`,
secret-like files, `node_modules`, virtual environments, build outputs,
coverage, and oversized files by default. Automatic `colab repl` or
`colab console` loops are intentionally out of scope; workers run one command at
a time through the configured `google-colab-cli`-compatible adapter.

Colab worker commands reject task input with secret-like values or prohibited
automation patterns before invoking the adapter. Stored adapter output and
`cli_arguments` metadata redact secret-like values, Google Drive paths, and
local absolute paths so review packets and release-gate evidence stay shareable.

Before handing a worker result to the Codex reviewer slot, use
`winsmux review-pack <run_id> --json`. The command writes a bounded packet under
`.winsmux/review-packs` with changed files, test results, critic objections,
remaining risks, commands, and artifact references. It excludes repository
dumps, long logs, secrets, binary artifacts, vendor directories, local absolute
paths, and full conversation history.

Example slot entries (excerpt; `winsmux init` creates six slots):

```yaml
external-operator: true
worker-backend: local
execution-profile: local-windows
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: provider-default
    model-source: provider-default
    worker-backend: codex
    execution-profile: local-windows
    worker-role: reviewer
    fallback-model: gpt-5.3-codex-spark
    pane-title: W1 Codex Reviewer
    worktree-mode: managed
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: colab_cli
    execution-profile: isolated-enterprise
    worker-role: impl
    session-name: "{{project_slug}}_w2_impl"
    gpu-preference: [H100, A100]
    packages: [torch, transformers, accelerate]
    bootstrap: workers/colab/bootstrap_impl.py
    task-script: workers/colab/impl_worker.py
    worktree-mode: managed
```

Use this model when assigning work:

- send implementation tasks to work-capable slots
- send review tasks to review-capable slots
- use consultation only for difficult, ambiguous, or non-converging work

## Credentials

Store credentials that must be injected into a pane with Windows DPAPI:

```powershell
winsmux vault set <name> <value>
winsmux vault inject <name> <pane>
```

winsmux does not broker OAuth flows, receive callback URLs, or share local interactive login tokens across panes.

## Desktop preferences

The desktop app follows the same operator contract as the CLI. It may expose theme, density, wrapping, code font, and focus preferences, but raw PTY output stays in the terminal drawer for diagnostics.

Use the desktop app for:

- scanning source-linked run evidence and decision gates
- comparing recorded work
- drilling into source-level context
- keeping terminal diagnostics available without making them the primary surface
