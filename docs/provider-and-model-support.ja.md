# プロバイダーとモデルの対応方針

このページでは、winsmux が AI プロバイダー、モデル名、Google Colab ワーカー、
将来のローカル LLM ランタイムをどう扱うかを説明します。

winsmux はローカル優先の管制面です。エージェント CLI、ワーカースロット、
証跡収集を起動・監視します。winsmux 自体が LLM ランタイムになるわけではなく、
特定のプロバイダー、モデル、エンドポイントが常に使えることも約束しません。

最終確認日: 2026-06-10。

## 表記方針

公開ドキュメントでは、製品名を次のようにそろえます。

- `Claude Code`
- `Codex`
- `Antigravity CLI`
- `Gemini CLI`。従来環境からの移行を説明する場合だけ使います。

それらをどう実行するかを説明する時は、周辺文で「エージェント CLI」、
「公式 CLI」、「ローカルエンドポイント」と書きます。表の製品名列では上の製品名を使い、
CLI であることは認証方式や実行方式の列で説明します。

## 対応レベル

| 種別 | 現在の winsmux での扱い | 補足 |
| ----- | ----------------------- | ----- |
| 公式のクラウド型エージェント CLI | ペイン内エージェントとして対応 | サインインや API キー設定は、その CLI 自身が所有します。 |
| `local` ワーカーバックエンド | 対応 | この PC 上の通常の管理ペインとして動かします。 |
| `codex` ワーカーバックエンド | 現時点ではメタデータ | Codex 対応のワーカーまたはレビュースロットを表します。 |
| `antigravity` プロバイダーアダプター | 公式 CLI のペイン内エージェントとして対応 | ローカルの `agy` コマンドを使います。モデル選択は Antigravity CLI 側の設定が所有し、winsmux は証跡へ記録します。 |
| `colab_cli` ワーカーバックエンド | 状態確認、診断、単発実行、ログ、アップロード、ダウンロードに対応 | `google-colab-cli` 互換アダプターが必要です。H100 または A100 の Colab 実行を主な対象にします。 |
| `colab_llm` ワーカーバックエンド | Colab GPU モデルジョブのメタデータ、診断、単発実行、ログ、伏せ字済み証跡に対応 | アダプターが管理する Colab ランタイム上でモデルジョブを動かします。モデルキャッシュ、Hugging Face cache、大きな成果物は Colab に mount された Google Drive 配下に置き、Windows PC や Ollama cache には置きません。 |
| 主要なオープンモデルファミリー | タスクスクリプトとランタイムが用意している場合、Colab 上のモデル対象として対応 | 例は Gemma、Llama、Mistral、Qwen、DeepSeek、Kimi/Moonshot です。モデルファミリーはプロバイダーではなく、作業メタデータとして扱います。 |
| `local_llm` ワーカーバックエンド | 状態確認、診断、単発プロンプト実行、ローカルログに対応 | 初期ランタイムは `http://127.0.0.1:11434` の Ollama です。モデルキャッシュと大きな実行成果物は、通常 G ドライブの同期ルートなど、C ドライブ以外に置きます。 |
| `noop` ワーカーバックエンド | 仮置きスロットとして対応 | スロットを宣言したまま無効にできます。 |

## プロバイダー能力カタログ

`v0.33.0` から、`.winsmux/provider-capabilities.json` をエージェント CLI と
ローカルエンドポイント用アダプターの能力カタログとして扱います。このカタログでは、
起動方法、モデル情報、資格情報の境界を分けます。これにより、winsmux は
ローカル推論エンドポイントを誤って書き込み可能ワーカーとして扱いません。

プロバイダー定義では、次の項目を分けて宣言できます。

