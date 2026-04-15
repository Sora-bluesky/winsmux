$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Public surface policy' {
    BeforeAll {
        $repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($repoRoot)) {
            throw 'Failed to resolve repository root.'
        }

        $readme = Get-Content (Join-Path $repoRoot 'README.md') -Raw
        $readmeJa = Get-Content (Join-Path $repoRoot 'README.ja.md') -Raw
        $operatorModel = Get-Content (Join-Path $repoRoot 'docs/operator-model.md') -Raw
        $agents = Get-Content (Join-Path $repoRoot 'AGENTS.md') -Raw
        $surfacePolicy = Get-Content (Join-Path $repoRoot 'docs/repo-surface-policy.md') -Raw
        $gitignore = Get-Content (Join-Path $repoRoot '.gitignore') -Raw
        $claudeContract = Get-Content (Join-Path $repoRoot '.claude/CLAUDE.md') -Raw
        $syncRoadmap = Get-Content (Join-Path $repoRoot 'winsmux-core/scripts/sync-roadmap.ps1') -Raw
        $syncInternalDocs = Get-Content (Join-Path $repoRoot 'winsmux-core/scripts/sync-internal-docs.ps1') -Raw
    }

    It 'keeps public docs free of contributor/private direct links' {
        $forbidden = @(
            '.claude/CLAUDE.md',
            'AGENT.md',
            'GEMINI.md',
            'docs/internal/',
            'docs/handoff.md',
            'tasks/roadmap-title-ja.psd1'
        )

        foreach ($reference in $forbidden) {
            $readme | Should -Not -Match ([Regex]::Escape($reference))
            $readmeJa | Should -Not -Match ([Regex]::Escape($reference))
            $operatorModel | Should -Not -Match ([Regex]::Escape($reference))
        }
    }

    It 'keeps internal startup helpers and dogfooding terminology out of public docs while advertising future public entrypoints' {
        foreach ($forbidden in @('/winsmux-start', 'dogfooding', 'maintainer-only', 'operator-handoff', 'private live-ops')) {
            $readme | Should -Not -Match ([Regex]::Escape($forbidden))
            $readmeJa | Should -Not -Match ([Regex]::Escape($forbidden))
            $operatorModel | Should -Not -Match ([Regex]::Escape($forbidden))
        }

        foreach ($entrypoint in @('winsmux init', 'winsmux launch', 'winsmux compare')) {
            $readme | Should -Match ([Regex]::Escape($entrypoint))
            $readmeJa | Should -Match ([Regex]::Escape($entrypoint))
            $operatorModel | Should -Match ([Regex]::Escape($entrypoint))
        }
    }

    It 'uses local operator handoff and example roadmap title override in durable repo rules' {
        $agents | Should -Match '\.claude/local/operator-handoff\.md'
        $agents | Should -Match 'tasks/roadmap-title-ja\.example\.psd1'
        $agents | Should -Not -Match 'docs/handoff\.md'
        $agents | Should -Not -Match 'tasks/roadmap-title-ja\.psd1'
    }

    It 'uses the five-surface model consistently in durable policy files' {
        $agents | Should -Match 'five distinct surfaces'
        $agents | Should -Match 'runtime contract surface'
        $agents | Should -Match 'contributor/test surface'
        $agents | Should -Not -Match 'contributor/runtime surface'

        $surfacePolicy | Should -Match '## 1\. Public product surface'
        $surfacePolicy | Should -Match '## 2\. Runtime contract surface'
        $surfacePolicy | Should -Match '## 3\. Contributor/test surface'
        $surfacePolicy | Should -Match '## 4\. Private live-ops surface'
        $surfacePolicy | Should -Match '## 5\. Generated/runtime artifacts'
        $surfacePolicy | Should -Match 'Runtime contract surface'
        $surfacePolicy | Should -Match 'Contributor/test surface'
    }

    It 'keeps ignore rules aligned with tracked contributor/runtime files' {
        $gitignore | Should -Match '/CLAUDE\.md'
        $gitignore | Should -Match 'docs/handoff\.md'
        $gitignore | Should -Match '\.claude/local/'
        $gitignore | Should -Match '!tasks/roadmap-title-ja\.example\.psd1'
    }

    It 'pins Claude Code startup guidance to operator_contract' {
        $claudeContract | Should -Match 'winsmux orchestra-smoke --json'
        $claudeContract | Should -Match 'operator_contract'
        $claudeContract | Should -Match 'Do not probe with legacy commands such as `psmux --version` or `Get-Process psmux-server`'
        $claudeContract | Should -Not -Match 'Check psmux version'
    }

    It 'does not track bootstrap handoff files in the repository root or docs' {
        $tracked = @(
            & git ls-files -- HANDOFF.md docs/HANDOFF.md docs/handoff.md 2>$null |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        @($tracked).Count | Should -Be 0
    }

    It 'uses example fallback for roadmap title localization' {
        $syncRoadmap | Should -Match 'tasks/roadmap-title-ja\.example\.psd1'
        $syncInternalDocs | Should -Match 'tasks/roadmap-title-ja\.example\.psd1'
    }

    It 'keeps the tracked roadmap title example scrubbed of live planning data' {
        $example = Get-Content (Join-Path $repoRoot 'tasks/roadmap-title-ja.example.psd1') -Raw

        $example | Should -Match 'VersionTitles\s*=\s*@\{\}'
        $example | Should -Match 'TaskTitles\s*=\s*@\{\}'
        $example | Should -Not -Match '"v0\.'
        $example | Should -Not -Match '"TASK-'
    }
}
