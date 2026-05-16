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
operator explicitly wants the enterprise isolation lane. The isolated
workspace, credential, heartbeat, Windows sandbox baseline, and brokered
execution baseline behavior are attached to that profile only; they are not
public defaults.

### Isolated workspaces

`isolated-enterprise` slots can prepare a disposable workspace for one run:

```powershell
winsmux workers workspace prepare w2 --include src --include docs/task.md --run-id run-123 --json
```

The command copies only the requested project-relative files or directories
into `.winsmux/isolated-workspaces/<slot>/<run>/workspace`. It also creates
separate `downloads` and `artifacts` directories for the run. Direct writes to
the project root are not part of the contract.

Projection paths are strict. winsmux rejects absolute path escapes, `..`
segments, reparse points such as symlinks or junctions, Windows reserved names,
runtime directories, dependency directories, build outputs, and secret-like
files. Directory projections must pass the same checks for every file inside
the directory before the workspace is created.

Remove the run workspace after collecting the required artifacts:

```powershell
winsmux workers workspace cleanup w2 --run-id run-123 --json
```

### Run-scoped secret projections

Use the same typed secret projection contract for `local-windows` and
`isolated-enterprise` worker runs. The command resolves Windows DPAPI vault
entries at run start and stores values only under the run's local secret
directory:

```powershell
winsmux workers secrets project w2 --run-id run-123 --env OPENAI_API_KEY=openai --file creds/token.txt=github --variable model_token=anthropic --json
```

Projection types are explicit:

- `--env <name=vault-key>` writes a PowerShell environment loader for that run.
- `--file <path=vault-key>` writes a run-local secret file.
- `--variable <name=vault-key>` writes a run-local variable map.

The JSON output and `secret-projection.json` manifest report only typed
locations, vault key names, scope, and value references. They do not include
secret values. Isolated runs must already have a prepared isolated workspace so
the secret directory stays under that run boundary and is removed by workspace
cleanup.

### Worker heartbeat and offline detection

Use `workers heartbeat` to report liveness for a local or isolated worker run:

```powershell
winsmux workers heartbeat mark w2 --run-id run-123 --state running --json
winsmux workers heartbeat check w2 --run-id run-123 --json
```

The shared heartbeat states are `running`, `blocked`, `approval_waiting`,
`child_wait`, `stalled`, `completed`, and `resumable`. `blocked` and
`approval_waiting` mean the worker needs operator attention. `child_wait` means
the worker is waiting for a nested child run and must not be treated as a
stopped process. A recent `running` heartbeat is healthy, an old heartbeat
becomes `stalled` after the grace period, and an expired heartbeat becomes
`offline`.

Heartbeat artifacts are stored as `heartbeat.json` under the run boundary:

- `.winsmux/worker-runs/<slot>/<run>/heartbeat.json` for `local-windows`
- `.winsmux/isolated-workspaces/<slot>/<run>/heartbeat.json` for `isolated-enterprise`

`winsmux workers status --json` includes the same `heartbeat`,
`heartbeat_health`, and `heartbeat_state` fields that the desktop app uses, so
CLI and Tauri surfaces share one worker liveness contract.

### Windows sandbox baseline

`isolated-enterprise` runs can define a Windows native sandbox baseline after
the isolated workspace exists:

```powershell
winsmux workers sandbox baseline w2 --run-id run-123 --json
```

The baseline combines two contracts for the run:

- a `restricted_token` process-launch requirement for any worker process that
  later executes inside the run
- a `run_acl_boundary` file boundary rooted at
  `.winsmux/isolated-workspaces/<slot>/<run>`

The command fails closed unless the slot uses `isolated-enterprise`, the run
workspace has already been prepared, the required run directories exist, and no
reparse point is present under the run boundary. It writes
`sandbox-baseline.json` under the isolated run directory and reports only
project-relative artifact references.

This is a baseline contract, not a claim that an already running worker is
securely isolated. The JSON output sets `isolation_claim.secure` to `false`
until the worker launch path enforces the restricted token and ACL boundary.
Do not use `local-windows` runs for this lane.

### Brokered execution baseline

`isolated-enterprise` runs can also define the first brokered execution
contract after the isolated workspace exists:

```powershell
winsmux workers broker baseline w2 --run-id run-123 --endpoint https://broker.example.invalid/worker --json
```

The baseline records one external broker node for the prepared run. It does not
start a process, open a network connection, or turn winsmux into a credential
broker. Endpoint URLs must use `http` or `https` and must not include embedded
credentials.

The command fails closed unless the slot uses `isolated-enterprise`, the run
workspace has already been prepared, the required run directories exist, the
endpoint is safe to record, and no reparse point is present under the run
boundary. It writes `broker-baseline.json` under the isolated run directory and
reports only project-relative artifact references. `winsmux workers status
--json` includes the latest broker contract in each worker row as `broker`.

After the broker baseline exists, issue a short-lived run token for the brokered
agent:

```powershell
winsmux workers broker token issue w2 --run-id run-123 --ttl-seconds 900 --json
winsmux workers broker token check w2 --run-id run-123 --json
```

The token value is stored only as `secrets/broker-run-token.txt` inside the
isolated run boundary. JSON output and `broker-token.json` report only the
token reference, fingerprint, issue time, and expiry time. A token check rotates
an expired token by default. If refresh is disabled or cannot complete, the run
is marked `offline` through the same heartbeat surface used by
`winsmux workers heartbeat`.

### Enterprise execution policy

After the broker baseline and a valid broker token exist, define the execution
policy that sits outside prompts:

```powershell
winsmux workers policy baseline w2 --run-id run-123 --network broker-only --write workspace-artifacts --provider configured --json
```

The policy controls network availability, write permissions, provider
availability, mandatory checks, and role-specific evidence for the prepared
`isolated-enterprise` run. It writes `execution-policy.json` under the run
directory and projects the latest policy through `winsmux workers status
--json` as `policy`.

The command fails closed unless the slot uses `isolated-enterprise`, the run
workspace exists, the broker baseline exists, and the broker token is valid and
unexpired. It also rejects invalid policy values and run-boundary reparse
points before writing the policy manifest. Operators can read the stop reason
from the command error and from the latest status projection after a successful
policy write.

### Desktop run-state visibility

The desktop worker status surface consumes the same `winsmux workers status
--json` contract as automation. Each worker row reports `execution_profile`,
`workspace`, `secret_projection`, `heartbeat`, `broker`, and `policy`. The
desktop pill bar reduces those fields to `exec:local`, `exec:isolated`, or
`exec:offline`, while the focused detail strip shows the workspace, secret
projection, policy health, heartbeat, and recovery action. Credential refresh
waits are shown as a recovery action without exposing secret values.

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

For run-scoped workers, prefer `winsmux workers secrets project` so credentials
are bound to one slot and one run instead of being injected broadly into a pane
session.

winsmux does not broker OAuth flows, receive callback URLs, or share local interactive login tokens across panes.

## Desktop preferences

The desktop app follows the same operator contract as the CLI. It may expose theme, density, wrapping, code font, and focus preferences, but raw PTY output stays in the terminal drawer for diagnostics.

Use the desktop app for:

- scanning source-linked run evidence and decision gates
- comparing recorded work
- drilling into source-level context
- keeping terminal diagnostics available without making them the primary surface
