$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'TASK781 supervisor deferred runtime promotion' {
    BeforeAll {
        $script:task781SupervisorPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-supervisor.ps1'
        $script:task781SupervisorContent = Get-Content -LiteralPath $script:task781SupervisorPath -Raw -Encoding UTF8
        . $script:task781SupervisorPath -ManifestPath 'synthetic-manifest' -GenerationId 'generation-1' -ServerSessionId '$9'
    }

    BeforeEach {
        $script:task781PromotionRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-task781-promotion-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:task781PromotionRoot -Force | Out-Null
        $script:task781PromotionMarkerPath = Join-Path $script:task781PromotionRoot 'worker-1.ready.json'
        $script:task781PromotionManifest = [PSCustomObject]@{
            panes = [ordered]@{
                'worker-1' = [ordered]@{
                    slot_id = 'worker-1'; pane_id = '%2'; worker_backend = 'codex'; worker_role = 'reviewer'
                    role = 'Reviewer'; title = 'W1 Codex Reviewer'; status = 'deferred_starting'; runtime_ready = $false
                    bootstrap_marker_path = $script:task781PromotionMarkerPath
                }
            }
        }
        $script:task781PromotionProcessResolver = {
            param([int]$Id)
            if ($Id -eq 4200) {
                return [PSCustomObject]@{
                    Id = 4200; StartTime = [datetime]'2026-07-15T00:00:01Z'; ParentProcessId = 1; Name = 'pwsh.exe'
                }
            }
            return $null
        }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:task781PromotionRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'TASK781 C42 carries the manifest expected pane count into the supervisor registry' {
        $script:task781SupervisorContent | Should -Match "-Name 'expected_pane_count'"
        $script:task781SupervisorContent | Should -Match '-ExpectedPaneCount \$expectedPaneCount -Panes \$runtimePanes'
    }

    It 'TASK781 C29 keeps deferred_starting deferred until its marker exists' {
        $panes = @(New-OrchestraSupervisorRuntimePanes -Manifest $script:task781PromotionManifest `
            -GenerationId 'generation-1' -ServerSessionId '$9' -ProcessResolver $script:task781PromotionProcessResolver)

        $panes.Count | Should -Be 1
        $panes[0].state | Should -Be 'deferred'
        $panes[0].bootstrap_pid | Should -Be 0
    }

    It 'TASK781 C29 promotes deferred_starting only from an authenticated current-generation marker' {
        ([ordered]@{
            state = 'bootstrap_pending'; generation_id = 'generation-1'; server_session_id = '$9'
            slot_id = 'worker-1'; pane_id = '%2'; backend = 'codex'; role = 'reviewer'; title = 'W1 Codex Reviewer'
            bootstrap_pid = 4200; bootstrap_process_started_at = '2026-07-15T00:00:01.0000000Z'
        } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:task781PromotionMarkerPath -Encoding UTF8

        $panes = @(New-OrchestraSupervisorRuntimePanes -Manifest $script:task781PromotionManifest `
            -GenerationId 'generation-1' -ServerSessionId '$9' -ProcessResolver $script:task781PromotionProcessResolver)

        $panes.Count | Should -Be 1
        $panes[0].state | Should -Be 'live'
        $panes[0].bootstrap_pid | Should -Be 4200
        $panes[0].bootstrap_process_started_at | Should -Be '2026-07-15T00:00:01.0000000Z'
    }

    It 'TASK781 C29 rejects a stale marker instead of publishing a live registry row' {
        ([ordered]@{
            state = 'bootstrap_pending'; generation_id = 'generation-old'; server_session_id = '$9'
            slot_id = 'worker-1'; pane_id = '%2'; backend = 'codex'; role = 'reviewer'; title = 'W1 Codex Reviewer'
            bootstrap_pid = 4200; bootstrap_process_started_at = '2026-07-15T00:00:01.0000000Z'
        } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:task781PromotionMarkerPath -Encoding UTF8

        {
            New-OrchestraSupervisorRuntimePanes -Manifest $script:task781PromotionManifest `
                -GenerationId 'generation-1' -ServerSessionId '$9' -ProcessResolver $script:task781PromotionProcessResolver
        } | Should -Throw '*marker identity does not match*'
    }

    It 'TASK781 C47 contains a transient dead-marker snapshot without terminating the supervisor loop' {
        ([ordered]@{
            state = 'bootstrap_pending'; generation_id = 'generation-1'; server_session_id = '$9'
            slot_id = 'worker-1'; pane_id = '%2'; backend = 'codex'; role = 'reviewer'; title = 'W1 Codex Reviewer'
            bootstrap_pid = 4200; bootstrap_process_started_at = '2026-07-15T00:00:01.0000000Z'
        } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:task781PromotionMarkerPath -Encoding UTF8
        $deadProcessResolver = { param([int]$Id) return $null }

        $contained = Get-OrchestraSupervisorRuntimePaneSnapshot -Manifest $script:task781PromotionManifest `
            -GenerationId 'generation-1' -ServerSessionId '$9' -ProcessResolver $deadProcessResolver
        $healthy = Get-OrchestraSupervisorRuntimePaneSnapshot -Manifest $script:task781PromotionManifest `
            -GenerationId 'generation-1' -ServerSessionId '$9' -ProcessResolver $script:task781PromotionProcessResolver

        $contained.valid | Should -BeFalse
        $contained.panes.Count | Should -Be 0
        $contained.diagnostic | Should -Match 'marker identity does not match'
        $healthy.valid | Should -BeTrue
        $healthy.panes.Count | Should -Be 1
    }
}

Describe 'TASK781 caller acknowledgement side effects' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\pane-control.ps1')
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\submission-contract.ps1')

        function Send-TextToPane {
            param(
                [string]$PaneId,
                [string]$CommandText,
                [string]$PromptTransport = 'argv',
                [string]$RuntimeProjectDir = '',
                [string]$RuntimeOperation = 'dispatch',
                [string]$ExpectedGenerationId = ''
            )
        }

        function New-Task781SyntheticAckCandidate {
            param(
                [Parameter(Mandatory = $true)][string]$ProjectDir,
                [Parameter(Mandatory = $true)][string]$SubmissionId,
                [Parameter(Mandatory = $true)][string]$Challenge
            )
            $packet = Read-WinsmuxSubmissionPacket -Path (Join-Path $ProjectDir ".winsmux\submissions\$SubmissionId.json")
            $record = New-WinsmuxSubmissionRunRecord -SubmissionId $SubmissionId -RunId $SubmissionId `
                -TaskId ([string]$packet.task_id) -Kind task -TaskTitle ([string]$packet.title) -SlotId worker-1 `
                -Backend codex -Status started -RequestConsumed -RequestDigest ([string]$packet.request_digest)
            $receipt = New-WinsmuxSubmissionReceipt -Kind task -Status accepted -Backend codex -SubmissionId $SubmissionId `
                -Target ([ordered]@{ label = 'worker-1'; pane_id = '%2'; role = 'Worker' }) -Acknowledgement $record
            return [PSCustomObject]@{
                record = $record
                receipt = $receipt
                envelope = New-WinsmuxSubmissionAcknowledgementEnvelope -Phase candidate -Challenge $Challenge -Receipt $receipt
            }
        }
    }

    BeforeEach {
        $script:task781AckRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-task781-ack-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:task781AckRoot '.winsmux') -Force | Out-Null
        $script:task781AckEntry = [PSCustomObject]@{
            Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; Role = 'Worker'; WorkerRole = 'worker'
            WorkerBackend = 'codex'; Title = 'W1 Codex Reviewer'; Status = 'ready'
        }
        $script:task781AckPipeState = [PSCustomObject]@{
            pipe_name = 'winsmux-submission-ack-33333333333333333333333333333333'
            challenge = ('c' * 64)
            server = $null
        }
        Mock Get-PaneControlManifestEntries { @($script:task781AckEntry) }
        Mock New-WinsmuxSubmissionAcknowledgementServer { $script:task781AckPipeState }
        Mock Complete-WinsmuxSubmissionAcknowledgement { $true }
        Mock Write-WinsmuxSubmissionAcknowledgementControl { }
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation, $CallerIdentity, $ProcessResolver)
            $context = [PSCustomObject]@{
                generation_id = 'generation-1'; server_session_id = '$9'; slot_id = 'worker-1'
                pane_id = '%2'; backend = 'codex'
            }
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' -Diagnostic 'verified' -Context $context
        }
        Mock New-WinsmuxSubmissionPipeCallerEvidence {
            [PSCustomObject]@{
                caller_identity = [PSCustomObject]@{
                    process_id = 4300; process_started_at = '2026-07-15T00:00:02.0000000Z'
                    generation_id = 'generation-1'; server_session_id = '$9'; slot_id = 'worker-1'
                    pane_id = '%2'; backend = 'codex'
                }
                process_resolver = { param([int]$Id) $null }
            }
        }
    }

    AfterEach {
        if ($script:task781AckRoot -and (Test-Path -LiteralPath $script:task781AckRoot)) {
            Remove-Item -LiteralPath $script:task781AckRoot -Recurse -Force
        }
    }

    It 'TASK781 refuses spoofed caller acknowledgement before any run record write' {
        Mock Test-PaneControlRuntimeContext {
            New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'caller_identity_mismatch' -Diagnostic 'synthetic caller mismatch'
        }
        Mock Write-WinsmuxSubmissionRunRecord { throw 'run record write must not occur' }

        $receipt = Invoke-WinsmuxSubmissionAcknowledge -ProjectDir $script:task781AckRoot -SlotId worker-1 `
            -SubmissionId submission-task781-refused -RunId submission-task781-refused -Kind task -Backend codex

        $receipt.status | Should -Be 'unavailable'
        $receipt.reason_code | Should -Be 'caller_identity_mismatch'
        Assert-MockCalled Write-WinsmuxSubmissionRunRecord -Times 0 -Exactly
        (Test-Path -LiteralPath (Join-Path $script:task781AckRoot '.winsmux\worker-runs\worker-1\submission-task781-refused\run.json')) | Should -BeFalse
    }

    It 'TASK781 keeps a strong caller acknowledgement in memory until commit authorization' {
        Mock Test-PaneControlRuntimeContext {
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' -Diagnostic 'verified'
        }
        New-WinsmuxSubmissionPacket -ProjectDir $script:task781AckRoot -Kind task `
            -Content ([ordered]@{ title = 'TASK781 ack'; request = 'Consume only after caller validation.' }) `
            -SubmissionId submission-task781-accepted -TargetLabel worker-1 | Out-Null

        $receipt = Invoke-WinsmuxSubmissionAcknowledge -ProjectDir $script:task781AckRoot -SlotId worker-1 `
            -SubmissionId submission-task781-accepted -RunId submission-task781-accepted -Kind task -Backend codex

        $receipt.status | Should -Be 'accepted'
        $receipt.reason_code | Should -Be ''
        $receipt.acknowledgement.slot_id | Should -Be 'worker-1'
        (Test-Path -LiteralPath (Join-Path $script:task781AckRoot '.winsmux\worker-runs\worker-1\submission-task781-accepted\run.json')) | Should -BeFalse
    }

    It 'TASK781 completes the canonical Codex packet to strong acknowledgement path' {
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation, $CallerIdentity, $ProcessResolver)
            $context = [PSCustomObject]@{
                generation_id = 'generation-1'; server_session_id = '$9'; slot_id = 'worker-1'
                pane_id = '%2'; backend = 'codex'
            }
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' -Diagnostic 'verified' -Context $context
        }
        Mock New-WinsmuxSubmissionPipeCallerEvidence {
            [PSCustomObject]@{
                caller_identity = [PSCustomObject]@{
                    process_id = 4300; process_started_at = '2026-07-15T00:00:02.0000000Z'
                    generation_id = 'generation-1'; server_session_id = '$9'; slot_id = 'worker-1'
                    pane_id = '%2'; backend = 'codex'
                }
                process_resolver = { param([int]$Id) $null }
            }
        }
        $script:task781DispatchPrompt = ''
        $script:task781AckReceiveCount = 0
        $script:task781CandidateRecord = $null
        $script:task781CandidateReceipt = $null
        $sendAction = {
            param([string]$PaneId, [string]$Text)
            $script:task781DispatchPrompt = $Text
        }
        Mock Receive-WinsmuxSubmissionAcknowledgement {
            $script:task781AckReceiveCount++
            if ($script:task781AckReceiveCount -eq 1) {
                $packet = Read-WinsmuxSubmissionPacket -Path (Join-Path $script:task781AckRoot '.winsmux\submissions\submission-task781-e2e.json')
                $script:task781CandidateRecord = New-WinsmuxSubmissionRunRecord -SubmissionId submission-task781-e2e `
                    -RunId submission-task781-e2e -TaskId ([string]$packet.task_id) -Kind task -TaskTitle ([string]$packet.title) `
                    -SlotId worker-1 -Backend codex -Status started -RequestConsumed -RequestDigest ([string]$packet.request_digest)
                $script:task781CandidateReceipt = New-WinsmuxSubmissionReceipt -Kind task -Status accepted -Backend codex `
                    -SubmissionId submission-task781-e2e -Target ([ordered]@{ label = 'worker-1'; pane_id = '%2'; role = 'Worker' }) `
                    -Acknowledgement $script:task781CandidateRecord
                return [PSCustomObject]@{
                    client_process_id = 4300
                    payload = New-WinsmuxSubmissionAcknowledgementEnvelope -Phase candidate `
                        -Challenge $script:task781AckPipeState.challenge -Receipt $script:task781CandidateReceipt
                }
            }
            return [PSCustomObject]@{
                client_process_id = 4300
                payload = New-WinsmuxSubmissionAcknowledgementEnvelope -Phase committed `
                    -Challenge $script:task781AckPipeState.challenge -Receipt $script:task781CandidateReceipt
            }
        }
        Mock Write-WinsmuxSubmissionAcknowledgementControl { }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781AckRoot -ManifestEntry $script:task781AckEntry `
            -Kind task -Content ([ordered]@{ title = 'TASK781 canonical ack'; request = 'Use the typed packet and acknowledge it.' }) `
            -SubmissionId submission-task781-e2e -SendAction $sendAction

        $receipt.status | Should -Be 'accepted'
        $receipt.acknowledgement.status | Should -Be 'started'
        $persistedRun = Get-Content -LiteralPath (Get-WinsmuxSubmissionRunPath -ProjectDir $script:task781AckRoot -SlotId worker-1 -RunId submission-task781-e2e) -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16
        $persistedRun.request_consumed | Should -BeTrue
        $script:task781DispatchPrompt | Should -Match "\.winsmux[/\\]submissions[/\\]submission-task781-e2e\.json"
        $script:task781DispatchPrompt | Should -Match 'winsmux submission-ack --submission-id submission-task781-e2e'
        $script:task781DispatchPrompt | Should -Match '--ack-pipe winsmux-submission-ack-33333333333333333333333333333333'
        $script:task781AckReceiveCount | Should -Be 2
        Should -Invoke Write-WinsmuxSubmissionAcknowledgementControl -Times 1 -Exactly -ParameterFilter { $Status -eq 'commit' }
        Should -Invoke Complete-WinsmuxSubmissionAcknowledgement -Times 1 -Exactly -ParameterFilter { $Verified }
    }

    It 'TASK781 C34 binds the canonical Codex production send to the captured generation lease' {
        $script:c34ReceiveCount = 0
        Mock Send-TextToPane {
            param($PaneId, $CommandText, $PromptTransport, $RuntimeProjectDir, $RuntimeOperation, $ExpectedGenerationId)
            if ($RuntimeProjectDir -cne $script:task781AckRoot -or $RuntimeOperation -cne 'dispatch' -or
                $ExpectedGenerationId -cne 'generation-1') {
                throw 'production submission send omitted the captured runtime lease'
            }
        }
        Mock Receive-WinsmuxSubmissionAcknowledgement {
            $script:c34ReceiveCount++
            $candidate = New-Task781SyntheticAckCandidate -ProjectDir $script:task781AckRoot `
                -SubmissionId submission-task781-c34-codex -Challenge $script:task781AckPipeState.challenge
            if ($script:c34ReceiveCount -eq 1) {
                return [PSCustomObject]@{ client_process_id = 4300; payload = $candidate.envelope }
            }
            return [PSCustomObject]@{
                client_process_id = 4300
                payload = New-WinsmuxSubmissionAcknowledgementEnvelope -Phase committed `
                    -Challenge $script:task781AckPipeState.challenge -Receipt $candidate.receipt
            }
        }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781AckRoot -ManifestEntry $script:task781AckEntry `
            -Kind task -Content 'Bind the production send to generation one.' -SubmissionId submission-task781-c34-codex

        $receipt.status | Should -Be 'accepted'
        Should -Invoke Send-TextToPane -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%2' -and $RuntimeProjectDir -ceq $script:task781AckRoot -and
            $RuntimeOperation -ceq 'dispatch' -and $ExpectedGenerationId -ceq 'generation-1'
        }
    }

    It 'TASK781 C34 binds the api_llm production send to the captured generation lease' {
        $entry = [PSCustomObject]@{
            Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; Role = 'Worker'; WorkerRole = 'worker'
            WorkerBackend = 'api_llm'; Title = 'W1 API Reviewer'; Status = 'ready'
        }
        Mock Send-TextToPane {
            param($PaneId, $CommandText, $PromptTransport, $RuntimeProjectDir, $RuntimeOperation, $ExpectedGenerationId)
            if ($RuntimeProjectDir -cne $script:task781AckRoot -or $RuntimeOperation -cne 'dispatch' -or
                $ExpectedGenerationId -cne 'generation-1') {
                throw 'api_llm production send omitted the captured runtime lease'
            }
        }
        $runResultAction = {
            param($ProjectDir, $SlotId, $RunId)
            $packet = Read-WinsmuxSubmissionPacket -Path (Join-Path $ProjectDir ".winsmux\submissions\$RunId.json")
            New-WinsmuxSubmissionRunRecord -SubmissionId $RunId -RunId $RunId -TaskId ([string]$packet.task_id) `
                -Kind task -TaskTitle ([string]$packet.title) -SlotId $SlotId -Backend api_llm -Status started `
                -RequestConsumed -RequestDigest ([string]$packet.request_digest)
        }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781AckRoot -ManifestEntry $entry `
            -Kind task -Content 'Bind api_llm production send to generation one.' `
            -SubmissionId submission-task781-c34-api -RunResultAction $runResultAction

        $receipt.status | Should -Be 'accepted'
        Should -Invoke Send-TextToPane -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%2' -and $RuntimeProjectDir -ceq $script:task781AckRoot -and
            $RuntimeOperation -ceq 'dispatch' -and $ExpectedGenerationId -ceq 'generation-1'
        }
    }

    It 'TASK781 accepts only with an adapter-owned durable run when final control delivery fails' {
        $script:task781FinalControlReceiveCount = 0
        Mock Receive-WinsmuxSubmissionAcknowledgement {
            $script:task781FinalControlReceiveCount++
            $candidate = New-Task781SyntheticAckCandidate -ProjectDir $script:task781AckRoot `
                -SubmissionId submission-task781-final-control-failure -Challenge $script:task781AckPipeState.challenge
            if ($script:task781FinalControlReceiveCount -eq 1) {
                return [PSCustomObject]@{ client_process_id = 4300; payload = $candidate.envelope }
            }
            return [PSCustomObject]@{
                client_process_id = 4300
                payload = New-WinsmuxSubmissionAcknowledgementEnvelope -Phase committed `
                    -Challenge $script:task781AckPipeState.challenge -Receipt $candidate.receipt
            }
        }
        Mock Complete-WinsmuxSubmissionAcknowledgement { $false }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781AckRoot -ManifestEntry $script:task781AckEntry `
            -Kind task -Content 'Final control delivery is not the durable authorization boundary.' `
            -SubmissionId submission-task781-final-control-failure -SendAction { param($PaneId, $Text) }
        $runPath = Get-WinsmuxSubmissionRunPath -ProjectDir $script:task781AckRoot -SlotId worker-1 `
            -RunId submission-task781-final-control-failure

        $receipt.status | Should -Be 'accepted'
        Test-Path -LiteralPath $runPath -PathType Leaf | Should -BeTrue
        Test-WinsmuxSubmissionRunRecord -Record (
            Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16
        ) -SubmissionId submission-task781-final-control-failure -Kind task -Backend codex `
            -ExpectedSlotId worker-1 | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:task781AckRoot '.winsmux\submissions\submission-task781-final-control-failure.json') `
            -PathType Leaf | Should -BeTrue
        Should -Invoke Complete-WinsmuxSubmissionAcknowledgement -Times 1 -Exactly -ParameterFilter { $Verified }
    }

    It 'TASK781 leaves no run record when the acknowledgement pipe times out' {
        Mock Receive-WinsmuxSubmissionAcknowledgement { throw 'synthetic pipe timeout' }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781AckRoot -ManifestEntry $script:task781AckEntry `
            -Kind task -Content 'Timeout must not authorize a run.' -SubmissionId submission-task781-timeout `
            -SendAction { param($PaneId, $Text) }

        $receipt.status | Should -Be 'rejected'
        $receipt.reason_code | Should -Be 'backend_acknowledgement_missing'
        (Test-Path -LiteralPath (Get-WinsmuxSubmissionRunPath -ProjectDir $script:task781AckRoot -SlotId worker-1 -RunId submission-task781-timeout)) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:task781AckRoot '.winsmux\submissions\submission-task781-timeout.json')) | Should -BeTrue
        Should -Invoke Write-WinsmuxSubmissionAcknowledgementControl -Times 0 -Exactly
        Should -Invoke Complete-WinsmuxSubmissionAcknowledgement -Times 1 -Exactly -ParameterFilter { -not $Verified }
    }

    It 'TASK781 rejects a mismatched challenge before commit and leaves no run record' {
        Mock Receive-WinsmuxSubmissionAcknowledgement {
            $candidate = New-Task781SyntheticAckCandidate -ProjectDir $script:task781AckRoot `
                -SubmissionId submission-task781-wrong-challenge -Challenge ('d' * 64)
            [PSCustomObject]@{ client_process_id = 4300; payload = $candidate.envelope }
        }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781AckRoot -ManifestEntry $script:task781AckEntry `
            -Kind task -Content 'Wrong challenge must fail.' -SubmissionId submission-task781-wrong-challenge `
            -SendAction { param($PaneId, $Text) }

        $receipt.status | Should -Be 'rejected'
        $receipt.reason_code | Should -Be 'runner_evidence_invalid'
        (Test-Path -LiteralPath (Get-WinsmuxSubmissionRunPath -ProjectDir $script:task781AckRoot -SlotId worker-1 -RunId submission-task781-wrong-challenge)) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:task781AckRoot '.winsmux\submissions\submission-task781-wrong-challenge.json')) | Should -BeTrue
        Should -Invoke Write-WinsmuxSubmissionAcknowledgementControl -Times 0 -Exactly
    }

    It 'TASK781 rejects a different pipe client PID before commit and leaves no run record' {
        Mock Receive-WinsmuxSubmissionAcknowledgement {
            $candidate = New-Task781SyntheticAckCandidate -ProjectDir $script:task781AckRoot `
                -SubmissionId submission-task781-wrong-pid -Challenge $script:task781AckPipeState.challenge
            [PSCustomObject]@{ client_process_id = 4999; payload = $candidate.envelope }
        }
        Mock New-WinsmuxSubmissionPipeCallerEvidence {
            [PSCustomObject]@{
                caller_identity = [PSCustomObject]@{
                    process_id = 4999; process_started_at = '2026-07-15T00:00:03.0000000Z'
                    generation_id = 'generation-1'; server_session_id = '$9'; slot_id = 'worker-1'
                    pane_id = '%2'; backend = 'codex'
                }
                process_resolver = { param([int]$Id) $null }
            }
        }
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation, $CallerIdentity, $ProcessResolver)
            if ($Operation -eq 'caller_ack') {
                return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'caller_identity_mismatch' -Diagnostic 'different pipe client'
            }
            $context = [PSCustomObject]@{
                generation_id = 'generation-1'; server_session_id = '$9'; slot_id = 'worker-1'; pane_id = '%2'; backend = 'codex'
            }
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' -Diagnostic 'verified' -Context $context
        }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781AckRoot -ManifestEntry $script:task781AckEntry `
            -Kind task -Content 'Different PID must fail.' -SubmissionId submission-task781-wrong-pid `
            -SendAction { param($PaneId, $Text) }

        $receipt.status | Should -Be 'unavailable'
        $receipt.reason_code | Should -Be 'caller_identity_mismatch'
        (Test-Path -LiteralPath (Get-WinsmuxSubmissionRunPath -ProjectDir $script:task781AckRoot -SlotId worker-1 -RunId submission-task781-wrong-pid)) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:task781AckRoot '.winsmux\submissions\submission-task781-wrong-pid.json')) | Should -BeTrue
        Should -Invoke Write-WinsmuxSubmissionAcknowledgementControl -Times 0 -Exactly
    }

    It 'TASK781 rejects a stale caller generation before commit and leaves no run record' {
        Mock Receive-WinsmuxSubmissionAcknowledgement {
            $candidate = New-Task781SyntheticAckCandidate -ProjectDir $script:task781AckRoot `
                -SubmissionId submission-task781-stale-generation -Challenge $script:task781AckPipeState.challenge
            [PSCustomObject]@{ client_process_id = 4300; payload = $candidate.envelope }
        }
        Mock New-WinsmuxSubmissionPipeCallerEvidence {
            [PSCustomObject]@{
                caller_identity = [PSCustomObject]@{
                    process_id = 4300; process_started_at = '2026-07-15T00:00:02.0000000Z'
                    generation_id = 'generation-old'; server_session_id = '$9'; slot_id = 'worker-1'
                    pane_id = '%2'; backend = 'codex'
                }
                process_resolver = { param([int]$Id) $null }
            }
        }
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation, $CallerIdentity, $ProcessResolver)
            if ($Operation -eq 'caller_ack') {
                return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'caller_identity_mismatch' -Diagnostic 'stale generation'
            }
            $context = [PSCustomObject]@{
                generation_id = 'generation-1'; server_session_id = '$9'; slot_id = 'worker-1'; pane_id = '%2'; backend = 'codex'
            }
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' -Diagnostic 'verified' -Context $context
        }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781AckRoot -ManifestEntry $script:task781AckEntry `
            -Kind task -Content 'Stale generation must fail.' -SubmissionId submission-task781-stale-generation `
            -SendAction { param($PaneId, $Text) }

        $receipt.status | Should -Be 'unavailable'
        $receipt.reason_code | Should -Be 'caller_identity_mismatch'
        (Test-Path -LiteralPath (Get-WinsmuxSubmissionRunPath -ProjectDir $script:task781AckRoot -SlotId worker-1 -RunId submission-task781-stale-generation)) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:task781AckRoot '.winsmux\submissions\submission-task781-stale-generation.json')) | Should -BeTrue
        Should -Invoke Write-WinsmuxSubmissionAcknowledgementControl -Times 0 -Exactly
    }

    It 'TASK781 rejects a pipe-only acknowledgement when no committed frame or run record arrives' {
        $script:task781PipeOnlyReceiveCount = 0
        Mock Receive-WinsmuxSubmissionAcknowledgement {
            $script:task781PipeOnlyReceiveCount++
            if ($script:task781PipeOnlyReceiveCount -eq 1) {
                $candidate = New-Task781SyntheticAckCandidate -ProjectDir $script:task781AckRoot `
                    -SubmissionId submission-task781-pipe-only -Challenge $script:task781AckPipeState.challenge
                return [PSCustomObject]@{ client_process_id = 4300; payload = $candidate.envelope }
            }
            throw 'synthetic committed frame timeout'
        }
        Mock Write-WinsmuxSubmissionAcknowledgementControl { }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781AckRoot -ManifestEntry $script:task781AckEntry `
            -Kind task -Content 'Pipe candidate alone must fail.' -SubmissionId submission-task781-pipe-only `
            -SendAction { param($PaneId, $Text) }

        $receipt.status | Should -Be 'rejected'
        $receipt.reason_code | Should -Be 'runner_evidence_invalid'
        (Test-Path -LiteralPath (Get-WinsmuxSubmissionRunPath -ProjectDir $script:task781AckRoot -SlotId worker-1 -RunId submission-task781-pipe-only)) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:task781AckRoot '.winsmux\submissions\submission-task781-pipe-only.json')) | Should -BeTrue
        Should -Invoke Write-WinsmuxSubmissionAcknowledgementControl -Times 1 -Exactly -ParameterFilter { $Status -eq 'commit' }
        Should -Invoke Complete-WinsmuxSubmissionAcknowledgement -Times 1 -Exactly -ParameterFilter { -not $Verified }
    }

    It 'TASK781 revalidates runtime after commit and retains the committed packet on expired lease' {
        $script:task781PostCommitReceiveCount = 0
        $script:task781PostCommitCallerChecks = 0
        Mock Receive-WinsmuxSubmissionAcknowledgement {
            $script:task781PostCommitReceiveCount++
            $candidate = New-Task781SyntheticAckCandidate -ProjectDir $script:task781AckRoot `
                -SubmissionId submission-task781-post-commit-expiry -Challenge $script:task781AckPipeState.challenge
            if ($script:task781PostCommitReceiveCount -eq 1) {
                return [PSCustomObject]@{ client_process_id = 4300; payload = $candidate.envelope }
            }
            return [PSCustomObject]@{
                client_process_id = 4300
                payload = New-WinsmuxSubmissionAcknowledgementEnvelope -Phase committed `
                    -Challenge $script:task781AckPipeState.challenge -Receipt $candidate.receipt
            }
        }
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation, $CallerIdentity, $ProcessResolver)
            $context = [PSCustomObject]@{
                generation_id = 'generation-1'; server_session_id = '$9'; slot_id = 'worker-1'; pane_id = '%2'; backend = 'codex'
            }
            if ($Operation -eq 'caller_ack') {
                $script:task781PostCommitCallerChecks++
                if ($script:task781PostCommitCallerChecks -gt 1) {
                    return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'invalid_supervisor_identity' -Diagnostic 'lease expired after commit'
                }
            }
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' -Diagnostic 'verified' -Context $context
        }
        Mock Write-WinsmuxSubmissionRunRecord { throw 'adapter write must not occur after failed fresh caller validation' }
        Mock Write-WinsmuxSubmissionAcknowledgementControl { }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781AckRoot -ManifestEntry $script:task781AckEntry `
            -Kind task -Content 'Lease expiry after commit must revoke acceptance.' `
            -SubmissionId submission-task781-post-commit-expiry -SendAction { param($PaneId, $Text) }

        $receipt.status | Should -Be 'unavailable'
        $receipt.reason_code | Should -Be 'invalid_supervisor_identity'
        $script:task781PostCommitCallerChecks | Should -Be 2
        (Test-Path -LiteralPath (Get-WinsmuxSubmissionRunPath -ProjectDir $script:task781AckRoot -SlotId worker-1 -RunId submission-task781-post-commit-expiry)) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:task781AckRoot '.winsmux\submissions\submission-task781-post-commit-expiry.json')) | Should -BeTrue
        Should -Invoke Write-WinsmuxSubmissionRunRecord -Times 0 -Exactly
        Should -Invoke Complete-WinsmuxSubmissionAcknowledgement -Times 1 -Exactly -ParameterFilter { -not $Verified }
    }

    It 'TASK781 preserves a racing run record and returns typed commit conflict without overwrite' {
        $script:task781ConflictReceiveCount = 0
        Mock Receive-WinsmuxSubmissionAcknowledgement {
            $script:task781ConflictReceiveCount++
            $candidate = New-Task781SyntheticAckCandidate -ProjectDir $script:task781AckRoot `
                -SubmissionId submission-task781-commit-conflict -Challenge $script:task781AckPipeState.challenge
            if ($script:task781ConflictReceiveCount -eq 1) {
                return [PSCustomObject]@{ client_process_id = 4300; payload = $candidate.envelope }
            }
            $runPath = Get-WinsmuxSubmissionRunPath -ProjectDir $script:task781AckRoot -SlotId worker-1 -RunId submission-task781-commit-conflict
            New-Item -ItemType Directory -Path (Split-Path -Parent $runPath) -Force | Out-Null
            [IO.File]::WriteAllText($runPath, 'race-winner', [Text.UTF8Encoding]::new($false))
            return [PSCustomObject]@{
                client_process_id = 4300
                payload = New-WinsmuxSubmissionAcknowledgementEnvelope -Phase committed `
                    -Challenge $script:task781AckPipeState.challenge -Receipt $candidate.receipt
            }
        }
        Mock Write-WinsmuxSubmissionAcknowledgementControl { }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781AckRoot -ManifestEntry $script:task781AckEntry `
            -Kind task -Content 'A racing record must win without overwrite.' -SubmissionId submission-task781-commit-conflict `
            -SendAction { param($PaneId, $Text) }
        $runPath = Get-WinsmuxSubmissionRunPath -ProjectDir $script:task781AckRoot -SlotId worker-1 -RunId submission-task781-commit-conflict

        $receipt.status | Should -Be 'rejected'
        $receipt.reason_code | Should -Be 'run_record_already_exists'
        (Get-Content -LiteralPath $runPath -Raw -Encoding UTF8) | Should -BeExactly 'race-winner'
        (Test-Path -LiteralPath (Join-Path $script:task781AckRoot '.winsmux\submissions\submission-task781-commit-conflict.json')) | Should -BeTrue
        Should -Invoke Complete-WinsmuxSubmissionAcknowledgement -Times 1 -Exactly -ParameterFilter { -not $Verified }
    }

    It 'TASK781 creates no packet when runtime identity expires before publication' {
        $script:task781DispatchValidationCount = 0
        Mock Test-PaneControlRuntimeContext {
            $script:task781DispatchValidationCount++
            if ($script:task781DispatchValidationCount -eq 1) {
                return New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' -Diagnostic 'verified'
            }
            return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'invalid_supervisor_identity' -Diagnostic 'lease expired before send'
        }
        $script:task781UnexpectedSendCount = 0
        $sendAction = {
            param([string]$PaneId, [string]$Text)
            $script:task781UnexpectedSendCount++
            throw 'send must not occur'
        }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781AckRoot -ManifestEntry $script:task781AckEntry `
            -Kind task -Content ([ordered]@{ title = 'TASK781 stale lease'; request = 'Do not send after lease expiry.' }) `
            -SubmissionId submission-task781-stale-before-send -SendAction $sendAction

        $receipt.status | Should -Be 'unavailable'
        $receipt.reason_code | Should -Be 'invalid_supervisor_identity'
        $script:task781UnexpectedSendCount | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $script:task781AckRoot '.winsmux\submissions\submission-task781-stale-before-send.json')) | Should -BeFalse
    }
}

