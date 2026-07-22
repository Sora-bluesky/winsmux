[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [string]$StartupToken = '',
    [int]$Interval = 20
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'json-compat.ps1')
. (Join-Path $PSScriptRoot 'manifest.ps1')
. (Join-Path $PSScriptRoot 'clm-safe-io.ps1')
. (Join-Path $PSScriptRoot 'pane-control.ps1')
$operatorPollLoggerParameterNames = @(
    'Command', 'ProjectDir', 'SessionName', 'Event', 'Level', 'Message', 'Role',
    'PaneId', 'Target', 'DataJson', 'MaxBytes', 'RetentionCount', 'AsJson'
)
$operatorPollLoggerCallerVariables = [ordered]@{}
foreach ($name in $operatorPollLoggerParameterNames) {
    $variable = Get-Variable -Name $name -Scope Local -ErrorAction SilentlyContinue
    if ($null -ne $variable) {
        $operatorPollLoggerCallerVariables[$name] = $variable.Value
    }
}
try {
    . (Join-Path $PSScriptRoot 'logger.ps1')
} finally {
    foreach ($name in $operatorPollLoggerParameterNames) {
        if ($operatorPollLoggerCallerVariables.Contains($name)) {
            Set-Variable -Name $name -Value $operatorPollLoggerCallerVariables[$name] -Scope Local -Force
        } else {
            Remove-Variable -Name $name -Scope Local -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Variable -Name operatorPollLoggerParameterNames -Scope Local -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name operatorPollLoggerCallerVariables -Scope Local -Force -ErrorAction SilentlyContinue
}

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

function Get-OperatorPollValue {
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

function Test-OperatorPollExactPropertyNames {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$AllowedNames
    )

    if ($null -eq $InputObject) { return $false }
    $names = if ($InputObject -is [Collections.IDictionary]) {
        @($InputObject.Keys | ForEach-Object { [string]$_ })
    } else {
        @($InputObject.PSObject.Properties.Name | ForEach-Object { [string]$_ })
    }
    return $names.Count -eq $AllowedNames.Count -and
        @($names | Where-Object { $_ -notin $AllowedNames }).Count -eq 0 -and
        @($AllowedNames | Where-Object { $_ -notin $names }).Count -eq 0
}

function Test-OperatorPollGenerationId {
    param([AllowNull()][string]$Value)

    return $null -ne $Value -and $Value -cmatch '\A(?:[0-9a-f]{32}|[a-z][a-z0-9]*(?:-[a-z0-9]+)*)\z'
}

function Test-OperatorPollWorkflowAcknowledgementData {
    param([AllowNull()]$Data)

    $allowed = @(
        'schema_version', 'run_id', 'node_id', 'idempotency_key', 'generation_id',
        'config_fingerprint', 'workflow_fingerprint', 'source_head', 'pane_id', 'status', 'evidence_ref'
    )
    if (-not (Test-OperatorPollExactPropertyNames -InputObject $Data -AllowedNames $allowed)) { return $false }
    $runId = [string](Get-OperatorPollValue -InputObject $Data -Name 'run_id' -Default '')
    $nodeId = [string](Get-OperatorPollValue -InputObject $Data -Name 'node_id' -Default '')
    $schemaVersion = Get-OperatorPollValue -InputObject $Data -Name 'schema_version' -Default $null
    if (
        $schemaVersion -isnot [ValueType] -or [int64]$schemaVersion -ne 1 -or
        $runId -cnotmatch '^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$' -or
        $nodeId -cnotmatch '^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$' -or
        [string](Get-OperatorPollValue -InputObject $Data -Name 'idempotency_key' -Default '') -cne "$runId`:$nodeId" -or
        -not (Test-OperatorPollGenerationId -Value ([string](Get-OperatorPollValue -InputObject $Data -Name 'generation_id' -Default ''))) -or
        [string](Get-OperatorPollValue -InputObject $Data -Name 'config_fingerprint' -Default '') -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        [string](Get-OperatorPollValue -InputObject $Data -Name 'workflow_fingerprint' -Default '') -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        [string](Get-OperatorPollValue -InputObject $Data -Name 'source_head' -Default '') -cnotmatch '^[0-9a-f]{40}$' -or
        [string](Get-OperatorPollValue -InputObject $Data -Name 'pane_id' -Default '') -cnotmatch '^%[0-9]+$' -or
        [string](Get-OperatorPollValue -InputObject $Data -Name 'status' -Default '') -cne 'succeeded' -or
        [string](Get-OperatorPollValue -InputObject $Data -Name 'evidence_ref' -Default '') -cne "workflow-ack:$runId`:$nodeId"
    ) {
        return $false
    }
    return $true
}

function Test-OperatorPollWorkflowAcknowledgementMailbox {
    param(
        [AllowNull()]$MailboxMessage,
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    $allowedEnvelope = @(
        'mailbox_version', 'message_id', 'correlation_id', 'causation_id', 'idempotency_key',
        'message_type', 'state', 'ttl_seconds', 'ack_required', 'from', 'to', 'timestamp', 'content'
    )
    $allowedContent = @('session', 'event', 'message', 'label', 'pane_id', 'role', 'status', 'exit_reason', 'data')
    if (-not (Test-OperatorPollExactPropertyNames -InputObject $MailboxMessage -AllowedNames $allowedEnvelope)) { return $false }
    $content = Get-OperatorPollValue -InputObject $MailboxMessage -Name 'content' -Default $null
    if (-not (Test-OperatorPollExactPropertyNames -InputObject $content -AllowedNames $allowedContent)) { return $false }
    if (
        [int](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'mailbox_version' -Default 0) -ne 2 -or
        [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'message_type' -Default '') -cne 'workflow-completion' -or
        [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'state' -Default '') -cne 'created' -or
        -not [bool](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'ack_required' -Default $false) -or
        [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'to' -Default '') -cne 'Operator' -or
        [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'message_id' -Default '') -ne [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'correlation_id' -Default '') -or
        -not [string]::IsNullOrWhiteSpace([string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'causation_id' -Default '')) -or
        [string](Get-OperatorPollValue -InputObject $content -Name 'session' -Default '') -cne $SessionName -or
        [string](Get-OperatorPollValue -InputObject $content -Name 'event' -Default '') -cne 'workflow.node.acknowledged' -or
        [string](Get-OperatorPollValue -InputObject $content -Name 'message' -Default '') -cne 'Declarative workflow completion.' -or
        [string](Get-OperatorPollValue -InputObject $content -Name 'status' -Default '') -cne 'succeeded' -or
        -not [string]::IsNullOrWhiteSpace([string](Get-OperatorPollValue -InputObject $content -Name 'exit_reason' -Default '')) -or
        [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'from' -Default '') -cne [string](Get-OperatorPollValue -InputObject $content -Name 'label' -Default '') -or
        -not (Test-OperatorPollWorkflowAcknowledgementData -Data (Get-OperatorPollValue -InputObject $content -Name 'data' -Default $null))
    ) {
        return $false
    }
    return $true
}

function Get-OperatorPollWorkflowAcknowledgementData {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [AllowEmptyString()][string]$MessageId = ''
    )

    $acknowledgement = [ordered]@{}
    foreach ($field in @(
            'schema_version', 'run_id', 'node_id', 'idempotency_key', 'generation_id',
            'config_fingerprint', 'workflow_fingerprint', 'source_head', 'pane_id', 'status', 'evidence_ref'
        )) {
        $acknowledgement[$field] = Get-OperatorPollValue -InputObject $Data -Name $field -Default $null
    }
    $acknowledgement['transport'] = 'mailbox'
    if (-not [string]::IsNullOrWhiteSpace($MessageId)) {
        $acknowledgement['message_id'] = $MessageId
    }
    return $acknowledgement
}

function Test-OperatorPollWorkflowAcknowledgementRecord {
    param(
        [Parameter(Mandatory = $true)]$EventRecord,
        [Parameter(Mandatory = $true)]$PaneContext,
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    $data = Get-OperatorPollValue -InputObject $EventRecord -Name 'data' -Default $null
    $acknowledgement = Get-OperatorPollWorkflowAcknowledgementData -Data $data
    $generationId = [string]$PaneContext['generation_id']
    $manifestPaneId = [string]$PaneContext['manifest_pane_id']
    $manifestLabel = [string]$PaneContext['label']
    $registeredSession = [string]$PaneContext['session_name']
    return (
        [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'source' -Default '') -ceq 'mailbox' -and
        [int](Get-OperatorPollValue -InputObject $EventRecord -Name 'mailbox_version' -Default 0) -eq 2 -and
        [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'mailbox_state' -Default '') -ceq 'created' -and
        [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'message_type' -Default '') -ceq 'workflow-completion' -and
        [bool](Get-OperatorPollValue -InputObject $EventRecord -Name 'ack_required' -Default $false) -and
        -not [string]::IsNullOrWhiteSpace($manifestPaneId) -and
        -not [string]::IsNullOrWhiteSpace($manifestLabel) -and
        -not [string]::IsNullOrWhiteSpace($registeredSession) -and
        -not [string]::IsNullOrWhiteSpace($generationId) -and
        $SessionName -ceq $registeredSession -and
        [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'session' -Default '') -ceq $registeredSession -and
        [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'pane_id' -Default '') -ceq $manifestPaneId -and
        [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'label' -Default '') -ceq $manifestLabel -and
        [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'mailbox_from' -Default '') -ceq $manifestLabel -and
        [string](Get-OperatorPollValue $PaneContext 'pane_id' '') -ceq $manifestPaneId -and
        [string](Get-OperatorPollValue $PaneContext 'event_pane_id' '') -ceq $manifestPaneId -and
        [string](Get-OperatorPollValue $PaneContext 'event_label' '') -ceq $manifestLabel -and
        [string](Get-OperatorPollValue $acknowledgement -Name 'pane_id' -Default '') -ceq $manifestPaneId -and
        [string]::Equals([string](Get-OperatorPollValue -InputObject $acknowledgement -Name 'generation_id' -Default ''), $generationId, [StringComparison]::Ordinal) -and
        (Test-OperatorPollWorkflowAcknowledgementData -Data (Get-OperatorPollValue -InputObject $EventRecord -Name 'workflow_ack_payload' -Default $data))
    )
}

function ConvertFrom-OperatorPollYamlScalar {
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

function ConvertFrom-OperatorPollManifestContent {
    param([Parameter(Mandatory = $true)][string]$Content)

    $parsed = ConvertFrom-ManifestYaml -Content $Content
    return [ordered]@{
        Session = $parsed.session
        Panes   = $parsed.panes
    }
}

function Read-OperatorPollManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Manifest not found: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Manifest is empty: $Path"
    }

    return ConvertFrom-OperatorPollManifestContent -Content $content
}

function Get-OperatorPollProjectDir {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $projectDir = [string](Get-OperatorPollValue -InputObject $Manifest['Session'] -Name 'project_dir' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($projectDir)) {
        return $projectDir
    }

    return Split-Path (Split-Path $ManifestPath -Parent) -Parent
}

function Get-OperatorPollSessionName {
    param([Parameter(Mandatory = $true)]$Manifest)

    $sessionName = [string](Get-OperatorPollValue -InputObject $Manifest['Session'] -Name 'name' -Default '')
    if ([string]::IsNullOrWhiteSpace($sessionName)) {
        return 'winsmux-orchestra'
    }

    return $sessionName
}

function Get-OperatorPollEventsPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path (Join-Path $ProjectDir '.winsmux') 'events.jsonl'
}

function Get-OperatorPollLogPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $logDir = Join-Path $ProjectDir '.winsmux\logs'
    [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
    return Join-Path $logDir 'operator-poll.jsonl'
}

function Write-OperatorPollLog {
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
    Write-WinsmuxTextFile -Path (Get-OperatorPollLogPath -ProjectDir $ProjectDir) -Content $line -Append
}

function Get-OperatorPollPaneContext {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)]$EventRecord
    )

    $eventPaneId = [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'pane_id' -Default '')
    $eventLabel = [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'label' -Default '')
    $eventRole = [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'role' -Default '')
    $projectDir = Get-OperatorPollProjectDir -Manifest $Manifest -ManifestPath $ManifestPath
    $manifestSession = Get-OperatorPollValue -InputObject $Manifest -Name 'Session' -Default $null
    $generationId = [string](Get-OperatorPollValue -InputObject $manifestSession -Name 'generation_id' -Default '')

    $matchedLabel = ''
    $matchedPane = $null

    if (-not [string]::IsNullOrWhiteSpace($eventLabel) -and
        -not [string]::IsNullOrWhiteSpace($eventPaneId) -and
        $Manifest['Panes'].Contains($eventLabel)) {
        $candidatePane = $Manifest['Panes'][$eventLabel]
        if ([string](Get-OperatorPollValue -InputObject $candidatePane -Name 'pane_id' -Default '') -ceq $eventPaneId) {
            $matchedLabel = $eventLabel
            $matchedPane = $candidatePane
        }
    }

    $role = $eventRole
    if ($null -ne $matchedPane) {
        $paneRole = [string](Get-OperatorPollValue -InputObject $matchedPane -Name 'role' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($paneRole)) {
            $role = $paneRole
        }
    }

    $worktreePath = ''
    if ($null -ne $matchedPane) {
        foreach ($key in @('builder_worktree_path', 'launch_dir')) {
            $candidate = [string](Get-OperatorPollValue -InputObject $matchedPane -Name $key -Default '')
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $worktreePath = $candidate
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($worktreePath)) {
        $worktreePath = $projectDir
    }

    $manifestPaneId = if ($null -ne $matchedPane) {
        [string](Get-OperatorPollValue -InputObject $matchedPane -Name 'pane_id' -Default '')
    } else {
        ''
    }

    return [ordered]@{
        project_dir   = $projectDir
        manifest_path = $ManifestPath
        generation_id = $generationId
        session_name  = Get-OperatorPollSessionName -Manifest $Manifest
        pane_id       = $manifestPaneId
        manifest_pane_id = $manifestPaneId
        event_pane_id = $eventPaneId
        event_label   = $eventLabel
        label         = $matchedLabel
        role          = $role
        worktree_path = $worktreePath
        task_id       = if ($null -ne $matchedPane) { [string](Get-OperatorPollValue -InputObject $matchedPane -Name 'task_id' -Default '') } else { '' }
        task          = if ($null -ne $matchedPane) { [string](Get-OperatorPollValue -InputObject $matchedPane -Name 'task' -Default '') } else { '' }
        task_state    = if ($null -ne $matchedPane) { [string](Get-OperatorPollValue -InputObject $matchedPane -Name 'task_state' -Default '') } else { '' }
        task_owner    = if ($null -ne $matchedPane) { [string](Get-OperatorPollValue -InputObject $matchedPane -Name 'task_owner' -Default '') } else { '' }
        review_state  = if ($null -ne $matchedPane) { [string](Get-OperatorPollValue -InputObject $matchedPane -Name 'review_state' -Default '') } else { '' }
        branch        = if ($null -ne $matchedPane) { [string](Get-OperatorPollValue -InputObject $matchedPane -Name 'branch' -Default '') } else { '' }
        head_sha      = if ($null -ne $matchedPane) { [string](Get-OperatorPollValue -InputObject $matchedPane -Name 'head_sha' -Default '') } else { '' }
    }
}

