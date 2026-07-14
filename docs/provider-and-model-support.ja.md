# プロバイダーとモデルの対応方針

このページでは、winsmux が AI プロバイダー、モデル名、外部モデルワーカー、
将来のローカル LLM ランタイムをどう扱うかを説明します。

winsmux はローカル優先の管制面です。エージェント CLI、ワーカースロット、
証跡収集を起動・監視します。winsmux 自体が LLM ランタイムになるわけではなく、
特定のプロバイダー、モデル、エンドポイントが常に使えることも約束しません。

最終確認日: 2026-07-02。

## 表記方針

公開ドキュメントでは、製品名を次のようにそろえます。

- `Claude Code`
- `Codex`
- `Antigravity CLI`
- `Gemini`

それらをどう実行するかを説明する時は、周辺文で「エージェント CLI」、
「公式 CLI」、「ローカルエンドポイント」と書きます。表の製品名列では上の製品名を使い、
CLI であることは認証方式や実行方式の列で説明します。

## 対応レベル

| 種別 | 現在の winsmux での扱い | 補足 |
| ----- | ----------------------- | ----- |
| 公式のクラウド型エージェント CLI | ペイン内エージェントとして対応 | サインインや API キー設定は、その CLI 自身が所有します。 |
| `local` ワーカーバックエンド | 対応 | この PC 上の通常の管理ペインとして動かします。 |
| `codex` ワーカーバックエンド | 現時点ではメタデータ | Codex 対応のワーカーまたはレビュースロットを表します。 |
| `api_llm` ワーカーバックエンド | OpenAI 互換の外部APIモデルワーカー用の契約として対応 | OpenRouter など、プロバイダー側が所有する API を使います。公開リポジトリでの標準導線は実行時の環境変数です。winsmux は伏せ字済みの実行メタデータだけを記録し、別のバックエンドへ黙って切り替えません。 |
| `antigravity` ワーカーバックエンド | Antigravity CLI の一回実行ワーカーとして対応 | ローカルの `agy` コマンドを print mode で使います。サインインとモデルアクセスは CLI 側が所有し、winsmux は伏せ字済みの実行メタデータだけを記録します。プロンプト本文はログに残しません。 |
| 主要なオープンモデルファミリー | プロバイダーとランタイムが提供する場合、外部または将来のローカル実行で対応 | 例は Gemma、Llama、Mistral、Qwen、DeepSeek、Kimi/Moonshot です。モデルファミリーはプロバイダーではなく、作業メタデータとして扱います。 |
| ローカル LLM ランタイム | 今後のアダプター候補 | 現時点では、通常のローカルツールとしてペインで動かすか、ローカルエンドポイントを使えるエージェント CLI 経由で使います。 |
| `noop` ワーカーバックエンド | 仮置きスロットとして対応 | スロットを宣言したまま無効にできます。 |

## プロバイダー能力カタログ

`v0.33.0` から、`.winsmux/provider-capabilities.json` をエージェント CLI と
ローカルエンドポイント用アダプターの能力カタログとして扱います。このカタログでは、
起動方法、モデル情報、資格情報の境界を分けます。これにより、winsmux は
ローカル推論エンドポイントを誤って書き込み可能ワーカーとして扱いません。

プロバイダー定義では、次の項目を分けて宣言できます。

- `harness_availability`: 組み込み CLI、外部アダプター、手動ペインツールのどれか。
- `credential_requirements`: サインイン、API キー、エンドポイントの秘密情報、トークン保存を誰が所有するか。
- `execution_backend`: エージェント CLI、外部 API ワーカー、OpenAI 互換ローカルエンドポイントなどの実行経路。
- `runtime_requirements`: エンドポイント、実行ファイル、GPU、CPU、メモリ、OS、リモートランタイムの要件。
- `model_catalog_source` と `model_options`: モデル名の取得元と、オペレーターが選べる候補。
- `api_base_url` と `api_key_env`: 外部APIモデルワーカーが使う OpenAI 互換エンドポイントと、API key の環境変数名。`openrouter` などの組み込み外部 provider では固定値として扱い、カスタム endpoint は localhost に限定します。
- `analysis_posture`: 読み取り専用の分析に限るか、通常の書き込み可能ワーカーとして扱えるか。

