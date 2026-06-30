[CmdletBinding()]
param(
    [switch]$Json,
    [ValidateSet('debug', 'release')]
    [string[]]$Build = @('debug', 'release'),
    [ValidateSet('on', 'off')]
    [string[]]$Warm = @('on', 'off'),
    [ValidateSet('default', 'pwsh-no-profile-no-exit', 'cmd-keep-open')]
    [string[]]$Shell = @('default', 'pwsh-no-profile-no-exit', 'cmd-keep-open'),
    [ValidateSet('fresh', 'stale', 'orphan-key', 'orphan-port')]
    [string[]]$Registry = @('fresh', 'stale', 'orphan-key', 'orphan-port'),
    [ValidateSet('normal', 'early-child-exit', 'forced-server-kill')]
    [string[]]$Exit = @('normal', 'early-child-exit', 'forced-server-kill'),
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$coreRoot = Join-Path $repoRoot 'core'

function Get-NowMillis {
    return [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
}

function Get-WinsmuxExe {
    param([Parameter(Mandatory = $true)][string]$BuildKind)

    $cargoArgs = @('build', '-p', 'winsmux')
    if ($BuildKind -eq 'release') {
        $cargoArgs += '--release'
    }
    Push-Location $repoRoot
    try {
        & cargo @cargoArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "cargo $($cargoArgs -join ' ') failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }

    $targetDir = if ($BuildKind -eq 'release') { 'release' } else { 'debug' }
    $exe = Join-Path $repoRoot "target\$targetDir\winsmux.exe"
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "winsmux binary not found: $exe"
    }
    return (Resolve-Path -LiteralPath $exe).Path
}

function ConvertTo-ReportPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRepo = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\')
    if ($fullPath.StartsWith($fullRepo, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $fullPath.Substring($fullRepo.Length).TrimStart('\') -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($relative)) {
            return '<repo-root>'
        }
        return "<repo-root>/$relative"
    }
    if ($fullPath.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
        return '<temp-fixture-home>'
    }
    return '<local-path>'
}

function Invoke-IsolatedWinsmux {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$FixtureHome,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][bool]$WarmEnabled
    )

    $envNames = @(
        'USERPROFILE',
        'HOME',
        'PSMUX_CONFIG_FILE',
        'PSMUX_NO_WARM',
        'PSMUX_ALLOW_NESTING',
        'PSMUX_TARGET_SESSION',
        'PSMUX_TARGET_FULL',
        'PSMUX_ACTIVE',
        'PSMUX_SESSION',
        'TMUX'
    )
    $saved = @{}
    foreach ($name in $envNames) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        $env:USERPROFILE = $FixtureHome
        $env:HOME = $FixtureHome
        $env:PSMUX_CONFIG_FILE = 'NUL'
        $env:PSMUX_ALLOW_NESTING = '1'
        if ($WarmEnabled) {
            Remove-Item Env:PSMUX_NO_WARM -ErrorAction SilentlyContinue
        } else {
            $env:PSMUX_NO_WARM = '1'
        }
        foreach ($name in @('PSMUX_TARGET_SESSION', 'PSMUX_TARGET_FULL', 'PSMUX_ACTIVE', 'PSMUX_SESSION', 'TMUX')) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }

        $output = & $Exe @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        return [PSCustomObject][ordered]@{
            exit_code = $exitCode
            output = (($output | Out-String).Trim())
            args = @($Arguments)
        }
    } finally {
        foreach ($name in $envNames) {
            if ($null -eq $saved[$name]) {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            } else {
                [Environment]::SetEnvironmentVariable($name, [string]$saved[$name], 'Process')
            }
        }
    }
}

function New-FixtureHome {
    param([Parameter(Mandatory = $true)][string]$Label)

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-v03623-session-" + $Label + "-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root '.psmux') -Force | Out-Null
    return $root
}

function Set-OldFileTimestamp {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path
        $old = (Get-Date).AddMinutes(-10)
        $item.LastWriteTime = $old
        $item.CreationTime = $old
    }
}

