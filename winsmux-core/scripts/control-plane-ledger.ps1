# Run ledger payload builders used by runs, digest, desktop-summary, explain, compare-runs, and promote-tactic.

function Get-RunsPayload {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $boardPayload = Get-BoardPayload -ProjectDir $ProjectDir
    $inboxPayload = Get-InboxPayload -ProjectDir $ProjectDir
    $eventRecords = @(Get-BridgeEventRecords -ProjectDir $ProjectDir)
    $runsById = [ordered]@{}

    foreach ($pane in @($boardPayload.panes)) {
        Assert-ManifestBackedRunShape -PaneRecord $pane
        $runId = Get-RunIdFromPaneRecord -PaneRecord $pane
        if (-not $runsById.Contains($runId)) {
            $runsById[$runId] = [ordered]@{
                run_id             = $runId
                task_id            = [string]$pane.task_id
                task               = [string]$pane.task
                task_state         = [string]$pane.task_state
                review_state       = [string]$pane.review_state
                branch             = [string]$pane.branch
                worktree           = [string]$pane.worktree
                head_sha           = [string]$pane.head_sha
                primary_label      = [string]$pane.label
                primary_pane_id    = [string]$pane.pane_id
                primary_role       = [string]$pane.role
                state              = [string]$pane.state
                tokens_remaining   = [string]$pane.tokens_remaining
                last_event         = [string]$pane.last_event
                last_event_at      = [string]$pane.last_event_at
                pane_count         = 0
                changed_file_count = 0
                labels             = [System.Collections.Generic.List[string]]::new()
                pane_ids           = [System.Collections.Generic.List[string]]::new()
                roles              = [System.Collections.Generic.List[string]]::new()
                changed_files      = [System.Collections.Generic.List[string]]::new()
                action_items       = [System.Collections.Generic.List[object]]::new()
                parent_run_id      = [string]$pane.parent_run_id
                goal               = [string]$pane.goal
                task_type          = [string]$pane.task_type
                priority           = [string]$pane.priority
                blocking           = [bool]$pane.blocking
                write_scope        = [System.Collections.Generic.List[string]]::new()
                read_scope         = [System.Collections.Generic.List[string]]::new()
                constraints        = [System.Collections.Generic.List[string]]::new()
                expected_output    = [string]$pane.expected_output
                verification_plan  = [System.Collections.Generic.List[string]]::new()
                review_required    = [bool]$pane.review_required
                provider_target    = [string]$pane.provider_target
                agent_role         = [string]$pane.agent_role
                timeout_policy     = [string]$pane.timeout_policy
                handoff_refs       = [System.Collections.Generic.List[string]]::new()
                experiment_packet  = $null
                security_policy    = $pane.security_policy
                security_verdict   = $null
                verification_contract = $null
                verification_result   = $null
                verification_evidence = $null
                context_contract      = $null
                team_memory           = $null
                run_insights          = $null
                architecture_contract = $null
                child_launch_contract = $null
                checkpoint_package    = $null
                plan                  = $null
                plan_checkpoints      = @()
                managed_loop          = $null
                audit_chain           = $null
                outcome               = $null
                draft_pr_gate         = $null
                tdd_gate              = $null
                verification_envelope = $null
            }
        }

        $run = $runsById[$runId]
        $run.pane_count = [int]$run.pane_count + 1
        $run.changed_file_count = [int]$run.changed_file_count + [int]$pane.changed_file_count

        if ([string]::IsNullOrWhiteSpace([string]$run.parent_run_id) -and -not [string]::IsNullOrWhiteSpace([string]$pane.parent_run_id)) {
            $run.parent_run_id = [string]$pane.parent_run_id
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.goal) -and -not [string]::IsNullOrWhiteSpace([string]$pane.goal)) {
            $run.goal = [string]$pane.goal
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.task_type) -and -not [string]::IsNullOrWhiteSpace([string]$pane.task_type)) {
            $run.task_type = [string]$pane.task_type
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.priority) -and -not [string]::IsNullOrWhiteSpace([string]$pane.priority)) {
            $run.priority = [string]$pane.priority
        }
        if (-not [bool]$run.blocking -and [bool]$pane.blocking) {
            $run.blocking = $true
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.expected_output) -and -not [string]::IsNullOrWhiteSpace([string]$pane.expected_output)) {
            $run.expected_output = [string]$pane.expected_output
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.worktree) -and -not [string]::IsNullOrWhiteSpace([string]$pane.worktree)) {
            $run.worktree = [string]$pane.worktree
        }
        if (-not [bool]$run.review_required -and [bool]$pane.review_required) {
            $run.review_required = $true
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.provider_target) -and -not [string]::IsNullOrWhiteSpace([string]$pane.provider_target)) {
            $run.provider_target = [string]$pane.provider_target
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.agent_role) -and -not [string]::IsNullOrWhiteSpace([string]$pane.agent_role)) {
            $run.agent_role = [string]$pane.agent_role
        }
        if ([string]::IsNullOrWhiteSpace([string]$run.timeout_policy) -and -not [string]::IsNullOrWhiteSpace([string]$pane.timeout_policy)) {
            $run.timeout_policy = [string]$pane.timeout_policy
        }
        if ($null -eq $run.security_policy -and $null -ne $pane.security_policy) {
            $run.security_policy = $pane.security_policy
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$pane.label) -and -not $run.labels.Contains([string]$pane.label)) {
            $run.labels.Add([string]$pane.label) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$pane.pane_id) -and -not $run.pane_ids.Contains([string]$pane.pane_id)) {
            $run.pane_ids.Add([string]$pane.pane_id) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$pane.role) -and -not $run.roles.Contains([string]$pane.role)) {
            $run.roles.Add([string]$pane.role) | Out-Null
        }

        foreach ($changedFile in @($pane.changed_files)) {
            $changedFileText = [string]$changedFile
            if (-not [string]::IsNullOrWhiteSpace($changedFileText) -and -not $run.changed_files.Contains($changedFileText)) {
                $run.changed_files.Add($changedFileText) | Out-Null
            }
        }
        foreach ($writeScopePath in @($pane.write_scope)) {
            $writeScopeText = [string]$writeScopePath
            if (-not [string]::IsNullOrWhiteSpace($writeScopeText) -and -not $run.write_scope.Contains($writeScopeText)) {
                $run.write_scope.Add($writeScopeText) | Out-Null
            }
        }
        foreach ($readScopePath in @($pane.read_scope)) {
            $readScopeText = [string]$readScopePath
            if (-not [string]::IsNullOrWhiteSpace($readScopeText) -and -not $run.read_scope.Contains($readScopeText)) {
                $run.read_scope.Add($readScopeText) | Out-Null
            }
        }
        foreach ($constraint in @($pane.constraints)) {
            $constraintText = [string]$constraint
            if (-not [string]::IsNullOrWhiteSpace($constraintText) -and -not $run.constraints.Contains($constraintText)) {
                $run.constraints.Add($constraintText) | Out-Null
            }
        }
        foreach ($verificationStep in @($pane.verification_plan)) {
            $verificationText = [string]$verificationStep
            if (-not [string]::IsNullOrWhiteSpace($verificationText) -and -not $run.verification_plan.Contains($verificationText)) {
                $run.verification_plan.Add($verificationText) | Out-Null
            }
        }
        foreach ($handoffRef in @($pane.handoff_refs)) {
            $handoffRefText = [string]$handoffRef
            if (-not [string]::IsNullOrWhiteSpace($handoffRefText) -and -not $run.handoff_refs.Contains($handoffRefText)) {
                $run.handoff_refs.Add($handoffRefText) | Out-Null
            }
        }
    }

    foreach ($item in @($inboxPayload.items)) {
        foreach ($runId in @($runsById.Keys)) {
            $run = $runsById[$runId]
            if (
                ((-not [string]::IsNullOrWhiteSpace([string]$item.task_id)) -and ([string]$item.task_id -eq [string]$run.task_id)) -or
                ((-not [string]::IsNullOrWhiteSpace([string]$item.branch)) -and ([string]$item.branch -eq [string]$run.branch)) -or
                ((-not [string]::IsNullOrWhiteSpace([string]$item.head_sha)) -and ([string]$item.head_sha -eq [string]$run.head_sha)) -or
                ((-not [string]::IsNullOrWhiteSpace([string]$item.label)) -and ($run.labels -contains [string]$item.label)) -or
                ((-not [string]::IsNullOrWhiteSpace([string]$item.pane_id)) -and ($run.pane_ids -contains [string]$item.pane_id))
            ) {
                $run.action_items.Add([ordered]@{
                    kind      = [string]$item.kind
                    message   = [string]$item.message
                    event     = [string]$item.event
                    timestamp = [string]$item.timestamp
                    source    = [string]$item.source
                }) | Out-Null
                break
            }
        }
    }

    foreach ($runId in @($runsById.Keys)) {
        $run = $runsById[$runId]
        $matchingEvents = @(
            foreach ($eventRecord in $eventRecords) {
                if (Test-RunMatchesExperimentEventRecord -Run $run -EventRecord $eventRecord) {
                    $eventRecord
                }
            }
        )

        if (@($matchingEvents).Count -gt 0) {
            $experimentPacket = Get-ExperimentPacketFromEventRecords -EventRecords $matchingEvents
            if (
                $null -ne $experimentPacket -and
                -not [string]::IsNullOrWhiteSpace([string]$experimentPacket.run_id) -and
                [string]$experimentPacket.run_id -ne [string]$run.run_id
            ) {
                $experimentPacket = $null
            }

            $run.experiment_packet = $experimentPacket
            $verificationSnapshot = Get-VerificationSnapshotFromEventRecords -EventRecords $matchingEvents
            if ($null -ne $verificationSnapshot) {
                $run.verification_contract = $verificationSnapshot.verification_contract
                $run.verification_result = $verificationSnapshot.verification_result
                $run.verification_evidence = $verificationSnapshot.verification_evidence
            }

            $securityVerdict = Get-SecurityVerdictFromEventRecords -EventRecords $matchingEvents
            if ($null -ne $securityVerdict) {
                $run.security_verdict = $securityVerdict
            }
            $run.plan_checkpoints = @(Get-RunPlanCheckpointsFromEventRecords -EventRecords $matchingEvents)
            $run.managed_loop = Get-ManagedLoopContractFromEventRecords -EventRecords $matchingEvents
            $run.audit_chain = New-RunAuditChainContract -Run $run -EventRecords $matchingEvents
        }
    }

    $runs = @(
        foreach ($runId in @($runsById.Keys)) {
            $run = $runsById[$runId]
            $runEvents = @($eventRecords | Where-Object { Test-RunMatchesEventRecord -Run $run -EventRecord $_ })
            $run.plan = New-RunPlanContract -Run $run
            $run.draft_pr_gate = New-RunDraftPrGate -Run $run -EventRecords $runEvents
            $run.tdd_gate = New-RunTddGateContract -Run $run -EventRecords $runEvents
            $run.phase_gate = New-RunPhaseGateContract -Run $run -EventRecords $runEvents
            $run.team_memory = New-RunTeamMemoryContract -Run $run -EventRecords $runEvents
            $run.context_contract = New-RunContextContract -Run $run -VerificationEvidence $run.verification_evidence -TeamMemoryRefs @($run.team_memory.team_memory_refs) -TeamMemory $run.team_memory
            $run.audit_chain = New-RunAuditChainContract -Run $run -EventRecords $runEvents
            $run.run_insights = New-RunInsightsContract -Run $run -EventRecords $runEvents
            $run.architecture_contract = New-RunArchitectureContract -Run $run
            $run.draft_pr_gate = New-RunDraftPrGate -Run $run -EventRecords $runEvents
            $run.phase_gate = New-RunPhaseGateContract -Run $run -EventRecords $runEvents
            $run.run_insights = New-RunInsightsContract -Run $run -EventRecords $runEvents
            $run.architecture_contract = New-RunArchitectureContract -Run $run
            $run.verification_envelope = New-RunVerificationEnvelope -Run $run
            $run.outcome = New-RunOutcomeContract -Run $run
            $run.child_launch_contract = New-RunChildLaunchContract -Run $run
            $run.checkpoint_package = New-RunCheckpointPackage -Run $run
            $nextAction = Get-RunNextAction -Run $run
            $stateModel = New-RunStateModel -State ([string]$run.state) -TaskState ([string]$run.task_state) -ReviewState ([string]$run.review_state) -EventKind $nextAction -LastEvent ([string]$run.last_event)
            [ordered]@{
                run_id             = [string]$run.run_id
                task_id            = [string]$run.task_id
                task               = [string]$run.task
                task_state         = [string]$run.task_state
                review_state       = [string]$run.review_state
                phase              = $stateModel.phase
                activity           = $stateModel.activity
                detail             = $stateModel.detail
                branch             = [string]$run.branch
                worktree           = [string]$run.worktree
                head_sha           = [string]$run.head_sha
                primary_label      = [string]$run.primary_label
                primary_pane_id    = [string]$run.primary_pane_id
                primary_role       = [string]$run.primary_role
                state              = [string]$run.state
                tokens_remaining   = [string]$run.tokens_remaining
                last_event         = [string]$run.last_event
                last_event_at      = [string]$run.last_event_at
                pane_count         = [int]$run.pane_count
                changed_file_count = [int]$run.changed_file_count
                labels             = @($run.labels)
                pane_ids           = @($run.pane_ids)
                roles              = @($run.roles)
                changed_files      = @($run.changed_files)
                action_items       = @($run.action_items | Sort-Object @{ Expression = { [string]$_.timestamp }; Descending = $true }, @{ Expression = { [string]$_.kind } })
                parent_run_id      = [string]$run.parent_run_id
                goal               = [string]$run.goal
                task_type          = [string]$run.task_type
                priority           = [string]$run.priority
                blocking           = [bool]$run.blocking
                write_scope        = @($run.write_scope)
                read_scope         = @($run.read_scope)
                constraints        = @($run.constraints)
                expected_output    = [string]$run.expected_output
                verification_plan  = @($run.verification_plan)
                review_required    = [bool]$run.review_required
                provider_target    = [string]$run.provider_target
                agent_role         = if (-not [string]::IsNullOrWhiteSpace([string]$run.agent_role)) { [string]$run.agent_role } else { [string]$run.primary_role }
                timeout_policy     = [string]$run.timeout_policy
                handoff_refs       = @($run.handoff_refs)
                experiment_packet  = $run.experiment_packet
                security_policy    = $run.security_policy
                security_verdict   = $run.security_verdict
                verification_contract = $run.verification_contract
                verification_result   = $run.verification_result
                verification_evidence = $run.verification_evidence
                context_contract      = $run.context_contract
                team_memory           = $run.team_memory
                run_insights          = $run.run_insights
                architecture_contract = $run.architecture_contract
                child_launch_contract = $run.child_launch_contract
                checkpoint_package    = $run.checkpoint_package
                tdd_gate              = $run.tdd_gate
                verification_envelope = $run.verification_envelope
                plan                  = $run.plan
                plan_checkpoints      = @($run.plan_checkpoints)
                managed_loop          = $run.managed_loop
                audit_chain           = $run.audit_chain
                outcome               = $run.outcome
                phase_gate            = $run.phase_gate
                draft_pr_gate         = $run.draft_pr_gate
            }
        }
    )

    foreach ($run in @($runs)) {
        $run['run_packet'] = New-RunPacketFromRun -Run $run
    }

    return [ordered]@{
        generated_at = (Get-Date).ToString('o')
        project_dir  = $ProjectDir
        summary      = [ordered]@{
            run_count          = $runs.Count
            blocked_runs       = @($runs | Where-Object { [string]$_.task_state -eq 'blocked' }).Count
            review_pending     = @($runs | Where-Object { [string]$_.review_state -eq 'PENDING' }).Count
            dirty_runs         = @($runs | Where-Object { [int]$_.changed_file_count -gt 0 }).Count
            action_item_count  = @($runs | ForEach-Object { @($_.action_items).Count } | Measure-Object -Sum).Sum
        }
        runs         = @($runs | Sort-Object @{ Expression = { [string]$_.last_event_at }; Descending = $true }, @{ Expression = { [string]$_.run_id } })
    }
}

