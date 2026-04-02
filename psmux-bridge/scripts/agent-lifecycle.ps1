Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AgentMonitorJobName = 'winsmux-agent-monitor'
$script:AgentLifecycleState = @{}
$script:AgentConfigCache = @{}
$script:AgentLifecycleScriptPath = $PSCommandPath
$script:WorkspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:LifecycleDir = Join-Path $script:WorkspaceRoot '.winsmux'
$script:LifecycleLog = Join-Path $script:LifecycleDir 'lifecycle.log'

function Get-AgentLifecyclePsmuxBin {
    foreach ($candidate in @('psmux', 'pmux', 'tmux')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            if ($command.Path) {
                return $command.Path
            }

            return $command.Name
        }
    }

    throw 'Could not find a psmux binary. Tried: psmux, pmux, tmux.'
}

function Initialize-AgentLifecycleLog {
    if (-not (Test-Path $script:LifecycleDir)) {
        New-Item -ItemType Directory -Path $script:LifecycleDir -Force | Out-Null
    }
}

function Write-AgentLifecycleLog {
    param(
        [Parameter(Mandatory)][string]$Event,
        [string]$PaneId,
        [string]$Label,
        [string]$State,
        [string]$Details
    )

    Initialize-AgentLifecycleLog

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add((Get-Date).ToString('o'))
    $parts.Add($Event)

    if (-not [string]::IsNullOrWhiteSpace($PaneId)) {
        $parts.Add("pane=$PaneId")
    }

    if (-not [string]::IsNullOrWhiteSpace($Label)) {
        $parts.Add("label=$Label")
    }

    if (-not [string]::IsNullOrWhiteSpace($State)) {
        $parts.Add("state=$State")
    }

    if (-not [string]::IsNullOrWhiteSpace($Details)) {
        $singleLineDetails = $Details -replace '\r?\n', ' '
        $parts.Add("details=$singleLineDetails")
    }

    Add-Content -Path $script:LifecycleLog -Value ($parts -join ' ') -Encoding UTF8
}

function Get-AgentLabelsFilePath {
    return Join-Path $env:APPDATA 'winsmux\labels.json'
}

function Get-AgentLabels {
    $labelsFile = Get-AgentLabelsFilePath
    if (-not (Test-Path $labelsFile)) {
        return @{}
    }

    $raw = Get-Content -Path $labelsFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-AgentLifecycleLog -Event 'warn' -Details "Invalid labels file: $labelsFile"
        return @{}
    }

    $labels = @{}
    foreach ($property in $parsed.PSObject.Properties) {
        $labels[$property.Name] = [string]$property.Value
    }

    return $labels
}

function Get-AgentLabelByPaneId {
    param([Parameter(Mandatory)][string]$PaneId)

    foreach ($entry in (Get-AgentLabels).GetEnumerator()) {
        if ([string]$entry.Value -eq $PaneId) {
            return [string]$entry.Key
        }
    }

    return $null
}

function Get-LabeledPaneAssignments {
    $labels = Get-AgentLabels

    return @(
        $labels.Keys |
            Sort-Object |
            ForEach-Object {
                [PSCustomObject]@{
                    Label  = [string]$_
                    PaneId = [string]$labels[$_]
                }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.PaneId) }
    )
}

