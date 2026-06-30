# クイックスタート

このガイドでは、Windows 上で winsmux をインストールし、最初の管理ペインを動かすところまで進めます。通常はデスクトップアプリから始めます。スクリプト実行、ヘッドレス運用、ターミナル中心の運用では CLI 経路を使います。

## 1. 動作要件を確認する

先に次を用意してください。

- Windows 10 または Windows 11
- PowerShell 7+
- Windows Terminal
- `npm` を含む Node.js
- 実行したい公式エージェント CLI。例: Codex、Claude Code、Antigravity CLI

## 2. winsmux をインストールする

推奨するデスクトップアプリ経路:

1. 対象の GitHub Release から `winsmux_<version>_x64-setup.exe` を取得します。
2. インストーラーを実行します。
3. インストール済みの winsmux デスクトップアプリを開きます。
4. エージェントに作業させたいプロジェクトフォルダーを選択します。

CLI パッケージ経路:

```powershell
npm install -g winsmux
winsmux install --profile full
```

`full` プロファイルは、ターミナルランタイム、オーケストレーション用スクリプト、Windows Terminal プロファイル、vault、監査用の支援機能を入れます。

クイックインストール:

```powershell
npm install -g winsmux
winsmux install --profile full
winsmux version
winsmux doctor
```

## 3. プロジェクト設定を作る

エージェントに作業させたいリポジトリまたはプロジェクトで実行します。

```powershell
winsmux init
```

既定のワークスペース方針は `managed-worktree` です。ワーカーごとのファイル変更を分けて扱えます。

## 4. winsmux を起動する

推奨するデスクトップアプリ経路:

インストール済みの winsmux アプリを開き、プロジェクトフォルダーを選択します。オペレーターとワーカーのペインを操作する画面上の管制面として、デスクトップアプリを使います。

CLI で管理するワークスペース経路:

```powershell
winsmux launch
```

`winsmux launch` は npm/CLI パッケージ経路の管理対象 Windows Terminal ワークスペースを起動します。デスクトップアプリは開きません。ペイン出力を読み、採用するかどうかを決める責任はオペレーターに残ります。

作業を送る前に、設定済みのワーカーを確認します。

```powershell
winsmux workers status
winsmux workers attach w2
winsmux workers doctor
```

Colab 対応ワーカースロットでは、ファイルを指定して単発実行し、ログを確認できます。

```powershell
winsmux workers exec w2 --script workers/colab/impl_worker.py --run-id demo-1 -- --task-json-inline '{"task_id":"demo-1","title":"この変更を実装する"}' --worker-id worker-2 --run-id demo-1
winsmux workers logs w2
```

Antigravity CLI の一回実行ワーカーを使う場合は、`worker-backend:
antigravity` を設定し、ファイル化したプロンプトを実行します。winsmux は
`agy --print` を呼び出し、応答を成果物として保存します。プロンプト本文はログに残しません。

```powershell
winsmux workers exec w1 --script tasks/antigravity-worker-task.md --run-id agy-demo-1 --json
winsmux workers logs w1 --run-id agy-demo-1
```

`workers/colab/` の追跡済みテンプレートは、実装、批評、リポジトリ調査、
テスト実行計画、重い再判定を扱います。各テンプレートは構造化 JSON を出力し、
既定では `/content/winsmux_artifacts/<worker_id>/<run_id>/` に成果物を書き込みます。

アップロードは安全側に制限しています。明示したファイルは対象にできますが、
ディレクトリを送る場合は `--allow-dir` が必要です。その場合も `.git`、秘密情報、
`node_modules`、仮想環境、ビルド成果物、coverage、サイズが大きすぎるファイルは
既定で除外します。

Colab 対応のモデル作業では、`H100` または `A100` へ接続した Colab ノートブック、
またはアダプターが管理する同等の実行環境を先に用意します。winsmux は
`model_family` や `model_id` などのモデルメタデータを記録しますが、正確なモデルを
読み込む責任はタスクスクリプト側にあります。対象には Gemma、Llama、Mistral、Qwen、
DeepSeek、Kimi/Moonshot、蒸留モデルの変種を含められます。

Colab の実行リソースを使う前に、インストール済み環境で確認します。

```powershell
winsmux workers doctor
```

インストール済みパッケージではなく、ソースから検証している場合は、
リポジトリ内のモック受け入れ確認も使えます。

```powershell
Invoke-Pester -Path tests/ColabAcceptance.Tests.ps1 -PassThru
```

## 5. 読み取りと送信を試す

指示を送る前に、対象ペインの出力を確認します。

```powershell
winsmux list
winsmux read worker-1 30
winsmux send worker-1 "現在のブランチを確認し、次の安全な手順を報告してください。"
```

`winsmux read` の最後の数値は、読み取る末尾行数です。

## 6. 記録済みセッションを復元する

デスクトップアプリでは、右サイドバーの Agent Vault を開きます。記録済みセッションを検索または絞り込み、セッションカードを空いているワーカーペインへドラッグします。winsmux は記録されたプロバイダーメタデータを使い、Claude Code、Codex、OpenCode に合った再開コマンドを起動します。

同じペインですでに復元を開始している場合は、その処理が終わるまで待ってから次のセッションをドロップしてください。

## 7. 実行結果を比較する

2 つの記録済み実行ができたら、採用前に比較します。

```powershell
winsmux compare runs <left_run_id> <right_run_id>
winsmux compare promote <run_id>
```

## 次に読む

- インストールプロファイルと更新は [インストール](installation.ja.md) を参照してください。
- 起動プリセット、ワークツリー方針、スロット、資格情報は [カスタマイズ](customization.ja.md) を参照してください。
- 認証の境界は [認証方針](authentication-support.ja.md) を参照してください。
- モデルとランタイムの方針は [プロバイダーとモデルの対応方針](provider-and-model-support.ja.md) を参照してください。
- GPU 付き単発実行は [Google Colab ワーカー](google-colab-workers.ja.md) を参照してください。
