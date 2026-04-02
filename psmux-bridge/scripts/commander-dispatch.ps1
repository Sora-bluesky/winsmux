Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CommanderDispatchSettingsScriptPath = Join-Path $PSScriptRoot 'settings.ps1'
. $script:CommanderDispatchSettingsScriptPath

$script:ActiveWorktrees = @{}
$script:CommanderDispatchBridgeScriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\psmux-bridge.ps1'))
$script:CommanderDispatchProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Get-CommanderDispatchPsmuxBin {
    foreach ($candidate in @('psmux', 'pmux', 'tmux')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            if ($command.Path) {
                return $command.Path
            }

            return $command.Name
        }
    }

    throw 'Could not find a psmux binary. Tried: psmux, pmux, tmux.'
}

function ConvertTo-CommanderDispatchPowerShellLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-CommanderDispatchGitArgs {
    param([Parameter(Mandatory)][string[]]$Arguments)

    return @('-c', "safe.directory=$script:CommanderDispatchProjectRoot") + $Arguments
}

function Invoke-CommanderDispatchGit {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$CaptureOutput,
        [string]$WorkingDirectory = $script:CommanderDispatchProjectRoot
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        $gitArgs = Get-CommanderDispatchGitArgs -Arguments $Arguments
        if ($CaptureOutput) {
            $output = & git @gitArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                $message = ($output | Out-String).Trim()
                if ([string]::IsNullOrWhiteSpace($message)) {
                    $message = "git $($Arguments -join ' ') failed"
                }

                throw $message
            }

            return $output
        }

        & git @gitArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}

function Invoke-CommanderDispatchBridge {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$CaptureOutput
    )

    if ($CaptureOutput) {
        $output = & pwsh -NoProfile -File $script:CommanderDispatchBridgeScriptPath @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            $message = ($output | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = "psmux-bridge $($Arguments -join ' ') failed"
            }

            throw $message
        }

        return ($output | Out-String).TrimEnd()
    }

    & pwsh -NoProfile -File $script:CommanderDispatchBridgeScriptPath @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "psmux-bridge $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Get-CommanderDispatchGitWorktreeDir {
    param([Parameter(Mandatory)][string]$ProjectDir)

    $dotGitPath = Join-Path $ProjectDir '.git'

    if (Test-Path $dotGitPath -PathType Leaf) {
        $raw = (Get-Content -Path $dotGitPath -Raw -Encoding UTF8).Trim()
        if ($raw -match '^gitdir:\s*(.+)$') {
            return [System.IO.Path]::GetFullPath($Matches[1].Trim())
        }
    }

    if (Test-Path $dotGitPath -PathType Container) {
        return (Get-Item -LiteralPath $dotGitPath).FullName
    }

    return $ProjectDir
}

function Get-CommanderDispatchBranchName {
    param(
        [Parameter(Mandatory)][string]$BuilderName,
        [Parameter(Mandatory)][string]$TaskId
    )

    return '{0}/{1}' -f $BuilderName.Trim(), $TaskId.Trim()
}

function Resolve-CommanderDispatchPaneId {
    param([Parameter(Mandatory)][string]$Target)

    if ($Target -match '^%') {
        return $Target
    }

    $resolved = Invoke-CommanderDispatchBridge -Arguments @('resolve', $Target) -CaptureOutput
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "Could not resolve pane for '$Target'."
    }

    return ($resolved -split '\r?\n' | Select-Object -Last 1).Trim()
}

function Get-CommanderDispatchPendingPaths {
    param([Parameter(Mandatory)][string]$WorktreePath)

    $statusLines = Invoke-CommanderDispatchGit -WorkingDirectory $WorktreePath -Arguments @('-C', $WorktreePath, 'status', '--porcelain') -CaptureOutput
    $paths = [System.Collections.Generic.List[string]]::new()

    foreach ($line in @($statusLines)) {
        $text = [string]$line
        if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -lt 4) {
            continue
        }

        $payload = $text.Substring(3).Trim()
        if ([string]::IsNullOrWhiteSpace($payload)) {
            continue
        }

        $parts = $payload -split '\s+->\s+'
        $candidate = $parts[$parts.Count - 1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $paths.Add($candidate)
        }
    }

    return @($paths | Sort-Object -Unique)
}

function Copy-CommanderDispatchPath {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $destinationParent = Split-Path -Parent $DestinationPath
    if (-not [string]::IsNullOrWhiteSpace($destinationParent) -and -not (Test-Path -LiteralPath $destinationParent)) {
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    }

    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
}

