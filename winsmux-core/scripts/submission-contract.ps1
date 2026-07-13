$ErrorActionPreference = 'Stop'

$script:WinsmuxSubmissionProtocolVersion = 1
$script:WinsmuxSubmissionStatuses = @('accepted', 'rejected', 'unsupported', 'unavailable')
$script:WinsmuxSubmissionKinds = @('task', 'review')
$script:WinsmuxSubmissionBackends = @('local', 'codex', 'api_llm', 'antigravity', 'colab_cli', 'noop')
$script:WinsmuxSubmissionBridgeScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\winsmux-core.ps1'))

function ConvertTo-WinsmuxSubmissionDiagnostic {
    param([AllowEmptyString()][string]$Text = '')

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    $safe = $Text -replace '(?i)[A-Z]:\\Users\\[^,;\r\n]+', '<local-path>'
    $safe = $safe -replace '(?i)\\\\[^\\\s]+\\[^,;\r\n]+', '<network-path>'
    return $safe.Trim()
}

function Get-WinsmuxSubmissionValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }
    return $Default
}

function New-WinsmuxSubmissionReceipt {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidateSet('accepted', 'rejected', 'unsupported', 'unavailable')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Backend,
        [Parameter(Mandatory = $true)][string]$SubmissionId,
        [AllowEmptyString()][string]$ReasonCode = '',
        [AllowEmptyString()][string]$Diagnostic = '',
        [AllowNull()]$Target = $null,
        [AllowNull()]$Routing = $null,
        [AllowNull()]$Acknowledgement = $null
    )

    return [ordered]@{
        protocol_version = $script:WinsmuxSubmissionProtocolVersion
        submission_id    = $SubmissionId
        kind             = $Kind
        status           = $Status
        backend          = $Backend.Trim().ToLowerInvariant()
        reason_code      = $ReasonCode
        diagnostic       = ConvertTo-WinsmuxSubmissionDiagnostic -Text $Diagnostic
        target           = $Target
        routing          = $Routing
        acknowledgement  = $Acknowledgement
    }
}

function Test-WinsmuxSubmissionReceipt {
    param([AllowNull()]$Receipt)

    if ($null -eq $Receipt) {
        return $false
    }
    $version = Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'protocol_version' -Default $null
    $status = [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'status' -Default '')
    $kind = [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'kind' -Default '')
    $backend = [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'backend' -Default '')
    $submissionId = [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'submission_id' -Default '')

    $parsedVersion = 0
    $versionIsInteger = [int]::TryParse(([string]$version), [ref]$parsedVersion)
    return (
        $versionIsInteger -and
        $parsedVersion -eq $script:WinsmuxSubmissionProtocolVersion -and
        $status -cin $script:WinsmuxSubmissionStatuses -and
        $kind -cin $script:WinsmuxSubmissionKinds -and
        $backend -cin $script:WinsmuxSubmissionBackends -and
        -not [string]::IsNullOrWhiteSpace($submissionId)
    )
}

function ConvertTo-WinsmuxSubmissionReceiptJson {
    param([Parameter(Mandatory = $true)]$Receipt)

    if (-not (Test-WinsmuxSubmissionReceipt -Receipt $Receipt)) {
        throw 'submission receipt is malformed or uses an unknown protocol version, status, kind, or backend'
    }
    return ($Receipt | ConvertTo-Json -Depth 12 -Compress)
}

function New-WinsmuxRouterRefusalReceipt {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)]$Route,
        [Parameter(Mandatory = $true)][string]$SubmissionId
    )

    $matchedKeywords = @((Get-WinsmuxSubmissionValue -InputObject $Route -Name 'MatchedKeywords' -Default @()))
    $expectedOwner = [string](Get-WinsmuxSubmissionValue -InputObject $Route -Name 'SelectedRole' -Default 'Operator')
    if ([string]::IsNullOrWhiteSpace($expectedOwner)) {
        $expectedOwner = 'Operator'
    }
    $matchedRule = if ($matchedKeywords.Count -gt 0) { $matchedKeywords -join ',' } else { 'no_delegable_target' }

    return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend local -SubmissionId $SubmissionId `
        -ReasonCode 'router_operator_owned' -Diagnostic ([string](Get-WinsmuxSubmissionValue -InputObject $Route -Name 'Reason' -Default 'router retained ownership')) `
        -Routing ([ordered]@{
            matched_rule   = $matchedRule
            expected_owner = $expectedOwner
            next_shape     = 'Provide a delegable implementation, review, research, or verification packet for an available managed worker.'
        })
}

