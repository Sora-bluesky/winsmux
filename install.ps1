# install.ps1 — winsmux one-command installer
# Usage: irm https://raw.githubusercontent.com/Sora-bluesky/winsmux/main/install.ps1 | iex
# Or: pwsh install.ps1 [install|update|uninstall|version|help] [-ReleaseTag vX.Y.Z] [-Profile full]

[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Action = "install",
    [string]$ReleaseTag = "",
    [Alias("Profile")][string]$InstallProfile = ""
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$VERSION      = "0.24.12"
$WINSMUX_DIR  = Join-Path $HOME ".winsmux"
$BIN_DIR      = Join-Path $WINSMUX_DIR "bin"
$BACKUP_DIR   = Join-Path $WINSMUX_DIR "backups"
$SCRIPT_DIR   = Join-Path $WINSMUX_DIR "scripts"
$BRIDGE_DIR   = Join-Path $WINSMUX_DIR "winsmux-core"
$BRIDGE_SCRIPTS_DIR = Join-Path $BRIDGE_DIR "scripts"
$VERSION_FILE = Join-Path $WINSMUX_DIR "version"
$PROFILE_FILE = Join-Path $WINSMUX_DIR "install-profile"
$PROFILE_MANIFEST_FILE = Join-Path $WINSMUX_DIR "install-profile.json"
$PROFILE_MATRIX = @{
    core = "Runtime binary, wrapper scripts, PATH setup, and base config."
    orchestra = "Core profile plus orchestration scripts, runtime dependencies, and Windows Terminal profile."
    security = "Core profile plus vault, redaction, and audit-oriented scripts."
    full = "Core, orchestra, and security profile contents."
}
$EffectiveReleaseTag = if ([string]::IsNullOrWhiteSpace($ReleaseTag)) { $env:WINSMUX_RELEASE_TAG } else { $ReleaseTag }
if ([string]::IsNullOrWhiteSpace($EffectiveReleaseTag)) {
    $BASE_URL = "https://raw.githubusercontent.com/Sora-bluesky/winsmux/main"
    $RELEASE_API_URL = "https://api.github.com/repos/Sora-bluesky/winsmux/releases/latest"
    $RELEASE_LABEL = "latest"
} else {
    $BASE_URL = "https://raw.githubusercontent.com/Sora-bluesky/winsmux/$EffectiveReleaseTag"
    $escapedTag = [Uri]::EscapeDataString($EffectiveReleaseTag)
    $RELEASE_API_URL = "https://api.github.com/repos/Sora-bluesky/winsmux/releases/tags/$escapedTag"
    $RELEASE_LABEL = $EffectiveReleaseTag
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Status($msg) { Write-Host "[winsmux] $msg" }

function Resolve-InstallProfile {
    param([switch]$PreferExisting)

    $profileName = if ([string]::IsNullOrWhiteSpace($InstallProfile)) { $env:WINSMUX_INSTALL_PROFILE } else { $InstallProfile }
    if ([string]::IsNullOrWhiteSpace($profileName) -and $PreferExisting -and (Test-Path -LiteralPath $PROFILE_FILE -PathType Leaf)) {
        $profileName = (Get-Content -LiteralPath $PROFILE_FILE -Raw -ErrorAction SilentlyContinue).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($profileName)) {
        $profileName = "full"
    }

    $normalized = $profileName.Trim().ToLowerInvariant()
    if (-not $PROFILE_MATRIX.ContainsKey($normalized)) {
        $supported = ($PROFILE_MATRIX.Keys | Sort-Object) -join ", "
        throw "Unsupported install profile '$profileName'. Supported profiles: $supported"
    }

    return $normalized
}

function Get-InstallProfileContents {
    param([Parameter(Mandatory = $true)][string]$Profile)

    switch ($Profile) {
        "core" { return @("runtime", "wrappers", "path", "base_config") }
        "orchestra" { return @("runtime", "wrappers", "path", "base_config", "orchestration_scripts", "windows_terminal_profile", "vault") }
        "security" { return @("runtime", "wrappers", "path", "base_config", "vault", "redaction", "audit_scripts") }
        "full" { return @("runtime", "wrappers", "path", "base_config", "orchestration_scripts", "windows_terminal_profile", "vault", "redaction", "audit_scripts") }
        default { throw "Unsupported install profile '$Profile'." }
    }
}

function Test-InstallProfileContent {
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$Content
    )

    return @(Get-InstallProfileContents -Profile $Profile) -contains $Content
}

function Write-InstallProfileManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][bool]$IsUpdate
    )

    $manifest = [ordered]@{
        version = $VERSION
        profile = $Profile
        release_tag = $EffectiveReleaseTag
        mode = if ($IsUpdate) { "update" } else { "install" }
        contents = @(Get-InstallProfileContents -Profile $Profile)
        recorded_at = (Get-Date).ToUniversalTime().ToString("o")
    }

    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $PROFILE_MANIFEST_FILE -Encoding UTF8
}

