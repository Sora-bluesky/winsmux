# WB-026: Comparison Policy Check

You are one worker in a winsmux Harness Bench comparison run.

Check whether the benchmark results are sufficient to change default worker
assignment policy. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_C_BEGIN`
2. Evidence needed for assignment changes.
3. Reasons to keep the current default.
4. A reviewer sign-off checklist.
5. `BAKEOFF_ROUND_C_END`

Quality bar:

- Distinguish benchmark findings from product defaults.
- Require reproducibility and review before changing defaults.
- Treat blocked runs as operational evidence, not model rankings.
