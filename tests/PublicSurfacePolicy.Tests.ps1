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
        $readme | Should -Match 'test this repository itself'
        $readmeJa | Should -Match '動作確認専用'
        $operatorModel | Should -Match 'dogfooding flow'

        foreach ($entrypoint in @('winsmux init', 'winsmux launch', 'winsmux launcher presets', 'winsmux compare')) {
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
        $installer | Should -Match 'winsmux-core/scripts/operator-poll\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/pane-control\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/agent-monitor\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/agent-watchdog\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/orchestra-state\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/server-watchdog\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/pane-border\.ps1'
    }

    It 'keeps public install and OAuth wording aligned with the current policy' {
        $authSupport = Get-Content (Join-Path $repoRoot 'docs/authentication-support.md') -Raw
        $authSupportJa = Get-Content (Join-Path $repoRoot 'docs/authentication-support.ja.md') -Raw

        $readme | Should -Not -Match 'raw\.githubusercontent\.com/Sora-bluesky/winsmux/main/install\.ps1'
        $readmeJa | Should -Not -Match 'raw\.githubusercontent\.com/Sora-bluesky/winsmux/main/install\.ps1'

        $readme | Should -Match 'npm install -g winsmux'
        $readmeJa | Should -Match 'npm install -g winsmux'

        $readme | Should -Match 'Claude Code \| Pro / Max OAuth \| This PC only, interactive use'
        $readme | Should -Match 'Gemini CLI \| Google OAuth \| This PC only, interactive use'
        $readmeJa | Should -Match 'Claude Code \| Pro / Max OAuth \| 当該 PC での対話利用のみ'
        $readmeJa | Should -Match 'Gemini CLI \| Google OAuth \| 当該 PC での対話利用のみ'

        $authSupport | Should -Match 'claude-pro-max-oauth.*interactive use on that same PC'
        $authSupport | Should -Match 'gemini-google-oauth.*interactive use on that same PC'
        $authSupport | Should -Match 'configured `auth_mode`'
        $authSupport | Should -Match 'token-broker'
        $authSupport | Should -Match 'provider-api-proxy'
        $authSupportJa | Should -Match 'claude-pro-max-oauth.*その PC 上での対話利用のみ'
        $authSupportJa | Should -Match 'gemini-google-oauth.*その PC 上での対話利用のみ'
        $authSupportJa | Should -Match '設定された `auth_mode`'
        $authSupportJa | Should -Match 'token-broker'
        $authSupportJa | Should -Match 'provider-api-proxy'
    }

    It 'uses recorded-baseline gitleaks scans for routine push and CI checks' {
        $workflow = Get-Content (Join-Path $repoRoot '.github/workflows/test.yml') -Raw
        $prePush = Get-Content (Join-Path $repoRoot '.githooks/pre-push') -Raw
        $gitleaksScript = Get-Content (Join-Path $repoRoot 'scripts/gitleaks-history.ps1') -Raw
        $baseline = Get-Content (Join-Path $repoRoot 'scripts/gitleaks-history-baseline.txt') -Raw

        $workflow | Should -Match 'Gitleaks Incremental Scan'
        $workflow | Should -Match 'Run secret scan since recorded baseline'
        $workflow | Should -Not -Match 'Run full-history secret scan'

        $prePush | Should -Match 'scripts\\\\gitleaks-history\.ps1'
        $gitleaksScript | Should -Match 'BaselineFile'
        $gitleaksScript | Should -Match 'baselineCommit\.\.HEAD'
        $gitleaksScript | Should -Match '-Full'
        $gitleaksScript | Should -Match '-UpdateBaseline'
        $baseline.Trim() | Should -Match '^[0-9a-f]{40}$'
    }
}
