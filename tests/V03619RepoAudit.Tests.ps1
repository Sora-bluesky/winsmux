$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'v0.36.19 repository-wide audit gate' {
    BeforeAll {
        $script:repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:repoRoot)) {
            throw 'Failed to resolve repository root.'
        }
        $script:gateScript = Join-Path $script:repoRoot 'scripts/test-v03619-repo-audit.ps1'
    }

    It 'passes the repository-wide audit static gate' {
        $output = & pwsh -NoProfile -File $script:gateScript -Json
        $LASTEXITCODE | Should -Be 0
        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result['all_pass'] | Should -Be $true
        $result['failed_count'] | Should -Be 0
        [int]$result['check_count'] | Should -BeGreaterThan 20
    }

    It 'keeps CI Pester categories file-owned and runnable without FullName filters' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github/workflows/test.yml') -Raw
        $matrixConsumerMatch = [regex]::Match($workflow, '(?ms)# TASK-810 consumer begin: matrix(?<consumer>.*?)# TASK-810 consumer end: matrix')

        [regex]::Matches($workflow, "(?ms)if \('\$\{\{ matrix\.name \}\}' -like 'bridge-\*'\)\s*\{\s*& \./scripts/assert-pester-shard-coverage\.ps1\s*\}").Count | Should -Be 1
        [regex]::Matches($workflow, '# TASK-810 consumer begin: matrix').Count | Should -Be 1
        $matrixConsumerMatch.Success | Should -BeTrue
        [regex]::Matches($matrixConsumerMatch.Groups['consumer'].Value, [regex]::Escape('& ./scripts/run-pester-shard.ps1 -ShardId $ShardId')).Count | Should -Be 1
        $workflow | Should -Not -Match '\$config\.Run\.Path'
        $workflow | Should -Not -Match '\$config\.Filter\.FullName'
        $workflow | Should -Not -Match 'Invoke-Pester'
    }
}
