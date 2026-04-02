[CmdletBinding()]
param(
    [switch]$Watch,
    [string]$ProjectDir = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/shared-task-list.ps1"
. "$PSScriptRoot/agent-lifecycle.ps1"
. "$PSScriptRoot/role-gate.ps1"

$script:TaskHooksWatcher = $null
$script:TaskHooksEventIds = @()
$script:TaskHooksProjectDir = $null
$script:TaskHooksSnapshot = @()
$script:TaskHooksBridgeScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\psmux-bridge.ps1'))
$script:TaskHooksScriptPath = $PSCommandPath
$script:TaskHooksPidFileName = 'task-hooks.pid'
$script:TaskHooksStopFileName = 'task-hooks.stop'
$script:TaskHooksLogFileName = 'task-hooks.log'

function Resolve-TaskHooksProjectDir {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Get-TaskHooksWorkspaceDir {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return Join-Path $ProjectRoot '.winsmux'
}

function Ensure-TaskHooksWorkspaceDir {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $workspaceDir = Get-TaskHooksWorkspaceDir -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $workspaceDir)) {
        New-Item -ItemType Directory -Path $workspaceDir -Force | Out-Null
    }

    return $workspaceDir
}

function Get-TaskHooksPidPath {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return Join-Path (Ensure-TaskHooksWorkspaceDir -ProjectRoot $ProjectRoot) $script:TaskHooksPidFileName
}

function Get-TaskHooksStopPath {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return Join-Path (Ensure-TaskHooksWorkspaceDir -ProjectRoot $ProjectRoot) $script:TaskHooksStopFileName
}

function Get-TaskHooksLogPath {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return Join-Path (Ensure-TaskHooksWorkspaceDir -ProjectRoot $ProjectRoot) $script:TaskHooksLogFileName
}

function Write-TaskHooksLog {
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$Details
    )

    if ([string]::IsNullOrWhiteSpace($script:TaskHooksProjectDir)) {
        return
    }

    $logPath = Get-TaskHooksLogPath -ProjectRoot $script:TaskHooksProjectDir
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add((Get-Date).ToString('o'))
    $parts.Add($Event)

    if (-not [string]::IsNullOrWhiteSpace($Details)) {
        $parts.Add(($Details -replace '\r?\n', ' '))
    }

    Add-Content -Path $logPath -Value ($parts -join ' | ') -Encoding UTF8
}

function Get-TaskHooksHostRecord {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $pidPath = Get-TaskHooksPidPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $pidPath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $pidPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Remove-TaskHooksHostRecord {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    foreach ($path in @(
        (Get-TaskHooksPidPath -ProjectRoot $ProjectRoot),
        (Get-TaskHooksStopPath -ProjectRoot $ProjectRoot)
    )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-TaskHooksTaskMap {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Tasks)

    $map = @{}
    foreach ($task in $Tasks) {
        $taskId = [string]$task.id
        if (-not [string]::IsNullOrWhiteSpace($taskId)) {
            $map[$taskId] = $task
        }
    }

    return $map
}

function Get-TaskHooksSnapshotHash {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Tasks)

    $json = @($Tasks) | ConvertTo-Json -Compress -Depth 8
    return [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($json)
        )
    ) -replace '-', ''
}

function Get-TaskHooksTaskDescriptor {
    param([Parameter(Mandatory = $true)]$Task)

    return ('{0} {1}' -f [string]$Task.id, [string]$Task.title).Trim()
}

function Get-TaskDispatchRole {
    param([Parameter(Mandatory = $true)]$Task)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($propertyName in @('title', 'type', 'kind', 'category', 'description')) {
        if ($Task.PSObject.Properties.Match($propertyName).Count -gt 0) {
            $value = [string]$Task.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $parts.Add($value)
            }
        }
    }

    $text = $parts -join ' '
    if ($text -match '(?i)\b(analysis|analyze|research|investigat|spike|spec|design|review|audit|plan|document(?:ation)?)\b') {
        return 'Researcher'
    }

    return 'Builder'
}

function Get-ClaimedAgents {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Tasks)

    $claimed = @{}
    foreach ($task in $Tasks) {
        $claimedBy = [string]$task.claimed_by
        if ($task.status -eq 'claimed' -and -not [string]::IsNullOrWhiteSpace($claimedBy)) {
            $claimed[$claimedBy] = $true
        }
    }

    return $claimed
}

