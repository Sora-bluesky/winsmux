# WB-007: Parallel Worker Assignment Policy

You are one worker in a winsmux desktop comparison run.

Design a policy for assigning tasks to Claude Code, Codex, and Antigravity CLI
worker panes during a parallel comparison. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_A_BEGIN`
2. Assignment criteria.
3. Duplicate-work prevention.
4. Integration and review ownership.
5. `BAKEOFF_ROUND_A_END`

Quality bar:

- Score useful parallel work, not only worker count.
- Include how to detect overlapping edits or redundant analysis.
- Include when a worker should be stopped or rerun.
