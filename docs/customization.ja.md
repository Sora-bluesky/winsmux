# カスタマイズ

カスタマイズは、winsmux をローカルの運用に合わせるためのものです。共有資格情報の仲介役にするものではありません。

## ワークスペース方針

`winsmux init` の既定値は、ワーカーごとの管理ワークツリーです。

```powershell
winsmux init --workspace-lifecycle managed-worktree
```

複数のエージェントが並列で編集する場合は、管理ワークツリーを使ってください。オペレーターがどの変更を取り込むか判断するまで、変更を分離した状態で保持できます。

## 実行プロファイル

`execution-profile` は実行方針のレーンを表します。ワーカースロットの配置先を表す `worker-backend` や、プロバイダー能力の実行経路を表す `execution_backend` とは別の契約です。

既定値は `local-windows` です。これは通常の Windows 管理ペイン動作を維持します。`isolated-enterprise` は明示的に選んだ場合だけ使います。隔離ワークスペース、資格情報、生存確認、Windows sandbox の土台、ブローカー実行の土台は、このプロファイルにだけ接続します。公開時の既定動作にはしません。

### 実行単位の秘密情報投影

`local-windows` と `isolated-enterprise` のワーカー実行では、同じ型付き秘密情報投影の契約を使います。コマンドは実行開始時に Windows DPAPI の保管庫エントリーを解決し、値はその実行のローカル秘密情報ディレクトリにだけ保存します。

```powershell
winsmux workers secrets project w2 --run-id run-123 --env OPENAI_API_KEY=openai --file creds/token.txt=github --variable model_token=anthropic --json
```

投影の種類は明示的です。

- `--env <name=vault-key>` は、その実行用の PowerShell 環境読み込みファイルを書き込みます。
- `--file <path=vault-key>` は、実行内の秘密情報ファイルを書き込みます。
- `--variable <name=vault-key>` は、実行内の変数マップを書き込みます。

JSON 出力と `secret-projection.json` には、型付きの保存場所、保管庫キー名、スコープ、値への参照だけを記録します。秘密情報の値は含めません。隔離実行では、先に隔離ワークスペースを準備しておく必要があります。これにより、秘密情報ディレクトリがその実行境界の内側に残り、ワークスペースのクリーンアップで削除されます。

### ワーカーの生存確認とオフライン判定

`workers heartbeat` で、ローカルまたは隔離ワーカー実行の生存状態を記録できます。

```powershell
winsmux workers heartbeat mark w2 --run-id run-123 --state running --json
winsmux workers heartbeat check w2 --run-id run-123 --json
```

共有する状態は、`running`、`blocked`、`approval_waiting`、`child_wait`、
`stalled`、`completed`、`resumable` です。`blocked` と
`approval_waiting` は、オペレーターの対応待ちを表します。`child_wait`
は、ワーカーが子実行の完了を待っている状態です。停止したプロセスとして扱ってはいけません。
直近の `running` は正常、猶予時間を過ぎた heartbeat は `stalled`、
期限を超えた heartbeat は `offline` になります。

heartbeat の成果物は、実行境界の内側に `heartbeat.json` として保存します。

- `local-windows`: `.winsmux/worker-runs/<slot>/<run>/heartbeat.json`
- `isolated-enterprise`: `.winsmux/isolated-workspaces/<slot>/<run>/heartbeat.json`

`winsmux workers status --json` は、デスクトップアプリと同じ
`heartbeat`、`heartbeat_health`、`heartbeat_state` を返します。CLI と
Tauri の画面は、同じワーカー生存確認契約を読みます。

### Windows sandbox の土台

`isolated-enterprise` の実行では、隔離ワークスペースを作成した後に
Windows native sandbox の土台を定義できます。

```powershell
winsmux workers sandbox baseline w2 --run-id run-123 --json
```

この土台は、実行単位で次の2つの契約を組み合わせます。

- 後続のワーカー起動が `restricted_token` を使うこと
- `.winsmux/isolated-workspaces/<slot>/<run>` を根にした
  `run_acl_boundary` のファイル境界を使うこと

コマンドは安全側で失敗します。スロットが `isolated-enterprise` ではない場合、実行ワークスペースが未作成の場合、必要な実行ディレクトリがない場合、または実行境界の内側にリパースポイントがある場合は、`sandbox-baseline.json` を書きません。出力にはプロジェクト相対の成果物参照だけを含めます。

これは土台の契約であり、すでに動いているワーカーが安全に隔離されているという主張ではありません。JSON 出力の `isolation_claim.secure` は、起動経路が `restricted_token` と ACL 境界を実際に適用するまで `false` のままです。このレーンに `local-windows` 実行を使わないでください。

### ブローカー実行の土台

`isolated-enterprise` の実行では、隔離ワークスペースを作成した後に、最初のブローカー実行契約も定義できます。

```powershell
winsmux workers broker baseline w2 --run-id run-123 --endpoint https://broker.example.invalid/worker --json
```

この土台は、準備済みの実行に単一の外部ブローカーノードを記録します。プロセスを起動せず、ネットワーク接続も開かず、winsmux を資格情報の仲介役にしません。エンドポイント URL は `http` または `https` だけを許可し、埋め込み資格情報を含めてはいけません。

コマンドは安全側で失敗します。スロットが `isolated-enterprise` ではない場合、実行ワークスペースが未作成の場合、必要な実行ディレクトリがない場合、エンドポイントを安全に記録できない場合、または実行境界の内側にリパースポイントがある場合は、`broker-baseline.json` を書きません。出力にはプロジェクト相対の成果物参照だけを含めます。`winsmux workers status --json` は、各ワーカー行の `broker` に最新のブローカー契約を含めます。

