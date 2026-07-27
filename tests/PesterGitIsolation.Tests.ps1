$ErrorActionPreference = 'Stop'

Describe 'TASK-796 Pester Git environment isolation' {
    BeforeAll {
        $script:Task796RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:Task796RunnerPath = Join-Path $script:Task796RepoRoot 'scripts\run-tests.ps1'
        $script:Task796TestPath = Join-Path $PSScriptRoot 'PesterGitIsolation.Tests.ps1'
        $script:Task796WorktreeTestPath = Join-Path $PSScriptRoot 'Integration.WorktreeHook.Tests.ps1'
        $script:Task796WorkflowPath = Join-Path $script:Task796RepoRoot '.github\workflows\test.yml'

        function Get-Task796EnvironmentState {
            param([Parameter(Mandatory = $true)][string]$Name)

            return [PSCustomObject]@{
                Exists = Test-Path -LiteralPath "Env:$Name"
                Value  = [Environment]::GetEnvironmentVariable($Name, 'Process')
            }
        }

        function Restore-Task796EnvironmentState {
            param(
                [Parameter(Mandatory = $true)][string]$Name,
                [Parameter(Mandatory = $true)]$State
            )

            if ($State.Exists) {
                [Environment]::SetEnvironmentVariable($Name, [string]$State.Value, 'Process')
            } else {
                Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
            }
        }

        function Get-Task796FunctionSource {
            param([Parameter(Mandatory = $true)][string]$Name)

            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:Task796RunnerPath,
                [ref]$tokens,
                [ref]$errors
            )
            if (@($errors).Count -gt 0) {
                throw "run-tests.ps1 parser error: $($errors[0].Message)"
            }
            $functionAst = @(
                $ast.FindAll(
                    {
                        param($candidate)
                        $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                            [string]$candidate.Name -ceq $Name
                    },
                    $true
                )
            ) | Select-Object -First 1
            if ($null -eq $functionAst) {
                return $null
            }
            return [string]$functionAst.Extent.Text
        }

        function Import-Task796RunnerFunction {
            param([Parameter(Mandatory = $true)][string]$Name)

            $source = Get-Task796FunctionSource -Name $Name
            $source | Should -Not -BeNullOrEmpty -Because "$Name must own an executable runner boundary"
            . ([scriptblock]::Create($source))
            $localDefinition = Get-Item -LiteralPath "Function:$Name" -ErrorAction Stop
            Set-Item -LiteralPath "Function:script:$Name" -Value $localDefinition.ScriptBlock
        }

        function Write-Task796Utf8File {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)][string]$Content
            )

            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
            [System.IO.File]::WriteAllText(
                $Path,
                $Content,
                [System.Text.UTF8Encoding]::new($false)
            )
        }

        function ConvertTo-Task796GitPath {
            param([Parameter(Mandatory = $true)][string]$Path)

            return ([System.IO.Path]::GetFullPath($Path) -replace '\\', '/')
        }

        function New-Task796HookSet {
            param(
                [Parameter(Mandatory = $true)][string]$Directory,
                [Parameter(Mandatory = $true)][string]$MarkerPath,
                [Parameter(Mandatory = $true)][string[]]$Names
            )

            [System.IO.Directory]::CreateDirectory($Directory) | Out-Null
            $marker = ConvertTo-Task796GitPath -Path $MarkerPath
            foreach ($name in $Names) {
                $hookPath = Join-Path $Directory $name
                Write-Task796Utf8File -Path $hookPath -Content @"
#!/bin/sh
printf '%s\n' '$name' >> '$marker'
exit 0
"@
                if (-not $IsWindows) {
                    $mode = [IO.UnixFileMode]::UserRead -bor
                        [IO.UnixFileMode]::UserWrite -bor
                        [IO.UnixFileMode]::UserExecute -bor
                        [IO.UnixFileMode]::GroupRead -bor
                        [IO.UnixFileMode]::GroupExecute -bor
                        [IO.UnixFileMode]::OtherRead -bor
                        [IO.UnixFileMode]::OtherExecute
                    [IO.File]::SetUnixFileMode($hookPath, $mode)
                }
            }
        }

        function New-Task796GlobalConfig {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)][string]$HooksPath
            )

            $hooks = ConvertTo-Task796GitPath -Path $HooksPath
            Write-Task796Utf8File -Path $Path -Content @"
[core]
    hooksPath = "$hooks"
