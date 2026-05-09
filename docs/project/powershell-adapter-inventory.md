# PowerShell Adapter Inventory

Purpose: contributor-facing inventory for `TASK-276`.
This document classifies PowerShell and hook entrypoints before the `v0.24.4` runtime cutover work.

## Current conclusion

- Keep install, bootstrap, git-guard, release, and compatibility entrypoints until Rust replacements have the same user and CI contracts.
- Shrink orchestration runtime scripts behind typed Rust contracts before deleting any script.
- Treat startup, attach, state, watchdog, and rollback as separate responsibilities.
- Do not remove a script only because repo-wide references are low. First prove it is outside public docs, hooks, install output, and operator startup paths.
- `TASK-282` should introduce measured dual-run comparison before `TASK-270` removes or thins runtime scripts.
- `TASK-296` tracks the legacy alias sunset: `psmux`, `pmux`, and `tmux` binary aliases are no longer shipped, and new docs and scripts must use `winsmux`.
- `TASK-407` expands the PowerShell reduction plan to the legacy Pester suites. The goal is to keep release-blocking coverage while moving core runtime behavior checks to Rust tests or typed fixtures before `v1.0.0`.

## Classification rules

| Class | Meaning | Cutover rule |
| --- | --- | --- |
| `keep` | Script remains part of bootstrap, public compatibility, CI, release, security, or current runtime operation. | Keep until a Rust or non-PowerShell path has the same documented contract and tests. |
| `thin-shim` | Script may remain as a small compatibility wrapper while behavior moves behind typed contracts. | The wrapper may parse arguments, locate the binary, and print compatibility guidance only. |
| `delete-candidate` | Script appears removable after references and documented usage are cleared. | Delete only after `TASK-282` proves there is no runtime or docs-visible behavior difference. |
| `needs-decision` | Ownership or runtime role is unclear. | Decide ownership before `TASK-270`; do not delete in this task. |

## Keep

