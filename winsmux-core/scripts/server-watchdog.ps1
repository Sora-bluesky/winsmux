[CmdletBinding()]
param(
    [string]$ManifestPath = '',
    [string]$SessionName = 'winsmux-orchestra',
    [string]$StartupToken = '',
    [ValidateRange(5, 10)][int]$PollInterval = 5,
    [int]$MaxRestartAttempts = 3,
    [int]$RestartWindowMinutes = 10
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'orchestra-preflight.ps1')
. (Join-Path $scriptDir 'manifest.ps1')
. (Join-Path $scriptDir 'settings.ps1')

function Write-ServerWatchdogTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Content = '',
        [switch]$Append
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $escapedPath = $Path -replace '"', '""'
    if ([string]::IsNullOrEmpty($Content)) {
        if ($Append) {
            return
        }

        $writeCommand = 'type nul > "{0}"' -f $escapedPath
        cmd /d /c $writeCommand | Out-Null
    } else {
        $redirect = if ($Append) { '>>' } else { '>' }
        $writeCommand = 'more {0} "{1}"' -f $redirect, $escapedPath
        $Content | cmd /d /c $writeCommand | Out-Null
    }

    if ($LASTEXITCODE -ne 0) {
        throw "cmd.exe failed to write $Path"
    }
}

function New-ServerWatchdogState {
    param(
        [int]$MaxRestartAttempts = 3,
        [int]$RestartWindowMinutes = 10
    )

    return [ordered]@{
        RestartAttempts      = @()
        Degraded             = $false
        DegradedLogged       = $false
        LastRestartAt        = ''
        LastRestartSucceeded = $false
        MaxRestartAttempts   = $MaxRestartAttempts
        RestartWindowMinutes = $RestartWindowMinutes
    }
}

function Get-ServerWatchdogProjectDir {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    return Split-Path (Split-Path $ManifestPath -Parent) -Parent
}

function Get-ServerWatchdogEventsPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path (Join-Path $ProjectDir '.winsmux') 'events.jsonl'
}

function Write-ServerWatchdogEvent {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$ExitReason,
        [AllowNull()]$Data = $null
    )

    try {
        $eventsPath = Get-ServerWatchdogEventsPath -ProjectDir $ProjectDir
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $eventsPath)) | Out-Null

        $record = [ordered]@{
            timestamp   = (Get-Date).ToString('o')
            session     = $SessionName
            event       = $Event
            message     = $Message
            label       = ''
            pane_id     = ''
            role        = ''
            status      = $Status
            exit_reason = $ExitReason
            data        = if ($null -eq $Data) { [ordered]@{} } else { $Data }
        }

        $line = ($record | ConvertTo-Json -Compress -Depth 10)
        Write-ServerWatchdogTextFile -Path $eventsPath -Content $line -Append
        return $record
    } catch {
        return $null
    }
}

function Invoke-ServerWatchdogWinsmux {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $winsmuxBin = Get-WinsmuxBin
    if (-not $winsmuxBin) {
        throw (Get-WinsmuxOperatorNotFoundMessage)
    }

    $output = & $winsmuxBin @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $message = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = 'unknown winsmux error'
        }

        throw "winsmux $($Arguments -join ' ') failed: $message"
    }

    return [ordered]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Test-ServerWatchdogSessionAlive {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    $result = Invoke-ServerWatchdogWinsmux -Arguments @('has-session', '-t', $SessionName) -AllowFailure
    return ($result.ExitCode -eq 0)
}

function Invoke-ServerWatchdogRestart {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    return (Invoke-ServerWatchdogWinsmux -Arguments @('new-session', '-d', '-s', $SessionName) -AllowFailure)
}

function Get-ServerWatchdogExpectedPaneCount {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return -1
    }

    try {
        $projectDir = Get-ServerWatchdogProjectDir -ManifestPath $ManifestPath
        $manifest = Get-WinsmuxManifest -ProjectDir $projectDir
        if ($null -eq $manifest -or $null -eq $manifest.panes) {
            return -1
        }

        if ($manifest.panes -is [System.Collections.IDictionary]) {
            return @($manifest.panes.Keys).Count
        }

        return @($manifest.panes).Count
    } catch {
        return -1
    }
}

function Get-ServerWatchdogHealthStatus {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    try {
        $expectedPaneCount = Get-ServerWatchdogExpectedPaneCount -ManifestPath $ManifestPath
        if ($expectedPaneCount -lt 1) {
            return 'Unhealthy'
        }
        return [string](Test-OrchestraServerHealth -SessionName $SessionName -WinsmuxBin (Get-WinsmuxBin) -ExpectedPaneCount $expectedPaneCount)
    } catch {
        return 'Unhealthy'
    }
}

function Get-ServerWatchdogActiveAttempts {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][datetime]$Now
    )

    $windowStart = $Now.AddMinutes(-1 * [int]$State.RestartWindowMinutes)
    $activeAttempts = [System.Collections.Generic.List[string]]::new()

    foreach ($attempt in @($State.RestartAttempts)) {
        $attemptText = [string]$attempt
        if ([string]::IsNullOrWhiteSpace($attemptText)) {
            continue
        }

        try {
            $attemptAt = [System.DateTimeOffset]::Parse($attemptText).DateTime
            if ($attemptAt -ge $windowStart) {
                $activeAttempts.Add($attemptText) | Out-Null
            }
        } catch {
        }
    }

    $State['RestartAttempts'] = @($activeAttempts)
    return @($activeAttempts)
}

