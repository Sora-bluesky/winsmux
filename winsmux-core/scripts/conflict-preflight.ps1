[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Invoke-WinsmuxGitProbe {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    Push-Location -LiteralPath $ProjectDir
    try {
        $global:LASTEXITCODE = 0
        $output = & git @Arguments 2>&1
        $exitCode = if (Test-Path Variable:\LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    } finally {
        Pop-Location
    }

    return [PSCustomObject][ordered]@{
        exit_code = $exitCode
        output    = ((@($output) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    }
}

function ConvertTo-WinsmuxConflictPathArray {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    return @(
        $Text -split "\r?\n" |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() }
    )
}

function Resolve-WinsmuxConflictPreflightRepoRoot {
    param([string]$ProjectDir)

    $resolvedProjectDir = if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
        (Get-Location).Path
    } else {
        $ProjectDir
    }

    if (-not (Test-Path -LiteralPath $resolvedProjectDir -PathType Container)) {
        throw "project directory not found: $resolvedProjectDir"
    }

    $repoResult = Invoke-WinsmuxGitProbe -ProjectDir $resolvedProjectDir -Arguments @('rev-parse', '--show-toplevel')
    if ($repoResult.exit_code -ne 0 -or [string]::IsNullOrWhiteSpace($repoResult.output)) {
        throw "git repository root could not be resolved from: $resolvedProjectDir"
    }

    return $repoResult.output
}

function Resolve-WinsmuxConflictCommit {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$Ref
    )

    $result = Invoke-WinsmuxGitProbe -ProjectDir $ProjectDir -Arguments @('rev-parse', '--verify', "$Ref`^{commit}")
    if ($result.exit_code -ne 0 -or [string]::IsNullOrWhiteSpace($result.output)) {
        throw "git ref could not be resolved: $Ref"
    }

    return $result.output
}

function Get-WinsmuxConflictPreflightPayload {
    param(
        [string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$LeftRef,
        [Parameter(Mandatory = $true)][string]$RightRef
    )

    $repoRoot = Resolve-WinsmuxConflictPreflightRepoRoot -ProjectDir $ProjectDir
    $leftSha = Resolve-WinsmuxConflictCommit -ProjectDir $repoRoot -Ref $LeftRef
    $rightSha = Resolve-WinsmuxConflictCommit -ProjectDir $repoRoot -Ref $RightRef

    $mergeBaseResult = Invoke-WinsmuxGitProbe -ProjectDir $repoRoot -Arguments @('merge-base', $LeftRef, $RightRef)
    if ($mergeBaseResult.exit_code -ne 0 -or [string]::IsNullOrWhiteSpace($mergeBaseResult.output)) {
        return [PSCustomObject][ordered]@{
            command              = 'conflict-preflight'
            status               = 'blocked'
            reason               = 'no_merge_base'
            project_dir          = $repoRoot
            left_ref             = $LeftRef
            right_ref            = $RightRef
            left_sha             = $leftSha
            right_sha            = $rightSha
            merge_base           = ''
            merge_tree_exit_code = $null
            conflict_detected    = $false
            overlap_paths        = @()
            left_only_paths      = @()
            right_only_paths     = @()
            next_action          = 'Choose related refs with a shared merge base and rerun winsmux conflict-preflight.'
        }
    }

    $mergeBase = $mergeBaseResult.output
    $leftPaths = ConvertTo-WinsmuxConflictPathArray -Text (Invoke-WinsmuxGitProbe -ProjectDir $repoRoot -Arguments @('diff', '--name-only', $mergeBase, $LeftRef)).output
    $rightPaths = ConvertTo-WinsmuxConflictPathArray -Text (Invoke-WinsmuxGitProbe -ProjectDir $repoRoot -Arguments @('diff', '--name-only', $mergeBase, $RightRef)).output

    $rightPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in $rightPaths) {
        [void]$rightPathSet.Add([string]$path)
    }

    $leftPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in $leftPaths) {
        [void]$leftPathSet.Add([string]$path)
    }

    $overlapPaths = [System.Collections.Generic.List[string]]::new()
    $leftOnlyPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $leftPaths) {
        if ($rightPathSet.Contains([string]$path)) {
            $overlapPaths.Add([string]$path) | Out-Null
        } else {
            $leftOnlyPaths.Add([string]$path) | Out-Null
        }
    }

    $rightOnlyPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $rightPaths) {
        if (-not $leftPathSet.Contains([string]$path)) {
            $rightOnlyPaths.Add([string]$path) | Out-Null
        }
    }

    $mergeTreeResult = Invoke-WinsmuxGitProbe -ProjectDir $repoRoot -Arguments @('merge-tree', '--write-tree', '--quiet', $LeftRef, $RightRef)
    $status = 'blocked'
    $reason = 'merge_tree_failed'
    $conflictDetected = $false
    $nextAction = 'Inspect git merge-tree output and rerun winsmux conflict-preflight.'
    switch ([int]$mergeTreeResult.exit_code) {
        0 {
            $status = 'clean'
            $reason = ''
            $nextAction = 'Safe to continue to compare UI or follow-up review.'
        }
        1 {
            $status = 'conflict'
            $reason = 'merge_conflict'
            $conflictDetected = $true
            $nextAction = 'Inspect overlap paths before compare or merge.'
        }
    }

    return [PSCustomObject][ordered]@{
        command              = 'conflict-preflight'
        status               = $status
        reason               = $reason
        project_dir          = $repoRoot
        left_ref             = $LeftRef
        right_ref            = $RightRef
        left_sha             = $leftSha
        right_sha            = $rightSha
        merge_base           = $mergeBase
        merge_tree_exit_code = [int]$mergeTreeResult.exit_code
        conflict_detected    = $conflictDetected
        overlap_paths        = @($overlapPaths)
        left_only_paths      = @($leftOnlyPaths)
        right_only_paths     = @($rightOnlyPaths)
        next_action          = $nextAction
    }
}
