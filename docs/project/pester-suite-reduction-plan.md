# Pester Suite Reduction Plan

Purpose: contributor-facing `TASK-407` plan for reducing legacy Pester coverage without losing release-blocking behavior.

This plan extends `docs/project/powershell-adapter-inventory.md`. It classifies existing Pester coverage before any test deletion or rewrite. The machine-readable inventory is `docs/project/pester-suite-inventory.json`, and `scripts/validate-pester-reduction-plan.ps1` checks that tracked Pester files are covered by the inventory.

## Release-sized target

`TASK-407` does not delete runtime coverage. It creates a release-sized migration plan with four outcomes:

| Bucket | Meaning | Release rule |
| --- | --- | --- |
| `keep-smoke` | Small PowerShell checks that protect installer, release, public-surface, security, compatibility, or contributor workflow contracts. | Keep in the release gate until a replacement has the same public or contributor contract. |
| `migrate-rust` | Runtime behavior that should move to Rust tests, typed fixtures, or CLI contract tests. | Keep the Pester file until the replacement exists and covers the same machine-readable behavior. |
| `archive-reference` | Historical upstream compatibility cases that are useful as reference fixtures but should not run in every release gate. | Preserve as fixtures or documentation before removing from the active Pester path. |
| `delete-after-coverage` | Duplicated, obsolete, diagnostic, stress, or benchmark scripts that may be removed only after equivalent smoke or fixture coverage exists. | No deletion is approved by `TASK-407`; deletion needs a follow-up patch with coverage evidence. |

## Current classification

### Keep smoke

Keep these in the active release gate because they protect current public, release, security, or contributor contracts:

- `tests/PublicSurfacePolicy.Tests.ps1`
- `tests/VersionSurface.Tests.ps1`
- `tests/NpmReleasePackage.Tests.ps1`
- `tests/GitHubWritePreflight.Tests.ps1`
- `tests/HarnessContract.Tests.ps1`
- `tests/McpServerContract.Tests.ps1`
- `tests/BuilderWorktree.Tests.ps1`
- `tests/codex-subagent-worktree-guard.Tests.ps1`

### Migrate to Rust or typed fixtures

Keep these temporarily, but move their runtime assertions into Rust tests, CLI contract tests, or typed fixtures:

- `tests/winsmux-bridge.Tests.ps1`
- `tests/Runtime.VaultInject.Tests.ps1`
- `tests/OrchestraPreflight.Tests.ps1`
- `tests/PaneBorder.Tests.ps1`
- `tests/Integration.GateEnforcement.Tests.ps1`
- `tests/Integration.MultiAgent.Tests.ps1`
- `tests/Integration.PaneMonitorHook.Tests.ps1`
- `tests/Integration.WorktreeHook.Tests.ps1`
- `core/tests/test_cli_handlers.ps1`
- `core/tests/test_config*.ps1`
- `core/tests/test_session*.ps1`
- `core/tests/test_newsession_flags.ps1`
- `core/tests/test_pane*.ps1`
- `core/tests/test_layout_engine.ps1`
- `core/tests/test_tmux_compat.ps1`
- `core/tests/test_parity.ps1`
- `core/tests/test_named_session_parity.ps1`
- `core/tests/test_new*_features.ps1`

### Archive as reference

Move these to reference fixtures or documented compatibility examples before removing them from routine release runs:

- `core/tests/test_issue*.ps1`
- `core/tests/test_issues_*.ps1`
- `core/tests/test_pr*.ps1`
- `core/tests/test_features*.ps1`
- `core/tests/test_copy_mode*.ps1`
- `core/tests/test_mouse*.ps1`
- `core/tests/test_overlay*.ps1`
- `core/tests/test_theme*.ps1`
- `core/tests/test_alt_key.ps1`
- `core/tests/test_bind*.ps1`
- `core/tests/test_cursor*.ps1`
- `core/tests/test_default_*.ps1`
- `core/tests/test_format*.ps1`
- `core/tests/test_keybinding_options.ps1`
- `core/tests/test_kill*.ps1`
- `core/tests/test_plugins_themes.ps1`
- `core/tests/test_real_plugins.ps1`
- `core/tests/test_wsl*.ps1`

### Delete after coverage

These look like local runners, diagnostics, benchmark, stress, destructive, or broad batch scripts. They are not approved for deletion in this task.

- `core/tests/_run_batch3.ps1`
- `core/tests/run_all_tests.ps1`
- `core/tests/run_fmt_test.ps1`
- `core/tests/battle_test.ps1`
- `core/tests/bench*.ps1`
- `core/tests/destructive_test.ps1`
- `core/tests/diag*.ps1`
- `core/tests/disable_processed_input.ps1`
- `core/tests/mouse_diag.ps1`
- `core/tests/test_all.ps1`
- `core/tests/test_advanced.ps1`
- `core/tests/test_bug*.ps1`
- `core/tests/test_debug_focus.ps1`
- `core/tests/test_e2e_latency.ps1`
- `core/tests/test_extreme_perf.ps1`
- `core/tests/test_github_issues*.ps1`
- `core/tests/test_install_speed.ps1`
- `core/tests/test_perf*.ps1`
- `core/tests/test_startup*_bench.ps1`
- `core/tests/test_stress*.ps1`

## Batch order

| Batch | Scope | Expected active PowerShell share |
| --- | --- | --- |
| `407-a` | Keep current `tests/` smoke files active; migrate top-level runtime tests to Rust or typed fixtures. | About 60% of current active `tests/` Pester files remain active after equivalent Rust coverage lands. |
| `407-b` | Convert legacy `core/tests/test_issue*`, `test_features*`, and `test_pr*` cases into reference fixtures. | Legacy issue-driven Pester coverage is no longer part of routine release validation. |
| `407-c` | Remove or replace diagnostics, benchmark, stress, and batch runner scripts after smoke coverage exists. | Routine release validation keeps only PowerShell smoke tests that still protect PowerShell-owned contracts. |

## Guardrails

- Do not delete a Pester file only to reduce the PowerShell language share.
- Record the protected contract before migrating or archiving a file.
- Keep public docs free of private paths and maintainer-only rituals.
- Keep `TASK-407` separate from runtime script deletion work.
