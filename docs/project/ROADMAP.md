# ロードマップ

> `tasks/backlog.yaml` から自動生成 — 手動編集禁止
> 最終同期: 2026-04-05 18:38 (+09:00)

## バージョン概要

| バージョン | タスク数 | 進捗 |
|-----------|---------|------|
| v0.9.6 | 10 | [====================] 100% (10/10) |
| v0.10.0 | 11 | [====================] 100% (11/11) |
| v0.10.1 | 7 | [====================] 100% (7/7) |
| v0.10.2 | 2 | [====================] 100% (2/2) |
| v0.10.3 | 2 | [====================] 100% (2/2) |
| v0.11.0 | 3 | [====================] 100% (3/3) |
| v0.12.0 | 3 | [====================] 100% (3/3) |
| v0.13.0 | 3 | [====================] 100% (3/3) |
| v0.14.0 | 2 | [====================] 100% (2/2) |
| v0.15.0 | 4 | [====================] 100% (4/4) |
| v0.16.0 | 4 | [====================] 100% (4/4) |
| v0.17.0 | 3 | [====================] 100% (3/3) |
| v0.17.1 | 2 | [====================] 100% (2/2) |
| v0.17.2 | 2 | [====================] 100% (2/2) |
| v0.17.3 | 2 | [====================] 100% (2/2) |
| v0.17.4 | 2 | [====================] 100% (2/2) |
| v0.18.0 | 1 | [====================] 100% (1/1) |
| v0.18.1 | 15 | [====================] 100% (15/15) |
| v0.18.2 | 10 | [====================] 100% (10/10) |
| v0.19.0 | 6 | [--------------------] 0% (0/6) |
| v0.19.1 | 2 | [--------------------] 0% (0/2) |
| v0.19.2 | 2 | [--------------------] 0% (0/2) |
| v0.20.0 | 5 | [--------------------] 0% (0/5) |
| v0.20.1 | 1 | [--------------------] 0% (0/1) |
| v0.21.0 | 2 | [--------------------] 0% (0/2) |
| v0.21.1 | 1 | [--------------------] 0% (0/1) |
| v0.21.2 | 1 | [--------------------] 0% (0/1) |
| cancelled | 22 | [--------------------] 0% (0/22) |
| post-v1.0.0 | 7 | [--------------------] 0% (0/7) |

## タスク詳細

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
| [x] | TASK-027 | Add role-based command gate to psmux-bridge (Assert-Role) | P0 | winsmux | done |
| [x] | TASK-028 | Add PreToolUse hook for Commander-side gate (sh-orchestra-gate.js) | P0 | winsmux | done |
| [x] | TASK-062 | Run Pester tests locally and fix all failures before next merge | P0 | winsmux | done |
| [x] | TASK-063 | Runtime test: role-gate + settings + shared-task-list (no psmux needed) | P0 | winsmux | done |
| [x] | TASK-065 | Runtime test: orchestra-layout.ps1 pane generation (psmux) | P0 | winsmux | done |
| [x] | TASK-077 | Build sora-psmux fork release binary and distribute via install.ps1 | P0 | winsmux | done |
| [x] | TASK-081 | orchestra-start preflight: auto-vault, Codex trust, skill unification | P0 | winsmux | done |
| [x] | TASK-025 | Extract psmux-bridge CLI as PPM plugin (winsmux remains as platform) | P1 | winsmux | done |
| [x] | TASK-026 | Implement hierarchical settings system (project > global > wizard) | P1 | winsmux | done |
| [x] | TASK-052 | Rewrite README.md/README.ja.md to reflect platform positioning and 3 unique strengths | P1 | winsmux | done |
| [x] | TASK-061 | Fix CI: remove test.yml or make it skip when test files are gitignored | P1 | winsmux | done |

