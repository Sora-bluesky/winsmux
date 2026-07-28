#Requires -Version 7.6

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:runtimeResults = @{}

    function Get-FirstSourceLine {
        param([Parameter(Mandatory)][string]$Path)

        return [string](Get-Content -LiteralPath $Path -Encoding UTF8 -TotalCount 1)
    }

    function Write-Utf8NoBom {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Content
        )

        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [System.IO.File]::WriteAllText(
            $Path,
            $Content,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    function Invoke-MinimumRuntimeFixture {
        param(
            [Parameter(Mandatory)]
            [ValidateSet('default', 'serial', 'coverage')]
            [string]$Mode,
            [Parameter(Mandatory)][string]$FixtureRoot
        )

        if (Test-Path -LiteralPath $FixtureRoot) {
            Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
        }

        $scriptsRoot = Join-Path $FixtureRoot 'scripts'
        $testsRoot = Join-Path $FixtureRoot 'tests'
        $bridgeRoot = Join-Path $testsRoot 'bridge'
        $workflowRoot = Join-Path $FixtureRoot '.github\workflows'
        New-Item -ItemType Directory -Path $scriptsRoot, $testsRoot, $bridgeRoot, $workflowRoot -Force | Out-Null

        Copy-Item -LiteralPath (Join-Path $script:repoRoot 'scripts\run-tests.ps1') -Destination (Join-Path $scriptsRoot 'run-tests.ps1')
        Write-Utf8NoBom -Path (Join-Path $scriptsRoot 'probe.ps1') -Content @'
function Get-RuntimeContractProbe {
    return 'runtime-contract-ok'
}
'@
        Write-Utf8NoBom -Path (Join-Path $testsRoot 'RuntimeProbe.Tests.ps1') -Content @'
Describe 'runtime contract probe' {
    It 'passes a non-bridge test' {
        1 | Should -Be 1
    }
}
'@

        $workflowLines = [System.Collections.Generic.List[string]]::new()
        $workflowLines.Add('jobs:')
        $workflowLines.Add('  pester-tests:')
        $workflowLines.Add('    strategy:')
        $workflowLines.Add('      matrix:')
        $workflowLines.Add('        include:')
        for ($index = 1; $index -le 13; $index++) {
            $suffix = '{0:d2}' -f $index
            $testName = "Bridge$suffix.Tests.ps1"
            Write-Utf8NoBom -Path (Join-Path $bridgeRoot $testName) -Content @"
Describe 'bridge runtime contract $suffix' {
    It 'passes bridge shard $suffix' {
        1 | Should -Be 1
    }
}
"@
            $workflowLines.Add("          - name: bridge-runtime-$suffix")
            $workflowLines.Add("            paths: tests/bridge/$testName")
        }
        Write-Utf8NoBom -Path (Join-Path $workflowRoot 'test.yml') -Content (($workflowLines -join "`n") + "`n")

        $resultsRoot = Join-Path $FixtureRoot 'results'
        $runnerPath = Join-Path $scriptsRoot 'run-tests.ps1'
        $pwshCommand = Get-Command pwsh -ErrorAction Stop | Select-Object -First 1
        $arguments = @(
            '-NoProfile',
            '-File',
            $runnerPath,
            '-ResultsDirectory',
            $resultsRoot,
            '-WorkerTimeoutSeconds',
            '120'
        )
        switch ($Mode) {
            'default' {
                $arguments += @('-Parallel', '-MaxParallel', '2')
            }
            'serial' {
                $arguments += '-Parallel:$false'
            }
            'coverage' {
                $arguments += @('-Coverage', '-CoverageThreshold', '0', '-Parallel:$false')
            }
        }

        try {
            $output = @(& $pwshCommand.Source @arguments 2>&1 | ForEach-Object { $_.ToString() })
            $exitCode = $LASTEXITCODE
            $summaryPath = Join-Path $resultsRoot 'summary.json'
            $summary = if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
                Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            } else {
                $null
            }
            return [pscustomobject]@{
                mode = $Mode
                exit_code = $exitCode
                output = $output
                summary = $summary
                powershell_version = $PSVersionTable.PSVersion.ToString()
                dotnet_version = [System.Environment]::Version.ToString()
            }
        }
        finally {
            if (Test-Path -LiteralPath $FixtureRoot) {
                Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
            }
        }
    }

    function Get-MinimumRuntimeResult {
        param(
            [Parameter(Mandatory)]
            [ValidateSet('default', 'serial', 'coverage')]
            [string]$Mode,
            [Parameter(Mandatory)][string]$TestDriveRoot
        )

        if (-not $script:runtimeResults.ContainsKey($Mode)) {
            $script:runtimeResults[$Mode] = Invoke-MinimumRuntimeFixture `
                -Mode $Mode `
                -FixtureRoot (Join-Path $TestDriveRoot "runtime-$Mode")
        }
        return $script:runtimeResults[$Mode]
    }
}

