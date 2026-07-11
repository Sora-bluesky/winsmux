# v0.36.29 Team Profile and Worker-Slot Assignment Architecture

This document is the foundation contract for TASK-713 and its child tasks
TASK-714 through TASK-718. It introduces an official six-worker Team Profile
and lets users assign each worker slot independently by provider, model,
reasoning effort, role profile, lifecycle, and task class.

The design extends the current external-operator model. It does not implement
the child tasks, replace the runtime manifest, change benchmark-measurement
models, or make repository instruction files into mutable settings stores.

## Decision summary

The project-level `.winsmux.yaml` file is the source of truth for the selected
Team Profile and project-owned slot overrides. A versioned, package-owned
preset supplies defaults. The effective team is derived as follows:

1. Load the built-in preset named by `team-profile.preset`.
2. Match `agent-slots` entries to preset entries by `slot-id`.
3. Overlay only fields explicitly present in each project slot entry.
4. Validate the six resolved slots against the model capability catalog and
   the static instruction-pack registry.
5. At pane launch, project each validated slot into a runtime prompt bundle and
   `.winsmux/manifest.yaml`.

The built-in preset and project overrides remain separate. Applying or
upgrading a preset never silently deletes a project override. Resetting a field,
slot, or whole team to preset values is a distinct, explicit user action.

The authoritative existing surfaces that this design extends are:

- `.winsmux.yaml` and `winsmux-core/scripts/settings.ps1` for project settings;
- `winsmux-app/src/modelCapabilities.ts` for provider, model, effort, backend,
  transport, and readiness vocabulary;
- `winsmux-core/scripts/orchestra-start.ps1` for worker layout and manifest
  creation;
- `.winsmux/manifest.yaml` and `winsmux-core/scripts/pane-status.ps1` for
  runtime state and status projection.

Generated manifests, prompt bundles, settings-screen state, and status output
are projections. They are not additional configuration authorities.

## Official default Team Profile

The package owns the default preset at:

`winsmux-core/agents/team-profiles/official-balanced-v1.yaml`

`official-balanced-v1` is immutable once released. A changed default is
published as a new preset ID or revision and is selected explicitly. The first
version resolves to the following six slots after TASK-714 has verified the
catalog entries introduced ahead of TASK-714 in PR #1191:

| Slot | Provider | Model capability ID | Effort | Role profile | Lifecycle | Task classes |
|---|---|---|---|---|---|---|
| `worker-1` | `codex` | `codex-gpt-5-6-sol` | `xhigh` | `architect` | `session` | `architecture`, `protocol`, `security` |
| `worker-2` | `codex` | `codex-gpt-5-6-terra` | `high` | `builder` | `task` | `implementation`, `test` |
| `worker-3` | `codex` | `codex-gpt-5-6-terra` | `high` | `builder` | `task` | `implementation`, `test` |
| `worker-4` | `codex` | `codex-gpt-5-6-sol` | `xhigh` | `reviewer` | `task` | `review`, `security` |
| `worker-5` | `codex` | `codex-gpt-5-6-terra` | `high` | `researcher` | `task` | `research`, `documentation` |
| `worker-6` | `codex` | `codex-gpt-5-6-luna` | `medium` | `maintainer` | `task` | `documentation`, `repository-operations` |

The preset is an operational default, not a benchmark claim or leaderboard.
Catalog metadata and benchmark-measurement model lists remain independent.

Lifecycle values have these v1 meanings:

- `session`: retain the pane and its context for the orchestra session;
- `task`: reset provider context at the task boundary while retaining the slot;
- `one-shot`: launch for one dispatch and retire after its recorded result.

Role profiles describe instruction policy, not pane topology. All six entries
remain runtime `worker` panes. Lane A owns layout and worktree placement; a
Lane B `role-profile: reviewer` must not create a legacy Reviewer pane or change
the slot's worktree by itself.

## Shared `.winsmux.yaml` contract

### Top-level ownership

Lane A and Lane B compose in one YAML document with disjoint top-level keys:

| Top-level key | Owner | Purpose |
|---|---|---|
| `config-version` | shared settings loader | Version of the containing settings document; remains `1` for these additive namespaces. |
| `workspace` | Lane A / TASK-658 | Layout selection, pane placement, worktree policy, recipes, and startup actions. |
| `workflows` | Lane A / TASK-659 | Versioned resumable workflow and pipeline definitions. |
| `context-packs` | Lane A / TASK-660 | Bounded repository-context package definitions and references. |
| `team-profile` | Lane B / TASK-715 | Base Team Profile selection and preset update policy. |
| `agent-slots` | Lane B / TASK-715 | Per-slot overrides and existing execution attributes, keyed by `slot-id`. |
| Existing keys such as `external-operator`, `worker-backend`, `execution-profile`, `roles`, and `vault-keys` | existing settings contract | Preserved until their own migration contract deprecates them. |

