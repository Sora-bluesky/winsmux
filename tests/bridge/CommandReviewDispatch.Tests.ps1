$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'TASK781 atomic acknowledgement run records' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\submission-contract.ps1')
    }

    BeforeEach {
        $script:task781AtomicRoot = Join-Path ([IO.Path]::GetTempPath()) ('winsmux-task781-atomic-' + [guid]::NewGuid().ToString('N'))
        $script:task781AtomicId = 'submission-task781-atomic'
        $script:task781AtomicRecord = New-WinsmuxSubmissionRunRecord -SubmissionId $script:task781AtomicId `
            -RunId $script:task781AtomicId -Kind task -TaskTitle 'Atomic acknowledgement record' -SlotId worker-1 `
            -Backend codex -Status started -RequestConsumed -RequestDigest ('a' * 64)
    }

    AfterEach {
        Remove-Item -LiteralPath $script:task781AtomicRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'TASK781 leaves no partial run artifact after <Mode>' -ForEach @(
        @{ Mode = 'write_failure' }
        @{ Mode = 'flush_failure' }
        @{ Mode = 'move_failure' }
        @{ Mode = 'existing_winner' }
    ) {
        $runPath = Get-WinsmuxSubmissionRunPath -ProjectDir $script:task781AtomicRoot -SlotId worker-1 `
            -RunId $script:task781AtomicId
        if ($Mode -in @('write_failure', 'flush_failure')) {
            Mock Write-WinsmuxSubmissionRunRecordTempFile {
                param([string]$Path, [byte[]]$Bytes)
                $length = if ($Mode -eq 'write_failure') { [Math]::Min(8, $Bytes.Length) } else { $Bytes.Length }
                [IO.File]::WriteAllBytes($Path, $Bytes[0..($length - 1)])
                throw "synthetic $Mode"
            }
        } elseif ($Mode -eq 'move_failure') {
            Mock Move-WinsmuxSubmissionRunRecordFile { throw 'synthetic move failure' }
        } else {
            New-Item -ItemType Directory -Path (Split-Path -Parent $runPath) -Force | Out-Null
            [IO.File]::WriteAllText($runPath, 'race-winner', [Text.UTF8Encoding]::new($false))
        }

        {
            Write-WinsmuxSubmissionRunRecord -ProjectDir $script:task781AtomicRoot -SlotId worker-1 `
                -Record $script:task781AtomicRecord
        } | Should -Throw

        if ($Mode -eq 'existing_winner') {
            (Get-Content -LiteralPath $runPath -Raw -Encoding UTF8) | Should -BeExactly 'race-winner'
        } else {
            Test-Path -LiteralPath $runPath -PathType Leaf | Should -BeFalse
        }
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $runPath) -Filter '.run-*.tmp' -File `
            -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}

Describe 'winsmux review-pack command' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:reviewPackTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-review-pack-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:reviewPackTempRoot -Force | Out-Null
        $script:reviewPackManifestDir = Join-Path $script:reviewPackTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:reviewPackManifestDir -Force | Out-Null
        $script:reviewPackManifestPath = Join-Path $script:reviewPackManifestDir 'manifest.yaml'
        $script:reviewPackEventsPath = Join-Path $script:reviewPackManifestDir 'events.jsonl'

        Push-Location $script:reviewPackTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:reviewPackTempRoot -and (Test-Path $script:reviewPackTempRoot)) {
            Remove-Item -Path $script:reviewPackTempRoot -Recurse -Force
        }

        $global:Target = $null
        $global:Rest = @()
        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

    It 'writes a bounded reviewer packet without logs, secrets, local paths, or vendor content' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:reviewPackTempRoot
panes:
  worker-2:
    pane_id: %6
    role: Worker
    task_id: task-474
    parent_run_id: operator:session-1
    goal: Ship bounded reviewer packets
    task: Implement review-pack
    task_type: implementation
    task_state: in_progress
    task_owner: worker-2
    review_state: PENDING
    priority: P1
    blocking: true
    branch: worktree-worker-2
    head_sha: abc1234def5678
    worktree: /home/alice/repo
    changed_file_count: 7
    changed_files: '["scripts/winsmux-core.ps1","node_modules/pkg/index.js","dist/app.exe",".env","/home/alice/repo/src/app.ts","\\\\server\\share\\file.ts","src/.."]'
    write_scope: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    read_scope: '["docs/operator-model.md"]'
    constraints: '["no raw logs in reviewer packet"]'
    expected_output: Stable review-pack JSON
    verification_plan: '["Invoke-Pester tests/winsmux-bridge.Tests.ps1"]'
    review_required: true
    provider_target: antigravity:worker
    agent_role: worker
    timeout_policy: standard
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:reviewPackManifestPath -Encoding UTF8

        $observationPack = New-ObservationPackFile -ProjectDir $script:reviewPackTempRoot -ObservationPack ([ordered]@{
            run_id          = 'task:task-474'
            task_id         = 'task-474'
            pane_id         = '%6'
            slot            = 'worker-2'
            hypothesis      = 'bounded packets are enough for review'
            result          = 'worker result ready from /workspace/winsmux'
            confidence      = 0.74
            next_action     = 'request_codex_review'
            failing_command = 'Invoke-Pester /home/alice/repo/tests/winsmux-bridge.Tests.ps1 token=PLACEHOLDER_VALUE'
        })
        $consultationPacket = New-ConsultationPacketFile -ProjectDir $script:reviewPackTempRoot -ConsultationPacket ([ordered]@{
            run_id         = 'task:task-474'
            task_id        = 'task-474'
            pane_id        = '%6'
            slot           = 'worker-2'
            kind           = 'consult_result'
            mode           = 'final'
            target_slot    = 'worker-1'
            confidence     = 0.68
            recommendation = 'verify packet boundaries before merge'
            risks          = @('password = PLACEHOLDER_VALUE', 'reviewer still needs focused verification')
        })

        @(
            ([ordered]@{
                timestamp = '2026-04-10T12:01:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.review_requested'
                message   = 'review requested with local path /mnt/c/Users/alice/repo and /var/folders/alice/repo'
                label     = 'worker-1'
                pane_id   = '%3'
                role      = 'Worker'
                branch    = 'worktree-worker-2'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id              = 'task-474'
                    run_id               = 'task:task-474'
                    observation_pack_ref = $observationPack.reference
                    consultation_ref     = $consultationPacket.reference
                    result               = 'worker result ready'
                    confidence           = 0.74
                    next_action          = 'request_codex_review'
                    slot                 = 'worker-2'
                    worktree             = '.worktrees/worker-2'
                }
            } | ConvertTo-Json -Compress -Depth 8),
            ([ordered]@{
                timestamp = '2026-04-10T12:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.verify.partial'
                message   = 'verification partial with token : PLACEHOLDER_VALUE'
                label     = 'worker-2'
                pane_id   = '%6'
                role      = 'Worker'
                branch    = 'worktree-worker-2'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id = 'task-474'
                    run_id  = 'task:task-474'
                    verification_contract = [ordered]@{
                        build = [ordered]@{ command = 'npm run build api_key = PLACEHOLDER_VALUE --prefix /tmp/repo'; outcome = 'PASS' }
                        test  = [ordered]@{ command = 'Invoke-Pester C:\Users\Example\repo\tests\winsmux-bridge.Tests.ps1'; outcome = 'PARTIAL' }
                    }
                    verification_result = [ordered]@{
                        outcome     = 'PARTIAL'
                        summary     = 'rerun focused review-pack tests'
                        next_action = 'rerun_verify'
                    }
                }
            } | ConvertTo-Json -Compress -Depth 8)
        ) | Set-Content -Path $script:reviewPackEventsPath -Encoding UTF8

@'
{
  "worktree-worker-2": {
    "status": "PENDING",
    "branch": "worktree-worker-2",
    "head_sha": "abc1234def5678",
    "request": {
      "branch": "worktree-worker-2",
      "head_sha": "abc1234def5678",
      "target_review_label": "worker-1",
      "target_review_pane_id": "%3",
      "target_review_role": "Worker",
      "review_contract": {
        "version": 1,
        "source_task": "TASK-474",
        "issue_ref": "#911",
        "style": "bounded_pack",
        "required_scope": [
          "bounded_review_pack",
          "review /home/alice/repo scope",
          "token : PLACEHOLDER_VALUE"
        ]
      }
    },
    "reviewer": {
      "pane_id": "%3",
      "label": "worker-1",
      "role": "Worker"
    },
    "updatedAt": "2026-04-10T12:01:00+09:00"
  }
}
'@ | Set-Content -Path (Join-Path $script:reviewPackManifestDir 'review-state.json') -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%6' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-ReviewPack -ReviewPackTarget 'task:task-474' -ReviewPackRest @('--json') | Out-String | ConvertFrom-Json -AsHashtable)
        $pack = $result['review_pack']
        $serialized = $pack | ConvertTo-Json -Depth 20

        $pack['packet_type'] | Should -Be 'review_pack'
        $pack['schema_version'] | Should -Be 1
        $result['review_pack_ref'] | Should -Match '^\.winsmux/review-packs/review-pack-[a-f0-9]+\.json$'
        Test-Path -LiteralPath (Join-Path $script:reviewPackTempRoot ($result['review_pack_ref'] -replace '/', '\')) | Should -Be $true
        $pack['changed_files'] | Should -Be @('scripts/winsmux-core.ps1')
        $pack['diff_summary']['raw_diff_included'] | Should -Be $false
        $pack['commands_run'] -join '|' | Should -Match '\[REDACTED\]'
        $pack['review_request']['required_scope'] | Should -Contain 'bounded_review_pack'
        $pack['review_request']['required_scope'] -join '|' | Should -Match '\[LOCAL_PATH\]'
        $pack['review_request']['required_scope'] -join '|' | Should -Match '\[REDACTED\]'
        $pack['artifact_refs'] | Should -Contain $observationPack.reference
        $pack['artifact_refs'] | Should -Contain $consultationPacket.reference
        $pack['critic_objections'] -join '|' | Should -Match 'reviewer still needs focused verification'
        $pack['unresolved_risks'] -join '|' | Should -Match 'reviewer still needs focused verification'
        $pack['excluded_content'] | Should -Contain 'repository_dumps'
        $pack['storage_policy']['repository_dump_stored'] | Should -Be $false
        $pack['storage_policy']['full_conversation_history_stored'] | Should -Be $false
        $serialized | Should -Not -Match 'PLACEHOLDER_VALUE'
        $serialized | Should -Not -Match 'C:\\Users'
        $serialized | Should -Not -Match 'home/alice'
        $serialized | Should -Not -Match 'server/share'
        $serialized | Should -Not -Match 'workspace/winsmux'
        $serialized | Should -Not -Match 'var/folders'
        $serialized | Should -Not -Match 'tmp/repo'
        $serialized | Should -Not -Match 'src/\.\.'
        $serialized | Should -Not -Match 'node_modules'
        $serialized | Should -Not -Match 'dist/app.exe'
        $serialized | Should -Not -Match '"\.env"'
    }

    It 'requires a run id' {
        { Invoke-ReviewPack -ReviewPackTarget '--json' } | Should -Throw '*usage: winsmux review-pack*'
    }
}

Describe 'winsmux dispatch-task routing' {
    BeforeAll {
        $script:dispatchCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:dispatchRouterPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\dispatch-router.ps1'
        . $script:dispatchCorePath 'version' *> $null
        . $script:dispatchRouterPath
    }

    BeforeEach {
        $script:dispatchTaskTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-dispatch-task-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dispatchTaskTempRoot -Force | Out-Null
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation)
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode ("{0}_verified" -f $Operation) `
                -Diagnostic 'synthetic dispatch runtime verified' -Context ([ordered]@{ generation_id = 'generation-dispatch' })
        }
        Mock New-WinsmuxSubmissionAcknowledgementServer {
            [PSCustomObject]@{ pipe_name = 'winsmux-submission-ack-11111111111111111111111111111111'; challenge = ('a' * 64); server = $null }
        }
        Mock Receive-WinsmuxSubmissionAcknowledgement { throw 'synthetic acknowledgement absent' }
        Mock Complete-WinsmuxSubmissionAcknowledgement { $true }
    }

    AfterEach {
        if ($script:dispatchTaskTempRoot -and (Test-Path -LiteralPath $script:dispatchTaskTempRoot -PathType Container)) {
            Remove-Item -LiteralPath $script:dispatchTaskTempRoot -Recurse -Force
        }
    }

    It 'keeps reviewer worker slots out of generic worker dispatch targets' {
        Mock Get-PaneControlManifestEntries {
            @(
                [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%1'; Role = 'Worker'; WorkerRole = 'reviewer'; AgentRole = '' },
                [PSCustomObject]@{ Label = 'worker-2'; PaneId = '%2'; Role = 'Worker'; WorkerRole = 'impl'; AgentRole = '' }
            )
        }

        $targets = @(Get-DispatchTaskAvailableTargets -ProjectDir 'C:\repo')
        $route = Get-DispatchRoute -Text 'implement bounded review packets' -AvailableTargets $targets -DefaultRole 'Worker'

        $targets | Should -Be @('worker-2')
        $route.SelectedRole | Should -Be 'Builder'
        $route.SelectedTarget | Should -Be 'worker-2'
    }

    It 'does not fall back to labels when the manifest contains only reviewer worker slots' {
        Mock Get-PaneControlManifestEntries {
            @(
                [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%1'; Role = 'Worker'; WorkerRole = 'reviewer'; AgentRole = '' }
            )
        }
        Mock Get-Labels { @{ 'worker-1' = '%1' } }

        $targets = @(Get-DispatchTaskAvailableTargets -ProjectDir 'C:\repo')
        $route = Get-DispatchRoute -Text 'implement bounded review packets' -AvailableTargets $targets -DefaultRole 'Worker'

        $targets.Count | Should -Be 0
        $route.HandleLocally | Should -Be $true
    }

    It 'validates only protocol-v1 submission receipts with the fixed vocabulary' {
        $evidence = New-WinsmuxSubmissionRunRecord -SubmissionId 'submission-test-1' -RunId 'submission-test-1' -Kind task -TaskTitle 'Test task' -SlotId worker-1 -Backend codex -Status started -RequestConsumed -RequestDigest ('a' * 64)
        $receipt = New-WinsmuxSubmissionReceipt -Kind task -Status accepted -Backend codex -SubmissionId 'submission-test-1' -Target ([ordered]@{ label = 'worker-1' }) -Acknowledgement $evidence

        (Test-WinsmuxSubmissionReceipt -Receipt $receipt) | Should -Be $true
        $receipt.protocol_version = 2
        (Test-WinsmuxSubmissionReceipt -Receipt $receipt) | Should -Be $false
        $receipt.protocol_version = 1
        $receipt.status = 'complete'
        (Test-WinsmuxSubmissionReceipt -Receipt $receipt) | Should -Be $false
        $receipt.status = 'accepted'
        $receipt.backend = 'unknown'
        (Test-WinsmuxSubmissionReceipt -Receipt $receipt) | Should -Be $false
    }

    It 'does not accept shell or Codex send success without a backend run record' {
        $entry = [PSCustomObject]@{ Label = 'worker-2'; PaneId = '%2'; Role = 'Worker'; WorkerBackend = 'codex' }
        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:dispatchTaskTempRoot -ManifestEntry $entry -Kind task -Content 'implement the focused change' -SubmissionId 'submission-test-2' `
            -SendAction { param($paneId, $commandText) } `
            -RunResultAction { param($projectDir, $slotId, $runId) $null }

        $receipt.status | Should -Be 'rejected'
        $receipt.reason_code | Should -Be 'backend_acknowledgement_missing'
    }

    It 'refuses shell or Codex even when mutable local evidence claims a matching run record' {
        $entry = [PSCustomObject]@{ Label = 'worker-2'; PaneId = '%2'; Role = 'Worker'; WorkerBackend = 'local' }
        $script:mutableRunResultRead = $false
        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:dispatchTaskTempRoot -ManifestEntry $entry -Kind task -Content 'implement the focused change' -SubmissionId 'submission-test-3' `
            -SendAction { param($paneId, $commandText) } `
            -RunResultAction { param($projectDir, $slotId, $runId) $script:mutableRunResultRead = $true; New-WinsmuxSubmissionRunRecord -SubmissionId $runId -RunId $runId -Kind task -TaskTitle 'Test task' -SlotId $slotId -Backend local -Status started -RequestConsumed -RequestDigest (Get-WinsmuxSubmissionRequestDigest -Request 'implement the focused change') }

        $receipt.status | Should -Be 'rejected'
        $receipt.reason_code | Should -Be 'backend_acknowledgement_missing'
        $receipt.acknowledgement | Should -BeNullOrEmpty
        $script:mutableRunResultRead | Should -BeFalse
    }

    It 'sends api_llm an exec packet and converts runner refusal to typed rejected' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-submission-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        try {
            $script:apiLlmCommand = ''
            $entry = [PSCustomObject]@{ Label = 'worker-5'; PaneId = '%5'; Role = 'Worker'; WorkerBackend = 'api_llm' }
            $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $tempRoot -ManifestEntry $entry -Kind review -Content 'review synthetic change' -SubmissionId 'submission-test-4' -ReviewStateRoot $tempRoot `
                -SendAction { param($paneId, $commandText) $script:apiLlmCommand = $commandText } `
                -RunResultAction { param($projectDir, $slotId, $runId) [ordered]@{ status = 'failed'; reason = 'runner_rejected_packet'; exit_code = 1; run_id = $runId } }

            $receipt.status | Should -Be 'rejected'
            $receipt.reason_code | Should -Be 'runner_rejected_packet'
            $expectedPacketPath = [IO.Path]::GetFullPath((Join-Path $tempRoot '.winsmux\submissions\submission-test-4.json'))
            $expectedReviewCommand = "winsmux review-request --state-root $tempRoot --submission-id submission-test-4"
            $script:apiLlmCommand | Should -BeExactly "exec $expectedPacketPath`n$expectedReviewCommand"
            @($script:apiLlmCommand -split "`n") | Should -HaveCount 2
            $script:apiLlmCommand | Should -Not -Match 'review synthetic change'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns unavailable for a CLI backend without a runnable command' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-submission-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        try {
            $entry = [PSCustomObject]@{ Label = 'worker-3'; PaneId = '%3'; Role = 'Worker'; WorkerBackend = 'antigravity' }
            $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $tempRoot -ManifestEntry $entry -Kind task -Content 'analyze synthetic input' -SubmissionId 'submission-test-5' `
                -CliRunAction { param($projectDir, $slotId, $packetPath, $submissionId) [ordered]@{ status = 'unavailable'; reason = 'cli_command_missing'; exit_code = 1 } }

            $receipt.status | Should -Be 'unavailable'
            $receipt.reason_code | Should -Be 'cli_command_missing'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepts a CLI backend only from a confirmed started or completed run receipt' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-submission-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        try {
            $entry = [PSCustomObject]@{ Label = 'worker-3'; PaneId = '%3'; Role = 'Worker'; WorkerBackend = 'antigravity' }
            $script:antigravityReviewCommand = ''
            $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $tempRoot -ManifestEntry $entry -Kind review -Content 'review synthetic input' -SubmissionId 'submission-test-7' -ReviewStateRoot $tempRoot `
                -CliRunAction { param($projectDir, $slotId, $packetPath, $submissionId, $backend, $kind, $reviewStateRoot, $reviewRequestCommand) $script:antigravityReviewCommand = $reviewRequestCommand; New-WinsmuxSubmissionRunRecord -SubmissionId $submissionId -RunId $submissionId -Kind review -TaskTitle 'Review test' -SlotId $slotId -Backend antigravity -Status started -RequestConsumed -RequestDigest (Get-WinsmuxSubmissionRequestDigest -Request 'review synthetic input') }

            $receipt.status | Should -Be 'accepted'
            $receipt.acknowledgement.type | Should -Be 'backend_run_record'
            $receipt.acknowledgement.run_id | Should -Be 'submission-test-7'
            $quotedRoot = "'" + $tempRoot.Replace("'", "''") + "'"
            $script:antigravityReviewCommand | Should -BeExactly "winsmux review-request --state-root $quotedRoot --submission-id submission-test-7"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails closed without a manifest or configured worker target' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-submission-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        try {
            Push-Location $tempRoot
            $output = & pwsh -NoProfile -File $script:dispatchCorePath dispatch-task implement synthetic change 2>&1
            $exitCode = $LASTEXITCODE
            Pop-Location

            $exitCode | Should -Be 1
            $receipt = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)[0] | ConvertFrom-Json
            $receipt.protocol_version | Should -Be 1
            $receipt.status | Should -Be 'rejected'
            $receipt.status | Should -Not -Be 'accepted'
        } finally {
            if ((Get-Location).Path -eq $tempRoot) { Pop-Location }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns typed router ownership context instead of free-text success' {
        $route = [PSCustomObject]@{ SelectedRole = 'Operator'; SelectedTarget = $null; RuleId = 'route.operator_owned.v1'; MatchedKeywords = @('commit'); Reason = 'operator owned'; HandleLocally = $true }
        $receipt = New-WinsmuxRouterRefusalReceipt -Kind task -Route $route -SubmissionId 'submission-test-6'

        $receipt.status | Should -Be 'rejected'
        $receipt.reason_code | Should -Be 'router_operator_owned'
        $receipt.routing.expected_owner | Should -Be 'Operator'
        $receipt.routing.rule_id | Should -Be 'route.operator_owned.v1'
        $receipt.routing.next_shape | Should -Not -BeNullOrEmpty
    }

    It 'TASK781 C50/C51 preserves typed deferred runtime refusals for task and review receipts' {
        $taskReceipt = New-WinsmuxDeferredStartFailureReceipt -Kind task -SubmissionId 'submission-task-c50' `
            -PaneId '%2' -Failure ([System.InvalidOperationException]::new(
                'runtime dispatch refused (invalid_supervisor_identity): generation expired before deferred start'))
        $reviewReceipt = New-WinsmuxDeferredStartFailureReceipt -Kind review -SubmissionId 'submission-review-c51' `
            -PaneId '%3' -Failure ([System.InvalidOperationException]::new(
                'runtime dispatch refused (runtime_target_mismatch): deferred pane belongs to another session'))
        $genericReceipt = New-WinsmuxDeferredStartFailureReceipt -Kind task -SubmissionId 'submission-task-generic' `
            -PaneId '%4' -Failure ([System.InvalidOperationException]::new('synthetic untyped failure'))

        $taskReceipt.status | Should -Be 'unavailable'
        $taskReceipt.reason_code | Should -Be 'invalid_supervisor_identity'
        $taskReceipt.diagnostic | Should -Be 'generation expired before deferred start'
        $reviewReceipt.status | Should -Be 'unavailable'
        $reviewReceipt.reason_code | Should -Be 'runtime_target_mismatch'
        $reviewReceipt.diagnostic | Should -Be 'deferred pane belongs to another session'
        $genericReceipt.reason_code | Should -Be 'deferred_start_failed'
        $genericReceipt.diagnostic | Should -Be 'synthetic untyped failure'

        $controlPlaneContent = Get-Content -LiteralPath (
            Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\control-plane-dispatch.ps1'
        ) -Raw -Encoding UTF8
        $coreContent = Get-Content -LiteralPath $script:dispatchCorePath -Raw -Encoding UTF8
        $controlPlaneContent | Should -Match 'New-WinsmuxDeferredStartFailureReceipt\s+-Kind\s+task'
        $coreContent | Should -Match 'New-WinsmuxDeferredStartFailureReceipt\s+-Kind\s+review'
    }
}

Describe 'winsmux explain command' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:explainTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-explain-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:explainTempRoot -Force | Out-Null
        $script:explainManifestDir = Join-Path $script:explainTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:explainManifestDir -Force | Out-Null
        $script:explainManifestPath = Join-Path $script:explainManifestDir 'manifest.yaml'
        $script:explainEventsPath = Join-Path $script:explainManifestDir 'events.jsonl'
        $script:explainReviewStatePath = Join-Path $script:explainManifestDir 'review-state.json'

        Push-Location $script:explainTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:explainTempRoot -and (Test-Path $script:explainTempRoot)) {
            Remove-Item -Path $script:explainTempRoot -Recurse -Force
        }

        $global:Target = $null
        $global:Rest = @()
        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

    It 'returns a json explanation with related events and review state' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    parent_run_id: operator:session-1
    goal: Ship run contract primitives
    task: Implement run ledger
    task_type: implementation
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    priority: P0
    blocking: true
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    write_scope: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    read_scope: '["winsmux-core/scripts/pane-status.ps1"]'
    constraints: '["preserve existing board schema"]'
    expected_output: Stable explain JSON
    verification_plan: '["Invoke-Pester tests/winsmux-bridge.Tests.ps1","verify explain --json contract"]'
    review_required: true
    provider_target: codex:gpt-5.4
    agent_role: worker
    timeout_policy: standard
    handoff_refs: '["docs/handoff.md"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        $explainObservationPack = New-ObservationPackFile -ProjectDir $script:explainTempRoot -ObservationPack ([ordered]@{
            run_id               = 'task:task-256'
            task_id              = 'task-256'
            pane_id              = '%2'
            slot                 = 'slot-builder-1'
            hypothesis           = 'experiment packet should flow into explain'
            test_plan            = @('collect matching events', 'normalize packet')
            changed_files        = @('scripts/winsmux-core.ps1')
            working_tree_summary = '1 file modified'
            failing_command      = 'Invoke-Pester tests/winsmux-bridge.Tests.ps1'
            env_fingerprint      = 'env:abc123'
            command_hash         = 'cmd:def456'
        })
        $explainConsultationPacket = New-ConsultationPacketFile -ProjectDir $script:explainTempRoot -ConsultationPacket ([ordered]@{
            run_id         = 'task:task-256'
            task_id        = 'task-256'
            pane_id        = '%2'
            slot           = 'slot-builder-1'
            kind           = 'consult_result'
            mode           = 'early'
            target_slot    = 'slot-review-1'
            confidence     = 0.66
            recommendation = 'consult before work'
            next_test      = 'approval_waiting'
            risks          = @('needs reviewer confirmation')
        })

        @(
            ([ordered]@{
                timestamp = '2026-04-10T12:01:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.review_requested'
                message   = 'review requested'
                label     = 'reviewer-1'
                pane_id   = '%3'
                role      = 'Reviewer'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id              = 'task-256'
                    hypothesis           = 'experiment packet should flow into explain'
                    test_plan            = @('collect matching events', 'normalize packet')
                    result               = 'consult before work'
                    confidence           = 0.66
                    next_action          = 'approval_waiting'
                    observation_pack_ref = $explainObservationPack.reference
                    consultation_ref     = $explainConsultationPacket.reference
                    run_id               = 'task:task-256'
                    slot                 = 'slot-builder-1'
                    worktree             = '.worktrees/builder-1'
                    env_fingerprint      = 'env:abc123'
                    command_hash         = 'cmd:def456'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T12:01:30+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.mailbox.message_received'
                message   = 'team memory reference captured'
                label     = 'operator'
                pane_id   = ''
                role      = 'Operator'
                source    = 'mailbox'
                data      = [ordered]@{
                    task_id            = 'task-256'
                    run_id             = 'task:task-256'
                    source             = 'mailbox'
                    team_memory_refs   = @('team-memory:task-256:operator-standard', 'C:\Users\Example\private.md', 'private note body')
                    evidence_note_refs = @('evidence-note:task-256:operator-standard', '%LOCALAPPDATA%\winsmux\private.md')
                    message_body       = 'operator direction body must not be exposed'
                }
            } | ConvertTo-Json -Compress -Depth 8),
            ([ordered]@{
                timestamp = '2026-04-10T12:01:40+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.mailbox.message_received'
                message   = 'mailbox event without explicit ref'
                label     = 'operator'
                pane_id   = ''
                role      = 'Operator'
                source    = 'mailbox'
                data      = [ordered]@{
                    task_id          = 'task-256'
                    run_id           = 'task:task-256'
                    source           = 'mailbox'
                    team_memory_refs = @('C:\Users\Example\private-2.md')
                    message_body     = 'fallback should expose only durable ref'
                }
            } | ConvertTo-Json -Compress -Depth 8),
            ([ordered]@{
                timestamp = '2026-04-10T12:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.verify.partial'
                message   = 'verification partial with drift retry'
                label     = 'reviewer-1'
                pane_id   = '%3'
                role      = 'Reviewer'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id = 'task-256'
                    run_id  = 'task:task-256'
                    verification_contract = [ordered]@{
                        mode = 'adversarial_verify'
                        build = [ordered]@{ command = 'npm run build'; outcome = 'PASS' }
                        test = [ordered]@{ command = 'Invoke-Pester tests/winsmux-bridge.Tests.ps1'; outcome = 'PARTIAL' }
                        context_budget = 120000
                        context_estimate = 42000
                        context_pack_id = 'ctx-task-256'
                        context_pack_version = '1'
                        tool_output_pruned_count = 2
                        context_pressure = 'medium'
                        context_mode = 'isolated'
                        semantic_context_pack_id = 'sem-task-256'
                        semantic_context_pack_ref = 'context-packs/sem-task-256.json'
                        source_refs = @('ADR-001', 'docs/operator-model.md#context', 'C:\Users\Example\private.md', 'private note body')
                        hard_constraints = @('do not store prompt bodies')
                        safety_rules = @('keep local paths out')
                        performance_budget = [ordered]@{ max_context_tokens = 42000 }
                        rationale = 'keep worker context scoped'
                        knowledge_pack_id = 'know-task-256'
                        knowledge_pack_ref = 'knowledge/know-task-256.json'
                        knowledge_source_refs = @('GUARDRAILS.md#17-git-guard-gate', 'docs/operator-model.md#knowledge', '%LOCALAPPDATA%\winsmux\private.md', 'private guidance body')
                        operating_guidance_refs = @('guidance:git-guard', 'guidance:review-before-merge')
                        knowledge_hard_constraints = @('never bypass git-guard')
                        capability_contract = [ordered]@{ can_edit = $true; can_merge = $false }
                        evidence_refs = @('evidence:task-256', 'C:\Users\Example\evidence.md', 'pasted evidence body')
                        rationale_refs = @('ADR-knowledge-layer', '%LOCALAPPDATA%\winsmux\rationale.md', 'pasted rationale body')
                    }
                    attempt = 2
                    verification_result = [ordered]@{
                        outcome = 'PARTIAL'
                        summary = 'rerun focused verification'
                        next_action = 'rerun_verify'
                        browser = [ordered]@{ required = $false; outcome = 'SKIPPED' }
                        screenshot = [ordered]@{ required = $false; artifact_ref = '' }
                        recording = [ordered]@{ required = $false; artifact_ref = '' }
                    }
                }
            } | ConvertTo-Json -Compress -Depth 8),
            ([ordered]@{
                timestamp = '2026-04-10T12:02:05+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.security.allowed'
                message   = 'security check passed'
                label     = 'reviewer-1'
                pane_id   = '%3'
                role      = 'Reviewer'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id = 'task-256'
                    run_id  = 'task:task-256'
                    action  = ''
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T12:02:10+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.verify.fail'
                message   = 'unrelated task local note should stay out'
                label     = 'reviewer-1'
                pane_id   = '%3'
                role      = 'Reviewer'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id = 'task-other'
                    run_id  = 'task:task-other'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
            timestamp = '2026-04-10T12:02:15+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.tdd.red'
            message   = 'test failed before implementation'
            label     = 'operator'
            pane_id   = ''
            role      = 'Operator'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id   = 'task-256'
                    run_id    = 'task:task-256'
                    tdd_phase = 'red'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T12:02:30+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T12:03:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.idle'
                message   = 'idle pane'
                label     = 'worker-1'
                pane_id   = '%6'
                role      = 'Worker'
                status    = 'ready'
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:explainEventsPath -Encoding UTF8

@'
{
  "worktree-builder-1": {
    "status": "PENDING",
    "branch": "worktree-builder-1",
    "head_sha": "abc1234def5678",
    "request": {
      "id": "review-request-__ID__",
      "branch": "worktree-builder-1",
      "head_sha": "abc1234def5678",
      "target_review_label": "reviewer-1",
      "target_review_pane_id": "%3",
      "target_review_role": "Reviewer",
      "target_reviewer_label": "reviewer-1",
      "target_reviewer_pane_id": "%3",
      "target_reviewer_role": "Reviewer",
      "review_contract": {
        "version": 1,
        "source_task": "TASK-210",
        "issue_ref": "#315",
        "style": "utility_first",
        "required_scope": [
          "design_impact",
          "replacement_coverage",
          "orphaned_artifacts",
          "pathspec_completeness"
        ]
      },
      "dispatched_at": "__TIMESTAMP__"
    },
    "reviewer": {
      "pane_id": "%3",
      "label": "reviewer-1",
      "role": "Reviewer",
      "agent_name": "codex"
    },
    "updatedAt": "__TIMESTAMP__"
  }
}
'@ | Set-Content -Path $script:explainReviewStatePath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Explain -ExplainTarget 'task:task-256' -ExplainRest @('--json') | Out-String | ConvertFrom-Json -AsHashtable)

        $result.run.run_id | Should -Be 'task:task-256'
        $result.run.task | Should -Be 'Implement run ledger'
        $result.run.parent_run_id | Should -Be 'operator:session-1'
        $result.run.goal | Should -Be 'Ship run contract primitives'
        $result.run.task_type | Should -Be 'implementation'
        $result.run.priority | Should -Be 'P0'
        $result.run.blocking | Should -Be $true
        $result.run.write_scope | Should -Be @('scripts/winsmux-core.ps1', 'tests/winsmux-bridge.Tests.ps1')
        $result.run.read_scope | Should -Be @('winsmux-core/scripts/pane-status.ps1')
        $result.run.constraints | Should -Be @('preserve existing board schema')
        $result.run.expected_output | Should -Be 'Stable explain JSON'
        $result.run.verification_plan | Should -Be @('Invoke-Pester tests/winsmux-bridge.Tests.ps1', 'verify explain --json contract')
        $result.run.review_required | Should -Be $true
        $result.run.provider_target | Should -Be 'codex:gpt-5.4'
        $result.run.agent_role | Should -Be 'worker'
        $result.run.timeout_policy | Should -Be 'standard'
        $result.run.handoff_refs | Should -Be @('docs/handoff.md')
        $result.run.experiment_packet.hypothesis | Should -Be 'experiment packet should flow into explain'
        $result.run.experiment_packet.test_plan | Should -Be @('collect matching events', 'normalize packet')
        $result.run.experiment_packet.result | Should -Be 'consult before work'
        $result.run.experiment_packet.confidence | Should -Be 0.66
        $result.run.experiment_packet.next_action | Should -Be 'approval_waiting'
        $result.run.experiment_packet.observation_pack_ref | Should -Be $explainObservationPack.reference
        $result.run.experiment_packet.consultation_ref | Should -Be $explainConsultationPacket.reference
        $result.run.experiment_packet.run_id | Should -Be 'task:task-256'
        $result.run.experiment_packet.slot | Should -Be 'slot-builder-1'
        $result.run.experiment_packet.worktree | Should -Be '.worktrees/builder-1'
        $result.run.experiment_packet.env_fingerprint | Should -Be 'env:abc123'
        $result.run.experiment_packet.command_hash | Should -Be 'cmd:def456'
        $result.run.verification_contract.mode | Should -Be 'adversarial_verify'
        $result.run.verification_result.outcome | Should -Be 'PARTIAL'
        $result.run.verification_evidence.build.command | Should -Be 'npm run build'
        $result.run.verification_evidence.test.outcome | Should -Be 'PARTIAL'
        $result.run.verification_evidence.browser.outcome | Should -Be 'SKIPPED'
        $result.run.verification_evidence.context_budget | Should -Be 120000
        $result.run.verification_evidence.context_estimate | Should -Be 42000
        $result.run.verification_evidence.context_pack_id | Should -Be 'ctx-task-256'
        $result.run.verification_evidence.context_pack_version | Should -Be '1'
        $result.run.verification_evidence.tool_output_pruned_count | Should -Be 2
        $result.run.verification_evidence.context_pressure | Should -Be 'medium'
        $result.run.context_contract.packet_type | Should -Be 'context_budget_contract'
        $result.run.context_contract.context_pack_id | Should -Be 'ctx-task-256'
        $result.run.context_contract.context_capsule.capsule_version | Should -Be 1
        $result.run.context_contract.context_capsule.run_id | Should -Be 'task:task-256'
        $result.run.context_contract.context_capsule.task_id | Should -Be 'task-256'
        $result.run.context_contract.context_capsule.source_slot | Should -Be 'builder-1'
        $result.run.context_contract.context_capsule.next_action | Should -Be 'approval_waiting'
        $result.run.context_contract.context_capsule.claim_level | Should -Be 'MOCK_INTEGRATION_VERIFIED'
        $result.run.context_contract.context_capsule.source_head_sha | Should -Be 'abc1234def5678'
        $result.run.context_contract.context_capsule.validation.valid | Should -Be $true
        $result.run.context_contract.context_capsule.privacy.raw_transcript_stored | Should -Be $false
        $result.run.context_contract.context_capsule.context_pressure.state | Should -Be 'healthy'
        $result.run.context_contract.context_capsule.context_pressure.usage.percent | Should -Be 35
        $result.run.context_contract.context_capsule.summary_quality_gate.valid | Should -Be $true
        $result.run.context_contract.router_policy.usable_for_routing | Should -Be $true
        $result.run.context_contract.context_mode | Should -Be 'isolated'
        $result.run.context_contract.semantic_context.context_pack_id | Should -Be 'sem-task-256'
        $result.run.context_contract.semantic_context.source_refs | Should -Be @('ADR-001', 'docs/operator-model.md#context')
        ($result.run.context_contract.semantic_context.source_refs -join '|') | Should -Not -Match 'Users'
        ($result.run.context_contract.semantic_context.source_refs -join '|') | Should -Not -Match 'private note'
        $result.run.context_contract.semantic_context.hard_constraints | Should -Be @('do not store prompt bodies')
        $result.run.context_contract.semantic_context.performance_budget.max_context_tokens | Should -Be 42000
        $result.run.context_contract.semantic_context.adr_body_stored | Should -Be $false
        $result.run.context_contract.semantic_context.persona_prompt_stored | Should -Be $false
        $result.run.context_contract.semantic_context.private_source_body_stored | Should -Be $false
        $result.run.context_contract.knowledge_layer.packet_type | Should -Be 'knowledge_layer_contract'
        $result.run.context_contract.knowledge_layer.knowledge_pack_id | Should -Be 'know-task-256'
        $result.run.context_contract.knowledge_layer.knowledge_pack_ref | Should -Be 'knowledge/know-task-256.json'
        $result.run.context_contract.knowledge_layer.source_refs | Should -Be @('GUARDRAILS.md#17-git-guard-gate', 'docs/operator-model.md#knowledge')
        ($result.run.context_contract.knowledge_layer.source_refs -join '|') | Should -Not -Match 'LOCALAPPDATA'
        ($result.run.context_contract.knowledge_layer.source_refs -join '|') | Should -Not -Match 'private guidance'
        $result.run.context_contract.knowledge_layer.operating_guidance_refs | Should -Be @('guidance:git-guard', 'guidance:review-before-merge')
        $result.run.context_contract.knowledge_layer.hard_constraints | Should -Be @('never bypass git-guard')
        $result.run.context_contract.knowledge_layer.capability_contract.can_edit | Should -Be $true
        $result.run.context_contract.knowledge_layer.capability_contract.can_merge | Should -Be $false
        $result.run.context_contract.knowledge_layer.evidence_refs | Should -Be @('evidence:task-256')
        ($result.run.context_contract.knowledge_layer.evidence_refs -join '|') | Should -Not -Match 'Users'
        ($result.run.context_contract.knowledge_layer.evidence_refs -join '|') | Should -Not -Match 'pasted evidence'
        $result.run.context_contract.knowledge_layer.rationale_refs | Should -Be @('ADR-knowledge-layer')
        ($result.run.context_contract.knowledge_layer.rationale_refs -join '|') | Should -Not -Match 'LOCALAPPDATA'
        ($result.run.context_contract.knowledge_layer.rationale_refs -join '|') | Should -Not -Match 'pasted rationale'
        $result.run.context_contract.knowledge_layer.team_memory_refs | Should -Contain 'team-memory:task-256:operator-standard'
        $result.run.context_contract.knowledge_layer.team_memory_refs | Should -Contain 'team-memory:task:task-256:event-3'
        $result.run.context_contract.knowledge_layer.freeform_body_stored | Should -Be $false
        $result.run.context_contract.knowledge_layer.private_guidance_stored | Should -Be $false
        $result.run.context_contract.knowledge_layer.local_reference_paths_stored | Should -Be $false
        $result.run.context_contract.knowledge_layer.PSObject.Properties.Name | Should -Not -Contain 'freeform_body'
        $result.run.context_contract.knowledge_layer.PSObject.Properties.Name | Should -Not -Contain 'private_guidance'
        $result.run.context_contract.fork_allowed | Should -Be $false
        $result.run.context_contract.prompt_body_stored | Should -Be $false
        $result.run.context_contract.private_memory_stored | Should -Be $false
        $result.run.context_contract.local_reference_paths_stored | Should -Be $false
        $result.run.team_memory.packet_type | Should -Be 'team_memory_contract'
        $result.run.team_memory.team_memory_refs | Should -Contain 'team-memory:task-256:operator-standard'
        $result.run.team_memory.team_memory_refs | Should -Contain 'team-memory:task:task-256:event-3'
        $result.run.team_memory.evidence_note_refs | Should -Be @('evidence-note:task-256:operator-standard')
        $result.run.team_memory.mailbox_event_count | Should -Be 2
        $result.run.team_memory.freeform_body_stored | Should -Be $false
        $result.run.team_memory.private_memory_body_stored | Should -Be $false
        $result.run.team_memory.local_reference_paths_stored | Should -Be $false
        $result.run.team_memory.PSObject.Properties.Name | Should -Not -Contain 'message_body'
        $result.run.team_memory.PSObject.Properties.Name | Should -Not -Contain 'private_memory_body'
        ($result.run.team_memory.team_memory_refs -join '|') | Should -Not -Match 'Users'
        ($result.run.team_memory.team_memory_refs -join '|') | Should -Not -Match 'private note'
        $result.run.run_insights.retry_count | Should -Be 1
        $result.run.run_insights.drift_signals | Should -Be @('drift_detected')
        $result.run.run_insights.intervention_count | Should -BeGreaterThan 0
        $result.run.run_insights.next_improvements | Should -Contain 'reduce retry loop before the next run'
        $result.run.architecture_contract.packet_type | Should -Be 'architecture_contract'
        $result.run.architecture_contract.current.drift_score | Should -Be 1
        $result.run.architecture_contract.status | Should -Be 'baseline_mismatch'
        $result.run.tdd_gate.required | Should -Be $true
        $result.run.tdd_gate.state | Should -Be 'passed'
        $result.run.tdd_gate.red_event | Should -Be 'pipeline.tdd.red'
        $result.run.audit_chain.chain_id | Should -Be 'task:task-256'
        $result.run.audit_chain.subject.task_id | Should -Be 'task-256'
        $result.run.audit_chain.subject.changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $result.run.audit_chain.subject.context_contract.context_mode | Should -Be 'isolated'
        $result.run.audit_chain.actor.label | Should -Be 'builder-1'
        $result.run.audit_chain.approval.required | Should -Be $true
        $result.run.audit_chain.approval.state | Should -Be 'pending'
        $result.run.audit_chain.approval.requested_at.ToString('o') | Should -Be '2026-04-10T03:01:00.0000000Z'
        $result.run.audit_chain.approval.requested_reviewer_label | Should -Be 'reviewer-1'
        @($result.run.audit_chain.events | ForEach-Object { $_.event }) | Should -Contain 'operator.review_requested'
        @($result.run.audit_chain.events | ForEach-Object { $_.event }) | Should -Contain 'pipeline.verify.partial'
        @($result.run.audit_chain.events | ForEach-Object { $_.event }) | Should -Contain 'pipeline.security.allowed'
        @($result.run.audit_chain.events | ForEach-Object { $_.event }) | Should -Contain 'pane.approval_waiting'
        @($result.run.audit_chain.events | ForEach-Object { $_.message }) | Should -Not -Contain 'unrelated task local note should stay out'
        ($result.run.audit_chain.events | Where-Object { $_.event -eq 'pipeline.security.allowed' } | Select-Object -First 1).what | Should -Be 'pipeline.security.allowed'
        $result.run.phase | Should -Be 'review'
        $result.run.activity | Should -Be 'waiting_for_input'
        $result.run.detail | Should -Be 'review_pending'
        $result.run.plan.goal | Should -Be 'Ship run contract primitives'
        $result.run.plan.verification_plan | Should -Be @('Invoke-Pester tests/winsmux-bridge.Tests.ps1', 'verify explain --json contract')
        $result.run.plan_checkpoints.Count | Should -Be 4
        @($result.run.plan_checkpoints | ForEach-Object { $_.name }) | Should -Be @('operator.review_requested', 'pipeline.verify.partial', 'pipeline.security.allowed', 'pane.approval_waiting')
        $result.run.plan_checkpoints[0].at.ToString('o') | Should -Be '2026-04-10T03:01:00.0000000Z'
        $result.run.phase_gate.order | Should -Be @('plan', 'build', 'test', 'review', 'package')
        $result.run.phase_gate.current_stage | Should -Be 'review'
        $result.run.phase_gate.stop_required | Should -Be $true
        $result.run.phase_gate.stop_reason | Should -Be 'needs_user_decision'
        $result.run.phase_gate.auto_continue_allowed | Should -Be $false
        $result.run.outcome.status | Should -Be 'needs_user_decision'
        $result.run.outcome.reason | Should -Be 'rerun focused verification'
        $result.run.outcome.confidence | Should -Be 0.66
        $result.run.draft_pr_gate.kind | Should -Be 'human_judgement'
        $result.run.draft_pr_gate.target | Should -Be 'draft_pr'
        $result.run.draft_pr_gate.state | Should -Be 'blocked'
        $result.run.draft_pr_gate.merge_requires_human | Should -Be $true
        $result.run.draft_pr_gate.handoff_package.summary | Should -Be 'rerun focused verification'
        $result.run.draft_pr_gate.handoff_package.remaining_risks | Should -Contain 'verification outcome is PARTIAL'
        $result.run.draft_pr_gate.handoff_package.blocked_reasons | Should -Contain 'review state is unresolved: PENDING'
        $result.run.draft_pr_gate.handoff_package.blocked_reasons | Should -Contain 'architecture baseline mismatch requires review'
        $result.run.draft_pr_gate.handoff_package.automatic_merge_allowed | Should -Be $false
        $result.observation_pack.failing_command | Should -Be 'Invoke-Pester tests/winsmux-bridge.Tests.ps1'
        $result.observation_pack.changed_files | Should -Contain 'scripts/winsmux-core.ps1'
        $result.consultation_packet.kind | Should -Be 'consult_result'
        $result.consultation_packet.mode | Should -Be 'early'
        $result.observation_pack.Contains('packet_type') | Should -BeFalse
        $result.consultation_packet.Contains('packet_type') | Should -BeFalse
        $result.Contains('experiment_packet') | Should -BeFalse
        $result.Contains('consultation_summary') | Should -BeFalse
        $result.evidence_digest.run_id | Should -Be 'task:task-256'
        $result.evidence_digest.next_action | Should -Be 'approval_waiting'
        $result.evidence_digest.phase | Should -Be 'review'
        $result.evidence_digest.activity | Should -Be 'waiting_for_input'
        $result.evidence_digest.detail | Should -Be 'review_pending'
        $result.evidence_digest.changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $result.explanation.current_state.review_state | Should -Be 'PENDING'
        $result.explanation.current_state.phase | Should -Be 'review'
        $result.explanation.current_state.activity | Should -Be 'waiting_for_input'
        $result.explanation.current_state.detail | Should -Be 'review_pending'
        $result.explanation.reasons | Should -Contain 'task_state=in_progress'
        $result.explanation.reasons | Should -Contain 'review_state=PENDING'
        $result.explanation.reasons | Should -Contain 'verify=PARTIAL'
        $result.explanation.reasons | Should -Contain 'review_contract=design_impact,replacement_coverage,orphaned_artifacts,pathspec_completeness'
        $result.review_state.status | Should -Be 'PENDING'
        $result.review_state.request.review_contract.style | Should -Be 'utility_first'
        $result.review_state.request.review_contract.source_task | Should -Be 'TASK-210'
        $result.review_state.request.review_contract.required_scope | Should -Be @('design_impact', 'replacement_coverage', 'orphaned_artifacts', 'pathspec_completeness')
        $result.run.Contains('run_packet') | Should -BeFalse
        $result.Contains('run_packet') | Should -Be $false
        $result.Contains('result_packet') | Should -Be $false
        $result.recent_events.Count | Should -Be 7
        @($result.recent_events | ForEach-Object { $_.event }) | Should -Contain 'operator.review_requested'
        @($result.recent_events | ForEach-Object { $_.event }) | Should -Contain 'operator.mailbox.message_received'
        @($result.recent_events | ForEach-Object { $_.event }) | Should -Contain 'pipeline.verify.partial'
        @($result.recent_events | ForEach-Object { $_.event }) | Should -Contain 'pipeline.security.allowed'
        @($result.recent_events | ForEach-Object { $_.event }) | Should -Contain 'pipeline.tdd.red'
        @($result.recent_events | ForEach-Object { $_.event }) | Should -Contain 'pane.approval_waiting'
        @($result.recent_events | ForEach-Object { $_.message }) | Should -Not -Contain 'unrelated task local note should stay out'
        ($result.recent_events | Where-Object { $_.event -eq 'operator.review_requested' } | Select-Object -First 1).hypothesis | Should -Be 'experiment packet should flow into explain'
        ($result.recent_events | Where-Object { $_.event -eq 'operator.review_requested' } | Select-Object -First 1).observation_pack.changed_files | Should -Contain 'scripts/winsmux-core.ps1'
        ($result.recent_events | Where-Object { $_.event -eq 'operator.review_requested' } | Select-Object -First 1).observation_pack.packet_type | Should -Be 'observation_pack'
        ($result.recent_events | Where-Object { $_.event -eq 'operator.review_requested' } | Select-Object -First 1).consultation_packet.kind | Should -Be 'consult_result'
    }

    It 'rejects explain when matching review-state record is missing reviewer' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        ([ordered]@{
            timestamp = '2026-04-10T12:01:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'operator.review_requested'
            message   = 'review requested'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id = 'task-256'
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:explainEventsPath -Encoding UTF8

@'
{
  "worktree-builder-1": {
    "status": "PENDING",
    "branch": "worktree-builder-1",
    "head_sha": "abc1234def5678",
    "request": {
      "branch": "worktree-builder-1",
      "head_sha": "abc1234def5678",
      "target_review_label": "reviewer-1",
      "target_review_pane_id": "%3",
      "target_review_role": "Reviewer",
      "review_contract": {
        "version": 1,
        "source_task": "TASK-210",
        "issue_ref": "#315",
        "style": "utility_first",
        "required_scope": [
          "design_impact",
          "replacement_coverage",
          "orphaned_artifacts",
          "pathspec_completeness"
        ]
      }
    },
    "updatedAt": "2026-04-10T12:01:00+09:00"
  }
}
'@ | Set-Content -Path $script:explainReviewStatePath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid review state*reviewer*'
    }

    It 'rejects explain when PASS review-state evidence is missing approved_via' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: done
    task_owner: builder-1
    review_state: PASS
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: review.pass
    last_event_at: 2026-04-10T12:10:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        ([ordered]@{
            timestamp = '2026-04-10T12:10:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'review.pass'
            message   = 'review PASS recorded'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id = 'task-256'
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:explainEventsPath -Encoding UTF8

@'
{
  "worktree-builder-1": {
    "status": "PASS",
    "branch": "worktree-builder-1",
    "head_sha": "abc1234def5678",
    "request": {
      "branch": "worktree-builder-1",
      "head_sha": "abc1234def5678",
      "target_review_label": "reviewer-1",
      "target_review_pane_id": "%3",
      "target_review_role": "Reviewer",
      "review_contract": {
        "version": 1,
        "source_task": "TASK-210",
        "issue_ref": "#315",
        "style": "utility_first",
        "required_scope": [
          "design_impact",
          "replacement_coverage",
          "orphaned_artifacts",
          "pathspec_completeness"
        ]
      }
    },
    "reviewer": {
      "pane_id": "%3",
      "label": "reviewer-1",
      "role": "Reviewer"
    },
    "updatedAt": "2026-04-10T12:10:00+09:00",
    "evidence": {
      "approved_at": "2026-04-10T12:10:00+09:00",
      "review_contract_snapshot": {
        "version": 1,
        "source_task": "TASK-210",
        "issue_ref": "#315",
        "style": "utility_first",
        "required_scope": [
          "design_impact",
          "replacement_coverage",
          "orphaned_artifacts",
          "pathspec_completeness"
        ]
      }
    }
  }
}
'@ | Set-Content -Path $script:explainReviewStatePath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid review state*approved_via*'
    }

    It 'rejects explain when manifest review_state is present without head_sha' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' review_state requires head_sha*'
    }

    It 'rejects explain when manifest changed_file_count is present without changed_files' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '[]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' changed_file_count requires changed_files*'
    }

    It 'rejects explain when manifest last_event is present without last_event_at' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' last_event requires last_event_at*'
    }

    It 'rejects explain when manifest planning metadata is missing parent_run_id' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    goal: Ship run contract primitives
    task_type: implementation
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    priority: P0
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' planning metadata requires parent_run_id*'
    }

    It 'rejects explain when manifest planning metadata is missing goal' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    parent_run_id: operator:session-1
    task: Implement run ledger
    task_type: implementation
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    priority: P0
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' planning metadata requires goal*'
    }

    It 'rejects explain when manifest planning metadata is missing task_type' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    parent_run_id: operator:session-1
    task: Implement run ledger
    goal: Ship run contract primitives
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    priority: P0
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' planning metadata requires task_type*'
    }

    It 'rejects explain when manifest planning metadata is missing priority' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    parent_run_id: operator:session-1
    task: Implement run ledger
    goal: Ship run contract primitives
    task_type: implementation
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' planning metadata requires priority*'
    }

    It 'keeps refs and returns null packets when artifact files are missing or malformed' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-777
    task: Explain missing packets
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 0
    changed_files: '[]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        $badConsultDir = Get-ConsultationDirectory -ProjectDir $script:explainTempRoot
        New-Item -ItemType Directory -Path $badConsultDir -Force | Out-Null
        Write-PsmuxBridgeTestFile -Path (Join-Path $badConsultDir 'consult-result-bad.json') -Content '{ nope }'

        ([ordered]@{
            timestamp = '2026-04-10T12:01:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'operator.review_requested'
            message   = 'review requested'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id              = 'task-777'
                hypothesis           = 'hydrate should be resilient'
                observation_pack_ref = '.winsmux/observation-packs/missing.json'
                consultation_ref     = '.winsmux/consultations/consult-result-bad.json'
                run_id               = 'task:task-777'
                slot                 = 'slot-builder-1'
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:explainEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Explain -ExplainTarget 'task:task-777' -ExplainRest @('--json') | Out-String | ConvertFrom-Json -AsHashtable)

        $result.run.experiment_packet.observation_pack_ref | Should -Be '.winsmux/observation-packs/missing.json'
        $result.run.experiment_packet.consultation_ref | Should -Be '.winsmux/consultations/consult-result-bad.json'
        $result.observation_pack | Should -Be $null
        $result.consultation_packet | Should -Be $null
        $result.Contains('consultation_summary') | Should -BeFalse
        $result.Contains('experiment_packet') | Should -BeFalse
    }

    It 'filters explain follow events from the current cursor forward' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        ([ordered]@{
            timestamp = '2026-04-10T12:01:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'operator.review_requested'
            message   = 'review requested'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id = 'task-256'
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:explainEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $payload = Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256'
        $cursor = @(Get-BridgeEventRecords -ProjectDir $script:explainTempRoot).Count

        @(
            ([ordered]@{
                timestamp = '2026-04-10T12:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.idle'
                message   = 'idle pane'
                label     = 'worker-1'
                pane_id   = '%6'
                role      = 'Worker'
                status    = 'ready'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T12:03:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.commit_ready'
                message   = 'commit ready'
                label     = ''
                pane_id   = ''
                role      = 'Operator'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                status    = 'commit_ready'
                data      = [ordered]@{
                    task_id              = 'task-256'
                    hypothesis           = 'follow path should keep experiment fields'
                    result               = 'ready to commit'
                    next_action          = 'commit_ready'
                    observation_pack_ref = '.winsmux/observation-packs/task-256.json'
                }
            } | ConvertTo-Json -Compress)
        ) | Add-Content -Path $script:explainEventsPath -Encoding UTF8

        $delta = Get-BridgeEventDelta -ProjectDir $script:explainTempRoot -Cursor $cursor
        $matching = @(
            $delta.events |
                Where-Object { Test-RunMatchesEventRecord -Run $payload.run -EventRecord $_ } |
                ForEach-Object { ConvertTo-RunEventRecord -EventRecord $_ }
        )

        $delta.cursor | Should -Be 3
        $matching.Count | Should -Be 1
        $matching[0].event | Should -Be 'operator.commit_ready'
        $matching[0].hypothesis | Should -Be 'follow path should keep experiment fields'
        $matching[0].next_action | Should -Be 'commit_ready'
        $matching[0].observation_pack_ref | Should -Be '.winsmux/observation-packs/task-256.json'
    }
}

Describe 'winsmux control-plane dispatch module' {
    BeforeAll {
        $script:winsmuxCoreDispatchRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreDispatchRawContent = Get-Content -Path $script:winsmuxCoreDispatchRawPath -Raw -Encoding UTF8
        $script:controlPlaneDispatchPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\control-plane-dispatch.ps1'
        $script:controlPlaneDispatchContent = Get-Content -Path $script:controlPlaneDispatchPath -Raw -Encoding UTF8
    }

    It 'loads the dispatch adapter module from the bridge script' {
        $script:winsmuxCoreDispatchRawContent | Should -Match 'control-plane-dispatch\.ps1'
        $script:winsmuxCoreDispatchRawContent | Should -Match '\. \$ControlPlaneDispatchScript'
    }

    It 'keeps external script adapter parsing outside the top-level command table' {
        $script:winsmuxCoreDispatchRawContent | Should -Match "'github-preflight'\s*\{\s*Invoke-WinsmuxGithubPreflightCommand"
        $script:winsmuxCoreDispatchRawContent | Should -Match "'dispatch-task'\s*\{\s*Invoke-WinsmuxDispatchTaskCommand"
        $script:winsmuxCoreDispatchRawContent | Should -Match "'task-split'\s*\{\s*Invoke-WinsmuxTaskSplitCommand"
        $script:winsmuxCoreDispatchRawContent | Should -Match "'builder-queue'\s*\{\s*Invoke-WinsmuxBuilderQueueCommand"
        $script:winsmuxCoreDispatchRawContent | Should -Match "'orchestra-smoke'\s*\{\s*Invoke-WinsmuxOrchestraSmokeCommand"
        $script:winsmuxCoreDispatchRawContent | Should -Match "'harness-check'\s*\{\s*Invoke-WinsmuxHarnessCheckCommand"
        $script:winsmuxCoreDispatchRawContent | Should -Match "'assign'\s*\{\s*Invoke-WinsmuxAssignCommand"
        $script:controlPlaneDispatchContent | Should -Match 'function Invoke-WinsmuxGithubPreflightCommand'
        $script:controlPlaneDispatchContent | Should -Match 'function Invoke-WinsmuxDispatchTaskCommand'
        $script:controlPlaneDispatchContent | Should -Match 'function Get-DispatchTaskAvailableTargets'
        $script:controlPlaneDispatchContent | Should -Match 'function Invoke-WinsmuxBuilderQueueCommand'
        $script:controlPlaneDispatchContent | Should -Match 'function Invoke-WinsmuxShadowCutoverGateCommand'
    }
}

Describe 'TASK-789 dispatch spawn and archive-pane' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $script:BridgeTestsRoot
        $script:task789DispatchPath = Join-Path $repoRoot 'winsmux-core\scripts\control-plane-dispatch.ps1'
        $script:task789DispatchContent = Get-Content -LiteralPath $script:task789DispatchPath -Raw -Encoding UTF8
        $script:task789WinsmuxCorePath = Join-Path $repoRoot 'scripts\winsmux-core.ps1'
        $script:task789WinsmuxCoreContent = Get-Content -LiteralPath $script:task789WinsmuxCorePath -Raw -Encoding UTF8
        $script:task789PaneScalerPath = Join-Path $repoRoot 'winsmux-core\scripts\pane-scaler.ps1'
        $script:task789PaneScalerContent = Get-Content -LiteralPath $script:task789PaneScalerPath -Raw -Encoding UTF8
        $script:task789ManifestPath = Join-Path $repoRoot 'winsmux-core\scripts\manifest.ps1'
        . $script:task789ManifestPath
        . $script:task789DispatchPath
        $script:task789SubmissionContractPath = Join-Path $repoRoot 'winsmux-core\scripts\submission-contract.ps1'
        if (Test-Path -LiteralPath $script:task789SubmissionContractPath -PathType Leaf) {
            . $script:task789SubmissionContractPath
        }
        $script:task789ScriptsRoot = Join-Path $repoRoot 'scripts'
        if (-not (Get-Command Stop-WithError -ErrorAction SilentlyContinue)) {
            function script:Stop-WithError {
                param([string]$Message)
                throw $Message
            }
        }
        if (-not (Get-Command Start-DeferredPaneFromManifestEntry -ErrorAction SilentlyContinue)) {
            function script:Start-DeferredPaneFromManifestEntry {
                param($ProjectDir, $ManifestEntry, $ExpectedGenerationId)
                return $false
            }
        }
        if (-not (Get-Command New-TeamProfileSlotAgentConfig -ErrorAction SilentlyContinue)) {
            function script:New-TeamProfileSlotAgentConfig {
                param($Role, $SlotId, $Assignment, $Settings, $RootPath)
            }
        }
        if (-not (Get-Command Invoke-TeamProfileLaunchProjection -ErrorAction SilentlyContinue)) {
            function script:Invoke-TeamProfileLaunchProjection {
                param($ProjectDir, $SessionId, $SlotId, $Worktree, $ReadWriteScope, [switch]$Force)
            }
        }
        if (-not (Get-Command Add-TeamProfileBundleToLaunchCommand -ErrorAction SilentlyContinue)) {
            function script:Add-TeamProfileBundleToLaunchCommand {
                param($LaunchCommand, $Projection, $ProjectDir)
                return $LaunchCommand
            }
        }
        if (-not (Get-Command New-OrchestraPaneBootstrapPlan -ErrorAction SilentlyContinue)) {
            function script:New-OrchestraPaneBootstrapPlan {
                param($ProjectDir, $PaneId, $Label, $SlotId, $Role, $WorkerBackend, $WorkerRole, $PaneTitle, $GenerationId, $ServerSessionId, $Agent, $Model, $StartupToken, $LaunchDir, $CleanPtyEnv, $LaunchCommand, $SupportsInterrupt, $ApprovedLaunch)
                throw 'New-OrchestraPaneBootstrapPlan not mocked'
            }
        }
        if (-not (Get-Command Get-OrchestraPaneBootstrapMarkerPath -ErrorAction SilentlyContinue)) {
            function script:Get-OrchestraPaneBootstrapMarkerPath {
                param($PlanPath, $GenerationId)
                throw 'Get-OrchestraPaneBootstrapMarkerPath not mocked'
            }
        }
        if (-not (Get-Command Start-OrchestraPaneBootstrap -ErrorAction SilentlyContinue)) {
            function script:Start-OrchestraPaneBootstrap {
                param($PaneId, $PlanPath, $SessionName)
                throw 'Start-OrchestraPaneBootstrap not mocked'
            }
        }
        if (-not (Get-Command Get-BridgeEventRecords -ErrorAction SilentlyContinue)) {
            function script:Get-BridgeEventRecords {
                param([string]$ProjectDir)
                return @()
            }
        }

        function script:Get-Task789SupervisorIdentity {
            $started = Get-WinsmuxRuntimeProcessStartedAt -ProcessId $PID
            if ([string]::IsNullOrWhiteSpace([string]$started)) {
                throw 'TASK-789 v2 fixture could not read the current process start time.'
            }
            return [pscustomobject]@{ Pid = [int]$PID; StartedAt = [string]$started }
        }

        function script:New-Task789V2Pane {
            param(
                [Parameter(Mandatory = $true)][string]$Label,
                [Parameter(Mandatory = $true)][string]$PaneId,
                [string]$Role = 'Worker',
                [string]$WorkerRole = 'worker',
                [string]$WorkerBackend = 'codex',
                [string]$Status = 'ready'
            )
            return [pscustomobject]@{
                Label         = $Label
                PaneId        = $PaneId
                Role          = $Role
                WorkerRole    = $WorkerRole
                WorkerBackend = $WorkerBackend
                Title         = $Label
                Status        = $Status
            }
        }

        function script:New-Task789V2RegistryPane {
            param(
                [Parameter(Mandatory = $true)][string]$Label,
                [Parameter(Mandatory = $true)][string]$PaneId,
                [string]$Backend = 'codex',
                [string]$Role = 'worker',
                [int]$BootstrapPid = 0,
                [string]$BootstrapStartedAt = '2026-08-17T00:00:01.0000000Z'
            )
            return [PSCustomObject]@{
                label                        = $Label
                slot_id                      = $Label
                pane_id                      = $PaneId
                backend                      = $Backend
                role                         = $Role
                title                        = $Label
                state                        = $(if ($BootstrapPid -gt 0) { 'live' } else { 'bootstrap_pending' })
                bootstrap_pid                = $BootstrapPid
                bootstrap_process_started_at = $(if ($BootstrapPid -gt 0) { $BootstrapStartedAt } else { '' })
                marker_path                  = ''
            }
        }

        function script:New-Task789ObservedPane {
            param(
                [Parameter(Mandatory = $true)][string]$PaneId,
                [Parameter(Mandatory = $true)][string]$Title,
                [string]$SessionId = '$9',
                [string]$SessionName = 'winsmux-orchestra'
            )
            return [pscustomobject]@{
                SessionId   = $SessionId
                SessionName = $SessionName
                PaneId      = $PaneId
                Title       = $Title
            }
        }

        function script:Write-Task789V2Manifest {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)][string]$ProjectDir,
                [Parameter(Mandatory = $true)][object[]]$Panes
            )
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add('version: 2') | Out-Null
            $lines.Add('saved_at: 2026-08-17T00:00:00Z') | Out-Null
            $lines.Add('session:') | Out-Null
            $lines.Add('  name: winsmux-orchestra') | Out-Null
            $lines.Add("  project_dir: $ProjectDir") | Out-Null
            $lines.Add('  generation_id: generation-789') | Out-Null
            $lines.Add("  server_session_id: '`$9'") | Out-Null
            $lines.Add("  bootstrap_pane_id: '%1'") | Out-Null
            $lines.Add(('  expected_pane_count: {0}' -f @($Panes).Count)) | Out-Null
            $lines.Add('panes:') | Out-Null
            foreach ($pane in @($Panes)) {
                $lines.Add(('  {0}:' -f $pane.Label)) | Out-Null
                $lines.Add(('    label: {0}' -f $pane.Label)) | Out-Null
                $lines.Add(('    slot_id: {0}' -f $pane.Label)) | Out-Null
                $lines.Add(("    pane_id: '{0}'" -f $pane.PaneId)) | Out-Null
                $lines.Add(('    role: {0}' -f $pane.Role)) | Out-Null
                $lines.Add(('    worker_role: {0}' -f $pane.WorkerRole)) | Out-Null
                $lines.Add(('    worker_backend: {0}' -f $pane.WorkerBackend)) | Out-Null
                $lines.Add(('    title: {0}' -f $pane.Title)) | Out-Null
                $lines.Add(('    status: {0}' -f $pane.Status)) | Out-Null
            }
            Set-Content -LiteralPath $Path -Value ($lines -join "`n") -Encoding utf8
        }

        function script:Get-Task789ObservedLines {
            return @(
                $script:task789Observed | ForEach-Object {
                    "{0}`t{1}`t{2}`t{3}" -f $_.SessionId, $_.SessionName, $_.PaneId, $_.Title
                }
            )
        }

        function script:Mock-Task789LiveServer {
            Mock Invoke-PaneControlWinsmux {
                param($Arguments)
                if (@($Arguments) -contains 'list-panes') {
                    return script:Get-Task789ObservedLines
                }
                throw ("unexpected pane-control winsmux: {0}" -f (@($Arguments) -join ' '))
            }
        }

        function script:New-Task789LiveEntry {
            param(
                [Parameter(Mandatory = $true)][string]$Label,
                [Parameter(Mandatory = $true)][string]$PaneId,
                [string]$Status = 'ready'
            )
            return [pscustomobject]@{
                Label         = $Label
                SlotId        = $Label
                PaneId        = $PaneId
                Role          = 'Worker'
                WorkerRole    = 'worker'
                WorkerBackend = 'codex'
                Title         = $Label
                Status        = $Status
            }
        }

        function script:Invoke-Task789PublicDispatchTask {
            param([Parameter(Mandatory = $true)][string[]]$Argv)
            $target = [string]$Argv[0]
            $rest = @()
            if ($Argv.Count -gt 1) {
                $rest = @($Argv[1..($Argv.Count - 1)])
            }
            return @(
                Invoke-WinsmuxDispatchTaskCommand -BridgeScriptRoot $script:task789ScriptsRoot `
                    -CommandTarget $target -CommandRest $rest
            )
        }
    }

    BeforeEach {
        $script:task789FixRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-task789-fix-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:task789FixRoot '.winsmux') -Force | Out-Null
        $script:task789Observed = @()
        $script:task789Killed = @()
        $script:task789AgentReadyProbes = 0
        $script:task789WorktreeRemoved = $false
    }

    AfterEach {
        if ($script:task789FixRoot -and (Test-Path -LiteralPath $script:task789FixRoot)) {
            Remove-Item -LiteralPath $script:task789FixRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'documents public archive-pane in usage and the command table' {
        $script:task789WinsmuxCoreContent | Should -Match 'archive-pane <slot>\s+'
        $script:task789WinsmuxCoreContent | Should -Match "'archive-pane'\s*\{\s*Invoke-WinsmuxArchivePaneCommand"
        $script:task789DispatchContent | Should -Match 'function Invoke-WinsmuxArchivePaneCommand'
    }

    It 'archives by interrupt-then-Remove-OrchestraPane and never calls workers-stop respawn' {
        $script:task789DispatchContent | Should -Match 'function Invoke-WinsmuxArchivePaneCommand'
        $archiveIndex = $script:task789DispatchContent.IndexOf('function Invoke-WinsmuxArchivePaneCommand')
        $archiveIndex | Should -BeGreaterThan -1
        $next = $script:task789DispatchContent.IndexOf("`nfunction ", $archiveIndex + 1)
        if ($next -lt 0) {
            $next = $script:task789DispatchContent.Length
        }
        $body = $script:task789DispatchContent.Substring($archiveIndex, $next - $archiveIndex)
        $body | Should -Match 'Remove-OrchestraPane'
        $body | Should -Match 'Get-WinsmuxArchivePaneRuntimeRefusal'
        $body | Should -Match 'C-c'
        $body | Should -Match 'pane\.idle'
        $body | Should -Match 'Get-PaneAgentStatus'
        $body.IndexOf('Get-WinsmuxArchivePaneRuntimeRefusal') | Should -BeLessThan $body.IndexOf('C-c')
        $script:task789DispatchContent | Should -Match "Operation stop_transition"
        $body | Should -Not -Match 'Invoke-WorkersStop'
        $body | Should -Not -Match 'respawn-pane'
        $body | Should -Not -Match 'workers stop'
        $script:task789PaneScalerContent | Should -Match 'kill-pane'
    }

    It 'spawns a missing live worker through Add-OrchestraPane and Team Profile assignment overlay' {
        $script:task789DispatchContent | Should -Match 'function Ensure-DispatchTaskLiveWorkerPane'
        $ensureIndex = $script:task789DispatchContent.IndexOf('function Ensure-DispatchTaskLiveWorkerPane')
        $ensureIndex | Should -BeGreaterThan -1
        $next = $script:task789DispatchContent.IndexOf("`nfunction ", $ensureIndex + 1)
        if ($next -lt 0) {
            $next = $script:task789DispatchContent.Length
        }
        $body = $script:task789DispatchContent.Substring($ensureIndex, $next - $ensureIndex)
        $body | Should -Match 'Add-OrchestraPane'
        $body | Should -Match 'New-TeamProfileSlotAgentConfig'
        $body | Should -Match 'Invoke-TeamProfileLaunchProjection'
        $body | Should -Match '-Projection \$projection'
        $body | Should -Match 'worker_backend'
        $body | Should -Not -Match 'requiredBackend'
        $body | Should -Match 'simple_mode_live_worker_limit'
        $body | Should -Match 'team_profile_projection_unavailable'
        $body | Should -Match 'team_profile_projection_mutated_live_manifest'
        $script:task789DispatchContent | Should -Match 'Ensure-DispatchTaskLiveWorkerPane'
        $script:task789DispatchContent | Should -Match 'function Get-DispatchTaskCatalogSlotIds'
        $script:task789DispatchContent | Should -Match 'function Get-DispatchTaskResolvedTeamSlots'
        $script:task789DispatchContent | Should -Match 'function Get-DispatchTaskMissingCatalogSlotIds'
        $catalogIndex = $script:task789DispatchContent.IndexOf('function Get-DispatchTaskCatalogSlotIds')
        $catalogIndex | Should -BeGreaterThan -1
        $catalogNext = $script:task789DispatchContent.IndexOf("`nfunction ", $catalogIndex + 1)
        if ($catalogNext -lt 0) {
            $catalogNext = $script:task789DispatchContent.Length
        }
        $catalogBody = $script:task789DispatchContent.Substring($catalogIndex, $catalogNext - $catalogIndex)
        $catalogBody | Should -Match 'Get-DispatchTaskResolvedTeamSlots'
        $catalogBody | Should -Not -Match 'Get-BridgeSettings'
        $resolveIndex = $script:task789DispatchContent.IndexOf('function Get-DispatchTaskResolvedTeamPayload')
        $resolveIndex | Should -BeGreaterThan -1
        $resolveNext = $script:task789DispatchContent.IndexOf("`nfunction ", $resolveIndex + 1)
        if ($resolveNext -lt 0) {
            $resolveNext = $script:task789DispatchContent.Length
        }
        $resolveBody = $script:task789DispatchContent.Substring($resolveIndex, $resolveNext - $resolveIndex)
        $resolveBody | Should -Match "--action', 'resolve'"
        $script:task789PaneScalerContent | Should -Match 'Add-TeamProfileBundleToLaunchCommand'
        $scalerIndex = $script:task789PaneScalerContent.IndexOf('function Add-OrchestraWorkerPane')
        $scalerIndex | Should -BeGreaterThan -1
        $scalerNext = $script:task789PaneScalerContent.IndexOf("`nfunction ", $scalerIndex + 1)
        if ($scalerNext -lt 0) {
            $scalerNext = $script:task789PaneScalerContent.Length
        }
        $scalerBody = $script:task789PaneScalerContent.Substring($scalerIndex, $scalerNext - $scalerIndex)
        $scalerBody.IndexOf('New-PaneScalerWorkerWorktree') | Should -BeLessThan $scalerBody.IndexOf('Invoke-TeamProfileLaunchProjection')
        $scalerBody | Should -Match '-Worktree \$worktree.WorktreePath'
        $script:task789DispatchContent | Should -Match 'Get-DispatchTaskAvailableTargets'
        $invokeIndex = $script:task789DispatchContent.IndexOf('function Invoke-WinsmuxDispatchTaskCommand')
        $invokeIndex | Should -BeGreaterThan -1
        $invokeNext = $script:task789DispatchContent.IndexOf("`nfunction ", $invokeIndex + 1)
        if ($invokeNext -lt 0) {
            $invokeNext = $script:task789DispatchContent.Length
        }
        $invokeBody = $script:task789DispatchContent.Substring($invokeIndex, $invokeNext - $invokeIndex)
        $invokeBody | Should -Match 'Get-DispatchRoute -Text \$taskText -AvailableTargets @\(\$classifiedSlotId\)'
        $invokeBody | Should -Match 'Get-DispatchTaskMissingCatalogSlotIds'
        $script:task789PaneScalerContent | Should -Match 'Add-TeamProfileBundleToLaunchCommand'
    }

    It 'fail-closes simple mode instead of spawning a second live worker pane' {
        Mock Get-OrchestraModeDocument {
            [pscustomobject]@{ schema_version = 1; mode = 'simple'; valid = $true; source = 'file' }
        }
        Mock Get-OrchestraLiveWorkerRolePaneCount { 1 }
        $result = Ensure-DispatchTaskLiveWorkerPane -ProjectDir (Join-Path ([System.IO.Path]::GetTempPath()) 'winsmux-task789-missing') -Label 'worker-2' -ManifestEntry $null
        $result.Spawned | Should -BeFalse
        $result.ReasonCode | Should -Be 'simple_mode_live_worker_limit'
    }

    It 'exposes Add-OrchestraPane after loading only control-plane-dispatch.ps1' {
        $probePath = Join-Path $script:task789FixRoot 'scope-probe.ps1'
        $dispatchPath = $script:task789DispatchPath
        $probe = @"
`$ErrorActionPreference = 'Stop'
if (Get-Command Add-OrchestraPane -ErrorAction SilentlyContinue) {
    throw 'Add-OrchestraPane already existed before dispatch load'
}
if (Get-Command New-TeamProfileSlotAgentConfig -ErrorAction SilentlyContinue) {
    throw 'orchestra-start.ps1 was pre-loaded'
}
. '$($dispatchPath.Replace("'", "''"))'
if (-not (Get-Command Add-OrchestraPane -ErrorAction SilentlyContinue)) {
    throw 'Add-OrchestraPane missing after dispatch load'
}
if (-not (Get-Command Remove-OrchestraPane -ErrorAction SilentlyContinue)) {
    throw 'Remove-OrchestraPane missing after dispatch load'
}
if (Get-Command New-TeamProfileSlotAgentConfig -ErrorAction SilentlyContinue) {
    throw 'Add-OrchestraPane must not depend on pre-loading orchestra-start.ps1'
}
`$null = Get-Command Ensure-DispatchTaskLiveWorkerPane -ErrorAction Stop
`$null = Get-Command Invoke-WinsmuxArchivePaneCommand -ErrorAction Stop
try {
    `$null = Ensure-DispatchTaskLiveWorkerPane -ProjectDir '$($script:task789FixRoot.Replace("'", "''"))' -Label 'worker-2' -ManifestEntry `$null
} catch {
    if (`$_.FullyQualifiedErrorId -eq 'CommandNotFoundException' -and [string]`$_.Exception.Message -match 'Add-OrchestraPane|Remove-OrchestraPane') {
        throw
    }
}
Write-Output 'ok'
"@
        Set-Content -LiteralPath $probePath -Value $probe -Encoding utf8
        $output = & pwsh -NoProfile -File $probePath 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) | Should -Match 'ok'
    }

    It 'transitions registry pane identities together with expected_pane_count' {
        $operatorPane = [PSCustomObject]@{
            label = 'operator'; slot_id = 'operator'; pane_id = '%2'; backend = 'local'
            role = 'operator'; title = 'Operator'; state = 'live'; bootstrap_pid = 4100
            bootstrap_process_started_at = '2026-08-17T00:00:00.0000000Z'; marker_path = ''
        }
        $worker1Pane = [PSCustomObject]@{
            label = 'worker-1'; slot_id = 'worker-1'; pane_id = '%3'; backend = 'codex'
            role = 'worker'; title = 'worker-1'; state = 'live'; bootstrap_pid = 4200
            bootstrap_process_started_at = '2026-08-17T00:00:01.0000000Z'; marker_path = ''
        }
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid 4100 `
            -SupervisorProcessStartedAt '2026-08-17T00:00:00.0000000Z' -ExpectedPaneCount 2 `
            -Panes @($operatorPane, $worker1Pane)
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null

        $manifest = [pscustomobject]@{
            Session = [pscustomobject]@{ expected_pane_count = 2 }
            Panes   = [ordered]@{
                'operator' = [pscustomobject]@{
                    slot_id = 'operator'; pane_id = '%2'; role = 'Operator'
                    worker_role = 'operator'; worker_backend = 'local'; title = 'Operator'
                }
                'worker-1' = [pscustomobject]@{
                    slot_id = 'worker-1'; pane_id = '%3'; role = 'Worker'
                    worker_role = 'worker'; worker_backend = 'codex'; title = 'worker-1'
                }
                'worker-2' = [pscustomobject]@{
                    slot_id = 'worker-2'; pane_id = '%4'; role = 'Worker'
                    worker_role = 'worker'; worker_backend = 'codex'; title = 'worker-2'
                }
            }
        }

        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        @"
version: 1
saved_at: 2026-08-17T00:00:00Z
session:
  name: winsmux-orchestra
  project_dir: $script:task789FixRoot
  expected_pane_count: 2
panes:
  operator:
    slot_id: operator
    pane_id: '%2'
    role: Operator
  worker-1:
    slot_id: worker-1
    pane_id: '%3'
    role: Worker
"@ | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $manifest | Add-Member -NotePropertyName 'version' -NotePropertyValue 1 -Force
        $count = Save-OrchestraLivePaneSetTransition -ManifestPath $manifestPath -Manifest $manifest -ProjectDir $script:task789FixRoot
        $count | Should -Be 3
        $manifest.Session.expected_pane_count | Should -Be 3

        $read = Read-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot
        $read.expected_pane_count | Should -Be 3
        @($read.panes).Count | Should -Be 3
        @($read.panes | ForEach-Object { [string]$_.label }) | Should -Be @('operator', 'worker-1', 'worker-2')
        ($read.panes | Where-Object { $_.label -eq 'worker-2' }).pane_id | Should -Be '%4'
        $saved = Read-PaneScalerManifest -ManifestPath $manifestPath
        @($saved.Panes.Keys) | Should -Be @('operator', 'worker-1', 'worker-2')
    }

    It 'does not clamp an empty pane set to expected_pane_count 1' {
        $workerPane = [PSCustomObject]@{
            label = 'worker-1'; slot_id = 'worker-1'; pane_id = '%3'; backend = 'codex'
            role = 'worker'; title = 'worker-1'; state = 'live'; bootstrap_pid = 4200
            bootstrap_process_started_at = '2026-08-17T00:00:01.0000000Z'; marker_path = ''
        }
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid 4100 `
            -SupervisorProcessStartedAt '2026-08-17T00:00:00.0000000Z' -ExpectedPaneCount 1 `
            -Panes @($workerPane)
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null

        $manifest = [pscustomobject]@{
            Session = [pscustomobject]@{ expected_pane_count = 1 }
            Panes   = [ordered]@{}
        }
        { Update-PaneScalerLiveExpectedPaneCount -Manifest $manifest -ProjectDir $script:task789FixRoot } |
            Should -Throw '*1 or greater*'

        $read = Read-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot
        $read.expected_pane_count | Should -Be 1
        @($read.panes).Count | Should -Be 1
        $read.panes[0].label | Should -Be 'worker-1'
    }

    It 'rejects operator and a non-worker label without mutating the session' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $yaml = @"
