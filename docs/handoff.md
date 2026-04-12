# Handoff

> Updated: 2026-04-12T20:32:00+09:00
> Source of truth: this file

## Current state

- `v0.19.5`, `v0.19.6`, `v0.19.7`, and `v0.19.8` are released.
- `v0.19.6 hardening` is implemented, merged, released, and tracked as `100% (6/6)` in the external planning backlog/roadmap.
- `v0.19.7 visible orchestration` is implemented, merged, released, and tracked as `100% (7/7)` in the external planning backlog/roadmap.
- `v0.19.8 External Operator & Agent Slots` is implemented in order; private planning now tracks `TASK-259`, `TASK-261`, `TASK-262`, `TASK-263`, and `TASK-264` as done, and the external roadmap is synced accordingly.
- Private planning now swaps `v0.20.0` and `v0.21.0` to match actual implementation order: `v0.20.0` is `Desktop UX Foundation`, and `v0.21.0` is `Operator Core & Slot Dispatch`.
- PR [#370](https://github.com/Sora-bluesky/winsmux/pull/370), PR [#371](https://github.com/Sora-bluesky/winsmux/pull/371), PR [#372](https://github.com/Sora-bluesky/winsmux/pull/372), PR [#374](https://github.com/Sora-bluesky/winsmux/pull/374), PR [#375](https://github.com/Sora-bluesky/winsmux/pull/375), PR [#376](https://github.com/Sora-bluesky/winsmux/pull/376), PR [#379](https://github.com/Sora-bluesky/winsmux/pull/379), PR [#380](https://github.com/Sora-bluesky/winsmux/pull/380), PR [#381](https://github.com/Sora-bluesky/winsmux/pull/381), PR [#382](https://github.com/Sora-bluesky/winsmux/pull/382), PR [#383](https://github.com/Sora-bluesky/winsmux/pull/383), PR [#384](https://github.com/Sora-bluesky/winsmux/pull/384), PR [#385](https://github.com/Sora-bluesky/winsmux/pull/385), PR [#386](https://github.com/Sora-bluesky/winsmux/pull/386), PR [#387](https://github.com/Sora-bluesky/winsmux/pull/387), PR [#388](https://github.com/Sora-bluesky/winsmux/pull/388), PR [#389](https://github.com/Sora-bluesky/winsmux/pull/389), PR [#390](https://github.com/Sora-bluesky/winsmux/pull/390), and PR [#392](https://github.com/Sora-bluesky/winsmux/pull/392) are merged into `main`.
- `v0.20.0` is released.
- `v0.20.1` is now fully implemented at `100% (7/7)` in the external planning backlog/roadmap after rebaselining the shipped transport/ledger slices and moving the remaining SQLite FTS5 + stdin parity work into follow-up tasks.
- `v0.20.1` is released at [v0.20.1](https://github.com/Sora-bluesky/winsmux/releases/tag/v0.20.1); release workflow run `24299025847` published `winsmux-x64.exe`, `winsmux-arm64.exe`, and `SHA256SUMS`.
- `v0.20.2` is fully implemented at `100% (5/5)` in the external planning backlog/roadmap and is released.
- Planning source of truth is externalized outside the public repository and syncs automatically into the private planning root.
- `v0.21.x` private planning is aligned to a conversation-first Tauri operator shell, with Codex-App-like shell rules reflected in Figma and backlog notes.
- `v0.24.x` private planning is split into schema, ledger, machine contract, cutover, and canary phases for Rust runtime convergence before `v1.0.0`.
- PR [#396](https://github.com/Sora-bluesky/winsmux/pull/396) is merged into `main`, landing the first `TASK-114` experiment-ledger read model slice.
- External planning is rebalanced so `v0.21.0` is reduced to slot-dispatch core, `v0.21.1` absorbs experiment compare/promotion, and `v0.22.0` is narrowed to backend-first Tauri control-plane foundation.

## This session

- Expanded the public operator contract in [docs/operator-model.md](../docs/operator-model.md) to add `Observation Pack`, `Consultation loop`, `Consult-capable slots`, `Experiment isolation and compare`, and `Tactic promotion` as first-class winsmux concepts.
- Updated the external planning backlog so `TASK-114`, `TASK-187`, `TASK-191`, `TASK-286`, and `TASK-299` explicitly cover experiment-ledger and consultation semantics, and added `TASK-300` through `TASK-305` for observation packs, consultation packets, consult-capable slots, experiment compare, tactic promotion, and the Tauri experiment board.
- Updated the Figma `winsmux Tauri Operator Workspace` file with a new `E. Experiment Loop & Consultation` section that maps `Experiments`, consultation cards, compare views, and playbook promotion into the sidebar, conversation shell, context side sheet, and command bar.
- Started the repo-side `TASK-187` first slice locally by introducing `prompt_transport` settings precedence (`global -> role -> slot`) with built-in `argv` default and fail-closed rejection for unsupported values such as `stdin`.
- Extracted send-path transport planning in [scripts/winsmux-core.ps1](../scripts/winsmux-core.ps1) so normal sends and `codex exec` sends now share a single transport-plan entry point while preserving file-backed prompt handoff as the first stable transport abstraction.
- Extended [tests/psmux-bridge.Tests.ps1](../tests/psmux-bridge.Tests.ps1) to cover prompt-transport settings precedence, restart-plan propagation, and file-forced dispatch payload behavior, and updated [winsmux-core/scripts/pane-control.ps1](../winsmux-core/scripts/pane-control.ps1) to surface the resolved `PromptTransport` in restart plans.
- Merged the `TASK-187` first slice via PR [#395](https://github.com/Sora-bluesky/winsmux/pull/395), landing `argv/file` prompt transport resolution, shared send transport planning, and restart-plan transport visibility on `main`.
- Started the repo-side `TASK-114` first slice locally by extending `runs / digest / explain` to surface a new `experiment_packet` assembled from event-ledger data without changing the existing `run_packet` contract.
- Added strict experiment-event correlation so experiment packets prefer `run_id / task_id / pane_id / label` over branch-only matching, and added a branch-collision regression to keep parallel hypothesis runs from cross-contaminating each other.
- Extended [tests/psmux-bridge.Tests.ps1](../tests/psmux-bridge.Tests.ps1) so `winsmux runs --json`, `winsmux digest --json`, `winsmux explain --json`, and explain follow-delta all cover experiment-ledger fields plus a negative case where `experiment_packet` remains null when no experiment metadata exists.
- Started the repo-side `TASK-301` write-side slice locally by adding consultation writer helpers and thin CLI commands that file `consult_request / consult_result / consult_error` packets under `.winsmux/consultations`, append corresponding bridge events, and project `result / confidence / next_action` back into the existing experiment ledger.
- Merged the `TASK-301` write-side consultation slice via PR [#398](https://github.com/Sora-bluesky/winsmux/pull/398), landing file-backed consultation packet writers and bridge-event projection fields on `main`.
- Started the repo-side `TASK-191` first slice locally by teaching one-shot orchestration to insert advisory consult steps before work, on blocked states, and before done using the existing reviewer/researcher lanes without introducing `consult-capable` routing policy yet.
- Extended [winsmux-core/scripts/team-pipeline.ps1](../winsmux-core/scripts/team-pipeline.ps1) with consult-target selection, advisory consult prompt builders, and `pipeline.consult.*` event emission so one-shot runs can dispatch `early / stuck / final` consult stages around the existing `plan -> build -> verify` loop.
- Extended [tests/psmux-bridge.Tests.ps1](../tests/psmux-bridge.Tests.ps1) to cover consult target selection plus successful and blocked orchestration paths, asserting that consult stages are inserted only when a non-builder consult target exists.
- Merged the `TASK-191` first slice via PR [#399](https://github.com/Sora-bluesky/winsmux/pull/399), inserting advisory consult stages into one-shot team orchestration without introducing `consult-capable` routing policy yet.
- Started the repo-side `TASK-188` first slice locally by extending the transport layer with stable `.winsmux/task-{slug}.md` prompt files so task-scoped handoff can be audited and reused before the full `task-run` command exists.
- Extended [scripts/winsmux-core.ps1](../scripts/winsmux-core.ps1) with task-prompt helpers (`ConvertTo-TaskPromptSlug`, `Get-TaskPromptPath`, `New-TaskPromptFile`) and task-aware transport planning so file-backed sends can target a deterministic `task-{slug}.md` artifact instead of a random dispatch file.
- Extended [tests/psmux-bridge.Tests.ps1](../tests/psmux-bridge.Tests.ps1) so send payloads cover normalized task slugs, stable relative references, and overwrite semantics when the same task slug is reused.
- Rebased the external planning backlog so `TASK-114`, `TASK-187`, `TASK-188`, `TASK-300`, and `TASK-301` reflect the shipped `v0.20.1` slices and are marked done, while the unshipped `stdin` transport parity and SQLite FTS5 search backend moved to new follow-up tasks `TASK-306` and `TASK-307` under `v0.20.3`.
- Re-synced the external roadmap so `v0.20.1: Run Transport & Event Ledger` now reads as `100% (7/7)` and is ready for release preparation.
- Drafted and saved the `v0.20.1` release notes and X thread under `C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\ChangeLogs\winsmux\v0.20.1\`.
- Tagged and published `v0.20.1`, then replaced the workflow-generated body with the curated Codex-style release notes and removed the extra `release-body.md` asset so the public release ships only `winsmux-x64.exe`, `winsmux-arm64.exe`, and `SHA256SUMS`.
- Started the first `v0.20.2` slice for `TASK-207` by strengthening `winsmux-core/agents/reviewer.sh` so reviewer prompts must explicitly audit downstream design impact, replacement coverage, and orphaned artifacts instead of limiting review to local diff correctness.
- Updated `winsmux-core/agents/AGENTS.md` to keep the reviewer-template docs aligned with the stronger audit contract, and added a narrow regression in `tests/psmux-bridge.Tests.ps1` that locks the new review-checklist language in place.
- Updated `.github/workflows/release-core.yml` from `softprops/action-gh-release@v2` to `@v3` to remove the Node 20 deprecation path that still appeared during the `v0.20.1` release workflow.
- Started the `TASK-210` runtime slice on `codex/task210-review-scope-contract-20260412`, adding `request.review_contract` to `review-request`, surfacing that contract through `explain/result_packet`, and rejecting `review-approve` / `review-fail` when a pending request lacks the mandatory scope contract.
- Updated external planning notes so `TASK-210`, `TASK-272`, `TASK-302`, `TASK-303`, `TASK-304`, and `TASK-305` explicitly encode Codex-derived UI acceptance rules (`utility-first`, `real-data-first`, `minimal chrome`, `calm hierarchy`, `one accent`), and added `TASK-308` for Playwright-based desktop viewport / overlap / drawer verification.
- Updated [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) with a short `Adaptation guardrails` bridge so Codex-derived UI reuse points back to release-train acceptance criteria without turning the notice file into additional license terms.
- Started the `v0.20.2` closing slice on `codex/v0202-verify-security-summary-20260412`, wiring structured verification packets, run-scoped security verdicts/policies, and digest event summaries into the runtime surfaces that back `runs`, `digest`, `explain`, and one-shot orchestration.
- Extended [winsmux-core/scripts/team-pipeline.ps1](../winsmux-core/scripts/team-pipeline.ps1) so verify stages emit `VERIFY_PASS / VERIFY_FAIL / VERIFY_PARTIAL`, produce utility-first verification packets, and surface security-block decisions as explicit blocked verdicts instead of prompt-only text.
- Extended [scripts/winsmux-core.ps1](../scripts/winsmux-core.ps1) so `runs`, `result_packet`, `run_packet`, `digest --events`, and `explain` hydrate `verification_contract`, `verification_result`, `security_policy`, and `security_verdict` from ledger events and manifest context.
- Extended [winsmux-core/scripts/pane-control.ps1](../winsmux-core/scripts/pane-control.ps1) and [winsmux-core/scripts/pane-status.ps1](../winsmux-core/scripts/pane-status.ps1) so manifest `security_policy` survives into pane/run surfaces even when stored as a JSON-escaped scalar in `.winsmux/manifest.yaml`.
- Extended [tests/psmux-bridge.Tests.ps1](../tests/psmux-bridge.Tests.ps1) to cover structured verify parsing, blocked security verdicts, manifest security policy hydration, digest event summaries, and explain/runs packet projection; local focused regression now passes at `141/141`.
- Fresh reviewer `Dirac` timed out with `no result yet` after a 30-second wait and was closed; fallback gate for this slice is `manual diff review + Invoke-Pester tests/psmux-bridge.Tests.ps1 + git diff --check`.
- Merged the `v0.20.2` closing slice via PR [#403](https://github.com/Sora-bluesky/winsmux/pull/403), landing utility-first verification packets, run-scoped security verdict surfaces, and `winsmux digest --events` on `main`.
- Rebaselined the external planning backlog/roadmap so `TASK-207`, `TASK-210`, `TASK-272`, `TASK-273`, and `TASK-274` are all `done`, `v0.20.2` shows `100% (5/5)`, and the unshipped full security-policy enforcement work moved to new follow-up `TASK-309`.
- Closed GitHub issues [#315](https://github.com/Sora-bluesky/winsmux/issues/315) and [#318](https://github.com/Sora-bluesky/winsmux/issues/318) after their merged fixes were reflected in planning truth.
- Drafted and saved the `v0.20.2` release notes and X thread under `C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\ChangeLogs\winsmux\v0.20.2\`.
- Tagged and published `v0.20.2`, then replaced the workflow-generated body with the curated Codex-style release notes and removed the extra `release-body.md` asset so the public release ships only `winsmux-x64.exe`, `winsmux-arm64.exe`, and `SHA256SUMS`.
- Merged `TASK-287` via PR [#393](https://github.com/Sora-bluesky/winsmux/pull/393), adding the keyboard-first operator command bar (`Ctrl/Cmd+K`) with quick actions, IME-safe input handling, focus restore, and accessible active-option semantics.
- Merged `TASK-298` via PR [#394](https://github.com/Sora-bluesky/winsmux/pull/394), rewriting `README.ja.md` to match the public operator model, shrinking maintainer-only planning readmes into internal stubs, and making tracked public config/docs safer for external users.
- Re-synced the external planning backlog/roadmap after PR [#394](https://github.com/Sora-bluesky/winsmux/pull/394), marking `TASK-298` as done so `v0.20.0` now shows `100% (12/12)`.
- Drafted the `v0.20.0` release notes and X thread in the external changelog root using the Codex-style release template.
- Published `v0.20.0` from tag `465782b` via GitHub Actions run `24276032671`, then aligned `scripts/generate-release-notes.ps1` and the live release body to the Codex-style section headings.
- Merged the repo-side `TASK-244` session board surface via PR [#371](https://github.com/Sora-bluesky/winsmux/pull/371).
- Released `v0.19.6` from tag `eac8615` and updated the public GitHub Release body to `/release-notes` format.
- Merged `TASK-245` via PR [#372](https://github.com/Sora-bluesky/winsmux/pull/372), adding `winsmux inbox` as the first actionable approval/review/blocker surface.
- Merged the repo-side `TASK-256` primitives via PR [#374](https://github.com/Sora-bluesky/winsmux/pull/374): `winsmux runs [--json]` and `winsmux explain <run_id> [--json] [--follow]`.
- Merged `TASK-257` via PR [#375](https://github.com/Sora-bluesky/winsmux/pull/375), tightening notification profiles so Telegram defaults to external-facing events only.
- Merged `TASK-246` via PR [#376](https://github.com/Sora-bluesky/winsmux/pull/376), adding `winsmux digest [--json]` and evidence digest fields for `explain`.
- Merged `TASK-253` via PR [#380](https://github.com/Sora-bluesky/winsmux/pull/380), extending manifest/status/board aggregation into first-class `run_packet` and `result_packet` surfaces for `winsmux runs --json` and `winsmux explain --json`.
- Released `v0.19.7` from tag `833249a` and updated the public GitHub Release body to the standardized English `/release-notes` format.
- Merged `TASK-285` via PR [#379](https://github.com/Sora-bluesky/winsmux/pull/379), landing the first Tauri operator workspace shell scaffold on `main`.
- Updated the private planning backlog/roadmap so `v0.19.8`, `v0.20.x`, `v0.21.x`, `v0.22.x`, and `v0.24.x` follow the `Operator / slot / provider / verification / security monitor / Tauri shell` model.
- Updated `TASK-257` planning notes to be channel-agnostic (`external channel` instead of `Telegram` as the design anchor) and documented the Claude Code channels abstraction in `.references`.
- Started the repo-side `TASK-261` slice on `codex/task261-agent-slots-20260410`, adding `agent_slots[]` parsing, worker-count synthesis, setup-wizard emission, and the default project slot array.
- Merged the repo-side `TASK-261` slice via PR [#381](https://github.com/Sora-bluesky/winsmux/pull/381), making `agent_slots[]` the project settings source of truth, rejecting malformed slot definitions fail-closed, and binding setup-wizard / orchestra-start to the canonical project root.
- Started the repo-side `TASK-262` slice on `codex/task262-slot-provider-model-20260410`, wiring slot-level `agent/model` selection into orchestra startup, restart plans, monitor cycles, and pane scaling paths.
- Merged the repo-side `TASK-262` slice via PR [#382](https://github.com/Sora-bluesky/winsmux/pull/382), wiring slot-level `agent/model` selection through startup, restart, monitor, and scale paths.
- Merged the repo-side `TASK-263` slice via PR [#383](https://github.com/Sora-bluesky/winsmux/pull/383), changing legacy role layout handling from implicit count-based activation to explicit `legacy_role_layout=true` opt-in only.
- Merged the repo-side `TASK-264` starter slice via PR [#384](https://github.com/Sora-bluesky/winsmux/pull/384), moving review-state and pipeline wording from dedicated `reviewer` targets toward generic `review target` semantics while keeping legacy `target_reviewer_*` keys readable.
- Released `v0.19.8` from tag `6ec6522a6a9b91810a84ab97e4483cb8658e2f19`; the public GitHub Release is published at [v0.19.8](https://github.com/Sora-bluesky/winsmux/releases/tag/v0.19.8) and the binary workflow run `24234569692` completed successfully.
- Saved `v0.19.8` post drafts to `C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\ChangeLogs\winsmux\v0.19.8\release-notes.md` and `C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\ChangeLogs\winsmux\v0.19.8\x-thread-draft.md`.
- Reworked the Tauri prototype toward `TASK-285`: `winsmux-app` now renders an operator workspace shell scaffold with conversation timeline, sticky composer with inline attachments, context toggle, and a terminal utility drawer instead of a PTY-first full-window layout.
- Added Figma high-fi anchors for `Operator Home / Inbox`, `Run Explain / Evidence`, and `Editor Secondary Surface`, and clarified how Explorer/Editor/Pane map into the new shell.
- Tightened the `TASK-285` shell slice locally: `winsmux-app` now uses a workspace sidebar instead of generic nav, adds a Codex-style footer/status lane, keeps wrapping summary-first, and separates sidebar / conversation / editor surface / context side sheet / terminal drawer more explicitly.
- Updated private planning notes so `TASK-101`, `TASK-285`, `TASK-287`, `TASK-292`, `TASK-294`, `TASK-297`, `TASK-107`, `TASK-138`, `TASK-286`, and `TASK-288` reflect the Codex-TUI-plus-cmux synthesis, then re-synced the external roadmap.
- Updated the Figma `winsmux Tauri Operator Workspace` file so the high-fi home screen shows the workspace sidebar, sticky composer, and footer/status lane together.
- Added [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and a matching `AGENTS.md` rule so direct Codex OSS UI reuse keeps Apache-2.0 attribution plus upstream source-path tracking in-repo, and documented the MIT-licensed legacy `psmux` compatibility surface from the core upstream for provenance.
- Merged the `TASK-285` workspace-sidebar shell slice via PR [#385](https://github.com/Sora-bluesky/winsmux/pull/385), replacing the generic left-nav with a workspace sidebar and landing in-repo third-party UI provenance tracking.
- Started the next `v0.21.0` UI slice on `codex/task297-sidebar-composer-responsive-20260410`, adding workspace-sidebar responsive behavior, composer mode chips, log semantics, and a settings/menu surface to advance `TASK-297`, `TASK-292`, `TASK-293`, and `TASK-294`.
- Merged the `TASK-297/292/293/294` starter slice via PR [#386](https://github.com/Sora-bluesky/winsmux/pull/386), adding a responsive workspace sidebar overlay, composer mode chips, settings/menu sheet, and conversation log semantics.
- Started the next `TASK-107` editor slice on `codex/task107-editor-secondary-surface-20260410`, wiring changed files and source context into the secondary editor surface.
- Merged the `TASK-107` editor slice via PR [#387](https://github.com/Sora-bluesky/winsmux/pull/387), connecting the secondary editor surface to explorer selections and source-context changed files.
- Started the workflow maintenance slice on `codex/node24-workflow-actions-20260410`, upgrading GitHub Actions core actions to Node-24-capable majors to remove runner deprecation warnings.
- Added a durable subagent review-gate rule to [AGENTS.md](../AGENTS.md): close completed review agents promptly, prefer fresh agents per PR slice, wait longer before declaring timeout, and record fallback review grounds explicitly when timeouts persist.
- Merged the workflow maintenance slice via PR [#388](https://github.com/Sora-bluesky/winsmux/pull/388), upgrading core GitHub Actions dependencies to Node-24-capable majors and landing the durable subagent review-gate workflow rule in [AGENTS.md](../AGENTS.md).
- Swapped `v0.20.0` and `v0.21.0` in the private planning backlog/roadmap so release numbering matches actual implementation order, then re-synced [ROADMAP.md](C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\Projects\winsmux\planning\ROADMAP.md).
- Started the next `v0.20.0` desktop UX slice on top of `TASK-138`, unifying source-control/worktree mock data into a single `sourceControlState` view model and wiring sidebar source summary, source-entry filters, context overview cards, and changed-file rows to the same state.
- Merged the `TASK-138` source-control context slice via PR [#389](https://github.com/Sora-bluesky/winsmux/pull/389), making the desktop UX source-control surface worktree-aware and editor-linked from a single `sourceControlState`.
- Started the `TASK-101` theme-contract slice on `codex/task101-theme-contract-20260411`, adding semantic theme tokens, Codex-derived typography tokens, and `Theme / Density / Wrap` state to the settings sheet.
- Merged the `TASK-101` theme-contract slice via PR [#390](https://github.com/Sora-bluesky/winsmux/pull/390), adding semantic theme tokens, theme/density/wrap controls, and Codex OSS attribution for reused styling patterns.
- Started the active `v0.20.0` desktop UX slice on `codex/v0200-operator-timeline-public-docs-20260411`, combining `TASK-292`, `TASK-286`, and public operator-doc cleanup: composer attachments now support paste/drag-drop/file-picker, the conversation shell is moving to a concise filtered activity feed, and public operator docs are being split from contributor dogfooding docs.
- Expanded the active slice to include `TASK-299`, adding strict public operator/pane role-definition docs (`.claude/CLAUDE.md`, `AGENT-BASE.md`, `AGENT.md`, `GEMINI.md`, `docs/operator-model.md`) and aligning the timeline grammar with pane result reports.
- Merged the public operator/pane docs and concise timeline slice via PR [#392](https://github.com/Sora-bluesky/winsmux/pull/392), adding `AGENT-BASE.md`, `AGENT.md`, the strict-default `.claude/CLAUDE.md`, the reworked `docs/operator-model.md`, and pane report cards with `STATUS/TASK/RESULT/FILES_CHANGED/ISSUES`.
- Re-synced the external planning backlog/roadmap after PR [#392](https://github.com/Sora-bluesky/winsmux/pull/392), marking `TASK-101`, `TASK-286`, `TASK-292`, and `TASK-299` as done so `v0.20.0` now shows `83% (10/12)`.
- Started `TASK-287` on `codex/task287-command-bar-20260411`, adding a keyboard-first command bar (`Ctrl/Cmd+K`) with quick actions for dispatch/review/explain, source context, settings, and terminal control.
- Started `TASK-298` cleanup on `codex/task298-public-surface-cleanup-20260411`, removing maintainer-heavy content from public docs/config, rewriting `README.ja.md`, and shrinking tracked planning readmes into internal stubs.

## Validation

- Docs-only change; no tests run.
- Release workflow passed for `v0.19.6`.
- Release workflow passed for `v0.19.7`.
- Release workflow passed for `v0.19.8`: GitHub Actions run `24234569692` published `winsmux-x64.exe`, `winsmux-arm64.exe`, and `SHA256SUMS`.
- `TASK-244` PR CI passed before merge.
- `TASK-245` PR CI passed before merge.
- `TASK-246` focused regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `101/101 PASS`.
- `TASK-253` focused regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `103/103 PASS`.
- Current Tauri shell scaffold passes frontend build: `npm run build` in `winsmux-app`.
- Composer scaffold matches the intended keyboard contract (`Enter` sends, `Shift+Enter` inserts newline, IME composition Enter does not send), and Context/Terminal toggles expose disclosure semantics via `aria-controls` plus `aria-expanded`.
- `TASK-261` settings/layout regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `110/110 PASS`.
- Current `TASK-262` slot wiring regression passes locally: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `113/113 PASS`.
- `TASK-263` explicit legacy opt-in regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `115/115 PASS`.
- `TASK-264` starter regression passed before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `116/116 PASS`.
- Current Tauri workspace-sidebar slice passes frontend build: `npm run build` in `winsmux-app`.
- Current `TASK-297/292/293/294` starter slice passes frontend build: `npm run build` in `winsmux-app`.
- Current `TASK-107` editor slice is merged via PR [#387](https://github.com/Sora-bluesky/winsmux/pull/387).
- PR [#388](https://github.com/Sora-bluesky/winsmux/pull/388) merged cleanly and the repo is back to `main == origin/main`.
- Current `TASK-138` source-control slice passes frontend build: `npm run build` in `winsmux-app`.
- Current `TASK-101` theme-contract slice passes frontend build: `npm run build` in `winsmux-app`.
- Merged `TASK-292/TASK-286/TASK-299` slice passed frontend build before landing: `npm run build` in `winsmux-app`.
- Current `TASK-287` command-bar slice passes frontend build: `npm run build` in `winsmux-app`.
- `TASK-298` docs/config cleanup landed via PR [#394](https://github.com/Sora-bluesky/winsmux/pull/394); its CI `Pester Tests` run `24271531120` passed before merge.
- `v0.20.0` release workflow run `24276032671` completed successfully and published `winsmux-x64.exe`, `winsmux-arm64.exe`, and `SHA256SUMS`.
- `TASK-187` transport slice passed focused regression before merge: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `122/122 PASS`.
- Current local `TASK-114` experiment-ledger slice passes focused regression: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `123/123 PASS`.
- PR [#396](https://github.com/Sora-bluesky/winsmux/pull/396) CI passed before merge: `Pester Tests` run `24280233475`.
- Current local `TASK-301` write-side consultation slice passes focused regression: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `130/130 PASS`.
- PR [#398](https://github.com/Sora-bluesky/winsmux/pull/398) merged cleanly and the repo returned to `main == origin/main`.
- Current local `TASK-191` consult-insertion slice passes focused regression: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `133/133 PASS`.
- Current local `TASK-191` consult-insertion slice passes `git diff --check` aside from benign LF->CRLF warnings on the edited files.
- PR [#399](https://github.com/Sora-bluesky/winsmux/pull/399) merged cleanly and the repo returned to `main == origin/main`.
- Current local `TASK-188` task-prompt-file slice passes focused regression: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `135/135 PASS`.
- Current local `TASK-188` task-prompt-file slice passes `git diff --check` aside from benign LF->CRLF warnings on the edited files.
- PR [#400](https://github.com/Sora-bluesky/winsmux/pull/400) merged cleanly and the repo returned to `main == origin/main`.
- `v0.20.1` release workflow run `24299025847` completed successfully after tag push.
- Current local `TASK-207` + release-workflow maintenance slice passes focused regression: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `136/136 PASS`.
- Current local `TASK-207` + release-workflow maintenance slice passes `git diff --check` aside from benign LF->CRLF warnings on edited files.
- Current local `TASK-210` runtime-contract slice passes focused regression: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `136/136 PASS`.
- Current local `TASK-210` runtime-contract slice passes focused regression: `Invoke-Pester tests/Integration.GateEnforcement.Tests.ps1` -> `45/45 PASS`.
- Current local `TASK-210` runtime-contract slice passes `git diff --check` aside from benign LF->CRLF warnings on edited files.
- Current local `v0.20.2` closing slice passes focused regression: `Invoke-Pester tests/psmux-bridge.Tests.ps1` -> `141/141 PASS`.
- Current local `v0.20.2` closing slice passes `git diff --check` aside from benign LF->CRLF warnings on edited files.
- PR [#403](https://github.com/Sora-bluesky/winsmux/pull/403) CI passed before merge: `Pester Tests` run `24300148509`.
- `v0.20.2` release workflow run `24300269827` completed successfully and published `winsmux-x64.exe`, `winsmux-arm64.exe`, and `SHA256SUMS`.

## Next actions

1. Start `v0.20.3` from `TASK-309` or another governance/runtime-contract slice.
2. Keep `TASK-308` as the explicit `v0.22.1` Playwright viewport / overlap / drawer quality gate for the Tauri desktop shell.
3. Preserve the Codex-style English release format for future GitHub Releases.

## Notes

- `HANDOFF.md` at the repository root is historical context and no longer authoritative.
- Public tracked files must not contain personal paths or private planning roots.
- External planning source of truth stays outside the public repository and is resolved via the configured planning root.
- Public docs may refer to the external planning contract, but must not embed machine-specific absolute paths.
- `v0.21.2` release gate includes a required `README.md` / `README.ja.md` refresh so the terminal-based final form is documented before `v0.22.0` begins the desktop control-plane handoff.
- Public GitHub Release titles and bodies are standardized in English, even when the working session is conducted in Japanese.
- Before each release, explicitly re-check the boundary between public product docs/config and maintainer dogfooding material.
