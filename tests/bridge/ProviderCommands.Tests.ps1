$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'winsmux task-run command' {
    BeforeAll {
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreRawContent = Get-Content -Path $script:winsmuxCoreRawPath -Raw -Encoding UTF8
    }

    It 'documents task-run in usage and dispatches it through the one-shot pipeline entrypoint' {
        $script:winsmuxCoreRawContent | Should -Match 'task-run <task>\s+Alias for pipeline; one-shot orchestration entrypoint'
        $script:winsmuxCoreRawContent | Should -Match "'task-run'\s*\{"
        $script:winsmuxCoreRawContent | Should -Match "team-pipeline\.ps1"
    }
}

Describe 'winsmux profile command' {
    BeforeAll {
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreRawContent = Get-Content -Path $script:winsmuxCoreRawPath -Raw -Encoding UTF8
    }

    BeforeEach {
        $script:profileTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-profile-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:profileTempRoot -Force | Out-Null
    }

    AfterEach {
        if ($script:profileTempRoot -and (Test-Path $script:profileTempRoot)) {
            Remove-Item -Path $script:profileTempRoot -Recurse -Force
        }
    }

    It 'passes custom provider commands into the generated Windows Terminal profile' {
        $script:winsmuxCoreRawContent | Should -Match 'function ConvertTo-ProfileAgentHashtableLiteral'
        $script:winsmuxCoreRawContent | Should -Match 'function Get-ProfileAgentGrid'
        $script:winsmuxCoreRawContent | Should -Match 'label:agent-command'
        $script:winsmuxCoreRawContent | Should -Match '\$agentArgument = '' -Rows \{0\} -Cols \{1\} -Agents @\(\{2\}\)'''

        $oldLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $script:profileTempRoot
        try {
            & pwsh -NoProfile -File $script:winsmuxCoreRawPath profile nightly builder:codex-nightly 'researcher:claude --model opus' 'reviewer:claude --append-system-prompt "hello world"' | Out-Null
        } finally {
            $env:LOCALAPPDATA = $oldLocalAppData
        }

        $fragmentPath = Join-Path $script:profileTempRoot 'Microsoft\Windows Terminal\Fragments\winsmux\winsmux.json'
        Test-Path -LiteralPath $fragmentPath | Should -Be $true
        $fragment = Get-Content -LiteralPath $fragmentPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $commandline = [string]$fragment.profiles[0].commandline
        $commandline | Should -Match '-EncodedCommand '
        $encodedCommand = ($commandline -replace '^.*-EncodedCommand\s+', '').Trim()
        $decodedCommand = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedCommand))
        $startOrchestraCall = "& (Join-Path `$env:USERPROFILE '.winsmux\bin\start-orchestra.ps1')"
        $childStartOrchestraCall = "pwsh (Join-Path `$env:USERPROFILE '.winsmux\bin\start-orchestra.ps1')"
        $decodedCommand | Should -Match ([regex]::Escape($startOrchestraCall))
        $decodedCommand | Should -Not -Match ([regex]::Escape($childStartOrchestraCall))
        $decodedCommand | Should -Match '-Rows 1 -Cols 3 -Agents @\('
        $decodedCommand | Should -Match "winsmux new-session -s 'nightly'"
        $decodedCommand | Should -Match "label = 'builder'"
        $decodedCommand | Should -Match "command = 'codex-nightly'"
        $decodedCommand | Should -Match "label = 'researcher'"
        $decodedCommand | Should -Match "command = 'claude --model opus'"
        $decodedCommand | Should -Match 'command = ''claude --append-system-prompt "hello world"'''
    }
}

Describe 'winsmux public first-run commands' {
    BeforeAll {
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreRawContent = Get-Content -Path $script:winsmuxCoreRawPath -Raw -Encoding UTF8
        $script:publicFirstRunPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\public-first-run.ps1'
        $script:publicFirstRunContent = Get-Content -Path $script:publicFirstRunPath -Raw -Encoding UTF8
    }

    It 'documents init and launch in usage and dispatches them through the public first-run helper' {
        $script:winsmuxCoreRawContent | Should -Match 'init \[--json\] \[--project-dir <path>\] \[--force\] \[--agent <provider>\] \[--model <name>\] \[--worker-count <count>\] \[--workspace-lifecycle <preset>\]\s+Create or refresh public first-run config'
        $script:winsmuxCoreRawContent | Should -Match 'launch \[--json\] \[--project-dir <path>\] \[--skip-doctor\]\s+Run public first-run checks and startup'
        $script:winsmuxCoreRawContent | Should -Match "'init'\s*\{"
        $script:winsmuxCoreRawContent | Should -Match "'launch'\s*\{"
        $script:winsmuxCoreRawContent | Should -Match 'public-first-run\.ps1'
        $script:winsmuxCoreRawContent | Should -Match 'function Test-WinsmuxInstalledBinLayout'
        $script:winsmuxCoreRawContent | Should -Match '\$skipDoctor = Test-WinsmuxInstalledBinLayout'
        $script:winsmuxCoreRawContent | Should -Match 'Invoke-WinsmuxPublicLaunch -ProjectDir \$projectDir -SkipDoctor:\$skipDoctor'
        $script:publicFirstRunContent | Should -Match 'function Invoke-WinsmuxPublicInit'
        $script:publicFirstRunContent | Should -Match 'function Invoke-WinsmuxPublicLaunch'
        $script:publicFirstRunContent | Should -Match 'Run winsmux launch\.'
    }
}

Describe 'winsmux conflict-preflight command' {
    BeforeAll {
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreRawContent = Get-Content -Path $script:winsmuxCoreRawPath -Raw -Encoding UTF8
        $script:conflictPreflightPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\conflict-preflight.ps1'
        $script:conflictPreflightContent = Get-Content -Path $script:conflictPreflightPath -Raw -Encoding UTF8
    }

    It 'documents conflict-preflight in usage and dispatches it through the helper script' {
        $script:winsmuxCoreRawContent | Should -Match 'conflict-preflight <left_ref> <right_ref> \[--json\]\s+Run git merge-tree preflight before compare UI or merge review'
        $script:winsmuxCoreRawContent | Should -Match "'conflict-preflight'\s*\{"
        $script:winsmuxCoreRawContent | Should -Match 'conflict-preflight\.ps1'
        $script:conflictPreflightContent | Should -Match 'function Get-WinsmuxConflictPreflightPayload'
        $script:conflictPreflightContent | Should -Match 'function Invoke-WinsmuxGitProbe'
    }
}

Describe 'conflict preflight helper' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\conflict-preflight.ps1')
    }

    BeforeEach {
        $script:conflictPreflightTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-conflict-preflight-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:conflictPreflightTempRoot -Force | Out-Null
    }

    AfterEach {
        if ($script:conflictPreflightTempRoot -and (Test-Path $script:conflictPreflightTempRoot)) {
            Remove-Item -Path $script:conflictPreflightTempRoot -Recurse -Force
        }
    }

    It 'returns a clean preflight result with overlap paths when merge-tree succeeds' {
        Mock Invoke-WinsmuxGitProbe {
            param($ProjectDir, [string[]]$Arguments)

            $commandLine = ($Arguments | ForEach-Object { [string]$_ }) -join ' '
            switch ($commandLine) {
                'rev-parse --show-toplevel' { return [PSCustomObject]@{ exit_code = 0; output = $script:conflictPreflightTempRoot } }
                'rev-parse --verify left^{commit}' { return [PSCustomObject]@{ exit_code = 0; output = '1111111111111111111111111111111111111111' } }
                'rev-parse --verify right^{commit}' { return [PSCustomObject]@{ exit_code = 0; output = '2222222222222222222222222222222222222222' } }
                'merge-base left right' { return [PSCustomObject]@{ exit_code = 0; output = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } }
                'diff --name-only aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa left' { return [PSCustomObject]@{ exit_code = 0; output = "src/a.ps1`nsrc/shared.ps1" } }
                'diff --name-only aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa right' { return [PSCustomObject]@{ exit_code = 0; output = "src/shared.ps1`nsrc/b.ps1" } }
                'merge-tree --write-tree --quiet left right' { return [PSCustomObject]@{ exit_code = 0; output = '' } }
                default { throw "unexpected git probe: $commandLine" }
            }
        }

        $result = Get-WinsmuxConflictPreflightPayload -ProjectDir $script:conflictPreflightTempRoot -LeftRef 'left' -RightRef 'right'

        $result.status | Should -Be 'clean'
        $result.conflict_detected | Should -Be $false
        $result.merge_tree_exit_code | Should -Be 0
        @($result.overlap_paths) | Should -Be @('src/shared.ps1')
        @($result.left_only_paths) | Should -Be @('src/a.ps1')
        @($result.right_only_paths) | Should -Be @('src/b.ps1')
    }

    It 'returns a conflict result when merge-tree detects a merge conflict' {
        Mock Invoke-WinsmuxGitProbe {
            param($ProjectDir, [string[]]$Arguments)

            $commandLine = ($Arguments | ForEach-Object { [string]$_ }) -join ' '
            switch ($commandLine) {
                'rev-parse --show-toplevel' { return [PSCustomObject]@{ exit_code = 0; output = $script:conflictPreflightTempRoot } }
                'rev-parse --verify left^{commit}' { return [PSCustomObject]@{ exit_code = 0; output = '1111111111111111111111111111111111111111' } }
                'rev-parse --verify right^{commit}' { return [PSCustomObject]@{ exit_code = 0; output = '2222222222222222222222222222222222222222' } }
                'merge-base left right' { return [PSCustomObject]@{ exit_code = 0; output = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } }
                'diff --name-only aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa left' { return [PSCustomObject]@{ exit_code = 0; output = "src/shared.ps1" } }
                'diff --name-only aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa right' { return [PSCustomObject]@{ exit_code = 0; output = "src/shared.ps1" } }
                'merge-tree --write-tree --quiet left right' { return [PSCustomObject]@{ exit_code = 1; output = '' } }
                default { throw "unexpected git probe: $commandLine" }
            }
        }

        $result = Get-WinsmuxConflictPreflightPayload -ProjectDir $script:conflictPreflightTempRoot -LeftRef 'left' -RightRef 'right'

        $result.status | Should -Be 'conflict'
        $result.reason | Should -Be 'merge_conflict'
        $result.conflict_detected | Should -Be $true
        $result.next_action | Should -Be 'Inspect overlap paths before compare or merge.'
    }

    It 'returns blocked when refs do not share a merge base' {
        Mock Invoke-WinsmuxGitProbe {
            param($ProjectDir, [string[]]$Arguments)

            $commandLine = ($Arguments | ForEach-Object { [string]$_ }) -join ' '
            switch ($commandLine) {
                'rev-parse --show-toplevel' { return [PSCustomObject]@{ exit_code = 0; output = $script:conflictPreflightTempRoot } }
                'rev-parse --verify left^{commit}' { return [PSCustomObject]@{ exit_code = 0; output = '1111111111111111111111111111111111111111' } }
                'rev-parse --verify right^{commit}' { return [PSCustomObject]@{ exit_code = 0; output = '2222222222222222222222222222222222222222' } }
                'merge-base left right' { return [PSCustomObject]@{ exit_code = 1; output = '' } }
                default { throw "unexpected git probe: $commandLine" }
            }
        }

        $result = Get-WinsmuxConflictPreflightPayload -ProjectDir $script:conflictPreflightTempRoot -LeftRef 'left' -RightRef 'right'

        $result.status | Should -Be 'blocked'
        $result.reason | Should -Be 'no_merge_base'
        $result.next_action | Should -Be 'Choose related refs with a shared merge base and rerun winsmux conflict-preflight.'
    }
}

Describe 'public first-run helper' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\settings.ps1')
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\public-first-run.ps1')
    }

    BeforeEach {
        $script:publicFirstRunTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-public-first-run-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:publicFirstRunTempRoot -Force | Out-Null
        $script:publicFirstRunRendererPayloads = @()
        Mock Get-WinsmuxBin { 'C:\test\winsmux.exe' }
        Mock Invoke-BridgeProjectSettingsRenderProcess {
            param($WinsmuxBin, $PayloadJson)

            $payload = $PayloadJson | ConvertFrom-Json
            $script:publicFirstRunRendererPayloads += $payload
            [PSCustomObject]@{
                ExitCode = 0
                StdOut   = [string]$payload.desired_yaml
            }
        }
    }

    AfterEach {
        if ($script:publicFirstRunTempRoot -and (Test-Path $script:publicFirstRunTempRoot)) {
            Remove-Item -Path $script:publicFirstRunTempRoot -Recurse -Force
        }
    }

    It 'writes the default managed-slot config on init' {
        $result = Invoke-WinsmuxPublicInit -ProjectDir $script:publicFirstRunTempRoot

        $result.status | Should -Be 'initialized'
        $result.created | Should -Be $true
        $result.slot_count | Should -Be 6
        $result.external_operator | Should -Be $true
        Test-Path -LiteralPath $result.config_path | Should -Be $true

        $settings = Get-BridgeSettings -RootPath $script:publicFirstRunTempRoot
        $settings.external_operator | Should -Be $true
        $settings.worker_count | Should -Be 6
        $settings.worker_backend | Should -Be 'local'
        $settings.agent_slots.Count | Should -Be 6
        $settings.agent_slots[0].slot_id | Should -Be 'worker-1'
        $settings.agent_slots[0].agent | Should -Be 'codex'
        $settings.agent_slots[0].model | Should -Be 'provider-default'
        $settings.agent_slots[0].model_source | Should -Be 'provider-default'
        $settings.agent_slots[0].worker_backend | Should -Be 'codex'
        $settings.agent_slots[0].worker_role | Should -Be 'reviewer'
        $settings.agent_slots[0].fallback_model | Should -Be 'gpt-5.3-codex-spark'
        $settings.agent_slots[1].worker_backend | Should -Be 'local'
        $slotKeys = if ($settings.agent_slots[1] -is [System.Collections.IDictionary]) {
            @($settings.agent_slots[1].Keys)
        } else {
            @($settings.agent_slots[1].PSObject.Properties.Name)
        }
        $slotKeys | Should -Not -Contain 'model'
        $settings.workspace_lifecycle_preset | Should -Be 'managed-worktree'
        $script:publicFirstRunRendererPayloads.Count | Should -Be 1
        $contract = $script:publicFirstRunRendererPayloads[0].nested_contract
        $contract.agent_slots.identity_key | Should -Be 'slot_id'
        @($contract.agent_slots.owned_keys) | Should -Contain 'fallback_model'
        $contract.agent_slots.aliases.backend | Should -Be 'worker_backend'
        $contract.agent_slots.aliases.role | Should -Be 'worker_role'
        @($contract.roles.owned_keys) | Should -Be @('agent', 'model', 'model_source', 'reasoning_effort', 'prompt_transport', 'auth_mode')
    }

    It 'stores a custom workspace lifecycle preset on init' {
        $result = Invoke-WinsmuxPublicInit -ProjectDir $script:publicFirstRunTempRoot -WorkspaceLifecyclePreset 'ephemeral-worktree'

        $result.status | Should -Be 'initialized'
        $result.workspace_lifecycle_preset | Should -Be 'ephemeral-worktree'

        $settings = Get-BridgeSettings -RootPath $script:publicFirstRunTempRoot
        $settings.workspace_lifecycle_preset | Should -Be 'ephemeral-worktree'
    }

    It 'stores custom provider names in managed slots on init' {
        $result = Invoke-WinsmuxPublicInit -ProjectDir $script:publicFirstRunTempRoot -Agent 'codex-nightly' -Model 'gpt-5.4-code' -WorkerCount 2

        $result.status | Should -Be 'initialized'
        $result.slot_count | Should -Be 2

        $settings = Get-BridgeSettings -RootPath $script:publicFirstRunTempRoot
        $settings.agent | Should -Be 'codex-nightly'
        $settings.model | Should -Be 'gpt-5.4-code'
        $settings.worker_count | Should -Be 2
        $settings.agent_slots.Count | Should -Be 2
        $settings.agent_slots[0].agent | Should -Be 'codex'
        $settings.agent_slots[0].model | Should -Be 'provider-default'
        $settings.agent_slots[0].worker_role | Should -Be 'reviewer'
        $settings.agent_slots[1].agent | Should -Be 'codex-nightly'
        $settings.agent_slots[1].model | Should -Be 'gpt-5.4-code'
    }

    It 'returns already_initialized when config exists and force is not set' {
        $null = Invoke-WinsmuxPublicInit -ProjectDir $script:publicFirstRunTempRoot

        $result = Invoke-WinsmuxPublicInit -ProjectDir $script:publicFirstRunTempRoot

        $result.status | Should -Be 'already_initialized'
        $result.created | Should -Be $false
        $result.slot_count | Should -Be 6
    }

    It 'blocks launch when the project config is missing' {
        $result = Invoke-WinsmuxPublicLaunch -ProjectDir $script:publicFirstRunTempRoot -SkipDoctor -BridgeScriptPath 'C:\bridge.ps1'

        $result.status | Should -Be 'blocked'
        $result.reason | Should -Be 'missing_config'
        $result.next_action | Should -Be 'Run winsmux init first.'
    }

    It 'blocks launch when doctor fails before startup' {
        $null = Invoke-WinsmuxPublicInit -ProjectDir $script:publicFirstRunTempRoot

        Mock Invoke-WinsmuxPublicDoctorProbe {
            [PSCustomObject]@{
                exit_code = 1
                output    = 'doctor failed'
            }
        }

        $result = Invoke-WinsmuxPublicLaunch -ProjectDir $script:publicFirstRunTempRoot -BridgeScriptPath 'C:\bridge.ps1' -DoctorScriptPath 'C:\doctor.ps1'

        $result.status | Should -Be 'blocked'
        $result.reason | Should -Be 'doctor_failed'
        $result.doctor_exit_code | Should -Be 1
        $result.doctor_output | Should -Be 'doctor failed'
    }

    It 'returns the operator contract when startup smoke succeeds' {
        $null = Invoke-WinsmuxPublicInit -ProjectDir $script:publicFirstRunTempRoot

        Mock Invoke-WinsmuxPublicDoctorProbe {
            [PSCustomObject]@{
                exit_code = 0
                output    = '[PASS] doctor'
            }
        }

        Mock Invoke-WinsmuxPublicSmokeProbe {
            [PSCustomObject]@{
                exit_code   = 0
                raw_output  = '{"operator_contract":{"operator_state":"ready","can_dispatch":true,"requires_startup":false,"operator_message":"ready","next_action":"Dispatch work or continue operator flow."}}'
                parse_error = ''
                parsed      = [PSCustomObject]@{
                    operator_contract = [PSCustomObject]@{
                        operator_state   = 'ready'
                        can_dispatch     = $true
                        requires_startup = $false
                        operator_message = 'ready'
                        next_action      = 'Dispatch work or continue operator flow.'
                    }
                }
            }
        }

        $result = Invoke-WinsmuxPublicLaunch -ProjectDir $script:publicFirstRunTempRoot -BridgeScriptPath 'C:\bridge.ps1' -DoctorScriptPath 'C:\doctor.ps1'

        $result.status | Should -Be 'ready'
        $result.can_dispatch | Should -Be $true
        $result.requires_startup | Should -Be $false
        $result.operator_message | Should -Be 'ready'
        $result.next_action | Should -Be 'Dispatch work or continue operator flow.'
    }
}

