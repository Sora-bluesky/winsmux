$ErrorActionPreference = 'Stop'

Describe 'sh-orchestra-gate integration' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:SourceHookPath = Join-Path $script:RepoRoot '.claude\hooks\sh-orchestra-gate.js'
        $script:WinsmuxCorePath = Join-Path $script:RepoRoot 'scripts\winsmux-core.ps1'
        $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $nodeCommand) {
            throw 'node was not found in PATH.'
        }

        $script:NodePath = if ($nodeCommand.Path) { $nodeCommand.Path } else { $nodeCommand.Name }
        $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $pwshCommand) {
            throw 'pwsh was not found in PATH.'
        }

        $script:PwshPath = if ($pwshCommand.Path) { $pwshCommand.Path } else { $pwshCommand.Name }

        $script:InvokeOrchestraGate = {
            param(
                [string]$RepoRoot = $script:RepoRoot,
                [Parameter(Mandatory = $true)][string]$ToolName,
                [Parameter(Mandatory = $true)][hashtable]$ToolInput
            )

            $hookPath = Join-Path $RepoRoot '.claude\hooks\sh-orchestra-gate.js'
            $payload = @{
                tool_name  = $ToolName
                tool_input = $ToolInput
            } | ConvertTo-Json -Compress -Depth 10

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
            $exitCode = $null
            try {
                $process.StandardInput.Write($payload)
                $process.StandardInput.Close()

                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                $exitCode = $process.ExitCode
            } finally {
                $process.Dispose()
            }

            $stderrTrimmed = $stderr.Trim()
            $parsedError = $null
            if (-not [string]::IsNullOrWhiteSpace($stderrTrimmed)) {
                try {
                    $parsedError = $stderrTrimmed | ConvertFrom-Json -ErrorAction Stop
                } catch {
                }
            }

            return [PSCustomObject]@{
                ExitCode    = $exitCode
                StdOut      = $stdout.Trim()
                StdErr      = $stderrTrimmed
                ErrorObject = $parsedError
            }
        }

        $script:InvokeWinsmuxCore = {
            param(
                [Parameter(Mandatory = $true)][string]$RepoRoot,
                [Parameter(Mandatory = $true)][string[]]$Arguments
            )

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:PwshPath
            $startInfo.ArgumentList.Add('-NoProfile')
            $startInfo.ArgumentList.Add('-File')
            $startInfo.ArgumentList.Add($script:WinsmuxCorePath)
            foreach ($argument in $Arguments) {
                $startInfo.ArgumentList.Add($argument)
            }

            $startInfo.WorkingDirectory = $RepoRoot
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true

            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()

                return [PSCustomObject]@{
                    ExitCode = $process.ExitCode
                    StdOut   = $stdout.Trim()
                    StdErr   = $stderr.Trim()
                }
            } finally {
                $process.Dispose()
            }
        }

        $script:AssertDenyResult = {
            param([Parameter(Mandatory = $true)]$Result)

            $Result.ExitCode | Should -Be 2
            $Result.StdErr | Should -Not -BeNullOrEmpty
            $Result.ErrorObject | Should -Not -BeNullOrEmpty
            $Result.ErrorObject.hookSpecificOutput.permissionDecision | Should -Be 'deny'
        }

        function New-GateFixture {
            $fixtureRoot = Join-Path $script:RepoRoot '.tmp-gate-enforcement-tests' ([guid]::NewGuid().ToString('N'))
            $repoRoot = Join-Path $fixtureRoot 'repo'

            New-Item -ItemType Directory -Path (Join-Path $repoRoot '.claude\hooks') -Force | Out-Null
            Set-Content -Path (Join-Path $repoRoot 'README.md') -Value 'fixture' -Encoding UTF8
            Copy-Item $script:SourceHookPath (Join-Path $repoRoot '.claude\hooks\sh-orchestra-gate.js')

            & git -C $repoRoot init | Out-Null
            & git -C $repoRoot add .
            & git -C $repoRoot -c user.name='Test User' -c user.email='test@example.com' commit -m 'init' | Out-Null
            & git -C $repoRoot checkout -b 'feature/review-gate' | Out-Null

            return [PSCustomObject]@{
                Root     = $fixtureRoot
                RepoRoot = $repoRoot
                Branch   = 'feature/review-gate'
            }
        }
    }

    AfterEach {
        if ($script:FixtureRoot -and (Test-Path $script:FixtureRoot)) {
            Remove-Item -Path $script:FixtureRoot -Recurse -Force
        }

        $script:FixtureRoot = $null
    }

    It 'denies Write on .ps1 files' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Write' -ToolInput @{
            file_path = 'scripts\demo.ps1'
        }

        & $script:AssertDenyResult -Result $result
    }

    It 'allows Write on .md files' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Write' -ToolInput @{
            file_path = 'docs\note.md'
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'denies direct winsmux send-keys usage' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'winsmux send-keys -t %1 Enter'
        }

        & $script:AssertDenyResult -Result $result
    }

    It 'denies direct codex exec usage' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'codex exec "review the repo"'
        }

        & $script:AssertDenyResult -Result $result
    }

    It 'allows codex exec text inside a heredoc body' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = @'
