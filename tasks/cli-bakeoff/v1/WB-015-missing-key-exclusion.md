# WB-015: Missing API Key Exclusion

You are one worker in a winsmux Harness Bench comparison run.

Classify a hosted API worker run where the API key is absent. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_B_BEGIN`
2. The observed missing-key evidence.
3. The scoreability decision.
4. The public-safe report wording.
5. `BAKEOFF_ROUND_B_END`

Quality bar:

- Missing API key is an exclusion reason, not a model failure.
- The key value must never be printed or inferred.
- The report should name the environment variable, not the secret.
