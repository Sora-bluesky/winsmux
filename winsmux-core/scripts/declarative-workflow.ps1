$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'json-compat.ps1')

function Get-DeclarativeWorkflowValue {
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

function Assert-DeclarativeWorkflowIdentifier {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -cnotmatch '^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$' -or $Value.Length -gt 128) {
        throw "$Name is invalid."
    }
}

function ConvertTo-DeclarativeWorkflowCanonicalObject {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string] -or $Value -is [char] -or
        $Value -is [bool] -or $Value -is [byte] -or
        $Value -is [int16] -or $Value -is [int32] -or
        $Value -is [int64] -or $Value -is [uint16] -or
        $Value -is [uint32] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or
        $Value -is [decimal]) {
        return $Value
    }
    if ($Value -is [System.DateTime]) {
        return $Value.ToUniversalTime().ToString(
            'o',
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
    if ($Value -is [System.DateTimeOffset]) {
        return $Value.UtcDateTime.ToString(
            'o',
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
            $result[$key] = ConvertTo-DeclarativeWorkflowCanonicalObject -Value $Value[$key]
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @(
            foreach ($item in $Value) {
                ConvertTo-DeclarativeWorkflowCanonicalObject -Value $item
            }
        )
        return ,$items
    }

    $properties = @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)
    if ($properties.Count -gt 0) {
        $result = [ordered]@{}
        foreach ($name in $properties) {
            $result[$name] = ConvertTo-DeclarativeWorkflowCanonicalObject -Value $Value.$name
        }
        return $result
    }

    return [string]$Value
}

function ConvertTo-DeclarativeWorkflowCanonicalJson {
    param([AllowNull()]$Value)

    $canonical = ConvertTo-DeclarativeWorkflowCanonicalObject -Value $Value
    return $canonical | ConvertTo-Json -Compress -Depth 50
}

function Get-DeclarativeWorkflowSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $digest = [System.Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)
    return 'sha256:' + (($digest | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-DeclarativeWorkflowContentDigest {
    param([Parameter(Mandatory = $true)]$Workflow)

    $json = ConvertTo-DeclarativeWorkflowCanonicalJson -Value $Workflow
    return Get-DeclarativeWorkflowSha256 -Bytes ([System.Text.Encoding]::UTF8.GetBytes($json))
}

function ConvertTo-DeclarativeWorkflowUtcTimestamp {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [DateTimeOffset]) {
        return $Value.UtcDateTime.ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture
        )
    }

    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        throw 'workflow_state_invalid: created_at is not an ISO timestamp.'
    }
    return $parsed.UtcDateTime.ToString(
        'o',
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Get-DeclarativeWorkflowRunStatePath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    Assert-DeclarativeWorkflowIdentifier -Value $RunId -Name 'run_id'
    $root = [System.IO.Path]::GetFullPath($ProjectDir)
    return Join-Path (Join-Path (Join-Path $root '.winsmux') 'workflow-runs') "$RunId.json"
}

function Read-DeclarativeWorkflowRunState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $path = Get-DeclarativeWorkflowRunStatePath -ProjectDir $ProjectDir -RunId $RunId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "workflow_run_not_found: $RunId"
    }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'workflow_state_invalid: UTF-8 BOM is not allowed.'
    }
    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $state = $text | ConvertFrom-WinsmuxJson -AsHashtable -Depth 50 -ErrorAction Stop
    } catch {
        throw "workflow_state_invalid: $($_.Exception.Message)"
    }
    if ([string](Get-DeclarativeWorkflowValue -InputObject $state -Name 'run_id' -Default '') -cne $RunId) {
        throw 'workflow_state_invalid: run identity mismatch.'
    }
    return $state
}

function Set-DeclarativeWorkflowRunState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$State
    )

    Assert-DeclarativeWorkflowIdentifier -Value $RunId -Name 'run_id'
    if ([string](Get-DeclarativeWorkflowValue -InputObject $State -Name 'run_id' -Default '') -cne $RunId) {
        throw 'workflow_state_invalid: writer run identity mismatch.'
    }
    $path = Get-DeclarativeWorkflowRunStatePath -ProjectDir $ProjectDir -RunId $RunId
    $directory = Split-Path -Parent $path
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $json = ConvertTo-DeclarativeWorkflowCanonicalJson -Value $State
    $temporary = Join-Path $directory (".{0}.{1}.tmp" -f $RunId, [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText(
        $temporary,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        [System.IO.File]::Move($temporary, $path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    return $path
}

function Enter-DeclarativeWorkflowInvocationLease {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    Assert-DeclarativeWorkflowIdentifier -Value $RunId -Name 'run_id'
    $statePath = Get-DeclarativeWorkflowRunStatePath -ProjectDir $ProjectDir -RunId $RunId
    $directory = Split-Path -Parent $statePath
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $leasePath = Join-Path $directory "$RunId.lease"
    $stream = $null
    try {
        try {
            $stream = [System.IO.FileStream]::new(
                $leasePath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            throw 'workflow_run_busy'
        }
        $lease = [PSCustomObject]@{
            Stream = $stream
            Path = $leasePath
            Released = $false
        }
        $lease | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
            if (-not $this.Released) {
                $this.Stream.Dispose()
                $this.Released = $true
            }
        } -Force
        return $lease
    } catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        throw
    }
}

function Get-DeclarativeWorkflowTaskSnapshot {
    param([Parameter(Mandatory = $true)][string]$TaskFile)

    $path = [System.IO.Path]::GetFullPath($TaskFile)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "workflow_task_not_found: $path"
    }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } catch {
        throw 'workflow_task_invalid: task file must be UTF-8.'
    }
    return [PSCustomObject]@{
        path = $path
        bytes = $bytes
        text = $text
        digest = Get-DeclarativeWorkflowSha256 -Bytes $bytes
    }
}

function Get-DeclarativeWorkflowSourceHead {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $output = @(& git -C $ProjectDir rev-parse HEAD 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "workflow_source_unavailable: $($output -join ' ')"
    }
    $head = ([string]($output | Select-Object -Last 1)).Trim().ToLowerInvariant()
    if ($head -cnotmatch '^[0-9a-f]{40}$') {
        throw 'workflow_source_invalid: expected an exact Git commit.'
    }
    return $head
}

