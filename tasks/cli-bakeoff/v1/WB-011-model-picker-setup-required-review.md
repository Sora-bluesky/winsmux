# WB-011: Model Picker Setup-Required Review

You are one worker in a winsmux Harness Bench comparison run.

Review the worker-pane model picker behavior for a hosted open-weight model.
Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_B_BEGIN`
2. The expected picker state for a local worker slot.
3. The expected picker state for an `api_llm` slot without a configured key.
4. The expected picker state for an `api_llm` slot with a configured key.
5. `BAKEOFF_ROUND_B_END`

Quality bar:

- Use the words setup-required, runnable, and blocked precisely.
- Identify the exact missing condition for a disabled assignment.
- Do not call a setup-required model unavailable.
