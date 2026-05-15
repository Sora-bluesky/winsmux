# Provider and Model Support

This page describes how winsmux treats AI providers, model names, Google Colab
workers, and future local LLM runtimes.

winsmux is a local-first control plane. It starts and supervises agent CLIs,
worker slots, and evidence collection. It is not itself an LLM runtime and it
does not promise that one specific provider, model, or endpoint will always be
available.

Last reviewed against current upstream documentation: 2026-05-13.

## Naming policy

Public docs use product names consistently:

- `Claude Code`
- `Codex`
- `Gemini`

When the docs need to describe how they run, they say "agent CLI", "official
CLI", or "local endpoint" in the surrounding text. Product-name columns use
the names above and keep the CLI detail in a separate authentication or runtime
column.

## Support levels

| Class | Current winsmux support | Notes |
| ----- | ----------------------- | ----- |
| Official hosted agent CLIs | Supported as pane agents | The CLI owns its own sign-in or API key flow. |
| `local` worker backend | Supported | Runs normal managed panes on this PC. |
| `codex` worker backend | Metadata today | Used to describe Codex-capable worker or review slots. |
| `colab_cli` worker backend | Supported for status, doctor, one-shot execution, logs, upload, and download | Requires a `google-colab-cli` compatible adapter and is intended for H100 or A100 Colab-backed work. |
| Major open model families | Supported as Colab model targets when the task script and runtime provide them | Examples include Gemma, Llama, Mistral, Qwen, DeepSeek, and Kimi/Moonshot. Treat the model family as workload metadata, not as a provider. |
| Local LLM runtimes | Planned adapter family | Not a `v0.32.x` Colab-lane runtime requirement. Today, run them as normal local tools or behind an agent CLI that can use a local endpoint. |
| `noop` worker backend | Supported placeholder | Keeps a slot declared but inactive. |

## Provider capability catalog

From `v0.33.0`, `.winsmux/provider-capabilities.json` is the capability catalog
for agent CLIs and local endpoint adapters. The catalog separates launch
mechanics from model metadata and from credential boundaries, so winsmux does
not treat a local inference endpoint as a write-capable worker by accident.

Provider entries may declare:

- `harness_availability`: whether the provider is a built-in CLI, an external
  adapter, or a manual pane tool.
- `credential_requirements`: who owns sign-in, API keys, endpoint secrets, and
  token storage.
- `execution_backend`: the runtime path, such as an agent CLI, Colab worker, or
  OpenAI-compatible local endpoint.
- `runtime_requirements`: endpoint, executable, GPU, CPU, memory, OS, or remote
  runtime expectations.
- `model_catalog_source` and `model_options`: where model names come from and
  which choices the operator can select.
- `analysis_posture`: whether the provider is safe only for read-only analysis
  or can act as a normal write-capable worker.

## Execution profile policy

`execution_profile` is a run-policy field, not a provider name and not a worker
backend. The default value is `local-windows`; it keeps the existing local
managed-pane behavior. `isolated-enterprise` is explicit opt-in for the
enterprise isolation lane and should not be selected implicitly by provider,
model, or role.

The Windows sandbox baseline belongs to this execution-profile layer. It is a
run contract for `isolated-enterprise`: a restricted-token launch requirement,
a run-scoped ACL boundary, and fail-closed checks around the prepared isolated
workspace. It is not a provider capability and does not make `local-windows`
workers sandboxed.

This keeps three decisions separate:

- role or playbook intent: why the slot exists and what evidence it should
  produce
- worker backend: where the worker slot is hosted
- execution profile: which run policy and isolation lane applies

For OpenAI-compatible local endpoints and GPU-backed local runtimes, the safe
default is a read-only analysis provider: `supports_file_edit: false`,
`supports_verification: false`, `supports_consultation: true`, and
`analysis_posture: "read-only-analysis"`. The local runtime owns its endpoint,
models, and credentials. winsmux must not broker OAuth, collect callback URLs,
or copy provider tokens between panes.

## Model selection policy

Model names change faster than winsmux releases. winsmux therefore treats a
model as runtime metadata, not as a hard-coded product role.

