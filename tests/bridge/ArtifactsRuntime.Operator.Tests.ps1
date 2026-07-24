$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'operator-poll helpers' {
    BeforeAll {
        $script:operatorPollScriptPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\operator-poll.ps1'
        function New-TestDurableWorkflowEnvelope {
            param(
                [string]$MessageId = 'workflow-ack-f01',
                [string]$NodeId = 'inspect',
                [string]$GenerationId = 'generation-123',
                [string]$RunId = 'run-123'
            )
            [ordered]@{
                mailbox_version = 2; message_id = $MessageId; correlation_id = $MessageId; causation_id = $null
                idempotency_key = "workflow-completion-$MessageId"; message_type = 'workflow-completion'; state = 'created'; ttl_seconds = 300
                ack_required = $true; from = 'builder-1'; to = 'Operator'; timestamp = [DateTimeOffset]::UtcNow.ToString('o')
                content = [ordered]@{
                    session = 'winsmux-orchestra'; event = 'workflow.node.acknowledged'; message = 'Declarative workflow completion.'
                    label = 'builder-1'; pane_id = '%2'; role = 'Builder'; status = 'succeeded'; exit_reason = ''
                    data = [ordered]@{
                        schema_version = 1; run_id = $RunId; node_id = $NodeId; idempotency_key = "$RunId`:$NodeId"
                        generation_id = $GenerationId; config_fingerprint = ('sha256:' + ('a' * 64)); workflow_fingerprint = ('sha256:' + ('d' * 64))
                        source_head = $script:operatorPollSourceHead; pane_id = '%2'; status = 'succeeded'; evidence_ref = "workflow-ack:$RunId`:$NodeId"
                    }
                }
            }
        }
        function ConvertTo-TestAuthenticatedDurableWorkflowRecord {
            param([Parameter(Mandatory = $true)]$MailboxMessage)

            $messageId = [string]$MailboxMessage.message_id
            $channel = Get-OperatorPollMailboxChannel -SessionName 'winsmux-orchestra'
            $pendingRoot = Join-Path $script:operatorPollTempRoot ".winsmux\mailbox\$channel\pending"
            [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
            $pendingPath = Join-Path $pendingRoot "$messageId.json"
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($MailboxMessage | ConvertTo-Json -Compress -Depth 20))
            [IO.File]::WriteAllBytes($pendingPath, $bytes)
            $persistedMessage = ([Text.UTF8Encoding]::new($false, $true).GetString($bytes)) |
                ConvertFrom-WinsmuxJson -AsHashtable -Depth 30 -ErrorAction Stop
            $record = ConvertTo-OperatorPollMailboxRecord -MailboxMessage $persistedMessage `
                -SessionName 'winsmux-orchestra'
            $record['durable_pending_path'] = $pendingPath
            $record['durable_pending_channel'] = $channel
            $record['durable_pending_message_id'] = $messageId
            $record['durable_pending_sha256'] = Get-DeclarativeWorkflowSha256Digest -Bytes $bytes
            return $record
        }
        function Initialize-TestDurableWorkflowRun {
            param(
                [string]$InspectState = 'dispatching',
                [int]$InspectAttempt = 1,
                [string]$InspectBinding = 'builder-1',
                [string]$RunId = 'run-123'
            )
            $runRoot = Join-Path $script:operatorPollTempRoot ".winsmux\workflow-runs\$RunId"
            [IO.Directory]::CreateDirectory($runRoot) | Out-Null
            $run = [ordered]@{
                schema_version = 3; run_id = $RunId; generation_id = 'generation-123'
                config_fingerprint = ('sha256:' + ('a' * 64)); workflow_fingerprint = ('sha256:' + ('d' * 64)); source_head = $script:operatorPollSourceHead
                resolved_bindings = [ordered]@{ implement = $InspectBinding; verify = 'builder-2' }
                normalized_snapshot = [ordered]@{
                    application_contract = [ordered]@{
                        implement = [ordered]@{
                            pane_ref = 'implement'; slot_id = $InspectBinding
                            worktree = [ordered]@{ mode = 'read-only-reference' }
                            actual_capabilities = [ordered]@{
                                supports_file_edit = $false
                                supports_verification = $true
                                supports_structured_result = $true
                            }
                        }
                        verify = [ordered]@{
                            pane_ref = 'verify'; slot_id = 'builder-2'
                            worktree = [ordered]@{ mode = 'read-only-reference' }
                            actual_capabilities = [ordered]@{
                                supports_file_edit = $false
                                supports_verification = $true
                                supports_structured_result = $true
                            }
                        }
                    }
                    nodes = @(
                        [ordered]@{
                            node_id = 'inspect'; pane_ref = 'implement'; action = 'verification'
                            required_capability = 'review'; allowed_worktree_modes = @('managed', 'read-only-reference')
                            may_advance_head = $false
                        }
                    )
                }
                pane_head_leases = [ordered]@{}
                nodes = [ordered]@{
                    inspect = [ordered]@{
                        node_id = 'inspect'; idempotency_key = "$RunId`:inspect"; state = $InspectState
                        attempt = $InspectAttempt; pane_ref = 'implement'; action = 'verification'
                        required_capability = 'review'; allowed_worktree_modes = @('managed', 'read-only-reference')
                        may_advance_head = $false
                        execution_lease = [ordered]@{
                            pane_ref = 'implement'; slot_id = $InspectBinding
                            worktree_mode = 'read-only-reference'; input_head = $script:operatorPollSourceHead
                            dependency_inputs = @(); dependency_heads = [ordered]@{}
                        }
                    }
                    verify = [ordered]@{
                        node_id = 'verify'; idempotency_key = "$RunId`:verify"; state = 'pending'
                        attempt = 0; pane_ref = 'verify'
                    }
                }
            }
            [IO.File]::WriteAllText((Join-Path $runRoot 'state.json'), ($run | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))
        }

        function Add-TestDurableWorkflowCompletionProof {
            param(
                [Parameter(Mandatory = $true)][string]$MessageId,
                [string]$NodeId = 'inspect',
                [string]$RunId = 'run-123'
            )
            $run = Read-DeclarativeWorkflowRunState -ProjectDir $script:operatorPollTempRoot -RunId $RunId
            $proof = (New-TestDurableWorkflowEnvelope -MessageId $MessageId -NodeId $NodeId -RunId $RunId).content.data
            $proof['schema_version'] = 2
            $proof['input_head'] = $script:operatorPollSourceHead
            $proof['output_head'] = $script:operatorPollSourceHead
            $proof['transport'] = 'mailbox'
            $proof['message_id'] = $MessageId
            Write-DeclarativeWorkflowDurableProof -ProjectDir $script:operatorPollTempRoot -Run $run -Kind Completion -NodeId $NodeId -Proof $proof `
                -TrustedSenderLabel 'builder-1' -TrustedSenderPaneId '%2' | Out-Null
        }

        function New-TestManagedPublisherFixture {
            param([string]$MessageId = 'workflow-ack-publisher-matrix')

            $project = $script:operatorPollTempRoot
            $baseHead = $script:operatorPollSourceHead
            $worktreeName = 'publisher-matrix'
            $managedPath = Join-Path $project ".worktrees\$worktreeName"
            & git -C $project worktree add --quiet -b $worktreeName $managedPath $baseHead
            $LASTEXITCODE | Should -Be 0

            $runRoot = Join-Path $project '.winsmux\workflow-runs\run-123'
            [IO.Directory]::CreateDirectory($runRoot) | Out-Null
            $run = [ordered]@{
                schema_version = 3; workflow_id = 'bugfix'; recipe_ref = 'bugfix-two-slot'; run_id = 'run-123'
                state = 'running'; generation_id = 'generation-123'
                config_fingerprint = ('sha256:' + ('a' * 64)); workflow_fingerprint = ('sha256:' + ('d' * 64))
                source_head = $baseHead; task_sha256 = ('sha256:' + ('c' * 64)); task_byte_count = 24
                resolved_bindings = [ordered]@{ implement = 'builder-1' }
                normalized_snapshot = [ordered]@{
                    resolved_bindings = [ordered]@{ implement = 'builder-1' }
                    application_contract = [ordered]@{
                        implement = [ordered]@{
                            pane_ref = 'implement'; slot_id = 'builder-1'
                            worktree = [ordered]@{ mode = 'managed'; name = $worktreeName }
                            actual_capabilities = [ordered]@{
                                supports_file_edit = $true
                                supports_verification = $false
                                supports_structured_result = $false
                            }
                        }
                    }
                    nodes = @(
                        [ordered]@{
                            node_id = 'inspect'; pane_ref = 'implement'; action = 'operator-dispatch'
                            required_capability = 'file-edit'; allowed_worktree_modes = @('managed')
                            may_advance_head = $true
                        }
                    )
                }
                pane_head_leases = [ordered]@{
                    implement = [ordered]@{ base_head = $baseHead; admitted_head = $baseHead }
                }
                nodes = [ordered]@{
                    inspect = [ordered]@{
                        node_id = 'inspect'; idempotency_key = 'run-123:inspect'; state = 'dispatching'
                        attempt = 1; pane_ref = 'implement'; action = 'operator-dispatch'
                        required_capability = 'file-edit'; allowed_worktree_modes = @('managed')
                        may_advance_head = $true
                        execution_lease = [ordered]@{
                            pane_ref = 'implement'; slot_id = 'builder-1'; worktree_mode = 'managed'
                            input_head = $baseHead
                            dependency_inputs = @(); dependency_heads = [ordered]@{}
                        }
                    }
                }
            }
            $statePath = Join-Path $runRoot 'state.json'
            [IO.File]::WriteAllText($statePath, ($run | ConvertTo-Json -Compress -Depth 30), [Text.UTF8Encoding]::new($false))
            $acknowledgement = (New-TestDurableWorkflowEnvelope -MessageId $MessageId).content.data
            $acknowledgement.source_head = $baseHead
            $acknowledgement['transport'] = 'mailbox'
            $acknowledgement['message_id'] = $MessageId
            [PSCustomObject]@{
                ProjectDir = $project
                BaseHead = $baseHead
                ManagedPath = $managedPath
                StatePath = $statePath
                Run = $run
                Acknowledgement = $acknowledgement
                PaneContext = [ordered]@{
                    label = 'builder-1'; pane_id = '%2'; worktree_path = $managedPath
                }
                Manifest = [ordered]@{
                    Session = [ordered]@{
                        name = 'winsmux-orchestra'; generation_id = 'generation-123'; project_dir = $project
                    }
                    Panes = [ordered]@{
                        'builder-1' = [ordered]@{
                            pane_id = '%2'; role = 'Builder'; launch_dir = $managedPath
                            builder_worktree_path = $managedPath
                            supports_file_edit = 'true'; supports_verification = 'false'
                            supports_structured_result = 'false'
                        }
                    }
                }
            }
        }
    }

    BeforeEach {
        $script:operatorPollTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-operator-poll-tests-' + [guid]::NewGuid().ToString('N'))
        $script:operatorPollManifestDir = Join-Path $script:operatorPollTempRoot '.winsmux'
        $script:operatorPollManifestPath = Join-Path $script:operatorPollManifestDir 'manifest.yaml'
        New-Item -ItemType Directory -Path $script:operatorPollManifestDir -Force | Out-Null
        & git -C $script:operatorPollTempRoot init --quiet
        $LASTEXITCODE | Should -Be 0
        $fixturePath = Join-Path $script:operatorPollTempRoot 'operator-poll-fixture.txt'
        [IO.File]::WriteAllText($fixturePath, 'fixture', [Text.UTF8Encoding]::new($false))
        & git -C $script:operatorPollTempRoot add -- operator-poll-fixture.txt
        & git -C $script:operatorPollTempRoot -c user.name=winsmux-test -c user.email=winsmux-test@example.invalid commit --quiet -m fixture
        $LASTEXITCODE | Should -Be 0
        $script:operatorPollSourceHead = ([string](& git -C $script:operatorPollTempRoot rev-parse HEAD)).Trim()

@"
version: 1
session:
  name: winsmux-orchestra
  generation_id: generation-123
  project_dir: $script:operatorPollTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: $script:operatorPollTempRoot
    supports_file_edit: false
    supports_verification: true
    supports_structured_result: true
"@ | Set-Content -Path $script:operatorPollManifestPath -Encoding UTF8

        . $script:operatorPollScriptPath -ManifestPath $script:operatorPollManifestPath
        Mock Read-WinsmuxRuntimeRegistry {
            [PSCustomObject]@{
                status = 'active'
                session_name = 'winsmux-orchestra'
                generation_id = 'generation-123'
                panes = @([PSCustomObject]@{ pane_id = '%2'; generation_id = 'generation-123' })
            }
        }
        $script:operatorPollRuntimeGeneration = 'generation-123'
        Mock Get-PaneControlManifestContext {
            param($ProjectDir, $PaneId)
            [PSCustomObject]@{
                ProjectDir = $ProjectDir
                Label = 'builder-1'
                PaneId = $PaneId
                GenerationId = $script:operatorPollRuntimeGeneration
            }
        }
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation)
            [PSCustomObject]@{
                valid = $true
                context = [PSCustomObject]@{
                    session_name = 'winsmux-orchestra'
                    generation_id = [string]$ManifestEntry.GenerationId
                    label = [string]$ManifestEntry.Label
                    pane_id = [string]$ManifestEntry.PaneId
                }
            }
        }
    }

    AfterEach {
        if ($script:operatorPollTempRoot -and (Test-Path $script:operatorPollTempRoot)) {
            Remove-Item -Path $script:operatorPollTempRoot -Recurse -Force
        }
    }

    It 'TASK781 C19 threads the event manifest snapshot through pane state updates' {
        $paneContext = [ordered]@{
            project_dir = $script:operatorPollTempRoot
            manifest_path = $script:operatorPollManifestPath
            pane_id = '%2'
            generation_id = 'generation-initial'
        }
        $script:capturedPollGeneration = ''
        Mock Get-PaneControlManifestEntries {
            @([pscustomobject]@{ ManifestPath = 'replacement'; PaneId = '%9'; GenerationId = 'generation-replacement' })
        }
        Mock Set-PaneControlManifestPaneProperties {
            param($ManifestPath, $PaneId, $Properties, $ExpectedGenerationId)
            $script:capturedPollGeneration = [string]$ExpectedGenerationId
        }

        Update-OperatorPollPaneState -PaneContext $paneContext -Properties ([ordered]@{ task_state = 'completed' })

        $script:capturedPollGeneration | Should -BeExactly 'generation-initial'
        Should -Invoke Get-PaneControlManifestEntries -Times 0 -Exactly
    }

    It 'TASK781 C19 carries the event snapshot through the production poll caller' {
        $manifest = [ordered]@{
            Session = [ordered]@{
                name = 'winsmux-orchestra'
                project_dir = $script:operatorPollTempRoot
                generation_id = 'generation-initial'
            }
            Panes = [ordered]@{
                'builder-1' = [ordered]@{ pane_id = '%2'; role = 'Builder'; launch_dir = $script:operatorPollTempRoot }
            }
        }
        $event = [ordered]@{ session = 'winsmux-orchestra'; event = 'pane.idle'; pane_id = '%2'; label = 'builder-1'; role = 'Builder' }
        $summary = [ordered]@{ new_events = 0; dispatches = 0; completions = 0; approvals = 0; errors = 0; messages = @() }
        $script:pollCallerGeneration = ''
        Mock Write-OperatorPollLog { }
        Mock Send-OperatorTelegramNotification { }
        $script:operatorPollRuntimeGeneration = 'generation-initial'
        Mock Get-PaneControlManifestEntries {
            @([pscustomobject]@{ ManifestPath = 'replacement'; PaneId = '%9'; GenerationId = 'generation-replacement' })
        }
        Mock Set-PaneControlManifestPaneProperties {
            $script:pollCallerGeneration = [string]$ExpectedGenerationId
        }

        Invoke-OperatorPollEventRecord -Manifest $manifest -ManifestPath $script:operatorPollManifestPath `
            -EventRecord $event -Summary $summary

        $summary.dispatches | Should -Be 1
        $script:pollCallerGeneration | Should -BeExactly 'generation-initial'
        Should -Invoke Get-PaneControlManifestEntries -Times 0 -Exactly
    }

    It 'D02 rejects an old pane ID with a reused label before log, counter, mutation, or notification effects' {
        $manifest = [ordered]@{
            Session = [ordered]@{
                name = 'winsmux-orchestra'
                project_dir = $script:operatorPollTempRoot
                generation_id = 'generation-current'
            }
            Panes = [ordered]@{
                'builder-1' = [ordered]@{ pane_id = '%9'; role = 'Builder'; launch_dir = $script:operatorPollTempRoot }
            }
        }
        $event = [ordered]@{
            session = 'winsmux-orchestra'
            event = 'pane.completed'
            pane_id = '%2'
            label = 'builder-1'
            role = 'Builder'
            source = 'events_jsonl'
            id = 'stale-pane-id'
        }
        $summary = [ordered]@{ new_events = 0; dispatches = 0; completions = 0; approvals = 0; errors = 0; messages = @() }
        Mock Write-OperatorPollLog { throw 'stale event must not be logged' }
        Mock Update-OperatorPollPaneState { throw 'stale event must not mutate manifest state' }
        Mock Send-OperatorTelegramNotification { throw 'stale event must not notify' }
        Mock Get-OperatorPollDiffData { throw 'stale event must not inspect a worktree' }
        Mock Test-PaneControlRuntimeContext { throw 'mismatched pane identity must be rejected before runtime admission' }

        Invoke-OperatorPollEventRecord -Manifest $manifest -ManifestPath $script:operatorPollManifestPath `
            -EventRecord $event -Summary $summary

        $summary.new_events | Should -Be 0
        $summary.dispatches | Should -Be 0
        $summary.completions | Should -Be 0
        $summary.approvals | Should -Be 0
        $summary.errors | Should -Be 1
        Should -Invoke Write-OperatorPollLog -Times 0 -Exactly
        Should -Invoke Update-OperatorPollPaneState -Times 0 -Exactly
        Should -Invoke Send-OperatorTelegramNotification -Times 0 -Exactly
        Should -Invoke Get-OperatorPollDiffData -Times 0 -Exactly
        Should -Invoke Test-PaneControlRuntimeContext -Times 0 -Exactly
    }

    It 'processes mailbox idle messages and logs dispatch-needed guidance' {
        Mock Receive-OperatorPollMailboxMessages {
            @(
                [ordered]@{
                    timestamp   = '2026-04-07T09:00:00.0000000+09:00'
                    session     = 'winsmux-orchestra'
                    event       = 'pane.idle'
                    message     = 'Operator alert: idle pane builder-1 (%2, role=Builder)'
                    label       = 'builder-1'
                    pane_id     = '%2'
                    role        = 'Builder'
                    status      = 'ready'
                    exit_reason = ''
                    data        = [ordered]@{
                        idle_threshold_seconds = 120
                    }
                    source      = 'mailbox'
                }
            )
        }
        Mock Write-OperatorPollLog { }

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
        $summary = $cycle['Summary']

        $summary.mailbox_events | Should -Be 1
        $summary.new_events | Should -Be 1
        $summary.dispatches | Should -Be 1
        $summary.messages[0] | Should -Be 'builder-1 (%2) がアイドル。次タスクのディスパッチが必要'
        Should -Invoke Write-OperatorPollLog -Times 1 -Exactly -ParameterFilter {
            $EventName -eq 'operator.poll.idle_dispatch_needed' -and
            $PaneId -eq '%2' -and
            $Message -eq 'builder-1 (%2) がアイドル。次タスクのディスパッチが必要'
        }
    }

    It 'converts v2 mailbox payloads into auditable operator events' {
        $record = ConvertTo-OperatorPollMailboxRecord -MailboxMessage ([ordered]@{
            mailbox_version = 2
            message_id      = 'msg-1'
            correlation_id  = 'corr-1'
            causation_id    = 'cause-1'
            idempotency_key = 'mailbox:v2:winsmux-orchestra:worker-1:pane.idle:abc123'
            message_type    = 'share'
            state           = 'created'
            ttl_seconds     = 300
            ack_required    = $true
            from            = 'worker-1'
            to              = 'Operator'
            timestamp       = '2026-04-07T09:00:00.0000000+09:00'
            content         = [ordered]@{
                session = 'winsmux-orchestra'
                event   = 'pane.idle'
                message = 'worker idle'
                label   = 'worker-1'
                pane_id = '%2'
                role    = 'Worker'
                status  = 'ready'
                data    = [ordered]@{ idle_threshold_seconds = 120 }
            }
        }) -SessionName 'winsmux-orchestra'

        $record.source | Should -Be 'mailbox'
        $record.mailbox_version | Should -Be 2
        $record.mailbox_state | Should -Be 'created'
        $record.message_id | Should -Be 'msg-1'
        $record.correlation_id | Should -Be 'corr-1'
        $record.causation_id | Should -Be 'cause-1'
        $record.idempotency_key | Should -Be 'mailbox:v2:winsmux-orchestra:worker-1:pane.idle:abc123'
        $record.ack_required | Should -Be $true
        $record.data.mailbox_message_id | Should -Be 'msg-1'
        $record.data.mailbox_state | Should -Be 'created'
    }

    It 'ignores malformed v2 mailbox payloads before they reach operator events' {
        $record = ConvertTo-OperatorPollMailboxRecord -MailboxMessage ([ordered]@{
            mailbox_version = 2
            message_type    = 'share'
            state           = 'created'
            content         = [ordered]@{
                session = 'winsmux-orchestra'
                message = 'missing event'
            }
        }) -SessionName 'winsmux-orchestra'

        $record | Should -BeNullOrEmpty
    }

    It 'persists only a closed v2 mailbox workflow acknowledgement with its exact completion tuple' {
        $acknowledgement = [ordered]@{
            schema_version      = 1
            run_id              = 'run-123'
            node_id             = 'inspect'
            idempotency_key     = 'run-123:inspect'
            generation_id       = 'generation-123'
            config_fingerprint  = ('sha256:' + ('a' * 64))
            workflow_fingerprint = ('sha256:' + ('d' * 64))
            source_head         = $script:operatorPollSourceHead
            pane_id             = '%2'
            status              = 'succeeded'
            evidence_ref        = 'workflow-ack:run-123:inspect'
        }
        $payload = [ordered]@{
            mailbox_version = 2
            message_id      = 'workflow-ack-1'
            correlation_id  = 'workflow-ack-1'
            causation_id    = $null
            idempotency_key = 'workflow-completion-1'
            message_type    = 'workflow-completion'
            state           = 'created'
            ttl_seconds     = 300
            ack_required    = $true
            from            = 'builder-1'
            to              = 'Operator'
            timestamp       = '2026-07-22T00:00:00.0000000+00:00'
            content         = [ordered]@{
                session     = 'winsmux-orchestra'
                event       = 'workflow.node.acknowledged'
                message     = 'Declarative workflow completion.'
                label       = 'builder-1'
                pane_id     = '%2'
                role        = 'Builder'
                status      = 'succeeded'
                exit_reason = ''
                data        = $acknowledgement
            }
        }
        $record = ConvertTo-TestAuthenticatedDurableWorkflowRecord -MailboxMessage $payload
        $manifest = Read-OperatorPollManifest -Path $script:operatorPollManifestPath
        $summary = [ordered]@{ new_events = 0; dispatches = 0; completions = 0; approvals = 0; errors = 0; messages = @() }
        Initialize-TestDurableWorkflowRun
        Add-TestDurableWorkflowCompletionProof -MessageId 'workflow-ack-1'
        Mock Write-OrchestraLog { }

        $eventResult = Invoke-OperatorPollEventRecord -Manifest $manifest `
            -ManifestPath $script:operatorPollManifestPath -EventRecord $record -Summary $summary

        $eventResult | Should -BeExactly 'workflow_ack_proof_committed_and_logged'
        $summary.errors | Should -Be 0 -Because ([string]::Join('; ', @($summary.messages)))
        Should -Invoke Write-OrchestraLog -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'workflow.node.acknowledged' -and
            $PaneId -eq '%2' -and
            $Target -eq 'builder-1' -and
            $Data.transport -eq 'mailbox' -and
            $Data.message_id -eq 'workflow-ack-1' -and
            $Data.workflow_fingerprint -eq ('sha256:' + ('d' * 64)) -and
            $Data.evidence_ref -eq 'workflow-ack:run-123:inspect'
        }

        $unknown = $payload | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $unknown.content.data['unexpected'] = 'field'
        (ConvertTo-OperatorPollMailboxRecord -MailboxMessage $unknown -SessionName 'winsmux-orchestra') | Should -BeNullOrEmpty
    }

    It 'AA04 publishes proof v2 from the persisted input lease and operator-observed descendant HEAD' {
        $project = $script:operatorPollTempRoot
        & git -C $project init --quiet
        $LASTEXITCODE | Should -Be 0
        $basePath = Join-Path $project 'publisher-base.txt'
        [IO.File]::WriteAllText($basePath, 'base', [Text.UTF8Encoding]::new($false))
        & git -C $project add -- publisher-base.txt
        & git -C $project -c user.name=winsmux-test -c user.email=winsmux-test@example.invalid commit --quiet -m base
        $LASTEXITCODE | Should -Be 0
        $baseHead = ([string](& git -C $project rev-parse HEAD)).Trim()

        $managedPath = Join-Path $project '.worktrees\publisher-implement'
        & git -C $project worktree add --quiet -b publisher-implement $managedPath $baseHead
        $LASTEXITCODE | Should -Be 0
        $outputPath = Join-Path $managedPath 'publisher-output.txt'
        [IO.File]::WriteAllText($outputPath, 'output', [Text.UTF8Encoding]::new($false))
        & git -C $managedPath add -- publisher-output.txt
        & git -C $managedPath -c user.name=winsmux-test -c user.email=winsmux-test@example.invalid commit --quiet -m output
        $LASTEXITCODE | Should -Be 0
        $outputHead = ([string](& git -C $managedPath rev-parse HEAD)).Trim()
        & git -C $managedPath merge-base --is-ancestor $baseHead $outputHead
        $LASTEXITCODE | Should -Be 0
        $outputHead | Should -Not -BeExactly $baseHead

        $runRoot = Join-Path $project '.winsmux\workflow-runs\run-123'
        [IO.Directory]::CreateDirectory($runRoot) | Out-Null
        $run = [ordered]@{
            schema_version = 3; workflow_id = 'bugfix'; recipe_ref = 'bugfix-two-slot'; run_id = 'run-123'
            state = 'running'; generation_id = 'generation-123'
            config_fingerprint = ('sha256:' + ('a' * 64)); workflow_fingerprint = ('sha256:' + ('d' * 64))
            source_head = $baseHead; task_sha256 = ('sha256:' + ('c' * 64)); task_byte_count = 24
            resolved_bindings = [ordered]@{ implement = 'builder-1' }
            normalized_snapshot = [ordered]@{
                resolved_bindings = [ordered]@{ implement = 'builder-1' }
                application_contract = [ordered]@{
                    implement = [ordered]@{
                        pane_ref = 'implement'; slot_id = 'builder-1'
                        worktree = [ordered]@{ mode = 'managed'; name = 'publisher-implement' }
                        actual_capabilities = [ordered]@{
                            supports_file_edit = $true
                            supports_verification = $false
                            supports_structured_result = $false
                        }
                    }
                }
                nodes = @(
                    [ordered]@{
                        node_id = 'inspect'; pane_ref = 'implement'; action = 'operator-dispatch'
                        required_capability = 'file-edit'; allowed_worktree_modes = @('managed')
                        may_advance_head = $true
                    }
                )
            }
            pane_head_leases = [ordered]@{
                implement = [ordered]@{ base_head = $baseHead; admitted_head = $baseHead }
            }
            nodes = [ordered]@{
                inspect = [ordered]@{
                    node_id = 'inspect'; idempotency_key = 'run-123:inspect'; state = 'dispatching'
                    attempt = 1; pane_ref = 'implement'; action = 'operator-dispatch'
                    required_capability = 'file-edit'; allowed_worktree_modes = @('managed')
                    may_advance_head = $true
                    execution_lease = [ordered]@{
                        pane_ref = 'implement'; slot_id = 'builder-1'; worktree_mode = 'managed'
                        input_head = $baseHead
                        dependency_inputs = @(); dependency_heads = [ordered]@{}
                    }
                }
            }
        }
        [IO.File]::WriteAllText((Join-Path $runRoot 'state.json'), ($run | ConvertTo-Json -Compress -Depth 30), [Text.UTF8Encoding]::new($false))

        $payload = New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-aa04'
        $payload.content.data.source_head = $baseHead
        $record = ConvertTo-TestAuthenticatedDurableWorkflowRecord -MailboxMessage $payload
        $manifest = [ordered]@{
            Session = [ordered]@{
                name = 'winsmux-orchestra'; generation_id = 'generation-123'; project_dir = $project
            }
            Panes = [ordered]@{
                'builder-1' = [ordered]@{
                    pane_id = '%2'; role = 'Builder'; launch_dir = $managedPath
                    builder_worktree_path = $managedPath
                    supports_file_edit = 'true'; supports_verification = 'false'; supports_structured_result = 'false'
                }
            }
        }
        $summary = [ordered]@{ new_events = 0; dispatches = 0; completions = 0; approvals = 0; errors = 0; messages = @() }
        Mock Write-OrchestraLog { }
        $paneContext = Get-OperatorPollPaneContext -Manifest $manifest `
            -ManifestPath $script:operatorPollManifestPath -EventRecord $record
        $verifiedPendingPath = Resolve-DeclarativeWorkflowMailboxPendingPath -ProjectDir $project `
            -Channel ([string]$record.durable_pending_channel) -MessageId ([string]$record.message_id)
        $verifiedPendingPath | Should -BeExactly ([string]$record.durable_pending_path)
        $pendingBytes = [IO.File]::ReadAllBytes($verifiedPendingPath)
        (Get-DeclarativeWorkflowSha256Digest -Bytes $pendingBytes) |
            Should -BeExactly ([string]$record.durable_pending_sha256)
        $mailboxMessage = ([Text.UTF8Encoding]::new($false, $true).GetString($pendingBytes)) |
            ConvertFrom-WinsmuxJson -AsHashtable -Depth 30 -ErrorAction Stop
        $fromPending = ConvertTo-OperatorPollMailboxRecord -MailboxMessage $mailboxMessage `
            -SessionName 'winsmux-orchestra'
        $candidate = Copy-DeclarativeWorkflowValue $record
        foreach ($field in @(
                'durable_pending_path', 'durable_pending_channel',
                'durable_pending_message_id', 'durable_pending_sha256'
            )) {
            $candidate.Remove($field) | Out-Null
        }
        (ConvertTo-DeclarativeWorkflowCanonicalJson -Value $candidate) |
            Should -BeExactly (ConvertTo-DeclarativeWorkflowCanonicalJson -Value $fromPending)
        (Test-OperatorPollWorkflowAcknowledgementRecord -EventRecord $candidate `
                -PaneContext $paneContext -SessionName 'winsmux-orchestra') | Should -BeTrue

        $eventResult = Invoke-OperatorPollEventRecord -Manifest $manifest `
            -ManifestPath $script:operatorPollManifestPath -EventRecord $record -Summary $summary

        $eventResult | Should -BeExactly 'workflow_ack_proof_committed_and_logged'
        $summary.errors | Should -Be 0 -Because ([string]::Join('; ', @($summary.messages)))
        $proof = Read-DeclarativeWorkflowDurableProof -ProjectDir $project -Run $null -RunId 'run-123' -Kind Completion -NodeId 'inspect'
        $proof.schema_version | Should -Be 2
        $proof.input_head | Should -BeExactly $baseHead
        $proof.output_head | Should -BeExactly $outputHead
        $proof.message_id | Should -BeExactly 'workflow-ack-aa04'
        Should -Invoke Write-OrchestraLog -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'workflow.node.acknowledged' -and $PaneId -eq '%2' -and $Target -eq 'builder-1'
        }
    }

    It 'AA05 publishes a no-commit managed outcome without consuming dirty worktree bytes' {
        $fixture = New-TestManagedPublisherFixture -MessageId 'workflow-ack-aa05'
        $dirtyPath = Join-Path $fixture.ManagedPath 'dirty-output.txt'
        [IO.File]::WriteAllText($dirtyPath, 'uncommitted output', [Text.UTF8Encoding]::new($false))
        $run = Read-DeclarativeWorkflowRunState -ProjectDir $fixture.ProjectDir -RunId 'run-123'

        $proof = Publish-OperatorPollWorkflowCompletionProof -Manifest $fixture.Manifest -PaneContext $fixture.PaneContext `
            -ProjectDir $fixture.ProjectDir -Run $run -Acknowledgement $fixture.Acknowledgement

        $proof.input_head | Should -BeExactly $fixture.BaseHead
        $proof.output_head | Should -BeExactly $fixture.BaseHead
        Test-Path -LiteralPath $dirtyPath -PathType Leaf | Should -BeTrue
        ([IO.File]::ReadAllText($dirtyPath, [Text.UTF8Encoding]::new($false, $true))) | Should -BeExactly 'uncommitted output'
    }

    It 'AA06 rejects managed rewind divergence and unresolved input before proof publication' {
        $fixture = New-TestManagedPublisherFixture -MessageId 'workflow-ack-aa06'
        $outputPath = Join-Path $fixture.ManagedPath 'output.txt'
        [IO.File]::WriteAllText($outputPath, 'managed output', [Text.UTF8Encoding]::new($false))
        & git -C $fixture.ManagedPath add -- output.txt
        & git -C $fixture.ManagedPath -c user.name=winsmux-test -c user.email=winsmux-test@example.invalid commit --quiet -m output
        $LASTEXITCODE | Should -Be 0
        $managedOutput = ([string](& git -C $fixture.ManagedPath rev-parse HEAD)).Trim()

        $fixture.Run.nodes.inspect.execution_lease.input_head = $managedOutput
        $fixture.Run.pane_head_leases.implement.admitted_head = $managedOutput
        [IO.File]::WriteAllText($fixture.StatePath, ($fixture.Run | ConvertTo-Json -Compress -Depth 30), [Text.UTF8Encoding]::new($false))
        & git -C $fixture.ManagedPath checkout --quiet --detach $fixture.BaseHead
        $LASTEXITCODE | Should -Be 0
        $rewindRun = Read-DeclarativeWorkflowRunState -ProjectDir $fixture.ProjectDir -RunId 'run-123'
        {
            Publish-OperatorPollWorkflowCompletionProof -Manifest $fixture.Manifest -PaneContext $fixture.PaneContext `
                -ProjectDir $fixture.ProjectDir -Run $rewindRun -Acknowledgement $fixture.Acknowledgement
        } | Should -Throw '*output HEAD is not an admitted descendant*'

        & git -C $fixture.ManagedPath checkout --quiet publisher-matrix
        $LASTEXITCODE | Should -Be 0
        $rootOutputPath = Join-Path $fixture.ProjectDir 'root-output.txt'
        [IO.File]::WriteAllText($rootOutputPath, 'diverged root output', [Text.UTF8Encoding]::new($false))
        & git -C $fixture.ProjectDir add -- root-output.txt
        & git -C $fixture.ProjectDir -c user.name=winsmux-test -c user.email=winsmux-test@example.invalid commit --quiet -m root-output
        $LASTEXITCODE | Should -Be 0
        $divergedInput = ([string](& git -C $fixture.ProjectDir rev-parse HEAD)).Trim()
        & git -C $fixture.ProjectDir merge-base --is-ancestor $divergedInput $managedOutput
        $LASTEXITCODE | Should -Be 1
        $fixture.Run.nodes.inspect.execution_lease.input_head = $divergedInput
        $fixture.Run.pane_head_leases.implement.admitted_head = $divergedInput
        [IO.File]::WriteAllText($fixture.StatePath, ($fixture.Run | ConvertTo-Json -Compress -Depth 30), [Text.UTF8Encoding]::new($false))
        $divergedRun = Read-DeclarativeWorkflowRunState -ProjectDir $fixture.ProjectDir -RunId 'run-123'
        {
            Publish-OperatorPollWorkflowCompletionProof -Manifest $fixture.Manifest -PaneContext $fixture.PaneContext `
                -ProjectDir $fixture.ProjectDir -Run $divergedRun -Acknowledgement $fixture.Acknowledgement
        } | Should -Throw '*output HEAD is not an admitted descendant*'

        $missingInput = 'e' * 40
        $fixture.Run.nodes.inspect.execution_lease.input_head = $missingInput
        $fixture.Run.pane_head_leases.implement.admitted_head = $missingInput
        [IO.File]::WriteAllText($fixture.StatePath, ($fixture.Run | ConvertTo-Json -Compress -Depth 30), [Text.UTF8Encoding]::new($false))
        $missingRun = Read-DeclarativeWorkflowRunState -ProjectDir $fixture.ProjectDir -RunId 'run-123'
        {
            Publish-OperatorPollWorkflowCompletionProof -Manifest $fixture.Manifest -PaneContext $fixture.PaneContext `
                -ProjectDir $fixture.ProjectDir -Run $missingRun -Acknowledgement $fixture.Acknowledgement
        } | Should -Throw '*output HEAD is not an admitted descendant*'
        Test-Path -LiteralPath (Join-Path $fixture.ProjectDir '.winsmux\workflow-runs\run-123\proofs\completion\inspect.json') -PathType Leaf |
            Should -BeFalse
    }

    It 'AA07 rejects changed read-only HEAD and incomplete application capability tuples' {
        Initialize-TestDurableWorkflowRun
        $run = Read-DeclarativeWorkflowRunState -ProjectDir $script:operatorPollTempRoot -RunId 'run-123'
        $acknowledgement = (New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-aa07-read-only').content.data
        $acknowledgement['transport'] = 'mailbox'
        $acknowledgement['message_id'] = 'workflow-ack-aa07-read-only'
        $manifest = Read-OperatorPollManifest -Path $script:operatorPollManifestPath
        $paneContext = [ordered]@{
            label = 'builder-1'; pane_id = '%2'; worktree_path = $script:operatorPollTempRoot
        }
        $changedPath = Join-Path $script:operatorPollTempRoot 'read-only-change.txt'
        [IO.File]::WriteAllText($changedPath, 'changed', [Text.UTF8Encoding]::new($false))
        & git -C $script:operatorPollTempRoot add -- read-only-change.txt
        & git -C $script:operatorPollTempRoot -c user.name=winsmux-test -c user.email=winsmux-test@example.invalid commit --quiet -m read-only-change
        $LASTEXITCODE | Should -Be 0
        {
            Publish-OperatorPollWorkflowCompletionProof -Manifest $manifest -PaneContext $paneContext `
                -ProjectDir $script:operatorPollTempRoot -Run $run -Acknowledgement $acknowledgement
        } | Should -Throw '*read-only action changed HEAD*'

        $fixture = New-TestManagedPublisherFixture -MessageId 'workflow-ack-aa07-capability'
        $fixture.Run.normalized_snapshot.application_contract.implement.actual_capabilities.Remove('supports_file_edit')
        [IO.File]::WriteAllText($fixture.StatePath, ($fixture.Run | ConvertTo-Json -Compress -Depth 30), [Text.UTF8Encoding]::new($false))
        $incompleteRun = Read-DeclarativeWorkflowRunState -ProjectDir $fixture.ProjectDir -RunId 'run-123'
        {
            Publish-OperatorPollWorkflowCompletionProof -Manifest $fixture.Manifest -PaneContext $fixture.PaneContext `
                -ProjectDir $fixture.ProjectDir -Run $incompleteRun -Acknowledgement $fixture.Acknowledgement
        } | Should -Throw '*manifest capability is missing or malformed*'
        Test-Path -LiteralPath (Join-Path $fixture.ProjectDir '.winsmux\workflow-runs\run-123\proofs\completion\inspect.json') -PathType Leaf |
            Should -BeFalse
    }

    It 'AC05 publishes a consumer proof after validating distinct producer worktrees independently' {
        $fixture = New-TestManagedPublisherFixture -MessageId 'workflow-ack-ac05'
        $project = $fixture.ProjectDir
        $baseHead = $fixture.BaseHead
        $producerOnePath = Join-Path $project '.worktrees\ac05-producer-one'
        $producerTwoPath = Join-Path $project '.worktrees\ac05-producer-two'
        & git -C $project worktree add --quiet -b ac05-producer-one $producerOnePath $baseHead
        $LASTEXITCODE | Should -Be 0
        & git -C $project worktree add --quiet -b ac05-producer-two $producerTwoPath $baseHead
        $LASTEXITCODE | Should -Be 0
        [IO.File]::WriteAllText((Join-Path $producerOnePath 'producer-one.txt'), 'one', [Text.UTF8Encoding]::new($false))
        & git -C $producerOnePath add -- producer-one.txt
        & git -C $producerOnePath -c user.name=winsmux-test -c user.email=winsmux-test@example.invalid commit --quiet -m producer-one
        $producerOneHead = ([string](& git -C $producerOnePath rev-parse HEAD)).Trim()
        [IO.File]::WriteAllText((Join-Path $producerTwoPath 'producer-two.txt'), 'two', [Text.UTF8Encoding]::new($false))
        & git -C $producerTwoPath add -- producer-two.txt
        & git -C $producerTwoPath -c user.name=winsmux-test -c user.email=winsmux-test@example.invalid commit --quiet -m producer-two
        $producerTwoHead = ([string](& git -C $producerTwoPath rev-parse HEAD)).Trim()

        $run = Copy-DeclarativeWorkflowValue $fixture.Run
        foreach ($producer in @(
                [ordered]@{
                    pane_ref = 'producer-one'; node_id = 'producer-one-node'; slot_id = 'builder-2'
                    pane_id = '%3'; worktree_name = 'ac05-producer-one'; output_head = $producerOneHead
                    message_id = 'workflow-ack-ac05-producer-one'
                }
                [ordered]@{
                    pane_ref = 'producer-two'; node_id = 'producer-two-node'; slot_id = 'builder-3'
                    pane_id = '%4'; worktree_name = 'ac05-producer-two'; output_head = $producerTwoHead
                    message_id = 'workflow-ack-ac05-producer-two'
                }
            )) {
            $run.resolved_bindings[$producer.pane_ref] = $producer.slot_id
            $run.normalized_snapshot.resolved_bindings[$producer.pane_ref] = $producer.slot_id
            $run.normalized_snapshot.application_contract[$producer.pane_ref] = [ordered]@{
                pane_ref = $producer.pane_ref; slot_id = $producer.slot_id
                worktree = [ordered]@{ mode = 'managed'; name = $producer.worktree_name }
                actual_capabilities = [ordered]@{
                    supports_file_edit = $true; supports_verification = $false
                    supports_structured_result = $false
                }
            }
            $run.pane_head_leases[$producer.pane_ref] = [ordered]@{
                base_head = $baseHead; admitted_head = $producer.output_head
            }
            $proof = [ordered]@{
                schema_version = 2; run_id = 'run-123'; node_id = $producer.node_id
                idempotency_key = "run-123:$($producer.node_id)"; generation_id = 'generation-123'
                config_fingerprint = ('sha256:' + ('a' * 64)); workflow_fingerprint = ('sha256:' + ('d' * 64))
                source_head = $baseHead; input_head = $baseHead; output_head = $producer.output_head
                pane_id = $producer.pane_id; status = 'succeeded'
                evidence_ref = "workflow-ack:run-123:$($producer.node_id)"
                transport = 'mailbox'; message_id = $producer.message_id
            }
            $node = Copy-DeclarativeWorkflowValue $run.nodes.inspect
            $node.node_id = $producer.node_id
            $node.idempotency_key = "run-123:$($producer.node_id)"
            $node.pane_ref = $producer.pane_ref
            $node.depends_on = @()
            $node.state = 'succeeded'
            $node.agent_cli_session_id = $producer.pane_id
            $node.evidence_refs = @($proof.evidence_ref)
            $node.completion_proof = $proof
            $node.application_outcome = [ordered]@{
                input_head = $baseHead; output_head = $producer.output_head
            }
            $node.execution_lease = [ordered]@{
                pane_ref = $producer.pane_ref; slot_id = $producer.slot_id
                worktree_mode = 'managed'; input_head = $baseHead
                dependency_inputs = @(); dependency_heads = [ordered]@{}
            }
            $run.nodes[$producer.node_id] = $node
            $definition = Copy-DeclarativeWorkflowValue $run.normalized_snapshot.nodes[0]
            $definition.node_id = $producer.node_id
            $definition.idempotency_key = "run-123:$($producer.node_id)"
            $definition.pane_ref = $producer.pane_ref
            $definition.depends_on = @()
            $producer['definition'] = $definition
            $producer['proof'] = $proof
        }
        $run.nodes.inspect.depends_on = @('producer-one-node', 'producer-two-node')
        $run.nodes.inspect.execution_lease.dependency_inputs = @(
            [ordered]@{
                node_id = 'producer-one-node'; pane_ref = 'producer-one'; output_head = $producerOneHead
                evidence_ref = 'workflow-ack:run-123:producer-one-node'
            }
            [ordered]@{
                node_id = 'producer-two-node'; pane_ref = 'producer-two'; output_head = $producerTwoHead
                evidence_ref = 'workflow-ack:run-123:producer-two-node'
            }
        )
        $run.nodes.inspect.execution_lease.dependency_heads = [ordered]@{
            'producer-one' = $producerOneHead; 'producer-two' = $producerTwoHead
        }
        $inspectDefinition = $run.normalized_snapshot.nodes[0]
        $inspectDefinition.depends_on = @('producer-one-node', 'producer-two-node')
        $producerOneDefinition = Copy-DeclarativeWorkflowValue $inspectDefinition
        $producerOneDefinition.node_id = 'producer-one-node'
        $producerOneDefinition.idempotency_key = 'run-123:producer-one-node'
        $producerOneDefinition.pane_ref = 'producer-one'
        $producerOneDefinition.depends_on = @()
        $producerTwoDefinition = Copy-DeclarativeWorkflowValue $producerOneDefinition
        $producerTwoDefinition.node_id = 'producer-two-node'
        $producerTwoDefinition.idempotency_key = 'run-123:producer-two-node'
        $producerTwoDefinition.pane_ref = 'producer-two'
        $run.normalized_snapshot.nodes = @($producerOneDefinition, $producerTwoDefinition, $inspectDefinition)

        $manifest = Copy-DeclarativeWorkflowValue $fixture.Manifest
        $manifest.Panes['builder-2'] = [ordered]@{
            pane_id = '%3'; role = 'Builder'; launch_dir = $producerOnePath
            builder_worktree_path = $producerOnePath
            supports_file_edit = 'true'; supports_verification = 'false'; supports_structured_result = 'false'
        }
        $manifest.Panes['builder-3'] = [ordered]@{
            pane_id = '%4'; role = 'Builder'; launch_dir = $producerTwoPath
            builder_worktree_path = $producerTwoPath
            supports_file_edit = 'true'; supports_verification = 'false'; supports_structured_result = 'false'
        }

        $published = Publish-OperatorPollWorkflowCompletionProof -Manifest $manifest `
            -PaneContext $fixture.PaneContext -ProjectDir $project -Run $run `
            -Acknowledgement $fixture.Acknowledgement

        $published.message_id | Should -BeExactly 'workflow-ack-ac05'
        $published.input_head | Should -BeExactly $baseHead
        $published.output_head | Should -BeExactly $baseHead
    }

    It 'AB01 rejects workflow acknowledgement proof publication from events.jsonl and non-durable mailbox input' {
        Initialize-TestDurableWorkflowRun
        $manifest = Read-OperatorPollManifest -Path $script:operatorPollManifestPath
        $summary = [ordered]@{ new_events = 0; dispatches = 0; completions = 0; approvals = 0; errors = 0; messages = @() }
        $eventsRecord = ConvertTo-OperatorPollMailboxRecord -MailboxMessage (
            New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-ab01-events'
        ) -SessionName 'winsmux-orchestra'
        $eventsRecord['source'] = 'events_jsonl'
        $pipeRecord = ConvertTo-OperatorPollMailboxRecord -MailboxMessage (
            New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-ab01-pipe'
        ) -SessionName 'winsmux-orchestra'
        Mock Write-OrchestraLog { throw 'untrusted workflow acknowledgement input must not be logged' }

        $eventResult = Invoke-OperatorPollEventRecord -Manifest $manifest -ManifestPath $script:operatorPollManifestPath `
            -EventRecord $eventsRecord -Summary $summary
        $pipeResult = Invoke-OperatorPollEventRecord -Manifest $manifest -ManifestPath $script:operatorPollManifestPath `
            -EventRecord $pipeRecord -Summary $summary

        $eventResult | Should -BeExactly 'workflow_ack_untrusted_source'
        $pipeResult | Should -BeExactly 'workflow_ack_untrusted_source'
        $summary.errors | Should -Be 2
        Read-DeclarativeWorkflowDurableProof -ProjectDir $script:operatorPollTempRoot -Run $null -RunId 'run-123' `
            -Kind Completion -NodeId 'inspect' | Should -BeNullOrEmpty
        Should -Invoke Write-OrchestraLog -Times 0 -Exactly
    }

    It 'AB09 preserves an authenticated durable pending acknowledgement when proof admission rejects' {
        Initialize-TestDurableWorkflowRun
        $messageId = 'workflow-ack-ab09-retry'
        $payload = New-TestDurableWorkflowEnvelope -MessageId $messageId
        $channel = Get-OperatorPollMailboxChannel -SessionName 'winsmux-orchestra'
        $pendingRoot = Join-Path $script:operatorPollTempRoot ".winsmux\mailbox\$channel\pending"
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        $pendingPath = Join-Path $pendingRoot "$messageId.json"
        $pendingBytes = [Text.UTF8Encoding]::new($false).GetBytes(($payload | ConvertTo-Json -Compress -Depth 20))
        [IO.File]::WriteAllBytes($pendingPath, $pendingBytes)

        $changedPath = Join-Path $script:operatorPollTempRoot 'ab09-read-only-change.txt'
        [IO.File]::WriteAllText($changedPath, 'changed after dispatch', [Text.UTF8Encoding]::new($false))
        & git -C $script:operatorPollTempRoot add -- ab09-read-only-change.txt
        & git -C $script:operatorPollTempRoot -c user.name=winsmux-test -c user.email=winsmux-test@example.invalid `
            commit --quiet -m ab09-read-only-change
        $LASTEXITCODE | Should -Be 0
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { throw 'rejected proof admission must not log acceptance' }

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 `
            -ProcessedEventSignatures ([ordered]@{})

        $cycle.Summary.errors | Should -Be 1
        Test-Path -LiteralPath $pendingPath -PathType Leaf | Should -BeTrue
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($pendingPath)) |
            Should -BeExactly ([Convert]::ToBase64String($pendingBytes))
        $cycle.ProcessedEventSignatures.Count | Should -Be 0
        Read-DeclarativeWorkflowDurableProof -ProjectDir $script:operatorPollTempRoot -Run $null -RunId 'run-123' `
            -Kind Completion -NodeId 'inspect' | Should -BeNullOrEmpty
        Should -Invoke Write-OrchestraLog -Times 0 -Exactly
    }

    It 'I01 accepts only managed GUID-N or legacy stable generation IDs in a workflow completion envelope' {
        foreach ($generationId in @('0123456789abcdef0123456789abcdef', 'generation-123')) {
            $record = ConvertTo-OperatorPollMailboxRecord -MailboxMessage (New-TestDurableWorkflowEnvelope `
                    -MessageId ('generation-id-' + $generationId) -GenerationId $generationId) -SessionName 'winsmux-orchestra'
            $record | Should -Not -BeNullOrEmpty
            $record.data.generation_id | Should -BeExactly $generationId
        }

        foreach ($generationId in @(
                '123',
                '0123456789abcdef0123456789abcde',
                '0123456789abcdef0123456789abcdef0',
                '0123456789abcdef0123456789abcdeF',
                '0123456789abcdef0123456789abcdeg',
                '-generation-123',
                ' generation-123',
                'generation-123 ',
                '世代-123'
            )) {
            (ConvertTo-OperatorPollMailboxRecord -MailboxMessage (New-TestDurableWorkflowEnvelope `
                    -MessageId 'generation-id-invalid' -GenerationId $generationId) -SessionName 'winsmux-orchestra') | Should -BeNullOrEmpty
        }

        $managedRecord = ConvertTo-OperatorPollMailboxRecord -MailboxMessage (New-TestDurableWorkflowEnvelope `
                -MessageId 'generation-id-exact-mismatch' -GenerationId '0123456789abcdef0123456789abcdef') -SessionName 'winsmux-orchestra'
        $manifest = Read-OperatorPollManifest -Path $script:operatorPollManifestPath
        $summary = [ordered]@{ new_events = 0; dispatches = 0; completions = 0; approvals = 0; errors = 0; messages = @() }
        Mock Write-OrchestraLog { throw 'a distinct managed generation must not become durable evidence for the legacy runtime generation' }

        Invoke-OperatorPollEventRecord -Manifest $manifest -ManifestPath $script:operatorPollManifestPath -EventRecord $managedRecord -Summary $summary

        $summary.errors | Should -Be 1
        Should -Invoke Write-OrchestraLog -Times 0 -Exactly
    }

    It 'rejects a stale workflow acknowledgement pane ID even when its label and envelope agree' {
        $acknowledgement = [ordered]@{
            schema_version      = 1
            run_id              = 'run-123'
            node_id             = 'inspect'
            idempotency_key     = 'run-123:inspect'
            generation_id       = 'generation-123'
            config_fingerprint  = ('sha256:' + ('a' * 64))
            workflow_fingerprint = ('sha256:' + ('d' * 64))
            source_head         = $script:operatorPollSourceHead
            pane_id             = '%2'
            status              = 'succeeded'
            evidence_ref        = 'workflow-ack:run-123:inspect'
        }
        $payload = [ordered]@{
            mailbox_version = 2; message_id = 'workflow-ack-stale'; correlation_id = 'workflow-ack-stale'; causation_id = $null
            idempotency_key = 'workflow-completion-stale'; message_type = 'workflow-completion'; state = 'created'; ttl_seconds = 300
            ack_required = $true; from = 'builder-1'; to = 'Operator'; timestamp = '2026-07-22T00:00:00.0000000+00:00'
            content = [ordered]@{
                session = 'winsmux-orchestra'; event = 'workflow.node.acknowledged'; message = 'Declarative workflow completion.'
                label = 'builder-1'; pane_id = '%2'; role = 'Builder'; status = 'succeeded'; exit_reason = ''; data = $acknowledgement
            }
        }
        $record = ConvertTo-OperatorPollMailboxRecord -MailboxMessage $payload -SessionName 'winsmux-orchestra'
        $manifest = Read-OperatorPollManifest -Path $script:operatorPollManifestPath
        $manifest.Panes['builder-1'].pane_id = '%9'
        $summary = [ordered]@{ new_events = 0; dispatches = 0; completions = 0; approvals = 0; errors = 0; messages = @() }
        Mock Write-OrchestraLog { throw 'stale pane acknowledgement must not become durable evidence' }

        Invoke-OperatorPollEventRecord -Manifest $manifest -ManifestPath $script:operatorPollManifestPath -EventRecord $record -Summary $summary

        $summary.errors | Should -Be 1
        Should -Invoke Write-OrchestraLog -Times 0 -Exactly
    }

    It 'F02 deduplicates exact workflow ACK replay without collapsing different nodes on the same pane' {
        $first = ConvertTo-OperatorPollMailboxRecord -MailboxMessage (New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-node-a' -NodeId 'inspect') -SessionName 'winsmux-orchestra'
        $replay = ConvertTo-OperatorPollMailboxRecord -MailboxMessage (New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-node-a' -NodeId 'inspect') -SessionName 'winsmux-orchestra'
        $secondNode = ConvertTo-OperatorPollMailboxRecord -MailboxMessage (New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-node-b' -NodeId 'verify') -SessionName 'winsmux-orchestra'

        (Get-OperatorPollEventSignature -EventRecord $first) | Should -BeExactly (Get-OperatorPollEventSignature -EventRecord $replay)
        (Get-OperatorPollEventSignature -EventRecord $first) | Should -Not -BeExactly (Get-OperatorPollEventSignature -EventRecord $secondNode)
    }

    It 'F02 keys non-workflow mailbox v2 records by message_id before legacy display fields' {
        $first = [ordered]@{
            event = 'pane.idle'; pane_id = '%2'; label = 'builder-1'; status = 'ready'; message = 'same display'
            source = 'mailbox'; mailbox_version = 2; message_id = 'mailbox-v2-first'
        }
        $replay = [ordered]@{
            event = 'pane.idle'; pane_id = '%2'; label = 'builder-1'; status = 'ready'; message = 'same display'
            source = 'mailbox'; mailbox_version = 2; message_id = 'mailbox-v2-first'
        }
        $second = [ordered]@{
            event = 'pane.idle'; pane_id = '%2'; label = 'builder-1'; status = 'ready'; message = 'same display'
            source = 'mailbox'; mailbox_version = 2; message_id = 'mailbox-v2-second'
        }

        (Get-OperatorPollEventSignature -EventRecord $first) | Should -BeExactly (Get-OperatorPollEventSignature -EventRecord $replay)
        (Get-OperatorPollEventSignature -EventRecord $first) | Should -Not -BeExactly (Get-OperatorPollEventSignature -EventRecord $second)
    }

    It 'O02 commits a valid workflow completion after more than five minutes of poll downtime' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        $pendingPath = Join-Path $pendingRoot 'workflow-ack-stale-publication.json'
        $payload = New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-stale-publication'
        $payload.timestamp = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o')
        [IO.File]::WriteAllText($pendingPath, ($payload | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))
        Initialize-TestDurableWorkflowRun
        Add-TestDurableWorkflowCompletionProof -MessageId 'workflow-ack-stale-publication'
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { }

        $result = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})

        $result.Summary.mailbox_events | Should -Be 1
        Test-Path -LiteralPath $pendingPath | Should -BeFalse
        $proofPath = Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs\completion\inspect.json'
        Test-Path -LiteralPath $proofPath -PathType Leaf | Should -BeTrue
        $proof = Read-DeclarativeWorkflowDurableProof -ProjectDir $script:operatorPollTempRoot -Run $null -RunId 'run-123' -Kind Completion -NodeId 'inspect'
        $proof.message_id | Should -BeExactly 'workflow-ack-stale-publication'
        Should -Invoke Write-OrchestraLog -Times 1 -Exactly
    }

    It 'P03 preserves authenticated pending completion when the versioned execution lease is missing' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        $pendingPath = Join-Path $pendingRoot 'workflow-ack-p03-raw.json'
        [IO.File]::WriteAllText($pendingPath, ((New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-p03-raw') | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))
        Initialize-TestDurableWorkflowRun
        $runPath = Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\state.json'
        $invalidRun = Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        $invalidRun.nodes.inspect.Remove('execution_lease')
        [IO.File]::WriteAllText($runPath, ($invalidRun | ConvertTo-Json -Compress -Depth 30), [Text.UTF8Encoding]::new($false))
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { throw 'raw pending completion must not be logged' }

        $result = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})

        $result.Summary.errors | Should -BeGreaterThan 0
        Test-Path -LiteralPath $pendingPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs\completion\inspect.json') -PathType Leaf | Should -BeFalse
        Should -Invoke Write-OrchestraLog -Times 0 -Exactly
    }

    It 'P02 refuses a prepared pending junction before read delete log or proof effects' {
        Initialize-TestDurableWorkflowRun
        $channelRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator'
        [IO.Directory]::CreateDirectory($channelRoot) | Out-Null
        $external = Join-Path $script:operatorPollTempRoot 'external-pending'
        [IO.Directory]::CreateDirectory($external) | Out-Null
        $externalPath = Join-Path $external 'workflow-ack-p02.json'
        $payload = New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-p02'
        [IO.File]::WriteAllText($externalPath, ($payload | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))
        $before = [IO.File]::ReadAllBytes($externalPath)
        $junction = $null
        try {
            $junction = New-Item -ItemType Junction -Path (Join-Path $channelRoot 'pending') -Target $external -ErrorAction Stop
            Mock Receive-OperatorPollMailboxMessages { @() }
            Mock Write-OrchestraLog { throw 'unsafe mailbox must not reach log' }
            $result = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
            $result.Summary.mailbox_events | Should -Be 0
            Should -Invoke Write-OrchestraLog -Times 0 -Exactly
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($externalPath)) | Should -BeExactly ([Convert]::ToBase64String($before))
            Test-Path -LiteralPath (Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs') | Should -BeFalse
        } finally {
            if ($null -ne $junction) { $junction.Delete() }
        }

        $pendingRoot = Join-Path $channelRoot 'pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        $leaf = Join-Path $pendingRoot 'workflow-ack-p02.json'
        $junction = $null
        try {
            $junction = New-Item -ItemType Junction -Path $leaf -Target $external -ErrorAction Stop
            $leafResult = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
            $leafResult.Summary.mailbox_events | Should -Be 0
            Should -Invoke Write-OrchestraLog -Times 0 -Exactly
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($externalPath)) | Should -BeExactly ([Convert]::ToBase64String($before))
            Test-Path -LiteralPath (Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs') | Should -BeFalse
        } finally {
            if ($null -ne $junction) { $junction.Delete() }
        }
    }

    It 'J01 admits a live completion after twenty sorted poison files and deletes every terminal-invalid partition without effects' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        $poisonPaths = @()
        foreach ($index in 1..20) {
            $poisonPath = Join-Path $pendingRoot ('a-poison-{0:d2}.json' -f $index)
            [IO.File]::WriteAllText($poisonPath, '{invalid', [Text.UTF8Encoding]::new($false))
            $poisonPaths += $poisonPath
        }
        $livePath = Join-Path $pendingRoot 'workflow-ack-j01-live.json'
        $livePayload = New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-j01-live'
        [IO.File]::WriteAllText($livePath, ($livePayload | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))

        $records = @(Receive-OperatorPollDurableWorkflowMessages -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' -MaxMessages 1)

        $records.Count | Should -Be 1
        $records[0].message_id | Should -BeExactly 'workflow-ack-j01-live'
        foreach ($poisonPath in $poisonPaths) {
            Test-Path -LiteralPath $poisonPath -PathType Leaf | Should -BeFalse
        }
        Test-Path -LiteralPath $livePath -PathType Leaf | Should -BeTrue
        [IO.File]::Delete($livePath)

        $terminalCases = @(
            [PSCustomObject]@{ Name = 'filename'; FileName = '0-invalid-name.json'; Write = { param($Path) [IO.File]::WriteAllText($Path, '{}', [Text.UTF8Encoding]::new($false)) } },
            [PSCustomObject]@{ Name = 'empty-size'; FileName = 'invalid-size-empty.json'; Write = { param($Path) [IO.File]::WriteAllBytes($Path, [byte[]]@()) } },
            [PSCustomObject]@{ Name = 'over-limit-size'; FileName = 'invalid-size-large.json'; Write = { param($Path) [IO.File]::WriteAllBytes($Path, [byte[]]::new(65537)) } },
            [PSCustomObject]@{ Name = 'nul'; FileName = 'invalid-nul.json'; Write = { param($Path) [IO.File]::WriteAllBytes($Path, [byte[]](0x7b, 0x00, 0x7d)) } },
            [PSCustomObject]@{ Name = 'utf8'; FileName = 'invalid-utf8.json'; Write = { param($Path) [IO.File]::WriteAllBytes($Path, [byte[]](0xff, 0xfe)) } },
            [PSCustomObject]@{ Name = 'json'; FileName = 'invalid-json.json'; Write = { param($Path) [IO.File]::WriteAllText($Path, '{invalid', [Text.UTF8Encoding]::new($false)) } },
            [PSCustomObject]@{ Name = 'envelope'; FileName = 'invalid-envelope.json'; Write = { param($Path) [IO.File]::WriteAllText($Path, '{}', [Text.UTF8Encoding]::new($false)) } },
            [PSCustomObject]@{ Name = 'message-identity'; FileName = 'invalid-message-identity.json'; Write = { param($Path) $payload = New-TestDurableWorkflowEnvelope -MessageId 'different-message-id'; [IO.File]::WriteAllText($Path, ($payload | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false)) } },
            [PSCustomObject]@{ Name = 'timestamp'; FileName = 'invalid-timestamp.json'; Write = { param($Path) $payload = New-TestDurableWorkflowEnvelope -MessageId 'invalid-timestamp'; $payload.timestamp = 'not-a-timestamp'; [IO.File]::WriteAllText($Path, ($payload | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false)) } },
            [PSCustomObject]@{ Name = 'ttl'; FileName = 'invalid-ttl.json'; Write = { param($Path) $payload = New-TestDurableWorkflowEnvelope -MessageId 'invalid-ttl'; $payload.ttl_seconds = 0; [IO.File]::WriteAllText($Path, ($payload | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false)) } }
        )
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { throw 'terminal-invalid pending files must not reach the durable log' }
        foreach ($case in $terminalCases) {
            $casePath = Join-Path $pendingRoot $case.FileName
            & $case.Write $casePath
            $result = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
            $result.Summary.mailbox_events | Should -Be 0 -Because $case.Name
            Test-Path -LiteralPath $casePath -PathType Leaf | Should -BeFalse -Because $case.Name
        }
        Should -Invoke Write-OrchestraLog -Times 0 -Exactly
    }

    It 'J02 retains a complete pending workflow completion when a transient file read fails' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        $pendingPath = Join-Path $pendingRoot 'workflow-ack-j02-transient.json'
        $payload = New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-j02-transient'
        [IO.File]::WriteAllText($pendingPath, ($payload | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))
        $lease = [IO.File]::Open($pendingPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            $records = @(Receive-OperatorPollDurableWorkflowMessages -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra')
            $records.Count | Should -Be 0
            Test-Path -LiteralPath $pendingPath -PathType Leaf | Should -BeTrue
        } finally {
            $lease.Dispose()
        }
    }

    It 'AC04 AB08 F01 consumes a pending workflow ACK only after durable log success and replays after the run advances' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        $pendingPath = Join-Path $pendingRoot 'workflow-ack-f01.json'
        $json = (New-TestDurableWorkflowEnvelope) | ConvertTo-Json -Compress -Depth 20
        [IO.File]::WriteAllText($pendingPath, $json, [Text.UTF8Encoding]::new($false))
        Initialize-TestDurableWorkflowRun
        Add-TestDurableWorkflowCompletionProof -MessageId 'workflow-ack-f01'
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { }

        $success = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})

        $success.Summary.mailbox_events | Should -Be 1
        Test-Path -LiteralPath $pendingPath | Should -BeFalse
        Should -Invoke Write-OrchestraLog -Times 1 -Exactly -ParameterFilter { $Event -eq 'workflow.node.acknowledged' }

        [IO.File]::WriteAllText($pendingPath, $json, [Text.UTF8Encoding]::new($false))
        Mock Write-OrchestraLog { throw 'injected durable log failure' }
        $failed = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})

        $failed.Summary.errors | Should -BeGreaterThan 0
        Test-Path -LiteralPath $pendingPath -PathType Leaf | Should -BeTrue
        $proofPath = Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs\completion\inspect.json'
        Test-Path -LiteralPath $proofPath -PathType Leaf | Should -BeTrue
        $proofBeforeRetry = [IO.File]::ReadAllBytes($proofPath)
        $proof = Read-DeclarativeWorkflowDurableProof -ProjectDir $script:operatorPollTempRoot `
            -Run $null -RunId 'run-123' -Kind Completion -NodeId 'inspect'
        $statePath = Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\state.json'
        $advancedRun = [IO.File]::ReadAllText($statePath, [Text.UTF8Encoding]::new($false, $true)) |
            ConvertFrom-WinsmuxJson -AsHashtable -Depth 30 -ErrorAction Stop
        $advancedRun.nodes.inspect.state = 'succeeded'
        $advancedRun.nodes.inspect.agent_cli_session_id = '%2'
        $advancedRun.nodes.inspect.evidence_refs = @($proof.evidence_ref)
        $advancedRun.nodes.inspect.completion_proof = Copy-DeclarativeWorkflowValue $proof
        $advancedRun.nodes.inspect.application_outcome = [ordered]@{
            input_head = $proof.input_head; output_head = $proof.output_head
        }
        $advancedRun.nodes.verify.state = 'ready'
        [IO.File]::WriteAllText($statePath, ($advancedRun | ConvertTo-Json -Compress -Depth 30), [Text.UTF8Encoding]::new($false))
        Mock Write-OrchestraLog { }
        $retry = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
        $retry.Summary.mailbox_events | Should -Be 1
        Test-Path -LiteralPath $pendingPath | Should -BeFalse
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($proofPath)) | Should -BeExactly ([Convert]::ToBase64String($proofBeforeRetry))

        $mismatchPath = Join-Path $pendingRoot 'workflow-ack-f01-mismatch.json'
        $mismatchJson = (New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-f01-mismatch') |
            ConvertTo-Json -Compress -Depth 20
        [IO.File]::WriteAllText($mismatchPath, $mismatchJson, [Text.UTF8Encoding]::new($false))
        $script:ac04UnexpectedLogs = 0
        Mock Write-OrchestraLog { $script:ac04UnexpectedLogs++ }
        $mismatch = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath `
            -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
        $mismatch.Summary.errors | Should -BeGreaterThan 0
        $mismatch.ProcessedEventSignatures.Count | Should -Be 0
        Test-Path -LiteralPath $mismatchPath -PathType Leaf | Should -BeTrue
        $script:ac04UnexpectedLogs | Should -Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($proofPath)) | Should -BeExactly ([Convert]::ToBase64String($proofBeforeRetry))
    }

    It 'Q01 preserves a future-node pre-ACK without creating a completion proof' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { }
        Initialize-TestDurableWorkflowRun
        $pendingPath = Join-Path $pendingRoot 'workflow-ack-q01-future.json'
        [IO.File]::WriteAllText($pendingPath, ((New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-q01-future' -NodeId 'verify') | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
        $cycle.Summary.errors | Should -BeGreaterThan 0
        Test-Path -LiteralPath $pendingPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs\completion\verify.json') -PathType Leaf | Should -BeFalse
    }

    It 'AB02 Q02 preserves a completion from a live but unassigned pane without poisoning the proof path' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { }
        Initialize-TestDurableWorkflowRun -InspectBinding 'builder-2'
        $pendingPath = Join-Path $pendingRoot 'workflow-ack-q02-wrong-pane.json'
        [IO.File]::WriteAllText($pendingPath, ((New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-q02-wrong-pane') | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
        $cycle.Summary.errors | Should -BeGreaterThan 0
        Test-Path -LiteralPath $pendingPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs\completion\inspect.json') -PathType Leaf | Should -BeFalse
    }

    It 'Q03 accepts a delayed completion from the assigned pane while the node is blocked' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { }
        Initialize-TestDurableWorkflowRun -InspectState 'blocked'
        Add-TestDurableWorkflowCompletionProof -MessageId 'workflow-ack-q03-blocked'
        $pendingPath = Join-Path $pendingRoot 'workflow-ack-q03-blocked.json'
        [IO.File]::WriteAllText($pendingPath, ((New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-q03-blocked') | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
        $cycle.Summary.errors | Should -Be 0
        Test-Path -LiteralPath $pendingPath -PathType Leaf | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs\completion\inspect.json') -PathType Leaf | Should -BeTrue
    }

    It 'Q04 preserves rejected input and processes a later valid completion in the same cycle' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { }
        Initialize-TestDurableWorkflowRun
        Add-TestDurableWorkflowCompletionProof -MessageId 'z-workflow-ack-q01-valid'
        $poisonPath = Join-Path $pendingRoot 'a-workflow-ack-q01-future.json'
        $validPath = Join-Path $pendingRoot 'z-workflow-ack-q01-valid.json'
        [IO.File]::WriteAllText($poisonPath, ((New-TestDurableWorkflowEnvelope -MessageId 'a-workflow-ack-q01-future' -NodeId 'verify') | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($validPath, ((New-TestDurableWorkflowEnvelope -MessageId 'z-workflow-ack-q01-valid') | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
        $cycle.Summary.errors | Should -BeGreaterThan 0
        Test-Path -LiteralPath $poisonPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $validPath -PathType Leaf | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs\completion\verify.json') -PathType Leaf | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs\completion\inspect.json') -PathType Leaf | Should -BeTrue
    }

    It 'Q05 preserves a missing-run completion record as durable retry input' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { }
        $pendingPath = Join-Path $pendingRoot 'workflow-ack-q05-missing-run.json'
        $payload = New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-q05-missing-run'
        $payload.content.data.run_id = 'missing-run'
        $payload.content.data.idempotency_key = 'missing-run:inspect'
        $payload.content.data.evidence_ref = 'workflow-ack:missing-run:inspect'
        [IO.File]::WriteAllText($pendingPath, ($payload | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
        $cycle.Summary.errors | Should -BeGreaterThan 0
        Test-Path -LiteralPath $pendingPath -PathType Leaf | Should -BeTrue
    }

    It 'Q06 preserves unknown-node and tuple-mismatch completion records as durable retry input' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { }
        Initialize-TestDurableWorkflowRun

        foreach ($case in @(
                [PSCustomObject]@{ Name = 'unknown-node'; Mutate = {
                        param($Payload)
                        $Payload.content.data.node_id = 'unknown'
                        $Payload.content.data.idempotency_key = 'run-123:unknown'
                        $Payload.content.data.evidence_ref = 'workflow-ack:run-123:unknown'
                    } },
                [PSCustomObject]@{ Name = 'tuple-mismatch'; Mutate = {
                        param($Payload)
                        $Payload.content.data.config_fingerprint = ('sha256:' + ('c' * 64))
                    } }
            )) {
            $messageId = "workflow-ack-q06-$($case.Name)"
            $pendingPath = Join-Path $pendingRoot ($messageId + '.json')
            $payload = New-TestDurableWorkflowEnvelope -MessageId $messageId
            & $case.Mutate $payload
            [IO.File]::WriteAllText($pendingPath, ($payload | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))

            $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
            $cycle.Summary.errors | Should -BeGreaterThan 0 -Because $case.Name
            Test-Path -LiteralPath $pendingPath -PathType Leaf | Should -BeTrue -Because $case.Name
        }
        Test-Path -LiteralPath (Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs\completion\unknown.json') -PathType Leaf | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs\completion\inspect.json') -PathType Leaf | Should -BeFalse
    }

    It 'Q07 rotates a full retry batch without deleting it so a later valid completion advances on the next cycle' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { }
        Initialize-TestDurableWorkflowRun
        Add-TestDurableWorkflowCompletionProof -MessageId 'z-workflow-ack-q07-valid'

        foreach ($index in 0..19) {
            $messageId = 'a-workflow-ack-q07-{0:d2}' -f $index
            $pendingPath = Join-Path $pendingRoot ($messageId + '.json')
            $payload = New-TestDurableWorkflowEnvelope -MessageId $messageId
            $payload.content.data.pane_id = '%3'
            [IO.File]::WriteAllText($pendingPath, ($payload | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))
        }
        $validPath = Join-Path $pendingRoot 'z-workflow-ack-q07-valid.json'
        [IO.File]::WriteAllText($validPath, ((New-TestDurableWorkflowEnvelope -MessageId 'z-workflow-ack-q07-valid') | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))

        $first = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
        $first.Summary.errors | Should -Be 20
        @(Get-ChildItem -LiteralPath $pendingRoot -File -Filter 'a-workflow-ack-q07-*.json').Count | Should -Be 20
        Test-Path -LiteralPath $validPath -PathType Leaf | Should -BeTrue

        $second = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount $first.ProcessedLineCount -ProcessedEventSignatures $first.ProcessedEventSignatures
        $second.Summary.errors | Should -Be 19
        Test-Path -LiteralPath $validPath -PathType Leaf | Should -BeFalse
        @(Get-ChildItem -LiteralPath $pendingRoot -File -Filter 'a-workflow-ack-q07-*.json').Count | Should -Be 20
        Test-Path -LiteralPath (Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs\completion\inspect.json') -PathType Leaf | Should -BeTrue
    }

    It 'AC03 rejects an over-bound workflow tuple without starving the later valid pending completion' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { }
        Initialize-TestDurableWorkflowRun
        Add-TestDurableWorkflowCompletionProof -MessageId 'z-workflow-ack-ac03-valid'

        $poisonPath = Join-Path $pendingRoot 'a-workflow-ack-ac03-over-bound.json'
        $poison = New-TestDurableWorkflowEnvelope -MessageId 'a-workflow-ack-ac03-over-bound'
        $overBoundRunId = 'r' * 193
        $poison.content.data.run_id = $overBoundRunId
        $poison.content.data.idempotency_key = "$overBoundRunId`:inspect"
        $poison.content.data.evidence_ref = "workflow-ack:$overBoundRunId`:inspect"
        [IO.File]::WriteAllText($poisonPath, ($poison | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))

        $validPath = Join-Path $pendingRoot 'z-workflow-ack-ac03-valid.json'
        $valid = New-TestDurableWorkflowEnvelope -MessageId 'z-workflow-ack-ac03-valid'
        [IO.File]::WriteAllText($validPath, ($valid | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath `
            -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})

        Test-Path -LiteralPath $poisonPath | Should -BeFalse
        Test-Path -LiteralPath $validPath | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:operatorPollTempRoot '.winsmux\workflow-runs\run-123\proofs\completion\inspect.json') |
            Should -BeTrue
        Should -Invoke Write-OrchestraLog -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'workflow.node.acknowledged'
        }
        $cycle.ProcessedEventSignatures.Count | Should -Be 1
    }

    It 'AC03 converts an unclassified authenticated admission exception into one retry and continues the cycle' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { }
        Initialize-TestDurableWorkflowRun
        Add-TestDurableWorkflowCompletionProof -MessageId 'z-workflow-ack-ac03-valid-after-error'

        $retryPath = Join-Path $pendingRoot 'a-workflow-ack-ac03-unclassified.json'
        $retry = New-TestDurableWorkflowEnvelope -MessageId 'a-workflow-ack-ac03-unclassified'
        [IO.File]::WriteAllText($retryPath, ($retry | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))
        $validPath = Join-Path $pendingRoot 'z-workflow-ack-ac03-valid-after-error.json'
        $valid = New-TestDurableWorkflowEnvelope -MessageId 'z-workflow-ack-ac03-valid-after-error'
        [IO.File]::WriteAllText($validPath, ($valid | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))

        Mock Publish-OperatorPollWorkflowCompletionProof {
            param($Manifest, $PaneContext, $ProjectDir, $Run, $Acknowledgement)
            if ([string]$Acknowledgement.message_id -ceq 'a-workflow-ack-ac03-unclassified') {
                throw 'injected unclassified authenticated admission exception'
            }
            Read-DeclarativeWorkflowDurableProof -ProjectDir $ProjectDir -Run $Run `
                -Kind Completion -NodeId ([string]$Acknowledgement.node_id)
        }

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath `
            -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})

        $cycle.Summary.errors | Should -BeGreaterThan 0
        $cycle.ProcessedEventSignatures.Count | Should -Be 1
        Test-Path -LiteralPath $retryPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $validPath | Should -BeFalse
        Should -Invoke Write-OrchestraLog -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'workflow.node.acknowledged'
        }
    }

    It 'AD01 preserves a log-failed durable completion and finalizes the later record in the same cycle' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        Mock Receive-OperatorPollMailboxMessages { @() }
        Initialize-TestDurableWorkflowRun -RunId 'run-123'
        Initialize-TestDurableWorkflowRun -RunId 'run-456'
        Add-TestDurableWorkflowCompletionProof -MessageId 'a-workflow-ack-ad01-log-failure' -RunId 'run-123'
        Add-TestDurableWorkflowCompletionProof -MessageId 'z-workflow-ack-ad01-valid' -RunId 'run-456'

        $firstPath = Join-Path $pendingRoot 'a-workflow-ack-ad01-log-failure.json'
        $first = New-TestDurableWorkflowEnvelope -MessageId 'a-workflow-ack-ad01-log-failure' -RunId 'run-123'
        [IO.File]::WriteAllText($firstPath, ($first | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))
        $secondPath = Join-Path $pendingRoot 'z-workflow-ack-ad01-valid.json'
        $second = New-TestDurableWorkflowEnvelope -MessageId 'z-workflow-ack-ad01-valid' -RunId 'run-456'
        [IO.File]::WriteAllText($secondPath, ($second | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))

        Mock Write-OrchestraLog {
            if ([string]$Data.run_id -ceq 'run-123') {
                throw 'injected first-record accepted-log failure'
            }
        }

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath `
            -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})

        $cycle.Summary.errors | Should -BeGreaterThan 0
        Test-Path -LiteralPath $firstPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $secondPath | Should -BeFalse
        $cycle.ProcessedEventSignatures.Count | Should -Be 1
        Should -Invoke Write-OrchestraLog -Times 2 -Exactly -ParameterFilter {
            $Event -eq 'workflow.node.acknowledged'
        }
    }

    It 'AD02 contains a signature lookup failure and finalizes the later durable record' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { }
        Initialize-TestDurableWorkflowRun -RunId 'run-123'
        Initialize-TestDurableWorkflowRun -RunId 'run-456'
        Add-TestDurableWorkflowCompletionProof -MessageId 'a-workflow-ack-ad02-signature-failure' -RunId 'run-123'
        Add-TestDurableWorkflowCompletionProof -MessageId 'z-workflow-ack-ad02-valid' -RunId 'run-456'

        $firstPath = Join-Path $pendingRoot 'a-workflow-ack-ad02-signature-failure.json'
        $first = New-TestDurableWorkflowEnvelope -MessageId 'a-workflow-ack-ad02-signature-failure' -RunId 'run-123'
        [IO.File]::WriteAllText($firstPath, ($first | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))
        $secondPath = Join-Path $pendingRoot 'z-workflow-ack-ad02-valid.json'
        $second = New-TestDurableWorkflowEnvelope -MessageId 'z-workflow-ack-ad02-valid' -RunId 'run-456'
        [IO.File]::WriteAllText($secondPath, ($second | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))

        Mock Get-OperatorPollEventSignature {
            param($EventRecord)
            $messageId = [string](Get-OperatorPollValue $EventRecord 'message_id' '')
            if ($messageId -ceq 'a-workflow-ack-ad02-signature-failure') {
                throw 'injected first-record signature failure'
            }
            "signature-$messageId"
        }

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath `
            -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})

        $cycle.Summary.errors | Should -BeGreaterThan 0
        Test-Path -LiteralPath $firstPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $secondPath | Should -BeFalse
        $cycle.ProcessedEventSignatures.Count | Should -Be 1
        Should -Invoke Write-OrchestraLog -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'workflow.node.acknowledged'
        }
    }

    It 'processes mailbox idle messages when panes are stored in dictionary format' {
        @"
version: 1
saved_at: 2026-04-09T11:00:00+09:00
session:
  name: winsmux-orchestra
  generation_id: generation-123
  project_dir: $script:operatorPollTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    launch_dir: $script:operatorPollTempRoot
"@ | Set-Content -Path $script:operatorPollManifestPath -Encoding UTF8

        Mock Receive-OperatorPollMailboxMessages {
            @(
                [ordered]@{
                    timestamp   = '2026-04-07T09:00:00.0000000+09:00'
                    session     = 'winsmux-orchestra'
                    event       = 'pane.idle'
                    message     = 'Operator alert: idle pane builder-1 (%2, role=Builder)'
                    label       = 'builder-1'
                    pane_id     = '%2'
                    role        = 'Builder'
                    status      = 'ready'
                    exit_reason = ''
                    data        = [ordered]@{
                        idle_threshold_seconds = 120
                    }
                    source      = 'mailbox'
                }
            )
        }
        Mock Write-OperatorPollLog { }

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
        $summary = $cycle['Summary']

        $summary.mailbox_events | Should -Be 1
        $summary.new_events | Should -Be 1
        $summary.dispatches | Should -Be 1
        $summary.messages[0] | Should -Be 'builder-1 (%2) がアイドル。次タスクのディスパッチが必要'
    }

    It 'prefers a worker as the review target when no reviewer pane exists' {
@"
version: 1
saved_at: 2026-04-09T11:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:operatorPollTempRoot
panes:
  worker-1:
    pane_id: %2
    role: Worker
    launch_dir: $script:operatorPollTempRoot
"@ | Set-Content -Path $script:operatorPollManifestPath -Encoding UTF8

        $manifest = Read-OperatorPollManifest -Path $script:operatorPollManifestPath
        $reviewPane = Get-OperatorPollPreferredReviewPane -Manifest $manifest

        $reviewPane.PaneId | Should -Be '%2'
        $reviewPane.Label | Should -Be 'worker-1'
        $reviewPane.Role | Should -Be 'Worker'
    }

    It 'matches review-state records that use generic review target keys' {
@"
version: 1
saved_at: 2026-04-09T11:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:operatorPollTempRoot
panes:
  worker-1:
    pane_id: %2
    role: Worker
    launch_dir: $script:operatorPollTempRoot
"@ | Set-Content -Path $script:operatorPollManifestPath -Encoding UTF8

        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-state.ps1')

        $reviewState = @{
            'feature/test' = @{
                status = 'PENDING'
                request = @{
                    target_review_label = 'worker-1'
                    target_review_pane_id = '%2'
                }
            }
        }

        $record = Get-OrchestraPaneReviewRecord -ReviewState $reviewState -Branch '' -Label 'worker-1' -PaneId '%2' -Role 'Worker'

        $record.status | Should -Be 'PENDING'
    }

    It 'appends operator poll log records as jsonl' {
        Write-OperatorPollLog -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' -EventName 'operator.poll.idle_dispatch_needed' -Message 'idle' -PaneId '%2'
        Write-OperatorPollLog -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' -EventName 'operator.poll.auto_approved' -Message 'approved' -PaneId '%2'

        $logPath = Get-OperatorPollLogPath -ProjectDir $script:operatorPollTempRoot
        $lines = @(Get-Content -Path $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $lines.Count | Should -Be 2
        ($lines[0] | ConvertFrom-Json).event | Should -Be 'operator.poll.idle_dispatch_needed'
        ($lines[1] | ConvertFrom-Json).event | Should -Be 'operator.poll.auto_approved'
    }

    It 'does not forward operator dispatch-needed alerts to Telegram by default' {
        Mock Test-Path { $true }
        Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
        Mock Invoke-RestMethod { }

        Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
            -Event 'operator.dispatch_needed' -Message 'idle' -PaneId '%2' -Label 'builder-1' -Role 'Builder'

        Should -Not -Invoke Invoke-RestMethod
    }

    It 'does not forward auto-approved alerts to Telegram by default' {
        Mock Test-Path { $true }
        Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
        Mock Invoke-RestMethod { }

        Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
            -Event 'operator.auto_approved' -Message 'approved' -PaneId '%2' -Label 'builder-1' -Role 'Builder'

        Should -Not -Invoke Invoke-RestMethod
    }

    It 'sends external review-requested alerts to Telegram by default' {
        Mock Test-Path { $true }
        Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
        Mock Invoke-RestMethod { }

        Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
            -Event 'operator.review_requested' -Message 'review requested' -PaneId '%4' -Label 'worker-1' -Role 'Worker'

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'sends commit-ready alerts to Telegram by default' {
        Mock Test-Path { $true }
        Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
        Mock Invoke-RestMethod { }

        Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
            -Event 'operator.commit_ready' -Message 'ready to commit' -HeadSha 'abc1234def5678'

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'allows all operator Telegram alerts when verbose profile is enabled' {
        $previousProfile = $env:WINSMUX_TELEGRAM_PROFILE
        $env:WINSMUX_TELEGRAM_PROFILE = 'verbose'

        try {
            Mock Test-Path { $true }
            Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
            Mock Invoke-RestMethod { }

            Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
                -Event 'operator.dispatch_needed' -Message 'idle' -PaneId '%2' -Label 'builder-1' -Role 'Builder'

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        } finally {
            if ($null -eq $previousProfile) {
                Remove-Item Env:WINSMUX_TELEGRAM_PROFILE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_TELEGRAM_PROFILE = $previousProfile
            }
        }
    }

    It 'suppresses all Telegram alerts when profile is none' {
        $previousProfile = $env:WINSMUX_TELEGRAM_PROFILE
        $env:WINSMUX_TELEGRAM_PROFILE = 'none'

        try {
            Mock Test-Path { $true }
            Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
            Mock Invoke-RestMethod { }

            Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
                -Event 'operator.review_failed' -Message 'review failed' -HeadSha 'abc1234def5678'

            Should -Not -Invoke Invoke-RestMethod
        } finally {
            if ($null -eq $previousProfile) {
                Remove-Item Env:WINSMUX_TELEGRAM_PROFILE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_TELEGRAM_PROFILE = $previousProfile
            }
        }
    }

    It 'allows internal operator Telegram alerts only when explicitly overridden' {
        $previousOverride = $env:WINSMUX_TELEGRAM_INCLUDE_INTERNAL_EVENTS
        $env:WINSMUX_TELEGRAM_INCLUDE_INTERNAL_EVENTS = 'true'

        try {
            Mock Test-Path { $true }
            Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
            Mock Invoke-RestMethod { }

            Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
                -Event 'operator.dispatch_needed' -Message 'idle' -PaneId '%2' -Label 'builder-1' -Role 'Builder'

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        } finally {
            if ($null -eq $previousOverride) {
                Remove-Item Env:WINSMUX_TELEGRAM_INCLUDE_INTERNAL_EVENTS -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_TELEGRAM_INCLUDE_INTERNAL_EVENTS = $previousOverride
            }
        }
    }

    It 'dispatches review requests through operator poll wrappers' {
@"
version: 1
saved_at: 2026-04-12T10:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:operatorPollTempRoot
panes:
  reviewer-1:
    pane_id: %4
    role: Reviewer
    launch_dir: $script:operatorPollTempRoot
"@ | Set-Content -Path $script:operatorPollManifestPath -Encoding UTF8

        Mock Send-OperatorPollLiteral { }
        Mock Approve-OperatorPollPane { }
        Mock Send-OperatorTelegramNotification { }

        $result = Invoke-OperatorStateMachine `
            -CurrentState 'waiting_for_review' `
            -CycleSummary @{ completions = 1 } `
            -ProjectDir $script:operatorPollTempRoot `
            -SessionName 'winsmux-orchestra' `
            -ManifestPath $script:operatorPollManifestPath

        $result.State | Should -Be 'review_requested'
        Should -Invoke Send-OperatorPollLiteral -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%4' -and $Text -eq 'winsmux review-request'
        }
        Should -Invoke Approve-OperatorPollPane -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%4'
        }
    }

    It 'stops at the draft PR gate after review passed' {
        Mock Send-OperatorTelegramNotification { }

        $result = Invoke-OperatorStateMachine `
            -CurrentState 'review_passed' `
            -CycleSummary @{ completions = 0 } `
            -ProjectDir $script:operatorPollTempRoot `
            -SessionName 'winsmux-orchestra' `
            -ManifestPath $script:operatorPollManifestPath

        $result.State | Should -Be 'blocked_draft_pr_required'
        $result.CommitReadySha | Should -Be ''

        $eventsPath = Join-Path $script:operatorPollManifestDir 'events.jsonl'
        $events = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        @($events | ForEach-Object { $_['event'] }) | Should -Contain 'operator.draft_pr.required'
        $draftEvent = @($events | Where-Object { $_['event'] -eq 'operator.draft_pr.required' })[0]
        $draftEvent['status'] | Should -Be 'blocked_draft_pr_required'
        $draftEvent['data']['human_merge_required'] | Should -Be $true
        $draftEvent['data']['auto_merge_allowed'] | Should -Be $false
        @($events | ForEach-Object { $_['event'] }) | Should -Not -Contain 'operator.commit_ready'

        Should -Invoke Send-OperatorTelegramNotification -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'operator.draft_pr.required'
        }
    }

    It 'ignores draft PR events without a matching head sha' {
        $eventsPath = Join-Path $script:operatorPollManifestDir 'events.jsonl'
        @(
            ([ordered]@{
                timestamp = '2026-04-12T10:00:00+09:00'
                event     = 'operator.draft_pr.created'
                head_sha  = ''
                data      = [ordered]@{ target = 'draft_pr'; draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/900' }
            } | ConvertTo-Json -Compress -Depth 10),
            ([ordered]@{
                timestamp = '2026-04-12T10:01:00+09:00'
                event     = 'operator.draft_pr.created'
                head_sha  = 'old-sha'
                data      = [ordered]@{ target = 'draft_pr'; draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/901' }
            } | ConvertTo-Json -Compress -Depth 10)
        ) | Set-Content -Path $eventsPath -Encoding UTF8

        Test-OperatorDraftPrCreated -ProjectDir $script:operatorPollTempRoot -HeadSha 'current-sha' | Should -Be $false
    }

    It 'resumes from the draft PR gate when matching draft PR evidence appears' {
        Mock git { 'abc123' }
        Mock Send-OperatorTelegramNotification { }

        $eventsPath = Join-Path $script:operatorPollManifestDir 'events.jsonl'
        ([ordered]@{
            timestamp = '2026-04-12T10:02:00+09:00'
            event     = 'operator.draft_pr.created'
            head_sha  = 'abc123'
            data      = [ordered]@{ target = 'draft_pr'; draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/902' }
        } | ConvertTo-Json -Compress -Depth 10) | Set-Content -Path $eventsPath -Encoding UTF8

        $result = Invoke-OperatorStateMachine `
            -CurrentState 'blocked_draft_pr_required' `
            -CycleSummary @{ completions = 0 } `
            -ProjectDir $script:operatorPollTempRoot `
            -SessionName 'winsmux-orchestra' `
            -ManifestPath $script:operatorPollManifestPath

        $result.State | Should -Be 'commit_ready'
        $result.CommitReadySha | Should -Be 'abc123'
        Should -Invoke Send-OperatorTelegramNotification -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'operator.commit_ready' -and $HeadSha -eq 'abc123'
        }
    }
}
