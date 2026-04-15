$ErrorActionPreference = 'Stop'

Describe 'harness-check contract' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:HarnessCheckPath = Join-Path $script:RepoRoot 'winsmux-core\scripts\harness-check.ps1'
        $script:WinsmuxCorePath = Join-Path $script:RepoRoot 'scripts\winsmux-core.ps1'
        $script:SettingsLocalPath = Join-Path $script:RepoRoot '.claude\settings.local.json'

        $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $pwshCommand) {
            throw 'pwsh was not found in PATH.'
        }

        $script:PwshPath = if ($pwshCommand.Path) { $pwshCommand.Path } else { $pwshCommand.Name }

        function Write-TestFileWithCmd {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)][string]$Content
            )

            $parent = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            $escapedPath = $Path -replace '"', '""'
            $Content | cmd /d /c ('more > "{0}"' -f $escapedPath) | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "cmd.exe failed to write $Path"
            }
        }

        function Remove-TestSettingsLocal {
            if (Test-Path -LiteralPath $script:SettingsLocalPath -PathType Leaf) {
                Remove-Item -LiteralPath $script:SettingsLocalPath -Force
            }

            & git -C $script:RepoRoot rm --cached --force --quiet -- '.claude/settings.local.json' 2>$null
            $null = $LASTEXITCODE
        }

        function Invoke-HarnessCheckJson {
            param([string[]]$Arguments)

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:PwshPath
            $startInfo.ArgumentList.Add('-NoProfile')
            $startInfo.ArgumentList.Add('-File')
            $startInfo.ArgumentList.Add($script:HarnessCheckPath)
            foreach ($argument in $Arguments) {
                $startInfo.ArgumentList.Add($argument)
            }
            $startInfo.WorkingDirectory = $script:RepoRoot
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true

            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                $exitCode = $process.ExitCode
            } finally {
                $process.Dispose()
            }

            $trimmedStdout = $stdout.Trim()
            $parsed = $null
            if (-not [string]::IsNullOrWhiteSpace($trimmedStdout)) {
                $parsed = $trimmedStdout | ConvertFrom-Json -Depth 16
            }

            [PSCustomObject]@{
                ExitCode = $exitCode
                StdOut   = $trimmedStdout
                StdErr   = $stderr.Trim()
                Json     = $parsed
            }
        }
    }

    BeforeEach {
        Remove-TestSettingsLocal
    }

    AfterEach {
        Remove-TestSettingsLocal
    }

    AfterAll {
        Remove-TestSettingsLocal
    }

    It 'passes against the current repository contract' {
        $result = Invoke-HarnessCheckJson -Arguments @('-ProjectDir', $script:RepoRoot, '-AsJson')

        $result.ExitCode | Should -Be 0
        $result.Json.passed | Should -Be $true
        ($result.Json.results | Where-Object { -not $_.passed }).Count | Should -Be 0
    }

    It 'fails when settings.local.json registers hooks' {
        Write-TestFileWithCmd -Path $script:SettingsLocalPath -Content '{"hooks":{"PreToolUse":[]}}'

        $result = Invoke-HarnessCheckJson -Arguments @('-ProjectDir', $script:RepoRoot, '-AsJson')
        $settingsLocalRecord = $result.Json.results | Where-Object { $_.name -eq 'settings-local-has-no-hooks' } | Select-Object -First 1

        $result.ExitCode | Should -Be 1
        $result.Json.passed | Should -Be $false
        $settingsLocalRecord.passed | Should -Be $false
        $settingsLocalRecord.message | Should -Match 'must not register hooks'
    }

    It 'fails when settings.local.json becomes tracked' {
        Write-TestFileWithCmd -Path $script:SettingsLocalPath -Content '{}'
        & git -C $script:RepoRoot add -f -- '.claude/settings.local.json'
        if ($LASTEXITCODE -ne 0) {
            throw 'git add failed for .claude/settings.local.json'
        }

        $result = Invoke-HarnessCheckJson -Arguments @('-ProjectDir', $script:RepoRoot, '-AsJson')
        $trackedRecord = $result.Json.results | Where-Object { $_.name -eq 'settings-local-not-tracked' } | Select-Object -First 1

        $result.ExitCode | Should -Be 1
        $result.Json.passed | Should -Be $false
        $trackedRecord.passed | Should -Be $false
        $trackedRecord.message | Should -Match 'must stay untracked'
    }

    It 'is exposed through winsmux-core as harness-check --json' {
        $stdout = & $script:PwshPath -NoProfile -File $script:WinsmuxCorePath harness-check --json 2>&1
        $exitCode = $LASTEXITCODE
        $json = (($stdout | Out-String).Trim() | ConvertFrom-Json -Depth 16)

        $exitCode | Should -Be 0
        $json.passed | Should -Be $true
    }
}