function Get-RunFromPayload {
    param(
        [Parameter(Mandatory = $true)]$RunsPayload,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    foreach ($run in @($RunsPayload.runs)) {
        if ([string]$run.run_id -eq $RunId) {
            return $run
        }
    }

    return $null
}

function Test-RunRecommendable {
    param([Parameter(Mandatory = $true)]$Run)

    $taskState = [string]$Run.task_state
    $reviewState = ([string]$Run.review_state).ToUpperInvariant()
    $verificationOutcome = if ($null -ne $Run.verification_result) { ([string]$Run.verification_result.outcome).ToUpperInvariant() } else { '' }
    $securityVerdict = if ($null -ne $Run.security_verdict) { ([string]$Run.security_verdict.verdict).ToUpperInvariant() } else { '' }

    if ($taskState -notin @('completed', 'task_completed', 'commit_ready', 'done')) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($reviewState) -and $reviewState -ne 'PASS') {
        return $false
    }
    if ($verificationOutcome -ne 'PASS') {
        return $false
    }
    if ($securityVerdict -notin @('ALLOW', 'PASS')) {
        return $false
    }
    $architectureContract = Get-RunContractField -InputObject $Run -Name 'architecture_contract'
    $architectureScoreRegression = [bool](Get-RunContractField -InputObject $architectureContract -Name 'score_regression')
    $architectureBaseline = Get-RunContractField -InputObject $architectureContract -Name 'baseline'
    $architectureReviewRequired = [bool](Get-RunContractField -InputObject $architectureBaseline -Name 'review_required_on_drift')
    if ($architectureScoreRegression -and $architectureReviewRequired -and $reviewState -ne 'PASS') {
        return $false
    }

    return $true
}