function Get-PaneRuntimeMap {
    $psmux = Get-AgentLifecyclePsmuxBin
    $runtimeMap = @{}
    $raw = & $psmux list-panes -a -F '#{pane_id}|#{pane_pid}|#{pane_current_command}|#{pane_current_path}|#{pane_title}' 2>$null
    $lines = @($raw | ForEach-Object { "$_".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    foreach ($line in $lines) {
        $parts = $line -split '\|', 5
        if ($parts.Count -lt 5) {
            continue
        }

        $paneId = [string]$parts[0]
        $panePid = [string]$parts[1]
        $isRunning = $false

        if ($panePid -match '^\d+$') {
            try {
                $null = Get-Process -Id ([int]$panePid) -ErrorAction Stop
                $isRunning = $true
            } catch {
                $isRunning = $false
            }
        }

        $runtimeMap[$paneId] = [PSCustomObject]@{
            PaneId         = $paneId
            PanePid        = $panePid
            CurrentCommand = [string]$parts[2]
            CurrentPath    = [string]$parts[3]
            Title          = [string]$parts[4]
            IsRunning      = $isRunning
        }
    }

    return $runtimeMap
}

function Get-PaneRuntimeRecord {
    param([Parameter(Mandatory)][string]$PaneId)

    $runtimeMap = Get-PaneRuntimeMap
    if ($runtimeMap.ContainsKey($PaneId)) {
        return $runtimeMap[$PaneId]
    }

    return $null
}

function Get-PaneOutputLines {
    param(
        [Parameter(Mandatory)][string]$PaneId,
        [int]$Lines = 5
    )

    $psmux = Get-AgentLifecyclePsmuxBin
    $output = & $psmux capture-pane -t $PaneId -p -J -S "-$Lines" 2>$null
    return @($output | ForEach-Object { [string]$_ })
}

function Get-AgentOutputHash {
    param([string[]]$Lines)

    $text = if ($Lines) { $Lines -join "`n" } else { '' }
    return [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($text)
        )
    ) -replace '-', ''
}

function Get-LastNonEmptyAgentLine {
    param([string[]]$Lines)

    if ($null -eq $Lines) {
        return $null
    }

    for ($index = $Lines.Count - 1; $index -ge 0; $index--) {
        $line = [string]$Lines[$index]
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            return $line
        }
    }

    return $null
}

function Test-AgentReadyLine {
    param([AllowNull()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }

    $trimmed = $Line.TrimEnd()
    $normalized = $trimmed.Trim()

    if ($trimmed -match 'codex>\s*$') { return $true }
    if ($trimmed -match '(?i)tokens used') { return $true }
    if ($trimmed -match 'claude>\s*$') { return $true }
    if ($normalized -eq '$') { return $true }
    if ($trimmed -match 'gemini>\s*$') { return $true }
    if ($normalized -eq '>') { return $true }
    if ($trimmed -match '^PS .+>\s*$') { return $true }

    return $false
}

function Test-AgentReadySnapshot {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        if (Test-AgentReadyLine -Line $line) {
            return $true
        }
    }

    return $false
}

