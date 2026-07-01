$ErrorActionPreference = 'Stop'

Describe 'ConvertFrom-GitWorktreeList' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\builder-worktree.ps1')
    }

    It 'parses a normal worktree entry with a branch name' {
        $content = @'
worktree C:/repo
HEAD abcdef1234567890
branch refs/heads/main

'@

        $entries = ConvertFrom-GitWorktreeList -Content $content

        $entries.Count | Should -Be 1
        $entries[0].WorktreePath | Should -Be 'C:/repo'
        $entries[0].BranchName | Should -Be 'main'
    }

    It 'parses a detached HEAD entry without throwing and leaves BranchName empty' {
        $content = @'
worktree C:/repo/.worktrees/builder-1
HEAD abcdef1234567890
detached

'@

        { ConvertFrom-GitWorktreeList -Content $content } | Should -Not -Throw

        $entries = ConvertFrom-GitWorktreeList -Content $content

        $entries.Count | Should -Be 1
        $entries[0].WorktreePath | Should -Be 'C:/repo/.worktrees/builder-1'
        $entries[0].BranchName | Should -Be ''
    }

    It 'parses mixed branch and detached worktree entries' {
        $content = @'
worktree C:/repo
HEAD 1111111111111111
branch refs/heads/main

worktree C:/repo/.worktrees/builder-1
HEAD 2222222222222222
detached

worktree C:/repo/.worktrees/builder-2
HEAD 3333333333333333
branch refs/heads/worktree-builder-2
'@

        $entries = ConvertFrom-GitWorktreeList -Content $content

        $entries.Count | Should -Be 3
        @($entries | ForEach-Object BranchName) | Should -Be @('main', '', 'worktree-builder-2')
        @($entries | ForEach-Object WorktreePath) | Should -Be @(
            'C:/repo',
            'C:/repo/.worktrees/builder-1',
            'C:/repo/.worktrees/builder-2'
        )
    }
}

Describe 'Get-BuilderWorktreeLockDiagnosticText' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\builder-worktree.ps1')
    }

    It 'reports a process whose command line references the locked worktree and excludes live desktop pollers' {
        $projectDir = Join-Path $TestDrive 'repo'
        $worktreePath = Join-Path $projectDir '.worktrees\builder-1'

        Mock Get-CimInstance {
            @(
                [PSCustomObject]@{
                    ProcessId   = 111
                    Name        = 'pwsh.exe'
                    CommandLine = "pwsh -NoProfile -File worker.ps1 -ProjectDir `"$worktreePath`""
                },
                [PSCustomObject]@{
                    ProcessId   = 222
                    Name        = 'pwsh.exe'
                    CommandLine = "pwsh -NoProfile -Command winsmux desktop-summary --stream --project `"$projectDir`""
                },
                [PSCustomObject]@{
                    ProcessId   = 333
                    Name        = 'pwsh.exe'
                    CommandLine = "pwsh -NoProfile -Command winsmux workers status all --project `"$projectDir`""
                }
            )
        }

        $text = Get-BuilderWorktreeLockDiagnosticText -WorktreePath $worktreePath -ProjectDir $projectDir

        $text | Should -Match 'owner candidates: pid=111 name=pwsh\.exe reason=command_line_matches_worktree'
        $text | Should -Not -Match 'pid=222'
        $text | Should -Not -Match 'pid=333'
    }

    It 'reports branch marker matches for registered builder worktrees' {
        $projectDir = Join-Path $TestDrive 'repo'
        $worktreePath = Join-Path $projectDir '.worktrees\builder-2'

        Mock Get-CimInstance {
            @(
                [PSCustomObject]@{
                    ProcessId   = 444
                    Name        = 'git.exe'
                    CommandLine = 'git worktree remove --force worktree-builder-2'
                }
            )
        }

        $text = Get-BuilderWorktreeLockDiagnosticText -WorktreePath $worktreePath -ProjectDir $projectDir

        $text | Should -Match 'owner candidates: pid=444 name=git\.exe reason=branch_or_worktree_marker'
    }

    It 'does not treat live desktop status pollers as lock owners' {
        $projectDir = Join-Path $TestDrive 'repo'
        $worktreePath = Join-Path $projectDir '.worktrees\builder-3'

        Mock Get-CimInstance {
            @(
                [PSCustomObject]@{
                    ProcessId   = 555
                    Name        = 'pwsh.exe'
                    CommandLine = "pwsh -NoProfile -Command winsmux desktop-summary --stream --project `"$projectDir`""
                },
                [PSCustomObject]@{
                    ProcessId   = 666
                    Name        = 'pwsh.exe'
                    CommandLine = "pwsh -NoProfile -Command winsmux workers status all --project `"$projectDir`""
                }
            )
        }

        $text = Get-BuilderWorktreeLockDiagnosticText -WorktreePath $worktreePath -ProjectDir $projectDir

        $text | Should -Match 'owner candidates: none by command line'
        $text | Should -Match 'excluded live desktop poller count=2'
    }

    It 'keeps cleanup diagnostics non-fatal when process inventory is unavailable' {
        $projectDir = Join-Path $TestDrive 'repo'
        $worktreePath = Join-Path $projectDir '.worktrees\builder-4'

        Mock Get-CimInstance {
            throw 'process inventory unavailable'
        }

        $text = Get-BuilderWorktreeLockDiagnosticText -WorktreePath $worktreePath -ProjectDir $projectDir

        $text | Should -Match 'owner candidates unavailable: process inventory unavailable'
    }
}
