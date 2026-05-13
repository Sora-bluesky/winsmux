$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Colab worker templates' {
    BeforeAll {
        $script:RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:RepoRoot)) {
            throw 'Failed to resolve repository root.'
        }
        $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
        if ($null -eq $pythonCommand) {
            $pythonCommand = Get-Command py -ErrorAction SilentlyContinue
        }
        $script:PythonCommand = if ($null -ne $pythonCommand) { $pythonCommand.Source } else { '' }
        $script:Templates = @(
            @{ Path = 'workers\colab\impl_worker.py'; Kind = 'impl'; Artifact = 'implementation-plan.md' },
            @{ Path = 'workers\colab\critic_worker.py'; Kind = 'critic'; Artifact = 'critic-notes.md' },
            @{ Path = 'workers\colab\scout_worker.py'; Kind = 'scout'; Artifact = 'scout-plan.md' },
            @{ Path = 'workers\colab\test_worker.py'; Kind = 'test'; Artifact = 'test-plan.md' },
            @{ Path = 'workers\colab\heavy_judge_worker.py'; Kind = 'heavy_judge'; Artifact = 'heavy-judge-report.md' }
        )
    }

    It 'emits structured JSON and writes artifacts for every template' {
        if ([string]::IsNullOrWhiteSpace($script:PythonCommand)) {
            Set-ItResult -Skipped -Because 'python is not available on PATH'
            return
        }

        $artifactRoot = Join-Path $TestDrive 'winsmux-artifacts'
        $taskJson = @{
            task_id = 'TASK-475'
            title = 'Add Colab worker templates'
            changed_files = @('workers/colab/impl_worker.py')
            verification_plan = @('Invoke-Pester tests/ColabWorkerTemplates.Tests.ps1')
        } | ConvertTo-Json -Compress

        foreach ($template in $script:Templates) {
            $scriptPath = Join-Path $script:RepoRoot $template.Path
            $isolatedDir = Join-Path $TestDrive ('isolated-' + $template.Kind)
            New-Item -ItemType Directory -Path $isolatedDir -Force | Out-Null
            $isolatedScript = Join-Path $isolatedDir (Split-Path -Leaf $scriptPath)
            Copy-Item -LiteralPath $scriptPath -Destination $isolatedScript

            $output = & $script:PythonCommand $isolatedScript --task-json-inline $taskJson --worker-id worker-2 --run-id run-1 --artifact-root $artifactRoot
            $LASTEXITCODE | Should -Be 0
            $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

            $payload.schema_version | Should -Be 'winsmux.colab.worker.result.v1'
            $payload.status | Should -Be 'succeeded'
            $payload.worker_kind | Should -Be $template.Kind
            $payload.worker_id | Should -Be 'worker-2'
            $payload.run_id | Should -Be 'run-1'
            $payload.task.id | Should -Be 'TASK-475'
            @($payload.artifacts).Count | Should -Be 1

            $artifactPath = [string]$payload.artifacts[0].path
            $artifactPath.Replace('\', '/') | Should -Match '/worker-2/run-1/'
            $artifactPath.Replace('\', '/') | Should -Match ([regex]::Escape(('/' + $template.Artifact)))
            Test-Path -LiteralPath $artifactPath | Should -Be $true
            (Get-Content -LiteralPath $artifactPath -Raw -Encoding UTF8) | Should -Match 'Colab worker templates|Add Colab worker templates|Worker'
        }
    }

    It 'returns a structured failure for invalid task JSON' {
        if ([string]::IsNullOrWhiteSpace($script:PythonCommand)) {
            Set-ItResult -Skipped -Because 'python is not available on PATH'
            return
        }

        $scriptPath = Join-Path $script:RepoRoot 'workers\colab\impl_worker.py'
        $output = & $script:PythonCommand $scriptPath --task-json-inline '{not-json' --worker-id worker-2 --artifact-root (Join-Path $TestDrive 'artifacts') 2>$null
        $LASTEXITCODE | Should -Be 1
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $payload.status | Should -Be 'failed'
        $payload.errors[0].code | Should -Be 'invalid_task_json'
    }

    It 'rejects worker ids that would escape the artifact directory' {
        if ([string]::IsNullOrWhiteSpace($script:PythonCommand)) {
            Set-ItResult -Skipped -Because 'python is not available on PATH'
            return
        }

        $scriptPath = Join-Path $script:RepoRoot 'workers\colab\impl_worker.py'
        $output = & $script:PythonCommand $scriptPath --task-json-inline '{}' --worker-id '../escape' --artifact-root (Join-Path $TestDrive 'artifacts') 2>$null
        $LASTEXITCODE | Should -Be 1
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $payload.status | Should -Be 'failed'
        $payload.errors[0].code | Should -Be 'invalid_worker_id'
    }
}
