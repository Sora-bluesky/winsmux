[English](README.md) | [日本語](README.ja.md)

<p align="center">
  <img src="docs/banner.png" alt="WINSMUX" width="600">
</p>

# winsmux

**winsmux は Windows ネイティブの AI エージェントオーケストレーション基盤です。**

1 つのオペレーターが Windows 上の複数のエージェント CLI を統括するための、ランタイムと制御レイヤーを提供します。単一ベンダーに閉じず、ペイン実行、ライブ監督、レビュー統制を同じワークスペースで扱えるようにします。

## winsmux が提供するもの

- **マルチベンダー対応**: Codex、Claude、Gemini など複数の CLI エージェントを同じセッションで並行運用
- **リアルタイム可視化**: 事後要約ではなく、`winsmux` ペインを通じて各エージェントの状態をライブで監督
- **統制しやすい実行基盤**: 1 人の外部オペレーター、managed pane agents、review/evidence の導線を分離

```powershell
winsmux read worker-1 20
winsmux send worker-2 "最新の auth 変更をレビューしてください。"
winsmux health-check
```

## winsmux が向いている場面

多くの agent ツールは、単一ベンダー・単一実行モデルに最適化されています。winsmux は、Windows で複数エージェントを同時に動かしつつ、全体を観測可能かつ統制可能に保ちたいチーム向けに設計されています。

- **ベンダー非依存のオーケストレーション**: 1 つの operator loop の下で Codex、Claude、Gemini、将来のローカルモデルを混在運用
- **pane-native な運用**: `winsmux` を通じて、ライブのペインを inspect / interrupt / redirect / relabel
- **統制された実行**: read-before-act、review-capable slot、worker worktree isolation を組み合わせて事故を減らす
- **Windows-first**: WSL2 や Linux 経由を前提にしない

## プラットフォームモデル

```text
winsmux
├── winsmux CLI
├── Orchestra
├── Role Gates
├── Worker Worktree Isolation
├── Credential Vault (DPAPI)
└── Evidence Ledger
```

- **`winsmux`** は pane targeting、messaging、health-check、vault injection、operator controls を担います
- **Orchestra** は 1 人の external operator と複数の managed pane agents を既定モデルにします
- **Role gates** は operator と pane agents の実行権限を分離します
- **Worker worktree isolation** は worker ごとに独立した git worktree を与えます
- **Evidence Ledger** は review や audit 向けの証跡を扱います

公開向けの operator / pane architecture は [docs/operator-model.md](docs/operator-model.md) を参照してください。役割定義は [`.claude/CLAUDE.md`](.claude/CLAUDE.md)、[`AGENT-BASE.md`](AGENT-BASE.md)、[`AGENT.md`](AGENT.md)、[`GEMINI.md`](GEMINI.md) に分割しています。

## コアランタイム

オーケストレーション層の下には、Rust 製の Windows ネイティブ terminal multiplexer runtime があります。

- **tmux 互換ランタイム**: tmux 風のコマンド体系を話し、`~/.tmux.conf` や既存テーマを利用可能
- **Windows ネイティブ UX**: ConPTY ベース、マウス対応、WSL/Cygwin/MSYS2 依存なし
- **複数エントリポイント**: `winsmux`、`pmux`、`tmux`
- **自動化向け**: 76 個の tmux 互換コマンドと 126+ の format 変数

| ランタイム資料 | 内容 |
| ------- | ------- |
| [Features](core/docs/features.md) | マウス、copy mode、layout、format、script surface |
| [Compatibility](core/docs/compatibility.md) | tmux 互換マトリクスとコマンド実装状況 |
| [Configuration](core/docs/configuration.md) | config file、option、environment variable、`.tmux.conf` 対応 |
| [Key Bindings](core/docs/keybindings.md) | 既定のキーボード操作とマウス操作 |
| [Mouse over SSH](core/docs/mouse-ssh.md) | SSH 越しのマウス動作と Windows 版要件 |
| [Claude Code](core/docs/claude-code.md) | teammate pane がランタイム上でどう動くか |

## インストール

```powershell
irm https://raw.githubusercontent.com/Sora-bluesky/winsmux/main/install.ps1 | iex
```

インストーラーは次を行います。

- `winsmux` ランタイムが未インストールなら導入
- `winsmux` wrapper script を `~\.winsmux\bin` に配置
- `.winsmux.conf` を構成
- Windows Terminal に **winsmux Orchestra** profile を登録

tmux 互換ランタイムだけが必要なら、直接インストールも可能です。

```powershell
winget install winsmux
cargo install winsmux
scoop bucket add winsmux https://github.com/winsmux/scoop-winsmux
scoop install winsmux
choco install winsmux
```

GitHub Releases の `.zip` を使うか、[`core/`](core) でソースからビルドすることもできます。

## クイックスタート

```powershell
# 環境チェック
winsmux doctor

# セッション開始
winsmux new-session -s orchestra

# 既定の Orchestra レイアウトを起動
pwsh winsmux-core/scripts/orchestra-start.ps1
```

Windows で `winsmux doctor` が worktree git sandbox limitation を報告した場合は、sandboxed pane では file edit / test を続けつつ、`.git/worktrees/*/index.lock` を作れないときの `git add` / `git commit` / `git push` だけを通常の shell から実行してください。

Windows の `ConstrainedLanguageMode` を含む詳細な回避策は [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) を参照してください。

現在の既定レイアウトは次です。

- 管理対象ウィンドウの外に external operator terminal
- 管理対象ウィンドウの中に複数の `worker-*` pane
- 旧 `Commander / Builder / Researcher / Reviewer` レイアウトは compatibility mode でのみ有効

セッション内では、pane を一覧・読取・送信できます。

```powershell
winsmux list
winsmux read worker-1 30
winsmux send worker-3 "upstream issue を要約してください。"
```

## ガバナンスの要点

- **Role gates**: external operator と managed pane agents に同じ command surface を与えない
- **Read Guard**: 読んでいない pane への blind input を防ぐ
- **Worktree isolation**: worker ごとに独立した git worktree を持てる
- **Credential Vault**: Windows DPAPI でシークレットを管理し、repo に `.env` を置かない
- **Evidence Ledger**: prompt、action、review evidence を記録できる

## 主要コマンド

| コマンド | 用途 |
| ------- | ------- |
| `winsmux list` | pane、label、process を表示 |
| `winsmux read <target> [lines]` | 実行前に pane output を読む |
| `winsmux send <target> <text>` | text を送って Enter を押す |
| `winsmux health-check` | label 付き pane の READY/BUSY/HUNG/DEAD を報告 |
| `winsmux vault set <key> [value]` | DPAPI-backed vault に資格情報を保存 |
| `winsmux vault inject <pane>` | 保存済み資格情報を対象 pane に注入 |
| `winsmux update` | 最新版へ更新 |
| `winsmux uninstall` | winsmux を削除 |

## 動作要件

- Windows 10/11
- PowerShell 7+
- Windows Terminal 推奨

## ライセンス

MIT
