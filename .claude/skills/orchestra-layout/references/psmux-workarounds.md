# psmux Layout Workarounds

Documented workarounds for psmux layout bugs tracked in psmux/psmux#171.

## Bug 1: resize-pane -x/-y Silent Fail

**Symptom**: `psmux resize-pane -t %1 -x 91` returns no error but pane size unchanged.

**Root cause**: `main.rs` parses `-x`/`-y` flags and appends to command string, but server
handler does not route to `CtrlReq::ResizePaneAbsolute`. The handler exists in `server/mod.rs`
but is unreachable from CLI.

**Workaround**: Do not use `-x`/`-y`. Use percentage-based splits during creation instead.

## Bug 2: split-window -l Aliased as Percentage

**Symptom**: `psmux split-window -h -l 91` creates a 91% split, not 91-cell split.

**Root cause**: `main.rs:829` maps both `-l` and `-p` to the same `size_pct` variable:
```rust
"-p" | "-l" => { size_pct = Some(cmd_args[i].to_string()); }
```

**Workaround**: Always use `-p` (percentage). Calculate cell-based sizes as percentages
relative to the parent pane.

## Bug 3: split-window -t Silently Ignored

**Symptom**: `psmux split-window -h -t %5` always splits the active pane, not %5.

**Root cause**: `main.rs` parses `-t` but skips its value:
```rust
"-t" | "-e" => { i += 1; /* skip value */ }
```

**Workaround**: Use `psmux select-pane -t %ID` before `split-window` to change the active
pane. The script captures pane IDs via `list-panes` and iterates with select-pane.

## Equal N-way Split Algorithm

To split a pane into N equal parts using only percentage-based 2-way splits:

```
For split i (0-indexed, 0 to N-2):
  percentage = 100 * (N - 1 - i) / (N - i)
```

Each split divides the active pane. The NEW pane receives the percentage and becomes active.

Example for 3 equal parts:
1. `split-window -p 67` → [33% original][67% new (active)]
2. `split-window -p 50` → [33%][33.5%][33.5%]

Example for 4 equal parts:
1. `split-window -p 75` → [25%][75% active]
2. `split-window -p 67` → [25%][25%][50% active]
3. `split-window -p 50` → [25%][25%][25%][25%]
