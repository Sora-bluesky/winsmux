$scriptDir = $PSScriptRoot
$agentReadinessScript = Join-Path $scriptDir 'agent-readiness.ps1'
$paneControlScript = Join-Path $scriptDir 'pane-control.ps1'

if (Test-Path $agentReadinessScript -PathType Leaf) {
    . $agentReadinessScript
}

if (Test-Path $paneControlScript -PathType Leaf) {
    . $paneControlScript
}

function Invoke-PaneStatusWinsmux {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $global:LASTEXITCODE = 0
    $output = & winsmux @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = 'unknown winsmux error'
        }

        throw "winsmux $($Arguments -join ' ') failed: $message"
    }

    return $output
}

function Get-PaneTokensRemainingText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $patterns = @(
        '(?im)\b(?<value>\d+(?:\.\d+)?%\s+(?:context\s+)?left)\b',
        '(?im)\b(?:context\s+left|tokens?\s+remaining)\s*[:=]\s*(?<value>\d+(?:\.\d+)?%)\b'
    )

    foreach ($pattern in $patterns) {
        $matches = [regex]::Matches($Text, $pattern)
        if ($matches.Count -gt 0) {
            return $matches[$matches.Count - 1].Groups['value'].Value.Trim()
        }
    }

    return ''
}

function Test-CodexBusyIndicatorText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $tailText = (@(Get-RecentNonEmptyLines -Text $Text -MaxCount 20) -join [Environment]::NewLine)
    if ([string]::IsNullOrWhiteSpace($tailText)) {
        return $false
    }

    $patterns = @(
        '(?im)\bworking\b',
        '(?im)\bthinking\b',
        '(?im)\banaly(?:s|z)ing\b',
        '(?im)\bsearching\b',
        '(?im)\bread(?:ing)?\b',
        '(?im)\bexecut(?:ing|ed)\b',
        '(?im)\brunning\b',
        '(?im)\bapplying\s+patch\b',
        '(?im)\bEsc to interrupt\b',
        '(?im)\bCtrl\+C to cancel\b',
        '(?im)\bstreaming\b'
    )

    foreach ($pattern in $patterns) {
        if ($tailText -match $pattern) {
            return $true
        }
    }

    return $false
}

function Test-CodexSessionText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $tailText = (@(Get-RecentNonEmptyLines -Text $Text -MaxCount 20) -join [Environment]::NewLine)
    if ([string]::IsNullOrWhiteSpace($tailText)) {
        return $false
    }

    $patterns = @(
        '(?im)\b(?:gpt|codex|gpt-oss|o[0-9])[A-Za-z0-9._/-]*\b',
        '(?im)\b\d+(?:\.\d+)?%\s+(?:context\s+)?left\b',
        '(?im)\?\s*send\b',
        '(?im)\bCtrl\+J newline\b'
    )

    foreach ($pattern in $patterns) {
        if ($tailText -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-PaneActualStateFromText {
    param(
        [AllowNull()][string]$Text,
        [string]$Agent = 'codex'
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 'unknown'
    }

    $lastLine = Get-LastNonEmptyLine -Text $Text
    if ($null -ne $lastLine -and $lastLine.TrimStart() -match '^PS [^>]+>$') {
        return 'pwsh'
    }

    if ($Agent -eq 'codex' -and (Test-CodexBusyIndicatorText -Text $Text)) {
        return 'busy'
    }

    if (Test-AgentPromptText -Text $Text -Agent $Agent) {
        return 'idle'
    }

    if ($Agent -eq 'codex' -and (Test-CodexSessionText -Text $Text)) {
        return 'codex'
    }

    return 'busy'
}

function Get-PaneStatusWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Entry
    )

    $entryProjectDir = [string]$Entry.ProjectDir
    $sessionProjectRoot = if (-not [string]::IsNullOrWhiteSpace($entryProjectDir)) { $entryProjectDir } else { $ProjectDir }
    $worktreePath = ''

    $launchDir = [string]$Entry.LaunchDir
    # launch_dir reflects the pane's current cwd, so only prefer it when it points away from the session root.
    if (
        -not [string]::IsNullOrWhiteSpace($launchDir) -and
        $launchDir -ne $ProjectDir -and
        $launchDir -ne $entryProjectDir
    ) {
        $worktreePath = $launchDir
    }

    if ([string]::IsNullOrWhiteSpace($worktreePath)) {
        $worktreePath = [string]$Entry.BuilderWorktreePath
    }

    if ([string]::IsNullOrWhiteSpace($worktreePath)) {
        $role = [string]$Entry.Role
        $label = [string]$Entry.Label
        $branch = [string]$Entry.Branch
        if (
            $role -in @('Builder', 'Worker') -and
            -not [string]::IsNullOrWhiteSpace($label) -and
            $branch -eq ("worktree-{0}" -f $label)
        ) {
            $worktreePath = ".worktrees/$label"
        }
    }

    if ([string]::IsNullOrWhiteSpace($worktreePath)) {
        return ''
    }

    if (-not [System.IO.Path]::IsPathRooted($worktreePath)) {
        return ($worktreePath -replace '\\', '/')
    }

    try {
        $relativePath = [System.IO.Path]::GetRelativePath($sessionProjectRoot, $worktreePath)
    } catch {
        return ($worktreePath -replace '\\', '/')
    }

    if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath -eq '.') {
        return ''
    }

    return ($relativePath -replace '\\', '/')
}

