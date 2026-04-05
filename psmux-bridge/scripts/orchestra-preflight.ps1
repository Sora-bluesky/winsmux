$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-ProcessSnapshot {
    try {
        $processes = @(Get-CimInstance Win32_Process -OperationTimeoutSec 10)
    } catch {
        $processes = @(Get-Process | ForEach-Object {
            [PSCustomObject]@{
                ProcessId       = $_.Id
                ParentProcessId = if ($_.Parent) { $_.Parent.Id } else { 0 }
                CommandLine     = $_.ProcessName
                Name            = $_.ProcessName
            }
        })
    }
    $byId = @{}
    $childrenByParent = @{}

    foreach ($process in $processes) {
        $byId[[int]$process.ProcessId] = $process
        $parentId = [int]$process.ParentProcessId
        if (-not $childrenByParent.ContainsKey($parentId)) {
            $childrenByParent[$parentId] = [System.Collections.Generic.List[object]]::new()
        }

        $childrenByParent[$parentId].Add($process)
    }

    return [PSCustomObject]@{
        Processes        = $processes
        ById             = $byId
        ChildrenByParent = $childrenByParent
    }
}

function Get-AncestorProcessIds {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][int]$ProcessId
    )

    $ids = [System.Collections.Generic.HashSet[int]]::new()
    $currentId = $ProcessId

    while ($currentId -gt 0 -and $Snapshot.ById.ContainsKey($currentId)) {
        if (-not $ids.Add($currentId)) {
            break
        }

        $currentId = [int]$Snapshot.ById[$currentId].ParentProcessId
    }

    return $ids
}