function Get-ProcessCommandArguments {
    param([AllowNull()][string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return ''
    }

    $trimmed = $CommandLine.Trim()
    if ($trimmed.StartsWith('"')) {
        $quotedMatch = [regex]::Match($trimmed, '^"[^"]+"\s*(?<args>.*)$')
        if ($quotedMatch.Success) {
            return $quotedMatch.Groups['args'].Value
        }
    }

    $plainMatch = [regex]::Match($trimmed, '^\S+\s*(?<args>.*)$')
    if ($plainMatch.Success) {
        return $plainMatch.Groups['args'].Value
    }

    return ''
}

function Get-AgentChildProcess {
    param([Parameter(Mandatory)][int]$ParentProcessId)

    try {
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ParentProcessId" -ErrorAction Stop)
    } catch {
        return $null
    }

    if (-not $children -or $children.Count -eq 0) {
        return $null
    }

    $scored = foreach ($child in $children) {
        $commandLine = [string]$child.CommandLine
        $name = [string]$child.Name
        $score = 0

        if ($commandLine -match '(?i)\bcodex\b' -or $name -match '(?i)^codex') { $score += 30 }
        if ($commandLine -match '(?i)\bclaude\b' -or $name -match '(?i)^claude') { $score += 30 }
        if ($commandLine -match '(?i)\bgemini\b') { $score += 30 }
        if ($name -match '(?i)^(pwsh|powershell|conhost|cmd)(\.exe)?$') { $score -= 20 }
        if (-not [string]::IsNullOrWhiteSpace($commandLine)) { $score += 5 }

        [PSCustomObject]@{
            Score   = $score
            Process = $child
        }
    }

    return ($scored | Sort-Object -Property @{ Expression = 'Score'; Descending = $true } | Select-Object -First 1).Process
}

function ConvertTo-AgentLaunchCommand {
    param($ProcessInfo)

    if ($null -eq $ProcessInfo) {
        return $null
    }

    $commandLine = [string]$ProcessInfo.CommandLine
    $executablePath = [string]$ProcessInfo.ExecutablePath
    $processName = [System.IO.Path]::GetFileNameWithoutExtension([string]$ProcessInfo.Name)

    if (-not [string]::IsNullOrWhiteSpace($executablePath)) {
        $escapedExecutable = $executablePath -replace "'", "''"
        $arguments = Get-ProcessCommandArguments -CommandLine $commandLine
        if ([string]::IsNullOrWhiteSpace($arguments)) {
            return "& '$escapedExecutable'"
        }

        return ("& '{0}' {1}" -f $escapedExecutable, $arguments.Trim()).Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($commandLine)) {
        return $commandLine.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($processName)) {
        return $processName
    }

    return $null
}

function Get-AgentLaunchFallback {
    param(
        [string]$Label,
        [string[]]$Lines
    )

    $labelText = if ($Label) { $Label.ToLowerInvariant() } else { '' }
    $joined = if ($Lines) { ($Lines -join "`n").ToLowerInvariant() } else { '' }

    if ($labelText -match 'codex' -or $joined -match 'codex>' -or $joined -match 'tokens used') {
        return 'codex'
    }

    if ($labelText -match 'claude' -or $joined -match 'claude>' -or $joined -match '(?m)^\$\s*$') {
        return 'claude'
    }

    if ($labelText -match 'gemini' -or $joined -match 'gemini>' -or $joined -match '(?m)^>\s*$') {
        return 'gemini'
    }

    return $null
}

function Get-AgentConfig {
    param([Parameter(Mandatory)][string]$PaneId)

    $label = Get-AgentLabelByPaneId -PaneId $PaneId
    $record = Get-PaneRuntimeRecord -PaneId $PaneId
    $knownConfig = if ($script:AgentConfigCache.ContainsKey($PaneId)) { $script:AgentConfigCache[$PaneId] } else { $null }
    $lines = @()
    $launchCommand = $null

    if ($record -and $record.IsRunning -and $record.PanePid -match '^\d+$') {
        $processInfo = Get-AgentChildProcess -ParentProcessId ([int]$record.PanePid)
        $launchCommand = ConvertTo-AgentLaunchCommand -ProcessInfo $processInfo
    }

    if ([string]::IsNullOrWhiteSpace($launchCommand)) {
        try {
            $lines = Get-PaneOutputLines -PaneId $PaneId -Lines 5
        } catch {
            $lines = @()
        }

        $launchCommand = Get-AgentLaunchFallback -Label $label -Lines $lines
    }

    $config = [PSCustomObject]@{
        PaneId           = $PaneId
        Label            = $label
        LaunchCommand    = if (-not [string]::IsNullOrWhiteSpace($launchCommand)) { $launchCommand } elseif ($knownConfig) { $knownConfig.LaunchCommand } else { $null }
        WorkingDirectory = if ($record -and -not [string]::IsNullOrWhiteSpace($record.CurrentPath)) { $record.CurrentPath } elseif ($knownConfig) { $knownConfig.WorkingDirectory } else { $null }
        CapturedAt       = (Get-Date).ToString('o')
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$config.LaunchCommand)) {
        $script:AgentConfigCache[$PaneId] = $config
    }

    return $config
}

function Reset-AgentHealthState {
    param([Parameter(Mandatory)][string]$PaneId)

    $script:AgentLifecycleState[$PaneId] = [PSCustomObject]@{
        LastHash        = $null
        StableIntervals = 0
        LastState       = 'UNKNOWN'
        UpdatedAt       = (Get-Date).ToString('o')
    }
}

