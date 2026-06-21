# WB-018: Invalid Output Exclusion

You are one worker in a winsmux Harness Bench comparison run.

Classify a worker run that completed but did not emit the required markers or
structured output. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_B_BEGIN`
2. Invalid-output evidence.
3. Scoreability decision.
4. Public-safe wording for the HTML report.
5. `BAKEOFF_ROUND_B_END`

Quality bar:

- Missing markers and invalid JSON are output-contract failures.
- Do not rely on self-reported success.
- The exclusion reason must be machine-readable.
