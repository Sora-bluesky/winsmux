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
            $fixtureBin = Join-Path $RepoRoot '.winsmux-test-bin'
            if (Test-Path -LiteralPath $fixtureBin -PathType Container) {
                $startInfo.Environment['PATH'] = $fixtureBin + [System.IO.Path]::PathSeparator + $startInfo.Environment['PATH']
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
            param(
                [Parameter(Mandatory = $true)]$Result,
                [string]$Because = 'the command crosses a protected execution boundary'
            )

            $Result.ExitCode | Should -Be 0 -Because $Because
            $Result.OutputObject | Should -Not -BeNullOrEmpty -Because $Because
            $Result.OutputObject.hookSpecificOutput.permissionDecision | Should -Be 'deny' -Because $Because
        }

        function New-GateFixture {
            $fixtureRoot = Join-Path $script:FixtureBaseRoot ([guid]::NewGuid().ToString('N'))
            $repoRoot = Join-Path $fixtureRoot 'repo'

            New-Item -ItemType Directory -Path (Join-Path $repoRoot '.claude\hooks') -Force | Out-Null
            Write-GateTestFile -Path (Join-Path $repoRoot 'README.md') -Content 'fixture'
            Copy-Item $script:SourceHookPath (Join-Path $repoRoot '.claude\hooks\sh-orchestra-gate.js')
            Copy-Item (Join-Path $script:RepoRoot '.claude\hooks\vendor') (Join-Path $repoRoot '.claude\hooks\vendor') -Recurse

            & git -C $repoRoot init | Out-Null
            & git -C $repoRoot add .
            & git -C $repoRoot -c user.name='Test User' -c user.email='test@example.com' commit -m 'init' | Out-Null
            & git -C $repoRoot checkout -b 'feature/review-gate' | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $repoRoot '.winsmux') -Force | Out-Null
            $fixtureBin = Join-Path $repoRoot '.winsmux-test-bin'
            New-Item -ItemType Directory -Path $fixtureBin -Force | Out-Null
            Write-GateTestFile -Path (Join-Path $fixtureBin 'winsmux.cmd') -Content @'
@echo off
pwsh -NoProfile -Command "$t=[char]9; [Console]::WriteLine(([char]36).ToString()+'1'+$t+'winsmux-gate'+$t+([char]37).ToString()+'1'+$t+'Bootstrap'); [Console]::WriteLine(([char]36).ToString()+'1'+$t+'winsmux-gate'+$t+([char]37).ToString()+'4'+$t+'Reviewer Pane')"
'@

            $generationId = 'gate-generation'
            $serverSessionId = '$1'
            $bootstrapPid = $PID
            $bootstrapProcess = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $bootstrapPid) -ErrorAction Stop
            $bootstrapStartedAt = ([datetime]$bootstrapProcess.CreationDate).ToUniversalTime().ToString('o')
            $markerPath = Join-Path $repoRoot '.winsmux\reviewer-bootstrap.json'
            $marker = [ordered]@{
                state = 'ready'; generation_id = $generationId; server_session_id = $serverSessionId
                slot_id = 'reviewer-1'; pane_id = '%4'; backend = 'local'; role = 'reviewer'; title = 'Reviewer Pane'
                bootstrap_pid = $bootstrapPid; bootstrap_process_started_at = $bootstrapStartedAt
            }
            Write-GateTestFile -Path $markerPath -Content ($marker | ConvertTo-Json -Depth 8)

            $approvedLaunch = ([ordered]@{ agent = 'local-reviewer'; worker_backend = 'local'; worker_role = 'reviewer' } | ConvertTo-Json -Compress)
            Write-GateTestFile -Path (Join-Path $repoRoot '.winsmux\manifest.yaml') -Content @"
version: 2
session:
  name: 'winsmux-gate'
  project_dir: '$repoRoot'
  generation_id: '$generationId'
  server_session_id: '$serverSessionId'
  bootstrap_pane_id: '%1'
  expected_pane_count: 1
  session_ready: 'true'
panes:
  reviewer-1:
    slot_id: 'reviewer-1'
    pane_id: '%4'
    worker_backend: 'local'
    worker_role: 'reviewer'
    role: 'Reviewer'
    title: 'Reviewer Pane'
    status: 'ready'
    runtime_ready: 'true'
    bootstrap_marker_path: '$markerPath'
    approved_launch: '$approvedLaunch'
tasks:
  queued: []
  in_progress: []
  completed: []