function New-WinsmuxSubmissionPacket {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$SubmissionId,
        [Parameter(Mandatory = $true)][string]$TargetLabel
    )

    if ($SubmissionId -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
        throw 'submission id contains unsupported characters'
    }
    $relativePath = Join-Path (Join-Path '.winsmux' 'submissions') ($SubmissionId + '.json')
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectDir $relativePath))
    $directory = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $packet = [ordered]@{
        protocol_version = 1
        submission_id    = $SubmissionId
        kind             = $Kind
        target           = $TargetLabel
        content          = $Content
    }
    [System.IO.File]::WriteAllText($fullPath, ($packet | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    return [PSCustomObject]@{ FullPath = $fullPath; RelativePath = $relativePath }
}

function Get-WinsmuxSubmissionRunResult {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $runPath = Join-Path (Join-Path (Join-Path (Join-Path $ProjectDir '.winsmux') 'worker-runs') $SlotId) (Join-Path $RunId 'run.json')
    $attempts = 60
    if ($env:WINSMUX_SUBMISSION_POLL_ATTEMPTS -match '^\d+$') {
        $attempts = [int]$env:WINSMUX_SUBMISSION_POLL_ATTEMPTS
    }
    for ($attempt = 0; $attempt -le $attempts; $attempt++) {
        if (Test-Path -LiteralPath $runPath -PathType Leaf) {
            try {
                return (Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16)
            } catch {
                return [ordered]@{ status = 'failed'; reason = 'runner_receipt_malformed'; exit_code = 1 }
            }
        }
        if ($attempt -lt $attempts) {
            Start-Sleep -Milliseconds 500
        }
    }
    return [ordered]@{ status = 'failed'; reason = 'runner_acknowledgement_missing'; exit_code = 1 }
}

function Invoke-WinsmuxSubmissionCliRun {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)][string]$PacketPath,
        [Parameter(Mandatory = $true)][string]$SubmissionId,
        [Parameter(Mandatory = $true)][string]$Backend,
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind
    )

    $workerArguments = @('workers', 'exec', $SlotId)
    if ([string]::Equals($Backend, 'colab_cli', [System.StringComparison]::OrdinalIgnoreCase)) {
        $workerScript = if ($Kind -eq 'review') { 'workers/colab/critic_worker.py' } else { 'workers/colab/impl_worker.py' }
        $workerArguments += @('--script', $workerScript, '--task-json', $PacketPath)
    } else {
        $workerArguments += @('--task-json', $PacketPath)
    }
    $workerArguments += @('--task-id', $SubmissionId, '--run-id', $SubmissionId, '--json', '--project-dir', $ProjectDir)
    $output = & pwsh -NoProfile -File $script:WinsmuxSubmissionBridgeScript @workerArguments 2>&1
    $exitCode = $LASTEXITCODE
    $jsonLine = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
    if ($jsonLine.Count -lt 1) {
        return [ordered]@{ status = 'unavailable'; reason = 'cli_command_missing'; exit_code = if ($exitCode) { $exitCode } else { 1 } }
    }
    try {
        $result = $jsonLine[0] | ConvertFrom-Json -Depth 16
    } catch {
        return [ordered]@{ status = 'unavailable'; reason = 'cli_receipt_malformed'; exit_code = 1 }
    }
    return $result
}

