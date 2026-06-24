$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'v0.36.20 coordinator foundation gate' {
    BeforeAll {
        $script:repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:repoRoot)) {
            throw 'Failed to resolve repository root.'
        }
        $script:gateScript = Join-Path $script:repoRoot 'scripts/test-v03620-coordinator-foundation.ps1'
        $script:routerScript = Join-Path $script:repoRoot 'winsmux-core/scripts/coordinator-router.ps1'
    }

    It 'passes the static coordinator foundation gate' {
        $output = & pwsh -NoProfile -File $script:gateScript -Json
        $LASTEXITCODE | Should -Be 0
        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result['all_pass'] | Should -Be $true
        $result['failed_count'] | Should -Be 0
        [int]$result['check_count'] | Should -BeGreaterThan 25
    }

    It 'builds a privacy-safe versioned RouteContext without raw prompt material' {
        . $script:routerScript

        $context = New-WinsmuxRouteContext `
            -TaskId 'TASK-599' `
            -TaskType 'implementation' `
            -Goal 'Add coordinator route context' `
            -Priority 'P0' `
            -RequestedRole 'Worker' `
            -ReadScope @('docs/project/v03620-coordinator-foundation.md') `
            -WriteScope @('winsmux-core/scripts/coordinator-router.ps1') `
            -Slots @(
                [ordered]@{ slot = 'worker-1'; provider = 'claude'; roles = @('Thinker', 'Verifier'); state = 'ready'; capabilities = @('review'); backend = 'local' },
                [ordered]@{ slot = 'worker-2'; provider = 'codex'; roles = @('Worker'); state = 'ready'; capabilities = @('implementation'); backend = 'codex' }
            ) `
            -PreviousRoutes @() `
            -RemainingTurns 5 `
            -RawPrompt 'private credential marker and local path marker'

        $context.schema_version | Should -Be 1
        $context.policy_revision | Should -Be 'v03620'
        $context.task.task_id | Should -Be 'TASK-599'
        $context.scope.write | Should -Contain 'winsmux-core/scripts/coordinator-router.ps1'
        ($context | ConvertTo-Json -Depth 10) | Should -Not -Match 'credential marker'
        ($context | ConvertTo-Json -Depth 10) | Should -Not -Match 'local path marker'
        ($context | ConvertTo-Json -Depth 10) | Should -Not -Match 'RawPrompt'
        $context.redaction.redacted_fields | Should -Contain 'raw_prompt'
    }

    It 'routes deterministically while excluding unavailable and conflicting slots' {
        . $script:routerScript

        $context = New-WinsmuxRouteContext `
            -TaskId 'TASK-600' `
            -TaskType 'implementation' `
            -Goal 'Implement deterministic router' `
            -Priority 'P0' `
            -RequestedRole 'Worker' `
            -ReadScope @('docs/project/v03620-coordinator-foundation.md') `
            -WriteScope @('winsmux-core/scripts/coordinator-router.ps1') `
            -Slots @(
                [ordered]@{ slot = 'worker-1'; provider = 'claude'; roles = @('Worker'); state = 'offline'; capabilities = @('implementation'); backend = 'local' },
                [ordered]@{ slot = 'worker-2'; provider = 'codex'; roles = @('Worker'); state = 'ready'; capabilities = @('implementation'); backend = 'codex'; active_write_scope = @('winsmux-core/scripts/coordinator-router.ps1') },
                [ordered]@{ slot = 'worker-3'; provider = 'codex'; roles = @('Worker', 'Verifier'); state = 'ready'; capabilities = @('implementation', 'review'); backend = 'codex' }
            ) `
            -PreviousRoutes @() `
            -RemainingTurns 5

        $decision = Invoke-WinsmuxDeterministicRoute -Context $context

        $decision.schema_version | Should -Be 1
        $decision.decision.slot | Should -Be 'worker-3'
        $decision.decision.role | Should -Be 'Worker'
        $decision.excluded.slot | Should -Contain 'worker-1'
        $decision.excluded.slot | Should -Contain 'worker-2'
        $decision.excluded.reason | Should -Contain 'slot_unavailable'
        $decision.excluded.reason | Should -Contain 'write_scope_conflict'
        $decision.decision.confidence | Should -BeGreaterOrEqual 0.5
    }

    It 'prefers review-capable Verifier slots and avoids repeating a failed route' {
        . $script:routerScript

        $context = New-WinsmuxRouteContext `
            -TaskId 'TASK-601' `
            -TaskType 'verification' `
            -Goal 'Verify coordinator contract' `
            -Priority 'P0' `
            -RequestedRole 'Verifier' `
            -ReadScope @('winsmux-core/scripts/coordinator-router.ps1') `
            -WriteScope @() `
            -Slots @(
                [ordered]@{ slot = 'worker-1'; provider = 'codex'; roles = @('Worker', 'Verifier'); state = 'ready'; capabilities = @('implementation'); backend = 'codex' },
                [ordered]@{ slot = 'worker-2'; provider = 'claude'; roles = @('Verifier'); state = 'ready'; capabilities = @('review', 'verification'); backend = 'local' }
            ) `
            -PreviousRoutes @([ordered]@{ slot = 'worker-1'; role = 'Verifier'; outcome = 'failed'; failure_class = 'model' }) `
            -RemainingTurns 4

        $decision = Invoke-WinsmuxDeterministicRoute -Context $context

        $decision.decision.slot | Should -Be 'worker-2'
        $decision.decision.role | Should -Be 'Verifier'
        $decision.excluded.slot | Should -Contain 'worker-1'
        $decision.excluded.reason | Should -Contain 'failed_route_retry_blocked'
    }

    It 'evaluates offline router baselines without calling live providers' {
        . $script:routerScript

        $cases = @(
            [ordered]@{
                id = 'case-implementation'
                expected_slot = 'worker-2'
                context = New-WinsmuxRouteContext -TaskId 'TASK-600' -TaskType 'implementation' -Goal 'Implement route' -Priority 'P0' -RequestedRole 'Worker' -ReadScope @() -WriteScope @('a.ps1') -Slots @(
                    [ordered]@{ slot = 'worker-1'; provider = 'claude'; roles = @('Verifier'); state = 'ready'; capabilities = @('review') },
                    [ordered]@{ slot = 'worker-2'; provider = 'codex'; roles = @('Worker'); state = 'ready'; capabilities = @('implementation') }
                ) -PreviousRoutes @() -RemainingTurns 5
            },
            [ordered]@{
                id = 'case-verifier'
                expected_slot = 'worker-1'
                context = New-WinsmuxRouteContext -TaskId 'TASK-601' -TaskType 'verification' -Goal 'Verify route' -Priority 'P0' -RequestedRole 'Verifier' -ReadScope @('a.ps1') -WriteScope @() -Slots @(
                    [ordered]@{ slot = 'worker-1'; provider = 'claude'; roles = @('Verifier'); state = 'ready'; capabilities = @('review', 'verification') },
                    [ordered]@{ slot = 'worker-2'; provider = 'codex'; roles = @('Worker'); state = 'ready'; capabilities = @('implementation') }
                ) -PreviousRoutes @() -RemainingTurns 5
            }
        )

        $evaluation = Invoke-WinsmuxOfflineRouteEvaluator -Cases $cases

        $evaluation.schema_version | Should -Be 1
        $evaluation.provider_calls | Should -Be 0
        $evaluation.baselines.Keys | Should -Contain 'deterministic_capability_router'
        $evaluation.baselines.Keys | Should -Contain 'strongest_single_slot'
        $evaluation.baselines.Keys | Should -Contain 'round_robin'
        $evaluation.baselines.Keys | Should -Contain 'random_seeded'
        $evaluation.baselines.Keys | Should -Contain 'static_task_type_rule'
        $evaluation.metrics.success_rate | Should -BeGreaterThan 0
    }
}