function Get-DeclarativeWorkflowManifestIdentity {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    if (-not (Get-Command Get-WinsmuxManifest -CommandType Function -ErrorAction SilentlyContinue) -or
        -not (Get-Command Get-WinsmuxVerifiedManifestIdentity -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'workflow_session_unavailable: verified manifest helpers are not loaded.'
    }
    $identity = Get-WinsmuxVerifiedManifestIdentity -Manifest (Get-WinsmuxManifest -ProjectDir $ProjectDir)
    if ($null -eq $identity) {
        throw 'workflow_session_invalid: current manifest identity is not verified.'
    }
    return [ordered]@{
        session_name = [string]$identity.session_name
        generation_id = [string]$identity.generation_id
        server_session_id = [string]$identity.server_session_id
    }
}

function Invoke-DeclarativeWorkflowWorkspacePlan {
    param(
        [Parameter(Mandatory = $true)][string]$RecipeId,
        [Parameter(Mandatory = $true)][string]$WorkflowId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    $command = ''
    foreach ($candidate in @(
        [string]$env:WINSMUX_RAW_EXE,
        [string]$env:WINSMUX_BIN,
        (Join-Path $ProjectDir 'target\release\winsmux.exe'),
        (Join-Path $ProjectDir 'target\debug\winsmux.exe')
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $command = [System.IO.Path]::GetFullPath($candidate)
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($command)) {
        $resolved = Get-Command winsmux.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $resolved) {
            throw 'workflow_plan_unavailable: winsmux executable was not found.'
        }
        $command = [string]$resolved.Path
    }

    $output = @(
        & $command workspace-plan `
            --recipe-id $RecipeId `
            --workflow-id $WorkflowId `
            --run-id $RunId `
            --project-dir $ProjectDir `
            --json 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
        throw "workflow_plan_invalid: $($output -join ' ')"
    }
    try {
        return ($output -join [Environment]::NewLine) |
            ConvertFrom-WinsmuxJson -AsHashtable -Depth 50 -ErrorAction Stop
    } catch {
        throw "workflow_plan_invalid: $($_.Exception.Message)"
    }
}

function Assert-DeclarativeWorkflowIdentity {
    param(
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)][string]$Context
    )

    foreach ($name in @('session_name', 'generation_id', 'server_session_id')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-DeclarativeWorkflowValue -InputObject $Identity -Name $name -Default ''))) {
            throw "workflow_session_invalid: $Context is missing $name."
        }
    }
}

function Assert-DeclarativeWorkflowPlan {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$RecipeId,
        [Parameter(Mandatory = $true)][string]$WorkflowId,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    if ([string](Get-DeclarativeWorkflowValue -InputObject $Plan -Name 'recipe_id' -Default '') -cne $RecipeId -or
        [string](Get-DeclarativeWorkflowValue -InputObject $Plan -Name 'workflow_id' -Default '') -cne $WorkflowId) {
        throw 'workflow_plan_invalid: selected identity mismatch.'
    }
    $configFingerprint = [string](Get-DeclarativeWorkflowValue -InputObject $Plan -Name 'config_fingerprint' -Default '')
    if ($configFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'workflow_plan_invalid: config fingerprint is invalid.'
    }
    $workflow = Get-DeclarativeWorkflowValue -InputObject $Plan -Name 'workflow'
    if ($null -eq $workflow -or
        [string](Get-DeclarativeWorkflowValue -InputObject $workflow -Name 'workflow_id' -Default '') -cne $WorkflowId -or
        [string](Get-DeclarativeWorkflowValue -InputObject $workflow -Name 'run_id' -Default '') -cne $RunId) {
        throw 'workflow_plan_invalid: normalized workflow identity mismatch.'
    }
    if ([string](Get-DeclarativeWorkflowValue -InputObject $workflow -Name 'recipe_ref' -Default '') -cne $RecipeId) {
        throw 'workflow_plan_invalid: normalized workflow recipe binding mismatch.'
    }

    $nodes = @(Get-DeclarativeWorkflowValue -InputObject $workflow -Name 'nodes' -Default @())
    $order = @(Get-DeclarativeWorkflowValue -InputObject $workflow -Name 'topological_order' -Default @())
    if ($nodes.Count -eq 0 -or $order.Count -ne $nodes.Count) {
        throw 'workflow_plan_invalid: normalized workflow is empty or unordered.'
    }
    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($node in $nodes) {
        $nodeId = [string](Get-DeclarativeWorkflowValue -InputObject $node -Name 'node_id' -Default '')
        $paneRef = [string](Get-DeclarativeWorkflowValue -InputObject $node -Name 'pane_ref' -Default '')
        $action = [string](Get-DeclarativeWorkflowValue -InputObject $node -Name 'action' -Default '')
        $idempotencyKey = [string](Get-DeclarativeWorkflowValue -InputObject $node -Name 'idempotency_key' -Default '')
        Assert-DeclarativeWorkflowIdentifier -Value $nodeId -Name 'node_id'
        if (-not $ids.Add($nodeId) -or [string]::IsNullOrWhiteSpace($paneRef) -or
            $action -cne 'operator-dispatch' -or
            $idempotencyKey -cne "$RunId`:$nodeId") {
            throw 'workflow_plan_invalid: normalized node contract is invalid.'
        }
    }
    if (@($order | Where-Object { -not $ids.Contains([string]$_) }).Count -gt 0) {
        throw 'workflow_plan_invalid: topological order references an unknown node.'
    }
    return $workflow
}

function ConvertTo-DeclarativeWorkflowPowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function New-DeclarativeWorkflowDispatchPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$TaskContent,
        [Parameter(Mandatory = $true)]$Node,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$ResultAdapterPath
    )

    $nodeId = [string](Get-DeclarativeWorkflowValue -InputObject $Node -Name 'node_id' -Default '')
    Assert-DeclarativeWorkflowIdentifier -Value $nodeId -Name 'node_id'
    $runId = [string](Get-DeclarativeWorkflowValue -InputObject $Run -Name 'run_id' -Default '')
    Assert-DeclarativeWorkflowIdentifier -Value $runId -Name 'run_id'
    $taskDigest = [string](Get-DeclarativeWorkflowValue -InputObject $Run -Name 'task_digest' -Default '')
    $workflowFingerprint = [string](Get-DeclarativeWorkflowValue -InputObject $Run -Name 'workflow_fingerprint' -Default '')
    if ($taskDigest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        $workflowFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'workflow_dispatch_invalid: durable content identity is missing.'
    }

    $resolvedProject = [IO.Path]::GetFullPath($ProjectDir)
    $resolvedAdapter = [IO.Path]::GetFullPath($ResultAdapterPath)
    $callback = [ordered]@{
        schema_version = 1
        adapter_path = $resolvedAdapter
        project_dir = $resolvedProject
        run_id = $runId
        node_id = $nodeId
        task_digest = $taskDigest
        workflow_fingerprint = $workflowFingerprint
    }
    $callbackJson = $callback | ConvertTo-Json -Depth 5 -Compress
    $adapterLiteral = ConvertTo-DeclarativeWorkflowPowerShellLiteral -Value $resolvedAdapter
    $projectLiteral = ConvertTo-DeclarativeWorkflowPowerShellLiteral -Value $resolvedProject
    $runLiteral = ConvertTo-DeclarativeWorkflowPowerShellLiteral -Value $runId
    $nodeLiteral = ConvertTo-DeclarativeWorkflowPowerShellLiteral -Value $nodeId
    $commandPrefix = "pwsh -NoProfile -File $adapterLiteral -WorkflowResult -RunId $runLiteral " +
        "-WorkflowResultNodeId $nodeLiteral -ProjectDir $projectLiteral"
    $successCommand = "$commandPrefix -WorkflowResultOutcome succeeded " +
        '-WorkflowResultExitCode 0 -AsJson'
    $failureCommand = "$commandPrefix -WorkflowResultOutcome failed " +
        '-WorkflowResultExitCode 1 -AsJson'
    $lineBreak = "`n"
    $contract = @(
        '<winsmux-workflow-result-v1>',
        $callbackJson,
        'After completing this node, execute exactly one result command.',
        "Success command: $successCommand",
        "Failure command: $failureCommand",
        '</winsmux-workflow-result-v1>'
    ) -join $lineBreak

    return $TaskContent + $lineBreak + $lineBreak + $contract
}

