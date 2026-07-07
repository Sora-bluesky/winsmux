$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'v0.36.26 desktop split gate' {
    BeforeAll {
        $script:repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:repoRoot)) {
            throw 'Failed to resolve repository root.'
        }
        $script:gateScript = Join-Path $script:repoRoot 'scripts/test-v03626-desktop-split-gate.ps1'
    }

    It 'passes the desktop split static wiring gate' {
        $output = & pwsh -NoProfile -File $script:gateScript -Json
        $LASTEXITCODE | Should -Be 0
        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result['gate_id'] | Should -Be 'v03626-desktop-split-gate'
        $result['evidence_mode'] | Should -Be 'static-wiring'
        $result['release_ready'] | Should -Be $false
        $result['all_pass'] | Should -Be $true
        $result['failed_count'] | Should -Be 0
        [int]$result['check_count'] | Should -BeGreaterThan 30
    }

    It 'publishes the required release gate input classes' {
        $output = & pwsh -NoProfile -File $script:gateScript -Json
        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)
        $classes = @($result['release_gate_inputs'] | ForEach-Object { $_['class'] })

        foreach ($requiredClass in @('visual', 'accessibility', 'clickable-coverage', 'desktop-e2e', 'module-budget', 'performance')) {
            $classes | Should -Contain $requiredClass
        }

        foreach ($input in @($result['release_gate_inputs'])) {
            [bool]$input['required_for_release'] | Should -Be $true
        }
    }

    It 'defines a required evidence mode for release readiness' {
        $content = Get-Content -LiteralPath $script:gateScript -Raw

        $content | Should -Match 'RequireEvidence'
        $content | Should -Match 'visual evidence file exists and reports ok'
        $content | Should -Match 'clickable coverage evidence file exists and reports ok'
        $content | Should -Match 'desktop E2E evidence file exists and reports ok'
        $content | Should -Match 'performance evidence includes measured durationMs'
        $content | Should -Match 'release_ready'
    }

    It 'keeps the npm release gate evidence-required and exposes static wiring separately' {
        $packagePath = Join-Path $script:repoRoot 'winsmux-app/package.json'
        $package = (Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json -AsHashtable)
        $scripts = $package['scripts']

        [string]$scripts['test:desktop-split-static'] | Should -Match 'test-v03626-desktop-split-gate\.ps1'
        [string]$scripts['test:desktop-split-static'] | Should -Not -Match '-RequireEvidence'
        [string]$scripts['test:desktop-split-gate'] | Should -Match 'test-v03626-desktop-split-gate\.ps1'
        [string]$scripts['test:desktop-split-gate'] | Should -Match '-RequireEvidence'
    }

    It 'keeps all frozen desktop split modules within their release budget' {
        $output = & pwsh -NoProfile -File $script:gateScript -Json
        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        foreach ($budget in @($result['module_budgets'])) {
            [int]$budget['physical_lines'] | Should -BeLessOrEqual ([int]$budget['limit'])
            [int]$budget['physical_lines'] | Should -BeLessOrEqual ([int]$budget['baseline'])
        }
    }
}