Lane A writers must not rewrite `team-profile` or `agent-slots`. Lane B writers
must not rewrite `workspace`, `workflows`, or `context-packs`. Both lanes use a
read-modify-write path that preserves unknown top-level keys. A save operation
that parses only its own subtree and serializes a replacement root document is
not acceptable.

The canonical on-disk spelling is kebab-case. Existing snake_case spellings
remain load-only compatibility aliases where the current settings loader
already accepts them. New saves emit the canonical spelling without changing
unrelated legacy keys merely to normalize formatting.

### Composed example

```yaml
config-version: 1

workspace:
  schema-version: 1
  layout: six-managed-workers
  recipe: default
  worktree-policy: managed
  startup-actions: []

workflows:
  schema-version: 1
  definitions: {}

context-packs:
  schema-version: 1
  definitions: {}

team-profile:
  schema-version: 1
  preset: official-balanced-v1
  preset-revision: 1
  update-policy: retain-overrides

agent-slots:
  - slot-id: worker-1
    provider: codex
    model: codex-gpt-5-6-sol
    reasoning-effort: xhigh
    role-profile: architect
    lifecycle: session
    task-classes:
      - architecture
      - protocol
      - security
  - slot-id: worker-6
    provider: openrouter
    model: openrouter-glm-5-2
    reasoning-effort: provider-default
    role-profile: maintainer
    lifecycle: task
    task-classes:
      - documentation
      - repository-operations

external-operator: true
worker-backend: local
roles: {}
```

The example intentionally shows only two override entries. The resolved team
still has six slots because the remaining four come from the selected preset.
An override may be sparse down to `slot-id`; omission means "inherit this field
from the preset," not "use an implicit provider default."

### Lane B schema

`team-profile` has the following v1 fields:

| Field | Required | Contract |
|---|---|---|
| `schema-version` | yes | Integer `1`. Unknown versions are rejected. |
| `preset` | yes | ID of an installed package-owned Team Profile. |
| `preset-revision` | yes | Revision last selected or acknowledged by the user. |
| `update-policy` | yes | `retain-overrides` in v1. No implicit reset policy exists. |

Each `agent-slots` entry is keyed by `slot-id` and may override these Lane B
fields:

| Field | Resolved requirement | Contract |
|---|---|---|
| `slot-id` | required | One of `worker-1` through `worker-6`; unique, stable identity. |
| `provider` | required | A `ProviderCapabilityId` from `modelCapabilities.ts`. |
| `model` | required | Stable `ModelCapability.id`, not the provider's raw CLI argument. |
| `reasoning-effort` | required | Supported by both the selected provider and model. |
| `role-profile` | required | ID in the static role-profile registry. |
| `lifecycle` | required | `session`, `task`, or `one-shot`. |
| `task-classes` | required | Non-empty, duplicate-free ordered list of registered task-class IDs. |

Existing execution fields in `agent-slots`, including `runtime-role`,
`worktree-mode`, `worker-backend`, `execution-profile`, `prompt-transport`, and
backend-specific fields, remain owned by their current contracts. TASK-715 must
preserve them. The new `provider` field is canonical for Team Profile selection;
the existing `agent` field is a migration alias. The resolver maps the stable
model capability ID to that catalog entry's provider launch value only after
validation. It does not infer a provider by sniffing model text.

The resolved configuration must contain exactly six unique slots. A project
override list does not need six entries, but it may not introduce a seventh
slot or delete a preset slot in v1.

### Load, validate, and save

The TASK-715 settings service follows one deterministic path:

1. Parse the entire YAML document and reject duplicate mapping keys.
2. Validate `config-version` and the Lane B `schema-version`.
3. Load the named package preset and verify its declared digest and six unique
   slot IDs.
4. Normalize supported legacy spellings without modifying the source file.
5. Overlay project slot fields by exact `slot-id` and produce six resolved
   immutable slot records.
6. Validate structural fields, then catalog relationships, then instruction-pack
   references. Return structured issues with slot ID, field, code, severity,
   and remediation. Never silently substitute a provider, model, effort, role,
   lifecycle, or task class.
