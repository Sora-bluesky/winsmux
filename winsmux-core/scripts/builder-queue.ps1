[CmdletBinding()]
param(
    [ValidateSet('add', 'list', 'dispatch-next', 'complete')]
    [string]$Action,
    [string]$ProjectDir = (Get-Location).Path,
    [string]$BuilderLabel,
    [string]$Task,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'json-compat.ps1')
. (Join-Path $PSScriptRoot 'manifest.ps1')
. (Join-Path $PSScriptRoot 'clm-safe-io.ps1')
. (Join-Path $PSScriptRoot 'submission-contract.ps1')
$script:BuilderQueuePaneControlScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'pane-control.ps1'))
if (Test-Path $script:BuilderQueuePaneControlScript -PathType Leaf) {
    . $script:BuilderQueuePaneControlScript
}

$script:BuilderQueueBridgeScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\winsmux-core.ps1'))
$script:DispatchLedgerRelativePath = '.winsmux\dispatch-ledger.json'

function ConvertTo-BuilderQueueEntry {
    param(
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [Parameter(Mandatory = $true)][string]$Task,
        [string]$TaskId
    )

    if ([string]::IsNullOrWhiteSpace($BuilderLabel)) {
        throw 'BuilderLabel must not be empty.'
    }

    if ([string]::IsNullOrWhiteSpace($Task)) {
        throw 'Task must not be empty.'
    }

    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        $TaskId = [guid]::NewGuid().ToString('N')
    }

    $encodedTask = [System.Uri]::EscapeDataString($Task)
    return "id=$TaskId;builder=$BuilderLabel;task=$encodedTask"
}

function ConvertFrom-BuilderQueueEntry {
    param([Parameter(Mandatory = $true)][string]$Entry)

    if ($Entry -match '^id=(.*?);builder=(.*?);task=(.*)$') {
        return [PSCustomObject]@{
            TaskId       = $Matches[1]
            BuilderLabel = $Matches[2]
            Task         = [System.Uri]::UnescapeDataString($Matches[3])
            RawEntry     = $Entry
        }
    }

    if ($Entry -match '^builder=(.*?);task=(.*)$') {
        $fallbackTaskId = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($Entry)
            )
        ).Replace('-', '').ToLowerInvariant()

        return [PSCustomObject]@{
            TaskId       = $fallbackTaskId
            BuilderLabel = $Matches[1]
            Task         = [System.Uri]::UnescapeDataString($Matches[2])
            RawEntry     = $Entry
        }
    }

    return [PSCustomObject]@{
        TaskId       = ''
        BuilderLabel = ''
        Task         = $Entry
        RawEntry     = $Entry
    }
}

function Ensure-ManifestTasksShape {
    param([Parameter(Mandatory = $true)]$Manifest)
    if (-not $Manifest.PSObject.Properties['tasks']) {
        $Manifest | Add-Member -NotePropertyName 'tasks' -NotePropertyValue ([PSCustomObject]@{
            queued      = @()
            in_progress = @()
            completed   = @()
        })
    } else {
        $t = $Manifest.tasks
        if (-not $t.PSObject.Properties['queued'])      { $t | Add-Member -NotePropertyName 'queued'      -NotePropertyValue @() }
        if (-not $t.PSObject.Properties['in_progress']) { $t | Add-Member -NotePropertyName 'in_progress' -NotePropertyValue @() }
        if (-not $t.PSObject.Properties['completed'])   { $t | Add-Member -NotePropertyName 'completed'   -NotePropertyValue @() }
    }
}

function Get-BuilderQueueManifest {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $manifest = Get-WinsmuxManifest -ProjectDir $ProjectDir
    if ($null -eq $manifest) {
        $manifest = New-WinsmuxManifest -ProjectDir $ProjectDir
    }

    Ensure-ManifestTasksShape -Manifest $manifest
    return $manifest
}

function Get-BuilderQueueExpectedGenerationId {
    param([Parameter(Mandatory = $true)]$Manifest)

    if ($null -eq $Manifest) {
        return ''
    }
    $session = Get-PaneControlValue -InputObject $Manifest -Name 'session' -Default $null
    return [string](Get-PaneControlValue -InputObject $session -Name 'generation_id' -Default '')
}

