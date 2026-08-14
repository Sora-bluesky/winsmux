$ErrorActionPreference = 'Stop'

Describe 'sh-worktree integration' {
    BeforeAll {
        $script:FixtureBaseRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'winsmux-tests\worktree-hook'
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:SourceHookRoot = Join-Path $script:RepoRoot '.claude\hooks'
        $script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $nodeCommand) {
            throw 'node was not found in PATH.'
        }

        $script:NodePath = if ($nodeCommand.Path) { $nodeCommand.Path } else { $nodeCommand.Name }
        $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $script:GitPath = if ($gitCommand.Path) { $gitCommand.Path } else { $gitCommand.Source }
        if ([string]::IsNullOrWhiteSpace($script:GitPath) -or -not (Test-Path -LiteralPath $script:GitPath -PathType Leaf)) {
            throw 'A concrete Git executable could not be resolved.'
        }

        function Get-WorktreeFixtureGitEnvironment {
            param([Parameter(Mandatory = $true)][string]$FixtureRoot)

            $emptyHooks = Join-Path $FixtureRoot 'empty-hooks'
            $emptyTemplate = Join-Path $FixtureRoot 'empty-template'
            New-Item -ItemType Directory -Path $emptyHooks, $emptyTemplate -Force | Out-Null
            $nullDevice = if ($IsWindows) { 'NUL' } else { '/dev/null' }
            return [ordered]@{
                GIT_CONFIG_GLOBAL = $nullDevice
                GIT_CONFIG_SYSTEM = $nullDevice
                GIT_CONFIG_NOSYSTEM = '1'
                GIT_CONFIG_COUNT = '5'
                GIT_CONFIG_KEY_0 = 'init.defaultBranch'
                GIT_CONFIG_VALUE_0 = 'main'
                GIT_CONFIG_KEY_1 = 'core.hooksPath'
                GIT_CONFIG_VALUE_1 = $emptyHooks
                GIT_CONFIG_KEY_2 = 'commit.gpgSign'
                GIT_CONFIG_VALUE_2 = 'false'
                GIT_CONFIG_KEY_3 = 'tag.gpgSign'
                GIT_CONFIG_VALUE_3 = 'false'
                GIT_CONFIG_KEY_4 = 'core.autocrlf'
                GIT_CONFIG_VALUE_4 = 'false'
                GIT_TEMPLATE_DIR = $emptyTemplate
                GIT_ATTR_NOSYSTEM = '1'
                GIT_OPTIONAL_LOCKS = '0'
                GIT_TERMINAL_PROMPT = '0'
                GCM_INTERACTIVE = 'Never'
            }
        }

        function Get-WorktreeFixtureProcessEnvironment {
            param(
                [Parameter(Mandatory = $true)][System.Collections.IDictionary]$GitEnvironment,
                [System.Collections.IDictionary]$ExtraEnvironment = @{}
            )

            $environment = [ordered]@{}
            foreach ($name in @(
                'APPDATA', 'ComSpec', 'HOME', 'LOCALAPPDATA', 'OS', 'Path', 'PATHEXT',
                'ProgramData', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432',
                'PSModulePath', 'SystemDrive', 'SystemRoot', 'TEMP', 'TMP', 'USERPROFILE', 'windir'
            )) {
                $value = [Environment]::GetEnvironmentVariable($name, 'Process')
                if (-not [string]::IsNullOrEmpty($value)) { $environment[$name] = $value }
            }
            foreach ($entry in $GitEnvironment.GetEnumerator()) {
                $environment[[string]$entry.Key] = [string]$entry.Value
            }
            foreach ($entry in $ExtraEnvironment.GetEnumerator()) {
                $environment[[string]$entry.Key] = [string]$entry.Value
            }
            return $environment
        }

        function Invoke-WorktreeFixtureProcess {
            param(
                [Parameter(Mandatory = $true)][string]$FilePath,
                [Parameter(Mandatory = $true)][string]$WorkingDirectory,
                [Parameter(Mandatory = $true)][string[]]$Arguments,
                [Parameter(Mandatory = $true)][System.Collections.IDictionary]$GitEnvironment,
                [System.Collections.IDictionary]$ExtraEnvironment = @{},
                [string]$StandardInput
            )

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $FilePath
            foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
            $startInfo.WorkingDirectory = $WorkingDirectory
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.Environment.Clear()
            $processEnvironment = Get-WorktreeFixtureProcessEnvironment -GitEnvironment $GitEnvironment -ExtraEnvironment $ExtraEnvironment
            foreach ($entry in $processEnvironment.GetEnumerator()) {
                $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
            }

            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                if ($null -ne $StandardInput) { $process.StandardInput.Write($StandardInput) }
                $process.StandardInput.Close()
                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                return [PSCustomObject]@{
                    ExitCode = [int]$process.ExitCode
                    StdOut = $stdout.Trim()
                    StdErr = $stderr.Trim()
                }
            } finally {
                $process.Dispose()
            }
        }

        function Invoke-WorktreeFixtureGit {
            param(
                [Parameter(Mandatory = $true)][string]$RepoRoot,
                [Parameter(Mandatory = $true)][string[]]$Arguments,
                [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment,
                [System.Collections.IDictionary]$ExtraEnvironment = @{}
            )

            $result = Invoke-WorktreeFixtureProcess -FilePath $script:GitPath -WorkingDirectory $RepoRoot -Arguments $Arguments -GitEnvironment $Environment -ExtraEnvironment $ExtraEnvironment
            if ($result.ExitCode -ne 0) {
                throw "git $($Arguments -join ' ') failed ($($result.ExitCode)): $($result.StdErr)"
            }
            return $result
        }

        function Resolve-WorktreeFixtureGitPath {
            param(
                [Parameter(Mandatory = $true)][string]$RepoRoot,
                [Parameter(Mandatory = $true)][string]$GitPath
            )

            if ([System.IO.Path]::IsPathRooted($GitPath)) {
                return [System.IO.Path]::GetFullPath($GitPath)
            }
            return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $GitPath))
        }

        function Get-WorktreeFixtureFileState {
            param([Parameter(Mandatory = $true)][string]$Path)

            $fullPath = [System.IO.Path]::GetFullPath($Path)
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                return [PSCustomObject]@{ Path = $fullPath; Exists = $false; Length = 0L; Sha256 = '' }
            }
            $item = Get-Item -LiteralPath $fullPath
            return [PSCustomObject]@{
                Path = $fullPath
                Exists = $true
                Length = [long]$item.Length
                Sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }

        function Get-WorktreeFixtureRepositoryState {
            param(
                [Parameter(Mandatory = $true)][string]$RepoRoot,
                [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
            )

            $tracked = (Invoke-WorktreeFixtureGit -RepoRoot $RepoRoot -Environment $Environment -Arguments @('ls-files', '-z', '--cached')).StdOut
            $ledger = [System.Collections.Generic.List[string]]::new()
            $repoPrefix = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            foreach ($relativePath in @($tracked -split "`0" | Where-Object { $_ })) {
                $fullPath = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $relativePath))
                if (-not $fullPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Tracked path escapes repository root: $relativePath"
                }
                $state = Get-WorktreeFixtureFileState -Path $fullPath
                if ($state.Exists) {
                    $ledger.Add("$relativePath`0$($state.Length)`0$($state.Sha256)")
                } else {
                    $ledger.Add("$relativePath`0<absent-or-nonfile>")
                }
            }
            $diff = (Invoke-WorktreeFixtureGit -RepoRoot $RepoRoot -Environment $Environment -Arguments @('diff-files', '--raw', '--no-abbrev', '-z')).StdOut
            $ledger.Add("<diff-files>`0$diff")
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $trackedBytes = ([Convert]::ToHexString($sha.ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes((@($ledger | Sort-Object) -join "`n"))
                ))).ToLowerInvariant()
            } finally {
                $sha.Dispose()
            }

            $indexText = (Invoke-WorktreeFixtureGit -RepoRoot $RepoRoot -Environment $Environment -Arguments @('rev-parse', '--git-path', 'index')).StdOut
            $configs = [System.Collections.Generic.List[object]]::new()
            foreach ($configName in @('config', 'config.worktree')) {
                $configText = (Invoke-WorktreeFixtureGit -RepoRoot $RepoRoot -Environment $Environment -Arguments @('rev-parse', '--git-path', $configName)).StdOut
                $configs.Add((Get-WorktreeFixtureFileState -Path (Resolve-WorktreeFixtureGitPath -RepoRoot $RepoRoot -GitPath $configText)))
            }
            return [PSCustomObject]@{
                TrackedBytes = $trackedBytes
                Index = Get-WorktreeFixtureFileState -Path (Resolve-WorktreeFixtureGitPath -RepoRoot $RepoRoot -GitPath $indexText)
                Refs = (Invoke-WorktreeFixtureGit -RepoRoot $RepoRoot -Environment $Environment -Arguments @('show-ref', '--head', '--dereference')).StdOut
                LocalConfigs = $configs.ToArray()
            }
        }

        function Assert-WorktreeFixtureFileState {
            param(
                [Parameter(Mandatory = $true)]$Expected,
                [Parameter(Mandatory = $true)]$Actual
            )

            $Actual.Path | Should -BeExactly $Expected.Path
            $Actual.Exists | Should -Be $Expected.Exists
            $Actual.Length | Should -Be $Expected.Length
            $Actual.Sha256 | Should -BeExactly $Expected.Sha256
        }

        function Assert-WorktreeFixtureRepositoryState {
            param(
                [Parameter(Mandatory = $true)]$Expected,
                [Parameter(Mandatory = $true)]$Actual
            )

            $Actual.TrackedBytes | Should -BeExactly $Expected.TrackedBytes
            Assert-WorktreeFixtureFileState -Expected $Expected.Index -Actual $Actual.Index
            $Actual.Refs | Should -BeExactly $Expected.Refs
            @($Actual.LocalConfigs).Count | Should -Be @($Expected.LocalConfigs).Count
            for ($index = 0; $index -lt @($Expected.LocalConfigs).Count; $index++) {
                Assert-WorktreeFixtureFileState -Expected @($Expected.LocalConfigs)[$index] -Actual @($Actual.LocalConfigs)[$index]
            }
        }

        function Invoke-WorktreeHook {
            param(
                [Parameter(Mandatory = $true)][string]$RepoRoot,
                [Parameter(Mandatory = $true)][hashtable]$Payload,
                [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
            )

            $hookPath = Join-Path $RepoRoot '.claude\hooks\sh-worktree.js'
            $json = $Payload | ConvertTo-Json -Compress -Depth 10

            return Invoke-WorktreeFixtureProcess `
                -FilePath $script:NodePath `
                -WorkingDirectory $RepoRoot `
                -Arguments @($hookPath) `
                -GitEnvironment $Environment `
                -StandardInput $json
        }

        function Get-CallerGitEnvironment {
            $snapshot = [ordered]@{}
            foreach ($entry in Get-ChildItem Env:) {
                if ($entry.Name -like 'GIT_*' -or $entry.Name -eq 'GCM_INTERACTIVE') {
                    $snapshot[$entry.Name] = [string]$entry.Value
                }
            }
            return $snapshot
        }

        function Restore-CallerGitEnvironment {
            param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Snapshot)

            foreach ($entry in @(Get-ChildItem Env:)) {
                if ($entry.Name -like 'GIT_*' -or $entry.Name -eq 'GCM_INTERACTIVE') {
                    Remove-Item -LiteralPath ('Env:' + $entry.Name) -ErrorAction SilentlyContinue
                }
            }
            foreach ($entry in $Snapshot.GetEnumerator()) {
                [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
            }
        }

        function Write-WorktreeFixtureHook {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)][string]$MarkerVariable
            )

            $content = "#!/bin/sh`n" + ('printf ''%s\n'' hook >> "$' + $MarkerVariable + '"') + "`n"
            [System.IO.File]::WriteAllText($Path, $content, $script:Utf8NoBom)
            if (-not $IsWindows) {
                [System.IO.File]::SetUnixFileMode(
                    $Path,
                    [System.IO.UnixFileMode]::UserRead -bor
                        [System.IO.UnixFileMode]::UserWrite -bor
                        [System.IO.UnixFileMode]::UserExecute
                )
            }
        }

        function New-WorktreeHookFixture {
            param([System.Collections.IDictionary]$ExtraEnvironment = @{})

            $fixtureRoot = Join-Path $script:FixtureBaseRoot ([guid]::NewGuid().ToString('N'))
            $script:FixtureRoot = $fixtureRoot
            $repoRoot = Join-Path $fixtureRoot 'repo'
            $worktreeTarget = Join-Path $repoRoot '.worktrees\feature-auth'
            $gitEnvironment = Get-WorktreeFixtureGitEnvironment -FixtureRoot $fixtureRoot

            New-Item -ItemType Directory -Path (Join-Path $repoRoot '.claude\hooks\lib') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $repoRoot '.claude\patterns') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $repoRoot '.claude\rules') -Force | Out-Null

            Copy-Item (Join-Path $script:SourceHookRoot 'sh-worktree.js') (Join-Path $repoRoot '.claude\hooks\sh-worktree.js')
            Copy-Item (Join-Path $script:SourceHookRoot 'lib\sh-utils.js') (Join-Path $repoRoot '.claude\hooks\lib\sh-utils.js')

            Set-Content -Path (Join-Path $repoRoot '.claude\settings.json') -Value '{}' -Encoding UTF8
            Set-Content -Path (Join-Path $repoRoot '.claude\patterns\injection-patterns.json') -Value '{"categories":{}}' -Encoding UTF8
            Set-Content -Path (Join-Path $repoRoot '.claude\rules\sample.md') -Value '# rule' -Encoding UTF8
            Set-Content -Path (Join-Path $repoRoot '.claude\hooks\sh-extra.js') -Value 'console.log("extra");' -Encoding UTF8
            Set-Content -Path (Join-Path $repoRoot 'README.md') -Value 'fixture' -Encoding UTF8

            [void](Invoke-WorktreeFixtureGit -RepoRoot $repoRoot -Environment $gitEnvironment -ExtraEnvironment $ExtraEnvironment -Arguments @('init'))
            [void](Invoke-WorktreeFixtureGit -RepoRoot $repoRoot -Environment $gitEnvironment -ExtraEnvironment $ExtraEnvironment -Arguments @('add', '--', '.'))
            [void](Invoke-WorktreeFixtureGit -RepoRoot $repoRoot -Environment $gitEnvironment -ExtraEnvironment $ExtraEnvironment -Arguments @(
                '-c', 'user.name=Test User', '-c', 'user.email=test@example.invalid',
                'commit', '-m', 'init'
            ))

            return [PSCustomObject]@{
                Root           = $fixtureRoot
                RepoRoot       = $repoRoot
                WorktreeTarget = $worktreeTarget
                GitEnvironment = $gitEnvironment
            }
        }
    }

    AfterEach {
        if ($script:FixtureRoot -and (Test-Path $script:FixtureRoot)) {
            Remove-Item -Path $script:FixtureRoot -Recurse -Force
        }
        $script:FixtureRoot = $null
    }

    It 'creates a git worktree and prints the absolute path on stdout' {
        $fixture = New-WorktreeHookFixture
        $script:FixtureRoot = $fixture.Root

        $result = Invoke-WorktreeHook -RepoRoot $fixture.RepoRoot -Environment $fixture.GitEnvironment -Payload @{
            hook_event_name = 'WorktreeCreate'
            session_id      = 'session-1'
            cwd             = $fixture.RepoRoot
            name            = 'feature-auth'
        }

        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -Be $fixture.WorktreeTarget
        Test-Path $fixture.WorktreeTarget | Should -Be $true
        Test-Path (Join-Path $fixture.WorktreeTarget '.claude\settings.json') | Should -Be $true
        Test-Path (Join-Path $fixture.WorktreeTarget '.claude\hooks\sh-extra.js') | Should -Be $true
    }

    It 'merges evidence and removes the worktree on WorktreeRemove' {
        $fixture = New-WorktreeHookFixture
        $script:FixtureRoot = $fixture.Root

        $createResult = Invoke-WorktreeHook -RepoRoot $fixture.RepoRoot -Environment $fixture.GitEnvironment -Payload @{
            hook_event_name = 'WorktreeCreate'
            session_id      = 'session-2'
            cwd             = $fixture.RepoRoot
            name            = 'feature-auth'
        }

        $createResult.ExitCode | Should -Be 0

        $ledgerDir = Join-Path $fixture.WorktreeTarget '.shield-harness\logs'
        New-Item -ItemType Directory -Path $ledgerDir -Force | Out-Null
        Set-Content -Path (Join-Path $ledgerDir 'evidence-ledger.jsonl') -Value '{"event":"child-entry"}' -Encoding UTF8

        $removeResult = Invoke-WorktreeHook -RepoRoot $fixture.RepoRoot -Environment $fixture.GitEnvironment -Payload @{
            hook_event_name = 'WorktreeRemove'
            session_id      = 'session-2'
            cwd             = $fixture.RepoRoot
            worktree_path   = $fixture.WorktreeTarget
        }

        $removeResult.ExitCode | Should -Be 0
        Test-Path $fixture.WorktreeTarget | Should -Be $false

        $mergedLedgerPath = Join-Path $fixture.RepoRoot '.claude\logs\evidence-ledger.jsonl'
        Test-Path $mergedLedgerPath | Should -Be $true
        $mergedEntry = @(
            Get-Content -Path $mergedLedgerPath |
                Where-Object { $_.Trim() } |
                ForEach-Object { $_ | ConvertFrom-Json }
        ) | Where-Object { $_.event -eq 'child-entry' } | Select-Object -First 1

        $mergedEntry | Should -Not -BeNullOrEmpty
        $mergedEntry.event | Should -Be 'child-entry'
        $mergedEntry.source_worktree | Should -Be $fixture.WorktreeTarget
    }

    It 'isolates direct Git calls from external hooks and permits one explicit fixture-local hook' {
        $callerBefore = Get-CallerGitEnvironment
        $sourceStateEnvironment = Get-WorktreeFixtureGitEnvironment -FixtureRoot (Join-Path $TestDrive 'source-state')
        $sourceBefore = Get-WorktreeFixtureRepositoryState -RepoRoot $script:RepoRoot -Environment $sourceStateEnvironment
        $externalHooks = Join-Path $TestDrive 'external-hooks'
        $hostileTemplate = Join-Path $TestDrive 'hostile-template'
        New-Item -ItemType Directory -Path $externalHooks, (Join-Path $hostileTemplate 'hooks') -Force | Out-Null
        $externalMarker = Join-Path $TestDrive 'external.marker'
        $localMarker = Join-Path $TestDrive 'local.marker'
        Write-WorktreeFixtureHook -Path (Join-Path $externalHooks 'pre-commit') -MarkerVariable 'WINSMUX_EXTERNAL_HOOK_MARKER'
        Write-WorktreeFixtureHook -Path (Join-Path $hostileTemplate 'hooks\pre-commit') -MarkerVariable 'WINSMUX_EXTERNAL_HOOK_MARKER'
        $hostileConfig = Join-Path $TestDrive 'hostile.gitconfig'
        $externalUnix = $externalHooks.Replace('\', '/')
        [System.IO.File]::WriteAllText($hostileConfig, "[core]`n`thooksPath = $externalUnix`n", $script:Utf8NoBom)
        $markerEnvironment = [ordered]@{
            WINSMUX_EXTERNAL_HOOK_MARKER = $externalMarker
            WINSMUX_LOCAL_HOOK_MARKER = $localMarker
        }

        try {
            [Environment]::SetEnvironmentVariable('GCM_INTERACTIVE', 'caller-direct', 'Process')
            [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $hostileConfig, 'Process')
            [Environment]::SetEnvironmentVariable('GIT_CONFIG_PARAMETERS', "'core.hooksPath'='$externalUnix'", 'Process')
            [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', '1', 'Process')
            [Environment]::SetEnvironmentVariable('GIT_CONFIG_KEY_0', 'core.hooksPath', 'Process')
            [Environment]::SetEnvironmentVariable('GIT_CONFIG_VALUE_0', $externalHooks, 'Process')
            [Environment]::SetEnvironmentVariable('GIT_TEMPLATE_DIR', $hostileTemplate, 'Process')
            [Environment]::SetEnvironmentVariable('GIT_DIR', (Join-Path $TestDrive 'hostile.git'), 'Process')
            [Environment]::SetEnvironmentVariable('GIT_WORK_TREE', (Join-Path $TestDrive 'hostile-worktree'), 'Process')

            $fixture = New-WorktreeHookFixture -ExtraEnvironment $markerEnvironment
            $script:FixtureRoot = $fixture.Root
            $createResult = Invoke-WorktreeHook -RepoRoot $fixture.RepoRoot -Environment $fixture.GitEnvironment -Payload @{
                hook_event_name = 'WorktreeCreate'
                session_id = 'session-isolated'
                cwd = $fixture.RepoRoot
                name = 'feature-auth'
            }
            $createResult.ExitCode | Should -Be 0
            Test-Path -LiteralPath $externalMarker | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $fixture.RepoRoot '.git\hooks\pre-commit') | Should -BeFalse

            $localHooks = Join-Path $fixture.RepoRoot '.fixture-hooks'
            New-Item -ItemType Directory -Path $localHooks -Force | Out-Null
            Write-WorktreeFixtureHook -Path (Join-Path $localHooks 'pre-commit') -MarkerVariable 'WINSMUX_LOCAL_HOOK_MARKER'
            [void](Invoke-WorktreeFixtureGit -RepoRoot $fixture.RepoRoot -Environment $fixture.GitEnvironment -ExtraEnvironment $markerEnvironment -Arguments @(
                '-c', 'user.name=Test User', '-c', 'user.email=test@example.invalid',
                '-c', "core.hooksPath=$($localHooks.Replace('\', '/'))",
                'commit', '--allow-empty', '-m', 'explicit fixture hook'
            ))
            Test-Path -LiteralPath $externalMarker | Should -BeFalse
            @(Get-Content -LiteralPath $localMarker).Count | Should -Be 1
        } finally {
            Restore-CallerGitEnvironment -Snapshot $callerBefore
        }

        $callerAfter = Get-CallerGitEnvironment
        $callerAfter.Count | Should -Be $callerBefore.Count
        foreach ($name in $callerBefore.Keys) {
            $callerAfter.Contains($name) | Should -BeTrue
            $callerAfter[$name] | Should -BeExactly $callerBefore[$name]
        }
        $sourceAfter = Get-WorktreeFixtureRepositoryState -RepoRoot $script:RepoRoot -Environment $sourceStateEnvironment
        Assert-WorktreeFixtureRepositoryState -Expected $sourceBefore -Actual $sourceAfter
    }
}
