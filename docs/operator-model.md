# Operator Model

winsmux is built around a **two-layer orchestration model**:

- an **external operator layer**
- a **managed pane execution layer**

This separation is the main contract of the product. winsmux is positioned as a Windows-native, local-first multi-agent control plane rather than an editor-first IDE shell.

## 1. Standard control chain

The standard winsmux operating model is:

`User -> external operator -> managed pane agents`

That model means:

- the user communicates with the operator
- the operator coordinates work
- pane agents execute work
- pane agents do not communicate directly with the user
- pane agents do not communicate directly with each other

## 2. Operator layer

The operator layer is where:

- user communication
- dispatch
- approval
- review interpretation
- prioritization
- escalation
- final judgement

happen.

The operator can be Claude Code, Codex, Gemini, or another external
user-to-operator channel surface. When a product runs as an official agent CLI,
the CLI detail is described in the authentication or runtime column rather than
being appended to only some product names.

The important abstraction is the **channel boundary**, not Telegram, Discord, or another single product.

In the standard winsmux operating model, the operator is responsible for:

- decomposition
- delegation
- result collection
- context alignment
- review decisions
- git lifecycle judgement

Direct file mutation or command execution by the operator is outside the standard winsmux operating model.

## 2a. Verification and evidence contract

winsmux treats verification as evidence, not as freeform approval prose.

That means:

- a review-capable slot should return findings, blocking state, and evidence references
- representative tool output should stay attributable to the tool that produced it
- the operator should make the final accept / reject judgement after reading that evidence

For Rust-oriented work, the representative evidence set currently includes:

- `cargo fmt --check`
- `cargo clippy -- -D warnings`
- `cargo test`
- `cargo audit`

winsmux may learn from public harness structures, checklists, and policy shapes.
It does not treat a generic persona prompt as a public product capability.
The durable public contract is slot capability, evidence shape, and operator-owned final judgement.

## 2b. Run context and recovery contracts

Recent winsmux releases treat run context as structured data rather than a copied chat transcript.

The public contract is:

- each run may carry a structured handoff package for the next pane or follow-up run
- checkpoint packages record changed-file summaries, review state, verification state, and public worktree references
- end-of-run snapshots record what can be safely resumed without storing raw terminal transcripts, private local paths, or private prompt bodies
- context budgets describe why a pane received a bounded context packet instead of the full conversation
- architecture contracts record drift score, baseline status, review requirement, and whether a gate should stop
- managed follow-up contracts describe the next run candidate after a compare or promote decision
- diversity policy records describe model or slot tradeoffs without exposing private provider routing details

These contracts are designed for local-first operation. They make later review, comparison, and recovery possible while keeping the operator responsible for the final decision.

## 3. Pane execution layer

The managed pane layer is where agent CLIs run inside winsmux-controlled panes or slots.

Examples:

- Codex
- Gemini
- Claude Code when explicitly assigned to a pane
- future local or hosted LLM CLIs

Panes may differ by:

- provider
- model
- worker backend
- review capability
- worktree assignment
- runtime role

The current direction is **slot/capability-based orchestration**, not hard-coded vendor roles.

The worker backend is a slot-level contract that says how a worker will
eventually be hosted. The current public values are:

- `local`
- `codex`
- `colab_cli`
- `noop`

`local` preserves the existing managed pane behavior. `colab_cli` now records a
worker state layer for `google-colab-cli` detection, session reuse metadata,
stale-session marking, GPU fallback, and degraded-state reporting. The
`winsmux workers` commands report, start, stop, diagnose, run one-shot
file-backed jobs, read logs, and move artifacts for the six configured worker
slots. `codex` and `noop` remain contract metadata until their later
release lanes add execution behavior. A standard initialized project keeps six
managed worker slots, and `agent-slots` remains the source of truth when
present.

The execution profile is a separate run-policy contract. `local-windows` is the
default profile and preserves the normal managed-pane behavior. The
`isolated-enterprise` profile is explicit opt-in; it does not change a slot into
a different worker backend by itself. Backend selection, provider capability,
and run policy stay separate so role or playbook intent is not mixed with the
execution substrate.

Worker liveness is a shared CLI and desktop contract. `winsmux workers
heartbeat mark` writes a run-scoped `heartbeat.json`, and `winsmux workers
heartbeat check` evaluates it as `running`, `blocked`, `approval_waiting`,
`child_wait`, `stalled`, `offline`, `completed`, or `resumable`. The state model
separates child-run waiting and approval waiting from genuine process stops.
`winsmux workers status --json` projects the latest heartbeat into each worker
row through `heartbeat`, `heartbeat_health`, and `heartbeat_state`, which is the
same contract consumed by the Tauri worker status surface.

