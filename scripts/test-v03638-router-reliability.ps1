[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$Worker,
    [string]$WorkerReceiptPath = '',
    [string]$RunDirectory = '',
    [int]$ParentProcessId = 0,
    [string]$ParentNonce = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Task613BaseSha = '7aab75f7f831993c0621d74ad4e772b3971c40e5'
$script:Task613ReceiptSchema = 'winsmux.v03638.router_reliability_receipt.v1'
$script:Task613GateId = 'v03638-router-reliability'
$script:Task613TargetVersion = 'v0.36.38'
$script:Task613AuthoritySourceHashes = [ordered]@{
    coordinator_router    = '24a6493aa9dff3a52175bba7b4f9c19b278e484b5c15d685df5d02f5a252e866'
    local_router_shadow   = '0303361289e95d33aafc4280c166cc8b9281ed31a10092830d8b5e9d2fe39ffc'
    local_router_manifest = '231f5a69959caadaefb2b000d73b95bbac12547bda6c5e538b7fff40fb69bd57'
    local_router_weights  = '2b0a2bf7d4cf00ff4c85f3bcbc8c0f5bf8ae0cb380396279ded764fac1ed210d'
}

function Get-Task613RepositoryRoot {
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Get-Task613Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'task613_source_file_missing'
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-Task613GitHead {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $head = @(& git -c ("safe.directory={0}" -f $RepositoryRoot) -C $RepositoryRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw 'task613_git_head_unavailable'
    }
    $value = ($head | Out-String).Trim()
    if ($value -notmatch '^[0-9a-f]{40}$') {
        throw 'task613_git_head_invalid'
    }
    return $value
}

function Get-Task613SourceHashes {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $sources = [ordered]@{
        coordinator_router   = 'winsmux-core/scripts/coordinator-router.ps1'
        local_router_shadow  = 'winsmux-core/scripts/local-router-shadow.ps1'
        local_router_manifest = 'winsmux-core/router/local-small-router-v03621.manifest.json'
        local_router_weights = 'winsmux-core/router/local-small-router-v03621.weights.json'
    }
    $hashes = [ordered]@{}
    foreach ($entry in $sources.GetEnumerator()) {
        $hashes[[string]$entry.Key] = Get-Task613Sha256 -Path (Join-Path $RepositoryRoot ([string]$entry.Value))
    }
    return $hashes
}

function Get-Task613AuthoritySourceHashMismatches {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$SourceHashes)

    $mismatches = [Collections.Generic.List[string]]::new()
    foreach ($name in $script:Task613AuthoritySourceHashes.Keys) {
        $actual = ''
        if ($SourceHashes.Contains($name)) {
            $actual = [string]$SourceHashes[$name]
        }
        if ($actual -cne [string]$script:Task613AuthoritySourceHashes[$name]) {
            $mismatches.Add([string]$name) | Out-Null
        }
    }
    return @($mismatches.ToArray())
}

function Write-Task613JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 24 -Compress
    [IO.File]::WriteAllText($Path, ($json + "`n"), [Text.UTF8Encoding]::new($false))
}

function Read-Task613JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'task613_child_receipt_missing'
    }
    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'task613_child_receipt_empty'
    }
    return $text | ConvertFrom-Json
}

function Get-Task613RequiredProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }
    if ($null -ne $Object.PSObject -and $Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    throw 'task613_receipt_property_missing'
}

function Test-Task613ExactBoolean {
    param(
        $Value,
        [Parameter(Mandatory = $true)][bool]$Expected
    )

    return ($Value -is [bool]) -and ($Value -eq $Expected)
}

function Test-Task613ExactInteger {
    param(
        $Value,
        [Parameter(Mandatory = $true)][int]$Expected
    )

    if ($Value -isnot [sbyte] -and $Value -isnot [byte] -and $Value -isnot [int16] -and
        $Value -isnot [uint16] -and $Value -isnot [int] -and $Value -isnot [uint32] -and
        $Value -isnot [int64] -and $Value -isnot [uint64]) {
        return $false
    }
    return ([int64]$Value -eq [int64]$Expected)
}

function Test-Task613RunDirectory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\', '/'))
        $tempPrefix = $tempRoot + [IO.Path]::DirectorySeparatorChar
        if (-not $fullPath.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        if (-not ([IO.Path]::GetFileName($fullPath).StartsWith('winsmux-v03638-router-reliability-', [StringComparison]::Ordinal))) {
            return $false
        }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
            return $false
        }
        $item = Get-Item -LiteralPath $fullPath -Force
        return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
    } catch {
        return $false
    }
}