### v0.10.1

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-053 | Document and enforce operational role definitions (Commander/Builder/Researcher/Reviewer) | P0 | winsmux | done |
| [x] | TASK-064 | Runtime test: vault source-file injection (DPAPI + psmux) | P0 | winsmux | done |
| [x] | TASK-088 | Global install + winsmux init/start for any project | P0 | winsmux | done |
| [x] | TASK-037 | Set up Pester 5 test framework with AAA pattern for psmux-bridge.ps1 | P1 | winsmux | done |
| [x] | TASK-038 | Write unit tests for all 11 CLI commands (44+ test cases, coverage >= 75%) | P1 | winsmux | done |
| [x] | TASK-060 | Write integration tests verifying gate enforcement (deny paths end-to-end) | P1 | winsmux | done |
| [x] | TASK-067 | Integration test: orchestra-start full cycle (settings→vault→layout→agents→health) | P1 | winsmux | done |

### v0.10.2

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-084 | Implement .winsmux/manifest.yaml persistent session state | P0 | winsmux | done |
| [x] | TASK-085 | Implement keyword-based dispatch routing for Commander | P0 | winsmux | done |

### v0.10.3

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-086 | Implement team pipeline automation (plan→exec→verify→fix loop) | P0 | winsmux | done |
| [x] | TASK-087 | Implement multi-vendor mixed agent teams (per-role agent config + local LLM) | P1 | winsmux | done |

### v0.11.0

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-040 | Add GitHub Actions CI workflow (Pester on push, coverage badge) | P2 | winsmux | done |
| [x] | TASK-041 | Write multi-agent integration test (orchestra end-to-end scenario) | P2 | winsmux | done |
| [x] | TASK-083 | Structured logging infrastructure for Orchestra startup and runtime | P2 | winsmux | done |

### v0.12.0

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-035 | Implement agent idle/crash detection with auto-respawn (TeammateIdle compat) | P2 | winsmux | done |
| [x] | TASK-043 | Expose psmux-bridge as MCP Server for Claude Code Agent Teams integration | P2 | winsmux | done |
| [x] | TASK-074 | Implement TypeScript/Python SDK for programmatic Orchestra control | P2 | winsmux | done |

### v0.13.0

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-089 | Implement 15 missing functions in sh-utils.js | P0 | winsmux | done |
| [x] | TASK-090 | Restore Shield-Harness init in orchestra-start.ps1 | P0 | winsmux | done |
| [x] | TASK-091 | Create .claude/settings.json and register hooks | P0 | winsmux | done |

### v0.14.0

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-092 | Activate Tier 1 Hooks (8 hooks: session, gate, injection, permission, output) | P0 | winsmux | done |
| [x] | TASK-093 | Fix injection-patterns.json schema (Array to Object with categories) | P1 | winsmux | done |

### v0.15.0

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-094 | Activate Tier 2 Hooks (9 hooks: quiet, circuit, subagent, worktree, lint, compact) | P0 | winsmux | done |
| [x] | TASK-029 | Implement Orchestra start automation (Prefix+O full lifecycle) | P1 | winsmux | done |
| [x] | TASK-095 | Implement P17 Focus Policy Stack (focus-lock/unlock) | P1 | winsmux | done |
| [x] | TASK-096 | Auto-cleanup stale worktrees and branches on Orchestra start | P1 | winsmux | done |

### v0.16.0

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-097 | Activate Tier 3 Hooks (8 hooks) + enterprise lib verification | P0 | winsmux | done |
| [x] | TASK-030 | Add channel event detection and severity boost to sh-user-prompt.js | P2 | winsmux | done |
| [x] | TASK-031 | Enhance evidence-ledger with command-trace recording and integrity check | P2 | winsmux | done |
| [x] | TASK-036 | Extend agent-readiness patterns beyond prompt detection (Codex/Gemini/Claude) | P2 | winsmux | done |

### v0.17.0 — Orchestra 自動ディスパッチ

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-109 | Builder work queue — auto-dispatch next task on completion | P0 | winsmux | done |
| [x] | TASK-111 | Builder completion notification + auto-Reviewer dispatch | P0 | winsmux | done |
| [x] | TASK-121 | Commander auto-detect Codex approval prompts in Builder panes | P0 | winsmux | done |

