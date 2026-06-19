$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'winsmux version surface' {
    BeforeAll {
        $script:RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:RepoRoot)) {
            throw 'Failed to resolve repository root.'
        }

        $script:ProductVersion = (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'VERSION') -Raw -Encoding UTF8).Trim()
    }

    It 'keeps release-critical product versions aligned' {
        $script:ProductVersion | Should -Match '^\d+\.\d+\.\d+$'

        $installScript = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'install.ps1') -Raw -Encoding UTF8
        $bridgeScript = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\winsmux-core.ps1') -Raw -Encoding UTF8
        $workspaceLock = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Cargo.lock') -Raw -Encoding UTF8
        $coreManifest = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'core\Cargo.toml') -Raw -Encoding UTF8
        $coreLock = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'core\Cargo.lock') -Raw -Encoding UTF8

        $installScript | Should -Match ('\$VERSION\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
        $installScript | Should -Match '\$UseLatestRelease\s*=\s*\[string\]::IsNullOrWhiteSpace\(\$requestedReleaseTag\) -and \$Action\.Trim\(\)\.ToLowerInvariant\(\) -eq ''update'''
        $installScript | Should -Match '\$EffectiveReleaseTag\s*=\s*if \(\[string\]::IsNullOrWhiteSpace\(\$requestedReleaseTag\)\) \{ "v\$VERSION" \}'
        $installScript | Should -Match 'releases/latest'
        $installScript | Should -Match 'releases/tags/\$escapedTag'
        $installScript | Should -Match 'version = \$ResolvedVersion'
        $installScript | Should -Match '\$ResolvedVersion \| Set-Content \$VERSION_FILE'
        $installScript | Should -Match 'function Get-WinsmuxCommandVersion'
        $installScript | Should -Match 'winsmux-core/scripts/colab-backend\.ps1'
        $installScript | Should -Match 'does not match release version'
        $installScript | Should -Match 'Reinstalling release binary'
        $bridgeScript | Should -Match ('\$VERSION\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
        $workspaceLock | Should -Match ('(?ms)^name\s*=\s*"winsmux"\s*\r?\nversion\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
        $coreManifest | Should -Match ('(?m)^version\s*=\s*"{0}"\r?$' -f [regex]::Escape($script:ProductVersion))
        $coreManifest | Should -Match '(?m)^license\s*=\s*"Apache-2\.0 AND MIT"\r?$'
        $coreManifest | Should -Match '(?m)^repository\s*=\s*"https://github\.com/Sora-bluesky/winsmux"\r?$'
        $coreLock | Should -Match ('(?ms)^name\s*=\s*"winsmux"\s*\r?\nversion\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
    }

    It 'keeps desktop app metadata aligned with the product version' {
        $appPackage = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\package.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $appPackageLock = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\package-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 20
        $tauriConfig = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src-tauri\tauri.conf.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $tauriManifest = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src-tauri\Cargo.toml') -Raw -Encoding UTF8
        $tauriLock = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src-tauri\Cargo.lock') -Raw -Encoding UTF8
        $workspaceLock = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Cargo.lock') -Raw -Encoding UTF8

        $appPackage.version | Should -Be $script:ProductVersion
        $appPackageLock['version'] | Should -Be $script:ProductVersion
        $appPackageLock['packages']['']['version'] | Should -Be $script:ProductVersion
        $tauriConfig.version | Should -Be $script:ProductVersion
        $tauriConfig.productName | Should -Be 'winsmux'
        $tauriConfig.app.windows[0].title | Should -Be 'winsmux'
        $tauriConfig.bundle.windows.nsis.languages | Should -Be @('English', 'Japanese')
        $tauriConfig.bundle.windows.nsis.displayLanguageSelector | Should -BeTrue
        $tauriManifest | Should -Match ('(?m)^version\s*=\s*"{0}"\r?$' -f [regex]::Escape($script:ProductVersion))
        $tauriManifest | Should -Match '(?m)^description\s*=\s*"Desktop control plane for winsmux"\r?$'
        $tauriManifest | Should -Match '(?m)^authors\s*=\s*\["Sora-bluesky"\]\r?$'
        $workspaceLock | Should -Match ('(?ms)^name\s*=\s*"winsmux-app"\s*\r?\nversion\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
        $tauriLock | Should -Match ('(?ms)^name\s*=\s*"winsmux-app"\s*\r?\nversion\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
    }

    It 'derives desktop installer E2E artifact names from VERSION' {
        $contextMenuE2e = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\scripts\windows-context-menu-e2e.ps1') -Raw -Encoding UTF8

        $contextMenuE2e | Should -Match ([regex]::Escape("Join-Path `$script:RepoRoot 'VERSION'"))
        $contextMenuE2e | Should -Match ([regex]::Escape('winsmux_$($script:ProductVersion)_x64-setup.exe'))
        $contextMenuE2e | Should -Not -Match 'winsmux_\d+\.\d+\.\d+_x64-setup\.exe'
    }

    It 'keeps staged npm package versions aligned while leaving the source package templated' {
        $stageScript = Join-Path $script:RepoRoot 'scripts\stage-npm-release.mjs'
        $outputRoot = Join-Path $TestDrive 'npm-release\winsmux'

        $sourcePackage = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'packages\winsmux\package.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $sourcePackage.version | Should -Be '0.0.0-development'

        & node $stageScript --version $script:ProductVersion --out $outputRoot
        $LASTEXITCODE | Should -Be 0

        $stagedPackage = Get-Content -LiteralPath (Join-Path $outputRoot 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $stagedInstaller = Get-Content -LiteralPath (Join-Path $outputRoot 'install.ps1') -Raw -Encoding UTF8

        $stagedPackage.version | Should -Be $script:ProductVersion
        $stagedInstaller | Should -Match ('\$VERSION\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
    }

    It 'rejects terse release notes before publishing release assets' {
        $qualityScript = Join-Path $script:RepoRoot 'scripts\assert-release-notes-quality.ps1'
        $releaseCoreWorkflow = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github\workflows\release-core.yml') -Raw -Encoding UTF8

        $generateIndex = $releaseCoreWorkflow.IndexOf('Generate Release Body')
        $qualityIndex = $releaseCoreWorkflow.IndexOf('Check Release Body Quality')
        $auditIndex = $releaseCoreWorkflow.IndexOf('Audit Release Public Surface')

        $generateIndex | Should -BeGreaterThan -1
        $qualityIndex | Should -BeGreaterThan $generateIndex
        $auditIndex | Should -BeGreaterThan $qualityIndex

        $terseBody = Join-Path $TestDrive 'terse-release-body.md'
        Set-Content -LiteralPath $terseBody -Value @'
## New Features

- add api_llm runner

## Full Changelog

- [v0.36.8...v0.36.9](https://github.com/Sora-bluesky/winsmux/compare/v0.36.8...v0.36.9)
'@ -Encoding UTF8

        $terseOutput = @(& pwsh -NoProfile -File $qualityScript -ReleaseNotesPath $terseBody 2>&1)

        $LASTEXITCODE | Should -Be 1
        ($terseOutput -join "`n") | Should -Match 'missing required section: Highlights'
        ($terseOutput -join "`n") | Should -Match 'release notes are too terse'
    }

    It 'accepts release-grade notes with highlights, safety, validation, and changelog evidence' {
        $qualityScript = Join-Path $script:RepoRoot 'scripts\assert-release-notes-quality.ps1'
        $releaseBody = Join-Path $TestDrive 'release-grade-body.md'
        Set-Content -LiteralPath $releaseBody -Value @'
## Highlights

- Adds the api_llm worker backend for hosted OpenAI-compatible providers.
- Keeps hosted API workers separate from local and Colab worker backends.
- Validates a hosted provider path with explicit provider and model metadata.
- Publishes release binaries, desktop installers, and npm package artifacts.

## Safety and operations

- Release notes are checked by the public-surface audit before publication.
- Secret-like values, local private paths, bearer tokens, and provider request metadata remain blocked from public release materials.
- Missing hosted API credentials stop before network access and do not launch a fallback backend.
- Public setup guidance keeps credential storage outside the repository and points users to runtime environment variables.
- Provider response identifiers are summarized as safe presence flags instead of being copied into public release text.

## Distribution

- GitHub Release assets are expected to include release executables, checksum files, and the final release body.
- npm publication is verified separately so package availability is not inferred from GitHub release creation alone.
- Desktop packaging remains a separate workflow gate and must finish before the release is treated as fully distributed.
- Follow-up dependency updates can land after the tag, but release notes must say which quality gates protected the tagged version.

## Validation

- `git diff --check`
- `pwsh -NoProfile -File scripts/audit-public-surface.ps1`
- `pwsh -NoProfile -File scripts/git-guard.ps1 -Mode full`
- `Invoke-Pester -Path tests/VersionSurface.Tests.ps1 -PassThru`
- `Invoke-Pester -Path tests/winsmux-bridge.Tests.ps1 -PassThru`
- `cargo test --manifest-path core/Cargo.toml`

This release body intentionally includes enough context for operators to understand the release outcome, security posture, validation path, distribution artifacts, and follow-up boundaries without reading private planning notes or raw execution logs. The quality gate should accept this level of detail and reject short generated summaries that only list commit categories.

## Full Changelog

- [v0.36.8...v0.36.9](https://github.com/Sora-bluesky/winsmux/compare/v0.36.8...v0.36.9)
'@ -Encoding UTF8

        $output = @(& pwsh -NoProfile -File $qualityScript -ReleaseNotesPath $releaseBody 2>&1)

        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'release-notes-quality.*passed'
    }

    It 'keeps tracked package metadata aligned with the public product surface' {
        $mcpPackage = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-core\package.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $mcpServer = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-core\mcp-server.js') -Raw -Encoding UTF8

        $mcpPackage.name | Should -Be 'winsmux-mcp'
        $mcpPackage.version | Should -Be $script:ProductVersion
        $mcpPackage.private | Should -BeTrue
        $mcpPackage.license | Should -Be 'Apache-2.0'
        $mcpServer | Should -Match ('const SERVER_VERSION = "{0}";' -f [regex]::Escape($script:ProductVersion))
    }

    It 'documents the public license split for runtime compatibility notices' {
        $readme = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'README.md') -Raw -Encoding UTF8
        $readmeJa = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'README.ja.md') -Raw -Encoding UTF8
        $packageReadme = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'packages\winsmux\README.md') -Raw -Encoding UTF8
        $thirdPartyNotices = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'THIRD_PARTY_NOTICES.md') -Raw -Encoding UTF8
        $coreLicense = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'core\LICENSE') -Raw -Encoding UTF8

        $readme | Should -Match 'Apache License 2\.0'
        $readme | Should -Match 'core/LICENSE'
        $readme | Should -Match 'THIRD_PARTY_NOTICES\.md'
        $readmeJa | Should -Match 'Apache License 2\.0'
        $readmeJa | Should -Match 'core/LICENSE'
        $readmeJa | Should -Match 'THIRD_PARTY_NOTICES\.md'
        $packageReadme | Should -Match 'The public npm package is Apache-2\.0'
        $packageReadme | Should -Match 'github\.com/Sora-bluesky/winsmux/blob/main/core/LICENSE'
        $packageReadme | Should -Match 'github\.com/Sora-bluesky/winsmux/blob/main/THIRD_PARTY_NOTICES\.md'
        $thirdPartyNotices | Should -Match 'License: MIT'
        $thirdPartyNotices | Should -Match 'MIT-derived compatibility implementation'
        $coreLicense | Should -Match 'MIT License'
    }

    It 'documents the completed legacy alias sunset consistently' {
        $readme = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'README.md') -Raw -Encoding UTF8
        $readmeJa = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'README.ja.md') -Raw -Encoding UTF8
        $compatibility = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'core\docs\compatibility.md') -Raw -Encoding UTF8
        $thirdPartyNotices = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'THIRD_PARTY_NOTICES.md') -Raw -Encoding UTF8
        $inventory = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\project\powershell-adapter-inventory.md') -Raw -Encoding UTF8

        foreach ($content in @($readme, $readmeJa, $compatibility, $thirdPartyNotices)) {
            $content | Should -Match 'psmux'
            $content | Should -Match 'pmux'
            $content | Should -Match 'tmux'
            $content | Should -Match 'winsmux'
            $content | Should -Match 'no longer ship|no longer shipped|配布しません'
        }

        $inventory | Should -Match 'TASK-296'
        $inventory | Should -Match 'legacy alias sunset'
        $compatibility | Should -Match 'does not remove tmux-compatible configuration support'
        $thirdPartyNotices | Should -Match 'no longer ships the legacy binary aliases'
    }

    It 'stops the release flow when verify fails before tagging or publishing' {
        $releaseScript = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\bump-version.ps1') -Raw -Encoding UTF8

        $verifyIndex = $releaseScript.IndexOf('& pwsh $bridgeScript verify $prNumber')
        $exitCheckIndex = $releaseScript.IndexOf('$verifyExitCode = $LASTEXITCODE')
        $prStateIndex = $releaseScript.IndexOf('gh pr view $prNumber --json state,mergeCommit')
        $remoteTagIndex = $releaseScript.IndexOf('git ls-remote --tags origin "refs/tags/v$Version"')
        $tagIndex = $releaseScript.IndexOf('git tag "v$Version" $releaseCommit')
        $releaseIndex = $releaseScript.IndexOf('gh release create "v$Version"')

        $verifyIndex | Should -BeGreaterThan -1
        $exitCheckIndex | Should -BeGreaterThan $verifyIndex
        $prStateIndex | Should -BeGreaterThan $exitCheckIndex
        $remoteTagIndex | Should -BeGreaterThan $prStateIndex
        $tagIndex | Should -BeGreaterThan $remoteTagIndex
        $releaseIndex | Should -BeGreaterThan $tagIndex

        $releaseScript | Should -Match 'verify failed for PR #\$prNumber'
        $releaseScript | Should -Match 'Refusing to tag or create GitHub Release'
        $releaseScript | Should -Match '\$prState\.state -ne ''MERGED'''
        $releaseScript | Should -Match 'main HEAD .* does not match release PR merge commit'
        $releaseScript | Should -Match 'Tag v\$Version already exists'
        $releaseScript | Should -Match 'Remote tag v\$Version already exists'
    }

    It 'runs verify with the same Pester discovery boundary as CI' {
        $bridgeScript = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\winsmux-core.ps1') -Raw -Encoding UTF8

        $bridgeScript | Should -Match 'New-PesterConfiguration'
        $bridgeScript | Should -Match '\$config\.Run\.Path = @\("tests/"\)'
        $bridgeScript | Should -Match '\$config\.Run\.Exit = \$true'
        $bridgeScript | Should -Match 'Invoke-Pester -Configuration \$config'
        $bridgeScript | Should -Match '-EncodedCommand \$encodedPesterCommand'
        $bridgeScript | Should -Not -Match 'Invoke-Pester -Path \(\$testFiles\.FullName\) -PassThru'
    }

    It 'checks bare PowerShell startup in doctor output' {
        $doctorScript = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-core\scripts\doctor.ps1') -Raw -Encoding UTF8

        $doctorScript | Should -Match 'PowerShell startup health'
        $doctorScript | Should -Match '-NoProfile'
        $doctorScript | Should -Match '\$PSVersionTable\.PSVersion\.ToString\(\)'
    }
}