function Remove-Task613RunDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if (-not (Test-Task613RunDirectory -Path $Path)) {
        throw 'task613_run_directory_invalid'
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

function Get-Task613LogEvidence {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{
            byte_count = 0
            sha256     = ''
        }
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    return [ordered]@{
        byte_count = [int64]$bytes.LongLength
        sha256     = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    }
}

function Add-Task613Failure {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Failures,
        [Parameter(Mandatory = $true)][string]$Category
    )

    $Failures.Add([pscustomobject][ordered]@{ category = $Category }) | Out-Null
}

function Add-Task613AuthoritySourceHashFailures {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Failures,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$SourceHashes
    )

    foreach ($name in @(Get-Task613AuthoritySourceHashMismatches -SourceHashes $SourceHashes)) {
        Add-Task613Failure -Failures $Failures -Category ('authority_source_hash_mismatch_' + [string]$name)
    }
}

function Get-Task613Definitions {
    return @(
        [pscustomobject][ordered]@{
            classification       = 'normal'
            minimum_confidence   = -1.0
            expected             = [ordered]@{ slot = 'worker-1'; action = 'shadow_route'; excluded = @(); fallback = $false }
        }
        [pscustomobject][ordered]@{
            classification       = 'previous-model-failure'
            minimum_confidence   = -1.0
            expected             = [ordered]@{ slot = 'worker-2'; action = 'shadow_route'; excluded = @('worker-1:failed_route_retry_blocked'); fallback = $false }
        }
        [pscustomobject][ordered]@{
            classification       = 'previous-infrastructure-failure'
            minimum_confidence   = -1.0
            expected             = [ordered]@{ slot = 'worker-1'; action = 'shadow_route'; excluded = @(); fallback = $false }
        }
        [pscustomobject][ordered]@{
            classification       = 'write-scope-conflict'
            minimum_confidence   = -1.0
            expected             = [ordered]@{ slot = 'worker-2'; action = 'shadow_route'; excluded = @('worker-1:write_scope_conflict'); fallback = $false }
        }
        [pscustomobject][ordered]@{
            classification       = 'all-offline'
            minimum_confidence   = -1.0
            expected             = [ordered]@{ slot = $null; action = 'handle_locally'; excluded = @('worker-1:slot_unavailable', 'worker-2:slot_unavailable'); fallback = $true }
        }
        [pscustomobject][ordered]@{
            classification       = 'threshold-fallback'
            minimum_confidence   = 1.0
            expected             = [ordered]@{ slot = 'worker-1'; action = 'shadow_route'; excluded = @(); fallback = $true }
        }
    )
}

function Get-Task613ExpectedClassCounts {
    param(
        [Parameter(Mandatory = $true)][object[]]$Definitions,
        [Parameter(Mandatory = $true)][int]$RunCount
    )

    $counts = [ordered]@{}
    foreach ($definition in $Definitions) {
        $counts[[string]$definition.classification] = 0
    }
    for ($index = 0; $index -lt $RunCount; $index++) {
        $classification = [string]$Definitions[$index % $Definitions.Count].classification
        $counts[$classification] = [int]$counts[$classification] + 1
    }
    return $counts
}