| Path | Owner | Reason | Cutover condition |
| --- | --- | --- | --- |
| `scripts/winsmux-core.ps1` | CLI compatibility | Main PowerShell bridge and documented direct entrypoint. | Rust CLI owns the same command surface, and docs no longer require direct bridge execution. |
| `install.ps1` | Installer | Public install path and profile deployment entrypoint. | Installer has an equivalent non-PowerShell path, including profile selection and rollback. |
| `scripts/bootstrap-git-guard.ps1` | Contributor security | Sets repository hook path. | Hook bootstrap is covered by a cross-shell or Rust tool. |
| `scripts/git-guard.ps1` | Contributor security | Required by hooks and CI. | Secret and public-surface checks move to an equivalent maintained tool. |
| `scripts/audit-public-surface.ps1` | Contributor security | Enforces public-vs-private surface boundaries. | Same checks run outside PowerShell in CI and hooks. |
| `scripts/gitleaks-history.ps1` | Contributor security | Applies the recorded gitleaks baseline policy. | Baseline scan policy is preserved in another tool. |
| `scripts/bump-version.ps1` | Release | Keeps version numbers synchronized. | Release tooling has an equivalent scripted path and release gate coverage. |
| `scripts/generate-release-notes.ps1` | Release | Builds Codex-style release body for tag workflows. | Release notes generation is moved to a tested non-PowerShell path. |
| `.githooks/pre-commit` | Contributor security | Runs staged `git-guard` and version checks. | Hook behavior is replaced with the same checks. |
| `.githooks/pre-push` | Contributor security | Runs full `git-guard`, public-surface audit, and gitleaks history scan. | Hook behavior is replaced with the same checks. |
| `.githooks/pre-commit-whitelist.ps1` | Contributor security | Defines allowed pre-commit script changes. | Whitelist contract is moved to a non-PowerShell policy file. |
| `winsmux-core/scripts/settings.ps1` | Runtime compatibility | Shared settings, path, and bridge helpers used by multiple scripts. | All consumers move to typed config loading. |
| `winsmux-core/scripts/planning-paths.ps1` | Planning sync | Resolves external planning roots for roadmap and release tooling. | Planning sync is replaced by a non-PowerShell tool. |
| `winsmux-core/scripts/sync-roadmap.ps1` | Planning sync | Generates roadmap views from external backlog. | Roadmap generation moves to a maintained non-PowerShell tool. |
| `winsmux-core/scripts/sync-internal-docs.ps1` | Planning sync | Generates internal feature and checklist views. | Internal docs generation moves with roadmap sync. |
| `winsmux-core/scripts/doctor.ps1` | Diagnostics | Public troubleshooting and local health checks depend on it. | Rust doctor covers the same checks and messages. |
| `winsmux-core/scripts/vault.ps1` | Security runtime | Maintains existing vault flows. | Secret storage is replaced by typed keyring-backed core. |
| `winsmux-core/scripts/orchestra-start.ps1` | Runtime startup | Current startup path for worker panes. | Rust startup path preserves bootstrap, state, attach, watchdog, and rollback contracts. |
| `winsmux-core/scripts/orchestra-smoke.ps1` | Runtime validation | Preferred operator-independent startup smoke path. | Rust smoke command exposes the same `operator_contract`. |
| `winsmux-core/scripts/orchestra-state.ps1` | Runtime state | Owns session state persistence and readiness indicators. | State contract moves to typed Rust state. |
| `winsmux-core/scripts/orchestra-bootstrap.ps1` | Runtime startup | Bootstraps pane instructions and startup setup. | Bootstrap packet generation moves to typed implementation. |
| `winsmux-core/scripts/orchestra-pane-bootstrap.ps1` | Runtime startup | Pane-side bootstrap path. | Pane bootstrap can be generated by Rust with the same CLM-safe behavior. |
| `winsmux-core/scripts/orchestra-preflight.ps1` | Runtime startup | Performs startup preflight checks. | Rust preflight reports the same blockers. |
| `winsmux-core/scripts/orchestra-layout.ps1` | Runtime startup | Computes deterministic pane layout. | Layout contract moves to typed Rust and keeps fixtures. |
| `winsmux-core/scripts/orchestra-ui-attach.ps1` | Runtime attach | Visible UI attach logic. | Attach is separated from startup and covered by tests. |
| `winsmux-core/scripts/orchestra-attach.ps1` | Runtime attach | Operator attach command and startup-required detection. | Rust attach command preserves session state outcomes. |
| `winsmux-core/scripts/orchestra-attach-entry.ps1` | Runtime attach | Entry shim for attach. | Can shrink after attach logic moves behind typed command. |
| `winsmux-core/scripts/orchestra-attach-confirm.ps1` | Runtime attach | Confirmation helper for attach flows. | Can shrink after attach confirmation contract is typed. |
| `winsmux-core/scripts/agent-launch.ps1` | Runtime pane launch | Starts agent commands with sandbox guidance. | Rust launcher emits equivalent pane instructions. |
| `winsmux-core/scripts/agent-readiness.ps1` | Runtime readiness | Reads pane readiness state. | Readiness moves to typed state. |
| `winsmux-core/scripts/agent-monitor.ps1` | Runtime monitoring | Monitors agent state and crashes. | Rust monitor covers the same event and recovery semantics. |
| `winsmux-core/scripts/agent-watchdog.ps1` | Runtime monitoring | Watchdog process for agent health. | Watchdog launch and state are typed and tested. |
| `winsmux-core/scripts/dispatch-router.ps1` | Runtime dispatch | Current task routing path. | Rust routing can explain the same assignment result. |
| `winsmux-core/scripts/task-splitter.ps1` | Runtime dispatch | Splits tasks for workers. | Rust splitter preserves packet shape and worker boundaries. |
| `winsmux-core/scripts/team-pipeline.ps1` | Runtime dispatch | Runs team pipeline and verification links. | Pipeline state and cost metadata move to typed Rust. |
| `winsmux-core/scripts/builder-queue.ps1` | Runtime dispatch | Builder queue operations. | Queue behavior moves to typed ledger/state. |
| `winsmux-core/scripts/builder-worktree.ps1` | Runtime isolation | Creates and manages isolated worktrees. | Rust worktree manager preserves isolation guard behavior. |
| `winsmux-core/scripts/worker-isolation.ps1` | Runtime isolation | Enforces worker isolation expectations. | Isolation checks move to typed guard path. |
| `winsmux-core/scripts/verify.ps1` | Runtime verification | Verification and PR merge gate path. | Rust verification gate preserves statuses and failure behavior. |
| `winsmux-core/scripts/harness-check.ps1` | Testing | Runs harness checks used by operator flows. | Harness command moves to typed tool. |
| `winsmux-core/scripts/conflict-preflight.ps1` | Runtime safety | Detects conflict risk before work. | Rust preflight covers the same risk classes. |
| `winsmux-core/scripts/clm-safe-io.ps1` | Runtime compatibility | Encapsulates Constrained Language Mode-safe IO. | Remove only after write paths no longer depend on PowerShell CLM workarounds. |
| `winsmux-core/scripts/pane-control.ps1` | Runtime pane control | Core pane control functions. | Rust pane control reaches feature parity with fixtures. |
| `winsmux-core/scripts/pane-env.ps1` | Runtime pane control | Pane environment setup. | Environment contract moves to typed config. |
| `winsmux-core/scripts/pane-status.ps1` | Runtime pane control | Pane status reads. | Status surface moves to typed state. |
| `winsmux-core/scripts/pane-border.ps1` | Runtime pane control | Visual pane border helpers. | UI status moves to Rust or a small compatibility wrapper. |
| `winsmux-core/scripts/pane-scaler.ps1` | Runtime pane control | Pane scaling helper with unclear long-term ownership. | Decide whether scaling remains a CLI feature before shrinking. |
| `winsmux-core/scripts/logger.ps1` | Runtime support | Shared logging support. | Logging moves to typed event writer. |
| `winsmux-core/scripts/manifest.ps1` | Runtime state | Manifest read/write helpers. | Manifest is fully covered by typed Rust schema and migration tests. |
| `winsmux-core/scripts/role-gate.ps1` | Runtime security | Role gate policy helper. | Security policy is enforced by typed contract. |
| `winsmux-core/scripts/operator-poll.ps1` | Runtime operations | Polling helper for operator workflows. | Operator polling has typed state and event coverage. |
| `winsmux-core/scripts/public-first-run.ps1` | Public compatibility | First-run setup surface. | Public first-run path moves to installer or Rust CLI. |
| `winsmux-core/scripts/setup-wizard.ps1` | Public compatibility | Guided setup surface. | Setup wizard moves to public installer or Rust CLI. |
| `winsmux-core/scripts/server-watchdog.ps1` | Runtime monitoring | Server watchdog helper. | Server health checks move to typed monitor. |

