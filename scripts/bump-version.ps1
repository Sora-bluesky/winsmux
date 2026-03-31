# bump-version.ps1 — Sync version across all winsmux files from VERSION (Single Source of Truth)
# Usage:
#   pwsh scripts/bump-version.ps1                  # Sync all files to VERSION file value
#   pwsh scripts/bump-version.ps1 -Version 0.9.0   # Set new version and sync all files

[CmdletBinding()]
param(
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$VersionFile = Join-Path $Root "VERSION"

# --- Resolve version ---
if ($Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        Write-Error "Invalid version format: '$Version'. Expected: X.Y.Z"
        exit 1
    }
    Set-Content -Path $VersionFile -Value $Version -NoNewline -Encoding UTF8
    Write-Host "[bump] VERSION file -> $Version"
} else {
    if (-not (Test-Path $VersionFile)) {
        Write-Error "VERSION file not found at $VersionFile"
        exit 1
    }
    $Version = (Get-Content $VersionFile -Raw).Trim()
    Write-Host "[bump] Reading VERSION file: $Version"
}

# --- Target files and their replacement patterns ---
$targets = @(
    @{
        Path    = Join-Path $Root "install.ps1"
        Pattern = '(\$VERSION\s*=\s*")[^"]*(")'
        Replace = "`${1}$Version`${2}"
    },
    @{
        Path    = Join-Path $Root "scripts\psmux-bridge.ps1"
        Pattern = '(\$VERSION\s*=\s*")[^"]*(")'
        Replace = "`${1}$Version`${2}"
    },
    @{
        Path    = Join-Path $Root "skills\winsmux\SKILL.md"
        Pattern = '(version:\s*")[^"]*(")'
        Replace = "`${1}$Version`${2}"
    },
    @{
        Path    = Join-Path $Root "skills\winsmux\references\psmux-bridge.md"
        Pattern = '(> Version:\s*)\S+'
        Replace = "`${1}$Version"
    }
)

# --- Apply replacements ---
$changed = 0
$synced  = 0

foreach ($t in $targets) {
    $relPath = [IO.Path]::GetRelativePath($Root, $t.Path)
    if (-not (Test-Path $t.Path)) {
        Write-Warning "[bump] SKIP $relPath (file not found)"
        continue
    }

    $content = Get-Content $t.Path -Raw
    $updated = $content -replace $t.Pattern, $t.Replace

    if ($updated -ne $content) {
        Set-Content -Path $t.Path -Value $updated -NoNewline -Encoding UTF8
        Write-Host "[bump] UPDATED $relPath"
        $changed++
    } else {
        Write-Host "[bump] OK      $relPath (already $Version)"
        $synced++
    }
}

# --- Summary ---
Write-Host ""
if ($changed -eq 0) {
    Write-Host "[bump] All $($targets.Count) files are in sync at v$Version" -ForegroundColor Green
} else {
    Write-Host "[bump] Updated $changed file(s), $synced already in sync." -ForegroundColor Yellow
}
