# Handoff

> Updated: 2026-04-12T17:02:00+09:00
> Source of truth: this file

## Current state

- `v0.20.0`, `v0.20.1`, `v0.20.2`, and `v0.20.3` are released.
- `v0.20.3` is closed at `100% (5/5)` with shipped scope:
  - `TASK-161`
  - `TASK-162` baseline only
  - `TASK-172`
  - `TASK-189`
  - `TASK-309`
- Issue `#260` is closed after the public troubleshooting workaround shipped in `v0.20.3`.
- All existing GitHub Releases on the public releases page were normalized to the latest Codex-style body/title format.
- `v0.12.1` exists as a git tag only and was not touched because no GitHub Release exists for it.
- Current branch is `main`.

## This session

- Merged PR `#405` and released `v0.20.3`.
- Rebased external planning so `v0.20.3` is `Governance Baseline, Env Contracts & Security Policy Enforcement` at `100% (5/5)`.
- Published the `v0.20.3` GitHub Release with Codex-style headings and inline issue refs.
- Updated `README.md`, `README.ja.md`, and `docs/TROUBLESHOOTING.md` so the Windows worktree sandbox workaround is described in external-user-safe language instead of maintainer workflow terms.
- Closed stale review agents after integrating results.
- Updated all historical GitHub Releases to the latest title/body format and fixed `scripts/generate-release-notes.ps1` so regenerated notes match the current Codex-style release structure.

## Validation

- PR `#405` CI passed:
  - `Pester Tests` green on run `24301402686`
- Local validation before merge:
  - PowerShell parser checks passed for the governance/env/security scripts
  - `node --check .claude/hooks/sh-session-start.js`
  - `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `149/149 PASS`
- Review gate history:
  - `/review` via Codex CLI timed out twice with `no result yet`
  - reviewer `Locke` -> `FAIL`, findings fixed
  - reviewer `Fermat` -> `FAIL`, findings fixed
  - reviewer `Hegel` -> `PASS`
  - release-readiness reviewer `Kepler` -> `FAIL`, docs/release-body issues fixed
  - release-readiness reviewer `Einstein` -> `PASS`
- Release-format normalization validation:
  - spot-checked `v0.1.0`, `v0.10.0`, `v0.20.2`, and `v0.20.3`
  - confirmed current releases use `New Features / Bug Fixes / Documentation / Chores / Full Changelog`
  - confirmed titles are normalized to plain `vX.Y.Z`

## Next actions

1. Commit and push the durable release-note generator change plus this handoff update.
2. Start `v0.21.0` from the rebalanced roadmap.
3. If `v0.12.1` should appear on the releases page, create a GitHub Release for the existing tag separately.

## Notes

- `TASK-162` intentionally shipped as a governance baseline only; per-call cost tracking moved to `TASK-310`.
- Public GitHub Releases stay English, use Codex-style headings, and keep inline issue/PR refs visible.
- `README.md` and `README.ja.md` must be updated again at `v0.21.2` release time to mark the terminal-based final form as the last pre-Tauri shape.