function Get-AvailableAgentForRole {
    param(
        [Parameter(Mandatory = $true)][string]$Role,
        [hashtable]$ReservedAgents = @{},
        [AllowEmptyCollection()][object[]]$Tasks = @()
    )

    $claimedAgents = Get-ClaimedAgents -Tasks $Tasks
    $assignments = @(
        Get-LabeledPaneAssignments |
            Where-Object { (ConvertTo-InferredWinsmuxRole $_.Label) -eq $Role } |
            Sort-Object Label
    )

    foreach ($assignment in $assignments) {
        $label = [string]$assignment.Label
        if ([string]::IsNullOrWhiteSpace($label)) {
            continue
        }

        if ($claimedAgents.ContainsKey($label) -or $ReservedAgents.ContainsKey($label)) {
            continue
        }

        try {
            $health = Get-AgentHealth -PaneId ([string]$assignment.PaneId)
        } catch {
            Write-TaskHooksLog -Event 'agent-health-error' -Details "$label :: $($_.Exception.Message)"
            continue
        }

        if ($health.State -eq 'READY') {
            return $assignment
        }
    }

    return $null
}

function Invoke-BridgeSend {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $output = & pwsh -NoProfile -File $script:TaskHooksBridgeScript 'send' $Target $Text 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $message = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "psmux-bridge send failed for $Target"
        }

        throw $message
    }

    return ($output | Out-String).Trim()
}

function Reset-SharedTaskClaim {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$AgentName
    )

    return Invoke-SharedTaskLock {
        $tasks = @(Read-SharedTasksInternal)
        $task = $tasks | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1

        if ($null -eq $task) {
            return $null
        }

        if ($task.status -eq 'claimed' -and [string]$task.claimed_by -eq $AgentName) {
            $task.status = if (Test-SharedTaskDependenciesSatisfied -Tasks $tasks -Task $task) { 'open' } else { 'blocked' }
            $task.claimed_by = $null
            Write-SharedTasksInternal -Tasks $tasks
        }

        return $task
    }
}

function New-TaskDispatchMessage {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $taskId = [string]$Task.id
    $taskTitle = [string]$Task.title
    $completionSnippet = ". '$PSScriptRoot/shared-task-list.ps1'; Complete-SharedTask -TaskId '$taskId'"

    return "Auto-dispatched $Role task ${taskId}: $taskTitle. When the work is complete, run: $completionSnippet"
}

function Invoke-TaskDispatch {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)]$Assignment
    )

    $agentName = [string]$Assignment.Label
    $role = Get-TaskDispatchRole -Task $Task
    $claimResult = Claim-SharedTask -TaskId ([string]$Task.id) -AgentName $agentName

    if ($claimResult -eq 'blocked') {
        Write-TaskHooksLog -Event 'dispatch-skipped' -Details "$agentName :: blocked :: $(Get-TaskHooksTaskDescriptor -Task $Task)"
        return $null
    }

    if ($null -eq $claimResult) {
        return $null
    }

    if ($claimResult.status -eq 'done') {
        return $null
    }

    if ($claimResult.status -ne 'claimed' -or [string]$claimResult.claimed_by -ne $agentName) {
        Write-TaskHooksLog -Event 'dispatch-race' -Details "$agentName :: $(Get-TaskHooksTaskDescriptor -Task $claimResult)"
        return $null
    }

    try {
        $message = New-TaskDispatchMessage -Task $claimResult -Role $role
        Invoke-BridgeSend -Target $agentName -Text $message | Out-Null
        Write-TaskHooksLog -Event 'dispatch' -Details "$agentName :: $(Get-TaskHooksTaskDescriptor -Task $claimResult)"

        return [PSCustomObject]@{
            TaskId = [string]$claimResult.id
            Title  = [string]$claimResult.title
            Agent  = $agentName
            Role   = $role
        }
    } catch {
        Reset-SharedTaskClaim -TaskId ([string]$Task.id) -AgentName $agentName | Out-Null
        Write-TaskHooksLog -Event 'dispatch-error' -Details "$agentName :: $(Get-TaskHooksTaskDescriptor -Task $Task) :: $($_.Exception.Message)"
        throw
    }
}

