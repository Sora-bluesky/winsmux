$ErrorActionPreference = 'Stop'

Describe 'sh-worktree integration' {
    BeforeAll {
        $script:FixtureBaseRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'winsmux-tests\worktree-hook'
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:SourceHookRoot = Join-Path $script:RepoRoot '.claude\hooks'
        $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $nodeCommand) {
            throw 'node was not found in PATH.'
        }

        $script:NodePath = if ($nodeCommand.Path) { $nodeCommand.Path } else { $nodeCommand.Name }

        function Get-WorktreeHookEnvironmentState {
            param([Parameter(Mandatory = $true)][string]$Name)

            return [PSCustomObject]@{
                Exists = Test-Path -LiteralPath "Env:$Name"
                Value  = [Environment]::GetEnvironmentVariable($Name, 'Process')
            }
        }

        function Restore-WorktreeHookEnvironmentState {
            param(
                [Parameter(Mandatory = $true)][string]$Name,
                [Parameter(Mandatory = $true)]$State
            )

            if ($State.Exists) {
                [Environment]::SetEnvironmentVariable($Name, [string]$State.Value, 'Process')
            } else {
                Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
            }
        }

        function Set-WorktreeHookGitIsolation {
            $env:GIT_CONFIG_GLOBAL = if (
                [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
            ) {
                'NUL'
            } else {
                '/dev/null'
            }
            $env:GIT_CONFIG_NOSYSTEM = '1'
            $env:GIT_CONFIG_COUNT = '1'
            $env:GIT_CONFIG_KEY_0 = 'init.defaultBranch'
            $env:GIT_CONFIG_VALUE_0 = 'main'
            $env:GIT_CONFIG_PARAMETERS = ''
        }

        function Invoke-CheckedFixtureGit {
            param([Parameter(Mandatory = $true)][string[]]$GitArguments)

            $output = @(& git @GitArguments 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "Fixture git command failed: git $($GitArguments -join ' ')`n$($output -join [Environment]::NewLine)"
            }
        }

        function Invoke-WorktreeHook {
            param(
                [Parameter(Mandatory = $true)][string]$RepoRoot,
                [Parameter(Mandatory = $true)][hashtable]$Payload
            )

            $hookPath = Join-Path $RepoRoot '.claude\hooks\sh-worktree.js'
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

                return [PSCustomObject]@{
                    ExitCode = $process.ExitCode
                    StdOut   = $stdout.Trim()
                    StdErr   = $stderr.Trim()
                }
            } finally {
                $process.Dispose()
            }
        }

        function New-WorktreeHookFixture {
            $fixtureRoot = Join-Path $script:FixtureBaseRoot ([guid]::NewGuid().ToString('N'))
            $repoRoot = Join-Path $fixtureRoot 'repo'
            $worktreeTarget = Join-Path $repoRoot '.worktrees\feature-auth'

            New-Item -ItemType Directory -Path (Join-Path $repoRoot '.claude\hooks\lib') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $repoRoot '.claude\patterns') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $repoRoot '.claude\rules') -Force | Out-Null

            Copy-Item (Join-Path $script:SourceHookRoot 'sh-worktree.js') (Join-Path $repoRoot '.claude\hooks\sh-worktree.js')
            Copy-Item (Join-Path $script:SourceHookRoot 'lib\sh-utils.js') (Join-Path $repoRoot '.claude\hooks\lib\sh-utils.js')

            Set-Content -Path (Join-Path $repoRoot '.claude\settings.json') -Value '{}' -Encoding UTF8
            Set-Content -Path (Join-Path $repoRoot '.claude\patterns\injection-patterns.json') -Value '{"categories":{}}' -Encoding UTF8
            Set-Content -Path (Join-Path $repoRoot '.claude\rules\sample.md') -Value '# rule' -Encoding UTF8
            Set-Content -Path (Join-Path $repoRoot '.claude\hooks\sh-extra.js') -Value 'console.log("extra");' -Encoding UTF8
            Set-Content -Path (Join-Path $repoRoot 'README.md') -Value 'fixture' -Encoding UTF8

            Invoke-CheckedFixtureGit -GitArguments @('-C', $repoRoot, 'init')
            $fixtureHooks = Join-Path $repoRoot '.git\fixture-hooks'
            New-Item -ItemType Directory -Path $fixtureHooks -Force | Out-Null
            Invoke-CheckedFixtureGit -GitArguments @(
                '-C', $repoRoot, 'config', '--local', 'core.hooksPath', $fixtureHooks
            )
            Invoke-CheckedFixtureGit -GitArguments @('-C', $repoRoot, 'add', '.')
            Invoke-CheckedFixtureGit -GitArguments @(
                '-C', $repoRoot,
                '-c', 'user.name=Test User',
                '-c', 'user.email=test@example.com',
                'commit', '-m', 'init'
            )

            return [PSCustomObject]@{
                Root           = $fixtureRoot
                RepoRoot       = $repoRoot
                WorktreeTarget = $worktreeTarget
            }
        }
    }

    BeforeEach {
        $script:GitEnvironmentStates = [ordered]@{}
        foreach ($name in @(
            'GIT_CONFIG_GLOBAL',
            'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_COUNT',
            'GIT_CONFIG_PARAMETERS',
            'GIT_CONFIG_KEY_0',
            'GIT_CONFIG_VALUE_0',
            'GIT_CONFIG_KEY_1',
            'GIT_CONFIG_VALUE_1'
        )) {
            $script:GitEnvironmentStates[$name] = Get-WorktreeHookEnvironmentState -Name $name
        }
        $script:HostileConfigRoot = Join-Path (
            [System.IO.Path]::GetTempPath()
        ) "winsmux-tests\worktree-hook-hostile\$([guid]::NewGuid().ToString('N'))"
        [System.IO.Directory]::CreateDirectory($script:HostileConfigRoot) | Out-Null
        $missingSigner = (
            Join-Path $script:HostileConfigRoot 'missing-gpg'
        ).Replace('\', '/')
        $hostileConfig = Join-Path $script:HostileConfigRoot 'global.gitconfig'
        [System.IO.File]::WriteAllText(
            $hostileConfig,
            "[commit]`n    gpgSign = true`n[gpg]`n    program = `"$missingSigner`"`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        $env:GIT_CONFIG_GLOBAL = $hostileConfig
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '2'
        $env:GIT_CONFIG_KEY_0 = 'commit.gpgSign'
        $env:GIT_CONFIG_VALUE_0 = 'true'
        $env:GIT_CONFIG_KEY_1 = 'gpg.program'
        $env:GIT_CONFIG_VALUE_1 = $missingSigner
        $env:GIT_CONFIG_PARAMETERS = (
            "'commit.gpgSign=true' 'gpg.program=$missingSigner'"
        )
        Set-WorktreeHookGitIsolation
    }

    AfterEach {
        try {
            if ($script:FixtureRoot -and (Test-Path $script:FixtureRoot)) {
                Remove-Item -Path $script:FixtureRoot -Recurse -Force
            }
            if ($script:HostileConfigRoot -and (Test-Path $script:HostileConfigRoot)) {
                Remove-Item -Path $script:HostileConfigRoot -Recurse -Force
            }
        } finally {
            foreach ($entry in $script:GitEnvironmentStates.GetEnumerator()) {
                Restore-WorktreeHookEnvironmentState -Name ([string]$entry.Key) -State $entry.Value
            }
            foreach ($entry in $script:GitEnvironmentStates.GetEnumerator()) {
                $name = [string]$entry.Key
                $state = $entry.Value
                (Test-Path -LiteralPath "Env:$name") | Should -Be $state.Exists
                if ($state.Exists) {
                    [Environment]::GetEnvironmentVariable(
                        $name,
                        'Process'
                    ) | Should -BeExactly ([string]$state.Value)
                }
            }
            $script:FixtureRoot = $null
            $script:HostileConfigRoot = $null
        }
    }

    It 'creates a git worktree and prints the absolute path on stdout' {
        $fixture = New-WorktreeHookFixture
        $script:FixtureRoot = $fixture.Root

        $result = Invoke-WorktreeHook -RepoRoot $fixture.RepoRoot -Payload @{
            hook_event_name = 'WorktreeCreate'
            session_id      = 'session-1'
            cwd             = $fixture.RepoRoot
            name            = 'feature-auth'
        }

        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $result.StdOut | Should -Be $fixture.WorktreeTarget
        Test-Path $fixture.WorktreeTarget | Should -Be $true
        Test-Path (Join-Path $fixture.WorktreeTarget '.claude\settings.json') | Should -Be $true
        Test-Path (Join-Path $fixture.WorktreeTarget '.claude\hooks\sh-extra.js') | Should -Be $true
    }

    It 'merges evidence and removes the worktree on WorktreeRemove' {
        $fixture = New-WorktreeHookFixture
        $script:FixtureRoot = $fixture.Root

        $createResult = Invoke-WorktreeHook -RepoRoot $fixture.RepoRoot -Payload @{
            hook_event_name = 'WorktreeCreate'
            session_id      = 'session-2'
            cwd             = $fixture.RepoRoot
            name            = 'feature-auth'
        }

        $createResult.ExitCode | Should -Be 0 -Because $createResult.StdErr

        $ledgerDir = Join-Path $fixture.WorktreeTarget '.shield-harness\logs'
        New-Item -ItemType Directory -Path $ledgerDir -Force | Out-Null
        Set-Content -Path (Join-Path $ledgerDir 'evidence-ledger.jsonl') -Value '{"event":"child-entry"}' -Encoding UTF8

        $removeResult = Invoke-WorktreeHook -RepoRoot $fixture.RepoRoot -Payload @{
            hook_event_name = 'WorktreeRemove'
            session_id      = 'session-2'
            cwd             = $fixture.RepoRoot
            worktree_path   = $fixture.WorktreeTarget
        }

        $removeResult.ExitCode | Should -Be 0 -Because $removeResult.StdErr
        Test-Path $fixture.WorktreeTarget | Should -Be $false

        $mergedLedgerPath = Join-Path $fixture.RepoRoot '.claude\logs\evidence-ledger.jsonl'
        Test-Path $mergedLedgerPath | Should -Be $true
        $mergedEntry = @(
            Get-Content -Path $mergedLedgerPath |
                Where-Object { $_.Trim() } |
                ForEach-Object { $_ | ConvertFrom-Json }
        ) | Where-Object { $_.event -eq 'child-entry' } | Select-Object -First 1

        $mergedEntry | Should -Not -BeNullOrEmpty
        $mergedEntry.event | Should -Be 'child-entry'
        $mergedEntry.source_worktree | Should -Be $fixture.WorktreeTarget
    }
}