Describe 'orchestra-start namespaced object targeting' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-start.ps1')
        $script:previousStartWinsmuxBin = $script:winsmuxBin
        $script:previousStartBridgeNamespace = $env:WINSMUX_BRIDGE_NAMESPACE_L
    }

    BeforeEach {
        $script:winsmuxBin = 'winsmux'
        $env:WINSMUX_BRIDGE_NAMESPACE_L = 'task781-start-test'
        $global:startWinsmuxCalls = [System.Collections.Generic.List[string]]::new()
        function global:winsmux {
            $global:LASTEXITCODE = 0
            $global:startWinsmuxCalls.Add((($args | ForEach-Object { [string]$_ }) -join ' ')) | Out-Null
            return 'ok'
        }
    }

    AfterEach {
        $script:winsmuxBin = $script:previousStartWinsmuxBin
        if ($null -ne $script:previousStartBridgeNamespace) {
            $env:WINSMUX_BRIDGE_NAMESPACE_L = $script:previousStartBridgeNamespace
        } else {
            Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
        }
        Remove-Item Function:\global:winsmux -ErrorAction SilentlyContinue
    }

    It 'qualifies a pane target before invoking the namespaced CLI' {
        $result = Invoke-Winsmux -Arguments @('display-message', '-t', '%2', '-p', '#{pane_id}') -CaptureOutput -TargetSessionName 'winsmux-orchestra'

        $result | Should -Be 'ok'
        @($global:startWinsmuxCalls) | Should -Be @('-L task781-start-test display-message -t winsmux-orchestra:%2 -p #{pane_id}')
    }

    It 'preserves explicit session and already-qualified targets' {
        Invoke-Winsmux -Arguments @('has-session', '-t', 'winsmux-orchestra') -TargetSessionName 'winsmux-orchestra'
        Invoke-Winsmux -Arguments @('display-message', '-t', 'winsmux-orchestra:%2', '-p', '#{pane_id}') -TargetSessionName 'winsmux-orchestra'

        @($global:startWinsmuxCalls) | Should -Be @(
            '-L task781-start-test has-session -t winsmux-orchestra',
            '-L task781-start-test display-message -t winsmux-orchestra:%2 -p #{pane_id}'
        )
    }
}