function Initialize-RegistryState {
    param(
        [Parameter(Mandatory = $true)][string]$FixtureHome,
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$Exe
    )

    $dir = Join-Path $FixtureHome '.psmux'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $portPath = Join-Path $dir "$Base.port"
    $keyPath = Join-Path $dir "$Base.key"
    $registryPath = Join-Path $dir "$Base.registry.json"
    $oldMillis = (Get-NowMillis) - 600000
    $serverExe = ([System.IO.Path]::GetFullPath($Exe) -replace '\\', '/').ToLowerInvariant()

    switch ($State) {
        'fresh' { return }
        'stale' {
            Set-Content -LiteralPath $portPath -Value '9' -NoNewline -Encoding ASCII
            Set-Content -LiteralPath $keyPath -Value 'fixture-stale-key' -NoNewline -Encoding ASCII
            $payload = [ordered]@{
                protocol_version = 1
                session = $Base
                namespace = $null
                server_pid = 999999
                process_started_at = $oldMillis
                server_exe = $serverExe
                instance_nonce = 'fixture-stale-nonce'
                port = 9
                state = 'ready'
                owner = 'normal'
                created_at = $oldMillis
                ready_at = $oldMillis + 250
            }
            $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $registryPath -Encoding UTF8
            Set-OldFileTimestamp -Path $portPath
            Set-OldFileTimestamp -Path $keyPath
            Set-OldFileTimestamp -Path $registryPath
        }
        'orphan-key' {
            Set-Content -LiteralPath $keyPath -Value 'fixture-orphan-key' -NoNewline -Encoding ASCII
            Set-OldFileTimestamp -Path $keyPath
        }
        'orphan-port' {
            Set-Content -LiteralPath $portPath -Value '9' -NoNewline -Encoding ASCII
            Set-OldFileTimestamp -Path $portPath
        }
    }
}

function Get-SessionCommandArgs {
    param(
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$ShellKind,
        [Parameter(Mandatory = $true)][string]$ExitKind
    )

    $args = @('-L', $Namespace, 'new-session', '-d', '-s', $SessionName)
    if ($ExitKind -eq 'early-child-exit') {
        if ($ShellKind -eq 'pwsh-no-profile-no-exit') {
            return $args + @('--', 'pwsh', '-NoProfile', '-Command', 'exit 0')
        }
        return $args + @('--', 'cmd.exe', '/C', 'exit /B 0')
    }

    switch ($ShellKind) {
        'default' { return $args }
        'pwsh-no-profile-no-exit' {
            return $args + @('--', 'pwsh', '-NoProfile', '-NoExit', '-Command', '$Host.UI.RawUI.WindowTitle = "winsmux-v03623-fixture"')
        }
        'cmd-keep-open' {
            return $args + @('--', 'cmd.exe', '/K', 'title winsmux-v03623-fixture')
        }
    }
}

function Get-RegistryFiles {
    param([Parameter(Mandatory = $true)][string]$FixtureHome)

    $dir = Join-Path $FixtureHome '.psmux'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        $portValue = $null
        if ($_.Extension -eq '.port') {
            try { $portValue = (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop).Trim() } catch { $portValue = '<read-error>' }
        }
        [PSCustomObject][ordered]@{
            name = $_.Name
            extension = $_.Extension
            length = $_.Length
            last_write_time = $_.LastWriteTime.ToString('o')
            port_value = $portValue
            key_content_recorded = $false
        }
    })
}

