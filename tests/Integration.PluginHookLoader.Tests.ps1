$ErrorActionPreference = 'Stop'

Describe 'plugin hook loader integration' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:SourceHookRoot = Join-Path $script:RepoRoot '.claude\hooks'
        $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $nodeCommand) {
            throw 'node was not found in PATH.'
        }

        $script:NodePath = if ($nodeCommand.Path) { $nodeCommand.Path } else { $nodeCommand.Name }

        function Write-TestFile {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)][string]$Content
            )

            $parent = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
        }

        function New-PluginLoaderFixture {
            $repoRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-plugin-loader-' + [guid]::NewGuid().ToString('N'))
            $hooksDir = Join-Path $repoRoot '.claude\hooks'
            $libDir = Join-Path $hooksDir 'lib'
            $pluginsDir = Join-Path $hooksDir 'plugins'

            New-Item -ItemType Directory -Path $libDir -Force | Out-Null
            New-Item -ItemType Directory -Path $pluginsDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:SourceHookRoot 'sh-plugin-loader.js') -Destination (Join-Path $hooksDir 'sh-plugin-loader.js') -Force
            Copy-Item -LiteralPath (Join-Path $script:SourceHookRoot 'lib\sh-utils.js') -Destination (Join-Path $libDir 'sh-utils.js') -Force

            return [PSCustomObject]@{
                RepoRoot   = $repoRoot
                PluginsDir = $pluginsDir
            }
        }

        function Invoke-PluginLoader {
            param(
                [Parameter(Mandatory = $true)][string]$RepoRoot,
                [Parameter(Mandatory = $true)][object]$Payload
            )

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:NodePath
            $startInfo.ArgumentList.Add((Join-Path $RepoRoot '.claude\hooks\sh-plugin-loader.js'))
            $startInfo.WorkingDirectory = $RepoRoot
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true

            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $process.StandardInput.Write(($Payload | ConvertTo-Json -Compress -Depth 20))
                $process.StandardInput.Close()
                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()

                $parsed = $null
                if (-not [string]::IsNullOrWhiteSpace($stdout.Trim())) {
                    $parsed = $stdout | ConvertFrom-Json -Depth 20
                }

                return [PSCustomObject]@{
                    ExitCode = $process.ExitCode
                    StdOut   = $stdout.Trim()
                    StdErr   = $stderr.Trim()
                    Json     = $parsed
                }
            } finally {
                $process.Dispose()
            }
        }
    }

    It 'registers the plugin loader once in every empty matcher hook group' {
        $settingsPath = Join-Path $script:RepoRoot '.claude\settings.json'
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
        $missingEvents = [System.Collections.Generic.List[string]]::new()

        foreach ($event in $settings.hooks.PSObject.Properties) {
            $emptyGroups = @($event.Value | Where-Object {
                $matcher = if ($_.PSObject.Properties['matcher']) { [string]$_.matcher } else { '' }
                $matcher -eq ''
            })

            if ($emptyGroups.Count -eq 0) {
                $missingEvents.Add($event.Name) | Out-Null
                continue
            }

            $loaderCount = @($emptyGroups[0].hooks | Where-Object {
                $_.command -eq 'node .claude/hooks/sh-plugin-loader.js'
            }).Count
            if ($loaderCount -ne 1) {
                $missingEvents.Add($event.Name) | Out-Null
            }
        }

        @($missingEvents).Count | Should -Be 0
    }

    It 'stays silent when no plugins are installed' {
        $fixture = New-PluginLoaderFixture
        try {
            $result = Invoke-PluginLoader -RepoRoot $fixture.RepoRoot -Payload ([ordered]@{
                hook_event_name = 'UserPromptSubmit'
                prompt          = 'hello'
            })

            $result.ExitCode | Should -Be 0
            $result.StdOut | Should -Be ''
            $result.StdErr | Should -Be ''
            $result.Json | Should -Be $null
        } finally {
            Remove-Item -LiteralPath $fixture.RepoRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'runs matching plugins by order and captures plugin console output as evidence' {
        $fixture = New-PluginLoaderFixture
        try {
            Write-TestFile -Path (Join-Path $fixture.PluginsDir 'zeta.js') -Content @'
"use strict";
module.exports = {
  name: "zeta",
  events: ["PreToolUse"],
  order: 20,
  run() {
    console.log("zeta chatter");
    return { additionalContext: "second" };
  },
};
'@
            Write-TestFile -Path (Join-Path $fixture.PluginsDir 'alpha.js') -Content @'
"use strict";
module.exports = {
  name: "alpha",
  events: ["PreToolUse"],
  order: 10,
  run() {
    return { additionalContext: "first" };
  },
};
'@

            $result = Invoke-PluginLoader -RepoRoot $fixture.RepoRoot -Payload ([ordered]@{
                hook_event_name = 'PreToolUse'
                tool_name       = 'Bash'
                tool_input      = [ordered]@{ command = 'git status' }
            })

            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
            $result.StdOut | Should -Not -Match 'zeta chatter'
            $result.Json.hookSpecificOutput.hookEventName | Should -Be 'PreToolUse'
            $result.Json.hookSpecificOutput.additionalContext | Should -Be "[alpha] first`n[zeta] second"

            $evidencePath = Join-Path $fixture.RepoRoot '.claude\logs\evidence-ledger.jsonl'
            $evidence = Get-Content -LiteralPath $evidencePath -Raw -Encoding UTF8
            $evidence | Should -Match 'zeta chatter'
            $evidence | Should -Match '"stage":"run-console"'
        } finally {
            Remove-Item -LiteralPath $fixture.RepoRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'emits a structured PreToolUse denial when a plugin denies access' {
        $fixture = New-PluginLoaderFixture
        try {
            Write-TestFile -Path (Join-Path $fixture.PluginsDir 'deny.js') -Content @'
"use strict";
module.exports = {
  name: "deny-fixture",
  events: ["PreToolUse"],
  run() {
    return { permissionDecision: "deny", permissionDecisionReason: "blocked by fixture" };
  },
};
'@

            $result = Invoke-PluginLoader -RepoRoot $fixture.RepoRoot -Payload ([ordered]@{
                hook_event_name = 'PreToolUse'
                tool_name       = 'Bash'
                tool_input      = [ordered]@{ command = 'git status' }
            })

            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
            $result.Json.hookSpecificOutput.hookEventName | Should -Be 'PreToolUse'
            $result.Json.hookSpecificOutput.permissionDecision | Should -Be 'deny'
            $result.Json.hookSpecificOutput.permissionDecisionReason | Should -Match 'blocked by fixture'
            $result.Json.systemMessage | Should -Match 'deny-fixture'
        } finally {
            Remove-Item -LiteralPath $fixture.RepoRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'continues on advisory plugin failures and records the error' {
        $fixture = New-PluginLoaderFixture
        try {
            Write-TestFile -Path (Join-Path $fixture.PluginsDir 'advisory.js') -Content @'
"use strict";
module.exports = {
  name: "advisory-fixture",
  events: ["PostToolUse"],
  failClosed: false,
  run() {
    throw new Error("advisory failure");
  },
};
'@

            $result = Invoke-PluginLoader -RepoRoot $fixture.RepoRoot -Payload ([ordered]@{
                hook_event_name = 'PostToolUse'
                tool_name       = 'Read'
                tool_input      = [ordered]@{ file_path = 'README.md' }
            })

            $result.ExitCode | Should -Be 0
            $result.StdOut | Should -Be ''
            $result.StdErr | Should -Be ''

            $evidencePath = Join-Path $fixture.RepoRoot '.claude\logs\evidence-ledger.jsonl'
            $evidence = Get-Content -LiteralPath $evidencePath -Raw -Encoding UTF8
            $evidence | Should -Match 'advisory-fixture'
            $evidence | Should -Match 'advisory failure'
        } finally {
            Remove-Item -LiteralPath $fixture.RepoRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails closed when a mandatory plugin throws outside PreToolUse' {
        $fixture = New-PluginLoaderFixture
        try {
            Write-TestFile -Path (Join-Path $fixture.PluginsDir 'mandatory.js') -Content @'
"use strict";
module.exports = {
  name: "mandatory-fixture",
  events: ["PostToolUse"],
  run() {
    throw new Error("mandatory failure");
  },
};
'@

            $result = Invoke-PluginLoader -RepoRoot $fixture.RepoRoot -Payload ([ordered]@{
                hook_event_name = 'PostToolUse'
                tool_name       = 'Read'
                tool_input      = [ordered]@{ file_path = 'README.md' }
            })

            $result.ExitCode | Should -Be 2
            $result.StdOut | Should -Be ''
            $result.StdErr | Should -Match 'mandatory-fixture'
            $result.StdErr | Should -Match 'mandatory failure'
        } finally {
            Remove-Item -LiteralPath $fixture.RepoRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