function Get-CommanderDispatchFilesToCollect {
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string[]]$PendingPaths
    )

    $files = [System.Collections.Generic.List[string]]::new()

    foreach ($relativePath in $PendingPaths) {
        $sourcePath = Join-Path $WorktreePath $relativePath
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            $files.Add($sourcePath)
            continue
        }

        if (Test-Path -LiteralPath $sourcePath -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $sourcePath -Recurse -File) {
                $files.Add($file.FullName)
            }
        }
    }

    return @($files | Sort-Object -Unique)
}

function New-BuilderWorktree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$BuilderName
    )

    $worktreePath = [System.IO.Path]::GetFullPath((Join-Path $script:CommanderDispatchProjectRoot "..\winsmux-$BuilderName"))
    $branchName = Get-CommanderDispatchBranchName -BuilderName $BuilderName -TaskId $TaskId

    if (Test-Path -LiteralPath $worktreePath) {
        throw "Worktree path already exists: $worktreePath"
    }

    Invoke-CommanderDispatchGit -Arguments @('worktree', 'add', '-b', $branchName, $worktreePath, 'HEAD')

    $script:ActiveWorktrees[$worktreePath] = [ordered]@{
        taskId       = $TaskId
        builderName  = $BuilderName
        branch       = $branchName
        paneId       = $null
        dispatchAt   = $null
        collected    = $false
        promptFile   = $null
        collectedAt  = $null
        collectedFiles = @()
        reviewerPane = $null
    }

    return $worktreePath
}

function Invoke-BuilderTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$PromptFile,
        [string]$Model = 'gpt-5.4'
    )

    if (-not $script:ActiveWorktrees.ContainsKey($WorktreePath)) {
        throw "Worktree is not registered: $WorktreePath"
    }

    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
        throw "Prompt file not found: $PromptFile"
    }

    $entry = $script:ActiveWorktrees[$WorktreePath]
    $paneId = Resolve-CommanderDispatchPaneId -Target ([string]$entry.builderName)
    $gitWorktreeDir = Get-CommanderDispatchGitWorktreeDir -ProjectDir $script:CommanderDispatchProjectRoot
    $launchCommand = "codex exec --model $Model -C $(ConvertTo-CommanderDispatchPowerShellLiteral -Value $WorktreePath) --add-dir $(ConvertTo-CommanderDispatchPowerShellLiteral -Value $gitWorktreeDir) --file $(ConvertTo-CommanderDispatchPowerShellLiteral -Value ([System.IO.Path]::GetFullPath($PromptFile)))"

    Invoke-CommanderDispatchBridge -Arguments @('send', $paneId, $launchCommand)

    $entry.paneId = $paneId
    $entry.dispatchAt = Get-Date
    $entry.promptFile = [System.IO.Path]::GetFullPath($PromptFile)
    $entry.collected = $false
    $entry.collectedAt = $null
    $entry.collectedFiles = @()
    $script:ActiveWorktrees[$WorktreePath] = $entry

    return [PSCustomObject]@{
        WorktreePath = $WorktreePath
        PaneId       = $paneId
        DispatchAt   = $entry.dispatchAt
        Command      = $launchCommand
    }
}

function Wait-BuilderCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PaneId,
        [int]$TimeoutSeconds = 600
    )

    $psmux = Get-CommanderDispatchPsmuxBin
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $snapshot = & $psmux capture-pane -t $PaneId -p -J -S '-120' 2>$null
        $text = ($snapshot | Out-String).TrimEnd()

        if ($text -match '(?im)tokens used' -or $text -match '(?m)^PS [A-Z]:\\.*>\s*$') {
            return $true
        }

        Start-Sleep -Seconds 5
    }

    return $false
}

function Collect-BuilderResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not $script:ActiveWorktrees.ContainsKey($WorktreePath)) {
        throw "Worktree is not registered: $WorktreePath"
    }

    $pendingPaths = Get-CommanderDispatchPendingPaths -WorktreePath $WorktreePath
    $collectedFiles = [System.Collections.Generic.List[string]]::new()

    $sourceFiles = Get-CommanderDispatchFilesToCollect -WorktreePath $WorktreePath -PendingPaths $pendingPaths

    foreach ($sourcePath in $sourceFiles) {
        $relativePath = [System.IO.Path]::GetRelativePath($WorktreePath, $sourcePath)
        $destinationFile = Join-Path $DestinationPath $relativePath
        Copy-CommanderDispatchPath -SourcePath $sourcePath -DestinationPath $destinationFile

        if (-not (Test-Path -LiteralPath $destinationFile -PathType Leaf)) {
            throw "Collected file verification failed: $destinationFile"
        }

        $collectedFiles.Add($destinationFile)
    }

    $entry = $script:ActiveWorktrees[$WorktreePath]
    $entry.collected = $true
    $entry.collectedAt = Get-Date
    $entry.collectedFiles = @($collectedFiles)
    $script:ActiveWorktrees[$WorktreePath] = $entry

    return @($collectedFiles)
}

