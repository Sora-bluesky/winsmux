# CLI comparison bakeoff

This page defines the Harness Bench evidence contract for comparing
Claude Code, Codex, Antigravity CLI, and OpenRouter-backed open-weight LLM
workers as winsmux worker-pane candidates.

`v0.36.17` ships the model setup, readiness, and desktop reliability groundwork.
`v0.36.23` ships the six-pane bring-up: the durable runner, the CDP pane-capture
path, and live dispatch-to-exec evidence across all six workers. The official
recorded 27-task benchmark run and Japanese HTML result report are re-scheduled
to a GA-readiness bench milestone that runs after the Harness Bench
productization lane (`v0.36.39`), where the harness defects found during the
2026-07-05 bring-up runs (#1134, #1135) are tracked. The decision record lives
in `docs/incidents/v03623-session-readiness/04-benchmark-readiness-gate.md`.

The bakeoff is not a model leaderboard. It is an operator evidence workflow for
deciding which CLI is suitable for a task class inside winsmux.

## Public contract

The tracked task pack lives in `tasks/cli-bakeoff/v1/`.

- `benchmark-pack.json` defines workers, task classes, scoring axes, and quality gates.
- `WB-*.md` files are shared task packets.
- Every worker in a run must receive the same task packet content.
- Every scored worker must use the same task set, timeout, and workspace
  baseline; per-worker task, timeout, or workspace overrides fail preflight.
- A worker result is scoreable only when it completed and the desktop recording evidence is publishable.
- The official task target is 27 tasks with a 60 minute timeout per task.
- The operator is not scored. The operator may assign panes, run commands,
  collect logs, mark exclusions, update reports, and manage release gates, but
  must not improve a worker answer mid-run.
- Worker-to-worker messaging is disabled for official runs. Run manifests must
  disclose the messaging state, operator intervention count, and execution
  surface so the run can be audited after collection.
- Official scoreable evidence must report
  `run_governance.execution_surface = "visible_desktop_worker_panes"` together
  with publishable desktop worker-pane recording evidence. App-external API or
  local CLI batch outputs are reference evidence only.
- Blocked runs, missing API keys, timeouts, crashes, empty stdout, invalid
  output, missing end markers, packet hash mismatches, and missing recordings
  are kept as evidence but are excluded from model scoring.

The required local evidence directory is `.winsmux/evidence/cli-bakeoff/<run-id>/`.
That directory is intentionally not committed.

## One-command desktop preparation

Use the desktop preparation entrypoint before any official six-pane run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/start-cli-bakeoff-desktop.ps1
```

The script builds the current release CLI and desktop app, copies the tracked
task pack into the local benchmark project, verifies that the release binaries
match the repository version and Git head, launches the production desktop app,
and moves the visible window to the test display. It does not use the Start menu,
installed shortcuts, stale installed binaries, or the Tauri dev server unless the
caller explicitly edits the command.

For a dry run that proves the pack and binary identity without launching the
desktop app:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/start-cli-bakeoff-desktop.ps1 -SkipBuild -NoLaunch
```

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

Before publishing v0.36.23, the six-pane bring-up evidence must come from the
visible winsmux desktop app: ready-check reporting all six workers, the
pty_capture preflight reaching every pane, the dispatch-to-exec loop delivering
a packet with a matching displayed hash, and the `api_llm` workers completing
end-to-end through the in-app pane route.

The official benchmark evidence requirement moves with the benchmark itself to
the GA-readiness bench milestone: that run must come from the visible winsmux
desktop app, with the operator pane managing all six worker panes, including
the OpenRouter workers through the in-app `api_llm` pane route. App-external
batch runs are retained only as reference evidence.

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