function Get-AgentHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PaneId)

    $record = Get-PaneRuntimeRecord -PaneId $PaneId
    $label = Get-AgentLabelByPaneId -PaneId $PaneId

    if ($null -eq $record -or [string]::IsNullOrWhiteSpace($record.PanePid) -or -not $record.IsRunning) {
        Reset-AgentHealthState -PaneId $PaneId

        return [PSCustomObject]@{
            PaneId          = $PaneId
            Label           = $label
            State           = 'DEAD'
            StableIntervals = 0
            LastLine        = $null
            Lines           = @()
            CheckedAt       = (Get-Date).ToString('o')
        }
    }

    $firstCapture = Get-PaneOutputLines -PaneId $PaneId -Lines 5
    if (Test-AgentReadySnapshot -Lines $firstCapture) {
        $firstHash = Get-AgentOutputHash -Lines $firstCapture
        $script:AgentLifecycleState[$PaneId] = [PSCustomObject]@{
            LastHash        = $firstHash
            StableIntervals = 0
            LastState       = 'READY'
            UpdatedAt       = (Get-Date).ToString('o')
        }

        return [PSCustomObject]@{
            PaneId          = $PaneId
            Label           = $label
            State           = 'READY'
            StableIntervals = 0
            LastLine        = Get-LastNonEmptyAgentLine -Lines $firstCapture
            Lines           = $firstCapture
            CheckedAt       = (Get-Date).ToString('o')
        }
    }

    Start-Sleep -Seconds 2

    $secondCapture = Get-PaneOutputLines -PaneId $PaneId -Lines 5
    $secondHash = Get-AgentOutputHash -Lines $secondCapture

    if (Test-AgentReadySnapshot -Lines $secondCapture) {
        $script:AgentLifecycleState[$PaneId] = [PSCustomObject]@{
            LastHash        = $secondHash
            StableIntervals = 0
            LastState       = 'READY'
            UpdatedAt       = (Get-Date).ToString('o')
        }

        return [PSCustomObject]@{
            PaneId          = $PaneId
            Label           = $label
            State           = 'READY'
            StableIntervals = 0
            LastLine        = Get-LastNonEmptyAgentLine -Lines $secondCapture
            Lines           = $secondCapture
            CheckedAt       = (Get-Date).ToString('o')
        }
    }

    $firstHash = Get-AgentOutputHash -Lines $firstCapture
    if ($firstHash -ne $secondHash) {
        $script:AgentLifecycleState[$PaneId] = [PSCustomObject]@{
            LastHash        = $secondHash
            StableIntervals = 0
            LastState       = 'BUSY'
            UpdatedAt       = (Get-Date).ToString('o')
        }

        return [PSCustomObject]@{
            PaneId          = $PaneId
            Label           = $label
            State           = 'BUSY'
            StableIntervals = 0
            LastLine        = Get-LastNonEmptyAgentLine -Lines $secondCapture
            Lines           = $secondCapture
            CheckedAt       = (Get-Date).ToString('o')
        }
    }

    $stableIntervals = 1
    if ($script:AgentLifecycleState.ContainsKey($PaneId)) {
        $previousState = $script:AgentLifecycleState[$PaneId]
        if ($previousState -and $previousState.LastHash -eq $secondHash) {
            $stableIntervals = [int]$previousState.StableIntervals + 1
        }
    }

    $state = if ($stableIntervals -ge 3) { 'HUNG' } else { 'BUSY' }
    $script:AgentLifecycleState[$PaneId] = [PSCustomObject]@{
        LastHash        = $secondHash
        StableIntervals = $stableIntervals
        LastState       = $state
        UpdatedAt       = (Get-Date).ToString('o')
    }

    return [PSCustomObject]@{
        PaneId          = $PaneId
        Label           = $label
        State           = $state
        StableIntervals = $stableIntervals
        LastLine        = Get-LastNonEmptyAgentLine -Lines $secondCapture
        Lines           = $secondCapture
        CheckedAt       = (Get-Date).ToString('o')
    }
}

function Restart-Agent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PaneId,
        [Parameter(Mandatory)]$AgentConfig
    )

    $launchCommand = [string]$AgentConfig.LaunchCommand
    if ([string]::IsNullOrWhiteSpace($launchCommand)) {
        throw "Cannot restart pane $PaneId because LaunchCommand is empty."
    }

    $psmux = Get-AgentLifecyclePsmuxBin
    $label = if ($AgentConfig.PSObject.Properties.Match('Label').Count -gt 0) { [string]$AgentConfig.Label } else { (Get-AgentLabelByPaneId -PaneId $PaneId) }

    try {
        & $psmux send-keys -t $PaneId C-c | Out-Null
    } catch {
    }

    Start-Sleep -Seconds 2

    $record = Get-PaneRuntimeRecord -PaneId $PaneId
    if ($null -eq $record -or [string]::IsNullOrWhiteSpace($record.PanePid) -or -not $record.IsRunning) {
        try {
            & $psmux respawn-pane -k -t $PaneId | Out-Null
            Start-Sleep -Seconds 1
        } catch {
            Write-AgentLifecycleLog -Event 'restart-failed' -PaneId $PaneId -Label $label -Details $_.Exception.Message
            throw
        }
    }

    $workingDirectory = if ($AgentConfig.PSObject.Properties.Match('WorkingDirectory').Count -gt 0) { [string]$AgentConfig.WorkingDirectory } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) {
        $escapedWorkingDirectory = $workingDirectory -replace "'", "''"
        & $psmux send-keys -t $PaneId -l -- "Set-Location -LiteralPath '$escapedWorkingDirectory'" | Out-Null
        & $psmux send-keys -t $PaneId Enter | Out-Null
        Start-Sleep -Milliseconds 300
    }

    & $psmux send-keys -t $PaneId -l -- $launchCommand | Out-Null
    & $psmux send-keys -t $PaneId Enter | Out-Null

    Reset-AgentHealthState -PaneId $PaneId
    $script:AgentConfigCache[$PaneId] = $AgentConfig

    Write-AgentLifecycleLog -Event 'restart' -PaneId $PaneId -Label $label -State 'RESTARTED' -Details $launchCommand

    return [PSCustomObject]@{
        PaneId        = $PaneId
        Label         = $label
        LaunchCommand = $launchCommand
        RestartedAt   = (Get-Date).ToString('o')
    }
}

