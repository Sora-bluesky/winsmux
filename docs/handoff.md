# Handoff

> Updated: 2026-04-14T03:10:00+09:00
> Source of truth: this file

## Current state

- `v0.20.0`, `v0.20.1`, `v0.20.2`, `v0.20.3`, `v0.21.0`, `v0.21.1`, and `v0.21.2` are released.
- `v0.21.2` shipped as the terminal-based final form release before the `v0.22.0` Tauri control-plane handoff.
- `ROADMAP.md` is now treated as the Japanese-facing planning surface, while `backlog.yaml` remains English-first.
- internal-only docs under `docs/internal/` now include a user-facing feature inventory and a version-by-version manual verification checklist; both stay gitignored and now cover the current released, active, and post-`v1.0.0` planned lanes.
- `winsmux-core/scripts/sync-roadmap.ps1` now refreshes those internal docs as part of the same planning-sync flow, so backlog changes update `ROADMAP.md` and the two internal verification sheets together.
- Windows-first planning is explicit again; cross-platform work is no longer on the pre-`v1.0.0` path.
- public autonomous execution is now planned as a post-`v1.0.0` product line:
  - `v1.1.0` managed autonomous runs baseline
  - `v1.2.0` TDD / self-verification / run insights hardening
  - `v1.3.0` knowledge / playbooks / parallel managed runs
- enterprise-grade execution isolation is now planned as the next post-`v1.0.0` public line:
  - `v1.4.0` enterprise isolation profile foundation
  - `v1.5.0` brokered execution and enterprise guardrails
  - default execution remains `local-windows`; stronger isolation is added as an opt-in profile, not a replacement
- roadmap headings now match the actual task contents again:
  - `v0.22.1` is the Tauri desktop detail lane
  - `v0.23.0` is the psmux-free dogfooding gate
  - post-`v1.0.0` work is split into `post-v1.0.0-platform` and `post-v1.0.0-governance`
- `ROADMAP.md` shows `v0.21.2 = 100% (2/2)` with only:
  - `TASK-216` terminal hot-path wrapper baseline
  - `TASK-295` winsmux-surface rename cleanup slice
- Non-terminal follow-up work was moved out of `v0.21.2` to later versions before release.
- `v0.21.1` shipped as a workflow-baseline release for:
  - `TASK-163` phase-gated workflow baseline
  - `TASK-164` structured chaining baseline
  - `TASK-167` provider/model slot metadata baseline
  - `TASK-254` provider capability metadata baseline
  - `TASK-303` compare-runs baseline
  - `TASK-304` promote-tactic baseline
- Non-shipped `v0.21.1` work was moved out of the release:
  - `TASK-168`
  - `TASK-169`
  - `TASK-192`
  - `TASK-307`

## This session

- Started `v0.22.0: Tauri Control Plane Foundation (Backend-first adapter core)`.
- Merged PR #411 for the first `TASK-289 / TASK-291` backend-first adapter slice:
  - `winsmux-app/src-tauri/src/lib.rs` now exposes `desktop_summary_snapshot` and `desktop_run_explain`
  - the adapter shells out to `scripts/winsmux-core.ps1` for `board/inbox/digest/explain --json`
  - repo-root resolution is centralized so Tauri reads backend summary surfaces instead of treating PTY stdout as the primary state source
- Wired the frontend shell to hydrate from backend summary surfaces when available:
  - `winsmux-app/src/main.ts` now loads a desktop summary snapshot at startup
  - sessions, footer lane, selected run summary, and explain flow prefer backend `board/inbox/digest/explain` data
  - the seeded shell remains as fallback when the backend adapter is unavailable
- Merged PR #412 for the next `TASK-291` slice:
  - source summary, source filters, context list, and selected-run chips now derive from `digest.items` plus cached `explain` payloads
  - editor metadata and generated preview content now prefer backend `run/slot/evidence` fields over the old hardcoded `sourceControlState`
  - the seeded state remains only as fallback when no backend summary is available
- Merged PR #413 for the next `TASK-291` slice:
  - `winsmux-app/src-tauri/src/lib.rs` now emits `run_projections` from `board + digest + explain`
  - `winsmux-app/src/main.ts` now consumes projection DTOs for source summary, source filters, context list, and editor preview
  - projection consumers now use `pane label + branch` only; they no longer pretend to have separate source/worktree identity
  - `explain` remains detail drill-down only instead of acting as a hidden source-summary join input
