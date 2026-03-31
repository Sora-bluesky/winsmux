# Agent Selection Guide

Guidelines for choosing which CLI agent to assign each task type in a multi-vendor Orchestra.

## Task-to-CLI Mapping

| Task Type                     | Recommended CLI       | Reason                                                       |
| ----------------------------- | --------------------- | ------------------------------------------------------------ |
| Large file structure analysis | Codex                 | Gemini Pro took 2+ min for 191 files; Codex completed in 20s |
| Single file summary           | Any                   | No significant difference                                    |
| Code review                   | Codex                 | Fast response (~90s for multi-builder review)                |
| Investigation / analysis      | Claude Sonnet         | Best balance of accuracy and speed (~30s)                    |
| Parallel implementation       | Codex or Gemini Flash | Both respond quickly; assign independent file sets           |

## Approval-Free Flags (with Shield Harness)

| CLI         | Flag                                  | Notes                                   |
| ----------- | ------------------------------------- | --------------------------------------- |
| Claude Code | `--permission-mode bypassPermissions` | Shield Harness hooks provide safety net |
| Codex CLI   | `--full-auto`                         | Sandboxed automatic execution           |
| Gemini CLI  | `--yolo`                              | All tool calls auto-approved            |

Without Shield Harness: no flags are added (manual approval mode).

## Known Limitations

- **Gemini Pro**: Slow on large-scale file processing. Use for focused tasks, not bulk analysis.
- **Codex (gpt-5.3-codex-spark)**: Smaller context window. Send reviewer diffs in small batches (max 3 files/message).
- **Gemini CLI**: Orphaned processes after session end. Run cleanup: `taskkill /F /IM node.exe /FI "WINDOWTITLE eq gemini*"`