function Get-DispatchQueue {
    param(
        [AllowEmptyCollection()][object[]]$PreferredTasks = @(),
        [AllowEmptyCollection()][object[]]$OpenTasks = @()
    )

    $queue = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    foreach ($task in @($PreferredTasks) + @($OpenTasks)) {
        if ($null -eq $task) {
            continue
        }

        $taskId = [string]$task.id
        if ([string]::IsNullOrWhiteSpace($taskId) -or $seen.ContainsKey($taskId)) {
            continue
        }

        $seen[$taskId] = $true
        $queue.Add($task)
    }

    return @($queue)
}

function Dispatch-ReadyTasks {
    param([AllowEmptyCollection()][object[]]$PreferredTasks = @())

    $tasks = @(Get-SharedTasks)
    $openTasks = @($tasks | Where-Object { $_.status -eq 'open' })
    if ($openTasks.Count -eq 0) {
        return @()
    }

    $reservedAgents = @{}
    $dispatches = [System.Collections.Generic.List[object]]::new()
    $queue = Get-DispatchQueue -PreferredTasks $PreferredTasks -OpenTasks $openTasks

    foreach ($task in $queue) {
        $role = Get-TaskDispatchRole -Task $task
        $assignment = Get-AvailableAgentForRole -Role $role -ReservedAgents $reservedAgents -Tasks $tasks
        if ($null -eq $assignment) {
            continue
        }

        try {
            $dispatch = Invoke-TaskDispatch -Task $task -Assignment $assignment
        } catch {
            continue
        }

        if ($null -eq $dispatch) {
            $tasks = @(Get-SharedTasks)
            continue
        }

        $reservedAgents[[string]$dispatch.Agent] = $true
        $dispatches.Add($dispatch)
        $tasks = @(Get-SharedTasks)
    }

    return @($dispatches)
}

function Get-CommanderTargets {
    $labels = Get-AgentLabels
    $targets = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $labels.GetEnumerator()) {
        if ((ConvertTo-InferredWinsmuxRole ([string]$entry.Key)) -eq 'Commander') {
            $targets.Add([string]$entry.Key)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_COMMANDER_TARGET)) {
        foreach ($value in ($env:WINSMUX_COMMANDER_TARGET -split ',')) {
            $trimmed = $value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $targets.Add($trimmed)
            }
        }
    }

    return @($targets | Sort-Object -Unique)
}

function New-CompletionSummary {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [AllowEmptyCollection()][object[]]$UnblockedTasks = @(),
        [AllowEmptyCollection()][object[]]$Dispatches = @()
    )

    $unblockedSummary = if ($UnblockedTasks.Count -gt 0) {
        ($UnblockedTasks | ForEach-Object { Get-TaskHooksTaskDescriptor -Task $_ }) -join '; '
    } else {
        'none'
    }

    $dispatchSummary = if ($Dispatches.Count -gt 0) {
        ($Dispatches | ForEach-Object { '{0} -> {1}' -f $_.Agent, $_.TaskId }) -join '; '
    } else {
        'none'
    }

    return "Shared task completed: $(Get-TaskHooksTaskDescriptor -Task $Task). Unblocked: $unblockedSummary. Dispatched: $dispatchSummary."
}

function Notify-Commander {
    param([Parameter(Mandatory = $true)][string]$Summary)

    $targets = Get-CommanderTargets
    if ($targets.Count -eq 0) {
        Write-TaskHooksLog -Event 'commander-notify-skipped' -Details $Summary
        return $false
    }

    $notified = $false
    foreach ($target in $targets) {
        try {
            Invoke-BridgeSend -Target $target -Text $Summary | Out-Null
            Write-TaskHooksLog -Event 'commander-notify' -Details "$target :: $Summary"
            $notified = $true
        } catch {
            Write-TaskHooksLog -Event 'commander-notify-error' -Details "$target :: $($_.Exception.Message)"
        }
    }

    return $notified
}

function OnTaskCreated {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Task)

    $dispatches = Dispatch-ReadyTasks -PreferredTasks @($Task)
    return $dispatches | Where-Object { $_.TaskId -eq [string]$Task.id } | Select-Object -First 1
}

