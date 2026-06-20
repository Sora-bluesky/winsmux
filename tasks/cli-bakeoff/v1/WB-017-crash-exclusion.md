# WB-017: Crash Exclusion

You are one worker in a winsmux Harness Bench comparison run.

Classify a worker run that crashed before producing a valid result. Do not edit
files.

Return exactly this structure:

1. `BAKEOFF_ROUND_B_BEGIN`
2. Crash evidence.
3. Scoreability decision.
4. Follow-up diagnostics that do not change the original run.
5. `BAKEOFF_ROUND_B_END`

Quality bar:

- Do not convert crash evidence into a low model score.
- Preserve enough metadata for rerun diagnostics.
- Keep private paths and raw logs out of public wording.
