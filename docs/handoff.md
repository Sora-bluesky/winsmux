# Handoff

> Updated: 2026-04-12T16:40:38+09:00
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
- Current branch is `main`.

## This session

- Merged PR `#405` and released `v0.20.3`.
- Rebased external planning so `v0.20.3` is `Governance Baseline, Env Contracts & Security Policy Enforcement` at `100% (5/5)`.
- Published the `v0.20.3` GitHub Release with Codex-style headings and inline issue refs.
- Updated `README.md`, `README.ja.md`, and `docs/TROUBLESHOOTING.md` so the Windows worktree sandbox workaround is described in external-user-safe language instead of maintainer workflow terms.
- Closed stale review agents after integrating results.

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

## Next actions

1. Push the final public-doc wording and handoff updates that were made during the `v0.20.3` release gate.
2. Verify the `v0.20.3` release assets are limited to `winsmux-x64.exe`, `winsmux-arm64.exe`, and `SHA256SUMS`.
3. Start `v0.21.0` from the rebalanced roadmap.

## Notes

- `TASK-162` intentionally shipped as a governance baseline only; per-call cost tracking moved to `TASK-310`.
- Public GitHub Releases stay English, use Codex-style headings, and keep inline issue/PR refs visible.
- `README.md` and `README.ja.md` must be updated again at `v0.21.2` release time to mark the terminal-based final form as the last pre-Tauri shape.
