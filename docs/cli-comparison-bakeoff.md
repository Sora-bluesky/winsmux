# CLI comparison bakeoff

This page defines the Harness Bench evidence contract for comparing
Claude Code, Codex, Antigravity CLI, and OpenRouter-backed open-weight LLM
workers as winsmux worker-pane candidates.

`v0.36.17` ships the model setup, readiness, and desktop reliability groundwork.
The official six-pane benchmark run and Japanese HTML result report belong to
`v0.36.23`, after the context-continuity, process-lifecycle, audit,
coordinator, and router groundwork has stabilized.

The bakeoff is not a model leaderboard. It is an operator evidence workflow for
deciding which CLI is suitable for a task class inside winsmux.

## Public contract

The tracked task pack lives in `tasks/cli-bakeoff/v1/`.

- `benchmark-pack.json` defines workers, task classes, scoring axes, and quality gates.
- `WB-*.md` files are shared task packets.
- Every worker in a run must receive the same task packet content.
- A worker result is scoreable only when it completed and the desktop recording evidence is publishable.
- The official task target is 27 tasks with a 60 minute timeout per task.
- The operator is not scored. The operator may assign panes, run commands,
  collect logs, mark exclusions, update reports, and manage release gates, but
  must not improve a worker answer mid-run.
- Blocked runs, missing API keys, timeouts, crashes, empty stdout, invalid
  output, missing end markers, packet hash mismatches, and missing recordings
  are kept as evidence but are excluded from model scoring.

The required local evidence directory is `.winsmux/evidence/cli-bakeoff/<run-id>/`.
That directory is intentionally not committed.

## Gates

Before recording or scoring a run:

```powershell
pwsh -NoProfile -File scripts/test-cli-bakeoff-preflight.ps1 -Json
```

Before publishing v0.36.17, the desktop reliability evidence must also pass:

```powershell
pwsh -NoProfile -File scripts/test-v03617-reliability-gate.ps1 -Json
```

That gate validates the local ten-run Tauri launch soak summary. The summary
must prove six visible worker panes, hidden worker status by default, debug port
cleanup after every run, zero owned orphan processes, and zero stale session
state files. The evidence file stays local under `.winsmux/evidence/` and is not
committed.

Before publishing v0.36.23, the official benchmark evidence must additionally
come from the visible winsmux desktop app. The operator pane must manage all six
worker panes, including the OpenRouter workers through the in-app `api_llm`
pane route. App-external batch runs are retained only as reference evidence.

After a local evidence run:

```powershell
pwsh -NoProfile -File scripts/summarize-cli-bakeoff.ps1 -Json
```

The summary writes advisory local outputs:

- `raw-score-matrix.csv`
- `model-evidence-profile.json`
- `model-task-fit.md`
- `assignment-policy.md`

These generated files are local evidence outputs. Public release notes should
summarize the findings without copying private paths, account names, API keys,
provider request identifiers, raw prompts, or unredacted transcripts.

## Assignment rule

Do not change the default worker layout from this bakeoff alone unless all of
the following are true:

- the task pack preflight passes;
- the compared workers used the same packet hash;
- each scored worker has publishable desktop recording evidence;
- blocked or incomplete runs are clearly separated from model quality findings;
- a reviewer accepts the scorecard and the public-surface audit passes.