OpenAI 互換ローカルエンドポイントや GPU 付きローカルランタイムの既定は、
読み取り専用の分析プロバイダーです。`supports_file_edit: false`、
`supports_verification: false`、`supports_consultation: true`、
`analysis_posture: "read-only-analysis"` と宣言します。ローカルランタイムは、
エンドポイント、モデル、資格情報を自分で所有します。winsmux は OAuth を仲介せず、
callback URL を受け取らず、プロバイダートークンをペイン間でコピーしません。

## Antigravity CLI ワーカー

Google の公開移行案内では、Gemini CLI と Gemini Code Assist IDE 拡張は、
Gemini Code Assist for individuals、Google AI Pro、Google AI Ultra からの
リクエスト提供を 2026-06-18 に停止し、対象ユーザーは Antigravity CLI へ
移行するとされています。winsmux では、Google AI Standard と Enterprise は
この sunset 対象として扱いません。

ローカルの `agy` コマンドが使える場合、`antigravity` を一回実行ワーカーとして
使えます。

```yaml
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: antigravity
    agent: antigravity
    model: provider-default
    model-source: provider-default
    prompt-transport: file
    auth-mode: antigravity-official-cli
    worktree-mode: managed
```

`winsmux workers exec` はプロジェクトディレクトリ上で
`agy --print <file-reference-prompt> --print-timeout <duration>` を呼び出し、
スロットが明示モデルを持つ場合は `--model <model>` を付けます。CLI
プロセスへ渡すのは、現在の作業領域にある相対タスクファイルを読むための短い
指示だけです。タスクファイル本文は、プロセス引数、run JSON、ログ、PR 本文、
リリース証跡にはコピーしません。

`agy` が未導入、または print mode を公開していない場合、`winsmux workers doctor`
は Antigravity CLI の失敗として報告し、移行対象ワーカーは未設定のまま止まります。
winsmux は、これらのワーカーを consumer Gemini CLI 経路へ黙って戻しません。

## 外部APIモデルワーカー

`api_llm` は、OpenAI 互換の外部APIモデルを使うワーカーバックエンドです。
chat-completions 互換 API を提供するプロバイダーを対象にし、最初の契約は
OpenRouter を想定します。スロットでは次のように宣言できます。

```yaml
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: api_llm
    agent: openrouter
    model: z-ai/glm-5.2
    model-source: operator-override
    prompt-transport: file
    auth-mode: api-key-env
    worktree-mode: managed
```

OpenRouter 互換の既定 base URL は `https://openrouter.ai/api/v1` です。
環境変数で認証する場合、既定名は `OPENROUTER_API_KEY` です。
winsmux はこの値をリポジトリ、公開ドキュメント、PR 本文、
生成レポート、ワーカーログ、リリース証跡に保存しません。
公開リポジトリでの標準手順では、Windows のユーザー環境変数として保存し、
新しい PowerShell を開いてから `winsmux` を実行します。

```powershell
$secret = Read-Host -AsSecureString "OpenRouter API key"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
try {
  [Environment]::SetEnvironmentVariable(
    "OPENROUTER_API_KEY",
    [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr),
    "User"
  )
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  Remove-Variable secret -ErrorAction SilentlyContinue
}
```

反映確認では値を表示せず、設定済みかだけを確認します。

```powershell
if ([string]::IsNullOrWhiteSpace($env:OPENROUTER_API_KEY)) { "missing" } else { "configured" }
```

シェル起動ファイル、コマンド履歴、リポジトリ内の `.env`、公開ドキュメント、PR 本文、
生成レポート、ワーカーログ、リリース証跡へ値を書かないでください。

`api_llm` はローカルや CLI 管理のバックエンドと分けて扱います。
API key の環境変数がない場合や、プロバイダーのエンドポイント設定が不正な場合は、
通信前に `api_llm_api_key_env_missing` などの診断理由を返します。別の実行経路へ
黙って切り替えることはありません。

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

## ワーカーペインのモデル選択とベンチ比較

デスクトップの実行環境設定では、モデル候補を6種類に分けて表示します。

