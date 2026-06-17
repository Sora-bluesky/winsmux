BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Adapter = Join-Path $script:RepoRoot 'scripts/google-colab-cli-adapter.ps1'
    $script:WorkerScript = Join-Path $script:RepoRoot 'workers/colab/llm_worker.py'
}

Describe 'google-colab-cli adapter bridge' {
    It 'uses a torch CUDA matched uv backend and prepares torch before importing vLLM' {
        $workerSource = Get-Content -LiteralPath $script:WorkerScript -Raw -Encoding UTF8
        $workerSource | Should -Match 'WINSMUX_COLAB_LLM_VLLM_INSTALL_MODE", "uv-wheel"'
        $workerSource | Should -Match 'resolve_uv_torch_backend'
        $workerSource | Should -Match 'WINSMUX_COLAB_LLM_UV_TORCH_BACKEND'
        $workerSource | Should -Match 'resolve_vllm_cuda_version'
        $workerSource | Should -Match 'WINSMUX_COLAB_LLM_VLLM_WHEEL_URL_TEMPLATE'
        $workerSource | Should -Match 'WINSMUX_COLAB_LLM_VLLM_RELEASE_TAG_API_TEMPLATE'
        $workerSource | Should -Match 'WINSMUX_COLAB_LLM_UV_INDEX_STRATEGY'
        $workerSource | Should -Match 'unsafe-best-match'
        $workerSource | Should -Match 'browser_download_url'
        $workerSource | Should -Match 'vllm_wheel_not_found'
        $workerSource | Should -Match 'WINSMUX_COLAB_LLM_UPGRADE_PILLOW'
        $workerSource | Should -Match 'clear_imported_modules'
        $workerSource | Should -Match '"PIL", "vllm", "numpy"'
        $workerSource | Should -Match 'detect_gpu_from_nvidia_smi'
        $workerSource | Should -Match '--query-gpu=name'
        $workerSource | Should -Match 'WINSMUX_COLAB_LLM_REEXEC_AFTER_INSTALL'
        $workerSource | Should -Match 'os\.execv'
        $workerSource | Should -Match 'build_effective_prompt'
        $workerSource | Should -Match 'WINSMUX_COLAB_LLM_INCLUDE_RUNTIME_METADATA'
        $workerSource | Should -Match 'format_chat_prompt'
        $workerSource | Should -Match 'WINSMUX_COLAB_LLM_USE_QWEN_CHAT_TEMPLATE'
        $workerSource | Should -Match '<\\|im_start\\|>system'
        $workerSource | Should -Match 'classify_worker_exception'
        $workerSource | Should -Match 'model_access_denied'
        $workerSource | Should -Match 'redact_sensitive_text'
        $workerSource | Should -Match 'quantization\.strip\(\)\.lower\(\) not in \("none", "null", "false"\)'
        $workerSource | Should -Match 'torch\.version'
        $workerSource | Should -Match 'WINSMUX_COLAB_LLM_DEFAULT_VLLM_CUDA_VERSION'
        $workerSource | Should -Match '--torch-backend='
        $workerSource | Should -Match '--reinstall-package=vllm'
        $workerSource | Should -Match 'libcudart\.so\*'
        $workerSource | Should -Match 'ctypes\.CDLL'
        $workerSource | Should -Match 'prepare_torch_cuda_runtime'
        $workerSource | Should -Match 'torch\.cuda\.current_device'
        $workerSource | Should -Match 'WINSMUX_COLAB_LLM_INSTALL_CUDA13_RUNTIME", False'
        $workerSource | Should -Match 'nvidia-cuda-runtime-cu13'
        $workerSource | Should -Match 'nvidia-cuda-nvrtc-cu13'
        $workerSource | Should -Match 'pip-cu129'
        $workerSource | Should -Match 'https://download\.pytorch\.org/whl/cu129'
        $workerSource | Should -Match 'WINSMUX_COLAB_LLM_MODEL_CAPACITY_PREFLIGHT'
        $workerSource | Should -Match 'WINSMUX_COLAB_LLM_HF_METADATA_TIMEOUT_SECONDS'
        $workerSource | Should -Match 'math\.isfinite'
        $workerSource | Should -Match 'SHARDED_PYTORCH_BIN_RE'
        $workerSource | Should -Match 'HF_WEIGHT_EXTENSIONS'
        $workerSource | Should -Match 'model_capacity_preflight_begin'
        $workerSource | Should -Match 'X-Linked-Size'
        $workerSource | Should -Match 'model_capacity_exceeded'
        $workerSource | Should -Match 'model_size_unavailable'
        $workerSource | Should -Match 'estimated_total_bytes'
    }

    It 'classifies oversized Hugging Face models before vLLM download or load' {
        $probe = Join-Path $TestDrive 'capacity_probe.py'
        $workerPath = ($script:WorkerScript -replace '\\', '\\')
        @"
import contextlib
import io
import json
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("llm_worker", r"$workerPath")
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

mod.detect_gpu = lambda: {"available": True, "name": "NVIDIA A100-SXM4-80GB", "count": 1, "source": "test"}
mod.configure_cache = lambda task: {
    "drive_root": "/content/drive/MyDrive/winsmux-colab-llm",
    "model_root": "/content/drive/MyDrive/winsmux-colab-llm/models",
    "hf_cache_root": "/content/drive/MyDrive/winsmux-colab-llm/hf-cache",
    "artifact_root": str(Path(r"$($TestDrive -replace '\\', '\\')") / "artifacts"),
    "runtime_cache_root": "/content/winsmux-runtime-cache",
}
mod.estimate_hf_model_storage = lambda model_id, timeout=30.0: {
    "model_id": model_id,
    "safetensor_files": 282,
    "shard_count": 282,
    "sample_file": "model-00001-of-00282.safetensors",
    "sample_size_bytes": 5342821416,
    "estimated_total_bytes": 1500000000000,
}

task = {
    "model_id": "zai-org/GLM-5.2",
    "license_state": "not_required",
    "prompt": "capacity probe",
}
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    code = mod.main([
        "--worker-id", "worker-1",
        "--run-id", "capacity-probe",
        "--model-id", "zai-org/GLM-5.2",
        "--task-json-inline", json.dumps(task),
        "--dry-run",
    ])
print(code)
print(buf.getvalue())
"@ | Set-Content -LiteralPath $probe -Encoding UTF8

        $output = & python $probe
        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) | Should -Match '^1'
        ($output | Out-String) | Should -Match 'model_capacity_exceeded'
        ($output | Out-String) | Should -Match 'estimated_total_bytes'
        ($output | Out-String) | Should -Match '1500000000000'
    }

    It 'completes dry-run when the model capacity estimate is under the configured limit' {
        $probe = Join-Path $TestDrive 'capacity_success_probe.py'
        $workerPath = ($script:WorkerScript -replace '\\', '\\')
        @"
import contextlib
import io
import json
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("llm_worker", r"$workerPath")
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

mod.detect_gpu = lambda: {"available": True, "name": "NVIDIA A100-SXM4-80GB", "count": 1, "source": "test"}
mod.configure_cache = lambda task: {
    "drive_root": "/content/drive/MyDrive/winsmux-colab-llm",
    "model_root": "/content/drive/MyDrive/winsmux-colab-llm/models",
    "hf_cache_root": "/content/drive/MyDrive/winsmux-colab-llm/hf-cache",
    "artifact_root": str(Path(r"$($TestDrive -replace '\\', '\\')") / "artifacts"),
    "runtime_cache_root": "/content/winsmux-runtime-cache",
}
mod.estimate_hf_model_storage = lambda model_id, timeout=30.0: {
    "model_id": model_id,
    "safetensor_files": 2,
    "shard_count": 2,
    "sample_file": "model-00001-of-00002.safetensors",
    "sample_size_bytes": 1024,
    "estimated_total_bytes": 2048,
}

task = {
    "model_id": "example/small-model",
    "license_state": "not_required",
    "prompt": "capacity success probe",
}
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    code = mod.main([
        "--worker-id", "worker-1",
        "--run-id", "capacity-success-probe",
        "--model-id", "example/small-model",
        "--task-json-inline", json.dumps(task),
        "--dry-run",
    ])
print(code)
print(buf.getvalue())
"@ | Set-Content -LiteralPath $probe -Encoding UTF8

        $output = & python $probe
        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) | Should -Match '^0'
        ($output | Out-String) | Should -Match '"status":"succeeded"'
        ($output | Out-String) | Should -Match '"estimated_total_bytes":2048'
    }

    It 'does not treat missing Hugging Face size headers as a zero-byte model' {
        $probe = Join-Path $TestDrive 'missing_size_header_probe.py'
        $workerPath = ($script:WorkerScript -replace '\\', '\\')
        @"
import importlib.util

spec = importlib.util.spec_from_file_location("llm_worker", r"$workerPath")
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

class FakeResponse:
    headers = {}
    def __enter__(self):
        return self
    def __exit__(self, exc_type, exc, tb):
        return False

class FakeOpener:
    def open(self, request, timeout=30.0):
        return FakeResponse()

mod.urllib.request.build_opener = lambda *args, **kwargs: FakeOpener()
try:
    mod.head_linked_size("https://huggingface.co/example/model/resolve/main/model.safetensors")
except mod.InputError as exc:
    print(exc.code)
    print(exc.message)
"@ | Set-Content -LiteralPath $probe -Encoding UTF8

        $output = & python $probe
        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) | Should -Match 'model_size_unavailable'
        ($output | Out-String) | Should -Match 'size header was unavailable'
    }

    It 'estimates sharded PyTorch bin checkpoints instead of rejecting non-safetensor weights' {
        $probe = Join-Path $TestDrive 'pytorch_bin_capacity_probe.py'
        $workerPath = ($script:WorkerScript -replace '\\', '\\')
        @"
import importlib.util
import json

spec = importlib.util.spec_from_file_location("llm_worker", r"$workerPath")
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

mod.read_json_url = lambda url, timeout=30.0: {
    "siblings": [
        {"rfilename": "README.md"},
        {"rfilename": "pytorch_model-00001-of-00003.bin"},
        {"rfilename": "pytorch_model-00002-of-00003.bin"},
        {"rfilename": "pytorch_model-00003-of-00003.bin"},
    ]
}
mod.head_linked_size = lambda url, timeout=30.0: 100
print(json.dumps(mod.estimate_hf_model_storage("example/pytorch-bin", timeout=1.0), sort_keys=True))
"@ | Set-Content -LiteralPath $probe -Encoding UTF8

        $output = & python $probe
        $LASTEXITCODE | Should -Be 0
        $text = $output | Out-String
        $text | Should -Match '"weight_files": 3'
        $text | Should -Match '"safetensor_files": 0'
        $text | Should -Match '"estimated_total_bytes": 300'
    }

    It 'rejects non-finite metadata timeout configuration before network use' {
        $probe = Join-Path $TestDrive 'finite_timeout_probe.py'
        $workerPath = ($script:WorkerScript -replace '\\', '\\')
        @"
import importlib.util
import os

spec = importlib.util.spec_from_file_location("llm_worker", r"$workerPath")
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

os.environ["WINSMUX_COLAB_LLM_HF_METADATA_TIMEOUT_SECONDS"] = "inf"
print(mod.positive_float_env("WINSMUX_COLAB_LLM_HF_METADATA_TIMEOUT_SECONDS", 30.0))
"@ | Set-Content -LiteralPath $probe -Encoding UTF8

        $output = & python $probe
        $LASTEXITCODE | Should -Be 0
        ($output | Out-String).Trim() | Should -Be '30.0'
    }

    It 'redacts preflight InputError details before printing worker results' {
        $probe = Join-Path $TestDrive 'capacity_redaction_probe.py'
        $workerPath = ($script:WorkerScript -replace '\\', '\\')
        @"
import contextlib
import io
import json
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("llm_worker", r"$workerPath")
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

mod.detect_gpu = lambda: {"available": True, "name": "NVIDIA A100-SXM4-80GB", "count": 1, "source": "test"}
mod.configure_cache = lambda task: {
    "drive_root": "/content/drive/MyDrive/winsmux-colab-llm",
    "model_root": "/content/drive/MyDrive/winsmux-colab-llm/models",
    "hf_cache_root": "/content/drive/MyDrive/winsmux-colab-llm/hf-cache",
    "artifact_root": str(Path(r"$($TestDrive -replace '\\', '\\')") / "artifacts"),
    "runtime_cache_root": "/content/winsmux-runtime-cache",
}

def fail_capacity(model_id, timeout=30.0):
    raise mod.InputError(
        "model_size_unavailable",
        "bad /content/drive/MyDrive/private user@example.com",
        details={"path": "/content/drive/MyDrive/private/file", "email": "user@example.com"},
    )

mod.estimate_hf_model_storage = fail_capacity

task = {
    "model_id": "zai-org/GLM-5.2",
    "license_state": "not_required",
    "prompt": "capacity redaction probe",
}
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    code = mod.main([
        "--worker-id", "worker-1",
        "--run-id", "capacity-redaction-probe",
        "--model-id", "zai-org/GLM-5.2",
        "--task-json-inline", json.dumps(task),
        "--dry-run",
    ])
print(code)
print(buf.getvalue())
"@ | Set-Content -LiteralPath $probe -Encoding UTF8

        $output = & python $probe
        $LASTEXITCODE | Should -Be 0
        $text = $output | Out-String
        $text | Should -Match '^1'
        $text | Should -Match 'model_size_unavailable'
        $text | Should -Match '\[EMAIL_REDACTED\]'
        $text | Should -Match '\[DRIVE_PATH_REDACTED\]'
        $text | Should -Not -Match 'user@example\.com'
        $text | Should -Not -Match '/content/drive/MyDrive/private'
    }

    It 'plans a Colab MCP run and exposes logs without connecting to Colab' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $stateRoot = Join-Path $TestDrive 'adapter-state'
        $outputDir = Join-Path $TestDrive 'adapter-output'
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'plan_only'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                license_state = 'accepted'
                prompt = 'hello user@example.com /content/drive/MyDrive/private'
                local_note = 'check C:\Users\First Last\secret.txt'
                forward_local_note = 'check C:/Users/Alice/secret.txt'
                drive_note = 'check G:/My Drive/private.txt'
                encoded_note = 'https://example.invalid/?email=user%40example.com&path=C%3A%2FUsers%2FAlice%2Fsecret.txt'
                api_note = 'api_key=secret-value'
                authorization = 'Bearer direct-secret-token'
                headers = @{
                    Authorization = 'Bearer nested-secret-token'
                }
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-1 `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            $payload = $runOutput | ConvertFrom-Json
            $payload.status | Should -Be 'planned'
            $payload.mode | Should -Be 'plan_only'
            $payload.script | Should -Be 'llm_worker.py'
            $planPath = Join-Path $outputDir 'colab-adapter-plan.py'
            Test-Path -LiteralPath $planPath | Should -BeTrue
            $planSource = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8
            $planSource | Should -Match '"--run-id", "run-1"'
            $planSource | Should -Match '_winsmux_env\[''PYTHONUNBUFFERED''\] = ''1'''
            $planSource | Should -Match 'subprocess\.Popen\(_winsmux_argv'
            $planSource | Should -Match 'for _winsmux_line in _winsmux_proc\.stdout'
            $planSource | Should -Match '\[EMAIL_REDACTED\]'
            $planSource | Should -Match '\[DRIVE_PATH_REDACTED\]'
            $planSource | Should -Match '\[LOCAL_PATH_REDACTED\]'
            $planSource | Should -Match '\[URL_ENCODED_SENSITIVE_REDACTED\]'
            $planSource | Should -Match 'api_key=\[REDACTED\]'
            $planSource | Should -Match 'Bearer \[REDACTED\]'
            $planSource | Should -Not -Match 'user@example\.com'
            $planSource | Should -Not -Match '/content/drive/MyDrive/private'
            $planSource | Should -Not -Match 'C:\\\\Users'
            $planSource | Should -Not -Match 'C:/Users/Alice'
            $planSource | Should -Not -Match 'G:/My Drive/private'
            $planSource | Should -Not -Match 'user%40example\.com'
            $planSource | Should -Not -Match 'secret-value'
            $planSource | Should -Not -Match 'direct-secret-token'
            $planSource | Should -Not -Match 'nested-secret-token'
            $planSource | Should -Not -Match 'runpy\.run_path'
            $compileOutput = & python -m py_compile $planPath 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($compileOutput -join "`n")
            Test-Path -LiteralPath (Join-Path $outputDir 'adapter-result.json') | Should -BeTrue

            $logs = & pwsh -NoProfile -File $script:Adapter logs --session test-session --run-id run-1
            $LASTEXITCODE | Should -Be 0
            ($logs | ConvertFrom-Json).status | Should -Be 'planned'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
        }
    }

    It 'redacts equals-form inline task JSON and plus-encoded secrets before plan persistence' {
        $probe = Join-Path $TestDrive 'adapter_redaction_probe.py'
        $adapterPath = ((Join-Path $script:RepoRoot 'scripts/google_colab_cli_adapter.py') -replace '\\', '\\')
        @"
import importlib.util
import json

spec = importlib.util.spec_from_file_location("google_colab_cli_adapter", r"$adapterPath")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

task = {
    "password": "foo bar",
    "encoded_auth": "authorization%3A+Bearer+plus-secret",
    "encoded_drive": "G%3A%2FMy+Drive%2Fprivate.txt",
}
args = [
    "--task-json-inline=" + json.dumps(task),
    "--task-json=C:/Users/Alice/private.json",
]
print(json.dumps(module.redact_script_args(args), ensure_ascii=False))
"@ | Set-Content -LiteralPath $probe -Encoding UTF8

        $output = (& python $probe) -join "`n"
        $LASTEXITCODE | Should -Be 0
        $redactedArgs = $output | ConvertFrom-Json
        $inlineArg = [string]$redactedArgs[0]
        $inlineTask = $inlineArg.Substring('--task-json-inline='.Length) | ConvertFrom-Json
        $output | Should -Match '--task-json-inline='
        $output | Should -Match '\[URL_ENCODED_SENSITIVE_REDACTED\]'
        $output | Should -Match '\[LOCAL_PATH_REDACTED\]'
        $inlineTask.password | Should -Be '[REDACTED]'
        $inlineTask.encoded_auth | Should -Be '[URL_ENCODED_SENSITIVE_REDACTED]'
        $inlineTask.encoded_drive | Should -Be '[URL_ENCODED_SENSITIVE_REDACTED]'
        $output | Should -Not -Match 'foo bar'
        $output | Should -Not -Match 'plus-secret'
        $output | Should -Not -Match 'G%3A%2FMy\+Drive'
        $output | Should -Not -Match 'C:/Users/Alice'
    }

    It 'extracts only real worker stage output lines from Colab page text' {
        $adapterPath = Join-Path $script:RepoRoot 'scripts/google_colab_cli_adapter.py'
        $python = @"
import importlib.util
import json
import pathlib
from datetime import datetime, timezone
spec = importlib.util.spec_from_file_location("adapter", pathlib.Path(r"$adapterPath"))
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
text = '''
_stage('source code literal')
print("WINSMUX_COLAB_LLM_STAGE " + json.dumps(payload, ensure_ascii=False, sort_keys=True))
WINSMUX_COLAB_LLM_STAGE {"at":"2026-06-15T01:03:04.432575Z","stage":"worker_start","worker_id":"stale"}
WINSMUX_COLAB_LLM_STAGE {"stage":"model_load_begin","model_id":"Qwen/Qwen3-32B"}
WINSMUX_COLAB_LLM_STAGE {"at":"2026-06-15T01:20:27.779750Z","stage":"generation_begin","model_id":"Qwen/Qwen3-32B"}
'''
print(json.dumps(module.extract_worker_stage_lines(text, not_before_utc=datetime(2026, 6, 15, 1, 10, 0, tzinfo=timezone.utc)), ensure_ascii=False))
"@
        $output = $python | python -
        $LASTEXITCODE | Should -Be 0
        $stages = @($output | ConvertFrom-Json)
        $stages.Count | Should -Be 1
        $stages[0] | Should -Match '"model_id": "Qwen/Qwen3-32B"'
        $stages[0] | Should -Match '"stage": "generation_begin"'
        $stages[0] | Should -Not -Match 'source code literal'
        $stages[0] | Should -Not -Match 'stale'
    }

    It 'replaces file collisions while staging directory uploads and downloads' {
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $stateRoot = Join-Path $TestDrive 'adapter-state-collisions'
        try {
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot

            $sourceDir = Join-Path $TestDrive 'source-dir'
            New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null
            'payload' | Set-Content -LiteralPath (Join-Path $sourceDir 'payload.txt') -Encoding UTF8

            $uploadTargetFile = Join-Path $stateRoot 'test-session\run-2\uploads\source-dir'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $uploadTargetFile) | Out-Null
            'stale file' | Set-Content -LiteralPath $uploadTargetFile -Encoding UTF8

            $uploadOutput = & pwsh -NoProfile -File $script:Adapter upload `
                --session test-session `
                --run-id run-2 `
                --source $sourceDir `
                --dest /content/source-dir

            $LASTEXITCODE | Should -Be 0
            ($uploadOutput | ConvertFrom-Json).status | Should -Be 'uploaded'
            Test-Path -LiteralPath (Join-Path $uploadTargetFile 'payload.txt') | Should -BeTrue

            $downloadSource = Join-Path $stateRoot 'test-session\run-2\uploads\result-dir'
            New-Item -ItemType Directory -Force -Path $downloadSource | Out-Null
            'result' | Set-Content -LiteralPath (Join-Path $downloadSource 'result.txt') -Encoding UTF8
            $downloadTarget = Join-Path $TestDrive 'download-target'
            'stale download file' | Set-Content -LiteralPath $downloadTarget -Encoding UTF8

            $downloadOutput = & pwsh -NoProfile -File $script:Adapter download `
                --session test-session `
                --run-id run-2 `
                --source /content/result-dir `
                --dest $downloadTarget

            $LASTEXITCODE | Should -Be 0
            ($downloadOutput | ConvertFrom-Json).status | Should -Be 'downloaded'
            Test-Path -LiteralPath (Join-Path $downloadTarget 'result.txt') | Should -BeTrue
        } finally {
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
        }
    }

    It 'passes the raw plan through stdin to the sibling Colab executor when output dir is relative' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-relative-plan'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-relative-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import json
