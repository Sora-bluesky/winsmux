[English](README.md) | [日本語](README.ja.md)

<p align="center">
  <img src="docs/brand-hero.svg" alt="winsmux: Governance for AI agents on Windows" width="100%">
</p>

# winsmux

`winsmux` は、複数のコーディング CLI を同時に動かす人のための、Windows ネイティブの管制デスクです。1 人の人間が、複数の CLI エージェントを見て判断するためのコックピットです。

エージェントをブラックボックス化せず、各ワーカーを実際のペインで見せ、ファイル変更を git worktree で分離し、必要なペインへ指示を送り、中断できます。完了後は、変更ファイルの重なり、レビュー状態、検証状態、チェックポイントなどの証跡を見ながら、どの結果を採用するか決められます。

Claude Code、Codex、Gemini を 1 つずつ手で眺める段階を越えたい。ただし、クラウド任せにも、特定ベンダー任せにもしたくない。`winsmux` はそのためのローカル管制面です。

たとえば、同じタスクを 2 つのエージェントに並走させ、両方のペインを見ながら、逸れた片方だけを止め、最後に証跡を比較して採用する結果を選べます。

`winsmux` が AI サービスへ代理ログインすることはありません。各 CLI エージェントは、それぞれ自分のログイン状態や API キー設定を使います。

## なぜ必要か

既存の道具は、この作業の一部だけを解決します。

- ターミナルマルチプレクサはペインを並べられますが、どのエージェントがどのファイルを変えたかまでは扱いません。
- IDE のチャット画面は 1 つの会話には便利ですが、複数の公式 CLI を束ねる管制面にはなりません。
- エージェントフレームワークは自動化に強い一方で、作業がコードやクラウド側へ寄りやすく、人間のオペレーターが途中で見て止める前提にはなりにくいです。

`winsmux` はその中間にあります。公式 CLI エージェントを見える状態で動かし、作業を独立した作業ディレクトリに分け、証跡を残し、最後に何を採用するかは人間が決めます。

## 何ができるか

- 複数の CLI エージェント用に、管理された Windows Terminal ワークスペースを起動します。
- オペレーターがペインを読み、ペインへ送信し、ペインを中断し、状態を確認できます。
- 既定で 6 つの管理ワーカースロットを作成します。生成される最初のスロットは Codex レビュー用で、残りのスロットは選択したワーカーバックエンドに従います。
- ワークツリー分離を有効にすると、ワーカーごとに別々の git ワークツリーを使えます。
- 記録済みの実行結果を比較し、採用する結果を選ぶ前に両方で変更されたファイルを確認できます。
- 記録済みの実行について、レビュー、検証、アーキテクチャ、チェックポイント、後続作業などの証跡を確認できます。
- 生の端末ログやローカル環境固有のパスを保存せず、実行終了時の構造化スナップショットを残せます。
- 選択した資格情報を Windows DPAPI で保護し、リポジトリに `.env` ファイルを置かずに扱えます。
- レビューや監査に使う検証証跡を残せます。

## 向いている場面

Windows PC で複数のコーディングエージェントを動かしつつ、制御を 1 人のオペレーターに集約したい時に使います。

特に次の用途に向いています。

- 異なるエージェントやプロバイダーの結果を比較したい。
- ワーカーごとのファイル変更を分けたい。
- 最終要約を待たず、実行中のペインを直接見たい。
- 変更を受け入れる前にレビュー証跡を確認したい。
- 後から再開または比較できる形で、実行の文脈を残したい。
- 特定のモデル提供元に運用を縛られたくない。

ターミナルマルチプレクサとしてだけ使いたい場合は、[`core/docs`](core/docs) を参照してください。

## 動作要件

- Windows 10 または Windows 11
- PowerShell 7+
- Windows Terminal
- 実行したい公式エージェント CLI。例: Claude Code、Codex、Gemini

Rust は、ランタイムをソースからビルドする時だけ必要です。

## 始め方

デスクトップアプリを使う場合は、対象の GitHub Release から `winsmux_<version>_x64-setup.exe` を取得し、実行します。起動後は、エージェントに作業させたいプロジェクトフォルダーを選択します。

CLI 中心で使う場合の最短手順は次の 4 コマンドです。

```powershell
npm install -g winsmux
winsmux install --profile full
winsmux init
winsmux launch
```

初回の流れは [クイックスタート](docs/quickstart.ja.md) を参照してください。
デスクトップインストーラー、CLI プロファイル、更新、アンインストールは [インストール](docs/installation.ja.md) にまとめています。
起動プリセット、ワークツリー方針、スロット、資格情報、デスクトップ設定は [カスタマイズ](docs/customization.ja.md) を参照してください。

## 主要コマンド

```powershell
winsmux list
winsmux read worker-1 30
winsmux send worker-2 "最新の認証変更をレビューしてください。"
winsmux health-check
winsmux workers status
winsmux workers doctor
winsmux workers exec w2 --script workers/colab/impl_worker.py --run-id demo-1 -- --task-json-inline '{"task_id":"demo-1","title":"この変更を実装する"}' --worker-id worker-2 --run-id demo-1
winsmux workers upload w2 data/input.json --remote /content/input.json
winsmux workers download w2 /content/output.json
winsmux workers sandbox baseline w2 --run-id demo-1 --json
winsmux workers broker baseline w2 --run-id demo-1 --endpoint https://broker.example.invalid/worker --json
winsmux workers broker token issue w2 --run-id demo-1 --ttl-seconds 900 --json
winsmux review-pack <run_id> --json
winsmux compare runs <left_run_id> <right_run_id>
winsmux compare preflight <left_ref> <right_ref>
winsmux compare promote <run_id>
winsmux meta-plan --task "この変更を計画して" --json
winsmux meta-plan --task "この変更を計画して" --roles .winsmux/meta-plan-roles.yaml --review-rounds 2 --json
winsmux skills --json
```

