$ErrorActionPreference = 'Stop'

Describe 'sh-orchestra-gate integration' {
    BeforeAll {
        $script:FixtureBaseRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'winsmux-tests\gate-enforcement'

        function Write-GateTestFile {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [AllowEmptyString()][string]$Content = ''
            )

            $parent = Split-Path -Parent $Path
            if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            $escapedPath = $Path -replace '"', '""'
            if ([string]::IsNullOrEmpty($Content)) {
                cmd /d /c ('type nul > "{0}"' -f $escapedPath) | Out-Null
            } else {
                $Content | cmd /d /c ('more > "{0}"' -f $escapedPath) | Out-Null
            }

            if ($LASTEXITCODE -ne 0) {
                throw "cmd.exe failed to write $Path"
            }
        }

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
                [Parameter(Mandatory = $true)][System.Collections.IDictionary]$ToolInput,
                [System.Collections.IDictionary]$Environment = @{},
                [bool]$DisableStartupGate = $true
            )

            $hookPath = Join-Path $RepoRoot '.claude\hooks\sh-orchestra-gate.js'
            $payload = [ordered]@{
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
            foreach ($entry in $Environment.GetEnumerator()) {
                $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
            }
            if ($DisableStartupGate) {
                $startInfo.Environment['WINSMUX_DISABLE_ORCHESTRA_STARTUP_GATE'] = '1'
            }

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
                [Parameter(Mandatory = $true)][string[]]$Arguments,
                [hashtable]$Environment = @{},
                [bool]$DisableStartupGate = $true
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
            foreach ($entry in $Environment.GetEnumerator()) {
                $startInfo.Environment[$entry.Key] = [string]$entry.Value
            }
            if ($DisableStartupGate) {
                $startInfo.Environment['WINSMUX_DISABLE_ORCHESTRA_STARTUP_GATE'] = '1'
            }

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
            $fixtureRoot = Join-Path $script:FixtureBaseRoot ([guid]::NewGuid().ToString('N'))
            $repoRoot = Join-Path $fixtureRoot 'repo'

            New-Item -ItemType Directory -Path (Join-Path $repoRoot '.claude\hooks') -Force | Out-Null
            Write-GateTestFile -Path (Join-Path $repoRoot 'README.md') -Content 'fixture'
            Copy-Item $script:SourceHookPath (Join-Path $repoRoot '.claude\hooks\sh-orchestra-gate.js')

            & git -C $repoRoot init | Out-Null
            & git -C $repoRoot add .
            & git -C $repoRoot -c user.name='Test User' -c user.email='test@example.com' commit -m 'init' | Out-Null
            & git -C $repoRoot checkout -b 'feature/review-gate' | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $repoRoot '.winsmux') -Force | Out-Null
            Write-GateTestFile -Path (Join-Path $repoRoot '.winsmux\manifest.yaml') -Content @"
session:
  name: 'winsmux-orchestra'
  project_dir: '$repoRoot'
panes:
  reviewer-1:
    pane_id: '%4'
    role: Reviewer