import os
import sys

def execute_llm_plan(plan, mode, **kwargs):
    if len(sys.argv) != 2 or sys.argv[1] != "execute_with_evidence":
        raise RuntimeError(f"unexpected argv: {sys.argv!r}")
    if "llm_worker.py" not in plan:
        raise RuntimeError("plan was not passed through stdin")
    return json.dumps({"stdout": "FAKE_EXECUTE_OK", "mode": mode, "plan_length": len(plan)})
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $relativeOutputDir = Resolve-Path -LiteralPath $outputDir -Relative
            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from relative path test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-relative `
                --output-dir $relativeOutputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'FAKE_EXECUTE_OK'
            Get-Content -LiteralPath (Join-Path $outputDir 'stdout.log') -Raw -Encoding UTF8 | Should -Match 'FAKE_EXECUTE_OK'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'uses the safe Colab executor path instead of nesting get_session inside the pool loop' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousProxyTimeout = $env:WINSMUX_COLAB_CLI_ADAPTER_PROXY_TIMEOUT_SEC
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-safe-executor'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-safe-executor'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-safe-executor-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import asyncio

def execute_llm_plan(*args, **kwargs):
    raise RuntimeError("nested executor should not be used")

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

def parse_gpu_from_text(stdout):
    return "NVIDIA A100"

def build_execution_evidence(**kwargs):
    return kwargs

async def _maybe_verify_kernel_bind(session, notebook_url):
    return True, "ok"

async def add_code_cell(session, code):
    return "cell-1"

async def run_code_cell(session, cell_id):
    return "ok"

async def read_cell_output(session, cell_id):
    return "SAFE_EXECUTOR_OK"

class ColabMcpPool:
    @classmethod
    def run(cls, coro):
        return asyncio.run(coro)

    @classmethod
    async def _connect_session(cls, proxy_timeout_sec, no_auto_browser):
        assert proxy_timeout_sec == 120.0
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_PROXY_TIMEOUT_SEC = 'nan'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from safe executor test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-safe-executor `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'SAFE_EXECUTOR_OK'
            Get-Content -LiteralPath (Join-Path $outputDir 'stdout.log') -Raw -Encoding UTF8 | Should -Match 'SAFE_EXECUTOR_OK'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousProxyTimeout) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PROXY_TIMEOUT_SEC -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PROXY_TIMEOUT_SEC = $previousProxyTimeout }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'falls back to the compatible executor when the safe executor contract is unavailable' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousTimeout = $env:WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-compatible-fallback'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-compatible-fallback'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-compatible-fallback-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import json