function Install-OrchestraSupportScripts {
    Download-File "winsmux-core/scripts/agent-launch.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "agent-launch.ps1")
    Download-File "winsmux-core/scripts/agent-monitor.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "agent-monitor.ps1")
    Download-File "winsmux-core/scripts/agent-readiness.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "agent-readiness.ps1")
    Download-File "winsmux-core/scripts/agent-watchdog.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "agent-watchdog.ps1")
    Download-File "winsmux-core/scripts/builder-worktree.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "builder-worktree.ps1")
    Download-File "winsmux-core/scripts/clm-safe-io.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "clm-safe-io.ps1")
    Download-File "winsmux-core/scripts/operator-poll.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "operator-poll.ps1")
    Download-File "winsmux-core/scripts/doctor.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "doctor.ps1")
    Download-File "winsmux-core/scripts/logger.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "logger.ps1")
    Download-File "winsmux-core/scripts/manifest.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "manifest.ps1")
    Download-File "winsmux-core/scripts/orchestra-attach-confirm.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-attach-confirm.ps1")
    Download-File "winsmux-core/scripts/orchestra-attach-entry.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-attach-entry.ps1")
    Download-File "winsmux-core/scripts/orchestra-pane-bootstrap.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-pane-bootstrap.ps1")
    Download-File "winsmux-core/scripts/orchestra-preflight.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-preflight.ps1")
    Download-File "winsmux-core/scripts/orchestra-smoke.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-smoke.ps1")
    Download-File "winsmux-core/scripts/orchestra-start.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-start.ps1")
    Download-File "winsmux-core/scripts/orchestra-state.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-state.ps1")
    Download-File "winsmux-core/scripts/orchestra-layout.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-layout.ps1")
    Download-File "winsmux-core/scripts/orchestra-ui-attach.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-ui-attach.ps1")
    Download-File "winsmux-core/scripts/pane-control.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "pane-control.ps1")
    Download-File "winsmux-core/scripts/pane-env.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "pane-env.ps1")
    Download-File "winsmux-core/scripts/pane-border.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "pane-border.ps1")
    Download-File "winsmux-core/scripts/planning-paths.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "planning-paths.ps1")
    Download-File "winsmux-core/scripts/public-first-run.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "public-first-run.ps1")
    Download-File "winsmux-core/scripts/server-watchdog.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "server-watchdog.ps1")
    Download-File "winsmux-core/scripts/settings.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "settings.ps1")
    Download-File "winsmux-core/scripts/vault.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "vault.ps1")
}

function Install-SecuritySupportScripts {
    Download-File "winsmux-core/scripts/vault.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "vault.ps1")
}

