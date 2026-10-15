$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Public strategy boundary' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
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
