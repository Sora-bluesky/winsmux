Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'json-compat.ps1')

$script:DeclarativeWorkflowIdPattern = '^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$'
$script:DeclarativeWorkflowGenerationIdPattern = '\A(?:[0-9a-f]{32}|[a-z][a-z0-9]*(?:-[a-z0-9]+)*)\z'
$script:DeclarativeWorkflowDigestPattern = '^sha256:[0-9a-f]{64}$'
$script:DeclarativeWorkflowHeadPattern = '^[0-9a-f]{40}$'
$script:DeclarativeWorkflowTaskLimit = 262144

function Get-DeclarativeWorkflowValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [Collections.IDictionary] -and $InputObject.Contains($Name)) {
        return $InputObject[$Name]
    }
    if ($null -ne $InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }
    return $Default
}

function Copy-DeclarativeWorkflowValue {
    param([Parameter(Mandatory = $true)]$Value)
    return [Management.Automation.PSSerializer]::Deserialize(
        [Management.Automation.PSSerializer]::Serialize($Value, 100)
    )
}

function Resolve-DeclarativeWorkflowNativeCommand {
    foreach ($configured in @($env:WINSMUX_RAW_EXE, $env:WINSMUX_BIN)) {
        if ([string]::IsNullOrWhiteSpace($configured)) { continue }
        if ([IO.Path]::IsPathRooted($configured) -and [IO.File]::Exists($configured)) {
            return [IO.Path]::GetFullPath($configured)
        }
        $configuredCommand = Get-Command $configured -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $configuredCommand) { throw 'workflow_state_reducer_unavailable' }
        $path = [string](Get-DeclarativeWorkflowValue $configuredCommand 'Source' '')
        if ([string]::IsNullOrWhiteSpace($path)) { $path = [string]$configuredCommand.Name }
        return $path
    }

    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    foreach ($candidate in @(
            (Join-Path $repoRoot 'target\release\winsmux.exe'),
            (Join-Path $repoRoot 'target\debug\winsmux.exe'))) {
        if ([IO.File]::Exists($candidate)) { return [IO.Path]::GetFullPath($candidate) }
    }
    $command = Get-Command winsmux -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { throw 'workflow_state_reducer_unavailable' }
    $commandPath = [string](Get-DeclarativeWorkflowValue $command 'Source' '')
    if ([string]::IsNullOrWhiteSpace($commandPath)) { $commandPath = [string]$command.Name }
    return $commandPath
}

function Invoke-DeclarativeWorkflowNativeReducerProcess {
    param([Parameter(Mandatory = $true)][string]$RequestPath)

    $nativeCommand = Resolve-DeclarativeWorkflowNativeCommand
    $output = @(& $nativeCommand '__workflow-state-reduce' '--request-file' $RequestPath 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'workflow_state_reducer_failed' }
        throw $text.Trim()
    }
    try {
        $snapshot = $text | ConvertFrom-WinsmuxJson -AsHashtable -Depth 100 -ErrorAction Stop
    } catch {
        throw 'workflow_state_reducer_invalid_output'
    }
    if ($snapshot -isnot [Collections.IDictionary]) { throw 'workflow_state_reducer_invalid_output' }
    return $snapshot
}

function Invoke-DeclarativeWorkflowStateReducer {
    param([Parameter(Mandatory = $true)]$Request)

    $json = $Request | ConvertTo-Json -Compress -Depth 100
    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    if ($bytes.Length -gt 1048576 -or [Array]::IndexOf($bytes, [byte]0) -ge 0) {
        throw 'workflow_state_reducer_request_invalid'
    }

    $requestDirectory = Join-Path ([IO.Path]::GetTempPath()) ('winsmux-workflow-reducer-' + [guid]::NewGuid().ToString('N'))
    $requestPath = Join-Path $requestDirectory 'request.json'
    [IO.Directory]::CreateDirectory($requestDirectory) | Out-Null
    try {
        $stream = [IO.File]::Open($requestPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        return Invoke-DeclarativeWorkflowNativeReducerProcess -RequestPath $requestPath
    } finally {
        if ([IO.File]::Exists($requestPath)) { [IO.File]::Delete($requestPath) }
        if ([IO.Directory]::Exists($requestDirectory)) { [IO.Directory]::Delete($requestDirectory, $false) }
    }
}

function Invoke-DeclarativeWorkflowTransition {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$Event,
        $DurableProofs = $null
    )
    if ($null -eq $DurableProofs) {
        $DurableProofs = [ordered]@{ completion_acknowledgements = @(); cancellation_proofs = @() }
    }
    return Invoke-DeclarativeWorkflowStateReducer -Request ([ordered]@{
            schema_version = 1
            operation      = 'transition'
            run            = $Run
            event          = $Event
            durable_proofs = $DurableProofs
        })
}

function Resolve-DeclarativeWorkflowDurableProofs {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [scriptblock]$ResolveAcknowledgement,
        [scriptblock]$ResolveCancellation
    )

    $acknowledgements = [Collections.Generic.List[object]]::new()
    foreach ($entry in $Run.nodes.GetEnumerator()) {
        if ([string](Get-DeclarativeWorkflowValue $entry.Value 'state' '') -cne 'succeeded') { continue }
        if ($null -eq $ResolveAcknowledgement) { throw 'workflow_state_invalid: external durable completion proof required' }
        $nodeId = [string]$entry.Key
        $raw = @(& $ResolveAcknowledgement $Run $nodeId)
        $candidates = @(Resolve-DeclarativeWorkflowAcknowledgementCandidates -Run $Run -NodeId $nodeId -Acknowledgements $raw)
        if ($candidates.Count -ne 1 -or
            -not (Test-DeclarativeWorkflowAcknowledgement -Run $Run -NodeId $nodeId -Acknowledgement $candidates[0])) {
            throw 'workflow_state_invalid: external durable completion proof required'
        }
        $acknowledgements.Add($candidates[0]) | Out-Null
    }

    $cancellations = @()
    $hasCancellation = $null -ne (Get-DeclarativeWorkflowValue $Run 'cancellation_proof' $null) -or
        [string](Get-DeclarativeWorkflowValue $Run 'state' '') -ceq 'cancelled'
    if ($hasCancellation) {
        if ($null -eq $ResolveCancellation) { throw 'workflow_state_invalid: external durable cancellation proof required' }
        $cancellations = @(& $ResolveCancellation $Run)
        if ($cancellations.Count -ne 1 -or $null -eq $cancellations[0]) {
            throw 'workflow_state_invalid: external durable cancellation proof required'
        }
    }
    return [ordered]@{
        completion_acknowledgements = @($acknowledgements)
        cancellation_proofs         = @($cancellations)
    }
}

function Assert-DeclarativeWorkflowId {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Value)
    if ($Value -cnotmatch $script:DeclarativeWorkflowIdPattern) {
        throw "$Name must be a stable lowercase ASCII identifier."
    }
}

function Assert-DeclarativeWorkflowGenerationId {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Value)
    if ($Value -cnotmatch $script:DeclarativeWorkflowGenerationIdPattern) {
        throw "$Name must be a managed lowercase GUID-N or legacy stable identifier."
    }
}

function Get-DeclarativeWorkflowSha256Digest {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        [byte[]]$hash = $algorithm.ComputeHash($Bytes)
    } finally {
        $algorithm.Dispose()
    }

    $hex = [Text.StringBuilder]::new($hash.Length * 2)
    foreach ($byte in $hash) {
        [void]$hex.Append(([byte]$byte).ToString('x2'))
    }
    return 'sha256:' + $hex.ToString()
}

function Read-DeclarativeWorkflowTaskFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) {
        throw 'Declarative workflow task file is missing or unreadable.'
    }
    try {
        [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    } catch {
        throw 'Declarative workflow task file is missing or unreadable.'
    }
    if ($bytes.Length -gt $script:DeclarativeWorkflowTaskLimit) {
        throw "Declarative workflow task file exceeds $($script:DeclarativeWorkflowTaskLimit) bytes."
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'Declarative workflow task file must be UTF-8 without BOM.'
    }
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) {
        throw 'Declarative workflow task file must not contain NUL.'
    }
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } catch {
        throw 'Declarative workflow task file must contain valid UTF-8.'
    }
    return [PSCustomObject]@{
        Text      = $text
        ByteCount = [int64]$bytes.Length
        Sha256    = Get-DeclarativeWorkflowSha256Digest -Bytes $bytes
    }
}

function Assert-DeclarativeWorkflowTaskIdentity {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$TaskInput
    )
    $expectedDigest = [string](Get-DeclarativeWorkflowValue $Run 'task_sha256' '')
    $expectedBytes = [int64](Get-DeclarativeWorkflowValue $Run 'task_byte_count' -1)
    $actualDigest = [string](Get-DeclarativeWorkflowValue $TaskInput 'Sha256' '')
    $actualBytes = [int64](Get-DeclarativeWorkflowValue $TaskInput 'ByteCount' -1)
    if ($expectedDigest -cne $actualDigest -or $expectedBytes -ne $actualBytes) {
        throw 'Declarative workflow task identity does not match the persisted digest and byte count.'
    }
}

function Assert-DeclarativeWorkflowConfirmation {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$Confirmation
    )
    foreach ($field in @('run_id', 'generation_id', 'config_fingerprint', 'source_head')) {
        $expected = [string](Get-DeclarativeWorkflowValue $Run $field '')
        $actual = [string](Get-DeclarativeWorkflowValue $Confirmation $field '')
        if ([string]::IsNullOrWhiteSpace($actual) -or $actual -cne $expected) {
            throw 'Declarative workflow confirmation tuple does not match the current run.'
        }
    }
}

function ConvertTo-DeclarativeWorkflowCanonicalValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $normalized = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            $normalized[$key] = ConvertTo-DeclarativeWorkflowCanonicalValue -Value $Value[$key]
        }
        return $normalized
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-DeclarativeWorkflowCanonicalValue -Value $_ })
    }
    if ($null -ne $Value.PSObject -and $Value -isnot [string] -and $Value -isnot [ValueType]) {
        $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property') })
        if ($properties.Count -gt 0) {
            $normalized = [ordered]@{}
            foreach ($property in @($properties | Sort-Object Name)) {
                $normalized[[string]$property.Name] = ConvertTo-DeclarativeWorkflowCanonicalValue -Value $property.Value
            }
            return $normalized
        }
    }
    return $Value
}

function ConvertTo-DeclarativeWorkflowCanonicalJson {
    param([AllowNull()]$Value)

    return (ConvertTo-DeclarativeWorkflowCanonicalValue -Value $Value) | ConvertTo-Json -Compress -Depth 32
}

function Assert-DeclarativeWorkflowSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$WorkflowFingerprint,
        [Parameter(Mandatory = $true)][string]$ConfigFingerprint,
        [Parameter(Mandatory = $true)]$ResolvedBindings
    )

    if (
        [string](Get-DeclarativeWorkflowValue $Run 'workflow_fingerprint' '') -cne $WorkflowFingerprint -or
        [string](Get-DeclarativeWorkflowValue $Run 'config_fingerprint' '') -cne $ConfigFingerprint -or
        (ConvertTo-DeclarativeWorkflowCanonicalJson -Value (Get-DeclarativeWorkflowValue $Run 'resolved_bindings' ([ordered]@{}))) -cne
            (ConvertTo-DeclarativeWorkflowCanonicalJson -Value $ResolvedBindings)
    ) {
        throw 'Declarative workflow snapshot does not match the persisted workflow, configuration, and bindings.'
    }
}

function Test-DeclarativeWorkflowFieldExists {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [Collections.IDictionary]) { return $InputObject.Contains($Name) }
    return ($null -ne $InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains $Name)
}

function New-DeclarativeWorkflowExecutionProjection {
    param([Parameter(Mandatory = $true)]$Plan)

    $definitions = @(Get-DeclarativeWorkflowValue $Plan 'nodes' @())
    if ($definitions.Count -lt 1) { throw 'Normalized workflow must contain at least one node.' }

    $nodeOrder = [Collections.Generic.List[string]]::new()
    $runtimeNodes = [ordered]@{}
    foreach ($definition in $definitions) {
        foreach ($field in @('node_id', 'action', 'pane_ref', 'depends_on', 'idempotency_key', 'cleanup')) {
            if (-not (Test-DeclarativeWorkflowFieldExists -InputObject $definition -Name $field)) {
                throw "Normalized workflow node is missing immutable field '$field'."
            }
        }
        $nodeId = [string](Get-DeclarativeWorkflowValue $definition 'node_id' '')
        Assert-DeclarativeWorkflowId -Name 'node_id' -Value $nodeId
        if ($runtimeNodes.Contains($nodeId)) { throw "Duplicate normalized node '$nodeId'." }

        $dependencies = @((Get-DeclarativeWorkflowValue $definition 'depends_on' @()) | ForEach-Object {
                $dependencyId = [string]$_
                Assert-DeclarativeWorkflowId -Name 'dependency node_id' -Value $dependencyId
                $dependencyId
            })
        $contextPackValue = Get-DeclarativeWorkflowValue $definition 'context_pack_ref' $null
        $contextPackRef = if ($null -eq $contextPackValue) { $null } else { [string]$contextPackValue }
        if ($null -ne $contextPackRef -and -not [string]::IsNullOrWhiteSpace($contextPackRef) -and
            -not (Test-DeclarativeWorkflowBoundedReference -Value $contextPackRef)) {
            throw 'context_pack_ref must be a bounded reference, not inline context content.'
        }

        $runtimeNodes[$nodeId] = [ordered]@{
            node_id         = $nodeId
            action          = [string](Get-DeclarativeWorkflowValue $definition 'action' '')
            pane_ref        = [string](Get-DeclarativeWorkflowValue $definition 'pane_ref' '')
            depends_on      = @($dependencies)
            idempotency_key = [string](Get-DeclarativeWorkflowValue $definition 'idempotency_key' '')
            cleanup         = [string](Get-DeclarativeWorkflowValue $definition 'cleanup' '')
            context_pack_ref = $contextPackRef
        }
        $nodeOrder.Add($nodeId) | Out-Null
    }

    return [ordered]@{
        normalized_snapshot = Copy-DeclarativeWorkflowValue $Plan
        node_order          = @($nodeOrder)
        runtime_nodes       = $runtimeNodes
    }
}

function Assert-DeclarativeWorkflowExecutionProjection {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$Plan
    )

    $expected = New-DeclarativeWorkflowExecutionProjection -Plan $Plan
    $persistedSnapshot = Get-DeclarativeWorkflowValue $Run 'normalized_snapshot' $null
    if ((ConvertTo-DeclarativeWorkflowCanonicalJson -Value $persistedSnapshot) -cne
        (ConvertTo-DeclarativeWorkflowCanonicalJson -Value $expected.normalized_snapshot)) {
        throw 'Declarative workflow execution projection normalized snapshot does not match the current normalized workflow.'
    }

    $persistedOrder = @(Get-DeclarativeWorkflowValue $Run 'node_order' @()) | ForEach-Object { [string]$_ }
    $expectedOrder = @($expected.node_order | ForEach-Object { [string]$_ })
    if ($persistedOrder.Count -ne $expectedOrder.Count) {
        throw 'Declarative workflow execution projection node order does not match the normalized workflow.'
    }
    for ($index = 0; $index -lt $expectedOrder.Count; $index++) {
        if ($persistedOrder[$index] -cne $expectedOrder[$index]) {
            throw 'Declarative workflow execution projection node order does not match the normalized workflow.'
        }
    }

    $persistedNodes = Get-DeclarativeWorkflowValue $Run 'nodes' $null
    if ($null -eq $persistedNodes -or $persistedNodes -isnot [Collections.IDictionary]) {
        throw 'Declarative workflow execution projection runtime nodes are missing.'
    }
    $persistedIds = @($persistedNodes.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    $expectedIds = @($expected.runtime_nodes.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    if ($persistedIds.Count -ne $expectedIds.Count -or
        @($persistedIds | Where-Object { $_ -notin $expectedIds }).Count -ne 0) {
        throw 'Declarative workflow execution projection runtime node set does not match the normalized workflow.'
    }

    foreach ($nodeId in $expectedOrder) {
        $persistedNode = $persistedNodes[$nodeId]
        $expectedNode = $expected.runtime_nodes[$nodeId]
        foreach ($field in @('node_id', 'action', 'pane_ref', 'depends_on', 'idempotency_key', 'cleanup', 'context_pack_ref')) {
            $persistedValue = if ($field -ceq 'depends_on') {
                @((Get-DeclarativeWorkflowValue $persistedNode $field @()))
            } else {
                Get-DeclarativeWorkflowValue $persistedNode $field $null
            }
            $expectedValue = if ($field -ceq 'depends_on') { @($expectedNode[$field]) } else { $expectedNode[$field] }
            $fieldRequired = $field -cne 'context_pack_ref' -or $null -ne $expectedValue
            if (($fieldRequired -and -not (Test-DeclarativeWorkflowFieldExists -InputObject $persistedNode -Name $field)) -or
                (ConvertTo-DeclarativeWorkflowCanonicalJson -Value $persistedValue) -cne
                    (ConvertTo-DeclarativeWorkflowCanonicalJson -Value $expectedValue)) {
                throw "Declarative workflow execution projection immutable field '$field' does not match node '$nodeId'."
            }
        }
    }
}

function New-DeclarativeWorkflowRun {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$GenerationId,
        [Parameter(Mandatory = $true)][string]$ConfigFingerprint,
        [Parameter(Mandatory = $true)][string]$SourceHead,
        [Parameter(Mandatory = $true)]$TaskInput
    )
    Assert-DeclarativeWorkflowId -Name 'run_id' -Value $RunId
    Assert-DeclarativeWorkflowGenerationId -Name 'generation_id' -Value $GenerationId
    if ($SourceHead -cnotmatch $script:DeclarativeWorkflowHeadPattern) {
        throw 'source_head must be a lowercase full commit ID.'
    }
    if ($ConfigFingerprint -cnotmatch $script:DeclarativeWorkflowDigestPattern) {
        throw 'config_fingerprint must be a lowercase SHA-256 digest.'
    }
    $workflowFingerprint = [string](Get-DeclarativeWorkflowValue $Plan 'workflow_fingerprint' '')
    if ($workflowFingerprint -cnotmatch $script:DeclarativeWorkflowDigestPattern) {
        throw 'workflow_fingerprint must be a lowercase SHA-256 digest.'
    }
    $taskDigest = [string](Get-DeclarativeWorkflowValue $TaskInput 'Sha256' '')
    $taskByteCount = [int64](Get-DeclarativeWorkflowValue $TaskInput 'ByteCount' -1)
    if ($taskDigest -cnotmatch $script:DeclarativeWorkflowDigestPattern -or $taskByteCount -lt 0) {
        throw 'Task input identity is invalid.'
    }
    return Invoke-DeclarativeWorkflowStateReducer -Request ([ordered]@{
            schema_version = 1
            operation      = 'bootstrap'
            plan           = Copy-DeclarativeWorkflowValue $Plan
            identity       = [ordered]@{
                run_id             = $RunId
                generation_id      = $GenerationId
                config_fingerprint = $ConfigFingerprint
                source_head        = $SourceHead
                task_sha256        = $taskDigest
                task_byte_count    = $taskByteCount
            }
        })
}

function Get-DeclarativeWorkflowNode {
    param([Parameter(Mandatory = $true)]$Run, [Parameter(Mandatory = $true)][string]$NodeId)
    $nodes = Get-DeclarativeWorkflowValue $Run 'nodes' $null
    if ($null -eq $nodes -or -not $nodes.Contains($NodeId)) { throw "Unknown workflow node '$NodeId'." }
    return $nodes[$NodeId]
}

