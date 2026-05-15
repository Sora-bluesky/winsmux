# Google Colab ワーカー

このページでは、Colab 対応の winsmux ワーカーを準備する方法を説明します。

`v0.32.x` の Colab 対応では、winsmux は `google-colab-cli` 互換アダプターを通じて、
次の単発ワーカー操作を実行できます。

- `winsmux workers exec`
- `winsmux workers logs`
- `winsmux workers upload`
- `winsmux workers download`
- `winsmux workers attach`

winsmux は Google のサインインを代行しません。認証、ランタイム作成、GPU の可用性、
クォータ、ブラウザーでのサインインは、Colab 側またはアダプター側の責務です。

## ノートブックとランタイムの要件

はい。Colab ノートブック、またはアダプターが管理する同等のノートブック/ランタイムが必要です。

Colab は、ランタイムへ接続したノートブックのコードを実行します。winsmux で
`workers exec` を使う前に、次のいずれかを準備してください。

- `H100` ランタイムへ接続済みの Colab ノートブック
- `A100` ランタイムへ接続済みの Colab ノートブック
- スクリプト実行前にノートブックを作成または選択し、`H100` または `A100`
  ランタイムへ接続する `google-colab-cli` 互換アダプター

winsmux は Google 側のノートブックリソースを直接作成しません。設定された
アダプターを呼び出し、ローカルの証跡を記録します。

## 必要なもの

ローカル側で必要なものは次の通りです。

- Windows 10 または Windows 11
- PowerShell 7+
- `full` または `orchestra` プロファイルで入れた winsmux
- `winsmux init` 済みのプロジェクト
- 準備済みの Colab ノートブック/ランタイム、またはそれらを管理するアダプター
- `google-colab-cli` という名前で実行できるアダプター、または互換アダプターを指す `WINSMUX_COLAB_CLI`
- アダプターやブートストラップで必要な場合は `uv`
- アダプターが必要とするネットワーク接続とブラウザーセッション

Google 側の要件は、使う Colab の種類によって変わります。

- 個人向け Colab では、ノートブックまたはランタイムを所有する Google アカウントでサインインします。
- Colab Enterprise では、Google Cloud プロジェクトと、ランタイム接続または作成に必要な IAM ロールが必要です。
- 想定アクセラレーターは `H100` です。`A100` を許容する代替候補にします。
- GPU が常に使えるとは限りません。winsmux は GPU を確認できない状態や、GPU が想定と違う状態を、縮退したワーカー状態として表示します。

モデル作業では、Google Colab 上でコードを実行することを前提にします。
Windows PC 側にローカル LLM ランタイムを用意する必要はありません。

## アダプター契約

winsmux は、次の操作を持つ `google-colab-cli` 互換コマンドを想定します。

```powershell
google-colab-cli run --session <name> --script <path> --run-id <id> --output-dir <path>
google-colab-cli logs --session <name> --run-id <id>
google-colab-cli upload --session <name> --source <path> --dest <remote-path> --manifest <path> --run-id <id>
google-colab-cli download --session <name> --source <remote-path> --dest <path> --run-id <id>
```

この契約では、`--session <name>` がアダプター管理下の Colab ノートブック/ランタイム
セッションを指します。その名前を実際のノートブックとランタイムへ対応づける責任は
アダプター側にあります。

アダプター側が `new`、`status`、`exec`、`log`、`stop` のような別の操作名を
持つ場合は、上の仕様に合わせる薄いラッパーを用意してください。`exec` は `run`、
`log` は `logs` に対応します。アダプター側の `new`、`status`、`stop` は
手動のランタイム確認では有用ですが、winsmux のワーカー状態、`attach`、`stop` は
ローカル側で完結する制御コマンドとして扱います。

アダプターの実行ファイル名が異なる場合は、次を設定します。

```powershell
$env:WINSMUX_COLAB_CLI = "C:\path\to\your-adapter.exe"
```

その後、確認します。

```powershell
winsmux workers doctor
```

## Colab スロットを設定する

