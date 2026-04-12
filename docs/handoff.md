# Handoff

> Updated: 2026-04-12T21:35:00+09:00
> Source of truth: this file

## Current state

- `v0.20.0`, `v0.20.1`, and `v0.20.2` are released.
- `v0.20.3` shipped scope is rebaselined locally to these 5 tasks and is pending PR/merge/release:
  - `TASK-161`
  - `TASK-162` baseline only
  - `TASK-172`
  - `TASK-189`
  - `TASK-309`
- Follow-up work is moved out of `v0.20.3`:
  - `TASK-190`
  - `TASK-248`
  - `TASK-306`
  - `TASK-307`
  - `TASK-310`
- Current working branch is `codex/v0203-governance-env-security-20260412`.

## This session

- Added `winsmux-core/scripts/pane-env.ps1` to formalize hook-profile / governance-mode resolution and pane env payload generation.
- Updated `winsmux-core/scripts/orchestra-start.ps1` and `scripts/start-orchestra.ps1` to use the shared pane env / hook-profile contract.
- Extended `winsmux-core/scripts/doctor.ps1` with hook profile, governance mode, and `WINSMUX_*` env contract checks.
- Added send-side security policy blocking in `scripts/winsmux-core.ps1` and one-shot pre-dispatch policy blocking in `winsmux-core/scripts/team-pipeline.ps1`.
- Documented the Codex worktree git sandbox limitation in `README.md`, `README.ja.md`, and `docs/TROUBLESHOOTING.md`.
- Rebaselined external planning locally so `v0.20.3` now reads as `Governance Baseline, Env Contracts & Security Policy Enforcement`; final `done` state will be applied only after merge/release.
- Ran `/review` twice via Codex CLI against the current working-tree diff; both attempts timed out with `no result yet`.
- Spawned fresh review explorers `Fermat` and `Locke`; both also remain `no result yet` after a 35-second wait and have not yet produced findings.

## Validation

- PowerShell parser checks passed for:
  - `winsmux-core/scripts/pane-env.ps1`
  - `winsmux-core/scripts/orchestra-start.ps1`
  - `winsmux-core/scripts/team-pipeline.ps1`
  - `winsmux-core/scripts/doctor.ps1`
  - `scripts/start-orchestra.ps1`
  - `scripts/winsmux-core.ps1`
- `node --check .claude/hooks/sh-session-start.js` passed.
- `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `148/148 PASS`.
- `git diff --check` shows only benign `LF -> CRLF` warnings on edited files.
- Review gate status: `no result yet`; fallback gate is currently `manual diff review + parser checks + 148/148 PASS + git diff --check`.

## Next actions

1. Wait once more for fresh review results; if none arrive, proceed with fallback gate.
2. Commit, push, and open the `v0.20.3` implementation PR from `codex/v0203-governance-env-security-20260412`.
3. Merge after CI, publish `v0.20.3`, and close issue `#260`.

## Notes

- Public GitHub Releases must stay English and use the Codex-style headings plus inline issue/PR refs.
- `TASK-162` is intentionally shipped as a governance baseline only; per-call cost tracking moved to `TASK-310`.
- Before release, re-run the public-vs-dogfooding gate and keep the README/troubleshooting language external-user-safe.
