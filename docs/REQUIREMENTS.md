# winsmux Requirements

> Date: 2026-04-02
> Status: Draft

## 1. Introduction

winsmux is a multi-vendor agent orchestration platform for Windows. It provides a Windows-native runtime and control plane for operating multiple CLI agents, including Claude, Codex, Gemini, and compatible custom agents, inside visible `psmux` panes with operator control, governance, and security boundaries.

This requirements document defines the product scope for the following winsmux subsystems:

- `psmux-bridge` CLI
- Orchestra
- Shield Harness integration
- Credential Vault

The document covers both currently implemented capabilities and target capabilities required for the next production-grade release. Requirement statements use normative language: winsmux "shall" satisfy each requirement.

## 2. Functional Requirements

| ID | Title | Requirement |
| --- | --- | --- |
| FR-001 | Cross-pane agent communication | winsmux shall provide cross-pane communication through `psmux-bridge`, including pane discovery, pane addressing by ID or label, pane reading, text sending, key dispatch, message sending, focus switching, and pane labeling. |
| FR-002 | Role-based command gate | winsmux shall enforce command authorization by role for `Commander`, `Builder`, `Researcher`, and `Reviewer`, and shall deny unknown or unauthorized commands by default. |
| FR-003 | Credential vault with DPAPI encryption | winsmux shall store, retrieve, list, and inject credentials by using Windows Credential Manager and DPAPI-backed protection without requiring `.env` files in the repository. |
| FR-004 | Orchestra startup automation | winsmux shall start Orchestra from a single operator action, including `Prefix+O`, create or refresh the orchestration session, label panes, assign roles, launch agents, and wait until agents are ready. |
| FR-005 | Hierarchical settings | winsmux shall resolve settings with the precedence order `project > global > wizard baseline`, where project settings override global settings and the setup wizard establishes initial global values. |
| FR-006 | Mailbox-based async routing | winsmux shall support mailbox-based asynchronous message routing over named pipes with JSON payload validation, point-to-point delivery, broadcast delivery, and bounded retry behavior. |
| FR-007 | Shared task list and dependency resolution | winsmux shall maintain a shared task list that supports task creation, claiming, completion, dependency tracking, blocked/open transitions, and next-available task selection. |
| FR-008 | Agent lifecycle monitoring and auto-respawn | winsmux shall monitor labeled agent panes, classify health states, and automatically respawn hung or dead agents by reusing the last known launch configuration. |
| FR-009 | JSON-RPC 2.0 endpoint | winsmux shall expose a JSON-RPC 2.0 endpoint for remote orchestration operations, including bridge actions and shared task operations, with structured success and error responses. |
| FR-010 | MCP Server integration | winsmux shall provide an MCP Server integration layer that exposes orchestration capabilities to external agent runtimes by adapting core winsmux operations into MCP-compatible tools and resources. |
| FR-011 | Shield Harness STG gates | winsmux shall support Shield Harness STG gates so that approval-free or policy-sensitive operations are evaluated against configured governance rules before dispatch. |
| FR-012 | Evidence ledger | winsmux shall capture an evidence ledger for governed runs, including prompt summaries, actor role, target pane, approval outcome, task linkage, review outcome, timestamps, and secret-redacted execution evidence. |
| FR-013 | Channel security | winsmux shall secure communication channels by validating channel names, rejecting malformed payloads, constraining delivery targets, and preventing unauthorized routing across panes or roles. |
| FR-014 | Read Guard and interaction watermark | winsmux shall enforce read-before-act for interactive pane operations and shall provide watermark-based change detection so follow-up reads can distinguish "no new output" from "new output received." |
| FR-015 | File and workspace locking | winsmux shall provide race-safe file locking for coordinated multi-agent work, including lock acquisition, lock release, lock listing, rival-lock denial, and stale-lock expiry handling. |
| FR-016 | Health visibility and diagnostics | winsmux shall provide operator-visible health and diagnostics, including `READY`, `BUSY`, `HUNG`, and `DEAD` states, environment diagnostics, and pane-level visibility suitable for live supervision. |
| FR-017 | Commander task-event notifications | winsmux shall notify Commander targets when shared tasks are created, completed, or unblocked so that orchestration can continue without manual polling for every task transition. |
| FR-018 | Windows Terminal integration and pane labels | winsmux shall integrate with Windows Terminal fragments and pane title labeling so operators can launch named Orchestra profiles and visually identify panes by role or label. |
| FR-019 | Setup wizard and bootstrap flow | winsmux shall provide an interactive setup wizard that collects baseline agent settings, model choice, role counts, and optional vault bootstrap data for first-time configuration. |
| FR-020 | Vendor-neutral runtime abstraction | winsmux shall define a vendor-neutral runtime abstraction for launching, monitoring, and coordinating supported agent CLIs, starting with Codex and Claude and remaining extensible to Gemini and custom shell agents. |

## 3. Non-Functional Requirements

| ID | Requirement |
| --- | --- |
| NFR-001 | All security decisions shall fail closed. If winsmux cannot validate a role, command, channel, payload, or policy outcome, the operation shall be denied. |
| NFR-002 | winsmux shall not place plaintext secrets in process arguments, repository files, or terminal history when a secure alternative is available. |
| NFR-003 | Role-gate enforcement coverage shall be at least 80% of user-accessible orchestration commands in the production release. |
| NFR-004 | Agent crash or hang recovery shall complete in less than 30 seconds from confirmed unhealthy state to relaunch attempt under nominal local conditions. |
| NFR-005 | winsmux shall support at least 15 concurrent agents within a single orchestrated workspace on a supported Windows host. |

