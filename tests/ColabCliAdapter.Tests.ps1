BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Adapter = Join-Path $script:RepoRoot 'scripts/google-colab-cli-adapter.ps1'
    $script:WorkerScript = Join-Path $script:RepoRoot 'workers/colab/llm_worker.py'
}

Describe 'google-colab-cli adapter bridge' {
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
                prompt = 'hello from test'
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
            Test-Path -LiteralPath (Join-Path $outputDir 'colab-adapter-plan.py') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $outputDir 'adapter-result.json') | Should -BeTrue

            $logs = & pwsh -NoProfile -File $script:Adapter logs --session test-session --run-id run-1
            $LASTEXITCODE | Should -Be 0
            ($logs | ConvertFrom-Json).status | Should -Be 'planned'
        } finally {
            if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_MODE = $previousMode }
            if ($null -eq $previousStateRoot) { Remove-Item Env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT = $previousStateRoot }
        }
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
}
