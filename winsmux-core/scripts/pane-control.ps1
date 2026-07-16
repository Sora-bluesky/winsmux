. (Join-Path $PSScriptRoot 'json-compat.ps1')
. (Join-Path $PSScriptRoot 'settings.ps1')
. (Join-Path $PSScriptRoot 'manifest.ps1')

function Invoke-PaneControlWinsmux {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = Invoke-WinsmuxBridgeCommand -WinsmuxBin 'winsmux' -Arguments $Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = 'unknown winsmux error'
        }

        throw "winsmux $($Arguments -join ' ') failed: $message"
    }

    return $output
}

function ConvertFrom-PaneControlYamlScalar {
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

function ConvertTo-PaneControlYamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [bool]) {
        if ($Value) {
            return 'true'
        }

        return 'false'
    }

    $text = [string]$Value
    if ($text.Length -eq 0) {
        return "''"
    }

    return "'" + $text.Replace("'", "''") + "'"
}

function Get-PaneControlValue {
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

function ConvertFrom-PaneControlChangedFiles {
    param([AllowNull()]$Value)

    $normalize = {
        param($Items)

        return @(
            @($Items) |
                Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { [string]$_ }
        )
    }

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return & $normalize $Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    try {
        $parsed = $text | ConvertFrom-Json -ErrorAction Stop
        if ($parsed -is [System.Array]) {
            return & $normalize $parsed
        }

        return & $normalize @($parsed)
    } catch {
        return & $normalize @($text)
    }
}

function ConvertFrom-PaneControlStringArray {
    param([AllowNull()]$Value)

    $normalize = {
        param($Items)

        return @(
            @($Items) |
                Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { [string]$_ }
        )
    }

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return & $normalize $Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    try {
        $parsed = $text | ConvertFrom-Json -ErrorAction Stop
        if ($parsed -is [System.Array]) {
            return & $normalize $parsed
        }

        return & $normalize @($parsed)
    } catch {
        return & $normalize @($text)
    }
}

function ConvertFrom-PaneControlBoolean {
    param([AllowNull()]$Value, [bool]$Default = $false)

    if ($null -eq $Value) {
        return $Default
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Default
    }

    switch ($text.Trim().ToLowerInvariant()) {
        'true' { return $true }
        '1' { return $true }
        'yes' { return $true }
        'y' { return $true }
        'false' { return $false }
        '0' { return $false }
        'no' { return $false }
        'n' { return $false }
        default { return $Default }
    }
}

function Get-PaneControlCanonicalRole {
    param([AllowNull()][string]$Role, [AllowNull()][string]$Label)

    $candidate = if ([string]::IsNullOrWhiteSpace($Role)) { $Label } else { $Role }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return 'Operator'
    }

    switch -Regex ($candidate.Trim()) {
        '^(?i)worker(?:$|[-_:/\s])' { return 'Worker' }
        '^(?i)builder(?:$|[-_:/\s])' { return 'Builder' }
        '^(?i)researcher(?:$|[-_:/\s])' { return 'Researcher' }
        '^(?i)reviewer(?:$|[-_:/\s])' { return 'Reviewer' }
        '^(?i)operator(?:$|[-_:/\s])' { return 'Operator' }
        default { return 'Operator' }
    }
}

function Get-PaneControlGitWorktreeDir {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $dotGitPath = Join-Path $ProjectDir '.git'

    if (Test-Path $dotGitPath -PathType Leaf) {
        $raw = (Get-Content -Path $dotGitPath -Raw -Encoding UTF8).Trim()
        if ($raw -match '^gitdir:\s*(.+)$') {
            return [System.IO.Path]::GetFullPath($Matches[1].Trim())
        }
    }

    if (Test-Path $dotGitPath -PathType Container) {
        return (Get-Item -LiteralPath $dotGitPath -Force).FullName
    }

    return $ProjectDir
}

