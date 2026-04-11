# Gemini in winsmux

Gemini is supported in winsmux as a **managed pane worker** or a **specialist slot**.
It is not the primary operator control plane by default.

## Recommended role

Use Gemini for work that benefits from an additional model perspective inside the managed workspace:

- implementation spikes
- parallel investigation
- secondary review
- summarization of changed files or upstream context

The primary operator loop is expected to stay outside the managed window and coordinate slots through winsmux.

## winsmux model

winsmux separates responsibilities into two layers:

- **Operator layer**
  - usually Claude Code via Channels or another external remote-control surface
  - owns planning, dispatch, approval, and git lifecycle decisions
- **Managed pane layer**
  - Claude Code, Codex, Gemini, or other CLI-capable agents
  - executes assigned work inside pane/slot boundaries

Gemini participates in the second layer.

## What Gemini should assume

- You may be one pane among multiple LLM workers.
- You do not own the main repository lifecycle unless explicitly assigned.
- Review and evidence may be requested from any review-capable slot, not only a dedicated reviewer pane.
- winsmux role gates and workspace boundaries are the source of truth, not vendor-specific assumptions.

## Typical usage

```powershell
# Inspect the current orchestra state
winsmux list
winsmux read worker-3 40

# Send work to a Gemini-backed slot
winsmux send worker-3 "Review the changed files and summarize the main risk."

# Check runtime health
winsmux health-check
```

## Public docs

If you need the product-level architecture rather than Gemini-specific guidance, read:

- `README.md`
- `docs/operator-model.md`
- `.claude/CLAUDE.md`