def execute_llm_plan(plan, selected_mode):
    return json.dumps({"stdout": "COMPAT_FALLBACK_OK", "mode": selected_mode, "plan_length": len(plan)})

class ColabMcpPool:
    pass
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC = 'inf'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from compatible fallback test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-compatible-fallback `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'COMPAT_FALLBACK_OK'
            Get-Content -LiteralPath (Join-Path $outputDir 'stdout.log') -Raw -Encoding UTF8 | Should -Match 'COMPAT_FALLBACK_OK'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousTimeout) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC = $previousTimeout }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'falls back when execute_with_evidence helpers are missing from the safe executor contract' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-missing-evidence-helpers'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-missing-evidence-helpers'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-missing-evidence-helpers-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import asyncio
import json

def execute_llm_plan(plan, mode):
    return json.dumps({"stdout": "MISSING_EVIDENCE_HELPERS_FALLBACK_OK", "mode": mode})

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

async def add_code_cell(session, code):
    return "cell-1"

async def run_code_cell(session, cell_id):
    return "ok"

async def read_cell_output(session, cell_id):
    return "SAFE_PATH_SHOULD_NOT_RUN"

class ColabMcpPool:
    @classmethod
    def run(cls, coro):
        return asyncio.run(coro)

    @classmethod
    async def _connect_session(cls, proxy_timeout_sec, no_auto_browser):
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from missing evidence helpers test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-missing-evidence-helpers `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'MISSING_EVIDENCE_HELPERS_FALLBACK_OK'
            ($runOutput | Out-String) | Should -Not -Match 'SAFE_PATH_SHOULD_NOT_RUN'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'falls back when kernel bind verification is requested but the helper is unavailable' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-missing-kernel-bind-helper'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-missing-kernel-bind-helper'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-missing-kernel-bind-helper-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import asyncio
