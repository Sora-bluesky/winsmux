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
                [string]$GenerationId = 'generation-123'
            )
            [ordered]@{
                mailbox_version = 2; message_id = $MessageId; correlation_id = $MessageId; causation_id = $null
                idempotency_key = "workflow-completion-$MessageId"; message_type = 'workflow-completion'; state = 'created'; ttl_seconds = 300
                ack_required = $true; from = 'builder-1'; to = 'Operator'; timestamp = [DateTimeOffset]::UtcNow.ToString('o')
                content = [ordered]@{
                    session = 'winsmux-orchestra'; event = 'workflow.node.acknowledged'; message = 'Declarative workflow completion.'
                    label = 'builder-1'; pane_id = '%2'; role = 'Builder'; status = 'succeeded'; exit_reason = ''
                    data = [ordered]@{
                        schema_version = 1; run_id = 'run-123'; node_id = $NodeId; idempotency_key = "run-123:$NodeId"
                        generation_id = $GenerationId; config_fingerprint = ('sha256:' + ('a' * 64)); workflow_fingerprint = ('sha256:' + ('d' * 64))
                        source_head = ('b' * 40); pane_id = '%2'; status = 'succeeded'; evidence_ref = "workflow-ack:run-123:$NodeId"
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
            source_head         = ('b' * 40)
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
        $record = ConvertTo-OperatorPollMailboxRecord -MailboxMessage $payload -SessionName 'winsmux-orchestra'
        $manifest = Read-OperatorPollManifest -Path $script:operatorPollManifestPath
        $summary = [ordered]@{ new_events = 0; dispatches = 0; completions = 0; approvals = 0; errors = 0; messages = @() }
        Mock Write-OrchestraLog { }

        Invoke-OperatorPollEventRecord -Manifest $manifest -ManifestPath $script:operatorPollManifestPath -EventRecord $record -Summary $summary

        $summary.errors | Should -Be 0
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
            source_head         = ('b' * 40)
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

    It 'F03 rejects a workflow completion whose durable publication TTL has elapsed' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        $pendingPath = Join-Path $pendingRoot 'workflow-ack-stale-publication.json'
        $payload = New-TestDurableWorkflowEnvelope -MessageId 'workflow-ack-stale-publication'
        $payload.timestamp = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o')
        [IO.File]::WriteAllText($pendingPath, ($payload | ConvertTo-Json -Compress -Depth 20), [Text.UTF8Encoding]::new($false))
        Mock Receive-OperatorPollMailboxMessages { @() }
        Mock Write-OrchestraLog { throw 'expired durable completion must not reach the log' }

        $result = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})

        $result.Summary.mailbox_events | Should -Be 0
        Test-Path -LiteralPath $pendingPath | Should -BeFalse
        Should -Invoke Write-OrchestraLog -Times 0 -Exactly
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

    It 'F01 consumes a pending workflow ACK only after durable log success and leaves it for replay after log failure' {
        $pendingRoot = Join-Path $script:operatorPollTempRoot '.winsmux\mailbox\winsmux-orchestra-operator\pending'
        [IO.Directory]::CreateDirectory($pendingRoot) | Out-Null
        $pendingPath = Join-Path $pendingRoot 'workflow-ack-f01.json'
        $json = (New-TestDurableWorkflowEnvelope) | ConvertTo-Json -Compress -Depth 20
        [IO.File]::WriteAllText($pendingPath, $json, [Text.UTF8Encoding]::new($false))
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