| 種別 | picker での扱い | ベンチ比較での扱い |
| ----- | --------------- | ------------------ |
| `selectable` | 互換性のある worker slot へ割り当てられます。実行できるかどうかは、最終的に slot の backend が判断します。 | winsmux-local の実行証跡がある場合に並べて表示します。 |
| `setup-required` | 通常の worker 経路はあるが設定が足りない状態です。たとえば OpenRouter は `api_llm` slot と実行環境の `OPENROUTER_API_KEY` が必要です。 | local run id、遅延、費用、失敗理由、再現性が記録されるまで採点から除外します。 |
| `runnable` | backend と認証状態が揃った互換 worker slot へ割り当てられます。 | winsmux-local の実行証跡がある場合に並べて表示します。 |
| `blocked` | provider、endpoint、またはローカル runner が現在の契約を満たせないため無効です。 | 理由付きの証跡として残し、採点から除外します。 |
| `reference-only` | 比較文脈として表示しますが、デスクトップ picker では選択できません。 | Agent Arena、Code Arena の参照値として表示できます。ただし winsmux がローカルで実行できるという意味にはしません。 |
| `unavailable` | 上流 provider が公式に復旧するまで無効です。 | 外部ベンチ行の説明用にだけ残します。 |

参照ベンチは補助情報です。`winsmux compare-runs` の勝敗判断は、ローカル実行証跡、
レビュー結果、変更ファイル、再現性、オペレーターの判断履歴をもとに行います。

Claude Code、Codex、Antigravity CLI の worker 比較では、
[CLI comparison bakeoff](cli-comparison-bakeoff.md) の task pack と preflight gate を使います。
公開可能なデスクトップ録画証跡がない run は運用証跡として残しますが、
既定の worker 割り当てを変える根拠にはしません。

`Claude Fable 5` は再び `selectable` として扱います。Anthropic は、Fable 5 が
2026-07-01 から Claude Platform、Claude.ai、Claude Code、Claude Cowork で
復旧したと案内しています。Pro、Max、Team、一部 Enterprise では、2026-07-07
までは週次利用枠の最大 50% まで Fable 5 が含まれます。それ以降は usage credits
の消費対象です。

winsmux は、ローカルの Claude Code アカウントに Fable 5 が表示される場合、
Claude Code のモデル picker で Fable 5 を選択できるようにします。ただし、
長時間のベンチマークや worker 実行の前には、アカウントの利用枠と credits を
確認してください。
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

## 将来のローカル LLM の現状

ローカルモデルまわりは変化が速い領域です。次の情報は、将来のアダプターと
ドキュメント整備のための調査結果です。

| ランタイム | Windows での位置づけ | winsmux での実用上の扱い |
| ------- | --------------- | -------------------------- |
| LM Studio | Windows x64 と ARM に対応しています。公式ドキュメントでは 16 GB RAM と 4 GB 以上の専用 VRAM が推奨されています。OpenAI 互換 API と Anthropic 互換 API でローカルモデルを提供できます。 | 将来のローカルエンドポイント用アダプター候補です。現時点でも手動のローカルモデル検証に向きます。 |
| Ollama | Windows ネイティブアプリです。公式ドキュメントでは Windows 10 22H2 以降、NVIDIA では 452.39 以降のドライバー、AMD Radeon では現在の Radeon ドライバーが要件です。ローカル API は `http://localhost:11434` で提供されます。 | 対応 GPU 経路がある PC では、将来のローカルエンドポイント用アダプター候補です。 |
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
- [Gemma 4 31B model card](https://huggingface.co/google/gemma-4-31B)
- [Gemma 4 26B A4B model card](https://huggingface.co/google/gemma-4-26B-A4B-it)
- [Llama 4 official overview](https://about.fb.com/ja/news/2025/04/llama-4-multimodal-intelligence/)
- [Mistral model overview](https://docs.mistral.ai/models/overview)
- [Qwen3.6-27B model card](https://huggingface.co/Qwen/Qwen3.6-27B)
- [DeepSeek V4 preview release](https://api-docs.deepseek.com/news/news260424)
- [DeepSeek API quick start](https://api-docs.deepseek.com/)
- [Kimi K2.6 model overview](https://www.kimi.com/ai-models/kimi-k2-6)
- [Kimi K2.7 Code model overview](https://platform.kimi.ai/docs/guide/kimi-k2-7-code-quickstart)
- [OpenRouter Kimi K2.7 Code](https://openrouter.ai/moonshotai/kimi-k2.7-code)
- [OpenRouter GLM 5.2](https://openrouter.ai/z-ai/glm-5.2)
- [Anthropic Fable 5 redeployment notice](https://www.anthropic.com/news/redeploying-fable-5)
- [Claude Fable availability](https://www.anthropic.com/claude/fable)
- [Claude apps release notes](https://docs.anthropic.com/en/release-notes/claude-apps)
