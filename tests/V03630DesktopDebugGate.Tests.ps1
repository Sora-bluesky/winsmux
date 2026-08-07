$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'V0.36.30 desktop debug gate contract' {
    BeforeAll {
        $script:RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:RepoRoot)) {
            throw 'Failed to resolve repository root.'
        }
    }

    It 'declares the main window with create disabled' {
        $configPath = Join-Path $script:RepoRoot 'winsmux-app\src-tauri\tauri.conf.json'
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $create = $config.app.windows[0].create
        $null -ne $create | Should -BeTrue
        $create | Should -Be $false
    }

    It 'does not declare static additionalBrowserArgs' {
        $configPath = Join-Path $script:RepoRoot 'winsmux-app\src-tauri\tauri.conf.json'
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $config.app.windows[0].PSObject.Properties.Name -notcontains 'additionalBrowserArgs' | Should -BeTrue
    }

    It 'pins wry to the version named by the gate constants' {
        $cargoLockPath = Join-Path $script:RepoRoot 'Cargo.lock'
        $cargoLock = Get-Content -LiteralPath $cargoLockPath -Raw -Encoding UTF8
        if ($cargoLock -notmatch '(?ms)name\s*=\s*"wry"\s*\r?\nversion\s*=\s*"([^"]+)"') {
            throw 'Failed to extract wry version from Cargo.lock.'
        }
        $Matches[1] | Should -Be '0.55.1'
    }

    It 'spells the gate environment variable names identically in Rust and PowerShell' {
        $rustPath = Join-Path $script:RepoRoot 'winsmux-app\src-tauri\src\remote_debug_gate.rs'
        $rustSource = Get-Content -LiteralPath $rustPath -Raw -Encoding UTF8
        $rustSource | Should -Match 'WINSMUX_DESKTOP_TEST_PROFILE'
        $rustSource | Should -Match 'WINSMUX_DESKTOP_REMOTE_DEBUG_PORT'

        $psPath = Join-Path $script:RepoRoot 'scripts\test-public-release.ps1'
        $psSource = Get-Content -LiteralPath $psPath -Raw -Encoding UTF8
        $psSource | Should -Match 'WINSMUX_DESKTOP_TEST_PROFILE'
        $psSource | Should -Match 'WINSMUX_DESKTOP_REMOTE_DEBUG_PORT'
    }

    It 'keeps the wry default browser args constant in the gate module' {
        $rustPath = Join-Path $script:RepoRoot 'winsmux-app\src-tauri\src\remote_debug_gate.rs'
        $rustSource = Get-Content -LiteralPath $rustPath -Raw -Encoding UTF8
        $rustSource | Should -Match '--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection'
        $rustSource | Should -Match '--autoplay-policy=no-user-gesture-required'
    }
}