- `harness_availability`: 組み込み CLI、外部アダプター、手動ペインツールのどれか。
- `credential_requirements`: サインイン、API キー、エンドポイントの秘密情報、トークン保存を誰が所有するか。
- `execution_backend`: エージェント CLI、Colab ワーカー、OpenAI 互換ローカルエンドポイントなどの実行経路。
- `runtime_requirements`: エンドポイント、実行ファイル、GPU、CPU、メモリ、OS、リモートランタイムの要件。
- `model_catalog_source` と `model_options`: モデル名の取得元と、オペレーターが選べる候補。
- `analysis_posture`: 読み取り専用の分析に限るか、通常の書き込み可能ワーカーとして扱えるか。

OpenAI 互換ローカルエンドポイントや GPU 付きローカルランタイムの既定は、
読み取り専用の分析プロバイダーです。`supports_file_edit: false`、
`supports_verification: false`、`supports_consultation: true`、
`analysis_posture: "read-only"` と宣言します。ローカルランタイムは、
エンドポイント、モデル、資格情報を自分で所有します。winsmux は OAuth を仲介せず、
callback URL を受け取らず、プロバイダートークンをペイン間でコピーしません。
組み込みの `ollama` 能力もこの方針に従い、`local_llm` ワーカーバックエンドから使います。

Colab GPU のモデルジョブでは、組み込みの `colab_llm` 能力も同じく読み取り専用を既定にします。Google サインイン、Colab ランタイム、ノートブック所有者、Drive mount は、アダプターとブラウザーセッションが所有する private runtime state です。winsmux は伏せ字済みの状態と成果物参照だけを記録します。

## 実行プロファイル方針

`execution_profile` は実行方針のフィールドです。プロバイダー名でもワーカーバックエンドでもありません。既定値は `local-windows` で、既存のローカル管理ペイン動作を維持します。`isolated-enterprise` は企業向け隔離レーンを明示的に選ぶための値であり、プロバイダー、モデル、ロールから暗黙に選ばないでください。

Windows sandbox の土台も、この実行プロファイルの層に属します。`isolated-enterprise` の実行契約として、`restricted_token` を使う起動要件、実行単位の ACL 境界、準備済み隔離ワークスペースに対する安全側の検査を扱います。これはプロバイダー能力ではなく、`local-windows` のワーカーを sandbox 化するものでもありません。

これにより、次の3つの判断を分けます。

- ロールまたは playbook の意図: そのスロットが何のためにあり、どの証跡を返すか
- ワーカーバックエンド: ワーカースロットをどこに配置するか
- 実行プロファイル: どの実行方針と隔離レーンを適用するか

## モデル選択の方針

モデル名は winsmux のリリースより速く変わります。そのため winsmux は、モデルを
固定された製品ロールではなく、実行時メタデータとして扱います。

スロットや計画記録では、次の情報を持てます。

- `provider`
- `model_family`
- `model_id`
- `fallback_model_id`
- `runtime_engine`
- `precision`
- `quantization`
- `distillation_source`
- `license_state`
- 作業、レビュー、相談、ツール利用、コンテキスト長などの能力情報

run 証跡にモデル名とランタイム情報が出てくる場合、winsmux はそれを記録します。
ただし、そのモデルをそのタスクで使ってよいかを判断する責任はオペレーターに残ります。

## 現行の Colab モデル対象

現在の Colab モデル実行経路は Google Colab 上での実行を対象にしており、ローカル LLM 提供は対象外です。
モデル実行のアクセラレーター対象は次の通りです。

- 推奨: `H100`
- 許容: `A100`

他の GPU でも小さな検証には使える場合がありますが、このリリース列の標準対象ではありません。
設定された Colab ワーカーが `H100` または `A100` を確認できない場合、winsmux は状態を表示し、
続行するかどうかはオペレーターが判断します。

主要なオープンモデルファミリーは、タスクスクリプトが正確なモデル ID を読み込める場合に
Colab 上の作業対象として扱います。winsmux は選択された `model_family` と `model_id` を
記録しますが、特定ベンダーや特定リリース名専用のローダーを内蔵しません。

