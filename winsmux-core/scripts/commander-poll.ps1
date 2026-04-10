[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [int]$Interval = 20
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'manifest.ps1')
. (Join-Path $PSScriptRoot 'clm-safe-io.ps1')
. (Join-Path $PSScriptRoot 'pane-control.ps1')

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

    $parsed = ConvertFrom-ManifestYaml -Content $Content
    return [ordered]@{
        Session = $parsed.session
        Panes   = $parsed.panes
    }
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

    $line = ($record | ConvertTo-Json -Compress -Depth 10)
    Write-WinsmuxTextFile -Path (Get-CommanderPollLogPath -ProjectDir $ProjectDir) -Content $line -Append
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
        task_id       = if ($null -ne $matchedPane) { [string](Get-CommanderPollValue -InputObject $matchedPane -Name 'task_id' -Default '') } else { '' }
        task          = if ($null -ne $matchedPane) { [string](Get-CommanderPollValue -InputObject $matchedPane -Name 'task' -Default '') } else { '' }
        task_state    = if ($null -ne $matchedPane) { [string](Get-CommanderPollValue -InputObject $matchedPane -Name 'task_state' -Default '') } else { '' }
        task_owner    = if ($null -ne $matchedPane) { [string](Get-CommanderPollValue -InputObject $matchedPane -Name 'task_owner' -Default '') } else { '' }
        review_state  = if ($null -ne $matchedPane) { [string](Get-CommanderPollValue -InputObject $matchedPane -Name 'review_state' -Default '') } else { '' }
        branch        = if ($null -ne $matchedPane) { [string](Get-CommanderPollValue -InputObject $matchedPane -Name 'branch' -Default '') } else { '' }
        head_sha      = if ($null -ne $matchedPane) { [string](Get-CommanderPollValue -InputObject $matchedPane -Name 'head_sha' -Default '') } else { '' }
    }
}

function Update-CommanderPollPaneState {
    param(
        [Parameter(Mandatory = $true)]$PaneContext,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Properties
    )

    if ([string]::IsNullOrWhiteSpace([string]$PaneContext['pane_id'])) {
        return
    }

    try {
        $entry = @(Get-PaneControlManifestEntries -ProjectDir ([string]$PaneContext['project_dir']) | Where-Object { $_.PaneId -eq [string]$PaneContext['pane_id'] } | Select-Object -First 1)[0]
        if ($null -eq $entry) {
            return
        }

        Set-PaneControlManifestPaneProperties -ManifestPath ([string]$entry.ManifestPath) -PaneId ([string]$entry.PaneId) -Properties $Properties
    } catch {
        # Pane state enrichment is best-effort.
    }
}

function New-CommanderPollStateData {
    param(
        [Parameter(Mandatory = $true)]$PaneContext,
        [AllowNull()]$Data = $null
    )

    $stateData = [ordered]@{
        task_id      = [string]$PaneContext['task_id']
        task         = [string]$PaneContext['task']
        task_state   = [string]$PaneContext['task_state']
        task_owner   = [string]$PaneContext['task_owner']
        review_state = [string]$PaneContext['review_state']
        branch       = [string]$PaneContext['branch']
        head_sha     = [string]$PaneContext['head_sha']
    }

    if ($null -ne $Data) {
        $dataMap = ConvertTo-ManifestPropertyMap -Value $Data
        foreach ($key in $dataMap.Keys) {
            $stateData[$key] = $dataMap[$key]
        }
    }

    return $stateData
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
    $branchLines = Get-CommanderPollGitOutput -WorktreePath $WorktreePath -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    $headShaLines = Get-CommanderPollGitOutput -WorktreePath $WorktreePath -Arguments @('rev-parse', 'HEAD')

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
        branch               = @($branchLines | Select-Object -First 1)[0]
        head_sha             = @($headShaLines | Select-Object -First 1)[0]
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
        timestamp      = [System.DateTimeOffset]::Now.ToString('o')
        manifest       = $ManifestPath
        events         = $EventsPath
        new_events     = 0
        mailbox_events = 0
        completions    = 0
        approvals      = 0
        dispatches     = 0
        errors         = 0
        messages       = @()
    }
}

