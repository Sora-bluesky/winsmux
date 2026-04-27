Describe 'codex subagent worktree guard' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:GuardScript = Join-Path $script:RepoRoot 'scripts/codex-subagent-worktree-guard.ps1'
    }

    It 'denies the shared operator checkout' {
        $output = & pwsh -NoProfile -File $script:GuardScript -RepoRoot $script:RepoRoot -WorktreePath $script:RepoRoot -Json | ConvertFrom-Json
        $LASTEXITCODE | Should -Be 1
        $output.ok | Should -BeFalse
        $output.reason | Should -Match 'shared operator checkout'
        $output.reason | Should -Match '#666'
    }

    It 'allows a dedicated git worktree' {
        $repo = Join-Path $TestDrive 'repo'
        $worker = Join-Path $TestDrive 'worker'
        New-Item -ItemType Directory -Path $repo | Out-Null
        & git -C $repo init | Out-Null
        & git -C $repo config user.name 'winsmux-test' | Out-Null
        & git -C $repo config user.email 'winsmux-test@example.invalid' | Out-Null
        Set-Content -Path (Join-Path $repo 'README.md') -Value 'test repo'
        & git -C $repo add README.md | Out-Null
        & git -C $repo commit -m 'initial commit' | Out-Null
        & git -C $repo worktree add -b worker $worker | Out-Null

        $output = & pwsh -NoProfile -File $script:GuardScript -RepoRoot $repo -WorktreePath $worker -Json | ConvertFrom-Json

        $LASTEXITCODE | Should -Be 0
        $output.ok | Should -BeTrue
        $output.reason | Should -Be 'dedicated git worktree confirmed'
        $output.worktree_root | Should -Be ([System.IO.Path]::GetFullPath($worker))
    }

    It 'returns json when git metadata cannot be read' {
        $notRepo = Join-Path $TestDrive 'not-repo'
        New-Item -ItemType Directory -Path $notRepo | Out-Null

        $output = & pwsh -NoProfile -File $script:GuardScript -RepoRoot $script:RepoRoot -WorktreePath $notRepo -Json | ConvertFrom-Json

        $LASTEXITCODE | Should -Be 1
        $output.ok | Should -BeFalse
        $output.reason | Should -Match 'git metadata probe failed'
        $output.worktree_root | Should -Be ''
        $output.git_dir | Should -Be ''
    }

    It 'requires the operator repo root when the target is the current linked checkout' {
        $repo = Join-Path $TestDrive 'repo-current-linked'
        $worker = Join-Path $TestDrive 'worker-current-linked'
        New-Item -ItemType Directory -Path $repo | Out-Null
        & git -C $repo init | Out-Null
        & git -C $repo config user.name 'winsmux-test' | Out-Null
        & git -C $repo config user.email 'winsmux-test@example.invalid' | Out-Null
        Set-Content -Path (Join-Path $repo 'README.md') -Value 'test repo'
        & git -C $repo add README.md | Out-Null
        & git -C $repo commit -m 'initial commit' | Out-Null
        & git -C $repo worktree add -b worker-current-linked $worker | Out-Null

        $output = & pwsh -NoProfile -File $script:GuardScript -RepoRoot $worker -WorktreePath $worker -Json | ConvertFrom-Json

        $LASTEXITCODE | Should -Be 1
        $output.ok | Should -BeFalse
        $output.reason | Should -Match 'shared operator checkout'
        $output.worktree_root | Should -Be ([System.IO.Path]::GetFullPath($worker))
    }
}
