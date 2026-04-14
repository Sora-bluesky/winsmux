# Handoff

> Updated: 2026-04-14T11:15:00+09:00
> Source of truth: this file

## Current state

- `v0.20.0` から `v0.21.2` までは release 済みです。
- `v0.22.0` の本線は `TASK-105`、`TASK-289`、`TASK-291` です。Tauri desktop control plane を backend-first で収束させています。
- `TASK-290` の detail UX は `v0.22.1` レーンに分離済みです。`v0.22.0` では backend truth の hydration と material-change follow-through だけを進めます。
- planning は `backlog.yaml` を英語の正本、`ROADMAP.md` を日本語の閲覧面として扱います。
- `winsmux-core/scripts/sync-roadmap.ps1` は `ROADMAP.md` と `docs/internal/` の 2 つの内部確認資料を同時更新する標準入口です。

## This session

- PR [#417](https://github.com/Sora-bluesky/winsmux/pull/417) を merge しました。
  - `desktop_json_rpc` / `pty_json_rpc` の transport 収束
  - desktop summary / explain / editor hydration の backend-truth 化
  - material-change 寄りの summary follow-through
- PR [#418](https://github.com/Sora-bluesky/winsmux/pull/418) を merge しました。
  - `sync-roadmap.ps1` は日本語 task title だけでなく日本語 version title も gate し、missing 時は `ROADMAP.md` を書く前に fail-closed します
  - `sync-internal-docs.ps1` は `done` を `公開済み` として扱うように修正しました
  - `AGENTS.md` / `GUARDRAILS.md` / root `docs/handoff.md` を planning sync フローに合わせて更新しました
- `v0.22.0` の次作業用 branch を `codex/task105-backend-truth-followup-20260414` として切り直しました。
- `TASK-291 / TASK-107` の editor hydration をさらに backend truth 寄りに進めました。
  - `renderEditorSurface()`、`findEditorFile()`、`getEditorFiles()` の seeded editor-loading copy を neutral な backend-preview wording に置き換えました
  - PR [#419](https://github.com/Sora-bluesky/winsmux/pull/419) を作成しました
- 同じ `#419` で fallback copy をさらに事実ベースへ絞りました。
  - `appendFallbackExplain()` は explanation placeholder ではなく digest の run / inbox / next / changed だけを使うように整理しました
  - editor idle / preview fallback は `waiting for ...` 型の seeded copy をやめ、cache / request 状態だけを示す文言に寄せました
  - `getEditorFiles()` の dead fallback object を削除しました
- 同じ `#419` で `TASK-289` の polling 依存をさらに 1 つ外しました。
  - `openExplainForSelectedRun()` は explain payload を取ったあとに `refreshDesktopSummary()` を呼ばず、会話と run summary の再描画だけで閉じるようにしました
  - selected run の explain 操作が interval/focus refresh とは独立して完結します
- 同じ `#419` で explicit action 側の summary refresh を debounce + queue で整理しました。
  - pane spawn / close、composer submit、focus、visibility restore、interval tick は `requestDesktopSummaryRefresh()` に集約しました
  - queued refresh は `requested/running` version で管理し、in-flight 中に積まれた refresh も完了後に 1 回は必ず流れます
  - `spawnPtyPane()` / `closePtyPane()` の backend call が失敗しても `finally` で refresh を積むようにしました

## Validation

- `gh pr checks 417` -> `Pester Tests` PASS
- `gh pr merge 417 --merge` -> PASS
- `gh pr merge 418 --merge` -> PASS
- `pwsh -NoProfile -File .\winsmux-core\scripts\sync-roadmap.ps1` -> PASS after the fail-closed localization fix
- `npm run build` in `winsmux-app` -> PASS after the editor empty-state copy follow-up
- `npm run test:editor-targets` in `winsmux-app` -> PASS after the editor empty-state copy follow-up
- `git diff --check` -> LF/CRLF warning のみ
- `npm run build` in `winsmux-app` -> PASS after the digest-first explain/editor fallback tightening
- `npm run test:editor-targets` in `winsmux-app` -> PASS after the same slice
- root `winsmux-core/scripts/sync-roadmap.ps1` -> PASS after the same slice
- `git diff --check` -> LF/CRLF warning のみ after the same slice
- `npm run build` in `winsmux-app` -> PASS after removing refresh-time coupling from `openExplainForSelectedRun()`
- `npm run test:editor-targets` in `winsmux-app` -> PASS after the same slice
- `git diff --check` -> LF/CRLF warning のみ after the same slice
- `npm run build` in `winsmux-app` -> PASS after the debounced explicit-action refresh slice
- `npm run test:editor-targets` in `winsmux-app` -> PASS after the same slice
- `cargo check` in `winsmux-app/src-tauri` -> PASS after the same slice
- `cargo test --lib` in `winsmux-app/src-tauri` -> PASS (`10 passed`) after the same slice
- `Invoke-Pester tests/winsmux-bridge.Tests.ps1 -CI` -> `171/171 PASS` after the same slice
- `git diff --check` -> LF/CRLF warning のみ after the same slice
- reviewer `Euclid` -> delayed `FAIL`
  - roadmap localization gate が write 後判定だった点
  - internal docs の `done` 分類
  - handoff の internal-doc scope wording
- reviewer `Lorentz` -> PASS after the fix-up slice
- reviewer `Zeno` -> PASS on the editor empty-state copy follow-up
- reviewer `Locke` -> PASS on the digest-first explain/editor fallback tightening
- reviewer `Ptolemy` -> PASS on the `openExplainForSelectedRun()` refresh-decoupling slice
- reviewer `Cicero` -> `no result yet` after two 30s waits on the first debounce implementation; manual diff review held the slice while the queue semantics were corrected
- reviewer `Epicurus` -> PASS on the queued explicit-action refresh follow-up

## Next actions

1. PR [#419](https://github.com/Sora-bluesky/winsmux/pull/419) を force-push で `main` に追いつかせ、check を通したうえで merge する。
2. `TASK-105` の残り backend seam を見直し、frontend からまだ直接残っている fallback / prefetch policy を adapter/backend 側へ寄せる。
3. `TASK-289` の follow-through をさらに event 寄りに寄せる。次の本丸は timer 除去ではなく、Rust 側に summary-change 通知入口を足せるかの見極めです。
4. `TASK-290` は `codex/task290-detail-lane-20260414` で後続に回し、`v0.22.0` に混ぜない。
5. Rust / Cargo / Tauri を使った handoff では、`C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\Learning\Rust Commands - winsmux.md` も同じ session で更新する。

## Notes

- `docs/internal/` は引き続き gitignore 対象です。internal docs は自動更新されますが公開面には出しません。
- `TASK-315` は内部運用レーンです。公開の自律実行は `v1.1.0` 以後の別ラインです。
- enterprise isolation は `local-windows` を置き換えるのではなく、post-`v1.0.0` の opt-in profile として扱います。
- `TASK-290` remains a `v0.22.1` task; only the minimum observability needed for `TASK-289 / TASK-291` stays on the `v0.22.0` branch.
- The external learning note under `MainVault\Learning` is intentionally untracked; only the durable handoff rule in `AGENTS.md` is part of the repo.
