$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:RepositoryRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$script:ModulePath = Join-Path $script:RepositoryRoot 'scripts/winsmux-pester.psm1'
$script:RunnerPath = Join-Path $script:RepositoryRoot 'scripts/run-pester-shard.ps1'
$script:WorkflowPath = Join-Path $script:RepositoryRoot '.github/workflows/test.yml'
$script:RunTestsPath = Join-Path $script:RepositoryRoot 'scripts/run-tests.ps1'
$script:CoverageValidatorPath = Join-Path $script:RepositoryRoot 'scripts/assert-pester-shard-coverage.ps1'

$script:ExportedCommands = @(
    'Get-WinsmuxPesterShardRegistry',
    'Resolve-WinsmuxPesterShard',
    'Resolve-WinsmuxPesterModule'
)

$script:EnvelopeRootKeys = @(
    'schema_version',
    'shard_id',
    'resolution_status',
    'execution_status',
    'test_outcome',
    'failure_origin',
    'workflow_action',
    'pester_invoked',
    'result_file',
    'error_code',
    'selected_module'
)

$script:SelectedModuleKeys = @('present', 'name', 'semantic_version', 'manifest_path')
$script:ResolutionStatuses = @('resolved', 'missing', 'ambiguous', 'empty', 'unknown', 'duplicate', 'artifact_conflict', 'runtime_failure')
$script:ExecutionStatuses = @('not_started', 'completed')
$script:TestOutcomes = @('not_run', 'passed', 'failed')
$script:FailureOrigins = @('none', 'assertion', 'test_runtime', 'block_or_container', 'mixed')
$script:WorkflowActions = @('install_once_then_rerun', 'succeed', 'fail')
$script:ExpectedErrorCodes = @(
    'none',
    'shard_id_empty',
    'shard_id_unknown',
    'shard_registry_duplicate',
    'preexisting_result_file',
    'pester_5_7_1_missing',
    'pester_5_7_1_ambiguous',
    'resolver_runtime_failure',
    'pester_import_failure',
    'pester_configuration_failure',
    'pester_runtime_failure',
    'pester_result_invalid',
    'pester_result_file_missing',
    'pester_tests_failed'
)

