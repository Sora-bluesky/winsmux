$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'json-compat.ps1')

$script:WinsmuxSubmissionProtocolVersion = 1
$script:WinsmuxSubmissionStatuses = @('accepted', 'rejected', 'unsupported', 'unavailable')
$script:WinsmuxSubmissionKinds = @('task', 'review')
$script:WinsmuxSubmissionBackends = @('local', 'codex', 'api_llm', 'antigravity', 'noop')
$script:WinsmuxSubmissionEvidenceTypes = @('backend_run_record')
$script:WinsmuxSubmissionRunStatuses = @('started', 'running', 'succeeded')
$script:WinsmuxSubmissionBridgeScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\winsmux-core.ps1'))
$script:WinsmuxSubmissionAckFrameLimit = 16384
$script:WinsmuxSubmissionAckTimeoutMilliseconds = 30000
function ConvertTo-WinsmuxSubmissionDiagnostic {
    param([AllowEmptyString()][string]$Text = '')

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    if (-not (Get-Command ConvertTo-WorkersSafeLogText -ErrorAction SilentlyContinue)) {
        return '[DIAGNOSTIC_REDACTED]'
    }
    return (ConvertTo-WorkersSafeLogText -Text $Text).Trim()
}

function Get-WinsmuxSubmissionValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Get-WinsmuxSubmissionRawValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Default = $null
    )

    if ($null -eq $InputObject) { return ,$Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return ,$InputObject[$Name] }
        return ,$Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return ,$Default
}

function Test-WinsmuxSubmissionIdentifier {
    param([AllowEmptyString()][string]$Value = '')
    return $Value -match '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$'
}

function Test-WinsmuxSubmissionInteger {
    param([AllowNull()]$Value)

    return ($Value -is [byte]) -or ($Value -is [sbyte]) -or
        ($Value -is [int16]) -or ($Value -is [uint16]) -or
        ($Value -is [int32]) -or ($Value -is [uint32]) -or
        ($Value -is [int64]) -or ($Value -is [uint64])
}

function Test-WinsmuxSubmissionStringArray {
    param([AllowNull()]$Value)

    if ($null -eq $Value -or $Value -isnot [System.Array]) { return $false }
    foreach ($item in $Value) {
        if ($item -isnot [string]) { return $false }
    }
    return $true
}

function ConvertTo-WinsmuxSubmissionStringArray {
    param([AllowNull()]$Value)

    return @(
        @($Value) |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
}

function Get-WinsmuxSubmissionRequestDigest {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Request)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Request))
        return ([System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
    } finally {
        $algorithm.Dispose()
    }
}

function New-WinsmuxSubmissionPacketData {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)]$Content,
        [Parameter(Mandatory = $true)][string]$SubmissionId,
        [Parameter(Mandatory = $true)][string]$TargetLabel,
        [AllowEmptyString()][string]$TaskId = ''
    )

    if (-not (Test-WinsmuxSubmissionIdentifier -Value $SubmissionId)) {
        throw 'submission id contains unsupported characters'
    }
    if ([string]::IsNullOrWhiteSpace($TaskId)) { $TaskId = $SubmissionId }
    if (-not (Test-WinsmuxSubmissionIdentifier -Value $TaskId)) {
        throw 'task id contains unsupported characters'
    }
    $title = ''
    $request = ''
    $files = @()
    $tests = @()
    $constraints = @()
    $branch = ''
    $headSha = ''
    if ($Content -is [System.Collections.IDictionary] -or $null -ne $Content.PSObject.Properties['request']) {
        $title = [string](Get-WinsmuxSubmissionValue -InputObject $Content -Name 'title' -Default '')
        $request = [string](Get-WinsmuxSubmissionValue -InputObject $Content -Name 'request' -Default '')
        $files = @(ConvertTo-WinsmuxSubmissionStringArray -Value (Get-WinsmuxSubmissionValue -InputObject $Content -Name 'files' -Default @()))
        $tests = @(ConvertTo-WinsmuxSubmissionStringArray -Value (Get-WinsmuxSubmissionValue -InputObject $Content -Name 'tests' -Default @()))
        $constraints = @(ConvertTo-WinsmuxSubmissionStringArray -Value (Get-WinsmuxSubmissionValue -InputObject $Content -Name 'constraints' -Default @()))
        $branch = [string](Get-WinsmuxSubmissionValue -InputObject $Content -Name 'branch' -Default '')
        $headSha = [string](Get-WinsmuxSubmissionValue -InputObject $Content -Name 'head_sha' -Default '')
    } else {
        $request = ([string]$Content).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = if ($request.Length -le 120) { $request } else { $request.Substring(0, 120) }
    }
    if ([string]::IsNullOrWhiteSpace($request)) {
        $request = $title
    }
    $requestDigest = Get-WinsmuxSubmissionRequestDigest -Request $request

    return [ordered]@{
        protocol_version = 1
        submission_id    = $SubmissionId
        run_id           = $SubmissionId
        task_id          = $TaskId
        kind             = $Kind
        target           = $TargetLabel
        title            = $title
        request          = $request
        request_digest   = $requestDigest
        files            = @($files)
        tests            = @($tests)
        constraints      = @($constraints)
        branch           = $branch
        head_sha         = $headSha
    }
}

function Test-WinsmuxSubmissionPacket {
    param([AllowNull()]$Packet)

    if ($null -eq $Packet) { return $false }
    $version = Get-WinsmuxSubmissionRawValue -InputObject $Packet -Name 'protocol_version' -Default $null
    if (-not (Test-WinsmuxSubmissionInteger -Value $version)) { return $false }
    $submissionIdValue = Get-WinsmuxSubmissionRawValue -InputObject $Packet -Name 'submission_id' -Default $null
    $runIdValue = Get-WinsmuxSubmissionRawValue -InputObject $Packet -Name 'run_id' -Default $null
    $taskIdValue = Get-WinsmuxSubmissionRawValue -InputObject $Packet -Name 'task_id' -Default $null
    $kindValue = Get-WinsmuxSubmissionRawValue -InputObject $Packet -Name 'kind' -Default $null
    $targetValue = Get-WinsmuxSubmissionRawValue -InputObject $Packet -Name 'target' -Default $null
    $titleValue = Get-WinsmuxSubmissionRawValue -InputObject $Packet -Name 'title' -Default $null
    $requestValue = Get-WinsmuxSubmissionRawValue -InputObject $Packet -Name 'request' -Default $null
    $requestDigestValue = Get-WinsmuxSubmissionRawValue -InputObject $Packet -Name 'request_digest' -Default $null
    $branchValue = Get-WinsmuxSubmissionRawValue -InputObject $Packet -Name 'branch' -Default $null
    $headShaValue = Get-WinsmuxSubmissionRawValue -InputObject $Packet -Name 'head_sha' -Default $null
    $submissionId = if ($submissionIdValue -is [string]) { $submissionIdValue } else { '' }
    $runId = if ($runIdValue -is [string]) { $runIdValue } else { '' }
    $taskId = if ($taskIdValue -is [string]) { $taskIdValue } else { '' }
    $kind = if ($kindValue -is [string]) { $kindValue } else { '' }
    if ([int64]$version -ne 1) { return $false }
    if (-not (Test-WinsmuxSubmissionIdentifier -Value $submissionId)) { return $false }
    if ($runId -cne $submissionId) { return $false }
    if (-not (Test-WinsmuxSubmissionIdentifier -Value $taskId)) { return $false }
    if ($kind -cnotin $script:WinsmuxSubmissionKinds) { return $false }
    if ($targetValue -isnot [string]) { return $false }
    if (-not (Test-WinsmuxSubmissionIdentifier -Value $targetValue)) { return $false }
    if ($titleValue -isnot [string]) { return $false }
    if ([string]::IsNullOrWhiteSpace($titleValue)) { return $false }
    if ($requestValue -isnot [string]) { return $false }
    if ([string]::IsNullOrWhiteSpace($requestValue)) { return $false }
    if ($requestDigestValue -isnot [string] -or $requestDigestValue -cnotmatch '^[0-9a-f]{64}$') { return $false }
    if ($requestDigestValue -cne (Get-WinsmuxSubmissionRequestDigest -Request $requestValue)) { return $false }
    foreach ($fieldName in @('files', 'tests', 'constraints')) {
        $fieldValue = Get-WinsmuxSubmissionRawValue -InputObject $Packet -Name $fieldName -Default $null
        if (-not (Test-WinsmuxSubmissionStringArray -Value $fieldValue)) { return $false }
    }
    if ($branchValue -isnot [string]) { return $false }
    if ($headShaValue -isnot [string]) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($headShaValue) -and $headShaValue -notmatch '^[0-9a-fA-F]{40}$') { return $false }
    return $true
}

function Resolve-WinsmuxSubmissionPacketPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SubmissionId
    )

    if (-not (Test-WinsmuxSubmissionIdentifier -Value $SubmissionId)) {
        throw 'submission packet path contains an unsupported submission id'
    }
    $relativePath = Join-Path (Join-Path '.winsmux' 'submissions') ($SubmissionId + '.json')
    return [PSCustomObject]@{
        RelativePath = $relativePath
        FullPath     = [System.IO.Path]::GetFullPath((Join-Path $ProjectDir $relativePath))
    }
}

