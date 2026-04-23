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
        $installScript | Should -Match 'function Get-WinsmuxCommandVersion'
        $installScript | Should -Match 'does not match installer version'
        $installScript | Should -Match 'Reinstalling release binary'
        $bridgeScript | Should -Match ('\$VERSION\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
        $workspaceLock | Should -Match ('(?ms)^name\s*=\s*"winsmux"\s*\r?\nversion\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
        $coreManifest | Should -Match ('(?m)^version\s*=\s*"{0}"\r?$' -f [regex]::Escape($script:ProductVersion))
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
        $tauriManifest | Should -Match ('(?m)^version\s*=\s*"{0}"\r?$' -f [regex]::Escape($script:ProductVersion))
        $workspaceLock | Should -Match ('(?ms)^name\s*=\s*"winsmux-app"\s*\r?\nversion\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
        $tauriLock | Should -Match ('(?ms)^name\s*=\s*"winsmux-app"\s*\r?\nversion\s*=\s*"{0}"' -f [regex]::Escape($script:ProductVersion))
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
}