"@

            return [PSCustomObject]@{
                Root     = $fixtureRoot
                RepoRoot = $repoRoot
                Branch   = 'feature/review-gate'
            }
        }

        function Get-GateFixtureHeadSha {
            param([Parameter(Mandatory = $true)][string]$RepoRoot)

            $headSha = (& git -C $RepoRoot rev-parse HEAD | Select-Object -First 1)
            if (($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) -or [string]::IsNullOrWhiteSpace($headSha)) {
                throw "unable to resolve HEAD for $RepoRoot"
            }

            return $headSha.Trim()
        }

        function Set-GateReviewState {
            param(
                [Parameter(Mandatory = $true)][string]$RepoRoot,
                [Parameter(Mandatory = $true)][string]$Branch,
                [Parameter(Mandatory = $true)][System.Collections.Specialized.OrderedDictionary]$Entry
            )

            $reviewStatePath = Join-Path $RepoRoot '.winsmux\review-state.json'
            $reviewStateDir = Split-Path -Parent $reviewStatePath
            New-Item -ItemType Directory -Path $reviewStateDir -Force | Out-Null

            $state = [ordered]@{}
            $state[$Branch] = $Entry
            Write-GateTestFile -Path $reviewStatePath -Content ($state | ConvertTo-Json -Depth 10)

            return $reviewStatePath
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

    It 'denies direct Write access to review-state.json' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Write' -ToolInput ([ordered]@{
            file_path = '.winsmux\review-state.json'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'review-state\.json'
    }

    It 'denies direct winsmux send-keys usage' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'winsmux send-keys -t %1 Enter'
        }

        & $script:AssertDenyResult -Result $result
    }

    It 'denies python writing hooks changes to settings.local.json' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'python -c "from pathlib import Path; Path(''.claude/settings.local.json'').write_text(''{\"hooks\":{}}'', encoding=''utf-8'')"'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'settings\.local\.json'
    }

    It 'denies direct codex exec usage' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'codex exec "review the repo"'
        }

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Be 'Use winsmux send to dispatch Codex to panes'
    }

    It 'denies direct codex sandbox usage' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'codex --sandbox danger-full-access -C C:\repo'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Be 'Use winsmux send to dispatch Codex to panes'
    }

    It 'allows winsmux send codex exec usage' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'winsmux send --pane builder-1 --text ''codex exec "review the repo"'''
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
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

    It 'denies direct Bash writes to review-state.json' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'Set-Content -LiteralPath .winsmux\review-state.json -Value "{}"'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'review-state\.json'
    }

    It 'allows Bash reads from review-state.json' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'Get-Content -LiteralPath .winsmux\review-state.json'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'denies review-approve unless WINSMUX_ROLE is review-capable' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'pwsh scripts/winsmux-core.ps1 review-approve'
        }) -Environment ([ordered]@{
            WINSMUX_ROLE = 'Commander'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'review-capable pane'
    }

    It 'allows review-approve when WINSMUX_ROLE is Reviewer' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'pwsh scripts/winsmux-core.ps1 review-approve'
        }) -Environment ([ordered]@{
            WINSMUX_ROLE = 'Reviewer'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows review-approve when WINSMUX_ROLE is Worker' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'pwsh scripts/winsmux-core.ps1 review-approve'
        }) -Environment ([ordered]@{
            WINSMUX_ROLE = 'Worker'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows rg review-approve as a read-only search' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'rg review-approve docs/'
        }) -Environment ([ordered]@{
            WINSMUX_ROLE = 'Commander'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows pwsh -Command with rg review-approve as a read-only search' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'pwsh -Command "rg review-approve .claude/"'
        }) -Environment ([ordered]@{
            WINSMUX_ROLE = 'Commander'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'denies pwsh -Command writing a code file from the operator pane' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'pwsh -Command "Set-Content -LiteralPath scripts/demo.ps1 -Value ''Write-Host hi''"'
        }) -Environment ([ordered]@{
            WINSMUX_ROLE = 'Commander'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'Operator shell write bypass blocked'
    }

    It 'denies cmd /c writing a code file from the operator pane' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'cmd /c "echo Write-Host hi > scripts\\demo.ps1"'
        }) -Environment ([ordered]@{
            WINSMUX_ROLE = 'Commander'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'Operator shell write bypass blocked'
    }

    It 'denies python -c writing a code file from the operator pane' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'python -c "from pathlib import Path; Path(''scripts/demo.py'').write_text(''print(1)'', encoding=''utf-8'')"'
        }) -Environment ([ordered]@{
            WINSMUX_ROLE = 'Commander'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'Operator shell write bypass blocked'
    }

    It 'denies Agent acceptEdits mode' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode = 'acceptEdits'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'delegated write bypass blocked'
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

    It 'denies Agent default mode' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode = 'default'
        })

        & $script:AssertDenyResult -Result $result
    }

    It 'allows Explore subagents even when mode is write-capable' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode          = 'acceptEdits'
            subagent_type = 'Explore'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'denies Agent write-capable modes even with worktree isolation' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode      = 'auto'
            isolation = 'worktree'
        })

        & $script:AssertDenyResult -Result $result
    }

    It 'allows a normal bash command' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'git status'
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows gh issue close without triggering the review gate' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'gh issue close 123'
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows gh pr close without triggering the review gate' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'gh pr close 123'
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'denies legacy psmux version probes from the operator pane' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'psmux --version'
        } -Environment ([ordered]@{
            WINSMUX_ROLE = 'Commander'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'winsmux orchestra-smoke --json'
    }

    It 'denies legacy psmux-server process probes from the operator pane' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'pwsh -Command "Get-Process psmux-server -ErrorAction SilentlyContinue"'
        } -Environment ([ordered]@{
            WINSMUX_ROLE = 'Commander'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'winsmux list-sessions'
    }

    It 'allows winsmux orchestra-smoke from the operator pane' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'pwsh -NoProfile -File scripts/winsmux-core.ps1 orchestra-smoke --json'
        } -Environment ([ordered]@{
            WINSMUX_ROLE = 'Commander'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'wires the startup gate disable environment flag into the orchestra readiness gate' {
        $hookContent = Get-Content -LiteralPath $script:SourceHookPath -Raw -Encoding UTF8

        $hookContent | Should -Match '!STARTUP_GATE_DISABLED'
        $hookContent | Should -Match 'WINSMUX_DISABLE_ORCHESTRA_STARTUP_GATE'
    }

    It 'denies git commit without Reviewer PASS for the current branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'git commit -m "feat: gated"'
        }

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'review-request'
        $result.ErrorObject.systemMessage | Should -Match 'review-approve'
    }

    It 'denies git merge without Reviewer PASS for the current branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'git merge main'
        }

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'review-approve'
        $result.ErrorObject.systemMessage | Should -Match 'review-request'
    }

    It 'denies gh pr merge without Reviewer PASS for the current branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'gh pr merge 112 --squash --delete-branch'
        }

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'review-approve'
        $result.ErrorObject.systemMessage | Should -Match 'review-request'
    }

    It 'denies git commit when PASS head_sha does not match current HEAD' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $currentHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = ('0' * $currentHeadSha.Length)
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = ('0' * $currentHeadSha.Length)
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'git commit -m "feat: stale-review"'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'review-approve'
        $result.ErrorObject.systemMessage | Should -Match 'review-request'
    }

    It 'denies git commit when reviewer role is not review-capable' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $currentHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $currentHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $currentHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Builder'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'git commit -m "feat: wrong-reviewer-role"'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'review-approve'
    }

    It 'denies git commit when reviewer pane_id is empty' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $currentHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $currentHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $currentHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = ''
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'git commit -m "feat: missing-pane-id"'
        })

        & $script:AssertDenyResult -Result $result
        $result.ErrorObject.systemMessage | Should -Match 'review-approve'
    }

    It 'allows git commit after review-approve records PASS for the current branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $reviewerEnv = @{
            WINSMUX_ROLE      = 'Reviewer'
            WINSMUX_PANE_ID   = '%4'
            WINSMUX_ROLE_MAP  = '{"%4":"Reviewer"}'
            WINSMUX_AGENT_NAME = 'codex'
        }

        $requestResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-request') -Environment $reviewerEnv
        $requestResult.ExitCode | Should -Be 0

        $approveResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-approve') -Environment $reviewerEnv
        $approveResult.ExitCode | Should -Be 0

        $reviewStatePath = Join-Path $fixture.RepoRoot '.winsmux\review-state.json'
        Test-Path -LiteralPath $reviewStatePath | Should -Be $true
        $reviewState = Get-Content -LiteralPath $reviewStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $reviewState.'feature/review-gate'.status | Should -Be 'PASS'
        $reviewState.'feature/review-gate'.reviewer.role | Should -Be 'Reviewer'
        $reviewState.'feature/review-gate'.reviewer.pane_id | Should -Be '%4'
        $reviewState.'feature/review-gate'.request.head_sha | Should -Not -BeNullOrEmpty
        $reviewState.'feature/review-gate'.request.target_reviewer_pane_id | Should -Be '%4'
        $reviewState.'feature/review-gate'.request.review_contract.source_task | Should -Be 'TASK-210'
        $reviewState.'feature/review-gate'.request.review_contract.style | Should -Be 'utility_first'
        $reviewState.'feature/review-gate'.request.review_contract.required_scope | Should -Be @('design_impact', 'replacement_coverage', 'orphaned_artifacts')
        $reviewState.'feature/review-gate'.evidence.review_contract_snapshot.required_scope | Should -Be @('design_impact', 'replacement_coverage', 'orphaned_artifacts')

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'git commit -m "feat: approved"'
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows git merge after review-approve records PASS for the current branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $reviewerEnv = @{
            WINSMUX_ROLE       = 'Reviewer'
            WINSMUX_PANE_ID    = '%4'
            WINSMUX_ROLE_MAP   = '{"%4":"Reviewer"}'
            WINSMUX_AGENT_NAME = 'codex'
        }

        $requestResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-request') -Environment $reviewerEnv
        $requestResult.ExitCode | Should -Be 0

        $approveResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-approve') -Environment $reviewerEnv
        $approveResult.ExitCode | Should -Be 0

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'git merge main'
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows gh pr merge after review-approve records PASS for the current branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $reviewerEnv = @{
            WINSMUX_ROLE       = 'Reviewer'
            WINSMUX_PANE_ID    = '%4'
            WINSMUX_ROLE_MAP   = '{"%4":"Reviewer"}'
            WINSMUX_AGENT_NAME = 'codex'
        }

        $requestResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-request') -Environment $reviewerEnv
        $requestResult.ExitCode | Should -Be 0

        $approveResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-approve') -Environment $reviewerEnv
        $approveResult.ExitCode | Should -Be 0

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'gh pr merge 112 --squash --delete-branch'
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'denies git commit again after review-reset clears PASS for the current branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $reviewerEnv = @{
            WINSMUX_ROLE      = 'Reviewer'
            WINSMUX_PANE_ID   = '%4'
            WINSMUX_ROLE_MAP  = '{"%4":"Reviewer"}'
            WINSMUX_AGENT_NAME = 'codex'
        }

        $requestResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-request') -Environment $reviewerEnv
        $requestResult.ExitCode | Should -Be 0

        $approveResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-approve') -Environment $reviewerEnv
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

    It 'requires a pending review request before review-approve succeeds' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $reviewerEnv = @{
            WINSMUX_ROLE      = 'Reviewer'
            WINSMUX_PANE_ID   = '%4'
            WINSMUX_ROLE_MAP  = '{"%4":"Reviewer"}'
            WINSMUX_AGENT_NAME = 'codex'
        }

        $approveResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-approve') -Environment $reviewerEnv
        $approveResult.ExitCode | Should -Be 1
        $approveResult.StdErr | Should -Match 'review-request'
    }

    It 'rejects review-approve when the pending request is missing review_contract' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $reviewStatePath = Join-Path $fixture.RepoRoot '.winsmux\review-state.json'
        @'
{
  "feature/review-gate": {
    "status": "PENDING",
    "branch": "feature/review-gate",
    "head_sha": "1111111111111111111111111111111111111111",
    "request": {
      "branch": "feature/review-gate",
      "head_sha": "1111111111111111111111111111111111111111",
      "target_reviewer_pane_id": "%4",
      "target_reviewer_label": "reviewer-1",
      "target_reviewer_role": "Reviewer"
    }
  }
}
'@ | Set-Content -LiteralPath $reviewStatePath -Encoding UTF8

        $reviewerEnv = @{
            WINSMUX_ROLE      = 'Reviewer'
            WINSMUX_PANE_ID   = '%4'
            WINSMUX_ROLE_MAP  = '{"%4":"Reviewer"}'
            WINSMUX_AGENT_NAME = 'codex'
        }

        $approveResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-approve') -Environment $reviewerEnv
        $approveResult.ExitCode | Should -Be 1
        $approveResult.StdErr | Should -Match 'missing review_contract'
    }
}
