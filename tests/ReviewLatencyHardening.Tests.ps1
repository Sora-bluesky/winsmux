$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Review latency hardening' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
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

    It 'keeps review latency details out of public product docs' {
        $publicDocs = @(
            'README.md',
            'README.ja.md',
            'docs/operator-model.md',
            'docs/external-control-plane.md',
            'docs/external-control-plane.ja.md'
        )
        $forbiddenFragments = @(
            'review-subagent latency',
            'issue #504',
            'issue `#504`',
            'no result yet'
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
