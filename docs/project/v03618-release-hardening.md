# v0.36.18 Release Hardening Contract

This document is the public repository contract for the v0.36.18 hardening lane.
The external backlog remains the planning source of truth, but this file keeps
the acceptance criteria close to the code that enforces them.

## Scope

v0.36.18 is not the formal Harness Bench measurement release. Formal measurement
is assigned to v0.36.22. This release closes repeated pre-release process
failures that can otherwise make desktop launch, helper cleanup, and progress
claims unreliable.

## TASK-596: Anti-loop Release Gate

Release work must stop instead of repeating the same failing operation when any
of these conditions are true:

- The same verification path has reached the two-strike retry limit.
- State drift, stale state, or a manifest mismatch is detected.
- The run scope is too large to verify safely in one pass.
- A required gate reports a blocking reason.

The run packet must expose these fields:

- `claim_level`: one of `observed`, `partial`, `verified`, or `blocked`.
- `loop_control.two_strike_limit`: fixed at `2`.
- `loop_control.one_hypothesis_one_change_required`: `true`.
- `loop_control.stop_required`: `true` when the run must stop for operator review.
- `scope_circuit_breaker.state`: `closed`, `armed`, or `open`.
- `scope_circuit_breaker.open_reasons`: machine-readable stop reasons.

Completion claims must use `claim_level` and the circuit-breaker state. A run
that has an open circuit breaker cannot be described as release-ready.

## TASK-597: Helper And Process Lifecycle Budget

Long-running helper processes are allowed only when they are owned, budgeted, and
cleaned up by the orchestration contract.

The lifecycle gate requires:

- Background helper launch uses hidden, owned process creation when a visible
  terminal is not the product surface.
- Write-capable Codex subagents must use a dedicated git worktree and must not
  write in the shared operator checkout.
- Cleanup targets only known winsmux session processes, warm server processes,
  or manifest-owned helper PIDs.
- Cleanup protects the current process and ancestor processes.
- Session server cleanup checks the session name before stopping a process.
- Warm process cleanup keeps the configured budget and stops only excess warm
  servers.
- Smoke output includes `process_contract` so release gates can check helper,
  warm process, and stale process budgets.
- Browser instances, browser evidence, screenshots, recordings, drivers, test
  servers, and temp files are treated as bounded evidence surfaces or runtime
  artifacts, not as unowned release outputs.

## TASK-578: Medium/Low Finding Disposition

The private audit reference is not a public artifact and must not be copied into
public docs or release notes. v0.36.18 records only public-safe dispositions:

| Category | Disposition | Evidence surface | Release impact |
|---|---|---|---|
| Release/version/CI gate hygiene | fixed and verified for the current 0.36 lane | `tests/VersionSurface.Tests.ps1`, `.github/workflows/test.yml`, release workflows, release note quality gate | Keep in v0.36.18 release gate. |
| Public/private boundary and secret leakage | fixed and verified for public surfaces | `scripts/audit-public-surface.ps1`, `tests/PublicSurfacePolicy.Tests.ps1`, `scripts/git-guard.ps1` | Blocking before PR merge and release notes publication. |
| Helper/process/browser lifecycle | fixed and verified for the current orchestration contract | `scripts/test-v03618-release-hardening.ps1`, `tests/V03618ReleaseHardening.Tests.ps1`, `orchestra-smoke` `process_contract` | Blocking when owner or cleanup evidence is missing. |
| Desktop installer and rollback baseline | handled by TASK-616 | Tauri build workflow, `winsmux-app/scripts/windows-context-menu-e2e.ps1`, `docs/project/v1-release-gate.md` | Must be verified before v0.36.18 release. |
| Maintainability and large-module cleanup | defer to v0.36.19 unless blocking release evidence | repository-wide re-audit lane | Do not absorb broad refactors into this hardening release. |
| Formal Harness Bench measurements | defer to v0.36.22 | benchmark plan and report lane | Not a v0.36.18 completion condition. |

Any remaining item without safe public evidence is either `still present` and
blocking, or explicitly deferred with a target release in the external backlog.

## TASK-616: Baseline Tauri Installer Smoke

The accepted desktop baseline is the current Tauri packaging path, not legacy
alias NSIS smoke scripts.

Required evidence:

- `npm run build` succeeds in `winsmux-app`.
- `cargo test --manifest-path winsmux-app/src-tauri/Cargo.toml` succeeds.
- `npm run tauri -- build --no-bundle` succeeds for binary build gating.
- For packaged release evidence, `npm run tauri -- build` produces desktop
  bundles and `SHA256SUMS-desktop`.
- `winsmux-app/scripts/windows-context-menu-e2e.ps1` uses
  `winsmux_${VERSION}_x64-setup.exe`, installs to a bounded test root, verifies
  English and Japanese context menu labels, verifies the desktop shortcut,
  runs the generated uninstaller, and removes registry/shortcut/test-root
  state afterwards.
- Installer migration smoke means a silent install over the bounded test root
  followed by the generated uninstaller cleanup check. It is not allowed to
  depend on a Start Menu shortcut, a stale installed executable, or a visible
  PowerShell window.
- Rollback smoke means a failed or completed installer/orchestration path leaves
  project files, manifests, pane state, registry keys, shortcuts, ports, helper
  processes, and temporary test roots either unchanged or explicitly cleaned by
  the owning script.
- The release gate records the update path, rollback/uninstall behavior,
  installer UI languages, signing posture, and checksum file.

Visible desktop launch evidence must come from a freshly verified repo build or
packaged artifact. A stale installed executable or a process with no verified
window is not accepted as desktop E2E evidence.

## TASK-579: Release Polish And CI Hygiene

v0.36.18 can reach 100% only after public-facing release polish is complete:

- Public docs and release notes must not expose private planning paths, raw
  transcripts, provider request IDs, or secrets.
- English and Japanese docs must describe setup-required states and recovery
  actions consistently.
- View/menu and worker-status UX changes must have a browser or desktop visual
  evidence entry when they are changed in this release.
- PR CI must use least-privilege read permissions for test/build workflows and
  concurrency cancellation for duplicate branch runs.
- Release notes must pass release body quality checks and public-surface audit
  before publication.
- Completion requires PR merge, GitHub Release publication, public asset check,
  post-release smoke, planning sync, progress HTML update, and branch cleanup.

## TASK-578 / TASK-616 / TASK-579 Gate Use

Medium/Low audit cleanup, installer smoke, and release polish may reuse this
contract. They must not bypass the anti-loop or process lifecycle gates when
claiming completion.

## Evidence

The contract is enforced by:

- `scripts/test-v03618-release-hardening.ps1`
- `tests/V03618ReleaseHardening.Tests.ps1`
- The `shell-support` Pester category in `.github/workflows/test.yml`
