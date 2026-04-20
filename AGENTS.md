# Codex Project Rules — winsmux

## Scope

This file is for **Codex contributors operating inside this repository**.
It is not the public product guide for winsmux users.

Use these documents for public-facing product behavior instead:

- `README.md` for the product overview
- `docs/operator-model.md` for operator / pane / channel architecture

Contributor/runtime contracts for managed panes live in:

- `AGENT-BASE.md`
- `AGENT.md`
- `GEMINI.md`

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

The live handoff source of truth for Claude Code dogfooding is the ignored local file:

- `.claude/local/operator-handoff.md`

Treat tracked handoff files under `docs/` or repository root as migration leftovers only.
They must not be used as live operational state, and they should be removed from tracked history when touched by public-surface cleanup work.

Codex must update `.claude/local/operator-handoff.md` at these points:

1. After any milestone-level state change.
   - Examples: release completion, PR merge, roadmap/backlog progress shift, version closure, planning externalization.
2. Before autonomous `commit -> push -> PR -> merge -> cleanup`, if the task materially changes current state.
3. Before ending a session when there are material code, planning, test, or release changes.
4. When the user asks for current status / handoff / continuation context and the file is stale.

`.claude/local/operator-handoff.md` should stay concise and always include these sections:

- `Current state`
- `This session`
- `Validation`
- `Next actions`
- `Notes`

When updating the local operator handoff:

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
3. Maintain live Japanese roadmap title overrides in the external planning root `roadmap-title-ja.psd1`.
4. The repository copy is only `tasks/roadmap-title-ja.example.psd1` and must remain example-only.
5. For `v0.20.0` and later, do not allow English task titles to leak into `ROADMAP.md`.
   - If a new task is added or renamed in `backlog.yaml`, update the Japanese title override before considering roadmap sync complete.
6. Treat missing Japanese roadmap titles as a sync gate failure, not as acceptable drift.
7. Treat stale internal planning docs under `docs/internal/` as a sync failure when backlog-driven sections no longer match the external planning source of truth.

## Rust Learning Note Gate

When local operator handoff work includes Rust, Cargo, Tauri, or Rust-adjacent commands used in winsmux development, Codex must also update the beginner-friendly learning note resolved from one of these sources:

- `WINSMUX_LEARNING_ROOT\Rust learning note\00 Index.md`
- `%LOCALAPPDATA%\winsmux\learning-root.txt` marker + `Rust learning note\00 Index.md`
- compatibility fallback:
  - `WINSMUX_LEARNING_ROOT\Rust learning note.md`
  - `%LOCALAPPDATA%\winsmux\learning-root.txt` marker + `Rust learning note.md`
  - `WINSMUX_LEARNING_ROOT\Rust Commands - winsmux.md`
  - `%LOCALAPPDATA%\winsmux\learning-root.txt` marker + `Rust Commands - winsmux.md`

Rules:

1. Keep the note outside the repository. Never commit files under the external `Learning` path.
2. Update the note during handoff in the same session that used the command, not later.
3. Prefer `Rust learning note/00 Index.md` as the canonical entry page for new updates. Use `Rust learning note.md` or `Rust Commands - winsmux.md` only as backward-compatibility fallbacks.
4. Every Rust-adjacent session note update must preserve these three fields for each command or concept entry:
   - the command or concept itself,
   - one concrete example from winsmux work,
   - the corresponding Rust Book chapter or nearest beginner-facing Rust concept.
5. Explain each command in beginner-friendly Japanese:
   - what it does,
   - when to use it,
   - one concrete example from winsmux work.
6. Prefer updating existing entries over adding duplicates.
7. Keep the note structure readable in Obsidian sidebar form.
   - Maintain `Rust learning note/00 Index.md` as the entry page.
   - Prefer Rust Book-aligned chapter titles under `Rust learning note/` (for example `4. 所有権を理解する`, `11. 自動テストを書く`, `21.4. 付録D：便利な開発ツール`).
   - Keep helper files such as templates outside the main TOC by using a non-book prefix like `_`.
   - Update the index note when a new chapter note is added.
8. If the session did not use or discuss Rust-adjacent commands, no learning-note update is required.

## Private Maintainer Skill Gate

Internal maintainer skill packs must not be tracked in the public repository.

When a maintainer-only workflow needs private skills:

1. Resolve the private skills root in this order:
   - `WINSMUX_PRIVATE_SKILLS_ROOT`
   - `%LOCALAPPDATA%\winsmux\private-skills-root.txt`
2. The resolved root is expected to contain maintainer-only skill content outside the public repo.
   - The exact skill names and bodies stay outside the public repository.
