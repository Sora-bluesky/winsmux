# Google Colab Workers

This page explains how to prepare a Colab-backed winsmux worker.

In `v0.32.4`, winsmux can route one-shot worker actions through a
`google-colab-cli` compatible adapter:

- `winsmux workers exec`
- `winsmux workers logs`
- `winsmux workers upload`
- `winsmux workers download`
- `winsmux workers attach`

winsmux does not become a Google sign-in broker. The Colab tool or Google-owned
runtime owns authentication, runtime creation, GPU availability, quota, and
browser sign-in.

## Notebook and runtime requirement

Yes, a Colab notebook or an adapter-managed equivalent is required.

Colab runs code from a notebook that is connected to a runtime. For winsmux,
prepare one of these before using `workers exec`:

- a Colab notebook already connected to an `H100` runtime
- a Colab notebook already connected to an `A100` runtime
- a `google-colab-cli` compatible adapter that creates or selects the notebook
  and connects it to an `H100` or `A100` runtime before running the script

winsmux does not create Google-owned notebook resources directly. It calls the
configured adapter and records the local evidence.

## Requirements

Local requirements:

- Windows 10 or Windows 11
- PowerShell 7+
- winsmux installed with the `full` or `orchestra` profile
- a project initialized with `winsmux init`
- a prepared Colab notebook/runtime, or an adapter that manages that notebook
  and runtime
- an adapter command available as `google-colab-cli`, or an explicit
  `WINSMUX_COLAB_CLI` environment variable pointing to a compatible adapter
- `uv` when your adapter or bootstrap flow depends on it
- network access and any browser session required by the adapter

Google-side requirements depend on the Colab product you use:

- for consumer Colab, sign in with the Google account that owns the notebook or runtime
- for Colab Enterprise, use a Google Cloud project and the required IAM roles for connecting to or creating runtimes
- the intended accelerator is `H100`, with `A100` as the accepted fallback
- GPU availability is not guaranteed; winsmux reports unavailable or mismatched GPU state as degraded worker state

For model workloads, this release lane assumes the code runs on Google Colab.
It does not require a local LLM runtime on the Windows PC.

## Adapter contract

winsmux expects a `google-colab-cli` compatible command with these operations:

```powershell
google-colab-cli run --session <name> --script <path> --run-id <id> --output-dir <path>
google-colab-cli logs --session <name> --run-id <id>
google-colab-cli upload --session <name> --source <path> --dest <remote-path> --manifest <path> --run-id <id>
google-colab-cli download --session <name> --source <remote-path> --dest <path> --run-id <id>
```

In that contract, `--session <name>` identifies the adapter-managed Colab
notebook/runtime session. The adapter is responsible for mapping that name to
the notebook and runtime.

If your adapter has another executable name, set:

```powershell
$env:WINSMUX_COLAB_CLI = "C:\path\to\your-adapter.exe"
```

Then check:

```powershell
winsmux workers doctor
```

## Configure a Colab slot

`winsmux init` creates six worker slots by default. To make one slot
Colab-backed, set `worker-backend: colab_cli` for that slot:

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

Run:

```powershell
winsmux workers status
winsmux workers attach w2
winsmux workers doctor
```

The slot should show `backend` as `colab_cli`. If the adapter, authentication,
or required `H100` / `A100` GPU cannot be confirmed, the slot remains visible
but is marked degraded.

## Model families

Colab workers are model-family agnostic. winsmux records the intended model as
metadata and lets the task script load the exact checkpoint or API target.

The intended `v0.32.4` accelerator target is `H100`, with `A100` as the
accepted fallback. Large dense, mixture-of-experts, multimodal, or long-context
models may still require quantization, smaller context settings, tensor
parallelism, or a hosted API target even on those GPUs.

Examples that the metadata should be able to represent include:

| Family | Example targets | Notes |
| ------ | --------------- | ----- |
| Gemma | Gemma 4 31B, Gemma 4 26B A4B | Accept the Google/Kaggle or Hugging Face access terms before first use. |
| Llama | Llama 4 Scout, Llama 4 Maverick | Accept the Meta license and acceptable use policy through an official access path. |
| Mistral | Mistral, Ministral, Magistral, Devstral variants | Check the exact model license. Mistral publishes open and restricted-license weights. |
| Qwen | Qwen3.6-27B and quantized or served variants | Check the model card and use a framework that supports the exact architecture. |
| DeepSeek | DeepSeek V4 Pro, DeepSeek V4 Flash, distill variants | Check the exact model or API ID, plus any base-model license for distills. |
| Kimi / Moonshot | Kimi K2.6 | Confirm the official open-weight or hosted endpoint terms. |

Before running a model task:

1. Accept all model access terms through the official source.
2. Make sure the Colab runtime is `H100` or `A100`.
3. Install only the packages needed by the script, such as `torch`,
   `transformers`, `accelerate`, `vllm`, or `sglang`.
4. Select precision and quantization intentionally.
5. Record distilled or derived model lineage when it is known.
6. Keep model cache and large outputs in Colab, Google Drive, Cloud Storage, or
   another explicit artifact location. Do not upload local secrets through
   `winsmux workers upload`.

Example slot metadata can record the intended model family and exact target:

```yaml
    model_family: qwen
    model_id: Qwen/Qwen3.6-27B
    runtime_engine: vllm
    precision: fp8
    gpu-preference: [H100, A100]
```

winsmux records this as runtime metadata. The task script is still responsible
for loading the exact model, API target, quantization, or distilled checkpoint.

## Run a task

Create a script in the project:

```powershell
New-Item -ItemType Directory -Force workers\colab | Out-Null
@'
print("hello from colab worker")
'@ > workers\colab\impl_worker.py
```

Run it:

```powershell
winsmux workers exec w2 --script workers/colab/impl_worker.py --run-id demo-1 --json
winsmux workers logs w2 --run-id demo-1
```

winsmux stores local metadata under:

- `.winsmux/worker-runs/<slot-id>/<run-id>/run.json`
- `.winsmux/worker-runs/<slot-id>/<run-id>/stdout.log`

## Upload and download artifacts

Upload an explicit file:

```powershell
winsmux workers upload w2 data/input.json --remote /content/input.json --run-id demo-1 --json
```

Upload a directory only when you explicitly allow it:

```powershell
winsmux workers upload w2 data --remote /content/data --allow-dir data --run-id demo-1 --json
```

Download an output:

```powershell
winsmux workers download w2 /content/output.json --output artifacts/worker-output --run-id demo-1 --json
```

Directory uploads are staged through a safe manifest. winsmux excludes:

- `.git`, `.hg`, `.svn`
- `.winsmux`, `.orchestra-prompts`
- `node_modules`
- virtual environments such as `.venv`, `venv`, and `env`
- build outputs such as `dist`, `build`, and `target`
- coverage and tool caches
- secret-like files such as `.env`, key files, certificates, tokens, and credentials
- files larger than the configured maximum upload size

## Limits

`v0.32.4` does not automate an interactive Colab REPL or console loop. It runs
one file-backed task at a time through the configured adapter.

Use Google Drive, Cloud Storage, or another explicit storage path for large
artifacts when the adapter supports that workflow. winsmux only records the
local run metadata and the upload/download command evidence.

## Troubleshooting

| Symptom | Check |
| ------- | ----- |
| `google-colab-cli not found on PATH` | Install your adapter or set `WINSMUX_COLAB_CLI`. |
| No notebook is prepared | Create a Colab notebook and connect it to an `H100` or `A100` runtime, or configure an adapter that manages that notebook/runtime. |
| `missing auth` or degraded auth state | Complete sign-in in the official Google or adapter-owned flow. winsmux will not receive callback URLs or extract tokens. |
| GPU is not `H100` or `A100` | Confirm the Colab runtime type and quota outside winsmux, then run `winsmux workers doctor` again. |
| Model download or API target setup fails | Confirm that model access terms were accepted and the runtime has the expected Kaggle, Hugging Face, Google, or provider credentials. |
| Directory upload is rejected | Add `--allow-dir <path>` and keep the source under the project directory. |
| Secret-like file is excluded | This is intentional. Upload a sanitized file instead. |
| Adapter returns a non-zero exit code | Inspect the JSON payload, `stdout.log`, and adapter logs. winsmux propagates the adapter exit code. |

## Sources

- [Google Colab Enterprise runtime connection docs](https://cloud.google.com/colab/docs/connect-to-runtime)
- [Google Colaboratory GitHub organization](https://github.com/googlecolab)
- [Gemma setup](https://ai.google.dev/gemma/docs/setup)
- [Gemma and LangChain Colab guide](https://ai.google.dev/gemma/docs/integrations/langchain)
- [Gemma 4 31B model card](https://huggingface.co/google/gemma-4-31B)
- [Gemma 4 26B A4B model card](https://huggingface.co/google/gemma-4-26B-A4B-it)
- [Llama official docs](https://ai.meta.com/llama/get-started/)
- [Mistral model overview](https://docs.mistral.ai/models/overview)
- [Qwen3.6-27B model card](https://huggingface.co/Qwen/Qwen3.6-27B)
- [DeepSeek V4 preview release](https://api-docs.deepseek.com/news/news260424)
- [Kimi K2.6 model overview](https://www.kimi.com/ai-models/kimi-k2-6)
