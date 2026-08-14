#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'TASK-796 Pester Git isolation' -Tag 'integration' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:RunnerPath = Join-Path $script:RepoRoot 'scripts\run-tests.ps1'
        $script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $script:GitPath = if ($gitCommand.Path) { $gitCommand.Path } else { $gitCommand.Source }
        $pwshCommand = Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $script:PwshPath = if ($pwshCommand.Path) { $pwshCommand.Path } else { $pwshCommand.Source }
        foreach ($applicationPath in @($script:GitPath, $script:PwshPath)) {
            if (-not (Test-Path -LiteralPath $applicationPath -PathType Leaf)) {
                throw "Required application is not a file: $applicationPath"
            }
        }

        $tokens = $null
        $parseErrors = $null
        $runnerAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:RunnerPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if ($parseErrors.Count -gt 0) {
            throw "run-tests.ps1 parse failed: $($parseErrors[0].Message)"
        }
        $runnerFunctions = $runnerAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $false)
        foreach ($runnerFunction in $runnerFunctions) {
            Invoke-Expression $runnerFunction.Extent.Text
        }

        function Assert-Task796RunnerFunction {
            param([Parameter(Mandatory)][string]$Name)

            Get-Command $Name -CommandType Function -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty -Because "$Name is a TASK-796 runner responsibility"
        }

        function Get-TestPlatformEnvironment {
            $environment = [ordered]@{}
            foreach ($name in @(
                'APPDATA', 'ComSpec', 'HOME', 'LOCALAPPDATA', 'Path', 'PATHEXT',
                'ProgramData', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432',
                'PSModulePath', 'SystemDrive', 'SystemRoot', 'TEMP', 'TMP',
                'USERNAME', 'USERPROFILE', 'windir'
            )) {
                $value = [Environment]::GetEnvironmentVariable($name)
                if ($null -ne $value) { $environment[$name] = $value }
            }
            $nullDevice = if ($IsWindows) { 'NUL' } else { '/dev/null' }
            $emptyHooks = Join-Path $TestDrive 'bootstrap-hooks'
            $emptyTemplate = Join-Path $TestDrive 'bootstrap-template'
            New-Item -ItemType Directory -Path $emptyHooks, $emptyTemplate -Force | Out-Null
            $environment['GIT_CONFIG_GLOBAL'] = $nullDevice
            $environment['GIT_CONFIG_SYSTEM'] = $nullDevice
            $environment['GIT_CONFIG_NOSYSTEM'] = '1'
            $environment['GIT_CONFIG_COUNT'] = '2'
            $environment['GIT_CONFIG_KEY_0'] = 'core.hooksPath'
            $environment['GIT_CONFIG_VALUE_0'] = $emptyHooks
            $environment['GIT_CONFIG_KEY_1'] = 'init.defaultBranch'
            $environment['GIT_CONFIG_VALUE_1'] = 'main'
            $environment['GIT_TEMPLATE_DIR'] = $emptyTemplate
            $environment['GIT_TERMINAL_PROMPT'] = '0'
            return $environment
        }

        function Invoke-TestGit {
            param(
                [Parameter(Mandatory)][string]$RepositoryRoot,
                [Parameter(Mandatory)][string[]]$Arguments,
                [System.Collections.IDictionary]$Environment = (Get-TestPlatformEnvironment),
                [System.Collections.IDictionary]$ExtraEnvironment = @{},
                [switch]$AllowFailure
            )

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:GitPath
            foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
            $startInfo.WorkingDirectory = $RepositoryRoot
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.Environment.Clear()
            foreach ($entry in $Environment.GetEnumerator()) {
                $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
            }
            foreach ($entry in $ExtraEnvironment.GetEnumerator()) {
                $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
            }

            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                if (-not $AllowFailure -and $process.ExitCode -ne 0) {
                    throw "git $($Arguments -join ' ') failed ($($process.ExitCode)): $stderr"
                }
                return [PSCustomObject]@{
                    ExitCode = [int]$process.ExitCode
                    StdOut = $stdout.Trim()
                    StdErr = $stderr.Trim()
                }
            } finally {
                $process.Dispose()
            }
        }

        function Invoke-TestPowerShell {
            param(
                [Parameter(Mandatory)][string]$WorkingDirectory,
                [Parameter(Mandatory)][string[]]$Arguments,
                [System.Collections.IDictionary]$Environment = (Get-TestPlatformEnvironment),
                [System.Collections.IDictionary]$ExtraEnvironment = @{},
                [switch]$AllowFailure
            )

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:PwshPath
            foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
            $startInfo.WorkingDirectory = $WorkingDirectory
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.Environment.Clear()
            foreach ($entry in $Environment.GetEnumerator()) {
                $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
            }
            foreach ($entry in $ExtraEnvironment.GetEnumerator()) {
                $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
            }

            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                if (-not $AllowFailure -and $process.ExitCode -ne 0) {
                    throw "pwsh $($Arguments -join ' ') failed ($($process.ExitCode)): $stderr"
                }
                return [PSCustomObject]@{
                    ExitCode = [int]$process.ExitCode
                    StdOut = $stdout.Trim()
                    StdErr = $stderr.Trim()
                }
            } finally {
                $process.Dispose()
            }
        }

        function New-TestRepository {
            param([Parameter(Mandatory)][string]$Name)

            $root = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            [void](Invoke-TestGit -RepositoryRoot $root -Arguments @('init'))
            [System.IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), "base`n", $script:Utf8NoBom)
            [void](Invoke-TestGit -RepositoryRoot $root -Arguments @('add', '--', 'tracked.txt'))
            [void](Invoke-TestGit -RepositoryRoot $root -Arguments @(
                '-c', 'user.name=TASK-796 Fixture', '-c', 'user.email=task796@example.invalid',
                'commit', '-m', 'fixture base'
            ))
            return $root
        }

        function Get-FileSha256 {
            param([Parameter(Mandatory)][string]$Path)

            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<absent>' }
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        }

        function Get-EnvironmentEvidence {
            param([Parameter(Mandatory)][string[]]$Names)

            $evidence = [ordered]@{}
            foreach ($name in $Names) {
                $value = [Environment]::GetEnvironmentVariable($name, 'Process')
                $evidence[$name] = [PSCustomObject]@{
                    Exists = $null -ne $value
                    Value = $value
                }
            }
            return $evidence
        }

        function Assert-EnvironmentEvidence {
            param(
                [Parameter(Mandatory)][System.Collections.IDictionary]$Expected,
                [Parameter(Mandatory)][System.Collections.IDictionary]$Actual
            )

            foreach ($name in $Expected.Keys) {
                $Actual[$name].Exists | Should -Be $Expected[$name].Exists
                $Actual[$name].Value | Should -BeExactly $Expected[$name].Value
            }
        }

        function Write-HookScript {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string]$MarkerVariable
            )

            $content = "#!/bin/sh`n" + ('printf ''%s\n'' hook >> "$' + $MarkerVariable + '"') + "`n"
            [System.IO.File]::WriteAllText($Path, $content, $script:Utf8NoBom)
        }
    }

    BeforeEach {
        $script:CallerGitEnvironment = [ordered]@{}
        foreach ($entry in Get-ChildItem Env:) {
            if ($entry.Name -like 'GIT_*' -or $entry.Name -eq 'WINSMUX_PESTER_CANDIDATE_TREE') {
                $script:CallerGitEnvironment[$entry.Name] = [string]$entry.Value
            }
        }
    }

    AfterEach {
        foreach ($entry in @(Get-ChildItem Env:)) {
            if ($entry.Name -like 'GIT_*' -or $entry.Name -eq 'WINSMUX_PESTER_CANDIDATE_TREE') {
                Remove-Item -LiteralPath ('Env:' + $entry.Name) -ErrorAction SilentlyContinue
            }
        }
        foreach ($entry in $script:CallerGitEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
        }
    }

    It 'T796-CONTROL extracts current runner functions without executing its entry' {
        (Get-IdentityHash -Identities @('b', 'a')) |
            Should -BeExactly (Get-IdentityHash -Identities @('a', 'b'))
    }

    It 'T796-E01 creates a controlled Git environment for every child worker' {
        Assert-Task796RunnerFunction -Name 'Get-RunnerGitEnvironment'
        $hooksPath = Join-Path $TestDrive 'managed-hooks'
        $templatePath = Join-Path $TestDrive 'managed-template'
        $tree = '1234567890123456789012345678901234567890'
        $gitEnvironment = Get-RunnerGitEnvironment -HooksPath $hooksPath -TemplatePath $templatePath -CandidateTreeId $tree

        $gitEnvironment['GIT_CONFIG_GLOBAL'] | Should -Be $(if ($IsWindows) { 'NUL' } else { '/dev/null' })
        $gitEnvironment['GIT_CONFIG_SYSTEM'] | Should -Be $(if ($IsWindows) { 'NUL' } else { '/dev/null' })
        $gitEnvironment['GIT_CONFIG_NOSYSTEM'] | Should -Be '1'
        $gitEnvironment['GIT_CONFIG_PARAMETERS'] | Should -BeNullOrEmpty
        $gitEnvironment['GIT_TEMPLATE_DIR'] | Should -BeExactly $templatePath
        $gitEnvironment['WINSMUX_PESTER_CANDIDATE_TREE'] | Should -BeExactly $tree
        @($gitEnvironment.Keys | Where-Object { $_ -like 'GIT_CONFIG_KEY_*' } | ForEach-Object { $gitEnvironment[$_] }) |
            Should -Contain 'core.hooksPath'

        $child = Get-IsolatedChildEnvironment -TempDirectory $TestDrive -ProjectDirectory $TestDrive -HooksPath $hooksPath -TemplatePath $templatePath -CandidateTreeId $tree
        foreach ($entry in $gitEnvironment.GetEnumerator()) {
            $child[[string]$entry.Key] | Should -BeExactly ([string]$entry.Value)
        }
        $child.Contains('GIT_DIR') | Should -BeFalse
        $child.Contains('GIT_INDEX_FILE') | Should -BeFalse
        $child.Contains('GIT_WORK_TREE') | Should -BeFalse
    }

    It 'T796-E02 restores caller Git variables after success, including absence' {
        Assert-Task796RunnerFunction -Name 'Invoke-WithRunnerGitEnvironment'
        $names = @('GCM_INTERACTIVE', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_PARAMETERS', 'GIT_DIR', 'GIT_TASK796_CREATED', 'WINSMUX_PESTER_CANDIDATE_TREE')
        [Environment]::SetEnvironmentVariable('GCM_INTERACTIVE', 'caller-interactive', 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', 'caller-global', 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_PARAMETERS', "'caller.key'='caller value'", 'Process')
        Remove-Item -LiteralPath 'Env:GIT_DIR' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:GIT_TASK796_CREATED' -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable('WINSMUX_PESTER_CANDIDATE_TREE', 'caller-tree', 'Process')
        $before = Get-EnvironmentEvidence -Names $names
        $managed = [ordered]@{
            GCM_INTERACTIVE = 'Never'
            GIT_CONFIG_GLOBAL = 'managed-global'
            WINSMUX_PESTER_CANDIDATE_TREE = 'managed-tree'
        }

        $observed = Invoke-WithRunnerGitEnvironment -Environment $managed -ScriptBlock {
            [Environment]::SetEnvironmentVariable('GIT_TASK796_CREATED', 'created', 'Process')
            return Get-EnvironmentEvidence -Names $names
        }

        $observed['GIT_CONFIG_GLOBAL'].Value | Should -BeExactly 'managed-global'
        $observed['GCM_INTERACTIVE'].Value | Should -BeExactly 'Never'
        $observed['GIT_CONFIG_PARAMETERS'].Exists | Should -BeFalse
        $observed['GIT_DIR'].Exists | Should -BeFalse
        $observed['WINSMUX_PESTER_CANDIDATE_TREE'].Value | Should -BeExactly 'managed-tree'
        Assert-EnvironmentEvidence -Expected $before -Actual (Get-EnvironmentEvidence -Names $names)
    }

    It 'T796-E03 restores caller Git variables after assertion and setup failures' {
        Assert-Task796RunnerFunction -Name 'Invoke-WithRunnerGitEnvironment'
        $names = @('GCM_INTERACTIVE', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_COUNT', 'GIT_TASK796_CREATED', 'WINSMUX_PESTER_CANDIDATE_TREE')
        [Environment]::SetEnvironmentVariable('GCM_INTERACTIVE', 'caller-before-failure', 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', 'caller-before-failure', 'Process')
        Remove-Item -LiteralPath 'Env:GIT_CONFIG_COUNT' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:GIT_TASK796_CREATED' -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable('WINSMUX_PESTER_CANDIDATE_TREE', 'caller-tree', 'Process')
        $before = Get-EnvironmentEvidence -Names $names
        $managed = [ordered]@{ GCM_INTERACTIVE = 'Never'; GIT_CONFIG_GLOBAL = 'managed'; GIT_CONFIG_COUNT = '0'; WINSMUX_PESTER_CANDIDATE_TREE = 'managed-tree' }

        try {
            Invoke-WithRunnerGitEnvironment -Environment $managed -ScriptBlock {
                [Environment]::SetEnvironmentVariable('GIT_TASK796_CREATED', 'assertion', 'Process')
                1 | Should -Be 2
            }
        } catch {}
        Assert-EnvironmentEvidence -Expected $before -Actual (Get-EnvironmentEvidence -Names $names)

        try {
            Invoke-WithRunnerGitEnvironment -Environment $managed -ScriptBlock {
                [Environment]::SetEnvironmentVariable('GIT_TASK796_CREATED', 'setup', 'Process')
                throw 'synthetic setup failure'
            }
        } catch {}
        Assert-EnvironmentEvidence -Expected $before -Actual (Get-EnvironmentEvidence -Names $names)
    }

    It 'T796-C01 materializes the prospective index as an exact private checkout-index tree' {
        Assert-Task796RunnerFunction -Name 'New-RunnerCandidateContext'
        Assert-Task796RunnerFunction -Name 'New-RunnerPrivateRepository'
        Assert-Task796RunnerFunction -Name 'Assert-RunnerSourceState'
        $source = New-TestRepository -Name 'prospective-source'
        $actualIndex = (Invoke-TestGit -RepositoryRoot $source -Arguments @('rev-parse', '--git-path', 'index')).StdOut
        if (-not [System.IO.Path]::IsPathRooted($actualIndex)) { $actualIndex = Join-Path $source $actualIndex }
        $prospectiveIndex = Join-Path $TestDrive 'prospective.index'
        Copy-Item -LiteralPath $actualIndex -Destination $prospectiveIndex
        [System.IO.File]::WriteAllText((Join-Path $source 'tracked.txt'), "candidate`n", $script:Utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $source 'added.txt'), "added`n", $script:Utf8NoBom)
        $prospectiveEnvironment = Get-TestPlatformEnvironment
        $prospectiveEnvironment['GIT_INDEX_FILE'] = $prospectiveIndex
        [void](Invoke-TestGit -RepositoryRoot $source -Arguments @('add', '--', 'tracked.txt', 'added.txt') -Environment $prospectiveEnvironment)
        $expectedTree = (Invoke-TestGit -RepositoryRoot $source -Arguments @('write-tree') -Environment $prospectiveEnvironment).StdOut
        $indexBefore = Get-FileSha256 -Path $actualIndex
        $prospectiveBefore = Get-FileSha256 -Path $prospectiveIndex
        $refsBefore = (Invoke-TestGit -RepositoryRoot $source -Arguments @('show-ref', '--head')).StdOut
        $configBefore = Get-FileSha256 -Path (Join-Path $source '.git\config')

        $context = New-RunnerCandidateContext -RepositoryRoot $source -ExecutionRoot (Join-Path $TestDrive 'controller') -ProspectiveIndexPath $prospectiveIndex
        $privateRoot = New-RunnerPrivateRepository -Context $context -DestinationPath (Join-Path $TestDrive 'private')

        $context.CandidateTreeId | Should -BeExactly $expectedTree
        (Invoke-TestGit -RepositoryRoot $privateRoot -Arguments @('write-tree') -Environment $context.GitEnvironment).StdOut | Should -BeExactly $expectedTree
        (Invoke-TestGit -RepositoryRoot $privateRoot -Arguments @('rev-parse', 'HEAD^{tree}') -Environment $context.GitEnvironment).StdOut | Should -BeExactly $expectedTree
        [System.IO.File]::ReadAllText((Join-Path $privateRoot 'tracked.txt')) | Should -BeExactly "candidate`n"
        [System.IO.File]::ReadAllText((Join-Path $privateRoot 'added.txt')) | Should -BeExactly "added`n"
        Assert-RunnerSourceState -Context $context
        (Get-FileSha256 -Path $actualIndex) | Should -BeExactly $indexBefore
        (Get-FileSha256 -Path $prospectiveIndex) | Should -BeExactly $prospectiveBefore
        (Invoke-TestGit -RepositoryRoot $source -Arguments @('show-ref', '--head')).StdOut | Should -BeExactly $refsBefore
        (Get-FileSha256 -Path (Join-Path $source '.git\config')) | Should -BeExactly $configBefore
    }

    It 'T796-C02 detects source tracked-byte drift without repairing caller Git state' {
        Assert-Task796RunnerFunction -Name 'New-RunnerCandidateContext'
        Assert-Task796RunnerFunction -Name 'Assert-RunnerSourceState'
        $source = New-TestRepository -Name 'drift-source'
        $actualIndex = (Invoke-TestGit -RepositoryRoot $source -Arguments @('rev-parse', '--git-path', 'index')).StdOut
        if (-not [System.IO.Path]::IsPathRooted($actualIndex)) { $actualIndex = Join-Path $source $actualIndex }
        $indexBefore = Get-FileSha256 -Path $actualIndex
        $refsBefore = (Invoke-TestGit -RepositoryRoot $source -Arguments @('show-ref', '--head')).StdOut
        $configBefore = Get-FileSha256 -Path (Join-Path $source '.git\config')
        $context = New-RunnerCandidateContext -RepositoryRoot $source -ExecutionRoot (Join-Path $TestDrive 'drift-controller')

        [System.IO.File]::WriteAllText((Join-Path $source 'tracked.txt'), "drift`n", $script:Utf8NoBom)
        { Assert-RunnerSourceState -Context $context } | Should -Throw '*source tracked bytes changed*'
        (Get-FileSha256 -Path $actualIndex) | Should -BeExactly $indexBefore
        (Invoke-TestGit -RepositoryRoot $source -Arguments @('show-ref', '--head')).StdOut | Should -BeExactly $refsBefore
        (Get-FileSha256 -Path (Join-Path $source '.git\config')) | Should -BeExactly $configBefore
    }

    It 'T796-C03 detects drift in a path tracked only by the prospective index' {
        Assert-Task796RunnerFunction -Name 'New-RunnerCandidateContext'
        Assert-Task796RunnerFunction -Name 'Assert-RunnerSourceState'
        $source = New-TestRepository -Name 'candidate-only-drift-source'
        $actualIndex = (Invoke-TestGit -RepositoryRoot $source -Arguments @('rev-parse', '--git-path', 'index')).StdOut
        if (-not [System.IO.Path]::IsPathRooted($actualIndex)) { $actualIndex = Join-Path $source $actualIndex }
        $prospectiveIndex = Join-Path $TestDrive 'candidate-only.index'
        Copy-Item -LiteralPath $actualIndex -Destination $prospectiveIndex
        [System.IO.File]::WriteAllText((Join-Path $source 'candidate-only.txt'), "candidate`n", $script:Utf8NoBom)
        $prospectiveEnvironment = Get-TestPlatformEnvironment
        $prospectiveEnvironment['GIT_INDEX_FILE'] = $prospectiveIndex
        [void](Invoke-TestGit -RepositoryRoot $source -Arguments @('add', '--', 'candidate-only.txt') -Environment $prospectiveEnvironment)
        $prospectiveBefore = Get-FileSha256 -Path $prospectiveIndex
        $context = New-RunnerCandidateContext -RepositoryRoot $source -ExecutionRoot (Join-Path $TestDrive 'candidate-only-controller') -ProspectiveIndexPath $prospectiveIndex

        [System.IO.File]::WriteAllText((Join-Path $source 'candidate-only.txt'), "drift`n", $script:Utf8NoBom)

        { Assert-RunnerSourceState -Context $context } | Should -Throw '*candidate tracked bytes changed*'
        (Get-FileSha256 -Path $prospectiveIndex) | Should -BeExactly $prospectiveBefore
    }

    It 'T796-L01 rejects unmatched line filters in serial and direct worker entry points' {
        Assert-Task796RunnerFunction -Name 'Get-RunnerCandidateTestPaths'
        Assert-Task796RunnerFunction -Name 'Assert-PesterWorkerSpecCandidatePaths'
        $allowlist = @(
            '.githooks/pre-commit-whitelist.ps1'
            '.gitignore'
            'scripts/run-tests.ps1'
            'tests/Integration.WorktreeHook.Tests.ps1'
            'tests/PesterGitIsolation.Tests.ps1'
        )
        $actualIndex = (Invoke-TestGit -RepositoryRoot $script:RepoRoot -Arguments @('rev-parse', '--git-path', 'index')).StdOut
        if (-not [System.IO.Path]::IsPathRooted($actualIndex)) {
            $actualIndex = Join-Path $script:RepoRoot $actualIndex
        }
        $prospectiveIndex = Join-Path $TestDrive 'selector-candidate.index'
        Copy-Item -LiteralPath $actualIndex -Destination $prospectiveIndex
        $candidateEnvironment = Get-TestPlatformEnvironment
        $candidateEnvironment['GIT_INDEX_FILE'] = $prospectiveIndex
        [void](Invoke-TestGit -RepositoryRoot $script:RepoRoot -Arguments (@('add', '--') + $allowlist) -Environment $candidateEnvironment)
        $candidateTreeId = (Invoke-TestGit -RepositoryRoot $script:RepoRoot -Arguments @('write-tree') -Environment $candidateEnvironment).StdOut
        $actualIndexBefore = Get-FileSha256 -Path $actualIndex
        $prospectiveIndexBefore = Get-FileSha256 -Path $prospectiveIndex
        $candidateTestPaths = @(Get-RunnerCandidateTestPaths `
            -RepositoryRoot $script:RepoRoot `
            -CandidateTreeId $candidateTreeId `
            -Environment $candidateEnvironment)
        $candidateTestPaths | Should -Contain (Join-Path $script:RepoRoot 'tests\PesterGitIsolation.Tests.ps1')

        $removedIndex = Join-Path $TestDrive 'selector-removed.index'
        Copy-Item -LiteralPath $prospectiveIndex -Destination $removedIndex
        $removedEnvironment = Get-TestPlatformEnvironment
        $removedEnvironment['GIT_INDEX_FILE'] = $removedIndex
        [void](Invoke-TestGit -RepositoryRoot $script:RepoRoot -Environment $removedEnvironment -Arguments @(
            'update-index', '--force-remove', '--', 'tests/Integration.WorktreeHook.Tests.ps1'
        ))
        $removedTreeId = (Invoke-TestGit -RepositoryRoot $script:RepoRoot -Environment $removedEnvironment -Arguments @('write-tree')).StdOut
        @(Get-RunnerCandidateTestPaths `
            -RepositoryRoot $script:RepoRoot `
            -CandidateTreeId $removedTreeId `
            -Environment $removedEnvironment) |
            Should -Not -Contain (Join-Path $script:RepoRoot 'tests\Integration.WorktreeHook.Tests.ps1')

        $resolverModule = Join-Path $script:RepoRoot 'scripts\winsmux-pester.psm1'
        Import-Module $resolverModule -Force -ErrorAction Stop | Out-Null
        $pesterResolution = Resolve-WinsmuxPester571
        $pesterResolution.resolution_status | Should -BeExactly 'resolved'
        $invalidLineFilter = '{0}:999999' -f (Join-Path $script:RepoRoot 'tests\PesterGitIsolation.Tests.ps1')
        $hooksPath = Join-Path $TestDrive 'selector-hooks'
        $templatePath = Join-Path $TestDrive 'selector-template'
        New-Item -ItemType Directory -Path $hooksPath, $templatePath -Force | Out-Null

        $workerRoot = Join-Path $TestDrive 'selector-worker'
        $workerSpec = [ordered]@{
            Mode = 'Test'
            WorkerId = 'selector-negative'
            RepositoryRoot = $script:RepoRoot
            WorkingDirectory = $script:RepoRoot
            Paths = @((Join-Path $script:RepoRoot 'tests\PesterGitIsolation.Tests.ps1'))
            LineFilters = @($invalidLineFilter)
            ExpectedCount = 1
            ResultPath = Join-Path $workerRoot 'result.json'
            NUnitPath = Join-Path $workerRoot 'result.xml'
            StdOutPath = Join-Path $workerRoot 'stdout.log'
            StdErrPath = Join-Path $workerRoot 'stderr.log'
            TempDirectory = Join-Path $workerRoot 'temp'
            ProjectDirectory = Join-Path $workerRoot 'project'
            PesterModulePath = [string]$pesterResolution.manifest_path
            CandidateTreeId = $candidateTreeId
            HooksPath = $hooksPath
            TemplatePath = $templatePath
            RequiresPrivateRepository = $false
        }
        New-Item -ItemType Directory -Path $workerRoot -Force | Out-Null
        $workerSpecPath = Join-Path $workerRoot 'spec.json'
        [System.IO.File]::WriteAllText($workerSpecPath, ($workerSpec | ConvertTo-Json -Depth 8), $script:Utf8NoBom)
        $workerRun = Invoke-TestPowerShell -WorkingDirectory $script:RepoRoot -AllowFailure -Arguments @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:RunnerPath,
            '-WorkerSpecPath', $workerSpecPath
        )
        $workerRun.ExitCode | Should -Be 2
        Test-Path -LiteralPath $workerSpec.ResultPath -PathType Leaf | Should -BeTrue
        $workerPayload = Get-Content -LiteralPath $workerSpec.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $workerPayload.total | Should -Be 0
        $workerPayload.expectedCount | Should -Be 1
        $workerPayload.harnessError | Should -Match 'expected 1 tests, got 0'

        $injectedRelativePath = 'tests/task796-candidate-exclusion-{0}.Tests.ps1' -f [guid]::NewGuid().ToString('N')
        $injectedPath = Join-Path $script:RepoRoot $injectedRelativePath
        $createdInjectedPath = $false
        try {
            if (Test-Path -LiteralPath $injectedPath) {
                throw "Candidate exclusion probe already exists: $injectedPath"
            }
            [System.IO.File]::WriteAllText($injectedPath, "Describe 'candidate-external' { It 'must not run' { 1 | Should -Be 2 } }`n", $script:Utf8NoBom)
            $createdInjectedPath = $true
            (Invoke-TestGit -RepositoryRoot $script:RepoRoot -Arguments @('check-ignore', '--quiet', '--', $injectedRelativePath) -AllowFailure).ExitCode |
                Should -Be 0
            @(Get-RunnerCandidateTestPaths `
                -RepositoryRoot $script:RepoRoot `
                -CandidateTreeId $candidateTreeId `
                -Environment $candidateEnvironment) |
                Should -Not -Contain $injectedPath

            $membershipRoot = Join-Path $TestDrive 'membership-worker'
            New-Item -ItemType Directory -Path $membershipRoot -Force | Out-Null
            $membershipSpec = [ordered]@{
                Mode = 'Test'
                WorkerId = 'membership-negative'
                RepositoryRoot = $script:RepoRoot
                WorkingDirectory = $script:RepoRoot
                Paths = @($injectedPath)
                LineFilters = @()
                ExpectedCount = 1
                ResultPath = Join-Path $membershipRoot 'result.json'
                NUnitPath = Join-Path $membershipRoot 'result.xml'
                StdOutPath = Join-Path $membershipRoot 'stdout.log'
                StdErrPath = Join-Path $membershipRoot 'stderr.log'
                TempDirectory = Join-Path $membershipRoot 'temp'
                ProjectDirectory = Join-Path $membershipRoot 'project'
                PesterModulePath = [string]$pesterResolution.manifest_path
                CandidateTreeId = $candidateTreeId
                HooksPath = $hooksPath
                TemplatePath = $templatePath
                RequiresPrivateRepository = $false
            }
            $membershipSpecPath = Join-Path $membershipRoot 'spec.json'
            [System.IO.File]::WriteAllText($membershipSpecPath, ($membershipSpec | ConvertTo-Json -Depth 8), $script:Utf8NoBom)
            $membershipRun = Invoke-TestPowerShell -WorkingDirectory $script:RepoRoot -AllowFailure -Arguments @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:RunnerPath,
                '-WorkerSpecPath', $membershipSpecPath
            )
            $membershipRun.ExitCode | Should -Be 2
            Test-Path -LiteralPath $membershipSpec.ResultPath -PathType Leaf | Should -BeTrue
            $membershipPayload = Get-Content -LiteralPath $membershipSpec.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $membershipPayload.harnessError | Should -Match 'not in the candidate Pester test inventory'
        } finally {
            if ($createdInjectedPath -and (Test-Path -LiteralPath $injectedPath -PathType Leaf)) {
                Remove-Item -LiteralPath $injectedPath -Force
            }
        }

        $serialRoot = Join-Path $TestDrive 'selector-serial'
        $wrapperPath = Join-Path $TestDrive 'invoke-selector-serial.ps1'
        $wrapper = @'
param(
    [Parameter(Mandatory)][string]$RunnerPath,
    [Parameter(Mandatory)][string]$LineFilter,
    [Parameter(Mandatory)][string]$ResultsDirectory
)
& $RunnerPath -Parallel:$false -LineFilters @($LineFilter) -ResultsDirectory $ResultsDirectory
exit $LASTEXITCODE
'@
        [System.IO.File]::WriteAllText($wrapperPath, $wrapper, $script:Utf8NoBom)
        $serialRun = Invoke-TestPowerShell -WorkingDirectory $script:RepoRoot -AllowFailure `
            -ExtraEnvironment ([ordered]@{ GIT_INDEX_FILE = $prospectiveIndex }) `
            -Arguments @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $wrapperPath,
                '-RunnerPath', $script:RunnerPath,
                '-LineFilter', $invalidLineFilter,
                '-ResultsDirectory', $serialRoot
            )
        $serialRun.ExitCode | Should -Be 1
        $serialSummaryPath = Join-Path $serialRoot 'summary.json'
        Test-Path -LiteralPath $serialSummaryPath -PathType Leaf | Should -BeTrue
        $serialSummary = Get-Content -LiteralPath $serialSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $serialSummary.mode | Should -BeExactly 'harness-error'
        $serialSummary.error | Should -Match 'matched no executed test'
        $serialSummary.total | Should -Be 0

        (Get-FileSha256 -Path $actualIndex) | Should -BeExactly $actualIndexBefore
        (Get-FileSha256 -Path $prospectiveIndex) | Should -BeExactly $prospectiveIndexBefore
    }

    It 'T796-F01 suppresses external hooks and permits one explicit fixture-local hook' {
        Assert-Task796RunnerFunction -Name 'New-RunnerCandidateContext'
        Assert-Task796RunnerFunction -Name 'New-RunnerPrivateRepository'
        $source = New-TestRepository -Name 'hook-source'
        $context = New-RunnerCandidateContext -RepositoryRoot $source -ExecutionRoot (Join-Path $TestDrive 'hook-controller')
        $privateRoot = New-RunnerPrivateRepository -Context $context -DestinationPath (Join-Path $TestDrive 'hook-private')
        $externalHooks = Join-Path $TestDrive 'external-hooks'
        $localHooks = Join-Path $TestDrive 'local-hooks'
        New-Item -ItemType Directory -Path $externalHooks, $localHooks -Force | Out-Null
        $externalMarker = Join-Path $TestDrive 'external.marker'
        $localMarker = Join-Path $TestDrive 'local.marker'
        Write-HookScript -Path (Join-Path $externalHooks 'pre-commit') -MarkerVariable 'WINSMUX_EXTERNAL_HOOK_MARKER'
        Write-HookScript -Path (Join-Path $localHooks 'pre-commit') -MarkerVariable 'WINSMUX_LOCAL_HOOK_MARKER'
        $globalConfig = Join-Path $TestDrive 'hostile.gitconfig'
        $externalUnix = $externalHooks.Replace('\', '/')
        [System.IO.File]::WriteAllText($globalConfig, "[core]`n`thooksPath = $externalUnix`n", $script:Utf8NoBom)
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $globalConfig, 'Process')
        $markers = [ordered]@{
            WINSMUX_EXTERNAL_HOOK_MARKER = $externalMarker
            WINSMUX_LOCAL_HOOK_MARKER = $localMarker
        }

        [void](Invoke-TestGit -RepositoryRoot $privateRoot -Environment $context.GitEnvironment -ExtraEnvironment $markers -Arguments @(
            '-c', 'user.name=TASK-796 Fixture', '-c', 'user.email=task796@example.invalid',
            'commit', '--allow-empty', '-m', 'managed hook boundary'
        ))
        Test-Path -LiteralPath $externalMarker | Should -BeFalse

        [void](Invoke-TestGit -RepositoryRoot $privateRoot -Environment $context.GitEnvironment -ExtraEnvironment $markers -Arguments @(
            '-c', 'user.name=TASK-796 Fixture', '-c', 'user.email=task796@example.invalid',
            '-c', "core.hooksPath=$($localHooks.Replace('\', '/'))",
            'commit', '--allow-empty', '-m', 'explicit local hook'
        ))
        Test-Path -LiteralPath $externalMarker | Should -BeFalse
        @(Get-Content -LiteralPath $localMarker).Count | Should -Be 1
    }

    It 'T796-F02 assigns only both mutable suites to one private fixture worker' {
        Assert-Task796RunnerFunction -Name 'Select-PesterWorkUnitsByLineFilter'
        $testFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'tests') -Filter '*.Tests.ps1' -File -Recurse)
        $discoveryTests = @($testFiles | ForEach-Object {
            [PSCustomObject]@{ file = $_.FullName; startLine = 1; identity = "tests/$($_.Name):1|fixture" }
        })
        $discovery = [PSCustomObject]@{ total = $discoveryTests.Count; tests = $discoveryTests }
        $units = @(New-PesterWorkUnits `
            -RepositoryRoot $script:RepoRoot `
            -CandidateRepositoryRoot $script:RepoRoot `
            -CandidateTestPaths @($testFiles.FullName) `
            -DiscoveryResult $discovery)

        @($units | Where-Object { $_.PSObject.Properties.Name -notcontains 'RequiresPrivateRepository' }).Count | Should -Be 0
        $privateUnits = @($units | Where-Object { [bool]$_.RequiresPrivateRepository })
        $privateUnits.Count | Should -Be 1
        $privateUnits[0].WorkerId | Should -BeExactly 'private-git-fixture'
        @($privateUnits[0].Paths | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Sort-Object) |
            Should -Be @('HarnessContract.Tests.ps1', 'PublicSurfacePolicy.Tests.ps1')
        @($units | Where-Object { -not [bool]$_.RequiresPrivateRepository } | ForEach-Object { $_.Paths } |
            ForEach-Object { [System.IO.Path]::GetFileName($_) }) |
            Should -Not -Contain 'HarnessContract.Tests.ps1'
        @($units | Where-Object { -not [bool]$_.RequiresPrivateRepository } | ForEach-Object { $_.Paths } |
            ForEach-Object { [System.IO.Path]::GetFileName($_) }) |
            Should -Not -Contain 'PublicSurfacePolicy.Tests.ps1'

        $boundedFilters = @(
            '{0}:1' -f (Join-Path $script:RepoRoot 'tests\PesterGitIsolation.Tests.ps1')
            '{0}:1' -f (Join-Path $script:RepoRoot 'tests\Integration.WorktreeHook.Tests.ps1')
        )
        $bounded = Select-PesterWorkUnitsByLineFilter -RepositoryRoot $script:RepoRoot -Units $units -DiscoveryResult $discovery -LineFilters $boundedFilters
        $bounded.Total | Should -Be 2
        @($bounded.Units).Count | Should -Be 2
        @($bounded.Units | Where-Object { [bool]$_.RequiresPrivateRepository }).Count | Should -Be 0
        @($bounded.Units | ForEach-Object { [System.IO.Path]::GetFileName($_.Paths[0]) } | Sort-Object) |
            Should -Be @('Integration.WorktreeHook.Tests.ps1', 'PesterGitIsolation.Tests.ps1')
        @($bounded.Units | ForEach-Object { @($_.LineFilters).Count }) | Should -Be @(1, 1)
    }
}
