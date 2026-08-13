#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('Task810ExactStringArgumentAttribute' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Management.Automation;
public sealed class Task810ExactStringArgumentAttribute : ValidateArgumentsAttribute
{
    protected override void Validate(object arguments, EngineIntrinsics engineIntrinsics)
    {
        if (arguments == null || arguments.GetType() != typeof(string))
        {
            throw new ValidationMetadataException(
                "ShardId must be an exact System.String argument (whole-argument validation).");
        }
    }
}
"@
}

function New-WinsmuxPesterMatrixRow {
    param(
        [Parameter(Mandatory)][int] $Ordinal,
        [Parameter(Mandatory)][string] $ShardId,
        [Parameter(Mandatory)][int] $TimeoutMinutes,
        [Parameter(Mandatory)][string[]] $TestPaths,
        [Parameter(Mandatory)][string] $ResultFile
    )
    return [pscustomobject][ordered]@{
        ordinal            = [int]$Ordinal
        shard_id           = [string]$ShardId
        job_kind           = [string]'matrix'
        timeout_minutes    = [int]$TimeoutMinutes
        test_paths         = [string[]]@($TestPaths)
        selector_identity  = [string]''
        result_file        = [string]$ResultFile
    }
}

function New-WinsmuxPesterDesktopRow {
    param(
        [Parameter(Mandatory)][int] $Ordinal,
        [Parameter(Mandatory)][string] $ShardId,
        [Parameter(Mandatory)][string[]] $TestPaths,
        [Parameter(Mandatory)][string] $ResultFile
    )
    return [pscustomobject][ordered]@{
        ordinal           = [int]$Ordinal
        shard_id          = [string]$ShardId
        job_kind          = [string]'Desktop'
        test_paths        = [string[]]@($TestPaths)
        selector_identity = [string]''
        result_file       = [string]$ResultFile
    }
}

