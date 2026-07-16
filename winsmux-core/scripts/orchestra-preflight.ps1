$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command Invoke-WinsmuxBridgeCommand -ErrorAction SilentlyContinue)) {
    $settingsScript = Join-Path $PSScriptRoot 'settings.ps1'
    if (Test-Path -LiteralPath $settingsScript -PathType Leaf) {
        . $settingsScript
    }
}

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

    Invoke-WinsmuxBridgeCommand -WinsmuxBin $WinsmuxBin -Arguments @('has-session', '-t', $SessionName) 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) {
        $panePidOutput = Invoke-WinsmuxBridgeCommand -WinsmuxBin $WinsmuxBin -Arguments @('list-panes', '-t', $SessionName, '-F', '#{pane_pid}') 2>$null
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
            if (Get-Command Write-WinsmuxLog -ErrorAction SilentlyContinue) {
                Write-WinsmuxLog -Level INFO -Event 'preflight.zombie_process.killed' -Message ("Killed zombie process {0} ({1})." -f $victim.Name, $victim.ProcessId) -Data @{ process_name = $victim.Name; process_id = [int]$victim.ProcessId } | Out-Null
            }
        } catch {
            Write-Warning ("Preflight: failed to kill zombie process {0} ({1}): {2}" -f $victim.Name, $victim.ProcessId, $_.Exception.Message)
        }
    }

    return [PSCustomObject]@{
        Victims = @($victims)
        Killed  = @($killed)
    }
}

function Get-OrchestraBridgeSessionNamespace {
    $namespace = $env:WINSMUX_BRIDGE_SESSION_NAMESPACE
    if ([string]::IsNullOrWhiteSpace($namespace)) {
        if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_BRIDGE_SOCKET_S)) {
            $namespace = Get-WinsmuxSocketNamespaceBase -SocketSelector $env:WINSMUX_BRIDGE_SOCKET_S
        } elseif (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_BRIDGE_NAMESPACE_L)) {
            $namespace = $env:WINSMUX_BRIDGE_NAMESPACE_L
        }
    }

    if ([string]::IsNullOrWhiteSpace($namespace)) {
        return ''
    }
    return $namespace.Trim()
}

function ConvertFrom-OrchestraCommandLineTokens {
    param([Parameter(Mandatory = $true)][string]$CommandLine)

    $tokens = [System.Collections.Generic.List[string]]::new()
    $token = [System.Text.StringBuilder]::new()
    $quote = [char]0
    $tokenWasQuoted = $false
    $malformed = $false
    $optionParsingStopped = $false

    for ($index = 0; $index -lt $CommandLine.Length; $index++) {
        $character = $CommandLine[$index]
        if ($quote -ne [char]0) {
            if ($character -eq $quote) {
                $quote = [char]0
                $tokenWasQuoted = $true
                continue
            }
            if ($quote -eq '"' -and $character -eq '\' -and $index + 1 -lt $CommandLine.Length -and
                $CommandLine[$index + 1] -eq '"') {
                [void]$token.Append('"')
                $index++
                continue
            }
            [void]$token.Append($character)
            continue
        }

        if ($character -eq '"' -or $character -eq "'") {
            $quote = $character
            $tokenWasQuoted = $true
            continue
        }
        if ([char]::IsWhiteSpace($character)) {
            if ($token.Length -eq 0 -and -not $tokenWasQuoted) {
                continue
            }
            $value = $token.ToString()
            if (-not $optionParsingStopped -and -not $tokenWasQuoted -and
                [string]::Equals($value, '--', [System.StringComparison]::Ordinal)) {
                $optionParsingStopped = $true
            } elseif (-not $optionParsingStopped) {
                $tokens.Add($value) | Out-Null
            }
            [void]$token.Clear()
            $tokenWasQuoted = $false
            continue
        }
        [void]$token.Append($character)
    }

    if ($quote -ne [char]0) {
        $malformed = $true
    } elseif ($token.Length -gt 0 -or $tokenWasQuoted) {
        $value = $token.ToString()
        if (-not $optionParsingStopped -and -not $tokenWasQuoted -and
            [string]::Equals($value, '--', [System.StringComparison]::Ordinal)) {
            $optionParsingStopped = $true
        } elseif (-not $optionParsingStopped) {
            $tokens.Add($value) | Out-Null
        }
    }

    return [PSCustomObject]@{ Tokens = @($tokens); Malformed = $malformed }
}