| モデルファミリー | Colab での扱い | アクセスとライセンスの注意 |
| ------------ | -------------------- | ------------------------ |
| Gemma | ノートブックが Google/Kaggle または Hugging Face 経路を準備している場合に対応。例は Gemma 4 31B、Gemma 4 26B A4B です。 | 初回利用前に、モデル配布元で Gemma の利用条件に同意してください。 |
| Llama | Meta Llama の重みにアクセスでき、選択した変種がランタイムに収まる場合に対応。例は Llama 4 Scout、Llama 4 Maverick です。 | Meta、Hugging Face、Kaggle、または公式パートナー経路で、ライセンスと利用ポリシーに同意してください。 |
| Mistral / Ministral / Devstral | 公式 Mistral 重み、または対応するクラウド/モデルハブ経路を使う場合に対応。Mistral、Ministral、Magistral、Devstral 系を含みます。 | モデルごとにライセンスが異なります。オープンな重みと制限付きライセンスの重みが混在します。 |
| Qwen | Transformers などの対応フレームワークで Qwen のオープン重みを使う場合に対応。例は Qwen3.6-27B と、その量子化または提供用の変種です。 | 正確なモデルカードとライセンスを確認してください。Qwen には通常構造と MoE の系列があります。 |
| DeepSeek | 公式 DeepSeek 重み、ホスト API 互換の対象、またはランタイムに収まる蒸留変種を使う場合に対応。例は DeepSeek V4 Pro、DeepSeek V4 Flash です。 | 正確なライセンスと、Llama や Qwen 由来の蒸留モデルでは元モデル側の条件も確認してください。 |
| Kimi / Moonshot | 公式のオープンウェイト、または承認済みのホストエンドポイントへアクセスできる場合に対応。例は Kimi K2.6 です。 | 公式配布元、モデルライセンス、ホスト API の条件を確認してください。 |
| その他の互換ファミリー | 信頼できる配布元、許可できるライセンス、`H100` / `A100` に収まるランタイム経路がある場合に対応 | コミュニティ名、マージ、量子化だけで承認済みとは扱いません。モデルカードとベースモデルの系譜を確認してください。 |

## 現行の Colab GPU LLM 対象

Colab Pro の GPU でオープンウェイト LLM を動かす場合は `colab_llm` を使います。これは次の2つとは別のバックエンドです。

- `colab_cli`: 汎用の Colab スクリプト実行
- `local_llm`: Ollama などの PC ローカルエンドポイント実行

初期のデスクトップ E2E では、標準で見えるスロットを使います。

- `worker-1`: Colab GPU model job A
- `worker-2`: Colab GPU model job B

2つのジョブは、同じアダプター管理の Colab ランタイムを対象にできます。選んだモデルを同時にロードできない場合は、同じランタイム内で逐次実行し、同じ GPU 条件として証跡に残します。CPU だけで動くローカル小型モデルへ置き換えないでください。

保存先の契約:

- 永続ルート: `/content/drive/MyDrive/winsmux-colab-llm/`
- モデルキャッシュ: `/content/drive/MyDrive/winsmux-colab-llm/models/`
- Hugging Face cache: `/content/drive/MyDrive/winsmux-colab-llm/hf-cache/`
- 大きな成果物: `/content/drive/MyDrive/winsmux-colab-llm/artifacts/`
- 一時 runtime cache: `/content/winsmux-runtime-cache/`

Colab 側のタスクスクリプトは、モデルを読み込む前に `HF_HOME`、`HF_HUB_CACHE`、`TRANSFORMERS_CACHE`、`XDG_CACHE_HOME` を Drive 上の cache root に向けます。Colab GPU E2E では、この Drive 配下だけがモデルダウンロード先です。Windows の Ollama cache や PC ローカルのモデルディレクトリへは pull しません。

スロット設定例:

```yaml
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: colab_llm
    worker-role: consult
    agent: colab-llm
    model-family: gemma
    model-id: <HF_MODEL_ID_A_27B_PLUS>
    runtime: colab
    runtime-engine: vllm
    gpu-preference: [H100, A100]
    session-name: "{{project_slug}}_colab_llm"
    drive-root: /content/drive/MyDrive/winsmux-colab-llm
    model-root: /content/drive/MyDrive/winsmux-colab-llm/models
    hf-cache-root: /content/drive/MyDrive/winsmux-colab-llm/hf-cache
    artifact-root: /content/drive/MyDrive/winsmux-colab-llm/artifacts
    runtime-cache-root: /content/winsmux-runtime-cache
    precision: bfloat16
    license-state: accepted
    task-script: workers/colab/llm_worker.py
    worktree-mode: managed
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: colab_llm
    worker-role: consult
    agent: colab-llm
    model-family: qwen
    model-id: <HF_MODEL_ID_B_27B_PLUS>
    runtime: colab
    runtime-engine: vllm
    gpu-preference: [H100, A100]
    session-name: "{{project_slug}}_colab_llm"
    drive-root: /content/drive/MyDrive/winsmux-colab-llm
    model-root: /content/drive/MyDrive/winsmux-colab-llm/models
    hf-cache-root: /content/drive/MyDrive/winsmux-colab-llm/hf-cache
    artifact-root: /content/drive/MyDrive/winsmux-colab-llm/artifacts
    runtime-cache-root: /content/winsmux-runtime-cache
    precision: bfloat16
    license-state: not_required
    task-script: workers/colab/llm_worker.py
    worktree-mode: managed
```

確認コマンド:

```powershell
winsmux workers doctor --json
winsmux workers status --json
winsmux workers exec worker-1 --prompt "このリポジトリの状態を要約してください。" --run-id colab-llm-smoke-1 --json
winsmux workers logs worker-1 --run-id colab-llm-smoke-1 --json
```

## 現行のローカル LLM 対象

最初の第一級ローカル LLM バックエンドは、Ollama を使う `local_llm` です。
これは `colab_cli` とは別の実行経路です。winsmux は、ローカル実行に
Colab の劣化状態や fallback を使いません。ローカルモデルを Colab セッションとしても扱いません。

これは PC ローカル用の機能です。Colab Pro GPU 経由の実行経路ではなく、上記の Colab LLM 2-worker E2E では使いません。

初期 E2E モデルは次の2つです。

- `gemma3:1b`
- `qwen2.5-coder:1.5b`

保存先の契約は、通常のペイン実行より厳しく扱います。

- モデルを pull する前に、`OLLAMA_MODELS` を G ドライブ上の ASCII のみの
  モデルルートへ向けます。例は `G:\winsmux-local-llm\ollama-models` または
  `<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\ollama-models` です。Windows 版 Ollama
  では、ローカライズされたフォルダー名など非 ASCII を含むモデルパスで
  `llama-server` が model blob を読み込めないことがあります。
- 各ローカル LLM スロットの `artifact-root`、または
  `WINSMUX_LOCAL_LLM_ARTIFACT_ROOT` を G ドライブ上の成果物ルートへ向けます。
  例は `<G_DRIVE_SYNC_ROOT>\winsmux-local-llm\artifacts` です。
- `.winsmux/worker-runs` には、軽量な `run.json`、伏せ字済みの
  `stdout.log`、共有可能な参照だけを置きます。
- 公開ドキュメント、レポート、リリースノートには、非公開の Google Drive URL や
  ユーザー固有の絶対パスを書きません。

スロット設定例:

```yaml
agent-slots:
  - slot-id: worker-3
    runtime-role: worker
    worker-backend: local_llm
    worker-role: consult
    agent: ollama
    model-id: gemma3:1b
    runtime: ollama
    endpoint: http://127.0.0.1:11434
    artifact-root: <G_DRIVE_SYNC_ROOT>\winsmux-local-llm\artifacts
    worktree-mode: managed
  - slot-id: worker-4
    runtime-role: worker
    worker-backend: local_llm
    worker-role: consult
    agent: ollama
    model-id: qwen2.5-coder:1.5b
    runtime: ollama
    endpoint: http://127.0.0.1:11434
    artifact-root: <G_DRIVE_SYNC_ROOT>\winsmux-local-llm\artifacts
    worktree-mode: managed
```