import json

def execute_llm_plan(plan, mode):
    return json.dumps({"stdout": "MISSING_KERNEL_BIND_HELPER_FALLBACK_OK", "mode": mode})

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

def parse_gpu_from_text(stdout):
    return "NVIDIA A100"

def build_execution_evidence(**kwargs):
    return kwargs

async def add_code_cell(session, code):
    return "cell-1"

async def run_code_cell(session, cell_id):
    return "ok"

async def read_cell_output(session, cell_id):
    return "SAFE_PATH_SHOULD_NOT_RUN"

class ColabMcpPool:
    @classmethod
    def run(cls, coro):
        return asyncio.run(coro)

    @classmethod
    async def _connect_session(cls, proxy_timeout_sec, no_auto_browser):
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from missing kernel bind helper test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-missing-kernel-bind-helper `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'MISSING_KERNEL_BIND_HELPER_FALLBACK_OK'
            ($runOutput | Out-String) | Should -Not -Match 'SAFE_PATH_SHOULD_NOT_RUN'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'falls back when ColabMcpPool connection signature is incompatible with the safe executor' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-incompatible-connect-signature'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-incompatible-connect-signature'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-incompatible-connect-signature-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import asyncio
import json

def execute_llm_plan(plan, mode):
    return json.dumps({"stdout": "INCOMPATIBLE_CONNECT_SIGNATURE_FALLBACK_OK", "mode": mode})

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

def parse_gpu_from_text(stdout):
    return "NVIDIA A100"

def build_execution_evidence(**kwargs):
    return kwargs

async def _maybe_verify_kernel_bind(session, notebook_url):
    return True, "ok"

async def add_code_cell(session, code):
    return "cell-1"

async def run_code_cell(session, cell_id):
    return "ok"

async def read_cell_output(session, cell_id):
    return "SAFE_PATH_SHOULD_NOT_RUN"

class ColabMcpPool:
    @classmethod
    def run(cls, coro):
        return asyncio.run(coro)

    @classmethod
    async def _connect_session(cls):
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from incompatible connection signature test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-incompatible-connect-signature `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'INCOMPATIBLE_CONNECT_SIGNATURE_FALLBACK_OK'
            ($runOutput | Out-String) | Should -Not -Match 'SAFE_PATH_SHOULD_NOT_RUN'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'falls back when safe executor helpers are synchronous instead of coroutine functions' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-sync-safe-helpers'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-sync-safe-helpers'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-sync-safe-helpers-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import asyncio
