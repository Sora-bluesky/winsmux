# Provider and Model Support

This page describes how winsmux treats AI providers, model names, Google Colab
workers, and future local LLM runtimes.

winsmux is a local-first control plane. It starts and supervises agent CLIs,
worker slots, and evidence collection. It is not itself an LLM runtime and it
does not promise that one specific provider, model, or endpoint will always be
available.

Last reviewed against current upstream documentation: 2026-06-10.

## Naming policy

Public docs use product names consistently:

- `Claude Code`
- `Codex`
- `Antigravity CLI`
- `Gemini CLI` for legacy migration references

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
| `antigravity` provider adapter | Supported as an official CLI pane agent | Uses the local `agy` command. Model selection is owned by Antigravity CLI settings and recorded in winsmux evidence. |
| `colab_cli` worker backend | Supported for status, doctor, one-shot execution, logs, upload, and download | Requires a `google-colab-cli` compatible adapter and is intended for H100 or A100 Colab-backed work. |
| `colab_llm` worker backend | Supported for Colab GPU model-job metadata, doctor, one-shot execution, logs, and redacted evidence | Runs model jobs in an adapter-managed Colab runtime. Model cache, Hugging Face cache, and large artifacts belong under Colab-mounted Google Drive, not on the Windows PC or Ollama cache. |
| Major open model families | Supported as Colab model targets when the task script and runtime provide them | Examples include Gemma, Llama, Mistral, Qwen, DeepSeek, and Kimi/Moonshot. Treat the model family as workload metadata, not as a provider. |
| `local_llm` worker backend | Supported for status, doctor, one-shot prompt execution, and local logs | Initial runtime is Ollama at `http://127.0.0.1:11434`. Model cache and large run artifacts must be configured on a non-C-drive path, normally a G drive sync root. |
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
`analysis_posture: "read-only"`. The local runtime owns its endpoint, models,
and credentials. winsmux must not broker OAuth, collect callback URLs, or copy
provider tokens between panes. The built-in `ollama` capability follows this
posture and is exposed through the `local_llm` worker backend.

For Colab GPU model jobs, the built-in `colab_llm` capability uses the same
read-only posture. The Google sign-in, Colab runtime, notebook ownership, and
Drive mount are private runtime state owned by the adapter and browser session.
winsmux records only redacted status and artifact references.

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

The current Colab model lane is aimed at Google Colab execution, not local LLM
serving. For model workloads, the expected accelerator target is:

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

## Current Colab GPU LLM target

Use `colab_llm` when the intent is to run open-weight LLMs on a Colab Pro GPU.
This backend is separate from both:

- `colab_cli`: generic Colab script execution
- `local_llm`: PC-local endpoint execution such as Ollama

The initial desktop E2E layout uses the standard visible slots:

- `worker-1`: Colab GPU model job A
- `worker-2`: Colab GPU model job B

Both jobs may target one adapter-managed Colab runtime. If the selected models
cannot be loaded at the same time, run them sequentially in the same runtime and
record the shared GPU condition. Do not replace this with CPU-only local models.

Storage contract:

- Persistent root: `/content/drive/MyDrive/winsmux-colab-llm/`
- Model cache: `/content/drive/MyDrive/winsmux-colab-llm/models/`
- Hugging Face cache: `/content/drive/MyDrive/winsmux-colab-llm/hf-cache/`
- Large artifacts: `/content/drive/MyDrive/winsmux-colab-llm/artifacts/`
- Temporary runtime cache: `/content/winsmux-runtime-cache/`

The Colab task script sets `HF_HOME`, `HF_HUB_CACHE`, `TRANSFORMERS_CACHE`, and
`XDG_CACHE_HOME` to the Drive-backed cache root before loading a model. That is
the only supported model download path for the Colab GPU E2E. Do not pull these
models into a Windows Ollama cache or a PC-local model directory.

Example worker slots:

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

Operator checks:

```powershell
winsmux workers doctor --json
winsmux workers status --json
winsmux workers exec worker-1 --prompt "Summarize this repository state." --run-id colab-llm-smoke-1 --json
winsmux workers logs worker-1 --run-id colab-llm-smoke-1 --json
```

## Current local LLM target

The first first-class local LLM backend is `local_llm` with the Ollama runtime.
It is separate from `colab_cli`: winsmux does not use Colab degraded-state
fallbacks for local execution, and it does not treat a local model as a Colab
session.

This is a PC-local feature. It is not the Colab Pro GPU path and is not used for
the Colab LLM 2-worker E2E described above.

Initial E2E models:

- `gemma3:1b`
- `qwen2.5-coder:1.5b`

The storage contract is stricter than normal pane execution:

- Set `OLLAMA_MODELS` to an ASCII-only G drive model root before pulling models,
  for example `G:\winsmux-local-llm\ollama-models` or
  `<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\ollama-models`.
  On Windows, Ollama can fail to load model blobs from localized or otherwise
  non-ASCII model paths.