function Get-BuilderQueuePaneContext {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$BuilderLabel
    )

    $panes = Get-PaneControlValue -InputObject $Manifest -Name 'panes' -Default $null
    $pane = $null
    if ($panes -is [System.Collections.IDictionary]) {
        if ($panes.Contains($BuilderLabel)) {
            $pane = $panes[$BuilderLabel]
        }
    } elseif ($null -ne $panes -and $null -ne $panes.PSObject) {
        $paneProperty = $panes.PSObject.Properties[$BuilderLabel]
        if ($null -ne $paneProperty) {
            $pane = $paneProperty.Value
        }
    }
    if ($null -eq $pane) {
        return $null
    }
    $paneId = [string](Get-PaneControlValue -InputObject $pane -Name 'pane_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($paneId)) {
        return $null
    }

    return [ordered]@{
        ManifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
        PaneId = $paneId
        GenerationId = Get-BuilderQueueExpectedGenerationId -Manifest $Manifest
    }
}

function Save-BuilderQueueManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Manifest,
        [AllowEmptyString()][string]$ExpectedGenerationId = ''
    )

    Ensure-ManifestTasksShape -Manifest $Manifest
    $manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
    Save-PaneControlManifestDocument -ManifestPath $manifestPath -Manifest $Manifest `
        -ExpectedGenerationId $ExpectedGenerationId
}

function Get-BuilderQueueEntries {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][ValidateSet('queued', 'in_progress', 'completed')][string]$State,
        [string]$BuilderLabel
    )

    Ensure-ManifestTasksShape -Manifest $Manifest
    $entries = @($Manifest.tasks.$State | ForEach-Object { ConvertFrom-BuilderQueueEntry -Entry ([string]$_) })

    if ([string]::IsNullOrWhiteSpace($BuilderLabel)) {
        return @($entries)
    }

    return @($entries | Where-Object { $_.BuilderLabel -eq $BuilderLabel })
}

function Remove-BuilderQueueRawEntry {
    param(
        [Parameter(Mandatory = $true)][array]$Entries,
        [Parameter(Mandatory = $true)][string]$RawEntry
    )

    $removed = $false
    $remaining = foreach ($entry in @($Entries)) {
        if (-not $removed -and [string]$entry -eq $RawEntry) {
            $removed = $true
            continue
        }

        $entry
    }

    return @($remaining)
}

function Update-BuilderQueuePaneState {
    param(
        [AllowNull()]$PaneContext,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Properties
    )

    if (-not (Get-Command Set-PaneControlManifestPaneProperties -ErrorAction SilentlyContinue) -or
        $null -eq $PaneContext) {
        return
    }

    try {
        if ([string]::IsNullOrWhiteSpace([string]$PaneContext.PaneId) -or
            [string]::IsNullOrWhiteSpace([string]$PaneContext.ManifestPath)) {
            return
        }

        $expectedGenerationId = [string]$PaneContext.GenerationId
        Set-PaneControlManifestPaneProperties -ManifestPath ([string]$PaneContext.ManifestPath) -PaneId ([string]$PaneContext.PaneId) `
            -Properties $Properties -ExpectedGenerationId $expectedGenerationId
    } catch {
        # Pane state enrichment is best-effort and must not break queue operation.
    }
}

function Get-BuilderQueueSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [string]$BuilderLabel
    )

    $manifest = Get-BuilderQueueManifest -ProjectDir $ProjectDir

    return [PSCustomObject]@{
        ProjectDir  = $ProjectDir
        BuilderLabel = $BuilderLabel
        Queued      = @(Get-BuilderQueueEntries -Manifest $manifest -State 'queued' -BuilderLabel $BuilderLabel)
        InProgress  = @(Get-BuilderQueueEntries -Manifest $manifest -State 'in_progress' -BuilderLabel $BuilderLabel)
        Completed   = @(Get-BuilderQueueEntries -Manifest $manifest -State 'completed' -BuilderLabel $BuilderLabel)
    }
}

function Get-DispatchLedgerPath {
    param([string]$ProjectDir = (Get-Location).Path)

    return Join-Path $ProjectDir $script:DispatchLedgerRelativePath
}

function Get-DispatchLedger {
    param([string]$ProjectDir = (Get-Location).Path)

    $path = Get-DispatchLedgerPath -ProjectDir $ProjectDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @()
        }

        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed) {
            return @()
        }

        if ($parsed -is [System.Array]) {
            return @($parsed)
        }

        return @($parsed)
    } catch {
        return @()
    }
}

