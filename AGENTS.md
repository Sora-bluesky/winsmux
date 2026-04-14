# Codex Project Rules — winsmux

## Scope

This file is for **Codex contributors operating inside this repository**.
It is not the public product guide for winsmux users.

Use these documents for public-facing product behavior instead:

- `README.md` for the product overview
- `docs/operator-model.md` for operator / pane / channel architecture
- `.claude/CLAUDE.md` for Claude Code operator guidance
- `AGENT-BASE.md` for the shared pane-agent contract
- `AGENT.md` for Codex pane guidance
- `GEMINI.md` for Gemini pane guidance

## Windows Sandbox: Constrained Language Mode Workaround (CRITICAL)

On Windows, the Codex sandbox (`unelevated`) runs PowerShell in ConstrainedLanguageMode.
This blocks Set-Content, Out-File, Add-Content, property assignments, and most file-editing cmdlets.

**You MUST use these alternatives for ALL file operations:**

### Writing/creating files

Use `apply_patch` (preferred) or `cmd /c`:

```
# PREFERRED: apply_patch for creating/editing files
apply_patch <<'EOF'
--- /dev/null
+++ path/to/file.ps1
@@ -0,0 +1,3 @@
+line 1
+line 2
+line 3
EOF

# ALTERNATIVE: cmd /c for simple writes
cmd /c "echo content > path\to\file.txt"
```

### Forbidden commands (will fail silently or error)

- `Set-Content` / `Out-File` / `Add-Content`
- `[IO.File]::WriteAllText()` / `[IO.File]::WriteAllBytes()`
- Property assignment on non-core types
- `New-Object` with non-core types

### Safe commands (these still work)

- `Get-Content` (reading files is allowed)
- `Test-Path`, `Get-Item`, `Get-ChildItem`
- `git` commands
- `cmd /c` (cmd.exe is not subject to CLM)
- `apply_patch` (Codex built-in tool, bypasses shell entirely)

## Project Context

winsmux is a Windows-native AI agent orchestration platform.
Builders operate in isolated git worktrees under `.worktrees/builder-N/`.

## Handoff Maintenance

`docs/handoff.md` is the only active handoff source of truth for this repo.
Treat repository-root `HANDOFF.md` files as historical unless the task is explicitly about consolidation.

Codex must update `docs/handoff.md` at these points:

1. After any milestone-level state change.
   - Examples: release completion, PR merge, roadmap/backlog progress shift, version closure, planning externalization.
2. Before autonomous `commit -> push -> PR -> merge -> cleanup`, if the task materially changes current state.
3. Before ending a session when there are material code, planning, test, or release changes.
4. When the user asks for current status / handoff / continuation context and the file is stale.

`docs/handoff.md` should stay concise and always include these sections:

- `Current state`
- `This session`
- `Validation`
- `Next actions`
- `Notes`

When updating handoff:

- Replace stale “next actions” that have already completed. Do not leave merged PR steps in place.
- If work is still in progress, record the active task, branch, changed files scope, and latest validation status.
- Reflect external planning truth when version progress changes.
- Prefer exact identifiers: version, task IDs, PR numbers, release status.

## Roadmap Localization Gate

`backlog.yaml` remains English-first, but `ROADMAP.md` is the Japanese-facing planning view for this repo.

When updating planning:

1. Keep task metadata in `backlog.yaml` in English unless the task explicitly requires otherwise.
2. Generate planning views through `winsmux-core/scripts/sync-roadmap.ps1`.
   - This now refreshes `ROADMAP.md` and the internal-only planning docs under `docs/internal/`.
3. Maintain Japanese roadmap title overrides in `tasks/roadmap-title-ja.psd1`.
4. For `v0.20.0` and later, do not allow English task titles to leak into `ROADMAP.md`.
   - If a new task is added or renamed in `backlog.yaml`, update the Japanese title override before considering roadmap sync complete.
5. Treat missing Japanese roadmap titles as a sync gate failure, not as acceptable drift.
6. Treat stale internal planning docs under `docs/internal/` as a sync failure when backlog-driven sections no longer match the external planning source of truth.

## Rust Learning Note Gate

When handoff work includes Rust, Cargo, Tauri, or Rust-adjacent commands used in winsmux development, Codex must also update the beginner-friendly learning note at:

- `C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\Learning\Rust Commands - winsmux.md`

Rules:

1. Keep the note outside the repository. Never commit files under the external `Learning` path.
2. Update the note during handoff in the same session that used the command, not later.
3. Explain each command in beginner-friendly Japanese:
   - what it does,
   - when to use it,
   - one concrete example from winsmux work.
