# Replays the Pester checks that c34d6d9b deleted together with the internal records they read.
# Each It body is copied from 36a319d9 (c34d6d9b^) with only its indentation shifted; gate-map.json pins
# the source line range and text digest, and check-map.mjs re-verifies both on every run.
# Only the repository root moves: run.ps1 materializes the pinned c34d6d9b^ blobs under $FixtureRoot.
param(
    [Parameter(Mandatory = $true)][string]$FixtureRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'c34d6d9b^ preserved contracts' {
    Describe 'Threat model audit contract' {
        BeforeAll {
            if (-not (Test-Path -LiteralPath $FixtureRoot -PathType Container)) { throw 'FixtureRoot is required.' }
            $script:RepoRoot = $FixtureRoot
            $script:ThreatModelPath = Join-Path $script:RepoRoot 'docs\project\THREAT_MODEL.md'
            $script:AuditPath = Join-Path $script:RepoRoot 'docs\project\THREAT_MODEL_AUDIT.md'
            $script:ProjectReadmePath = Join-Path $script:RepoRoot 'docs\project\README.md'
            $script:PatternsPath = Join-Path $script:RepoRoot '.claude\patterns\injection-patterns.json'

            $script:ThreatModel = Get-Content -LiteralPath $script:ThreatModelPath -Raw -Encoding UTF8
            $script:Audit = Get-Content -LiteralPath $script:AuditPath -Raw -Encoding UTF8
            $script:ProjectReadme = Get-Content -LiteralPath $script:ProjectReadmePath -Raw -Encoding UTF8
            $script:Patterns = Get-Content -LiteralPath $script:PatternsPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        }

        It 'records exactly 23 unique threat IDs in the threat model' {
            $ids = @(
                [regex]::Matches($script:ThreatModel, '(?m)^\|\s*(TM-\d{3})\s*\|') |
                    ForEach-Object { $_.Groups[1].Value } |
                    Sort-Object -Unique
            )

            $ids.Count | Should -Be 23
            $ids[0] | Should -Be 'TM-001'
            $ids[-1] | Should -Be 'TM-023'
        }

        It 'audits every threat ID from the threat model' {
            $threatIds = @(
                [regex]::Matches($script:ThreatModel, '(?m)^\|\s*(TM-\d{3})\s*\|') |
                    ForEach-Object { $_.Groups[1].Value } |
                    Sort-Object -Unique
            )
            $auditIds = @(
                [regex]::Matches($script:Audit, '(?m)^\|\s*(TM-\d{3})\s*\|') |
                    ForEach-Object { $_.Groups[1].Value } |
                    Sort-Object -Unique
            )

            $auditIds.Count | Should -Be 23
            $auditIds | Should -Be $threatIds
        }

        It 'keeps injection pattern categories mapped in the threat model' {
            $categories = @($script:Patterns.categories.PSObject.Properties.Name)
            $categories.Count | Should -BeGreaterThan 0

            foreach ($category in $categories) {
                $script:ThreatModel | Should -Match ([regex]::Escape($category))
            }
        }

        It 'distinguishes medium single-token warnings from high co-occurrence denial in the audit' {
            $tm005Row = @(
                $script:Audit -split "`r?`n" |
                    Where-Object { $_ -match '^\|\s*TM-005\s*\|' }
            )

            $tm005Row.Count | Should -Be 1
            $tm005Row[0] | Should -Match 'allows with warning context.*medium `encoding_evasion`'
            $tm005Row[0] | Should -Match 'denies.*high-severity `encoding_evasion_combo`'
            $tm005Row[0] | Should -Not -Match 'denies `encoding_evasion`'
        }

        It 'keeps the audit narrative aligned with the 23-threat matrix and current checks' {
            $script:Audit | Should -Match 'checks the 23 threat IDs'
            $script:Audit | Should -Match 'exactly 23 unique threat IDs'
            $script:Audit | Should -Match 'same 23 IDs'
            $script:Audit | Should -Match '23-threat audit matrix'
            $script:Audit | Should -Match 'role-hijack word-boundary behavior'
            $script:Audit | Should -Match 'anchored encoding co-occurrence behavior'
            $script:Audit | Should -Match 'medium single-token warnings from high co-occurrence denial'
        }

        It 'keeps the audit from claiming unconditional safety' {
            $script:Audit | Should -Not -Match '(?i)fully safe|guaranteed safe|no residual risk|zero risk'
            $script:Audit | Should -Match 'residual risk'
        }

        It 'links the threat model and audit from the project documentation index' {
            $script:ProjectReadme | Should -Match 'THREAT_MODEL\.md'
            $script:ProjectReadme | Should -Match 'THREAT_MODEL_AUDIT\.md'
        }
    }

    Describe 'Review latency hardening' {
        BeforeAll {
            if (-not (Test-Path -LiteralPath $FixtureRoot -PathType Container)) { throw 'FixtureRoot is required.' }
            $script:RepoRoot = $FixtureRoot
            $script:ReviewDoc = Join-Path $script:RepoRoot 'docs/project/review-latency-hardening.md'
            $script:ProjectReadme = Join-Path $script:RepoRoot 'docs/project/README.md'
            $script:DetailedDesign = Join-Path $script:RepoRoot 'docs/project/DETAILED_DESIGN.md'
        }

        It 'documents the TASK-372 trigger and stop conditions' {
            Test-Path -LiteralPath $script:ReviewDoc | Should -BeTrue

            $content = Get-Content -LiteralPath $script:ReviewDoc -Raw
            $content | Should -Match 'TASK-372'
            $content | Should -Match 'issue `#504`'
            $content | Should -Match 'small desktop UI or TypeScript'
            $content | Should -Match '1` to `3` changed files'
            $content | Should -Match 'no result yet'
            $content | Should -Match 'twice for the same PR or branch'
            $content | Should -Match 'stop spawning a fresh review subagent'
        }

        It 'fixes the wait, background hold, and milestone review policy' {
            $content = Get-Content -LiteralPath $script:ReviewDoc -Raw
            $content | Should -Match 'First wait \| `10` minutes'
            $content | Should -Match 'Second wait \| `10` minutes'
            $content | Should -Match 'Background hold \| `20` minutes'
            $content | Should -Match 'same agent alive'
            $content | Should -Match 'Switch To Milestone Review'
            $content | Should -Match 'The milestone review must cover all changes since the last accepted review\s+evidence'
        }

        It 'makes delayed review results part of the merge gate' {
            $content = Get-Content -LiteralPath $script:ReviewDoc -Raw
            $content | Should -Match 'The PR must not merge while a delayed review result is unexamined'
            $content | Should -Match 'codex review` passed with the release-review model'
            $content | Should -Match 'This rule is a merge gate'
            $content | Should -Match 'not a permission to skip the release review'
        }

        It 'links the rule from internal project surfaces' {
            $readme = Get-Content -LiteralPath $script:ProjectReadme -Raw
            $design = Get-Content -LiteralPath $script:DetailedDesign -Raw

            $readme | Should -Match '\[Review Latency Hardening\]\(\./review-latency-hardening\.md\)'
            $design | Should -Match '\[Review Latency Hardening\]\(\./review-latency-hardening\.md\)'
        }
    }

    Describe 'Enterprise strategy roadmap alignment' {
        BeforeAll {
            if (-not (Test-Path -LiteralPath $FixtureRoot -PathType Container)) { throw 'FixtureRoot is required.' }
            $script:RepoRoot = $FixtureRoot
            $script:AlignmentDoc = Join-Path $script:RepoRoot 'docs/project/enterprise-strategy-roadmap-alignment.md'
            $script:ProjectReadme = Join-Path $script:RepoRoot 'docs/project/README.md'
        }

        It 'documents the stable roadmap placement for TASK-371' {
            Test-Path -LiteralPath $script:AlignmentDoc | Should -BeTrue

            $content = Get-Content -LiteralPath $script:AlignmentDoc -Raw
            $content | Should -Match 'TASK-371'
            $content | Should -Match 'v0\.22\.x'
            $content | Should -Match 'v0\.24\.x'
            $content | Should -Match 'v1\.3\.0'
            $content | Should -Match 'v1\.4\.0'
            $content | Should -Match 'v1\.5\.0'
            $content | Should -Match 'post-v1\.0\.0-governance'
            $content | Should -Match 'issue `#454`'
        }

        It 'keeps the alignment note linked from the internal planning surface' {
            $readme = Get-Content -LiteralPath $script:ProjectReadme -Raw
            $readme | Should -Match '\[Enterprise Strategy Roadmap Alignment\]\(\./enterprise-strategy-roadmap-alignment\.md\)'
        }
    }

    Describe 'CLI bakeoff evidence harness' {
        BeforeAll {
            if (-not (Test-Path -LiteralPath $FixtureRoot -PathType Container)) { throw 'FixtureRoot is required.' }
            $script:RepoRoot = $FixtureRoot
        }

        It 'routes the formal six-pane benchmark evidence to v0.36.23' {
            $contractDoc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\cli-comparison-bakeoff.md') -Raw -Encoding UTF8
            $contractDoc | Should -Match 'v0\.36\.23'
            $contractDoc | Should -Not -Match 'publishing v0\.36\.22|Before publishing v0\.36\.22|official benchmark evidence.*v0\.36\.22'

            $contractHtml = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\benchmarks\v03617-harness-bench-report.ja.html') -Raw -Encoding UTF8
            $contractHtml | Should -Match 'v0\.36\.23'
            $contractHtml | Should -Not -Match 'v0\.36\.22 測定待ち|v0\.36\.22 で行う正式|6ペイン実測とレポート再作成は v0\.36\.22'
        }

        It 'documents public desktop startup troubleshooting without repo-build process assumptions [v1-release-gate assertions removed by c34d6d9b]' {
            $releaseGate = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\project\v1-release-gate.md') -Raw -Encoding UTF8
            $releaseGate | Should -Match 'Windows Search finds the app by'
            $releaseGate | Should -Match 'Installed apps'
            $releaseGate | Should -Match 'version number is not required in Windows Search'
            $releaseGate | Should -Match 'installed Windows app'
            $releaseGate | Should -Match 'target\\debug'
            $releaseGate | Should -Match 'target\\release'
            $releaseGate | Should -Match '\.local\\bin'
            $releaseGate | Should -Match 'must not be accepted as desktop installer\s+registration or normal-launch proof'
            $releaseGate | Should -Match 'releases/latest'
            $releaseGate | Should -Match 'version-neutral installer example'
            $releaseGate | Should -Match 'winsmux_\.\.\._x64-setup\.exe'
            $releaseGate | Should -Match 'must fail if public install\s+docs contain a fixed release asset name'
            $releaseGate | Should -Match 'winsmux_0\.x\.y_x64-setup\.exe'
            $releaseGate | Should -Match 'Quickstart must stay desktop-app first'
            $releaseGate | Should -Match 'README, Quickstart, Installation, Troubleshooting'
            $releaseGate | Should -Match 'packages/winsmux/README\.md'
            $releaseGate | Should -Match 'Automatic in-app update detection is delivered in the `v0\.36\.23` desktop app'
            $releaseGate | Should -Match 'release gate verifies the update check'
            $releaseGate | Should -Match 'checksum verification when'
            $releaseGate | Should -Not -Match '`v0\.36\.23` cannot ship until update check'
            $releaseGate | Should -Match 'installer-over-existing-install\s+update path'
            $releaseGate | Should -Match 'compact\s+persistent status/action'
            $releaseGate | Should -Match 'download\s+progress\s+from the final update action'
            $releaseGate | Should -Match 'post-install restart guidance'
            $releaseGate | Should -Match 'confirmation dialog'
            $releaseGate | Should -Match 'local active sessions may be interrupted'
            $releaseGate | Should -Match 'installing state with progress text'
            $releaseGate | Should -Match 'Clicking `Cancel` or outside the dialog closes the dialog'
            $releaseGate | Should -Match 'Silent background replacement without user-visible state is not\s+accepted'
        }

        It 'gates desktop releases on signed updater artifacts [v1-release-gate assertions removed by c34d6d9b]' {
            $releaseGate = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\project\v1-release-gate.md') -Raw -Encoding UTF8
            $releaseGate | Should -Match 'TASK-720'
            $releaseGate | Should -Match 'signed desktop updater release assets'
            $releaseGate | Should -Match 'latest\.json'
            $releaseGate | Should -Match '\.sig'
            $releaseGate | Should -Match 'WINDOWS_SIGNING_CERTIFICATE_BASE64'
            $releaseGate | Should -Match 'TAURI_SIGNING_PRIVATE_KEY'
            $releaseGate | Should -Not -Match 'TAURI_UPDATER_PRIVATE_KEY'
            $releaseGate | Should -Match 'unsigned installer'
            $releaseGate | Should -Match 'must\s+not\s+be\s+published'
        }
    }

    Describe 'Public surface policy' {
        BeforeAll {
            if (-not (Test-Path -LiteralPath $FixtureRoot -PathType Container)) { throw 'FixtureRoot is required.' }
            $repoRoot = $FixtureRoot
            $designFreezeGate = Get-Content (Join-Path $repoRoot 'docs/project/design-freeze-gate.md') -Raw
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
    }
}
