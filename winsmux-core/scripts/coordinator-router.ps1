$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-WinsmuxRouteProperty {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Value) {
        return $Default
    }
    if ($Value -is [System.Collections.IDictionary] -and $Value.Contains($Name)) {
        return $Value[$Name]
    }
    if ($null -ne $Value.PSObject -and $Value.PSObject.Properties.Name -contains $Name) {
        return $Value.$Name
    }
    return $Default
}

function ConvertTo-WinsmuxRouteList {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return @()
        }
        return @($Value)
    }
    return @($Value)
}

function ConvertTo-WinsmuxRouteScope {
    param([string[]]$Scope)

    $redacted = [System.Collections.Generic.List[string]]::new()
    foreach ($item in (ConvertTo-WinsmuxRouteList $Scope)) {
        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $normalized = $text.Replace('\', '/')
        if ($normalized -match '^[A-Za-z]:/' -or $normalized -match '^//') {
            $fileName = Split-Path -Path $normalized -Leaf
            if ([string]::IsNullOrWhiteSpace($fileName)) {
                $fileName = '<path>'
            }
            $redacted.Add("local-path-redacted/$fileName") | Out-Null
            continue
        }

        $redacted.Add($normalized) | Out-Null
    }
    return @($redacted)
}

function ConvertTo-WinsmuxRouteSlot {
    param($Slot)

    $slotId = [string](Get-WinsmuxRouteProperty -Value $Slot -Name 'slot' -Default (Get-WinsmuxRouteProperty -Value $Slot -Name 'id' -Default ''))
    if ([string]::IsNullOrWhiteSpace($slotId)) {
        throw 'Route slot requires slot or id.'
    }

    [pscustomobject][ordered]@{
        slot               = $slotId
        provider           = [string](Get-WinsmuxRouteProperty -Value $Slot -Name 'provider' -Default '')
        backend            = [string](Get-WinsmuxRouteProperty -Value $Slot -Name 'backend' -Default '')
        roles              = @(ConvertTo-WinsmuxRouteList (Get-WinsmuxRouteProperty -Value $Slot -Name 'roles' -Default @()))
        state              = ([string](Get-WinsmuxRouteProperty -Value $Slot -Name 'state' -Default 'unknown')).ToLowerInvariant()
        capabilities       = @(ConvertTo-WinsmuxRouteList (Get-WinsmuxRouteProperty -Value $Slot -Name 'capabilities' -Default @()))
        active_write_scope = @(ConvertTo-WinsmuxRouteScope (ConvertTo-WinsmuxRouteList (Get-WinsmuxRouteProperty -Value $Slot -Name 'active_write_scope' -Default @())))
        cost_tier          = [string](Get-WinsmuxRouteProperty -Value $Slot -Name 'cost_tier' -Default 'standard')
        latency_tier       = [string](Get-WinsmuxRouteProperty -Value $Slot -Name 'latency_tier' -Default 'standard')
        heartbeat          = [string](Get-WinsmuxRouteProperty -Value $Slot -Name 'heartbeat' -Default 'unknown')
    }
}

function ConvertTo-WinsmuxRoutePreviousRoute {
    param($Route)

    [pscustomobject][ordered]@{
        slot          = [string](Get-WinsmuxRouteProperty -Value $Route -Name 'slot' -Default '')
        role          = [string](Get-WinsmuxRouteProperty -Value $Route -Name 'role' -Default '')
        outcome       = ([string](Get-WinsmuxRouteProperty -Value $Route -Name 'outcome' -Default '')).ToLowerInvariant()
        failure_class = ([string](Get-WinsmuxRouteProperty -Value $Route -Name 'failure_class' -Default '')).ToLowerInvariant()
    }
}

function New-WinsmuxRouteContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$TaskType,
        [Parameter(Mandatory = $true)][string]$Goal,
        [Parameter(Mandatory = $true)][string]$Priority,
        [ValidateSet('Thinker', 'Worker', 'Verifier')]
        [string]$RequestedRole = 'Worker',
        [string[]]$ReadScope = @(),
        [string[]]$WriteScope = @(),
        [object[]]$Slots = @(),
        [object[]]$PreviousRoutes = @(),
        [int]$RemainingTurns = 5,
        [string]$RawPrompt = ''
    )

    $redactedFields = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RawPrompt)) {
        $redactedFields.Add('raw_prompt') | Out-Null
    }

    $safeReadScope = @(ConvertTo-WinsmuxRouteScope $ReadScope)
    $safeWriteScope = @(ConvertTo-WinsmuxRouteScope $WriteScope)
    if (($ReadScope + $WriteScope) -match '^[A-Za-z]:\\') {
        $redactedFields.Add('absolute_paths') | Out-Null
    }

    [pscustomobject][ordered]@{
        schema_version     = 1
        kind               = 'winsmux.route_context'
        policy_revision    = 'v03620'
        created_at_utc     = (Get-Date).ToUniversalTime().ToString('o')
        task               = [ordered]@{
            task_id = $TaskId
            type    = $TaskType
            goal    = $Goal
            priority = $Priority
        }
        scope              = [ordered]@{
            read  = @($safeReadScope)
            write = @($safeWriteScope)
        }
        requested_role     = $RequestedRole
        dependency_state   = 'unknown'
        review_state       = 'not_started'
        slots              = @($Slots | ForEach-Object { ConvertTo-WinsmuxRouteSlot $_ })
        previous_routes    = @($PreviousRoutes | ForEach-Object { ConvertTo-WinsmuxRoutePreviousRoute $_ })
        budget             = [ordered]@{
            remaining_turns = $RemainingTurns
            max_turns       = 5
            cost_policy     = 'bounded'
            latency_policy  = 'bounded'
        }
        redaction          = [ordered]@{
            raw_prompt_stored = $false
            redacted_fields   = @($redactedFields | Select-Object -Unique)
        }
        constraints        = [ordered]@{
            no_learning_router             = $true
            no_default_behavior_replacement = $true
            router_cannot_merge_or_release = $true
            provider_calls_allowed         = $false
        }
    }
}

