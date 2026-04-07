[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [int]$Interval = 20
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Get-Command Get-WinsmuxBin -ErrorAction SilentlyContinue)) {
    function Get-WinsmuxBin {
        foreach ($candidate in @('winsmux', 'pmux', 'tmux')) {
            $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $command) {
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$command.Path)) {
                return [string]$command.Path
            }

            return [string]$command.Name
        }

        return $null
    }
}

function Get-CommanderPollValue {
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

function ConvertFrom-CommanderPollYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = $Value.ToString().Trim()
    if ($text.Length -ge 2) {
        if (($text.StartsWith('"') -and $text.EndsWith('"')) -or ($text.StartsWith("'") -and $text.EndsWith("'"))) {
            $text = $text.Substring(1, $text.Length - 2)
        }
    }

    if ($text -eq 'null') {
        return $null
    }

    return $text
}

function ConvertFrom-CommanderPollManifestContent {
    param([Parameter(Mandatory = $true)][string]$Content)

    $manifest = [ordered]@{
        Session = [ordered]@{}
        Panes   = [ordered]@{}
    }

    $section = ''
    $currentPane = $null

    function Save-CommanderPollPane {
        param([AllowNull()]$Pane)

        if ($null -eq $Pane) {
            return
        }

        $label = [string](Get-CommanderPollValue -InputObject $Pane -Name 'label' -Default '')
        if ([string]::IsNullOrWhiteSpace($label)) {
            return
        }

        $savedPane = [ordered]@{}
        foreach ($entry in $Pane.GetEnumerator()) {
            $savedPane[[string]$entry.Key] = $entry.Value
        }

        $manifest['Panes'][$label] = $savedPane
    }

    foreach ($rawLine in ($Content -split "\r?\n")) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
            continue
        }

        if ($line -match '^(session|panes):\s*$') {
            if ($section -eq 'panes') {
                Save-CommanderPollPane -Pane $currentPane
                $currentPane = $null
            }

            $section = $Matches[1]
            continue
        }

        if ($section -eq 'session' -and $line -match '^\s{2}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
            $manifest['Session'][$Matches[1]] = ConvertFrom-CommanderPollYamlScalar $Matches[2]
            continue
        }

        if ($section -ne 'panes') {
            continue
        }

        if ($line -match '^\s{2}-\s+label:\s*(.*?)\s*$') {
            Save-CommanderPollPane -Pane $currentPane
            $currentPane = [ordered]@{
                label = ConvertFrom-CommanderPollYamlScalar $Matches[1]
            }
            continue
        }

        if ($line -match '^\s{2}(.+?):\s*$') {
            Save-CommanderPollPane -Pane $currentPane
            $currentPane = [ordered]@{
                label = ConvertFrom-CommanderPollYamlScalar $Matches[1]
            }
            continue
        }

        if ($null -ne $currentPane -and $line -match '^\s{4}([A-Za-z0-9_.-]+):\s*(.*?)\s*$') {
            $currentPane[$Matches[1]] = ConvertFrom-CommanderPollYamlScalar $Matches[2]
        }
    }

    if ($section -eq 'panes') {
        Save-CommanderPollPane -Pane $currentPane
    }

    return $manifest
}

function Read-CommanderPollManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Manifest not found: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Manifest is empty: $Path"
    }

    return ConvertFrom-CommanderPollManifestContent -Content $content
}

function Get-CommanderPollProjectDir {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $projectDir = [string](Get-CommanderPollValue -InputObject $Manifest['Session'] -Name 'project_dir' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($projectDir)) {
        return $projectDir
    }

    return Split-Path (Split-Path $ManifestPath -Parent) -Parent
}

function Get-CommanderPollSessionName {
    param([Parameter(Mandatory = $true)]$Manifest)

    $sessionName = [string](Get-CommanderPollValue -InputObject $Manifest['Session'] -Name 'name' -Default '')
    if ([string]::IsNullOrWhiteSpace($sessionName)) {
        return 'winsmux-orchestra'
    }

    return $sessionName
}

function Get-CommanderPollEventsPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path (Join-Path $ProjectDir '.winsmux') 'events.jsonl'
}

function Get-CommanderPollLogPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $logDir = Join-Path $ProjectDir '.winsmux\logs'
    [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
    return Join-Path $logDir 'commander-poll.jsonl'
}

function Write-CommanderPollLog {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$PaneId = '',
        [AllowNull()]$Data = $null,
        [ValidateSet('debug', 'info', 'warn', 'error')][string]$Level = 'info'
    )

    $record = [ordered]@{
        timestamp = [System.DateTimeOffset]::Now.ToString('o')
        session   = $SessionName
        event     = $EventName
        level     = $Level
        pane_id   = $PaneId
        message   = $Message
        data      = if ($null -eq $Data) { [ordered]@{} } else { $Data }
    }

    $line = ($record | ConvertTo-Json -Compress -Depth 10) + [System.Environment]::NewLine
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText((Get-CommanderPollLogPath -ProjectDir $ProjectDir), $line, $encoding)
}

