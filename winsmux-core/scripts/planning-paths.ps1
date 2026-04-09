[CmdletBinding()]
param()

function Get-WinsmuxPlanningRootMarkerPath {
    $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('LocalApplicationData') }
    return Join-Path $localAppData 'winsmux\planning-root.txt'
}

function Get-WinsmuxPlanningRootFromMarker {
    $markerPath = Get-WinsmuxPlanningRootMarkerPath
    if (-not (Test-Path -LiteralPath $markerPath)) {
        return $null
    }

    try {
        $markerValue = (Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop).Trim()
        if (-not [string]::IsNullOrWhiteSpace($markerValue)) {
            return $markerValue
        }
    } catch {
        return $null
    }

    return $null
}

function Find-WinsmuxPlanningRoot {
    param([Parameter(Mandatory = $true)][string]$UserProfile)

    try {
        $backlogFiles = Get-ChildItem -LiteralPath $UserProfile -Filter 'backlog.yaml' -File -Recurse -Depth 8 -ErrorAction SilentlyContinue
        foreach ($file in $backlogFiles) {
            $directory = $file.DirectoryName
            if ([string]::IsNullOrWhiteSpace($directory)) {
                continue
            }

            if ($directory -notmatch '[\\/]winsmux[\\/]planning$') {
                continue
            }

            if (Test-Path -LiteralPath (Join-Path $directory 'ROADMAP.md')) {
                return $directory
            }
        }
    } catch {
        return $null
    }

    return $null
}

function Get-WinsmuxDefaultPlanningRoot {
    $cachedPlanningRoot = $null
    $cachedVariable = Get-Variable -Scope Script -Name WinsmuxDefaultPlanningRoot -ErrorAction SilentlyContinue
    if ($cachedVariable) {
        $cachedPlanningRoot = [string]$cachedVariable.Value
    }

    if (-not [string]::IsNullOrWhiteSpace($cachedPlanningRoot)) {
        return $cachedPlanningRoot
    }

    $userProfile = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
    $markerRoot = Get-WinsmuxPlanningRootFromMarker
    if (-not [string]::IsNullOrWhiteSpace($markerRoot)) {
        $script:WinsmuxDefaultPlanningRoot = $markerRoot
        return $script:WinsmuxDefaultPlanningRoot
    }

    $discoveredRoot = Find-WinsmuxPlanningRoot -UserProfile $userProfile
    if (-not [string]::IsNullOrWhiteSpace($discoveredRoot)) {
        $script:WinsmuxDefaultPlanningRoot = $discoveredRoot
        return $script:WinsmuxDefaultPlanningRoot
    }

    $script:WinsmuxDefaultPlanningRoot = Join-Path $userProfile '.winsmux\planning'
    return $script:WinsmuxDefaultPlanningRoot
}

function Get-WinsmuxPlanningRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_PLANNING_ROOT)) {
        return $env:WINSMUX_PLANNING_ROOT
    }

    return Get-WinsmuxDefaultPlanningRoot
}

function Resolve-WinsmuxPlanningFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$LocalRelativePath,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentVariable,

        [Parameter(Mandatory = $true)]
        [string]$DefaultFileName
    )

    $explicitPath = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
    if (-not [string]::IsNullOrWhiteSpace($explicitPath)) {
        return $explicitPath
    }

    $externalPath = Join-Path (Get-WinsmuxPlanningRoot) $DefaultFileName
    $localPath = Join-Path $RepoRoot $LocalRelativePath

    if ((Test-Path -LiteralPath $externalPath) -or -not (Test-Path -LiteralPath $localPath)) {
        return $externalPath
    }

    return $localPath
}