- Started branch `codex/task105-desktop-client-seam-20260413` for the first `TASK-105` slice.
- Added `winsmux-app/src/desktopClient.ts` as the backend-facing seam for desktop snapshot/explain calls:
  - `main.ts` no longer invokes `desktop_summary_snapshot` or `desktop_run_explain` directly
  - backend contract types for summary/explain now live in the client module instead of the main shell
  - the current transport remains Tauri `invoke`, but the seam is ready for a later JSON-RPC / SDK swap
- Added `winsmux-app/src-tauri/src/desktop_backend.rs` as the backend transport boundary for desktop snapshot/explain calls:
  - `lib.rs` now delegates desktop commands to the backend module instead of holding the PowerShell script plumbing inline
  - command translation is centralized behind a small transport trait so a future JSON-RPC implementation can slot in without changing the Tauri command surface
  - the current behavior is unchanged; the slice only reduces coupling and makes the backend seam easier to extend
- Added `winsmux-app/src/ptyClient.ts` as the PTY transport seam for terminal pane lifecycle calls:
  - `main.ts` no longer invokes `pty_spawn`, `pty_write`, `pty_resize`, or `pty_close` directly
  - Tauri `invoke` remains the default transport implementation behind the helper module
  - the terminal pane behavior is unchanged; only the call boundary moved
- Landed `TASK-216` slice 1 and slice 2 on `main`:
  - PR #408: leaf wrapper consolidation for `commander-poll`, `pane-status`, and `pane-control`
  - PR #409: wrapper-based `orchestra-layout` session/window/pane flow
- Landed PR #410 for `TASK-295`:
  - renamed the tracked bridge regression file to `tests/winsmux-bridge.Tests.ps1`
  - updated `.gitignore`, `docs/handoff.md`, `scripts/generate-release-notes.ps1`, and embedded test fixture strings
  - kept `.psmux` registry/data-path references untouched as compatibility surface
- Reallocated non-shipped `v0.21.2` backlog to later versions so the release matches the actual shipped baseline:
  - `TASK-107`, `TASK-108`, `TASK-078` -> desktop detail rendering follow-up
  - `TASK-144` -> Tauri control-plane foundation follow-up
  - `TASK-143`, `TASK-154`, `TASK-306`, `TASK-115` -> later release/canary/GA tracks
- Updated `README.md` and `README.ja.md` to mark `v0.21.2` as the last terminal-primary release before `v0.22.0`.
- Released `v0.21.2`:
  - tag: `v0.21.2`
  - workflow: `24307042112` success
  - assets: `winsmux-x64.exe`, `winsmux-arm64.exe`, `SHA256SUMS`
  - release body replaced with the curated Codex-style notes
  - stray `release-body.md` asset removed
- Re-reviewed post-`v0.21.2` task placement and adjusted planning:
  - `TASK-306` -> `v0.22.0`
  - `TASK-310` -> `v0.24.3`
  - `TASK-115` -> `v0.24.5`
  - renamed `v0.24.1` to `Rust ledger, projections & session-state convergence`
- Started branch `codex/roadmap-ja-gate-20260413` for roadmap localization.
- Added `tasks/roadmap-title-ja.psd1` as the Japanese roadmap title overlay:
  - `backlog.yaml` stays English-first
  - `winsmux-core/scripts/sync-roadmap.ps1` now applies Japanese version/task title overrides only when generating `ROADMAP.md`
  - for `v0.20.0` and later, missing Japanese task titles now fail roadmap sync instead of silently leaking English titles
- Regenerated external `ROADMAP.md` from the English backlog through the new Japanese overlay/gate.
- Added a durable repo rule to `AGENTS.md`:
  - roadmap localization is a sync gate
  - new or renamed `v0.20.0+` tasks must update `tasks/roadmap-title-ja.psd1` before roadmap sync is considered complete
- There are carried-over local changes from the separate `TASK-105` transport branch in:
  - `winsmux-app/src/main.ts`
  - `winsmux-app/src/ptyClient.ts`
  These are intentionally outside the roadmap-localization slice and must not be staged with it.
- Added internal-only verification docs:
  - `docs/internal/winsmux-feature-inventory.md` now covers released / active / planned user-facing capabilities from `v0.1.0` through the current post-`v1.0.0` roadmap lanes
  - `docs/internal/winsmux-manual-checklist-by-version.md` now splits manual verification into a separate per-version checklist sheet and tracks the same roadmap horizon
