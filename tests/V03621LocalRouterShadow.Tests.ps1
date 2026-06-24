$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'v0.36.21 local router shadow mode gate' {
    BeforeAll {
        $script:repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:repoRoot)) {
            throw 'Failed to resolve repository root.'
        }
        $script:gateScript = Join-Path $script:repoRoot 'scripts/test-v03621-local-router-shadow.ps1'
        $script:routerScript = Join-Path $script:repoRoot 'winsmux-core/scripts/coordinator-router.ps1'
        $script:shadowScript = Join-Path $script:repoRoot 'winsmux-core/scripts/local-router-shadow.ps1'
        $script:manifestPath = Join-Path $script:repoRoot 'winsmux-core/router/local-small-router-v03621.manifest.json'
        $script:newTestRouteContext = {
            . $script:routerScript

            New-WinsmuxRouteContext `
                -TaskId 'TASK-605' `
                -TaskType 'implementation' `
                -Goal 'Implement local router shadow evidence' `
                -Priority 'P0' `
                -RequestedRole 'Worker' `
                -ReadScope @('docs/project/v03621-local-router-shadow.md') `
                -WriteScope @('winsmux-core/scripts/local-router-shadow.ps1') `
                -Slots @(
                    [ordered]@{ slot = 'worker-1'; provider = 'claude'; roles = @('Verifier'); state = 'ready'; capabilities = @('review', 'verification'); backend = 'local' },
                    [ordered]@{ slot = 'worker-2'; provider = 'codex'; roles = @('Worker'); state = 'ready'; capabilities = @('implementation', 'coding'); backend = 'codex' },
                    [ordered]@{ slot = 'worker-3'; provider = 'antigravity'; roles = @('Worker'); state = 'offline'; capabilities = @('implementation'); backend = 'antigravity' },
                    [ordered]@{ slot = 'worker-4'; provider = 'grok-build'; roles = @('Worker'); state = 'ready'; capabilities = @('implementation', 'research'); backend = 'local' },
                    [ordered]@{ slot = 'worker-5'; provider = 'openrouter'; roles = @('Worker'); state = 'setup-required'; capabilities = @('implementation'); backend = 'api_llm' },
                    [ordered]@{ slot = 'worker-6'; provider = 'openrouter'; roles = @('Worker'); state = 'ready'; capabilities = @('implementation', 'analysis'); backend = 'api_llm' }
                ) `
                -PreviousRoutes @() `
                -RemainingTurns 5 `
                -RawPrompt 'private local prompt must not be retained'
        }
    }

    It 'passes the static v0.36.21 router shadow gate' {
        $output = & pwsh -NoProfile -File $script:gateScript -Json
        $LASTEXITCODE | Should -Be 0
        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result['all_pass'] | Should -Be $true
        $result['failed_count'] | Should -Be 0
        [int]$result['check_count'] | Should -BeGreaterThan 30
    }

    It 'pins the local router artifact by manifest and weights hash' {
        . $script:shadowScript

        $artifact = Resolve-WinsmuxLocalRouterArtifact -ManifestPath $script:manifestPath

        $artifact.manifest.schema_version | Should -Be 1
        $artifact.manifest.artifact_id | Should -Be 'winsmux-local-router-shadow-v03621'
        $artifact.manifest.policy_revision | Should -Be 'v03621'
        $artifact.manifest.execution_mode | Should -Be 'shadow_only'
        $artifact.manifest.provider_calls_allowed | Should -BeFalse
        $artifact.manifest.auto_update_allowed | Should -BeFalse
        $artifact.manifest.weights_sha256 | Should -Be $artifact.weights_sha256
        $artifact.manifest.license | Should -Be 'Apache-2.0 AND MIT'
    }

    It 'fails closed for unsafe or tampered local router artifacts' {
        . $script:shadowScript

        $sourceManifest = Get-Content -LiteralPath $script:manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sourceWeightsPath = Join-Path (Split-Path -Parent $script:manifestPath) ([string]$sourceManifest.weights_path)
        $safeManifestPath = Join-Path $TestDrive 'safe-manifest.json'
        $safeWeightsPath = Join-Path $TestDrive ([string]$sourceManifest.weights_path)
        Copy-Item -LiteralPath $sourceWeightsPath -Destination $safeWeightsPath

        $badPathManifest = $sourceManifest.PSObject.Copy()
        $badPathManifest.weights_path = '..\outside.weights.json'
        $badPathManifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $safeManifestPath -Encoding UTF8
        { Resolve-WinsmuxLocalRouterArtifact -ManifestPath $safeManifestPath } |
            Should -Throw '*must stay under the router artifact directory*'

        $badPolicyManifest = $sourceManifest.PSObject.Copy()
        $badPolicyManifest.provider_calls_allowed = $true
        $badPolicyManifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $safeManifestPath -Encoding UTF8
        { Resolve-WinsmuxLocalRouterArtifact -ManifestPath $safeManifestPath } |
            Should -Throw '*must not allow provider calls*'

        $badHashManifest = $sourceManifest.PSObject.Copy()
        $badHashManifest.weights_sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
        $badHashManifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $safeManifestPath -Encoding UTF8
        { Resolve-WinsmuxLocalRouterArtifact -ManifestPath $safeManifestPath } |
            Should -Throw '*weights hash mismatch*'
    }

    It 'produces six slot logits and three role logits without changing execution authority' {
        . $script:routerScript
        . $script:shadowScript

        $context = & $script:newTestRouteContext
        $result = Invoke-WinsmuxLocalRouterShadow -Context $context -ManifestPath $script:manifestPath

        $result.schema_version | Should -Be 1
        $result.kind | Should -Be 'winsmux.local_router_shadow_decision'
        $result.mode | Should -Be 'shadow'
        $result.execution_authority | Should -Be 'deterministic_fallback'
        $result.provider_calls | Should -Be 0
        @($result.logits.slot_logits).Count | Should -Be 6
        @($result.logits.role_logits).Count | Should -Be 3
        @($result.availability_mask | Where-Object { $_.available }).slot | Should -Not -Contain 'worker-3'
        @($result.availability_mask | Where-Object { $_.available }).slot | Should -Not -Contain 'worker-5'
        $result.proposal.slot | Should -Not -Be 'worker-3'
        $result.proposal.slot | Should -Not -Be 'worker-5'
        $result.final_authority.slot | Should -Be $result.fallback_decision.decision.slot
        $result.shadow_only | Should -BeTrue
    }

    It 'is deterministic for the same sanitized context and artifact' {
        . $script:routerScript
        . $script:shadowScript

        $context = & $script:newTestRouteContext
        $first = Invoke-WinsmuxLocalRouterShadow -Context $context -ManifestPath $script:manifestPath
        $second = Invoke-WinsmuxLocalRouterShadow -Context $context -ManifestPath $script:manifestPath

        ($first | ConvertTo-Json -Depth 20 -Compress) | Should -Be ($second | ConvertTo-Json -Depth 20 -Compress)
    }

    It 'falls back deterministically when confidence is below the margin threshold' {
        . $script:routerScript
        . $script:shadowScript

        $context = & $script:newTestRouteContext
        $result = Invoke-WinsmuxLocalRouterShadow -Context $context -ManifestPath $script:manifestPath -MinimumMargin 99

        $result.fallback_required | Should -BeTrue
        $result.final_authority.slot | Should -Be $result.fallback_decision.decision.slot
        $result.final_authority.action | Should -Be $result.fallback_decision.decision.action
        $result.proposal.action | Should -Be 'shadow_proposal_only'
    }

    It 'falls back deterministically when confidence is below the threshold' {
        . $script:routerScript
        . $script:shadowScript

        $context = & $script:newTestRouteContext
        $result = Invoke-WinsmuxLocalRouterShadow -Context $context -ManifestPath $script:manifestPath -MinimumConfidence 1.0

        $result.fallback_required | Should -BeTrue
        $result.final_authority.slot | Should -Be $result.fallback_decision.decision.slot
        $result.final_authority.action | Should -Be $result.fallback_decision.decision.action
    }

    It 'falls back deterministically when no slot can be proposed' {
        . $script:routerScript
        . $script:shadowScript

        $emptyContext = New-WinsmuxRouteContext `
            -TaskId 'TASK-606' `
            -TaskType 'implementation' `
            -Goal 'Handle empty worker availability' `
            -Priority 'P0' `
            -RequestedRole 'Worker' `
            -ReadScope @('docs/project/v03621-local-router-shadow.md') `
            -WriteScope @('winsmux-core/scripts/local-router-shadow.ps1') `
            -Slots @() `
            -PreviousRoutes @() `
            -RemainingTurns 1 `
            -RawPrompt 'private prompt must not be retained'

        $emptyResult = Invoke-WinsmuxLocalRouterShadow -Context $emptyContext -ManifestPath $script:manifestPath

        $emptyResult.proposal.slot | Should -BeNullOrEmpty
        $emptyResult.fallback_required | Should -BeTrue
        $emptyResult.final_authority.action | Should -Be 'handle_locally'
        @($emptyResult.logits.slot_logits).Count | Should -Be 0

        $offlineContext = New-WinsmuxRouteContext `
            -TaskId 'TASK-606-OFFLINE' `
            -TaskType 'implementation' `
            -Goal 'Handle unavailable worker availability' `
            -Priority 'P0' `
            -RequestedRole 'Worker' `
            -ReadScope @('docs/project/v03621-local-router-shadow.md') `
            -WriteScope @('winsmux-core/scripts/local-router-shadow.ps1') `
            -Slots @(
                [ordered]@{ slot = 'worker-1'; provider = 'codex'; roles = @('Worker'); state = 'offline'; capabilities = @('implementation'); backend = 'local' }
            ) `
            -PreviousRoutes @() `
            -RemainingTurns 1 `
            -RawPrompt 'private prompt must not be retained'

        $offlineResult = Invoke-WinsmuxLocalRouterShadow -Context $offlineContext -ManifestPath $script:manifestPath

        $offlineResult.proposal.slot | Should -BeNullOrEmpty
        $offlineResult.fallback_required | Should -BeTrue
        $offlineResult.final_authority.action | Should -Be 'handle_locally'
        @($offlineResult.logits.slot_logits | Where-Object { $_.available }).Count | Should -Be 0
        @($offlineResult.logits.slot_logits).probability | Should -Not -Contain 1.0
    }

    It 'rejects trace writes for non-shadow decisions or sensitive content' {
        . $script:shadowScript

        $tracePath = Join-Path $TestDrive 'shadow.jsonl'
        { Write-WinsmuxLocalRouterShadowTrace -ShadowDecision ([ordered]@{ kind = 'winsmux.route_decision' }) -Path $tracePath } |
            Should -Throw '*only accepts local router shadow decision objects*'

        $sensitiveDecision = [ordered]@{
            kind       = 'winsmux.local_router_shadow_decision'
            raw_prompt = 'private prompt must not be written'
        }
        { Write-WinsmuxLocalRouterShadowTrace -ShadowDecision $sensitiveDecision -Path $tracePath } |
            Should -Throw '*rejected sensitive shadow decision content*'
    }

    It 'reports resource and privacy profile without raw prompt or provider metadata' {
        . $script:routerScript
        . $script:shadowScript

        $profile = Measure-WinsmuxLocalRouterShadowProfile -Cases @(
            [ordered]@{ id = 'fixture-implementation'; context = & $script:newTestRouteContext },
            [ordered]@{ id = 'fixture-repeat'; context = & $script:newTestRouteContext }
        ) -ManifestPath $script:manifestPath

        $profile.provider_calls | Should -Be 0
        $profile.gpu_required | Should -BeFalse
        $profile.raw_prompt_stored | Should -BeFalse
        $profile.max_workspace_write_bytes | Should -Be 0
        $profile.case_count | Should -Be 2
        ($profile | ConvertTo-Json -Depth 12) | Should -Not -Match 'private local prompt'
        ($profile | ConvertTo-Json -Depth 12) | Should -Not -Match 'OPENROUTER_API_KEY|ANTHROPIC_API_KEY|provider_request'
    }
}