function Test-DeclarativeWorkflowBoundedReference {
    param([AllowNull()][string]$Value)

    return (-not [string]::IsNullOrWhiteSpace($Value) -and
        $Value.Length -le 256 -and
        $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]*$')
}

function Get-DeclarativeWorkflowVerificationEnvelope {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$NodeId
    )

    $node = Get-DeclarativeWorkflowNode -Run $Run -NodeId $NodeId
    if ([string](Get-DeclarativeWorkflowValue $node 'action' '') -cne 'verification') {
        return $null
    }

    $contextPackRef = [string](Get-DeclarativeWorkflowValue $node 'context_pack_ref' '')
    $dependencyNodeIds = @((Get-DeclarativeWorkflowValue $node 'depends_on' @()) | ForEach-Object { [string]$_ })
    if (-not (Test-DeclarativeWorkflowBoundedReference -Value $contextPackRef) -or $dependencyNodeIds.Count -lt 1) {
        return $null
    }

    $nodes = Get-DeclarativeWorkflowValue $Run 'nodes' $null
    if ($null -eq $nodes) { return $null }
    $seenNodes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenEvidence = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $evidenceRefs = [Collections.Generic.List[string]]::new()
    $runId = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')

    foreach ($dependencyNodeId in $dependencyNodeIds) {
        if ([string]::IsNullOrWhiteSpace($dependencyNodeId) -or -not $seenNodes.Add($dependencyNodeId) -or -not $nodes.Contains($dependencyNodeId)) {
            return $null
        }
        $dependencyNode = $nodes[$dependencyNodeId]
        if ([string](Get-DeclarativeWorkflowValue $dependencyNode 'state' '') -cne 'succeeded') {
            return $null
        }
        $expectedEvidenceRef = "workflow-ack:$runId`:$dependencyNodeId"
        $dependencyEvidenceRefs = @((Get-DeclarativeWorkflowValue $dependencyNode 'evidence_refs' @()) | ForEach-Object { [string]$_ })
        if ($dependencyEvidenceRefs.Count -lt 1) { return $null }
        foreach ($evidenceRef in $dependencyEvidenceRefs) {
            if ($evidenceRef -cne $expectedEvidenceRef -or -not $seenEvidence.Add($evidenceRef)) {
                return $null
            }
            $evidenceRefs.Add($evidenceRef) | Out-Null
        }
    }

    return [PSCustomObject]@{
        context_pack_ref    = $contextPackRef
        dependency_node_ids = @($dependencyNodeIds)
        evidence_refs       = @($evidenceRefs)
    }
}

function Test-DeclarativeWorkflowSessionId {
    param([AllowNull()][string]$Value)
    return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -cmatch '^%[0-9]+$')
}

function Test-DeclarativeWorkflowAcknowledgement {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$NodeId,
        [AllowNull()]$Acknowledgement
    )
    if ($null -eq $Acknowledgement) { return $false }
    $node = Get-DeclarativeWorkflowNode -Run $Run -NodeId $NodeId
    $expected = [ordered]@{
        schema_version     = '1'
        run_id             = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
        node_id            = $NodeId
        idempotency_key    = [string](Get-DeclarativeWorkflowValue $node 'idempotency_key' '')
        generation_id      = [string](Get-DeclarativeWorkflowValue $Run 'generation_id' '')
        config_fingerprint = [string](Get-DeclarativeWorkflowValue $Run 'config_fingerprint' '')
        workflow_fingerprint = [string](Get-DeclarativeWorkflowValue $Run 'workflow_fingerprint' '')
        source_head        = [string](Get-DeclarativeWorkflowValue $Run 'source_head' '')
        status             = 'succeeded'
        evidence_ref       = "workflow-ack:$([string](Get-DeclarativeWorkflowValue $Run 'run_id' '')):$NodeId"
    }
    $propertyNames = if ($Acknowledgement -is [Collections.IDictionary]) {
        @($Acknowledgement.Keys | ForEach-Object { [string]$_ })
    } else {
        @($Acknowledgement.PSObject.Properties.Name)
    }
    $requiredNames = @($expected.Keys) + @('pane_id')
    $allowedNames = @($requiredNames) + @('transport', 'message_id')
    if (@($propertyNames | Where-Object { $_ -notin $allowedNames }).Count -ne 0 -or
        @($requiredNames | Where-Object { $_ -notin $propertyNames }).Count -ne 0) {
        return $false
    }
    foreach ($entry in $expected.GetEnumerator()) {
        if ([string](Get-DeclarativeWorkflowValue $Acknowledgement ([string]$entry.Key) '') -cne [string]$entry.Value) {
            return $false
        }
    }
    $transport = Get-DeclarativeWorkflowValue $Acknowledgement 'transport' $null
    if ($null -ne $transport -and [string]$transport -cne 'mailbox') { return $false }
    $messageId = [string](Get-DeclarativeWorkflowValue $Acknowledgement 'message_id' '')
    if (-not [string]::IsNullOrWhiteSpace($messageId) -and $messageId -cnotmatch '^[a-z][a-z0-9-]{0,127}$') { return $false }
    return (Test-DeclarativeWorkflowSessionId ([string](Get-DeclarativeWorkflowValue $Acknowledgement 'pane_id' '')))
}

function Get-DeclarativeWorkflowCompletionProofAdmissionError {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$NodeId,
        [Parameter(Mandatory = $true)]$Proof,
        [AllowEmptyString()][string]$TrustedSenderLabel = '',
        [AllowEmptyString()][string]$TrustedSenderPaneId = ''
    )

    $nodes = Get-DeclarativeWorkflowValue $Run 'nodes' $null
    if ($null -eq $nodes -or $nodes -isnot [Collections.IDictionary] -or -not $nodes.Contains($NodeId)) {
        return 'unknown node'
    }
    $node = $nodes[$NodeId]
    if ([string](Get-DeclarativeWorkflowValue $node 'state' '') -notin @('dispatching', 'blocked')) {
        return 'node is not awaiting completion'
    }
    if ([int](Get-DeclarativeWorkflowValue $node 'attempt' 0) -lt 1) {
        return 'node has no dispatch attempt'
    }
    if ([string]::IsNullOrWhiteSpace($TrustedSenderLabel) -or [string]::IsNullOrWhiteSpace($TrustedSenderPaneId)) {
        return 'trusted sender identity is missing'
    }
    $bindings = Get-DeclarativeWorkflowValue $Run 'resolved_bindings' $null
    $paneRef = [string](Get-DeclarativeWorkflowValue $node 'pane_ref' '')
    if ($null -eq $bindings -or $bindings -isnot [Collections.IDictionary] -or
        [string]::IsNullOrWhiteSpace($paneRef) -or -not $bindings.Contains($paneRef) -or
        [string]$bindings[$paneRef] -cne $TrustedSenderLabel) {
        return 'sender is not assigned to the node'
    }
    if ([string](Get-DeclarativeWorkflowValue $Proof 'pane_id' '') -cne $TrustedSenderPaneId) {
        return 'proof pane does not match the authenticated sender'
    }
    if (-not (Test-DeclarativeWorkflowAcknowledgement -Run $Run -NodeId $NodeId -Acknowledgement $Proof)) {
        return 'completion tuple does not match the existing run'
    }
    return $null
}

function Resolve-DeclarativeWorkflowAcknowledgementCandidates {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$NodeId,
        [AllowNull()][object[]]$Acknowledgements = @()
    )

    $node = Get-DeclarativeWorkflowNode -Run $Run -NodeId $NodeId
    $runId = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
    $expectedKey = [string](Get-DeclarativeWorkflowValue $node 'idempotency_key' '')
    $seen = [ordered]@{}
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($acknowledgement in @($Acknowledgements)) {
        if ($null -eq $acknowledgement -or
            [string](Get-DeclarativeWorkflowValue $acknowledgement 'run_id' '') -cne $runId -or
            [string](Get-DeclarativeWorkflowValue $acknowledgement 'node_id' '') -cne $NodeId -or
            [string](Get-DeclarativeWorkflowValue $acknowledgement 'idempotency_key' '') -cne $expectedKey) {
            continue
        }
        $propertyNames = if ($acknowledgement -is [Collections.IDictionary]) {
            @($acknowledgement.Keys | ForEach-Object { [string]$_ } | Sort-Object)
        } else {
            @($acknowledgement.PSObject.Properties.Name | ForEach-Object { [string]$_ } | Sort-Object)
        }
        $normalized = [ordered]@{}
        foreach ($name in $propertyNames) {
            $normalized[$name] = Get-DeclarativeWorkflowValue $acknowledgement $name $null
        }
        $identity = ConvertTo-DeclarativeWorkflowCanonicalJson -Value $normalized
        if (-not $seen.Contains($identity)) {
            $seen[$identity] = $true
            $candidates.Add($acknowledgement) | Out-Null
        }
    }
    foreach ($candidate in $candidates) {
        Write-Output $candidate
    }
}

function Get-DeclarativeWorkflowCompletionAcknowledgement {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$NodeId,
        [AllowNull()]$Completion
    )
    if ($null -eq $Completion -or [string](Get-DeclarativeWorkflowValue $Completion 'status' '') -cne 'accepted') { return $null }
    $acknowledgement = Get-DeclarativeWorkflowValue $Completion 'acknowledgement' $null
    if (-not (Test-DeclarativeWorkflowAcknowledgement -Run $Run -NodeId $NodeId -Acknowledgement $acknowledgement)) { return $null }
    $paneId = [string](Get-DeclarativeWorkflowValue $acknowledgement 'pane_id' '')
    $targetPaneId = [string](Get-DeclarativeWorkflowValue (Get-DeclarativeWorkflowValue $Completion 'target' $null) 'pane_id' '')
    $evidenceRefs = @((Get-DeclarativeWorkflowValue $Completion 'evidence_refs' @()) | ForEach-Object { [string]$_ })
    $expectedEvidenceRef = [string](Get-DeclarativeWorkflowValue $acknowledgement 'evidence_ref' '')
    if ($targetPaneId -cne $paneId -or $evidenceRefs.Count -ne 1 -or $evidenceRefs[0] -cne $expectedEvidenceRef) { return $null }
    return $acknowledgement
}

