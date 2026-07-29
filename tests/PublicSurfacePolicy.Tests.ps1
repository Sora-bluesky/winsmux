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
        $designFreezeGate = Get-Content (Join-Path $repoRoot 'docs/project/design-freeze-gate.md') -Raw
        $gitignore = Get-Content (Join-Path $repoRoot '.gitignore') -Raw
        $claudeContract = Get-Content (Join-Path $repoRoot '.claude/CLAUDE.md') -Raw
        $thirdPartyNotices = Get-Content (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') -Raw
        $appIndex = Get-Content (Join-Path $repoRoot 'winsmux-app/index.html') -Raw
        $syncRoadmap = Get-Content (Join-Path $repoRoot 'winsmux-core/scripts/sync-roadmap.ps1') -Raw
        $syncInternalDocs = Get-Content (Join-Path $repoRoot 'winsmux-core/scripts/sync-internal-docs.ps1') -Raw
        $installer = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
        $desktopPaneE2E = Get-Content (Join-Path $repoRoot 'winsmux-app/scripts/desktop-pane-e2e.mjs') -Raw
        $auditPublicSurface = Join-Path $repoRoot 'scripts/audit-public-surface.ps1'
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

    It 'loads roadmap title localization with skip-limit and fail-fast diagnostics' {
        foreach ($syncScript in @($syncRoadmap, $syncInternalDocs)) {
            $syncScript | Should -Match 'Import-PowerShellDataFile\s+-LiteralPath\s+\$Path\s+-SkipLimitCheck\s+-ErrorAction\s+Stop'
        }
    }

    It 'renders roadmap tasks in curated order with Japanese five-column tables' {
        $backlog = Join-Path $TestDrive 'roadmap-backlog.yaml'
        $roadmap = Join-Path $TestDrive 'ROADMAP.md'
        $titles = Join-Path $TestDrive 'roadmap-title-ja.psd1'
        $fixtureScripts = Join-Path $TestDrive 'winsmux-core/scripts'
        $null = New-Item -ItemType Directory -Path $fixtureScripts -Force
        foreach ($scriptName in @('sync-roadmap.ps1', 'planning-paths.ps1')) {
            Copy-Item -LiteralPath (Join-Path $repoRoot "winsmux-core/scripts/$scriptName") -Destination (Join-Path $fixtureScripts $scriptName)
        }
        # The fixture deliberately omits sync-internal-docs.ps1. The generator's
        # existing Test-Path guard prevents repo-side effects without an opt-out.
        $syncScript = Join-Path $fixtureScripts 'sync-roadmap.ps1'

        Set-Content -LiteralPath $titles -Encoding UTF8 -Value @'
@{
    VersionTitles = @{
        "v0.36.29" = "完了済みの旧版"
        "v0.36.30" = "現在版"
        "v0.36.31" = "次版"
        "v1.2.0" = "長期版"
    }
    TaskTitles = @{
        "TASK-100" = "依存先の後に実行"
        "TASK-101" = "完了済みの前提"
        "TASK-102" = "優先度中"
        "TASK-103" = "優先度最優先"
        "TASK-104" = "ブロック形式の依存"
        "TASK-105" = "後続の依存"
        "TASK-106" = "別版の依存"
        "TASK-107" = "別版の優先度順"
        "TASK-108" = "完了済みの旧作業"
        "TASK-110" = "長期の作業"
        "TASK-111" = "長期の完了済み作業"
        "TASK-120" = "欠落参照"
        "TASK-130" = "循環一"
        "TASK-131" = "循環二"
    }
}
'@

        Set-Content -LiteralPath $backlog -Encoding UTF8 -Value @'
# === v0.36.30: current ===
# === v0.36.31: next ===
# === v1.2.0: long ===
tasks:
  - id: TASK-100
    title: consumer
    status: todo
    priority: P0
    roadmap_order: 6
    target_version: v0.36.30
    depends_on: [TASK-101]
  - id: TASK-101
    title: prerequisite
    status: done
    priority: P3
    roadmap_order: 5
    target_version: v0.36.30
  - id: TASK-102
    title: medium
    status: todo
    priority: P1
    roadmap_order: 3
    target_version: v0.36.30
  - id: TASK-103
    title: highest
    status: wip
    priority: P0
    roadmap_order: 1
    target_version: v0.36.30
  - id: TASK-104
    title: block dependency
    status: todo
    priority: P0
    roadmap_order: 2
    target_version: v0.36.30
    depends_on:
      - TASK-103
  - id: TASK-105
    title: later dependency
    status: todo
    priority: P2
    roadmap_order: 4
    target_version: v0.36.30
    depends_on: [TASK-104, TASK-103]
  - id: TASK-106
    title: cross release
    status: todo
    priority: P0
    target_version: v0.36.31
    depends_on: [TASK-100]
  - id: TASK-107
    title: next priority
    status: todo
    priority: P1
    target_version: v0.36.31
  - id: TASK-108
    title: completed historical
    status: done
    priority: P0
    target_version: v0.36.29
  - id: TASK-110
    title: long term
    status: todo
    priority: P0
    target_version: v1.2.0
  - id: TASK-111
    title: completed long term
    status: done
    priority: P1
    target_version: v1.2.0
'@

        $output = @(& pwsh -NoProfile -File $syncScript -BacklogPath $backlog -RoadmapPath $roadmap -RoadmapTitleJaPath $titles 2>&1)
        $LASTEXITCODE | Should -Be 0
        $rendered = Get-Content -LiteralPath $roadmap -Raw

        foreach ($taskId in @('TASK-103', 'TASK-102', 'TASK-101', 'TASK-100', 'TASK-104', 'TASK-105')) {
            $rendered | Should -Match ([regex]::Escape($taskId))
        }
        $rendered.IndexOf('TASK-103') | Should -BeLessThan $rendered.IndexOf('TASK-104')
        $rendered.IndexOf('TASK-104') | Should -BeLessThan $rendered.IndexOf('TASK-102')
        $rendered.IndexOf('TASK-102') | Should -BeLessThan $rendered.IndexOf('TASK-105')
        $rendered.IndexOf('TASK-105') | Should -BeLessThan $rendered.IndexOf('TASK-101')
        $rendered.IndexOf('TASK-101') | Should -BeLessThan $rendered.IndexOf('TASK-100')
        $rendered.IndexOf('TASK-106') | Should -BeLessThan $rendered.IndexOf('TASK-107')
        $rendered | Should -Match '### v0\.36\.31: 次版'
        $rendered | Should -Match '### v1\.2\.0: 長期版'
        $rendered | Should -Match '\| 順 \| Task \| 状態 \| 依存 \| やること \|'
        $rendered | Should -Match '\| 1 \| TASK-103 \| 作業中 \| — \| 優先度最優先 \|'
        $rendered | Should -Match '\| 2 \| TASK-104 \| 未着手 \| TASK-103 \| ブロック形式の依存 \|'
        $rendered | Should -Match '\| 4 \| TASK-105 \| 未着手 \| TASK-104, TASK-103 \| 後続の依存 \|'
        $rendered | Should -Match '\| 5 \| TASK-101 \| 完了 \| — \| 完了済みの前提 \|'
        $rendered | Should -Match '\| 1 \| TASK-106 \| 未着手 \| TASK-100 \| 別版の依存 \|'
        $rendered | Should -Not -Match '### v0\.36\.29'
        $rendered | Should -Not -Match 'TASK-108'
        $rendered | Should -Not -Match 'TASK-111'
        $rendered | Should -Not -Match '\|\s*対象\s*\|'
        $rendered | Should -Not -Match '\| 順 \| ID \|'
        $rendered | Should -Not -Match '\|\s*優先度\s*\|'
        $rendered | Should -Not -Match '一意な責任'
        $rendered | Should -Not -Match '\b(todo|wip)\b'
        $rendered | Should -Not -Match '\[x\]|\[-\]|\[R\]|\[ \]'

        $firstBytes = [System.IO.File]::ReadAllBytes($roadmap)
        $output = @(& pwsh -NoProfile -File $syncScript -BacklogPath $backlog -RoadmapPath $roadmap -RoadmapTitleJaPath $titles 2>&1)
        $LASTEXITCODE | Should -Be 0
        [System.IO.File]::ReadAllBytes($roadmap) | Should -Be $firstBytes

        Set-Content -LiteralPath $backlog -Encoding UTF8 -Value @'
# === v0.36.30: current ===
tasks:
  - id: TASK-120
    title: missing
    status: todo
    priority: P0
    target_version: v0.36.30
    depends_on: [TASK-999]
'@
        $output = @(& pwsh -NoProfile -File $syncScript -BacklogPath $backlog -RoadmapPath $roadmap -RoadmapTitleJaPath $titles 2>&1)
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'task TASK-120 in v0\.36\.30 references missing dependency TASK-999'
        [System.IO.File]::ReadAllBytes($roadmap) | Should -Be $firstBytes

        Set-Content -LiteralPath $backlog -Encoding UTF8 -Value @'
# === v0.36.30: current ===
tasks:
  - id: TASK-130
    title: first cycle
    status: todo
    priority: P1
    roadmap_order: 2
    target_version: v0.36.30
    depends_on: [TASK-131]
  - id: TASK-131
    title: second cycle
    status: todo
    priority: P0
    roadmap_order: 1
    target_version: v0.36.30
    depends_on: [TASK-130]
'@
        $output = @(& pwsh -NoProfile -File $syncScript -BacklogPath $backlog -RoadmapPath $roadmap -RoadmapTitleJaPath $titles 2>&1)
        $LASTEXITCODE | Should -Be 0
        $rendered = Get-Content -LiteralPath $roadmap -Raw
        $rendered | Should -Match '\| 1 \| TASK-131 \| 未着手 \| TASK-130 \| 循環二 \|'
        $rendered | Should -Match '\| 2 \| TASK-130 \| 未着手 \| TASK-131 \| 循環一 \|'

        $invalidOrderCases = @(
            [pscustomobject]@{ Name = 'all-or-none'; Body = @'
  - id: TASK-140
    title: first
    status: todo
    priority: P0
    roadmap_order: 1
    target_version: v0.36.30
  - id: TASK-141
    title: second
    status: todo
    priority: P1
    target_version: v0.36.30
'@; Pattern = 'requires roadmap_order for every rendered task' },
            [pscustomobject]@{ Name = 'duplicate'; Body = @'
  - id: TASK-142
    title: first
    status: todo
    priority: P0
    roadmap_order: 1
    target_version: v0.36.30
  - id: TASK-143
    title: second
    status: todo
    priority: P1
    roadmap_order: 1
    target_version: v0.36.30
'@; Pattern = 'reuses roadmap_order 1' },
            [pscustomobject]@{ Name = 'gap'; Body = @'
  - id: TASK-144
    title: first
    status: todo
    priority: P0
    roadmap_order: 1
    target_version: v0.36.30
  - id: TASK-145
    title: second
    status: todo
    priority: P1
    roadmap_order: 3
    target_version: v0.36.30
'@; Pattern = 'must use contiguous roadmap_order values 1\.\.2; missing 2' },
            [pscustomobject]@{ Name = 'non-positive'; Body = @'
  - id: TASK-146
    title: first
    status: todo
    priority: P0
    roadmap_order: 0
    target_version: v0.36.30
  - id: TASK-147
    title: second
    status: todo
    priority: P1
    roadmap_order: 2
    target_version: v0.36.30
'@; Pattern = 'invalid roadmap_order 0' },
            [pscustomobject]@{ Name = 'non-integer'; Body = @'
  - id: TASK-148
    title: first
    status: todo
    priority: P0
    roadmap_order: one
    target_version: v0.36.30
  - id: TASK-149
    title: second
    status: todo
    priority: P1
    roadmap_order: 2
    target_version: v0.36.30
'@; Pattern = 'invalid roadmap_order one' }
        )
        $preservedBytes = [System.IO.File]::ReadAllBytes($roadmap)
        foreach ($case in $invalidOrderCases) {
            Set-Content -LiteralPath $backlog -Encoding UTF8 -Value ("# === v0.36.30: current ===`ntasks:`n" + $case.Body)
            $output = @(& pwsh -NoProfile -File $syncScript -BacklogPath $backlog -RoadmapPath $roadmap -RoadmapTitleJaPath $titles 2>&1)
            $LASTEXITCODE | Should -Be 1 -Because $case.Name
            ($output -join "`n") | Should -Match $case.Pattern
            [System.IO.File]::ReadAllBytes($roadmap) | Should -Be $preservedBytes
        }
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
        $installer | Should -Match 'Install-CoreSupportScripts'
        $installer | Should -Match 'winsmux-core/scripts/public-first-run\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/control-plane-commands\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/control-plane-dispatch\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/control-plane-workers\.ps1'
        $installer | Should -Match 'winsmux-core/scripts/control-plane-ledger\.ps1'
        $installer | Should -Match 'function Test-RemoteFileExists'
        $installer | Should -Match 'function Download-OptionalFile'
        $installer | Should -Match 'Skipping optional \$relativeUrl'
        $coreSupportFiles = [regex]::Match($installer, '(?s)function Install-CoreSupportScripts \{(?<files>.*?)\n\}')
        $coreSupportFiles.Success | Should -BeTrue
        $coreSupportFiles.Groups['files'].Value | Should -Match 'Download-OptionalFile'
        $coreSupportFiles.Groups['files'].Value | Should -Not -Match 'Download-File "winsmux-core/scripts/control-plane-workers\.ps1"'
        $coreSupportFiles.Groups['files'].Value | Should -Not -Match 'Download-File "winsmux-core/scripts/control-plane-ledger\.ps1"'
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
        $installer | Should -Match 'winsmux-core/scripts/common-contract\.generated\.ps1'
        $installer | Should -Match '"control-plane-commands\.ps1"'
        $installer | Should -Match '"common-contract\.generated\.ps1"'
        $orchestrationRemovalFiles = [regex]::Match($installer, '(?s)Content = "orchestration_scripts".*?Files = @\((?<files>.*?)\)\s*\}')
        $orchestrationRemovalFiles.Success | Should -BeTrue
        $orchestrationRemovalFiles.Groups['files'].Value | Should -Not -Match '"control-plane-workers\.ps1"'
        $orchestrationRemovalFiles.Groups['files'].Value | Should -Not -Match '"control-plane-ledger\.ps1"'
    }

    It 'keeps public install and OAuth wording aligned with the current policy' {
        $authSupport = Get-Content (Join-Path $repoRoot 'docs/authentication-support.md') -Raw
        $authSupportJa = Get-Content (Join-Path $repoRoot 'docs/authentication-support.ja.md') -Raw

        $readme | Should -Not -Match 'raw\.githubusercontent\.com/Sora-bluesky/winsmux/main/install\.ps1'
        $readmeJa | Should -Not -Match 'raw\.githubusercontent\.com/Sora-bluesky/winsmux/main/install\.ps1'

        $readme | Should -Match 'npm install -g winsmux'
        $readmeJa | Should -Match 'npm install -g winsmux'

        $readme | Should -Match 'Claude Code \| Pro / Max OAuth \| This PC only, interactive use'
        $readme | Should -Match 'Antigravity CLI \| Official Antigravity CLI sign-in \| This PC only, interactive use'
        $readme | Should -Match 'Gemini \| Google OAuth \| Legacy / tier-limited, this PC only'
        $readme | Should -Match '2026-06-18'
        $readme | Should -Match 'Google AI Pro'
        $readme | Should -Match 'Google AI Ultra'
        $readme | Should -Match 'Google AI Standard and Enterprise'
        $readmeJa | Should -Match 'Claude Code \| Pro / Max OAuth \| 当該 PC での対話利用のみ'
        $readmeJa | Should -Match 'Antigravity CLI \| 公式 Antigravity CLI のサインイン \| 当該 PC での対話利用のみ'
        $readmeJa | Should -Match 'Gemini \| Google OAuth \| 互換目的 / tier 制限あり、この PC のみ'
        $readmeJa | Should -Match '2026-06-18'
        $readmeJa | Should -Match 'Google AI Pro'
        $readmeJa | Should -Match 'Google AI Ultra'
        $readmeJa | Should -Match 'Google AI Standard と Enterprise'

        $authSupport | Should -Match 'claude-pro-max-oauth.*interactive use on that same PC'
        $authSupport | Should -Match 'antigravity-official-cli.*interactive use on that same PC'
        $authSupport | Should -Match 'gemini-google-oauth.*tier-limited after 2026-06-18'
        $authSupport | Should -Match 'Antigravity CLI'
        $authSupport | Should -Match 'Gemini Code Assist for individuals'
        $authSupport | Should -Match 'configured `auth_mode`'
        $authSupport | Should -Match 'token-broker'
        $authSupport | Should -Match 'provider-api-proxy'
        $authSupportJa | Should -Match 'claude-pro-max-oauth.*その PC 上での対話利用のみ'
        $authSupportJa | Should -Match 'antigravity-official-cli.*その PC 上での対話利用のみ'
        $authSupportJa | Should -Match 'gemini-google-oauth.*2026-06-18 以降は互換目的'
        $authSupportJa | Should -Match 'Antigravity CLI'
        $authSupportJa | Should -Match 'Gemini Code Assist for individuals'
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

    It 'blocks hosted API keys and provider request ids in generated release notes' {
        $releaseBody = Join-Path $TestDrive 'hosted-api-release-body.md'
        $openRouterKey = 'sk-or-' + 'v1-' + ('a' * 24)
        Set-Content -LiteralPath $releaseBody -Value @"
## New Features

- Hosted worker smoke used $openRouterKey.
- provider_request_id=req_release_123456789
"@ -Encoding UTF8

        $output = @(& pwsh -NoProfile -File $auditPublicSurface -ReleaseNotesPath $releaseBody 2>&1)

        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'hosted API runtime secret or request metadata'
        ($output -join "`n") | Should -Match 'OpenRouter'
        ($output -join "`n") | Should -Match 'provider request id'
    }

    It 'keeps evidence/auth secret scanning wired into git and public-surface gates' {
        $gitGuard = Get-Content (Join-Path $repoRoot 'scripts/git-guard.ps1') -Raw
        $publicAudit = Get-Content (Join-Path $repoRoot 'scripts/audit-public-surface.ps1') -Raw

        $gitGuard | Should -Match 'function Test-EvidenceAuthLeak'
        $gitGuard | Should -Match 'evidence/auth secret leak'
        $gitGuard | Should -Match 'OpenRouter API key'
        $gitGuard | Should -Match 'GitHub token'
        $gitGuard | Should -Match 'function Test-ExternalRoadmapFreshness'
        $gitGuard | Should -Match 'external ROADMAP is older than backlog.yaml'
        $gitGuard | Should -Match 'function Test-StaleMainDirtyState'
        $gitGuard | Should -Match 'fast-forward main before interpreting or committing local diffs'
        $publicAudit | Should -Match 'function Test-IsEvidenceAuthScanSurface'
        $publicAudit | Should -Match 'function Add-ForbiddenEvidenceAuthFailures'
        $publicAudit | Should -Match 'evidence/auth surface'
    }

    It 'blocks stale external roadmap output before git operations' {
        $gitGuard = Join-Path $repoRoot 'scripts/git-guard.ps1'
        $backlog = Join-Path $TestDrive 'backlog.yaml'
        $roadmap = Join-Path $TestDrive 'ROADMAP.md'
        Set-Content -LiteralPath $backlog -Value "version: 3`ntasks: []`n" -Encoding UTF8
        Set-Content -LiteralPath $roadmap -Value "# ロードマップ`n" -Encoding UTF8
        $now = [DateTime]::UtcNow
        [System.IO.File]::SetLastWriteTimeUtc($roadmap, $now.AddMinutes(-10))
        [System.IO.File]::SetLastWriteTimeUtc($backlog, $now)

        $previousBacklogPath = $env:WINSMUX_BACKLOG_PATH
        $previousRoadmapPath = $env:WINSMUX_ROADMAP_PATH
        try {
            $env:WINSMUX_BACKLOG_PATH = $backlog
            $env:WINSMUX_ROADMAP_PATH = $roadmap

            $output = @(& pwsh -NoProfile -File $gitGuard -Mode staged 2>&1)

            $LASTEXITCODE | Should -Be 1
            ($output -join "`n") | Should -Match 'external ROADMAP is older than backlog.yaml'
        } finally {
            $env:WINSMUX_BACKLOG_PATH = $previousBacklogPath
            $env:WINSMUX_ROADMAP_PATH = $previousRoadmapPath
        }
    }

    It 'keeps desktop dynamic rendering out of innerHTML assignments' {
        $mainTs = Get-Content (Join-Path $repoRoot 'winsmux-app/src/main.ts') -Raw
        $unsafeAssignments = @(
            $mainTs -split "`r?`n" |
                Where-Object { $_ -match 'innerHTML\s*=' -and $_ -notmatch 'innerHTML\s*=\s*""\s*;' } |
                ForEach-Object { $_.Trim() }
        )

        @($unsafeAssignments).Count | Should -Be 0
    }

    It 'keeps the v0.36.24 design-freeze gate anchored to required surfaces' {
        foreach ($source in @(
                'docs/project/component-map.md',
                'docs/project/contract-source-of-truth-inventory.md',
                'docs/project/metrics-baseline.md',
                'docs/project/compatibility-deprecation-policy.md'
            )) {
            $designFreezeGate | Should -Match ([Regex]::Escape($source))
        }

        foreach ($heading in @(
                '## Frozen module boundaries',
                '## Contract freeze',
                '## Size and coupling budget',
                '## No-go conditions',
                '## Release blockers',
                '## Verification',
                '## TASK-723 handoff'
            )) {
            $designFreezeGate | Should -Match ([Regex]::Escape($heading))
        }

        foreach ($surface in @(
                'scripts/winsmux-core.ps1',
                'winsmux-app/src/main.ts',
                'core/src/operator_cli.rs',
                'winsmux-app/src-tauri/src/desktop_backend.rs',
                'Agent Vault provider vocabulary',
                'Route role taxonomy',
                'Concrete worker-backend',
                'Mailbox envelope'
            )) {
            $designFreezeGate | Should -Match ([Regex]::Escape($surface))
        }

        $designFreezeGate | Should -Match 'scripts/audit-public-surface\.ps1'
        $designFreezeGate | Should -Match 'tests/PublicSurfacePolicy\.Tests\.ps1'
        $designFreezeGate | Should -Match '\.githooks/pre-commit-whitelist\.ps1'
        $designFreezeGate | Should -Match 'rg -n "([^"]+)" docs/project/design-freeze-gate\.md'
        $legacyLiteralPattern = [regex]::Match($designFreezeGate, 'rg -n "([^"]+)" docs/project/design-freeze-gate\.md').Groups[1].Value
        foreach ($legacyLiteral in @('ps' + 'mux', 'pm' + 'ux', 't' + 'mux')) {
            $legacyLiteral | Should -Match $legacyLiteralPattern
        }
        foreach ($nonLegacyLiteral in @('psux', 'pmmux')) {
            $nonLegacyLiteral | Should -Not -Match $legacyLiteralPattern
        }
    }

    It 'keeps desktop E2E control-pipe calls authenticated' {
        $desktopPaneE2E | Should -Match 'const CONTROL_PIPE_TOKEN'
        $desktopPaneE2E | Should -Match 'WINSMUX_DESKTOP_E2E_CONTROL_PIPE_TOKEN'
        $desktopPaneE2E | Should -Match 'WINSMUX_CONTROL_PIPE_TOKEN:\s*CONTROL_PIPE_TOKEN'
        $desktopPaneE2E | Should -Match 'auth:\s*\{\s*token:\s*CONTROL_PIPE_TOKEN'
        $desktopPaneE2E | Should -Not -Match 'process\.env\.WINSMUX_CONTROL_PIPE_TOKEN'
        $desktopPaneE2E | Should -Not -Match '"pty\.write",\s*params:'
    }

    It 'keeps the desktop control token out of spawned PTY environments' {
        $libRs = Get-Content (Join-Path $repoRoot 'winsmux-app/src-tauri/src/lib.rs') -Raw

        $libRs | Should -Match 'WINSMUX_CONTROL_PIPE_TOKEN_ENV'
        $libRs | Should -Match 'cmd\.env_remove\(WINSMUX_CONTROL_PIPE_TOKEN_ENV\);'
    }

    It 'uses recorded-baseline gitleaks scans for routine push and CI checks' {
        $workflow = Get-Content (Join-Path $repoRoot '.github/workflows/test.yml') -Raw
        $prePush = Get-Content (Join-Path $repoRoot '.githooks/pre-push') -Raw
        $gitleaksScript = Get-Content (Join-Path $repoRoot 'scripts/gitleaks-history.ps1') -Raw
        $baseline = Get-Content (Join-Path $repoRoot 'scripts/gitleaks-history-baseline.txt') -Raw

        $workflow | Should -Match 'Gitleaks Incremental Scan'
        $workflow | Should -Match 'Run secret scan since recorded baseline'
        $workflow | Should -Not -Match 'Run full-history secret scan'
        $workflow | Should -Match 'name:\s+Merge Gate'
        $workflow | Should -Match 'core-build-test:'
        $workflow | Should -Match 'desktop-build-test:'
        $workflow | Should -Match 'needs\.core-build-test\.result'
        $workflow | Should -Match 'needs\.desktop-build-test\.result'

        $prePush | Should -Match 'scripts\\\\gitleaks-history\.ps1'
        $gitleaksScript | Should -Match 'BaselineFile'
        $gitleaksScript | Should -Match 'baselineCommit\.\.HEAD'
        $gitleaksScript | Should -Match '-Full'
        $gitleaksScript | Should -Match '-UpdateBaseline'
        $baseline.Trim() | Should -Match '^[0-9a-f]{40}$'
    }
}