function Remove-ProfileExcludedSupportScripts {
    param([Parameter(Mandatory = $true)][string]$Profile)

    $scriptGroups = @(
        [PSCustomObject]@{
            Content = "orchestration_scripts"
            Files = @(
                "agent-launch.ps1",
                "agent-monitor.ps1",
                "agent-readiness.ps1",
                "agent-watchdog.ps1",
                "builder-worktree.ps1",
                "clm-safe-io.ps1",
                "operator-poll.ps1",
                "doctor.ps1",
                "logger.ps1",
                "manifest.ps1",
                "orchestra-attach-confirm.ps1",
                "orchestra-attach-entry.ps1",
                "orchestra-pane-bootstrap.ps1",
                "orchestra-preflight.ps1",
                "orchestra-smoke.ps1",
                "orchestra-start.ps1",
                "orchestra-state.ps1",
                "orchestra-layout.ps1",
                "orchestra-ui-attach.ps1",
                "pane-control.ps1",
                "pane-env.ps1",
                "pane-border.ps1",
                "planning-paths.ps1",
                "public-first-run.ps1",
                "server-watchdog.ps1",
                "settings.ps1"
            )
        },
        [PSCustomObject]@{
            Content = "vault"
            Files = @("vault.ps1")
        }
    )

    foreach ($group in $scriptGroups) {
        if (Test-InstallProfileContent -Profile $Profile -Content $group.Content) {
            continue
        }

        foreach ($fileName in $group.Files) {
            $path = Join-Path $BRIDGE_SCRIPTS_DIR $fileName
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
                Write-Status "Removed profile-excluded support script: $fileName"
            }
        }
    }
}

function Sync-WindowsTerminalFragment {
    param([Parameter(Mandatory = $true)][string]$Profile)

    $fragmentDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments\winsmux"
    $fragmentFile = Join-Path $fragmentDir "winsmux.json"
    $shouldInstallFragment = Test-InstallProfileContent -Profile $Profile -Content "windows_terminal_profile"

    if (-not $shouldInstallFragment) {
        if (Test-Path $fragmentFile) {
            Remove-Item $fragmentFile -Force
            Write-Status "Removed Windows Terminal fragment for profile '$Profile': $fragmentFile"
        }
        return
    }

    if (-not (Test-Path $fragmentDir)) {
        New-Item -ItemType Directory -Path $fragmentDir -Force | Out-Null
    }
    $fragmentJson = @'
{
  "profiles": [
    {
      "name": "winsmux Orchestra",
      "commandline": "pwsh -NoProfile -Command \"$dir = Read-Host 'Project dir'; if ([string]::IsNullOrWhiteSpace($dir)) { Write-Error 'Project dir is required.'; exit 1 }; & '%USERPROFILE%\\.winsmux\\bin\\winsmux.ps1' start -C $dir\"",
      "icon": "🎼",
      "startingDirectory": "%USERPROFILE%",
      "tabTitle": "winsmux Orchestra"
    }
  ]
}
'@
    $fragmentJson | Set-Content -Path $fragmentFile -Encoding UTF8
    Write-Status "Registered Windows Terminal fragment: $fragmentFile"
}

function Test-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PreferredReleaseAssetName {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq "x86" -and $env:PROCESSOR_ARCHITEW6432) {
        $arch = $env:PROCESSOR_ARCHITEW6432
    }

    switch ($arch) {
        "AMD64" { return "winsmux-x64.exe" }
        "ARM64" { return "winsmux-arm64.exe" }
        default { throw "Unsupported architecture: $arch" }
    }
}

