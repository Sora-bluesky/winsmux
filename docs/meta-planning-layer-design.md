# Meta-Planning Layer Design

## Status

Phase 0 design has been reviewed for implementation. `v0.24.18` adds the
CLI-only `winsmux meta-plan` entrypoint for the MVP seed role set:
`investigator` and `verifier`.

The command writes role draft artifacts, cross-review artifacts, an integrated
Markdown plan, and JSONL audit events under `.winsmux/`. Workers remain
read-only, and the operator keeps the single approval gate.

`v0.24.19` adds UTF-8 role YAML loading through `--roles <path>` and supports
one or two cross-review rounds through `--review-rounds <1|2>`. Role labels and
prompts may contain Japanese text, while `role_id` remains ASCII for logs.
The built-in seed remains Claude/Codex for the MVP, but custom role files can
select future providers when `.winsmux/provider-capabilities.json` declares the
adapter, launch command, prompt transport, and a known read-only launch
contract.

`v0.24.20` hardens runtime retention. Generated scaffold artifacts keep
`task_hash` and `prompt_hash` references instead of storing the operator task
body or role prompt bodies. The operator-owned interactive approval flow remains
the place where the full request is visible.

## Goal

Add a meta-planning layer above the normal operator execution flow.

The operator remains the only user-facing approval point. Before execution, the
operator may launch specialist planning workers in read-only planning mode,
collect their plans and cross-reviews, and merge them into one integrated plan
for the user.

The target control chain is:

```text
User -> Operator planning session -> specialist planning workers
     -> cross-review -> integrated plan -> single user approval -> execution
```

## Constraints

- Windows-native only. Do not require WSL2.
- The MVP seed uses Claude Code and Codex, but role selection must be
  capability-driven for custom role files.
- Providers outside the built-in MVP seed must be declared in
  `.winsmux/provider-capabilities.json` before they can be used as planning
  workers.
- Custom provider adapters outside the known Claude, Codex, and Gemini launch
  contracts must declare `read_only_launch_args`, which winsmux records in the
  launch contract before the provider is eligible for planning work.
- Worker panes must stay read-only and must not leave planning mode.
- The operator is the only component that may request final user approval.
- Role names must be configurable per task. Do not build around fixed role pairs.
- Japanese IME input for role labels, comments, and user-facing text is P0.
- Audit records must be JSONL and must use the existing winsmux logging model.
- Public docs and prompts must use current winsmux naming. Legacy bridge script
  names are compatibility details, not canonical product names.

## Current Environment Findings

### Naming cleanup gate

Repository-wide search currently finds the legacy runtime name in 223 tracked or
candidate text files, spread across public docs, compatibility inventories,
runtime compatibility paths, tests, upstream crate metadata, and external
planning files.

Do not add new occurrences in meta-planning docs, task titles, prompts, role
YAML, or audit event examples. Full removal is a separate planning gate because
some occurrences are executable compatibility behavior or provenance text, not
simple wording drift.

### Claude Code planning mode

Local `claude --help` exposes:

```text
--permission-mode <mode>
choices: acceptEdits, auto, bypassPermissions, default, dontAsk, plan
```

Phase 1 should treat `claude --permission-mode plan` as the first-choice launch
contract for Claude Code planning workers. A startup probe must verify that the
worker is actually in plan mode before any task is sent.

### Codex planning mode equivalent

Local `codex exec --help` does not expose a dedicated plan-mode flag. It does
expose:

```text
codex exec --sandbox read-only --json
codex exec --output-schema <FILE>
```

Phase 1 should treat Codex planning workers as read-only planning workers, not
as native plan-mode workers. The launch contract should combine:

- `codex exec --sandbox read-only`
- a system/task prompt that forbids mutation and requires a plan-only response
- optional `--json` or `--output-schema` for machine-readable collection

The design must record this as a weaker guarantee than Claude Code native plan
mode.

### winsmux bridge integration

The public command surface is `winsmux read`, `winsmux send`, and related
operator commands. Direct PowerShell entry through `scripts/winsmux-core.ps1`
remains an internal compatibility path.

Meta-planning must integrate through existing pane control and logging concepts:

- Read Guard: always read before sending to a pane.
- Role gate: planning workers may send results to the operator but must not
  control other panes.
