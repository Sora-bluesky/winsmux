$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'winsmux control-plane command module' {
    BeforeAll {
        $script:winsmuxCoreCommandRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreCommandRawContent = Get-Content -Path $script:winsmuxCoreCommandRawPath -Raw -Encoding UTF8
        $script:controlPlaneCommandsPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\control-plane-commands.ps1'
        $script:controlPlaneCommandsContent = Get-Content -Path $script:controlPlaneCommandsPath -Raw -Encoding UTF8
        $script:controlPlaneWorkersPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\control-plane-workers.ps1'
        $script:controlPlaneWorkersContent = Get-Content -Path $script:controlPlaneWorkersPath -Raw -Encoding UTF8
        $script:controlPlaneLedgerPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\control-plane-ledger.ps1'
        $script:controlPlaneLedgerContent = Get-Content -Path $script:controlPlaneLedgerPath -Raw -Encoding UTF8
        . $script:controlPlaneCommandsPath
    }

    It 'loads typed command helpers from the bridge script' {
        $script:winsmuxCoreCommandRawContent | Should -Match 'control-plane-commands\.ps1'
        $script:winsmuxCoreCommandRawContent | Should -Match '\. \$ControlPlaneCommandsScript'
        $script:controlPlaneCommandsContent | Should -Match 'function New-WinsmuxCommandResult'
        $script:controlPlaneCommandsContent | Should -Match 'function New-WinsmuxCommandError'
        $script:controlPlaneCommandsContent | Should -Match 'function Write-WinsmuxCommandResult'
    }

    It 'keeps workers workspace parsing in the workers command module' {
        $script:winsmuxCoreCommandRawContent | Should -Match 'control-plane-workers\.ps1'
        $script:winsmuxCoreCommandRawContent | Should -Match '\. \$ControlPlaneWorkersScript'
        $script:winsmuxCoreCommandRawContent | Should -Match "'workspace'\s*\{\s*Invoke-WinsmuxWorkersWorkspaceCommand"
        $script:winsmuxCoreCommandRawContent | Should -Not -Match 'function Read-WorkersWorkspaceOptions\s*\{'
        $script:winsmuxCoreCommandRawContent | Should -Not -Match 'function Invoke-WorkersWorkspacePrepare\s*\{'
        $script:winsmuxCoreCommandRawContent | Should -Not -Match 'function Invoke-WorkersWorkspaceCleanup\s*\{'
        $script:winsmuxCoreCommandRawContent | Should -Not -Match 'function Invoke-WorkersWorkspace\s*\{'
        $script:controlPlaneWorkersContent | Should -Match 'function Read-WinsmuxWorkersWorkspaceOptions'
        $script:controlPlaneWorkersContent | Should -Match 'function Invoke-WinsmuxWorkersWorkspacePrepare'
        $script:controlPlaneWorkersContent | Should -Match 'function Invoke-WinsmuxWorkersWorkspaceCleanup'
        $script:controlPlaneWorkersContent | Should -Match 'function Invoke-WinsmuxWorkersWorkspaceCommand'
    }

    It 'keeps run ledger payload builders in the ledger command module' {
        $script:winsmuxCoreCommandRawContent | Should -Match 'control-plane-ledger\.ps1'
        $script:winsmuxCoreCommandRawContent | Should -Match '\. \$ControlPlaneLedgerScript'
        $script:winsmuxCoreCommandRawContent | Should -Not -Match 'function Get-RunsPayload\s*\{'
        $script:winsmuxCoreCommandRawContent | Should -Not -Match 'function Get-ExplainPayload\s*\{'
        $script:winsmuxCoreCommandRawContent | Should -Not -Match 'function ConvertTo-CompareRunsPayload\s*\{'
        $script:winsmuxCoreCommandRawContent | Should -Not -Match 'function Get-PromoteTacticPayload\s*\{'
        $script:controlPlaneLedgerContent | Should -Match 'function Get-RunsPayload'
        $script:controlPlaneLedgerContent | Should -Match 'function Get-ExplainPayload'
        $script:controlPlaneLedgerContent | Should -Match 'function ConvertTo-CompareRunsPayload'
        $script:controlPlaneLedgerContent | Should -Match 'function Get-PromoteTacticPayload'
    }

    It 'keeps launcher and provider command parsing outside the top-level command table' {
        $script:winsmuxCoreCommandRawContent | Should -Match "'launcher'\s*\{\s*Invoke-WinsmuxLauncherCommand"
        $script:winsmuxCoreCommandRawContent | Should -Match "'provider-capabilities'\s*\{\s*Invoke-WinsmuxProviderCapabilitiesCommand"
        $script:winsmuxCoreCommandRawContent | Should -Match "'provider-switch'\s*\{\s*Invoke-WinsmuxProviderSwitchCommand"
        $script:winsmuxCoreCommandRawContent | Should -Not -Match 'function Invoke-Launcher\s*\{'
        $script:winsmuxCoreCommandRawContent | Should -Not -Match 'function Invoke-ProviderCapabilities\s*\{'
        $script:winsmuxCoreCommandRawContent | Should -Not -Match 'function Invoke-ProviderSwitch\s*\{'
        $script:controlPlaneCommandsContent | Should -Match 'function Invoke-WinsmuxLauncherCommand'
        $script:controlPlaneCommandsContent | Should -Match 'function Invoke-WinsmuxProviderCapabilitiesCommand'
        $script:controlPlaneCommandsContent | Should -Match 'function Invoke-WinsmuxProviderSwitchCommand'
    }

    It 'creates typed command result and error envelopes without changing public payload shape' {
        $result = New-WinsmuxCommandResult -CommandName 'provider-switch' -Status 'updated' -Data ([ordered]@{ slot_id = 'worker-1'; model = 'gpt-5.4' })
        $result.command | Should -Be 'provider-switch'
        $result.ok | Should -Be $true
        $result.status | Should -Be 'updated'
        $result.exit_code | Should -Be 0
        $result.data.slot_id | Should -Be 'worker-1'

        $error = New-WinsmuxCommandError -CommandName 'launcher' -Reason 'invalid_argument' -Message 'usage: winsmux launcher'
        $error.command | Should -Be 'launcher'
        $error.ok | Should -Be $false
        $error.status | Should -Be 'error'
        $error.reason | Should -Be 'invalid_argument'
        $error.exit_code | Should -Be 1
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

It 'marks and checks local worker heartbeats without exposing local paths' {
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
        $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:00Z'

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat mark w2 --run-id hb-local --state running --message "running from C:\work\secret.txt" --stalled-after 60 --offline-after 600 --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $serialized = $payload | ConvertTo-Json -Depth 24
        $heartbeatPath = Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-2\hb-local\heartbeat.json'

        $payload.status | Should -Be 'marked'
        $payload.health | Should -Be 'running'
        $payload.message | Should -Match '\[LOCAL_PATH_REDACTED\]'
        $payload.artifact | Should -Be '.winsmux/worker-runs/worker-2/hb-local/heartbeat.json'
        Test-Path -LiteralPath $heartbeatPath | Should -Be $true
        $serialized | Should -Not -Match ([regex]::Escape($script:workersTempRoot))

        $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:11:01Z'
        $checkOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat check w2 --run-id hb-local --stalled-after 60 --offline-after 600 --json --project-dir $script:workersTempRoot
        $checkPayload = ($checkOutput | Select-Object -Last 1) | ConvertFrom-Json

        $checkPayload.health | Should -Be 'offline'
        $checkPayload.reason | Should -Be 'heartbeat_expired'
        $checkPayload.age_seconds | Should -BeGreaterThan 600
    }

It 'keeps child run waiting separate from stopped or offline state' {
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
        $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:00Z'
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat mark w2 --run-id child-wait --state child_wait --message 'waiting for nested run' --json --project-dir $script:workersTempRoot | Out-Null

        $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T02:00:00Z'
        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat check w2 --run-id child-wait --stalled-after 60 --offline-after 600 --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $payload.health | Should -Be 'child_wait'
        $payload.reason | Should -Be 'child_run_waiting'
        $payload.waiting_for_child_run | Should -Be $true
        $payload.terminal | Should -Be $false
    }

It 'marks isolated worker heartbeats under the isolated run boundary' {
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
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id hb-isolated --json --project-dir $script:workersTempRoot | Out-Null
        $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:00Z'

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat mark w2 --run-id hb-isolated --profile isolated-enterprise --state approval_waiting --message 'operator approval required' --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $payload.status | Should -Be 'marked'
        $payload.execution_profile | Should -Be 'isolated-enterprise'
        $payload.health | Should -Be 'approval_waiting'
        $payload.requires_user | Should -Be $true
        $payload.artifact | Should -Be '.winsmux/isolated-workspaces/worker-2/hb-isolated/heartbeat.json'
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\hb-isolated\heartbeat.json') | Should -Be $true
    }

It 'includes worker heartbeat health in status rows for desktop consumers' {
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
        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot '.winsmux') -Force | Out-Null
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
                    last_heartbeat_run_id = 'hb-blocked'
                    last_heartbeat_profile = 'local-windows'
                }
            }
            tasks = [ordered]@{
                queued = @()
                in_progress = @()
                completed = @()
            }
            worktrees = [ordered]@{}
        })
        $runDir = Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-2\hb-blocked'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        [ordered]@{
            contract_version      = 1
            command               = 'workers.heartbeat'
            status                = 'marked'
            slot                  = 'w2'
            slot_id               = 'worker-2'
            run_id                = 'hb-blocked'
            execution_profile     = 'local-windows'
            state                 = 'blocked'
            message               = 'waiting for user'
            heartbeat_at          = '2026-05-16T00:00:00Z'
            stalled_after_seconds = 300
            offline_after_seconds = 900
            artifact              = '.winsmux/worker-runs/worker-2/hb-blocked/heartbeat.json'
        } | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $runDir 'heartbeat.json') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status worker-2 --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $row = @($payload.workers)[0]

        $row.slot_id | Should -Be 'worker-2'
        $row.execution_profile | Should -Be 'local-windows'
        $row.state | Should -Be 'blocked'
        $row.heartbeat_health | Should -Be 'blocked'
        $row.heartbeat_state | Should -Be 'blocked'
        $row.heartbeat.health | Should -Be 'blocked'
        $row.heartbeat.requires_user | Should -Be $true
        $row.heartbeat.artifact | Should -Be '.winsmux/worker-runs/worker-2/hb-blocked/heartbeat.json'
        $row.workspace.type | Should -Be 'local-project'
        $row.workspace.status | Should -Be 'local'
        $row.workspace.lifecycle | Should -Be 'project'
        $row.workspace.workspace | Should -Be '.'
        $row.secret_projection | Should -BeNullOrEmpty
    }

