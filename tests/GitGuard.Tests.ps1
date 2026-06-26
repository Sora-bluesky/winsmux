$ErrorActionPreference = 'Stop'

Describe 'git-guard stale main protection' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:GitGuard = Join-Path $script:RepoRoot 'scripts/git-guard.ps1'

        function Invoke-TestGit {
            param(
                [Parameter(Mandatory = $true)][string]$Cwd,
                [Parameter(Mandatory = $true)][string[]]$Arguments
            )

            $output = & git -C $Cwd @Arguments 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "git $($Arguments -join ' ') failed in ${Cwd}: $($output -join "`n")"
            }
            return $output
        }

        function Initialize-GuardRepoPair {
            $root = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
            $remote = Join-Path $root 'remote.git'
            $operator = Join-Path $root 'operator'
            $peer = Join-Path $root 'peer'

            New-Item -ItemType Directory -Force -Path $root | Out-Null
            & git init --bare $remote | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'failed to initialize bare remote' }

            & git clone $remote $operator | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'failed to clone operator repo' }
            Invoke-TestGit -Cwd $operator -Arguments @('config', 'user.email', 'winsmux-tests@example.invalid') | Out-Null
            Invoke-TestGit -Cwd $operator -Arguments @('config', 'user.name', 'winsmux tests') | Out-Null
            Set-Content -LiteralPath (Join-Path $operator 'tracked.txt') -Value 'one' -Encoding UTF8
            Invoke-TestGit -Cwd $operator -Arguments @('add', 'tracked.txt') | Out-Null
            Invoke-TestGit -Cwd $operator -Arguments @('commit', '-m', 'test: seed repo') | Out-Null
            Invoke-TestGit -Cwd $operator -Arguments @('branch', '-M', 'main') | Out-Null
            Invoke-TestGit -Cwd $operator -Arguments @('push', '-u', 'origin', 'main') | Out-Null

            & git clone $remote $peer | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'failed to clone peer repo' }
            Invoke-TestGit -Cwd $peer -Arguments @('config', 'user.email', 'winsmux-tests@example.invalid') | Out-Null
            Invoke-TestGit -Cwd $peer -Arguments @('config', 'user.name', 'winsmux tests') | Out-Null
            Set-Content -LiteralPath (Join-Path $peer 'tracked.txt') -Value 'two' -Encoding UTF8
            Invoke-TestGit -Cwd $peer -Arguments @('add', 'tracked.txt') | Out-Null
            Invoke-TestGit -Cwd $peer -Arguments @('commit', '-m', 'test: advance remote') | Out-Null
            Invoke-TestGit -Cwd $peer -Arguments @('push', 'origin', 'main') | Out-Null
            Invoke-TestGit -Cwd $operator -Arguments @('fetch', 'origin') | Out-Null

            return [pscustomobject]@{
                Root     = $root
                Remote   = $remote
                Operator = $operator
                Peer     = $peer
            }
        }
    }

    It 'blocks local main when upstream is ahead and tracked files are modified' {
        $repos = Initialize-GuardRepoPair
        Set-Content -LiteralPath (Join-Path $repos.Operator 'tracked.txt') -Value 'local stale edit' -Encoding UTF8

        Push-Location -LiteralPath $repos.Operator
        try {
            $output = @(& pwsh -NoProfile -File $script:GitGuard -Mode staged 2>&1)
            $LASTEXITCODE | Should -Be 1
            ($output -join "`n") | Should -Match 'local main is 1 commit\(s\) behind origin/main'
            ($output -join "`n") | Should -Match 'fast-forward main before interpreting or committing local diffs'
        } finally {
            Pop-Location
        }
    }

    It 'allows clean local main even when upstream is ahead' {
        $repos = Initialize-GuardRepoPair

        Push-Location -LiteralPath $repos.Operator
        try {
            $output = @(& pwsh -NoProfile -File $script:GitGuard -Mode staged 2>&1)
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match 'git-guard passed'
        } finally {
            Pop-Location
        }
    }
}