オペレーターは次のコマンドで確認できます。

```powershell
winsmux workers doctor --json
winsmux workers status --json
winsmux workers exec worker-3 --prompt "このリポジトリの状態を要約してください。" --run-id local-smoke-1 --json
winsmux workers logs worker-3 --run-id local-smoke-1 --json
```

実機で 2 worker の Ollama E2E を行う場合は、リポジトリ直下の
`.winsmux.yaml` を上書きせず、専用 runner を使います。

```powershell
pwsh scripts/test-local-llm-e2e.ps1 `
  -ModelRoot "<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\ollama-models" `
  -ArtifactRoot "<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\artifacts" `
  -CreateRoots `
  -PullModels
```

Ollama がインストール済みでも `PATH` にない場合は、実行ファイルを明示します。

```powershell
pwsh scripts/test-local-llm-e2e.ps1 `
  -ModelRoot "<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\ollama-models" `
  -ArtifactRoot "<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\artifacts" `
  -OllamaPath "<OLLAMA_INSTALL_DIR>\ollama.exe" `
  -PullModels
```

ディレクトリ作成、モデル pull、証跡書き込みを行わずに準備状態だけ確認する場合は、
preflight だけを実行します。

```powershell
pwsh scripts/test-local-llm-e2e.ps1 `
  -ModelRoot "<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\ollama-models" `
  -ArtifactRoot "<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\artifacts" `
  -PreflightOnly
```

この runner は `.winsmux/local-llm-e2e/<run-id>/` に隔離したプロジェクトを作り、
そのプロセス内だけで `OLLAMA_MODELS` を設定します。`worker-3` と `worker-4`
を並行実行し、リポジトリには軽量な証跡だけを残します。大きな
request/response artifact は、指定した G ドライブ上の artifact root に保存します。
Ollama のインストール、永続的な環境変数変更、グローバルな Ollama service 起動は行いません。

Windows の Ollama は、Ollama アプリ起動時のユーザー環境変数とシステム環境変数を
継承します。Ollama が C ドライブのモデルルートを見た状態ですでに起動している場合、
runner のプロセス内だけで `OLLAMA_MODELS` を設定しても不十分です。Ollama を終了し、
`OLLAMA_MODELS` を G ドライブのモデルルートへ永続設定してから Ollama を起動し直し、
その後にモデルを pull してください。runner は、対象モデルの Ollama manifest が
G ドライブ上の `ModelRoot` に存在することも確認します。
`ModelRoot` に非 ASCII 文字が含まれる場合は preflight で失敗させます。
この状態では `ollama list` は通っても、`llama-server` が model blob を開く段階で
失敗することがあります。
Google Drive のローカル表示名そのものが非 ASCII の場合は、セッション用に
ASCII のドライブ文字を割り当ててから Ollama へ渡します。

```powershell
subst W: "<G_DRIVE_LOCALIZED_MY_DRIVE>"
pwsh scripts/test-local-llm-e2e.ps1 `
  -ModelRoot "W:\winsmux-local-llm\ollama-models" `
  -ArtifactRoot "W:\winsmux-local-llm\artifacts" `
  -OllamaPath "<OLLAMA_INSTALL_DIR>\ollama.exe" `
  -PullModels