It 'does not let stale worker heartbeat override a manifest-bound lifecycle state' {
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
        $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:00Z'
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat mark worker-2 --run-id stale-run --state running --message 'old worker run' --json --project-dir $script:workersTempRoot | Out-Null

        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot '.winsmux') -Force | Out-Null
        Save-WinsmuxManifest -ProjectDir $script:workersTempRoot -Manifest ([ordered]@{
            version = 1
            saved_at = '2026-05-16T00:01:00Z'
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
                    status = 'deferred_start'
                    last_heartbeat_run_id = 'stale-run'
                    last_heartbeat_profile = 'local-windows'
                }
            }
            tasks = [ordered]@{
                queued = @()
                in_progress = @()
                completed = @()
            }
            worktrees = [ordered]@{}
        })

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status worker-2 --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $row = @($payload.workers)[0]

        $row.state | Should -Be 'deferred_start'
        $row.heartbeat_health | Should -Be 'running'
        $row.heartbeat.run_id | Should -Be 'stale-run'
    }

It 'does not let orphan heartbeat artifacts drive unlaunched worker status' {
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
        $runDir = Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-2\orphan-run'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        [ordered]@{
            contract_version      = 1
            command               = 'workers.heartbeat'
            status                = 'marked'
            slot                  = 'w2'
            slot_id               = 'worker-2'
            run_id                = 'orphan-run'
            execution_profile     = 'local-windows'
            state                 = 'running'
            message               = 'orphaned old worker'
            heartbeat_at          = '2026-05-16T00:00:00Z'
            stalled_after_seconds = 300
            offline_after_seconds = 900
            artifact              = '.winsmux/worker-runs/worker-2/orphan-run/heartbeat.json'
        } | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $runDir 'heartbeat.json') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status worker-2 --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $row = @($payload.workers)[0]

        $row.state | Should -Be 'not_launched'
        $row.heartbeat_health | Should -Be ''
        $row.heartbeat | Should -BeNullOrEmpty
    }

