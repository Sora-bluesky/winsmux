# Operator Model

winsmux is built around a **two-layer orchestration model**:

- an **external operator layer**
- a **managed pane layer**

This separation is the key to understanding how Claude Code, Codex, Gemini, and other LLM tools fit into winsmux.

## 1. External operator layer

The operator layer is where user communication, dispatch, approval, and final judgement happen.

The recommended operator is **Claude Code** because winsmux is designed to work well with:

- Claude Code Channels
- Claude Code remote control
- other external user-to-operator channel surfaces

The important abstraction is the **external channel boundary**.
Telegram, Discord, or another channel can sit on top of that boundary, but the architecture is not tied to one messaging product.

Typical operator responsibilities:

- talk to the user
- inspect `inbox`, `runs`, `explain`, and `digest`
- decide what to dispatch next
- request or interpret review
- own git lifecycle decisions

## 2. Managed pane layer

The managed pane layer is where multiple agent CLIs run inside winsmux-controlled panes or slots.

Examples:

- Claude Code
- Codex
- Gemini
- future local or hosted LLM CLIs

These panes are expected to work in parallel and may differ by:

- provider
- model
- review capability
- worktree assignment
- runtime role

The current direction is **slot/capability-based orchestration**, not hard-coded vendor roles.

## 3. Legacy layouts vs current model

Older `Commander / Builder / Researcher / Reviewer` pane layouts still exist for compatibility, but they are not the long-term architecture.

The current model is:

- one external operator
- multiple managed worker slots
- review handled by any review-capable slot

This means:

- `reviewer` is not required to be a permanent dedicated pane
- operator channels are not tied to Telegram specifically
- vendor identity does not define authority by itself

## 4. Public product docs vs contributor docs

Public product behavior should be read from:

- `README.md`
- `.claude/CLAUDE.md`
- `GEMINI.md`
- this file

Contributor and dogfooding operations may still exist in repo-facing docs such as:

- `AGENTS.md`
- `docs/handoff.md`

Those files describe how contributors and AI agents operate **inside this repository**.
They are not the public end-user guide for winsmux as a product.

## 5. UI/UX direction

The Tauri desktop direction follows the same operator model:

- **workspace sidebar** for sessions, explorer, open editors, and source control summary
- **conversation shell** as the primary operator surface
- **context side sheet** for run, slot, evidence, branch, and review state
- **secondary editor surface** for source-level drill-down
- **terminal drawer** for raw PTY and diagnostics only

This keeps the operator loop separate from the managed pane execution layer.