function New-WinsmuxSubmissionPacket {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)]$Content,
        [Parameter(Mandatory = $true)][string]$SubmissionId,
        [Parameter(Mandatory = $true)][string]$TargetLabel,
        [AllowEmptyString()][string]$TaskId = ''
    )

    $packet = New-WinsmuxSubmissionPacketData -Kind $Kind -Content $Content -SubmissionId $SubmissionId -TargetLabel $TargetLabel -TaskId $TaskId
    $packetPath = Resolve-WinsmuxSubmissionPacketPath -ProjectDir $ProjectDir -SubmissionId $SubmissionId
    $relativePath = [string]$packetPath.RelativePath
    $fullPath = [string]$packetPath.FullPath
    $directory = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($packet | ConvertTo-Json -Depth 8))
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return [PSCustomObject]@{ FullPath = $fullPath; RelativePath = $relativePath; Packet = $packet }
}

function Read-WinsmuxSubmissionPacket {
    param([Parameter(Mandatory = $true)][string]$Path)

    $packet = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-WinsmuxJson -Depth 16
    if (-not (Test-WinsmuxSubmissionPacket -Packet $packet)) {
        throw 'submission packet is malformed or uses an unknown protocol version, kind, or id'
    }
    return $packet
}

function Read-WinsmuxSubmissionPacketIfPresent {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-WinsmuxJson -Depth 16
    $hasProtocol = $null -ne $candidate.PSObject.Properties['protocol_version']
    $hasSubmissionId = $null -ne $candidate.PSObject.Properties['submission_id']
    if (-not $hasProtocol -and -not $hasSubmissionId) { return $null }
    if (-not (Test-WinsmuxSubmissionPacket -Packet $candidate)) {
        throw 'submission packet is malformed or uses an unknown protocol version, kind, or id'
    }
    return $candidate
}

function New-WinsmuxSubmissionRunRecord {
    param(
        [Parameter(Mandatory = $true)][string]$SubmissionId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$TaskTitle,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)][ValidateSet('local', 'codex', 'api_llm', 'antigravity')][string]$Backend,
        [Parameter(Mandatory = $true)][ValidateSet('started', 'running', 'succeeded', 'failed')][string]$Status,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$RequestDigest,
        [switch]$RequestConsumed,
        [AllowEmptyString()][string]$Reason = '',
        [AllowEmptyString()][string]$TaskId = ''
    )

    if ([string]::IsNullOrWhiteSpace($TaskId)) { $TaskId = $SubmissionId }
    if (-not (Test-WinsmuxSubmissionIdentifier -Value $TaskId)) {
        throw 'task id contains unsupported characters'
    }
    return [ordered]@{
        protocol_version = 1
        type             = 'backend_run_record'
        submission_id    = $SubmissionId
        run_id           = $RunId
        kind             = $Kind
        task_id          = $TaskId
        task_title       = $TaskTitle
        worker_kind      = if ($Kind -eq 'review') { 'critic' } else { 'implementation' }
        slot_id          = $SlotId
        backend          = $Backend
        status           = $Status
        backend_owned    = $true
        request_consumed = [bool]$RequestConsumed
        request_digest   = $RequestDigest
        reason           = $Reason
        exit_code        = if ($Status -eq 'failed') { 1 } else { 0 }
        generated_at     = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Test-WinsmuxSubmissionRunRecord {
    param(
        [AllowNull()]$Record,
        [Parameter(Mandatory = $true)][string]$SubmissionId,
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Backend,
        [string]$ExpectedSlotId = '',
        [string]$ExpectedRequestDigest = '',
        [string]$ExpectedTaskId = ''
    )

    if ($null -eq $Record) { return $false }
    $version = Get-WinsmuxSubmissionRawValue -InputObject $Record -Name 'protocol_version' -Default $null
    if (-not (Test-WinsmuxSubmissionInteger -Value $version)) { return $false }
    $expectedWorkerKind = if ($Kind -eq 'review') { 'critic' } else { 'implementation' }
    $taskTitle = Get-WinsmuxSubmissionValue -InputObject $Record -Name 'task_title' -Default $null
    $workerKind = Get-WinsmuxSubmissionValue -InputObject $Record -Name 'worker_kind' -Default $null
    $recordSlotId = Get-WinsmuxSubmissionValue -InputObject $Record -Name 'slot_id' -Default $null
    $backendOwned = Get-WinsmuxSubmissionValue -InputObject $Record -Name 'backend_owned' -Default $null
    $requestConsumed = Get-WinsmuxSubmissionValue -InputObject $Record -Name 'request_consumed' -Default $null
    $requestDigest = Get-WinsmuxSubmissionValue -InputObject $Record -Name 'request_digest' -Default $null
    $exitCode = Get-WinsmuxSubmissionRawValue -InputObject $Record -Name 'exit_code' -Default $null
    return (
        [int64]$version -eq 1 -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Record -Name 'type' -Default '') -cin $script:WinsmuxSubmissionEvidenceTypes -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Record -Name 'submission_id' -Default '') -ceq $SubmissionId -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Record -Name 'run_id' -Default '') -ceq $SubmissionId -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Record -Name 'kind' -Default '') -ceq $Kind -and
        (Test-WinsmuxSubmissionIdentifier -Value ([string](Get-WinsmuxSubmissionValue -InputObject $Record -Name 'task_id' -Default ''))) -and
        ([string]::IsNullOrWhiteSpace($ExpectedTaskId) -or [string](Get-WinsmuxSubmissionValue -InputObject $Record -Name 'task_id' -Default '') -ceq $ExpectedTaskId) -and
        ($taskTitle -is [string]) -and (-not [string]::IsNullOrWhiteSpace($taskTitle)) -and
        ($workerKind -is [string]) -and $workerKind -ceq $expectedWorkerKind -and
        ($recordSlotId -is [string]) -and (Test-WinsmuxSubmissionIdentifier -Value $recordSlotId) -and
        ([string]::IsNullOrWhiteSpace($ExpectedSlotId) -or $recordSlotId -ceq $ExpectedSlotId) -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Record -Name 'backend' -Default '') -ceq $Backend -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Record -Name 'status' -Default '') -cin $script:WinsmuxSubmissionRunStatuses -and
        ($backendOwned -is [bool]) -and $backendOwned -eq $true -and
        ($requestConsumed -is [bool]) -and $requestConsumed -eq $true -and
        ($requestDigest -is [string]) -and $requestDigest -cmatch '^[0-9a-f]{64}$' -and
        ([string]::IsNullOrWhiteSpace($ExpectedRequestDigest) -or $requestDigest -ceq $ExpectedRequestDigest) -and
        (Test-WinsmuxSubmissionInteger -Value $exitCode) -and [int64]$exitCode -eq 0
    )
}

function ConvertTo-WinsmuxPublicAcknowledgement {
    param([AllowNull()]$Acknowledgement)

    if ($null -eq $Acknowledgement) { return $null }
    return [ordered]@{
        type             = [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'type' -Default '')
        protocol_version = Get-WinsmuxSubmissionRawValue -InputObject $Acknowledgement -Name 'protocol_version' -Default $null
        status           = [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'status' -Default '')
        submission_id    = [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'submission_id' -Default '')
        run_id           = [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'run_id' -Default '')
        task_id          = [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'task_id' -Default '')
        kind             = [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'kind' -Default '')
        backend          = [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'backend' -Default '')
        slot_id          = [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'slot_id' -Default '')
        worker_kind      = [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'worker_kind' -Default '')
        request_digest   = [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'request_digest' -Default '')
    }
}

function Test-WinsmuxPublicAcknowledgement {
    param(
        [AllowNull()]$Acknowledgement,
        [Parameter(Mandatory = $true)][string]$SubmissionId,
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Backend,
        [Parameter(Mandatory = $true)][string]$ExpectedSlotId
    )

    if ($null -eq $Acknowledgement) { return $false }
    $allowedNames = @('type', 'protocol_version', 'status', 'submission_id', 'run_id', 'task_id', 'kind', 'backend', 'slot_id', 'worker_kind', 'request_digest')
    $actualNames = if ($Acknowledgement -is [System.Collections.IDictionary]) {
        @($Acknowledgement.Keys | ForEach-Object { [string]$_ })
    } else {
        @($Acknowledgement.PSObject.Properties.Name)
    }
    if ($actualNames.Count -ne $allowedNames.Count -or @($actualNames | Where-Object { $_ -cnotin $allowedNames }).Count -gt 0) {
        return $false
    }
    $version = Get-WinsmuxSubmissionRawValue -InputObject $Acknowledgement -Name 'protocol_version' -Default $null
    $workerKind = if ($Kind -eq 'review') { 'critic' } else { 'implementation' }
    return (
        (Test-WinsmuxSubmissionInteger -Value $version) -and [int64]$version -eq 1 -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'type' -Default '') -ceq 'backend_run_record' -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'status' -Default '') -cin $script:WinsmuxSubmissionRunStatuses -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'submission_id' -Default '') -ceq $SubmissionId -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'run_id' -Default '') -ceq $SubmissionId -and
        (Test-WinsmuxSubmissionIdentifier -Value ([string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'task_id' -Default ''))) -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'kind' -Default '') -ceq $Kind -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'backend' -Default '') -ceq $Backend -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'slot_id' -Default '') -ceq $ExpectedSlotId -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'worker_kind' -Default '') -ceq $workerKind -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Acknowledgement -Name 'request_digest' -Default '') -cmatch '^[0-9a-f]{64}$'
    )
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
        protocol_version = 1
        submission_id    = $SubmissionId
        kind             = $Kind
        status           = $Status
        backend          = $Backend.Trim().ToLowerInvariant()
        reason_code      = $ReasonCode
        diagnostic       = ConvertTo-WinsmuxSubmissionDiagnostic -Text $Diagnostic
        target           = $Target
        routing          = $Routing
        acknowledgement  = ConvertTo-WinsmuxPublicAcknowledgement -Acknowledgement $Acknowledgement
    }
}