function Get-PaneControlLaunchCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Model,
        [AllowEmptyString()][string]$ModelSource = '',
        [AllowEmptyString()][string]$ReasoningEffort = '',
        [AllowEmptyString()][string]$McpMode = '',
        [AllowEmptyString()][string]$SlotId = '',
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [string]$RootPath = ''
    )

    return Get-BridgeProviderLaunchCommand `
        -ProviderId $Agent `
        -Model $Model `
        -ModelSource $ModelSource `
        -ReasoningEffort $ReasoningEffort `
        -McpMode $McpMode `
        -SlotId $SlotId `
        -ProjectDir $ProjectDir `
        -GitWorktreeDir $GitWorktreeDir `
        -RootPath $RootPath
}

function ConvertFrom-PaneControlManifestContent {
    param([Parameter(Mandatory = $true)][string]$Content)

    $parsed = ConvertFrom-ManifestYaml -Content $Content
    return [ordered]@{
        version = $parsed.version
        saved_at = $parsed.saved_at
        Session = $parsed.session
        Panes   = $parsed.panes
        Tasks   = $parsed.tasks
        Worktrees = $parsed.worktrees
    }
}

function ConvertFrom-PaneControlSecurityPolicy {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return $Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $parseCandidates = @($text)
    if ($text.Contains('\"')) {
        $parseCandidates += ($text -replace '\\"', '"')
    }

    foreach ($candidate in $parseCandidates | Select-Object -Unique) {
        try {
            return ($candidate | ConvertFrom-WinsmuxJson -AsHashtable -Depth 8)
        } catch {
        }
    }

    return [ordered]@{ raw = $text }
}

function Get-PaneControlManifestEntries {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
    if (-not (Test-Path $manifestPath -PathType Leaf)) {
        throw "Manifest not found: $manifestPath"
    }

    $content = Get-Content -Path $manifestPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Manifest is empty: $manifestPath"
    }

    $manifest = ConvertFrom-PaneControlManifestContent -Content $content
    $manifestVersion = ConvertTo-WinsmuxRuntimeInteger -Value (Get-PaneControlValue -InputObject $manifest -Name 'Version' -Default $null)
    $manifestGenerationId = [string](Get-PaneControlValue -InputObject $manifest.Session -Name 'generation_id' -Default '')
    $projectRoot = [string](Get-PaneControlValue -InputObject $manifest.Session -Name 'project_dir' -Default '')
    if ([string]::IsNullOrWhiteSpace($projectRoot)) {
        $projectRoot = $ProjectDir
    }

    $sessionGitWorktreeDir = [string](Get-PaneControlValue -InputObject $manifest.Session -Name 'git_worktree_dir' -Default '')
    $entries = @()

    foreach ($label in $manifest.Panes.Keys) {
        $pane = $manifest.Panes[$label]
        $role = Get-PaneControlCanonicalRole -Role ([string](Get-PaneControlValue -InputObject $pane -Name 'role' -Default '')) -Label $label
        $usesWorkerWorktree = $role -in @('Builder', 'Worker')
        $launchDir = [string](Get-PaneControlValue -InputObject $pane -Name 'launch_dir' -Default '')
        $builderWorktreePath = [string](Get-PaneControlValue -InputObject $pane -Name 'builder_worktree_path' -Default '')
        if (-not $usesWorkerWorktree) {
            $builderWorktreePath = ''
        }
        $builderBranch = [string](Get-PaneControlValue -InputObject $pane -Name 'builder_branch' -Default '')
        if (-not $usesWorkerWorktree) {
            $builderBranch = ''
        }

        if ($usesWorkerWorktree -and [string]::IsNullOrWhiteSpace($launchDir) -and -not [string]::IsNullOrWhiteSpace($builderWorktreePath)) {
            $launchDir = $builderWorktreePath
        }

        if ([string]::IsNullOrWhiteSpace($launchDir)) {
            $launchDir = $projectRoot
        }

        $paneGitWorktreeDir = ''
        if ($usesWorkerWorktree) {
            $paneGitWorktreeDir = [string](Get-PaneControlValue -InputObject $pane -Name 'worktree_git_dir' -Default '')
        }
        $gitWorktreeDir = $paneGitWorktreeDir
        if ([string]::IsNullOrWhiteSpace($gitWorktreeDir)) {
            $gitWorktreeDir = $sessionGitWorktreeDir
            if ($usesWorkerWorktree -or [string]::IsNullOrWhiteSpace($gitWorktreeDir)) {
                $gitWorktreeDir = Get-PaneControlGitWorktreeDir -ProjectDir $launchDir
            }
        }

        $entries += [PSCustomObject][ordered]@{
            ManifestPath        = $manifestPath
            ManifestVersion     = $manifestVersion
            GenerationId        = $manifestGenerationId
            ProjectDir          = $projectRoot
            Label               = $label
            SlotId              = [string](Get-PaneControlValue -InputObject $pane -Name 'slot_id' -Default $label)
            PaneId              = [string](Get-PaneControlValue -InputObject $pane -Name 'pane_id' -Default '')
            WorkerBackend       = [string](Get-PaneControlValue -InputObject $pane -Name 'worker_backend' -Default 'local')
            WorkerRole          = [string](Get-PaneControlValue -InputObject $pane -Name 'worker_role' -Default '')
            Role                = $role
            Title               = [string](Get-PaneControlValue -InputObject $pane -Name 'title' -Default '')
            RuntimeReady        = ConvertFrom-PaneControlBoolean -Value (Get-PaneControlValue -InputObject $pane -Name 'runtime_ready' -Default $false) -Default $false
            LaunchDir           = $launchDir
            BuilderBranch       = $builderBranch
            BuilderWorktreePath = $builderWorktreePath
            GitWorktreeDir      = $gitWorktreeDir
            TaskId              = [string](Get-PaneControlValue -InputObject $pane -Name 'task_id' -Default '')
            Task                = [string](Get-PaneControlValue -InputObject $pane -Name 'task' -Default '')
            TaskState           = [string](Get-PaneControlValue -InputObject $pane -Name 'task_state' -Default '')
            TaskOwner           = [string](Get-PaneControlValue -InputObject $pane -Name 'task_owner' -Default '')
            ReviewState         = [string](Get-PaneControlValue -InputObject $pane -Name 'review_state' -Default '')
            Branch              = [string](Get-PaneControlValue -InputObject $pane -Name 'branch' -Default '')
            HeadSha             = [string](Get-PaneControlValue -InputObject $pane -Name 'head_sha' -Default '')
            ChangedFileCount    = [int](Get-PaneControlValue -InputObject $pane -Name 'changed_file_count' -Default 0)
            ChangedFiles        = @(ConvertFrom-PaneControlChangedFiles -Value (Get-PaneControlValue -InputObject $pane -Name 'changed_files' -Default @()))
            LastCommand         = [string](Get-PaneControlValue -InputObject $pane -Name 'last_command' -Default '')
            LastCommandAt       = [string](Get-PaneControlValue -InputObject $pane -Name 'last_command_at' -Default '')
            LastEvent           = [string](Get-PaneControlValue -InputObject $pane -Name 'last_event' -Default '')
            LastEventAt         = [string](Get-PaneControlValue -InputObject $pane -Name 'last_event_at' -Default '')
            LastFailureStage    = [string](Get-PaneControlValue -InputObject $pane -Name 'last_failure_stage' -Default '')
            LastFailureReason   = [string](Get-PaneControlValue -InputObject $pane -Name 'last_failure_reason' -Default '')
            RecoveryAction      = [string](Get-PaneControlValue -InputObject $pane -Name 'recovery_action' -Default '')
            LastHeartbeatRunId  = [string](Get-PaneControlValue -InputObject $pane -Name 'last_heartbeat_run_id' -Default '')
            LastHeartbeatProfile = [string](Get-PaneControlValue -InputObject $pane -Name 'last_heartbeat_profile' -Default '')
            LastHeartbeatAt     = [string](Get-PaneControlValue -InputObject $pane -Name 'last_heartbeat_at' -Default '')
            LastWorkspaceRunId  = [string](Get-PaneControlValue -InputObject $pane -Name 'last_workspace_run_id' -Default '')
            LastWorkspaceProfile = [string](Get-PaneControlValue -InputObject $pane -Name 'last_workspace_profile' -Default '')
            LastWorkspaceStatus = [string](Get-PaneControlValue -InputObject $pane -Name 'last_workspace_status' -Default '')
            LastWorkspaceLifecycle = [string](Get-PaneControlValue -InputObject $pane -Name 'last_workspace_lifecycle' -Default '')
            LastWorkspaceRoot   = [string](Get-PaneControlValue -InputObject $pane -Name 'last_workspace_root' -Default '')
            LastWorkspaceManifest = [string](Get-PaneControlValue -InputObject $pane -Name 'last_workspace_manifest' -Default '')
            LastSecretRunId     = [string](Get-PaneControlValue -InputObject $pane -Name 'last_secret_run_id' -Default '')
            LastSecretProfile   = [string](Get-PaneControlValue -InputObject $pane -Name 'last_secret_profile' -Default '')
            LastSecretStatus    = [string](Get-PaneControlValue -InputObject $pane -Name 'last_secret_status' -Default '')
            LastSecretBinding   = [string](Get-PaneControlValue -InputObject $pane -Name 'last_secret_binding' -Default '')
            LastSecretProjectionCount = [string](Get-PaneControlValue -InputObject $pane -Name 'last_secret_projection_count' -Default '')
            LastSecretManifest  = [string](Get-PaneControlValue -InputObject $pane -Name 'last_secret_manifest' -Default '')
            LastBrokerRunId     = [string](Get-PaneControlValue -InputObject $pane -Name 'last_broker_run_id' -Default '')
            LastBrokerProfile   = [string](Get-PaneControlValue -InputObject $pane -Name 'last_broker_profile' -Default '')
            LastBrokerStatus    = [string](Get-PaneControlValue -InputObject $pane -Name 'last_broker_status' -Default '')
            LastBrokerNodeId    = [string](Get-PaneControlValue -InputObject $pane -Name 'last_broker_node_id' -Default '')
            LastBrokerEndpoint  = [string](Get-PaneControlValue -InputObject $pane -Name 'last_broker_endpoint' -Default '')
            LastBrokerManifest  = [string](Get-PaneControlValue -InputObject $pane -Name 'last_broker_manifest' -Default '')
            LastBrokerTokenStatus = [string](Get-PaneControlValue -InputObject $pane -Name 'last_broker_token_status' -Default '')
            LastBrokerTokenHealth = [string](Get-PaneControlValue -InputObject $pane -Name 'last_broker_token_health' -Default '')
            LastBrokerTokenExpiresAt = [string](Get-PaneControlValue -InputObject $pane -Name 'last_broker_token_expires_at' -Default '')
            LastBrokerTokenManifest = [string](Get-PaneControlValue -InputObject $pane -Name 'last_broker_token_manifest' -Default '')
            LastPolicyRunId    = [string](Get-PaneControlValue -InputObject $pane -Name 'last_policy_run_id' -Default '')
            LastPolicyProfile  = [string](Get-PaneControlValue -InputObject $pane -Name 'last_policy_profile' -Default '')
            LastPolicyStatus   = [string](Get-PaneControlValue -InputObject $pane -Name 'last_policy_status' -Default '')
            LastPolicyHealth   = [string](Get-PaneControlValue -InputObject $pane -Name 'last_policy_health' -Default '')
            LastPolicyReason   = [string](Get-PaneControlValue -InputObject $pane -Name 'last_policy_reason' -Default '')
            LastPolicyNetwork  = [string](Get-PaneControlValue -InputObject $pane -Name 'last_policy_network' -Default '')
            LastPolicyWrite    = [string](Get-PaneControlValue -InputObject $pane -Name 'last_policy_write' -Default '')
            LastPolicyProvider = [string](Get-PaneControlValue -InputObject $pane -Name 'last_policy_provider' -Default '')
            LastPolicyMandatoryChecks = [string](Get-PaneControlValue -InputObject $pane -Name 'last_policy_mandatory_checks' -Default '')
            LastPolicyRequiredEvidence = [string](Get-PaneControlValue -InputObject $pane -Name 'last_policy_required_evidence' -Default '')
            LastPolicyManifest = [string](Get-PaneControlValue -InputObject $pane -Name 'last_policy_manifest' -Default '')
            ParentRunId         = [string](Get-PaneControlValue -InputObject $pane -Name 'parent_run_id' -Default '')
            Goal                = [string](Get-PaneControlValue -InputObject $pane -Name 'goal' -Default '')
            TaskType            = [string](Get-PaneControlValue -InputObject $pane -Name 'task_type' -Default '')
            Priority            = [string](Get-PaneControlValue -InputObject $pane -Name 'priority' -Default '')
            Blocking            = ConvertFrom-PaneControlBoolean -Value (Get-PaneControlValue -InputObject $pane -Name 'blocking' -Default $false) -Default $false
            WriteScope          = @(ConvertFrom-PaneControlStringArray -Value (Get-PaneControlValue -InputObject $pane -Name 'write_scope' -Default @()))
            ReadScope           = @(ConvertFrom-PaneControlStringArray -Value (Get-PaneControlValue -InputObject $pane -Name 'read_scope' -Default @()))
            Constraints         = @(ConvertFrom-PaneControlStringArray -Value (Get-PaneControlValue -InputObject $pane -Name 'constraints' -Default @()))
            ExpectedOutput      = [string](Get-PaneControlValue -InputObject $pane -Name 'expected_output' -Default '')
            VerificationPlan    = @(ConvertFrom-PaneControlStringArray -Value (Get-PaneControlValue -InputObject $pane -Name 'verification_plan' -Default @()))
            ReviewRequired      = ConvertFrom-PaneControlBoolean -Value (Get-PaneControlValue -InputObject $pane -Name 'review_required' -Default $false) -Default $false
            ProviderTarget      = [string](Get-PaneControlValue -InputObject $pane -Name 'provider_target' -Default '')
            AgentRole           = [string](Get-PaneControlValue -InputObject $pane -Name 'agent_role' -Default '')
            CapabilityAdapter   = [string](Get-PaneControlValue -InputObject $pane -Name 'capability_adapter' -Default '')
            Status              = [string](Get-PaneControlValue -InputObject $pane -Name 'status' -Default '')
            ApprovedLaunch      = ConvertFrom-PaneControlSecurityPolicy -Value (Get-PaneControlValue -InputObject $pane -Name 'approved_launch' -Default $null)
            BootstrapPlanPath   = [string](Get-PaneControlValue -InputObject $pane -Name 'bootstrap_plan_path' -Default '')
            BootstrapMarkerPath = [string](Get-PaneControlValue -InputObject $pane -Name 'bootstrap_marker_path' -Default '')
            TimeoutPolicy       = [string](Get-PaneControlValue -InputObject $pane -Name 'timeout_policy' -Default '')
            HandoffRefs         = @(ConvertFrom-PaneControlStringArray -Value (Get-PaneControlValue -InputObject $pane -Name 'handoff_refs' -Default @()))
            SecurityPolicy      = ConvertFrom-PaneControlSecurityPolicy -Value (Get-PaneControlValue -InputObject $pane -Name 'security_policy' -Default $null)
        }
    }

    return @($entries)
}

function Test-PaneControlRuntimeContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$ManifestEntry,
        [ValidateSet('dispatch', 'start_deferred', 'caller_ack', 'stop_transition')][string]$Operation = 'dispatch',
        [AllowNull()]$CallerIdentity = $null,
        [AllowNull()][scriptblock]$ProcessResolver = $null
    )

    try {
        $manifest = Get-WinsmuxManifest -ProjectDir $ProjectDir
        $registry = Read-WinsmuxRuntimeRegistry -ProjectDir $ProjectDir
    } catch {
        return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'manifest_regeneration_required' `
            -Diagnostic 'Runtime manifest or registry is missing or malformed; regenerate the orchestra session.'
    }
    if ($null -eq $registry) {
        return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'manifest_regeneration_required' `
            -Diagnostic 'Runtime registry is missing; regenerate the orchestra session.'
    }

    $sessionName = [string](Get-WinsmuxRuntimeValue -InputObject $registry -Name 'session_name' -Default '')
    $serverSessionId = [string](Get-WinsmuxRuntimeValue -InputObject $registry -Name 'server_session_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($sessionName) -or $serverSessionId -cnotmatch '^\$[0-9]+$') {
        return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'manifest_regeneration_required' `
            -Diagnostic 'Runtime registry session identity is malformed; regenerate the orchestra session.'
    }

    try {
        $format = "#{session_id}`t#{session_name}`t#{pane_id}`t#{pane_title}"
        $snapshotOutput = Invoke-PaneControlWinsmux -Arguments @('list-panes', '-a', '-t', $sessionName, '-F', $format)
        $observedPanes = [System.Collections.Generic.List[object]]::new()
        $observedSessionId = ''
        foreach ($line in @((($snapshotOutput | Out-String).Trim()) -split "\r?\n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split "`t", 4
            if ($parts.Count -ne 4 -or $parts[0] -cnotmatch '^\$[0-9]+$' -or $parts[1] -cne $sessionName -or
                [string]::IsNullOrWhiteSpace($parts[2]) -or [string]::IsNullOrWhiteSpace($parts[3])) {
                throw 'server pane snapshot is malformed or belongs to another session'
            }
            if ([string]::IsNullOrWhiteSpace($observedSessionId)) { $observedSessionId = $parts[0] }
            if ($observedSessionId -cne $parts[0]) { throw 'server pane snapshot mixes session identities' }
            $observedPanes.Add([PSCustomObject]@{ pane_id = $parts[2]; title = $parts[3] }) | Out-Null
        }
        if ([string]::IsNullOrWhiteSpace($observedSessionId)) { throw 'server pane snapshot is empty' }
    } catch {
        return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'manifest_regeneration_required' `
            -Diagnostic 'Live server session evidence is unavailable; regenerate the orchestra session.'
    }

    $marker = $null
    $markerPath = [string](Get-PaneControlValue -InputObject $ManifestEntry -Name 'BootstrapMarkerPath' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($markerPath) -and (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        try { $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch {
            return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'runtime_target_mismatch' `
                -Diagnostic 'Pane bootstrap marker is malformed.'
        }
    }

    $backend = ([string](Get-PaneControlValue -InputObject $ManifestEntry -Name 'WorkerBackend' -Default '')).Trim().ToLowerInvariant()
    if ($null -eq $ProcessResolver) {
        try { $ProcessResolver = New-WinsmuxProcessSnapshotResolver }
        catch {
            $reasonCode = if ($Operation -ceq 'caller_ack') { 'caller_identity_mismatch' } else { 'invalid_supervisor_identity' }
            return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode $reasonCode `
                -Diagnostic 'OS process identity evidence is unavailable.'
        }
    }
    if ($null -eq $CallerIdentity -and $Operation -ceq 'caller_ack' -and $backend -in @('local', 'codex')) {
        $callerSnapshot = & $ProcessResolver $PID
        $callerStartedAt = ConvertTo-WinsmuxRuntimeUtcIdentity -Value (Get-WinsmuxRuntimeValue -InputObject $callerSnapshot -Name 'StartTime' -Default (Get-WinsmuxRuntimeValue -InputObject $callerSnapshot -Name 'CreationDate' -Default ''))
        $CallerIdentity = [PSCustomObject][ordered]@{
            process_id        = $PID
            process_started_at = $callerStartedAt
            generation_id    = [string](Get-WinsmuxRuntimeValue -InputObject $registry -Name 'generation_id' -Default '')
            server_session_id = $serverSessionId
            slot_id          = [string](Get-PaneControlValue -InputObject $ManifestEntry -Name 'SlotId' -Default '')
            pane_id          = [string](Get-PaneControlValue -InputObject $ManifestEntry -Name 'PaneId' -Default '')
            backend          = $backend
        }
    }

    return Test-WinsmuxRuntimeContext -Manifest $manifest -Registry $registry -ObservedServerSessionId $observedSessionId `
        -ObservedPanes @($observedPanes) -ManifestEntry $ManifestEntry -PaneMarker $marker -CallerIdentity $CallerIdentity `
        -ProcessResolver $ProcessResolver -Operation $Operation
}

function Wait-PaneControlRuntimeContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$ManifestEntry,
        [ValidateSet('dispatch', 'start_deferred', 'caller_ack', 'stop_transition')][string]$Operation = 'dispatch',
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastResult = $null
    do {
        $lastResult = Test-PaneControlRuntimeContext -ProjectDir $ProjectDir -ManifestEntry $ManifestEntry -Operation $Operation
        if ($lastResult.valid) { return $lastResult }
        if ($lastResult.reason_code -notin @('runtime_target_mismatch', 'manifest_regeneration_required')) {
            return $lastResult
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $lastResult
}

function Get-PaneControlManifestContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$PaneId
    )

    $entries = Get-PaneControlManifestEntries -ProjectDir $ProjectDir
    foreach ($entry in $entries) {
        if ($entry.PaneId -ne $PaneId) {
            continue
        }

        return $entry
    }

    $manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
    throw "Pane $PaneId was not found in manifest: $manifestPath"
}

function Get-PaneControlManifestGenerationId {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Manifest not found: $ManifestPath"
    }
    $projectDir = Split-Path (Split-Path $ManifestPath -Parent) -Parent
    $manifest = Get-WinsmuxManifest -ProjectDir $projectDir
    $version = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $manifest -Name 'version' -Default $null)
    if ($version -ne 2) { return '' }

    $session = Get-WinsmuxRuntimeValue -InputObject $manifest -Name 'session' -Default $null
    $generationId = [string](Get-WinsmuxRuntimeValue -InputObject $session -Name 'generation_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($generationId)) {
        throw 'runtime dispatch refused (manifest_regeneration_required): v2 manifest generation_id is missing.'
    }
    return $generationId
}

