# Pre-GA v10 Planning Sync Note

This note records only the public-safe outcome of the pre-GA v10 planning sync.

## Release Sequence

- `v0.36.22` is complete and published.
- `v0.36.23` is the current working release, titled "Six-pane measurement and coordination reliability benchmark".
- `v0.36.23` covers `TASK-575`, `TASK-576`, `TASK-617`, and `TASK-618`.
- `v0.36.24` through `v0.36.33` cover pre-GA design, execution foundation, usability, API, security, distribution, and maintenance hardening.
- The six former `v0.36.24` tasks were moved to `v0.36.34` without changing their IDs, titles, bodies, or priorities.
- `TASK-545` remains the `v1.0.0` GA release task. Its dependency now points to the `v0.36.34` release gate, `TASK-615`.

## Validation Results

- Duplicate task IDs: 0.
- Orphan task dependencies: 0.
- Missing release titles for `v0.36.23` through `v0.36.34` and `v1.0.0`: 0.
- Unintended status changes in `v0.36.14` through `v0.36.23`: 0.
- Title, body, or priority changes in the six former `v0.36.24` tasks moved to `v0.36.34`: 0.

## Operating Rules

- Regenerate the generated roadmap from the canonical backlog.
- Do not hand-edit the generated roadmap as a planning-state fix.
- Treat browser previews, desktop E2E, packaged-app E2E, and official benchmark results as separate evidence.
- Do not mix mock runs or diagnostic overrides into official benchmark results.
- Do not include raw prompts, secrets, private environment paths, or raw logs in public artifacts.

## 2026-07-05 Re-scope Update

The Release Sequence section above records the original v10 sync snapshot. The
following changes were applied on 2026-07-05 (user-approved; decision record:
`docs/incidents/v03623-session-readiness/04-benchmark-readiness-gate.md`,
PR #1136):

- `v0.36.23` was re-scoped to the six-pane bring-up release (generated-roadmap
  title updated accordingly). `TASK-618` remains its release gate, re-scoped
  to the bring-up evidence.
- `TASK-575` and `TASK-576` (the official 27-task Harness Bench measurement
  and the Japanese HTML report) moved to the new `v0.36.43` GA-readiness bench
  lane, which depends on the `v0.36.39` Harness Bench productization gate
  (`TASK-737`).
- The `v0.36.39` lane gained `TASK-765` through `TASK-768` (bench-runner
  echo-race fix #1134, Codex-pane dispatch fix #1135, desktop PTY child
  cleanup #1137, one-click bench launch #1139); `TASK-737` now depends on
  them.
- The roadmap was regenerated from the canonical backlog after the change;
  the title and consistency gates passed.
