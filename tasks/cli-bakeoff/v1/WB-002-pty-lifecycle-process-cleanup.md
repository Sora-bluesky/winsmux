# WB-002: PTY Lifecycle And Process Cleanup

You are one worker in a winsmux desktop comparison run.

Analyze how winsmux should prevent background `pwsh`, `node`, `cargo`, or
desktop child processes from remaining after app shutdown or pane reset. Do not
edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_A_BEGIN`
2. Root-cause hypothesis with repository file references.
3. Proposed permanent fix, including shutdown and pane-reset paths.
4. Verification plan for Windows process cleanup.
5. `BAKEOFF_ROUND_A_END`

Quality bar:

- Separate app exit, pane close, and test-run cleanup.
- Include a bounded wait and forced cleanup policy.
- Include how to avoid killing unrelated user processes.
