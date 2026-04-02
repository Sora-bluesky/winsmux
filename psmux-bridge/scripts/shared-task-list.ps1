<#
.SYNOPSIS
Shared task list helpers for winsmux agents.

.DESCRIPTION
Dot-source this script to load the task functions:

    . "$PSScriptRoot/shared-task-list.ps1"
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SharedTasksDirectoryPath {
    return Join-Path (Get-Location).Path '.winsmux'
}

function Get-SharedTasksFilePath {
    return Join-Path (Get-SharedTasksDirectoryPath) 'tasks.json'
}

function Get-SharedTasksLockPath {
    return Join-Path (Get-SharedTasksDirectoryPath) 'tasks.lock'
}

function Initialize-SharedTaskStore {
    $tasksDir = Get-SharedTasksDirectoryPath
    if (-not (Test-Path -LiteralPath $tasksDir)) {
        New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
    }

    $tasksFile = Get-SharedTasksFilePath
    if (-not (Test-Path -LiteralPath $tasksFile)) {
        Set-Content -LiteralPath $tasksFile -Value '[]' -Encoding UTF8
    }
}

function Invoke-SharedTaskLock {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    Initialize-SharedTaskStore
    $lockDir = Get-SharedTasksLockPath

    while ($true) {
        if (Test-Path -LiteralPath $lockDir) {
            Start-Sleep -Milliseconds 50
            continue
        }

        try {
            New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop | Out-Null
            break
        } catch {
            Start-Sleep -Milliseconds 50
        }
    }

    try {
        return & $ScriptBlock
    } finally {
        if (Test-Path -LiteralPath $lockDir) {
            Remove-Item -LiteralPath $lockDir -Force -Recurse
        }
    }
}

function Read-SharedTasksInternal {
    $tasksFile = Get-SharedTasksFilePath
    Initialize-SharedTaskStore

    $raw = Get-Content -LiteralPath $tasksFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) {
        return @()
    }

    return @($parsed)
}

function Read-SharedTasksFromStream {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileStream]$Stream
    )

    if ($Stream.Length -eq 0) {
        return @()
    }

    $Stream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
    $reader = [System.IO.StreamReader]::new($Stream, [System.Text.Encoding]::UTF8, $true, 1024, $true)
    try {
        $raw = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) {
        return @()
    }

    return @($parsed)
}

function Write-SharedTasksInternal {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Tasks
    )

    $tasksFile = Get-SharedTasksFilePath
    $json = @($Tasks) | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $tasksFile -Value $json -Encoding UTF8
}

function Write-SharedTasksToStream {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileStream]$Stream,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Tasks
    )

    $json = @($Tasks) | ConvertTo-Json -Depth 6
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    $Stream.SetLength(0)
    $Stream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Get-NextSharedTaskId {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Tasks
    )

    $maxId = 0
    foreach ($task in $Tasks) {
        if ($null -ne $task.id -and $task.id -match '^T-(\d+)$') {
            $numericId = [int]$Matches[1]
            if ($numericId -gt $maxId) {
                $maxId = $numericId
            }
        }
    }

    return 'T-{0:D3}' -f ($maxId + 1)
}

function Test-SharedTaskDependenciesSatisfied {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Tasks,
        [Parameter(Mandatory = $true)]$Task
    )

    $dependencies = @($Task.depends_on)
    if ($dependencies.Count -eq 0) {
        return $true
    }

    foreach ($dependencyId in $dependencies) {
        $dependency = $Tasks | Where-Object { $_.id -eq $dependencyId } | Select-Object -First 1
        if ($null -eq $dependency -or $dependency.status -ne 'done') {
            return $false
        }
    }

    return $true
}

function Update-SharedTaskBlockingStates {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Tasks
    )

    foreach ($task in $Tasks) {
        if ($task.status -eq 'blocked' -and (Test-SharedTaskDependenciesSatisfied -Tasks $Tasks -Task $task)) {
            $task.status = 'open'
        }
    }
}

