# winsmux

## Mission
smux の Windows ネイティブ版を実装する。psmux をバックエンドに使い、
WSL2 不要で PowerShell 上で AI エージェント間のクロスペイン通信を実現する。

## Architecture
```
winsmux/
├── scripts/psmux-bridge.ps1    ← 核心。psmux の高レベル CLI ラッパー
├── install.ps1                 ← ワンコマンドインストーラー
├── .psmux.conf                 ← psmux 設定（smux の .tmux.conf ベース）
├── skills/winsmux/SKILL.md     ← エージェント向けスキル定義
├── tests/test-bridge.ps1       ← 手動テストスクリプト
├── CLAUDE.md                   ← このファイル
└── README.md
```

## Design Docs
- `.references/winsmux-design.md` — 詳細設計書
- `.references/winsmux-handoff.md` — 引き継ぎ指示書
- `.references/winsmux-implementation-plan.md` — 実装計画

## Rules

### 共通
1. psmux コマンドは `psmux` を使う（`tmux` エイリアスは使わない）
2. PowerShell 7（pwsh）必須。5.1 構文は使わない
3. UTF-8: スクリプト先頭で `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`

### psmux-bridge
4. Read Guard: type/keys の前に必ず read が必要。マーク管理は `$env:TEMP\winsmux\read_marks\`
5. ラベル管理: `$env:APPDATA\winsmux\labels.json`（psmux の @name オプションはペイン単位で動かないため）
6. ターゲット検証: 操作前に `psmux display-message -t $target -p '#{pane_id}'` で存在確認
7. message ヘッダー: `[psmux-bridge from:<name> pane:<id> at:<s:w.p> -- load the winsmux skill to reply]`
8. ファイル名エスケープ: ペインID の `%` と `:` は `_` に置換

### Git
9. コミットメッセージは英語
10. フェーズごとにブランチ → PR → squash merge

## Phases

| Phase | 内容 | 状態 |
|-------|------|------|
| 0 | psmux インストール・検証 | ✅ 完了 |
| 1 | psmux-bridge.ps1 + CLAUDE.md + tests | 🔄 進行中 |
| 2 | install.ps1 + .psmux.conf | ⬜ 未着手 |
| 3 | SKILL.md + references | ⬜ 未着手 |

## Testing
psmux セッション内で `tests/test-bridge.ps1` を実行。
手動で 2 ペイン以上のセッションを作成してからテストする。

```powershell
psmux new-session -d -s test
psmux split-window -h -t test
pwsh tests/test-bridge.ps1
```

## References
- smux: https://github.com/ShawnPana/smux
- psmux: https://github.com/psmux/psmux
- smux SKILL.md: https://github.com/ShawnPana/smux/blob/main/skills/smux/SKILL.md
