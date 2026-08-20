BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:McpServerPath = Join-Path $script:RepoRoot 'winsmux-core\mcp-server.js'
    if ([string]::IsNullOrWhiteSpace($env:WINSMUX_CLI)) {
        $candidates = @()
        if (-not [string]::IsNullOrWhiteSpace($env:CARGO_TARGET_DIR)) {
            $candidates += (Join-Path $env:CARGO_TARGET_DIR 'debug\winsmux.exe')
        }
        $dir = $script:RepoRoot
        while ($dir) {
            $candidates += (Join-Path $dir 'target\debug\winsmux.exe')
            $parent = Split-Path -Parent $dir
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) {
                break
            }
            $dir = $parent
        }
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $env:WINSMUX_CLI = $candidate
                break
            }
        }
    }
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

    It 'exposes winsmux_automation_contract through the MCP tool list' {
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
        $responses[1].result.tools.name | Should -Contain 'winsmux_assign'
        $responses[1].result.tools.name | Should -Contain 'winsmux_automation_contract'
    }

    It 'automation contract tool invokes the native winsmux CLI without pwsh' {
        $content = Get-Content -LiteralPath $script:McpServerPath -Raw -Encoding UTF8

        $content | Should -Match 'function invokeNativeCli'
        $content | Should -Match 'case "winsmux_automation_contract":'
        $content | Should -Match 'return invokeNativeCli\(\["automation-contract"\]\)'
        $content | Should -Match 'execFileSync\(bin,'

        $nativeStart = $content.IndexOf('function invokeNativeCli')
        $nativeStart | Should -BeGreaterThan -1
        $nativeEnd = $content.IndexOf('// --- Tool Handlers ---', $nativeStart)
        $nativeEnd | Should -BeGreaterThan $nativeStart
        $nativeFn = $content.Substring($nativeStart, $nativeEnd - $nativeStart)
        $nativeFn | Should -Not -Match 'invokeBridge'
        $nativeFn | Should -Not -Match 'pwsh'
        $nativeFn | Should -Not -Match 'winsmux-core\.ps1'

        $case = [Regex]::Match(
            $content,
            'case "winsmux_automation_contract":[\s\S]*?return invokeNativeCli\(\["automation-contract"\]\);'
        )
        $case.Success | Should -BeTrue
        $case.Value | Should -Not -Match 'invokeBridge'
        $case.Value | Should -Not -Match 'pwsh'
        $case.Value | Should -Not -Match 'winsmux-core\.ps1'
    }

    It 'automation contract tool fails closed when the desktop pipe is absent' {
        $requests = @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
            '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"winsmux_automation_contract","arguments":{}}}'
        ) -join [Environment]::NewLine

        $output = $requests | & node $script:McpServerPath
        $LASTEXITCODE | Should -Be 0

        $responses = @($output | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object {
            $_ | ConvertFrom-Json
        })

        $responses.Count | Should -Be 2
        $call = $responses[1].result
        if ($call.isError -ne $true) {
            return
        }
        $text = [string]$call.content[0].text
        $text | Should -Not -Match 'pwsh'
        $text | Should -Not -Match 'winsmux-core\.ps1'
        $text | Should -Not -Match 'unknown command'
        (
            $text -match 'desktop control pipe is not available' -or
            $text -match 'ENOENT' -or
            $text -match 'spawn'
        ) | Should -BeTrue
    }

    It 'automation contract tool output matches the pipe contract when the desktop runs' {
        $requests = @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
            '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"winsmux_automation_contract","arguments":{}}}'
        ) -join [Environment]::NewLine

        $output = $requests | & node $script:McpServerPath
        $LASTEXITCODE | Should -Be 0

        $responses = @($output | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object {
            $_ | ConvertFrom-Json
        })

        $responses.Count | Should -Be 2
        $call = $responses[1].result
        if ($call.isError -eq $true) {
            $text = [string]$call.content[0].text
            $text | Should -Not -Match 'pwsh'
            $text | Should -Not -Match 'unknown command'
            (
                $text -match 'desktop control pipe is not available' -or
                $text -match 'ENOENT' -or
                $text -match 'spawn'
            ) | Should -BeTrue
            return
        }

        $contract = $call.content[0].text | ConvertFrom-Json
        $contract.scope | Should -Be 'external_control_pipe'
        @($contract.methods).Count | Should -BeGreaterThan 0
        @($contract.desktop_methods).Count | Should -BeGreaterThan 0
        @($contract.pty_methods).Count | Should -BeGreaterThan 0
        @($contract.operator_methods).Count | Should -BeGreaterThan 0
    }

    It 'exposes winsmux_automation_discover and winsmux_automation_pair through the MCP tool list' {
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
        $names = @($responses[1].result.tools.name)
        $names | Should -Contain 'winsmux_assign'
        $names | Should -Contain 'winsmux_automation_contract'
        $names | Should -Contain 'winsmux_automation_discover'
        $names | Should -Contain 'winsmux_automation_pair'

        $discover = $responses[1].result.tools | Where-Object { $_.name -eq 'winsmux_automation_discover' }
        $pair = $responses[1].result.tools | Where-Object { $_.name -eq 'winsmux_automation_pair' }
        @($discover.inputSchema.required).Count | Should -Be 0
        @($pair.inputSchema.required).Count | Should -Be 0
    }

    It 'automation discover and pair tools invoke the native winsmux CLI without pwsh' {
        $content = Get-Content -LiteralPath $script:McpServerPath -Raw -Encoding UTF8

        $discoverCase = [Regex]::Match(
            $content,
            'case "winsmux_automation_discover":[\s\S]*?return invokeNativeCli\(\["automation-discover"\]\);'
        )
        $pairCase = [Regex]::Match(
            $content,
            'case "winsmux_automation_pair":[\s\S]*?return invokeNativeCli\(\["automation-pair"\]\);'
        )
        $discoverCase.Success | Should -BeTrue
        $pairCase.Success | Should -BeTrue
        foreach ($case in @($discoverCase.Value, $pairCase.Value)) {
            $case | Should -Not -Match 'invokeBridge'
            $case | Should -Not -Match 'pwsh'
            $case | Should -Not -Match 'winsmux-core\.ps1'
        }
    }

    It 'automation discover tool fails closed when the desktop pipe is absent' {
        $requests = @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
            '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"winsmux_automation_discover","arguments":{}}}'
        ) -join [Environment]::NewLine

        $output = $requests | & node $script:McpServerPath
        $LASTEXITCODE | Should -Be 0

        $responses = @($output | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object {
            $_ | ConvertFrom-Json
        })

        $responses.Count | Should -Be 2
        $call = $responses[1].result
        if ($call.isError -ne $true) {
            return
        }
        $text = [string]$call.content[0].text
        $text | Should -Not -Match 'pwsh'
        $text | Should -Not -Match 'unknown command'
        (
            $text -match 'desktop control pipe is not available' -or
            $text -match 'ENOENT' -or
            $text -match 'spawn'
        ) | Should -BeTrue
    }

    It 'automation pair tool fails closed when the desktop pipe is absent or no token exists' {
        $requests = @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
            '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"winsmux_automation_pair","arguments":{}}}'
        ) -join [Environment]::NewLine

        $output = $requests | & node $script:McpServerPath
        $LASTEXITCODE | Should -Be 0

        $responses = @($output | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object {
            $_ | ConvertFrom-Json
        })

        $responses.Count | Should -Be 2
        $call = $responses[1].result
        if ($call.isError -ne $true) {
            return
        }
        $text = [string]$call.content[0].text
        $text | Should -Not -Match 'pwsh'
        $text | Should -Not -Match '"paired":true'
        (
            $text -match 'desktop control pipe is not available' -or
            $text -match 'WINSMUX_CONTROL_PIPE_TOKEN or a non-empty token file is required' -or
            $text -match 'ENOENT' -or
            $text -match 'spawn'
        ) | Should -BeTrue
    }

    It 'automation discover tool reports the live desktop document when the pipe answers' {
        $requests = @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
            '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"winsmux_automation_discover","arguments":{}}}'
        ) -join [Environment]::NewLine

        $output = $requests | & node $script:McpServerPath
        $LASTEXITCODE | Should -Be 0

        $responses = @($output | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object {
            $_ | ConvertFrom-Json
        })

        $responses.Count | Should -Be 2
        $call = $responses[1].result
        if ($call.isError -eq $true) {
            return
        }

        $document = $call.content[0].text | ConvertFrom-Json
        $document.desktop_running | Should -BeTrue
        $document.pipe | Should -Be '\\.\pipe\winsmux-control'
        $document.contract_version | Should -BeOfType [int]
        $document.auth_source | Should -BeIn @('env', 'file')
        $document.connect_ready | Should -BeOfType [bool]
    }

    It 'automation pair tool pairs against the running desktop' {
        $requests = @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
            '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"winsmux_automation_pair","arguments":{}}}'
        ) -join [Environment]::NewLine

        $output = $requests | & node $script:McpServerPath
        $LASTEXITCODE | Should -Be 0

        $responses = @($output | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object {
            $_ | ConvertFrom-Json
        })

        $responses.Count | Should -Be 2
        $call = $responses[1].result
        if ($call.isError -eq $true) {
            return
        }

        $document = $call.content[0].text | ConvertFrom-Json
        $document.paired | Should -BeTrue
        $document.auth_source | Should -BeIn @('env', 'file')
        $null -eq $document.reason | Should -BeTrue
    }

    It 'automation discover and pair tools never print token bytes' {
        $sentinel = 'task802-mcp-env-token-value'
        $previous = $env:WINSMUX_CONTROL_PIPE_TOKEN
        $env:WINSMUX_CONTROL_PIPE_TOKEN = $sentinel
        try {
            $requests = @(
                '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
                '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"winsmux_automation_discover","arguments":{}}}'
                '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"winsmux_automation_pair","arguments":{}}}'
            ) -join [Environment]::NewLine

            $output = $requests | & node $script:McpServerPath
            $LASTEXITCODE | Should -Be 0
            $raw = [string]$output
            $raw | Should -Not -Match [Regex]::Escape($sentinel)
            $raw | Should -Not -Match 'control-pipe\\token'
        }
        finally {
            if ($null -eq $previous) {
                Remove-Item Env:WINSMUX_CONTROL_PIPE_TOKEN -ErrorAction SilentlyContinue
            }
            else {
                $env:WINSMUX_CONTROL_PIPE_TOKEN = $previous
            }
        }
    }

    It 'rejects an unknown tool name over real stdio' {
        $requests = @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
            '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"winsmux_does_not_exist","arguments":{}}}'
        ) -join [Environment]::NewLine

        $output = $requests | & node $script:McpServerPath
        $LASTEXITCODE | Should -Be 0
        $raw = [string]$output
        $raw | Should -Not -Match 'pwsh'
        $raw | Should -Not -Match 'winsmux-core\.ps1'

        $responses = @($output | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object {
            $_ | ConvertFrom-Json
        })

        $call = $responses | Where-Object { $_.id -eq 2 }
        $null -eq $call.error | Should -BeFalse
        $call.error.code | Should -Be -32602
        [string]$call.error.message | Should -Match 'Unknown tool'
        $null -eq $call.result | Should -BeTrue
    }

    It 'rejects an unknown JSON-RPC method with -32601' {
        $requests = @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
            '{"jsonrpc":"2.0","id":2,"method":"bogus/method","params":{}}'
            '{"jsonrpc":"2.0","id":3,"method":"ping","params":{}}'
        ) -join [Environment]::NewLine

        $output = $requests | & node $script:McpServerPath
        $LASTEXITCODE | Should -Be 0

        $responses = @($output | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object {
            $_ | ConvertFrom-Json
        })

        $responses.Count | Should -Be 3
        $unknown = $responses | Where-Object { $_.id -eq 2 }
        $unknown.error.code | Should -Be -32601
        [string]$unknown.error.message | Should -Match 'Method not found'
        $ping = $responses | Where-Object { $_.id -eq 3 }
        $null -eq $ping.error | Should -BeTrue
        $null -eq $ping.result | Should -BeFalse
    }
}
