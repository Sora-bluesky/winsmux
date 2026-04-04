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
$BacklogPath = Join-Path $Root "tasks\backlog.yaml"
$RoadmapPath = Join-Path $Root "docs\project\ROADMAP.md"
$SyncRoadmapScript = Join-Path $Root "psmux-bridge\scripts\sync-roadmap.ps1"

function ConvertFrom-QuotedYamlScalar {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    $trimmed = $Value.Trim()
    if ($trimmed.Length -ge 2) {
        if (($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))) {
            return $trimmed.Substring(1, $trimmed.Length - 2)
        }
    }

    return $trimmed
}

function Update-ReleaseBacklogStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if (-not (Test-Path $Path)) {
        return @()
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $content = [System.IO.File]::ReadAllText($Path, $utf8NoBom)
    $matches = [regex]::Matches($content, '(?ms)^[ \t]*-[ \t]+id:[ \t]*(?<id>TASK-\d+)[ \t]*\r?\n(?<body>.*?)(?=^[ \t]*-[ \t]+id:[ \t]*TASK-\d+[ \t]*\r?\n|\z)')
    if ($matches.Count -eq 0) {
        return @()
    }

    $releaseTag = "v$Version"
    $today = Get-Date -Format 'yyyy-MM-dd'
    $updatedTaskIds = New-Object System.Collections.Generic.List[string]
    $builder = New-Object System.Text.StringBuilder
    $cursor = 0

    foreach ($match in $matches) {
        [void]$builder.Append($content.Substring($cursor, $match.Index - $cursor))

        $taskBlock = $match.Value
        $taskId = $match.Groups['id'].Value
        $taskBody = $match.Groups['body'].Value

        $title = ''
        if ($taskBody -match '(?m)^[ \t]*title:[ \t]*(?<value>.+)$') {
            $title = ConvertFrom-QuotedYamlScalar -Value $Matches['value']
        }

        $status = ''
        if ($taskBody -match '(?m)^[ \t]*status:[ \t]*(?<value>[^\r\n#]+)') {
            $status = $Matches['value'].Trim()
        }

        $labels = ''
        if ($taskBody -match '(?m)^[ \t]*labels:[ \t]*\[(?<value>[^\]]*)\]') {
            $labels = $Matches['value']
        }

        $targetVersion = ''
        if ($taskBody -match '(?m)^[ \t]*target_version:[ \t]*(?<value>[^\r\n#]+)') {
            $targetVersion = ($Matches['value'].Trim() -replace '^["'']|["'']$', '')
        }
        $isReleaseTask = ($targetVersion -eq $releaseTag) -or ($targetVersion -eq $Version)

        if ($isReleaseTask -and $status -notin @('done', 'cancelled')) {
            $updatedTaskBlock = $taskBlock -replace '(?m)^(\s*)status:\s*[^\r\n]*$', '${1}status: done'
            if ($updatedTaskBlock -match '(?m)^(\s*)updated:\s*[^\r\n]*$') {
                $updatedTaskBlock = $updatedTaskBlock -replace '(?m)^(\s*)updated:\s*[^\r\n]*$', ('${1}updated: "' + $today + '"')
            } else {
                $lineEnding = if ($updatedTaskBlock -match "`r`n") { "`r`n" } else { "`n" }
                $updatedTaskBlock = $updatedTaskBlock.TrimEnd("`r", "`n") + $lineEnding + '    updated: "' + $today + '"' + $lineEnding
            }

            $taskBlock = $updatedTaskBlock
            $updatedTaskIds.Add($taskId)
        }

        [void]$builder.Append($taskBlock)
        $cursor = $match.Index + $match.Length
    }

    [void]$builder.Append($content.Substring($cursor))

    if ($updatedTaskIds.Count -gt 0) {
        [System.IO.File]::WriteAllText($Path, $builder.ToString(), $utf8NoBom)
    }

    return @($updatedTaskIds.ToArray())
}

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

