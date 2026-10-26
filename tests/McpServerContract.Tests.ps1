BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'Current control-plane SDK boundary' {
    It 'does not retain the retired Node adapter or subprocess clients' {
        foreach ($relative in @(
            'winsmux-core/mcp-server.js',
            'winsmux-core/package.json',
            'sdk/python/winsmux.py',
            'sdk/typescript/winsmux.ts'
        )) {
            Test-Path -LiteralPath (Join-Path $script:RepoRoot $relative) |
                Should -BeFalse -Because "$relative is outside the shipped control-plane surface"
        }
    }

    It 'keeps generated control-plane bindings aligned with the checked-in contract' {
        $generator = Join-Path $script:RepoRoot 'winsmux-app/scripts/generate-control-plane-bindings.mjs'
        $output = @(& node $generator --check 2>&1)
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        ($output -join "`n") | Should -Match 'control-plane-bindings: ok'
    }

    It 'documents the current bindings and named-pipe walkthrough' {
        $readme = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'sdk/README.md') -Raw -Encoding UTF8
        foreach ($relative in @(
            'python/control_plane_contract.py',
            'typescript/control-plane-contract.ts',
            'examples/adapter-walkthrough.py'
        )) {
            Test-Path -LiteralPath (Join-Path $script:RepoRoot "sdk/$relative") | Should -BeTrue
            $readme | Should -Match ([regex]::Escape($relative))
        }
        $readme | Should -Not -Match 'mcp-server\.js|WinsmuxClient'
    }
}