- Added `TASK-316` to external planning under `v0.24.5`:
  - English title: `Version-by-version manual checklist + guided E2E validation before v1.0.0`
  - purpose: use the new internal docs to run a Codex-guided end-to-end verification pass before `v1.0.0`
  - `TASK-220` now depends on `TASK-316`, so the final release gate cannot pass before the guided verification is complete
- Expanded `TASK-316` and the manual checklist so the guided verification also captures reusable screen recordings:
  - the checklist now tracks `収録候補` alongside PASS / FAIL
  - success cases can be reused later for `README`, `SNS`, and `Zenn`
  - recording guidance explicitly excludes secrets, personal data, local-only paths, and other internal-only details
- Moved cross-platform work out of the pre-`v1.0.0` line:
  - `TASK-249`, `TASK-250`, `TASK-251`, `TASK-252`, `TASK-267`, `TASK-268`, and `TASK-271` now target `post-v1.0.0`
  - `TASK-270` no longer depends on the moved cross-platform Rust tasks
  - `TASK-316` no longer depends on `TASK-271`, so the guided pre-`v1.0.0` E2E track remains Windows-first
- Updated the internal-only verification docs to match the roadmap move:
  - `docs/internal/winsmux-feature-inventory.md`
  - `docs/internal/winsmux-manual-checklist-by-version.md`
- Reorganized roadmap presentation to reduce planning drift:
  - `winsmux-core/scripts/sync-roadmap.ps1` now applies Japanese version title overrides even when the backlog comments do not provide a default title
  - `tasks/roadmap-title-ja.psd1` now labels `v0.22.1` as the Tauri desktop detail lane and `v0.23.0` as the psmux-free dogfooding gate
  - `TASK-271` title wording now correctly says post-`v1.0.0`
  - `TASK-315` is now explicitly labeled as an internal-operations lane in both planning and internal docs
  - post-`v1.0.0` planning is split into:
    - `post-v1.0.0-platform` for Windows/Linux/macOS expansion
    - `post-v1.0.0-governance` for long-horizon design / security / approval work
- Added a dedicated public roadmap lane for Devin-style managed autonomy after `v1.0.0`:
  - moved `TASK-311` out of `v0.22.0` into `v1.1.0` as the autonomous run stage machine core
  - moved dependent `TASK-312` into `v1.3.0` so version ordering remains dependency-safe
  - added `TASK-317` to `TASK-326` for autonomous run contract, Claude-managed loop, draft-PR stop gate, TDD policy, self-verification, run insights, knowledge, playbooks, parallel child runs, and the human handoff cockpit
  - added Japanese roadmap title overlays for `v1.1.0`, `v1.2.0`, `v1.3.0`, and `TASK-317` to `TASK-326`
- Added the next public roadmap lane for enterprise-grade execution isolation after the autonomy line:
  - added `v1.4.0` for execution profile contract, isolated workspace runner, typed secret projection, and heartbeat/offline detection
  - added `v1.5.0` for brokered execution, short-lived run tokens, enterprise capability/network policy, and desktop visibility
  - kept `TASK-250` and `TASK-268` in `post-v1.0.0-governance`; the new `TASK-329` depends on them rather than moving them into the product lane
  - fixed the default direction to stay Windows-native (`local-windows`) and treat stronger isolation as `isolated-enterprise`
  - regenerated the external planning view after the new lane was added:
    - `C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\Projects\winsmux\planning\ROADMAP.md`
    - `v1.4.0` and `v1.5.0` now appear in the Japanese roadmap with localized titles
- Concretized the Scion-inspired roadmap intake into explicit product tasks:
  - added `TASK-335` for `phase / activity / detail` state semantics with `waiting_for_input`, `blocked`, and `offline`
  - added `TASK-337` for a progressive-skills CLI that agents can learn from via self-describing help surfaces
  - added `TASK-338` for explicit diversity policy across mixed model / harness teams
  - folded Scion-style notification subscriptions into existing `TASK-144` instead of creating a duplicate notification lane
  - folded role-vs-backend separation into the existing `TASK-324` + `TASK-327` boundary
  - folded late-bound credential resolution into `TASK-329` instead of splitting a second auth task
  - hardened `winsmux-core/scripts/sync-roadmap.ps1` so roadmap generation warns and skips malformed empty `target_version` entries instead of crashing on parameter binding
