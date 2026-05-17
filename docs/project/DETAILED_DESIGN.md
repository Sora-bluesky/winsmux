# Detailed Design

This document is an internal planning and governance surface for `TASK-048`.
It complements `docs/project/ARCHITECTURE.md` and should not be treated as
public product messaging.

## Scope

`TASK-048` asked for detailed design coverage for hook I/O specs, matching
rules, branch logic, and test templates. The current repository did not contain
a tracked `DETAILED_DESIGN.md` artifact, so this file records the current
implementation contract without inventing new runtime behavior.

## Hook Input and Output

The hook runtime is command based. Each hook command receives a structured event
payload from the invoking agent runtime and returns a process result.

Expected input fields:

| Field | Meaning | Handling |
| --- | --- | --- |
| `hook_event_name` | Runtime event such as `PreToolUse` or `PostToolUse` | Selects the registered event bucket in `.claude/settings.json`. |
| `matcher` | Tool or event selector such as `Bash`, `WebFetch`, or `Edit|Write|Read` | Compared with the registration matcher before command execution. |
| `tool_name` | Tool name for tool events | Used by gate, evidence, and dependency-audit hooks. |
| `tool_input` | Tool arguments or action metadata | Treated as untrusted input and checked before any authority is granted. |
| `cwd` or workspace metadata | Current workspace context when provided | Used only after path and boundary checks. |
| session metadata | Session, pane, or run identifiers when provided | Used for evidence attribution and liveness state. |

Expected output contract:

| Outcome | Process signal | Runtime meaning |
| --- | --- | --- |
| allow | exit code `0` with no blocking decision | Continue the original action. |
| block | nonzero exit code or explicit block payload | Stop the original action and surface the reason. |
| warn | exit code `0` with warning evidence | Continue while preserving evidence for operator judgement. |
| evidence | structured stdout or append-only record | Attribute verification, security, or review context to the producing hook. |

Hooks must not rely on prompt text as authority. They should use explicit event
fields, repository state, policy files, and operator approvals.

## Matching Rules

The current matcher patterns are simple event selectors rather than arbitrary
user-provided expressions.

| Pattern | Matches | Current use |
| --- | --- | --- |
| empty string | all events in the event bucket | Session lifecycle, permission, evidence, task completion |
| `Bash` | shell tool use | command gate, injection guard, channel detection, dependency audit |
| `WebFetch` | web fetch tool use | injection guard and data boundary checks |
| `Edit|Write|Read` | file read and write tools | invisible character scan and injection guard |

The matcher string `Edit|Write|Read` is treated as a constrained alternation for
known tool names. It is not a general policy language.

## Branch and Surface Logic

Release work uses dedicated branches with the `codex/` prefix. A version branch
must keep its changes scoped to that version's task and must not include
ignored live operational files.

Branch gates:

| Gate | Rule |
| --- | --- |
| clean start | `git status --short --branch` must not show unrelated user-owned changes. |
| release branch | Use a `codex/` branch for version work. |
| public surface | Run `scripts/audit-public-surface.ps1` before release. |
| secret surface | Run `scripts/git-guard.ps1 -Mode full` before release. |
| review gate | Run `codex review` with the configured release-review model and a long timeout. |
| merge gate | Merge only after local validation, PR review, and required CI pass. |
| release gate | Verify local tag, remote tag, GitHub Release, body, and `release-body.md` asset. |

Surface rules:

- `docs/project/*.md` is contributor-facing planning and contract inventory.
- `docs/internal/` remains ignored live internal material.
- `docs/handoff.md`, `docs/HANDOFF.md`, and `HANDOFF.md` are live operational
  files and must not be tracked.
- Public docs must not depend on private planning roots or local machine paths.

## Hook Script Responsibilities

| Script | Primary responsibility |
| --- | --- |
| `sh-session-start.js` | Record session startup context. |
| `sh-session-end.js` | Record session shutdown context. |
| `sh-gate.js` | Gate shell commands before execution. |
| `sh-injection-guard.js` | Detect prompt or tool-input injection patterns. |
| `sh-channel-detect.js` | Detect unintended channel or shell routing. |
| `sh-quiet-inject.js` | Prevent quiet injection paths from bypassing review. |
| `sh-data-boundary.js` | Enforce data-boundary rules for tool input. |
| `sh-issue-gate.js` | Keep issue-related gates attached to work state. |
| `sh-invisible-char-scan.js` | Detect invisible or private-use characters in file operations. |
| `sh-orchestra-gate.js` | Gate orchestration-specific actions. |
| `sh-permission.js` | Enforce permission checks before broad actions. |
| `sh-evidence.js` | Record tool evidence after execution. |
| `sh-output-control.js` | Constrain post-tool output handling. |
| `sh-pane-monitor.js` | Track pane state after tool actions. |
| `lint-on-save.js` | Run save-time lint checks for file edits. |
| `sh-dep-audit.js` | Audit dependency-impacting shell actions. |
| `sh-user-prompt.js` | Process user-prompt submission context. |
| `sh-circuit-breaker.js` | Stop runaway or unsafe repeated workflow patterns. |
| `sh-subagent.js` | Record subagent startup state. |
| `sh-worktree.js` | Record worktree creation state. |
| `sh-precompact.js` | Preserve pre-compaction context. |
| `sh-postcompact.js` | Verify post-compaction continuity. |
| `sh-elicitation.js` | Record explicit elicitation context. |
| `sh-config-guard.js` | Guard configuration changes. |
| `sh-instructions.js` | Record instruction-loading context. |
| `sh-permission-learn.js` | Record permission-request learning events. |
| `sh-pipeline.js` | Record task pipeline completion state. |
| `sh-task-gate.js` | Gate task completion claims. |

## Test Templates

Use the smallest template that covers the changed surface, then include the
default release gate before tagging.

Documentation or planning-only change:

```powershell
git diff --check
pwsh -NoProfile -File scripts\audit-public-surface.ps1
pwsh -NoProfile -File scripts\git-guard.ps1 -Mode full
Invoke-Pester -Path tests\PublicSurfacePolicy.Tests.ps1 -PassThru
```

Core contract change:

```powershell
git diff --check
cargo test --manifest-path core\Cargo.toml
pwsh -NoProfile -File scripts\audit-public-surface.ps1
pwsh -NoProfile -File scripts\git-guard.ps1 -Mode full
```

Desktop behavior change:

```powershell
git diff --check
cmd /c npm run build
cargo check --manifest-path winsmux-app\src-tauri\Cargo.toml --locked
cmd /c npm run test:desktop-pane-e2e
cmd /c npm run test:clickable-coverage
```

Full release gate:

```powershell
git diff --check
Invoke-Pester -Path tests\winsmux-bridge.Tests.ps1 -PassThru
Invoke-Pester -Path tests\PublicSurfacePolicy.Tests.ps1 -PassThru
cargo test --manifest-path core\Cargo.toml
cmd /c npm run build
cargo check --manifest-path winsmux-app\src-tauri\Cargo.toml --locked
pwsh -NoProfile -File scripts\audit-public-surface.ps1
pwsh -NoProfile -File scripts\git-guard.ps1 -Mode full
```

## Traceability

| Planning task | Design evidence |
| --- | --- |
| `TASK-047` | Architecture diagram, hook inventory, data flow, and component diagram are in `docs/project/ARCHITECTURE.md`. |
| `TASK-048` | Hook input and output, matching rules, branch logic, and test templates are recorded in this file. |
