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
        $docsIndex = Get-Content (Join-Path $repoRoot 'docs/README.md') -Raw
        $docsIndexJa = Get-Content (Join-Path $repoRoot 'docs/README.ja.md') -Raw
        $operatorModel = Get-Content (Join-Path $repoRoot 'docs/operator-model.md') -Raw
        $surfacePolicy = Get-Content (Join-Path $repoRoot 'docs/repo-surface-policy.md') -Raw
        $gitignore = Get-Content (Join-Path $repoRoot '.gitignore') -Raw
        $claudeContract = Get-Content (Join-Path $repoRoot '.claude/CLAUDE.md') -Raw
        $thirdPartyNotices = Get-Content (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') -Raw
        $appIndex = Get-Content (Join-Path $repoRoot 'winsmux-app/index.html') -Raw
        $syncRoadmap = Get-Content (Join-Path $repoRoot 'winsmux-core/scripts/sync-roadmap.ps1') -Raw
        $syncInternalDocs = Get-Content (Join-Path $repoRoot 'winsmux-core/scripts/sync-internal-docs.ps1') -Raw
        $installer = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
        $auditPublicSurface = Join-Path $repoRoot 'scripts/audit-public-surface.ps1'
        $auditStagedPublicSurface = Join-Path $repoRoot 'scripts/audit-staged-public-surface.ps1'
        $previousHooksPath = (& git config --get core.hooksPath 2>$null | Out-String).Trim()
        $hadHooksPath = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($previousHooksPath)
        & git config core.hooksPath .githooks
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to configure core.hooksPath for public surface audit tests.'
        }
        $publicDocs = @(
            $readme,
            $readmeJa,
            $docsIndex,
            $docsIndexJa,
            $operatorModel,
            $thirdPartyNotices,
            (Get-Content (Join-Path $repoRoot 'docs/quickstart.md') -Raw),
            (Get-Content (Join-Path $repoRoot 'docs/quickstart.ja.md') -Raw),
            (Get-Content (Join-Path $repoRoot 'docs/installation.md') -Raw),
            (Get-Content (Join-Path $repoRoot 'docs/installation.ja.md') -Raw),
            (Get-Content (Join-Path $repoRoot 'docs/customization.md') -Raw),
            (Get-Content (Join-Path $repoRoot 'docs/customization.ja.md') -Raw),
            (Get-Content (Join-Path $repoRoot 'docs/TROUBLESHOOTING.md') -Raw),
            (Get-Content (Join-Path $repoRoot 'docs/TROUBLESHOOTING.ja.md') -Raw),
            (Get-Content (Join-Path $repoRoot 'packages/winsmux/README.md') -Raw)
        )
    }

    AfterAll {
        if ($hadHooksPath) {
            & git config core.hooksPath $previousHooksPath
        } else {
            & git config --unset core.hooksPath
        }
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
            foreach ($publicDoc in $publicDocs) {
                $publicDoc | Should -Not -Match ([Regex]::Escape($reference))
            }
        }
    }

    It 'keeps repository startup flows out of the public UX and advertises public entrypoints' {
        $readme | Should -Not -Match '/winsmux-start'
        $readmeJa | Should -Not -Match '/winsmux-start'
        $operatorModel | Should -Not -Match '/winsmux-start'
        $readme | Should -Not -Match 'test this repository itself'
        $readmeJa | Should -Not -Match '動作確認専用'
        $operatorModel | Should -Not -Match 'dogfooding'
        $operatorModel | Should -Not -Match 'Repository-operated'
        $operatorModel | Should -Not -Match 'contributor/runtime'
        $operatorModel | Should -Match 'Repository-specific startup flows are kept in contributor documents'

        $readme | Should -Match 'docs/quickstart\.md'
        $readme | Should -Match 'docs/installation\.md'
        $readme | Should -Match 'docs/customization\.md'
        $readmeJa | Should -Match 'docs/quickstart\.ja\.md'
        $readmeJa | Should -Match 'docs/installation\.ja\.md'
        $readmeJa | Should -Match 'docs/customization\.ja\.md'
        $docsIndex | Should -Match 'quickstart\.md'
        $docsIndexJa | Should -Match 'quickstart\.ja\.md'

        foreach ($entrypoint in @('winsmux init', 'winsmux launch', 'winsmux launcher presets', 'winsmux compare')) {
            $readme | Should -Match ([Regex]::Escape($entrypoint))
            $readmeJa | Should -Match ([Regex]::Escape($entrypoint))
            $operatorModel | Should -Match ([Regex]::Escape($entrypoint))
        }
    }

    It 'uses local operator handoff and example roadmap title override in durable repo rules' {
        $claudeContract | Should -Match '\.claude/local/operator-handoff\.md'
        $syncRoadmap | Should -Match 'tasks/roadmap-title-ja\.example\.psd1'
        $syncInternalDocs | Should -Match 'tasks/roadmap-title-ja\.example\.psd1'
        $claudeContract | Should -Not -Match 'docs/handoff\.md'
        $syncRoadmap | Should -Not -Match 'tasks/roadmap-title-ja\.psd1'
    }

    It 'uses the five-surface model consistently in durable policy files' {
        $surfacePolicy | Should -Match '## 1\. Public product surface'
        $surfacePolicy | Should -Match '## 2\. Runtime contract surface'
        $surfacePolicy | Should -Match '## 3\. Contributor/test surface'
        $surfacePolicy | Should -Match '## 4\. Private live-ops surface'
        $surfacePolicy | Should -Match '## 5\. Generated/runtime artifacts'
        $surfacePolicy | Should -Match 'Runtime contract surface'
        $surfacePolicy | Should -Match 'Contributor/test surface'
        $surfacePolicy | Should -Match 'root `AGENTS\.md` when present as local Codex project rules'
        $surfacePolicy | Should -Not -Match 'contributor/runtime surface'
    }

    It 'keeps ignore rules aligned with tracked contributor/runtime files' {
        $gitignore | Should -Match '/AGENTS\.md'
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

    It 'keeps local generated artifacts out of the tracked public surface' {
        $gitignore | Should -Match '\.playwright-mcp/'

        $trackedArtifacts = @(
            & git ls-files -- .playwright-mcp testResults.xml 2>$null |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        @($trackedArtifacts).Count | Should -Be 0

        $privateUsePaths = @(
            & git ls-files -- 2>$null |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -match '[\uE000-\uF8FF]' }
        )
        @($privateUsePaths).Count | Should -Be 0
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
        $readme | Should -Match 'Antigravity CLI \| Google Sign-In through secure keyring \| This PC only, interactive use'
        $readme | Should -Match 'Gemini CLI \| Google OAuth \| Legacy local use; migrate to Antigravity CLI'
        $readmeJa | Should -Match 'Claude Code \| Pro / Max OAuth \| 当該 PC での対話利用のみ'
        $readmeJa | Should -Match 'Antigravity CLI \| セキュアキーチェーン経由の Google Sign-In \| この PC での対話利用のみ'
        $readmeJa | Should -Match 'Gemini CLI \| Google OAuth \| 従来のローカル利用。Antigravity CLI への移行対象'

        $authSupport | Should -Match 'claude-pro-max-oauth.*interactive use on that same PC'
        $authSupport | Should -Match 'antigravity-google-signin.*interactive use on that same PC'
        $authSupport | Should -Match 'gemini-google-oauth.*legacy local use'
        $authSupport | Should -Match 'configured `auth_mode`'
        $authSupport | Should -Match 'token-broker'
        $authSupport | Should -Match 'provider-api-proxy'
        $authSupportJa | Should -Match 'claude-pro-max-oauth.*その PC 上での対話利用のみ'
        $authSupportJa | Should -Match 'antigravity-google-signin.*その PC 上での対話利用のみ'
        $authSupportJa | Should -Match 'gemini-google-oauth.*従来のローカル利用'
        $authSupportJa | Should -Match '設定された `auth_mode`'
        $authSupportJa | Should -Match 'token-broker'
        $authSupportJa | Should -Match 'provider-api-proxy'
    }

    It 'passes the public docs external product reference audit' {
        $output = @(& pwsh -NoProfile -File $auditPublicSurface 2>&1)

        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'audit-public-surface passed'
    }

    It 'allows terminal cursor wording in generated release notes' {
        $releaseBody = Join-Path $TestDrive 'cursor-release-body.md'
        Set-Content -LiteralPath $releaseBody -Value @'
## Bug Fixes

- Cursor movement now preserves position after pane redraws.
'@ -Encoding UTF8

        $output = @(& pwsh -NoProfile -File $auditPublicSurface -ReleaseNotesPath $releaseBody 2>&1)

        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'audit-public-surface passed'
    }

    It 'blocks non-reserved email addresses in public materials without printing the address' {
        $linkedPublicDoc = Join-Path $repoRoot 'docs/source-access.md'
        $original = [System.IO.File]::ReadAllText($linkedPublicDoc)
        $blockedAddress = 'sample.operator' + '@' + ('gmail' + '.com')
        try {
            [System.IO.File]::WriteAllText(
                $linkedPublicDoc,
                $original + "`nMaintainer contact: $blockedAddress`n",
                [System.Text.UTF8Encoding]::new($false)
            )

            $output = @(& pwsh -NoProfile -File $auditPublicSurface 2>&1)

            $LASTEXITCODE | Should -Be 1
            ($output -join "`n") | Should -Match 'public material contains non-reserved email address'
            ($output -join "`n") | Should -Match 'docs/source-access\.md'
            ($output -join "`n") | Should -Not -Match ([Regex]::Escape($blockedAddress))
        } finally {
            [System.IO.File]::WriteAllText($linkedPublicDoc, $original, [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'allows reserved example email addresses in public materials and release notes' {
        $linkedPublicDoc = Join-Path $repoRoot 'docs/source-access.md'
        $original = [System.IO.File]::ReadAllText($linkedPublicDoc)
        $releaseBody = Join-Path $TestDrive 'reserved-email-release-body.md'
        try {
            [System.IO.File]::WriteAllText(
                $linkedPublicDoc,
                $original + "`nFixture contact: winsmux-test@example.invalid`n",
                [System.Text.UTF8Encoding]::new($false)
            )
            Set-Content -LiteralPath $releaseBody -Value @'
## Notes

- Fixture contact remains winsmux-test@example.invalid.
'@ -Encoding UTF8

            $output = @(& pwsh -NoProfile -File $auditPublicSurface -ReleaseNotesPath $releaseBody 2>&1)

            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match 'audit-public-surface passed'
        } finally {
            [System.IO.File]::WriteAllText($linkedPublicDoc, $original, [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'blocks non-reserved email addresses in generated release notes without printing the address' {
        $releaseBody = Join-Path $TestDrive 'personal-email-release-body.md'
        $blockedAddress = 'sample.operator' + '@' + ('gmail' + '.com')
        Set-Content -LiteralPath $releaseBody -Value @"
## Notes

- Maintainer contact: $blockedAddress.
"@ -Encoding UTF8

        $output = @(& pwsh -NoProfile -File $auditPublicSurface -ReleaseNotesPath $releaseBody 2>&1)

        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'release notes contains non-reserved email address'
        ($output -join "`n") | Should -Not -Match ([Regex]::Escape($blockedAddress))
    }

    It 'blocks Google Drive URLs in public materials without printing the URL' {
        $linkedPublicDoc = Join-Path $repoRoot 'docs/source-access.md'
        $original = [System.IO.File]::ReadAllText($linkedPublicDoc)
        $blockedUrl = 'https://drive.google.com/drive/folders/1A2B3C4D5E6F7G8H9I0J'
        try {
            [System.IO.File]::WriteAllText(
                $linkedPublicDoc,
                $original + "`nColab model cache: $blockedUrl`n",
                [System.Text.UTF8Encoding]::new($false)
            )

            $output = @(& pwsh -NoProfile -File $auditPublicSurface 2>&1)

            $LASTEXITCODE | Should -Be 1
            ($output -join "`n") | Should -Match 'public material contains a Google Drive document or folder URL'
            ($output -join "`n") | Should -Match 'docs/source-access\.md'
            ($output -join "`n") | Should -Not -Match ([Regex]::Escape($blockedUrl))
        } finally {
            [System.IO.File]::WriteAllText($linkedPublicDoc, $original, [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'blocks local absolute paths in generated release notes without printing the path' {
        $releaseBody = Join-Path $TestDrive 'private-path-release-body.md'
        $blockedPath = 'D:\work\repo\private-models'
        Set-Content -LiteralPath $releaseBody -Value @"
## Notes

- Colab artifact cache was prepared at $blockedPath.
"@ -Encoding UTF8

        $output = @(& pwsh -NoProfile -File $auditPublicSurface -ReleaseNotesPath $releaseBody 2>&1)

        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'release notes contains a local absolute path'
        ($output -join "`n") | Should -Not -Match ([Regex]::Escape($blockedPath))
    }

    It 'blocks forbidden external product names in linked top-level public docs' {
        $linkedPublicDoc = Join-Path $repoRoot 'docs/authentication-support.md'
        $original = [System.IO.File]::ReadAllText($linkedPublicDoc)
        try {
            [System.IO.File]::WriteAllText(
                $linkedPublicDoc,
                $original + "`nThis public page must not compare winsmux to VS Code.`n",
                [System.Text.UTF8Encoding]::new($false)
            )

            $output = @(& pwsh -NoProfile -File $auditPublicSurface 2>&1)

            $LASTEXITCODE | Should -Be 1
            ($output -join "`n") | Should -Match 'public doc contains forbidden external product/reference'
            ($output -join "`n") | Should -Match 'docs/authentication-support\.md'
        } finally {
            [System.IO.File]::WriteAllText($linkedPublicDoc, $original, [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'blocks paid source disclosure strategy in public materials' {
        $linkedPublicDoc = Join-Path $repoRoot 'docs/source-access.md'
        $original = [System.IO.File]::ReadAllText($linkedPublicDoc)
        try {
            [System.IO.File]::WriteAllText(
                $linkedPublicDoc,
                $original + "`nSelected source can be shared with Substack paid-member reviewers.`n",
                [System.Text.UTF8Encoding]::new($false)
            )

            $output = @(& pwsh -NoProfile -File $auditPublicSurface 2>&1)

            $LASTEXITCODE | Should -Be 1
            ($output -join "`n") | Should -Match 'public material contains paid-source disclosure strategy'
            ($output -join "`n") | Should -Match 'docs/source-access\.md'
        } finally {
            [System.IO.File]::WriteAllText($linkedPublicDoc, $original, [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'allows upstream names in third-party notices for attribution' {
        $noticePath = Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md'
        $original = [System.IO.File]::ReadAllText($noticePath)
        try {
            [System.IO.File]::WriteAllText(
                $noticePath,
                $original + "`nTemporary attribution line for VS Code provenance.`n",
                [System.Text.UTF8Encoding]::new($false)
            )

            $output = @(& pwsh -NoProfile -File $auditPublicSurface 2>&1)

            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match 'audit-public-surface passed'
        } finally {
            [System.IO.File]::WriteAllText($noticePath, $original, [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'blocks forbidden external product names in generated release notes' {
        $releaseBody = Join-Path $TestDrive 'release-body.md'
        Set-Content -LiteralPath $releaseBody -Value @'
## New Features

- Keeps the operator flow separate from VS Code-style workbench assumptions.
'@ -Encoding UTF8

        $output = @(& pwsh -NoProfile -File $auditPublicSurface -ReleaseNotesPath $releaseBody 2>&1)

        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'release notes contains forbidden external product/reference'
        ($output -join "`n") | Should -Match "name 'VS Code'"
    }

    It 'blocks non-reserved email addresses staged for public materials without printing the address' {
        $fixtureRepo = Join-Path $TestDrive 'staged-personal-email-repo'
        New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'scripts') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'docs') -Force | Out-Null
        Copy-Item -LiteralPath $auditStagedPublicSurface -Destination (Join-Path $fixtureRepo 'scripts/audit-staged-public-surface.ps1')
        & git -C $fixtureRepo init | Out-Null
        & git -C $fixtureRepo config user.name 'winsmux-test' | Out-Null
        & git -C $fixtureRepo config user.email 'winsmux-test@example.invalid' | Out-Null

        $blockedAddress = 'sample.operator' + '@' + ('gmail' + '.com')
        Set-Content -LiteralPath (Join-Path $fixtureRepo 'docs/release-notes.md') -Value "Maintainer contact: $blockedAddress" -Encoding UTF8
        & git -C $fixtureRepo add docs/release-notes.md scripts/audit-staged-public-surface.ps1 | Out-Null

        Push-Location -LiteralPath $fixtureRepo
        try {
            $output = @(& pwsh -NoProfile -File (Join-Path $fixtureRepo 'scripts/audit-staged-public-surface.ps1') 2>&1)
        } finally {
            Pop-Location
        }

        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'staged public material contains non-reserved email address'
        ($output -join "`n") | Should -Match 'docs/release-notes\.md'
        ($output -join "`n") | Should -Not -Match ([Regex]::Escape($blockedAddress))
    }

    It 'allows reserved example email addresses staged for public materials' {
        $fixtureRepo = Join-Path $TestDrive 'staged-reserved-email-repo'
        New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'scripts') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'docs') -Force | Out-Null
        Copy-Item -LiteralPath $auditStagedPublicSurface -Destination (Join-Path $fixtureRepo 'scripts/audit-staged-public-surface.ps1')
        & git -C $fixtureRepo init | Out-Null
        & git -C $fixtureRepo config user.name 'winsmux-test' | Out-Null
        & git -C $fixtureRepo config user.email 'winsmux-test@example.invalid' | Out-Null

        Set-Content -LiteralPath (Join-Path $fixtureRepo 'docs/release-notes.md') -Value 'Fixture contact: winsmux-test@example.invalid' -Encoding UTF8
        & git -C $fixtureRepo add docs/release-notes.md scripts/audit-staged-public-surface.ps1 | Out-Null

        Push-Location -LiteralPath $fixtureRepo
        try {
            $output = @(& pwsh -NoProfile -File (Join-Path $fixtureRepo 'scripts/audit-staged-public-surface.ps1') 2>&1)
        } finally {
            Pop-Location
        }

        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'audit-staged-public-surface passed'
    }

    It 'blocks staged Google Drive URLs and local absolute paths without printing the values' {
        $fixtureRepo = Join-Path $TestDrive 'staged-private-runtime-reference-repo'
        New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'scripts') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'docs') -Force | Out-Null
        Copy-Item -LiteralPath $auditStagedPublicSurface -Destination (Join-Path $fixtureRepo 'scripts/audit-staged-public-surface.ps1')
        & git -C $fixtureRepo init | Out-Null
        & git -C $fixtureRepo config user.name 'winsmux-test' | Out-Null
        & git -C $fixtureRepo config user.email 'winsmux-test@example.invalid' | Out-Null

        $blockedUrl = 'https://drive.google.com/file/d/1Z2Y3X4W5V6U7T8S9R0Q/view'
        $blockedPath = 'E:\private\colab-cache'
        Set-Content -LiteralPath (Join-Path $fixtureRepo 'docs/release-notes.md') -Value "Cache: $blockedUrl`nMirror: $blockedPath" -Encoding UTF8
        & git -C $fixtureRepo add docs/release-notes.md scripts/audit-staged-public-surface.ps1 | Out-Null

        Push-Location -LiteralPath $fixtureRepo
        try {
            $output = @(& pwsh -NoProfile -File (Join-Path $fixtureRepo 'scripts/audit-staged-public-surface.ps1') 2>&1)
        } finally {
            Pop-Location
        }

        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'staged public material contains a Google Drive document or folder URL'
        ($output -join "`n") | Should -Match 'staged public material contains a local absolute path'
        ($output -join "`n") | Should -Not -Match ([Regex]::Escape($blockedUrl))
        ($output -join "`n") | Should -Not -Match ([Regex]::Escape($blockedPath))
    }

    It 'uses recorded-baseline gitleaks scans for routine push and CI checks' {
        $workflow = Get-Content (Join-Path $repoRoot '.github/workflows/test.yml') -Raw
        $preCommit = Get-Content (Join-Path $repoRoot '.githooks/pre-commit') -Raw
        $prePush = Get-Content (Join-Path $repoRoot '.githooks/pre-push') -Raw
        $gitleaksScript = Get-Content (Join-Path $repoRoot 'scripts/gitleaks-history.ps1') -Raw
        $baseline = Get-Content (Join-Path $repoRoot 'scripts/gitleaks-history-baseline.txt') -Raw

        $workflow | Should -Match 'Gitleaks Incremental Scan'
        $workflow | Should -Match 'Run secret scan since recorded baseline'
        $workflow | Should -Not -Match 'Run full-history secret scan'

        $preCommit | Should -Match 'scripts\\\\git-guard\.ps1" -Mode staged'
        $preCommit | Should -Match 'scripts\\\\audit-staged-public-surface\.ps1'
        $prePush | Should -Match 'scripts\\\\audit-public-surface\.ps1'
        $prePush | Should -Match 'scripts\\\\gitleaks-history\.ps1'
        $gitleaksScript | Should -Match 'BaselineFile'
        $gitleaksScript | Should -Match 'baselineCommit\.\.HEAD'
        $gitleaksScript | Should -Match '-Full'
        $gitleaksScript | Should -Match '-UpdateBaseline'
        $baseline.Trim() | Should -Match '^[0-9a-f]{40}$'
    }
}