version: 1
saved_at: 2026-08-17T00:00:00Z
session:
  name: winsmux-orchestra
  project_dir: $script:task789FixRoot
  generation_id: generation-789
  server_session_id: '`$9'
  bootstrap_pane_id: '%1'
  expected_pane_count: 3
panes:
  operator:
    label: operator
    slot_id: operator
    pane_id: '%2'
    role: Operator
    worker_role: operator
    worker_backend: local
    title: Operator
    status: ready
  reviewer:
    label: reviewer
    slot_id: reviewer
    pane_id: '%4'
    role: Reviewer
    worker_role: reviewer
    worker_backend: local
    title: Reviewer
    status: ready
  worker-1:
    label: worker-1
    slot_id: worker-1
    pane_id: '%3'
    role: Worker
    worker_role: worker
    worker_backend: codex
    title: worker-1
    status: ready
"@
        Set-Content -LiteralPath $manifestPath -Value $yaml -Encoding utf8
        $registryPath = Get-WinsmuxRuntimeRegistryPath -ProjectDir $script:task789FixRoot
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid 4100 `
            -SupervisorProcessStartedAt '2026-08-17T00:00:00.0000000Z' -ExpectedPaneCount 3 `
            -Panes @(
                [PSCustomObject]@{ label = 'operator'; slot_id = 'operator'; pane_id = '%2'; backend = 'local'; role = 'operator'; title = 'Operator'; state = 'live'; bootstrap_pid = 0; bootstrap_process_started_at = ''; marker_path = '' },
                [PSCustomObject]@{ label = 'reviewer'; slot_id = 'reviewer'; pane_id = '%4'; backend = 'local'; role = 'reviewer'; title = 'Reviewer'; state = 'live'; bootstrap_pid = 0; bootstrap_process_started_at = ''; marker_path = '' },
                [PSCustomObject]@{ label = 'worker-1'; slot_id = 'worker-1'; pane_id = '%3'; backend = 'codex'; role = 'worker'; title = 'worker-1'; state = 'live'; bootstrap_pid = 0; bootstrap_process_started_at = ''; marker_path = '' }
            )
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null
        $beforeManifest = [System.IO.File]::ReadAllBytes($manifestPath)
        $beforeRegistry = [System.IO.File]::ReadAllBytes($registryPath)

        Mock Invoke-MonitorWinsmux { throw 'kill-pane must not run for a non-worker archive' }

        foreach ($label in @('operator', 'reviewer')) {
            $result = Remove-OrchestraWorkerPane -ManifestPath $manifestPath -Label $label
            $result.Changed | Should -BeFalse
            $result.Reason | Should -Be 'archive_role_not_worker'

            $entry = [pscustomobject]@{ Label = $label; Role = $label; PaneId = '%2' }
            $refusal = Get-WinsmuxArchivePaneRefusal -Entry $entry -Label $label -Manifest (Read-PaneScalerManifest -ManifestPath $manifestPath)
            $refusal.ReasonCode | Should -Be 'archive_role_not_worker'
        }

        [System.IO.File]::ReadAllBytes($manifestPath) | Should -Be $beforeManifest
        [System.IO.File]::ReadAllBytes($registryPath) | Should -Be $beforeRegistry
        Should -Invoke Invoke-MonitorWinsmux -Times 0
    }

    It 'refuses to archive the last required worker without mutating the session' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $yaml = @"