import json

def execute_llm_plan(plan, mode):
    return json.dumps({"stdout": "SYNC_SAFE_HELPERS_FALLBACK_OK", "mode": mode})

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

def parse_gpu_from_text(stdout):
    return "NVIDIA A100"

def build_execution_evidence(**kwargs):
    return kwargs

def _maybe_verify_kernel_bind(session, notebook_url):
    return True, "ok"

def add_code_cell(session, code):
    return "cell-1"

def run_code_cell(session, cell_id):
    return "ok"

def read_cell_output(session, cell_id):
    return "SAFE_PATH_SHOULD_NOT_RUN"

class ColabMcpPool:
    @classmethod
    def run(cls, coro):
        return asyncio.run(coro)

    @classmethod
    async def _connect_session(cls, proxy_timeout_sec, no_auto_browser):
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from sync safe helpers test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-sync-safe-helpers `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'SYNC_SAFE_HELPERS_FALLBACK_OK'
            ($runOutput | Out-String) | Should -Not -Match 'SAFE_PATH_SHOULD_NOT_RUN'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'falls back when ColabMcpPool connection helper is synchronous' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-sync-connect-helper'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-sync-connect-helper'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-sync-connect-helper-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import asyncio
import json

def execute_llm_plan(plan, mode):
    return json.dumps({"stdout": "SYNC_CONNECT_HELPER_FALLBACK_OK", "mode": mode})

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

def parse_gpu_from_text(stdout):
    return "NVIDIA A100"

def build_execution_evidence(**kwargs):
    return kwargs

async def _maybe_verify_kernel_bind(session, notebook_url):
    return True, "ok"

async def add_code_cell(session, code):
    return "cell-1"

async def run_code_cell(session, cell_id):
    return "ok"

async def read_cell_output(session, cell_id):
    return "SAFE_PATH_SHOULD_NOT_RUN"

class ColabMcpPool:
    @classmethod
    def run(cls, coro):
        return asyncio.run(coro)

    @classmethod
    def _connect_session(cls, proxy_timeout_sec, no_auto_browser):
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from sync connect helper test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-sync-connect-helper `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'SYNC_CONNECT_HELPER_FALLBACK_OK'
            ($runOutput | Out-String) | Should -Not -Match 'SAFE_PATH_SHOULD_NOT_RUN'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'falls back when ColabMcpPool run does not accept a coroutine argument' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-incompatible-run-signature'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-incompatible-run-signature'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-incompatible-run-signature-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import json

def execute_llm_plan(plan, mode):
    return json.dumps({"stdout": "INCOMPATIBLE_RUN_SIGNATURE_FALLBACK_OK", "mode": mode})

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

def parse_gpu_from_text(stdout):
    return "NVIDIA A100"

def build_execution_evidence(**kwargs):
    return kwargs

async def _maybe_verify_kernel_bind(session, notebook_url):
    return True, "ok"

async def add_code_cell(session, code):
    return "cell-1"

async def run_code_cell(session, cell_id):
    return "ok"

async def read_cell_output(session, cell_id):
    return "SAFE_PATH_SHOULD_NOT_RUN"

class ColabMcpPool:
    @classmethod
    def run(cls):
        return "BAD_RUN_SIGNATURE"

    @classmethod
    async def _connect_session(cls, proxy_timeout_sec, no_auto_browser):
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from incompatible run signature test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-incompatible-run-signature `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'INCOMPATIBLE_RUN_SIGNATURE_FALLBACK_OK'
            ($runOutput | Out-String) | Should -Not -Match 'SAFE_PATH_SHOULD_NOT_RUN'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'falls back when ColabMcpPool run is an instance method' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-instance-run'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-instance-run'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-instance-run-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import json

def execute_llm_plan(plan, mode):
    return json.dumps({"stdout": "INSTANCE_RUN_FALLBACK_OK", "mode": mode})

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

def parse_gpu_from_text(stdout):
    return "NVIDIA A100"

def build_execution_evidence(**kwargs):
    return kwargs

async def _maybe_verify_kernel_bind(session, notebook_url):
    return True, "ok"

async def add_code_cell(session, code):
    return "cell-1"

async def run_code_cell(session, cell_id):
    return "ok"

async def read_cell_output(session, cell_id):
    return "SAFE_PATH_SHOULD_NOT_RUN"

class ColabMcpPool:
    def run(self, coro):
        return "BAD_INSTANCE_RUN"

    @classmethod
    async def _connect_session(cls, proxy_timeout_sec, no_auto_browser):
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from instance run test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-instance-run `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'INSTANCE_RUN_FALLBACK_OK'
            ($runOutput | Out-String) | Should -Not -Match 'SAFE_PATH_SHOULD_NOT_RUN'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'falls back when ColabMcpPool run returns an awaitable payload' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-awaitable-run'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-awaitable-run'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-awaitable-run-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import json