function Get-DeclarativeWorkflowNode {
    param(
        [Parameter(Mandatory = $true)]$Workflow,
        [Parameter(Mandatory = $true)][string]$NodeId
    )

    return @(
        @(Get-DeclarativeWorkflowValue -InputObject $Workflow -Name 'nodes' -Default @())) |
        Where-Object {
            [string](Get-DeclarativeWorkflowValue -InputObject $_ -Name 'node_id' -Default '') -ceq $NodeId
        } |
        Select-Object -First 1
}

function Update-DeclarativeWorkflowOverallState {
    param([Parameter(Mandatory = $true)]$State)

    $nodeStates = @(
        foreach ($nodeId in @($State['nodes'].Keys)) {
            [string]$State['nodes'][$nodeId]['state']
        }
    )
    if ($nodeStates.Count -gt 0 -and @($nodeStates | Where-Object { $_ -cne 'succeeded' }).Count -eq 0) {
        $State['state'] = 'succeeded'
    } elseif (@($nodeStates | Where-Object { $_ -in @('running', 'dispatching') }).Count -gt 0) {
        $State['state'] = 'running'
    } elseif ($nodeStates -contains 'blocked') {
        $State['state'] = 'blocked'
    } elseif ($nodeStates -contains 'failed') {
        $State['state'] = 'failed'
    } else {
        $State['state'] = 'blocked'
    }
}

function Invoke-DeclarativeWorkflowReadyNodes {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$TaskContent,
        [Parameter(Mandatory = $true)][scriptblock]$DispatchNode
    )

    $workflow = $State['workflow']
    foreach ($nodeIdValue in @(Get-DeclarativeWorkflowValue -InputObject $workflow -Name 'topological_order' -Default @())) {
        $nodeId = [string]$nodeIdValue
        $nodeState = $State['nodes'][$nodeId]
        if ([string]$nodeState['state'] -cne 'pending') {
            continue
        }
        $node = Get-DeclarativeWorkflowNode -Workflow $workflow -NodeId $nodeId
        $dependencies = @(Get-DeclarativeWorkflowValue -InputObject $node -Name 'depends_on' -Default @())
        $ready = @($dependencies | Where-Object {
                [string]$State['nodes'][[string]$_]['state'] -cne 'succeeded'
            }).Count -eq 0
        if (-not $ready) {
            continue
        }

        $nodeState['state'] = 'dispatching'
        Update-DeclarativeWorkflowOverallState -State $State
        Set-DeclarativeWorkflowRunState -ProjectDir $ProjectDir -RunId ([string]$State['run_id']) -State $State | Out-Null
        $receipt = & $DispatchNode $node $TaskContent $State
        if ($null -eq $receipt -or
            -not [bool](Get-DeclarativeWorkflowValue -InputObject $receipt -Name 'accepted' -Default $false)) {
            throw "workflow_dispatch_rejected: $nodeId"
        }
        $nodeState['state'] = 'running'
        Update-DeclarativeWorkflowOverallState -State $State
        Set-DeclarativeWorkflowRunState -ProjectDir $ProjectDir -RunId ([string]$State['run_id']) -State $State | Out-Null
    }
}

function New-DeclarativeWorkflowRunState {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$Workflow,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$TaskSnapshot,
        [Parameter(Mandatory = $true)][string]$SourceHead,
        [Parameter(Mandatory = $true)]$Session
    )

    $nodes = [ordered]@{}
    foreach ($node in @(Get-DeclarativeWorkflowValue -InputObject $Workflow -Name 'nodes' -Default @())) {
        $nodeId = [string](Get-DeclarativeWorkflowValue -InputObject $node -Name 'node_id' -Default '')
        $nodes[$nodeId] = [ordered]@{
            state = 'pending'
            pane_ref = [string](Get-DeclarativeWorkflowValue -InputObject $node -Name 'pane_ref' -Default '')
            idempotency_key = [string](Get-DeclarativeWorkflowValue -InputObject $node -Name 'idempotency_key' -Default '')
            message_id = $null
            result_digest = $null
            exit_code = $null
        }
    }

    return [ordered]@{
        schema_version = 1
        run_id = $RunId
        created_at = [System.DateTimeOffset]::UtcNow.ToString('o')
        recipe_id = [string](Get-DeclarativeWorkflowValue -InputObject $Plan -Name 'recipe_id' -Default '')
        workflow_id = [string](Get-DeclarativeWorkflowValue -InputObject $Plan -Name 'workflow_id' -Default '')
        state = 'running'
        config_fingerprint = [string](Get-DeclarativeWorkflowValue -InputObject $Plan -Name 'config_fingerprint' -Default '')
        workflow = ConvertTo-DeclarativeWorkflowCanonicalObject -Value $Workflow
        workflow_fingerprint = Get-DeclarativeWorkflowContentDigest -Workflow $Workflow
        source_head = $SourceHead
        task_digest = [string]$TaskSnapshot.digest
        task_bytes = [int64]$TaskSnapshot.bytes.Length
        session = ConvertTo-DeclarativeWorkflowCanonicalObject -Value $Session
        nodes = $nodes
        admitted_messages = @()
    }
}

