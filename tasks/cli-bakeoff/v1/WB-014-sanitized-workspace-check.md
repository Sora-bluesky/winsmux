# WB-014: Sanitized Workspace Check

You are one worker in a winsmux Harness Bench comparison run.

Inspect the benchmark setup and describe how the workspace should be sanitized
before a scored worker run. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_B_BEGIN`
2. Required workspace reset steps.
3. Files and paths that must not enter public evidence.
4. A rerun-safe verification checklist.
5. `BAKEOFF_ROUND_B_END`

Quality bar:

- Exclude raw logs, user paths, account IDs, and provider request IDs from public output.
- Keep task packets tracked and evidence directories untracked.
- Require the same sanitized baseline for every worker.