function Save-PaneControlManifestDocument {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)]$Manifest,
        [AllowEmptyString()][string]$ExpectedGenerationId = '',
        [AllowEmptyString()][string]$RuntimePaneId = '',
        [ValidateSet('auto', 'dispatch', 'start_deferred', 'caller_ack', 'stop_transition')][string]$RuntimeOperation = 'auto'
    )

    $projectDir = Split-Path (Split-Path $ManifestPath -Parent) -Parent
    $nextVersion = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $Manifest -Name 'version' -Default $null)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        if ($nextVersion -eq 2) {
            throw "Manifest not found: $ManifestPath"
        }
        Save-WinsmuxManifest -ProjectDir $projectDir -Manifest $Manifest
        return
    }

    $currentManifest = Get-WinsmuxManifest -ProjectDir $projectDir
    $currentVersion = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $currentManifest -Name 'version' -Default $null)
    if ($currentVersion -ne 2) {
        $isPureV1Save = $currentVersion -eq 1 -and
            $nextVersion -eq 1 -and
            [string]::IsNullOrWhiteSpace($ExpectedGenerationId)
        if (-not $isPureV1Save) {
            throw 'runtime dispatch refused (manifest_regeneration_required): Current manifest schema is not v2 for a guarded v2 document mutation.'
        }
        Save-WinsmuxManifest -ProjectDir $projectDir -Manifest $Manifest
        return
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedGenerationId)) {
        throw 'runtime dispatch refused (invalid_supervisor_identity): ExpectedGenerationId is required for a v2 manifest mutation.'
    }

    $currentSession = Get-WinsmuxRuntimeValue -InputObject $currentManifest -Name 'session' -Default $null
    $currentGenerationId = [string](Get-WinsmuxRuntimeValue -InputObject $currentSession -Name 'generation_id' -Default '')
    if (-not [string]::Equals($currentGenerationId, $ExpectedGenerationId, [System.StringComparison]::Ordinal)) {
        throw 'runtime dispatch refused (invalid_supervisor_identity): Runtime generation changed before the manifest mutation began.'
    }

    $bootstrapPaneId = [string](Get-WinsmuxRuntimeValue -InputObject $currentSession -Name 'bootstrap_pane_id' -Default '')
    $paneMap = ConvertTo-ManifestPropertyMap -Value (Get-WinsmuxRuntimeValue -InputObject $currentManifest -Name 'panes' -Default $null)
    $managedPaneIds = [System.Collections.Generic.List[string]]::new()
    $seenPaneIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($label in @($paneMap.Keys | Sort-Object)) {
        $paneId = [string](Get-WinsmuxRuntimeValue -InputObject $paneMap[$label] -Name 'pane_id' -Default '')
        if ($paneId -cnotmatch '^%[0-9]+$' -or
            [string]::Equals($paneId, $bootstrapPaneId, [System.StringComparison]::Ordinal)) {
            continue
        }
        if (-not $seenPaneIds.Add($paneId)) {
            throw 'runtime dispatch refused (runtime_target_mismatch): Managed runtime pane IDs must be unique for a v2 manifest mutation.'
        }
        $managedPaneIds.Add($paneId) | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($RuntimePaneId)) {
        if ($managedPaneIds.Count -eq 0) {
            throw 'runtime dispatch refused (runtime_target_mismatch): A live managed runtime pane is required for a v2 manifest mutation.'
        }
        $RuntimePaneId = $managedPaneIds[0]
    } elseif ($RuntimePaneId -cnotmatch '^%[0-9]+$' -or -not $seenPaneIds.Contains($RuntimePaneId)) {
        throw 'runtime dispatch refused (runtime_target_mismatch): RuntimePaneId must identify a managed non-bootstrap pane in the current v2 manifest.'
    }

    $manifestEntry = Get-PaneControlManifestContext -ProjectDir $projectDir -PaneId $RuntimePaneId
    $effectiveOperation = $RuntimeOperation
    if ($effectiveOperation -ceq 'auto') {
        $status = [string](Get-PaneControlValue -InputObject $manifestEntry -Name 'Status' -Default '')
        $effectiveOperation = [string](Get-WinsmuxRuntimeStatusClassification -Status $status).RuntimeOperation
    }
    $runtimeValidation = Test-PaneControlRuntimeContext -ProjectDir $projectDir -ManifestEntry $manifestEntry -Operation $effectiveOperation
    if ($null -eq $runtimeValidation -or -not [bool]$runtimeValidation.valid) {
        $reasonCode = [string](Get-PaneControlValue -InputObject $runtimeValidation -Name 'reason_code' -Default 'invalid_supervisor_identity')
        $diagnostic = [string](Get-PaneControlValue -InputObject $runtimeValidation -Name 'diagnostic' -Default 'Runtime identity validation failed immediately before manifest save.')
        throw ("runtime dispatch refused ({0}): {1}" -f $reasonCode, $diagnostic)
    }
    $validatedGenerationId = [string](Get-PaneControlValue -InputObject $runtimeValidation.context -Name 'generation_id' -Default '')
    if (-not [string]::Equals($validatedGenerationId, $ExpectedGenerationId, [System.StringComparison]::Ordinal)) {
        throw 'runtime dispatch refused (invalid_supervisor_identity): Runtime generation changed immediately before manifest save.'
    }

    $freshManifest = Get-WinsmuxManifest -ProjectDir $projectDir
    $freshVersion = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $freshManifest -Name 'version' -Default $null)
    $freshSession = Get-WinsmuxRuntimeValue -InputObject $freshManifest -Name 'session' -Default $null
    $freshGenerationId = [string](Get-WinsmuxRuntimeValue -InputObject $freshSession -Name 'generation_id' -Default '')
    $nextIdentity = Get-WinsmuxVerifiedManifestIdentity -Manifest $Manifest
    if ($freshVersion -ne 2 -or
        -not [string]::Equals($freshGenerationId, $ExpectedGenerationId, [System.StringComparison]::Ordinal) -or
        $null -eq $nextIdentity -or
        -not [string]::Equals([string]$nextIdentity.generation_id, $ExpectedGenerationId, [System.StringComparison]::Ordinal)) {
        throw 'runtime dispatch refused (invalid_supervisor_identity): Runtime generation changed immediately before manifest save.'
    }

    Save-WinsmuxManifest -ProjectDir $projectDir -Manifest $Manifest -ExpectedGenerationId $ExpectedGenerationId
}