function Save-DispatchLedger {
    param(
        [string]$ProjectDir = (Get-Location).Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Entries
    )

    $path = Get-DispatchLedgerPath -ProjectDir $ProjectDir
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (@($Entries).Count -eq 0) {
        Write-WinsmuxTextFile -Path $path -Content '[]'
        return
    }

    Write-WinsmuxTextFile -Path $path -Content (@($Entries) | ConvertTo-Json -Depth 8)
}

function ConvertTo-DispatchLockPath {
    param(
        [string]$ProjectDir = (Get-Location).Path,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $candidate = $Path.Trim()
    $candidate = $candidate.Trim("'`"[](){}.,;:")
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    $rootedCandidate = $candidate
    if ([System.IO.Path]::IsPathRooted($rootedCandidate)) {
        try {
            $projectRoot = [System.IO.Path]::GetFullPath($ProjectDir).TrimEnd('\', '/')
            $fullCandidate = [System.IO.Path]::GetFullPath($rootedCandidate)
            if (-not $fullCandidate.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $null
            }

            $candidate = $fullCandidate.Substring($projectRoot.Length).TrimStart('\', '/')
        } catch {
            return $null
        }
    }

    $candidate = $candidate -replace '\\', '/'
    if ($candidate.StartsWith('./')) {
        $candidate = $candidate.Substring(2)
    }

    while ($candidate.StartsWith('/')) {
        $candidate = $candidate.Substring(1)
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    return $candidate
}

function Get-BuilderQueueTaskFiles {
    param(
        [string]$ProjectDir = (Get-Location).Path,
        [Parameter(Mandatory = $true)][string]$Task
    )

    $matches = [regex]::Matches($Task, '(?<![\w.-])(?:[A-Za-z0-9_.-]+[\\/])+[A-Za-z0-9_.-]+')
    $files = [System.Collections.Generic.List[string]]::new()
    $seen = @{}

    foreach ($match in $matches) {
        $normalized = ConvertTo-DispatchLockPath -ProjectDir $ProjectDir -Path $match.Value
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }

        $key = $normalized.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $files.Add($normalized)
    }

    return @($files)
}

function Lock-DispatchFiles {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [string[]]$Files,
        [string]$ProjectDir = (Get-Location).Path
    )

    $normalizedFiles = [System.Collections.Generic.List[string]]::new()
    $requested = @{}
    foreach ($file in @($Files)) {
        $normalized = ConvertTo-DispatchLockPath -ProjectDir $ProjectDir -Path ([string]$file)
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }

        $key = $normalized.ToLowerInvariant()
        if ($requested.ContainsKey($key)) {
            continue
        }

        $requested[$key] = $true
        $normalizedFiles.Add($normalized)
    }

    $ledger = @(Get-DispatchLedger -ProjectDir $ProjectDir | Where-Object { $_.task_id -ne $TaskId })
    foreach ($entry in $ledger) {
        if ([string]$entry.builder_label -eq $BuilderLabel) {
            continue
        }

        foreach ($file in @($entry.files)) {
            if ($requested.ContainsKey(([string]$file).ToLowerInvariant())) {
                return $false
            }
        }
    }

    if ($normalizedFiles.Count -gt 0) {
        $ledger = @($ledger) + @([PSCustomObject]@{
            task_id       = $TaskId
            builder_label = $BuilderLabel
            files         = @($normalizedFiles)
            state         = 'locked'
        })
    }

    Save-DispatchLedger -ProjectDir $ProjectDir -Entries $ledger
    return $true
}

function Unlock-DispatchFiles {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$ProjectDir = (Get-Location).Path
    )

    $ledger = @(Get-DispatchLedger -ProjectDir $ProjectDir)
    $remaining = @($ledger | Where-Object { $_.task_id -ne $TaskId })
    Save-DispatchLedger -ProjectDir $ProjectDir -Entries $remaining
    return ($remaining.Count -ne $ledger.Count)
}

function Add-BuilderQueueTask {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [Parameter(Mandatory = $true)][string]$Task
    )

    $manifest = Get-BuilderQueueManifest -ProjectDir $ProjectDir
    $expectedGenerationId = Get-BuilderQueueExpectedGenerationId -Manifest $manifest
    $entry = ConvertTo-BuilderQueueEntry -BuilderLabel $BuilderLabel -Task $Task
    $manifest.tasks.queued = @($manifest.tasks.queued) + @($entry)
    Save-BuilderQueueManifest -ProjectDir $ProjectDir -Manifest $manifest -ExpectedGenerationId $expectedGenerationId

    return [PSCustomObject]@{
        TaskId       = (ConvertFrom-BuilderQueueEntry -Entry $entry).TaskId
        BuilderLabel = $BuilderLabel
        Task         = $Task
        RawEntry     = $entry
        Snapshot     = Get-BuilderQueueSnapshot -ProjectDir $ProjectDir -BuilderLabel $BuilderLabel
    }
}