It 'expires self-reported stalled heartbeats after the offline window' {
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
        $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:00Z'
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat mark worker-2 --run-id self-stalled --state stalled --stalled-after 60 --offline-after 600 --json --project-dir $script:workersTempRoot | Out-Null

        $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:11:01Z'
        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat check worker-2 --run-id self-stalled --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $payload.state | Should -Be 'stalled'
        $payload.health | Should -Be 'offline'
        $payload.reason | Should -Be 'heartbeat_expired'
        $payload.age_seconds | Should -BeGreaterThan 600
    }

It 'returns offline heartbeat status for missing isolated check runs' {
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

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat check worker-2 --run-id missing-isolated --profile isolated-enterprise --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $payload.health | Should -Be 'offline'
        $payload.reason | Should -Be 'heartbeat_missing'
        $payload.run_id | Should -Be 'missing-isolated'
        $payload.execution_profile | Should -Be 'isolated-enterprise'
    }

It 'rejects unsupported latest heartbeat profile before scanning local artifacts' {
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
        $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:00Z'
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat mark worker-2 --run-id latest-local --state running --json --project-dir $script:workersTempRoot | Out-Null

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat check worker-2 --profile typo-profile --json --project-dir $script:workersTempRoot 2>&1

        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'unsupported execution profile for heartbeat: typo-profile'
        ($output | Out-String) | Should -Not -Match 'latest-local'
    }

It 'rejects heartbeat mark profile mismatches for isolated slots' {
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

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat mark worker-2 --run-id cross-profile --profile local-windows --state running --json --project-dir $script:workersTempRoot 2>&1

        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match "worker slot worker-2 uses execution profile 'isolated-enterprise', not local-windows"
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-2\cross-profile\heartbeat.json') | Should -Be $false
    }

It 'honors latest heartbeat check thresholds and profile filters' {
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
        $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:00Z'
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat mark worker-2 --run-id latest-local --state running --json --project-dir $script:workersTempRoot | Out-Null

        $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:01:30Z'
        $staleOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat check worker-2 --stalled-after 10 --offline-after 20 --json --project-dir $script:workersTempRoot
        $stalePayload = ($staleOutput | Select-Object -Last 1) | ConvertFrom-Json

        $stalePayload.run_id | Should -Be 'latest-local'
        $stalePayload.health | Should -Be 'offline'
        $stalePayload.reason | Should -Be 'heartbeat_expired'

        $profileOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat check worker-2 --profile isolated-enterprise --json --project-dir $script:workersTempRoot
        $profilePayload = ($profileOutput | Select-Object -Last 1) | ConvertFrom-Json

        $profilePayload.health | Should -Be 'offline'
        $profilePayload.reason | Should -Be 'heartbeat_missing'
        $profilePayload.execution_profile | Should -Be 'isolated-enterprise'
    }

