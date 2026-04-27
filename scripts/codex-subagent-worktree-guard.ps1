[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$WorktreePath = '',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory = $true)][string]$Cwd,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = & git -C $Cwd @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output | ForEach-Object { [string]$_ }) -join "`n")
    }

    return (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Convert-GitPathToFullPath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$GitPath
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($GitPath.Trim())
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $expanded))
}

function New-GuardResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Ok,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$WorktreeRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RepoRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$GitDir,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CommonGitDir
    )

    [PSCustomObject]@{
        ok             = $Ok
        reason         = $Reason
        worktree_root  = $WorktreeRoot
        repo_root      = $RepoRoot
        git_dir        = $GitDir
        common_git_dir = $CommonGitDir
    }
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$defaultRepoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot '..'))
$resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $defaultRepoRoot
} else {
    Resolve-FullPath -Path $RepoRoot
}

$targetPath = if ([string]::IsNullOrWhiteSpace($WorktreePath)) {
    (Get-Location).Path
} else {
    $WorktreePath
}
$resolvedTargetPath = Resolve-FullPath -Path $targetPath

try {
    $worktreeRoot = Convert-GitPathToFullPath -BasePath $resolvedTargetPath -GitPath (Invoke-GitText -Cwd $resolvedTargetPath -Arguments @('rev-parse', '--show-toplevel'))
    $gitDir = Convert-GitPathToFullPath -BasePath $worktreeRoot -GitPath (Invoke-GitText -Cwd $resolvedTargetPath -Arguments @('rev-parse', '--git-dir'))
    $commonGitDir = Convert-GitPathToFullPath -BasePath $worktreeRoot -GitPath (Invoke-GitText -Cwd $resolvedTargetPath -Arguments @('rev-parse', '--git-common-dir'))
} catch {
    $result = New-GuardResult -Ok $false -Reason ("git metadata probe failed: {0}" -f $_.Exception.Message) -WorktreeRoot '' -RepoRoot $resolvedRepoRoot -GitDir '' -CommonGitDir ''
    if ($Json) {
        $result | ConvertTo-Json -Depth 4
    } else {
        Write-Error $result.reason
    }
    exit 1
}

$isLinkedWorktree = ($gitDir -ne $commonGitDir)
$isSharedOperatorCheckout = ($worktreeRoot -eq $resolvedRepoRoot)

if ($isSharedOperatorCheckout -or -not $isLinkedWorktree) {
    $reason = 'Codex implementation subagents must not write in the shared operator checkout. Create or select a dedicated git worktree before spawning a write-capable subagent. See issue #666.'
    $result = New-GuardResult -Ok $false -Reason $reason -WorktreeRoot $worktreeRoot -RepoRoot $resolvedRepoRoot -GitDir $gitDir -CommonGitDir $commonGitDir
    if ($Json) {
        $result | ConvertTo-Json -Depth 4
    } else {
        Write-Error $reason
    }
    exit 1
}

$result = New-GuardResult -Ok $true -Reason 'dedicated git worktree confirmed' -WorktreeRoot $worktreeRoot -RepoRoot $resolvedRepoRoot -GitDir $gitDir -CommonGitDir $commonGitDir
if ($Json) {
    $result | ConvertTo-Json -Depth 4
} else {
    Write-Output ("Codex subagent worktree guard passed: {0}" -f $worktreeRoot)
}