`winsmux init` は既定で 6 つのワーカースロットを作ります。1 つのスロットを
Colab 対応にするには、そのスロットに `worker-backend: colab_cli` を設定します。

```yaml
agent: codex
model: provider-default
worker-backend: local
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: colab_cli
    worker-role: impl
    session-name: "{{project_slug}}_w2_impl"
    gpu-preference: [H100, A100]
    packages: [torch, transformers, accelerate]
    bootstrap: workers/colab/bootstrap_impl.py
    task-script: workers/colab/impl_worker.py
    worktree-mode: managed
```

次を実行します。

```powershell
winsmux workers status
winsmux workers attach w2
winsmux workers doctor
```

対象スロットの `backend` が `colab_cli` として表示されます。アダプター、認証、
必要な `H100` / `A100` GPU を確認できない場合もスロットは表示されますが、
縮退状態として扱います。

## モデルファミリー

Colab ワーカーは、特定モデルファミリーに固定しません。winsmux は意図したモデルを
メタデータとして記録し、正確なチェックポイントまたは API 対象の読み込みは
タスクスクリプトに任せます。

アクセラレーター対象は `H100` です。`A100` を許容する代替候補にします。
大きな通常構造のモデル、MoE、マルチモーダル、長文コンテキストのモデルでは、
それでも量子化、短めのコンテキスト設定、テンソル並列、またはホスト API 対象が
必要になる場合があります。

メタデータは、次のような対象を表せる必要があります。

| ファミリー | 例 | 注意 |
| ------ | --------------- | ----- |
| Gemma | Gemma 4 31B、Gemma 4 26B A4B | 初回利用前に Google/Kaggle または Hugging Face の利用条件へ同意します。 |
| Llama | Llama 4 Scout、Llama 4 Maverick | 公式経路で Meta のライセンスと利用ポリシーへ同意します。 |
| Mistral | Mistral、Ministral、Magistral、Devstral 系 | 正確なモデルライセンスを確認します。Mistral にはオープンな重みと制限付きライセンスの重みがあります。 |
| Qwen | Qwen3.6-27B と、その量子化または提供用の変種 | モデルカードを確認し、正確なアーキテクチャに対応するフレームワークを使います。 |
| DeepSeek | DeepSeek V4 Pro、DeepSeek V4 Flash、蒸留変種 | 正確なモデル ID または API ID と、蒸留モデルではベースモデルのライセンスも確認します。 |
| Kimi / Moonshot | Kimi K2.6 | 公式のオープンウェイト、またはホストエンドポイントの条件を確認します。 |

モデルタスクを実行する前に、次を確認してください。

1. 公式配布元で、必要なモデル利用条件に同意します。
2. Colab ランタイムが `H100` または `A100` であることを確認します。
3. `torch`、`transformers`、`accelerate`、`vllm`、`sglang` など、スクリプトが必要とするパッケージだけを入れます。
4. 精度と量子化を明示的に選びます。
5. 蒸留モデルや派生モデルでは、分かる範囲でモデルの系譜を記録します。
6. モデルキャッシュと大きな出力は、Colab、Google Drive、Cloud Storage、または明示した成果物置き場に置きます。ローカルの秘密情報を `winsmux workers upload` で送らないでください。

スロットのメタデータには、意図したモデルファミリーと正確な対象を記録できます。

```yaml
    model_family: qwen
    model_id: Qwen/Qwen3.6-27B
    runtime_engine: vllm
    precision: fp8
    gpu-preference: [H100, A100]
```

winsmux はこれを実行時メタデータとして記録します。正確なモデル、API 対象、量子化、
蒸留チェックポイントを読み込む責任は、タスクスクリプト側に残ります。

## タスクを実行する

リポジトリには `workers/colab/` 配下の薄いテンプレートが含まれています。

- `impl_worker.py`
- `critic_worker.py`
- `scout_worker.py`
- `test_worker.py`
- `heavy_judge_worker.py`

