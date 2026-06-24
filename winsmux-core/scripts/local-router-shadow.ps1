$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:DefaultLocalRouterManifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'router/local-small-router-v03621.manifest.json'
$script:LocalRouterPolicyRevision = 'v03621'

if (-not (Get-Command -Name Invoke-WinsmuxDeterministicRoute -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'coordinator-router.ps1')
}

function Get-WinsmuxLocalRouterProperty {
    param(
        [AllowNull()]$Value,
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

function ConvertTo-WinsmuxLocalRouterList {
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

function Get-WinsmuxLocalRouterSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Local router artifact file not found: $Path"
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Resolve-WinsmuxLocalRouterArtifactFile {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestDirectory,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw 'Local router artifact path must not be empty.'
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw 'Local router artifact path must be relative.'
    }
    $pathParts = @($RelativePath -split '[\\/]' | Where-Object { $_ })
    if ($pathParts -contains '..') {
        throw 'Local router artifact path must stay under the router artifact directory.'
    }

    $routerDirectory = [System.IO.Path]::GetFullPath($ManifestDirectory).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $routerDirectory $RelativePath))
    $expectedPrefix = $routerDirectory + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Local router artifact path must stay under the router artifact directory.'
    }

    return $candidate
}

function Resolve-WinsmuxLocalRouterArtifact {
    [CmdletBinding()]
    param([string]$ManifestPath = $script:DefaultLocalRouterManifestPath)

    $resolvedManifestPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ManifestPath)
    if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
        throw "Local router manifest not found: $resolvedManifestPath"
    }

    $manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.artifact_id -ne 'winsmux-local-router-shadow-v03621') {
        throw "Local router manifest artifact mismatch: $($manifest.artifact_id)"
    }
    if ([string]$manifest.policy_revision -ne $script:LocalRouterPolicyRevision) {
        throw "Local router manifest policy revision mismatch: $($manifest.policy_revision)"
    }
    if ([string]$manifest.execution_mode -ne 'shadow_only') {
        throw "Local router manifest execution mode mismatch: $($manifest.execution_mode)"
    }
    if ([bool]$manifest.provider_calls_allowed) {
        throw 'Local router manifest must not allow provider calls.'
    }
    if ([bool]$manifest.auto_update_allowed) {
        throw 'Local router manifest must not allow automatic model updates.'
    }
    if ([bool]$manifest.raw_prompt_storage_allowed) {
        throw 'Local router manifest must not allow raw prompt storage.'
    }

    $manifestDir = Split-Path -Parent $resolvedManifestPath
    $weightsPath = Resolve-WinsmuxLocalRouterArtifactFile -ManifestDirectory $manifestDir -RelativePath ([string]$manifest.weights_path)
    $weightsSha256 = Get-WinsmuxLocalRouterSha256 -Path $weightsPath
    if ($weightsSha256 -ne [string]$manifest.weights_sha256) {
        throw "Local router weights hash mismatch. expected=$($manifest.weights_sha256) actual=$weightsSha256"
    }
    $weights = Get-Content -LiteralPath $weightsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$weights.feature_dimension -ne 12) {
        throw "Local router feature dimension mismatch: $($weights.feature_dimension)"
    }

    [pscustomobject][ordered]@{
        manifest_path   = $resolvedManifestPath
        manifest_sha256 = Get-WinsmuxLocalRouterSha256 -Path $resolvedManifestPath
        weights_path    = $weightsPath
        weights_sha256  = $weightsSha256
        manifest        = $manifest
        weights         = $weights
    }
}

function Test-WinsmuxLocalRouterSlotAvailable {
    param([Parameter(Mandatory = $true)]$Slot)

    $state = ([string](Get-WinsmuxLocalRouterProperty -Value $Slot -Name 'state' -Default 'unknown')).ToLowerInvariant()
    return $state -in @('ready', 'idle', 'available')
}

