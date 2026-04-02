# Role Definitions for winsmux Orchestra

This document defines the operational contract for the four Orchestra roles in winsmux: `Commander`, `Builder`, `Researcher`, and `Reviewer`.

`psmux-bridge/scripts/role-gate.ps1` is the hard gate for pane-level command permissions. `scripts/start-orchestra.ps1` is the operational prompt layer for the Commander. This document aligns both layers and is the human-readable source for day-to-day role separation.

## Core Separation Rules

- `Commander` orchestrates work, judges outcomes, and performs git decisions such as commit, merge, or rejection.
- `Commander` never writes code, never edits project files directly, and never performs code review directly.
- `Builder` implements code only in the explicitly assigned worktree and file scope.
- `Builder` never reads other panes and never performs git commit, merge, or push.
- `Researcher` analyzes, tests, and investigates.
- `Researcher` never modifies code, never edits project files, and never performs review.
- `Reviewer` performs code quality, architecture, and security review only.
- `Reviewer` never implements fixes and never performs git commit, merge, or push.
- `Commander` dispatches reviews to `Reviewer`; the Commander does not self-review.
- `Commander` reads the `Reviewer` verdict and findings summary, not the code as a substitute for review.

## Enforcement Model

- Hard enforcement: [`psmux-bridge/scripts/role-gate.ps1`](/C:/Users/komei/Documents/Projects/apps/winsmux-b1/psmux-bridge/scripts/role-gate.ps1) restricts which `psmux-bridge` commands each role can execute.
- Operational enforcement: [`scripts/start-orchestra.ps1`](/C:/Users/komei/Documents/Projects/apps/winsmux-b1/scripts/start-orchestra.ps1) instructs the Commander to delegate implementation to Builders and review to Reviewers.
- Process enforcement: the workflow below requires Builder completion before Reviewer dispatch, and Reviewer verdict before Commander commit or merge.

## Commander

Responsibility: Orchestrate the workflow, assign work, judge outcomes from agent reports, and perform final git decisions.

Allowed actions:

- Break user work into tasks and decide execution order.
- Dispatch implementation to one or more Builders with explicit file or worktree boundaries.
- Dispatch investigation, testing, and diagnostic work to Researchers.
- Dispatch code review to Reviewers after Builder work completes.
- Poll panes, read status, and consume findings, summaries, and verdicts from other roles.
- Judge whether work is accepted, rejected, or returned for rework based on Researcher and Reviewer outputs.
- Resolve task sequencing, conflict handling, and merge readiness.
- Run git staging, commit, merge, branch cleanup, and related release-control commands.
- Manage orchestration utilities such as health checks, watch/wait operations, and vault access.
- Use `psmux-bridge send` or `message` to communicate with any role.
- Use own-pane input commands for Commander-local terminal actions.

Prohibited actions:

- Writing code directly.
- Editing project files directly.
- Implementing fixes instead of dispatching them to a Builder.
- Reviewing code directly.
- Replacing the Reviewer verdict with the Commander's own inspection.
- Skipping Reviewer dispatch and approving Builder output alone.
- Asking a Reviewer to implement fixes.
- Typing into or sending special keys to another pane directly through low-level input commands.

Allowed `psmux-bridge` commands (`role-gate.ps1`):

- `read` on own pane and other panes
- `send` to any pane
- `message` to any pane
- `health-check`
- `watch`
- `wait-ready`
- `vault`
- `dispatch`
- `type` on own pane only
- `clipboard-paste` on own pane only
- `image-paste` on own pane only
- `ime-input` on own pane only
- `keys` on own pane only
- `list`
- `id`
- `version`
- `doctor`

## Builder

Responsibility: Implement approved code changes only within the assigned worktree and file scope.

Allowed actions:

- Modify source code, tests, configuration, and documentation only when those files are explicitly assigned.
- Implement fixes requested by the Commander.
- Work only inside the assigned worktree and assigned file boundary.
- Run local build, test, lint, or formatting commands needed to complete the assigned implementation.
- Report status, blockers, completion, and file ownership back to the Commander.
- Send messages only to the Commander.
- Use own-pane input commands for Builder-local terminal actions.

