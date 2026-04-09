$ErrorActionPreference = 'Stop'

Describe 'sh-pane-monitor integration' {
    BeforeAll {
        $script:FixtureBaseRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'winsmux-tests\pane-monitor'
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:SourceHookRoot = Join-Path $script:RepoRoot '.claude\hooks'
        $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $nodeCommand) {
            throw 'node was not found in PATH.'
        }

        $script:NodePath = if ($nodeCommand.Path) { $nodeCommand.Path } else { $nodeCommand.Name }

        function Invoke-PaneMonitorHook {
            param(
                [Parameter(Mandatory = $true)][string]$RepoRoot,
                [Parameter(Mandatory = $true)][hashtable]$Payload
            )

            $hookPath = Join-Path $RepoRoot '.claude\hooks\sh-pane-monitor.js'
            $json = $Payload | ConvertTo-Json -Compress -Depth 10

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:NodePath
            $startInfo.ArgumentList.Add($hookPath)
            $startInfo.WorkingDirectory = $RepoRoot
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true

            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $process.StandardInput.Write($json)
                $process.StandardInput.Close()

                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()

                $stderrTrimmed = $stderr.Trim()
                $parsedError = $null
                if (-not [string]::IsNullOrWhiteSpace($stderrTrimmed)) {
                    try {
                        $parsedError = $stderrTrimmed | ConvertFrom-Json -ErrorAction Stop
                    } catch {
                    }
                }

                return [ordered]@{
                    ExitCode    = $process.ExitCode
                    StdOut      = $stdout.Trim()
                    StdErr      = $stderrTrimmed
                    ErrorObject = $parsedError
                }
            } finally {
                $process.Dispose()
            }
        }

        function New-PaneMonitorFixture {
            $fixtureRoot = Join-Path $script:FixtureBaseRoot ([guid]::NewGuid().ToString('N'))
            $projectRoot = Join-Path $fixtureRoot 'project'
            $repoRoot = Join-Path $projectRoot '.worktrees\builder-1'
            $winsmuxDir = Join-Path $projectRoot '.winsmux'

            New-Item -ItemType Directory -Path (Join-Path $repoRoot '.claude\hooks\lib') -Force | Out-Null
            New-Item -ItemType Directory -Path $winsmuxDir -Force | Out-Null

            Copy-Item (Join-Path $script:SourceHookRoot 'sh-pane-monitor.js') (Join-Path $repoRoot '.claude\hooks\sh-pane-monitor.js')
            Copy-Item (Join-Path $script:SourceHookRoot 'lib\sh-utils.js') (Join-Path $repoRoot '.claude\hooks\lib\sh-utils.js')
            @"
version: 1
session:
  project_dir: '$projectRoot'
"@ | Set-Content -Path (Join-Path $winsmuxDir 'manifest.yaml') -Encoding UTF8

            return [ordered]@{
                Root       = $fixtureRoot
                ProjectRoot = $projectRoot
                RepoRoot   = $repoRoot
                WinsmuxDir = $winsmuxDir
                EventsPath = Join-Path $winsmuxDir 'events.jsonl'
            }
        }

        function New-PaneMonitorPayload {
            param(
                [Parameter(Mandatory = $true)][string]$ToolName,
                [Parameter(Mandatory = $true)][hashtable]$ToolInput,
                [string]$SessionId = 'session-1'
            )

            return [ordered]@{
                session_id = $SessionId
                tool_name  = $ToolName
                tool_input = $ToolInput
            }
        }
    }

    It 'is registered in tracked PostToolUse settings' {
        $settings = Get-Content -Path (Join-Path $script:RepoRoot '.claude\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $postToolUse = @($settings.hooks.PostToolUse | Where-Object { $_.matcher -eq '' })

        $postToolUse | Should -HaveCount 1
        @($postToolUse[0].hooks.command) | Should -Contain 'node .claude/hooks/sh-pane-monitor.js'
    }

    AfterEach {
        if ($script:FixtureRoot -and (Test-Path $script:FixtureRoot)) {
            Remove-Item -Path $script:FixtureRoot -Recurse -Force
        }
        $script:FixtureRoot = $null
    }

    It 'reads new pane events and emits alerts' {
        $fixture = New-PaneMonitorFixture
        $script:FixtureRoot = $fixture.Root

        Test-Path (Join-Path $fixture.RepoRoot '.winsmux') | Should -BeFalse

        @(
            ([ordered]@{ event = 'pane.completed'; label = 'builder-1'; pane_id = '%2' } | ConvertTo-Json -Compress),
            ([ordered]@{ event = 'pane.ready'; label = 'builder-2'; pane_id = '%3' } | ConvertTo-Json -Compress),
            ([ordered]@{ event = 'pane.crashed'; label = 'reviewer'; pane_id = '%4' } | ConvertTo-Json -Compress),
            ([ordered]@{ event = 'pane.approval_waiting'; label = 'approver'; pane_id = '%5' } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $fixture.EventsPath -Encoding UTF8

        $result = Invoke-PaneMonitorHook -RepoRoot $fixture.RepoRoot -Payload ([ordered]@{
            session_id = 'session-1'
            tool_name  = 'Read'
            tool_input = [ordered]@{ file_path = 'README.md' }
        })

        $result['ExitCode'] | Should -Be 0
        $result['ErrorObject'] | Should -Not -BeNullOrEmpty
        $context = [string]$result['ErrorObject'].hookSpecificOutput.additionalContext
        $context | Should -Match '\[PANE ALERT\] builder-1 completed'
        $context | Should -Match '\[PANE ALERT\] reviewer crashed'
        $context | Should -Match '\[PANE ALERT\] approver awaiting approval'

        $expectedCursor = (Get-Item -LiteralPath $fixture.EventsPath).Length
        $cursorPath = Join-Path $fixture.WinsmuxDir 'monitor-cursor-session-1.txt'
        (Get-Content -LiteralPath $cursorPath -Raw -Encoding UTF8).Trim() | Should -Be "$expectedCursor"
    }

    It 'is silent when there are no new events' {
        $fixture = New-PaneMonitorFixture
        $script:FixtureRoot = $fixture.Root

        ([ordered]@{ event = 'pane.completed'; label = 'builder-1'; pane_id = '%2' } | ConvertTo-Json -Compress) |
            Set-Content -Path $fixture.EventsPath -Encoding UTF8

        $first = Invoke-PaneMonitorHook -RepoRoot $fixture.RepoRoot -Payload (New-PaneMonitorPayload -ToolName 'Bash' -ToolInput ([ordered]@{ command = 'git status' }))
        $first['ExitCode'] | Should -Be 0

        $second = Invoke-PaneMonitorHook -RepoRoot $fixture.RepoRoot -Payload (New-PaneMonitorPayload -ToolName 'Bash' -ToolInput ([ordered]@{ command = 'git status' }))

        $second['ExitCode'] | Should -Be 0
        $second['StdErr'] | Should -Be ''
        $second['ErrorObject'] | Should -Be $null
    }

    It 'persists the cursor and only reports newly appended events' {
        $fixture = New-PaneMonitorFixture
        $script:FixtureRoot = $fixture.Root

        ([ordered]@{ event = 'pane.completed'; label = 'builder-1'; pane_id = '%2' } | ConvertTo-Json -Compress) |
            Set-Content -Path $fixture.EventsPath -Encoding UTF8

        $first = Invoke-PaneMonitorHook -RepoRoot $fixture.RepoRoot -Payload (New-PaneMonitorPayload -ToolName 'Read' -ToolInput ([ordered]@{ file_path = 'docs\handoff.md' }))
        $first['ExitCode'] | Should -Be 0
        ([string]$first['ErrorObject'].hookSpecificOutput.additionalContext) | Should -Match '\[PANE ALERT\] builder-1 completed'

        Add-Content -Path $fixture.EventsPath -Value ([ordered]@{ event = 'pane.crashed'; label = 'reviewer'; pane_id = '%4' } | ConvertTo-Json -Compress) -Encoding UTF8

        $second = Invoke-PaneMonitorHook -RepoRoot $fixture.RepoRoot -Payload (New-PaneMonitorPayload -ToolName 'Read' -ToolInput ([ordered]@{ file_path = 'docs\handoff.md' }))

        $second['ExitCode'] | Should -Be 0
        $context = [string]$second['ErrorObject'].hookSpecificOutput.additionalContext
        $context | Should -Match '\[PANE ALERT\] reviewer crashed'
        $context | Should -Not -Match '\[PANE ALERT\] builder-1 completed'

        $expectedCursor = (Get-Item -LiteralPath $fixture.EventsPath).Length
        $cursorPath = Join-Path $fixture.WinsmuxDir 'monitor-cursor-session-1.txt'
        (Get-Content -LiteralPath $cursorPath -Raw -Encoding UTF8).Trim() | Should -Be "$expectedCursor"
    }

    It 'keeps cursor state isolated per session' {
        $fixture = New-PaneMonitorFixture
        $script:FixtureRoot = $fixture.Root

        ([ordered]@{ event = 'pane.completed'; label = 'builder-1'; pane_id = '%2' } | ConvertTo-Json -Compress) |
            Set-Content -Path $fixture.EventsPath -Encoding UTF8

        $sessionOneFirst = Invoke-PaneMonitorHook -RepoRoot $fixture.RepoRoot -Payload (New-PaneMonitorPayload -ToolName 'Read' -ToolInput ([ordered]@{ file_path = 'docs\handoff.md' }) -SessionId 'session-1')
        $sessionTwoFirst = Invoke-PaneMonitorHook -RepoRoot $fixture.RepoRoot -Payload (New-PaneMonitorPayload -ToolName 'Read' -ToolInput ([ordered]@{ file_path = 'docs\handoff.md' }) -SessionId 'session-2')

        $sessionOneFirst['ExitCode'] | Should -Be 0
        $sessionTwoFirst['ExitCode'] | Should -Be 0
        ([string]$sessionOneFirst['ErrorObject'].hookSpecificOutput.additionalContext) | Should -Match '\[PANE ALERT\] builder-1 completed'
        ([string]$sessionTwoFirst['ErrorObject'].hookSpecificOutput.additionalContext) | Should -Match '\[PANE ALERT\] builder-1 completed'

        $sessionOneSecond = Invoke-PaneMonitorHook -RepoRoot $fixture.RepoRoot -Payload (New-PaneMonitorPayload -ToolName 'Read' -ToolInput ([ordered]@{ file_path = 'docs\handoff.md' }) -SessionId 'session-1')
        $sessionTwoSecond = Invoke-PaneMonitorHook -RepoRoot $fixture.RepoRoot -Payload (New-PaneMonitorPayload -ToolName 'Read' -ToolInput ([ordered]@{ file_path = 'docs\handoff.md' }) -SessionId 'session-2')

        $sessionOneSecond['ErrorObject'] | Should -Be $null
        $sessionTwoSecond['ErrorObject'] | Should -Be $null
        Test-Path (Join-Path $fixture.WinsmuxDir 'monitor-cursor-session-1.txt') | Should -BeTrue
        Test-Path (Join-Path $fixture.WinsmuxDir 'monitor-cursor-session-2.txt') | Should -BeTrue
    }
}
