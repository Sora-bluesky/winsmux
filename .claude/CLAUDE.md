# winsmux

Windows-native AI agent orchestration platform built on psmux.

## Quick Start

```powershell
# Session start (vault + trust + layout + agents + readiness check)
pwsh psmux-bridge/scripts/orchestra-start.ps1
```

psmux must be running before orchestra-start. If not running, user starts it manually (Start-Process breaks colors).

## Architecture

- **psmux-bridge/**: CLI plugin for psmux — vault, settings, role-gate, orchestra scripts
- **.claude/hooks/**: PreToolUse hooks for governance enforcement (git-tracked)
- **install.ps1**: Downloads sora-psmux fork binary from GitHub Releases

## Roles (Orchestra)

| Role | Allowed | Forbidden |
|------|---------|-----------|
| Commander | plan, dispatch, git ops, backlog | write/edit code, review code |
| Builder | implement in worktree | push, merge, direct main repo work |
| Reviewer | review diffs | implement |
| Researcher | investigate, report | implement |

Commander enforced by `.claude/hooks/sh-orchestra-gate.js` (PreToolUse hook).

## Commands

```powershell
# Pester tests (unit)
NO_COLOR=1 pwsh -Command "Invoke-Pester tests/ -Output Minimal"

# Syntax check
pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('psmux-bridge/scripts/orchestra-start.ps1', [ref]$null, [ref]$errors); if ($errors.Count -gt 0) { $errors } else { 'OK' }"

# Vault
pwsh scripts/psmux-bridge.ps1 vault list
pwsh scripts/psmux-bridge.ps1 vault set KEY value

# Version bump
pwsh scripts/bump-version.ps1 -Version X.Y.Z
```

## psmux send-keys Rules

- Always use `-l` flag (literal mode). Without it, commands silently vanish.
- Send Enter separately: `psmux send-keys -t %ID Enter`
- Wait for agent readiness (poll for `›` prompt) BEFORE sending prompts.
- Builder panes run pwsh — use PowerShell syntax, not bash.

## Worktree Rules

- Builders MUST work in `git worktree` (physical isolation from main repo).
- Never use `git clone --depth` (shallow clones break worktree creation).
- Collect output from worktree BEFORE deleting it.

## Hook System

Hooks are in `.claude/hooks/` (git-tracked, 25 files). Two registration layers:
- **settings.json** (git-tracked): all-user hooks (security baseline). Currently: sh-evidence.js のみ
- **settings.local.json** (gitignored): Commander-specific hooks (sh-orchestra-gate.js)

**Current status (v0.13.0)**: 25 hooks exist, 2 registered (orchestra-gate + evidence).
sh-utils.js 15関数実装済み (v0.13.0)。残り21本は v0.14.0〜v0.16.0 で段階的に有効化予定。
shield-harness init 復元済み（session.json + config テンプレート自動生成）。

## ROADMAP Sync

- `sync-roadmap.ps1` 実行後、`git add -f docs/project/ROADMAP.md` が必要（gitignore 例外）
- `git pull --rebase` 後は ROADMAP.md が古い状態に戻る場合あり → 再 sync 必要

## Git Rules

- **`git rm` 禁止。`git rm --cached` を使う。** bare `git rm` はローカルファイルも削除する（PR #79, #101 で2回事故）
- ブランチは feature branch で作業、main 直コミットは pre-commit hook がブロック

## Conventions

- Commit messages: English, conventional commits (`feat:`, `fix:`, `chore:`)
- PowerShell: strict mode, UTF-8, `$ErrorActionPreference = 'Stop'`
- Settings files (`settings.json`, `.claude.json`): edit via `python -c` (not Edit/Write tools — race condition)

## Task Status Rules

Allowed transitions: `backlog` → `wip` → `review` → `done`

| Status | Meaning | Gate |
|--------|---------|------|
| backlog | Not started or code exists but untested/gitignored | — |
| wip | Branch created, active development | git branch exists |
| review | PR open, code git-tracked, tests pass | `git ls-files` confirms tracked |
| done | PR merged + runtime test passed | merge commit on main |

**Never set `review` if the script is gitignored.** Run `sync-roadmap.ps1` to auto-detect and fix violations.

## Key Files

| File | Purpose |
|------|---------|
| `psmux-bridge/scripts/orchestra-start.ps1` | Full orchestra lifecycle |
| `psmux-bridge/scripts/settings.ps1` | Hierarchical settings (project > global > defaults) |
| `psmux-bridge/scripts/vault.ps1` | Windows Credential Manager integration |
| `.claude/hooks/sh-orchestra-gate.js` | Commander role enforcement |
| `tasks/backlog.yaml` | Task tracking (local only, gitignored) |
| `HANDOFF.md` | Session state handoff (local only) |

@HANDOFF.md