function Test-WinsmuxLocalRouterSlotRole {
    param(
        [Parameter(Mandatory = $true)]$Slot,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $roles = @(ConvertTo-WinsmuxLocalRouterList (Get-WinsmuxLocalRouterProperty -Value $Slot -Name 'roles' -Default @()))
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

function ConvertTo-WinsmuxLocalRouterFeatureVector {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    $requestedRole = [string](Get-WinsmuxLocalRouterProperty -Value $Context -Name 'requested_role' -Default 'Worker')
    $task = Get-WinsmuxLocalRouterProperty -Value $Context -Name 'task'
    $taskType = ([string](Get-WinsmuxLocalRouterProperty -Value $task -Name 'type' -Default '')).ToLowerInvariant()
    $priority = ([string](Get-WinsmuxLocalRouterProperty -Value $task -Name 'priority' -Default '')).ToUpperInvariant()
    $scope = Get-WinsmuxLocalRouterProperty -Value $Context -Name 'scope'
    $readScope = @(ConvertTo-WinsmuxLocalRouterList (Get-WinsmuxLocalRouterProperty -Value $scope -Name 'read' -Default @()))
    $writeScope = @(ConvertTo-WinsmuxLocalRouterList (Get-WinsmuxLocalRouterProperty -Value $scope -Name 'write' -Default @()))
    $budget = Get-WinsmuxLocalRouterProperty -Value $Context -Name 'budget'
    $remainingTurns = [double](Get-WinsmuxLocalRouterProperty -Value $budget -Name 'remaining_turns' -Default 0)
    $previousRoutes = @(ConvertTo-WinsmuxLocalRouterList (Get-WinsmuxLocalRouterProperty -Value $Context -Name 'previous_routes' -Default @()))
    $slots = @(ConvertTo-WinsmuxLocalRouterList (Get-WinsmuxLocalRouterProperty -Value $Context -Name 'slots' -Default @()))
    $hasPreviousFailure = @($previousRoutes | Where-Object {
        ([string](Get-WinsmuxLocalRouterProperty -Value $_ -Name 'outcome' -Default '')).ToLowerInvariant() -eq 'failed'
    }).Count -gt 0

    @(
        if ($requestedRole -eq 'Worker') { 1.0 } else { 0.0 }
        if ($requestedRole -eq 'Verifier') { 1.0 } else { 0.0 }
        if ($requestedRole -eq 'Thinker') { 1.0 } else { 0.0 }
        if ($taskType -match 'implement|code|fix|build') { 1.0 } else { 0.0 }
        if ($taskType -match 'verify|review|audit|security') { 1.0 } else { 0.0 }
        [Math]::Min(1.0, [double]$writeScope.Count / 5.0)
        [Math]::Min(1.0, [double]$readScope.Count / 5.0)
        [Math]::Min(1.0, [Math]::Max(0.0, $remainingTurns) / 5.0)
        if ($hasPreviousFailure) { 1.0 } else { 0.0 }
        [Math]::Min(1.0, [double]$slots.Count / 6.0)
        if ($priority -eq 'P0') { 1.0 } else { 0.0 }
        1.0
    )
}

function Get-WinsmuxLocalRouterHead {
    param(
        [Parameter(Mandatory = $true)]$Heads,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $exact = Get-WinsmuxLocalRouterProperty -Value $Heads -Name $Name
    if ($null -ne $exact) {
        return $exact
    }
    return Get-WinsmuxLocalRouterProperty -Value $Heads -Name 'default'
}

function Invoke-WinsmuxLocalRouterDotProduct {
    param(
        [Parameter(Mandatory = $true)][double[]]$Features,
        [Parameter(Mandatory = $true)]$Head
    )

    $weights = @($Head.weights | ForEach-Object { [double]$_ })
    if ($weights.Count -ne $Features.Count) {
        throw "Local router head dimension mismatch. expected=$($Features.Count) actual=$($weights.Count)"
    }

    $score = [double](Get-WinsmuxLocalRouterProperty -Value $Head -Name 'bias' -Default 0)
    for ($index = 0; $index -lt $Features.Count; $index++) {
        $score += $Features[$index] * $weights[$index]
    }
    return [Math]::Round($score, 6)
}

function ConvertTo-WinsmuxLocalRouterSoftmax {
    param(
        [Parameter(Mandatory = $true)][double[]]$Values,
        [double]$Temperature = 1.0
    )

    if ($Values.Count -eq 0) {
        return @()
    }
    $safeTemperature = [Math]::Max(0.01, $Temperature)
    $max = ($Values | Measure-Object -Maximum).Maximum
    $exps = @($Values | ForEach-Object { [Math]::Exp(([double]$_ - [double]$max) / $safeTemperature) })
    $sum = [double](($exps | Measure-Object -Sum).Sum)
    if ($sum -le 0) {
        return @($Values | ForEach-Object { 0.0 })
    }
    return @($exps | ForEach-Object { [Math]::Round(([double]$_ / $sum), 6) })
}

function Invoke-WinsmuxLocalRouterShadow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string]$ManifestPath = $script:DefaultLocalRouterManifestPath,
        [double]$MinimumConfidence = -1,
        [double]$MinimumMargin = -1
    )

    $artifact = Resolve-WinsmuxLocalRouterArtifact -ManifestPath $ManifestPath
    $features = [double[]](ConvertTo-WinsmuxLocalRouterFeatureVector -Context $Context)
    $weights = $artifact.weights
    $temperature = [double](Get-WinsmuxLocalRouterProperty -Value $weights -Name 'temperature' -Default 1.0)
    $confidenceThreshold = if ($MinimumConfidence -ge 0) { $MinimumConfidence } else { [double](Get-WinsmuxLocalRouterProperty -Value $weights -Name 'minimum_confidence' -Default 0.45) }
    $marginThreshold = if ($MinimumMargin -ge 0) { $MinimumMargin } else { [double](Get-WinsmuxLocalRouterProperty -Value $weights -Name 'minimum_margin' -Default 0.05) }
    $requestedRole = [string](Get-WinsmuxLocalRouterProperty -Value $Context -Name 'requested_role' -Default 'Worker')

    $slots = @(ConvertTo-WinsmuxLocalRouterList (Get-WinsmuxLocalRouterProperty -Value $Context -Name 'slots' -Default @()) | Sort-Object slot)
    $slotLogitRows = [System.Collections.Generic.List[object]]::new()
    $availabilityRows = [System.Collections.Generic.List[object]]::new()
    foreach ($slot in $slots) {
        $slotId = [string](Get-WinsmuxLocalRouterProperty -Value $slot -Name 'slot' -Default (Get-WinsmuxLocalRouterProperty -Value $slot -Name 'id' -Default ''))
        $head = Get-WinsmuxLocalRouterHead -Heads $weights.slot_heads -Name $slotId
        $rawLogit = Invoke-WinsmuxLocalRouterDotProduct -Features $features -Head $head
        $available = (Test-WinsmuxLocalRouterSlotAvailable -Slot $slot) -and (Test-WinsmuxLocalRouterSlotRole -Slot $slot -Role $requestedRole)
        $maskedLogit = if ($available) { $rawLogit } else { -1000.0 }
        $slotLogitRows.Add([pscustomobject][ordered]@{
            slot         = $slotId
            raw_logit    = $rawLogit
            masked_logit = $maskedLogit
            available    = $available
        }) | Out-Null
        $availabilityRows.Add([pscustomobject][ordered]@{
            slot      = $slotId
            available = $available
            state     = ([string](Get-WinsmuxLocalRouterProperty -Value $slot -Name 'state' -Default 'unknown')).ToLowerInvariant()
        }) | Out-Null
    }

    $probabilityBySlot = @{}
    $availableSlotRows = @($slotLogitRows | Where-Object { $_.available })
    if ($availableSlotRows.Count -gt 0) {
        $availableSlotLogits = [double[]]@($availableSlotRows | ForEach-Object { [double]$_.masked_logit })
        $availableProbabilities = @(ConvertTo-WinsmuxLocalRouterSoftmax -Values $availableSlotLogits -Temperature $temperature)
        for ($index = 0; $index -lt $availableSlotRows.Count; $index++) {
            $probabilityBySlot[[string]$availableSlotRows[$index].slot] = [double]$availableProbabilities[$index]
        }
    }
    for ($index = 0; $index -lt $slotLogitRows.Count; $index++) {
        $slotId = [string]$slotLogitRows[$index].slot
        $probability = if ($probabilityBySlot.ContainsKey($slotId)) { [double]$probabilityBySlot[$slotId] } else { 0.0 }
        $slotLogitRows[$index] | Add-Member -NotePropertyName probability -NotePropertyValue $probability -Force
    }

    $roleRows = [System.Collections.Generic.List[object]]::new()
    $roleLogits = [System.Collections.Generic.List[double]]::new()
    foreach ($role in @('Thinker', 'Worker', 'Verifier')) {
        $head = Get-WinsmuxLocalRouterHead -Heads $weights.role_heads -Name $role
        $logit = Invoke-WinsmuxLocalRouterDotProduct -Features $features -Head $head
        $roleRows.Add([pscustomobject][ordered]@{ role = $role; logit = $logit }) | Out-Null
        $roleLogits.Add([double]$logit) | Out-Null
    }
    $roleProbabilities = @(ConvertTo-WinsmuxLocalRouterSoftmax -Values ([double[]]$roleLogits.ToArray()) -Temperature $temperature)
    for ($index = 0; $index -lt $roleRows.Count; $index++) {
        $roleRows[$index] | Add-Member -NotePropertyName probability -NotePropertyValue ([double]$roleProbabilities[$index]) -Force
    }

    $sortedSlots = @($slotLogitRows | Where-Object { $_.available } | Sort-Object @{ Expression = 'probability'; Descending = $true }, slot)
    $topSlot = @($sortedSlots | Select-Object -First 1)
    $secondSlot = @($sortedSlots | Select-Object -Skip 1 -First 1)
    $proposalSlot = if ($topSlot.Count -gt 0) { [string]$topSlot[0].slot } else { $null }
    $confidence = if ($topSlot.Count -gt 0) { [double]$topSlot[0].probability } else { 0.0 }
    $margin = if ($topSlot.Count -gt 0 -and $secondSlot.Count -gt 0) {
        [Math]::Round([double]$topSlot[0].masked_logit - [double]$secondSlot[0].masked_logit, 6)
    } elseif ($topSlot.Count -gt 0) {
        [Math]::Round([double]$topSlot[0].masked_logit, 6)
    } else {
        0.0
    }
    $fallbackRequired = ($null -eq $proposalSlot) -or ($confidence -lt $confidenceThreshold) -or ($margin -lt $marginThreshold)
    $fallbackDecision = Invoke-WinsmuxDeterministicRoute -Context $Context

    [pscustomobject][ordered]@{
        schema_version      = 1
        kind                = 'winsmux.local_router_shadow_decision'
        policy_revision     = $script:LocalRouterPolicyRevision
        mode                = 'shadow'
        shadow_only         = $true
        execution_authority = 'deterministic_fallback'
        provider_calls      = 0
        artifact            = [ordered]@{
            artifact_id     = [string]$artifact.manifest.artifact_id
            manifest_sha256 = [string]$artifact.manifest_sha256
            weights_sha256  = [string]$artifact.weights_sha256
            license         = [string]$artifact.manifest.license
            provenance      = [string]$artifact.manifest.provenance
            auto_update     = [bool]$artifact.manifest.auto_update_allowed
        }
        features            = [ordered]@{
            method            = 'privacy_safe_route_state_projection'
            dimension         = $features.Count
            raw_prompt_stored = $false
            values            = @($features | ForEach-Object { [Math]::Round([double]$_, 6) })
        }
        logits              = [ordered]@{
            slot_logits = @($slotLogitRows)
            role_logits = @($roleRows)
        }
        availability_mask   = @($availabilityRows)
        proposal            = [ordered]@{
            slot       = $proposalSlot
            role       = $requestedRole
            confidence = [Math]::Round($confidence, 6)
            margin     = $margin
            action     = 'shadow_proposal_only'
        }
        fallback_required   = [bool]$fallbackRequired
        fallback_decision   = $fallbackDecision
        final_authority     = $fallbackDecision.decision
        rationale           = 'Local route-head artifact produced a shadow proposal only; deterministic routing remains the execution authority.'
    }
}

function Measure-WinsmuxLocalRouterShadowProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Cases,
        [string]$ManifestPath = $script:DefaultLocalRouterManifestPath
    )

    $caseRows = [System.Collections.Generic.List[object]]::new()
    $maxElapsedMs = 0.0
    foreach ($case in $Cases) {
        $caseId = [string](Get-WinsmuxLocalRouterProperty -Value $case -Name 'id' -Default 'case')
        $context = Get-WinsmuxLocalRouterProperty -Value $case -Name 'context'
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $decision = Invoke-WinsmuxLocalRouterShadow -Context $context -ManifestPath $ManifestPath
        $timer.Stop()
        $elapsedMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 3)
        $maxElapsedMs = [Math]::Max($maxElapsedMs, $elapsedMs)
        $caseRows.Add([pscustomobject][ordered]@{
            id                = $caseId
            elapsed_ms        = $elapsedMs
            proposal_slot     = $decision.proposal.slot
            final_slot        = $decision.final_authority.slot
            fallback_required = $decision.fallback_required
        }) | Out-Null
    }

    [pscustomobject][ordered]@{
        schema_version             = 1
        kind                       = 'winsmux.local_router_shadow_profile'
        policy_revision            = $script:LocalRouterPolicyRevision
        case_count                 = $Cases.Count
        max_elapsed_ms             = [Math]::Round($maxElapsedMs, 3)
        provider_calls             = 0
        gpu_required               = $false
        raw_prompt_stored          = $false
        max_workspace_write_bytes  = 0
        retains_provider_metadata  = $false
        stores_local_private_paths = $false
        cases                      = @($caseRows)
    }
}

function Write-WinsmuxLocalRouterShadowTrace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ShadowDecision,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([string](Get-WinsmuxLocalRouterProperty -Value $ShadowDecision -Name 'kind' -Default '') -ne 'winsmux.local_router_shadow_decision') {
        throw 'Local router trace writer only accepts local router shadow decision objects.'
    }
    $serialized = $ShadowDecision | ConvertTo-Json -Depth 20 -Compress
    $sensitiveMetadataPattern = ('OPENROUTER' + '_API_KEY|ANTHROPIC' + '_API_KEY|provider' + '_request_id|bearer\s+[A-Za-z0-9._-]+')
    if ($serialized -match '"raw_prompt"\s*:' -or
        $serialized -match $sensitiveMetadataPattern) {
        throw 'Local router trace writer rejected sensitive shadow decision content.'
    }

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $serialized | Add-Content -LiteralPath $Path -Encoding UTF8
}
