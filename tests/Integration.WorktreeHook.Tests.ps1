$ErrorActionPreference = 'Stop'

Describe 'sh-worktree integration' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:SourceHookRoot = Join-Path $script:RepoRoot '.claude\hooks'
        $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $nodeCommand) {
            throw 'node was not found in PATH.'
        }

        $script:NodePath = if ($nodeCommand.Path) { $nodeCommand.Path } else { $nodeCommand.Name }

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
            $fixtureRoot = Join-Path $script:RepoRoot '.tmp-worktree-hook-tests' ([guid]::NewGuid().ToString('N'))
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

            & git -C $repoRoot init | Out-Null
            & git -C $repoRoot add .
            & git -C $repoRoot -c user.name='Test User' -c user.email='test@example.com' commit -m 'init' | Out-Null

            return [PSCustomObject]@{
                Root           = $fixtureRoot
                RepoRoot       = $repoRoot
                WorktreeTarget = $worktreeTarget
            }
        }
    }

    AfterEach {
        if ($script:FixtureRoot -and (Test-Path $script:FixtureRoot)) {
            Remove-Item -Path $script:FixtureRoot -Recurse -Force
        }
        $script:FixtureRoot = $null
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

        $result.ExitCode | Should -Be 0
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

        $createResult.ExitCode | Should -Be 0

        $ledgerDir = Join-Path $fixture.WorktreeTarget '.shield-harness\logs'
        New-Item -ItemType Directory -Path $ledgerDir -Force | Out-Null
        Set-Content -Path (Join-Path $ledgerDir 'evidence-ledger.jsonl') -Value '{"event":"child-entry"}' -Encoding UTF8

        $removeResult = Invoke-WorktreeHook -RepoRoot $fixture.RepoRoot -Payload @{
            hook_event_name = 'WorktreeRemove'
            session_id      = 'session-2'
            cwd             = $fixture.RepoRoot
            worktree_path   = $fixture.WorktreeTarget
        }

        $removeResult.ExitCode | Should -Be 0
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
