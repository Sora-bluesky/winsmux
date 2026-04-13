# Handoff

> Updated: 2026-04-14T09:05:00+09:00
> Source of truth: this file

## Current state

- `v0.20.0` から `v0.21.2` までは release 済みです。
- `v0.22.0` が現在の本線です。`TASK-105`、`TASK-289`、`TASK-291` を中心に、Tauri desktop control plane の backend-first 収束を進めています。
- `TASK-290` の detail UX は `v0.22.1` レーンに分離済みです。`v0.22.0` では backend truth の hydration と material-change follow-through だけを進めます。
- planning は `backlog.yaml` を英語の正本、`ROADMAP.md` を日本語の閲覧面として扱います。
- `winsmux-core/scripts/sync-roadmap.ps1` は `ROADMAP.md` と `docs/internal/` の 2 つの内部確認資料を同時更新する標準入口です。

## This session

- PR [#417](https://github.com/Sora-bluesky/winsmux/pull/417) を merge しました。
  - `desktop_json_rpc` / `pty_json_rpc` の transport 収束
  - desktop summary / explain / editor hydration の backend-truth 化
  - material-change 寄りの summary follow-through
- `v0.22.0` の次作業用 branch を `codex/task105-backend-truth-followup-20260414` として切り直しました。
- roadmap / internal-doc sync レーンを整理しました。
  - branch: `codex/roadmap-ja-gate-20260413`
  - PR [#418](https://github.com/Sora-bluesky/winsmux/pull/418) を作成済み
  - `sync-roadmap.ps1` は日本語 task title だけでなく日本語 version title も gate し、missing 時は `ROADMAP.md` を書く前に fail-closed します
  - `sync-internal-docs.ps1` は `done` を `公開済み` として扱うように修正しました
  - `AGENTS.md` には roadmap localization gate と Rust learning-note gate の両方を残しました
- `docs/handoff.md` は conflict 解消時に、現在の repo 状態に合わせて簡潔化しました。

## Validation

- `gh pr checks 417` -> `Pester Tests` PASS
- `gh pr merge 417 --merge` -> PASS
- `pwsh -NoProfile -File .\winsmux-core\scripts\sync-roadmap.ps1` -> PASS after the fail-closed localization fix
- `git diff --check` -> LF/CRLF warning のみ
- reviewer `Euclid` -> delayed `FAIL`
  - roadmap localization gate が write 後判定だった点
  - internal docs の `done` 分類
  - handoff の internal-doc scope wording
- reviewer `Lorentz` -> PASS after the fix-up slice

## Next actions

1. PR [#418](https://github.com/Sora-bluesky/winsmux/pull/418) の conflict を解消して merge する。
2. merge 後に `codex/roadmap-ja-gate-20260413` を remote/local ともに削除する。
3. `codex/task105-backend-truth-followup-20260414` で `v0.22.0` を継続する。
4. 次の最短は、`appendFallbackExplain()` と editor empty-state の seeded copy をさらに backend digest の事実だけに寄せるか、`TASK-105` の未完 backend seam を閉じることです。

## Notes

- `docs/internal/` は引き続き gitignore 対象です。internal docs は自動更新されますが公開面には出しません。
- `TASK-315` は内部運用レーンです。公開の自律実行は `v1.1.0` 以後の別ラインです。
- enterprise isolation は `local-windows` を置き換えるのではなく、post-`v1.0.0` の opt-in profile として扱います。
