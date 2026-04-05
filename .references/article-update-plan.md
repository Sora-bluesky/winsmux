# Zenn 記事更新計画

> 対象: https://zenn.dev/sora_biz/articles/winsmux-ai-agent-cross-pane-communication
> 作成: 2026-04-05

## 現在の記事の問題点

記事は v0.10.0 時点の内容。v0.18.1 まで9バージョン分の進化が反映されていない。

## 修正ポイント

### 1. アーキテクチャ図の全面更新

**現在の記事**: psmux CLI → send-keys/read で直接操作
**実態 (v0.18.1)**: Tauri アプリ (Rust + xterm.js) に移行中

```
【現在 (v0.18.0)】
┌─────────────────────────────────────────────┐
│ Windows Terminal                             │
│ ┌─────────┐ ┌─────────┐ ┌─────────┐        │
│ │Commander│ │Builder×4│ │Reviewer │        │
│ │(Claude) │ │(Codex)  │ │(Codex)  │        │
│ └────┬────┘ └────┬────┘ └────┬────┘        │
│      │           │           │              │
│      └─────psmux CLI─────────┘              │
│              │                               │
│         ConPTY (Windows)                     │
└─────────────────────────────────────────────┘

【将来 (Tauri 完成後)】
┌─────────────────────────────────────────────┐
│ winsmux-app (Tauri デスクトップアプリ)        │
│ ┌──────────────────────────────────────┐    │
│ │ フロントエンド (xterm.js + React)     │    │
│ │ ┌────┐ ┌────┐ ┌────┐ ┌────┐        │    │
│ │ │ペイン│ │ペイン│ │ペイン│ │ペイン│        │    │
│ │ └──┬─┘ └──┬─┘ └──┬─┘ └──┬─┘        │    │
│ └────┼──────┼──────┼──────┼──────────┘    │
│      └──────┴──┬───┴──────┘              │
│           Tauri IPC                        │
│      ┌─────────┴─────────┐                │
│      │ Rust PtyManager    │                │
│      │ (portable-pty)     │                │
│      └─────────┬─────────┘                │
│           ConPTY (Windows)                 │
└─────────────────────────────────────────────┘
```

### 2. 機能一覧の大幅追加

記事にない v0.11.0〜v0.18.0 の機能:
- **v0.14.0〜v0.16.0**: 26 セキュリティ Hook（Tier 1/2/3）
- **v0.17.0**: Builder work queue, completion watcher, approval detection
- **v0.17.1**: startup lock, auto-rebalance
- **v0.17.2**: vault health check, doctor diagnostics
- **v0.17.3**: Pester CI gate
- **v0.17.4**: startup rollback/journal, TROUBLESHOOTING.md
- **v0.18.0**: Tauri scaffold (Rust + xterm.js + ConPTY)
- **v0.18.1**: マルチペイン PTY、kill/restart サブコマンド

### 3. Orchestra セクションの更新

**現在の記事**: 3エージェント体制（architect/builder/reviewer）
**実態**: 4B1R1Rev 構成（Builder×4, Researcher×1, Reviewer×1）+ Commander

Commander の役割を明確化:
- コードを書かない（Hook で強制）
- タスク判断・ディスパッチ・git 操作のみ
- sh-orchestra-gate.js で Write/Edit をブロック

### 4. Tauri アプリセクションの新設

記事にまったく記載がない。以下を追加:
- なぜ Tauri を選んだか（Rust + Web 技術、Windows ネイティブ）
- ConPTY を portable-pty crate で直接管理
- psmux からの移行パス
- マルチペイン UI の設計（TASK-099）

### 5. コマンド体系の更新

新コマンド追加:
- `kill` / `restart` (v0.18.1)
- `builder-queue add/list/dispatch-next/complete` (v0.17.0)
- `pipeline` (v0.17.0)
- `monitor` (v0.17.0)
- `doctor` (v0.17.2)
- `auto-rebalance` (v0.17.1)

### 6. セキュリティセクションの拡充

**現在の記事**: Shield Harness 22フック
**実態**: 26 Hook + injection-patterns 5カテゴリ17パターン

### 7. 「今後の展開」セクションの更新

**削除すべき**（実装済み）:
- Read Guard 並列対応 → 済
- Agent Teams 互換 → 済
- Event Stream → 部分的に済

**追加すべき**:
- Tauri アプリの完成（v0.19.0〜v0.21.0）
- psmux 完全隠蔽
- Commander チャット UI（日本語入力最適化、画像ペースト対応）
- JSON-RPC + SDK
- リモートペイン + Relay Auth

### 8. UX 改善の新セクション

ユーザーの要望:
- Commander とのチャット欄で日本語入力をしやすくする
- スクリーンショットを直接貼れる
- CLI の制約（Ctrl+G で Notepad 起動が必要、画像貼り付け不可）を解消
- Tauri の WebView でネイティブテキスト入力 + ドラッグ&ドロップ画像対応

### 9. Agent Teams との比較の更新

**現在の記事**: isTTY gate の問題
**実態**: Agent Teams は正式リリース済み。比較ポイントを更新:
- Agent Teams: Claude Code 限定、公式サポート
- winsmux: マルチベンダー（Codex, Gemini, Claude）、Windows ネイティブ、Tauri UI

### 10. タイトル・リード文の検討

現タイトル「司令塔はコードを触らない：WSL不要でAIエージェントを並列稼働させる winsmux を作った」
→ Tauri アプリ化を反映した更新を検討