function New-SharedTaskRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Title,
        [string[]]$DependsOn = @(),
        [Parameter(Mandatory = $true)][string]$Status
    )

    return [PSCustomObject][ordered]@{
        id         = $Id
        title      = $Title
        status     = $Status
        claimed_by = $null
        depends_on = @($DependsOn)
        created    = [DateTime]::UtcNow.ToString('o')
    }
}

function Get-SharedTasks {
    return Invoke-SharedTaskLock {
        return @(Read-SharedTasksInternal)
    }
}

function Add-SharedTask {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [string[]]$DependsOn = @()
    )

    return Invoke-SharedTaskLock {
        $tasks = @(Read-SharedTasksInternal)
        $taskId = Get-NextSharedTaskId -Tasks $tasks
        $candidate = [PSCustomObject]@{ depends_on = @($DependsOn) }
        $status = if (Test-SharedTaskDependenciesSatisfied -Tasks $tasks -Task $candidate) { 'open' } else { 'blocked' }
        $task = New-SharedTaskRecord -Id $taskId -Title $Title -DependsOn $DependsOn -Status $status
        $tasks += $task
        Write-SharedTasksInternal -Tasks $tasks
        return $task
    }
}

function Claim-SharedTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$AgentName
    )

    return Invoke-SharedTaskLock {
        Initialize-SharedTaskStore
        $tasksFile = Get-SharedTasksFilePath
        $fileStream = [System.IO.File]::Open(
            $tasksFile,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )

        try {
            $tasks = @(Read-SharedTasksFromStream -Stream $fileStream)
            $task = $tasks | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1

            if ($null -eq $task) {
                throw "Shared task not found: $TaskId"
            }

            if (-not (Test-SharedTaskDependenciesSatisfied -Tasks $tasks -Task $task)) {
                $task.status = 'blocked'
                $task.claimed_by = $null
                Write-SharedTasksToStream -Stream $fileStream -Tasks $tasks
                return 'blocked'
            }

            if ($task.status -eq 'done') {
                return $task
            }

            if ($task.status -eq 'claimed' -and $task.claimed_by -ne $AgentName) {
                return $task
            }

            $task.status = 'claimed'
            $task.claimed_by = $AgentName
            Write-SharedTasksToStream -Stream $fileStream -Tasks $tasks
            return $task
        } finally {
            $fileStream.Dispose()
        }
    }
}

function Complete-SharedTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId
    )

    return Invoke-SharedTaskLock {
        $tasks = @(Read-SharedTasksInternal)
        $task = $tasks | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1

        if ($null -eq $task) {
            throw "Shared task not found: $TaskId"
        }

        $task.status = 'done'
        $task.claimed_by = $null

        foreach ($dependentTask in $tasks) {
            if ($dependentTask.status -ne 'blocked') {
                continue
            }

            if (@($dependentTask.depends_on) -contains $TaskId -and (Test-SharedTaskDependenciesSatisfied -Tasks $tasks -Task $dependentTask)) {
                $dependentTask.status = 'open'
            }
        }

        Write-SharedTasksInternal -Tasks $tasks
        return $task
    }
}

function Get-NextAvailableTask {
    param(
        [Parameter(Mandatory = $true)][string]$AgentName
    )

    return Invoke-SharedTaskLock {
        $tasks = @(Read-SharedTasksInternal)
        Update-SharedTaskBlockingStates -Tasks $tasks

        $task = $tasks |
            Where-Object { $_.status -eq 'open' -and (Test-SharedTaskDependenciesSatisfied -Tasks $tasks -Task $_) } |
            Select-Object -First 1

        if ($null -eq $task) {
            Write-SharedTasksInternal -Tasks $tasks
            return $null
        }

        $task.status = 'claimed'
        $task.claimed_by = $AgentName
        Write-SharedTasksInternal -Tasks $tasks
        return $task
    }
}
