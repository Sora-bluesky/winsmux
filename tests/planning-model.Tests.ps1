$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Write-PlanningModelDurably' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\winsmux-core\scripts\planning-model.ps1')
        $script:Command = Get-Command -Name 'Write-PlanningModelDurably' -ErrorAction Stop
    }

    BeforeEach {
        $script:FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('winsmux-planning-model-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:FixtureRoot)
    }

    AfterEach {
        if ([IO.Directory]::Exists($script:FixtureRoot)) {
            [IO.Directory]::Delete($script:FixtureRoot, $true)
        }
    }

    It 'exposes Write-PlanningModelDurably from the exact dot-source' {
        $script:Command.Name | Should -BeExactly 'Write-PlanningModelDurably'
        $script:Command.Parameters.ContainsKey('LiteralPath') | Should -BeTrue
        $script:Command.Parameters.ContainsKey('Content') | Should -BeTrue
    }

    It 'creates a missing destination with the exact requested content' {
        $dest = Join-Path $script:FixtureRoot 'created.txt'
        Write-PlanningModelDurably -LiteralPath $dest -Content 'exact-bytes'
        [IO.File]::ReadAllText($dest, [Text.UTF8Encoding]::new($false)) | Should -BeExactly 'exact-bytes'
        @(Get-ChildItem -LiteralPath $script:FixtureRoot -Force).Name | Should -BeExactly @('created.txt')
    }

    It 'replaces an existing destination completely' {
        $dest = Join-Path $script:FixtureRoot 'replaced.txt'
        [IO.File]::WriteAllText($dest, 'old-content', [Text.UTF8Encoding]::new($false))
        Write-PlanningModelDurably -LiteralPath $dest -Content 'new-content'
        [IO.File]::ReadAllText($dest, [Text.UTF8Encoding]::new($false)) | Should -BeExactly 'new-content'
        @(Get-ChildItem -LiteralPath $script:FixtureRoot -Force).Name | Should -BeExactly @('replaced.txt')
    }

    It 'treats wildcard characters in a filename literally' {
        $dest = Join-Path $script:FixtureRoot 'file[1].txt'
        Write-PlanningModelDurably -LiteralPath $dest -Content 'literal-brackets'
        Test-Path -LiteralPath $dest -PathType Leaf | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:FixtureRoot -Force).Name | Should -BeExactly @('file[1].txt')
        [IO.File]::ReadAllText($dest, [Text.UTF8Encoding]::new($false)) | Should -BeExactly 'literal-brackets'
    }

    It 'writes UTF-8 without BOM and does not add a newline' {
        $dest = Join-Path $script:FixtureRoot 'utf8.txt'
        Write-PlanningModelDurably -LiteralPath $dest -Content 'a'
        $bytes = [IO.File]::ReadAllBytes($dest)
        $bytes.Length | Should -Be 1
        $bytes[0] | Should -Be 97
    }

    It 'preserves the previous destination when publication fails and removes the staging file' {
        $dest = Join-Path $script:FixtureRoot 'locked.txt'
        [IO.File]::WriteAllText($dest, 'keep-me', [Text.UTF8Encoding]::new($false))
        $lock = [IO.File]::Open($dest, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            { Write-PlanningModelDurably -LiteralPath $dest -Content 'should-not-land' } | Should -Throw
        } finally {
            $lock.Dispose()
        }
        [IO.File]::ReadAllText($dest, [Text.UTF8Encoding]::new($false)) | Should -BeExactly 'keep-me'
        @(Get-ChildItem -LiteralPath $script:FixtureRoot -Force).Name | Should -BeExactly @('locked.txt')
    }
}
