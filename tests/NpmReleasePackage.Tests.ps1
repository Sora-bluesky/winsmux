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
        $script:InstallDownloadGatePath = Join-Path $script:RepoRoot 'scripts\assert-install-downloads-exist.ps1'
        $script:ReleaseWorkflowPath = Join-Path $script:RepoRoot '.github\workflows\release-npm.yml'
        $script:TestWorkflowPath = Join-Path $script:RepoRoot '.github\workflows\test.yml'
        $script:InstallerPath = Join-Path $script:RepoRoot 'install.ps1'
        $script:InstallE2ePath = Join-Path $script:RepoRoot 'scripts\test-install-e2e.ps1'
        $script:NativeBridgeE2ePath = Join-Path $script:RepoRoot 'scripts\test-native-bridge-resolution.ps1'
        $script:RedirectedInstallSmokePath = Join-Path $script:RepoRoot 'scripts\test-install-redirected.ps1'
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

        function Invoke-PwshProcess {
            param(
                [Parameter(Mandatory = $true)][string[]]$Arguments,
                [string]$WorkingDirectory = $script:RepoRoot
            )

            $pwshCommand = Get-Command pwsh -ErrorAction Stop | Select-Object -First 1
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = if ($pwshCommand.Path) { $pwshCommand.Path } else { $pwshCommand.Name }
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
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                $process.WaitForExit()
                $stdout = $stdoutTask.GetAwaiter().GetResult()
                $stderr = $stderrTask.GetAwaiter().GetResult()
                return [PSCustomObject]@{
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
        $testWorkflow = Get-Content -LiteralPath $script:TestWorkflowPath -Raw -Encoding UTF8
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        $installE2e = Get-Content -LiteralPath $script:InstallE2ePath -Raw -Encoding UTF8
        $nativeBridgeE2e = Get-Content -LiteralPath $script:NativeBridgeE2ePath -Raw -Encoding UTF8
        $redirectedSmoke = Get-Content -LiteralPath $script:RedirectedInstallSmokePath -Raw -Encoding UTF8

        $e2eTokens = $null
        $e2eErrors = $null
        $e2eAst = [System.Management.Automation.Language.Parser]::ParseInput($installE2e, [ref]$e2eTokens, [ref]$e2eErrors)
        $e2eErrors.Count | Should -Be 0
        $versionConverter = $e2eAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertTo-WinsmuxBinaryVersion'
        }, $true)
        $versionConverter | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($versionConverter.Extent.Text))
        (ConvertTo-WinsmuxBinaryVersion -ReleaseTag 'v0.36.28') | Should -Be '0.36.28'
        (ConvertTo-WinsmuxBinaryVersion -ReleaseTag 'v0.36.28.1') | Should -Be '0.36.28'

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
        $packageReadme | Should -Match 'exact GitHub release tag'
        $packageReadme | Should -Match 'source directory is not the publish artifact'
        $packageReadme | Should -Match 'staged package'
        $packageReadme | Should -Match 'added during\s+staging'
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
        $rootReadme | Should -Match 'docs/installation\.md'
        $rootReadme | Should -Match 'docs/quickstart\.md'
        $rootReadme | Should -Match 'docs/customization\.md'
        $rootReadme | Should -Not -Match 'Windows release workflow'
        $rootReadmeJa | Should -Match 'npm install -g winsmux'
        $rootReadmeJa | Should -Match 'winsmux install --profile full'
        $rootReadmeJa | Should -Match 'docs/installation\.ja\.md'
        $rootReadmeJa | Should -Match 'docs/quickstart\.ja\.md'
        $rootReadmeJa | Should -Match 'docs/customization\.ja\.md'
        $rootReadmeJa | Should -Not -Match 'Windows 検証が通った後'
        $releaseWorkflow | Should -Match 'tags:\s*\r?\n\s*-\s*"v\*"'
        $releaseWorkflow | Should -Match 'name:\s+Verify Windows entrypoint'
        $releaseWorkflow | Should -Match 'if:\s+steps\.stage\.outputs\.publish_ready == ''true'''
        $releaseWorkflow | Should -Match 'name:\s+Check whether npm version already exists'
        $releaseWorkflow | Should -Match 'npm view "winsmux@\$\{\{\s*needs\.verify\.outputs\.version\s*\}\}" version'
        $releaseWorkflow | Should -Match 'name:\s+Skip existing npm version'
        $releaseWorkflow | Should -Match 'if:\s+steps\.npm-version\.outputs\.exists != ''true'''
        $releaseWorkflow | Should -Match 'NODE_AUTH_TOKEN:\s+\$\{\{\s*secrets\.NPM_TOKEN\s*\}\}'
        $testWorkflow | Should -Match 'name:\s+Fresh Install E2E \(\$\{\{ matrix\.route \}\}\)'
        $installJob = [regex]::Match($testWorkflow, '(?ms)^  install-e2e:\r?\n(?<body>.*?)(?=^  [a-z][a-z0-9-]*:)')
        $installJob.Success | Should -BeTrue
        $installJob.Groups['body'].Value | Should -Match 'runs-on:\s+windows-2025'
        $installJob.Groups['body'].Value | Should -Not -Match 'runs-on:\s+windows-latest'
        $testWorkflow | Should -Match 'route:\s*\[Npm, Direct, DefectDetection\]'
        $testWorkflow | Should -Match 'scripts/test-install-e2e\.ps1 -Route "\$\{\{ matrix\.route \}\}"'
        $testWorkflow | Should -Match 'WINSMUX_INSTALL_E2E_GITHUB_ACCESS:\s+\$\{\{ github\.token \}\}'
        $testWorkflow | Should -Match 'needs:[\s\S]*?- install-e2e[\s\S]*?needs\.install-e2e\.result'
        $installer | Should -Not -Match 'Download-File "winsmux\.ps1"'
        $installer | Should -Match 'Download-File "install\.ps1" \(Join-Path \$BIN_DIR "install\.ps1"\)'
        $downloadDeclarations = @([regex]::Matches($installer, '(?m)^\s*Download-(?:Optional)?File\s+"(?<path>[^"]+)"\s+(?<destination>[^\r\n]+)$') | ForEach-Object {
            '{0}|{1}' -f $_.Groups['path'].Value, $_.Groups['destination'].Value.Trim()
        })
        @($downloadDeclarations | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
        ([regex]::Matches($installer, 'Join-Path \$BIN_DIR "winsmux\.cmd"')).Count | Should -Be 1
        $installer | Should -Match 'winsmux-core\.ps1" %\*'
        $installer | Should -Match 'WINSMUX_RAW_EXE=%USERPROFILE%\\\.local\\bin\\winsmux\.exe'
        $installer | Should -Not -Match '(?<!-core)winsmux\.ps1" %\*'
        $installer | Should -Match 'winsmux\.cmd'' launch --project-dir \$dir'
        $installer | Should -Not -Match 'winsmux\.ps1'' start -C \$dir'
        $installE2e | Should -Match 'isGitHubRunner'
        $installE2e | Should -Match 'isAuthorizedRedirect'
        $installE2e | Should -Not -Match '(?m)^\$home\s*='
        $installE2e | Should -Match '\$fixtureHome = Join-Path \$scratch ''home'''
        $installE2e | Should -Match "ValidateSet\('Npm', 'Direct', 'DefectDetection'\)"
        $installE2e | Should -Match 'irm ''\$url'' \| iex'
        $installE2e | Should -Match 'WINSMUX_INSTALL_SOURCE_REF'
        $installE2e | Should -Match "GetExtension\(\`$FilePath\) -ieq '\.cmd'"
        $installE2e | Should -Match '\$startInfo\.FileName = \$env:ComSpec'
        $installE2e | Should -Match '\$startInfo\.Arguments = ''/d /s /c "'''
        $installE2e | Should -Match 'WINSMUX_INSTALL_E2E_GITHUB_ACCESS'
        $installE2e | Should -Match '\[switch\]\$IncludeGitHubAccess'
        $installE2e | Should -Match 'if \(\$IncludeGitHubAccess -and \$isGitHubRunner\)'
        $installE2e | Should -Match '\$startInfo\.Environment\[''WINSMUX_INSTALL_E2E_GITHUB_ACCESS''\] = \$gitHubAccess'
        $installE2e | Should -Match 'Invoke-IrmInstaller -SourceInstaller \$brokenInstaller -ServerDirectory \(Join-Path \$scratch ''pre-fix-server''\) -IncludeTargetInstallerBootstrapMarker\r?\n'
        $installE2e | Should -Not -Match 'Invoke-IrmInstaller -SourceInstaller \$brokenInstaller[^\r\n]+-IncludeGitHubAccess'
        $installE2e | Should -Match 'Invoke-CapturedProcess -FilePath \$npmShim[^\r\n]+-IncludeGitHubAccess:\$isGitHubRunner'
        $installE2e | Should -Match 'Invoke-IrmInstaller -SourceInstaller \$installerPath[^\r\n]+-IncludeGitHubAccess:\$isGitHubRunner'
        $installE2e | Should -Match 'wrapper_launch_project_dir_verified'
        $installE2e | Should -Match 'wrapper_raw_command_forwarding_verified'
        $installE2e | Should -Match 'wrapper_update_dispatch_verified'
        $installE2e | Should -Match 'wrapper_uninstall_dispatch_verified'
        $installE2e | Should -Match 'wrapper_lifecycle_without_native_verified'
        $installE2e | Should -Match 'tagless_install_verified'
        $installE2e | Should -Match '\$expectedReleaseTag'
        $installE2e | Should -Match 'ConvertTo-WinsmuxBinaryVersion -ReleaseTag \$expectedReleaseTag'
        $testWorkflow | Should -Match '(?m)^  native-lifecycle-source:$'
        $testWorkflow | Should -Match 'runs-on: windows-2025'
        $testWorkflow | Should -Match 'test-native-bridge-resolution\.ps1 -CandidateBinary target/release/winsmux\.exe'
        $testWorkflow | Should -Match '\$\{\{ needs\.native-lifecycle-source\.result \}\}'
        $nativeBridgeE2e | Should -Match "foreach \(\`$action in @\('install', 'update', 'uninstall'\)\)"
        $nativeBridgeE2e | Should -Match 'executed the hostile CWD bridge'
        $nativeBridgeE2e | Should -Match 'succeeded without an installed bridge'
        $nativeBridgeE2e | Should -Match 'non-WindowsApps PowerShell 7 executable'
        $installE2e | Should -Match 'Tagless direct install did not stay on the fixed main installer'
        $installE2e | Should -Match 'Tagless direct install replaced the fixed main scripts with the previous release scripts'
        $installer | Should -Match 'keepPipedMainScripts'
        $installer | Should -Match 'Test-IsPipedWinsmuxInstaller -InvocationPath \(\[string\]\$MyInvocation\.MyCommand\.Path\)'
        $installer | Should -Match "(?s)\`$requestedReleaseTag = if \(\`$releaseAction -notin @\('install', 'update'\)\).*?Assert-WinsmuxReleaseTag -ReleaseTag \`$requestedReleaseTag"
        $installer | Should -Match 'switch \(\$releaseAction\)'
        $installer | Should -Not -Match 'switch \(\$Action\.ToLower\(\)\)'
        $installE2e | Should -Match 'WT settings: not found'
        $installE2e | Should -Match "wrapper.*doctor"
        $installE2e | Should -Match 'installer download failure'
        $installE2e | Should -Not -Match "\$installResult\.Combined -match '404\|Not Found\|Failed to download'"
        $installE2e | Should -Match 'Defect fixture skips release binary acquisition'
        $installE2e | Should -Match "Install-WinsmuxBinary\[ \\t\]\*\\r\?\$"
        $installE2e | Should -Not -Match "\$result\.Combined -notmatch '404\|Not Found\|Failed to download'"
        $installE2e | Should -Match '\[ValidateRange\(1, 1800\)\]\[int\]\$TimeoutSeconds = 900'
        $installE2e | Should -Match '\$process\.Kill\(\$true\)'
        $installE2e | Should -Match 'Child process exceeded \$\{TimeoutSeconds\}s and was terminated'
        $redirectedSmoke | Should -Match 'Remove-FixturePathEntry'
        $redirectedSmoke | Should -Match 'Remove-FixtureProfileBlock'
        $redirectedSmoke | Should -Match '\.winsmux\\backups'
        $redirectedSmoke | Should -Match '\[System\.IO\.FileShare\]::None'
        $redirectedSmoke | Should -Match 'live_user_path_untouched'
        $redirectedSmoke | Should -Match 'live_profile_untouched'
        $redirectedSmoke | Should -Match 'kind = ''directory'''
        $redirectedSmoke | Should -Match 'install_owned_live_state_preserved'
        $redirectedSmoke | Should -Match 'git -C \$repoRoot rev-parse HEAD'
        $redirectedSmoke | Should -Match '''-SourceCommit'', \$sourceCommit'
        $redirectedSmoke | Should -Match "Where-Object \{ \`$_.Source -notmatch '\\\\WindowsApps\\\\' \}"
        $redirectedSmoke | Should -Match 'requires a non-WindowsApps PowerShell 7 executable'
        $redirectedSmoke | Should -Match 'if \(\$null -eq \$remainingProfile\) \{ \$remainingProfile = '''' \}'
        $installer | Should -Match 'WINSMUX_INSTALL_STATE_ROOT must be contained by the redirected HOME'
        $installer | Should -Match 'Redirected installer E2E mode only permits the install action'
        $installer | Should -Match 'if \(\$installerE2e\) \{ \[string\]\$env:WINSMUX_INSTALL_E2E_GITHUB_ACCESS \} else \{ '''' \}'
        $installer | Should -Match '\$installSourceRef = if \(\$installerE2e -or \$redirectedInstallerE2e\)'
        $installer | Should -Match '\$headers\.Authorization = "Bearer \$e2eGitHubAccess"'
        $installer | Should -Match 'WINSMUX_RAW_EXE=%USERPROFILE%\\\.local\\bin\\winsmux\.exe'
        $installE2e | Should -Match 'Invoke-CapturedProcess -FilePath \$wrapper -Arguments @\(''-V''\)'
        $installer | Should -Match 'Get-InstallUserPath'
        $installer | Should -Match 'Get-InstallPowerShellProfilePath'
        $redirectedSmoke.IndexOf('$invariantErrors', [System.StringComparison]::Ordinal) | Should -BeLessThan $redirectedSmoke.IndexOf('$failureParts', [System.StringComparison]::Ordinal)
    }

    It 're-executes the resolved target installer before a pinned install or update' {
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        $installer | Should -Match '(?s)\$release\s*=\s*Resolve-WinsmuxRelease.*?\$headers\s*=\s*Get-WinsmuxReleaseHeaders.*?browser_download_url\s+-Headers\s+\$headers'
        $installer | Should -Not -Match 'UpdateBootstrapComplete'
        $installer | Should -Match 'WINSMUX_INTERNAL_TARGET_INSTALLER_BOOTSTRAPPED'
        $installer | Should -Match 'winsmux\.exe\.previous-'
        $installE2e = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts/test-install-e2e.ps1') -Raw -Encoding UTF8
        $installE2e | Should -Match 'update could not replace a running native executable'
        $installE2e | Should -Match "if \(\`$Route -eq 'Direct' -and \`$isGitHubRunner\)"
        $installE2e | Should -Not -Match "if \(\`$Route -eq 'Direct'\) \{\s*\`$cmdFixture"
        $installE2e | Should -Match "\`$startInfo.Environment\['WINSMUX_INTERNAL_TARGET_INSTALLER_BOOTSTRAPPED'\] = '1'"
        $installE2e | Should -Match 'Invoke-IrmInstaller .* -IncludeTargetInstallerBootstrapMarker'
        $mainMarker = '# Main'
        $mainOffset = $installer.IndexOf($mainMarker, [System.StringComparison]::Ordinal)
        $mainOffset | Should -BeGreaterThan 0
        $definitions = $installer.Substring(0, $mainOffset)

        $markerPath = Join-Path $TestDrive 'update-bootstrap.json'
        $targetInstaller = Join-Path $TestDrive 'target-install.ps1'
        $markerLiteral = $markerPath.Replace("'", "''")
        Write-TestFileUtf8 -Path $targetInstaller -Content @"
param(
    [Parameter(Position=0)][string]`$Action,
    [string]`$ReleaseTag,
    [string]`$InstallProfile
)
@{ action = `$Action; release = `$ReleaseTag; profile = `$InstallProfile; bootstrapped = (`$env:WINSMUX_INTERNAL_TARGET_INSTALLER_BOOTSTRAPPED -eq '1') } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath '$markerLiteral' -Encoding UTF8
"@

        . ([scriptblock]::Create($definitions))
        function Resolve-InstallProfile { return 'orchestra' }
        function Resolve-WinsmuxRelease {
            throw 'A pinned release must not be replaced by a latest-release lookup.'
        }
        $UseLatestRelease = $false
        $ResolvedReleaseTag = 'v0.36.28'
        function Download-File {
            param($relativeUrl, $destPath)
            $relativeUrl | Should -Be 'install.ps1'
            Copy-Item -LiteralPath $targetInstaller -Destination $destPath -Force
        }

        foreach ($targetAction in @('install', 'update')) {
            $env:WINSMUX_INTERNAL_TARGET_INSTALLER_BOOTSTRAPPED = 'outer-value'
            try {
                Invoke-TargetInstallerBootstrap -TargetAction $targetAction
            } finally {
                $env:WINSMUX_INTERNAL_TARGET_INSTALLER_BOOTSTRAPPED | Should -Be 'outer-value'
                Remove-Item Env:WINSMUX_INTERNAL_TARGET_INSTALLER_BOOTSTRAPPED -ErrorAction SilentlyContinue
            }

            $result = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.action | Should -Be $targetAction
            $result.release | Should -Be 'v0.36.28'
            $result.profile | Should -Be 'orchestra'
            $result.bootstrapped | Should -BeTrue
        }

        $requestedReleaseTag = ''
        $isPipedInstaller = $true
        (Test-ShouldBootstrapTargetInstaller -TargetAction install) | Should -BeFalse
        (Test-ShouldBootstrapTargetInstaller -TargetAction update) | Should -BeTrue
        $isPipedInstaller = $false
        (Test-ShouldBootstrapTargetInstaller -TargetAction install) | Should -BeTrue
        $requestedReleaseTag = 'v0.36.28'
        $isPipedInstaller = $true
        (Test-ShouldBootstrapTargetInstaller -TargetAction install) | Should -BeTrue
        (Test-IsPipedWinsmuxInstaller -InvocationPath '') | Should -BeTrue
        (Test-IsPipedWinsmuxInstaller -InvocationPath 'C:\saved\install.ps1') | Should -BeFalse
        (Get-WinsmuxBinaryVersionFromReleaseTag -ReleaseTag 'v0.36.28') | Should -Be '0.36.28'
        (Get-WinsmuxBinaryVersionFromReleaseTag -ReleaseTag 'v0.36.28.1') | Should -Be '0.36.28'
        (Get-WinsmuxBinaryVersionFromReleaseTag -ReleaseTag 'v0.36.29-preview.1') | Should -Be '0.36.29-preview.1'
        { Get-WinsmuxBinaryVersionFromReleaseTag -ReleaseTag 'v0.36' } | Should -Throw '*Unsupported winsmux release tag format*'
        { Assert-WinsmuxReleaseTag -ReleaseTag 'v0.36.28' } | Should -Not -Throw
        { Assert-WinsmuxReleaseTag -ReleaseTag 'v0.36.28.1' } | Should -Not -Throw
        { Assert-WinsmuxReleaseTag -ReleaseTag 'v0.36.29-preview.1' } | Should -Not -Throw
        { Assert-WinsmuxReleaseTag -ReleaseTag '../../attacker/repo/main' } | Should -Throw '*Invalid winsmux release tag*'
        { Assert-WinsmuxReleaseTag -ReleaseTag 'v0.36.28/../../main' } | Should -Throw '*Invalid winsmux release tag*'
        $installer | Should -Match '-not \(Test-ShouldBootstrapTargetInstaller -TargetAction install\)'
    }

    It 'keeps non-release actions independent from a stale release tag' {
        $installerLiteral = $script:InstallerPath.Replace("'", "''")
        foreach ($case in @(
            @{ Action = 'help'; Expected = 'Usage: install.ps1' },
            @{ Action = 'version'; Expected = 'winsmux 0.36.28' },
            @{ Action = 'unknown-action'; Expected = 'Usage: install.ps1' }
        )) {
            $command = "`$env:WINSMUX_RELEASE_TAG = '../../attacker/repo/main'; & '$installerLiteral' $($case.Action) -ReleaseTag 'also-invalid'"
            $result = Invoke-PwshProcess -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command)
            $result.ExitCode | Should -Be 0
            $result.StdOut | Should -Match ([regex]::Escape($case.Expected))
            $result.StdErr | Should -Not -Match 'Invalid winsmux release tag'
        }
    }

    It 'repairs installer-managed state without release assets when the installed binary already matches' {
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        $mainOffset = $installer.IndexOf('# Main', [System.StringComparison]::Ordinal)
        $mainOffset | Should -BeGreaterThan 0
        $fixtureHome = Join-Path $TestDrive 'matching-binary-home'
        $script:TestInstallHome = $fixtureHome
        $localBin = Join-Path $fixtureHome '.local\bin'
        $winsmuxExe = Join-Path $localBin 'winsmux.exe'
        New-Item -ItemType Directory -Path $localBin -Force | Out-Null
        Write-TestFileUtf8 -Path $winsmuxExe -Content 'matching-binary'

        $previousE2e = $env:WINSMUX_INSTALL_E2E
        $previousStateRoot = $env:WINSMUX_INSTALL_STATE_ROOT
        try {
            $env:WINSMUX_INSTALL_E2E = 'redirected'
            $env:WINSMUX_INSTALL_STATE_ROOT = Join-Path $fixtureHome 'installer-state'
            $definitions = $installer.Substring(0, $mainOffset).Replace('$HOME', '$script:TestInstallHome')
            . ([scriptblock]::Create($definitions))

            function Resolve-WinsmuxRelease {
                Set-Variable -Name ResolvedVersion -Value '9.9.9' -Scope Script
                return [PSCustomObject]@{ tag_name = 'v9.9.9'; assets = @() }
            }
            function Get-WinsmuxReleaseHeaders { return @{} }
            function Get-WinsmuxCommandVersion {
                param($CommandInfo)
                return [PSCustomObject]@{ Version = '9.9.9'; Output = 'winsmux 9.9.9' }
            }
            function Get-PreferredReleaseAssetName {
                throw 'Asset selection must not run when the installed binary already matches.'
            }

            { Install-WinsmuxBinary } | Should -Not -Throw
        } finally {
            $env:WINSMUX_INSTALL_E2E = $previousE2e
            $env:WINSMUX_INSTALL_STATE_ROOT = $previousStateRoot
        }

        (Get-Content -LiteralPath $winsmuxExe -Raw -Encoding UTF8) | Should -Be 'matching-binary'
    }

    It 'does not forward GitHub access from redirected local smoke' {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:InstallE2ePath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        @($parseErrors).Count | Should -Be 0
        $functionAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Invoke-CapturedProcess'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($functionAst.Extent.Text))

        $previousAccess = $env:WINSMUX_INSTALL_E2E_GITHUB_ACCESS
        $isGitHubRunner = $false
        $repoRoot = $script:RepoRoot
        try {
            $env:WINSMUX_INSTALL_E2E_GITHUB_ACCESS = 'local-sentinel-must-not-cross'
            $result = Invoke-CapturedProcess -FilePath (Get-Command pwsh -ErrorAction Stop).Source -Arguments @(
                '-NoProfile', '-Command',
                '[Console]::Write([Environment]::GetEnvironmentVariable("WINSMUX_INSTALL_E2E_GITHUB_ACCESS"))'
            ) -IncludeGitHubAccess
        } finally {
            $env:WINSMUX_INSTALL_E2E_GITHUB_ACCESS = $previousAccess
        }

        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -BeNullOrEmpty

        $normalMarkerResult = Invoke-CapturedProcess -FilePath (Get-Command pwsh -ErrorAction Stop).Source -Arguments @(
            '-NoProfile', '-Command',
            '[Console]::Write([Environment]::GetEnvironmentVariable("WINSMUX_INTERNAL_TARGET_INSTALLER_BOOTSTRAPPED"))'
        )
        $normalMarkerResult.ExitCode | Should -Be 0
        $normalMarkerResult.StdOut | Should -BeNullOrEmpty

        $markerResult = Invoke-CapturedProcess -FilePath (Get-Command pwsh -ErrorAction Stop).Source -Arguments @(
            '-NoProfile', '-Command',
            '[Console]::Write([Environment]::GetEnvironmentVariable("WINSMUX_INTERNAL_TARGET_INSTALLER_BOOTSTRAPPED"))'
        ) -IncludeTargetInstallerBootstrapMarker
        $markerResult.ExitCode | Should -Be 0
        $markerResult.StdOut | Should -Be '1'

        $releaseNames = @('WINSMUX_RELEASE_TAG', 'WINSMUX_INSTALL_E2E_RELEASE_TAG', 'WINSMUX_INSTALL_SOURCE_REF')
        $previousReleaseValues = @{}
        try {
            foreach ($name in $releaseNames) {
                $previousReleaseValues[$name] = [Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name, 'fixture-value', 'Process')
            }
            $releaseProbe = '[Console]::Write((@("WINSMUX_RELEASE_TAG","WINSMUX_INSTALL_E2E_RELEASE_TAG","WINSMUX_INSTALL_SOURCE_REF") | ForEach-Object { [Environment]::GetEnvironmentVariable($_) }) -join "|")'
            $selectedReleaseResult = Invoke-CapturedProcess -FilePath (Get-Command pwsh -ErrorAction Stop).Source -Arguments @('-NoProfile', '-Command', $releaseProbe)
            $taglessReleaseResult = Invoke-CapturedProcess -FilePath (Get-Command pwsh -ErrorAction Stop).Source -Arguments @('-NoProfile', '-Command', $releaseProbe) -OmitReleaseTagSelection
        } finally {
            foreach ($name in $releaseNames) {
                [Environment]::SetEnvironmentVariable($name, $previousReleaseValues[$name], 'Process')
            }
        }
        $selectedReleaseResult.StdOut | Should -Be 'fixture-value|fixture-value|fixture-value'
        $taglessReleaseResult.StdOut | Should -Be '||fixture-value'
    }

    It 'accepts an empty redirected profile after removing the managed block' {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:RedirectedInstallSmokePath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        @($parseErrors).Count | Should -Be 0
        $functionAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Remove-FixtureProfileBlock'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($functionAst.Extent.Text))

        $profilePath = Join-Path $TestDrive 'redirected-profile.ps1'
        $fixtureBin = Join-Path $TestDrive 'home\.winsmux\bin'
        Write-TestFileUtf8 -Path $profilePath -Content ("# winsmux`r`n`$env:PATH = `"$fixtureBin;`$env:PATH`"`r`n")

        (Remove-FixtureProfileBlock -ProfilePath $profilePath -FixtureBin $fixtureBin) | Should -BeTrue
        (Get-Item -LiteralPath $profilePath).Length | Should -Be 0
        $remainingProfile = Get-Content -LiteralPath $profilePath -Raw
        if ($null -eq $remainingProfile) { $remainingProfile = '' }
        $remainingProfile.Contains($fixtureBin, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeFalse
    }

    It 'recovers an interrupted binary rotation and rolls back a failed replacement validation' {
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        $mainOffset = $installer.IndexOf('# Main', [System.StringComparison]::Ordinal)
        $mainOffset | Should -BeGreaterThan 0
        . ([scriptblock]::Create($installer.Substring(0, $mainOffset)))

        $localBin = Join-Path $TestDrive 'rotation-bin'
        New-Item -ItemType Directory -Path $localBin -Force | Out-Null
        $winsmuxExe = Join-Path $localBin 'winsmux.exe'
        $interruptedPrevious = Join-Path $localBin 'winsmux.exe.previous-0123456789abcdef0123456789abcdef'
        $unownedSibling = Join-Path $localBin 'winsmux.exe.previous-not-owned'
        Write-TestFileUtf8 -Path $interruptedPrevious -Content 'previous-version'
        Write-TestFileUtf8 -Path $unownedSibling -Content 'preserve-me'

        Repair-WinsmuxBinaryRotation -LocalBin $localBin -WinsmuxExe $winsmuxExe
        (Get-Content -LiteralPath $winsmuxExe -Raw -Encoding UTF8) | Should -Be 'previous-version'
        Test-Path -LiteralPath $interruptedPrevious | Should -BeFalse
        Test-Path -LiteralPath $unownedSibling | Should -BeTrue

        function Get-WinsmuxCommandVersion {
            param($CommandInfo)
            $content = Get-Content -LiteralPath $CommandInfo.Source -Raw -Encoding UTF8
            if ($content -eq 'previous-version') {
                return [PSCustomObject]@{ Version = '1.0.0'; Output = 'winsmux 1.0.0' }
            }
            if ($content -eq 'unvalidated-replacement') {
                return [PSCustomObject]@{ Version = '2.0.0'; Output = 'winsmux 2.0.0' }
            }
            return $null
        }

        $stalePrevious = Join-Path $localBin 'winsmux.exe.previous-fedcba9876543210fedcba9876543210'
        Write-TestFileUtf8 -Path $stalePrevious -Content 'stale-version'
        Repair-WinsmuxBinaryRotation -LocalBin $localBin -WinsmuxExe $winsmuxExe
        Test-Path -LiteralPath $stalePrevious | Should -BeTrue
        Clear-WinsmuxBinaryRotation -LocalBin $localBin
        Test-Path -LiteralPath $stalePrevious | Should -BeFalse

        Write-TestFileUtf8 -Path $winsmuxExe -Content 'unvalidated-replacement'
        $unvalidatedPrevious = Join-Path $localBin 'winsmux.exe.previous-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        Write-TestFileUtf8 -Path $unvalidatedPrevious -Content 'previous-version'
        Repair-WinsmuxBinaryRotation -LocalBin $localBin -WinsmuxExe $winsmuxExe
        (Get-Content -LiteralPath $winsmuxExe -Raw -Encoding UTF8) | Should -Be 'unvalidated-replacement'
        Test-Path -LiteralPath $unvalidatedPrevious | Should -BeTrue
        Clear-WinsmuxBinaryRotation -LocalBin $localBin
        (Get-Content -LiteralPath $winsmuxExe -Raw -Encoding UTF8) | Should -Be 'unvalidated-replacement'
        Test-Path -LiteralPath $unvalidatedPrevious | Should -BeFalse

        $downloadPath = Join-Path $TestDrive 'invalid-replacement.exe'
        Write-TestFileUtf8 -Path $downloadPath -Content 'invalid-version'

        {
            Install-VerifiedWinsmuxBinary -DownloadPath $downloadPath -WinsmuxExe $winsmuxExe -LocalBin $localBin -ExpectedVersion '9.9.9'
        } | Should -Throw '*Installed binary validation failed*'
        (Get-Content -LiteralPath $winsmuxExe -Raw -Encoding UTF8) | Should -Be 'unvalidated-replacement'
        @(Get-ChildItem -LiteralPath $localBin -File | Where-Object { $_.Name -match '^winsmux\.exe\.previous-[0-9a-f]{32}$' }).Count | Should -Be 0
        Test-Path -LiteralPath $unownedSibling | Should -BeTrue
    }

    It 'removes only the installer-owned profile block and preserves user content and encoding' {
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        $installer | Should -Not -Match "-notmatch 'winsmux'"
        $installer | Should -Match '\$managedProfilePattern'
        $mainOffset = $installer.IndexOf('# Main', [System.StringComparison]::Ordinal)
        $mainOffset | Should -BeGreaterThan 0
        . ([scriptblock]::Create($installer.Substring(0, $mainOffset)))

        $managedLine = '$env:PATH = "C:\fixture\.winsmux\bin;$env:PATH"'
        $profileText = "function Invoke-WinsmuxCustom {`r`n    winsmux doctor`r`n}`r`n# winsmux`r`n$managedLine`r`nWrite-Host 'keep winsmux note'`r`n"
        foreach ($case in @(
            @{ Name = 'utf8-bom'; Encoding = [System.Text.UTF8Encoding]::new($true); Preamble = [byte[]](0xEF, 0xBB, 0xBF) },
            @{ Name = 'utf16-le'; Encoding = [System.Text.UnicodeEncoding]::new($false, $true); Preamble = [byte[]](0xFF, 0xFE) }
        )) {
            $profilePath = Join-Path $TestDrive ($case.Name + '.ps1')
            $body = $case.Encoding.GetBytes($profileText)
            $bytes = [byte[]]::new($case.Preamble.Length + $body.Length)
            [Array]::Copy($case.Preamble, 0, $bytes, 0, $case.Preamble.Length)
            [Array]::Copy($body, 0, $bytes, $case.Preamble.Length, $body.Length)
            [System.IO.File]::WriteAllBytes($profilePath, $bytes)

            Remove-WinsmuxProfileBlock -ProfilePath $profilePath -ManagedPathLine $managedLine

            $updatedBytes = [System.IO.File]::ReadAllBytes($profilePath)
            @($updatedBytes[0..($case.Preamble.Length - 1)]) | Should -Be $case.Preamble
            $updated = $case.Encoding.GetString($updatedBytes, $case.Preamble.Length, $updatedBytes.Length - $case.Preamble.Length)
            $updated | Should -Match 'function Invoke-WinsmuxCustom'
            $updated | Should -Match 'winsmux doctor'
            $updated | Should -Match "Write-Host 'keep winsmux note'"
            $updated | Should -Not -Match [regex]::Escape($managedLine)
        }
    }

    It 'verifies every installer download target against the release tree and rejects a missing target' {
        $valid = Invoke-PwshProcess -Arguments @(
            '-NoProfile', '-File', $script:InstallDownloadGatePath,
            '-RepositoryRoot', $script:RepoRoot,
            '-Treeish', 'HEAD'
        )
        $valid.ExitCode | Should -Be 0
        $valid.StdErr | Should -Be ''
        $validSummary = $valid.StdOut | ConvertFrom-Json -Depth 10
        $validSummary.download_target_count | Should -BeGreaterThan 0
        $validSummary.runtime_dependency_count | Should -BeGreaterThan 0
        @($validSummary.download_targets) | Should -Contain 'scripts/winsmux-core.ps1'
        @($validSummary.download_targets) | Should -Not -Contain 'winsmux.ps1'
        @($validSummary.runtime_dependencies) | Should -Contain 'json-compat.ps1'

        $invalidInstaller = Join-Path $TestDrive 'install-with-missing-download.ps1'
        $installer = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'install.ps1') -Raw -Encoding UTF8
        $invalid = $installer.Replace(
            'Download-File "scripts/winsmux-core.ps1" (Join-Path $BIN_DIR "winsmux-core.ps1")',
            'Download-File "missing/installer-entrypoint.ps1" (Join-Path $BIN_DIR "winsmux-core.ps1")'
        )
        $invalid | Should -Not -Be $installer
        Write-TestFileUtf8 -Path $invalidInstaller -Content $invalid

        $missing = Invoke-PwshProcess -Arguments @(
            '-NoProfile', '-File', $script:InstallDownloadGatePath,
            '-RepositoryRoot', $script:RepoRoot,
            '-InstallScriptPath', $invalidInstaller,
            '-Treeish', 'HEAD'
        )
        $missing.ExitCode | Should -Not -Be 0
        $missing.StdErr | Should -Match 'missing/installer-entrypoint\.ps1'

        $invalidCases = @(
            @{
                Name = 'missing runtime dependency declaration'
                Find = 'Download-File "winsmux-core/scripts/json-compat.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "json-compat.ps1")'
                Replace = '# deliberately omit json-compat.ps1 from the installer fixture'
                Error = 'runtime script dependencies are not downloaded:.*json-compat\.ps1'
            },
            @{
                Name = 'missing optional target'
                Find = 'Download-OptionalFile "winsmux-core/scripts/control-plane-workers.ps1"'
                Replace = 'Download-OptionalFile "missing/optional-worker.ps1"'
                Error = 'missing/optional-worker\.ps1'
            },
            @{
                Name = 'dynamic target'
                Find = 'Download-File "scripts/winsmux-core.ps1" (Join-Path $BIN_DIR "winsmux-core.ps1")'
                Replace = 'Download-File $dynamicPath (Join-Path $BIN_DIR "winsmux-core.ps1")'
                Error = 'static string literal'
            },
            @{
                Name = 'parent traversal'
                Find = 'Download-File ".winsmux.conf" $confDest'
                Replace = 'Download-File "../.winsmux.conf" $confDest'
                Error = 'unsafe relative path'
            },
            @{
                Name = 'absolute URL'
                Find = 'Download-File ".winsmux.conf" $confDest'
                Replace = 'Download-File "https://example.invalid/.winsmux.conf" $confDest'
                Error = 'unsafe relative path'
            },
            @{
                Name = 'directory instead of file'
                Find = 'Download-File ".winsmux.conf" $confDest'
                Replace = 'Download-File "scripts" $confDest'
                Error = 'not files'
            }
        )
        foreach ($case in $invalidCases) {
            $casePath = Join-Path $TestDrive (($case.Name -replace '[^A-Za-z0-9]+', '-') + '.ps1')
            $caseInstaller = $installer.Replace($case.Find, $case.Replace)
            $caseInstaller | Should -Not -Be $installer -Because $case.Name
            Write-TestFileUtf8 -Path $casePath -Content $caseInstaller
            $caseResult = Invoke-PwshProcess -Arguments @(
                '-NoProfile', '-File', $script:InstallDownloadGatePath,
                '-RepositoryRoot', $script:RepoRoot,
                '-InstallScriptPath', $casePath,
                '-Treeish', 'HEAD'
            )
            $caseResult.ExitCode | Should -Not -Be 0 -Because $case.Name
            $caseResult.StdErr | Should -Match $case.Error -Because $case.Name
        }
    }

    It 'refuses to run the persistent installer E2E directly on a development machine' {
        $savedCi = $env:CI
        try {
            $env:CI = ''
            $result = Invoke-PwshProcess -Arguments @(
                '-NoProfile', '-File', $script:InstallE2ePath,
                '-Route', 'Direct', '-RepositoryRoot', $script:RepoRoot
            )
            $result.ExitCode | Should -Not -Be 0
            $result.StdErr | Should -Match 'Run it through GitHub Actions'
            $result.StdErr | Should -Match 'test-install-redirected\.ps1'
        } finally {
            $env:CI = $savedCi
        }
    }

    It 'does not accept a generic CI marker as disposable-runner authorization' {
        $savedCi = $env:CI
        $savedGitHubActions = $env:GITHUB_ACTIONS
        try {
            $env:CI = 'true'
            $env:GITHUB_ACTIONS = ''
            $result = Invoke-PwshProcess -Arguments @(
                '-NoProfile', '-File', $script:InstallE2ePath,
                '-Route', 'Direct', '-RepositoryRoot', $script:RepoRoot
            )
            $result.ExitCode | Should -Not -Be 0
            $result.StdErr | Should -Match 'Run it through GitHub Actions'
        } finally {
            $env:CI = $savedCi
            $env:GITHUB_ACTIONS = $savedGitHubActions
        }
    }

    It 'fails closed before uninstall can use the redirected installer seam' {
        $savedHome = $env:HOME
        $savedUserProfile = $env:USERPROFILE
        $savedMode = $env:WINSMUX_INSTALL_E2E
        $savedStateRoot = $env:WINSMUX_INSTALL_STATE_ROOT
        $liveProfile = $PROFILE.CurrentUserAllHosts
        $profileExisted = Test-Path -LiteralPath $liveProfile -PathType Leaf
        $profileHash = if ($profileExisted) { (Get-FileHash -LiteralPath $liveProfile -Algorithm SHA256).Hash } else { '' }
        try {
            $fixtureHome = Join-Path $TestDrive 'redirected-home'
            $env:HOME = $fixtureHome
            $env:USERPROFILE = $fixtureHome
            $env:WINSMUX_INSTALL_E2E = 'redirected'
            $env:WINSMUX_INSTALL_STATE_ROOT = Join-Path $fixtureHome 'state'
            $result = Invoke-PwshProcess -Arguments @('-NoProfile', '-File', $script:InstallerPath, 'uninstall')
            $result.ExitCode | Should -Not -Be 0
            $result.StdErr | Should -Match 'Redirected installer E2E mode only permits the install action'
        } finally {
            $env:HOME = $savedHome
            $env:USERPROFILE = $savedUserProfile
            $env:WINSMUX_INSTALL_E2E = $savedMode
            $env:WINSMUX_INSTALL_STATE_ROOT = $savedStateRoot
        }
        $profileAfterExists = Test-Path -LiteralPath $liveProfile -PathType Leaf
        $profileAfterHash = if ($profileAfterExists) { (Get-FileHash -LiteralPath $liveProfile -Algorithm SHA256).Hash } else { '' }
        $profileAfterExists | Should -Be $profileExisted
        $profileAfterHash | Should -Be $profileHash
    }

    It 'keeps the package source and staged publish artifact separate' {
        $packageReadme = Get-Content -LiteralPath $script:PackageReadmePath -Raw -Encoding UTF8
        $stageScript = Get-Content -LiteralPath $script:StageScriptPath -Raw -Encoding UTF8

        Test-Path -LiteralPath (Join-Path $script:PackageRoot 'install.ps1') | Should -BeFalse
        $stageScript | Should -Match 'installScriptSource = path\.join\(repoRoot, "install\.ps1"\)'
        $stageScript | Should -Match 'fs\.writeFileSync\(path\.join\(targetDir, "install\.ps1"\), versionPatched\)'
        $packageReadme | Should -Match 'source directory is not the publish artifact'
        $packageReadme | Should -Match 'published npm tarball is\s+produced by'
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
        $stagedPackage.winsmuxReleaseTag | Should -Be 'v0.23.0'
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
        $stagedReadme | Should -Match 'exact GitHub release tag'
        $stagedReadme | Should -Match 'source directory is not the publish artifact'
        $stagedReadme | Should -Match 'added during\s+staging'
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
        $stagedEntrypoint | Should -Match 'packageJson\.winsmuxReleaseTag \?\? `v\$\{packageJson\.version\}`'
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
        $stagedInstallScript | Should -Match 'SHA256SUMS asset not found in release'
        $stagedInstallScript | Should -Match 'Cannot verify release asset'
        $stagedInstallScript | Should -Match 'Invoke-RestMethod -Uri \$asset\.browser_download_url -Headers \$headers -OutFile \$downloadPath -ErrorAction Stop'
        $stagedInstallScript | Should -Match 'Move-Item -LiteralPath \$downloadPath -Destination \$winsmuxExe -Force'
        $stagedInstallScript | Should -Not -Match 'Invoke-RestMethod -Uri \$asset\.browser_download_url -Headers \$headers -OutFile \$winsmuxExe'
        $stagedInstallScript | Should -Not -Match 'Skipping checksum verification'

        $helpResult = Invoke-NodeProcess -Arguments @((Join-Path $script:OutputRoot 'index.mjs'), 'help') -WorkingDirectory $script:OutputRoot
        $helpResult.ExitCode | Should -Be 0
        $helpResult.StdErr | Should -Be ''
        $helpResult.StdOut | Should -Match 'Usage: install\.ps1 \[action\]'
        $helpResult.StdOut | Should -Match 'Profiles:'
    }

    It 'maps a four-part packaging hotfix tag to unique npm and exact release identities' {
        $stageResult = Invoke-NodeProcess -Arguments @(
            $script:StageScriptPath,
            '--release-tag',
            'v0.36.28.1',
            '--out',
            'output/npm-release/winsmux'
        )

        $stageResult.ExitCode | Should -Be 0
        $stageResult.StdErr | Should -Be ''
        $stagedPackage = Get-Content -LiteralPath (Join-Path $script:OutputRoot 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $stagedPackage.version | Should -Be '0.36.28-hotfix.1'
        $stagedPackage.winsmuxReleaseTag | Should -Be 'v0.36.28.1'

        $releaseWorkflow = Get-Content -LiteralPath $script:ReleaseWorkflowPath -Raw -Encoding UTF8
        $releaseWorkflow | Should -Match '(?m)^\s+release_tag:$'
        $releaseWorkflow | Should -Not -Match 'github\.event\.inputs\.version'
        $releaseWorkflow | Should -Match 'github\.event\.inputs\.release_tag'
        $releaseWorkflow | Should -Match 'stage-npm-release\.mjs --release-tag \$releaseTag'
        $releaseWorkflow | Should -Match 'version=\$version'
        $releaseWorkflow | Should -Match 'release_tag=\$releaseTag'
        $releaseWorkflow | Should -Match 'npm publish --access public --tag latest'

        $stagedEntrypoint = Get-Content -LiteralPath (Join-Path $script:OutputRoot 'index.mjs') -Raw -Encoding UTF8
        $stagedEntrypoint | Should -Match 'packageJson\.winsmuxReleaseTag \?\? `v\$\{packageJson\.version\}`'
    }
}
