$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Threat model audit contract' {
    BeforeAll {
        $script:RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:RepoRoot)) {
            throw 'Failed to resolve repository root.'
        }

        $script:ThreatModelPath = Join-Path $script:RepoRoot 'docs\project\THREAT_MODEL.md'
        $script:AuditPath = Join-Path $script:RepoRoot 'docs\project\THREAT_MODEL_AUDIT.md'
        $script:ProjectReadmePath = Join-Path $script:RepoRoot 'docs\project\README.md'
        $script:PatternsPath = Join-Path $script:RepoRoot '.claude\patterns\injection-patterns.json'

        $script:ThreatModel = Get-Content -LiteralPath $script:ThreatModelPath -Raw -Encoding UTF8
        $script:Audit = Get-Content -LiteralPath $script:AuditPath -Raw -Encoding UTF8
        $script:ProjectReadme = Get-Content -LiteralPath $script:ProjectReadmePath -Raw -Encoding UTF8
        $script:Patterns = Get-Content -LiteralPath $script:PatternsPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    }

    It 'records exactly 22 unique threat IDs in the threat model' {
        $ids = @(
            [regex]::Matches($script:ThreatModel, '(?m)^\|\s*(TM-\d{3})\s*\|') |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object -Unique
        )

        $ids.Count | Should -Be 22
        $ids[0] | Should -Be 'TM-001'
        $ids[-1] | Should -Be 'TM-022'
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

        $auditIds.Count | Should -Be 22
        $auditIds | Should -Be $threatIds
    }

    It 'keeps injection pattern categories mapped in the threat model' {
        $categories = @($script:Patterns.categories.PSObject.Properties.Name)
        $categories.Count | Should -BeGreaterThan 0

        foreach ($category in $categories) {
            $script:ThreatModel | Should -Match ([regex]::Escape($category))
        }
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
