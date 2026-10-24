$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Public review boundary' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
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
