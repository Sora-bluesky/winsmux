# Handoff

> Updated: 2026-04-12T23:18:00+09:00
> Source of truth: this file

## Current state

- `v0.20.0`, `v0.20.1`, `v0.20.2`, `v0.20.3`, `v0.21.0`, and `v0.21.1` are released.
- `v0.21.2` is active. `TASK-216` has two landed slices on `main`:
  - PR #408: leaf wrapper consolidation for `commander-poll`, `pane-status`, and `pane-control`
  - PR #409: wrapper-based `orchestra-layout` session/window/pane flow
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

- Started `v0.21.2: Terminal-Based Final Form & Session Ergonomics`.
- Landed `TASK-216` slice 1 and slice 2 on `main`, keeping the bridge-file refactor deferred while consolidating hot-path wrapper calls first.
- Started `TASK-295` on branch `codex/task295-rename-surface-20260412`.
- Renamed the tracked bridge regression file to `tests/winsmux-bridge.Tests.ps1`.
- Updated tracked references in:
  - `.gitignore`
  - `docs/handoff.md`
  - `scripts/generate-release-notes.ps1`
  - `tests/winsmux-bridge.Tests.ps1`
- Confirmed that `.psmux` registry/data-path references remain compatibility surface and stay out of this rename slice.
- Explorer `Pauli` completed the rename-debt scope audit and was closed.
- Explorer `Rawls` completed the `v0.21.2` reallocation review and was closed.
- Fresh reviewer `Planck` returned `PASS` for the `TASK-295` rename slice and was closed.

## Validation

- `Invoke-Pester tests/winsmux-bridge.Tests.ps1` -> `164/164 PASS`
- `Invoke-Pester tests/winsmux-bridge.Tests.ps1` -> `166/166 PASS` after the `orchestra-layout` slice
- `Invoke-Pester tests/winsmux-bridge.Tests.ps1` -> `166/166 PASS` after the `TASK-295` rename slice
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

## Next actions

1. Commit, push, and merge the `TASK-295` rename slice.
2. Rebaseline `v0.21.2` so only terminal-final-form core remains in the version, and move non-core desktop/packaging work out.
3. Update `README.md` and `README.ja.md` at `v0.21.2` release time to mark the terminal-based final form before `v0.22.0`.
4. Generate curated release notes and publish `v0.21.2`.

## Notes

- `v0.21.1` is a baseline release, not the full advanced workflow/runtime roadmap.
- `TASK-216` is being landed as small hot-path wrapper slices rather than a single bridge-file refactor.
- `TASK-295` keeps `.psmux` compatibility paths untouched; those stay under the sunset plan instead of this rename slice.
- Public GitHub Releases stay English, use Codex-style headings, and keep inline issue/PR refs visible.
- `README.md` and `README.ja.md` must be updated again at `v0.21.2` release time to mark the terminal-based final form as the last pre-Tauri shape.
