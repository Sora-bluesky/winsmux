# Operator Model

winsmux is built around a **two-layer orchestration model**:

- an **external operator layer**
- a **managed pane execution layer**

This separation is the main contract of the product.

## 1. Standard control chain

The standard winsmux operating model is:

`User -> Claude Code (operator) -> pane agents`

That model means:

- the user communicates with the operator
- the operator coordinates work
- pane agents execute work
- pane agents do not communicate directly with the user
- pane agents do not communicate directly with each other

## 2. Operator layer

The operator layer is where:

- user communication
- dispatch
- approval
- review interpretation
- prioritization
- escalation
- final judgement

happen.

The recommended operator is **Claude Code**.
winsmux is designed to work well with:

- Claude Code Channels
- Claude Code remote control
- other external user-to-operator channel surfaces

The important abstraction is the **channel boundary**, not Telegram, Discord, or another single product.

In the standard winsmux operating model, the operator is responsible for:

- decomposition
- delegation
- result collection
- context alignment
- review decisions
- git lifecycle judgement

Direct file mutation or command execution by the operator is outside the standard winsmux operating model.

## 3. Pane execution layer

The managed pane layer is where agent CLIs run inside winsmux-controlled panes or slots.

Examples:

- Codex
- Gemini
- Claude Code when explicitly assigned to a pane
- future local or hosted LLM CLIs

Panes may differ by:

- provider
- model
- review capability
- worktree assignment
- runtime role

The current direction is **slot/capability-based orchestration**, not hard-coded vendor roles.

Review is handled by any **review-capable slot**, not by a permanently dedicated reviewer pane.

## 4. Public role-definition documents

The public contract is split across these files:

- `README.md`
- `.claude/CLAUDE.md`
- `AGENT-BASE.md`
- `AGENT.md`
- `GEMINI.md`
- this file

Their responsibilities are:

- `.claude/CLAUDE.md`
  - operator role definition
- `AGENT-BASE.md`
  - pane-wide shared execution contract
- `AGENT.md`
  - Codex-specific pane contract
- `GEMINI.md`
  - Gemini-specific pane contract

## 5. Public docs vs contributor docs

Contributor and dogfooding operations may still exist in repo-facing docs such as:

- `AGENTS.md`
- `docs/handoff.md`

Those files describe how contributors and AI agents operate **inside this repository**.
They are not the public end-user guide for winsmux as a product.

Dogfooding-specific rules do not define the public operator or pane contract.

## 6. Legacy layouts vs current model

Older `Commander / Builder / Researcher / Reviewer` pane layouts still exist for compatibility, but they are not the long-term architecture.

The current model is:

- one external operator
- multiple managed pane agents
- review handled by any review-capable slot

## 7. Tauri UI direction

The Tauri desktop direction follows the same contract:

- **workspace sidebar** for sessions, explorer, open editors, and source control summary
- **conversation shell** as the primary operator surface
- **context side sheet** for run, slot, evidence, branch, and review state
- **secondary editor surface** for source-level drill-down
- **terminal drawer** for raw PTY and diagnostics only

`TASK-286` aligns the timeline grammar with the docs contract:

- user message
- operator update
- system card
- pane result report

Pane result reports should follow the shared `AGENT-BASE.md` report shape:

- `STATUS`
- `TASK`
- `RESULT`
- `FILES_CHANGED`
- `ISSUES`
