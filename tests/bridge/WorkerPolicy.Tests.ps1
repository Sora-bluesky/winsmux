$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'TASK-780 typed submission review fixes' {
    BeforeAll {
        $script:task780RepoRoot = Split-Path -Parent $script:BridgeTestsRoot
        $script:task780CorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:task780ApiWorkerPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\api-llm-pane-worker.ps1'
        $script:task780RouterPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\dispatch-router.ps1'
        $script:task780BuilderQueuePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\builder-queue.ps1'
        $script:task780RustMainPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'core\src\main.rs'
        . $script:task780CorePath 'version' *> $null
        . $script:task780RouterPath
        . $script:task780BuilderQueuePath
    }

    BeforeEach {
        $script:task780TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-task780-review-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:task780TempRoot -Force | Out-Null
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation)
            if ([string]$Operation -ceq 'caller_ack') {
                return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'caller_identity_mismatch' -Diagnostic 'synthetic caller ancestry is not authoritative'
            }
            return New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'dispatch_runtime_verified' `
                -Diagnostic 'synthetic dispatch runtime verified' -Context ([ordered]@{ generation_id = 'generation-1' })
        }
        Mock New-WinsmuxSubmissionAcknowledgementServer {
            [PSCustomObject]@{ pipe_name = 'winsmux-submission-ack-22222222222222222222222222222222'; challenge = ('b' * 64); server = $null }
        }
        Mock Receive-WinsmuxSubmissionAcknowledgement { throw 'synthetic acknowledgement absent' }
        Mock Complete-WinsmuxSubmissionAcknowledgement { $true }
    }

    AfterEach {
        if ($script:task780TempRoot -and (Test-Path -LiteralPath $script:task780TempRoot)) {
            Remove-Item -LiteralPath $script:task780TempRoot -Recurse -Force
        }
    }

    It 'TASK781 C19 derives the builder queue write guard from the loaded manifest snapshot' {
        $manifest = [PSCustomObject]@{
            session = [PSCustomObject]@{ generation_id = 'generation-initial' }
        }
        Mock Get-PaneControlManifestGenerationId { 'generation-replacement' }

        Get-BuilderQueueExpectedGenerationId -Manifest $manifest | Should -BeExactly 'generation-initial'

        Should -Invoke Get-PaneControlManifestGenerationId -Times 0 -Exactly
    }

    It 'TASK781 C19 threads the queue snapshot through its pane state follow-up' {
        $snapshot = [ordered]@{
            ManifestPath = 'C:\repo\.winsmux\manifest.yaml'
            PaneId = '%2'
            GenerationId = 'generation-initial'
        }
        $script:capturedQueueGeneration = ''
        Mock Get-PaneControlManifestEntries {
            @([pscustomobject]@{ ManifestPath = 'replacement'; PaneId = '%9'; GenerationId = 'generation-replacement' })
        }
        Mock Set-PaneControlManifestPaneProperties {
            param($ManifestPath, $PaneId, $Properties, $ExpectedGenerationId)
            $script:capturedQueueGeneration = [string]$ExpectedGenerationId
        }

        Update-BuilderQueuePaneState -PaneContext $snapshot -Properties ([ordered]@{ task_state = 'completed' })

        $script:capturedQueueGeneration | Should -BeExactly 'generation-initial'
        Should -Invoke Get-PaneControlManifestEntries -Times 0 -Exactly
    }

    It 'TASK781 C19 carries the loaded generation through the production queue completion caller' {
        $rawEntry = 'task-301|builder-1|bounded queue task'
        $manifest = [pscustomobject]@{
            session = [pscustomobject]@{ generation_id = 'generation-initial' }
            panes = [ordered]@{ 'builder-1' = [pscustomobject]@{ pane_id = '%2' } }
            tasks = [pscustomobject]@{ queued = @(); in_progress = @($rawEntry); completed = @() }
        }
        $script:queueCallerGeneration = ''
        Mock Get-BuilderQueueManifest { $manifest }
        Mock Get-BuilderQueueEntries {
            if ($State -ceq 'in_progress') {
                return @([pscustomobject]@{
                    TaskId = 'task-301'
                    BuilderLabel = 'builder-1'
                    Task = 'bounded queue task'
                    RawEntry = $rawEntry
                })
            }
            return @()
        }
        Mock Save-BuilderQueueManifest { }
        Mock Unlock-DispatchFiles { $true }
        Mock Set-PaneControlManifestPaneProperties {
            $script:queueCallerGeneration = [string]$ExpectedGenerationId
        }
        Mock Get-PaneControlManifestGenerationId { 'generation-replacement' }
        Mock Dispatch-NextBuilderQueueTask {
            [pscustomobject]@{ Dispatched = $false; CurrentTask = $null }
        }
        Mock Get-BuilderQueueSnapshot { [pscustomobject]@{} }

        $result = Complete-BuilderQueueTask -ProjectDir $script:task780TempRoot -BuilderLabel 'builder-1'

        $result.CompletedTask | Should -BeExactly 'bounded queue task'
        $script:queueCallerGeneration | Should -BeExactly 'generation-initial'
        Should -Invoke Get-PaneControlManifestGenerationId -Times 0 -Exactly
    }

    It 'P1 refuses pane input echo when strong caller identity is unavailable' {
        $entry = [PSCustomObject]@{ Label = 'worker-2'; PaneId = '%2'; Role = 'Worker'; WorkerBackend = 'codex' }
        $script:echoedPrompt = ''
        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content 'synthetic implementation request' -SubmissionId 'submission-review-echo' `
            -SendAction { param($paneId, $commandText) $script:echoedPrompt = $commandText; "sent to $paneId" } `
            -CaptureAction { param($paneId) $script:echoedPrompt } `
            -RunResultAction { param($projectDir, $slotId, $runId) $null }

        $receipt.GetType().Name | Should -Not -Be 'Object[]'
        $receipt.status | Should -Be 'rejected'
        $receipt.reason_code | Should -Be 'backend_acknowledgement_missing'
        $script:echoedPrompt | Should -Match 'typed submission packet'
        $script:echoedPrompt | Should -Not -Match 'synthetic implementation request'
    }

    It 'P1 rejects unsafe target labels before composing a pane command' {
        $entry = [PSCustomObject]@{ Label = 'worker-1;Write-Output injected'; PaneId = '%2'; Role = 'Worker'; WorkerBackend = 'codex' }
        $script:unsafeTargetSendCalled = $false
        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content 'synthetic request' -SubmissionId 'submission-unsafe-target' `
            -SendAction { $script:unsafeTargetSendCalled = $true }

        $receipt.status | Should -Be 'rejected'
        $receipt.reason_code | Should -Be 'target_identifier_invalid'
        $script:unsafeTargetSendCalled | Should -Be $false
    }

    It 'P1 validates accepted evidence type kind and matching submission and run ids' {
        $missing = New-WinsmuxSubmissionReceipt -Kind task -Status accepted -Backend codex -SubmissionId 'submission-review-evidence'
        (Test-WinsmuxSubmissionReceipt -Receipt $missing) | Should -Be $false

        foreach ($evidence in @(
            [ordered]@{ type = 'unknown'; submission_id = 'submission-review-evidence'; run_id = 'submission-review-evidence'; kind = 'task'; status = 'started'; backend_owned = $true; request_consumed = $true },
            [ordered]@{ type = 'backend_run_record'; submission_id = 'other'; run_id = 'submission-review-evidence'; kind = 'task'; status = 'started'; backend_owned = $true; request_consumed = $true },
            [ordered]@{ type = 'backend_run_record'; submission_id = 'submission-review-evidence'; run_id = 'other'; kind = 'task'; status = 'started'; backend_owned = $true; request_consumed = $true },
            [ordered]@{ type = 'backend_run_record'; submission_id = 'submission-review-evidence'; run_id = 'submission-review-evidence'; kind = 'review'; status = 'started'; backend_owned = $true; request_consumed = $true }
        )) {
            $receipt = New-WinsmuxSubmissionReceipt -Kind task -Status accepted -Backend codex -SubmissionId 'submission-review-evidence' -Acknowledgement $evidence
            (Test-WinsmuxSubmissionReceipt -Receipt $receipt) | Should -Be $false
        }

        $validEvidence = New-WinsmuxSubmissionRunRecord -SubmissionId 'submission-review-evidence' -RunId 'submission-review-evidence' -Kind task -TaskTitle 'Review evidence test' -SlotId worker-1 -Backend codex -Status started -RequestConsumed -RequestDigest ('b' * 64)
        $validReceipt = New-WinsmuxSubmissionReceipt -Kind task -Status accepted -Backend codex -SubmissionId 'submission-review-evidence' -Target ([ordered]@{ label = 'worker-1' }) -Acknowledgement $validEvidence
        (Test-WinsmuxSubmissionReceipt -Receipt $validReceipt) | Should -Be $true
        foreach ($evidenceMutation in @(
            [ordered]@{ name = 'type'; value = 'unknown' },
            [ordered]@{ name = 'protocol_version'; value = 2 },
            [ordered]@{ name = 'status'; value = 'failed' },
            [ordered]@{ name = 'submission_id'; value = 'other-task' },
            [ordered]@{ name = 'run_id'; value = 'other-run' },
            [ordered]@{ name = 'kind'; value = 'review' },
            [ordered]@{ name = 'backend'; value = 'local' },
            [ordered]@{ name = 'worker_kind'; value = 'critic' },
            [ordered]@{ name = 'slot_id'; value = '../escape' },
            [ordered]@{ name = 'slot_id'; value = 'worker-2' },
            [ordered]@{ name = 'request_digest'; value = ('c' * 63) }
        )) {
            $invalidEvidence = New-WinsmuxSubmissionRunRecord -SubmissionId 'submission-review-evidence' -RunId 'submission-review-evidence' -Kind task -TaskTitle 'Review evidence test' -SlotId worker-1 -Backend codex -Status started -RequestConsumed -RequestDigest ('b' * 64)
            $invalidEvidence[$evidenceMutation.name] = $evidenceMutation.value
            $invalidReceipt = New-WinsmuxSubmissionReceipt -Kind task -Status accepted -Backend codex -SubmissionId 'submission-review-evidence' -Target ([ordered]@{ label = 'worker-1' }) -Acknowledgement $invalidEvidence
            (Test-WinsmuxSubmissionReceipt -Receipt $invalidReceipt) | Should -Be $false
        }
        foreach ($mutation in @(
            { param($receipt) $receipt.protocol_version = 2 },
            { param($receipt) $receipt.protocol_version = '1' },
            { param($receipt) $receipt.status = 'complete' },
            { param($receipt) $receipt.kind = 'unknown' },
            { param($receipt) $receipt.submission_id = '' }
        )) {
            $invalid = New-WinsmuxSubmissionReceipt -Kind task -Status accepted -Backend codex -SubmissionId 'submission-review-evidence' -Target ([ordered]@{ label = 'worker-1' }) -Acknowledgement $validEvidence
            & $mutation $invalid
            (Test-WinsmuxSubmissionReceipt -Receipt $invalid) | Should -Be $false
            { ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $invalid } | Should -Throw
        }
    }

    It 'P1 emits one packet schema whose real worker fields are top level and not double encoded' {
        $packetRef = New-WinsmuxSubmissionPacket -ProjectDir $script:task780TempRoot -Kind review -Content ([ordered]@{
            title = 'Review synthetic change'
            request = 'Inspect the bounded diff.'
            files = @('src/example.rs')
            tests = @('cargo test synthetic')
            branch = 'synthetic/review'
            head_sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        }) -SubmissionId 'submission-review-packet' -TargetLabel 'worker-3'
        $packet = Get-Content -LiteralPath $packetRef.FullPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $packet.protocol_version | Should -Be 1
        $packet.kind | Should -Be 'review'
        $packet.run_id | Should -Be 'submission-review-packet'
        $packet.title | Should -Be 'Review synthetic change'
        @($packet.files) | Should -Be @('src/example.rs')
        @($packet.tests) | Should -Be @('cargo test synthetic')
        $packet.request | Should -Be 'Inspect the bounded diff.'
        $packet.PSObject.Properties.Name | Should -Not -Contain 'content'
    }

    It 'P1 rejects malformed packet field types and broken submission invariants before backend execution' {
        $valid = New-WinsmuxSubmissionPacketData -Kind task -Content ([ordered]@{ title = 'Typed packet'; request = 'Consume typed input.' }) -SubmissionId 'submission-schema-check' -TargetLabel worker-1
        (Test-WinsmuxSubmissionPacket -Packet $valid) | Should -Be $true

        foreach ($mutation in @(
            { param($packet) $packet.run_id = 'other-run' },
            { param($packet) $packet.task_id = 'invalid task id' },
            { param($packet) $packet.protocol_version = '1' },
            { param($packet) $packet.target = @('worker-1') },
            { param($packet) $packet.title = @('not-a-string') },
            { param($packet) $packet.files = 'not-an-array' },
            { param($packet) $packet.tests = @([ordered]@{ command = 'cargo test' }) },
            { param($packet) $packet.branch = @('not-a-string') },
            { param($packet) $packet.head_sha = 'not-a-sha' }
        )) {
            $candidate = New-WinsmuxSubmissionPacketData -Kind task -Content ([ordered]@{ title = 'Typed packet'; request = 'Consume typed input.' }) -SubmissionId 'submission-schema-check' -TargetLabel worker-1
            & $mutation $candidate
            (Test-WinsmuxSubmissionPacket -Packet $candidate) | Should -Be $false
        }
    }

    It 'P1 refuses local acknowledgement until strong caller authority is available' {
        $manifestDir = Join-Path $script:task780TempRoot '.winsmux'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $manifestDir 'manifest.yaml'), @'
version: 1
session:
  name: task780-test
panes:
  worker-1:
    pane_id: "%2"
    role: Worker
    worker_backend: codex
'@, [Text.UTF8Encoding]::new($false))
        New-WinsmuxSubmissionPacket -ProjectDir $script:task780TempRoot -Kind task -Content ([ordered]@{ title = 'Ack target'; request = 'Acknowledge typed input.' }) -SubmissionId 'submission-ack-bound' -TargetLabel worker-1 | Out-Null
        $previousPaneId = $env:WINSMUX_PANE_ID
        try {
            $env:WINSMUX_PANE_ID = '%2'
            $receipt = Invoke-WinsmuxSubmissionAcknowledge -ProjectDir $script:task780TempRoot -SlotId worker-1 -SubmissionId 'submission-ack-bound' -RunId 'submission-ack-bound' -Kind task -Backend codex
            $receipt.status | Should -Be 'unavailable'
            $receipt.reason_code | Should -Be 'caller_identity_mismatch'

            New-WinsmuxSubmissionPacket -ProjectDir $script:task780TempRoot -Kind task -Content ([ordered]@{ title = 'Wrong pane'; request = 'Reject wrong pane.' }) -SubmissionId 'submission-ack-wrong-pane' -TargetLabel worker-1 | Out-Null
            $env:WINSMUX_PANE_ID = '%9'
            (Invoke-WinsmuxSubmissionAcknowledge -ProjectDir $script:task780TempRoot -SlotId worker-1 -SubmissionId 'submission-ack-wrong-pane' -RunId 'submission-ack-wrong-pane' -Kind task -Backend codex).status | Should -Be 'unavailable'

            $env:WINSMUX_PANE_ID = '%2'
            (Invoke-WinsmuxSubmissionAcknowledge -ProjectDir $script:task780TempRoot -SlotId worker-1 -SubmissionId 'submission-ack-wrong-pane' -RunId 'submission-ack-wrong-pane' -Kind task -Backend local).reason_code | Should -Be 'caller_identity_mismatch'
        } finally {
            $env:WINSMUX_PANE_ID = $previousPaneId
        }
    }

    It 'P1 rejects a pre-existing run record instead of reusing it as acceptance' {
        $entry = [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%2'; Role = 'Worker'; WorkerBackend = 'codex' }
        $stale = New-WinsmuxSubmissionRunRecord -SubmissionId 'submission-stale-run' -RunId 'submission-stale-run' -Kind task -TaskTitle 'Stale run' -SlotId worker-1 -Backend codex -Status started -RequestConsumed -RequestDigest ('d' * 64)
        Write-WinsmuxSubmissionRunRecord -ProjectDir $script:task780TempRoot -SlotId worker-1 -Record $stale | Out-Null
        $script:staleRunSendCalled = $false
        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content 'new request' -SubmissionId 'submission-stale-run' `
            -SendAction { $script:staleRunSendCalled = $true }

        $receipt.status | Should -Be 'rejected'
        $receipt.reason_code | Should -Be 'run_record_already_exists'
        $script:staleRunSendCalled | Should -Be $false
    }

    It 'P1 requires a durable api_llm started record before accepting a long execution' {
        $evidence = New-WinsmuxSubmissionRunRecord -SubmissionId 'submission-review-api-start' -RunId 'submission-review-api-start' -Kind task -TaskTitle 'API start test' -SlotId worker-1 -Backend api_llm -Status started -RequestConsumed -RequestDigest ('e' * 64)

        $evidence.protocol_version | Should -Be 1
        $evidence.status | Should -Be 'started'
        $evidence.task_id | Should -Be 'submission-review-api-start'
        $evidence.task_title | Should -Be 'API start test'
        $evidence.worker_kind | Should -Be 'implementation'
        $evidence.slot_id | Should -Be 'worker-1'
        $evidence.backend_owned | Should -Be $true
        $evidence.request_consumed | Should -Be $true
    }

    It 'P1 returns stable and internally consistent router reason codes' {
        $noTargetRoute = Get-DispatchRoute -Text 'implement the bounded change' -AvailableTargets @()
        $noTarget = New-WinsmuxRouterRefusalReceipt -Kind task -Route $noTargetRoute -SubmissionId 'submission-review-router-1'
        $operatorRoute = Get-DispatchRoute -Text 'commit the release' -AvailableTargets @('builder-1')
        $operator = New-WinsmuxRouterRefusalReceipt -Kind task -Route $operatorRoute -SubmissionId 'submission-review-router-2'

        $noTarget.reason_code | Should -Be 'router_target_unavailable'
        $noTarget.routing.expected_owner | Should -Be 'Builder'
        $noTarget.routing.rule_id | Should -Be 'route.no_available_target.v1'
        $operator.reason_code | Should -Be 'router_operator_owned'
        $operator.routing.expected_owner | Should -Be 'Operator'
        $operator.routing.rule_id | Should -Be 'route.operator_owned.v1'
    }

    It 'P2 sends api_llm REPL packets through task-json parsing rather than script parsing' {
        $content = Get-Content -LiteralPath $script:task780ApiWorkerPath -Raw -Encoding UTF8

        $content | Should -Match '@\(''workers'', ''exec'', \$slotId, ''--task-json'', \$packetPath'
        $content | Should -Not -Match '@\(''workers'', ''exec'', \$slotId, ''--script'', \$scriptPath'
        $content | Should -Match 'usage: exec <task-packet-path>'
        $content | Should -Not -Match 'exec <task-packet-path> \[task-id\]'
    }

    It 'P2 routes a real api_llm REPL packet through workers exec and preserves review kind' {
        @'
agent: codex
model: provider-default
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: api_llm
    worker-role: reviewer
    agent: openrouter
    model: synthetic/model
    model-source: operator-override
    prompt-transport: file
    auth-mode: api-key-env
    worktree-mode: managed
'@ | Set-Content -LiteralPath (Join-Path $script:task780TempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:task780TempRoot '.winsmux') -Force | Out-Null
@'
{
  "version": 1,
  "providers": {
    "openrouter": {
      "adapter": "openai-compatible",
      "command": "openrouter",
      "prompt_transports": ["file"],
      "auth_modes": ["api-key-env"],
      "model_sources": ["provider-default", "operator-override"],
      "execution_backend": "openai-compatible-chat-completions",
      "api_base_url": "https://openrouter.ai/api/v1",
      "api_key_env": "TASK780_SYNTHETIC_MISSING_KEY",
      "supports_structured_result": true
    }
  }
}
'@ | Set-Content -LiteralPath (Join-Path $script:task780TempRoot '.winsmux\provider-capabilities.json') -Encoding UTF8
        $submissionId = 'submission-real-api-repl'
        $packetRef = New-WinsmuxSubmissionPacket -ProjectDir $script:task780TempRoot -Kind review -Content ([ordered]@{ title = 'Synthetic API review'; request = 'Review synthetic input.' }) -SubmissionId $submissionId -TargetLabel 'worker-1'
        $relativePacket = $packetRef.RelativePath
        $inputLines = "exec $relativePacket`nquit`n"
        $output = $inputLines | & pwsh -NoProfile -File $script:task780ApiWorkerPath -SlotId worker-1 -Provider openrouter -Model synthetic/model -ProjectDir $script:task780TempRoot 2>&1
        $runPath = Join-Path $script:task780TempRoot ".winsmux\worker-runs\worker-1\$submissionId\run.json"
        (Test-Path -LiteralPath $runPath -PathType Leaf) | Should -Be $true -Because ($output | Out-String)
        $run = Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $outputText = $output | Out-String
        $outputText | Should -Not -Match 'unknown command'
        $run.protocol_version | Should -Be 1
        $run.submission_id | Should -Be $submissionId
        $run.kind | Should -Be 'review'
        $run.request_consumed | Should -Be $true
        $run.reason | Should -BeIn @('api_llm_api_key_env_missing', 'api_llm_runtime_config_invalid')
    }

    It 'P2 has no production environment-variable bypass around the shared bridge contract' {
        $content = Get-Content -LiteralPath $script:task780RustMainPath -Raw -Encoding UTF8

        $content | Should -Not -Match 'WINSMUX_DISABLE_CORE_BRIDGE'
        $content | Should -Match 'dispatch-review'
        $content | Should -Match 'dispatch-task'
    }

    It 'P2 returns a typed nonzero review refusal before manifest lookup can escape' {
        $previousRole = $env:WINSMUX_ROLE
        $previousPane = $env:WINSMUX_PANE_ID
        $previousRoleMap = $env:WINSMUX_ROLE_MAP
        try {
            $env:WINSMUX_ROLE = 'Operator'
            $env:WINSMUX_PANE_ID = '%1'
            $env:WINSMUX_ROLE_MAP = '{"%1":"Operator"}'
            Push-Location $script:task780TempRoot
            $output = & pwsh -NoProfile -File $script:task780CorePath dispatch-review 2>&1
            $exitCode = $LASTEXITCODE
            Pop-Location

            $receipt = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)[0] | ConvertFrom-Json
            $exitCode | Should -Be 1
            $receipt.protocol_version | Should -Be 1
            $receipt.kind | Should -Be 'review'
            $receipt.status | Should -Be 'unavailable'
            $receipt.reason_code | Should -Be 'review_target_unavailable'
        } finally {
            if ((Get-Location).Path -eq $script:task780TempRoot) { Pop-Location }
            $env:WINSMUX_ROLE = $previousRole
            $env:WINSMUX_PANE_ID = $previousPane
            $env:WINSMUX_ROLE_MAP = $previousRoleMap
        }
    }

    It 'P2 redacts arbitrary Windows UNC and Unix absolute paths from diagnostics' {
        $diagnostic = ConvertTo-WinsmuxSubmissionDiagnostic -Text 'C:\Users\Jane Doe\repo\secret.txt D:\workspace\secret\file.txt C:\tmp\private.json \\server\share\private.md /home/alice/private.txt /srv/private/file /mnt/c/private/file /root/private/file https://example.test/srv/public'

        $diagnostic | Should -Not -Match 'D:\\workspace'
        $diagnostic | Should -Not -Match 'C:\\tmp'
        $diagnostic | Should -Not -Match '\\\\server\\share'
        $diagnostic | Should -Not -Match '/home/alice'
        $diagnostic | Should -Not -Match '/srv/private'
        $diagnostic | Should -Not -Match '/mnt/c/private'
        $diagnostic | Should -Not -Match '/root/private'
        $diagnostic | Should -Not -Match 'Jane Doe|Doe\\repo'
        $diagnostic | Should -Match 'https://example\.test/srv/public'
    }

    It 'ROUND2 P1 keeps builder queue queued after raw send success and advances only for a validated receipt' {
        $queuedEntry = ConvertTo-BuilderQueueEntry -BuilderLabel builder-1 -Task 'Implement typed queue dispatch' -TaskId task-round2-queue
        $script:round2Manifest = [PSCustomObject]@{
            tasks = [PSCustomObject]@{ queued = @($queuedEntry); in_progress = @(); completed = @() }
            panes = [PSCustomObject]@{}
        }
        Mock Get-BuilderQueueManifest { $script:round2Manifest }
        $script:round2SavedManifest = $null
        Mock Save-BuilderQueueManifest { param($ProjectDir, $Manifest) $script:round2SavedManifest = $Manifest }
        Mock Get-BuilderQueueTaskFiles { @() }
        Mock Lock-DispatchFiles { $true }
        Mock Unlock-DispatchFiles { $true }
        Mock Update-BuilderQueuePaneState {}

        $rawOutcome = Dispatch-NextBuilderQueueTask -ProjectDir $script:task780TempRoot -BuilderLabel builder-1 -DispatchAction {
            [PSCustomObject]@{ Output = 'raw bridge send succeeded' }
        }
        $rawOutcome.Dispatched | Should -Be $false
        $rawOutcome.Reason | Should -Be 'runner_evidence_invalid'
        @($script:round2Manifest.tasks.queued).Count | Should -Be 1
        @($script:round2Manifest.tasks.in_progress).Count | Should -Be 0
        Assert-MockCalled Save-BuilderQueueManifest -Times 0 -Exactly

        foreach ($mutation in @(
            [ordered]@{ name = 'backend_owned'; value = $false },
            [ordered]@{ name = 'request_consumed'; value = $false },
            [ordered]@{ name = 'task_id'; value = 'other-task' },
            [ordered]@{ name = 'exit_code'; value = 1 },
            [ordered]@{ name = 'request_digest'; value = ('0' * 64) }
        )) {
            $invalidOutcome = Dispatch-NextBuilderQueueTask -ProjectDir $script:task780TempRoot -BuilderLabel builder-1 -DispatchAction {
                param($builderLabel, $task, $prompt, $stableTaskId, $attemptId)
                $packet = New-WinsmuxSubmissionPacket -ProjectDir $script:task780TempRoot -Kind task -Content $prompt -SubmissionId $attemptId -TaskId $stableTaskId -TargetLabel $builderLabel
                $invalidEvidence = New-WinsmuxSubmissionRunRecord -SubmissionId $attemptId -RunId $attemptId -TaskId $stableTaskId -Kind task -TaskTitle $task -SlotId $builderLabel -Backend api_llm -Status started -RequestConsumed -RequestDigest ([string]$packet.Packet.request_digest)
                $invalidEvidence[$mutation.name] = $mutation.value
                Write-WinsmuxSubmissionRunRecord -ProjectDir $script:task780TempRoot -SlotId $builderLabel -Record $invalidEvidence | Out-Null
                return New-WinsmuxSubmissionReceipt -Kind task -Status accepted -Backend api_llm -SubmissionId $attemptId -Target ([ordered]@{ label = $builderLabel }) -Acknowledgement $invalidEvidence
            }
            $invalidOutcome.Dispatched | Should -Be $false
            $invalidOutcome.Reason | Should -Be 'runner_evidence_invalid'
            Assert-MockCalled Save-BuilderQueueManifest -Times 0 -Exactly
        }

        $acceptedOutcome = Dispatch-NextBuilderQueueTask -ProjectDir $script:task780TempRoot -BuilderLabel builder-1 -DispatchAction {
            param($builderLabel, $task, $prompt, $stableTaskId, $attemptId)
            $packet = New-WinsmuxSubmissionPacket -ProjectDir $script:task780TempRoot -Kind task -Content $prompt -SubmissionId $attemptId -TaskId $stableTaskId -TargetLabel $builderLabel
            $evidence = New-WinsmuxSubmissionRunRecord -SubmissionId $attemptId -RunId $attemptId -TaskId $stableTaskId -Kind task -TaskTitle $task -SlotId $builderLabel -Backend api_llm -Status started -RequestConsumed -RequestDigest ([string]$packet.Packet.request_digest)
            Write-WinsmuxSubmissionRunRecord -ProjectDir $script:task780TempRoot -SlotId $builderLabel -Record $evidence | Out-Null
            return New-WinsmuxSubmissionReceipt -Kind task -Status accepted -Backend api_llm -SubmissionId $attemptId -Target ([ordered]@{ label = $builderLabel }) -Acknowledgement $evidence
        }
        $acceptedOutcome.Dispatched | Should -Be $true
        Assert-MockCalled Save-BuilderQueueManifest -Times 1 -Exactly -ParameterFilter {
            @($Manifest.tasks.queued).Count -eq 0 -and @($Manifest.tasks.in_progress).Count -eq 1
        }
    }

    It 'ROUND2 P1 projects accepted acknowledgement through a strict public allowlist' {
        $digest = ('a' * 64)
        $record = New-WinsmuxSubmissionRunRecord -SubmissionId submission-round2-public -RunId submission-round2-public -Kind task -TaskTitle 'SECRET REQUEST C:\private\task.txt' -SlotId worker-1 -Backend api_llm -Status started -RequestConsumed -RequestDigest $digest
        $record['request'] = 'SECRET BODY /srv/private/body.txt'
        $record['project_dir'] = 'D:\private\repo'
        $record['command'] = '\\server\share\private.cmd'
        $record['transcript'] = '/mnt/c/private/transcript.txt'
        $record['exception'] = '/root/private/error.txt'
        $record['provider_payload'] = '/home/private/provider.json'
        $receipt = New-WinsmuxSubmissionReceipt -Kind task -Status accepted -Backend api_llm -SubmissionId submission-round2-public -Target ([ordered]@{ label = 'worker-1' }) -Acknowledgement $record
        $json = ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt
        foreach ($secret in @('SECRET', 'task_title', 'project_dir', 'command', 'transcript', 'exception', 'provider_payload', 'C:\\', 'D:\\', '\\\\server', '/home', '/srv', '/mnt', '/root')) {
            $json | Should -Not -Match ([regex]::Escape($secret))
        }
        @($receipt.acknowledgement.Keys) | Should -Be @('type', 'protocol_version', 'status', 'submission_id', 'run_id', 'task_id', 'kind', 'backend', 'slot_id', 'worker_kind', 'request_digest')
    }

    It 'ROUND2 P2 refuses forged local or Codex pane identity until TASK-781 authority exists' {
        $previousPaneId = $env:WINSMUX_PANE_ID
        try {
            Mock Test-PaneControlRuntimeContext {
                New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'caller_identity_mismatch' -Diagnostic 'synthetic mutable pane identity is not authoritative'
            }
            $env:WINSMUX_PANE_ID = '%2'
            $entry = [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%2'; Role = 'Worker'; WorkerBackend = 'codex' }
            $script:round2LocalSendCalled = $false
            $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content 'Do not trust mutable pane identity.' -SubmissionId submission-round2-forged-local `
                -SendAction { $script:round2LocalSendCalled = $true } `
                -RunResultAction { throw 'must not request optimistic evidence' }
            $receipt.status | Should -Be 'unavailable'
            $receipt.reason_code | Should -Be 'caller_identity_mismatch'
            $script:round2LocalSendCalled | Should -Be $false
        } finally {
            $env:WINSMUX_PANE_ID = $previousPaneId
        }
    }

    It 'ROUND2 P2 rejects matching run identifiers with a different complete-request digest' {
        $entry = [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%2'; Role = 'Worker'; WorkerBackend = 'api_llm' }
        $content = 'Complete request identity must match exactly.'
        $wrong = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content $content -SubmissionId submission-round2-digest-wrong `
            -SendAction { 'sent' } `
            -RunResultAction {
                param($projectDir, $slotId, $runId)
                New-WinsmuxSubmissionRunRecord -SubmissionId $runId -RunId $runId -Kind task -TaskTitle 'same non-empty title' -SlotId $slotId -Backend api_llm -Status started -RequestConsumed -RequestDigest ('0' * 64)
            }
        $wrong.status | Should -Be 'rejected'

        $expectedDigest = Get-WinsmuxSubmissionRequestDigest -Request $content
        $exact = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content $content -SubmissionId submission-round2-digest-exact `
            -SendAction { 'sent' } `
            -RunResultAction {
                param($projectDir, $slotId, $runId)
                New-WinsmuxSubmissionRunRecord -SubmissionId $runId -RunId $runId -Kind task -TaskTitle 'different title is not authority' -SlotId $slotId -Backend api_llm -Status started -RequestConsumed -RequestDigest $expectedDigest
            }
        $exact.status | Should -Be 'accepted'
    }

    It 'ROUND2 P1 returns a process-level typed queue refusal with nonzero exit and retained state' {
        $manifest = New-WinsmuxManifest -ProjectDir $script:task780TempRoot
        $manifest.panes['builder-1'] = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; worker_backend = 'codex' }
        $manifest.tasks.queued = @(ConvertTo-BuilderQueueEntry -BuilderLabel builder-1 -Task 'Keep queued without TASK-781 authority' -TaskId task-round2-cli)
        Save-WinsmuxManifest -ProjectDir $script:task780TempRoot -Manifest $manifest

        $output = & pwsh -NoProfile -File $script:task780BuilderQueuePath -Action dispatch-next -ProjectDir $script:task780TempRoot -BuilderLabel builder-1 -AsJson 2>&1
        $exitCode = $LASTEXITCODE
        $payload = ($output | Out-String) | ConvertFrom-Json
        $saved = Get-WinsmuxManifest -ProjectDir $script:task780TempRoot

        $exitCode | Should -Be 1
        $payload.Dispatched | Should -Be $false
        $payload.DispatchResult.status | Should -Be 'unavailable'
        $payload.DispatchResult.reason_code | Should -Be 'manifest_regeneration_required'
        @($saved.tasks.queued).Count | Should -Be 1
        @($saved.tasks.in_progress).Count | Should -Be 0
        @(Get-DispatchLedger -ProjectDir $script:task780TempRoot).Count | Should -Be 0
    }

    It 'ROUND3 P1 retries a queued task with a fresh real submission attempt while preserving task identity' {
        $queueTaskId = 'task-round3-retry'
        $manifest = New-WinsmuxManifest -ProjectDir $script:task780TempRoot
        $manifest.panes['builder-1'] = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; worker_backend = 'antigravity' }
        $manifest.tasks.queued = @(ConvertTo-BuilderQueueEntry -BuilderLabel builder-1 -Task 'Retry typed queue dispatch' -TaskId $queueTaskId)
        Save-WinsmuxManifest -ProjectDir $script:task780TempRoot -Manifest $manifest

        $script:round3AttemptIds = [System.Collections.Generic.List[string]]::new()
        $script:round3DispatchCount = 0
        $dispatchAction = {
            param($builderLabel, $task, $prompt, $stableTaskId, $attemptId)
            $script:round3DispatchCount++
            if ([string]::IsNullOrWhiteSpace([string]$stableTaskId)) { $stableTaskId = $queueTaskId }
            if ([string]::IsNullOrWhiteSpace([string]$attemptId)) { $attemptId = $stableTaskId }
            $script:round3AttemptIds.Add([string]$attemptId) | Out-Null
            $entry = [PSCustomObject]@{ Label = $builderLabel; PaneId = ''; Role = 'Builder'; WorkerBackend = 'antigravity' }
            $cliAction = {
                param($projectDir, $slotId, $packetPath, $submissionId, $backend, $kind)
                $packet = Read-WinsmuxSubmissionPacket -Path (Join-Path $projectDir $packetPath)
                $accepted = $script:round3DispatchCount -gt 1
                $record = [ordered]@{
                    protocol_version = 1; type = 'backend_run_record'; submission_id = $submissionId; run_id = $submissionId
                    kind = $kind; task_id = [string]$packet.task_id; task_title = [string]$packet.title; worker_kind = 'implementation'
                    slot_id = $slotId; backend = $backend; status = if ($accepted) { 'started' } else { 'failed' }
                    backend_owned = $true; request_consumed = $true; request_digest = [string]$packet.request_digest
                    reason = if ($accepted) { '' } else { 'runner_rejected_packet' }; exit_code = if ($accepted) { 0 } else { 1 }
                    generated_at = (Get-Date).ToUniversalTime().ToString('o')
                }
                Write-WinsmuxSubmissionRunRecord -ProjectDir $projectDir -SlotId $slotId -Record $record | Out-Null
                return Get-Content -LiteralPath (Get-WinsmuxSubmissionRunPath -ProjectDir $projectDir -SlotId $slotId -RunId $submissionId) -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16
            }
            $adapterParameters = @{
                ProjectDir = $script:task780TempRoot; ManifestEntry = $entry; Kind = 'task'; Content = $prompt
                SubmissionId = $attemptId; CliRunAction = $cliAction
            }
            if ((Get-Command Invoke-WinsmuxSubmissionAdapter).Parameters.ContainsKey('TaskId')) {
                $adapterParameters['TaskId'] = $stableTaskId
            }
            return Invoke-WinsmuxSubmissionAdapter @adapterParameters
        }

        $first = Dispatch-NextBuilderQueueTask -ProjectDir $script:task780TempRoot -BuilderLabel builder-1 -DispatchAction $dispatchAction
        $afterFirst = Get-WinsmuxManifest -ProjectDir $script:task780TempRoot
        $first.Dispatched | Should -Be $false
        $first.DispatchResult.status | Should -Be 'rejected'
        $first.DispatchResult.reason_code | Should -Be 'runner_rejected_packet'
        @($afterFirst.tasks.queued).Count | Should -Be 1
        @($afterFirst.tasks.in_progress).Count | Should -Be 0

        $second = Dispatch-NextBuilderQueueTask -ProjectDir $script:task780TempRoot -BuilderLabel builder-1 -DispatchAction $dispatchAction
        $afterSecond = Get-WinsmuxManifest -ProjectDir $script:task780TempRoot
        $second.Dispatched | Should -Be $true
        $second.DispatchResult.status | Should -Be 'accepted'
        $script:round3AttemptIds.Count | Should -Be 2
        $script:round3AttemptIds[0] | Should -Not -Be $script:round3AttemptIds[1]
        $second.DispatchResult.submission_id | Should -Be $script:round3AttemptIds[1]
        $second.DispatchResult.acknowledgement.task_id | Should -Be $queueTaskId
        @($afterSecond.tasks.queued).Count | Should -Be 0
        @($afterSecond.tasks.in_progress).Count | Should -Be 1

        foreach ($attemptId in @($script:round3AttemptIds)) {
            $packet = Read-WinsmuxSubmissionPacket -Path (Join-Path $script:task780TempRoot ".winsmux\submissions\$attemptId.json")
            $run = Get-Content -LiteralPath (Get-WinsmuxSubmissionRunPath -ProjectDir $script:task780TempRoot -SlotId builder-1 -RunId $attemptId) -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16
            $packet.submission_id | Should -Be $attemptId
            $packet.run_id | Should -Be $attemptId
            $packet.task_id | Should -Be $queueTaskId
            $run.submission_id | Should -Be $attemptId
            $run.run_id | Should -Be $attemptId
            $run.task_id | Should -Be $queueTaskId
        }

        $duplicateEntry = [PSCustomObject]@{ Label = 'builder-1'; PaneId = ''; Role = 'Builder'; WorkerBackend = 'antigravity' }
        $duplicate = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $duplicateEntry -Kind task -Content 'Retry typed queue dispatch' `
            -SubmissionId $script:round3AttemptIds[1] -TaskId $queueTaskId -CliRunAction { throw 'duplicate attempt must stop before runner invocation' }
        $duplicate.status | Should -Be 'rejected'
        $duplicate.reason_code | Should -Be 'run_record_already_exists'
        (ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $second.DispatchResult) | Should -Not -Match 'Retry typed queue dispatch'
    }

    It 'ROUND3 P1 maps real runner reasons to stable public codes without leaking untrusted text' {
        $entry = [PSCustomObject]@{ Label = 'worker-3'; PaneId = ''; Role = 'Worker'; WorkerBackend = 'antigravity' }
        $knownCases = @(
            [ordered]@{ status = 'unavailable'; reason = 'cli_command_missing'; expected = 'cli_command_missing' },
            [ordered]@{ status = 'failed'; reason = 'runner_rejected_packet'; expected = 'runner_rejected_packet' }
        )
        $caseIndex = 0
        foreach ($case in $knownCases) {
            $caseIndex++
            $submissionId = "submission-round3-known-$caseIndex"
            $cliAction = {
                param($projectDir, $slotId, $packetPath, $runId, $backend, $kind)
                $record = [ordered]@{ status = $case.status; reason = $case.reason; exit_code = 1; run_id = $runId }
                Write-WinsmuxSubmissionRunRecord -ProjectDir $projectDir -SlotId $slotId -Record $record | Out-Null
                return Get-Content -LiteralPath (Get-WinsmuxSubmissionRunPath -ProjectDir $projectDir -SlotId $slotId -RunId $runId) -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16
            }
            $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content 'Known reason mapping' -SubmissionId $submissionId -CliRunAction $cliAction
            $receipt.reason_code | Should -Be $case.expected
            $receipt.reason_code | Should -Match '^[a-z][a-z0-9_]*$'
        }

        $unsafeReasons = @(
            'key=sk-synthetic-leak-value',
            'C:\Users\LeakSubject\private.txt',
            '\\secret-host\private-share\payload.json',
            '/home/leaksubject/private.txt',
            '{"provider":"private-payload"}',
            "provider failure`nprivate second line",
            ('control' + [char]1 + 'private')
        )
        $unsafeIndex = 0
        foreach ($unsafeReason in $unsafeReasons) {
            $unsafeIndex++
            $submissionId = "submission-round3-unsafe-$unsafeIndex"
            $cliAction = {
                param($projectDir, $slotId, $packetPath, $runId, $backend, $kind)
                $record = [ordered]@{ status = 'failed'; reason = $unsafeReason; exit_code = 1; run_id = $runId }
                Write-WinsmuxSubmissionRunRecord -ProjectDir $projectDir -SlotId $slotId -Record $record | Out-Null
                return Get-Content -LiteralPath (Get-WinsmuxSubmissionRunPath -ProjectDir $projectDir -SlotId $slotId -RunId $runId) -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16
            }
            $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content 'Unsafe reason mapping' -SubmissionId $submissionId -CliRunAction $cliAction
            $json = ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt
            $receipt.status | Should -Be 'rejected'
            $receipt.reason_code | Should -Be 'runner_evidence_invalid'
            $receipt.reason_code | Should -Match '^[a-z][a-z0-9_]*$'
            $receipt.reason_code | Should -Not -Match '[\s/\\{}=:]'
            $receipt.diagnostic | Should -Be ''
            $receipt.acknowledgement | Should -BeNullOrEmpty
            foreach ($privateMarker in @('sk-synthetic-leak-value', 'LeakSubject', 'secret-host', 'leaksubject', 'private-payload', 'private second line', 'control')) {
                $json | Should -Not -Match ([regex]::Escape($privateMarker))
            }
        }

        $acceptedId = 'submission-round3-public-ack'
        $acceptedAction = {
            param($projectDir, $slotId, $packetPath, $runId, $backend, $kind)
            $packet = Read-WinsmuxSubmissionPacket -Path (Join-Path $projectDir $packetPath)
            $record = New-WinsmuxSubmissionRunRecord -SubmissionId $runId -RunId $runId -TaskId ([string]$packet.task_id) -Kind $kind -TaskTitle 'Public acknowledgement' -SlotId $slotId -Backend $backend -Status started -RequestConsumed -RequestDigest ([string]$packet.request_digest)
            Write-WinsmuxSubmissionRunRecord -ProjectDir $projectDir -SlotId $slotId -Record $record | Out-Null
            return Get-Content -LiteralPath (Get-WinsmuxSubmissionRunPath -ProjectDir $projectDir -SlotId $slotId -RunId $runId) -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16
        }
        $accepted = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content 'Public acknowledgement allowlist' -SubmissionId $acceptedId -TaskId task-round3-public -CliRunAction $acceptedAction
        $accepted.status | Should -Be 'accepted'
        @($accepted.acknowledgement.Keys) | Should -Be @('type', 'protocol_version', 'status', 'submission_id', 'run_id', 'task_id', 'kind', 'backend', 'slot_id', 'worker_kind', 'request_digest')
        @($accepted.Keys) | Should -Be @('protocol_version', 'submission_id', 'kind', 'status', 'backend', 'reason_code', 'diagnostic', 'target', 'routing', 'acknowledgement')
    }

    It 'ROUND3 P1 forwards stable task and attempt identities through the default CLI adapter path' {
        $taskId = 'task-round3-default-cli'
        $attemptId = 'attempt-round3-default-cli-1'
        $entry = [PSCustomObject]@{ Label = 'worker-3'; PaneId = ''; Role = 'Worker'; WorkerBackend = 'antigravity' }
        $script:round3BridgeArguments = @()

        function global:pwsh {
            $script:round3BridgeArguments = @($args)
            $taskIdIndex = [array]::IndexOf([object[]]$script:round3BridgeArguments, '--task-id')
            $runIdIndex = [array]::IndexOf([object[]]$script:round3BridgeArguments, '--run-id')
            $packetIndex = [array]::IndexOf([object[]]$script:round3BridgeArguments, '--task-json')
            $projectIndex = [array]::IndexOf([object[]]$script:round3BridgeArguments, '--project-dir')
            $workersIndex = [array]::IndexOf([object[]]$script:round3BridgeArguments, 'workers')
            $packet = Read-WinsmuxSubmissionPacket -Path (Join-Path $script:round3BridgeArguments[$projectIndex + 1] $script:round3BridgeArguments[$packetIndex + 1])
            $record = New-WinsmuxSubmissionRunRecord -SubmissionId $script:round3BridgeArguments[$runIdIndex + 1] -RunId $script:round3BridgeArguments[$runIdIndex + 1] `
                -TaskId $script:round3BridgeArguments[$taskIdIndex + 1] -Kind task -TaskTitle ([string]$packet.title) -SlotId $script:round3BridgeArguments[$workersIndex + 2] `
                -Backend antigravity -Status started -RequestConsumed -RequestDigest ([string]$packet.request_digest)
            return ($record | ConvertTo-Json -Compress -Depth 12)
        }

        try {
            $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content 'Default CLI identity forwarding' -SubmissionId $attemptId -TaskId $taskId
        } finally {
            Remove-Item function:\pwsh -ErrorAction SilentlyContinue
        }

        $taskIdIndex = [array]::IndexOf([object[]]$script:round3BridgeArguments, '--task-id')
        $runIdIndex = [array]::IndexOf([object[]]$script:round3BridgeArguments, '--run-id')
        $taskIdIndex | Should -BeGreaterOrEqual 0
        $script:round3BridgeArguments[$taskIdIndex + 1] | Should -Be $taskId
        $runIdIndex | Should -BeGreaterOrEqual 0
        $script:round3BridgeArguments[$runIdIndex + 1] | Should -Be $attemptId
        $receipt.status | Should -Be 'accepted'
        $receipt.submission_id | Should -Be $attemptId
        $receipt.acknowledgement.task_id | Should -Be $taskId
    }

    It 'ROUND3 P1 rejects duplicate attempts before rewriting the original submission packet' {
        $taskId = 'task-round3-immutable-packet'
        $attemptId = 'attempt-round3-immutable-packet-1'
        $entry = [PSCustomObject]@{ Label = 'worker-3'; PaneId = ''; Role = 'Worker'; WorkerBackend = 'antigravity' }
        $firstContent = [ordered]@{ title = 'Original packet'; request = 'Keep this original request.' }
        $firstAction = {
            param($projectDir, $slotId, $packetPath, $runId, $backend, $kind)
            $packet = Read-WinsmuxSubmissionPacket -Path (Join-Path $projectDir $packetPath)
            $record = New-WinsmuxSubmissionRunRecord -SubmissionId $runId -RunId $runId -TaskId ([string]$packet.task_id) -Kind $kind -TaskTitle ([string]$packet.title) `
                -SlotId $slotId -Backend $backend -Status failed -RequestConsumed -RequestDigest ([string]$packet.request_digest) -Reason 'runner_rejected_packet'
            Write-WinsmuxSubmissionRunRecord -ProjectDir $projectDir -SlotId $slotId -Record $record | Out-Null
            return $record
        }

        $first = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content $firstContent -SubmissionId $attemptId -TaskId $taskId -CliRunAction $firstAction
        $packetPath = Join-Path $script:task780TempRoot ".winsmux\submissions\$attemptId.json"
        $originalPacketText = Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8
        $originalPacket = $originalPacketText | ConvertFrom-Json

        $duplicate = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content ([ordered]@{ title = 'Replacement packet'; request = 'This must not overwrite the original.' }) `
            -SubmissionId $attemptId -TaskId $taskId -CliRunAction { throw 'duplicate attempt must stop before runner invocation' }
        $packetAfterDuplicateText = Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8
        $packetAfterDuplicate = $packetAfterDuplicateText | ConvertFrom-Json

        $first.reason_code | Should -Be 'runner_rejected_packet'
        $duplicate.status | Should -Be 'rejected'
        $duplicate.reason_code | Should -Be 'run_record_already_exists'
        $packetAfterDuplicateText | Should -BeExactly $originalPacketText
        $packetAfterDuplicate.request | Should -BeExactly $originalPacket.request
        $packetAfterDuplicate.request_digest | Should -BeExactly $originalPacket.request_digest
    }

    It 'ROUND3 P2 rejects a packet-only retry without overwriting the original request' {
        $taskId = 'task-round3-packet-only-retry'
        $attemptId = 'attempt-round3-packet-only-retry-1'
        $entry = [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%1'; Role = 'Worker'; WorkerBackend = 'api_llm' }
        $firstContent = [ordered]@{ title = 'Original packet'; request = 'Keep this request after send failure.' }
        $script:task780PacketRetrySendCount = 0

        $first = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content $firstContent `
            -SubmissionId $attemptId -TaskId $taskId `
            -SendAction { $script:task780PacketRetrySendCount++; throw 'synthetic packet send failure' } `
            -RunResultAction { throw 'send failure must stop before runner polling' }
        $packetPath = Join-Path $script:task780TempRoot ".winsmux\submissions\$attemptId.json"
        $runPath = Get-WinsmuxSubmissionRunPath -ProjectDir $script:task780TempRoot -SlotId worker-1 -RunId $attemptId
        $originalPacketText = Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8
        $originalPacket = $originalPacketText | ConvertFrom-Json

        $duplicate = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task `
            -Content ([ordered]@{ title = 'Replacement packet'; request = 'This request must not replace the original.' }) `
            -SubmissionId $attemptId -TaskId $taskId `
            -SendAction { $script:task780PacketRetrySendCount++; throw 'duplicate retry must stop before sending' } `
            -RunResultAction { throw 'duplicate retry must stop before runner polling' }
        $packetAfterRetryText = Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8
        $packetAfterRetry = $packetAfterRetryText | ConvertFrom-Json

        $first.status | Should -Be 'unavailable'
        $first.reason_code | Should -Be 'packet_repl_unavailable'
        $duplicate.status | Should -Be 'rejected'
        $duplicate.reason_code | Should -Be 'run_record_already_exists'
        (Test-WinsmuxSubmissionReceipt -Receipt $duplicate) | Should -Be $true
        { ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $duplicate | Out-Null } | Should -Not -Throw
        $script:task780PacketRetrySendCount | Should -Be 1
        (Test-Path -LiteralPath $runPath -PathType Leaf) | Should -Be $false
        $packetAfterRetryText | Should -BeExactly $originalPacketText
        $packetAfterRetry.request | Should -BeExactly $originalPacket.request
        $packetAfterRetry.request_digest | Should -BeExactly $originalPacket.request_digest
    }

    It 'TASK781 preserves a local packet when delivery commits before post-Enter failure' {
        $taskId = 'task-task781-local-committed-packet'
        $attemptId = 'attempt-task781-local-committed-packet-1'
        $entry = [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%2'; Role = 'Worker'; WorkerBackend = 'codex' }
        Mock Test-PaneControlRuntimeContext {
            [PSCustomObject]@{
                valid = $true
                reason_code = 'dispatch_runtime_verified'
                diagnostic = ''
                context = [PSCustomObject]@{ generation_id = 'generation-task781' }
            }
        }
        Mock Send-TextToPane {
            $DeliveryState['SubmissionCommitted'] = $true
            throw 'synthetic post-Enter watermark failure'
        }

        $first = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task `
            -Content 'Preserve the exact committed packet.' -SubmissionId $attemptId -TaskId $taskId
        $packetPath = Join-Path $script:task780TempRoot ".winsmux\submissions\$attemptId.json"
        $originalPacketText = Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8

        $duplicate = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task `
            -Content 'Do not replace the committed packet.' -SubmissionId $attemptId -TaskId $taskId `
            -SendAction { throw 'duplicate must stop before delivery' }

        $first.status | Should -Be 'unavailable'
        $first.reason_code | Should -Be 'packet_repl_unavailable'
        $duplicate.status | Should -Be 'rejected'
        $duplicate.reason_code | Should -Be 'run_record_already_exists'
        (Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8) | Should -BeExactly $originalPacketText
        Should -Invoke Send-TextToPane -Times 1 -Exactly -ParameterFilter {
            $null -ne $DeliveryState -and [bool]$DeliveryState['SubmissionCommitted']
        }
    }

    It 'TASK781 C19 refuses stale runtime before creating a submission packet' {
        $attemptId = 'attempt-task781-prepublication-refusal-1'
        $entry = [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%2'; Role = 'Worker'; WorkerBackend = 'api_llm' }
        $script:task781PrepublicationChecks = 0
        Mock Test-PaneControlRuntimeContext {
            $script:task781PrepublicationChecks++
            if ($script:task781PrepublicationChecks -eq 1) {
                return [PSCustomObject]@{
                    valid = $true
                    reason_code = 'dispatch_runtime_verified'
                    diagnostic = ''
                    context = [PSCustomObject]@{ generation_id = 'generation-before-publication' }
                }
            }
            return New-WinsmuxRuntimeValidationResult -Valid $false `
                -ReasonCode 'invalid_supervisor_identity' -Diagnostic 'synthetic lease expired before packet publication'
        }
        Mock New-WinsmuxSubmissionPacket { throw 'packet creation must not be reached' }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task `
            -Content 'Never persist this request after lease expiry.' -SubmissionId $attemptId -TaskId 'task-task781-prepublication-refusal' `
            -SendAction { throw 'send must not be reached' } -RunResultAction { throw 'run polling must not be reached' }

        $receipt.status | Should -Be 'unavailable'
        $receipt.reason_code | Should -Be 'invalid_supervisor_identity'
        $script:task781PrepublicationChecks | Should -Be 2
        Should -Invoke New-WinsmuxSubmissionPacket -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $script:task780TempRoot ".winsmux\submissions\$attemptId.json") | Should -BeFalse
    }

    It 'TASK781 C19 refuses a missing captured generation before creating a submission packet' {
        $attemptId = 'attempt-task781-missing-generation-refusal-1'
        $entry = [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%2'; Role = 'Worker'; WorkerBackend = 'api_llm' }
        $script:task781MissingGenerationChecks = 0
        Mock Test-PaneControlRuntimeContext {
            $script:task781MissingGenerationChecks++
            $generationId = if ($script:task781MissingGenerationChecks -eq 1) { '' } else { 'generation-fresh' }
            return [PSCustomObject]@{
                valid = $true
                reason_code = 'dispatch_runtime_verified'
                diagnostic = ''
                context = [PSCustomObject]@{ generation_id = $generationId }
            }
        }
        Mock New-WinsmuxSubmissionPacket { throw 'packet creation must not be reached' }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task `
            -Content 'Never persist this request without an exact generation.' -SubmissionId $attemptId `
            -TaskId 'task-task781-missing-generation-refusal' -SendAction { throw 'send must not be reached' } `
            -RunResultAction { throw 'run polling must not be reached' }

        $receipt.status | Should -Be 'unavailable'
        $receipt.reason_code | Should -Be 'manifest_regeneration_required'
        $script:task781MissingGenerationChecks | Should -Be 2
        Should -Invoke New-WinsmuxSubmissionPacket -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $script:task780TempRoot ".winsmux\submissions\$attemptId.json") | Should -BeFalse
    }

    It 'TASK781 C19 refuses a missing fresh generation before creating a submission packet' {
        $attemptId = 'attempt-task781-missing-fresh-generation-refusal-1'
        $entry = [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%2'; Role = 'Worker'; WorkerBackend = 'api_llm' }
        $script:task781MissingFreshGenerationChecks = 0
        Mock Test-PaneControlRuntimeContext {
            $script:task781MissingFreshGenerationChecks++
            $generationId = if ($script:task781MissingFreshGenerationChecks -eq 1) { 'generation-captured' } else { '' }
            return [PSCustomObject]@{
                valid = $true
                reason_code = 'dispatch_runtime_verified'
                diagnostic = ''
                context = [PSCustomObject]@{ generation_id = $generationId }
            }
        }
        Mock New-WinsmuxSubmissionPacket { throw 'packet creation must not be reached' }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task `
            -Content 'Never persist this request without a fresh generation.' -SubmissionId $attemptId `
            -TaskId 'task-task781-missing-fresh-generation-refusal' -SendAction { throw 'send must not be reached' } `
            -RunResultAction { throw 'run polling must not be reached' }

        $receipt.status | Should -Be 'unavailable'
        $receipt.reason_code | Should -Be 'manifest_regeneration_required'
        $script:task781MissingFreshGenerationChecks | Should -Be 2
        Should -Invoke New-WinsmuxSubmissionPacket -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $script:task780TempRoot ".winsmux\submissions\$attemptId.json") | Should -BeFalse
    }

    It 'TASK781 C19 uses ordinal generation identity before creating a submission packet' {
        $attemptId = 'attempt-task781-ordinal-generation-refusal-1'
        $entry = [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%2'; Role = 'Worker'; WorkerBackend = 'api_llm' }
        $script:task781OrdinalGenerationChecks = 0
        Mock Test-PaneControlRuntimeContext {
            $script:task781OrdinalGenerationChecks++
            $generationId = if ($script:task781OrdinalGenerationChecks -eq 1) {
                "generation-$([char]0x00E9)"
            } else {
                "generation-e$([char]0x0301)"
            }
            return [PSCustomObject]@{
                valid = $true
                reason_code = 'dispatch_runtime_verified'
                diagnostic = ''
                context = [PSCustomObject]@{ generation_id = $generationId }
            }
        }
        Mock New-WinsmuxSubmissionPacket { throw 'packet creation must not be reached' }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task `
            -Content 'Never persist this request for a non-ordinal generation match.' -SubmissionId $attemptId `
            -TaskId 'task-task781-ordinal-generation-refusal' -SendAction { throw 'send must not be reached' } `
            -RunResultAction { throw 'run polling must not be reached' }

        $receipt.status | Should -Be 'unavailable'
        $receipt.reason_code | Should -Be 'invalid_supervisor_identity'
        $script:task781OrdinalGenerationChecks | Should -Be 2
        Should -Invoke New-WinsmuxSubmissionPacket -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $script:task780TempRoot ".winsmux\submissions\$attemptId.json") | Should -BeFalse
    }

    It 'ROUND3 P2 converts an atomic packet-create collision to typed duplicate refusal' {
        $attemptId = 'attempt-round3-atomic-packet-race-1'
        $entry = [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%1'; Role = 'Worker'; WorkerBackend = 'api_llm' }
        $packetPath = (Resolve-WinsmuxSubmissionPacketPath -ProjectDir $script:task780TempRoot -SubmissionId $attemptId).FullPath
        New-Item -ItemType Directory -Path (Split-Path -Parent $packetPath) -Force | Out-Null
        $script:task780AtomicPacketPath = $packetPath
        $script:task780AtomicSendCalled = $false
        Mock New-WinsmuxSubmissionPacket {
            [System.IO.File]::WriteAllText($script:task780AtomicPacketPath, 'race winner packet', [System.Text.UTF8Encoding]::new($false))
            throw [System.IO.IOException]::new('synthetic CreateNew collision')
        }

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content 'Atomic retry loser' `
            -SubmissionId $attemptId -TaskId 'task-round3-atomic-packet-race' `
            -SendAction { $script:task780AtomicSendCalled = $true } `
            -RunResultAction { throw 'atomic collision must stop before runner polling' }

        $receipt.status | Should -Be 'rejected'
        $receipt.reason_code | Should -Be 'run_record_already_exists'
        (Test-WinsmuxSubmissionReceipt -Receipt $receipt) | Should -Be $true
        { ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt | Out-Null } | Should -Not -Throw
        $script:task780AtomicSendCalled | Should -Be $false
        (Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8) | Should -BeExactly 'race winner packet'
        Should -Invoke New-WinsmuxSubmissionPacket -Times 1 -Exactly
    }

    It 'ROUND3 P1 exposes only the finite unavailable and rejected reason allowlists' {
        $cases = @(
            [ordered]@{ backend = 'antigravity'; status = 'blocked'; reason = 'antigravity_cli_missing'; receipt_status = 'unavailable'; expected = 'antigravity_cli_missing' },
            [ordered]@{ backend = 'antigravity'; status = 'unavailable'; reason = 'cli_command_missing'; receipt_status = 'unavailable'; expected = 'cli_command_missing' },
            [ordered]@{ backend = 'antigravity'; status = 'unavailable'; reason = 'sk_synthetic_secret_cli_missing'; receipt_status = 'unavailable'; expected = 'backend_unavailable' },
            [ordered]@{ backend = 'antigravity'; status = 'blocked'; reason = 'private_provider_payload_cli_missing'; receipt_status = 'unavailable'; expected = 'backend_unavailable' },
            [ordered]@{ backend = 'antigravity'; status = 'failed'; reason = 'runner_rejected_packet'; receipt_status = 'rejected'; expected = 'runner_rejected_packet' },
            [ordered]@{ backend = 'antigravity'; status = 'failed'; reason = 'private_provider_payload'; receipt_status = 'rejected'; expected = 'runner_evidence_invalid' }
        )

        $index = 0
        foreach ($case in $cases) {
            $index++
            $entry = [PSCustomObject]@{ Label = 'worker-3'; PaneId = ''; Role = 'Worker'; WorkerBackend = $case.backend }
            $runnerAction = {
                param($projectDir, $slotId, $packetPath, $runId, $backend, $kind)
                return [ordered]@{ status = $case.status; reason = $case.reason; exit_code = 1; run_id = $runId }
            }
            $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content 'Finite reason mapping' `
                -SubmissionId "attempt-round3-reason-$index" -TaskId "task-round3-reason-$index" -CliRunAction $runnerAction
            $json = ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt

            $receipt.status | Should -Be $case.receipt_status
            $receipt.reason_code | Should -Be $case.expected
            $receipt.reason_code | Should -Match '^[a-z][a-z0-9_]*$'
            $json | Should -Not -Match 'sk_synthetic_secret_cli_missing|private_provider_payload'
        }
    }

    It 'ROUND3 P2 keeps backend and task-id refusal combinations typed and serializable' {
        $cases = @(
            [ordered]@{
                name             = 'known-backend-invalid-task'
                backend          = 'antigravity'
                task_id          = 'invalid task id'
                expected_status  = 'rejected'
                expected_backend = 'antigravity'
                expected_reason  = 'task_identifier_invalid'
            },
            [ordered]@{
                name             = 'unknown-backend-valid-task'
                backend          = 'unknown_backend'
                task_id          = 'valid-task-id'
                expected_status  = 'unsupported'
                expected_backend = 'noop'
                expected_reason  = 'backend_unsupported'
            },
            [ordered]@{
                name             = 'unknown-backend-invalid-task'
                backend          = 'unknown_backend'
                task_id          = 'invalid task id'
                expected_status  = 'unsupported'
                expected_backend = 'noop'
                expected_reason  = 'backend_unsupported'
            }
        )

        foreach ($case in $cases) {
            $entry = [PSCustomObject]@{ Label = 'worker-3'; PaneId = ''; Role = 'Worker'; WorkerBackend = $case.backend }
            $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task780TempRoot -ManifestEntry $entry -Kind task -Content 'Input validation matrix' `
                -SubmissionId ('submission-' + $case.name) -TaskId $case.task_id -CliRunAction { throw 'input refusal must stop before runner invocation' }

            $receipt.status | Should -Be $case.expected_status
            $receipt.backend | Should -Be $case.expected_backend
            $receipt.reason_code | Should -Be $case.expected_reason
            (Test-WinsmuxSubmissionReceipt -Receipt $receipt) | Should -Be $true
            { ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt | Out-Null } | Should -Not -Throw

            $parsed = ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt | ConvertFrom-Json
            $parsed.protocol_version | Should -Be 1
            $parsed.status | Should -Be $case.expected_status
            $parsed.backend | Should -Be $case.expected_backend
            $parsed.reason_code | Should -Be $case.expected_reason
        }
    }

    It 'ROUND3 P1 validates the complete public receipt shape for all four statuses' {
        $submissionId = 'submission-round3-receipt-shape'
        $record = New-WinsmuxSubmissionRunRecord -SubmissionId $submissionId -RunId $submissionId -TaskId 'task-round3-receipt-shape' -Kind task -TaskTitle 'Receipt shape' `
            -SlotId worker-1 -Backend api_llm -Status started -RequestConsumed -RequestDigest ('d' * 64)
        $statuses = @('accepted', 'rejected', 'unavailable', 'unsupported')

        foreach ($status in $statuses) {
            $receipt = if ($status -eq 'accepted') {
                New-WinsmuxSubmissionReceipt -Kind task -Status accepted -Backend api_llm -SubmissionId $submissionId -Target ([ordered]@{ label = 'worker-1' }) -Acknowledgement $record
            } else {
                New-WinsmuxSubmissionReceipt -Kind task -Status $status -Backend api_llm -SubmissionId $submissionId -ReasonCode ($status + '_test')
            }
            (Test-WinsmuxSubmissionReceipt -Receipt $receipt) | Should -Be $true
            { ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt } | Should -Not -Throw

            $invalidReason = ($receipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable)
            $invalidReason['reason_code'] = 'token=sk-synthetic-secret-value'
            (Test-WinsmuxSubmissionReceipt -Receipt $invalidReason) | Should -Be $false
            { ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $invalidReason } | Should -Throw

            $invalidDiagnostic = ($receipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable)
            $invalidDiagnostic['diagnostic'] = 'token=sk-synthetic-secret-value'
            (Test-WinsmuxSubmissionReceipt -Receipt $invalidDiagnostic) | Should -Be $false
            { ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $invalidDiagnostic } | Should -Throw

            $missingAcknowledgement = ($receipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable)
            $missingAcknowledgement.Remove('acknowledgement')
            (Test-WinsmuxSubmissionReceipt -Receipt $missingAcknowledgement) | Should -Be $false
            { ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $missingAcknowledgement } | Should -Throw

            $extraField = ($receipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable)
            $extraField['provider_payload'] = 'private-provider-data'
            (Test-WinsmuxSubmissionReceipt -Receipt $extraField) | Should -Be $false
            { ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $extraField } | Should -Throw

            if ($status -ne 'accepted') {
                $nonNullAcknowledgement = ($receipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable)
                $nonNullAcknowledgement['acknowledgement'] = ConvertTo-WinsmuxPublicAcknowledgement -Acknowledgement $record
                (Test-WinsmuxSubmissionReceipt -Receipt $nonNullAcknowledgement) | Should -Be $false
                { ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $nonNullAcknowledgement } | Should -Throw
            }
        }
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

It 'defines enterprise execution policy for prepared isolated broker runs outside prompts' {
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
        Save-WinsmuxManifest -ProjectDir $script:workersTempRoot -Manifest ([ordered]@{
            version = 1
            saved_at = '2026-05-16T00:00:00Z'
            session = [ordered]@{
                name = 'winsmux-orchestra'
                project_dir = $script:workersTempRoot
                git_worktree_dir = (Join-Path $script:workersTempRoot '.git')
            }
            panes = [ordered]@{
                'worker-2' = [ordered]@{
                    pane_id = '%2'
                    slot_id = 'worker-2'
                    worker_backend = 'local'
                    role = 'Worker'
                    launch_dir = $script:workersTempRoot
                    status = 'ready'
                }
            }
            tasks = [ordered]@{
                queued = @()
                in_progress = @()
                completed = @()
            }
            worktrees = [ordered]@{}
        })
        'payload' | Set-Content -Path (Join-Path $script:workersTempRoot 'input.txt') -Encoding UTF8
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id policy-run --json --project-dir $script:workersTempRoot | Out-Null
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker baseline worker-2 --run-id policy-run --endpoint https://broker.example.invalid/worker --node-id broker-a --json --project-dir $script:workersTempRoot | Out-Null

        $previousNow = $env:WINSMUX_TEST_NOW_UTC
        try {
            $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:00Z'
            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker token issue w2 --run-id policy-run --ttl-seconds 900 --json --project-dir $script:workersTempRoot | Out-Null

            $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers policy baseline worker-2 --run-id policy-run --network broker-only --write workspace-artifacts --provider configured --require-check codex_review --require-evidence reviewer:release_review --json --project-dir $script:workersTempRoot
            $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
            $serialized = $payload | ConvertTo-Json -Depth 32
            $manifestPath = Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\policy-run\execution-policy.json'

            $payload.status | Should -Be 'policy_defined'
            $payload.health | Should -Be 'enforced'
            $payload.reason | Should -Be 'policy_enforced_before_execution'
            $payload.execution_profile | Should -Be 'isolated-enterprise'
            $payload.public_default | Should -Be $false
            $payload.controls.network.mode | Should -Be 'broker-only'
            $payload.controls.network.outbound_network | Should -Be 'blocked_before_execution'
            $payload.controls.network.broker_only_requires_token | Should -Be $true
            $payload.controls.write.mode | Should -Be 'workspace-artifacts'
            @($payload.controls.write.allowed_roots) | Should -Contain '.winsmux/isolated-workspaces/worker-2/policy-run/workspace'
            @($payload.controls.write.allowed_roots) | Should -Contain '.winsmux/isolated-workspaces/worker-2/policy-run/artifacts'
            $payload.controls.write.direct_project_write | Should -Be 'prohibited'
            $payload.controls.provider.mode | Should -Be 'configured'
            $payload.controls.provider.prompt_override_allowed | Should -Be $false
            @($payload.required_evidence.builder) | Should -Contain 'focused_tests'
            @($payload.required_evidence.reviewer) | Should -Contain 'codex_review'
            @($payload.required_evidence.reviewer) | Should -Contain 'release_review'
            @($payload.mandatory_checks) | Should -Contain 'broker_baseline'
            @($payload.mandatory_checks) | Should -Contain 'broker_token_valid'
            @($payload.mandatory_checks) | Should -Contain 'codex_review'
            $payload.alignment.broker_baseline.manifest | Should -Be '.winsmux/isolated-workspaces/worker-2/policy-run/broker-baseline.json'
            $payload.alignment.broker_token.manifest | Should -Be '.winsmux/isolated-workspaces/worker-2/policy-run/broker-token.json'
            $payload.alignment.broker_token.health | Should -Be 'valid'
            $payload.alignment.broker_token.baseline_node_id | Should -Be 'broker-a'
            $payload.alignment.broker_token.baseline_endpoint | Should -Be 'https://broker.example.invalid/worker'
            $payload.alignment.broker_token.value_output | Should -Be $false
            $payload.failure_policy.pre_execution_required | Should -Be $true
            $payload.failure_policy.operator_visible_stop_reasons | Should -Be $true
            @($payload.failure_policy.fail_closed_on) | Should -Contain 'missing_or_invalid_broker_token'
            $payload.operator_surface.status_projection | Should -Be 'workers.status.policy'
            $payload.locations.manifest.reference | Should -Be '.winsmux/isolated-workspaces/worker-2/policy-run/execution-policy.json'
            @($payload.testable_guards) | Should -Contain 'policy_options_validated'
            Test-Path -LiteralPath $manifestPath | Should -Be $true
            $serialized | Should -Not -Match ([regex]::Escape($script:workersTempRoot))
            $serialized | Should -Not -Match ([regex]::Escape($script:workersTempRoot.Replace('\', '\\')))

            $statusOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status worker-2 --json --project-dir $script:workersTempRoot
            $statusPayload = ($statusOutput | Select-Object -Last 1) | ConvertFrom-Json
            $statusRow = @($statusPayload.workers)[0]
            $statusRow.policy.run_id | Should -Be 'policy-run'
            $statusRow.policy.execution_profile | Should -Be 'isolated-enterprise'
            $statusRow.policy.status | Should -Be 'policy_defined'
            $statusRow.policy.health | Should -Be 'enforced'
            $statusRow.policy.network | Should -Be 'broker-only'
            $statusRow.policy.write | Should -Be 'workspace-artifacts'
            $statusRow.policy.provider | Should -Be 'configured'
            $statusRow.policy.mandatory_checks | Should -Match 'codex_review'
            $statusRow.policy.required_evidence | Should -Match 'release_review'
            $statusRow.policy.manifest | Should -Be '.winsmux/isolated-workspaces/worker-2/policy-run/execution-policy.json'

            $workspaceOnlyOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers policy baseline worker-2 --run-id policy-run --network broker-only --write workspace-only --provider configured --json --project-dir $script:workersTempRoot
            $workspaceOnly = ($workspaceOnlyOutput | Select-Object -Last 1) | ConvertFrom-Json
            $workspaceOnly.controls.write.mode | Should -Be 'workspace-only'
            @($workspaceOnly.controls.write.allowed_roots) | Should -HaveCount 1
            @($workspaceOnly.controls.write.allowed_roots) | Should -Contain '.winsmux/isolated-workspaces/worker-2/policy-run/workspace'
            @($workspaceOnly.controls.write.allowed_roots) | Should -Not -Contain '.winsmux/isolated-workspaces/worker-2/policy-run/downloads'
            @($workspaceOnly.controls.write.allowed_roots) | Should -Not -Contain '.winsmux/isolated-workspaces/worker-2/policy-run/artifacts'

            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id policy-run-next --json --project-dir $script:workersTempRoot | Out-Null
            $nextStatusOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status worker-2 --json --project-dir $script:workersTempRoot
            $nextStatusPayload = ($nextStatusOutput | Select-Object -Last 1) | ConvertFrom-Json
            $nextStatusRow = @($nextStatusPayload.workers)[0]

            $nextStatusRow.workspace.run_id | Should -Be 'policy-run-next'
            $nextStatusRow.broker | Should -BeNullOrEmpty
            $nextStatusRow.policy | Should -BeNullOrEmpty
        } finally {
            $env:WINSMUX_TEST_NOW_UTC = $previousNow
        }

        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id policy-stale-endpoint-token --json --project-dir $script:workersTempRoot | Out-Null
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker baseline worker-2 --run-id policy-stale-endpoint-token --endpoint https://broker-a.example.invalid/worker --node-id broker-a --json --project-dir $script:workersTempRoot | Out-Null
        $previousNow = $env:WINSMUX_TEST_NOW_UTC
        try {
            $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:00Z'
            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker token issue worker-2 --run-id policy-stale-endpoint-token --ttl-seconds 900 --json --project-dir $script:workersTempRoot | Out-Null
            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker baseline worker-2 --run-id policy-stale-endpoint-token --endpoint https://broker-b.example.invalid/worker --node-id broker-a --json --project-dir $script:workersTempRoot | Out-Null
            $staleEndpointToken = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers policy baseline worker-2 --run-id policy-stale-endpoint-token --json --project-dir $script:workersTempRoot 2>&1
            $LASTEXITCODE | Should -Be 1
            ($staleEndpointToken | Out-String) | Should -Match 'requires a valid broker token'
            Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\policy-stale-endpoint-token\execution-policy.json') | Should -Be $false
        } finally {
            $env:WINSMUX_TEST_NOW_UTC = $previousNow
        }
    }

It 'fails closed for enterprise execution policy outside the prepared broker boundary' {
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

        $localProfile = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers policy baseline worker-2 --run-id policy-local --profile local-windows --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($localProfile | Out-String) | Should -Match 'requires execution profile isolated-enterprise'

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

        $invalidNetwork = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers policy baseline worker-2 --run-id policy-invalid --network internet --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($invalidNetwork | Out-String) | Should -Match '--network must be one of'

        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id policy-missing-broker --json --project-dir $script:workersTempRoot | Out-Null
        $missingBroker = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers policy baseline worker-2 --run-id policy-missing-broker --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($missingBroker | Out-String) | Should -Match 'requires an existing broker baseline'
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\policy-missing-broker\execution-policy.json') | Should -Be $false

        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id policy-missing-token --json --project-dir $script:workersTempRoot | Out-Null
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker baseline worker-2 --run-id policy-missing-token --endpoint https://broker.example.invalid/worker --json --project-dir $script:workersTempRoot | Out-Null
        $missingToken = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers policy baseline worker-2 --run-id policy-missing-token --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($missingToken | Out-String) | Should -Match 'requires a valid broker token'
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\policy-missing-token\execution-policy.json') | Should -Be $false

        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id policy-expired-token --json --project-dir $script:workersTempRoot | Out-Null
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker baseline worker-2 --run-id policy-expired-token --endpoint https://broker.example.invalid/worker --json --project-dir $script:workersTempRoot | Out-Null
        $previousNow = $env:WINSMUX_TEST_NOW_UTC
        try {
            $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:00Z'
            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker token issue worker-2 --run-id policy-expired-token --ttl-seconds 60 --json --project-dir $script:workersTempRoot | Out-Null
            $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:02:00Z'
            $expiredToken = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers policy baseline worker-2 --run-id policy-expired-token --json --project-dir $script:workersTempRoot 2>&1
            $LASTEXITCODE | Should -Be 1
            ($expiredToken | Out-String) | Should -Match 'requires a valid broker token'
            Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\policy-expired-token\execution-policy.json') | Should -Be $false
        } finally {
            $env:WINSMUX_TEST_NOW_UTC = $previousNow
        }

        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id policy-mismatched-token --json --project-dir $script:workersTempRoot | Out-Null
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker baseline worker-2 --run-id policy-mismatched-token --endpoint https://broker.example.invalid/worker --node-id broker-a --json --project-dir $script:workersTempRoot | Out-Null
        $previousNow = $env:WINSMUX_TEST_NOW_UTC
        try {
            $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:00Z'
            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker token issue worker-2 --run-id policy-mismatched-token --ttl-seconds 900 --json --project-dir $script:workersTempRoot | Out-Null
            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker baseline worker-2 --run-id policy-mismatched-token --endpoint https://broker.example.invalid/worker --node-id broker-b --json --project-dir $script:workersTempRoot | Out-Null
            $mismatchedToken = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers policy baseline worker-2 --run-id policy-mismatched-token --json --project-dir $script:workersTempRoot 2>&1
            $LASTEXITCODE | Should -Be 1
            ($mismatchedToken | Out-String) | Should -Match 'requires a valid broker token'
            Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\policy-mismatched-token\execution-policy.json') | Should -Be $false
        } finally {
            $env:WINSMUX_TEST_NOW_UTC = $previousNow
        }
    }
}