7. On save, edit only `team-profile` and the changed Lane B fields in the
   matching `agent-slots` entry. Preserve all Lane A and unknown subtrees and
   all existing non-Lane-B slot fields.
8. Write to a sibling temporary file, parse and validate it again, then replace
   `.winsmux.yaml` atomically. A failed validation leaves the original file
   unchanged.

When the user changes a field, save the explicit override. When the user resets
that field to preset, remove only that field from the project entry. Remove an
empty slot entry only when it has no other existing execution fields. Selecting
or refreshing a preset changes `team-profile` metadata and inherited values;
it does not erase explicit fields under `agent-slots`.

The settings UI may display a resolved six-row table, but it must retain the
distinction between inherited and overridden values. Generated resolved state
must not be written as a second authority under `.winsmux/`.

## Static instruction packs

TASK-716 adds package-owned, reviewable templates under
`winsmux-core/agents/profiles`:

```text
winsmux-core/agents/profiles/
  registry.yaml
  base.md
  providers/
    codex.md
    claude.md
    antigravity.md
    grok-build.md
    openrouter.md
  models/
    codex/
      codex-gpt-5-6-sol.md
      codex-gpt-5-6-terra.md
      codex-gpt-5-6-luna.md
    claude/
      <catalog-model-id>.md
    antigravity/
      <catalog-model-id>.md
    grok-build/
      <catalog-model-id>.md
    openrouter/
      _dynamic.md
      <seed-catalog-model-id>.md
  roles/
    architect.md
    builder.md
    reviewer.md
    researcher.md
    maintainer.md
  lifecycles/
    session.md
    task.md
    one-shot.md
  task-classes/
    architecture.md
    protocol.md
    security.md
    implementation.md
    test.md
    review.md
    research.md
    documentation.md
    repository-operations.md
```

`registry.yaml` assigns every selectable catalog model to an exact provider and
model template ID. Dynamic provider models use an explicit registry mapping
such as `models/openrouter/_dynamic.md`; the resolver must not probe filenames
or silently fall back because a file is missing.

Templates contain only static behavioral instructions. They do not contain
credentials, local absolute paths, project content, mutable user preferences,
or provider hidden prompts. Adding a provider or model requires adding or
explicitly mapping its instruction pack and passing registry validation.

Repository-owned `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` remain normal static
repository instructions. TASK-716 and TASK-717 must not edit, generate,
append to, or use them as storage for Team Profile state.

## Runtime prompt-bundle projection

TASK-717 resolves a slot immediately before worker-pane launch and builds one
deterministic prompt bundle in this order:

1. `base.md`;
2. the exact provider template;
3. the exact catalog-mapped model template;
4. the selected role template;
5. the selected lifecycle template;
6. task-class templates in the validated order from `.winsmux.yaml`;
7. bounded runtime assignment metadata: slot ID, task ID, allowed worktree,
   allowed read/write scope, and expected evidence contract.

The bundle is written atomically beneath
`.winsmux/runtime/prompt-bundles/<session-id>/<slot-id>.md`. It is ephemeral
runtime state and must be ignored by Git. It contains no credential values,
raw transcript, browser state, or unrelated private context.

The manifest session records the resolved Team Profile ID, preset revision,
source configuration digest, and instruction-pack registry digest. Each pane
entry adds structured data rather than encoding state in a prompt string:

```yaml
session:
  team_profile:
    preset: official-balanced-v1
    preset_revision: 1
    source_config_sha256: <digest>
    instruction_registry_sha256: <digest>
panes:
  worker-1:
    slot_id: worker-1
    assignment:
      provider: codex
      model: codex-gpt-5-6-sol
      launch_model: gpt-5.6-sol
      reasoning_effort: xhigh
      role_profile: architect
      lifecycle: session
      task_classes: [architecture, protocol, security]
    prompt_bundle:
      path: .winsmux/runtime/prompt-bundles/<session-id>/worker-1.md
      sha256: <digest>
      template_ids: [base, provider/codex, model/codex/codex-gpt-5-6-sol, role/architect, lifecycle/session, task/architecture, task/protocol, task/security]
    status: ready
```

The status command and desktop runtime view show provider, model capability ID,
effort, role, lifecycle, task classes, configuration source
(`preset`/`override`), validation state, and the prompt-bundle digest. They do
not show the prompt body, credential state beyond a redacted requirement name,
or the provider's hidden metadata.

