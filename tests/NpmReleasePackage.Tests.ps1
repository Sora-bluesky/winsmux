$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'winsmux npm release package contract' {
    BeforeAll {
        $script:RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:RepoRoot)) {
            throw 'Failed to resolve repository root.'
        }

        $script:PackageRoot = Join-Path $script:RepoRoot 'packages\winsmux'
        $script:PackageJsonPath = Join-Path $script:PackageRoot 'package.json'
        $script:PackageReadmePath = Join-Path $script:PackageRoot 'README.md'
        $script:EntrypointPath = Join-Path $script:PackageRoot 'index.mjs'
        $script:StageScriptPath = Join-Path $script:RepoRoot 'scripts\stage-npm-release.mjs'
        $script:ReleaseWorkflowPath = Join-Path $script:RepoRoot '.github\workflows\release-npm.yml'
        $script:RootReadmePath = Join-Path $script:RepoRoot 'README.md'
        $script:RootReadmeJaPath = Join-Path $script:RepoRoot 'README.ja.md'
        $script:OutputRoot = Join-Path $script:RepoRoot 'output\npm-release\winsmux'

        $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $nodeCommand) {
            throw 'node was not found in PATH.'
        }
        $script:NodePath = if ($nodeCommand.Path) { $nodeCommand.Path } else { $nodeCommand.Name }

        function Write-TestFileUtf8 {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)][string]$Content
            )

            $parent = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            $utf8 = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($Path, $Content, $utf8)
        }

        function Backup-TestFile {
            param([Parameter(Mandatory = $true)][string]$Path)

            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            }

            return $null
        }

        function Restore-TestFile {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [AllowNull()][string]$Content
            )

            if ($null -eq $Content) {
                if (Test-Path -LiteralPath $Path -PathType Leaf) {
                    Remove-Item -LiteralPath $Path -Force
                }
                return
            }

            Write-TestFileUtf8 -Path $Path -Content $Content
        }

        function Invoke-NodeProcess {
            param(
                [Parameter(Mandatory = $true)][string[]]$Arguments,
                [string]$WorkingDirectory = $script:RepoRoot
            )

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:NodePath
            foreach ($argument in $Arguments) {
                $startInfo.ArgumentList.Add($argument)
            }
            $startInfo.WorkingDirectory = $WorkingDirectory
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true

            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()

                [PSCustomObject]@{
                    ExitCode = $process.ExitCode
                    StdOut   = $stdout.Trim()
                    StdErr   = $stderr.Trim()
                }
            } finally {
                $process.Dispose()
            }
        }

        function Set-PackagePrivateFlag {
            param([Parameter(Mandatory = $true)][bool]$Private)

            $original = Get-Content -LiteralPath $script:PackageJsonPath -Raw -Encoding UTF8
            $updated = $original -replace '"private":\s*(true|false),', ('"private": {0},' -f $Private.ToString().ToLowerInvariant())
            Write-TestFileUtf8 -Path $script:PackageJsonPath -Content $updated
        }

        function Remove-StagedReleaseOutput {
            if (Test-Path -LiteralPath $script:OutputRoot) {
                Remove-Item -LiteralPath $script:OutputRoot -Recurse -Force
            }
        }
    }

    BeforeEach {
        Remove-StagedReleaseOutput
    }

    AfterEach {
        Remove-StagedReleaseOutput
    }

    It 'documents the public entrypoint after package publish opens' {
        $packageReadme = Get-Content -LiteralPath $script:PackageReadmePath -Raw -Encoding UTF8
        $packageJson = Get-Content -LiteralPath $script:PackageJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $rootReadme = Get-Content -LiteralPath $script:RootReadmePath -Raw -Encoding UTF8
        $rootReadmeJa = Get-Content -LiteralPath $script:RootReadmeJaPath -Raw -Encoding UTF8
        $releaseWorkflow = Get-Content -LiteralPath $script:ReleaseWorkflowPath -Raw -Encoding UTF8

        $packageJson.description | Should -Match 'Windows npm install surface'
        $packageJson.private | Should -Be $false
        $packageJson.license | Should -Be 'Apache-2.0'
        $packageReadme | Should -Match '## Public contract'
        $packageReadme | Should -Match 'Windows only'
        $packageReadme | Should -Match 'npm install -g winsmux'
        $packageReadme | Should -Match 'winsmux install'
        $packageReadme | Should -Match 'winsmux update'
        $packageReadme | Should -Match 'winsmux uninstall'
        $packageReadme | Should -Match 'winsmux version'
        $packageReadme | Should -Match 'winsmux help'
        $packageReadme | Should -Match 'same GitHub release tag'
        $packageReadme | Should -Match '## Installer profiles'
        $packageReadme | Should -Match 'winsmux install --profile full'
        $packageReadme | Should -Match 'winsmux update --profile orchestra'
        $packageReadme | Should -Match 'forwards `--profile` to that script as `-Profile`'
        $packageReadme | Should -Match 'Updates keep the previously recorded profile'
        $packageReadme | Should -Match 'install-profile\.json'
        $packageReadme | Should -Match 'Profile scope is enforced by the installer'
        $packageReadme | Should -Match 'core` does not install orchestration scripts'
        $packageReadme | Should -Match 'support scripts that are no\r?\nlonger part of the selected profile are removed'
        $packageReadme | Should -Match '## Release gate'
        $packageReadme | Should -Match 'Windows verify job'
        $packageReadme | Should -Match 'tag-driven'
        $packageReadme | Should -Match 'NPM_TOKEN'
        $packageReadme | Should -Match 'github\.com/Sora-bluesky/winsmux/blob/main/core/LICENSE'
        $packageReadme | Should -Match 'github\.com/Sora-bluesky/winsmux/blob/main/THIRD_PARTY_NOTICES\.md'
        $rootReadme | Should -Match 'npm install -g winsmux'
        $rootReadme | Should -Match 'winsmux install --profile full'
        $rootReadme | Should -Match 'keeps the previously\r?\nrecorded profile'
        $rootReadme | Should -Match 'does not install orchestration\r?\nscripts'
        $rootReadme | Should -Match 'support scripts that no longer\r?\nbelong to the selected profile are removed'
        $rootReadme | Should -Not -Match 'Windows release workflow'
        $rootReadmeJa | Should -Match 'npm install -g winsmux'
        $rootReadmeJa | Should -Match 'winsmux install --profile full'
        $rootReadmeJa | Should -Match '前回記録したプロファイル'
        $rootReadmeJa | Should -Match '導入対象を切り分けます'
        $rootReadmeJa | Should -Match '対象外になった支援スクリプトを削除します'
        $rootReadmeJa | Should -Match 'Windows Terminal 側のプロファイルも、選んだインストールプロファイル'
        $rootReadmeJa | Should -Not -Match 'Windows 検証が通った後'
        $releaseWorkflow | Should -Match 'tags:\s*\r?\n\s*-\s*"v\*"'
        $releaseWorkflow | Should -Match 'name:\s+Verify Windows entrypoint'
        $releaseWorkflow | Should -Match 'if:\s+steps\.stage\.outputs\.publish_ready == ''true'''
        $releaseWorkflow | Should -Match 'NODE_AUTH_TOKEN:\s+\$\{\{\s*secrets\.NPM_TOKEN\s*\}\}'
    }

    It 'skips staging only if the package source is explicitly gated' {
        $originalPackageJson = Backup-TestFile -Path $script:PackageJsonPath
        try {
            Set-PackagePrivateFlag -Private $true

            $result = Invoke-NodeProcess -Arguments @(
                $script:StageScriptPath,
                '--version',
                '0.23.0',
                '--out',
                'output/npm-release/winsmux'
            )

            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
            $result.StdOut | Should -Be 'winsmux npm package is still gated (private=true); skipping stage.'
            Test-Path -LiteralPath $script:OutputRoot | Should -Be $false
        } finally {
            Restore-TestFile -Path $script:PackageJsonPath -Content $originalPackageJson
        }
    }

    It 'stages a release-ready package when the publish gate is open' {
        $stageResult = Invoke-NodeProcess -Arguments @(
            $script:StageScriptPath,
            '--version',
            '0.23.0',
            '--out',
            'output/npm-release/winsmux'
        )

        $stageResult.ExitCode | Should -Be 0
        $stageResult.StdErr | Should -Be ''
        $stageResult.StdOut | Should -Match 'Staged winsmux npm package at'

        foreach ($relativePath in @('package.json', 'README.md', 'index.mjs', 'install.ps1', 'LICENSE')) {
            Test-Path -LiteralPath (Join-Path $script:OutputRoot $relativePath) | Should -Be $true
        }

        $stagedPackage = Get-Content -LiteralPath (Join-Path $script:OutputRoot 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $stagedReadme = Get-Content -LiteralPath (Join-Path $script:OutputRoot 'README.md') -Raw -Encoding UTF8
        $stagedPackage.name | Should -Be 'winsmux'
        $stagedPackage.version | Should -Be '0.23.0'
        $stagedPackage.description | Should -Match 'Windows npm install surface'
        $stagedPackage.license | Should -Be 'Apache-2.0'
        $stagedPackage.PSObject.Properties.Name | Should -Not -Contain 'private'
        @($stagedPackage.files) | Should -Be @('README.md', 'index.mjs', 'install.ps1', 'LICENSE')
        @($stagedPackage.os) | Should -Be @('win32')
        $stagedReadme | Should -Match '## Public contract'
        $stagedReadme | Should -Match 'Windows only'
        $stagedReadme | Should -Match 'npm install -g winsmux'
        $stagedReadme | Should -Match 'winsmux install'
        $stagedReadme | Should -Match 'winsmux update'
        $stagedReadme | Should -Match 'winsmux uninstall'
        $stagedReadme | Should -Match 'winsmux version'
        $stagedReadme | Should -Match 'winsmux help'
        $stagedReadme | Should -Match 'same GitHub release tag'
        $stagedReadme | Should -Match '## Installer profiles'
        $stagedReadme | Should -Match 'winsmux install --profile full'
        $stagedReadme | Should -Match 'winsmux update --profile orchestra'
        $stagedReadme | Should -Match 'forwards `--profile` to that script as `-Profile`'
        $stagedReadme | Should -Match 'Updates keep the previously recorded profile'
        $stagedReadme | Should -Match 'install-profile\.json'
        $stagedReadme | Should -Match 'Profile scope is enforced by the installer'
        $stagedReadme | Should -Match 'core` does not install orchestration scripts'
        $stagedReadme | Should -Match 'support scripts that are no\r?\nlonger part of the selected profile are removed'
        $stagedReadme | Should -Match '## Release gate'
        $stagedReadme | Should -Match 'Windows verify job'
        $stagedReadme | Should -Match 'tag-driven'

        $stagedEntrypoint = Get-Content -LiteralPath (Join-Path $script:OutputRoot 'index.mjs') -Raw -Encoding UTF8
        $stagedEntrypoint | Should -Match 'const releaseTag = `v\$\{packageJson\.version\}`;'
        $stagedEntrypoint | Should -Match '"-ReleaseTag",\s*releaseTag'
        $stagedEntrypoint | Should -Match 'value === "--profile"'
        $stagedEntrypoint | Should -Match 'result\.push\("-Profile", profile\)'

        $stagedInstallScript = Get-Content -LiteralPath (Join-Path $script:OutputRoot 'install.ps1') -Raw -Encoding UTF8
        $stagedInstallScript | Should -Match '\$VERSION\s*=\s*"0\.23\.0"'
        $stagedInstallScript | Should -Match 'releases/tags/\$escapedTag'
        $stagedInstallScript | Should -Match 'raw\.githubusercontent\.com/Sora-bluesky/winsmux/\$EffectiveReleaseTag'
        $stagedInstallScript | Should -Match '\[Alias\("Profile"\)\]\[string\]\$InstallProfile'
        $stagedInstallScript | Should -Match 'Unsupported install profile'
        $stagedInstallScript | Should -Match '\$PROFILE_MANIFEST_FILE'
        $stagedInstallScript | Should -Match 'Resolve-InstallProfile -PreferExisting:\$IsUpdate'
        $stagedInstallScript | Should -Match 'Write-InstallProfileManifest'
        $stagedInstallScript | Should -Match 'function Test-InstallProfileContent'
        $stagedInstallScript | Should -Match 'Install-OrchestraSupportScripts'
        $stagedInstallScript | Should -Match 'Install-SecuritySupportScripts'
        $stagedInstallScript | Should -Match 'Remove-ProfileExcludedSupportScripts'
        $stagedInstallScript | Should -Match 'Removed profile-excluded support script'
        $stagedInstallScript | Should -Match 'Sync-WindowsTerminalFragment -Profile \$resolvedInstallProfile'

        $helpResult = Invoke-NodeProcess -Arguments @((Join-Path $script:OutputRoot 'index.mjs'), 'help') -WorkingDirectory $script:OutputRoot
        $helpResult.ExitCode | Should -Be 0
        $helpResult.StdErr | Should -Be ''
        $helpResult.StdOut | Should -Match 'Usage: install\.ps1 \[action\]'
        $helpResult.StdOut | Should -Match 'Profiles:'
    }
}