function Test-RunPromotable {
    param([Parameter(Mandatory = $true)]$Run)

    return (Test-RunRecommendable -Run $Run)
}

function Get-RunPlaybookFlow {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [AllowNull()]$EvidenceDigest = $null,
        [string]$Fallback = 'bugfix'
    )

    $nextAction = [string](Get-RunContractField -InputObject $EvidenceDigest -Name 'next_action')
    $reviewState = [string](Get-RunContractField -InputObject $Run -Name 'review_state')
    $changedFiles = @(
        foreach ($changedFile in @($Run.changed_files)) {
            [string]$changedFile
        }
    )

    if ($changedFiles | Where-Object { $_ -match '^\.github/' -or $_ -match '\.ya?ml$' -or $_ -match 'package(-lock)?\.json$' }) {
        return 'ci'
    }
    if ($reviewState -in @('PENDING', 'FAIL', 'FAILED') -or $nextAction -match 'review') {
        return 'review'
    }
    if ($changedFiles | Where-Object { $_ -match '\.(css|tsx|jsx|html)$' -or $_ -match 'ui|desktop|viewport' }) {
        return 'ui'
    }

    return $Fallback
}

function New-RunPlaybookTemplate {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [AllowNull()]$EvidenceDigest = $null,
        [string]$Flow = '',
        [string]$Source = 'run'
    )

    if ([string]::IsNullOrWhiteSpace($Flow)) {
        $Flow = Get-RunPlaybookFlow -Run $Run -EvidenceDigest $EvidenceDigest
    }

    $requiredEvidence = switch ($Flow) {
        'ci' { @('workflow_status', 'build_log', 'rerun_evidence') }
        'review' { @('findings', 'review_decision', 'evidence_refs') }
        'ui' { @('screenshot_or_manual_check', 'interaction_check', 'viewport_check') }
        'compare_winner_follow_up' { @('winning_run', 'comparison_evidence', 'promotion_candidate') }
        'conflict_resolution' { @('overlap_paths', 'reconcile_consult', 'human_decision') }
        default { @('reproduction', 'fix', 'regression_test') }
    }

    return [ordered]@{
        contract_version          = 1
        packet_type               = 'playbook_template_contract'
        source                    = [string]$Source
        source_run_id             = [string]$Run.run_id
        flow                      = [string]$Flow
        template_refs             = @("playbook:$Flow")
        role_policy               = [ordered]@{
            builder  = 'implement smallest verified change'
            reviewer = 'return findings first with evidence references'
            tester   = 'verify unit integration cli and contract coverage'
        }
        required_evidence         = @($requiredEvidence)
        team_memory_refs          = @(ConvertTo-RunStringArray -Value (Get-RunContractField -InputObject $Run.team_memory -Name 'team_memory_refs') | Sort-Object -Unique)
        handoff_refs              = @($Run.handoff_refs)
        execution_backend         = 'operator_managed'
        backend_profile_required  = $false
        approval_defaults         = New-ManagedFollowUpApprovalDefaults
        freeform_body_stored      = $false
        private_guidance_stored   = $false
        local_reference_paths_stored = $false
    }
}

function New-ManagedFollowUpApprovalDefaults {
    return [ordered]@{
        contract_version        = 1
        packet_type             = 'managed_follow_up_approval_defaults'
        review_required         = $true
        human_approval_required = $true
        auto_merge_allowed      = $false
        merge_requires_human    = $true
        operator_controls_merge = $true
    }
}