- Shield Harness: planning launches should reuse existing safety checks and
  provider policy.
- Logger: write JSONL records through the existing `.winsmux/logs/*.jsonl`
  shape.

## Proposed Phase 1 MVP Flow

1. Operator receives a task and starts a meta-planning run.
2. winsmux launches two planning workers:
   - investigator: gather facts and constraints
   - verifier: find risks, missing tests, and failure modes
3. Each worker starts in planning-only mode.
4. Each worker produces a structured plan draft.
5. The operator sends each draft to the other worker for one cross-review round.
6. The operator merges the drafts and reviews into one Markdown plan.
7. The operator requests one user approval for the integrated plan.
8. Execution remains blocked until that approval exists.

The MVP intentionally skips the Tauri GUI and role editing UI. It does not make
Claude/Codex a permanent product model; it is the first seed for the
capability-driven role contract.

## Audit JSONL Schema Draft

Use the existing logger envelope:

```json
{
  "timestamp": "2026-05-04T00:00:00.0000000+09:00",
  "session": "winsmux-orchestra",
  "event": "meta_plan_init",
  "level": "info",
  "message": "Meta-planning run started.",
  "role": "operator",
  "pane_id": "%1",
  "target": "",
  "data": {}
}
```

Minimum events:

- `meta_plan_init`: task, selected roles, run id, operator pane.
- `role_assigned`: role id, provider, model, pane id, read-only policy.
- `plan_drafted`: role id, draft artifact ref, confidence, open questions.
- `cross_review`: reviewer role id, target role id, findings, blocking state.
- `plan_merged`: integrated plan artifact ref, source draft refs, unresolved items.
- `exit_plan_mode`: operator approval request time, plan ref, final gate state.

Do not store raw terminal transcripts, private prompt bodies, secrets, or local
absolute paths in audit records. Store artifact references and scrubbed summaries.

## Role YAML Schema Draft

Future configurable role files should live outside runtime logs and should be
loaded as UTF-8.

```yaml
version: 1
roles:
  - role_id: investigator
    label: "Investigator"
    provider: claude
    model: provider-default
    plan_mode: required
    read_only: true
    review_rounds: 1
    capabilities: [facts, constraints]
    prompt: |
      Gather facts and constraints. Do not edit files.
  - role_id: verifier
    label: "Verifier"
    provider: codex
    model: provider-default
    plan_mode: read_only_equivalent
    read_only: true
    review_rounds: 1
    capabilities: [risk, tests]
    prompt: |
      Find risks, missing tests, and failure modes. Do not edit files.
```

Rules:

- `role_id` must be ASCII and stable for logs.
- `label` and `prompt` may contain Japanese text.
- `provider` may be `claude` or `codex` for the built-in MVP seed, or a provider
  id declared in `.winsmux/provider-capabilities.json`.
- `read_only` must be true for meta-planning workers.
- `plan_mode` must be `required` for Claude-compatible providers and
  `read_only_equivalent` for non-Claude providers until their capability
  contract exposes a native plan-mode guarantee.
- Gemini is eligible through its known plan-approval launch contract. Future
  custom adapters are eligible only after their metadata declares adapter,
  command, prompt transport, and explicit `read_only_launch_args`.

## Integrated Plan Format

The integrated plan should be Markdown with these sections:

- Summary
- Key changes
- Interfaces and data flow
- Safety and approval gates
- Test plan
- Open questions

Only the integrated plan is user-approved. Worker drafts and reviews are
evidence, not approval surfaces.

## Phase 0 Deliverables

- This design document.
- `backlog.yaml` tasks for Phase 0, MVP, and expansion.
- Japanese roadmap title overrides.
- Regenerated roadmap output.

## Open Questions

- Should Phase 1 use interactive panes only, or also support non-interactive
  `codex exec --json` collection for planning drafts?
- Where should role YAML live by default: project `.winsmux/`, external planning
  root, or a new user-local winsmux config directory?
- Should meta-planning audit events reuse the orchestra log file or write a
  separate `meta-planning-*.jsonl` file under `.winsmux/logs/`?
- What is the exact startup probe for confirming Claude Code is in plan mode?
- Which legacy bridge script references should be renamed or hidden before this
  feature becomes public documentation?
