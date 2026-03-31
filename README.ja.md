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
- **Windows Terminal Fragment** — WT のドロップダウンメニューに「winsmux Orchestra」プロファイルを追加

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
| `psmux-bridge wait <channel> [timeout]` | シグナル受信までブロック（ポーリング置換）       |
| `psmux-bridge signal <channel>`         | シグナル送信（待機プロセスをアンブロック）       |
| `psmux-bridge watch <label> [sil] [to]` | ペイン出力の沈黙を検知してブロック解除           |
| `psmux-bridge vault set <key> [value]`  | 資格情報をセキュアに保存（DPAPI）                |
| `psmux-bridge vault get <key>`          | 保存済み資格情報を取得                           |
| `psmux-bridge vault inject <pane>`      | 全資格情報を環境変数としてペインに注入           |
| `psmux-bridge vault list`               | 保存済み資格情報のキー一覧                       |
| `psmux-bridge profile [name] [agents]`  | WT ドロップダウンプロファイルの表示・登録         |
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

## Credential Vault

シークレットをセキュアに保管し、エージェントのペインに注入する。リポジトリに `.env` ファイルを置く必要はない。

```powershell
# 資格情報を保存（DPAPI 暗号化、Windows Credential Manager）
psmux-bridge vault set OPENAI_API_KEY sk-...
psmux-bridge vault set ANTHROPIC_API_KEY sk-ant-...

# ビルダーペインに全資格情報を $env: 変数として注入
psmux-bridge read builder 10
psmux-bridge vault inject builder
```

資格情報は Windows DPAPI でマシン単位に暗号化保存される。`vault inject` はターゲットペインに `$env:KEY = 'value'` コマンドを送信するため、エージェントプロセスは環境変数として受け取る。ディスクに平文は残らない。

## Windows Terminal 連携

インストーラーは [Fragments](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions) 経由で Windows Terminal のドロップダウンに **winsmux Orchestra** プロファイルを自動登録する。ワンクリックで `psmux-bridge doctor` → psmux セッション作成 → Orchestra スクリプト起動までを実行。

カスタムプロファイルの作成:

```powershell
psmux-bridge profile mysetup builder:codex reviewer:claude
```

## Orchestra

Orchestra は1人の Commander が複数の AI エージェントを並列管理する仕組みだ。Commander はユーザーのターミナルで動作（キーボード直接入力可能）、バックグラウンドのエージェントは psmux ペインで動く。やりたいことを Commander に伝えれば、ビルダーへの作業分割・完了ポーリング・レビュー依頼・競合チェック・コミットまでを自動で進める。

### Commander がやること

1. **作業分割** — ビルダーごとに担当ファイルを割り当て、互いに干渉させない
2. **完了ポーリング** — 全エージェントを `psmux-bridge read` で巡回し、完了を検知
3. **段階的レビュー** — ビルダーが完了した順にレビュアーへ送信（全員を待たない）
4. **競合検知** — マージ前に `git diff --name-only` で変更ファイルの重複をチェック
5. **安全なコミット** — レビュー通過＋競合なしの場合のみコミット

### マルチベンダー対応

異なる CLI エージェントを同じ Orchestra に混在できる。スクリプトが CLI の種類を自動判定して差異を吸収する:

| CLI         | 承認レスフラグ（`-ShieldHarness` 有効時） |
| ----------- | ----------------------------------------- |
| Claude Code | `--permission-mode bypassPermissions`     |
| Codex CLI   | `--full-auto`                             |
| Gemini CLI  | `--yolo`                                  |

`-ShieldHarness` なし: フラグは付与されない（手動承認モード）。

### クイック起動

```powershell
# 1. ターミナルを開いて psmux を起動
psmux

# 2. 別のターミナルから Orchestra セットアップを実行
pwsh scripts/start-orchestra.ps1 -ProjectDir C:\path\to\project

# 3. さらに別のターミナルで Commander を起動
cd C:\path\to\project
claude --model claude-opus-4-6 --append-system-prompt-file .commander-prompt.txt
```

### スケールアップ（例: ビルダー4 + リサーチャー + レビュアー）

```powershell
pwsh scripts/start-orchestra.ps1 -ProjectDir C:\my\project -Rows 2 -Cols 3 -Agents @(
  @{label="builder-1"; command="codex"},
  @{label="builder-2"; command="codex"},
  @{label="builder-3"; command="gemini --model gemini-3.1-pro-preview"},
  @{label="researcher"; command="claude --model sonnet"},
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

`.commander-prompt.txt` は実際のペインID・ラベル・協調プロトコル付きで自動生成される。Commander は誰にどう話しかければいいか常に把握している。

| パラメータ       | デフォルト        | 説明                                                                                        |
| ---------------- | ----------------- | ------------------------------------------------------------------------------------------- |
| `-ProjectDir`    | カレント          | 全ペインの作業ディレクトリ                                                                  |
| `-Rows`          | 2                 | グリッドの行数                                                                              |
| `-Cols`          | 2                 | グリッドの列数                                                                              |
| `-Agents`        | 4ペインデフォルト | `@{label; command}` の配列                                                                  |
| `-ShieldHarness` | Off               | [Shield Harness](https://github.com/Sora-bluesky/shield-harness) による承認レスモード有効化 |

詳細は [SKILL.md](skills/winsmux/SKILL.md) を参照。管理プロトコル（パイプライン運用、researcher 偵察、reviewer 小分け、エージェント選定）はスキルの references/ に同梱され、エージェントがオンデマンドで読み込む。

## AI Agent Skills

winsmux スキルをインストールすると、エージェントが psmux-bridge の使い方を学習する:

```powershell
npx skills add Sora-bluesky/winsmux
```

スキルに含まれるもの:

- psmux-bridge の使い方（[SKILL.md](skills/winsmux/SKILL.md)）
- Orchestra 管理プロトコル（[references/orchestra-management.md](skills/winsmux/references/orchestra-management.md)）
- エージェント選定ガイド（[references/agent-selection.md](skills/winsmux/references/agent-selection.md)）

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
