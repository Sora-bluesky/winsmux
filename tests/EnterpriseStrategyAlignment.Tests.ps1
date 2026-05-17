$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Enterprise strategy roadmap alignment' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
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

    It 'does not leak internal strategy positioning into public product docs' {
        $publicDocs = @(
            'README.md',
            'README.ja.md',
            'docs/operator-model.md',
            'docs/external-control-plane.md',
            'docs/external-control-plane.ja.md'
        )
        $forbiddenFragments = @(
            'internal enterprise strategy',
            'enterprise strategy-to-roadmap',
            'internal-only positioning',
            'absolute market claims'
        )

        foreach ($relativePath in $publicDocs) {
            $path = Join-Path $script:RepoRoot $relativePath
            Test-Path -LiteralPath $path | Should -BeTrue
            $content = Get-Content -LiteralPath $path -Raw
            foreach ($fragment in $forbiddenFragments) {
                $content | Should -Not -Match ([Regex]::Escape($fragment))
            }
        }
    }
}