function Get-CommanderPollMailboxChannel {
    param([string]$SessionName = 'winsmux-orchestra')

    $resolvedSessionName = if ([string]::IsNullOrWhiteSpace($SessionName)) {
        'winsmux-orchestra'
    } else {
        $SessionName.Trim()
    }

    $safeSessionName = [regex]::Replace($resolvedSessionName, '[^A-Za-z0-9_-]', '-')
    return "$safeSessionName-commander"
}

function Receive-CommanderPollMailboxMessages {
    param(
        [string]$SessionName = 'winsmux-orchestra',
        [int]$TimeoutMilliseconds = 25,
        [int]$MaxMessages = 20
    )

    $messages = [System.Collections.Generic.List[object]]::new()
    $pipeName = "winsmux-mailbox-$(Get-CommanderPollMailboxChannel -SessionName $SessionName)"

    for ($messageIndex = 0; $messageIndex -lt $MaxMessages; $messageIndex++) {
        $server = $null
        try {
            $server = [System.IO.Pipes.NamedPipeServerStream]::new(
                $pipeName,
                [System.IO.Pipes.PipeDirection]::In,
                1,
                [System.IO.Pipes.PipeTransmissionMode]::Byte,
                [System.IO.Pipes.PipeOptions]::Asynchronous
            )
            $waitTask = $server.WaitForConnectionAsync()
            if (-not $waitTask.Wait($TimeoutMilliseconds)) {
                break
            }

            $reader = [System.IO.StreamReader]::new($server, [System.Text.Encoding]::UTF8)
            try {
                $payload = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }

            if ([string]::IsNullOrWhiteSpace($payload)) {
                continue
            }

            $mailboxMessage = $null
            try {
                $mailboxMessage = $payload | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            } catch {
                continue
            }

            $content = Get-CommanderPollValue -InputObject $mailboxMessage -Name 'content' -Default $null
            $eventName = [string](Get-CommanderPollValue -InputObject $content -Name 'event' -Default '')
            if ([string]::IsNullOrWhiteSpace($eventName)) {
                continue
            }

            $messages.Add([ordered]@{
                timestamp   = [string](Get-CommanderPollValue -InputObject $mailboxMessage -Name 'timestamp' -Default ([System.DateTimeOffset]::Now.ToString('o')))
                session     = [string](Get-CommanderPollValue -InputObject $content -Name 'session' -Default $SessionName)
                event       = $eventName
                message     = [string](Get-CommanderPollValue -InputObject $content -Name 'message' -Default '')
                label       = [string](Get-CommanderPollValue -InputObject $content -Name 'label' -Default '')
                pane_id     = [string](Get-CommanderPollValue -InputObject $content -Name 'pane_id' -Default '')
                role        = [string](Get-CommanderPollValue -InputObject $content -Name 'role' -Default '')
                status      = [string](Get-CommanderPollValue -InputObject $content -Name 'status' -Default '')
                exit_reason = [string](Get-CommanderPollValue -InputObject $content -Name 'exit_reason' -Default '')
                data        = Get-CommanderPollValue -InputObject $content -Name 'data' -Default ([ordered]@{})
                source      = 'mailbox'
                mailbox_from = [string](Get-CommanderPollValue -InputObject $mailboxMessage -Name 'from' -Default '')
            })
        } catch {
            break
        } finally {
            if ($server) {
                $server.Dispose()
            }
        }
    }

    return @($messages)
}

