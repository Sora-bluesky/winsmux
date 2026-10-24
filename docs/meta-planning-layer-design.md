# Meta-planning

`winsmux meta-plan` creates planning artifacts for the operator before execution.
The built-in roles are `investigator` and `verifier`. Workers remain read-only;
the operator presents the integrated plan for user approval.

## Role configuration

Use `--roles <path>` to load a UTF-8 role YAML file and
`--review-rounds <1|2>` to select the cross-review count. Role IDs are stable
ASCII identifiers. Labels and prompts may contain Japanese text. Each role
requires `read_only: true`.

The built-in provider seed uses Claude and Codex. Additional providers must be
declared in `.winsmux/provider-capabilities.json` with their adapter, command,
prompt transport, and read-only launch contract. Claude uses its planning-mode
contract, Codex uses a read-only sandbox, and Gemini uses its known planning
approval contract. Other adapters require explicit `read_only_launch_args`.
A provider declaration does not by itself prove runtime readiness.

## Outputs and privacy

The command writes role drafts, cross-review artifacts, an integrated Markdown
plan, and JSONL audit events under `.winsmux/`. Generated scaffold artifacts
retain `task_hash` and `prompt_hash` references rather than the task or role
prompt bodies. Do not copy raw terminal transcripts, private prompts, secrets,
or local absolute paths into audit records.

Only the integrated plan is presented for user approval. Worker drafts and
reviews provide evidence and do not authorize execution. Use the public
`winsmux read` and `winsmux send` commands for managed panes, with a read before
interaction. Planning workers must not control other panes.

See [Operator model](./operator-model.md) for the public control-plane contract.
