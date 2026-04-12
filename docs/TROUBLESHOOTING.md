# トラブルシューティングガイド

## 起動時の問題

### "Orchestra already starting (lock exists)"

**原因**: 前回の起動が異常終了し、ロックファイルが残っている。

**解決**:
```powershell
Remove-Item .winsmux/orchestra.lock -Force
```

### エージェントが起動しない（ペインが空）

**原因**: respawn-pane 後のシェル準備が間に合わなかった。

**解決**: 再度 `orchestra-start.ps1` を実行。Wait-PaneShellReady が自動リトライする。

### Codex が毎コマンド承認を求める

**原因**: `~/.codex/config.toml` の `[windows] sandbox = "elevated"`。

**解決**:
```toml
[windows]
sandbox = "unelevated"
```

### Codex worktree pane で file write や git 操作が不安定

**症状**:
- worktree pane 内の Codex が `.git/worktrees/*/index.lock` を作れず、`git add` や `git commit` が失敗する
- PowerShell が `ConstrainedLanguageMode` になり、`Set-Content` / `Out-File` / `[IO.File]::*` が失敗する

**原因**:
- Windows の `unelevated` sandbox では、Codex pane が worktree git metadata と PowerShell file APIs に制約を受ける

**解決**:
- winsmux の標準分担を使う
  - Codex pane: file edit / test / focused verification
  - external operator: `git add` / `git commit` / `git push`
- pane 内の file write は `apply_patch` か `cmd /c` を使う
- `Set-Content` / `Out-File` / `[IO.File]::WriteAllText()` は避ける

**補足**:
- これは issue `#260` の documented workaround
- `winsmux doctor` がこの limitation を検知したら、external operator が `git add` / `git commit` / `git push` を担当する

### vault key が見つからない

**原因**: Windows Credential Manager に登録されていない。

**解決**:
```powershell
pwsh scripts/winsmux-core.ps1 vault set KEY value
# または
pwsh scripts/winsmux-core.ps1 doctor  # 診断実行
```

## ペインの問題

### ペインが不均等

**原因**: v0.14.0 以前の Split-Equal バグ（修正済み）。

**解決**: `winsmux select-layout tiled` または Orchestra 再起動。

### ロール切替でペインが消える

**原因**: v0.17.0 以前の role switch バグ（修正済み）。

**解決**: Orchestra 再起動。`winsmux role` は respawn-pane -k を使用（修正済み）。

## リリースの問題

### bump-version でファイルがコミットされない

**原因**: gitignore されたファイルの `git add` に `-f` が必要。

**解決**: v0.17.0 以降で修正済み。手動の場合は `git add -f` を使用。

### backlog のタスクが done にならない

**原因**: タスクの status が `backlog` の場合、auto-update はスキップする（wip/review のみ昇格）。

**解決**: 事前にタスクの status を `wip` または `review` に変更してからリリース。

## 診断コマンド

```powershell
# 総合診断
pwsh scripts/winsmux-core.ps1 doctor

# vault 状態確認
pwsh scripts/winsmux-core.ps1 vault list

# ペイン一覧
pwsh scripts/winsmux-core.ps1 list

# キュー状態
pwsh scripts/winsmux-core.ps1 builder-queue list builder-1

# アイドル Builder 確認
pwsh scripts/winsmux-core.ps1 auto-rebalance
```

## ログファイル

| ファイル | 内容 |
|---------|------|
| `.winsmux/startup-journal.log` | 起動失敗の履歴 |
| `.claude/logs/evidence-ledger.jsonl` | 全 Hook 操作ログ |
| `.shield-harness/session.json` | セッション状態 |
| `.winsmux/manifest.yaml` | Orchestra 現在状態 |
