# Handoff

> Updated: 2026-04-14T14:40:00+09:00
> Source of truth: this file

## Current state

- `v0.20.0` から `v0.21.2` までは release 済みです。
- `v0.22.0` の本線は `TASK-105`、`TASK-289`、`TASK-291` です。Tauri desktop control plane を backend-first で収束させています。
- `TASK-290` の detail UX は `v0.22.1` レーンに分離済みです。`v0.22.0` では backend truth の hydration と material-change follow-through だけを進めます。
- `v0.22.0` は PR [#419](https://github.com/Sora-bluesky/winsmux/pull/419) 上で継続中です。最小の残 seam は、frontend polling を完全撤去することではなく、summary change の Rust/Tauri 通知入口を詰めることです。
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
- 同じ `#419` で Rust/Tauri 側の最小 notification seam を追加しました。
  - `winsmux-app/src-tauri/src/lib.rs` で `desktop-summary-refresh` イベントを追加し、`pty_spawn` / `pty_close` 成功時にだけ発火するようにしました
  - `winsmux-app/src/desktopClient.ts` に Tauri event 購読を追加し、`winsmux-app/src/main.ts` はそのイベントを受けて summary refresh queue を流すようにしました
  - 15 秒 interval は fallback のまま残していますが、pane topology change は polling を待たずに summary 側へ伝わります
- `orchestra-start.ps1` の strict mode バグを修正しました。
  - public-safe な `.winsmux.yaml` から `agent` / `model` を削った後でも、`agent_slots` の `slot.agent` / `slot.model` 未定義アクセスで落ちないようにしました
  - 起動時の `Agent:` / `Model:` 表示は、既定値が無い場合 `per-slot / override only` と表示するようにしました
  - `tests/winsmux-bridge.Tests.ps1` に、strict mode で `agent/model` 省略 slot を許容する回帰試験を追加しました
- `orchestra-start.ps1` の bootstrap gate を fail-closed に強化しました。
  - worker の一部だけが `bootstrap_invalid` でも warning で続行していたため、pane 未展開のまま `/winsmux-start` が次の探索へ進めていました
  - いまは期待 pane のうち 1 つでも `bootstrap_invalid` が出たら throw で startup を中断し、既存の catch/rollback 経路へ流します
  - `tests/winsmux-bridge.Tests.ps1` に、この fail-closed 条件が throw になる回帰試験を追加しました
- `/winsmux-start` の restoration rule も明文化しました。
  - `external-commander: true` は commander pane を省略するだけで、worker pane 不足を ready 扱いしてよい意味ではありません
  - winsmux session は存在しても expected worker count に満たない場合は `needs-startup` として扱い、状態説明や task 提案より前に `orchestra-start.ps1` を再実行して pane 数を検証する必要があります
  - 再実行後も不足していれば `blocked` として fail-closed し、local explore にフォールバックしない運用にしました
- operational problem の Issue 起票ルールを追加しました。
  - 新しい startup / orchestration / CI / operator workflow 問題は、修正だけで終わらせず GitHub Issue を必ず残します
  - 重複確認、issue 番号、解決 PR を handoff に同一 session で反映する運用にしました
- Issue [#421](https://github.com/Sora-bluesky/winsmux/issues/421) を起票しました。
  - `/winsmux-start` が external commander mode で worker pane 未展開でも false-ready 扱いになる症状を追跡します
  - PR [#420](https://github.com/Sora-bluesky/winsmux/pull/420) の repo 側修正と、repo 外の hook JSON 症状を切り分けて管理します
- 公開 docs と dogfooding/runtime docs の境界を整理しました。
  - `README.md` と `docs/operator-model.md` は Claude Code operator を public-facing の主語として明示します
  - `AGENT-BASE.md` / `AGENT.md` / `GEMINI.md` は managed pane runtime contract であり、公開の operator 説明そのものではないと明記しました
  - `AGENT.md` には Codex pane 専用であることを先頭に追記しました
- サブエージェント遅延の恒久対策を `AGENTS.md` に追加しました。
  - 今回の観測では `Euclid`、`Ptolemy`、`Popper` など delayed result が多く、主因は silent drop ではなく latency です
  - Rust/Tauri review は first timeout を 60 秒以上に伸ばし、review concurrency を 1 に制限し、routine review では `fork_context=true` を避ける運用にしました

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
- `npm run build` in `winsmux-app` -> PASS after the `desktop-summary-refresh` event slice
- `npm run test:editor-targets` in `winsmux-app` -> PASS after the same slice
- `cargo check` in `winsmux-app/src-tauri` -> PASS after the same slice
- `cargo test --lib` in `winsmux-app/src-tauri` -> PASS (`10 passed`) after the same slice
- `Invoke-Pester tests/winsmux-bridge.Tests.ps1 -CI` -> `171/171 PASS` after the same slice
- `pwsh -NoProfile -File .\winsmux-core\scripts\sync-roadmap.ps1` -> PASS after syncing missing `tasks/roadmap-title-ja.psd1` and `docs/internal/*` into this worktree
- `git diff --check` -> LF/CRLF warning のみ after the same slice
- `Invoke-Pester tests/winsmux-bridge.Tests.ps1 -CI` -> `173/173 PASS` after the `orchestra-start.ps1` strict-mode fix
- `Invoke-Pester tests/winsmux-bridge.Tests.ps1 -CI` -> PASS after the bootstrap-invalid fail-closed gate
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
- subagent `Pascal` -> `desktop-summary-refresh` を `pty_spawn` / `pty_close` 成功時にだけ発火する最小 Rust slice を推奨
- subagent `Ramanujan` -> `v0.22.0` は小さな Rust/Tauri notification slice 1 本で閉じられる見積もり（2〜4 時間 + review 1 回）
- reviewer `Darwin` -> first wait 60s では `no result yet`、追加 30s 後に delayed `PASS`
  - 今回も silent drop ではなく latency が主因だったことを確認
  - notification slice 自体への finding はなし
- reviewer `Singer` -> `no result yet` after two 30s waits on the `orchestra-start.ps1` strict-mode fix; diff was kept under manual review because the slice is limited to one PowerShell script, one test file, and handoff text
- reviewer `Mencius` -> PASS on the bootstrap-invalid fail-closed follow-up

## Next actions

1. PR [#419](https://github.com/Sora-bluesky/winsmux/pull/419) に今回の Rust/Tauri notification slice を push し、check と review を通したうえで merge する。
2. `TASK-105` の残り backend seam を再点検し、frontend に残る fallback / prefetch policy のうち `v0.22.0` に不要な seeded copy を削る。
3. `TASK-289` は event-driven 側をもう 1 段詰め、interval を完全撤去するかどうかを別 slice として判断する。
4. `TASK-290` は `codex/task290-detail-lane-20260414` で後続に回し、`v0.22.0` に混ぜない。
5. Rust / Cargo / Tauri を使った handoff では、`C:\Users\komei\iCloudDrive\iCloud~md~obsidian\MainVault\Learning\Rust Commands - winsmux.md` も同じ session で更新する。
6. `/winsmux-start` で `orchestra-start.ps1` を使う経路は、この strict-mode fix と bootstrap-invalid fail-closed gate、ならびに worker-pane readiness gate を前提に再確認する。
7. 今回の `/winsmux-start` worker 未展開問題は issue 化し、今後の再発時は issue 更新を正本にする。

## Notes

- `docs/internal/` は引き続き gitignore 対象です。internal docs は自動更新されますが公開面には出しません。
- `TASK-315` は内部運用レーンです。公開の自律実行は `v1.1.0` 以後の別ラインです。
- enterprise isolation は `local-windows` を置き換えるのではなく、post-`v1.0.0` の opt-in profile として扱います。
- `TASK-290` remains a `v0.22.1` task; only the minimum observability needed for `TASK-289 / TASK-291` stays on the `v0.22.0` branch.
- The external learning note under `MainVault\Learning` is intentionally untracked; only the durable handoff rule in `AGENTS.md` is part of the repo.
- review agent の `no result yet` は、今の観測では silent failure より latency が主因です。今後は Rust/Tauri slice で 60 秒以上待ち、同一 slice の review concurrency を 1 に制限します。
- `desktop-summary-refresh` は `pty_spawn` / `pty_close` の成功時だけ発火する最小 seam として入れています。汎用 notification 基盤にはまだ広げていません。
