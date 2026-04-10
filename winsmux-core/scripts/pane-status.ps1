$scriptDir = $PSScriptRoot
$agentReadinessScript = Join-Path $scriptDir 'agent-readiness.ps1'
$paneControlScript = Join-Path $scriptDir 'pane-control.ps1'

if (Test-Path $agentReadinessScript -PathType Leaf) {
    . $agentReadinessScript
}

if (Test-Path $paneControlScript -PathType Leaf) {
    . $paneControlScript
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
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 'unknown'
    }

    $lastLine = Get-LastNonEmptyLine -Text $Text
    if ($null -ne $lastLine -and $lastLine.TrimStart() -match '^PS [^>]+>$') {
        return 'pwsh'
    }

    if (Test-CodexBusyIndicatorText -Text $Text) {
        return 'busy'
    }

    if (Test-AgentPromptText -Text $Text -Agent 'codex') {
        return 'idle'
    }

    if (Test-CodexSessionText -Text $Text) {
        return 'codex'
    }

    return 'busy'
}

function Get-PaneStatusRecords {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [scriptblock]$SnapshotProvider
    )

    if ($null -eq $SnapshotProvider) {
        $SnapshotProvider = {
            param($PaneId)
            (& winsmux capture-pane -t $PaneId -p -J -S '-80' | Out-String).TrimEnd()
        }
    }

    $entries = Get-PaneControlManifestEntries -ProjectDir $ProjectDir
    $records = @()

    foreach ($entry in $entries) {
        $snapshot = ''
        $state = 'unknown'

        if (-not [string]::IsNullOrWhiteSpace($entry.PaneId)) {
            try {
                $captured = & $SnapshotProvider $entry.PaneId
                if ($null -ne $captured) {
                    $snapshot = [string]$captured
                }
                $state = Get-PaneActualStateFromText -Text $snapshot
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
        }
    }

    return @($records)
}
