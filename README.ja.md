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
| `psmux-bridge ime-input <target>` | GUI ダイアログで日本語 IME 入力 |
| `psmux-bridge image-paste <target>` | クリップボード画像を保存してパスを送信 |
| `psmux-bridge clipboard-paste <target>` | クリップボードテキストをペインに送信 |
| `psmux-bridge doctor` | 環境チェックと IME 診断 |
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

## Orchestra（4 ペイン構成）

Orchestra ワークフローは 2×2 グリッドで、Claude Code が複数エージェントを指揮する:

```
┌──────────────┬──────────────┐
│  Commander   │   Builder    │
│ Claude Opus  │  Codex CLI   │
├──────────────┼──────────────┤
│  Researcher  │   Reviewer   │
│ Claude Sonnet│  Codex CLI   │
└──────────────┴──────────────┘
```

| ペイン | 役割 | 担当 |
|---|---|---|
| Commander | 設計・指揮 | タスク分解、指示送信、git 操作 |
| Builder | 実装 | コード実装、Reviewer の指摘を修正 |
| Researcher | 調査 | リサーチ、テスト、lint、ドキュメント |
| Reviewer | レビュー | セキュリティ・アーキテクチャ・品質のレビュー |

### クイック起動

```powershell
# 1. ターミナルを開いて psmux を起動
psmux

# 2. 別のターミナルから Orchestra セットアップを実行
pwsh scripts/start-orchestra.ps1 -ProjectDir C:\path\to\your\project
```

Commander は起動時に `--append-system-prompt` でロール・ペイン割り当て・ワークフロールールが自動注入される。

> **重要:** psmux は必ず手動でターミナルを開いて起動すること。`Start-Process` 経由だとカラーレンダリングが壊れる。

### カスタマイズ

全ロールをパラメータで変更可能:

```powershell
pwsh scripts/start-orchestra.ps1 `
  -ProjectDir C:\my\project `
  -Commander "claude --model opus" `
  -Researcher "claude --model sonnet" `
  -Builder "codex" `
  -Reviewer "claude --model haiku"
```

| パラメータ | デフォルト |
|---|---|
| `-ProjectDir` | カレントディレクトリ |
| `-Commander` | `claude --model opus --channels plugin:telegram@claude-plugins-official` |
| `-Researcher` | `claude --model sonnet` |
| `-Builder` | `codex` |
| `-Reviewer` | `codex` |
| `-ShieldHarness` | Off（スイッチ） |

### 承認レスモード（Shield Harness）

`-ShieldHarness` を追加すると Commander と Researcher が承認ダイアログなしで動作する。[Shield Harness](https://github.com/Sora-bluesky/shield-harness) が 22 のセキュリティフック、deny ルール、エビデンス記録を提供するため、危険な操作は自動でブロックされる。

```powershell
pwsh scripts/start-orchestra.ps1 -ProjectDir C:\my\project -ShieldHarness
```

- 初回: プロジェクトに shield-harness を自動初期化（`npx shield-harness init --profile standard`）
- 2回目以降: 既存のインストールを検出してスキップ
- `-ShieldHarness` なし: 従来通り（手動承認モード）

ワークフローの流れ: **Plan → Build → Poll → Review → Poll → Judge → Commit → Next**

Commander はコードを直接書かない。実装は Builder に委任し、Reviewer の指摘も Builder に修正指示を送る。

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