| コマンド | 用途 |
| ------- | ------- |
| `winsmux init` | 既定のプロジェクト設定を作成 |
| `winsmux launch` | 確認を通し、管理対象ワークスペースを起動 |
| `winsmux launcher presets` | 起動プリセットとペア構成テンプレートを表示 |
| `winsmux launcher lifecycle` | ワークスペースのライフサイクル方針を選択 |
| `winsmux workers status` | ワーカースロットのバックエンド、状態、GPU、セッション、直近コマンドを表示 |
| `winsmux workers attach` | Colab 対応ワーカーを、長時間ループを始めずにデスクトップ表示へ準備 |
| `winsmux workers doctor` | ワーカー設定、Colab CLI、認証、uv、状態ファイルの場所を診断 |
| `winsmux workers exec` | Colab 対応ワーカースロットで、ファイル指定の単発実行を行う |
| `winsmux workers logs` | ワーカー実行の保存済みログを読む。必要に応じて Colab CLI から取得 |
| `winsmux workers upload` | 明示したファイル、または許可したディレクトリだけをアップロード |
| `winsmux workers download` | リモート成果物をプロジェクト配下へダウンロード |
| `winsmux workers sandbox baseline` | 準備済み隔離実行に `restricted_token` と ACL 境界の土台を定義 |
| `winsmux workers broker baseline` | 準備済み隔離実行に、単一の外部ブローカーノード契約を定義 |
| `winsmux workers broker token` | 短命ブローカー実行トークンを発行または確認。値は出力しない |
| `winsmux review-pack` | 変更ファイル、テスト結果、リスク、実行コマンド、成果物参照だけを含むレビュー用パケットを書き出す |
| `winsmux compare runs` | 2 つの記録済み実行について、証跡と信頼度を比較 |
| `winsmux compare preflight` | マージ前や比較レビュー前に 2 つの git 参照を確認 |
| `winsmux compare promote` | 成功した実行結果を、次の実行で使う入力として書き出す |
| `winsmux meta-plan` | 実行前に読み取り専用で、複数ロールでの計画を作成 |
| `winsmux skills` | エージェントが読めるコマンド仕様を出力 |
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
| Codex | API key | 公式に対応 |
| Codex | ChatGPT OAuth | この PC での対話利用のみ |
| Gemini | Gemini API key | 公式に対応 |
| Gemini | Vertex AI の Gemini API | 公式に対応 |
| Gemini | Google OAuth | 当該 PC での対話利用のみ |

詳しくは [認証方針](docs/authentication-support.ja.md) を参照してください。
[プロバイダーとモデルの対応方針](docs/provider-and-model-support.ja.md) では、クラウド、Colab、将来のローカル LLM ランタイムの扱いを説明しています。
[外部コントロールプレーン API](docs/external-control-plane.ja.md) では、外部自動化クライアント向けのローカル named pipe JSON-RPC 契約を説明しています。
[Google Colab ワーカー](docs/google-colab-workers.ja.md) では、`H100` / `A100` 前提の設定を説明しています。

## 安全に使うための注意

- 指示を送る前に、`winsmux read` で送り先ペインの出力を確認してください。
- 受け入れ可否の最終判断は、1 人のオペレーターが担ってください。
- 複数のエージェントが並列で編集する時は、既定の管理ワークツリー方針を維持してください。
- API キーをペインのチャットや Issue コメントへ貼らないでください。
- ペインへ資格情報を渡す必要がある時は、`winsmux vault` を使ってください。
- 比較結果やリリース証跡は、レビュー材料として扱ってください。自動承認には使わないでください。

互換用の旧コマンド名 `psmux`、`pmux`、`tmux` は配布しません。
スクリプトやドキュメントでは `winsmux` を使ってください。tmux 互換の設定、ターゲット、コマンドは、ドキュメントで明記した範囲で引き続き利用できます。

## 関連ドキュメント

- [オペレーターモデル](docs/operator-model.md)（英語のみ）
- [ドキュメント一覧](docs/README.ja.md)
- [クイックスタート](docs/quickstart.ja.md)
- [インストール](docs/installation.ja.md)
- [カスタマイズ](docs/customization.ja.md)
- [認証方針](docs/authentication-support.ja.md)
- [プロバイダーとモデルの対応方針](docs/provider-and-model-support.ja.md)
- [外部コントロールプレーン API](docs/external-control-plane.ja.md)
- [Google Colab ワーカー](docs/google-colab-workers.ja.md)
- [トラブルシューティング](docs/TROUBLESHOOTING.ja.md)
- [リポジトリの公開面ポリシー](docs/repo-surface-policy.md)（英語のみ）
- [ランタイム機能](core/docs/features.md)（英語のみ）
- [ランタイム設定](core/docs/configuration.md)（英語のみ）
- [tmux 互換性](core/docs/compatibility.md)（英語のみ）

開発者向け、コントリビューター向けの運用ルールは、この README には載せません。リポジトリ自体を変更する場合は、まず [リポジトリの公開面ポリシー](docs/repo-surface-policy.md) を参照してください。

## ライセンス

Apache License 2.0 です。

一部のランタイム互換コードには、上流プロジェクト由来の MIT ライセンス表示が `core/LICENSE` に残ります。
詳しくは [サードパーティライセンス](THIRD_PARTY_NOTICES.md) を参照してください。