function Get-CommanderPollPaneContext {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)]$EventRecord
    )

    $eventPaneId = [string](Get-CommanderPollValue -InputObject $EventRecord -Name 'pane_id' -Default '')
    $eventLabel = [string](Get-CommanderPollValue -InputObject $EventRecord -Name 'label' -Default '')
    $eventRole = [string](Get-CommanderPollValue -InputObject $EventRecord -Name 'role' -Default '')
    $projectDir = Get-CommanderPollProjectDir -Manifest $Manifest -ManifestPath $ManifestPath

    $matchedLabel = $eventLabel
    $matchedPane = $null

    foreach ($label in $Manifest['Panes'].Keys) {
        $pane = $Manifest['Panes'][$label]
        $paneId = [string](Get-CommanderPollValue -InputObject $pane -Name 'pane_id' -Default '')

        if (-not [string]::IsNullOrWhiteSpace($eventPaneId) -and $paneId -eq $eventPaneId) {
            $matchedLabel = $label
            $matchedPane = $pane
            break
        }

        if (-not [string]::IsNullOrWhiteSpace($eventLabel) -and $label -eq $eventLabel) {
            $matchedLabel = $label
            $matchedPane = $pane
            break
        }
    }

    $role = $eventRole
    if ($null -ne $matchedPane) {
        $paneRole = [string](Get-CommanderPollValue -InputObject $matchedPane -Name 'role' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($paneRole)) {
            $role = $paneRole
        }
    }

    $worktreePath = ''
    if ($null -ne $matchedPane) {
        foreach ($key in @('builder_worktree_path', 'launch_dir')) {
            $candidate = [string](Get-CommanderPollValue -InputObject $matchedPane -Name $key -Default '')
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $worktreePath = $candidate
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($worktreePath)) {
        $worktreePath = $projectDir
    }

    $resolvedPaneId = $eventPaneId
    if ([string]::IsNullOrWhiteSpace($resolvedPaneId) -and $null -ne $matchedPane) {
        $resolvedPaneId = [string](Get-CommanderPollValue -InputObject $matchedPane -Name 'pane_id' -Default '')
    }

    return [ordered]@{
        project_dir   = $projectDir
        session_name  = Get-CommanderPollSessionName -Manifest $Manifest
        pane_id       = $resolvedPaneId
        label         = $matchedLabel
        role          = $role
        worktree_path = $worktreePath
    }
}

function Invoke-CommanderPollWinsmux {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $winsmuxBin = Get-WinsmuxBin
    if (-not $winsmuxBin) {
        throw 'Could not find a winsmux binary. Tried: winsmux, pmux, tmux.'
    }

    $output = & $winsmuxBin @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = 'unknown winsmux error'
        }

        throw "winsmux $($Arguments -join ' ') failed: $message"
    }

    return $output
}

function Approve-CommanderPollPane {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    Invoke-CommanderPollWinsmux -Arguments @('send-keys', '-t', $PaneId, 'Enter') | Out-Null
}

function Get-CommanderPollGitOutput {
    param(
        [Parameter(Mandatory = $true)][string]$WorktreePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if (-not (Test-Path -LiteralPath $WorktreePath -PathType Container)) {
        return @()
    }

    $output = & git -C $WorktreePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    return @($output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-CommanderPollDiffData {
    param([Parameter(Mandatory = $true)][string]$WorktreePath)

    $statusLines = Get-CommanderPollGitOutput -WorktreePath $WorktreePath -Arguments @('status', '--short', '--untracked-files=all')
    $unstagedDiff = Get-CommanderPollGitOutput -WorktreePath $WorktreePath -Arguments @('diff', '--stat', '--no-ext-diff')
    $stagedDiff = Get-CommanderPollGitOutput -WorktreePath $WorktreePath -Arguments @('diff', '--cached', '--stat', '--no-ext-diff')

    $changedFiles = @()
    foreach ($statusLine in $statusLines) {
        $trimmed = $statusLine.Trim()
        if ($trimmed -match '^[A-Z\?\! ]{1,2}\s+(.+)$') {
            $changedFiles += @($Matches[1].Trim())
            continue
        }

        $changedFiles += @($trimmed)
    }

    return [ordered]@{
        worktree_path        = $WorktreePath
        changed_file_count   = $changedFiles.Count
        changed_files        = @($changedFiles)
        status_lines         = @($statusLines)
        unstaged_diff_stat   = @($unstagedDiff)
        staged_diff_stat     = @($stagedDiff)
    }
}

function Test-CommanderPollApprovalEvent {
    param([Parameter(Mandatory = $true)]$EventRecord)

    $eventName = [string](Get-CommanderPollValue -InputObject $EventRecord -Name 'event' -Default '')
    if ($eventName -eq 'approval_waiting') {
        return $true
    }

    $status = [string](Get-CommanderPollValue -InputObject $EventRecord -Name 'status' -Default '')
    if ($status -eq 'approval_waiting') {
        return $true
    }

    $data = Get-CommanderPollValue -InputObject $EventRecord -Name 'data' -Default $null
    $dataStatus = [string](Get-CommanderPollValue -InputObject $data -Name 'status' -Default '')
    return ($eventName -eq 'monitor.status' -and $dataStatus -eq 'approval_waiting')
}

function New-CommanderPollCycleSummary {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$EventsPath
    )

    return [ordered]@{
        timestamp   = [System.DateTimeOffset]::Now.ToString('o')
        manifest    = $ManifestPath
        events      = $EventsPath
        new_events  = 0
        completions = 0
        approvals   = 0
        errors      = 0
        messages    = @()
    }
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Manifest not found: $ManifestPath"
}

$initialManifest = Read-CommanderPollManifest -Path $ManifestPath
$initialProjectDir = Get-CommanderPollProjectDir -Manifest $initialManifest -ManifestPath $ManifestPath
$eventsPath = Get-CommanderPollEventsPath -ProjectDir $initialProjectDir
$processedLineCount = 0

if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
    $processedLineCount = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8).Count
}