function New-CompareWinnerFollowUpRunContract {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$EvidenceDigest,
        [Parameter(Mandatory = $true)]$PlaybookTemplate
    )

    $experimentPacket = Get-RunContractField -InputObject $Run -Name 'experiment_packet'
    $observationPackRef = [string](Get-RunContractField -InputObject $experimentPacket -Name 'observation_pack_ref')
    $consultationRef = [string](Get-RunContractField -InputObject $experimentPacket -Name 'consultation_ref')

    return [ordered]@{
        contract_version             = 1
        packet_type                  = 'managed_follow_up_run_contract'
        source                       = 'compare_runs'
        source_run_id                = [string]$Run.run_id
        task_id                      = [string]$Run.task_id
        flow                         = 'compare_winner_follow_up'
        run_mode                     = 'operator_managed'
        playbook_template_ref        = 'playbook:compare_winner_follow_up'
        required_evidence            = @($PlaybookTemplate.required_evidence)
        source_evidence_refs         = @(
            if (-not [string]::IsNullOrWhiteSpace($observationPackRef)) { $observationPackRef }
            if (-not [string]::IsNullOrWhiteSpace($consultationRef)) { $consultationRef }
        )
        changed_files                = @(ConvertTo-RunPublicChangedFiles -ChangedFiles $EvidenceDigest.changed_files)
        team_memory_refs             = @($PlaybookTemplate.team_memory_refs)
        approval_defaults            = New-ManagedFollowUpApprovalDefaults
        review_required              = $true
        human_approval_required      = $true
        auto_merge_allowed           = $false
        merge_requires_human         = $true
        operator_controls_merge      = $true
        next_action                  = 'start managed follow-up run and request human review before merge'
        local_reference_paths_stored = $false
        freeform_body_stored         = $false
        private_guidance_stored      = $false
    }
}

function New-CompareReconcilePlaybookTemplate {
    param(
        [Parameter(Mandatory = $true)]$LeftRun,
        [Parameter(Mandatory = $true)]$RightRun
    )

    $teamMemoryRefs = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(ConvertTo-RunStringArray -Value (Get-RunContractField -InputObject $LeftRun.team_memory -Name 'team_memory_refs'))) {
        Add-RunUniqueString -List $teamMemoryRefs -Value $item
    }
    foreach ($item in @(ConvertTo-RunStringArray -Value (Get-RunContractField -InputObject $RightRun.team_memory -Name 'team_memory_refs'))) {
        Add-RunUniqueString -List $teamMemoryRefs -Value $item
    }

    return [ordered]@{
        contract_version          = 1
        packet_type               = 'playbook_template_contract'
        source                    = 'compare_runs'
        source_run_id             = ''
        flow                      = 'conflict_resolution'
        template_refs             = @('playbook:conflict_resolution')
        role_policy               = [ordered]@{
            builder  = 'prepare minimal conflict evidence'
            reviewer = 'compare behavior and safety risks'
            tester   = 'verify both branches before choosing'
        }
        required_evidence         = @('overlap_paths', 'reconcile_consult', 'human_decision')
        compare_run_ids           = @([string]$LeftRun.run_id, [string]$RightRun.run_id)
        team_memory_refs          = @($teamMemoryRefs | Sort-Object -Unique)
        execution_backend         = 'operator_managed'
        backend_profile_required  = $false
        approval_defaults         = New-ManagedFollowUpApprovalDefaults
        freeform_body_stored      = $false
        private_guidance_stored   = $false
        local_reference_paths_stored = $false
    }
}