worktrees: {}
"@

            $now = (Get-Date).ToUniversalTime()
            $registry = [ordered]@{
                schema_version = 1; status = 'active'; session_name = 'winsmux-gate'; server_session_id = $serverSessionId
                bootstrap_pane_id = '%1'; generation_id = $generationId; expected_pane_count = 1
                supervisor = [ordered]@{ pid = $bootstrapPid; process_started_at = $bootstrapStartedAt }
                lease = [ordered]@{ state = 'active'; expires_at = $now.AddMinutes(5).ToString('o') }
                panes = @([ordered]@{
                    label = 'reviewer-1'; slot_id = 'reviewer-1'; pane_id = '%4'; backend = 'local'; role = 'reviewer'
                    title = 'Reviewer Pane'; state = 'live'; bootstrap_pid = $bootstrapPid
                    bootstrap_process_started_at = $bootstrapStartedAt; marker_path = $markerPath
                })
                updated_at = $now.ToString('o')
            }
            Write-GateTestFile -Path (Join-Path $repoRoot '.winsmux\runtime-registry.json') -Content ($registry | ConvertTo-Json -Depth 12)

            return [PSCustomObject]@{
                Root     = $fixtureRoot
                RepoRoot = $repoRoot
                Branch   = 'feature/review-gate'
            }
        }

        function New-GateTargetRepo {
            param(
                [Parameter(Mandatory = $true)][string]$Root,
                [string]$Branch = 'feature/review-gate-target',
                [string]$Name = ''
            )

            $repoRoot = if ([string]::IsNullOrEmpty($Name)) {
                Join-Path $Root ([guid]::NewGuid().ToString('N'))
            } else {
                Join-Path $Root $Name
            }
            New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
            Write-GateTestFile -Path (Join-Path $repoRoot 'README.md') -Content 'target fixture'

            & git -C $repoRoot init | Out-Null
            & git -C $repoRoot add .
            & git -C $repoRoot -c user.name='Test User' -c user.email='test@example.com' commit -m 'init' | Out-Null
            & git -C $repoRoot checkout -b $Branch | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $repoRoot '.winsmux') -Force | Out-Null

            return [PSCustomObject]@{
                RepoRoot = $repoRoot
                Branch   = $Branch
            }
        }

        function New-GateLinkedWorktree {
            param(
                [Parameter(Mandatory = $true)][string]$SourceRepoRoot,
                [Parameter(Mandatory = $true)][string]$Root,
                [string]$Branch = 'feature/review-gate-linked'
            )

            $null = $SourceRepoRoot
            $target = New-GateTargetRepo -Root $Root -Branch $Branch
            $dotGitPath = Join-Path $target.RepoRoot '.git'
            $actualGitDir = Join-Path $Root ([guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $dotGitPath -Destination $actualGitDir
            Write-GateTestFile -Path $dotGitPath -Content ('gitdir: {0}' -f $actualGitDir)
            & git --git-dir $actualGitDir config core.worktree $target.RepoRoot
            if ($LASTEXITCODE -ne 0) {
                throw "unable to configure pointer gitdir $actualGitDir"
            }

            return $target
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

        function Set-GatePass {
            param(
                [Parameter(Mandatory = $true)][string]$RepoRoot,
                [Parameter(Mandatory = $true)][string]$Branch
            )

            $headSha = Get-GateFixtureHeadSha -RepoRoot $RepoRoot
            Set-GateReviewState -RepoRoot $RepoRoot -Branch $Branch -Entry ([ordered]@{
                status   = 'PASS'
                head_sha = $headSha
                request  = [ordered]@{
                    branch                  = $Branch
                    head_sha                = $headSha
                    target_reviewer_pane_id = '%4'
                }
                reviewer = [ordered]@{
                    role    = 'Reviewer'
                    pane_id = '%4'
                }
                updatedAt = '2026-07-16T19:30:00.0000000+09:00'
            }) | Out-Null
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
                'pwsh -Command "if ($true) { Set-Content -LiteralPath C:\repo\README.md -Value demo; if ($false) {} }"',
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
                'pwsh -Command "& (''Set''+''-Content'') -LiteralPath C:\repo\README.md -Value demo"',
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
                'bash -c "touch C:/repo/outside.py"',
                'bash -lc "printf ''C:/repo/README.md\n'' | xargs touch"',
                'printf ''C:/repo/README.md\n'' | xargs touch',
                'printf ''C:/repo/README.md\n'' | xargs env touch',
                'printf ''C:/repo/README.md\n'' | xargs -I{} sh -c ''touch {}''',
                'cp -t C:\repo\outside C:\repo\.worktrees\worker-1\src.txt',
                'sed -i s/a/b/ C:/repo/README.md',
                'install C:/repo/.worktrees/worker-1/source.txt C:/repo/README.md',
                'Start-Process pwsh -ArgumentList ''-Command'',''Set-Content C:\repo\README.md x''',
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
                'python -c "from os import remove; target=''C:/repo/README.md''; remove(target)"',
                'python -c "from os import remove as r; r(''C:/repo/README.md'')"',
                'python -c "from os import rename as rn; rn(''C:/repo/.worktrees/worker-1/a.txt'', ''C:/repo/README.md'')"',
                'python -c "from os import remove as r; target=''C:/repo/README.md''; r(target)"',
                'python -c "import os; f=os.remove; f(''C:/repo/README.md'')"',
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
                'bash -c "cd ..; touch README.md"',
                'command cd .. && touch outside.txt',
                'builtin cd .. && touch outside.txt',
                'pwsh -Command "pushd ..; Set-Content -LiteralPath README.md -Value demo"',
                'Start-Process -WorkingDirectory .. -FilePath pwsh -ArgumentList "-Command", "Set-Content -LiteralPath README.md -Value demo"',
                'env -C C:\repo python -c "from pathlib import Path; Path(''README.md'').write_text(''x'')"',
                'FOO=1 env -C C:\repo python -c "from pathlib import Path; Path(''README.md'').write_text(''x'')"',
                'python -c "import os; os.chdir(''C:/repo''); open(''README.md'', ''w'').write(''x'')"',
                'python -c "from os import chdir; chdir(''C:/repo''); open(''README.md'', ''w'').write(''x'')"',
                'node -e "process.chdir(''C:/repo''); require(''fs'').writeFileSync(''README.md'', ''x'')"'
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

    It 'allows Worker env-wrapped relative shell writes without chdir' {
        $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
            command = 'env python -c "from pathlib import Path; Path(''README.md'').write_text(''x'')"'
        } -Environment ([ordered]@{
            WINSMUX_ROLE              = 'Worker'
            WINSMUX_ASSIGNED_WORKTREE = (Get-Location).Path
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'allows Worker read-only interpreter commands' {
        foreach ($command in @(
                'python -c "open(''README.md'').read()"',
                'python -c "import sys; sys.stdout.write(''ok'')"',
                'node -e "process.stdout.write(''ok'')"'
            )) {
            $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{
                command = $command
            } -Environment ([ordered]@{
                WINSMUX_ROLE              = 'Worker'
                WINSMUX_ASSIGNED_WORKTREE = (Get-Location).Path
            })

            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
        }
    }

    It 'allows Worker shell writes inside the assigned worktree' {
        foreach ($command in @(
                'cmd /c "echo demo > C:\repo\.worktrees\worker-1\README.md"',
                'pwsh -Command "Set-Content -LiteralPath C:\repo\.worktrees\worker-1\README.md -Value demo"',
                'pwsh -Command "Copy-Item -Path C:\repo\README.md -Destination C:\repo\.worktrees\worker-1\README.md"',
                'bash -c "touch C:/repo/.worktrees/worker-1/outside.py"',
                'cp -t C:\repo\.worktrees\worker-1 C:\repo\source.txt',
                'curl https://example.com',
                'pwsh -Command "Invoke-WebRequest https://example.com -OutFile C:\repo\.worktrees\worker-1\download.txt"',
                'node -e "require(''fs'').writeFileSync(''C:/repo/.worktrees/worker-1/README.md'', ''x'')"',
                'python -c "from pathlib import Path; Path(''C:/repo/.worktrees/worker-1/README.md'').write_text(''x'')"',
                'python -c "from os import remove as r; r(''C:/repo/.worktrees/worker-1/README.md'')"'
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
                'Start-Process git -ArgumentList commit -Wait',
                'Start-Process git commit -m x',
                'printf ''commit -m x\n'' | xargs git',
                'printf ''commit -m x\n'' | xargs env git',
                'printf ''commit -m x\n'' | xargs -I{} sh -c ''git {}''',
                'Start-Process (Get-Command git) -ArgumentList commit -Wait',
                'Start-Process (''g''+''it'') -ArgumentList commit -Wait',
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
                'g(){ git "$@"; }; g commit -m x',
                'g(){ "$@"; }; g git commit -m x'
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
                'Start-Process gh -ArgumentList ''pr'', ''merge'', ''123'' -Wait',
                'Start-Process gh pr merge 123',
                'printf ''pr merge 123\n'' | xargs gh',
                'printf ''pr merge 123\n'' | xargs env gh',
                'printf ''pr merge 123\n'' | xargs -I{} sh -c ''gh {}''',
                'Start-Process (Get-Command gh) -ArgumentList ''pr merge 123'' -Wait',
                'Start-Process (''g''+''h'') -ArgumentList ''pr merge 123'' -Wait',
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
                'gh api repos/OWNER/REPO/git/refs -f ref=refs/heads/topic -f sha=abc',
                'gh api graphql -f query=''mutation { createRef(input:{}) { ref { id } } }''',
                'gh api graphql -f query=''mutation { updateRef(input:{}) { clientMutationId } }''',
                'gh api graphql -f query=''mutation { deleteRef(input:{}) { clientMutationId } }'''
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
                '(true; git add README.md)',
                'git -c alias.ci=commit ci -m x',
                'git config user.name Worker',
                'git diff --output=C:/repo/README.md',
                'env FOO=1 git config user.name Worker',
                'FOO=1 git diff --output=C:/repo/README.md',
                'pwsh -Com "git add README.md"',
                'pwsh -Com "git push origin feature/review-gate"',
                'pwsh -Command "if ($true) { git add README.md }"',
                'pwsh -Command "if ($true) { git add README.md; if ($false) {} }"',
                'pwsh -Command "& { if ($true) { git add README.md } }"',
                'pwsh -Command "foreach ($x in 1) { git push origin feature/review-gate }"',
                'pwsh -Command "iex ''git add README.md''"',
                'pwsh -Command "Invoke-Expression ''git add README.md''"',
                'pwsh -Command "[scriptblock]::Create(''git add README.md'').Invoke()"',
                'pwsh -Command "$c=''git add README.md''; [scriptblock]::Create($c).Invoke()"',
                'bash -c"git add README.md"',
                'bash -lc "command git add README.md"',
                'bash -lc "exec git push origin feature/review-gate"',
                'printf ''add README.md\n'' | xargs git',
                'printf ''pr merge 123\n'' | xargs gh',
                'printf ''add README.md\n'' | xargs env git',
                'printf ''pr merge 123\n'' | xargs env gh',
                'printf ''add README.md\n'' | xargs -I{} sh -c ''git {}''',
                'printf ''pr merge 123\n'' | xargs -I{} sh -c ''gh {}''',
                'Start-Process git -ArgumentList ''add README.md''',
                'Start-Process git add README.md',
                '$g=''git''; Start-Process $g -ArgumentList ''add README.md''',
                'Start-Process (Get-Command git) -ArgumentList ''add README.md''',
                'Start-Process $env:COMSPEC -ArgumentList ''/c git add README.md''',
                'cmd /c start git add README.md',
                'pwsh -Command "Start-Process git -ArgumentList ''add README.md''"',
                'pwsh -Command "Start-Process -FilePath pwsh -ArgumentList ''-NoProfile'', ''-Command'', ''git add README.md''"',
                'Start-Process -FilePath pwsh -ArgumentList @(''-NoProfile'', ''-Command'', ''git add README.md'')',
                'command git add README.md',
                'builtin command git commit -m x',
                'env -S "git add README.md"',
                'Set-Alias g git; g add README.md',
                'Set-Alias g git; function f { g add . }; f',
                'Set-Alias -Name g -Value git; g add README.md',
                'Set-Alias -Nam:g -Val:git; g add README.md',
                'Set-Alias h gh; h pr merge 123 --squash',
                'alias g=git; g add README.md',
                'alias g=git; f(){ g add .; }; f',
                'alias g="command git"; g add README.md',
                'alias g="env git"; g add README.md',
                'alias h="builtin gh"; h pr merge 123 --squash',
                'alias ga="git add"; ga README.md',
                'g(){ git "$@"; }; g add README.md',
                'g(){ "$@"; }; g git add README.md',
                'g(){ command "$@"; }; g git add README.md',
                'g(){ git add README.md; }; g',
                'sh -c "git add README.md"',
                'bash -lc "git add README.md"',
                'git -c alias.m="!git m merge main" m',
                'cmd /c "echo x & git add README.md"',
                'cmd /c"echo x & git add README.md"',
                'cmd /c g^it add README.md',
                'bash -c "g\it add README.md"',
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
            $result.OutputObject.systemMessage | Should -Match 'Worker-pane Git lifecycle blocked' -Because $command
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

    It 'allows and creates one-file git commit after same-head review PASS' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $winsmuxProbe = @(& (Join-Path $fixture.RepoRoot '.winsmux-test-bin\winsmux.cmd') 'list-panes')
        $winsmuxProbe | Should -Be @(
            ('$1' + "`t" + 'winsmux-gate' + "`t" + '%1' + "`t" + 'Bootstrap'),
            ('$1' + "`t" + 'winsmux-gate' + "`t" + '%4' + "`t" + 'Reviewer Pane')
        )

        $reviewerEnv = @{
            WINSMUX_ROLE      = 'Reviewer'
            WINSMUX_PANE_ID   = '%4'
            WINSMUX_ROLE_MAP  = '{"%4":"Reviewer"}'
            WINSMUX_AGENT_NAME = 'codex'
        }

        Write-GateTestFile -Path (Join-Path $fixture.RepoRoot 'approved-change.txt') -Content 'approved change'
        & git -C $fixture.RepoRoot add -- approved-change.txt
        $LASTEXITCODE | Should -Be 0
        @(& git -C $fixture.RepoRoot diff --cached --name-only) | Should -Be @('approved-change.txt')

        $requestResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-request') -Environment $reviewerEnv
        $requestResult.ExitCode | Should -Be 0 -Because $requestResult.StdErr

        $approveResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-approve') -Environment $reviewerEnv
        $approveResult.ExitCode | Should -Be 0 -Because $approveResult.StdErr

        $reviewStatePath = Join-Path $fixture.RepoRoot '.winsmux\review-state.json'
        Test-Path -LiteralPath $reviewStatePath | Should -Be $true
        $reviewState = Get-Content -LiteralPath $reviewStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $reviewState.'feature/review-gate'.status | Should -Be 'PASS'
        $reviewState.'feature/review-gate'.reviewer.role | Should -Be 'reviewer'
        $reviewState.'feature/review-gate'.reviewer.pane_id | Should -Be '%4'
        $reviewState.'feature/review-gate'.reviewer.agent_name | Should -Be 'local-reviewer'
        $reviewState.'feature/review-gate'.reviewer.backend | Should -Be 'local'
        $reviewState.'feature/review-gate'.reviewer.generation_id | Should -Be 'gate-generation'
        $reviewState.'feature/review-gate'.request.head_sha | Should -Not -BeNullOrEmpty
        $reviewState.'feature/review-gate'.request.target_reviewer_pane_id | Should -Be '%4'
        $reviewState.'feature/review-gate'.request.review_contract.source_task | Should -Be 'TASK-210'
        $reviewState.'feature/review-gate'.request.review_contract.style | Should -Be 'utility_first'
        $reviewState.'feature/review-gate'.request.review_contract.required_scope | Should -Be @('design_impact', 'replacement_coverage', 'orphaned_artifacts', 'pathspec_completeness')
        $reviewState.'feature/review-gate'.evidence.approved_at | Should -Not -BeNullOrEmpty
        $reviewState.'feature/review-gate'.evidence.approved_via | Should -Be 'winsmux review-approve'
        $reviewState.'feature/review-gate'.evidence.review_contract_snapshot.required_scope | Should -Be @('design_impact', 'replacement_coverage', 'orphaned_artifacts', 'pathspec_completeness')
        $reviewedHead = [string]$reviewState.'feature/review-gate'.request.head_sha
        $reviewedHead | Should -Be (Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot)

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'git commit -m "feat: approved"'
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''

        & git -C $fixture.RepoRoot -c user.name='Test User' -c user.email='test@example.com' commit -m 'feat: approved'
        $LASTEXITCODE | Should -Be 0

        $committedHead = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $committedHead | Should -Not -Be $reviewedHead
        (& git -C $fixture.RepoRoot rev-parse "$committedHead^").Trim() | Should -Be $reviewedHead
        @(& git -C $fixture.RepoRoot diff-tree --no-commit-id --name-only -r $committedHead) | Should -Be @('approved-change.txt')
    }

    It 'rejects approval from a different pane without changing PENDING or HEAD' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $reviewerEnv = @{
            WINSMUX_ROLE = 'Reviewer'; WINSMUX_PANE_ID = '%4'; WINSMUX_ROLE_MAP = '{"%4":"Reviewer"}'
            WINSMUX_AGENT_NAME = 'spoofed-agent'
        }
        $requestResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-request') -Environment $reviewerEnv
        $requestResult.ExitCode | Should -Be 0 -Because $requestResult.StdErr

        $reviewStatePath = Join-Path $fixture.RepoRoot '.winsmux\review-state.json'
        $beforeState = [Convert]::ToBase64String([IO.File]::ReadAllBytes($reviewStatePath))
        $beforeHead = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $otherPaneEnv = @{
            WINSMUX_ROLE = 'Reviewer'; WINSMUX_PANE_ID = '%9'; WINSMUX_ROLE_MAP = '{"%9":"Reviewer"}'
            WINSMUX_AGENT_NAME = 'local-reviewer'
        }

        $approveResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-approve') -Environment $otherPaneEnv
        $approveResult.ExitCode | Should -Be 1
        $approveResult.StdErr | Should -Match 'Pane %9 was not found'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($reviewStatePath)) | Should -Be $beforeState
        (Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot) | Should -Be $beforeHead
    }

    It 'rejects approval after HEAD changes without changing PENDING or the new HEAD' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $reviewerEnv = @{
            WINSMUX_ROLE = 'Reviewer'; WINSMUX_PANE_ID = '%4'; WINSMUX_ROLE_MAP = '{"%4":"Reviewer"}'
            WINSMUX_AGENT_NAME = 'spoofed-agent'
        }
        $requestResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-request') -Environment $reviewerEnv
        $requestResult.ExitCode | Should -Be 0 -Because $requestResult.StdErr

        Write-GateTestFile -Path (Join-Path $fixture.RepoRoot 'head-change.txt') -Content 'new head'
        & git -C $fixture.RepoRoot add -- head-change.txt
        $LASTEXITCODE | Should -Be 0
        $noHooks = Join-Path $fixture.RepoRoot '.git\no-hooks'
        & git -C $fixture.RepoRoot -c "core.hooksPath=$noHooks" -c user.name='Test User' -c user.email='test@example.com' commit -m 'test: advance head'
        $LASTEXITCODE | Should -Be 0

        $reviewStatePath = Join-Path $fixture.RepoRoot '.winsmux\review-state.json'
        $beforeState = [Convert]::ToBase64String([IO.File]::ReadAllBytes($reviewStatePath))
        $advancedHead = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $approveResult = & $script:InvokeWinsmuxCore -RepoRoot $fixture.RepoRoot -Arguments @('review-approve') -Environment $reviewerEnv
        $approveResult.ExitCode | Should -Be 1
        $approveResult.StdErr | Should -Match 'head mismatch'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($reviewStatePath)) | Should -Be $beforeState
        (Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot) | Should -Be $advancedHead
    }

    It 'uses tool input cwd for review-gated git lifecycle checks' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'git commit -m "feat: approved-target-cwd"'
            cwd     = $target.RepoRoot
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'uses tool input cwd for review-gated shell function lifecycle checks' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'g() { git "$@"; }; g commit -m "feat: approved-target-wrapper"'
            cwd     = $target.RepoRoot
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'uses Start-Process WorkingDirectory for review-gated lifecycle checks' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('pwsh -Command "Start-Process git -ArgumentList ''commit -m start-process-approved'' -WorkingDirectory ''{0}'' -Wait"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'uses Start-Process WorkingDirectory for dynamic review-gated lifecycle checks' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('pwsh -Command "Start-Process (Get-Command git) -ArgumentList ''commit -m start-process-dynamic-approved'' -WorkingDirectory ''{0}'' -Wait"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy a Start-Process WorkingDirectory lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('pwsh -Command "Start-Process git -ArgumentList ''commit -m start-process-denied'' -WorkingDirectory ''{0}'' -Wait"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'does not allow root PASS to satisfy a dynamic Start-Process WorkingDirectory target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('pwsh -Command "Start-Process (Get-Command git) -ArgumentList ''commit -m start-process-dynamic-denied'' -WorkingDirectory ''{0}'' -Wait"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses caller cwd when WorkingDirectory appears only inside Start-Process ArgumentList' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('pwsh -Command "Start-Process git -ArgumentList ''commit'', ''-m'', ''-WorkingDirectory:{0}'' -Wait"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow ArgumentList WorkingDirectory text to satisfy Start-Process cwd' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('pwsh -Command "Start-Process git -ArgumentList ''commit'', ''-m'', ''-WorkingDirectory:{0}'' -Wait"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'honors inline Start-Process WorkingDirectory after ArgumentList' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('pwsh -Command "Start-Process git -ArgumentList commit -WorkingDirectory:{0} -Wait"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow caller PASS to satisfy inline Start-Process WorkingDirectory after ArgumentList' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('pwsh -Command "Start-Process git -ArgumentList commit -WorkingDirectory:{0} -Wait"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses shell function body targets for review-gated lifecycle checks' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('g() {{ git -C "{0}" "$@"; }}; g commit -m "feat: approved-function-target"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not require caller PASS for a parsed shell function target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'FAIL'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('g() {{ git -C "{0}" "$@"; }}; g commit -m "feat: approved-function-target-only"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy a shell function body lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('g() {{ git -C "{0}" "$@"; }}; g commit -m "feat: denied-function-target"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses the call-site cwd for shell function forwarding lifecycle checks' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('cd "{0}"; g() {{ git "$@"; }}; g commit -m "feat: approved-function-cd"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy shell function forwarding after cd' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('cd "{0}"; g() {{ git "$@"; }}; g commit -m "feat: denied-function-cd"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses the current cwd for review-gated shell command substitutions' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('cd "{0}" && echo $(git commit -m "feat: approved-substitution-cd")' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy a review-gated shell command substitution after cd' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('cd "{0}" && echo $(git commit -m "feat: denied-substitution-cd")' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'requires current repo PASS for review-gated backtick command substitutions' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m `git commit -m "feat: denied-inner-backtick"`' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'allows review-gated backtick command substitutions when each repo has PASS' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null
        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m `git commit -m "feat: approved-inner-backtick"`' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'ignores single-quoted shell command substitutions when selecting review targets' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git commit -m ''$(git -C "{0}" commit -m "feat: ignored-substitution")''' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root review PASS to satisfy a target cwd git lifecycle check' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'git commit -m "feat: denied-target-cwd"'
            cwd     = $target.RepoRoot
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'ignores unrelated git -C stages when selecting the review-gated repo root' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" status; git commit -m "feat: denied-target-cwd"' -f $fixture.RepoRoot)
            cwd     = $target.RepoRoot
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses git -C target for review-gated git lifecycle checks' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m "feat: approved-target-c" ' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not resolve shell-expanded git cwd tokens as literal repo paths' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $literalTarget = New-GateTargetRepo -Root $fixture.RepoRoot -Name '$TARGET' -Branch 'feature/review-gate-literal-target'
        $literalHeadSha = Get-GateFixtureHeadSha -RepoRoot $literalTarget.RepoRoot

        Set-GateReviewState -RepoRoot $literalTarget.RepoRoot -Branch $literalTarget.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $literalHeadSha
            request   = [ordered]@{
                branch                  = $literalTarget.Branch
                head_sha                = $literalHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'git -C $TARGET commit -m "feat: denied-expanded-cwd"'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'does not resolve home-shortcut git cwd tokens as literal repo paths' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $literalTarget = New-GateTargetRepo -Root $fixture.RepoRoot -Name '~\repo' -Branch 'feature/review-gate-literal-home'
        $literalHeadSha = Get-GateFixtureHeadSha -RepoRoot $literalTarget.RepoRoot

        Set-GateReviewState -RepoRoot $literalTarget.RepoRoot -Branch $literalTarget.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $literalHeadSha
            request   = [ordered]@{
                branch                  = $literalTarget.Branch
                head_sha                = $literalHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'git -C ~/repo commit -m "feat: denied-home-shortcut-cwd"'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'does not resolve cmd-expanded git cwd tokens as literal repo paths' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $literalTarget = New-GateTargetRepo -Root $fixture.RepoRoot -Name '%TARGET%' -Branch 'feature/review-gate-literal-cmd'
        $literalHeadSha = Get-GateFixtureHeadSha -RepoRoot $literalTarget.RepoRoot

        Set-GateReviewState -RepoRoot $literalTarget.RepoRoot -Branch $literalTarget.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $literalHeadSha
            request   = [ordered]@{
                branch                  = $literalTarget.Branch
                head_sha                = $literalHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = 'cmd /c git -C %TARGET% commit -m "feat: denied-cmd-expanded-cwd"'
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses the effective final git -C path when multiple cwd options are present' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot
        $targetRelativeFromRoot = [System.IO.Path]::GetRelativePath($fixture.RepoRoot, $target.RepoRoot)

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" -C "{1}" commit -m "feat: approved-final-cwd"' -f $fixture.RepoRoot, $targetRelativeFromRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'preserves the prior git -C path when a later cwd option is empty' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" -C "" commit -m "feat: approved-empty-cwd"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy a git -C target followed by an empty cwd option' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" -C "" commit -m "feat: denied-empty-cwd"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'does not allow the first git -C PASS to satisfy a later git -C lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetRelativeFromRoot = [System.IO.Path]::GetRelativePath($fixture.RepoRoot, $target.RepoRoot)

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" -C "{1}" commit -m "feat: denied-final-cwd"' -f $fixture.RepoRoot, $targetRelativeFromRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses xargs git -C target for review-gated lifecycle checks' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('printf ''commit -m x\n'' | xargs git -C "{0}"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy an xargs git -C lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('printf ''commit -m x\n'' | xargs git -C "{0}"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'requires PASS for every git -C lifecycle target in the same command' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m "feat: approved-first"; git -C "{1}" commit -m "feat: denied-second"' -f $fixture.RepoRoot, $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'allows multiple git -C lifecycle targets only when each target has PASS' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null
        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m "feat: approved-first"; git -C "{1}" commit -m "feat: approved-second"' -f $fixture.RepoRoot, $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not let non-executed git text steer review-gated target selection' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('echo git -C "{0}" commit; git -C "{1}" commit -m "feat: denied-actual-target"' -f $fixture.RepoRoot, $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses git shell alias body targets for review-gated lifecycle checks' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -c "alias.cm=!git -C ''{0}'' commit --allow-empty -m alias-target" cm' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy a git shell alias target lifecycle' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -c "alias.cm=!git -C ''{0}'' commit --allow-empty -m alias-target-denied" cm' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'requires current repo PASS when a grouped git lifecycle follows a git target command' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m "feat: approved-target"; (git commit -m "feat: denied-grouped-base")' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'allows a grouped git lifecycle only when target and current repos have PASS' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null
        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m "feat: approved-target"; (git commit -m "feat: approved-grouped-base")' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'requires current repo PASS when a grouped command mixes target and current git lifecycles' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('(git -C "{0}" commit -m "feat: approved-target"; git commit -m "feat: denied-grouped-current")' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'allows grouped mixed git lifecycles only when target and current repos have PASS' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null
        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('(git -C "{0}" commit -m "feat: approved-target"; git commit -m "feat: approved-grouped-current")' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'requires current repo PASS when git target commands are mixed with gh pr merge' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m "feat: approved-target"; gh pr merge 123 --squash' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'allows mixed git target and gh pr merge only when each repo has PASS' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null
        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m "feat: approved-target"; gh pr merge 123 --squash' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'requires current repo PASS when git target commands are mixed with gh api merge' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m "feat: approved-target"; gh api repos/Sora-bluesky/winsmux/pulls/123/merge -X PUT' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'requires current repo PASS when an unparsed git alias follows a git target command' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('g() {{ git "$@"; }}; git -C "{0}" commit -m "feat: approved-target"; g commit -m "feat: denied-current"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'requires current repo PASS when a timed git lifecycle follows a git target command' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m "feat: approved-target"; time git commit -m "feat: denied-current"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'allows mixed git target and timed git lifecycle only when each repo has PASS' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m "feat: approved-target"; time git commit -m "feat: approved-current"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'requires current repo PASS when a control-flow git lifecycle follows a git target command' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m "feat: approved-target"; if true; then git commit -m "feat: denied-current"; fi' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'allows mixed git target and control-flow git lifecycle only when each repo has PASS' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git -C "{0}" commit -m "feat: approved-target"; if true; then git commit -m "feat: approved-current"; fi' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'keeps scanning git global options with values before lifecycle -C paths' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --namespace "review-test" -C "{0}" commit -m "feat: approved-option-cwd"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not fall back to root PASS when git global options precede a target -C path' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --namespace "review-test" -C "{0}" commit -m "feat: denied-option-cwd"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses a later git -C path when resolving relative --work-tree targets' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --work-tree "." -C "{0}" commit -m "feat: approved-later-cwd-work-tree"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS when a later git -C path rebases --work-tree' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --work-tree "." -C "{0}" commit -m "feat: denied-later-cwd-work-tree"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses the current repo when only a Git work tree is supplied' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        foreach ($command in @(
                ('git --work-tree "{0}" commit -m "feat: approved-current-work-tree-only"' -f $target.RepoRoot),
                ('GIT_WORK_TREE="{0}" git commit -m "feat: approved-current-env-work-tree-only"' -f $target.RepoRoot)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
                command = $command
            })

            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
        }
    }

    It 'does not allow work-tree PASS when only a Git work tree is supplied' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        foreach ($command in @(
                ('git --work-tree "{0}" commit -m "feat: denied-current-work-tree-only"' -f $target.RepoRoot),
                ('GIT_WORK_TREE="{0}" git commit -m "feat: denied-current-env-work-tree-only"' -f $target.RepoRoot)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
                command = $command
            })

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'review-approve'
            $result.OutputObject.systemMessage | Should -Match 'review-request'
        }
    }

    It 'uses git -C repo when only inline Git work tree is supplied' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $workTree = New-GateTargetRepo -Root $fixture.Root -Name 'approved-work-tree' -Branch 'feature/review-gate-work-tree'
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'target' -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('GIT_WORK_TREE="{0}" git -C "{1}" commit -m "feat: approved-work-tree-with-c"' -f $workTree.RepoRoot, $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow caller PASS for inline Git work tree with git -C target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $workTree = New-GateTargetRepo -Root $fixture.Root -Name 'approved-work-tree' -Branch 'feature/review-gate-work-tree'
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'target' -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('GIT_WORK_TREE="{0}" git -C "{1}" commit -m "feat: denied-work-tree-with-c"' -f $workTree.RepoRoot, $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses git --work-tree as the review-gated lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --git-dir "{0}" --work-tree "{1}" commit -m "feat: approved-work-tree"' -f $targetGitDir, $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy a git --work-tree lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --git-dir "{0}" --work-tree "{1}" commit -m "feat: denied-work-tree"' -f $targetGitDir, $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses git --git-dir as the review-gated lifecycle target when work-tree points elsewhere' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $repoTarget = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $workTreeTarget = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-worktree'
        $repoTargetHeadSha = Get-GateFixtureHeadSha -RepoRoot $repoTarget.RepoRoot
        $repoTargetGitDir = Join-Path $repoTarget.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $repoTarget.RepoRoot -Branch $repoTarget.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $repoTargetHeadSha
            request   = [ordered]@{
                branch                  = $repoTarget.Branch
                head_sha                = $repoTargetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --git-dir "{0}" --work-tree "{1}" commit -m "feat: approved-git-dir-over-work-tree"' -f $repoTargetGitDir, $workTreeTarget.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow work-tree PASS to satisfy a different git-dir lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $repoTarget = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $workTreeTarget = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-worktree'
        $workTreeTargetHeadSha = Get-GateFixtureHeadSha -RepoRoot $workTreeTarget.RepoRoot
        $repoTargetGitDir = Join-Path $repoTarget.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $workTreeTarget.RepoRoot -Branch $workTreeTarget.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $workTreeTargetHeadSha
            request   = [ordered]@{
                branch                  = $workTreeTarget.Branch
                head_sha                = $workTreeTargetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --git-dir "{0}" --work-tree "{1}" commit -m "feat: denied-work-tree-over-git-dir"' -f $repoTargetGitDir, $workTreeTarget.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses git --git-dir as the review-gated lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --git-dir "{0}" commit -m "feat: approved-git-dir"' -f $targetGitDir)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy a git --git-dir lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --git-dir "{0}" commit -m "feat: denied-git-dir"' -f $targetGitDir)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses linked worktree .git pointer files as review-gated lifecycle targets' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateLinkedWorktree -SourceRepoRoot $fixture.RepoRoot -Root $fixture.Root -Branch 'feature/review-gate-linked'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        (Get-Item -LiteralPath $targetGitDir).PSIsContainer | Should -Be $false

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --git-dir "{0}" --work-tree "{1}" commit -m "feat: approved-linked-git-dir"' -f $targetGitDir, $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy a linked worktree .git pointer target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateLinkedWorktree -SourceRepoRoot $fixture.RepoRoot -Root $fixture.Root -Branch 'feature/review-gate-linked'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        (Get-Item -LiteralPath $targetGitDir).PSIsContainer | Should -Be $false

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --git-dir "{0}" --work-tree "{1}" commit -m "feat: denied-linked-git-dir"' -f $targetGitDir, $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses linked worktree git-dir paths as review-gated lifecycle targets' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateLinkedWorktree -SourceRepoRoot $fixture.RepoRoot -Root $fixture.Root -Branch 'feature/review-gate-linked'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot
        $targetGitPointer = Join-Path $target.RepoRoot '.git'
        $actualGitDir = ((Get-Content -LiteralPath $targetGitPointer -Raw -Encoding UTF8) -replace '^gitdir:\s*', '').Trim()

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        Test-Path -LiteralPath $actualGitDir | Should -Be $true

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --git-dir "{0}" --work-tree "{1}" commit -m "feat: approved-linked-git-dir-path"' -f $actualGitDir, $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy a linked worktree git-dir path target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateLinkedWorktree -SourceRepoRoot $fixture.RepoRoot -Root $fixture.Root -Branch 'feature/review-gate-linked'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetGitPointer = Join-Path $target.RepoRoot '.git'
        $actualGitDir = ((Get-Content -LiteralPath $targetGitPointer -Raw -Encoding UTF8) -replace '^gitdir:\s*', '').Trim()

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        Test-Path -LiteralPath $actualGitDir | Should -Be $true

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('git --git-dir "{0}" --work-tree "{1}" commit -m "feat: denied-linked-git-dir-path"' -f $actualGitDir, $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses inline Git environment work tree as the review-gated lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('GIT_DIR="{0}" GIT_WORK_TREE="{1}" git commit -m "feat: approved-env-work-tree"' -f $targetGitDir, $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy an inline Git environment work tree target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('GIT_DIR="{0}" GIT_WORK_TREE="{1}" git commit -m "feat: denied-env-work-tree"' -f $targetGitDir, $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses env split-string Git environment targets for review-gated lifecycle checks' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('env -S "GIT_DIR=''{0}'' GIT_WORK_TREE=''{1}'' git commit -m approved-env-split"' -f $targetGitDir, $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy env split-string Git environment targets' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('env -S "GIT_DIR=''{0}'' GIT_WORK_TREE=''{1}'' git commit -m denied-env-split"' -f $targetGitDir, $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses inline GIT_DIR as the review-gated lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('GIT_DIR="{0}" git commit -m "feat: approved-env-git-dir"' -f $targetGitDir)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy an inline GIT_DIR target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('GIT_DIR="{0}" git commit -m "feat: denied-env-git-dir"' -f $targetGitDir)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses caller repo when env unsets prefixed Git directory' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        foreach ($command in @(
                ('GIT_DIR="{0}" env -u GIT_DIR git commit -m "feat: approved-env-unset-git-dir"' -f $targetGitDir),
                ('GIT_DIR="{0}" env -i git commit -m "feat: approved-env-ignore-git-dir"' -f $targetGitDir)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
                command = $command
            })

            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
        }
    }

    It 'does not allow discarded Git env PASS after env unset or ignore-environment' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        foreach ($command in @(
                ('GIT_DIR="{0}" env -u GIT_DIR git commit -m "feat: denied-env-unset-git-dir"' -f $targetGitDir),
                ('GIT_DIR="{0}" env -i git commit -m "feat: denied-env-ignore-git-dir"' -f $targetGitDir)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
                command = $command
            })

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'review-approve'
            $result.OutputObject.systemMessage | Should -Match 'review-request'
        }
    }

    It 'resolves relative inline Git environment paths after git -C' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $launcher = New-GateTargetRepo -Root $fixture.RepoRoot -Name 'launcher' -Branch 'feature/review-gate-launcher'
        $target = New-GateTargetRepo -Root $fixture.RepoRoot -Name 'target' -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('GIT_DIR="../target/.git" GIT_WORK_TREE="../target" git -C "{0}" commit -m "feat: approved-env-after-c"' -f $launcher.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy inline Git environment paths rebased by git -C' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $launcher = New-GateTargetRepo -Root $fixture.RepoRoot -Name 'launcher' -Branch 'feature/review-gate-launcher'
        New-GateTargetRepo -Root $fixture.RepoRoot -Name 'target' -Branch 'feature/review-gate-target' | Out-Null
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('GIT_DIR="../target/.git" GIT_WORK_TREE="../target" git -C "{0}" commit -m "feat: denied-env-after-c"' -f $launcher.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses env chdir as the review-gated lifecycle base cwd' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('env -C "{0}" git commit -m "feat: approved-env-chdir"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy an env chdir target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('env -C "{0}" git commit -m "feat: denied-env-chdir"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses env chdir as the review-gated base cwd for nested shell commands' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('env -C "{0}" bash -lc "git commit -m ''feat: approved-env-shell''"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy an env chdir nested shell lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('env -C "{0}" bash -lc "git commit -m ''feat: denied-env-shell''"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses shell cd as the review-gated base cwd for following git lifecycle commands' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('cd "{0}" && git commit -m "feat: approved-shell-cd"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy a shell cd git lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('cd "{0}" && git commit -m "feat: denied-shell-cd"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'fails closed for previous-directory shell cd before lifecycle commands' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        foreach ($command in @(
                'cd -; git commit -m "feat: denied-previous-cd"',
                'cd -- -; git commit -m "feat: denied-previous-cd-after-options"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
                command = $command
            })

            & $script:AssertDenyResult -Result $result
            $result.OutputObject.systemMessage | Should -Match 'review-approve'
            $result.OutputObject.systemMessage | Should -Match 'review-request'
        }
    }

    It 'uses control-flow shell cd as the review-gated base cwd for following lifecycle commands' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('if true; then cd "{0}"; git commit -m "feat: approved-control-flow-cd"; fi' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy a control-flow shell cd lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('if true; then cd "{0}"; git commit -m "feat: denied-control-flow-cd"; fi' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'preserves nested control-flow shell cd for following lifecycle commands in the outer branch' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('if true; then if true; then cd "{0}"; fi; git commit -m "feat: approved-nested-control-flow-cd"; fi' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy a nested control-flow shell cd lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('if true; then if true; then cd "{0}"; fi; git commit -m "feat: denied-nested-control-flow-cd"; fi' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'preserves an executed control-flow shell cd after the block closes' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('if true; then cd "{0}"; fi; git commit -m "feat: approved-post-block-control-flow-cd"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy an executed post-block control-flow shell cd lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('if true; then cd "{0}"; fi; git commit -m "feat: denied-post-block-control-flow-cd"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses the outer cwd after a closed control-flow shell cd block' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('if false; then cd "{0}"; fi; git commit -m "feat: approved-after-closed-control-flow"' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow target PASS to satisfy a lifecycle after a closed control-flow shell cd block' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('if false; then cd "{0}"; fi; git commit -m "feat: denied-after-closed-control-flow"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'uses shell brace group cd as the review-gated base cwd for lifecycle commands' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('{{ cd "{0}"; git commit -m "feat: approved-brace-cd"; }}' -f $target.RepoRoot)
        })

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
    }

    It 'does not allow root PASS to satisfy a shell brace group cd lifecycle target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $rootHeadSha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot

        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $rootHeadSha
            request   = [ordered]@{
                branch                  = $fixture.Branch
                head_sha                = $rootHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('{{ cd "{0}"; git commit -m "feat: denied-brace-cd"; }}' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'does not treat conditionally skipped shell cd as an executed lifecycle target cwd' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('false && cd "{0}"; git commit -m "feat: denied-conditional-cd"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'does not treat shell cd before an or-else lifecycle as the lifecycle cwd' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('cd "{0}" || git commit -m "feat: denied-or-else-cd"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'does not treat backgrounded shell cd as the lifecycle cwd' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('cd "{0}" & git commit -m "feat: denied-backgrounded-cd"' -f $target.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'prefers inline Git environment targets over bare git chdir cwd' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $approved = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-approved'
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $approvedHeadSha = Get-GateFixtureHeadSha -RepoRoot $approved.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $approved.RepoRoot -Branch $approved.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $approvedHeadSha
            request   = [ordered]@{
                branch                  = $approved.Branch
                head_sha                = $approvedHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('GIT_DIR="{0}" GIT_WORK_TREE="{1}" git -C "{2}" commit -m "feat: denied-env-over-chdir"' -f $targetGitDir, $target.RepoRoot, $approved.RepoRoot)
        })

        & $script:AssertDenyResult -Result $result
        $result.OutputObject.systemMessage | Should -Match 'review-approve'
        $result.OutputObject.systemMessage | Should -Match 'review-request'
    }

    It 'allows inline Git environment targets with bare git chdir when target has PASS' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $launcher = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-launcher'
        $target = New-GateTargetRepo -Root $fixture.Root -Branch 'feature/review-gate-target'
        $targetHeadSha = Get-GateFixtureHeadSha -RepoRoot $target.RepoRoot
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        Set-GateReviewState -RepoRoot $target.RepoRoot -Branch $target.Branch -Entry ([ordered]@{
            status    = 'PASS'
            head_sha  = $targetHeadSha
            request   = [ordered]@{
                branch                  = $target.Branch
                head_sha                = $targetHeadSha
                target_reviewer_pane_id = '%4'
            }
            reviewer  = [ordered]@{
                role    = 'Reviewer'
                pane_id = '%4'
            }
            updatedAt = '2026-04-07T09:00:00.0000000+09:00'
        }) | Out-Null

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput ([ordered]@{
            command = ('GIT_DIR="{0}" GIT_WORK_TREE="{1}" git -C "{2}" commit -m "feat: approved-env-over-chdir"' -f $targetGitDir, $target.RepoRoot, $launcher.RepoRoot)
        })

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
        $reviewState.'feature/review-gate'.evidence.review_contract_snapshot.required_scope | Should -Be @('design_impact', 'replacement_coverage', 'orphaned_artifacts', 'pathspec_completeness')
    }

    It 'TASK-783 C03 allows lifecycle commands that resolve only to an unrelated repository' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'unrelated-repo'
        Remove-Item -LiteralPath (Join-Path $target.RepoRoot '.winsmux') -Recurse -Force

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = ('git -C "{0}" commit -m unrelated' -f $target.RepoRoot)
        }

        $result.ExitCode | Should -Be 0
        $result.StdErr | Should -Be ''
        $result.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C08 denies constant wrapper lifecycle bypasses for an unreviewed managed target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'managed-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        $commands = @(
            'time git -C "{0}" commit -m x',
            'command git -C "{0}" commit -m x',
            'exec git -C "{0}" commit -m x',
            'nohup git -C "{0}" commit -m x',
            'nohup -- git -C "{0}" commit -m x',
            'timeout 10 git -C "{0}" commit -m x',
            'timeout -k 2 10 git -C "{0}" commit -m x',
            'stdbuf -oL git -C "{0}" commit -m x',
            'stdbuf -o L git -C "{0}" commit -m x',
            'nice git -C "{0}" commit -m x',
            'nice -n 5 git -C "{0}" commit -m x',
            'ionice git -C "{0}" commit -m x',
            'ionice -c 2 -n 7 git -C "{0}" commit -m x',
            'setsid git -C "{0}" commit -m x',
            'setsid -f git -C "{0}" commit -m x',
            'sudo git -C "{0}" commit -m x',
            'sudo -u root git -C "{0}" commit -m x',
            'eval ''git -C "{0}" commit -m x''',
            'script -q -c ''git -C "{0}" commit -m x'' /dev/null'
        )
        $allowed = @()
        foreach ($template in $commands) {
            $command = $template -f $target.RepoRoot
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if ($null -eq $result.OutputObject -or $result.OutputObject.hookSpecificOutput.permissionDecision -ne 'deny') {
                $allowed += $command
            }
        }

        ($allowed -join "`n") | Should -Be ''
    }

    It 'TASK-783 C10 denies constant command-substitution Git executables for an unreviewed managed target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'substitution-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $commands = @(
            ('$(echo git) -C "{0}" commit -m substitution-bypass' -f $target.RepoRoot),
            ('`echo git` -C "{0}" commit -m backtick-bypass' -f $target.RepoRoot)
        )
        $allowed = @()
        foreach ($command in $commands) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if ($null -eq $result.OutputObject -or $result.OutputObject.hookSpecificOutput.permissionDecision -ne 'deny') {
                $allowed += $command
            }
        }

        ($allowed -join "`n") | Should -Be ''
    }

    It 'TASK-783 C12 denies an executable heredoc lifecycle body without PASS' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $command = @'
bash <<'EOF'
git commit -m heredoc-bypass
EOF
'@

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
        & $script:AssertDenyResult -Result $result

        $target = New-GateTargetRepo -Root $fixture.Root -Name 'heredoc-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetCommand = "bash <<'EOF'`ngit -C `"$($target.RepoRoot)`" commit -m heredoc-target-bypass`nEOF"
        $targetResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $targetCommand }
        & $script:AssertDenyResult -Result $targetResult

        $literalResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = @'
cat <<'EOF'
git commit -m literal-only
EOF
'@ }
        $literalResult.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C13 denies a repository gitconfig commit alias without PASS' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        & git -C $fixture.RepoRoot config alias.cm commit
        if ($LASTEXITCODE -ne 0) { throw 'unable to configure synthetic Git alias' }

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = 'git cm -m alias-bypass' }
        & $script:AssertDenyResult -Result $result

        $globalConfig = Join-Path $fixture.Root 'synthetic-global-gitconfig'
        & git config --file $globalConfig alias.gcm commit
        if ($LASTEXITCODE -ne 0) { throw 'unable to configure synthetic global Git alias' }
        $globalAlias = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = 'git gcm -m global-alias-bypass' } -Environment @{
            GIT_CONFIG_GLOBAL = $globalConfig
        }
        & $script:AssertDenyResult -Result $globalAlias

        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $approved = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = 'git cm -m alias-approved' }
        $approved.OutputObject | Should -BeNullOrEmpty

        $target = New-GateTargetRepo -Root $fixture.Root -Name 'alias-target'
        & git -C $target.RepoRoot config alias.cm commit
        $targetDenied = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = ('env -C "{0}" git cm -m target-alias-bypass' -f $target.RepoRoot)
        }
        & $script:AssertDenyResult -Result $targetDenied

        Set-GatePass -RepoRoot $target.RepoRoot -Branch $target.Branch
        $targetApproved = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = ('env -C "{0}" git cm -m target-alias-approved' -f $target.RepoRoot)
        }
        $targetApproved.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C14 denies constant indirect interpreter lifecycle payloads without PASS' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $commands = @(
            'echo ''git commit -m pipe-bypass'' | bash',
            'bash -s <<< ''git commit -m here-string-bypass''',
            'node -e "require(''child_process'').execSync(''git commit -m node-bypass'')"',
            'python -c "import os; os.system(''git commit -m python-bypass'')"'
        )
        $allowed = @()
        foreach ($command in $commands) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if ($null -eq $result.OutputObject -or $result.OutputObject.hookSpecificOutput.permissionDecision -ne 'deny') {
                $allowed += $command
            }
        }

        ($allowed -join "`n") | Should -Be ''

        $target = New-GateTargetRepo -Root $fixture.Root -Name 'interpreter-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetPath = $target.RepoRoot.Replace('\', '/')
        $targetCommand = 'node -e "require(''child_process'').execSync(''git -C {0} commit -m interpreter-target-bypass'')"' -f $targetPath
        $targetResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $targetCommand }
        & $script:AssertDenyResult -Result $targetResult

        $readOnlyResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'node -e "require(''child_process'').execSync(''git status --short'')"'
        }
        $readOnlyResult.OutputObject | Should -BeNullOrEmpty

    }

    It 'TASK-783 C15 denies PowerShell EncodedCommand lifecycle payloads without PASS' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('git commit -m encoded-bypass'))
        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = "pwsh -EncodedCommand $encoded"
        }

        & $script:AssertDenyResult -Result $result
    }

    It 'TASK-783 C16 denies GitHub merge and ref writes explicitly targeting another repository' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $commands = @(
            'gh pr merge 1 -R other/repo --squash',
            'gh pr merge https://github.com/other/repo/pull/1 --squash',
            'GH_REPO=other/repo gh pr merge 1 --squash',
            'env GH_REPO=other/repo gh pr merge 1 --squash',
            'pwsh -Command "$env:GH_REPO=''other/repo''; gh pr merge 1 --squash"',
            'gh api -X PUT repos/other/repo/pulls/1/merge',
            'gh api -X PATCH repos/other/repo/git/refs/heads/main'
        )
        $allowed = @()
        foreach ($command in $commands) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if ($null -eq $result.OutputObject -or $result.OutputObject.hookSpecificOutput.permissionDecision -ne 'deny') {
                $allowed += $command
            }
        }

        ($allowed -join "`n") | Should -Be ''

        & git -C $fixture.RepoRoot remote add origin https://github.com/Sora-bluesky/winsmux.git
        if ($LASTEXITCODE -ne 0) { throw 'unable to configure synthetic origin' }
        foreach ($command in @(
                'gh pr merge 1 -R Sora-bluesky/winsmux --squash',
                'gh pr merge https://github.com/Sora-bluesky/winsmux/pull/1 --squash',
                'GH_REPO=Sora-bluesky/winsmux gh pr merge 1 --squash',
                'env GH_REPO=Sora-bluesky/winsmux gh pr merge 1 --squash',
                'pwsh -Command "$env:GH_REPO=''Sora-bluesky/winsmux''; gh pr merge 1 --squash"',
                'gh api -X PUT repos/Sora-bluesky/winsmux/pulls/1/merge'
            )) {
            $approved = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            $approved.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C17 requires PASS for managed repository ref writes' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $commands = @(
            'git push origin feature/review-gate',
            'git push origin feature/review-gate # bump-version',
            'git commit -m "chore: bump version to 0.0.0"',
            'cmd /c call git push origin feature/review-gate',
            'cmd /c @call gh pr merge 1 --squash',
            'git update-ref refs/heads/demo HEAD',
            'git branch -f demo HEAD',
            'git branch demo HEAD',
            'git tag -f demo HEAD'
        )
        $allowed = @()
        foreach ($command in $commands) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if ($null -eq $result.OutputObject -or $result.OutputObject.hookSpecificOutput.permissionDecision -ne 'deny') {
                $allowed += $command
            }
        }

        ($allowed -join "`n") | Should -Be ''

        foreach ($command in @('git branch --list', 'git tag --list', 'rg -n ''git push'' docs')) {
            $readOnly = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            $readOnly.OutputObject | Should -BeNullOrEmpty
        }

        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        foreach ($command in $commands) {
            $approved = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            $approved.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C19 denies executable-position Codex dispatches across constant wrappers' {
        $commands = @(
            'codex exec review',
            'env codex exec review',
            'command codex exec review',
            'bash -lc ''codex exec review''',
            'pwsh -Command "codex exec review"',
            'pwsh -Command "Start-Process codex -ArgumentList exec"',
            'pwsh -Command "saps codex -Args exec"',
            'pwsh -Command "Start-Process (Get-Command codex) -ArgumentList exec"',
            'cmd /c call codex exec review',
            'cmd /c @call codex exec review',
            '$(echo codex) exec review',
            '`echo codex` exec review',
            "bash <<'EOF'`ncodex exec review`nEOF",
            'node -e "require(''child_process'').execSync(''codex exec review'')"',
            'node -e "require(''child_process'').spawnSync(''codex'', [''exec'', ''review''])"',
            'python -c "import subprocess; subprocess.run([''codex'', ''exec'', ''review''])"',
            'python -c "import subprocess; subprocess.run((''codex'', ''exec'', ''review''))"'
        )
        $allowed = @()
        foreach ($command in $commands) {
            $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{ command = $command }
            if ($null -eq $result.OutputObject -or $result.OutputObject.hookSpecificOutput.permissionDecision -ne 'deny') {
                $allowed += $command
            }
        }

        ($allowed -join "`n") | Should -Be ''
    }

    It 'TASK-783 C20-C21 allows read-only Codex text and finitely allowlisted companion input' {
        foreach ($command in @(
                'rg -n ''codex exec'' docs',
                'git grep ''codex exec'' -- docs',
                'rg -n ''git commit'' docs',
                'git grep ''gh pr merge'' -- docs',
                'node companion-runtime.js --payload ''codex exec review''',
                'node -e "require(''child_process'').spawnSync(''echo'', [''codex'', ''exec''])"',
                'python -c "import subprocess; subprocess.run([''echo'', ''codex'', ''exec''])"',
                'cmd /c echo call codex exec review'
            )) {
            $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{ command = $command }
            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
            $result.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C93 defaults direct trampolines and unenumerated child executables to deny' {
        foreach ($command in @(
                'forfiles.exe /p . /m VERSION /c "cmd /c codex exec"',
                'git grep --open-files-in-page="codex exec --help" -e "^" -- .gitignore',
                'node -e "require(''child_process'').spawnSync(''mshta.exe'', [''javascript:new ActiveXObject(\"WScript.Shell\").Run(\"codex exec\");close()''])"',
                'python -c "import subprocess; subprocess.run([''wmic.exe'',''process'',''call'',''create'',''codex exec''])"',
                'python -c "import subprocess; subprocess.run([''schtasks.exe'',''/create'',''/tn'',''winsmux-review-bypass'',''/tr'',''codex exec''])"',
                'node -e "require(''child_process'').spawnSync(''helper'', [''codex'', ''exec''])"',
                'python -c "import subprocess; subprocess.run([''helper'', ''codex'', ''exec''])"',
                'pwsh -Command "Start-Process helper -ArgumentList codex,exec"'
            )) {
            $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }
    }

    It 'TASK-783 C23 inspects heredoc bodies executed by a pipeline consumer' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $command = @'
cat <<'EOF' | bash
git commit -m pipeline-heredoc-bypass
EOF
'@

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
        & $script:AssertDenyResult -Result $result

        $literal = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = @'
cat <<'EOF'
git commit -m literal-heredoc
EOF
'@ }
        $literal.OutputObject | Should -BeNullOrEmpty

        $dataOnlyPipeline = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = @'
cat <<'EOF' | bash -c 'cat >/dev/null'
git commit -m data-only-heredoc
EOF
'@ }
        $dataOnlyPipeline.OutputObject | Should -BeNullOrEmpty

        foreach ($executedPipeline in @(
                @'
cat <<'EOF' | env FOO=1 sh
git commit -m env-shell-heredoc
EOF
'@,
                @'
cat <<'EOF' | tee /dev/stderr | bash
git commit -m multihop-heredoc
EOF
'@,
                @'
cat <<'EOF' |& bash
git commit -m stderr-pipeline-heredoc
EOF
'@
            )) {
            $executed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $executedPipeline }
            & $script:AssertDenyResult -Result $executed
        }

        foreach ($dataPipeline in @(
                @'
cat <<'EOF' | tee note.txt
git commit -m tee-data-heredoc
EOF
'@,
                @'
cat <<'EOF' || bash
git commit -m logical-or-heredoc
EOF
'@,
                @'
cat <<'EOF' | bash script.sh
git commit -m script-file-data-heredoc
EOF
'@
            )) {
            $data = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $dataPipeline }
            $data.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C24 preserves outer Git environment targets in nested shell commands' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'nested-env-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetGitDir = Join-Path $target.RepoRoot '.git'
        $command = 'GIT_DIR="{0}" GIT_WORK_TREE="{1}" bash -c ''git commit -m nested-env-bypass''' -f $targetGitDir, $target.RepoRoot

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
        & $script:AssertDenyResult -Result $result

        $clearedCommand = 'GIT_DIR="{0}" GIT_WORK_TREE="{1}" bash -c ''env -u GIT_DIR -u GIT_WORK_TREE git commit -m nested-env-cleared''' -f $targetGitDir, $target.RepoRoot
        $cleared = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $clearedCommand }
        $cleared.OutputObject | Should -BeNullOrEmpty

        Set-GatePass -RepoRoot $target.RepoRoot -Branch $target.Branch
        $approved = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
        $approved.OutputObject | Should -BeNullOrEmpty

        $override = New-GateTargetRepo -Root $fixture.Root -Name 'nested-env-override'
        $overrideGitDir = Join-Path $override.RepoRoot '.git'
        $overriddenCommand = 'GIT_DIR="{0}" GIT_WORK_TREE="{1}" bash -c ''GIT_DIR="{2}" GIT_WORK_TREE="{3}" git commit -m nested-env-override''' -f $targetGitDir, $target.RepoRoot, $overrideGitDir, $override.RepoRoot
        $overridden = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $overriddenCommand }
        & $script:AssertDenyResult -Result $overridden

        $doubleNestedCommand = 'GIT_DIR="{0}" GIT_WORK_TREE="{1}" bash -c ''bash -c "git commit -m nested-env-double"''' -f $overrideGitDir, $override.RepoRoot
        $doubleNested = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $doubleNestedCommand }
        & $script:AssertDenyResult -Result $doubleNested

        $nonLeakingCommand = 'GIT_DIR="{0}" GIT_WORK_TREE="{1}" true; git commit -m adjacent-command-caller' -f $overrideGitDir, $override.RepoRoot
        $nonLeaking = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $nonLeakingCommand }
        $nonLeaking.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C25 preserves cwd from an executed branch across an inactive else' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'executed-branch-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $command = 'if true; then cd "{0}"; else :; fi; git commit -m executed-branch-bypass' -f $target.RepoRoot

        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
        & $script:AssertDenyResult -Result $result

        $inactiveThen = 'if false; then cd "{0}"; else :; fi; git commit -m inactive-then-caller' -f $target.RepoRoot
        $callerApproved = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $inactiveThen }
        $callerApproved.OutputObject | Should -BeNullOrEmpty

        $activeElse = 'if false; then :; else cd "{0}"; fi; git commit -m active-else-target' -f $target.RepoRoot
        $targetDenied = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $activeElse }
        & $script:AssertDenyResult -Result $targetDenied

        Set-GatePass -RepoRoot $target.RepoRoot -Branch $target.Branch
        $approved = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
        $approved.OutputObject | Should -BeNullOrEmpty

        $branchTarget = New-GateTargetRepo -Root $fixture.Root -Name 'branch-state-target'
        $matchedThen = 'if true; then :; elif true; then cd "{0}"; else cd "{0}"; fi; git commit -m matched-then-caller' -f $branchTarget.RepoRoot
        $matchedThenResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $matchedThen }
        $matchedThenResult.OutputObject | Should -BeNullOrEmpty

        $activeElif = 'if false; then :; elif true; then cd "{0}"; else :; fi; git commit -m active-elif-target' -f $branchTarget.RepoRoot
        $activeElifResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $activeElif }
        & $script:AssertDenyResult -Result $activeElifResult

        $inactiveWithoutElse = 'if false; then cd "{0}"; fi; git commit -m inactive-without-else-caller' -f $branchTarget.RepoRoot
        $inactiveWithoutElseResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $inactiveWithoutElse }
        $inactiveWithoutElseResult.OutputObject | Should -BeNullOrEmpty

        $unknownCondition = 'if test -d maybe; then cd "{0}"; fi; git commit -m unknown-condition-target' -f $branchTarget.RepoRoot
        $unknownConditionResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $unknownCondition }
        & $script:AssertDenyResult -Result $unknownConditionResult
    }

    It 'TASK-783 C26 denies executable heredoc bodies across multiple redirects and interpreter options' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $unexpectedAllowed = @()
        foreach ($command in @(
                "cat <<SAFE <<EXEC | bash`nharmless`nSAFE`ngit commit -m multi-heredoc`nEXEC",
                "cat <<SAFE | bash <<EXEC`nharmless`nSAFE`ngit commit -m split-heredoc`nEXEC",
                "cat <<EOF | bash -o pipefail`ngit commit -m bash-option`nEOF",
                "cat <<EOF | bash -O extglob`ngit commit -m bash-shopt-option`nEOF",
                "cat <<EOF | bash -s sentinel`ngit commit -m bash-stdin-option`nEOF",
                "cat <<EOF | bash --rcfile profile`ngit commit -m bash-rcfile-option`nEOF",
                "cat <<EOF | python -W ignore`ngit commit -m python-option`nEOF",
                "cat <<EOF | node --require fs`ngit commit -m node-option`nEOF",
                "cat <<EOF | pwsh -NoProfile`ngit commit -m powershell-option`nEOF"
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        foreach ($dataOnlyCommand in @(
                "cat <<FIRST <<SECOND`ngit commit -m literal-first`nFIRST`ngit commit -m literal-second`nSECOND",
                "cat <<EOF | bash script.sh`ngit commit -m bash-script-data`nEOF",
                "cat <<EOF | python script.py`ngit commit -m python-script-data`nEOF",
                "cat <<EOF | node script.js`ngit commit -m node-script-data`nEOF",
                "cat <<EOF | pwsh -File script.ps1`ngit commit -m powershell-script-data`nEOF"
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $dataOnlyCommand }
            $result.OutputObject | Should -BeNullOrEmpty -Because $command
        }
    }

    It 'TASK-783 C27 inspects lifecycle and Codex dispatches in shell control-flow executable positions' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'if true; then git commit -m control-flow-then; fi',
                'if false; then :; elif true; then git commit -m control-flow-elif; fi',
                'if false; then :; else git commit -m control-flow-else; fi',
                'for x in 1; do git commit -m control-flow-do; done',
                'if git commit -m control-flow-condition; then :; fi',
                'if true; then (git commit -m control-flow-group); fi',
                'if true; then codex exec review; fi',
                'if false; then :; elif true; then codex exec review; fi',
                'if false; then :; else codex exec review; fi',
                'for x in 1; do codex exec review; done',
                'if codex exec review; then :; fi',
                'if true; then (codex exec review); fi'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }
    }

    It 'TASK-783 C28 fails closed at nested dispatch and review-target recursion limits' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'deep-review-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        $nestedCodex = 'codex exec review'
        foreach ($unused in 1..8) {
            $nestedCodex = 'eval "{0}"' -f ($nestedCodex.Replace('\', '\\').Replace('"', '\"'))
        }
        $codexResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $nestedCodex }
        & $script:AssertDenyResult -Result $codexResult

        $nestedGit = 'git commit -m deep-review-target'
        foreach ($unused in 1..7) {
            $nestedGit = 'eval "{0}"' -f ($nestedGit.Replace('\', '\\').Replace('"', '\"'))
        }
        $targetGitDir = Join-Path $target.RepoRoot '.git'
        $targetCommand = 'GIT_DIR="{0}" GIT_WORK_TREE="{1}" {2}' -f $targetGitDir, $target.RepoRoot, $nestedGit
        $targetResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $targetCommand }
        & $script:AssertDenyResult -Result $targetResult
    }

    It 'TASK-783 C29 handles attached env unsets and compound branch conditions fail closed' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'attached-unset-target'
        $branchTarget = New-GateTargetRepo -Root $fixture.Root -Name 'compound-condition-target'
        Set-GatePass -RepoRoot $target.RepoRoot -Branch $target.Branch
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        foreach ($command in @(
                ('GIT_DIR="{0}" env -uGIT_DIR git commit -m attached-unset-git-dir' -f $targetGitDir),
                ('GIT_DIR="{0}" GIT_WORK_TREE="{1}" env -uGIT_DIR -uGIT_WORK_TREE git commit -m attached-unset-both' -f $targetGitDir, $target.RepoRoot)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        foreach ($command in @(
                ('if false || true; then cd "{0}"; fi; git commit -m compound-or-target' -f $branchTarget.RepoRoot),
                ('if false && true || true; then cd "{0}"; fi; git commit -m compound-chain-target' -f $branchTarget.RepoRoot),
                ('if false; then :; elif false || true; then cd "{0}"; fi; git commit -m compound-elif-target' -f $branchTarget.RepoRoot)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }
    }

    It 'TASK-783 C30 parses adjacent heredocs continued pipelines quotes and attached env options' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'attached-env-target'

        foreach ($command in @(
                "cat<<EOF | bash`ngit commit -m adjacent-heredoc`nEOF",
                "cat <<EOF \`n| bash`ngit commit -m continued-heredoc`nEOF",
                "cat2(){ cat; }; cat2<<EOF | bash`ngit commit -m digit-suffix-heredoc`nEOF",
                'printf "\\"; git commit -m even-backslash-quote',
                'printf "\\"; codex exec review',
                'echo \\\\`codex exec review`',
                "env -S'git commit -m attached-split'",
                "env -S'codex exec review'",
                'printf ''codex\n'' | xargs -I{} sh -c ''$0 exec'' {}'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $attachedChdir = 'env -C"{0}" git commit -m attached-chdir' -f $target.RepoRoot
        $attachedChdirResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $attachedChdir }
        & $script:AssertDenyResult -Result $attachedChdirResult

        foreach ($dataOnly in @(
                "cat<<EOF`ngit commit -m literal-adjacent`nEOF",
                "bash 3<<EOF`ngit commit -m fd-three-data`nEOF",
                "bash script.sh <<EOF`ngit commit -m script-data`nEOF",
                "cat <<EOF | bash -x script.sh`ngit commit -m option-script-data`nEOF",
                "env -S'printf harmless'",
                "printf 'codex exec\n' | xargs echo",
                'echo \`codex exec review\`'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $dataOnly }
            $result.OutputObject | Should -BeNullOrEmpty -Because $command
        }
    }

    It 'TASK-783 C31 applies the review-only mutator table to wrappers and aliases' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'xargs git push',
                'xargs git update-ref refs/heads/x HEAD',
                'xargs git branch new-branch',
                'xargs git tag release-candidate',
                'f(){ git "$@"; }; f push',
                'f(){ git "$@"; }; f update-ref refs/heads/x HEAD',
                "shopt -s expand_aliases`nalias g=git`ng push",
                'Set-Alias g git; g push'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($readOnly in @(
                'xargs git branch --list',
                'xargs git tag --list',
                "shopt -s expand_aliases`nalias g=git`ng status",
                'Set-Alias g git; g status'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $readOnly }
            $result.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C32 resolves or fails closed on command-local Git alias configuration' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        foreach ($command in @(
                'git -c alias.x=push x',
                'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.x GIT_CONFIG_VALUE_0=push git x',
                'ALIAS_VALUE=push git --config-env=alias.x=ALIAS_VALUE x'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($readOnly in @(
                'git -c alias.x=status x --short',
                'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.x GIT_CONFIG_VALUE_0=status git x --short',
                'ALIAS_VALUE=status git --config-env=alias.x=ALIAS_VALUE x --short'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $readOnly }
            $result.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C33 fails closed on persistent Git environment mutations' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'persistent-env-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetGitDir = Join-Path $target.RepoRoot '.git'

        foreach ($command in @(
                ('export GIT_DIR="{0}"; git commit -m export-target' -f $targetGitDir),
                ('export "GIT_DIR={0}"; git commit -m quoted-export-target' -f $targetGitDir),
                ('$env:GIT_DIR="{0}"; git commit -m powershell-env-target' -f $targetGitDir),
                ('Set-Item Env:GIT_DIR "{0}"; git commit -m set-item-target' -f $targetGitDir)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        $nonGitEnvironment = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = 'export FOO=1; git commit -m caller-approved' }
        $nonGitEnvironment.OutputObject | Should -BeNullOrEmpty

        $secondFixture = New-GateFixture
        $secondTarget = New-GateTargetRepo -Root $secondFixture.Root -Name 'persistent-unset-target'
        Set-GatePass -RepoRoot $secondTarget.RepoRoot -Branch $secondTarget.Branch
        $secondGitDir = Join-Path $secondTarget.RepoRoot '.git'
        foreach ($command in @(
                ('GIT_DIR="{0}" bash -c ''unset -v GIT_DIR; git commit -m unset-target''' -f $secondGitDir),
                ('GIT_DIR="{0}" pwsh -Command ''$env:GIT_DIR=$null; git commit -m clear-target''' -f $secondGitDir)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $secondFixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }
    }

    It 'TASK-783 C34 fails closed on child-process target metadata' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'child-metadata-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        foreach ($command in @(
                ('node -e "require(''child_process'').execSync(''git commit -m node-cwd'', {{cwd: ''{0}''}})"' -f $target.RepoRoot),
                ('node -e "require(''child_process'').execFileSync(''git'', [''commit'',''-m'',''node-env''], {{env: {{GIT_DIR: ''{0}''}}}})"' -f (Join-Path $target.RepoRoot '.git')),
                ('python -c "import subprocess; subprocess.run([''git'',''commit'',''-m'',''python-cwd''], cwd=''{0}'')"' -f $target.RepoRoot),
                ('pwsh -Command "Start-Process git -ArgumentList commit -Environment @{{GIT_DIR=''{0}''}}"' -f (Join-Path $target.RepoRoot '.git')),
                ('pwsh -Command "start git -ArgumentList commit -Envir @{{GIT_DIR=''{0}''}}"' -f (Join-Path $target.RepoRoot '.git'))
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        $plainChild = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = 'node -e "require(''child_process'').execSync(''git commit -m caller-approved'')"' }
        $plainChild.OutputObject | Should -BeNullOrEmpty -Because 'a literal child process without target-changing metadata uses the caller repository PASS'
    }

    It 'TASK-783 C35 recognizes executable heredocs behind compound shell consumers' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                "cat <<'EOF' | { bash; }`ngit commit -m heredoc-brace`nEOF",
                "f(){ bash; }; cat <<'EOF' | f`ngit commit -m heredoc-function`nEOF",
                "cat <<'EOF' > >(bash)`ngit commit -m heredoc-process-substitution`nEOF",
                "if true; then bash <<'EOF'`ngit commit -m heredoc-if`nEOF`nfi",
                "! bash <<'EOF'`ngit commit -m heredoc-negated`nEOF"
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($dataOnly in @(
                "cat <<'EOF'`ngit commit -m literal-only`nEOF",
                "bash script.sh <<'EOF'`ngit commit -m script-input`nEOF"
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $dataOnly }
            $result.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C36 preserves ANSI-C quote boundaries around following commands' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                "printf `$'foo\''; git commit -m ansi-quote",
                "printf `$'foo\''; codex exec review"
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        $literal = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = "printf `$'git commit -m literal-only\n'"
        }
        $literal.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C37 unwraps executable negation coprocess and case branches' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                '! git commit -m negated',
                '! codex exec review',
                'coproc git commit -m coprocess',
                'case x in x) git commit -m case-branch;; esac'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($readOnly in @(
                '! git status --short',
                'coproc git branch --list',
                'case x in x) git tag --list;; esac'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $readOnly }
            $result.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C38 parses clustered GNU env short options without losing split payloads' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                "env -iS'/usr/bin/git commit -m env-cluster'",
                "env -iS'/usr/bin/codex exec review'"
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        $readOnly = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = "env -iS'/usr/bin/git status --short'"
        }
        $readOnly.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C39 fails closed when xargs supplies a lifecycle subcommand dynamically' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'cat args.txt | xargs git',
                'cat args.txt | xargs env git',
                'cat args.txt | xargs sh -c ''git "$@"'' sentinel',
                'cat args.txt | xargs gh'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($readOnly in @(
                'xargs git status --short',
                'xargs git branch --list',
                'xargs git tag --list',
                'xargs echo harmless'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $readOnly }
            $result.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C40 recursively expands Bash aliases after a trailing blank' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $mutating = "shopt -s expand_aliases`nalias g='git '`nalias c=commit`ng c -m recursive-alias"
        $mutatingResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $mutating }
        & $script:AssertDenyResult -Result $mutatingResult

        $readOnly = "shopt -s expand_aliases`nalias g='git '`nalias s=status`ng s --short"
        $readOnlyResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $readOnly }
        $readOnlyResult.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C41 fails closed when configured Git alias recursion exceeds the parser limit' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        & git -C $fixture.RepoRoot config alias.cm commit
        & git -C $fixture.RepoRoot config alias.st status

        $nestedMutating = 'git cm -m deep-alias'
        foreach ($unused in 1..6) {
            $nestedMutating = 'eval "{0}"' -f ($nestedMutating.Replace('\', '\\').Replace('"', '\"'))
        }

        $mutatingResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $nestedMutating }
        & $script:AssertDenyResult -Result $mutatingResult

        $readOnlyResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = 'git st --short' }
        $readOnlyResult.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C42 fails closed on persistent Git environment provider and export-state mutations' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'persistent-env-sibling-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetGitDir = (Join-Path $target.RepoRoot '.git').Replace('\', '/')

        foreach ($command in @(
                ('pwsh -NoProfile -Command ''si Env:GIT_DIR "{0}"; git commit -m ps-alias-env''' -f $targetGitDir),
                ('pwsh -NoProfile -Command ''New-Item Env:GIT_DIR -Value "{0}"; git commit -m ps-new-env''' -f $targetGitDir),
                ('bash -c ''declare -x GIT_DIR="{0}"; git commit -m declare-env''' -f $targetGitDir),
                ('bash -c ''export GIT_DIR; GIT_DIR="{0}"; git commit -m export-attribute-env''' -f $targetGitDir)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'export FOO=1; git commit -m non-git-env',
                'pwsh -NoProfile -Command ''si Env:FOO 1; git commit -m non-git-provider-env'''
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }

        Set-GatePass -RepoRoot $target.RepoRoot -Branch $target.Branch
        Set-GateReviewState -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch -Entry ([ordered]@{
            status   = 'PENDING'
            head_sha = Get-GateFixtureHeadSha -RepoRoot $fixture.RepoRoot
        }) | Out-Null
        $unexport = 'GIT_DIR="{0}" bash -c ''export -n GIT_DIR; git commit -m unexport-env''' -f $targetGitDir
        $unexportResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $unexport }
        & $script:AssertDenyResult -Result $unexportResult
    }

    It 'TASK-783 C43 fails closed on quoted shorthand spread and dictionary child-process options' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'child-options-sibling-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetPath = $target.RepoRoot.Replace('\', '/')

        foreach ($command in @(
                ('node -e "require(''child_process'').execSync(''git commit -m quoted-cwd'', {{''cwd'':''{0}''}})"' -f $targetPath),
                ('node -e "const cwd=''''{0}''''; require(''child_process'').execSync(''git commit -m shorthand-cwd'', {{cwd}})"' -f $targetPath),
                ('node -e "const options={{cwd:''{0}''}}; require(''child_process'').execSync(''git commit -m spread-cwd'', {{...options}})"' -f $targetPath),
                ('node -e "const options={{cwd:''{0}''}}; require(''child_process'').execSync(''git commit -m dynamic-cwd'', options)"' -f $targetPath),
                ('python -c "import subprocess; subprocess.run([''git'',''commit'',''-m'',''dict-cwd''], **{{''cwd'':r''{0}''}})"' -f $targetPath),
                'python -c "import subprocess; options={''cwd'':''C:/dynamic''}; subprocess.run([''git'',''commit'',''-m'',''dynamic-dict''], **options)"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'node -e "require(''child_process'').execSync(''git commit -m no-options'')"',
                'node -e "require(''child_process'').execSync(''git commit -m safe-options'', {encoding:''utf8'',stdio:''inherit''})"',
                'python -c "import subprocess; subprocess.run([''git'',''commit'',''-m'',''safe-options''], check=True, text=True)"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C44 recognizes stdin device paths and source consumers for executable heredocs' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                "cat <<'EOF' | bash /dev/stdin`ngit commit -m bash-dev-stdin`nEOF",
                "cat <<'EOF' | source /dev/stdin`ngit commit -m source-dev-stdin`nEOF",
                "cat <<'EOF' | . /dev/fd/0`ngit commit -m dot-dev-fd`nEOF",
                "cat <<'EOF' | python /proc/self/fd/0`ngit commit -m python-proc-fd`nEOF"
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($dataOnly in @(
                "cat <<'EOF' | bash script.sh`ngit commit -m shell-script-data`nEOF",
                "cat <<'EOF' | bash -c 'cat >/dev/null'`ngit commit -m shell-command-data`nEOF",
                "cat <<'EOF' | python script.py`ngit commit -m python-script-data`nEOF"
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $dataOnly }
            $allowed.OutputObject | Should -BeNullOrEmpty -Because $allowedCommand
        }
    }

    It 'TASK-783 C45 normalizes equivalent stdin device paths before classifying heredoc consumers' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                "cat <<'EOF' | bash /dev/fd/./0`ngit commit -m dot-fd-stdin`nEOF",
                "cat <<'EOF' | bash /dev/fd/00`ngit commit -m padded-fd-stdin`nEOF",
                "cat <<'EOF' | bash /proc/self/fd/./0`ngit commit -m proc-dot-fd-stdin`nEOF"
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        $scriptFile = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = "cat <<'EOF' | bash script.sh`ngit commit -m script-data`nEOF" }
        $scriptFile.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C46 fails closed on runtime Git environment mutations before child lifecycle commands' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'runtime-env-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetGitDir = (Join-Path $target.RepoRoot '.git').Replace('\', '/')

        foreach ($command in @(
                ('pwsh -Command "[System.Environment]::SetEnvironmentVariable(''GIT_DIR'',''{0}'',''Process''); git commit -m system-env"' -f $targetGitDir),
                ('pwsh -Command "[Environment] :: SetEnvironmentVariable(''GIT_DIR'',''{0}'',''Process''); git commit -m spaced-env"' -f $targetGitDir),
                ('node -e "process.env.GIT_DIR=''{0}''; require(''child_process'').execSync(''git commit -m node-runtime-env'')"' -f $targetGitDir),
                ('python -c "import os,subprocess; os.environ[''GIT_DIR'']=r''{0}''; subprocess.run([''git'',''commit'',''-m'',''python-runtime-env''])"' -f $targetGitDir)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'node -e "process.env.FOO=''1''; require(''child_process'').execSync(''git commit -m non-git-env'')"',
                'python -c "import os,subprocess; os.environ[''FOO'']=''1''; subprocess.run([''git'',''commit'',''-m'',''non-git-env''])"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty -Because $allowedCommand
        }
    }

    It 'TASK-783 C47 rejects unresolved Node child-process options expressions' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'dynamic-options-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetPath = $target.RepoRoot.Replace('\', '/')

        foreach ($command in @(
                ('node -e "require(''child_process'').execSync(''git commit -m assigned-options'', Object.assign({{}}, {{cwd:''{0}''}}))"' -f $targetPath),
                ('node -e "const getOptions=()=>({{cwd:''{0}''}}); require(''child_process'').execSync(''git commit -m call-options'', getOptions())"' -f $targetPath)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        $safe = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = 'node -e "require(''child_process'').execSync(''git commit -m safe-options'', {encoding:''utf8''})"' }
        $safe.OutputObject | Should -BeNullOrEmpty -Because 'literal encoding options do not change the reviewed repository target'
    }

    It 'TASK-783 C48 keeps comment delimiters from terminating child-process call parsing' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'comment-options-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetPath = $target.RepoRoot.Replace('\', '/')

        $nodeCommand = 'node -e "require(''child_process'').execSync(''git commit -m node-comment'', /* ) */ {{cwd:''{0}''}})"' -f $targetPath
        $nodeResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $nodeCommand }
        & $script:AssertDenyResult -Result $nodeResult

        $pythonCommand = @"
python -c "import subprocess; subprocess.run(['git','commit','-m','python-comment'], # )
 cwd=r'$targetPath')"
"@
        $pythonResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $pythonCommand }
        & $script:AssertDenyResult -Result $pythonResult
    }

    It 'TASK-783 C49 rejects positional Popen cwd and env targets' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'popen-positional-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetPath = $target.RepoRoot.Replace('\', '/')

        foreach ($command in @(
                ('python -c "import subprocess; subprocess.Popen([''git'',''commit'',''-m'',''popen-cwd''],-1,None,None,None,None,None,True,False,r''{0}'')"' -f $targetPath),
                'python -c "import subprocess; subprocess.Popen([''git'',''commit'',''-m'',''popen-env''],-1,None,None,None,None,None,True,False,None,{''GIT_DIR'':''C:/target/.git''})"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        $safe = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = 'python -c "import subprocess; subprocess.Popen([''git'',''commit'',''-m'',''popen-default''])"' }
        $safe.OutputObject | Should -BeNullOrEmpty -Because 'Popen defaults do not change the reviewed repository target'
    }

    It 'TASK-783 C50 resolves or fails closed on shell variable lifecycle executables' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'g=git; "$g" commit -m shell-variable',
                'g=git; ${g} commit -m shell-braced-variable',
                'tool=$UNKNOWN; "$tool" commit -m unresolved-variable',
                'c=codex; "$c" exec review',
                'readonly g=git; command "$g" commit -m readonly-variable',
                'G=git sh -c ''$G commit -m inherited-variable''',
                'g=/usr/bin/git; "$g" commit -m path-variable',
                'g=git; eval "$g commit -m eval-variable"',
                'h=gh; "$h" pr merge 1200',
                'h=gh; "$h" api -X PATCH repos/example/winsmux/git/refs/heads/main',
                'cmd=(git commit -m array-variable); "${cmd[@]}"',
                'cmd=(codex exec review); "${cmd[@]}"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'g=git; "$g" status',
                'g=git; printf "%s" "$g commit"',
                'cmd=(git branch --list); "${cmd[@]}"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty -Because $allowedCommand
        }
    }

    It 'TASK-783 C51 tracks stdin device symlink aliases used by heredoc consumers' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $linkOneNative = Join-Path $fixture.Root 'stdin-link-one'
        $linkTwoNative = Join-Path $fixture.Root 'stdin-link-two'
        $linkOne = $linkOneNative.Replace('\', '/')
        $linkTwo = $linkTwoNative.Replace('\', '/')

        foreach ($command in @(
                ("ln -sf /dev/fd/0 '$linkOne'; cat <<'EOF' | bash '$linkOne'`ngit commit -m symlink-stdin`nEOF"),
                ("ln -sf /proc/self/fd/0 '$linkOne'; ln -sf '$linkOne' '$linkTwo'; cat <<'EOF' | python '$linkTwo'`ngit commit -m chained-symlink-stdin`nEOF")
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        $magic = [System.Text.Encoding]::ASCII.GetBytes('!<symlink>')
        $bom = [byte[]](0xff, 0xfe)
        $stdinTarget = [System.Text.Encoding]::Unicode.GetBytes("/dev/fd/0$([char]0)")
        [System.IO.File]::WriteAllBytes($linkOneNative, [byte[]]($magic + $bom + $stdinTarget))
        $relativeTarget = [System.Text.Encoding]::Unicode.GetBytes("stdin-link-one$([char]0)")
        [System.IO.File]::WriteAllBytes($linkTwoNative, [byte[]]($magic + $bom + $relativeTarget))
        foreach ($existingLink in @($linkOne, $linkTwo)) {
            $existingCommand = "cat <<'EOF' | bash '$existingLink'`ngit commit -m existing-symlink-stdin`nEOF"
            $existingResult = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $existingCommand }
            & $script:AssertDenyResult -Result $existingResult
        }

        $regularLink = (Join-Path $fixture.Root 'regular-script-link').Replace('\', '/')
        $regularScript = "ln -sf script.sh '$regularLink'; cat <<'EOF' | bash '$regularLink'`ngit commit -m regular-script-data`nEOF"
        $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $regularScript }
        $allowed.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C52 fails closed on additional runtime Git environment mutation APIs' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'runtime-env-api-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetGitDir = (Join-Path $target.RepoRoot '.git').Replace('\', '/')

        foreach ($command in @(
                ('node -e "Object.assign(process.env,{{GIT_DIR:''{0}''}}); require(''child_process'').execSync(''git commit -m object-assign-env'')"' -f $targetGitDir),
                ('node -e "Reflect.set(process.env,''GIT_DIR'',''{0}''); require(''child_process'').execSync(''git commit -m reflect-env'')"' -f $targetGitDir),
                ('node -e "Object.defineProperty(process.env,''GIT_DIR'',{{value:''{0}'',configurable:true,enumerable:true,writable:true}}); require(''child_process'').execSync(''git commit -m define-property-env'')"' -f $targetGitDir),
                ('GIT_DIR=''{0}'' node -e "Reflect.deleteProperty(process.env,''GIT_DIR''); require(''child_process'').execSync(''git commit -m reflect-delete-env'')"' -f $targetGitDir),
                ('node -e "process.env={{...process.env,GIT_DIR:''{0}''}}; require(''child_process'').execSync(''git commit -m replace-env-object'')"' -f $targetGitDir),
                ('python -c "import os,subprocess; os.environ.update({{''GIT_DIR'':r''{0}''}}); subprocess.run([''git'',''commit'',''-m'',''update-env''])"' -f $targetGitDir),
                ('python -c "import os,subprocess; os.environ.setdefault(''GIT_DIR'',r''{0}''); subprocess.run([''git'',''commit'',''-m'',''setdefault-env''])"' -f $targetGitDir),
                ('GIT_DIR=''{0}'' python -c "import os,subprocess; os.environ.pop(''GIT_DIR'',None); subprocess.run([''git'',''commit'',''-m'',''pop-env''])"' -f $targetGitDir),
                ('GIT_DIR=''{0}'' python -c "import os,subprocess; os.unsetenv(''GIT_DIR''); subprocess.run([''git'',''commit'',''-m'',''unset-env''])"' -f $targetGitDir)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'node -e "Object.assign(process.env,{FOO:''1''}); require(''child_process'').execSync(''git commit -m safe-object-assign'')"',
                'python -c "import os,subprocess; os.environ.update({''FOO'':''1''}); subprocess.run([''git'',''commit'',''-m'',''safe-update''])"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty -Because $allowedCommand
        }
    }

    It 'TASK-783 C53 preserves JavaScript regex literals while parsing child options' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'regex-options-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetPath = $target.RepoRoot.Replace('\', '/')

        foreach ($command in @(
                ('node -e "require(''child_process'').execSync(''git commit -m regex-close'', {{marker:/\)/,cwd:''{0}''}})"' -f $targetPath),
                ('node -e "require(''child_process'').execSync(''git commit -m regex-class'', {{marker:/[,)]\//,cwd:''{0}''}})"' -f $targetPath)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        $safe = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'node -e "require(''child_process'').execSync(''git commit -m safe-regex'', {marker:/[,)]/,encoding:''utf8''})"'
        }
        $safe.OutputObject | Should -BeNullOrEmpty -Because 'a regex-valued non-target option does not change the reviewed repository target'
    }

    It 'TASK-783 C54 rejects dynamic Git subcommands in Node and Python child processes' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'node -e "require(''child_process'').spawnSync(''git'', [''com''+''mit'',''-m'',''node-dynamic-subcommand''])"',
                'python -c "import subprocess; subprocess.run([''git'',''''.join([''com'',''mit'']),''-m'',''python-dynamic-subcommand''])"',
                'node -e "const action=''status''; require(''child_process'').execFileSync(''git'', [action])"',
                'node -e "const action=''status''; require(''child_process'').spawnSync(''/usr/bin/git'', [...[action]])"',
                'node -e "const action=''status''; require(''child_process'').execSync(`git ${action}`)"',
                'python -c "import subprocess as sp; action=''status''; sp.run([''git'',action])"',
                'python -c "import os; action=''status''; os.system(''git ''+action)"',
                'node -e "require(''child_process'').spawnSync(''gh'', [''pr'',''mer''+''ge'',''1200''])"',
                'python -c "import subprocess; subprocess.run([''gh'',''pr'',''''.join([''mer'',''ge'']),''1200''])"',
                'node -e "const leaf=''merge''; require(''child_process'').spawnSync(''gh'', [''api'',''-X'',''PUT'',`repos/x/y/pulls/1200/${leaf}`])"',
                'node -e "const ref=''refs/heads/main''; require(''child_process'').spawnSync(''gh'', [''api'',''-X'',''PATCH'',`repos/x/y/git/${ref}`])"',
                'node -e "const action=''merge''; require(''child_process'').execSync(`gh pr ${action} 1200`)"',
                'python -c "import os; action=''merge''; os.system(''gh pr ''+action+'' 1200'')"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        foreach ($allowedCommand in @(
                'node -e "require(''child_process'').spawnSync(''git'', [''status''])"',
                'python -c "import subprocess; subprocess.run([''git'',''branch'',''--list''])"',
                'node -e "require(''child_process'').spawnSync(''gh'', [''pr'',''view'',''1200''])"',
                'node -e "const id=''1200''; require(''child_process'').spawnSync(''gh'', [''issue'',''view'',id])"',
                'python -c "import subprocess; subprocess.run([''gh'',''api'',''--method'',''GET'',''repos/x/y''])"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C55 fails closed on dynamic PowerShell Git environment names' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'dynamic-powershell-env-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetGitDir = (Join-Path $target.RepoRoot '.git').Replace('\', '/')

        foreach ($command in @(
                ('pwsh -Command "$names=@(''GIT_DIR'',''GIT_WORK_TREE''); Set-Item (''Env:''+$names[0]) ''{0}''; git commit -m dynamic-provider-env"' -f $targetGitDir),
                ('pwsh -Command "$name=''GIT_DIR''; [Environment]::SetEnvironmentVariable($name,''{0}'',''Process''); git commit -m dynamic-dotnet-env"' -f $targetGitDir),
                ('GIT_DIR=''{0}'' pwsh -Command "$names=@(''GIT_DIR''); Remove-Item (''Env:''+$names[0]); git commit -m dynamic-remove-env"' -f $targetGitDir)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        $safe = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'pwsh -Command "$name=''FOO''; Set-Item (''Env:''+$name) ''1''; git commit -m safe-dynamic-env"'
        }
        $safe.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C56 inspects executable heredocs supplied on nonzero file descriptors' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                "bash /dev/fd/3 3<<'EOF'`ngit commit -m fd-three`nEOF",
                "python /proc/self/fd/04 4<<'EOF'`ngit commit -m fd-four`nEOF",
                "source /dev/fd/5 5<<'EOF'`ngit commit -m fd-five`nEOF",
                "bash /dev/fd/4 3<<'EOF' 4<&3`ngit commit -m duplicated-fd`nEOF",
                "exec 6<<'EOF'`ngit commit -m persistent-fd`nEOF"
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                "cat /dev/fd/3 3<<'EOF'`ngit commit -m data-only-fd`nEOF",
                "bash script.sh 3<<'EOF'`ngit commit -m script-file-fd`nEOF",
                "bash /dev/fd/4 3<<'EOF'`ngit commit -m mismatched-fd`nEOF"
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C57 fails closed on aliased and computed child-process callees' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'aliased-child-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetPath = $target.RepoRoot.Replace('\', '/')

        foreach ($command in @(
                'node -e "require(''child_process'')[''spawnSync''](''git'', [''com''+''mit'',''-m'',''computed-callee''])"',
                'node -e "const {spawnSync:s}=require(''child_process''); s(''git'', [''com''+''mit'',''-m'',''destructured-alias''])"',
                'node -e "const cp=require(''child_process''); cp[''spawnSync''](''git'', [''com''+''mit'',''-m'',''member-computed''])"',
                'node -e "const s=require(''child_process'').spawnSync; s(''git'', [''com''+''mit'',''-m'',''assigned-alias''])"',
                'node -e "const cp=require(''node:child_process''); cp[''spawnSync''](''git'', [''com''+''mit'',''-m'',''node-prefix-computed''])"',
                'node -e "const {spawnSync:s}=require(''child_process''); s(''codex'', [''exec'',''review''])"',
                ('node -e "const cp=require(''child_process''); cp[''spawnSync''](''git'', [''commit'',''-m'',''computed-cwd''], {{cwd:''{0}''}})"' -f $targetPath),
                'python -c "import subprocess; getattr(subprocess,''run'')([''git'',''''.join([''com'',''mit'']),''-m'',''getattr-callee''])"',
                'python -c "from subprocess import run as r; r([''git'',''''.join([''com'',''mit'']),''-m'',''import-alias''])"',
                'python -c "import subprocess; r=subprocess.run; r([''git'',''''.join([''com'',''mit'']),''-m'',''assigned-alias''])"',
                'python -c "from subprocess import run as r; r([''codex'',''exec'',''review''])"',
                ('python -c "from subprocess import run as r; r([''git'',''commit'',''-m'',''alias-cwd''], cwd=r''{0}'')"' -f $targetPath)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        foreach ($allowedCommand in @(
                'node -e "require(''child_process'')[''spawnSync''](''git'', [''status''])"',
                'node -e "const {spawnSync:s}=require(''child_process''); s(''gh'', [''issue'',''view'',''1200''])"',
                'python -c "from subprocess import run as r; r([''git'',''branch'',''--list''])"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty -Because $allowedCommand
        }
    }

    It 'TASK-783 C58 rejects constructed runtime Git environment names' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'constructed-env-name-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetGitDir = (Join-Path $target.RepoRoot '.git').Replace('\', '/')

        foreach ($command in @(
                ('node -e "const k=''GIT_''+''DIR''; process.env[k]=''{0}''; require(''child_process'').execSync(''git commit -m constructed-node-env'')"' -f $targetGitDir),
                ('node -e "const k=[''GIT'',''DIR''].join(''_''); Object.assign(process.env,{{[k]:''{0}''}}); require(''child_process'').execSync(''git commit -m constructed-object-env'')"' -f $targetGitDir),
                ('python -c "import os,subprocess; k=''GIT_''+''DIR''; os.environ[k]=r''{0}''; subprocess.run([''git'',''commit'',''-m'',''constructed-python-env''])"' -f $targetGitDir),
                ('pwsh -Command "$k=''GIT_''+''DIR''; Set-Item (''Env:''+$k) ''{0}''; git commit -m constructed-provider-env"' -f $targetGitDir),
                ('pwsh -Command "$k=''GIT_''+''DIR''; [Environment]::SetEnvironmentVariable($k,''{0}'',''Process''); git commit -m constructed-dotnet-env"' -f $targetGitDir)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'node -e "const k=''FO''+''O''; process.env[k]=''1''; require(''child_process'').execSync(''git status --short'')"',
                'python -c "import os,subprocess; k=''FO''+''O''; os.environ[k]=''1''; subprocess.run([''git'',''status'',''--short''])"',
                'pwsh -Command "$k=''FO''+''O''; Set-Item (''Env:''+$k) ''1''; git commit -m safe-constructed-provider-env"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C59 rejects dynamic Windows lifecycle wrappers' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'cmd /v:on /c "set g=git&&call !g! com^mit --allow-empty -m delayed-expansion"',
                'cmd /c "set g=git&&call %g% com^mit --allow-empty -m percent-expansion"',
                'cmd /v:on /c "set h=gh&&call !h! pr merge 1200"',
                'pwsh -Command ''saps $env:ComSpec -ArgumentList @("/c","call","git","commit","--allow-empty","-m","saps-cmd") -Wait''',
                'pwsh -Command ''Start-Process $env:ComSpec -ArgumentList @("/v:on","/c","set g=git&&call !g! commit -m start-cmd") -Wait''',
                'pwsh -Command ''saps $env:ComSpec -ArgumentList @("/c","call","codex","exec","review") -Wait'''
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'cmd /v:on /c "set g=git&&call !g! status --short"',
                'pwsh -Command ''saps git -ArgumentList @("status","--short") -Wait''',
                'pwsh -Command ''saps $env:ComSpec -ArgumentList @("/c","echo","git commit is text") -Wait'''
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C60 resolves transitive and computed child-process provenance' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'node -e "const cp=require(''child_process''); const s=cp.spawnSync; const t=s; t(''git'', [''commit'',''-m'',''transitive-node''])"',
                'node -e "const cp=require(''child_process''); const s=cp[''spawn''+''Sync'']; s(''git'', [''commit'',''-m'',''computed-method''])"',
                'node --input-type=module -e "const cp=await import(''node:child_process''); const s=cp.spawnSync; const t=s; t(''git'', [''commit'',''-m'',''dynamic-import''])"',
                'node -e "const cp=require(''child_process''); const s=cp.spawnSync; const t=s; t(''codex'', [''exec'',''review''])"',
                'python -c "from subprocess import PIPE, run as r; r([''git'',''commit'',''-m'',''multi-import''])"',
                'python -c "import subprocess; r=subprocess.run; q=r; q([''git'',''commit'',''-m'',''transitive-python''])"',
                'python -c "from subprocess import PIPE, run as r; r([''codex'',''exec'',''review''])"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'node -e "function exec(x){return x}; exec(''git commit is text'')"',
                'node -e "const cp=require(''child_process''); const s=cp.spawnSync; const t=s; t(''git'', [''status''])"',
                'python -c "from subprocess import PIPE, run as r; r([''git'',''branch'',''--list''])"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty -Because $allowedCommand
        }
    }

    It 'TASK-783 C61 evaluates generalized constructed Git environment names' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'generalized-env-name-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetGitDir = (Join-Path $target.RepoRoot '.git').Replace('\', '/')
        $targetPath = $target.RepoRoot.Replace('\', '/')

        foreach ($command in @(
                ('python -c "import os,subprocess; k=''''.join([''GIT_'',''DIR'']); os.environ[k]=r''{0}''; subprocess.run([''git'',''commit'',''-m'',''python-join-dir''])"' -f $targetGitDir),
                ('python -c "import os,subprocess; k=''''.join([''GIT_'',''WORK_TREE'']); os.environ[k]=r''{0}''; subprocess.run([''git'',''commit'',''-m'',''python-join-worktree''])"' -f $targetPath),
                ('node -e "const k=''GI''+''T_DIR''; process.env[k]=''{0}''; require(''child_process'').execSync(''git commit -m split-prefix-env'')"' -f $targetGitDir),
                ('pwsh -Command "$k=[string]::Concat(''GI'',''T_DIR''); Set-Item (''Env:''+$k) ''{0}''; git commit -m concat-env"' -f $targetGitDir)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'python -c "import os,subprocess; k=''''.join([''F'',''OO'']); os.environ[k]=''1''; subprocess.run([''git'',''status'',''--short''])"',
                'node -e "const k=''F''+''OO''; process.env[k]=''1''; require(''child_process'').execSync(''git status --short'')"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C62 resolves or fails closed on cmd variable lifecycle executables' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'cmd /c call %GIT_EXE% com^mit -m external-percent',
                'cmd /v:on /c "set c=codex&&call !c! exec review"',
                'cmd /v:on /c "set a=gi&&set b=t&&call !a!!b! commit -m fragments"',
                'cmd /v:on /c "set x=xgitx&&call !x:~1,3! commit -m substring"',
                'cmd /v:on /c "set a=g&&set b=h&&call !a!!b! pr merge 1200"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'cmd /c call %READ_TOOL% status --short',
                'cmd /v:on /c "set a=gi&&set b=t&&call !a!!b! status --short"',
                'cmd /v:on /c "echo set a=gi&&echo !a! commit is text"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C63 normalizes braced ComSpec Start-Process wrappers' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'pwsh -Command ''saps ${env:ComSpec} -ArgumentList @("/c","git","commit","-m","braced-comspec") -Wait''',
                'pwsh -Command ''Start-Process ${env:ComSpec} -ArgumentList @("/c","call","codex","exec","review") -Wait'''
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'pwsh -Command ''saps ${env:ComSpec} -ArgumentList @("/c","git","status","--short") -Wait''',
                'pwsh -Command ''saps ${env:ComSpec} -ArgumentList @("/c","echo","git commit is text") -Wait'''
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C64 preserves child-callee provenance without reassignment false positives' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'node -e "const cp=require(''child_process''); let s; s=cp.spawnSync; s(''git'', [''commit'',''-m'',''late-assignment''])"',
                'node -e "const cp=require(''child_process''); cp?.spawnSync(''git'', [''commit'',''-m'',''optional-chain''])"',
                'node -e "const cp=require(''child_process''); const {spawnSync:s}=cp; s(''git'', [''commit'',''-m'',''object-destructure''])"',
                'node -e "const cp=require(''child_process''); const s=cp.spawnSync.bind(cp); s(''git'', [''commit'',''-m'',''bound-callee''])"',
                'node --input-type=module -e "import cp from ''node:child_process''; cp.spawnSync(''git'', [''commit'',''-m'',''esm-default''])"',
                'node -e "const cp=require(''child_process''); const m=''spawnSync''; cp[m](''git'', [''commit'',''-m'',''computed-variable''])"',
                'node -e "const cp=require(''child_process''); let s; s=cp.spawnSync; const tool=''codex''; s(tool, [''exec'',''review''])"',
                'python -c "import subprocess; r,unused=subprocess.run,None; r([''git'',''commit'',''-m'',''tuple-alias''])"',
                'python -c "import subprocess; m=''run''; getattr(subprocess,m)([''git'',''commit'',''-m'',''computed-getattr''])"',
                'python -c "import os as o; o.system(''git commit -m os-object-alias'')"',
                'python -c "from os import system as s; s(''git commit -m os-function-alias'')"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'node -e "require(''child_process'').spawnSync(''git'', [''status''])"',
                'node -e "const cp=require(''child_process''); let s; s=cp.spawnSync; s(''git'', [''status''])"',
                'python -c "import os as o; o.system(''git status'')"',
                'node -e "function exec(x){return x}; exec(''git commit is text'')"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty -Because $allowedCommand
        }
    }

    It 'TASK-783 C65 tracks constructed Git environment names through sink aliases and provider paths' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'sink-alias-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetGitDir = (Join-Path $target.RepoRoot '.git').Replace('\', '/')
        $targetPath = $target.RepoRoot.Replace('\', '/')

        foreach ($command in @(
                ('python -c "import os,subprocess; k=''GI''+''T_DIR''; os.environ |= {{k:r''{0}''}}; subprocess.run([''git'',''commit'',''-m'',''environ-or''])"' -f $targetGitDir),
                ('python -c "import os,subprocess; k=''GI''+''T_DIR''; e=os.environ; e[k]=r''{0}''; subprocess.run([''git'',''commit'',''-m'',''python-sink-alias''])"' -f $targetGitDir),
                ('node -e "const k=''GI''+''T_DIR''; const e=process.env; e[k]=''{0}''; require(''child_process'').execSync(''git commit -m node-sink-alias'')"' -f $targetGitDir),
                ('pwsh -Command "$k=''GI''+''T_DIR''; Set-Item (''Env:''+$k) ''{0}''; git commit -m inline-provider-path"' -f $targetGitDir),
                ('pwsh -Command "$k=''GI''+''T_WORK_TREE''; $p=[string]::Concat(''Env:'',$k); si $p ''{0}''; git commit -m provider-path-alias"' -f $targetPath)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'python -c "import os,subprocess; k=''FO''+''O''; os.environ |= {k:''1''}; subprocess.run([''git'',''status'',''--short''])"',
                'python -c "import os,subprocess; k=''FO''+''O''; e=os.environ; e[k]=''1''; subprocess.run([''git'',''status'',''--short''])"',
                'node -e "const k=''FO''+''O''; const e=process.env; e[k]=''1''; require(''child_process'').execSync(''git status --short'')"',
                'pwsh -Command "$k=''FO''+''O''; $p=(''Env:''+$k); Set-Item $p ''1''; git commit -m safe-provider-path"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C66 resolves cmd replacements and ComSpec aliases at executable and environment sinks' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'cmd /c call %GIT_EXE:git=git% commit -m percent-replacement',
                'cmd /v:on /c "set g=git&&call !g:git=git! commit -m delayed-replacement"',
                'cmd /v:on /c "set x=xit&&call !x:x=g! commit -m replacement-transform"',
                'cmd /v:on /c "set c=codex&&call !c:codex=codex! exec review"',
                'pwsh -Command "$cs=$env:ComSpec; saps $cs -ArgumentList @(''/c'',''codex'',''exec'',''review'') -Wait"',
                'pwsh -Command "Start-Process ([Environment]::GetEnvironmentVariable(''ComSpec'')) -ArgumentList @(''/c'',''codex'',''exec'',''review'') -Wait"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if ($null -eq $result.OutputObject) {
                throw "Expected gate denial for C66 input: $command"
            }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'cmd /v:on /c "set g=git&&call !g:git=git! status --short"',
                'cmd /v:on /c "set t=git commit&&echo !t:commit=commit!"',
                'pwsh -Command "$cs=$env:ComSpec; saps $cs -ArgumentList @(''/c'',''git'',''status'',''--short'') -Wait"',
                'pwsh -Command "$cs=$env:ComSpec; saps $cs -ArgumentList @(''/c'',''echo'',''git commit is text'') -Wait"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            if ($null -ne $allowed.OutputObject) {
                throw "Expected gate allow for C66 input: $allowedCommand"
            }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }

        $target = New-GateTargetRepo -Root $fixture.Root -Name 'cmd-dynamic-env-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetGitDir = (Join-Path $target.RepoRoot '.git').Replace('\', '/')
        foreach ($command in @(
                ('cmd /v:on /c "set a=GI&&set b=T_DIR&&set !a!!b!={0}&&git commit -m dynamic-env-name"' -f $targetGitDir),
                ('cmd /v:on /c "set x=xGIT_DIRx&&set !x:~1,7!={0}&&git commit -m substring-env-name"' -f $targetGitDir)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        $safe = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'cmd /v:on /c "set a=FO&&set b=O&&set !a!!b!=1&&git commit -m safe-dynamic-env"'
        }
        $safe.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C67 tracks object-level child provenance and unresolved Codex modes by call position' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'node -e "let cp; cp=require(''child_process''); cp.spawnSync(''git'', [''commit'',''-m'',''object-late''])"',
                'node -e "const base=require(''child_process''); let cp; cp=base; cp.spawnSync(''git'', [''commit'',''-m'',''object-alias''])"',
                'node -e "const cp=require(''child_process''); let s; ({spawnSync:s}=cp); s(''git'', [''commit'',''-m'',''assignment-destructure''])"',
                'python -c "import subprocess; sp=subprocess; sp.run([''git'',''commit'',''-m'',''python-object-alias''])"',
                'python -c "import os; o=os; o.system(''git commit -m os-object-alias-chain'')"',
                'node -e "const {spawnSync:s}=require(''child_process''); const mode=process.argv[1]; s(''codex'',[mode])" exec',
                'python -c "import subprocess,sys; mode=sys.argv[1]; subprocess.run([''codex'',mode])" exec'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'node -e "require(''child_process'').spawnSync(''git'', [''status''])"',
                'python -c "import subprocess; subprocess.run([''git'',''status''])"',
                'python -c "import os; os.system(''git status'')"',
                'python -c "import subprocess; subprocess.run([''git'',''branch'',''--list''])"',
                'python -c "import os; os.system(''echo read-only'')"',
                'node -e "const {spawnSync:s}=require(''child_process''); const tool=''echo''; s(tool,[''exec''])"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C68 tracks environment object aliases and invalidates safe reassignments' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'environment-alias-variants-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetGitDir = (Join-Path $target.RepoRoot '.git').Replace('\', '/')

        foreach ($command in @(
                ('node -e "const k=''GI''+''T_DIR''; const {{env:e}}=process; e[k]=''{0}''; require(''child_process'').execSync(''git commit -m process-destructure'')"' -f $targetGitDir),
                ('node -e "const k=''GI''+''T_DIR''; const e=process[''env'']; e[k]=''{0}''; require(''child_process'').execSync(''git commit -m process-computed'')"' -f $targetGitDir),
                ('node -e "const k=''GI''+''T_DIR''; const e=process.env; Object.assign(e,{{[k]:''{0}''}}); require(''child_process'').execSync(''git commit -m object-assign-alias'')"' -f $targetGitDir),
                ('python -c "import os,subprocess; k=''GI''+''T_DIR''; e=getattr(os,''environ''); e[k]=r''{0}''; subprocess.run([''git'',''commit'',''-m'',''getattr-environ''])"' -f $targetGitDir),
                ('python -c "import os,subprocess; k=''GI''+''T_DIR''; e=os.__dict__[''environ'']; e[k]=r''{0}''; subprocess.run([''git'',''commit'',''-m'',''dict-environ''])"' -f $targetGitDir),
                ('python -c "from os import environ as e; import subprocess; k=''GI''+''T_DIR''; e[k]=r''{0}''; subprocess.run([''git'',''commit'',''-m'',''import-environ''])"' -f $targetGitDir),
                ('python -c "import os,subprocess; k=''GI''+''T_DIR''; e=os.environ; e.update({{k:r''{0}''}}); subprocess.run([''git'',''commit'',''-m'',''update-alias''])"' -f $targetGitDir)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'node -e "let e=process.env; e={}; const k=''GI''+''T_DIR''; e[k]=''x''; require(''child_process'').execSync(''git status --short'')"',
                'python -c "import os,subprocess; e=os.environ; e={}; k=''GI''+''T_DIR''; e[k]=''x''; subprocess.run([''git'',''status'',''--short''])"',
                'pwsh -Command ''Set-Item Env:FOO 1; git commit -m safe-static-foo''',
                'pwsh -Command ''Set-Item -Path Env:FOO -Value 1; git commit -m safe-path-foo'''
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C69 resolves cmd wildcard modifiers and ComSpec aliases by invocation position' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'cmd /v:on /c "set x=prefix git&&call !x:* =! commit -m wildcard-git"',
                'cmd /v:on /c "set x=xxgit&&call !x:*xx=! commit -m wildcard-prefix"',
                'cmd /v:on /c "set x=prefix gh&&call !x:* =! pr merge 1200"',
                'cmd /v:on /c "set x=prefix codex&&call !x:* =! exec review"',
                'cmd /c call %GH_EXE:gh=gh% pr merge 1200',
                'pwsh -Command "$cs=$env:ComSpec; saps $cs -ArgumentList @(''/c'',''codex'',''exec'',''review'') -Wait; $cs=''helper''"',
                'pwsh -Command ''$cs=Get-Item Env:ComSpec; saps $cs.Value -ArgumentList @("/c","git","commit","-m","x") -Wait'''
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'cmd /v:on /c "set x=prefix git&&call !x:* =! status --short"',
                'cmd /v:off /c "set g=git&&call !g! commit -m text"',
                'pwsh -Command ''$cs=$env:ComSpec; $cs="echo"; saps $cs -ArgumentList @("git","commit","is","text") -Wait''',
                'pwsh -Command ''$cs=Get-Item Env:ComSpec; saps $cs.Value -ArgumentList @("/c","git","status","--short") -Wait'''
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }

        $target = New-GateTargetRepo -Root $fixture.Root -Name 'cmd-wildcard-env-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetGitDir = (Join-Path $target.RepoRoot '.git').Replace('\', '/')
        $redirected = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = ('cmd /v:on /c "set x=prefix GIT_DIR&&set !x:* =!={0}&&git commit -m wildcard-env"' -f $targetGitDir)
        }
        & $script:AssertDenyResult -Result $redirected
    }

    It 'TASK-783 C70 denies unresolved whole Codex commands and argv containers' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'node -e "const {execSync:e}=require(''child_process''); const mode=process.argv[1]; e(''codex ''+mode)" exec',
                'node -e "const {spawnSync:s}=require(''child_process''); const mode=process.argv[1]; const args=[mode]; s(''codex'',args)" exec',
                'node -e "const {spawnSync:s}=require(''child_process''); const argv=process.argv.slice(1); s(''codex'',argv)" exec',
                'python -c "import subprocess,sys; mode=sys.argv[1]; args=[''codex'',mode]; subprocess.run(args)" exec',
                'python -c "import os,sys; mode=sys.argv[1]; os.system(''codex ''+mode)" exec'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'node -e "require(''child_process'').execSync(''echo read-only'')"',
                'python -c "import subprocess; subprocess.run([''echo'',''read-only''])"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C71 resolves cmd variables at each invocation and honors delayed-expansion mode' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'cmd /c call %GIT_EXE:* =% commit -m external-wildcard-percent',
                'cmd /v:on /c "call !GIT_EXE:* =! commit -m external-wildcard-bang"',
                'cmd /v:on /c "set g=git&&call !g! commit -m temporal&&set g=echo"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        foreach ($allowedCommand in @(
                'cmd /c call %GIT_EXE:* =% status --short',
                'cmd /v:on /c "set g=echo&&call !g! commit is text&&set g=git"',
                'cmd /v:off /c "set x=GIT_DIR&&set !x!=literal&&git commit -m literal-bang-env"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C72 tracks environment aliases across sibling syntax and lexical scopes' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'environment-scope-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $targetGitDir = (Join-Path $target.RepoRoot '.git').Replace('\', '/')

        foreach ($command in @(
                ('node -e "const k=''GIT_DIR''; const {{env}}=process; env[k]=''{0}''; require(''child_process'').execSync(''git commit -m shorthand-env'')"' -f $targetGitDir),
                ('node -e "const k=''GIT_DIR''; const {{''env'':e}}=process; e[k]=''{0}''; require(''child_process'').execSync(''git commit -m quoted-env'')"' -f $targetGitDir),
                ('node -e "const k=''GIT_DIR''; const e=process?.env; e[k]=''{0}''; require(''child_process'').execSync(''git commit -m optional-env'')"' -f $targetGitDir),
                ('node -e "const k=''GIT_DIR''; let e; ({{env:e}}=process); e[k]=''{0}''; require(''child_process'').execSync(''git commit -m assignment-env'')"' -f $targetGitDir),
                ('node -e "const k=''GIT_DIR''; const e=process.env; function f(){{let e={{}};return e}}; e[k]=''{0}''; require(''child_process'').execSync(''git commit -m scoped-env'')"' -f $targetGitDir),
                ('python -c "import os as o,subprocess; k=''GIT_DIR''; e=o.environ; e[k]=r''{0}''; subprocess.run([''git'',''commit'',''-m'',''module-alias-env''])"' -f $targetGitDir),
                ('python -c "import os,subprocess; k=''GIT_DIR''; e,other=os.environ,None; e[k]=r''{0}''; subprocess.run([''git'',''commit'',''-m'',''tuple-env''])"' -f $targetGitDir)
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'node -e "let e; ({env:e}=process); e={}; const k=''GIT_DIR''; e[k]=''x''; require(''child_process'').execSync(''git status --short'')"',
                'python -c "import os,subprocess; e,other=os.environ,None; e={}; k=''GIT_DIR''; e[k]=''x''; subprocess.run([''git'',''status'',''--short''])"',
                'node -e "const e=process.env; Object.assign(e,{FOO:''1''}); require(''child_process'').execSync(''git status --short'')"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C73 tracks child process provenance across property tuple import and scope forms' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'node -e "let s; ({spawnSync:s}=require(''child_process'')); s(''git'', [''commit'',''-m'',''direct-destructure''])"',
                'node -e "const cp={}; cp.spawnSync=require(''child_process'').spawnSync; cp.spawnSync(''git'', [''commit'',''-m'',''property-alias''])"',
                'node -e "const {spawnSync:s}=require(''child_process''); function f(){let s=()=>0;return s}; s(''git'', [''commit'',''-m'',''scoped-method''])"',
                "python -c `"import subprocess`ndef f():`n    subprocess = None`nsubprocess.run(['git','commit','-m','python-scoped-module'])`"",
                'python -c "import os; o,s=os,os.system; s(''git commit -m tuple-system'')"',
                'python -c "import os; s=getattr(os,''system''); s(''git commit -m getattr-system'')"',
                'python -c "from os import path, system as s; s(''git commit -m second-import-system'')"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'node -e "const cp={}; cp.spawnSync=(tool,args)=>[tool,args]; cp.spawnSync(''git'', [''commit''])"',
                'python -c "import os; o,s=os,os.system; s=lambda x:x; s(''git commit is text'')"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C74 resolves direct ComSpec expressions without blocking read-only commands' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'pwsh -Command ''saps (Get-Item Env:ComSpec).Value -ArgumentList @("/c","git","commit","-m","direct-item") -Wait''',
                'pwsh -Command ''saps (gi Env:ComSpec).Value -ArgumentList @("/c","codex","exec","review") -Wait''',
                'pwsh -Command ''Start-Process ([Environment]::GetEnvironmentVariable(("Com"+"Spec"))) -ArgumentList @("/c","git","commit","-m","constructed-comspec") -Wait'''
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'pwsh -Command ''saps (Get-Item Env:ComSpec).Value -ArgumentList @("/c","git","status","--short") -Wait''',
                'pwsh -Command ''Start-Process ([Environment]::GetEnvironmentVariable(("Com"+"Spec"))) -ArgumentList @("/c","echo","git commit is text") -Wait'''
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C75 preserves binding scope while denying parent mutations across function arrow and block forms' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'node -e "const {spawnSync:s}=require(''child_process''); const f=()=>{const s=()=>0;return s}; s(''git'', [''commit'',''-m'',''arrow-shadow''])"',
                'node -e "const {spawnSync:s}=require(''child_process''); {const s=()=>0}; s(''git'', [''commit'',''-m'',''block-shadow''])"',
                'node -e "let cp={spawnSync:(tool,args)=>[tool,args]}; function activate(){cp=require(''child_process'')}; activate(); cp.spawnSync(''git'', [''commit'',''-m'',''parent-assignment''])"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        foreach ($allowedCommand in @(
                'codex --version',
                'node -e "require(''child_process'').spawnSync(''codex'', [''--version''])"',
                'python -c "import subprocess; subprocess.run([''codex'',''--version''])"',
                'node -e "require(''child_process'').spawnSync(''git'', [''status''])"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C76 evaluates tuple RHS argv mutations and object generations at the sink position' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'python -c "import subprocess; r=subprocess.run; s=lambda args:args; r,s=s,r; s([''git'',''commit'',''-m'',''tuple-old-state''])"',
                'node -e "const cp={}; cp.spawnSync=(tool,args)=>[tool,args]; cp={spawnSync:require(''child_process'').spawnSync}; cp.spawnSync(''git'', [''commit'',''-m'',''new-generation''])"',
                'node -e "const {spawnSync:s}=require(''child_process''); const args=[''status'']; args[0]=''exec''; s(''codex'',args)"',
                'python -c "import subprocess,sys; args=[''codex'',''status'']; args[1]=sys.argv[1]; subprocess.run(args)" exec'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        foreach ($allowedCommand in @(
                'python -c "import subprocess; subprocess.run([''git'',''status''])"',
                'node -e "require(''child_process'').spawnSync(''git'', [''status''])"',
                'node -e "const {spawnSync:s}=require(''child_process''); const args=[''--version'']; s(''codex'',args)"',
                'python -c "import subprocess; args=[''codex'',''--version'']; subprocess.run(args)"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty -Because $allowedCommand
        }
    }

    It 'TASK-783 C77 preserves cmd conditional execution and delayed-expansion mode per invocation' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        foreach ($command in @(
                'cmd /v:on /c "set g=git || set g=echo & call !g! commit -m conditional-write"',
                'cmd /v:off /c "set g=echo&&echo !g!"; cmd /v:on /c "set g=git&&call !g! commit -m per-invocation-write"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result
        }

        foreach ($allowedCommand in @(
                'cmd /v:on /c "set g=echo && set g=git || call !g! commit -m skipped-branch"',
                'cmd /v:off /c "set g=git&&echo !g! commit is text"; cmd /v:on /c "set g=echo&&call !g! commit is text"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C78 preserves PowerShell ComSpec bindings across function-local shadows' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root

        $denied = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'pwsh -Command ''$cs=Get-Item Env:ComSpec; function f {$cs="echo"}; saps $cs.Value -ArgumentList @("/c","git","commit","-m","scope-shadow") -Wait'''
        }
        & $script:AssertDenyResult -Result $denied

        $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'pwsh -Command ''$cs="echo"; function f {$cs=Get-Item Env:ComSpec}; saps $cs -ArgumentList @("git","commit","is","text") -Wait'''
        }
        $allowed.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C79 resolves aliases at assignment time and fails closed on dynamic process candidates' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        foreach ($command in @(
                'node -e "const {spawnSync:s}=require(''child_process''); let a=[''exec'']; const args=a; a=[''--version'']; s(''codex'',args)"',
                'node -e "const cp=require(''child_process''); const method=process.argv[1]; cp[method](''git'', [''commit'',''-m'',''computed-method''])" spawnSync',
                'python -c "import subprocess,sys; f=getattr(subprocess,sys.argv[1]); f([''git'',''commit'',''-m'',''dynamic-getattr''])" run'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        foreach ($allowedCommand in @(
                'node -e "require(''child_process'').execSync(''codex --version'')"',
                'node -e "const {spawnSync:s}=require(''child_process''); const args=[''--version'']; s(''codex'',args)"',
                'node -e "require(''child_process'').spawnSync(''git'', [''status''])"',
                'python -c "import subprocess; subprocess.run([''git'',''status''])"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C80 fails closed on unresolved process callees and whole Codex commands' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        foreach ($command in @(
                'node -e "const {execSync:e}=require(''child_process''); e(process.argv[1])" "codex exec"',
                'node -e "const cp=require(''child_process''); const f=cp[process.argv[1]]; f(''git'', [''commit'',''-m'',''x''])" spawnSync',
                'python -c "import subprocess,sys; getattr(subprocess,sys.argv[1])([''git'',''commit'',''-m'',''x''])" run',
                'python -c "import os,sys; os.system(sys.argv[1])" "codex exec"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        foreach ($allowedCommand in @(
                'node -e "require(''child_process'').spawnSync(''echo'',[''read-only''])"',
                'node -e "const e=x=>x; e(process.argv[1])" "codex exec"',
                'python -c "import subprocess; subprocess.run([''echo'',''read-only''])"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C81 resolves command and argv scalars in lexical scope' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        foreach ($command in @(
                'node -e "const {execSync:e}=require(''child_process''); const mode=''exec''; function f(){const mode=''--version'';return mode}; const command=''codex ''+mode; e(command)"',
                'node -e "const {spawnSync:s}=require(''child_process''); const mode=''exec''; function f(){const mode=''--version'';return mode}; s(''codex'',[mode])"',
                "python -c `"import os`nmode='exec'`ndef f():`n    mode='--version'`n    return mode`nos.system('codex '+mode)`""
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        foreach ($allowedCommand in @(
                'node -e "const {execSync:e}=require(''child_process''); const mode=''--version''; function f(){const mode=''help'';return mode}; const command=''codex ''+mode; e(command)"',
                'node -e "const {spawnSync:s}=require(''child_process''); const mode=''--version''; function f(){const mode=''help'';return mode}; s(''codex'',[mode])"',
                "python -c `"import os`nmode='--version'`ndef f():`n    mode='help'`n    return mode`nos.system('codex '+mode)`""
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C82 fails closed on unsupported provenance and alias mutation' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        foreach ($command in @(
                'node -e "const {spawnSync:s}=require(''child_process''); if(true){let s=()=>0;} s(''git'', [''commit'',''-m'',''x''])"',
                'node -e "const {spawnSync:s}=require(''child_process''); const a=[''--version'']; const b=a; b[0]=''exec''; s(''codex'',a)"',
                'node -e "let s=x=>x; let t=require(''child_process'').spawnSync; [s,t]=[t,s]; s(''git'', [''commit''])"',
                'node -e "const cp=Object.assign({},require(''child_process'')); cp.spawnSync(''git'', [''commit''])"',
                'node -e "const cp={}; cp[''spawnSync'']=require(''child_process'').spawnSync; cp.spawnSync(''git'', [''commit''])"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        foreach ($allowedCommand in @(
                'node -e "if(true){let s=()=>0; s(''git'', [''commit'']);}"',
                'node -e "const {spawnSync:s}=require(''child_process''); const a=[''--version'']; const b=a; s(''codex'',a)"',
                'node -e "const spawnSync=()=>0; const fake={spawnSync(){return 0}}; fake.spawnSync(''codex'', [''exec''])"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C83 models cmd state transitions conservatively' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        foreach ($command in @(
                'cmd /v:off /c "setlocal EnableDelayedExpansion&set g=git&call !g! commit -m x"',
                'cmd /v:on /c "set g=echo&if defined g set g=git&call !g! commit -m x"',
                'cmd /v:on /c "type missing-file >nul 2>&1 && set g=echo || set g=git & call !g! commit -m x"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        foreach ($allowedCommand in @(
                'cmd /v:on /c "set g=echo&call !g! commit is text"',
                'cmd /v:off /c "echo !g! commit is text"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty
        }
    }

    It 'TASK-783 C84 tracks outer environment bindings at the protected sink' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'env-parent-binding-target'
        $escapedTarget = (Join-Path $target.RepoRoot '.git').Replace('\\', '\\\\')
        $command = 'node -e "const cp=require(''child_process''); let e={{}}; function activate(){{e=process.env}}; activate(); e[''GIT_DIR'']=''{0}''; cp.execSync(''git commit -m x'')"' -f $escapedTarget
        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
        & $script:AssertDenyResult -Result $result -Because $command

        $allowedCommand = 'node -e "const cp=require(''child_process''); const e={}; e[''GIT_DIR'']=''not-an-environment-alias''; cp.execSync(''git status'')"'
        $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
        $allowed.OutputObject | Should -BeNullOrEmpty
    }

    It 'TASK-783 C85 rejects complex protected interpreter boundaries while preserving literal read-only calls' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'conservative-boundary-target'
        $targetGitDir = (Join-Path $target.RepoRoot '.git').Replace('\', '/')

        $deniedCommands = @(
            'node -e "let s=require(''child_process'').spawnSync; function never(){s=()=>0}; s(''git'', [''commit'',''-m'',''x''])"',
            'node -e "if(true){var s=require(''child_process'').spawnSync;} s(''git'', [''commit'',''-m'',''x''])"',
            'node -e "const f=Reflect.get(require(''child_process''),''spawnSync''); f(''git'', [''commit''])"',
            'node -e "const f=Reflect.get(require(''child_process''),''spawnSync''); f(''g''+''it'', [''com''+''mit''])"',
            'node -e "const f=Reflect.get(require(''child_process''),''spawnSync''); f(''codex'', [''ex''+''ec''])"',
            'node -e "const action=''commit''; const tool=''git''; const f=Reflect.get(require(''child_process''),''spawnSync''); f(tool,[action])"',
            'node -e "const tool=[''co'',''dex''].join(''''); const mode=[''ex'',''ec''].join(''''); const f=Reflect.get(require(''child_process''),''spawnSync''); f(tool,[mode])"',
            'node -e "const cp={...require(''child_process'')}; cp.spawnSync(''git'', [''commit''])"',
            'node -e "const {spawnSync:s}=require(''child_process''); const a=[''--version'']; const b=a; Reflect.set(b,0,''exec''); s(''codex'',a)"',
            'cmd /v:on /c "set g=git&setlocal DisableDelayedExpansion&endlocal&call !g! commit -m x"',
            'cmd /c "if defined ComSpec git commit -m x"',
            'cmd /c "if exist NUL git commit -m x"',
            'cmd /v:on /c "set a=com&set b=mit&if exist NUL git !a!!b! -m x"',
            ('node -e "const cp=require(''child_process''); const e=Reflect.get(process,''env''); e[''GIT_DIR'']=''{0}''; cp.execSync([''g'',''it commit -m x''].join(''''))"' -f $targetGitDir),
            ('node -e "const cp=require(''child_process''); let e=process.env; function never(){{e={{}}}}; e[''GIT_DIR'']=''{0}''; cp.execSync(''git commit -m x'')"' -f $targetGitDir)
        )
        foreach ($command in $deniedCommands) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        foreach ($allowedCommand in @(
                'node -e "require(''child_process'').spawnSync(''git'', [''status'',''--short''])"',
                'node -e "require(''child_process'').execSync(''codex --version'')"',
                'python -c "import subprocess; subprocess.run([''git'',''status''])"',
                'cmd /c "git status --short"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty -Because $allowedCommand
        }
    }

    It 'TASK-783 C86 rejects every non-canonical inline process boundary without safe-call decoys' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'canonical-boundary-target'
        $targetGitDir = (Join-Path $target.RepoRoot '.git').Replace('\', '/')

        $deniedCommands = @(
            'node -e "const cp=require(''child''+''_process''); cp.spawnSync(''g''+''it'', [''com''+''mit''])"',
            'python -c "m=__import__(''sub''+''process''); m.run([''g''+''it'',''com''+''mit''])"',
            'node -e "const cp=require(''child_process''); Object.getOwnPropertyDescriptor(cp,''spawnSync'').value(''g''+''it'', [''com''+''mit'']); cp.spawnSync(''git'', [''status''])"',
            'node -e "const cp=require(''child_process''); cp.spawnSync(''git'', [''status'']); Object.getOwnPropertyDescriptor(cp,''spawnSync'').value(''g''+''it'', [''com''+''mit''])"',
            'node -e "const cp=require(''child_process''); cp[''spawn''+''Sync''](''git'', [''commit'']); cp.spawnSync(''git'', [''status''])"',
            'node -e "const cp=require(String.fromCharCode(99,104,105,108,100,95,112,114,111,99,101,115,115)); cp.spawnSync(''git'', [''commit''])"',
            'python -c "m=__import__(''subprocess''); getattr(m,''r''+''un'')([''git'',''commit''])"',
            'cmd /v:on /c "set a=gi&set b=t&set c=com&set d=mit&if exist NUL !a!!b! !c!!d! -m x"',
            ('node -e "const e=Object.getOwnPropertyDescriptor(process,''env'').value; e[''GIT''+''_DIR'']=''{0}''; const cp=require(''child''+''_process''); cp.execSync(''g''+''it com''+''mit -m x'')"' -f $targetGitDir),
            ('python -c "import os; e=getattr(os,''en''+''viron''); e[''GIT''+''_DIR'']=r''{0}''; m=__import__(''sub''+''process''); m.run([''g''+''it'',''com''+''mit''])"' -f $targetGitDir),
            'node -e "require(''child_process'').spawnSync(''git'', [''status''], {cwd:process.argv[1]})" .',
            'node -e "require(''child_process'').spawnSync(''git'', [''status''], {env:process.env})"',
            'node -e "require(''child_process'').spawnSync(''git status'', [], {shell:true})"',
            'node -e "eval(''require(\\''child_process\\'').execSync(\\''git commit\\'')'')"',
            'node -e "Function(''return process'')().mainModule.require(''child_process'').execSync(''git commit'')"',
            'node -e "const p=new Proxy(require(''child_process''),{}); p.spawnSync(''git'', [''commit''])"'
        )
        foreach ($command in $deniedCommands) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        foreach ($allowedCommand in @(
                'node -e "require(''child_process'').spawnSync(''git'', [''status'',''--short''])"',
                'node -e "require(''child_process'').execSync(''codex --version'')"',
                'python -c "import subprocess; subprocess.run([''git'',''status''])"',
                'cmd /c "git status --short"',
                'cmd /c "echo read-only text"',
                'node -e "console.log(''read-only text'')"',
                'python -c "print(''read-only text'')"'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            $allowed.OutputObject | Should -BeNullOrEmpty -Because $allowedCommand
        }
    }

    It 'TASK-783 C87 enforces lexical module and callee provenance without unrelated-method false positives' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        foreach ($command in @(
                'node -e "const m=String.fromCharCode(99,104,105,108,100,95,112,114,111,99,101,115,115); function f(){const m=''fs'';} const cp=require(m); cp.spawnSync(''git'', [''commit''])"',
                'node -e "const r=require; const m=String.fromCharCode(99,104,105,108,100,95,112,114,111,99,101,115,115); const cp=r(m); cp.spawnSync(''git'', [''commit''])"',
                'node -e "const cp=require(''child''+''_process''); (0,cp.spawnSync)(''git'', [''commit''])"',
                'node -e "const r=require; const m=''child''+''_process''; const cp=r(m); const k=''sp''+''awnSync''; cp[k](''git'', [''commit''])"',
                'node -e "const cp=require(''child_process''); (0,cp.spawnSync)(''git'', [''commit''])"',
                'node -e "const cp=require(''child_process''); cp.spawnSync.call(null,''git'', [''commit''])"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            & $script:AssertDenyResult -Result $result -Because $command
        }

        $unrelatedMethod = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = 'node -e "require(''child_process''); const fake={spawnSync(){}}; fake.spawnSync(''echo'', [''read-only''])"'
        }
        $unrelatedMethod.OutputObject | Should -BeNullOrEmpty -Because 'an unrelated object method is not a child_process capability'
    }

    It 'TASK-783 C88 closes cross-interpreter dispatch gaps without blocking process-free reflection or literal read-only calls' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $headBefore = (& git -C $fixture.RepoRoot rev-parse HEAD).Trim()
        $reviewStatePath = Join-Path $fixture.RepoRoot '.winsmux\review-state.json'
        $reviewStateHashBefore = (Get-FileHash -LiteralPath $reviewStatePath -Algorithm SHA256).Hash
        $indexStateBefore = (& git -C $fixture.RepoRoot diff --cached --binary) -join "`n"
        $worktreeStateBefore = (& git -C $fixture.RepoRoot diff --binary) -join "`n"
        $refsStateBefore = (& git -C $fixture.RepoRoot for-each-ref '--format=%(refname)%00%(objectname)') -join "`n"

        $rule7Commands = @(
            'node -e "require(''child_process'').spawnSync(''codex'', [''--no-alt-screen'',''exec''])"',
            'python -c "import subprocess; subprocess.run([''codex'',''--no-alt-screen'',''exec''])"',
            'python -c "import os; os.execlp(''codex'',''codex'',''exec'')"',
            'python -c "from os import execlp as launch; launch(''codex'',''codex'',''exec'')"',
            'python -c "import os; os.spawnl(os.P_WAIT,''codex'',''codex'',''exec'')"',
            'python -c "import os; os.spawnle(os.P_WAIT,''codex'',''codex'',''exec'',os.environ)"',
            'python -c "import os; os.spawnlp(os.P_WAIT,''codex'',''codex'',''exec'')"',
            'python -c "import os; os.spawnlpe(os.P_WAIT,''codex'',''codex'',''exec'',os.environ)"',
            'python -c "import os; getattr(os,''exe''+''clp'')(''codex'',''codex'',''exec'')"',
            'python -c "import os; getattr(os,pick(''execl'',''p''))(''codex'',''codex'',''exec'')"',
            'python -c "import os; launch=os.execlp; launch(''codex'',''codex'',''exec'')"',
            'python -c "import os; launch=getattr(os,pick(''execl'',''p'')); launch(''codex'',''codex'',''exec'')"',
            'python -c "import os; c=bytes.fromhex(''636f646578'').decode(); os.execlp(c,c,''exec'')"',
            'python -c "import subprocess,sys; subprocess.run(sys.argv[1:])" codex exec',
            'node -e "require(''child_process'').spawnSync(process.argv[1],process.argv.slice(2))" codex exec',
            'python -c "import os; launch,other=os.execlp,None; launch(''codex'',''codex'',''exec'')"',
            'python -c "import os; o=os; o.execlp(''codex'',''codex'',''exec'')"',
            'python -c "import os; launchers=[os.execlp]; launchers[0](''codex'',''codex'',''exec'')"',
            'python -c "import subprocess; args=[''codex'',''--version'']; args.__setitem__(1,''exec''); subprocess.run(args)"'
        )
        $unexpectedAllowed = @()
        $unexpectedRemediation = @()
        $deniedCommands = @(
                'nodejs -e "require(''child_process'').spawnSync(''codex'', [''exec''])"',
                'py -c "import subprocess; subprocess.run([''codex'',''exec''])"',
                'python3.12 -c "import subprocess; subprocess.run([''codex'',''exec''])"',
                'node -e "const cp=module.require(''child''+''_process''); cp.spawnSync(''codex'', [''exec''])"',
                'node -e "const cp=process.getBuiltinModule(''child''+''_process''); cp.spawnSync(''codex'', [''exec''])"',
                'python -c "import os; os.posix_spawnp(''codex'', [''codex'',''exec''], os.environ)"',
                'python -c "import os; os.spawnvp(os.P_WAIT, ''codex'', [''codex'',''exec''])"',
                'python -c "from os import spawnvp as launch, P_WAIT; launch(P_WAIT, ''codex'', [''codex'',''exec''])"',
                'python -c "exec(''import sub''+''process; subprocess.run([\"codex\",\"exec\"])'')"',
                'python -c "eval(''__import__(\"sub\"+\"process\").run([\"codex\",\"exec\"])'')"',
                'python -c "import os; os.system(''cmd /c codex exec'')"',
                'python -c "import subprocess; subprocess.run([''cmd'',''/c'',''codex exec''])"',
                'node -e "require(''child_process'').spawnSync(''cmd'', [''/c'',''codex exec''])"',
                'node -e "require(`child_process`).execSync(''codex exec'')"',
                'python -c "import os; os.popen(''codex exec'')"',
                'python -c "from os import popen as launch; launch(''codex exec'')"',
                'python -c "import os; m,x=os,None; m.execlp(''codex'',''codex'',''exec'')"',
                'cmd /c "for %x in (codex) do %x exec"',
                'cmd /c "for %A in (codex) do @%A exec review"',
                'pwsh -NoProfile -Command "iex ''codex exec''"',
                'pwsh -NoProfile -Command "iex (''co''+''dex exec review'')"',
                'pwsh -NoProfile -Command "[ScriptBlock]::Create(''codex exec'').Invoke()"',
                'pwsh -NoProfile -Command "[ScriptBlock]::Create(''co''+''dex exec review'').Invoke()"',
                'pwsh -NoProfile -Command "[System.Diagnostics.Process]::Start(''codex'',''exec'')"',
                'pwsh -NoProfile -Command "[Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]::new(''codex'',''exec review''))"',
                'pwsh -NoProfile -Command "$p=[System.Diagnostics.ProcessStartInfo]::new(''codex'',''exec''); [System.Diagnostics.Process]::Start($p)"',
                'git -c alias.unsafe="!echo arbitrary-shell" -c alias.safe=status safe --short',
                'git -c "alias.ce=!codex exec" -c alias.st=status ce'
            ) + $rule7Commands
        foreach ($command in $deniedCommands) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if (-not $result.OutputObject) {
                $unexpectedAllowed += $command
            }
            if ($rule7Commands -contains $command -and $result.OutputObject.systemMessage -notmatch 'winsmux send') {
                $unexpectedRemediation += $command
            }
        }
        $unexpectedDenied = @()
        foreach ($allowedCommand in @(
                'node -e "console.log(Object.getOwnPropertyDescriptor({a:1},''a'').value)"',
                'nodejs -e "require(''child_process'').spawnSync(''git'', [''status'',''--short''])"',
                'py -c "import subprocess; subprocess.run([''git'',''status''])"',
                'python3.12 -c "import subprocess; subprocess.run([''git'',''status''])"',
                'node -e "require(''child_process'').spawnSync(''codex'', [''--version''])"',
                'python -c "import subprocess; subprocess.run([''codex'',''--version''])"',
                'python -c "print(''os.execlp codex exec'')"',
                'python -c "print(\"os.execlp(''codex'',''codex'',''exec'')\")"',
                'python -c "import os; os.spawnvp(os.P_WAIT,''git'', [''git'',''status''])"',
                'python -c "import os; os.spawnvp(os.P_WAIT,''codex'', [''codex'',''--version''])"',
                'python -c "import os; os.execlp(''git'',''git'',''grep'',''codex'',''exec'')"',
                'python -c "import os; os.execlp(''echo'',''echo'',''codex'',''exec'')"',
                'python -c "import os; os.system(''echo codex exec'')"',
                'python -c "import subprocess; subprocess.run([''cmd'',''/c'',''git status''])"',
                'node -e "require(`child_process`).execSync(''codex --version'')"',
                'python -c "import os; os.popen(''git status'')"',
                'python -c "import os; m,x=os,None; m.execlp(''git'',''git'',''grep'',''codex'',''exec'')"',
                'cmd /c "git status --short"',
                'git -c alias.safe=status safe --short'
            )) {
            $allowed = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $allowedCommand }
            if ($allowed.OutputObject) {
                $unexpectedDenied += $allowedCommand
            }
        }
        $failures = @()
        if ($unexpectedAllowed.Count -gt 0) {
            $failures += 'allowed unexpectedly: ' + ($unexpectedAllowed -join ' | ')
        }
        if ($unexpectedRemediation.Count -gt 0) {
            $failures += 'wrong Rule 7 remediation: ' + ($unexpectedRemediation -join ' | ')
        }
        if ($unexpectedDenied.Count -gt 0) {
            $failures += 'denied unexpectedly: ' + ($unexpectedDenied -join ' | ')
        }
        $headAfter = (& git -C $fixture.RepoRoot rev-parse HEAD).Trim()
        $reviewStateHashAfter = (Get-FileHash -LiteralPath $reviewStatePath -Algorithm SHA256).Hash
        $indexStateAfter = (& git -C $fixture.RepoRoot diff --cached --binary) -join "`n"
        $worktreeStateAfter = (& git -C $fixture.RepoRoot diff --binary) -join "`n"
        $refsStateAfter = (& git -C $fixture.RepoRoot for-each-ref '--format=%(refname)%00%(objectname)') -join "`n"
        if ($headAfter -ne $headBefore) {
            $failures += "fixture HEAD changed: $headBefore -> $headAfter"
        }
        if ($reviewStateHashAfter -ne $reviewStateHashBefore) {
            $failures += "review state changed: $reviewStateHashBefore -> $reviewStateHashAfter"
        }
        if ($indexStateAfter -cne $indexStateBefore) {
            $failures += 'fixture index changed'
        }
        if ($worktreeStateAfter -cne $worktreeStateBefore) {
            $failures += 'fixture worktree changed'
        }
        if ($refsStateAfter -cne $refsStateBefore) {
            $failures += 'fixture refs changed'
        }
        $failures | Should -BeNullOrEmpty -Because ('the full decision table and rejected-state preservation must hold; ' + ($failures -join ' || '))
    }

    It 'TASK-783 C89 fails closed for unowned process capabilities and proves static wrapper controls' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        $unexpectedAllowed = @()
        foreach ($command in @(
                'python -c "import subprocess; subprocess.run([''sh'',''-c'',''"$0" "$1$2"'',''codex'',''ex'',''ec''])"',
                'node -e "require(''child_process'').spawnSync(''sh'', [''-c'',''"$0" "$1$2"'',''codex'',''ex'',''ec''])"',
                'node -e "require(`child\u005fprocess`).execSync(''codex exec'')"',
                'node -e "require(`node:child\x5fprocess`).execSync(''codex exec'')"',
                'python -c "import os; mods=[os]; mods[0].execlp(''codex'',''codex'',''exec'')"',
                'python -c "import os; (m,x)=(os,None); m.execlp(''codex'',''codex'',''exec'')"',
                'python -c "import os; [m,x]=[os,None]; m.execlp(''codex'',''codex'',''exec'')"',
                'python -c "import os; m=(os); m.execlp(''codex'',''codex'',''exec'')"',
                'python -c "import os; getattr(os,''popen'')(''codex exec'')"',
                'python -c "import os; getattr(os,''po''+''pen'')(''codex exec'')"',
                'python -c "import os,sys; getattr(os,sys.argv[1])(''git status'')"',
                'python -c "import os; launchers=(os.execlp,); launchers[0](''codex'',''codex'',''exec'')"',
                'python -c "import os; box={''run'':os.execlp}; box[''run''](''codex'',''codex'',''exec'')"',
                'python -c "import subprocess; subprocess.run([''env'',''codex'',''exec''])"',
                'node -e "require(''child_process'').spawnSync(''/usr/bin/env'', [''codex'',''exec''])"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if (-not $result.OutputObject) {
                $unexpectedAllowed += $command
            }
        }

        $unexpectedDenied = @()
        foreach ($command in @(
                'python -c "import subprocess; subprocess.run([''sh'',''-c'',''git status --short''])"',
                'python -c "import subprocess; subprocess.run([''sh'',''-c'',''"$0" "$1$2"'',''git'',''sta'',''tus''])"',
                'node -e "require(''child_process'').spawnSync(''sh'', [''-c'',''"$0" "$1$2"'',''git'',''sta'',''tus''])"',
                'node -e "require(`child\u005fprocess`).execSync(''codex --version'')"',
                'node -e "require(`node:child\x5fprocess`).execSync(''git status'')"',
                'python -c "import subprocess; subprocess.run([''env'',''git'',''status'',''--short''])"',
                'node -e "require(''child_process'').spawnSync(''/usr/bin/env'', [''codex'',''--version''])"',
                'python -c "import os; getattr(os,''popen'')(''git status'')"',
                'python -c "import os; m=os; m.execlp(''git'',''git'',''status'')"',
                'python -c "import platform; print(platform.system())"',
                'python -c "class Cursor: pass; cursor=Cursor(); cursor.execute=lambda value:value; print(cursor.execute(''select 1''))"',
                'python -c "import os; print(os.name)"',
                'python -c "mods=[''os'']; print(mods[0])"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if ($result.OutputObject) {
                $unexpectedDenied += $command
            }
        }
        @(
            if ($unexpectedAllowed.Count -gt 0) { 'allowed unexpectedly: ' + ($unexpectedAllowed -join ' | ') }
            if ($unexpectedDenied.Count -gt 0) { 'denied unexpectedly: ' + ($unexpectedDenied -join ' | ') }
        ) | Should -BeNullOrEmpty
    }

    It 'TASK-783 C90 propagates process ownership across options parameters and container mutation without blocking pure imports' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        $unexpectedAllowed = @()
        foreach ($command in @(
                'node -e "const o={shell:true}; require(''child_process'').spawnSync(''echo'', [''ok && codex exec''], o)"',
                'node -e "const base={shell:true}; const o={...base}; require(''child_process'').spawnSync(''echo'', [''ok && codex exec''], o)"',
                'node -e "const f=cp=>cp.spawnSync(''codex'', [''exec'']); f(require(''child_process''))"',
                'node -e "const f=x=>x.cp.spawnSync(''codex'', [''exec'']); f({cp:require(''child_process'')})"',
                'node -e "const box={cp:require(''child_process'')}; box.cp.spawnSync(''codex'', [''exec''])"',
                'node -e "const box=[require(''child_process'')]; box[0].spawnSync(''codex'', [''exec''])"',
                'node -e "function load(){return require(''child_process'')} load().spawnSync(''codex'', [''exec''])"',
                'python -c "import os; (lambda m:m.system(''codex exec''))(os)"',
                'python -c "import os; f=lambda m:m.popen(''codex exec''); f(os)"',
                'node -e "const s=require(''child_process'').spawnSync; const a=[''--version'']; Object.assign(a,{0:''exec''}); s(''codex'',a)"',
                'node -e "const s=require(''child_process'').spawnSync; const a=[''--version'']; Reflect.set(a,0,''exec''); s(''codex'',a)"',
                'node -e "const s=require(''child_process'').spawnSync; const a=[''--version'']; function mutate(x){x[0]=''exec''}; mutate(a); s(''codex'',a)"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if (-not $result.OutputObject) {
                $unexpectedAllowed += $command
            }
        }

        $unexpectedDenied = @()
        foreach ($command in @(
                'node -e "const m=''fs''; require(m); console.log(''read-only'')"',
                'node -e "const m=''f''+''s''; require(m); console.log(''read-only'')"',
                'python -c "print(__import__(''json'').dumps({''ok'':True}))"',
                'python -c "import importlib; print(importlib.import_module(''json'').dumps({''ok'':True}))"',
                'node -e "const cp=require(''child_process''); cp.spawnSync(''git'', [''status''], {stdio:''pipe''})"',
                'node -e "const o={encoding:''utf8''}; require(''child_process'').execSync(''codex --version'', o)"',
                'node -e "const a=[''read-only'']; Object.assign(a,{0:''still-read-only''}); console.log(a[0])"',
                'python -c "import json; print((lambda m:m.dumps({''ok'':True}))(json))"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if ($result.OutputObject) {
                $unexpectedDenied += $command
            }
        }

        @(
            if ($unexpectedAllowed.Count -gt 0) { 'allowed unexpectedly: ' + ($unexpectedAllowed -join ' | ') }
            if ($unexpectedDenied.Count -gt 0) { 'denied unexpectedly: ' + ($unexpectedDenied -join ' | ') }
        ) | Should -BeNullOrEmpty
    }

    It 'TASK-783 C91 permits only canonical capability parents bindings loaders and immutable proof inputs' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        $unexpectedAllowed = @()
        foreach ($command in @(
                'node -e "const m=''fs''; ({m}={m:''child_process''}); require(m).spawnSync(''codex'', [''exec''])"',
                'python -c "from importlib import import_module as load; load(''subprocess'').run([''codex'',''exec''])"',
                'python -c "from importlib import import_module as load; alias=load; m=alias(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "load=__import__; alias=load; m=alias(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import importlib; load=importlib.import_module; m=load(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import importlib as il; alias=il; m=alias.import_module(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import importlib as il; load=il.import_module; alias=load; m=alias(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "from importlib import import_module as load; alias=(load,)[0]; m=alias(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import importlib; load=getattr(importlib,''import_module''); m=load(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import importlib; load=vars(importlib)[''import_module'']; m=load(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import importlib; load=importlib.__dict__[''import_module'']; m=load(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import os, importlib as il; alias=il; m=alias.import_module(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "from importlib import (import_module as load); alias=load; m=alias(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "__import__(''os.path'').system(''codex exec'')"',
                'node -e "const cp=true?require(''child_process''):{}; cp.spawnSync(''codex'', [''exec''])"',
                'node -e "import(''child_process'').then(cp => cp.spawnSync(''codex'', [''exec'']))"',
                'node -e "import(''node:child_process'').then(({spawnSync}) => spawnSync(''codex'', [''exec'']))"',
                'python -c "import os; (lambda m=os:m.system(''codex exec''))()"',
                'node -e "const o={encoding:''utf8''}; o.shell=true; require(''child_process'').spawnSync(''echo'', [''ok && codex exec''], o)"',
                'node -e "const s=require(''child_process'').spawnSync; const a=[''--version'']; const mutators={set:x=>x[0]=''exec''}; mutators[''set''](a); s(''codex'',a)"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if (-not $result.OutputObject) { $unexpectedAllowed += $command }
        }

        $unexpectedDenied = @()
        foreach ($command in @(
                'node -e "const m=''fs''; require(m); console.log(''read-only'')"',
                'python -c "from importlib import import_module as load; print(load(''json'').dumps({''ok'':True}))"',
                'python -c "import importlib as il; print(il.import_module(''json'').dumps({''ok'':True}))"',
                'python -c "import os, importlib as il; print(il.import_module(''json'').dumps({''ok'':True}))"',
                'python -c "from importlib import (import_module as load); print(load(''json'').dumps({''ok'':True}))"',
                'python -c "print(__import__(''json.encoder'').__name__)"',
                'node -e "const value=true?require(''fs''):{}; console.log(Boolean(value))"',
                'python -c "import json; print((lambda m=json:m.dumps({''ok'':True}))())"',
                'node -e "const other={encoding:''utf8''}; other.shell=true; require(''child_process'').spawnSync(''codex'', [''--version''])"'
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if ($result.OutputObject) { $unexpectedDenied += $command }
        }

        @(
            if ($unexpectedAllowed.Count -gt 0) { 'allowed unexpectedly: ' + ($unexpectedAllowed -join ' | ') }
            if ($unexpectedDenied.Count -gt 0) { 'denied unexpectedly: ' + ($unexpectedDenied -join ' | ') }
        ) | Should -BeNullOrEmpty
    }

    It 'TASK-783 C92 resolves Python loader provenance without blocking read-only importlib diagnostics' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch

        $longLoaderGapCommand = 'python -c "import importlib; importlib.import_module{0}(''subprocess'').run([''codex'',''exec''])"' -f (' ' * 1100)
        $multilineComprehensionCommand = @'
python -c "import importlib; [m.import_module('subprocess').run(['codex','exec']) for m in
{importlib}]"
'@.Trim()
        $returnCapabilityCommand = @'
python -c "import importlib
def f(): return importlib
f().import_module('subprocess').run(['codex','exec'])"
'@.Trim()
        $safeReturnCommand = @'
python -c "import json
def f(): return json
print(f().dumps({'ok':True}))"
'@.Trim()
        $unexpectedAllowed = @()
        foreach ($command in @(
                'python -c "import builtins; builtins.__import__(''subprocess'').run([''codex'',''exec''])"',
                'python -c "import builtins as b; load=getattr(b,''__import__''); m=load(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import builtins; load=builtins.__import__; m=load(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "m=getattr(__builtins__,''__import__'')(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "m=__builtins__[''__import__''](''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import builtins; m=vars(builtins)[''__import__''](''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import builtins; m=builtins.__dict__[''__import__''](''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "from builtins import __import__ as load; m=load(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import builtins; name=''subprocess''; m=builtins.__import__(name); m.run([''codex'',''exec''])"',
                'python -c "import builtins,sys; m=builtins.__import__(sys.argv[1]); m.run([''codex'',''exec''])" subprocess',
                'python -c "import importlib; (importlib.import_module)(''subprocess'').run([''codex'',''exec''])"',
                'python -c "import importlib; m=(importlib).import_module(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import builtins; m=(builtins).__import__(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import builtins; getattr(builtins,''__import__'')(''subprocess'').run([''codex'',''exec''])"',
                'python -c "import builtins; builtins.__dict__.get(''__import__'')(''subprocess'').run([''codex'',''exec''])"',
                'python -c "import builtins; (lambda load: load(''subprocess'').run([''codex'',''exec'']))(builtins.__import__)"',
                'python -c "import builtins; (lambda load=builtins.__import__: load(''subprocess'').run([''codex'',''exec'']))()"',
                'python -c "import builtins; f=lambda b:b.__import__; load=f(builtins); m=load(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import builtins; f=lambda b=builtins:b.__import__; load=f(); m=load(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import importlib; (lambda m: m.import_module(''subprocess'').run([''codex'',''exec'']))(importlib)"',
                'python -c "import importlib,operator; operator.attrgetter(''import_module'')(importlib)(''subprocess'').run([''codex'',''exec''])"',
                'python -c "import builtins; (lambda box: box[0].__import__(''subprocess'').run([''codex'',''exec'']))([builtins])"',
                'python -c "import importlib; box={''loader'':importlib}; (lambda value: value[''loader''].import_module(''subprocess'').run([''codex'',''exec'']))(box)"',
                'python -c "import builtins; load=builtins.__getattribute__(''__import__''); m=load(''subprocess''); m.run([''codex'',''exec''])"',
                'python -c "import importlib; (m := importlib).import_module(''subprocess'').run([''codex'',''exec''])"',
                'python -c "import importlib; [m.import_module(''subprocess'').run([''codex'',''exec'']) for m in [importlib]]"',
                'python -c "import importlib; {m.import_module(''subprocess'').run([''codex'',''exec'']) for m in [importlib]}"',
                'python -c "import importlib; [m.import_module(''subprocess'').run([''codex'',''exec'']) for m in {importlib}]"',
                'python -c "import importlib; [m.import_module(''subprocess'').run([''codex'',''exec'']) for (m,) in [(importlib,)]]"',
                'python -c "import importlib; [m.import_module(''subprocess'').run([''codex'',''exec'']) for m,_ in [(importlib,None)]]"',
                'node -e "require(''child_process'').spawnSync(''python'', [''-c'', ''import subprocess; subprocess.run([\"codex\",\"exec\"])''])"',
                'node -e "require(''child_process'').spawnSync(''forfiles.exe'', [''/p'', ''.'', ''/m'', ''VERSION'', ''/c'', ''cmd /c codex exec''])"',
                'python -c "import subprocess; subprocess.run([''git'',''-c'',''diff.external=codex exec'',''diff'',''--ext-diff'',''--no-index'',''C:/Windows/win.ini'',''C:/Windows/System32/drivers/etc/hosts''])"',
                'python -c "import importlib,types; box=types.SimpleNamespace(); box.loader=importlib; box.loader.import_module(''subprocess'').run([''codex'',''exec''])"',
                'python -c "import importlib; box=[None]; box[0]=importlib; box[0].import_module(''subprocess'').run([''codex'',''exec''])"',
                'python -c "import importlib,types; box=types.SimpleNamespace(); box.__dict__[''loader'']=importlib; box.__dict__[''loader''].import_module(''subprocess'').run([''codex'',''exec''])"',
                'node -e "require(''child_process'').spawnSync(''sh'', [''-c'', ''co""dex.cmd exec''])"',
                'python -c "import subprocess; subprocess.run([''git'',''grep'',''-Ocodex exec --help'',''-e'',''^'',''--'',''.gitignore''])"',
                'python -c "import subprocess; subprocess.run([''git'',''grep'',''--open-files-in-page=codex exec --help'',''-e'',''^'',''--'',''.gitignore''])"',
                'python -c "import os,subprocess; os.environ[''GIT_ALLOW_PROTOCOL'']=''ext''; subprocess.run([''git'',''remote'',''show'',''ext::codex exec --help''])"',
                'python -c "import os,subprocess; os.environ[''GIT_ALLOW_PROTOCOL'']=''ext''; os.environ[''GIT_CONFIG_COUNT'']=''1''; os.environ[''GIT_CONFIG_KEY_0'']=''remote.safe.url''; os.environ[''GIT_CONFIG_VALUE_0'']=''ext::codex exec --help''; subprocess.run([''git'',''remote'',''show'',''safe''])"',
                'node -e "require(''child_process'').spawnSync(''bash'', [''-lc'', ''c""odex exec''])"',
                'node -e "require(''child_process'').spawnSync(''bash'', [''-lc'', ''co?ex.cmd exec''])"',
                'python -c "import sys; sys.modules[''importlib''].import_module(''subprocess'').run([''codex'',''exec''])"',
                'python -c "import sys; sys.modules.get(''builtins'').__import__(''subprocess'').run([''codex'',''exec''])"',
                'python -c "import sys; sys.modules[''import''+''lib''].import_module(''subprocess'').run([''codex'',''exec''])"',
                'node -e "require(''child_process'').spawnSync(''bash'', [''-lc'', ''hash -p /tmp/codex.cmd helper; helper exec''])"',
                'python -c "import os,subprocess; os.environ[''GIT_CONFIG_COUNT'']=''1''; os.environ[''GIT_CONFIG_KEY_0'']=''core.fsmonitor''; os.environ[''GIT_CONFIG_VALUE_0'']=''codex exec --help''; subprocess.run([''git'',''status'',''--short''])"',
                'python -c "import os,subprocess,operator; operator.setitem(os.environ,''GIT_CONFIG_COUNT'',''1''); operator.setitem(os.environ,''GIT_CONFIG_KEY_0'',''core.fsmonitor''); operator.setitem(os.environ,''GIT_CONFIG_VALUE_0'',''codex exec --help''); subprocess.run([''git'',''status'',''--short''])"',
                'python -c "import os,subprocess; from operator import setitem as assign; assign(os.environ,''GIT_CONFIG_COUNT'',''1''); assign(os.environ,''GIT_CONFIG_KEY_0'',''core.fsmonitor''); assign(os.environ,''GIT_CONFIG_VALUE_0'',''codex exec --help''); subprocess.run([''git'',''status'',''--short''])"',
                'python -c "import ctypes; ctypes.CDLL(''msvcrt.dll'').system(b''codex exec'')"',
                'python -c "getattr(globals()[''__builtins__''],''__import__'')(''subprocess'').run([''codex'',''exec''])"',
                'python -c "import os; os.__dict__[''system''](''codex exec'')"',
                'python -c "import os as operating; operating.__dict__[''popen''](''codex exec'')"',
                'python -c "import os; os.startfile(''codex.cmd'', arguments=''exec'')"',
                'python -c "from os import startfile as launch; launch(''codex.cmd'', arguments=''exec'')"',
                $returnCapabilityCommand,
                $multilineComprehensionCommand,
                $longLoaderGapCommand
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if (-not $result.OutputObject) { $unexpectedAllowed += $command }
        }

        $unexpectedDenied = @()
        foreach ($command in @(
                'python -c "import importlib.util; print(importlib.util.find_spec(''json'').name)"',
                'python -c "import importlib.metadata; print(importlib.metadata.version(''pip''))"',
                'python -c "import builtins; print(builtins.__import__(''json'').dumps({''ok'':True}))"',
                'python -c "import builtins as b; print(b.__import__(''json.encoder'').__name__)"',
                'python -c "from builtins import __import__ as load; print(load(''json'').dumps({''ok'':True}))"',
                'python -c "import importlib; print((importlib.import_module)(''json'').dumps({''ok'':True}))"',
                'python -c "import importlib; print((importlib).import_module(''json'').dumps({''ok'':True}))"',
                'python -c "import builtins; print((builtins).__import__(''json'').dumps({''ok'':True}))"',
                'python -c "import builtins; print(getattr(builtins,''__import__'')(''json'').dumps({''ok'':True}))"',
                'python -c "import builtins; print(builtins.__dict__.get(''__import__'')(''json'').dumps({''ok'':True}))"',
                'python -c "label=''builtins importlib __import__''; print(label)"',
                'python -c "import builtins; print(builtins.__name__)"',
                'python -c "print((name := ''json''))"',
                'python -c "print([name.upper() for name in [''json'']])"',
                'python -c "print([name.upper() for (name,) in [(''json'',)]])"',
                'node -e "require(''child_process'').spawnSync(''python'', [''-c'', ''print(\"read-only\")''])"',
                'node -e "require(''child_process'').spawnSync(''git'', [''status'',''--short''])"',
                'node -e "require(''child_process'').spawnSync(''echo'', [''read-only''])"',
                'python -c "import json,types; box=types.SimpleNamespace(); box.module=json; print(box.module.dumps({''ok'':True}))"',
                'node -e "require(''child_process'').spawnSync(''sh'', [''-c'', ''co""dex.cmd --version''])"',
                'python -c "import subprocess; subprocess.run([''git'',''grep'',''-e'',''codex'',''--'',''.gitignore''])"',
                'python -c "import subprocess; subprocess.run([''git'',''remote'',''show'',''-n'',''origin''])"',
                'python -c "import sys,json; sys.modules[''json'']=json; print(sys.modules[''json''].dumps({''ok'':True}))"',
                $safeReturnCommand
            )) {
            $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{ command = $command }
            if ($result.OutputObject) { $unexpectedDenied += $command }
        }

        @(
            if ($unexpectedAllowed.Count -gt 0) { 'allowed unexpectedly: ' + ($unexpectedAllowed -join ' | ') }
            if ($unexpectedDenied.Count -gt 0) { 'denied unexpectedly: ' + ($unexpectedDenied -join ' | ') }
        ) | Should -BeNullOrEmpty
    }

    It 'TASK-783 C09 denies PowerShell block cwd changes to an unreviewed managed target' {
        $fixture = New-GateFixture
        $script:FixtureRoot = $fixture.Root
        $target = New-GateTargetRepo -Root $fixture.Root -Name 'powershell-target'
        Set-GatePass -RepoRoot $fixture.RepoRoot -Branch $fixture.Branch
        $result = & $script:InvokeOrchestraGate -RepoRoot $fixture.RepoRoot -ToolName 'Bash' -ToolInput @{
            command = ('pwsh -Command "if ($true) {{ Set-Location ''{0}''; git commit -m x }}"' -f $target.RepoRoot)
        }

        & $script:AssertDenyResult -Result $result
    }
}