Describe 'winsmux readiness adapter helpers' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreRawContent = Get-Content -Raw -Path $script:winsmuxCorePath -Encoding UTF8
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:readinessTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-readiness-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:readinessTempRoot '.winsmux') -Force | Out-Null

@'
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  reviewer:
    pane_id: %4
    role: Reviewer
    capability_adapter: claude
  builder-1:
    pane_id: %2
    role: Builder
    capability_adapter: codex
  legacy:
    pane_id: %8
    role: Worker
    provider_target: codex:gpt-5.4
  switched:
    pane_id: %10
    role: Worker
    capability_adapter: codex
'@ | Set-Content -Path (Join-Path $script:readinessTempRoot '.winsmux\manifest.yaml') -Encoding UTF8

@'
agent: codex
model: gpt-5.4
prompt-transport: argv
agent-slots:
  - slot-id: switched
    runtime-role: worker
    agent: codex
    model: gpt-5.4
    prompt-transport: argv
'@ | Set-Content -Path (Join-Path $script:readinessTempRoot '.winsmux.yaml') -Encoding UTF8

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "prompt_transports": ["argv", "file", "stdin"]
    },
    "claude": {
      "adapter": "claude",
      "command": "claude",
      "prompt_transports": ["file"]
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:readinessTempRoot '.winsmux\provider-capabilities.json') -Encoding UTF8

@'
{
  "version": 1,
  "slots": {
    "switched": {
      "agent": "claude",
      "model": "opus",
      "prompt_transport": "file"
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:readinessTempRoot '.winsmux\provider-registry.json') -Encoding UTF8
    }

    AfterEach {
        if ($script:readinessTempRoot -and (Test-Path $script:readinessTempRoot)) {
            Remove-Item -Path $script:readinessTempRoot -Recurse -Force
        }
    }

    It 'uses the shared readiness detector for configured adapters' {
        (Test-AgentReadyPromptText -Text @"
gpt-5.4   64% context left
? send   Ctrl+J newline
>
"@ -Agent 'codex') | Should -Be $true

        (Test-AgentReadyPromptText -Text '>' -Agent 'codex') | Should -Be $true
        (Test-AgentReadyPromptText -Text 'Welcome to Claude Code!' -Agent 'claude') | Should -Be $true
        (Test-AgentReadyPromptText -Text '›' -Agent 'claude') | Should -Be $true
        (Test-AgentReadyPromptText -Text @"
│ ✻ Welcome to Claude Code! │
╰──────────────────────╯
"@ -Agent 'claude') | Should -Be $true
        (Test-AgentReadyPromptText -Text 'gemini-2.5-pro   84% context left' -Agent 'gemini') | Should -Be $true
        (Test-AgentReadyPromptText -Text '▌' -Agent 'gemini') | Should -Be $true
        (Test-AgentReadyPromptText -Text @"
│ Type your message... │
╰──────────────────────╯
"@ -Agent 'gemini') | Should -Be $true
    }

    It 'does not treat stale prompt markers as ready' {
        (Test-AgentReadyPromptText -Text @"
gpt-5.4   64% context left
? send   Ctrl+J newline
>
thinking
"@ -Agent 'codex') | Should -Be $false

        (Test-AgentReadyPromptText -Text @"
Welcome to Claude Code!
thinking
"@ -Agent 'claude') | Should -Be $false
    }

    It 'keeps readiness unknown when provider metadata is missing' {
        { Test-AgentReadyPromptText -Text '>' -Agent '' } | Should -Not -Throw
        (Test-AgentReadyPromptText -Text '>' -Agent '') | Should -Be $false
        (Test-AgentReadyPromptText -Text 'Welcome to Claude Code!' -Agent '') | Should -Be $false
    }

    It 'normalizes provider aliases before adapter readiness checks' {
        ConvertTo-ReadinessAgentName 'codex-nightly' | Should -Be 'codex'
        ConvertTo-ReadinessAgentName 'Claude/opus' | Should -Be 'claude'
        ConvertTo-ReadinessAgentName 'gemini:flash' | Should -Be 'gemini'
    }

    It 'resolves readiness adapters from the pane manifest' {
        Get-PaneReadinessAgent -Target 'reviewer' -PaneId '%4' -ProjectDir $script:readinessTempRoot | Should -Be 'claude'
        Get-PaneReadinessAgent -Target 'builder-1' -PaneId '%2' -ProjectDir $script:readinessTempRoot | Should -Be 'codex'
        Get-PaneReadinessAgent -Target 'legacy' -PaneId '%8' -ProjectDir $script:readinessTempRoot | Should -Be 'codex'
        Get-PaneReadinessAgent -Target 'switched' -PaneId '%10' -ProjectDir $script:readinessTempRoot | Should -Be 'codex'
        Get-PaneReadinessAgent -Target 'missing' -PaneId '%9' -ProjectDir $script:readinessTempRoot | Should -Be ''
    }

    It 'documents wait-ready without a Codex-only prompt contract' {
        $script:winsmuxCoreRawContent | Should -Match 'Wait for the configured agent prompt in pane'
        $script:winsmuxCoreRawContent | Should -Match 'Test-AgentReadyPrompt -PaneId \$paneId -Agent \$readinessAgent'
        $script:winsmuxCoreRawContent | Should -Match 'Test-AgentReadyPromptText -Text \$secondSnapshot -Agent \$readinessAgent'
        $script:winsmuxCoreRawContent | Should -Match 'Set-PaneReadinessManifestFromRestartPlan -ProjectDir \$ProjectDir -PaneId \$PaneId -Plan \$plan'
    }
}

Describe 'winsmux provider-capabilities command' {
    BeforeAll {
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreRawContent = Get-Content -Raw -Path $script:winsmuxCoreRawPath -Encoding UTF8
    }

    BeforeEach {
        $script:providerCapabilitiesTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-provider-capabilities-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:providerCapabilitiesTempRoot '.winsmux') -Force | Out-Null

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "display_name": "Codex",
      "command": "codex",
      "model_options": [
        {"id": "provider-default", "label": "Provider default", "source": "provider-default"},
        {"id": "gpt-5.3-codex-spark", "label": "GPT-5.3-Codex-Spark", "source": "cli-discovery", "availability": "local-account"}
      ],
      "model_sources": ["provider-default", "cli-discovery"],
      "reasoning_efforts": ["provider-default", "low", "medium", "high", "xhigh"],
      "local_access_note": "Local Codex CLI catalog and ChatGPT account access.",
      "harness_availability": "official-cli",
      "credential_requirements": "local-cli-owned",
      "execution_backend": "agent-cli",
      "runtime_requirements": "Codex CLI installed in the pane environment.",
      "analysis_posture": "read-write-worker",
      "prompt_transports": ["argv", "file", "stdin"],
      "supports_file_edit": true,
      "supports_verification": true,
      "supports_subagents": true
    },
    "local-openai-compatible": {
      "adapter": "openai-compatible",
      "display_name": "Local OpenAI-compatible endpoint",
      "command": "winsmux-local-llm",
      "model_options": [
        {"id": "operator-selected", "label": "Operator-selected runtime model", "source": "operator-override", "availability": "runtime-discovery"}
      ],
      "model_sources": ["operator-override"],
      "reasoning_efforts": ["provider-default"],
      "model_catalog_source": "runtime-health-endpoint",
      "local_access_note": "Local endpoint owns model access and request handling.",
      "harness_availability": "external-adapter",
      "credential_requirements": "runtime-owned-local-endpoint",
      "execution_backend": "openai-compatible-local-endpoint",
      "runtime_requirements": "127.0.0.1 endpoint; GPU/CPU capacity owned by runtime.",
      "analysis_posture": "read-only-analysis",
      "prompt_transports": ["stdin"],
      "auth_modes": ["none", "local-api-key"],
      "read_only_launch_args": ["--read-only", "--no-file-edits"],
      "supports_file_edit": false,
      "supports_verification": false,
      "supports_consultation": true
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:providerCapabilitiesTempRoot '.winsmux\provider-capabilities.json') -Encoding UTF8
    }

    AfterEach {
        if ($script:providerCapabilitiesTempRoot -and (Test-Path $script:providerCapabilitiesTempRoot)) {
            Remove-Item -Path $script:providerCapabilitiesTempRoot -Recurse -Force
        }
    }

    It 'documents provider-capabilities in usage and reports the registry contract' {
        $script:winsmuxCoreRawContent | Should -Match 'provider-capabilities \[provider\] \[--json\]'
        $script:winsmuxCoreRawContent | Should -Match "'provider-capabilities'\s*\{"

        Push-Location $script:providerCapabilitiesTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-capabilities --json
        } finally {
            Pop-Location
        }

        $payload = $output | ConvertFrom-Json
        $payload.version | Should -Be 1
        $payload.providers.codex.adapter | Should -Be 'codex'
        $payload.providers.codex.model_options[1].source | Should -Be 'cli-discovery'
        $payload.providers.codex.reasoning_efforts | Should -Be @('provider-default', 'low', 'medium', 'high', 'xhigh')
        $payload.providers.codex.local_access_note | Should -Be 'Local Codex CLI catalog and ChatGPT account access.'
        $payload.providers.codex.harness_availability | Should -Be 'official-cli'
        $payload.providers.codex.prompt_transports | Should -Be @('argv', 'file', 'stdin')
        $payload.providers.codex.supports_file_edit | Should -Be $true
        $payload.providers.'local-openai-compatible'.analysis_posture | Should -Be 'read-only-analysis'
        $payload.providers.'local-openai-compatible'.credential_requirements | Should -Be 'runtime-owned-local-endpoint'
        $payload.providers.'local-openai-compatible'.execution_backend | Should -Be 'openai-compatible-local-endpoint'
        $payload.providers.'local-openai-compatible'.read_only_launch_args | Should -Be @('--read-only', '--no-file-edits')
        $payload.providers.'local-openai-compatible'.supports_file_edit | Should -Be $false
    }

    It 'reports one provider capability entry' {
        Push-Location $script:providerCapabilitiesTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-capabilities CODEX --json
        } finally {
            Pop-Location
        }

        $payload = $output | ConvertFrom-Json
        $payload.provider_id | Should -Be 'CODEX'
        $payload.capabilities.command | Should -Be 'codex'
        $payload.capabilities.model_sources | Should -Be @('provider-default', 'cli-discovery')
        $payload.capabilities.supports_verification | Should -Be $true
    }
}

Describe 'winsmux meta-plan command' {
    BeforeAll {
        $script:winsmuxMetaPlanCoreRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxMetaPlanCoreRawContent = Get-Content -Raw -Path $script:winsmuxMetaPlanCoreRawPath -Encoding UTF8
        . $script:winsmuxMetaPlanCoreRawPath 'version' *> $null
    }

    It 'documents meta-plan in usage and delegates to the Rust meta-plan contract' {
        $script:winsmuxMetaPlanCoreRawContent | Should -Match 'meta-plan --task <text> \[--roles <path>\] \[--review-rounds <1\|2>\] \[--json\] \[--project-dir <path>\] \[--session <name>\]'
        $script:winsmuxMetaPlanCoreRawContent | Should -Match "'meta-plan'\s*\{ Invoke-MetaPlan \}"

        Mock Invoke-WinsmuxRaw {
            param([string[]]$Arguments)
            $script:metaPlanArgs = @($Arguments)
            return '{"command":"meta-plan","roles":[{"role_id":"investigator"},{"role_id":"verifier"}],"audit_events":["meta_plan_init","role_assigned","plan_drafted","cross_review","plan_merged","exit_plan_mode"]}'
        }

        $output = Invoke-MetaPlan -MetaPlanTarget '--task' -MetaPlanRest @('日本語IME対応', '--roles', 'roles.yaml', '--review-rounds', '2', '--json')
        $json = $output | ConvertFrom-Json
        $script:metaPlanArgs | Should -Be @('meta-plan', '--task', '日本語IME対応', '--roles', 'roles.yaml', '--review-rounds', '2', '--json')
        $json.command | Should -Be 'meta-plan'
        @($json.roles.role_id) | Should -Be @('investigator', 'verifier')
        $json.audit_events | Should -Contain 'exit_plan_mode'
    }
}

Describe 'winsmux guard command' {
    BeforeAll {
        $script:winsmuxGuardCoreRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxGuardCoreRawContent = Get-Content -Raw -Path $script:winsmuxGuardCoreRawPath -Encoding UTF8
        . $script:winsmuxGuardCoreRawPath 'version' *> $null
    }

    It 'documents guard in usage and delegates to the Rust guard report' {
        $script:winsmuxGuardCoreRawContent | Should -Match 'guard \[--json\]'
        $script:winsmuxGuardCoreRawContent | Should -Match "'guard'\s*\{ Invoke-Guard \}"

        Mock Invoke-WinsmuxRaw {
            param([string[]]$Arguments)
            $script:guardArgs = @($Arguments)
            return '{"command":"guard","task_ids":["TASK-362","TASK-383","TASK-384"]}'
        }

        $output = Invoke-Guard -GuardTarget '--json'
        $json = $output | ConvertFrom-Json
        $script:guardArgs | Should -Be @('guard', '--json')
        $json.command | Should -Be 'guard'
        @($json.task_ids) | Should -Be @('TASK-362', 'TASK-383', 'TASK-384')
    }

    It 'rejects unknown guard arguments' {
        { Invoke-Guard -GuardTarget '--private' } | Should -Throw '*usage: winsmux guard [--json]*'
    }
}

Describe 'winsmux skills command' {
    BeforeAll {
        $script:winsmuxSkillsCoreRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxSkillsCoreRawContent = Get-Content -Raw -Path $script:winsmuxSkillsCoreRawPath -Encoding UTF8
        . $script:winsmuxSkillsCoreRawPath 'version' *> $null
    }

    It 'documents skills in usage and delegates to the Rust skills catalog' {
        $script:winsmuxSkillsCoreRawContent | Should -Match 'skills \[--json\]'
        $script:winsmuxSkillsCoreRawContent | Should -Match "'skills'\s*\{ Invoke-Skills \}"

        Mock Invoke-WinsmuxRaw {
            param([string[]]$Arguments)
            $script:skillsArgs = @($Arguments)
            return '{"packet_type":"progressive_skills_catalog","private_skill_bodies_allowed":false,"workflow_pack_registry":{"private_skill_bodies_allowed":false,"local_absolute_paths_allowed":false,"discovery":{"supported_levels":["builtin","user","repository"],"sources":[{"level":"user","source_ref":"user-workflow-packs","private_skill_bodies_allowed":false,"local_absolute_paths_allowed":false},{"level":"repository","source_ref":"repository-workflow-packs","private_skill_bodies_allowed":false,"local_absolute_paths_allowed":false}]},"packs":[{"id":"compare-and-promote","metadata":{"review_role":"reviewer"},"scope":["compare run outputs"],"supporting_files":["docs/operator-model.md"],"provenance":{"private_material_referenced":false},"evidence_requirements":["comparison_evidence","playbook_template_contract"]},{"id":"repository-skill-discovery","metadata":{"review_role":"operator"},"scope":["discover workflow pack source levels"],"supporting_files":["docs/operator-model.md"],"provenance":{"private_material_referenced":false,"local_absolute_path_stored":false},"discovery":{"available_source_levels":["user","repository"],"selected_level":"repository","selection_reason":"repository contracts take precedence when tracked docs define the workflow pack boundary"},"loading_plan":{"minimum_supporting_files":["docs/operator-model.md"],"public_contract_only":true},"evidence_requirements":["workflow_pack_registry","discovery_source_metadata","scoped_loading_plan"]}]},"workflow_execution_contract":{"entrypoint":"winsmux skills --json","private_skill_bodies_allowed":false,"local_absolute_paths_allowed":false,"required_request_fields":["workflow_pack_id"],"selection_result_fields":["selected_pack_id","selected_level","selection_reason","source_ref"],"scoped_loading_plan_fields":["selected_pack_id","minimum_supporting_files","load_order","excluded"]},"skills":[{"id":"compare-and-promote","required_evidence":["comparison_evidence","playbook_template_contract"],"private_skill_body_stored":false},{"id":"repository-skill-discovery","required_evidence":["workflow_pack_registry","discovery_source_metadata","scoped_loading_plan"],"private_skill_body_stored":false}]}'
        }

        $output = Invoke-Skills -SkillsTarget '--json'
        $json = $output | ConvertFrom-Json
        $script:skillsArgs | Should -Be @('skills', '--json')
        $json.packet_type | Should -Be 'progressive_skills_catalog'
        $json.private_skill_bodies_allowed | Should -Be $false
        $json.workflow_pack_registry.private_skill_bodies_allowed | Should -Be $false
        $json.workflow_pack_registry.local_absolute_paths_allowed | Should -Be $false
        $json.workflow_pack_registry.discovery.supported_levels | Should -Contain 'user'
        $json.workflow_pack_registry.discovery.supported_levels | Should -Contain 'repository'
        $json.workflow_pack_registry.discovery.sources[1].source_ref | Should -Be 'repository-workflow-packs'
        $json.workflow_pack_registry.PSObject.Properties.Name | Should -Not -Contain 'selected_pack'
        $json.workflow_pack_registry.PSObject.Properties.Name | Should -Not -Contain 'scoped_loading_plan'
        $json.workflow_pack_registry.packs[0].id | Should -Be 'compare-and-promote'
        $json.workflow_pack_registry.packs[0].supporting_files | Should -Contain 'docs/operator-model.md'
        $json.workflow_pack_registry.packs[0].provenance.private_material_referenced | Should -Be $false
        $json.workflow_pack_registry.packs[0].evidence_requirements | Should -Contain 'playbook_template_contract'
        $json.workflow_pack_registry.packs[1].id | Should -Be 'repository-skill-discovery'
        $json.workflow_pack_registry.packs[1].discovery.selection_reason | Should -Match 'repository contracts'
        $json.workflow_pack_registry.packs[1].loading_plan.minimum_supporting_files | Should -Be @('docs/operator-model.md')
        $json.workflow_pack_registry.packs[1].provenance.local_absolute_path_stored | Should -Be $false
        $json.workflow_execution_contract.entrypoint | Should -Be 'winsmux skills --json'
        $json.workflow_execution_contract.required_request_fields | Should -Contain 'workflow_pack_id'
        $json.workflow_execution_contract.selection_result_fields | Should -Contain 'selection_reason'
        $json.workflow_execution_contract.scoped_loading_plan_fields | Should -Contain 'minimum_supporting_files'
        $json.skills[0].required_evidence | Should -Contain 'playbook_template_contract'
        $json.skills[0].private_skill_body_stored | Should -Be $false
        $json.skills[1].required_evidence | Should -Contain 'scoped_loading_plan'
        ($output -join "`n") | Should -Not -Match 'C:\\'
        ($output -join "`n") | Should -Not -Match 'C:/'
        ($output -join "`n") | Should -Not -Match '\\Users\\'
    }

    It 'rejects unknown skills arguments' {
        { Invoke-Skills -SkillsTarget '--private' } | Should -Throw '*usage: winsmux skills [--json]*'
    }
}

Describe 'winsmux assign command' {
    BeforeAll {
        $script:winsmuxAssignRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxAssignRawContent = Get-Content -Raw -Path $script:winsmuxAssignRawPath -Encoding UTF8
    }

    BeforeEach {
        $script:winsmuxAssignTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-assign-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:winsmuxAssignTempRoot 'tasks') -Force | Out-Null
@'
tasks:
  - id: TASK-405
    title: "Operator judgment memory and dynamic AI team assignment policy for Claude Code runs (#676)"
    status: backlog
    priority: P0
    target_version: "v0.24.8"
    repo: winsmux
    labels: [enhancement, orchestration, multi-vendor, model-policy, security, release-blocker]
    notes: >
      Add a policy layer that chooses provider, role, model, effort, approval policy,
      sandbox mode, and context budget from TASK, Issue, and PR content.
      Do not store provider tokens. Keep Claude Code as the upper operator.
'@ | Set-Content -Path (Join-Path $script:winsmuxAssignTempRoot 'tasks\backlog.yaml') -Encoding UTF8
    }

    AfterEach {
        if ($script:winsmuxAssignTempRoot -and (Test-Path $script:winsmuxAssignTempRoot)) {
            Remove-Item -Path $script:winsmuxAssignTempRoot -Recurse -Force
        }
    }

    It 'documents assign and returns a dry-run JSON assignment without token storage' {
        $script:winsmuxAssignRawContent | Should -Match 'assign --task <TASK-ID> \[--json\] \[--text <text>\]'
        $script:winsmuxAssignRawContent | Should -Match "'assign'\s*\{"

        Push-Location $script:winsmuxAssignTempRoot
        try {
            $env:WINSMUX_BACKLOG_PATH = Join-Path $script:winsmuxAssignTempRoot 'tasks\backlog.yaml'
            $output = & pwsh -NoProfile -File $script:winsmuxAssignRawPath assign --task TASK-405 --json
        } finally {
            $env:WINSMUX_BACKLOG_PATH = $null
            Pop-Location
        }

        $payload = $output | ConvertFrom-Json
        $payload.dry_run | Should -BeTrue
        $payload.task_id | Should -Be 'TASK-405'
        $payload.upper_operator.product | Should -Be 'Claude Code'
        $payload.upper_operator.owns_final_judgment | Should -BeTrue
        $payload.assignment.selected.capability_tier | Should -Be 'deep_review'
        $payload.assignment.selected.model | Should -Be 'alias:opus'
        $payload.assignment.selected.model_resolution | Should -Be 'alias:opus'
        $payload.assignment.selected.model_reasoning_effort | Should -Be 'high'
        $payload.assignment.selected.model_reasoning_summary | Should -Be 'none'
        $payload.assignment.selected.approvals_reviewer | Should -Be 'operator'
        @($payload.assignment.fallback.provider) | Should -Contain 'antigravity'
        $payload.assignment.approval_policy | Should -Be 'operator_review_required'
        $payload.security.stores_provider_tokens | Should -BeFalse
        $payload.security.brokers_oauth | Should -BeFalse
        $payload.generated_outputs | Should -Contain 'provider_capability_catalog.generated.json'
        $payload.generated_outputs | Should -Contain 'model_resolution_report.json'
    }

    It 'routes fast research packets to Antigravity instead of Gemini' {
        Push-Location $script:winsmuxAssignTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxAssignRawPath assign --text 'research docs and planning context shaping' --json
        } finally {
            Pop-Location
        }

        $payload = $output | ConvertFrom-Json
        $payload.assignment.selected.provider | Should -Be 'antigravity'
        $payload.assignment.selected.auth_mode | Should -Be 'antigravity-official-cli'
        $payload.assignment.selected.rationale | Should -Match 'Gemini CLI individual tier sunset'
    }
}