Describe 'TASK-797 official Pester developer runtime contract' {
    It 'RT01-default-min-runtime executes the canonical default runner on PowerShell 7.6' {
        Get-FirstSourceLine -Path (Join-Path $script:repoRoot 'scripts\run-tests.ps1') |
            Should -BeExactly '#Requires -Version 7.6'
        $PSVersionTable.PSVersion | Should -BeGreaterOrEqual ([version]'7.6')

        $result = Get-MinimumRuntimeResult -Mode default -TestDriveRoot $TestDrive
        $result.exit_code | Should -Be 0 -Because ($result.output -join [Environment]::NewLine)
        $result.summary | Should -Not -BeNullOrEmpty
        $result.summary.parallel | Should -BeTrue
        [int]$result.summary.passed | Should -Be 14
        [int]$result.summary.failed | Should -Be 0
        [int]$result.summary.total | Should -Be 14
        [string]$result.summary.identityHash | Should -Not -BeNullOrEmpty
    }

    It 'RT02-serial-min-runtime executes the canonical serial runner on PowerShell 7.6' {
        Get-FirstSourceLine -Path (Join-Path $script:repoRoot 'scripts\run-tests.ps1') |
            Should -BeExactly '#Requires -Version 7.6'

        $result = Get-MinimumRuntimeResult -Mode serial -TestDriveRoot $TestDrive
        $result.exit_code | Should -Be 0 -Because ($result.output -join [Environment]::NewLine)
        $result.summary | Should -Not -BeNullOrEmpty
        $result.summary.parallel | Should -BeFalse
        [int]$result.summary.passed | Should -Be 14
        [int]$result.summary.failed | Should -Be 0
        [int]$result.summary.total | Should -Be 14
        [string]$result.summary.identityHash | Should -Not -BeNullOrEmpty
    }

    It 'RT03-coverage-min-runtime executes coverage and preserves test identity' {
        Get-FirstSourceLine -Path (Join-Path $script:repoRoot 'scripts\run-tests.ps1') |
            Should -BeExactly '#Requires -Version 7.6'

        $coverage = Get-MinimumRuntimeResult -Mode coverage -TestDriveRoot $TestDrive
        $default = Get-MinimumRuntimeResult -Mode default -TestDriveRoot $TestDrive
        $serial = Get-MinimumRuntimeResult -Mode serial -TestDriveRoot $TestDrive
        $coverage.exit_code | Should -Be 0 -Because ($coverage.output -join [Environment]::NewLine)
        $coverage.summary | Should -Not -BeNullOrEmpty
        $coverage.summary.parallel | Should -BeFalse
        $coverage.summary.coveragePercent | Should -Not -BeNullOrEmpty
        [int]$coverage.summary.passed | Should -Be 14
        [int]$coverage.summary.failed | Should -Be 0
        [int]$coverage.summary.total | Should -Be 14
        [string]$coverage.summary.identityHash | Should -BeExactly ([string]$default.summary.identityHash)
        [string]$coverage.summary.identityHash | Should -BeExactly ([string]$serial.summary.identityHash)
    }

    It 'RT04-verify-runtime-forwarding keeps verify as a consumer of the canonical runner' {
        $verifyPath = Join-Path $script:repoRoot 'winsmux-core\scripts\verify.ps1'
        Get-FirstSourceLine -Path $verifyPath | Should -BeExactly '#Requires -Version 7.6'
        $verifySource = Get-Content -LiteralPath $verifyPath -Raw -Encoding UTF8
        $verifySource.Contains('Join-Path $ProjectDir ''scripts\run-tests.ps1''') | Should -BeTrue
        $verifySource.Contains('& $pwsh.Source -NoProfile -File $runnerPath') | Should -BeTrue
    }

    It 'RT05-runtime-contract-parity binds declarations, contributor docs, CI, and product non-goals' {
        foreach ($relativePath in @(
            'scripts\run-tests.ps1',
            'scripts\assert-pester-shard-coverage.ps1',
            'winsmux-core\scripts\verify.ps1'
        )) {
            Get-FirstSourceLine -Path (Join-Path $script:repoRoot $relativePath) |
                Should -BeExactly '#Requires -Version 7.6'
        }

        $contributing = Get-Content -LiteralPath (Join-Path $script:repoRoot 'CONTRIBUTING.md') -Raw -Encoding UTF8
        $testReadme = Get-Content -LiteralPath (Join-Path $script:repoRoot 'tests\README.md') -Raw -Encoding UTF8
        $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github\workflows\test.yml') -Raw -Encoding UTF8
        $contributing | Should -Match 'PowerShell 7\.6'
        $contributing | Should -Match 'scripts/run-tests\.ps1'
        $testReadme | Should -Match 'PowerShell 7\.6'
        $testReadme | Should -Match 'scripts/run-tests\.ps1'
        $workflow | Should -Match 'name:\s+pester-runtime-contract'
        $workflow | Should -Match 'paths:\s+tests/PesterRuntimeContract\.Tests\.ps1'

        foreach ($relativePath in @('README.md', 'README.ja.md', 'docs\installation.md', 'docs\installation.ja.md')) {
            $productDocumentation = Get-Content -LiteralPath (Join-Path $script:repoRoot $relativePath) -Raw -Encoding UTF8
            $productDocumentation | Should -Match 'PowerShell 7\+'
        }
    }

    It 'RT06-below-floor-rejected declares 7.6 before any test output or durable mutation' {
        $protectedPaths = @(
            'scripts\run-tests.ps1',
            'scripts\assert-pester-shard-coverage.ps1',
            'winsmux-core\scripts\verify.ps1'
        )
        foreach ($relativePath in $protectedPaths) {
            $path = Join-Path $script:repoRoot $relativePath
            $before = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $path,
                [ref]$tokens,
                [ref]$errors
            )
            @($errors).Count | Should -Be 0
            $ast.ScriptRequirements.RequiredPSVersion.ToString() | Should -BeExactly '7.6'
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -BeExactly $before
        }

        $resultsPath = Join-Path $TestDrive 'below-floor-results'
        $powershellCommand = Get-Command powershell.exe -ErrorAction Stop | Select-Object -First 1
        $legacyOutput = @(
            & $powershellCommand.Source -NoProfile -File (Join-Path $script:repoRoot 'scripts\run-tests.ps1') `
                -ResultsDirectory $resultsPath 2>&1 |
                ForEach-Object { $_.ToString() }
        )
        $legacyExitCode = $LASTEXITCODE
        $legacyExitCode | Should -Not -Be 0 -Because ($legacyOutput -join [Environment]::NewLine)
        Test-Path -LiteralPath $resultsPath | Should -BeFalse
    }

    It 'RT07-test-doc-entry redirects the obsolete Pester config path to the canonical runner' {
        $testReadme = Get-Content -LiteralPath (Join-Path $script:repoRoot 'tests\README.md') -Raw -Encoding UTF8
        $testReadme | Should -Not -Match 'tests/\.pester\.ps1'
        $testReadme.Contains('pwsh -NoProfile -File scripts/run-tests.ps1') | Should -BeTrue
    }

    It 'RT08-dispatch-full-suite-entry routes operator full-suite validation through the canonical runner' {
        $dispatch = Get-Content -LiteralPath (Join-Path $script:repoRoot '.claude\rules\dispatch.md') -Raw -Encoding UTF8
        $dispatch.Contains('Invoke-Pester <worktree>/tests/') | Should -BeFalse
        $dispatch.Contains('Invoke-Pester tests/') | Should -BeFalse
        $dispatch.Contains('pwsh -NoProfile -File <worktree>/scripts/run-tests.ps1 -ResultsDirectory <repo-external-results>') |
            Should -BeTrue
        $dispatch.Contains('& pwsh -NoProfile -File scripts/run-tests.ps1 -ResultsDirectory $testResults') |
            Should -BeTrue
    }
}
