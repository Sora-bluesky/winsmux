# WB-021: Failure Taxonomy Report

You are one worker in a winsmux Harness Bench comparison run.

Create a failure taxonomy for scoreable and excluded runs. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_C_BEGIN`
2. Failure classes.
3. Exclusion reasons.
4. How the HTML report should show each class.
5. `BAKEOFF_ROUND_C_END`

Quality bar:

- Include missing key, timeout, crash, empty stdout, invalid output, and hidden test failure.
- Keep exclusion reasons distinct from low scores.
- Make the taxonomy useful for future worker assignment decisions.
