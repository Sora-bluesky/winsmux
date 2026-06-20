# CLI comparison bakeoff

This page defines the `v0.36.15` bakeoff evidence path for comparing Claude
Code, Codex, and Antigravity CLI as winsmux worker-pane candidates.

The bakeoff is not a model leaderboard. It is an operator evidence workflow for
deciding which CLI is suitable for a task class inside winsmux.

## Public contract

The tracked task pack lives in `tasks/cli-bakeoff/v1/`.

- `benchmark-pack.json` defines workers, task classes, scoring axes, and quality gates.
- `WB-*.md` files are shared task packets.
- Every worker in a run must receive the same task packet content.
- A worker result is scoreable only when it completed and the desktop recording evidence is publishable.
- Blocked runs, empty Antigravity stdout, missing end markers, packet hash mismatches, and missing recordings are kept as evidence but are excluded from model scoring.

The required local evidence directory is `.winsmux/evidence/cli-bakeoff/<run-id>/`.
That directory is intentionally not committed.

## Gates

Before recording or scoring a run:

```powershell
pwsh -NoProfile -File scripts/test-cli-bakeoff-preflight.ps1 -Json
```

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