The Windows sandbox baseline is also attached only to `isolated-enterprise`.
`winsmux workers sandbox baseline` defines the restricted-token launch
requirement and the run-scoped ACL boundary for a prepared isolated run. It
fails closed for local profiles, missing run directories, path escapes, and
reparse points. The baseline manifest deliberately keeps
`isolation_claim.secure=false` until the worker launch path actually enforces
the restricted token and ACL boundary.

The brokered execution baseline is also explicit opt-in. `winsmux workers
broker baseline` records one external broker node for a prepared
`isolated-enterprise` run. It keeps the broker contract separate from OAuth and
token brokering, does not start an external process, and projects the latest
broker state through `winsmux workers status --json`.

Brokered agents use a run-scoped short-lived token after the baseline exists.
`winsmux workers broker token issue` stores the token value only under the
isolated run secret directory, and `winsmux workers broker token check` reports
or refreshes expiry without printing the token. If the token is expired and
cannot be refreshed, the run moves to `offline` through the worker heartbeat
surface.

Enterprise execution policy is the next boundary after the broker baseline and
token. `winsmux workers policy baseline` records network availability, write
permissions, provider availability, mandatory checks, and role-specific
evidence for the prepared `isolated-enterprise` run. It fails closed before
execution when the broker baseline or valid token is missing, when a policy
value is invalid, or when the run boundary contains a reparse point. The latest
policy is projected through `winsmux workers status --json` as `policy` so the
operator surface can show the enforced controls and stop reason without reading
the prompt.

Desktop worker status uses the same `winsmux workers status --json` contract.
Rows expose the execution profile, workspace, secret projection, heartbeat,
broker, and policy state. The UI distinguishes local Windows runs, isolated
enterprise runs, and offline runs, then shows the recovery action from the same
status row. Credential refresh waits are represented as recovery actions
without keeping a separate desktop-only state model.

Review is handled by any **review-capable slot**, not by a permanently dedicated reviewer pane.
Meta-planning follows the same rule: the current Claude/Codex role pair is an
MVP seed, while custom planning roles should be selected from provider
capability metadata. The operator remains the only approval owner, and planning
workers only return read-only drafts or reviews.

## 4. Public docs vs runtime contracts

The public product-facing operator contract is centered on:

- `README.md`
- this file

The public first-run entrypoints now converge on:

- `winsmux init`
- `winsmux launch`
- `winsmux launcher presets [--json]`
- `winsmux launcher lifecycle [preset|--clear] [--json]`
- `winsmux workers <status|start|stop|doctor> [slot|all] [--json]`
- `winsmux workers <exec|logs|upload|download> <slot> ... [--json]`
- `winsmux workers heartbeat <mark|check> <slot> [--run-id <id>] ... [--json]`
- `winsmux workers workspace <prepare|cleanup> <slot> ... [--json]`
- `winsmux workers secrets project <slot> --run-id <id> ... [--json]`
- `winsmux workers sandbox baseline <slot> --run-id <id> ... [--json]`
- `winsmux workers broker baseline <slot> --run-id <id> --endpoint <url> ... [--json]`
- `winsmux workers broker token <issue|check> <slot> --run-id <id> ... [--json]`
- `winsmux workers policy baseline <slot> --run-id <id> ... [--json]`
- `winsmux conflict-preflight`
- `winsmux compare <runs|preflight|promote>`

That direction is public product behavior.
Repository-specific startup flows are kept in contributor documents, not in the primary public UX.
`winsmux launcher presets [--json]` reports launcher presets, pair templates, and slot capabilities before a launch or compare-oriented run.
`winsmux launcher lifecycle [preset|--clear] [--json]` reports or stores the local workspace lifecycle override.
`winsmux launcher save <name>` stores that launcher template in the project `.winsmux` directory for later reuse.
Lifecycle presets are declarative workspace policy. They do not execute arbitrary setup or teardown scripts from project configuration.
`winsmux workers workspace prepare` creates a disposable `isolated-enterprise` run workspace from explicit project-relative projections only.
It separates the projected workspace, downloads, and artifacts directories, and the returned location identities use shareable artifact references instead of host absolute paths.
`winsmux workers workspace cleanup` deletes only the verified run directory under `.winsmux/isolated-workspaces`.
`winsmux workers secrets project` resolves DPAPI vault entries at run start and writes typed `env`, `file`, and `variable` projections into the run-local secret boundary without returning secret values in JSON or public metadata.
`winsmux workers sandbox baseline` records the Windows restricted-token and ACL boundary contract for a prepared isolated run, without claiming full process isolation before the launcher enforces it.
`winsmux workers broker baseline` records the single external broker node contract for a prepared isolated run, without starting the external worker or mixing broker metadata with OAuth or token brokering.
`winsmux workers broker token` stores short-lived broker run tokens inside the run secret boundary, reports only references and expiry metadata, and marks the run offline when an expired token cannot be refreshed.
`winsmux workers policy baseline` records the prompt-external execution policy for a prepared isolated run, including network, write, provider, check, and evidence requirements.
`winsmux compare <runs|preflight|promote>` is the public compare coordination surface.
It wraps run comparison, merge preflight, and follow-up candidate promotion behind one entrypoint.
The desktop compare card surfaces shared changed files as hotspots and displays a risk badge before winner selection.
`winsmux skills [--json]` lists supported workflow packs and their public evidence expectations.
The catalog is contract-only: it must not expose private skill bodies, private guidance, generated runtime artifacts, or local absolute paths.
Workflow execution remains operator-mediated.
The contract can identify the workflow pack, required evidence, and expected result fields, but the operator keeps final decisions for task splitting, merge, release, and escalation.