It 'reports the default six worker slots with aliases and launch metadata' {
@'
agent: codex
model: gpt-5.4
worker-backend: antigravity
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        @($payload.workers).Count | Should -Be 6
        $payload.workers[0].slot | Should -Be 'w1'
        $payload.workers[0].slot_id | Should -Be 'worker-1'
        $payload.workers[0].backend | Should -Be 'codex'
        $payload.workers[0].role | Should -Be 'reviewer'
        $payload.workers[0].state | Should -Be 'not_launched'
        $payload.workers[1].slot | Should -Be 'w2'
        $payload.workers[1].slot_id | Should -Be 'worker-2'
        $payload.workers[1].backend | Should -Be 'antigravity'
        $payload.workers[1].state | Should -Be 'not_launched'
        $payload.workers[1].current_launch.packet_type | Should -Be 'worker_launch_approval'
        $payload.workers[1].current_launch.source | Should -Be 'user_approved_worker_config'
        @($payload.workers[1].approval_differences).Count | Should -Be 0
        $payload.workers[0].launch_command_status | Should -Be 'available'
        $payload.workers[0].launch_command_error | Should -Be ''
        $payload.workers[0].launch_command | Should -Match '^codex '
        $payload.workers[0].launch_command | Should -Match '--sandbox danger-full-access'
    }

It 'reports api_llm worker status with provider-hosted model metadata' {
        Write-WorkersApiLlmProjectConfig

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $row = @($payload.workers)[0]

        $row.slot_id | Should -Be 'worker-1'
        $row.backend | Should -Be 'api_llm'
        $row.provider | Should -Be 'openrouter'
        $row.model | Should -Be 'z-ai/glm-5.2'
        $row.model_source | Should -Be 'operator-override'
        $row.auth_mode | Should -Be 'api-key-env'
        $row.credential_requirements | Should -Be 'runtime-owned-api-key'
        $row.execution_backend | Should -Be 'openai-compatible-chat-completions'
        $row.api_base_url | Should -Be 'https://openrouter.ai/api/v1'
        $row.api_key_env | Should -Be 'OPENROUTER_API_KEY'
        $row.capability_adapter | Should -Be 'openai-compatible'
        $row.launch_command_status | Should -Be 'available'
        $row.launch_command_error | Should -Be ''
        $row.launch_command | Should -Match 'api-llm-pane-worker\.ps1'
        $row.launch_command | Should -Match "-SlotId 'worker-1'"
        $row.launch_command | Should -Match "-Provider 'openrouter'"
        $row.launch_command | Should -Match "-Model 'z-ai/glm-5\.2'"
    }

It 'adds api_llm diagnostics without a secondary backend fallback' {
        Write-WorkersApiLlmProjectConfig

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers doctor --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $apiBackend = @($payload.checks | Where-Object { $_.label -eq 'api_llm backend' })[0]
        $apiRunner = @($payload.checks | Where-Object { $_.label -eq 'api_llm runner' })[0]
        $apiKeyEnv = @($payload.checks | Where-Object { $_.label -eq 'api_llm API key env' })[0]

        $apiBackend.status | Should -Be 'pass'
        $apiBackend.detail | Should -Be '1 api_llm worker slots configured'
        $apiRunner.status | Should -Be 'pass'
        $apiRunner.detail | Should -Match 'OpenAI-compatible chat completions execution is available'
        $apiKeyEnv.status | Should -Be 'warn'
        $apiKeyEnv.detail | Should -Match 'OPENROUTER_API_KEY'
    }

It 'reports antigravity worker status with CLI runner metadata' {
        Write-WorkersAntigravityProjectConfig

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $row = @($payload.workers)[0]

        $row.slot_id | Should -Be 'worker-1'
        $row.backend | Should -Be 'antigravity'
        $row.provider | Should -Be 'antigravity'
        $row.model | Should -Be 'gemini-3.5-flash'
        $row.model_source | Should -Be 'operator-override'
        $row.auth_mode | Should -Be 'antigravity-official-cli'
        $row.credential_requirements | Should -Be 'local-cli-owned'
        $row.execution_backend | Should -Be 'antigravity-cli-print'
        $row.capability_adapter | Should -Be 'antigravity'
    }

It 'adds antigravity diagnostics without a secondary backend fallback' {
        Write-WorkersAntigravityProjectConfig
        New-WorkersFakeAntigravityCli | Out-Null

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers doctor --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $backend = @($payload.checks | Where-Object { $_.label -eq 'antigravity backend' })[0]
        $cli = @($payload.checks | Where-Object { $_.label -eq 'antigravity CLI' })[0]
        $printMode = @($payload.checks | Where-Object { $_.label -eq 'antigravity print mode' })[0]
        $modelFlag = @($payload.checks | Where-Object { $_.label -eq 'antigravity model flag' })[0]

        $backend.status | Should -Be 'pass'
        $backend.detail | Should -Be '1 antigravity worker slots configured'
        $cli.status | Should -Be 'pass'
        $cli.detail | Should -Be '[LOCAL_PATH_REDACTED]'
        $cli.detail | Should -Not -Match 'agy\.cmd'
        $printMode.status | Should -Be 'pass'
        $printMode.detail | Should -Match '--print'
        $modelFlag.status | Should -Be 'pass'
        $modelFlag.detail | Should -Match '--model'
    }