function Get-WinsmuxPesterShardRegistry {
    [CmdletBinding()]
    param()

    # Fresh 26-row registry matching activation architecture §7 / current test.yml topology.
    @(
        (New-WinsmuxPesterMatrixRow -Ordinal 1 -ShardId 'bridge-foundation' -TimeoutMinutes 15 -TestPaths @(
            'tests/bridge/Foundation.Tests.ps1'
            'tests/bridge/Foundation.Settings.Tests.ps1'
        ) -ResultFile 'test-results-bridge-foundation.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 2 -ShardId 'bridge-agent-orchestra' -TimeoutMinutes 20 -TestPaths @(
            'tests/bridge/AgentOrchestra.Tests.ps1'
            'tests/bridge/AgentOrchestra.Bootstrap.Tests.ps1'
        ) -ResultFile 'test-results-bridge-agent-orchestra.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 3 -ShardId 'bridge-command-status' -TimeoutMinutes 12 -TestPaths @(
            'tests/bridge/CommandStatus.Tests.ps1'
            'tests/bridge/CommandStatus.RuntimeIdentity.Tests.ps1'
        ) -ResultFile 'test-results-bridge-command-status.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 4 -ShardId 'bridge-worker-workspace-sandbox' -TimeoutMinutes 12 -TestPaths @(
            'tests/bridge/WorkerWorkspaceSandbox.Tests.ps1'
        ) -ResultFile 'test-results-bridge-worker-workspace-sandbox.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 5 -ShardId 'bridge-worker-broker-token' -TimeoutMinutes 12 -TestPaths @(
            'tests/bridge/WorkerBrokerToken.Tests.ps1'
        ) -ResultFile 'test-results-bridge-worker-broker-token.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 6 -ShardId 'bridge-worker-policy' -TimeoutMinutes 12 -TestPaths @(
            'tests/bridge/WorkerPolicy.Tests.ps1'
        ) -ResultFile 'test-results-bridge-worker-policy.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 7 -ShardId 'bridge-worker-secrets-status' -TimeoutMinutes 12 -TestPaths @(
            'tests/bridge/WorkerSecretsStatus.Tests.ps1'
        ) -ResultFile 'test-results-bridge-worker-secrets-status.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 8 -ShardId 'bridge-worker-heartbeat-start' -TimeoutMinutes 12 -TestPaths @(
            'tests/bridge/WorkerHeartbeatStart.Tests.ps1'
        ) -ResultFile 'test-results-bridge-worker-heartbeat-start.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 9 -ShardId 'bridge-worker-api-agy-exec' -TimeoutMinutes 12 -TestPaths @(
            'tests/bridge/WorkerApiAgyExec.Tests.ps1'
        ) -ResultFile 'test-results-bridge-worker-api-agy-exec.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 10 -ShardId 'bridge-command-queue-reporting' -TimeoutMinutes 12 -TestPaths @(
            'tests/bridge/CommandQueueReporting.Tests.ps1'
        ) -ResultFile 'test-results-bridge-command-queue-reporting.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 11 -ShardId 'bridge-command-review-dispatch' -TimeoutMinutes 12 -TestPaths @(
            'tests/bridge/CommandReviewDispatch.Tests.ps1'
        ) -ResultFile 'test-results-bridge-command-review-dispatch.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 12 -ShardId 'bridge-provider-commands' -TimeoutMinutes 15 -TestPaths @(
            'tests/bridge/ProviderCommands.Tests.ps1'
            'tests/bridge/ProviderCommands.Dispatch.Tests.ps1'
        ) -ResultFile 'test-results-bridge-provider-commands.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 13 -ShardId 'bridge-artifacts-runtime' -TimeoutMinutes 15 -TestPaths @(
            'tests/bridge/ArtifactsRuntime.Tests.ps1'
            'tests/bridge/ArtifactsRuntime.Operator.Tests.ps1'
        ) -ResultFile 'test-results-bridge-artifacts-runtime.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 14 -ShardId 'integration' -TimeoutMinutes 25 -TestPaths @(
            'tests/Integration.GateEnforcement.Tests.ps1'
            'tests/Integration.MultiAgent.Tests.ps1'
            'tests/Integration.PaneMonitorHook.Tests.ps1'
            'tests/Integration.PluginHookLoader.Tests.ps1'
            'tests/Integration.WorktreeHook.Tests.ps1'
            'tests/Task839WorktreeReviewState.Tests.ps1'
            'tests/V03630DesktopDebugGate.Tests.ps1'
            'tests/DeclarativeWorkflow.Tests.ps1'
            'tests/Task810PesterRunner.Tests.ps1'
            'tests/Task800OperatorShellBoundary.Tests.ps1'
        ) -ResultFile 'test-results-integration.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 15 -ShardId 'worker-benchmark' -TimeoutMinutes 20 -TestPaths @(
            'tests/CliBakeoff.Tests.ps1'
            'tests/HarnessContract.Tests.ps1'
            'tests/Runtime.VaultInject.Tests.ps1'
        ) -ResultFile 'test-results-worker-benchmark.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 16 -ShardId 'release-public' -TimeoutMinutes 20 -TestPaths @(
            'tests/PublicSurfacePolicy.Tests.ps1'
            'tests/VersionSurface.Tests.ps1'
            'tests/NpmReleasePackage.Tests.ps1'
            'tests/GitHubWritePreflight.Tests.ps1'
            'tests/McpServerContract.Tests.ps1'
            'tests/ThreatModelContract.Tests.ps1'
            'tests/EnterpriseStrategyAlignment.Tests.ps1'
            'tests/ReviewLatencyHardening.Tests.ps1'
            'tests/UpstreamReevaluation.Tests.ps1'
        ) -ResultFile 'test-results-release-public.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 17 -ShardId 'shell-support' -TimeoutMinutes 15 -TestPaths @(
            'tests/BuilderWorktree.Tests.ps1'
            'tests/codex-subagent-worktree-guard.Tests.ps1'
            'tests/OrchestraPreflight.Tests.ps1'
            'tests/PaneBorder.Tests.ps1'
            'tests/V03618ReleaseHardening.Tests.ps1'
            'tests/AgentReadiness.Tests.ps1'
            'tests/GitGuard.Tests.ps1'
        ) -ResultFile 'test-results-shell-support.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 18 -ShardId 'repo-audit-v03619' -TimeoutMinutes 12 -TestPaths @(
            'tests/V03619RepoAudit.Tests.ps1'
        ) -ResultFile 'test-results-repo-audit-v03619.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 19 -ShardId 'coordinator-v03620' -TimeoutMinutes 12 -TestPaths @(
            'tests/V03620CoordinatorFoundation.Tests.ps1'
        ) -ResultFile 'test-results-coordinator-v03620.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 20 -ShardId 'local-router-v03621' -TimeoutMinutes 12 -TestPaths @(
            'tests/V03621LocalRouterShadow.Tests.ps1'
        ) -ResultFile 'test-results-local-router-v03621.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 21 -ShardId 'desktop-split-v03626' -TimeoutMinutes 12 -TestPaths @(
            'tests/V03626DesktopSplitGate.Tests.ps1'
        ) -ResultFile 'test-results-desktop-split-v03626.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 22 -ShardId 'compat-performance-v03627' -TimeoutMinutes 12 -TestPaths @(
            'tests/V03627CompatPerformanceGate.Tests.ps1'
            'tests/Task781RuntimeCompatibility.Tests.ps1'
        ) -ResultFile 'test-results-compat-performance-v03627.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 23 -ShardId 'race-abnormal-soak-v03628' -TimeoutMinutes 12 -TestPaths @(
            'tests/V03628RaceAbnormalSoak.Tests.ps1'
        ) -ResultFile 'test-results-race-abnormal-soak-v03628.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 24 -ShardId 'runtime-reliability-v03628' -TimeoutMinutes 12 -TestPaths @(
            'tests/V03628RuntimeReliabilityGate.Tests.ps1'
        ) -ResultFile 'test-results-runtime-reliability-v03628.xml')
        (New-WinsmuxPesterMatrixRow -Ordinal 25 -ShardId 'packaged-restore-v03628' -TimeoutMinutes 12 -TestPaths @(
            'tests/V03628PackagedRestoreGate.Tests.ps1'
        ) -ResultFile 'test-results-packaged-restore-v03628.xml')
        (New-WinsmuxPesterDesktopRow -Ordinal 26 -ShardId 'desktop-debug-process' -TestPaths @(
            'tests/V03630DesktopDebugGateProcess.Tests.ps1'
        ) -ResultFile 'test-results-desktop-debug-v03630.xml')
    )
}