function Get-CommanderPollEventSignature {
    param([Parameter(Mandatory = $true)]$EventRecord)

    return '{0}|{1}|{2}|{3}|{4}' -f `
        ([string](Get-CommanderPollValue -InputObject $EventRecord -Name 'event' -Default '')), `
        ([string](Get-CommanderPollValue -InputObject $EventRecord -Name 'pane_id' -Default '')), `
        ([string](Get-CommanderPollValue -InputObject $EventRecord -Name 'label' -Default '')), `
        ([string](Get-CommanderPollValue -InputObject $EventRecord -Name 'status' -Default '')), `
        ([string](Get-CommanderPollValue -InputObject $EventRecord -Name 'message' -Default ''))
}

function Get-CommanderTelegramNotificationProfile {
    $profile = [string]$env:WINSMUX_TELEGRAM_PROFILE
    if (-not [string]::IsNullOrWhiteSpace($profile)) {
        switch ($profile.Trim().ToLowerInvariant()) {
            { $_ -in @('external', 'default', 'public') } { return 'external' }
            { $_ -in @('verbose', 'all', 'internal') } { return 'verbose' }
            { $_ -in @('none', 'off', 'disabled') } { return 'none' }
        }
    }

    $override = [string]$env:WINSMUX_TELEGRAM_INCLUDE_INTERNAL_EVENTS
    if (-not [string]::IsNullOrWhiteSpace($override) -and $override.Trim().ToLowerInvariant() -in @('1', 'true', 'yes', 'on')) {
        return 'verbose'
    }

    return 'external'
}

function Test-CommanderTelegramNotificationEnabled {
    param([Parameter(Mandatory = $true)][string]$Event)

    $externalFacingEvents = @(
        'commander.review_requested',
        'commander.review_passed',
        'commander.review_failed',
        'commander.blocked',
        'commander.commit_ready',
        'commander.commit_done'
    )

    $internalOnlyEvents = @(
        'commander.dispatch_needed',
        'commander.auto_approved',
        'commander.started',
        'pane.completed',
        'pane.exec_completed'
    )

    switch (Get-CommanderTelegramNotificationProfile) {
        'none' { return $false }
        'verbose' { return $true }
        default {
            if ($Event -in $externalFacingEvents) {
                return $true
            }

            if ($Event -in $internalOnlyEvents) {
                return $false
            }

            return $false
        }
    }
}

function Send-CommanderTelegramNotification {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$PaneId = '',
        [string]$Label = '',
        [string]$Role = '',
        [string]$Branch = '',
        [string]$HeadSha = ''
    )

    if (-not (Test-CommanderTelegramNotificationEnabled -Event $Event)) {
        return
    }

    try {
        $chatId = $env:WINSMUX_TELEGRAM_CHAT_ID
        if ([string]::IsNullOrWhiteSpace($chatId)) {
            $chatId = '8642321094'
        }

        $tokenPath = Join-Path $env:USERPROFILE '.claude' 'channels' 'telegram' '.env'
        if (-not (Test-Path $tokenPath)) { return }
        $tokenLine = Get-Content $tokenPath -Raw -Encoding UTF8
        if ($tokenLine -match 'TELEGRAM_BOT_TOKEN=(.+)') {
            $botToken = $Matches[1].Trim()
        } else { return }

        $shortSha = if ($HeadSha.Length -ge 7) { $HeadSha.Substring(0, 7) } else { $HeadSha }
        $lines = @(
            "[winsmux] $Event"
            "セッション: $SessionName"
        )
        if ($Label) { $lines += "ペイン: $Label ($PaneId)" }
        if ($Role) { $lines += "ロール: $Role" }
        if ($Branch) { $lines += "ブランチ: $Branch" }
        if ($shortSha) { $lines += "SHA: $shortSha" }
        $lines += ''
        $lines += $Message

        $text = $lines -join "`n"
        $body = @{ chat_id = $chatId; text = $text } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -Uri "https://api.telegram.org/bot$botToken/sendMessage" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ErrorAction SilentlyContinue
    } catch {
        # Telegram notification failure is non-fatal
    }
}