function Assert-DeclarativeWorkflowEnvelope {
    param(
        [Parameter(Mandatory = $true)]$Envelope,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $topLevel = @(
        'mailbox_version', 'message_id', 'correlation_id', 'causation_id',
        'idempotency_key', 'message_type', 'state', 'ttl_seconds',
        'ack_required', 'from', 'to', 'content', 'timestamp'
    )
    $contentFields = @(
        'run_id', 'node_id', 'node_idempotency_key', 'session_name',
        'generation_id', 'server_session_id', 'workflow_fingerprint',
        'task_digest', 'outcome', 'exit_code', 'result_digest'
    )
    if ($Envelope -isnot [System.Collections.IDictionary]) {
        $Envelope = ConvertTo-DeclarativeWorkflowCanonicalObject -Value $Envelope
    }
    $unexpectedTop = @($Envelope.Keys | Where-Object { [string]$_ -notin $topLevel })
    $missingTop = @($topLevel | Where-Object { -not $Envelope.Contains($_) })
    if ($unexpectedTop.Count -gt 0 -or $missingTop.Count -gt 0) {
        throw 'workflow_mailbox_invalid: envelope fields are not canonical.'
    }

    $messageId = [string]$Envelope['message_id']
    Assert-DeclarativeWorkflowIdentifier -Value $messageId -Name 'message_id'
    $content = $Envelope['content']
    if ($content -isnot [System.Collections.IDictionary]) {
        $content = ConvertTo-DeclarativeWorkflowCanonicalObject -Value $content
    }
    $unexpectedContent = @($content.Keys | Where-Object { [string]$_ -notin $contentFields })
    $missingContent = @($contentFields | Where-Object { -not $content.Contains($_) })
    if ($unexpectedContent.Count -gt 0 -or $missingContent.Count -gt 0) {
        throw 'workflow_mailbox_invalid: result fields are not canonical.'
    }

    $nodeId = [string]$content['node_id']
    Assert-DeclarativeWorkflowIdentifier -Value $nodeId -Name 'node_id'
    if (-not $Run['nodes'].Contains($nodeId)) {
        throw 'workflow_mailbox_invalid: node identity is unknown.'
    }
    $node = Get-DeclarativeWorkflowNode -Workflow $Run['workflow'] -NodeId $nodeId
    $session = $Run['session']
    $outcome = [string]$content['outcome']
    $exitCode = [int]$content['exit_code']
    $expectedResultDigest = Get-DeclarativeWorkflowSha256 -Bytes (
        [System.Text.Encoding]::UTF8.GetBytes("$outcome`:$exitCode`:$nodeId")
    )

    if ([int]$Envelope['mailbox_version'] -ne 2 -or
        [string]$Envelope['correlation_id'] -cne $messageId -or
        [string]$Envelope['idempotency_key'] -cne "mailbox:v2:$RunId`:$nodeId" -or
        [string]$Envelope['message_type'] -cne 'workflow_result' -or
        [string]$Envelope['state'] -cne 'created' -or
        [int]$Envelope['ttl_seconds'] -le 0 -or
        -not [bool]$Envelope['ack_required'] -or
        [string]$Envelope['to'] -cne 'Operator' -or
        [string]$Envelope['from'] -cne [string](Get-DeclarativeWorkflowValue -InputObject $node -Name 'pane_ref' -Default '') -or
        [string]$content['run_id'] -cne $RunId -or
        [string]$content['node_idempotency_key'] -cne [string]$Run['nodes'][$nodeId]['idempotency_key'] -or
        [string]$content['session_name'] -cne [string]$session['session_name'] -or
        -not [string]::Equals([string]$content['generation_id'], [string]$session['generation_id'], [StringComparison]::Ordinal) -or
        [string]$content['server_session_id'] -cne [string]$session['server_session_id'] -or
        [string]$content['workflow_fingerprint'] -cne [string]$Run['workflow_fingerprint'] -or
        [string]$content['task_digest'] -cne [string]$Run['task_digest'] -or
        [string]$content['result_digest'] -cne $expectedResultDigest -or
        ($outcome -ceq 'succeeded' -and $exitCode -ne 0) -or
        ($outcome -ceq 'failed' -and $exitCode -eq 0) -or
        $outcome -cnotin @('succeeded', 'failed')) {
        throw 'workflow_mailbox_invalid: result identity or outcome is contradictory.'
    }

    return [ordered]@{
        message_id = $messageId
        node_id = $nodeId
        outcome = $outcome
        exit_code = $exitCode
        result_digest = [string]$content['result_digest']
        envelope = ConvertTo-DeclarativeWorkflowCanonicalObject -Value $Envelope
    }
}

function Get-DeclarativeWorkflowMailboxDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][ValidateSet('pending', 'consumed')][string]$State
    )

    Assert-DeclarativeWorkflowIdentifier -Value $RunId -Name 'run_id'
    return Join-Path (Join-Path (Join-Path (Join-Path ([System.IO.Path]::GetFullPath($ProjectDir)) '.winsmux') 'workflow-mailbox') $RunId) $State
}

function Read-DeclarativeWorkflowMailboxFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            throw 'UTF-8 BOM is not allowed.'
        }
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $value = $text | ConvertFrom-WinsmuxJson -AsHashtable -Depth 50 -ErrorAction Stop
        return [PSCustomObject]@{
            path = $Path
            bytes = $bytes
            value = $value
        }
    } catch {
        throw "workflow_mailbox_invalid: $($_.Exception.Message)"
    }
}