Manifest and status serialization must use structured fields. No component may
classify assignments by searching prompt text or model-name substrings. A
bundle generation failure returns a typed issue before launch and does not
write a partial manifest entry.

## Capability mismatch and fail-closed policy

TASK-718 owns the user-facing warning policy and the final start/apply gate.
TASK-715 and TASK-717 expose structured validation results; they do not invent
fallbacks.

| Condition | Settings behavior | Launch/apply behavior |
|---|---|---|
| Unknown provider or model ID | Error on the affected field. | Reject the transaction. |
| Model belongs to another provider | Error with the catalog provider ID. | Reject the transaction. |
| Unsupported reasoning effort | Error listing supported values. | Reject the transaction. |
| Unknown role, lifecycle, or task class | Error identifying the missing registry entry. | Reject the transaction. |
| Missing or digest-invalid instruction template | Error naming the template ID, without local private content. | Reject the transaction. |
| Catalog state is `blocked`, `reference-only`, or `unavailable` | Warning plus non-runnable status in the resolved row. | Reject the transaction. |
| Catalog state is `candidate`, `setup-required`, or `selectable` but runtime credentials, CLI, backend, transport, or model access are not verified | Actionable warning; show only requirement names, never secret values. | Recheck at launch and reject if runtime readiness is not `runnable`. |
| Dynamic catalog refresh is unavailable | Preserve the saved ID and show stale/unverified state. | Reject unless a still-valid, locally verified catalog entry and runtime probe both pass. |
| User overrides differ from a newly available preset revision | Mark fields as retained overrides and offer explicit reset controls. | Use the retained override if otherwise runnable. |

Fail-closed is transactional. For a fresh orchestra start, all six resolved
slots must pass before any new worker pane is created. For reconfiguration of a
running orchestra, a rejected candidate configuration leaves the current team
running and records the candidate validation failure; it does not partially
replace slots. There is no automatic fallback to `provider-default`, a
different model, a `fallback-model`, or a less expensive effort.

Warnings are advisory only while editing. A yellow warning must never be
interpreted as launch authorization. The runtime readiness gate is the final
authority because credentials and executable availability can change after
save.

TASK-718 wires these rules into the v0.36.29 pre-release gate. The gate must
cover the default preset, every mismatch class above, the six-slot atomic start
rule, user-override retention, settings/CLI/runtime display parity, prompt
privacy, public documentation, public-surface audit, and the full Git guard.

## Child task contracts

### TASK-714: provider and model catalog update

**Scope.** Reconcile `winsmux-app/src/modelCapabilities.ts` and generated/common
contract consumers with official information for Sonnet 5, Fable 5,
Antigravity, Grok, and OpenRouter. Audit the GPT-5.6 Sol/Terra/Luna entries that
PR #1191 added ahead of this child and retain them when verified.

**Boundary.** TASK-714 owns provider/model/effort/readiness metadata and evidence
references. It does not implement `.winsmux.yaml` persistence, templates,
prompt projection, settings UI, or runtime lifecycle. It must not add, remove,
rename, or reinterpret benchmark-measurement models or turn availability
metadata into benchmark results.

**Acceptance gate.** Catalog validation has no duplicate IDs, provider/model
mismatches, invalid default efforts, or invalid backends; every new claim has
dated official-source evidence; generated common-contract parity and relevant
desktop tests pass; and an exact before/after snapshot proves that the
benchmark-measurement model set and measurements are unchanged.

### TASK-715: per-worker assignment schema

**Scope.** Implement the `team-profile` and Lane B `agent-slots` schema, preset
overlay, load/normalize/validate/save service, migration aliases, and explicit
override reset semantics described above.

**Boundary.** TASK-715 owns persisted user intent and resolved slot records. It
does not add catalog entries, author instruction templates, launch panes,
generate prompt bundles, or implement the settings screen. It must preserve
Lane A namespaces and existing backend/worktree slot fields.

**Acceptance gate.** Fixtures cover empty project defaults, sparse overrides,
all six full overrides, legacy aliases, duplicate keys/slots, missing slots in
the preset, a seventh slot, invalid enums, and catalog mismatches. Round-trip
tests prove that saving a Lane B field leaves `workspace`, `workflows`,
`context-packs`, unknown keys, and non-Lane-B slot fields semantically unchanged.
Preset revision tests prove that explicit overrides survive apply/upgrade and
are removed only by an explicit reset. Failed validation and failed atomic
replace leave the original file intact.