version: 1
saved_at: 2026-08-17T00:00:00Z
session:
  name: winsmux-orchestra
  project_dir: $script:task789FixRoot
  generation_id: generation-789
  server_session_id: '`$9'
  bootstrap_pane_id: '%1'
  expected_pane_count: 1
panes:
  worker-1:
    label: worker-1
    slot_id: worker-1
    pane_id: '%3'
    role: Worker
    worker_role: worker
    worker_backend: codex
    title: worker-1
    status: ready
"@
        Set-Content -LiteralPath $manifestPath -Value $yaml -Encoding utf8
        $registryPath = Get-WinsmuxRuntimeRegistryPath -ProjectDir $script:task789FixRoot
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid 4100 `
            -SupervisorProcessStartedAt '2026-08-17T00:00:00.0000000Z' -ExpectedPaneCount 1 `
            -Panes @(
                [PSCustomObject]@{ label = 'worker-1'; slot_id = 'worker-1'; pane_id = '%3'; backend = 'codex'; role = 'worker'; title = 'worker-1'; state = 'live'; bootstrap_pid = 0; bootstrap_process_started_at = ''; marker_path = '' }
            )
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null
        $beforeManifest = [System.IO.File]::ReadAllBytes($manifestPath)
        $beforeRegistry = [System.IO.File]::ReadAllBytes($registryPath)

        Mock Invoke-MonitorWinsmux { throw 'kill-pane must not run for the last required worker' }

        $result = Remove-OrchestraWorkerPane -ManifestPath $manifestPath -Label 'worker-1'
        $result.Changed | Should -BeFalse
        $result.Reason | Should -Be 'last_required_worker'

        $entry = [pscustomobject]@{ Label = 'worker-1'; Role = 'Worker'; PaneId = '%3' }
        $refusal = Get-WinsmuxArchivePaneRefusal -Entry $entry -Label 'worker-1' -Manifest (Read-PaneScalerManifest -ManifestPath $manifestPath)
        $refusal.ReasonCode | Should -Be 'last_required_worker'

        [System.IO.File]::ReadAllBytes($manifestPath) | Should -Be $beforeManifest
        [System.IO.File]::ReadAllBytes($registryPath) | Should -Be $beforeRegistry
        Should -Invoke Invoke-MonitorWinsmux -Times 0
    }

    It 'fail-closes spawn when Team Profile projection <Case>' -ForEach @(
        @{ Case = 'mistyped_slot'; ProjectionError = "Team Profile launch projection failed for slot 'worker-99': unknown slot" }
        @{ Case = 'invalid_profile'; ProjectionError = "Team Profile launch projection failed for slot 'worker-2': invalid profile" }
        @{ Case = 'bridge_error'; ProjectionError = "Team Profile launch projection failed for slot 'worker-2': winsmux binary was not found." }
    ) {
        $script:task789ProjectionError = $ProjectionError
        Mock Get-OrchestraModeDocument {
            [pscustomobject]@{ schema_version = 1; mode = 'team'; valid = $true; source = 'file' }
        }
        Mock Get-OrchestraLiveWorkerRolePaneCount { 1 }
        Mock Get-BridgeSettings { $null }
        Mock Get-WinsmuxManifest { $null }
        Mock Invoke-TeamProfileLaunchProjection { throw $script:task789ProjectionError }
        Mock Add-OrchestraPane { throw 'should not spawn an unconfigured worker' }

        $result = Ensure-DispatchTaskLiveWorkerPane -ProjectDir $script:task789FixRoot -Label 'worker-2' -ManifestEntry $null
        $result.Spawned | Should -BeFalse
        $result.ReasonCode | Should -Be 'team_profile_projection_unavailable'
        $result.Diagnostic | Should -Be $ProjectionError
        Should -Invoke Add-OrchestraPane -Times 0
    }

    It 'E10 fail-closes spawn when Team Profile projection mutates the live manifest' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $original = "version: 1`nsession:`n  name: keep`npanes: {}`n"
        [System.IO.File]::WriteAllText($manifestPath, $original)
        $before = [System.IO.File]::ReadAllBytes($manifestPath)
        Mock Get-OrchestraModeDocument {
            [pscustomobject]@{ schema_version = 1; mode = 'team'; valid = $true; source = 'file' }
        }
        Mock Get-OrchestraLiveWorkerRolePaneCount { 1 }
        Mock Get-OrchestraMaxLiveWorkerPaneCount { 6 }
        Mock Get-BridgeSettings { $null }
        Mock Get-WinsmuxManifest { $null }
        Mock Invoke-TeamProfileLaunchProjection {
            [System.IO.File]::AppendAllText($manifestPath, "session:`n  team_profile:`n    preset: leaked`n")
            [pscustomobject]@{
                bundle_path = '.winsmux/runtime/prompt-bundles/sess/worker-2.md'
                projection  = [pscustomobject]@{
                    pane = [pscustomobject]@{
                        assignment = [pscustomobject]@{ provider = 'codex'; worker_backend = 'codex' }
                    }
                }
            }
        }
        Mock Add-OrchestraPane { throw 'E10 must not spawn after live manifest mutation' }

        $result = Ensure-DispatchTaskLiveWorkerPane -ProjectDir $script:task789FixRoot -Label 'worker-2' -ManifestEntry $null
        $result.Spawned | Should -BeFalse
        $result.ReasonCode | Should -Be 'team_profile_projection_mutated_live_manifest'
        Should -Invoke Add-OrchestraPane -Times 0
        [System.IO.File]::ReadAllBytes($manifestPath) | Should -Be $before
    }

    It 'E10 continues spawn when Team Profile projection leaves live pane-set files unchanged' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        [System.IO.File]::WriteAllText($manifestPath, "version: 1`nsession:`n  name: keep`npanes: {}`n")
        $before = [System.IO.File]::ReadAllBytes($manifestPath)
        Mock Get-OrchestraModeDocument {
            [pscustomobject]@{ schema_version = 1; mode = 'team'; valid = $true; source = 'file' }
        }
        Mock Get-OrchestraLiveWorkerRolePaneCount { 1 }
        Mock Get-OrchestraMaxLiveWorkerPaneCount { 6 }
        Mock Get-BridgeSettings { $null }
        Mock Get-WinsmuxManifest { $null }
        Mock Invoke-TeamProfileLaunchProjection {
            [pscustomobject]@{
                bundle_path = '.winsmux/runtime/prompt-bundles/sess/worker-2.md'
                projection  = [pscustomobject]@{
                    pane = [pscustomobject]@{
                        assignment = [pscustomobject]@{ provider = 'codex'; worker_backend = 'codex' }
                    }
                }
            }
        }
        Mock New-TeamProfileSlotAgentConfig {
            [pscustomobject]@{ Agent = 'codex'; Model = 'gpt-5.4'; WorkerBackend = 'codex'; PaneTitle = $SlotId }
        }
        Mock Add-OrchestraPane {
            return [pscustomobject]@{ Changed = $true; Label = $SlotId; PaneId = '%5' }
        }
        Mock Get-DispatchTaskManifestEntry {
            script:New-Task789LiveEntry -Label 'worker-2' -PaneId '%5'
        }

        $result = Ensure-DispatchTaskLiveWorkerPane -ProjectDir $script:task789FixRoot -Label 'worker-2' -ManifestEntry $null
        $result.Spawned | Should -BeTrue
        Should -Invoke Add-OrchestraPane -Times 1
        [System.IO.File]::ReadAllBytes($manifestPath) | Should -Be $before
    }

    It 'does not publish a new registry when the guarded manifest save fails' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $registryPath = Get-WinsmuxRuntimeRegistryPath -ProjectDir $script:task789FixRoot
        $supervisor = script:Get-Task789SupervisorIdentity
        script:Write-Task789V2Manifest -Path $manifestPath -ProjectDir $script:task789FixRoot -Panes @(
            script:New-Task789V2Pane -Label 'worker-1' -PaneId '%3'
        )
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid $supervisor.Pid `
            -SupervisorProcessStartedAt $supervisor.StartedAt -ExpectedPaneCount 1 -LeaseSeconds 300 `
            -Panes @(script:New-Task789V2RegistryPane -Label 'worker-1' -PaneId '%3' -BootstrapPid 4200)
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null
        $beforeRegistry = [System.IO.File]::ReadAllBytes($registryPath)
        $beforeManifest = [System.IO.File]::ReadAllBytes($manifestPath)

        $manifest = Read-PaneScalerManifest -ManifestPath $manifestPath
        $manifest.Panes['worker-2'] = [pscustomobject]@{
            slot_id = 'worker-2'; pane_id = '%4'; role = 'Worker'; worker_role = 'worker'
            worker_backend = 'codex'; title = 'worker-2'; status = 'ready'
        }
        $script:task789Observed = @(
            script:New-Task789ObservedPane -PaneId '%1' -Title 'bootstrap'
            script:New-Task789ObservedPane -PaneId '%3' -Title 'worker-1'
            script:New-Task789ObservedPane -PaneId '%4' -Title 'worker-2'
        )
        script:Mock-Task789LiveServer
        Mock Save-PaneScalerManifest { throw 'injected manifest save failure' }
        Mock Save-WinsmuxRuntimeRegistry { throw 'registry must not publish after a failed manifest save' }

        { Save-OrchestraLivePaneSetTransition -ManifestPath $manifestPath -Manifest $manifest -ProjectDir $script:task789FixRoot -ExpectedGenerationId 'generation-789' -RuntimePaneId '%3' } |
            Should -Throw '*injected manifest save failure*'

        [System.IO.File]::ReadAllBytes($registryPath) | Should -Be $beforeRegistry
        [System.IO.File]::ReadAllBytes($manifestPath) | Should -Be $beforeManifest
        Should -Invoke Save-WinsmuxRuntimeRegistry -Times 0
    }

    It 'rolls both halves back when registry save fails after the new manifest is written' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $registryPath = Get-WinsmuxRuntimeRegistryPath -ProjectDir $script:task789FixRoot
        $oldYaml = "version: 1`nsession:`n  name: old`npanes:`n  worker-1:`n    pane_id: '%3'`n"
        Set-Content -LiteralPath $manifestPath -Value $oldYaml -Encoding utf8
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid 4100 `
            -SupervisorProcessStartedAt '2026-08-17T00:00:00.0000000Z' -ExpectedPaneCount 1 `
            -Panes @(
                [PSCustomObject]@{ label = 'worker-1'; slot_id = 'worker-1'; pane_id = '%3'; backend = 'codex'; role = 'worker'; title = 'worker-1'; state = 'live'; bootstrap_pid = 4200; bootstrap_process_started_at = '2026-08-17T00:00:01.0000000Z'; marker_path = '' }
            )
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null
        $beforeRegistry = [System.IO.File]::ReadAllBytes($registryPath)
        $beforeManifest = [System.IO.File]::ReadAllBytes($manifestPath)

        $manifest = [pscustomobject]@{
            version = 1
            Session = [pscustomobject]@{ expected_pane_count = 1 }
            Panes   = [ordered]@{
                'worker-1' = [pscustomobject]@{ slot_id = 'worker-1'; pane_id = '%3'; role = 'Worker'; worker_role = 'worker'; worker_backend = 'codex'; title = 'worker-1' }
                'worker-2' = [pscustomobject]@{ slot_id = 'worker-2'; pane_id = '%4'; role = 'Worker'; worker_role = 'worker'; worker_backend = 'codex'; title = 'worker-2' }
            }
        }
        Mock Save-PaneScalerManifest {
            [System.IO.File]::WriteAllText($ManifestPath, 'NEW-HALF-PUBLISHED-MANIFEST')
        }
        Mock Save-WinsmuxRuntimeRegistry { throw 'injected registry save failure' }

        { Save-OrchestraLivePaneSetTransition -ManifestPath $manifestPath -Manifest $manifest -ProjectDir $script:task789FixRoot } |
            Should -Throw '*injected registry save failure*'

        [System.IO.File]::ReadAllBytes($manifestPath) | Should -Be $beforeManifest
        [System.IO.File]::ReadAllBytes($registryPath) | Should -Be $beforeRegistry
    }

    It 'does not expose a spawned worker as ready without a bootstrap marker identity' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        @"