def execute_llm_plan(plan, mode):
    return json.dumps({"stdout": "AWAITABLE_RUN_FALLBACK_OK", "mode": mode})

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

def parse_gpu_from_text(stdout):
    return "NVIDIA A100"

def build_execution_evidence(**kwargs):
    return kwargs

async def _maybe_verify_kernel_bind(session, notebook_url):
    return True, "ok"

async def add_code_cell(session, code):
    return "cell-1"

async def run_code_cell(session, cell_id):
    return "ok"

async def read_cell_output(session, cell_id):
    return "SAFE_PATH_SHOULD_NOT_RUN"

class ColabMcpPool:
    @classmethod
    def run(cls, coro):
        return coro

    @classmethod
    async def _connect_session(cls, proxy_timeout_sec, no_auto_browser):
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from awaitable run test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-awaitable-run `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'AWAITABLE_RUN_FALLBACK_OK'
            ($runOutput | Out-String) | Should -Not -Match 'SAFE_PATH_SHOULD_NOT_RUN'
            Get-Content -LiteralPath (Join-Path $outputDir 'stderr.log') -Raw -Encoding UTF8 | Should -Match 'safe_executor_awaitable_result_fallback'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'accepts a JSON string returned by the safe executor' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-json-safe-payload'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-json-safe-payload'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-json-safe-payload-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import json

def execute_llm_plan(*args, **kwargs):
    raise RuntimeError("fallback executor should not be used")

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

def parse_gpu_from_text(stdout):
    return "NVIDIA A100"

def build_execution_evidence(**kwargs):
    return kwargs

async def _maybe_verify_kernel_bind(session, notebook_url):
    return True, "ok"

async def add_code_cell(session, code):
    return "cell-1"

async def run_code_cell(session, cell_id):
    return "ok"

async def read_cell_output(session, cell_id):
    return "SAFE_PATH_SHOULD_NOT_RUN"

class ColabMcpPool:
    @classmethod
    def run(cls, coro):
        coro.close()
        return json.dumps({"ok": True, "stdout": "JSON_SAFE_PAYLOAD_OK", "mode": "execute_with_evidence"})

    @classmethod
    async def _connect_session(cls, proxy_timeout_sec, no_auto_browser):
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from JSON safe payload test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-json-safe-payload `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'JSON_SAFE_PAYLOAD_OK'
            ($runOutput | Out-String) | Should -Not -Match 'SAFE_PATH_SHOULD_NOT_RUN'
            Get-Content -LiteralPath (Join-Path $outputDir 'stderr.log') -Raw -Encoding UTF8 | Should -Not -Match 'safe_executor_payload_normalize_error'
            $result = Get-Content -LiteralPath (Join-Path $outputDir 'adapter-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.status | Should -Be 'succeeded'
            $result.exit_code | Should -Be 0
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'fails when the safe executor returns an invalid payload type' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-invalid-safe-payload'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-invalid-safe-payload'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-invalid-safe-payload-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
def execute_llm_plan(*args, **kwargs):
    raise RuntimeError("nested executor should not be used")

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

def parse_gpu_from_text(stdout):
    return "NVIDIA A100"

def build_execution_evidence(**kwargs):
    return kwargs

async def _maybe_verify_kernel_bind(session, notebook_url):
    return True, "ok"

async def add_code_cell(session, code):
    return "cell-1"

async def run_code_cell(session, cell_id):
    return "ok"

async def read_cell_output(session, cell_id):
    return "SAFE_PATH_SHOULD_NOT_BE_WRITTEN"

class ColabMcpPool:
    @classmethod
    def run(cls, coro):
        coro.close()
        return "BAD_PAYLOAD"

    @classmethod
    async def _connect_session(cls, proxy_timeout_sec, no_auto_browser):
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from invalid safe payload test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-invalid-safe-payload `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm 2>&1

            $LASTEXITCODE | Should -Be 1
            ($runOutput | Out-String) | Should -Match 'invalid safe executor result type'
            $result = Get-Content -LiteralPath (Join-Path $outputDir 'adapter-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.status | Should -Be 'failed'
            $result.exit_code | Should -Be 1

            (Get-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Raw -Encoding UTF8).Replace('return "BAD_PAYLOAD"', 'return "[]"') |
                Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8
            $jsonNonObjectOutputDir = Join-Path $TestDrive 'adapter-invalid-safe-json-non-object-output'
            New-Item -ItemType Directory -Force -Path $jsonNonObjectOutputDir | Out-Null
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-invalid-safe-json-non-object `
                --output-dir $jsonNonObjectOutputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm 2>&1

            $LASTEXITCODE | Should -Be 1
            ($runOutput | Out-String) | Should -Match 'JSON payload is not an object'
            $result = Get-Content -LiteralPath (Join-Path $jsonNonObjectOutputDir 'adapter-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.status | Should -Be 'failed'
            $result.exit_code | Should -Be 1
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'marks safe executor ERROR output as a failed adapter run' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-safe-executor-error'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-safe-executor-error'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-safe-executor-error-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import asyncio

def execute_llm_plan(*args, **kwargs):
    raise RuntimeError("nested executor should not be used")

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

def parse_gpu_from_text(stdout):
    return "NVIDIA A100"

def build_execution_evidence(**kwargs):
    return kwargs

async def _maybe_verify_kernel_bind(session, notebook_url):
    return True, "ok"

async def add_code_cell(session, code):
    return "cell-1"

async def run_code_cell(session, cell_id):
    return "ok"

async def read_cell_output(session, cell_id):
    return "ERROR: worker failed"

class ColabMcpPool:
    @classmethod
    def run(cls, coro):
        return asyncio.run(coro)

    @classmethod
    async def _connect_session(cls, proxy_timeout_sec, no_auto_browser):
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from safe executor error test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-safe-executor-error `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm 2>&1

            $LASTEXITCODE | Should -Be 1
            ($runOutput | Out-String) | Should -Match 'worker failed'
            $result = Get-Content -LiteralPath (Join-Path $outputDir 'adapter-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.status | Should -Be 'failed'
            $result.exit_code | Should -Be 1
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'redacts sensitive Colab URLs emails and local paths from execution evidence' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-redaction'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-redaction'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-redaction-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
@'
import json
import sys

def execute_llm_plan(plan, mode, **kwargs):
    print('"Authorization":"Bearer stderr-secret-token" api_key=stderr-secret-value access_token=stderr-access-value', file=sys.stderr, flush=True)
    return json.dumps({
                "stdout": "user@example.com https://colab.research.google.com/drive/abc#mcpProxyToken=secret&mcpProxyPort=1\nC:\\Users\\First Last\\private\\file.txt\n/content/drive/MyDrive/private\nAuthorization: Bearer stdout-secret-token api_key=stdout-secret-value access_token=stdout-access-value",
    })
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from redaction test'
            } | ConvertTo-Json -Compress
            & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-redaction `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm | Out-Null

            $LASTEXITCODE | Should -Be 0
            $stdout = Get-Content -LiteralPath (Join-Path $outputDir 'stdout.log') -Raw -Encoding UTF8
            $stderr = Get-Content -LiteralPath (Join-Path $outputDir 'stderr.log') -Raw -Encoding UTF8
            $stdout | Should -Match '\[EMAIL_REDACTED\]'
            $stdout | Should -Match '\[COLAB_MCP_URL_REDACTED\]'
            $stdout | Should -Match '\[LOCAL_PATH_REDACTED\]'
            $stdout | Should -Match '\[DRIVE_PATH_REDACTED\]'
            $stdout | Should -Match 'Authorization: Bearer \[REDACTED\]'
            $stdout | Should -Match 'api_key=\[REDACTED\]'
            $stdout | Should -Match 'access_token=\[REDACTED\]'
            $stdout | Should -Not -Match 'user@example\.com'
            $stdout | Should -Not -Match 'mcpProxyToken=secret'
            $stdout | Should -Not -Match 'C:\\Users\\First Last'
            $stdout | Should -Not -Match 'stdout-secret'
            $stderr | Should -Match '"Authorization":"Bearer \[REDACTED\]'
            $stderr | Should -Match 'api_key=\[REDACTED\]'
            $stderr | Should -Match 'access_token=\[REDACTED\]'
            $stderr | Should -Not -Match 'stderr-secret'
            $stderr | Should -Not -Match 'stderr-access'
            $result = Get-Content -LiteralPath (Join-Path $outputDir 'adapter-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.stdout | Should -Match '\[EMAIL_REDACTED\]'
            $result.stdout | Should -Match '\[COLAB_MCP_URL_REDACTED\]'
            $result.stdout | Should -Match '\[LOCAL_PATH_REDACTED\]'
            $result.stdout | Should -Match '\[DRIVE_PATH_REDACTED\]'
            $result.stdout | Should -Match 'Authorization: Bearer \[REDACTED\]'
            $result.stdout | Should -Match 'api_key=\[REDACTED\]'
            $result.stdout | Should -Match 'access_token=\[REDACTED\]'
            $result.stderr | Should -Match '"Authorization":"Bearer \[REDACTED\]'
            $result.stderr | Should -Match 'api_key=\[REDACTED\]'
            $result.stderr | Should -Match 'access_token=\[REDACTED\]'
            $result.stdout | Should -Not -Match 'user@example\.com'
            $result.stdout | Should -Not -Match 'mcpProxyToken=secret'
            $result.stdout | Should -Not -Match 'C:\\Users\\First Last'
            $result.stdout | Should -Not -Match 'stdout-secret'
            $result.stderr | Should -Not -Match 'stderr-secret'
            $result.stderr | Should -Not -Match 'stderr-access'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'returns a failed result when the safe Colab executor path times out' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousTimeout = $env:WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-safe-timeout'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-safe-timeout'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-safe-timeout-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import asyncio
import time

def execute_llm_plan(*args, **kwargs):
    raise RuntimeError("fallback executor should not be used")

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

def parse_gpu_from_text(stdout):
    return "NVIDIA A100"

def build_execution_evidence(**kwargs):
    return kwargs

async def _maybe_verify_kernel_bind(session, notebook_url):
    return True, "ok"

async def add_code_cell(session, code):
    return "cell-1"

async def run_code_cell(session, cell_id):
    return "ok"

async def read_cell_output(session, cell_id):
    return "SAFE_EXECUTOR_TIMEOUT_SHOULD_NOT_RETURN"

class ColabMcpPool:
    @classmethod
    def run(cls, coro):
        print("SAFE_PARTIAL stdout Authorization: Bearer safe-stdout-secret", flush=True)
        time.sleep(5)
        return asyncio.run(coro)

    @classmethod
    async def _connect_session(cls, proxy_timeout_sec, no_auto_browser):
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC = '3'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from safe timeout test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-safe-timeout `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm 2>&1

            $LASTEXITCODE | Should -Be 124
            ($runOutput | Out-String) | Should -Match 'timed out'
            $stdout = Get-Content -LiteralPath (Join-Path $outputDir 'stdout.log') -Raw -Encoding UTF8
            $stderr = Get-Content -LiteralPath (Join-Path $outputDir 'stderr.log') -Raw -Encoding UTF8
            $stdout | Should -Match 'SAFE_PARTIAL stdout Authorization: Bearer \[REDACTED\]'
            $stdout | Should -Not -Match 'safe-stdout-secret'
            $stderr | Should -Match 'pool_run_begin'
            $result = Get-Content -LiteralPath (Join-Path $outputDir 'adapter-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.status | Should -Be 'failed'
            $result.exit_code | Should -Be 124
            $result.stdout | Should -Match 'SAFE_PARTIAL stdout Authorization: Bearer \[REDACTED\]'
            $result.stdout | Should -Not -Match 'safe-stdout-secret'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousTimeout) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC = $previousTimeout }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'returns a failed result when the sibling Colab executor times out' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousTimeout = $env:WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $stateRoot = Join-Path $TestDrive 'adapter-state-timeout'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-timeout'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-timeout-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import time

def execute_llm_plan(plan, mode, **kwargs):
    print("PARTIAL_PROGRESS before sleep", flush=True)
    time.sleep(10)
    return "{}"
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC = '3'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from timeout test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-timeout `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm 2>&1

            $LASTEXITCODE | Should -Be 124
            ($runOutput | Out-String) | Should -Match 'timed out'
            Get-Content -LiteralPath (Join-Path $outputDir 'stdout.log') -Raw -Encoding UTF8 | Should -Match 'PARTIAL_PROGRESS'
            $result = Get-Content -LiteralPath (Join-Path $outputDir 'adapter-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.status | Should -Be 'failed'
            $result.exit_code | Should -Be 124
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousTimeout) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC = $previousTimeout }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
        }
    }

    It 'runs Playwright setup before waiting for Colab proxy tools when enabled' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $previousPlaywrightSetup = $env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_SETUP
        $previousPlaywrightGpu = $env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_GPU
        $previousPlaywrightTimeout = $env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_TIMEOUT_SEC
        $stateRoot = Join-Path $TestDrive 'adapter-state-playwright-proxy'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-playwright-proxy'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-playwright-proxy-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