```

実体は G ドライブ上に残ります。`winsmux workers doctor` と E2E runner は、
`subst` 先が `G:\` に戻る場合だけ、このドライブを G ドライブ保存先として扱います。

## 変種と蒸留モデルのメタデータ

対応表をすべてのモデル宣伝名に依存させません。新しい変種、量子化、マージ、
蒸留チェックポイントは、ドキュメント更新より速く増えます。

run 証跡では、次のような構造化メタデータを優先します。

```yaml
model_family: qwen
model_id: Qwen/Qwen3.6-27B
runtime_engine: vllm
precision: fp8
distillation_source: null
license_state: accepted
```

蒸留モデルや派生モデルでは、分かる範囲で派生先とベースモデルの系譜を記録します。

```yaml
model_family: deepseek
model_id: deepseek-ai/DeepSeek-R1-Distill-Qwen-32B
runtime_engine: transformers
precision: int4
distillation_source: Qwen/Qwen2.5-32B
license_state: accepted
```

この形なら、`Kimi K2.6`、`DeepSeek V4 Pro / Flash`、`Qwen3.6-27B`、
`Gemma 4 31B / 26B A4B`、`Llama 4 Scout / Maverick`、今後のモデルファミリーを、
新しいチェックポイントごとに CLI 契約を変えずに追跡できます。

タスクスクリプト側の責務は次の通りです。

- モデル読み込み前に、モデルアクセスを受け付け済みか確認する
- `torch`、`transformers`、`accelerate`、`vllm`、`sglang` など必要なパッケージを入れる
- 許可した配布元から正確なモデル ID を解決する
- 量子化や精度を選ぶ
- 派生モデルや蒸留モデルでは、分かる範囲でモデルの系譜を記録する
- 正確なモデル変種が `H100` / `A100` ランタイムに収まるか確認する

## ローカル LLM ランタイムの現状

ローカルモデルまわりは変化が速い領域です。Ollama は現在の第一級
`local_llm` ランタイムです。次の表の他のランタイムは、将来のアダプターと
ドキュメント整備のための計画参考情報です。この表は `colab_cli` の動作要件ではありません。

| ランタイム | Windows での位置づけ | winsmux での実用上の扱い |
| ------- | --------------- | -------------------------- |
| LM Studio | Windows x64 と ARM に対応しています。公式ドキュメントでは 16 GB RAM と 4 GB 以上の専用 VRAM が推奨されています。OpenAI 互換 API と Anthropic 互換 API でローカルモデルを提供できます。 | 将来のローカルエンドポイント用アダプター候補です。現時点でも手動のローカルモデル検証に向きます。 |
| Ollama | Windows ネイティブアプリです。公式ドキュメントでは Windows 10 22H2 以降、NVIDIA では 452.39 以降のドライバー、AMD Radeon では現在の Radeon ドライバーが要件です。ローカル API は `http://localhost:11434` で提供されます。 | 現在の第一級 `local_llm` ランタイムです。初期 E2E モデルは `gemma3:1b` と `qwen2.5-coder:1.5b` です。 |
| llama.cpp | GGUF モデル向けのクロスプラットフォーム実行エンジンです。CUDA、HIP、Vulkan、SYCL、OpenVINO、Metal、CPU BLAS などのバックエンドがあります。 | 低レベルの実行エンジンです。直接使う場合も、別ツールに同梱された形で使う場合もあります。 |
| vLLM | サーバー向けランタイムです。現在の公式ドキュメントは対応 OS を Linux とし、Windows はネイティブ対応外で、WSL または Linux サーバーの利用を案内しています。 | 高スループット推論向けの WSL またはリモートエンドポイント候補です。Windows ネイティブの既定依存にはしません。 |
| ONNX Runtime GenAI と Windows ML | ONNX 形式の生成モデルを Windows 上で動かす経路です。Windows ML の GenAI ライブラリは 0.x のプレビューとして説明されています。 | 将来のネイティブアプリ統合候補ですが、安定した既定バックエンドにはまだしません。 |

## ローカル実行時の実用要件

次は計画時の目安であり、動作保証ではありません。必要な容量は、モデルサイズ、
量子化、コンテキスト長、ツール利用、ランタイムによって変わります。

