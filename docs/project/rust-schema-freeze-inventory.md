# Rust Schema Freeze Inventory

Purpose: contributor-facing inventory for `TASK-277`.
This document identifies which runtime data shapes are already close to a typed Rust contract and which shapes are still loose PowerShell schemas.

## Current conclusion

- `summary` is the most freeze-ready surface.
- `run/explain` is the next most freeze-ready surface.
- `.winsmux/review-state.json` now has the first fixture-backed typed Rust snapshot contract.
- `manifest` now has a first Rust-side schema fixture and validation contract.
- `event` and `verdict` still rely on loose PowerShell object shapes.
- The next safe implementation step is to freeze the event envelope before ledger persistence.

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
- The remaining work is to connect this contract to ledger persistence without turning it into a full manifest rewrite.

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

- The root event envelope is fairly stable, but `data` remains polymorphic.
- Downstream projections infer event meaning through conversion helpers instead of a shared typed event contract.

### 6. `verdict`

Current location:

- embedded inside run, digest, and explain payloads

Current gap:

- There is no standalone `verdict` schema.
- Rust currently receives verdict-related values as typed fields on higher-level DTOs, but the producer-side assembly still lives in PowerShell object composition.

## Recommended order after this inventory

1. Freeze the `.winsmux/events.jsonl` envelope next.
2. Keep the review-state fixture as the branch-keyed root file shape.
3. Keep the manifest contract limited to session and pane boundary validation until ledger persistence needs more fields.
4. Do not expand the contract work into a full runtime rewrite without a separate task.

## Parallel work that stays safe

- Read-only schema inventory for `manifest`
- Read-only event shape catalog for `.winsmux/events.jsonl`
- Read-only `TASK-289` UI refresh gap analysis

These can run in parallel because they do not mutate the same runtime contract surface.