3. If the private skills root is unavailable, treat that as a maintainer warning, not a public-repo blocker.
   - Do not recreate or track the missing skill bodies inside this repository.
4. Do not expose private maintainer skills in public product docs, README flows, or tracked public-facing guidance.

When editing or reviewing Rust, Cargo, or Tauri code in this repository:

1. Use the private maintainer Rust guard skill from the resolved private skills root.
2. Public repo files under `.agents/**` must stay public-safe only.
   - They may document the boundary, but they must not contain maintainer-only skill bodies.
3. For merge-critical or ecosystem-sensitive Rust/Tauri slices, run one explorer-style subagent using the private Rust ecosystem radar skill before the final review or merge decision.
   - Typical triggers:
     - Windows subprocess / path / current-dir logic
     - Cargo workspace or bootstrap behavior
     - security-sensitive dependency or registry changes
     - Tauri runtime / desktop backend contract changes
4. If the radar pass finds material drift, record the date and takeaway in `.claude/local/operator-handoff.md`.
5. If the radar pass finds no material drift, that is still a valid result; record it briefly when the slice is merge-critical.

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

## Issue Escalation Gate

When a new product, startup, orchestration, CI, or operator workflow problem is observed:

1. Search for an existing GitHub issue first. Reuse it if the same root cause is already tracked.
2. If no matching issue exists, create one before treating the problem as resolved.
3. Every issue must have at least one GitHub label before the session ends.
4. Prefer existing repository labels first. For winsmux, the default working set is:
   - `bug`
   - `chore`
   - `debug`
   - `documentation`
   - `enhancement`
   - `orchestration`
   - `question`
   - `review`
   - `security`
   - `testing`
5. Only create a new custom label when none of the existing labels describe the issue well enough, and record that choice in `.claude/local/operator-handoff.md`.
6. Record the exact reproduction symptom, current hypothesis, mitigation, and the PR or commit that addressed it.
7. Update `.claude/local/operator-handoff.md` with the issue number, labels, and current resolution state in the same session.
8. Do not silently "just fix and move on" for operational failures that could recur.
9. If the problem is only partially understood, still create the issue and mark the remaining uncertainty explicitly.
10. After creating or materially updating a non-duplicate issue, map it into planning in the same session unless it is explicitly triage-only, invalid, duplicate, or upstream-only.
11. Planning mapping means:
   - link the issue to an existing `TASK-*`, or add a new `TASK-*` in the external `backlog.yaml`,
   - place it in the most appropriate version lane instead of defaulting to a catch-all bucket,
   - when a task is created primarily to track a GitHub issue, append the issue reference to the task title itself (for example `(#423)`),
   - add or update the external planning root `roadmap-title-ja.psd1` when roadmap sync would expose the task,
   - run `winsmux-core/scripts/sync-roadmap.ps1`,
   - and record the issue-to-task mapping in `.claude/local/operator-handoff.md`.
12. Treat "issue filed but not taskified" as incomplete operational bookkeeping unless the session explicitly documents why taskification is deferred.

## Orchestra Boundary Gate

When changing orchestra startup, restore, attach, watchdog, or rollback behavior:

1. Do not solve the problem by adding more inline branching to one monolithic startup path unless no boundary-preserving option exists.
2. Keep these responsibilities explicitly separable:
   - detached session/bootstrap creation,
   - visible UI attach,
   - manifest/session-state persistence,
   - watchdog launch,
   - rollback/cleanup.
3. Treat `session-ready`, `ui-attach-launched`, and `ui-attached` as different states. Do not collapse them into one success flag.
4. If a change touches more than one of the responsibilities above, add or update tests that exercise the boundary directly.
5. For startup regressions, prefer extracting a helper or state contract over patching more conditions into `orchestra-start.ps1`.
6. Keep an operator-independent startup smoke path available.
   - `winsmux orchestra-smoke --json` is the preferred quick check and must expose a structured `operator_contract`.
   - Treat `operator_contract.operator_state`, `operator_contract.can_dispatch`, and `operator_contract.requires_startup` as the startup source of truth.
   - Do not make `/winsmux-start` the only way to validate orchestra startup.
7. If the fix reveals a structural boundary problem rather than a one-off defect, open or update an issue and map it to planning in the same session.

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
4. mention the provenance in `.claude/local/operator-handoff.md` when the change is active in the current session.

For Codex-derived UI work, use `openai/codex` as the upstream reference and track the exact source areas being reused.

## Subagent Review Gate

Review agents are a required quality gate, but they must be operated predictably.

Codex must follow these rules:

