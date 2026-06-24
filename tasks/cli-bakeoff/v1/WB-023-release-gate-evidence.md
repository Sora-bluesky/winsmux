# WB-023: Release Gate Evidence

You are one worker in a winsmux Harness Bench comparison run.

Identify which benchmark and release-gate evidence is required before publishing
v0.36.17. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_C_BEGIN`
2. Required local gates.
3. Required GitHub checks.
4. Release-note evidence boundaries.
5. `BAKEOFF_ROUND_C_END`

Quality bar:

- Include public-surface audit and secret scan.
- Include the v0.36.17 ten-run Tauri launch soak reliability gate.
- Include PR, merge, and GitHub Release as completion gates.
- Do not mark the version 100% before the release is public.
