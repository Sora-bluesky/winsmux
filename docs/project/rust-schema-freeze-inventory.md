# Rust Schema Freeze Inventory

Purpose: contributor-facing inventory for Rust schema freeze work.
This document identifies which runtime data shapes are already close to a typed Rust contract and which shapes are still loose PowerShell schemas.

## Current conclusion

- `summary` is the most freeze-ready surface.
- `run/explain` is the next most freeze-ready surface.
- `.winsmux/review-state.json` now has the first fixture-backed typed Rust snapshot contract.
- `manifest` now has a first Rust-side schema fixture and validation contract.
- `event` now has a first Rust-side envelope fixture and validation contract.
- `verdict` still relies on loose PowerShell object shapes.
- The next safe implementation step is to freeze actionable event payload groups before ledger persistence.

## Freeze-ready surfaces

### 1. `summary`

Producer entrypoints:

- `scripts/winsmux-core.ps1`
  - `Get-BoardPayload`
  - `Get-InboxPayload`
  - `Get-DigestPayload`
  - `Get-DesktopSummaryPayload`

Typed Rust surface:

- `winsmux-app/src-tauri/src/desktop_backend.rs`
  - `DesktopBoardSummary`
  - `DesktopBoardSnapshot`
  - `DesktopInboxSummary`
  - `DesktopInboxItem`
  - `DesktopInboxSnapshot`
  - `DesktopDigestSummary`
  - `DesktopBoardPane`
  - `DesktopDigestItem`
  - `DesktopDigestSnapshot`
  - `DesktopSummarySnapshot`
  - `DesktopSummaryRefreshSignal`

Parity fixtures:

- `tests/fixtures/rust-parity/board.json`
- `tests/fixtures/rust-parity/inbox.json`
- `tests/fixtures/rust-parity/digest.json`
- `tests/test_support/rust_parity.rs`

Why this is close to freeze:

- The Rust DTOs already reject missing required fields.
- The fixtures already exercise the main board/inbox/digest snapshot shape.
- `board.summary.by_state` / `by_review` / `by_task_state` と `inbox.summary.by_kind` も Rust 側で必須化済み。
- `inbox.items[*]` の補助項目も、Rust 側で `priority`、`role`、`task_id`、`task`、`head_sha`、`event`、`timestamp`、`source` を受ける形へ狭め始めている。
- Recent `TASK-278` slices have been narrowing this surface with fail-close regressions instead of widening it loosely.

### 2. `run/explain`

Producer entrypoints:

- `scripts/winsmux-core.ps1`
  - `New-RunPacketFromRun`
  - `New-RunResultPacket`
  - `Get-ExplainPayload`

Typed Rust surface:

- `winsmux-app/src-tauri/src/desktop_backend.rs`
  - `DesktopRunProjection`
  - `DesktopExplainPayload`
  - `DesktopExplainRun`
  - `DesktopExplainExplanation`
  - `DesktopExplainEvidenceDigest`
  - `DesktopExplainRecentEvent`

Parity fixtures:

- `tests/fixtures/rust-parity/explain.json`
- `tests/test_support/rust_parity.rs`

Why this is close to freeze:

- `explain.json` already anchors the nested run payload in one place.
- `explain.run` は、`task_id`、主要 pane 情報、最新イベント、変更件数、identity 配列、`tokens_remaining`、計画系、`action_items[*]`、`experiment_packet`、検証系、セキュリティ系まで Rust 側で必須化済み。
- `explanation.current_state` も Rust 側で型付きになり、欠落を拒否する回帰テストがある。
- `explain.observation_pack` は、`run_id`、`task_id`、`pane_id`、`slot`、`hypothesis`、`test_plan`、`changed_files`、`working_tree_summary`、`failing_command`、`env_fingerprint`、`command_hash`、`generated_at` を Rust 側で必須化済み。
- `explain.consultation_packet` は、`run_id`、`task_id`、`pane_id`、`slot`、`kind`、`mode`、`target_slot`、`confidence`、`recommendation`、`next_test`、`risks`、`generated_at` を Rust 側で必須化済み。
- 古い別名だった最上位 `experiment_packet`、`consultation_summary`、`run_packet`、`result_packet` は explain から削除済み。
- 最上位 `observation_pack` と `consultation_packet` の `packet_type` も削除済み。`packet_type` は artifact 本体と `recent_events` の生イベント側だけに残る。
- Rust parity fixture と PowerShell 契約テストは、今の explain shape に揃っている。

## Fixture-backed frozen surfaces

### 3. `state`

Source file:

- `.winsmux/review-state.json`

Main PowerShell readers/writers:

- `scripts/winsmux-core.ps1`
  - `Get-ReviewStatePath`
  - `Get-ReviewStatePropertyValue`
  - `Get-ReviewState`
  - `Save-ReviewState`
  - `ConvertTo-ReviewStateValue`

Typed Rust surface:

- `winsmux-app/src-tauri/src/desktop_backend.rs`
  - `DesktopReviewStateSnapshot`
  - `DesktopReviewStateRecord`
  - `DesktopReviewStateRequest`
  - `DesktopReviewStateReviewer`
  - `DesktopReviewStateEvidence`
  - `DesktopReviewContract`

Parity fixtures:

- `tests/fixtures/rust-parity/review-state.json`
- `tests/test_support/rust_parity.rs`
- `core/tests-rs/test_parity.rs`

Frozen shape:

- The root object is keyed by branch name.
- Each branch record requires `status`, `branch`, `head_sha`, `request`, `reviewer`, and `updatedAt`.
- Each `request.review_contract` requires `required_scope`, `checklist_labels`, and the other review contract fields.
- The branch key must match the record `branch`.
- The request `branch` and `head_sha` must match the saved record.
- `required_scope` must be present and non-empty in the request contract and evidence snapshot.
- `target_review_*` is the primary request identity. Legacy `target_reviewer_*` remains readable as a fallback.
- `PASS` requires `evidence.approved_at` and `evidence.approved_via`.
- `FAIL` / `FAILED` requires `evidence.failed_at` and `evidence.failed_via`.
- This is a fixture-backed DTO contract. Runtime file ingestion remains PowerShell-owned until the Rust ledger work starts.

### 4. `manifest`

Source file:

- `.winsmux/manifest.yaml`

Main PowerShell readers:

- `scripts/winsmux-core.ps1`
  - `Get-PaneControlManifestContext`
  - `Get-PaneControlManifestEntries`
  - `Get-CurrentPaneManifestContext`
  - `Get-DispatchTaskManifestEntry`

Current gap:

- The runtime still depends on PowerShell readers for live ingestion.
- A first Rust-side typed schema now exists in `core/src/manifest_contract.rs`.
- The contract accepts both dictionary and legacy list `panes` formats.
- The test parser also normalizes legacy unquoted pane IDs such as `%2`.
- The parser accepts `changed_files: null` as an empty list.
- The parser keeps current path fields such as `launch_dir`, `builder_worktree_path`, and `worktree_git_dir`.
- The fixture lives in `tests/fixtures/rust-parity/manifest.yaml`.
- The first frozen minimum shape covers the current pane/session slice used by `run` / `explain` consumers:
  - `review_state` requires `branch` and `head_sha`
  - `changed_file_count > 0` requires non-empty `changed_files`
  - `last_event` requires `last_event_at`
  - `security_policy` is preserved as a manifest field
- Planning metadata has the same bundled requirement:
  - if any of `parent_run_id`, `goal`, `task_type`, or `priority` is present, all four fields are required
- `TASK-265` has started connecting this contract to read-only ledger persistence without turning it into a full manifest rewrite.

## Still-loose surfaces

### 5. `event`

Source file:

- `.winsmux/events.jsonl`

Main PowerShell readers/writers:

- `scripts/winsmux-core.ps1`
  - `Write-BridgeEventRecord`
  - `Get-BridgeEventPath`
  - `Get-BridgeEventRecords`

Current gap:

- A first Rust-side typed event envelope now exists in `core/src/event_contract.rs`.
- The current event contract is fixture-backed and test-only.
- The fixture lives in `tests/fixtures/rust-parity/events.jsonl`.
- The current contract keeps envelope strings typed while allowing sparse legacy lines and `null` optional fields.
- Legacy `data.branch` / `data.head_sha` lines are still covered because current PowerShell readers still fall back to them.
- `data` is now limited to JSON object payloads, while the inner payload catalog still remains polymorphic.
- Downstream projections still infer event meaning through conversion helpers instead of a shared typed payload catalog.

### 6. `ledger`

Current location:

- `core/src/ledger.rs`
- `core/tests-rs/ledger_contract.rs`
- `core/tests-rs/fixture_comparison.rs`

Current boundary:

- `LedgerSnapshot` loads the frozen `manifest` and `events` fixtures together.
- It can also load live `.winsmux/manifest.yaml` and `.winsmux/events.jsonl` files.
- It validates the manifest and event envelope before exposing the snapshot.
- It indexes panes by `pane_id` for later projection work.
- It exposes ordered pane read models for later board/inbox/digest/explain projection work.
- It derives the first Rust board projection from manifest pane read models.
- It derives the first Rust inbox projection from manifest pane state and latest actionable events.
- It derives the first Rust digest projection from pane read models and inbox action items.
- It derives the first Rust explain projection from digest items, matching panes, and matching events.
- It has a fixture comparison harness skeleton that loads the PowerShell golden corpus and Rust typed projection sources.
- It rejects duplicate manifest `pane_id` values because they make projection identity ambiguous.
- It preserves manifest pane order separately from the lookup index.
- It preserves unknown event pane IDs instead of rejecting them, because historical events can outlive the current manifest view.
- It rejects events that explicitly belong to a different session.
- It is now compiled by the core binary crate, not only by integration tests.

Current limitation:

- The snapshot is still read-only.
- Projection code does not consume the live snapshot yet.
- The PowerShell and desktop surfaces do not consume the Rust board projection yet.
- The PowerShell and desktop surfaces do not consume the Rust inbox projection yet.
- The PowerShell and desktop surfaces do not consume the Rust digest projection yet.
- The PowerShell and desktop surfaces do not consume the Rust explain projection yet.
- The fixture comparison harness does not diff projection payloads yet.

### 7. `verdict`

Current location:

- embedded inside run, digest, and explain payloads

Current gap:

- There is no standalone `verdict` schema.
- Rust currently receives verdict-related values as typed fields on higher-level DTOs, but the producer-side assembly still lives in PowerShell object composition.

## Recommended order after this inventory

1. Keep `LedgerSnapshot` read-only until projection surfaces are ready.
2. Freeze actionable event payload groups on top of the new `.winsmux/events.jsonl` envelope.
3. Keep the review-state fixture as the branch-keyed root file shape.
4. Keep the manifest contract limited to session and pane boundary validation until ledger persistence needs more fields.
5. Do not expand the contract work into a full runtime rewrite without a separate task.

## Parallel work that stays safe

- Read-only schema inventory for `manifest`
- Read-only event shape catalog for `.winsmux/events.jsonl`
- Read-only `TASK-289` UI refresh gap analysis

These can run in parallel because they do not mutate the same runtime contract surface.
