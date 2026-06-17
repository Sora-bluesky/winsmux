$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Colab worker acceptance gate' {
    BeforeAll {
        $script:RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:RepoRoot)) {
            throw 'Failed to resolve repository root.'
        }

        $script:BridgePath = Join-Path $script:RepoRoot 'scripts\winsmux-core.ps1'
        $script:ColabLlmE2eRunnerPath = Join-Path $script:RepoRoot 'scripts\run-colab-llm-e2e.ps1'
    }

    BeforeEach {
        $script:AcceptanceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-colab-acceptance-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AcceptanceRoot -Force | Out-Null

        $script:PreviousColabCli = $env:WINSMUX_COLAB_CLI
        $script:PreviousColabAuth = $env:WINSMUX_COLAB_AUTH_STATE
        $script:PreviousColabGpu = $env:WINSMUX_COLAB_AVAILABLE_GPUS
        $script:PreviousTaskJson = $env:WINSMUX_TASK_JSON
        $script:PreviousCapacityEstimateJson = $env:WINSMUX_COLAB_LLM_E2E_CAPACITY_ESTIMATE_JSON
        $script:PreviousCapacityMaxBytes = $env:WINSMUX_COLAB_LLM_MAX_MODEL_BYTES
        $script:PreviousCapacityPreflight = $env:WINSMUX_COLAB_LLM_MODEL_CAPACITY_PREFLIGHT
    }

    AfterEach {
        if ($null -eq $script:PreviousColabCli) {
            Remove-Item Env:WINSMUX_COLAB_CLI -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_COLAB_CLI = $script:PreviousColabCli
        }

        if ($null -eq $script:PreviousColabAuth) {
            Remove-Item Env:WINSMUX_COLAB_AUTH_STATE -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_COLAB_AUTH_STATE = $script:PreviousColabAuth
        }

        if ($null -eq $script:PreviousColabGpu) {
            Remove-Item Env:WINSMUX_COLAB_AVAILABLE_GPUS -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_COLAB_AVAILABLE_GPUS = $script:PreviousColabGpu
        }

        if ($null -eq $script:PreviousTaskJson) {
            Remove-Item Env:WINSMUX_TASK_JSON -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_TASK_JSON = $script:PreviousTaskJson
        }

        if ($null -eq $script:PreviousCapacityEstimateJson) {
            Remove-Item Env:WINSMUX_COLAB_LLM_E2E_CAPACITY_ESTIMATE_JSON -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_COLAB_LLM_E2E_CAPACITY_ESTIMATE_JSON = $script:PreviousCapacityEstimateJson
        }

        if ($null -eq $script:PreviousCapacityMaxBytes) {
            Remove-Item Env:WINSMUX_COLAB_LLM_MAX_MODEL_BYTES -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_COLAB_LLM_MAX_MODEL_BYTES = $script:PreviousCapacityMaxBytes
        }

        if ($null -eq $script:PreviousCapacityPreflight) {
            Remove-Item Env:WINSMUX_COLAB_LLM_MODEL_CAPACITY_PREFLIGHT -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_COLAB_LLM_MODEL_CAPACITY_PREFLIGHT = $script:PreviousCapacityPreflight
        }

        if ($script:AcceptanceRoot -and (Test-Path -LiteralPath $script:AcceptanceRoot)) {
            Remove-Item -LiteralPath $script:AcceptanceRoot -Recurse -Force
        }
    }

    function script:Write-AcceptanceProjectConfig {
        @'
agent: codex
model: provider-default
worker-backend: colab_cli
'@ | Set-Content -LiteralPath (Join-Path $script:AcceptanceRoot '.winsmux.yaml') -Encoding UTF8
    }

    function script:Write-ColabLlmAcceptanceProjectConfig {
        @'
agent: claude
worker-backend: local
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: colab_llm
    worker-role: consult
    agent: colab-llm
    model-id: google/gemma-3-27b-it
    model-family: gemma
    runtime: colab
    runtime-engine: vllm
    gpu-preference: H100,A100
    session-name: winsmux_colab_llm_runtime
    drive-root: /content/drive/MyDrive/winsmux-colab-llm
    model-root: /content/drive/MyDrive/winsmux-colab-llm/models
    hf-cache-root: /content/drive/MyDrive/winsmux-colab-llm/hf-cache
    artifact-root: /content/drive/MyDrive/winsmux-colab-llm/artifacts
    runtime-cache-root: /content/winsmux-runtime-cache
    precision: bfloat16
    quantization: none
    license-state: accepted
    worktree-mode: managed
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: colab_llm
    worker-role: consult
    agent: colab-llm
    model-id: Qwen/Qwen3-32B
    model-family: qwen
    runtime: colab
    runtime-engine: vllm
    gpu-preference: H100,A100
    session-name: winsmux_colab_llm_runtime
    drive-root: /content/drive/MyDrive/winsmux-colab-llm
    license-state: not_required
    worktree-mode: managed
'@ | Set-Content -LiteralPath (Join-Path $script:AcceptanceRoot '.winsmux.yaml') -Encoding UTF8
    }

    function script:Write-LocalWorkerProjectConfig {
        @'
agent: claude
worker-backend: local
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: local
    worktree-mode: managed
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    worktree-mode: managed
'@ | Set-Content -LiteralPath (Join-Path $script:AcceptanceRoot '.winsmux.yaml') -Encoding UTF8
    }

    function script:New-AcceptanceFakeColabCli {
        $logPath = Join-Path $script:AcceptanceRoot 'fake-colab-commands.log'
        $fakeCli = Join-Path $script:AcceptanceRoot 'google-colab-cli.cmd'
        $content = @'
@echo off
>> "__LOG_PATH__" echo(%*
if "%1"=="new" (
  echo fake-colab new ok
  exit /b 0
)
if "%1"=="status" (
  echo fake-colab status H100
  exit /b 0
)
if "%1"=="stop" (
  echo fake-colab stop ok
  exit /b 0
)
if "%1"=="run" (
  echo fake-colab run ok
  exit /b 0
)
if "%1"=="exec" (
  echo fake-colab exec ok
  exit /b 0
)
if "%1"=="logs" (
  echo fake-colab logs ok
  exit /b 0
)
if "%1"=="log" (
  echo fake-colab log ok
  exit /b 0
)
if "%1"=="upload" (
  echo fake-colab upload ok
  exit /b 0
)
if "%1"=="download" (
  echo fake-colab download ok
  exit /b 0
)
echo fake-colab unknown %*
exit /b 1
'@
        $content.Replace('__LOG_PATH__', $logPath) | Set-Content -LiteralPath $fakeCli -Encoding ASCII
        $env:WINSMUX_COLAB_CLI = $fakeCli
        $env:WINSMUX_COLAB_AUTH_STATE = 'authenticated'
        $env:WINSMUX_COLAB_AVAILABLE_GPUS = 'A100'

        return [PSCustomObject]@{
            Path = $fakeCli
            Log  = $logPath
        }
    }

    function script:ConvertFrom-AcceptanceJsonOutput {
        param(
            [Parameter(Mandatory = $true)]
            [object[]]$Output
        )

        $raw = ($Output | Out-String)
        $clean = [regex]::Replace($raw, "`e\[[0-?]*[ -/]*[@-~]", '')
        $clean = [regex]::Replace($clean, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
        try {
            return $clean | ConvertFrom-Json -Depth 32 -ErrorAction Stop
        } catch {
        }

        $lines = @($clean -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $candidate = $lines[$i].Trim()
            if ($candidate.StartsWith('{') -or $candidate.StartsWith('[')) {
                try {
                    return $candidate | ConvertFrom-Json -Depth 32 -ErrorAction Stop
                } catch {
                    continue
                }
            }
        }

        throw "No JSON payload found in command output. Sanitized output: $clean"
    }

    function script:Invoke-AcceptanceJson {
        param(
            [Parameter(Mandatory = $true)]
            [string[]]$Arguments,
            [int]$ExpectedExitCode = 0
        )

        $output = & pwsh -NoProfile -File $script:BridgePath @Arguments 2>&1
        if ($LASTEXITCODE -ne $ExpectedExitCode) {
            throw "Expected exit code $ExpectedExitCode, got $LASTEXITCODE. Output: $($output | Out-String)"
        }
        return ConvertFrom-AcceptanceJsonOutput -Output $output
    }

    It 'runs the mock Colab worker acceptance flow without a real runtime' {
        Write-AcceptanceProjectConfig
        $fake = New-AcceptanceFakeColabCli

        & $fake.Path new --session winsmux_worker_2 | Out-Null
        & $fake.Path status --session winsmux_worker_2 | Out-Null

        $status = Invoke-AcceptanceJson -Arguments @('workers', 'status', '--json', '--project-dir', $script:AcceptanceRoot)
        @($status.workers).Count | Should -Be 6
        $worker2 = @($status.workers | Where-Object { $_.slot_id -eq 'worker-2' })[0]
        $worker2.backend | Should -Be 'colab_cli'
        $worker2.actual_gpu | Should -Be 'A100'
        $worker2.degraded_reason | Should -Be ''

        $doctor = Invoke-AcceptanceJson -Arguments @('workers', 'doctor', '--json', '--project-dir', $script:AcceptanceRoot)
        (@($doctor.checks | Where-Object { $_.label -eq 'config' })[0].status) | Should -Be 'pass'
        (@($doctor.checks | Where-Object { $_.label -eq 'google-colab-cli' })[0].status) | Should -Be 'pass'
        (@($doctor.checks | Where-Object { $_.label -eq 'colab auth' })[0].status) | Should -Be 'pass'

        $taskDir = Join-Path $script:AcceptanceRoot 'workers\colab'
        New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
        'print("hello from acceptance")' | Set-Content -LiteralPath (Join-Path $taskDir 'task.py') -Encoding UTF8

        $taskJson = '{"task_id":"TASK-477","title":"Colab acceptance mock"}'
        $env:WINSMUX_TASK_JSON = $taskJson
        $exec = Invoke-AcceptanceJson -Arguments @(
            'workers', 'exec', 'w2',
            '--script', 'workers/colab/task.py',
            '--run-id', 'acceptance-run',
            '--task-id', 'TASK-477',
            '--json',
            '--project-dir', $script:AcceptanceRoot
        )
        $exec.status | Should -Be 'succeeded'
        $exec.run_id | Should -Be 'acceptance-run'
        $exec.stdout_log | Should -Match '^\.winsmux/worker-runs/worker-2/acceptance-run/stdout\.log$'

        $localLog = Invoke-AcceptanceJson -Arguments @('workers', 'logs', 'w2', '--run-id', 'acceptance-run', '--json', '--project-dir', $script:AcceptanceRoot)
        $localLog.source | Should -Be 'local'
        $localLog.log | Should -Match 'fake-colab run ok'

        $remoteLog = Invoke-AcceptanceJson -Arguments @('workers', 'logs', 'w2', '--run-id', 'remote-only', '--json', '--project-dir', $script:AcceptanceRoot)
        $remoteLog.source | Should -Be 'google-colab-cli'
        $remoteLog.log | Should -Match 'fake-colab logs ok'

        $inputDir = Join-Path $script:AcceptanceRoot 'inputs'
        New-Item -ItemType Directory -Path (Join-Path $inputDir 'node_modules') -Force | Out-Null
        'safe' | Set-Content -LiteralPath (Join-Path $inputDir 'data.txt') -Encoding UTF8
        'SECRET=1' | Set-Content -LiteralPath (Join-Path $inputDir '.env') -Encoding UTF8
        'module' | Set-Content -LiteralPath (Join-Path $inputDir 'node_modules\dep.js') -Encoding UTF8

        $upload = Invoke-AcceptanceJson -Arguments @('workers', 'upload', 'w2', 'inputs', '--remote', '/content/inputs', '--allow-dir', 'inputs', '--run-id', 'acceptance-upload', '--json', '--project-dir', $script:AcceptanceRoot)
        $upload.status | Should -Be 'succeeded'
        $upload.uploaded_count | Should -Be 1
        $upload.excluded_count | Should -Be 2

        $manifestPath = Join-Path $script:AcceptanceRoot ($upload.manifest -replace '/', '\')
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
        @($manifest.files | ForEach-Object { $_.path }) | Should -Contain 'inputs/data.txt'
        @($manifest.excluded | ForEach-Object { $_.reason }) | Should -Contain 'secret_like_file'
        @($manifest.excluded | ForEach-Object { $_.reason }) | Should -Contain 'excluded_segment:node_modules'

        $download = Invoke-AcceptanceJson -Arguments @('workers', 'download', 'w2', '/content/out/result.json', '--run-id', 'acceptance-download', '--json', '--project-dir', $script:AcceptanceRoot)
        $download.status | Should -Be 'succeeded'
        $download.output | Should -Match '^\.winsmux/worker-downloads/worker-2/acceptance-download$'

        $attach = Invoke-AcceptanceJson -Arguments @('workers', 'attach', 'w2', '--json', '--project-dir', $script:AcceptanceRoot)
        $attach.results[0].status | Should -Be 'pending_launch'
        $attach.results[0].reason | Should -Be 'manifest_entry_missing'

        & $fake.Path stop --session winsmux_worker_2 | Out-Null
        $commandLog = Get-Content -LiteralPath $fake.Log -Raw -Encoding UTF8
        $commandLog | Should -Match '(?m)^new --session winsmux_worker_2'
        $commandLog | Should -Match '(?m)^status --session winsmux_worker_2'
        $commandLog | Should -Match '(?m)^run --session .+_worker_2'
        $commandLog | Should -Match '(?m)^logs --session .+_worker_2 --run-id remote-only'
        $commandLog | Should -Match '(?m)^upload --session .+_worker_2'
        $commandLog | Should -Match '(?m)^download --session .+_worker_2'
        $commandLog | Should -Match '(?m)^stop --session winsmux_worker_2'
    }

    It 'explains that the live Colab LLM E2E runner needs a private colab_llm project' {
        Write-LocalWorkerProjectConfig
        New-AcceptanceFakeColabCli | Out-Null

        $output = & pwsh -NoProfile -File $script:ColabLlmE2eRunnerPath -ProjectDir $script:AcceptanceRoot -PlanOnly -Json 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($output | Out-String) | Should -Match "worker slot worker-1 uses backend 'local', not colab_llm"
        ($output | Out-String) | Should -Match 'Pass -ProjectDir to a Git-ignored project configured'
        ($output | Out-String) | Should -Match 'requested colab_llm worker slots'
    }

    It 'plans a worker-1 only GLM-5.2 Colab E2E run' {
        Write-ColabLlmAcceptanceProjectConfig
        New-AcceptanceFakeColabCli | Out-Null
        $configPath = Join-Path $script:AcceptanceRoot '.winsmux.yaml'
        (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8).Replace('google/gemma-3-27b-it', 'zai-org/GLM-5.2').Replace('model-family: gemma', 'model-family: glm') |
            Set-Content -LiteralPath $configPath -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:ColabLlmE2eRunnerPath `
            -ProjectDir $script:AcceptanceRoot `
            -Workers worker-1 `
            -ExpectedModelId 'zai-org/GLM-5.2' `
            -PlanOnly `
            -Json 2>&1

        $LASTEXITCODE | Should -Be 0
        $summary = ConvertFrom-AcceptanceJsonOutput -Output $output
        @($summary.workers).Count | Should -Be 1
        $summary.workers[0].slot_id | Should -Be 'worker-1'
        $summary.workers[0].model_id | Should -Be 'zai-org/GLM-5.2'
        $summary.workers[0].status | Should -Be 'planned'
        $summary.expected_model_id | Should -Be 'zai-org/GLM-5.2'
    }

    It 'stops a GLM-5.2 E2E plan when worker-1 points at another model' {
        Write-ColabLlmAcceptanceProjectConfig
        New-AcceptanceFakeColabCli | Out-Null

        $output = & pwsh -NoProfile -File $script:ColabLlmE2eRunnerPath `
            -ProjectDir $script:AcceptanceRoot `
            -Workers worker-1 `
            -ExpectedModelId 'zai-org/GLM-5.2' `
            -PlanOnly `
            -Json 2>&1

        $LASTEXITCODE | Should -Not -Be 0
        ($output | Out-String) | Should -Match "worker slot worker-1 uses model_id 'google/gemma-3-27b-it', not expected 'zai-org/GLM-5.2'"
    }

    It 'plans two Colab LLM workers with per-worker expected model ids' {
        Write-ColabLlmAcceptanceProjectConfig
        New-AcceptanceFakeColabCli | Out-Null
        $expectedModels = @{
            'worker-1' = 'google/gemma-3-27b-it'
            'worker-2' = 'Qwen/Qwen3-32B'
        } | ConvertTo-Json -Compress

        $output = & pwsh -NoProfile -File $script:ColabLlmE2eRunnerPath `
            -ProjectDir $script:AcceptanceRoot `
            -Workers 'worker-1,worker-2' `
            -ExpectedModelMapJson $expectedModels `
            -PlanOnly `
            -Json 2>&1

        $LASTEXITCODE | Should -Be 0
        $summary = ConvertFrom-AcceptanceJsonOutput -Output $output
        @($summary.workers).Count | Should -Be 2
        $summary.expected_model_id | Should -Be ''
        $summary.expected_model_ids.'worker-1' | Should -Be 'google/gemma-3-27b-it'
        $summary.expected_model_ids.'worker-2' | Should -Be 'Qwen/Qwen3-32B'
        (@($summary.workers | Where-Object { $_.slot_id -eq 'worker-1' })[0].expected_model_id) | Should -Be 'google/gemma-3-27b-it'
        (@($summary.workers | Where-Object { $_.slot_id -eq 'worker-2' })[0].expected_model_id) | Should -Be 'Qwen/Qwen3-32B'
    }

    It 'stops a two-worker Colab LLM plan when a per-worker expected model id is wrong' {
        Write-ColabLlmAcceptanceProjectConfig
        New-AcceptanceFakeColabCli | Out-Null
        $expectedModels = @{
            'worker-1' = 'google/gemma-3-27b-it'
            'worker-2' = 'zai-org/GLM-5.2'
        } | ConvertTo-Json -Compress

        $output = & pwsh -NoProfile -File $script:ColabLlmE2eRunnerPath `
            -ProjectDir $script:AcceptanceRoot `
            -Workers 'worker-1,worker-2' `
            -ExpectedModelMapJson $expectedModels `
            -PlanOnly `
            -Json 2>&1

        $LASTEXITCODE | Should -Not -Be 0
        ($output | Out-String) | Should -Match "worker slot worker-2 uses model_id 'Qwen/Qwen3-32B', not expected 'zai-org/GLM-5.2'"
    }

    It 'requires per-worker expected model ids for every selected Colab LLM worker' {
        Write-ColabLlmAcceptanceProjectConfig
        New-AcceptanceFakeColabCli | Out-Null
        $expectedModels = @{
            'worker-1' = 'google/gemma-3-27b-it'
        } | ConvertTo-Json -Compress

        $output = & pwsh -NoProfile -File $script:ColabLlmE2eRunnerPath `
            -ProjectDir $script:AcceptanceRoot `
            -Workers 'worker-1,worker-2' `
            -ExpectedModelMapJson $expectedModels `
            -PlanOnly `
            -Json 2>&1

        $LASTEXITCODE | Should -Not -Be 0
        ($output | Out-String) | Should -Match "ExpectedModelMapJson is missing selected worker 'worker-2'"
    }

    It 'classifies oversized GLM-5.2 before starting a live Colab runtime' {
        Write-ColabLlmAcceptanceProjectConfig
        New-AcceptanceFakeColabCli | Out-Null
        $configPath = Join-Path $script:AcceptanceRoot '.winsmux.yaml'
        (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8).Replace('google/gemma-3-27b-it', 'zai-org/GLM-5.2').Replace('model-family: gemma', 'model-family: glm') |
            Set-Content -LiteralPath $configPath -Encoding UTF8
        $env:WINSMUX_COLAB_LLM_E2E_CAPACITY_ESTIMATE_JSON = @{
            model_id = 'zai-org/GLM-5.2'
            weight_files = 282
            safetensor_files = 282
            shard_count = 282
            sample_file = 'model-00001-of-00282.safetensors'
            sample_size_bytes = 5342821416
            estimated_total_bytes = 1500000000000
        } | ConvertTo-Json -Compress
        $env:WINSMUX_COLAB_LLM_MAX_MODEL_BYTES = [string]([Int64]350 * 1024 * 1024 * 1024)

        $output = & pwsh -NoProfile -File $script:ColabLlmE2eRunnerPath `
            -ProjectDir $script:AcceptanceRoot `
            -Workers worker-1 `
            -ExpectedModelId 'zai-org/GLM-5.2' `
            -CapacityPreflightOnly `
            -Json 2>&1

        $LASTEXITCODE | Should -Be 1
        $summary = ConvertFrom-AcceptanceJsonOutput -Output $output
        $summary.status | Should -Be 'blocked'
        $summary.blocked_reason | Should -Be 'capacity_preflight_failed'
        @($summary.blocked_workers).Count | Should -Be 1
        $summary.blocked_workers[0].slot_id | Should -Be 'worker-1'
        $summary.blocked_workers[0].blocked_reason | Should -Be 'model_capacity_exceeded'
        @($summary.workers).Count | Should -Be 1
        $summary.workers[0].slot_id | Should -Be 'worker-1'
        $summary.workers[0].status | Should -Be 'model_capacity_exceeded'
        $summary.workers[0].blocked_reason | Should -Be 'model_capacity_exceeded'
        $summary.workers[0].capacity_preflight.estimated_total_bytes | Should -Be 1500000000000
        $summary.workers[0].capacity_preflight.max_total_bytes | Should -Be ([Int64]350 * 1024 * 1024 * 1024)
    }

    It 'allows capacity-only preflight to pass without live Colab execution for an under-limit model' {
        Write-ColabLlmAcceptanceProjectConfig
        New-AcceptanceFakeColabCli | Out-Null
        $env:WINSMUX_COLAB_LLM_E2E_CAPACITY_ESTIMATE_JSON = @{
            model_id = 'google/gemma-3-27b-it'
            weight_files = 12
            safetensor_files = 12
            shard_count = 12
            sample_file = 'model-00001-of-00012.safetensors'
            sample_size_bytes = 1024
            estimated_total_bytes = 12288
        } | ConvertTo-Json -Compress

        $output = & pwsh -NoProfile -File $script:ColabLlmE2eRunnerPath `
            -ProjectDir $script:AcceptanceRoot `
            -Workers worker-1 `
            -CapacityPreflightOnly `
            -Json 2>&1

        $LASTEXITCODE | Should -Be 0
        $summary = ConvertFrom-AcceptanceJsonOutput -Output $output
        $summary.status | Should -Be 'capacity_ok'
        $summary.blocked_reason | Should -Be ''
        @($summary.blocked_workers).Count | Should -Be 0
        @($summary.workers).Count | Should -Be 1
        $summary.workers[0].slot_id | Should -Be 'worker-1'
        $summary.workers[0].status | Should -Be 'capacity_ok'
        $summary.workers[0].capacity_preflight.status | Should -Be 'capacity_ok'
    }

    It 'reports disabled capacity-only preflight as skipped, not successful' {
        Write-ColabLlmAcceptanceProjectConfig
        New-AcceptanceFakeColabCli | Out-Null
        $env:WINSMUX_COLAB_LLM_MODEL_CAPACITY_PREFLIGHT = '0'

        $output = & pwsh -NoProfile -File $script:ColabLlmE2eRunnerPath `
            -ProjectDir $script:AcceptanceRoot `
            -Workers worker-1 `
            -CapacityPreflightOnly `
            -Json 2>&1

        $LASTEXITCODE | Should -Be 0
        $summary = ConvertFrom-AcceptanceJsonOutput -Output $output
        $summary.status | Should -Be 'capacity_skipped'
        @($summary.skipped_workers).Count | Should -Be 1
        $summary.skipped_workers[0].slot_id | Should -Be 'worker-1'
        $summary.skipped_workers[0].skipped_reason | Should -Be 'capacity_preflight_disabled'
        @($summary.workers).Count | Should -Be 1
        $summary.workers[0].slot_id | Should -Be 'worker-1'
        $summary.workers[0].status | Should -Be 'capacity_skipped'
        $summary.workers[0].capacity_preflight.status | Should -Be 'skipped'
    }

    It 'records capacity preflight metadata failures without starting live Colab' {
        Write-ColabLlmAcceptanceProjectConfig
        New-AcceptanceFakeColabCli | Out-Null
        $env:WINSMUX_COLAB_LLM_E2E_CAPACITY_ESTIMATE_JSON = '{not-json'

        $output = & pwsh -NoProfile -File $script:ColabLlmE2eRunnerPath `
            -ProjectDir $script:AcceptanceRoot `
            -Workers worker-1 `
            -CapacityPreflightOnly `
            -Json 2>&1

        $LASTEXITCODE | Should -Be 1
        $summary = ConvertFrom-AcceptanceJsonOutput -Output $output
        $summary.status | Should -Be 'blocked'
        $summary.blocked_reason | Should -Be 'capacity_preflight_failed'
        @($summary.blocked_workers).Count | Should -Be 1
        $summary.blocked_workers[0].slot_id | Should -Be 'worker-1'
        $summary.blocked_workers[0].blocked_reason | Should -Be 'model_capacity_preflight_failed'
        @($summary.workers).Count | Should -Be 1
        $summary.workers[0].slot_id | Should -Be 'worker-1'
        $summary.workers[0].status | Should -Be 'model_capacity_preflight_failed'
        $summary.workers[0].blocked_reason | Should -Be 'model_capacity_preflight_failed'
        $summary.workers[0].capacity_preflight.error | Should -Match 'JSON'
    }

    It 'rejects malformed worker ids before planning a Colab E2E run' {
        Write-ColabLlmAcceptanceProjectConfig
        New-AcceptanceFakeColabCli | Out-Null

        $output = & pwsh -NoProfile -File $script:ColabLlmE2eRunnerPath `
            -ProjectDir $script:AcceptanceRoot `
            -Workers 'worker 1' `
            -PlanOnly `
            -Json 2>&1

        $LASTEXITCODE | Should -Not -Be 0
        ($output | Out-String) | Should -Match "Invalid worker id 'worker 1'"
    }

    It 'reports two colab_llm workers in one Colab GPU runtime without local Ollama fallback' {
        Write-ColabLlmAcceptanceProjectConfig
        New-AcceptanceFakeColabCli | Out-Null

        $status = Invoke-AcceptanceJson -Arguments @('workers', 'status', '--json', '--project-dir', $script:AcceptanceRoot)
        @($status.workers).Count | Should -Be 2

        $worker1 = @($status.workers | Where-Object { $_.slot_id -eq 'worker-1' })[0]
        $worker2 = @($status.workers | Where-Object { $_.slot_id -eq 'worker-2' })[0]
        $worker1.backend | Should -Be 'colab_llm'
        $worker2.backend | Should -Be 'colab_llm'
        $worker1.actual_gpu | Should -Be 'A100'
        $worker2.actual_gpu | Should -Be 'A100'
        $worker1.colab_llm.runtime | Should -Be 'colab'
        $worker1.colab_llm.runtime_engine | Should -Be 'vllm'
        $worker1.colab_llm.model_id | Should -Be 'google/gemma-3-27b-it'
        $worker2.colab_llm.model_id | Should -Be 'Qwen/Qwen3-32B'
        $worker1.colab_llm.health | Should -Be 'configured'
        $worker2.colab_llm.health | Should -Be 'configured'
        $worker1.colab_llm.drive_root | Should -Be '[DRIVE_PATH_REDACTED]'
        $worker1.colab_llm.env.HF_HOME | Should -Be '[DRIVE_PATH_REDACTED]'
        $worker1.local_llm | Should -BeNullOrEmpty
        $worker2.local_llm | Should -BeNullOrEmpty

        $doctor = Invoke-AcceptanceJson -Arguments @('workers', 'doctor', '--json', '--project-dir', $script:AcceptanceRoot)
        (@($doctor.checks | Where-Object { $_.label -eq 'Colab LLM slots' })[0].status) | Should -Be 'pass'
        (@($doctor.checks | Where-Object { $_.label -eq 'Colab LLM worker worker-1' })[0].status) | Should -Be 'pass'
        (@($doctor.checks | Where-Object { $_.label -eq 'Colab LLM worker worker-2' })[0].detail) | Should -Match 'Qwen/Qwen3-32B via vllm'
        @($doctor.checks | ForEach-Object { $_.label }) | Should -Not -Contain 'ollama command'
        @($doctor.checks | ForEach-Object { $_.label }) | Should -Not -Contain 'OLLAMA_MODELS'
    }

    It 'records redacted colab_llm worker exec evidence through the Colab adapter' {
        Write-ColabLlmAcceptanceProjectConfig
        New-AcceptanceFakeColabCli | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AcceptanceRoot 'workers\colab') -Force | Out-Null
        'print("hello from colab llm")' | Set-Content -LiteralPath (Join-Path $script:AcceptanceRoot 'workers\colab\llm_worker.py') -Encoding UTF8

        $exec = Invoke-AcceptanceJson -Arguments @(
            'workers', 'exec', 'worker-1',
            '--prompt', 'Summarize the repository shape.',
            '--run-id', 'colab-llm-run',
            '--json',
            '--project-dir', $script:AcceptanceRoot
        )

        $exec.status | Should -Be 'succeeded'
        $exec.backend | Should -Be 'colab_llm'
        $exec.runtime | Should -Be 'colab'
        $exec.runtime_engine | Should -Be 'vllm'
        $exec.model_id | Should -Be 'google/gemma-3-27b-it'
        $exec.drive_root | Should -Be '[DRIVE_PATH_REDACTED]'
        $exec.model_root | Should -Be '[DRIVE_PATH_REDACTED]'
        $exec.hf_cache_root | Should -Be '[DRIVE_PATH_REDACTED]'
        $exec.artifact_root | Should -Be '[DRIVE_PATH_REDACTED]'
        (@($exec.cli_arguments) -join ' ') | Should -Not -Match '/content/drive/MyDrive'
        $exec.stdout_log | Should -Match '^\.winsmux/worker-runs/worker-1/colab-llm-run/stdout\.log$'
        $exec.task_json | Should -Match '^\.winsmux/worker-runs/worker-1/colab-llm-run/task\.json$'
        $exec.run_json | Should -Match '^\.winsmux/worker-runs/worker-1/colab-llm-run/run\.json$'

        $runJsonPath = Join-Path $script:AcceptanceRoot ($exec.run_json -replace '/', '\')
        $runJson = Get-Content -LiteralPath $runJsonPath -Raw -Encoding UTF8
        $runJson | Should -Not -Match '/content/drive/MyDrive'
        $runJson | Should -Match '\[DRIVE_PATH_REDACTED\]'
    }

    It 'executes worker-1 and worker-2 colab_llm jobs concurrently through the same adapter contract' {
        Write-ColabLlmAcceptanceProjectConfig
        $fake = New-AcceptanceFakeColabCli
        New-Item -ItemType Directory -Path (Join-Path $script:AcceptanceRoot 'workers\colab') -Force | Out-Null
        'print("hello from concurrent colab llm")' | Set-Content -LiteralPath (Join-Path $script:AcceptanceRoot 'workers\colab\llm_worker.py') -Encoding UTF8

        $jobScript = {
            param(
                [string]$BridgePath,
                [string]$ProjectRoot,
                [string]$FakeCli,
                [string]$Worker,
                [string]$RunId
            )

            $env:WINSMUX_COLAB_CLI = $FakeCli
            $env:WINSMUX_COLAB_AUTH_STATE = 'authenticated'
            $env:WINSMUX_COLAB_AVAILABLE_GPUS = 'A100'
            $env:NO_COLOR = '1'
            $PSStyle.OutputRendering = 'PlainText'
            $output = & pwsh -NoProfile -File $BridgePath workers exec $Worker --prompt "Concurrent Colab LLM acceptance prompt for $Worker." --run-id $RunId --json --project-dir $ProjectRoot 2>&1
            $raw = ($output | Out-String)
            $clean = [regex]::Replace($raw, "`e\[[0-?]*[ -/]*[@-~]", '')
            $clean = [regex]::Replace($clean, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
            $json = $null
            $lines = @($clean -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                $candidate = $lines[$i].Trim()
                if ($candidate.StartsWith('{') -or $candidate.StartsWith('[')) {
                    try {
                        $json = $candidate | ConvertFrom-Json -Depth 32 -ErrorAction Stop
                        break
                    } catch {
                    }
                }
            }
            if ($null -eq $json) {
                throw "No JSON payload found in command output. Sanitized output: $clean"
            }
            [PSCustomObject]@{
                Worker   = $Worker
                RunId    = $RunId
                ExitCode = $LASTEXITCODE
                Output   = $clean
                Json     = $json
            }
        }

        $jobs = @(
            Start-Job -ScriptBlock $jobScript -ArgumentList $script:BridgePath, $script:AcceptanceRoot, $fake.Path, 'worker-1', 'colab-llm-concurrent-1'
            Start-Job -ScriptBlock $jobScript -ArgumentList $script:BridgePath, $script:AcceptanceRoot, $fake.Path, 'worker-2', 'colab-llm-concurrent-2'
        )

        try {
            $completed = Wait-Job -Job $jobs -Timeout 90
            @($completed).Count | Should -Be 2

            $results = @($jobs | Receive-Job)
            @($results).Count | Should -Be 2
            foreach ($result in $results) {
                $result.ExitCode | Should -Be 0 -Because $result.Output
                $result.Json.status | Should -Be 'succeeded'
                $result.Json.backend | Should -Be 'colab_llm'
                $result.Json.runtime_engine | Should -Be 'vllm'
                $result.Json.stdout_log | Should -Match "^\.winsmux/worker-runs/$($result.Worker)/$($result.RunId)/stdout\.log$"
            }
            @($results | ForEach-Object { $_.Json.slot_id }) | Should -Contain 'worker-1'
            @($results | ForEach-Object { $_.Json.slot_id }) | Should -Contain 'worker-2'
        } finally {
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps real Colab runtime acceptance behind an explicit manual flag' {
        if ([string]$env:WINSMUX_COLAB_ACCEPTANCE_REAL -ne '1') {
            Set-ItResult -Skipped -Because 'Set WINSMUX_COLAB_ACCEPTANCE_REAL=1 and WINSMUX_COLAB_ACCEPTANCE_PROJECT to run live Colab checks manually.'
            return
        }

        $project = [string]$env:WINSMUX_COLAB_ACCEPTANCE_PROJECT
        if ([string]::IsNullOrWhiteSpace($project)) {
            throw 'WINSMUX_COLAB_ACCEPTANCE_PROJECT must point to a project configured with worker-1 and worker-2 colab_llm slots.'
        }

        $doctor = Invoke-AcceptanceJson -Arguments @('workers', 'doctor', '--json', '--project-dir', $project)
        (@($doctor.checks | Where-Object { $_.label -eq 'google-colab-cli' })[0].status) | Should -Be 'pass'
        (@($doctor.checks | Where-Object { $_.label -eq 'colab auth' })[0].status) | Should -Be 'pass'
        (@($doctor.checks | Where-Object { $_.label -eq 'Colab LLM slots' })[0].status) | Should -Be 'pass'
        (@($doctor.checks | Where-Object { $_.label -eq 'Colab LLM worker worker-1' })[0].status) | Should -Be 'pass'
        (@($doctor.checks | Where-Object { $_.label -eq 'Colab LLM worker worker-2' })[0].status) | Should -Be 'pass'

        $status = Invoke-AcceptanceJson -Arguments @('workers', 'status', '--json', '--project-dir', $project)
        $worker1 = @($status.workers | Where-Object { $_.slot_id -eq 'worker-1' })[0]
        $worker2 = @($status.workers | Where-Object { $_.slot_id -eq 'worker-2' })[0]
        $worker1.backend | Should -Be 'colab_llm'
        $worker2.backend | Should -Be 'colab_llm'
        $worker1.degraded_reason | Should -Be ''
        $worker2.degraded_reason | Should -Be ''
        $worker1.actual_gpu | Should -Match 'H100|A100'
        $worker2.actual_gpu | Should -Match 'H100|A100'
        $worker1.colab_llm.runtime_engine | Should -Be 'vllm'
        $worker2.colab_llm.runtime_engine | Should -Be 'vllm'
    }
}
