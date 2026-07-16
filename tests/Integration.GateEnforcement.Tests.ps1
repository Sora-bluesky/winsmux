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

    It 'TASK-783 C20-C21 allows read-only Codex text and sanctioned companion-shaped input without name allowlists' {
        foreach ($command in @(
                'rg -n ''codex exec'' docs',
                'git grep ''codex exec'' -- docs',
                'rg -n ''git commit'' docs',
                'git grep ''gh pr merge'' -- docs',
                'node companion-runtime.js --payload ''codex exec review''',
                'node -e "require(''child_process'').spawnSync(''helper'', [''codex'', ''exec''])"',
                'python -c "import subprocess; subprocess.run([''helper'', ''codex'', ''exec''])"',
                'python -c "import subprocess; subprocess.run((''helper'', ''codex'', ''exec''))"',
                'pwsh -Command "Start-Process helper -ArgumentList codex,exec"',
                'cmd /c echo call codex exec review'
            )) {
            $result = & $script:InvokeOrchestraGate -ToolName 'Bash' -ToolInput @{ command = $command }
            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
            $result.OutputObject | Should -BeNullOrEmpty
        }
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
