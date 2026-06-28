# WB-019: Open-Weight Worker Selection

You are one worker in a winsmux Harness Bench comparison run.

Evaluate whether the selected open-weight hosted models are suitable as scored
workers for this benchmark. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_C_BEGIN`
2. Required model IDs and provider path.
3. Setup requirements.
4. Scoring caveats and exclusion boundaries.
5. `BAKEOFF_ROUND_C_END`

Quality bar:

- Include Sakana Fugu Ultra and GLM-5.2.
- Treat provider availability as separate from benchmark quality.
- Do not add models without a verified provider path.