function OnTaskCompleted {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Task)

    $beforeTasks = @(Get-SharedTasks)
    $beforeMap = Get-TaskHooksTaskMap -Tasks $beforeTasks
    $completedTask = Complete-SharedTask -TaskId ([string]$Task.id)
    $afterTasks = @(Get-SharedTasks)

    $newlyUnblocked = @(
        foreach ($candidate in $afterTasks) {
            $candidateId = [string]$candidate.id
            $beforeTask = if ($beforeMap.ContainsKey($candidateId)) { $beforeMap[$candidateId] } else { $null }

            if ($candidate.status -eq 'open' -and $null -ne $beforeTask -and $beforeTask.status -eq 'blocked') {
                $candidate
            }
        }
    )

    $dispatches = Dispatch-ReadyTasks -PreferredTasks $newlyUnblocked
    $summary = New-CompletionSummary -Task $completedTask -UnblockedTasks $newlyUnblocked -Dispatches $dispatches
    Notify-Commander -Summary $summary | Out-Null

    return [PSCustomObject]@{
        Task       = $completedTask
        Unblocked  = @($newlyUnblocked)
        Dispatched = @($dispatches)
    }
}

function Process-TaskHookChanges {
    Start-Sleep -Milliseconds 200

    $oldTasks = @($script:TaskHooksSnapshot)
    $newTasks = @(Get-SharedTasks)

    if ((Get-TaskHooksSnapshotHash -Tasks $oldTasks) -eq (Get-TaskHooksSnapshotHash -Tasks $newTasks)) {
        return
    }

    $oldMap = Get-TaskHooksTaskMap -Tasks $oldTasks
    $completedTasks = [System.Collections.Generic.List[object]]::new()
    $createdTasks = [System.Collections.Generic.List[object]]::new()

    foreach ($task in $newTasks) {
        $taskId = [string]$task.id
        $previousTask = if ($oldMap.ContainsKey($taskId)) { $oldMap[$taskId] } else { $null }

        if ($null -eq $previousTask) {
            if ($task.status -eq 'open') {
                $createdTasks.Add($task)
            }
            continue
        }

        if ($previousTask.status -ne 'done' -and $task.status -eq 'done') {
            $completedTasks.Add($task)
        }
    }

    foreach ($task in $completedTasks) {
        try {
            OnTaskCompleted -Task $task | Out-Null
        } catch {
            Write-TaskHooksLog -Event 'task-completed-error' -Details "$(Get-TaskHooksTaskDescriptor -Task $task) :: $($_.Exception.Message)"
        }
    }

    foreach ($task in $createdTasks) {
        try {
            OnTaskCreated -Task $task | Out-Null
        } catch {
            Write-TaskHooksLog -Event 'task-created-error' -Details "$(Get-TaskHooksTaskDescriptor -Task $task) :: $($_.Exception.Message)"
        }
    }

    $script:TaskHooksSnapshot = @(Get-SharedTasks)
}

function Register-TaskHooks {
    [CmdletBinding()]
    param(
        [string]$ProjectDir = (Get-Location).Path,
        [switch]$InProcess
    )

    $resolvedProjectDir = Resolve-TaskHooksProjectDir -Path $ProjectDir

    if (-not $InProcess) {
        Unregister-TaskHooks -ProjectDir $resolvedProjectDir | Out-Null

        $stopPath = Get-TaskHooksStopPath -ProjectRoot $resolvedProjectDir
        if (Test-Path -LiteralPath $stopPath) {
            Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
        }

        $process = Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile',
            '-File',
            $script:TaskHooksScriptPath,
            '-Watch',
            '-ProjectDir',
            $resolvedProjectDir
        ) -WorkingDirectory $resolvedProjectDir -WindowStyle Hidden -PassThru

        $record = [PSCustomObject]@{
            pid        = $process.Id
            projectDir = $resolvedProjectDir
            started    = (Get-Date).ToString('o')
        }

        $record | ConvertTo-Json | Set-Content -LiteralPath (Get-TaskHooksPidPath -ProjectRoot $resolvedProjectDir) -Encoding UTF8
        return $record
    }

    $script:TaskHooksProjectDir = $resolvedProjectDir
    Set-Location -LiteralPath $resolvedProjectDir
    Initialize-SharedTaskStore

    if ($null -ne $script:TaskHooksWatcher) {
        Unregister-TaskHooks -ProjectDir $resolvedProjectDir -InProcess | Out-Null
    }

    $tasksPath = Get-SharedTasksFilePath
    $watcher = [System.IO.FileSystemWatcher]::new(
        (Split-Path -Path $tasksPath -Parent),
        (Split-Path -Path $tasksPath -Leaf)
    )
    $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size, CreationTime'
    $watcher.IncludeSubdirectories = $false
    $watcher.EnableRaisingEvents = $true

    $script:TaskHooksWatcher = $watcher
    $script:TaskHooksSnapshot = @(Get-SharedTasks)
    $script:TaskHooksEventIds = @(
        'winsmux.taskhooks.changed'
        'winsmux.taskhooks.created'
        'winsmux.taskhooks.renamed'
    )

    Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier $script:TaskHooksEventIds[0] | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier $script:TaskHooksEventIds[1] | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Renamed -SourceIdentifier $script:TaskHooksEventIds[2] | Out-Null

    Write-TaskHooksLog -Event 'watcher-registered' -Details $resolvedProjectDir

    return [PSCustomObject]@{
        ProjectDir = $resolvedProjectDir
        TasksFile  = $tasksPath
    }
}