version: 1
saved_at: 2026-08-17T00:00:00Z
session:
  name: winsmux-orchestra
  project_dir: $script:task789FixRoot
  generation_id: generation-789
  server_session_id: '`$9'
  bootstrap_pane_id: '%1'
  expected_pane_count: 1
panes:
  worker-1:
    slot_id: worker-1
    pane_id: '%3'
    role: Worker
    worker_role: worker
    worker_backend: codex
    title: worker-1
    status: ready
"@ | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $worktreePath = Join-Path $script:task789FixRoot '.worktrees\worker-2'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        Mock New-PaneScalerWorkerWorktree {
            [pscustomobject]@{ WorktreePath = $worktreePath; BranchName = 'worktree-worker-2'; GitWorktreeDir = $worktreePath }
        }
        Mock Invoke-MonitorWinsmux {
            param($Arguments)
            if (@($Arguments) -contains 'split-window') { return '%5' }
        }
        Mock Wait-MonitorPaneShellReady { }
        Mock Send-MonitorBridgeCommand { throw 'direct launch must not replace orchestra bootstrap' }
        Mock Get-PaneScalerLaunchCommand { 'echo spawn-worker-2' }
        Mock New-OrchestraPaneBootstrapPlan {
            $planDir = Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap'
            New-Item -ItemType Directory -Path $planDir -Force | Out-Null
            $planPath = Join-Path $planDir '5.json'
            Set-Content -LiteralPath $planPath -Value '{}' -Encoding utf8
            return $planPath
        }
        Mock Get-OrchestraPaneBootstrapMarkerPath {
            Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap\5-generation-789.ready.json'
        }
        Mock Start-OrchestraPaneBootstrap { }
        Mock Get-BridgeSettings { [ordered]@{ agent = 'codex'; model = 'gpt-5.4' } }

        $result = Add-OrchestraWorkerPane -ManifestPath $manifestPath -SlotId 'worker-2' -SlotAgentConfig ([pscustomobject]@{
            Agent = 'codex'; Model = 'gpt-5.4'; WorkerBackend = 'codex'; PaneTitle = 'worker-2'
        })
        $result.Changed | Should -BeTrue
        $saved = Read-PaneScalerManifest -ManifestPath $manifestPath
        $saved.Panes['worker-2'].status | Should -Be 'deferred_starting'
        $readyRaw = $saved.Panes['worker-2'].runtime_ready
        ($readyRaw -eq $true -or [string]$readyRaw -ceq 'true') | Should -BeFalse
        [string]$saved.Panes['worker-2'].bootstrap_marker_path | Should -Match '5-generation-789\.ready\.json'
        Should -Invoke Send-MonitorBridgeCommand -Times 0
        Should -Invoke Start-OrchestraPaneBootstrap -Times 1

        $dispatchCheck = Test-WinsmuxRuntimeContext -Manifest ([pscustomobject]@{
            version = 2
            session = [pscustomobject]@{
                name = 'winsmux-orchestra'; generation_id = 'generation-789'
                server_session_id = '$9'; bootstrap_pane_id = '%1'; expected_pane_count = 2
            }
            panes = [ordered]@{
                'worker-1' = [ordered]@{ slot_id = 'worker-1'; pane_id = '%3'; worker_backend = 'codex'; worker_role = 'worker'; role = 'Worker'; title = 'worker-1'; status = 'ready' }
                'worker-2' = [ordered]@{ slot_id = 'worker-2'; pane_id = '%5'; worker_backend = 'codex'; worker_role = 'worker'; role = 'Worker'; title = 'worker-2'; status = 'ready' }
            }
        }) -Registry ([pscustomobject]@{
            schema_version = 1; status = 'active'; session_name = 'winsmux-orchestra'
            generation_id = 'generation-789'; server_session_id = '$9'; bootstrap_pane_id = '%1'
            expected_pane_count = 2
            supervisor = [pscustomobject]@{ pid = 4100; process_started_at = '2026-08-17T00:00:00.0000000Z' }
            lease = [pscustomobject]@{ state = 'active'; expires_at = '2099-01-01T00:00:00.0000000Z' }
            panes = @(
                [pscustomobject]@{ label = 'worker-1'; slot_id = 'worker-1'; pane_id = '%3'; backend = 'codex'; role = 'worker'; title = 'worker-1'; state = 'live'; bootstrap_pid = 4200; bootstrap_process_started_at = '2026-08-17T00:00:01.0000000Z' }
                [pscustomobject]@{ label = 'worker-2'; slot_id = 'worker-2'; pane_id = '%5'; backend = 'codex'; role = 'worker'; title = 'worker-2'; state = 'live'; bootstrap_pid = 0; bootstrap_process_started_at = '' }
            )
        }) -ObservedServerSessionId '$9' -ObservedPanes @(
            [pscustomobject]@{ pane_id = '%1'; title = 'bootstrap' }
            [pscustomobject]@{ pane_id = '%3'; title = 'worker-1' }
            [pscustomobject]@{ pane_id = '%5'; title = 'worker-2' }
        ) -ManifestEntry ([pscustomobject]@{
            Label = 'worker-2'; SlotId = 'worker-2'; PaneId = '%5'; WorkerBackend = 'codex'
            WorkerRole = 'worker'; Role = 'Worker'; Title = 'worker-2'; Status = 'ready'
        }) -PaneMarker $null -ProcessResolver {
            param([int]$Id)
            if ($Id -eq 4100) {
                return [PSCustomObject]@{ Id = 4100; StartTime = [datetime]'2026-08-17T00:00:00Z'; ParentProcessId = 1; Name = 'pwsh.exe' }
            }
            return $null
        } -Operation dispatch -Now ([datetime]'2026-08-17T00:05:00Z')
        $dispatchCheck.valid | Should -BeFalse
        $dispatchCheck.reason_code | Should -Be 'runtime_target_mismatch'
    }

    It 'lets dispatch runtime succeed after a spawned worker persists bootstrap marker identity' {
        $markerDir = Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap'
        New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
        $markerPath = Join-Path $markerDir '5-generation-789.ready.json'
        $startedAt = '2026-08-17T00:00:02.0000000Z'
        @{
            state = 'bootstrap_pending'
            generation_id = 'generation-789'
            server_session_id = '$9'
            slot_id = 'worker-2'
            pane_id = '%5'
            backend = 'codex'
            role = 'worker'
            title = 'worker-2'
            bootstrap_pid = 4300
            bootstrap_process_started_at = $startedAt
        } | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding utf8

        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        @"
version: 1
saved_at: 2026-08-17T00:00:00Z
session:
  name: winsmux-orchestra
  project_dir: $script:task789FixRoot
  generation_id: generation-789
  server_session_id: '`$9'
  bootstrap_pane_id: '%1'
  expected_pane_count: 1
panes:
  worker-1:
    slot_id: worker-1
    pane_id: '%3'
    role: Worker
    worker_role: worker
    worker_backend: codex
    title: worker-1
    status: ready
"@ | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $worktreePath = Join-Path $script:task789FixRoot '.worktrees\worker-2'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        Mock New-PaneScalerWorkerWorktree {
            [pscustomobject]@{ WorktreePath = $worktreePath; BranchName = 'worktree-worker-2'; GitWorktreeDir = $worktreePath }
        }
        Mock Invoke-MonitorWinsmux {
            param($Arguments)
            if (@($Arguments) -contains 'split-window') { return '%5' }
            if (@($Arguments) -contains 'capture-pane') {
                $script:task789AgentReadyProbes++
                return '>'
            }
        }
        Mock Wait-MonitorPaneShellReady { }
        Mock Get-PaneScalerLaunchCommand { 'echo spawn-worker-2' }
        Mock New-OrchestraPaneBootstrapPlan {
            Join-Path $markerDir '5.json'
        }
        Mock Get-OrchestraPaneBootstrapMarkerPath { $markerPath }
        Mock Start-OrchestraPaneBootstrap { }
        Mock Get-BridgeSettings { [ordered]@{ agent = 'codex'; model = 'gpt-5.4' } }

        $null = Add-OrchestraWorkerPane -ManifestPath $manifestPath -SlotId 'worker-2' -SlotAgentConfig ([pscustomobject]@{
            Agent = 'codex'; Model = 'gpt-5.4'; WorkerBackend = 'codex'; PaneTitle = 'worker-2'
        })
        $saved = Read-PaneScalerManifest -ManifestPath $manifestPath
        $saved.Panes['worker-2'].status | Should -Be 'ready'
        [bool]$saved.Panes['worker-2'].runtime_ready | Should -BeTrue
        [string]$saved.Panes['worker-2'].bootstrap_marker_path | Should -Be $markerPath
        $script:task789AgentReadyProbes | Should -BeGreaterThan 0

        $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $processResolver = {
            param([int]$Id)
            switch ($Id) {
                4100 { return [PSCustomObject]@{ Id = 4100; StartTime = [datetime]'2026-08-17T00:00:00Z'; ParentProcessId = 1; Name = 'pwsh.exe' } }
                4300 { return [PSCustomObject]@{ Id = 4300; StartTime = [datetime]'2026-08-17T00:00:02Z'; ParentProcessId = 1; Name = 'pwsh.exe' } }
                default { return $null }
            }
        }
        $dispatchCheck = Test-WinsmuxRuntimeContext -Manifest ([pscustomobject]@{
            version = 2
            session = [pscustomobject]@{
                name = 'winsmux-orchestra'; generation_id = 'generation-789'
                server_session_id = '$9'; bootstrap_pane_id = '%1'; expected_pane_count = 2
            }
            panes = [ordered]@{
                'worker-1' = [ordered]@{ slot_id = 'worker-1'; pane_id = '%3'; worker_backend = 'codex'; worker_role = 'worker'; role = 'Worker'; title = 'worker-1'; status = 'ready' }
                'worker-2' = [ordered]@{ slot_id = 'worker-2'; pane_id = '%5'; worker_backend = 'codex'; worker_role = 'worker'; role = 'Worker'; title = 'worker-2'; status = 'ready' }
            }
        }) -Registry ([pscustomobject]@{
            schema_version = 1; status = 'active'; session_name = 'winsmux-orchestra'
            generation_id = 'generation-789'; server_session_id = '$9'; bootstrap_pane_id = '%1'
            expected_pane_count = 2
            supervisor = [pscustomobject]@{ pid = 4100; process_started_at = '2026-08-17T00:00:00.0000000Z' }
            lease = [pscustomobject]@{ state = 'active'; expires_at = '2099-01-01T00:00:00.0000000Z' }
            panes = @(
                [pscustomobject]@{ label = 'worker-1'; slot_id = 'worker-1'; pane_id = '%3'; backend = 'codex'; role = 'worker'; title = 'worker-1'; state = 'live'; bootstrap_pid = 4200; bootstrap_process_started_at = '2026-08-17T00:00:01.0000000Z' }
                [pscustomobject]@{ label = 'worker-2'; slot_id = 'worker-2'; pane_id = '%5'; backend = 'codex'; role = 'worker'; title = 'worker-2'; state = 'live'; bootstrap_pid = 4300; bootstrap_process_started_at = $startedAt }
            )
        }) -ObservedServerSessionId '$9' -ObservedPanes @(
            [pscustomobject]@{ pane_id = '%1'; title = 'bootstrap' }
            [pscustomobject]@{ pane_id = '%3'; title = 'worker-1' }
            [pscustomobject]@{ pane_id = '%5'; title = 'worker-2' }
        ) -ManifestEntry ([pscustomobject]@{
            Label = 'worker-2'; SlotId = 'worker-2'; PaneId = '%5'; WorkerBackend = 'codex'
            WorkerRole = 'worker'; Role = 'Worker'; Title = 'worker-2'; Status = 'ready'
            BootstrapMarkerPath = $markerPath
        }) -PaneMarker $marker -ProcessResolver $processResolver -Operation dispatch -Now ([datetime]'2026-08-17T00:05:00Z')
        $dispatchCheck.valid | Should -BeTrue
        $dispatchCheck.reason_code | Should -Be 'live_runtime_verified'
    }

    It 'does not send C-c when archive runtime ownership is unverified' {
        $entry = [pscustomobject]@{
            Label = 'worker-2'; SlotId = 'worker-2'; PaneId = '%9'; Role = 'Worker'
            WorkerRole = 'worker'; WorkerBackend = 'codex'; Title = 'worker-2'; Status = 'busy'
        }
        if (-not (Get-Command Invoke-WinsmuxRaw -ErrorAction SilentlyContinue)) {
            function script:Invoke-WinsmuxRaw { param($Arguments) }
        }
        if (-not (Get-Command Invoke-MonitorWinsmux -ErrorAction SilentlyContinue)) {
            function script:Invoke-MonitorWinsmux { param($Arguments) }
        }
        Mock Test-PaneControlRuntimeContext {
            [pscustomobject]@{
                valid = $false
                reason_code = 'runtime_target_mismatch'
                diagnostic = 'stale project-dir or unverified pane id'
            }
        }
        Mock Invoke-WinsmuxRaw { throw 'C-c must not run after a failed runtime check' }
        Mock Invoke-MonitorWinsmux { throw 'C-c must not run after a failed runtime check' }

        $refusal = Get-WinsmuxArchivePaneRuntimeRefusal -ProjectDir $script:task789FixRoot -Entry $entry
        $refusal.ReasonCode | Should -Be 'runtime_target_mismatch'
        $refusal.Diagnostic | Should -Match 'stale project-dir'
        Should -Invoke Invoke-WinsmuxRaw -Times 0
        Should -Invoke Invoke-MonitorWinsmux -Times 0
    }

    It 'skips C-c in archive-pane when a mismatched project-dir fails runtime ownership' {
        $probePath = Join-Path $script:task789FixRoot 'archive-runtime-probe.ps1'
        $dispatchPath = $script:task789DispatchPath
        $sentPath = Join-Path $script:task789FixRoot 'cc-sent.txt'
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        @"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:task789FixRoot
  expected_pane_count: 2
panes:
  worker-1:
    slot_id: worker-1
    pane_id: '%3'
    role: Worker
    worker_role: worker
    status: ready
  worker-2:
    slot_id: worker-2
    pane_id: '%9'
    role: Worker
    worker_role: worker
    status: busy
"@ | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $probe = @"
`$ErrorActionPreference = 'Stop'
function Stop-WithError { param([string]`$Message) throw `$Message }
function Get-Labels { return @{ 'worker-2' = '%9' } }
. '$($dispatchPath.Replace("'", "''"))'
function Test-PaneControlRuntimeContext {
    param(`$ProjectDir, `$ManifestEntry, `$Operation)
    return [pscustomobject]@{ valid = `$false; reason_code = 'runtime_target_mismatch'; diagnostic = 'unverified pane' }
}
function Get-PaneControlManifestEntries {
    param(`$ProjectDir)
    return @([pscustomobject]@{
        Label = 'worker-2'; SlotId = 'worker-2'; PaneId = '%9'; Role = 'Worker'
        WorkerRole = 'worker'; WorkerBackend = 'codex'; Title = 'worker-2'
        Status = 'busy'; LastEvent = 'pane.progress'
    })
}
function Invoke-WinsmuxRaw {
    param(`$Arguments)
    if (@(`$Arguments) -contains 'C-c') { Set-Content -LiteralPath '$($sentPath.Replace("'", "''"))' -Value 'sent' -Encoding utf8 }
}
function Invoke-MonitorWinsmux {
    param(`$Arguments)
    if (@(`$Arguments) -contains 'C-c') { Set-Content -LiteralPath '$($sentPath.Replace("'", "''"))' -Value 'sent' -Encoding utf8 }
}
Set-Location -LiteralPath '$($script:task789FixRoot.Replace("'", "''"))'
Invoke-WinsmuxArchivePaneCommand -BridgeScriptRoot '$($script:task789FixRoot.Replace("'", "''"))' -CommandTarget 'worker-2' -CommandRest @()
Write-Output 'reached-after-exit'
"@
        Set-Content -LiteralPath $probePath -Value $probe -Encoding utf8
        $output = & pwsh -NoProfile -File $probePath 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'unverified pane'
        ($output | Out-String) | Should -Not -Match 'reached-after-exit'
        Test-Path -LiteralPath $sentPath | Should -BeFalse
    }

    It 'treats unrecognized or empty archive status without an idle event as unavailable' {
        Mock Get-BridgeEventRecords { @() }
        $empty = Test-WinsmuxArchivePaneIdle -Entry ([pscustomobject]@{
            Label = 'worker-2'; PaneId = '%5'; Status = ''; LastEvent = ''
        }) -ProjectDir $script:task789FixRoot
        $empty.Idle | Should -BeFalse
        $empty.Evidence | Should -Be 'unavailable'

        $unknown = Test-WinsmuxArchivePaneIdle -Entry ([pscustomobject]@{
            Label = 'worker-2'; PaneId = '%5'; Status = 'unknown'; LastEvent = ''
        }) -ProjectDir $script:task789FixRoot
        $unknown.Idle | Should -BeFalse
        $unknown.Evidence | Should -Be 'unavailable'

        $ready = Test-WinsmuxArchivePaneIdle -Entry ([pscustomobject]@{
            Label = 'worker-2'; PaneId = '%5'; Status = 'ready'; LastEvent = ''
        }) -ProjectDir $script:task789FixRoot
        $ready.Idle | Should -BeTrue
        $ready.Evidence | Should -Be 'idle'
    }

    It 'lets a later matching pane.progress event override stale archive status=ready' {
        $idleIndex = $script:task789DispatchContent.IndexOf('function Test-WinsmuxArchivePaneIdle')
        $idleIndex | Should -BeGreaterThan -1
        $next = $script:task789DispatchContent.IndexOf("`nfunction ", $idleIndex + 1)
        if ($next -lt 0) {
            $next = $script:task789DispatchContent.Length
        }
        $body = $script:task789DispatchContent.Substring($idleIndex, $next - $idleIndex)
        $body.IndexOf('Get-BridgeEventRecords') | Should -BeGreaterThan -1
        $body.IndexOf('Get-BridgeEventRecords') | Should -BeLessThan $body.IndexOf("'ready', 'waiting_for_dispatch'")

        Mock Get-BridgeEventRecords {
            @(
                [ordered]@{ event = 'pane.idle'; label = 'worker-2'; pane_id = '%5' }
                [ordered]@{ event = 'pane.progress'; label = 'worker-2'; pane_id = '%5' }
            )
        }
        $busy = Test-WinsmuxArchivePaneIdle -Entry ([pscustomobject]@{
            Label = 'worker-2'; PaneId = '%5'; Status = 'ready'; LastEvent = ''
        }) -ProjectDir $script:task789FixRoot
        $busy.Idle | Should -BeFalse
        $busy.Evidence | Should -Be 'busy'
        $busy.LastEvent | Should -Be 'pane.progress'
    }

    It 'keeps archive idle when status=ready and the newest matching event or lastEvent is idle' {
        Mock Get-BridgeEventRecords {
            @(
                [ordered]@{ event = 'pane.progress'; label = 'worker-2'; pane_id = '%5' }
                [ordered]@{ event = 'pane.idle'; label = 'worker-2'; pane_id = '%5' }
            )
        }
        $newestIdle = Test-WinsmuxArchivePaneIdle -Entry ([pscustomobject]@{
            Label = 'worker-2'; PaneId = '%5'; Status = 'ready'; LastEvent = ''
        }) -ProjectDir $script:task789FixRoot
        $newestIdle.Idle | Should -BeTrue
        $newestIdle.Evidence | Should -Be 'idle'
        $newestIdle.LastEvent | Should -Be 'pane.idle'

        Mock Get-BridgeEventRecords { @() }
        $lastEventIdle = Test-WinsmuxArchivePaneIdle -Entry ([pscustomobject]@{
            Label = 'worker-2'; PaneId = '%5'; Status = 'ready'; LastEvent = 'pane.idle'
        }) -ProjectDir $script:task789FixRoot
        $lastEventIdle.Idle | Should -BeTrue
        $lastEventIdle.Evidence | Should -Be 'idle'
        $lastEventIdle.LastEvent | Should -Be 'pane.idle'
    }

    It 'keeps lastEvent busy ahead of a later idle event' {
        Mock Get-BridgeEventRecords {
            @(
                [ordered]@{ event = 'pane.idle'; label = 'worker-2'; pane_id = '%5' }
            )
        }
        $busy = Test-WinsmuxArchivePaneIdle -Entry ([pscustomobject]@{
            Label = 'worker-2'; PaneId = '%5'; Status = 'ready'; LastEvent = 'pane.progress'
        }) -ProjectDir $script:task789FixRoot
        $busy.Idle | Should -BeFalse
        $busy.Evidence | Should -Be 'busy'
        $busy.LastEvent | Should -Be 'pane.progress'
    }

    It 'commits a v2 spawn after split when the guarded save sees the new observed pane' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $registryPath = Get-WinsmuxRuntimeRegistryPath -ProjectDir $script:task789FixRoot
        $supervisor = script:Get-Task789SupervisorIdentity
        script:Write-Task789V2Manifest -Path $manifestPath -ProjectDir $script:task789FixRoot -Panes @(
            script:New-Task789V2Pane -Label 'worker-1' -PaneId '%3'
        )
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid $supervisor.Pid `
            -SupervisorProcessStartedAt $supervisor.StartedAt -ExpectedPaneCount 1 -LeaseSeconds 300 `
            -Panes @(script:New-Task789V2RegistryPane -Label 'worker-1' -PaneId '%3' -BootstrapPid 4200)
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null

        $script:task789Observed = @(
            script:New-Task789ObservedPane -PaneId '%1' -Title 'bootstrap'
            script:New-Task789ObservedPane -PaneId '%3' -Title 'worker-1'
        )
        script:Mock-Task789LiveServer
        $worktreePath = Join-Path $script:task789FixRoot '.worktrees\worker-2'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        Mock New-PaneScalerWorkerWorktree {
            [pscustomobject]@{ WorktreePath = $worktreePath; BranchName = 'worktree-worker-2'; GitWorktreeDir = $worktreePath }
        }
        Mock Invoke-MonitorWinsmux {
            param($Arguments)
            $argsList = @($Arguments)
            if ($argsList -contains 'split-window') {
                $script:task789Observed = @($script:task789Observed) + @(
                    script:New-Task789ObservedPane -PaneId '%5' -Title 'worker-2'
                )
                return '%5'
            }
            if ($argsList -contains 'select-pane') { return }
            if ($argsList -contains 'kill-pane') { throw 'spawn success must not kill the new pane' }
        }
        Mock Wait-MonitorPaneShellReady { }
        Mock Get-PaneScalerLaunchCommand { 'echo spawn-worker-2' }
        Mock New-OrchestraPaneBootstrapPlan {
            $planDir = Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap'
            New-Item -ItemType Directory -Path $planDir -Force | Out-Null
            $planPath = Join-Path $planDir '5.json'
            Set-Content -LiteralPath $planPath -Value '{}' -Encoding utf8
            return $planPath
        }
        Mock Get-OrchestraPaneBootstrapMarkerPath {
            Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap\5-generation-789.ready.json'
        }
        Mock Start-OrchestraPaneBootstrap { }
        Mock Get-BridgeSettings { [ordered]@{ agent = 'codex'; model = 'gpt-5.4' } }

        $result = Add-OrchestraWorkerPane -ManifestPath $manifestPath -SlotId 'worker-2' -SlotAgentConfig ([pscustomobject]@{
            Agent = 'codex'; Model = 'gpt-5.4'; WorkerBackend = 'codex'; PaneTitle = 'worker-2'
        })
        $result.Changed | Should -BeTrue
        $result.PaneId | Should -Be '%5'

        $saved = Read-PaneScalerManifest -ManifestPath $manifestPath
        $saved.version | Should -Be 2
        @($saved.Panes.Keys) | Should -Be @('worker-1', 'worker-2')
        $saved.Panes['worker-2'].pane_id | Should -Be '%5'
        $saved.Session.expected_pane_count | Should -Be 2
        $saved.Panes['worker-2'].status | Should -Be 'deferred_starting'

        $read = Read-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot
        $read.expected_pane_count | Should -Be 2
        @($read.panes | ForEach-Object { [string]$_.pane_id }) | Should -Be @('%3', '%5')
        ($script:task789Observed | ForEach-Object { $_.PaneId }) | Should -Contain '%5'
    }

    It 'kills the new v2 pane and restores file bytes when guarded spawn save fails after split' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $registryPath = Get-WinsmuxRuntimeRegistryPath -ProjectDir $script:task789FixRoot
        $supervisor = script:Get-Task789SupervisorIdentity
        script:Write-Task789V2Manifest -Path $manifestPath -ProjectDir $script:task789FixRoot -Panes @(
            script:New-Task789V2Pane -Label 'worker-1' -PaneId '%3'
        )
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid $supervisor.Pid `
            -SupervisorProcessStartedAt $supervisor.StartedAt -ExpectedPaneCount 1 -LeaseSeconds 300 `
            -Panes @(script:New-Task789V2RegistryPane -Label 'worker-1' -PaneId '%3' -BootstrapPid 4200)
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null
        $beforeRegistry = [System.IO.File]::ReadAllBytes($registryPath)
        $beforeManifest = [System.IO.File]::ReadAllBytes($manifestPath)

        $script:task789Observed = @(
            script:New-Task789ObservedPane -PaneId '%1' -Title 'bootstrap'
            script:New-Task789ObservedPane -PaneId '%3' -Title 'worker-1'
        )
        $script:task789Killed = @()
        script:Mock-Task789LiveServer
        $worktreePath = Join-Path $script:task789FixRoot '.worktrees\worker-2'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        Mock New-PaneScalerWorkerWorktree {
            [pscustomobject]@{ WorktreePath = $worktreePath; BranchName = 'worktree-worker-2'; GitWorktreeDir = $worktreePath }
        }
        Mock Invoke-MonitorWinsmux {
            param($Arguments)
            $argsList = @($Arguments)
            if ($argsList -contains 'split-window') {
                $script:task789Observed = @($script:task789Observed) + @(
                    script:New-Task789ObservedPane -PaneId '%5' -Title 'worker-2'
                )
                return '%5'
            }
            if ($argsList -contains 'select-pane') { return }
            if ($argsList -contains 'kill-pane') {
                $target = $argsList[$argsList.IndexOf('-t') + 1]
                $script:task789Killed += $target
                $script:task789Observed = @($script:task789Observed | Where-Object { $_.PaneId -ne $target })
                return
            }
        }
        Mock Wait-MonitorPaneShellReady { }
        Mock Get-PaneScalerLaunchCommand { 'echo spawn-worker-2' }
        Mock New-OrchestraPaneBootstrapPlan { Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap\5.json' }
        Mock Get-OrchestraPaneBootstrapMarkerPath {
            Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap\5-generation-789.ready.json'
        }
        Mock Start-OrchestraPaneBootstrap { }
        Mock Get-BridgeSettings { [ordered]@{ agent = 'codex'; model = 'gpt-5.4' } }
        Mock Save-PaneScalerManifest { throw 'injected spawn save failure' }

        { Add-OrchestraWorkerPane -ManifestPath $manifestPath -SlotId 'worker-2' -SlotAgentConfig ([pscustomobject]@{
            Agent = 'codex'; Model = 'gpt-5.4'; WorkerBackend = 'codex'; PaneTitle = 'worker-2'
        }) } | Should -Throw '*injected spawn save failure*'

        [System.IO.File]::ReadAllBytes($manifestPath) | Should -Be $beforeManifest
        [System.IO.File]::ReadAllBytes($registryPath) | Should -Be $beforeRegistry
        $script:task789Killed | Should -Contain '%5'
        ($script:task789Observed | ForEach-Object { $_.PaneId }) | Should -Not -Contain '%5'
    }

    It 'does not dispatch a v2 spawned worker as ready without a bootstrap marker PID' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $supervisor = script:Get-Task789SupervisorIdentity
        script:Write-Task789V2Manifest -Path $manifestPath -ProjectDir $script:task789FixRoot -Panes @(
            script:New-Task789V2Pane -Label 'worker-1' -PaneId '%3'
        )
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid $supervisor.Pid `
            -SupervisorProcessStartedAt $supervisor.StartedAt -ExpectedPaneCount 1 -LeaseSeconds 300 `
            -Panes @(script:New-Task789V2RegistryPane -Label 'worker-1' -PaneId '%3' -BootstrapPid 4200)
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null
        $script:task789Observed = @(
            script:New-Task789ObservedPane -PaneId '%1' -Title 'bootstrap'
            script:New-Task789ObservedPane -PaneId '%3' -Title 'worker-1'
        )
        script:Mock-Task789LiveServer
        $worktreePath = Join-Path $script:task789FixRoot '.worktrees\worker-2'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        Mock New-PaneScalerWorkerWorktree {
            [pscustomobject]@{ WorktreePath = $worktreePath; BranchName = 'worktree-worker-2'; GitWorktreeDir = $worktreePath }
        }
        Mock Invoke-MonitorWinsmux {
            param($Arguments)
            $argsList = @($Arguments)
            if ($argsList -contains 'split-window') {
                $script:task789Observed = @($script:task789Observed) + @(
                    script:New-Task789ObservedPane -PaneId '%5' -Title 'worker-2'
                )
                return '%5'
            }
            if ($argsList -contains 'select-pane') { return }
        }
        Mock Wait-MonitorPaneShellReady { }
        Mock Get-PaneScalerLaunchCommand { 'echo spawn-worker-2' }
        Mock New-OrchestraPaneBootstrapPlan { Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap\5.json' }
        Mock Get-OrchestraPaneBootstrapMarkerPath {
            Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap\5-generation-789.ready.json'
        }
        Mock Start-OrchestraPaneBootstrap { }
        Mock Get-BridgeSettings { [ordered]@{ agent = 'codex'; model = 'gpt-5.4' } }

        $null = Add-OrchestraWorkerPane -ManifestPath $manifestPath -SlotId 'worker-2' -SlotAgentConfig ([pscustomobject]@{
            Agent = 'codex'; Model = 'gpt-5.4'; WorkerBackend = 'codex'; PaneTitle = 'worker-2'
        })
        $saved = Read-PaneScalerManifest -ManifestPath $manifestPath
        $saved.Panes['worker-2'].status | Should -Be 'deferred_starting'
        $readyRaw = $saved.Panes['worker-2'].runtime_ready
        ($readyRaw -eq $true -or [string]$readyRaw -ceq 'true') | Should -BeFalse

        $read = Read-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot
        $spawned = @($read.panes | Where-Object { [string]$_.label -eq 'worker-2' })[0]
        [int]$spawned.bootstrap_pid | Should -Be 0

        $script:task789DispatchStartedAt = Get-WinsmuxRuntimeProcessStartedAt -ProcessId $PID
        $dispatchCheck = Test-WinsmuxRuntimeContext -Manifest (Get-WinsmuxManifest -ProjectDir $script:task789FixRoot) `
            -Registry $read -ObservedServerSessionId '$9' -ObservedPanes @(
                [pscustomobject]@{ pane_id = '%1'; title = 'bootstrap' }
                [pscustomobject]@{ pane_id = '%3'; title = 'worker-1' }
                [pscustomobject]@{ pane_id = '%5'; title = 'worker-2' }
            ) -ManifestEntry ([pscustomobject]@{
                Label = 'worker-2'; SlotId = 'worker-2'; PaneId = '%5'; WorkerBackend = 'codex'
                WorkerRole = 'worker'; Role = 'Worker'; Title = 'worker-2'; Status = 'ready'
            }) -PaneMarker $null -ProcessResolver {
                param([int]$Id)
                if ($Id -eq $PID) {
                    return [PSCustomObject]@{ Id = $PID; StartTime = $script:task789DispatchStartedAt; ParentProcessId = 1; Name = 'pwsh.exe' }
                }
                if ($Id -eq 4200) {
                    return [PSCustomObject]@{ Id = 4200; StartTime = '2026-08-17T00:00:01.0000000Z'; ParentProcessId = 1; Name = 'pwsh.exe' }
                }
                return $null
            } -Operation dispatch -Now ([datetime]::UtcNow.AddMinutes(1))
        $dispatchCheck.valid | Should -BeFalse
        $dispatchCheck.reason_code | Should -Be 'runtime_target_mismatch'
    }

    It 'lets v2 dispatch runtime succeed after a spawned worker persists a bootstrap marker PID' {
        $markerDir = Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap'
        New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
        $markerPath = Join-Path $markerDir '5-generation-789.ready.json'
        $startedAt = '2026-08-17T00:00:02.0000000Z'
        @{
            state = 'bootstrap_pending'
            generation_id = 'generation-789'
            server_session_id = '$9'
            slot_id = 'worker-2'
            pane_id = '%5'
            backend = 'codex'
            role = 'worker'
            title = 'worker-2'
            bootstrap_pid = 4300
            bootstrap_process_started_at = $startedAt
        } | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding utf8

        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $supervisor = script:Get-Task789SupervisorIdentity
        script:Write-Task789V2Manifest -Path $manifestPath -ProjectDir $script:task789FixRoot -Panes @(
            script:New-Task789V2Pane -Label 'worker-1' -PaneId '%3'
        )
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid $supervisor.Pid `
            -SupervisorProcessStartedAt $supervisor.StartedAt -ExpectedPaneCount 1 -LeaseSeconds 300 `
            -Panes @(script:New-Task789V2RegistryPane -Label 'worker-1' -PaneId '%3' -BootstrapPid 4200)
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null
        $script:task789Observed = @(
            script:New-Task789ObservedPane -PaneId '%1' -Title 'bootstrap'
            script:New-Task789ObservedPane -PaneId '%3' -Title 'worker-1'
        )
        script:Mock-Task789LiveServer
        $worktreePath = Join-Path $script:task789FixRoot '.worktrees\worker-2'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        Mock New-PaneScalerWorkerWorktree {
            [pscustomobject]@{ WorktreePath = $worktreePath; BranchName = 'worktree-worker-2'; GitWorktreeDir = $worktreePath }
        }
        Mock Invoke-MonitorWinsmux {
            param($Arguments)
            $argsList = @($Arguments)
            if ($argsList -contains 'split-window') {
                $script:task789Observed = @($script:task789Observed) + @(
                    script:New-Task789ObservedPane -PaneId '%5' -Title 'worker-2'
                )
                return '%5'
            }
            if ($argsList -contains 'select-pane') { return }
            if ($argsList -contains 'capture-pane') {
                $script:task789AgentReadyProbes++
                return '>'
            }
        }
        Mock Wait-MonitorPaneShellReady { }
        Mock Get-PaneScalerLaunchCommand { 'echo spawn-worker-2' }
        Mock New-OrchestraPaneBootstrapPlan { Join-Path $markerDir '5.json' }
        Mock Get-OrchestraPaneBootstrapMarkerPath { $markerPath }
        Mock Start-OrchestraPaneBootstrap { }
        Mock Get-BridgeSettings { [ordered]@{ agent = 'codex'; model = 'gpt-5.4' } }

        $null = Add-OrchestraWorkerPane -ManifestPath $manifestPath -SlotId 'worker-2' -SlotAgentConfig ([pscustomobject]@{
            Agent = 'codex'; Model = 'gpt-5.4'; WorkerBackend = 'codex'; PaneTitle = 'worker-2'
        })
        $saved = Read-PaneScalerManifest -ManifestPath $manifestPath
        $saved.Panes['worker-2'].status | Should -Be 'ready'
        [bool]$saved.Panes['worker-2'].runtime_ready | Should -BeTrue
        $script:task789AgentReadyProbes | Should -BeGreaterThan 0

        $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $read = Read-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot
        $script:task789DispatchStartedAt = Get-WinsmuxRuntimeProcessStartedAt -ProcessId $PID
        $dispatchCheck = Test-WinsmuxRuntimeContext -Manifest (Get-WinsmuxManifest -ProjectDir $script:task789FixRoot) `
            -Registry $read -ObservedServerSessionId '$9' -ObservedPanes @(
                [pscustomobject]@{ pane_id = '%1'; title = 'bootstrap' }
                [pscustomobject]@{ pane_id = '%3'; title = 'worker-1' }
                [pscustomobject]@{ pane_id = '%5'; title = 'worker-2' }
            ) -ManifestEntry ([pscustomobject]@{
                Label = 'worker-2'; SlotId = 'worker-2'; PaneId = '%5'; WorkerBackend = 'codex'
                WorkerRole = 'worker'; Role = 'Worker'; Title = 'worker-2'; Status = 'ready'
                BootstrapMarkerPath = $markerPath
            }) -PaneMarker $marker -ProcessResolver {
                param([int]$Id)
                switch ($Id) {
                    $PID { return [PSCustomObject]@{ Id = $PID; StartTime = $script:task789DispatchStartedAt; ParentProcessId = 1; Name = 'pwsh.exe' } }
                    4200 { return [PSCustomObject]@{ Id = 4200; StartTime = '2026-08-17T00:00:01.0000000Z'; ParentProcessId = 1; Name = 'pwsh.exe' } }
                    4300 { return [PSCustomObject]@{ Id = 4300; StartTime = [datetime]'2026-08-17T00:00:02Z'; ParentProcessId = 1; Name = 'pwsh.exe' } }
                    default { return $null }
                }
            } -Operation dispatch -Now ([datetime]::UtcNow.AddMinutes(1))
        $dispatchCheck.valid | Should -BeTrue -Because ("dispatch diagnostic: {0} {1}" -f $dispatchCheck.reason_code, $dispatchCheck.diagnostic)
        $dispatchCheck.reason_code | Should -Be 'live_runtime_verified'
    }

    It 'does not publish v2 status=ready when a marker PID exists but agent-readiness times out' {
        $scalerIndex = $script:task789PaneScalerContent.IndexOf('function Add-OrchestraWorkerPane')
        $scalerIndex | Should -BeGreaterThan -1
        $next = $script:task789PaneScalerContent.IndexOf("`nfunction ", $scalerIndex + 1)
        if ($next -lt 0) {
            $next = $script:task789PaneScalerContent.Length
        }
        $spawnBody = $script:task789PaneScalerContent.Substring($scalerIndex, $next - $scalerIndex)
        $spawnBody | Should -Match 'Wait-OrchestraSpawnAgentReady'
        $script:task789PaneScalerContent | Should -Match 'function Wait-OrchestraSpawnAgentReady'
        $script:task789PaneScalerContent | Should -Match 'Get-PaneAgentStatus -PaneId \$PaneId -Agent \$Agent -Role ''Worker'''

        $markerDir = Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap'
        New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
        $markerPath = Join-Path $markerDir '5-generation-789.ready.json'
        @{
            state = 'bootstrap_pending'
            generation_id = 'generation-789'
            server_session_id = '$9'
            slot_id = 'worker-2'
            pane_id = '%5'
            backend = 'codex'
            role = 'worker'
            title = 'worker-2'
            bootstrap_pid = 4300
            bootstrap_process_started_at = '2026-08-17T00:00:02.0000000Z'
        } | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding utf8

        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $registryPath = Get-WinsmuxRuntimeRegistryPath -ProjectDir $script:task789FixRoot
        $supervisor = script:Get-Task789SupervisorIdentity
        script:Write-Task789V2Manifest -Path $manifestPath -ProjectDir $script:task789FixRoot -Panes @(
            script:New-Task789V2Pane -Label 'worker-1' -PaneId '%3'
        )
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid $supervisor.Pid `
            -SupervisorProcessStartedAt $supervisor.StartedAt -ExpectedPaneCount 1 -LeaseSeconds 300 `
            -Panes @(script:New-Task789V2RegistryPane -Label 'worker-1' -PaneId '%3' -BootstrapPid 4200)
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null
        $beforeRegistry = [System.IO.File]::ReadAllBytes($registryPath)
        $beforeManifest = [System.IO.File]::ReadAllBytes($manifestPath)
        $script:task789Observed = @(
            script:New-Task789ObservedPane -PaneId '%1' -Title 'bootstrap'
            script:New-Task789ObservedPane -PaneId '%3' -Title 'worker-1'
        )
        $script:task789Killed = @()
        script:Mock-Task789LiveServer
        $worktreePath = Join-Path $script:task789FixRoot '.worktrees\worker-2'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        Mock New-PaneScalerWorkerWorktree {
            [pscustomobject]@{ WorktreePath = $worktreePath; BranchName = 'worktree-worker-2'; GitWorktreeDir = $worktreePath }
        }
        Mock Remove-PaneScalerBuilderWorktree { $script:task789WorktreeRemoved = $true }
        Mock Invoke-MonitorWinsmux {
            param($Arguments)
            $argsList = @($Arguments)
            if ($argsList -contains 'split-window') {
                $script:task789Observed = @($script:task789Observed) + @(
                    script:New-Task789ObservedPane -PaneId '%5' -Title 'worker-2'
                )
                return '%5'
            }
            if ($argsList -contains 'select-pane') { return }
            if ($argsList -contains 'capture-pane') {
                $script:task789AgentReadyProbes++
                return 'executing task...'
            }
            if ($argsList -contains 'kill-pane') {
                $target = $argsList[$argsList.IndexOf('-t') + 1]
                $script:task789Killed += $target
                $script:task789Observed = @($script:task789Observed | Where-Object { $_.PaneId -ne $target })
                return
            }
        }
        Mock Wait-MonitorPaneShellReady { }
        Mock Get-PaneScalerLaunchCommand { 'echo spawn-worker-2' }
        Mock New-OrchestraPaneBootstrapPlan { Join-Path $markerDir '5.json' }
        Mock Get-OrchestraPaneBootstrapMarkerPath { $markerPath }
        Mock Start-OrchestraPaneBootstrap { }
        Mock Get-BridgeSettings { [ordered]@{ agent = 'codex'; model = 'gpt-5.4' } }

        { Add-OrchestraWorkerPane -ManifestPath $manifestPath -SlotId 'worker-2' -SlotAgentConfig ([pscustomobject]@{
            Agent = 'codex'; Model = 'gpt-5.4'; WorkerBackend = 'codex'; PaneTitle = 'worker-2'
        }) -AgentReadyTimeoutSeconds 0 } | Should -Throw '*timed out waiting for agent ready*'

        $script:task789AgentReadyProbes | Should -BeGreaterThan 0
        [System.IO.File]::ReadAllBytes($manifestPath) | Should -Be $beforeManifest
        [System.IO.File]::ReadAllBytes($registryPath) | Should -Be $beforeRegistry
        $script:task789Killed | Should -Contain '%5'
        $script:task789WorktreeRemoved | Should -BeTrue
        ($script:task789Observed | ForEach-Object { $_.PaneId }) | Should -Not -Contain '%5'
        $saved = Read-PaneScalerManifest -ManifestPath $manifestPath
        $saved.Panes.Contains('worker-2') | Should -BeFalse
    }

    It 'TASK-789 spawn readiness uses CapabilityAdapter instead of provider Agent' {
        $scalerIndex = $script:task789PaneScalerContent.IndexOf('function Add-OrchestraWorkerPane')
        $scalerIndex | Should -BeGreaterThan -1
        $next = $script:task789PaneScalerContent.IndexOf("`nfunction ", $scalerIndex + 1)
        if ($next -lt 0) {
            $next = $script:task789PaneScalerContent.Length
        }
        $spawnBody = $script:task789PaneScalerContent.Substring($scalerIndex, $next - $scalerIndex)
        $spawnBody | Should -Match 'Get-PaneScalerReadinessAgent'
        $spawnBody | Should -Match 'Wait-OrchestraSpawnAgentReady -PaneId \$newPaneId -Agent \$readinessAgent'
        $spawnBody | Should -Not -Match 'Wait-OrchestraSpawnAgentReady -PaneId \$newPaneId -Agent \$agent'
        $script:task789PaneScalerContent | Should -Match 'function Get-PaneScalerReadinessAgent'

        Get-PaneScalerReadinessAgent -SlotAgentConfig ([pscustomobject]@{
            Agent = 'openrouter'; CapabilityAdapter = 'openai-compatible'
        }) -FallbackAgent 'codex' | Should -Be 'openai-compatible'
        Get-PaneScalerReadinessAgent -SlotAgentConfig ([pscustomobject]@{
            Agent = 'openrouter'; CapabilityAdapter = ''
        }) -FallbackAgent 'codex' | Should -Be 'openrouter'

        $promptText = (@(
            'status: ready'
            'api_llm[worker-1]>'
        ) -join [Environment]::NewLine)
        Test-AgentPromptText -Text $promptText -Agent 'openrouter' | Should -BeFalse
        Test-AgentPromptText -Text $promptText -Agent 'openai-compatible' | Should -BeTrue

        $markerDir = Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap'
        New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
        $markerPath = Join-Path $markerDir '5-generation-789.ready.json'
        @{
            state = 'bootstrap_pending'
            generation_id = 'generation-789'
            server_session_id = '$9'
            slot_id = 'worker-2'
            pane_id = '%5'
            backend = 'openrouter'
            role = 'worker'
            title = 'worker-2'
            bootstrap_pid = 4300
            bootstrap_process_started_at = '2026-08-17T00:00:02.0000000Z'
        } | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding utf8

        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        @"
version: 1
saved_at: 2026-08-17T00:00:00Z
session:
  name: winsmux-orchestra
  project_dir: $script:task789FixRoot
  generation_id: generation-789
  server_session_id: '`$9'
  bootstrap_pane_id: '%1'
  expected_pane_count: 1
panes:
  worker-1:
    slot_id: worker-1
    pane_id: '%3'
    role: Worker
    worker_role: worker
    worker_backend: openrouter
    title: worker-1
    status: ready
"@ | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $worktreePath = Join-Path $script:task789FixRoot '.worktrees\worker-2'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        Mock New-PaneScalerWorkerWorktree {
            [pscustomobject]@{ WorktreePath = $worktreePath; BranchName = 'worktree-worker-2'; GitWorktreeDir = $worktreePath }
        }
        Mock Invoke-MonitorWinsmux {
            param($Arguments)
            if (@($Arguments) -contains 'split-window') { return '%5' }
        }
        Mock Wait-MonitorPaneShellReady { }
        Mock Get-PaneScalerLaunchCommand { 'echo spawn-worker-2' }
        Mock New-OrchestraPaneBootstrapPlan { Join-Path $markerDir '5.json' }
        Mock Get-OrchestraPaneBootstrapMarkerPath { $markerPath }
        Mock Start-OrchestraPaneBootstrap { }
        Mock Get-BridgeSettings { [ordered]@{ agent = 'openrouter'; model = 'z-ai/glm-5.2' } }
        Mock Get-PaneAgentStatus {
            [PSCustomObject]@{
                Status       = 'ready'
                PaneId       = '%5'
                SnapshotTail = ''
                ExitReason   = ''
            }
        }

        $null = Add-OrchestraWorkerPane -ManifestPath $manifestPath -SlotId 'worker-2' -SlotAgentConfig ([pscustomobject]@{
            Agent = 'openrouter'; CapabilityAdapter = 'openai-compatible'; Model = 'z-ai/glm-5.2'; WorkerBackend = 'openrouter'; PaneTitle = 'worker-2'
        })
        $saved = Read-PaneScalerManifest -ManifestPath $manifestPath
        $saved.Panes['worker-2'].status | Should -Be 'ready'
        Should -Invoke Get-PaneAgentStatus -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%5' -and $Agent -eq 'openai-compatible' -and $Role -eq 'Worker'
        }
        Should -Invoke Get-PaneAgentStatus -Times 0 -ParameterFilter {
            $Agent -eq 'openrouter'
        }
    }

    It 'restores v2 archive files when kill-pane fails and the pane is still listed' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $registryPath = Get-WinsmuxRuntimeRegistryPath -ProjectDir $script:task789FixRoot
        $supervisor = script:Get-Task789SupervisorIdentity
        script:Write-Task789V2Manifest -Path $manifestPath -ProjectDir $script:task789FixRoot -Panes @(
            script:New-Task789V2Pane -Label 'worker-1' -PaneId '%3'
            script:New-Task789V2Pane -Label 'worker-2' -PaneId '%5'
        )
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid $supervisor.Pid `
            -SupervisorProcessStartedAt $supervisor.StartedAt -ExpectedPaneCount 2 -LeaseSeconds 300 `
            -Panes @(
                script:New-Task789V2RegistryPane -Label 'worker-1' -PaneId '%3' -BootstrapPid 4200
                script:New-Task789V2RegistryPane -Label 'worker-2' -PaneId '%5' -BootstrapPid 4300
            )
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null
        $beforeRegistry = [System.IO.File]::ReadAllBytes($registryPath)
        $beforeManifest = [System.IO.File]::ReadAllBytes($manifestPath)
        $script:task789Observed = @(
            script:New-Task789ObservedPane -PaneId '%1' -Title 'bootstrap'
            script:New-Task789ObservedPane -PaneId '%3' -Title 'worker-1'
            script:New-Task789ObservedPane -PaneId '%5' -Title 'worker-2'
        )
        script:Mock-Task789LiveServer
        Mock Invoke-MonitorWinsmux {
            param($Arguments)
            if (@($Arguments) -contains 'kill-pane') {
                throw 'injected kill-pane failure'
            }
        }

        { Remove-OrchestraWorkerPane -ManifestPath $manifestPath -Label 'worker-2' } |
            Should -Throw '*still live*'

        [System.IO.File]::ReadAllBytes($manifestPath) | Should -Be $beforeManifest
        [System.IO.File]::ReadAllBytes($registryPath) | Should -Be $beforeRegistry
        $saved = Read-PaneScalerManifest -ManifestPath $manifestPath
        $saved.Panes.Contains('worker-2') | Should -BeTrue
    }

    It 'does not re-advertise a dead v2 pane when kill-pane succeeds and the guarded save fails' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $registryPath = Get-WinsmuxRuntimeRegistryPath -ProjectDir $script:task789FixRoot
        $supervisor = script:Get-Task789SupervisorIdentity
        script:Write-Task789V2Manifest -Path $manifestPath -ProjectDir $script:task789FixRoot -Panes @(
            script:New-Task789V2Pane -Label 'worker-1' -PaneId '%3'
            script:New-Task789V2Pane -Label 'worker-2' -PaneId '%5'
        )
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid $supervisor.Pid `
            -SupervisorProcessStartedAt $supervisor.StartedAt -ExpectedPaneCount 2 -LeaseSeconds 300 `
            -Panes @(
                script:New-Task789V2RegistryPane -Label 'worker-1' -PaneId '%3' -BootstrapPid 4200
                script:New-Task789V2RegistryPane -Label 'worker-2' -PaneId '%5' -BootstrapPid 4300
            )
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null
        $script:task789Observed = @(
            script:New-Task789ObservedPane -PaneId '%1' -Title 'bootstrap'
            script:New-Task789ObservedPane -PaneId '%3' -Title 'worker-1'
            script:New-Task789ObservedPane -PaneId '%5' -Title 'worker-2'
        )
        script:Mock-Task789LiveServer
        Mock Invoke-MonitorWinsmux {
            param($Arguments)
            $argsList = @($Arguments)
            if ($argsList -contains 'kill-pane') {
                $target = $argsList[$argsList.IndexOf('-t') + 1]
                $script:task789Observed = @($script:task789Observed | Where-Object { $_.PaneId -ne $target })
                return
            }
        }
        Mock Save-PaneScalerManifest { throw 'injected archive save failure' }

        { Remove-OrchestraWorkerPane -ManifestPath $manifestPath -Label 'worker-2' } |
            Should -Throw '*failed to persist*'

        $saved = Read-PaneScalerManifest -ManifestPath $manifestPath
        $saved.Panes.Contains('worker-2') | Should -BeFalse
        @($saved.Panes.Keys) | Should -Be @('worker-1')
        $read = Read-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot
        @($read.panes | ForEach-Object { [string]$_.label }) | Should -Be @('worker-1')
        $read.expected_pane_count | Should -Be 1
        (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8) | Should -Not -Match "pane_id: '%5'"
    }

    It 'does not send C-c or kill when archive-pane has no idle evidence' {
        $probePath = Join-Path $script:task789FixRoot 'archive-idle-probe.ps1'
        $dispatchPath = $script:task789DispatchPath
        $sentPath = Join-Path $script:task789FixRoot 'cc-sent.txt'
        $killedPath = Join-Path $script:task789FixRoot 'killed.txt'
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        script:Write-Task789V2Manifest -Path $manifestPath -ProjectDir $script:task789FixRoot -Panes @(
            script:New-Task789V2Pane -Label 'worker-1' -PaneId '%3' -Status 'ready'
            script:New-Task789V2Pane -Label 'worker-2' -PaneId '%9' -Status 'unknown'
        )
        $probe = @"
`$ErrorActionPreference = 'Stop'
function Stop-WithError { param([string]`$Message) throw `$Message }
function Get-Labels { return @{ 'worker-2' = '%9' } }
. '$($dispatchPath.Replace("'", "''"))'
function Test-PaneControlRuntimeContext {
    param(`$ProjectDir, `$ManifestEntry, `$Operation)
    return [pscustomobject]@{ valid = `$true; reason_code = 'stop_transition_verified'; diagnostic = 'ok'; context = [pscustomobject]@{ generation_id = 'generation-789' } }
}
function Get-PaneControlManifestEntries {
    param(`$ProjectDir)
    return @(
        [pscustomobject]@{
            Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%3'; Role = 'Worker'
            WorkerRole = 'worker'; WorkerBackend = 'codex'; Title = 'worker-1'
            Status = 'ready'; LastEvent = 'pane.idle'
        },
        [pscustomobject]@{
            Label = 'worker-2'; SlotId = 'worker-2'; PaneId = '%9'; Role = 'Worker'
            WorkerRole = 'worker'; WorkerBackend = 'codex'; Title = 'worker-2'
            Status = 'unknown'; LastEvent = ''
        }
    )
}
function Invoke-WinsmuxRaw {
    param(`$Arguments)
    if (@(`$Arguments) -contains 'C-c') { Set-Content -LiteralPath '$($sentPath.Replace("'", "''"))' -Value 'sent' -Encoding utf8 }
}
function Invoke-MonitorWinsmux {
    param(`$Arguments)
    if (@(`$Arguments) -contains 'C-c') { Set-Content -LiteralPath '$($sentPath.Replace("'", "''"))' -Value 'sent' -Encoding utf8 }
    if (@(`$Arguments) -contains 'kill-pane') { Set-Content -LiteralPath '$($killedPath.Replace("'", "''"))' -Value 'killed' -Encoding utf8 }
}
function Remove-OrchestraPane {
    param(`$ManifestPath, `$Role, `$Label)
    Set-Content -LiteralPath '$($killedPath.Replace("'", "''"))' -Value 'removed' -Encoding utf8
    return [pscustomobject]@{ Changed = `$true; Reason = '' }
}
Set-Location -LiteralPath '$($script:task789FixRoot.Replace("'", "''"))'
Invoke-WinsmuxArchivePaneCommand -BridgeScriptRoot '$($script:task789FixRoot.Replace("'", "''"))' -CommandTarget 'worker-2' -CommandRest @()
Write-Output 'reached-after-exit'
"@
        Set-Content -LiteralPath $probePath -Value $probe -Encoding utf8
        $output = & pwsh -NoProfile -File $probePath 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'idle evidence is unavailable'
        ($output | Out-String) | Should -Not -Match 'reached-after-exit'
        Test-Path -LiteralPath $sentPath | Should -BeFalse
        Test-Path -LiteralPath $killedPath | Should -BeFalse
    }

    It 'interrupts instead of skip-killing when archive-pane sees status=ready and a later pane.progress event' {
        $probePath = Join-Path $script:task789FixRoot 'archive-ready-progress-probe.ps1'
        $dispatchPath = $script:task789DispatchPath
        $sentPath = Join-Path $script:task789FixRoot 'cc-sent.txt'
        $killedPath = Join-Path $script:task789FixRoot 'killed.txt'
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        script:Write-Task789V2Manifest -Path $manifestPath -ProjectDir $script:task789FixRoot -Panes @(
            script:New-Task789V2Pane -Label 'worker-1' -PaneId '%3' -Status 'ready'
            script:New-Task789V2Pane -Label 'worker-2' -PaneId '%9' -Status 'ready'
        )
        $probe = @"
`$ErrorActionPreference = 'Stop'
function Stop-WithError { param([string]`$Message) throw `$Message }
function Get-Labels { return @{ 'worker-2' = '%9' } }
. '$($dispatchPath.Replace("'", "''"))'
function Test-PaneControlRuntimeContext {
    param(`$ProjectDir, `$ManifestEntry, `$Operation)
    return [pscustomobject]@{ valid = `$true; reason_code = 'stop_transition_verified'; diagnostic = 'ok'; context = [pscustomobject]@{ generation_id = 'generation-789' } }
}
function Get-PaneControlManifestEntries {
    param(`$ProjectDir)
    return @(
        [pscustomobject]@{
            Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%3'; Role = 'Worker'
            WorkerRole = 'worker'; WorkerBackend = 'codex'; Title = 'worker-1'
            Status = 'ready'; LastEvent = 'pane.idle'
        },
        [pscustomobject]@{
            Label = 'worker-2'; SlotId = 'worker-2'; PaneId = '%9'; Role = 'Worker'
            WorkerRole = 'worker'; WorkerBackend = 'codex'; Title = 'worker-2'
            Status = 'ready'; LastEvent = ''
        }
    )
}
function Get-BridgeEventRecords {
    param(`$ProjectDir)
    return @(
        [ordered]@{ event = 'pane.idle'; label = 'worker-2'; pane_id = '%9' }
        [ordered]@{ event = 'pane.progress'; label = 'worker-2'; pane_id = '%9' }
    )
}
function Invoke-WinsmuxRaw {
    param(`$Arguments)
    if (@(`$Arguments) -contains 'C-c') { Set-Content -LiteralPath '$($sentPath.Replace("'", "''"))' -Value 'sent' -Encoding utf8 }
}
function Invoke-MonitorWinsmux {
    param(`$Arguments)
    if (@(`$Arguments) -contains 'C-c') { Set-Content -LiteralPath '$($sentPath.Replace("'", "''"))' -Value 'sent' -Encoding utf8 }
    if (@(`$Arguments) -contains 'kill-pane') { Set-Content -LiteralPath '$($killedPath.Replace("'", "''"))' -Value 'killed' -Encoding utf8 }
}
function Remove-OrchestraPane {
    param(`$ManifestPath, `$Role, `$Label)
    Set-Content -LiteralPath '$($killedPath.Replace("'", "''"))' -Value 'removed' -Encoding utf8
    return [pscustomobject]@{ Changed = `$true; Reason = '' }
}
Set-Location -LiteralPath '$($script:task789FixRoot.Replace("'", "''"))'
Invoke-WinsmuxArchivePaneCommand -BridgeScriptRoot '$($script:task789FixRoot.Replace("'", "''"))' -CommandTarget 'worker-2' -CommandRest @()
Write-Output 'reached-after-exit'
"@
        Set-Content -LiteralPath $probePath -Value $probe -Encoding utf8
        $output = & pwsh -NoProfile -File $probePath 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'interrupt did not make'
        ($output | Out-String) | Should -Not -Match 'reached-after-exit'
        Test-Path -LiteralPath $sentPath | Should -BeTrue
        Test-Path -LiteralPath $killedPath | Should -BeFalse
    }

    It 'keeps a single control-plane flag as a one-element argument list' {
        $parts = ConvertTo-WinsmuxControlPlaneArgumentList -Value (
            Get-WinsmuxControlPlaneArguments -CommandTarget '--json' -CommandRest @()
        )
        $parts.Count | Should -Be 1
        $parts[0] | Should -Be '--json'
    }

    It 'E03 public argv parse keeps --slot-id and --project-dir as separate tokens' {
        $parts = ConvertTo-WinsmuxControlPlaneArgumentList -Value (
            Get-WinsmuxControlPlaneArguments -CommandTarget '--slot-id' -CommandRest @(
                'worker-2', '--project-dir', $script:task789FixRoot, 'implement the focused change'
            )
        )
        $parsed = Split-WinsmuxDispatchTaskArguments -Parts $parts
        $parsed.SlotId | Should -Be 'worker-2'
        $parsed.ProjectDir | Should -Be $script:task789FixRoot
        $parsed.TaskText | Should -Be 'implement the focused change'
        $parts.Count | Should -Be 5
        $parts[0] | Should -Be '--slot-id'
        $parts[1] | Should -Be 'worker-2'
    }

    It 'E01 public dispatch-task without --slot-id spawns a missing catalog slot instead of only the live worker' {
        $null = New-Item -ItemType File -Path (Join-Path $script:task789FixRoot '.winsmux.yaml') -Force
        $script:task789SpawnedSlots = @()
        $script:task789SubmittedLabel = ''
        $script:task789Receipt = $null
        $script:task789Worker2Live = $false
        Mock Get-OrchestraModeDocument {
            [pscustomobject]@{ schema_version = 1; mode = 'team'; valid = $true; source = 'file' }
        }
        Mock Get-OrchestraLiveWorkerRolePaneCount { 1 }
        Mock Get-OrchestraMaxLiveWorkerPaneCount { 6 }
        Mock Get-WinsmuxManifest {
            [pscustomobject]@{
                Panes = [ordered]@{
                    'worker-1' = [pscustomobject]@{ pane_id = '%3'; role = 'Worker' }
                }
            }
        }
        Mock Get-BridgeSettings {
            [ordered]@{
                agent_slots = @(
                    [pscustomobject]@{ slot_id = 'worker-1'; runtime_role = 'worker'; worker_role = 'impl' }
                    [pscustomobject]@{ slot_id = 'worker-2'; runtime_role = 'worker'; worker_role = 'impl' }
                )
            }
        }
        Mock Get-PaneControlManifestEntries {
            $entries = @(script:New-Task789LiveEntry -Label 'worker-1' -PaneId '%3')
            if ($script:task789Worker2Live) {
                $entries += script:New-Task789LiveEntry -Label 'worker-2' -PaneId '%5'
            }
            return $entries
        }
        Mock Get-DispatchTaskCatalogSlotIds { @('worker-1', 'worker-2') }
        Mock Invoke-TeamProfileLaunchProjection {
            [pscustomobject]@{
                bundle_path = '.winsmux/team-profile/worker-2.md'
                projection  = [pscustomobject]@{
                    pane = [pscustomobject]@{
                        assignment    = [pscustomobject]@{ provider = 'codex'; launch_model = 'gpt-5.4'; worker_backend = 'codex' }
                        prompt_bundle = [pscustomobject]@{ path = '.winsmux/team-profile/worker-2.md' }
                    }
                }
            }
        }
        Mock New-TeamProfileSlotAgentConfig {
            [pscustomobject]@{ Agent = 'codex'; Model = 'gpt-5.4'; WorkerBackend = 'codex'; PaneTitle = $SlotId }
        }
        Mock Add-OrchestraPane {
            $script:task789SpawnedSlots += [string]$SlotId
            $script:task789Worker2Live = $true
            return [pscustomobject]@{ Changed = $true; Label = $SlotId; PaneId = '%5' }
        }
        Mock Test-PaneControlRuntimeContext {
            [pscustomobject]@{
                valid       = $true
                reason_code = 'dispatch_verified'
                diagnostic  = 'ok'
                context     = [ordered]@{ generation_id = 'generation-789' }
            }
        }
        Mock Start-DeferredPaneFromManifestEntry { $false }
        Mock Invoke-WinsmuxSubmissionAdapter {
            param($ProjectDir, $ManifestEntry, $Kind, $Content, $SubmissionId)
            $script:task789SubmittedLabel = [string]$ManifestEntry.Label
            return [pscustomobject]@{
                protocol_version = 1
                submission_id    = $SubmissionId
                kind             = 'task'
                status           = 'accepted'
                backend          = 'codex'
                reason_code      = ''
                diagnostic       = ''
                target           = [ordered]@{ label = [string]$ManifestEntry.Label; pane_id = [string]$ManifestEntry.PaneId; role = 'Worker' }
                routing          = $null
                acknowledgement  = $null
            }
        }
        Mock ConvertTo-WinsmuxSubmissionReceiptJson {
            param($Receipt)
            $script:task789Receipt = $Receipt
            return ($Receipt | ConvertTo-Json -Compress -Depth 8)
        }

        $null = script:Invoke-Task789PublicDispatchTask -Argv @(
            '--project-dir', $script:task789FixRoot, 'implement the focused change'
        )

        $script:task789SpawnedSlots | Should -Be @('worker-2')
        $script:task789SubmittedLabel | Should -Be 'worker-2'
        $script:task789Receipt.routing.matched_rule | Should -Not -BeNullOrEmpty
        Should -Invoke Add-OrchestraPane -Times 1
    }

    It 'E03 public --slot-id spawn initializes route and emits routing.matched_rule' {
        $null = New-Item -ItemType File -Path (Join-Path $script:task789FixRoot '.winsmux.yaml') -Force
        $script:task789SpawnedSlots = @()
        $script:task789SubmittedLabel = ''
        $script:task789Receipt = $null
        $script:task789Worker2Live = $false
        Mock Get-OrchestraModeDocument {
            [pscustomobject]@{ schema_version = 1; mode = 'team'; valid = $true; source = 'file' }
        }
        Mock Get-OrchestraLiveWorkerRolePaneCount { 1 }
        Mock Get-OrchestraMaxLiveWorkerPaneCount { 6 }
        Mock Get-WinsmuxManifest {
            [pscustomobject]@{
                Panes = [ordered]@{
                    'worker-1' = [pscustomobject]@{ pane_id = '%3'; role = 'Worker' }
                }
            }
        }
        Mock Get-PaneControlManifestEntries {
            $entries = @(script:New-Task789LiveEntry -Label 'worker-1' -PaneId '%3')
            if ($script:task789Worker2Live) {
                $entries += script:New-Task789LiveEntry -Label 'worker-2' -PaneId '%5'
            }
            return $entries
        }
        Mock Get-DispatchTaskCatalogSlotIds { @('worker-1', 'worker-2') }
        Mock Get-BridgeSettings {
            [ordered]@{
                agent_slots = @(
                    [pscustomobject]@{ slot_id = 'worker-1'; runtime_role = 'worker'; worker_role = 'impl' }
                    [pscustomobject]@{ slot_id = 'worker-2'; runtime_role = 'worker'; worker_role = 'impl' }
                )
            }
        }
        Mock Invoke-TeamProfileLaunchProjection {
            [pscustomobject]@{
                bundle_path = '.winsmux/team-profile/worker-2.md'
                projection  = [pscustomobject]@{
                    pane = [pscustomobject]@{
                        assignment = [pscustomobject]@{ provider = 'codex'; launch_model = 'gpt-5.4'; worker_backend = 'codex' }
                    }
                }
            }
        }
        Mock New-TeamProfileSlotAgentConfig {
            [pscustomobject]@{ Agent = 'codex'; Model = 'gpt-5.4'; WorkerBackend = 'codex'; PaneTitle = $SlotId }
        }
        Mock Add-OrchestraPane {
            $script:task789SpawnedSlots += [string]$SlotId
            $script:task789Worker2Live = $true
            return [pscustomobject]@{ Changed = $true; Label = $SlotId; PaneId = '%5' }
        }
        Mock Test-PaneControlRuntimeContext {
            [pscustomobject]@{
                valid       = $true
                reason_code = 'dispatch_verified'
                diagnostic  = 'ok'
                context     = [ordered]@{ generation_id = 'generation-789' }
            }
        }
        Mock Start-DeferredPaneFromManifestEntry { $false }
        Mock Invoke-WinsmuxSubmissionAdapter {
            param($ProjectDir, $ManifestEntry, $Kind, $Content, $SubmissionId)
            $script:task789SubmittedLabel = [string]$ManifestEntry.Label
            return [pscustomobject]@{
                protocol_version = 1
                submission_id    = $SubmissionId
                kind             = 'task'
                status           = 'accepted'
                backend          = 'codex'
                reason_code      = ''
                diagnostic       = ''
                target           = [ordered]@{ label = [string]$ManifestEntry.Label; pane_id = [string]$ManifestEntry.PaneId; role = 'Worker' }
                routing          = $null
                acknowledgement  = $null
            }
        }
        Mock ConvertTo-WinsmuxSubmissionReceiptJson {
            param($Receipt)
            $script:task789Receipt = $Receipt
            return ($Receipt | ConvertTo-Json -Compress -Depth 8)
        }

        { script:Invoke-Task789PublicDispatchTask -Argv @(
            '--slot-id', 'worker-2', '--project-dir', $script:task789FixRoot, 'implement the focused change'
        ) } | Should -Not -Throw

        $script:task789SpawnedSlots | Should -Be @('worker-2')
        $script:task789SubmittedLabel | Should -Be 'worker-2'
        $script:task789Receipt.routing.matched_rule | Should -Not -BeNullOrEmpty
        $script:task789Receipt.routing.expected_owner | Should -Be 'Worker'
    }

    It 'E04 public --slot-id on a live worker does not spawn and still initializes route' {
        $null = New-Item -ItemType File -Path (Join-Path $script:task789FixRoot '.winsmux.yaml') -Force
        $script:task789SpawnedSlots = @()
        $script:task789SubmittedLabel = ''
        $script:task789Receipt = $null
        Mock Get-OrchestraModeDocument {
            [pscustomobject]@{ schema_version = 1; mode = 'team'; valid = $true; source = 'file' }
        }
        Mock Get-OrchestraLiveWorkerRolePaneCount { 1 }
        Mock Get-OrchestraMaxLiveWorkerPaneCount { 6 }
        Mock Get-WinsmuxManifest {
            [pscustomobject]@{
                Panes = [ordered]@{
                    'worker-1' = [pscustomobject]@{ pane_id = '%3'; role = 'Worker' }
                }
            }
        }
        Mock Get-BridgeSettings {
            [ordered]@{
                agent_slots = @(
                    [pscustomobject]@{ slot_id = 'worker-1'; runtime_role = 'worker'; worker_role = 'impl' }
                    [pscustomobject]@{ slot_id = 'worker-2'; runtime_role = 'worker'; worker_role = 'impl' }
                )
            }
        }
        Mock Get-PaneControlManifestEntries {
            @(script:New-Task789LiveEntry -Label 'worker-1' -PaneId '%3')
        }
        Mock Get-DispatchTaskManifestEntry {
            param($ProjectDir, $Label)
            if ([string]$Label -eq 'worker-1') {
                return (script:New-Task789LiveEntry -Label 'worker-1' -PaneId '%3')
            }
            return $null
        }
        Mock Get-DispatchTaskCatalogSlotIds { @('worker-1', 'worker-2') }
        Mock Invoke-TeamProfileLaunchProjection { throw 'E04 must not project a live slot' }
        Mock Add-OrchestraPane {
            $script:task789SpawnedSlots += [string]$SlotId
            throw 'E04 must not spawn a second pane for a live slot'
        }
        Mock Test-PaneControlRuntimeContext {
            [pscustomobject]@{
                valid       = $true
                reason_code = 'dispatch_verified'
                diagnostic  = 'ok'
                context     = [ordered]@{ generation_id = 'generation-789' }
            }
        }
        Mock Start-DeferredPaneFromManifestEntry { $false }
        Mock Invoke-WinsmuxSubmissionAdapter {
            param($ProjectDir, $ManifestEntry, $Kind, $Content, $SubmissionId)
            $script:task789SubmittedLabel = [string]$ManifestEntry.Label
            return [pscustomobject]@{
                protocol_version = 1
                submission_id    = $SubmissionId
                kind             = 'task'
                status           = 'accepted'
                backend          = 'codex'
                reason_code      = ''
                diagnostic       = ''
                target           = [ordered]@{ label = [string]$ManifestEntry.Label; pane_id = [string]$ManifestEntry.PaneId; role = 'Worker' }
                routing          = $null
                acknowledgement  = $null
            }
        }
        Mock ConvertTo-WinsmuxSubmissionReceiptJson {
            param($Receipt)
            $script:task789Receipt = $Receipt
            return ($Receipt | ConvertTo-Json -Compress -Depth 8)
        }

        $null = script:Invoke-Task789PublicDispatchTask -Argv @(
            '--slot-id', 'worker-1', '--project-dir', $script:task789FixRoot, 'implement the focused change'
        )

        $script:task789SpawnedSlots | Should -Be @()
        $script:task789SubmittedLabel | Should -Be 'worker-1'
        $script:task789Receipt | Should -Not -BeNullOrEmpty
        $script:task789Receipt.routing.matched_rule | Should -Not -BeNullOrEmpty
        Should -Invoke Add-OrchestraPane -Times 0
    }

    It 'E02 public dispatch-task at the live worker cap does not spawn' {
        $script:task789SpawnedSlots = @()
        $script:task789SubmittedLabel = ''
        Mock Get-OrchestraModeDocument {
            [pscustomobject]@{ schema_version = 1; mode = 'team'; valid = $true; source = 'file' }
        }
        Mock Get-OrchestraLiveWorkerRolePaneCount { 6 }
        Mock Get-OrchestraMaxLiveWorkerPaneCount { 6 }
        Mock Get-WinsmuxManifest {
            [pscustomobject]@{
                Panes = [ordered]@{
                    'worker-1' = [pscustomobject]@{ pane_id = '%3'; role = 'Worker' }
                    'worker-2' = [pscustomobject]@{ pane_id = '%4'; role = 'Worker' }
                    'worker-3' = [pscustomobject]@{ pane_id = '%5'; role = 'Worker' }
                    'worker-4' = [pscustomobject]@{ pane_id = '%6'; role = 'Worker' }
                    'worker-5' = [pscustomobject]@{ pane_id = '%7'; role = 'Worker' }
                    'worker-6' = [pscustomobject]@{ pane_id = '%8'; role = 'Worker' }
                }
            }
        }
        Mock Get-PaneControlManifestEntries {
            @(
                script:New-Task789LiveEntry -Label 'worker-1' -PaneId '%3'
                script:New-Task789LiveEntry -Label 'worker-2' -PaneId '%4'
                script:New-Task789LiveEntry -Label 'worker-3' -PaneId '%5'
                script:New-Task789LiveEntry -Label 'worker-4' -PaneId '%6'
                script:New-Task789LiveEntry -Label 'worker-5' -PaneId '%7'
                script:New-Task789LiveEntry -Label 'worker-6' -PaneId '%8'
            )
        }
        Mock Get-DispatchTaskCatalogSlotIds { @('worker-1', 'worker-2', 'worker-3', 'worker-4', 'worker-5', 'worker-6') }
        Mock Add-OrchestraPane { throw 'E02 must not spawn when live workers are at max' }
        Mock Test-PaneControlRuntimeContext {
            [pscustomobject]@{
                valid       = $true
                reason_code = 'dispatch_verified'
                diagnostic  = 'ok'
                context     = [ordered]@{ generation_id = 'generation-789' }
            }
        }
        Mock Start-DeferredPaneFromManifestEntry { $false }
        Mock Invoke-WinsmuxSubmissionAdapter {
            param($ProjectDir, $ManifestEntry, $Kind, $Content, $SubmissionId)
            $script:task789SubmittedLabel = [string]$ManifestEntry.Label
            return [pscustomobject]@{
                protocol_version = 1
                submission_id    = $SubmissionId
                kind             = 'task'
                status           = 'accepted'
                backend          = 'codex'
                reason_code      = ''
                diagnostic       = ''
                target           = [ordered]@{ label = [string]$ManifestEntry.Label; pane_id = [string]$ManifestEntry.PaneId; role = 'Worker' }
                routing          = $null
                acknowledgement  = $null
            }
        }
        Mock ConvertTo-WinsmuxSubmissionReceiptJson {
            param($Receipt)
            return ($Receipt | ConvertTo-Json -Compress -Depth 8)
        }

        $null = script:Invoke-Task789PublicDispatchTask -Argv @(
            '--project-dir', $script:task789FixRoot, 'implement the focused change'
        )

        $script:task789SpawnedSlots | Should -Be @()
        $script:task789SubmittedLabel | Should -Match '^worker-\d+$'
        Should -Invoke Add-OrchestraPane -Times 0
    }

    It 'E05 public simple mode does not spawn a second live worker-role pane' {
        $null = New-Item -ItemType File -Path (Join-Path $script:task789FixRoot '.winsmux.yaml') -Force
        $script:task789SpawnedSlots = @()
        $script:task789SubmittedLabel = ''
        Mock Get-OrchestraModeDocument {
            [pscustomobject]@{ schema_version = 1; mode = 'simple'; valid = $true; source = 'file' }
        }
        Mock Get-OrchestraLiveWorkerRolePaneCount { 1 }
        Mock Get-OrchestraMaxLiveWorkerPaneCount { 1 }
        Mock Get-WinsmuxManifest {
            [pscustomobject]@{
                Panes = [ordered]@{
                    'worker-1' = [pscustomobject]@{ pane_id = '%3'; role = 'Worker' }
                }
            }
        }
        Mock Get-PaneControlManifestEntries {
            @(script:New-Task789LiveEntry -Label 'worker-1' -PaneId '%3')
        }
        Mock Get-DispatchTaskCatalogSlotIds { @('worker-1', 'worker-2') }
        Mock Get-BridgeSettings {
            [ordered]@{
                agent_slots = @(
                    [pscustomobject]@{ slot_id = 'worker-1'; runtime_role = 'worker'; worker_role = 'impl' }
                    [pscustomobject]@{ slot_id = 'worker-2'; runtime_role = 'worker'; worker_role = 'impl' }
                )
            }
        }
        Mock Add-OrchestraPane {
            $script:task789SpawnedSlots += [string]$SlotId
            throw 'E05 must not spawn a second simple-mode worker'
        }
        Mock Test-PaneControlRuntimeContext {
            [pscustomobject]@{
                valid       = $true
                reason_code = 'dispatch_verified'
                diagnostic  = 'ok'
                context     = [ordered]@{ generation_id = 'generation-789' }
            }
        }
        Mock Start-DeferredPaneFromManifestEntry { $false }
        Mock Invoke-WinsmuxSubmissionAdapter {
            param($ProjectDir, $ManifestEntry, $Kind, $Content, $SubmissionId)
            $script:task789SubmittedLabel = [string]$ManifestEntry.Label
            return [pscustomobject]@{
                protocol_version = 1
                submission_id    = $SubmissionId
                kind             = 'task'
                status           = 'accepted'
                backend          = 'codex'
                reason_code      = ''
                diagnostic       = ''
                target           = [ordered]@{ label = [string]$ManifestEntry.Label; pane_id = [string]$ManifestEntry.PaneId; role = 'Worker' }
                routing          = $null
                acknowledgement  = $null
            }
        }
        Mock ConvertTo-WinsmuxSubmissionReceiptJson {
            param($Receipt)
            return ($Receipt | ConvertTo-Json -Compress -Depth 8)
        }

        $null = script:Invoke-Task789PublicDispatchTask -Argv @(
            '--project-dir', $script:task789FixRoot, 'implement the focused change'
        )

        $script:task789SpawnedSlots | Should -Be @()
        $script:task789SubmittedLabel | Should -Be 'worker-1'
        Should -Invoke Add-OrchestraPane -Times 0
    }

    It 'E08 public spawn launch command attaches the Team Profile bundle from the same projection' {
        $null = New-Item -ItemType File -Path (Join-Path $script:task789FixRoot '.winsmux.yaml') -Force
        $script:task789BundleCalls = @()
        $script:task789LaunchCommands = @()
        $script:task789SubmittedLabel = ''
        $script:task789Worker2Live = $false
        $projection = [pscustomobject]@{
            bundle_path = '.winsmux/team-profile/worker-2.md'
            projection  = [pscustomobject]@{
                pane = [pscustomobject]@{
                    assignment    = [pscustomobject]@{ provider = 'codex'; launch_model = 'gpt-5.4'; worker_backend = 'codex' }
                    prompt_bundle = [pscustomobject]@{ path = '.winsmux/team-profile/worker-2.md' }
                }
            }
        }
        Mock Get-OrchestraModeDocument {
            [pscustomobject]@{ schema_version = 1; mode = 'team'; valid = $true; source = 'file' }
        }
        Mock Get-OrchestraLiveWorkerRolePaneCount { 1 }
        Mock Get-OrchestraMaxLiveWorkerPaneCount { 6 }
        Mock Get-WinsmuxManifest {
            [pscustomobject]@{
                Panes = [ordered]@{
                    'worker-1' = [pscustomobject]@{ pane_id = '%3'; role = 'Worker' }
                }
            }
        }
        Mock Get-PaneControlManifestEntries {
            $entries = @(script:New-Task789LiveEntry -Label 'worker-1' -PaneId '%3')
            if ($script:task789Worker2Live) {
                $entries += script:New-Task789LiveEntry -Label 'worker-2' -PaneId '%5'
            }
            return $entries
        }
        Mock Get-DispatchTaskCatalogSlotIds { @('worker-1', 'worker-2') }
        Mock Invoke-TeamProfileLaunchProjection { $projection }
        Mock New-TeamProfileSlotAgentConfig {
            [pscustomobject]@{ Agent = 'codex'; Model = 'gpt-5.4'; WorkerBackend = 'codex'; PaneTitle = $SlotId }
        }
        Mock Add-TeamProfileBundleToLaunchCommand {
            param($LaunchCommand, $Projection, $ProjectDir)
            $script:task789BundleCalls += [pscustomobject]@{
                LaunchCommand = [string]$LaunchCommand
                BundlePath    = [string]$Projection.bundle_path
                ProjectDir    = [string]$ProjectDir
            }
            $script:task789LaunchCommands += ([string]$LaunchCommand + ' TEAM-PROFILE-BUNDLE')
            return ($LaunchCommand + ' TEAM-PROFILE-BUNDLE')
        }
        Mock Add-OrchestraWorkerPane {
            param($ManifestPath, $SlotId, $Settings, $SlotAgentConfig, $Assignment, $Projection)
            if ($null -eq $Projection -or [string]::IsNullOrWhiteSpace([string]$Projection.bundle_path)) {
                throw 'E08 spawn must receive the Team Profile projection'
            }
            $null = Add-TeamProfileBundleToLaunchCommand -LaunchCommand 'echo spawn-worker-2' -Projection $Projection -ProjectDir $script:task789FixRoot
            $script:task789Worker2Live = $true
            return [pscustomobject]@{ Changed = $true; Label = $SlotId; PaneId = '%5' }
        }
        Mock Test-PaneControlRuntimeContext {
            [pscustomobject]@{
                valid       = $true
                reason_code = 'dispatch_verified'
                diagnostic  = 'ok'
                context     = [ordered]@{ generation_id = 'generation-789' }
            }
        }
        Mock Start-DeferredPaneFromManifestEntry { $false }
        Mock Invoke-WinsmuxSubmissionAdapter {
            param($ProjectDir, $ManifestEntry, $Kind, $Content, $SubmissionId)
            $script:task789SubmittedLabel = [string]$ManifestEntry.Label
            return [pscustomobject]@{
                protocol_version = 1
                submission_id    = $SubmissionId
                kind             = 'task'
                status           = 'accepted'
                backend          = 'codex'
                reason_code      = ''
                diagnostic       = ''
                target           = [ordered]@{ label = [string]$ManifestEntry.Label; pane_id = [string]$ManifestEntry.PaneId; role = 'Worker' }
                routing          = $null
                acknowledgement  = $null
            }
        }
        Mock ConvertTo-WinsmuxSubmissionReceiptJson {
            param($Receipt)
            return ($Receipt | ConvertTo-Json -Compress -Depth 8)
        }

        $null = script:Invoke-Task789PublicDispatchTask -Argv @(
            '--slot-id', 'worker-2', '--project-dir', $script:task789FixRoot, 'implement the focused change'
        )

        $script:task789SubmittedLabel | Should -Be 'worker-2'
        $script:task789BundleCalls.Count | Should -BeGreaterThan 0
        $script:task789BundleCalls[0].BundlePath | Should -Be '.winsmux/team-profile/worker-2.md'
        $script:task789LaunchCommands[0] | Should -Match 'TEAM-PROFILE-BUNDLE'
    }

    It 'E08 Add-OrchestraWorkerPane launch command calls Add-TeamProfileBundleToLaunchCommand' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $supervisor = script:Get-Task789SupervisorIdentity
        script:Write-Task789V2Manifest -Path $manifestPath -ProjectDir $script:task789FixRoot -Panes @(
            script:New-Task789V2Pane -Label 'worker-1' -PaneId '%3'
        )
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid $supervisor.Pid `
            -SupervisorProcessStartedAt $supervisor.StartedAt -ExpectedPaneCount 1 -LeaseSeconds 300 `
            -Panes @(script:New-Task789V2RegistryPane -Label 'worker-1' -PaneId '%3' -BootstrapPid 4200)
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null
        $script:task789Observed = @(
            script:New-Task789ObservedPane -PaneId '%1' -Title 'bootstrap'
            script:New-Task789ObservedPane -PaneId '%3' -Title 'worker-1'
        )
        $script:task789BundleCalls = @()
        script:Mock-Task789LiveServer
        $worktreePath = Join-Path $script:task789FixRoot '.worktrees\worker-2'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        $projection = [pscustomobject]@{
            bundle_path = '.winsmux/team-profile/worker-2.md'
            projection  = [pscustomobject]@{
                pane = [pscustomobject]@{
                    prompt_bundle = [pscustomobject]@{ path = '.winsmux/team-profile/worker-2.md' }
                }
            }
        }
        Mock New-PaneScalerWorkerWorktree {
            [pscustomobject]@{ WorktreePath = $worktreePath; BranchName = 'worktree-worker-2'; GitWorktreeDir = $worktreePath }
        }
        Mock Invoke-MonitorWinsmux {
            param($Arguments)
            $argsList = @($Arguments)
            if ($argsList -contains 'split-window') {
                $script:task789Observed = @($script:task789Observed) + @(
                    script:New-Task789ObservedPane -PaneId '%5' -Title 'worker-2'
                )
                return '%5'
            }
            if ($argsList -contains 'select-pane') { return }
        }
        Mock Wait-MonitorPaneShellReady { }
        Mock Get-PaneScalerLaunchCommand { 'echo spawn-worker-2' }
        Mock Add-TeamProfileBundleToLaunchCommand {
            param($LaunchCommand, $Projection, $ProjectDir)
            $script:task789BundleCalls += [pscustomobject]@{
                LaunchCommand = [string]$LaunchCommand
                BundlePath    = [string]$Projection.bundle_path
                ProjectDir    = [string]$ProjectDir
            }
            return ($LaunchCommand + ' TEAM-PROFILE-BUNDLE')
        }
        Mock New-OrchestraPaneBootstrapPlan {
            param($LaunchCommand)
            $script:task789CapturedLaunch = [string]$LaunchCommand
            $planDir = Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap'
            New-Item -ItemType Directory -Path $planDir -Force | Out-Null
            $planPath = Join-Path $planDir '5.json'
            Set-Content -LiteralPath $planPath -Value '{}' -Encoding utf8
            return $planPath
        }
        Mock Get-OrchestraPaneBootstrapMarkerPath {
            Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap\5-generation-789.ready.json'
        }
        Mock Start-OrchestraPaneBootstrap { }
        Mock Get-BridgeSettings { [ordered]@{ agent = 'codex'; model = 'gpt-5.4' } }

        $result = Add-OrchestraWorkerPane -ManifestPath $manifestPath -SlotId 'worker-2' -SlotAgentConfig ([pscustomobject]@{
            Agent = 'codex'; Model = 'gpt-5.4'; WorkerBackend = 'codex'; PaneTitle = 'worker-2'
        }) -Projection $projection
        $result.Changed | Should -BeTrue
        $script:task789BundleCalls.Count | Should -Be 1
        $script:task789BundleCalls[0].BundlePath | Should -Be '.winsmux/team-profile/worker-2.md'
        $script:task789CapturedLaunch | Should -Match 'TEAM-PROFILE-BUNDLE'
        $saved = Read-PaneScalerManifest -ManifestPath $manifestPath
        $saved.version | Should -Be 2
        $saved.Session.expected_pane_count | Should -Be 2
    }

    It 'TASK-789 empty agent_slots still exposes the resolved six-slot catalog' {
        Mock Get-BridgeSettings {
            [ordered]@{ agent_slots = @() }
        }
        Mock Get-DispatchTaskResolvedTeamSlots {
            @('worker-1', 'worker-2', 'worker-3', 'worker-4', 'worker-5', 'worker-6')
        }
        $ids = @(Get-DispatchTaskCatalogSlotIds -ProjectDir $script:task789FixRoot)
        $ids.Count | Should -Be 6
        $ids[0] | Should -Be 'worker-1'
        $ids[5] | Should -Be 'worker-6'
    }

    It 'TASK-789 regenerates Team Profile projection after the spawned worktree exists' {
        $manifestPath = Join-Path $script:task789FixRoot '.winsmux\manifest.yaml'
        $supervisor = script:Get-Task789SupervisorIdentity
        script:Write-Task789V2Manifest -Path $manifestPath -ProjectDir $script:task789FixRoot -Panes @(
            script:New-Task789V2Pane -Label 'worker-1' -PaneId '%3'
        )
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-orchestra' -ServerSessionId '$9' `
            -BootstrapPaneId '%1' -GenerationId 'generation-789' -SupervisorPid $supervisor.Pid `
            -SupervisorProcessStartedAt $supervisor.StartedAt -ExpectedPaneCount 1 -LeaseSeconds 300 `
            -Panes @(script:New-Task789V2RegistryPane -Label 'worker-1' -PaneId '%3' -BootstrapPid 4200)
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task789FixRoot -Registry $registry | Out-Null
        $script:task789Observed = @(
            script:New-Task789ObservedPane -PaneId '%1' -Title 'bootstrap'
            script:New-Task789ObservedPane -PaneId '%3' -Title 'worker-1'
        )
        $script:task789BundleCalls = @()
        $script:task789ProjectionWorktrees = @()
        script:Mock-Task789LiveServer
        $worktreePath = Join-Path $script:task789FixRoot '.worktrees\worker-2'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        Mock New-PaneScalerWorkerWorktree {
            [pscustomobject]@{ WorktreePath = $worktreePath; BranchName = 'worktree-worker-2'; GitWorktreeDir = $worktreePath }
        }
        Mock Invoke-TeamProfileLaunchProjection {
            param($ProjectDir, $SessionId, $SlotId, $Worktree, $ReadWriteScope, [switch]$Force)
            $script:task789ProjectionWorktrees += [string]$Worktree
            return [pscustomobject]@{
                bundle_path = '.winsmux/team-profile/worker-2.md'
                worktree    = [string]$Worktree
                projection  = [pscustomobject]@{
                    pane = [pscustomobject]@{
                        prompt_bundle = [pscustomobject]@{ path = '.winsmux/team-profile/worker-2.md' }
                    }
                }
            }
        }
        Mock Invoke-MonitorWinsmux {
            param($Arguments)
            $argsList = @($Arguments)
            if ($argsList -contains 'split-window') {
                $script:task789Observed = @($script:task789Observed) + @(
                    script:New-Task789ObservedPane -PaneId '%5' -Title 'worker-2'
                )
                return '%5'
            }
            if ($argsList -contains 'select-pane') { return }
        }
        Mock Wait-MonitorPaneShellReady { }
        Mock Get-PaneScalerLaunchCommand { 'echo spawn-worker-2' }
        Mock Add-TeamProfileBundleToLaunchCommand {
            param($LaunchCommand, $Projection, $ProjectDir)
            $script:task789BundleCalls += [pscustomobject]@{
                LaunchCommand = [string]$LaunchCommand
                BundlePath    = [string]$Projection.bundle_path
                Worktree      = [string]$Projection.worktree
            }
            return ($LaunchCommand + ' TEAM-PROFILE-BUNDLE')
        }
        Mock New-OrchestraPaneBootstrapPlan {
            param($LaunchCommand)
            $script:task789CapturedLaunch = [string]$LaunchCommand
            $planDir = Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap'
            New-Item -ItemType Directory -Path $planDir -Force | Out-Null
            $planPath = Join-Path $planDir '5.json'
            Set-Content -LiteralPath $planPath -Value '{}' -Encoding utf8
            return $planPath
        }
        Mock Get-OrchestraPaneBootstrapMarkerPath {
            Join-Path $script:task789FixRoot '.winsmux\orchestra-bootstrap\5-generation-789.ready.json'
        }
        Mock Start-OrchestraPaneBootstrap { }
        Mock Get-BridgeSettings { [ordered]@{ agent = 'codex'; model = 'gpt-5.4' } }

        $stale = [pscustomobject]@{ bundle_path = 'stale'; worktree = '' }
        $result = Add-OrchestraWorkerPane -ManifestPath $manifestPath -SlotId 'worker-2' -SlotAgentConfig ([pscustomobject]@{
            Agent = 'codex'; Model = 'gpt-5.4'; WorkerBackend = 'codex'; PaneTitle = 'worker-2'
        }) -Projection $stale
        $result.Changed | Should -BeTrue
        $script:task789ProjectionWorktrees.Count | Should -Be 1
        $script:task789ProjectionWorktrees[0] | Should -Be $worktreePath
        $script:task789BundleCalls[0].Worktree | Should -Be $worktreePath
    }

    It 'E09 Get-DispatchTaskAvailableTargets still excludes reviewer-only live slots after catalog union' {
        Mock Get-OrchestraModeDocument {
            [pscustomobject]@{ schema_version = 1; mode = 'team'; valid = $true; source = 'file' }
        }
        Mock Get-OrchestraLiveWorkerRolePaneCount { 1 }
        Mock Get-OrchestraMaxLiveWorkerPaneCount { 6 }
        Mock Get-PaneControlManifestEntries {
            @(
                [PSCustomObject]@{ Label = 'worker-1'; PaneId = '%1'; Role = 'Worker'; WorkerRole = 'reviewer'; AgentRole = '' },
                [PSCustomObject]@{ Label = 'worker-2'; PaneId = '%2'; Role = 'Worker'; WorkerRole = 'impl'; AgentRole = '' }
            )
        }
        Mock Get-DispatchTaskCatalogSlotIds { @('worker-2', 'worker-3') }
        Mock Get-BridgeSettings {
            [ordered]@{
                agent_slots = @(
                    [pscustomobject]@{ slot_id = 'worker-1'; runtime_role = 'worker'; worker_role = 'reviewer' }
                    [pscustomobject]@{ slot_id = 'worker-2'; runtime_role = 'worker'; worker_role = 'impl' }
                    [pscustomobject]@{ slot_id = 'worker-3'; runtime_role = 'worker'; worker_role = 'impl' }
                )
            }
        }
        $null = New-Item -ItemType File -Path (Join-Path $script:task789FixRoot '.winsmux.yaml') -Force

        $targets = @(Get-DispatchTaskAvailableTargets -ProjectDir $script:task789FixRoot)
        $targets | Should -Contain 'worker-2'
        $targets | Should -Contain 'worker-3'
        $targets | Should -Not -Contain 'worker-1'
    }
}