function Invoke-DeclarativeWorkflowNode {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$NodeId,
        [Parameter(Mandatory = $true)]$TaskInput,
        [Parameter(Mandatory = $true)]$Confirmation,
        [Parameter(Mandatory = $true)][scriptblock]$SaveRun,
        [Parameter(Mandatory = $true)][scriptblock]$Dispatch,
        [Parameter(Mandatory = $true)][scriptblock]$ResolveSession,
        $DurableProofs = $null
    )
    Assert-DeclarativeWorkflowTaskIdentity -Run $Run -TaskInput $TaskInput
    Assert-DeclarativeWorkflowConfirmation -Run $Run -Confirmation $Confirmation
    $candidate = Invoke-DeclarativeWorkflowTransition -Run $Run -Event ([ordered]@{ type = 'validate' }) -DurableProofs $DurableProofs
    $runState = [string](Get-DeclarativeWorkflowValue $candidate 'state' '')
    if ($runState -in @('succeeded', 'cancelled', 'rolled_back')) {
        throw "Declarative workflow terminal run '$runState' cannot resume."
    }
    if ($runState -ceq 'failed') {
        throw 'Declarative workflow failed run requires a new operator-approved run.'
    }
    $current = Get-DeclarativeWorkflowNode -Run $candidate -NodeId $NodeId
    $currentState = [string](Get-DeclarativeWorkflowValue $current 'state' '')
    if ($currentState -ceq 'succeeded') { return $candidate }
    if ($currentState -cne 'ready') {
        throw "Workflow node '$NodeId' is not ready for dispatch."
    }
    if ([int](Get-DeclarativeWorkflowValue $current 'attempt' 0) -ne 0) {
        throw "Workflow node '$NodeId' cannot be retried automatically."
    }

    $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'dispatch_intent'; node_id = $NodeId }) -DurableProofs $DurableProofs
    & $SaveRun $candidate
    $node = Get-DeclarativeWorkflowNode -Run $candidate -NodeId $NodeId

    $stage = if ([string](Get-DeclarativeWorkflowValue $node 'action' '') -ceq 'verification') { 'VERIFY' } else { 'EXEC' }
    $request = [ordered]@{
        stage       = $stage
        node_id     = $NodeId
        pane_ref    = [string](Get-DeclarativeWorkflowValue $node 'pane_ref' '')
        task        = [string](Get-DeclarativeWorkflowValue $TaskInput 'Text' '')
        evidence_refs = @()
    }
    if ($stage -ceq 'VERIFY') {
        $verificationEnvelope = Get-DeclarativeWorkflowVerificationEnvelope -Run $candidate -NodeId $NodeId
        if ($null -eq $verificationEnvelope) {
            $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'block'; node_id = $NodeId }) -DurableProofs $DurableProofs
            & $SaveRun $candidate
            return $candidate
        }
        $request.context_pack_ref = [string]$verificationEnvelope.context_pack_ref
        $request.dependency_node_ids = @($verificationEnvelope.dependency_node_ids)
        $request.evidence_refs = @($verificationEnvelope.evidence_refs)
    }
    try {
        $completion = & $Dispatch $request $candidate
    } catch {
        $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'block'; node_id = $NodeId }) -DurableProofs $DurableProofs
        & $SaveRun $candidate
        return $candidate
    }
    if ($null -eq $completion) {
        $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'block'; node_id = $NodeId }) -DurableProofs $DurableProofs
        & $SaveRun $candidate
        return $candidate
    }
    $completionStatus = [string](Get-DeclarativeWorkflowValue $completion 'status' '')
    if ($completionStatus -cne 'accepted') {
        $eventType = if ($completionStatus -in @('failed', 'rejected')) { 'dispatch_failed' } else { 'block' }
        $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = $eventType; node_id = $NodeId }) -DurableProofs $DurableProofs
        & $SaveRun $candidate
        return $candidate
    }
    $acknowledgement = Get-DeclarativeWorkflowCompletionAcknowledgement -Run $candidate -NodeId $NodeId -Completion $completion
    if ($null -eq $acknowledgement) {
        $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'block'; node_id = $NodeId }) -DurableProofs $DurableProofs
        & $SaveRun $candidate
        return $candidate
    }
    $paneId = [string](Get-DeclarativeWorkflowValue $acknowledgement 'pane_id' '')
    $sessionId = [string](& $ResolveSession $paneId)
    if (-not (Test-DeclarativeWorkflowSessionId $sessionId) -or
        $sessionId -cne $paneId) {
        $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'block'; node_id = $NodeId }) -DurableProofs $DurableProofs
        & $SaveRun $candidate
        return $candidate
    }

    $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{
            type                = 'acknowledge'
            node_id             = $NodeId
            acknowledgement     = $acknowledgement
            resolved_session_id = $sessionId
        }) -DurableProofs $DurableProofs
    & $SaveRun $candidate
    return $candidate
}

function Invoke-DeclarativeWorkflowResume {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$TaskInput,
        [Parameter(Mandatory = $true)]$Confirmation,
        [Parameter(Mandatory = $true)][scriptblock]$SaveRun,
        [Parameter(Mandatory = $true)][scriptblock]$Dispatch,
        [Parameter(Mandatory = $true)][scriptblock]$ResolveSession,
        [Parameter(Mandatory = $true)][scriptblock]$ResolveAcknowledgement,
        [scriptblock]$ResolveCancellation,
        [scriptblock]$ValidateSnapshot
    )
    Assert-DeclarativeWorkflowTaskIdentity -Run $Run -TaskInput $TaskInput
    Assert-DeclarativeWorkflowConfirmation -Run $Run -Confirmation $Confirmation
    $candidate = $Run
    $snapshotPending = $null -ne $ValidateSnapshot
    $initialValidation = $true

    while ($true) {
        $durableProofs = Resolve-DeclarativeWorkflowDurableProofs -Run $candidate -ResolveAcknowledgement $ResolveAcknowledgement -ResolveCancellation $ResolveCancellation
        $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'validate' }) -DurableProofs $durableProofs
        $runState = [string](Get-DeclarativeWorkflowValue $candidate 'state' '')
        if ($runState -in @('succeeded', 'cancelled', 'rolled_back')) {
            if ($initialValidation) {
                throw "Declarative workflow terminal run '$runState' cannot resume."
            }
            return $candidate
        }
        $initialValidation = $false
        if ($snapshotPending) {
            & $ValidateSnapshot $candidate
            $snapshotPending = $false
        }
        if ($runState -ceq 'failed') { return $candidate }

        $failed = @($candidate.nodes.GetEnumerator() | Where-Object {
                [string](Get-DeclarativeWorkflowValue $_.Value 'state' '') -ceq 'failed'
            } | Select-Object -First 1)
        if ($failed.Count -gt 0) { return $candidate }

        $inFlight = @($candidate.nodes.GetEnumerator() | Where-Object {
                [string](Get-DeclarativeWorkflowValue $_.Value 'state' '') -in @('dispatching', 'blocked')
            } | Select-Object -First 1)
        if ($inFlight.Count -gt 0) {
            $nodeId = [string]$inFlight[0].Key
            $nodeState = [string](Get-DeclarativeWorkflowValue $inFlight[0].Value 'state' '')
            $rawAcknowledgements = @(& $ResolveAcknowledgement $candidate $nodeId)
            $acknowledgements = @(Resolve-DeclarativeWorkflowAcknowledgementCandidates -Run $candidate -NodeId $nodeId -Acknowledgements $rawAcknowledgements)
            if ($acknowledgements.Count -ne 1 -or
                -not (Test-DeclarativeWorkflowAcknowledgement -Run $candidate -NodeId $nodeId -Acknowledgement $acknowledgements[0])) {
                if ($nodeState -ceq 'dispatching') {
                    $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'block'; node_id = $nodeId }) -DurableProofs $durableProofs
                    & $SaveRun $candidate
                }
                return $candidate
            }
            $acknowledgement = $acknowledgements[0]
            # Completion proofs have already passed publisher-side caller authentication and
            # immutable admission.  Resume must retain that original execution identity even
            # when the completed pane no longer exists in the current runtime registry.
            $resolvedSession = [string](Get-DeclarativeWorkflowValue $acknowledgement 'pane_id' '')
            $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{
                    type                = 'acknowledge'
                    node_id             = $nodeId
                    acknowledgement     = $acknowledgement
                    resolved_session_id = $resolvedSession
                }) -DurableProofs $durableProofs
            & $SaveRun $candidate
            continue
        }

        $ready = @($candidate.nodes.GetEnumerator() | Where-Object {
                [string](Get-DeclarativeWorkflowValue $_.Value 'state' '') -ceq 'ready'
            } | Select-Object -First 1)
        if ($ready.Count -eq 0) { return $candidate }
        $candidate = Invoke-DeclarativeWorkflowNode -Run $candidate -NodeId ([string]$ready[0].Key) -TaskInput $TaskInput `
            -Confirmation $Confirmation -SaveRun $SaveRun -Dispatch $Dispatch -ResolveSession $ResolveSession -DurableProofs $durableProofs
        if ([string](Get-DeclarativeWorkflowValue $candidate 'state' '') -in @('blocked', 'failed')) { return $candidate }
    }
}

function Get-DeclarativeWorkflowRunDirectory {
    param([Parameter(Mandatory = $true)][string]$ProjectDir, [Parameter(Mandatory = $true)][string]$RunId)
    Assert-DeclarativeWorkflowId -Name 'run_id' -Value $RunId
    $projectRoot = [IO.Path]::GetFullPath($ProjectDir)
    $runsRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '.winsmux\workflow-runs'))
    $runRoot = [IO.Path]::GetFullPath((Join-Path $runsRoot $RunId))
    $prefix = $runsRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $runRoot.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Workflow run path escaped the managed workflow-runs directory.'
    }
    return $runRoot
}

function Test-DeclarativeWorkflowReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch [Management.Automation.ItemNotFoundException] {
        return $false
    } catch [IO.FileNotFoundException] {
        return $false
    } catch [IO.DirectoryNotFoundException] {
        return $false
    }
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Resolve-DeclarativeWorkflowManagedPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string[]]$RelativeComponents,
        [Parameter(Mandatory = $true)][ValidateRange(0, 16)][int]$DirectoryComponentCount,
        [switch]$CreateDirectories
    )
    if ($RelativeComponents.Count -lt 1 -or $DirectoryComponentCount -gt $RelativeComponents.Count) {
        throw 'Workflow managed path components are invalid.'
    }
    foreach ($component in $RelativeComponents) {
        if ([string]::IsNullOrWhiteSpace($component) -or $component -in @('.', '..') -or
            $component.IndexOf([IO.Path]::DirectorySeparatorChar) -ge 0 -or
            $component.IndexOf([IO.Path]::AltDirectorySeparatorChar) -ge 0) {
            throw 'Workflow managed path component is invalid.'
        }
    }

    $projectRoot = [IO.Path]::GetFullPath($ProjectDir)
    $winsmuxRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '.winsmux'))
    $projectPrefix = $projectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $winsmuxRoot.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Workflow managed path escaped the project.'
    }
    $paths = [Collections.Generic.List[string]]::new()
    $paths.Add($winsmuxRoot) | Out-Null
    $current = $winsmuxRoot
    foreach ($component in $RelativeComponents) {
        $current = [IO.Path]::GetFullPath((Join-Path $current $component))
        $winsmuxPrefix = $winsmuxRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $current.StartsWith($winsmuxPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Workflow managed path escaped .winsmux.'
        }
        $paths.Add($current) | Out-Null
    }

    foreach ($path in $paths) {
        if (Test-DeclarativeWorkflowReparsePoint -Path $path) {
            throw 'Workflow managed path contains a reparse point.'
        }
    }
    if ($CreateDirectories) {
        [IO.Directory]::CreateDirectory($winsmuxRoot) | Out-Null
        for ($index = 0; $index -lt $DirectoryComponentCount; $index++) {
            [IO.Directory]::CreateDirectory($paths[$index + 1]) | Out-Null
            foreach ($observedPath in $paths) {
                if (Test-DeclarativeWorkflowReparsePoint -Path $observedPath) {
                    throw 'Workflow managed path contains a reparse point.'
                }
            }
        }
    }
    foreach ($path in $paths) {
        if (Test-DeclarativeWorkflowReparsePoint -Path $path) {
            throw 'Workflow managed path contains a reparse point.'
        }
    }
    return $paths[$paths.Count - 1]
}

function Resolve-DeclarativeWorkflowMailboxPendingPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$Channel,
        [AllowEmptyString()][string]$MessageId = '',
        [switch]$CreateDirectory
    )
    if ($Channel -cnotmatch '^[A-Za-z0-9_-]{1,64}$') { throw 'Workflow mailbox channel is invalid.' }
    $components = @('mailbox', $Channel, 'pending')
    $directoryCount = 3
    if (-not [string]::IsNullOrWhiteSpace($MessageId)) {
        if ($MessageId -cnotmatch '^[a-z][a-z0-9-]{0,127}$') { throw 'Workflow mailbox message_id is invalid.' }
        $components += @("$MessageId.json")
    }
    return Resolve-DeclarativeWorkflowManagedPath -ProjectDir $ProjectDir -RelativeComponents $components `
        -DirectoryComponentCount $directoryCount -CreateDirectories:$CreateDirectory
}

function Resolve-DeclarativeWorkflowDurableProofPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateSet('Completion', 'Cancellation')][string]$Kind,
        [AllowEmptyString()][string]$NodeId = '',
        [switch]$CreateDirectory
    )
    Assert-DeclarativeWorkflowId -Name 'run_id' -Value $RunId
    if ($Kind -ceq 'Completion') {
        Assert-DeclarativeWorkflowId -Name 'node_id' -Value $NodeId
        $components = @('workflow-runs', $RunId, 'proofs', 'completion', "$NodeId.json")
        $directoryCount = 4
    } else {
        if (-not [string]::IsNullOrWhiteSpace($NodeId)) { throw 'Cancellation proof must not specify node_id.' }
        $components = @('workflow-runs', $RunId, 'proofs', 'cancel.json')
        $directoryCount = 3
    }
    return Resolve-DeclarativeWorkflowManagedPath -ProjectDir $ProjectDir -RelativeComponents $components `
        -DirectoryComponentCount $directoryCount -CreateDirectories:$CreateDirectory
}

function Resolve-DeclarativeWorkflowDurableProofConflictPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateSet('Completion', 'Cancellation')][string]$Kind,
        [AllowEmptyString()][string]$NodeId = '',
        [switch]$CreateDirectory
    )
    Assert-DeclarativeWorkflowId -Name 'run_id' -Value $RunId
    if ($Kind -ceq 'Completion') {
        Assert-DeclarativeWorkflowId -Name 'node_id' -Value $NodeId
        $components = @('workflow-runs', $RunId, 'proofs', 'completion', "$NodeId.conflict")
        $directoryCount = 4
    } else {
        $components = @('workflow-runs', $RunId, 'proofs', 'cancel.conflict')
        $directoryCount = 3
    }
    return Resolve-DeclarativeWorkflowManagedPath -ProjectDir $ProjectDir -RelativeComponents $components `
        -DirectoryComponentCount $directoryCount -CreateDirectories:$CreateDirectory
}

function Set-DeclarativeWorkflowDurableProofConflict {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateSet('Completion', 'Cancellation')][string]$Kind,
        [AllowEmptyString()][string]$NodeId = ''
    )
    $path = Resolve-DeclarativeWorkflowDurableProofConflictPath -ProjectDir $ProjectDir -RunId $RunId -Kind $Kind -NodeId $NodeId -CreateDirectory
    if ([IO.File]::Exists($path)) { return }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes("conflict`n")
    try {
        $verifiedPath = Resolve-DeclarativeWorkflowDurableProofConflictPath -ProjectDir $ProjectDir -RunId $RunId -Kind $Kind -NodeId $NodeId
        if ($verifiedPath -cne $path) { throw 'Workflow durable proof conflict ownership changed.' }
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
    } catch [IO.IOException] {
        if (-not [IO.File]::Exists($path)) { throw }
    }
}

function Test-DeclarativeWorkflowCancellationProof {
    param([Parameter(Mandatory = $true)]$Run, [AllowNull()]$Proof)
    if ($null -eq $Proof) { return $false }
    $expected = [ordered]@{
        schema_version       = 1
        run_id               = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
        idempotency_key      = "$([string](Get-DeclarativeWorkflowValue $Run 'run_id' '')):cancel"
        generation_id        = [string](Get-DeclarativeWorkflowValue $Run 'generation_id' '')
        config_fingerprint   = [string](Get-DeclarativeWorkflowValue $Run 'config_fingerprint' '')
        workflow_fingerprint = [string](Get-DeclarativeWorkflowValue $Run 'workflow_fingerprint' '')
        source_head          = [string](Get-DeclarativeWorkflowValue $Run 'source_head' '')
        status               = 'cancelled'
        evidence_ref         = "workflow-cancel:$([string](Get-DeclarativeWorkflowValue $Run 'run_id' ''))"
    }
    $names = if ($Proof -is [Collections.IDictionary]) { @($Proof.Keys | ForEach-Object { [string]$_ }) } else { @($Proof.PSObject.Properties.Name) }
    if ($names.Count -ne $expected.Count -or @($names | Where-Object { $_ -notin $expected.Keys }).Count -ne 0) { return $false }
    $schema = Get-DeclarativeWorkflowValue $Proof 'schema_version' $null
    if ($schema -isnot [ValueType] -or [int64]$schema -ne 1) { return $false }
    foreach ($entry in $expected.GetEnumerator()) {
        if ([string](Get-DeclarativeWorkflowValue $Proof ([string]$entry.Key) '') -cne [string]$entry.Value) { return $false }
    }
    return $true
}

function Read-DeclarativeWorkflowDurableProof {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [AllowNull()]$Run = $null,
        [AllowEmptyString()][string]$RunId = '',
        [Parameter(Mandatory = $true)][ValidateSet('Completion', 'Cancellation')][string]$Kind,
        [AllowEmptyString()][string]$NodeId = ''
    )
    if ($null -eq $Run) {
        if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'Workflow durable proof requires run_id.' }
        $Run = Read-DeclarativeWorkflowRunState -ProjectDir $ProjectDir -RunId $RunId
    } else {
        $RunId = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
    }
    $conflictPath = Resolve-DeclarativeWorkflowDurableProofConflictPath -ProjectDir $ProjectDir -RunId $RunId -Kind $Kind -NodeId $NodeId
    if ([IO.File]::Exists($conflictPath)) { throw 'Workflow durable proof conflict.' }
    $path = Resolve-DeclarativeWorkflowDurableProofPath -ProjectDir $ProjectDir -RunId $RunId -Kind $Kind -NodeId $NodeId
    if (-not [IO.File]::Exists($path)) { return $null }
    $verifiedPath = Resolve-DeclarativeWorkflowDurableProofPath -ProjectDir $ProjectDir -RunId $RunId -Kind $Kind -NodeId $NodeId
    if ($verifiedPath -cne $path) { throw 'Workflow durable proof ownership changed before read.' }
    try {
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -lt 2 -or $bytes.Length -gt 65536 -or [Array]::IndexOf($bytes, [byte]0) -ge 0) { throw 'invalid proof size' }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $proof = $text | ConvertFrom-WinsmuxJson -AsHashtable -Depth 30 -ErrorAction Stop
    } catch {
        throw 'Workflow durable proof is malformed.'
    }
    $valid = if ($Kind -ceq 'Completion') {
        Test-DeclarativeWorkflowAcknowledgement -Run $Run -NodeId $NodeId -Acknowledgement $proof
    } else {
        Test-DeclarativeWorkflowCancellationProof -Run $Run -Proof $proof
    }
    if (-not $valid) { throw 'Workflow durable proof conflicts with its derived identity.' }
    return $proof
}

