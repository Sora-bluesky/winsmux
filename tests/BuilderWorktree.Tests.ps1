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