function Test-AuthHandshake {
    param(
        [Parameter(Mandatory = $true)][string]$FixtureHome,
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Port
    )

    if ($null -eq $Port -or ([string]$Port) -notmatch '^\d+$') {
        return [PSCustomObject][ordered]@{ ok = $false; reason = 'missing-port' }
    }
    $keyPath = Join-Path (Join-Path $FixtureHome '.psmux') "$Base.key"
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
        return [PSCustomObject][ordered]@{ ok = $false; reason = 'missing-key' }
    }
    $key = (Get-Content -LiteralPath $keyPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($key)) {
        return [PSCustomObject][ordered]@{ ok = $false; reason = 'empty-key' }
    }
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect('127.0.0.1', [int]$Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(300)) {
            $client.Close()
            return [PSCustomObject][ordered]@{ ok = $false; reason = 'connect-timeout' }
        }
        $client.EndConnect($iar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 500
        $writer = [System.IO.StreamWriter]::new($stream)
        $writer.NewLine = "`n"
        $writer.AutoFlush = $true
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.WriteLine("AUTH $key")
        $writer.WriteLine('session-info')
        $line = $reader.ReadLine()
        $client.Close()
        return [PSCustomObject][ordered]@{ ok = ($line -eq 'OK'); reason = $line }
    } catch {
        return [PSCustomObject][ordered]@{ ok = $false; reason = $_.Exception.Message }
    }
}

function Invoke-Probe {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$FixtureHome,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][bool]$WarmEnabled
    )

    return Invoke-IsolatedWinsmux -Exe $Exe -FixtureHome $FixtureHome -WarmEnabled $WarmEnabled -Arguments (@('-L', $Namespace, '-t', $SessionName) + $Arguments)
}

function Get-Observation {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$FixtureHome,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][int]$DelayMs,
        [Parameter(Mandatory = $true)][bool]$WarmEnabled
    )

    $base = "$Namespace`__$SessionName"
    $dir = Join-Path $FixtureHome '.psmux'
    $portPath = Join-Path $dir "$Base.port"
    $registryPath = Join-Path $dir "$Base.registry.json"
    $registry = $null
    if (Test-Path -LiteralPath $registryPath -PathType Leaf) {
        try { $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json } catch { $registry = $null }
    }
    $port = $null
    if (Test-Path -LiteralPath $portPath -PathType Leaf) {
        try { $port = (Get-Content -LiteralPath $portPath -Raw).Trim() } catch { $port = $null }
    }

    $listeners = @()
    if ($null -ne $port -and ([string]$port) -match '^\d+$') {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort ([int]$port) -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject][ordered]@{
                local_address = $_.LocalAddress
                local_port = $_.LocalPort
                owning_process = $_.OwningProcess
            }
        })
    }

    $serverPid = $null
    if ($null -ne $registry -and $null -ne $registry.server_pid) {
        $serverPid = [int]$registry.server_pid
    } elseif ($listeners.Count -gt 0) {
        $serverPid = [int]$listeners[0].owning_process
    }

    $serverStart = $null
    if ($null -ne $serverPid) {
        $proc = Get-Process -Id $serverPid -ErrorAction SilentlyContinue
        if ($proc) {
            try { $serverStart = $proc.StartTime.ToString('o') } catch { $serverStart = $null }
        }
    }

    $hasSession = Invoke-Probe -Exe $Exe -FixtureHome $FixtureHome -Namespace $Namespace -SessionName $SessionName -WarmEnabled $WarmEnabled -Arguments @('has-session')
    $listPanes = Invoke-Probe -Exe $Exe -FixtureHome $FixtureHome -Namespace $Namespace -SessionName $SessionName -WarmEnabled $WarmEnabled -Arguments @('list-panes', '-a', '-F', '#{pane_id} #{pane_pid} #{pane_current_command}')

    $paneChildren = @()
    if (-not [string]::IsNullOrWhiteSpace($listPanes.output)) {
        foreach ($line in ($listPanes.output -split "`r?`n")) {
            $parts = $line.Trim() -split '\s+', 3
            if ($parts.Count -ge 2 -and $parts[1] -match '^\d+$') {
                $paneProc = Get-Process -Id ([int]$parts[1]) -ErrorAction SilentlyContinue
                $paneChildren += [PSCustomObject][ordered]@{
                    pane_id = $parts[0]
                    pid = [int]$parts[1]
                    command = if ($parts.Count -ge 3) { $parts[2] } else { '' }
                    process_name = if ($paneProc) { $paneProc.ProcessName } else { $null }
                    start_time = if ($paneProc) { try { $paneProc.StartTime.ToString('o') } catch { $null } } else { $null }
                }
            }
        }
    }

    return [PSCustomObject][ordered]@{
        delay_ms = $DelayMs
        captured_at = (Get-Date).ToString('o')
        server_pid = $serverPid
        process_start_time = $serverStart
        instance_nonce = if ($registry) { $registry.instance_nonce } else { $null }
        listener = $listeners
        port = $port
        registry_files = Get-RegistryFiles -FixtureHome $FixtureHome
        auth_handshake = Test-AuthHandshake -FixtureHome $FixtureHome -Base $base -Port $port
        has_session = [PSCustomObject][ordered]@{ exit_code = $hasSession.exit_code; output = $hasSession.output }
        list_panes = [PSCustomObject][ordered]@{ exit_code = $listPanes.exit_code; output = $listPanes.output }
        pane_child_processes = $paneChildren
        session_state = if ($registry) { $registry.state } else { $null }
    }
}

