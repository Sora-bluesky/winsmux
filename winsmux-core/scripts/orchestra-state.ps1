$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'manifest.ps1')

function Get-OrchestraStateValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($Name)) {
        return $InputObject[$Name]
    }

    if ($null -ne $InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }

    return $Default
}

function ConvertTo-OrchestraStatePropertyMap {
    param([AllowNull()]$Value)

    $result = [ordered]@{}
    if ($null -eq $Value) {
        return $result
    }

    if ($Value -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = $Value[$key]
        }

        return $result
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) {
            $result[[string]$entry.Key] = $entry.Value
        }

        return $result
    }

    if ($null -ne $Value.PSObject) {
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = $property.Value
        }
    }

    return $result
}

function ConvertTo-OrchestraStringArray {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return @()
        }

        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary])) {
        return @($Value | ForEach-Object {
            if ($null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_)) {
                [string]$_
            }
        })
    }

    return @([string]$Value)
}

function ConvertFrom-OrchestraQueueEntry {
    param([Parameter(Mandatory = $true)][string]$Entry)

    if ($Entry -match '^id=(.*?);builder=(.*?);task=(.*)$') {
        return [ordered]@{
            task_id       = $Matches[1]
            builder_label = $Matches[2]
            task_text     = [System.Uri]::UnescapeDataString($Matches[3])
            raw_entry     = $Entry
        }
    }

    if ($Entry -match '^builder=(.*?);task=(.*)$') {
        return [ordered]@{
            task_id       = ''
            builder_label = $Matches[1]
            task_text     = [System.Uri]::UnescapeDataString($Matches[2])
            raw_entry     = $Entry
        }
    }

    return [ordered]@{
        task_id       = ''
        builder_label = ''
        task_text     = $Entry
        raw_entry     = $Entry
    }
}

function Get-OrchestraTaskAssignments {
    param([AllowNull()]$Manifest)

    $assignments = [ordered]@{}
    if ($null -eq $Manifest) {
        return $assignments
    }

    $tasks = Get-OrchestraStateValue -InputObject $Manifest -Name 'tasks' -Default $null
    if ($null -eq $tasks) {
        return $assignments
    }

    foreach ($stateName in @('queued', 'in_progress', 'completed')) {
        $entries = @(Get-OrchestraStateValue -InputObject $tasks -Name $stateName -Default @())
        foreach ($entry in $entries) {
            $parsed = ConvertFrom-OrchestraQueueEntry -Entry ([string]$entry)
            $builderLabel = [string](Get-OrchestraStateValue -InputObject $parsed -Name 'builder_label' -Default '')
            if ([string]::IsNullOrWhiteSpace($builderLabel)) {
                continue
            }

            if (-not $assignments.Contains($builderLabel)) {
                $assignments[$builderLabel] = [ordered]@{
                    queued      = @()
                    in_progress = @()
                    completed   = @()
                }
            }

            $bucket = $assignments[$builderLabel]
            $bucket[$stateName] = @($bucket[$stateName]) + @($parsed)
        }
    }

    return $assignments
}

function Get-OrchestraReviewStatePath {
    param([string]$ProjectDir = (Get-Location).Path)

    return Join-Path (Join-Path $ProjectDir '.winsmux') 'review-state.json'
}

function Get-OrchestraReviewState {
    param([string]$ProjectDir = (Get-Location).Path)

    $path = Get-OrchestraReviewStatePath -ProjectDir $ProjectDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [ordered]@{}
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{}
    }

    try {
        $parsed = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $ordered = [ordered]@{}
        foreach ($key in $parsed.Keys) {
            $ordered[[string]$key] = $parsed[$key]
        }

        return $ordered
    } catch {
        return [ordered]@{}
    }
}

