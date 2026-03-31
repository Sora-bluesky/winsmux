# install.ps1 — winsmux one-command installer
# Usage: irm https://raw.githubusercontent.com/Sora-bluesky/winsmux/main/install.ps1 | iex
# Or: pwsh install.ps1 [install|update|uninstall|version|help]

[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Action = "install"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$VERSION      = "0.8.5"
$WINSMUX_DIR  = Join-Path $HOME ".winsmux"
$BIN_DIR      = Join-Path $WINSMUX_DIR "bin"
$BACKUP_DIR   = Join-Path $WINSMUX_DIR "backups"
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
    Write-Status "psmux not found. Attempting auto-install..."

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Status "Installing via winget..."
        winget install psmux --accept-package-agreements --accept-source-agreements
        return
    }
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Status "Installing via scoop..."
        scoop bucket add psmux https://github.com/psmux/scoop-psmux 2>$null
        scoop install psmux
        return
    }
    if (Get-Command cargo -ErrorAction SilentlyContinue) {
        Write-Status "Installing via cargo..."
        cargo install psmux
        return
    }
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Status "Installing via chocolatey..."
        choco install psmux -y
        return
    }
    Write-Error "[winsmux] Could not install psmux. Install manually: https://github.com/psmux/psmux"
    exit 1
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
    foreach ($dir in @($WINSMUX_DIR, $BIN_DIR, $BACKUP_DIR, (Join-Path $env:APPDATA "winsmux"))) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # 5. Download & place files
    # psmux-bridge.ps1
    Download-File "scripts/psmux-bridge.ps1" (Join-Path $BIN_DIR "psmux-bridge.ps1")

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

    # 7. Create winsmux.ps1 CLI wrapper
    $winsmuxPs1 = Join-Path $BIN_DIR "winsmux.ps1"
    @'
# winsmux.ps1 — winsmux CLI wrapper
param([Parameter(Position=0)][string]$Action = "help")
$installer = "https://raw.githubusercontent.com/Sora-bluesky/winsmux/main/install.ps1"
switch ($Action) {
    "update"    { Invoke-RestMethod $installer | Invoke-Expression }
    "uninstall" { & pwsh -Command "& { $(Invoke-RestMethod $installer) } uninstall" }
    "version"   { Get-Content "$HOME\.winsmux\version" -ErrorAction SilentlyContinue }
    default     {
        Write-Host "winsmux — Windows terminal multiplexer for AI agents"
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  winsmux update      Update winsmux to latest"
        Write-Host "  winsmux uninstall   Remove winsmux"
        Write-Host "  winsmux version     Show version"
    }
}
'@ | Set-Content -Path $winsmuxPs1 -Encoding UTF8

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
      "commandline": "pwsh -NoProfile -Command \"& '%USERPROFILE%\\.winsmux\\bin\\psmux-bridge.ps1' doctor; psmux new-session -s orchestra; pwsh '%USERPROFILE%\\.winsmux\\bin\\start-orchestra.ps1'\"",
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