### v0.17.1 — アイドルペイン切替 + 起動シリアライズ

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-117 | Serialize orchestra-start phases with startup lock, retry, and idempotent preflight | P0 | winsmux | done |
| [x] | TASK-112 | Idle pane auto-role-switch for optimal resource utilization | P1 | winsmux | done |

### v0.17.2 — 起動 UX + Vault 堅牢化

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-116 | Remove interactive startup prompts and add startup-doctor remediation | P1 | winsmux | done |
| [x] | TASK-119 | Credential and vault health preflight with redacted diagnostics | P1 | winsmux | done |

### v0.17.3 — CI ゲート + 監査トリアージ

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-039 | Make STG3 gate CI-aware (auto-run Pester, deny on coverage < 80%) | P2 | winsmux | done |
| [x] | TASK-082 | Triage 96 startup audit findings to responsible tasks | P2 | winsmux | done |

### v0.17.4 — ロールバック + ドキュメント

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-118 | Add startup rollback and recovery journal for partial initialization | P1 | winsmux | done |
| [x] | TASK-120 | Write startup troubleshooting guide and verification matrix | P2 | winsmux | done |

### v0.18.0 — Tauri scaffold

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-098 | Tauri scaffold + sidebar + Focus Policy + notification inbox | P0 | winsmux | done |

### v0.18.1 — マルチペイン + Codex 改善

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-099 | Multi-pane layout + Orchestra integration in Tauri | P0 | winsmux | done |
| [x] | TASK-122 | Fix orchestra-start pane duplication on restart | P0 | winsmux | done |
| [x] | TASK-123 | Replace Get-CimInstance Win32_Process with Get-Process globally | P0 | winsmux | done |
| [x] | TASK-124 | Add psmux-bridge kill/restart subcommands for Builder panes | P0 | winsmux | done |
| [x] | TASK-131 | Fix pty_close: stop reader thread and kill child process | P0 | winsmux | done |
| [x] | TASK-132 | Fix orchestra-start blocked by zombie pwsh/worktree locks | P0 | winsmux | done |
| [x] | TASK-133 | Fix sh-orchestra-gate.js: block git add/commit from Commander | P0 | winsmux | done |
| [x] | TASK-135 | Integrate v0.17.0 auto-dispatch features into orchestra-start | P0 | winsmux | done |
| [x] | TASK-136 | Prevent idle panes: Commander × dispatch-router/builder-queue/agent-monitor | P0 | winsmux | done |
| [x] | TASK-102 | Fix Codex context exhaustion in Builder worktrees | P1 | winsmux | done |
| [x] | TASK-125 | Auto-inject cmd /c workaround for Codex constrained language mode | P1 | winsmux | done |
| [x] | TASK-126 | Fix sh-worktree.js hook (no output on worktree create) | P1 | winsmux | done |
| [x] | TASK-127 | Fix builder-queue manifest queued property error | P1 | winsmux | done |
| [x] | TASK-128 | Fix role switch killing pane instead of respawning | P1 | winsmux | done |
| [x] | TASK-129 | Fix pane border labels not displayed | P2 | winsmux | done |

### v0.18.2 — タスク分割 + 動的スケーリング

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [x] | TASK-140 | Switch Builder agents from persistent session to codex exec per task + shell templates | P0 | winsmux | done |
| [x] | TASK-141 | Dispatch-router file-level task boundary enforcement | P0 | winsmux | done |
| [x] | TASK-142 | Fix orchestra-start crash when zombie processes are killed (Write-Output pipeline pollution) | P0 | winsmux | done |
| [x] | TASK-148 | Set GIT_EDITOR=true in orchestra session to prevent vim stall | P0 | winsmux | done |
| [x] | TASK-149 | Agent-monitor background daemon for continuous pane monitoring | P0 | winsmux | done |
| [x] | TASK-150 | Fix agent-watchdog: Start-Job dies with parent process → Start-Process | P0 | winsmux | done |
| [x] | TASK-110 | Automatic task splitting for parallel Builder dispatch | P1 | winsmux | done |
| [x] | TASK-113 | Dynamic pane scaling — auto add/remove panes based on workload | P1 | winsmux | done |
| [x] | TASK-130 | Commander auto-detect Builder stall and alert | P1 | winsmux | done |
| [x] | TASK-134 | Commander approval gate for Builder sandbox prompts | P1 | winsmux | done |

