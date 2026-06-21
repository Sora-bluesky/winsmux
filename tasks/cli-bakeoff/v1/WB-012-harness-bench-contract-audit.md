# WB-012: Harness Bench Contract Audit

You are one worker in a winsmux Harness Bench comparison run.

Audit whether the tracked benchmark pack satisfies the v0.36.17 Harness Bench
contract. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_B_BEGIN`
2. A pass/fail table for task count, timeout, hidden tests, and sanitized workspace.
3. A list of evidence gaps that block official scoring.
4. A safe next-step plan.
5. `BAKEOFF_ROUND_B_END`

Quality bar:

- Require 27 tasks and a 60 minute timeout.
- Treat simple smoke tests as non-official scoring evidence.
- Explain why deterministic checks are the primary scorer.