function Get-WinsmuxCommandVersion {
    param([Parameter(Mandatory = $true)]$CommandInfo)

    try {
        $output = (& $CommandInfo.Source -V 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        if ($output -match 'winsmux(?:-[^\s]+)?\s+(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)') {
            return [PSCustomObject]@{
                Version = $Matches.version
                Output  = $output
            }
        }
    } catch {
        return $null
    }

    return $null
}

function Install-WinsmuxBinary {
    $existing = Get-Command winsmux -ErrorAction SilentlyContinue
    if ($existing) {
        $detected = Get-WinsmuxCommandVersion -CommandInfo $existing
        if ($detected -and $detected.Version -eq $VERSION) {
            Write-Status "winsmux found: $($detected.Output)"
            return
        }

        if ($detected) {
            Write-Warning "[winsmux] Existing winsmux version '$($detected.Version)' does not match installer version '$VERSION'. Reinstalling release binary."
        } else {
            Write-Warning "[winsmux] Existing winsmux command did not return a compatible version. Reinstalling release binary."
        }
    } else {
        Write-Status "winsmux binary not found. Downloading winsmux-core..."
    }

    $localBin = Join-Path $HOME ".local/bin"
    $winsmuxExe = Join-Path $localBin "winsmux.exe"
    $headers = @{ "User-Agent" = "winsmux-installer/$VERSION" }
    $assetName = Get-PreferredReleaseAssetName

    try {
        if (-not (Test-Path $localBin)) {
            New-Item -ItemType Directory -Path $localBin -Force | Out-Null
        }

        Write-Status "Fetching winsmux-core release ($RELEASE_LABEL)..."
        $release = Invoke-RestMethod -Uri $RELEASE_API_URL -Headers $headers -ErrorAction Stop
        $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
        if (-not $asset -and $assetName -eq "winsmux-arm64.exe") {
            Write-Warning "[winsmux] ARM64 asset not found in release $($release.tag_name). Falling back to winsmux-x64.exe."
            $asset = $release.assets | Where-Object { $_.name -eq "winsmux-x64.exe" } | Select-Object -First 1
        }
        if (-not $asset) {
            throw "$assetName asset not found in release $($release.tag_name)"
        }

        Write-Status "Downloading $($asset.name) from $($release.tag_name)..."
        Invoke-RestMethod -Uri $asset.browser_download_url -Headers $headers -OutFile $winsmuxExe -ErrorAction Stop

        $sha256Asset = $release.assets | Where-Object { $_.name -eq "SHA256SUMS" } | Select-Object -First 1
        if (-not $sha256Asset) {
            Write-Warning "[winsmux] SHA256SUMS asset not found in release $($release.tag_name). Skipping checksum verification."
        } else {
            $checksumsPath = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-" + [System.Guid]::NewGuid().ToString() + "-SHA256SUMS")
            try {
                Write-Status "Downloading $($sha256Asset.name) from $($release.tag_name)..."
                Invoke-RestMethod -Uri $sha256Asset.browser_download_url -Headers $headers -OutFile $checksumsPath -ErrorAction Stop

                $expectedHash = $null
                foreach ($line in Get-Content $checksumsPath) {
                    if ($line -match '^(?<hash>[A-Fa-f0-9]{64})\s+\*?(?<name>.+)$') {
                        if ($Matches.name -eq $asset.name) {
                            $expectedHash = $Matches.hash.ToUpperInvariant()
                            break
                        }
                    }
                }

                if (-not $expectedHash) {
                    Write-Warning "[winsmux] SHA256SUMS does not contain an entry for $($asset.name). Skipping checksum verification."
                } else {
                    $actualHash = (Get-FileHash $winsmuxExe -Algorithm SHA256).Hash.ToUpperInvariant()
                    if ($actualHash -ne $expectedHash) {
                        throw "Checksum verification failed for $($asset.name)."
                    }
                    Write-Status "Checksum verified"
                }
            } catch {
                if ($_.Exception.Message -like "Checksum verification failed*") {
                    throw
                }
                Write-Warning "[winsmux] Failed to verify checksum for $($asset.name): $_. Skipping checksum verification."
            } finally {
                Remove-Item $checksumsPath -Force -ErrorAction SilentlyContinue
            }
        }

        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $userPaths = @()
        if ($userPath) {
            $userPaths = $userPath -split ';' | Where-Object { $_ }
        }

        $hasLocalBin = $false
        foreach ($pathEntry in $userPaths) {
            if ($pathEntry.TrimEnd('\') -ieq $localBin.TrimEnd('\')) {
                $hasLocalBin = $true
                break
            }
        }

        if (-not $hasLocalBin) {
            $newUserPath = if ($userPath) { "$userPath;$localBin" } else { $localBin }
            [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
            Write-Status "Added $localBin to user PATH"
        }

        if (-not (($env:Path -split ';' | Where-Object { $_.TrimEnd('\') -ieq $localBin.TrimEnd('\') }))) {
            $env:Path = if ($env:Path) { "$env:Path;$localBin" } else { $localBin }
        }

        $ver = (& $winsmuxExe -V 2>&1 | Out-String).Trim()
        Write-Status "Installed winsmux: $ver"
    } catch {
        Write-Error "[winsmux] Failed to install winsmux-core: $_"
        exit 1
    }
}

function Backup-File($path) {
    if (Test-Path $path) {
        $ts   = Get-Date -Format "yyyyMMdd-HHmmss"
        $name = (Split-Path $path -Leaf) + ".$ts.bak"
        $dest = Join-Path $BACKUP_DIR $name
        Copy-Item $path $dest -Force
        Write-Status "Backed up $(Split-Path $path -Leaf) -> $dest"
    }
}

function Download-File($relativeUrl, $destPath) {
    $url = "$BASE_URL/$relativeUrl"
    Write-Status "Downloading $relativeUrl ..."
    try {
        Invoke-RestMethod -Uri $url -OutFile $destPath -ErrorAction Stop
    } catch {
        Write-Error "[winsmux] Failed to download $url : $_"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Invoke-Install {
    param([switch]$IsUpdate)
    $label = if ($IsUpdate) { "Updating" } else { "Installing" }
    $resolvedInstallProfile = Resolve-InstallProfile -PreferExisting:$IsUpdate
    Write-Status "$label winsmux v$VERSION with profile '$resolvedInstallProfile' ..."

    # 1. PowerShell version check
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Warning "[winsmux] PowerShell 7+ is recommended. You are running $($PSVersionTable.PSVersion). Some features may not work correctly."
    }

    # 2. Administrator check
    if (Test-Administrator) {
        Write-Warning "[winsmux] Running as Administrator is not recommended. Consider running as a normal user."
    }

    # 3. winsmux detection / install
    Install-WinsmuxBinary

    # 4. Create directories
    foreach ($dir in @($WINSMUX_DIR, $BIN_DIR, $BACKUP_DIR, $SCRIPT_DIR, $BRIDGE_DIR, $BRIDGE_SCRIPTS_DIR, (Join-Path $env:APPDATA "winsmux"))) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # 5. Download & place files
    # winsmux-core.ps1
    Download-File "scripts/winsmux-core.ps1" (Join-Path $BIN_DIR "winsmux-core.ps1")
    Download-File "scripts/winsmux-core.ps1" (Join-Path $SCRIPT_DIR "winsmux-core.ps1")

    # winsmux.ps1 CLI
    Download-File "winsmux.ps1" (Join-Path $BIN_DIR "winsmux.ps1")

    if (Test-InstallProfileContent -Profile $resolvedInstallProfile -Content "orchestration_scripts") {
        Install-OrchestraSupportScripts
    }
    if (Test-InstallProfileContent -Profile $resolvedInstallProfile -Content "vault") {
        Install-SecuritySupportScripts
    }
    Remove-ProfileExcludedSupportScripts -Profile $resolvedInstallProfile

    # .winsmux.conf (backup existing)
    $confDest = Join-Path $HOME ".winsmux.conf"
    Backup-File $confDest
    Download-File ".winsmux.conf" $confDest

    # 6. Create .cmd wrappers
    $bridgeCmd = Join-Path $BIN_DIR "winsmux.cmd"
    @"
@echo off
pwsh -NoProfile -File "%USERPROFILE%\.winsmux\bin\winsmux-core.ps1" %*
"@ | Set-Content -Path $bridgeCmd -Encoding ASCII

    $winsmuxCmd = Join-Path $BIN_DIR "winsmux.cmd"
    @"
@echo off
pwsh -NoProfile -File "%USERPROFILE%\.winsmux\bin\winsmux.ps1" %*
"@ | Set-Content -Path $winsmuxCmd -Encoding ASCII

    # 7.5. Register Windows Terminal Fragments
    Sync-WindowsTerminalFragment -Profile $resolvedInstallProfile

    # 8. Add to PATH via $PROFILE
    $profileLine = "`$env:PATH = `"$BIN_DIR;`$env:PATH`""
    $profilePath = $PROFILE.CurrentUserAllHosts
    if (-not (Test-Path $profilePath)) {
        $profileDir = Split-Path $profilePath -Parent
        if (-not (Test-Path $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        }
        New-Item -Path $profilePath -Force | Out-Null
    }
    $content = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if (-not $content -or $content -notmatch 'winsmux') {
        Add-Content $profilePath "`n# winsmux`n$profileLine"
    }
    $env:PATH = "$BIN_DIR;$env:PATH"

    # 9. Record version
    $VERSION | Set-Content $VERSION_FILE
    $resolvedInstallProfile | Set-Content $PROFILE_FILE
    Write-InstallProfileManifest -Profile $resolvedInstallProfile -IsUpdate:$IsUpdate

    # 10. Completion message
    if ($IsUpdate) {
        Write-Host ""
        Write-Status "Updated to v$VERSION!"
        Write-Host "  winsmux: $(Join-Path $BIN_DIR 'winsmux-core.ps1')"
        Write-Host "  winsmux config:  $confDest"
        Write-Host "  install profile: $resolvedInstallProfile"
    } else {
        Write-Host ""
        Write-Status "Installed successfully! (v$VERSION)"
        Write-Host "  winsmux: $(Join-Path $BIN_DIR 'winsmux-core.ps1')"
        Write-Host "  winsmux config:  $confDest"
        Write-Host "  install profile: $resolvedInstallProfile"
        Write-Host ""
        Write-Host "Next steps:"
        if (Test-InstallProfileContent -Profile $resolvedInstallProfile -Content "orchestration_scripts") {
            Write-Host "  1. Create project config:  winsmux init"
            Write-Host "  2. Launch first run:       winsmux launch"
            Write-Host "  3. Inspect panes:          winsmux list"
        } else {
            Write-Host "  1. Start a session:        winsmux new-session -s work"
            Write-Host "  2. Inspect panes:          winsmux list"
        }
    }
}

function Invoke-Uninstall {
    Write-Status "Uninstalling winsmux..."

    # 1. Remove ~/.winsmux
    if (Test-Path $WINSMUX_DIR) {
        Remove-Item $WINSMUX_DIR -Recurse -Force
        Write-Status "Removed $WINSMUX_DIR"
    }

    # 2. Remove ~/.winsmux.conf
    $confPath = Join-Path $HOME ".winsmux.conf"
    if (Test-Path $confPath) {
        Write-Host "[winsmux] Remove $confPath ? (winsmux config file)" -NoNewline
        Write-Host " [Y/n] " -NoNewline
        $answer = Read-Host
        if ($answer -eq '' -or $answer -match '^[Yy]') {
            Remove-Item $confPath -Force
            Write-Status "Removed $confPath"
        } else {
            Write-Status "Kept $confPath"
        }
    }

    # 3. Remove winsmux lines from $PROFILE
    $profilePath = $PROFILE.CurrentUserAllHosts
    if (Test-Path $profilePath) {
        $lines = Get-Content $profilePath
        $filtered = $lines | Where-Object { $_ -notmatch 'winsmux' }
        $filtered | Set-Content $profilePath
        Write-Status "Cleaned $profilePath"
    }

    # 4. Remove Windows Terminal Fragments
    $fragmentDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments\winsmux"
    if (Test-Path $fragmentDir) {
        Remove-Item $fragmentDir -Recurse -Force
        Write-Status "Removed Windows Terminal fragment: $fragmentDir"
    }

    # 5. Remove %APPDATA%\winsmux
    $appDataDir = Join-Path $env:APPDATA "winsmux"
    if (Test-Path $appDataDir) {
        Remove-Item $appDataDir -Recurse -Force
        Write-Status "Removed $appDataDir"
    }

    # 6. Done (winsmux binary is NOT uninstalled)
    Write-Host ""
    Write-Status "Uninstalled."
    Write-Host "  Note: winsmux itself was NOT removed. Manage it separately if needed."
}

function Show-Help {
    Write-Host @"
Usage: install.ps1 [action] [-Profile core|orchestra|security|full]

Actions:
  install     Install winsmux (default)
  update      Update to latest version
  uninstall   Remove winsmux
  version     Show version
  help        Show this help

Profiles:
  core        Runtime, wrapper scripts, PATH, and base config
  orchestra  core plus orchestration scripts and Windows Terminal profile
  security   core plus vault, redaction, and audit-oriented scripts
  full       core, orchestra, and security contents (default)
"@
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

switch ($Action.ToLower()) {
    "install"   { Invoke-Install }
    "update"    { Invoke-Install -IsUpdate }
    "uninstall" { Invoke-Uninstall }
    "version"   { Write-Output "winsmux $VERSION" }
    "help"      { Show-Help }
    default     { Show-Help }
}