function Get-OrchestraServerCommandSelectors {
    param([Parameter(Mandatory = $true)][string]$CommandLine)

    $tokenization = ConvertFrom-OrchestraCommandLineTokens -CommandLine $CommandLine
    $tokens = @($tokenization.Tokens)

    $serverCount = 0
    $sessions = [System.Collections.Generic.List[string]]::new()
    $namespaces = [System.Collections.Generic.List[object]]::new()
    $malformed = [bool]$tokenization.Malformed
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $token = [string]$tokens[$index]
        if ([string]::Equals($token, 'server', [System.StringComparison]::OrdinalIgnoreCase)) {
            $serverCount++
            continue
        }

        $kind = ''
        $value = $null
        if ([string]::Equals($token, '-s', [System.StringComparison]::Ordinal) -or
            [string]::Equals($token, '--session', [System.StringComparison]::OrdinalIgnoreCase)) {
            $kind = 'session'
        } elseif ($token.StartsWith('-s=', [System.StringComparison]::Ordinal)) {
            $kind = 'session'; $value = $token.Substring(3)
        } elseif ($token.StartsWith('--session=', [System.StringComparison]::OrdinalIgnoreCase)) {
            $kind = 'session'; $value = $token.Substring('--session='.Length)
        } elseif ([string]::Equals($token, '-S', [System.StringComparison]::Ordinal)) {
            $kind = 'socket'
        } elseif ($token.StartsWith('-S=', [System.StringComparison]::Ordinal)) {
            $kind = 'socket'; $value = $token.Substring(3)
        } elseif ([string]::Equals($token, '-L', [System.StringComparison]::Ordinal)) {
            $kind = 'literal'
        } elseif ($token.StartsWith('-L=', [System.StringComparison]::Ordinal)) {
            $kind = 'literal'; $value = $token.Substring(3)
        } else {
            continue
        }

        if ($null -eq $value) {
            if ($index + 1 -ge $tokens.Count) {
                $malformed = $true
                break
            }
            $index++
            $value = [string]$tokens[$index]
        }
        if ([string]::IsNullOrWhiteSpace([string]$value)) {
            $malformed = $true
            break
        }
        if ($kind -eq 'session') {
            $sessions.Add([string]$value) | Out-Null
        } else {
            $namespaces.Add([PSCustomObject]@{ Kind = $kind; Value = [string]$value }) | Out-Null
        }
    }

    return [PSCustomObject]@{
        Malformed = $malformed
        ServerCount = $serverCount
        Sessions = @($sessions)
        Namespaces = @($namespaces)
    }
}