function Write-DeclarativeWorkflowDurableProof {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][ValidateSet('Completion', 'Cancellation')][string]$Kind,
        [AllowEmptyString()][string]$NodeId = '',
        [Parameter(Mandatory = $true)]$Proof,
        [AllowEmptyString()][string]$TrustedSenderLabel = '',
        [AllowEmptyString()][string]$TrustedSenderPaneId = ''
    )
    $runId = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
    $persistedRun = Read-DeclarativeWorkflowRunState -ProjectDir $ProjectDir -RunId $runId
    $canonical = ConvertTo-DeclarativeWorkflowCanonicalJson -Value $Proof
    if ($Kind -ceq 'Completion') {
        $nodes = Get-DeclarativeWorkflowValue $persistedRun 'nodes' $null
        $node = if ($null -ne $nodes -and $nodes -is [Collections.IDictionary] -and $nodes.Contains($NodeId)) { $nodes[$NodeId] } else { $null }
        if ($null -ne $node -and [string](Get-DeclarativeWorkflowValue $node 'state' '') -ceq 'succeeded') {
            $existingPath = Resolve-DeclarativeWorkflowDurableProofPath -ProjectDir $ProjectDir -RunId $runId -Kind $Kind -NodeId $NodeId
            if ([IO.File]::Exists($existingPath)) {
                $existing = Read-DeclarativeWorkflowDurableProof -ProjectDir $ProjectDir -Run $persistedRun -Kind $Kind -NodeId $NodeId
                if ((ConvertTo-DeclarativeWorkflowCanonicalJson -Value $existing) -ceq $canonical) { return $existingPath }
            }
        }
        $admissionError = Get-DeclarativeWorkflowCompletionProofAdmissionError -Run $persistedRun -NodeId $NodeId -Proof $Proof `
            -TrustedSenderLabel $TrustedSenderLabel -TrustedSenderPaneId $TrustedSenderPaneId
        if ($null -ne $admissionError) { throw "workflow_completion_rejected: $admissionError" }
    } elseif (-not (Test-DeclarativeWorkflowCancellationProof -Run $persistedRun -Proof $Proof)) {
        throw 'Workflow durable proof does not match the existing run.'
    }

    $path = Resolve-DeclarativeWorkflowDurableProofPath -ProjectDir $ProjectDir -RunId $runId -Kind $Kind -NodeId $NodeId -CreateDirectory
    $payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes($canonical + "`n")
    if ([IO.File]::Exists($path)) {
        $existing = Read-DeclarativeWorkflowDurableProof -ProjectDir $ProjectDir -Run $persistedRun -Kind $Kind -NodeId $NodeId
        if ((ConvertTo-DeclarativeWorkflowCanonicalJson -Value $existing) -ceq $canonical) { return $path }
        Set-DeclarativeWorkflowDurableProofConflict -ProjectDir $ProjectDir -RunId $runId -Kind $Kind -NodeId $NodeId
        throw 'Workflow durable proof conflict.'
    }

    $temporaryName = '.proof-{0}.tmp' -f [guid]::NewGuid().ToString('N')
    $temporaryComponents = @('workflow-runs', $runId, 'proofs')
    if ($Kind -ceq 'Completion') { $temporaryComponents += @('completion', $temporaryName) } else { $temporaryComponents += @($temporaryName) }
    $temporaryDirectoryCount = if ($Kind -ceq 'Completion') { 4 } else { 3 }
    $temporary = Resolve-DeclarativeWorkflowManagedPath -ProjectDir $ProjectDir `
        -RelativeComponents $temporaryComponents -DirectoryComponentCount $temporaryDirectoryCount
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($payloadBytes, 0, $payloadBytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        $verifiedPath = Resolve-DeclarativeWorkflowDurableProofPath -ProjectDir $ProjectDir -RunId $runId -Kind $Kind -NodeId $NodeId
        if ($verifiedPath -cne $path) { throw 'Workflow durable proof ownership changed before commit.' }
        try {
            [IO.File]::Move($temporary, $path)
        } catch [IO.IOException] {
            if ([IO.File]::Exists($path)) {
                $winner = Read-DeclarativeWorkflowDurableProof -ProjectDir $ProjectDir -Run $persistedRun -Kind $Kind -NodeId $NodeId
                if ((ConvertTo-DeclarativeWorkflowCanonicalJson -Value $winner) -ceq $canonical) { return $path }
            }
            Set-DeclarativeWorkflowDurableProofConflict -ProjectDir $ProjectDir -RunId $runId -Kind $Kind -NodeId $NodeId
            throw 'Workflow durable proof conflict.'
        }
    } finally {
        if ([IO.File]::Exists($temporary)) {
            $verifiedTemporary = Resolve-DeclarativeWorkflowManagedPath -ProjectDir $ProjectDir `
                -RelativeComponents $temporaryComponents -DirectoryComponentCount $temporaryDirectoryCount
            if ($verifiedTemporary -ceq $temporary) { [IO.File]::Delete($temporary) }
        }
    }
    return $path
}

function Resolve-DeclarativeWorkflowOwnedRunPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateSet('state.json', 'run.lock', 'invocation.lock')][string]$LeafName,
        [switch]$CreateRunDirectory
    )
    $projectRoot = [IO.Path]::GetFullPath($ProjectDir)
    $winsmuxRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '.winsmux'))
    $runsRoot = [IO.Path]::GetFullPath((Join-Path $winsmuxRoot 'workflow-runs'))
    $runRoot = Get-DeclarativeWorkflowRunDirectory -ProjectDir $projectRoot -RunId $RunId
    $ownedPath = [IO.Path]::GetFullPath((Join-Path $runRoot $LeafName))
    $runPrefix = $runRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $ownedPath.StartsWith($runPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Workflow run state path escaped its managed run directory.'
    }
    foreach ($component in @($winsmuxRoot, $runsRoot, $runRoot, $ownedPath)) {
        if (Test-DeclarativeWorkflowReparsePoint -Path $component) {
            throw 'Workflow run owned path contains a reparse point.'
        }
    }
    if ($CreateRunDirectory) {
        [IO.Directory]::CreateDirectory($runRoot) | Out-Null
        foreach ($component in @($winsmuxRoot, $runsRoot, $runRoot, $ownedPath)) {
            if (Test-DeclarativeWorkflowReparsePoint -Path $component) {
                throw 'Workflow run owned path contains a reparse point.'
            }
        }
    }
    return $ownedPath
}

function Resolve-DeclarativeWorkflowOwnedLock {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Run,
        [switch]$CreateRunDirectory
    )
    $runId = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
    return Resolve-DeclarativeWorkflowOwnedRunPath -ProjectDir $ProjectDir -RunId $runId -LeafName 'run.lock' -CreateRunDirectory:$CreateRunDirectory
}

function Enter-DeclarativeWorkflowInvocationLease {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    Assert-DeclarativeWorkflowId -Name 'run_id' -Value $RunId
    $path = Resolve-DeclarativeWorkflowOwnedRunPath -ProjectDir $ProjectDir -RunId $RunId -LeafName 'invocation.lock' -CreateRunDirectory
    try {
        return [IO.File]::Open(
            $path,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    } catch [IO.IOException] {
        throw 'workflow_run_invocation_busy'
    }
}

function New-DeclarativeWorkflowRunLock {
    param([Parameter(Mandatory = $true)][string]$ProjectDir, [Parameter(Mandatory = $true)]$Run)
    $runId = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
    $path = Resolve-DeclarativeWorkflowOwnedLock -ProjectDir $ProjectDir -Run $Run -CreateRunDirectory
    $payload = [ordered]@{
        run_id = $runId
        generation_id = [string](Get-DeclarativeWorkflowValue $Run 'generation_id' '')
        config_fingerprint = [string](Get-DeclarativeWorkflowValue $Run 'config_fingerprint' '')
        source_head = [string](Get-DeclarativeWorkflowValue $Run 'source_head' '')
    }
    $verifiedPath = Resolve-DeclarativeWorkflowOwnedLock -ProjectDir $ProjectDir -Run $Run
    if ($verifiedPath -cne $path) { throw 'Workflow run lock ownership changed before write.' }
    $payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes(($payload | ConvertTo-Json -Compress))
    $created = $false
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $created = $true
        try {
            $stream.Write($payloadBytes, 0, $payloadBytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
    } catch {
        if ($created) {
            $cleanupPath = Resolve-DeclarativeWorkflowOwnedLock -ProjectDir $ProjectDir -Run $Run
            if ($cleanupPath -cne $path) { throw 'Workflow run lock ownership changed during create rollback.' }
            if ([IO.File]::Exists($cleanupPath)) { Remove-Item -LiteralPath $cleanupPath -Force }
        }
        throw
    }
    return $path
}

function Test-DeclarativeWorkflowRunLockOwnership {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Run
    )
    try {
        $Path = Resolve-DeclarativeWorkflowOwnedLock -ProjectDir $ProjectDir -Run $Run
    } catch {
        return $false
    }
    if (-not [IO.File]::Exists($Path)) { return $false }
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -gt 4096 -or [Array]::IndexOf($bytes, [byte]0) -ge 0) { return $false }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $payload = $text | ConvertFrom-Json -ErrorAction Stop
    } catch { return $false }
    $allowed = @('run_id', 'generation_id', 'config_fingerprint', 'source_head')
    if (@($payload.PSObject.Properties.Name | Where-Object { $_ -notin $allowed }).Count -gt 0) { return $false }
    foreach ($field in $allowed) {
        if ([string](Get-DeclarativeWorkflowValue $payload $field '') -cne [string](Get-DeclarativeWorkflowValue $Run $field '')) { return $false }
    }
    return $true
}