function Set-PaneControlManifestPaneProperties {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Properties,
        [AllowEmptyString()][string]$ExpectedGenerationId = '',
        [ValidateSet('auto', 'dispatch', 'start_deferred', 'caller_ack', 'stop_transition')][string]$RuntimeOperation = 'auto'
    )

    if (-not (Test-Path $ManifestPath -PathType Leaf)) {
        throw "Manifest not found: $ManifestPath"
    }

    $projectDir = Split-Path (Split-Path $ManifestPath -Parent) -Parent
    $manifest = Get-WinsmuxManifest -ProjectDir $projectDir
    if ($null -eq $manifest) {
        throw "Pane $PaneId was not found in manifest: $ManifestPath"
    }

    $manifestVersion = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $manifest -Name 'version' -Default $null)
    if ($manifestVersion -eq 2) {
        if ([string]::IsNullOrWhiteSpace($ExpectedGenerationId)) {
            throw 'runtime dispatch refused (invalid_supervisor_identity): ExpectedGenerationId is required for a v2 manifest mutation.'
        }

        $manifestSession = Get-WinsmuxRuntimeValue -InputObject $manifest -Name 'session' -Default $null
        $initialGenerationId = [string](Get-WinsmuxRuntimeValue -InputObject $manifestSession -Name 'generation_id' -Default '')
        if (-not [string]::Equals($initialGenerationId, $ExpectedGenerationId, [System.StringComparison]::Ordinal)) {
            throw 'runtime dispatch refused (invalid_supervisor_identity): Runtime generation changed before the manifest mutation began.'
        }

        $manifestEntry = Get-PaneControlManifestContext -ProjectDir $projectDir -PaneId $PaneId
        $effectiveOperation = $RuntimeOperation
        if ($effectiveOperation -ceq 'auto') {
            $status = [string](Get-PaneControlValue -InputObject $manifestEntry -Name 'Status' -Default '')
            $effectiveOperation = [string](Get-WinsmuxRuntimeStatusClassification -Status $status).RuntimeOperation
        }
        $runtimeValidation = Test-PaneControlRuntimeContext -ProjectDir $projectDir -ManifestEntry $manifestEntry -Operation $effectiveOperation
        if ($null -eq $runtimeValidation -or -not [bool]$runtimeValidation.valid) {
            $reasonCode = [string](Get-PaneControlValue -InputObject $runtimeValidation -Name 'reason_code' -Default 'invalid_supervisor_identity')
            $diagnostic = [string](Get-PaneControlValue -InputObject $runtimeValidation -Name 'diagnostic' -Default 'Runtime identity validation failed immediately before manifest save.')
            throw ("runtime dispatch refused ({0}): {1}" -f $reasonCode, $diagnostic)
        }
        $validatedGenerationId = [string](Get-PaneControlValue -InputObject $runtimeValidation.context -Name 'generation_id' -Default '')
        if (-not [string]::Equals($validatedGenerationId, $ExpectedGenerationId, [System.StringComparison]::Ordinal)) {
            throw 'runtime dispatch refused (invalid_supervisor_identity): Runtime generation changed immediately before manifest save.'
        }

        # Re-read after runtime validation so a concurrent generation replacement cannot be overwritten by an older document.
        $manifest = Get-WinsmuxManifest -ProjectDir $projectDir
        $freshVersion = ConvertTo-WinsmuxRuntimeInteger -Value (Get-WinsmuxRuntimeValue -InputObject $manifest -Name 'version' -Default $null)
        $freshSession = Get-WinsmuxRuntimeValue -InputObject $manifest -Name 'session' -Default $null
        $freshGenerationId = [string](Get-WinsmuxRuntimeValue -InputObject $freshSession -Name 'generation_id' -Default '')
        if ($freshVersion -ne 2 -or -not [string]::Equals($freshGenerationId, $ExpectedGenerationId, [System.StringComparison]::Ordinal)) {
            throw 'runtime dispatch refused (invalid_supervisor_identity): Runtime generation changed immediately before manifest save.'
        }
    }

    $originalLabel = $null
    $updatedPanes = [ordered]@{}
    foreach ($label in $manifest.panes.Keys) {
        $pane = $manifest.panes[$label]
        if ([string]$pane.pane_id -ne $PaneId) {
            $updatedPanes[$label] = $pane
            continue
        }

        $originalLabel = $label
        $newLabel = if ($Properties.Contains('label')) { [string]$Properties['label'] } else { $label }
        $updatedPane = [ordered]@{}
        $paneMap = ConvertTo-ManifestPropertyMap -Value $pane
        foreach ($propertyName in $paneMap.Keys) {
            $updatedPane[$propertyName] = $paneMap[$propertyName]
        }

        foreach ($entry in $Properties.GetEnumerator()) {
            $propertyName = [string]$entry.Key
            if ($propertyName -eq 'label') {
                continue
            }

            $updatedPane[$propertyName] = $entry.Value
        }

        $updatedPanes[$newLabel] = [PSCustomObject]$updatedPane
    }

    if ($null -eq $originalLabel) {
        throw "Pane $PaneId was not found in manifest: $ManifestPath"
    }

    $manifest.panes = $updatedPanes
    Save-PaneControlManifestDocument -ManifestPath $ManifestPath -Manifest $manifest `
        -ExpectedGenerationId $ExpectedGenerationId -RuntimePaneId $PaneId -RuntimeOperation $RuntimeOperation
}

function Get-PaneControlPaneTitle {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    $titleOutput = Invoke-PaneControlWinsmux -Arguments @('display-message', '-p', '-t', $PaneId, '#{pane_title}')
    return (($titleOutput | Out-String).Trim() -split "\r?\n" | Select-Object -Last 1).Trim()
}

function Update-PaneControlManifestPaneLabel {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [AllowNull()][string]$Label = $null
    )

    $context = Get-PaneControlManifestContext -ProjectDir $ProjectDir -PaneId $PaneId
    $resolvedLabel = if ([string]::IsNullOrWhiteSpace($Label)) {
        Get-PaneControlPaneTitle -PaneId $PaneId
    } else {
        $Label
    }

    if ([string]::IsNullOrWhiteSpace($resolvedLabel)) {
        return $false
    }

    if ([string]$context.Label -eq $resolvedLabel) {
        return $false
    }

    $properties = [ordered]@{
        label = $resolvedLabel
    }
    $expectedGenerationId = [string]$context.GenerationId
    Set-PaneControlManifestPaneProperties -ManifestPath $context.ManifestPath -PaneId $PaneId -Properties $properties `
        -ExpectedGenerationId $expectedGenerationId
    return $true
}