- Added internal planning-doc sync to the roadmap flow:
  - `winsmux-core/scripts/sync-internal-docs.ps1` now regenerates the backlog-driven sections of
    `docs/internal/winsmux-feature-inventory.md` and
    `docs/internal/winsmux-manual-checklist-by-version.md`
  - `winsmux-core/scripts/sync-roadmap.ps1` now calls that script automatically after roadmap generation
  - the volatile `進行中 / 今後予定` sections and checklist rows are now backlog-synced instead of hand-maintained
- Normalized external planning metadata for `TASK-144`:
  - fixed the malformed backlog indentation so `priority = P2` and `status = backlog` are emitted correctly into `ROADMAP.md`
  - regenerated the roadmap and internal planning docs through the standard sync flow

## Validation

- `git diff --check` -> warnings only for LF/CRLF normalization, no substantive errors
- `npm run build` in `winsmux-app` -> PASS after PTY seam extraction
- `cargo check` in `winsmux-app/src-tauri` -> PASS
- `cargo test --lib` in `winsmux-app/src-tauri` -> PASS for the backend transport boundary tests
- `pwsh -NoProfile -Command "& { & '.\scripts\winsmux-core.ps1' board --json }"` -> PASS
- `pwsh -NoProfile -Command "& { & '.\scripts\winsmux-core.ps1' digest --json }"` -> PASS
- `pwsh -NoProfile -Command "& { $digest = & '.\scripts\winsmux-core.ps1' digest --json | ConvertFrom-Json; if ($digest.items.Count -gt 0) { & '.\scripts\winsmux-core.ps1' explain $digest.items[0].run_id --json | Out-Null } }"` -> PASS
- `cargo check` in `winsmux-app/src-tauri` -> PASS after `desktopClient.ts` extraction
- `npm run build` in `winsmux-app` -> PASS after `desktopClient.ts` extraction
- Fresh reviewer `Dewey` -> `PASS` for the projection-driven source-context slice in PR #412
- Fresh reviewer `Herschel` -> `FAIL`; backend heuristic join removed after review
- Fresh reviewer `Singer` -> `FAIL`; field semantics corrected to avoid fake worktree/source identity
- Fresh reviewer `Socrates` -> `FAIL`; frontend branch/worktree leakage removed from filters and context copy
- Fresh reviewer `Aquinas` -> `PASS`; no blocking findings on the final `run_projections` slice
- PR #413 CI -> green (`Pester Tests`)
- Fresh reviewer `Lorentz` -> `no result yet` after two 35s waits; closed without result
- Manual diff review completed for the `TASK-291` projection-driven source-context slice
- PR #411 CI -> green (`Pester Tests`)
- PR #412 CI -> green (`Pester Tests`)
- Fresh reviewer `Dewey` -> `PASS` for the projection-driven source-context slice
- Fresh reviewer `Anscombe` -> `no result yet` after two 35s waits; closed without result
- Manual diff review completed for the `TASK-289 / TASK-291` adapter slice
- `Invoke-Pester tests/winsmux-bridge.Tests.ps1` -> `164/164 PASS`
- `Invoke-Pester tests/winsmux-bridge.Tests.ps1` -> `166/166 PASS` after the `orchestra-layout` slice
- `Invoke-Pester tests/winsmux-bridge.Tests.ps1` -> `166/166 PASS` after the `TASK-295` rename slice
- `git diff --check` -> warnings only for CRLF normalization, no substantive errors
- PowerShell parser check for:
  - `winsmux-core/scripts/commander-poll.ps1`
  - `winsmux-core/scripts/pane-status.ps1`
  - `winsmux-core/scripts/pane-control.ps1`
  - `tests/winsmux-bridge.Tests.ps1`
  -> PASS