function Remove-BuilderWorktree {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorktreePath)

    if (-not $script:ActiveWorktrees.ContainsKey($WorktreePath)) {
        throw "Worktree is not registered: $WorktreePath"
    }

    $entry = $script:ActiveWorktrees[$WorktreePath]
    if (-not [bool]$entry.collected) {
        Write-Error 'Cannot remove worktree: results not collected' -ErrorAction Continue
        return
    }

    $branchName = [string]$entry.branch
    Invoke-CommanderDispatchGit -Arguments @('worktree', 'remove', '--force', $WorktreePath)
    Invoke-CommanderDispatchGit -Arguments @('branch', '-D', $branchName)
    $null = $script:ActiveWorktrees.Remove($WorktreePath)
}

function Invoke-ReviewerCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewerPane,
        [Parameter(Mandatory)][string]$WorktreePath,
        [string[]]$CollectedFiles = @(),
        [int]$TimeoutSeconds = 600
    )

    $relativeFiles = @(
        $CollectedFiles |
            ForEach-Object {
                try {
                    Resolve-Path -LiteralPath $_ -ErrorAction Stop | ForEach-Object {
                        [System.IO.Path]::GetRelativePath($script:CommanderDispatchProjectRoot, $_.ProviderPath)
                    }
                } catch {
                    $_
                }
            }
    )

    $focusText = if ($relativeFiles.Count -gt 0) {
        [string]::Join(', ', $relativeFiles)
    } else {
        'all collected files'
    }

    $reviewPrompt = @(
        "Review the current uncommitted changes collected from $(ConvertTo-CommanderDispatchPowerShellLiteral -Value $WorktreePath)."
        "Focus on: $focusText"
        'Reply with PASS or FAIL on a single line first, then a brief rationale.'
    ) -join ' '

    Invoke-CommanderDispatchBridge -Arguments @('send', $ReviewerPane, $reviewPrompt)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $snapshot = Invoke-CommanderDispatchBridge -Arguments @('read', $ReviewerPane, '120') -CaptureOutput
        if ($snapshot -match '(?im)^\s*PASS\b') {
            return [PSCustomObject]@{
                Outcome  = 'PASS'
                Transcript = $snapshot
            }
        }

        if ($snapshot -match '(?im)^\s*FAIL\b') {
            return [PSCustomObject]@{
                Outcome  = 'FAIL'
                Transcript = $snapshot
            }
        }

        Start-Sleep -Seconds 5
    }

    return [PSCustomObject]@{
        Outcome  = 'TIMEOUT'
        Transcript = $null
    }
}

function Invoke-FullDispatchCycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$PromptFile,
        [Parameter(Mandatory)][string]$BuilderPane,
        [Parameter(Mandatory)][string]$ReviewerPane
    )

    $worktreePath = New-BuilderWorktree -TaskId $TaskId -BuilderName $BuilderPane
    $script:ActiveWorktrees[$worktreePath].reviewerPane = $ReviewerPane

    try {
        $dispatch = Invoke-BuilderTask -WorktreePath $worktreePath -PromptFile $PromptFile
        $completed = Wait-BuilderCompletion -PaneId $dispatch.PaneId
        if (-not $completed) {
            return [PSCustomObject]@{
                TaskId         = $TaskId
                WorktreePath   = $worktreePath
                Status         = 'builder-timeout'
                BuilderPane    = $dispatch.PaneId
                CollectedFiles = @()
                Review         = $null
            }
        }

        $collectedFiles = Collect-BuilderResults -WorktreePath $worktreePath -DestinationPath $script:CommanderDispatchProjectRoot
        $review = Invoke-ReviewerCheck -ReviewerPane $ReviewerPane -WorktreePath $worktreePath -CollectedFiles $collectedFiles

        if ($review.Outcome -ne 'PASS') {
            return [PSCustomObject]@{
                TaskId         = $TaskId
                WorktreePath   = $worktreePath
                Status         = if ($review.Outcome -eq 'FAIL') { 'review-failed' } else { 'review-timeout' }
                BuilderPane    = $dispatch.PaneId
                CollectedFiles = @($collectedFiles)
                Review         = $review
            }
        }

        Remove-BuilderWorktree -WorktreePath $worktreePath

        return [PSCustomObject]@{
            TaskId         = $TaskId
            WorktreePath   = $worktreePath
            Status         = 'ready-to-commit'
            BuilderPane    = $dispatch.PaneId
            CollectedFiles = @($collectedFiles)
            Review         = $review
        }
    } catch {
        throw
    }
}
