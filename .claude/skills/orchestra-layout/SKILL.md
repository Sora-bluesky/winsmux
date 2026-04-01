---
name: orchestra-layout
description: |
  Deterministic psmux grid layout creation for Orchestra multi-agent configurations.
  Creates Builder/Researcher/Reviewer pane grids in one command using percentage-based
  splits. Use this skill whenever setting up Orchestra panes, creating multi-agent
  layouts, configuring builder/researcher/reviewer grids, or any request involving
  "pane layout", "Orchestra setup", "split panes", "create grid", or specifying agent
  counts like "4 builders 1 researcher 1 reviewer". Always use this instead of manually
  running split-window commands — manual pane creation wastes tokens and is unreliable
  due to psmux resize bugs (psmux/psmux#171).
user-invocable: false
allowed-tools: Bash
---

# Orchestra Layout

Create deterministic psmux pane grids for Orchestra multi-agent configurations.
Replaces manual split-window trial-and-error with a single script invocation.

## Why This Skill Exists

Manual pane creation via split-window/resize-pane commands is unreliable because:
- `resize-pane -x/-y` silently fails (CLI parses flags but server ignores them)
- `split-window -l` is aliased as percentage (not cell count)
- `split-window -t` is silently ignored (always splits active pane)

The script works around all three bugs using `split-window -p` (percentage-based) splits
with a chained formula that produces equal partitions: `pct[i] = 100*(N-1-i)/(N-i)`.

## Step 1: Run the Layout Script

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/orchestra-layout.sh" <PRESET>
```

### Preset Format

`NbNrNv` — N = count, b = builder, r = researcher, v = reviewer.

| Preset | Agents | Grid |
|--------|--------|------|
| `4b1r1v` | 4 builders + 1 researcher + 1 reviewer | 2x3 |
| `3b1r1v` | 3 builders + 1 researcher + 1 reviewer | 2x3 |
| `2b1r1v` | 2 builders + 1 researcher + 1 reviewer | 2x2 |
| `2b1r` | 2 builders + 1 researcher | 1x3 |
| `1b1r` | 1 builder + 1 researcher | 1x2 |

Default preset: `4b1r1v`

## Step 2: Use Pane IDs for Agent Dispatch

The script outputs pane IDs and role labels:

```
=== Orchestra Layout: 4b1r1v → 2x3 grid ===
Panes:
  %1 → Builder-1
  %4 → Builder-2
  %5 → Builder-3
  %3 → Builder-4
  %6 → Researcher-1
  %7 → Reviewer-1
Done.
```

Use these IDs to send commands to each pane:

```bash
psmux send-keys -t %1 "codex exec --model gpt-5.3-codex-spark --full-auto 'task'" Enter
```

## Examples

### Example 1: Standard Orchestra (4 builders + 1 researcher + 1 reviewer)

Commander receives: "4ビルダー、1リサーチャー、1レビュアーでペインを構成して"

Action:
```bash
bash "${CLAUDE_SKILL_DIR}/scripts/orchestra-layout.sh" 4b1r1v
```

Result: 2x3 grid with labeled panes, ready for agent dispatch.

### Example 2: Minimal Setup (2 builders + 1 reviewer)

Commander receives: "2ビルダー1レビュアーで"

Action:
```bash
bash "${CLAUDE_SKILL_DIR}/scripts/orchestra-layout.sh" 2b1v
```

Result: 1x3 grid (3 panes in one row).

## Troubleshooting

### Error: "psmux: no server running"

**Cause**: psmux server not started or was killed.

**Solution**: The script auto-starts a new session via `psmux new-session -d`.
If this fails, verify psmux binary is in PATH.

### Pane sizes are unequal

**Cause**: The percentage formula produces near-equal splits (±0.5%), not pixel-perfect.
For 3 columns: 33% | 33.5% | 33.5%. This is expected and acceptable.

### select-pane -T labels not showing

**Cause**: pane-border-status may not be enabled.

**Solution**: Ensure psmux is configured with `pane-border-status top` or `bottom`.

## Constraints

- The script creates a new window in the existing psmux session (does not kill other windows)
- Maximum 12 panes (3x4 grid)
- Grid cells beyond total pane count remain as empty shells
- Pane IDs are auto-assigned; use the script output to map IDs to roles

## Reference Files

- [psmux workarounds](references/psmux-workarounds.md) — Known psmux bugs and workaround details