It 'fails api_llm diagnostics when provider metadata is inherited from the default agent' {
@'
agent: codex
model: provider-default
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: api_llm
    worker-role: impl
    model: z-ai/glm-5.2
    model-source: operator-override
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers doctor --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $apiBackend = @($payload.checks | Where-Object { $_.label -eq 'api_llm backend' })[0]

        $apiBackend.status | Should -Be 'fail'
        $apiBackend.detail | Should -Match 'missing explicit OpenAI-compatible provider or model metadata'
        $apiBackend.action | Should -Match 'Set agent and model'
    }

It 'stops one worker by slot alias and records the lifecycle command in the manifest' {
@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: local
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot '.winsmux') -Force | Out-Null
        $bootstrapRoot = Join-Path (Join-Path $script:workersTempRoot '.winsmux') 'orchestra-bootstrap'
        New-Item -ItemType Directory -Path $bootstrapRoot -Force | Out-Null
        $planPath = Join-Path $bootstrapRoot '_2.json'
        $markerPath = Join-Path $bootstrapRoot '_2-test.ready.json'
        '{}' | Set-Content -LiteralPath $planPath -Encoding UTF8
        '{}' | Set-Content -LiteralPath $markerPath -Encoding UTF8
        Save-WinsmuxManifest -ProjectDir $script:workersTempRoot -Manifest ([ordered]@{
            version = 2
            saved_at = '2026-05-13T00:00:00Z'
            session = [ordered]@{
                name = 'winsmux-orchestra'
                project_dir = $script:workersTempRoot
                git_worktree_dir = (Join-Path $script:workersTempRoot '.git')
                generation_id = 'generation-workers'
                server_session_id = '$workers'
                bootstrap_pane_id = '%1'
                expected_pane_count = 1
            }
            panes = [ordered]@{
                'worker-1' = [ordered]@{
                    pane_id = '%2'
                    slot_id = 'worker-1'
                    worker_backend = 'local'
                    role = 'Worker'
                    exec_mode = $false
                    launch_dir = $script:workersTempRoot
                    status = 'ready'
                    runtime_ready = $true
                    bootstrap_plan_path = $planPath
                    bootstrap_marker_path = $markerPath
                    task = $null
                }
            }
            tasks = [ordered]@{
                queued = @()
                in_progress = @()
                completed = @()
            }
            worktrees = [ordered]@{}
        })

        Mock Invoke-WinsmuxRaw {
            param([string[]]$Arguments)
            $global:LASTEXITCODE = 0
            return @()
        } -ParameterFilter {
            $Arguments[0] -eq 'respawn-pane'
        }

        $Rest = @('w1', '--json', '--project-dir', $script:workersTempRoot)
        $output = Invoke-WorkersStop
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $entry = @(Get-PaneControlManifestEntries -ProjectDir $script:workersTempRoot)[0]

        $payload.results[0].slot_id | Should -Be 'worker-1'
        $payload.results[0].status | Should -Be 'stopped'
        $entry.Status | Should -Be 'deferred_start'
        $entry.RuntimeReady | Should -BeFalse
        $entry.LastCommand | Should -Be 'workers.stop'
        Test-Path -LiteralPath $markerPath -PathType Leaf | Should -BeFalse
        Should -Invoke Invoke-WinsmuxRaw -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'respawn-pane' -and $Arguments -contains '%2'
        }
    }