# --- Release requires backlog + roadmap assets ---
if ($DoRelease) {
    $requiredPaths = @($BacklogPath, $RoadmapPath, $SyncRoadmapScript)
    $missingPaths = @(
        $requiredPaths |
            Where-Object { -not (Test-Path $_) } |
            ForEach-Object { [IO.Path]::GetRelativePath($Root, $_) }
    )

    if ($missingPaths.Count -gt 0) {
        Write-Error "[release] Preflight failed. Missing required files: $($missingPaths -join ', ')"
        exit 1
    }
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

    # Stage and commit (filter to existing files only — #154)
    $filesToAdd = @("VERSION", "install.ps1", "scripts/psmux-bridge.ps1", "skills/winsmux/SKILL.md", "skills/winsmux/references/psmux-bridge.md")
    $existingFiles = $filesToAdd | Where-Object { Test-Path (Join-Path $Root $_) }
    if ($existingFiles) { git add $existingFiles }

    # Sync ROADMAP from backlog
    & pwsh $SyncRoadmapScript -BacklogPath $BacklogPath -RoadmapPath $RoadmapPath
    if ($LASTEXITCODE -ne 0) {
        throw "ROADMAP sync failed."
    }
    if (Test-Path $RoadmapPath) { git add -f $RoadmapPath }
    Write-Host "[release] ROADMAP synced"

    git commit -m "chore: bump version to $Version"
    Write-Host "[release] Committed"

    # Push branch
    git push -u origin $branch
    Write-Host "[release] Pushed branch"

    # Create and merge PR
    $prUrl = gh pr create --title "chore: bump version to $Version" --body "Automated release via ``bump-version.ps1 -Version $Version``" --head $branch
    Write-Host "[release] PR created: $prUrl"

    # Extract PR number and merge via verify gate
    $prNumber = if ($prUrl -match '/(\d+)$') { $Matches[1] } else { $prUrl }
    $bridgeScript = Join-Path $PSScriptRoot "psmux-bridge.ps1"
    & pwsh $bridgeScript verify $prNumber
    Write-Host "[release] PR merged (verified)"

    # Switch back to main and pull
    git checkout main
    git pull origin main --rebase
    Write-Host "[release] Main updated"

    # Tag the merge commit and push
    git tag "v$Version"
    git push origin "v$Version"
    Write-Host "[release] Tagged v$Version"

    # GitHub Release
    gh release create "v$Version" --title "v$Version" --generate-notes --latest
    Write-Host "[release] GitHub Release created" -ForegroundColor Green

    # Close the release task in backlog and refresh ROADMAP.
    $updatedTaskIds = Update-ReleaseBacklogStatus -Path $BacklogPath -Version $Version
    if ($updatedTaskIds.Count -gt 0) {
        Write-Host "[release] Backlog updated: $($updatedTaskIds -join ', ')"
        & pwsh $SyncRoadmapScript -BacklogPath $BacklogPath -RoadmapPath $RoadmapPath
        if ($LASTEXITCODE -ne 0) {
            throw "ROADMAP sync failed after backlog update."
        }
        Write-Host "[release] ROADMAP refreshed after backlog update"

        git add -- "tasks/backlog.yaml" "docs/project/ROADMAP.md"
        git diff --cached --quiet -- "tasks/backlog.yaml" "docs/project/ROADMAP.md"
        if ($LASTEXITCODE -ne 0) {
            git commit -m "chore: close release task for $Version"
            git push origin main
            Write-Host "[release] Backlog status committed"
        } else {
            Write-Host "[release] Backlog files already up to date"
        }
    } else {
        Write-Warning "[release] No matching release task found in tasks/backlog.yaml for v$Version"
    }

    Write-Host ""
    Write-Host "[release] Done! https://github.com/Sora-bluesky/winsmux/releases/tag/v$Version" -ForegroundColor Green
} catch {
    Write-Error "[release] Failed: $_"
    Pop-Location
    exit 1
} finally {
    Pop-Location
}