Slots and planning records may include:

- `provider`
- `model_family`
- `model_id`
- `fallback_model_id`
- `runtime_engine`
- `precision`
- `quantization`
- `distillation_source`
- `license_state`
- capability metadata such as work, review, consultation, tool use, and context size

winsmux records the selected model and runtime metadata when they appear in run
evidence, but the operator remains responsible for deciding whether that model
is acceptable for a task.

## Current Colab model target

The `v0.32.x` Colab lane is aimed at Google Colab execution, not local LLM serving. For model
workloads, the expected accelerator target is:

- preferred: `H100`
- acceptable: `A100`

Other GPU types may be useful for smaller experiments, but they are not the
normal operating target for this release lane. If the configured Colab worker
cannot confirm `H100` or `A100`, winsmux should report the state and let the
operator decide whether to continue.

Major open model families are supported as Colab workload targets when the task
script can load the exact model id. winsmux should record the selected
`model_family` and `model_id`, but it should not hard-code a loader for one
vendor or one release name.

| Model family | Colab target posture | Access and license notes |
| ------------ | -------------------- | ------------------------ |
| Gemma | Supported when the notebook installs the required Google/Kaggle or Hugging Face path. Examples include Gemma 4 31B and Gemma 4 26B A4B when the runtime can fit them. | Accept the Gemma terms through the model source before first use. |
| Llama | Supported when the notebook can access Meta Llama weights and the selected variant fits the runtime. Examples include Llama 4 Scout and Llama 4 Maverick. | Accept the Meta license and acceptable use policy through Meta, Hugging Face, Kaggle, or another official partner path. |
| Mistral / Ministral / Devstral | Supported when the notebook uses official Mistral weights or a supported cloud/model hub path. Examples include Mistral, Ministral, Magistral, and Devstral variants. | Check the license for the exact model. Mistral publishes both open and restricted-license weights. |
| Qwen | Supported when the notebook uses Qwen open weights through a supported framework such as Transformers. Examples include Qwen3.6-27B and its quantized or served variants. | Check the exact model card and license. Qwen includes dense and mixture-of-experts model families. |
| DeepSeek | Supported when the notebook uses official DeepSeek weights, hosted API-compatible targets, or distill variants that fit the runtime. Examples include DeepSeek V4 Pro and DeepSeek V4 Flash. | Check the exact license and base-model terms, especially for distill models derived from Llama or Qwen. |
| Kimi / Moonshot | Supported when the notebook can access an official open-weight release or an approved hosted endpoint. Examples include Kimi K2.6. | Confirm the official source, model license, and any hosted API terms before use. |
| Other compatible families | Supported when they have a trusted source, an allowed license, and a runtime path that fits `H100` / `A100`. | Do not treat community names, merges, or quantizations as approved without checking their model card and base model lineage. |

## Variant and distillation metadata

Do not make the support matrix depend on every model marketing name. New model
variants, quantizations, merges, and distilled checkpoints appear too quickly
for that to remain accurate.

Run evidence should prefer structured metadata:

```yaml
model_family: qwen
model_id: Qwen/Qwen3.6-27B
runtime_engine: vllm
precision: fp8
distillation_source: null
license_state: accepted
```

For distilled or derived models, record the derived model and the base model
lineage when it is known:

```yaml
model_family: deepseek
model_id: deepseek-ai/DeepSeek-R1-Distill-Qwen-32B
runtime_engine: transformers
precision: int4
distillation_source: Qwen/Qwen2.5-32B
license_state: accepted
```

This lets winsmux track `Kimi K2.6`, `DeepSeek V4 Pro / Flash`,
`Qwen3.6-27B`, `Gemma 4 31B / 26B A4B`, `Llama 4 Scout / Maverick`, and later
families without changing the CLI contract for every new checkpoint.

The task script remains responsible for:

- accepting or verifying model access before loading
- installing packages such as `torch`, `transformers`, `accelerate`, `vllm`,
  `sglang`, or another supported runtime
- resolving the exact model id from an allowlisted source
- selecting quantization or precision
- recording derived or distilled model lineage when applicable
- checking whether the exact variant fits the `H100` / `A100` runtime