各テンプレートは `--task-json`、`--task-json-inline`、または
`WINSMUX_TASK_JSON` からタスク JSON を受け取ります。標準出力へ構造化 JSON を返し、
既定では `/content/winsmux_artifacts/<worker_id>/<run_id>/` にロール別の成果物を書き込みます。
リモート成果物と winsmux 側の実行メタデータを揃えるため、スクリプト引数の区切りの後にも
同じ `--run-id` を渡してください。入力が不正な場合は非ゼロで終了し、
`status: failed` と `errors` 配列を返します。

実行します。

```powershell
$task = '{"task_id":"demo-1","title":"この変更を実装する","changed_files":["src/app.ts"],"verification_plan":["npm test"]}'
winsmux workers exec w2 --script workers/colab/impl_worker.py --run-id demo-1 --json -- --task-json-inline $task --worker-id worker-2 --run-id demo-1
winsmux workers logs w2 --run-id demo-1
```

winsmux はローカルのメタデータを次の場所へ保存します。

- `.winsmux/worker-runs/<slot-id>/<run-id>/run.json`
- `.winsmux/worker-runs/<slot-id>/<run-id>/stdout.log`

## 安全境界

Colab ワーカーコマンドは、アダプターを呼ぶ前にローカルで安全境界を適用します。
`workers exec` は、秘密情報らしい値を含むタスク入力や、マイニングツール、
プロキシトンネル、ネットワークスキャナー、ファイル配信サーバー、破壊的な
シェルコマンド、取得したスクリプトをそのままシェルへ渡すインストーラー、
無限ループ、資格情報のダンプに関わるツールを含む入力を拒否します。

winsmux は、アダプター出力、`stdout.log`、JSON の `cli_arguments` メタデータに
秘密情報らしい値、Google Drive パス、ローカル絶対パスを残さないよう伏せ字にします。
アダプターには実行に必要な実パスを渡しますが、winsmux 側の証跡はレビューパックや
リリースゲートに渡しやすい形で保存します。

## 成果物をアップロード、ダウンロードする

明示したファイルをアップロードします。

```powershell
winsmux workers upload w2 data/input.json --remote /content/input.json --run-id demo-1 --json
```

ディレクトリは、明示的に許可した時だけアップロードできます。

```powershell
winsmux workers upload w2 data --remote /content/data --allow-dir data --run-id demo-1 --json
```

出力をダウンロードします。

```powershell
winsmux workers download w2 /content/output.json --output artifacts/worker-output --run-id demo-1 --json
```

アップロードとダウンロードの JSON には、型付きの `locations` 記録が含まれます。これはローカルの入力または出力、リモート成果物パス、ローカルの manifest またはステージングディレクトリを分けて表します。記録にはプロジェクト相対の参照だけを保存し、端末上の絶対パスは公開しません。リモート成果物は `kind: remote_artifact` で、`local_path` を公開しません。永続化されるローカル記録でも `local_path` は空にし、共有される worker 証跡から操作者のプロジェクトパスが漏れないようにします。

ディレクトリアップロードでは、安全な manifest を使ってステージングします。
winsmux は次を除外します。

- `.git`、`.hg`、`.svn`
- `.winsmux`、`.orchestra-prompts`
- `node_modules`
- `.venv`、`venv`、`env` などの仮想環境
- `dist`、`build`、`target` などのビルド成果物
- coverage とツールキャッシュ
- `.env`、鍵、証明書、トークン、資格情報など、秘密情報らしいファイル
- 設定された最大アップロードサイズを超えるファイル

## 受け入れ確認

CI の受け入れ確認は、ソースから検証する場合の手順です。モック優先で、
実 Colab ランタイムは必要ありません。

```powershell
Invoke-Pester -Path tests/ColabAcceptance.Tests.ps1 -PassThru
```

このモック確認では、6 ワーカーの Colab 構成、`workers status`、`workers doctor`、
単発実行、ローカルログとアダプター経由ログ、ディレクトリアップロードの除外、
ダウンロード、attach の挙動を確認します。モックアダプターは `new`、`status`、
`stop` も受け付けるため、アダプター作者は Colab の実行リソースを使わずに
ライフサイクル管理のラッパーを確認できます。