function Set-PaneControlManifestPanePaths {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$LaunchDir,
        [AllowNull()][string]$BuilderWorktreePath = $null
    )

    $context = Get-PaneControlManifestContext -ProjectDir $ProjectDir -PaneId $PaneId
    $manifestPath = [string]$context.ManifestPath
    $properties = [ordered]@{
        launch_dir = $LaunchDir
    }

    if (-not [string]::IsNullOrWhiteSpace($BuilderWorktreePath)) {
        $properties['builder_worktree_path'] = $BuilderWorktreePath
    }

    $expectedGenerationId = [string]$context.GenerationId
    Set-PaneControlManifestPaneProperties -ManifestPath $manifestPath -PaneId $PaneId -Properties $properties `
        -ExpectedGenerationId $expectedGenerationId
}

function Get-PaneControlRestartPlan {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$PaneId,
        $Settings
    )

    if ($null -eq $Settings) {
        if (Get-Command Get-BridgeSettings -ErrorAction SilentlyContinue) {
            $Settings = Get-BridgeSettings -RootPath $ProjectDir
        } else {
            $Settings = [ordered]@{
                agent = 'codex'
                model = ''
                roles = [ordered]@{}
            }
        }
    }

    $context = Get-PaneControlManifestContext -ProjectDir $ProjectDir -PaneId $PaneId
    $agentConfig = $null
    if (Get-Command Get-SlotAgentConfig -ErrorAction SilentlyContinue) {
        $agentConfig = Get-SlotAgentConfig -Role $context.Role -SlotId $context.Label -Settings $Settings -RootPath $ProjectDir
    } elseif (Get-Command Get-RoleAgentConfig -ErrorAction SilentlyContinue) {
        $agentConfig = Get-RoleAgentConfig -Role $context.Role -Settings $Settings -RootPath $ProjectDir
    } else {
        $agentConfig = [ordered]@{
            Agent = [string]$Settings.agent
            Model = [string]$Settings.model
        }
    }

    $launchCommand = Get-PaneControlLaunchCommand -Agent $agentConfig.Agent -Model $agentConfig.Model -ModelSource $agentConfig.ModelSource -ReasoningEffort $agentConfig.ReasoningEffort -McpMode $agentConfig.McpMode -SlotId $context.Label -ProjectDir $context.LaunchDir -GitWorktreeDir $context.GitWorktreeDir -RootPath $ProjectDir

    return [ordered]@{
        PaneId         = $context.PaneId
        GenerationId   = [string]$context.GenerationId
        Label          = $context.Label
        Role           = $context.Role
        ProjectDir     = $context.ProjectDir
        LaunchDir      = $context.LaunchDir
        GitWorktreeDir = $context.GitWorktreeDir
        Agent          = [string]$agentConfig.Agent
        Model          = [string]$agentConfig.Model
        CapabilityAdapter = [string]$agentConfig.CapabilityAdapter
        PromptTransport = [string]$agentConfig.PromptTransport
        Source         = [string]$agentConfig.Source
        LaunchCommand  = $launchCommand
    }
}
