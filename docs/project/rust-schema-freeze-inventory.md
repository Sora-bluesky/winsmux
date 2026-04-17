# Rust Schema Freeze Inventory

Purpose: contributor-facing inventory for `TASK-277`.
This document identifies which runtime data shapes are already close to a typed Rust contract and which shapes are still loose PowerShell schemas.

## Current conclusion

- `summary` is the most freeze-ready surface.
- `run/explain` is the next most freeze-ready surface.
- `manifest`, `state`, `event`, and `verdict` still rely on loose PowerShell object shapes.
- The smallest safe next implementation slice is a typed freeze for `.winsmux/review-state.json`.

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
- `explain.run` でも、`task_id`、主要 pane 情報、最新イベント、変更件数を Rust 側で受ける形へ狭め始めている。
- `explain.run.action_items[*]` でも、`message` と `source` を含む形で Rust 側へ通し始めている。
- `explain.run` の計画系でも、`parent_run_id`、`goal`、`task_type`、`priority`、`blocking`、scope 群、`expected_output`、`verification_plan`、`review_required`、`timeout_policy`、`handoff_refs` を Rust 側へ通し始めている。
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
- Recent parity work already tightened `run.worktree` and `evidence_digest.verification_outcome`.
- The remaining work is more about extracting the contract explicitly than inventing new fields.

## Still-loose surfaces

### 3. `manifest`

Source file:

- `.winsmux/manifest.yaml`

Main PowerShell readers:

- `scripts/winsmux-core.ps1`
  - `Get-PaneControlManifestContext`
  - `Get-PaneControlManifestEntries`
  - `Get-CurrentPaneManifestContext`
  - `Get-DispatchTaskManifestEntry`

Current gap:

- The runtime still depends on specific YAML fields, and there is still no typed Rust schema or fixture set that freezes the full manifest shape.
- A first PowerShell-side minimum shape now exists for run/explain consumers:
  - `review_state` requires `branch` and `head_sha`
  - `changed_file_count > 0` requires non-empty `changed_files`
  - `last_event` requires `last_event_at`
- A second PowerShell-side planning metadata slice now exists for run/explain consumers:
  - if any of `parent_run_id`, `goal`, `task_type`, or `priority` is present, all four fields are required
- The remaining work is to inventory and freeze the wider pane/session/task fields without widening this slice back into a full manifest rewrite.

### 4. `state`

Source file:

- `.winsmux/review-state.json`

Main PowerShell readers/writers:

- `scripts/winsmux-core.ps1`
  - `Get-ReviewStatePath`
  - `Get-ReviewStatePropertyValue`
  - `Get-ReviewState`
  - `Save-ReviewState`
  - `ConvertTo-ReviewStateValue`

Current gap:

- The root object is branch-keyed JSON with nested `request`, `status`, `evidence`, and `result` data.
- The field contract is currently implied by helpers and downstream consumers rather than frozen in one typed schema.

Why this is the best next slice:

- It is smaller than `manifest`.
- It is less polymorphic than `events.jsonl`.
- It already feeds `Get-ExplainPayload`, review approval, and review failure flows.

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

1. Freeze `.winsmux/review-state.json` as the first typed schema slice for `TASK-277`.
2. Add parity fixtures and fail-close tests for the frozen review-state shape.
3. Reassess whether `manifest` or `event` is the next smaller contract after review-state.
4. Keep `TASK-289` as the next serial desktop lane after `TASK-277` planning clarity, not in parallel with contract changes on the same surface.

## Parallel work that stays safe

- Read-only schema inventory for `manifest`
- Read-only event shape catalog for `.winsmux/events.jsonl`
- Read-only `TASK-289` UI refresh gap analysis

These can run in parallel because they do not mutate the same runtime contract surface.
