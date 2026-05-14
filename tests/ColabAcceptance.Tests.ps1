$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Colab worker acceptance gate' {
    BeforeAll {
        $script:RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:RepoRoot)) {
            throw 'Failed to resolve repository root.'
        }

        $script:BridgePath = Join-Path $script:RepoRoot 'scripts\winsmux-core.ps1'
    }

    BeforeEach {
        $script:AcceptanceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-colab-acceptance-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AcceptanceRoot -Force | Out-Null

        $script:PreviousColabCli = $env:WINSMUX_COLAB_CLI
        $script:PreviousColabAuth = $env:WINSMUX_COLAB_AUTH_STATE
        $script:PreviousColabGpu = $env:WINSMUX_COLAB_AVAILABLE_GPUS
        $script:PreviousTaskJson = $env:WINSMUX_TASK_JSON
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
        return (($output | Select-Object -Last 1) | ConvertFrom-Json -Depth 32)
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

    It 'keeps real Colab runtime acceptance behind an explicit manual flag' {
        if ([string]$env:WINSMUX_COLAB_ACCEPTANCE_REAL -ne '1') {
            Set-ItResult -Skipped -Because 'Set WINSMUX_COLAB_ACCEPTANCE_REAL=1 and WINSMUX_COLAB_ACCEPTANCE_PROJECT to run live Colab checks manually.'
            return
        }

        $project = [string]$env:WINSMUX_COLAB_ACCEPTANCE_PROJECT
        if ([string]::IsNullOrWhiteSpace($project)) {
            throw 'WINSMUX_COLAB_ACCEPTANCE_PROJECT must point to a project configured with at least one colab_cli slot.'
        }

        $doctor = Invoke-AcceptanceJson -Arguments @('workers', 'doctor', '--json', '--project-dir', $project)
        (@($doctor.checks | Where-Object { $_.label -eq 'google-colab-cli' })[0].status) | Should -Be 'pass'
        (@($doctor.checks | Where-Object { $_.label -eq 'colab auth' })[0].status) | Should -Be 'pass'

        $status = Invoke-AcceptanceJson -Arguments @('workers', 'status', '--json', '--project-dir', $project)
        @($status.workers | Where-Object { $_.backend -eq 'colab_cli' -and $_.degraded_reason -eq '' }).Count | Should -BeGreaterThan 0
    }
}
