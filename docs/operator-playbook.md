# External operator playbook

The external operator coordinates managed workers, collects evidence, and
validates results against the requested outcome. The public command and
permission contract is described in [Operator model](./operator-model.md).

## Startup and managed panes

When restoration reports `needs-startup`, run `harness-check --json`, then
the configured orchestra startup, then `orchestra-smoke --json`. Dispatch is
allowed only when `operator_contract.can_dispatch` is true. Startup chatter
does not establish readiness.

Read a managed pane before interacting with it. For shell input, read the pane,
type the command, read again to verify the buffer, then send Enter. Use the
transport declared by the worker capability; packet REPL panes require their
typed packet grammar. Do not send raw prose to an `api_llm` packet REPL.

## Work and evidence

Give each worker a bounded outcome, necessary source references, its allowed
read/write scope, and executable acceptance conditions. Isolate conflicting
writers. Keep the author and any required independent reviewer separate.

Record the command, exit code, and evidence for completed verification.
Distinguish unexecuted work, environmental failures, and passing results.
A pane's completion message does not prove that the requested result exists.
Check the resulting files and native outputs before reporting success.

Use public or sanitized inputs for workers. Keep secrets, private prompt bodies,
raw transcripts, and unrelated local paths out of task packets and reports.
A denied action remains denied until its cause is resolved through the declared
permission route.

## Local Router Shadow Mode
`coordinator-router.ps1` retains deterministic execution authority.
`local-router-shadow.ps1` produces a Shadow Mode proposal only and does not alter execution.

Run the distribution gate first:

```powershell
pwsh -NoProfile -File scripts/test-v03638-router-distribution.ps1
```

It verifies the four source artifacts, the bundled desktop resources, and the CLI full profile.
It is a distribution gate, not the fixed 100-case reliability gate.

Then run the fixed 100-case reliability gate:

```powershell
pwsh -NoProfile -File scripts/test-v03638-router-reliability.ps1
```

The receipt evaluates these six classifications: `normal`, `previous-model-failure`,
`previous-infrastructure-failure`, `write-scope-conflict`, `all-offline`, and
`threshold-fallback`. Record its identity and provenance fields: `schema`, `gate_id`,
`target_version`, `task_base_sha`, `executed_head_sha`, and `source_sha256`. Record its
outcome fields: `run_count`, `class_counts`, `class_results`, `max_batch_size`,
`provider_calls`, `prompt_canary_occurrences`, `failures`, `child`, `child_output`,
`cleanup`, and `release_ready`. A passing receipt requires `provider_calls=0` and
`prompt_canary_occurrences=0`.

For each Shadow Mode decision, `fallback_required` states whether deterministic fallback is
needed. `fallback_decision` preserves that deterministic route, and `final_authority` is the
execution decision that remains in force.