function ConvertFrom-WinsmuxRuntimeRefusal {
    param([Parameter(Mandatory = $true)]$Failure)

    $failureException = Get-WinsmuxSubmissionValue -InputObject $Failure -Name 'Exception' -Default $null
    $message = if ($Failure -is [System.Exception]) {
        [string]$Failure.Message
    } elseif ($failureException -is [System.Exception]) {
        [string]$failureException.Message
    } else {
        [string]$Failure
    }
    $reasonCode = 'deferred_start_failed'
    $diagnostic = $message
    if ($message -match '^runtime dispatch refused \(([a-z][a-z0-9_]*)\):\s*(.*)$') {
        $reasonCode = [string]$Matches[1]
        $diagnostic = [string]$Matches[2]
    }
    return [PSCustomObject][ordered]@{
        reason_code = $reasonCode
        diagnostic  = $diagnostic
    }
}

function New-WinsmuxDeferredStartFailureReceipt {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$SubmissionId,
        [AllowEmptyString()][string]$PaneId = '',
        [string]$Backend = 'noop',
        [AllowNull()]$Target = $null,
        [Parameter(Mandatory = $true)]$Failure
    )

    $normalizedBackend = $Backend.Trim().ToLowerInvariant()
    if ($normalizedBackend -notin @('local', 'codex', 'api_llm', 'antigravity', 'noop')) {
        $normalizedBackend = 'noop'
    }
    if ($null -eq $Target) {
        $Target = [ordered]@{ label = ''; pane_id = $PaneId; role = '' }
    }
    $refusal = ConvertFrom-WinsmuxRuntimeRefusal -Failure $Failure
    return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $normalizedBackend `
        -SubmissionId $SubmissionId -ReasonCode ([string]$refusal.reason_code) `
        -Diagnostic ([string]$refusal.diagnostic) -Target $Target
}

function Test-WinsmuxSubmissionReceipt {
    param([AllowNull()]$Receipt)

    if ($null -eq $Receipt) { return $false }
    $allowedNames = @('protocol_version', 'submission_id', 'kind', 'status', 'backend', 'reason_code', 'diagnostic', 'target', 'routing', 'acknowledgement')
    $actualNames = @(
        if ($Receipt -is [System.Collections.IDictionary]) {
            $Receipt.Keys | ForEach-Object { [string]$_ }
        } else {
            $Receipt.PSObject.Properties.Name
        }
    )
    if ($actualNames.Count -ne $allowedNames.Count -or @($actualNames | Where-Object { $_ -cnotin $allowedNames }).Count -gt 0) {
        return $false
    }
    $version = Get-WinsmuxSubmissionRawValue -InputObject $Receipt -Name 'protocol_version' -Default $null
    if (-not (Test-WinsmuxSubmissionInteger -Value $version)) { return $false }
    $status = [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'status' -Default '')
    $kind = [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'kind' -Default '')
    $backend = [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'backend' -Default '')
    $submissionId = [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'submission_id' -Default '')
    $reasonCodeValue = Get-WinsmuxSubmissionRawValue -InputObject $Receipt -Name 'reason_code' -Default $null
    $diagnosticValue = Get-WinsmuxSubmissionRawValue -InputObject $Receipt -Name 'diagnostic' -Default $null
    $acknowledgement = Get-WinsmuxSubmissionRawValue -InputObject $Receipt -Name 'acknowledgement' -Default $null
    if (
        [int64]$version -ne 1 -or
        $status -cnotin $script:WinsmuxSubmissionStatuses -or
        $kind -cnotin $script:WinsmuxSubmissionKinds -or
        $backend -cnotin $script:WinsmuxSubmissionBackends -or
        -not (Test-WinsmuxSubmissionIdentifier -Value $submissionId) -or
        $reasonCodeValue -isnot [string] -or
        $diagnosticValue -isnot [string]
    ) {
        return $false
    }
    $reasonCode = [string]$reasonCodeValue
    $diagnostic = [string]$diagnosticValue
    if ($status -eq 'accepted') {
        if ($reasonCode -cne '') { return $false }
    } elseif ($reasonCode -cnotmatch '^[a-z][a-z0-9_]*$') {
        return $false
    }
    if ($diagnostic -cne (ConvertTo-WinsmuxSubmissionDiagnostic -Text $diagnostic)) {
        return $false
    }
    if ($status -eq 'accepted') {
        $target = Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'target' -Default $null
        $targetLabel = [string](Get-WinsmuxSubmissionValue -InputObject $target -Name 'label' -Default '')
        if (-not (Test-WinsmuxSubmissionIdentifier -Value $targetLabel)) { return $false }
        return Test-WinsmuxPublicAcknowledgement -Acknowledgement $acknowledgement -SubmissionId $submissionId -Kind $kind -Backend $backend -ExpectedSlotId $targetLabel
    }
    return $null -eq $acknowledgement
}

function ConvertTo-WinsmuxSubmissionReceiptJson {
    param([Parameter(Mandatory = $true)]$Receipt)

    if (-not (Test-WinsmuxSubmissionReceipt -Receipt $Receipt)) {
        throw 'submission receipt is malformed or uses an unknown protocol version, status, kind, backend, or evidence'
    }
    return ($Receipt | ConvertTo-Json -Depth 12 -Compress)
}