function Invoke-ServerWatchdogCycle {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [AllowNull()]$State = $null
    )

    if ($null -eq $State) {
        $State = New-ServerWatchdogState
    }

    $projectDir = Get-ServerWatchdogProjectDir -ManifestPath $ManifestPath
    $now = Get-Date
    $activeAttempts = @(Get-ServerWatchdogActiveAttempts -State $State -Now $now)

    $result = [ordered]@{
        SessionName        = $SessionName
        ProjectDir         = $projectDir
        SessionAlive       = $true
        RestartAttempted   = $false
        RestartSucceeded   = $false
        Degraded           = [bool]$State.Degraded
        AttemptCount       = $activeAttempts.Count
        MaxRestartAttempts = [int]$State.MaxRestartAttempts
        RestartWindowMinutes = [int]$State.RestartWindowMinutes
        Event              = ''
        Message            = ''
        State              = $State
    }

    if ($State.Degraded) {
        $result['SessionAlive'] = (Test-ServerWatchdogSessionAlive -SessionName $SessionName)
        $result['Degraded'] = $true
        $result['Message'] = 'Server watchdog is in degraded state.'
        return $result
    }

    $healthStatus = Get-ServerWatchdogHealthStatus -SessionName $SessionName -ManifestPath $ManifestPath
    $result['HealthStatus'] = $healthStatus

    if ($healthStatus -eq 'Healthy') {
        return $result
    }

    $result['SessionAlive'] = $false
    $exitReason = if ($healthStatus -eq 'Unhealthy') { 'healthcheck_failed' } else { 'session_missing' }

    if ($activeAttempts.Count -ge [int]$State.MaxRestartAttempts) {
        $State['Degraded'] = $true
        $result['Degraded'] = $true
        $result['Event'] = 'server.restart_failed'
        $result['Message'] = "Server session $SessionName entered degraded state after repeated restart failures."

        if (-not [bool]$State.DegradedLogged) {
            Write-ServerWatchdogEvent -ProjectDir $projectDir -SessionName $SessionName `
                -Event 'server.restart_failed' `
                -Message $result.Message `
                -Status 'degraded' `
                -ExitReason 'crash_loop_protection' `
                -Data ([ordered]@{
                    attempt_count          = $activeAttempts.Count
                    max_restart_attempts   = [int]$State.MaxRestartAttempts
                    restart_window_minutes = [int]$State.RestartWindowMinutes
                    health_status          = $healthStatus
                }) | Out-Null
            $State['DegradedLogged'] = $true
        }

        return $result
    }

    $attemptAt = $now.ToString('o')
    $State['RestartAttempts'] = @($activeAttempts + @($attemptAt))
    $State['LastRestartAt'] = $attemptAt
    $result['AttemptCount'] = @($State.RestartAttempts).Count
    $result['RestartAttempted'] = $true

    $restartResult = Invoke-ServerWatchdogRestart -SessionName $SessionName
    if ($restartResult.ExitCode -eq 0) {
        $State['LastRestartSucceeded'] = $true
        $result['RestartSucceeded'] = $true
        $result['Event'] = 'server.restarted'
        $result['Message'] = "Restarted server session $SessionName."

        Write-ServerWatchdogEvent -ProjectDir $projectDir -SessionName $SessionName `
            -Event 'server.restarted' `
            -Message $result.Message `
            -Status 'restarted' `
            -ExitReason $exitReason `
            -Data ([ordered]@{
                attempt_count          = $result.AttemptCount
                max_restart_attempts   = [int]$State.MaxRestartAttempts
                restart_window_minutes = [int]$State.RestartWindowMinutes
                health_status          = $healthStatus
            }) | Out-Null

        return $result
    }

    $State['LastRestartSucceeded'] = $false
    $result['Event'] = 'server.restart_failed'
    $result['Message'] = "Failed to restart server session $SessionName."

    $restartOutput = ($restartResult.Output | Out-String).Trim()
    Write-ServerWatchdogEvent -ProjectDir $projectDir -SessionName $SessionName `
        -Event 'server.restart_failed' `
        -Message $result.Message `
        -Status 'failed' `
        -ExitReason 'restart_failed' `
        -Data ([ordered]@{
            attempt_count          = $result.AttemptCount
            max_restart_attempts   = [int]$State.MaxRestartAttempts
            restart_window_minutes = [int]$State.RestartWindowMinutes
            restart_output         = $restartOutput
            health_status          = $healthStatus
        }) | Out-Null

    return $result
}

function Start-ServerWatchdogLoop {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [ValidateRange(5, 10)][int]$PollInterval = 5,
        [int]$MaxRestartAttempts = 3,
        [int]$RestartWindowMinutes = 10
    )

    $state = New-ServerWatchdogState -MaxRestartAttempts $MaxRestartAttempts -RestartWindowMinutes $RestartWindowMinutes
    while ($true) {
        try {
            $result = Invoke-ServerWatchdogCycle -ManifestPath $ManifestPath -SessionName $SessionName -State $state
            Write-Output ($result | ConvertTo-Json -Depth 8 -Compress)
        } catch {
            Write-Warning ("Server watchdog cycle failed for session {0}: {1}" -f $SessionName, $_.Exception.Message)
        }

        Start-Sleep -Seconds $PollInterval
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        throw 'ManifestPath is required.'
    }

    Start-ServerWatchdogLoop -ManifestPath $ManifestPath -SessionName $SessionName -PollInterval $PollInterval -MaxRestartAttempts $MaxRestartAttempts -RestartWindowMinutes $RestartWindowMinutes
}