It 'blocks start for an api_llm worker without dispatching bootstrap text' {
        Write-WorkersApiLlmProjectConfig
        Save-WinsmuxManifest -ProjectDir $script:workersTempRoot -Manifest ([ordered]@{
            version = 1
            saved_at = '2026-05-13T00:00:00Z'
            session = [ordered]@{
                name = 'winsmux-orchestra'
                project_dir = $script:workersTempRoot
                git_worktree_dir = (Join-Path $script:workersTempRoot '.git')
            }
            panes = [ordered]@{
                'worker-1' = [ordered]@{
                    pane_id = '%2'
                    slot_id = 'worker-1'
                    worker_backend = 'api_llm'
                    role = 'Worker'
                    exec_mode = $false
                    launch_dir = $script:workersTempRoot
                    status = 'api_llm_runner_unconfigured'
                    approved_launch = [ordered]@{
                        packet_type = 'worker_launch_approval'
                        source = 'user_approved_worker_config'
                        slot_id = 'worker-1'
                        worker_backend = 'api_llm'
                        worker_role = 'impl'
                        agent = 'openrouter'
                        model = 'z-ai/glm-5.2'
                        model_source = 'operator-override'
                        reasoning_effort = 'provider-default'
                        prompt_transport = 'file'
                        auth_mode = 'api-key-env'
                        credential_requirements = 'runtime-owned-api-key'
                        execution_backend = 'openai-compatible-chat-completions'
                        analysis_posture = 'hosted-api-worker'
                        auto_launch = $false
                    }
                    task = $null
                }
            }
            tasks = [ordered]@{
                queued = @()
                in_progress = @()
                completed = @()
            }
            worktrees = [ordered]@{}
        })

        Mock Send-TextToPane { throw 'bootstrap should not be dispatched' }

        $manifestPath = Join-Path $script:workersTempRoot '.winsmux\manifest.yaml'
        $manifestHashBefore = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        $Rest = @('worker-1', '--json', '--project-dir', $script:workersTempRoot)
        $output = Invoke-WorkersStart
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $entry = @(Get-PaneControlManifestEntries -ProjectDir $script:workersTempRoot)[0]

        $payload.results[0].slot_id | Should -Be 'worker-1'
        $payload.results[0].status | Should -Be 'blocked'
        $payload.results[0].reason | Should -Be 'api_llm_runner_unconfigured'
        $payload.results[0].failed_stage | Should -Be 'runner_config'
        $payload.results[0].recovery_action | Should -Be 'set-api-llm-slot-and-api-key-env'
        $entry.Status | Should -Be 'api_llm_runner_unconfigured'
        $entry.LastCommand | Should -BeNullOrEmpty
        $entry.LastFailureStage | Should -BeNullOrEmpty
        $entry.LastFailureReason | Should -BeNullOrEmpty
        $entry.RecoveryAction | Should -BeNullOrEmpty
        (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash | Should -Be $manifestHashBefore
        Should -Invoke Send-TextToPane -Times 0 -Exactly
    }

It 'blocks start for an antigravity worker without dispatching bootstrap text' {
        Write-WorkersAntigravityProjectConfig
        Save-WinsmuxManifest -ProjectDir $script:workersTempRoot -Manifest ([ordered]@{
            version = 1
            saved_at = '2026-06-19T00:00:00Z'
            session = [ordered]@{
                name = 'winsmux-orchestra'
                project_dir = $script:workersTempRoot
                git_worktree_dir = (Join-Path $script:workersTempRoot '.git')
            }
            panes = [ordered]@{
                'worker-1' = [ordered]@{
                    pane_id = '%2'
                    slot_id = 'worker-1'
                    worker_backend = 'antigravity'
                    role = 'Worker'
                    exec_mode = $false
                    launch_dir = $script:workersTempRoot
                    status = 'antigravity_runner_unconfigured'
                    approved_launch = [ordered]@{
                        packet_type = 'worker_launch_approval'
                        source = 'user_approved_worker_config'
                        slot_id = 'worker-1'
                        worker_backend = 'antigravity'
                        worker_role = 'impl'
                        agent = 'antigravity'
                        model = 'gemini-3.5-flash'
                        model_source = 'operator-override'
                        reasoning_effort = 'provider-default'
                        prompt_transport = 'file'
                        auth_mode = 'antigravity-official-cli'
                        credential_requirements = 'local-cli-owned'
                        execution_backend = 'antigravity-cli-print'
                        analysis_posture = 'read-write-worker'
                        auto_launch = $false
                    }
                    task = $null
                }
            }
            tasks = [ordered]@{
                queued = @()
                in_progress = @()
                completed = @()
            }
            worktrees = [ordered]@{}
        })

        Mock Send-TextToPane { throw 'bootstrap should not be dispatched' }

        $manifestPath = Join-Path $script:workersTempRoot '.winsmux\manifest.yaml'
        $manifestHashBefore = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        $Rest = @('worker-1', '--json', '--project-dir', $script:workersTempRoot)
        $output = Invoke-WorkersStart
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $entry = @(Get-PaneControlManifestEntries -ProjectDir $script:workersTempRoot)[0]

        $payload.results[0].slot_id | Should -Be 'worker-1'
        $payload.results[0].status | Should -Be 'blocked'
        $payload.results[0].reason | Should -Be 'antigravity_runner_unconfigured'
        $payload.results[0].failed_stage | Should -Be 'runner_config'
        $payload.results[0].recovery_action | Should -Be 'install-or-configure-antigravity-cli'
        $entry.Status | Should -Be 'antigravity_runner_unconfigured'
        $entry.LastCommand | Should -BeNullOrEmpty
        $entry.LastFailureStage | Should -BeNullOrEmpty
        $entry.LastFailureReason | Should -BeNullOrEmpty
        $entry.RecoveryAction | Should -BeNullOrEmpty
        (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash | Should -Be $manifestHashBefore
        Should -Invoke Send-TextToPane -Times 0 -Exactly
    }

It 'blocks start when the manifest approval no longer matches the worker config' {
@'
agent: codex
model: gpt-5.5
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: local
    worker-role: worker
    agent: codex
    model: gpt-5.5
    model-source: operator-override
    reasoning-effort: high
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot '.winsmux') -Force | Out-Null
        $planPath = Join-Path $script:workersTempRoot 'worker-1.json'
        Save-WinsmuxManifest -ProjectDir $script:workersTempRoot -Manifest ([ordered]@{
            version = 2
            saved_at = '2026-05-13T00:00:00Z'
            session = [ordered]@{
                name = 'winsmux-orchestra'
                project_dir = $script:workersTempRoot
                git_worktree_dir = (Join-Path $script:workersTempRoot '.git')
                generation_id = 'generation-workers'
                server_session_id = '$workers'
                bootstrap_pane_id = '%1'
                expected_pane_count = 1
            }
            panes = [ordered]@{
                'worker-1' = [ordered]@{
                    pane_id = '%2'
                    slot_id = 'worker-1'
                    worker_backend = 'local'
                    role = 'Worker'
                    exec_mode = $false
                    launch_dir = $script:workersTempRoot
                    status = 'deferred_start'
                    bootstrap_plan_path = $planPath
                    approved_launch = [ordered]@{
                        packet_type = 'worker_launch_approval'
                        source = 'user_approved_worker_config'
                        slot_id = 'worker-1'
                        worker_backend = 'local'
                        worker_role = 'worker'
                        agent = 'codex'
                        model = 'gpt-5.4'
                        model_source = 'operator-override'
                        reasoning_effort = 'high'
                        prompt_transport = 'argv'
                        auth_mode = 'local-cli'
                        credential_requirements = 'local-cli-owned'
                        execution_backend = 'local'
                        analysis_posture = 'read-write-worker'
                        auto_launch = $false
                    }
                    task = $null
                }
            }
            tasks = [ordered]@{
                queued = @()
                in_progress = @()
                completed = @()
            }
            worktrees = [ordered]@{}
        })
        ([ordered]@{
            agent = 'codex'
            ready_marker_path = (Join-Path $script:workersTempRoot 'worker-1.ready.json')
            approved_launch = [ordered]@{
                packet_type = 'worker_launch_approval'
                source = 'user_approved_worker_config'
                slot_id = 'worker-1'
                worker_backend = 'local'
                worker_role = 'worker'
                agent = 'codex'
                model = 'gpt-5.5'
                model_source = 'operator-override'
                reasoning_effort = 'high'
                prompt_transport = 'argv'
                auth_mode = 'local-cli'
                credential_requirements = 'local-cli-owned'
                execution_backend = 'local'
                analysis_posture = 'read-write-worker'
                auto_launch = $false
            }
        } | ConvertTo-Json -Depth 8) | Set-Content -Path $planPath -Encoding UTF8

        Mock Send-TextToPane { throw 'bootstrap should not be dispatched' }

        $Rest = @('worker-1', '--json', '--project-dir', $script:workersTempRoot)
        $output = Invoke-WorkersStart
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $payload.results[0].slot_id | Should -Be 'worker-1'
        $payload.results[0].status | Should -Be 'blocked'
        $payload.results[0].reason | Should -Match 'worker launch approval mismatch'
        @($payload.results[0].approval_differences | Where-Object { $_.field -eq 'model' }).Count | Should -Be 1
        Should -Invoke Send-TextToPane -Times 0 -Exactly
    }

It 'clears stale heartbeat binding when a deferred worker starts' {
@'
agent: codex
model: gpt-5.5
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: local
    worker-role: worker
    agent: codex
    model: gpt-5.5
    model-source: operator-override
    reasoning-effort: high
    execution-profile: local-windows
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot '.winsmux') -Force | Out-Null
        $planPath = Join-Path $script:workersTempRoot 'worker-1.json'
        Save-WinsmuxManifest -ProjectDir $script:workersTempRoot -Manifest ([ordered]@{
            version = 2
            saved_at = '2026-05-13T00:00:00Z'
            session = [ordered]@{
                name = 'winsmux-orchestra'
                project_dir = $script:workersTempRoot
                git_worktree_dir = (Join-Path $script:workersTempRoot '.git')
                generation_id = 'generation-workers'
                server_session_id = '$workers'
                bootstrap_pane_id = '%1'
                expected_pane_count = 1
            }
            panes = [ordered]@{
                'worker-1' = [ordered]@{
                    pane_id = '%2'
                    slot_id = 'worker-1'
                    worker_backend = 'local'
                    role = 'Worker'
                    exec_mode = $false
                    launch_dir = $script:workersTempRoot
                    status = 'deferred_start'
                    bootstrap_plan_path = $planPath
                    last_heartbeat_run_id = 'old-run'
                    last_heartbeat_profile = 'local-windows'
                    task = $null
                }
            }
            tasks = [ordered]@{
                queued = @()
                in_progress = @()
                completed = @()
            }
            worktrees = [ordered]@{}
        })
        ([ordered]@{
            agent = 'codex'
            ready_marker_path = (Join-Path $script:workersTempRoot 'worker-1.ready.json')
        } | ConvertTo-Json -Depth 8) | Set-Content -Path $planPath -Encoding UTF8
        $runDir = Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-1\old-run'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        [ordered]@{
            contract_version      = 1
            command               = 'workers.heartbeat'
            status                = 'marked'
            slot                  = 'w1'
            slot_id               = 'worker-1'
            run_id                = 'old-run'
            execution_profile     = 'local-windows'
            state                 = 'blocked'
            message               = 'stale approval wait'
            heartbeat_at          = '2026-05-13T00:00:00Z'
            stalled_after_seconds = 60
            offline_after_seconds = 600
            artifact              = '.winsmux/worker-runs/worker-1/old-run/heartbeat.json'
        } | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $runDir 'heartbeat.json') -Encoding UTF8

        Mock Wait-PaneShellReady { }
        Mock Invoke-Send { return $true }
        Mock Wait-DeferredPaneReady { }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            [pscustomobject]@{
                Managed      = $true
                ProjectDir   = $script:workersTempRoot
                GenerationId = 'generation-workers-stale-heartbeat'
                Validation   = [pscustomobject]@{
                    valid       = $true
                    reason_code = 'dispatch_verified'
                    diagnostic  = 'synthetic deferred worker runtime verified'
                }
            }
        }

        $Rest = @('worker-1', '--json', '--project-dir', $script:workersTempRoot)
        $output = Invoke-WorkersStart
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $entry = @(Get-PaneControlManifestEntries -ProjectDir $script:workersTempRoot)[0]

        $payload.results[0].slot_id | Should -Be 'worker-1'
        $payload.results[0].status | Should -Be 'started' -Because ([string]$payload.results[0].reason)
        $entry.Status | Should -Be 'ready'
        [string](Get-SendConfigValue -InputObject $entry -Name 'LastHeartbeatRunId' -Default '') | Should -Be ''
        [string](Get-SendConfigValue -InputObject $entry -Name 'LastHeartbeatProfile' -Default '') | Should -Be ''
        Should -Invoke Invoke-Send -Times 1 -Exactly -ParameterFilter {
            $SendTarget -eq '%2' -and
            @($SendArguments).Count -eq 1 -and
            $SendArguments[0] -match 'orchestra-pane-bootstrap\.ps1' -and
            $SendArguments[0] -match '-PlanFile' -and
            $DeliveryClass -eq 'launch' -and
            $SkipDeferredPaneStart
        }

        $Rest = @('worker-1', '--json', '--project-dir', $script:workersTempRoot)
        $statusOutput = Invoke-WorkersStatus
        $statusPayload = ($statusOutput | Select-Object -Last 1) | ConvertFrom-Json
        $row = @($statusPayload.workers)[0]

        $row.state | Should -Not -Be 'blocked'
        $row.heartbeat_health | Should -Be ''
        $row.heartbeat | Should -BeNullOrEmpty
    }