Describe 'winsmux launcher command' {
    BeforeAll {
        $script:winsmuxLauncherRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxLauncherRawContent = Get-Content -Raw -Path $script:winsmuxLauncherRawPath -Encoding UTF8
    }

    BeforeEach {
        $script:winsmuxLauncherTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-launcher-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:winsmuxLauncherTempRoot '.winsmux') -Force | Out-Null

@'
version: 1
agent: codex
model: gpt-5.4
external_operator: true
worker_count: 3
workspace_lifecycle_preset: managed-worktree
agent_slots:
  - slot_id: worker-1
    runtime_role: worker
    agent: codex
    model: gpt-5.4
    prompt_transport: argv
  - slot_id: worker-2
    runtime_role: worker
    agent: claude
    model: opus
    prompt_transport: file
    auth_mode: claude-pro-max-oauth
  - slot_id: reviewer-1
    runtime_role: reviewer
    agent: claude
    model: opus
    prompt_transport: file
'@ | Set-Content -Path (Join-Path $script:winsmuxLauncherTempRoot '.winsmux.yaml') -Encoding UTF8

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "display_name": "Codex",
      "command": "codex",
      "prompt_transports": ["argv", "file", "stdin"],
      "auth_modes": ["api-key", "codex-chatgpt-local"],
      "local_interactive_oauth_modes": ["codex-chatgpt-local"],
      "supports_file_edit": true,
      "supports_verification": true,
      "supports_structured_result": true,
      "supports_subagents": true
    },
    "claude": {
      "adapter": "claude",
      "display_name": "Claude",
      "command": "claude",
      "prompt_transports": ["file"],
      "auth_modes": ["api-key", "claude-pro-max-oauth"],
      "local_interactive_oauth_modes": ["claude-pro-max-oauth"],
      "supports_file_edit": true,
      "supports_verification": true,
      "supports_structured_result": false,
      "supports_consultation": true
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:winsmuxLauncherTempRoot '.winsmux\provider-capabilities.json') -Encoding UTF8
    }

    AfterEach {
        if ($script:winsmuxLauncherTempRoot -and (Test-Path $script:winsmuxLauncherTempRoot)) {
            Remove-Item -Path $script:winsmuxLauncherTempRoot -Recurse -Force
        }
    }

    It 'documents launcher in usage and returns capability-aware presets' {
        $script:winsmuxLauncherRawContent | Should -Match 'launcher <presets\|lifecycle\|list\|save> \[name\] \[--lifecycle <preset>\] \[--json\]'
        $script:winsmuxLauncherRawContent | Should -Match "'launcher'\s*\{"

        Push-Location $script:winsmuxLauncherTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxLauncherRawPath launcher presets --json
        } finally {
            Pop-Location
        }

        $payload = $output | ConvertFrom-Json
        $payload.version | Should -Be 1
        $payload.slot_count | Should -Be 3
        $payload.slots[0].slot_id | Should -Be 'worker-1'
        $payload.slots[0].capability_adapter | Should -Be 'codex'
        $payload.slots[1].prompt_transport | Should -Be 'file'
        $payload.slots[1].auth_mode | Should -Be 'claude-pro-max-oauth'
        $payload.slots[1].auth_policy | Should -Be 'local_interactive_only'
        @($payload.presets.name) | Should -Contain 'all-workers'
        @($payload.presets.name) | Should -Contain 'balanced-build-review'
        @($payload.presets.name) | Should -Contain 'verification'
        $payload.pair_templates[0].name | Should -Be 'ab-pair'
        @($payload.pair_templates[0].slot_ids) | Should -Be @('worker-1', 'worker-2')
        $payload.workspace_lifecycle.selected_preset | Should -Be 'managed-worktree'
        @($payload.workspace_lifecycle.presets.name) | Should -Contain 'ephemeral-worktree'
        $payload.workspace_lifecycle.presets[0].PSObject.Properties.Name | Should -Not -Contain 'setup_scripts'
        $payload.workspace_lifecycle.presets[0].PSObject.Properties.Name | Should -Not -Contain 'teardown_scripts'
        $payload.templates_path | Should -Match '\\.winsmux\\launcher-templates\.json$'
    }

    It 'saves and lists launcher templates without rewriting project settings' {
        Push-Location $script:winsmuxLauncherTempRoot
        try {
            $saveOutput = & pwsh -NoProfile -File $script:winsmuxLauncherRawPath launcher save build-review --json
            $listOutput = & pwsh -NoProfile -File $script:winsmuxLauncherRawPath launcher list --json
        } finally {
            Pop-Location
        }

        $saved = $saveOutput | ConvertFrom-Json
        $listed = $listOutput | ConvertFrom-Json
        $saved.name | Should -Be 'build-review'
        $saved.saved | Should -Be $true
        $saved.template.slot_count | Should -Be 3
        @($saved.template.presets.name) | Should -Contain 'balanced-build-review'
        $saved.template.workspace_lifecycle.selected_preset | Should -Be 'managed-worktree'
        Test-Path -LiteralPath $saved.templates_path | Should -Be $true
        $listed.template_count | Should -Be 1
        $listed.templates[0].name | Should -Be 'build-review'
        Test-Path -LiteralPath (Join-Path $script:winsmuxLauncherTempRoot '.winsmux.yaml') | Should -Be $true
    }

    It 'sets and clears workspace lifecycle override without rewriting project settings' {
        $settingsPath = Join-Path $script:winsmuxLauncherTempRoot '.winsmux.yaml'
        $settingsBefore = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8

        Push-Location $script:winsmuxLauncherTempRoot
        try {
            $setOutput = & pwsh -NoProfile -File $script:winsmuxLauncherRawPath launcher lifecycle ephemeral-worktree --json
        } finally {
            Pop-Location
        }

        $setPayload = $setOutput | ConvertFrom-Json
        $setPayload.selected_preset | Should -Be 'ephemeral-worktree'
        $setPayload.override_saved | Should -Be $true
        Test-Path -LiteralPath $setPayload.saved_path | Should -Be $true
        $override = Get-Content -LiteralPath $setPayload.saved_path -Raw -Encoding UTF8 | ConvertFrom-Json
        $override.preset | Should -Be 'ephemeral-worktree'

        Push-Location $script:winsmuxLauncherTempRoot
        try {
            $clearOutput = & pwsh -NoProfile -File $script:winsmuxLauncherRawPath launcher lifecycle --clear --json
        } finally {
            Pop-Location
        }

        $clearPayload = $clearOutput | ConvertFrom-Json
        $clearPayload.selected_preset | Should -Be 'managed-worktree'
        $clearPayload.override_cleared | Should -Be $true
        Test-Path -LiteralPath $setPayload.saved_path | Should -Be $false

        $settingsAfter = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
        $settingsAfter | Should -Be $settingsBefore
    }

    It 'rejects unknown workspace lifecycle presets' {
        Push-Location $script:winsmuxLauncherTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxLauncherRawPath launcher lifecycle custom-script --json 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $exitCode | Should -Be 1
        ($output | Out-String) | Should -Match 'workspace lifecycle preset not found: custom-script'
        Test-Path -LiteralPath (Join-Path $script:winsmuxLauncherTempRoot '.winsmux\workspace-lifecycle.json') | Should -Be $false
    }

    It 'rejects lifecycle clear when combined with another launcher mode or preset' {
        Push-Location $script:winsmuxLauncherTempRoot
        try {
            $presetOutput = & pwsh -NoProfile -File $script:winsmuxLauncherRawPath launcher presets --clear --json 2>&1
            $presetExitCode = $LASTEXITCODE
            $combinedOutput = & pwsh -NoProfile -File $script:winsmuxLauncherRawPath launcher lifecycle ephemeral-worktree --clear --json 2>&1
            $combinedExitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $presetExitCode | Should -Be 1
        ($presetOutput | Out-String) | Should -Match 'usage: winsmux launcher lifecycle \[preset\|--clear\] \[--json\]'
        $combinedExitCode | Should -Be 1
        ($combinedOutput | Out-String) | Should -Match 'usage: winsmux launcher lifecycle \[preset\|--clear\] \[--json\]'
    }

    It 'rejects save when only --json is supplied instead of a template name' {
        Push-Location $script:winsmuxLauncherTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxLauncherRawPath launcher save --json 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $exitCode | Should -Be 1
        ($output | Out-String) | Should -Match 'usage: winsmux launcher save <name> \[--json\]'
        Test-Path -LiteralPath (Join-Path $script:winsmuxLauncherTempRoot '.winsmux\launcher-templates.json') | Should -Be $false
    }
}

