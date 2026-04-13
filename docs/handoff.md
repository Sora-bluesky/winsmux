# Handoff

> Updated: 2026-04-13T20:05:00+09:00
> Source of truth: this file

## Current state

- `v0.20.0`, `v0.20.1`, `v0.20.2`, `v0.20.3`, `v0.21.0`, `v0.21.1`, and `v0.21.2` are released.
- `v0.21.2` shipped as the terminal-based final form release before the `v0.22.0` Tauri control-plane handoff.
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
- Merged PR #414 for the first `TASK-105` slice:
  - branch: `codex/task105-desktop-client-seam-20260413`
  - title: `feat: add tauri desktop client seam`
  - `Pester Tests` green before merge
- Started branch `codex/task105-desktop-client-transport-20260413` for the next `TASK-105` slice.
- Refactored `winsmux-app/src/desktopClient.ts` to use an injectable `DesktopCommandTransport`:
  - Tauri `invoke` is now the default transport implementation instead of the hardwired call site
  - `getDesktopSummarySnapshot` and `getDesktopRunExplain` now resolve through the transport interface
  - the next JSON-RPC slice can swap transport behavior without touching `main.ts`
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

## Validation

- `npm run build` in `winsmux-app` -> PASS
- `cargo check` in `winsmux-app/src-tauri` -> PASS
- `pwsh -NoProfile -Command "& { & '.\scripts\winsmux-core.ps1' board --json }"` -> PASS
- `pwsh -NoProfile -Command "& { & '.\scripts\winsmux-core.ps1' digest --json }"` -> PASS
- `pwsh -NoProfile -Command "& { $digest = & '.\scripts\winsmux-core.ps1' digest --json | ConvertFrom-Json; if ($digest.items.Count -gt 0) { & '.\scripts\winsmux-core.ps1' explain $digest.items[0].run_id --json | Out-Null } }"` -> PASS
- `git diff --check` -> warnings only for CRLF normalization, no substantive errors
- `cargo check` in `winsmux-app/src-tauri` -> PASS after `desktopClient.ts` extraction
- `npm run build` in `winsmux-app` -> PASS after `desktopClient.ts` extraction
- `git diff --check` -> warnings only for CRLF normalization, no substantive errors
- Fresh reviewer `Darwin` -> `PASS` for the `desktopClient.ts` seam slice
- PR #414 CI -> green (`Pester Tests`)
- `npm run build` in `winsmux-app` -> PASS after `DesktopCommandTransport` refactor
- `git diff --check` -> warnings only for CRLF normalization, no substantive errors
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

## Next actions

1. Open a PR for the `DesktopCommandTransport` abstraction slice on `codex/task105-desktop-client-transport-20260413`.
2. Continue `v0.22.0` with the next backend-first slice by swapping a concrete JSON-RPC transport implementation into `desktopClient.ts`.
3. Track startup latency from per-run `explain` fetches inside `desktop_summary_snapshot` if digest volume grows.

## Notes

- `v0.21.1` is a baseline release, not the full advanced workflow/runtime roadmap.
- `TASK-216` landed as small hot-path wrapper slices rather than a single bridge-file refactor.
- `TASK-295` keeps `.psmux` compatibility paths untouched; those stay under the sunset plan instead of this rename slice.
- Public GitHub Releases stay English, use Codex-style headings, and keep inline issue/PR refs visible.