function New-BuilderQueueDispatchPrompt {
    param([Parameter(Mandatory = $true)][string]$Task)

    return @"
Implement the next queued Builder task in your assigned workspace.

Task:
$Task

Before finishing:
- run the relevant checks or tests
- summarize changed files
- summarize the verification you performed

End with exactly one line:
STATUS: EXEC_DONE

If blocked, end with:
STATUS: BLOCKED
"@
}

function Invoke-BuilderQueueDispatch {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][string]$AttemptId,
        [Parameter(Mandatory = $true)][string]$Prompt
    )

    $manifestEntry = @(Get-PaneControlManifestEntries -ProjectDir $ProjectDir | Where-Object { [string]$_.Label -ceq $BuilderLabel } | Select-Object -First 1)[0]
    if ($null -eq $manifestEntry) {
        return New-WinsmuxSubmissionReceipt -Kind task -Status unavailable -Backend noop -SubmissionId $AttemptId `
            -ReasonCode 'target_manifest_missing' -Target ([ordered]@{ label = $BuilderLabel })
    }
    return Invoke-WinsmuxSubmissionAdapter -ProjectDir $ProjectDir -ManifestEntry $manifestEntry -Kind task -Content $Prompt -SubmissionId $AttemptId -TaskId $Task
}

function Test-BuilderQueueDispatchEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$AttemptId,
        [Parameter(Mandatory = $true)]$Receipt
    )

    $target = Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'target' -Default $null
    if (
        [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'submission_id' -Default '') -cne $AttemptId -or
        [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'kind' -Default '') -cne 'task' -or
        [string](Get-WinsmuxSubmissionValue -InputObject $target -Name 'label' -Default '') -cne $BuilderLabel
    ) {
        return $false
    }
    $packetPath = Join-Path (Join-Path (Join-Path $ProjectDir '.winsmux') 'submissions') ($AttemptId + '.json')
    $runPath = Get-WinsmuxSubmissionRunPath -ProjectDir $ProjectDir -SlotId $BuilderLabel -RunId $AttemptId
    if (-not (Test-Path -LiteralPath $packetPath -PathType Leaf) -or -not (Test-Path -LiteralPath $runPath -PathType Leaf)) {
        return $false
    }
    try {
        $packet = Read-WinsmuxSubmissionPacket -Path $packetPath
        $runRecord = Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-WinsmuxJson -Depth 16
    } catch {
        return $false
    }
    if (
        [string]$packet.submission_id -cne $AttemptId -or
        [string]$packet.run_id -cne $AttemptId -or
        [string]$packet.task_id -cne $TaskId -or
        [string]$packet.kind -cne 'task' -or
        [string]$packet.target -cne $BuilderLabel
    ) {
        return $false
    }
    return Test-WinsmuxSubmissionRunRecord -Record $runRecord -SubmissionId $AttemptId -Kind task `
        -Backend ([string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'backend' -Default '')) -ExpectedSlotId $BuilderLabel -ExpectedRequestDigest ([string]$packet.request_digest) -ExpectedTaskId $TaskId
}