function Find-WinsmuxPesterShardMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [Task810ExactStringArgument()]
        [object] $ShardId
    )

    $caller = [string]$ShardId
    $comparer = [System.StringComparer]::OrdinalIgnoreCase
    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @(Get-WinsmuxPesterShardRegistry)) {
        if ($comparer.Equals([string]$row.shard_id, $caller)) {
            # Fresh row copy so callers cannot mutate canonical registry data.
            if ($row.job_kind -eq 'matrix') {
                $matched.Add((New-WinsmuxPesterMatrixRow -Ordinal ([int]$row.ordinal) -ShardId ([string]$row.shard_id) -TimeoutMinutes ([int]$row.timeout_minutes) -TestPaths ([string[]]$row.test_paths) -ResultFile ([string]$row.result_file))) | Out-Null
            } else {
                $matched.Add((New-WinsmuxPesterDesktopRow -Ordinal ([int]$row.ordinal) -ShardId ([string]$row.shard_id) -TestPaths ([string[]]$row.test_paths) -ResultFile ([string]$row.result_file))) | Out-Null
            }
        }
    }

    return [pscustomobject][ordered]@{
        caller_shard_id = $caller
        match_count     = [int]$matched.Count
        matches         = [object[]]@($matched.ToArray())
    }
}

function Resolve-WinsmuxPester571 {
    [CmdletBinding()]
    param()

    try {
        $paths = [System.Collections.Generic.List[string]]::new()
        $modules = @(Get-Module -ListAvailable -Name Pester -ErrorAction SilentlyContinue)
        foreach ($moduleInfo in $modules) {
            if ($null -eq $moduleInfo) { continue }
            if ([string]$moduleInfo.Name -cne 'Pester') { continue }
            $versionText = [string]$moduleInfo.Version
            if ($versionText -cne '5.7.1') { continue }

            $manifest = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$moduleInfo.Path) -and ([string]$moduleInfo.Path).EndsWith('Pester.psd1', [System.StringComparison]::OrdinalIgnoreCase)) {
                $manifest = [System.IO.Path]::GetFullPath([string]$moduleInfo.Path)
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$moduleInfo.ModuleBase)) {
                $manifest = [System.IO.Path]::GetFullPath((Join-Path ([string]$moduleInfo.ModuleBase) 'Pester.psd1'))
            }
            if ([string]::IsNullOrWhiteSpace($manifest)) { continue }
            if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }

            $duplicate = $false
            foreach ($existing in $paths) {
                if ([System.StringComparer]::Ordinal.Equals($existing, $manifest)) {
                    $duplicate = $true
                    break
                }
            }
            if (-not $duplicate) {
                $paths.Add($manifest) | Out-Null
            }
        }

        if ($paths.Count -eq 0) {
            return [pscustomobject][ordered]@{
                resolution_status = [string]'missing'
                manifest_path     = [string]''
                name              = [string]''
                semantic_version  = [string]''
                module_base       = [string]''
            }
        }
        if ($paths.Count -gt 1) {
            return [pscustomobject][ordered]@{
                resolution_status = [string]'ambiguous'
                manifest_path     = [string]''
                name              = [string]''
                semantic_version  = [string]''
                module_base       = [string]''
            }
        }

        $selected = [string]$paths[0]
        return [pscustomobject][ordered]@{
            resolution_status = [string]'resolved'
            manifest_path     = $selected
            name              = [string]'Pester'
            semantic_version  = [string]'5.7.1'
            module_base       = [string]([System.IO.Path]::GetDirectoryName($selected))
        }
    } catch {
        return [pscustomobject][ordered]@{
            resolution_status = [string]'runtime_failure'
            manifest_path     = [string]''
            name              = [string]''
            semantic_version  = [string]''
            module_base       = [string]''
        }
    }
}

Export-ModuleMember -Function @(
    'Get-WinsmuxPesterShardRegistry'
    'Find-WinsmuxPesterShardMatch'
    'Resolve-WinsmuxPester571'
)