Describe 'winsmux role command provider routing' {
    BeforeAll {
        $script:winsmuxRoleRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxRoleRawContent = Get-Content -Raw -Path $script:winsmuxRoleRawPath -Encoding UTF8

        function Invoke-TestManagedPaneLifecycleMutationRefusal {
            param(
                [Parameter(Mandatory = $true)][bool]$HasManifest,
                [AllowNull()]$Validation,
                [ValidateSet('role', 'restart', 'name', 'kill')][string]$OperationName = 'role',
                [AllowEmptyString()][string]$RequestedLabel = '',
                [AllowNull()]$Context = $null
            )

            $helperSource = [regex]::Match(
                $script:winsmuxRoleRawContent,
                '(?s)function Get-ManagedPaneLifecycleMutationRefusal \{.*?\r?\n\}\r?\n\r?\nfunction Invoke-Role'
            ).Value
            if ([string]::IsNullOrWhiteSpace($helperSource)) {
                throw 'Failed to extract Get-ManagedPaneLifecycleMutationRefusal from winsmux-core.ps1.'
            }
            $helperSource = $helperSource -replace '\r?\n\r?\nfunction Invoke-Role$', ''

            & {
                param($HelperSource, $HasManifest, $Validation, $OperationName, $RequestedLabel, $Context)
                Set-StrictMode -Version Latest

                function Test-Path {
                    param([string]$LiteralPath, [string]$PathType)
                    return $HasManifest
                }

                function Get-PaneControlManifestContext {
                    param([string]$ProjectDir, [string]$PaneId)
                    return [pscustomobject]@{ ProjectDir = $ProjectDir; PaneId = $PaneId }
                }

                function Test-PaneControlRuntimeContext {
                    param([string]$ProjectDir, $ManifestEntry, [string]$Operation)
                    return $Validation
                }

                function Resolve-WinsmuxManagedTargetContext {
                    param([string]$PaneId, [string]$CurrentProjectDir, [string]$Operation)
                    return [pscustomobject]@{
                        Managed    = $HasManifest
                        Validation = $Validation
                        Context    = $Context
                    }
                }

                Invoke-Expression $HelperSource
                Get-ManagedPaneLifecycleMutationRefusal -ProjectDir 'C:\synthetic-winsmux' -PaneId '%1' `
                    -OperationName $OperationName -RequestedLabel $RequestedLabel
            } $helperSource $HasManifest $Validation $OperationName $RequestedLabel $Context
        }
    }

    It 'builds reassigned role launch commands through provider capabilities' {
        $script:winsmuxRoleRawContent | Should -Match 'Get-SlotAgentConfig -Role \$newRole -SlotId \$newLabel'
        $script:winsmuxRoleRawContent | Should -Match 'Get-BridgeProviderLaunchCommand'
        $script:winsmuxRoleRawContent | Should -Match '\$launchDir = \[string\]\$manifestEntry\.LaunchDir'
        $script:winsmuxRoleRawContent | Should -Match '\$gitDir = \[string\]\$manifestEntry\.GitWorktreeDir'
        $script:winsmuxRoleRawContent | Should -Match 'ProjectDir \$launchDir'
        $script:winsmuxRoleRawContent | Should -Match ([regex]::Escape("Invoke-WinsmuxRaw -Arguments @('respawn-pane', '-k', '-t', `$paneId, '-c', `$launchDir)"))
        $script:winsmuxRoleRawContent | Should -Match 'role\s*=\s*\$manifestRole'
        $script:winsmuxRoleRawContent | Should -Match 'launch_dir\s*=\s*\$launchDir'
        $script:winsmuxRoleRawContent | Should -Match 'worktree_git_dir\s*=\s*\$gitDir'
        $script:winsmuxRoleRawContent | Should -Match 'provider_target\s*=\s*\$providerTarget'
        $script:winsmuxRoleRawContent | Should -Match 'capability_adapter\s*=\s*\[string\]\$roleAgentConfig\.CapabilityAdapter'
        $script:winsmuxRoleRawContent | Should -Match "builder_worktree_path'\]\s*=\s*''"
        $script:winsmuxRoleRawContent | Should -Match "builder_branch'\]\s*=\s*''"
        $script:winsmuxRoleRawContent | Should -Match '\$environmentGitDir\s*=\s*'''''
        $script:winsmuxRoleRawContent | Should -Match '\$assignedBranch\s*=\s*\[string\]\$manifestEntry\.BuilderBranch'
        $script:winsmuxRoleRawContent | Should -Match 'Get-WinsmuxEnvironmentVariableNames'
        $script:winsmuxRoleRawContent | Should -Match 'Get-WinsmuxPaneEnvironment'
        $script:winsmuxRoleRawContent | Should -Match 'WINSMUX_ROLE_MAP'
        $script:winsmuxRoleRawContent | Should -Match ([regex]::Escape("Invoke-WinsmuxRaw -Arguments @('set-environment', '-t', `$sessionName"))
        $script:winsmuxRoleRawContent | Should -Match ([regex]::Escape("Invoke-WinsmuxRaw -Arguments @('set-environment', '-u', '-t', `$sessionName, `$name)"))
        $script:winsmuxRoleRawContent | Should -Not -Match 'codex --sandbox danger-full-access -C'
        $launchIndex = $script:winsmuxRoleRawContent.IndexOf('$launchCmd = Get-BridgeProviderLaunchCommand')
        $nonWorkerResetIndex = $script:winsmuxRoleRawContent.IndexOf('$manifestRole -notin @(''Builder'', ''Worker'')')
        $renameIndex = $script:winsmuxRoleRawContent.IndexOf('Invoke-WinsmuxRaw -Arguments @(''select-pane'', ''-t'', $paneId, ''-T'', $newLabel)')
        $manifestUpdateIndex = $script:winsmuxRoleRawContent.IndexOf('Set-PaneControlManifestPaneProperties -ManifestPath $manifestPath')
        $environmentIndex = $script:winsmuxRoleRawContent.IndexOf('$paneEnvironment = Get-WinsmuxPaneEnvironment')
        $environmentClearIndex = $script:winsmuxRoleRawContent.IndexOf('Invoke-WinsmuxRaw -Arguments @(''set-environment'', ''-u'', ''-t'', $sessionName, $name)')
        $respawnIndex = $script:winsmuxRoleRawContent.IndexOf('Invoke-WinsmuxRaw -Arguments @(''respawn-pane'', ''-k'', ''-t'', $paneId, ''-c'', $launchDir)')
        $launchIndex | Should -BeGreaterThan -1
        $nonWorkerResetIndex | Should -BeGreaterThan -1
        $renameIndex | Should -BeGreaterThan -1
        $manifestUpdateIndex | Should -BeGreaterThan -1
        $environmentIndex | Should -BeGreaterThan -1
        $environmentClearIndex | Should -BeGreaterThan -1
        $respawnIndex | Should -BeGreaterThan -1
        $nonWorkerResetIndex | Should -BeLessThan $launchIndex
        $launchIndex | Should -BeLessThan $renameIndex
        $manifestUpdateIndex | Should -BeLessThan $respawnIndex
        $environmentClearIndex | Should -BeLessThan $environmentIndex
        $environmentIndex | Should -BeLessThan $respawnIndex
    }

    It 'TASK781 preserves unmanaged role and restart paths' {
        $result = Invoke-TestManagedPaneLifecycleMutationRefusal -HasManifest $false -Validation $null

        $result | Should -BeNullOrEmpty
    }

    It 'TASK781 blocks managed lifecycle replacement after validating the current runtime identity' {
        $result = Invoke-TestManagedPaneLifecycleMutationRefusal -HasManifest $true -Validation ([pscustomobject]@{
            valid       = $true
            reason_code = ''
            diagnostic  = 'verified'
        })

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'manifest_regeneration_required'
        $result.diagnostic | Should -Match 'replace the registered bootstrap identity'
        $script:winsmuxRoleRawContent | Should -Match '(?s)function Invoke-Role.*?Get-ManagedPaneLifecycleMutationRefusal.*?Stop-WithError.*?select-pane'
        $script:winsmuxRoleRawContent | Should -Match '(?s)function Invoke-RestartPane.*?Get-ManagedPaneLifecycleMutationRefusal.*?Stop-WithError.*?respawn-pane'
    }

    It 'TASK781 refuses every managed name publication after runtime validation' {
        $validation = [pscustomobject]@{ valid = $true; reason_code = ''; diagnostic = 'verified' }
        $context = [pscustomobject]@{ Title = 'W1 Codex Reviewer' }

        $exact = Invoke-TestManagedPaneLifecycleMutationRefusal -HasManifest $true -Validation $validation `
            -OperationName name -RequestedLabel 'W1 Codex Reviewer' -Context $context
        $replacement = Invoke-TestManagedPaneLifecycleMutationRefusal -HasManifest $true -Validation $validation `
            -OperationName name -RequestedLabel 'renamed' -Context $context

        $exact.valid | Should -BeFalse
        $exact.reason_code | Should -Be 'manifest_regeneration_required'
        $replacement.valid | Should -BeFalse
        $replacement.reason_code | Should -Be 'manifest_regeneration_required'
        $script:winsmuxRoleRawContent | Should -Match 'Invoke-Name[\s\S]*?-OperationName name -RequestedLabel \$label'
        $script:winsmuxRoleRawContent | Should -Not -Match '(?s)function Get-ManagedPaneLifecycleMutationRefusal.*?OperationName -eq ''name''.*?return \$null.*?function Invoke-Role'
    }

    It 'TASK781 preserves the central runtime refusal reason for managed lifecycle changes' {
        $result = Invoke-TestManagedPaneLifecycleMutationRefusal -HasManifest $true -Validation ([pscustomobject]@{
            valid       = $false
            reason_code = 'invalid_supervisor_identity'
            diagnostic  = 'supervisor start time mismatch'
        })

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'invalid_supervisor_identity'
        $result.diagnostic | Should -Be 'supervisor start time mismatch'
    }
}

Describe 'winsmux provider-switch command' {
    BeforeAll {
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreRawContent = Get-Content -Path $script:winsmuxCoreRawPath -Raw -Encoding UTF8
        $script:controlPlaneProviderSwitchCommandsContent = Get-Content -Path (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\control-plane-commands.ps1') -Raw -Encoding UTF8
    }

    BeforeEach {
        $script:providerSwitchTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-provider-switch-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:providerSwitchTempRoot -Force | Out-Null
        @'
agent: codex
model: gpt-5.4
model-source: cli-discovery
prompt-transport: argv
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: gpt-5.4
    model-source: cli-discovery
    prompt-transport: argv
'@ | Set-Content -Path (Join-Path $script:providerSwitchTempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:providerSwitchTempRoot '.winsmux') -Force | Out-Null
@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "model_options": [
        {"id": "provider-default", "label": "Provider default", "source": "provider-default", "reasoning_efforts": ["provider-default"]},
        {"id": "gpt-5.3-codex-spark", "label": "GPT-5.3-Codex-Spark", "source": "cli-discovery", "availability": "local-account", "reasoning_efforts": ["low", "medium", "high", "xhigh"]},
        {"id": "gpt-5.4", "label": "GPT-5.4", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "xhigh"]},
        {"id": "gpt-5.6-sol", "label": "GPT-5.6 Sol", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]},
        {"id": "gpt-5.6-terra", "label": "GPT-5.6 Terra", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]},
        {"id": "gpt-5.6-luna", "label": "GPT-5.6 Luna", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]}
      ],
      "model_sources": ["provider-default", "cli-discovery"],
      "reasoning_efforts": ["provider-default", "low", "medium", "high", "xhigh"],
      "local_access_note": "Local Codex CLI catalog and ChatGPT account access.",
      "harness_availability": "official-cli",
      "credential_requirements": "local-cli-owned",
      "execution_backend": "agent-cli",
      "runtime_requirements": "Codex CLI installed in the pane environment.",
      "analysis_posture": "read-write-worker",
      "prompt_transports": ["argv", "file", "stdin"],
      "auth_modes": ["api-key", "codex-chatgpt-local"],
      "local_interactive_oauth_modes": ["codex-chatgpt-local"],
      "supports_parallel_runs": true,
      "supports_interrupt": true,
      "supports_structured_result": true,
      "supports_file_edit": true,
      "supports_subagents": true,
      "supports_verification": true,
      "supports_consultation": false,
      "supports_context_reset": true
    },
    "claude": {
      "adapter": "claude",
      "command": "claude",
      "model_options": [
        {"id": "provider-default", "label": "Provider default", "source": "provider-default", "reasoning_efforts": ["provider-default"]},
        {"id": "sonnet", "label": "Sonnet", "source": "official-doc", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]},
        {"id": "opus", "label": "Opus", "source": "official-doc", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]},
        {"id": "opusplan", "label": "Opus Plan", "source": "official-doc", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]}
      ],
      "model_sources": ["provider-default", "official-doc", "operator-override"],
      "reasoning_efforts": ["provider-default", "low", "medium", "high", "xhigh", "max"],
      "local_access_note": "Local Claude Code account and settings.",
      "harness_availability": "official-cli",
      "credential_requirements": "local-cli-owned",
      "execution_backend": "agent-cli",
      "runtime_requirements": "Claude Code CLI installed in the pane environment.",
      "analysis_posture": "read-write-worker",
      "prompt_transports": ["file"],
      "auth_modes": ["api-key", "claude-pro-max-oauth"],
      "local_interactive_oauth_modes": ["claude-pro-max-oauth"],
      "supports_parallel_runs": false,
      "supports_interrupt": true,
      "supports_structured_result": false,
      "supports_file_edit": true,
      "supports_subagents": false,
      "supports_verification": true,
      "supports_consultation": true,
      "supports_context_reset": false
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:providerSwitchTempRoot '.winsmux\provider-capabilities.json') -Encoding UTF8
    }

    AfterEach {
        if ($script:providerSwitchTempRoot -and (Test-Path $script:providerSwitchTempRoot)) {
            Remove-Item -Path $script:providerSwitchTempRoot -Recurse -Force
        }
    }

    It 'documents provider-switch in usage and writes a provider registry entry' {
        $script:winsmuxCoreRawContent | Should -Match 'provider-switch <slot> \[--agent <name>\] \[--model <name>\] \[--model-source <source>\] \[--reasoning-effort <level>\] \[--prompt-transport <argv\|file\|stdin>\] \[--auth-mode <mode>\] \[--reason <text>\] \[--restart\] \[--clear\] \[--json\]'
        $script:winsmuxCoreRawContent | Should -Match "'provider-switch'\s*\{"

        Push-Location $script:providerSwitchTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent claude --model opus --model-source operator-override --reasoning-effort xhigh --prompt-transport file --auth-mode claude-pro-max-oauth --reason 'operator requested provider switch' --json
        } finally {
            Pop-Location
        }

        $result = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $result.slot_id | Should -Be 'worker-1'
        $result.agent | Should -Be 'claude'
        $result.model | Should -Be 'opus'
        $result.model_source | Should -Be 'operator-override'
        $result.reasoning_effort | Should -Be 'xhigh'
        $result.prompt_transport | Should -Be 'file'
        $result.auth_mode | Should -Be 'claude-pro-max-oauth'
        $result.auth_policy | Should -Be 'local_interactive_only'
        $result.source | Should -Be 'registry'
        $result.capability_adapter | Should -Be 'claude'
        $result.capability_command | Should -Be 'claude'
        $result.local_access_note | Should -Be 'Local Claude Code account and settings.'
        $result.harness_availability | Should -Be 'official-cli'
        $result.credential_requirements | Should -Be 'local-cli-owned'
        $result.execution_backend | Should -Be 'agent-cli'
        $result.runtime_requirements | Should -Be 'Claude Code CLI installed in the pane environment.'
        $result.analysis_posture | Should -Be 'read-write-worker'
        $result.supports_file_edit | Should -Be $true
        $result.supports_subagents | Should -Be $false
        $result.supports_consultation | Should -Be $true
        $result.supports_context_reset | Should -Be $false
        $result.restart_requested | Should -Be $false
        $result.restarted | Should -Be $false

        $registryPath = Join-Path $script:providerSwitchTempRoot '.winsmux\provider-registry.json'
        Test-Path -LiteralPath $registryPath | Should -Be $true
        $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $registry.slots.'worker-1'.agent | Should -Be 'claude'
        $registry.slots.'worker-1'.model | Should -Be 'opus'
        $registry.slots.'worker-1'.model_source | Should -Be 'operator-override'
        $registry.slots.'worker-1'.reasoning_effort | Should -Be 'xhigh'
        $registry.slots.'worker-1'.prompt_transport | Should -Be 'file'
        $registry.slots.'worker-1'.reason | Should -Be 'operator requested provider switch'
    }

    It 'persists runtime role preferences for desktop settings' {
        $script:winsmuxCoreRawContent | Should -Match 'runtime-roles apply --roles-json <json> \[--json\]'
        $script:winsmuxCoreRawContent | Should -Match "'runtime-roles'\s*\{"

        $rolesJson = @(
            [ordered]@{
                role_id          = 'worker'
                provider         = 'codex'
                model            = 'gpt-5.3-codex-spark'
                model_source     = 'cli-discovery'
                reasoning_effort = 'high'
            },
            [ordered]@{
                role_id          = 'operator'
                provider         = 'claude'
                model            = 'provider-default'
                model_source     = 'provider-default'
                reasoning_effort = 'provider-default'
            }
        ) | ConvertTo-Json -Compress -Depth 8

        Push-Location $script:providerSwitchTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath runtime-roles apply --roles-json $rolesJson --json
        } finally {
            Pop-Location
        }

        $result = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $result.roles.worker.agent | Should -Be 'codex'
        $result.roles.worker.model | Should -Be 'gpt-5.3-codex-spark'
        $result.roles.worker.model_source | Should -Be 'cli-discovery'
        $result.roles.worker.reasoning_effort | Should -Be 'high'
        Test-Path -LiteralPath (Join-Path $script:providerSwitchTempRoot '.winsmux\runtime-role-preferences.json') | Should -Be $true
    }

    It 'rejects invalid runtime role max before changing preferences or provider registry' {
        $preferencesPath = Join-Path $script:providerSwitchTempRoot '.winsmux\runtime-role-preferences.json'
        $registryPath = Join-Path $script:providerSwitchTempRoot '.winsmux\provider-registry.json'
        '{"version":1,"updated_at_utc":"2026-07-12T00:00:00Z","roles":{"worker":{"agent":"codex","model":"gpt-5.4","model_source":"cli-discovery","reasoning_effort":"high"}}}' |
            Set-Content -LiteralPath $preferencesPath -Encoding UTF8 -NoNewline
        '{"version":1,"slots":{"worker-1":{"agent":"codex","model":"gpt-5.4","model_source":"cli-discovery","reasoning_effort":"high"}}}' |
            Set-Content -LiteralPath $registryPath -Encoding UTF8 -NoNewline
        $preferencesBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($preferencesPath))
        $registryBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($registryPath))
        $rolesJson = @(
            [ordered]@{
                role_id          = 'worker'
                provider         = 'codex'
                model            = 'gpt-5.6-terra'
                model_source     = 'provider-default'
                reasoning_effort = 'max'
            },
            [ordered]@{
                role_id          = 'operator'
                provider         = 'claude'
                model            = 'provider-default'
                model_source     = 'provider-default'
                reasoning_effort = 'provider-default'
            }
        ) | ConvertTo-Json -Compress -Depth 8

        Push-Location $script:providerSwitchTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath runtime-roles apply --roles-json $rolesJson --json 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $exitCode | Should -Not -Be 0
        [string]::Join("`n", @($output)) | Should -Match "model 'gpt-5.6-terra' does not support reasoning_effort 'max'"
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($preferencesPath)) | Should -BeExactly $preferencesBefore
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($registryPath)) | Should -BeExactly $registryBefore
    }

    It 'rejects provider-switch blocked auth modes before writing the provider registry' {
        Push-Location $script:providerSwitchTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent claude --model opus --prompt-transport file --auth-mode token-broker --json 2>&1
        } finally {
            Pop-Location
        }

        [string]::Join("`n", @($output)) | Should -Match 'must not broker OAuth'
        $registryPath = Join-Path $script:providerSwitchTempRoot '.winsmux\provider-registry.json'
        Test-Path $registryPath | Should -BeFalse
    }

    It 'rejects provider-switch selectors outside provider capabilities before writing the provider registry' {
        Push-Location $script:providerSwitchTempRoot
        try {
            $modelSourceOutput = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --model gpt-5.5 --model-source operator-override --json 2>&1
            $reasoningOutput = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --reasoning-effort max --json 2>&1
        } finally {
            Pop-Location
        }

        [string]::Join("`n", @($modelSourceOutput)) | Should -Match "does not support model_source 'operator-override'"
        [string]::Join("`n", @($reasoningOutput)) | Should -Match "does not support reasoning_effort 'max'"
        $registryPath = Join-Path $script:providerSwitchTempRoot '.winsmux\provider-registry.json'
        Test-Path $registryPath | Should -BeFalse
    }

    It 'accepts configured GPT-5.6 max effort before writing the provider registry' {
        $capabilityPath = Join-Path $script:providerSwitchTempRoot '.winsmux\provider-capabilities.json'
        $capabilities = Get-Content -LiteralPath $capabilityPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $capabilities.providers.codex.reasoning_efforts = @('provider-default', 'low', 'medium', 'high', 'max', 'xhigh')
        $capabilities | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $capabilityPath -Encoding UTF8

        Push-Location $script:providerSwitchTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --model gpt-5.6-terra --model-source cli-discovery --reasoning-effort max --prompt-transport file --auth-mode codex-chatgpt-local --json
        } finally {
            Pop-Location
        }

        $result = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $result.agent | Should -Be 'codex'
        $result.model | Should -Be 'gpt-5.6-terra'
        $result.reasoning_effort | Should -Be 'max'

        $registryPath = Join-Path $script:providerSwitchTempRoot '.winsmux\provider-registry.json'
        $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $registry.slots.'worker-1'.reasoning_effort | Should -Be 'max'
    }

    It 'uses provider-level efforts for unprojected provider-default model selections' {
        $capabilityPath = Join-Path $script:providerSwitchTempRoot '.winsmux\provider-capabilities.json'
        $capabilities = Get-Content -LiteralPath $capabilityPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $capabilities.providers.codex.model_options = @($capabilities.providers.codex.model_options) + [pscustomobject][ordered]@{
            id                = 'custom-operator-model'
            label             = 'Custom operator model'
            source            = 'operator-override'
            reasoning_efforts = @('max')
        }
        $capabilities | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $capabilityPath -Encoding UTF8

        Push-Location $script:providerSwitchTempRoot
        try {
            $codexDefaultOutput = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --model provider-default --model-source provider-default --reasoning-effort xhigh --prompt-transport argv --json
            $unprojectedCustomOutput = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --model custom-operator-model --model-source provider-default --reasoning-effort high --prompt-transport argv --json
            $claudeDefaultOutput = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent claude --model provider-default --model-source provider-default --reasoning-effort max --prompt-transport file --json
        } finally {
            Pop-Location
        }

        $codexDefault = ($codexDefaultOutput | Select-Object -Last 1) | ConvertFrom-Json
        $codexDefault.model | Should -Be 'provider-default'
        $codexDefault.reasoning_effort | Should -Be 'xhigh'

        $unprojectedCustom = ($unprojectedCustomOutput | Select-Object -Last 1) | ConvertFrom-Json
        $unprojectedCustom.model | Should -Be 'custom-operator-model'
        $unprojectedCustom.model_source | Should -Be 'provider-default'
        $unprojectedCustom.reasoning_effort | Should -Be 'high'

        $claudeDefault = ($claudeDefaultOutput | Select-Object -Last 1) | ConvertFrom-Json
        $claudeDefault.model | Should -Be 'provider-default'
        $claudeDefault.reasoning_effort | Should -Be 'max'
    }

    It 'backfills common efforts for legacy capabilities while restricting max to exact GPT-5.6 models' {
        $capabilityPath = Join-Path $script:providerSwitchTempRoot '.winsmux\provider-capabilities.json'
        $capabilities = Get-Content -LiteralPath $capabilityPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($option in @($capabilities.providers.codex.model_options)) {
            if ($option.id -in @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')) {
                $option.PSObject.Properties.Remove('reasoning_efforts')
            }
        }
        $capabilities.providers.codex.model_options = @($capabilities.providers.codex.model_options) + [pscustomobject][ordered]@{
            id = 'legacy-codex'; label = 'Legacy Codex'; source = 'cli-discovery'
        }
        $capabilities.providers.codex.PSObject.Properties.Remove('reasoning_efforts')
        $claudeOpus = @($capabilities.providers.claude.model_options | Where-Object id -eq 'opus')[0]
        $claudeOpus.PSObject.Properties.Remove('reasoning_efforts')
        $capabilities.providers.claude.PSObject.Properties.Remove('reasoning_efforts')
        $capabilities | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $capabilityPath -Encoding UTF8

        Push-Location $script:providerSwitchTempRoot
        try {
            foreach ($model in @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')) {
                $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --model $model --model-source cli-discovery --reasoning-effort max --json
                $LASTEXITCODE | Should -Be 0
                (($output | Select-Object -Last 1) | ConvertFrom-Json).reasoning_effort | Should -Be 'max'
            }

            $legacyHighOutput = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --model legacy-codex --model-source cli-discovery --reasoning-effort high --json 2>&1
            $legacyHighExit = $LASTEXITCODE
            $gpt56XhighOutput = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --model gpt-5.6-terra --model-source cli-discovery --reasoning-effort xhigh --json 2>&1
            $gpt56XhighExit = $LASTEXITCODE
            $legacyProviderDefaultHighOutput = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --model legacy-codex --model-source provider-default --reasoning-effort high --json 2>&1
            $legacyProviderDefaultHighExit = $LASTEXITCODE
            $gpt56ProviderDefaultXhighOutput = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --model gpt-5.6-terra --model-source provider-default --reasoning-effort xhigh --json 2>&1
            $gpt56ProviderDefaultXhighExit = $LASTEXITCODE
            $legacyHighExit | Should -Be 0 -Because ([string]::Join("`n", @($legacyHighOutput)))
            $gpt56XhighExit | Should -Be 0 -Because ([string]::Join("`n", @($gpt56XhighOutput)))
            $legacyProviderDefaultHighExit | Should -Be 0 -Because ([string]::Join("`n", @($legacyProviderDefaultHighOutput)))
            $gpt56ProviderDefaultXhighExit | Should -Be 0 -Because ([string]::Join("`n", @($gpt56ProviderDefaultXhighOutput)))

            $registryPath = Join-Path $script:providerSwitchTempRoot '.winsmux\provider-registry.json'
            foreach ($case in @(
                @{ model = 'legacy-codex'; source = 'cli-discovery' },
                @{ model = 'legacy-codex'; source = 'provider-default' },
                @{ model = 'gpt-5.6-terra'; source = 'provider-default' }
            )) {
                $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($registryPath))
                $failure = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --model $case.model --model-source $case.source --reasoning-effort max --json 2>&1
                $LASTEXITCODE | Should -Be 1
                [string]::Join("`n", @($failure)) | Should -Match "does not support reasoning_effort 'max'"
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($registryPath)) | Should -BeExactly $before
            }

            $capabilities.providers.codex.model_options = @($capabilities.providers.codex.model_options | Where-Object id -ne 'gpt-5.6-terra')
            $capabilities.providers.codex | Add-Member -NotePropertyName reasoning_efforts -NotePropertyValue @('provider-default', 'low', 'medium', 'high', 'xhigh', 'max') -Force
            $capabilities | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $capabilityPath -Encoding UTF8
            $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($registryPath))
            $failure = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --model gpt-5.6-terra --model-source cli-discovery --reasoning-effort max --json 2>&1
            $LASTEXITCODE | Should -Be 1
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($registryPath)) | Should -BeExactly $before

            $luna = @($capabilities.providers.codex.model_options | Where-Object id -eq 'gpt-5.6-luna')[0]
            $luna | Add-Member -NotePropertyName reasoning_efforts -NotePropertyValue @('low', 'medium', 'high', 'xhigh') -Force
            $capabilities | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $capabilityPath -Encoding UTF8
            $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($registryPath))
            $failure = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --model gpt-5.6-luna --model-source cli-discovery --reasoning-effort max --json 2>&1
            $LASTEXITCODE | Should -Be 1
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($registryPath)) | Should -BeExactly $before

            $claudeLegacyMaxOutput = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent claude --model opus --model-source official-doc --reasoning-effort max --prompt-transport file --json 2>&1
            $claudeLegacyMaxExit = $LASTEXITCODE
            $beforeMissing = [Convert]::ToBase64String([IO.File]::ReadAllBytes($registryPath))
            $claudeMissingHighOutput = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent claude --model missing-claude --model-source operator-override --reasoning-effort high --prompt-transport file --json 2>&1
            $claudeMissingHighExit = $LASTEXITCODE
            $missingUnchanged = [Convert]::ToBase64String([IO.File]::ReadAllBytes($registryPath)) -eq $beforeMissing
            $beforeProviderDefault = [Convert]::ToBase64String([IO.File]::ReadAllBytes($registryPath))
            $claudeProviderDefaultHighOutput = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent claude --model opus --model-source provider-default --reasoning-effort high --prompt-transport file --json 2>&1
            $claudeProviderDefaultHighExit = $LASTEXITCODE
            $providerDefaultUnchanged = [Convert]::ToBase64String([IO.File]::ReadAllBytes($registryPath)) -eq $beforeProviderDefault
            $nonCodexLegacyContract = (
                $claudeLegacyMaxExit -eq 0 -and
                $claudeMissingHighExit -eq 1 -and
                $missingUnchanged -and
                [string]::Join("`n", @($claudeMissingHighOutput)) -match "does not support reasoning_effort 'high'" -and
                $claudeProviderDefaultHighExit -eq 1 -and
                $providerDefaultUnchanged -and
                [string]::Join("`n", @($claudeProviderDefaultHighOutput)) -match "does not support reasoning_effort 'high'"
            )
            $nonCodexLegacyContract | Should -BeTrue -Because (
                "matching max exit=$claudeLegacyMaxExit; missing high exit=$claudeMissingHighExit unchanged=$missingUnchanged; provider-default high exit=$claudeProviderDefaultHighExit unchanged=$providerDefaultUnchanged; errors: " +
                [string]::Join("`n", @($claudeLegacyMaxOutput) + @($claudeMissingHighOutput) + @($claudeProviderDefaultHighOutput))
            )
        } finally {
            Pop-Location
        }
    }

    It 'rejects unprojected GPT-5.6 max before provider-switch writes the registry' {
        Remove-Item -LiteralPath (Join-Path $script:providerSwitchTempRoot '.winsmux\provider-capabilities.json') -Force
        $registryPath = Join-Path $script:providerSwitchTempRoot '.winsmux\provider-registry.json'
        $registryBefore = '{"version":1,"slots":{"worker-9":{"agent":"claude","model":"opus","updated_at_utc":"2026-07-12T00:00:00Z"}}}'
        Set-Content -LiteralPath $registryPath -Value $registryBefore -Encoding UTF8 -NoNewline

        Push-Location $script:providerSwitchTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent codex --model gpt-5.6-terra --model-source provider-default --reasoning-effort max --json 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $exitCode | Should -Be 1
        [string]::Join("`n", @($output)) | Should -Match "model 'gpt-5.6-terra' does not support reasoning_effort 'max'"
        (Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8) | Should -Be $registryBefore
    }

    It 'uses the built-in OpenRouter capability without a private capability file entry' {
        Push-Location $script:providerSwitchTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent openrouter --model z-ai/glm-5.2 --model-source provider-api --reasoning-effort provider-default --prompt-transport file --auth-mode api-key-env --json
        } finally {
            Pop-Location
        }

        $result = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $result.slot_id | Should -Be 'worker-1'
        $result.agent | Should -Be 'openrouter'
        $result.model | Should -Be 'z-ai/glm-5.2'
        $result.model_source | Should -Be 'provider-api'
        $result.reasoning_effort | Should -Be 'provider-default'
        $result.capability_adapter | Should -Be 'openai-compatible'
        $result.execution_backend | Should -Be 'openai-compatible-chat-completions'
        $result.api_base_url | Should -Be 'https://openrouter.ai/api/v1'
        $result.api_key_env | Should -Be 'OPENROUTER_API_KEY'
        $result.supports_structured_result | Should -Be $true
        $result.supports_file_edit | Should -Be $false
    }

    It 'allows provider-switch to repair stale provider selector overrides' {
        $registryPath = Join-Path $script:providerSwitchTempRoot '.winsmux\provider-registry.json'
@'
{"version":1,"slots":{"worker-1":{"agent":"codex","model_source":"operator-override","reasoning_effort":"max","updated_at_utc":"2026-05-05T00:00:00Z"}}}
'@ | Set-Content -Path $registryPath -Encoding UTF8

        Push-Location $script:providerSwitchTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --reasoning-effort high --json
        } finally {
            Pop-Location
        }

        $result = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $result.reasoning_effort | Should -Be 'high'
        $result.model_source | Should -Be 'cli-discovery'
        $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $registry.slots.'worker-1'.reasoning_effort | Should -Be 'high'
        $registry.slots.'worker-1'.PSObject.Properties.Name | Should -Not -Contain 'model_source'
    }

    It 'clears provider-switch overrides and reports the configured slot provider' {
        Push-Location $script:providerSwitchTempRoot
        try {
            & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent claude --model opus --prompt-transport file --json | Out-Null
            $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --clear --json
        } finally {
            Pop-Location
        }

        $result = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $result.slot_id | Should -Be 'worker-1'
        $result.agent | Should -Be 'codex'
        $result.model | Should -Be 'gpt-5.4'
        $result.prompt_transport | Should -Be 'argv'
        $result.source | Should -Be 'slot'
        $result.capability_adapter | Should -Be 'codex'
        $result.supports_parallel_runs | Should -Be $true
        $result.supports_verification | Should -Be $true
        $result.supports_consultation | Should -Be $false
        $result.supports_context_reset | Should -Be $true
        $result.clear_requested | Should -Be $true
        $result.cleared | Should -Be $true
        $registry = Get-Content -LiteralPath (Join-Path $script:providerSwitchTempRoot '.winsmux\provider-registry.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $registry.slots.PSObject.Properties.Name | Should -Not -Contain 'worker-1'
    }

    It 'documents provider-switch restart and routes it through the manifest-backed restart helper' {
        $script:controlPlaneProviderSwitchCommandsContent | Should -Match "'--restart'\s*\{"
        $script:controlPlaneProviderSwitchCommandsContent | Should -Match "'--clear'\s*\{"
        $script:controlPlaneProviderSwitchCommandsContent | Should -Match 'Get-PaneControlManifestEntries -ProjectDir \$projectDir'
        $script:controlPlaneProviderSwitchCommandsContent | Should -Match 'Confirm-Target \(\[string\]\$manifestEntry\[0\]\.PaneId\)'
        $script:winsmuxCoreRawContent | Should -Match 'Invoke-RestartPane -PaneId'
        $script:winsmuxCoreRawContent | Should -Match '\$restartReadinessAgent\s*=\s*Get-RestartReadinessAgentName -Plan \$plan'
        $script:winsmuxCoreRawContent | Should -Match 'Test-AgentReadyPrompt -PaneId \$PaneId -Agent \$restartReadinessAgent'
        $script:winsmuxCoreRawContent | Should -Not -Match 'timed out waiting for Codex after restart'
        $script:controlPlaneProviderSwitchCommandsContent | Should -Match 'Remove-BridgeProviderRegistryEntry -RootPath \$projectDir -SlotId \$slotId'
        $script:controlPlaneProviderSwitchCommandsContent | Should -Match 'clear_requested'
        $script:controlPlaneProviderSwitchCommandsContent | Should -Match 'restart_requested'
        $script:controlPlaneProviderSwitchCommandsContent | Should -Match 'restart_pane_id'
    }

    It 'keeps Confirm-Target compatible with whitespace-separated pane lists' {
        $script:winsmuxCoreRawContent | Should -Match "\$lastOutput -split '\\s\+'"
        $script:winsmuxCoreRawContent | Should -Match '\$lastExitCode -eq 0 -or \(\$null -eq \$lastExitCode -and -not \[string\]::IsNullOrWhiteSpace\(\$lastOutput\)\)'
    }

    It 'rejects provider-switch restart when the manifest pane id is stale before writing the registry' {
        $winsmuxBin = Join-Path $script:providerSwitchTempRoot 'bin'
        New-Item -ItemType Directory -Path $winsmuxBin -Force | Out-Null
        @'
@echo off
if "%1"=="list-panes" (
  echo %%live
  exit /b 0
)
exit /b 0
'@ | Set-Content -Path (Join-Path $winsmuxBin 'winsmux.cmd') -Encoding ASCII

        New-Item -ItemType Directory -Path (Join-Path $script:providerSwitchTempRoot '.winsmux') -Force | Out-Null
        $manifestContent = @'
session:
  name: winsmux-orchestra
  project_dir: __PROJECT_DIR__
panes:
  worker-1:
    pane_id: "%stale"
    role: Builder
    launch_dir: __PROJECT_DIR__
'@
        $manifestContent.Replace('__PROJECT_DIR__', $script:providerSwitchTempRoot) |
            Set-Content -Path (Join-Path $script:providerSwitchTempRoot '.winsmux\manifest.yaml') -Encoding UTF8

        $originalPath = $env:PATH
        Push-Location $script:providerSwitchTempRoot
        try {
            $env:PATH = "$winsmuxBin$([System.IO.Path]::PathSeparator)$env:PATH"
            $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent claude --model opus --restart --json 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $env:PATH = $originalPath
            Pop-Location
        }

        $exitCode | Should -Be 1
        ($output | Out-String) | Should -Match 'invalid target: %stale'
        Test-Path -LiteralPath (Join-Path $script:providerSwitchTempRoot '.winsmux\provider-registry.json') | Should -Be $false
    }
}

