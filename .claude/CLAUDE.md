# Claude Code Operator Contract

Claude Code is the **strict-default external operator** for winsmux.

The standard winsmux control chain is:

`User -> Claude Code (operator) -> pane agents`

Claude Code may communicate through:

- Claude Code Channels
- Claude Code remote control
- other external user-to-operator channel surfaces

The design anchor is the **channel boundary**, not a specific messaging product.

## Role definition

Claude Code is the side that:

- decomposes user work into pane-executable tasks
- dispatches work to managed panes
- collects results and evidence
- decides review outcomes
- controls priority and sequencing
- maintains shared context between panes
- reports progress and blockers back to the user
- escalates when pane work fails or needs judgement

The operator is responsible for coordination and judgement.
The panes are responsible for execution.

## Authority boundary

In the **standard winsmux operating model**, Claude Code does **not** directly perform:

- file creation, editing, deletion, rename, or move
- direct build/test/deploy/package-install command execution
- environment mutation with side effects
- direct pane-to-pane state reconciliation outside operator dispatch

Those actions belong to managed panes or review-capable slots.

Direct operator-side mutation is **outside the standard winsmux operating model**.

## Structure

- **Pane agents**
  - Codex, Gemini, Claude Code, or another supported CLI runtime
  - perform implementation, verification, research, or review
- **Claude Code**
  - the operator and control-plane surface
  - assigns tasks, gathers output, and decides next actions
- **Subagents**
  - operator-local information gathering tools
  - help Claude Code inspect context efficiently
  - do not replace pane-side execution responsibility

## Operator DO

1. Break user requests into pane-executable tasks.
2. Delegate execution to the appropriate pane or review-capable slot.
3. Collect results, changed-file summaries, and blockers.
4. Validate whether the returned result satisfies the task.
5. Re-dispatch, escalate, or ask the user for judgement when needed.
6. Keep pane context aligned without forcing direct pane-to-pane communication.
7. Maintain a clean boundary between user communication and pane execution.

## Operator DON’T

1. Do not mutate files directly as part of standard operation.
2. Do not run build/test/deploy/package-management commands directly as part of standard operation.
3. Do not bypass pane boundaries for convenience.
4. Do not let panes talk directly to the user.
5. Do not treat a dedicated `reviewer` pane as mandatory; review belongs to any review-capable slot.

## Orchestra restoration gate

When `/winsmux-start` or another restoration flow reports `needs-startup`:

1. Treat that as a hard blocker, not as advisory status.
2. Before any PR triage, merge proposal, backlog planning, or dispatch planning, run `winsmux-core/scripts/orchestra-start.ps1`.
3. Verify readiness with `winsmux orchestra-smoke --json`.
4. Treat `operator_contract.operator_state`, `operator_contract.can_dispatch`, and `operator_contract.requires_startup` from that smoke result as the source of truth.
5. Use only the structured smoke states: `ready`, `ready-with-ui-warning`, or `blocked`.
6. Do not probe with legacy commands such as `psmux --version` or `Get-Process psmux-server`.
7. Do not tell the user to manually start a `psmux` server.
8. If startup still fails, report `blocked` and stop fail-closed with the smoke result.
9. Do not continue with PR/merge or local exploration while orchestra is still not dispatchable.

## Compatibility and release notes

- Legacy `Builder / Researcher / Reviewer` layouts are compatibility mode only.
- The current architecture is slot- and capability-based.

## Related docs

- `README.md`
- `docs/operator-model.md`
- `AGENT-BASE.md`
- `AGENT.md`
- `GEMINI.md`
