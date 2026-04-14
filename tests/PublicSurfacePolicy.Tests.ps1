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
        $trackedHandoff = Get-Content (Join-Path $repoRoot 'HANDOFF.md') -Raw
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

    It 'uses local operator handoff and example roadmap title override in durable repo rules' {
        $agents | Should -Match '\.claude/local/operator-handoff\.md'
        $agents | Should -Match 'tasks/roadmap-title-ja\.example\.psd1'
        $agents | Should -Not -Match 'docs/handoff\.md'
        $agents | Should -Not -Match 'tasks/roadmap-title-ja\.psd1'
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

    It 'keeps tracked bootstrap handoff aligned with current startup contract' {
        $trackedHandoff | Should -Match 'winsmux orchestra-smoke --json'
        $trackedHandoff | Should -Match 'operator_contract'
        $trackedHandoff | Should -Match 'TASK-105'
        $trackedHandoff | Should -Match 'TASK-289'
        $trackedHandoff | Should -Match 'TASK-291'
        $trackedHandoff | Should -Not -Match 'psmux サーバー'
        $trackedHandoff | Should -Not -Match '手動で起動'
        $trackedHandoff | Should -Not -Match 'v0\.19\.5 進捗 70%'
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
