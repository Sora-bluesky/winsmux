Set-StrictMode -Version Latest

$script:WinsmuxPesterShardRegistry = @(
    [pscustomobject][ordered]@{ shard_id = 'bridge-foundation'; paths = @('tests/bridge/Foundation.Tests.ps1', 'tests/bridge/Foundation.Settings.Tests.ps1'); full_name = ''; result_file = 'test-results-bridge-foundation.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'bridge-agent-orchestra'; paths = @('tests/bridge/AgentOrchestra.Tests.ps1', 'tests/bridge/AgentOrchestra.Bootstrap.Tests.ps1'); full_name = ''; result_file = 'test-results-bridge-agent-orchestra.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'bridge-command-status'; paths = @('tests/bridge/CommandStatus.Tests.ps1', 'tests/bridge/CommandStatus.RuntimeIdentity.Tests.ps1'); full_name = ''; result_file = 'test-results-bridge-command-status.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'bridge-worker-workspace-sandbox'; paths = @('tests/bridge/WorkerWorkspaceSandbox.Tests.ps1'); full_name = ''; result_file = 'test-results-bridge-worker-workspace-sandbox.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'bridge-worker-broker-token'; paths = @('tests/bridge/WorkerBrokerToken.Tests.ps1'); full_name = ''; result_file = 'test-results-bridge-worker-broker-token.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'bridge-worker-policy'; paths = @('tests/bridge/WorkerPolicy.Tests.ps1'); full_name = ''; result_file = 'test-results-bridge-worker-policy.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'bridge-worker-secrets-status'; paths = @('tests/bridge/WorkerSecretsStatus.Tests.ps1'); full_name = ''; result_file = 'test-results-bridge-worker-secrets-status.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'bridge-worker-heartbeat-start'; paths = @('tests/bridge/WorkerHeartbeatStart.Tests.ps1'); full_name = ''; result_file = 'test-results-bridge-worker-heartbeat-start.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'bridge-worker-api-agy-exec'; paths = @('tests/bridge/WorkerApiAgyExec.Tests.ps1'); full_name = ''; result_file = 'test-results-bridge-worker-api-agy-exec.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'bridge-command-queue-reporting'; paths = @('tests/bridge/CommandQueueReporting.Tests.ps1'); full_name = ''; result_file = 'test-results-bridge-command-queue-reporting.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'bridge-command-review-dispatch'; paths = @('tests/bridge/CommandReviewDispatch.Tests.ps1'); full_name = ''; result_file = 'test-results-bridge-command-review-dispatch.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'bridge-provider-commands'; paths = @('tests/bridge/ProviderCommands.Tests.ps1', 'tests/bridge/ProviderCommands.Dispatch.Tests.ps1'); full_name = ''; result_file = 'test-results-bridge-provider-commands.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'bridge-artifacts-runtime'; paths = @('tests/bridge/ArtifactsRuntime.Tests.ps1', 'tests/bridge/ArtifactsRuntime.Operator.Tests.ps1'); full_name = ''; result_file = 'test-results-bridge-artifacts-runtime.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'integration'; paths = @('tests/Integration.GateEnforcement.Tests.ps1', 'tests/Integration.MultiAgent.Tests.ps1', 'tests/Integration.PaneMonitorHook.Tests.ps1', 'tests/Integration.PluginHookLoader.Tests.ps1', 'tests/Integration.WorktreeHook.Tests.ps1', 'tests/Task839WorktreeReviewState.Tests.ps1', 'tests/V03630DesktopDebugGate.Tests.ps1', 'tests/Task810PesterRunner.Tests.ps1'); full_name = ''; result_file = 'test-results-integration.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'worker-benchmark'; paths = @('tests/CliBakeoff.Tests.ps1', 'tests/HarnessContract.Tests.ps1', 'tests/Runtime.VaultInject.Tests.ps1'); full_name = ''; result_file = 'test-results-worker-benchmark.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'release-public'; paths = @('tests/PublicSurfacePolicy.Tests.ps1', 'tests/VersionSurface.Tests.ps1', 'tests/NpmReleasePackage.Tests.ps1', 'tests/GitHubWritePreflight.Tests.ps1', 'tests/McpServerContract.Tests.ps1', 'tests/ThreatModelContract.Tests.ps1', 'tests/EnterpriseStrategyAlignment.Tests.ps1', 'tests/ReviewLatencyHardening.Tests.ps1', 'tests/UpstreamReevaluation.Tests.ps1'); full_name = ''; result_file = 'test-results-release-public.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'shell-support'; paths = @('tests/BuilderWorktree.Tests.ps1', 'tests/codex-subagent-worktree-guard.Tests.ps1', 'tests/OrchestraPreflight.Tests.ps1', 'tests/PaneBorder.Tests.ps1', 'tests/V03618ReleaseHardening.Tests.ps1', 'tests/AgentReadiness.Tests.ps1'); full_name = ''; result_file = 'test-results-shell-support.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'repo-audit-v03619'; paths = @('tests/V03619RepoAudit.Tests.ps1'); full_name = ''; result_file = 'test-results-repo-audit-v03619.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'coordinator-v03620'; paths = @('tests/V03620CoordinatorFoundation.Tests.ps1'); full_name = ''; result_file = 'test-results-coordinator-v03620.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'local-router-v03621'; paths = @('tests/V03621LocalRouterShadow.Tests.ps1'); full_name = ''; result_file = 'test-results-local-router-v03621.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'desktop-split-v03626'; paths = @('tests/V03626DesktopSplitGate.Tests.ps1'); full_name = ''; result_file = 'test-results-desktop-split-v03626.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'compat-performance-v03627'; paths = @('tests/V03627CompatPerformanceGate.Tests.ps1'); full_name = ''; result_file = 'test-results-compat-performance-v03627.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'race-abnormal-soak-v03628'; paths = @('tests/V03628RaceAbnormalSoak.Tests.ps1'); full_name = ''; result_file = 'test-results-race-abnormal-soak-v03628.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'runtime-reliability-v03628'; paths = @('tests/V03628RuntimeReliabilityGate.Tests.ps1'); full_name = ''; result_file = 'test-results-runtime-reliability-v03628.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'packaged-restore-v03628'; paths = @('tests/V03628PackagedRestoreGate.Tests.ps1'); full_name = ''; result_file = 'test-results-packaged-restore-v03628.xml'; job_kind = 'matrix' }
    [pscustomobject][ordered]@{ shard_id = 'desktop-debug-process'; paths = @('tests/V03630DesktopDebugGateProcess.Tests.ps1'); full_name = ''; result_file = 'test-results-desktop-debug-v03630.xml'; job_kind = 'desktop' }
)