function New-WinsmuxRouterRefusalReceipt {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)]$Route,
        [Parameter(Mandatory = $true)][string]$SubmissionId
    )

    $selectedRole = [string](Get-WinsmuxSubmissionValue -InputObject $Route -Name 'SelectedRole' -Default '')
    $operatorOwned = [string]::Equals($selectedRole, 'Operator', [System.StringComparison]::OrdinalIgnoreCase)
    $reasonCode = if ($operatorOwned) { 'router_operator_owned' } else { 'router_target_unavailable' }
    $ruleId = [string](Get-WinsmuxSubmissionValue -InputObject $Route -Name 'RuleId' -Default '')
    if ([string]::IsNullOrWhiteSpace($ruleId)) {
        throw 'dispatch route is missing its stable rule id'
    }
    $nextShape = if ($operatorOwned) {
        'Keep this operation with the operator or provide a non-operator task packet.'
    } else {
        "Configure an available $selectedRole worker, then resubmit the same version-1 packet."
    }

    return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend local -SubmissionId $SubmissionId `
        -ReasonCode $reasonCode -Routing ([ordered]@{
            rule_id       = $ruleId
            expected_owner = if ($operatorOwned) { 'Operator' } else { $selectedRole }
            next_shape    = $nextShape
        })
}

function Get-WinsmuxSubmissionRunPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    if (-not (Test-WinsmuxSubmissionIdentifier -Value $SlotId) -or -not (Test-WinsmuxSubmissionIdentifier -Value $RunId)) {
        throw 'submission run path contains an unsupported slot or run id'
    }
    return Join-Path (Join-Path (Join-Path (Join-Path $ProjectDir '.winsmux') 'worker-runs') $SlotId) (Join-Path $RunId 'run.json')
}

function Write-WinsmuxSubmissionRunRecordTempFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Move-WinsmuxSubmissionRunRecordFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    [System.IO.File]::Move($SourcePath, $DestinationPath)
}

function Write-WinsmuxSubmissionRunRecord {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)]$Record
    )

    $runPath = Get-WinsmuxSubmissionRunPath -ProjectDir $ProjectDir -SlotId $SlotId -RunId ([string]$Record.run_id)
    $directory = Split-Path -Parent $runPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($Record | ConvertTo-Json -Depth 12))
    $tempPath = Join-Path $directory ('.run-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Write-WinsmuxSubmissionRunRecordTempFile -Path $tempPath -Bytes $bytes
        Move-WinsmuxSubmissionRunRecordFile -SourcePath $tempPath -DestinationPath $runPath
    } finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
    return $runPath
}

function Get-WinsmuxSubmissionRunResult {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $runPath = Get-WinsmuxSubmissionRunPath -ProjectDir $ProjectDir -SlotId $SlotId -RunId $RunId
    $attempts = 60
    if ($env:WINSMUX_SUBMISSION_POLL_ATTEMPTS -match '^\d+$') { $attempts = [int]$env:WINSMUX_SUBMISSION_POLL_ATTEMPTS }
    for ($attempt = 0; $attempt -le $attempts; $attempt++) {
        if (Test-Path -LiteralPath $runPath -PathType Leaf) {
            try { return (Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-WinsmuxJson -Depth 16) }
            catch { return [ordered]@{ status = 'failed'; reason = 'runner_receipt_malformed'; exit_code = 1 } }
        }
        if ($attempt -lt $attempts) { Start-Sleep -Milliseconds 500 }
    }
    return [ordered]@{ status = 'failed'; reason = 'runner_acknowledgement_missing'; exit_code = 1 }
}

function Invoke-WinsmuxSubmissionAcknowledge {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)][string]$SubmissionId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidateSet('local', 'codex')][string]$Backend,
        [AllowNull()]$CallerIdentity = $null,
        [AllowNull()][scriptblock]$ProcessResolver = $null,
        [AllowEmptyString()][string]$AckPipe = '',
        [AllowEmptyString()][string]$Challenge = ''
    )

    $target = [ordered]@{ label = $SlotId }
    $hasAckChannel = -not [string]::IsNullOrWhiteSpace($AckPipe) -or -not [string]::IsNullOrWhiteSpace($Challenge)
    if ($hasAckChannel -and (-not (Test-WinsmuxSubmissionAckPipeName -Value $AckPipe) -or
            -not (Test-WinsmuxSubmissionAckChallenge -Value $Challenge))) {
        throw 'submission acknowledgement channel is invalid'
    }
    $finish = {
        param($Receipt)
        if (-not $hasAckChannel) { return $Receipt }
        return Invoke-WinsmuxSubmissionAcknowledgementClientHandshake `
            -PipeName $AckPipe -Challenge $Challenge -Receipt $Receipt
    }.GetNewClosure()
    if (-not (Get-Command Get-PaneControlManifestEntries -ErrorAction SilentlyContinue) -or
        -not (Get-Command Test-PaneControlRuntimeContext -ErrorAction SilentlyContinue)) {
        return & $finish (New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $Backend -SubmissionId $SubmissionId `
            -ReasonCode 'caller_identity_unavailable' -Target $target)
    }

    $entries = @(Get-PaneControlManifestEntries -ProjectDir $ProjectDir | Where-Object { [string]$_.Label -ceq $SlotId })
    if ($entries.Count -ne 1) {
        return & $finish (New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $Backend -SubmissionId $SubmissionId `
            -ReasonCode 'runtime_target_mismatch' -Target $target)
    }
    $manifestEntry = $entries[0]
    $target['pane_id'] = [string](Get-WinsmuxSubmissionValue -InputObject $manifestEntry -Name 'PaneId' -Default '')
    $target['role'] = [string](Get-WinsmuxSubmissionValue -InputObject $manifestEntry -Name 'Role' -Default '')
    if ([string](Get-WinsmuxSubmissionValue -InputObject $manifestEntry -Name 'WorkerBackend' -Default '') -cne $Backend) {
        return & $finish (New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $Backend -SubmissionId $SubmissionId `
            -ReasonCode 'caller_identity_mismatch' -Target $target)
    }

    $runtimeArguments = @{
        ProjectDir     = $ProjectDir
        ManifestEntry = $manifestEntry
        Operation     = 'caller_ack'
    }
    if ($null -ne $CallerIdentity) { $runtimeArguments['CallerIdentity'] = $CallerIdentity }
    if ($null -ne $ProcessResolver) { $runtimeArguments['ProcessResolver'] = $ProcessResolver }
    $runtimeResult = Test-PaneControlRuntimeContext @runtimeArguments
    if (-not $runtimeResult.valid) {
        return & $finish (New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $Backend -SubmissionId $SubmissionId `
            -ReasonCode ([string]$runtimeResult.reason_code) -Diagnostic ([string]$runtimeResult.diagnostic) -Target $target)
    }

    if ($RunId -cne $SubmissionId) {
        return & $finish (New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $Backend -SubmissionId $SubmissionId `
            -ReasonCode 'runner_evidence_invalid' -Target $target)
    }
    $runPath = Get-WinsmuxSubmissionRunPath -ProjectDir $ProjectDir -SlotId $SlotId -RunId $RunId
    if (Test-Path -LiteralPath $runPath -PathType Leaf) {
        return & $finish (New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $Backend -SubmissionId $SubmissionId `
            -ReasonCode 'run_record_already_exists' -Target $target)
    }

    $packetPath = (Resolve-WinsmuxSubmissionPacketPath -ProjectDir $ProjectDir -SubmissionId $SubmissionId).FullPath
    if (-not (Test-Path -LiteralPath $packetPath -PathType Leaf)) {
        return & $finish (New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $Backend -SubmissionId $SubmissionId `
            -ReasonCode 'runner_acknowledgement_missing' -Target $target)
    }
    try { $packet = Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8 | ConvertFrom-WinsmuxJson -Depth 16 }
    catch {
        return & $finish (New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $Backend -SubmissionId $SubmissionId `
            -ReasonCode 'runner_receipt_malformed' -Target $target)
    }
    if (-not (Test-WinsmuxSubmissionPacket -Packet $packet) -or
        [string]$packet.submission_id -cne $SubmissionId -or [string]$packet.run_id -cne $RunId -or
        [string]$packet.kind -cne $Kind -or [string]$packet.target -cne $SlotId) {
        return & $finish (New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $Backend -SubmissionId $SubmissionId `
            -ReasonCode 'runner_evidence_invalid' -Target $target)
    }

    $record = New-WinsmuxSubmissionRunRecord -SubmissionId $SubmissionId -RunId $RunId -TaskId ([string]$packet.task_id) `
        -Kind $Kind -TaskTitle ([string]$packet.title) -SlotId $SlotId -Backend $Backend -Status started `
        -RequestConsumed -RequestDigest ([string]$packet.request_digest)
    $receipt = New-WinsmuxSubmissionReceipt -Kind $Kind -Status accepted -Backend $Backend -SubmissionId $SubmissionId `
        -Target $target -Acknowledgement $record
    return & $finish $receipt
}

function Get-WinsmuxSubmissionAckTimeoutMilliseconds {
    $configured = 0
    if ([int]::TryParse([string]$env:WINSMUX_SUBMISSION_ACK_TIMEOUT_MS, [ref]$configured) -and
        $configured -ge 1 -and $configured -le 300000) {
        return $configured
    }
    return $script:WinsmuxSubmissionAckTimeoutMilliseconds
}

function Test-WinsmuxSubmissionAckPipeName {
    param([AllowEmptyString()][string]$Value = '')

    return $Value -cmatch '^winsmux-submission-ack-[0-9a-f]{32}$'
}

function Test-WinsmuxSubmissionAckChallenge {
    param([AllowEmptyString()][string]$Value = '')

    return $Value -cmatch '^[0-9a-f]{64}$'
}

function New-WinsmuxSubmissionAckChallenge {
    $bytes = New-Object byte[] 32
    $algorithm = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $algorithm.GetBytes($bytes)
    } finally {
        $algorithm.Dispose()
    }
    return ([System.BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant())
}

function New-WinsmuxSubmissionAckPipeServerStream {
    param([Parameter(Mandatory = $true)][string]$PipeName)

    if (-not (Test-WinsmuxSubmissionAckPipeName -Value $PipeName)) {
        throw 'submission acknowledgement pipe name is invalid'
    }

    $direction = [System.IO.Pipes.PipeDirection]::InOut
    $transmission = [System.IO.Pipes.PipeTransmissionMode]::Byte
    $options = [System.IO.Pipes.PipeOptions]::Asynchronous
    if ([enum]::GetNames([System.IO.Pipes.PipeOptions]) -contains 'CurrentUserOnly') {
        $options = $options -bor [System.IO.Pipes.PipeOptions]::CurrentUserOnly
        return [System.IO.Pipes.NamedPipeServerStream]::new($PipeName, $direction, 1, $transmission, $options, 4096, 4096)
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $security = [System.IO.Pipes.PipeSecurity]::new()
        $security.SetAccessRuleProtection($true, $false)
        $rule = [System.IO.Pipes.PipeAccessRule]::new(
            $identity.User,
            [System.IO.Pipes.PipeAccessRights]::ReadWrite,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule)
        return [System.IO.Pipes.NamedPipeServerStream]::new($PipeName, $direction, 1, $transmission, $options, 4096, 4096, $security)
    } finally {
        $identity.Dispose()
    }
}

function New-WinsmuxSubmissionAcknowledgementServer {
    $pipeName = 'winsmux-submission-ack-' + [guid]::NewGuid().ToString('N')
    return [PSCustomObject][ordered]@{
        pipe_name = $pipeName
        challenge = New-WinsmuxSubmissionAckChallenge
        server    = New-WinsmuxSubmissionAckPipeServerStream -PipeName $pipeName
    }
}

function Wait-WinsmuxSubmissionPipeTask {
    param(
        [Parameter(Mandatory = $true)][System.Threading.Tasks.Task]$Task,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds,
        [Parameter(Mandatory = $true)][System.IDisposable]$TimeoutTarget
    )

    $delay = [System.Threading.Tasks.Task]::Delay($TimeoutMilliseconds)
    $winner = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($Task, $delay))
    if ($winner -ne 0) {
        $TimeoutTarget.Dispose()
        try { $Task.GetAwaiter().GetResult() | Out-Null } catch { }
        throw [System.TimeoutException]::new('submission acknowledgement pipe timed out')
    }
    return $Task.GetAwaiter().GetResult()
}