function Get-PaneStatusRecords {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [scriptblock]$SnapshotProvider
    )

    if ($null -eq $SnapshotProvider) {
        $SnapshotProvider = {
            param($PaneId)
            (Invoke-PaneStatusWinsmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') | Out-String).TrimEnd()
        }
    }

    $entries = Get-PaneControlManifestEntries -ProjectDir $ProjectDir
    $records = @()

    foreach ($entry in $entries) {
        $snapshot = ''
        $state = 'unknown'
        $stateAgent = [string]$entry.CapabilityAdapter
        if ([string]::IsNullOrWhiteSpace($stateAgent)) {
            $stateAgent = 'codex'
        }

        if (-not [string]::IsNullOrWhiteSpace($entry.PaneId)) {
            try {
                $captured = & $SnapshotProvider $entry.PaneId
                if ($null -ne $captured) {
                    $snapshot = [string]$captured
                }
                $state = Get-PaneActualStateFromText -Text $snapshot -Agent $stateAgent
            } catch {
                $state = 'unknown'
            }
        }

        $records += [PSCustomObject]@{
            Label           = $entry.Label
            Role            = $entry.Role
            PaneId          = $entry.PaneId
            State           = $state
            TokensRemaining = Get-PaneTokensRemainingText -Text $snapshot
            TaskId          = $entry.TaskId
            Task            = $entry.Task
            TaskState       = $entry.TaskState
            TaskOwner       = $entry.TaskOwner
            ReviewState     = $entry.ReviewState
            Branch          = $entry.Branch
            Worktree        = Get-PaneStatusWorktree -ProjectDir $ProjectDir -Entry $entry
            HeadSha         = $entry.HeadSha
            ChangedFileCount = $entry.ChangedFileCount
            ChangedFiles    = @($entry.ChangedFiles)
            LastEvent       = $entry.LastEvent
            LastEventAt     = $entry.LastEventAt
            ParentRunId     = $entry.ParentRunId
            Goal            = $entry.Goal
            TaskType        = $entry.TaskType
            Priority        = $entry.Priority
            Blocking        = $entry.Blocking
            WriteScope      = @($entry.WriteScope)
            ReadScope       = @($entry.ReadScope)
            Constraints     = @($entry.Constraints)
            ExpectedOutput  = $entry.ExpectedOutput
            VerificationPlan = @($entry.VerificationPlan)
            ReviewRequired  = $entry.ReviewRequired
            ProviderTarget  = $entry.ProviderTarget
            AgentRole       = $entry.AgentRole
            TimeoutPolicy   = $entry.TimeoutPolicy
            HandoffRefs     = @($entry.HandoffRefs)
            SecurityPolicy  = $entry.SecurityPolicy
        }
    }

    return @($records)
}