Describe 'winsmux orchestra-smoke command' {
    BeforeAll {
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreRawContent = Get-Content -Path $script:winsmuxCoreRawPath -Raw -Encoding UTF8
        $script:orchestraSmokePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-smoke.ps1'
        $script:orchestraSmokeContent = Get-Content -Path $script:orchestraSmokePath -Raw -Encoding UTF8
        $script:runtimeManifestPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\manifest.ps1'
        $script:harnessCheckContent = Get-Content -Path (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\harness-check.ps1') -Raw -Encoding UTF8

        function Invoke-TestOrchestraRuntimeValidity {
            param(
                [Parameter(Mandatory = $true)][object[]]$Entries,
                [Parameter(Mandatory = $true)][object[]]$Validations,
                [int]$ExpectedPaneCount = 6
            )

            $runtimeSource = [regex]::Match(
                $script:orchestraSmokeContent,
                '(?s)function Get-OrchestraSmokeRuntimeValidity \{.*?\r?\n\}\r?\n\r?\nfunction ConvertTo-OrchestraSmokeInt'
            ).Value
            if ([string]::IsNullOrWhiteSpace($runtimeSource)) {
                throw 'Failed to extract Get-OrchestraSmokeRuntimeValidity from orchestra-smoke.ps1.'
            }
            $runtimeSource = $runtimeSource -replace '\r?\n\r?\nfunction ConvertTo-OrchestraSmokeInt$', ''

            & {
                param($RuntimeSource, $RuntimeManifestPath, $Entries, $Validations, $ExpectedPaneCount)

                Set-StrictMode -Version Latest
                . $RuntimeManifestPath
                $validationQueue = [System.Collections.Queue]::new()
                foreach ($validation in $Validations) {
                    $validationQueue.Enqueue($validation)
                }

                function Get-PaneControlManifestEntries {
                    param([string]$ProjectDir)
                    return @($Entries)
                }

                function Get-PaneControlValue {
                    param($InputObject, [string]$Name, $Default)
                    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($Name)) {
                        return $InputObject[$Name]
                    }
                    if ($null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties[$Name]) {
                        return $InputObject.$Name
                    }
                    return $Default
                }

                function Test-PaneControlRuntimeContext {
                    param([string]$ProjectDir, $ManifestEntry, [string]$Operation)
                    if ($validationQueue.Count -eq 0) {
                        throw 'Missing synthetic runtime validation result.'
                    }
                    return $validationQueue.Dequeue()
                }

                Invoke-Expression $RuntimeSource
                Get-OrchestraSmokeRuntimeValidity -ProjectDir 'C:\synthetic-winsmux' -ExpectedPaneCount $ExpectedPaneCount
            } $runtimeSource $script:runtimeManifestPath $Entries $Validations $ExpectedPaneCount
        }

        function Invoke-TestHarnessSmokeContractEvaluation {
            param([Parameter(Mandatory = $true)]$SmokeProbe)

            $propertySource = [regex]::Match(
                $script:harnessCheckContent,
                '(?s)function Test-HarnessHasProperty \{.*?\r?\n\}\r?\n\r?\nfunction Test-HarnessSettingsLocalTracked'
            ).Value
            $evaluationSource = [regex]::Match(
                $script:harnessCheckContent,
                '(?s)function Get-HarnessSmokeContractEvaluation \{.*?\r?\n\}\r?\n\r?\n\$results ='
            ).Value
            if ([string]::IsNullOrWhiteSpace($propertySource) -or [string]::IsNullOrWhiteSpace($evaluationSource)) {
                throw 'Failed to extract harness smoke contract helpers.'
            }
            $propertySource = $propertySource -replace '\r?\n\r?\nfunction Test-HarnessSettingsLocalTracked$', ''
            $evaluationSource = $evaluationSource -replace '\r?\n\r?\n\$results =$', ''

            & {
                param($PropertySource, $EvaluationSource, $SmokeProbe)
                Set-StrictMode -Version Latest
                Invoke-Expression $PropertySource
                Invoke-Expression $EvaluationSource
                Get-HarnessSmokeContractEvaluation -SmokeProbe $SmokeProbe
            } $propertySource $evaluationSource $SmokeProbe
        }

        function Invoke-TestOrchestraOperatorContract {
            param(
                [Parameter(Mandatory = $true)][bool]$SmokeOk,
                [Parameter(Mandatory = $true)][bool]$SessionReady,
                [Parameter(Mandatory = $true)][bool]$UiAttachLaunched,
                [Parameter(Mandatory = $true)][bool]$UiAttached,
                [Parameter(Mandatory = $true)][string]$UiAttachStatus,
                [Parameter(Mandatory = $true)][bool]$ExternalOperatorMode,
                [Parameter(Mandatory = $true)][int]$PaneCount,
                [Parameter(Mandatory = $true)][int]$ExpectedPaneCount,
                [Parameter(Mandatory = $true)][string[]]$SmokeErrors
            )

            $contractSource = [regex]::Match(
                $script:orchestraSmokeContent,
                '(?s)function Get-OrchestraOperatorContract \{.*?\r?\n\}\r?\n\r?\nfunction Get-OrchestraSmokeProbeState'
            ).Value

            if ([string]::IsNullOrWhiteSpace($contractSource)) {
                throw 'Failed to extract Get-OrchestraOperatorContract from orchestra-smoke.ps1.'
            }

            $contractSource = $contractSource -replace '\r?\n\r?\nfunction Get-OrchestraSmokeProbeState$', ''

            & {
                Set-StrictMode -Version Latest
                Invoke-Expression $contractSource
                Get-OrchestraOperatorContract `
                    -SmokeOk $SmokeOk `
                    -SessionReady $SessionReady `
                    -UiAttachLaunched $UiAttachLaunched `
                    -UiAttached $UiAttached `
                    -UiAttachStatus $UiAttachStatus `
                    -ExternalOperatorMode $ExternalOperatorMode `
                    -PaneCount $PaneCount `
                    -ExpectedPaneCount $ExpectedPaneCount `
                    -SmokeErrors $SmokeErrors
            }
        }

        function Invoke-TestOrchestraAttachResolution {
            param(
                [Parameter(Mandatory = $true)]$ProbeState,
                [AllowNull()]$AttachState,
                [Parameter(Mandatory = $true)][bool]$ClientProbeOk,
                [AllowNull()]$ClientSnapshot,
                [bool]$LiveVisibleAttach = $false
            )

            $resolverSource = [regex]::Match(
                $script:orchestraSmokeContent,
                '(?s)function Resolve-OrchestraSmokeAttachState \{.*?\r?\n\}\r?\n\r?\nif \(\[string\]::IsNullOrWhiteSpace\(\$ProjectDir\)\)'
            ).Value

            if ([string]::IsNullOrWhiteSpace($resolverSource)) {
                throw 'Failed to extract Resolve-OrchestraSmokeAttachState from orchestra-smoke.ps1.'
            }

            $resolverSource = $resolverSource -replace '\r?\n\r?\nif \(\[string\]::IsNullOrWhiteSpace\(\$ProjectDir\)\)$', ''

            & {
                param($ProbeState, $AttachState, $ClientProbeOk, $ClientSnapshot, $LiveVisibleAttach)

                Set-StrictMode -Version Latest

                function Test-OrchestraLiveVisibleAttachState {
                    param($State, [string]$SessionName, [string]$WinsmuxBin)
                    return $LiveVisibleAttach
                }

                function Get-OrchestraAttachTraceEntries {
                    param($State)
                    if ($null -eq $State -or $null -eq $State.PSObject.Properties['attach_adapter_trace']) {
                        return @()
                    }

                    return @($State.attach_adapter_trace)
                }

                Invoke-Expression $resolverSource
                Resolve-OrchestraSmokeAttachState -ProbeState $ProbeState -AttachState $AttachState -ClientProbeOk $ClientProbeOk -ClientSnapshot $ClientSnapshot -WinsmuxBin 'C:\winsmux\winsmux.exe'
            } $ProbeState $AttachState $ClientProbeOk $ClientSnapshot $LiveVisibleAttach
        }

        function Invoke-TestOrchestraProcessContract {
            param(
                [AllowNull()]$Manifest,
                [AllowNull()]$AttachState,
                [Parameter(Mandatory = $true)][int]$PaneCount,
                [Parameter(Mandatory = $true)][int]$ExpectedPaneCount,
                [Parameter(Mandatory = $true)][int]$AttachedClientCount,
                [AllowNull()]$ProcessSnapshot,
                [bool]$CountMissingProcessReferences = $true,
                [string]$ProjectDir = 'C:\repo'
            )

            $contractSource = [regex]::Match(
                $script:orchestraSmokeContent,
                '(?s)function ConvertTo-OrchestraSmokeInt \{.*?\r?\n\}\r?\n\r?\nfunction Get-OrchestraAttachedClientSnapshot'
            ).Value

            if ([string]::IsNullOrWhiteSpace($contractSource)) {
                throw 'Failed to extract process contract helpers from orchestra-smoke.ps1.'
            }

            $contractSource = $contractSource -replace '\r?\n\r?\nfunction Get-OrchestraAttachedClientSnapshot$', ''

            & {
                param($Manifest, $AttachState, $PaneCount, $ExpectedPaneCount, $AttachedClientCount, $ProcessSnapshot, $CountMissingProcessReferences)

                Set-StrictMode -Version Latest
                Invoke-Expression $contractSource
                Get-OrchestraSmokeProcessContract `
                    -Manifest $Manifest `
                    -AttachState $AttachState `
                    -PaneCount $PaneCount `
                    -ExpectedPaneCount $ExpectedPaneCount `
                    -AttachedClientCount $AttachedClientCount `
                    -ProcessSnapshot $ProcessSnapshot `
                    -CountMissingProcessReferences $CountMissingProcessReferences `
                    -ProjectDir $ProjectDir
            } $Manifest $AttachState $PaneCount $ExpectedPaneCount $AttachedClientCount $ProcessSnapshot $CountMissingProcessReferences $ProjectDir
        }
    }

    It 'documents orchestra-smoke and dispatches it through the dedicated startup smoke script' {
        $script:winsmuxCoreRawContent | Should -Match 'orchestra-smoke \[--json\] \[--auto-start\] \[--project-dir <path>\]\s+Report structured startup contract \+ UI attach state \(use --auto-start to start if needed\)'
        $script:winsmuxCoreRawContent | Should -Match 'orchestra-attach \[--json\] \[--project-dir <path>\]\s+Launch a visible attach window for an existing orchestra session'
        $script:winsmuxCoreRawContent | Should -Match 'dispatch-task <text>\s+Route and send task text to a managed pane using manifest-aware role selection'
        $script:winsmuxCoreRawContent | Should -Match "'orchestra-smoke'\s*\{"
        $script:winsmuxCoreRawContent | Should -Match "'orchestra-attach'\s*\{"
        $script:winsmuxCoreRawContent | Should -Match "'dispatch-task'\s*\{"
        $script:winsmuxCoreRawContent | Should -Match 'orchestra-smoke\.ps1'
        $script:winsmuxCoreRawContent | Should -Match 'orchestra-attach\.ps1'
        $script:winsmuxCoreRawContent | Should -Match '--project-dir <path>'
        $script:winsmuxCoreRawContent | Should -Match '--auto-start'
        $script:winsmuxCoreRawContent | Should -Not -Match '--session-name <name>'
    }

    It 'reports a structured operator startup contract alongside session-ready and UI attach state' {
        $script:orchestraSmokeContent | Should -Match 'session_ready'
        $script:orchestraSmokeContent | Should -Match 'ui_attach_launched'
        $script:orchestraSmokeContent | Should -Match 'ui_attached'
        $script:orchestraSmokeContent | Should -Match 'attach_request_id'
        $script:orchestraSmokeContent | Should -Match 'attached_client_snapshot'
        $script:orchestraSmokeContent | Should -Match 'attached_client_registry_count'
        $script:orchestraSmokeContent | Should -Match 'attach_adapter_trace'
        $script:orchestraSmokeContent | Should -Match 'ui_host_kind'
        $script:orchestraSmokeContent | Should -Match 'runtime_attached_client_count'
        $script:orchestraSmokeContent | Should -Match 'external_operator_mode'
        $script:orchestraSmokeContent | Should -Match 'expected_pane_count'
        $script:orchestraSmokeContent | Should -Match 'winsmux_bin'
        $script:orchestraSmokeContent | Should -Match 'pane_probe_ok'
        $script:orchestraSmokeContent | Should -Match 'Get-OrchestraSmokeLayoutSettings'
        $script:orchestraSmokeContent | Should -Match 'function Get-OrchestraOperatorContract'
        $script:orchestraSmokeContent | Should -Match 'contract_version'
        $script:orchestraSmokeContent | Should -Match 'operator_state'
        $script:orchestraSmokeContent | Should -Match 'ready-with-ui-warning'
        $script:orchestraSmokeContent | Should -Match 'can_dispatch'
        $script:orchestraSmokeContent | Should -Match 'requires_startup'
        $script:orchestraSmokeContent | Should -Match 'worker_isolation'
        $script:orchestraSmokeContent | Should -Match 'worker isolation drift'
        $script:orchestraSmokeContent | Should -Match 'process_contract'
        $script:orchestraSmokeContent | Should -Match 'worker_shell_count'
        $script:orchestraSmokeContent | Should -Match 'background_helper_count'
        $script:orchestraSmokeContent | Should -Match 'attach_host_count'
        $script:orchestraSmokeContent | Should -Match 'warm_process_count'
        $script:orchestraSmokeContent | Should -Match 'stale_process_count'
    }

    It 'reports process contract counts for worker shells background helpers attach hosts and warm processes' {
        $snapshot = [pscustomobject]@{
            Processes = @(
                [pscustomobject]@{ ProcessId = 101; Name = 'pwsh.exe'; CommandLine = 'pwsh operator-poll.ps1 C:\repo\.winsmux\manifest.yaml' },
                [pscustomobject]@{ ProcessId = 202; Name = 'pwsh.exe'; CommandLine = 'pwsh agent-watchdog.ps1 C:\repo\.winsmux\manifest.yaml' },
                [pscustomobject]@{ ProcessId = 303; Name = 'pwsh.exe'; CommandLine = 'pwsh server-watchdog.ps1 C:\repo\.winsmux\manifest.yaml' },
                [pscustomobject]@{ ProcessId = 404; Name = 'pwsh.exe'; CommandLine = 'pwsh -NoLogo -NoExit -File orchestra-attach-entry.ps1' },
                [pscustomobject]@{ ProcessId = 505; Name = 'winsmux.exe'; CommandLine = 'winsmux server __warm__' }
            )
            ById = @{
                101 = [pscustomobject]@{ ProcessId = 101; Name = 'pwsh.exe'; CommandLine = 'pwsh operator-poll.ps1 C:\repo\.winsmux\manifest.yaml' }
                202 = [pscustomobject]@{ ProcessId = 202; Name = 'pwsh.exe'; CommandLine = 'pwsh agent-watchdog.ps1 C:\repo\.winsmux\manifest.yaml' }
                303 = [pscustomobject]@{ ProcessId = 303; Name = 'pwsh.exe'; CommandLine = 'pwsh server-watchdog.ps1 C:\repo\.winsmux\manifest.yaml' }
                404 = [pscustomobject]@{ ProcessId = 404; Name = 'pwsh.exe'; CommandLine = 'pwsh -NoLogo -NoExit -File orchestra-attach-entry.ps1' }
                505 = [pscustomobject]@{ ProcessId = 505; Name = 'winsmux.exe'; CommandLine = 'winsmux server __warm__' }
            }
            SupportsCommandLine = $true
        }

        $contract = Invoke-TestOrchestraProcessContract `
            -Manifest ([pscustomobject]@{
                session = [pscustomobject]@{
                    operator_poll_pid = 101
                    watchdog_pid = 202
                    server_watchdog_pid = 303
                }
            }) `
            -AttachState ([pscustomobject]@{ attach_process_id = 404 }) `
            -PaneCount 6 `
            -ExpectedPaneCount 6 `
            -AttachedClientCount 1 `
            -ProcessSnapshot $snapshot

        $contract.ok | Should -Be $true
        $contract.worker_shell_count | Should -Be 6
        $contract.background_helper_count | Should -Be 3
        $contract.attach_host_count | Should -Be 1
        $contract.warm_process_count | Should -Be 1
        $contract.stale_process_count | Should -Be 0
    }

    It 'reports parentless winsmux-generated pane shells as stale processes' {
        $parent = [pscustomobject]@{ ProcessId = 900; ParentProcessId = 0; Name = 'WindowsTerminal.exe'; CommandLine = 'wt' }
        $staleShell = [pscustomobject]@{
            ProcessId       = 801
            ParentProcessId = 700
            Name            = 'pwsh.exe'
            CommandLine     = 'pwsh -NoLogo -NoProfile -NoExit -Command "Set-Location C:\repo\.worktrees\builder-1; if (-not (Test-Path variable:Global:__psmux_cwd_hook)) { $Global:__psmux_cwd_hook = $true }"'
        }
        $unscopedShell = [pscustomobject]@{
            ProcessId       = 803
            ParentProcessId = 701
            Name            = 'pwsh.exe'
            CommandLine     = 'pwsh -NoLogo -NoProfile -NoExit -Command "$Global:__psmux_cwd_hook = $true"'
        }
        $vscodeShell = [pscustomobject]@{
            ProcessId       = 802
            ParentProcessId = 0
            Name            = 'pwsh.exe'
            CommandLine     = 'pwsh -NoExit -Command ". C:\Users\test\AppData\Local\Programs\Microsoft VS Code\shellIntegration.ps1"'
        }
        $activeShell = [pscustomobject]@{
            ProcessId       = 901
            ParentProcessId = 900
            Name            = 'pwsh.exe'
            CommandLine     = 'pwsh -NoLogo -NoProfile -NoExit -Command "$Global:__psmux_cwd_hook = $true"'
        }
        $snapshot = [pscustomobject]@{
            Processes = @($parent, $staleShell, $vscodeShell, $unscopedShell, $activeShell)
            ById = @{
                801 = $staleShell
                802 = $vscodeShell
                803 = $unscopedShell
                900 = $parent
                901 = $activeShell
            }
            SupportsCommandLine = $true
        }

        $contract = Invoke-TestOrchestraProcessContract `
            -Manifest $null `
            -AttachState $null `
            -PaneCount 6 `
            -ExpectedPaneCount 6 `
            -AttachedClientCount 0 `
            -ProcessSnapshot $snapshot

        $contract.ok | Should -Be $false
        $contract.stale_process_count | Should -Be 1
        $contract.stale_processes[0].pid | Should -Be 801
        $contract.stale_processes[0].label | Should -Be 'worker_shell'
        $contract.stale_processes[0].reason | Should -Be 'parent_missing_winsmux_shell'
        $contract.warnings | Should -Contain 'stale managed process count 1 exceeds budget 0.'
    }

    It 'treats the orchestra supervisor as one background helper' {
        $snapshot = [pscustomobject]@{
            Processes = @(
                [pscustomobject]@{ ProcessId = 707; Name = 'pwsh.exe'; CommandLine = 'pwsh -NoProfile -File orchestra-supervisor.ps1 -ManifestPath C:\repo\.winsmux\manifest.yaml' }
            )
            ById = @{
                707 = [pscustomobject]@{ ProcessId = 707; Name = 'pwsh.exe'; CommandLine = 'pwsh -NoProfile -File orchestra-supervisor.ps1 -ManifestPath C:\repo\.winsmux\manifest.yaml' }
            }
            SupportsCommandLine = $true
        }

        $contract = Invoke-TestOrchestraProcessContract `
            -Manifest ([pscustomobject]@{
                session = [pscustomobject]@{
                    supervisor_pid = 707
                }
            }) `
            -AttachState $null `
            -PaneCount 6 `
            -ExpectedPaneCount 6 `
            -AttachedClientCount 0 `
            -ProcessSnapshot $snapshot

        $contract.ok | Should -Be $true
        $contract.background_helper_count | Should -Be 1
        $contract.budgets.max_background_helpers | Should -Be 1
        $contract.background_helpers[0].label | Should -Be 'supervisor_pid'
    }

    It 'blocks smoke when managed process budget is exceeded' {
        $snapshot = [pscustomobject]@{
            Processes = @()
            ById = @{}
            SupportsCommandLine = $true
        }

        $contract = Invoke-TestOrchestraProcessContract `
            -Manifest ([pscustomobject]@{
                session = [pscustomobject]@{
                    operator_poll_pid = 101
                }
            }) `
            -AttachState $null `
            -PaneCount 7 `
            -ExpectedPaneCount 6 `
            -AttachedClientCount 0 `
            -ProcessSnapshot $snapshot

        $contract.ok | Should -Be $false
        $contract.stale_process_count | Should -Be 1
        $contract.warnings | Should -Contain 'worker shell count 7 exceeds budget 6.'
        $contract.warnings | Should -Contain 'stale managed process count 1 exceeds budget 0.'
        $script:orchestraSmokeContent | Should -Match 'process contract: \$warning'
    }

    It 'keeps missing manifest process references out of pressure counts when no session is present' {
        $snapshot = [pscustomobject]@{
            Processes = @()
            ById = @{}
            SupportsCommandLine = $true
        }

        $contract = Invoke-TestOrchestraProcessContract `
            -Manifest ([pscustomobject]@{
                session = [pscustomobject]@{
                    supervisor_pid = 101
                }
            }) `
            -AttachState ([pscustomobject]@{ attach_process_id = 404 }) `
            -PaneCount 6 `
            -ExpectedPaneCount 6 `
            -AttachedClientCount 0 `
            -ProcessSnapshot $snapshot `
            -CountMissingProcessReferences $false

        $contract.ok | Should -Be $true
        $contract.stale_process_count | Should -Be 0
        $contract.stale_processes | Should -Be @()
    }

    It 'keeps ready-with-ui-warning fail-closed only for external operator mode' {
        $externalWarning = Invoke-TestOrchestraOperatorContract `
            -SmokeOk $true `
            -SessionReady $true `
            -UiAttachLaunched $true `
            -UiAttached $false `
            -UiAttachStatus 'attach_pending' `
            -ExternalOperatorMode $true `
            -PaneCount 6 `
            -ExpectedPaneCount 6 `
            -SmokeErrors @('attach_pending')

        $internalWarning = Invoke-TestOrchestraOperatorContract `
            -SmokeOk $true `
            -SessionReady $true `
            -UiAttachLaunched $true `
            -UiAttached $false `
            -UiAttachStatus 'attach_pending' `
            -ExternalOperatorMode $false `
            -PaneCount 6 `
            -ExpectedPaneCount 6 `
            -SmokeErrors @('attach_pending')

        $externalWarning.operator_state | Should -Be 'ready-with-ui-warning'
        $externalWarning.can_dispatch | Should -Be $false
        $externalWarning.operator_message | Should -Match 'external operator dispatch stays blocked'
        $externalWarning.next_action | Should -Match 'attached-client confirmation'

        $internalWarning.operator_state | Should -Be 'ready-with-ui-warning'
        $internalWarning.can_dispatch | Should -Be $true
        $internalWarning.operator_message | Should -Match 'internal operator mode may continue dispatch'
        $internalWarning.next_action | Should -Be 'Dispatch work or continue operator flow.'
    }

    It 'keeps host-launch-failed-but-session-healthy in warning state instead of treating startup as blocked' {
        $attachFailed = Invoke-TestOrchestraOperatorContract `
            -SmokeOk $true `
            -SessionReady $true `
            -UiAttachLaunched $false `
            -UiAttached $false `
            -UiAttachStatus 'attach_failed' `
            -ExternalOperatorMode $true `
            -PaneCount 6 `
            -ExpectedPaneCount 6 `
            -SmokeErrors @('attach_failed')

        $attachFailed.operator_state | Should -Be 'ready-with-ui-warning'
        $attachFailed.can_dispatch | Should -Be $false
        $attachFailed.requires_startup | Should -Be $false
        $attachFailed.operator_message | Should -Match 'session-ready'
        $attachFailed.next_action | Should -Match 'attached-client confirmation'
    }

    It 'keeps worker isolation drift inside the blocked operator_state contract' {
        $workerDrift = Invoke-TestOrchestraOperatorContract `
            -SmokeOk $false `
            -SessionReady $true `
            -UiAttachLaunched $true `
            -UiAttached $true `
            -UiAttachStatus 'attach_confirmed' `
            -ExternalOperatorMode $true `
            -PaneCount 6 `
            -ExpectedPaneCount 6 `
            -SmokeErrors @('worker isolation drift: worker-1: branch is main; expected worktree-worker-1')

        $workerDrift.operator_state | Should -Be 'blocked'
        $workerDrift.can_dispatch | Should -Be $false
        $workerDrift.requires_startup | Should -Be $false
        $workerDrift.smoke_errors[0] | Should -Match 'worker isolation drift'
        $workerDrift.operator_message | Should -Match 'startup is already session-ready'
        $workerDrift.next_action | Should -Match 'Operator shell'
    }

    It 'fails closed to runtime attach state instead of trusting manifest ui_attached alone' {
        $script:orchestraSmokeContent | Should -Match '\$uiAttached = \$false'
        $script:orchestraSmokeContent | Should -Match 'if \(\$null -eq \$attachState\)'
        $script:orchestraSmokeContent | Should -Match 'Visible attach state is missing; runtime attach confirmation is unavailable\.'
    }

    It 'rejects attached-client registry matches when post-draw render evidence is absent' {
        $resolution = Invoke-TestOrchestraAttachResolution `
            -ProbeState ([pscustomobject]@{
                SessionName      = 'winsmux-orchestra'
                UiAttachLaunched = $true
                UiAttachStatus   = 'attach_confirmed'
                UiAttachReason   = ''
                UiAttachSource   = 'handshake'
                UiHostKind       = ''
                AttachRequestId  = ''
            }) `
            -AttachState ([pscustomobject]@{
                attach_status           = 'attach_confirmed'
                attach_request_id       = 'req-456'
                attached_client_count   = 1
                attached_client_snapshot = @('/dev/pts/7: winsmux-orchestra: node')
                ui_host_kind            = 'powershell-window'
                error                   = ''
            }) `
            -ClientProbeOk $true `
            -ClientSnapshot ([pscustomobject]@{
                Clients = @('/dev/pts/7: winsmux-orchestra: node')
            }) `
            -LiveVisibleAttach $false

        $resolution.UiAttached | Should -Be $false
        $resolution.UiAttachStatus | Should -Be 'attach_unconfirmed'
        $resolution.UiAttachSource | Should -Be 'none'
        $resolution.AttachedClientRegistryCount | Should -Be 1
        $resolution.AttachRequestId | Should -Be 'req-456'
        $resolution.AttachedClientSnapshot | Should -Be @('/dev/pts/7: winsmux-orchestra: node')
        $resolution.UiHostKind | Should -Be 'powershell-window'
    }

    It 'falls back to probe-state attach adapter trace when runtime attach state is missing' {
        $resolution = Invoke-TestOrchestraAttachResolution `
            -ProbeState ([pscustomobject]@{
                SessionName       = 'winsmux-orchestra'
                UiAttachLaunched  = $false
                UiAttachStatus    = 'attach_failed'
                UiAttachReason    = 'manifest only'
                UiAttachSource    = 'handshake'
                UiHostKind        = 'windows-terminal'
                AttachRequestId   = 'req-manifest'
                AttachAdapterTrace = @(
                    [pscustomobject]@{
                        sequence      = 1
                        host_kind     = 'windows-terminal'
                        launch_result = 'launch_failed'
                    }
                )
            }) `
            -AttachState $null `
            -ClientProbeOk $true `
            -ClientSnapshot ([pscustomobject]@{
                Clients = @('/dev/pts/7: winsmux-orchestra: node')
            })

        $resolution.AttachAdapterTrace.Count | Should -Be 1
        $resolution.AttachAdapterTrace[0].host_kind | Should -Be 'windows-terminal'
        $resolution.AttachAdapterTrace[0].launch_result | Should -Be 'launch_failed'
    }

    It 'allows empty ui_attach_status when building the operator contract' {
        $script:orchestraSmokeContent | Should -Match '\[AllowEmptyString\(\)\]\[string\]\$UiAttachStatus'
    }

    It 'allows an empty smoke_errors collection when building the operator contract' {
        $script:orchestraSmokeContent | Should -Match '\[AllowEmptyCollection\(\)\]\[string\[\]\]\$SmokeErrors'
    }

    It 'defaults orchestra-smoke to observation-only and only auto-starts when requested' {
        $script:orchestraSmokeContent | Should -Match '\[switch\]\$AutoStart'
        $script:orchestraSmokeContent | Should -Match 'elseif \(\$AutoStart\)'
        $script:orchestraSmokeContent | Should -Match 'Skipped orchestra-start; run orchestra-start\.ps1 when operator_contract\.requires_startup is true\.'
    }

    It 'keeps the structured operator contract independent from MCP or plugin chatter inputs' {
        $script:orchestraSmokeContent | Should -Not -Match 'called MCP'
        $script:orchestraSmokeContent | Should -Not -Match 'plugin initialization'
        $script:orchestraSmokeContent | Should -Not -Match 'channel notifications'
        $script:orchestraSmokeContent | Should -Match 'Get-OrchestraOperatorContract'
    }

    It 'waits briefly for manifest and pane convergence after auto-start before finalizing smoke' {
        $script:orchestraSmokeContent | Should -Match 'function Get-OrchestraSmokeProbeState'
        $script:orchestraSmokeContent | Should -Match 'function Wait-OrchestraSmokeConvergence'
        $script:orchestraSmokeContent | Should -Match 'Wait-OrchestraSmokeConvergence -ProjectDir \$ProjectDir -SessionName \$SessionName'
        $script:orchestraSmokeContent | Should -Match 'PaneCount -lt \$ExpectedPaneCount'
        $script:orchestraSmokeContent | Should -Match 'PaneProbeOk'
        $script:orchestraSmokeContent | Should -Match 'ManifestReadable'
        $script:orchestraSmokeContent | Should -Match 'manifest read failed during startup convergence'
    }

    It 'TASK781 makes smoke readiness depend on structured runtime identity validity' {
        $script:orchestraSmokeContent | Should -Match 'function Get-OrchestraSmokeRuntimeValidity'
        $script:orchestraSmokeContent | Should -Match 'Test-PaneControlRuntimeContext'
        $script:orchestraSmokeContent | Should -Match '\$sessionAlreadyHealthy = .*RuntimeValid'
        $script:orchestraSmokeContent | Should -Match "runtime identity invalid"
        $script:orchestraSmokeContent | Should -Match 'runtime_valid\s+=\s+\$runtimeValid'
        $script:orchestraSmokeContent | Should -Match 'runtime_identity\s+=\s+\$runtimeIdentity'
    }

    It 'TASK781 verifies all six expected runtime identities before smoke can pass' {
        $entries = @(
            1..6 | ForEach-Object {
                [pscustomobject]@{
                    SlotId        = "worker-$_"
                    PaneId        = "%$_"
                    WorkerBackend = 'codex'
                    Role          = 'Worker'
                    Title         = "worker-$_"
                    Status        = 'ready'
                }
            }
        )
        $validations = @(
            1..6 | ForEach-Object {
                [pscustomobject]@{ valid = $true; reason_code = ''; diagnostic = 'verified' }
            }
        )

        $result = Invoke-TestOrchestraRuntimeValidity -Entries $entries -Validations $validations

        $result.valid | Should -BeTrue
        $result.expected | Should -Be 6
        $result.verified | Should -Be 6
        $result.entries.Count | Should -Be 6
    }

    It 'TASK781 makes one invalid supervisor identity fail the six-pane smoke contract' {
        $entries = @(
            1..6 | ForEach-Object {
                [pscustomobject]@{
                    SlotId        = "worker-$_"
                    PaneId        = "%$_"
                    WorkerBackend = 'codex'
                    Role          = 'Worker'
                    Title         = "worker-$_"
                    Status        = 'ready'
                }
            }
        )
        $validations = @(
            1..5 | ForEach-Object {
                [pscustomobject]@{ valid = $true; reason_code = ''; diagnostic = 'verified' }
            }
        ) + @(
            [pscustomobject]@{
                valid       = $false
                reason_code = 'invalid_supervisor_identity'
                diagnostic  = 'supervisor start time mismatch'
            }
        )

        $result = Invoke-TestOrchestraRuntimeValidity -Entries $entries -Validations $validations

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'invalid_supervisor_identity'
        $result.verified | Should -Be 5
    }

    It 'TASK781 rejects each parseable but invalid harness smoke result' {
        $validContract = [pscustomobject]@{
            operator_state  = 'ready'
            can_dispatch    = $true
            requires_startup = $false
        }
        $invalidCases = @(
            [pscustomobject]@{
                Name  = 'nonzero exit'
                Probe = [pscustomobject]@{
                    exit_code = 1
                    parsed    = [pscustomobject]@{ smoke_ok = $true; runtime_valid = $true; runtime_identity = @{}; operator_contract = $validContract }
                    error     = ''
                }
                Message = 'exited with code 1'
            }
            [pscustomobject]@{
                Name  = 'smoke false'
                Probe = [pscustomobject]@{
                    exit_code = 0
                    parsed    = [pscustomobject]@{ smoke_ok = $false; runtime_valid = $true; runtime_identity = @{}; operator_contract = $validContract }
                    error     = ''
                }
                Message = 'smoke_ok=false'
            }
            [pscustomobject]@{
                Name  = 'missing runtime identity'
                Probe = [pscustomobject]@{
                    exit_code = 0
                    parsed    = [pscustomobject]@{ smoke_ok = $true; runtime_valid = $true; operator_contract = $validContract }
                    error     = ''
                }
                Message = 'runtime identity registry'
            }
            [pscustomobject]@{
                Name  = 'runtime invalid'
                Probe = [pscustomobject]@{
                    exit_code = 0
                    parsed    = [pscustomobject]@{ smoke_ok = $true; runtime_valid = $false; runtime_identity = @{}; operator_contract = $validContract }
                    error     = ''
                }
                Message = 'runtime identity registry'
            }
        )

        foreach ($case in $invalidCases) {
            $result = Invoke-TestHarnessSmokeContractEvaluation -SmokeProbe $case.Probe
            $result.passed | Should -BeFalse -Because $case.Name
            $result.message | Should -Match ([regex]::Escape($case.Message)) -Because $case.Name
        }
    }

    It 'TASK781 accepts a complete valid harness smoke result' {
        $probe = [pscustomobject]@{
            exit_code = 0
            error     = ''
            parsed    = [pscustomobject]@{
                smoke_ok              = $true
                runtime_valid         = $true
                runtime_identity      = [pscustomobject]@{ verified = 6; expected = 6 }
                external_operator_mode = $false
                session_ready         = $true
                ui_attached           = $false
                operator_contract     = [pscustomobject]@{
                    operator_state   = 'ready-with-ui-warning'
                    can_dispatch     = $true
                    requires_startup = $false
                }
            }
        }

        $result = Invoke-TestHarnessSmokeContractEvaluation -SmokeProbe $probe

        $result.passed | Should -BeTrue
    }

    It 'TASK781 accepts only known typed safe pre-start blocked harness reasons' {
        foreach ($reasonCode in @(
            'manifest_regeneration_required'
            'invalid_supervisor_identity'
            'caller_identity_mismatch'
            'runtime_target_mismatch'
        )) {
            $probe = [pscustomobject]@{
                exit_code = 1
                error     = ''
                parsed    = [pscustomobject]@{
                    smoke_ok               = $false
                    runtime_valid          = $false
                    runtime_identity       = [pscustomobject]@{
                        valid       = $false
                        reason_code = $reasonCode
                        diagnostic  = 'regenerate the orchestra session'
                    }
                    external_operator_mode = $true
                    session_ready          = $false
                    ui_attached            = $false
                    operator_contract      = [pscustomobject]@{
                        operator_state   = 'blocked'
                        can_dispatch     = $false
                        requires_startup = $true
                    }
                }
            }

            $result = Invoke-TestHarnessSmokeContractEvaluation -SmokeProbe $probe

            $result.passed | Should -BeTrue -Because $reasonCode
            $result.message | Should -Match 'safe pre-start blocked state' -Because $reasonCode
        }
    }

    It 'TASK781 rejects inconsistent pre-start blocked harness states' {
        $cases = @(
            [pscustomobject]@{ Name = 'dispatch enabled'; State = 'blocked'; CanDispatch = $true; RequiresStartup = $true; Reason = 'manifest_regeneration_required' }
            [pscustomobject]@{ Name = 'ready claim'; State = 'ready'; CanDispatch = $false; RequiresStartup = $true; Reason = 'manifest_regeneration_required' }
            [pscustomobject]@{ Name = 'startup not required'; State = 'blocked'; CanDispatch = $false; RequiresStartup = $false; Reason = 'manifest_regeneration_required' }
            [pscustomobject]@{ Name = 'missing typed reason'; State = 'blocked'; CanDispatch = $false; RequiresStartup = $true; Reason = '' }
            [pscustomobject]@{ Name = 'unknown typed reason'; State = 'blocked'; CanDispatch = $false; RequiresStartup = $true; Reason = 'unexpected_runtime_reason' }
        )

        foreach ($case in $cases) {
            $probe = [pscustomobject]@{
                exit_code = 1
                error     = ''
                parsed    = [pscustomobject]@{
                    smoke_ok         = $false
                    runtime_valid    = $false
                    runtime_identity = [pscustomobject]@{
                        valid       = $false
                        reason_code = $case.Reason
                    }
                    external_operator_mode = $true
                    session_ready   = $false
                    ui_attached     = $false
                    operator_contract = [pscustomobject]@{
                        operator_state   = $case.State
                        can_dispatch     = $case.CanDispatch
                        requires_startup = $case.RequiresStartup
                    }
                }
            }

            $result = Invoke-TestHarnessSmokeContractEvaluation -SmokeProbe $probe

            $result.passed | Should -BeFalse -Because $case.Name
            $result.message | Should -Match 'not a safe pre-start blocked state' -Because $case.Name
        }
    }

    It 'TASK781 makes harness and doctor fail when smoke or runtime identity is invalid' {
        $harnessContent = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\harness-check.ps1') -Raw -Encoding UTF8
        $doctorContent = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\doctor.ps1') -Raw -Encoding UTF8

        $harnessContent | Should -Match 'function Get-HarnessSmokeContractEvaluation'
        $harnessContent | Should -Match '\$exitCode -ne 0'
        $harnessContent | Should -Match 'smoke_ok=false'
        $harnessContent | Should -Match 'runtime_valid'
        $harnessContent | Should -Match 'safe pre-start blocked state'
        $doctorContent | Should -Match '\$resultOk = \$exitCode -eq 0 -and \$smokeOk -and \$runtimeValid'
        $doctorContent | Should -Match '\$status = if \(\$null -ne \$smoke\.Data\) \{ ''fail'' \} else \{ ''warn'' \}'
    }

    It 'refreshes the attached client snapshot after startup convergence before resolving attach state' {
        $script:orchestraSmokeContent | Should -Match 'function Get-OrchestraSmokeClientProbe'
        $script:orchestraSmokeContent | Should -Match '(?s)Wait-OrchestraSmokeConvergence -ProjectDir \$ProjectDir -SessionName \$SessionName.*?\$clientSnapshot = Get-OrchestraSmokeClientProbe -WinsmuxBin \$winsmuxBin -SessionName \$SessionName.*?Resolve-OrchestraSmokeAttachState'
    }
}