function Get-OrchestraGitOutput {
    param(
        [Parameter(Mandatory = $true)][string]$WorktreePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if ([string]::IsNullOrWhiteSpace($WorktreePath) -or -not (Test-Path -LiteralPath $WorktreePath -PathType Container)) {
        return @()
    }

    $output = & git -C $WorktreePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    return @($output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-OrchestraGitSnapshot {
    param([string]$WorktreePath)

    $branch = ''
    $headSha = ''
    $changedFiles = @()

    $branchLines = @(Get-OrchestraGitOutput -WorktreePath $WorktreePath -Arguments @('rev-parse', '--abbrev-ref', 'HEAD'))
    if ($branchLines.Count -gt 0) {
        $branch = [string]$branchLines[0]
        if ($branch -eq 'HEAD') {
            $branch = ''
        }
    }

    $headLines = @(Get-OrchestraGitOutput -WorktreePath $WorktreePath -Arguments @('rev-parse', 'HEAD'))
    if ($headLines.Count -gt 0) {
        $headSha = [string]$headLines[0]
    }

    $statusLines = @(Get-OrchestraGitOutput -WorktreePath $WorktreePath -Arguments @('status', '--short', '--untracked-files=all'))
    foreach ($statusLine in $statusLines) {
        $trimmed = $statusLine.Trim()
        if ($trimmed -match '^[A-Z\?\! ]{1,2}\s+(.+)$') {
            $changedFiles += @($Matches[1].Trim())
        } elseif (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $changedFiles += @($trimmed)
        }
    }

    return [ordered]@{
        branch             = $branch
        head_sha           = $headSha
        changed_file_count = @($changedFiles).Count
        changed_files      = @($changedFiles)
    }
}

function Get-OrchestraPaneReviewRecord {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$ReviewState,
        [string]$Branch,
        [string]$Label,
        [string]$PaneId,
        [string]$Role
    )

    if (-not [string]::IsNullOrWhiteSpace($Branch) -and $ReviewState.Contains($Branch)) {
        return $ReviewState[$Branch]
    }

    if ($Role -notin @('Reviewer', 'Worker')) {
        return $null
    }

    foreach ($branchKey in $ReviewState.Keys) {
        $entry = $ReviewState[$branchKey]
        $request = Get-OrchestraStateValue -InputObject $entry -Name 'request' -Default $null
        if ($null -eq $request) {
            continue
        }

        $targetLabel = [string](Get-OrchestraStateValue -InputObject $request -Name 'target_review_label' -Default '')
        if ([string]::IsNullOrWhiteSpace($targetLabel)) {
            $targetLabel = [string](Get-OrchestraStateValue -InputObject $request -Name 'target_reviewer_label' -Default '')
        }
        $targetPaneId = [string](Get-OrchestraStateValue -InputObject $request -Name 'target_review_pane_id' -Default '')
        if ([string]::IsNullOrWhiteSpace($targetPaneId)) {
            $targetPaneId = [string](Get-OrchestraStateValue -InputObject $request -Name 'target_reviewer_pane_id' -Default '')
        }
        if ($targetLabel -eq $Label -or $targetPaneId -eq $PaneId) {
            return $entry
        }
    }

    return $null
}

function Get-OrchestraPaneStateModel {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)]$Pane,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$TaskAssignments,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$ReviewState
    )

    $role = [string](Get-OrchestraStateValue -InputObject $Pane -Name 'role' -Default '')
    $paneId = [string](Get-OrchestraStateValue -InputObject $Pane -Name 'pane_id' -Default '')
    $builderBranch = [string](Get-OrchestraStateValue -InputObject $Pane -Name 'builder_branch' -Default '')
    $worktreePath = [string](Get-OrchestraStateValue -InputObject $Pane -Name 'builder_worktree_path' -Default '')
    if ([string]::IsNullOrWhiteSpace($worktreePath)) {
        $worktreePath = [string](Get-OrchestraStateValue -InputObject $Pane -Name 'launch_dir' -Default '')
    }

    $gitSnapshot = Get-OrchestraGitSnapshot -WorktreePath $worktreePath
    $branch = if ([string]::IsNullOrWhiteSpace($builderBranch)) {
        [string](Get-OrchestraStateValue -InputObject $gitSnapshot -Name 'branch' -Default '')
    } else {
        $builderBranch
    }

    $taskId = ''
    $taskText = ''
    $taskState = ''
    $taskQueueDepth = 0

    if ($TaskAssignments.Contains($Label)) {
        $taskBucket = $TaskAssignments[$Label]
        $queuedEntries = @($taskBucket['queued'])
        $inProgressEntries = @($taskBucket['in_progress'])
        $completedEntries = @($taskBucket['completed'])
        $taskQueueDepth = $queuedEntries.Count

        $selectedTask = $null
        if ($inProgressEntries.Count -gt 0) {
            $taskState = 'in_progress'
            $selectedTask = $inProgressEntries[0]
        } elseif ($queuedEntries.Count -gt 0) {
            $taskState = 'queued'
            $selectedTask = $queuedEntries[0]
        } elseif ($completedEntries.Count -gt 0) {
            $taskState = 'completed'
            $selectedTask = $completedEntries[$completedEntries.Count - 1]
        }

        if ($null -ne $selectedTask) {
            $taskId = [string](Get-OrchestraStateValue -InputObject $selectedTask -Name 'task_id' -Default '')
            $taskText = [string](Get-OrchestraStateValue -InputObject $selectedTask -Name 'task_text' -Default '')
        }
    }

    $reviewRecord = Get-OrchestraPaneReviewRecord -ReviewState $ReviewState -Branch $branch -Label $Label -PaneId $paneId -Role $role
    $reviewStateName = ''
    if ($null -ne $reviewRecord) {
        $reviewStateName = [string](Get-OrchestraStateValue -InputObject $reviewRecord -Name 'status' -Default '')
    }

    $changedFiles = ConvertTo-OrchestraStringArray -Value (Get-OrchestraStateValue -InputObject $gitSnapshot -Name 'changed_files' -Default @())

    return [ordered]@{
        label          = $Label
        pane_id        = $paneId
        role           = $role
        task_id        = $taskId
        task           = $taskText
        task_state     = $taskState
        task_owner     = $Label
        branch         = $branch
        head_sha       = [string](Get-OrchestraStateValue -InputObject $gitSnapshot -Name 'head_sha' -Default '')
        changed_file_count = [int](Get-OrchestraStateValue -InputObject $gitSnapshot -Name 'changed_file_count' -Default 0)
        changed_files  = $changedFiles
        review_state   = $reviewStateName
        last_event     = [string](Get-OrchestraStateValue -InputObject $Pane -Name 'last_event' -Default '')
        last_event_at  = [string](Get-OrchestraStateValue -InputObject $Pane -Name 'last_event_at' -Default '')
        task_queue_depth = $taskQueueDepth
    }
}

