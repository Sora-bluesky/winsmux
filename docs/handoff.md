# Handoff

> Updated: 2026-04-10T10:15+09:00
> Source of truth: this file

## Current state

- `v0.19.5` is released.
- `v0.19.6 hardening` is implemented and tracked as `100% (6/6)` in the external planning backlog/roadmap.
- PR [#370](https://github.com/Sora-bluesky/winsmux/pull/370) carries the repo-side hardening closure.
- Planning source of truth is externalized outside the public repository and syncs automatically into the private planning root.

## This session

- Closed the remaining `v0.19.6` hardening implementation in the repo.
- Added strict orchestra server health waiting and watchdog restart handling.
- Hardened `winsmux send` so redraw-only pane changes do not report false success.
- Added operator shell write-bypass blocking for direct code-file writes from non-worker panes.
- Updated external planning so `v0.19.6` is complete and `v0.19.8` exists in the roadmap.

## Validation

- Full local Pester suite passed: `171/171 PASS`
- Targeted hardening suite passed earlier: `133/133 PASS`
- CI on PR `#370` initially failed only because `Reset-OrchestraServerSession` called the `winsmux` binary directly in a test environment where the binary is unavailable.
- The repo now uses `Test-OrchestraServerSession` for that check so CI can be rerun cleanly.

## Next actions

1. Push the CI-only fix for PR `#370`.
2. Confirm GitHub Actions is green.
3. Merge PR `#370`.
4. Delete the merged feature branch.
5. Start `v0.19.7` or `v0.19.8` depending on orchestration priorities.

## Notes

- `HANDOFF.md` at the repository root is historical context and no longer authoritative.
- Public tracked files must not contain personal paths or private planning roots.
