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
            $stdoutTrimmed = $stdout.Trim()
            $parsedOutput = $null
            if (-not [string]::IsNullOrWhiteSpace($stdoutTrimmed)) {
                try {
                    $parsedOutput = $stdoutTrimmed | ConvertFrom-Json -ErrorAction Stop
                } catch {
                }
            }
            if ($null -eq $parsedOutput -and -not [string]::IsNullOrWhiteSpace($stderrTrimmed)) {
                try {
                    $parsedOutput = $stderrTrimmed | ConvertFrom-Json -ErrorAction Stop
                } catch {
                }
            }

            return [PSCustomObject]@{
                ExitCode    = $exitCode
                StdOut      = $stdoutTrimmed
                StdErr      = $stderrTrimmed
                OutputObject = $parsedOutput
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

            $Result.ExitCode | Should -Be 0
            $Result.OutputObject | Should -Not -BeNullOrEmpty
            $Result.OutputObject.hookSpecificOutput.permissionDecision | Should -Be 'deny'
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

    It 'denies Worker writes outside the assigned worktree' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Write' -ToolInput @{
            file_path = 'C:\repo\README.md'
        } -Environment ([ordered]@{
            WINSMUX_ROLE              = 'Worker'
            WINSMUX_ASSIGNED_WORKTREE = 'C:\repo\.worktrees\worker-1'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'assigned worktree'
    }

    It 'denies Worker file mutations when assigned worktree is missing' {
        foreach ($case in @(
                @{
                    ToolName  = 'Write'
                    ToolInput = @{ file_path = 'C:\repo\src\demo.js' }
                },
                @{
                    ToolName  = 'Bash'
                    ToolInput = @{ command = 'Set-Content -LiteralPath C:\repo\README.md -Value demo' }
                }
            )) {
            $result = & $script:InvokeOrchestraGate -ToolName $case.ToolName -ToolInput $case.ToolInput -Environment ([ordered]@{
                WINSMUX_ROLE = 'Worker'
            })

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'assigned worktree is required'
        }
    }

    It 'denies Worker writes to sibling worktrees with a shared prefix' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Write' -ToolInput @{
            file_path = 'C:\repo\.worktrees\worker-10\README.md'
        } -Environment ([ordered]@{
            WINSMUX_ROLE              = 'Worker'
            WINSMUX_ASSIGNED_WORKTREE = 'C:\repo\.worktrees\worker-1'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'assigned worktree'
    }

    It 'denies Worker MultiEdit outside the assigned worktree' {
        $result = & $script:InvokeOrchestraGate -ToolName 'MultiEdit' -ToolInput @{
            file_path = 'C:\repo\README.md'
        } -Environment ([ordered]@{
            WINSMUX_ROLE              = 'Worker'
            WINSMUX_ASSIGNED_WORKTREE = 'C:\repo\.worktrees\worker-1'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'assigned worktree'
    }

    It 'allows Worker writes inside the assigned worktree' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Write' -ToolInput @{
            file_path = 'C:\repo\.worktrees\worker-1\README.md'
        } -Environment ([ordered]@{
            WINSMUX_ROLE              = 'Worker'
            WINSMUX_ASSIGNED_WORKTREE = 'C:\repo\.worktrees\worker-1'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows Worker MultiEdit on code inside the assigned worktree' {
        $result = & $script:InvokeOrchestraGate -ToolName 'MultiEdit' -ToolInput @{
            file_path = 'C:\repo\.worktrees\worker-1\src\demo.js'
        } -Environment ([ordered]@{
            WINSMUX_ROLE              = 'Worker'
            WINSMUX_ASSIGNED_WORKTREE = 'C:\repo\.worktrees\worker-1'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'denies Worker shell writes outside the assigned worktree' {
        foreach ($command in @(
                'cmd /c "echo demo > C:\repo\README.md"',
                'pwsh -Command "Set-Content -LiteralPath C:\repo\README.md -Value demo"',
                'pwsh -Command Set-Content -LiteralPath C:\repo\README.md -Value demo',
                'FOO=1 pwsh -Command "Set-Content -LiteralPath C:\repo\README.md -Value demo"',
                'env FOO=1 pwsh -Command "Set-Content -LiteralPath C:\repo\README.md -Value demo"',
                'cmd /d/c pwsh -Command "Set-Content -LiteralPath C:\repo\README.md -Value demo"',
                'pwsh -Command "iex ''Set-Content -LiteralPath C:\repo\README.md -Value demo''"',
                'pwsh -Command "Invoke-Expression ''Set-Content -LiteralPath C:\repo\README.md -Value demo''"',
                'pwsh -Command "[scriptblock]::Create(''Set-Content -LiteralPath C:\repo\README.md -Value demo'').Invoke()"',
                'pwsh -Command "$c=''Set-Content -LiteralPath C:\repo\README.md -Value demo''; [scriptblock]::Create($c).Invoke()"',
                'pwsh -Command "[scriptblock]::Create($env:X).Invoke()"',
                'pwsh -Command "Set-Content -LiteralPath:C:\repo\README.md -Value:demo"',
                'pwsh -Command "Set-Content -Lit:C:\repo\README.md -Value demo"',
                'pwsh -Command "Set-Content -PSPath:C:\repo\README.md -Value demo"',
                'pwsh -Command "&(''Set-Content'') -LiteralPath C:\repo\README.md -Value demo"',
                'pwsh -Command "Copy-Item -Path C:\repo\.worktrees\worker-1\README.md -Destination C:\repo\README.md"',
                'pwsh -Command "Move-Item -Path:C:\repo\README.md -Destination:C:\repo\.worktrees\worker-1\README.md"',
                'pwsh -Command "Invoke-WebRequest https://example.com -OutFile:C:\repo\out.txt"',
                'Start-Process cmd -ArgumentList "/c", "echo hi" -RedirectStandardOutput C:\repo\out.txt -Wait',
                'Start-Process -FilePath cmd -ArgumentList "/c", "echo hi" -RedirectStandardError C:\repo\err.txt -Wait',
                'Start-Process pwsh -ArgumentList ''-Command "Set-Content -LiteralPath C:\repo\README.md -Value demo"''',
                'Start-Process -FilePath pwsh -ArgumentList "-NoProfile", "-Command", "Set-Content -LiteralPath C:\repo\README.md -Value demo"',
                'Start-Process -FilePath pwsh -ArgumentList @(''-NoProfile'', ''-Command'', ''Set-Content -LiteralPath C:\repo\README.md -Value demo'')',
                'pwsh -Command "[System.IO.File]::WriteAllText(''C:\repo\README.md'', ''x'')"',
                'FOO=1 pwsh -Command "[IO.File]::WriteAllBytes(''C:\repo\README.md'', [byte[]]@(1))"',
                'env FOO=1 pwsh -Command "[System.IO.File]::Delete(''C:\repo\README.md'')"',
                'pwsh -Command "[System.IO.File]::Open(''C:\repo\README.md'', [System.IO.FileMode]::Create)"',
                'pwsh -Command "[System.IO.File]::Move(''C:\repo\README.md'', ''C:\repo\.worktrees\worker-1\README.md'')"',
                'pwsh -Command "[System.IO.FileInfo]::new(''C:\repo\README.md'').MoveTo(''C:\repo\.worktrees\worker-1\README.md'')"',
                'pwsh -Command "(New-Object System.IO.FileInfo ''C:\repo\README.md'').Delete()"',
                'pwsh -Command "([System.IO.FileInfo]''C:\repo\README.md'').Delete()"',
                'pwsh -Command "(New-Object -TypeName System.IO.FileInfo -ArgumentList ''C:\repo\README.md'').Delete()"',
                'pwsh -Command "(New-Object -TypeName:System.IO.FileInfo -ArgumentList:''C:\repo\README.md'').Delete()"',
                'pwsh -Command "(New-Object -TypeName System.IO.FileInfo -ArgumentList C:\repo\README.md).Delete()"',
                'pwsh -Command "(New-Object -Type System.IO.FileInfo -Arg ''C:\repo\README.md'').Delete()"',
                'pwsh -Command "(New-Object -TypeName ''System.IO.FileInfo'' -ArgumentList ''C:\repo\README.md'').Delete()"',
                'pwsh -Command "([System.IO.FileInfo]C:\repo\README.md).Delete()"',
                'pwsh -Command "New-Item -Name README.md -ItemType File"',
                'pwsh -Command "New-Item -Path C:\repo\.worktrees\worker-1 -Name ..\..\README.md -ItemType File"',
                'pwsh -Command "New-Item C:\repo\.worktrees\worker-1 -Name ..\..\README.md -ItemType File"',
                'pwsh -Command "New-Item -Name:README.md -ItemType:File"',
                'pwsh -Command "Set-Alias x Set-Content; x -LiteralPath C:\repo\README.md -Value demo"',
                'pwsh -Command "Set-Alias x Microsoft.PowerShell.Management\Set-Content; x -LiteralPath C:\repo\README.md -Value demo"',
                'pwsh -Command "New-Alias x Set-Content; x -LiteralPath C:\repo\README.md -Value demo"',
                'pwsh -Command "Set-Content -LiteralPath C:\repo\.worktrees\worker-1\$n -Value demo"',
                'pwsh -Command "Set-Content -LiteralPath C:\repo\.worktrees\worker-1\safe.txt,C:\repo\README.md -Value demo"',
                'pwsh -Command "1 | ForEach-Object { Set-Content -LiteralPath C:\repo\README.md -Value demo }"',
                'pwsh -Command "1 | ForEach-Object { sc -LiteralPath C:\repo\README.md -Value demo }"',
                'pwsh -Command "Set-Alias x Set-Content; 1 | ForEach-Object { x -LiteralPath C:\repo\README.md -Value demo }"',
                'pwsh -Command "mkdir C:\repo\outside"',
                'pwsh -Command "md C:\repo\outside"',
                'pwsh -EncodedCommand UwBlAHQALQBDAG8AbgB0AGUAbgB0AA==',
                'pwsh -Command "Export-Csv -Path C:\repo\out.csv -InputObject @{}"',
                'pwsh -Command "Export-Clixml -Path C:\repo\out.xml -InputObject @{}"',
                'pwsh -Command "Start-Transcript -Path C:\repo\transcript.txt"',
                'pwsh -Command "Invoke-WebRequest https://example.com -OutFile C:\repo\out.txt"',
                'curl.exe -o C:\repo\out.txt https://example.com',
                '"demo" | Set-Content -LiteralPath C:\repo\README.md',
                'echo demo>C:\repo\README.md',
                'echo demo>>C:\repo\README.md',
                'Write-Error demo 2> C:\repo\err.txt',
                'rm.exe C:\repo\README.md',
                'rm C:\repo\README.md',
                'del C:\repo\README.md',
                'Tee-Object -FilePath C:\repo\README.md',
                'Set-Content -LiteralPath \Users\me\out.txt -Value demo',
                'Set-Content -LiteralPath ~\out.txt -Value demo',
                'xcopy C:\repo\.worktrees\worker-1\safe.txt C:\repo\out.txt',
                'robocopy C:\repo\.worktrees\worker-1 C:\repo\outside safe.txt',
                'robocopy C:\repo C:\repo\.worktrees\worker-1 README.md /MOV',
                'robocopy C:\repo C:\repo\.worktrees\worker-1 README.md /MOVE',
                'node -e "require(''fs'').writeFileSync(''C:/repo/README.md'', ''x'')"',
                'node -e "const fs=require(''fs''); const fd=fs.openSync(''C:/repo/README.md'', ''w''); fs.writeSync(fd, ''x'')"',
                'node -e "require(''fs'').mkdtempSync(''C:/repo/out'')"',
                'node -e "require(''fs'').cpSync(''C:/repo/source'', ''C:/repo/dest'')"',
                'node -e "require(''fs'').truncateSync(''C:/repo/README.md'', 0)"',
                'node -e "require(''fs'').createWriteStream(''C:/repo/README.md'')"',
                'env node -e "require(''fs'').writeFileSync(''C:/repo/README.md'', ''x'')"',
                'bash -lc "command node -e ''require(''''fs'''').writeFileSync(''''C:/repo/README.md'''', ''''x'''')''"',
                'exec node -e "require(''fs'').writeFileSync(''C:/repo/README.md'', ''x'')"',
                'FOO=1 node -e "require(''fs'').writeFileSync(''C:/repo/README.md'', ''x'')"',
                'python -c "from pathlib import Path; Path(''C:/repo/README.md'').write_text(''x'')"',
                'sh -c"python -c ''from pathlib import Path; Path(''''C:/repo/README.md'''').write_text(''''x'''')''"',
                'python3.11 -c "from pathlib import Path; Path(''C:/repo/README.md'').write_text(''x'')"',
                'env python -c "from pathlib import Path; Path(''C:/repo/README.md'').write_text(''x'')"',
                'env -S "python -c ''from pathlib import Path; Path(''''C:/repo/README.md'''').write_text(''''x'''')''"',
                'env -C C:\repo python -c "from pathlib import Path; Path(''C:/repo/README.md'').write_text(''x'')"',
                'cmd /c p^ython -c "from pathlib import Path; Path(''C:/repo/README.md'').write_text(''x'')"',
                'env FOO=1 python3.11 -c "import os; os.remove(''C:/repo/README.md'')"',
                'FOO=1 python -c "from pathlib import Path; Path(''C:/repo/README.md'').write_text(''x'')"',
                'python -c "from pathlib import Path; Path(''C:/repo/README.md'').unlink()"',
                'python -c "from pathlib import Path; Path(''C:/repo/.worktrees/worker-1/README.md'').rename(''C:/repo/README.md'')"',
                'python -c "from pathlib import Path; Path(''C:/repo/.worktrees/worker-1/README.md'').rename(Path(''C:/repo/README.md''))"',
                'python -c "from pathlib import Path; target=''C:/repo/README.md''; Path(''C:/repo/.worktrees/worker-1/README.md'').rename(Path(target))"',
                'python -c "from pathlib import Path; target=''C:/repo/README.md''; Path(''C:/repo/.worktrees/worker-1/README.md'').rename(target)"',
                'python -c "import os; os.remove(''C:/repo/README.md'')"',
                'python -c "import os as o; o.remove(''C:/repo/README.md'')"',
                'python -c "from os import remove; remove(''C:/repo/README.md'')"',
                'python -c "import os; os.rename(''C:/repo/README.md'', ''C:/repo/.worktrees/worker-1/README.md'')"',
                'python -c "from pathlib import Path; import os; dest=''C:/repo/README.md''; Path(''C:/repo/.worktrees/worker-1/safe.txt'').write_text(''x''); os.rename(''C:/repo/.worktrees/worker-1/safe.txt'', dest)"',
                'python -c "from pathlib import Path; dest=''C:/repo/README.md''; Path(''C:/repo/.worktrees/worker-1/safe.txt'').write_text(''x''); Path(dest).write_text(''y'')"',
                'python -c "import os; os.makedirs(''C:/repo/out'')"',
                'python -c "import shutil; shutil.rmtree(''C:/repo/out'')"',
                'python -c "import shutil; shutil.move(''C:/repo/README.md'', ''C:/repo/.worktrees/worker-1/README.md'')"',
                'python -c "from shutil import copyfile; copyfile(''C:/repo/source.txt'', ''C:/repo/README.md'')"',
                'python -c "import shutil; shutil.copyfile(''C:/repo/source.txt'', ''C:/repo/README.md'')"',
                'node -e "require(''fs'').renameSync(''C:/repo/README.md'', ''C:/repo/.worktrees/worker-1/README.md'')"',
                'node -e "const fs=require(''fs''); const dest=''C:/repo/README.md''; fs.writeFileSync(''C:/repo/.worktrees/worker-1/safe.txt'', ''x''); fs.renameSync(''C:/repo/.worktrees/worker-1/safe.txt'', dest)"',
                'node -e "const fs=require(''fs''); const dest=''C:/repo/README.md''; fs.writeFileSync(''C:/repo/.worktrees/worker-1/safe.txt'', ''x''); fs.writeFileSync(dest, ''y'')"'
            )) {
            $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
                command = $command
            } -Environment ([ordered]@{
                WINSMUX_ROLE              = 'Worker'
                WINSMUX_ASSIGNED_WORKTREE = 'C:\repo\.worktrees\worker-1'
            })

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'shell writes must target assigned worktree|unresolved shell write target'
        }
    }

    It 'denies Worker shell writes with unresolved targets' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = '$p = ''C:\repo\README.md''; Set-Content -LiteralPath $p -Value demo'
        } -Environment ([ordered]@{
            WINSMUX_ROLE              = 'Worker'
            WINSMUX_ASSIGNED_WORKTREE = 'C:\repo\.worktrees\worker-1'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'unresolved shell write target'
    }

    It 'denies Worker PowerShell splatted write targets' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'pwsh -Command "function x { Set-Content @args }; x -LiteralPath C:\repo\README.md -Value demo"'
        } -Environment ([ordered]@{
            WINSMUX_ROLE              = 'Worker'
            WINSMUX_ASSIGNED_WORKTREE = 'C:\repo\.worktrees\worker-1'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'unresolved shell write target'
    }

    It 'denies Worker python writes when the write target cannot be parsed' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'python -c "from pathlib import Path; target = ''C:/repo/README.md''; Path(target).write_text(''x'')"'
        } -Environment ([ordered]@{
            WINSMUX_ROLE              = 'Worker'
            WINSMUX_ASSIGNED_WORKTREE = 'C:\repo\.worktrees\worker-1'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'unresolved shell write target'
    }

    It 'denies Worker write-capable interpreter heredocs' {
        foreach ($command in @(
                @'
python - <<'PY'
from pathlib import Path
Path('C:/repo/README.md').write_text('x')
PY
'@,
                @'
/usr/bin/node <<'JS'
require('fs').writeFileSync('C:/repo/README.md', 'x')
JS
'@,
                @'
env node <<'JS'
require('fs').writeFileSync('C:/repo/README.md', 'x')
JS
'@,
                @'
env FOO=1 node <<'JS'
require('fs').writeFileSync('C:/repo/README.md', 'x')
JS
'@,
                @'
cmd /c python <<'PY'
from pathlib import Path
Path('C:/repo/README.md').write_text('x')
PY
'@,
                @'
cat <<'PY' | python
from pathlib import Path
Path('C:/repo/README.md').write_text('x')
PY
'@,
                @'
cat <<'PS' | pwsh
Set-Content -LiteralPath C:\repo\README.md -Value demo
PS
'@,
                @'
FOO=1 node <<'JS'
require('fs').writeFileSync('C:/repo/README.md', 'x')
JS
'@,
                @'
python3.11 <<'PY'
from pathlib import Path
Path('C:/repo/README.md').write_text('x')
PY
'@
            )) {
            $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
                command = $command
            } -Environment ([ordered]@{
                WINSMUX_ROLE              = 'Worker'
                WINSMUX_ASSIGNED_WORKTREE = 'C:\repo\.worktrees\worker-1'
            })

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'interpreter heredocs'
        }
    }

    It 'denies Worker relative shell writes after changing directory' {
        foreach ($command in @(
                'cd C:\repo; "demo" > README.md',
                'env -C C:\repo python -c "from pathlib import Path; Path(''README.md'').write_text(''x'')"',
                'FOO=1 env -C C:\repo python -c "from pathlib import Path; Path(''README.md'').write_text(''x'')"'
            )) {
            $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
                command = $command
            } -Environment ([ordered]@{
                WINSMUX_ROLE              = 'Worker'
                WINSMUX_ASSIGNED_WORKTREE = 'C:\repo\.worktrees\worker-1'
            })

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'relative shell write targets'
        }
    }

    It 'allows Worker shell writes inside the assigned worktree' {
        foreach ($command in @(
                'cmd /c "echo demo > C:\repo\.worktrees\worker-1\README.md"',
                'pwsh -Command "Set-Content -LiteralPath C:\repo\.worktrees\worker-1\README.md -Value demo"',
                'pwsh -Command "Copy-Item -Path C:\repo\README.md -Destination C:\repo\.worktrees\worker-1\README.md"',
                'curl https://example.com',
                'pwsh -Command "Invoke-WebRequest https://example.com -OutFile C:\repo\.worktrees\worker-1\download.txt"',
                'node -e "require(''fs'').writeFileSync(''C:/repo/.worktrees/worker-1/README.md'', ''x'')"',
                'python -c "from pathlib import Path; Path(''C:/repo/.worktrees/worker-1/README.md'').write_text(''x'')"'
            )) {
            $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
                command = $command
            } -Environment ([ordered]@{
                WINSMUX_ROLE              = 'Worker'
                WINSMUX_ASSIGNED_WORKTREE = 'C:\repo\.worktrees\worker-1'
            })

            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
        }
    }

    It 'denies direct Write access to review-state.json' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Write' -ToolInput ([ordered]@{
            file_path = '.winsmux\review-state.json'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-state\.json'
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
        $result.OutputObject.systemMessage | Should -Match 'settings\.local\.json'
    }

    It 'denies direct codex exec usage' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'codex exec "review the repo"'
        }

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Be 'Use winsmux send to dispatch Codex to panes'
    }

    It 'denies direct codex sandbox usage' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'codex --sandbox danger-full-access -C C:\repo'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Be 'Use winsmux send to dispatch Codex to panes'
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
        $result.OutputObject.systemMessage | Should -Match 'review-state\.json'
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
            WINSMUX_ROLE = 'Operator'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-capable pane'
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
            WINSMUX_ROLE = 'Operator'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows pwsh -Command with rg review-approve as a read-only search' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'pwsh -Command "rg review-approve .claude/"'
        }) -Environment ([ordered]@{
            WINSMUX_ROLE = 'Operator'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'denies pwsh -Command writing a code file from the operator pane' {
        foreach ($command in @(
                'pwsh -Command "Set-Content -LiteralPath scripts/demo.ps1 -Value ''Write-Host hi''"',
                'pwsh -Command Set-Content -LiteralPath scripts/demo.ps1 -Value ''Write-Host hi'''
            )) {
            $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
                command = $command
            }) -Environment ([ordered]@{
                WINSMUX_ROLE = 'Operator'
            })

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'Operator shell write bypass blocked'
        }
    }

    It 'denies cmd /c writing a code file from the operator pane' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'cmd /c "echo Write-Host hi > scripts\\demo.ps1"'
        }) -Environment ([ordered]@{
            WINSMUX_ROLE = 'Operator'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'Operator shell write bypass blocked'
    }

    It 'denies python -c writing a code file from the operator pane' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'python -c "from pathlib import Path; Path(''scripts/demo.py'').write_text(''print(1)'', encoding=''utf-8'')"'
        }) -Environment ([ordered]@{
            WINSMUX_ROLE = 'Operator'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'Operator shell write bypass blocked'
    }

    It 'denies Agent acceptEdits mode' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode = 'acceptEdits'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'delegated execution bypass blocked'
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

    It 'denies non-startup Explore subagents once operator execution must stay in managed panes' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode          = 'acceptEdits'
            subagent_type = 'Explore'
            description   = 'Analyze PR #419 diff scope'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'dispatch-task'
    }

    It 'allows startup-diagnosis Explore subagents' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Agent' -ToolInput ([ordered]@{
            mode          = 'acceptEdits'
            subagent_type = 'Explore'
            description   = 'Investigate orchestra startup blocked manifest pane count'
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
            WINSMUX_ROLE = 'Operator'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'winsmux orchestra-smoke --json'
    }

    It 'denies legacy psmux-server process probes from the operator pane' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'pwsh -Command "Get-Process psmux-server -ErrorAction SilentlyContinue"'
        } -Environment ([ordered]@{
            WINSMUX_ROLE = 'Operator'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'winsmux list-sessions'
    }

    It 'allows winsmux orchestra-smoke from the operator pane' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'pwsh -NoProfile -File scripts/winsmux-core.ps1 orchestra-smoke --json'
        } -Environment ([ordered]@{
            WINSMUX_ROLE = 'Operator'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows winsmux orchestra-attach from the operator pane' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'pwsh -NoProfile -File scripts/winsmux-core.ps1 orchestra-attach --json'
        } -Environment ([ordered]@{
            WINSMUX_ROLE = 'Operator'
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

        foreach ($command in @(
                'git commit -m "feat: gated"',
                'bash -lc "git commit -m x"',
                'pwsh -Command "Set-Alias g git; g commit -m x"',
                'git -c alias.ci=commit ci -m "feat: gated"',
                'Set-Alias g git; g commit -m "feat: gated"',
                'Set-Alias -Name g -Value git; g commit -m "feat: gated"',
                'Set-Alias -Nam:g -Val:git; g commit -m "feat: gated"',
                'New-Alias g git; g commit -m "feat: gated"',
                'pwsh -Command "New-Alias g git; g commit -m x"',
                'pwsh -Command "function g { git }; g commit -m x"',
                'alias g=git; g commit -m x',
                'alias g="command git"; g commit -m x',
                'alias gc="git commit"; gc -m x',
                'g(){ git "$@"; }; g commit -m x'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
                command = $command
            }

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'review-request'
            $result.OutputObject.systemMessage | Should -Match 'review-approve'
        }
    }

    It 'denies git merge without Reviewer PASS for the current branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'git merge main',
                'git -c alias.m=merge m main',
                'git -c alias.m="!git m merge main" m'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
                command = $command
            }

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'review-approve'
            $result.OutputObject.systemMessage | Should -Match 'review-request'
        }
    }

    It 'denies GitHub pull request merge without Reviewer PASS for the current branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'gh pr merge 112 --squash --delete-branch',
                'bash -lc "gh pr merge 112 --squash"',
                'cmd /c g^h pr merge 112 --squash --delete-branch',
                'gh api repos/OWNER/REPO/pulls/123/merge -X PUT',
                'Set-Alias h gh; h pr merge 123 --squash',
                'Set-Alias -Name h -Value gh; h pr merge 123 --squash',
                'Set-Alias -Nam:h -Val:gh; h pr merge 123 --squash',
                'alias h="command gh"; h pr merge 123 --squash',
                'bash -lc "alias h=gh; h pr merge 123 --squash"',
                'alias h="gh api"; h repos/OWNER/REPO/pulls/123/merge -X PUT',
                'h(){ gh "$@"; }; h pr merge 123 --squash',
                'h(){ gh api "$@"; }; h repos/OWNER/REPO/pulls/123/merge -X PUT'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
                command = $command
            }

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'review-approve'
            $result.OutputObject.systemMessage | Should -Match 'review-request'
        }
    }

    It 'denies GitHub ref writes without Reviewer PASS for the current branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'gh api -X PATCH repos/OWNER/REPO/git/refs/heads/main -f sha=abc',
                'gh api -XPATCH repos/OWNER/REPO/git/refs/heads/main -f sha=abc',
                'gh api --method DELETE repos/OWNER/REPO/git/refs/heads/old',
                'gh api --method=PATCH repos/OWNER/REPO/git/ref/heads/main --field sha=abc',
                'gh api repos/OWNER/REPO/git/refs -f ref=refs/heads/topic -f sha=abc'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
                command = $command
            }

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'review-approve'
            $result.OutputObject.systemMessage | Should -Match 'review-request'
        }
    }

    It 'denies Worker git add even before the review gate' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'git add README.md'
        } -Environment ([ordered]@{
            WINSMUX_ROLE = 'Worker'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'Worker-pane Git lifecycle blocked'
    }

    It 'denies Worker git index mutation commands' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'git rm --cached README.md',
                'git restore --staged README.md',
                'git update-index --add README.md',
                'git checkout-index -f README.md',
                'git notes add -m note',
                'git -c alias.ci=commit ci -m x',
                'git config user.name Worker',
                'git diff --output=C:/repo/README.md',
                'env FOO=1 git config user.name Worker',
                'FOO=1 git diff --output=C:/repo/README.md',
                'pwsh -Com "git add README.md"',
                'pwsh -Com "git push origin feature/review-gate"',
                'pwsh -Command "if ($true) { git add README.md }"',
                'pwsh -Command "foreach ($x in 1) { git push origin feature/review-gate }"',
                'pwsh -Command "iex ''git add README.md''"',
                'pwsh -Command "Invoke-Expression ''git add README.md''"',
                'pwsh -Command "[scriptblock]::Create(''git add README.md'').Invoke()"',
                'pwsh -Command "$c=''git add README.md''; [scriptblock]::Create($c).Invoke()"',
                'bash -c"git add README.md"',
                'bash -lc "command git add README.md"',
                'bash -lc "exec git push origin feature/review-gate"',
                'Start-Process git -ArgumentList ''add README.md''',
                'Start-Process (Get-Command git) -ArgumentList ''add README.md''',
                'Start-Process $env:COMSPEC -ArgumentList ''/c git add README.md''',
                'pwsh -Command "Start-Process git -ArgumentList ''add README.md''"',
                'pwsh -Command "Start-Process -FilePath pwsh -ArgumentList ''-NoProfile'', ''-Command'', ''git add README.md''"',
                'Start-Process -FilePath pwsh -ArgumentList @(''-NoProfile'', ''-Command'', ''git add README.md'')',
                'command git add README.md',
                'builtin command git commit -m x',
                'env -S "git add README.md"',
                'Set-Alias g git; g add README.md',
                'Set-Alias -Name g -Value git; g add README.md',
                'Set-Alias -Nam:g -Val:git; g add README.md',
                'Set-Alias h gh; h pr merge 123 --squash',
                'alias g=git; g add README.md',
                'alias g="command git"; g add README.md',
                'alias g="env git"; g add README.md',
                'alias h="builtin gh"; h pr merge 123 --squash',
                'alias ga="git add"; ga README.md',
                'g(){ git "$@"; }; g add README.md',
                'g(){ git add README.md; }; g',
                'sh -c "git add README.md"',
                'bash -lc "git add README.md"',
                'git -c alias.m="!git m merge main" m',
                'cmd /c "echo x & git add README.md"',
                'cmd /c"echo x & git add README.md"',
                'cmd /c g^it add README.md',
                'cmd /d/c git add README.md',
                'cmd /d/c"git add README.md"',
                'python -c "import subprocess; subprocess.run([''git'', ''add'', ''README.md''])"',
                'python -c "import subprocess; tool=''git''; subprocess.run([tool, ''add'', ''README.md''])"',
                'python -c "import subprocess as sp; sp.run([chr(103)+chr(105)+chr(116), ''add'', ''README.md''])"',
                'node -e "require(''child_process'').execFileSync(''git'', [''add'', ''README.md''])"',
                'node -e "const {execFileSync}=require(''child_process''); execFileSync(''g''+''it'', [''add'', ''README.md''])"',
                'node -e "require(''child_process'').execSync(''git add README.md'')"',
                'gh api repos/OWNER/REPO/pulls/123/merge -X PUT',
                'gh api -X PATCH repos/OWNER/REPO/git/refs/heads/main -f sha=abc',
                'gh api -XPATCH repos/OWNER/REPO/git/refs/heads/main -f sha=abc',
                'gh api repos/OWNER/REPO/git/refs -f ref=refs/heads/topic -f sha=abc',
                'gh api repos/OWNER/REPO/git/ref/heads/main --method=PATCH --field sha=abc',
                'pwsh -Command "gh api --method PATCH repos/OWNER/REPO/git/refs/heads/main -f sha=abc"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
                command = $command
            } -Environment ([ordered]@{
                WINSMUX_ROLE = 'Worker'
            })

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'Worker-pane Git lifecycle blocked'
        }
    }

    It 'allows Worker read-only git status checks' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'git status --short'
        } -Environment ([ordered]@{
            WINSMUX_ROLE = 'Worker'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''

        foreach ($command in @(
                'command git status --short',
                'bash -c"git status --short"'
            )) {
            $wrappedResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
                command = $command
            } -Environment ([ordered]@{
                WINSMUX_ROLE = 'Worker'
            })

            $wrappedResult.ExitCode | Should -Be 0
            $wrappedResult.StdErr | Should -Be ''
        }
    }

    It 'allows Worker to search for git lifecycle examples' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'rg "git add" docs'
        } -Environment ([ordered]@{
            WINSMUX_ROLE = 'Worker'
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'denies Worker git push as an Operator-only lifecycle command' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'pwsh -Command "git push origin feature/review-gate"'
        } -Environment ([ordered]@{
            WINSMUX_ROLE = 'Worker'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'Worker-pane Git lifecycle blocked'
    }

    It 'denies Worker git lifecycle commands behind PowerShell call operators' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                '& git add README.md',
                '& { git push origin feature/review-gate }',
                'pwsh -Command "&(''git'') add README.md"',
                'pwsh -Command "& (Get-Command git) add README.md"',
                'pwsh -Command "& (''g''+''it'') add README.md"',
                'pwsh -Command "g`it add README.md"',
                'pwsh -Command "New-Alias g git; g add README.md"',
                'pwsh -Command "function g { git }; g add README.md"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
                command = $command
            } -Environment ([ordered]@{
                WINSMUX_ROLE = 'Worker'
            })

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'Worker-pane Git lifecycle blocked'
        }
    }

    It 'denies Worker git lifecycle commands behind PowerShell pipelines' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'Write-Output x | git add README.md'
        } -Environment ([ordered]@{
            WINSMUX_ROLE = 'Worker'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'Worker-pane Git lifecycle blocked'
    }

    It 'denies Worker git lifecycle commands behind unquoted PowerShell command arguments' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'pwsh -Command git push origin feature/review-gate'
        } -Environment ([ordered]@{
            WINSMUX_ROLE = 'Worker'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'Worker-pane Git lifecycle blocked'
    }

    It 'denies Worker git branch and tag mutations' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'git branch feature/new',
                'git branch -D old-topic',
                'git branch -m old-topic new-topic',
                'git branch --set-upstream-to origin/main',
                'git tag v0.0.1',
                'git tag -d v0.0.1'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
                command = $command
            } -Environment ([ordered]@{
                WINSMUX_ROLE = 'Worker'
            })

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'Worker-pane Git lifecycle blocked'
        }
    }

    It 'denies Worker git worktree mutation commands' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'git worktree add C:\repo\.worktrees\worker-2 main',
                'git worktree remove C:\repo\.worktrees\worker-2'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
                command = $command
            } -Environment ([ordered]@{
                WINSMUX_ROLE = 'Worker'
            })

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'Worker-pane Git lifecycle blocked'
        }
    }

    It 'allows Worker read-only git branch and tag queries' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'git branch --show-current',
                'git branch --list',
                'git branch -a',
                'git branch --all',
                'git branch -r',
                'git branch --remotes',
                'git branch --format "%(refname:short)"',
                'git tag --list',
                'git tag --format "%(refname:short)"',
                'git worktree list',
                'git remote -v',
                'git config --get user.name'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
                command = $command
            } -Environment ([ordered]@{
                WINSMUX_ROLE = 'Worker'
            })

            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
        }
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
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
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
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
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
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
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
        $reviewState.'feature/review-gate'.evidence.approved_at | Should -Not -BeNullOrEmpty
        $reviewState.'feature/review-gate'.evidence.approved_via | Should -Be 'winsmux review-approve'
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

    It 'records fail evidence when review-fail is used for the current branch' {
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

        $failResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-fail') -Environment $reviewerEnv
        $failResult.ExitCode | Should -Be 0

        $reviewStatePath = Join-Path $fixture.RepoRoot '.winsmux\review-state.json'
        $reviewState = Get-Content -LiteralPath $reviewStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $reviewState.'feature/review-gate'.status | Should -Be 'FAIL'
        $reviewState.'feature/review-gate'.evidence.failed_at | Should -Not -BeNullOrEmpty
        $reviewState.'feature/review-gate'.evidence.failed_via | Should -Be 'winsmux review-fail'
        $reviewState.'feature/review-gate'.evidence.review_contract_snapshot.required_scope | Should -Be @('design_impact', 'replacement_coverage', 'orphaned_artifacts')
    }
}