- `git diff --check` -> warnings only, no substantive diff-check failures
- Explorer review `Aristotle` completed and recommended the leaf-script-first `TASK-216` slice
- PR #408 CI -> green (`Pester Tests`)
- PR #409 CI -> green (`Pester Tests`)
- Fresh reviewer `Mill` -> `no result yet` after two 35s waits; closed without result
- Manual diff review completed for the `TASK-216` leaf-wrapper slice
- Fresh reviewer `Wegener` -> `no result yet` after two 35s waits on the `orchestra-layout` slice; closed without result
- Manual diff review completed for the `orchestra-layout` wrapper slice
- Explorer `Pauli` -> rename-debt audit complete
- Explorer `Rawls` -> `v0.21.2` reallocation recommendation complete
- Fresh reviewer `Planck` -> `PASS` on the `TASK-295` rename slice
- Fresh reviewer `Sartre` -> `no result yet` after 45s on release-prep docs/planning diff; closed without result
- Release reviewer `Hypatia` -> `PASS` for `v0.21.2` release readiness
- Manual diff review completed for the `README.md` / `README.ja.md` release-prep wording
- GitHub release [v0.21.2](https://github.com/Sora-bluesky/winsmux/releases/tag/v0.21.2) published successfully
- `git check-ignore -v docs/internal/winsmux-feature-inventory.md` -> PASS
- `git check-ignore -v docs/internal/winsmux-manual-checklist-by-version.md` -> PASS
- external `winsmux planning backlog.yaml` updated with `TASK-316`
- external `winsmux ROADMAP.md` regenerated after adding `TASK-316`
- external `winsmux planning backlog.yaml` updated for the Windows-first roadmap change
- `pwsh -NoProfile -File winsmux-core/scripts/sync-roadmap.ps1` -> PASS after version-heading and post-`v1.0.0` bucket split
- external `winsmux planning backlog.yaml` metadata normalized for `TASK-144`
- `pwsh -NoProfile -File winsmux-core/scripts/sync-roadmap.ps1` -> PASS after the `TASK-144` metadata fix
- `pwsh -NoProfile -File winsmux-core/scripts/sync-roadmap.ps1` -> PASS after adding internal-doc auto-sync
- Manual diff review completed for the planning-sync flow (`sync-roadmap.ps1`, `sync-internal-docs.ps1`, `internal-docs-meta.psd1`)
- `/review` follow-up via subagent `Euclid` -> delayed `FAIL` on the planning/sync-only slice after the initial 30s wait
- follow-up fix after the delayed `Euclid` review:
  - `sync-roadmap.ps1` now validates missing Japanese version titles before writing `ROADMAP.md`, so the localization gate fails closed
  - `sync-internal-docs.ps1` now classifies `done` tasks as `公開済み` instead of leaving them in the generated `進行中` view
  - `docs/handoff.md` now describes the internal planning docs as extending through the current post-`v1.0.0` lanes
- follow-up reviewer `Lorentz` -> `PASS` on the fix-up slice for fail-closed roadmap generation, `done` classification, and handoff scope wording

## Next actions

1. Continue `v0.22.0` with the next transport substitution slice, likely a real file preview/read surface behind `winsmux-app/src-tauri/src/desktop_backend.rs`.
2. Keep `TASK-315` clearly marked as an internal-operations lane if more user-facing roadmap cleanup happens around `v0.22.0`.
3. Use `docs/internal/winsmux-manual-checklist-by-version.md` as the execution sheet when the guided end-to-end verification for `TASK-316` starts, including screen-capture candidates.
4. Keep the PTY seam limited to terminal pane lifecycle calls so follow-up refactors stay isolated.
5. Treat `TASK-317` as the first public autonomous-execution entrypoint after the `v1.0.0` release gate rather than mixing it into `TASK-315`.
6. Keep backlog-driven sections of the two internal verification docs generated through `sync-roadmap.ps1`; do not hand-edit those sections directly.
7. Treat `v1.4.0` / `v1.5.0` as opt-in enterprise isolation profiles that extend the Windows-native default rather than replacing it with container-first execution.

## Notes

- `v0.21.1` is a baseline release, not the full advanced workflow/runtime roadmap.
- `TASK-216` landed as small hot-path wrapper slices rather than a single bridge-file refactor.
- `TASK-295` keeps `.psmux` compatibility paths untouched; those stay under the sunset plan instead of this rename slice.
- Public GitHub Releases stay English, use Codex-style headings, and keep inline issue/PR refs visible.
- `ROADMAP.md` is Japanese-first for operator readability; `backlog.yaml` remains English-first as the canonical planning dataset.
- `docs/internal/` remains gitignored; internal verification docs must not be committed as public surface.
- The enterprise isolation plan intentionally does not make containers mandatory. It reserves room for container-backed or broker-backed isolation profiles without changing the default Windows-first operator model.
- `TASK-315` stays internal-only; the public autonomous execution line starts at `v1.1.0` with `TASK-317`.
- `docs/internal/winsmux-feature-inventory.md` and `docs/internal/winsmux-manual-checklist-by-version.md` now contain backlog-driven generated blocks. Manual prose can stay, but the generated blocks should be refreshed via `sync-roadmap.ps1`.
