# Team Profile and worker-slot configuration

Project-owned Team Profile settings live in `.winsmux.yaml`. The installed
preset supplies defaults only after explicit `team-profile` opt-in. Generated
manifests, prompt bundles, and status output are projections of that configuration.

## Configuration and compatibility

An opted-in profile resolves its named preset, matches overrides by `slot-id`,
and validates the six resolved slots against the capability catalog and static
instruction-pack registry. Explicit overrides survive preset updates. Resetting
a field, slot, or team is an explicit user action.

When `team-profile` is absent, the existing `agent-slots` list remains the
complete roster. Reading or upgrading it must not load a preset, backfill slots,
or create additional panes. The actual slot count remains authoritative.

The canonical on-disk spelling is kebab-case. The live parser accepts matching
snake_case spellings as load-only aliases and rejects both spellings appearing
for the same field with `ambiguous_alias`. A scalar `team-profile: default`
is invalid; `team-profile` must be a mapping.

| Profile field | Contract |
|---|---|
| `schema-version` | Integer `1`; unknown versions are rejected. |
| `preset` | Installed package-owned preset ID. |
| `preset-revision` | Revision explicitly selected or acknowledged. |
| `update-policy` | `retain-overrides` in v1. |

An opted-in configuration resolves exactly `worker-1` through `worker-6`,
with unique slot IDs. Sparse project overrides are allowed, but a seventh slot
or deletion of a preset slot is rejected. Legacy configurations can retain a
smaller roster.

Each resolved slot has a concrete catalog `provider` and `model`, a supported
`reasoning-effort`, a registered `role-profile`, a `lifecycle` of `session`,
`task`, or `one-shot`, and a nonempty ordered list of unique `task-classes`.
The `provider-default` sentinel cannot remain in a resolved Team Profile. The
provider launch value comes from the validated model capability entry. A
`worker-backend` override must belong to that capability's assignable backends.

## Save and runtime boundaries

Save edits only the selected Team Profile fields and matching slot overrides.
It preserves `workspace-recipes`, `workflows`, `context-packs`, unknown keys,
and existing execution attributes. Duplicate mapping keys are rejected. Save
validates a sibling temporary file before atomic replacement; failed validation
leaves the original configuration intact.

Static templates are package-owned under `winsmux-core/agents/profiles`. Their
registry maps exact provider/model IDs to templates. Missing mappings must not
be repaired by filename probing or silent fallback. Repository instruction files
are not storage for Team Profile state.

Runtime prompt bundles compose base, provider, model, role, lifecycle, task-class,
and bounded launch metadata in that order. Launch does not invent a task ID or
authorization. A later typed dispatch packet supplies the concrete task and
its scope. Bundles remain disposable runtime state under
`.winsmux/runtime/prompt-bundles/`, with structured digests in manifest/status
metadata. Credentials, raw transcripts, private prompts, and unrelated private
context must not enter that metadata.

Unknown IDs, provider/model mismatches, unsupported effort, missing or invalid
templates, and non-runnable runtime capabilities reject start/apply. Editing
warnings do not authorize launch. A fresh opted-in start validates all six slots
before creating any worker pane. Rejected reconfiguration preserves the current
team. No automatic provider, model, backend, or effort substitution is allowed.

See [Operator model](../operator-model.md) for the supported public workflow.