function Write-WinsmuxSubmissionPipeFrame {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][string]$Json
    )

    $payload = [System.Text.UTF8Encoding]::new($false).GetBytes($Json)
    if ($payload.Length -lt 2 -or $payload.Length -gt $script:WinsmuxSubmissionAckFrameLimit) {
        throw 'submission acknowledgement frame length is invalid'
    }
    $header = [System.BitConverter]::GetBytes([int]$payload.Length)
    $Stream.Write($header, 0, $header.Length)
    $Stream.Write($payload, 0, $payload.Length)
    $Stream.Flush()
}

function Read-WinsmuxSubmissionPipeBytes {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][int]$Length,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
    )

    $buffer = New-Object byte[] $Length
    $offset = 0
    while ($offset -lt $Length) {
        $readTask = $Stream.ReadAsync($buffer, $offset, $Length - $offset)
        $read = Wait-WinsmuxSubmissionPipeTask -Task $readTask -TimeoutMilliseconds $TimeoutMilliseconds -TimeoutTarget $Stream
        if ($read -lt 1) { throw 'submission acknowledgement pipe closed before a complete frame was received' }
        $offset += [int]$read
    }
    return ,$buffer
}

function Read-WinsmuxSubmissionPipeFrame {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
    )

    $header = Read-WinsmuxSubmissionPipeBytes -Stream $Stream -Length 4 -TimeoutMilliseconds $TimeoutMilliseconds
    $length = [System.BitConverter]::ToInt32($header, 0)
    if ($length -lt 2 -or $length -gt $script:WinsmuxSubmissionAckFrameLimit) {
        throw 'submission acknowledgement frame length is invalid'
    }
    $payload = Read-WinsmuxSubmissionPipeBytes -Stream $Stream -Length $length -TimeoutMilliseconds $TimeoutMilliseconds
    return [System.Text.UTF8Encoding]::new($false, $true).GetString($payload)
}

function Read-WinsmuxSubmissionPipeJson {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [int]$TimeoutMilliseconds = (Get-WinsmuxSubmissionAckTimeoutMilliseconds)
    )

    $json = Read-WinsmuxSubmissionPipeFrame -Stream $Stream -TimeoutMilliseconds $TimeoutMilliseconds
    try { return ($json | ConvertFrom-WinsmuxJson -Depth 16) }
    catch { throw 'submission acknowledgement frame is not valid JSON' }
}

function Initialize-WinsmuxSubmissionPipeInterop {
    if ('WinsmuxSubmissionPipeNative' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class WinsmuxSubmissionPipeNative
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint clientProcessId);

    public static int GetClientProcessId(SafePipeHandle pipe)
    {
        uint processId;
        if (!GetNamedPipeClientProcessId(pipe, out processId))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return checked((int)processId);
    }
}
'@
}

function Get-WinsmuxSubmissionPipeClientProcessId {
    param([Parameter(Mandatory = $true)][System.IO.Pipes.NamedPipeServerStream]$Server)

    if (-not $Server.IsConnected) {
        throw 'submission acknowledgement pipe is not connected'
    }
    Initialize-WinsmuxSubmissionPipeInterop
    return [WinsmuxSubmissionPipeNative]::GetClientProcessId($Server.SafePipeHandle)
}

function Receive-WinsmuxSubmissionAcknowledgement {
    param(
        [Parameter(Mandatory = $true)]$ServerState,
        [int]$TimeoutMilliseconds = (Get-WinsmuxSubmissionAckTimeoutMilliseconds)
    )

    $server = Get-WinsmuxSubmissionValue -InputObject $ServerState -Name 'server' -Default $null
    if ($server -isnot [System.IO.Pipes.NamedPipeServerStream]) {
        throw 'submission acknowledgement server state is invalid'
    }
    if (-not $server.IsConnected) {
        $waitTask = $server.WaitForConnectionAsync()
        Wait-WinsmuxSubmissionPipeTask -Task $waitTask -TimeoutMilliseconds $TimeoutMilliseconds -TimeoutTarget $server | Out-Null
    }
    $clientProcessId = Get-WinsmuxSubmissionPipeClientProcessId -Server $server
    return [PSCustomObject][ordered]@{
        client_process_id = $clientProcessId
        payload           = Read-WinsmuxSubmissionPipeJson -Stream $server -TimeoutMilliseconds $TimeoutMilliseconds
    }
}

function Write-WinsmuxSubmissionAcknowledgementControl {
    param(
        [Parameter(Mandatory = $true)]$ServerState,
        [Parameter(Mandatory = $true)][ValidateSet('commit', 'verified', 'rejected')][string]$Status
    )

    $server = Get-WinsmuxSubmissionValue -InputObject $ServerState -Name 'server' -Default $null
    if ($server -isnot [System.IO.Pipes.NamedPipeServerStream] -or -not $server.IsConnected) {
        throw 'submission acknowledgement pipe is not connected'
    }
    $response = [ordered]@{ protocol_version = 1; status = $Status }
    Write-WinsmuxSubmissionPipeFrame -Stream $server -Json ($response | ConvertTo-Json -Compress)
}

function Test-WinsmuxSubmissionAcknowledgementControl {
    param(
        [AllowNull()]$Control,
        [Parameter(Mandatory = $true)][ValidateSet('commit', 'verified', 'rejected')][string]$ExpectedStatus
    )

    if ($null -eq $Control) { return $false }
    $names = if ($Control -is [System.Collections.IDictionary]) { @($Control.Keys) } else { @($Control.PSObject.Properties.Name) }
    $version = Get-WinsmuxSubmissionRawValue -InputObject $Control -Name 'protocol_version' -Default $null
    return (
        $names.Count -eq 2 -and @($names | Where-Object { [string]$_ -cnotin @('protocol_version', 'status') }).Count -eq 0 -and
        (Test-WinsmuxSubmissionInteger -Value $version) -and [int64]$version -eq 1 -and
        [string](Get-WinsmuxSubmissionValue -InputObject $Control -Name 'status' -Default '') -ceq $ExpectedStatus
    )
}

function Complete-WinsmuxSubmissionAcknowledgement {
    param(
        [Parameter(Mandatory = $true)]$ServerState,
        [Parameter(Mandatory = $true)][bool]$Verified
    )

    $server = Get-WinsmuxSubmissionValue -InputObject $ServerState -Name 'server' -Default $null
    if ($server -isnot [System.IO.Pipes.NamedPipeServerStream]) { return $false }
    try {
        if ($server.IsConnected) {
            $status = if ($Verified) { 'verified' } else { 'rejected' }
            Write-WinsmuxSubmissionAcknowledgementControl -ServerState $ServerState -Status $status
        }
        return $true
    } catch {
        return $false
    } finally {
        $server.Dispose()
    }
}

function New-WinsmuxSubmissionAcknowledgementEnvelope {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('candidate', 'committed')][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Challenge,
        [Parameter(Mandatory = $true)]$Receipt
    )

    if (-not (Test-WinsmuxSubmissionAckChallenge -Value $Challenge) -or
        -not (Test-WinsmuxSubmissionReceipt -Receipt $Receipt)) {
        throw 'submission acknowledgement envelope input is invalid'
    }
    return [ordered]@{
        protocol_version = 1
        phase            = $Phase
        challenge        = $Challenge
        receipt          = $Receipt
    }
}

function Test-WinsmuxSubmissionAcknowledgementEnvelope {
    param(
        [AllowNull()]$Envelope,
        [Parameter(Mandatory = $true)][ValidateSet('candidate', 'committed')][string]$ExpectedPhase,
        [Parameter(Mandatory = $true)][string]$ExpectedChallenge,
        [Parameter(Mandatory = $true)][string]$SubmissionId,
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidateSet('local', 'codex')][string]$Backend,
        [Parameter(Mandatory = $true)][string]$SlotId
    )

    if ($null -eq $Envelope) { return $false }
    $allowedNames = @('protocol_version', 'phase', 'challenge', 'receipt')
    $actualNames = if ($Envelope -is [System.Collections.IDictionary]) {
        @($Envelope.Keys | ForEach-Object { [string]$_ })
    } else {
        @($Envelope.PSObject.Properties.Name)
    }
    if ($actualNames.Count -ne $allowedNames.Count -or @($actualNames | Where-Object { $_ -cnotin $allowedNames }).Count -gt 0) {
        return $false
    }
    $version = Get-WinsmuxSubmissionRawValue -InputObject $Envelope -Name 'protocol_version' -Default $null
    $phase = Get-WinsmuxSubmissionRawValue -InputObject $Envelope -Name 'phase' -Default $null
    $challenge = Get-WinsmuxSubmissionRawValue -InputObject $Envelope -Name 'challenge' -Default $null
    $receipt = Get-WinsmuxSubmissionRawValue -InputObject $Envelope -Name 'receipt' -Default $null
    if (-not (Test-WinsmuxSubmissionInteger -Value $version) -or [int64]$version -ne 1 -or
        $phase -isnot [string] -or [string]$phase -cne $ExpectedPhase -or
        $challenge -isnot [string] -or -not [string]::Equals([string]$challenge, $ExpectedChallenge, [System.StringComparison]::Ordinal) -or
        -not (Test-WinsmuxSubmissionAckChallenge -Value ([string]$challenge)) -or
        -not (Test-WinsmuxSubmissionReceipt -Receipt $receipt)) {
        return $false
    }
    $target = Get-WinsmuxSubmissionValue -InputObject $receipt -Name 'target' -Default $null
    return (
        [string](Get-WinsmuxSubmissionValue -InputObject $receipt -Name 'submission_id' -Default '') -ceq $SubmissionId -and
        [string](Get-WinsmuxSubmissionValue -InputObject $receipt -Name 'kind' -Default '') -ceq $Kind -and
        [string](Get-WinsmuxSubmissionValue -InputObject $receipt -Name 'backend' -Default '') -ceq $Backend -and
        [string](Get-WinsmuxSubmissionValue -InputObject $target -Name 'label' -Default '') -ceq $SlotId
    )
}

