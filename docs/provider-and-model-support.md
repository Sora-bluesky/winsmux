# Provider and Model Support

This page describes how winsmux treats AI providers, model names, hosted model
workers, and future local LLM runtimes.

winsmux is a local-first control plane. It starts and supervises agent CLIs,
worker slots, and evidence collection. It is not itself an LLM runtime and it
does not promise that one specific provider, model, or endpoint will always be
available.

Last reviewed against current upstream documentation: 2026-07-02.

## Naming policy

Public docs use product names consistently:

- `Claude Code`
- `Codex`
- `Antigravity CLI`
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
| `api_llm` worker backend | Supported contract for hosted OpenAI-compatible model workers | Uses provider-owned API access such as OpenRouter. The public setup path is the runtime environment variable; winsmux records only redacted run metadata and does not fall back to another backend. |
| `antigravity` worker backend | Supported for Antigravity CLI one-shot workers | Uses the local `agy` command in print mode. The CLI owns sign-in and model access; winsmux records redacted run metadata and does not log the prompt body. |
| Major open model families | Supported through hosted or future local runtimes when the provider and runtime expose them | Examples include Gemma, Llama, Mistral, Qwen, DeepSeek, and Kimi/Moonshot. Treat the model family as workload metadata, not as a provider. |
| Local LLM runtimes | Planned adapter family | Today, run them as normal local tools or behind an agent CLI that can use a local endpoint. |
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
- `execution_backend`: the runtime path, such as an agent CLI, hosted API
  worker, or OpenAI-compatible local endpoint.
- `runtime_requirements`: endpoint, executable, GPU, CPU, memory, OS, or remote
  runtime expectations.
- `model_catalog_source` and `model_options`: where model names come from and
  which choices the operator can select.
- `api_base_url` and `api_key_env`: the OpenAI-compatible endpoint and the
  environment variable name used by hosted `api_llm` workers. Built-in hosted
  providers such as `openrouter` keep these values fixed; custom endpoints are
  limited to localhost.
- `analysis_posture`: whether the provider is safe only for read-only analysis
  or can act as a normal write-capable worker.

## Antigravity CLI workers

Google's published migration notice says Gemini CLI and Gemini Code Assist IDE
extensions stopped serving requests for Gemini Code Assist for individuals,
Google AI Pro, and Google AI Ultra on 2026-06-18. Affected users should use
Antigravity CLI. Google AI Standard and Enterprise tiers are not treated as
sunset by this winsmux policy.

Use `antigravity` for one-shot worker execution when the local `agy` command is
available:

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

`winsmux workers exec` runs `agy --print <file-reference-prompt>
--print-timeout <duration>` from the project directory and adds
`--model <model>` when the slot declares an explicit model. The CLI process
receives a short instruction to read the relative task file in the current
workspace; winsmux does not place the task file body in the process arguments,
run JSON, logs, PR text, or release evidence.

If `agy` is not installed or cannot expose print mode, `winsmux workers doctor`
reports an Antigravity CLI failure and migrated workers stay unconfigured.
winsmux does not silently fall back to the consumer Gemini CLI path for these
workers.

## Hosted API model workers

`api_llm` is the hosted OpenAI-compatible worker backend. It is for model
providers that expose chat-completions style APIs, with OpenRouter as the first
supported provider contract. A slot may declare:

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

The default OpenRouter-compatible base URL is
`https://openrouter.ai/api/v1`. The environment variable name is
`OPENROUTER_API_KEY` when the operator chooses environment-based
authentication. winsmux must not write this value
to repository files, public docs, PR text, generated reports, worker logs, or
release evidence.
For public setup on Windows, store the key as a user environment variable and
open a new PowerShell session before running `winsmux`:

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

Verify only that the variable is present; do not print the value:

```powershell
if ([string]::IsNullOrWhiteSpace($env:OPENROUTER_API_KEY)) { "missing" } else { "configured" }
```

Do not store the key in shell startup files, command history, repo-local `.env`
files, public docs, PR text, generated reports, worker logs, or release
evidence.

`api_llm` is intentionally separate from local and CLI-managed backends. If the
API key environment variable is missing or the provider
endpoint is invalid, winsmux reports a diagnostic reason such as
`api_llm_api_key_env_missing` before network access instead of silently
switching to another backend.

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

## Worker pane model picker and benchmark comparison

The desktop runtime settings surface separates model entries into six classes:

| Class | Picker behavior | Benchmark behavior |
| ----- | --------------- | ------------------ |
| `selectable` | Can be assigned to a compatible worker slot. The slot backend still decides whether the run can start. | Shown with winsmux-local run evidence when available. |
| `setup-required` | Shown when a normal worker path exists but setup is incomplete. For example, OpenRouter entries require an `api_llm` slot and `OPENROUTER_API_KEY` in the runtime environment. | Excluded from scoring until a local run id, latency, cost, failure reason, and reproducibility data are recorded. |
| `runnable` | Can be assigned to a compatible worker slot after backend and credential checks pass. | Shown with winsmux-local run evidence when available. |
| `blocked` | Disabled because the provider, endpoint, or local runner cannot currently satisfy the contract. | Kept as evidence with an explicit reason and excluded from scoring. |
| `reference-only` | Shown for comparison context but not selectable from the desktop picker. | Can show Agent Arena or Code Arena reference data, but must not imply that winsmux can run the model locally. |
| `unavailable` | Disabled until the upstream provider restores official access. | Kept only to explain external benchmark rows. |

Reference benchmarks are advisory. They do not directly change `winsmux
compare-runs` winner selection, which is based on the local run evidence,
review outcome, changed files, reproducibility, and operator decision trail.

For Claude Code, Codex, and Antigravity CLI worker comparisons, use the
tracked [CLI comparison bakeoff](cli-comparison-bakeoff.md) task pack and
preflight gates. A run without publishable desktop recording evidence is useful
as operational evidence, but it must not change the default worker assignment.

`Claude Fable 5` is treated as `selectable` again. Anthropic announced that
Fable 5 access was restored for Claude Platform, Claude.ai, Claude Code, and
Claude Cowork starting 2026-07-01. Pro, Max, Team, and select Enterprise plans
include Fable 5 usage within up to 50% of weekly usage limits through
2026-07-07. After that date, Fable 5 usage requires usage credits.

winsmux may offer Fable 5 in the Claude Code model picker when the local Claude
Code account exposes the model. Long benchmark or worker runs should still
confirm account quota and credit availability before dispatch.
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

## Future local LLM landscape

Local model support is moving quickly. The following information is included to
guide future adapters and documentation.

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
- [Gemma 4 31B model card](https://huggingface.co/google/gemma-4-31B)
- [Gemma 4 26B A4B model card](https://huggingface.co/google/gemma-4-26B-A4B-it)
- [Llama official docs](https://ai.meta.com/llama/get-started/)
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
