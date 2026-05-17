# Threat Model

This document is an internal planning and governance surface for `TASK-046`.
It records the current winsmux threat model without turning enterprise security
goals into public product promises.

Public vulnerability reporting remains in `SECURITY.md`. Public product
positioning remains in `README.md` and `docs/operator-model.md`.

## Scope

The threat model covers the local operator flow used by the current repository:

- user intent and explicit approval;
- desktop and CLI control surfaces;
- hook-based policy decisions;
- local evidence and review state;
- managed pane workers and backend adapters;
- release and public documentation surfaces.

It does not claim that every future enterprise mitigation is implemented. The
audit in `docs/project/THREAT_MODEL_AUDIT.md` records which current controls
were checked and which residual risks remain.

## Source Artifacts

| Area | Current artifact |
| --- | --- |
| Hook registration | `.claude/settings.json` |
| Injection pattern categories | `.claude/patterns/injection-patterns.json` |
| Shell command gate | `.claude/hooks/sh-gate.js` |
| Injection guard | `.claude/hooks/sh-injection-guard.js` |
| Data boundary guard | `.claude/hooks/sh-data-boundary.js` |
| Evidence and pane state | `.claude/hooks/sh-evidence.js`, `.claude/hooks/sh-pane-monitor.js` |
| Public surface policy | `docs/repo-surface-policy.md`, `scripts/audit-public-surface.ps1` |
| Secret scan | `scripts/git-guard.ps1`, `scripts/gitleaks-history.ps1` |

## Pattern Categories

The current `injection-patterns.json` file defines these categories:

| Category | Severity | Meaning |
| --- | --- | --- |
| `instruction_override` | high | Attempts to discard or override active instructions. |
| `role_hijack` | high | Attempts to redefine the assistant role or identity. |
| `prompt_extraction` | critical | Attempts to extract hidden instructions or internal state. |
| `context_manipulation` | medium | Fabricated context or authority claims. |
| `encoding_evasion` | high | Encoding or eval patterns that try to bypass checks. |

The hook implementation also checks invisible Unicode controls before loading
the pattern file, because those characters can alter how text is interpreted.

## Threat Inventory

OCSF names below are used as internal classification labels. They do not imply
that the repository exports OCSF events today.

| ID | Threat | Entry point | Pattern category or control | OCSF classification | Current mitigation |
| --- | --- | --- | --- | --- | --- |
| TM-001 | Instruction override in user or tool text | `Bash`, `Edit`, `Write`, `Read`, `WebFetch` | `instruction_override` | Security Finding | `sh-injection-guard.js` denies high-severity matches and records evidence. |
| TM-002 | Role or identity hijack | `Bash`, `Edit`, `Write`, `Read`, `WebFetch` | `role_hijack` | Security Finding | `sh-injection-guard.js` denies high-severity role redefinition patterns. |
| TM-003 | Hidden prompt or instruction extraction | `Bash`, `Edit`, `Write`, `Read`, `WebFetch` | `prompt_extraction` | Security Finding | `sh-injection-guard.js` denies critical prompt extraction patterns. |
| TM-004 | Fabricated prior context or authority | `Bash`, `Edit`, `Write`, `Read`, `WebFetch` | `context_manipulation` | Detection Finding | `sh-injection-guard.js` allows medium findings with warning context and evidence. |
| TM-005 | Encoding or eval evasion | `Bash`, file operations, fetched URLs | `encoding_evasion` | Security Finding | NFKC normalization and pattern checks deny high-severity encoding and eval probes. |
| TM-006 | Invisible or bidirectional character evasion | File paths, command text, prompts | zero-width control check | Security Finding | `ZERO_WIDTH_RE` is applied before pattern loading. |
| TM-007 | Destructive shell command execution | `Bash` | destructive command gate | Security Finding | `sh-gate.js` blocks destructive file-system and device patterns. |
| TM-008 | Tool switching to bypass file-write controls | `Bash` | tool-switching patterns | Security Finding | `sh-gate.js` blocks shell-based file-write bypasses such as scripting one-liners and redirects. |
| TM-009 | Dynamic linker or runtime injection | `Bash` | dynamic linker patterns | Security Finding | `sh-gate.js` blocks `LD_PRELOAD`, loader invocation, and Windows DLL execution patterns. |
| TM-010 | Hook or configuration tampering | `Bash`, git configuration | configuration and git bypass patterns | Security Finding | `sh-gate.js`, `sh-config-guard.js`, and repository hooks block common bypass paths. |
| TM-011 | Path or environment hijack | `Bash` | path, environment, and expansion patterns | Security Finding | `sh-gate.js` blocks high-risk path, environment, and command-substitution patterns. |
| TM-012 | Windows shortcut, batch, or alternate data stream execution | `Bash`, file paths | Windows-specific patterns | Security Finding | `sh-gate.js` blocks known Windows execution and alternate data stream patterns. |
| TM-013 | Network access to production or internal hosts | `Bash`, `WebFetch` | data boundary guard | Security Finding | `sh-data-boundary.js` blocks configured production hosts, localhost, metadata, and private networks. |
| TM-014 | Unauthorized jurisdiction or host class | `WebFetch` | data boundary guard | Detection Finding | `sh-data-boundary.js` enforces configured jurisdiction allowlists when present. |
| TM-015 | Quiet injection path bypass | `Bash` | quiet injection guard | Security Finding | `sh-quiet-inject.js` runs before command execution for shell actions. |
| TM-016 | Channel or shell routing confusion | `Bash` | channel detection | Detection Finding | `sh-channel-detect.js` records channel mismatch and shell-routing context. |
| TM-017 | Dependency-impacting command without audit | `Bash` | dependency audit | Detection Finding | `sh-dep-audit.js` runs after shell commands and records dependency-impacting actions. |
| TM-018 | Evidence omission or tampering | Post-tool events | evidence hook and git guard | Detection Finding | `sh-evidence.js`, `git-guard`, and CI checks preserve release evidence boundaries. |
| TM-019 | Pane state spoofing or stale liveness | Post-tool events | pane monitor | Detection Finding | `sh-pane-monitor.js` records pane state after tool activity. |
| TM-020 | Subagent or worktree context over-sharing | subagent and worktree events | subagent and worktree hooks | Detection Finding | `sh-subagent.js` and `sh-worktree.js` record startup and worktree boundaries. |
| TM-021 | False task completion or issue closure | task and issue flow | task and issue gates | Detection Finding | `sh-task-gate.js`, `sh-pipeline.js`, and `sh-issue-gate.js` attach completion claims to evidence. |
| TM-022 | Release or public documentation leakage | release notes and public docs | public surface audit | Security Finding | `scripts/audit-public-surface.ps1` and `PublicSurfacePolicy.Tests.ps1` block forbidden public references. |

## Residual Risk Handling

- Missing or corrupted policy files must not be described as safe. The audit
  records whether a control denies, warns, or depends on optional configuration.
- Medium-severity findings are warning signals, not approvals.
- Public release notes may mention this document only as internal planning and
  governance evidence.
- Future enterprise controls must be added as separate tasks before public
  documentation can promise stronger enforcement.

## Traceability

| Planning task | Current evidence |
| --- | --- |
| `TASK-046` | This document records the 22 threat IDs, pattern mapping, OCSF classification labels, and current mitigations. |
| `TASK-050` | `docs/project/THREAT_MODEL_AUDIT.md` records the audit and mitigation probe results. |
