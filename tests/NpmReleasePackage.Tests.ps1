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
        $script:OutputRoot = Join-Path $TestDrive 'unused-output'
        $script:ProductVersion = (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'VERSION') -Raw -Encoding UTF8).Trim()
        # Pester TestDrive is normally inside TEMP. Give stage children a
        # separate owned temporary root so the physical separation gate remains
        # active for every positive and negative package fixture.
        $script:StageTemp = Join-Path $script:RepoRoot ('.evidence/workspace-package/npm-contract-temp-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:StageTemp)

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

            if ($Arguments -contains $script:StageScriptPath) {
                $startInfo.Environment['TEMP'] = $script:StageTemp
                $startInfo.Environment['TMP'] = $script:StageTemp
            }

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
            $ownedRoot = [IO.Path]::GetFullPath($TestDrive).TrimEnd('\') + '\'
            if (-not [IO.Path]::GetFullPath($script:OutputRoot).StartsWith($ownedRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Release fixture cleanup must stay inside TestDrive.'
            }
            if (Test-Path -LiteralPath $script:OutputRoot) {
                Remove-Item -LiteralPath $script:OutputRoot -Recurse -Force
            }
        }

        function New-NpmReleaseFixture([string]$Version) {
            $fixture = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
            $files = @{
                'VERSION' = "$Version`n"
                'Cargo.toml' = "[workspace]`nmembers = [`"core`", `"core/crates/winsmux-workspace-mcp`", `"winsmux-app/src-tauri`"]`nresolver = `"2`"`n"
            }
            $lock = "version = 4`n"
            foreach ($package in @(@('winsmux', 'core'), @('winsmux-app', 'winsmux-app/src-tauri'), @('winsmux-workspace-mcp', 'core/crates/winsmux-workspace-mcp'))) {
                $files[$package[1] + '/Cargo.toml'] = "[package]`nname = `"$($package[0])`"`nversion = `"$Version`"`nedition = `"2021`"`n"
                $files[$package[1] + '/src/main.rs'] = "fn main() {}`n"
                $lock += "`n[[package]]`nname = `"$($package[0])`"`nversion = `"$Version`"`n"
            }
            $files['Cargo.lock'] = $lock
            $files['winsmux-app/package.json'] = ConvertTo-Json @{ version = $Version } -Compress
            $files['winsmux-app/package-lock.json'] = ConvertTo-Json @{ version = $Version; packages = @{ '' = @{ version = $Version } } } -Depth 8 -Compress
            $files['winsmux-app/src-tauri/tauri.conf.json'] = ConvertTo-Json @{ version = $Version } -Compress
            foreach ($relative in @('scripts/stage-npm-release.mjs', 'scripts/assert-distribution-version.ps1', 'scripts/distribution-prelaunch.mjs',
                'LICENSE', 'packages/winsmux/package.json', 'packages/winsmux/README.md', 'packages/winsmux/index.mjs')) {
                $files[$relative] = [IO.File]::ReadAllText((Join-Path $script:RepoRoot $relative))
            }
            $productInstaller = [IO.File]::ReadAllText($script:InstallerPath)
            $files['install.ps1'] = [regex]::Replace($productInstaller, '(?m)^\$VERSION\s*=\s*"[^"\r\n]+"', ('$VERSION = "' + $Version + '"'))
            foreach ($relative in $files.Keys) { Write-TestFileUtf8 (Join-Path $fixture $relative) $files[$relative] }
            $script:OutputRoot = Join-Path $fixture 'output/npm-release/winsmux'
            return $fixture
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
        $installer | Should -Match 'New-WinsmuxLifecycleState \$lease \(Get-WinsmuxExecutingInstallerSource\) \$script:ResolvedVersion'
        $installer | Should -Match 'Publish-WinsmuxLifecycle \$lease \$lifecycle'
        $installer | Should -Not -Match 'Download-File "install\.ps1" \(Join-Path \$BIN_DIR "install\.ps1"\)'
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
        $installE2e | Should -Match ([regex]::Escape('-IncludeGitHubAccess:($isGitHubRunner -and -not $candidateFixture)'))
        $installE2e | Should -Match 'Invoke-CapturedProcess -FilePath \$npmShim[^\r\n]+-IncludeGitHubAccess:'
        $installE2e | Should -Match 'Invoke-IrmInstaller -SourceInstaller \$installerPath[^\r\n]+-IncludeGitHubAccess:'
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
        $installer | Should -Match 'Test-IsPipedWinsmuxInstaller -InvocationPath \$installerInvocationPath'
        $installer | Should -Match "(?s)\`$requestedReleaseTag = if \(\`$releaseAction -notin @\('install', 'update'\)\).*?Assert-WinsmuxReleaseTag -ReleaseTag \`$requestedReleaseTag"
        $installer | Should -Match 'switch \(\$releaseAction\)'
        $installer | Should -Not -Match 'switch \(\$Action\.ToLower\(\)\)'
        $installE2e | Should -Match 'WT settings: not found'
        $installE2e | Should -Match "wrapper.*doctor"
        $installE2e | Should -Match 'installer download failure'
        $installE2e | Should -Not -Match '\$installResult\.Combined -match ''404\|Not Found\|Failed to download'''
        $installE2e | Should -Match 'Defect fixture skips release binary acquisition'
        $installE2e | Should -Match 'Install-WinsmuxBinary.*-Lease.*lease.*\[ \\t\]\*\\r\?\$'
        $installE2e | Should -Not -Match '\$result\.Combined -notmatch ''404\|Not Found\|Failed to download'''
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

    It 'prepares npm before HOME isolation and keeps private transport separate from public release evidence' {
        $source = [IO.File]::ReadAllText($script:InstallE2ePath)
        $stageOffset = $source.IndexOf("'scripts/stage-npm-release.mjs'", [StringComparison]::Ordinal)
        $isolationOffset = $source.IndexOf('$env:HOME = $fixtureHome', [StringComparison]::Ordinal)
        $stageOffset | Should -BeGreaterThan 0
        $stageOffset | Should -BeLessThan $isolationOffset
        $source | Should -Match ([regex]::Escape('$repositoryPreparationOpen = $false'))
        $source | Should -Match ([regex]::Escape('$FilePath -notin @($node, $npm)'))
        $source | Should -Match 'pristine_tarball_sha256'
        $source | Should -Match 'fixture_tarball_sha256'
        $source | Should -Match 'Pristine npm installer differs from the candidate Git source'
        $source | Should -Match 'Fixture npm projection changed its index, metadata, or declared installer'
        $source | Should -Match 'Private candidate fixture must not use a public release override'
        $source | Should -Match 'public_release_acquisition_proven = \$false'
        $workflow = [IO.File]::ReadAllText($script:TestWorkflowPath)
        $candidate = [regex]::Match($workflow, '(?ms)^  fresh-install-candidate:\s*\r?\n(?<body>.*?)(?=^  [A-Za-z0-9_-]+:\s*\r?$|\z)').Groups['body'].Value
        $candidate | Should -Match 'setup-windows-distribution-toolchain'
        $candidate | Should -Match 'node scripts/build-core-candidate.mjs x86_64-pc-windows-msvc'
        $candidate | Should -Not -Match 'contents: write|npm publish|action-gh-release'
        $workflow | Should -Match ([regex]::Escape('fresh-install-candidate-${{ github.sha }}'))
        $workflow | Should -Match ([regex]::Escape('-CandidateDirectory "${{ runner.temp }}/fresh-install-candidate"'))
        $workflow | Should -Not -Match 'WINSMUX_INSTALL_E2E_RELEASE_TAG: v0\.36\.28'
    }

    It 'classifies saved and in-memory installer inputs under strict mode: <Mode>' -TestCases @(
        @{ Mode = 'saved'; ExpectedPiped = $false },
        @{ Mode = 'saved-dot'; ExpectedPiped = $false },
        @{ Mode = 'scriptblock'; ExpectedPiped = $true },
        @{ Mode = 'scriptblock-dot'; ExpectedPiped = $true },
        @{ Mode = 'piped'; ExpectedPiped = $true }
    ) {
        param($Mode, $ExpectedPiped)
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        $mainOffset = $installer.IndexOf('# Main', [StringComparison]::Ordinal)
        $mainOffset | Should -BeGreaterThan 0
        # The exact product prefix defines its functions without invoking an
        # install/update/uninstall action. Run iex from a saved caller as well,
        # so that the caller's PSCommandPath cannot masquerade as input identity.
        $prefixPath = Join-Path $TestDrive ('invocation-' + $Mode + '.ps1')
        Write-TestFileUtf8 -Path $prefixPath -Content ($installer.Substring(0, $mainOffset) +
            "`nWrite-Output (ConvertTo-Json @{ piped = `$isPipedInstaller } -Compress)`n")
        $callerPath = Join-Path $TestDrive ('caller-' + $Mode + '.ps1')
        Write-TestFileUtf8 -Path $callerPath -Content @'
param([string]$Mode, [string]$InputPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
foreach ($key in @('GITHUB_ACTIONS', 'WINSMUX_INSTALL_E2E', 'WINSMUX_INSTALL_STATE_ROOT', 'WINSMUX_INSTALL_SOURCE_REF', 'WINSMUX_RELEASE_TAG')) {
    [Environment]::SetEnvironmentVariable($key, $null, 'Process')
}
switch ($Mode) {
    'saved' { & $InputPath }
    'saved-dot' { . $InputPath }
    'scriptblock' { & ([scriptblock]::Create([IO.File]::ReadAllText($InputPath))) }
    'scriptblock-dot' { . ([scriptblock]::Create([IO.File]::ReadAllText($InputPath))) }
    'piped' { Get-Content -LiteralPath $InputPath -Raw | Invoke-Expression }
}
'@
        $result = Invoke-PwshProcess -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $callerPath, $Mode, $prefixPath)
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        ($result.StdOut | ConvertFrom-Json).piped | Should -Be $ExpectedPiped
    }

    It 'persists the complete current consumer for saved and piped release actions' {
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        $installer | Should -Match '(?s)\$release\s*=\s*Resolve-WinsmuxRelease.*?\$headers\s*=\s*Get-WinsmuxReleaseHeaders.*?browser_download_url\s+-Headers\s+\$headers'
        $installer | Should -Not -Match 'Invoke-TargetInstallerBootstrap|Test-ShouldBootstrapTargetInstaller|WINSMUX_INTERNAL_TARGET_INSTALLER_BOOTSTRAPPED'
        $mainOffset = $installer.IndexOf('# Main', [StringComparison]::Ordinal)
        $mainOffset | Should -BeGreaterThan 0
        . ([scriptblock]::Create($installer.Substring(0, $mainOffset)))
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
        $proofScript = Join-Path $script:RepoRoot 'tests/workspace-package/install-lifecycle-source.test.ps1'
        $proofOutput = & pwsh -NoLogo -NoProfile -File $proofScript
        $LASTEXITCODE | Should -Be 0
        $summary = ($proofOutput | Select-Object -Last 1) | ConvertFrom-Json
        $proof = Get-Content -LiteralPath (Join-Path $summary.root 'result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $proof.completed | Should -BeTrue
        $proof.passed | Should -Be 20
        $proof.failed | Should -Be 0
        $main = $installer.Substring($mainOffset)
        $main | Should -Match '"install"\s+\{ Invoke-Install \}'
        $main | Should -Match '"update"\s+\{ Invoke-Install -IsUpdate \}'
    }

    It 'keeps non-release actions independent from a stale release tag' {
        $installerLiteral = $script:InstallerPath.Replace("'", "''")
        foreach ($case in @(
            @{ Action = 'help'; Expected = 'Usage: install.ps1' },
            @{ Action = 'version'; Expected = "winsmux $script:ProductVersion" },
            @{ Action = 'unknown-action'; Expected = 'Usage: install.ps1' }
        )) {
            $command = "`$env:WINSMUX_RELEASE_TAG = '../../attacker/repo/main'; & '$installerLiteral' $($case.Action) -ReleaseTag 'also-invalid'"
            $result = Invoke-PwshProcess -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command)
            $result.ExitCode | Should -Be 0
            $result.StdOut | Should -Match ([regex]::Escape($case.Expected))
            $result.StdErr | Should -Not -Match 'Invalid winsmux release tag'
        }
    }

    It 'refuses missing paired release assets even when the installed binary already matches' {
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
                return 'winsmux-x64.exe'
            }

            { Install-WinsmuxBinary } | Should -Throw '*Missing or ambiguous paired release asset*'
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

    It 'preserves legacy evidence and restores the complete prior generation after replacement failure' {
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        $installer | Should -Not -Match 'function (Repair-WinsmuxBinaryRotation|Clear-WinsmuxBinaryRotation|Install-VerifiedWinsmuxBinary)'
        $selection = 'prior-success,prior-fault-before-readback,absent-one-legacy,absent-two-legacy,invalid-no-legacy,invalid-with-legacy'
        $proofScript = Join-Path $script:RepoRoot 'tests/workspace-package/install-generation.test.ps1'
        $proofOutput = & pwsh -NoLogo -NoProfile -File $proofScript -SelectedCase $selection
        $LASTEXITCODE | Should -Be 0
        $summary = ($proofOutput | Select-Object -Last 1) | ConvertFrom-Json
        $proof = Get-Content -LiteralPath $summary.result -Raw -Encoding UTF8 | ConvertFrom-Json
        $proof.completed | Should -BeTrue
        $proof.passed | Should -Be 6
        $proof.failed | Should -Be 0
        $proof.selection | Should -BeExactly $selection
        @($proof.cases.name | Sort-Object) -join ',' | Should -BeExactly (($selection.Split(',') | Sort-Object) -join ',')
    }

    It 'classifies download responses under strict mode: <StatusCode>' -TestCases @(
        @{ StatusCode = 408; Retry = $true }, @{ StatusCode = 429; Retry = $true },
        @{ StatusCode = 500; Retry = $true }, @{ StatusCode = 599; Retry = $true },
        @{ StatusCode = 400; Retry = $false }, @{ StatusCode = 401; Retry = $false },
        @{ StatusCode = 404; Retry = $false }, @{ StatusCode = 600; Retry = $false }
    ) {
        param($StatusCode, $Retry)
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        . ([scriptblock]::Create($installer.Substring(0, $installer.IndexOf('# Main', [StringComparison]::Ordinal))))
        $response = [Net.Http.HttpResponseMessage]::new([Enum]::ToObject([Net.HttpStatusCode], $StatusCode))
        try {
            $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('HTTP failure', $response)
            $errorRecord = [Management.Automation.ErrorRecord]::new($exception, 'http-fixture', [Management.Automation.ErrorCategory]::InvalidOperation, $null)
            Get-WinsmuxDownloadStatusCode $errorRecord | Should -Be $StatusCode
            Test-RetryableDownloadFailure $errorRecord | Should -Be $Retry
        } finally { $response.Dispose() }
    }

    It 'handles missing download response metadata without inventing an HTTP status: <Shape>' -TestCases @(
        @{ Shape = 'absent'; Message = 'timeout'; Retry = $true },
        @{ Shape = 'null'; Message = 'connection reset'; Retry = $true },
        @{ Shape = 'no-status'; Message = '404 not found'; Retry = $false },
        @{ Shape = 'invalid-status'; Message = 'permanent failure'; Retry = $false }
    ) {
        param($Shape, $Message, $Retry)
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        . ([scriptblock]::Create($installer.Substring(0, $installer.IndexOf('# Main', [StringComparison]::Ordinal))))
        $exception = [Exception]::new($Message)
        switch ($Shape) {
            'null' { $exception | Add-Member NoteProperty Response $null }
            'no-status' { $exception | Add-Member NoteProperty Response ([pscustomobject]@{ Other = 'fixture' }) }
            'invalid-status' { $exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode = 'invalid' }) }
        }
        $errorRecord = [Management.Automation.ErrorRecord]::new($exception, 'metadata-fixture', [Management.Automation.ErrorCategory]::InvalidOperation, $null)
        Get-WinsmuxDownloadStatusCode $errorRecord | Should -BeNullOrEmpty
        Test-RetryableDownloadFailure $errorRecord | Should -Be $Retry
    }

    It 'handles missing response metadata for optional-file probes without masking the original failure' {
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        . ([scriptblock]::Create($installer.Substring(0, $installer.IndexOf('# Main', [StringComparison]::Ordinal))))
        Mock Invoke-WebRequest { throw '404 not found' }
        Test-RemoteFileExists 'fixture' | Should -BeFalse
        Mock Invoke-WebRequest { throw 'timeout' }
        { Test-RemoteFileExists 'fixture' } | Should -Throw '*timeout*'
    }

    It 'retries transient download failures without replacing the destination until success' {
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        . ([scriptblock]::Create($installer.Substring(0, $installer.IndexOf('# Main', [System.StringComparison]::Ordinal))))
        $dest = Join-Path $TestDrive 'download.txt'
        'old' | Set-Content -LiteralPath $dest -NoNewline -Encoding utf8
        $script:r46Attempts = 0
        Mock Invoke-RestMethod { param($Uri, $OutFile); $script:r46Attempts++; if ($script:r46Attempts -eq 1) { throw 'timeout' }; 'new' | Set-Content -LiteralPath $OutFile -NoNewline -Encoding utf8 }
        Download-File 'fixture' $dest
        $script:r46Attempts | Should -Be 2
        Get-Content -LiteralPath $dest -Raw -Encoding utf8 | Should -Be 'new'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.download-*.tmp' -File).Count | Should -Be 0
    }

    It 'stops a permanent download failure after one attempt without mutating the destination' {
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        . ([scriptblock]::Create($installer.Substring(0, $installer.IndexOf('# Main', [System.StringComparison]::Ordinal))))
        $dest = Join-Path $TestDrive 'permanent.txt'; 'old' | Set-Content $dest -NoNewline -Encoding utf8
        $script:r46Attempts = 0
        Mock Invoke-RestMethod { $script:r46Attempts++; throw '404 not found' }
        { Invoke-DownloadFileWithRetry 'fixture' $dest } | Should -Throw
        $script:r46Attempts | Should -Be 1
        Get-Content $dest -Raw -Encoding utf8 | Should -Be 'old'
        @(Get-ChildItem $TestDrive -Filter '*.download-*.tmp' -File).Count | Should -Be 0
    }

    It 'stops transient download failures after three attempts without mutating the destination' {
        $installer = Get-Content -LiteralPath $script:InstallerPath -Raw -Encoding UTF8
        . ([scriptblock]::Create($installer.Substring(0, $installer.IndexOf('# Main', [System.StringComparison]::Ordinal))))
        $dest = Join-Path $TestDrive 'transient.txt'; 'old' | Set-Content $dest -NoNewline -Encoding utf8
        $script:r46Attempts = 0
        Mock Invoke-RestMethod { $script:r46Attempts++; throw 'timeout' }
        { Invoke-DownloadFileWithRetry 'fixture' $dest } | Should -Throw
        $script:r46Attempts | Should -Be 3
        Get-Content $dest -Raw -Encoding utf8 | Should -Be 'old'
        @(Get-ChildItem $TestDrive -Filter '*.download-*.tmp' -File).Count | Should -Be 0
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
        $candidateIndex = Join-Path $TestDrive 'install-download-candidate.index'
        $originalIndex = [Environment]::GetEnvironmentVariable(
            'GIT_INDEX_FILE',
            [EnvironmentVariableTarget]::Process
        )
        try {
            $env:GIT_INDEX_FILE = $candidateIndex
            & git -C $script:RepoRoot read-tree HEAD
            $LASTEXITCODE | Should -Be 0
            & git -C $script:RepoRoot add -- `
                install.ps1 `
                winsmux-core/scripts/declarative-workflow.ps1
            $LASTEXITCODE | Should -Be 0
            $candidateTree = [string](& git -C $script:RepoRoot write-tree)
            $LASTEXITCODE | Should -Be 0
            $candidateTree = $candidateTree.Trim()
            $candidateTree | Should -Match '^[0-9a-f]{40}$'
        } finally {
            if ($null -eq $originalIndex) {
                Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
            } else {
                $env:GIT_INDEX_FILE = $originalIndex
            }
        }
        if ($null -eq $originalIndex) {
            Test-Path Env:GIT_INDEX_FILE | Should -BeFalse
        } else {
            $env:GIT_INDEX_FILE | Should -BeExactly $originalIndex
        }

        $valid = Invoke-PwshProcess -Arguments @(
            '-NoProfile', '-File', $script:InstallDownloadGatePath,
            '-RepositoryRoot', $script:RepoRoot,
            '-Treeish', $candidateTree
        )
        $valid.ExitCode | Should -Be 0
        $valid.StdErr | Should -Be ''
        $validSummary = $valid.StdOut | ConvertFrom-Json -Depth 10
        $validSummary.download_target_count | Should -BeGreaterThan 0
        $validSummary.runtime_dependency_count | Should -BeGreaterThan 0
        @($validSummary.download_targets) | Should -Contain 'scripts/winsmux-core.ps1'
        @($validSummary.download_targets) | Should -Contain 'winsmux-core/scripts/declarative-workflow.ps1'
        @($validSummary.download_targets) | Should -Not -Contain 'winsmux.ps1'
        @($validSummary.runtime_dependencies) | Should -Contain 'declarative-workflow.ps1'
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
            '-Treeish', $candidateTree
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
                '-Treeish', $candidateTree
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
        $stageScript | Should -Match 'files\.set\("install\.ps1", fs\.readFileSync\(path\.join\(repoRoot, "install\.ps1"\)\)\)'
        $stageScript | Should -Not -Match 'installer\.replace'
        $stageScript | Should -Match 'verifyFiles\(stageDir, files\)'
        $stageScript | Should -Match 'publishGeneration\(targetDir, stageDir, backupDir, pendingPath, files\)'
        $packageReadme | Should -Match 'source directory is not the publish artifact'
        $packageReadme | Should -Match 'published npm tarball is\s+produced by'
    }

    It 'refuses staging when the package source is explicitly gated and preserves it' {
            $fixture = New-NpmReleaseFixture '0.23.0'
            $packagePath = Join-Path $fixture 'packages/winsmux/package.json'
            $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
            $package.private = $true
            Write-TestFileUtf8 $packagePath (ConvertTo-Json $package -Depth 20)
            $originalPackageHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash

            $result = Invoke-NodeProcess -Arguments @(
                $script:StageScriptPath,
                '--version',
                '0.23.0',
                '--out',
                'output/npm-release/winsmux'
            ) -WorkingDirectory $fixture

            $result.ExitCode | Should -Not -Be 0
            $result.StdErr | Should -Match 'npm package is not enabled for release preparation'
            Test-Path -LiteralPath $script:OutputRoot | Should -Be $false
            (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash | Should -Be $originalPackageHash
    }

    It 'preserves installer bytes across native and package repair preparation entrances' {
        foreach ($ending in @("`n", "`r`n")) {
            foreach ($repair in @($false, $true)) {
                $fixture = New-NpmReleaseFixture '0.23.0'
                $installerPath = Join-Path $fixture 'install.ps1'
                $body = [IO.File]::ReadAllText($installerPath).Replace("`r`n", "`n")
                $body = $body.Replace('$VERSION = "0.23.0"', "`t`$VERSION `t= `"0.23.0`" `t")
                $body = $body.Replace("`n", $ending)
                Write-TestFileUtf8 $installerPath $body
                $originalHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
                $selection = if ($repair) { @('--release-tag', 'v0.23.0.1') } else { @('--version', '0.23.0') }
                $result = Invoke-NodeProcess -Arguments (@($script:StageScriptPath) + $selection + @('--out', 'output/npm-release/winsmux')) -WorkingDirectory $fixture
                $result.ExitCode | Should -Be 0 -Because "the verified source version is unchanged ($repair; $($ending.Length) byte newline)"
                (Get-FileHash -LiteralPath (Join-Path $script:OutputRoot 'install.ps1') -Algorithm SHA256).Hash | Should -BeExactly $originalHash
                $package = Get-Content -LiteralPath (Join-Path $script:OutputRoot 'package.json') -Raw | ConvertFrom-Json
                $package.version | Should -BeExactly $(if ($repair) { '0.23.0-pkgfix.1' } else { '0.23.0' })
                Remove-StagedReleaseOutput
            }
        }
    }

    It 'stages a release-ready package when the publish gate is open' {
        $fixture = New-NpmReleaseFixture '0.23.0'
        $stageResult = Invoke-NodeProcess -Arguments @(
            $script:StageScriptPath,
            '--version',
            '0.23.0',
            '--out',
            'output/npm-release/winsmux'
        ) -WorkingDirectory $fixture

        $stageResult.ExitCode | Should -Be 0
        $stageResult.StdErr | Should -Be ''
        $stageResult.StdOut | Should -Match 'Staged winsmux 0\.23\.0 \(v0\.23\.0; native 0\.23\.0\) at'

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
        $stagedInstallScript | Should -Match 'Missing or ambiguous paired release asset'
        $stagedInstallScript | Should -Match 'Release checksum is missing the exact paired asset'
        $stagedInstallScript | Should -Match 'Invoke-RestMethod -Uri \$asset\.browser_download_url -Headers \$headers -OutFile \$downloadPath -ErrorAction Stop'
        $stagedInstallScript | Should -Match 'Install-VerifiedWinsmuxGeneration \$lease \$state \$downloadPath \$sidecar'
        $stagedInstallScript | Should -Not -Match 'Invoke-RestMethod -Uri \$asset\.browser_download_url -Headers \$headers -OutFile \$winsmuxExe'
        $stagedInstallScript | Should -Not -Match 'Skipping checksum verification'

        $helpResult = Invoke-NodeProcess -Arguments @((Join-Path $script:OutputRoot 'index.mjs'), 'help') -WorkingDirectory $script:OutputRoot
        $helpResult.ExitCode | Should -Be 0
        $helpResult.StdErr | Should -Be ''
        $helpResult.StdOut | Should -Match 'Usage: install\.ps1 \[action\]'
        $helpResult.StdOut | Should -Match 'Profiles:'
    }

    It 'maps a four-part packaging hotfix tag to unique npm and exact release identities' {
        $fixture = New-NpmReleaseFixture '0.36.28'
        $stageResult = Invoke-NodeProcess -Arguments @(
            $script:StageScriptPath,
            '--release-tag',
            'v0.36.28.1',
            '--out',
            'output/npm-release/winsmux'
        ) -WorkingDirectory $fixture

        $stageResult.ExitCode | Should -Be 0
        $stageResult.StdErr | Should -Be ''
        $stagedPackage = Get-Content -LiteralPath (Join-Path $script:OutputRoot 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $stagedPackage.version | Should -Be '0.36.28-pkgfix.1'
        $stagedPackage.winsmuxReleaseTag | Should -Be 'v0.36.28.1'

        $releaseWorkflow = Get-Content -LiteralPath $script:ReleaseWorkflowPath -Raw -Encoding UTF8
        $releaseWorkflow | Should -Not -Match 'workflow_dispatch'
        $releaseWorkflow | Should -Not -Match 'github\.event\.inputs\.'
        $releaseWorkflow | Should -Match 'stage-npm-release\.mjs --release-tag \$releaseTag'
        $releaseWorkflow | Should -Match 'version=\$version'
        $releaseWorkflow | Should -Match 'release_tag=\$releaseTag'
        $releaseWorkflow | Should -Match 'npm publish --access public --tag latest'

        $stagedEntrypoint = Get-Content -LiteralPath (Join-Path $script:OutputRoot 'index.mjs') -Raw -Encoding UTF8
        $stagedEntrypoint | Should -Match 'packageJson\.winsmuxReleaseTag \?\? `v\$\{packageJson\.version\}`'
    }

    It 'rejects release tags that collide with the reserved npm hotfix namespace' {
        $stageResult = Invoke-NodeProcess -Arguments @(
            $script:StageScriptPath,
            '--release-tag',
            'v0.36.28-pkgfix.1',
            '--out',
            'output/npm-release/winsmux'
        )

        $stageResult.ExitCode | Should -Not -Be 0
        $stageResult.StdErr | Should -Match 'Unsupported native release version: 0\.36\.28-pkgfix\.1'
        Test-Path -LiteralPath $script:OutputRoot | Should -BeFalse
    }

    It 'preserves an ordinary prerelease tag outside the reserved namespace' {
        $fixture = New-NpmReleaseFixture '0.36.29-preview.1'
        $stageResult = Invoke-NodeProcess -Arguments @(
            $script:StageScriptPath,
            '--release-tag',
            'v0.36.29-preview.1',
            '--out',
            'output/npm-release/winsmux'
        ) -WorkingDirectory $fixture

        $stageResult.ExitCode | Should -Be 0
        $stageResult.StdErr | Should -Be ''
        $stagedPackage = Get-Content -LiteralPath (Join-Path $script:OutputRoot 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $stagedPackage.version | Should -Be '0.36.29-preview.1'
        $stagedPackage.winsmuxReleaseTag | Should -Be 'v0.36.29-preview.1'
    }
}