Prohibited actions:

- Reading other panes.
- Accessing another Builder's, Researcher's, Reviewer's, or Commander's pane.
- Dispatching work to other roles.
- Reviewing code.
- Judging release readiness.
- Performing git commit, merge, push, reset, or branch management.
- Changing files outside the assigned worktree or assigned file boundary.
- Reading secrets through vault commands.

Allowed `psmux-bridge` commands (`role-gate.ps1`):

- `read` on own pane only
- `send` to Commander only
- `message` to Commander only
- `type` on own pane only
- `clipboard-paste` on own pane only
- `image-paste` on own pane only
- `ime-input` on own pane only
- `keys` on own pane only
- `list`
- `id`
- `version`
- `doctor`

## Researcher

Responsibility: Analyze code, investigate impact, and verify behavior through tests and diagnostics without changing implementation.

Allowed actions:

- Inspect repository structure, dependencies, and code paths.
- Investigate impact, edge cases, failure modes, and integration risks.
- Run tests, lint, type checks, builds, and other verification commands.
- Collect logs, diagnostics, and reproducible evidence for the Commander.
- Produce implementation guidance, reproduction steps, and verification results for the Commander.
- Send messages only to the Commander.
- Use own-pane input commands for Researcher-local terminal actions.

Prohibited actions:

- Modifying source code.
- Editing project files.
- Implementing fixes.
- Reviewing code for approval or rejection.
- Dispatching work to other roles.
- Performing git commit, merge, push, reset, or branch management.
- Reading other panes.
- Reading secrets through vault commands.

Allowed `psmux-bridge` commands (`role-gate.ps1`):

- `read` on own pane only
- `send` to Commander only
- `message` to Commander only
- `type` on own pane only
- `clipboard-paste` on own pane only
- `image-paste` on own pane only
- `ime-input` on own pane only
- `keys` on own pane only
- `list`
- `id`
- `version`
- `doctor`

## Reviewer

Responsibility: Review completed Builder output for code quality, correctness, security, and maintainability, then return a verdict to the Commander.

Allowed actions:

- Review Builder-produced diffs, summaries, and scoped code excerpts.
- Evaluate quality, correctness, tests, regressions, architecture, and security.
- Return verdicts such as approve, reject, or request changes to the Commander.
- Describe concrete findings and required follow-up work.
- Send messages only to the Commander.
- Use own-pane input commands for Reviewer-local terminal actions.

Prohibited actions:

- Writing or modifying code.
- Implementing fixes.
- Editing project files.
- Running git commit, merge, push, reset, or branch management.
- Dispatching work to other roles.
- Reading other panes.
- Taking over Builder work after finding defects.
- Acting as the final merger or release approver.

Allowed `psmux-bridge` commands (`role-gate.ps1`):

- `read` on own pane only
- `send` to Commander only
- `message` to Commander only
- `type` on own pane only
- `clipboard-paste` on own pane only
- `image-paste` on own pane only
- `ime-input` on own pane only
- `keys` on own pane only
- `list`
- `id`
- `version`
- `doctor`

## Workflow Diagram

`User -> Commander -> dispatch to Builder -> Builder completes -> Commander dispatches to Reviewer -> Reviewer reports verdict -> Commander merges or rejects`

## Anti-Patterns

- Commander reviewing code directly: violates separation of duties and bypasses the Reviewer gate.
- Commander writing files: implementation belongs to the Builder role.
- Builder accessing other panes: breaks pane isolation and role containment.
- Skipping Reviewer: bypasses the quality and security gate before commit or merge.

## Operational Notes

- The Commander may read pane output for coordination, but must not substitute that access for direct code review.
- Builder, Researcher, and Reviewer are intentionally asymmetrical: they can report only to the Commander, not to each other.
- If the Reviewer rejects work, the Commander routes the findings back to a Builder; the Reviewer does not fix the issue.
- If the Researcher finds risk or missing evidence, the Commander decides whether to send more research work, more Builder work, or both.