- Set each local LLM slot `artifact-root`, or
  `WINSMUX_LOCAL_LLM_ARTIFACT_ROOT`, to a G drive artifact root such as
  `<G_DRIVE_SYNC_ROOT>\winsmux-local-llm\artifacts`.
- Keep only lightweight `run.json`, redacted `stdout.log`, and shareable
  references under `.winsmux/worker-runs`.
- Do not write private Google Drive URLs or user-specific absolute paths into
  public docs, reports, or release notes.

Example worker slots:

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

Operator checks:

```powershell
winsmux workers doctor --json
winsmux workers status --json
winsmux workers exec worker-3 --prompt "Summarize this repository state." --run-id local-smoke-1 --json
winsmux workers logs worker-3 --run-id local-smoke-1 --json
```

For the real two-worker Ollama E2E, use the dedicated runner instead of
overwriting the repository `.winsmux.yaml`:

```powershell
pwsh scripts/test-local-llm-e2e.ps1 `
  -ModelRoot "<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\ollama-models" `
  -ArtifactRoot "<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\artifacts" `
  -CreateRoots `
  -PullModels
```

If Ollama is installed but not on `PATH`, pass the executable explicitly:

```powershell
pwsh scripts/test-local-llm-e2e.ps1 `
  -ModelRoot "<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\ollama-models" `
  -ArtifactRoot "<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\artifacts" `
  -OllamaPath "<OLLAMA_INSTALL_DIR>\ollama.exe" `
  -PullModels
```

To check readiness without creating directories, pulling models, or writing
evidence, run preflight only:

```powershell
pwsh scripts/test-local-llm-e2e.ps1 `
  -ModelRoot "<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\ollama-models" `
  -ArtifactRoot "<G_DRIVE_ASCII_ROOT>\winsmux-local-llm\artifacts" `
  -PreflightOnly
```

The runner creates an isolated project under `.winsmux/local-llm-e2e/<run-id>/`,
sets `OLLAMA_MODELS` only for that process, runs `worker-3` and `worker-4`
concurrently, and stores only lightweight evidence under the repository. Large
request/response artifacts stay under the configured G drive artifact root. It
does not install Ollama, change persistent environment variables, or start a
global Ollama service.

On Windows, Ollama reads user and system environment variables when the Ollama
application starts. If Ollama is already running with a C-drive model root,
setting `OLLAMA_MODELS` only in the runner process is not enough. Quit Ollama,
set `OLLAMA_MODELS` persistently to the G drive model root, restart Ollama, and
then pull the models. The runner also verifies that each requested model has an
Ollama manifest under the G drive `ModelRoot` before it treats the E2E as valid.
The runner fails preflight when `ModelRoot` contains non-ASCII characters because
that path can pass `ollama list` but still fail when `llama-server` opens the
model blob.
If the Google Drive mount itself is localized, create a temporary ASCII drive
letter for the session and point Ollama at that path:

```powershell
subst W: "<G_DRIVE_LOCALIZED_MY_DRIVE>"
pwsh scripts/test-local-llm-e2e.ps1 `
  -ModelRoot "W:\winsmux-local-llm\ollama-models" `
  -ArtifactRoot "W:\winsmux-local-llm\artifacts" `
  -OllamaPath "<OLLAMA_INSTALL_DIR>\ollama.exe" `
  -PullModels
```

The storage still lives under the G drive mount. `winsmux workers doctor` and
the E2E runner accept a `subst` drive only when it resolves back to `G:\`.

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

## Local LLM runtime landscape

Local model support is moving quickly. Ollama is the current first-class
`local_llm` runtime. The other runtimes in this table are planning references
for future adapters and documentation. This table is not a `colab_cli` runtime
requirement.

| Runtime | Windows posture | Practical role for winsmux |
| ------- | --------------- | -------------------------- |
| LM Studio | Windows x64 and ARM are supported. The docs recommend 16 GB RAM and 4 GB dedicated VRAM. It can serve local models through OpenAI-compatible and Anthropic-compatible APIs. | Good candidate for a future local endpoint adapter and for manual local model experiments today. |
| Ollama | Native Windows app. The docs list Windows 10 22H2 or newer, NVIDIA driver 452.39 or newer for NVIDIA cards, and current AMD Radeon drivers for Radeon cards. The local API is served at `http://localhost:11434`. | Current first-class `local_llm` runtime. Initial E2E models are `gemma3:1b` and `qwen2.5-coder:1.5b`. |
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
| Colab or Colab Enterprise runtime with H100 or A100 | GPU-backed one-shot worker execution without local VRAM | This is the current target for `colab_llm` model jobs. Availability, quota, IAM, and runtime startup are owned by Google/Colab, not winsmux. |

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