function Invoke-AgentMonitorPass {
    param([Parameter(Mandatory)][int]$IntervalSeconds)

    $assignments = Get-LabeledPaneAssignments
    foreach ($assignment in $assignments) {
        $paneId = [string]$assignment.PaneId
        $label = [string]$assignment.Label

        try {
            $agentConfig = Get-AgentConfig -PaneId $paneId
            $health = Get-AgentHealth -PaneId $paneId

            if ($health.State -in @('HUNG', 'DEAD')) {
                if ($null -eq $agentConfig -or [string]::IsNullOrWhiteSpace([string]$agentConfig.LaunchCommand)) {
                    Write-AgentLifecycleLog -Event 'restart-skipped' -PaneId $paneId -Label $label -State $health.State -Details 'LaunchCommand could not be determined.'
                    continue
                }

                Restart-Agent -PaneId $paneId -AgentConfig $agentConfig | Out-Null
            }
        } catch {
            Write-AgentLifecycleLog -Event 'monitor-error' -PaneId $paneId -Label $label -Details $_.Exception.Message
        }
    }

    Start-Sleep -Seconds $IntervalSeconds
}

function Invoke-AgentMonitorLoop {
    param([Parameter(Mandatory)][int]$IntervalSeconds)

    while ($true) {
        try {
            Invoke-AgentMonitorPass -IntervalSeconds $IntervalSeconds
        } catch {
            Write-AgentLifecycleLog -Event 'monitor-loop-error' -Details $_.Exception.Message
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
}

function Start-AgentMonitor {
    [CmdletBinding()]
    param([int]$IntervalSeconds = 30)

    if ($IntervalSeconds -lt 1) {
        throw 'IntervalSeconds must be 1 or greater.'
    }

    $existingJob = Get-Job -Name $script:AgentMonitorJobName -ErrorAction SilentlyContinue
    if ($existingJob) {
        if ($existingJob.State -eq 'Running') {
            return $existingJob
        }

        Remove-Job -Job $existingJob -Force -ErrorAction SilentlyContinue
    }

    Initialize-AgentLifecycleLog
    Write-AgentLifecycleLog -Event 'monitor-start' -Details "interval=${IntervalSeconds}s"

    return Start-Job -Name $script:AgentMonitorJobName -ArgumentList @(
        $script:AgentLifecycleScriptPath,
        $IntervalSeconds,
        $env:APPDATA,
        $env:PATH,
        $env:USERPROFILE
    ) -ScriptBlock {
        param(
            [string]$ScriptPath,
            [int]$JobIntervalSeconds,
            [string]$AppDataPath,
            [string]$PathValue,
            [string]$UserProfilePath
        )

        if (-not [string]::IsNullOrWhiteSpace($AppDataPath)) {
            $env:APPDATA = $AppDataPath
        }

        if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
            $env:PATH = $PathValue
        }

        if (-not [string]::IsNullOrWhiteSpace($UserProfilePath)) {
            $env:USERPROFILE = $UserProfilePath
        }

        . $ScriptPath
        Invoke-AgentMonitorLoop -IntervalSeconds $JobIntervalSeconds
    }
}

function Stop-AgentMonitor {
    [CmdletBinding()]
    param()

    $job = Get-Job -Name $script:AgentMonitorJobName -ErrorAction SilentlyContinue
    if (-not $job) {
        return $null
    }

    if ($job.State -eq 'Running') {
        Stop-Job -Job $job | Out-Null
    }

    $finalState = $job.State
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    Write-AgentLifecycleLog -Event 'monitor-stop' -Details "state=$finalState"

    return $finalState
}