function Invoke-WinsmuxSubmissionAcknowledgementClientHandshake {
    param(
        [Parameter(Mandatory = $true)][string]$PipeName,
        [Parameter(Mandatory = $true)][string]$Challenge,
        [Parameter(Mandatory = $true)]$Receipt,
        [int]$TimeoutMilliseconds = (Get-WinsmuxSubmissionAckTimeoutMilliseconds)
    )

    if (-not (Test-WinsmuxSubmissionAckPipeName -Value $PipeName)) {
        throw 'submission acknowledgement pipe name is invalid'
    }
    $candidate = New-WinsmuxSubmissionAcknowledgementEnvelope -Phase candidate -Challenge $Challenge -Receipt $Receipt
    $client = [System.IO.Pipes.NamedPipeClientStream]::new(
        '.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous
    )
    try {
        $client.Connect($TimeoutMilliseconds)
        Write-WinsmuxSubmissionPipeFrame -Stream $client -Json ($candidate | ConvertTo-Json -Depth 14 -Compress)
        $control = Read-WinsmuxSubmissionPipeJson -Stream $client -TimeoutMilliseconds $TimeoutMilliseconds
        if ([string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'status' -Default '') -cne 'accepted') {
            return $Receipt
        }
        if (-not (Test-WinsmuxSubmissionAcknowledgementControl -Control $control -ExpectedStatus commit)) {
            return New-WinsmuxSubmissionReceipt -Kind ([string]$Receipt.kind) -Status rejected -Backend ([string]$Receipt.backend) `
                -SubmissionId ([string]$Receipt.submission_id) -ReasonCode 'runner_evidence_invalid' -Target $Receipt.target
        }

        $committed = New-WinsmuxSubmissionAcknowledgementEnvelope -Phase committed -Challenge $Challenge -Receipt $Receipt
        Write-WinsmuxSubmissionPipeFrame -Stream $client -Json ($committed | ConvertTo-Json -Depth 14 -Compress)
        $finalControl = Read-WinsmuxSubmissionPipeJson -Stream $client -TimeoutMilliseconds $TimeoutMilliseconds
        if (Test-WinsmuxSubmissionAcknowledgementControl -Control $finalControl -ExpectedStatus verified) { return $Receipt }
        return New-WinsmuxSubmissionReceipt -Kind ([string]$Receipt.kind) -Status rejected -Backend ([string]$Receipt.backend) `
            -SubmissionId ([string]$Receipt.submission_id) -ReasonCode 'runner_evidence_invalid' -Target $Receipt.target
    } finally {
        $client.Dispose()
    }
}

function New-WinsmuxSubmissionPipeCallerEvidence {
    param(
        [Parameter(Mandatory = $true)][int]$ClientProcessId,
        [Parameter(Mandatory = $true)]$RuntimeResult
    )

    if (-not (Get-Command New-WinsmuxProcessSnapshotResolver -ErrorAction SilentlyContinue)) {
        throw 'OS process ancestry resolver is unavailable'
    }
    $context = Get-WinsmuxSubmissionValue -InputObject $RuntimeResult -Name 'context' -Default $null
    $generationId = [string](Get-WinsmuxSubmissionValue -InputObject $context -Name 'generation_id' -Default '')
    $serverSessionId = [string](Get-WinsmuxSubmissionValue -InputObject $context -Name 'server_session_id' -Default '')
    $slotId = [string](Get-WinsmuxSubmissionValue -InputObject $context -Name 'slot_id' -Default '')
    $paneId = [string](Get-WinsmuxSubmissionValue -InputObject $context -Name 'pane_id' -Default '')
    $backend = [string](Get-WinsmuxSubmissionValue -InputObject $context -Name 'backend' -Default '')
    if ([string]::IsNullOrWhiteSpace($generationId) -or $serverSessionId -cnotmatch '^\$[0-9]+$' -or
        -not (Test-WinsmuxSubmissionIdentifier -Value $slotId) -or [string]::IsNullOrWhiteSpace($paneId) -or
        $backend -notin @('local', 'codex')) {
        throw 'dispatch runtime context is incomplete for caller acknowledgement'
    }

    $resolver = New-WinsmuxProcessSnapshotResolver
    $snapshot = & $resolver $ClientProcessId
    $startedAt = [string](Get-WinsmuxSubmissionValue -InputObject $snapshot -Name 'StartTime' -Default '')
    if ($null -eq $snapshot -or [int](Get-WinsmuxSubmissionValue -InputObject $snapshot -Name 'Id' -Default 0) -ne $ClientProcessId -or
        [string]::IsNullOrWhiteSpace($startedAt)) {
        throw 'acknowledgement pipe client process identity is unavailable'
    }
    return [PSCustomObject][ordered]@{
        caller_identity = [PSCustomObject][ordered]@{
            process_id         = $ClientProcessId
            process_started_at = $startedAt
            generation_id      = $generationId
            server_session_id  = $serverSessionId
            slot_id            = $slotId
            pane_id            = $paneId
            backend            = $backend
        }
        process_resolver = $resolver
    }
}

function Test-WinsmuxSubmissionAcknowledgementMatchesRunRecord {
    param(
        [AllowNull()]$Acknowledgement,
        [AllowNull()]$RunRecord
    )

    if ($null -eq $Acknowledgement -or $null -eq $RunRecord) { return $false }
    $expected = ConvertTo-WinsmuxPublicAcknowledgement -Acknowledgement $RunRecord
    $actual = ConvertTo-WinsmuxPublicAcknowledgement -Acknowledgement $Acknowledgement
    return (($expected | ConvertTo-Json -Compress) -ceq ($actual | ConvertTo-Json -Compress))
}

function Invoke-WinsmuxSubmissionCliRun {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)][string]$PacketPath,
        [Parameter(Mandatory = $true)][string]$SubmissionId,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Backend,
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind
    )

    $workerArguments = @('workers', 'exec', $SlotId, '--task-json', $PacketPath)
    $workerArguments += @('--task-id', $TaskId, '--run-id', $SubmissionId, '--json', '--project-dir', $ProjectDir)
    $output = & pwsh -NoProfile -File $script:WinsmuxSubmissionBridgeScript @workerArguments 2>&1
    $exitCode = $LASTEXITCODE
    $jsonLine = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
    if ($jsonLine.Count -lt 1) {
        return [ordered]@{ status = 'unavailable'; reason = 'cli_command_missing'; exit_code = if ($exitCode) { $exitCode } else { 1 } }
    }
    try { return ($jsonLine[0] | ConvertFrom-WinsmuxJson -Depth 16) }
    catch { return [ordered]@{ status = 'unavailable'; reason = 'cli_receipt_malformed'; exit_code = 1 } }
}

