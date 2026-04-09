[CmdletBinding()]
param()

function Get-WinsmuxDefaultPlanningRoot {
    $userProfile = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
    return Join-Path $userProfile 'iCloudDrive\iCloud~md~obsidian\MainVault\Projects\winsmux\planning'
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