function Stop-SessionServer {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$FixtureHome,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][bool]$WarmEnabled
    )
    Invoke-IsolatedWinsmux -Exe $Exe -FixtureHome $FixtureHome -WarmEnabled $WarmEnabled -Arguments @('-L', $Namespace, 'kill-server') | Out-Null
}

function Stop-ObservedServer {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Observation)
    if ($null -eq $Observation -or $null -eq $Observation.server_pid) {
        return $false
    }
    $proc = Get-Process -Id ([int]$Observation.server_pid) -ErrorAction SilentlyContinue
    if (-not $proc) {
        return $false
    }
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    return $true
}

function Start-WarmSeed {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$FixtureHome,
        [Parameter(Mandatory = $true)][string]$Namespace
    )

    $seed = 'warmseed'
    $created = Invoke-IsolatedWinsmux -Exe $Exe -FixtureHome $FixtureHome -WarmEnabled $true -Arguments @('-L', $Namespace, 'new-session', '-d', '-s', $seed)
    $warmBase = "$Namespace`____warm__"
    $warmPort = Join-Path (Join-Path $FixtureHome '.psmux') "$warmBase.port"
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $warmPort -PathType Leaf)) {
        Start-Sleep -Milliseconds 100
    }
    return [PSCustomObject][ordered]@{
        command = $created
        warm_port_exists = (Test-Path -LiteralPath $warmPort -PathType Leaf)
    }
}

$binaryByBuild = [ordered]@{}
$exeByBuild = [ordered]@{}
foreach ($kind in $Build) {
    $exe = Get-WinsmuxExe -BuildKind $kind
    $exeByBuild[$kind] = $exe
    $item = Get-Item -LiteralPath $exe
    $binaryByBuild[$kind] = [ordered]@{
        path = ConvertTo-ReportPath -Path $exe
        length = $item.Length
        last_write_time = $item.LastWriteTime.ToString('o')
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash
        version_output = ((& $exe --version 2>&1 | Out-String).Trim())
    }
}