function ConvertTo-CompareRunsPayload {
    param(
        [Parameter(Mandatory = $true)]$LeftPayload,
        [Parameter(Mandatory = $true)]$RightPayload
    )

    $leftRun = $LeftPayload.run
    $rightRun = $RightPayload.run
    $leftExperiment = $leftRun.experiment_packet
    $rightExperiment = $rightRun.experiment_packet
    $leftEvidence = $LeftPayload.evidence_digest
    $rightEvidence = $RightPayload.evidence_digest
    $leftChangedFiles = @($leftEvidence.changed_files)
    $rightChangedFiles = @($rightEvidence.changed_files)
    $sharedChangedFiles = @($leftChangedFiles | Where-Object { $_ -in $rightChangedFiles } | Select-Object -Unique)
    $leftOnlyChangedFiles = @($leftChangedFiles | Where-Object { $_ -notin $rightChangedFiles })
    $rightOnlyChangedFiles = @($rightChangedFiles | Where-Object { $_ -notin $leftChangedFiles })

    $leftConfidence = if ($null -ne $leftExperiment -and $leftExperiment.Contains('confidence')) { $leftExperiment.confidence } else { $null }
    $rightConfidence = if ($null -ne $rightExperiment -and $rightExperiment.Contains('confidence')) { $rightExperiment.confidence } else { $null }
    $confidenceDelta = $null
    if ($null -ne $leftConfidence -and $null -ne $rightConfidence) {
        $confidenceDelta = [math]::Round(([double]$leftConfidence - [double]$rightConfidence), 4)
    }

    $differences = [System.Collections.Generic.List[object]]::new()
    foreach ($field in @(
            'branch',
            'worktree',
            'slot',
            'task_state',
            'review_state',
            'state',
            'next_action',
            'hypothesis',
            'result',
            'env_fingerprint',
            'command_hash'
        )) {
        $leftValue = ''
        $rightValue = ''
        switch ($field) {
            'branch'         { $leftValue = [string]$leftRun.branch; $rightValue = [string]$rightRun.branch }
            'worktree'       { $leftValue = if ($null -ne $leftExperiment) { [string]$leftExperiment.worktree } else { '' }; $rightValue = if ($null -ne $rightExperiment) { [string]$rightExperiment.worktree } else { '' } }
            'slot'           { $leftValue = if ($null -ne $leftExperiment) { [string]$leftExperiment.slot } else { '' }; $rightValue = if ($null -ne $rightExperiment) { [string]$rightExperiment.slot } else { '' } }
            'task_state'     { $leftValue = [string]$leftRun.task_state; $rightValue = [string]$rightRun.task_state }
            'review_state'   { $leftValue = [string]$leftRun.review_state; $rightValue = [string]$rightRun.review_state }
            'state'          { $leftValue = [string]$leftRun.state; $rightValue = [string]$rightRun.state }
            'next_action'    { $leftValue = [string]$leftEvidence.next_action; $rightValue = [string]$rightEvidence.next_action }
            'hypothesis'     { $leftValue = if ($null -ne $leftExperiment) { [string]$leftExperiment.hypothesis } else { '' }; $rightValue = if ($null -ne $rightExperiment) { [string]$rightExperiment.hypothesis } else { '' } }
            'result'         { $leftValue = if ($null -ne $leftExperiment) { [string]$leftExperiment.result } else { '' }; $rightValue = if ($null -ne $rightExperiment) { [string]$rightExperiment.result } else { '' } }
            'env_fingerprint'{ $leftValue = if ($null -ne $leftExperiment) { [string]$leftExperiment.env_fingerprint } else { '' }; $rightValue = if ($null -ne $rightExperiment) { [string]$rightExperiment.env_fingerprint } else { '' } }
            'command_hash'   { $leftValue = if ($null -ne $leftExperiment) { [string]$leftExperiment.command_hash } else { '' }; $rightValue = if ($null -ne $rightExperiment) { [string]$rightExperiment.command_hash } else { '' } }
        }

        if ($leftValue -ne $rightValue) {
            $differences.Add([ordered]@{
                field = $field
                left  = $leftValue
                right = $rightValue
            }) | Out-Null
        }
    }

    if (@($leftOnlyChangedFiles).Count -gt 0 -or @($rightOnlyChangedFiles).Count -gt 0) {
        $differences.Add([ordered]@{
            field = 'changed_files'
            left  = @($leftChangedFiles)
            right = @($rightChangedFiles)
        }) | Out-Null
    }

    if ($null -ne $confidenceDelta -and $confidenceDelta -ne 0) {
        $differences.Add([ordered]@{
            field = 'confidence'
            left  = $leftConfidence
            right = $rightConfidence
        }) | Out-Null
    }

    $leftRecommendable = Test-RunRecommendable -Run $leftRun
    $rightRecommendable = Test-RunRecommendable -Run $rightRun
    $winningRunId = ''
    if ($leftRecommendable -and $rightRecommendable -and $null -ne $confidenceDelta) {
        if ($confidenceDelta -gt 0) {
            $winningRunId = [string]$leftRun.run_id
        } elseif ($confidenceDelta -lt 0) {
            $winningRunId = [string]$rightRun.run_id
        }
    }

    $reconcileConsult = [bool](
        @($differences | Where-Object { $_.field -in @('branch', 'worktree', 'env_fingerprint', 'command_hash', 'result') }).Count -gt 0 -or
        -not ($leftRecommendable -and $rightRecommendable)
    )
    $recommendedPlaybook = $null
    $recommendedFollowUpRun = $null
    if (-not [string]::IsNullOrWhiteSpace($winningRunId)) {
        if ($winningRunId -eq [string]$leftRun.run_id) {
            $recommendedPlaybook = New-RunPlaybookTemplate -Run $leftRun -EvidenceDigest $leftEvidence -Flow 'compare_winner_follow_up' -Source 'compare_runs'
            $recommendedFollowUpRun = New-CompareWinnerFollowUpRunContract -Run $leftRun -EvidenceDigest $leftEvidence -PlaybookTemplate $recommendedPlaybook
        } else {
            $recommendedPlaybook = New-RunPlaybookTemplate -Run $rightRun -EvidenceDigest $rightEvidence -Flow 'compare_winner_follow_up' -Source 'compare_runs'
            $recommendedFollowUpRun = New-CompareWinnerFollowUpRunContract -Run $rightRun -EvidenceDigest $rightEvidence -PlaybookTemplate $recommendedPlaybook
        }
    } elseif ($reconcileConsult) {
        $recommendedPlaybook = New-CompareReconcilePlaybookTemplate -LeftRun $leftRun -RightRun $rightRun
    }

    return [ordered]@{
        generated_at = (Get-Date).ToString('o')
        left = [ordered]@{
            run_id               = [string]$leftRun.run_id
            label                = [string]$leftRun.primary_label
            branch               = [string]$leftRun.branch
            task_state           = [string]$leftRun.task_state
            review_state         = [string]$leftRun.review_state
            state                = [string]$leftRun.state
            next_action          = [string]$leftEvidence.next_action
            confidence           = $leftConfidence
            changed_files        = @($leftChangedFiles)
            observation_pack_ref = if ($null -ne $leftExperiment) { [string]$leftExperiment.observation_pack_ref } else { '' }
            consultation_ref     = if ($null -ne $leftExperiment) { [string]$leftExperiment.consultation_ref } else { '' }
            recommendable        = $leftRecommendable
        }
        right = [ordered]@{
            run_id               = [string]$rightRun.run_id
            label                = [string]$rightRun.primary_label
            branch               = [string]$rightRun.branch
            task_state           = [string]$rightRun.task_state
            review_state         = [string]$rightRun.review_state
            state                = [string]$rightRun.state
            next_action          = [string]$rightEvidence.next_action
            confidence           = $rightConfidence
            changed_files        = @($rightChangedFiles)
            observation_pack_ref = if ($null -ne $rightExperiment) { [string]$rightExperiment.observation_pack_ref } else { '' }
            consultation_ref     = if ($null -ne $rightExperiment) { [string]$rightExperiment.consultation_ref } else { '' }
            recommendable        = $rightRecommendable
        }
        shared_changed_files = @($sharedChangedFiles)
        left_only_changed_files = @($leftOnlyChangedFiles)
        right_only_changed_files = @($rightOnlyChangedFiles)
        confidence_delta = $confidenceDelta
        differences = @($differences)
        recommend = [ordered]@{
            winning_run_id = $winningRunId
            reconcile_consult = $reconcileConsult
            next_action = if ([string]$leftEvidence.next_action -eq [string]$rightEvidence.next_action) { [string]$leftEvidence.next_action } else { 'reconcile_consult' }
            playbook_template = $recommendedPlaybook
            follow_up_run = $recommendedFollowUpRun
        }
    }
}

function Get-PromoteTacticPayload {
    param(
        [Parameter(Mandatory = $true)]$ExplainPayload,
        [string]$Title = '',
        [string]$Kind = 'playbook'
    )

    $run = $ExplainPayload.run
    $experimentPacket = $run.experiment_packet
    $observationPack = $ExplainPayload.observation_pack
    $consultationPacket = $ExplainPayload.consultation_packet
    $evidenceDigest = $ExplainPayload.evidence_digest

    if ([string]::IsNullOrWhiteSpace($Title)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$consultationPacket.recommendation)) {
            $Title = [string]$consultationPacket.recommendation
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$experimentPacket.result)) {
            $Title = [string]$experimentPacket.result
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$run.task)) {
            $Title = [string]$run.task
        } else {
            $Title = "Tactic from $([string]$run.run_id)"
        }
    }
    $playbookFlow = ''
    if ([string]$Kind -eq 'verification') {
        $playbookFlow = 'ci'
    }

    return [ordered]@{
        run_id               = [string]$run.run_id
        task_id              = [string]$run.task_id
        pane_id              = [string]$run.primary_pane_id
        slot                 = if ($null -ne $experimentPacket) { [string]$experimentPacket.slot } else { '' }
        kind                 = [string]$Kind
        title                = [string]$Title
        summary              = if (-not [string]::IsNullOrWhiteSpace([string]$consultationPacket.recommendation)) { [string]$consultationPacket.recommendation } else { [string]$experimentPacket.result }
        hypothesis           = if ($null -ne $experimentPacket) { [string]$experimentPacket.hypothesis } else { '' }
        next_action          = [string]$evidenceDigest.next_action
        confidence           = if ($null -ne $experimentPacket -and $experimentPacket.Contains('confidence')) { $experimentPacket.confidence } else { $null }
        branch               = [string]$run.branch
        head_sha             = [string]$run.head_sha
        worktree             = if ($null -ne $experimentPacket) { [string]$experimentPacket.worktree } else { '' }
        env_fingerprint      = if ($null -ne $experimentPacket) { [string]$experimentPacket.env_fingerprint } else { '' }
        command_hash         = if ($null -ne $experimentPacket) { [string]$experimentPacket.command_hash } else { '' }
        changed_files        = @($evidenceDigest.changed_files)
        observation_pack_ref = if ($null -ne $experimentPacket) { [string]$experimentPacket.observation_pack_ref } else { '' }
        consultation_ref     = if ($null -ne $experimentPacket) { [string]$experimentPacket.consultation_ref } else { '' }
        verification_result  = $run.verification_result
        verification_evidence = $run.verification_evidence
        security_verdict     = $run.security_verdict
        playbook_template    = New-RunPlaybookTemplate -Run $run -EvidenceDigest $evidenceDigest -Flow $playbookFlow -Source 'promote_tactic'
        action_item_count    = @($run.action_items).Count
        action_item_kinds    = @($run.action_items | ForEach-Object { [string]$_.kind } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        reuse_conditions     = @(
            if (-not [string]::IsNullOrWhiteSpace([string]$run.branch)) { "branch=$([string]$run.branch)" }
            if ($null -ne $experimentPacket -and -not [string]::IsNullOrWhiteSpace([string]$experimentPacket.env_fingerprint)) { "env_fingerprint=$([string]$experimentPacket.env_fingerprint)" }
            if ($null -ne $experimentPacket -and -not [string]::IsNullOrWhiteSpace([string]$experimentPacket.command_hash)) { "command_hash=$([string]$experimentPacket.command_hash)" }
        )
    }
}

