# Handoff

> Updated: 2026-04-12T23:59:00+09:00
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

1. Start `v0.22.0: Tauri Control Plane Foundation (Backend-first adapter core)`.
2. Keep the release workflow follow-up in view if `release-body.md` should stop being uploaded automatically in future releases.
3. Preserve the `v0.21.2` README wording until `v0.22.0` materially changes the public surface.

## Notes

- `v0.21.1` is a baseline release, not the full advanced workflow/runtime roadmap.
- `TASK-216` landed as small hot-path wrapper slices rather than a single bridge-file refactor.
- `TASK-295` keeps `.psmux` compatibility paths untouched; those stay under the sunset plan instead of this rename slice.
- Public GitHub Releases stay English, use Codex-style headings, and keep inline issue/PR refs visible.