ブローカー契約を作成した後は、ブローカー対応エージェント向けの短命実行トークンを発行できます。

```powershell
winsmux workers broker token issue w2 --run-id run-123 --ttl-seconds 900 --json
winsmux workers broker token check w2 --run-id run-123 --json
```

トークン値は、隔離実行境界の内側にある `secrets/broker-run-token.txt` にだけ保存します。JSON 出力と `broker-token.json` には、トークン参照、指紋、発行時刻、期限だけを記録します。期限切れの確認では、既定でトークンを更新します。更新を無効化した場合、または更新できない場合は、`winsmux workers heartbeat` と同じ生存確認面で実行を `offline` にします。

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

`v0.32.4` 以降では、Colab バックエンドの状態を
`.winsmux/state/colab_sessions.json` に保存します。`google-colab-cli` の
不在、認証を確認できない状態、`H100` / `A100` GPU を使えない状態のいずれかが発生した場合は、
ワーカーを `degraded` 状態として記録します。セッション名が変わった既存記録は
`stale` として残します。Colab のモデル作業では、ローカル CPU やローカル LLM
ランタイムへ黙って切り替えません。

`winsmux workers status`、`winsmux workers attach`、`winsmux workers start`、
`winsmux workers stop`、`winsmux workers doctor` で、6 つの設定済みワーカースロットを
確認、デスクトップ表示へ準備、起動、停止、診断できます。

Colab 対応スロットでは、ファイルを指定した単発実行と成果物の受け渡しも使えます。

```powershell
winsmux workers exec w2 --script workers/colab/impl_worker.py --run-id demo-1 -- --task-json-inline '{"task_id":"demo-1","title":"この変更を実装する"}' --worker-id worker-2 --run-id demo-1
winsmux workers logs w2 --run-id <run_id>
winsmux workers upload w2 data/input.json --remote /content/input.json
winsmux workers upload w2 data --remote /content/data --allow-dir data
winsmux workers download w2 /content/output.json --output artifacts/worker-output
```

`workers/colab/` には次の追跡済みテンプレートがあります。

- `impl_worker.py`
- `critic_worker.py`
- `scout_worker.py`
- `test_worker.py`
- `heavy_judge_worker.py`

各テンプレートは `--task-json`、`--task-json-inline`、または
`WINSMUX_TASK_JSON` からタスク JSON を受け取ります。既定では
`/content/winsmux_artifacts/<worker_id>/<run_id>/` にロール別の成果物を書き込み、
構造化 JSON を出力します。リモート成果物と winsmux 側の実行メタデータを揃えるため、
スクリプト引数の区切りの後にも同じ `--run-id` を渡してください。入力が不正な場合は
非ゼロで終了し、`status: failed` と `errors` 配列を返します。

ディレクトリをアップロードする場合は `--allow-dir` が必要です。アップロード用の
manifest では、`.git`、秘密情報らしいファイル、`node_modules`、仮想環境、
ビルド成果物、coverage、サイズが大きすぎるファイルを既定で除外します。
`colab repl` や `colab console` のような自動対話ループは対象外です。設定された
`google-colab-cli` 互換 adapter に対して、1 回ずつコマンドを実行します。

Colab ワーカーコマンドは、秘密情報らしい値や禁止された自動化パターンを含む
タスク入力を、アダプター呼び出し前に拒否します。保存するアダプター出力と
`cli_arguments` メタデータでは、秘密情報らしい値、Google Drive パス、
ローカル絶対パスを伏せ字にします。これにより、レビューパックとリリースゲートの
証跡を共有しやすくします。

ワーカーの結果を Codex レビュースロットへ渡す前に、
`winsmux review-pack <run_id> --json` を使います。このコマンドは
`.winsmux/review-packs` に、変更ファイル、テスト結果、レビュー上の懸念、
残っているリスク、実行コマンド、成果物参照だけを含む小さなパケットを書き出します。
リポジトリ全体のダンプ、長いログ、秘密情報、バイナリ成果物、外部依存ディレクトリ、
ローカル絶対パス、会話履歴全体は含めません。

契約のみを記述したスロット設定の例（抜粋）です。`winsmux init` では 6 スロットが作成されます。

```yaml
external-operator: true
worker-backend: local
execution-profile: local-windows
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: provider-default
    model-source: provider-default
    worker-backend: codex
    execution-profile: local-windows
    worker-role: reviewer
    fallback-model: gpt-5.3-codex-spark
    pane-title: W1 Codex Reviewer
    worktree-mode: managed
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: colab_cli
    execution-profile: isolated-enterprise
    worker-role: impl
    session-name: "{{project_slug}}_w2_impl"
    gpu-preference: [H100, A100]
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

実行単位のワーカーでは、`winsmux workers secrets project` を使ってください。資格情報をペイン全体へ広く注入するのではなく、1 つのスロットと 1 つの実行に紐づけられます。

winsmux は OAuth フローを代理実行しません。コールバック URL を受け取らず、同じ PC で対話的にログインして取得したトークンを別ペインへ共有しません。

## デスクトップ設定

デスクトップアプリは CLI と同じオペレーターの責任分界に従います。テーマ、表示密度、折り返し、コードフォント、集中モードなどの設定を表示できますが、生の PTY 出力は診断用の端末パネルに残します。

デスクトップアプリは次の用途に使います。

- 元の記録へ辿れる実行証跡と採否を決める判断ポイントを確認する
- 記録済みの作業を比較する
- ソースコード単位の詳細へ掘り下げる
- 端末診断を残しつつ、主画面を証跡中心に保つ