function Test-DeclarativeWorkflowPristineBootstrap {
    param([Parameter(Mandatory = $true)]$Run)

    if ([string](Get-DeclarativeWorkflowValue $Run 'state' '') -cne 'ready') { return $false }
    if ([string](Get-DeclarativeWorkflowValue $Run 'rollback_state' '') -cne 'not_requested') { return $false }

    $journal = @(Get-DeclarativeWorkflowValue $Run 'cleanup_journal' @())
    if ($journal.Count -ne 1) { return $false }
    $action = $journal[0]
    $runId = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
    foreach ($field in @('action_id', 'kind', 'state', 'idempotency_key', 'resource_ref')) {
        if (-not (Test-DeclarativeWorkflowFieldExists -InputObject $action -Name $field)) { return $false }
    }
    if (
        [string](Get-DeclarativeWorkflowValue $action 'action_id' '') -cne 'release-run-lock' -or
        [string](Get-DeclarativeWorkflowValue $action 'kind' '') -cne 'release-run-lock' -or
        [string](Get-DeclarativeWorkflowValue $action 'state' '') -cne 'pending' -or
        [string](Get-DeclarativeWorkflowValue $action 'idempotency_key' '') -cne "$runId`:cleanup:release-run-lock" -or
        [string](Get-DeclarativeWorkflowValue $action 'resource_ref' '') -cne "workflow-run-lock:$runId"
    ) {
        return $false
    }

    $nodes = Get-DeclarativeWorkflowValue $Run 'nodes' $null
    if ($null -eq $nodes -or $nodes -isnot [Collections.IDictionary] -or $nodes.Count -lt 1) { return $false }
    foreach ($entry in $nodes.GetEnumerator()) {
        $node = $entry.Value
        if (
            [int](Get-DeclarativeWorkflowValue $node 'attempt' -1) -ne 0 -or
            [string](Get-DeclarativeWorkflowValue $node 'state' '') -notin @('pending', 'ready') -or
            -not [string]::IsNullOrWhiteSpace([string](Get-DeclarativeWorkflowValue $node 'agent_cli_session_id' '')) -or
            @((Get-DeclarativeWorkflowValue $node 'evidence_refs' @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -ne 0
        ) {
            return $false
        }
    }
    return $true
}

function Get-DeclarativeWorkflowCleanupActionState {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string[]]$AllowedStates
    )

    $journal = @(Get-DeclarativeWorkflowValue $Run 'cleanup_journal' @())
    if ($journal.Count -ne 1 -or $null -eq $journal[0]) { throw 'workflow_cleanup_action_invalid' }
    $action = $journal[0]
    $runId = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
    $expected = [ordered]@{
        action_id       = 'release-run-lock'
        kind            = 'release-run-lock'
        idempotency_key = "$runId`:cleanup:release-run-lock"
        resource_ref    = "workflow-run-lock:$runId"
    }
    $propertyNames = if ($action -is [Collections.IDictionary]) {
        @($action.Keys | ForEach-Object { [string]$_ })
    } else {
        @($action.PSObject.Properties.Name | ForEach-Object { [string]$_ })
    }
    $expectedNames = @($expected.Keys) + @('state')
    if (@($propertyNames | Where-Object { $_ -notin $expectedNames }).Count -ne 0 -or
        @($expectedNames | Where-Object { $_ -notin $propertyNames }).Count -ne 0) {
        throw 'workflow_cleanup_action_invalid'
    }
    foreach ($entry in $expected.GetEnumerator()) {
        if ([string](Get-DeclarativeWorkflowValue $action ([string]$entry.Key) '') -cne [string]$entry.Value) {
            throw 'workflow_cleanup_action_invalid'
        }
    }
    $state = [string](Get-DeclarativeWorkflowValue $action 'state' '')
    if ($AllowedStates -cnotcontains $state) { throw 'workflow_cleanup_action_not_admissible' }
    return $state
}

function Test-DeclarativeWorkflowRunningCleanupRecovery {
    param([Parameter(Mandatory = $true)]$Run)
    try {
        if ((Get-DeclarativeWorkflowCleanupActionState -Run $Run -AllowedStates @('running')) -cne 'running') { return $false }
        $runState = [string](Get-DeclarativeWorkflowValue $Run 'state' '')
        $preserved = [string](Get-DeclarativeWorkflowValue $Run 'cleanup_preserve_run_state' '')
        if ($runState -ceq 'cleanup_pending') { return [string]::IsNullOrWhiteSpace($preserved) }
        return (@('succeeded', 'failed', 'cancelled') -ccontains $runState) -and $preserved -ceq $runState
    } catch {
        return $false
    }
}

function Remove-DeclarativeWorkflowPristineRunState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Run
    )

    $runId = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
    $path = Resolve-DeclarativeWorkflowOwnedRunPath -ProjectDir $ProjectDir -RunId $runId -LeafName 'state.json'
    if (-not [IO.File]::Exists($path)) { return }
    $persisted = Read-DeclarativeWorkflowRunState -ProjectDir $ProjectDir -RunId $runId
    foreach ($field in @('run_id', 'generation_id', 'config_fingerprint', 'source_head')) {
        if ([string](Get-DeclarativeWorkflowValue $persisted $field '') -cne [string](Get-DeclarativeWorkflowValue $Run $field '')) {
            throw 'Declarative workflow initial state ownership changed before rollback.'
        }
    }
    if (-not (Test-DeclarativeWorkflowPristineBootstrap -Run $persisted)) {
        throw 'Declarative workflow initial state is no longer pristine for rollback.'
    }
    $verifiedPath = Resolve-DeclarativeWorkflowOwnedRunPath -ProjectDir $ProjectDir -RunId $runId -LeafName 'state.json'
    if ($verifiedPath -cne $path) { throw 'Declarative workflow initial state ownership changed before rollback.' }
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
}

function Invoke-DeclarativeWorkflowCleanup {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][scriptblock]$SaveRun,
        [Parameter(Mandatory = $true)][scriptblock]$ReleaseLock,
        [scriptblock]$ResolveAcknowledgement,
        [scriptblock]$ResolveCancellation,
        [ValidateSet('', 'succeeded', 'failed', 'cancelled')][string]$PreserveRunState = ''
    )
    $durableProofs = Resolve-DeclarativeWorkflowDurableProofs -Run $Run -ResolveAcknowledgement $ResolveAcknowledgement -ResolveCancellation $ResolveCancellation
    $candidate = Invoke-DeclarativeWorkflowTransition -Run $Run -Event ([ordered]@{ type = 'validate' }) -DurableProofs $durableProofs
    $journal = @(Get-DeclarativeWorkflowValue $candidate 'cleanup_journal' @())
    if ($journal.Count -ne 1) { throw 'workflow_state_invalid' }
    $cleanupState = [string](Get-DeclarativeWorkflowValue $journal[0] 'state' '')
    if ($cleanupState -ceq 'succeeded' -or $cleanupState -ceq 'blocked') { return $candidate }
    if (@('pending', 'running') -cnotcontains $cleanupState) { throw 'workflow_state_invalid' }

    $ownershipUnobservable = $false
    try {
        $lockPath = Resolve-DeclarativeWorkflowOwnedLock -ProjectDir $ProjectDir -Run $candidate
        $lockPresent = [IO.File]::Exists($lockPath)
    } catch {
        $lockPath = $null
        $lockPresent = $false
        $ownershipUnobservable = $true
    }
    if ($cleanupState -ceq 'pending' -and -not $lockPresent -and -not $ownershipUnobservable) {
        throw 'workflow_run_lock_missing_after_effect'
    }

    if ($cleanupState -ceq 'pending') {
        $intent = [ordered]@{ type = 'cleanup_intent' }
        if (-not [string]::IsNullOrWhiteSpace($PreserveRunState)) {
            $intent['preserve_run_state'] = $PreserveRunState
        }
        $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event $intent -DurableProofs $durableProofs
        & $SaveRun $candidate
    }

    if ($ownershipUnobservable) {
        $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'cleanup_blocked' }) -DurableProofs $durableProofs
        & $SaveRun $candidate
        return $candidate
    }
    if (-not $lockPresent) {
        $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'cleanup_succeeded' }) -DurableProofs $durableProofs
        & $SaveRun $candidate
        return $candidate
    }
    try {
        $verifiedLockPath = Resolve-DeclarativeWorkflowOwnedLock -ProjectDir $ProjectDir -Run $candidate
        $owned = $verifiedLockPath -ceq $lockPath -and
            (Test-DeclarativeWorkflowRunLockOwnership -ProjectDir $ProjectDir -Run $candidate)
    } catch {
        $owned = $false
    }
    if (-not $owned) {
        $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'cleanup_blocked' }) -DurableProofs $durableProofs
        & $SaveRun $candidate
        return $candidate
    }
    try {
        & $ReleaseLock $lockPath
    } catch {
        $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'cleanup_blocked' }) -DurableProofs $durableProofs
        & $SaveRun $candidate
        return $candidate
    }
    try {
        $postReleasePath = Resolve-DeclarativeWorkflowOwnedLock -ProjectDir $ProjectDir -Run $candidate
        $released = $postReleasePath -ceq $lockPath -and -not [IO.File]::Exists($postReleasePath)
    } catch {
        $released = $false
    }
    if (-not $released) {
        $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'cleanup_blocked' }) -DurableProofs $durableProofs
        & $SaveRun $candidate
        return $candidate
    }
    $candidate = Invoke-DeclarativeWorkflowTransition -Run $candidate -Event ([ordered]@{ type = 'cleanup_succeeded' }) -DurableProofs $durableProofs
    & $SaveRun $candidate
    return $candidate
}

