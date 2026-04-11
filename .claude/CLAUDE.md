# Claude Code in winsmux

Claude Code is the **recommended external operator** for winsmux.

winsmux assumes the operator can communicate through an external channel layer such as:

- Claude Code Channels
- Claude Code remote control
- other external user-to-operator channel surfaces

The design anchor is the **channel boundary**, not Telegram specifically.

## Recommended role

Use Claude Code outside the managed window as the primary operator when you need:

- planning and dispatch
- approval and review decisions
- git lifecycle control
- operator-facing status, explain, digest, and inbox workflows

Claude Code can also run inside a managed pane when explicitly assigned, but that is not the default control-plane model.

## winsmux model

winsmux splits responsibility into two layers:

- **Operator layer**
  - commonly Claude Code through Channels or remote control
  - owns user communication, orchestration, and final judgement
- **Managed pane layer**
  - Claude Code, Codex, Gemini, or other LLM CLIs in review-capable or execution-capable slots
  - performs implementation, investigation, verification, and assigned review work

Legacy `Builder / Researcher / Reviewer` pane layouts are compatibility mode only.
The current direction is slot and capability based.

## Quick start

```powershell
# Verify the environment
winsmux doctor

# Start the runtime session
winsmux new-session -s orchestra

# Launch the default managed layout
pwsh winsmux-core/scripts/orchestra-start.ps1
```

The default orchestra model is:

- one external operator terminal outside the managed window
- multiple managed `worker-*` panes inside the orchestra window
- optional compatibility mode for legacy role-specific layouts

## What Claude Code should assume

- The operator is external to the managed pane cluster by default.
- The operator communicates with users through a channel layer, not through direct pane ownership.
- Review is a slot capability and may be served by different panes over time.
- winsmux hooks and role gates are the enforcement surface; this file is guidance only.

## Practical commands

```powershell
# Inspect panes and labels
winsmux list

# Read before acting
winsmux read worker-1 30

# Dispatch work
winsmux send worker-2 "Investigate the failing source-control context state."

# Check readiness
winsmux health-check
```

## Related docs

- `README.md`
- `docs/operator-model.md`
- `GEMINI.md`