function Test-OrchestraServerProcessNamespace {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [AllowEmptyString()][string]$Namespace = ''
    )

    $selectors = Get-OrchestraServerCommandSelectors -CommandLine $CommandLine
    if ([bool]$selectors.Malformed) {
        return $false
    }
    $namespaceSelectors = @($selectors.Namespaces)
    if ([string]::IsNullOrWhiteSpace($Namespace)) {
        return $namespaceSelectors.Count -eq 0
    }
    if ($namespaceSelectors.Count -ne 1) {
        return $false
    }

    $selector = $namespaceSelectors[0]
    if ([string]$selector.Kind -eq 'socket') {
        $socketNamespace = Get-WinsmuxSocketNamespaceBase -SocketSelector ([string]$selector.Value)
        return [string]::Equals(
            [string]$socketNamespace,
            $Namespace.Trim(),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    }
    return [string]::Equals(
        [string]$selector.Value,
        $Namespace.Trim(),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Test-OrchestraSessionServerProcess {
    param(
        [AllowNull()]$Process,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [AllowEmptyString()][string]$Namespace = (Get-OrchestraBridgeSessionNamespace)
    )

    if ($null -eq $Process) {
        return $false
    }

    $processName = Get-OrchestraManagedProcessName -Name ([string]$Process.Name)
    if ($processName -notin @('winsmux', 'psmux', 'pmux', 'tmux')) {
        return $false
    }

    $commandLine = [string]$Process.CommandLine
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return $false
    }

    $selectors = Get-OrchestraServerCommandSelectors -CommandLine $commandLine
    if ([bool]$selectors.Malformed -or [int]$selectors.ServerCount -ne 1) {
        return $false
    }
    $sessions = @($selectors.Sessions)
    if ($sessions.Count -ne 1 -or
        -not [string]::Equals([string]$sessions[0], $SessionName, [System.StringComparison]::Ordinal)) {
        return $false
    }

    return Test-OrchestraServerProcessNamespace -CommandLine $commandLine -Namespace $Namespace
}

function Remove-OrchestraSessionServerProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$WinsmuxBin,
        [switch]$IncludeExpectedBinary,
        [AllowNull()]$ProcessSnapshot = $null,
        [scriptblock]$PostStopSnapshotResolver = { Get-ProcessSnapshot },
        [ValidateRange(1, 100)][int]$VerificationAttempts = 20,
        [ValidateRange(0, 5000)][int]$VerificationIntervalMilliseconds = 100
    )

    $snapshot = if ($null -ne $ProcessSnapshot) { $ProcessSnapshot } else { Get-ProcessSnapshot }
    $protectedIds = Get-AncestorProcessIds -Snapshot $snapshot -ProcessId $PID
    if ($null -eq $protectedIds) {
        $protectedIds = [System.Collections.Generic.HashSet[int]]::new()
    }

    $expectedWinsmuxPath = ''
    if (-not [string]::IsNullOrWhiteSpace($WinsmuxBin)) {
        try {
            $expectedWinsmuxPath = [System.IO.Path]::GetFullPath($WinsmuxBin)
        } catch {
            $expectedWinsmuxPath = [string]$WinsmuxBin
        }
    }

    $sessionNamespace = Get-OrchestraBridgeSessionNamespace
    $selectRetirementCandidates = {
        param([Parameter(Mandatory = $true)]$InputSnapshot)

        return @(
            $InputSnapshot.Processes |
                Where-Object { Test-OrchestraSessionServerProcess -Process $_ -SessionName $SessionName -Namespace $sessionNamespace } |
                Where-Object {
                    $candidatePath = if ($null -ne $_.PSObject.Properties['ExecutablePath']) { [string]$_.ExecutablePath } else { '' }
                    $isExpectedBinary = -not [string]::IsNullOrWhiteSpace($candidatePath) -and
                        -not [string]::IsNullOrWhiteSpace($expectedWinsmuxPath) -and
                        [string]::Equals($candidatePath, $expectedWinsmuxPath, [System.StringComparison]::OrdinalIgnoreCase)
                    return ($IncludeExpectedBinary -or -not $isExpectedBinary)
                } |
                Sort-Object -Property ProcessId
        )
    }
    $serverProcesses = @(
        $snapshot.Processes |
            Where-Object { Test-OrchestraSessionServerProcess -Process $_ -SessionName $SessionName -Namespace $sessionNamespace } |
            Sort-Object -Property ProcessId
    )
    $retirementCandidates = @(& $selectRetirementCandidates $snapshot)
    $killed = [System.Collections.Generic.List[object]]::new()
    $stopErrors = [System.Collections.Generic.List[string]]::new()

    foreach ($serverProcess in $retirementCandidates) {
        $serverPid = [int]$serverProcess.ProcessId
        if ($protectedIds.Contains($serverPid)) {
            continue
        }

        $actualPath = ''
        if ($null -ne $serverProcess.PSObject.Properties['ExecutablePath']) {
            $actualPath = [string]$serverProcess.ExecutablePath
        }
        $idsToStop = @(Get-DescendantProcessIds -Snapshot $snapshot -RootProcessIds @($serverPid)) |
            Sort-Object -Descending
        foreach ($processId in $idsToStop) {
            if ($protectedIds.Contains([int]$processId)) {
                continue
            }
            if (-not $snapshot.ById.ContainsKey([int]$processId)) {
                continue
            }

            try {
                Stop-Process -Id ([int]$processId) -Force -ErrorAction Stop
                $process = $snapshot.ById[[int]$processId]
                $killed.Add($process) | Out-Null
                Write-Host ("Preflight: killed stale session process {0} ({1}) for {2}" -f $process.Name, [int]$processId, $SessionName)
                if (Get-Command Write-WinsmuxLog -ErrorAction SilentlyContinue) {
                    Write-WinsmuxLog -Level INFO -Event 'preflight.session_process.killed' -Message ("Killed stale session process {0} ({1}) for {2}." -f $process.Name, [int]$processId, $SessionName) -Data @{
                        process_name = [string]$process.Name
                        process_id = [int]$processId
                        session_name = $SessionName
                        executable_path = $actualPath
                        expected_winsmux = $expectedWinsmuxPath
                    } | Out-Null
                }
            } catch {
                $stopError = "process $([int]$processId): $($_.Exception.Message)"
                $stopErrors.Add($stopError) | Out-Null
                Write-Warning ("Preflight: failed to kill stale session process {0}: {1}" -f [int]$processId, $_.Exception.Message)
            }
        }
    }

    $remaining = @()
    foreach ($attempt in 1..$VerificationAttempts) {
        $postStopSnapshot = & $PostStopSnapshotResolver
        if ($null -eq $postStopSnapshot) {
            throw 'Preflight: post-stop process snapshot is unavailable.'
        }
        $remaining = @(& $selectRetirementCandidates $postStopSnapshot)
        if ($remaining.Count -eq 0) {
            break
        }
        if ($attempt -lt $VerificationAttempts -and $VerificationIntervalMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $VerificationIntervalMilliseconds
        }
    }

    if ($stopErrors.Count -gt 0 -or $remaining.Count -gt 0) {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($stopErrors.Count -gt 0) {
            $parts.Add('stop failures: ' + ($stopErrors -join '; ')) | Out-Null
        }
        if ($remaining.Count -gt 0) {
            $remainingIds = @($remaining | ForEach-Object { [string][int]$_.ProcessId }) -join ', '
            $parts.Add("server processes remain after retirement: $remainingIds") | Out-Null
        }
        throw ('Preflight: session server retirement incomplete: ' + ($parts -join ' | '))
    }

    return [PSCustomObject]@{
        SessionProcesses         = @($serverProcesses)
        Killed                   = @($killed)
        RemainingSessionProcesses = @($remaining)
        Errors                   = @($stopErrors)
    }
}