import asyncio

async def call_tool(session, name, args):
    return {}

async def ensure_proxy_tools(session, proxy_timeout_sec):
    from colab_llm_mcp import colab_playwright
    if not colab_playwright.CALLED:
        raise RuntimeError("proxy wait started before Playwright setup")
    return True

def colab_mcp_stdio_params(*args, **kwargs):
    return object()

class ColabMcpPool:
    @classmethod
    def run(cls, coro):
        return asyncio.run(coro)

    @classmethod
    async def _connect_session(cls, proxy_timeout_sec, no_auto_browser):
        await call_tool(None, "open_colab_browser_connection", {})
        await ensure_proxy_tools(None, proxy_timeout_sec)
        return object()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'colab_mcp_pool.py') -Encoding UTF8
            @'
CALLED = False

class Result:
    ok = True
    message = "fake Playwright setup ok"
    screenshot = ""

def run_colab_playwright_setup(**kwargs):
    global CALLED
    CALLED = True
    if kwargs.get("gpu") != "A100":
        raise RuntimeError("unexpected gpu")
    if not callable(globals().get("_click_mcp_connect")):
        raise RuntimeError("MCP Connect override was not installed")
    if not callable(globals().get("_connect_runtime_if_needed")):
        raise RuntimeError("runtime connect override was not installed")
    return Result()
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'colab_playwright.py') -Encoding UTF8
            @'