function Invoke-DeclarativeWorkflowTerminalCleanup {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][scriptblock]$SaveRun,
        [Parameter(Mandatory = $true)][scriptblock]$ReleaseLock,
        [scriptblock]$ResolveAcknowledgement,
        [scriptblock]$ResolveCancellation
    )

    $terminalState = [string](Get-DeclarativeWorkflowValue $Run 'state' '')
    if ($terminalState -notin @('succeeded', 'failed', 'cancelled')) {
        throw "Declarative workflow terminal cleanup requires a terminal run, not '$terminalState'."
    }
    return Invoke-DeclarativeWorkflowCleanup -ProjectDir $ProjectDir -Run $Run -SaveRun $SaveRun -ReleaseLock $ReleaseLock `
        -ResolveAcknowledgement $ResolveAcknowledgement -ResolveCancellation $ResolveCancellation -PreserveRunState $terminalState
}

function Read-DeclarativeWorkflowRunState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $path = Resolve-DeclarativeWorkflowOwnedRunPath -ProjectDir $ProjectDir -RunId $RunId -LeafName 'state.json'
    if (-not [IO.File]::Exists($path)) { throw "Declarative workflow run '$RunId' was not found." }
    try {
        [byte[]]$bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -gt 1048576 -or [Array]::IndexOf($bytes, [byte]0) -ge 0) { throw 'invalid state size' }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $state = $text | ConvertFrom-WinsmuxJson -AsHashtable -Depth 100 -ErrorAction Stop
    } catch {
        throw "Declarative workflow run '$RunId' is malformed."
    }
    if ([string](Get-DeclarativeWorkflowValue $state 'run_id' '') -cne $RunId) {
        throw "Declarative workflow run '$RunId' identity does not match its derived path."
    }
    return $state
}

function Test-DeclarativeWorkflowForbiddenStateField {
    param([Parameter(Mandatory = $true)][string]$Name)

    return [string]::Equals($Name, 'Text', [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($Name, 'task', [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($Name, 'task_file', [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($Name, 'task_path', [StringComparison]::OrdinalIgnoreCase)
}

function Get-DeclarativeWorkflowStateEntries {
    param([AllowNull()]$Value)

    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            [PSCustomObject]@{ Name = [string]$key; Value = $Value[$key] }
        }
        return
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in @($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property') })) {
            [PSCustomObject]@{ Name = [string]$property.Name; Value = $property.Value }
        }
    }
}

function Test-DeclarativeWorkflowStructuredStateRecord {
    param([AllowNull()]$Value)

    return ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject])
}

function Assert-DeclarativeWorkflowStatePrivacy {
    param(
        [AllowNull()]$Value,
        [ValidateSet('run', 'snapshot', 'record', 'node-map', 'binding-map')][string]$Shape = 'record'
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) {
        return
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [Collections.IDictionary]) {
        foreach ($item in $Value) {
            Assert-DeclarativeWorkflowStatePrivacy -Value $item -Shape 'record'
        }
        return
    }

    $entries = @(Get-DeclarativeWorkflowStateEntries -Value $Value)
    if ($entries.Count -eq 0) { return }
    if ($Shape -in @('node-map', 'binding-map')) {
        foreach ($entry in $entries) {
            if ($Shape -ceq 'node-map' -and -not (Test-DeclarativeWorkflowStructuredStateRecord -Value $entry.Value)) {
                throw 'Declarative workflow state nodes must map identifiers to typed records.'
            }
            Assert-DeclarativeWorkflowStatePrivacy -Value $entry.Value -Shape 'record'
        }
        return
    }

    foreach ($entry in $entries) {
        if (Test-DeclarativeWorkflowForbiddenStateField -Name $entry.Name) {
            throw 'Declarative workflow state must not persist task text or task-file paths.'
        }
        $childShape = 'record'
        if ($Shape -ceq 'run') {
            if ($entry.Name -ceq 'nodes') {
                $childShape = 'node-map'
            } elseif ($entry.Name -ceq 'resolved_bindings') {
                $childShape = 'binding-map'
            } elseif ($entry.Name -ceq 'normalized_snapshot') {
                $childShape = 'snapshot'
            }
        } elseif ($Shape -ceq 'snapshot' -and $entry.Name -ceq 'resolved_bindings') {
            $childShape = 'binding-map'
        }
        Assert-DeclarativeWorkflowStatePrivacy -Value $entry.Value -Shape $childShape
    }
}

function Save-DeclarativeWorkflowRunState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Run,
        [switch]$CreateNew
    )
    $runId = [string](Get-DeclarativeWorkflowValue $Run 'run_id' '')
    $generationId = [string](Get-DeclarativeWorkflowValue $Run 'generation_id' '')
    Assert-DeclarativeWorkflowId -Name 'run_id' -Value $runId
    Assert-DeclarativeWorkflowGenerationId -Name 'generation_id' -Value $generationId
    Assert-DeclarativeWorkflowStatePrivacy -Value $Run -Shape 'run'
    $path = Resolve-DeclarativeWorkflowOwnedRunPath -ProjectDir $ProjectDir -RunId $runId -LeafName 'state.json' -CreateRunDirectory
    $runRoot = Split-Path -Parent $path
    if ($CreateNew -and [IO.File]::Exists($path)) {
        throw 'Declarative workflow run state already exists.'
    }
    $previousBytes = if (-not $CreateNew -and [IO.File]::Exists($path)) { [IO.File]::ReadAllBytes($path) } else { $null }
    $json = $Run | ConvertTo-Json -Depth 100 -Compress
    $stateBytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
    $tempPath = Join-Path $runRoot ('.state-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $createdInitialState = $false
    try {
        $verifiedPath = Resolve-DeclarativeWorkflowOwnedRunPath -ProjectDir $ProjectDir -RunId $runId -LeafName 'state.json'
        if ($verifiedPath -cne $path) { throw 'Workflow run state ownership changed before write.' }
        if ($CreateNew) {
            $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $createdInitialState = $true
            try {
                $stream.Write($stateBytes, 0, $stateBytes.Length)
                $stream.Flush($true)
            } finally {
                $stream.Dispose()
            }
        } else {
            [IO.File]::WriteAllBytes($tempPath, $stateBytes)
            Move-Item -LiteralPath $tempPath -Destination $path -Force
        }

        $manifestPath = Join-Path (Join-Path ([IO.Path]::GetFullPath($ProjectDir)) '.winsmux') 'manifest.yaml'
        if ([IO.File]::Exists($manifestPath) -and (Get-Command Get-WinsmuxManifest -ErrorAction SilentlyContinue) -and (Get-Command Save-WinsmuxManifest -ErrorAction SilentlyContinue)) {
            $manifest = Get-WinsmuxManifest -ProjectDir $ProjectDir
            if ($null -eq $manifest) { throw 'Declarative workflow requires a readable runtime manifest.' }
            $manifestGeneration = [string](Get-DeclarativeWorkflowValue (Get-DeclarativeWorkflowValue $manifest 'session' $null) 'generation_id' '')
            if (-not [string]::Equals($manifestGeneration, $generationId, [StringComparison]::Ordinal)) { throw 'Declarative workflow manifest generation does not match the run.' }
            $runs = [ordered]@{}
            $runsRoot = Split-Path -Parent $runRoot
            foreach ($directory in @(Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction Stop | Sort-Object Name)) {
                if ($directory.Name -cnotmatch $script:DeclarativeWorkflowIdPattern) { continue }
                $statePath = Resolve-DeclarativeWorkflowOwnedRunPath -ProjectDir $ProjectDir -RunId $directory.Name -LeafName 'state.json'
                if (-not [IO.File]::Exists($statePath)) { continue }
                $runs[$directory.Name] = Read-DeclarativeWorkflowRunState -ProjectDir $ProjectDir -RunId $directory.Name
            }
            if ($manifest -is [Collections.IDictionary]) {
                $manifest['workflow_runs'] = $runs
            } else {
                $manifest | Add-Member -NotePropertyName 'workflow_runs' -NotePropertyValue $runs -Force
            }
            Save-WinsmuxManifest -ProjectDir $ProjectDir -Manifest $manifest -ExpectedGenerationId $generationId | Out-Null
        }
    } catch {
        $saveFailure = $_
        $rollbackPath = Resolve-DeclarativeWorkflowOwnedRunPath -ProjectDir $ProjectDir -RunId $runId -LeafName 'state.json'
        if ($rollbackPath -cne $path) { throw 'Workflow run state ownership changed during rollback.' }
        if ([IO.File]::Exists($tempPath)) { Remove-Item -LiteralPath $tempPath -Force }
        if ($CreateNew) {
            if ($createdInitialState -and [IO.File]::Exists($rollbackPath)) {
                try {
                    $persisted = Read-DeclarativeWorkflowRunState -ProjectDir $ProjectDir -RunId $runId
                    foreach ($field in @('run_id', 'generation_id', 'config_fingerprint', 'source_head')) {
                        if ([string](Get-DeclarativeWorkflowValue $persisted $field '') -cne [string](Get-DeclarativeWorkflowValue $Run $field '')) {
                            throw 'Declarative workflow initial state ownership changed during rollback.'
                        }
                    }
                    if (-not (Test-DeclarativeWorkflowPristineBootstrap -Run $persisted)) {
                        throw 'Declarative workflow initial state is no longer pristine during rollback.'
                    }
                    Remove-Item -LiteralPath $rollbackPath -Force -ErrorAction Stop
                } catch {
                    throw "Declarative workflow initial state rollback failed: $([string]$saveFailure.Exception.Message); $([string]$_.Exception.Message)"
                }
            }
        } elseif ($null -ne $previousBytes) {
            [IO.File]::WriteAllBytes($rollbackPath, $previousBytes)
        } elseif ([IO.File]::Exists($rollbackPath)) {
            Remove-Item -LiteralPath $rollbackPath -Force
        }
        throw $saveFailure
    }
    return $path
}