function Update-OperatorPollPaneState {
    param(
        [Parameter(Mandatory = $true)]$PaneContext,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Properties
    )

    if ([string]::IsNullOrWhiteSpace([string]$PaneContext['pane_id'])) {
        return
    }

    try {
        $manifestPath = [string]$PaneContext['manifest_path']
        if ([string]::IsNullOrWhiteSpace($manifestPath)) {
            return
        }

        $expectedGenerationId = [string]$PaneContext['generation_id']
        Set-PaneControlManifestPaneProperties -ManifestPath $manifestPath -PaneId ([string]$PaneContext['pane_id']) `
            -Properties $Properties -ExpectedGenerationId $expectedGenerationId
    } catch {
        # Pane state enrichment is best-effort.
    }
}

function New-OperatorPollStateData {
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

function Invoke-OperatorPollWinsmux {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $winsmuxBin = Get-WinsmuxBin
    if (-not $winsmuxBin) {
        throw (Get-WinsmuxOperatorNotFoundMessage)
    }

    $output = Invoke-WinsmuxBridgeCommand -WinsmuxBin $winsmuxBin -Arguments $Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = 'unknown winsmux error'
        }

        throw "winsmux $($Arguments -join ' ') failed: $message"
    }

    return $output
}

function Approve-OperatorPollPane {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    Invoke-OperatorPollWinsmux -Arguments @('send-keys', '-t', $PaneId, 'Enter') | Out-Null
}

function Send-OperatorPollLiteral {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Text
    )

    Invoke-OperatorPollWinsmux -Arguments @('send-keys', '-t', $PaneId, '-l', '--', $Text) | Out-Null
}

function Get-OperatorPollGitOutput {
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

function Get-OperatorPollDiffData {
    param([Parameter(Mandatory = $true)][string]$WorktreePath)

    $statusLines = Get-OperatorPollGitOutput -WorktreePath $WorktreePath -Arguments @('status', '--short', '--untracked-files=all')
    $unstagedDiff = Get-OperatorPollGitOutput -WorktreePath $WorktreePath -Arguments @('diff', '--stat', '--no-ext-diff')
    $stagedDiff = Get-OperatorPollGitOutput -WorktreePath $WorktreePath -Arguments @('diff', '--cached', '--stat', '--no-ext-diff')
    $branchLines = Get-OperatorPollGitOutput -WorktreePath $WorktreePath -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    $headShaLines = Get-OperatorPollGitOutput -WorktreePath $WorktreePath -Arguments @('rev-parse', 'HEAD')

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

function Test-OperatorPollApprovalEvent {
    param([Parameter(Mandatory = $true)]$EventRecord)

    $eventName = [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'event' -Default '')
    if ($eventName -eq 'approval_waiting') {
        return $true
    }

    $status = [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'status' -Default '')
    if ($status -eq 'approval_waiting') {
        return $true
    }

    $data = Get-OperatorPollValue -InputObject $EventRecord -Name 'data' -Default $null
    $dataStatus = [string](Get-OperatorPollValue -InputObject $data -Name 'status' -Default '')
    return ($eventName -eq 'monitor.status' -and $dataStatus -eq 'approval_waiting')
}

function New-OperatorPollCycleSummary {
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

function Get-OperatorPollMailboxChannel {
    param([string]$SessionName = 'winsmux-orchestra')

    $resolvedSessionName = if ([string]::IsNullOrWhiteSpace($SessionName)) {
        'winsmux-orchestra'
    } else {
        $SessionName.Trim()
    }

    $safeSessionName = [regex]::Replace($resolvedSessionName, '[^A-Za-z0-9_-]', '-')
    return "$safeSessionName-operator"
}

function ConvertTo-OperatorPollDataMap {
    param([AllowNull()]$InputObject = $null)

    $data = [ordered]@{}
    if ($null -eq $InputObject) {
        return $data
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $data[[string]$key] = $InputObject[$key]
        }
        return $data
    }

    foreach ($property in @($InputObject.PSObject.Properties)) {
        $data[[string]$property.Name] = $property.Value
    }

    return $data
}

function ConvertTo-OperatorPollMailboxRecord {
    param(
        [AllowNull()]$MailboxMessage = $null,
        [string]$SessionName = 'winsmux-orchestra'
    )

    if ($null -eq $MailboxMessage) {
        return $null
    }

    $mailboxVersion = 1
    $versionValue = Get-OperatorPollValue -InputObject $MailboxMessage -Name 'mailbox_version' -Default 1
    [int]::TryParse(([string]$versionValue), [ref]$mailboxVersion) | Out-Null
    $content = Get-OperatorPollValue -InputObject $MailboxMessage -Name 'content' -Default $null
    $eventName = [string](Get-OperatorPollValue -InputObject $content -Name 'event' -Default '')
    if ([string]::IsNullOrWhiteSpace($eventName)) {
        return $null
    }
    if ($eventName -ceq 'workflow.node.acknowledged' -and -not (Test-OperatorPollWorkflowAcknowledgementMailbox -MailboxMessage $MailboxMessage -SessionName $SessionName)) {
        return $null
    }

    $messageId = [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'message_id' -Default '')
    $correlationId = [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'correlation_id' -Default '')
    $causationId = [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'causation_id' -Default '')
    $idempotencyKey = [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'idempotency_key' -Default '')
    $messageType = [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'message_type' -Default '')
    $mailboxState = [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'state' -Default '')
    $ttlSeconds = Get-OperatorPollValue -InputObject $MailboxMessage -Name 'ttl_seconds' -Default $null
    $ackRequired = [bool](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'ack_required' -Default $false)

    if ($mailboxVersion -ge 2) {
        if (
            [string]::IsNullOrWhiteSpace($messageId) -or
            [string]::IsNullOrWhiteSpace($idempotencyKey) -or
            [string]::IsNullOrWhiteSpace($messageType) -or
            [string]::IsNullOrWhiteSpace($mailboxState)
        ) {
            return $null
        }
        if ([string]::IsNullOrWhiteSpace($correlationId)) {
            $correlationId = $messageId
        }
    }

    $workflowAcknowledgementPayload = Get-OperatorPollValue -InputObject $content -Name 'data' -Default ([ordered]@{})
    $data = ConvertTo-OperatorPollDataMap -InputObject $workflowAcknowledgementPayload
    if ($mailboxVersion -ge 2) {
        $data['mailbox_version'] = $mailboxVersion
        $data['mailbox_message_id'] = $messageId
        $data['mailbox_correlation_id'] = $correlationId
        $data['mailbox_causation_id'] = $causationId
        $data['mailbox_idempotency_key'] = $idempotencyKey
        $data['mailbox_message_type'] = $messageType
        $data['mailbox_state'] = $mailboxState
        $data['mailbox_ttl_seconds'] = $ttlSeconds
        $data['mailbox_ack_required'] = $ackRequired
    }

    return [ordered]@{
        timestamp       = [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'timestamp' -Default ([System.DateTimeOffset]::Now.ToString('o')))
        session         = [string](Get-OperatorPollValue -InputObject $content -Name 'session' -Default $SessionName)
        event           = $eventName
        message         = [string](Get-OperatorPollValue -InputObject $content -Name 'message' -Default '')
        label           = [string](Get-OperatorPollValue -InputObject $content -Name 'label' -Default '')
        pane_id         = [string](Get-OperatorPollValue -InputObject $content -Name 'pane_id' -Default '')
        role            = [string](Get-OperatorPollValue -InputObject $content -Name 'role' -Default '')
        status          = [string](Get-OperatorPollValue -InputObject $content -Name 'status' -Default '')
        exit_reason     = [string](Get-OperatorPollValue -InputObject $content -Name 'exit_reason' -Default '')
        data            = $data
        source          = 'mailbox'
        mailbox_from    = [string](Get-OperatorPollValue -InputObject $MailboxMessage -Name 'from' -Default '')
        mailbox_version = $mailboxVersion
        mailbox_state   = $mailboxState
        message_id      = $messageId
        correlation_id  = $correlationId
        causation_id    = $causationId
        idempotency_key = $idempotencyKey
        message_type    = $messageType
        ack_required    = $ackRequired
        workflow_ack_payload = if ($eventName -ceq 'workflow.node.acknowledged') { $workflowAcknowledgementPayload } else { $null }
    }
}

function Resolve-OperatorPollProtectedRuntimeAdmission {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$EventRecord,
        [Parameter(Mandatory = $true)]$PaneContext
    )

    $eventSession = [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'session' -Default '')
    $eventLabel = [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'label' -Default '')
    $eventPaneId = [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'pane_id' -Default '')
    $manifestSession = Get-OperatorPollValue -InputObject $Manifest -Name 'Session' -Default $null
    $manifestSessionName = [string](Get-OperatorPollValue -InputObject $manifestSession -Name 'name' -Default '')
    $manifestGenerationId = [string](Get-OperatorPollValue -InputObject $manifestSession -Name 'generation_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($eventSession) -or
        [string]::IsNullOrWhiteSpace($eventLabel) -or
        [string]::IsNullOrWhiteSpace($eventPaneId) -or
        [string]::IsNullOrWhiteSpace($manifestSessionName) -or
        [string]::IsNullOrWhiteSpace($manifestGenerationId) -or
        $eventSession -cne $manifestSessionName -or
        [string](Get-OperatorPollValue $PaneContext 'session_name' '') -cne $manifestSessionName -or
        -not [string]::Equals([string](Get-OperatorPollValue $PaneContext 'generation_id' ''), $manifestGenerationId, [StringComparison]::Ordinal) -or
        [string](Get-OperatorPollValue $PaneContext 'label' '') -cne $eventLabel -or
        [string](Get-OperatorPollValue $PaneContext 'pane_id' '') -cne $eventPaneId) {
        return $null
    }

    try {
        $manifestEntry = Get-PaneControlManifestContext -ProjectDir ([string]$PaneContext['project_dir']) -PaneId $eventPaneId
        if ([string](Get-OperatorPollValue $manifestEntry 'Label' '') -cne $eventLabel -or
            [string](Get-OperatorPollValue $manifestEntry 'PaneId' '') -cne $eventPaneId -or
            -not [string]::Equals([string](Get-OperatorPollValue $manifestEntry 'GenerationId' ''), $manifestGenerationId, [StringComparison]::Ordinal)) {
            return $null
        }
        $validation = Test-PaneControlRuntimeContext -ProjectDir ([string]$PaneContext['project_dir']) -ManifestEntry $manifestEntry -Operation dispatch
        if ($null -eq $validation -or -not [bool](Get-OperatorPollValue $validation 'valid' $false)) { return $null }
        $runtime = Get-OperatorPollValue $validation 'context' $null
        if ($null -eq $runtime -or
            [string](Get-OperatorPollValue $runtime 'session_name' '') -cne $manifestSessionName -or
            -not [string]::Equals([string](Get-OperatorPollValue $runtime 'generation_id' ''), $manifestGenerationId, [StringComparison]::Ordinal) -or
            [string](Get-OperatorPollValue $runtime 'label' '') -cne $eventLabel -or
            [string](Get-OperatorPollValue $runtime 'pane_id' '') -cne $eventPaneId) {
            return $null
        }
        return $PaneContext
    } catch {
        return $null
    }
}

function Receive-OperatorPollMailboxMessages {
    param(
        [string]$SessionName = 'winsmux-orchestra',
        [int]$TimeoutMilliseconds = 25,
        [int]$MaxMessages = 20
    )

    $messages = [System.Collections.Generic.List[object]]::new()
    $pipeName = "winsmux-mailbox-$(Get-OperatorPollMailboxChannel -SessionName $SessionName)"

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
                $mailboxMessage = $payload | ConvertFrom-WinsmuxJson -AsHashtable -ErrorAction Stop
            } catch {
                continue
            }

            $record = ConvertTo-OperatorPollMailboxRecord -MailboxMessage $mailboxMessage -SessionName $SessionName
            if ($null -ne $record) {
                $messages.Add($record)
            }
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

function Remove-OperatorPollTerminalPendingFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        [IO.File]::Delete($Path)
    } catch {
    }
}

function Receive-OperatorPollDurableWorkflowMessages {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [int]$MaxMessages = 20
    )

    $channel = Get-OperatorPollMailboxChannel -SessionName $SessionName
    if ($channel -cnotmatch '^[A-Za-z0-9_-]{1,64}$') { return @() }
    $pendingRoot = Join-Path $ProjectDir ".winsmux\mailbox\$channel\pending"
    if (-not [IO.Directory]::Exists($pendingRoot)) { return @() }
    $messages = [Collections.Generic.List[object]]::new()
    if ($MaxMessages -lt 1) { return @($messages) }
    try {
        $pendingFiles = @(Get-ChildItem -LiteralPath $pendingRoot -File -Filter '*.json' -ErrorAction Stop | Sort-Object Name)
    } catch {
        return @($messages)
    }
    foreach ($file in $pendingFiles) {
        if ($messages.Count -ge $MaxMessages) { break }
        if ($file.BaseName -cnotmatch '^[a-z][a-z0-9-]{0,127}$') {
            Remove-OperatorPollTerminalPendingFile -Path $file.FullName
            continue
        }
        try {
            $fileLength = [int64]$file.Length
        } catch {
            continue
        }
        if ($fileLength -lt 2 -or $fileLength -gt 65536) {
            Remove-OperatorPollTerminalPendingFile -Path $file.FullName
            continue
        }
        try {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
        } catch {
            continue
        }
        if ([Array]::IndexOf($bytes, [byte]0) -ge 0) {
            Remove-OperatorPollTerminalPendingFile -Path $file.FullName
            continue
        }
        try {
            $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            $mailboxMessage = $json | ConvertFrom-WinsmuxJson -AsHashtable -Depth 30 -ErrorAction Stop
            $record = ConvertTo-OperatorPollMailboxRecord -MailboxMessage $mailboxMessage -SessionName $SessionName
            if ($null -eq $record -or [string]$record['message_type'] -cne 'workflow-completion' -or
                [string]$record['message_id'] -cne $file.BaseName) {
                Remove-OperatorPollTerminalPendingFile -Path $file.FullName
                continue
            }
            $createdAt = [DateTimeOffset]::MinValue
            $ttl = 0
            if (-not [DateTimeOffset]::TryParse([string]$record['timestamp'], [ref]$createdAt) -or
                -not [int]::TryParse([string](Get-OperatorPollValue $record['data'] 'mailbox_ttl_seconds' 0), [ref]$ttl) -or
                $ttl -lt 1 -or $ttl -gt 3600) {
                Remove-OperatorPollTerminalPendingFile -Path $file.FullName
                continue
            }
            if ([DateTimeOffset]::UtcNow -gt $createdAt.ToUniversalTime().AddSeconds($ttl)) {
                Remove-OperatorPollTerminalPendingFile -Path $file.FullName
                continue
            }
            $record['durable_pending_path'] = $file.FullName
            $messages.Add($record) | Out-Null
        } catch {
            Remove-OperatorPollTerminalPendingFile -Path $file.FullName
            continue
        }
    }
    return @($messages)
}

function Get-OperatorPollEventSignature {
    param([Parameter(Mandatory = $true)]$EventRecord)

    if ([string](Get-OperatorPollValue $EventRecord 'event' '') -ceq 'workflow.node.acknowledged' -and
        [int](Get-OperatorPollValue $EventRecord 'mailbox_version' 0) -eq 2) {
        $data = Get-OperatorPollValue $EventRecord 'workflow_ack_payload' $null
        return 'workflow-ack|{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}' -f `
            ([string](Get-OperatorPollValue $EventRecord 'message_id' '')), `
            ([string](Get-OperatorPollValue $data 'run_id' '')), `
            ([string](Get-OperatorPollValue $data 'node_id' '')), `
            ([string](Get-OperatorPollValue $data 'idempotency_key' '')), `
            ([string](Get-OperatorPollValue $data 'generation_id' '')), `
            ([string](Get-OperatorPollValue $data 'workflow_fingerprint' '')), `
            ([string](Get-OperatorPollValue $data 'config_fingerprint' '')), `
            ([string](Get-OperatorPollValue $data 'source_head' '')), `
            ([string](Get-OperatorPollValue $data 'pane_id' '')), `
            ([string](Get-OperatorPollValue $data 'status' '')), `
            ([string](Get-OperatorPollValue $data 'evidence_ref' '')), `
            ([string](Get-OperatorPollValue $EventRecord 'idempotency_key' ''))
    }
    if ([int](Get-OperatorPollValue $EventRecord 'mailbox_version' 0) -ge 2) {
        $messageId = [string](Get-OperatorPollValue $EventRecord 'message_id' '')
        if (-not [string]::IsNullOrWhiteSpace($messageId)) {
            return "mailbox-v2|$messageId"
        }
    }

    return '{0}|{1}|{2}|{3}|{4}' -f `
        ([string](Get-OperatorPollValue -InputObject $EventRecord -Name 'event' -Default '')), `
        ([string](Get-OperatorPollValue -InputObject $EventRecord -Name 'pane_id' -Default '')), `
        ([string](Get-OperatorPollValue -InputObject $EventRecord -Name 'label' -Default '')), `
        ([string](Get-OperatorPollValue -InputObject $EventRecord -Name 'status' -Default '')), `
        ([string](Get-OperatorPollValue -InputObject $EventRecord -Name 'message' -Default ''))
}

function Get-OperatorTelegramNotificationProfile {
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

function Test-OperatorTelegramNotificationEnabled {
    param([Parameter(Mandatory = $true)][string]$Event)

    $externalFacingEvents = @(
        'operator.review_requested',
        'operator.review_passed',
        'operator.review_failed',
        'operator.blocked',
        'operator.draft_pr.required',
        'operator.commit_ready',
        'operator.commit_done'
    )

    $internalOnlyEvents = @(
        'operator.dispatch_needed',
        'operator.auto_approved',
        'operator.started',
        'pane.completed',
        'pane.exec_completed'
    )

    switch (Get-OperatorTelegramNotificationProfile) {
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

function Send-OperatorTelegramNotification {
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

    if (-not (Test-OperatorTelegramNotificationEnabled -Event $Event)) {
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

function Invoke-OperatorPollEventRecord {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)]$EventRecord,
        [Parameter(Mandatory = $true)]$Summary
    )

    $projectDir = Get-OperatorPollProjectDir -Manifest $Manifest -ManifestPath $ManifestPath
    $sessionName = Get-OperatorPollSessionName -Manifest $Manifest
    $eventName = [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'event' -Default '')
    $paneContext = Get-OperatorPollPaneContext -Manifest $Manifest -ManifestPath $ManifestPath -EventRecord $EventRecord
    $approvalEvent = Test-OperatorPollApprovalEvent -EventRecord $EventRecord
    $protectedEvent = $eventName -in @('workflow.node.acknowledged', 'pane.exec_completed', 'pane.completed', 'pane.idle') -or $approvalEvent
    if ($protectedEvent) {
        $paneContext = Resolve-OperatorPollProtectedRuntimeAdmission -Manifest $Manifest -EventRecord $EventRecord -PaneContext $paneContext
        if ($null -eq $paneContext) {
            $Summary['errors'] = [int]$Summary['errors'] + 1
            return
        }
    }
    $paneId = [string]$paneContext['pane_id']
    $sourceName = [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'source' -Default 'events_jsonl')
    $sourceId = [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'id' -Default '')
    $Summary['new_events'] = [int]$Summary['new_events'] + 1

    if ($eventName -ceq 'workflow.node.acknowledged') {
        if (-not (Test-OperatorPollWorkflowAcknowledgementRecord -EventRecord $EventRecord -PaneContext $paneContext -SessionName $sessionName)) {
            $Summary['errors'] = [int]$Summary['errors'] + 1
            return
        }
        $acknowledgement = Get-OperatorPollWorkflowAcknowledgementData `
            -Data (Get-OperatorPollValue -InputObject $EventRecord -Name 'workflow_ack_payload' -Default $null) `
            -MessageId ([string](Get-OperatorPollValue $EventRecord 'message_id' ''))
        Write-OrchestraLog -ProjectDir $projectDir -SessionName $sessionName -Event 'workflow.node.acknowledged' -Level 'info' `
            -Message 'Declarative workflow completion was received through the mailbox.' `
            -Role ([string]$paneContext['role']) -PaneId ([string]$paneContext['pane_id']) -Target ([string]$paneContext['label']) -Data $acknowledgement | Out-Null
        return 'workflow_ack_logged'
    }

    if ($eventName -in @('pane.exec_completed', 'pane.completed')) {
        $diffData = Get-OperatorPollDiffData -WorktreePath ([string]$paneContext['worktree_path'])
        $message = "$($paneContext['label']) ($paneId) 完了。変更ファイル: $($diffData['changed_file_count'])件"

        Write-OperatorPollLog `
            -ProjectDir $projectDir `
            -SessionName $sessionName `
            -EventName 'operator.poll.exec_completed' `
            -Message $message `
            -PaneId $paneId `
            -Data (New-OperatorPollStateData -PaneContext $paneContext -Data ([ordered]@{
                    label     = $paneContext['label']
                    role      = $paneContext['role']
                    diff      = $diffData
                    source    = $sourceName
                    source_id = $sourceId
                }))

        $Summary['completions'] = [int]$Summary['completions'] + 1
        $Summary['messages'] += @($message)
        Update-OperatorPollPaneState -PaneContext $paneContext -Properties ([ordered]@{
                task_state         = 'completed'
                task_owner         = 'Operator'
                branch             = [string](Get-OperatorPollValue -InputObject $diffData -Name 'branch' -Default '')
                head_sha           = [string](Get-OperatorPollValue -InputObject $diffData -Name 'head_sha' -Default '')
                changed_file_count = [int](Get-OperatorPollValue -InputObject $diffData -Name 'changed_file_count' -Default 0)
                changed_files      = @(Get-OperatorPollValue -InputObject $diffData -Name 'changed_files' -Default @())
                last_event         = 'operator.poll.exec_completed'
                last_event_at      = (Get-Date).ToString('o')
            })

        Send-OperatorTelegramNotification -ProjectDir $projectDir -SessionName $sessionName `
            -Event $eventName -Message $message -PaneId $paneId `
            -Label ([string]$paneContext['label']) -Role ([string]$paneContext['role']) `
            -Branch (git -C $projectDir rev-parse --abbrev-ref HEAD 2>$null) `
            -HeadSha (git -C $projectDir rev-parse HEAD 2>$null)
        return
    }

    if ($eventName -eq 'pane.idle') {
        $message = "$($paneContext['label']) ($paneId) がアイドル。次タスクのディスパッチが必要"

        Write-OperatorPollLog `
            -ProjectDir $projectDir `
            -SessionName $sessionName `
            -EventName 'operator.poll.idle_dispatch_needed' `
            -Message $message `
            -PaneId $paneId `
            -Data (New-OperatorPollStateData -PaneContext $paneContext -Data ([ordered]@{
                    label      = $paneContext['label']
                    role       = $paneContext['role']
                    status     = [string](Get-OperatorPollValue -InputObject $EventRecord -Name 'status' -Default '')
                    event      = $eventName
                    source     = $sourceName
                    source_id  = $sourceId
                }))

        $Summary['dispatches'] = [int]$Summary['dispatches'] + 1
        $Summary['messages'] += @($message)
        Update-OperatorPollPaneState -PaneContext $paneContext -Properties ([ordered]@{
                task_state    = 'waiting_for_dispatch'
                task_owner    = 'Operator'
                last_event    = 'operator.poll.idle_dispatch_needed'
                last_event_at = (Get-Date).ToString('o')
            })

        Send-OperatorTelegramNotification -ProjectDir $projectDir -SessionName $sessionName `
            -Event 'operator.dispatch_needed' -Message $message -PaneId $paneId `
            -Label ([string]$paneContext['label']) -Role ([string]$paneContext['role'])
        return
    }

    if ($approvalEvent) {
        if ([string]::IsNullOrWhiteSpace($paneId)) {
            $Summary['errors'] = [int]$Summary['errors'] + 1
            $Summary['messages'] += @('approval_waiting event is missing pane_id')
            return
        }

        Approve-OperatorPollPane -PaneId $paneId
        $message = "$($paneContext['label']) ($paneId) を自動承認"

        Write-OperatorPollLog `
            -ProjectDir $projectDir `
            -SessionName $sessionName `
            -EventName 'operator.poll.auto_approved' `
            -Message $message `
            -PaneId $paneId `
            -Data (New-OperatorPollStateData -PaneContext $paneContext -Data ([ordered]@{
                    label     = $paneContext['label']
                    role      = $paneContext['role']
                    source    = $sourceName
                    source_id = $sourceId
                }))

        $Summary['approvals'] = [int]$Summary['approvals'] + 1
        $Summary['messages'] += @($message)
        Update-OperatorPollPaneState -PaneContext $paneContext -Properties ([ordered]@{
                task_owner    = 'Operator'
                last_event    = 'operator.poll.auto_approved'
                last_event_at = (Get-Date).ToString('o')
            })

        Send-OperatorTelegramNotification -ProjectDir $projectDir -SessionName $sessionName `
            -Event 'operator.auto_approved' -Message $message -PaneId $paneId `
            -Label ([string]$paneContext['label']) -Role ([string]$paneContext['role'])
    }
}

function Invoke-OperatorPollCycle {
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

    $manifest = Read-OperatorPollManifest -Path $ManifestPath
    $projectDir = Get-OperatorPollProjectDir -Manifest $manifest -ManifestPath $ManifestPath
    $sessionName = Get-OperatorPollSessionName -Manifest $manifest
    $eventsPath = Get-OperatorPollEventsPath -ProjectDir $projectDir
    $summary = New-OperatorPollCycleSummary -ManifestPath $ManifestPath -EventsPath $eventsPath

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
                $eventRecord = $line | ConvertFrom-WinsmuxJson -AsHashtable -ErrorAction Stop
                $eventRecord['source'] = 'events_jsonl'
                $eventRecords.Add($eventRecord)
            } catch {
                $summary['errors'] = [int]$summary['errors'] + 1
                $summary['messages'] += @("Failed to parse event line $($index + 1): $($_.Exception.Message)")
            }
        }

        $ProcessedLineCount = $lines.Count

        $mailboxRecords = @(
            @(Receive-OperatorPollMailboxMessages -SessionName $sessionName)
            @(Receive-OperatorPollDurableWorkflowMessages -ProjectDir $projectDir -SessionName $sessionName)
        )
        $summary['mailbox_events'] = $mailboxRecords.Count
        foreach ($mailboxRecord in $mailboxRecords) {
            $eventRecords.Add($mailboxRecord)
        }

        foreach ($eventRecord in $eventRecords) {
            $signature = Get-OperatorPollEventSignature -EventRecord $eventRecord
            $pendingPath = [string](Get-OperatorPollValue $eventRecord 'durable_pending_path' '')
            if ([string]::IsNullOrWhiteSpace($pendingPath) -and $ProcessedEventSignatures.Contains($signature)) {
                continue
            }

            $result = Invoke-OperatorPollEventRecord -Manifest $manifest -ManifestPath $ManifestPath -EventRecord $eventRecord -Summary $summary
            if (-not [string]::IsNullOrWhiteSpace($pendingPath)) {
                if ([string]$result -ceq 'workflow_ack_logged') {
                    [IO.File]::Delete($pendingPath)
                    $ProcessedEventSignatures[$signature] = [string](Get-OperatorPollValue -InputObject $eventRecord -Name 'timestamp' -Default ([System.DateTimeOffset]::Now.ToString('o')))
                }
                continue
            }
            $ProcessedEventSignatures[$signature] = [string](Get-OperatorPollValue -InputObject $eventRecord -Name 'timestamp' -Default ([System.DateTimeOffset]::Now.ToString('o')))
        }
    } catch {
        $summary['errors'] = [int]$summary['errors'] + 1
        $errorMessage = "operator-poll cycle failed: $($_.Exception.Message)"
        $summary['messages'] += @($errorMessage)

        Write-OperatorPollLog `
            -ProjectDir $projectDir `
            -SessionName $sessionName `
            -EventName 'operator.poll.error' `
            -Message $errorMessage `
            -Level 'error'
    }

    return [ordered]@{
        Summary                  = $summary
        ProcessedLineCount       = $ProcessedLineCount
        ProcessedEventSignatures = $ProcessedEventSignatures
    }
}

function Get-OperatorPollPreferredReviewPane {
    param([AllowNull()]$Manifest)

    if ($null -eq $Manifest -or $null -eq $Manifest.Panes) {
        return $null
    }

    foreach ($preferredRole in @('Reviewer', 'Worker')) {
        foreach ($label in $Manifest.Panes.Keys) {
            $pane = $Manifest.Panes[$label]
            $role = [string](Get-OperatorPollValue -InputObject $pane -Name 'role' -Default '')
            $status = [string](Get-OperatorPollValue -InputObject $pane -Name 'status' -Default '')
            if ($role -eq $preferredRole -and $status -ne 'bootstrap_invalid') {
                return [ordered]@{
                    PaneId = [string](Get-OperatorPollValue -InputObject $pane -Name 'pane_id' -Default '')
                    Label  = [string]$label
                    Role   = $role
                }
            }
        }
    }

    return $null
}

function Test-OperatorDraftPrCreated {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [string]$HeadSha = ''
    )

    if ([string]::IsNullOrWhiteSpace($HeadSha)) {
        return $false
    }

    $eventsPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'events.jsonl'
    if (-not (Test-Path $eventsPath -PathType Leaf)) {
        return $false
    }

    foreach ($line in @(Get-Content -Path $eventsPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $record = $line | ConvertFrom-WinsmuxJson -AsHashtable -ErrorAction Stop
        } catch {
            continue
        }

        if ([string]$record['event'] -ne 'operator.draft_pr.created') {
            continue
        }

        $recordHeadSha = [string]$record['head_sha']
        $data = $null
        if ($record.Contains('data')) {
            $data = $record['data']
        }
        if ([string]::IsNullOrWhiteSpace($recordHeadSha) -and $null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('head_sha')) {
            $recordHeadSha = [string]$data['head_sha']
        }

        if ([string]::IsNullOrWhiteSpace($recordHeadSha)) {
            continue
        }

        if ($null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('target')) {
            if ([string]$data['target'] -ne 'draft_pr') {
                continue
            }
        }

        if ($recordHeadSha -eq $HeadSha) {
            return $true
        }
    }

    return $false
}

function Write-OperatorDraftPrRequiredEvent {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [string]$HeadSha = ''
    )

    $eventsPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'events.jsonl'
    $record = [ordered]@{
        timestamp   = (Get-Date).ToString('o')
        session     = $SessionName
        event       = 'operator.draft_pr.required'
        message     = 'Draft PR is required before this autonomous run can proceed.'
        label       = ''
        pane_id     = ''
        role        = 'Operator'
        status      = 'blocked_draft_pr_required'
        exit_reason = ''
        head_sha    = $HeadSha
        data        = [ordered]@{
            target                = 'draft_pr'
            reason                = 'draft_pr_required'
            human_merge_required  = $true
            auto_merge_allowed    = $false
            suggested_next_action = 'create a draft PR and request human review'
        }
    }

    Write-WinsmuxTextFile -Path $eventsPath -Content ($record | ConvertTo-Json -Compress -Depth 10) -Append
}

function Invoke-OperatorStateMachine {
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
                $manifest = Read-OperatorPollManifest -Path $ManifestPath
                $reviewPane = Get-OperatorPollPreferredReviewPane -Manifest $manifest
                if ($null -eq $reviewPane -or [string]::IsNullOrWhiteSpace([string]$reviewPane.PaneId)) {
                    Send-OperatorTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                        -Event 'operator.blocked' -Message "Review 可能なペインが見つかりません。" -Branch $branch -HeadSha $headSha
                    $nextState = 'blocked_no_review_target'
                } else {
                    Send-OperatorPollLiteral -PaneId $reviewPane.PaneId -Text 'winsmux review-request'
                    Approve-OperatorPollPane -PaneId $reviewPane.PaneId
                    Send-OperatorTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                        -Event 'operator.review_requested' -Message "$($reviewPane.Label) ($($reviewPane.PaneId)) にレビュー依頼送信。PASS/FAIL 待機中。" `
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
                    $rs = Get-Content $rsp -Raw -Encoding UTF8 | ConvertFrom-WinsmuxJson -AsHashtable -ErrorAction Stop
                    if ($rs.Contains($branch)) {
                        $e = $rs[$branch]
                        $st = [string]$e['status']
                        $sha = [string]$e['head_sha']
                        $rsRequest = $null
                        if ($e.Contains('request')) { $rsRequest = $e['request'] }
                        $rsReviewPaneId = ''
                        if ($null -ne $rsRequest -and $rsRequest -is [System.Collections.IDictionary]) {
                            if ($rsRequest.Contains('target_review_pane_id')) {
                                $rsReviewPaneId = [string]$rsRequest['target_review_pane_id']
                            } elseif ($rsRequest.Contains('target_reviewer_pane_id')) {
                                $rsReviewPaneId = [string]$rsRequest['target_reviewer_pane_id']
                            }
                        }
                        $manifestReviewPaneId = ''
                        $manifest2 = Read-OperatorPollManifest -Path $ManifestPath
                        $reviewPane = Get-OperatorPollPreferredReviewPane -Manifest $manifest2
                        if ($null -ne $reviewPane) {
                            $manifestReviewPaneId = [string]$reviewPane.PaneId
                        }
                        $reviewTargetMatch = [string]::IsNullOrWhiteSpace($rsReviewPaneId) -or $rsReviewPaneId -eq $manifestReviewPaneId
                        if ($st -eq 'PASS' -and $sha -eq $headSha -and $reviewTargetMatch) {
                            Send-OperatorTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                                -Event 'operator.review_passed' -Message "レビュー PASS。" -Branch $branch -HeadSha $headSha
                            $nextState = 'review_passed'
                        } elseif ($st -eq 'PASS' -and $sha -eq $headSha -and -not $reviewTargetMatch) {
                            Write-Warning "TASK-238: review PASS pane_id mismatch: review-state=$rsReviewPaneId manifest=$manifestReviewPaneId"
                        } elseif ($st -eq 'FAIL') {
                            Send-OperatorTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                                -Event 'operator.review_failed' -Message "レビュー FAIL。修正が必要。" -Branch $branch -HeadSha $headSha
                            $nextState = 'blocked_review_failed'
                        }
                    }
                }
            } catch { Write-Warning "TASK-238: review-state read error: $($_.Exception.Message)" }
        }
        'review_passed' {
            $headSha = (git -C $ProjectDir rev-parse HEAD 2>$null)
            if (Test-OperatorDraftPrCreated -ProjectDir $ProjectDir -HeadSha $headSha) {
                $nextCommitReadySha = $headSha
                Send-OperatorTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                    -Event 'operator.commit_ready' -Message "コミット準備完了。" -HeadSha $headSha
                $nextState = 'commit_ready'
            } else {
                Write-OperatorDraftPrRequiredEvent -ProjectDir $ProjectDir -SessionName $SessionName -HeadSha $headSha
                Send-OperatorTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                    -Event 'operator.draft_pr.required' -Message "draft PR 作成と人間の判断が必要です。自動 merge は許可されません。" -HeadSha $headSha
                $nextState = 'blocked_draft_pr_required'
            }
        }
        'commit_ready' {
            $currentSha = (git -C $ProjectDir rev-parse HEAD 2>$null)
            if ($CommitReadySha -and $currentSha -ne $CommitReadySha) {
                Send-OperatorTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                    -Event 'operator.commit_done' -Message "コミット検出。次タスク待機。" -HeadSha $currentSha
                $nextState = 'waiting_for_dispatch'
                $nextCommitReadySha = ''
            }
        }
        'blocked_review_failed' {
            if ([int]$CycleSummary['completions'] -gt 0) { $nextState = 'waiting_for_review' }
        }
        'blocked_no_review_target' {
            try {
                $manifest = Read-OperatorPollManifest -Path $ManifestPath
                if ($null -ne (Get-OperatorPollPreferredReviewPane -Manifest $manifest)) {
                    $nextState = 'waiting_for_review'
                }
            } catch { }
        }
        'blocked_draft_pr_required' {
            $headSha = (git -C $ProjectDir rev-parse HEAD 2>$null)
            if (Test-OperatorDraftPrCreated -ProjectDir $ProjectDir -HeadSha $headSha) {
                $nextCommitReadySha = $headSha
                Send-OperatorTelegramNotification -ProjectDir $ProjectDir -SessionName $SessionName `
                    -Event 'operator.commit_ready' -Message "コミット準備完了。" -HeadSha $headSha
                $nextState = 'commit_ready'
            }
        }
        'blocked_bootstrap_invalid' { }
    }

    if ($nextState -ne $CurrentState) {
        Write-OperatorPollLog -ProjectDir $ProjectDir -SessionName $SessionName `
            -EventName 'operator.state_transition' -Message "State: $CurrentState -> $nextState" `
            -Data ([ordered]@{ from = $CurrentState; to = $nextState })
        try {
            $ep = Join-Path (Join-Path $ProjectDir '.winsmux') 'events.jsonl'
            $rec = [ordered]@{
                timestamp = (Get-Date).ToString('o'); session = $SessionName
                event = 'operator.state_transition'; message = "State: $CurrentState -> $nextState"
                label = ''; pane_id = ''; role = 'Operator'; status = $nextState
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

    $initialManifest = Read-OperatorPollManifest -Path $ManifestPath
    $initialProjectDir = Get-OperatorPollProjectDir -Manifest $initialManifest -ManifestPath $ManifestPath
    $eventsPath = Get-OperatorPollEventsPath -ProjectDir $initialProjectDir
    $processedLineCount = 0
    $processedEventSignatures = [ordered]@{}

    if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
        $processedLineCount = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8).Count
    }

    Send-OperatorTelegramNotification -ProjectDir $initialProjectDir `
        -SessionName (Get-OperatorPollSessionName -Manifest $initialManifest) `
        -Event 'operator.started' -Message "Operator Poll 開始。間隔: ${Interval}秒"

    $operatorState = 'starting'
    $commitReadySha = ''

    while ($true) {
        $cycleResult = Invoke-OperatorPollCycle `
            -ManifestPath $ManifestPath `
            -ProcessedLineCount $processedLineCount `
            -ProcessedEventSignatures $processedEventSignatures

        $processedLineCount = [int]$cycleResult['ProcessedLineCount']
        $processedEventSignatures = $cycleResult['ProcessedEventSignatures']
        $smResult = Invoke-OperatorStateMachine `
            -CurrentState $operatorState `
            -CycleSummary ($cycleResult['Summary']) `
            -ProjectDir $initialProjectDir `
            -SessionName (Get-OperatorPollSessionName -Manifest (Read-OperatorPollManifest -Path $ManifestPath)) `
            -ManifestPath $ManifestPath `
            -CommitReadySha $commitReadySha

        $operatorState = [string]$smResult['State']
        $commitReadySha = [string]$smResult['CommitReadySha']

        $summaryOutput = $cycleResult['Summary']
        $summaryOutput['operator_state'] = $operatorState
        Write-Output ($summaryOutput | ConvertTo-Json -Compress -Depth 10)
        Start-Sleep -Seconds $Interval
    }
}