$runs = @()
$failures = @()
$runIndex = 0
foreach ($buildKind in $Build) {
    $exe = [string]$exeByBuild[$buildKind]
    foreach ($warmMode in $Warm) {
        foreach ($shellKind in $Shell) {
            foreach ($registryState in $Registry) {
                foreach ($exitKind in $Exit) {
                    $runIndex++
                    $label = "r$runIndex-$buildKind-$warmMode-$shellKind-$registryState-$exitKind" -replace '[^A-Za-z0-9_.-]', '-'
                    $fixtureHome = New-FixtureHome -Label $label
                    $namespace = ("v03623_" + [guid]::NewGuid().ToString('N').Substring(0, 12))
                    $session = 'target'
                    $base = "$namespace`__$session"
                    $warmEnabled = ($warmMode -eq 'on')
                    $prewarm = $null
                    $createResult = $null
                    $observations = @()
                    $forcedKilled = $false
                    try {
                        Initialize-RegistryState -FixtureHome $fixtureHome -Base $base -State $registryState -Exe $exe
                        if ($warmEnabled) {
                            $prewarm = Start-WarmSeed -Exe $exe -FixtureHome $fixtureHome -Namespace $namespace
                        }
                        $sessionArgs = Get-SessionCommandArgs -Namespace $namespace -SessionName $session -ShellKind $shellKind -ExitKind $exitKind
                        $startedAt = Get-Date
                        $sw = [System.Diagnostics.Stopwatch]::StartNew()
                        $createResult = Invoke-IsolatedWinsmux -Exe $exe -FixtureHome $fixtureHome -WarmEnabled $warmEnabled -Arguments $sessionArgs
                        foreach ($delay in @(250, 1000, 3000)) {
                            $remaining = $delay - [int]$sw.ElapsedMilliseconds
                            if ($remaining -gt 0) {
                                Start-Sleep -Milliseconds $remaining
                            }
                            $observation = Get-Observation -Exe $exe -FixtureHome $fixtureHome -Namespace $namespace -SessionName $session -DelayMs $delay -WarmEnabled $warmEnabled
                            $observations += $observation
                            if ($exitKind -eq 'forced-server-kill' -and -not $forcedKilled -and $delay -eq 250) {
                                $forcedKilled = Stop-ObservedServer -Observation $observation
                            }
                        }
                        $final = $observations[-1]
                        $normalShouldBeReady = ($exitKind -eq 'normal')
                        $passed = (-not $normalShouldBeReady) -or (
                            $createResult.exit_code -eq 0 -and
                            $final.has_session.exit_code -eq 0 -and
                            $final.list_panes.exit_code -eq 0 -and
                            -not [string]::IsNullOrWhiteSpace($final.list_panes.output) -and
                            $final.auth_handshake.ok
                        )
                        if (-not $passed) {
                            $failures += $label
                        }
                        $runs += [PSCustomObject][ordered]@{
                            label = $label
                            build = $buildKind
                            warm_server = $warmMode
                            shell = $shellKind
                            registry = $registryState
                            exit = $exitKind
                            home = ConvertTo-ReportPath -Path $fixtureHome
                            namespace = $namespace
                            session = $session
                            base = $base
                            started_at = $startedAt.ToString('o')
                            create = $createResult
                            prewarm = $prewarm
                            forced_server_killed = $forcedKilled
                            observations = $observations
                            expected_ready = $normalShouldBeReady
                            passed = $passed
                        }
                    } catch {
                        $failures += $label
                        $runs += [PSCustomObject][ordered]@{
                            label = $label
                            build = $buildKind
                            warm_server = $warmMode
                            shell = $shellKind
                            registry = $registryState
                            exit = $exitKind
                            home = ConvertTo-ReportPath -Path $fixtureHome
                            namespace = $namespace
                            session = $session
                            base = $base
                            error = $_.Exception.Message
                            passed = $false
                        }
                    } finally {
                        Stop-SessionServer -Exe $exe -FixtureHome $fixtureHome -Namespace $namespace -WarmEnabled $warmEnabled
                        if (-not $KeepArtifacts) {
                            Remove-Item -LiteralPath $fixtureHome -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
        }
    }
}

$result = [PSCustomObject][ordered]@{
    schema_version = 1
    captured_at = (Get-Date).ToString('o')
    repo = '<repo-root>'
    core = '<repo-root>/core'
    matrix = [ordered]@{
        warm_server = @($Warm)
        shell = @($Shell)
        build = @($Build)
        registry = @($Registry)
        exit = @($Exit)
        observation_ms = @(250, 1000, 3000)
    }
    binaries = $binaryByBuild
    summary = [ordered]@{
        total = $runs.Count
        failed = $failures.Count
        failure_labels = @($failures)
    }
    runs = $runs
}

if ($Json) {
    $result | ConvertTo-Json -Depth 20
} else {
    $result.summary | Format-List
}

if ($failures.Count -gt 0) {
    exit 1
}
