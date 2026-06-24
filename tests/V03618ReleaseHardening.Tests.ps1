$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'v0.36.18 release hardening gate' {
    BeforeAll {
        $script:repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:repoRoot)) {
            throw 'Failed to resolve repository root.'
        }
        $script:gateScript = Join-Path $script:repoRoot 'scripts/test-v03618-release-hardening.ps1'
        $script:winsmuxCorePath = Join-Path $script:repoRoot 'scripts/winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    It 'passes the static anti-loop and lifecycle gate' {
        $output = & pwsh -NoProfile -File $script:gateScript -Json
        $LASTEXITCODE | Should -Be 0
        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result['all_pass'] | Should -Be $true
        $result['failed_count'] | Should -Be 0
        [int]$result['check_count'] | Should -BeGreaterThan 20
    }

    It 'opens the scope circuit breaker after the two-strike retry limit' {
        $run = [pscustomobject]@{
            action_items          = @()
            phase_gate            = [ordered]@{}
            draft_pr_gate         = [ordered]@{}
            tdd_gate              = [ordered]@{}
            verification_result   = [ordered]@{ outcome = 'FAIL'; summary = 'verification failed' }
            security_verdict      = [ordered]@{ verdict = 'ALLOW' }
            verification_evidence = [ordered]@{ context_pressure = 'low' }
            pane_count            = 6
            changed_file_count    = 1
        }
        $events = @(
            [ordered]@{
                event   = 'pipeline.verify.fail'
                message = 'retry required'
                status  = 'FAIL'
                data    = [ordered]@{ next_action = 'rerun_verify'; attempt = 1 }
            },
            [ordered]@{
                event   = 'pipeline.verify.fail'
                message = 'retry required again'
                status  = 'FAIL'
                data    = [ordered]@{ next_action = 'retry'; attempt = 2 }
            }
        )

        $insights = New-RunInsightsContract -Run $run -EventRecords $events

        $insights['claim_level'] | Should -Be 'blocked'
        $insights['loop_control']['two_strike_limit'] | Should -Be 2
        $insights['loop_control']['one_hypothesis_one_change_required'] | Should -Be $true
        $insights['loop_control']['stop_required'] | Should -Be $true
        $insights['loop_control']['stop_reasons'] | Should -Contain 'two_strike_retry_limit_reached'
        $insights['scope_circuit_breaker']['state'] | Should -Be 'open'
        $insights['scope_circuit_breaker']['auto_continue'] | Should -Be $false
    }

    It 'marks a complete verification envelope as verified but never auto-mergeable' {
        $run = [pscustomobject]@{
            run_id                 = 'task:TASK-596'
            task_id                = 'TASK-596'
            verification_result    = [ordered]@{ outcome = 'PASS'; summary = 'focused gates passed'; next_action = 'release_gate' }
            verification_evidence  = [ordered]@{ context_pressure = 'low' }
            audit_chain            = [ordered]@{
                chain_id = 'audit-v03618'
                approval = [ordered]@{ state = 'approved'; stages = @() }
                events = @([ordered]@{ event = 'operator.review_passed' })
            }
            review_required        = $true
            review_state           = 'PASS'
            security_verdict       = [ordered]@{ verdict = 'ALLOW'; reason = '' }
            draft_pr_gate          = [ordered]@{ state = 'passed' }
            phase_gate             = [ordered]@{}
            architecture_contract  = [ordered]@{ score_regression = $false; baseline = [ordered]@{ review_required_on_drift = $true } }
            context_contract       = [ordered]@{}
            verification_plan      = @('Invoke-Pester tests/V03618ReleaseHardening.Tests.ps1')
            changed_files          = @('scripts/winsmux-core.ps1')
            last_event             = 'operator.review_passed'
        }

        $envelope = New-RunVerificationEnvelope -Run $run

        $envelope['claim_level'] | Should -Be 'verified'
        $envelope['release_decision']['claim_level'] | Should -Be 'verified'
        $envelope['release_decision']['status'] | Should -Be 'approved'
        $envelope['release_decision']['automatic_merge_allowed'] | Should -Be $false
        $envelope['dynamic_gates']['verification']['evidence_complete'] | Should -Be $true
    }
}
