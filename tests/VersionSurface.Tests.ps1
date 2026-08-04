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
        $installScript | Should -Match '\$releaseAction\s*=\s*\$Action\.Trim\(\)\.ToLowerInvariant\(\)'
        $installScript | Should -Match '\$UseLatestRelease\s*=\s*\[string\]::IsNullOrWhiteSpace\(\$requestedReleaseTag\) -and \(\$releaseAction -eq ''install'' -or \$releaseAction -eq ''update''\)'
        $installScript | Should -Not -Match '\$UseLatestRelease\s*=.*\$Action\.Trim\(\)\.ToLowerInvariant\(\) -eq ''update'''
        $installScript | Should -Match '\$EffectiveReleaseTag\s*=\s*if \(\[string\]::IsNullOrWhiteSpace\(\$requestedReleaseTag\)\) \{ "v\$VERSION" \}'
        $installScript | Should -Match 'releases/latest'
        $installScript | Should -Match 'releases/tags/\$escapedTag'
        $installScript | Should -Match 'version = \$ResolvedVersion'
        $installScript | Should -Match '\$ResolvedVersion \| Set-Content \$VERSION_FILE'
        $installScript | Should -Match 'function Get-WinsmuxCommandVersion'
        $installScript | Should -Match 'does not match release version'
        $installScript | Should -Match 'Reinstalling release binary'
        $installScript | Should -Match 'SHA256SUMS asset not found in release'
        $installScript | Should -Match 'Cannot verify release asset'
        $installScript | Should -Match 'Invoke-RestMethod -Uri \$asset\.browser_download_url -Headers \$headers -OutFile \$downloadPath -ErrorAction Stop'
        $installScript | Should -Match 'Move-Item -LiteralPath \$downloadPath -Destination \$winsmuxExe -Force'
        $installScript | Should -Not -Match 'Invoke-RestMethod -Uri \$asset\.browser_download_url -Headers \$headers -OutFile \$winsmuxExe'
        $installScript | Should -Not -Match 'Skipping checksum verification'
        $bridgeScript | Should -Match ('\$VERSION\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
        $workspaceLock | Should -Match ('(?ms)^name\s*=\s*"winsmux"\s*\r?\nversion\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
        $coreManifest | Should -Match ('(?m)^version\s*=\s*"{0}"\r?$' -f [regex]::Escape($script:ProductVersion))
        $coreManifest | Should -Match '(?m)^license\s*=\s*"Apache-2\.0 AND MIT"\r?$'
        $coreManifest | Should -Match '(?m)^repository\s*=\s*"https://github\.com/Sora-bluesky/winsmux"\r?$'
        $coreLock | Should -Match ('(?ms)^name\s*=\s*"winsmux"\s*\r?\nversion\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
    }

    It 'keeps Windows PowerShell bridge script UTF-8 BOM encoded' {
        $bridgeScriptPath = Join-Path $script:RepoRoot 'scripts\winsmux-core.ps1'
        $bytes = [System.IO.File]::ReadAllBytes($bridgeScriptPath)

        $bytes.Length | Should -BeGreaterThan 3
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
    }

    It 'preserves each target file UTF-8 BOM state during version sync' {
        $releaseScript = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\bump-version.ps1') -Raw -Encoding UTF8

        $releaseScript | Should -Match 'function Write-Utf8TextPreservingBom'
        $releaseScript | Should -Match '\$hasUtf8Bom\s*='
        $releaseScript | Should -Match '\[System\.Text\.UTF8Encoding\]::new\(\$hasUtf8Bom\)'
        $releaseScript | Should -Match '\[System\.IO\.File\]::WriteAllText\(\$Path, \$Content, \$encoding\)'
        $releaseScript | Should -Not -Match 'Set-Content -Path \$t\.Path'
    }

    It 'uses latest release resolution for tagless install and update actions' {
        $installScript = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'install.ps1') -Raw -Encoding UTF8

        $installScript | Should -Match '\$releaseAction\s*=\s*\$Action\.Trim\(\)\.ToLowerInvariant\(\)'
        $installScript | Should -Match '\$UseLatestRelease\s*=\s*\[string\]::IsNullOrWhiteSpace\(\$requestedReleaseTag\) -and \(\$releaseAction -eq ''install'' -or \$releaseAction -eq ''update''\)'
        $installScript | Should -Not -Match '\$UseLatestRelease\s*=.*\$Action\.Trim\(\)\.ToLowerInvariant\(\) -eq ''update'''
        $installScript | Should -Match '\$RELEASE_API_URL = "https://api\.github\.com/repos/Sora-bluesky/winsmux/releases/latest"'
        $installScript | Should -Match '\$script:ResolvedReleaseTag = \[string\]\$release\.tag_name'
        $installScript | Should -Match '\$script:ResolvedVersion = Get-WinsmuxBinaryVersionFromReleaseTag -ReleaseTag \$script:ResolvedReleaseTag'
        $installScript | Should -Match '\$keepPipedMainScripts = \$script:releaseAction -eq ''install'' -and \$script:isPipedInstaller -and \[string\]::IsNullOrWhiteSpace\(\$script:requestedReleaseTag\)'
        $installScript | Should -Match '\$script:BASE_URL = if \(\[string\]::IsNullOrWhiteSpace\(\$script:installSourceRef\) -and -not \$keepPipedMainScripts\)'
        $installScript | Should -Match '"https://raw\.githubusercontent\.com/Sora-bluesky/winsmux/main"'
        $installScript | Should -Match '"https://raw\.githubusercontent\.com/Sora-bluesky/winsmux/\$script:ResolvedReleaseTag"'
        $installScript | Should -Match '"https://raw\.githubusercontent\.com/Sora-bluesky/winsmux/\$script:installSourceRef"'
    }

    It 'keeps desktop app metadata aligned with the product version' {
        $appPackage = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\package.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $appPackageLock = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\package-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 20
        $tauriConfig = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src-tauri\tauri.conf.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $tauriManifest = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src-tauri\Cargo.toml') -Raw -Encoding UTF8
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
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src-tauri\Cargo.lock') | Should -BeFalse
    }

    It 'allows the desktop OpenRouter model catalog endpoint through Tauri CSP' {
        $tauriConfig = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src-tauri\tauri.conf.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        $modelCapabilities = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src\modelCapabilities.ts') -Raw -Encoding UTF8

        $modelCapabilities | Should -Match 'export const openRouterModelsApiUrl = "https://openrouter\.ai/api/v1/models"'
        $tauriConfig.app.security.csp | Should -Match 'connect-src[^;]*https://openrouter\.ai'
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
        $publishIndex = $releaseCoreWorkflow.IndexOf('softprops/action-gh-release')

        $generateIndex | Should -BeGreaterThan -1
        $qualityIndex | Should -BeGreaterThan $generateIndex
        $auditIndex | Should -BeGreaterThan $qualityIndex
        $publishIndex | Should -BeGreaterThan $auditIndex
        $releaseCoreWorkflow | Should -Not -Match '-BacklogPath "tasks/backlog.yaml"'

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

    It 'T668-SMOKE-CORE binds the public Core smoke after Release upload' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        Test-Path -LiteralPath $helperPath -PathType Leaf | Should -BeTrue

        $workflow = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github\workflows\release-core.yml') -Raw -Encoding UTF8
        $publishIndex = $workflow.IndexOf('uses: softprops/action-gh-release@v3', [StringComparison]::Ordinal)
        $smokeIndex = $workflow.IndexOf('smoke-public-core:', [StringComparison]::Ordinal)
        $publishIndex | Should -BeGreaterThan -1
        $smokeIndex | Should -BeGreaterThan $publishIndex
        $smokeJob = $workflow.Substring($smokeIndex)
        $smokeJob | Should -Match '(?m)^\s+needs:\s+release\s*$'
        $smokeJob | Should -Match '(?m)^\s+runs-on:\s+windows-latest\s*$'
        $smokeJob | Should -Match '(?ms)^\s+permissions:\s*\r?\n\s+contents:\s+read\s*$'
        $smokeJob | Should -Match 'test-public-release\.ps1[^\r\n]*-Surface Core'
        $smokeJob | Should -Match '-ReleaseTag\s+"?\$\{\{\s*github\.ref_name\s*\}\}"?'
        $smokeJob | Should -Not -Match 'download-artifact|output/|target/'

        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0

        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Core -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        $selfTest.ok | Should -BeTrue
        $selfTest.surface | Should -Be 'Core'
        (@($selfTest.case_ids) -join ',') | Should -Be 'packaging_hotfix_coordinates,coordinate_mismatch,ordinary_prerelease_coordinates,core_asset_inventory,missing_arm64_checksum_entry,duplicate_arm64_checksum_entry,arm64_checksum_mismatch,valid,missing_checksum_entry,duplicate_checksum_entry,checksum_mismatch,version_mismatch,temp_cleanup'
    }

    It 'T668-SMOKE-CORE-ASSET-INVENTORY requires both public Core executables' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8
        $helper | Should -Match 'function Get-CoreReleaseAssetNames'

        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Core -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'core_asset_inventory'
    }

    It 'T668-SMOKE-CORE-ARM64-MISSING rejects a missing ARM64 checksum entry' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Core -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'missing_arm64_checksum_entry'
    }

    It 'T668-SMOKE-CORE-ARM64-DUPLICATE rejects duplicate ARM64 checksum entries' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Core -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'duplicate_arm64_checksum_entry'
    }

    It 'T668-SMOKE-CORE-ARM64-MISMATCH rejects mismatched ARM64 public bytes' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Core -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'arm64_checksum_mismatch'
    }

    It 'T668-SMOKE-DESKTOP binds the public Desktop smoke after Release upload' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        Test-Path -LiteralPath $helperPath -PathType Leaf | Should -BeTrue

        $workflow = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github\workflows\release-desktop.yml') -Raw -Encoding UTF8
        $publishIndex = $workflow.IndexOf('Upload desktop bundles to release', [StringComparison]::Ordinal)
        $smokeIndex = $workflow.IndexOf('smoke-public-desktop:', [StringComparison]::Ordinal)
        $publishIndex | Should -BeGreaterThan -1
        $smokeIndex | Should -BeGreaterThan $publishIndex
        $smokeJob = $workflow.Substring($smokeIndex)
        $smokeJob | Should -Match '(?m)^\s+needs:\s+build\s*$'
        $smokeJob | Should -Match '(?m)^\s+if:\s+github\.event_name == ''push''\s*$'
        $smokeJob | Should -Match '(?m)^\s+runs-on:\s+windows-latest\s*$'
        $smokeJob | Should -Match '(?ms)^\s+permissions:\s*\r?\n\s+contents:\s+read\s*$'
        $smokeJob | Should -Match 'test-public-release\.ps1[^\r\n]*-Surface Desktop'
        $smokeJob | Should -Not -Match 'download-artifact|output/|target/'

        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        $selfTest.ok | Should -BeTrue
        $selfTest.surface | Should -Be 'Desktop'
        (@($selfTest.case_ids) -join ',') | Should -Be 'packaging_hotfix_coordinates,coordinate_mismatch,ordinary_prerelease_coordinates,product_version_exact,product_version_suffix_rejected,product_version_padding_rejected,preexisting_folder_context,preexisting_background_context,preexisting_product_state,owned_product_state_cleanup,preexisting_uninstall_registration,desktop_install_location_unquoted,desktop_install_location_outer_quoted,desktop_install_location_malformed,desktop_install_location_foreign,uninstall_registration_residue,preexisting_desktop_shortcut,preexisting_start_menu_shortcut,preexisting_process,preexisting_install_root,desktop_uninstall_argv_order,desktop_uninstall_foreign_path,desktop_lifecycle_ownership_reject_preserves_state,desktop_lifecycle_stop_failure_preserves_state,desktop_lifecycle_uninstall_failure_preserves_state,desktop_lifecycle_registration_remains_preserves_state,desktop_lifecycle_success_orders_cleanup,desktop_lifecycle_residue_failure_blocks_root_cleanup,process_diagnostics_metadata_only,desktop_observer_states,desktop_observation_cleanup_aggregate,install_root_residue,production_page_url,checksum_mismatch,nonproduction_url,desktop_cdp_probe_taxonomy,desktop_typed_observation_authority,desktop_typed_observation_fail_closed,desktop_owned_capture_bounded,desktop_unexpected_probe_failure,desktop_teardown_diagnosis_keys,desktop_teardown_diagnosis_budget,desktop_teardown_diagnosis_privacy'
    }

    It 'T668-SMOKE-NPM binds the public npm smoke after registry publish' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        Test-Path -LiteralPath $helperPath -PathType Leaf | Should -BeTrue

        $workflow = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github\workflows\release-npm.yml') -Raw -Encoding UTF8
        $publishIndex = $workflow.IndexOf('name: Publish to npm', [StringComparison]::Ordinal)
        $smokeIndex = $workflow.IndexOf('smoke-public-npm:', [StringComparison]::Ordinal)
        $publishIndex | Should -BeGreaterThan -1
        $smokeIndex | Should -BeGreaterThan $publishIndex
        $smokeJob = $workflow.Substring($smokeIndex)
        $smokeJob | Should -Match '(?m)^\s+needs:\s+\[verify, publish\]\s*$'
        $smokeJob | Should -Match 'needs\.verify\.outputs\.publish_ready == ''true'''
        $smokeJob | Should -Match 'needs\.publish\.result == ''success'''
        $smokeJob | Should -Match '(?m)^\s+runs-on:\s+windows-latest\s*$'
        $smokeJob | Should -Match '(?ms)^\s+permissions:\s*\r?\n\s+contents:\s+read\s*$'
        $smokeJob | Should -Match 'test-public-release\.ps1[^\r\n]*-Surface Npm'
        $smokeJob | Should -Not -Match 'download-artifact|output/npm-release'

        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Npm -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        $selfTest.ok | Should -BeTrue
        $selfTest.surface | Should -Be 'Npm'
        (@($selfTest.case_ids) -join ',') | Should -Be 'packaging_hotfix_coordinates,coordinate_mismatch,ordinary_prerelease_coordinates,reserved_pkgfix_namespace,node_path_precedence_zero,node_path_precedence_one,node_path_precedence_multiple,node_path_precedence_invalid_first,npm_complete_toolchain_consumed,npm_incomplete_toolchain_no_effects,valid,missing_integrity,version_mismatch,help_failure,temp_cleanup,npm_default_real_scope'
    }

    It 'T826-NPM-RT-01 executes the default npm child-process route in real PowerShell scope' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Npm -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'npm_default_real_scope'

        $evidence = $selfTest.evidence.npm_default_real_scope
        @($evidence.PSObject.Properties.Name | Sort-Object) | Should -Be @('child_exit_code', 'child_started', 'default_dispatcher', 'operation', 'raw_output_excluded', 'sibling_operations')
        $evidence.child_exit_code.GetType().FullName | Should -Be 'System.Int64'
        foreach ($property in @('child_started', 'default_dispatcher', 'raw_output_excluded')) {
            $evidence.$property.GetType().FullName | Should -Be 'System.Boolean'
        }
        $evidence.operation.GetType().FullName | Should -Be 'System.String'
        ($evidence.sibling_operations -is [System.Array]) | Should -BeTrue
        @($evidence.sibling_operations | ForEach-Object { $_.GetType().FullName }) | Should -Be @('System.String', 'System.String', 'System.String', 'System.String', 'System.String')
        $evidence.child_started | Should -BeTrue
        $evidence.child_exit_code | Should -Be 0
        $evidence.default_dispatcher | Should -BeTrue
        $evidence.operation | Should -Be 'npm_view'
        $evidence.raw_output_excluded | Should -BeTrue
        @($evidence.sibling_operations) | Should -Be @('npm_view', 'npm_pack', 'tar_list', 'tar_extract', 'npm_help')
    }

    It 'T826-DESKTOP-CDP-01 preserves the finite CDP probe taxonomy through the real HTTP boundary' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $acceptedUrlMarker = 'T826_CDP_ACCEPTED_SUFFIX_MARKER'
        $acceptedPageUrl = "tauri://localhost/$acceptedUrlMarker`?probe=$acceptedUrlMarker#$acceptedUrlMarker"
        $helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8
        $helper | Should -Match ([regex]::Escape($acceptedPageUrl))

        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTestJson = $selfTestOutput -join "`n"
        $selfTest = $selfTestJson | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'desktop_cdp_probe_taxonomy'

        $evidence = $selfTest.evidence.desktop_cdp_probe_taxonomy
        @($evidence.PSObject.Properties.Name | Sort-Object) | Should -Be @('real_http_boundary', 'records')
        $evidence.real_http_boundary.GetType().FullName | Should -Be 'System.Boolean'
        $evidence.real_http_boundary | Should -BeTrue
        ($evidence.records -is [System.Object[]]) | Should -BeTrue
        $expectedRecords = @(
            @{ probe_state = 'transport_unavailable'; public_state = 'live_cdp_transport_unavailable' },
            @{ probe_state = 'http_error'; public_state = 'live_cdp_http_error' },
            @{ probe_state = 'payload_invalid'; public_state = 'live_cdp_payload_invalid' },
            @{ probe_state = 'page_absent'; public_state = 'live_cdp_page_absent' },
            @{ probe_state = 'url_rejected'; public_state = 'live_cdp_url_rejected' },
            @{ probe_state = 'page_ready'; public_state = 'page_ready' }
        )
        @($evidence.records).Count | Should -Be $expectedRecords.Count
        for ($index = 0; $index -lt $expectedRecords.Count; $index++) {
            $record = $evidence.records[$index]
            $expected = $expectedRecords[$index]
            @($record.PSObject.Properties.Name | Sort-Object) | Should -Be @('probe_state', 'public_state', 'raw_body_absent', 'raw_url_absent')
            foreach ($property in @('probe_state', 'public_state')) {
                $record.$property.GetType().FullName | Should -Be 'System.String'
            }
            foreach ($property in @('raw_body_absent', 'raw_url_absent')) {
                $record.$property.GetType().FullName | Should -Be 'System.Boolean'
                $record.$property | Should -BeTrue
            }
            $record.probe_state | Should -Be $expected.probe_state
            $record.public_state | Should -Be $expected.public_state
        }
        $pageReadyRecords = @($selfTest.evidence.desktop_observer.records | Where-Object { [string]$_.state -ceq 'page_ready' })
        $pageReadyRecords.Count | Should -Be 1
        $pageReadyRecords[0].page_url.GetType().FullName | Should -Be 'System.String'
        $pageReadyRecords[0].page_url | Should -Be 'tauri://localhost/'
        $selfTestJson | Should -Not -Match ([regex]::Escape($acceptedUrlMarker))
    }

    It 'T826-DESKTOP-EX-01 does not flatten an unexpected probe failure into CDP not-ready' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'desktop_unexpected_probe_failure'

        $evidence = $selfTest.evidence.desktop_unexpected_probe_failure
        @($evidence.PSObject.Properties.Name | Sort-Object) | Should -Be @('cleanup_count', 'failed', 'flattened', 'public_marker_absent')
        $evidence.cleanup_count.GetType().FullName | Should -Be 'System.Int64'
        foreach ($property in @('failed', 'flattened', 'public_marker_absent')) {
            $evidence.$property.GetType().FullName | Should -Be 'System.Boolean'
        }
        $evidence.cleanup_count | Should -Be 1
        $evidence.failed | Should -BeTrue
        $evidence.flattened | Should -BeFalse
        $evidence.public_marker_absent | Should -BeTrue
    }

    It 'T831-DESKTOP-AUTH-01 binds the run-owned WebView endpoint through one typed authority' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTestJson = $selfTestOutput -join "`n"
        $selfTest = $selfTestJson | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'desktop_typed_observation_authority'

        $evidence = $selfTest.evidence.desktop_typed_observation_authority
        @($evidence.PSObject.Properties.Name | Sort-Object) | Should -Be @(
            'browser_process_identity',
            'debug_port_zero',
            'listener_loopback',
            'listener_owner_identity',
            'page_url',
            'port_file_identity',
            'raw_absent',
            'root_descendant',
            'user_data_identity',
            'version_browser_path_identity'
        )
        foreach ($property in @(
            'browser_process_identity',
            'debug_port_zero',
            'listener_loopback',
            'listener_owner_identity',
            'port_file_identity',
            'raw_absent',
            'root_descendant',
            'user_data_identity',
            'version_browser_path_identity'
        )) {
            $evidence.$property.GetType().FullName | Should -Be 'System.Boolean'
            $evidence.$property | Should -BeTrue
        }
        $evidence.page_url.GetType().FullName | Should -Be 'System.String'
        $evidence.page_url | Should -Be 'tauri://localhost/'
        $selfTestJson | Should -Not -Match 'DevToolsActivePort|msedgewebview2|--remote-debugging-port|/devtools/browser/|listener_owner_pid|root_pid|browser_pid'
    }

    It 'T831-DESKTOP-REJECT-01 rejects every unowned or malformed WebView authority without raw disclosure' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTestJson = $selfTestOutput -join "`n"
        $selfTest = $selfTestJson | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'desktop_typed_observation_fail_closed'

        $evidence = $selfTest.evidence.desktop_typed_observation_fail_closed
        @($evidence.PSObject.Properties.Name | Sort-Object) | Should -Be @('http_requests_before_authority', 'records')
        $evidence.http_requests_before_authority.GetType().FullName | Should -Be 'System.Int64'
        $evidence.http_requests_before_authority | Should -Be 0
        ($evidence.records -is [System.Object[]]) | Should -BeTrue
        $expectedStates = @(
            'user_data_reparse',
            'port_file_missing',
            'port_file_reparse',
            'port_file_invalid_encoding',
            'port_file_invalid_shape',
            'port_invalid',
            'browser_path_invalid',
            'listener_missing',
            'listener_ambiguous',
            'listener_foreign',
            'browser_identity_invalid',
            'version_identity_mismatch'
        )
        @($evidence.records).Count | Should -Be $expectedStates.Count
        @($evidence.records | ForEach-Object { [string]$_.state }) | Should -Be $expectedStates
        foreach ($record in @($evidence.records)) {
            @($record.PSObject.Properties.Name | Sort-Object) | Should -Be @('protected_state_unchanged', 'raw_absent', 'state')
            $record.state.GetType().FullName | Should -Be 'System.String'
            foreach ($property in @('protected_state_unchanged', 'raw_absent')) {
                $record.$property.GetType().FullName | Should -Be 'System.Boolean'
                $record.$property | Should -BeTrue
            }
        }
        $selfTestJson | Should -Not -Match 'DevToolsActivePort|msedgewebview2|--remote-debugging-port|/devtools/browser/|listener_owner_pid|root_pid|browser_pid'
    }

    It 'T831-DESKTOP-CAPTURE-01 bounds owned Desktop output before diagnostic projection' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTestJson = $selfTestOutput -join "`n"
        $selfTest = $selfTestJson | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'desktop_owned_capture_bounded'

        $evidence = $selfTest.evidence.desktop_owned_capture_bounded
        @($evidence.PSObject.Properties.Name | Sort-Object) | Should -Be @('limit_bytes', 'raw_absent', 'records')
        $evidence.limit_bytes.GetType().FullName | Should -Be 'System.Int64'
        $evidence.raw_absent.GetType().FullName | Should -Be 'System.Boolean'
        $evidence.limit_bytes | Should -Be 16384
        $evidence.raw_absent | Should -BeTrue
        ($evidence.records -is [System.Object[]]) | Should -BeTrue
        $expected = @(
            @{ stream = 'stdout'; scenario = 'zero'; total_bytes = 0; retained_bytes = 0; truncated = $false },
            @{ stream = 'stderr'; scenario = 'zero'; total_bytes = 0; retained_bytes = 0; truncated = $false },
            @{ stream = 'stdout'; scenario = 'limit'; total_bytes = 16384; retained_bytes = 16384; truncated = $false },
            @{ stream = 'stdout'; scenario = 'over_limit'; total_bytes = 16385; retained_bytes = 16384; truncated = $true },
            @{ stream = 'stderr'; scenario = 'limit'; total_bytes = 16384; retained_bytes = 16384; truncated = $false },
            @{ stream = 'stderr'; scenario = 'over_limit'; total_bytes = 16385; retained_bytes = 16384; truncated = $true }
        )
        @($evidence.records).Count | Should -Be $expected.Count
        for ($index = 0; $index -lt $expected.Count; $index++) {
            $record = $evidence.records[$index]
            $expectedRecord = $expected[$index]
            @($record.PSObject.Properties.Name | Sort-Object) | Should -Be @('retained_bytes', 'scenario', 'stream', 'terminal', 'total_bytes', 'truncated')
            foreach ($property in @('scenario', 'stream')) {
                $record.$property.GetType().FullName | Should -Be 'System.String'
                $record.$property | Should -Be $expectedRecord[$property]
            }
            foreach ($property in @('retained_bytes', 'total_bytes')) {
                $record.$property.GetType().FullName | Should -Be 'System.Int64'
                $record.$property | Should -Be $expectedRecord[$property]
            }
            foreach ($property in @('terminal', 'truncated')) {
                $record.$property.GetType().FullName | Should -Be 'System.Boolean'
            }
            $record.terminal | Should -BeTrue
            $record.truncated | Should -Be $expectedRecord.truncated
        }
        $selfTestJson | Should -Not -Match '[xy]{64}'
    }

    It 'T825-NPM-01 resolves the complete npm toolchain before effects' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Npm -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTestJson = $selfTestOutput -join "`n"
        $selfTest = $selfTestJson | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'npm_complete_toolchain_consumed'

        $evidence = $selfTest.evidence.npm_complete_toolchain
        @($evidence.PSObject.Properties.Name | Sort-Object) | Should -Be @('npm_adjacent', 'operation_order', 'same_tar_for_list_extract', 'selected_node_index', 'selected_tar_index')
        $evidence.selected_node_index.GetType().FullName | Should -Be 'System.Int64'
        $evidence.selected_tar_index.GetType().FullName | Should -Be 'System.Int64'
        $evidence.npm_adjacent.GetType().FullName | Should -Be 'System.Boolean'
        $evidence.same_tar_for_list_extract.GetType().FullName | Should -Be 'System.Boolean'
        $evidence.selected_node_index | Should -Be 0
        $evidence.selected_tar_index | Should -Be 0
        $evidence.npm_adjacent | Should -BeTrue
        $evidence.same_tar_for_list_extract | Should -BeTrue
        @($evidence.operation_order) | Should -Be @('npm_view', 'npm_pack', 'tar_list', 'tar_extract', 'npm_help')
        $selfTestJson | Should -Not -Match 'T825_'

        $helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8
        $helper | Should -Match 'function Resolve-NpmPathPrecedenceToolchain'
        $helper | Should -Match '\$nodeCandidates\s*=\s*@\(Get-Command node\.exe -CommandType Application'
        $helper | Should -Match '\$tarCandidates\s*=\s*@\(Get-Command tar\.exe -CommandType Application'
        $helper | Should -Match 'Resolve-NpmPathPrecedenceToolchain\s+-NodeCandidates\s+\$nodeCandidates\s+-TarCandidates\s+\$tarCandidates'
        $helper | Should -Match '(?s)Resolve-NpmPathPrecedenceToolchain.*?New-Item'
        $helper | Should -Match '\.tar_path\s+-tf\s+'
        $helper | Should -Match '\.tar_path\s+-xf\s+'
    }

    It 'T825-NPM-02 rejects an incomplete npm toolchain before effects' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Npm -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTestJson = $selfTestOutput -join "`n"
        $selfTest = $selfTestJson | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'npm_incomplete_toolchain_no_effects'

        $cases = @($selfTest.evidence.npm_incomplete_toolchain.cases)
        $cases.Count | Should -Be 5
        @($cases | ForEach-Object { $_.name }) | Should -Be @('missing_node', 'invalid_first_node', 'missing_adjacent_npm', 'missing_tar', 'invalid_first_tar')
        foreach ($case in $cases) {
            @($case.PSObject.Properties.Name | Sort-Object) | Should -Be @('name', 'process_operations', 'root_unchanged')
            $case.name.GetType().FullName | Should -Be 'System.String'
            $case.root_unchanged.GetType().FullName | Should -Be 'System.Boolean'
            $case.process_operations.GetType().FullName | Should -Be 'System.Int64'
            $case.root_unchanged | Should -BeTrue
            $case.process_operations | Should -Be 0
        }
        $selfTestJson | Should -Not -Match 'T825_'

        $helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8
        $helper | Should -Match 'function Resolve-NpmPathPrecedenceToolchain'
        $helper | Should -Match 'Resolve-NpmPathPrecedenceToolchain\s+-NodeCandidates\s+\$nodeCandidates\s+-TarCandidates\s+\$tarCandidates'
        $helper | Should -Match '(?s)Invoke-NpmSmoke.*?Resolve-NpmPathPrecedenceToolchain.*?New-Item'
        $helper | Should -Match '\$candidates\[0\]\.Source'
        $helper | Should -Match '\$tarCandidates\[0\]\.Source'
    }

    It 'T825-DIAG-01 keeps child output content out of public diagnostics' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTestJson = $selfTestOutput -join "`n"
        $selfTest = $selfTestJson | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'process_diagnostics_metadata_only'

        $diagnostics = @($selfTest.evidence.process_diagnostics.records)
        $expectedDiagnostics = @(
            @{ operation = 'core_version'; state = 'stderr_nonempty'; exit_code = 0; stdout_present = $true; stdout_bytes = 13; stdout_truncated = $false; stderr_present = $true; stderr_bytes = 13; stderr_truncated = $false },
            @{ operation = 'npm_view'; state = 'parse_failed'; exit_code = 0; stdout_present = $true; stdout_bytes = 17; stdout_truncated = $false; stderr_present = $false; stderr_bytes = 0; stderr_truncated = $false },
            @{ operation = 'npm_pack'; state = 'parse_failed'; exit_code = 0; stdout_present = $true; stdout_bytes = 17; stdout_truncated = $false; stderr_present = $false; stderr_bytes = 0; stderr_truncated = $false },
            @{ operation = 'tar_list'; state = 'content_invalid'; exit_code = 0; stdout_present = $true; stdout_bytes = 17; stdout_truncated = $false; stderr_present = $false; stderr_bytes = 0; stderr_truncated = $false },
            @{ operation = 'tar_extract'; state = 'exit_nonzero'; exit_code = 23; stdout_present = $false; stdout_bytes = 0; stdout_truncated = $false; stderr_present = $true; stderr_bytes = 20; stderr_truncated = $false },
            @{ operation = 'npm_help'; state = 'content_invalid'; exit_code = 0; stdout_present = $true; stdout_bytes = 17; stdout_truncated = $false; stderr_present = $false; stderr_bytes = 0; stderr_truncated = $false },
            @{ operation = 'desktop_installer'; state = 'exit_nonzero'; exit_code = 23; stdout_present = $false; stdout_bytes = 0; stdout_truncated = $false; stderr_present = $true; stderr_bytes = 26; stderr_truncated = $false },
            @{ operation = 'desktop_observer'; state = 'exited'; exit_code = 23; stdout_present = $true; stdout_bytes = 25; stdout_truncated = $false; stderr_present = $true; stderr_bytes = 25; stderr_truncated = $false },
            @{ operation = 'desktop_uninstaller'; state = 'exit_nonzero'; exit_code = 23; stdout_present = $false; stdout_bytes = 0; stdout_truncated = $false; stderr_present = $true; stderr_bytes = 16413; stderr_truncated = $true }
        )
        $diagnostics.Count | Should -Be $expectedDiagnostics.Count
        for ($index = 0; $index -lt $expectedDiagnostics.Count; $index++) {
            $record = $diagnostics[$index]
            $expected = $expectedDiagnostics[$index]
            @($record.PSObject.Properties.Name | Sort-Object) | Should -Be @('digest_absent', 'exit_code', 'formatted_once', 'marker_absent', 'operation', 'state', 'stderr_bytes', 'stderr_present', 'stderr_truncated', 'stdout_bytes', 'stdout_present', 'stdout_truncated')
            $record.operation.GetType().FullName | Should -Be 'System.String'
            $record.state.GetType().FullName | Should -Be 'System.String'
            $record.exit_code.GetType().FullName | Should -Be 'System.Int64'
            foreach ($property in @('marker_absent', 'digest_absent', 'formatted_once', 'stdout_present', 'stdout_truncated', 'stderr_present', 'stderr_truncated')) {
                $record.$property.GetType().FullName | Should -Be 'System.Boolean'
            }
            foreach ($property in @('stdout_bytes', 'stderr_bytes')) {
                $record.$property.GetType().FullName | Should -Be 'System.Int64'
            }
            $record.marker_absent | Should -BeTrue
            $record.digest_absent | Should -BeTrue
            $record.formatted_once | Should -BeTrue
            foreach ($property in @('operation', 'state', 'exit_code', 'stdout_present', 'stdout_bytes', 'stdout_truncated', 'stderr_present', 'stderr_bytes', 'stderr_truncated')) {
                $record.$property | Should -Be $expected[$property]
            }
        }
        foreach ($property in @('public_error_marker_absent', 'self_test_json_marker_absent', 'block_error_marker_absent')) {
            $selfTest.evidence.process_diagnostics.$property.GetType().FullName | Should -Be 'System.Boolean'
            $selfTest.evidence.process_diagnostics.$property | Should -BeTrue
        }
        $selfTestJson | Should -Not -Match 'T825_(CORE|NPM|TAR|DESKTOP)'

        $helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8
        (@([regex]::Matches($helper, 'function Format-PublicChildProcessDiagnostic'))).Count | Should -Be 1
        foreach ($operation in @('core_version', 'npm_view', 'npm_pack', 'tar_list', 'tar_extract', 'npm_help', 'desktop_installer', 'desktop_observer', 'desktop_uninstaller')) {
            $helper | Should -Match ([regex]::Escape("-Operation '$operation'"))
        }
        $helper | Should -Not -Match '(?im)^\s*throw\s+[^\r\n]*(\.stdout|\.stderr)'

        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true))
        $publicProcessOwner = @($functions | Where-Object Name -CEQ 'Invoke-PublicChildProcess')
        $desktopLifecycleOwner = @($functions | Where-Object Name -CEQ 'Invoke-DesktopLifecycleOperation')
        $publicProcessOwner.Count | Should -Be 1
        $desktopLifecycleOwner.Count | Should -Be 1
        $nativeCalls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Invoke-NativeProcess'
        }, $true))
        $publicCalls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Invoke-PublicChildProcess'
        }, $true))
        $nativeCalls.Count | Should -Be 2
        $publicCalls.Count | Should -Be 4
        $publicProcessOwner[0].Extent.Text | Should -Match "Data\['process_result'\]"
        $publicProcessOwner[0].Extent.Text | Should -Match "-State 'timed_out'"
        $desktopOwnerText = $desktopLifecycleOwner[0].Extent.Text
        $cleanupIndex = $desktopOwnerText.IndexOf('Invoke-DesktopCleanup', [StringComparison]::Ordinal)
        $captureIndex = $desktopOwnerText.IndexOf('Set-DesktopObservationCaptureMetadata', [StringComparison]::Ordinal)
        $formatIndex = $desktopOwnerText.IndexOf('Format-PublicChildProcessDiagnostic', [StringComparison]::Ordinal)
        $cleanupIndex | Should -BeGreaterThan -1
        $captureIndex | Should -BeGreaterThan $cleanupIndex
        $formatIndex | Should -BeGreaterThan $captureIndex
    }

    It 'T825-DESKTOP-01 distinguishes exited live and page states' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $acceptedUrlMarker = 'T825_DESKTOP_ACCEPTED_SUFFIX_MARKER'
        $helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8
        $helper | Should -Match ([regex]::Escape('$injectedAcceptedUrlMarker = ''T825_DESKTOP_ACCEPTED_SUFFIX_MARKER'''))
        $helper | Should -Match ([regex]::Escape('$injectedAcceptedPageUrl = "tauri://localhost/$injectedAcceptedUrlMarker`?probe=$injectedAcceptedUrlMarker#$injectedAcceptedUrlMarker"'))

        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTestJson = $selfTestOutput -join "`n"
        $selfTest = $selfTestJson | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'desktop_observer_states'

        $records = @($selfTest.evidence.desktop_observer.records)
        $expectedRecords = @(
            @{ state = 'exited'; is_live = $false; has_exited = $true; exit_code = 23; port = 48251; page_present = $false; page_url = $null; attempts = 1; stdout_present = $true; stdout_bytes = 25; stdout_truncated = $false; stderr_present = $true; stderr_bytes = 25; stderr_truncated = $false },
            @{ state = 'live_no_cdp'; is_live = $true; has_exited = $false; exit_code = $null; port = 48252; page_present = $false; page_url = $null; attempts = 2; stdout_present = $false; stdout_bytes = 0; stdout_truncated = $false; stderr_present = $false; stderr_bytes = 0; stderr_truncated = $false },
            @{ state = 'page_ready'; is_live = $true; has_exited = $false; exit_code = $null; port = 48253; page_present = $true; page_url = 'tauri://localhost/'; attempts = 1; stdout_present = $false; stdout_bytes = 0; stdout_truncated = $false; stderr_present = $false; stderr_bytes = 0; stderr_truncated = $false }
        )
        $records.Count | Should -Be $expectedRecords.Count
        for ($index = 0; $index -lt $expectedRecords.Count; $index++) {
            $record = $records[$index]
            $expected = $expectedRecords[$index]
            @($record.PSObject.Properties.Name | Sort-Object) | Should -Be @('attempts', 'exit_code', 'has_exited', 'is_live', 'page_present', 'page_url', 'port', 'state', 'stderr_bytes', 'stderr_present', 'stderr_truncated', 'stdout_bytes', 'stdout_present', 'stdout_truncated')
            $record.state.GetType().FullName | Should -Be 'System.String'
            foreach ($property in @('is_live', 'has_exited', 'page_present', 'stdout_present', 'stdout_truncated', 'stderr_present', 'stderr_truncated')) {
                $record.$property.GetType().FullName | Should -Be 'System.Boolean'
            }
            foreach ($property in @('port', 'attempts', 'stdout_bytes', 'stderr_bytes')) {
                $record.$property.GetType().FullName | Should -Be 'System.Int64'
            }
            if ($null -eq $expected.exit_code) {
                $record.exit_code | Should -Be $null
            } else {
                $record.exit_code.GetType().FullName | Should -Be 'System.Int64'
                $record.exit_code | Should -Be $expected.exit_code
            }
            if ($null -eq $expected.page_url) {
                $record.page_url | Should -Be $null
            } else {
                $record.page_url.GetType().FullName | Should -Be 'System.String'
                $record.page_url | Should -Be $expected.page_url
            }
            foreach ($property in @('state', 'is_live', 'has_exited', 'port', 'page_present', 'attempts', 'stdout_present', 'stdout_bytes', 'stdout_truncated', 'stderr_present', 'stderr_bytes', 'stderr_truncated')) {
                $record.$property | Should -Be $expected[$property]
            }
        }
        $pageReadyRecords = @($records | Where-Object { [string]$_.state -ceq 'page_ready' })
        $pageReadyRecords.Count | Should -Be 1
        $pageReadyRecords[0].page_url | Should -Be 'tauri://localhost/'
        $selfTestJson | Should -Not -Match ([regex]::Escape($acceptedUrlMarker))
        $selfTest.evidence.desktop_observer.post_probe_exit_wins.GetType().FullName | Should -Be 'System.Boolean'
        $selfTest.evidence.desktop_observer.post_probe_exit_wins | Should -BeTrue
        $selfTestJson | Should -Not -Match 'T825_'

        $helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8
        $helper | Should -Match 'function Start-OwnedProcess'
        $helper | Should -Match 'function Wait-DesktopProcessObservation'
        $helper | Should -Match 'function Invoke-DesktopLifecycleOperation'
        $helper | Should -Match '(?s)function Invoke-DesktopLifecycleOperation.*?Wait-DesktopProcessObservation'
        $helper | Should -Match '(?s)function Invoke-DesktopSmoke.*?Invoke-DesktopLifecycleOperation'
    }

    It 'T825-DESKTOP-02 preserves observation and cleanup failures through the lifecycle owner' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTestJson = $selfTestOutput -join "`n"
        $selfTest = $selfTestJson | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'desktop_observation_cleanup_aggregate'

        $lifecycle = $selfTest.evidence.desktop_lifecycle
        @($lifecycle.PSObject.Properties.Name | Sort-Object) | Should -Be @('cleanup_invocations', 'cleanup_only', 'dual', 'operation_only', 'owner_invocations', 'success')
        $lifecycle.owner_invocations.GetType().FullName | Should -Be 'System.Int64'
        $lifecycle.cleanup_invocations.GetType().FullName | Should -Be 'System.Int64'
        $lifecycle.owner_invocations | Should -Be 4
        $lifecycle.cleanup_invocations | Should -Be 4
        @($lifecycle.success.PSObject.Properties.Name | Sort-Object) | Should -Be @('result_returned', 'terminal_phase')
        $lifecycle.success.result_returned.GetType().FullName | Should -Be 'System.Boolean'
        $lifecycle.success.terminal_phase.GetType().FullName | Should -Be 'System.String'
        $lifecycle.success.result_returned | Should -BeTrue
        $lifecycle.success.terminal_phase | Should -Be 'clean'
        foreach ($name in @('operation_only', 'cleanup_only')) {
            $record = $lifecycle.$name
            @($record.PSObject.Properties.Name | Sort-Object) | Should -Be @('exception_role', 'reference_identity', 'terminal_phase')
            $record.exception_role.GetType().FullName | Should -Be 'System.String'
            $record.reference_identity.GetType().FullName | Should -Be 'System.Boolean'
            $record.terminal_phase.GetType().FullName | Should -Be 'System.String'
            $record.reference_identity | Should -BeTrue
        }
        $lifecycle.operation_only.exception_role | Should -Be 'observer'
        $lifecycle.operation_only.terminal_phase | Should -Be 'clean'
        $lifecycle.cleanup_only.exception_role | Should -Be 'cleanup'
        $lifecycle.cleanup_only.terminal_phase | Should -Be 'preserve'
        @($lifecycle.dual.PSObject.Properties.Name | Sort-Object) | Should -Be @('aggregate_type', 'inner_count', 'inner_roles', 'reference_identity', 'terminal_phase')
        $lifecycle.dual.aggregate_type.GetType().FullName | Should -Be 'System.String'
        $lifecycle.dual.inner_count.GetType().FullName | Should -Be 'System.Int64'
        $lifecycle.dual.terminal_phase.GetType().FullName | Should -Be 'System.String'
        $lifecycle.dual.aggregate_type | Should -Be 'System.AggregateException'
        $lifecycle.dual.inner_count | Should -Be 2
        @($lifecycle.dual.inner_roles) | Should -Be @('observer', 'cleanup')
        @($lifecycle.dual.reference_identity) | Should -Be @($true, $true)
        $lifecycle.dual.terminal_phase | Should -Be 'preserve'
        $selfTestJson | Should -Not -Match 'T825_'

        $helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8
        $helper | Should -Match 'function Invoke-DesktopLifecycleOperation'
        $helper | Should -Match '(?s)function Invoke-DesktopLifecycleOperation.*?Invoke-DesktopCleanup'
        $helper | Should -Match '(?s)function Invoke-DesktopLifecycleOperation.*?System\.AggregateException'
        $helper | Should -Match '(?s)function Invoke-DesktopSmoke.*?Invoke-DesktopLifecycleOperation'
    }

    It 'IR668-NODE-01 selects one PATH-precedence Node and couples npm without lower fallback' {
        $helper = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\test-public-release.ps1') -Raw -Encoding UTF8

        $helper | Should -Match 'function Resolve-NpmPathPrecedenceToolchain'
        $helper | Should -Match '\$nodeCandidates = @\(Get-Command node\.exe -CommandType Application'
        $helper | Should -Match '\$nodePath = \[string\]\$candidates\[0\]\.Source'
        $helper | Should -Match 'npm CLI was not found next to the first PATH-precedence Node application'
        foreach ($caseId in @('node_path_precedence_zero', 'node_path_precedence_one', 'node_path_precedence_multiple', 'node_path_precedence_invalid_first')) {
            $helper | Should -Match ([regex]::Escape($caseId))
        }
    }

    It 'IR668-DESKTOP-PATH-01 accepts only exact Tauri outer-quoted InstallLocation ownership' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8

        $helper | Should -Match 'function Get-ExactDesktopInstallLocation'
        $helper | Should -Match 'Get-ExactDesktopInstallLocation -InstallLocation \$installLocation -ExpectedInstallRoot \$ExpectedInstallRoot'
        foreach ($caseId in @('desktop_install_location_unquoted', 'desktop_install_location_outer_quoted', 'desktop_install_location_malformed', 'desktop_install_location_foreign')) {
            $helper | Should -Match ([regex]::Escape($caseId))
        }
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'desktop_lifecycle_ownership_reject_preserves_state'
    }

    It 'IR668-DESKTOP-UNINSTALL-01 waits for the run-owned NSIS uninstaller before cleanup' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8

        $helper | Should -Match 'function Invoke-VerifiedDesktopUninstaller'
        $helper | Should -Match 'function Invoke-DesktopCleanup'
        $helper | Should -Match ([regex]::Escape('desktop_uninstall_argv_order'))
        $helper | Should -Match ([regex]::Escape('_?=$installRoot'))
        $helper | Should -Match 'Invoke-VerifiedDesktopUninstaller -Context \$Context -Environment \$Environment'
        $helper | Should -Not -Match 'DesktopCleanupAuthorized|-AfterFailure'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        foreach ($caseId in @(
            'desktop_lifecycle_stop_failure_preserves_state',
            'desktop_lifecycle_uninstall_failure_preserves_state',
            'desktop_lifecycle_registration_remains_preserves_state',
            'desktop_lifecycle_success_orders_cleanup',
            'desktop_lifecycle_residue_failure_blocks_root_cleanup'
        )) {
            @($selfTest.case_ids) | Should -Contain $caseId
        }
    }

    It 'IR668-RECOVERY-WORKFLOW-01 runs a main-bound read-only three-surface recovery receipt' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github\workflows\public-smoke-recovery.yml') -Raw -Encoding UTF8

        $workflow | Should -Match '(?ms)^on:\s*\r?\n\s+workflow_dispatch:'
        $workflow | Should -Not -Match '(?m)^\s+(push|pull_request|schedule):'
        $workflow | Should -Match '(?ms)^permissions:\s*\r?\n\s+contents:\s+read\s*$'
        $workflow | Should -Not -Match '(?i)secrets\.|npm publish|softprops/action-gh-release|git (push|tag)|actions/upload-artifact'
        (@([regex]::Matches($workflow, 'actions/checkout@v6'))).Count | Should -Be 1
        (@([regex]::Matches($workflow, 'ref:\s+\$\{\{ github\.sha \}\}'))).Count | Should -Be 1
        (@([regex]::Matches($workflow, 'persist-credentials:\s+false'))).Count | Should -Be 1
        (@([regex]::Matches($workflow, 'actions/setup-node@v6'))).Count | Should -Be 1
        $workflow | Should -Match "if: matrix\.surface == 'Npm'"
        $workflow | Should -Match '(?m)^\s+fail-fast:\s+false\s*$'
        foreach ($surface in @('Core', 'Desktop', 'Npm')) {
            (@([regex]::Matches($workflow, "(?m)^\s+- surface: $surface\s*$"))).Count | Should -Be 1
        }
        (@([regex]::Matches($workflow, 'test-public-release\.ps1\s+-Surface\s+\$surface'))).Count | Should -Be 1
        foreach ($environmentBinding in @(
            'RECOVERY_RELEASE_TAG: ${{ inputs.release_tag }}',
            'RECOVERY_RELEASE_COMMIT: ${{ inputs.release_commit }}',
            'RECOVERY_NATIVE_VERSION: ${{ inputs.native_version }}',
            'RECOVERY_NPM_VERSION: ${{ inputs.npm_version }}',
            'RECOVERY_WORKFLOW_REF: ${{ github.ref }}',
            'RECOVERY_WORKFLOW_SHA: ${{ github.sha }}'
        )) {
            $workflow | Should -Match ([regex]::Escape($environmentBinding))
        }
        foreach ($coordinate in @(
            'refs/heads/main',
            'feaab01701ddd1f0930da2e8b72cab1e7b25edb0',
            '75dcae87538e96a4cf49dc844d8343842d3c3178',
            'refs/tags/$Tag^{}',
            'helperSourceCommit -cne $workflowSha',
            'tagBefore = Get-RemoteTagIdentity',
            'tagAfter = Get-RemoteTagIdentity',
            'Assert-ExactProperties -Object $helperReceipt',
            "@('asset', 'sha256', 'version')",
            "@('asset', 'sha256', 'version', 'page_url')",
            "'node_path',",
            "'npm_cli_path'",
            'workflow_source_commit',
            'helper_source_sha256',
            'target_tag_object',
            'target_tag_commit',
            'target_identity_sha256',
            'final_receipt'
        )) {
            $workflow | Should -Match ([regex]::Escape($coordinate))
        }
    }

    It 'accepts release-grade notes with highlights, safety, validation, and changelog evidence' {
        $qualityScript = Join-Path $script:RepoRoot 'scripts\assert-release-notes-quality.ps1'
        $releaseBody = Join-Path $TestDrive 'release-grade-body.md'
        Set-Content -LiteralPath $releaseBody -Value @'
## Highlights

- Adds the api_llm worker backend for hosted OpenAI-compatible providers.
- Keeps hosted API workers separate from local and CLI worker backends.
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

    It 'generates release notes that pass the quality gate' {
        $generator = Join-Path $script:RepoRoot 'scripts\generate-release-notes.ps1'
        $qualityScript = Join-Path $script:RepoRoot 'scripts\assert-release-notes-quality.ps1'
        $generatedBody = Join-Path $TestDrive 'generated-release-body.md'
        $backlog = Join-Path $TestDrive 'backlog.yaml'
        Set-Content -LiteralPath $backlog -Value @'
- id: TASK-503
    title: api_llm backend contract and worker CLI surfaces
    status: done
    priority: HIGH
    target_version: v0.36.9
- id: TASK-504
    title: OpenRouter/OpenAI-compatible runner and auth contract
    status: done
    priority: HIGH
    target_version: v0.36.9
- id: TASK-506
    title: External API secret and public-surface gate
    status: done
    priority: HIGH
    target_version: v0.36.9
- id: TASK-507
    title: External API worker E2E evidence and review gate
    status: done
    priority: HIGH
    target_version: v0.36.9
'@ -Encoding UTF8

        $generateOutput = @(& pwsh -NoProfile -File $generator -Version 'v0.36.9' -BacklogPath $backlog -OutputPath $generatedBody 2>&1)
        $LASTEXITCODE | Should -Be 0
        ($generateOutput -join "`n") | Should -Match 'release-notes.*wrote'

        $qualityOutput = @(& pwsh -NoProfile -File $qualityScript -ReleaseNotesPath $generatedBody 2>&1)
        $LASTEXITCODE | Should -Be 0
        ($qualityOutput -join "`n") | Should -Match 'release-notes-quality.*passed'

        $body = Get-Content -LiteralPath $generatedBody -Raw -Encoding UTF8
        $body | Should -Match 'Release workflow builds the Windows x64 core binary'
        $body | Should -Not -Match 'source of truth'
    }

    It 'generates v0.36.26 release notes without private planning wording' {
        $generator = Join-Path $script:RepoRoot 'scripts\generate-release-notes.ps1'
        $qualityScript = Join-Path $script:RepoRoot 'scripts\assert-release-notes-quality.ps1'
        $generatedBody = Join-Path $TestDrive 'generated-v03626-release-body.md'
        $backlog = Join-Path $TestDrive 'backlog.yaml'
        $gitShimDir = Join-Path $TestDrive 'bin-v03626'
        New-Item -ItemType Directory -Path $gitShimDir -Force | Out-Null
        Set-Content -LiteralPath $backlog -Value @'
- id: TASK-639
    title: デスクトップ分割と保守性改善の親タスク
    status: done
    priority: P0
    target_version: v0.36.26
- id: TASK-644
    title: デスクトップ分割ゲート
    status: done
    priority: P0
    target_version: v0.36.26
'@ -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $gitShimDir 'git.cmd') -Value @'
@echo off
if "%~1"=="rev-parse" (
  echo %* | findstr /C:"v0.36.26" >nul
  if not errorlevel 1 exit /b 1
  exit /b 0
)
if "%~1"=="tag" (
  echo v0.36.25
  echo v0.36.24
  exit /b 0
)
if "%~1"=="log" (
  echo test^(app^): add desktop split release gate ^(#1164^)
  exit /b 0
)
exit /b 1
'@ -Encoding ascii

        $previousPath = $env:PATH
        try {
            $env:PATH = "$gitShimDir;$previousPath"
            $generateOutput = @(& pwsh -NoProfile -File $generator -Version 'v0.36.26' -BacklogPath $backlog -OutputPath $generatedBody 2>&1)
            $LASTEXITCODE | Should -Be 0
            ($generateOutput -join "`n") | Should -Match 'release-notes.*wrote'

            $qualityOutput = @(& pwsh -NoProfile -File $qualityScript -ReleaseNotesPath $generatedBody 2>&1)
            $LASTEXITCODE | Should -Be 0
            ($qualityOutput -join "`n") | Should -Match 'release-notes-quality.*passed'
        } finally {
            $env:PATH = $previousPath
        }

        $body = Get-Content -LiteralPath $generatedBody -Raw -Encoding UTF8
        $body | Should -Match 'desktop maintainability'
        $body | Should -Match 'https://github\.com/Sora-bluesky/winsmux/(compare|releases/tag)/'
        $body | Should -Not -Match '[\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}]'
        $body | Should -Not -Match 'TASK-'
        $body | Should -Not -Match 'HANDOFF'
        $maintainerLocalPathPattern = ([regex]::Escape(('C:' + '\Users\'))) + '|Main' + 'Vault|iCloud' + 'Drive'
        $body | Should -Not -Match $maintainerLocalPathPattern
        $body | Should -Not -Match '(?i)\bplanning\b|private planning|planning labels'
    }

    It 'generates v0.36.27 release notes without private planning wording' {
        $generator = Join-Path $script:RepoRoot 'scripts\generate-release-notes.ps1'
        $qualityScript = Join-Path $script:RepoRoot 'scripts\assert-release-notes-quality.ps1'
        $generatedBody = Join-Path $TestDrive 'generated-v03627-release-body.md'
        $backlog = Join-Path $TestDrive 'backlog.yaml'
        $gitShimDir = Join-Path $TestDrive 'bin-v03627'
        New-Item -ItemType Directory -Path $gitShimDir -Force | Out-Null
        Set-Content -LiteralPath $backlog -Value @'
- id: TASK-645
    title: 制御プレーン分割とプロセスプールの親タスク
    status: done
    priority: P0
    target_version: v0.36.27
- id: TASK-650
    title: 互換性・性能ゲート
    status: done
    priority: P0
    target_version: v0.36.27
'@ -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $gitShimDir 'git.cmd') -Value @'
@echo off
if "%~1"=="rev-parse" (
  echo %* | findstr /C:"v0.36.27" >nul
  if not errorlevel 1 exit /b 1
  exit /b 0
)
if "%~1"=="tag" (
  echo v0.36.26
  echo v0.36.25
  exit /b 0
)
if "%~1"=="log" (
  echo refactor^(core^): split control-plane dispatch adapters ^(#1170^)
  echo refactor^(core^): extract command result handlers ^(#1172^)
  echo refactor^(core^): extract workers workspace command module ^(#1173^)
  echo refactor^(core^): extract run ledger module ^(#1174^)
  echo feat^(core^): add shared Rust read path ^(#1175^)
  echo feat^(core^): add process registry and automation driver pool ^(#1176^)
  echo test^(release^): add v0.36.27 compat performance gate ^(#1177^)
  exit /b 0
)
exit /b 1
'@ -Encoding ascii

        $previousPath = $env:PATH
        try {
            $env:PATH = "$gitShimDir;$previousPath"
            $generateOutput = @(& pwsh -NoProfile -File $generator -Version 'v0.36.27' -BacklogPath $backlog -OutputPath $generatedBody 2>&1)
            $LASTEXITCODE | Should -Be 0
            ($generateOutput -join "`n") | Should -Match 'release-notes.*wrote'

            $qualityOutput = @(& pwsh -NoProfile -File $qualityScript -ReleaseNotesPath $generatedBody 2>&1)
            $LASTEXITCODE | Should -Be 0
            ($qualityOutput -join "`n") | Should -Match 'release-notes-quality.*passed'
        } finally {
            $env:PATH = $previousPath
        }

        $body = Get-Content -LiteralPath $generatedBody -Raw -Encoding UTF8
        $body | Should -Match 'control-plane dispatch path'
        $body | Should -Match 'compatibility and performance release gate'
        $body | Should -Match 'https://github\.com/Sora-bluesky/winsmux/(compare|releases/tag)/'
        $body | Should -Not -Match '[\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}]'
        $body | Should -Not -Match 'TASK-'
        $body | Should -Not -Match 'HANDOFF'
        $maintainerLocalPathPattern = ([regex]::Escape(('C:' + '\Users\'))) + '|Main' + 'Vault|iCloud' + 'Drive'
        $body | Should -Not -Match $maintainerLocalPathPattern
        $body | Should -Not -Match '(?i)\bplanning\b|private planning|planning labels'
    }

    It 'generates release notes from public git history when backlog is unavailable' {
        $generator = Join-Path $script:RepoRoot 'scripts\generate-release-notes.ps1'
        $qualityScript = Join-Path $script:RepoRoot 'scripts\assert-release-notes-quality.ps1'
        $generatedBody = Join-Path $TestDrive 'generated-release-body-no-backlog.md'
        $gitShimDir = Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory -Path $gitShimDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $gitShimDir 'git.cmd') -Value @'
@echo off
if "%~1"=="rev-parse" exit /b 0
if "%~1"=="tag" (
  echo v0.36.10
  echo v0.36.9
  exit /b 0
)
if "%~1"=="log" (
  echo feat^(workers^): migrate worker path to Antigravity CLI ^(#982^)
  echo test^(release^): gate release note quality ^(#981^)
  echo fix^(desktop^): harden operator runtime controls ^(#975^)
  echo chore^(deps-dev^): bump vite from 6.4.2 to 6.4.3 in /winsmux-app
  exit /b 0
)
exit /b 1
'@ -Encoding ascii

        $previousPath = $env:PATH
        try {
            $env:PATH = "$gitShimDir;$previousPath"
            $generateOutput = @(& pwsh -NoProfile -File $generator -Version 'v0.36.10' -BacklogPath (Join-Path $TestDrive 'missing-backlog.yaml') -OutputPath $generatedBody 2>&1)
            $LASTEXITCODE | Should -Be 0
            ($generateOutput -join "`n") | Should -Match 'backlog not found'
            ($generateOutput -join "`n") | Should -Match 'release-notes.*wrote'

            $qualityOutput = @(& pwsh -NoProfile -File $qualityScript -ReleaseNotesPath $generatedBody 2>&1)
            $LASTEXITCODE | Should -Be 0
            ($qualityOutput -join "`n") | Should -Match 'release-notes-quality.*passed'
        } finally {
            $env:PATH = $previousPath
        }

        $body = Get-Content -LiteralPath $generatedBody -Raw -Encoding UTF8
        $body | Should -Match 'Antigravity CLI route'
        $body | Should -Match 'release-note quality gates'
        $body | Should -Not -Match 'source of truth'
    }

    It 'uses the latest existing version tag when the requested release tag is missing' {
        $generator = Join-Path $script:RepoRoot 'scripts\generate-release-notes.ps1'
        $generatedBody = Join-Path $TestDrive 'generated-release-body-missing-target-tag.md'
        $gitShimDir = Join-Path $TestDrive 'bin-missing-tag'
        $gitArgsLog = Join-Path $TestDrive 'git-log-args.txt'
        New-Item -ItemType Directory -Path $gitShimDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $gitShimDir 'git.ps1') -Value @"
`$gitArgsLog = @'
$gitArgsLog
'@

switch (`$args[0]) {
    'rev-parse' {
        if (`$args -contains 'v0.36.15') { exit 1 }
        if (`$args -contains 'v0.36.10') {
            '9b8475b2b3548f29977cf1f1b3c75995d9d76baa'
            exit 0
        }
        exit 0
    }
    'tag' {
        'v0.36.10'
        'v0.36.9'
        exit 0
    }
    'log' {
        Add-Content -LiteralPath `$gitArgsLog -Value (`$args -join ' ') -Encoding UTF8
        'feat(desktop): add worker model picker benchmark surface'
        'fix(release): harden core release notes fallback (#984)'
        exit 0
    }
    default {
        exit 1
    }
}
"@ -Encoding UTF8

        $previousPath = $env:PATH
        try {
            $env:PATH = "$gitShimDir;$previousPath"
            $generateOutput = @(& pwsh -NoProfile -File $generator -Version 'v0.36.15' -BacklogPath (Join-Path $TestDrive 'missing-backlog.yaml') -OutputPath $generatedBody 2>&1)
            $LASTEXITCODE | Should -Be 0
            ($generateOutput -join "`n") | Should -Match 'release-notes.*wrote'
        } finally {
            $env:PATH = $previousPath
        }

        (Get-Content -LiteralPath $gitArgsLog -Raw -Encoding UTF8) | Should -Match 'v0\.36\.10\.\.HEAD'
        (Get-Content -LiteralPath $generatedBody -Raw -Encoding UTF8) | Should -Match 'v0\.36\.10\.\.\.v0\.36\.15'
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

    It 'T832-CONTROL-01 observes desktop self-test case projection through the shared transport' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'desktop_lifecycle_success_orders_cleanup'
    }

    It 'T832-DIAG-KEYS-01 emits six teardown diagnosis keys in the four-value domain' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8

        $helper | Should -Match 'function Get-DesktopTeardownDiagnosis'
        $helper | Should -Match 'function New-DesktopTeardownProbeTable'
        foreach ($key in @(
            'desktop_probe_runtime_registry',
            'desktop_probe_runtime_binary',
            'desktop_probe_profile_dir',
            'desktop_probe_init_trace',
            'desktop_probe_port_file_redirected',
            'desktop_probe_port_file_fallback',
            'desktop_probe_webview_process_present'
        )) {
            $helper | Should -Match ([regex]::Escape($key))
        }
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'desktop_teardown_diagnosis_keys'
    }

    It 'T832-DIAG-BUDGET-01 bounds teardown probes and keeps cleanup unconditional' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8

        $helper | Should -Match 'function Invoke-BoundedDiagnosisProbe'
        $helper | Should -Match ([regex]::Escape('$script:DesktopTeardownProbeTimeoutMilliseconds = 5000'))
        $helper | Should -Match ([regex]::Escape('$script:DesktopTeardownProbeTotalBudgetMilliseconds = 20000'))
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'desktop_teardown_diagnosis_budget'
    }

    It 'T832-DIAG-PRIVACY-01 asserts the raw-absent pattern on the diagnosis segment before emit' {
        $helperPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8

        $helper | Should -Match 'function Get-DesktopTeardownDiagnosisSegment'
        $helper | Should -Match ([regex]::Escape('desktop_probe_[a-z_]+=(?:true|false|unknown|error:[a-z]+)'))
        $selfTestOutput = @(& pwsh -NoProfile -File $helperPath -Surface Desktop -Version $script:ProductVersion -ReleaseTag "v$($script:ProductVersion)" -Repository 'Sora-bluesky/winsmux' -SelfTest -Json 2>&1)
        $LASTEXITCODE | Should -Be 0
        $selfTest = ($selfTestOutput -join "`n") | ConvertFrom-Json -Depth 20
        @($selfTest.case_ids) | Should -Contain 'desktop_teardown_diagnosis_privacy'
    }
}
