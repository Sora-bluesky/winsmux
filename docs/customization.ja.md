# カスタマイズ

カスタマイズは、winsmux をローカルの運用に合わせるためのものです。共有資格情報の仲介役にするものではありません。

## ワークスペース方針

`winsmux init` の既定値は、ワーカーごとの管理ワークツリーです。

```powershell
winsmux init --workspace-lifecycle managed-worktree
```

複数のエージェントが並列で編集する場合は、管理ワークツリーを使ってください。オペレーターがどの変更を取り込むか判断するまで、変更を分離した状態で保持できます。

## 起動プリセット

比較を目的とした実行を始める前に、プリセットを確認できます。

```powershell
winsmux launcher presets --json
winsmux launcher lifecycle --json
```

プリセットはワークスペースの構成を表します。自由形式のセットアップやクリーンアップスクリプトを実行する仕組みではありません。

## エージェントスロット

winsmux はベンダーごとに固定された役割ではなく、スロットと能力で構成を表します。スロットは、作業、レビュー、相談などの能力を示せます。どのペインに何を任せるかはオペレーターが決めます。

`winsmux init` は既定で 6 つの管理ワーカースロットを作ります。
`agent-slots` がある場合は、その一覧が正本です。`worker_count` は
一覧の件数から決まります。トップレベルの `worker-backend` は既定で
`local` です。各スロットでは、次の値で上書きできます。

- `local`: 現在のローカル管理ペイン
- `codex`: Codex レビュー用、またはワーカー用のメタデータ
- `colab_cli`: `google-colab-cli` ワーカー用の状態メタデータ
- `noop`: 無効化または仮置きのワーカー用メタデータ

`v0.32.1` では、Colab バックエンドの状態を `.winsmux/state/colab_sessions.json` に保存します。`google-colab-cli` の不在、認証を確認できない状態、GPU を使えない状態のいずれかが発生した場合は、ワーカーを `degraded` 状態として記録します。セッション名が変わった既存記録は `stale` として残します。GPU は設定された優先順序で選択を試み、使えない場合は最終的に CPU へ縮退します。ワーカーのライフサイクル操作と単発実行コマンドは、後続のリリースで扱います。

契約のみを記述したスロット設定の例（抜粋）です。`winsmux init` では 6 スロットが作成されます。

```yaml
external-operator: true
worker-backend: local
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: codex
    worker-role: reviewer
    fallback-model: gpt-5.4
    worktree-mode: managed
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: colab_cli
    worker-role: impl
    session-name: "{{project_slug}}_w2_impl"
    gpu-preference: [H100, A100, L4]
    packages: [torch, transformers, accelerate]
    bootstrap: workers/colab/bootstrap_impl.py
    task-script: workers/colab/impl_worker.py
    worktree-mode: managed
```

割り当て時は次の考え方を使います。

- 実装は作業を担当できるスロットに送る
- レビューはレビュー可能なスロットに送る
- 方針が固まらない作業だけ相談を使う

## 資格情報

ペインへ渡す必要がある資格情報は Windows DPAPI で保存します。

```powershell
winsmux vault set <name> <value>
winsmux vault inject <name> <pane>
```

winsmux は OAuth フローを代理実行しません。コールバック URL を受け取らず、同じ PC で対話的にログインして取得したトークンを別ペインへ共有しません。

## デスクトップ設定

デスクトップアプリは CLI と同じオペレーターの責任分界に従います。テーマ、表示密度、折り返し、コードフォント、集中モードなどの設定を表示できますが、生の PTY 出力は診断用の端末パネルに残します。

デスクトップアプリは次の用途に使います。

- 元の記録へ辿れる実行証跡と採否を決める判断ポイントを確認する
- 記録済みの作業を比較する
- ソースコード単位の詳細へ掘り下げる
- 端末診断を残しつつ、主画面を証跡中心に保つ
