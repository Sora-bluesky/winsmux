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

| キー          | 動作                              |
| ------------- | --------------------------------- |
| `Alt+i/k/j/l` | 上/下/左/右に移動                 |
| `Alt+n`       | 新しいペイン（分割 + 自動タイル） |
| `Alt+w`       | ペインを閉じる                    |
| `Alt+o`       | レイアウトを切り替え              |
| `Alt+g`       | ペインをマーク                    |
| `Alt+y`       | マークしたペインと入れ替え        |

### ウィンドウ

| キー    | 動作             |
| ------- | ---------------- |
| `Alt+m` | 新しいウィンドウ |
| `Alt+u` | 次のウィンドウ   |
| `Alt+h` | 前のウィンドウ   |

### スクロール

| キー                | 動作                       |
| ------------------- | -------------------------- |
| `Alt+Tab`           | スクロールモードの切り替え |
| `i/k`               | 上/下にスクロール          |
| `Shift+I/K`         | 半ページ上/下              |
| `q` または `Escape` | スクロールモード終了       |

### マウス

- クリックでペインを選択
- ドラッグでテキスト選択（自動でクリップボードにコピー）
- スクロールホイールでスクロール

## psmux-bridge

Windows 向けのクロスペイン通信 CLI。シェルコマンドを実行できるツールなら何でも使える — Claude Code、Codex、Gemini CLI、PowerShell スクリプトなど。

| コマンド                                | 説明                                             |
| --------------------------------------- | ------------------------------------------------ |
| `psmux-bridge list`                     | 全ペインをターゲット・プロセス・ラベル付きで表示 |
| `psmux-bridge read <target> [lines]`    | ペインの末尾 N 行を読み取り（デフォルト 50）     |
| `psmux-bridge type <target> <text>`     | ペインにテキストを入力（Enter なし）             |
| `psmux-bridge keys <target> <key>...`   | キーを送信（Enter, Escape, C-c 等）              |
| `psmux-bridge message <target> <text>`  | 送信者情報付きのタグ付きメッセージを送信         |
| `psmux-bridge name <target> <label>`    | ペインにラベルを付ける                           |
| `psmux-bridge resolve <label>`          | ラベルからペインを検索                           |
| `psmux-bridge id`                       | 自分のペイン ID を表示                           |
| `psmux-bridge ime-input <target>`       | GUI ダイアログで日本語 IME 入力                  |
| `psmux-bridge image-paste <target>`     | クリップボード画像を保存してパスを送信           |
| `psmux-bridge clipboard-paste <target>` | クリップボードテキストをペインに送信             |
| `psmux-bridge send <target> <text>`     | テキスト送信 + Enter（推奨）                     |
| `psmux-bridge focus <label\|target>`    | アクティブペイン切替（psmux 外から操作）         |
| `psmux-bridge doctor`                   | 環境チェックと IME 診断                          |
| `psmux-bridge version`                  | バージョンを表示                                 |

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

## Orchestra

Orchestra ワークフローは Commander（別ターミナル）がバックグラウンドの psmux ペインにいるエージェントを指揮する構成。任意のグリッドサイズ、混合 CLI（Claude Code、Codex、Gemini CLI）に対応。

### デフォルト（2×2）

```powershell
# 1. ターミナルを開いて psmux を起動
psmux

# 2. 別のターミナルから Orchestra セットアップを実行
pwsh scripts/start-orchestra.ps1 -ProjectDir C:\path\to\project
```

### カスタム（例: 3×2 で 6 エージェント）

```powershell
pwsh scripts/start-orchestra.ps1 -ProjectDir C:\my\project -Rows 2 -Cols 3 -Agents @(
  @{label="builder-1"; command="codex"},
  @{label="researcher"; command="claude --model sonnet"},
  @{label="builder-2"; command="codex"},
  @{label="builder-3"; command="gemini --model gemini-3.1-pro-preview"},
  @{label="builder-4"; command="gemini --model gemini-3-flash-preview"},
  @{label="reviewer"; command="codex"}
) -ShieldHarness
```

```
┌──────────┬──────────┬──────────┐
│builder-1 │builder-2 │builder-3 │
├──────────┼──────────┼──────────┤
│researcher│builder-4 │reviewer  │
└──────────┴──────────┴──────────┘
```

Commander は別ターミナルで直接キーボード入力可能な状態で起動:

```powershell
cd C:\my\project
claude --model claude-opus-4-6 --permission-mode bypassPermissions --append-system-prompt-file .commander-prompt.txt
```

| パラメータ       | デフォルト        | 説明                       |
| ---------------- | ----------------- | -------------------------- |
| `-ProjectDir`    | カレント          | 全ペインの作業ディレクトリ |
| `-Rows`          | 2                 | グリッドの行数             |
| `-Cols`          | 2                 | グリッドの列数             |
| `-Agents`        | 4ペインデフォルト | `@{label; command}` の配列 |
| `-ShieldHarness` | Off               | 承認レスモード有効化       |

### 承認レスモード（Shield Harness）

`-ShieldHarness` を追加すると承認ダイアログなしで動作する。[Shield Harness](https://github.com/Sora-bluesky/shield-harness) がセキュリティフックを提供し、危険な操作を自動ブロックする。

有効時、スクリプトが各 CLI に応じたフラグを自動付与:

| CLI         | 自動付与されるフラグ                  |
| ----------- | ------------------------------------- |
| Claude Code | `--permission-mode bypassPermissions` |
| Codex CLI   | `--full-auto`                         |
| Gemini CLI  | `--yolo`                              |

`-ShieldHarness` なし: フラグは付与されない（手動承認モード）。

### 並列ビルダー管理

Commander は複数ビルダーを以下のプロトコルで管理する:

1. **Split** — ビルダーごとに独立したファイル領域を割り当て
2. **Poll** — `psmux-bridge read builder-1`, `read builder-2` で巡回確認
3. **Review** — 完了したビルダーから順にレビュアーへ
4. **Conflict check** — マージ前に `git diff --name-only` で競合検知
5. **Commit** — レビュー通過後にコミット

詳細は [SKILL.md](skills/winsmux/SKILL.md) を参照。

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
