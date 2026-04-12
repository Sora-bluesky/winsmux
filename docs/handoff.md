# Handoff

> Updated: 2026-04-12T18:05:00+09:00
> Source of truth: this file

## Current state

- `v0.20.0`, `v0.20.1`, `v0.20.2`, and `v0.20.3` are released.
- `v0.21.0: Operator Core & Slot Dispatch` is rebaselined to honest shipped scope and ready for PR/release closure.
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
  - fresh `/review` still required on the consolidated PR slice before merge

## Next actions

1. Create a branch for the `v0.21.0` closure slice and open a PR.
2. Run a fresh `/review` on that PR slice and merge if the gate passes or timeout fallback is justified.
3. Publish the `v0.21.0` GitHub Release and save release/post drafts.

## Notes

- `v0.21.0` is a baseline release, not the full advanced slot/runtime roadmap.
- `TASK-167`, `TASK-254`, `TASK-306`, and `TASK-310` were intentionally moved out so the release truth matches shipped code.
- Public GitHub Releases stay English, use Codex-style headings, and keep inline issue/PR refs visible.
- `README.md` and `README.ja.md` must be updated again at `v0.21.2` release time to mark the terminal-based final form as the last pre-Tauri shape.