function Invoke-CommanderPollEventRecord {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)]$EventRecord,
        [Parameter(Mandatory = $true)]$Summary
    )

    $projectDir = Get-CommanderPollProjectDir -Manifest $Manifest -ManifestPath $ManifestPath
    $sessionName = Get-CommanderPollSessionName -Manifest $Manifest
    $eventName = [string](Get-CommanderPollValue -InputObject $EventRecord -Name 'event' -Default '')
    $paneContext = Get-CommanderPollPaneContext -Manifest $Manifest -ManifestPath $ManifestPath -EventRecord $EventRecord
    $paneId = [string]$paneContext['pane_id']
    $sourceName = [string](Get-CommanderPollValue -InputObject $EventRecord -Name 'source' -Default 'events_jsonl')
    $sourceId = [string](Get-CommanderPollValue -InputObject $EventRecord -Name 'id' -Default '')
    $Summary['new_events'] = [int]$Summary['new_events'] + 1

    if ($eventName -in @('pane.exec_completed', 'pane.completed')) {
        $diffData = Get-CommanderPollDiffData -WorktreePath ([string]$paneContext['worktree_path'])
        $message = "$($paneContext['label']) ($paneId) 完了。変更ファイル: $($diffData['changed_file_count'])件"

        Write-CommanderPollLog `
            -ProjectDir $projectDir `
            -SessionName $sessionName `
            -EventName 'commander.poll.exec_completed' `
            -Message $message `
            -PaneId $paneId `
            -Data (New-CommanderPollStateData -PaneContext $paneContext -Data ([ordered]@{
                    label     = $paneContext['label']
                    role      = $paneContext['role']
                    diff      = $diffData
                    source    = $sourceName
                    source_id = $sourceId
                }))

        $Summary['completions'] = [int]$Summary['completions'] + 1
        $Summary['messages'] += @($message)
        Update-CommanderPollPaneState -PaneContext $paneContext -Properties ([ordered]@{
                task_state         = 'completed'
                task_owner         = 'Commander'
                branch             = [string](Get-CommanderPollValue -InputObject $diffData -Name 'branch' -Default '')
                head_sha           = [string](Get-CommanderPollValue -InputObject $diffData -Name 'head_sha' -Default '')
                changed_file_count = [int](Get-CommanderPollValue -InputObject $diffData -Name 'changed_file_count' -Default 0)
                changed_files      = @(Get-CommanderPollValue -InputObject $diffData -Name 'changed_files' -Default @())
                last_event         = 'commander.poll.exec_completed'
                last_event_at      = (Get-Date).ToString('o')
            })

        Send-CommanderTelegramNotification -ProjectDir $projectDir -SessionName $sessionName `
            -Event $eventName -Message $message -PaneId $paneId `
            -Label ([string]$paneContext['label']) -Role ([string]$paneContext['role']) `
            -Branch (git -C $projectDir rev-parse --abbrev-ref HEAD 2>$null) `
            -HeadSha (git -C $projectDir rev-parse HEAD 2>$null)
        return
    }

    if ($eventName -eq 'pane.idle') {
        $message = "$($paneContext['label']) ($paneId) がアイドル。次タスクのディスパッチが必要"

        Write-CommanderPollLog `
            -ProjectDir $projectDir `
            -SessionName $sessionName `
            -EventName 'commander.poll.idle_dispatch_needed' `
            -Message $message `
            -PaneId $paneId `
            -Data (New-CommanderPollStateData -PaneContext $paneContext -Data ([ordered]@{
                    label      = $paneContext['label']
                    role       = $paneContext['role']
                    status     = [string](Get-CommanderPollValue -InputObject $EventRecord -Name 'status' -Default '')
                    event      = $eventName
                    source     = $sourceName
                    source_id  = $sourceId
                }))

        $Summary['dispatches'] = [int]$Summary['dispatches'] + 1
        $Summary['messages'] += @($message)
        Update-CommanderPollPaneState -PaneContext $paneContext -Properties ([ordered]@{
                task_state    = 'waiting_for_dispatch'
                task_owner    = 'Commander'
                last_event    = 'commander.poll.idle_dispatch_needed'
                last_event_at = (Get-Date).ToString('o')
            })

        Send-CommanderTelegramNotification -ProjectDir $projectDir -SessionName $sessionName `
            -Event 'commander.dispatch_needed' -Message $message -PaneId $paneId `
            -Label ([string]$paneContext['label']) -Role ([string]$paneContext['role'])
        return
    }

    if (Test-CommanderPollApprovalEvent -EventRecord $EventRecord) {
        if ([string]::IsNullOrWhiteSpace($paneId)) {
            $Summary['errors'] = [int]$Summary['errors'] + 1
            $Summary['messages'] += @('approval_waiting event is missing pane_id')
            return
        }

        Approve-CommanderPollPane -PaneId $paneId
        $message = "$($paneContext['label']) ($paneId) を自動承認"

        Write-CommanderPollLog `
            -ProjectDir $projectDir `
            -SessionName $sessionName `
            -EventName 'commander.poll.auto_approved' `
            -Message $message `
            -PaneId $paneId `
            -Data (New-CommanderPollStateData -PaneContext $paneContext -Data ([ordered]@{
                    label     = $paneContext['label']
                    role      = $paneContext['role']
                    source    = $sourceName
                    source_id = $sourceId
                }))

        $Summary['approvals'] = [int]$Summary['approvals'] + 1
        $Summary['messages'] += @($message)
        Update-CommanderPollPaneState -PaneContext $paneContext -Properties ([ordered]@{
                task_owner    = 'Commander'
                last_event    = 'commander.poll.auto_approved'
                last_event_at = (Get-Date).ToString('o')
            })

        Send-CommanderTelegramNotification -ProjectDir $projectDir -SessionName $sessionName `
            -Event 'commander.auto_approved' -Message $message -PaneId $paneId `
            -Label ([string]$paneContext['label']) -Role ([string]$paneContext['role'])
    }
}

