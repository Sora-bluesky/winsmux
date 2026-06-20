# WB-024: Worker Pane Assignment Plan

You are one worker in a winsmux Harness Bench comparison run.

Plan pane assignments for a cohort run with more scored workers than visible
panes. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_C_BEGIN`
2. Cohort split.
3. Invariants that must stay identical across cohorts.
4. Evidence needed to compare cohorts.
5. `BAKEOFF_ROUND_C_END`

Quality bar:

- Operator is not scored.
- Same task set, timeout, and workspace policy across cohorts.
- Do not duplicate worker tasks unless a rerun is explicitly marked.
