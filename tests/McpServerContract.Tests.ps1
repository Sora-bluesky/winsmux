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

    It 'documents the upstream-first adapter boundary in initialize metadata' {
        $content = Get-Content -LiteralPath $script:McpServerPath -Raw -Encoding UTF8

        $content | Should -Match 'protocolSource: "upstream-mcp-json-rpc"'
        $content | Should -Match 'transport: "stdio"'
        $content | Should -Match 'shimPolicy: "thin-winsmux-command-adapter"'
        $content | Should -Match '"winsmux/adapterBoundary": ADAPTER_BOUNDARY'
    }

    It 'round-trips initialize and tools/list over stdio transport' {
        $requests = @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
            '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
        ) -join [Environment]::NewLine

        $output = $requests | & node $script:McpServerPath
        $LASTEXITCODE | Should -Be 0

        $responses = @($output | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object {
            $_ | ConvertFrom-Json
        })

        $responses.Count | Should -Be 2
        $responses[0].result.protocolVersion | Should -Be '2024-11-05'
        $responses[0].result._meta.'winsmux/adapterBoundary'.protocolSource | Should -Be 'upstream-mcp-json-rpc'
        $responses[0].result._meta.'winsmux/adapterBoundary'.transport | Should -Be 'stdio'
        $responses[1].result.tools.name | Should -Contain 'winsmux_assign'
    }

    It 'resolves the Python SDK default server path to the tracked MCP server' {
        $python = @'
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
sys.path.insert(0, str(repo_root / "sdk" / "python"))

from winsmux import WinsmuxClient

print(WinsmuxClient._resolve_default_server_path())
'@

        $output = & python -c $python $script:RepoRoot
        $LASTEXITCODE | Should -Be 0

        $resolvedPath = ($output | Select-Object -Last 1).Trim()
        (Split-Path -Leaf $resolvedPath) | Should -Be 'mcp-server.js'
        (Split-Path -Leaf (Split-Path -Parent $resolvedPath)) | Should -Be 'winsmux-core'
        (Test-Path -LiteralPath $resolvedPath -PathType Leaf) | Should -BeTrue
    }

    It 'resolves the TypeScript SDK default server path to the tracked MCP server' {
        $typescriptSdk = Join-Path $script:RepoRoot 'sdk\typescript\winsmux.ts'
        $content = Get-Content -LiteralPath $typescriptSdk -Raw -Encoding UTF8
        $content | Should -Match 'fileURLToPath\(import\.meta\.url\)'
        $resolver = [Regex]::Match(
            $content,
            'return resolve\(moduleDir,\s*(?<segments>[^;]+)\);'
        )
        $resolver.Success | Should -BeTrue

        $segments = @(
            [Regex]::Matches($resolver.Groups['segments'].Value, '"(?<segment>[^"]+)"') |
                ForEach-Object { $_.Groups['segment'].Value }
        )
        $segments | Should -Be @('..', '..', 'winsmux-core', 'mcp-server.js')

        $resolvedPath = Split-Path -Parent $typescriptSdk
        foreach ($segment in $segments) {
            $resolvedPath = Join-Path $resolvedPath $segment
        }
        $resolvedPath = [System.IO.Path]::GetFullPath($resolvedPath)
        (Split-Path -Leaf $resolvedPath) | Should -Be 'mcp-server.js'
        (Split-Path -Leaf (Split-Path -Parent $resolvedPath)) | Should -Be 'winsmux-core'
        (Test-Path -LiteralPath $resolvedPath -PathType Leaf) | Should -BeTrue
    }
}
