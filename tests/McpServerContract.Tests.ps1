BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:McpServerPath = Join-Path $script:RepoRoot 'winsmux-core\mcp-server.js'
}

Describe 'winsmux MCP server contract' {
    It 'uses argument-array execution for bridge calls and validates assign task ids' {
        $content = Get-Content -LiteralPath $script:McpServerPath -Raw -Encoding UTF8

        $content | Should -Match 'execFileSync'
        $content | Should -Not -Match 'execSync'
        $content | Should -Match '\^TASK-\\d\+\$'
        $content | Should -Match 'winsmux_assign requires a TASK id'
    }

    It 'keeps winsmux_assign exposed through the MCP tool list' {
        $content = Get-Content -LiteralPath $script:McpServerPath -Raw -Encoding UTF8

        $content | Should -Match 'name: "winsmux_assign"'
        $content | Should -Match 'return invokeBridge\(\["assign", "--task", args\.task, "--json"'
    }
}
