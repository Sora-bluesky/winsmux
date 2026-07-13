$ErrorActionPreference = 'Stop'

$script:WinsmuxSubmissionProtocolVersion = 1
$script:WinsmuxSubmissionStatuses = @('accepted', 'rejected', 'unsupported', 'unavailable')
$script:WinsmuxSubmissionKinds = @('task', 'review')
$script:WinsmuxSubmissionBackends = @('local', 'codex', 'api_llm', 'antigravity', 'colab_cli', 'noop')
$script:WinsmuxSubmissionEvidenceTypes = @('backend_run_record')
$script:WinsmuxSubmissionRunStatuses = @('started', 'running', 'succeeded')
$script:WinsmuxSubmissionBridgeScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\winsmux-core.ps1'))

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
        [Parameter(Mandatory = $true)][string]$TargetLabel
    )

    if (-not (Test-WinsmuxSubmissionIdentifier -Value $SubmissionId)) {
        throw 'submission id contains unsupported characters'
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
        task_id          = $SubmissionId
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
    if ($runId -cne $submissionId -or $taskId -cne $submissionId) { return $false }
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

function New-WinsmuxSubmissionPacket {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)]$Content,
        [Parameter(Mandatory = $true)][string]$SubmissionId,
        [Parameter(Mandatory = $true)][string]$TargetLabel
    )

    $packet = New-WinsmuxSubmissionPacketData -Kind $Kind -Content $Content -SubmissionId $SubmissionId -TargetLabel $TargetLabel
    $relativePath = Join-Path (Join-Path '.winsmux' 'submissions') ($SubmissionId + '.json')
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectDir $relativePath))
    $directory = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($fullPath, ($packet | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    return [PSCustomObject]@{ FullPath = $fullPath; RelativePath = $relativePath; Packet = $packet }
}

function Read-WinsmuxSubmissionPacket {
    param([Parameter(Mandatory = $true)][string]$Path)

    $packet = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16
    if (-not (Test-WinsmuxSubmissionPacket -Packet $packet)) {
        throw 'submission packet is malformed or uses an unknown protocol version, kind, or id'
    }
    return $packet
}

function Read-WinsmuxSubmissionPacketIfPresent {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16
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
        [Parameter(Mandatory = $true)][ValidateSet('local', 'codex', 'api_llm', 'antigravity', 'colab_cli')][string]$Backend,
        [Parameter(Mandatory = $true)][ValidateSet('started', 'running', 'succeeded', 'failed')][string]$Status,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$RequestDigest,
        [switch]$RequestConsumed,
        [AllowEmptyString()][string]$Reason = ''
    )

    return [ordered]@{
        protocol_version = 1
        type             = 'backend_run_record'
        submission_id    = $SubmissionId
        run_id           = $RunId
        kind             = $Kind
        task_id          = $SubmissionId
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
        [string]$ExpectedRequestDigest = ''
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
        [string](Get-WinsmuxSubmissionValue -InputObject $Record -Name 'task_id' -Default '') -ceq $SubmissionId -and
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
    $allowedNames = @('type', 'protocol_version', 'status', 'submission_id', 'run_id', 'kind', 'backend', 'slot_id', 'worker_kind', 'request_digest')
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

function Test-WinsmuxSubmissionReceipt {
    param([AllowNull()]$Receipt)

    if ($null -eq $Receipt) { return $false }
    $version = Get-WinsmuxSubmissionRawValue -InputObject $Receipt -Name 'protocol_version' -Default $null
    if (-not (Test-WinsmuxSubmissionInteger -Value $version)) { return $false }
    $status = [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'status' -Default '')
    $kind = [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'kind' -Default '')
    $backend = [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'backend' -Default '')
    $submissionId = [string](Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'submission_id' -Default '')
    if (
        [int64]$version -ne 1 -or
        $status -cnotin $script:WinsmuxSubmissionStatuses -or
        $kind -cnotin $script:WinsmuxSubmissionKinds -or
        $backend -cnotin $script:WinsmuxSubmissionBackends -or
        -not (Test-WinsmuxSubmissionIdentifier -Value $submissionId)
    ) {
        return $false
    }
    if ($status -eq 'accepted') {
        $evidence = Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'acknowledgement' -Default $null
        $target = Get-WinsmuxSubmissionValue -InputObject $Receipt -Name 'target' -Default $null
        $targetLabel = [string](Get-WinsmuxSubmissionValue -InputObject $target -Name 'label' -Default '')
        if (-not (Test-WinsmuxSubmissionIdentifier -Value $targetLabel)) { return $false }
        return Test-WinsmuxPublicAcknowledgement -Acknowledgement $evidence -SubmissionId $submissionId -Kind $kind -Backend $backend -ExpectedSlotId $targetLabel
    }
    return $true
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
    [System.IO.File]::WriteAllText($runPath, ($Record | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
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
            try { return (Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16) }
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
        [Parameter(Mandatory = $true)][ValidateSet('local', 'codex')][string]$Backend
    )

    return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $Backend -SubmissionId $SubmissionId `
        -ReasonCode 'caller_identity_unavailable' -Target ([ordered]@{ label = $SlotId })
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
    try { return ($jsonLine[0] | ConvertFrom-Json -Depth 16) }
    catch { return [ordered]@{ status = 'unavailable'; reason = 'cli_receipt_malformed'; exit_code = 1 } }
}

function Invoke-WinsmuxSubmissionAdapter {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$ManifestEntry,
        [Parameter(Mandatory = $true)][ValidateSet('task', 'review')][string]$Kind,
        [Parameter(Mandatory = $true)]$Content,
        [string]$SubmissionId = ('submission-' + [guid]::NewGuid().ToString('N')),
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

    if (-not (Test-WinsmuxSubmissionIdentifier -Value $label)) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend noop -SubmissionId $SubmissionId -ReasonCode 'target_identifier_invalid' -Target $target
    }
    if ($backend -notin $script:WinsmuxSubmissionBackends -or $backend -eq 'noop') {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unsupported -Backend noop -SubmissionId $SubmissionId -ReasonCode 'backend_unsupported' -Target $target
    }

    $packet = New-WinsmuxSubmissionPacket -ProjectDir $ProjectDir -Kind $Kind -Content $Content -SubmissionId $SubmissionId -TargetLabel $label
    $existingRunPath = Get-WinsmuxSubmissionRunPath -ProjectDir $ProjectDir -SlotId $label -RunId $SubmissionId
    if (Test-Path -LiteralPath $existingRunPath -PathType Leaf) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'run_record_already_exists' -Target $target
    }
    if ($backend -in @('local', 'codex')) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'caller_identity_unavailable' -Target $target
    } elseif ($backend -eq 'api_llm') {
        if ([string]::IsNullOrWhiteSpace($paneId)) {
            return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'pane_unavailable' -Target $target
        }
        $execCommand = "exec $($packet.RelativePath)"
        try {
            if ($null -ne $SendAction) { & $SendAction $paneId $execCommand | Out-Null }
            else { Send-TextToPane -PaneId $paneId -CommandText $execCommand | Out-Null }
        } catch {
            return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode 'packet_repl_unavailable' -Diagnostic $_.Exception.Message -Target $target
        }
        $runner = if ($null -ne $RunResultAction) { & $RunResultAction $ProjectDir $label $SubmissionId } else { Get-WinsmuxSubmissionRunResult -ProjectDir $ProjectDir -SlotId $label -RunId $SubmissionId }
    } else {
        $runner = if ($null -ne $CliRunAction) { & $CliRunAction $ProjectDir $label $packet.RelativePath $SubmissionId $backend $Kind } else { Invoke-WinsmuxSubmissionCliRun -ProjectDir $ProjectDir -SlotId $label -PacketPath $packet.RelativePath -SubmissionId $SubmissionId -Backend $backend -Kind $Kind }
    }

    if (Test-WinsmuxSubmissionRunRecord -Record $runner -SubmissionId $SubmissionId -Kind $Kind -Backend $backend -ExpectedSlotId $label -ExpectedRequestDigest ([string]$packet.Packet.request_digest)) {
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status accepted -Backend $backend -SubmissionId $SubmissionId -Target $target -Acknowledgement $runner
    }
    $runnerStatus = [string](Get-WinsmuxSubmissionValue -InputObject $runner -Name 'status' -Default '')
    $runnerReason = [string](Get-WinsmuxSubmissionValue -InputObject $runner -Name 'reason' -Default '')
    if ($runnerStatus -eq 'unavailable' -or $runnerReason -match '^(backend_unavailable|cli_command_missing|.*_cli_missing|.*_runner_unconfigured|api_llm_api_key_env_missing)$') {
        if ([string]::IsNullOrWhiteSpace($runnerReason)) { $runnerReason = 'backend_unavailable' }
        return New-WinsmuxSubmissionReceipt -Kind $Kind -Status unavailable -Backend $backend -SubmissionId $SubmissionId -ReasonCode $runnerReason -Target $target
    }
    if (($null -eq $runner -or $runnerReason -eq 'runner_acknowledgement_missing') -and $backend -in @('local', 'codex')) {
        $runnerReason = 'backend_acknowledgement_missing'
    }
    if ([string]::IsNullOrWhiteSpace($runnerReason)) { $runnerReason = 'runner_evidence_invalid' }
    return New-WinsmuxSubmissionReceipt -Kind $Kind -Status rejected -Backend $backend -SubmissionId $SubmissionId -ReasonCode $runnerReason -Target $target
}