function Get-OrchestraPaneStateModels {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [AllowNull()]$Manifest = $null
    )

    if ($null -eq $Manifest) {
        $Manifest = Get-WinsmuxManifest -ProjectDir $ProjectDir
    }

    $models = [ordered]@{}
    if ($null -eq $Manifest) {
        return $models
    }

    $taskAssignments = Get-OrchestraTaskAssignments -Manifest $Manifest
    $reviewState = Get-OrchestraReviewState -ProjectDir $ProjectDir
    $panes = ConvertTo-OrchestraStatePropertyMap -Value (Get-OrchestraStateValue -InputObject $Manifest -Name 'panes' -Default ([ordered]@{}))

    foreach ($label in $panes.Keys) {
        $models[$label] = Get-OrchestraPaneStateModel -Label ([string]$label) -Pane $panes[$label] -TaskAssignments $taskAssignments -ReviewState $reviewState
    }

    return $models
}

function Get-OrchestraPaneStateModelFromCollection {
    param(
        [AllowNull()][System.Collections.IDictionary]$StateModels,
        [string]$Label,
        [string]$PaneId
    )

    if ($null -eq $StateModels) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($Label) -and $StateModels.Contains($Label)) {
        return $StateModels[$Label]
    }

    foreach ($key in $StateModels.Keys) {
        $candidate = $StateModels[$key]
        if ([string](Get-OrchestraStateValue -InputObject $candidate -Name 'pane_id' -Default '') -eq $PaneId) {
            return $candidate
        }
    }

    return $null
}