1. Close completed subagents promptly after their result is integrated.
2. Prefer fresh review agents for new PR slices instead of keeping completed agents open.
3. For review requests, do not use a single fixed wait time.
   - Small TypeScript/docs-only slices: wait at least 60 seconds before fallback.
   - Rust/Tauri/PowerShell/orchestration slices: wait at least 120 seconds before fallback.
4. A subagent timeout is not a PASS or FAIL result. It is only `no result yet`.
5. If the review is merge-critical and still `no result yet`, Codex should allow one additional wait of the same duration before falling back, unless the task is explicitly urgent.
6. Keep review concurrency at `1` unless the user explicitly asks for broader parallel review.
7. Avoid `fork_context=true` for review agents unless the diff cannot be reviewed correctly without full thread context.
8. If a review agent still has `no result yet`, Codex may continue with a fallback gate only when:
   - the diff is small and well-scoped,
   - validation passes,
   - manual diff review is completed,
   - the `no result yet` status is explicitly recorded in `.claude/local/operator-handoff.md` or the PR summary.

## Public Surface Gate

winsmux uses one repository with five distinct surfaces:

- public product surface
- runtime contract surface
- contributor/test surface
- private live-ops surface
- generated/runtime artifacts

The canonical classification is documented in `docs/repo-surface-policy.md`.
Tracked files must belong to the public product surface, the runtime contract surface, or the contributor/test surface.
Private live-ops files and generated artifacts must not be tracked.

## Git-Guard Gate

`git-guard` is mandatory. Do not treat it as optional local hygiene.

1. After cloning or resetting a local workspace, run `pwsh -NoProfile -File scripts/bootstrap-git-guard.ps1`.
2. The repository-managed hooks under `.githooks/` are the source of truth.
3. `git config --get core.hooksPath` must resolve to `.githooks` before `commit -> push -> PR -> merge`.
4. `.githooks/pre-commit` and `.githooks/pre-push` must run the repository `scripts/git-guard.ps1`.
5. CI must also run `scripts/git-guard.ps1` and `scripts/audit-public-surface.ps1`.
6. Do not bypass git-guard for:
   - secret-like files or tokens,
   - maintainer-local path leaks,
   - tracked live handoff or planning override files,
   - runtime artifacts such as `.winsmux/` or `.orchestra-prompts/`.
7. If git-guard or the public-surface audit fails, stop fail-closed and fix the classification or leak before continuing.
9. Before merge, if a delayed subagent result arrives, Codex must incorporate that result into the final merge decision.
10. If review agents repeatedly return `no result yet` across slices, Codex must treat that as a process issue and either:
   - reduce review scope,
   - reduce concurrent agents,
   - increase wait time,
   - open or update a tracking issue,
   - or document the blocker clearly before continuing.

## Subagent Latency Mitigation

Repeated `no result yet` responses are treated as a latency problem first, not as an implicit PASS.

Codex must follow these rules when review or audit agents are slow:

1. For Rust/Tauri slices, or any review touching more than 2 files, wait at least 60 seconds before the first timeout decision.
2. For small TypeScript / docs-only slices, wait at least 60 seconds before the first timeout decision.
   - Desktop UI, composer, CSS, viewport harness, and other interaction slices are included in this bucket.
3. Keep review concurrency to 1 agent at a time for Rust/Tauri work. If a separate explorer is needed, do not run more than 2 total subagents on the same slice.
4. Prefer narrow prompts and explicit file paths over `fork_context=true` for routine reviews. Only fork full context when the review truly depends on prior thread state.
5. If two consecutive review agents on the same slice return `no result yet`, stop spawning more review agents for that slice until either:
   - the diff is reduced,
   - the wait time is increased,
   - or the blocker is documented and manual diff fallback is used.
6. If the same review agent returns `no result yet` twice, keep that agent alive in the background.
   - Do not report review as complete.
   - Do not merge before the delayed result is incorporated.
   - Continue only with non-overlapping local work, local validation, and manual diff review while waiting.
7. When a delayed review result arrives after a timeout, record the latency pattern in `.claude/local/operator-handoff.md` and use that result in the final decision.
8. If the same PR accumulates multiple tiny desktop UI slices and `no result yet` repeats across those slices, stop per-slice review for that PR.
   - Switch to milestone-based review instead.
   - A milestone is a semantically meaningful bundle such as:
     - one new surface,
     - one completed interaction flow,
     - or a ready-for-review PR state.
9. While milestone-based review is active, every interim slice must still pass local validation and manual diff review before commit/push.
10. Record the switch to milestone-based review in `.claude/local/operator-handoff.md` and link the tracking issue when one exists.