function Test-OrchestraWarmProcess {
    param([AllowNull()]$Process)

    if ($null -eq $Process) {
        return $false
    }

    $processName = Get-OrchestraManagedProcessName -Name ([string]$Process.Name)
    if ($processName -notin @('winsmux', 'psmux', 'pmux', 'tmux')) {
        return $false
    }

    $commandLine = [string]$Process.CommandLine
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return $false
    }

    return (
        $commandLine.IndexOf('__warm__', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $commandLine.IndexOf('server', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    )
}

function Remove-OrchestraExcessWarmProcesses {
    param(
        [int]$MaxWarmProcesses = 1,
        [AllowNull()]$ProcessSnapshot = $null
    )

    $snapshot = if ($null -ne $ProcessSnapshot) { $ProcessSnapshot } else { Get-ProcessSnapshot }
    $protectedIds = Get-AncestorProcessIds -Snapshot $snapshot -ProcessId $PID
    if ($null -eq $protectedIds) {
        $protectedIds = [System.Collections.Generic.HashSet[int]]::new()
    }
    $warmProcesses = @(
        $snapshot.Processes |
            Where-Object { Test-OrchestraWarmProcess -Process $_ } |
            Sort-Object -Property ProcessId
    )

    $maxAllowed = [Math]::Max(0, $MaxWarmProcesses)
    $victims = @($warmProcesses | Select-Object -Skip $maxAllowed)
    $killed = [System.Collections.Generic.List[object]]::new()

    foreach ($victim in $victims) {
        $victimProcessId = [int]$victim.ProcessId
        if ($protectedIds.Contains($victimProcessId)) {
            continue
        }

        try {
            Stop-Process -Id $victimProcessId -Force -ErrorAction Stop
            $killed.Add($victim) | Out-Null
            Write-Host ("Preflight: killed excess warm server {0} ({1})" -f $victim.Name, $victimProcessId)
            if (Get-Command Write-WinsmuxLog -ErrorAction SilentlyContinue) {
                Write-WinsmuxLog -Level INFO -Event 'preflight.warm_process.killed' -Message ("Killed excess warm server {0} ({1})." -f $victim.Name, $victimProcessId) -Data @{ process_name = $victim.Name; process_id = $victimProcessId } | Out-Null
            }
        } catch {
            Write-Warning ("Preflight: failed to kill excess warm server {0} ({1}): {2}" -f $victim.Name, $victimProcessId, $_.Exception.Message)
        }
    }

    return [PSCustomObject]@{
        WarmProcesses    = @($warmProcesses)
        Victims          = @($victims)
        Killed           = @($killed)
        MaxWarmProcesses = $maxAllowed
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

function Get-StableSocketNamespaceHash {
    param([Parameter(Mandatory = $true)][string]$Value)

    $hash = [System.Numerics.BigInteger]::Parse('14695981039346656037')
    $prime = [System.Numerics.BigInteger]::Parse('1099511628211')
    $modulus = [System.Numerics.BigInteger]::Pow([System.Numerics.BigInteger]2, 64)
    foreach ($byte in [System.Text.Encoding]::UTF8.GetBytes($Value)) {
        $hash = [System.Numerics.BigInteger]::Remainder(($hash -bxor [System.Numerics.BigInteger]$byte) * $prime, $modulus)
    }

    return ('{0:x16}' -f [uint64]$hash)
}

function Get-WinsmuxSocketNamespaceBase {
    param([Parameter(Mandatory = $true)][string]$SocketSelector)

    $selector = $SocketSelector.Trim()
    if ([string]::IsNullOrWhiteSpace($selector)) {
        return $null
    }

    $looksLikePath = $selector.Contains('\') -or $selector.Contains('/') -or [System.IO.Path]::HasExtension($selector)
    if (-not $looksLikePath) {
        return $selector
    }

    try {
        $path = $selector
        if (-not [System.IO.Path]::IsPathRooted($path)) {
            $path = Join-Path (Get-Location) $path
        }

        $normalized = [System.IO.Path]::GetFullPath($path).Replace('\', '/')
        if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
            $normalized = $normalized.ToLowerInvariant()
        }

        return ('socket-{0}' -f (Get-StableSocketNamespaceHash -Value $normalized))
    } catch {
        return ('socket-{0}' -f (Get-StableSocketNamespaceHash -Value $selector.Replace('\', '/').ToLowerInvariant()))
    }
}

function Get-OrchestraSessionRegistryBaseName {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    $namespace = Get-OrchestraBridgeSessionNamespace

    if ([string]::IsNullOrWhiteSpace($namespace)) {
        return $SessionName
    }

    return ("{0}__{1}" -f $namespace.Trim(), $SessionName)
}

function Get-OrchestraSessionPortFilePath {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    $registryDir = Get-OrchestraSessionRegistryDir
    if ([string]::IsNullOrWhiteSpace($registryDir)) {
        return $null
    }

    $registryBaseName = Get-OrchestraSessionRegistryBaseName -SessionName $SessionName
    return (Join-Path $registryDir "$registryBaseName.port")
}

function Get-OrchestraSessionKeyFilePath {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    $registryDir = Get-OrchestraSessionRegistryDir
    if ([string]::IsNullOrWhiteSpace($registryDir)) {
        return $null
    }

    $registryBaseName = Get-OrchestraSessionRegistryBaseName -SessionName $SessionName
    return (Join-Path $registryDir "$registryBaseName.key")
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

function New-OrchestraTcpClient {
    return [System.Net.Sockets.TcpClient]::new()
}

function Test-OrchestraTcpConnection {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 500
    )

    $client = New-OrchestraTcpClient
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

    $client = New-OrchestraTcpClient
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
        $lines = @($response -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -eq 0) {
            return $false
        }

        $authOk = $lines[0] -match '^(?i)OK\b'
        $sessionInfoLines = @($lines | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^(?i)OK\b' })
        return ($authOk -and $sessionInfoLines.Count -gt 0)
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

    Invoke-WinsmuxBridgeCommand -WinsmuxBin $WinsmuxBin -Arguments @('has-session', '-t', $SessionName) 1>$null 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-OrchestraSessionPaneCount {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$WinsmuxBin
    )

    $paneOutput = Invoke-WinsmuxBridgeCommand -WinsmuxBin $WinsmuxBin -Arguments @('list-panes', '-t', $SessionName, '-F', '#{pane_id}') 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return @(
        $paneOutput |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ -match '^%\d+$' }
    ).Count
}

function Test-OrchestraServerHealth {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$WinsmuxBin,
        [int]$TimeoutMs = 500,
        [int]$ExpectedPaneCount = 0
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

    if ($ExpectedPaneCount -gt 0) {
        $paneCount = Get-OrchestraSessionPaneCount -SessionName $SessionName -WinsmuxBin $WinsmuxBin
        if ($null -eq $paneCount -or $paneCount -ne $ExpectedPaneCount) {
            return 'Unhealthy'
        }
    }

    return 'Healthy'
}

function Wait-OrchestraServerHealthy {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$WinsmuxBin,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15,
        [ValidateRange(100, 5000)][int]$PollIntervalMilliseconds = 500,
        [int]$ExpectedPaneCount = 0
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempt = 0
    $lastHealth = 'Unknown'
    while ((Get-Date) -lt $deadline) {
        $attempt++
        $lastHealth = Test-OrchestraServerHealth -SessionName $SessionName -WinsmuxBin $WinsmuxBin -TimeoutMs ([Math]::Max($PollIntervalMilliseconds, 500)) -ExpectedPaneCount $ExpectedPaneCount
        if ($lastHealth -eq 'Healthy') {
            return [ordered]@{
                SessionName = $SessionName
                Health      = $lastHealth
                Attempts    = $attempt
            }
        }

        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }

    throw "Orchestra session '$SessionName' did not reach Healthy state within $TimeoutSeconds seconds (last health: $lastHealth)."
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