function Get-DeclarativeWorkflowMailboxPublication {
    param(
        [Parameter(Mandatory = $true)][string]$PendingPath,
        [Parameter(Mandatory = $true)][string]$ConsumedPath,
        [Parameter(Mandatory = $true)][byte[]]$ExpectedBytes
    )

    foreach ($candidate in @(
            [PSCustomObject]@{ Path = $PendingPath; State = 'pending' },
            [PSCustomObject]@{ Path = $ConsumedPath; State = 'consumed' }
        )) {
        $stream = $null
        $memory = $null
        try {
            try {
                $stream = [System.IO.FileStream]::new(
                    $candidate.Path,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
                )
            } catch [System.IO.FileNotFoundException] {
                continue
            } catch [System.IO.DirectoryNotFoundException] {
                continue
            }
            $memory = [System.IO.MemoryStream]::new()
            $stream.CopyTo($memory)
            $existing = $memory.ToArray()
            if (-not [System.Linq.Enumerable]::SequenceEqual[byte]($existing, $ExpectedBytes)) {
                throw 'workflow_mailbox_conflict: message_id already has different bytes.'
            }
            return [PSCustomObject]@{
                accepted = $true
                duplicate = $true
                state = [string]$candidate.State
            }
        } finally {
            if ($null -ne $memory) {
                $memory.Dispose()
            }
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
    }
    return $null
}

function Write-DeclarativeWorkflowMailboxResultCore {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$Payload
    )

    try {
        $envelope = if ($Payload -is [string]) {
            $Payload | ConvertFrom-WinsmuxJson -AsHashtable -Depth 50 -ErrorAction Stop
        } else {
            ConvertTo-DeclarativeWorkflowCanonicalObject -Value $Payload
        }
    } catch {
        throw "workflow_mailbox_invalid: $($_.Exception.Message)"
    }
    $record = Assert-DeclarativeWorkflowEnvelope -Envelope $envelope -Run $Run -RunId $RunId
    $json = ConvertTo-DeclarativeWorkflowCanonicalJson -Value $record.envelope
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)

    $pendingDir = Get-DeclarativeWorkflowMailboxDirectory -ProjectDir $ProjectDir -RunId $RunId -State pending
    $consumedDir = Get-DeclarativeWorkflowMailboxDirectory -ProjectDir $ProjectDir -RunId $RunId -State consumed
    [System.IO.Directory]::CreateDirectory($pendingDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($consumedDir) | Out-Null
    $pendingPath = Join-Path $pendingDir "$($record.message_id).json"
    $consumedPath = Join-Path $consumedDir "$($record.message_id).json"

    $existing = Get-DeclarativeWorkflowMailboxPublication `
        -PendingPath $pendingPath -ConsumedPath $consumedPath -ExpectedBytes $bytes
    if ($null -ne $existing) {
        $existing | Add-Member -NotePropertyName message_id `
            -NotePropertyValue $record.message_id
        return $existing
    }

    $temporary = Join-Path $pendingDir (".{0}.{1}.tmp" -f $record.message_id, [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllBytes($temporary, $bytes)
    try {
        try {
            [System.IO.File]::Move($temporary, $pendingPath)
        } catch [System.IO.IOException] {
            $collision = Get-DeclarativeWorkflowMailboxPublication `
                -PendingPath $pendingPath -ConsumedPath $consumedPath -ExpectedBytes $bytes
            if ($null -eq $collision) {
                throw
            }
            $collision | Add-Member -NotePropertyName message_id `
                -NotePropertyValue $record.message_id
            return $collision
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    return [PSCustomObject]@{
        accepted = $true
        duplicate = $false
        message_id = $record.message_id
        state = 'pending'
    }
}

function Write-DeclarativeWorkflowMailboxResult {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Payload
    )

    $lease = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $ProjectDir -RunId $RunId
    try {
        $run = Read-DeclarativeWorkflowRunState -ProjectDir $ProjectDir -RunId $RunId
        return Write-DeclarativeWorkflowMailboxResultCore `
            -ProjectDir $ProjectDir -RunId $RunId -Run $run -Payload $Payload
    } finally {
        $lease.Dispose()
    }
}

function Write-DeclarativeWorkflowNodeResult {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$NodeId,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [Parameter(Mandatory = $true)][int]$ExitCode
    )

    Assert-DeclarativeWorkflowIdentifier -Value $RunId -Name 'run_id'
    Assert-DeclarativeWorkflowIdentifier -Value $NodeId -Name 'node_id'
    if ($Outcome -cnotin @('succeeded', 'failed') -or
        ($Outcome -ceq 'succeeded' -and $ExitCode -ne 0) -or
        ($Outcome -ceq 'failed' -and $ExitCode -eq 0)) {
        throw 'workflow_result_invalid: outcome and exit code are contradictory.'
    }

    $run = Read-DeclarativeWorkflowRunState -ProjectDir $ProjectDir -RunId $RunId
    if (-not $run['nodes'].Contains($NodeId)) {
        throw 'workflow_result_invalid: node identity is unknown.'
    }
    $nodeState = $run['nodes'][$NodeId]
    $nodeOutcome = [string]$nodeState['state']
    $isReplay = $nodeOutcome -cin @('succeeded', 'failed')
    if (-not $isReplay -and
        $nodeOutcome -cnotin @('dispatching', 'running', 'blocked')) {
        throw "workflow_result_invalid: node '$NodeId' is not awaiting a result."
    }
    $node = Get-DeclarativeWorkflowNode -Workflow $run['workflow'] -NodeId $NodeId
    $resultDigest = Get-DeclarativeWorkflowSha256 -Bytes (
        [System.Text.Encoding]::UTF8.GetBytes("$Outcome`:$ExitCode`:$NodeId")
    )
    $messageIdentity = Get-DeclarativeWorkflowSha256 -Bytes (
        [System.Text.Encoding]::UTF8.GetBytes(
            "$RunId`0$NodeId`0$Outcome`0$ExitCode`0$resultDigest"
        )
    )
    $messageId = 'result-' + $messageIdentity.Substring(7, 32)
    if ($isReplay) {
        if ($Outcome -cne $nodeOutcome -or
            $ExitCode -ne [int]$nodeState['exit_code'] -or
            $resultDigest -cne [string]$nodeState['result_digest'] -or
            $messageId -cne [string]$nodeState['message_id'] -or
            @($run['admitted_messages']) -cnotcontains $messageId) {
            throw "workflow_result_conflict: terminal node '$NodeId' already owns a different result."
        }
        $mailbox = Get-DeclarativeWorkflowMailboxRecords `
            -ProjectDir $ProjectDir -RunId $RunId -Run $run
        Assert-DeclarativeWorkflowStateProofConsistency -State $run -Mailbox $mailbox
    }
    $createdAtValue = Get-DeclarativeWorkflowValue -InputObject $run -Name 'created_at' -Default ''
    if ([string]::IsNullOrWhiteSpace([string]$createdAtValue)) {
        throw 'workflow_state_invalid: created_at is missing.'
    }
    $createdAt = ConvertTo-DeclarativeWorkflowUtcTimestamp -Value $createdAtValue
    $session = $run['session']
    $envelope = [ordered]@{
        mailbox_version = 2
        message_id = $messageId
        correlation_id = $messageId
        causation_id = $null
        idempotency_key = "mailbox:v2:$RunId`:$NodeId"
        message_type = 'workflow_result'
        state = 'created'
        ttl_seconds = 300
        ack_required = $true
        from = [string](Get-DeclarativeWorkflowValue -InputObject $node -Name 'pane_ref' -Default '')
        to = 'Operator'
        content = [ordered]@{
            run_id = $RunId
            node_id = $NodeId
            node_idempotency_key = [string]$nodeState['idempotency_key']
            session_name = [string]$session['session_name']
            generation_id = [string]$session['generation_id']
            server_session_id = [string]$session['server_session_id']
            workflow_fingerprint = [string]$run['workflow_fingerprint']
            task_digest = [string]$run['task_digest']
            outcome = $Outcome
            exit_code = $ExitCode
            result_digest = $resultDigest
        }
        timestamp = $createdAt
    }
    return Write-DeclarativeWorkflowMailboxResultCore `
        -ProjectDir $ProjectDir -RunId $RunId -Run $run -Payload $envelope
}

function Get-DeclarativeWorkflowMailboxRecords {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$Run
    )

    $byMessage = [ordered]@{}
    foreach ($mailboxState in @('consumed', 'pending')) {
        $directory = Get-DeclarativeWorkflowMailboxDirectory -ProjectDir $ProjectDir -RunId $RunId -State $mailboxState
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            continue
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -File -Filter '*.json' | Sort-Object Name)) {
            $loaded = Read-DeclarativeWorkflowMailboxFile -Path $file.FullName
            $record = Assert-DeclarativeWorkflowEnvelope -Envelope $loaded.value -Run $Run -RunId $RunId
            if ($file.BaseName -cne [string]$record.message_id) {
                throw 'workflow_mailbox_invalid: filename and message identity differ.'
            }
            $canonicalBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
                (ConvertTo-DeclarativeWorkflowCanonicalJson -Value $record.envelope)
            )
            if ($byMessage.Contains([string]$record.message_id)) {
                $existing = $byMessage[[string]$record.message_id]
                if (-not [System.Linq.Enumerable]::SequenceEqual[byte]($existing.bytes, $canonicalBytes)) {
                    throw 'workflow_mailbox_conflict: duplicate message bytes differ.'
                }
                if ($mailboxState -ceq 'pending') {
                    $existing.pending_path = $file.FullName
                }
                continue
            }
            $byMessage[[string]$record.message_id] = [ordered]@{
                record = $record
                bytes = $canonicalBytes
                pending_path = if ($mailboxState -ceq 'pending') { $file.FullName } else { $null }
                consumed_path = if ($mailboxState -ceq 'consumed') { $file.FullName } else { $null }
            }
        }
    }
    return $byMessage
}

function Assert-DeclarativeWorkflowStateProofConsistency {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Mailbox
    )

    $admitted = @($State['admitted_messages'] | ForEach-Object { [string]$_ })
    $admittedSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($messageId in $admitted) {
        if ([string]::IsNullOrWhiteSpace($messageId) -or -not $admittedSet.Add($messageId)) {
            throw 'workflow_state_proof_invalid: admitted message identities are not unique.'
        }
    }

    $ownedProofs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($nodeId in @($State['nodes'].Keys)) {
        $nodeState = $State['nodes'][$nodeId]
        $nodeOutcome = [string]$nodeState['state']
        $messageId = [string]$nodeState['message_id']
        $resultDigest = [string]$nodeState['result_digest']
        $hasExitCode = $null -ne $nodeState['exit_code']
        $terminal = $nodeOutcome -cin @('succeeded', 'failed')
        if (-not $terminal) {
            if (-not [string]::IsNullOrWhiteSpace($messageId) -or
                -not [string]::IsNullOrWhiteSpace($resultDigest) -or
                $hasExitCode) {
                throw "workflow_state_proof_invalid: nonterminal node '$nodeId' claims result proof."
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($messageId) -or
            [string]::IsNullOrWhiteSpace($resultDigest) -or
            -not $hasExitCode -or
            -not $admittedSet.Contains($messageId) -or
            -not $Mailbox.Contains($messageId) -or
            -not $ownedProofs.Add($messageId)) {
            throw "workflow_state_proof_invalid: terminal node '$nodeId' has no unique admitted proof."
        }
        $record = $Mailbox[$messageId]['record']
        if ([string]$record['message_id'] -cne $messageId -or
            [string]$record['node_id'] -cne [string]$nodeId -or
            [string]$record['outcome'] -cne $nodeOutcome -or
            [int]$record['exit_code'] -ne [int]$nodeState['exit_code'] -or
            [string]$record['result_digest'] -cne $resultDigest) {
            throw "workflow_state_proof_invalid: terminal node '$nodeId' proof does not match state."
        }
    }

    foreach ($messageId in $admitted) {
        if (-not $Mailbox.Contains($messageId) -or -not $ownedProofs.Contains($messageId)) {
            throw 'workflow_state_proof_invalid: admitted proof is not owned by one terminal node.'
        }
    }
}

function Move-DeclarativeWorkflowMessageToConsumed {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$MailboxEntry
    )

    $pendingPath = [string]$MailboxEntry['pending_path']
    if ([string]::IsNullOrWhiteSpace($pendingPath) -or
        -not (Test-Path -LiteralPath $pendingPath -PathType Leaf)) {
        return
    }
    $consumedDir = Get-DeclarativeWorkflowMailboxDirectory -ProjectDir $ProjectDir -RunId $RunId -State consumed
    [System.IO.Directory]::CreateDirectory($consumedDir) | Out-Null
    $destination = Join-Path $consumedDir ([System.IO.Path]::GetFileName($pendingPath))
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllBytes($destination)
        if (-not [System.Linq.Enumerable]::SequenceEqual[byte]($existing, [byte[]]$MailboxEntry['bytes'])) {
            throw 'workflow_mailbox_conflict: consumed message bytes differ.'
        }
        Remove-Item -LiteralPath $pendingPath -Force
        return
    }
    [System.IO.File]::Move($pendingPath, $destination)
}

function Invoke-DeclarativeWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$RecipeId = '',
        [string]$WorkflowId = '',
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$TaskFile,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [scriptblock]$WorkspacePlanInvoker,
        [scriptblock]$ManifestIdentityReader,
        [scriptblock]$SourceHeadReader,
        [scriptblock]$DispatchNode
    )

    if ($Action -cnotin @('start', 'resume')) {
        throw 'workflow_action_invalid: expected start or resume.'
    }
    Assert-DeclarativeWorkflowIdentifier -Value $RunId -Name 'run_id'
    $resolvedProject = [System.IO.Path]::GetFullPath($ProjectDir)
    $task = Get-DeclarativeWorkflowTaskSnapshot -TaskFile $TaskFile
    if ($null -eq $WorkspacePlanInvoker) {
        $WorkspacePlanInvoker = {
            param($SelectedRecipeId, $SelectedWorkflowId, $SelectedRunId, $SelectedProjectDir)
            Invoke-DeclarativeWorkflowWorkspacePlan `
                -RecipeId $SelectedRecipeId -WorkflowId $SelectedWorkflowId `
                -RunId $SelectedRunId -ProjectDir $SelectedProjectDir
        }
    }
    if ($null -eq $ManifestIdentityReader) {
        $ManifestIdentityReader = {
            param($SelectedProjectDir)
            Get-DeclarativeWorkflowManifestIdentity -ProjectDir $SelectedProjectDir
        }
    }
    if ($null -eq $SourceHeadReader) {
        $SourceHeadReader = {
            param($SelectedProjectDir)
            Get-DeclarativeWorkflowSourceHead -ProjectDir $SelectedProjectDir
        }
    }
    if ($null -eq $DispatchNode) {
        $resultAdapterPath = [System.IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot 'team-pipeline.ps1')
        )
        if (-not (Test-Path -LiteralPath $resultAdapterPath -PathType Leaf)) {
            throw "workflow_dispatch_unavailable: result adapter was not found: $resultAdapterPath"
        }
        $DispatchNode = {
            param($Node, $TaskContent, $Run)
            if (-not (Get-Command Invoke-TeamPipelineGuardedSend -CommandType Function -ErrorAction SilentlyContinue)) {
                throw 'workflow_dispatch_unavailable: guarded send is not loaded.'
            }
            $target = [string](Get-DeclarativeWorkflowValue -InputObject $Node -Name 'pane_ref' -Default '')
            $prompt = New-DeclarativeWorkflowDispatchPrompt `
                -TaskContent $TaskContent -Node $Node -Run $Run `
                -ProjectDir $resolvedProject -ResultAdapterPath $resultAdapterPath
            $blocked = Invoke-TeamPipelineGuardedSend `
                -StageName 'WORKFLOW' -Target $target -Prompt $prompt `
                -WorkflowPromptStdin `
                -ProjectDir $resolvedProject -SessionName ([string]$Run['session']['session_name']) `
                -ExpectedGenerationId ([string]$Run['session']['generation_id']) `
                -ExpectedServerSessionId ([string]$Run['session']['server_session_id']) `
                -Role 'Worker' -Task $TaskContent
            if ($null -ne $blocked) {
                throw "workflow_dispatch_rejected: $target"
            }
            return [ordered]@{ accepted = $true }
        }.GetNewClosure()
    }

    $lease = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $resolvedProject -RunId $RunId
    try {
        if ($Action -ceq 'start') {
            if ([string]::IsNullOrWhiteSpace($RecipeId) -or [string]::IsNullOrWhiteSpace($WorkflowId)) {
                throw 'workflow_start_invalid: recipe_id and workflow_id are required.'
            }
            $statePath = Get-DeclarativeWorkflowRunStatePath -ProjectDir $resolvedProject -RunId $RunId
            if (Test-Path -LiteralPath $statePath -PathType Leaf) {
                throw 'workflow_run_exists'
            }
            $plan = & $WorkspacePlanInvoker $RecipeId $WorkflowId $RunId $resolvedProject
            $workflow = Assert-DeclarativeWorkflowPlan `
                -Plan $plan -RecipeId $RecipeId -WorkflowId $WorkflowId -RunId $RunId
            $session = & $ManifestIdentityReader $resolvedProject
            Assert-DeclarativeWorkflowIdentity -Identity $session -Context 'current manifest'
            $sourceHead = [string](& $SourceHeadReader $resolvedProject)
            if ($sourceHead -cnotmatch '^[0-9a-f]{40}$') {
                throw 'workflow_source_invalid: expected an exact Git commit.'
            }
            $state = New-DeclarativeWorkflowRunState `
                -Plan $plan -Workflow $workflow -RunId $RunId -TaskSnapshot $task `
                -SourceHead $sourceHead -Session $session
            Set-DeclarativeWorkflowRunState -ProjectDir $resolvedProject -RunId $RunId -State $state | Out-Null
            Invoke-DeclarativeWorkflowReadyNodes `
                -State $state -ProjectDir $resolvedProject -TaskContent $task.text -DispatchNode $DispatchNode
            Update-DeclarativeWorkflowOverallState -State $state
            Set-DeclarativeWorkflowRunState -ProjectDir $resolvedProject -RunId $RunId -State $state | Out-Null
            return Read-DeclarativeWorkflowRunState -ProjectDir $resolvedProject -RunId $RunId
        }

        $state = Read-DeclarativeWorkflowRunState -ProjectDir $resolvedProject -RunId $RunId
        $terminalState = [string]$state['state'] -in @('succeeded', 'failed', 'cancelled')
        $persistedFingerprint = Get-DeclarativeWorkflowContentDigest -Workflow $state['workflow']
        if ($persistedFingerprint -cne [string]$state['workflow_fingerprint']) {
            throw 'workflow fingerprint mismatch: persisted content changed.'
        }
        if ($terminalState) {
            if ($task.digest -cne [string]$state['task_digest'] -or
                [int64]$task.bytes.Length -ne [int64]$state['task_bytes']) {
                throw 'workflow task identity changed.'
            }
            if ([string]$state['state'] -ceq 'cancelled') {
                throw "workflow_terminal: $([string]$state['state'])"
            }

            $terminalMailbox = Get-DeclarativeWorkflowMailboxRecords `
                -ProjectDir $resolvedProject -RunId $RunId -Run $state
            $terminalPending = @(
                $terminalMailbox.Values |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace([string]($_['pending_path']))
                    }
            )
            if ($terminalPending.Count -eq 0) {
                throw "workflow_terminal: $([string]$state['state'])"
            }

            Assert-DeclarativeWorkflowStateProofConsistency `
                -State $state -Mailbox $terminalMailbox
            $terminalAdmitted = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal
            )
            foreach ($messageId in @($state['admitted_messages'])) {
                $null = $terminalAdmitted.Add([string]$messageId)
            }
            foreach ($entry in @($terminalMailbox.Values)) {
                $messageId = [string]$entry['record']['message_id']
                if (-not $terminalAdmitted.Contains($messageId)) {
                    throw 'workflow_mailbox_invalid: terminal run contains unadmitted proof.'
                }
            }
            foreach ($entry in $terminalPending) {
                Move-DeclarativeWorkflowMessageToConsumed `
                    -ProjectDir $resolvedProject -RunId $RunId -MailboxEntry $entry
            }
            return Read-DeclarativeWorkflowRunState `
                -ProjectDir $resolvedProject -RunId $RunId
        }
        $plan = & $WorkspacePlanInvoker `
            ([string]$state['recipe_id']) ([string]$state['workflow_id']) $RunId $resolvedProject
        $currentWorkflow = Assert-DeclarativeWorkflowPlan `
            -Plan $plan -RecipeId ([string]$state['recipe_id']) `
            -WorkflowId ([string]$state['workflow_id']) -RunId $RunId
        if ((Get-DeclarativeWorkflowContentDigest -Workflow $currentWorkflow) -cne $persistedFingerprint -or
            [string](Get-DeclarativeWorkflowValue -InputObject $plan -Name 'config_fingerprint' -Default '') -cne
                [string]$state['config_fingerprint']) {
            throw 'workflow fingerprint mismatch: current content changed.'
        }
        if ($task.digest -cne [string]$state['task_digest'] -or
            [int64]$task.bytes.Length -ne [int64]$state['task_bytes']) {
            throw 'workflow task identity changed.'
        }
        $sourceHead = [string](& $SourceHeadReader $resolvedProject)
        if ($sourceHead -cne [string]$state['source_head']) {
            throw 'workflow source identity changed.'
        }
        $session = & $ManifestIdentityReader $resolvedProject
        Assert-DeclarativeWorkflowIdentity -Identity $session -Context 'current manifest'
        foreach ($name in @('session_name', 'generation_id', 'server_session_id')) {
            if ([string](Get-DeclarativeWorkflowValue -InputObject $session -Name $name -Default '') -cne
                [string]$state['session'][$name]) {
                throw 'workflow session identity changed.'
            }
        }

        $mailbox = Get-DeclarativeWorkflowMailboxRecords `
            -ProjectDir $resolvedProject -RunId $RunId -Run $state
        Assert-DeclarativeWorkflowStateProofConsistency -State $state -Mailbox $mailbox
        $byNode = [ordered]@{}
        foreach ($entry in @($mailbox.Values)) {
            $nodeId = [string]$entry['record']['node_id']
            if (-not $byNode.Contains($nodeId)) {
                $byNode[$nodeId] = @()
            }
            $byNode[$nodeId] = @($byNode[$nodeId]) + @($entry)
        }
        foreach ($nodeId in @($byNode.Keys)) {
            if (@($byNode[$nodeId]).Count -gt 1) {
                throw "workflow_mailbox_ambiguous: $nodeId"
            }
        }

        $moves = [System.Collections.Generic.List[object]]::new()
        foreach ($nodeIdValue in @(Get-DeclarativeWorkflowValue -InputObject $state['workflow'] -Name 'topological_order' -Default @())) {
            $nodeId = [string]$nodeIdValue
            $nodeState = $state['nodes'][$nodeId]
            $entries = @()
            if ($byNode.Contains($nodeId)) {
                $entries = @($byNode[$nodeId])
            }
            if ($entries.Count -eq 0) {
                if ([string]$nodeState['state'] -in @('running', 'dispatching')) {
                    $nodeState['state'] = 'blocked'
                }
                continue
            }

            $entry = $entries[0]
            $record = $entry['record']
            $messageId = [string]$record['message_id']
            $alreadyAdmitted = @($state['admitted_messages']) -contains $messageId
            if ($alreadyAdmitted) {
                if ([string]$nodeState['message_id'] -cne $messageId) {
                    throw 'workflow_mailbox_invalid: admitted message identity changed.'
                }
                $moves.Add($entry) | Out-Null
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$entry['consumed_path'])) {
                throw 'workflow_mailbox_invalid: unadmitted result is already consumed.'
            }

            $nodeState['message_id'] = $messageId
            $nodeState['result_digest'] = [string]$record['result_digest']
            $nodeState['exit_code'] = [int]$record['exit_code']
            $nodeState['state'] = [string]$record['outcome']
            $state['admitted_messages'] = @($state['admitted_messages']) + @($messageId)
            $moves.Add($entry) | Out-Null
        }

        Update-DeclarativeWorkflowOverallState -State $state
        Set-DeclarativeWorkflowRunState -ProjectDir $resolvedProject -RunId $RunId -State $state | Out-Null
        foreach ($entry in $moves) {
            Move-DeclarativeWorkflowMessageToConsumed `
                -ProjectDir $resolvedProject -RunId $RunId -MailboxEntry $entry
        }
        if ([string]$state['state'] -ne 'failed') {
            Invoke-DeclarativeWorkflowReadyNodes `
                -State $state -ProjectDir $resolvedProject -TaskContent $task.text -DispatchNode $DispatchNode
        }
        Update-DeclarativeWorkflowOverallState -State $state
        Set-DeclarativeWorkflowRunState -ProjectDir $resolvedProject -RunId $RunId -State $state | Out-Null
        return Read-DeclarativeWorkflowRunState -ProjectDir $resolvedProject -RunId $RunId
    } finally {
        $lease.Dispose()
    }
}