function New-Task613RouteContext {
    param(
        [Parameter(Mandatory = $true)][string]$Classification,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $writeScope = @('tests/V03638RouterReliability.Tests.ps1')
    $slots = @(
        [ordered]@{ slot = 'worker-1'; provider = 'local'; roles = @('Worker'); state = 'ready'; capabilities = @('implementation', 'coding'); active_write_scope = @() },
        [ordered]@{ slot = 'worker-2'; provider = 'local'; roles = @('Worker'); state = 'ready'; capabilities = @('implementation', 'coding'); active_write_scope = @() }
    )
    $previousRoutes = @()

    switch ($Classification) {
        'previous-model-failure' {
            $previousRoutes = @([ordered]@{ slot = 'worker-1'; role = 'Worker'; outcome = 'failed'; failure_class = 'model' })
        }
        'previous-infrastructure-failure' {
            $previousRoutes = @([ordered]@{ slot = 'worker-1'; role = 'Worker'; outcome = 'failed'; failure_class = 'infrastructure' })
        }
        'write-scope-conflict' {
            $slots[0].active_write_scope = @($writeScope[0])
        }
        'all-offline' {
            $slots[0].state = 'offline'
            $slots[1].state = 'offline'
        }
    }

    return New-WinsmuxRouteContext `
        -TaskId ('TASK-613-' + $Index.ToString('000')) `
        -TaskType 'implementation' `
        -Goal 'Router reliability fixture' `
        -Priority 'P0' `
        -RequestedRole 'Worker' `
        -ReadScope @('winsmux-core/scripts/coordinator-router.ps1') `
        -WriteScope $writeScope `
        -Slots $slots `
        -PreviousRoutes $previousRoutes `
        -RemainingTurns 5
}

function Get-Task613ExcludedKeys {
    param([Parameter(Mandatory = $true)]$Decision)

    return [string[]]@($Decision.excluded | ForEach-Object {
        ('{0}:{1}' -f [string]$_.slot, [string]$_.reason)
    })
}

function Test-Task613StringSequence {
    param(
        [string[]]$Actual = @(),
        [string[]]$Expected = @()
    )

    if (@($Actual).Count -ne @($Expected).Count) {
        return $false
    }
    for ($index = 0; $index -lt @($Expected).Count; $index++) {
        if (-not [string]::Equals([string]$Actual[$index], [string]$Expected[$index], [StringComparison]::Ordinal)) {
            return $false
        }
    }
    return $true
}

function Test-Task613DeterministicOutcome {
    param(
        [Parameter(Mandatory = $true)]$Decision,
        [Parameter(Mandatory = $true)]$Expected
    )

    $actualExcluded = @(Get-Task613ExcludedKeys -Decision $Decision)
    $expectedExcluded = [string[]]@($Expected.excluded)
    return [string]::Equals([string]$Decision.decision.slot, [string]$Expected.slot, [StringComparison]::Ordinal) -and
        [string]::Equals([string]$Decision.decision.action, [string]$Expected.action, [StringComparison]::Ordinal) -and
        (Test-Task613StringSequence -Actual $actualExcluded -Expected $expectedExcluded)
}

function Test-Task613ShadowFinalOutcome {
    param(
        [Parameter(Mandatory = $true)]$ShadowDecision,
        [Parameter(Mandatory = $true)]$Expected
    )

    return [string]::Equals([string]$ShadowDecision.final_authority.slot, [string]$Expected.slot, [StringComparison]::Ordinal) -and
        [string]::Equals([string]$ShadowDecision.final_authority.action, [string]$Expected.action, [StringComparison]::Ordinal) -and
        ([bool]$ShadowDecision.fallback_required -eq [bool]$Expected.fallback)
}

function Test-Task613WorkerAuthorization {
    param(
        [string]$ReceiptPath,
        [string]$OwnedRunDirectory,
        [int]$ExpectedParentProcessId,
        [string]$Nonce
    )

    if ($ExpectedParentProcessId -le 0 -or $Nonce -notmatch '^[0-9a-f]{32}$') {
        return $false
    }
    if (-not (Test-Task613RunDirectory -Path $OwnedRunDirectory)) {
        return $false
    }
    try {
        $expectedReceiptPath = [IO.Path]::GetFullPath((Join-Path $OwnedRunDirectory 'child-receipt.json'))
        if (-not [string]::Equals([IO.Path]::GetFullPath($ReceiptPath), $expectedReceiptPath, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $tokenPath = Join-Path $OwnedRunDirectory 'parent-nonce.txt'
        if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
            return $false
        }
        $storedNonce = [IO.File]::ReadAllText($tokenPath, [Text.UTF8Encoding]::new($false, $true))
        if (-not [string]::Equals($storedNonce, $Nonce, [StringComparison]::Ordinal)) {
            return $false
        }
        return $null -ne (Get-Process -Id $ExpectedParentProcessId -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Invoke-Task613Worker {
    $failures = [Collections.Generic.List[object]]::new()
    $definitions = Get-Task613Definitions
    $runCount = 100
    $expectedCounts = Get-Task613ExpectedClassCounts -Definitions $definitions -RunCount $runCount
    $sourceHashes = [ordered]@{}
    $executedHead = ''
    $workerAuthorized = Test-Task613WorkerAuthorization `
        -ReceiptPath $WorkerReceiptPath `
        -OwnedRunDirectory $RunDirectory `
        -ExpectedParentProcessId $ParentProcessId `
        -Nonce $ParentNonce

    if (-not $workerAuthorized) {
        Add-Task613Failure -Failures $failures -Category 'worker_parent_authorization_failed'
        $workerResult = [ordered]@{
            schema        = $script:Task613ReceiptSchema
            gate_id       = $script:Task613GateId
            mode          = 'worker'
            all_pass      = $false
            release_ready = $false
            failures      = @($failures.ToArray())
        }
        return [pscustomobject][ordered]@{
            exit_code     = 1
            public_result = $workerResult
        }
    }

    $sourceHashes = [ordered]@{}
    $executedHead = ''
    $classRowsByName = @{}
    foreach ($definition in $definitions) {
        $classRowsByName[[string]$definition.classification] = [pscustomobject][ordered]@{
            classification             = [string]$definition.classification
            count                      = 0
            deterministic_matches      = 0
            shadow_final_matches       = 0
            fallback_matches           = 0
        }
    }
    $providerCalls = 0
    $validShadowDecision = $null
    $validTraceWritten = $false
    $sensitiveTraceRejected = $false
    $promptCanary = 'TASK613_PROMPT_CANARY_DO_NOT_PUBLISH'

    try {
        $repositoryRoot = Get-Task613RepositoryRoot
        $sourceHashes = Get-Task613SourceHashes -RepositoryRoot $repositoryRoot
        $executedHead = Get-Task613GitHead -RepositoryRoot $repositoryRoot
        Add-Task613AuthoritySourceHashFailures -Failures $failures -SourceHashes $sourceHashes
        $authorityHashMismatches = @(Get-Task613AuthoritySourceHashMismatches -SourceHashes $sourceHashes)
        if ($authorityHashMismatches.Count -eq 0) {
            . (Join-Path $repositoryRoot 'winsmux-core/scripts/coordinator-router.ps1')
            . (Join-Path $repositoryRoot 'winsmux-core/scripts/local-router-shadow.ps1')
            $manifestPath = Join-Path $repositoryRoot 'winsmux-core/router/local-small-router-v03621.manifest.json'

        for ($index = 0; $index -lt $runCount; $index++) {
            $definition = $definitions[$index % $definitions.Count]
            $classification = [string]$definition.classification
            $classRow = $classRowsByName[$classification]
            $classRow.count = [int]$classRow.count + 1
            try {
                $context = New-Task613RouteContext -Classification $classification -Index $index
                $deterministic = Invoke-WinsmuxDeterministicRoute -Context $context
                $shadow = if ([double]$definition.minimum_confidence -ge 0) {
                    Invoke-WinsmuxLocalRouterShadow -Context $context -ManifestPath $manifestPath -MinimumConfidence ([double]$definition.minimum_confidence)
                } else {
                    Invoke-WinsmuxLocalRouterShadow -Context $context -ManifestPath $manifestPath
                }

                if (Test-Task613DeterministicOutcome -Decision $deterministic -Expected $definition.expected) {
                    $classRow.deterministic_matches = [int]$classRow.deterministic_matches + 1
                } else {
                    Add-Task613Failure -Failures $failures -Category 'deterministic_expected_outcome_mismatch'
                }
                if (Test-Task613ShadowFinalOutcome -ShadowDecision $shadow -Expected $definition.expected) {
                    $classRow.shadow_final_matches = [int]$classRow.shadow_final_matches + 1
                } else {
                    Add-Task613Failure -Failures $failures -Category 'shadow_final_expected_outcome_mismatch'
                }
                if ([bool]$shadow.fallback_required -eq [bool]$definition.expected.fallback) {
                    $classRow.fallback_matches = [int]$classRow.fallback_matches + 1
                } else {
                    Add-Task613Failure -Failures $failures -Category 'shadow_fallback_expected_outcome_mismatch'
                }
                if ([int]$shadow.provider_calls -ne 0) {
                    Add-Task613Failure -Failures $failures -Category 'provider_call_reported'
                }
                $providerCalls += [int]$shadow.provider_calls
                if ($index -eq 0) {
                    $validShadowDecision = $shadow
                }
            } catch {
                Add-Task613Failure -Failures $failures -Category 'case_execution_failed'
            }
        }

        if ($null -eq $validShadowDecision) {
            Add-Task613Failure -Failures $failures -Category 'valid_trace_input_missing'
        } else {
            $validTracePath = Join-Path $RunDirectory 'valid-shadow-trace.jsonl'
            Write-WinsmuxLocalRouterShadowTrace -ShadowDecision $validShadowDecision -Path $validTracePath
            $validTrace = Read-Task613JsonFile -Path $validTracePath
            $validTraceWritten = ([string]$validTrace.kind -ceq 'winsmux.local_router_shadow_decision') -and
                (($validTrace | ConvertTo-Json -Depth 20 -Compress) -notmatch '"raw_prompt"')
            if (-not $validTraceWritten) {
                Add-Task613Failure -Failures $failures -Category 'valid_trace_verification_failed'
            }
        }

        $sensitiveTracePath = Join-Path $RunDirectory 'sensitive-shadow-trace.jsonl'
        try {
            Write-WinsmuxLocalRouterShadowTrace -ShadowDecision ([ordered]@{
                kind       = 'winsmux.local_router_shadow_decision'
                raw_prompt = $promptCanary
            }) -Path $sensitiveTracePath
        } catch {
            $sensitiveTraceRejected = $_.Exception.Message -like '*rejected sensitive shadow decision content*'
        }
        if (-not $sensitiveTraceRejected -or (Test-Path -LiteralPath $sensitiveTracePath -PathType Leaf)) {
            Add-Task613Failure -Failures $failures -Category 'sensitive_trace_rejection_failed'
        }
        }
    } catch {
        Add-Task613Failure -Failures $failures -Category 'worker_setup_or_trace_failed'
    }

    $classResults = @($definitions | ForEach-Object {
        $classRowsByName[[string]$_.classification]
    })
    $classCounts = [ordered]@{}
    foreach ($definition in $definitions) {
        $classification = [string]$definition.classification
        $classCounts[$classification] = [int]$classRowsByName[$classification].count
    }
    $workerAllPass = ($failures.Count -eq 0) -and ($providerCalls -eq 0) -and
        ($executedHead -match '^[0-9a-f]{40}$') -and
        (@(Get-Task613AuthoritySourceHashMismatches -SourceHashes $sourceHashes).Count -eq 0) -and
        ($classResults.Count -eq $definitions.Count)
    $childExitCode = if ($workerAllPass) { 0 } else { 1 }

    $receipt = [ordered]@{
        schema                     = $script:Task613ReceiptSchema
        gate_id                    = $script:Task613GateId
        target_version             = $script:Task613TargetVersion
        task_base_sha              = $script:Task613BaseSha
        executed_head_sha          = $executedHead
        source_sha256              = $sourceHashes
        run_count                  = $runCount
        class_counts               = $classCounts
        class_results              = $classResults
        max_batch_size             = 1
        provider_calls             = $providerCalls
        prompt_canary_occurrences  = 0
        valid_trace_written        = $validTraceWritten
        sensitive_trace_rejected   = $sensitiveTraceRejected
        failures                   = @($failures.ToArray())
        child                      = [ordered]@{
            pid        = $PID
            parent_pid = $ParentProcessId
            exit_code  = $childExitCode
        }
        release_ready             = $false
    }
    $receiptJson = $receipt | ConvertTo-Json -Depth 24 -Compress
    $receipt.prompt_canary_occurrences = [regex]::Matches($receiptJson, [regex]::Escape($promptCanary)).Count
    if ([int]$receipt.prompt_canary_occurrences -ne 0) {
        Add-Task613Failure -Failures $failures -Category 'prompt_canary_disclosure_detected'
        $receipt.failures = @($failures.ToArray())
        $receipt.child.exit_code = 1
        $workerAllPass = $false
        $childExitCode = 1
    }

    try {
        Write-Task613JsonFile -Path $WorkerReceiptPath -Value $receipt
    } catch {
        $workerAllPass = $false
        $childExitCode = 1
    }

    $workerResult = [ordered]@{
        schema        = $script:Task613ReceiptSchema
        gate_id       = $script:Task613GateId
        mode          = 'worker'
        all_pass      = $workerAllPass
        release_ready = $false
        failures      = @($failures.ToArray())
    }
    return [pscustomobject][ordered]@{
        exit_code     = $childExitCode
        public_result = $workerResult
    }
}

function Test-Task613ChildReceipt {
    param(
        [Parameter(Mandatory = $true)]$Receipt,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$SourceHashes,
        [Parameter(Mandatory = $true)][string]$ExecutedHead,
        [Parameter(Mandatory = $true)][int]$ChildProcessId,
        [Parameter(Mandatory = $true)][string]$ChildStartedAtUtc,
        [Parameter(Mandatory = $true)][int]$ChildExitCode,
        [Parameter(Mandatory = $true)][int]$ExpectedParentProcessId
    )

    $script:Task613ReceiptValidationStage = 'identity'
    try {
        if ([string](Get-Task613RequiredProperty -Object $Receipt -Name 'schema') -cne $script:Task613ReceiptSchema) { return $false }
        if ([string](Get-Task613RequiredProperty -Object $Receipt -Name 'gate_id') -cne $script:Task613GateId) { return $false }
        if ([string](Get-Task613RequiredProperty -Object $Receipt -Name 'target_version') -cne $script:Task613TargetVersion) { return $false }
        if ([string](Get-Task613RequiredProperty -Object $Receipt -Name 'task_base_sha') -cne $script:Task613BaseSha) { return $false }
        $receiptExecutedHead = [string](Get-Task613RequiredProperty -Object $Receipt -Name 'executed_head_sha')
        if ($ExecutedHead -notmatch '^[0-9a-f]{40}$' -or $receiptExecutedHead -notmatch '^[0-9a-f]{40}$') { return $false }
        if ($receiptExecutedHead -cne $ExecutedHead) { return $false }
        if (-not (Test-Task613ExactInteger -Value (Get-Task613RequiredProperty -Object $Receipt -Name 'run_count') -Expected 100)) { return $false }
        if (-not (Test-Task613ExactInteger -Value (Get-Task613RequiredProperty -Object $Receipt -Name 'max_batch_size') -Expected 1)) { return $false }
        if (-not (Test-Task613ExactInteger -Value (Get-Task613RequiredProperty -Object $Receipt -Name 'provider_calls') -Expected 0)) { return $false }
        if (-not (Test-Task613ExactInteger -Value (Get-Task613RequiredProperty -Object $Receipt -Name 'prompt_canary_occurrences') -Expected 0)) { return $false }
        if (-not (Test-Task613ExactBoolean -Value (Get-Task613RequiredProperty -Object $Receipt -Name 'valid_trace_written') -Expected $true)) { return $false }
        if (-not (Test-Task613ExactBoolean -Value (Get-Task613RequiredProperty -Object $Receipt -Name 'sensitive_trace_rejected') -Expected $true)) { return $false }
        if (-not (Test-Task613ExactBoolean -Value (Get-Task613RequiredProperty -Object $Receipt -Name 'release_ready') -Expected $false)) { return $false }

        $script:Task613ReceiptValidationStage = 'authority_source_hashes'
        if (@(Get-Task613AuthoritySourceHashMismatches -SourceHashes $SourceHashes).Count -ne 0) {
            return $false
        }
        $receiptHashes = Get-Task613RequiredProperty -Object $Receipt -Name 'source_sha256'
        foreach ($name in $script:Task613AuthoritySourceHashes.Keys) {
            $expectedHash = [string]$script:Task613AuthoritySourceHashes[$name]
            $parentHash = [string]$SourceHashes[$name]
            $receiptHash = [string](Get-Task613RequiredProperty -Object $receiptHashes -Name ([string]$name))
            if ($parentHash -cne $expectedHash -or $receiptHash -cne $expectedHash -or $receiptHash -cne $parentHash) {
                return $false
            }
        }

        $script:Task613ReceiptValidationStage = 'class_results'
        $definitions = Get-Task613Definitions
        $expectedCounts = Get-Task613ExpectedClassCounts -Definitions $definitions -RunCount 100
        $receiptCounts = Get-Task613RequiredProperty -Object $Receipt -Name 'class_counts'
        $receiptRows = @((Get-Task613RequiredProperty -Object $Receipt -Name 'class_results'))
        if ($receiptRows.Count -ne $definitions.Count) {
            $script:Task613ReceiptValidationStage = 'class_results_shape'
            return $false
        }
        $countSum = 0
        foreach ($definition in $definitions) {
            $classification = [string]$definition.classification
            $expectedCount = [int]$expectedCounts[$classification]
            $countValue = Get-Task613RequiredProperty -Object $receiptCounts -Name $classification
            if (-not (Test-Task613ExactInteger -Value $countValue -Expected $expectedCount)) {
                $script:Task613ReceiptValidationStage = 'class_counts'
                return $false
            }
            $countSum += [int]$countValue
            $matchingRows = @($receiptRows | Where-Object { [string]$_.classification -ceq $classification })
            if ($matchingRows.Count -ne 1) {
                $script:Task613ReceiptValidationStage = 'class_result_identity'
                return $false
            }
            foreach ($propertyName in @('count', 'deterministic_matches', 'shadow_final_matches', 'fallback_matches')) {
                if (-not (Test-Task613ExactInteger -Value (Get-Task613RequiredProperty -Object $matchingRows[0] -Name $propertyName) -Expected $expectedCount)) {
                    $script:Task613ReceiptValidationStage = ('class_result_' + $propertyName)
                    return $false
                }
            }
        }
        if ($countSum -ne 100) {
            $script:Task613ReceiptValidationStage = 'class_count_sum'
            return $false
        }
        if (@((Get-Task613RequiredProperty -Object $Receipt -Name 'failures')).Count -ne 0) {
            $script:Task613ReceiptValidationStage = 'child_failures'
            return $false
        }

        $script:Task613ReceiptValidationStage = 'child_evidence'
        $child = Get-Task613RequiredProperty -Object $Receipt -Name 'child'
        if (-not (Test-Task613ExactInteger -Value (Get-Task613RequiredProperty -Object $child -Name 'pid') -Expected $ChildProcessId)) {
            $script:Task613ReceiptValidationStage = 'child_pid'
            return $false
        }
        if (-not (Test-Task613ExactInteger -Value (Get-Task613RequiredProperty -Object $child -Name 'parent_pid') -Expected $ExpectedParentProcessId)) {
            $script:Task613ReceiptValidationStage = 'child_parent_pid'
            return $false
        }
        if (-not (Test-Task613ExactInteger -Value (Get-Task613RequiredProperty -Object $child -Name 'exit_code') -Expected $ChildExitCode)) {
            $script:Task613ReceiptValidationStage = 'child_exit_code'
            return $false
        }
        $script:Task613ReceiptValidationStage = ''
        return $true
    } catch {
        $script:Task613ReceiptValidationStage = 'validator_exception'
        return $false
    }
}

function Invoke-Task613Parent {
    $failures = [Collections.Generic.List[object]]::new()
    $repositoryRoot = ''
    $sourceHashes = [ordered]@{}
    $executedHead = ''
    $runDirectory = ''
    $child = $null
    $childProcessId = 0
    $childStartedAtUtc = ''
    $childExitCode = -1
    $childExited = $false
    $childReceipt = $null
    $childReceiptValid = $false
    $stdoutPath = ''
    $stderrPath = ''
    $logEvidence = [ordered]@{
        stdout = [ordered]@{ byte_count = 0; sha256 = '' }
        stderr = [ordered]@{ byte_count = 0; sha256 = '' }
    }
    $cleanup = [ordered]@{
        remaining_processes     = 0
        remaining_temp_entries  = 0
    }

    try {
        $repositoryRoot = Get-Task613RepositoryRoot
        $sourceHashes = Get-Task613SourceHashes -RepositoryRoot $repositoryRoot
        Add-Task613AuthoritySourceHashFailures -Failures $failures -SourceHashes $sourceHashes
        $executedHead = Get-Task613GitHead -RepositoryRoot $repositoryRoot

        $runDirectory = Join-Path ([IO.Path]::GetTempPath()) ('winsmux-v03638-router-reliability-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop | Out-Null
        if (-not (Test-Task613RunDirectory -Path $runDirectory)) {
            throw 'task613_created_run_directory_invalid'
        }
        $nonce = [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText((Join-Path $runDirectory 'parent-nonce.txt'), $nonce, [Text.UTF8Encoding]::new($false))
        $childReceiptPath = Join-Path $runDirectory 'child-receipt.json'
        $stdoutPath = Join-Path $runDirectory 'child.stdout.log'
        $stderrPath = Join-Path $runDirectory 'child.stderr.log'

        $pwshPath = (Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source
        $scriptPath = $PSCommandPath
        $childArguments = @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-File', ('"{0}"' -f $scriptPath),
            '-Worker',
            '-Json',
            '-WorkerReceiptPath', ('"{0}"' -f $childReceiptPath),
            '-RunDirectory', ('"{0}"' -f $runDirectory),
            '-ParentProcessId', $PID.ToString(),
            '-ParentNonce', $nonce
        )
        $child = Start-Process -FilePath $pwshPath `
            -ArgumentList $childArguments `
            -WorkingDirectory $repositoryRoot `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -WindowStyle Hidden `
            -PassThru
        $childProcessId = [int]$child.Id
        $childStartedAtUtc = $child.StartTime.ToUniversalTime().ToString('o')
        $child.WaitForExit()
        $childExitCode = [int]$child.ExitCode
        $child.Refresh()
        $childExited = [bool]$child.HasExited
        $logEvidence.stdout = Get-Task613LogEvidence -Path $stdoutPath
        $logEvidence.stderr = Get-Task613LogEvidence -Path $stderrPath

        if ($childExitCode -ne 0) {
            Add-Task613Failure -Failures $failures -Category 'child_exit_nonzero'
        }
        if (-not $childExited) {
            Add-Task613Failure -Failures $failures -Category 'child_not_exited'
        }
        try {
            $childReceipt = Read-Task613JsonFile -Path $childReceiptPath
            $childReceiptValid = Test-Task613ChildReceipt `
                -Receipt $childReceipt `
                -SourceHashes $sourceHashes `
                -ExecutedHead $executedHead `
                -ChildProcessId $childProcessId `
                -ChildStartedAtUtc $childStartedAtUtc `
                -ChildExitCode $childExitCode `
                -ExpectedParentProcessId $PID
            if (-not $childReceiptValid) {
                $validationStage = [string]$script:Task613ReceiptValidationStage
                if ([string]::IsNullOrWhiteSpace($validationStage)) {
                    $validationStage = 'unknown'
                }
                Add-Task613Failure -Failures $failures -Category ('child_receipt_validation_' + $validationStage)
            }
        } catch {
            Add-Task613Failure -Failures $failures -Category 'child_receipt_unavailable'
        }
    } catch {
        Add-Task613Failure -Failures $failures -Category 'parent_execution_failed'
    } finally {
        if ($null -ne $child) {
            try {
                $child.Refresh()
                if (-not $child.HasExited) {
                    $child.Kill()
                    $child.WaitForExit()
                }
            } catch {
                Add-Task613Failure -Failures $failures -Category 'child_cleanup_failed'
            }
        }
        if ($childProcessId -gt 0) {
            $remainingChild = Get-Process -Id $childProcessId -ErrorAction SilentlyContinue
            $cleanup.remaining_processes = if ($null -eq $remainingChild) { 0 } else { 1 }
            if ([int]$cleanup.remaining_processes -ne 0) {
                Add-Task613Failure -Failures $failures -Category 'child_process_remained'
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($runDirectory)) {
            try {
                Remove-Task613RunDirectory -Path $runDirectory
            } catch {
                Add-Task613Failure -Failures $failures -Category 'run_directory_cleanup_failed'
            }
            if (Test-Path -LiteralPath $runDirectory) {
                $cleanup.remaining_temp_entries = 1 + @(
                    Get-ChildItem -LiteralPath $runDirectory -Force -ErrorAction SilentlyContinue
                ).Count
            }
            if ([int]$cleanup.remaining_temp_entries -ne 0) {
                Add-Task613Failure -Failures $failures -Category 'run_directory_remained'
            }
        }
        if ($null -ne $child) {
            $child.Dispose()
        }
    }

    $safeClassResults = @()
    $safeClassCounts = [ordered]@{}
    $definitions = Get-Task613Definitions
    $expectedCounts = Get-Task613ExpectedClassCounts -Definitions $definitions -RunCount 100
    foreach ($definition in $definitions) {
        $classification = [string]$definition.classification
        $count = [int]$expectedCounts[$classification]
        $safeClassCounts[$classification] = $count
        $safeClassResults += [ordered]@{
            classification        = $classification
            count                 = $count
            deterministic_matches = if ($childReceiptValid) { $count } else { 0 }
            shadow_final_matches  = if ($childReceiptValid) { $count } else { 0 }
            fallback_matches      = if ($childReceiptValid) { $count } else { 0 }
        }
    }
    $allPass = ($failures.Count -eq 0) -and $childReceiptValid -and $childExited -and
        ([int]$cleanup.remaining_processes -eq 0) -and ([int]$cleanup.remaining_temp_entries -eq 0)
    $releaseReady = [bool]$allPass
    $receipt = [ordered]@{
        schema                    = $script:Task613ReceiptSchema
        gate_id                   = $script:Task613GateId
        target_version            = $script:Task613TargetVersion
        task_base_sha             = $script:Task613BaseSha
        executed_head_sha         = $executedHead
        source_sha256             = $sourceHashes
        run_count                 = 100
        class_counts              = $safeClassCounts
        class_results             = $safeClassResults
        max_batch_size            = 1
        provider_calls            = if ($childReceiptValid) { 0 } else { -1 }
        prompt_canary_occurrences = if ($childReceiptValid) { 0 } else { -1 }
        failures                  = @($failures.ToArray())
        child                     = [ordered]@{
            pid            = $childProcessId
            parent_pid     = $PID
            started_at_utc = $childStartedAtUtc
            exit_code      = $childExitCode
            exited         = $childExited
        }
        child_output               = $logEvidence
        cleanup                    = $cleanup
        release_ready              = $releaseReady
    }
    return [pscustomobject][ordered]@{
        schema        = $script:Task613ReceiptSchema
        gate_id       = $script:Task613GateId
        all_pass      = $allPass
        release_ready = $releaseReady
        receipt       = $receipt
    }
}

if ($Worker) {
    $workerExecution = Invoke-Task613Worker
    if ($Json) {
        Write-Output ($workerExecution.public_result | ConvertTo-Json -Depth 8 -Compress)
    } else {
        Write-Output ("worker_all_pass={0}; release_ready=false" -f $workerExecution.public_result.all_pass)
    }
    exit ([int]$workerExecution.exit_code)
}

$result = Invoke-Task613Parent
if ($Json) {
    Write-Output ($result | ConvertTo-Json -Depth 24 -Compress)
} else {
    Write-Output ("all_pass={0}; release_ready={1}; failures={2}" -f $result.all_pass, $result.release_ready, @($result.receipt.failures).Count)
}

if (-not $result.all_pass) {
    exit 1
}
