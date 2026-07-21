$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'TASK781 acknowledgement pipe integration' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\pane-control.ps1')
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\submission-contract.ps1')
        $script:task781PipeContractPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\submission-contract.ps1'
    }

    BeforeEach {
        $script:task781PipeRoot = Join-Path ([IO.Path]::GetTempPath()) ('winsmux-task781-pipe-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:task781PipeRoot -Force | Out-Null
        $script:task781PipeClientScript = Join-Path $script:task781PipeRoot 'ack-client.ps1'
        $script:task781PipeClient = $null
        $script:task781PipeCallerChecks = 0
        $script:task781PipeObservedPids = [Collections.Generic.List[int]]::new()
        $script:task781PipePreviousTimeout = $env:WINSMUX_SUBMISSION_ACK_TIMEOUT_MS
        $env:WINSMUX_SUBMISSION_ACK_TIMEOUT_MS = '10000'
        [IO.File]::WriteAllText($script:task781PipeClientScript, @'
param(
    [string]$ContractPath,
    [string]$PipeName,
    [string]$Challenge,
    [string]$SubmissionId,
    [string]$RequestDigest,
    [switch]$DisconnectBeforeFinal
)
$ErrorActionPreference = 'Stop'
. $ContractPath
$record = New-WinsmuxSubmissionRunRecord -SubmissionId $SubmissionId -RunId $SubmissionId -Kind task `
    -TaskTitle 'Actual pipe client' -SlotId worker-1 -Backend local -Status started -RequestConsumed -RequestDigest $RequestDigest
$receipt = New-WinsmuxSubmissionReceipt -Kind task -Status accepted -Backend local -SubmissionId $SubmissionId `
    -Target ([ordered]@{ label = 'worker-1'; pane_id = '%2'; role = 'Worker' }) -Acknowledgement $record
if ($DisconnectBeforeFinal) {
    $client = [System.IO.Pipes.NamedPipeClientStream]::new(
        '.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous
    )
    try {
        $client.Connect(10000)
        $candidate = New-WinsmuxSubmissionAcknowledgementEnvelope -Phase candidate -Challenge $Challenge -Receipt $receipt
        Write-WinsmuxSubmissionPipeFrame -Stream $client -Json ($candidate | ConvertTo-Json -Depth 14 -Compress)
        $control = Read-WinsmuxSubmissionPipeJson -Stream $client -TimeoutMilliseconds 10000
        if (-not (Test-WinsmuxSubmissionAcknowledgementControl -Control $control -ExpectedStatus commit)) { exit 2 }
        $committed = New-WinsmuxSubmissionAcknowledgementEnvelope -Phase committed -Challenge $Challenge -Receipt $receipt
        Write-WinsmuxSubmissionPipeFrame -Stream $client -Json ($committed | ConvertTo-Json -Depth 14 -Compress)
    } finally {
        $client.Dispose()
    }
    Start-Sleep -Milliseconds 2000
    exit 0
}
$result = Invoke-WinsmuxSubmissionAcknowledgementClientHandshake `
    -PipeName $PipeName -Challenge $Challenge -Receipt $receipt
if ([string]$result.status -eq 'accepted') { exit 0 }
exit 1
'@, [Text.UTF8Encoding]::new($false))
    }

    AfterEach {
        if ($null -ne $script:task781PipeClient -and -not $script:task781PipeClient.HasExited) {
            Stop-Process -Id $script:task781PipeClient.Id -Force -ErrorAction SilentlyContinue
        }
        if ($null -eq $script:task781PipePreviousTimeout) {
            Remove-Item Env:WINSMUX_SUBMISSION_ACK_TIMEOUT_MS -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_SUBMISSION_ACK_TIMEOUT_MS = $script:task781PipePreviousTimeout
        }
        if ($script:task781PipeRoot -and (Test-Path -LiteralPath $script:task781PipeRoot)) {
            Remove-Item -LiteralPath $script:task781PipeRoot -Recurse -Force
        }
    }

    It 'TASK781 uses an actual <ClientHost> pipe client for <Mode>' -ForEach @(
        @{ ClientHost = 'pwsh'; Mode = 'success' }
        @{ ClientHost = 'powershell.exe'; Mode = 'success' }
        @{ ClientHost = 'pwsh'; Mode = 'post_commit_reject' }
        @{ ClientHost = 'powershell.exe'; Mode = 'post_commit_reject' }
        @{ ClientHost = 'pwsh'; Mode = 'create_new_conflict' }
        @{ ClientHost = 'pwsh'; Mode = 'client_receive_failure' }
    ) {
        $script:task781PipeMode = $Mode
        $clientHolder = [PSCustomObject]@{ Process = $null }
        $clientScriptPath = $script:task781PipeClientScript
        $contractPath = $script:task781PipeContractPath
        $clientHost = $ClientHost
        $submissionId = 'submission-task781-actual-' + ($Mode -replace '_', '-') + '-' + ($ClientHost -replace '[^A-Za-z0-9]', '-')
        $request = 'Actual two-phase pipe request for ' + $Mode + ' on ' + $ClientHost
        $requestDigest = Get-WinsmuxSubmissionRequestDigest -Request $request
        $entry = [PSCustomObject]@{
            Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; Role = 'Worker'; WorkerRole = 'worker'
            WorkerBackend = 'local'; Title = 'W1 Local Worker'; Status = 'ready'
        }
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation, $CallerIdentity, $ProcessResolver)
            $context = [PSCustomObject]@{
                generation_id = 'generation-actual'; server_session_id = '$9'; slot_id = 'worker-1'
                pane_id = '%2'; backend = 'local'
            }
            if ($Operation -eq 'caller_ack') {
                $script:task781PipeCallerChecks++
                $script:task781PipeObservedPids.Add([int]$CallerIdentity.process_id) | Out-Null
                if ($script:task781PipeMode -eq 'create_new_conflict' -and $script:task781PipeCallerChecks -eq 1) {
                    $racePath = Get-WinsmuxSubmissionRunPath -ProjectDir $script:task781PipeRoot -SlotId worker-1 -RunId $submissionId
                    New-Item -ItemType Directory -Path (Split-Path -Parent $racePath) -Force | Out-Null
                    [IO.File]::WriteAllText($racePath, 'race-winner', [Text.UTF8Encoding]::new($false))
                }
                if ($script:task781PipeMode -eq 'post_commit_reject' -and $script:task781PipeCallerChecks -gt 1) {
                    return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'invalid_supervisor_identity' -Diagnostic 'synthetic post-commit expiry'
                }
            }
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' -Diagnostic 'verified' -Context $context
        }
        $sendAction = {
            param([string]$PaneId, [string]$Text)
            if ($Text -notmatch '--ack-pipe (?<pipe>winsmux-submission-ack-[0-9a-f]{32}) --challenge (?<challenge>[0-9a-f]{64})') {
                throw 'actual acknowledgement command is missing pipe identity'
            }
            $arguments = @(
                '-NoProfile', '-File', $clientScriptPath,
                '-ContractPath', $contractPath,
                '-PipeName', $Matches.pipe,
                '-Challenge', $Matches.challenge,
                '-SubmissionId', $submissionId,
                '-RequestDigest', $requestDigest
            )
            if ($Mode -eq 'client_receive_failure') { $arguments += '-DisconnectBeforeFinal' }
            $clientHolder.Process = Start-Process -FilePath $clientHost `
                -ArgumentList $arguments -PassThru -WindowStyle Hidden
        }.GetNewClosure()

        $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781PipeRoot -ManifestEntry $entry `
            -Kind task -Content $request -SubmissionId $submissionId -SendAction $sendAction
        $script:task781PipeClient = $clientHolder.Process
        $script:task781PipeClient | Should -Not -BeNullOrEmpty -Because (
            'the adapter receipt was {0}/{1}' -f [string]$receipt.status, [string]$receipt.reason_code)
        $script:task781PipeClient.WaitForExit(15000) | Should -BeTrue
        $runPath = Get-WinsmuxSubmissionRunPath -ProjectDir $script:task781PipeRoot -SlotId worker-1 -RunId $submissionId
        $packetPath = Join-Path $script:task781PipeRoot ".winsmux\submissions\$submissionId.json"

        @($script:task781PipeObservedPids | Select-Object -Unique) | Should -Be @($script:task781PipeClient.Id)
        if ($Mode -in @('success', 'client_receive_failure')) {
            $receipt.status | Should -Be 'accepted' -Because (
                'the acknowledgement reason was {0}: {1}' -f [string]$receipt.reason_code, [string]$receipt.diagnostic)
            $script:task781PipeClient.ExitCode | Should -Be 0
            Test-Path -LiteralPath $runPath -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath $packetPath -PathType Leaf | Should -BeTrue
            $script:task781PipeCallerChecks | Should -Be 2
        } elseif ($Mode -eq 'post_commit_reject') {
            $receipt.status | Should -Be 'unavailable'
            $receipt.reason_code | Should -Be 'invalid_supervisor_identity'
            $script:task781PipeClient.ExitCode | Should -Be 1
            Test-Path -LiteralPath $runPath -PathType Leaf | Should -BeFalse
            Test-Path -LiteralPath $packetPath -PathType Leaf | Should -BeTrue
            $committedPacketText = Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8
            $duplicate = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781PipeRoot -ManifestEntry $entry `
                -Kind task -Content 'replacement must not overwrite committed packet' -SubmissionId $submissionId `
                -SendAction { throw 'duplicate must stop before delivery' }
            $duplicate.status | Should -Be 'rejected'
            $duplicate.reason_code | Should -Be 'run_record_already_exists'
            (Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8) | Should -BeExactly $committedPacketText
            $script:task781PipeCallerChecks | Should -Be 2
        } else {
            $receipt.status | Should -Be 'rejected'
            $receipt.reason_code | Should -Be 'run_record_already_exists'
            $script:task781PipeClient.ExitCode | Should -Be 1
            (Get-Content -LiteralPath $runPath -Raw -Encoding UTF8) | Should -BeExactly 'race-winner'
            Test-Path -LiteralPath $packetPath -PathType Leaf | Should -BeTrue
            $committedPacketText = Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8
            $duplicate = Invoke-WinsmuxSubmissionAdapter -ProjectDir $script:task781PipeRoot -ManifestEntry $entry `
                -Kind task -Content 'replacement must not overwrite committed packet' -SubmissionId $submissionId `
                -SendAction { throw 'duplicate must stop before delivery' }
            $duplicate.status | Should -Be 'rejected'
            $duplicate.reason_code | Should -Be 'run_record_already_exists'
            (Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8) | Should -BeExactly $committedPacketText
            $script:task781PipeCallerChecks | Should -Be 2
        }
        @(Get-ChildItem -LiteralPath (Join-Path $script:task781PipeRoot '.winsmux') -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.(tmp|partial)$' }).Count | Should -Be 0
    }
}

Describe 'TASK781 C18 startup token diagnostic boundary' {
    BeforeAll {
        $script:c18RepoRoot = Split-Path -Parent $script:BridgeTestsRoot
        $script:c18OrchestraStartPath = Join-Path $script:c18RepoRoot 'winsmux-core\scripts\orchestra-start.ps1'
        . $script:c18OrchestraStartPath

        function New-Task781C18BootstrapPlan {
            param(
                [Parameter(Mandatory = $true)][string]$ProjectDir,
                [Parameter(Mandatory = $true)][string]$StartupToken
            )

            New-OrchestraPaneBootstrapPlan `
                -ProjectDir $ProjectDir `
                -PaneId '%2' `
                -Label 'worker-1' `
                -SlotId 'worker-1' `
                -Role 'Worker' `
                -WorkerBackend 'local' `
                -WorkerRole 'worker' `
                -PaneTitle 'worker-1' `
                -GenerationId 'generation-c18-safe' `
                -ServerSessionId '$18' `
                -Agent 'codex' `
                -Model 'gpt-5.4' `
                -StartupToken $StartupToken `
                -LaunchDir $ProjectDir `
                -CleanPtyEnv ([pscustomobject]@{ Environment = [ordered]@{} }) `
                -LaunchCommand 'codex --help'
        }
    }

    BeforeEach {
        $script:c18StartupToken = 'C18-STARTUP-TOKEN-SENTINEL'
        $script:c18TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-c18-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:c18TempRoot -Force | Out-Null
    }

    AfterEach {
        if ($script:c18TempRoot -and (Test-Path -LiteralPath $script:c18TempRoot)) {
            Remove-Item -LiteralPath $script:c18TempRoot -Recurse -Force
        }
    }

    It 'TASK781 C18 keeps the generated bootstrap marker path on the safe generation identity' {
        $planPath = New-Task781C18BootstrapPlan -ProjectDir $script:c18TempRoot -StartupToken $script:c18StartupToken
        $planText = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8
        $plan = $planText | ConvertFrom-Json

        [System.IO.Path]::GetFileName([string]$plan.ready_marker_path) | Should -Be '2-generation-c18-safe.ready.json'
    }

    It 'TASK781 C18 keeps the runtime registry JSON free of the startup token' {
        $planPath = New-Task781C18BootstrapPlan -ProjectDir $script:c18TempRoot -StartupToken $script:c18StartupToken
        $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $registry = New-WinsmuxRuntimeRegistryDocument `
            -SessionName 'winsmux-c18' `
            -ServerSessionId '$18' `
            -GenerationId 'generation-c18-safe' `
            -SupervisorPid 1818 `
            -SupervisorProcessStartedAt '2026-07-15T00:00:00.0000000Z' `
            -ExpectedPaneCount 1 `
            -Panes @([pscustomobject][ordered]@{
                slot_id = 'worker-1'; pane_id = '%2'; backend = 'local'; role = 'worker'; title = 'worker-1'
                state = 'bootstrap_pending'; bootstrap_pid = 1819; bootstrap_process_started_at = '2026-07-15T00:00:01.0000000Z'
                marker_path = [string]$plan.ready_marker_path
            })

        ($registry | ConvertTo-Json -Depth 20) | Should -Not -Match ([regex]::Escape($script:c18StartupToken))
    }

    It 'TASK781 C18 keeps smoke doctor and harness diagnostic serialization token free' {
        $diagnosticSurfaces = [ordered]@{
            smoke = [ordered]@{
                runtime_valid = $true
                runtime_identity = [ordered]@{ valid = $true; expected = 1; verified = 1; entries = @() }
            }
            doctor = [ordered]@{ status = 'pass'; label = 'Orchestra process contract'; detail = 'runtime identity registry verified' }
            harness = [ordered]@{ passed = $true; message = 'orchestra smoke contract verified' }
        }

        ($diagnosticSurfaces | ConvertTo-Json -Depth 12) | Should -Not -Match ([regex]::Escape($script:c18StartupToken))
        foreach ($relativePath in @(
            'winsmux-core\scripts\orchestra-smoke.ps1',
            'winsmux-core\scripts\doctor.ps1',
            'winsmux-core\scripts\harness-check.ps1'
        )) {
            (Get-Content -LiteralPath (Join-Path $script:c18RepoRoot $relativePath) -Raw -Encoding UTF8) | Should -Not -Match '(?i)startup_token'
        }
    }

    It 'TASK781 C18 keeps startup log and journal Data free of the startup token' {
        $source = Get-Content -LiteralPath $script:c18OrchestraStartPath -Raw -Encoding UTF8
        $logCall = [regex]::Match(
            $source,
            "(?m)^\s*Write-WinsmuxLog -Level INFO -Event 'preflight\.startup_lock\.acquired'.*$"
        )

        $logCall.Success | Should -BeTrue
        $logCall.Value | Should -Not -Match 'startup_token'
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

It 'uses the worker input byte limit contract' {
        $previousInputMaxBytes = $env:WINSMUX_WORKER_INPUT_MAX_BYTES
        try {
            $env:WINSMUX_WORKER_INPUT_MAX_BYTES = '4096'
            Get-WorkersInputMaxBytes | Should -Be 4096

            $env:WINSMUX_WORKER_INPUT_MAX_BYTES = 'invalid'
            Get-WorkersInputMaxBytes | Should -Be 104857600
        } finally {
            $env:WINSMUX_WORKER_INPUT_MAX_BYTES = $previousInputMaxBytes
        }
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

It 'records blocked api_llm exec artifacts when the API key env is missing' {
        Write-WorkersApiLlmProjectConfig
        'Summarize the repository status.' | Set-Content -Path (Join-Path $script:workersTempRoot 'prompt.md') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers exec w1 --script prompt.md --run-id api-run --json --project-dir $script:workersTempRoot 2>&1
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $LASTEXITCODE | Should -Be 1
        $payload.status | Should -Be 'blocked'
        $payload.reason | Should -Be 'api_llm_api_key_env_missing'
        $payload.backend | Should -Be 'api_llm'
        $payload.slot_id | Should -Be 'worker-1'
        $payload.input | Should -Be 'prompt.md'
        $payload.api_llm.provider | Should -Be 'openrouter'
        $payload.api_llm.model | Should -Be 'z-ai/glm-5.2'
        $payload.api_llm.execution_backend | Should -Be 'openai-compatible-chat-completions'
        $payload.api_llm.api_key_env | Should -Be 'OPENROUTER_API_KEY'
        $payload.network | Should -Be 'not_started'
        $payload.api_key_env | Should -Be 'OPENROUTER_API_KEY'
        $payload.endpoint_host | Should -Be 'openrouter.ai'
        $payload.provider_response_id_present | Should -Be $false
        $payload.prompt_value_output | Should -Be $false
        $payload.locations.input.local_path | Should -Be ''
        ($output | Out-String) | Should -Not -Match 'Summarize the repository status'

        $logPath = Join-Path $script:workersTempRoot ($payload.stdout_log -replace '/', '\')
        $logText = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
        $logText | Should -Match 'api_llm_api_key_env_missing'
        $logText | Should -Match 'network: not_started'
        $logText | Should -Not -Match 'Summarize the repository status'

        $logsOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers logs w1 --run-id api-run --json --project-dir $script:workersTempRoot 2>&1
        $logsPayload = ($logsOutput | Select-Object -Last 1) | ConvertFrom-Json

        $LASTEXITCODE | Should -Be 1
        $logsPayload.status | Should -Be 'blocked'
        $logsPayload.reason | Should -Be 'api_llm_api_key_env_missing'
        $logsPayload.backend | Should -Be 'api_llm'
        $logsPayload.source | Should -Be 'local'
        $logsPayload.log | Should -Match 'api_llm_api_key_env_missing'
    }

It 'rejects OpenRouter endpoint overrides before network access' {
        Write-WorkersApiLlmProjectConfig
        'Summarize the repository status.' | Set-Content -Path (Join-Path $script:workersTempRoot 'prompt.md') -Encoding UTF8
        $env:OPENROUTER_API_KEY = 'test-openrouter-key'
@'
{
  "version": 1,
  "providers": {
    "openrouter": {
      "adapter": "openai-compatible",
      "display_name": "OpenRouter",
      "command": "openrouter",
      "prompt_transports": ["file"],
      "auth_modes": ["api-key-env"],
      "model_sources": ["operator-override"],
      "credential_requirements": "runtime-owned-api-key",
      "execution_backend": "openai-compatible-chat-completions",
      "api_base_url": "https://attacker.example.invalid/api",
      "api_key_env": "OPENROUTER_API_KEY",
      "analysis_posture": "hosted-api-worker"
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux\provider-capabilities.json') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers exec w1 --script prompt.md --run-id api-hostile-run --json --project-dir $script:workersTempRoot 2>&1
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $LASTEXITCODE | Should -Be 1
        $payload.status | Should -Be 'blocked'
        $payload.reason | Should -Be 'api_llm_runtime_config_invalid'
        $payload.network | Should -Be 'not_started'
        $payload.endpoint_host | Should -Be ''
        $payload.api_key_env | Should -Be ''

        $logPath = Join-Path $script:workersTempRoot ($payload.stdout_log -replace '/', '\')
        $logText = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
        $logText | Should -Match 'api_base_url overrides are not allowed'
        $logText | Should -Not -Match 'test-openrouter-key'
    }

It 'rejects unsupported and unsafe api_llm runtime metadata' {
        { Resolve-WorkersApiLlmRuntimeConfig -Metadata ([ordered]@{
                provider = 'openrouter'
                auth_mode = 'api-key-vault'
            }) } | Should -Throw '*auth_mode must be api-key-env*'

        { Resolve-WorkersApiLlmRuntimeConfig -Metadata ([ordered]@{
                provider = 'custom-remote'
                auth_mode = 'api-key-env'
                api_base_url = 'https://attacker.example.invalid/v1'
                api_key_env = 'WINSMUX_CUSTOM_REMOTE_API_KEY'
            }) } | Should -Throw '*custom OpenAI-compatible endpoints must be localhost*'

        { Resolve-WorkersApiLlmRuntimeConfig -Metadata ([ordered]@{
                provider = 'local-openai-compatible'
                auth_mode = 'api-key-env'
                api_base_url = 'http://127.0.0.1:8080/v1'
                api_key_env = 'OPENROUTER_API_KEY'
            }) } | Should -Throw '*custom provider api_key_env must be provider-scoped*'
    }

It 'marks empty provider completions as malformed' {
        Mock Invoke-RestMethod {
            return [pscustomobject]@{
                id = 'chatcmpl-empty'
                choices = @(
                    [pscustomobject]@{
                        message = [pscustomobject]@{
                            content = ''
                        }
                    }
                )
            }
        }

        $completion = Invoke-WorkersOpenAiCompatibleChatCompletion `
            -RuntimeConfig ([pscustomobject]@{ Endpoint = 'https://openrouter.ai/api/v1/chat/completions' }) `
            -Metadata ([ordered]@{ model = 'z-ai/glm-5.2' }) `
            -InputKind 'script' `
            -InputContent 'Summarize the repository status.' `
            -ApiKey 'test-openrouter-key'

        $completion.ResponseMalformed | Should -Be $true
        $completion.ProviderResponseIdPresent | Should -Be $true
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

It 'redacts provider request ids from api_llm log details' {
        $safe = ConvertTo-WorkersSafeLogText -Text 'provider failed: x-request-id=req-123 request_id: req-456 provider_response_id="chatcmpl-789"'

        $safe | Should -Not -Match 'req-123'
        $safe | Should -Not -Match 'req-456'
        $safe | Should -Not -Match 'chatcmpl-789'
        $safe | Should -Match 'x-request-id=\[REDACTED\]'
        $safe | Should -Match 'request_id: \[REDACTED\]'
        $safe | Should -Match 'provider_response_id="\[REDACTED\]'
    }

It 'runs api_llm exec through OpenAI-compatible chat completions with an env key' {
        Write-WorkersApiLlmProjectConfig
        'Summarize the repository status.' | Set-Content -Path (Join-Path $script:workersTempRoot 'prompt.md') -Encoding UTF8
        $env:OPENROUTER_API_KEY = 'test-openrouter-key'
        $script:apiLlmCapturedUri = ''
        $script:apiLlmCapturedHeaders = $null
        $script:apiLlmCapturedBody = ''

        Mock Invoke-RestMethod {
            param(
                [string]$Uri,
                [string]$Method,
                [hashtable]$Headers,
                [string]$Body,
                [string]$ContentType,
                [int]$TimeoutSec
            )

            $script:apiLlmCapturedUri = $Uri
            $script:apiLlmCapturedHeaders = $Headers
            $script:apiLlmCapturedBody = $Body
            return [pscustomobject]@{
                id = 'chatcmpl-test-response'
                choices = @(
                    [pscustomobject]@{
                        message = [pscustomobject]@{
                            content = 'External model response.'
                        }
                    }
                )
                usage = [pscustomobject]@{
                    prompt_tokens = 12
                    completion_tokens = 4
                    total_tokens = 16
                }
            }
        }

        $Rest = @('w1', '--script', 'prompt.md', '--run-id', 'api-success-run', '--json', '--project-dir', $script:workersTempRoot)
        $output = Invoke-WorkersExec
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $payload.status | Should -Be 'succeeded'
        $payload.reason | Should -Be ''
        $payload.network | Should -Be 'completed'
        $payload.response | Should -Be '.winsmux/worker-runs/worker-1/api-success-run/response.txt'
        $payload.api_key_env | Should -Be 'OPENROUTER_API_KEY'
        $payload.endpoint_host | Should -Be 'openrouter.ai'
        $payload.provider_response_id_present | Should -Be $true
        $payload.usage.total_tokens | Should -Be 16
        $payload.prompt_value_output | Should -Be $false
        $script:apiLlmCapturedUri | Should -Be 'https://openrouter.ai/api/v1/chat/completions'
        $script:apiLlmCapturedHeaders.Authorization | Should -Be 'Bearer test-openrouter-key'
        $script:apiLlmCapturedBody | Should -Match '"model"'
        $script:apiLlmCapturedBody | Should -Match 'z-ai/glm-5.2'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly

        $logPath = Join-Path $script:workersTempRoot ($payload.stdout_log -replace '/', '\')
        $logText = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
        $logText | Should -Match 'status: succeeded'
        $logText | Should -Match 'network: completed'
        $logText | Should -Not -Match 'test-openrouter-key'
        $logText | Should -Not -Match 'Summarize the repository status'

        $responsePath = Join-Path $script:workersTempRoot ($payload.response -replace '/', '\')
        (Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8) | Should -Match 'External model response'
        (Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8) | Should -Not -Match 'test-openrouter-key'
    }

It 'accepts task-json as the api_llm exec input contract' {
        Write-WorkersApiLlmProjectConfig
        '{"task_id":"api-task-json","title":"Summarize release state"}' | Set-Content -Path (Join-Path $script:workersTempRoot 'task.json') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers exec w1 --task-json task.json --run-id api-task-json-run --json --project-dir $script:workersTempRoot 2>&1
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $LASTEXITCODE | Should -Be 1
        $payload.status | Should -Be 'blocked'
        $payload.reason | Should -Be 'api_llm_api_key_env_missing'
        $payload.backend | Should -Be 'api_llm'
        $payload.input | Should -Be 'task.json'
        $payload.input_kind | Should -Be 'task_json'
        $payload.script | Should -Be ''
        $payload.task_json | Should -Be 'task.json'
        $payload.prompt_value_output | Should -Be $false
        ($output | Out-String) | Should -Not -Match 'Summarize release state'
    }

It 'rejects ambiguous api_llm script and task-json exec input' {
        Write-WorkersApiLlmProjectConfig
        'Summarize the repository status.' | Set-Content -Path (Join-Path $script:workersTempRoot 'prompt.md') -Encoding UTF8
        '{"task_id":"api-task-json","title":"Summarize release state"}' | Set-Content -Path (Join-Path $script:workersTempRoot 'task.json') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers exec w1 --script prompt.md --task-json task.json --run-id api-ambiguous-run --json --project-dir $script:workersTempRoot 2>&1

        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'api_llm workers exec accepts either --script or --task-json, not both'
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-1\api-ambiguous-run') | Should -Be $false
    }

It 'rejects secret-like api_llm prompt input before creating a run artifact' {
        Write-WorkersApiLlmProjectConfig
        '{"api_key":"abcdefghijklmnop"}' | Set-Content -Path (Join-Path $script:workersTempRoot 'prompt.json') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers exec w1 --script prompt.json --run-id secret-api-run --json --project-dir $script:workersTempRoot 2>&1

        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'API LLM safety policy'
        ($output | Out-String) | Should -Match 'secret_like_input'
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-1\secret-api-run') | Should -Be $false
    }

It 'records blocked antigravity exec artifacts when agy is missing' {
        Write-WorkersAntigravityProjectConfig
        $env:WINSMUX_ANTIGRAVITY_CLI = Join-Path $script:workersTempRoot 'missing-agy.cmd'
        'Summarize the repository status.' | Set-Content -Path (Join-Path $script:workersTempRoot 'prompt.md') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers exec w1 --script prompt.md --run-id agy-missing --json --project-dir $script:workersTempRoot 2>&1
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $LASTEXITCODE | Should -Be 1
        $payload.status | Should -Be 'blocked'
        $payload.reason | Should -Be 'antigravity_cli_missing'
        $payload.backend | Should -Be 'antigravity'
        $payload.slot_id | Should -Be 'worker-1'
        $payload.input | Should -Be 'prompt.md'
        $payload.antigravity.provider | Should -Be 'antigravity'
        $payload.antigravity.model | Should -Be 'gemini-3.5-flash'
        $payload.antigravity.execution_backend | Should -Be 'antigravity-cli-print'
        $payload.process | Should -Be 'not_started'
        $payload.prompt_value_output | Should -Be $false
        $payload.locations.input.local_path | Should -Be ''
        ($output | Out-String) | Should -Not -Match 'Summarize the repository status'

        $logPath = Join-Path $script:workersTempRoot ($payload.stdout_log -replace '/', '\')
        $logText = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
        $logText | Should -Match 'antigravity_cli_missing'
        $logText | Should -Match 'process: not_started'
        $logText | Should -Not -Match 'Summarize the repository status'

        $logsOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers logs w1 --run-id agy-missing --json --project-dir $script:workersTempRoot 2>&1
        $logsPayload = ($logsOutput | Select-Object -Last 1) | ConvertFrom-Json

        $LASTEXITCODE | Should -Be 1
        $logsPayload.status | Should -Be 'blocked'
        $logsPayload.reason | Should -Be 'antigravity_cli_missing'
        $logsPayload.backend | Should -Be 'antigravity'
        $logsPayload.source | Should -Be 'local'
        $logsPayload.log | Should -Match 'antigravity_cli_missing'
        ($logsOutput | Out-String) | Should -Not -Match 'api_llm'
    }

It 'runs antigravity exec through agy print mode with explicit model selection' {
        Write-WorkersAntigravityProjectConfig
        New-WorkersFakeAntigravityCli | Out-Null
        $env:WINSMUX_ANTIGRAVITY_PRINT_TIMEOUT = '5m'
        'Summarize the repository status.' | Set-Content -Path (Join-Path $script:workersTempRoot 'prompt.md') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers exec w1 --script prompt.md --run-id agy-success --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $payload.status | Should -Be 'succeeded'
        $payload.reason | Should -Be ''
        $payload.backend | Should -Be 'antigravity'
        $payload.process | Should -Be 'completed'
        $payload.response | Should -Be '.winsmux/worker-runs/worker-1/agy-success/response.txt'
        $payload.print_timeout | Should -Be '5m'
        $payload.prompt_value_output | Should -Be $false
        $payload.cli_arguments | Should -Contain '--print'
        $payload.cli_arguments | Should -Contain '[PROMPT_FILE_CONTENT_REDACTED]'
        $payload.cli_arguments | Should -Contain '--print-timeout'
        $payload.cli_arguments | Should -Contain '--model'
        $payload.cli_arguments | Should -Contain 'gemini-3.5-flash'
        ($payload.cli_arguments -join ' ') | Should -Not -Match 'Summarize the repository status'
        ($output | Out-String) | Should -Not -Match 'Summarize the repository status'
        $actualArguments = Get-Content -LiteralPath (Join-Path $script:workersTempRoot 'agy-args.txt') -Raw -Encoding UTF8
        $actualArguments | Should -Match 'prompt\.md'
        $actualArguments | Should -Not -Match 'Summarize the repository status'

        $logPath = Join-Path $script:workersTempRoot ($payload.stdout_log -replace '/', '\')
        $logText = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
        $logText | Should -Match 'status: succeeded'
        $logText | Should -Match 'process: completed'
        $logText | Should -Not -Match 'Summarize the repository status'

        $responsePath = Join-Path $script:workersTempRoot ($payload.response -replace '/', '\')
        (Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8) | Should -Match 'fake-antigravity response'
    }

It 'marks antigravity exec with empty stdout as failed evidence' {
        Write-WorkersAntigravityProjectConfig
        New-WorkersFakeAntigravityCli -EmptyStdout | Out-Null
        'Summarize the repository status.' | Set-Content -Path (Join-Path $script:workersTempRoot 'prompt.md') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers exec w1 --script prompt.md --run-id agy-empty-stdout --json --project-dir $script:workersTempRoot 2>&1
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $payload.status | Should -Be 'failed'
        $payload.reason | Should -Be 'antigravity_empty_stdout'
        $payload.backend | Should -Be 'antigravity'
        $payload.process | Should -Be 'completed'
        $payload.exit_code | Should -Be 0
        $payload.response | Should -Be ''
        $payload.prompt_value_output | Should -Be $false
        ($output | Out-String) | Should -Not -Match 'Summarize the repository status'

        $logPath = Join-Path $script:workersTempRoot ($payload.stdout_log -replace '/', '\')
        $logText = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
        $logText | Should -Match 'antigravity_empty_stdout'
        $logText | Should -Match 'completed without stdout'
        $logText | Should -Not -Match 'Summarize the repository status'
    }

It 'accepts task-json as the antigravity exec input contract' {
        Write-WorkersAntigravityProjectConfig
        New-WorkersFakeAntigravityCli | Out-Null
        '{"task_id":"agy-task-json","title":"Summarize release state"}' | Set-Content -Path (Join-Path $script:workersTempRoot 'task.json') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers exec w1 --task-json task.json --run-id agy-task-json-run --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $payload.status | Should -Be 'succeeded'
        $payload.backend | Should -Be 'antigravity'
        $payload.input | Should -Be 'task.json'
        $payload.input_kind | Should -Be 'task_json'
        $payload.script | Should -Be ''
        $payload.task_json | Should -Be 'task.json'
        $payload.prompt_value_output | Should -Be $false
        ($payload.cli_arguments -join ' ') | Should -Not -Match 'Summarize release state'
        ($output | Out-String) | Should -Not -Match 'api_llm'
    }

It 'rejects ambiguous antigravity script and task-json exec input' {
        Write-WorkersAntigravityProjectConfig
        'Summarize the repository status.' | Set-Content -Path (Join-Path $script:workersTempRoot 'prompt.md') -Encoding UTF8
        '{"task_id":"agy-task-json","title":"Summarize release state"}' | Set-Content -Path (Join-Path $script:workersTempRoot 'task.json') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers exec w1 --script prompt.md --task-json task.json --run-id agy-ambiguous-run --json --project-dir $script:workersTempRoot 2>&1

        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'antigravity workers exec accepts either --script or --task-json, not both'
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-1\agy-ambiguous-run') | Should -Be $false
    }

It 'rejects secret-like antigravity prompt input before creating a run artifact' {
        Write-WorkersAntigravityProjectConfig
        '{"api_key":"abcdefghijklmnop"}' | Set-Content -Path (Join-Path $script:workersTempRoot 'prompt.json') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers exec w1 --script prompt.json --run-id secret-agy-run --json --project-dir $script:workersTempRoot 2>&1

        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'Antigravity safety policy'
        ($output | Out-String) | Should -Match 'secret_like_input'
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-1\secret-agy-run') | Should -Be $false
    }

It 'classifies JSON-formatted secret task fields' {
        '{"task_id":"secret-equals","token":"abcdefghijklmnopqrstuvwxyz123456"}' | Set-Content -Path (Join-Path $script:workersTempRoot 'task-equals.json') -Encoding UTF8

        $fileFinding = Get-WorkersSafetyFinding -Values @('{"task_id":"secret-file","token":"abcdefghijklmnopqrstuvwxyz123456"}')
        $inlineFinding = Get-WorkersSafetyFinding -Values @('{"task_id":"secret-inline","api_key":"abcdefghijklmnop"}')
        $bearerFinding = Get-WorkersSafetyFinding -Values @('{"headers":{"Authorization":"Bearer abcdefghijklmnopqrstuvwxyz123456"}}')
        $equalsValues = Get-WorkersExecSafetyInputValues -ProjectDir $script:workersTempRoot -ScriptArgs @('--task-json=task-equals.json')
        $equalsFinding = Get-WorkersSafetyFinding -Values @($equalsValues)

        $fileFinding.Code | Should -Be 'secret_like_input'
        $inlineFinding.Code | Should -Be 'secret_like_input'
        $bearerFinding.Code | Should -Be 'secret_like_input'
        ($equalsValues -join ' ') | Should -Match 'secret-equals'
        $equalsFinding.Code | Should -Be 'secret_like_input'
    }

It 'keeps empty stored worker logs local' {
        Write-WorkersAntigravityProjectConfig
        $runDir = Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-1\empty-log'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $runDir 'stdout.log') -Force | Out-Null

        $logsOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers logs worker-1 --run-id empty-log --json --project-dir $script:workersTempRoot
        $logsPayload = ($logsOutput | Select-Object -Last 1) | ConvertFrom-Json

        $logsPayload.source | Should -Be 'local'
        $logsPayload.log | Should -Be ''
    }

It 'propagates stored failed run status from local logs' {
        Write-WorkersAntigravityProjectConfig
        $runDir = Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-1\failed-run'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        'failed log body' | Set-Content -Path (Join-Path $runDir 'stdout.log') -Encoding UTF8
        @{
            status    = 'failed'
            exit_code = 7
        } | ConvertTo-Json | Set-Content -Path (Join-Path $runDir 'run.json') -Encoding UTF8

        $logsOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers logs worker-1 --run-id failed-run --json --project-dir $script:workersTempRoot 2>&1
        $logsPayload = ($logsOutput | Select-Object -Last 1) | ConvertFrom-Json

        $LASTEXITCODE | Should -Be 7
        $logsPayload.source | Should -Be 'local'
        $logsPayload.status | Should -Be 'failed'
        $logsPayload.exit_code | Should -Be 7
        $logsPayload.log | Should -Match 'failed log body'
    }

It 'returns failing process exit codes when the antigravity adapter fails' {
        New-WorkersFakeAntigravityCli -ExitCode 7 | Out-Null
        Write-WorkersAntigravityProjectConfig
        'Summarize the failure evidence.' | Set-Content -Path (Join-Path $script:workersTempRoot 'prompt.md') -Encoding UTF8

        $execOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers exec w1 --script prompt.md --run-id exec-failed --json --project-dir $script:workersTempRoot 2>&1
        $execPayload = ($execOutput | Select-Object -Last 1) | ConvertFrom-Json

        $LASTEXITCODE | Should -Be 7
        $execPayload.status | Should -Be 'failed'
        $execPayload.exit_code | Should -Be 7
    }
}