4. Prefer updating existing entries over adding duplicates.
5. If the session did not use or discuss Rust-adjacent commands, no learning-note update is required.

## Orchestra Startup Gate

When using `/winsmux-start` or otherwise restoring orchestra-driven work from Claude Code:

1. Treat `external-commander: true` as **"no commander pane is created"**, not as **"worker panes may be absent"**.
2. A session is **not ready** when the winsmux session exists but the active pane count is smaller than the expected worker count from `.winsmux.yaml` / resolved `agent_slots`.
3. In that state, do not summarize status, propose task order, or dispatch work yet.
4. First run the actual startup path (`winsmux-core/scripts/orchestra-start.ps1`) and verify that the pane count reaches the expected worker count.
5. If pane expansion still fails, stop fail-closed and report the startup blocker clearly instead of falling back to local exploration or pretending orchestra is active.
6. `/winsmux-start` restoration must distinguish these three states explicitly:
   - `ready`: expected worker panes exist
   - `needs-startup`: session exists but worker panes are missing
   - `blocked`: startup was attempted and failed

## Release Notes Policy

GitHub Release titles and bodies must be written in English, regardless of the conversation language.

When generating or editing a release:

1. Use English section headings and bullets for the public GitHub Release body.
2. Follow the Codex GitHub Release template structure used in `openai/codex` releases.
   - Preferred headings are:
     - `New Features`
     - `Bug Fixes`
     - `Documentation`
     - `Chores`
     - `Full Changelog`
   - Omit empty sections rather than invent filler.
3. Keep the GitHub Release body aligned with the `/release-notes` structure, but in English and mapped onto the Codex-style headings above.
4. Link the compare range in `Full Changelog` when the repository and tag range support it.
5. Local or private post drafts may be Japanese if the task explicitly asks for them, but the public GitHub Release stays English.
6. When an item maps to a repository issue or PR, preserve that reference inline in the bullet in Codex style.
   - Prefer `(#315)` or `(#315, #318)` at the end of the bullet when the reference is available.
   - Do not strip issue/PR references out of release bullets during summarization if they materially help traceability.

## Public-vs-Dogfooding Release Gate

winsmux is dogfooded in this repository, so every release candidate must explicitly separate:

- public product-facing documentation and configuration, and
- maintainer / repo-operations / dogfooding-only material.

Before every version release, Codex must verify:

1. public-facing docs still describe winsmux for external users, not the maintainer's local workflow,
2. dogfooding-only rules stay in contributor/agent-operation documents,
3. release notes and README-facing docs do not leak private planning roots, personal paths, or maintainer-only rituals,
4. any newly added tracked files are classified as either:
   - public product surface, or
   - dogfooding/contributor surface.
5. when releasing `v0.21.2`, update `README.md` and `README.ja.md` so they describe the terminal-based final form as the last pre-Tauri release shape before the `v0.22.0` desktop control-plane handoff.

If drift is found, fix or explicitly track it before the release is finalized.

## Third-Party UI Attribution

When winsmux directly reuses or closely adapts UI assets, style definitions, menu/footer behavior, wrapping logic, or component code from external OSS projects, Codex must:

1. keep `THIRD_PARTY_NOTICES.md` updated,
2. record the upstream repository and source file paths,
3. preserve the original OSS license attribution in-repo,
4. mention the provenance in `docs/handoff.md` when the change is active in the current session.

For Codex-derived UI work, use `openai/codex` as the upstream reference and track the exact source areas being reused.

## Subagent Review Gate

Review agents are a required quality gate, but they must be operated predictably.

Codex must follow these rules:

1. Close completed subagents promptly after their result is integrated.
2. Prefer fresh review agents for new PR slices instead of keeping completed agents open.
3. For review requests, wait at least 30 seconds before treating the review as timed out unless the task is explicitly urgent.
4. A subagent timeout is not a PASS or FAIL result. It is only `no result yet`.
5. If a review agent times out, Codex may continue with a fallback gate only when:
   - the diff is small and well-scoped,
   - validation passes,
   - manual diff review is completed,
   - the timeout is explicitly recorded in `docs/handoff.md` or the PR summary.
6. Before merge, if a delayed subagent result arrives, Codex must incorporate that result into the final merge decision.
7. If review agents time out repeatedly across slices, Codex must treat that as a process issue and either:
   - reduce review scope,
   - reduce concurrent agents,
   - increase wait time,
   - or document the blocker clearly before continuing.
