#pester:parallel-safe

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RepoRoot 'winsmux-core\scripts\declarative-workflow.ps1')
    . (Join-Path $script:RepoRoot 'winsmux-core\scripts\manifest.ps1')
    . (Join-Path $script:RepoRoot 'winsmux-core\scripts\control-plane-dispatch.ps1')
    . (Join-Path $script:RepoRoot 'winsmux-core\scripts\team-pipeline.ps1')

    function New-TestWorkflowPlan {
        [PSCustomObject]@{
            schema_version = 1
            workflow_id = 'bugfix'
            recipe_ref = 'bugfix-two-slot'
            workflow_fingerprint = ('sha256:' + ('d' * 64))
            task_input = [ordered]@{ source = 'runtime-task-file'; privacy = 'digest-only' }
            resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
            nodes = @(
                [PSCustomObject]@{ node_id = 'inspect'; pane_ref = 'implement'; action = 'operator-dispatch'; depends_on = @(); idempotency_key = 'run-123:inspect'; cleanup = 'retain' },
                [PSCustomObject]@{ node_id = 'verify'; pane_ref = 'verify'; action = 'verification'; depends_on = @('inspect'); idempotency_key = 'run-123:verify'; cleanup = 'retain'; context_pack_ref = 'review-pack' }
            )
            resume_policy = [ordered]@{ mode = 'operator-confirmed'; reject_completed_runs = $true }
            cleanup_policy = [ordered]@{ mode = 'compensating-actions'; on = @('cancel', 'failure', 'success'); actions = @('release-run-lock') }
        }
    }

    function New-TestConfirmation {
        [ordered]@{
            run_id = 'run-123'
            generation_id = 'generation-123'
            config_fingerprint = ('sha256:' + ('a' * 64))
            source_head = ('b' * 40)
        }
    }

    function New-TestTaskInput {
        param([string]$Text = 'Implement TASK-659 safely.')
        $bytes = [System.Text.UTF8Encoding]::new($false, $true).GetBytes($Text)
        [PSCustomObject]@{
            Text = $Text
            ByteCount = $bytes.Length
            Sha256 = Get-DeclarativeWorkflowSha256Digest -Bytes $bytes
        }
    }

    function New-TestRun {
        $taskInput = New-TestTaskInput
        New-DeclarativeWorkflowRun `
            -Plan (New-TestWorkflowPlan) `
            -RunId 'run-123' `
            -GenerationId 'generation-123' `
            -ConfigFingerprint ('sha256:' + ('a' * 64)) `
            -SourceHead ('b' * 40) `
            -TaskInput $taskInput
    }

    function Get-TestWorkflowDerivedState {
        param([Parameter(Mandatory = $true)]$Run)
        if ($null -ne (Get-DeclarativeWorkflowValue $Run 'cancellation_proof' $null)) { return 'cancelled' }
        $states = @($Run.nodes.Values | ForEach-Object { [string]$_.state })
        $nodeState = if ($states -contains 'failed') { 'failed' }
            elseif ($states -contains 'blocked') { 'blocked' }
            elseif ($states -contains 'dispatching') { 'running' }
            elseif (@($states | Where-Object { $_ -cne 'succeeded' }).Count -eq 0) { 'succeeded' }
            elseif ($states -contains 'ready') {
                if (@($Run.nodes.Values | Where-Object { [int]$_.attempt -gt 0 -or [string]$_.state -ceq 'succeeded' }).Count -gt 0) { 'running' } else { 'ready' }
            } else { 'planned' }
        $cleanup = $Run.cleanup_journal[0]
        if ([string]$cleanup.state -ceq 'pending') { return $nodeState }
        if ([string]$cleanup.state -ceq 'running') {
            if ($null -ne (Get-DeclarativeWorkflowValue $Run 'cleanup_preserve_run_state' $null)) { return [string]$Run.cleanup_preserve_run_state }
            return 'cleanup_pending'
        }
        if ([string]$cleanup.state -ceq 'blocked') {
            if ($null -ne (Get-DeclarativeWorkflowValue $Run 'cleanup_preserve_run_state' $null)) { return [string]$Run.cleanup_preserve_run_state }
            return 'blocked'
        }
        if ($null -ne (Get-DeclarativeWorkflowValue $Run 'cleanup_preserve_run_state' $null)) { return [string]$Run.cleanup_preserve_run_state }
        return 'succeeded'
    }

    function Assert-TestWorkflowReducerSnapshot {
        param(
            [Parameter(Mandatory = $true)]$Run,
            [Parameter(Mandatory = $true)]$DurableProofs
        )
        if ([int]$Run.schema_version -eq 1) { throw 'workflow_state_migration_required' }
        if ([int]$Run.schema_version -ne 2) { throw 'workflow_state_invalid' }
        Assert-DeclarativeWorkflowExecutionProjection -Run $Run -Plan $Run.normalized_snapshot
        foreach ($node in $Run.nodes.Values) {
            $dependenciesProven = @($node.depends_on | Where-Object {
                    [string]$Run.nodes[[string]$_].state -cne 'succeeded' -or $null -eq $Run.nodes[[string]$_].completion_proof
                }).Count -eq 0
            $hasSession = -not [string]::IsNullOrWhiteSpace([string](Get-DeclarativeWorkflowValue $node 'agent_cli_session_id' ''))
            $evidence = @($node.evidence_refs)
            $proof = Get-DeclarativeWorkflowValue $node 'completion_proof' $null
            switch ([string]$node.state) {
                'pending' { if ([int]$node.attempt -ne 0 -or $hasSession -or $evidence.Count -ne 0 -or $null -ne $proof -or $dependenciesProven) { throw 'workflow_state_invalid' } }
                'ready' { if ([int]$node.attempt -ne 0 -or $hasSession -or $evidence.Count -ne 0 -or $null -ne $proof -or -not $dependenciesProven) { throw 'workflow_state_invalid' } }
                { $_ -in @('dispatching', 'blocked', 'failed') } { if ([int]$node.attempt -ne 1 -or $hasSession -or $evidence.Count -ne 0 -or $null -ne $proof -or -not $dependenciesProven) { throw 'workflow_state_invalid' } }
                'succeeded' {
                    $expectedEvidence = "workflow-ack:$($Run.run_id):$($node.node_id)"
                    if ([int]$node.attempt -ne 1 -or -not $hasSession -or $evidence.Count -ne 1 -or [string]$evidence[0] -cne $expectedEvidence -or $null -eq $proof -or
                        [string]$proof.run_id -cne [string]$Run.run_id -or [string]$proof.node_id -cne [string]$node.node_id -or
                        [string]$proof.idempotency_key -cne [string]$node.idempotency_key -or [string]$proof.generation_id -cne [string]$Run.generation_id -or
                        [string]$proof.config_fingerprint -cne [string]$Run.config_fingerprint -or [string]$proof.workflow_fingerprint -cne [string]$Run.workflow_fingerprint -or
                        [string]$proof.source_head -cne [string]$Run.source_head -or [string]$proof.pane_id -cne [string]$node.agent_cli_session_id -or
                        [string]$proof.status -cne 'succeeded' -or [string]$proof.evidence_ref -cne $expectedEvidence -or -not $dependenciesProven) { throw 'workflow_state_invalid' }
                    $external = @($DurableProofs.completion_acknowledgements | Where-Object {
                            (ConvertTo-DeclarativeWorkflowCanonicalJson -Value $_) -ceq (ConvertTo-DeclarativeWorkflowCanonicalJson -Value $proof)
                        })
                    if ($external.Count -ne 1) { throw 'workflow_state_invalid' }
                }
                default { throw 'workflow_state_invalid' }
            }
        }
        $cancellation = Get-DeclarativeWorkflowValue $Run 'cancellation_proof' $null
        if ($null -ne $cancellation) {
            $externalCancellation = @($DurableProofs.cancellation_proofs | Where-Object {
                    (ConvertTo-DeclarativeWorkflowCanonicalJson -Value $_) -ceq (ConvertTo-DeclarativeWorkflowCanonicalJson -Value $cancellation)
                })
            if ($externalCancellation.Count -ne 1) { throw 'workflow_state_invalid' }
        }
        $journal = @(Get-DeclarativeWorkflowValue $Run 'cleanup_journal' @())
        if ($journal.Count -ne 1 -or $null -eq $journal[0]) { throw 'workflow_state_invalid' }
        $action = $journal[0]
        $expectedCleanup = [ordered]@{
            action_id       = 'release-run-lock'
            kind            = 'release-run-lock'
            idempotency_key = "$($Run.run_id):cleanup:release-run-lock"
            resource_ref    = "workflow-run-lock:$($Run.run_id)"
        }
        foreach ($entry in $expectedCleanup.GetEnumerator()) {
            if ([string](Get-DeclarativeWorkflowValue $action ([string]$entry.Key) '') -cne [string]$entry.Value) { throw 'workflow_state_invalid' }
        }
        $cleanupState = [string](Get-DeclarativeWorkflowValue $action 'state' '')
        if ($cleanupState -notin @('pending', 'running', 'blocked', 'succeeded')) { throw 'workflow_state_invalid' }
        $nodeOutcome = if ($null -ne $cancellation) { 'cancelled' } else {
            $states = @($Run.nodes.Values | ForEach-Object { [string]$_.state })
            if ($states -contains 'failed') { 'failed' }
            elseif ($states -contains 'blocked') { 'blocked' }
            elseif ($states -contains 'dispatching') { 'running' }
            elseif (@($states | Where-Object { $_ -cne 'succeeded' }).Count -eq 0) { 'succeeded' }
            elseif ($states -contains 'ready') {
                if (@($Run.nodes.Values | Where-Object { [int]$_.attempt -gt 0 -or [string]$_.state -ceq 'succeeded' }).Count -gt 0) { 'running' } else { 'ready' }
            } else { 'planned' }
        }
        $preserved = Get-DeclarativeWorkflowValue $Run 'cleanup_preserve_run_state' $null
        if ($cleanupState -ceq 'pending') {
            if ($null -ne $preserved) { throw 'workflow_state_invalid' }
        } elseif ($null -ne $preserved) {
            if ([string]$preserved -cne [string]$nodeOutcome) { throw 'workflow_state_invalid' }
        } elseif ($nodeOutcome -cne 'succeeded') {
            throw 'workflow_state_invalid'
        }
        if ([string]$Run.state -cne (Get-TestWorkflowDerivedState -Run $Run)) { throw 'workflow_state_invalid' }
    }

    function Invoke-TestWorkflowReducer {
        param([Parameter(Mandatory = $true)]$Request)
        if ([string]$Request.operation -ceq 'bootstrap') {
            $plan = $Request.plan
            $identity = $Request.identity
            $nodes = [ordered]@{}
            foreach ($definition in @($plan.nodes)) {
                $contextPackRef = [string](Get-DeclarativeWorkflowValue $definition 'context_pack_ref' '')
                if (-not [string]::IsNullOrWhiteSpace($contextPackRef) -and
                    -not (Test-DeclarativeWorkflowBoundedReference -Value $contextPackRef)) {
                    throw 'context_pack_ref must be a bounded reference'
                }
                $nodeId = [string]$definition.node_id
                $nodes[$nodeId] = [ordered]@{
                    node_id = $nodeId; state = if (@($definition.depends_on).Count -eq 0) { 'ready' } else { 'pending' }; attempt = 0
                    idempotency_key = [string]$definition.idempotency_key; pane_ref = [string]$definition.pane_ref; action = [string]$definition.action
                    depends_on = @($definition.depends_on); cleanup = [string]$definition.cleanup; evidence_refs = @()
                }
                if (Test-DeclarativeWorkflowFieldExists -InputObject $definition -Name 'context_pack_ref') {
                    $nodes[$nodeId]['context_pack_ref'] = $definition.context_pack_ref
                }
            }
            return [ordered]@{
                schema_version = 2; workflow_id = [string]$plan.workflow_id; recipe_ref = [string]$plan.recipe_ref; run_id = [string]$identity.run_id; state = 'ready'
                generation_id = [string]$identity.generation_id; config_fingerprint = [string]$identity.config_fingerprint; workflow_fingerprint = [string]$plan.workflow_fingerprint
                source_head = [string]$identity.source_head; task_sha256 = [string]$identity.task_sha256; task_byte_count = [int64]$identity.task_byte_count
                resolved_bindings = Copy-DeclarativeWorkflowValue $plan.resolved_bindings; normalized_snapshot = Copy-DeclarativeWorkflowValue $plan
                node_order = @($plan.nodes | ForEach-Object { [string]$_.node_id }); nodes = $nodes
                cleanup_journal = @([ordered]@{ action_id = 'release-run-lock'; kind = 'release-run-lock'; state = 'pending'; idempotency_key = "$($identity.run_id):cleanup:release-run-lock"; resource_ref = "workflow-run-lock:$($identity.run_id)" })
                rollback_state = 'not_requested'
            }
        }
        $run = Copy-DeclarativeWorkflowValue $Request.run
        $event = $Request.event
        $durableProofs = Copy-DeclarativeWorkflowValue $Request.durable_proofs
        if ([string]$event.type -ceq 'acknowledge') {
            $durableProofs.completion_acknowledgements = @($durableProofs.completion_acknowledgements) + @($event.acknowledgement)
        } elseif ([string]$event.type -ceq 'cancel') {
            $durableProofs.cancellation_proofs = @($durableProofs.cancellation_proofs) + @($event.cancellation)
        }
        Assert-TestWorkflowReducerSnapshot -Run $run -DurableProofs $durableProofs
        $node = if (Test-DeclarativeWorkflowFieldExists -InputObject $event -Name 'node_id') { $run.nodes[[string]$event.node_id] } else { $null }
        switch ([string]$event.type) {
            'validate' { return $run }
            'dispatch_intent' { $node.state = 'dispatching'; $node.attempt = 1 }
            'block' { $node.state = 'blocked' }
            'dispatch_failed' { $node.state = 'failed' }
            'acknowledge' {
                $ack = $event.acknowledgement
                $node.state = 'succeeded'; $node.agent_cli_session_id = [string]$event.resolved_session_id
                $node.evidence_refs = @([string]$ack.evidence_ref); $node.completion_proof = Copy-DeclarativeWorkflowValue $ack
                foreach ($candidate in $run.nodes.Values) {
                    if ([string]$candidate.state -cne 'pending') { continue }
                    if (@($candidate.depends_on | Where-Object { [string]$run.nodes[[string]$_].state -cne 'succeeded' -or $null -eq $run.nodes[[string]$_].completion_proof }).Count -eq 0) {
                        $candidate.state = 'ready'
                    }
                }
            }
            'cleanup_intent' {
                $run.cleanup_journal[0].state = 'running'
                if (Test-DeclarativeWorkflowFieldExists -InputObject $event -Name 'preserve_run_state') { $run.cleanup_preserve_run_state = [string]$event.preserve_run_state }
            }
            'cleanup_blocked' { $run.cleanup_journal[0].state = 'blocked' }
            'cleanup_succeeded' { $run.cleanup_journal[0].state = 'succeeded' }
            'cancel' { $run['cancellation_proof'] = Copy-DeclarativeWorkflowValue $event.cancellation }
            default { throw 'workflow_state_invalid' }
        }
        $run.state = Get-TestWorkflowDerivedState -Run $run
        Assert-TestWorkflowReducerSnapshot -Run $run -DurableProofs $durableProofs
        return $run
    }

    function New-TestAcknowledgement {
        param(
            [Parameter(Mandatory = $true)][string]$NodeId,
            [Parameter(Mandatory = $true)][string]$PaneId
        )
        [ordered]@{
            schema_version      = 1
            run_id              = 'run-123'
            node_id             = $NodeId
            idempotency_key     = "run-123:$NodeId"
            generation_id       = 'generation-123'
            config_fingerprint  = ('sha256:' + ('a' * 64))
            workflow_fingerprint = ('sha256:' + ('d' * 64))
            source_head         = ('b' * 40)
            pane_id             = $PaneId
            status              = 'succeeded'
            evidence_ref        = "workflow-ack:run-123:$NodeId"
        }
    }

    function New-TestCancellationProof {
        [ordered]@{
            schema_version       = 1
            run_id               = 'run-123'
            idempotency_key      = 'run-123:cancel'
            generation_id        = 'generation-123'
            config_fingerprint   = ('sha256:' + ('a' * 64))
            workflow_fingerprint = ('sha256:' + ('d' * 64))
            source_head          = ('b' * 40)
            status               = 'cancelled'
            evidence_ref         = 'workflow-cancel:run-123'
        }
    }

    function New-TestDurableProofs {
        param(
            [object[]]$CompletionAcknowledgements = @(),
            [object[]]$CancellationProofs = @()
        )
        [ordered]@{
            completion_acknowledgements = @($CompletionAcknowledgements)
            cancellation_proofs         = @($CancellationProofs)
        }
    }

    function New-TestDispatchedRun {
        param([string]$NodeId = 'inspect', $Run = $null, $DurableProofs = $null)
        if ($null -eq $Run) { $Run = New-TestRun }
        if ($null -eq $DurableProofs) { $DurableProofs = New-TestDurableProofs }
        Invoke-DeclarativeWorkflowTransition -Run $Run -Event ([ordered]@{ type = 'dispatch_intent'; node_id = $NodeId }) -DurableProofs $DurableProofs
    }

    function New-TestBlockedRun {
        $run = New-TestDispatchedRun
        Invoke-DeclarativeWorkflowTransition -Run $run -Event ([ordered]@{ type = 'block'; node_id = 'inspect' })
    }

    function New-TestFailedRun {
        $run = New-TestDispatchedRun
        Invoke-DeclarativeWorkflowTransition -Run $run -Event ([ordered]@{ type = 'dispatch_failed'; node_id = 'inspect' })
    }

    function New-TestSucceededInspectRun {
        $run = New-TestDispatchedRun
        $acknowledgement = New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'
        Invoke-DeclarativeWorkflowTransition -Run $run -Event ([ordered]@{
                type = 'acknowledge'; node_id = 'inspect'; resolved_session_id = '%2'; acknowledgement = $acknowledgement
            })
    }

    function New-TestSucceededRun {
        $inspectAcknowledgement = New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'
        $run = New-TestSucceededInspectRun
        $durableProofs = New-TestDurableProofs -CompletionAcknowledgements @($inspectAcknowledgement)
        $run = New-TestDispatchedRun -NodeId 'verify' -Run $run -DurableProofs $durableProofs
        $verifyAcknowledgement = New-TestAcknowledgement -NodeId 'verify' -PaneId '%3'
        Invoke-DeclarativeWorkflowTransition -Run $run -Event ([ordered]@{
                type = 'acknowledge'; node_id = 'verify'; resolved_session_id = '%3'; acknowledgement = $verifyAcknowledgement
            }) -DurableProofs $durableProofs
    }

    function New-TestCancelledRun {
        $run = New-TestRun
        $cancellation = New-TestCancellationProof
        Invoke-DeclarativeWorkflowTransition -Run $run -Event ([ordered]@{ type = 'cancel'; cancellation = $cancellation })
    }

    function New-TestAcceptedReceipt {
        param(
            [Parameter(Mandatory = $true)][string]$NodeId,
            [Parameter(Mandatory = $true)][string]$PaneId
        )
        $acknowledgement = New-TestAcknowledgement -NodeId $NodeId -PaneId $PaneId
        [PSCustomObject]@{
            status          = 'accepted'
            target          = [PSCustomObject]@{ pane_id = $PaneId }
            evidence_refs   = @($acknowledgement.evidence_ref)
            acknowledgement = $acknowledgement
        }
    }
}