Describe 'winsmux workers command' {
BeforeAll {
        $script:winsmuxWorkersCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxWorkersCoreRawContent = Get-Content -LiteralPath $script:winsmuxWorkersCorePath -Raw -Encoding UTF8
        . $script:winsmuxWorkersCorePath 'version' *> $null

        function New-Task781WorkersStopFixture {
            param([Parameter(Mandatory = $true)][string]$ProjectDir)

            $bootstrapRoot = Join-Path (Join-Path $ProjectDir '.winsmux') 'orchestra-bootstrap'
            New-Item -ItemType Directory -Path $bootstrapRoot -Force | Out-Null
            $planPath = Join-Path $bootstrapRoot '_2.json'
            $markerPath = Join-Path $bootstrapRoot '_2-synthetic.ready.json'
            '{}' | Set-Content -LiteralPath $planPath -Encoding UTF8
            '{}' | Set-Content -LiteralPath $markerPath -Encoding UTF8

            $entry = [PSCustomObject]@{
                Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; Status = 'ready'; RuntimeReady = $true
                ManifestPath = 'synthetic-manifest'; BootstrapPlanPath = $planPath; BootstrapMarkerPath = $markerPath
            }
            $row = [PSCustomObject]@{
                Slot = 'w1'; SlotId = 'worker-1'; PaneId = '%2'; Backend = 'codex'; State = 'ready'
                LastFailureStage = ''; RecoveryAction = ''; ApprovedLaunch = $null; CurrentLaunch = $null; ApprovalDifferences = @()
            }
            $entriesBySlot = @{}
            $entriesBySlot['worker-1'] = $entry

            return [PSCustomObject]@{
                Entry = $entry; Row = $row; EntriesBySlot = $entriesBySlot; MarkerPath = $markerPath
            }
        }
    }

BeforeEach {
        $script:workersTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-workers-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:workersTempRoot -Force | Out-Null
        $script:previousWorkersNow = $env:WINSMUX_TEST_NOW_UTC
        $script:previousPublicOpenRouterApiKey = $env:OPENROUTER_API_KEY
        $script:previousAntigravityCli = $env:WINSMUX_ANTIGRAVITY_CLI
        $script:previousAntigravityPrintTimeout = $env:WINSMUX_ANTIGRAVITY_PRINT_TIMEOUT
        $env:WINSMUX_TEST_NOW_UTC = ''
        $env:OPENROUTER_API_KEY = ''
        $env:WINSMUX_ANTIGRAVITY_CLI = ''
        $env:WINSMUX_ANTIGRAVITY_PRINT_TIMEOUT = ''
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation)
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode ("{0}_verified" -f $Operation) `
                -Diagnostic 'synthetic worker runtime verified' -Context ([ordered]@{ generation_id = 'generation-workers' })
        }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            [PSCustomObject]@{ Managed = $true; Operation = 'dispatch'; GenerationId = 'generation-workers' }
        }
    }

AfterEach {
        $env:WINSMUX_TEST_NOW_UTC = $script:previousWorkersNow
        $env:OPENROUTER_API_KEY = $script:previousPublicOpenRouterApiKey
        $env:WINSMUX_ANTIGRAVITY_CLI = $script:previousAntigravityCli
        $env:WINSMUX_ANTIGRAVITY_PRINT_TIMEOUT = $script:previousAntigravityPrintTimeout
        if ($script:workersTempRoot -and (Test-Path -LiteralPath $script:workersTempRoot)) {
            Remove-Item -LiteralPath $script:workersTempRoot -Recurse -Force
        }

        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

function script:New-WorkersFakeAntigravityCli {
        param(
            [int]$ExitCode = 0,
            [string]$OutputLine = 'fake-antigravity response',
            [switch]$EmptyStdout
        )

        $fakeCli = Join-Path $script:workersTempRoot 'agy.cmd'
        $argsPath = Join-Path $script:workersTempRoot 'agy-args.txt'
        $outputCommand = if ($EmptyStdout) { 'rem intentionally empty stdout' } else { "echo $OutputLine" }
$content = @'
@echo off
if "%1"=="--help" (
  echo Usage: agy --print PROMPT --print-timeout DURATION --model MODEL
  exit /b 0
)
echo %* > "__ARGS_PATH__"
__OUTPUT_COMMAND__
exit /b __EXIT_CODE__
'@
        $content.Replace('__EXIT_CODE__', [string]$ExitCode).Replace('__OUTPUT_COMMAND__', $outputCommand).Replace('__ARGS_PATH__', $argsPath) | Set-Content -Path $fakeCli -Encoding ASCII
        $env:WINSMUX_ANTIGRAVITY_CLI = $fakeCli
        return $fakeCli
    }

function script:Write-WorkersAntigravityProjectConfig {
@'
agent: codex
model: provider-default
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: antigravity
    worker-role: impl
    agent: antigravity
    model: gemini-3.5-flash
    model-source: operator-override
    prompt-transport: file
    auth-mode: antigravity-official-cli
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot '.winsmux') -Force | Out-Null
@'
{
  "version": 1,
  "providers": {
    "antigravity": {
      "adapter": "antigravity",
      "display_name": "Antigravity CLI",
      "command": "agy",
      "prompt_transports": ["argv", "file"],
      "auth_modes": ["antigravity-official-cli"],
      "model_sources": ["provider-default", "cli-discovery", "operator-override"],
      "credential_requirements": "local-cli-owned",
      "execution_backend": "antigravity-cli-print",
      "runtime_requirements": "Antigravity CLI agy installed in the pane environment.",
      "analysis_posture": "read-write-worker",
      "supports_file_edit": true,
      "supports_structured_result": true
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux\provider-capabilities.json') -Encoding UTF8
    }

function script:Write-WorkersApiLlmProjectConfig {
@'
agent: codex
model: provider-default
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: api_llm
    worker-role: impl
    agent: openrouter
    model: z-ai/glm-5.2
    model-source: operator-override
    prompt-transport: file
    auth-mode: api-key-env
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot '.winsmux') -Force | Out-Null
@'
{
  "version": 1,
  "providers": {
    "openrouter": {
      "adapter": "openai-compatible",
      "display_name": "OpenRouter",
      "command": "openrouter",
      "prompt_transports": ["file"],
      "auth_modes": ["api-key-env", "api-key-vault"],
      "model_sources": ["provider-default", "operator-override"],
      "reasoning_efforts": ["provider-default"],
      "credential_requirements": "runtime-owned-api-key",
      "execution_backend": "openai-compatible-chat-completions",
      "api_base_url": "https://openrouter.ai/api/v1",
      "api_key_env": "OPENROUTER_API_KEY",
      "analysis_posture": "hosted-api-worker",
      "supports_file_edit": false,
      "supports_structured_result": true
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux\provider-capabilities.json') -Encoding UTF8
    }

It 'documents and routes the workers lifecycle command' {
        $script:winsmuxWorkersCoreRawContent | Should -Match 'workers <status\|start\|stop\|doctor> \[slot\|all\] \[--json\] \[--project-dir <path>\]'
        $script:winsmuxWorkersCoreRawContent | Should -Match 'workers <exec\|logs> <slot> \.\.\. \[--json\] \[--project-dir <path>\]'
        $script:winsmuxWorkersCoreRawContent | Should -Match 'workers workspace <prepare\|cleanup> <slot> \[--include <path>\] \[--run-id <id>\] \[--json\] \[--project-dir <path>\]'
        $script:winsmuxWorkersCoreRawContent | Should -Match 'workers secrets project <slot> --run-id <id> \[--env <name=key>\] \[--file <path=key>\] \[--variable <name=key>\] \[--json\] \[--project-dir <path>\]'
        $script:winsmuxWorkersCoreRawContent | Should -Match 'workers heartbeat <mark\|check> <slot> \[--run-id <id>\] \[--state <state>\] \[--json\] \[--project-dir <path>\]'
        $script:winsmuxWorkersCoreRawContent | Should -Match 'workers sandbox baseline <slot> --run-id <id> \[--json\] \[--project-dir <path>\]'
        $script:winsmuxWorkersCoreRawContent | Should -Match 'workers broker baseline <slot> --run-id <id> --endpoint <url> \[--node-id <id>\] \[--json\] \[--project-dir <path>\]'
        $script:winsmuxWorkersCoreRawContent | Should -Match 'workers broker token <issue\|check> <slot> --run-id <id> \[--ttl-seconds <n>\] \[--no-refresh\] \[--json\] \[--project-dir <path>\]'
        $script:winsmuxWorkersCoreRawContent | Should -Match 'workers policy baseline <slot> --run-id <id> \[--network <mode>\] \[--write <mode>\] \[--provider <mode>\] \[--json\] \[--project-dir <path>\]'
        $script:winsmuxWorkersCoreRawContent | Should -Match "'workers'\s*\{\s*Invoke-Workers\s*\}"
        $script:winsmuxWorkersCoreRawContent | Should -Match 'uv not found on PATH'
        $script:winsmuxWorkersCoreRawContent | Should -Match "'exec'\s*\{\s*Invoke-WorkersExec\s*\}"
        $script:winsmuxWorkersCoreRawContent | Should -Match "'logs'\s*\{\s*Invoke-WorkersLogs\s*\}"
        $script:winsmuxWorkersCoreRawContent | Should -Not -Match "'attach'\s*\{\s*Invoke-WorkersAttach\s*\}"
        $script:winsmuxWorkersCoreRawContent | Should -Not -Match "'upload'\s*\{\s*Invoke-WorkersUpload\s*\}"
        $script:winsmuxWorkersCoreRawContent | Should -Not -Match "'download'\s*\{\s*Invoke-WorkersDownload\s*\}"
        $script:winsmuxWorkersCoreRawContent | Should -Match "'workspace'\s*\{\s*Invoke-WinsmuxWorkersWorkspaceCommand"
        $script:winsmuxWorkersCoreRawContent | Should -Match "'secrets'\s*\{\s*Invoke-WorkersSecrets\s*\}"
        $script:winsmuxWorkersCoreRawContent | Should -Match "'heartbeat'\s*\{\s*Invoke-WorkersHeartbeat\s*\}"
        $script:winsmuxWorkersCoreRawContent | Should -Match "'sandbox'\s*\{\s*Invoke-WorkersSandbox\s*\}"
        $script:winsmuxWorkersCoreRawContent | Should -Match "'broker'\s*\{\s*Invoke-WorkersBroker\s*\}"
        $script:winsmuxWorkersCoreRawContent | Should -Match "'policy'\s*\{\s*Invoke-WorkersPolicy\s*\}"
    }

It 'prepares and cleans up a disposable isolated workspace from explicit includes' {
@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    execution-profile: isolated-enterprise
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot 'src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot 'docs') -Force | Out-Null
        'Write-Output "ok"' | Set-Content -Path (Join-Path $script:workersTempRoot 'src\tool.ps1') -Encoding UTF8
        'spec' | Set-Content -Path (Join-Path $script:workersTempRoot 'docs\spec.md') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include src/tool.ps1 --include docs --run-id isolated-run --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $serialized = $payload | ConvertTo-Json -Depth 24
        $runDir = Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\isolated-run'

        $payload.status | Should -Be 'prepared'
        $payload.execution_profile | Should -Be 'isolated-enterprise'
        $payload.workspace_lifecycle | Should -Be 'disposable'
        $payload.policy.direct_project_write | Should -Be 'prohibited'
        $payload.locations.workspace.kind | Should -Be 'local_directory'
        $payload.locations.workspace.access_method | Should -Be 'isolated_workspace'
        $payload.locations.downloads.access_method | Should -Be 'isolated_downloads'
        $payload.locations.artifacts.access_method | Should -Be 'isolated_artifacts'
        $payload.locations.manifest.kind | Should -Be 'local_file'
        $payload.locations.workspace.local_path | Should -Be ''
        $serialized | Should -Not -Match ([regex]::Escape($script:workersTempRoot))
        $serialized | Should -Not -Match ([regex]::Escape($script:workersTempRoot.Replace('\', '\\')))
        @($payload.projections | ForEach-Object { $_.source }) | Should -Contain 'src/tool.ps1'
        @($payload.projections | ForEach-Object { $_.source }) | Should -Contain 'docs'
        Test-Path -LiteralPath (Join-Path $runDir 'workspace\src\tool.ps1') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $runDir 'workspace\docs\spec.md') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot 'src\tool.ps1') | Should -Be $true

        $cleanupOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace cleanup worker-2 --run-id isolated-run --json --project-dir $script:workersTempRoot
        $cleanupPayload = ($cleanupOutput | Select-Object -Last 1) | ConvertFrom-Json

        $cleanupPayload.status | Should -Be 'cleaned'
        $cleanupPayload.existed | Should -Be $true
        Test-Path -LiteralPath $runDir | Should -Be $false
    }

It 'requires the isolated-enterprise execution profile for isolated workspaces' {
@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    execution-profile: local-windows
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        'payload' | Set-Content -Path (Join-Path $script:workersTempRoot 'input.txt') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id local-profile --json --project-dir $script:workersTempRoot 2>&1

        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match "not isolated-enterprise"
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\local-profile') | Should -Be $false
    }

It 'rejects unsafe isolated workspace projection paths' {
@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    execution-profile: isolated-enterprise
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot 'safe') -Force | Out-Null
        'payload' | Set-Content -Path (Join-Path $script:workersTempRoot 'safe\data.txt') -Encoding UTF8

        $rootOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include . --run-id root-include --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($rootOutput | Out-String) | Should -Match 'not the project root'

        $escapeOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include ..\escape --run-id traversal --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($escapeOutput | Out-String) | Should -Match 'unsupported path segment'

        $reservedOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include CON --run-id reserved --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($reservedOutput | Out-String) | Should -Match 'reserved Windows name'

        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\root-include') | Should -Be $false
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\traversal') | Should -Be $false
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\reserved') | Should -Be $false
    }

It 'rejects reparse points in isolated workspace projections' {
@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    execution-profile: isolated-enterprise
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        $outside = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-isolated-outside-' + [guid]::NewGuid().ToString('N'))
        $linkedInput = Join-Path $script:workersTempRoot 'linked-input'

        try {
            New-Item -ItemType Directory -Path $outside -Force | Out-Null
            'secret' | Set-Content -Path (Join-Path $outside 'secret.txt') -Encoding UTF8
            New-Item -ItemType Junction -Path $linkedInput -Target $outside | Out-Null

            $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include linked-input --run-id reparse --json --project-dir $script:workersTempRoot 2>&1

            $LASTEXITCODE | Should -Be 1
            ($output | Out-String) | Should -Match 'unsupported reparse point'
            Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\reparse') | Should -Be $false
        } finally {
            if (Test-Path -LiteralPath $linkedInput) {
                Remove-Item -LiteralPath $linkedInput -Force
            }
            if (Test-Path -LiteralPath $outside) {
                Remove-Item -LiteralPath $outside -Recurse -Force
            }
        }
    }

It 'cleans isolated workspace run directories without following worker-created reparse points' {
@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    execution-profile: isolated-enterprise
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        'payload' | Set-Content -Path (Join-Path $script:workersTempRoot 'input.txt') -Encoding UTF8
        $outside = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-isolated-cleanup-outside-' + [guid]::NewGuid().ToString('N'))
        $runDir = Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\cleanup-reparse'
        $linkedOutput = Join-Path $runDir 'workspace\worker-link'

        try {
            $prepareOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id cleanup-reparse --json --project-dir $script:workersTempRoot
            $preparePayload = ($prepareOutput | Select-Object -Last 1) | ConvertFrom-Json
            $preparePayload.status | Should -Be 'prepared'

            New-Item -ItemType Directory -Path $outside -Force | Out-Null
            'external' | Set-Content -Path (Join-Path $outside 'external.txt') -Encoding UTF8
            New-Item -ItemType Junction -Path $linkedOutput -Target $outside | Out-Null

            $cleanupOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace cleanup w2 --run-id cleanup-reparse --json --project-dir $script:workersTempRoot
            $cleanupPayload = ($cleanupOutput | Select-Object -Last 1) | ConvertFrom-Json

            $cleanupPayload.status | Should -Be 'cleaned'
            Test-Path -LiteralPath $runDir | Should -Be $false
            Test-Path -LiteralPath (Join-Path $outside 'external.txt') | Should -Be $true
        } finally {
            if (Test-Path -LiteralPath $linkedOutput) {
                Remove-Item -LiteralPath $linkedOutput -Force
            }
            if (Test-Path -LiteralPath $runDir) {
                Remove-Item -LiteralPath $runDir -Recurse -Force
            }
            if (Test-Path -LiteralPath $outside) {
                Remove-Item -LiteralPath $outside -Recurse -Force
            }
        }
    }

It 'defines a Windows sandbox baseline for prepared isolated runs without claiming full isolation' {
@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    execution-profile: isolated-enterprise
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        'payload' | Set-Content -Path (Join-Path $script:workersTempRoot 'input.txt') -Encoding UTF8
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id sandbox-run --json --project-dir $script:workersTempRoot | Out-Null

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers sandbox baseline worker-2 --run-id sandbox-run --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $serialized = $payload | ConvertTo-Json -Depth 32
        $manifestPath = Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\sandbox-run\sandbox-baseline.json'

        $payload.status | Should -Be 'baseline_defined'
        $payload.execution_profile | Should -Be 'isolated-enterprise'
        $payload.public_default | Should -Be $false
        $payload.boundary.process.token.kind | Should -Be 'restricted_token'
        $payload.boundary.process.token.required | Should -Be $true
        $payload.boundary.filesystem.acl.kind | Should -Be 'run_acl_boundary'
        $payload.boundary.filesystem.acl.verified_no_reparse_points | Should -Be $true
        $payload.boundary.credentials.value_output | Should -Be $false
        $payload.failure_policy.unsafe_claims_prohibited | Should -Be $true
        $payload.isolation_claim.secure | Should -Be $false
        $payload.isolation_claim.reason | Should -Match 'restricted token'
        $payload.locations.manifest.reference | Should -Be '.winsmux/isolated-workspaces/worker-2/sandbox-run/sandbox-baseline.json'
        @($payload.testable_guards) | Should -Contain 'isolated_enterprise_profile_required'
        Test-Path -LiteralPath $manifestPath | Should -Be $true
        $serialized | Should -Not -Match ([regex]::Escape($script:workersTempRoot))
        $serialized | Should -Not -Match ([regex]::Escape($script:workersTempRoot.Replace('\', '\\')))
    }

It 'fails closed for Windows sandbox baselines outside the prepared isolated boundary' {
@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    execution-profile: local-windows
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        'payload' | Set-Content -Path (Join-Path $script:workersTempRoot 'input.txt') -Encoding UTF8

        $localProfile = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers sandbox baseline worker-2 --run-id sandbox-local --profile local-windows --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($localProfile | Out-String) | Should -Match 'requires execution profile isolated-enterprise'

        $missingRun = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers sandbox baseline worker-2 --run-id sandbox-missing --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($missingRun | Out-String) | Should -Match 'uses execution profile'
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\sandbox-missing\sandbox-baseline.json') | Should -Be $false

@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    execution-profile: isolated-enterprise
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        $missingIsolatedRun = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers sandbox baseline worker-2 --run-id sandbox-missing --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($missingIsolatedRun | Out-String) | Should -Match 'requires an existing isolated workspace run'
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\sandbox-missing\sandbox-baseline.json') | Should -Be $false
    }

It 'rejects worker-created reparse points before writing the Windows sandbox baseline manifest' {
@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    execution-profile: isolated-enterprise
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        'payload' | Set-Content -Path (Join-Path $script:workersTempRoot 'input.txt') -Encoding UTF8
        $outside = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-sandbox-outside-' + [guid]::NewGuid().ToString('N'))
        $runDir = Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\sandbox-reparse'
        $linkedOutput = Join-Path $runDir 'workspace\worker-link'

        try {
            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id sandbox-reparse --json --project-dir $script:workersTempRoot | Out-Null
            New-Item -ItemType Directory -Path $outside -Force | Out-Null
            'external' | Set-Content -Path (Join-Path $outside 'external.txt') -Encoding UTF8
            New-Item -ItemType Junction -Path $linkedOutput -Target $outside | Out-Null

            $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers sandbox baseline w2 --run-id sandbox-reparse --json --project-dir $script:workersTempRoot 2>&1

            $LASTEXITCODE | Should -Be 1
            ($output | Out-String) | Should -Match 'unsupported reparse point'
            Test-Path -LiteralPath (Join-Path $runDir 'sandbox-baseline.json') | Should -Be $false
        } finally {
            if (Test-Path -LiteralPath $linkedOutput) {
                Remove-Item -LiteralPath $linkedOutput -Force
            }
            if (Test-Path -LiteralPath $runDir) {
                Remove-Item -LiteralPath $runDir -Recurse -Force
            }
            if (Test-Path -LiteralPath $outside) {
                Remove-Item -LiteralPath $outside -Recurse -Force
            }
        }
    }
}