while ($true) {
    $manifest = Read-CommanderPollManifest -Path $ManifestPath
    $projectDir = Get-CommanderPollProjectDir -Manifest $manifest -ManifestPath $ManifestPath
    $sessionName = Get-CommanderPollSessionName -Manifest $manifest
    $eventsPath = Get-CommanderPollEventsPath -ProjectDir $projectDir
    $summary = New-CommanderPollCycleSummary -ManifestPath $ManifestPath -EventsPath $eventsPath

    try {
        $lines = @()
        if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
            $lines = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8)
        }

        if ($lines.Count -lt $processedLineCount) {
            $processedLineCount = 0
        }

        for ($index = $processedLineCount; $index -lt $lines.Count; $index++) {
            $line = [string]$lines[$index]
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $eventRecord = $null
            try {
                $eventRecord = $line | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            } catch {
                $summary['errors'] = [int]$summary['errors'] + 1
                $summary['messages'] += @("Failed to parse event line $($index + 1): $($_.Exception.Message)")
                continue
            }

            $summary['new_events'] = [int]$summary['new_events'] + 1
            $eventName = [string](Get-CommanderPollValue -InputObject $eventRecord -Name 'event' -Default '')

            if ($eventName -eq 'pane.exec_completed') {
                $paneContext = Get-CommanderPollPaneContext -Manifest $manifest -ManifestPath $ManifestPath -EventRecord $eventRecord
                $diffData = Get-CommanderPollDiffData -WorktreePath ([string]$paneContext['worktree_path'])
                $message = "Completion detected for $($paneContext['label']) ($($paneContext['pane_id'])) with $($diffData['changed_file_count']) changed file(s)"

                Write-CommanderPollLog `
                    -ProjectDir $projectDir `
                    -SessionName $sessionName `
                    -EventName 'commander.poll.exec_completed' `
                    -Message $message `
                    -PaneId ([string]$paneContext['pane_id']) `
                    -Data ([ordered]@{
                        label      = $paneContext['label']
                        role       = $paneContext['role']
                        diff       = $diffData
                        source_id  = Get-CommanderPollValue -InputObject $eventRecord -Name 'id' -Default ''
                    })

                $summary['completions'] = [int]$summary['completions'] + 1
                $summary['messages'] += @($message)
                continue
            }

            if (Test-CommanderPollApprovalEvent -EventRecord $eventRecord) {
                $paneContext = Get-CommanderPollPaneContext -Manifest $manifest -ManifestPath $ManifestPath -EventRecord $eventRecord
                $paneId = [string]$paneContext['pane_id']

                if ([string]::IsNullOrWhiteSpace($paneId)) {
                    $summary['errors'] = [int]$summary['errors'] + 1
                    $summary['messages'] += @('approval_waiting event is missing pane_id')
                    continue
                }

                Approve-CommanderPollPane -PaneId $paneId
                $message = "Approved pane $($paneContext['label']) ($paneId) with Enter"

                Write-CommanderPollLog `
                    -ProjectDir $projectDir `
                    -SessionName $sessionName `
                    -EventName 'commander.poll.auto_approved' `
                    -Message $message `
                    -PaneId $paneId `
                    -Data ([ordered]@{
                        label     = $paneContext['label']
                        role      = $paneContext['role']
                        source_id = Get-CommanderPollValue -InputObject $eventRecord -Name 'id' -Default ''
                    })

                $summary['approvals'] = [int]$summary['approvals'] + 1
                $summary['messages'] += @($message)
            }
        }

        $processedLineCount = $lines.Count
    } catch {
        $summary['errors'] = [int]$summary['errors'] + 1
        $errorMessage = "commander-poll cycle failed: $($_.Exception.Message)"
        $summary['messages'] += @($errorMessage)

        Write-CommanderPollLog `
            -ProjectDir $projectDir `
            -SessionName $sessionName `
            -EventName 'commander.poll.error' `
            -Message $errorMessage `
            -Level 'error'
    }

    Write-Output ($summary | ConvertTo-Json -Compress -Depth 10)
    Start-Sleep -Seconds $Interval
}