function Get-ShortHeadSha {
    param([AllowNull()][string]$HeadSha)

    if ([string]::IsNullOrWhiteSpace($HeadSha)) {
        return ''
    }

    if ($HeadSha.Length -le 7) {
        return $HeadSha
    }

    return $HeadSha.Substring(0, 7)
}

function Get-RunNextAction {
    param([Parameter(Mandatory = $true)]$Run)

    $priorityOrder = @(
        'approval_waiting',
        'review_failed',
        'task_blocked',
        'blocked',
        'needs_user_decision',
        'commit_ready',
        'task_completed',
        'review_pending',
        'dispatch_needed'
    )
    foreach ($priorityKind in $priorityOrder) {
        $match = $Run.action_items | Where-Object { [string]$_.kind -eq $priorityKind } | Select-Object -First 1
        if ($null -ne $match) {
            return [string]$match.kind
        }
    }

    $firstActionItem = $Run.action_items | Select-Object -First 1
    if ($null -ne $firstActionItem -and -not [string]::IsNullOrWhiteSpace([string]$firstActionItem.kind)) {
        return [string]$firstActionItem.kind
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Run.review_state)) {
        return [string]$Run.review_state
    }

    return [string]$Run.task_state
}

function New-EmptyVerdictSummary {
    param([Parameter(Mandatory = $true)][string]$Kind)

    return [ordered]@{
        kind      = $Kind
        verdict   = ''
        summary   = ''
        event     = ''
        timestamp = ''
    }
}

function ConvertTo-EvidenceDigestItem {
    param([Parameter(Mandatory = $true)]$Run)

    $experimentPacket = $Run.experiment_packet
    $nextAction = Get-RunNextAction -Run $Run
    $stateModel = New-RunStateModel -State ([string]$Run.state) -TaskState ([string]$Run.task_state) -ReviewState ([string]$Run.review_state) -EventKind $nextAction -LastEvent ([string]$Run.last_event)

    return [ordered]@{
        run_id             = [string]$Run.run_id
        task_id            = [string]$Run.task_id
        task               = [string]$Run.task
        label              = [string]$Run.primary_label
        pane_id            = [string]$Run.primary_pane_id
        role               = [string]$Run.primary_role
        provider_target    = [string]$Run.provider_target
        task_state         = [string]$Run.task_state
        review_state       = [string]$Run.review_state
        phase              = $stateModel.phase
        activity           = $stateModel.activity
        detail             = $stateModel.detail
        next_action        = $nextAction
        branch             = [string]$Run.branch
        worktree           = if ($null -ne $experimentPacket -and -not [string]::IsNullOrWhiteSpace([string]$experimentPacket.worktree)) { [string]$experimentPacket.worktree } else { [string]$Run.worktree }
        head_sha           = [string]$Run.head_sha
        head_short         = Get-ShortHeadSha -HeadSha ([string]$Run.head_sha)
        changed_file_count = [int]$Run.changed_file_count
        changed_files      = @($Run.changed_files)
        action_item_count  = @($Run.action_items).Count
        last_event         = [string]$Run.last_event
        last_event_at      = [string]$Run.last_event_at
        verification_verdict_summary = New-EmptyVerdictSummary -Kind 'verification'
        security_verdict_summary = New-EmptyVerdictSummary -Kind 'security'
        monitoring_verdict_summary = New-EmptyVerdictSummary -Kind 'monitoring'
        verification_outcome = if ($null -ne $Run.verification_result) { [string]$Run.verification_result.outcome } else { '' }
        security_blocked   = if ($null -ne $Run.security_verdict) { [string]$Run.security_verdict.verdict } else { '' }
        hypothesis         = if ($null -ne $experimentPacket) { [string]$experimentPacket.hypothesis } else { '' }
        confidence         = if ($null -ne $experimentPacket) { $experimentPacket.confidence } else { $null }
        observation_pack_ref = if ($null -ne $experimentPacket) { [string]$experimentPacket.observation_pack_ref } else { '' }
        consultation_ref   = if ($null -ne $experimentPacket) { [string]$experimentPacket.consultation_ref } else { '' }
    }
}

function ConvertTo-DigestSummaryEventItem {
    param([Parameter(Mandatory = $true)]$EventRecord)

    $kind = Get-InboxActionableEventKind -EventRecord $EventRecord
    if ([string]::IsNullOrWhiteSpace($kind)) {
        return $null
    }

    $data = $null
    if ($EventRecord.Contains('data')) {
        $data = $EventRecord['data']
    }

    $branch = [string]$EventRecord['branch']
    $headSha = [string]$EventRecord['head_sha']
    $taskId = ''
    $runId = ''
    $nextAction = ''
    $changedFileCount = 0
    if ($null -ne $data -and $data -is [System.Collections.IDictionary]) {
        if ([string]::IsNullOrWhiteSpace($branch) -and $data.Contains('branch')) { $branch = [string]$data['branch'] }
        if ([string]::IsNullOrWhiteSpace($headSha) -and $data.Contains('head_sha')) { $headSha = [string]$data['head_sha'] }
        if ($data.Contains('task_id')) { $taskId = [string]$data['task_id'] }
        if ($data.Contains('run_id')) { $runId = [string]$data['run_id'] }
        if ($data.Contains('next_action')) { $nextAction = [string]$data['next_action'] }
        if ($data.Contains('changed_file_count')) { $changedFileCount = [int]$data['changed_file_count'] }
    }

    return [ordered]@{
        timestamp          = [string]$EventRecord['timestamp']
        kind               = $kind
        source_event       = [string]$EventRecord['event']
        run_id             = $runId
        task_id            = $taskId
        label              = [string]$EventRecord['label']
        pane_id            = [string]$EventRecord['pane_id']
        role               = [string]$EventRecord['role']
        message            = [string]$EventRecord['message']
        next_action        = $nextAction
        branch             = $branch
        head_sha           = $headSha
        head_short         = Get-ShortHeadSha -HeadSha $headSha
        changed_file_count = $changedFileCount
    }
}

