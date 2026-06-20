# WB-025: Hidden Test Result Schema

You are one worker in a winsmux Harness Bench comparison run.

Define the public-safe schema for reporting hidden test outcomes. Do not edit
files.

Return exactly this structure:

1. `BAKEOFF_ROUND_C_BEGIN`
2. Required hidden-test result fields.
3. Fields that must stay private.
4. How pass rate is calculated.
5. `BAKEOFF_ROUND_C_END`

Quality bar:

- Do not reveal hidden test fixtures or expected answers.
- Pass rate must be deterministic.
- Excluded runs must not enter the denominator.
