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
            $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $tempRoot -ManifestEntry $entry -Kind review -Content 'review synthetic change' -SubmissionId 'submission-test-4' `
                -SendAction { param($paneId, $commandText) $script:apiLlmCommand = $commandText } `
                -RunResultAction { param($projectDir, $slotId, $runId) [ordered]@{ status = 'failed'; reason = 'runner_rejected_packet'; exit_code = 1; run_id = $runId } }

            $receipt.status | Should -Be 'rejected'
            $receipt.reason_code | Should -Be 'runner_rejected_packet'
        $script:apiLlmCommand | Should -Match '^exec \.winsmux[\\/]submissions[\\/]submission-test-4\.json$'
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
            $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $tempRoot -ManifestEntry $entry -Kind review -Content 'review synthetic input' -SubmissionId 'submission-test-7' `
                -CliRunAction { param($projectDir, $slotId, $packetPath, $submissionId) New-WinsmuxSubmissionRunRecord -SubmissionId $submissionId -RunId $submissionId -Kind review -TaskTitle 'Review test' -SlotId $slotId -Backend antigravity -Status started -RequestConsumed -RequestDigest (Get-WinsmuxSubmissionRequestDigest -Request 'review synthetic input') }

            $receipt.status | Should -Be 'accepted'
            $receipt.acknowledgement.type | Should -Be 'backend_run_record'
            $receipt.acknowledgement.run_id | Should -Be 'submission-test-7'
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