function Get-DigestSummaryEventItems {
    param([Parameter(Mandatory = $true)][object[]]$EventRecords)

    return @(
        foreach ($eventRecord in @($EventRecords)) {
            $item = ConvertTo-DigestSummaryEventItem -EventRecord $eventRecord
            if ($null -ne $item) {
                $item
            }
        }
    )
}

function Get-DigestPayload {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $runsPayload = Get-RunsPayload -ProjectDir $ProjectDir
    $items = @(
        foreach ($run in @($runsPayload.runs)) {
            ConvertTo-EvidenceDigestItem -Run $run
        }
    )

    return [ordered]@{
        generated_at = (Get-Date).ToString('o')
        project_dir  = $ProjectDir
        summary      = [ordered]@{
            item_count         = @($items).Count
            dirty_items        = @($items | Where-Object { [int]$_.changed_file_count -gt 0 }).Count
            review_pending     = @($items | Where-Object { [string]$_.review_state -eq 'PENDING' }).Count
            review_failed      = @($items | Where-Object { [string]$_.review_state -in @('FAIL', 'FAILED') }).Count
            actionable_items   = @($items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.next_action) }).Count
        }
        items        = @($items | Sort-Object @{ Expression = { [string]$_.last_event_at }; Descending = $true }, @{ Expression = { [string]$_.run_id } })
    }
}

function New-DesktopRunProjection {
    param(
        [Parameter(Mandatory = $true)]$DigestItem,
        [AllowNull()]$ExplainPayload
    )

    $run = if ($null -ne $ExplainPayload) { $ExplainPayload.run } else { $null }
    $explanation = if ($null -ne $ExplainPayload) { $ExplainPayload.explanation } else { $null }
    $evidenceDigest = if ($null -ne $ExplainPayload) { $ExplainPayload.evidence_digest } else { $null }

    $runId = [string]$DigestItem.run_id
    $task = [string]$DigestItem.task
    $branch = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.branch)) {
        [string]$run.branch
    } else {
        [string]$DigestItem.branch
    }
    $runWorktree = if ($null -ne $run) { [string]$run.worktree } else { '' }
    if ([string]::IsNullOrWhiteSpace($runWorktree) -and $null -ne $run -and $null -ne $run.experiment_packet) {
        $runWorktree = [string]$run.experiment_packet.worktree
    }
    $digestWorktree = if ($null -ne $DigestItem) { [string]$DigestItem.worktree } else { '' }
    $worktree = if (-not [string]::IsNullOrWhiteSpace($runWorktree)) {
        $runWorktree
    } else {
        $digestWorktree
    }
    $changedFiles = if ($null -ne $evidenceDigest -and @($evidenceDigest.changed_files).Count -gt 0) {
        @($evidenceDigest.changed_files)
    } else {
        @($DigestItem.changed_files)
    }
    $summary = if ($null -ne $explanation -and -not [string]::IsNullOrWhiteSpace([string]$explanation.summary)) {
        [string]$explanation.summary
    } elseif (-not [string]::IsNullOrWhiteSpace($task)) {
        $task
    } elseif (-not [string]::IsNullOrWhiteSpace($runId)) {
        "Projected from $runId"
    } else {
        'Projected run'
    }
    $reasons = @()
    if ($null -ne $explanation) {
        $reasons = @($explanation.reasons)
    }

    return [ordered]@{
        run_id               = $runId
        pane_id              = [string]$DigestItem.pane_id
        label                = [string]$DigestItem.label
        branch               = $branch
        worktree             = $worktree
        head_sha             = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.head_sha)) { [string]$run.head_sha } else { [string]$DigestItem.head_sha }
        head_short           = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.head_sha)) { Get-ShortHeadSha -HeadSha ([string]$run.head_sha) } else { [string]$DigestItem.head_short }
        provider_target      = [string]$DigestItem.provider_target
        task                 = $task
        task_state           = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.task_state)) { [string]$run.task_state } else { [string]$DigestItem.task_state }
        review_state         = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.review_state)) { [string]$run.review_state } else { [string]$DigestItem.review_state }
        phase                = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.phase)) { [string]$run.phase } else { [string]$DigestItem.phase }
        activity             = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.activity)) { [string]$run.activity } else { [string]$DigestItem.activity }
        detail               = if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.detail)) { [string]$run.detail } else { [string]$DigestItem.detail }
        verification_outcome = if ($null -ne $evidenceDigest -and -not [string]::IsNullOrWhiteSpace([string]$evidenceDigest.verification_outcome)) { [string]$evidenceDigest.verification_outcome } else { [string]$DigestItem.verification_outcome }
        security_blocked     = if ($null -ne $evidenceDigest -and -not [string]::IsNullOrWhiteSpace([string]$evidenceDigest.security_blocked)) { [string]$evidenceDigest.security_blocked } else { [string]$DigestItem.security_blocked }
        verification_verdict_summary = if ($null -ne $evidenceDigest -and $null -ne $evidenceDigest.verification_verdict_summary) { $evidenceDigest.verification_verdict_summary } else { $DigestItem.verification_verdict_summary }
        security_verdict_summary     = if ($null -ne $evidenceDigest -and $null -ne $evidenceDigest.security_verdict_summary) { $evidenceDigest.security_verdict_summary } else { $DigestItem.security_verdict_summary }
        monitoring_verdict_summary   = if ($null -ne $evidenceDigest -and $null -ne $evidenceDigest.monitoring_verdict_summary) { $evidenceDigest.monitoring_verdict_summary } else { $DigestItem.monitoring_verdict_summary }
        changed_files        = @($changedFiles)
        next_action          = if ($null -ne $explanation -and -not [string]::IsNullOrWhiteSpace([string]$explanation.next_action)) { [string]$explanation.next_action } else { [string]$DigestItem.next_action }
        summary              = $summary
        reasons              = @($reasons)
        hypothesis           = [string]$DigestItem.hypothesis
        confidence           = $DigestItem.confidence
        observation_pack_ref = [string]$DigestItem.observation_pack_ref
        consultation_ref     = [string]$DigestItem.consultation_ref
    }
}

function Get-DesktopSummaryPayload {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $board = Get-BoardPayload -ProjectDir $ProjectDir
    $inbox = Get-InboxPayload -ProjectDir $ProjectDir
    $digest = Get-DigestPayload -ProjectDir $ProjectDir
    $runProjections = @()

    foreach ($digestItem in @($digest.items)) {
        $runProjections += @(New-DesktopRunProjection -DigestItem $digestItem -ExplainPayload $null)
    }

    return [ordered]@{
        generated_at    = (Get-Date).ToString('o')
        project_dir     = $ProjectDir
        board           = $board
        inbox           = $inbox
        digest          = $digest
        run_projections = @($runProjections)
    }
}