## 4. Acceptance Criteria

| FR | Testable acceptance criteria |
| --- | --- |
| FR-001 | Given labeled panes, `psmux-bridge list`, `read`, `send`, `message`, `keys`, `focus`, `name`, and `resolve` shall succeed against valid targets and fail with explicit errors for invalid targets. |
| FR-002 | Given each supported role, authorized commands shall succeed, unauthorized commands shall return `DENIED`, and unknown commands shall be denied without side effects. |
| FR-003 | A credential stored through the vault shall be retrievable on the same machine, absent from repo files, and injectable into a target pane without writing plaintext secrets to disk. |
| FR-004 | Triggering Orchestra from `Prefix+O` or an equivalent startup command shall create the session, label panes, assign role environment variables, launch agents, and report readiness or a startup error for each pane. |
| FR-005 | If the same setting exists in wizard baseline, global settings, and project settings, the effective value shall come from project settings; if project is absent, global shall win; if both are absent, the wizard baseline or built-in default shall apply. |
| FR-006 | A valid mailbox JSON message shall route to the intended pane or panes, a `broadcast` target shall exclude the sender, malformed JSON shall be rejected, and undeliverable targets shall retry no more than three times. |
| FR-007 | A task with unsatisfied dependencies shall remain `blocked`, shall become `open` after dependencies complete, shall be claimable by one agent at a time, and shall retain an auditable state transition history in the shared store. |
| FR-008 | A pane classified as `HUNG` or `DEAD` shall trigger an automatic restart using cached launch data, and the pane shall return to a monitored state without requiring operator reconfiguration. |
| FR-009 | The JSON-RPC endpoint shall accept valid `jsonrpc: "2.0"` requests, reject malformed requests with JSON-RPC error codes, and expose bridge and task operations with structured responses. |
| FR-010 | An MCP client shall be able to invoke winsmux orchestration capabilities through MCP-compatible tools, and those calls shall still honor winsmux role and policy enforcement. |
| FR-011 | When Shield Harness STG gates are enabled, a gated operation shall not dispatch unless the relevant policy evaluation succeeds; denied or indeterminate evaluations shall block execution and produce evidence. |
| FR-012 | For a governed run, winsmux shall emit evidence records that link request context, role, pane target, approval result, execution outcome, and review result, while redacting secrets from stored records. |
| FR-013 | Channel names outside the allowed character set shall be rejected, malformed mailbox or RPC payloads shall not be delivered, and unauthorized cross-role routing attempts shall fail without delivery. |
| FR-014 | `type`, `keys`, `message`, and vault injection shall require a prior read mark, and a read performed after `send` shall return a waiting indicator until pane content changes. |
| FR-015 | A second agent attempting to lock an already locked file shall receive a denial, the original lock owner shall be able to unlock it, and locks older than the configured expiry window shall be releasable as stale. |
| FR-016 | `health-check` and related diagnostics shall report pane status in the set `READY`, `BUSY`, `HUNG`, `DEAD`, and `doctor` shall surface missing prerequisites or environment problems with actionable output. |
| FR-017 | When a task is created, completed, or newly unblocked, Commander targets shall receive a notification message or a logged notification failure within the watcher process. |
| FR-018 | Registering a Windows Terminal profile shall create a fragment with a named Orchestra launch entry, and pane labels shall be visible through pane title formatting when the psmux border settings are enabled. |
| FR-019 | The setup wizard shall collect agent, model, builder count, researcher count, reviewer count, and optional GH token storage, then persist the selected baseline settings without requiring manual file edits. |
| FR-020 | The runtime abstraction shall generate valid launch behavior for supported CLIs, surface explicit errors for unsupported agents, and separate vendor-specific launch flags from winsmux role and session semantics. |

## 5. Traceability Matrix

| FR | TASK mapping | Primary scope |
| --- | --- | --- |
| FR-001 | TASK-001 Bridge core and pane addressing | `psmux-bridge` CLI |
| FR-002 | TASK-002 Role gate policy engine | Security / Orchestra |
| FR-003 | TASK-003 DPAPI credential vault | Credential Vault |
| FR-004 | TASK-004 Orchestra one-action startup | Orchestra |
| FR-005 | TASK-005 Hierarchical settings loader | Configuration |
| FR-006 | TASK-006 Mailbox router and named-pipe transport | Messaging |
| FR-007 | TASK-007 Shared task store and dependency engine | Orchestration |
| FR-008 | TASK-008 Agent lifecycle monitor and auto-respawn | Reliability |
| FR-009 | TASK-009 JSON-RPC server surface | Integration |
| FR-010 | TASK-010 MCP adapter and server surface | Integration |
| FR-011 | TASK-011 Shield Harness STG gate integration | Governance |
| FR-012 | TASK-012 Evidence ledger capture and export | Governance |
| FR-013 | TASK-013 Channel validation and delivery security | Security |
| FR-014 | TASK-014 Read Guard and watermark enforcement | Safety |
| FR-015 | TASK-015 File lock coordinator | Concurrency |
| FR-016 | TASK-016 Health check and operator diagnostics | Observability |
| FR-017 | TASK-017 Commander task hooks and notifications | Orchestration |
| FR-018 | TASK-018 Windows Terminal fragment and pane labels | UX / Launch |
| FR-019 | TASK-019 Interactive setup wizard | Onboarding |
| FR-020 | TASK-020 Vendor-neutral runtime adapter layer | Platform |
