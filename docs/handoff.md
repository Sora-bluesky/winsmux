# Handoff

> Updated: 2026-04-12T23:42:00+09:00
> Source of truth: this file

## Current state

- `v0.20.0`, `v0.20.1`, `v0.20.2`, `v0.20.3`, `v0.21.0`, and `v0.21.1` are released.
- `v0.21.2` is in release-prep. The shipped scope has been rebaselined to:
  - `TASK-216` terminal hot-path wrapper baseline
  - `TASK-295` winsmux-surface rename cleanup slice
- `ROADMAP.md` now shows `v0.21.2 = 100% (2/2)` and non-terminal follow-up work moved out to later versions.
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
- Manual diff review completed for the `README.md` / `README.ja.md` release-prep wording

## Next actions

1. Commit and push the `README.md` / `README.ja.md` release-prep wording.
2. Generate curated release notes and X draft for `v0.21.2`.
3. Create tag/release for `v0.21.2` and verify assets/body.
4. Update handoff again after the release is public and return the repo to a clean `main == origin/main` state.

## Notes

- `v0.21.1` is a baseline release, not the full advanced workflow/runtime roadmap.
- `TASK-216` is being landed as small hot-path wrapper slices rather than a single bridge-file refactor.
- `TASK-295` keeps `.psmux` compatibility paths untouched; those stay under the sunset plan instead of this rename slice.
- Public GitHub Releases stay English, use Codex-style headings, and keep inline issue/PR refs visible.
- `README.md` and `README.ja.md` must be updated again at `v0.21.2` release time to mark the terminal-based final form as the last pre-Tauri shape.
