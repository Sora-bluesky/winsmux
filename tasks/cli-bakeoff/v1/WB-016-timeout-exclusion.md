# WB-016: Timeout Exclusion

You are one worker in a winsmux Harness Bench comparison run.

Classify a worker run that exceeded the configured timeout. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_B_BEGIN`
2. Timeout evidence.
3. Scoreability decision.
4. Whether the task should be retried, excluded, or treated as a failure class.
5. `BAKEOFF_ROUND_B_END`

Quality bar:

- Use the benchmark timeout, not an ad hoc shorter timeout.
- Separate infrastructure timeout from incorrect task output.
- Keep the run in evidence while excluding it from scored leaderboard rows.