function Get-WinsmuxPesterShardRegistry {
    [OutputType([pscustomobject])]
    param()

    return $script:WinsmuxPesterShardRegistry
}

function Resolve-WinsmuxPesterShard {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ShardId
    )

    if ($ShardId.Length -eq 0) {
        return [pscustomobject][ordered]@{ status = 'empty'; shard = $null }
    }

    $matches = @(
        foreach ($candidate in $script:WinsmuxPesterShardRegistry) {
            if ([System.StringComparer]::OrdinalIgnoreCase.Equals($candidate.shard_id, $ShardId)) {
                $candidate
            }
        }
    )

    if ($matches.Count -eq 0) {
        return [pscustomobject][ordered]@{ status = 'unknown'; shard = $null }
    }

    if ($matches.Count -gt 1) {
        return [pscustomobject][ordered]@{ status = 'duplicate'; shard = $null }
    }

    return [pscustomobject][ordered]@{ status = 'resolved'; shard = $matches[0] }
}

function Resolve-WinsmuxPesterModule {
    [OutputType([pscustomobject])]
    param()

    $absent = [pscustomobject][ordered]@{
        present = $false
        name = ''
        semantic_version = ''
        manifest_path = ''
    }

    try {
        $manifestPaths = @()
        foreach ($candidate in @(Get-Module -ListAvailable -Name Pester -ErrorAction Stop)) {
            if ($candidate.Name -ne 'Pester' -or $candidate.Version -ne [version]'5.7.1') {
                continue
            }

            $manifestPath = Join-Path -Path $candidate.ModuleBase -ChildPath 'Pester.psd1'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                continue
            }

            $normalizedPath = (Resolve-Path -LiteralPath $manifestPath -ErrorAction Stop).Path
            if (-not $manifestPaths.Where({ [System.StringComparer]::OrdinalIgnoreCase.Equals($_, $normalizedPath) }).Count) {
                $manifestPaths += $normalizedPath
            }
        }

        if ($manifestPaths.Count -eq 0) {
            return [pscustomobject][ordered]@{ status = 'missing'; selected_module = $absent }
        }

        if ($manifestPaths.Count -ne 1) {
            return [pscustomobject][ordered]@{ status = 'ambiguous'; selected_module = $absent }
        }

        return [pscustomobject][ordered]@{
            status = 'resolved'
            selected_module = [pscustomobject][ordered]@{
                present = $true
                name = 'Pester'
                semantic_version = '5.7.1'
                manifest_path = $manifestPaths[0]
            }
        }
    } catch {
        return [pscustomobject][ordered]@{ status = 'runtime_failure'; selected_module = $absent }
    }
}

Export-ModuleMember -Function Get-WinsmuxPesterShardRegistry, Resolve-WinsmuxPesterShard, Resolve-WinsmuxPesterModule
