# クイックスタート

このガイドでは、Windows 上で winsmux をインストールし、最初の管理ペインを動かすところまで進めます。

## 1. 動作要件を確認する

先に次を用意してください。

- Windows 10 または Windows 11
- PowerShell 7+
- Windows Terminal
- `npm` を含む Node.js
- 実行したい公式エージェント CLI。例: Codex、Claude Code、Gemini

## 2. winsmux をインストールする

デスクトップアプリを使う場合は、対象の GitHub Release から `winsmux_<version>_x64-setup.exe` を取得し、実行します。起動後は、エージェントに作業させたいプロジェクトフォルダーを選択します。

CLI 中心で使う場合は、npm パッケージから入れます。

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

## 4. ワークスペースを起動する

```powershell
winsmux launch
```

管理された Windows Terminal ワークスペースが起動します。デスクトップアプリでは、同じプロジェクトをプロジェクト選択から開き、オペレーターとワーカーのペインを管制面から確認します。ペイン出力を読み、採用するかどうかを決める責任はオペレーターに残ります。

作業を送る前に、設定済みのワーカーを確認します。

```powershell
winsmux workers status
winsmux workers doctor
```

Colab 対応ワーカースロットでは、ファイルを指定して単発実行し、ログを確認できます。

```powershell
winsmux workers exec w2 --script workers/colab/impl_worker.py
winsmux workers logs w2
```

アップロードは安全側に制限しています。明示したファイルは対象にできますが、
ディレクトリを送る場合は `--allow-dir` が必要です。その場合も `.git`、秘密情報、
`node_modules`、仮想環境、ビルド成果物、coverage、サイズが大きすぎるファイルは
既定で除外します。

Colab 対応のモデル作業では、`H100` または `A100` へ接続した Colab ノートブック、
またはアダプターが管理する同等の実行環境を先に用意します。winsmux は
`model_family` や `model_id` などのモデルメタデータを記録しますが、正確なモデルを
読み込む責任はタスクスクリプト側にあります。対象には Gemma、Llama、Mistral、Qwen、
DeepSeek、Kimi/Moonshot、蒸留モデルの変種を含められます。

## 5. 読み取りと送信を試す

指示を送る前に、対象ペインの出力を確認します。

```powershell
winsmux list
winsmux read worker-1 30
winsmux send worker-1 "現在のブランチを確認し、次の安全な手順を報告してください。"
```

`winsmux read` の最後の数値は、読み取る末尾行数です。

## 6. 実行結果を比較する

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