function Get-DescendantProcessIds {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][int[]]$RootProcessIds
    )

    $ids = [System.Collections.Generic.HashSet[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()

    foreach ($rootId in $RootProcessIds) {
        if ($rootId -gt 0) {
            $queue.Enqueue($rootId)
        }
    }

    while ($queue.Count -gt 0) {
        $currentId = $queue.Dequeue()
        if (-not $ids.Add($currentId)) {
            continue
        }

        if (-not $Snapshot.ChildrenByParent.ContainsKey($currentId)) {
            continue
        }

        foreach ($child in $Snapshot.ChildrenByParent[$currentId]) {
            $queue.Enqueue([int]$child.ProcessId)
        }
    }

    return $ids
}

function Get-OrchestraManagedProcessName {
    param([AllowEmptyString()][string]$Name)

    $raw = ([string]$Name).Trim().ToLowerInvariant()
    if ($raw.EndsWith('.exe')) {
        return $raw.Substring(0, $raw.Length - 4)
    }

    return $raw
}

function Test-OrchestraManagedProcess {
    param($Process)

    $processName = Get-OrchestraManagedProcessName -Name ([string]$Process.Name)
    return $processName -in @('codex', 'node', 'pwsh', 'powershell')
}

function Test-OrchestraZombieProcessMatch {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [Parameter(Mandatory = $true)][string]$BridgeScript,
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    $processName = Get-OrchestraManagedProcessName -Name ([string]$Process.Name)
    if ($processName -notin @('codex', 'node', 'pwsh', 'powershell')) {
        return $false
    }

    $commandLine = [string]$Process.CommandLine
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return $false
    }

    $builderWorktreeRoot = Join-Path $ProjectDir '.worktrees'
    $gitWorktreesRoot = Join-Path $GitWorktreeDir 'worktrees'
    $sharedMarkers = @(
        $BridgeScript,
        $SessionName,
        $builderWorktreeRoot,
        $gitWorktreesRoot,
        'worktree-builder-'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $matchesSharedMarker = $false
    foreach ($marker in $sharedMarkers) {
        if ($commandLine.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $matchesSharedMarker = $true
            break
        }
    }

    if ($processName -in @('pwsh', 'powershell')) {
        return $matchesSharedMarker
    }

    if ($matchesSharedMarker) {
        return $true
    }

    foreach ($marker in @($ProjectDir, $GitWorktreeDir) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
        if ($commandLine.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}

function Get-OrchestraZombieVictims {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.HashSet[int]]$ProtectedIds,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [Parameter(Mandatory = $true)][string]$BridgeScript,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [int[]]$PaneRootIds = @()
    )

    $candidateIds = [System.Collections.Generic.HashSet[int]]::new()

    if (@($PaneRootIds).Count -gt 0) {
        $descendantIds = Get-DescendantProcessIds -Snapshot $Snapshot -RootProcessIds $PaneRootIds
        foreach ($descendantId in $descendantIds) {
            if (-not $Snapshot.ById.ContainsKey($descendantId)) {
                continue
            }

            $process = $Snapshot.ById[$descendantId]
            if (Test-OrchestraManagedProcess -Process $process) {
                [void]$candidateIds.Add([int]$descendantId)
            }
        }
    }

    foreach ($process in $Snapshot.Processes) {
        if (-not (Test-OrchestraManagedProcess -Process $process)) {
            continue
        }

        $processId = [int]$process.ProcessId
        $parentId = [int]$process.ParentProcessId
        $parentMissing = ($parentId -le 0) -or (-not $Snapshot.ById.ContainsKey($parentId))

        if (-not $parentMissing) {
            continue
        }

        if (Test-OrchestraZombieProcessMatch -Process $process -ProjectDir $ProjectDir -GitWorktreeDir $GitWorktreeDir -BridgeScript $BridgeScript -SessionName $SessionName) {
            [void]$candidateIds.Add($processId)
        }
    }

    return @(
        $candidateIds |
            Where-Object { -not $ProtectedIds.Contains([int]$_) -and $Snapshot.ById.ContainsKey([int]$_) } |
            Sort-Object -Unique |
            ForEach-Object { $Snapshot.ById[[int]$_] }
    )
}

function Remove-OrchestraZombieProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [Parameter(Mandatory = $true)][string]$BridgeScript,
        [Parameter(Mandatory = $true)][string]$PsmuxBin
    )

    $snapshot = Get-ProcessSnapshot
    $protectedIds = Get-AncestorProcessIds -Snapshot $snapshot -ProcessId $PID
    $paneRootIds = @()

    & $PsmuxBin has-session -t $SessionName 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) {
        $panePidOutput = & $PsmuxBin list-panes -t $SessionName -F '#{pane_pid}' 2>$null
        $paneRootIds = @(
            $panePidOutput |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -match '^\d+$' } |
                ForEach-Object { [int]$_ }
        )
    }

    $victims = Get-OrchestraZombieVictims `
        -Snapshot $snapshot `
        -ProtectedIds $protectedIds `
        -ProjectDir $ProjectDir `
        -GitWorktreeDir $GitWorktreeDir `
        -BridgeScript $BridgeScript `
        -SessionName $SessionName `
        -PaneRootIds $paneRootIds

    $killed = [System.Collections.Generic.List[object]]::new()
    foreach ($victim in $victims) {
        try {
            Stop-Process -Id ([int]$victim.ProcessId) -Force -ErrorAction Stop
            $killed.Add($victim) | Out-Null
            Write-Host ("Preflight: killed zombie process {0} ({1})" -f $victim.Name, $victim.ProcessId)
            Write-WinsmuxLog -Level INFO -Event 'preflight.zombie_process.killed' -Message ("Killed zombie process {0} ({1})." -f $victim.Name, $victim.ProcessId) -Data @{ process_name = $victim.Name; process_id = [int]$victim.ProcessId } | Out-Null
        } catch {
            Write-Warning ("Preflight: failed to kill zombie process {0} ({1}): {2}" -f $victim.Name, $victim.ProcessId, $_.Exception.Message)
        }
    }

    return [PSCustomObject]@{
        Victims = @($victims)
        Killed  = @($killed)
    }
}