### TASK-716: instruction-pack templates

**Scope.** Add the static profile tree and registry under
`winsmux-core/agents/profiles`, covering the default preset and every selectable
catalog mapping, including an explicit policy for dynamic models.

**Boundary.** TASK-716 owns static instruction text, template IDs, registry
relationships, and lint rules. It does not read project settings, launch panes,
generate runtime bundles, or mutate repository instruction files. Templates
must not become a second provider/model catalog.

**Acceptance gate.** Registry lint proves unique stable IDs, exact file paths,
valid UTF-8 without BOM, no missing mappings for selectable models/default
roles/lifecycles/task classes, and no secrets or private absolute paths.
Deterministic composition snapshots cover one default slot and one dynamic
provider slot. Hash checks prove `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` are
unchanged.

### TASK-717: runtime prompt-bundle projection

**Scope.** At worker-pane launch, consume the resolved TASK-715 slot record and
TASK-716 registry, generate the deterministic runtime bundle, pass it through
the provider's declared transport, and project structured assignment and bundle
metadata into manifest and status.

**Boundary.** TASK-717 owns derivation and runtime projection only. It does not
save user settings, update the model catalog, edit static templates, redesign
the settings screen, or weaken the runtime readiness decision owned by
TASK-718. The bundle is disposable and never becomes configuration authority.

**Acceptance gate.** Focused tests prove stable layer order and digest,
provider-declared transport, atomic file/manifest writes, lifecycle-specific
context behavior, structured manifest round-trip, status parity, and redaction.
Failure injection at every projection step proves no partial worker launch or
partial manifest assignment. Repository instruction-file hashes remain
unchanged before and after launch.

### TASK-718: settings, documentation, and pre-release gate

**Scope.** Add the six-row Team Profile settings experience, inherited/override
indicators, provider/model/effort dependency controls, role/lifecycle/task-class
controls, mismatch warnings, explicit reset actions, runtime display, public
documentation, and the v0.36.29 release gate.

**Boundary.** TASK-718 consumes the catalog, settings service, template registry,
and projection result through their typed contracts. It does not duplicate
their validation tables in UI-only code, silently repair invalid configuration,
or change benchmark measurements. Release publication remains outside this
child and still requires the release-level approval contract.

**Acceptance gate.** UI and CLI tests cover all mismatch rows in the policy
table, default/inherited/overridden rendering, keyboard-accessible reset
confirmation, save/reload retention, and settings/runtime parity. End-to-end
fixtures prove a valid six-slot start and transactional refusal for each
non-runnable condition. Documentation examples parse against the real schema.
The v0.36.29 pre-release gate includes focused tests, common-contract parity,
public-surface audit, `git diff --check`, and
`scripts/git-guard.ps1 -Mode full`.

## Evidence, migration, and rollback

TASK-713 changes documentation only. Child implementations must preserve the
current external-operator path when `team-profile` is absent: resolve
`official-balanced-v1` in memory and do not rewrite the project file merely by
reading it. Existing `agent-slots` provider fields are migrated through the
TASK-715 compatibility path, with an explicit diagnostic for ambiguous raw
model values.

Completion evidence for the child sequence is more than passing exit codes. It
includes validated YAML examples, exact catalog/benchmark snapshots,
round-trip preservation fixtures, deterministic bundle digests, manifest and
status snapshots, instruction-file hash checks, mismatch failure injection,
and the pre-release gate report.

Rollback is additive and ordered. TASK-718 UI/gate wiring can be disabled while
preserving saved YAML; TASK-717 projection can stop consuming the new fields;
TASK-716 templates can remain inert; TASK-715 can continue reading the old
settings contract; and TASK-714 catalog additions can be reverted independently
only if no saved project configuration references them. No rollback path
rewrites user overrides or repository instruction files.

## Non-goals

- no child implementation in TASK-713;
- no dynamic mutation of `AGENTS.md`, `CLAUDE.md`, or `GEMINI.md`;
- no raw transcript, secret, token, cookie, or credential value in settings,
  prompt-bundle metadata, manifest status, tests, or documentation;
- no automatic provider/model fallback or content-sniffing classification;
- no change to benchmark-measurement models or results;
- no seventh worker slot, arbitrary plugin-defined lifecycle, or recursive
  delegation in schema v1;
- no replacement of Lane A layout/workflow/context-pack authority;
- no PR, merge, planning-file update, or release publication in this parent
  task.