function Dispatch-NextBuilderQueueTask {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [scriptblock]$DispatchAction
    )

    $manifest = Get-BuilderQueueManifest -ProjectDir $ProjectDir
    $expectedGenerationId = Get-BuilderQueueExpectedGenerationId -Manifest $manifest
    $paneContext = Get-BuilderQueuePaneContext -Manifest $manifest -ProjectDir $ProjectDir -BuilderLabel $BuilderLabel
    $current = @(Get-BuilderQueueEntries -Manifest $manifest -State 'in_progress' -BuilderLabel $BuilderLabel)
    if ($current.Count -gt 0) {
        return [PSCustomObject]@{
            BuilderLabel   = $BuilderLabel
            Dispatched     = $false
            Reason         = 'already_in_progress'
            CurrentTask    = $current[0].Task
            DispatchResult = $null
        }
    }

    $queued = @(Get-BuilderQueueEntries -Manifest $manifest -State 'queued' -BuilderLabel $BuilderLabel)
    if ($queued.Count -lt 1) {
        return [PSCustomObject]@{
            BuilderLabel   = $BuilderLabel
            Dispatched     = $false
            Reason         = 'queue_empty'
            CurrentTask    = $null
            DispatchResult = $null
        }
    }

    $nextEntry = $queued[0]
    $attemptId = 'attempt-' + [guid]::NewGuid().ToString('N')
    $dispatchFiles = @(Get-BuilderQueueTaskFiles -ProjectDir $ProjectDir -Task $nextEntry.Task)
    $locked = Lock-DispatchFiles -TaskId $nextEntry.TaskId -BuilderLabel $BuilderLabel -Files $dispatchFiles -ProjectDir $ProjectDir
    if (-not $locked) {
        return [PSCustomObject]@{
            BuilderLabel     = $BuilderLabel
            Dispatched       = $false
            Reason           = 'file_conflict'
            CurrentTask      = $nextEntry.Task
            DispatchFiles    = @($dispatchFiles)
            DispatchResult   = $null
        }
    }

    $prompt = New-BuilderQueueDispatchPrompt -Task $nextEntry.Task
    try {
        $dispatchResult = if ($null -ne $DispatchAction) {
            & $DispatchAction $BuilderLabel $nextEntry.Task $prompt $nextEntry.TaskId $attemptId
        } else {
            Invoke-BuilderQueueDispatch -ProjectDir $ProjectDir -BuilderLabel $BuilderLabel -Task $nextEntry.TaskId -AttemptId $attemptId -Prompt $prompt
        }
    } catch {
        Unlock-DispatchFiles -TaskId $nextEntry.TaskId -ProjectDir $ProjectDir | Out-Null
        throw
    }

    $receiptValid = Test-WinsmuxSubmissionReceipt -Receipt $dispatchResult
    $accepted = $receiptValid -and [string]$dispatchResult.status -ceq 'accepted'
    $evidenceValid = $accepted -and (Test-BuilderQueueDispatchEvidence -ProjectDir $ProjectDir -BuilderLabel $BuilderLabel -TaskId $nextEntry.TaskId -AttemptId $attemptId -Receipt $dispatchResult)
    if (-not $accepted -or -not $evidenceValid) {
        Unlock-DispatchFiles -TaskId $nextEntry.TaskId -ProjectDir $ProjectDir | Out-Null
        $reason = if (-not $accepted -and $receiptValid -and -not [string]::IsNullOrWhiteSpace([string]$dispatchResult.reason_code)) {
            [string]$dispatchResult.reason_code
        } else {
            'runner_evidence_invalid'
        }
        return [PSCustomObject]@{
            BuilderLabel   = $BuilderLabel
            Dispatched     = $false
            Reason         = $reason
            CurrentTask    = $nextEntry.Task
            DispatchFiles  = @($dispatchFiles)
            DispatchResult = $dispatchResult
        }
    }

    $manifest.tasks.queued = @(
        @($manifest.tasks.queued) |
            Where-Object { (ConvertFrom-BuilderQueueEntry -Entry ([string]$_)).TaskId -cne $nextEntry.TaskId }
    )
    $manifest.tasks.in_progress = (@($manifest.tasks.in_progress) + @($nextEntry.RawEntry))
    Save-BuilderQueueManifest -ProjectDir $ProjectDir -Manifest $manifest -ExpectedGenerationId $expectedGenerationId
    Update-BuilderQueuePaneState -PaneContext $paneContext -Properties ([ordered]@{
        task_id            = $nextEntry.TaskId
        task               = $nextEntry.Task
        task_state         = 'in_progress'
        task_owner         = 'Builder'
        changed_file_count = 0
        changed_files      = @()
        last_event         = 'builder.queue.dispatched'
        last_event_at      = (Get-Date).ToString('o')
    })

    return [PSCustomObject]@{
        BuilderLabel   = $BuilderLabel
        Dispatched     = $true
        Reason         = 'task_dispatched'
        CurrentTask    = $nextEntry.Task
        DispatchFiles  = @($dispatchFiles)
        DispatchResult = $dispatchResult
    }
}

