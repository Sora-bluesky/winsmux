[English](README.md) | [日本語](README.ja.md)

# winsmux

Windows ネイティブのターミナルマルチプレクサ。AI エージェント間のクロスペイン通信を実現する。WSL2 不要。

- **ユーザー向け** — PowerShell 上で Alt キーバインドによるペイン操作
- **エージェント向け** — `psmux-bridge` CLI で任意のペインの読み取り・入力・キー送信が可能
- **エージェント間通信** — Claude Code が隣のペインの Codex に指示を送り、Codex が返答する。シェルコマンドを実行できるエージェントなら何でも参加できる。

```powershell
psmux-bridge read codex 20              # ペインを読む
psmux-bridge type codex "review src/auth.ts"  # テキストを入力
psmux-bridge keys codex Enter           # Enter を押す
```

## インストール

```powershell
irm https://raw.githubusercontent.com/Sora-bluesky/winsmux/main/install.ps1 | iex
```

インストールされるもの:
- **psmux** — 未インストールの場合は自動インストール（winget, scoop, cargo, chocolatey のいずれか）
- **psmux-bridge** — クロスペイン通信用 CLI
- **.psmux.conf** — Alt キーバインド、マウスサポート、ペインラベルの設定

すべて `~\.winsmux\` に配置される。

## クイックスタート

```powershell
# 1. セッションを作成
psmux new-session -s work

# 2. ペインを分割（Alt+n でも可）
psmux split-window -h

# 3. ペインにラベルを付ける
psmux-bridge name %1 claude
psmux-bridge name %2 codex

# 4. メッセージを送信
psmux-bridge read codex 20
psmux-bridge message codex "review src/auth.ts"
psmux-bridge read codex 20
psmux-bridge keys codex Enter
```

## キーバインド

すべてのキーバインドは **Alt** キーを使用する。プレフィックス不要。

### ペイン

| キー | 動作 |
|---|---|
| `Alt+i/k/j/l` | 上/下/左/右に移動 |
| `Alt+n` | 新しいペイン（分割 + 自動タイル） |
| `Alt+w` | ペインを閉じる |
| `Alt+o` | レイアウトを切り替え |
| `Alt+g` | ペインをマーク |
| `Alt+y` | マークしたペインと入れ替え |

### ウィンドウ

| キー | 動作 |
|---|---|
| `Alt+m` | 新しいウィンドウ |
| `Alt+u` | 次のウィンドウ |
| `Alt+h` | 前のウィンドウ |

### スクロール

| キー | 動作 |
|---|---|
| `Alt+Tab` | スクロールモードの切り替え |
| `i/k` | 上/下にスクロール |
| `Shift+I/K` | 半ページ上/下 |
| `q` または `Escape` | スクロールモード終了 |

### マウス

- クリックでペインを選択
- ドラッグでテキスト選択（自動でクリップボードにコピー）
- スクロールホイールでスクロール

## psmux-bridge

Windows 向けのクロスペイン通信 CLI。シェルコマンドを実行できるツールなら何でも使える — Claude Code、Codex、Gemini CLI、PowerShell スクリプトなど。

| コマンド | 説明 |
|---|---|
| `psmux-bridge list` | 全ペインをターゲット・プロセス・ラベル付きで表示 |
| `psmux-bridge read <target> [lines]` | ペインの末尾 N 行を読み取り（デフォルト 50） |
| `psmux-bridge type <target> <text>` | ペインにテキストを入力（Enter なし） |
| `psmux-bridge keys <target> <key>...` | キーを送信（Enter, Escape, C-c 等） |
| `psmux-bridge message <target> <text>` | 送信者情報付きのタグ付きメッセージを送信 |
| `psmux-bridge name <target> <label>` | ペインにラベルを付ける |
| `psmux-bridge resolve <label>` | ラベルからペインを検索 |
| `psmux-bridge id` | 自分のペイン ID を表示 |
| `psmux-bridge doctor` | 環境チェックと診断 |
| `psmux-bridge version` | バージョンを表示 |

### Read Guard

CLI は **read-before-act** ルールを強制する。ペインを `read` しない限り `type` や `keys` は実行できない。`type`/`keys` 実行後はマークがクリアされ、再度 `read` が必要になる。

```powershell
psmux-bridge type codex "hello"
# error: must read the pane before interacting. Run: psmux-bridge read codex
```

エージェントが誤ったペインに盲目的に入力するのを防ぐ仕組みだ。

### ターゲット指定

ペインは以下の方法で指定できる:
- **ペイン ID** — `%3`, `%5`（psmux ネイティブ ID）
- **ラベル** — `psmux-bridge name` で設定した任意の名前

ラベルはすべてのコマンドで自動解決される。保存先は `$env:APPDATA\winsmux\labels.json`。

## Commander Orchestration

Commander ワークフローは 4 ペイン構成で、Claude Code が builder/reviewer エージェントを指揮する:

```
┌──────────────┬──────────────┐
│  commander   │   builder    │
│ (Claude Code)│  (Codex CLI) │
├──────────────┼──────────────┤
│  reviewer    │   monitor    │
│  (Codex CLI) │  (shell)     │
└──────────────┴──────────────┘
```

| ペイン | 役割 | 担当 |
|---|---|---|
| commander | 設計・指揮 | タスク分解、指示送信、git 操作 |
| builder | 実装 | コード実装、reviewer の指摘を修正 |
| reviewer | レビュー | セキュリティ・アーキテクチャ・品質のレビュー |
| monitor | 監視 | テスト実行、dev server、ビルドログ |

ワークフローの流れ: **Plan → Build → Poll → Review → Poll → Judge → Commit → Next**

Commander はコードを直接書かない。実装は builder に委任し、reviewer の指摘も builder に修正指示を送る。

詳細は [SKILL.md](skills/winsmux/SKILL.md) を参照。Commander ワークフローの全手順、Poll パターン、自動承認ルールが記載されている。

## AI Agent Skills

winsmux スキルをインストールすると、エージェントが psmux-bridge の使い方を学習する:

```powershell
npx skills add Sora-bluesky/winsmux
```

Claude Code、Codex、Cursor、Copilot、[その他のエージェント](https://skills.sh)で動作する。

## アップデート

```powershell
winsmux update
```

## アンインストール

```powershell
winsmux uninstall
```

## 動作要件

- Windows 10/11
- PowerShell 7+（pwsh）
- [psmux](https://github.com/psmux/psmux)（自動インストール）

## 謝辞

winsmux は [smux](https://github.com/ShawnPana/smux)（[@ShawnPana](https://github.com/ShawnPana) 作）の Windows ネイティブ版だ。smux は macOS/Linux 向けに tmux を使った同様のターミナルマルチプレクサ + AI エージェント通信ワークフローを提供している。winsmux はその体験を psmux 経由で Windows にネイティブに持ち込む。WSL2 は不要。

## ライセンス

MIT