function Invoke-CommanderPollCycle {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [int]$ProcessedLineCount = 0,
        [AllowNull()]$ProcessedEventSignatures = $null
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Manifest not found: $ManifestPath"
    }

    if ($null -eq $ProcessedEventSignatures) {
        $ProcessedEventSignatures = [ordered]@{}
    }

    $manifest = Read-CommanderPollManifest -Path $ManifestPath
    $projectDir = Get-CommanderPollProjectDir -Manifest $manifest -ManifestPath $ManifestPath
    $sessionName = Get-CommanderPollSessionName -Manifest $manifest
    $eventsPath = Get-CommanderPollEventsPath -ProjectDir $projectDir
    $summary = New-CommanderPollCycleSummary -ManifestPath $ManifestPath -EventsPath $eventsPath

    try {
        $eventRecords = [System.Collections.Generic.List[object]]::new()
        $lines = @()
        if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
            $lines = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8)
        }

        if ($lines.Count -lt $ProcessedLineCount) {
            $ProcessedLineCount = 0
        }

        for ($index = $ProcessedLineCount; $index -lt $lines.Count; $index++) {
            $line = [string]$lines[$index]
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $eventRecord = $line | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                $eventRecord['source'] = 'events_jsonl'
                $eventRecords.Add($eventRecord)
            } catch {
                $summary['errors'] = [int]$summary['errors'] + 1
                $summary['messages'] += @("Failed to parse event line $($index + 1): $($_.Exception.Message)")
            }
        }

        $ProcessedLineCount = $lines.Count

        $mailboxRecords = @(Receive-CommanderPollMailboxMessages -SessionName $sessionName)
        $summary['mailbox_events'] = $mailboxRecords.Count
        foreach ($mailboxRecord in $mailboxRecords) {
            $eventRecords.Add($mailboxRecord)
        }

        foreach ($eventRecord in $eventRecords) {
            $signature = Get-CommanderPollEventSignature -EventRecord $eventRecord
            if ($ProcessedEventSignatures.Contains($signature)) {
                continue
            }

            $ProcessedEventSignatures[$signature] = [string](Get-CommanderPollValue -InputObject $eventRecord -Name 'timestamp' -Default ([System.DateTimeOffset]::Now.ToString('o')))
            Invoke-CommanderPollEventRecord -Manifest $manifest -ManifestPath $ManifestPath -EventRecord $eventRecord -Summary $summary
        }
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

    return [ordered]@{
        Summary                  = $summary
        ProcessedLineCount       = $ProcessedLineCount
        ProcessedEventSignatures = $ProcessedEventSignatures
    }
}

function Get-CommanderPollPreferredReviewPane {
    param([AllowNull()]$Manifest)

    if ($null -eq $Manifest -or $null -eq $Manifest.Panes) {
        return $null
    }

    foreach ($preferredRole in @('Reviewer', 'Worker')) {
        foreach ($label in $Manifest.Panes.Keys) {
            $pane = $Manifest.Panes[$label]
            $role = [string](Get-CommanderPollValue -InputObject $pane -Name 'role' -Default '')
            $status = [string](Get-CommanderPollValue -InputObject $pane -Name 'status' -Default '')
            if ($role -eq $preferredRole -and $status -ne 'bootstrap_invalid') {
                return [ordered]@{
                    PaneId = [string](Get-CommanderPollValue -InputObject $pane -Name 'pane_id' -Default '')
                    Label  = [string]$label
                    Role   = $role
                }
            }
        }
    }

    return $null
}

