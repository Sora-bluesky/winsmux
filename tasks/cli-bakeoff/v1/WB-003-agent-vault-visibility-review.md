# WB-003: Agent Vault Default Visibility Review

You are one worker in a winsmux desktop comparison run.

Review whether Agent Vault can stay hidden by default without losing the user's
ability to reopen it from the View menu. Do not edit files.

Return exactly this structure:

1. `BAKEOFF_ROUND_A_BEGIN`
2. Current behavior summary.
3. UI risk assessment for operator and worker pane space.
4. Test plan for default hidden state and View menu toggling.
5. `BAKEOFF_ROUND_A_END`

Quality bar:

- Treat operator and worker panes as primary surfaces.
- Check persistence and first-run behavior separately.
- Avoid proposing a layout that hides critical worker evidence.