## Future local LLM landscape

Local model support is moving quickly. The following information is included to
guide future adapters and documentation. It is not a `v0.32.x` Colab-lane runtime
requirement.

| Runtime | Windows posture | Practical role for winsmux |
| ------- | --------------- | -------------------------- |
| LM Studio | Windows x64 and ARM are supported. The docs recommend 16 GB RAM and 4 GB dedicated VRAM. It can serve local models through OpenAI-compatible and Anthropic-compatible APIs. | Good candidate for a future local endpoint adapter and for manual local model experiments today. |
| Ollama | Native Windows app. The docs list Windows 10 22H2 or newer, NVIDIA driver 452.39 or newer for NVIDIA cards, and current AMD Radeon drivers for Radeon cards. The local API is served at `http://localhost:11434`. | Good candidate for a future local endpoint adapter when the machine has a supported GPU path. |
| llama.cpp | Cross-platform engine for GGUF models with backends such as CUDA, HIP, Vulkan, SYCL, OpenVINO, Metal, and CPU BLAS paths. | Useful as a low-level runtime, either directly or through tools that package it. |
| vLLM | Server-oriented runtime. Current docs list Linux as the supported OS and state that Windows is not natively supported; use WSL or a Linux server for Windows workflows. | Good candidate for remote or WSL-hosted high-throughput inference, not a default native Windows dependency. |
| ONNX Runtime GenAI with Windows ML | Windows local inference path for ONNX generative models. The Windows ML GenAI library is documented as a preview 0.x library. | Interesting future native-app path, but not a stable default worker backend yet. |

## Practical local hardware guidance

These are planning guidelines, not guarantees. Exact fit depends on model size,
quantization, context length, tool use, and the runtime.

| Machine class | Useful for | Notes |
| ------------- | ---------- | ----- |
| CPU-only Windows PC with 16 GB RAM | Small quantized models, smoke tests, offline demos | Expect lower speed. Prefer small context sizes. |
| Windows PC with 8 to 12 GB VRAM and 32 GB system RAM | Many 7B/8B class quantized models, light coding assistance, local review experiments | This is the most practical consumer tier. |
| Windows PC with 16 to 24 GB VRAM and 64 GB system RAM | Larger quantized models and longer context experiments | Still runtime-specific. Check the model card and runtime memory estimator. |
| WSL/Linux server with datacenter GPU | vLLM-style serving and multi-user or high-throughput jobs | Treat as a remote or WSL endpoint, not a native Windows pane. |
| Colab or Colab Enterprise runtime with H100 or A100 | GPU-backed one-shot worker execution without local VRAM | This is the current target for `colab_cli` model work. Availability, quota, IAM, and runtime startup are owned by Google/Colab, not winsmux. |

## Security and privacy rules

Local does not automatically mean safe.

- Download models only from trusted sources and review their licenses.
- Treat model files and prompt logs as data assets.
- Bind local inference servers to `127.0.0.1` unless you intentionally expose them.
- Do not put API keys or OAuth tokens into model prompts.
- Do not let winsmux receive OAuth callback URLs or extract tokens from another tool.
- Use `winsmux vault` only for credentials that must be injected into a pane.

## Adapter requirements for future local LLM support

A future local LLM adapter must expose:

- runtime health
- configured endpoint or executable path
- selected model id
- context size or a clear unknown value
- tool-use support state
- authentication mode
- evidence path for request/response metadata that avoids raw secret capture

If a local runtime cannot report these fields, winsmux should treat it as a
manual pane tool rather than a first-class worker backend.

## Sources

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
- [Llama official docs](https://ai.meta.com/llama/get-started/)
- [Mistral model overview](https://docs.mistral.ai/models/overview)
- [Qwen3.6-27B model card](https://huggingface.co/Qwen/Qwen3.6-27B)
- [DeepSeek V4 preview release](https://api-docs.deepseek.com/news/news260424)
- [DeepSeek API quick start](https://api-docs.deepseek.com/)
- [Kimi K2.6 model overview](https://www.kimi.com/ai-models/kimi-k2-6)