### v0.19.0 — Explorer + Dashboard

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-104 | Sync sora-psmux fork with upstream before rendering work | P0 | sora-psmux | cancelled |
| [ ] | TASK-100 | Explorer + Dashboard panels in Tauri | P1 | winsmux | backlog |
| [ ] | TASK-103 | Implement P14-Ph2 psmux rendering improvements (TrueColor, Nerd Font, GPU) | P1 | sora-psmux | cancelled |
| [ ] | TASK-137 | Audit dead code and missing integration across v0.9.6–v0.18.0 | P1 | winsmux | backlog |
| [ ] | TASK-138 | Source control panel in Tauri UI Explorer (worktree-aware) | P1 | winsmux | backlog |
| [ ] | TASK-139 | Rename psmux-bridge to winsmux-core + adapter layer separation | P1 | winsmux | backlog |

### v0.19.1 — テーマエンジン + ペインメタデータ

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-101 | Theme engine + Nerd Font + TrueColor in Tauri | P1 | winsmux | backlog |
| [ ] | TASK-078 | Pane border metadata display (git branch, timestamp, idle time) | P2 | winsmux | backlog |

### v0.19.2 — イベントキャプチャ + 検索

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-070 | Implement Event Stream (pub/sub event bus for Orchestra) | P1 | winsmux | backlog |
| [ ] | TASK-114 | Orchestra event capture + SQLite FTS5 search layer | P1 | winsmux | backlog |

### v0.20.0 — JSON-RPC + SDK

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-105 | JSON-RPC backend + SDK integration in Tauri | P0 | winsmux | backlog |
| [ ] | TASK-143 | Shadow Git checkpoint for Builder worktrees | P1 | winsmux | backlog |
| [ ] | TASK-145 | TaskResume hook × manifest.yaml integration | P1 | winsmux | backlog |
| [ ] | TASK-144 | Hook parallel execution + Notification hook | P2 | winsmux | backlog |
| [ ] | TASK-146 | PreCompact hook × context usage monitoring | P2 | winsmux | backlog |

### v0.20.1 — インストーラプロファイル

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-115 | Installer profile design (core/orchestra/security/full) | P2 | winsmux | backlog |

### v0.21.0 — Relay Auth

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-106 | Relay Auth + remote pane support in Tauri | P1 | winsmux | backlog |
| [ ] | TASK-147 | ACP (Agent Communication Protocol) server support | P1 | winsmux | backlog |

### v0.21.1 — Editor パネル

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-107 | Editor panel + drag-and-drop layout + polish | P1 | winsmux | backlog |

### v0.21.2 — ペイン分離 + マルチディスプレイ

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-108 | Pane pop-out and multi-display support | P1 | winsmux | backlog |

