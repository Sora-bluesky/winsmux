# クイックスタート

このガイドでは、Windows 上で winsmux をインストールし、最初の管理ペインを動かすところまで進めます。

## 1. 動作要件を確認する

先に次を用意してください。

- Windows 10 または Windows 11
- PowerShell 7+
- Windows Terminal
- `npm` を含む Node.js
- 実行したいエージェント CLI。例: Codex CLI、Claude Code、Gemini CLI

## 2. winsmux をインストールする

```powershell
npm install -g winsmux
winsmux install --profile full
```

`full` プロファイルは、ターミナルランタイム、オーケストレーション用スクリプト、Windows Terminal プロファイル、vault、監査用の支援機能を入れます。

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

管理された Windows Terminal ワークスペースが起動します。ペイン出力を読み、採用するかどうかを決める責任はオペレーターに残ります。

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
