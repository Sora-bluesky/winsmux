# Operator Model

winsmux is built around a **two-layer orchestration model**:

- an **external operator layer**
- a **managed pane execution layer**

This separation is the main contract of the product. winsmux is positioned as a Windows-native, local-first multi-agent control plane rather than an editor-first IDE shell.

## 1. Standard control chain

The standard winsmux operating model is:

`User -> Claude Code (operator) -> pane agents`

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

The recommended operator is **Claude Code**.
winsmux is designed to work well with:

- Claude Code Channels
- Claude Code remote control
- other external user-to-operator channel surfaces

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
- review capability
- worktree assignment
- runtime role

The current direction is **slot/capability-based orchestration**, not hard-coded vendor roles.

Review is handled by any **review-capable slot**, not by a permanently dedicated reviewer pane.

## 4. Public docs vs runtime contracts

The public product-facing operator contract is centered on:

- `README.md`
- this file

The public first-run entrypoints now converge on:

- `winsmux init`
- `winsmux launch`
- `winsmux launcher presets [--json]`
- `winsmux launcher lifecycle [preset|--clear] [--json]`
- `winsmux conflict-preflight`
- `winsmux compare <runs|preflight|promote>`

That direction is public product behavior.
Repository-specific startup flows are kept in contributor documents, not in the primary public UX.
`winsmux launcher presets [--json]` reports the launcher presets, pair templates, and slot capabilities that should exist before a launch or compare-oriented run.
`winsmux launcher lifecycle [preset|--clear] [--json]` reports or stores the local workspace lifecycle override.
`winsmux launcher save <name>` stores that launcher template in the project `.winsmux` directory for later reuse.
Lifecycle presets are declarative workspace policy. They do not execute arbitrary setup or teardown scripts from project configuration.
`winsmux compare <runs|preflight|promote>` is the public compare coordination surface.
It wraps run comparison, merge preflight, and follow-up candidate promotion behind one entrypoint.
The desktop compare card surfaces shared changed files as hotspots and displays a risk badge before winner selection.

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
- **context side sheet** for run, slot, evidence, branch, and review state
- **secondary editor surface** for source-level drill-down
- **terminal drawer** for raw PTY and diagnostics only
- **decision cockpit** for verification, review, security, architecture, and operator-decision gates

The roadmap groups these desktop surfaces into three UX layers:

- **Decision Cockpit** for compare, evidence, code browser, and localhost preview
- **Fast Start + Launcher + Coordination Guard** for quick entry, multi-agent launch, and conflict preflight
- **Managed Team Intelligence** for durable memory, playbooks, and diversity-aware follow-up runs

`TASK-286` aligns the timeline grammar with the docs contract:

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
