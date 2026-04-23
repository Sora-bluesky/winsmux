[English](README.md) | [日本語](README.ja.md)

<p align="center">
  <img src="docs/winsmux-hero.png" alt="WINSMUX" width="600">
</p>

# winsmux

`winsmux` は、1 人のオペレーターが Windows 上で複数の CLI エージェントを運用・監督するためのツールです。

オペレーターは手元で制御を保てます。`winsmux` はペインを起動し、各エージェントの出力を読み取り、正しいペインへ指示を送り、結果を比較し、レビューに必要な証跡を残します。

`winsmux` が AI サービスへ代理ログインすることはありません。各 CLI エージェントは、それぞれ自分のログイン状態や API キー設定を使います。

## 何ができるか

- 複数の CLI エージェント用に、管理された Windows Terminal ワークスペースを起動します。
- オペレーターがペインを読み、送信し、中断し、状態を確認できます。
- 分離を有効にすると、ワーカーごとに別々の git ワークツリーを使えます。
- 記録済みの実行結果を比較し、勝者を選ぶ前に両方の実行で変更されたファイルを確認できます。
- 選択した資格情報を Windows DPAPI で保護し、リポジトリに `.env` ファイルを置かずに扱えます。
- レビューや監査に使う検証証跡を残せます。

## 向いている場面

Windows PC で複数のコーディングエージェントを動かしつつ、制御を 1 人のオペレーターに集約したい時に使います。

特に次の用途に向いています。

- 異なるエージェントやプロバイダーの結果を比較したい。
- ワーカーごとのファイル変更を分けたい。
- 最終要約を待たず、実行中のペインを直接見たい。
- 変更を受け入れる前にレビュー証跡を確認したい。
- 特定のモデルベンダーに運用を固定したくない。

ターミナルマルチプレクサとしてだけ使いたい場合は、[`core/docs`](core/docs) を参照してください。

## 動作要件

- Windows 10 または Windows 11
- PowerShell 7+
- Windows Terminal
- 実行したい CLI エージェント。例: Codex CLI、Claude Code、Gemini CLI

Rust は、ランタイムをソースからビルドする時だけ必要です。

## 始め方

Windows では `npm` からインストールします。

```powershell
npm install -g winsmux
```

最初のセットアップでは、次のコマンドを使います。

```powershell
winsmux install --profile full
```

`npm` 経由のインストールでは、`--profile` で導入対象を切り分けます。
`winsmux update` に新しい指定を渡さない場合は、前回記録したプロファイルを使います。
`core` では、オーケストレーション用のスクリプトを含めません。
Windows Terminal 側のプロファイルも、選んだインストールプロファイルに合わせて扱います。
後からインストールプロファイルを変更した場合、インストーラーは対象外になった支援スクリプトを削除します。

次に、プロジェクト設定を作り、既定のワークスペースを起動します。

```powershell
winsmux init
winsmux launch
```

`winsmux init` の既定値は、ワーカーごとに管理されたワークツリーです。
通常は指定不要です。方針を明示したい時だけ、次の指定を使います。

```powershell
winsmux init --workspace-lifecycle managed-worktree
```

比較向けの実行を始める前に、起動プリセットを確認できます。

```powershell
winsmux launcher presets --json
```

## 主要コマンド

```powershell
winsmux list
winsmux read worker-1 30
winsmux send worker-2 "最新の認証変更をレビューしてください。"
winsmux health-check
winsmux compare runs <left_run_id> <right_run_id>
winsmux compare preflight <left_ref> <right_ref>
winsmux compare promote <run_id>
```

| コマンド | 用途 |
| ------- | ------- |
| `winsmux init` | 既定のプロジェクト設定を作成 |
| `winsmux launch` | 確認を通し、管理対象ワークスペースを起動 |
| `winsmux launcher presets` | 起動プリセットとペアテンプレートを表示 |
| `winsmux launcher lifecycle` | ワークスペースのライフサイクル方針を選択 |
| `winsmux compare runs` | 2 つの記録済み実行の証跡と信頼度を比較 |
| `winsmux compare preflight` | マージ前や比較レビュー前に 2 つの参照を確認 |
| `winsmux compare promote` | 成功した実行結果を、次の実行で使う入力として書き出す |
| `winsmux read` | 操作前にペイン出力を読む |
| `winsmux send` | ペインへテキストを送る |
| `winsmux vault set` | 資格情報を Windows DPAPI で保護して保存 |
| `winsmux vault inject` | 保存済み資格情報を対象ペインへ差し込む |

`winsmux conflict-preflight` は、`winsmux compare preflight` の互換コマンドとして引き続き利用できます。

## 認証方針

| ツール | 認証方式 | winsmux での扱い |
| ------- | ------- | ------- |
| Claude Code | API key / ドキュメント化された企業向け認証 | 公式に対応 |
| Claude Code | Pro / Max OAuth | 当該 PC での対話利用のみ |
| Codex CLI | API key | 公式に対応 |
| Codex CLI | ChatGPT OAuth | このマシン上での対話利用のみ |
| Gemini CLI | Gemini API key | 公式に対応 |
| Gemini CLI | Vertex AI | 公式に対応 |
| Gemini CLI | Google OAuth | 当該 PC での対話利用のみ |

詳しくは [認証方針](docs/authentication-support.ja.md) を参照してください。

## 安全に使うための注意

- 指示を送る前に、`winsmux read` で送り先ペインの出力を確認してください。
- 受け入れ可否の最終判断は、1 人のオペレーターが担ってください。
- 複数のエージェントが並列で編集する時は、既定の管理ワークツリー方針を維持してください。
- API キーをペインのチャットや issue コメントへ貼らないでください。
- ペインへ資格情報を渡す必要がある時は、`winsmux vault` を使ってください。
- 比較結果やリリース証跡は、レビュー材料として扱ってください。自動承認には使わないでください。

## 関連ドキュメント

- [オペレーターモデル](docs/operator-model.md)（英語のみ）
- [認証方針](docs/authentication-support.ja.md)
- [トラブルシューティング](docs/TROUBLESHOOTING.md)
- [リポジトリの公開面ポリシー](docs/repo-surface-policy.md)（英語のみ）
- [ランタイム機能](core/docs/features.md)（英語のみ）
- [ランタイム設定](core/docs/configuration.md)（英語のみ）
- [tmux 互換性](core/docs/compatibility.md)（英語のみ）

開発者向け、コントリビューター向けの運用ルールは、この README には載せません。リポジトリ自体を変更する場合は、まず [リポジトリの公開面ポリシー](docs/repo-surface-policy.md) を参照してください。

## ライセンス

Apache License 2.0 です。

一部のランタイム互換コードには、上流由来の MIT ライセンス表示が `core/LICENSE` に残ります。
詳しくは [サードパーティライセンス](THIRD_PARTY_NOTICES.md) を参照してください。