function Unregister-TaskHooks {
    [CmdletBinding()]
    param(
        [string]$ProjectDir = (Get-Location).Path,
        [switch]$InProcess
    )

    $resolvedProjectDir = Resolve-TaskHooksProjectDir -Path $ProjectDir

    if (-not $InProcess) {
        $record = Get-TaskHooksHostRecord -ProjectRoot $resolvedProjectDir
        if ($null -eq $record) {
            Remove-TaskHooksHostRecord -ProjectRoot $resolvedProjectDir
            return $false
        }

        $stopPath = Get-TaskHooksStopPath -ProjectRoot $resolvedProjectDir
        Set-Content -LiteralPath $stopPath -Value (Get-Date).ToString('o') -Encoding UTF8

        if ($record.pid -match '^\d+$') {
            $process = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
            if ($process) {
                for ($attempt = 0; $attempt -lt 20 -and -not $process.HasExited; $attempt++) {
                    Start-Sleep -Milliseconds 200
                    $process.Refresh()
                }

                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
            }
        }

        Remove-TaskHooksHostRecord -ProjectRoot $resolvedProjectDir
        return $true
    }

    foreach ($eventId in @($script:TaskHooksEventIds)) {
        Get-EventSubscriber -SourceIdentifier $eventId -ErrorAction SilentlyContinue | Unregister-Event -Force -ErrorAction SilentlyContinue
        Get-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    }

    if ($null -ne $script:TaskHooksWatcher) {
        $script:TaskHooksWatcher.EnableRaisingEvents = $false
        $script:TaskHooksWatcher.Dispose()
    }

    $script:TaskHooksWatcher = $null
    $script:TaskHooksEventIds = @()
    $script:TaskHooksSnapshot = @()
    Write-TaskHooksLog -Event 'watcher-unregistered' -Details $resolvedProjectDir

    return $true
}

function Clear-TaskHookEvents {
    foreach ($eventId in @($script:TaskHooksEventIds)) {
        Get-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    }
}

function Start-TaskHooksWatcherLoop {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $resolvedProjectDir = Resolve-TaskHooksProjectDir -Path $ProjectDir
    $script:TaskHooksProjectDir = $resolvedProjectDir
    Set-Location -LiteralPath $resolvedProjectDir
    Register-TaskHooks -ProjectDir $resolvedProjectDir -InProcess | Out-Null
    Write-TaskHooksLog -Event 'watcher-started' -Details "pid=$PID"

    try {
        while ($true) {
            if (Test-Path -LiteralPath (Get-TaskHooksStopPath -ProjectRoot $resolvedProjectDir)) {
                break
            }

            $event = Wait-Event -Timeout 2
            if ($null -eq $event) {
                continue
            }

            $sourceId = [string]$event.SourceIdentifier
            Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue

            if ($script:TaskHooksEventIds -contains $sourceId) {
                Clear-TaskHookEvents
                Process-TaskHookChanges
            }
        }
    } finally {
        Unregister-TaskHooks -ProjectDir $resolvedProjectDir -InProcess | Out-Null
        Remove-TaskHooksHostRecord -ProjectRoot $resolvedProjectDir
        Write-TaskHooksLog -Event 'watcher-stopped' -Details "pid=$PID"
    }
}

if ($Watch) {
    Start-TaskHooksWatcherLoop -ProjectDir $ProjectDir
}