function Get-DesktopSummaryRefreshRunId {
    param([Parameter(Mandatory = $true)]$EventRecord)

    $data = $null
    if ($EventRecord.Contains('data')) {
        $data = $EventRecord['data']
    }

    $runId = ''
    if ($null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('run_id')) {
        $runId = [string]$data['run_id']
    }
    if ([string]::IsNullOrWhiteSpace($runId) -and $EventRecord.Contains('run_id')) {
        $runId = [string]$EventRecord['run_id']
    }
    if (-not [string]::IsNullOrWhiteSpace($runId)) {
        return $runId
    }

    $taskId = ''
    if ($null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('task_id')) {
        $taskId = [string]$data['task_id']
    }
    if ([string]::IsNullOrWhiteSpace($taskId) -and $EventRecord.Contains('task_id')) {
        $taskId = [string]$EventRecord['task_id']
    }
    if (-not [string]::IsNullOrWhiteSpace($taskId)) {
        return "task:$taskId"
    }

    $branch = [string]$EventRecord['branch']
    if ([string]::IsNullOrWhiteSpace($branch) -and $null -ne $data -and $data -is [System.Collections.IDictionary] -and $data.Contains('branch')) {
        $branch = [string]$data['branch']
    }
    if (-not [string]::IsNullOrWhiteSpace($branch)) {
        return "branch:$branch"
    }

    return ''
}

function ConvertTo-DesktopSummaryRefreshItem {
    param([Parameter(Mandatory = $true)]$EventRecord)

    $reason = [string]$EventRecord['event']
    if ([string]::IsNullOrWhiteSpace($reason) -and $EventRecord.Contains('status')) {
        $reason = [string]$EventRecord['status']
    }
    if ([string]::IsNullOrWhiteSpace($reason)) {
        return $null
    }

    $item = [ordered]@{
        source = 'summary'
        reason = $reason
    }

    $timestamp = [string]$EventRecord['timestamp']
    if (-not [string]::IsNullOrWhiteSpace($timestamp)) {
        $item['timestamp'] = $timestamp
    }

    $paneId = [string]$EventRecord['pane_id']
    if (-not [string]::IsNullOrWhiteSpace($paneId)) {
        $item['pane_id'] = $paneId
    }

    $runId = Get-DesktopSummaryRefreshRunId -EventRecord $EventRecord
    if (-not [string]::IsNullOrWhiteSpace($runId)) {
        $item['run_id'] = $runId
    }

    return $item
}

function Get-ExplainPayload {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $runsPayload = Get-RunsPayload -ProjectDir $ProjectDir
    $run = @($runsPayload.runs | Where-Object { [string]$_.run_id -eq $RunId } | Select-Object -First 1)[0]
    if ($null -eq $run) {
        Stop-WithError "run not found: $RunId"
    }
    if ($run -is [System.Collections.IDictionary] -and $run.Contains('run_packet')) {
        $run.Remove('run_packet')
    }

    $events = @(
        Get-BridgeEventRecords -ProjectDir $ProjectDir |
            Where-Object { Test-RunMatchesEventRecord -Run $run -EventRecord $_ } |
            ForEach-Object { ConvertTo-RunEventRecord -EventRecord $_ -ProjectDir $ProjectDir } |
            Sort-Object @{ Expression = { [string]$_.timestamp }; Descending = $true }, @{ Expression = { [int]$_.line_number }; Descending = $true }
    )

    $reviewState = $null
    $branch = [string]$run.branch
    if (-not [string]::IsNullOrWhiteSpace($branch)) {
        $state = Get-ReviewState -ProjectDir $ProjectDir
        if ($state.Contains($branch)) {
            $reviewState = ConvertTo-ReviewStateValue -Value $state[$branch]
            Assert-ReviewStateRecordShape -Record $reviewState -Branch $branch
        }
    }

    $reasons = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string]$run.task_state)) {
        $reasons.Add("task_state=$([string]$run.task_state)") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$run.review_state)) {
        $reasons.Add("review_state=$([string]$run.review_state)") | Out-Null
    }
    if ($reviewState -is [System.Collections.IDictionary] -and $reviewState.Contains('request')) {
        $reviewRequest = $reviewState['request']
        if ($reviewRequest -is [System.Collections.IDictionary] -and $reviewRequest.Contains('review_contract')) {
            $reviewContract = $reviewRequest['review_contract']
            if ($reviewContract -is [System.Collections.IDictionary] -and $reviewContract.Contains('required_scope')) {
                $reasons.Add("review_contract=$(([string[]]$reviewContract['required_scope']) -join ',')") | Out-Null
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$run.last_event)) {
        $reasons.Add("last_event=$([string]$run.last_event)") | Out-Null
    }
    foreach ($actionItem in @($run.action_items | Select-Object -First 3)) {
        $reasons.Add("action:$([string]$actionItem.kind)") | Out-Null
    }
    if ($null -ne $run.verification_result -and -not [string]::IsNullOrWhiteSpace([string]$run.verification_result.outcome)) {
        $reasons.Add("verify=$([string]$run.verification_result.outcome)") | Out-Null
    }
    if ($null -ne $run.security_verdict -and -not [string]::IsNullOrWhiteSpace([string]$run.security_verdict.verdict)) {
        $reasons.Add("security=$([string]$run.security_verdict.verdict)") | Out-Null
    }

    $evidenceDigest = ConvertTo-EvidenceDigestItem -Run $run
    $recentEvents = @($events | Select-Object -First 20)
    $observationPack = Get-HydratedObservationPack -ExperimentPacket $run.experiment_packet -ProjectDir $ProjectDir -ExpectedRunId ([string]$run.run_id)
    $consultationPacket = Get-HydratedConsultationPacket -ExperimentPacket $run.experiment_packet -ProjectDir $ProjectDir -ExpectedRunId ([string]$run.run_id)
    if ($observationPack -is [System.Collections.IDictionary] -and $observationPack.Contains('packet_type')) {
        $observationPack.Remove('packet_type')
    }
    if ($consultationPacket -is [System.Collections.IDictionary] -and $consultationPacket.Contains('packet_type')) {
        $consultationPacket.Remove('packet_type')
    }
    return [ordered]@{
        generated_at       = (Get-Date).ToString('o')
        project_dir        = $ProjectDir
        run                = $run
        observation_pack   = $observationPack
        consultation_packet = $consultationPacket
        evidence_digest    = $evidenceDigest
        explanation        = [ordered]@{
            summary       = if (-not [string]::IsNullOrWhiteSpace([string]$run.task)) { [string]$run.task } else { [string]$run.primary_label }
            reasons       = @($reasons)
            next_action   = if (@($run.action_items).Count -gt 0) { [string]$run.action_items[0].kind } else { [string]$run.task_state }
            current_state = [ordered]@{
                state        = [string]$run.state
                task_state   = [string]$run.task_state
                review_state = [string]$run.review_state
                phase        = [string]$run.phase
                activity     = [string]$run.activity
                detail       = [string]$run.detail
                last_event   = [string]$run.last_event
            }
        }
        review_state       = $reviewState
        recent_events      = $recentEvents
    }
}