### cancelled

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-032 | Implement Mailbox-compatible async message router (mailbox-router.ps1) | P0 | winsmux | cancelled |
| [ ] | TASK-033 | Implement Shared Task List with file-lock self-claiming and dependency auto-resolve | P0 | winsmux | cancelled |
| [ ] | TASK-054 | Fix vault inject to use psmux set-environment instead of send-keys | P0 | winsmux | cancelled |
| [ ] | TASK-056 | Fix role-gate.ps1 to deny unknown commands (fail-open → fail-close) | P0 | winsmux | cancelled |
| [ ] | TASK-057 | Fix rpc-server.ps1: remove client-supplied role trust, bind to process identity | P0 | winsmux | cancelled |
| [ ] | TASK-058 | Eliminate raw send-keys from orchestra-start, mailbox-router, agent-lifecycle | P0 | winsmux | cancelled |
| [ ] | TASK-059 | Fix task-hooks.ps1: notify Commander instead of auto-assigning work | P0 | winsmux | cancelled |
| [ ] | TASK-066 | Runtime test: rpc-server + mcp-server mock client verification | P0 | winsmux | cancelled |
| [ ] | TASK-024 | Full integration test → GA release → winsmux v1.0.0 publish | P1 | winsmux | cancelled |
| [ ] | TASK-034 | Add TaskCreated / TaskCompleted hook integration for auto-dispatch | P1 | winsmux | cancelled |
| [ ] | TASK-042 | Implement JSON-RPC 2.0 endpoint for psmux-bridge (psmux-bridge-rpc.ps1) | P1 | winsmux | cancelled |
| [ ] | TASK-044 | Prepare and submit PR to psmux-plugins upstream | P1 | winsmux | cancelled |
| [ ] | TASK-049 | Run 15-agent 15min load test (crash rate < 0.1%, evidence integrity 100%) | P1 | winsmux | cancelled |
| [ ] | TASK-051 | Release v0.10.0 GA (release notes, migration guide, install wizard, version bump) | P1 | winsmux | cancelled |
| [ ] | TASK-055 | Commander automation: backlog sync + worktree lifecycle gate (collect before cleanup) | P1 | winsmux | cancelled |
| [ ] | TASK-068 | Integration test: mailbox-router + task-hooks + commander-dispatch | P1 | winsmux | cancelled |
| [ ] | TASK-069 | Implement ExecPolicy DSL (declarative TOML command policy) | P1 | winsmux | cancelled |
| [ ] | TASK-071 | Implement Guardian sub-agent (AI risk scoring with cross-vendor check) | P1 | winsmux | cancelled |
| [ ] | TASK-072 | Implement Rollout recording (event sourcing + replay) | P2 | winsmux | cancelled |
| [ ] | TASK-075 | Implement SQLite session persistence (state.db) | P2 | winsmux | cancelled |
| [ ] | TASK-079 | Scheduled Orchestra (periodic multi-agent execution) | P3 | winsmux | cancelled |
| [ ] | TASK-080 | Browser agent integration (Multi-Modal Orchestra with Playwright) | P3 | winsmux | cancelled |

### post-v1.0.0

| | ID | Title | Priority | Repo | Status |
|-|-----|-------|----------|------|--------|
| [ ] | TASK-045 | Write REQUIREMENTS.md (functional reqs, NFR, acceptance criteria, traceability matrix) | P2 | winsmux | backlog |
| [ ] | TASK-046 | Write THREAT_MODEL.md (22 threat IDs mapped to injection-patterns.json, OCSF classification) | P2 | winsmux | backlog |
| [ ] | TASK-047 | Write ARCHITECTURE.md (4-layer diagram, 22 hooks, data flow, component diagram) | P2 | winsmux | backlog |
| [ ] | TASK-048 | Write DETAILED_DESIGN.md (hook I/O specs, regex, branch logic, test templates) | P2 | winsmux | backlog |
| [ ] | TASK-050 | Security audit against THREAT_MODEL.md (22 threats, pen-test all mitigations) | P2 | winsmux | backlog |
| [ ] | TASK-073 | Implement Command Orchestrator (per-command approval pipeline) | P2 | winsmux | backlog |
| [ ] | TASK-076 | Implement deferred network approval pattern | P2 | winsmux | backlog |

## 凡例

| 記号 | 意味 |
|------|------|
| [x] | 完了 |
| [-] | 作業中 |
| [R] | レビュー中 |
| [ ] | 未着手 |

| 優先度 | 意味 |
|--------|------|
| P0 | 最重要 |
| P1 | 高 |
| P2 | 中 |
| P3 | 低 |
