# bump-version.ps1 — Sync version across all winsmux files from VERSION (Single Source of Truth)
# Usage:
#   pwsh scripts/bump-version.ps1                            # Sync all files to VERSION file value
#   pwsh scripts/bump-version.ps1 -Version 0.9.0             # Bump + commit + tag + push + GitHub Release (DEFAULT)
#   pwsh scripts/bump-version.ps1 -Version 0.9.0 -SyncOnly   # Only sync files, no release flow

[CmdletBinding()]
param(
    [string]$Version,
    [switch]$SyncOnly
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$VersionFile = Join-Path $Root "VERSION"

# --- Determine if release flow is active ---
# Release is the DEFAULT when -Version is specified. Use -SyncOnly to suppress.
$DoRelease = $Version -and -not $SyncOnly

# --- Release requires gh CLI ---
if ($DoRelease) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Error "GitHub CLI (gh) is required for release. Install: winget install GitHub.cli"
        exit 1
    }
}

# --- Release requires clean working tree ---
if ($DoRelease) {
    Push-Location $Root
    $status = git status --porcelain 2>&1
    if ($status) {
        Write-Error "Working tree is not clean. Commit or stash changes before releasing."
        Pop-Location
        exit 1
    }
    Pop-Location
}

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

# --- Release flow ---
if (-not $DoRelease) { return }

Write-Host ""
Write-Host "[release] Starting release flow for v$Version ..." -ForegroundColor Cyan

Push-Location $Root
try {
    $branch = "release/v$Version"

    # Create release branch
    git checkout -b $branch
    Write-Host "[release] Created branch $branch"

    # Stage and commit
    $filesToAdd = @("VERSION", "install.ps1", "scripts/psmux-bridge.ps1", "skills/winsmux/SKILL.md", "skills/winsmux/references/psmux-bridge.md")
    git add $filesToAdd
    git commit -m "chore: bump version to $Version"
    Write-Host "[release] Committed"

    # Push branch
    git push -u origin $branch
    Write-Host "[release] Pushed branch"

    # Create and merge PR
    $prUrl = gh pr create --title "chore: bump version to $Version" --body "Automated release via ``bump-version.ps1 -Version $Version``" --head $branch
    Write-Host "[release] PR created: $prUrl"

    gh pr merge $prUrl --squash --delete-branch
    Write-Host "[release] PR merged"

    # Switch back to main and pull
    git checkout main
    git pull origin main
    Write-Host "[release] Main updated"

    # Tag the merge commit and push
    git tag "v$Version"
    git push origin "v$Version"
    Write-Host "[release] Tagged v$Version"

    # GitHub Release
    gh release create "v$Version" --title "v$Version" --generate-notes --latest
    Write-Host "[release] GitHub Release created" -ForegroundColor Green

    Write-Host ""
    Write-Host "[release] Done! https://github.com/Sora-bluesky/winsmux/releases/tag/v$Version" -ForegroundColor Green
} catch {
    Write-Error "[release] Failed: $_"
    Pop-Location
    exit 1
} finally {
    Pop-Location
}
