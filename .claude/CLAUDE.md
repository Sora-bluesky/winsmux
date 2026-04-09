# winsmux

Windows-native AI agent orchestration platform built on winsmux-core.

## Quick Start

```powershell
# Session start (vault + trust + layout + agents + readiness check)
pwsh winsmux-core/scripts/orchestra-start.ps1
```

winsmux must be running before orchestra-start. If not running, user starts it manually (Start-Process breaks colors).

## Architecture

- `winsmux-core/`: CLI core for vault, settings, role gates, orchestra scripts.
- `.claude/hooks/`: PreToolUse hooks for governance enforcement.
- `install.ps1`: Downloads the winsmux-core binary from GitHub Releases.

## Roles (Orchestra)

The default model is now **external Commander + background workers**.

| Role | Agent | Allowed | Forbidden |
|------|-------|---------|-----------|
| Commander | Claude Code / Codex outside the managed window | plan, dispatch, git ops, backlog, final judgement | background pane execution as the sole control plane |
| Worker | Codex in managed panes | implement, investigate, verify, review when assigned | direct ownership of the main repo lifecycle |

Legacy `Builder / Researcher / Reviewer` pane layouts remain available only for explicit compatibility mode.

Roles are advisory. Hard enforcement is via hooks (`sh-orchestra-gate.js` for Commander) and winsmux role gates inside managed panes.

**Enforcement**: CLAUDE.md is advisory, not enforced. Use hooks for deterministic enforcement. See GUARDRAILS.md for recurring failures.

## Rules

Topic-specific rules are in `.claude/rules/`. Path-specific rules use `paths:` frontmatter.

## Commands

```powershell
# Pester tests (unit)
NO_COLOR=1 pwsh -Command "Invoke-Pester tests/ -Output Minimal"

# Syntax check
pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('winsmux-core/scripts/orchestra-start.ps1', [ref]$null, [ref]$errors); if ($errors.Count -gt 0) { $errors } else { 'OK' }"

# Vault
pwsh scripts/winsmux-core.ps1 vault list
pwsh scripts/winsmux-core.ps1 vault set KEY value

# Version bump
pwsh scripts/bump-version.ps1 -Version X.Y.Z
```

## winsmux send-keys Rules

- Always use `-l` (literal mode). Without it, commands silently vanish.
- Send Enter separately: `winsmux send-keys -t %ID Enter`.
- Wait for agent readiness (`›` prompt) before sending prompts.
- Builder panes run pwsh; use PowerShell syntax, not bash.

## Worktree Rules

- Builders must work in `git worktree` isolation, never the main repo.
- Never use `git clone --depth`; shallow clones break worktree creation.
- Collect output from the worktree before deleting it.

## Git Rules

- See [GUARDRAILS.md](GUARDRAILS.md) for recurring failure prevention.
- Use feature branches; direct commits to `main` are blocked by hooks.

## Conventions

- Commit messages: English, conventional commits (`feat:`, `fix:`, `chore:`).
- PowerShell: strict mode, UTF-8, `$ErrorActionPreference = 'Stop'`.
- Settings file (`.claude/settings.json`): edit via `python -c` to avoid race conditions.

## CLM Compatibility (Codex scripts)

- Use `[ordered]@{}` instead of `[PSCustomObject]@{}`
- Use hashtable assignment (`$obj['key'] = val`) instead of `Add-Member`
- Codex context reset: `/new` (not `/clear`). `/compact` for context shrink.
- Sandbox uses `--sandbox danger-full-access` to bypass CLM (#319). Builders can run Pester directly.

## Task Status Rules

Allowed transitions: `backlog` -> `wip` -> `review` -> `done`

- `backlog`: not started, or code exists but is untested/gitignored.
- `wip`: branch exists and active development is in progress.
- `review`: PR is open, code is git-tracked, and tests pass.
- `done`: PR is merged and runtime verification passed.
- Never set `review` if the script is gitignored; run the local-only `sync-roadmap.ps1` to auto-correct violations.

## ROADMAP Sync

Planning artifacts are local-only and maintained outside the repo. Generate or refresh them with `sync-roadmap.ps1`, which resolves the external planning paths via `WINSMUX_PLANNING_ROOT`, `WINSMUX_BACKLOG_PATH`, and `WINSMUX_ROADMAP_PATH`.

@HANDOFF.md