function Invoke-WinsmuxSubmissionAdapter {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$ManifestEntry,
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Content,
        [string]$SubmissionId = ('submission-' + [guid]::NewGuid().ToString('N')),
        [scriptblock]$SendAction,
        [scriptblock]$CaptureAction,
        [scriptblock]$RunResultAction,
        [scriptblock]$CliRunAction
    )

    $label = [string](Get-WinsmuxSubmissionValue -InputObject $ManifestEntry -Name 'Label' -Default '')
    $paneId = [string](Get-WinsmuxSubmissionValue -InputObject $ManifestEntry -Name 'PaneId' -Default '')
    $role = [string](Get-WinsmuxSubmissionValue -InputObject $ManifestEntry -Name 'Role' -Default '')
    $backend = [string](Get-WinsmuxSubmissionValue -InputObject $ManifestEntry -Name 'WorkerBackend' -Default 'local')
    $backend = $backend.Trim().ToLowerInvariant()
    $target = [ordered]@{ label = $label; pane_id = $paneId; role = $role }

    if ($backend -notin $script:WinsmuxSubmissionBackends) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unsupported -Backend noop -SubmissionId $SubmissionId -ReasonCode 'backend_unsupported' -Diagnostic "Unsupported worker backend '$backend'." -Target $target
    }
    if ($backend -eq 'noop') {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unsupported -Backend noop -SubmissionId $SubmissionId -ReasonCode 'backend_unsupported' -Diagnostic 'The noop backend cannot accept submissions.' -Target $target
    }

    if ($backend -in @('local', 'codex')) {
        if ([string]::IsNullOrWhiteSpace($paneId)) {
            return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'pane_unavailable' -Diagnostic 'The target pane id is missing.' -Target $target
        }
        $marker = "[winsmux-submission-accepted:$SubmissionId]"
        $commandText = "Before doing any other work, print exactly $marker on its own line to acknowledge this $Kind submission.`n`n$Content"
        try {
            if ($null -ne $SendAction) {
                & $SendAction $paneId $commandText
            } else {
                Send-TextToPane -PaneId $paneId -CommandText $commandText
            }
        } catch {
            return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'pane_send_failed' -Diagnostic $_.Exception.Message -Target $target
        }

        $attempts = 10
        if ($env:WINSMUX_SUBMISSION_POLL_ATTEMPTS -match '^\d+$') {
            $attempts = [int]$env:WINSMUX_SUBMISSION_POLL_ATTEMPTS
        }
        for ($attempt = 0; $attempt -le $attempts; $attempt++) {
            $snapshot = if ($null -ne $CaptureAction) { & $CaptureAction $paneId } else { Get-PaneSnapshotText -PaneId $paneId -Lines 200 }
            if ([string]$snapshot -match [regex]::Escape($marker)) {
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status accepted -Backend $backend -SubmissionId $SubmissionId -Target $target `
                    -Acknowledgement ([ordered]@{ type = 'backend_marker'; marker = $marker })
            }
            if ($attempt -lt $attempts) {
                Start-Sleep -Milliseconds 300
            }
        }
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'backend_acknowledgement_missing' -Diagnostic 'Text delivery was not followed by the required backend acknowledgement marker.' -Target $target
    }

    $packet = New-WinsmuxSubmissionPacket -ProjectDir $ProjectDir -Kind $Kind -Content $Content -SubmissionId $SubmissionId -TargetLabel $label
    if ($backend -eq 'api_llm') {
        if ([string]::IsNullOrWhiteSpace($paneId)) {
            return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'pane_unavailable' -Diagnostic 'The api_llm packet REPL pane id is missing.' -Target $target
        }
        $execCommand = "exec $($packet.RelativePath) $SubmissionId $SubmissionId"
        try {
            if ($null -ne $SendAction) { & $SendAction $paneId $execCommand } else { Send-TextToPane -PaneId $paneId -CommandText $execCommand }
        } catch {
            return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'packet_repl_unavailable' -Diagnostic $_.Exception.Message -Target $target
        }
        $runner = if ($null -ne $RunResultAction) { & $RunResultAction $ProjectDir $label $SubmissionId } else { Get-WinsmuxSubmissionRunResult -ProjectDir $ProjectDir -SlotId $label -RunId $SubmissionId }
    } else {
        $runner = if ($null -ne $CliRunAction) { & $CliRunAction $ProjectDir $label $packet.RelativePath $SubmissionId $backend $Kind } else { Invoke-WinsmuxSubmissionCliRun -ProjectDir $ProjectDir -SlotId $label -PacketPath $packet.RelativePath -SubmissionId $SubmissionId -Backend $backend -Kind $Kind }
    }

    $runnerStatus = [string](Get-WinsmuxSubmissionValue -InputObject $runner -Name 'status' -Default '')
    $runnerReason = [string](Get-WinsmuxSubmissionValue -InputObject $runner -Name 'reason' -Default '')
    $runnerExitCode = [int](Get-WinsmuxSubmissionValue -InputObject $runner -Name 'exit_code' -Default 1)
    if ($runnerStatus -in @('succeeded', 'started', 'running') -and $runnerExitCode -eq 0) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status accepted -Backend $backend -SubmissionId $SubmissionId -Target $target `
            -Acknowledgement ([ordered]@{ type = 'run_receipt'; run_id = $SubmissionId; runner_status = $runnerStatus })
    }
    if ($runnerStatus -eq 'unavailable' -or $runnerReason -match '(missing|unavailable|unconfigured)') {
        if ([string]::IsNullOrWhiteSpace($runnerReason)) { $runnerReason = 'backend_unavailable' }
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode $runnerReason -Diagnostic 'The backend runner did not start.' -Target $target
    }
    if ([string]::IsNullOrWhiteSpace($runnerReason)) { $runnerReason = 'runner_rejected_submission' }
    return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId -ReasonCode $runnerReason -Diagnostic 'The backend runner refused or failed the submission.' -Target $target
}
