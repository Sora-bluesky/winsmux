# プロバイダーとモデルの対応方針

このページでは、winsmux が AI プロバイダー、モデル名、Google Colab ワーカー、
将来のローカル LLM ランタイムをどう扱うかを説明します。

winsmux はローカル優先の管制面です。エージェント CLI、ワーカースロット、
証跡収集を起動・監視します。winsmux 自体が LLM ランタイムになるわけではなく、
特定のプロバイダー、モデル、エンドポイントが常に使えることも約束しません。

最終確認日: 2026-05-13。

## 表記方針

公開ドキュメントでは、製品名を次のようにそろえます。

- `Claude Code`
- `Codex`
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
| `colab_cli` ワーカーバックエンド | 状態確認、診断、単発実行、ログ、アップロード、ダウンロードに対応 | `google-colab-cli` 互換アダプターが必要です。H100 または A100 の Colab 実行を主な対象にします。 |
| 主要なオープンモデルファミリー | タスクスクリプトとランタイムが用意している場合、Colab 上のモデル対象として対応 | 例は Gemma、Llama、Mistral、Qwen、DeepSeek、Kimi/Moonshot です。モデルファミリーはプロバイダーではなく、作業メタデータとして扱います。 |
| ローカル LLM ランタイム | 今後のアダプター候補 | `v0.32.4` の動作要件にはしません。現時点では、通常のローカルツールとしてペインで動かすか、ローカルエンドポイントを使えるエージェント CLI 経由で使います。 |
| `noop` ワーカーバックエンド | 仮置きスロットとして対応 | スロットを宣言したまま無効にできます。 |

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

`v0.32.4` の対象は Google Colab 上での実行であり、ローカル LLM 提供ではありません。
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

## 将来のローカル LLM の現状

ローカルモデルまわりは変化が速い領域です。次の情報は、将来のアダプターと
ドキュメント整備のための調査結果です。`v0.32.4` の動作要件ではありません。

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
| H100 または A100 の Colab / Colab Enterprise ランタイム | ローカル VRAM を使わない GPU 付き単発ワーカー実行 | `colab_cli` モデル作業の現行対象です。可用性、割り当て、IAM、ランタイム起動は Google/Colab 側の責務です。 |

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