Repository-specific runtime contracts also exist for contributor flows, but they are maintained as contributor documents rather than primary public product docs.

## 5. Public docs vs contributor docs

The public-facing docs describe the operator model and product shape.
Contributor workflows, release operations, and repository-specific runtime contracts are documented separately and do not define the public operator or pane contract.

## 6. Legacy layouts vs current model

Older `Operator / Builder / Researcher / Reviewer` pane layouts still exist for compatibility, but they are not the long-term architecture.

The current model is:

- one external operator
- multiple managed pane agents
- review handled by any review-capable slot

## 7. Tauri UI direction

The Tauri desktop direction follows the same contract:

- **workspace sidebar** for sessions, explorer, open editors, and source control summary
- **conversation shell** as the primary operator surface
- **details panel** for the selected run, slot, branch, and review state
- **evidence sidebar** for source-linked verification, review, security, and event records
- **secondary editor surface** for source-level drill-down
- **terminal drawer** for raw PTY and diagnostics only
- **decision view** for verification, review, security, architecture, and operator judgement

The roadmap groups these desktop surfaces into three UX layers:

- **Decision View** for compare, evidence, code browser, and localhost preview
- **Fast Start + Launcher + Coordination Guard** for quick entry, multi-agent launch, and conflict preflight
- **Managed Team Intelligence** for durable memory, playbooks, and diversity-aware follow-up runs

The desktop timeline grammar follows the docs contract:

- user message
- operator update
- system card
- pane result report

Pane result reports should follow the shared `AGENT-BASE.md` report shape:

- `STATUS`
- `TASK`
- `RESULT`
- `FILES_CHANGED`
- `ISSUES`

## 8. Observation packs

Before substantive work, the operator should perform a small orientation pass and package the result as an **observation pack** for the target pane or slot.

Observation packs are not freeform prose. They are evidence bundles that can be compared across runs and experiments.

An observation pack should include, when available:

- changed files
- working tree summary
- failing command or failing check
- last passing signal
- branch/head
- worktree
- CI, build, cache, and environment signals
- relevant links or prior evidence references

## 9. Consultation loop

When the operator judges a task to be difficult, ambiguous, or non-converging, it should consult a **consult-capable slot**.

The standard consultation timings are:

- after initial orientation, before substantive work
- when stuck
- when considering a change of approach
- when evidence conflicts
- before declaring the task done

Consultation results are advisory. The operator owns the final accept/reject judgement.

## 10. Consult-capable slots

Consultation is handled as a slot capability, similar to review capability.

- no dedicated consultation pane is required
- Codex is the default consultation candidate for code, build, and debug work
- Gemini is the default consultation candidate for long-context, multimodal, policy, or specification work
- other providers may advertise consultation capability in the same slot model

In **advisory mode**, a consult-capable slot does not perform file mutation or destructive command execution. It returns recommendations, risks, confidence, and the next test to run.

The default policy is:

- up to 2 consultation calls per run
- a 3rd call is allowed only for stuck-state recovery or evidence reconciliation

## 11. Experiment isolation and compare

Hypothesis-driven work should be isolated by run, slot, and worktree.

- one hypothesis should map to one run
- parallel experiments should use separate slots or worktrees
- comparison should happen on top of the run ledger, not ad hoc operator memory

The operator uses these isolated runs to compare evidence, detect conflicts, and choose the next experiment.

## 12. Tactic promotion

When a run finds a repeatable winning tactic, winsmux should promote it instead of leaving it as one-off tribal knowledge.

Promotion targets include:

- playbooks
- prewarm candidates
- verification presets
- reusable investigation prompts

This keeps successful debugging, build, and verification loops durable and reusable across future runs.
