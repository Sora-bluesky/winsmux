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
}
