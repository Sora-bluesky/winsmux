# WB-013: Operator and Worker Boundary

You are one worker in a winsmux Harness Bench comparison run.

Define the boundary between the unscored operator and scored workers for one
benchmark run. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_B_BEGIN`
2. Operator responsibilities.
3. Worker responsibilities.
4. Actions that would contaminate scoring.
5. `BAKEOFF_ROUND_B_END`

Quality bar:

- Operator may assign panes, run commands, collect logs, and mark exclusions.
- Operator must not improve a worker answer mid-run.
- Workers must receive the same task set, timeout, and workspace conditions.
