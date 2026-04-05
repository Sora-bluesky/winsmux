$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-BuilderWorktreeGit {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & git -C $ProjectDir @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = 'unknown git error'
        }

        throw "git $($Arguments -join ' ') failed: $text"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $text
        Lines    = @($output)
    }
}

function Test-BuilderWorktreePathUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')

    if ([string]::Equals($fullPath, $fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $fullPath.StartsWith(
        $fullRoot + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function ConvertFrom-GitWorktreeList {
    param([AllowEmptyString()][string]$Content)

    $entries = [System.Collections.Generic.List[object]]::new()
    $current = [ordered]@{}

    foreach ($rawLine in ($Content -split "\r?\n")) {
        $line = $rawLine.Trim()

        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($current.Contains('worktree')) {
                $entries.Add([PSCustomObject]@{
                    WorktreePath = [string]$current.worktree
                    BranchName   = [string]$current.branch
                }) | Out-Null
            }

            $current = [ordered]@{}
            continue
        }

        if ($line -match '^worktree\s+(.+)$') {
            $current.worktree = $Matches[1]
            continue
        }

        if ($line -match '^branch\s+refs/heads/(.+)$') {
            $current.branch = $Matches[1]
            continue
        }
    }

    if ($current.Contains('worktree')) {
        $entries.Add([PSCustomObject]@{
            WorktreePath = [string]$current.worktree
            BranchName   = [string]$current.branch
        }) | Out-Null
    }

    return @($entries)
}

function Get-OrchestraBuilderWorktreeInventory {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $worktreeRoot = Join-Path $ProjectDir '.worktrees'
    $worktreeResult = Invoke-BuilderWorktreeGit -ProjectDir $ProjectDir -Arguments @('worktree', 'list', '--porcelain')
    $registered = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in (ConvertFrom-GitWorktreeList -Content $worktreeResult.Output)) {
        $leafName = Split-Path -Leaf $entry.WorktreePath
        $matchesManagedBranch = $entry.BranchName -match '^worktree-builder-\d+$'
        $matchesManagedPath =
            $leafName -match '^builder-\d+$' -and
            (Test-BuilderWorktreePathUnderRoot -Path $entry.WorktreePath -Root $worktreeRoot)

        if (-not $matchesManagedBranch -and -not $matchesManagedPath) {
            continue
        }

        $registered.Add([PSCustomObject]@{
            WorktreePath = [System.IO.Path]::GetFullPath($entry.WorktreePath)
            BranchName   = $entry.BranchName
        }) | Out-Null
    }

    $registeredPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $registered) {
        [void]$registeredPaths.Add($entry.WorktreePath)
    }

    $orphanDirectories = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $worktreeRoot -PathType Container) {
        foreach ($directory in (Get-ChildItem -LiteralPath $worktreeRoot -Directory -Filter 'builder-*')) {
            if ($registeredPaths.Contains($directory.FullName)) {
                continue
            }

            $orphanDirectories.Add($directory.FullName) | Out-Null
        }
    }

    $branchResult = Invoke-BuilderWorktreeGit -ProjectDir $ProjectDir -Arguments @('branch', '--list', '--format', '%(refname:short)', 'worktree-builder-*')
    $registeredBranches = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $registered) {
        if (-not [string]::IsNullOrWhiteSpace($entry.BranchName)) {
            [void]$registeredBranches.Add($entry.BranchName)
        }
    }

    $orphanBranches = [System.Collections.Generic.List[string]]::new()
    foreach ($branch in @($branchResult.Lines | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })) {
        if ($registeredBranches.Contains($branch)) {
            continue
        }

        $orphanBranches.Add($branch) | Out-Null
    }

    return [PSCustomObject]@{
        RegisteredWorktrees = @($registered)
        OrphanDirectories   = @($orphanDirectories)
        OrphanBranches      = @($orphanBranches)
    }
}

function Invoke-StaleBuilderWorktreeCleanup {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $worktreeRoot = Join-Path $ProjectDir '.worktrees'
    $resolvedProjectDir = [System.IO.Path]::GetFullPath($ProjectDir).TrimEnd('\', '/')

    Invoke-BuilderWorktreeGit -ProjectDir $ProjectDir -Arguments @('worktree', 'prune') | Out-Null
    $inventory = Get-OrchestraBuilderWorktreeInventory -ProjectDir $ProjectDir

    $removedWorktreePaths = [System.Collections.Generic.List[string]]::new()
    $removedDirectoryPaths = [System.Collections.Generic.List[string]]::new()
    $removedBranches = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($inventory.RegisteredWorktrees | Sort-Object WorktreePath -Unique)) {
        $worktreePath = [System.IO.Path]::GetFullPath($entry.WorktreePath)
        if ([string]::Equals($worktreePath.TrimEnd('\', '/'), $resolvedProjectDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if (-not (Test-BuilderWorktreePathUnderRoot -Path $worktreePath -Root $worktreeRoot)) {
            throw "Refusing to remove Builder worktree outside ${worktreeRoot}: $worktreePath"
        }

        if (Test-Path -LiteralPath $worktreePath -PathType Container) {
            Invoke-BuilderWorktreeGit -ProjectDir $ProjectDir -Arguments @('worktree', 'remove', '--force', $worktreePath) | Out-Null
            $removedWorktreePaths.Add($worktreePath) | Out-Null
        }

        if (-not [string]::IsNullOrWhiteSpace($entry.BranchName)) {
            $deleteResult = Invoke-BuilderWorktreeGit -ProjectDir $ProjectDir -Arguments @('branch', '-D', $entry.BranchName) -AllowFailure
            if ($deleteResult.ExitCode -eq 0) {
                $removedBranches.Add($entry.BranchName) | Out-Null
            }
        }
    }

    foreach ($directoryPath in @($inventory.OrphanDirectories | Sort-Object -Unique)) {
        $resolvedDirectoryPath = [System.IO.Path]::GetFullPath($directoryPath)
        if (-not (Test-BuilderWorktreePathUnderRoot -Path $resolvedDirectoryPath -Root $worktreeRoot)) {
            throw "Refusing to remove stale Builder directory outside ${worktreeRoot}: $resolvedDirectoryPath"
        }

        if (Test-Path -LiteralPath $resolvedDirectoryPath -PathType Container) {
            Remove-Item -LiteralPath $resolvedDirectoryPath -Recurse -Force
            $removedDirectoryPaths.Add($resolvedDirectoryPath) | Out-Null
        }
    }

    foreach ($branchName in @($inventory.OrphanBranches | Sort-Object -Unique)) {
        $deleteResult = Invoke-BuilderWorktreeGit -ProjectDir $ProjectDir -Arguments @('branch', '-D', $branchName) -AllowFailure
        if ($deleteResult.ExitCode -eq 0) {
            $removedBranches.Add($branchName) | Out-Null
        }
    }

    return [PSCustomObject]@{
        RemovedWorktreePaths  = @($removedWorktreePaths)
        RemovedDirectoryPaths = @($removedDirectoryPaths)
        RemovedBranches       = @($removedBranches | Sort-Object -Unique)
    }
}