$script:RegistryRows = @(
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

$script:ResolverControlRows = @(
    [pscustomobject]@{ case_id = 'missing_exact_5_7_1'; expected_status = 'missing' }
    [pscustomobject]@{ case_id = 'one_normalized_exact_5_7_1'; expected_status = 'resolved' }
    [pscustomobject]@{ case_id = 'duplicate_identical_normalized_path'; expected_status = 'resolved' }
    [pscustomobject]@{ case_id = 'multiple_distinct_exact_5_7_1'; expected_status = 'ambiguous' }
    [pscustomobject]@{ case_id = 'wrong_versions_only'; expected_status = 'missing' }
    [pscustomobject]@{ case_id = 'enumeration_throws'; expected_status = 'runtime_failure' }
)

$script:ProducerRows = @(
    [pscustomobject]@{ id = 'P00'; resolution_status = 'unknown'; execution_status = 'not_started'; test_outcome = 'not_run'; failure_origin = 'none'; workflow_action = 'fail'; pester_invoked = $false; result_file_state = 'empty'; error_code = 'shard_id_unknown'; selected_module = 'absent' }
    [pscustomobject]@{ id = 'P01'; resolution_status = 'empty'; execution_status = 'not_started'; test_outcome = 'not_run'; failure_origin = 'none'; workflow_action = 'fail'; pester_invoked = $false; result_file_state = 'empty'; error_code = 'shard_id_empty'; selected_module = 'absent' }
    [pscustomobject]@{ id = 'P02'; resolution_status = 'duplicate'; execution_status = 'not_started'; test_outcome = 'not_run'; failure_origin = 'none'; workflow_action = 'fail'; pester_invoked = $false; result_file_state = 'empty'; error_code = 'shard_registry_duplicate'; selected_module = 'absent' }
    [pscustomobject]@{ id = 'P03'; resolution_status = 'artifact_conflict'; execution_status = 'not_started'; test_outcome = 'not_run'; failure_origin = 'none'; workflow_action = 'fail'; pester_invoked = $false; result_file_state = 'present'; error_code = 'preexisting_result_file'; selected_module = 'absent' }
    [pscustomobject]@{ id = 'P04'; resolution_status = 'missing'; execution_status = 'not_started'; test_outcome = 'not_run'; failure_origin = 'none'; workflow_action = 'install_once_then_rerun'; pester_invoked = $false; result_file_state = 'absent'; error_code = 'pester_5_7_1_missing'; selected_module = 'absent' }
    [pscustomobject]@{ id = 'P05'; resolution_status = 'ambiguous'; execution_status = 'not_started'; test_outcome = 'not_run'; failure_origin = 'none'; workflow_action = 'fail'; pester_invoked = $false; result_file_state = 'absent'; error_code = 'pester_5_7_1_ambiguous'; selected_module = 'absent' }
    [pscustomobject]@{ id = 'P06'; resolution_status = 'runtime_failure'; execution_status = 'not_started'; test_outcome = 'not_run'; failure_origin = 'none'; workflow_action = 'fail'; pester_invoked = $false; result_file_state = 'absent'; error_code = 'resolver_runtime_failure'; selected_module = 'absent' }
    [pscustomobject]@{ id = 'P07'; resolution_status = 'resolved'; execution_status = 'not_started'; test_outcome = 'not_run'; failure_origin = 'none'; workflow_action = 'fail'; pester_invoked = $false; result_file_state = 'absent'; error_code = 'pester_import_failure'; selected_module = 'present' }
    [pscustomobject]@{ id = 'P08'; resolution_status = 'resolved'; execution_status = 'not_started'; test_outcome = 'not_run'; failure_origin = 'none'; workflow_action = 'fail'; pester_invoked = $false; result_file_state = 'absent'; error_code = 'pester_configuration_failure'; selected_module = 'present' }
    [pscustomobject]@{ id = 'P09'; resolution_status = 'resolved'; execution_status = 'not_started'; test_outcome = 'not_run'; failure_origin = 'none'; workflow_action = 'fail'; pester_invoked = $true; result_file_state = 'either'; error_code = 'pester_runtime_failure'; selected_module = 'present' }
    [pscustomobject]@{ id = 'P10'; resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'not_run'; failure_origin = 'none'; workflow_action = 'fail'; pester_invoked = $true; result_file_state = 'either'; error_code = 'pester_result_invalid'; selected_module = 'present' }
    [pscustomobject]@{ id = 'P11'; resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'passed'; failure_origin = 'none'; workflow_action = 'fail'; pester_invoked = $true; result_file_state = 'absent'; error_code = 'pester_result_file_missing'; selected_module = 'present' }
    [pscustomobject]@{ id = 'P12'; resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'failed'; failure_origin = 'assertion'; workflow_action = 'fail'; pester_invoked = $true; result_file_state = 'absent'; error_code = 'pester_result_file_missing'; selected_module = 'present' }
    [pscustomobject]@{ id = 'P13'; resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'failed'; failure_origin = 'test_runtime'; workflow_action = 'fail'; pester_invoked = $true; result_file_state = 'absent'; error_code = 'pester_result_file_missing'; selected_module = 'present' }
    [pscustomobject]@{ id = 'P14'; resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'failed'; failure_origin = 'block_or_container'; workflow_action = 'fail'; pester_invoked = $true; result_file_state = 'absent'; error_code = 'pester_result_file_missing'; selected_module = 'present' }
    [pscustomobject]@{ id = 'P15'; resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'failed'; failure_origin = 'mixed'; workflow_action = 'fail'; pester_invoked = $true; result_file_state = 'absent'; error_code = 'pester_result_file_missing'; selected_module = 'present' }
    [pscustomobject]@{ id = 'P16'; resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'passed'; failure_origin = 'none'; workflow_action = 'succeed'; pester_invoked = $true; result_file_state = 'present'; error_code = 'none'; selected_module = 'present' }
    [pscustomobject]@{ id = 'P17'; resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'failed'; failure_origin = 'assertion'; workflow_action = 'fail'; pester_invoked = $true; result_file_state = 'present'; error_code = 'pester_tests_failed'; selected_module = 'present' }
    [pscustomobject]@{ id = 'P18'; resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'failed'; failure_origin = 'test_runtime'; workflow_action = 'fail'; pester_invoked = $true; result_file_state = 'present'; error_code = 'pester_tests_failed'; selected_module = 'present' }
    [pscustomobject]@{ id = 'P19'; resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'failed'; failure_origin = 'block_or_container'; workflow_action = 'fail'; pester_invoked = $true; result_file_state = 'present'; error_code = 'pester_tests_failed'; selected_module = 'present' }
    [pscustomobject]@{ id = 'P20'; resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'failed'; failure_origin = 'mixed'; workflow_action = 'fail'; pester_invoked = $true; result_file_state = 'present'; error_code = 'pester_tests_failed'; selected_module = 'present' }
)

$script:OriginTruthRows = @(
    [pscustomobject]@{ a = $false; t = $false; b = $false; failure_origin = 'none' }
    [pscustomobject]@{ a = $true; t = $false; b = $false; failure_origin = 'assertion' }
    [pscustomobject]@{ a = $false; t = $true; b = $false; failure_origin = 'test_runtime' }
    [pscustomobject]@{ a = $false; t = $false; b = $true; failure_origin = 'block_or_container' }
    [pscustomobject]@{ a = $true; t = $true; b = $false; failure_origin = 'mixed' }
    [pscustomobject]@{ a = $true; t = $false; b = $true; failure_origin = 'mixed' }
    [pscustomobject]@{ a = $false; t = $true; b = $true; failure_origin = 'mixed' }
    [pscustomobject]@{ a = $true; t = $true; b = $true; failure_origin = 'mixed' }
)

$script:ConsumerRows = @(
    # Each variant is a complete consumer fixture.  Calls name a canonical producer row;
    # the fixture runner materializes its file state before JSON emission and records every
    # phase in case-owned JSONL.  Mutations are deliberately performed after constructing a
    # valid base envelope by dictionary-safe operations in that runner.
    [pscustomobject]@{ id = 'C00'; variants = @(
        [pscustomobject]@{ name = 'desktop-partial-P16-then-throw'; job = 'desktop'; caller_id = 'desktop-debug-process'; calls = @([pscustomobject]@{ producer_row = 'P16'; capture = 'partial_throw'; mutation = ''; file_at_emission = 'present'; file_after_return = 'present' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $true }
    ) }
    [pscustomobject]@{ id = 'C01'; variants = @(
        [pscustomobject]@{ name = 'capture-count'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P16'; capture = 'two_strings'; mutation = ''; file_at_emission = 'present'; file_after_return = 'present' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
        [pscustomobject]@{ name = 'capture-runtime-type'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P16'; capture = 'object'; mutation = ''; file_at_emission = 'present'; file_after_return = 'present' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
        [pscustomobject]@{ name = 'physical-line-shape'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P16'; capture = 'two_lines'; mutation = ''; file_at_emission = 'present'; file_after_return = 'present' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
        [pscustomobject]@{ name = 'json-parse'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P16'; capture = 'invalid_json'; mutation = ''; file_at_emission = 'present'; file_after_return = 'present' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
    ) }
    [pscustomobject]@{ id = 'C02'; variants = @(
        @(
            [pscustomobject]@{ name = 'root-key-set'; mutation = 'root_keys' }
            [pscustomobject]@{ name = 'nested-key-set'; mutation = 'nested_keys' }
            [pscustomobject]@{ name = 'json-type'; mutation = 'json_type' }
            [pscustomobject]@{ name = 'enum'; mutation = 'enum' }
            ('resolution_status', 'execution_status', 'test_outcome', 'failure_origin', 'workflow_action', 'error_code' | ForEach-Object { [pscustomobject]@{ name = "case-shifted-$_"; mutation = "case_$_" } })
            [pscustomobject]@{ name = 'schema'; mutation = 'schema' }
        ) | ForEach-Object {
            $logical = $_
            @(
                [pscustomobject]@{ name = "$($logical.name)-matrix"; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P16'; capture = 'json'; mutation = $logical.mutation; file_at_emission = 'present'; file_after_return = 'present' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
                [pscustomobject]@{ name = "$($logical.name)-desktop"; job = 'desktop'; caller_id = 'desktop-debug-process'; calls = @([pscustomobject]@{ producer_row = 'P16'; capture = 'json'; mutation = $logical.mutation; file_at_emission = 'present'; file_after_return = 'present' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $true }
            )
        }
    ) }
    [pscustomobject]@{ id = 'C03'; variants = @(
        @(
            [pscustomobject]@{ name = 'ordinal-caller'; producer_row = 'P16'; mutation = 'caller'; file_at_emission = 'present'; file_after_return = 'present' }
            [pscustomobject]@{ name = 'static-result'; producer_row = 'P16'; mutation = 'result'; file_at_emission = 'present'; file_after_return = 'present' }
            [pscustomobject]@{ name = 'P04-empty-result-file'; producer_row = 'P04'; mutation = 'empty_result_file'; file_at_emission = 'absent'; file_after_return = 'absent' }
            [pscustomobject]@{ name = 'P16-empty-result-file'; producer_row = 'P16'; mutation = 'empty_result_file'; file_at_emission = 'present'; file_after_return = 'present' }
            [pscustomobject]@{ name = 'module'; producer_row = 'P16'; mutation = 'module'; file_at_emission = 'present'; file_after_return = 'present' }
            [pscustomobject]@{ name = 'relative-existing-manifest'; producer_row = 'P16'; mutation = 'relative_manifest_path'; file_at_emission = 'present'; file_after_return = 'present' }
            [pscustomobject]@{ name = 'non-normalized-existing-manifest'; producer_row = 'P16'; mutation = 'non_normalized_manifest_path'; file_at_emission = 'present'; file_after_return = 'present' }
            [pscustomobject]@{ name = 'wrong-leaf-existing-manifest'; producer_row = 'P16'; mutation = 'wrong_leaf_manifest_path'; file_at_emission = 'present'; file_after_return = 'present' }
            [pscustomobject]@{ name = 'nonexistent-manifest'; producer_row = 'P16'; mutation = 'nonexistent_manifest_path'; file_at_emission = 'present'; file_after_return = 'present' }
            [pscustomobject]@{ name = 'origin'; producer_row = 'P16'; mutation = 'origin'; file_at_emission = 'present'; file_after_return = 'present' }
            [pscustomobject]@{ name = 'producer-membership'; producer_row = 'P16'; mutation = 'producer'; file_at_emission = 'present'; file_after_return = 'present' }
        ) | ForEach-Object {
            $logical = $_
            @(
                [pscustomobject]@{ name = "$($logical.name)-matrix"; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = $logical.producer_row; capture = 'json'; mutation = $logical.mutation; file_at_emission = $logical.file_at_emission; file_after_return = $logical.file_after_return }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
                [pscustomobject]@{ name = "$($logical.name)-desktop"; job = 'desktop'; caller_id = 'desktop-debug-process'; calls = @([pscustomobject]@{ producer_row = $logical.producer_row; capture = 'json'; mutation = $logical.mutation; file_at_emission = $logical.file_at_emission; file_after_return = $logical.file_after_return }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $true }
            )
        }
    ) }
    [pscustomobject]@{ id = 'C04'; variants = @(
        [pscustomobject]@{ name = 'matrix-first-P04-existing-repository-reruns-P16'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P04'; capture = 'json'; mutation = ''; file_at_emission = 'absent'; file_after_return = 'absent' }, [pscustomobject]@{ producer_row = 'P16'; capture = 'json'; mutation = ''; file_at_emission = 'present'; file_after_return = 'present' }); expected_install_count = 1; expected_prerequisite_events = @('repository-lookup', 'repository-set', 'install-invoked'); expected_exit = 0; desktop_cleanup = $false }
        [pscustomobject]@{ name = 'desktop-first-P04-existing-repository-reruns-P16'; job = 'desktop'; caller_id = 'desktop-debug-process'; calls = @([pscustomobject]@{ producer_row = 'P04'; capture = 'json'; mutation = ''; file_at_emission = 'absent'; file_after_return = 'absent' }, [pscustomobject]@{ producer_row = 'P16'; capture = 'json'; mutation = ''; file_at_emission = 'present'; file_after_return = 'present' }); expected_install_count = 1; expected_prerequisite_events = @('repository-lookup', 'repository-set', 'install-invoked'); expected_exit = 0; desktop_cleanup = $true }
        [pscustomobject]@{ name = 'matrix-first-P04-missing-repository-reruns-P16'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P04'; capture = 'json'; mutation = ''; file_at_emission = 'absent'; file_after_return = 'absent' }, [pscustomobject]@{ producer_row = 'P16'; capture = 'json'; mutation = ''; file_at_emission = 'present'; file_after_return = 'present' }); expected_install_count = 1; repository_present = $false; expected_prerequisite_events = @('repository-lookup', 'repository-register', 'repository-set', 'install-invoked'); expected_exit = 0; desktop_cleanup = $false }
    ) }
    [pscustomobject]@{ id = 'C05'; variants = @(
        [pscustomobject]@{ name = 'first-P04-install-throws'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P04'; capture = 'json'; mutation = ''; file_at_emission = 'absent'; file_after_return = 'absent' }); expected_install_count = 1; install_throws = $true; expected_prerequisite_events = @('repository-lookup', 'repository-set', 'install-invoked'); expected_exit = 2; desktop_cleanup = $false }
        [pscustomobject]@{ name = 'first-P04-missing-repository-registration-throws'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P04'; capture = 'json'; mutation = ''; file_at_emission = 'absent'; file_after_return = 'absent' }); expected_install_count = 0; repository_present = $false; registration_throws = $true; expected_prerequisite_events = @('repository-lookup', 'repository-register'); expected_exit = 2; desktop_cleanup = $false }
        [pscustomobject]@{ name = 'first-P04-trust-set-throws'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P04'; capture = 'json'; mutation = ''; file_at_emission = 'absent'; file_after_return = 'absent' }); expected_install_count = 0; trust_set_throws = $true; expected_prerequisite_events = @('repository-lookup', 'repository-set'); expected_exit = 2; desktop_cleanup = $false }
    ) }
    [pscustomobject]@{ id = 'C06'; variants = @([pscustomobject]@{ name = 'second-P04-rejected-without-second-prerequisite'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P04'; capture = 'json'; mutation = ''; file_at_emission = 'absent'; file_after_return = 'absent' }, [pscustomobject]@{ producer_row = 'P04'; capture = 'json'; mutation = ''; file_at_emission = 'absent'; file_after_return = 'absent' }); expected_install_count = 1; expected_prerequisite_events = @('repository-lookup', 'repository-set', 'install-invoked'); expected_exit = 2; desktop_cleanup = $false }) }
    [pscustomobject]@{ id = 'C07'; variants = @([pscustomobject]@{ name = 'P16-present'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P16'; capture = 'json'; mutation = ''; file_at_emission = 'present'; file_after_return = 'present' }); expected_install_count = 0; expected_exit = 0; desktop_cleanup = $false }) }
    [pscustomobject]@{ id = 'C08'; variants = @([pscustomobject]@{ name = 'P16-vanishes-after-emission'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P16'; capture = 'json'; mutation = ''; file_at_emission = 'present'; file_after_return = 'absent' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }) }
    [pscustomobject]@{ id = 'C09'; variants = @('P17', 'P18', 'P19', 'P20' | ForEach-Object { [pscustomobject]@{ name = "$_-present"; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = $_; capture = 'json'; mutation = ''; file_at_emission = 'present'; file_after_return = 'present' }); expected_install_count = 0; expected_exit = 1; desktop_cleanup = $false } }) }
    [pscustomobject]@{ id = 'C10'; variants = @('P17', 'P18', 'P19', 'P20' | ForEach-Object { [pscustomobject]@{ name = "$_-vanishes-after-emission"; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = $_; capture = 'json'; mutation = ''; file_at_emission = 'present'; file_after_return = 'absent' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false } }) }
    [pscustomobject]@{ id = 'C11'; variants = @('P11', 'P12', 'P13', 'P14', 'P15' | ForEach-Object { [pscustomobject]@{ name = "$_-absent"; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = $_; capture = 'json'; mutation = ''; file_at_emission = 'absent'; file_after_return = 'absent' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false } }) }
    [pscustomobject]@{ id = 'C12'; variants = @(
        [pscustomobject]@{ name = 'P00-arbitrary-unknown'; job = 'matrix'; caller_id = 'unknown + multi-byte あ'; calls = @([pscustomobject]@{ producer_row = 'P00'; capture = 'json'; mutation = ''; file_at_emission = 'empty'; file_after_return = 'absent' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
        [pscustomobject]@{ name = 'P01-empty'; job = 'matrix'; caller_id = ''; calls = @([pscustomobject]@{ producer_row = 'P01'; capture = 'json'; mutation = ''; file_at_emission = 'empty'; file_after_return = 'absent' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
        [pscustomobject]@{ name = 'P02-configured-duplicate-id'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P02'; capture = 'json'; mutation = ''; file_at_emission = 'empty'; file_after_return = 'absent' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
        [pscustomobject]@{ name = 'P03-preexisting'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P03'; capture = 'json'; mutation = ''; file_at_emission = 'present'; file_after_return = 'present'; preexisting = $true }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
        ('P05', 'P06', 'P07', 'P08' | ForEach-Object { [pscustomobject]@{ name = "$_-terminal"; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = $_; capture = 'json'; mutation = ''; file_at_emission = 'absent'; file_after_return = 'absent' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false } })
    ) }
    [pscustomobject]@{ id = 'C13'; variants = @(
        [pscustomobject]@{ name = 'P09-absent'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P09'; capture = 'json'; mutation = ''; file_at_emission = 'absent'; file_after_return = 'absent' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
        [pscustomobject]@{ name = 'P09-partial'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P09'; capture = 'json'; mutation = ''; file_at_emission = 'present'; file_after_return = 'present'; partial = $true }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
        [pscustomobject]@{ name = 'P10-absent'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P10'; capture = 'json'; mutation = ''; file_at_emission = 'absent'; file_after_return = 'absent' }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
        [pscustomobject]@{ name = 'P10-partial'; job = 'matrix'; caller_id = 'integration'; calls = @([pscustomobject]@{ producer_row = 'P10'; capture = 'json'; mutation = ''; file_at_emission = 'present'; file_after_return = 'present'; partial = $true }); expected_install_count = 0; expected_exit = 2; desktop_cleanup = $false }
    ) }
)

$script:ResolverControlCases = @(
    foreach ($row in $script:ResolverControlRows) {
        $case = @{}
        foreach ($property in $row.PSObject.Properties) {
            $case[$property.Name] = $property.Value
        }
        $case
    }
)

$script:ProducerCases = @(
    foreach ($row in $script:ProducerRows) {
        $case = @{}
        foreach ($property in $row.PSObject.Properties) {
            $case[$property.Name] = $property.Value
        }
        $case
    }
)

$script:OriginTruthCases = @(
    foreach ($row in $script:OriginTruthRows) {
        $case = @{}
        foreach ($property in $row.PSObject.Properties) {
            $case[$property.Name] = $property.Value
        }
        $case
    }
)

$script:ConsumerCases = @(
    foreach ($row in $script:ConsumerRows) {
        $case = @{}
        foreach ($property in $row.PSObject.Properties) {
            if ($property.Name -ne 'variants') {
                $case[$property.Name] = $property.Value
                continue
            }

            $case[$property.Name] = @(
                foreach ($variant in @($property.Value)) {
                    $boundVariant = [ordered]@{}
                    foreach ($variantProperty in $variant.PSObject.Properties) {
                        if ($variantProperty.Name -ne 'calls') {
                            $boundVariant[$variantProperty.Name] = $variantProperty.Value
                            continue
                        }

                        $boundVariant[$variantProperty.Name] = @(
                            foreach ($call in @($variantProperty.Value)) {
                                $boundCall = [ordered]@{}
                                foreach ($callProperty in $call.PSObject.Properties) {
                                    $boundCall[$callProperty.Name] = $callProperty.Value
                                }
                                $sourceRows = @($script:ProducerRows | Where-Object { $_.id -eq $call.producer_row })
                                if ($sourceRows.Count -ne 1) {
                                    throw "consumer producer projection requires exactly one frozen row for $($call.producer_row)"
                                }
                                $producerSnapshot = [ordered]@{}
                                foreach ($producerProperty in $sourceRows[0].PSObject.Properties) {
                                    $producerSnapshot[$producerProperty.Name] = $producerProperty.Value
                                }
                                $boundCall.producer_snapshot = $producerSnapshot
                                [pscustomobject]$boundCall
                            }
                        )
                    }
                    [pscustomobject]$boundVariant
                }
            )
        }
        $case.workflow_path = $script:WorkflowPath
        $case
    }
)

BeforeAll {
    $script:RepositoryRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
    $script:ModulePath = Join-Path $script:RepositoryRoot 'scripts/winsmux-pester.psm1'
    $script:RunnerPath = Join-Path $script:RepositoryRoot 'scripts/run-pester-shard.ps1'
    $script:WorkflowPath = Join-Path $script:RepositoryRoot '.github/workflows/test.yml'
    $script:RunTestsPath = Join-Path $script:RepositoryRoot 'scripts/run-tests.ps1'
    $script:CoverageValidatorPath = Join-Path $script:RepositoryRoot 'scripts/assert-pester-shard-coverage.ps1'
    $script:ExportedCommands = @('Get-WinsmuxPesterShardRegistry', 'Resolve-WinsmuxPesterShard', 'Resolve-WinsmuxPesterModule')
    $script:EnvelopeRootKeys = @('schema_version', 'shard_id', 'resolution_status', 'execution_status', 'test_outcome', 'failure_origin', 'workflow_action', 'pester_invoked', 'result_file', 'error_code', 'selected_module')
    $script:SelectedModuleKeys = @('present', 'name', 'semantic_version', 'manifest_path')
    $script:ResolutionStatuses = @('resolved', 'missing', 'ambiguous', 'empty', 'unknown', 'duplicate', 'artifact_conflict', 'runtime_failure')
    $script:ExecutionStatuses = @('not_started', 'completed')
    $script:TestOutcomes = @('not_run', 'passed', 'failed')
    $script:FailureOrigins = @('none', 'assertion', 'test_runtime', 'block_or_container', 'mixed')
    $script:WorkflowActions = @('install_once_then_rerun', 'succeed', 'fail')
    $script:ExpectedErrorCodes = @('none', 'shard_id_empty', 'shard_id_unknown', 'shard_registry_duplicate', 'preexisting_result_file', 'pester_5_7_1_missing', 'pester_5_7_1_ambiguous', 'resolver_runtime_failure', 'pester_import_failure', 'pester_configuration_failure', 'pester_runtime_failure', 'pester_result_invalid', 'pester_result_file_missing', 'pester_tests_failed')

    $registrySpecification = @'
bridge-foundation|test-results-bridge-foundation.xml|matrix|tests/bridge/Foundation.Tests.ps1;tests/bridge/Foundation.Settings.Tests.ps1
bridge-agent-orchestra|test-results-bridge-agent-orchestra.xml|matrix|tests/bridge/AgentOrchestra.Tests.ps1;tests/bridge/AgentOrchestra.Bootstrap.Tests.ps1
bridge-command-status|test-results-bridge-command-status.xml|matrix|tests/bridge/CommandStatus.Tests.ps1;tests/bridge/CommandStatus.RuntimeIdentity.Tests.ps1
bridge-worker-workspace-sandbox|test-results-bridge-worker-workspace-sandbox.xml|matrix|tests/bridge/WorkerWorkspaceSandbox.Tests.ps1
bridge-worker-broker-token|test-results-bridge-worker-broker-token.xml|matrix|tests/bridge/WorkerBrokerToken.Tests.ps1
bridge-worker-policy|test-results-bridge-worker-policy.xml|matrix|tests/bridge/WorkerPolicy.Tests.ps1
bridge-worker-secrets-status|test-results-bridge-worker-secrets-status.xml|matrix|tests/bridge/WorkerSecretsStatus.Tests.ps1
bridge-worker-heartbeat-start|test-results-bridge-worker-heartbeat-start.xml|matrix|tests/bridge/WorkerHeartbeatStart.Tests.ps1
bridge-worker-api-agy-exec|test-results-bridge-worker-api-agy-exec.xml|matrix|tests/bridge/WorkerApiAgyExec.Tests.ps1
bridge-command-queue-reporting|test-results-bridge-command-queue-reporting.xml|matrix|tests/bridge/CommandQueueReporting.Tests.ps1
bridge-command-review-dispatch|test-results-bridge-command-review-dispatch.xml|matrix|tests/bridge/CommandReviewDispatch.Tests.ps1
bridge-provider-commands|test-results-bridge-provider-commands.xml|matrix|tests/bridge/ProviderCommands.Tests.ps1;tests/bridge/ProviderCommands.Dispatch.Tests.ps1
bridge-artifacts-runtime|test-results-bridge-artifacts-runtime.xml|matrix|tests/bridge/ArtifactsRuntime.Tests.ps1;tests/bridge/ArtifactsRuntime.Operator.Tests.ps1
integration|test-results-integration.xml|matrix|tests/Integration.GateEnforcement.Tests.ps1;tests/Integration.MultiAgent.Tests.ps1;tests/Integration.PaneMonitorHook.Tests.ps1;tests/Integration.PluginHookLoader.Tests.ps1;tests/Integration.WorktreeHook.Tests.ps1;tests/Task839WorktreeReviewState.Tests.ps1;tests/V03630DesktopDebugGate.Tests.ps1;tests/Task810PesterRunner.Tests.ps1
worker-benchmark|test-results-worker-benchmark.xml|matrix|tests/CliBakeoff.Tests.ps1;tests/HarnessContract.Tests.ps1;tests/Runtime.VaultInject.Tests.ps1
release-public|test-results-release-public.xml|matrix|tests/PublicSurfacePolicy.Tests.ps1;tests/VersionSurface.Tests.ps1;tests/NpmReleasePackage.Tests.ps1;tests/GitHubWritePreflight.Tests.ps1;tests/McpServerContract.Tests.ps1;tests/ThreatModelContract.Tests.ps1;tests/EnterpriseStrategyAlignment.Tests.ps1;tests/ReviewLatencyHardening.Tests.ps1;tests/UpstreamReevaluation.Tests.ps1
shell-support|test-results-shell-support.xml|matrix|tests/BuilderWorktree.Tests.ps1;tests/codex-subagent-worktree-guard.Tests.ps1;tests/OrchestraPreflight.Tests.ps1;tests/PaneBorder.Tests.ps1;tests/V03618ReleaseHardening.Tests.ps1;tests/AgentReadiness.Tests.ps1
repo-audit-v03619|test-results-repo-audit-v03619.xml|matrix|tests/V03619RepoAudit.Tests.ps1
coordinator-v03620|test-results-coordinator-v03620.xml|matrix|tests/V03620CoordinatorFoundation.Tests.ps1
local-router-v03621|test-results-local-router-v03621.xml|matrix|tests/V03621LocalRouterShadow.Tests.ps1
desktop-split-v03626|test-results-desktop-split-v03626.xml|matrix|tests/V03626DesktopSplitGate.Tests.ps1
compat-performance-v03627|test-results-compat-performance-v03627.xml|matrix|tests/V03627CompatPerformanceGate.Tests.ps1
race-abnormal-soak-v03628|test-results-race-abnormal-soak-v03628.xml|matrix|tests/V03628RaceAbnormalSoak.Tests.ps1
runtime-reliability-v03628|test-results-runtime-reliability-v03628.xml|matrix|tests/V03628RuntimeReliabilityGate.Tests.ps1
packaged-restore-v03628|test-results-packaged-restore-v03628.xml|matrix|tests/V03628PackagedRestoreGate.Tests.ps1
desktop-debug-process|test-results-desktop-debug-v03630.xml|desktop|tests/V03630DesktopDebugGateProcess.Tests.ps1
'@
    $script:RegistryRows = @(
        foreach ($line in ($registrySpecification.Trim() -split "`r?`n")) {
            $fields = $line -split '\|', 4
            [pscustomobject][ordered]@{
                shard_id = $fields[0]
                paths = @($fields[3] -split ';')
                full_name = ''
                result_file = $fields[1]
                job_kind = $fields[2]
            }
        }
    )

function Get-Task810OptionalValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Default = $null
    )

    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Assert-Task810Envelope {
    param(
        [Parameter(Mandatory = $true)][object[]]$Output,
        [Parameter(Mandatory = $true)][pscustomobject]$Expected,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedResultFile
    )

    $Output.Count | Should -Be 1
    $Output[0].GetType().FullName | Should -Be 'System.String'
    ($Output[0] -split "`r?`n").Count | Should -Be 1
    $envelope = $Output[0] | ConvertFrom-Json -ErrorAction Stop
    @($envelope.PSObject.Properties.Name) | Should -BeExactly $script:EnvelopeRootKeys
    @($envelope.selected_module.PSObject.Properties.Name) | Should -BeExactly $script:SelectedModuleKeys
    $envelope.schema_version.GetType().FullName | Should -Be 'System.String'
    $envelope.shard_id.GetType().FullName | Should -Be 'System.String'
    $envelope.pester_invoked.GetType().FullName | Should -Be 'System.Boolean'
    $envelope.schema_version | Should -Be '1'
    $envelope.resolution_status | Should -Be $Expected.resolution_status
    $envelope.execution_status | Should -Be $Expected.execution_status
    $envelope.test_outcome | Should -Be $Expected.test_outcome
    $envelope.failure_origin | Should -Be $Expected.failure_origin
    $envelope.workflow_action | Should -Be $Expected.workflow_action
    $envelope.pester_invoked | Should -Be $Expected.pester_invoked
    $envelope.error_code | Should -Be $Expected.error_code
    $envelope.result_file | Should -Be $ExpectedResultFile
    $envelope.selected_module.present | Should -Be ($Expected.selected_module -eq 'present')
    if ($Expected.selected_module -eq 'present') {
        $envelope.selected_module.name | Should -Be 'Pester'
        $envelope.selected_module.semantic_version | Should -Be '5.7.1'
        $envelope.selected_module.manifest_path | Should -Not -BeNullOrEmpty
        [IO.Path]::IsPathFullyQualified($envelope.selected_module.manifest_path) | Should -BeTrue
    } else {
        $envelope.selected_module.name | Should -Be ''
        $envelope.selected_module.semantic_version | Should -Be ''
        $envelope.selected_module.manifest_path | Should -Be ''
    }

    return $envelope
}

function Write-Task810Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Get-Task810FixturePesterModule {
    return @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dataPath = Join-Path $PSScriptRoot 'task810-phase.json'
$phase = Get-Content -Raw -LiteralPath $dataPath | ConvertFrom-Json -ErrorAction Stop

function New-PesterConfiguration {
    if ($phase.mode -eq 'configuration_throw') { throw 'fixture configuration failure' }

    return [pscustomobject]@{
        Run = [pscustomobject]@{ Path = @(); PassThru = $false }
        TestResult = [pscustomobject]@{ Enabled = $false; OutputPath = ''; OutputFormat = '' }
    }
}

function Invoke-Pester {
    param([Parameter(Mandatory = $true)]$Configuration)

    if ($phase.mode -eq 'invoke_throw') { throw 'fixture Pester runtime failure' }
    if ([bool]$phase.write_result) {
        [IO.File]::WriteAllText($Configuration.TestResult.OutputPath, '<test-results />', [Text.UTF8Encoding]::new($false))
    }

    $failed = @()
    $failedBlocks = @()
    $passed = @()
    $notRun = @()
    if ([bool]$phase.passed) {
        $passed = @([pscustomobject]@{ state = 'passed' })
    } elseif ($phase.invalid -eq 'failed_without_entry') {
        $notRun = @([pscustomobject]@{ state = 'not_run' })
    } elseif ([bool]$phase.selected_not_executed) {
        $failed = @([pscustomobject]@{ ShouldRun = $true; Executed = $false; ErrorRecord = @() })
    } elseif ($phase.invalid -eq 'executed_failure_without_error') {
        $failed = @([pscustomobject]@{ ShouldRun = $true; Executed = $true; ErrorRecord = @() })
    } elseif ([bool]$phase.block -and -not ([bool]$phase.assertion -or [bool]$phase.runtime)) {
        $failedBlocks = @([pscustomobject]@{ state = 'failed_block' })
        $notRun = @([pscustomobject]@{ state = 'not_run' })
    } else {
        $errors = @()
        if ([bool]$phase.assertion) { $errors += [pscustomobject]@{ FullyQualifiedErrorId = 'PesterAssertionFailed' } }
        if ([bool]$phase.runtime) { $errors += [pscustomobject]@{ FullyQualifiedErrorId = 'FixtureRuntimeFailure' } }
        $failed = @([pscustomobject]@{ ShouldRun = $true; Executed = $true; ErrorRecord = $errors })
        if ([bool]$phase.block) { $failedBlocks = @([pscustomobject]@{ state = 'failed_block' }) }
    }

    if ($phase.invalid -eq 'passed_with_failure') {
        $failed = @([pscustomobject]@{ ShouldRun = $true; Executed = $true; ErrorRecord = @([pscustomobject]@{ FullyQualifiedErrorId = 'PesterAssertionFailed' }) })
    }

    $tests = @($failed + $passed + $notRun)
    $result = if ([bool]$phase.passed -or $phase.invalid -eq 'passed_with_failure') { 'Passed' } else { 'Failed' }
    $run = [pscustomobject][ordered]@{
        Result = $result
        Failed = $failed
        FailedBlocks = $failedBlocks
        FailedContainers = @()
        Passed = $passed
        Skipped = @()
        Inconclusive = @()
        NotRun = $notRun
        Tests = $tests
        FailedCount = [int]@($failed).Count
        FailedBlocksCount = [int]@($failedBlocks).Count
        FailedContainersCount = 0
        PassedCount = [int]@($passed).Count
        SkippedCount = 0
        InconclusiveCount = 0
        NotRunCount = [int]@($notRun).Count
        TotalCount = [int]@($tests).Count
    }
    if ($phase.invalid -eq 'failed_without_entry') {
        $run.NotRun = @()
        $run.NotRunCount = 0
        $run.Tests = @()
        $run.TotalCount = 0
    }
    if ($phase.invalid -eq 'count_mismatch') { $run.FailedCount += 1 }
    return $run
}

Export-ModuleMember -Function New-PesterConfiguration, Invoke-Pester
'@
}

function Invoke-Task810IsolatedRunnerCase {
    param(
        [Parameter(Mandatory = $true)][string]$CaseId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ShardId,
        [hashtable]$Phase = @{},
        [bool]$DuplicateRegistry = $false,
        [bool]$PrecreateResult = $false,
        [ValidateSet('5.7.1', '5.6.0')][string[]]$PesterVersions = @('5.7.1'),
        [bool]$ResolverThrows = $false,
        [bool]$ImportThrows = $false
    )

    $originalArtifactPath = Join-Path $script:RepositoryRoot 'test-results-integration.xml'
    Test-Path -LiteralPath $originalArtifactPath | Should -BeFalse -Because 'the original staging artifact is never a fixture target'

    $caseRoot = Join-Path $TestDrive ("task810-$CaseId-" + [guid]::NewGuid().ToString('N'))
    $scriptsRoot = Join-Path $caseRoot 'scripts'
    $modulesRoots = @()
    New-Item -ItemType Directory -Path $scriptsRoot -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $script:RunnerPath -Destination (Join-Path $scriptsRoot 'run-pester-shard.ps1') -ErrorAction Stop
    Copy-Item -LiteralPath $script:ModulePath -Destination (Join-Path $scriptsRoot 'winsmux-pester.psm1') -ErrorAction Stop

    if ($DuplicateRegistry) {
        $fixtureModulePath = Join-Path $scriptsRoot 'winsmux-pester.psm1'
        $fixtureModule = Get-Content -Raw -LiteralPath $fixtureModulePath
        $duplicateIntegrationRow = "    [pscustomobject][ordered]@{ shard_id = 'INTEGRATION'; paths = @('tests/fixture.Tests.ps1'); full_name = ''; result_file = 'test-results-fixture.xml'; job_kind = 'matrix' }"
        $fixtureModule = $fixtureModule -replace '(\r?\n\)\r?\n\r?\nfunction Get-WinsmuxPesterShardRegistry)', ("`r`n" + $duplicateIntegrationRow + '$1')
        Write-Task810Utf8File -Path $fixtureModulePath -Content $fixtureModule
    }

    $phaseData = [ordered]@{
        mode = [string](Get-Task810OptionalValue -Object $Phase -Name 'mode' -Default 'run')
        assertion = [bool](Get-Task810OptionalValue -Object $Phase -Name 'assertion' -Default $false)
        runtime = [bool](Get-Task810OptionalValue -Object $Phase -Name 'runtime' -Default $false)
        block = [bool](Get-Task810OptionalValue -Object $Phase -Name 'block' -Default $false)
        passed = [bool](Get-Task810OptionalValue -Object $Phase -Name 'passed' -Default $false)
        invalid = [string](Get-Task810OptionalValue -Object $Phase -Name 'invalid' -Default '')
        selected_not_executed = [bool](Get-Task810OptionalValue -Object $Phase -Name 'selected_not_executed' -Default $false)
        write_result = [bool](Get-Task810OptionalValue -Object $Phase -Name 'write_result' -Default $false)
    }
    $phaseJson = $phaseData | ConvertTo-Json -Compress

    for ($index = 0; $index -lt $PesterVersions.Count; $index++) {
        $modulesRoot = Join-Path $caseRoot ("modules-$index")
        $pesterRoot = Join-Path $modulesRoot (Join-Path 'Pester' $PesterVersions[$index])
        New-Item -ItemType Directory -Path $pesterRoot -ErrorAction Stop | Out-Null
        $modulesRoots += $modulesRoot
        $manifest = "@{ RootModule = 'Pester.psm1'; ModuleVersion = '$($PesterVersions[$index])'; GUID = '2b80ecfd-c998-49e8-8f54-00865dd4c968' }"
        Write-Task810Utf8File -Path (Join-Path $pesterRoot 'Pester.psd1') -Content $manifest
        $moduleSource = if ($ImportThrows) { "throw 'fixture import failure'" } else { Get-Task810FixturePesterModule }
        Write-Task810Utf8File -Path (Join-Path $pesterRoot 'Pester.psm1') -Content $moduleSource
        Write-Task810Utf8File -Path (Join-Path $pesterRoot 'task810-phase.json') -Content $phaseJson
    }

    $caseResultPath = Join-Path $caseRoot 'test-results-integration.xml'
    $artifactBefore = $null
    if ($PrecreateResult) {
        [IO.File]::WriteAllBytes($caseResultPath, [byte[]](17, 34, 51, 68))
        $artifact = Get-Item -LiteralPath $caseResultPath
        $artifactBefore = [pscustomobject]@{
            bytes = [IO.File]::ReadAllBytes($caseResultPath)
            hash = (Get-FileHash -LiteralPath $caseResultPath -Algorithm SHA256).Hash
            length = $artifact.Length
            creation_time_utc = $artifact.CreationTimeUtc
            last_write_time_utc = $artifact.LastWriteTimeUtc
            attributes = $artifact.Attributes
        }
    }

    $childPath = Join-Path $caseRoot 'invoke-case.ps1'
    $childSource = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CaseRoot,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ShardId,
    [Parameter(Mandatory = $true)][string]$ModuleRoots,
    [Parameter(Mandatory = $true)][string]$ResolverThrows
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$moduleRootItems = @($ModuleRoots -split [Regex]::Escape([string][IO.Path]::PathSeparator) | Where-Object { $_.Length -gt 0 })
$env:PSModulePath = $moduleRootItems -join [IO.Path]::PathSeparator
if ([System.Convert]::ToBoolean($ResolverThrows)) {
    function global:Get-Module { param() throw 'fixture enumeration failure' }
}

& (Join-Path $CaseRoot 'scripts/run-pester-shard.ps1') -ShardId $ShardId
'@
    Write-Task810Utf8File -Path $childPath -Content $childSource
    $stdoutPath = Join-Path $caseRoot 'stdout.txt'
    $stderrPath = Join-Path $caseRoot 'stderr.txt'
    $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    $moduleRootsArgument = $modulesRoots -join [IO.Path]::PathSeparator
    & $pwshPath -NoLogo -NoProfile -NonInteractive -File $childPath -CaseRoot $caseRoot -ShardId $ShardId -ModuleRoots $moduleRootsArgument -ResolverThrows $ResolverThrows 1> $stdoutPath 2> $stderrPath
    $childExitCode = $LASTEXITCODE

    $artifactAfter = if (Test-Path -LiteralPath $caseResultPath) {
        $artifact = Get-Item -LiteralPath $caseResultPath
        [pscustomobject]@{
            bytes = [IO.File]::ReadAllBytes($caseResultPath)
            hash = (Get-FileHash -LiteralPath $caseResultPath -Algorithm SHA256).Hash
            length = $artifact.Length
            creation_time_utc = $artifact.CreationTimeUtc
            last_write_time_utc = $artifact.LastWriteTimeUtc
            attributes = $artifact.Attributes
        }
    } else { $null }
    Test-Path -LiteralPath $originalArtifactPath | Should -BeFalse -Because 'only the case-owned artifact path is eligible for a fixture'

    return [pscustomobject]@{
        case_root = $caseRoot
        exit_code = $childExitCode
        stdout_lines = [IO.File]::ReadAllLines($stdoutPath)
        stderr = [IO.File]::ReadAllText($stderrPath)
        artifact_before = $artifactBefore
        artifact_after = $artifactAfter
    }
}

function Assert-Task810IsolatedRunnerCase {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Case,
        [Parameter(Mandatory = $true)][pscustomobject]$Expected,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedResultFile,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedShardId,
        [ValidateSet('absent', 'present', 'either')][string]$ArtifactState = 'either'
    )

    $diagnostics = "child exit={0}; stderr={1}; stdout={2}" -f $Case.exit_code, $Case.stderr, ($Case.stdout_lines -join '|')
    $Case.exit_code | Should -Be 0 -Because $diagnostics
    $Case.stderr | Should -Be '' -Because $diagnostics
    $Case.stdout_lines.Count | Should -Be 1 -Because $diagnostics
    $Case.stdout_lines[0] | Should -Match '^\{.+\}$' -Because $diagnostics
    $actual = $Case.stdout_lines[0] | ConvertFrom-Json -ErrorAction Stop
    $actual.resolution_status | Should -Be $Expected.resolution_status -Because $diagnostics
    $actual.execution_status | Should -Be $Expected.execution_status -Because $diagnostics
    $actual.error_code | Should -Be $Expected.error_code -Because $diagnostics
    $actual.pester_invoked | Should -Be $Expected.pester_invoked -Because $diagnostics
    $envelope = Assert-Task810Envelope -Output $Case.stdout_lines -Expected $Expected -ExpectedResultFile $ExpectedResultFile
    $envelope.shard_id | Should -Be $ExpectedShardId -Because $diagnostics
    if ($ArtifactState -eq 'absent') {
        $Case.artifact_after | Should -BeNullOrEmpty -Because $diagnostics
    } elseif ($ArtifactState -eq 'present') {
        $Case.artifact_after | Should -Not -BeNullOrEmpty -Because $diagnostics
    }

    return $envelope
}
}

Describe 'TASK-810 exact three-export module and 26-row registry' {
    It 'exports the exact runner module command set from the sole future module path' {
        $script:ModulePath | Should -Exist -Because 'scripts/winsmux-pester.psm1 is the sole TASK-810 module location'
        $module = Import-Module -Name $script:ModulePath -PassThru -ErrorAction Stop
        try {
            @($module.ExportedFunctions.Keys | Sort-Object) | Should -BeExactly @($script:ExportedCommands | Sort-Object)
            @($module.ExportedAliases.Keys).Count | Should -Be 0
        } finally {
            Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        }
    }

    It 'defines the complete ordered registry with exact five-property internal rows' {
        $script:RegistryRows.Count | Should -Be 26
        @($script:RegistryRows.shard_id) | Should -BeExactly @(
            'bridge-foundation', 'bridge-agent-orchestra', 'bridge-command-status', 'bridge-worker-workspace-sandbox',
            'bridge-worker-broker-token', 'bridge-worker-policy', 'bridge-worker-secrets-status', 'bridge-worker-heartbeat-start',
            'bridge-worker-api-agy-exec', 'bridge-command-queue-reporting', 'bridge-command-review-dispatch', 'bridge-provider-commands',
            'bridge-artifacts-runtime', 'integration', 'worker-benchmark', 'release-public', 'shell-support', 'repo-audit-v03619',
            'coordinator-v03620', 'local-router-v03621', 'desktop-split-v03626', 'compat-performance-v03627',
            'race-abnormal-soak-v03628', 'runtime-reliability-v03628', 'packaged-restore-v03628', 'desktop-debug-process'
        )
        foreach ($row in $script:RegistryRows) {
            @($row.PSObject.Properties.Name) | Should -BeExactly @('shard_id', 'paths', 'full_name', 'result_file', 'job_kind')
            $row.full_name | Should -Be ''
            $row.job_kind | Should -BeIn @('matrix', 'desktop')
            $row.result_file | Should -Match '^test-results-[a-z0-9-]+\.xml$'
            foreach ($path in $row.paths) {
                $path.GetType().FullName | Should -Be 'System.String'
                $path | Should -Match '^tests/.+\.Tests\.ps1$'
                $path | Should -Not -Match '(^[A-Za-z]:|^\\\\|\\|\.\.|\*)'
            }
        }
        @($script:RegistryRows | Where-Object { $_.job_kind -eq 'matrix' }).Count | Should -Be 25
        @($script:RegistryRows | Where-Object { $_.job_kind -eq 'desktop' }).Count | Should -Be 1
        @($script:RegistryRows | Where-Object { $_.job_kind -eq 'matrix' } | ForEach-Object { $_.paths }).Count | Should -Be 52
        @($script:RegistryRows.result_file).Count | Should -Be (@($script:RegistryRows.result_file | Sort-Object -Unique).Count)
    }

    It 'returns the frozen registry from the exported module without changing internal row shape' {
        $script:ModulePath | Should -Exist -Because 'scripts/winsmux-pester.psm1 is the sole TASK-810 module location'
        $module = Import-Module -Name $script:ModulePath -PassThru -ErrorAction Stop
        try {
            $actualRows = @(Get-WinsmuxPesterShardRegistry)
            $actualRows.Count | Should -Be $script:RegistryRows.Count
            for ($index = 0; $index -lt $script:RegistryRows.Count; $index += 1) {
                $expected = $script:RegistryRows[$index]
                $actual = $actualRows[$index]
                @($actual.PSObject.Properties.Name) | Should -BeExactly @('shard_id', 'paths', 'full_name', 'result_file', 'job_kind')
                $actual.shard_id | Should -Be $expected.shard_id
                @($actual.paths) | Should -BeExactly @($expected.paths)
                $actual.full_name | Should -Be $expected.full_name
                $actual.result_file | Should -Be $expected.result_file
                $actual.job_kind | Should -Be $expected.job_kind
            }
        } finally {
            Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'TASK-810 exact 5.7.1 resolver controls' {
    It 'drives the exported resolver through <case_id>' -ForEach $script:ResolverControlCases {
        $module = Import-Module -Name $script:ModulePath -Force -PassThru -ErrorAction Stop
        $fixtureRoot = $null
        try {
            $installed = @(Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -eq [version]'5.7.1' })[0]
            $candidate = [pscustomobject]@{ Name = 'Pester'; Version = [version]'5.7.1'; ModuleBase = $installed.ModuleBase }
            switch ($case_id) {
                'missing_exact_5_7_1' { Mock Get-Module -ModuleName $module.Name -MockWith { @() } }
                'one_normalized_exact_5_7_1' { Mock Get-Module -ModuleName $module.Name -MockWith { @($candidate) } }
                'duplicate_identical_normalized_path' { Mock Get-Module -ModuleName $module.Name -MockWith { @($candidate, $candidate) } }
                'multiple_distinct_exact_5_7_1' {
                    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("task810-pester-" + [guid]::NewGuid().ToString('N'))
                    $secondBase = Join-Path $fixtureRoot 'Pester'
                    New-Item -ItemType Directory -Path $secondBase -ErrorAction Stop | Out-Null
                    [IO.File]::WriteAllText((Join-Path $secondBase 'Pester.psd1'), "@{ ModuleVersion = '5.7.1' }")
                    $second = [pscustomobject]@{ Name = 'Pester'; Version = [version]'5.7.1'; ModuleBase = $secondBase }
                    Mock Get-Module -ModuleName $module.Name -MockWith { @($candidate, $second) }
                }
                'wrong_versions_only' {
                    $wrong = [pscustomobject]@{ Name = 'Pester'; Version = [version]'5.7.0'; ModuleBase = $installed.ModuleBase }
                    Mock Get-Module -ModuleName $module.Name -MockWith { @($wrong) }
                }
                'enumeration_throws' { Mock Get-Module -ModuleName $module.Name -MockWith { throw 'fixture enumeration failure' } }
                default { throw "Unexpected resolver case: $case_id" }
            }

            $actual = Resolve-WinsmuxPesterModule
            $actual.status | Should -Be $expected_status
            if ($expected_status -eq 'resolved') {
                $actual.selected_module.present | Should -BeTrue
                $actual.selected_module.name | Should -Be 'Pester'
                $actual.selected_module.semantic_version | Should -Be '5.7.1'
                [IO.Path]::IsPathFullyQualified($actual.selected_module.manifest_path) | Should -BeTrue
            } else {
                $actual.selected_module.present | Should -BeFalse
                $actual.selected_module.name | Should -Be ''
                $actual.selected_module.semantic_version | Should -Be ''
                $actual.selected_module.manifest_path | Should -Be ''
            }
            Should -Invoke Get-Module -ModuleName $module.Name -Times 1 -Exactly
        } finally {
            if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
            Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exports a callable resolver only from the exact module' {
        $script:ModulePath | Should -Exist -Because 'scripts/winsmux-pester.psm1 is the sole TASK-810 module location'
        $module = Import-Module -Name $script:ModulePath -PassThru -ErrorAction Stop
        try {
            Get-Command -Module $module.Name -Name 'Resolve-WinsmuxPesterModule' -ErrorAction Stop | Should -Not -BeNullOrEmpty
        } finally {
            Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'TASK-810 literal Pester identity evidence' {
    It 'observes positive negative and assertion selections from real Pester Path values' {
        $identityScript = {
            Describe 'TASK810 identity fixture' {
                It 'literal selected' { 1 | Should -Be 1 }
                It 'assertion selected' { 1 | Should -Be 2 }
            }
        }
        $literalIdentity = 'TASK810 identity fixture.literal selected'
        $positiveConfiguration = New-PesterConfiguration
        $positiveConfiguration.Run.ScriptBlock = $identityScript
        $positiveConfiguration.Run.PassThru = $true
        $positiveConfiguration.Output.Verbosity = 'None'
        $positiveConfiguration.Filter.FullName = @([WildcardPattern]::Escape($literalIdentity))
        $positive = Invoke-Pester -Configuration $positiveConfiguration
        $positiveTests = @($positive.Tests)
        $positiveIds = [string[]]@($positiveTests | ForEach-Object {
            $_.Path.GetType().GetGenericTypeDefinition().FullName | Should -Be 'System.Collections.Generic.List`1'
            $_.Path.GetType().GetGenericArguments()[0].FullName | Should -Be 'System.String'
            ([string]($_.Path -join '.'))
        })
        $shouldRun = [string[]]@($positiveTests | Where-Object ShouldRun | ForEach-Object { [string]($_.Path -join '.') })
        $executed = [string[]]@($positiveTests | Where-Object Executed | ForEach-Object { [string]($_.Path -join '.') })
        $positiveIds.Count | Should -Be 2
        $shouldRun.Count | Should -Be 1
        $executed.Count | Should -Be 1
        [StringComparer]::Ordinal.Equals($shouldRun[0], $literalIdentity) | Should -BeTrue
        [StringComparer]::Ordinal.Equals($executed[0], $literalIdentity) | Should -BeTrue

        $negativeConfiguration = New-PesterConfiguration
        $negativeConfiguration.Run.ScriptBlock = $identityScript
        $negativeConfiguration.Run.PassThru = $true
        $negativeConfiguration.Output.Verbosity = 'None'
        $negativeConfiguration.Filter.FullName = @([WildcardPattern]::Escape('TASK810 identity fixture.no match'))
        $negative = Invoke-Pester -Configuration $negativeConfiguration
        @($negative.Tests | Where-Object ShouldRun).Count | Should -Be 0
        @($negative.Tests | Where-Object Executed).Count | Should -Be 0

        $assertionIdentity = 'TASK810 identity fixture.assertion selected'
        $assertionConfiguration = New-PesterConfiguration
        $assertionConfiguration.Run.ScriptBlock = $identityScript
        $assertionConfiguration.Run.PassThru = $true
        $assertionConfiguration.Output.Verbosity = 'None'
        $assertionConfiguration.Filter.FullName = @([WildcardPattern]::Escape($assertionIdentity))
        $assertion = Invoke-Pester -Configuration $assertionConfiguration
        $assertionTest = @($assertion.Tests | Where-Object Executed)[0]
        [StringComparer]::Ordinal.Equals(([string]($assertionTest.Path -join '.')), $assertionIdentity) | Should -BeTrue
        [StringComparer]::Ordinal.Equals($assertionTest.ErrorRecord[0].FullyQualifiedErrorId, 'PesterAssertionFailed') | Should -BeTrue

        $duplicateScript = {
            Describe 'TASK810 duplicate fixture' {
                It 'duplicate' { 1 | Should -Be 1 }
                It 'duplicate' { 1 | Should -Be 1 }
            }
        }
        $duplicateConfiguration = New-PesterConfiguration
        $duplicateConfiguration.Run.ScriptBlock = $duplicateScript
        $duplicateConfiguration.Run.PassThru = $true
        $duplicateConfiguration.Output.Verbosity = 'None'
        $duplicate = Invoke-Pester -Configuration $duplicateConfiguration
        $duplicateIds = [string[]]@($duplicate.Tests | ForEach-Object { [string]($_.Path -join '.') })
        @($duplicateIds | Sort-Object -Unique).Count | Should -BeLessThan $duplicateIds.Count
    }

    It 'keeps selected-module identity limited to the approved Pester name and semantic version' {
        $script:SelectedModuleKeys | Should -BeExactly @('present', 'name', 'semantic_version', 'manifest_path')
        $script:ModulePath | Should -Exist
        $moduleSource = Get-Content -Raw -LiteralPath $script:ModulePath
        $moduleSource | Should -Match '(?i)\bPester\b'
        $moduleSource | Should -Match '\b5\.7\.1\b'
        $moduleSource | Should -Match 'manifest_path'
    }
}

Describe 'TASK-810 producer state table' {
    It 'drives the isolated copied runner to frozen producer row <id>' -ForEach $script:ProducerCases {
        $integration = @($script:RegistryRows | Where-Object { $_.shard_id -eq 'integration' })[0]
        $expected = [pscustomobject]@{ resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'failed'; failure_origin = 'assertion'; workflow_action = 'fail'; pester_invoked = $true; error_code = 'pester_result_file_missing'; selected_module = 'present' }
        $expected.resolution_status = $resolution_status
        $expected.execution_status = $execution_status
        $expected.test_outcome = $test_outcome
        $expected.failure_origin = $failure_origin
        $expected.workflow_action = $workflow_action
        $expected.pester_invoked = $pester_invoked
        $expected.error_code = $error_code
        $expected.selected_module = $selected_module
        $runnerShardId = if ($id -eq 'P01') { '' } elseif ($id -eq 'P00') { 'not-a-registered-shard' } else { 'integration' }
        $invoke = @{ CaseId = $id; ShardId = $runnerShardId }
        switch ($id) {
            'P02' { $invoke.DuplicateRegistry = $true }
            'P03' { $invoke.PrecreateResult = $true }
            'P04' { $invoke.PesterVersions = @('5.6.0') }
            'P05' { $invoke.PesterVersions = @('5.7.1', '5.7.1') }
            'P06' { $invoke.ResolverThrows = $true }
            'P07' { $invoke.ImportThrows = $true }
            'P08' { $invoke.Phase = @{ mode = 'configuration_throw' } }
            'P09' { $invoke.Phase = @{ mode = 'invoke_throw' } }
            'P10' { $invoke.Phase = @{ invalid = 'count_mismatch' } }
            'P11' { $invoke.Phase = @{ passed = $true } }
            'P12' { $invoke.Phase = @{ assertion = $true } }
            'P13' { $invoke.Phase = @{ runtime = $true } }
            'P14' { $invoke.Phase = @{ block = $true } }
            'P15' { $invoke.Phase = @{ assertion = $true; runtime = $true; block = $true } }
            'P16' { $invoke.Phase = @{ passed = $true; write_result = $true } }
            'P17' { $invoke.Phase = @{ assertion = $true; write_result = $true } }
            'P18' { $invoke.Phase = @{ runtime = $true; write_result = $true } }
            'P19' { $invoke.Phase = @{ block = $true; write_result = $true } }
            'P20' { $invoke.Phase = @{ assertion = $true; runtime = $true; block = $true; write_result = $true } }
        }

        $case = Invoke-Task810IsolatedRunnerCase @invoke
        $expectedResultFile = if ($result_file_state -eq 'empty') { '' } else { $integration.result_file }
        $artifactState = if ($result_file_state -eq 'empty' -or $result_file_state -eq 'absent') { 'absent' } elseif ($result_file_state -eq 'present') { 'present' } else { 'either' }
        $envelope = Assert-Task810IsolatedRunnerCase -Case $case -Expected $expected -ExpectedResultFile $expectedResultFile -ExpectedShardId $runnerShardId -ArtifactState $artifactState
        if ($id -eq 'P03') {
            $case.artifact_before | Should -Not -BeNullOrEmpty
            $case.artifact_after | Should -Not -BeNullOrEmpty
            [Convert]::ToBase64String($case.artifact_after.bytes) | Should -Be ([Convert]::ToBase64String($case.artifact_before.bytes))
            $case.artifact_after.hash | Should -Be $case.artifact_before.hash
            $case.artifact_after.length | Should -Be $case.artifact_before.length
            $case.artifact_after.creation_time_utc | Should -Be $case.artifact_before.creation_time_utc
            $case.artifact_after.last_write_time_utc | Should -Be $case.artifact_before.last_write_time_utc
            $case.artifact_after.attributes | Should -Be $case.artifact_before.attributes
        }
    }
}

Describe 'TASK-810 all eight A/T/B origin rows' {
    It 'drives A=<a> T=<t> B=<b> through the real runner classifier' -ForEach $script:OriginTruthCases {
        $case = Invoke-Task810IsolatedRunnerCase -CaseId ("origin-$a-$t-$b") -ShardId 'integration' -Phase @{ assertion = $a; runtime = $t; block = $b; passed = (-not ($a -or $t -or $b)) }
        $expected = [pscustomobject]@{ resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = if ($a -or $t -or $b) { 'failed' } else { 'passed' }; failure_origin = $failure_origin; workflow_action = 'fail'; pester_invoked = $true; error_code = 'pester_result_file_missing'; selected_module = 'present' }
        Assert-Task810IsolatedRunnerCase -Case $case -Expected $expected -ExpectedResultFile 'test-results-integration.xml' -ExpectedShardId 'integration' -ArtifactState 'absent' | Out-Null
    }

    It 'fails closed for contradictory counts and invalid failed-test evidence while handling selected-not-executed' {
        $invalidExpected = [pscustomobject]@{ resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'not_run'; failure_origin = 'none'; workflow_action = 'fail'; pester_invoked = $true; error_code = 'pester_result_invalid'; selected_module = 'present' }
        foreach ($invalid in @('passed_with_failure', 'failed_without_entry', 'count_mismatch', 'executed_failure_without_error')) {
            $case = Invoke-Task810IsolatedRunnerCase -CaseId "invalid-$invalid" -ShardId 'integration' -Phase @{ invalid = $invalid }
            Assert-Task810IsolatedRunnerCase -Case $case -Expected $invalidExpected -ExpectedResultFile 'test-results-integration.xml' -ExpectedShardId 'integration' -ArtifactState 'absent' | Out-Null
        }

        $selectedNotExecuted = Invoke-Task810IsolatedRunnerCase -CaseId 'selected-not-executed' -ShardId 'integration' -Phase @{ selected_not_executed = $true }
        $selectedExpected = [pscustomobject]@{ resolution_status = 'resolved'; execution_status = 'completed'; test_outcome = 'failed'; failure_origin = 'block_or_container'; workflow_action = 'fail'; pester_invoked = $true; error_code = 'pester_result_file_missing'; selected_module = 'present' }
        Assert-Task810IsolatedRunnerCase -Case $selectedNotExecuted -Expected $selectedExpected -ExpectedResultFile 'test-results-integration.xml' -ExpectedShardId 'integration' -ArtifactState 'absent' | Out-Null
    }
}

Describe 'TASK-810 consumer state table' {
BeforeAll {
function Get-Task810ConsumerBody {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('matrix', 'desktop')][string]$Job,
        [Parameter(Mandatory = $true)][string]$WorkflowPath
    )

    $lines = [IO.File]::ReadAllLines($WorkflowPath)
    $begin = "# TASK-810 consumer begin: $Job"
    $end = "# TASK-810 consumer end: $Job"
    $beginIndexes = @(
        for ($index = 0; $index -lt $lines.Count; $index += 1) {
            if ($lines[$index].Trim() -eq $begin) { $index }
        }
    )
    $endIndexes = @(
        for ($index = 0; $index -lt $lines.Count; $index += 1) {
            if ($lines[$index].Trim() -eq $end) { $index }
        }
    )
    $beginIndexes.Count | Should -Be 1 -Because "the $Job workflow consumer has one unique begin boundary"
    $endIndexes.Count | Should -Be 1 -Because "the $Job workflow consumer has one unique end boundary"
    $endIndexes[0] | Should -BeGreaterThan $beginIndexes[0] -Because 'consumer boundaries must preserve phase order'
    return [string]::Join([Environment]::NewLine, $lines[($beginIndexes[0] + 1)..($endIndexes[0] - 1)])
}

function Get-Task810ConsumerEnvelope {
    param(
        [Parameter(Mandatory = $true)][object]$ProducerSnapshot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CallerId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ArtifactName,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $resultName = if ($ProducerSnapshot.result_file_state -eq 'empty') { '' } else { $ArtifactName }
    $module = [ordered]@{ present = ($ProducerSnapshot.selected_module -eq 'present'); name = ''; semantic_version = ''; manifest_path = '' }
    if ($module.present) {
        $module.name = 'Pester'
        $module.semantic_version = '5.7.1'
        $module.manifest_path = $ManifestPath
    }
    return [ordered]@{
        schema_version = '1'
        shard_id = $CallerId
        resolution_status = $ProducerSnapshot.resolution_status
        execution_status = $ProducerSnapshot.execution_status
        test_outcome = $ProducerSnapshot.test_outcome
        failure_origin = $ProducerSnapshot.failure_origin
        workflow_action = $ProducerSnapshot.workflow_action
        pester_invoked = [bool]$ProducerSnapshot.pester_invoked
        result_file = $resultName
        error_code = $ProducerSnapshot.error_code
        selected_module = $module
    }
}

function Invoke-Task810ConsumerFixture {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Variant,
        [Parameter(Mandatory = $true)][string]$WorkflowPath
    )

    $consumerBody = Get-Task810ConsumerBody -Job $Variant.job -WorkflowPath $WorkflowPath
    $caseRoot = Join-Path $TestDrive ("task810-consumer-" + [guid]::NewGuid().ToString('N'))
    $scriptsRoot = Join-Path $caseRoot 'scripts'
    $modulesRoot = Join-Path $caseRoot 'modules/Pester/5.7.1'
    New-Item -ItemType Directory -Path $scriptsRoot -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $modulesRoot -Force -ErrorAction Stop | Out-Null
    $artifactName = if ($Variant.job -eq 'desktop') { 'test-results-desktop-debug-v03630.xml' } else { 'test-results-integration.xml' }
    $artifactPath = Join-Path $caseRoot $artifactName
    $manifestPath = Join-Path $modulesRoot 'Pester.psd1'
    Write-Task810Utf8File -Path $manifestPath -Content "@{ RootModule = 'Pester.psm1'; ModuleVersion = '5.7.1' }"
    Write-Task810Utf8File -Path (Join-Path $modulesRoot 'Other.psd1') -Content "@{ RootModule = 'Other.psm1'; ModuleVersion = '5.7.1' }"

    $calls = @()
    foreach ($call in @($Variant.calls)) {
        $calls += [ordered]@{
            producer_row = $call.producer_row
            capture = $call.capture
            mutation = $call.mutation
            file_at_emission = $call.file_at_emission
            file_after_return = $call.file_after_return
            preexisting = [bool](Get-Task810OptionalValue -Object $call -Name 'preexisting' -Default $false)
            envelope = Get-Task810ConsumerEnvelope -ProducerSnapshot $call.producer_snapshot -CallerId $Variant.caller_id -ArtifactName $artifactName -ManifestPath $manifestPath
        }
    }
    if (@($calls | Where-Object { $_.preexisting }).Count -gt 0) {
        [IO.File]::WriteAllBytes($artifactPath, [byte[]](17, 34, 51, 68))
    }
    $artifactBefore = if (Test-Path -LiteralPath $artifactPath) {
        $item = Get-Item -LiteralPath $artifactPath
        [pscustomobject]@{ bytes = [IO.File]::ReadAllBytes($artifactPath); length = $item.Length; creation_time_utc = $item.CreationTimeUtc; last_write_time_utc = $item.LastWriteTimeUtc; attributes = $item.Attributes }
    } else { $null }
    $scenario = [ordered]@{
        case_id = $Variant.name
        caller_id = $Variant.caller_id
        artifact_path = $artifactPath
        event_path = (Join-Path $caseRoot 'events.jsonl')
        repository_present = [bool](Get-Task810OptionalValue -Object $Variant -Name 'repository_present' -Default $true)
        registration_throws = [bool](Get-Task810OptionalValue -Object $Variant -Name 'registration_throws' -Default $false)
        trust_set_throws = [bool](Get-Task810OptionalValue -Object $Variant -Name 'trust_set_throws' -Default $false)
        install_throws = [bool](Get-Task810OptionalValue -Object $Variant -Name 'install_throws' -Default $false)
        calls = $calls
    }
    $scenarioPath = Join-Path $caseRoot 'scenario.json'
    Write-Task810Utf8File -Path $scenarioPath -Content ($scenario | ConvertTo-Json -Depth 10 -Compress)

    $runnerSource = @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$ShardId)
$scenario = Get-Content -Raw -LiteralPath (Join-Path (Get-Location) 'scenario.json') | ConvertFrom-Json -AsHashtable
$statePath = Join-Path (Get-Location) 'runner-state.txt'
$index = if (Test-Path -LiteralPath $statePath) { [int](Get-Content -Raw -LiteralPath $statePath) } else { 0 }
[IO.File]::WriteAllText($statePath, [string]($index + 1))
$call = $scenario.calls[$index]
function Add-Task810Event([hashtable]$Value) { Add-Content -LiteralPath $scenario.event_path -Value ($Value | ConvertTo-Json -Compress) -Encoding utf8 }
function Test-Task810Artifact { Test-Path -LiteralPath $scenario.artifact_path }
Add-Task810Event @{ phase = 'call-started'; call_index = $index; producer_row = $call.producer_row; shard_id = $ShardId }
if ($call.file_at_emission -eq 'present' -and -not (Test-Task810Artifact)) { [IO.File]::WriteAllText($scenario.artifact_path, 'fixture-result') }
$envelope = $call.envelope
if ($call.mutation) {
    # Hashtable edits deliberately preserve the valid producer envelope as the mutation source.
    switch ($call.mutation) {
        'root_keys' { [void]$envelope.Remove('error_code') }
        'nested_keys' { [void]$envelope.selected_module.Remove('name') }
        'json_type' { $envelope.pester_invoked = 'true' }
        'enum' { $envelope.error_code = 'fixture_invalid_enum' }
        'case_resolution_status' { $envelope.resolution_status = $envelope.resolution_status.ToUpperInvariant() }
        'case_execution_status' { $envelope.execution_status = $envelope.execution_status.ToUpperInvariant() }
        'case_test_outcome' { $envelope.test_outcome = $envelope.test_outcome.ToUpperInvariant() }
        'case_failure_origin' { $envelope.failure_origin = $envelope.failure_origin.ToUpperInvariant() }
        'case_workflow_action' { $envelope.workflow_action = $envelope.workflow_action.ToUpperInvariant() }
        'case_error_code' { $envelope.error_code = $envelope.error_code.ToUpperInvariant() }
        'schema' { $envelope.schema_version = '2' }
        'caller' { $envelope.shard_id = 'fixture-wrong-caller' }
        'result' { $envelope.result_file = 'test-results-fixture-other.xml' }
        'empty_result_file' { $envelope.result_file = '' }
        'module' { $envelope.selected_module.present = $false }
        'relative_manifest_path' { $envelope.selected_module.manifest_path = 'modules/Pester/5.7.1/Pester.psd1' }
        'non_normalized_manifest_path' { $envelope.selected_module.manifest_path = Join-Path (Get-Location) 'modules/Pester/5.7.1/../5.7.1/Pester.psd1' }
        'wrong_leaf_manifest_path' { $envelope.selected_module.manifest_path = Join-Path (Get-Location) 'modules/Pester/5.7.1/Other.psd1' }
        'nonexistent_manifest_path' { $envelope.selected_module.manifest_path = Join-Path (Get-Location) 'modules/Pester/5.7.1/Missing/Pester.psd1' }
        'origin' { $envelope.failure_origin = 'assertion' }
        'producer' { $envelope.workflow_action = 'fail' }
        default { throw 'fixture mutation is not admitted' }
    }
}
$json = $envelope | ConvertTo-Json -Depth 8 -Compress
Add-Task810Event @{ phase = 'json-emitted'; call_index = $index; producer_row = $call.producer_row; shard_id = $ShardId; artifact_exists = (Test-Task810Artifact); mutation = $call.mutation }
switch ($call.capture) {
    'two_strings' { Write-Output $json; Write-Output $json }
    'object' { Write-Output ([pscustomobject]@{ fixture = 'non-string' }) }
    'two_lines' { Write-Output ($json + "`nfixture-second-line") }
    'invalid_json' { Write-Output '{fixture-invalid-json' }
    default { Write-Output $json }
}
if ($call.file_after_return -eq 'absent' -and (Test-Task810Artifact)) { Remove-Item -LiteralPath $scenario.artifact_path -Force }
if ($call.capture -eq 'partial_throw') { Add-Task810Event @{ phase = 'intentional-throw'; call_index = $index; producer_row = $call.producer_row }; throw 'fixture runner throw' }
Add-Task810Event @{ phase = 'call-completed'; call_index = $index; producer_row = $call.producer_row; artifact_exists = (Test-Task810Artifact) }
'@
    Write-Task810Utf8File -Path (Join-Path $scriptsRoot 'run-pester-shard.ps1') -Content $runnerSource

    $escapedCaller = ([string]$Variant.caller_id).Replace("'", "''")
    $escapedResult = ($artifactName -replace '^test-results-', '' -replace '\.xml$', '').Replace("'", "''")
    if ($Variant.job -eq 'matrix') {
        $consumerBody = $consumerBody -replace '\$\{\{\s*matrix\.name\s*\}\}', $escapedCaller
        $consumerBody = $consumerBody -replace '\$\{\{\s*matrix\.result\s*\}\}', $escapedResult
    }
    $childPath = Join-Path $caseRoot 'invoke-consumer.ps1'
    $childSource = @'
param([Parameter(Mandatory = $true)][string]$CaseRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $CaseRoot
$scenario = Get-Content -Raw -LiteralPath (Join-Path $CaseRoot 'scenario.json') | ConvertFrom-Json -AsHashtable
function Add-Task810Event([hashtable]$Value) { Add-Content -LiteralPath $scenario.event_path -Value ($Value | ConvertTo-Json -Compress) -Encoding utf8 }
function global:Install-Module {
    param([string]$Name, [switch]$Force, [string]$Scope, [version]$RequiredVersion, [string]$Repository, [System.Management.Automation.ActionPreference]$ErrorAction)
    Add-Task810Event @{ phase = 'install-invoked'; name = $Name; force = [bool]$Force; scope = $Scope; required_version = [string]$RequiredVersion; repository = $Repository }
    if ($scenario.install_throws) { throw 'fixture install throw' }
}
function global:Get-PSRepository {
    param([string]$Name, [System.Management.Automation.ActionPreference]$ErrorAction)
    Add-Task810Event @{ phase = 'repository-lookup'; name = $Name }
    if ($scenario.repository_present) { [pscustomobject]@{ Name = $Name } }
}
function global:Register-PSRepository {
    param([switch]$Default, [System.Management.Automation.ActionPreference]$ErrorAction)
    Add-Task810Event @{ phase = 'repository-register'; default = [bool]$Default }
    if ($scenario.registration_throws) { throw 'fixture repository registration throw' }
}
function global:Set-PSRepository {
    param([string]$Name, [string]$InstallationPolicy, [System.Management.Automation.ActionPreference]$ErrorAction)
    Add-Task810Event @{ phase = 'repository-set'; name = $Name; installation_policy = $InstallationPolicy }
    if ($scenario.trust_set_throws) { throw 'fixture repository trust-set throw' }
}
function global:Remove-Item {
    param([string[]]$Path, [string[]]$LiteralPath, [switch]$Recurse, [switch]$Force, [System.Management.Automation.ActionPreference]$ErrorAction)
    Add-Task810Event @{ phase = 'remove-item'; path = [string[]]@(@($Path) + @($LiteralPath) | Where-Object { -not [string]::IsNullOrEmpty($_) }) }
    $forward = @{}; foreach ($entry in $PSBoundParameters.GetEnumerator()) { $forward[$entry.Key] = $entry.Value }
    Microsoft.PowerShell.Management\Remove-Item @forward
}
$env:WINSMUX_DBGGATE_APP_EXE = 'TASK810_ENV_SENTINEL_APP'
$env:WINSMUX_DBGGATE_PORT = 'TASK810_ENV_SENTINEL_PORT'
'@
    $childSource += [Environment]::NewLine + $consumerBody + [Environment]::NewLine
    Write-Task810Utf8File -Path $childPath -Content $childSource
    $stdoutPath = Join-Path $caseRoot 'stdout.txt'
    $stderrPath = Join-Path $caseRoot 'stderr.txt'
    & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -File $childPath -CaseRoot $caseRoot 1> $stdoutPath 2> $stderrPath
    return [pscustomobject]@{
        variant = $Variant
        exit_code = $LASTEXITCODE
        case_root = $caseRoot
        artifact_path = $artifactPath
        manifest_path = $manifestPath
        scenario_path = $scenarioPath
        body_path = $childPath
        artifact_before = $artifactBefore
        artifact_after = if (Test-Path -LiteralPath $artifactPath) {
            $item = Get-Item -LiteralPath $artifactPath
            [pscustomobject]@{ bytes = [IO.File]::ReadAllBytes($artifactPath); length = $item.Length; creation_time_utc = $item.CreationTimeUtc; last_write_time_utc = $item.LastWriteTimeUtc; attributes = $item.Attributes }
        } else { $null }
        stdout = [IO.File]::ReadAllText($stdoutPath)
        stderr = [IO.File]::ReadAllText($stderrPath)
        events = @(if (Test-Path -LiteralPath $scenario.event_path) { Get-Content -LiteralPath $scenario.event_path | ForEach-Object { $_ | ConvertFrom-Json } })
    }
}

function Assert-Task810ConsumerFixture {
    param([Parameter(Mandatory = $true)][pscustomobject]$Case)

    $variant = $Case.variant
    $Case.exit_code | Should -Be $variant.expected_exit
    $events = @($Case.events)
    $started = @($events | Where-Object phase -eq 'call-started')
    $emitted = @($events | Where-Object phase -eq 'json-emitted')
    $completed = @($events | Where-Object { $_.phase -in @('call-completed', 'intentional-throw') })
    $started.Count | Should -Be @($variant.calls).Count
    $emitted.Count | Should -Be @($variant.calls).Count
    $completed.Count | Should -Be @($variant.calls).Count
    for ($index = 0; $index -lt @($variant.calls).Count; $index += 1) {
        $call = @($variant.calls)[$index]
        $started[$index].producer_row | Should -Be $call.producer_row
        $started[$index].shard_id | Should -Be $variant.caller_id
        $emitted[$index].producer_row | Should -Be $call.producer_row
        $emitted[$index].shard_id | Should -Be $variant.caller_id
        $emitted[$index].artifact_exists | Should -Be ($call.file_at_emission -eq 'present')
    }
    $installs = @($events | Where-Object phase -eq 'install-invoked')
    $installs.Count | Should -Be $variant.expected_install_count
    foreach ($install in $installs) {
        $install.name | Should -Be 'Pester'; $install.force | Should -BeTrue; $install.scope | Should -Be 'CurrentUser'
        $install.required_version | Should -Be '5.7.1'; $install.repository | Should -Be 'PSGallery'
    }
    $prerequisiteEvents = @($events | Where-Object { $_.phase -in @('repository-lookup', 'repository-register', 'repository-set', 'install-invoked') } | ForEach-Object { [string]$_.phase })
    $expectedPrerequisiteEvents = [string[]]@(Get-Task810OptionalValue -Object $variant -Name 'expected_prerequisite_events' -Default @())
    $prerequisiteEvents | Should -BeExactly $expectedPrerequisiteEvents
    if (@($variant.calls | Where-Object { [bool](Get-Task810OptionalValue -Object $_ -Name 'preexisting' -Default $false) }).Count -gt 0) {
        [Convert]::ToBase64String($Case.artifact_after.bytes) | Should -Be ([Convert]::ToBase64String($Case.artifact_before.bytes))
        $Case.artifact_after.length | Should -Be $Case.artifact_before.length
        $Case.artifact_after.creation_time_utc | Should -Be $Case.artifact_before.creation_time_utc
        $Case.artifact_after.last_write_time_utc | Should -Be $Case.artifact_before.last_write_time_utc
        $Case.artifact_after.attributes | Should -Be $Case.artifact_before.attributes
    }
    $lastCall = @($variant.calls)[@($variant.calls).Count - 1]
    ($null -ne $Case.artifact_after) | Should -Be ($lastCall.file_after_return -eq 'present')
    if ($variant.desktop_cleanup) {
        $cleanupTargets = [string[]]@($events | Where-Object phase -eq 'remove-item' | ForEach-Object { @($_.path) })
        $cleanupTargets | Should -BeExactly @('Env:WINSMUX_DBGGATE_APP_EXE', 'Env:WINSMUX_DBGGATE_PORT')
    }
    $combinedOutput = $Case.stdout + $Case.stderr
    foreach ($sensitive in @([string]$variant.caller_id, 'TASK810_ENV_SENTINEL_APP', 'TASK810_ENV_SENTINEL_PORT', '"schema_version"', 'fixture runner throw', 'fixture install throw', $Case.case_root, $Case.artifact_path, $Case.manifest_path, $Case.scenario_path, $Case.body_path)) {
        if ($sensitive.Length -gt 0) { $combinedOutput | Should -Not -Match ([Regex]::Escape($sensitive)) }
    }
}

}

    It 'drives the exact future consumer through frozen row <id>' -ForEach $script:ConsumerCases {
        if ($id -in @('C02', 'C03')) {
            $negativeVariants = @($variants)
            $negativeVariants.Count | Should -Be 22
            foreach ($variant in $negativeVariants) {
                @($variant.calls).Count | Should -Be 1
                $variant.expected_exit | Should -Be 2
                $variant.expected_install_count | Should -Be 0
            }
            $logicalPairs = @($negativeVariants | Group-Object -Property {
                $call = @($_.calls)[0]
                '{0}|{1}|{2}|{3}|{4}' -f $call.producer_row, $call.capture, $call.mutation, $call.file_at_emission, $call.file_after_return
            })
            $logicalPairs.Count | Should -Be 11
            foreach ($pair in $logicalPairs) {
                $pair.Count | Should -Be 2
                $pairVariants = @($pair.Group)
                @($pairVariants.job | Sort-Object) | Should -BeExactly @('desktop', 'matrix')
                $desktop = @($pairVariants | Where-Object job -eq 'desktop')
                $matrix = @($pairVariants | Where-Object job -eq 'matrix')
                $desktop.Count | Should -Be 1
                $matrix.Count | Should -Be 1
                $desktop[0].caller_id | Should -Be 'desktop-debug-process'
                $matrix[0].caller_id | Should -Be 'integration'
                $desktop[0].desktop_cleanup | Should -BeTrue
                $matrix[0].desktop_cleanup | Should -BeFalse
                foreach ($field in @('producer_row', 'capture', 'mutation', 'file_at_emission', 'file_after_return')) {
                    $desktopCall = @($desktop[0].calls)[0]
                    $matrixCall = @($matrix[0].calls)[0]
                    $desktopCall.$field | Should -Be $matrixCall.$field
                }
            }
        }
        foreach ($variant in @($variants)) {
            $case = Invoke-Task810ConsumerFixture -Variant $variant -WorkflowPath $workflow_path
            Assert-Task810ConsumerFixture -Case $case
        }
    }
}

Describe 'TASK-810 result artifact state and envelope closure' {
    It 'uses only the approved root and nested envelope keys and enums' {
        $script:EnvelopeRootKeys.Count | Should -Be 11
        $script:SelectedModuleKeys.Count | Should -Be 4
        $script:ExpectedErrorCodes.Count | Should -Be 14
        @($script:EnvelopeRootKeys | Sort-Object -Unique).Count | Should -Be $script:EnvelopeRootKeys.Count
        @($script:SelectedModuleKeys | Sort-Object -Unique).Count | Should -Be $script:SelectedModuleKeys.Count
    }

    It 'keeps the original staging result path absent after isolated fixture cases' {
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'test-results-integration.xml') | Should -BeFalse
    }
}

Describe 'TASK-810 local runner workflow topology and security prohibitions' {
    It 'requires only the approved module and runner entry points' {
        $script:ModulePath | Should -Exist
        $script:RunnerPath | Should -Exist
        $runner = Get-Content -Raw -LiteralPath $script:RunnerPath
        $runner | Should -Match 'Resolve-WinsmuxPesterShard'
        $runner | Should -Not -Match '(?im)\b(Install-Module|Start-Process|ProcessStartInfo|GITHUB_OUTPUT|exit\s+)'
    }

    It 'keeps workflow ownership in one same-runspace path with no transport, loop, or public parameter' {
        $script:WorkflowPath | Should -Exist
        $script:RunTestsPath | Should -Exist
        $script:CoverageValidatorPath | Should -Exist
        $workflow = Get-Content -Raw -LiteralPath $script:WorkflowPath
        $workflow | Should -Match 'run-pester-shard\.ps1'
        ([regex]::Matches($workflow, [regex]::Escape('scripts/assert-pester-shard-coverage.ps1'))).Count | Should -Be 1
        $workflow | Should -Not -Match '(?im)(GITHUB_OUTPUT|ProcessStartInfo|Start-Process|continue-on-error|\bwhile\b|\bforeach\b|\bStart-Sleep\b)'
    }
}

AfterAll {
    Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'test-results-integration.xml') | Should -BeFalse -Because 'Pester TestDrive owns all fixture cleanup and the staging artifact is never a fixture target'
}