## Thin-shim candidates

| Path | Why it can shrink | Required wrapper behavior |
| --- | --- | --- |
| `scripts/winsmux.ps1` | Delegates into the bridge and can become a compatibility launcher. | Locate installed `winsmux` binary or bridge and forward arguments. |
| `scripts/start-orchestra.ps1` | User-facing startup helper that can delegate to typed startup. | Keep old command name and print migration guidance when needed. |
| `scripts/sync-project-views.ps1` | Maintenance trigger for generated views. | Delegate to the canonical sync command. |
| `winsmux-core/psmux-bridge.ps1` | Compatibility bridge for tmux/psmux integration. | Keep plugin path stable while implementation moves. |
| `winsmux-core/scripts/orchestra-attach-entry.ps1` | Entry wrapper around attach behavior. | Preserve visible attach launch contract. |

## Delete candidates

No file is approved for deletion by `TASK-276`.

Deletion must wait for `TASK-282` measurement and `TASK-270` implementation. Low-reference scripts such as `scripts/run-tests.ps1` and `winsmux-core/scripts/orchestra-cleanup.ps1` are only candidates for review, not removal.

## Needs decision before `TASK-270`

| Topic | Decision needed | Why it matters |
| --- | --- | --- |
| `scripts/run-tests.ps1` | Decide whether this is a supported contributor command or an obsolete local helper. | If supported, keep or thin it. If obsolete, remove docs and references first. |
| `winsmux-core/scripts/orchestra-cleanup.ps1` | Decide whether cleanup remains a startup responsibility, an explicit operator command, or an internal helper. | Cleanup affects rollback and stale worktree safety. |
| `winsmux-core/scripts/pane-scaler.ps1` | Decide whether scaling is public pane control or an internal startup helper. | Public behavior needs compatibility; internal behavior can move sooner. |
| Release tooling | Decide whether `bump-version.ps1` and `generate-release-notes.ps1` stay PowerShell until after `v1.0.0`. | Release reliability is more important than removing PowerShell early. |
| Planning sync | Decide whether roadmap/internal-doc sync remains local-only PowerShell. | External planning roots are maintainer-local and should not leak into public docs. |