It 'keeps a ready deferred worker idempotent when its approved launch was manual' {
@'
agent: codex
model: gpt-5.5
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: local
    worker-role: worker
    agent: codex
    model: gpt-5.5
    model-source: operator-override
    reasoning-effort: high
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot '.winsmux') -Force | Out-Null
        Save-WinsmuxManifest -ProjectDir $script:workersTempRoot -Manifest ([ordered]@{
            version = 2
            saved_at = '2026-05-13T00:00:00Z'
            session = [ordered]@{
                name = 'winsmux-orchestra'
                project_dir = $script:workersTempRoot
                git_worktree_dir = (Join-Path $script:workersTempRoot '.git')
                generation_id = 'generation-workers'
                server_session_id = '$workers'
                bootstrap_pane_id = '%1'
                expected_pane_count = 1
            }
            panes = [ordered]@{
                'worker-1' = [ordered]@{
                    pane_id = '%2'
                    slot_id = 'worker-1'
                    worker_backend = 'local'
                    role = 'Worker'
                    exec_mode = $false
                    launch_dir = $script:workersTempRoot
                    status = 'ready'
                    bootstrap_plan_path = (Join-Path $script:workersTempRoot 'worker-1.json')
                    approved_launch = [ordered]@{
                        packet_type = 'worker_launch_approval'
                        source = 'user_approved_worker_config'
                        slot_id = 'worker-1'
                        worker_backend = 'local'
                        worker_role = 'worker'
                        agent = 'codex'
                        model = 'gpt-5.5'
                        model_source = 'operator-override'
                        reasoning_effort = 'high'
                        prompt_transport = 'argv'
                        auth_mode = ''
                        credential_requirements = ''
                        execution_backend = ''
                        analysis_posture = ''
                        auto_launch = $false
                    }
                    task = $null
                }
            }
            tasks = [ordered]@{
                queued = @()
                in_progress = @()
                completed = @()
            }
            worktrees = [ordered]@{}
        })

        Mock Send-TextToPane { throw 'bootstrap should not be dispatched' }

        $Rest = @('worker-1', '--json', '--project-dir', $script:workersTempRoot)
        $output = Invoke-WorkersStart
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $payload.results[0].slot_id | Should -Be 'worker-1'
        $payload.results[0].status | Should -Be 'already_running'
        [bool]$payload.results[0].current_launch.auto_launch | Should -Be $false
        @($payload.results[0].approval_differences).Count | Should -Be 0
        Should -Invoke Send-TextToPane -Times 0 -Exactly
    }

It 'prints worker doctor checks with actionable uv diagnostics' {
@'
agent: codex
model: gpt-5.4
worker-backend: local
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers doctor --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $labels = @($payload.checks | ForEach-Object { $_.label })

        $labels | Should -Contain 'config'
        $labels | Should -Contain 'uv'
        $uvCheck = @($payload.checks | Where-Object { $_.label -eq 'uv' })[0]
        if ($uvCheck.status -eq 'fail') {
            $uvCheck.action | Should -Match 'Install uv'
        }
    }
}