function ConvertTo-OrchestraPaneManifestProperties {
    param([Parameter(Mandatory = $true)]$StateModel)

    $changedFiles = ConvertTo-OrchestraStringArray -Value (Get-OrchestraStateValue -InputObject $StateModel -Name 'changed_files' -Default @())

    return [ordered]@{
        task_id            = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'task_id' -Default '')
        task               = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'task' -Default '')
        task_state         = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'task_state' -Default '')
        task_owner         = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'task_owner' -Default '')
        review_state       = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'review_state' -Default '')
        branch             = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'branch' -Default '')
        head_sha           = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'head_sha' -Default '')
        changed_file_count = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'changed_file_count' -Default 0)
        changed_files      = $changedFiles
        last_event         = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'last_event' -Default '')
        last_event_at      = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'last_event_at' -Default '')
    }
}

function Merge-OrchestraPaneEventData {
    param(
        [AllowNull()]$StateModel,
        [AllowNull()]$Data = $null
    )

    $merged = ConvertTo-OrchestraStatePropertyMap -Value $Data
    if ($null -eq $StateModel) {
        return $merged
    }

    $merged['task'] = [ordered]@{
        id    = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'task_id' -Default '')
        text  = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'task' -Default '')
        state = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'task_state' -Default '')
        owner = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'task_owner' -Default '')
    }
    $merged['git'] = [ordered]@{
        branch             = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'branch' -Default '')
        head_sha           = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'head_sha' -Default '')
        changed_file_count = [int](Get-OrchestraStateValue -InputObject $StateModel -Name 'changed_file_count' -Default 0)
        changed_files      = ConvertTo-OrchestraStringArray -Value (Get-OrchestraStateValue -InputObject $StateModel -Name 'changed_files' -Default @())
    }
    $merged['review'] = [ordered]@{
        state = [string](Get-OrchestraStateValue -InputObject $StateModel -Name 'review_state' -Default '')
    }

    return $merged
}

function Sync-OrchestraPaneStateModels {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [AllowNull()]$Manifest = $null
    )

    if ($null -eq $Manifest) {
        $Manifest = Get-WinsmuxManifest -ProjectDir $ProjectDir
    }

    $models = Get-OrchestraPaneStateModels -ProjectDir $ProjectDir -Manifest $Manifest
    if ($null -eq $Manifest) {
        return $models
    }

    $panes = ConvertTo-OrchestraStatePropertyMap -Value (Get-OrchestraStateValue -InputObject $Manifest -Name 'panes' -Default ([ordered]@{}))
    foreach ($label in $panes.Keys) {
        $paneMap = ConvertTo-ManifestPropertyMap -Value $panes[$label]
        $stateModel = Get-OrchestraPaneStateModelFromCollection -StateModels $models -Label ([string]$label)
        if ($null -eq $stateModel) {
            continue
        }

        $properties = ConvertTo-OrchestraPaneManifestProperties -StateModel $stateModel
        foreach ($propertyName in $properties.Keys) {
            $paneMap[$propertyName] = $properties[$propertyName]
        }

        $Manifest.panes[$label] = [ordered]@{}
        foreach ($propertyName in $paneMap.Keys) {
            $Manifest.panes[$label][$propertyName] = $paneMap[$propertyName]
        }
    }

    Save-WinsmuxManifest -ProjectDir $ProjectDir -Manifest $Manifest
    return $models
}
