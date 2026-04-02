# Roadmap

> Auto-generated from `tasks/backlog.yaml` — do not edit manually.
> Last sync: 2026-04-02 15:14 (+09:00)

## Version Summary

| Version | Tasks | Progress |
|---------|-------|----------|
| v0.9.6 | 10 | [====================] 100% (10/10) |
| v0.10.0 | 36 | [============--------] 58% (21/36) |
| v1.0.0 | 1 | [--------------------] 0% (0/1) |

## Work Breakdown

### v0.9.6

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-001 | Fix resize-pane -x/-y routing to ResizePaneAbsolute | P1 | psmux/psmux | done |
| [x] | TASK-002 | Separate split-window -l (cells) from -p (percent) | P1 | psmux/psmux | done |
| [x] | TASK-007 | Sync VERSION and install.ps1 to v0.9.5 | P1 | winsmux | done |
| [x] | TASK-008 | Add orchestra-layout skill and dispatch scripts | P1 | winsmux | done |
| [x] | TASK-009 | Create ROADMAP.md, backlog.yaml, and sync workflow | P1 | winsmux | done |
| [x] | TASK-016 | Sync all public docs to v0.9.5 and add version-drift pre-commit gate | P1 | winsmux | done |
| [x] | TASK-019 | Sync sora-psmux fork with upstream (commit 1861eb7) | P1 | sora-psmux | done |
| [x] | TASK-020 | Submit fork patches as upstream PR (psmux/psmux#175) | P1 | sora-psmux | done |
| [x] | TASK-003 | Fix select-layout tiled pane redistribution | P2 | psmux/psmux | done |
| [x] | TASK-023 | File upstream Issues for remaining bugs (#176, #177, #178) | P2 | psmux/psmux | done |

### v0.10.0

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-032 | Implement Mailbox-compatible async message router (mailbox-router.ps1) | P0 | winsmux | done |
| [x] | TASK-027 | Add role-based command gate to psmux-bridge (Assert-Role) | P0 | winsmux | done |
| [x] | TASK-053 | Document and enforce operational role definitions (Commander/Builder/Researcher/Reviewer) | P0 | winsmux | done |
| [x] | TASK-028 | Add PreToolUse hook for Commander-side gate (sh-orchestra-gate.js) | P0 | winsmux | done |
| [ ] | TASK-060 | Write integration tests verifying gate enforcement (deny paths end-to-end) | P0 | winsmux | backlog |
| [x] | TASK-059 | Fix task-hooks.ps1: notify Commander instead of auto-assigning work | P0 | winsmux | done |
| [x] | TASK-058 | Eliminate raw send-keys from orchestra-start, mailbox-router, agent-lifecycle | P0 | winsmux | done |
| [x] | TASK-033 | Implement Shared Task List with file-lock self-claiming and dependency auto-resolve | P0 | winsmux | done |
| [ ] | TASK-057 | Fix rpc-server.ps1: remove client-supplied role trust, bind to process identity | P0 | winsmux | backlog |
| [x] | TASK-056 | Fix role-gate.ps1 to deny unknown commands (fail-open → fail-close) | P0 | winsmux | done |
| [x] | TASK-054 | Fix vault inject to use psmux set-environment instead of send-keys | P0 | winsmux | done |
| [ ] | TASK-044 | Prepare and submit PR to psmux-plugins upstream | P1 | winsmux | backlog |
| [x] | TASK-052 | Rewrite README.md/README.ja.md to reflect platform positioning and 3 unique strengths | P1 | winsmux | done |
| [x] | TASK-025 | Extract psmux-bridge CLI as PPM plugin (winsmux remains as platform) | P1 | winsmux | done |
| [ ] | TASK-043 | Expose psmux-bridge as MCP Server for Claude Code Agent Teams integration | P1 | winsmux | backlog |
| [ ] | TASK-049 | Run 15-agent 15min load test (crash rate < 0.1%, evidence integrity 100%) | P1 | winsmux | backlog |
| [ ] | TASK-055 | Auto-update backlog.yaml status when tasks complete (Commander automation) | P1 | winsmux | backlog |
| [x] | TASK-042 | Implement JSON-RPC 2.0 endpoint for psmux-bridge (psmux-bridge-rpc.ps1) | P1 | winsmux | done |
| [ ] | TASK-051 | Release v0.10.0 GA (release notes, migration guide, install wizard, version bump) | P1 | winsmux | backlog |
| [x] | TASK-039 | Make STG3 gate CI-aware (auto-run Pester, deny on coverage < 80%) | P1 | winsmux | done |
| [x] | TASK-026 | Implement hierarchical settings system (project > global > wizard) | P1 | winsmux | done |
| [x] | TASK-029 | Implement Orchestra start automation (Prefix+O full lifecycle) | P1 | winsmux | done |
| [x] | TASK-030 | Add channel event detection and severity boost to sh-user-prompt.js | P1 | winsmux | done |
| [x] | TASK-038 | Write unit tests for all 11 CLI commands (44+ test cases, coverage >= 75%) | P1 | winsmux | done |
| [x] | TASK-031 | Enhance evidence-ledger with command-trace recording and integrity check | P1 | winsmux | done |
| [x] | TASK-037 | Set up Pester 5 test framework with AAA pattern for psmux-bridge.ps1 | P1 | winsmux | done |
| [ ] | TASK-050 | Security audit against THREAT_MODEL.md (22 threats, pen-test all mitigations) | P1 | winsmux | backlog |
| [x] | TASK-035 | Implement agent idle/crash detection with auto-respawn (TeammateIdle compat) | P1 | winsmux | done |
| [x] | TASK-034 | Add TaskCreated / TaskCompleted hook integration for auto-dispatch | P1 | winsmux | done |
| [ ] | TASK-040 | Add GitHub Actions CI workflow (Pester on push, coverage badge) | P2 | winsmux | backlog |
| [ ] | TASK-036 | Extend agent-readiness patterns beyond prompt detection (Codex/Gemini/Claude) | P2 | winsmux | backlog |
| [ ] | TASK-047 | Write ARCHITECTURE.md (4-layer diagram, 22 hooks, data flow, component diagram) | P2 | winsmux | backlog |
| [ ] | TASK-046 | Write THREAT_MODEL.md (22 threat IDs mapped to injection-patterns.json, OCSF classification) | P2 | winsmux | backlog |
| [ ] | TASK-045 | Write REQUIREMENTS.md (functional reqs, NFR, acceptance criteria, traceability matrix) | P2 | winsmux | backlog |
| [ ] | TASK-048 | Write DETAILED_DESIGN.md (hook I/O specs, regex, branch logic, test templates) | P2 | winsmux | backlog |
| [ ] | TASK-041 | Write multi-agent integration test (orchestra end-to-end scenario) | P2 | winsmux | backlog |

### v1.0.0

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-024 | Full integration test → GA release → winsmux v1.0.0 publish | P1 | winsmux | backlog |

## Legend

| Symbol | Meaning |
|--------|---------|
| [x] | Done |
| [-] | In progress |
| [R] | In review |
| [ ] | Backlog / Ready |

| Priority | Meaning |
|----------|---------|
| P0 | Critical / Blocker |
| P1 | High |
| P2 | Medium |
| P3 | Low |