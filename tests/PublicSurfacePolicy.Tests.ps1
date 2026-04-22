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
        $thirdPartyNotices = Get-Content (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') -Raw
        $appIndex = Get-Content (Join-Path $repoRoot 'winsmux-app/index.html') -Raw
        $syncRoadmap = Get-Content (Join-Path $repoRoot 'winsmux-core/scripts/sync-roadmap.ps1') -Raw
        $syncInternalDocs = Get-Content (Join-Path $repoRoot 'winsmux-core/scripts/sync-internal-docs.ps1') -Raw
        $installer = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
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

    It 'keeps /winsmux-start out of the public UX and advertises future public entrypoints' {
        $readme | Should -Match '/winsmux-start'
        $readmeJa | Should -Match '/winsmux-start'
        $operatorModel | Should -Match '/winsmux-start'
        $readme | Should -Match 'dogfooding-only flow'
        $readmeJa | Should -Match 'dogfooding 専用フロー'
        $operatorModel | Should -Match 'dogfooding flow'

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

    It 'describes Codex UI provenance as public openai/codex TUI-derived work' {
        $agents | Should -Match 'public `openai/codex` TUI-derived UI work'
        $agents | Should -Match 'Do not treat non-public Codex App desktop source as an upstream reference'
        $thirdPartyNotices | Should -Match 'public `openai/codex` TUI-derived UI work'
        $thirdPartyNotices | Should -Match 'does not imply.*non-public Codex App desktop source code'
        $thirdPartyNotices | Should -Not -Match 'Codex-derived UI'
        $appIndex | Should -Match 'Public openai/codex TUI-derived typography'
        $appIndex | Should -Not -Match 'Codex-derived typography'
    }

    It 'keeps installer next steps aligned with public first-run commands' {
        $installerSingleLine = $installer -replace '\s+', ' '
        $installer | Should -Match 'winsmux init'
        $installer | Should -Match 'winsmux launch'
        $installer | Should -Not -Match "WINSMUX_AGENT_NAME = 'claude'"
        $installerSingleLine | Should -Match '"orchestra".*"vault"'
        $installer | Should -Match 'Test-InstallProfileContent -Profile \$resolvedInstallProfile -Content "orchestration_scripts"'
        $installer | Should -Match 'winsmux-core/scripts/public-first-run\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/orchestra-smoke\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/doctor\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/orchestra-attach-confirm\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/orchestra-pane-bootstrap\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/commander-poll\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/pane-control\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/agent-monitor\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/agent-watchdog\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/orchestra-state\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/server-watchdog\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/pane-border\.ps1'
    }
}