function Complete-BuilderQueueTask {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [string]$Task,
        [scriptblock]$DispatchAction
    )

    $manifest = Get-BuilderQueueManifest -ProjectDir $ProjectDir
    $expectedGenerationId = Get-BuilderQueueExpectedGenerationId -Manifest $manifest
    $paneContext = Get-BuilderQueuePaneContext -Manifest $manifest -ProjectDir $ProjectDir -BuilderLabel $BuilderLabel
    $inProgress = @(Get-BuilderQueueEntries -Manifest $manifest -State 'in_progress' -BuilderLabel $BuilderLabel)

    $completedEntry = if ([string]::IsNullOrWhiteSpace($Task)) {
        if ($inProgress.Count -lt 1) { $null } else { $inProgress[0] }
    } else {
        @($inProgress | Where-Object { $_.Task -eq $Task } | Select-Object -First 1)[0]
    }

    if ($null -eq $completedEntry) {
        throw "No in-progress task found for $BuilderLabel."
    }

    $manifest.tasks.in_progress = (Remove-BuilderQueueRawEntry -Entries $manifest.tasks.in_progress -RawEntry $completedEntry.RawEntry)
    if (@($manifest.tasks.completed | Where-Object { [string]$_ -eq $completedEntry.RawEntry }).Count -eq 0) {
        $manifest.tasks.completed = (@($manifest.tasks.completed) + @($completedEntry.RawEntry))
    }
    Save-BuilderQueueManifest -ProjectDir $ProjectDir -Manifest $manifest -ExpectedGenerationId $expectedGenerationId
    Unlock-DispatchFiles -TaskId $completedEntry.TaskId -ProjectDir $ProjectDir | Out-Null
    Update-BuilderQueuePaneState -PaneContext $paneContext -Properties ([ordered]@{
        task_id       = $completedEntry.TaskId
        task          = $completedEntry.Task
        task_state    = 'completed'
        task_owner    = 'Operator'
        last_event    = 'builder.queue.completed'
        last_event_at = (Get-Date).ToString('o')
    })

    $dispatchOutcome = Dispatch-NextBuilderQueueTask -ProjectDir $ProjectDir -BuilderLabel $BuilderLabel -DispatchAction $DispatchAction

    return [PSCustomObject]@{
        BuilderLabel    = $BuilderLabel
        CompletedTask   = $completedEntry.Task
        DispatchedTask  = if ($dispatchOutcome.Dispatched) { $dispatchOutcome.CurrentTask } else { $null }
        DispatchOutcome = $dispatchOutcome
        Snapshot        = Get-BuilderQueueSnapshot -ProjectDir $ProjectDir -BuilderLabel $BuilderLabel
    }
}

function Invoke-BuilderQueueAction {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('add', 'list', 'dispatch-next', 'complete')][string]$Action,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [string]$BuilderLabel,
        [string]$Task
    )

    switch ($Action) {
        'add' {
            if ([string]::IsNullOrWhiteSpace($BuilderLabel)) {
                throw 'builder-queue add requires -BuilderLabel.'
            }
            if ([string]::IsNullOrWhiteSpace($Task)) {
                throw 'builder-queue add requires -Task.'
            }

            return Add-BuilderQueueTask -ProjectDir $ProjectDir -BuilderLabel $BuilderLabel -Task $Task
        }
        'list' {
            return Get-BuilderQueueSnapshot -ProjectDir $ProjectDir -BuilderLabel $BuilderLabel
        }
        'dispatch-next' {
            if ([string]::IsNullOrWhiteSpace($BuilderLabel)) {
                throw 'builder-queue dispatch-next requires -BuilderLabel.'
            }

            return Dispatch-NextBuilderQueueTask -ProjectDir $ProjectDir -BuilderLabel $BuilderLabel
        }
        'complete' {
            if ([string]::IsNullOrWhiteSpace($BuilderLabel)) {
                throw 'builder-queue complete requires -BuilderLabel.'
            }

            return Complete-BuilderQueueTask -ProjectDir $ProjectDir -BuilderLabel $BuilderLabel -Task $Task
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-BuilderQueueAction -Action $Action -ProjectDir $ProjectDir -BuilderLabel $BuilderLabel -Task $Task
    if ($AsJson) {
        $result | ConvertTo-Json -Depth 8
    } else {
        $result
    }
    if ($Action -eq 'dispatch-next' -and -not [bool]$result.Dispatched -and [string]$result.Reason -notin @('already_in_progress', 'queue_empty')) {
        exit 1
    }
}