| マシン構成 | 向いている用途 | 補足 |
| ------------- | ---------- | ----- |
| CPU のみ、16 GB RAM の Windows PC | 小さな量子化モデル、疎通確認、オフラインデモ | 速度は控えめです。コンテキスト長も小さめにします。 |
| 8 から 12 GB VRAM と 32 GB RAM の Windows PC | 7B/8B クラスの量子化モデル、軽いコーディング補助、ローカルレビューの試行 | 個人向けでは最も現実的な層です。 |
| 16 から 24 GB VRAM と 64 GB RAM の Windows PC | より大きな量子化モデル、長めのコンテキスト実験 | それでもランタイムごとの確認が必要です。モデルカードとメモリ見積もりを確認してください。 |
| データセンター GPU を持つ WSL/Linux サーバー | vLLM 型の提供、高スループット、複数ユーザー用途 | Windows ネイティブのペインではなく、WSL またはリモートエンドポイントとして扱います。 |
| H100 または A100 の Colab / Colab Enterprise ランタイム | ローカル VRAM を使わない GPU 付き単発ワーカー実行 | `colab_llm` モデルジョブの現行対象です。可用性、割り当て、IAM、ランタイム起動は Google/Colab 側の責務です。 |

## セキュリティとプライバシー

ローカル実行だから安全、とは限りません。

- モデルは信頼できる配布元から取得し、ライセンスを確認してください。
- モデルファイルとプロンプトログはデータ資産として扱ってください。
- 意図して公開する場合を除き、推論サーバーは `127.0.0.1` に束縛してください。
- API キーや OAuth トークンをモデルへのプロンプトに入れないでください。
- winsmux に OAuth の callback URL を受け取らせたり、他ツールのトークンを抽出させたりしないでください。
- ペインへ渡す必要がある資格情報だけを `winsmux vault` で扱ってください。

## 将来のローカル LLM アダプター要件

将来のローカル LLM アダプターは、少なくとも次を報告できる必要があります。

- ランタイムの状態
- 設定されたエンドポイントまたは実行ファイルの場所
- 選択中のモデル ID
- コンテキスト長、または不明であること
- ツール利用への対応状態
- 認証方式
- 秘密情報をそのまま保存しないリクエスト/レスポンス証跡の場所

これらを報告できないローカルランタイムは、第一級のワーカーバックエンドではなく、
手動で使うペイン内ツールとして扱います。

## 参照元

- [LM Studio system requirements](https://www.lmstudio.ai/docs/app/system-requirements)
- [LM Studio API docs](https://lmstudio.ai/docs/api)
- [LM Studio offline operation](https://www.lmstudio.ai/docs/app/offline)
- [Ollama for Windows](https://docs.ollama.com/windows)
- [llama.cpp README](https://github.com/ggml-org/llama.cpp/blob/master/README.md)
- [vLLM GPU installation](https://docs.vllm.ai/getting_started/installation/gpu.html)
- [Windows ML ONNX Runtime GenAI preview](https://learn.microsoft.com/en-us/windows/ai/new-windows-ml/run-genai-onnx-models)
- [Gemma get started](https://ai.google.dev/gemma/docs/get_started)
- [Gemma setup](https://ai.google.dev/gemma/docs/setup)
- [Gemma and LangChain Colab guide](https://ai.google.dev/gemma/docs/integrations/langchain)
- [Gemma 4 31B model card](https://huggingface.co/google/gemma-4-31B)
- [Gemma 4 26B A4B model card](https://huggingface.co/google/gemma-4-26B-A4B-it)
- [Llama 4 official overview](https://about.fb.com/ja/news/2025/04/llama-4-multimodal-intelligence/)
- [Mistral model overview](https://docs.mistral.ai/models/overview)
- [Qwen3.6-27B model card](https://huggingface.co/Qwen/Qwen3.6-27B)
- [DeepSeek V4 preview release](https://api-docs.deepseek.com/news/news260424)
- [DeepSeek API quick start](https://api-docs.deepseek.com/)
- [Kimi K2.6 model overview](https://www.kimi.com/ai-models/kimi-k2-6)
