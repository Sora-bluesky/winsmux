# install.ps1 — winsmux one-command installer
# Usage: irm https://raw.githubusercontent.com/Sora-bluesky/winsmux/main/install.ps1 | iex
# Or: pwsh install.ps1 [install|update|uninstall|version|help]

[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Action = "install"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$VERSION      = "0.17.0"
$WINSMUX_DIR  = Join-Path $HOME ".winsmux"
$BIN_DIR      = Join-Path $WINSMUX_DIR "bin"
$BACKUP_DIR   = Join-Path $WINSMUX_DIR "backups"
$SCRIPT_DIR   = Join-Path $WINSMUX_DIR "scripts"
$BRIDGE_DIR   = Join-Path $WINSMUX_DIR "psmux-bridge"
$BRIDGE_SCRIPTS_DIR = Join-Path $BRIDGE_DIR "scripts"
$VERSION_FILE = Join-Path $WINSMUX_DIR "version"
$BASE_URL     = "https://raw.githubusercontent.com/Sora-bluesky/winsmux/main"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Status($msg) { Write-Host "[winsmux] $msg" }

function Test-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-Psmux {
    if (Get-Command psmux -ErrorAction SilentlyContinue) {
        $ver = (psmux -V 2>&1 | Out-String).Trim()
        Write-Status "psmux found: $ver"
        return
    }
    Write-Status "psmux not found. Downloading sora-psmux fork..."

    $localBin = Join-Path $HOME ".local/bin"
    $psmuxExe = Join-Path $localBin "psmux.exe"
    $releaseUrl = "https://api.github.com/repos/Sora-bluesky/psmux/releases/latest"
    $headers = @{ "User-Agent" = "winsmux-installer/$VERSION" }

    try {
        if (-not (Test-Path $localBin)) {
            New-Item -ItemType Directory -Path $localBin -Force | Out-Null
        }

        Write-Status "Fetching latest sora-psmux release..."
        $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers -ErrorAction Stop
        $asset = $release.assets | Where-Object { $_.name -eq "psmux.exe" } | Select-Object -First 1
        if (-not $asset) {
            throw "psmux.exe asset not found in release $($release.tag_name)"
        }

        Write-Status "Downloading $($asset.name) from $($release.tag_name)..."
        Invoke-RestMethod -Uri $asset.browser_download_url -Headers $headers -OutFile $psmuxExe -ErrorAction Stop

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
                    $actualHash = (Get-FileHash $psmuxExe -Algorithm SHA256).Hash.ToUpperInvariant()
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

        $ver = (& $psmuxExe -V 2>&1 | Out-String).Trim()
        Write-Status "Installed psmux: $ver"
    } catch {
        Write-Error "[winsmux] Failed to install sora-psmux: $_"
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
    Write-Status "$label winsmux v$VERSION ..."

    # 1. PowerShell version check
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Warning "[winsmux] PowerShell 7+ is recommended. You are running $($PSVersionTable.PSVersion). Some features may not work correctly."
    }

    # 2. Administrator check
    if (Test-Administrator) {
        Write-Warning "[winsmux] Running as Administrator is not recommended. Consider running as a normal user."
    }

    # 3. psmux detection / install
    Install-Psmux

    # 4. Create directories
    foreach ($dir in @($WINSMUX_DIR, $BIN_DIR, $BACKUP_DIR, $SCRIPT_DIR, $BRIDGE_DIR, $BRIDGE_SCRIPTS_DIR, (Join-Path $env:APPDATA "winsmux"))) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # 5. Download & place files
    # psmux-bridge.ps1
    Download-File "scripts/psmux-bridge.ps1" (Join-Path $BIN_DIR "psmux-bridge.ps1")
    Download-File "scripts/psmux-bridge.ps1" (Join-Path $SCRIPT_DIR "psmux-bridge.ps1")

    # winsmux.ps1 CLI
    Download-File "winsmux.ps1" (Join-Path $BIN_DIR "winsmux.ps1")

    # Orchestra support scripts
    Download-File "psmux-bridge/scripts/orchestra-start.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-start.ps1")
    Download-File "psmux-bridge/scripts/orchestra-layout.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "orchestra-layout.ps1")
    Download-File "psmux-bridge/scripts/settings.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "settings.ps1")
    Download-File "psmux-bridge/scripts/vault.ps1" (Join-Path $BRIDGE_SCRIPTS_DIR "vault.ps1")

    # .psmux.conf (backup existing)
    $confDest = Join-Path $HOME ".psmux.conf"
    Backup-File $confDest
    Download-File ".psmux.conf" $confDest

    # 6. Create .cmd wrappers
    $bridgeCmd = Join-Path $BIN_DIR "psmux-bridge.cmd"
    @"
@echo off
pwsh -NoProfile -File "%USERPROFILE%\.winsmux\bin\psmux-bridge.ps1" %*
"@ | Set-Content -Path $bridgeCmd -Encoding ASCII

    $winsmuxCmd = Join-Path $BIN_DIR "winsmux.cmd"
    @"
@echo off
pwsh -NoProfile -File "%USERPROFILE%\.winsmux\bin\winsmux.ps1" %*
"@ | Set-Content -Path $winsmuxCmd -Encoding ASCII

    # 7.5. Register Windows Terminal Fragments
    $fragmentDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments\winsmux"
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
    $fragmentFile = Join-Path $fragmentDir "winsmux.json"
    $fragmentJson | Set-Content -Path $fragmentFile -Encoding UTF8
    Write-Status "Registered Windows Terminal fragment: $fragmentFile"

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

    # 10. Completion message
    if ($IsUpdate) {
        Write-Host ""
        Write-Status "Updated to v$VERSION!"
        Write-Host "  psmux-bridge: $(Join-Path $BIN_DIR 'psmux-bridge.ps1')"
        Write-Host "  psmux config:  $confDest"
    } else {
        Write-Host ""
        Write-Status "Installed successfully! (v$VERSION)"
        Write-Host "  psmux-bridge: $(Join-Path $BIN_DIR 'psmux-bridge.ps1')"
        Write-Host "  psmux config:  $confDest"
        Write-Host ""
        Write-Host "Next steps:"
        Write-Host "  1. Start a psmux session:  psmux new-session -s work"
        Write-Host "  2. Set your agent name:    `$env:WINSMUX_AGENT_NAME = 'claude'"
        Write-Host "  3. Try it out:             psmux-bridge list"
    }
}

function Invoke-Uninstall {
    Write-Status "Uninstalling winsmux..."

    # 1. Remove ~/.winsmux
    if (Test-Path $WINSMUX_DIR) {
        Remove-Item $WINSMUX_DIR -Recurse -Force
        Write-Status "Removed $WINSMUX_DIR"
    }

    # 2. Remove ~/.psmux.conf
    $confPath = Join-Path $HOME ".psmux.conf"
    if (Test-Path $confPath) {
        Write-Host "[winsmux] Remove $confPath ? (psmux config file)" -NoNewline
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

    # 6. Done (psmux itself is NOT uninstalled)
    Write-Host ""
    Write-Status "Uninstalled."
    Write-Host "  Note: psmux itself was NOT removed. Manage it separately if needed."
}

function Show-Help {
    Write-Host @"
Usage: install.ps1 [action]

Actions:
  install     Install winsmux (default)
  update      Update to latest version
  uninstall   Remove winsmux
  version     Show version
  help        Show this help
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