function Test-WinsmuxSubmissionRuntimeFreshness {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$ManifestEntry,
        [AllowEmptyString()][string]$ExpectedGenerationId = ''
    )

    try {
        $result = Test-PaneControlRuntimeContext `
            -ProjectDir $ProjectDir -ManifestEntry $ManifestEntry -Operation dispatch
    } catch {
        return New-WinsmuxRuntimeValidationResult -Valid $false `
            -ReasonCode 'manifest_regeneration_required' `
            -Diagnostic 'Runtime identity evidence is unavailable; regenerate the orchestra session.'
    }
    if (-not $result.valid) {
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedGenerationId)) {
        return New-WinsmuxRuntimeValidationResult -Valid $false `
            -ReasonCode 'manifest_regeneration_required' `
            -Diagnostic 'Captured runtime generation identity is missing; regenerate the orchestra session.'
    }

    $context = Get-WinsmuxSubmissionValue -InputObject $result -Name 'context' -Default $null
    $actualGenerationId = [string](Get-WinsmuxSubmissionValue -InputObject $context -Name 'generation_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($actualGenerationId)) {
        return New-WinsmuxRuntimeValidationResult -Valid $false `
            -ReasonCode 'manifest_regeneration_required' `
            -Diagnostic 'Fresh runtime generation identity is missing; regenerate the orchestra session.'
    }
    if (-not [string]::Equals($actualGenerationId, $ExpectedGenerationId, [System.StringComparison]::Ordinal)) {
        return New-WinsmuxRuntimeValidationResult -Valid $false `
            -ReasonCode 'invalid_supervisor_identity' `
            -Diagnostic 'Runtime generation changed before submission packet publication.'
    }
    return $result
}

function Invoke-WinsmuxSubmissionAdapter {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$ManifestEntry,
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)]$Content,
        [string]$SubmissionId = ('submission-' + [guid]::NewGuid().ToString('N')),
        [AllowEmptyString()][string]$TaskId = '',
        [scriptblock]$SendAction,
        [scriptblock]$CaptureAction,
        [scriptblock]$RunResultAction,
        [scriptblock]$CliRunAction
    )

    $label = [string](Get-WinsmuxSubmissionValue -InputObject $ManifestEntry -Name 'Label' -Default '')
    $paneId = [string](Get-WinsmuxSubmissionValue -InputObject $ManifestEntry -Name 'PaneId' -Default '')
    $role = [string](Get-WinsmuxSubmissionValue -InputObject $ManifestEntry -Name 'Role' -Default '')
    $backend = ([string](Get-WinsmuxSubmissionValue -InputObject $ManifestEntry -Name 'WorkerBackend' -Default 'local')).Trim().ToLowerInvariant()
    $target = [ordered]@{ label = $label; pane_id = $paneId; role = $role }

    if ($backend -notin $script:WinsmuxSubmissionBackends -or $backend -eq 'noop') {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unsupported -Backend noop -SubmissionId $SubmissionId -ReasonCode 'backend_unsupported' -Target $target
    }
    if ([string]::IsNullOrWhiteSpace($TaskId)) { $TaskId = $SubmissionId }
    if (-not (Test-WinsmuxSubmissionIdentifier -Value $TaskId)) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'task_identifier_invalid' -Target $target
    }
    if (-not (Test-WinsmuxSubmissionIdentifier -Value $label)) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend noop -SubmissionId $SubmissionId -ReasonCode 'target_identifier_invalid' -Target $target
    }

    if (-not (Get-Command Test-PaneControlRuntimeContext -ErrorAction SilentlyContinue)) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId `
            -ReasonCode 'manifest_regeneration_required' -Diagnostic 'Runtime identity validator is unavailable.' -Target $target
    }
    try {
        $runtimeResult = Test-PaneControlRuntimeContext -ProjectDir $ProjectDir -ManifestEntry $ManifestEntry -Operation dispatch
    } catch {
        $runtimeResult = New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'manifest_regeneration_required' `
            -Diagnostic 'Runtime identity evidence is unavailable; regenerate the orchestra session.'
    }
    if (-not $runtimeResult.valid) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId `
            -ReasonCode ([string]$runtimeResult.reason_code) -Diagnostic ([string]$runtimeResult.diagnostic) -Target $target
    }
    $initialRuntimeContext = Get-WinsmuxSubmissionValue -InputObject $runtimeResult -Name 'context' -Default $null
    $initialGenerationId = [string](Get-WinsmuxSubmissionValue -InputObject $initialRuntimeContext -Name 'generation_id' -Default '')

    $existingRunPath = Get-WinsmuxSubmissionRunPath -ProjectDir $ProjectDir -SlotId $label -RunId $SubmissionId
    if (Test-Path -LiteralPath $existingRunPath -PathType Leaf) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'run_record_already_exists' -Target $target
    }
    $packetPath = (Resolve-WinsmuxSubmissionPacketPath -ProjectDir $ProjectDir -SubmissionId $SubmissionId).FullPath
    if (Test-Path -LiteralPath $packetPath -PathType Leaf) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'run_record_already_exists' -Target $target
    }
    $prePublicationRuntime = Test-WinsmuxSubmissionRuntimeFreshness `
        -ProjectDir $ProjectDir -ManifestEntry $ManifestEntry -ExpectedGenerationId $initialGenerationId
    if (-not $prePublicationRuntime.valid) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId `
            -ReasonCode ([string]$prePublicationRuntime.reason_code) `
            -Diagnostic ([string]$prePublicationRuntime.diagnostic) -Target $target
    }
    try {
        $packet = New-WinsmuxSubmissionPacket -ProjectDir $ProjectDir -Kind $Kind -Content $Content -SubmissionId $SubmissionId -TargetLabel $label -TaskId $TaskId
    } catch [System.IO.IOException] {
        if (Test-Path -LiteralPath $packetPath -PathType Leaf) {
            return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'run_record_already_exists' -Target $target
        }
        throw
    }
    $runtimeResult = Test-WinsmuxSubmissionRuntimeFreshness `
        -ProjectDir $ProjectDir -ManifestEntry $ManifestEntry -ExpectedGenerationId $initialGenerationId
    if (-not $runtimeResult.valid) {
        Remove-Item -LiteralPath ([string]$packet.FullPath) -Force -ErrorAction SilentlyContinue
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId `
            -ReasonCode ([string]$runtimeResult.reason_code) -Diagnostic ([string]$runtimeResult.diagnostic) -Target $target
    }
    $runtimeContext = Get-WinsmuxSubmissionValue -InputObject $runtimeResult -Name 'context' -Default $null
    $capturedGenerationId = [string](Get-WinsmuxSubmissionValue -InputObject $runtimeContext -Name 'generation_id' -Default '')
    if ($backend -in @('local', 'codex', 'api_llm') -and $null -eq $SendAction -and
        [string]::IsNullOrWhiteSpace($capturedGenerationId)) {
        Remove-Item -LiteralPath ([string]$packet.FullPath) -Force -ErrorAction SilentlyContinue
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId `
            -ReasonCode 'manifest_regeneration_required' `
            -Diagnostic 'Runtime generation identity is missing; regenerate the orchestra session.' -Target $target
    }
    if ($backend -in @('local', 'codex')) {
        if ([string]::IsNullOrWhiteSpace($paneId)) {
            Remove-Item -LiteralPath ([string]$packet.FullPath) -Force -ErrorAction SilentlyContinue
            return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'pane_unavailable' -Target $target
        }
        $ackServer = $null
        $acknowledgementVerified = $false
        $submissionAccepted = $false
        $adapterCreatedRunPath = ''
        $durableCommitValidated = $false
        $deliveryState = [ordered]@{ SubmissionCommitted = $false }
        try {
            try {
                $ackServer = New-WinsmuxSubmissionAcknowledgementServer
            } catch {
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId `
                    -ReasonCode 'backend_acknowledgement_missing' -Target $target
            }
            $ackCommand = "winsmux submission-ack --submission-id $SubmissionId --run-id $SubmissionId --kind $Kind --backend $backend --slot $label --ack-pipe $($ackServer.pipe_name) --challenge $($ackServer.challenge)"
            $packetInstruction = "Read and execute the typed submission packet at '$($packet.RelativePath)'. After accepting that exact packet from this pane, run: $ackCommand"
            try {
                if ($null -ne $SendAction) {
                    & $SendAction $paneId $packetInstruction | Out-Null
                    $deliveryState['SubmissionCommitted'] = $true
                }
                else {
                    Send-TextToPane -PaneId $paneId -CommandText $packetInstruction `
                        -RuntimeProjectDir $ProjectDir -RuntimeOperation dispatch `
                        -ExpectedGenerationId $capturedGenerationId -DeliveryState $deliveryState | Out-Null
                }
            } catch {
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'packet_repl_unavailable' -Diagnostic $_.Exception.Message -Target $target
            }

            try {
                $pipeAcknowledgement = Receive-WinsmuxSubmissionAcknowledgement -ServerState $ackServer
                $callerEvidence = New-WinsmuxSubmissionPipeCallerEvidence `
                    -ClientProcessId ([int]$pipeAcknowledgement.client_process_id) -RuntimeResult $runtimeResult
            } catch {
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId `
                    -ReasonCode 'backend_acknowledgement_missing' -Target $target
            }

            try {
                $callerRuntimeResult = Test-PaneControlRuntimeContext -ProjectDir $ProjectDir -ManifestEntry $ManifestEntry `
                    -Operation caller_ack -CallerIdentity $callerEvidence.caller_identity -ProcessResolver $callerEvidence.process_resolver
            } catch {
                $callerRuntimeResult = New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'caller_identity_mismatch' `
                    -Diagnostic 'Acknowledgement caller identity could not be verified.'
            }
            if (-not $callerRuntimeResult.valid) {
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId `
                    -ReasonCode ([string]$callerRuntimeResult.reason_code) -Diagnostic ([string]$callerRuntimeResult.diagnostic) -Target $target
            }

            if (-not (Test-WinsmuxSubmissionAcknowledgementEnvelope -Envelope $pipeAcknowledgement.payload `
                    -ExpectedPhase candidate -ExpectedChallenge ([string]$ackServer.challenge) `
                    -SubmissionId $SubmissionId -Kind $Kind -Backend $backend -SlotId $label)) {
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId `
                    -ReasonCode 'runner_evidence_invalid' -Target $target
            }
            $candidateReceipt = Get-WinsmuxSubmissionRawValue -InputObject $pipeAcknowledgement.payload -Name 'receipt' -Default $null
            if ([string](Get-WinsmuxSubmissionValue -InputObject $candidateReceipt -Name 'status' -Default '') -cne 'accepted') {
                $acknowledgementVerified = $true
                return $candidateReceipt
            }
            $canonicalRunRecord = New-WinsmuxSubmissionRunRecord -SubmissionId $SubmissionId -RunId $SubmissionId `
                -TaskId ([string]$packet.Packet.task_id) -Kind $Kind -TaskTitle ([string]$packet.Packet.title) `
                -SlotId $label -Backend $backend -Status started -RequestConsumed `
                -RequestDigest ([string]$packet.Packet.request_digest)
            if (-not (Test-WinsmuxSubmissionAcknowledgementMatchesRunRecord `
                    -Acknowledgement (Get-WinsmuxSubmissionRawValue -InputObject $candidateReceipt -Name 'acknowledgement' -Default $null) `
                    -RunRecord $canonicalRunRecord)) {
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId `
                    -ReasonCode 'runner_evidence_invalid' -Target $target
            }

            Write-WinsmuxSubmissionAcknowledgementControl -ServerState $ackServer -Status commit
            $committedAcknowledgement = Receive-WinsmuxSubmissionAcknowledgement -ServerState $ackServer
            if ([int]$committedAcknowledgement.client_process_id -ne [int]$pipeAcknowledgement.client_process_id) {
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId `
                    -ReasonCode 'caller_identity_mismatch' -Target $target
            }
            if (-not (Test-WinsmuxSubmissionAcknowledgementEnvelope -Envelope $committedAcknowledgement.payload `
                    -ExpectedPhase committed -ExpectedChallenge ([string]$ackServer.challenge) `
                    -SubmissionId $SubmissionId -Kind $Kind -Backend $backend -SlotId $label)) {
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId `
                    -ReasonCode 'runner_evidence_invalid' -Target $target
            }
            try {
                $freshCallerEvidence = New-WinsmuxSubmissionPipeCallerEvidence `
                    -ClientProcessId ([int]$committedAcknowledgement.client_process_id) -RuntimeResult $runtimeResult
                $freshCallerResult = Test-PaneControlRuntimeContext -ProjectDir $ProjectDir -ManifestEntry $ManifestEntry `
                    -Operation caller_ack -CallerIdentity $freshCallerEvidence.caller_identity `
                    -ProcessResolver $freshCallerEvidence.process_resolver
            } catch {
                $freshCallerResult = New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'caller_identity_mismatch' `
                    -Diagnostic 'Committed acknowledgement caller identity could not be revalidated.'
            }
            if (-not $freshCallerResult.valid) {
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId `
                    -ReasonCode ([string]$freshCallerResult.reason_code) -Diagnostic ([string]$freshCallerResult.diagnostic) -Target $target
            }
            $committedReceipt = Get-WinsmuxSubmissionRawValue -InputObject $committedAcknowledgement.payload -Name 'receipt' -Default $null
            if (-not (Test-WinsmuxSubmissionAcknowledgementMatchesRunRecord `
                    -Acknowledgement (Get-WinsmuxSubmissionRawValue -InputObject $committedReceipt -Name 'acknowledgement' -Default $null) `
                    -RunRecord $canonicalRunRecord)) {
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId `
                    -ReasonCode 'runner_evidence_invalid' -Target $target
            }

            try {
                $adapterCreatedRunPath = Write-WinsmuxSubmissionRunRecord -ProjectDir $ProjectDir -SlotId $label -Record $canonicalRunRecord
            } catch {
                $reasonCode = if (Test-Path -LiteralPath $existingRunPath -PathType Leaf) {
                    'run_record_already_exists'
                } else {
                    'runner_evidence_invalid'
                }
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId `
                    -ReasonCode $reasonCode -Target $target
            }
            try { $runner = Get-Content -LiteralPath $adapterCreatedRunPath -Raw -Encoding UTF8 | ConvertFrom-WinsmuxJson -Depth 16 }
            catch {
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId `
                    -ReasonCode 'runner_receipt_malformed' -Target $target
            }
            if ((Test-WinsmuxSubmissionRunRecord -Record $runner -SubmissionId $SubmissionId -Kind $Kind -Backend $backend `
                    -ExpectedSlotId $label -ExpectedRequestDigest ([string]$packet.Packet.request_digest) `
                    -ExpectedTaskId ([string]$packet.Packet.task_id)) -and
                (Test-WinsmuxSubmissionAcknowledgementMatchesRunRecord `
                    -Acknowledgement (Get-WinsmuxSubmissionRawValue -InputObject $committedReceipt -Name 'acknowledgement' -Default $null) `
                    -RunRecord $runner)) {
                $durableCommitValidated = $true
                $acknowledgementVerified = $true
                $submissionAccepted = $true
                return New-WinsmuxSubmissionReceipt -Kind $Kind -Status accepted -Backend $backend -SubmissionId $SubmissionId -Target $target -Acknowledgement $runner
            }
            return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId `
                -ReasonCode 'runner_evidence_invalid' -Target $target
        } catch {
            return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId `
                -ReasonCode 'runner_evidence_invalid' -Target $target
        } finally {
            if ($null -ne $ackServer) {
                Complete-WinsmuxSubmissionAcknowledgement -ServerState $ackServer -Verified $acknowledgementVerified | Out-Null
            }
            if (-not $submissionAccepted) {
                if (-not $durableCommitValidated -and -not [string]::IsNullOrWhiteSpace($adapterCreatedRunPath) -and
                    (Test-Path -LiteralPath $adapterCreatedRunPath -PathType Leaf)) {
                    Remove-Item -LiteralPath $adapterCreatedRunPath -Force -ErrorAction SilentlyContinue
                }
                if (-not [bool]$deliveryState['SubmissionCommitted']) {
                    Remove-Item -LiteralPath ([string]$packet.FullPath) -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } elseif ($backend -eq 'api_llm') {
        if ([string]::IsNullOrWhiteSpace($paneId)) {
            return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'pane_unavailable' -Target $target
        }
        $execCommand = "exec $($packet.RelativePath)"
        try {
            if ($null -ne $SendAction) { & $SendAction $paneId $execCommand | Out-Null }
            else {
                Send-TextToPane -PaneId $paneId -CommandText $execCommand `
                    -RuntimeProjectDir $ProjectDir -RuntimeOperation dispatch `
                    -ExpectedGenerationId $capturedGenerationId | Out-Null
            }
        } catch {
            return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'packet_repl_unavailable' -Diagnostic $_.Exception.Message -Target $target
        }
        $runner = if ($null -ne $RunResultAction) { & $RunResultAction $ProjectDir $label $SubmissionId } else { Get-WinsmuxSubmissionRunResult -ProjectDir $ProjectDir -SlotId $label -RunId $SubmissionId }
    } else {
        $runner = if ($null -ne $CliRunAction) { & $CliRunAction $ProjectDir $label $packet.RelativePath $SubmissionId $backend $Kind } else { Invoke-WinsmuxSubmissionCliRun -ProjectDir $ProjectDir -SlotId $label -PacketPath $packet.RelativePath -SubmissionId $SubmissionId -TaskId $TaskId -Backend $backend -Kind $Kind }
    }

    if (Test-WinsmuxSubmissionRunRecord -Record $runner -SubmissionId $SubmissionId -Kind $Kind -Backend $backend -ExpectedSlotId $label -ExpectedRequestDigest ([string]$packet.Packet.request_digest) -ExpectedTaskId ([string]$packet.Packet.task_id)) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status accepted -Backend $backend -SubmissionId $SubmissionId -Target $target -Acknowledgement $runner
    }
    $runnerStatus = [string](Get-WinsmuxSubmissionValue -InputObject $runner -Name 'status' -Default '')
    $runnerReason = [string](Get-WinsmuxSubmissionValue -InputObject $runner -Name 'reason' -Default '')
    $unavailableAllow = '^(backend_unavailable|cli_command_missing|cli_receipt_malformed|api_llm_runner_unconfigured|api_llm_api_key_env_missing|antigravity_runner_unconfigured|antigravity_cli_missing)$'
    $rejectedAllow = '^(runner_rejected_packet|runner_receipt_malformed|runner_acknowledgement_missing|backend_acknowledgement_missing|run_record_already_exists)$'
    if ($runnerStatus -in @('unavailable', 'blocked')) {
        $reasonCode = if ($runnerReason -cmatch $unavailableAllow) { $runnerReason } else { 'backend_unavailable' }
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode $reasonCode -Target $target
    }
    if (($null -eq $runner -or $runnerReason -eq 'runner_acknowledgement_missing') -and $backend -in @('local', 'codex')) {
        $runnerReason = 'backend_acknowledgement_missing'
    }
    $reasonCode = if ($runnerReason -cmatch $rejectedAllow) { $runnerReason } else { 'runner_evidence_invalid' }
    return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId -ReasonCode $reasonCode -Target $target
}
