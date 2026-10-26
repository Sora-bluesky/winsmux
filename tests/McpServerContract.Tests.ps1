BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'Current control-plane SDK boundary' {
    It 'keeps the SDK limited to current contract bindings and the walkthrough' {
        $sdkRoot = Join-Path $script:RepoRoot 'sdk'
        $files = @(Get-ChildItem -LiteralPath $sdkRoot -Recurse -File |
            Where-Object { $_.Extension -in @('.py', '.ts', '.md') } |
            ForEach-Object { [IO.Path]::GetRelativePath($sdkRoot, $_.FullName).Replace('\', '/') } |
            Sort-Object)
        $files | Should -Be @('README.md', 'examples/adapter-walkthrough.py',
            'python/control_plane_contract.py', 'typescript/control-plane-contract.ts' | Sort-Object)
    }

    It 'documents the separate control-pipe and Rust workspace MCP surfaces' {
        $adapter = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'core/crates/winsmux-workspace-mcp/src/lib.rs') -Raw
        $adapter | Should -Match 'TOOL_NAME: &str = "winsmux_workspace_request"'
        foreach ($relative in @('docs/external-control-plane.md', 'docs/external-control-plane.ja.md')) {
            $doc = Get-Content -LiteralPath (Join-Path $script:RepoRoot $relative) -Raw -Encoding UTF8
            $doc | Should -Match 'winsmux-workspace-mcp'
            $doc | Should -Match 'winsmux_workspace_request'
            $rows = @($doc -split "\r?\n" | Where-Object { $_ -match '^\| (desktop\.|pty\.)' })
            $rows.Count | Should -BeGreaterThan 0
            foreach ($row in $rows) { $row | Should -Match '\| — \|$' }
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
    }
}