function Invoke-CommanderStateMachine {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentState,
        [Parameter(Mandatory = $true)]$CycleSummary,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [string]$CommitReadySha = ''
    )

    $nextState = $CurrentState
    $nextCommitReadySha = $CommitReadySha

    switch ($CurrentState) {
        'starting' { $nextState = 'waiting_for_dispatch' }
        'waiting_for_dispatch' {
            if ([int]$CycleSummary['completions'] -gt 0) { $nextState = 'waiting_for_review' }
        }
        'builder_running' {
            if ([int]$CycleSummary['completions'] -gt 0) { $nextState = 'waiting_for_review' }
        }
        'waiting_for_review' {
            try {
                $branch = (git -C $ProjectDir rev-parse --abbrev-ref HEAD 2>$null)
                $headSha = (git -C $ProjectDir rev-parse HEAD 2>$null)
                $manifest = Read-CommanderPollManifest -Path $ManifestPath
                $reviewPane = Get-CommanderPollPreferredReviewPane -Manifest $manifest
                if ($null -eq $reviewPane -or [string]::IsNullOrWhiteSpace([string]$reviewPane.PaneId)) {
                    Send-CommanderTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                        -Event 'commander.blocked' -Message "Review 可能なペインが見つかりません。" -Branch $branch -HeadSha $headSha
                    $nextState = 'blocked_no_review_target'
                } else {
                    $wb = Get-WinsmuxBin
                    & $wb send-keys -t $reviewPane.PaneId -l 'winsmux review-request' 2>$null | Out-Null
                    & $wb send-keys -t $reviewPane.PaneId Enter 2>$null | Out-Null
                    Send-CommanderTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                        -Event 'commander.review_requested' -Message "$($reviewPane.Label) ($($reviewPane.PaneId)) にレビュー依頼送信。PASS/FAIL 待機中。" `
                        -PaneId $reviewPane.PaneId -Label $reviewPane.Label -Role $reviewPane.Role -Branch $branch -HeadSha $headSha
                    $nextState = 'review_requested'
                }
            } catch {
                Write-Warning "TASK-238: review dispatch failed: $($_.Exception.Message)"
                $nextState = 'blocked_review_failed'
            }
        }
        'review_requested' {
            try {
                $rsp = Join-Path (Join-Path $ProjectDir '.winsmux') 'review-state.json'
                if (Test-Path $rsp -PathType Leaf) {
                    $branch = (git -C $ProjectDir rev-parse --abbrev-ref HEAD 2>$null)
                    $headSha = (git -C $ProjectDir rev-parse HEAD 2>$null)
                    $rs = Get-Content $rsp -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    if ($rs.Contains($branch)) {
                        $e = $rs[$branch]
                        $st = [string]$e['status']
                        $sha = [string]$e['head_sha']
                        $rsRequest = $null
                        if ($e.Contains('request')) { $rsRequest = $e['request'] }
                        $rsReviewerPaneId = ''
                        if ($null -ne $rsRequest -and $rsRequest -is [System.Collections.IDictionary] -and $rsRequest.Contains('target_reviewer_pane_id')) {
                            $rsReviewerPaneId = [string]$rsRequest['target_reviewer_pane_id']
                        }
                        $manifestReviewPaneId = ''
                        $manifest2 = Read-CommanderPollManifest -Path $ManifestPath
                        $reviewPane = Get-CommanderPollPreferredReviewPane -Manifest $manifest2
                        if ($null -ne $reviewPane) {
                            $manifestReviewPaneId = [string]$reviewPane.PaneId
                        }
                        $reviewerMatch = [string]::IsNullOrWhiteSpace($rsReviewerPaneId) -or $rsReviewerPaneId -eq $manifestReviewPaneId
                        if ($st -eq 'PASS' -and $sha -eq $headSha -and $reviewerMatch) {
                            Send-CommanderTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                                -Event 'commander.review_passed' -Message "レビュー PASS。" -Branch $branch -HeadSha $headSha
                            $nextState = 'review_passed'
                        } elseif ($st -eq 'PASS' -and $sha -eq $headSha -and -not $reviewerMatch) {
                            Write-Warning "TASK-238: review PASS pane_id mismatch: review-state=$rsReviewerPaneId manifest=$manifestReviewPaneId"
                        } elseif ($st -eq 'FAIL') {
                            Send-CommanderTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                                -Event 'commander.review_failed' -Message "レビュー FAIL。修正が必要。" -Branch $branch -HeadSha $headSha
                            $nextState = 'blocked_review_failed'
                        }
                    }
                }
            } catch { Write-Warning "TASK-238: review-state read error: $($_.Exception.Message)" }
        }
        'review_passed' {
            $headSha = (git -C $ProjectDir rev-parse HEAD 2>$null)
            $nextCommitReadySha = $headSha
            Send-CommanderTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                -Event 'commander.commit_ready' -Message "コミット準備完了。" -HeadSha $headSha
            $nextState = 'commit_ready'
        }
        'commit_ready' {
            $currentSha = (git -C $ProjectDir rev-parse HEAD 2>$null)
            if ($CommitReadySha -and $currentSha -ne $CommitReadySha) {
                Send-CommanderTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                    -Event 'commander.commit_done' -Message "コミット検出。次タスク待機。" -HeadSha $currentSha
                $nextState = 'waiting_for_dispatch'
                $nextCommitReadySha = ''
            }
        }
        'blocked_review_failed' {
            if ([int]$CycleSummary['completions'] -gt 0) { $nextState = 'waiting_for_review' }
        }
        'blocked_no_review_target' {
            try {
                $manifest = Read-CommanderPollManifest -Path $ManifestPath
                if ($null -ne (Get-CommanderPollPreferredReviewPane -Manifest $manifest)) {
                    $nextState = 'waiting_for_review'
                }
            } catch { }
        }
        'blocked_bootstrap_invalid' { }
    }

    if ($nextState -ne $CurrentState) {
        Write-CommanderPollLog -ProjectDir $ProjectDir -SessionName $SessionName `
            -EventName 'commander.state_transition' -Message "State: $CurrentState -> $nextState" `
            -Data ([ordered]@{ from = $CurrentState; to = $nextState })
        try {
            $ep = Join-Path (Join-Path $ProjectDir '.winsmux') 'events.jsonl'
            $rec = [ordered]@{
                timestamp = (Get-Date).ToString('o'); session = $SessionName
                event = 'commander.state_transition'; message = "State: $CurrentState -> $nextState"
                label = ''; pane_id = ''; role = 'Commander'; status = $nextState
                exit_reason = ''; data = [ordered]@{ from = $CurrentState; to = $nextState }
            }
            Write-WinsmuxTextFile -Path $ep -Content ($rec | ConvertTo-Json -Compress -Depth 10) -Append
        } catch { }
    }

    return [ordered]@{ State = $nextState; CommitReadySha = $nextCommitReadySha }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Manifest not found: $ManifestPath"
    }

    $initialManifest = Read-CommanderPollManifest -Path $ManifestPath
    $initialProjectDir = Get-CommanderPollProjectDir -Manifest $initialManifest -ManifestPath $ManifestPath
    $eventsPath = Get-CommanderPollEventsPath -ProjectDir $initialProjectDir
    $processedLineCount = 0
    $processedEventSignatures = [ordered]@{}

    if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
        $processedLineCount = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8).Count
    }

    Send-CommanderTelegramNotification -ProjectDir $initialProjectDir `
        -SessionName (Get-CommanderPollSessionName -Manifest $initialManifest) `
        -Event 'commander.started' -Message "Commander Poll 開始。間隔: ${Interval}秒"

    $commanderState = 'starting'
    $commitReadySha = ''

    while ($true) {
        $cycleResult = Invoke-CommanderPollCycle `
            -ManifestPath $ManifestPath `
            -ProcessedLineCount $processedLineCount `
            -ProcessedEventSignatures $processedEventSignatures

        $processedLineCount = [int]$cycleResult['ProcessedLineCount']
        $processedEventSignatures = $cycleResult['ProcessedEventSignatures']
        $smResult = Invoke-CommanderStateMachine `
            -CurrentState $commanderState `
            -CycleSummary ($cycleResult['Summary']) `
            -ProjectDir $initialProjectDir `
            -SessionName (Get-CommanderPollSessionName -Manifest (Read-CommanderPollManifest -Path $ManifestPath)) `
            -ManifestPath $ManifestPath `
            -CommitReadySha $commitReadySha

        $commanderState = [string]$smResult['State']
        $commitReadySha = [string]$smResult['CommitReadySha']

        $summaryOutput = $cycleResult['Summary']
        $summaryOutput['commander_state'] = $commanderState
        Write-Output ($summaryOutput | ConvertTo-Json -Compress -Depth 10)
        Start-Sleep -Seconds $Interval
    }
}
