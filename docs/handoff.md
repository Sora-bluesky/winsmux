# Handoff

> Updated: 2026-04-12T19:05:00+09:00
> Source of truth: this file

## Current state

- `v0.20.0`, `v0.20.1`, `v0.20.2`, `v0.20.3`, and `v0.21.0` are released.
- `v0.21.0: Operator Core & Slot Dispatch` is closed at shipped-baseline scope and publicly released.
- Released-version roadmap drift is fixed:
  - `v0.20.0` baseline tasks are now marked done
  - `v0.20.1` baseline tasks are now marked done
  - `v0.21.0` shipped baseline tasks are now marked done
- `v0.21.0` follow-up backlog moved out of the release:
  - `TASK-167`
  - `TASK-254`
  - `TASK-306`
  - `TASK-310`
- Current branch is `main`.

## This session

- Audited `v0.21.0` against the actual repo state and corrected planning drift.
- Rebased external planning so `v0.21.0` reflects the shipped baseline:
  - `TASK-213` unified slot architecture baseline
  - `TASK-255` autonomous dispatch baseline
  - `TASK-165` slot-level provider/model selection baseline
  - `TASK-302` consultation loop baseline
  - `TASK-166` model resolution baseline
  - `TASK-190` ConPTY clean environment baseline
  - `TASK-191` `/task-run` baseline
  - `TASK-248` config version baseline + metadata surface
- Moved non-shipped follow-ups out of `v0.21.0`:
  - `TASK-167` and `TASK-254` to `v0.21.1`
  - `TASK-306` to `v0.21.2`
  - `TASK-310` to `v0.24.1`
- Implemented the missing baseline code to match the rebaselined `v0.21.0` scope:
  - `config_version` fail-closed contract and metadata surface
  - clean ConPTY env scrub/reinject helper
  - doctor metadata check
  - `/task-run` alias for one-shot pipeline entry
- Opened PR `#406`, ran a fresh `/review`, merged the closure slice, and published `v0.21.0`.
- Corrected the generated GitHub Release body after publish so it uses the curated `v0.21.0` notes and only the three public assets remain.
- Closed completed explorer/reviewer subagents after their results were integrated.

## Validation

- PowerShell parser checks passed for:
  - `scripts/winsmux-core.ps1`
  - `winsmux-core/scripts/settings.ps1`
  - `winsmux-core/scripts/pane-env.ps1`
  - `winsmux-core/scripts/orchestra-start.ps1`
  - `winsmux-core/scripts/doctor.ps1`
  - `tests/psmux-bridge.Tests.ps1`
- `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `155/155 PASS`
- `git diff --check` -> no substantive diff-check failures
- Review gate history for this `v0.21.0` closure slice:
  - explorer agents `McClintock`, `Bohr`, and `Linnaeus` identified planning/release-scope drift
  - reviewer `Beauvoir` -> `FAIL`, findings fixed
  - fresh reviewer `Euclid` -> `no result yet` after repeated waits; fallback gate used
- PR / release validation:
  - PR `#406` CI green
  - merge commit `06e6df1a4871c5bbced69f63484b9a9eb53813b4`
  - release workflow `24303968440` success

## Next actions

1. Start `v0.21.1` from the rebalanced roadmap.
2. Consider a follow-up to keep `release-body.md` out of release assets automatically instead of removing it post-publish.
3. Keep the `v0.21.2` README gate in place for the terminal-based final-form release.

## Notes

- `v0.21.0` is a baseline release, not the full advanced slot/runtime roadmap.
- `TASK-167`, `TASK-254`, `TASK-306`, and `TASK-310` were intentionally moved out so the release truth matches shipped code.
- Public GitHub Releases stay English, use Codex-style headings, and keep inline issue/PR refs visible.
- `README.md` and `README.ja.md` must be updated again at `v0.21.2` release time to mark the terminal-based final form as the last pre-Tauri shape.
