$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Integrated release boundary for version bumping' {
    BeforeAll {
        $script:BumpSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/bump-version.ps1'
        $script:PwshPath = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source

        function Invoke-BumpFixture {
            param([string[]]$BumpArguments)
            $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            foreach ($directory in @('scripts', 'winsmux-core/scripts', 'bin')) {
                [void][IO.Directory]::CreateDirectory((Join-Path $fixture $directory))
            }
            Copy-Item -LiteralPath $script:BumpSource -Destination (Join-Path $fixture 'scripts/bump-version.ps1')
            [IO.File]::WriteAllText((Join-Path $fixture 'VERSION'), '0.37.0')
            [IO.File]::WriteAllText((Join-Path $fixture 'backlog.yaml'), '')
            [IO.File]::WriteAllText((Join-Path $fixture 'winsmux-core/scripts/planning-paths.ps1'), @'
function Resolve-WinsmuxPlanningFilePath {
    param($RepoRoot, $LocalRelativePath, $EnvironmentVariable, $DefaultFileName)
    Join-Path $RepoRoot $DefaultFileName
}
'@)
            [IO.File]::WriteAllText((Join-Path $fixture 'winsmux-core/scripts/sync-roadmap.ps1'), 'exit 0')
            [IO.File]::WriteAllText((Join-Path $fixture 'scripts/winsmux-core.ps1'), 'exit 77')
            [IO.File]::WriteAllText((Join-Path $fixture 'bin/record.ps1'), @'
param([string]$Program)
[IO.File]::AppendAllText($env:BUMP_FIXTURE_CALLS, (@($Program) + $args -join ' ') + "`n")
if ($Program -eq 'gh' -and $args[0] -eq 'pr') { 'https://example.invalid/pull/1' }
exit 0
'@)
            foreach ($program in @('git', 'gh')) {
                $shim = '@"{0}" -NoProfile -File "%~dp0record.ps1" {1} %*' -f $script:PwshPath, $program
                [IO.File]::WriteAllText((Join-Path $fixture "bin/$program.cmd"), $shim + "`n")
            }
            $callsPath = Join-Path $fixture 'calls.txt'
            $start = [Diagnostics.ProcessStartInfo]::new($script:PwshPath)
            foreach ($argument in @('-NoProfile', '-File', (Join-Path $fixture 'scripts/bump-version.ps1')) + $BumpArguments) {
                $start.ArgumentList.Add($argument)
            }
            $start.Environment['PATH'] = (Join-Path $fixture 'bin') + [IO.Path]::PathSeparator + $env:PATH
            $start.Environment['BUMP_FIXTURE_CALLS'] = $callsPath
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($start)
            try {
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(60000)) {
                    $process.Kill($true)
                    throw 'Version bump fixture exceeded 60 seconds.'
                }
                [pscustomobject]@{
                    ExitCode = $process.ExitCode
                    Output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
                    Calls = @(if (Test-Path -LiteralPath $callsPath) { Get-Content -LiteralPath $callsPath })
                    Version = [IO.File]::ReadAllText((Join-Path $fixture 'VERSION'))
                }
            } finally { $process.Dispose() }
        }
    }

    It 'refuses v0.38.0 before any Git or gh call or version write' {
        $result = Invoke-BumpFixture -BumpArguments @('-Version', '0.38.0')
        $result.Calls | Should -BeNullOrEmpty
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'integrated publication'
        $result.Version | Should -BeExactly '0.37.0'
    }

    It 'allows explicit synchronization of v0.38.0 without Git or gh' {
        $result = Invoke-BumpFixture -BumpArguments @('-Version', '0.38.0', '-SyncOnly')
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Calls | Should -BeNullOrEmpty
        $result.Version | Should -BeExactly '0.38.0'
    }

    It 'keeps implicit synchronization without Git or gh' {
        $result = Invoke-BumpFixture -BumpArguments @()
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Calls | Should -BeNullOrEmpty
        $result.Version | Should -BeExactly '0.37.0'
    }

    It 'preserves the existing release route for other versions' {
        $result = Invoke-BumpFixture -BumpArguments @('-Version', '9.9.9')
        $result.Calls | Should -Contain 'git checkout -b release/v9.9.9'
        $result.Output | Should -Match 'verify failed'
        $result.Version | Should -BeExactly '9.9.9'
    }
}