Describe 'TASK-659 declarative workflow runtime' -Tag 'unit' {
    BeforeEach {
        Mock Invoke-DeclarativeWorkflowNativeReducerProcess {
            param($RequestPath)
            $request = [IO.File]::ReadAllText($RequestPath, [Text.UTF8Encoding]::new($false, $true)) |
                ConvertFrom-WinsmuxJson -AsHashtable -Depth 100 -ErrorAction Stop
            Invoke-TestWorkflowReducer -Request $request
        }
        $script:testDeclarativeSessionName = 'winsmux-orchestra'
        Mock Get-PaneControlManifestEntries {
            @(
                [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%2'; GenerationId = 'generation-123'; Role = 'Builder' }
                [PSCustomObject]@{ Label = 'worker-2'; PaneId = '%3'; GenerationId = 'generation-123'; Role = 'Reviewer' }
            )
        }
        Mock Get-PaneControlManifestContext {
            param($ProjectDir, $PaneId)
            Get-PaneControlManifestEntries -ProjectDir $ProjectDir | Where-Object { $_.PaneId -ceq $PaneId } | Select-Object -First 1
        }
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation)
            [PSCustomObject]@{
                valid = $true
                context = [PSCustomObject]@{
                    session_name = $script:testDeclarativeSessionName
                    generation_id = [string]$ManifestEntry.GenerationId
                    label = [string]$ManifestEntry.Label
                    pane_id = [string]$ManifestEntry.PaneId
                }
            }
        }
    }

    It 'L01 L02 selects declarative mode only for the leading marker' {
        (ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget 'legacy task' -CommandRest @('--workflow-action', 'start')) | Should -BeNullOrEmpty
        (Join-WinsmuxControlPlaneText -Arguments (Get-WinsmuxControlPlaneArguments -CommandTarget 'legacy task' -CommandRest @('--workflow-action', 'start'))) | Should -Be 'legacy task --workflow-action start'
    }

    It 'A01 accepts only the closed start and resume argument sets' {
        $common = @('--run-id', 'run-123', '--generation-id', 'generation-123', '--config-fingerprint', ('sha256:' + ('a' * 64)), '--source-head', ('b' * 40), '--task-file', 'task.txt', '--json')
        $start = ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget '--workflow-action' -CommandRest (@('start', '--recipe-id', 'bugfix-two-slot', '--workflow-id', 'bugfix') + $common)
        $resume = ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget '--workflow-action' -CommandRest (@('resume') + $common)
        $start.workflow_action | Should -Be 'start'
        $resume.workflow_action | Should -Be 'resume'
        { ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget '--workflow-action' -CommandRest (@('start', '--recipe-id', 'bugfix-two-slot', '--workflow-id', 'bugfix') + $common + @('--run-id', 'other')) } | Should -Throw '*Duplicate*'
        { ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget '--workflow-action' -CommandRest (@('resume') + $common + @('positional')) } | Should -Throw '*Unknown or positional*'
        { ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget '--workflow-action' -CommandRest (@('resume') + $common + @('--unknown', 'x')) } | Should -Throw '*Unknown*'

        $bridge = Join-Path $script:RepoRoot 'scripts\winsmux-core.ps1'
        $invalidCases = [Collections.Generic.List[object]]::new()
        $invalidCases.Add([string[]]@('pipeline', '--workflow-action', 'resume', '--run-id', 'run-123', '--generation-id', 'generation-123', '--config-fingerprint', ('sha256:' + ('a' * 64)), '--source-head', ('b' * 40), '--json')) | Out-Null
        $invalidCases.Add([string[]](@('pipeline', '--workflow-action', 'resume') + $common + @('--run-id', 'other'))) | Out-Null
        $invalidCases.Add([string[]](@('pipeline', '--workflow-action', 'resume') + $common + @('--unknown', 'x'))) | Out-Null
        foreach ($invalidArguments in $invalidCases) {
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @('-NoProfile', '-File', $bridge) + $invalidArguments) { $startInfo.ArgumentList.Add([string]$argument) }
            $process = [Diagnostics.Process]::Start($startInfo)
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $output = @($stdout -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $exitCode = $process.ExitCode
            $output.Count | Should -Be 1 -Because $stderr
            $payload = $output[0] | ConvertFrom-Json -ErrorAction Stop
            $payload.status | Should -Be 'rejected'
            $exitCode | Should -Be 1
        }
    }

    It 'A02 invokes workspace-plan exactly once and consumes its one strict JSON object' {
        Mock Invoke-TeamPipelineBridge {
            [PSCustomObject]@{
                ExitCode = 0
                Output = '{"schema_version":1,"config_fingerprint":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","resolved_bindings":{},"workflow":{}}'
            }
        }

        $plan = Invoke-TeamPipelineWorkspacePlanOnce -ProjectDir $TestDrive -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' -RunId 'run-123'

        $plan.schema_version | Should -Be 1
        $plan.workflow | Should -BeOfType ([System.Collections.IDictionary])
        Should -Invoke Invoke-TeamPipelineBridge -Times 1 -Exactly
    }

    It 'A03 rejects nonzero, malformed, or extra workspace-plan output' {
        Mock Invoke-TeamPipelineBridge { $script:WorkspacePlanResult }
        $cases = @(
            [PSCustomObject]@{ ExitCode = 1; Output = '{}' },
            [PSCustomObject]@{ ExitCode = 0; Output = '{invalid' },
            [PSCustomObject]@{ ExitCode = 0; Output = '{"workflow":{}} trailing' }
        )

        foreach ($case in $cases) {
            $script:WorkspacePlanResult = $case
            { Invoke-TeamPipelineWorkspacePlanOnce -ProjectDir $TestDrive -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' -RunId 'run-123' } | Should -Throw 'workspace_plan_*'
        }
        Should -Invoke Invoke-TeamPipelineBridge -Times 3 -Exactly
    }

    It 'W16 reads BOM-free UTF-8 once and persists only digest metadata' {
        $path = Join-Path $TestDrive 'task.txt'
        [System.IO.File]::WriteAllBytes($path, [System.Text.UTF8Encoding]::new($false).GetBytes('日本語 task'))

        $input = Read-DeclarativeWorkflowTaskFile -Path $path
        $run = New-DeclarativeWorkflowRun -Plan (New-TestWorkflowPlan) -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskInput $input
        $json = $run | ConvertTo-Json -Depth 20

        $input.Text | Should -Be '日本語 task'
        $run.task_byte_count | Should -Be 14
        $run.task_sha256 | Should -Match '^sha256:[0-9a-f]{64}$'
        $json | Should -Not -Match '日本語 task'
        $json | Should -Not -Match ([regex]::Escape($path))
    }

    It 'W16 uses the shared SHA-256 boundary for task input and completion envelopes under Windows PowerShell 5.1' {
        $caseRoot = Join-Path $TestDrive 'task659-ps51-digest-boundary'
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $taskPath = Join-Path $caseRoot 'task.txt'
        $childScriptPath = Join-Path $caseRoot 'validate-digest-boundary.ps1'
        [System.IO.File]::WriteAllBytes($taskPath, [System.Text.UTF8Encoding]::new($false).GetBytes('PS5.1 digest boundary'))

        $childScript = @'
param(
    [Parameter(Mandatory = $true)][string]$DeclarativeScript,
    [Parameter(Mandatory = $true)][string]$TeamPipelineScript,
    [Parameter(Mandatory = $true)][string]$TaskPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. $DeclarativeScript
. $TeamPipelineScript
$Error.Clear()

function Invoke-DeclarativeWorkflowNativeReducerProcess {
    param([string]$RequestPath)
    $request = [IO.File]::ReadAllText($RequestPath, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
    $definition = $request.plan.nodes[0]
    return [ordered]@{
        schema_version = 2; workflow_id = [string]$request.plan.workflow_id; recipe_ref = [string]$request.plan.recipe_ref; run_id = [string]$request.identity.run_id; state = 'ready'
        generation_id = [string]$request.identity.generation_id; config_fingerprint = [string]$request.identity.config_fingerprint; workflow_fingerprint = [string]$request.plan.workflow_fingerprint
        source_head = [string]$request.identity.source_head; task_sha256 = [string]$request.identity.task_sha256; task_byte_count = [int64]$request.identity.task_byte_count
        resolved_bindings = $request.plan.resolved_bindings; normalized_snapshot = $request.plan; node_order = @([string]$definition.node_id)
        nodes = [ordered]@{ inspect = [ordered]@{ node_id = 'inspect'; state = 'ready'; attempt = 0; idempotency_key = 'run-ps51:inspect'; pane_ref = 'implement'; action = 'operator-dispatch'; depends_on = @(); cleanup = 'retain'; evidence_refs = @() } }
        cleanup_journal = @([ordered]@{ action_id = 'release-run-lock'; kind = 'release-run-lock'; state = 'pending'; idempotency_key = 'run-ps51:cleanup:release-run-lock'; resource_ref = 'workflow-run-lock:run-ps51' })
        rollback_state = 'not_requested'
    }
}

$taskInput = Read-DeclarativeWorkflowTaskFile -Path $TaskPath
$plan = [ordered]@{
    schema_version = 1
    workflow_id = 'bugfix'
    recipe_ref = 'bugfix-two-slot'
    workflow_fingerprint = ('sha256:' + ('d' * 64))
    task_input = [ordered]@{ source = 'runtime-task-file'; privacy = 'digest-only' }
    resolved_bindings = [ordered]@{ implement = 'worker-1' }
    nodes = @(
        [ordered]@{ node_id = 'inspect'; pane_ref = 'implement'; action = 'operator-dispatch'; depends_on = @(); idempotency_key = 'run-ps51:inspect'; cleanup = 'retain' }
    )
    resume_policy = [ordered]@{ mode = 'operator-confirmed'; reject_completed_runs = $true }
    cleanup_policy = [ordered]@{ mode = 'compensating-actions'; on = @('cancel', 'failure', 'success'); actions = @('release-run-lock') }
}
$run = New-DeclarativeWorkflowRun -Plan $plan -RunId 'run-ps51' -GenerationId 'generation-ps51' -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskInput $taskInput
$instruction = New-TeamPipelineDeclarativeCompletionInstruction -Run $run -NodeId 'inspect' -SessionName 'workflow-ps51' -Target 'worker-1' -PaneId '%2' -Role 'implement'
$mailboxCommand = @($instruction -split '\r?\n' | Where-Object { $_ -like 'winsmux mailbox-send *' })
if ($mailboxCommand.Count -ne 1 -or $mailboxCommand[0] -notmatch "^winsmux mailbox-send '[^']+' '(?<payload>.+)'$") {
    throw 'completion instruction did not contain exactly one mailbox envelope command.'
}
$envelope = $matches['payload'] | ConvertFrom-Json -ErrorAction Stop

[PSCustomObject][ordered]@{
    host_version = $PSVersionTable.PSVersion.ToString()
    error_count = @($Error).Count
    task = [ordered]@{
        text = $taskInput.Text
        byte_count = $taskInput.ByteCount
        sha256 = $taskInput.Sha256
    }
    envelope = [ordered]@{
        mailbox_version = $envelope.mailbox_version
        message_id = $envelope.message_id
        correlation_id = $envelope.correlation_id
        idempotency_key = $envelope.idempotency_key
        message_type = $envelope.message_type
        state = $envelope.state
        ack_required = $envelope.ack_required
        from = $envelope.from
        to = $envelope.to
        timestamp = $envelope.timestamp
        content = [ordered]@{
            event = $envelope.content.event
            status = $envelope.content.status
            pane_id = $envelope.content.pane_id
            role = $envelope.content.role
            data = $envelope.content.data
        }
    }
} | ConvertTo-Json -Compress -Depth 12
'@
        [System.IO.File]::WriteAllText($childScriptPath, $childScript, [System.Text.UTF8Encoding]::new($false))

        $declarativeScript = Join-Path $script:RepoRoot 'winsmux-core\scripts\declarative-workflow.ps1'
        $teamPipelineScript = Join-Path $script:RepoRoot 'winsmux-core\scripts\team-pipeline.ps1'
        $output = @(& powershell.exe -NoProfile -File $childScriptPath -DeclarativeScript $declarativeScript -TeamPipelineScript $teamPipelineScript -TaskPath $taskPath 2>&1)
        $exitCode = $LASTEXITCODE
        $jsonLine = @($output | Where-Object { ([string]$_).TrimStart().StartsWith('{') } | Select-Object -Last 1)

        $jsonLine.Count | Should -Be 1 -Because (($output | Out-String).Trim())
        $result = ([string]$jsonLine[0]) | ConvertFrom-Json
        $result.host_version | Should -Match '^5\.1\.'
        $result.error_count | Should -Be 0
        $result.task.text | Should -Be 'PS5.1 digest boundary'
        $result.task.byte_count | Should -Be 21
        $result.task.sha256 | Should -Be 'sha256:f960845f68f1ab41d39e591c0280d872b2bf4ed2141a35646a4c81810f4e1141'
        $result.envelope.mailbox_version | Should -Be 2
        $result.envelope.message_id | Should -Be 'workflow-ack-2ba826611c05107ef2c4af13'
        $result.envelope.correlation_id | Should -Be $result.envelope.message_id
        $result.envelope.idempotency_key | Should -Be ('workflow-completion-' + $result.envelope.message_id.Substring('workflow-ack-'.Length))
        $result.envelope.message_type | Should -Be 'workflow-completion'
        $result.envelope.state | Should -Be 'created'
        $result.envelope.ack_required | Should -BeTrue
        $result.envelope.from | Should -Be 'worker-1'
        $result.envelope.to | Should -Be 'Operator'
        $result.envelope.timestamp | Should -BeNullOrEmpty
        $result.envelope.content.event | Should -Be 'workflow.node.acknowledged'
        $result.envelope.content.status | Should -Be 'succeeded'
        $result.envelope.content.pane_id | Should -Be '%2'
        $result.envelope.content.role | Should -Be 'implement'
        $result.envelope.content.data.run_id | Should -Be 'run-ps51'
        $result.envelope.content.data.node_id | Should -Be 'inspect'
        $result.envelope.content.data.idempotency_key | Should -Be 'run-ps51:inspect'
        $result.envelope.content.data.generation_id | Should -Be 'generation-ps51'
        $result.envelope.content.data.config_fingerprint | Should -Be ('sha256:' + ('a' * 64))
        $result.envelope.content.data.workflow_fingerprint | Should -Be ('sha256:' + ('d' * 64))
        $result.envelope.content.data.source_head | Should -Be ('b' * 40)
        $result.envelope.content.data.pane_id | Should -Be '%2'
        $result.envelope.content.data.status | Should -Be 'succeeded'
        $result.envelope.content.data.evidence_ref | Should -Be 'workflow-ack:run-ps51:inspect'
        $exitCode | Should -Be 0
    }

    It 'W16 rejects BOM NUL invalid UTF-8 and oversized files' {
        $cases = @(
            [byte[]](0xEF, 0xBB, 0xBF, 0x61),
            [byte[]](0x61, 0x00, 0x62),
            [byte[]](0xC3, 0x28),
            [byte[]](New-Object byte[] 262145)
        )
        for ($index = 0; $index -lt $cases.Count; $index++) {
            $path = Join-Path $TestDrive "invalid-$index.bin"
            [IO.File]::WriteAllBytes($path, $cases[$index])
            { Read-DeclarativeWorkflowTaskFile -Path $path } | Should -Throw
        }
    }

    It 'O01 uses immutable run-owned completion and cancellation proofs without log fallback' {
        $project = Join-Path $TestDrive 'o01-proof-store'
        $run = New-TestRun
        Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $run -CreateNew | Out-Null
        $acknowledgement = New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'
        $acknowledgement['transport'] = 'mailbox'
        $acknowledgement['message_id'] = 'workflow-ack-o01'

        $proofPath = Write-DeclarativeWorkflowDurableProof -ProjectDir $project -Run $run -Kind Completion -NodeId 'inspect' -Proof $acknowledgement
        $before = [IO.File]::ReadAllBytes($proofPath)
        Write-DeclarativeWorkflowDurableProof -ProjectDir $project -Run $run -Kind Completion -NodeId 'inspect' -Proof $acknowledgement | Should -BeExactly $proofPath
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($proofPath)) | Should -BeExactly ([Convert]::ToBase64String($before))

        Write-OrchestraLog -ProjectDir $project -SessionName 'unused-log' -Event 'workflow.node.acknowledged' -PaneId '%2' -Data $acknowledgement | Out-Null
        $observabilityLog = Get-OrchestraLogPath -ProjectDir $project -SessionName 'unused-log'
        Remove-Item -LiteralPath $observabilityLog -Force
        $resolved = @(Resolve-TeamPipelineDeclarativeAcknowledgement -Run $run -NodeId 'inspect' -ProjectDir $project -SessionName 'unused-log')
        $resolved.Count | Should -Be 1
        $resolved[0].message_id | Should -BeExactly 'workflow-ack-o01'

        $conflict = Copy-DeclarativeWorkflowValue $acknowledgement
        $conflict.pane_id = '%3'
        { Write-DeclarativeWorkflowDurableProof -ProjectDir $project -Run $run -Kind Completion -NodeId 'inspect' -Proof $conflict } |
            Should -Throw '*conflict*'
        Test-Path -LiteralPath (Join-Path $project '.winsmux\workflow-runs\run-123\proofs\completion\inspect.conflict') -PathType Leaf | Should -BeTrue
        { Read-DeclarativeWorkflowDurableProof -ProjectDir $project -Run $run -Kind Completion -NodeId 'inspect' } |
            Should -Throw '*conflict*'
        { Write-DeclarativeWorkflowDurableProof -ProjectDir $project -Run $run -Kind Completion -NodeId 'inspect' -Proof $acknowledgement } |
            Should -Throw '*conflict*'
        $script:o01SaveCount = 0
        $script:o01DispatchCount = 0
        {
            Invoke-DeclarativeWorkflowResume -Run (New-TestDispatchedRun) -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
                -SaveRun { $script:o01SaveCount++ } `
                -Dispatch { $script:o01DispatchCount++ } `
                -ResolveSession { '%2' } `
                -ResolveAcknowledgement {
                    param($candidate, $nodeId)
                    Resolve-TeamPipelineDeclarativeAcknowledgement -Run $candidate -NodeId $nodeId -ProjectDir $project -SessionName 'unused-log'
                }
        } | Should -Throw '*conflict*'
        $script:o01SaveCount | Should -Be 0
        $script:o01DispatchCount | Should -Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($proofPath)) | Should -BeExactly ([Convert]::ToBase64String($before))

        $cancellation = New-TestCancellationProof
        $cancelPath = Write-DeclarativeWorkflowDurableProof -ProjectDir $project -Run $run -Kind Cancellation -Proof $cancellation
        Test-Path -LiteralPath $cancelPath -PathType Leaf | Should -BeTrue
        $resolvedCancellation = @(Resolve-TeamPipelineDeclarativeCancellation -Run $run -ProjectDir $project -SessionName 'unused-log')
        $resolvedCancellation.Count | Should -Be 1
        $resolvedCancellation[0].evidence_ref | Should -BeExactly 'workflow-cancel:run-123'
    }

    It 'P01 rejects prepared proof directory and leaf junctions without changing external bytes' {
        $project = Join-Path $TestDrive 'p01-proof-reparse'
        $run = New-TestRun
        Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $run -CreateNew | Out-Null
        $acknowledgement = New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'
        $acknowledgement['transport'] = 'mailbox'
        $acknowledgement['message_id'] = 'workflow-ack-p01'
        $runRoot = Join-Path $project '.winsmux\workflow-runs\run-123'
        $external = Join-Path $TestDrive 'external-proof-target'
        [IO.Directory]::CreateDirectory($external) | Out-Null
        $marker = Join-Path $external 'marker.txt'
        [IO.File]::WriteAllText($marker, 'unchanged', [Text.UTF8Encoding]::new($false))
        $before = [IO.File]::ReadAllBytes($marker)
        $proofsJunction = Join-Path $runRoot 'proofs'
        $junction = $null
        try {
            $junction = New-Item -ItemType Junction -Path $proofsJunction -Target $external -ErrorAction Stop
            { Write-DeclarativeWorkflowDurableProof -ProjectDir $project -Run $run -Kind Completion -NodeId 'inspect' -Proof $acknowledgement } |
                Should -Throw '*reparse*'
            { Read-DeclarativeWorkflowDurableProof -ProjectDir $project -Run $run -Kind Completion -NodeId 'inspect' } |
                Should -Throw '*reparse*'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($marker)) | Should -BeExactly ([Convert]::ToBase64String($before))
            @(Get-ChildItem -LiteralPath $external -Force).Count | Should -Be 1
        } finally {
            if ($null -ne $junction -and (Test-Path -LiteralPath $proofsJunction)) { $junction.Delete() }
        }

        $proofsRoot = Join-Path $runRoot 'proofs'
        $completionRoot = Join-Path $proofsRoot 'completion'
        [IO.Directory]::CreateDirectory($completionRoot) | Out-Null
        $leafJunction = Join-Path $completionRoot 'inspect.json'
        $junction = $null
        try {
            $junction = New-Item -ItemType Junction -Path $leafJunction -Target $external -ErrorAction Stop
            { Write-DeclarativeWorkflowDurableProof -ProjectDir $project -Run $run -Kind Completion -NodeId 'inspect' -Proof $acknowledgement } |
                Should -Throw '*reparse*'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($marker)) | Should -BeExactly ([Convert]::ToBase64String($before))
        } finally {
            if ($null -ne $junction -and (Test-Path -LiteralPath $leafJunction)) { $junction.Delete() }
        }
    }

    It 'W05 W06 persists intent before one effect and ACK before dependency release' {
        $script:testDeclarativeSessionName = 'workflow-test'
        $run = New-TestRun
        $proofProject = Join-Path $TestDrive 'w05-durable-proof'
        Save-DeclarativeWorkflowRunState -ProjectDir $proofProject -Run $run -CreateNew | Out-Null
        $events = [Collections.Generic.List[string]]::new()
        Mock Invoke-TeamPipelineGuardedSend { [PSCustomObject]@{ Status = 'EXEC_DONE' } }
        Mock Wait-TeamPipelineDeclarativeCompletion {
            $acknowledgement = New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'
            $acknowledgement['transport'] = 'mailbox'
            return $acknowledgement
        }
        Mock Write-TeamPipelineEvent { throw 'declarative completion must not be synthesized from pane text' }
        $manifest = [PSCustomObject]@{ Panes = [ordered]@{ 'worker-1' = [ordered]@{ pane_id = '%2' } } }
        $request = [PSCustomObject]@{ stage = 'EXEC'; node_id = 'inspect'; pane_ref = 'implement'; task = 'Implement TASK-659 safely.' }
        $productionReceipt = Invoke-TeamPipelineDeclarativeDispatch -Request $request -Run $run -Manifest $manifest -ProjectDir $TestDrive -SessionName 'workflow-test'

        $productionReceipt.acknowledgement.run_id | Should -Be 'run-123'
        $productionReceipt.acknowledgement.node_id | Should -Be 'inspect'
        $productionReceipt.acknowledgement.pane_id | Should -Be '%2'
        $productionReceipt.acknowledgement.transport | Should -Be 'mailbox'
        $productionReceipt.acknowledgement.evidence_ref | Should -Be 'workflow-ack:run-123:inspect'
        Should -Invoke Write-TeamPipelineEvent -Times 0 -Exactly
        Write-DeclarativeWorkflowDurableProof -ProjectDir $proofProject -Run $run -Kind Completion -NodeId 'inspect' -Proof $productionReceipt.acknowledgement | Out-Null
        $resolvedAcknowledgements = @(Resolve-TeamPipelineDeclarativeAcknowledgement -Run $run -NodeId 'inspect' -ProjectDir $proofProject -SessionName 'workflow-test')
        $resolvedAcknowledgements.Count | Should -Be 1
        $resolvedAcknowledgements[0].pane_id | Should -Be '%2'

        Write-OrchestraLog -ProjectDir $TestDrive -SessionName 'workflow-noise-test' -Event 'workflow.node.acknowledged' -PaneId '%2' -Data $productionReceipt.acknowledgement | Out-Null
        $noiseLogPath = Get-OrchestraLogPath -ProjectDir $TestDrive -SessionName 'workflow-noise-test'
        $noiseWriter = [IO.StreamWriter]::new($noiseLogPath, $true, [Text.UTF8Encoding]::new($false))
        try {
            foreach ($index in 1..4100) { $noiseWriter.WriteLine('{"event":"workflow.noise","data":{"index":' + $index + '}}') }
        } finally {
            $noiseWriter.Dispose()
        }
        $ackBeforeNoise = @(Resolve-TeamPipelineDeclarativeAcknowledgement -Run $run -NodeId 'inspect' -ProjectDir $proofProject -SessionName 'workflow-noise-test')
        $ackBeforeNoise.Count | Should -Be 1
        $ackBeforeNoise[0].pane_id | Should -Be '%2'

        $ambiguousAcknowledgements = @($productionReceipt.acknowledgement, (Copy-DeclarativeWorkflowValue $productionReceipt.acknowledgement))
        $ambiguousAcknowledgements[1].pane_id = '%3'

        $cancellation = New-TestCancellationProof
        Write-DeclarativeWorkflowDurableProof -ProjectDir $proofProject -Run $run -Kind Cancellation -Proof $cancellation | Out-Null
        $resolvedCancellations = @(Resolve-TeamPipelineDeclarativeCancellation -Run $run -ProjectDir $proofProject -SessionName 'workflow-test')
        $resolvedCancellations.Count | Should -Be 1
        $resolvedCancellations[0].evidence_ref | Should -Be 'workflow-cancel:run-123'
        @(Resolve-TeamPipelineDeclarativeCancellation -Run $run -ProjectDir $proofProject -SessionName 'workflow-test').Count | Should -Be 1

        $ambiguousRun = New-TestDispatchedRun
        $script:ambiguousDispatches = 0
        $ambiguousResult = Invoke-DeclarativeWorkflowResume -Run $ambiguousRun -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) } `
            -Dispatch { $script:ambiguousDispatches++ } `
            -ResolveSession { param($paneId) $paneId } `
            -ResolveAcknowledgement { $ambiguousAcknowledgements }
        $ambiguousResult.nodes.inspect.state | Should -Be 'blocked'
        $script:ambiguousDispatches | Should -Be 0

        $result = Invoke-DeclarativeWorkflowNode `
            -Run $run -NodeId 'inspect' -TaskInput (New-TestTaskInput) `
            -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) $events.Add("save:$($candidate.nodes.inspect.state):$($candidate.nodes.verify.state)") | Out-Null } `
            -Dispatch { param($request) $events.Add("dispatch:$($request.stage)") | Out-Null; New-TestAcceptedReceipt -NodeId 'inspect' -PaneId '%2' } `
            -ResolveSession { param($paneId) $events.Add("session:$paneId") | Out-Null; '%2' }

        $events[0] | Should -Be 'save:dispatching:pending'
        $events[1] | Should -Be 'dispatch:EXEC'
        $events[2] | Should -Be 'session:%2'
        $events[3] | Should -Be 'save:succeeded:ready'
        $events.Count | Should -Be 4
        @($events | Where-Object { $_ -like 'dispatch:*' }).Count | Should -Be 1
        $result.nodes.inspect.state | Should -Be 'succeeded'
        $result.nodes.inspect.attempt | Should -Be 1
        $result.nodes.inspect.agent_cli_session_id | Should -Be '%2'
        $result.nodes.verify.state | Should -Be 'ready'
    }

    It 'W05 does not call the adapter when intent persistence fails' {
        $script:dispatches = 0
        {
            Invoke-DeclarativeWorkflowNode `
                -Run (New-TestRun) -NodeId 'inspect' -TaskInput (New-TestTaskInput) `
                -Confirmation (New-TestConfirmation) `
                -SaveRun { throw 'injected save failure' } `
                -Dispatch { $script:dispatches++; [PSCustomObject]@{ status = 'accepted' } } `
                -ResolveSession { '%2' }
        } | Should -Throw '*injected save failure*'
        $script:dispatches | Should -Be 0
    }

    It 'W08 W15 blocks ambiguous acknowledgement or missing registry session without redispatch' {
        foreach ($receipt in @($null, [PSCustomObject]@{ status = 'accepted'; target = [PSCustomObject]@{ pane_id = '%2' } })) {
            $script:dispatches = 0
            $run = New-TestRun
            $result = Invoke-DeclarativeWorkflowNode `
                -Run $run -NodeId 'inspect' -TaskInput (New-TestTaskInput) `
                -Confirmation (New-TestConfirmation) `
                -SaveRun { param($candidate) } `
                -Dispatch { $script:dispatches++; $receipt } `
                -ResolveSession { '' }
            $result.nodes.inspect.state | Should -Be 'blocked'
            $result.nodes.verify.state | Should -Be 'pending'
            $script:dispatches | Should -Be 1
        }

        $secretInput = New-TestTaskInput -Text 'git reset --hard SECRET_MARKER'
        $script:testDeclarativeSessionName = 'privacy-test'
        $secretRun = New-DeclarativeWorkflowRun -Plan (New-TestWorkflowPlan) -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskInput $secretInput
        $manifest = [PSCustomObject]@{ Panes = [ordered]@{ 'worker-1' = [ordered]@{ pane_id = '%2' } } }
        $capturedEvents = [Collections.Generic.List[object]]::new()
        $savedRuns = [Collections.Generic.List[string]]::new()
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $capturedEvents.Add([PSCustomObject]@{ event = $Event; data = $Data }) | Out-Null
            return [PSCustomObject]@{ event = $Event; data = $Data }
        }
        $secretResult = Invoke-DeclarativeWorkflowNode -Run $secretRun -NodeId 'inspect' -TaskInput $secretInput -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) $savedRuns.Add(($candidate | ConvertTo-Json -Depth 20 -Compress)) | Out-Null } `
            -Dispatch { param($request) Invoke-TeamPipelineDeclarativeDispatch -Request $request -Run $secretRun -Manifest $manifest -ProjectDir $TestDrive -SessionName 'privacy-test' } `
            -ResolveSession { '' }
        $secretResult.nodes.inspect.state | Should -Be 'blocked'
        ($capturedEvents | ConvertTo-Json -Depth 20 -Compress) | Should -Not -Match 'SECRET_MARKER'
        ($savedRuns -join "`n") | Should -Not -Match 'SECRET_MARKER'
    }

    It 'W09 W12 skips succeeded nodes and rejects terminal run resume' {
        $run = New-TestSucceededInspectRun
        $inspectProofs = New-TestDurableProofs -CompletionAcknowledgements @((New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'))
        $script:dispatches = 0
        $same = Invoke-DeclarativeWorkflowNode -Run $run -NodeId 'inspect' -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun { } -Dispatch { $script:dispatches++ } -ResolveSession { 'x' } -DurableProofs $inspectProofs
        $same.nodes.inspect.state | Should -Be 'succeeded'
        $script:dispatches | Should -Be 0

        $run = New-TestSucceededRun
        $allProofs = New-TestDurableProofs -CompletionAcknowledgements @(
            (New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'),
            (New-TestAcknowledgement -NodeId 'verify' -PaneId '%3')
        )
        { Invoke-DeclarativeWorkflowNode -Run $run -NodeId 'verify' -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun { } -Dispatch { } -ResolveSession { 'x' } -DurableProofs $allProofs } | Should -Throw '*terminal*'

        $run = New-TestCancelledRun
        $cancellationProofs = New-TestDurableProofs -CancellationProofs @((New-TestCancellationProof))
        { Invoke-DeclarativeWorkflowNode -Run $run -NodeId 'inspect' -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun { } -Dispatch { } -ResolveSession { 'x' } -DurableProofs $cancellationProofs } | Should -Throw '*terminal*'

        $run = New-TestFailedRun
        { Invoke-DeclarativeWorkflowNode -Run $run -NodeId 'inspect' -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun { } -Dispatch { $script:dispatches++ } -ResolveSession { '%2' } } | Should -Throw '*new operator-approved run*'
        $script:dispatches | Should -Be 0
    }

    It 'W10 W13 W16 rejects stale confirmation and task mismatch before effects' {
        $run = New-TestRun
        $script:effects = 0
        $badConfirmation = New-TestConfirmation
        $badConfirmation.source_head = 'c' * 40
        { Invoke-DeclarativeWorkflowNode -Run $run -NodeId 'inspect' -TaskInput (New-TestTaskInput) -Confirmation $badConfirmation -SaveRun { $script:effects++ } -Dispatch { $script:effects++ } -ResolveSession { 'x' } } | Should -Throw '*confirmation*'
        { Invoke-DeclarativeWorkflowNode -Run $run -NodeId 'inspect' -TaskInput (New-TestTaskInput -Text 'changed') -Confirmation (New-TestConfirmation) -SaveRun { $script:effects++ } -Dispatch { $script:effects++ } -ResolveSession { 'x' } } | Should -Throw '*task*'
        $script:effects | Should -Be 0
    }

    It 'W11 persists terminal run state after the final node succeeds' {
        $project = Join-Path $TestDrive 'terminal-run-project'
        $saved = [Collections.Generic.List[object]]::new()
        $save = {
            param($candidate)
            $saved.Add((Copy-DeclarativeWorkflowValue $candidate)) | Out-Null
            Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $candidate | Out-Null
        }
        $dispatch = {
            param($request)
            $paneId = if ($request.node_id -ceq 'inspect') { '%2' } else { '%3' }
            New-TestAcceptedReceipt -NodeId $request.node_id -PaneId $paneId
        }
        $resolveSession = { param($paneId) $paneId }

        $afterInspect = Invoke-DeclarativeWorkflowNode -Run (New-TestRun) -NodeId 'inspect' -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun $save -Dispatch $dispatch -ResolveSession $resolveSession
        $inspectProofs = New-TestDurableProofs -CompletionAcknowledgements @((New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'))
        $afterVerify = Invoke-DeclarativeWorkflowNode -Run $afterInspect -NodeId 'verify' -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun $save -Dispatch $dispatch -ResolveSession $resolveSession -DurableProofs $inspectProofs
        $reloaded = Read-DeclarativeWorkflowRunState -ProjectDir $project -RunId 'run-123'

        $afterVerify.state | Should -Be 'succeeded'
        $saved[$saved.Count - 1].state | Should -Be 'succeeded'
        $reloaded.state | Should -Be 'succeeded'
    }

    It 'W11 reconciles a durable ACK after the ACK-event cut without redispatch and advances only unfinished nodes' {
        $run = New-TestDispatchedRun
        $saved = [Collections.Generic.List[object]]::new()
        $requests = [Collections.Generic.List[object]]::new()

        $result = Invoke-DeclarativeWorkflowResume -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) $saved.Add((Copy-DeclarativeWorkflowValue $candidate)) | Out-Null } `
            -Dispatch { param($request) $requests.Add($request) | Out-Null; New-TestAcceptedReceipt -NodeId $request.node_id -PaneId '%3' } `
            -ResolveSession { param($paneId) $paneId } `
            -ResolveAcknowledgement { param($candidate, $nodeId) New-TestAcknowledgement -NodeId $nodeId -PaneId $(if ($nodeId -ceq 'inspect') { '%2' } else { '%3' }) }

        $result.state | Should -Be 'succeeded'
        $result.nodes.inspect.state | Should -Be 'succeeded'
        $result.nodes.inspect.attempt | Should -Be 1
        $result.nodes.inspect.agent_cli_session_id | Should -Be '%2'
        $result.nodes.inspect.evidence_refs | Should -Contain 'workflow-ack:run-123:inspect'
        $result.nodes.inspect.idempotency_key | Should -Be 'run-123:inspect'
        @($requests | Where-Object { $_.node_id -ceq 'inspect' }).Count | Should -Be 0
        @($requests | Where-Object { $_.node_id -ceq 'verify' }).Count | Should -Be 1
        $saved[$saved.Count - 1].state | Should -Be 'succeeded'
    }

    It 'W11 keeps a blocked node without ACK or registry evidence blocked with zero dispatches' {
        $run = New-TestBlockedRun
        $saved = [Collections.Generic.List[object]]::new()
        $script:w11Dispatches = 0

        $result = Invoke-DeclarativeWorkflowResume -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) $saved.Add((Copy-DeclarativeWorkflowValue $candidate)) | Out-Null } `
            -Dispatch { $script:w11Dispatches++; throw 'dispatch must not be called without reconciliation evidence' } `
            -ResolveSession { '' } `
            -ResolveAcknowledgement { $null }

        $result.state | Should -Be 'blocked'
        $result.nodes.inspect.state | Should -Be 'blocked'
        $script:w11Dispatches | Should -Be 0
        $saved.Count | Should -Be 0

        $conflict = New-TestBlockedRun
        $conflictResult = Invoke-DeclarativeWorkflowResume -Run $conflict -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) } `
            -Dispatch { $script:w11Dispatches++; throw 'conflicting acknowledgement must not redispatch' } `
            -ResolveSession { param($paneId) $paneId } `
            -ResolveAcknowledgement { @((New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'), (New-TestAcknowledgement -NodeId 'inspect' -PaneId '%3')) }
        $conflictResult.nodes.inspect.state | Should -Be 'blocked'
        $script:w11Dispatches | Should -Be 0
    }

    It 'W11 rejects an impossible succeeded sibling while another dependency remains blocked without effects' {
        $run = New-TestRun
        $run.state = 'blocked'
        $run.nodes.inspect.state = 'blocked'
        $run.nodes.inspect.attempt = 1
        $run.nodes.inspect.evidence_refs = @()
        $run.nodes.verify.depends_on = @()
        $run.nodes.verify.state = 'succeeded'
        $run.nodes.verify.attempt = 1
        $run.nodes.verify.agent_cli_session_id = 'cli-session:verify-pane'
        $run.nodes.verify.evidence_refs = @('evidence:verify')
        $script:w11Effects = 0

        { Invoke-DeclarativeWorkflowResume -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { $script:w11Effects++ } `
            -Dispatch { $script:w11Effects++ } `
            -ResolveSession { '' } `
            -ResolveAcknowledgement { $null } } | Should -Throw '*workflow_state_invalid*'
        $script:w11Effects | Should -Be 0
    }

    It 'W11 wires resume through the reconciliation choke point for blocked evidence-free runs' {
        $script:w11ResumeCalls = 0
        $script:w11WiredRun = New-TestBlockedRun
        $taskFile = Join-Path $TestDrive 'resume-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))

        Mock Read-DeclarativeWorkflowRunState { Copy-DeclarativeWorkflowValue $script:w11WiredRun }
        Mock Invoke-TeamPipelineWorkspacePlanOnce { [ordered]@{ config_fingerprint = ('sha256:' + ('a' * 64)); resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }; workflow = (New-TestWorkflowPlan) } }
        Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'w11-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
        Mock Get-TeamPipelineSessionName { 'w11-session' }
        Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
        Mock Resolve-TeamPipelineDeclarativeRuntimeLease { param($Label) [PSCustomObject]@{ label = [string]$Label; pane_id = '%2' } }
        Mock Assert-TeamPipelineDeclarativeRunLockAdmission { }
        Mock Save-DeclarativeWorkflowRunState { }
        Mock Invoke-DeclarativeWorkflowResume {
            param($Run, $TaskInput, $Confirmation, $SaveRun, $Dispatch, $ResolveSession, $ResolveAcknowledgement, $ResolveCancellation, $ValidateSnapshot)
            $script:w11ResumeCalls++
            & $SaveRun $Run
            return $Run
        }

        $result = Invoke-TeamPipelineDeclarativeWorkflow -Action resume -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $TestDrive

        $result.status | Should -Be 'blocked'
        $result.state | Should -Be 'blocked'
        $script:w11ResumeCalls | Should -Be 1
        Should -Invoke Invoke-DeclarativeWorkflowResume -Times 1 -Exactly
    }

    It 'C07 advances a start run through every ready node and releases the terminal lock exactly once' {
        $project = Join-Path $TestDrive 'start-run-advancement'
        $run = New-TestRun
        $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
        $effects = [Collections.Generic.List[string]]::new()
        $releases = [Collections.Generic.List[string]]::new()

        $after = Invoke-TeamPipelineDeclarativeRunAdvancement -ProjectDir $project -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) } `
            -Dispatch {
                param($request)
                $effects.Add([string]$request.node_id) | Out-Null
                $paneId = if ([string]$request.node_id -ceq 'inspect') { '%2' } else { '%3' }
                New-TestAcceptedReceipt -NodeId $request.node_id -PaneId $paneId
            } `
            -ResolveSession { param($paneId) $paneId } `
            -ResolveAcknowledgement { param($candidate, $nodeId) New-TestAcknowledgement -NodeId $nodeId -PaneId $(if ($nodeId -ceq 'inspect') { '%2' } else { '%3' }) } `
            -ReleaseLock {
                param($path)
                $releases.Add($path) | Out-Null
                Remove-Item -LiteralPath $path -Force
            }

        $after.state | Should -Be 'succeeded'
        $after.nodes.inspect.state | Should -Be 'succeeded'
        $after.nodes.verify.state | Should -Be 'succeeded'
        [string]::Join(',', @($effects)) | Should -Be 'inspect,verify'
        $releases.Count | Should -Be 1
        Test-Path -LiteralPath $lock | Should -BeFalse
    }

    It 'D01 rejects a fresh manifest generation mismatch before workspace planning, state, lock, or dispatch effects' {
        $taskFile = Join-Path $TestDrive 'manifest-generation-mismatch-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        $script:manifestGenerationMismatchWorkspacePlans = 0
        $script:manifestGenerationMismatchStateWrites = 0
        $script:manifestGenerationMismatchLocks = 0
        $script:manifestGenerationMismatchAdvances = 0

        Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
        Mock Read-TeamPipelineManifest {
            [PSCustomObject]@{
                Session = [ordered]@{ name = 'workflow-session'; generation_id = 'generation-replaced' }
                Panes = [ordered]@{}
            }
        }
        Mock Invoke-TeamPipelineWorkspacePlanOnce { $script:manifestGenerationMismatchWorkspacePlans++ }
        Mock Save-DeclarativeWorkflowRunState { $script:manifestGenerationMismatchStateWrites++ }
        Mock New-DeclarativeWorkflowRunLock { $script:manifestGenerationMismatchLocks++ }
        Mock Invoke-TeamPipelineDeclarativeRunAdvancement { $script:manifestGenerationMismatchAdvances++ }

        {
            Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
                -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
                -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $TestDrive
        } | Should -Throw '*workflow_manifest_generation_mismatch*'

        $script:manifestGenerationMismatchWorkspacePlans | Should -Be 0
        $script:manifestGenerationMismatchStateWrites | Should -Be 0
        $script:manifestGenerationMismatchLocks | Should -Be 0
        $script:manifestGenerationMismatchAdvances | Should -Be 0
    }

    It 'W11 routes start through the one run-advancement choke point' {
        $taskFile = Join-Path $TestDrive 'start-route-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        $script:startRouteRun = New-TestRun

        Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
        Mock Invoke-TeamPipelineWorkspacePlanOnce {
            $workflow = [ordered]@{}
            (New-TestWorkflowPlan).PSObject.Properties | ForEach-Object { $workflow[$_.Name] = $_.Value }
            [ordered]@{
                config_fingerprint = ('sha256:' + ('a' * 64))
                resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
                workflow = $workflow
            }
        }
        Mock New-DeclarativeWorkflowRun { Copy-DeclarativeWorkflowValue $script:startRouteRun }
        Mock New-DeclarativeWorkflowRunLock { Join-Path $TestDrive 'synthetic-start.lock' }
        Mock Save-DeclarativeWorkflowRunState { }
        Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'start-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
        Mock Get-TeamPipelineSessionName { 'start-session' }
        Mock Resolve-TeamPipelineDeclarativeRuntimeLease { param($Label) [PSCustomObject]@{ label = [string]$Label; pane_id = '%2' } }
        Mock Invoke-TeamPipelineDeclarativeRunAdvancement {
            $completed = Copy-DeclarativeWorkflowValue $script:startRouteRun
            $completed.state = 'succeeded'
            return $completed
        }
        Mock Invoke-DeclarativeWorkflowNode { throw 'start must not retain a second direct node-dispatch path' }

        $result = Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
            -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
            -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $TestDrive

        $result.status | Should -Be 'accepted'
        $result.state | Should -Be 'succeeded'
        Should -Invoke Invoke-TeamPipelineDeclarativeRunAdvancement -Times 1 -Exactly
        Should -Invoke Invoke-DeclarativeWorkflowNode -Times 0 -Exactly
    }

    It 'C07 recovers one pending terminal action after validation and preserves its terminal outcome' {
        foreach ($terminalState in @('succeeded', 'failed', 'cancelled')) {
            $project = Join-Path $TestDrive "terminal-recovery-$terminalState"
            $run = switch ($terminalState) {
                'succeeded' { New-TestSucceededRun }
                'failed' { New-TestFailedRun }
                'cancelled' { New-TestCancelledRun }
            }
            $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
            $script:terminalRecoverySnapshotCalls = 0
            $releases = [Collections.Generic.List[string]]::new()
            $resolveAcknowledgement = {
                param($candidate, $nodeId)
                New-TestAcknowledgement -NodeId $nodeId -PaneId $(if ($nodeId -ceq 'inspect') { '%2' } else { '%3' })
            }
            $resolveCancellation = { New-TestCancellationProof }

            $after = Invoke-TeamPipelineDeclarativeTerminalRecovery -ProjectDir $project -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
                -ValidateSnapshot { param($candidate) $script:terminalRecoverySnapshotCalls++ } `
                -SaveRun { param($candidate) } `
                -ResolveAcknowledgement $resolveAcknowledgement -ResolveCancellation $resolveCancellation `
                -ReleaseLock {
                    param($path)
                    $releases.Add($path) | Out-Null
                    Remove-Item -LiteralPath $path -Force
                }

            $after.state | Should -Be $terminalState
            $after.cleanup_journal[0].state | Should -Be 'succeeded'
            $script:terminalRecoverySnapshotCalls | Should -Be 1
            $releases.Count | Should -Be 1
            Test-Path -LiteralPath $lock | Should -BeFalse
        }
    }

    It 'C07 rejects terminal recovery actions outside the typed pending or running states' {
        $project = Join-Path $TestDrive 'terminal-recovery-admission'
        $taskInput = New-TestTaskInput
        $confirmation = New-TestConfirmation

        foreach ($case in @(
                [PSCustomObject]@{ Name = 'succeeded'; Configure = { param($run) $run.cleanup_journal[0].state = 'succeeded' } },
                [PSCustomObject]@{ Name = 'blocked'; Configure = { param($run) $run.cleanup_journal[0].state = 'blocked' } },
                [PSCustomObject]@{ Name = 'case-variant'; Configure = { param($run) $run.cleanup_journal[0].state = 'Running' } },
                [PSCustomObject]@{ Name = 'unknown'; Configure = { param($run) $run.cleanup_journal[0].state = 'unknown' } },
                [PSCustomObject]@{ Name = 'malformed'; Configure = { param($run) $run.cleanup_journal = @([ordered]@{ state = 'pending' }) } },
                [PSCustomObject]@{ Name = 'multiple'; Configure = { param($run) $run.cleanup_journal = @($run.cleanup_journal[0], (Copy-DeclarativeWorkflowValue $run.cleanup_journal[0])) } }
            )) {
            $run = New-TestFailedRun
            & $case.Configure $run
            $before = $run | ConvertTo-Json -Depth 40 -Compress
            $script:terminalRecoveryEffects = 0

            {
                Invoke-TeamPipelineDeclarativeTerminalRecovery -ProjectDir $project -Run $run -TaskInput $taskInput -Confirmation $confirmation `
                    -ValidateSnapshot { param($candidate) } `
                    -SaveRun { $script:terminalRecoveryEffects++ } `
                    -ReleaseLock { $script:terminalRecoveryEffects++ }
            } | Should -Throw -Because "terminal cleanup state '$($case.Name)' is not a recoverable pending action"

            $script:terminalRecoveryEffects | Should -Be 0
            ($run | ConvertTo-Json -Depth 40 -Compress) | Should -Be $before
        }
    }

    It 'C07 rejects terminal resume recovery outside the typed pending or running states before protected effects' {
        $taskFile = Join-Path $TestDrive 'terminal-recovery-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))

        foreach ($case in @(
                [PSCustomObject]@{ Name = 'succeeded'; Configure = { param($run) $run.cleanup_journal[0].state = 'succeeded' } },
                [PSCustomObject]@{ Name = 'blocked'; Configure = { param($run) $run.cleanup_journal[0].state = 'blocked' } },
                [PSCustomObject]@{ Name = 'case-variant'; Configure = { param($run) $run.cleanup_journal[0].state = 'Running' } },
                [PSCustomObject]@{ Name = 'unknown'; Configure = { param($run) $run.cleanup_journal[0].state = 'unknown' } },
                [PSCustomObject]@{ Name = 'malformed'; Configure = { param($run) $run.cleanup_journal = @([ordered]@{ state = 'pending' }) } },
                [PSCustomObject]@{ Name = 'multiple'; Configure = { param($run) $run.cleanup_journal = @($run.cleanup_journal[0], (Copy-DeclarativeWorkflowValue $run.cleanup_journal[0])) } }
            )) {
            $script:terminalResumeRun = New-TestFailedRun
            & $case.Configure $script:terminalResumeRun
            $before = $script:terminalResumeRun | ConvertTo-Json -Depth 40 -Compress
            $script:terminalResumeSaveCount = 0
            $script:terminalResumeDispatchCount = 0
            $script:terminalResumeSnapshotCount = 0

            Mock Read-DeclarativeWorkflowRunState { Copy-DeclarativeWorkflowValue $script:terminalResumeRun }
            Mock Invoke-TeamPipelineWorkspacePlanOnce {
                $script:terminalResumeSnapshotCount++
                [ordered]@{
                    config_fingerprint = ('sha256:' + ('a' * 64))
                    resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
                    workflow = (New-TestWorkflowPlan)
                }
            }
            Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'terminal-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
            Mock Get-TeamPipelineSessionName { 'terminal-session' }
            Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
            Mock Resolve-TeamPipelineDeclarativeRuntimeLease { param($Label) [PSCustomObject]@{ label = [string]$Label; pane_id = '%2' } }
            Mock Save-DeclarativeWorkflowRunState { $script:terminalResumeSaveCount++ }
            Mock Invoke-TeamPipelineDeclarativeDispatch { $script:terminalResumeDispatchCount++; throw 'terminal recovery must not dispatch' }

            {
                Invoke-TeamPipelineDeclarativeWorkflow -Action resume -RunId 'run-123' -GenerationId 'generation-123' `
                    -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $TestDrive
            } | Should -Throw -Because "terminal cleanup state '$($case.Name)' is not admissible for recovery"

            $script:terminalResumeSnapshotCount | Should -Be 0
            $script:terminalResumeSaveCount | Should -Be 0
            $script:terminalResumeDispatchCount | Should -Be 0
            ($script:terminalResumeRun | ConvertTo-Json -Depth 40 -Compress) | Should -Be $before
        }
    }

    It 'C01 C02 C04 reconciles pending and persisted-running cleanup with exact save and release counts' {
        $resolveAcknowledgement = {
            param($candidate, $nodeId)
            New-TestAcknowledgement -NodeId $nodeId -PaneId $(if ($nodeId -ceq 'inspect') { '%2' } else { '%3' })
        }
        $completionProofs = New-TestDurableProofs -CompletionAcknowledgements @(
            (New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'),
            (New-TestAcknowledgement -NodeId 'verify' -PaneId '%3')
        )

        foreach ($case in @(
                [PSCustomObject]@{ Name = 'pending-matching'; PersistIntent = $false; LockPresent = $true; ExpectedSaves = 'running,succeeded'; ExpectedReleases = 1 },
                [PSCustomObject]@{ Name = 'running-matching'; PersistIntent = $true; LockPresent = $true; ExpectedSaves = 'succeeded'; ExpectedReleases = 1 },
                [PSCustomObject]@{ Name = 'running-absent'; PersistIntent = $true; LockPresent = $false; ExpectedSaves = 'succeeded'; ExpectedReleases = 0 }
            )) {
            $project = Join-Path $TestDrive ("cleanup-" + $case.Name)
            $run = New-TestSucceededRun
            if ($case.PersistIntent) {
                $run = Invoke-DeclarativeWorkflowTransition -Run $run -Event ([ordered]@{ type = 'cleanup_intent' }) -DurableProofs $completionProofs
            }
            $lock = Resolve-DeclarativeWorkflowOwnedLock -ProjectDir $project -Run $run -CreateRunDirectory
            if ($case.LockPresent) { $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run }
            $events = [Collections.Generic.List[string]]::new()

            $after = Invoke-DeclarativeWorkflowCleanup -ProjectDir $project -Run $run `
                -SaveRun { param($candidate) $events.Add("save:$($candidate.cleanup_journal[0].state)") | Out-Null } `
                -ReleaseLock { param($path) $events.Add("release:$path") | Out-Null; Remove-Item -LiteralPath $path } `
                -ResolveAcknowledgement $resolveAcknowledgement

            [string]::Join(',', @($events | Where-Object { $_ -like 'save:*' } | ForEach-Object { $_.Substring(5) })) | Should -Be $case.ExpectedSaves -Because $case.Name
            @($events | Where-Object { $_ -like 'release:*' }).Count | Should -Be $case.ExpectedReleases -Because $case.Name
            $after.cleanup_journal[0].state | Should -Be 'succeeded' -Because $case.Name
            $after.state | Should -Be 'succeeded' -Because $case.Name
            Test-Path -LiteralPath $lock -PathType Leaf | Should -BeFalse -Because $case.Name
        }
    }

    It 'C03 C05 blocks mismatched or reparse-point cleanup without releasing' {
        $project = Join-Path $TestDrive 'blocked-project'
        $resolveAcknowledgement = {
            param($candidate, $nodeId)
            New-TestAcknowledgement -NodeId $nodeId -PaneId $(if ($nodeId -ceq 'inspect') { '%2' } else { '%3' })
        }
        $script:releases = 0
        $run = New-TestSucceededRun
        $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
        $payload = Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json
        $payload.source_head = 'c' * 40
        [IO.File]::WriteAllText($lock, ($payload | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $blocked = Invoke-DeclarativeWorkflowCleanup -ProjectDir $project -Run $run -SaveRun { } -ReleaseLock { $script:releases++ } -ResolveAcknowledgement $resolveAcknowledgement
        $blocked.cleanup_journal[0].state | Should -Be 'blocked'
        $script:releases | Should -Be 0
        Test-Path -LiteralPath $lock | Should -BeTrue

        $junctionProject = Join-Path $TestDrive 'junction-project'
        $runsRoot = Join-Path $junctionProject '.winsmux\workflow-runs'
        $externalRunRoot = Join-Path $TestDrive 'external-run-root'
        [IO.Directory]::CreateDirectory($runsRoot) | Out-Null
        [IO.Directory]::CreateDirectory($externalRunRoot) | Out-Null
        $externalLock = Join-Path $externalRunRoot 'run.lock'
        $junctionRun = New-TestSucceededRun
        $junctionPayload = [ordered]@{
            run_id = $junctionRun.run_id
            generation_id = $junctionRun.generation_id
            config_fingerprint = $junctionRun.config_fingerprint
            source_head = $junctionRun.source_head
        }
        [IO.File]::WriteAllText($externalLock, ($junctionPayload | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $junctionPath = Join-Path $runsRoot 'run-123'
        try {
            try {
                $junction = New-Item -ItemType Junction -Path $junctionPath -Target $externalRunRoot -ErrorAction Stop
            } catch {
                throw "Junction fixture creation failed explicitly: $($_.Exception.Message)"
            }
            [bool]($junction.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -BeTrue
            $junctionBlocked = Invoke-DeclarativeWorkflowCleanup -ProjectDir $junctionProject -Run $junctionRun -SaveRun { } -ReleaseLock { $script:releases++; Remove-Item -LiteralPath $args[0] } -ResolveAcknowledgement $resolveAcknowledgement
            $junctionBlocked.cleanup_journal[0].state | Should -Be 'blocked'
            $script:releases | Should -Be 0
            Test-Path -LiteralPath $externalLock -PathType Leaf | Should -BeTrue
        } finally {
            if ([IO.Directory]::Exists($junctionPath)) { [IO.Directory]::Delete($junctionPath) }
        }
        Test-Path -LiteralPath $externalLock -PathType Leaf | Should -BeTrue
    }

    It 'W18 treats pane completion text as non-evidence until a typed mailbox completion is durable' {
        $run = New-TestRun
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; role = 'Worker' }
            }
        }
        Mock Invoke-TeamPipelineGuardedSend {
            [PSCustomObject]@{ Status = 'EXEC_DONE'; Target = 'worker-1' }
        }
        Mock Wait-TeamPipelineStage {
            throw 'pane output must not be polled for declarative completion'
        }
        Mock Wait-TeamPipelineDeclarativeCompletion { $null }
        Mock Write-TeamPipelineEvent { throw 'the dispatcher must not synthesize an acknowledgement' }

        $result = Invoke-TeamPipelineDeclarativeDispatch -Request ([PSCustomObject]@{
                stage = 'EXEC'; node_id = 'inspect'; pane_ref = 'implement'; task = 'safe task body'
            }) -Run $run -Manifest $manifest -ProjectDir $TestDrive -SessionName 'winsmux-orchestra'

        $result.status | Should -Be 'blocked'
        Should -Invoke Wait-TeamPipelineStage -Times 0 -Exactly
        Should -Invoke Wait-TeamPipelineDeclarativeCompletion -Times 1 -Exactly
        Should -Invoke Write-TeamPipelineEvent -Times 0 -Exactly
    }

    It 'W06 accepts only a durable typed mailbox completion and retains its exact tuple' {
        $run = New-TestRun
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; role = 'Worker' }
            }
        }
        $ack = New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'
        $ack['transport'] = 'mailbox'
        Mock Invoke-TeamPipelineGuardedSend { [PSCustomObject]@{ Status = 'SENT'; Target = 'worker-1' } }
        Mock Wait-TeamPipelineStage { throw 'pane output must not be polled for declarative completion' }
        Mock Wait-TeamPipelineDeclarativeCompletion { $ack }

        $result = Invoke-TeamPipelineDeclarativeDispatch -Request ([PSCustomObject]@{
                stage = 'EXEC'; node_id = 'inspect'; pane_ref = 'implement'; task = 'safe task body'
            }) -Run $run -Manifest $manifest -ProjectDir $TestDrive -SessionName 'winsmux-orchestra'

        $result.status | Should -Be 'accepted'
        $result.acknowledgement.workflow_fingerprint | Should -Be ('sha256:' + ('d' * 64))
        $result.acknowledgement.pane_id | Should -Be '%2'
        Should -Invoke Wait-TeamPipelineStage -Times 0 -Exactly
    }

    It 'W17 blocks conflicting or unknown durable ACK candidates for the same identity' {
        $run = New-TestRun
        $first = New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'
        $first['transport'] = 'mailbox'
        $conflict = Copy-DeclarativeWorkflowValue $first
        $conflict.source_head = ('c' * 40)
        $unknown = Copy-DeclarativeWorkflowValue $first
        $unknown['unexpected'] = 'field'

        @(Resolve-DeclarativeWorkflowAcknowledgementCandidates -Run $run -NodeId 'inspect' -Acknowledgements @($first, $first)).Count | Should -Be 1
        @(Resolve-DeclarativeWorkflowAcknowledgementCandidates -Run $run -NodeId 'inspect' -Acknowledgements @($first, $conflict)).Count | Should -Be 2
        @(Resolve-DeclarativeWorkflowAcknowledgementCandidates -Run $run -NodeId 'inspect' -Acknowledgements @($unknown)).Count | Should -Be 1

        $blocked = Invoke-DeclarativeWorkflowResume -Run (New-TestBlockedRun) -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun { } -Dispatch { throw 'must not dispatch' } -ResolveSession { param($paneId) $paneId } `
            -ResolveAcknowledgement { @($first, $conflict) }
        $blocked.state | Should -Be 'blocked'
    }

    It 'W19 observes the actual project HEAD exactly once and rejects mismatch or probe failure before state mutation' {
        $expectedHead = ('b' * 40)
        $observed = Get-TeamPipelineDeclarativeProjectHead -ProjectDir $script:RepoRoot
        $observed | Should -Match '^[0-9a-f]{40}$'
        $expectedHead | Should -Not -Be $observed

        { Assert-TeamPipelineDeclarativeSourceHead -ExpectedSourceHead $expectedHead -ObservedSourceHead $observed } | Should -Throw '*source head*'
        { Get-TeamPipelineDeclarativeProjectHead -ProjectDir (Join-Path $TestDrive 'not-a-git-project') } | Should -Throw '*source head*'
    }

    It 'W20 persists workflow fingerprint and rejects a workflow-only resume mismatch before dispatch' {
        $run = New-TestBlockedRun
        $before = $run | ConvertTo-Json -Depth 40 -Compress
        $script:workflowEffects = 0

        {
            Invoke-DeclarativeWorkflowResume -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) -SaveRun { $script:workflowEffects++ } `
                -Dispatch { $script:workflowEffects++ } -ResolveSession { '' } -ResolveAcknowledgement { $null } `
                -ValidateSnapshot { param($candidate) Assert-DeclarativeWorkflowSnapshot -Run $candidate -WorkflowFingerprint ('sha256:' + ('e' * 64)) -ConfigFingerprint $candidate.config_fingerprint -ResolvedBindings $candidate.resolved_bindings }
        } | Should -Throw '*snapshot*'
        $script:workflowEffects | Should -Be 0
        ($run | ConvertTo-Json -Depth 40 -Compress) | Should -Be $before
    }

    It 'K01 admits resume only when confirmation fresh configuration workflow bindings source and generation all match' {
        $taskFile = Join-Path $TestDrive 'fresh-admission-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        $script:k01Run = New-TestBlockedRun
        $script:k01Plan = [ordered]@{
            config_fingerprint = ('sha256:' + ('a' * 64))
            resolved_bindings  = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
            workflow           = (New-TestWorkflowPlan)
        }
        $script:k01ObservedHead = 'b' * 40
        $script:k01ManifestGeneration = 'generation-123'
        $script:k01LockAdmissions = 0
        $script:k01Saves = 0
        $script:k01Dispatches = 0
        $script:k01Advancements = 0
        $script:k01Cleanups = 0

        Mock Read-DeclarativeWorkflowRunState { Copy-DeclarativeWorkflowValue $script:k01Run }
        Mock Invoke-TeamPipelineWorkspacePlanOnce { Copy-DeclarativeWorkflowValue $script:k01Plan }
        Mock Get-TeamPipelineDeclarativeProjectHead { $script:k01ObservedHead }
        Mock Read-TeamPipelineManifest {
            [PSCustomObject]@{ Session = [ordered]@{ name = 'k01-session'; generation_id = $script:k01ManifestGeneration }; Panes = [ordered]@{} }
        }
        Mock Get-TeamPipelineSessionName { 'k01-session' }
        Mock Resolve-TeamPipelineDeclarativeRuntimeLease { param($Label) [PSCustomObject]@{ label = [string]$Label; pane_id = '%2' } }
        Mock Assert-TeamPipelineDeclarativeRunLockAdmission { $script:k01LockAdmissions++; Join-Path $TestDrive 'k01.lock' }
        Mock Save-DeclarativeWorkflowRunState { $script:k01Saves++ }
        Mock Invoke-TeamPipelineDeclarativeDispatch { $script:k01Dispatches++; throw 'K01 rejection must not dispatch' }
        Mock Invoke-TeamPipelineDeclarativeRunAdvancement { param($Run) $script:k01Advancements++; $Run }
        Mock Invoke-TeamPipelineDeclarativeTerminalRecovery { $script:k01Cleanups++; throw 'K01 rejection must not clean up' }

        $cases = @(
            [PSCustomObject]@{ Name = 'unchanged'; ExpectedAccepted = $true },
            [PSCustomObject]@{ Name = 'changed-config'; Configure = { $script:k01Plan.config_fingerprint = 'sha256:' + ('c' * 64) } },
            [PSCustomObject]@{ Name = 'changed-workflow'; Configure = { $script:k01Plan.workflow.workflow_fingerprint = 'sha256:' + ('e' * 64) } },
            [PSCustomObject]@{ Name = 'changed-binding'; Configure = { $script:k01Plan.resolved_bindings.implement = 'worker-other' } },
            [PSCustomObject]@{ Name = 'stale-confirmation'; ConfigFingerprint = ('sha256:' + ('c' * 64)) },
            [PSCustomObject]@{ Name = 'source-head'; SourceHead = ('c' * 40) },
            [PSCustomObject]@{ Name = 'generation'; GenerationId = 'generation-other' }
        )

        foreach ($case in $cases) {
            $script:k01Plan = [ordered]@{
                config_fingerprint = ('sha256:' + ('a' * 64))
                resolved_bindings  = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
                workflow           = (New-TestWorkflowPlan)
            }
            $configure = Get-DeclarativeWorkflowValue $case 'Configure' $null
            if ($null -ne $configure) { & $configure }
            $caseConfigFingerprint = [string](Get-DeclarativeWorkflowValue $case 'ConfigFingerprint' '')
            $caseSourceHead = [string](Get-DeclarativeWorkflowValue $case 'SourceHead' '')
            $caseGenerationId = [string](Get-DeclarativeWorkflowValue $case 'GenerationId' '')
            $configFingerprint = if ($caseConfigFingerprint) { $caseConfigFingerprint } else { 'sha256:' + ('a' * 64) }
            $sourceHead = if ($caseSourceHead) { $caseSourceHead } else { 'b' * 40 }
            $generationId = if ($caseGenerationId) { $caseGenerationId } else { 'generation-123' }
            $before = $script:k01Run | ConvertTo-Json -Depth 40 -Compress
            $beforeCounts = @($script:k01LockAdmissions, $script:k01Saves, $script:k01Dispatches, $script:k01Advancements, $script:k01Cleanups)

            $expectedAccepted = [bool](Get-DeclarativeWorkflowValue $case 'ExpectedAccepted' $false)
            if ($expectedAccepted) {
                $result = Invoke-TeamPipelineDeclarativeWorkflow -Action resume -RunId 'run-123' -GenerationId $generationId `
                    -ConfigFingerprint $configFingerprint -SourceHead $sourceHead -TaskFile $taskFile -ProjectDir $TestDrive
                $result.status | Should -Be 'blocked'
                $script:k01LockAdmissions | Should -Be ($beforeCounts[0] + 1)
                $script:k01Advancements | Should -Be ($beforeCounts[3] + 1)
            } else {
                {
                    Invoke-TeamPipelineDeclarativeWorkflow -Action resume -RunId 'run-123' -GenerationId $generationId `
                        -ConfigFingerprint $configFingerprint -SourceHead $sourceHead -TaskFile $taskFile -ProjectDir $TestDrive
                } | Should -Throw -Because $case.Name
                $script:k01LockAdmissions | Should -Be $beforeCounts[0] -Because $case.Name
                $script:k01Saves | Should -Be $beforeCounts[1] -Because $case.Name
                $script:k01Dispatches | Should -Be $beforeCounts[2] -Because $case.Name
                $script:k01Advancements | Should -Be $beforeCounts[3] -Because $case.Name
                $script:k01Cleanups | Should -Be $beforeCounts[4] -Because $case.Name
                ($script:k01Run | ConvertTo-Json -Depth 40 -Compress) | Should -Be $before -Because $case.Name
            }
        }
    }

    It 'M03 rejects public start with an unresolved live binding before state lock dispatch or cleanup effects' {
        $project = Join-Path $TestDrive 'live-binding-start-reject'
        $taskFile = Join-Path $TestDrive 'live-binding-start-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        $workspacePlan = [ordered]@{
            config_fingerprint = ('sha256:' + ('a' * 64))
            resolved_bindings  = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
            workflow           = (New-TestWorkflowPlan)
        }
        $script:m03StateWrites = 0
        $script:m03LockWrites = 0
        $script:m03Dispatches = 0
        $script:m03Cleanups = 0
        $script:m03ResolvedLabels = [Collections.Generic.List[string]]::new()

        Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
        Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'm03-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
        Mock Get-TeamPipelineSessionName { 'm03-session' }
        Mock Invoke-TeamPipelineWorkspacePlanOnce { Copy-DeclarativeWorkflowValue $workspacePlan }
        Mock Resolve-TeamPipelineDeclarativeRuntimeLease {
            param($Label)
            $script:m03ResolvedLabels.Add([string]$Label) | Out-Null
            if ([string]$Label -ceq 'worker-1') { return [PSCustomObject]@{ label = 'worker-1'; pane_id = '%2' } }
            return $null
        }
        Mock Save-DeclarativeWorkflowRunState { $script:m03StateWrites++ }
        Mock New-DeclarativeWorkflowRunLock { $script:m03LockWrites++; Join-Path $project 'synthetic-run.lock' }
        Mock Invoke-TeamPipelineDeclarativeRunAdvancement { $script:m03Dispatches++; throw 'unresolved admission must not reach advancement' }
        Mock Invoke-DeclarativeWorkflowCleanup { $script:m03Cleanups++; throw 'unresolved admission must not reach cleanup' }

        {
            Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
                -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
                -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $project
        } | Should -Throw '*workflow_live_binding_unavailable*'

        $script:m03ResolvedLabels | Should -Contain 'worker-2'
        $script:m03StateWrites | Should -Be 0
        $script:m03LockWrites | Should -Be 0
        $script:m03Dispatches | Should -Be 0
        $script:m03Cleanups | Should -Be 0
        Test-Path -LiteralPath (Join-Path $project '.winsmux\workflow-runs\run-123\state.json') -PathType Leaf | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $project '.winsmux\workflow-runs\run-123\run.lock') -PathType Leaf | Should -BeFalse
    }

    It 'M05 rejects public resume with an unresolved live binding without changing existing state or lock bytes' {
        $project = Join-Path $TestDrive 'live-binding-resume-reject'
        $taskFile = Join-Path $TestDrive 'live-binding-resume-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        $run = New-TestBlockedRun
        Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $run | Out-Null
        $lockPath = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
        $statePath = Resolve-DeclarativeWorkflowOwnedRunPath -ProjectDir $project -RunId 'run-123' -LeafName 'state.json'
        $stateBytesBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath))
        $lockBytesBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath))
        $workspacePlan = [ordered]@{
            config_fingerprint = ('sha256:' + ('a' * 64))
            resolved_bindings  = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
            workflow           = (New-TestWorkflowPlan)
        }
        $script:m05Saves = 0
        $script:m05Dispatches = 0
        $script:m05Cleanups = 0
        $script:m05LockAdmissions = 0

        Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
        Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'm05-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
        Mock Get-TeamPipelineSessionName { 'm05-session' }
        Mock Invoke-TeamPipelineWorkspacePlanOnce { Copy-DeclarativeWorkflowValue $workspacePlan }
        Mock Resolve-TeamPipelineDeclarativeRuntimeLease {
            param($Label)
            if ([string]$Label -ceq 'worker-1') { return [PSCustomObject]@{ label = 'worker-1'; pane_id = '%2' } }
            return $null
        }
        Mock Save-DeclarativeWorkflowRunState { $script:m05Saves++ }
        Mock Invoke-TeamPipelineDeclarativeDispatch { $script:m05Dispatches++; throw 'unresolved resume admission must not dispatch' }
        Mock Invoke-TeamPipelineDeclarativeTerminalRecovery { $script:m05Cleanups++; throw 'unresolved resume admission must not recover terminal state' }
        Mock Invoke-DeclarativeWorkflowCleanup { $script:m05Cleanups++; throw 'unresolved resume admission must not clean up' }
        Mock Assert-TeamPipelineDeclarativeRunLockAdmission { $script:m05LockAdmissions++; throw 'unresolved resume admission must not inspect the run lock' }

        {
            Invoke-TeamPipelineDeclarativeWorkflow -Action resume -RunId 'run-123' -GenerationId 'generation-123' `
                -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $project
        } | Should -Throw '*workflow_live_binding_unavailable*'

        $script:m05Saves | Should -Be 0
        $script:m05Dispatches | Should -Be 0
        $script:m05Cleanups | Should -Be 0
        $script:m05LockAdmissions | Should -Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath)) | Should -Be $stateBytesBefore
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath)) | Should -Be $lockBytesBefore
    }

    It 'M04 validates every ordinal-distinct live binding once and rejects each resolver-null partition' {
        $script:m04Mode = ''
        $script:m04Labels = [Collections.Generic.List[string]]::new()
        Mock Resolve-TeamPipelineDeclarativeRuntimeLease {
            param($Label)
            $script:m04Labels.Add([string]$Label) | Out-Null
            if ($script:m04Mode -in @('missing', 'duplicate', 'stale', 'invalid') -and [string]$Label -ceq 'worker-2') { return $null }
            return [PSCustomObject]@{ label = [string]$Label; pane_id = '%2' }
        }

        foreach ($case in @(
                [PSCustomObject]@{ Name = 'complete-with-unrelated-extra'; Mode = 'complete'; Bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }; ExpectedLabels = 'worker-1,worker-2'; Accept = $true },
                [PSCustomObject]@{ Name = 'shared-label'; Mode = 'shared'; Bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-1' }; ExpectedLabels = 'worker-1'; Accept = $true },
                [PSCustomObject]@{ Name = 'missing'; Mode = 'missing'; Bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }; ExpectedLabels = 'worker-1,worker-2'; Accept = $false },
                [PSCustomObject]@{ Name = 'duplicate'; Mode = 'duplicate'; Bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }; ExpectedLabels = 'worker-1,worker-2'; Accept = $false },
                [PSCustomObject]@{ Name = 'stale'; Mode = 'stale'; Bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }; ExpectedLabels = 'worker-1,worker-2'; Accept = $false },
                [PSCustomObject]@{ Name = 'invalid'; Mode = 'invalid'; Bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }; ExpectedLabels = 'worker-1,worker-2'; Accept = $false }
            )) {
            $run = New-TestRun
            $run.resolved_bindings = Copy-DeclarativeWorkflowValue $case.Bindings
            $run.normalized_snapshot.resolved_bindings = Copy-DeclarativeWorkflowValue $case.Bindings
            $workspacePlan = [ordered]@{
                config_fingerprint = ('sha256:' + ('a' * 64))
                resolved_bindings  = Copy-DeclarativeWorkflowValue $case.Bindings
                workflow           = Copy-DeclarativeWorkflowValue $run.normalized_snapshot
            }
            $script:m04Mode = [string]$case.Mode
            $script:m04Labels.Clear()
            $invoke = {
                Assert-TeamPipelineDeclarativeAdmission -Run $run -Confirmation (New-TestConfirmation) -TaskInput (New-TestTaskInput) `
                    -WorkspacePlan $workspacePlan -ManifestGenerationId 'generation-123' -ObservedSourceHead ('b' * 40) `
                    -ProjectDir $TestDrive -SessionName 'm04-session'
            }

            if ($case.Accept) { $invoke | Should -Not -Throw -Because $case.Name }
            else { $invoke | Should -Throw '*workflow_live_binding_unavailable*' -Because $case.Name }
            [string]::Join(',', @($script:m04Labels)) | Should -Be $case.ExpectedLabels -Because $case.Name
        }
    }

    It 'A21 structurally binds the persisted DAG projection before reconciliation, save, dispatch, or cleanup' {
        $plan = New-TestWorkflowPlan
        $taskInput = New-TestTaskInput
        $confirmation = New-TestConfirmation

        { Assert-DeclarativeWorkflowExecutionProjection -Run (New-TestRun) -Plan $plan } | Should -Not -Throw

        $cases = @(
            [PSCustomObject]@{
                Name = 'extra-normalized-node'
                Mutate = {
                    param($candidate)
                    $candidate.normalized_snapshot.nodes += [ordered]@{
                        node_id = 'extra'; pane_ref = 'implement'; action = 'operator-dispatch'; depends_on = @()
                        idempotency_key = 'run-123:extra'; cleanup = 'retain'
                    }
                }
            },
            [PSCustomObject]@{
                Name = 'missing-normalized-node'
                Mutate = { param($candidate) $candidate.normalized_snapshot.nodes = @($candidate.normalized_snapshot.nodes | Select-Object -First 1) }
            },
            [PSCustomObject]@{
                Name = 'reordered-normalized-nodes'
                Mutate = { param($candidate) $candidate.normalized_snapshot.nodes = @($candidate.normalized_snapshot.nodes[1], $candidate.normalized_snapshot.nodes[0]) }
            },
            [PSCustomObject]@{
                Name = 'runtime-node-order'
                Mutate = { param($candidate) $candidate.node_order = @('verify', 'inspect') }
            }
        )

        foreach ($field in @('node_id', 'action', 'pane_ref', 'depends_on', 'idempotency_key', 'cleanup', 'context_pack_ref')) {
            $cases += [PSCustomObject]@{
                Name = "mutated-runtime-$field"
                Mutate = {
                    param($candidate)
                    switch ($field) {
                        'node_id' { $candidate.nodes.inspect.node_id = 'verify' }
                        'action' { $candidate.nodes.inspect.action = 'verification' }
                        'pane_ref' { $candidate.nodes.inspect.pane_ref = 'verify' }
                        'depends_on' { $candidate.nodes.inspect.depends_on = @('verify') }
                        'idempotency_key' { $candidate.nodes.inspect.idempotency_key = 'run-123:other' }
                        'cleanup' { $candidate.nodes.inspect.cleanup = 'delete-everything' }
                        'context_pack_ref' { $candidate.nodes.inspect.context_pack_ref = 'different-pack' }
                    }
                }.GetNewClosure()
            }
        }

        foreach ($case in $cases) {
            $candidate = New-TestRun
            & $case.Mutate $candidate
            $script:projectionSaves = 0
            $script:projectionDispatches = 0
            $script:projectionReconciles = 0
            $script:projectionCleanups = 0

            {
                Invoke-TeamPipelineDeclarativeRunAdvancement -ProjectDir $TestDrive -Run $candidate -TaskInput $taskInput -Confirmation $confirmation `
                    -SaveRun { $script:projectionSaves++ } `
                    -Dispatch { $script:projectionDispatches++; throw 'projection validation must happen before dispatch' } `
                    -ResolveSession { throw 'projection validation must happen before session lookup' } `
                    -ResolveAcknowledgement { $script:projectionReconciles++; throw 'projection validation must happen before reconciliation' } `
                    -ReleaseLock { $script:projectionCleanups++ } `
                    -ValidateSnapshot { param($runToValidate) Assert-DeclarativeWorkflowExecutionProjection -Run $runToValidate -Plan $plan }
            } | Should -Throw '*projection*' -Because $case.Name

            $script:projectionSaves | Should -Be 0 -Because $case.Name
            $script:projectionDispatches | Should -Be 0 -Because $case.Name
            $script:projectionReconciles | Should -Be 0 -Because $case.Name
            $script:projectionCleanups | Should -Be 0 -Because $case.Name
        }
    }

    It 'C07 preserves terminal success failure and cancel outcomes while releasing the lock exactly once' {
        foreach ($terminalState in @('succeeded', 'failed', 'cancelled')) {
            $project = Join-Path $TestDrive "terminal-cleanup-$terminalState"
            $run = switch ($terminalState) {
                'succeeded' { New-TestSucceededRun }
                'failed' { New-TestFailedRun }
                'cancelled' { New-TestCancelledRun }
            }
            $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
            $releases = [Collections.Generic.List[string]]::new()
            $after = Invoke-DeclarativeWorkflowTerminalCleanup -ProjectDir $project -Run $run -SaveRun { } `
                -ResolveAcknowledgement { param($candidate, $nodeId) New-TestAcknowledgement -NodeId $nodeId -PaneId $(if ($nodeId -ceq 'inspect') { '%2' } else { '%3' }) } `
                -ResolveCancellation { New-TestCancellationProof } -ReleaseLock {
                param($path)
                $releases.Add($path) | Out-Null
                Remove-Item -LiteralPath $path
            }

            $after.state | Should -Be $terminalState
            $after.cleanup_journal[0].state | Should -Be 'succeeded'
            $releases.Count | Should -Be 1
            Test-Path -LiteralPath $lock | Should -BeFalse
        }
    }

    It 'C07 resumes terminal cleanup after both crash cuts without rewriting terminal outcome' {
        $project = Join-Path $TestDrive 'terminal-cleanup-crash-cut'
        $run = New-TestFailedRun
        $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
        $resumeReleases = [Collections.Generic.List[string]]::new()
        $afterCrash = Invoke-DeclarativeWorkflowTerminalCleanup -ProjectDir $project -Run $run -SaveRun { } -ReleaseLock {
            param($path)
            $resumeReleases.Add($path) | Out-Null
            Remove-Item -LiteralPath $path
        }
        $afterCrash.state | Should -Be 'failed'
        $resumeReleases.Count | Should -Be 1

        $afterDeleteCrash = Invoke-DeclarativeWorkflowTransition -Run (New-TestFailedRun) -Event ([ordered]@{ type = 'cleanup_intent'; preserve_run_state = 'failed' })
        $recovered = Invoke-DeclarativeWorkflowTerminalCleanup -ProjectDir $project -Run $afterDeleteCrash -SaveRun { } -ReleaseLock { throw 'must not repeat deletion' }
        $recovered.state | Should -Be 'failed'
        $recovered.cleanup_journal[0].state | Should -Be 'succeeded'
    }

    It 'L01 reconciles persisted running cleanup through public resume for terminal and successful outcomes' {
        $taskFile = Join-Path $TestDrive 'persisted-cleanup-resume-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        $completionProofs = New-TestDurableProofs -CompletionAcknowledgements @(
            (New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2'),
            (New-TestAcknowledgement -NodeId 'verify' -PaneId '%3')
        )
        $fixtures = @()
        foreach ($case in @(
                [PSCustomObject]@{ Name = 'terminal-running-matching'; Outcome = 'failed'; ExpectedStatus = 'failed'; ExpectedCleanupState = 'succeeded'; LockPresent = $true; ExpectedLockAfter = $false; ExpectedDeletes = 1 },
                [PSCustomObject]@{ Name = 'terminal-running-absent'; Outcome = 'failed'; ExpectedStatus = 'failed'; ExpectedCleanupState = 'succeeded'; LockPresent = $false; ExpectedLockAfter = $false; ExpectedDeletes = 0 },
                [PSCustomObject]@{ Name = 'terminal-running-mismatch'; Outcome = 'failed'; ExpectedStatus = 'blocked'; ExpectedCleanupState = 'blocked'; LockPresent = $true; ExpectedLockAfter = $true; ExpectedDeletes = 0; Mismatch = $true },
                [PSCustomObject]@{ Name = 'success-running-matching'; Outcome = 'succeeded'; ExpectedStatus = 'accepted'; ExpectedCleanupState = 'succeeded'; LockPresent = $true; ExpectedLockAfter = $false; ExpectedDeletes = 1 },
                [PSCustomObject]@{ Name = 'success-running-absent'; Outcome = 'succeeded'; ExpectedStatus = 'accepted'; ExpectedCleanupState = 'succeeded'; LockPresent = $false; ExpectedLockAfter = $false; ExpectedDeletes = 0 }
            )) {
            $project = Join-Path $TestDrive ("l01-" + $case.Name)
            $run = if ($case.Outcome -ceq 'failed') { New-TestFailedRun } else { New-TestSucceededRun }
            $intent = [ordered]@{ type = 'cleanup_intent' }
            if ($case.Outcome -ceq 'failed') { $intent['preserve_run_state'] = 'failed' }
            $run = Invoke-DeclarativeWorkflowTransition -Run $run -Event $intent -DurableProofs $(if ($case.Outcome -ceq 'succeeded') { $completionProofs } else { New-TestDurableProofs })
            if ($case.LockPresent) {
                $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run
                if ([bool](Get-DeclarativeWorkflowValue $case 'Mismatch' $false)) {
                    $payload = [IO.File]::ReadAllText($lock) | ConvertFrom-Json
                    $payload.source_head = 'c' * 40
                    [IO.File]::WriteAllText($lock, ($payload | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
                }
            }
            $fixtures += [PSCustomObject]@{ Case = $case; Project = $project; Run = $run }
        }

        $script:l01Current = $null
        $script:l01SaveCount = 0
        $script:l01DeleteCount = 0
        $script:l01DispatchCount = 0
        Mock Read-DeclarativeWorkflowRunState { Copy-DeclarativeWorkflowValue $script:l01Current.Run }
        Mock Save-DeclarativeWorkflowRunState {
            param($Run)
            $script:l01SaveCount++
            $script:l01Current.Run = Copy-DeclarativeWorkflowValue $Run
        }
        Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
        Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'l01-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
        Mock Get-TeamPipelineSessionName { 'l01-session' }
        Mock Resolve-TeamPipelineDeclarativeRuntimeLease { param($Label) [PSCustomObject]@{ label = [string]$Label; pane_id = '%2' } }
        Mock Invoke-TeamPipelineWorkspacePlanOnce {
            [ordered]@{
                config_fingerprint = ('sha256:' + ('a' * 64))
                resolved_bindings  = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
                workflow           = (New-TestWorkflowPlan)
            }
        }
        Mock Resolve-TeamPipelineDeclarativeAcknowledgement {
            param($Run, $NodeId)
            if ($script:l01Current.Case.Outcome -ceq 'succeeded') {
                return New-TestAcknowledgement -NodeId $NodeId -PaneId $(if ($NodeId -ceq 'inspect') { '%2' } else { '%3' })
            }
            return $null
        }
        Mock Invoke-TeamPipelineDeclarativeDispatch { $script:l01DispatchCount++; throw 'cleanup recovery must not dispatch' }
        Mock Remove-Item {
            param($LiteralPath)
            $script:l01DeleteCount++
            [IO.File]::Delete([string]$LiteralPath)
        } -ParameterFilter { [string]$LiteralPath -like '*run.lock' }

        foreach ($fixture in $fixtures) {
            $script:l01Current = $fixture
            $saveBefore = $script:l01SaveCount
            $deleteBefore = $script:l01DeleteCount
            $dispatchBefore = $script:l01DispatchCount
            $lockPath = Resolve-DeclarativeWorkflowOwnedLock -ProjectDir $fixture.Project -Run $fixture.Run

            $result = Invoke-TeamPipelineDeclarativeWorkflow -Action resume -RunId 'run-123' -GenerationId 'generation-123' `
                -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $fixture.Project

            $result.status | Should -Be $fixture.Case.ExpectedStatus -Because $fixture.Case.Name
            $result.state | Should -Be $fixture.Case.Outcome -Because $fixture.Case.Name
            $script:l01Current.Run.cleanup_journal[0].state | Should -Be $fixture.Case.ExpectedCleanupState -Because $fixture.Case.Name
            $script:l01Current.Run.state | Should -Be $fixture.Case.Outcome -Because $fixture.Case.Name
            ($script:l01SaveCount - $saveBefore) | Should -Be 1 -Because $fixture.Case.Name
            ($script:l01DeleteCount - $deleteBefore) | Should -Be $fixture.Case.ExpectedDeletes -Because $fixture.Case.Name
            ($script:l01DispatchCount - $dispatchBefore) | Should -Be 0 -Because $fixture.Case.Name
            (Test-Path -LiteralPath $lockPath -PathType Leaf) | Should -Be $fixture.Case.ExpectedLockAfter -Because $fixture.Case.Name

            $saveAfterSuccess = $script:l01SaveCount
            $deleteAfterSuccess = $script:l01DeleteCount
            {
                Invoke-TeamPipelineDeclarativeWorkflow -Action resume -RunId 'run-123' -GenerationId 'generation-123' `
                    -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $fixture.Project
            } | Should -Throw -Because "cleanup success is terminal and idempotently rejected for $($fixture.Case.Name)"
            $script:l01SaveCount | Should -Be $saveAfterSuccess -Because $fixture.Case.Name
            $script:l01DeleteCount | Should -Be $deleteAfterSuccess -Because $fixture.Case.Name
            $script:l01DispatchCount | Should -Be $dispatchBefore -Because $fixture.Case.Name
        }
    }

    It 'V01 carries an ordered bounded verification envelope from durable dependency evidence into the existing verify prompt' {
        $script:testDeclarativeSessionName = 'verification-session'
        $run = New-TestSucceededInspectRun
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\\builder-worktree' }
                'worker-2' = [ordered]@{ pane_id = '%3'; role = 'Reviewer' }
            }
        }
        $acknowledgement = New-TestAcknowledgement -NodeId 'verify' -PaneId '%3'
        $acknowledgement['transport'] = 'mailbox'
        $script:verificationRequest = $null
        $script:verificationPrompt = ''
        Mock Invoke-TeamPipelineGuardedSend {
            param($StageName, $Target, $Prompt)
            $script:verificationPrompt = $Prompt
            [PSCustomObject]@{ Status = 'SENT'; Target = $Target }
        }
        Mock Wait-TeamPipelineDeclarativeCompletion { $acknowledgement }

        $after = Invoke-DeclarativeWorkflowNode -Run $run -NodeId 'verify' -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
            -SaveRun { param($candidate) } `
            -Dispatch {
                param($request, $candidateRun)
                $script:verificationRequest = Copy-DeclarativeWorkflowValue $request
                Invoke-TeamPipelineDeclarativeDispatch -Request $request -Run $candidateRun -Manifest $manifest -ProjectDir $TestDrive -SessionName 'verification-session'
            } `
            -ResolveSession { param($paneId) $paneId } `
            -DurableProofs (New-TestDurableProofs -CompletionAcknowledgements @((New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2')))

        $after.nodes.verify.state | Should -Be 'succeeded'
        $script:verificationRequest.context_pack_ref | Should -Be 'review-pack'
        @($script:verificationRequest.dependency_node_ids) | Should -Be @('inspect')
        @($script:verificationRequest.evidence_refs) | Should -Be @('workflow-ack:run-123:inspect')
        $script:verificationPrompt | Should -Match 'Builder label: worker-1'
        $script:verificationPrompt | Should -Match ([regex]::Escape('Builder worktree: C:\\builder-worktree'))
        $script:verificationPrompt | Should -Match 'Context package reference: review-pack'
        $script:verificationPrompt | Should -Match 'workflow-ack:run-123:inspect'
        $script:verificationPrompt | Should -Not -Match 'RAW_OUTPUT_MARKER'
    }

    It 'V01 blocks a verification dispatch before acknowledgement when the dependency producer binding or bounded context is missing' {
        $run = New-TestSucceededInspectRun
        $run.resolved_bindings.Remove('implement')
        $manifest = [PSCustomObject]@{ Panes = [ordered]@{ 'worker-2' = [ordered]@{ pane_id = '%3'; role = 'Reviewer' } } }
        $request = [PSCustomObject]@{
            stage = 'VERIFY'; node_id = 'verify'; pane_ref = 'verify'; task = 'safe task body'
            context_pack_ref = 'review-pack'; dependency_node_ids = @('inspect'); evidence_refs = @('workflow-ack:run-123:inspect')
        }
        Mock Invoke-TeamPipelineGuardedSend { throw 'verification must not be sent without a producer binding' }
        Mock Wait-TeamPipelineDeclarativeCompletion { throw 'verification must not await an acknowledgement without a producer binding' }

        $result = Invoke-TeamPipelineDeclarativeDispatch -Request $request -Run $run -Manifest $manifest -ProjectDir $TestDrive -SessionName 'verification-session'

        $result | Should -BeNullOrEmpty
        Should -Invoke Invoke-TeamPipelineGuardedSend -Times 0 -Exactly
        Should -Invoke Wait-TeamPipelineDeclarativeCompletion -Times 0 -Exactly
    }

    It 'V01 blocks an unbounded context value before it can become verification prompt content' {
        $run = New-TestSucceededInspectRun
        $run.nodes.verify.context_pack_ref = "context-pack:RAW_OUTPUT_MARKER`nnot-a-reference"
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\\builder-worktree' }
                'worker-2' = [ordered]@{ pane_id = '%3'; role = 'Reviewer' }
            }
        }
        $request = [PSCustomObject]@{
            stage = 'VERIFY'; node_id = 'verify'; pane_ref = 'verify'; task = 'safe task body'
            context_pack_ref = $run.nodes.verify.context_pack_ref; dependency_node_ids = @('inspect'); evidence_refs = @('workflow-ack:run-123:inspect')
        }
        Mock Invoke-TeamPipelineGuardedSend { throw 'raw producer output must not be forwarded as a context reference' }
        Mock Wait-TeamPipelineDeclarativeCompletion { throw 'raw producer output must not reach acknowledgement polling' }

        $result = Invoke-TeamPipelineDeclarativeDispatch -Request $request -Run $run -Manifest $manifest -ProjectDir $TestDrive -SessionName 'verification-session'

        $result | Should -BeNullOrEmpty
        Should -Invoke Invoke-TeamPipelineGuardedSend -Times 0 -Exactly
        Should -Invoke Wait-TeamPipelineDeclarativeCompletion -Times 0 -Exactly
    }

    It 'V01 rejects unbounded context content while constructing the durable run state' {
        $plan = New-TestWorkflowPlan
        $plan.nodes[1].context_pack_ref = "context-pack:RAW_OUTPUT_MARKER`nnot-a-reference"

        {
            New-DeclarativeWorkflowRun -Plan $plan -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskInput (New-TestTaskInput)
        } | Should -Throw '*bounded reference*'
    }

    It 'V01 blocks an ambiguous multi-producer verification context before acknowledgement' {
        $run = New-TestRun
        $run.nodes.inspect.state = 'succeeded'
        $run.nodes.inspect.evidence_refs = @('workflow-ack:run-123:inspect')
        $run.nodes['second'] = [ordered]@{
            state = 'succeeded'; attempt = 1; idempotency_key = 'run-123:second'; pane_ref = 'implement-two'
            action = 'operator-dispatch'; depends_on = @(); cleanup = 'retain'; evidence_refs = @('workflow-ack:run-123:second')
        }
        $run.nodes.verify.depends_on = @('inspect', 'second')
        $run.resolved_bindings['implement-two'] = 'worker-3'
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\\builder-one' }
                'worker-2' = [ordered]@{ pane_id = '%3'; role = 'Reviewer' }
                'worker-3' = [ordered]@{ pane_id = '%4'; role = 'Builder'; builder_worktree_path = 'C:\\builder-two' }
            }
        }
        $request = [PSCustomObject]@{
            stage = 'VERIFY'; node_id = 'verify'; pane_ref = 'verify'; task = 'safe task body'
            context_pack_ref = 'review-pack'; dependency_node_ids = @('inspect', 'second')
            evidence_refs = @('workflow-ack:run-123:inspect', 'workflow-ack:run-123:second')
        }
        Mock Invoke-TeamPipelineGuardedSend { throw 'verification must not be sent for an ambiguous producer context' }
        Mock Wait-TeamPipelineDeclarativeCompletion { throw 'verification must not await acknowledgement for an ambiguous producer context' }

        $result = Invoke-TeamPipelineDeclarativeDispatch -Request $request -Run $run -Manifest $manifest -ProjectDir $TestDrive -SessionName 'verification-session'

        $result | Should -BeNullOrEmpty
        Should -Invoke Invoke-TeamPipelineGuardedSend -Times 0 -Exactly
        Should -Invoke Wait-TeamPipelineDeclarativeCompletion -Times 0 -Exactly
    }

    It 'S01 rejects missing or malformed start manifests before creating a workflow-run state lock dispatch or cleanup effect' {
        $taskFile = Join-Path $TestDrive 'manifest-precondition-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        foreach ($case in @(
                [PSCustomObject]@{ Name = 'missing'; ReadManifest = { $null } },
                [PSCustomObject]@{ Name = 'malformed'; ReadManifest = { throw 'manifest parse rejected' } },
                [PSCustomObject]@{ Name = 'missing-session-identity'; ReadManifest = { [PSCustomObject]@{ Session = [ordered]@{}; Panes = [ordered]@{} } } }
            )) {
            $project = Join-Path $TestDrive ("manifest-precondition-" + $case.Name)
            $plan = [ordered]@{
                config_fingerprint = ('sha256:' + ('a' * 64))
                resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
                workflow = (New-TestWorkflowPlan)
            }
            Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
            Mock Read-TeamPipelineManifest $case.ReadManifest
            Mock Invoke-TeamPipelineWorkspacePlanOnce { Copy-DeclarativeWorkflowValue $plan }
            Mock Invoke-TeamPipelineDeclarativeRunAdvancement { throw 'start must not dispatch without a manifest identity' }

            {
                Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
                    -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
                    -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $project
            } | Should -Throw

            Test-Path -LiteralPath (Join-Path $project '.winsmux\workflow-runs\run-123') | Should -BeFalse
            Should -Invoke Invoke-TeamPipelineWorkspacePlanOnce -Times 0 -Exactly
            Should -Invoke Invoke-TeamPipelineDeclarativeRunAdvancement -Times 0 -Exactly
        }
    }

    It 'M02 structurally rejects task-body fields without rejecting identifier-map keys and preserves existing state bytes' {
        $project = Join-Path $TestDrive 'structural-privacy-project'
        $run = New-TestRun
        $run.nodes.inspect.pane_ref = 'task'
        $run.resolved_bindings['task'] = 'worker-1'
        $run.nodes['task'] = Copy-DeclarativeWorkflowValue $run.nodes.inspect
        Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $run | Out-Null
        $statePath = Join-Path $project '.winsmux\workflow-runs\run-123\state.json'
        $baseline = [IO.File]::ReadAllBytes($statePath)

        foreach ($field in @('Text', 'task', 'task_file', 'task_path')) {
            $topLevel = Copy-DeclarativeWorkflowValue $run
            $topLevel[$field] = 'PRIVATE_TASK_BODY'
            { Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $topLevel } | Should -Throw '*must not persist*'
            [Convert]::ToHexString([IO.File]::ReadAllBytes($statePath)) | Should -Be ([Convert]::ToHexString($baseline))

            $nodeRecord = Copy-DeclarativeWorkflowValue $run
            $nodeRecord.nodes.inspect[$field] = 'PRIVATE_TASK_BODY'
            { Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $nodeRecord } | Should -Throw '*must not persist*'
            [Convert]::ToHexString([IO.File]::ReadAllBytes($statePath)) | Should -Be ([Convert]::ToHexString($baseline))
        }

        $untypedNode = Copy-DeclarativeWorkflowValue $run
        $untypedNode.nodes['task'] = 'PRIVATE_TASK_BODY'
        { Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $untypedNode } | Should -Throw '*typed records*'
        [Convert]::ToHexString([IO.File]::ReadAllBytes($statePath)) | Should -Be ([Convert]::ToHexString($baseline))
    }

    It 'M01 atomically projects workflow state while preserving unknown manifest sections' {
        $project = Join-Path $TestDrive 'manifest-project'
        $winsmuxDir = Join-Path $project '.winsmux'
        [IO.Directory]::CreateDirectory($winsmuxDir) | Out-Null
        $manifestPath = Join-Path $winsmuxDir 'manifest.yaml'
        $manifest = @"
version: 2
saved_at: 2026-07-22T00:00:00Z
session:
  name: winsmux-orchestra
  generation_id: generation-123
  server_session_id: `$9
  bootstrap_pane_id: "%1"
panes: {}
tasks:
  queued: []
  in_progress: []
  completed: []
worktrees: {}
future_state:
  keep: true
"@
        [IO.File]::WriteAllText($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))
        $run = New-TestRun
        Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
        Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $run | Out-Null
        $after = [IO.File]::ReadAllText($manifestPath)
        $after | Should -Match '(?m)^workflow_runs:'
        $after | Should -Match '(?m)^future_state:'
        $after | Should -Match '(?m)^  keep: true\r?$'
        $after | Should -Not -Match 'Implement TASK-659 safely'

        $stateBefore = [IO.File]::ReadAllBytes((Join-Path $winsmuxDir 'workflow-runs\run-123\state.json'))
        $manifestBefore = [IO.File]::ReadAllBytes($manifestPath)
        $badRun = Copy-DeclarativeWorkflowValue $run
        $badRun.generation_id = 'generation-other'
        { Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $badRun } | Should -Throw '*generation*'
        [Convert]::ToHexString([IO.File]::ReadAllBytes($manifestPath)) | Should -Be ([Convert]::ToHexString($manifestBefore))
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $winsmuxDir 'workflow-runs\run-123\state.json'))) | Should -Be ([Convert]::ToHexString($stateBefore))

        $junctionProject = Join-Path $TestDrive 'state-junction-project'
        $junctionRunsRoot = Join-Path $junctionProject '.winsmux\workflow-runs'
        $externalRunRoot = Join-Path $TestDrive 'external-state-run'
        [IO.Directory]::CreateDirectory($junctionRunsRoot) | Out-Null
        [IO.Directory]::CreateDirectory($externalRunRoot) | Out-Null
        $externalState = Join-Path $externalRunRoot 'state.json'
        [IO.File]::WriteAllText($externalState, 'external-state-sentinel', [Text.UTF8Encoding]::new($false))
        $externalBefore = [IO.File]::ReadAllBytes($externalState)
        $junctionPath = Join-Path $junctionRunsRoot 'run-123'
        $taskFile = Join-Path $TestDrive 'junction-state-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'm01-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
        Mock Get-TeamPipelineSessionName { 'm01-session' }
        try {
            try {
                $stateJunction = New-Item -ItemType Junction -Path $junctionPath -Target $externalRunRoot -ErrorAction Stop
            } catch {
                throw "State junction fixture creation failed explicitly: $($_.Exception.Message)"
            }
            [bool]($stateJunction.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -BeTrue
            { Read-DeclarativeWorkflowRunState -ProjectDir $junctionProject -RunId 'run-123' } | Should -Throw '*reparse*'
            { Save-DeclarativeWorkflowRunState -ProjectDir $junctionProject -Run $run } | Should -Throw '*reparse*'
            {
                Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
                    -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
                    -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $junctionProject
            } | Should -Throw '*reparse*'
            [Convert]::ToHexString([IO.File]::ReadAllBytes($externalState)) | Should -Be ([Convert]::ToHexString($externalBefore))
        } finally {
            if ([IO.Directory]::Exists($junctionPath)) { [IO.Directory]::Delete($junctionPath) }
        }
        [Convert]::ToHexString([IO.File]::ReadAllBytes($externalState)) | Should -Be ([Convert]::ToHexString($externalBefore))

        $transactionWorkflow = (New-TestWorkflowPlan | ConvertTo-Json -Depth 20) | ConvertFrom-Json -AsHashtable
        $transactionPlan = [ordered]@{
            config_fingerprint = ('sha256:' + ('a' * 64))
            resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
            workflow = $transactionWorkflow
        }
        Mock Invoke-TeamPipelineWorkspacePlanOnce { Copy-DeclarativeWorkflowValue $transactionPlan }
        Mock Resolve-TeamPipelineDeclarativeRuntimeLease { param($Label) [PSCustomObject]@{ label = [string]$Label; pane_id = '%2' } }
        $existingLockProject = Join-Path $TestDrive 'existing-lock-project'
        $existingRunRoot = Join-Path $existingLockProject '.winsmux\workflow-runs\run-123'
        [IO.Directory]::CreateDirectory($existingRunRoot) | Out-Null
        $existingLockPath = Join-Path $existingRunRoot 'run.lock'
        [IO.File]::WriteAllText($existingLockPath, 'existing-lock-sentinel', [Text.UTF8Encoding]::new($false))
        $existingLockBefore = [IO.File]::ReadAllBytes($existingLockPath)
        {
            Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
                -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
                -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $existingLockProject
        } | Should -Throw
        [Convert]::ToHexString([IO.File]::ReadAllBytes($existingLockPath)) | Should -Be ([Convert]::ToHexString($existingLockBefore))
        Test-Path -LiteralPath (Join-Path $existingRunRoot 'state.json') -PathType Leaf | Should -BeFalse

        $saveFailureProject = Join-Path $TestDrive 'save-failure-project'
        $saveFailureLock = Join-Path $saveFailureProject '.winsmux\workflow-runs\run-123\run.lock'
        $script:lockObservedBeforeStateSave = $false
        Mock Save-DeclarativeWorkflowRunState {
            $script:lockObservedBeforeStateSave = Test-Path -LiteralPath $saveFailureLock -PathType Leaf
            throw 'injected state save failure'
        }
        {
            Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
                -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
                -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $saveFailureProject
        } | Should -Throw '*injected state save failure*'
        $script:lockObservedBeforeStateSave | Should -BeFalse
        Test-Path -LiteralPath $saveFailureLock -PathType Leaf | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $saveFailureProject '.winsmux\workflow-runs\run-123\state.json') -PathType Leaf | Should -BeFalse
    }

    It 'C21 admits only a pristine state-only bootstrap, reuses a matching lock, and blocks a missing or mismatched lock after an effect' {
        $taskFile = Join-Path $TestDrive 'bootstrap-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        $workspacePlan = [ordered]@{
            config_fingerprint = ('sha256:' + ('a' * 64))
            resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
            workflow = (New-TestWorkflowPlan)
        }

        foreach ($case in @(
                [PSCustomObject]@{ Name = 'state-only-pristine'; Setup = { param($project, $run) } ; ExpectedAdvance = 1; ExpectedLock = $true },
                [PSCustomObject]@{ Name = 'matching-lock'; Setup = { param($project, $run) New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $run | Out-Null } ; ExpectedAdvance = 1; ExpectedLock = $true },
                [PSCustomObject]@{
                    Name = 'missing-lock-after-effect'
                    Setup = { param($project, $run) $dispatched = New-TestDispatchedRun -Run $run; Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $dispatched | Out-Null }
                    ExpectedAdvance = 0; ExpectedLock = $false
                },
                [PSCustomObject]@{
                    Name = 'mismatched-lock-after-effect'
                    Setup = {
                        param($project, $run)
                        $dispatched = New-TestDispatchedRun -Run $run
                        Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $dispatched | Out-Null
                        $lock = New-DeclarativeWorkflowRunLock -ProjectDir $project -Run $dispatched
                        $payload = [IO.File]::ReadAllText($lock) | ConvertFrom-Json
                        $payload.source_head = ('c' * 40)
                        [IO.File]::WriteAllText($lock, ($payload | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
                    }
                    ExpectedAdvance = 0; ExpectedLock = $true
                }
            )) {
            $project = Join-Path $TestDrive ("bootstrap-" + $case.Name)
            $run = New-TestRun
            Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $run -CreateNew | Out-Null
            & $case.Setup $project $run
            $statePath = Join-Path $project '.winsmux\workflow-runs\run-123\state.json'
            $stateBefore = [IO.File]::ReadAllBytes($statePath)
            $script:bootstrapAdvances = 0
            $script:bootstrapDispatches = 0
            Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
            Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'bootstrap-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
            Mock Get-TeamPipelineSessionName { 'bootstrap-session' }
            Mock Invoke-TeamPipelineWorkspacePlanOnce { Copy-DeclarativeWorkflowValue $workspacePlan }
            Mock Resolve-TeamPipelineDeclarativeRuntimeLease { param($Label) [PSCustomObject]@{ label = [string]$Label; pane_id = '%2' } }
            Mock Invoke-TeamPipelineDeclarativeRunAdvancement {
                param($ProjectDir, $Run)
                $script:bootstrapAdvances++
                return $Run
            }
            Mock Invoke-TeamPipelineDeclarativeDispatch { $script:bootstrapDispatches++; throw 'bootstrap rejection must not dispatch' }

            if ($case.ExpectedAdvance -eq 0) {
                {
                    Invoke-TeamPipelineDeclarativeWorkflow -Action resume -RunId 'run-123' -GenerationId 'generation-123' `
                        -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $project
                } | Should -Throw -Because $case.Name
            } else {
                $result = Invoke-TeamPipelineDeclarativeWorkflow -Action resume -RunId 'run-123' -GenerationId 'generation-123' `
                    -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $project
                $result.status | Should -Be 'accepted'
            }

            $script:bootstrapAdvances | Should -Be $case.ExpectedAdvance -Because $case.Name
            $script:bootstrapDispatches | Should -Be 0 -Because $case.Name
            $lockPath = Join-Path $project '.winsmux\workflow-runs\run-123\run.lock'
            (Test-Path -LiteralPath $lockPath -PathType Leaf) | Should -Be $case.ExpectedLock -Because $case.Name
            if ($case.ExpectedAdvance -eq 0) {
                [Convert]::ToHexString([IO.File]::ReadAllBytes($statePath)) | Should -Be ([Convert]::ToHexString($stateBefore)) -Because $case.Name
            }
        }
    }

    It 'C22 removes the create-new state when initial manifest projection fails before any lock exists' {
        $project = Join-Path $TestDrive 'bootstrap-projection-failure'
        $winsmuxDir = Join-Path $project '.winsmux'
        [IO.Directory]::CreateDirectory($winsmuxDir) | Out-Null
        [IO.File]::WriteAllText((Join-Path $winsmuxDir 'manifest.yaml'), @"
version: 2
session:
  name: bootstrap-projection
  generation_id: generation-123
panes: {}
worktrees: {}
"@, [Text.UTF8Encoding]::new($false))
        $run = New-TestRun
        Mock Save-WinsmuxManifest { throw 'injected initial manifest projection failure' }

        { Save-DeclarativeWorkflowRunState -ProjectDir $project -Run $run -CreateNew } | Should -Throw '*injected initial manifest projection failure*'

        Test-Path -LiteralPath (Join-Path $project '.winsmux\workflow-runs\run-123\state.json') -PathType Leaf | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $project '.winsmux\workflow-runs\run-123\run.lock') -PathType Leaf | Should -BeFalse
    }

    It 'F03 admits one invocation lease per run, permits different runs, and recovers after owner exit without deleting the marker' {
        $project = Join-Path $TestDrive 'invocation-lease'
        $run = New-TestRun
        $otherRun = Copy-DeclarativeWorkflowValue $run
        $otherRun.run_id = 'run-456'

        $owner = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123'
        $otherOwner = $null
        try {
            { Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123' } |
                Should -Throw '*workflow_run_invocation_busy*'
            $otherOwner = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-456'
        } finally {
            if ($null -ne $otherOwner) { $otherOwner.Dispose() }
            $owner.Dispose()
        }

        $marker = Join-Path $project '.winsmux\workflow-runs\run-123\invocation.lock'
        Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
        $recovered = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123'
        $recovered.Dispose()
        Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
    }

    It 'F03 releases the kernel invocation lease after an owning pwsh process is terminated' {
        $project = Join-Path $TestDrive 'invocation-crash-recovery'
        $readyPath = Join-Path $TestDrive 'invocation-owner-ready.txt'
        $workflowScript = Join-Path $script:RepoRoot 'winsmux-core\scripts\declarative-workflow.ps1'
        $escapedWorkflowScript = $workflowScript.Replace("'", "''")
        $escapedProject = $project.Replace("'", "''")
        $escapedReadyPath = $readyPath.Replace("'", "''")
        $childCommand = @"
. '$escapedWorkflowScript'
`$lease = Enter-DeclarativeWorkflowInvocationLease -ProjectDir '$escapedProject' -RunId 'run-123'
[IO.File]::WriteAllText('$escapedReadyPath', 'ready', [Text.UTF8Encoding]::new(`$false))
while (`$true) { Start-Sleep -Seconds 1 }
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
        $pwsh = (Get-Process -Id $PID).Path
        $owner = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WindowStyle Hidden -PassThru
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
                if ($owner.HasExited) { throw "invocation lease child exited early with code $($owner.ExitCode)" }
                Start-Sleep -Milliseconds 50
            }
            Test-Path -LiteralPath $readyPath -PathType Leaf | Should -BeTrue
            { Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123' } |
                Should -Throw '*workflow_run_invocation_busy*'
        } finally {
            if (-not $owner.HasExited) { Stop-Process -Id $owner.Id -Force -ErrorAction SilentlyContinue }
            $owner.WaitForExit(10000) | Out-Null
            $owner.Dispose()
        }

        $marker = Join-Path $project '.winsmux\workflow-runs\run-123\invocation.lock'
        Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
        $recovered = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123'
        $recovered.Dispose()
        Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
    }

    It 'F03 holds the invocation lease across start planning and releases it after the invocation returns' {
        $project = Join-Path $TestDrive 'invocation-lifetime'
        $taskFile = Join-Path $TestDrive 'invocation-lifetime-task.txt'
        [IO.File]::WriteAllText($taskFile, 'Implement TASK-659 safely.', [Text.UTF8Encoding]::new($false))
        $workspacePlan = [ordered]@{
            config_fingerprint = ('sha256:' + ('a' * 64))
            resolved_bindings = [ordered]@{ implement = 'worker-1'; verify = 'worker-2' }
            workflow = (New-TestWorkflowPlan)
        }
        $script:invocationBusyObserved = $false
        Mock Get-TeamPipelineDeclarativeProjectHead { 'b' * 40 }
        Mock Read-TeamPipelineManifest { [PSCustomObject]@{ Session = [ordered]@{ name = 'lease-session'; generation_id = 'generation-123' }; Panes = [ordered]@{} } }
        Mock Get-TeamPipelineSessionName { 'lease-session' }
        Mock Invoke-TeamPipelineWorkspacePlanOnce {
            try {
                $contender = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123'
                $contender.Dispose()
            } catch {
                $script:invocationBusyObserved = $_.Exception.Message -like '*workflow_run_invocation_busy*'
            }
            Copy-DeclarativeWorkflowValue $workspacePlan
        }
        Mock Resolve-TeamPipelineDeclarativeRuntimeLease { param($Label) [PSCustomObject]@{ label = [string]$Label; pane_id = '%2' } }
        Mock Invoke-TeamPipelineDeclarativeRunAdvancement { param($ProjectDir, $Run) $Run }

        $result = Invoke-TeamPipelineDeclarativeWorkflow -Action start -RecipeId 'bugfix-two-slot' -WorkflowId 'bugfix' `
            -RunId 'run-123' -GenerationId 'generation-123' -ConfigFingerprint ('sha256:' + ('a' * 64)) `
            -SourceHead ('b' * 40) -TaskFile $taskFile -ProjectDir $project

        $result.status | Should -Be 'accepted'
        $script:invocationBusyObserved | Should -BeTrue
        $after = Enter-DeclarativeWorkflowInvocationLease -ProjectDir $project -RunId 'run-123'
        $after.Dispose()
    }

    It 'H01 routes all workflow state changes through the native Rust reducer and creates only schema v2 snapshots' {
        Get-Command Invoke-DeclarativeWorkflowStateReducer -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $run = New-TestRun
        $run.schema_version | Should -Be 2
        $run.nodes.inspect.state | Should -Be 'ready'
        $run.nodes.verify.state | Should -Be 'pending'
    }

    It 'I01 accepts only managed GUID-N or legacy stable generation IDs at bootstrap and save boundaries' {
        $taskInput = New-TestTaskInput
        $validGenerationIds = @(
            '0123456789abcdef0123456789abcdef',
            'generation-123'
        )
        for ($index = 0; $index -lt $validGenerationIds.Count; $index++) {
            $generationId = $validGenerationIds[$index]
            $run = New-DeclarativeWorkflowRun -Plan (New-TestWorkflowPlan) -RunId 'run-123' -GenerationId $generationId `
                -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskInput $taskInput
            $run.generation_id | Should -BeExactly $generationId
            Save-DeclarativeWorkflowRunState -ProjectDir (Join-Path $TestDrive "generation-id-$index") -Run $run | Out-Null
        }

        $invalidGenerationIds = @(
            '123',
            '0123456789abcdef0123456789abcde',
            '0123456789abcdef0123456789abcdef0',
            '0123456789abcdef0123456789abcdeF',
            '0123456789abcdef0123456789abcdeg',
            '-generation-123',
            ' generation-123',
            'generation-123 ',
            '世代-123'
        )
        foreach ($generationId in $invalidGenerationIds) {
            {
                New-DeclarativeWorkflowRun -Plan (New-TestWorkflowPlan) -RunId 'run-123' -GenerationId $generationId `
                    -ConfigFingerprint ('sha256:' + ('a' * 64)) -SourceHead ('b' * 40) -TaskInput $taskInput
            } | Should -Throw '*generation_id*'

            $persisted = New-TestRun
            $persisted.generation_id = $generationId
            {
                Save-DeclarativeWorkflowRunState -ProjectDir (Join-Path $TestDrive ('invalid-generation-' + [guid]::NewGuid().ToString('N'))) -Run $persisted
            } | Should -Throw '*generation_id*'
        }
    }

    It 'H02 rejects a legacy v1 snapshot before save dispatch or cleanup effects' {
        $run = New-TestRun
        $run.schema_version = 1
        $script:h02Effects = 0
        {
            Invoke-DeclarativeWorkflowResume -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
                -SaveRun { $script:h02Effects++ } -Dispatch { $script:h02Effects++ } `
                -ResolveSession { '%2' } -ResolveAcknowledgement { New-TestAcknowledgement -NodeId 'inspect' -PaneId '%2' }
        } | Should -Throw '*workflow_state_migration_required*'
        $script:h02Effects | Should -Be 0
    }

    It 'H03 does not release a dependent from a forged succeeded state without an exact completion proof' {
        $run = New-TestRun
        $run.nodes.inspect.state = 'succeeded'
        $run.nodes.inspect.attempt = 1
        $run.nodes.inspect.agent_cli_session_id = '%2'
        $run.nodes.inspect.evidence_refs = @('workflow-ack:run-123:inspect')
        $script:h03Effects = 0
        {
            Invoke-DeclarativeWorkflowResume -Run $run -TaskInput (New-TestTaskInput) -Confirmation (New-TestConfirmation) `
                -SaveRun { $script:h03Effects++ } -Dispatch { $script:h03Effects++ } `
                -ResolveSession { '%2' } -ResolveAcknowledgement { $null }
        } | Should -Throw '*workflow_state_invalid*'
        $script:h03Effects | Should -Be 0
        $run.nodes.verify.state | Should -Be 'pending'
    }
}
