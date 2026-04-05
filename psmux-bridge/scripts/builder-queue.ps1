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

. (Join-Path $PSScriptRoot 'manifest.ps1')

$script:BuilderQueueBridgeScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\psmux-bridge.ps1'))

function ConvertTo-BuilderQueueEntry {
    param(
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [Parameter(Mandatory = $true)][string]$Task
    )

    if ([string]::IsNullOrWhiteSpace($BuilderLabel)) {
        throw 'BuilderLabel must not be empty.'
    }

    if ([string]::IsNullOrWhiteSpace($Task)) {
        throw 'Task must not be empty.'
    }

    $encodedTask = [System.Uri]::EscapeDataString($Task)
    return "builder=$BuilderLabel;task=$encodedTask"
}

function ConvertFrom-BuilderQueueEntry {
    param([Parameter(Mandatory = $true)][string]$Entry)

    if ($Entry -match '^builder=(.*?);task=(.*)$') {
        return [PSCustomObject]@{
            BuilderLabel = $Matches[1]
            Task         = [System.Uri]::UnescapeDataString($Matches[2])
            RawEntry     = $Entry
        }
    }

    return [PSCustomObject]@{
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

function Save-BuilderQueueManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Manifest
    )

    Ensure-ManifestTasksShape -Manifest $Manifest
    Save-WinsmuxManifest -ProjectDir $ProjectDir -Manifest $Manifest
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

function Add-BuilderQueueTask {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [Parameter(Mandatory = $true)][string]$Task
    )

    $manifest = Get-BuilderQueueManifest -ProjectDir $ProjectDir
    $entry = ConvertTo-BuilderQueueEntry -BuilderLabel $BuilderLabel -Task $Task
    $manifest.tasks.queued = @($manifest.tasks.queued) + @($entry)
    Save-BuilderQueueManifest -ProjectDir $ProjectDir -Manifest $manifest

    return [PSCustomObject]@{
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
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][string]$Prompt
    )

    if (-not (Test-Path $script:BuilderQueueBridgeScript -PathType Leaf)) {
        throw "Bridge CLI script not found: $script:BuilderQueueBridgeScript"
    }

    $output = & pwsh -NoProfile -File $script:BuilderQueueBridgeScript send $BuilderLabel $Prompt 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).TrimEnd()

    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = 'unknown psmux-bridge error'
        }

        throw "Failed to dispatch queued task to ${BuilderLabel}: $text"
    }

    return [PSCustomObject]@{
        BuilderLabel = $BuilderLabel
        Task         = $Task
        Prompt       = $Prompt
        Output       = $text
    }
}

function Dispatch-NextBuilderQueueTask {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$BuilderLabel,
        [scriptblock]$DispatchAction
    )

    $manifest = Get-BuilderQueueManifest -ProjectDir $ProjectDir
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
    $prompt = New-BuilderQueueDispatchPrompt -Task $nextEntry.Task
    $dispatchResult = if ($null -ne $DispatchAction) {
        & $DispatchAction $BuilderLabel $nextEntry.Task $prompt
    } else {
        Invoke-BuilderQueueDispatch -BuilderLabel $BuilderLabel -Task $nextEntry.Task -Prompt $prompt
    }

    $manifest.tasks.queued = (Remove-BuilderQueueRawEntry -Entries $manifest.tasks.queued -RawEntry $nextEntry.RawEntry)
    $manifest.tasks.in_progress = (@($manifest.tasks.in_progress) + @($nextEntry.RawEntry))
    Save-BuilderQueueManifest -ProjectDir $ProjectDir -Manifest $manifest

    return [PSCustomObject]@{
        BuilderLabel   = $BuilderLabel
        Dispatched     = $true
        Reason         = 'task_dispatched'
        CurrentTask    = $nextEntry.Task
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
    Save-BuilderQueueManifest -ProjectDir $ProjectDir -Manifest $manifest

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
}