インストール済み環境では、まずローカル側の診断を実行してください。

```powershell
winsmux workers doctor
```

ソースから実 Colab を使う確認は、手動でのみ実行します。動作する `colab_cli`
スロットを持つプロジェクトを指定してから、明示的に有効化してください。

```powershell
$env:WINSMUX_COLAB_ACCEPTANCE_REAL = "1"
$env:WINSMUX_COLAB_ACCEPTANCE_PROJECT = "C:\path\to\project"
Invoke-Pester -Path tests/ColabAcceptance.Tests.ps1 -PassThru
```

実タスクを動かす前に、Colab 側のクォータと停止方針を winsmux の外で確認してください。
ローカルワーカーペインを止める時は `winsmux workers stop <slot>` を使います。
リモートのノートブックやランタイムも止める必要がある場合は、アダプター側の
停止コマンドも使ってください。

## 制限

`v0.32.x` の Colab 対応は、対話型の Colab REPL や console ループを自動化しません。
設定されたアダプターを通じて、ファイルを指定したタスクを 1 回ずつ実行します。

大きな成果物は、アダプターが対応している場合、Google Drive、Cloud Storage、
または明示した保存先を使ってください。winsmux が記録するのは、ローカルの run
メタデータとアップロード/ダウンロードコマンドの証跡です。

## トラブルシューティング

| 症状 | 確認すること |
| ------- | ----- |
| `google-colab-cli not found on PATH` | アダプターをインストールするか、`WINSMUX_COLAB_CLI` を設定します。 |
| ノートブックを準備していない | Colab ノートブックを作成して `H100` または `A100` ランタイムへ接続するか、それを管理するアダプターを設定します。 |
| 認証がない、または認証状態が縮退している | Google またはアダプターが所有する公式フローでサインインします。winsmux は callback URL を受け取らず、トークンも抽出しません。 |
| GPU が `H100` または `A100` ではない | Colab 側のランタイム種別とクォータを確認し、その後 `winsmux workers doctor` を再実行します。 |
| モック受け入れ確認は通るが実ランタイムが失敗する | 実プロジェクトで `workers doctor` を再実行し、アダプターのサインインとランタイムのクォータを確認したうえで、`WINSMUX_COLAB_ACCEPTANCE_REAL=1` を設定して再実行してください。 |
| モデルのダウンロード、または API 対象の準備に失敗する | モデル利用条件への同意と、ランタイム内の Kaggle、Hugging Face、Google、各プロバイダーの資格情報を確認します。 |
| ディレクトリアップロードが拒否される | `--allow-dir <path>` を追加し、プロジェクト配下のディレクトリを指定します。 |
| 秘密情報らしいファイルが除外される | 意図した挙動です。秘密情報を含まないファイルを用意してください。 |
| アダプターが非ゼロ終了コードを返す | JSON、`stdout.log`、アダプター側ログを確認します。winsmux はアダプターの終了コードをそのまま返します。 |

## 参照元

- [Google Colab Enterprise runtime connection docs](https://cloud.google.com/colab/docs/connect-to-runtime)
- [Google Colaboratory GitHub organization](https://github.com/googlecolab)
- [Gemma setup](https://ai.google.dev/gemma/docs/setup)
- [Gemma and LangChain Colab guide](https://ai.google.dev/gemma/docs/integrations/langchain)
- [Gemma 4 31B model card](https://huggingface.co/google/gemma-4-31B)
- [Gemma 4 26B A4B model card](https://huggingface.co/google/gemma-4-26B-A4B-it)
- [Llama 4 official overview](https://about.fb.com/ja/news/2025/04/llama-4-multimodal-intelligence/)
- [Mistral model overview](https://docs.mistral.ai/models/overview)
- [Qwen3.6-27B model card](https://huggingface.co/Qwen/Qwen3.6-27B)
- [DeepSeek V4 preview release](https://api-docs.deepseek.com/news/news260424)
- [Kimi K2.6 model overview](https://www.kimi.com/ai-models/kimi-k2-6)