from colab_llm_mcp.colab_mcp_pool import ColabMcpPool

def execute_llm_plan(*args, **kwargs):
    raise RuntimeError("fallback executor should not run")

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

def parse_gpu_from_text(stdout):
    return "NVIDIA A100"

def build_execution_evidence(**kwargs):
    return kwargs

async def _maybe_verify_kernel_bind(session, notebook_url):
    return True, "ok"

async def add_code_cell(session, code):
    return "cell-1"

async def run_code_cell(session, cell_id):
    return "ok"

async def read_cell_output(session, cell_id):
    return "PLAYWRIGHT_PROXY_OK"
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source
            $env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_SETUP = '1'
            $env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_GPU = 'A100'
            $env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_TIMEOUT_SEC = '1'

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from playwright proxy setup test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-playwright-proxy `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'PLAYWRIGHT_PROXY_OK'
            $stderr = Get-Content -LiteralPath (Join-Path $outputDir 'stderr.log') -Raw -Encoding UTF8
            $stderr | Should -Match 'playwright_setup_begin'
            $stderr | Should -Match 'playwright_setup_done'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
            if ($null -eq $previousPlaywrightSetup) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_SETUP -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_SETUP = $previousPlaywrightSetup }
            if ($null -eq $previousPlaywrightGpu) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_GPU -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_GPU = $previousPlaywrightGpu }
            if ($null -eq $previousPlaywrightTimeout) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_TIMEOUT_SEC -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_TIMEOUT_SEC = $previousPlaywrightTimeout }
        }
    }

    It 'uses the direct browser path when explicitly enabled' {
        $previousMode = $env:WINSMUX_COLAB_CLI_ADAPTER_MODE
        $previousStateRoot = $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT
        $previousColabRepo = $env:WINSMUX_COLAB_MCP_REPO
        $previousAdapterPython = $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON
        $previousPythonPath = $env:PYTHONPATH
        $previousDirectBrowser = $env:WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER
        $previousDirectBrowserDryStdout = $env:WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER_DRY_STDOUT
        $stateRoot = Join-Path $TestDrive 'adapter-state-direct-browser'
        $fakeColabRepo = Join-Path $TestDrive 'fake-colab-direct-browser'
        $fakePackage = Join-Path $fakeColabRepo 'src\colab_llm_mcp'
        $outputDir = Join-Path $TestDrive 'adapter-direct-browser-output'
        New-Item -ItemType Directory -Force -Path $fakePackage | Out-Null
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        try {
            '' | Set-Content -LiteralPath (Join-Path $fakeColabRepo 'pyproject.toml') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $fakePackage '__init__.py') -Encoding UTF8
            @'
def execute_llm_plan(*args, **kwargs):
    raise RuntimeError("compatible executor should not run")

def extract_plan_code(plan):
    return plan

def resolve_colab_notebook_url():
    return "https://colab.research.google.com/drive/test-notebook"

class ColabMcpPool:
    pass
'@ | Set-Content -LiteralPath (Join-Path $fakePackage 'execute.py') -Encoding UTF8

            $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = 'execute_with_evidence'
            $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $stateRoot
            $env:WINSMUX_COLAB_MCP_REPO = $fakeColabRepo
            $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = (Get-Command python).Source
            $env:WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER = '1'
            $env:WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER_DRY_STDOUT = '{"schema_version":"winsmux.colab_llm.result.v1","status":"succeeded","run_id":"run-direct-browser","output":"DIRECT_BROWSER_OK"}'

            $task = @{
                model_id = 'Qwen/Qwen3-32B'
                prompt = 'hello from direct browser path test'
            } | ConvertTo-Json -Compress
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-direct-browser `
                --output-dir $outputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm

            $LASTEXITCODE | Should -Be 0
            ($runOutput | Out-String) | Should -Match 'DIRECT_BROWSER_OK'
            $stderr = Get-Content -LiteralPath (Join-Path $outputDir 'stderr.log') -Raw -Encoding UTF8
            $stderr | Should -Match 'direct_browser_begin'
            $stderr | Should -Match 'direct_browser_done'
            $stderr | Should -Not -Match 'safe_executor_begin'
            $progress = Get-Content -LiteralPath (Join-Path $outputDir 'progress.jsonl') -Raw -Encoding UTF8
            $progress | Should -Match '"stage": "command_run_execute_plan_begin"'
            $progress | Should -Match '"stage": "direct_browser_enter"'
            $progress | Should -Match '"stage": "direct_browser_dry_run"'
            $progress | Should -Not -Match 'mcpProxyToken='
            $progress | Should -Not -Match 'Users\\\\'

            $badOutputDir = Join-Path $TestDrive 'adapter-direct-browser-bad-output'
            New-Item -ItemType Directory -Force -Path $badOutputDir | Out-Null
            $env:WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER_DRY_STDOUT = 'not a winsmux result marker'
            $runOutput = & pwsh -NoProfile -File $script:Adapter run `
                --session test-session `
                --script $script:WorkerScript `
                --run-id run-direct-browser-bad `
                --output-dir $badOutputDir `
                --task-json-inline $task `
                --worker-id worker-1 `
                --model-id Qwen/Qwen3-32B `
                --runtime-engine vllm 2>&1

            $LASTEXITCODE | Should -Be 1
            ($runOutput | Out-String) | Should -Match 'direct browser dry run did not contain result marker'
            $result = Get-Content -LiteralPath (Join-Path $badOutputDir 'adapter-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.status | Should -Be 'failed'
            $result.exit_code | Should -Be 1
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
            if ($null -eq $previousColabRepo) { Remove-Item Env:WINSMUX_COLAB_MCP_REPO -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_MCP_REPO = $previousColabRepo }
            if ($null -eq $previousAdapterPython) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_PYTHON = $previousAdapterPython }
            if ($null -eq $previousPythonPath) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $previousPythonPath }
            if ($null -eq $previousDirectBrowser) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER = $previousDirectBrowser }
            if ($null -eq $previousDirectBrowserDryStdout) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER_DRY_STDOUT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER_DRY_STDOUT = $previousDirectBrowserDryStdout }
        }
    }
}