cat <<'EOF'
codex exec "review the repo"
EOF
'@
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'denies shallow git clone usage' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'git clone https://github.com/example/repo.git --depth 1'
        }

        & $script:AssertDenyResult -Result $result
    }

    It 'denies bare git rm usage' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'git rm secrets.txt'
        }

        & $script:AssertDenyResult -Result $result
    }

    It 'allows git rm --cached usage' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'git rm --cached secrets.txt'
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'denies Agent acceptEdits mode outside worktree isolation' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode = 'acceptEdits'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'write-capable Agent modes'
    }

    It 'denies Agent auto mode outside worktree isolation' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode = 'auto'
        })

        & $script:AssertDenyResult -Result $result
    }

    It 'denies Agent dontAsk mode outside worktree isolation' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode = 'dontAsk'
        })

        & $script:AssertDenyResult -Result $result
    }

    It 'denies Agent bypassPermissions mode outside worktree isolation' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode = 'bypassPermissions'
        })

        & $script:AssertDenyResult -Result $result
    }

    It 'allows Agent plan mode' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode = 'plan'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows Agent default mode' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode = 'default'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows Explore subagents even when mode is write-capable' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode          = 'acceptEdits'
            subagent_type = 'Explore'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows Agent write-capable modes when isolation is worktree' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode      = 'auto'
            isolation = 'worktree'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'Rule 7 removed verify command not yet implemented' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'gh pr merge 112 --squash --delete-branch'
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows a normal bash command' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'git status'
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'denies git commit without Reviewer PASS for the current branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'git commit -m "feat: gated"'
        }

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'review-approve'
    }

    It 'allows git commit after review-approve records PASS for the current branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $approveResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-approve')
        $approveResult.ExitCode | Should -Be 0

        $reviewStatePath = Join-Path $fixture.RepoRoot '.winsmux\review-state.json'
        Test-Path -LiteralPath $reviewStatePath | Should -Be $true
        $reviewState = Get-Content -LiteralPath $reviewStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $reviewState.'feature/review-gate'.status | Should -Be 'PASS'

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'git commit -m "feat: approved"'
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'denies git commit again after review-reset clears PASS for the current branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $approveResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-approve')
        $approveResult.ExitCode | Should -Be 0

        $resetResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-reset')
        $resetResult.ExitCode | Should -Be 0

        $reviewStatePath = Join-Path $fixture.RepoRoot '.winsmux\review-state.json'
        Test-Path -LiteralPath $reviewStatePath | Should -Be $false

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'git commit -m "feat: reset"'
        }

        & $script:AssertDenyResult -Result $result
    }
}