"@
        }

        function Invoke-Task796GitChild {
            param(
                [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment,
                [Parameter(Mandatory = $true)][string]$CaseRoot,
                [string]$ExplicitGlobalConfig
            )

            $childPath = Join-Path $CaseRoot 'git-child.ps1'
            Write-Task796Utf8File -Path $childPath -Content @'
param(
    [Parameter(Mandatory = $true)][string]$CaseRoot,
    [string]$ExplicitGlobalConfig
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Invoke-CheckedGit {
    param([Parameter(Mandatory = $true)][string[]]$GitArguments)

    $output = @(& git @GitArguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine(($output -join [Environment]::NewLine))
        exit 20
    }
}

if (-not [string]::IsNullOrWhiteSpace($ExplicitGlobalConfig)) {
    $env:GIT_CONFIG_GLOBAL = $ExplicitGlobalConfig
}

$repo = Join-Path $CaseRoot 'repo'
$worktree = Join-Path $CaseRoot 'worktree'
[System.IO.Directory]::CreateDirectory($repo) | Out-Null
Invoke-CheckedGit -GitArguments @('-C', $repo, 'init')
Invoke-CheckedGit -GitArguments @('-C', $repo, 'config', 'user.name', 'TASK-796 Test')
Invoke-CheckedGit -GitArguments @('-C', $repo, 'config', 'user.email', 'task796@example.invalid')
[System.IO.File]::WriteAllText(
    (Join-Path $repo 'fixture.txt'),
    'fixture',
    [System.Text.UTF8Encoding]::new($false)
)
Invoke-CheckedGit -GitArguments @('-C', $repo, 'add', 'fixture.txt')
Invoke-CheckedGit -GitArguments @('-C', $repo, 'commit', '-m', 'fixture')
Invoke-CheckedGit -GitArguments @('-C', $repo, 'worktree', 'add', '-b', 'task796-child', $worktree)
'@

            $pwshPath = (Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $pwshPath
            foreach ($argument in @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $childPath,
                '-CaseRoot', $CaseRoot
            )) {
                $startInfo.ArgumentList.Add($argument)
            }
            if (-not [string]::IsNullOrWhiteSpace($ExplicitGlobalConfig)) {
                $startInfo.ArgumentList.Add('-ExplicitGlobalConfig')
                $startInfo.ArgumentList.Add($ExplicitGlobalConfig)
            }
            $startInfo.WorkingDirectory = $CaseRoot
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.Environment.Clear()
            foreach ($entry in $Environment.GetEnumerator()) {
                $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
            }

            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
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

        function Get-Task796MarkerCount {
            param([Parameter(Mandatory = $true)][string]$Path)

            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                return 0
            }
            return @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() }).Count
        }

        function Invoke-Task796CheckedGit {
            param(
                [Parameter(Mandatory = $true)][string]$RepositoryRoot,
                [Parameter(Mandatory = $true)][string[]]$Arguments
            )

            $output = @(& git -C $RepositoryRoot @Arguments 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "fixture git failed: git -C <fixture> $($Arguments -join ' '): $($output -join ' ')"
            }
            return @($output)
        }

        function New-Task796FixtureRepository {
            param(
                [Parameter(Mandatory = $true)][string]$RepositoryRoot,
                [string[]]$RelativePaths = @('tracked.txt')
            )

            [System.IO.Directory]::CreateDirectory($RepositoryRoot) | Out-Null
            Invoke-Task796CheckedGit -RepositoryRoot $RepositoryRoot -Arguments @('init') | Out-Null
            Invoke-Task796CheckedGit -RepositoryRoot $RepositoryRoot -Arguments @(
                'config', 'user.name', 'TASK-796 Test'
            ) | Out-Null
            Invoke-Task796CheckedGit -RepositoryRoot $RepositoryRoot -Arguments @(
                'config', 'user.email', 'task796@example.invalid'
            ) | Out-Null
            foreach ($relativePath in $RelativePaths) {
                Write-Task796Utf8File -Path (Join-Path $RepositoryRoot $relativePath) -Content (
                    "fixture:$($relativePath -replace '\\', '/')"
                )
            }
            Invoke-Task796CheckedGit -RepositoryRoot $RepositoryRoot -Arguments @(
                'add', '-f', '--all'
            ) | Out-Null
            Invoke-Task796CheckedGit -RepositoryRoot $RepositoryRoot -Arguments @(
                'commit', '--no-gpg-sign', '-m', 'fixture'
            ) | Out-Null

            return [string](
                Invoke-Task796CheckedGit -RepositoryRoot $RepositoryRoot -Arguments @(
                    'rev-parse', 'HEAD^{tree}'
                ) | Select-Object -First 1
            ).Trim()
        }

        function Get-Task796FixtureRepositoryState {
            param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

            $indexPath = [string](
                Invoke-Task796CheckedGit -RepositoryRoot $RepositoryRoot -Arguments @(
                    'rev-parse', '--path-format=absolute', '--git-path', 'index'
                ) | Select-Object -First 1
            ).Trim()
            $configPath = [string](
                Invoke-Task796CheckedGit -RepositoryRoot $RepositoryRoot -Arguments @(
                    'rev-parse', '--path-format=absolute', '--git-path', 'config'
                ) | Select-Object -First 1
            ).Trim()
            $indexBytes = [System.IO.File]::ReadAllBytes($indexPath)
            $configBytes = [System.IO.File]::ReadAllBytes($configPath)
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            try {
                $indexSha = (
                    [Convert]::ToHexString($sha256.ComputeHash($indexBytes))
                ).ToLowerInvariant()
                $configSha = (
                    [Convert]::ToHexString($sha256.ComputeHash($configBytes))
                ).ToLowerInvariant()
            } finally {
                $sha256.Dispose()
            }
            $trackedDiff = @(
                Invoke-Task796CheckedGit -RepositoryRoot $RepositoryRoot -Arguments @(
                    'diff', '--binary', 'HEAD', '--'
                )
            ) -join "`n"
            $refs = @(
                Invoke-Task796CheckedGit -RepositoryRoot $RepositoryRoot -Arguments @(
                    'for-each-ref', '--format=%(refname)%00%(objectname)'
                )
            ) -join "`n"

            return [PSCustomObject]@{
                IndexSha256  = $indexSha
                ConfigSha256 = $configSha
                TrackedDiff  = $trackedDiff
                Refs         = $refs
            }
        }
    }

    It 'TB02 GI01 parallel workers ignore hostile global hooks' {
        Import-Task796RunnerFunction -Name 'Get-IsolatedGitEnvironment'
        Import-Task796RunnerFunction -Name 'Get-IsolatedChildEnvironment'
        $caseRoot = Join-Path $TestDrive 'gi01'
        $syntheticHome = Join-Path $caseRoot 'home'
        $hooks = Join-Path $caseRoot 'hostile-hooks'
        $marker = Join-Path $caseRoot 'hostile.log'
        $project = Join-Path $caseRoot 'project'
        $temp = Join-Path $caseRoot 'temp'
        New-Task796HookSet -Directory $hooks -MarkerPath $marker -Names @('pre-commit', 'post-checkout')
        New-Task796GlobalConfig -Path (Join-Path $syntheticHome '.gitconfig') -HooksPath $hooks
        [System.IO.Directory]::CreateDirectory($project) | Out-Null
        [System.IO.Directory]::CreateDirectory($temp) | Out-Null

        $states = [ordered]@{}
        foreach ($name in @(
            'HOME',
            'USERPROFILE',
            'GIT_CONFIG_COUNT',
            'GIT_CONFIG_PARAMETERS',
            'GIT_CONFIG_KEY_0',
            'GIT_CONFIG_VALUE_0'
        )) {
            $states[$name] = Get-Task796EnvironmentState -Name $name
        }
        try {
            $env:HOME = $syntheticHome
            $env:USERPROFILE = $syntheticHome
            $env:GIT_CONFIG_COUNT = '1'
            $env:GIT_CONFIG_KEY_0 = 'core.hooksPath'
            $env:GIT_CONFIG_VALUE_0 = ConvertTo-Task796GitPath -Path $hooks
            $env:GIT_CONFIG_PARAMETERS = (
                "'core.hooksPath=$($env:GIT_CONFIG_VALUE_0)'"
            )
            $environment = Get-IsolatedChildEnvironment -TempDirectory $temp -ProjectDirectory $project
            $environment['GIT_CONFIG_COUNT'] | Should -Be '1'
            $environment['GIT_CONFIG_PARAMETERS'] | Should -BeExactly ''
            $environment['GIT_CONFIG_KEY_0'] | Should -BeExactly 'init.defaultBranch'
            $environment['GIT_CONFIG_VALUE_0'] | Should -BeExactly 'main'
            $environment.Contains('GIT_CONFIG_KEY_1') | Should -BeFalse
            $environment.Contains('GIT_CONFIG_VALUE_1') | Should -BeFalse
            $result = Invoke-Task796GitChild -Environment $environment -CaseRoot (Join-Path $caseRoot 'child')

            $result.ExitCode | Should -Be 0 -Because $result.StdErr
            (Get-Task796MarkerCount -Path $marker) | Should -Be 0 -Because 'parallel discovery and execution workers must not load host Git hooks'
        } finally {
            foreach ($entry in $states.GetEnumerator()) {
                Restore-Task796EnvironmentState -Name ([string]$entry.Key) -State $entry.Value
            }
        }
    }

    It 'GI02 explicit fixture hook remains authoritative' {
        Import-Task796RunnerFunction -Name 'Get-IsolatedGitEnvironment'
        Import-Task796RunnerFunction -Name 'Get-IsolatedChildEnvironment'
        $caseRoot = Join-Path $TestDrive 'gi02'
        $project = Join-Path $caseRoot 'project'
        $temp = Join-Path $caseRoot 'temp'
        $hooks = Join-Path $caseRoot 'explicit-hooks'
        $marker = Join-Path $caseRoot 'explicit.log'
        $config = Join-Path $caseRoot 'explicit.gitconfig'
        [System.IO.Directory]::CreateDirectory($project) | Out-Null
        [System.IO.Directory]::CreateDirectory($temp) | Out-Null
        New-Task796HookSet -Directory $hooks -MarkerPath $marker -Names @('pre-commit')
        New-Task796GlobalConfig -Path $config -HooksPath $hooks
        $source = [System.IO.File]::ReadAllText(
            $script:Task796TestPath,
            [System.Text.Encoding]::UTF8
        )
        $hookFactory = [regex]::Match(
            $source,
            '(?ms)^\s{8}function New-Task796HookSet \{.*?(?=^\s{8}function )'
        )
        $hookFactory.Success | Should -BeTrue
        $hookFactory.Value | Should -Match '\[IO\.File\]::SetUnixFileMode'
        if (-not $IsWindows) {
            $hookMode = [IO.File]::GetUnixFileMode((Join-Path $hooks 'pre-commit'))
            ($hookMode -band [IO.UnixFileMode]::UserExecute) |
                Should -Be [IO.UnixFileMode]::UserExecute
        }

        $environment = Get-IsolatedChildEnvironment -TempDirectory $temp -ProjectDirectory $project
        $environment.Contains('GIT_CONFIG_GLOBAL') | Should -BeTrue -Because 'the common runner must provide a controlled default'
        $environment['GIT_CONFIG_NOSYSTEM'] | Should -Be '1'
        $environment['GIT_CONFIG_COUNT'] | Should -Be '1'
        $environment['GIT_CONFIG_KEY_0'] | Should -BeExactly 'init.defaultBranch'
        $environment['GIT_CONFIG_VALUE_0'] | Should -BeExactly 'main'
        $environment['GIT_CONFIG_PARAMETERS'] | Should -BeExactly ''
        $result = Invoke-Task796GitChild -Environment $environment -CaseRoot (Join-Path $caseRoot 'child') -ExplicitGlobalConfig $config

        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        (Get-Task796MarkerCount -Path $marker) | Should -Be 1 -Because 'an explicit test-owned config must override the controlled default'
    }

    It 'GI03 serial wrapper restores absent Git config variables' {
        Import-Task796RunnerFunction -Name 'Get-IsolatedGitEnvironment'
        Import-Task796RunnerFunction -Name 'Invoke-WithIsolatedGitEnvironment'
        $states = [ordered]@{}
        foreach ($name in @(
            'GIT_CONFIG_GLOBAL',
            'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_COUNT',
            'GIT_CONFIG_PARAMETERS',
            'GIT_CONFIG_KEY_0',
            'GIT_CONFIG_VALUE_0'
        )) {
            $states[$name] = Get-Task796EnvironmentState -Name $name
        }
        try {
            foreach ($name in $states.Keys) {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
            $observed = Invoke-WithIsolatedGitEnvironment -ScriptBlock {
                [PSCustomObject]@{
                    Global     = [Environment]::GetEnvironmentVariable('GIT_CONFIG_GLOBAL', 'Process')
                    NoSystem   = [Environment]::GetEnvironmentVariable('GIT_CONFIG_NOSYSTEM', 'Process')
                    Count      = [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT', 'Process')
                    Parameters = [Environment]::GetEnvironmentVariable('GIT_CONFIG_PARAMETERS', 'Process')
                    Key0       = [Environment]::GetEnvironmentVariable('GIT_CONFIG_KEY_0', 'Process')
                    Value0     = [Environment]::GetEnvironmentVariable('GIT_CONFIG_VALUE_0', 'Process')
                }
            }

            $observed.Global | Should -Not -BeNullOrEmpty
            $observed.NoSystem | Should -Be '1'
            $observed.Count | Should -Be '1'
            $observed.Parameters | Should -BeExactly ''
            $observed.Key0 | Should -BeExactly 'init.defaultBranch'
            $observed.Value0 | Should -BeExactly 'main'
            foreach ($name in $states.Keys) {
                Test-Path -LiteralPath "Env:$name" | Should -BeFalse
            }
        } finally {
            foreach ($entry in $states.GetEnumerator()) {
                Restore-Task796EnvironmentState -Name ([string]$entry.Key) -State $entry.Value
            }
        }
    }

    It 'TB01 GI04 serial wrapper restores present Git config variables exactly' {
        Import-Task796RunnerFunction -Name 'Get-IsolatedGitEnvironment'
        Import-Task796RunnerFunction -Name 'Invoke-WithIsolatedGitEnvironment'
        $states = [ordered]@{}
        foreach ($name in @(
            'GIT_CONFIG_GLOBAL',
            'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_COUNT',
            'GIT_CONFIG_PARAMETERS',
            'GIT_CONFIG_KEY_0',
            'GIT_CONFIG_VALUE_0'
        )) {
            $states[$name] = Get-Task796EnvironmentState -Name $name
        }
        try {
            $env:GIT_CONFIG_GLOBAL = 'C:\task796\original.gitconfig'
            $env:GIT_CONFIG_NOSYSTEM = 'original-value'
            $env:GIT_CONFIG_COUNT = '1'
            $env:GIT_CONFIG_KEY_0 = 'core.hooksPath'
            $env:GIT_CONFIG_VALUE_0 = 'C:/task796/command-scope-hooks'
            $env:GIT_CONFIG_PARAMETERS = "'core.hooksPath=C:/task796/legacy-hooks'"
            {
                Invoke-WithIsolatedGitEnvironment -ScriptBlock {
                    $script:Task796ObservedGlobal = $env:GIT_CONFIG_GLOBAL
                    $script:Task796ObservedNoSystem = $env:GIT_CONFIG_NOSYSTEM
                    $script:Task796ObservedCount = $env:GIT_CONFIG_COUNT
                    $script:Task796ObservedParameters = $env:GIT_CONFIG_PARAMETERS
                    $script:Task796ObservedKey0 = $env:GIT_CONFIG_KEY_0
                    $script:Task796ObservedValue0 = $env:GIT_CONFIG_VALUE_0
                    $script:Task796ObservedGitOrigin = @(
                        & git -C $script:Task796RepoRoot config --show-origin --get core.hooksPath
                    ) -join "`n"
                    $script:Task796ObservedDefaultBranch = @(
                        & git -C $script:Task796RepoRoot config --get init.defaultBranch
                    ) -join "`n"
                    throw 'TASK796_EXPECTED_FAILURE'
                }
            } | Should -Throw '*TASK796_EXPECTED_FAILURE*'

            $script:Task796ObservedGlobal | Should -Not -Be 'C:\task796\original.gitconfig'
            $script:Task796ObservedNoSystem | Should -Be '1'
            $script:Task796ObservedCount | Should -Be '1'
            $script:Task796ObservedParameters | Should -BeExactly ''
            $script:Task796ObservedKey0 | Should -BeExactly 'init.defaultBranch'
            $script:Task796ObservedValue0 | Should -BeExactly 'main'
            $script:Task796ObservedDefaultBranch | Should -BeExactly 'main'
            $script:Task796ObservedGitOrigin | Should -Not -Match 'task796[/\\](command-scope|legacy)-hooks'
            $env:GIT_CONFIG_GLOBAL | Should -BeExactly 'C:\task796\original.gitconfig'
            $env:GIT_CONFIG_NOSYSTEM | Should -BeExactly 'original-value'
            $env:GIT_CONFIG_COUNT | Should -BeExactly '1'
            $env:GIT_CONFIG_PARAMETERS | Should -BeExactly "'core.hooksPath=C:/task796/legacy-hooks'"
            $env:GIT_CONFIG_KEY_0 | Should -BeExactly 'core.hooksPath'
            $env:GIT_CONFIG_VALUE_0 | Should -BeExactly 'C:/task796/command-scope-hooks'
        } finally {
            foreach ($entry in $states.GetEnumerator()) {
                Restore-Task796EnvironmentState -Name ([string]$entry.Key) -State $entry.Value
            }
        }
    }

    It 'GI05 direct worktree fixture is hook-isolated' {
        $source = [System.IO.File]::ReadAllText($script:Task796WorktreeTestPath, [System.Text.Encoding]::UTF8)
        $source | Should -Match 'core\.hooksPath' -Because 'the direct focused test must not depend on the caller global hook path'
        $source | Should -Match 'fixture-hooks' -Because 'the hook directory must be fixture-local and intentionally empty'
        $source | Should -Match 'Set-WorktreeHookGitIsolation' -Because 'the direct entry must replace arbitrary caller Git config before real Git runs'
        $source | Should -Match 'gpgSign = true' -Because 'the direct test must execute against a deterministic hostile non-hook global setting'
        $source | Should -Match 'GIT_CONFIG_COUNT' -Because 'modern command-scope config must be neutralized at the direct entry'
        $source | Should -Match 'GIT_CONFIG_PARAMETERS' -Because 'legacy command-scope config must be neutralized at the direct entry'
        $source | Should -Match 'init\.defaultBranch' -Because 'the direct entry must retain the suite-owned main branch identity'
        $source | Should -Match 'Restore-WorktreeHookEnvironmentState' -Because 'the direct entry must restore caller environment existence and values'
        ([regex]::Matches($source, 'Invoke-CheckedFixtureGit -GitArguments')).Count | Should -BeGreaterOrEqual 4 -Because 'every fixture setup Git command must preserve its own failure output'
    }

    It 'GI06 child stderr is retained in assertion evidence' {
        $source = [System.IO.File]::ReadAllText($script:Task796WorktreeTestPath, [System.Text.Encoding]::UTF8)
        $stderrAssertions = [regex]::Matches(
            $source,
            '(?m)^[ \t]*\$(?<resultVar>(?:result|\w+Result))\.ExitCode[ \t]*\|[ \t]*Should[ \t]+-Be[ \t]+0[ \t]+-Because[ \t]+\$\k<resultVar>\.StdErr[ \t]*$'
        )
        $stderrAssertions.Count | Should -Be 3 -Because 'all three worktree child exit assertions must carry stderr into NUnit'
    }

    It 'GI07 CI matrix executes the isolation suite' {
        $workflow = [System.IO.File]::ReadAllText(
            $script:Task796WorkflowPath,
            [System.Text.Encoding]::UTF8
        )
        $integrationShard = [regex]::Match(
            $workflow,
            '(?ms)^\s{10}- name:\s+integration\s*\r?\n.*?(?=^\s{10}- name:|^\s{4}steps:)'
        )

        $integrationShard.Success | Should -BeTrue
        [regex]::Matches(
            $integrationShard.Value,
            [regex]::Escape('tests/PesterGitIsolation.Tests.ps1')
        ).Count | Should -Be 1 -Because 'the new regression suite must execute in its owning CI shard'
    }

    It 'RI01 rejects a candidate tree that does not match source bytes' {
        $repositoryRoot = Join-Path $TestDrive 'ri01-source'
        $candidateTree = New-Task796FixtureRepository -RepositoryRoot $repositoryRoot
        $trackedPath = Join-Path $repositoryRoot 'tracked.txt'
        Write-Task796Utf8File -Path $trackedPath -Content 'changed-after-candidate'
        $stateBefore = Get-Task796FixtureRepositoryState -RepositoryRoot $repositoryRoot
        $functionSource = Get-Task796FunctionSource -Name 'Assert-PesterCandidateTreeMatchesSource'
        $rejection = $null
        if (-not [string]::IsNullOrWhiteSpace($functionSource)) {
            Import-Task796RunnerFunction -Name 'Assert-PesterCandidateTreeMatchesSource'
            try {
                Assert-PesterCandidateTreeMatchesSource `
                    -RepositoryRoot $repositoryRoot `
                    -CandidateTree $candidateTree
            } catch {
                $rejection = $_
            }
        }
        $stateAfter = Get-Task796FixtureRepositoryState -RepositoryRoot $repositoryRoot

        $stateAfter.IndexSha256 | Should -BeExactly $stateBefore.IndexSha256
        $stateAfter.ConfigSha256 | Should -BeExactly $stateBefore.ConfigSha256
        $stateAfter.TrackedDiff | Should -BeExactly $stateBefore.TrackedDiff
        $stateAfter.Refs | Should -BeExactly $stateBefore.Refs
        $functionSource | Should -Not -BeNullOrEmpty -Because 'RI01 requires one candidate-tree admission authority'
        $rejection | Should -Not -BeNullOrEmpty
        $rejection.Exception.Message | Should -Match 'SOURCE_CANDIDATE_TREE_MISMATCH'
    }

    It 'RI02 materializes the exact candidate tree in a private repository' {
        $sourceRoot = Join-Path $TestDrive 'ri02-source'
        $privateRoot = Join-Path $TestDrive 'ri02-private'
        $candidateTree = New-Task796FixtureRepository `
            -RepositoryRoot $sourceRoot `
            -RelativePaths @('tracked.txt', 'nested/file.txt')
        $stateBefore = Get-Task796FixtureRepositoryState -RepositoryRoot $sourceRoot
        $functionSource = Get-Task796FunctionSource -Name 'New-PesterPrivateRepository'
        $materialized = $null
        if (-not [string]::IsNullOrWhiteSpace($functionSource)) {
            Import-Task796RunnerFunction -Name 'Invoke-PesterGitCommand'
            Import-Task796RunnerFunction -Name 'New-PesterPrivateRepository'
            $materialized = New-PesterPrivateRepository `
                -SourceRepositoryRoot $sourceRoot `
                -CandidateTree $candidateTree `
                -DestinationRoot $privateRoot
        }
        $stateAfter = Get-Task796FixtureRepositoryState -RepositoryRoot $sourceRoot

        $stateAfter.IndexSha256 | Should -BeExactly $stateBefore.IndexSha256
        $stateAfter.ConfigSha256 | Should -BeExactly $stateBefore.ConfigSha256
        $stateAfter.TrackedDiff | Should -BeExactly $stateBefore.TrackedDiff
        $stateAfter.Refs | Should -BeExactly $stateBefore.Refs
        $functionSource | Should -Not -BeNullOrEmpty -Because 'RI02 requires one exact-tree materializer'
        $materialized.RepositoryRoot | Should -BeExactly ([System.IO.Path]::GetFullPath($privateRoot))
        $materialized.Tree | Should -BeExactly $candidateTree
        Test-Path -LiteralPath (Join-Path $privateRoot 'nested\file.txt') -PathType Leaf |
            Should -BeTrue
        $privateTree = [string](
            Invoke-Task796CheckedGit -RepositoryRoot $privateRoot -Arguments @(
                'write-tree'
            ) | Select-Object -First 1
        ).Trim()
        $privateTree | Should -BeExactly $candidateTree
    }

    It 'RI03 runs discovery only from the private repository' {
        $privateRoot = Join-Path $TestDrive 'ri03-private'
        $resultRoot = Join-Path $TestDrive 'ri03-result'
        $tempRoot = Join-Path $TestDrive 'ri03-temp'
        $projectRoot = Join-Path $TestDrive 'ri03-project'
        foreach ($path in @($privateRoot, $resultRoot, $tempRoot, $projectRoot)) {
            [System.IO.Directory]::CreateDirectory($path) | Out-Null
        }
        $functionSource = Get-Task796FunctionSource -Name 'New-PesterDiscoverySpec'
        $spec = $null
        if (-not [string]::IsNullOrWhiteSpace($functionSource)) {
            Import-Task796RunnerFunction -Name 'New-PesterDiscoverySpec'
            $spec = New-PesterDiscoverySpec `
                -RepositoryRoot $privateRoot `
                -ResultRoot $resultRoot `
                -TempDirectory $tempRoot `
                -ProjectDirectory $projectRoot `
                -PesterModulePath 'Pester.psd1'
        }
        $launcherSource = Get-Task796FunctionSource -Name 'Invoke-IsolatedPwshWorkers'

        $functionSource | Should -Not -BeNullOrEmpty -Because 'RI03 requires one discovery-spec authority'
        $spec.RepositoryRoot | Should -BeExactly ([System.IO.Path]::GetFullPath($privateRoot))
        $spec.TestsPath | Should -BeExactly (Join-Path ([System.IO.Path]::GetFullPath($privateRoot)) 'tests')
        $launcherSource | Should -Match '\$spec\.RepositoryRoot' -Because 'the child working directory must come from its own exact-tree spec'
        $launcherSource | Should -Not -Match '\$startInfo\.WorkingDirectory\s*=\s*\$RepositoryRoot'
    }

    It 'RI04 assigns both mutable suites to one private serial worker' {
        $fixtureRoot = Join-Path $TestDrive 'ri04'
        $testsRoot = Join-Path $fixtureRoot 'tests'
        [System.IO.Directory]::CreateDirectory($testsRoot) | Out-Null
        $paths = @(
            (Join-Path $testsRoot 'HarnessContract.Tests.ps1'),
            (Join-Path $testsRoot 'PublicSurfacePolicy.Tests.ps1'),
            (Join-Path $testsRoot 'ReadOnly.Tests.ps1')
        )
        foreach ($path in $paths) {
            Write-Task796Utf8File -Path $path -Content "Describe 'fixture' { It 'passes' { `$true | Should -BeTrue } }"
        }
        $discovery = [PSCustomObject]@{
            total = 3
            tests = @(
                [PSCustomObject]@{ file = $paths[0] },
                [PSCustomObject]@{ file = $paths[1] },
                [PSCustomObject]@{ file = $paths[2] }
            )
        }
        $script:Task796BridgeFixturePath = $paths[2]
        function script:Get-BridgeShards {
            param([string]$RepositoryRoot)
            return @(
                [PSCustomObject]@{
                    Name = 'bridge-fixture'
                    Paths = @($script:Task796BridgeFixturePath)
                }
            )
        }
        Import-Task796RunnerFunction -Name 'New-PesterWorkUnits'
        $units = @(New-PesterWorkUnits -RepositoryRoot $fixtureRoot -DiscoveryResult $discovery)
        $mutable = @($units | Where-Object { [string]$_.WorkerId -ceq 'mutable-repository' })

        $units.Count | Should -Be 2 -Because 'two mutable files must replace their two source workers with one private worker'
        $mutable.Count | Should -Be 1
        $mutable[0].Paths.Count | Should -Be 2
        @($mutable[0].Paths | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object) |
            Should -Be @('HarnessContract.Tests.ps1', 'PublicSurfacePolicy.Tests.ps1')
        $mutable[0].PSObject.Properties.Name -contains 'RepositoryMode' | Should -BeTrue
        $mutable[0].RepositoryMode | Should -BeExactly 'private'
    }

    It 'RI05 keeps private-index and fixture-local suites parallel' {
        $fixtureRoot = Join-Path $TestDrive 'ri05'
        $testsRoot = Join-Path $fixtureRoot 'tests'
        [System.IO.Directory]::CreateDirectory($testsRoot) | Out-Null
        $names = @(
            'HarnessContract.Tests.ps1',
            'PublicSurfacePolicy.Tests.ps1',
            'NpmReleasePackage.Tests.ps1',
            'Integration.WorktreeHook.Tests.ps1'
        )
        $paths = @(
            $names | ForEach-Object {
                $path = Join-Path $testsRoot $_
                Write-Task796Utf8File -Path $path -Content "Describe 'fixture' { It 'passes' { `$true | Should -BeTrue } }"
                $path
            }
        )
        $discovery = [PSCustomObject]@{
            total = $paths.Count
            tests = @($paths | ForEach-Object { [PSCustomObject]@{ file = $_ } })
        }
        $script:Task796BridgeFixturePath = $paths[3]
        function script:Get-BridgeShards {
            param([string]$RepositoryRoot)
            return @(
                [PSCustomObject]@{
                    Name = 'bridge-fixture'
                    Paths = @($script:Task796BridgeFixturePath)
                }
            )
        }
        Import-Task796RunnerFunction -Name 'New-PesterWorkUnits'
        $units = @(New-PesterWorkUnits -RepositoryRoot $fixtureRoot -DiscoveryResult $discovery)
        $sourceUnits = @(
            $units | Where-Object {
                (Split-Path -Leaf ([string]$_.Paths[0])) -in @(
                    'NpmReleasePackage.Tests.ps1',
                    'Integration.WorktreeHook.Tests.ps1'
                )
            }
        )

        $sourceUnits.Count | Should -Be 2
        foreach ($unit in $sourceUnits) {
            $unit.Paths.Count | Should -Be 1
            $unit.PSObject.Properties.Name -contains 'RepositoryMode' | Should -BeTrue
            $unit.RepositoryMode | Should -BeExactly 'source'
        }
        ($units.ExpectedCount | Measure-Object -Sum).Sum | Should -Be 4
    }

    It 'RI06 rejects source index config or tracked-byte drift' {
        $repositoryRoot = Join-Path $TestDrive 'ri06-source'
        New-Task796FixtureRepository `
            -RepositoryRoot $repositoryRoot `
            -RelativePaths @('tracked.txt', 'staged.txt') | Out-Null
        $functionSource = Get-Task796FunctionSource -Name 'Get-PesterRepositoryStateIdentity'
        $assertSource = Get-Task796FunctionSource -Name 'Assert-PesterRepositoryStateIdentity'
        $before = Get-Task796FixtureRepositoryState -RepositoryRoot $repositoryRoot
        Write-Task796Utf8File -Path (Join-Path $repositoryRoot 'tracked.txt') -Content 'tracked-drift'
        Write-Task796Utf8File -Path (Join-Path $repositoryRoot 'staged.txt') -Content 'index-drift'
        Invoke-Task796CheckedGit -RepositoryRoot $repositoryRoot -Arguments @(
            'add', '--', 'staged.txt'
        ) | Out-Null
        Invoke-Task796CheckedGit -RepositoryRoot $repositoryRoot -Arguments @(
            'config', '--local', 'task796.drift', 'config-drift'
        ) | Out-Null
        $driftBeforeGate = Get-Task796FixtureRepositoryState -RepositoryRoot $repositoryRoot
        $rejection = $null
        if (
            -not [string]::IsNullOrWhiteSpace($functionSource) -and
            -not [string]::IsNullOrWhiteSpace($assertSource)
        ) {
            Import-Task796RunnerFunction -Name 'Invoke-PesterGitCommand'
            Import-Task796RunnerFunction -Name 'Get-PesterRepositoryStateIdentity'
            Import-Task796RunnerFunction -Name 'Assert-PesterRepositoryStateIdentity'
            $expected = [PSCustomObject]@{
                TrackedIdentity = $before.TrackedDiff
                IndexIdentity = $before.IndexSha256
                ConfigIdentity = $before.ConfigSha256
                RefsIdentity = $before.Refs
            }
            $actual = Get-PesterRepositoryStateIdentity -RepositoryRoot $repositoryRoot
            try {
                Assert-PesterRepositoryStateIdentity -Expected $expected -Actual $actual
            } catch {
                $rejection = $_
            }
        }
        $driftAfterGate = Get-Task796FixtureRepositoryState -RepositoryRoot $repositoryRoot

        $driftAfterGate.IndexSha256 | Should -BeExactly $driftBeforeGate.IndexSha256
        $driftAfterGate.ConfigSha256 | Should -BeExactly $driftBeforeGate.ConfigSha256
        $driftAfterGate.TrackedDiff | Should -BeExactly $driftBeforeGate.TrackedDiff
        $functionSource | Should -Not -BeNullOrEmpty
        $assertSource | Should -Not -BeNullOrEmpty
        $rejection | Should -Not -BeNullOrEmpty
        $rejection.Exception.Message | Should -Match 'SOURCE_REPOSITORY_DRIFT'
        $rejection.Exception.Message | Should -Match 'tracked'
        $rejection.Exception.Message | Should -Match 'index'
        $rejection.Exception.Message | Should -Match 'config'
    }

    It 'RI07 TB07 cleans private repositories after success and failure' {
        $sourceRoot = Join-Path $TestDrive 'ri07-source'
        $candidateTree = New-Task796FixtureRepository -RepositoryRoot $sourceRoot
        $stateBefore = Get-Task796FixtureRepositoryState -RepositoryRoot $sourceRoot
        $functionSource = Get-Task796FunctionSource -Name 'Invoke-WithPesterPrivateRepository'
        if (-not [string]::IsNullOrWhiteSpace($functionSource)) {
            foreach ($name in @(
                'Invoke-PesterGitCommand',
                'New-PesterPrivateRepository',
                'Remove-PesterPrivateRepository',
                'Invoke-WithPesterPrivateRepository'
            )) {
                Import-Task796RunnerFunction -Name $name
            }
            $successRoot = Join-Path $TestDrive 'ri07-success'
            $observed = Invoke-WithPesterPrivateRepository `
                -SourceRepositoryRoot $sourceRoot `
                -CandidateTree $candidateTree `
                -DestinationRoot $successRoot `
                -ScriptBlock {
                    param($privateRepository)
                    return $privateRepository.Tree
                }
            $observed | Should -BeExactly $candidateTree
            Test-Path -LiteralPath $successRoot | Should -BeFalse

            $failureRoot = Join-Path $TestDrive 'ri07-failure'
            {
                Invoke-WithPesterPrivateRepository `
                    -SourceRepositoryRoot $sourceRoot `
                    -CandidateTree $candidateTree `
                    -DestinationRoot $failureRoot `
                    -ScriptBlock {
                        param($privateRepository)
                        throw 'RI07_EXPECTED_BODY_FAILURE'
                    }
            } | Should -Throw '*RI07_EXPECTED_BODY_FAILURE*'
            Test-Path -LiteralPath $failureRoot | Should -BeFalse
        }
        $stateAfter = Get-Task796FixtureRepositoryState -RepositoryRoot $sourceRoot

        $stateAfter.IndexSha256 | Should -BeExactly $stateBefore.IndexSha256
        $stateAfter.ConfigSha256 | Should -BeExactly $stateBefore.ConfigSha256
        $stateAfter.TrackedDiff | Should -BeExactly $stateBefore.TrackedDiff
        $stateAfter.Refs | Should -BeExactly $stateBefore.Refs
        $functionSource | Should -Not -BeNullOrEmpty -Because 'RI07 requires one success/failure cleanup owner'
    }

    It 'RI08 TB08 preserves child stderr for materialization and cleanup failures' {
        $repositoryRoot = Join-Path $TestDrive 'ri08-source'
        New-Task796FixtureRepository -RepositoryRoot $repositoryRoot | Out-Null
        $stateBefore = Get-Task796FixtureRepositoryState -RepositoryRoot $repositoryRoot
        $functionSource = Get-Task796FunctionSource -Name 'Invoke-PesterGitCommand'
        $failure = $null
        if (-not [string]::IsNullOrWhiteSpace($functionSource)) {
            Import-Task796RunnerFunction -Name 'Invoke-PesterGitCommand'
            try {
                Invoke-PesterGitCommand `
                    -RepositoryRoot $repositoryRoot `
                    -Arguments @('task796-command-that-does-not-exist') `
                    -FailureToken 'RI08_NATIVE_FAILURE'
            } catch {
                $failure = $_
            }
        }
        $stateAfter = Get-Task796FixtureRepositoryState -RepositoryRoot $repositoryRoot

        $stateAfter.IndexSha256 | Should -BeExactly $stateBefore.IndexSha256
        $stateAfter.ConfigSha256 | Should -BeExactly $stateBefore.ConfigSha256
        $stateAfter.TrackedDiff | Should -BeExactly $stateBefore.TrackedDiff
        $stateAfter.Refs | Should -BeExactly $stateBefore.Refs
        $functionSource | Should -Not -BeNullOrEmpty -Because 'RI08 requires one native diagnostic owner'
        $failure | Should -Not -BeNullOrEmpty
        $failure.Exception.Message | Should -Match 'RI08_NATIVE_FAILURE'
        $failure.Exception.Message | Should -Match 'exit='
        $failure.Exception.Message | Should -Match 'stderr='
    }

    It 'RI09 keeps private extraction within the declared PowerShell 7.0 runtime' {
        $runnerSource = Get-Content -LiteralPath $script:Task796RunnerPath -Raw -Encoding UTF8
        $materializerSource = Get-Task796FunctionSource -Name 'New-PesterPrivateRepository'

        $runnerFirstLine = ($runnerSource -split '\r?\n', 2)[0]
        $runnerFirstLine | Should -BeExactly '#Requires -Version 7.0'
        ($materializerSource -match 'System\.Formats\.Tar') | Should -BeFalse `
            -Because 'PowerShell 7.0-7.2 run on runtimes older than .NET 7'
        ($materializerSource -match "'--format=zip'") | Should -BeTrue
        ($materializerSource -match '\[System\.IO\.Compression\.ZipFile\]::ExtractToDirectory') |
            Should -BeTrue
    }
}