function Test-WinsmuxSlotHasRole {
    param(
        [Parameter(Mandatory = $true)]$Slot,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $roles = @(ConvertTo-WinsmuxRouteList $Slot.roles)
    if ($roles.Count -eq 0) {
        return $true
    }
    foreach ($slotRole in $roles) {
        if ([string]::Equals([string]$slotRole, $Role, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-WinsmuxSlotHasCapability {
    param(
        [Parameter(Mandatory = $true)]$Slot,
        [Parameter(Mandatory = $true)][string[]]$Capabilities
    )

    $slotCapabilities = @(ConvertTo-WinsmuxRouteList $Slot.capabilities)
    foreach ($candidate in $Capabilities) {
        foreach ($capability in $slotCapabilities) {
            if ([string]::Equals([string]$capability, $candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Test-WinsmuxWriteScopeConflict {
    param(
        [Parameter(Mandatory = $true)]$Slot,
        [string[]]$RequestedWriteScope = @()
    )

    $slotWriteScope = @(ConvertTo-WinsmuxRouteScope (ConvertTo-WinsmuxRouteList $Slot.active_write_scope))
    if ($slotWriteScope.Count -eq 0 -or $RequestedWriteScope.Count -eq 0) {
        return $false
    }

    foreach ($requested in $RequestedWriteScope) {
        foreach ($active in $slotWriteScope) {
            if ([string]::Equals($requested, $active, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Test-WinsmuxPreviousRouteFailed {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Slot,
        [Parameter(Mandatory = $true)][string]$Role
    )

    foreach ($route in @(ConvertTo-WinsmuxRouteList $Context.previous_routes)) {
        if (-not [string]::Equals([string]$route.slot, $Slot, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if (-not [string]::Equals([string]$route.role, $Role, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($route.outcome -ne 'failed') {
            continue
        }
        if ($route.failure_class -eq 'infrastructure') {
            continue
        }
        return $true
    }
    return $false
}

function Get-WinsmuxRouteCapabilityNeed {
    param(
        [Parameter(Mandatory = $true)][string]$TaskType,
        [Parameter(Mandatory = $true)][string]$RequestedRole
    )

    if ([string]::Equals($RequestedRole, 'Verifier', [System.StringComparison]::OrdinalIgnoreCase)) {
        return @('review', 'verification')
    }
    switch -Regex ($TaskType) {
        'verify|review|audit|security' { return @('review', 'verification') }
        'plan|design|decompose|research' { return @('planning', 'analysis', 'research') }
        default { return @('implementation', 'coding', 'worker') }
    }
}

function Invoke-WinsmuxDeterministicRoute {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    $requestedRole = [string]$Context.requested_role
    $capabilityNeed = @(Get-WinsmuxRouteCapabilityNeed -TaskType ([string]$Context.task.type) -RequestedRole $requestedRole)
    $requestedWriteScope = @(ConvertTo-WinsmuxRouteScope (ConvertTo-WinsmuxRouteList $Context.scope.write))
    $excluded = [System.Collections.Generic.List[object]]::new()
    $considered = [System.Collections.Generic.List[object]]::new()

    foreach ($slot in @($Context.slots | Sort-Object slot)) {
        $slotId = [string]$slot.slot
        $state = ([string]$slot.state).ToLowerInvariant()
        $reasons = [System.Collections.Generic.List[string]]::new()

        if ($state -notin @('ready', 'idle', 'available')) {
            $reasons.Add('slot_unavailable') | Out-Null
        }
        if (-not (Test-WinsmuxSlotHasRole -Slot $slot -Role $requestedRole)) {
            $reasons.Add('role_mismatch') | Out-Null
        }
        if ((Test-WinsmuxWriteScopeConflict -Slot $slot -RequestedWriteScope $requestedWriteScope)) {
            $reasons.Add('write_scope_conflict') | Out-Null
        }
        if ((Test-WinsmuxPreviousRouteFailed -Context $Context -Slot $slotId -Role $requestedRole)) {
            $reasons.Add('failed_route_retry_blocked') | Out-Null
        }
        if ([string]::Equals($requestedRole, 'Verifier', [System.StringComparison]::OrdinalIgnoreCase) -and
            -not (Test-WinsmuxSlotHasCapability -Slot $slot -Capabilities @('review', 'verification'))) {
            $reasons.Add('verifier_capability_missing') | Out-Null
        }

        if ($reasons.Count -gt 0) {
            foreach ($reason in $reasons) {
                $excluded.Add([pscustomobject][ordered]@{ slot = $slotId; reason = $reason }) | Out-Null
            }
            continue
        }

        $score = 10
        if ((Test-WinsmuxSlotHasRole -Slot $slot -Role $requestedRole)) {
            $score += 40
        }
        if ((Test-WinsmuxSlotHasCapability -Slot $slot -Capabilities $capabilityNeed)) {
            $score += 30
        }
        if ([string]::Equals($requestedRole, 'Verifier', [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-WinsmuxSlotHasCapability -Slot $slot -Capabilities @('review', 'verification'))) {
            $score += 20
        }
        if ($slot.provider -eq 'codex' -and $requestedRole -eq 'Worker') {
            $score += 5
        }
        if ($slot.provider -eq 'claude' -and $requestedRole -eq 'Verifier') {
            $score += 5
        }

        $considered.Add([pscustomobject][ordered]@{
            slot     = $slotId
            provider = [string]$slot.provider
            role     = $requestedRole
            score    = $score
        }) | Out-Null
    }

    $selected = @($considered | Sort-Object @{ Expression = 'score'; Descending = $true }, slot | Select-Object -First 1)
    if ($selected.Count -eq 0) {
        return [pscustomobject][ordered]@{
            schema_version = 1
            kind           = 'winsmux.route_decision'
            decision       = [pscustomobject][ordered]@{
                slot       = $null
                role       = 'Operator'
                confidence = 0.0
                action     = 'handle_locally'
            }
            considered     = @()
            excluded       = @($excluded)
            rationale      = 'No eligible slot remained after deterministic masks.'
        }
    }

    $confidence = [Math]::Min(0.99, [Math]::Round(([double]$selected[0].score / 100.0), 2))
    return [pscustomobject][ordered]@{
        schema_version = 1
        kind           = 'winsmux.route_decision'
        decision       = [pscustomobject][ordered]@{
            slot       = [string]$selected[0].slot
            role       = [string]$selected[0].role
            confidence = $confidence
            action     = 'shadow_route'
        }
        considered     = @($considered)
        excluded       = @($excluded)
        rationale      = 'Deterministic capability router selected the highest scored eligible slot.'
    }
}

function Get-WinsmuxCoordinatorRoleContract {
    param([ValidateSet('Thinker', 'Worker', 'Verifier')][string]$Role)

    $contracts = [ordered]@{
        Thinker  = [ordered]@{
            allowed_actions = @('read', 'decompose', 'hypothesize', 'plan')
            write_policy    = 'read_only'
            evidence        = @('assumptions', 'risks', 'handoff_packet')
        }
        Worker   = [ordered]@{
            allowed_actions = @('implement', 'experiment', 'produce_patch', 'record_evidence')
            write_policy    = 'bounded_to_route_scope'
            evidence        = @('changed_files', 'test_output', 'trace_id')
        }
        Verifier = [ordered]@{
            allowed_actions = @('inspect', 'run_tests', 'compare_evidence', 'accept_or_reject')
            write_policy    = 'no_product_writes'
            evidence        = @('findings', 'commands', 'acceptance')
        }
    }

    if ([string]::IsNullOrWhiteSpace($Role)) {
        return $contracts
    }
    return $contracts[$Role]
}

function Write-WinsmuxRouteTrace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Decision,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $record = [ordered]@{
        schema_version = 1
        kind           = 'winsmux.route_trace'
        recorded_at_utc = (Get-Date).ToUniversalTime().ToString('o')
        route_context  = $Context
        route_decision = $Decision
    }
    ($record | ConvertTo-Json -Depth 18 -Compress) | Add-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-WinsmuxOfflineRouteEvaluator {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Cases)

    $deterministicSuccess = 0
    $roundRobinSuccess = 0
    $strongestSuccess = 0
    $staticSuccess = 0
    $randomSuccess = 0
    $random = [System.Random]::new(3620)
    $caseResults = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($case in $Cases) {
        $context = Get-WinsmuxRouteProperty -Value $case -Name 'context'
        $expectedSlot = [string](Get-WinsmuxRouteProperty -Value $case -Name 'expected_slot' -Default '')
        $caseId = [string](Get-WinsmuxRouteProperty -Value $case -Name 'id' -Default ('case-' + $index))
        $readySlots = @($context.slots | Where-Object { $_.state -in @('ready', 'idle', 'available') } | Sort-Object slot)

        $decision = Invoke-WinsmuxDeterministicRoute -Context $context
        if ([string]$decision.decision.slot -eq $expectedSlot) { $deterministicSuccess++ }

        $strongest = @($readySlots | Sort-Object @{ Expression = { if (Test-WinsmuxSlotHasCapability -Slot $_ -Capabilities @('review', 'verification', 'implementation')) { 0 } else { 1 } } }, slot | Select-Object -First 1)
        if ($strongest.Count -gt 0 -and [string]$strongest[0].slot -eq $expectedSlot) { $strongestSuccess++ }

        if ($readySlots.Count -gt 0) {
            $roundRobin = $readySlots[$index % $readySlots.Count]
            if ([string]$roundRobin.slot -eq $expectedSlot) { $roundRobinSuccess++ }

            $randomSlot = $readySlots[$random.Next(0, $readySlots.Count)]
            if ([string]$randomSlot.slot -eq $expectedSlot) { $randomSuccess++ }
        }

        $staticTarget = if ([string]$context.requested_role -eq 'Verifier') {
            @($readySlots | Where-Object { Test-WinsmuxSlotHasCapability -Slot $_ -Capabilities @('review', 'verification') } | Select-Object -First 1)
        } else {
            @($readySlots | Where-Object { Test-WinsmuxSlotHasCapability -Slot $_ -Capabilities @('implementation', 'coding', 'worker') } | Select-Object -First 1)
        }
        if ($staticTarget.Count -gt 0 -and [string]$staticTarget[0].slot -eq $expectedSlot) { $staticSuccess++ }

        $caseResults.Add([pscustomobject][ordered]@{
            id                = $caseId
            expected_slot     = $expectedSlot
            deterministic_slot = [string]$decision.decision.slot
        }) | Out-Null
        $index++
    }

    $denominator = [Math]::Max(1, $Cases.Count)
    [pscustomobject][ordered]@{
        schema_version = 1
        kind           = 'winsmux.offline_route_evaluation'
        provider_calls = 0
        baselines      = [ordered]@{
            deterministic_capability_router = [ordered]@{ success = $deterministicSuccess; total = $Cases.Count }
            strongest_single_slot           = [ordered]@{ success = $strongestSuccess; total = $Cases.Count }
            round_robin                     = [ordered]@{ success = $roundRobinSuccess; total = $Cases.Count }
            random_seeded                   = [ordered]@{ success = $randomSuccess; total = $Cases.Count }
            static_task_type_rule           = [ordered]@{ success = $staticSuccess; total = $Cases.Count }
        }
        metrics        = [ordered]@{
            success_rate       = [Math]::Round($deterministicSuccess / $denominator, 4)
            coordination_turns = $Cases.Count
            conflict_rate      = 0
            fallback_rate      = 0
        }
        cases          = @($caseResults)
    }
}
