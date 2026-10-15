# CLI comparison bakeoff

This page defines the Harness Bench evidence contract for comparing
Claude Code, Codex, Antigravity CLI, and OpenRouter-backed open-weight LLM
workers as winsmux worker-pane candidates.

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

The desktop preparation entrypoint now launches the v0.38 project workspace:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/start-cli-bakeoff-desktop.ps1
```

The script builds the current release CLI and desktop app, copies the tracked
task pack into the local benchmark project, verifies that the release binaries
match the repository version and Git head, launches the production desktop app,
and moves the visible window to the test display. It confirms the mounted native
main view using its captured session and readonly canonical capabilities,
project, pane and run observations. It does not open or reopen a workspace
session, start another owner, or launch a missing run to satisfy observation.
An existing project with no current run is a valid restoration.
It does not use the Start menu,
installed shortcuts, stale installed binaries, or the Tauri dev server unless the
caller explicitly edits the command.

`-ProjectDir` is delivered once through the workspace view's folder-open request.
The launcher preserves pack copying, candidate identity checks, `-SkipBuild`,
`-NoLaunch`, and window metrics. `-NoLaunch` reports `launch: skipped` and provides
no native startup evidence. The app uses the existing public-smoke remote-debug
gate. The workspace store remains at its Windows KnownFolder location; changing
the child profile environment does not isolate that store. A busy app or debug
port stops preparation.
If verification fails, cleanup requests one normal close only from the exact
PID, creation identity and executable started by this invocation. Refused or
unconfirmed closure preserves the app; another app or child is never force killed.

The retired six-worker operator bakeoff is a separate consumer. Its ready-check,
composer and PTY-capture route has not been migrated to the new workspace.
`winsmux-app/scripts/run-cli-bakeoff.mjs` returns `unsupported` before those
effects when it sees the workspace startup or cannot identify its legacy
operator surface. A successful project launch does not prove a six-worker
benchmark run. Final removal of that legacy runner belongs to the later cleanup.

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

Official scoreable evidence must come from visible desktop worker panes with
publishable recording evidence. A successful project launch alone does not
establish a six-worker benchmark run. App-external batch results remain
reference evidence.

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