## Inputs for `TASK-282`

`TASK-282` should compare current PowerShell behavior with Rust or typed replacements before cutover.

Minimum dual-run surfaces:

- `doctor` output categories and failure codes.
- `orchestra-smoke --json` and `operator_contract` fields.
- startup state transitions: `session-ready`, `ui-attach-launched`, and `ui-attached`.
- manifest read/write shape.
- dispatch route and task split packet shape.
- verify gate verdicts and merge-blocking statuses.
- pane status and readiness snapshots.

Diff budget:

- Exact match for machine-readable fields.
- Allowed wording differences only for human-readable messages.
- No missing failure states.
- No silent fallback from a blocked state to a successful state.
- No path or credential material in generated output.

## Inputs for `TASK-270`

`TASK-270` should not try to delete scripts first. It should shrink scripts in this order:

1. Move machine-readable state and projection behavior behind typed Rust contracts.
2. Keep PowerShell as launcher, setup, and compatibility glue.
3. Remove direct runtime ownership only after `TASK-282` shows matching behavior.
4. Update docs after the replacement path exists.
5. Delete scripts last, and only when public docs, hooks, installer, and startup paths no longer reference them.

`winsmux powershell-deescalation --json` exposes this shrink contract to operators and tests.
It is the machine-readable gate for deciding whether a PowerShell script is still runtime-owned
or has become bootstrap, setup, compatibility, security, release, or planning glue.

## Inputs for `TASK-283`

`TASK-283` should use `winsmux rust-canary --json` as the machine-readable release gate for
the Rust default-on canary phase.

Canary requirements:

- `WINSMUX_BACKEND` unset must report `runtime.backend = cli`.
- `WINSMUX_BACKEND=tauri` or `WINSMUX_BACKEND=desktop` must report `runtime.backend = tauri`.
- Any other `WINSMUX_BACKEND` value must fail before release validation continues.
- The payload must list the blocking conditions that prevent the default-on release gate.
- The canary remains a gate and observation surface; it must not silently change runtime ownership without the shadow cutover gate.

## Inputs for `TASK-407`

`TASK-407` should classify Pester files before deleting or rewriting them.

The release-sized plan is tracked in `docs/project/pester-suite-reduction-plan.md`.
The machine-readable inventory is `docs/project/pester-suite-inventory.json`.
Validate it with `scripts/validate-pester-reduction-plan.ps1`.

Minimum classification buckets:

- `keep-smoke`: Windows setup, installer, compatibility alias, git-guard, public-surface, and release smoke tests that are still best exercised through PowerShell.
- `migrate-rust`: core runtime behavior currently covered by Pester but now owned by Rust modules, CLI commands, or typed fixtures.
- `archive-reference`: historical upstream compatibility cases that should be preserved as fixtures or documentation, not executed in every release gate.
- `delete-after-coverage`: duplicated or obsolete tests that can be removed only after an equivalent Rust or smoke check exists.

Coverage rule:

- Do not delete a Pester test only to reduce the language ratio.
- First identify the user or release contract it protects.
- Then move the contract to Rust tests, typed fixtures, or a thinner Pester smoke check.
- Record the expected PowerShell share after each batch so language-ratio progress is measurable.

## Acceptance checklist

- Every PowerShell or hook entrypoint is classified.
- Each `keep` script has an owner and cutover condition.
- No deletion is approved without `TASK-282`.
- Startup, attach, state, watchdog, and rollback remain separate responsibilities.
- The inventory gives `TASK-270` a safe shrink order.
- Legacy Pester cleanup is tracked through `TASK-407`, not hidden inside runtime script deletion.
