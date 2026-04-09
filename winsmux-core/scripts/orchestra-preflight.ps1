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
    return $processName -in @('codex', 'pwsh', 'powershell')
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

    if ($processName -eq 'node') {
        if ($matchesSharedMarker) {
            return $true
        }

        foreach ($marker in @($ProjectDir, 'winsmux') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
            if ($commandLine.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }

        return $false
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
        $paneRootIdSet = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($rid in @($PaneRootIds)) { [void]$paneRootIdSet.Add([int]$rid) }
        foreach ($descendantId in $descendantIds) {
            if ($paneRootIdSet.Contains([int]$descendantId)) {
                continue
            }
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
        $processName = Get-OrchestraManagedProcessName -Name ([string]$process.Name)
        if (-not (Test-OrchestraManagedProcess -Process $process) -and $processName -ne 'node') {
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
        [Parameter(Mandatory = $true)][string]$WinsmuxBin
    )

    $snapshot = Get-ProcessSnapshot
    $protectedIds = Get-AncestorProcessIds -Snapshot $snapshot -ProcessId $PID
    $paneRootIds = @()

    & $WinsmuxBin has-session -t $SessionName 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) {
        $panePidOutput = & $WinsmuxBin list-panes -t $SessionName -F '#{pane_pid}' 2>$null
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

function Get-OrchestraSessionRegistryDir {
    $homeDir = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($homeDir)) {
        $homeDir = $env:HOME
    }

    if ([string]::IsNullOrWhiteSpace($homeDir)) {
        return $null
    }

    return (Join-Path $homeDir '.psmux')
}

function Get-OrchestraSessionPortFilePath {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    $registryDir = Get-OrchestraSessionRegistryDir
    if ([string]::IsNullOrWhiteSpace($registryDir)) {
        return $null
    }

    return (Join-Path $registryDir "$SessionName.port")
}

function Get-OrchestraSessionKeyFilePath {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    $registryDir = Get-OrchestraSessionRegistryDir
    if ([string]::IsNullOrWhiteSpace($registryDir)) {
        return $null
    }

    return (Join-Path $registryDir "$SessionName.key")
}

function Get-OrchestraSessionPort {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    $portFilePath = Get-OrchestraSessionPortFilePath -SessionName $SessionName
    if ([string]::IsNullOrWhiteSpace($portFilePath) -or -not (Test-Path -LiteralPath $portFilePath)) {
        return $null
    }

    $rawPort = (Get-Content -LiteralPath $portFilePath -Raw -Encoding UTF8).Trim()
    $port = 0
    if (-not [int]::TryParse($rawPort, [ref]$port)) {
        return $null
    }

    return $port
}

function Test-OrchestraTcpConnection {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 500
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $connectTask.Wait($TimeoutMs)) {
            return $false
        }

        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Test-OrchestraSessionAuthResponse {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 500
    )

    $sessionKey = ''
    $keyFilePath = Get-OrchestraSessionKeyFilePath -SessionName $SessionName
    if (-not [string]::IsNullOrWhiteSpace($keyFilePath) -and (Test-Path -LiteralPath $keyFilePath)) {
        $sessionKey = (Get-Content -LiteralPath $keyFilePath -Raw -Encoding UTF8).Trim()
    }

    $client = [System.Net.Sockets.TcpClient]::new()
    $stream = $null

    try {
        $connectTask = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $connectTask.Wait($TimeoutMs)) {
            return $false
        }

        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs
        $stream = $client.GetStream()
        $payload = [System.Text.Encoding]::UTF8.GetBytes(("AUTH {0}`nsession-info`n" -f $sessionKey))
        $stream.Write($payload, 0, $payload.Length)
        $stream.Flush()

        $buffer = [byte[]]::new(256)
        $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
        if ($bytesRead -le 0) {
            return $false
        }

        $response = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $bytesRead)
        return $response.Contains('OK')
    } catch {
        return $false
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }

        $client.Dispose()
    }
}

function Invoke-OrchestraHasSessionProbe {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$WinsmuxBin
    )

    & $WinsmuxBin has-session -t $SessionName 1>$null 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-OrchestraServerHealth {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$WinsmuxBin,
        [int]$TimeoutMs = 500
    )

    $portFilePath = Get-OrchestraSessionPortFilePath -SessionName $SessionName
    if ([string]::IsNullOrWhiteSpace($portFilePath) -or -not (Test-Path -LiteralPath $portFilePath)) {
        return 'Missing'
    }

    $port = Get-OrchestraSessionPort -SessionName $SessionName
    if ($null -eq $port) {
        return 'Unhealthy'
    }

    if (-not (Test-OrchestraTcpConnection -Port $port -TimeoutMs $TimeoutMs)) {
        return 'Unhealthy'
    }

    if (-not (Test-OrchestraSessionAuthResponse -SessionName $SessionName -Port $port -TimeoutMs $TimeoutMs)) {
        return 'Unhealthy'
    }

    if (-not (Invoke-OrchestraHasSessionProbe -SessionName $SessionName -WinsmuxBin $WinsmuxBin)) {
        return 'Unhealthy'
    }

    return 'Healthy'
}

function Clear-OrchestraSessionRegistration {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    foreach ($path in @(
        (Get-OrchestraSessionPortFilePath -SessionName $SessionName),
        (Get-OrchestraSessionKeyFilePath -SessionName $SessionName)
    )) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            continue
        }

        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}
