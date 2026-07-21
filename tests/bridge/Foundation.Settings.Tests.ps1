$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'Get-BridgeSettings' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\settings.ps1')
    }

    BeforeEach {
        $script:settingsTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-settings-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:settingsTempRoot -Force | Out-Null
        Push-Location $script:settingsTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:settingsTempRoot -and (Test-Path $script:settingsTempRoot)) {
            Remove-Item -Path $script:settingsTempRoot -Recurse -Force
        }
    }

    It 'ignores arbitrary output when the global option command exits nonzero' {
        Mock Get-WinsmuxBin { return 'winsmux-test-double' }
        Mock Invoke-WinsmuxBridgeCommand {
            $global:LASTEXITCODE = 5
            return 'Access is denied.'
        }

        $settings = Get-BridgeSettings

        $settings.prompt_transport | Should -Be 'argv'
        $settings.execution_profile | Should -Be 'local-windows'
    }

    It 'returns built-in defaults when no global or project settings exist' {
        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings

        $settings.agent | Should -Be 'codex'
        $settings.model | Should -Be ''
        $settings.config_version | Should -Be 1
        $settings.prompt_transport | Should -Be 'argv'
        $settings.external_operator | Should -Be $true
        $settings.legacy_role_layout | Should -Be $false
        $settings.operators | Should -Be 0
        $settings.worker_count | Should -Be 6
        $settings.worker_backend | Should -Be 'local'
        $settings.execution_profile | Should -Be 'local-windows'
        $settings.agent_slots.Count | Should -Be 6
        $settings.agent_slots[0].slot_id | Should -Be 'worker-1'
        $settings.agent_slots[0].runtime_role | Should -Be 'worker'
        $settings.agent_slots[0].agent | Should -Be 'codex'
        $settings.agent_slots[0].model | Should -Be 'provider-default'
        $settings.agent_slots[0].model_source | Should -Be 'provider-default'
        $settings.agent_slots[0].worker_backend | Should -Be 'codex'
        $settings.agent_slots[0].execution_profile | Should -Be 'local-windows'
        $settings.agent_slots[0].worker_role | Should -Be 'reviewer'
        $settings.agent_slots[0].fallback_model | Should -Be 'gpt-5.3-codex-spark'
        $settings.agent_slots[0].pane_title | Should -Be 'W1 Codex Reviewer'
        $settings.agent_slots[1].worker_backend | Should -Be 'local'
        $settings.agent_slots[1].execution_profile | Should -Be 'local-windows'
        $settings.builders | Should -Be 0
        $settings.researchers | Should -Be 0
        $settings.reviewers | Should -Be 0
        $settings.terminal | Should -Be 'background'
        $settings.vault_keys | Should -Be @('GH_TOKEN')
    }

    It 'applies global overrides and lets project settings take precedence per key' {
@'
agent: claude
reviewers: 3
external-operator: false
legacy-role-layout: true
vault-keys:
  - GH_TOKEN
  - OPENAI_API_KEY
terminal: tab
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption {
            param($Name, $Default)

            switch ($Name) {
                '@bridge-agent' { 'gemini' }
                '@bridge-model' { 'gpt-5.5-mini' }
                '@bridge-external-operator' { 'on' }
                '@bridge-worker-count' { '9' }
                '@bridge-builders' { '7' }
                '@bridge-researchers' { '2' }
                '@bridge-reviewers' { '5' }
                '@bridge-vault-keys' { 'GH_TOKEN,CLAUDE_CODE_OAUTH_TOKEN' }
                '@bridge-terminal' { 'window' }
                default { $null }
            }
        }

        $settings = Get-BridgeSettings

        $settings.agent | Should -Be 'claude'
        $settings.model | Should -Be 'gpt-5.5-mini'
        $settings.external_operator | Should -Be $false
        $settings.legacy_role_layout | Should -Be $true
        $settings.worker_count | Should -Be 9
        $settings.builders | Should -Be 7
        $settings.researchers | Should -Be 2
        $settings.reviewers | Should -Be 3
        $settings.terminal | Should -Be 'tab'
        $settings.vault_keys | Should -Be @('GH_TOKEN', 'OPENAI_API_KEY')
    }

    It 'parses agent slot arrays and treats them as the source of truth for managed slot count' {
@'
agent: codex
model: gpt-5.4
external-operator: true
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: gpt-5.4
    worktree-mode: managed
  - slot-id: worker-2
    runtime-role: worker
    agent: claude
    model: sonnet
    worktree-mode: managed
  - slot-id: worker-3
    runtime-role: worker
    agent: gemini
    model: gemini-2.5-pro
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings

        $settings.worker_count | Should -Be 3
        $settings.agent_slots.Count | Should -Be 3
        $settings.agent_slots[0].slot_id | Should -Be 'worker-1'
        $settings.agent_slots[1].agent | Should -Be 'claude'
        $settings.agent_slots[2].model | Should -Be 'gemini-2.5-pro'
    }

    It 'propagates top-level worker backend into generated managed slots' {
@'
agent: codex
model: provider-default
worker-backend: Codex
worker_count: 2
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings

        $settings.worker_backend | Should -Be 'codex'
        $settings.worker_count | Should -Be 2
        $settings.agent_slots.Count | Should -Be 2
        $settings.agent_slots[0].worker_backend | Should -Be 'codex'
        $settings.agent_slots[1].worker_backend | Should -Be 'codex'
    }

    It 'keeps execution profile separate from worker backend and execution backend' {
@'
agent: codex
model: provider-default
worker-backend: local
execution-profile: isolated-enterprise
worker_count: 2
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: codex
    execution-profile: local-windows
    worker-role: reviewer
    agent: codex
    model: provider-default
    worktree-mode: managed
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: antigravity
    execution-profile: isolated-enterprise
    worker-role: impl
    agent: codex
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings

        $settings.execution_profile | Should -Be 'isolated-enterprise'
        $settings.agent_slots[0].execution_profile | Should -Be 'local-windows'
        $settings.agent_slots[1].worker_backend | Should -Be 'antigravity'
        $settings.agent_slots[1].execution_profile | Should -Be 'isolated-enterprise'

        $impl = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-2' -Settings $settings
        $impl.WorkerBackend | Should -Be 'antigravity'
        $impl.ExecutionProfile | Should -Be 'isolated-enterprise'
        $impl.ExecutionBackend | Should -Be ''
    }

    It 'fails closed when execution profile is unsupported' {
@'
execution-profile: container-mandatory
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        { Get-BridgeSettings } | Should -Throw '*Invalid execution_profile configuration*'
    }

    It 'fails closed when global execution profile is unsupported' {
        Mock Get-WinsmuxOption {
            param($Name, $Default)

            switch ($Name) {
                '@bridge-execution-profile' { 'container-mandatory' }
                default { $null }
            }
        }

        { Get-BridgeSettings } | Should -Throw "*Invalid execution_profile configuration: unsupported value 'container-mandatory'.*"
    }

    It 'parses WorkerBackend metadata for six-slot worker configs without runtime dispatch' {
@'
agent: codex
model: provider-default
worker-backend: LOCAL
external-operator: true
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: Codex
    worker-role: reviewer
    agent: codex
    model: gpt-5.5
    fallback-model: gpt-5.4
    pane-title: W1 Codex Reviewer
    worktree-mode: managed
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: ANTIGRAVITY
    worker-role: impl
    agent: codex
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings

        $settings.worker_backend | Should -Be 'local'
        $settings.worker_count | Should -Be 2
        $settings.agent_slots[0].worker_backend | Should -Be 'codex'
        $settings.agent_slots[0].worker_role | Should -Be 'reviewer'
        $settings.agent_slots[0].fallback_model | Should -Be 'gpt-5.4'
        $settings.agent_slots[0].pane_title | Should -Be 'W1 Codex Reviewer'
        $settings.agent_slots[1].worker_backend | Should -Be 'antigravity'
        $settings.agent_slots[1].worker_role | Should -Be 'impl'

        $reviewer = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings
        $reviewer.WorkerBackend | Should -Be 'codex'
        $reviewer.WorkerRole | Should -Be 'reviewer'
        $reviewer.FallbackModel | Should -Be 'gpt-5.4'

        $impl = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-2' -Settings $settings
        $impl.WorkerBackend | Should -Be 'antigravity'
        $impl.WorkerRole | Should -Be 'impl'
    }

    It 'parses api_llm worker backend metadata without backend fallback' {
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
    auth-mode: api-key-env
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        $settings.agent_slots[0].worker_backend | Should -Be 'api_llm'
        $settings.agent_slots[0].agent | Should -Be 'openrouter'
        $settings.agent_slots[0].model | Should -Be 'z-ai/glm-5.2'

        $impl = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings
        $impl.WorkerBackend | Should -Be 'api_llm'
        $impl.Agent | Should -Be 'openrouter'
        $impl.Model | Should -Be 'z-ai/glm-5.2'
        $impl.AuthMode | Should -Be 'api-key-env'
    }

    It 'parses antigravity worker backend metadata without backend fallback' {
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
    auth-mode: antigravity-official-cli
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        $settings.agent_slots[0].worker_backend | Should -Be 'antigravity'
        $settings.agent_slots[0].agent | Should -Be 'antigravity'
        $settings.agent_slots[0].model | Should -Be 'gemini-3.5-flash'

        $impl = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings
        $impl.WorkerBackend | Should -Be 'antigravity'
        $impl.Agent | Should -Be 'antigravity'
        $impl.Model | Should -Be 'gemini-3.5-flash'
        $impl.AuthMode | Should -Be 'antigravity-official-cli'
    }


    It 'parses per-role agent and model overrides and falls back to global settings' {
        @'
agent: codex
model: gpt-5.4
roles:
  builder:
    agent: codex
    model: gpt-5.4-codex
  researcher:
    agent: claude
    model: sonnet
  reviewer:
    agent: codex
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings

        $settings.roles.builder.agent | Should -Be 'codex'
        $settings.roles.builder.model | Should -Be 'gpt-5.4-codex'
        $settings.roles.researcher.agent | Should -Be 'claude'
        $settings.roles.reviewer.agent | Should -Be 'codex'

        $builderConfig = Get-RoleAgentConfig -Role 'Builder' -Settings $settings
        $builderConfig.Agent | Should -Be 'codex'
        $builderConfig.Model | Should -Be 'gpt-5.4-codex'

        $researcherConfig = Get-RoleAgentConfig -Role 'Researcher' -Settings $settings
        $researcherConfig.Agent | Should -Be 'claude'
        $researcherConfig.Model | Should -Be 'sonnet'

        $reviewerConfig = Get-RoleAgentConfig -Role 'Reviewer' -Settings $settings
        $reviewerConfig.Agent | Should -Be 'codex'
        $reviewerConfig.Model | Should -Be 'gpt-5.4'

        $operatorConfig = Get-RoleAgentConfig -Role 'Operator' -Settings $settings
        $operatorConfig.Agent | Should -Be 'codex'
        $operatorConfig.Model | Should -Be 'gpt-5.4'
    }

    It 'rejects retired reasoning efforts from top-level, role, and slot settings' {
        foreach ($case in @(
            @{
                Name    = 'top-level'
                Content = @'
agent: codex
reasoning-effort: none
'@
                Pattern = 'Invalid reasoning_effort configuration'
            },
            @{
                Name    = 'role'
                Content = @'
agent: codex
roles:
  worker:
    reasoning-effort: minimal
'@
                Pattern = 'Invalid roles configuration'
            },
            @{
                Name    = 'slot'
                Content = @'
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    reasoning-effort: none
'@
                Pattern = 'Invalid agent_slots configuration'
            }
        )) {
            Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Value $case.Content -Encoding UTF8
            Mock Get-WinsmuxOption { param($Name, $Default) return $null }

            { Get-BridgeSettings -RootPath $script:settingsTempRoot } | Should -Throw "*$($case.Pattern)*"
        }
    }

    It 'uses the generated common contract binding for provider selector vocabularies' {
        $script:BridgeCommonContractPackageVersion | Should -Be '0.36.28'
        Get-BridgeCommonContractVocabularyValues -Name 'modelSources' | Should -Be @('provider-default', 'cli-discovery', 'provider-api', 'official-doc', 'operator-override')
        Get-BridgeCommonContractVocabularyValues -Name 'reasoningEfforts' | Should -Be @('provider-default', 'low', 'medium', 'high', 'max', 'xhigh')
        Get-BridgeCommonContractVocabularyValues -Name 'promptTransports' | Should -Be @('argv', 'file', 'stdin')

        Test-BridgeReasoningEffortValue -Value 'MAX' | Should -Be $true
        Get-BridgeCommonContractSupportedValuesText -Name 'reasoningEfforts' | Should -Be 'provider-default, low, medium, high, max, xhigh'

        $runtimePreferences = Write-BridgeRuntimeRolePreferences -RootPath $script:settingsTempRoot -Roles @(
            [ordered]@{
                role_id         = 'worker'
                provider        = 'claude'
                model           = 'opus'
                modelSource     = 'official-doc'
                reasoningEffort = 'MAX'
                promptTransport = 'STDIN'
            }
        )
        $runtimePreferences.roles.worker.model_source | Should -Be 'official-doc'
        $runtimePreferences.roles.worker.reasoning_effort | Should -Be 'max'
        $runtimePreferences.roles.worker.prompt_transport | Should -Be 'stdin'
        {
            Write-BridgeRuntimeRolePreferences -RootPath $script:settingsTempRoot -Roles @(
                [ordered]@{
                    role_id         = 'worker'
                    promptTransport = 'socket'
                }
            )
        } | Should -Throw '*runtime role preference prompt_transport*'

        $registryEntry = Write-BridgeProviderRegistryEntry `
            -RootPath $script:settingsTempRoot `
            -SlotId 'worker-1' `
            -Agent 'claude' `
            -ModelSource 'official-doc' `
            -ReasoningEffort 'max' `
            -PromptTransport 'stdin'

        $registryEntry.model_source | Should -Be 'official-doc'
        $registryEntry.reasoning_effort | Should -Be 'max'
        $registryEntry.prompt_transport | Should -Be 'stdin'
    }

    It 'overlays ignored runtime role preferences on project role defaults' {
@'
agent: codex
model: gpt-5.4
roles:
  worker:
    agent: codex
    model: gpt-5.4
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }
        $settings = Get-BridgeSettings -RootPath $script:settingsTempRoot
        $roles = @(
            [ordered]@{
                role_id          = 'worker'
                provider         = 'claude'
                model            = 'opus'
                model_source     = 'operator-override'
                reasoning_effort = 'xhigh'
            },
            [ordered]@{
                role_id          = 'reviewer'
                provider         = 'codex'
                model            = 'gpt-5.3-codex-spark'
                model_source     = 'cli-discovery'
                reasoning_effort = 'high'
            }
        )

        $result = Write-BridgeRuntimeRolePreferences -RootPath $script:settingsTempRoot -Roles $roles
        $result.roles.worker.agent | Should -Be 'claude'

        $workerConfig = Get-RoleAgentConfig -Role 'Worker' -Settings $settings -RootPath $script:settingsTempRoot
        $workerConfig.Agent | Should -Be 'claude'
        $workerConfig.Model | Should -Be 'opus'
        $workerConfig.ModelSource | Should -Be 'operator-override'
        $workerConfig.ReasoningEffort | Should -Be 'xhigh'

        $slotConfig = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings -RootPath $script:settingsTempRoot
        $slotConfig.Agent | Should -Be 'claude'
        $slotConfig.Model | Should -Be 'opus'
    }

    It 'keeps the configured provider when runtime preferences use provider-default' {
@'
agent: codex
model: gpt-5.4
roles:
  worker:
    agent: codex
    model: gpt-5.4
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }
        $settings = Get-BridgeSettings -RootPath $script:settingsTempRoot
        $roles = @(
            [ordered]@{
                role_id          = 'worker'
                provider         = 'provider-default'
                model            = 'provider-default'
                model_source     = 'provider-default'
                reasoning_effort = 'provider-default'
            }
        )

        $result = Write-BridgeRuntimeRolePreferences -RootPath $script:settingsTempRoot -Roles $roles
        $result.roles.worker.Contains('agent') | Should -Be $false

        $slotConfig = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings -RootPath $script:settingsTempRoot
        $slotConfig.Agent | Should -Be 'codex'
        $slotConfig.Model | Should -Be 'provider-default'

        $command = Get-BridgeProviderLaunchCommand `
            -ProviderId $slotConfig.Agent `
            -Model $slotConfig.Model `
            -ModelSource $slotConfig.ModelSource `
            -ReasoningEffort $slotConfig.ReasoningEffort `
            -ProjectDir 'C:\Project Root' `
            -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
            -RootPath $script:settingsTempRoot

        $command | Should -Match '^codex '
        $command | Should -Not -Match 'provider-default'
    }

    It 'parses per-role and slot-level prompt transport overrides with the same precedence as agent/model' {
@'
agent: codex
model: gpt-5.4
prompt-transport: argv
roles:
  worker:
    agent: codex
    model: gpt-5.4
    prompt-transport: file
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: claude
    model: sonnet
    prompt-transport: argv
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        $settings.prompt_transport | Should -Be 'argv'
        $settings.roles.worker.prompt_transport | Should -Be 'file'
        $settings.agent_slots[0].prompt_transport | Should -Be 'argv'

        $workerRoleConfig = Get-RoleAgentConfig -Role 'Worker' -Settings $settings
        $workerRoleConfig.PromptTransport | Should -Be 'file'

        $workerOneConfig = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings
        $workerOneConfig.PromptTransport | Should -Be 'argv'
        $workerOneConfig.Source | Should -Be 'slot'

        $workerTwoConfig = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-2' -Settings $settings
        $workerTwoConfig.PromptTransport | Should -Be 'file'
        $workerTwoConfig.Source | Should -Be 'role'
    }

    It 'lets project prompt_transport override the global winsmux option' {
@'
prompt-transport: file
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption {
            param($Name, $Default)

            switch ($Name) {
                '@bridge-prompt-transport' { 'argv' }
                default { $null }
            }
        }

        $settings = Get-BridgeSettings
        $settings.prompt_transport | Should -Be 'file'
    }

    It 'reads config_version metadata and reports it as current' {
@'
config-version: 1
agent: codex
model: gpt-5.4
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        $metadata = Get-BridgeSettingsMetadata -Settings $settings

        $settings.config_version | Should -Be 1
        $metadata.ConfigVersion | Should -Be 1
        $metadata.MigrationStatus | Should -Be 'current'
        $metadata.SlotCount | Should -BeGreaterThan 0
    }

    It 'accepts stdin prompt_transport from project settings' {
@'
prompt-transport: stdin
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings

        $settings.prompt_transport | Should -Be 'stdin'
    }

    It 'rejects unsupported workspace lifecycle presets from project settings' {
@'
workspace-lifecycle-preset: custom-script
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        { Get-BridgeSettings } |
            Should -Throw "Invalid workspace_lifecycle_preset configuration: unsupported value 'custom-script'."
    }

    It 'fails closed when prompt_transport is unsupported' {
@'
prompt-transport: socket
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        { Get-BridgeSettings } | Should -Throw '*prompt_transport*'
    }

    It 'ignores global prompt_transport probe errors when no winsmux server is running yet' {
        Mock Get-WinsmuxOption {
            param($Name, $Default)

            switch ($Name) {
                '@bridge-prompt-transport' { "winsmux: no server running on session 'default'" }
                default { $null }
            }
        }

        $settings = Get-BridgeSettings

        $settings.prompt_transport | Should -Be 'argv'
    }

    It 'rejects retired operator role keys from project settings' {
        $retiredExternalKey = 'external-' + 'comm' + 'ander'
        $settingsPath = Join-Path $script:settingsTempRoot '.winsmux.yaml'
@"
${retiredExternalKey}: false
"@ | Set-Content -Path $settingsPath -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        { Get-BridgeSettings } | Should -Throw '*Retired runtime role setting*external*'
    }

    It 'rejects retired operator role options from global settings' {
        $retiredOption = '@bridge-external-' + 'comm' + 'ander'
        Mock Get-WinsmuxOption {
            param($Name, $Default)

            if ($Name -eq $retiredOption) {
                return 'false'
            }

            return $null
        }

        { Get-BridgeSettings } | Should -Throw '*Retired runtime role option*'
    }

    It 'ignores server-not-running probe text during raw global settings normalization' {
        Mock Get-WinsmuxOption {
            param($Name, $Default)

            switch ($Name) {
                '@bridge-prompt-transport' { "winsmux: no server running on session 'default'" }
                default { $null }
            }
        }

        $settings = Read-BridgeGlobalSettings

        $settings.Contains('prompt_transport') | Should -BeFalse
    }

    It 'fails closed when config_version is unsupported' {
@'
config-version: 2
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        { Get-BridgeSettings } | Should -Throw '*config_version*'
    }

    It 'prefers slot-level agent and model overrides when a matching slot id is provided' {
@'
agent: codex
model: gpt-5.4
roles:
  worker:
    agent: codex
    model: gpt-5.4
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: claude
    model: sonnet
  - slot-id: worker-2
    runtime-role: worker
    agent: gemini
    model: gemini-2.5-pro
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings

        $workerOneConfig = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings
        $workerOneConfig.Agent | Should -Be 'claude'
        $workerOneConfig.Model | Should -Be 'sonnet'
        $workerOneConfig.Source | Should -Be 'slot'

        $workerThreeConfig = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-3' -Settings $settings
        $workerThreeConfig.Agent | Should -Be 'codex'
        $workerThreeConfig.Model | Should -Be 'gpt-5.4'
        $workerThreeConfig.Source | Should -Be 'role'
    }

    It 'lets the provider registry override a slot without mutating project settings' {
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
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        $registryEntry = Write-BridgeProviderRegistryEntry -RootPath $script:settingsTempRoot -SlotId 'worker-1' -Agent 'claude' -Model 'opus' -PromptTransport 'file' -Reason 'operator requested provider hot-swap'
        $registryEntry.agent | Should -Be 'claude'
        $registryEntry.model | Should -Be 'opus'
        $registryEntry.prompt_transport | Should -Be 'file'

        $registryPath = Get-BridgeProviderRegistryPath -RootPath $script:settingsTempRoot
        Test-Path -LiteralPath $registryPath | Should -Be $true
        $registryContent = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8
        $registryContent | Should -Match '"worker-1"'
        $registryContent | Should -Match '"reason":\s*"operator requested provider hot-swap"'

        $workerOneConfig = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings -RootPath $script:settingsTempRoot
        $workerOneConfig.Agent | Should -Be 'claude'
        $workerOneConfig.Model | Should -Be 'opus'
        $workerOneConfig.PromptTransport | Should -Be 'file'
        $workerOneConfig.Source | Should -Be 'registry'

        $settings.agent_slots[0].agent | Should -Be 'codex'
        $settings.agent_slots[0].model | Should -Be 'gpt-5.4'
        $settings.agent_slots[0].prompt_transport | Should -Be 'argv'
    }

    It 'rejects provider registry entries with invalid prompt transport values' {
        {
            Write-BridgeProviderRegistryEntry -RootPath $script:settingsTempRoot -SlotId 'worker-1' -Agent 'claude' -PromptTransport 'socket'
        } | Should -Throw '*prompt_transport*'
    }

    It 'removes a provider registry override and falls back to configured slot settings' {
@'
agent: codex
model: gpt-5.4
prompt-transport: argv
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: gpt-5.4
    prompt-transport: argv
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        Write-BridgeProviderRegistryEntry -RootPath $script:settingsTempRoot -SlotId 'worker-1' -Agent 'claude' -Model 'opus' -PromptTransport 'file' | Out-Null
        $before = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings -RootPath $script:settingsTempRoot
        $before.Source | Should -Be 'registry'

        $removeResult = Remove-BridgeProviderRegistryEntry -RootPath $script:settingsTempRoot -SlotId 'worker-1'
        $removeResult.Removed | Should -Be $true

        $after = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings -RootPath $script:settingsTempRoot
        $after.Agent | Should -Be 'codex'
        $after.Model | Should -Be 'gpt-5.4'
        $after.PromptTransport | Should -Be 'argv'
        $after.Source | Should -Be 'slot'
        $registryAfterRemove = Read-BridgeProviderRegistry -RootPath $script:settingsTempRoot
        $registryAfterRemove.slots.Count | Should -Be 0
    }

    It 'reads provider capability registry entries' {
        $registryPath = Get-BridgeProviderCapabilityRegistryPath -RootPath $script:settingsTempRoot
        $registryDir = Split-Path -Parent $registryPath
        New-Item -ItemType Directory -Path $registryDir -Force | Out-Null

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
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8

        $registry = Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot
        $registry.providers.codex.adapter | Should -Be 'codex'
        $registry.providers.codex.prompt_transports | Should -Be @('argv', 'file', 'stdin')
        $registry.providers.codex.model_options[1].source | Should -Be 'cli-discovery'
        $registry.providers.codex.model_sources | Should -Be @('provider-default', 'cli-discovery')
        $registry.providers.codex.reasoning_efforts | Should -Be @('provider-default', 'low', 'medium', 'high', 'xhigh')
        $registry.providers.codex.local_access_note | Should -Be 'Local Codex CLI catalog and ChatGPT account access.'
        $registry.providers.codex.harness_availability | Should -Be 'official-cli'
        $registry.providers.codex.credential_requirements | Should -Be 'local-cli-owned'
        $registry.providers.codex.execution_backend | Should -Be 'agent-cli'
        $registry.providers.codex.runtime_requirements | Should -Be 'Codex CLI installed in the pane environment.'
        $registry.providers.codex.analysis_posture | Should -Be 'read-write-worker'
        $registry.providers.codex.auth_modes | Should -Be @('api-key', 'codex-chatgpt-local')
        $registry.providers.codex.local_interactive_oauth_modes | Should -Be @('codex-chatgpt-local')
        $registry.providers.codex.supports_file_edit | Should -Be $true
        $registry.providers.codex.supports_context_reset | Should -Be $true

        $capability = Get-BridgeProviderCapability -RootPath $script:settingsTempRoot -ProviderId 'CODEX'
        $capability.command | Should -Be 'codex'
    }

    It 'projects provider capability fields onto resolved slot configs' {
        $registryPath = Get-BridgeProviderCapabilityRegistryPath -RootPath $script:settingsTempRoot
        $registryDir = Split-Path -Parent $registryPath
        New-Item -ItemType Directory -Path $registryDir -Force | Out-Null

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
        {"id": "gpt-5.4", "label": "GPT-5.4", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "xhigh"]}
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
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8

@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: gpt-5.4
    model-source: cli-discovery
    reasoning-effort: high
    prompt-transport: argv
    auth-mode: codex-chatgpt-local
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        $config = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings -RootPath $script:settingsTempRoot

        $config.CapabilityAdapter | Should -Be 'codex'
        $config.CapabilityCommand | Should -Be 'codex'
        $config.ModelSource | Should -Be 'cli-discovery'
        $config.ReasoningEffort | Should -Be 'high'
        $config.ModelOptions[1].source | Should -Be 'cli-discovery'
        $config.ModelOptions[2].reasoning_efforts | Should -Be @('low', 'medium', 'high', 'xhigh')
        $config.ModelSources | Should -Be @('provider-default', 'cli-discovery')
        $config.ReasoningEfforts | Should -Be @('provider-default', 'low', 'medium', 'high', 'xhigh')
        $config.LocalAccessNote | Should -Be 'Local Codex CLI catalog and ChatGPT account access.'
        $config.HarnessAvailability | Should -Be 'official-cli'
        $config.CredentialRequirements | Should -Be 'local-cli-owned'
        $config.ExecutionBackend | Should -Be 'agent-cli'
        $config.RuntimeRequirements | Should -Be 'Codex CLI installed in the pane environment.'
        $config.AnalysisPosture | Should -Be 'read-write-worker'
        $config.AuthMode | Should -Be 'codex-chatgpt-local'
        $config.AuthPolicy | Should -Be 'local_interactive_only'
        $config.SupportsParallelRuns | Should -Be $true
        $config.SupportsInterrupt | Should -Be $true
        $config.SupportsInterruptDeclared | Should -Be $true
        $config.SupportsStructuredResult | Should -Be $true
        $config.SupportsFileEdit | Should -Be $true
        $config.SupportsSubagents | Should -Be $true
        $config.SupportsVerification | Should -Be $true
        $config.SupportsConsultation | Should -Be $false
        $config.SupportsContextReset | Should -Be $true
        $config.SupportsContextResetDeclared | Should -Be $true
    }

    It 'validates max reasoning effort against the specific model before launcher command construction' {
        $registryPath = Get-BridgeProviderCapabilityRegistryPath -RootPath $script:settingsTempRoot
        $registryDir = Split-Path -Parent $registryPath
        New-Item -ItemType Directory -Path $registryDir -Force | Out-Null

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "model_options": [
        {"id": "provider-default", "label": "Provider default", "source": "provider-default", "reasoning_efforts": ["provider-default"]},
        {"id": "gpt-5.4", "label": "GPT-5.4", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "xhigh"]},
        {"id": "gpt-5.6-sol", "label": "GPT-5.6 Sol", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]},
        {"id": "gpt-5.6-terra", "label": "GPT-5.6 Terra", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]},
        {"id": "gpt-5.6-luna", "label": "GPT-5.6 Luna", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]},
        {"id": "legacy-codex-model", "label": "Legacy Codex model", "source": "cli-discovery"},
        {"id": "custom-operator-model", "label": "Custom operator model", "source": "operator-override", "reasoning_efforts": ["max"]}
      ],
      "model_sources": ["provider-default", "cli-discovery", "operator-override"],
      "reasoning_efforts": ["provider-default", "low", "medium", "high", "max", "xhigh"],
      "prompt_transports": ["argv", "file"]
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8

        {
            Get-BridgeProviderLaunchCommand `
                -ProviderId 'codex' `
                -Model 'provider-default' `
                -ModelSource 'provider-default' `
                -ReasoningEffort 'max' `
                -ProjectDir 'C:\Project Root' `
                -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
                -RootPath $script:settingsTempRoot
        } | Should -Throw "*model 'provider-default' does not support reasoning_effort 'max'*"

        {
            Get-BridgeProviderLaunchCommand `
                -ProviderId 'codex' `
                -Model 'custom-operator-model' `
                -ModelSource 'operator-override' `
                -ReasoningEffort 'max' `
                -ProjectDir 'C:\Project Root' `
                -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
                -RootPath $script:settingsTempRoot
        } | Should -Throw "*model 'custom-operator-model' does not support reasoning_effort 'max'*"

        foreach ($effort in @('low', 'medium', 'high', 'xhigh')) {
            {
                Get-BridgeProviderLaunchCommand `
                    -ProviderId 'codex' `
                    -Model 'legacy-codex-model' `
                    -ModelSource 'cli-discovery' `
                    -ReasoningEffort $effort `
                    -ProjectDir 'C:\Project Root' `
                    -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
                    -RootPath $script:settingsTempRoot
            } | Should -Not -Throw
        }

        {
            Get-BridgeProviderLaunchCommand `
                -ProviderId 'codex' `
                -Model 'legacy-codex-model' `
                -ModelSource 'cli-discovery' `
                -ReasoningEffort 'max' `
                -ProjectDir 'C:\Project Root' `
                -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
                -RootPath $script:settingsTempRoot
        } | Should -Throw "*model 'legacy-codex-model' does not support reasoning_effort 'max'*"

@'
agent: codex
model: gpt-5.4
model-source: cli-discovery
reasoning-effort: high
prompt-transport: argv
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }
        $settings = Get-BridgeSettings -RootPath $script:settingsTempRoot
        Write-BridgeProviderRegistryEntry `
            -RootPath $script:settingsTempRoot `
            -SlotId 'worker-1' `
            -Model 'gpt-5.4' `
            -ModelSource 'cli-discovery' `
            -ReasoningEffort 'max' | Out-Null

        {
            Get-SlotAgentConfig `
                -Role 'Worker' `
                -SlotId 'worker-1' `
                -Settings $settings `
                -RootPath $script:settingsTempRoot
        } | Should -Throw "*model 'gpt-5.4' does not support reasoning_effort 'max'*"

        $gpt56Settings = Get-BridgeSettings -RootPath $script:settingsTempRoot
        $gpt56Config = Get-SlotAgentConfig `
            -Role 'Worker' `
            -SlotId 'worker-1' `
            -Settings $gpt56Settings `
            -RootPath $script:settingsTempRoot `
            -ProviderRegistryEntryOverride ([ordered]@{
                model = 'gpt-5.6-terra'
                model_source = 'cli-discovery'
                reasoning_effort = 'max'
            })
        $gpt56Command = Get-BridgeProviderLaunchCommand `
            -ProviderId $gpt56Config.Agent `
            -Model $gpt56Config.Model `
            -ModelSource $gpt56Config.ModelSource `
            -ReasoningEffort $gpt56Config.ReasoningEffort `
            -ProjectDir 'C:\Project Root' `
            -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
            -RootPath $script:settingsTempRoot

        $gpt56Command | Should -Match "-c 'model=gpt-5\.6-terra'.*-c 'model_reasoning_effort=max'"
    }

    It 'allows max for only exact GPT-5.6 Codex models without configured capabilities' {
        foreach ($model in @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')) {
            $command = Get-BridgeProviderLaunchCommand `
                -ProviderId 'codex' `
                -Model $model `
                -ModelSource 'cli-discovery' `
                -ReasoningEffort 'max' `
                -ProjectDir 'C:\Project Root' `
                -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
                -RootPath $script:settingsTempRoot

            $command | Should -Match "-c 'model=$model'.*-c 'model_reasoning_effort=max'"
        }

        foreach ($model in @('gpt-5.5', 'gpt-5.4', 'gpt-5.4-mini', 'gpt-5.3-codex-spark', 'provider-default', 'gpt-5.6-terra-preview')) {
            {
                Get-BridgeProviderLaunchCommand `
                    -ProviderId 'codex' `
                    -Model $model `
                    -ModelSource 'cli-discovery' `
                    -ReasoningEffort 'max' `
                    -ProjectDir 'C:\Project Root' `
                    -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
                    -RootPath $script:settingsTempRoot
            } | Should -Throw "*model '$model' does not support reasoning_effort 'max'*"
        }

@'
agent: codex
model: gpt-5.4
model-source: cli-discovery
reasoning-effort: high
prompt-transport: argv
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }
        $settings = Get-BridgeSettings -RootPath $script:settingsTempRoot
        $gpt56Config = Get-SlotAgentConfig `
            -Role 'Worker' `
            -SlotId 'worker-1' `
            -Settings $settings `
            -RootPath $script:settingsTempRoot `
            -ProviderRegistryEntryOverride ([ordered]@{
                model = 'gpt-5.6-terra'
                model_source = 'cli-discovery'
                reasoning_effort = 'max'
            })
        $gpt56Config.Model | Should -Be 'gpt-5.6-terra'
        $gpt56Config.ReasoningEffort | Should -Be 'max'

        {
            Get-SlotAgentConfig `
                -Role 'Worker' `
                -SlotId 'worker-1' `
                -Settings $settings `
                -RootPath $script:settingsTempRoot `
                -ProviderRegistryEntryOverride ([ordered]@{
                    model = 'gpt-5.6-terra'
                    model_source = 'provider-default'
                    reasoning_effort = 'max'
                })
        } | Should -Throw "*model 'gpt-5.6-terra' does not support reasoning_effort 'max'*"

        {
            Get-SlotAgentConfig `
                -Role 'Worker' `
                -SlotId 'worker-1' `
                -Settings $settings `
                -RootPath $script:settingsTempRoot `
                -ProviderRegistryEntryOverride ([ordered]@{
                    model = 'gpt-5.5'
                    model_source = 'cli-discovery'
                    reasoning_effort = 'max'
                })
        } | Should -Throw "*model 'gpt-5.5' does not support reasoning_effort 'max'*"

        $registryPath = Get-BridgeProviderCapabilityRegistryPath -RootPath $script:settingsTempRoot
        $registryDir = Split-Path -Parent $registryPath
        New-Item -ItemType Directory -Path $registryDir -Force | Out-Null
        '{"version":1,"providers":{}}' | Set-Content -Path $registryPath -Encoding UTF8
        $emptyRegistryCommand = Get-BridgeProviderLaunchCommand `
            -ProviderId 'codex' `
            -Model 'gpt-5.6-terra' `
            -ModelSource 'cli-discovery' `
            -ReasoningEffort 'max' `
            -ProjectDir 'C:\Project Root' `
            -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
            -RootPath $script:settingsTempRoot
        $emptyRegistryCommand | Should -Match "-c 'model=gpt-5\.6-terra'.*-c 'model_reasoning_effort=max'"

        {
            Get-BridgeProviderLaunchCommand `
                -ProviderId 'codex' `
                -Model 'gpt-5.6-terra' `
                -ModelSource 'provider-default' `
                -ReasoningEffort 'max' `
                -ProjectDir 'C:\Project Root' `
                -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
                -RootPath $script:settingsTempRoot
        } | Should -Throw "*model 'gpt-5.6-terra' does not support reasoning_effort 'max'*"
    }

    It 'distinguishes a missing interrupt capability from an explicit false value' {
        $registryPath = Get-BridgeProviderCapabilityRegistryPath -RootPath $script:settingsTempRoot
        $registryDir = Split-Path -Parent $registryPath
        New-Item -ItemType Directory -Path $registryDir -Force | Out-Null

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "prompt_transports": ["argv", "file", "stdin"]
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8

@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: gpt-5.4
    prompt-transport: argv
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        $config = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings -RootPath $script:settingsTempRoot

        $config.CapabilityAdapter | Should -Be 'codex'
        $config.CapabilityCommand | Should -Be 'codex'
        $config.SupportsInterrupt | Should -Be $false
        $config.SupportsInterruptDeclared | Should -Be $false
    }

    It 'rejects slot prompt transport values not supported by provider capabilities' {
        $registryPath = Get-BridgeProviderCapabilityRegistryPath -RootPath $script:settingsTempRoot
        $registryDir = Split-Path -Parent $registryPath
        New-Item -ItemType Directory -Path $registryDir -Force | Out-Null

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "prompt_transports": ["argv"]
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8

@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: gpt-5.4
    prompt-transport: file
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        {
            Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings -RootPath $script:settingsTempRoot
        } | Should -Throw "*does not support prompt_transport 'file'*"
    }

    It 'rejects provider registry prompt transport overrides not supported by provider capabilities' {
        $registryPath = Get-BridgeProviderCapabilityRegistryPath -RootPath $script:settingsTempRoot
        $registryDir = Split-Path -Parent $registryPath
        New-Item -ItemType Directory -Path $registryDir -Force | Out-Null

@'
{
  "version": 1,
  "providers": {
    "claude": {
      "adapter": "claude",
      "command": "claude",
      "prompt_transports": ["file"]
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8

@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: gpt-5.4
    prompt-transport: argv
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        Write-BridgeProviderRegistryEntry `
            -RootPath $script:settingsTempRoot `
            -SlotId 'worker-1' `
            -Agent 'claude' `
            -PromptTransport 'stdin' | Out-Null

        {
            Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings -RootPath $script:settingsTempRoot
        } | Should -Throw "*does not support prompt_transport 'stdin'*"
    }

    It 'rejects blocked provider auth modes before launch resolution' {
        $registryPath = Get-BridgeProviderCapabilityRegistryPath -RootPath $script:settingsTempRoot
        $registryDir = Split-Path -Parent $registryPath
        New-Item -ItemType Directory -Path $registryDir -Force | Out-Null

@'
{
  "version": 1,
  "providers": {
    "claude": {
      "adapter": "claude",
      "command": "claude",
      "prompt_transports": ["file"],
      "auth_modes": ["api-key", "claude-pro-max-oauth"],
      "local_interactive_oauth_modes": ["claude-pro-max-oauth"]
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8

@'
agent: claude
model: opus
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: claude
    model: opus
    prompt-transport: file
    auth-mode: token-broker
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        {
            Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings -RootPath $script:settingsTempRoot
        } | Should -Throw '*must not broker OAuth*'
    }

    It 'rejects top-level blocked provider auth modes before launch resolution' {
        $registryPath = Get-BridgeProviderCapabilityRegistryPath -RootPath $script:settingsTempRoot
        $registryDir = Split-Path -Parent $registryPath
        New-Item -ItemType Directory -Path $registryDir -Force | Out-Null

@'
{
  "version": 1,
  "providers": {
    "claude": {
      "adapter": "claude",
      "command": "claude",
      "prompt_transports": ["file"],
      "auth_modes": ["api-key", "claude-pro-max-oauth"],
      "local_interactive_oauth_modes": ["claude-pro-max-oauth"]
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8

@'
agent: claude
model: opus
prompt-transport: file
auth-mode: callback-url-receiver
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        {
            Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings -RootPath $script:settingsTempRoot
        } | Should -Throw '*must not broker OAuth*'
    }

    It 'rejects providers missing from a non-empty provider capability registry' {
        $registryPath = Get-BridgeProviderCapabilityRegistryPath -RootPath $script:settingsTempRoot
        $registryDir = Split-Path -Parent $registryPath
        New-Item -ItemType Directory -Path $registryDir -Force | Out-Null

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "prompt_transports": ["argv"]
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8

@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: claude
    model: opus
    prompt-transport: stdin
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        {
            Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings -RootPath $script:settingsTempRoot
        } | Should -Throw "*Provider capability 'claude' was not found*"
    }

    It 'builds launch commands from provider capability adapter and command metadata' {
        $registryPath = Get-BridgeProviderCapabilityRegistryPath -RootPath $script:settingsTempRoot
        $registryDir = Split-Path -Parent $registryPath
        New-Item -ItemType Directory -Path $registryDir -Force | Out-Null

@'
{
  "version": 1,
  "providers": {
    "codex-local": {
      "adapter": "codex",
      "command": "codex-beta",
      "model_options": [
        {"id": "gpt-5.4", "label": "GPT-5.4", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "xhigh"]},
        {"id": "gpt-5.5", "label": "GPT-5.5", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "xhigh"]},
        {"id": "gpt-5.6-terra", "label": "GPT-5.6 Terra", "source": "cli-discovery", "reasoning_efforts": ["low", "medium", "high", "max", "xhigh"]}
      ],
      "prompt_transports": ["argv", "file"]
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8

        $command = Get-BridgeProviderLaunchCommand `
            -ProviderId 'codex-local' `
            -Model 'gpt-5.4' `
            -ModelSource 'cli-discovery' `
            -ReasoningEffort 'xhigh' `
            -ProjectDir 'C:\Project Root' `
            -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
            -RootPath $script:settingsTempRoot

        $command | Should -Match 'codex-beta'
        $command | Should -Match "-c 'model=gpt-5\.4'"
        $command | Should -Match "-c 'model_reasoning_effort=xhigh'"
        $command | Should -Match "-C 'C:\\Project Root'"
        $command | Should -Match "--add-dir 'C:\\Project Root\\.git\\worktrees\\worker-1'"

        $maxCommand = Get-BridgeProviderLaunchCommand `
            -ProviderId 'codex-local' `
            -Model 'gpt-5.6-terra' `
            -ModelSource 'cli-discovery' `
            -ReasoningEffort 'max' `
            -ProjectDir 'C:\Project Root' `
            -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
            -RootPath $script:settingsTempRoot

        $maxCommand | Should -Match "-c 'model=gpt-5\.6-terra'"
        $maxCommand | Should -Match "-c 'model_reasoning_effort=max'"

        $providerDefaultCommand = Get-BridgeProviderLaunchCommand `
            -ProviderId 'codex-local' `
            -Model 'provider-default' `
            -ModelSource 'provider-default' `
            -ReasoningEffort 'provider-default' `
            -ProjectDir 'C:\Project Root' `
            -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
            -RootPath $script:settingsTempRoot

        $providerDefaultCommand | Should -Not -Match 'model_reasoning_effort='
        $providerDefaultCommand | Should -Not -Match 'model=provider-default'

        $providerDefaultSourceCommand = Get-BridgeProviderLaunchCommand `
            -ProviderId 'codex-local' `
            -Model 'gpt-5.4' `
            -ModelSource 'provider-default' `
            -ReasoningEffort 'provider-default' `
            -ProjectDir 'C:\Project Root' `
            -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
            -RootPath $script:settingsTempRoot

        $providerDefaultSourceCommand | Should -Not -Match 'model=gpt-5\.4'

        $previousCodexMcpDisableServers = $env:WINSMUX_CODEX_MCP_DISABLE_SERVERS
        try {
            $env:WINSMUX_CODEX_MCP_DISABLE_SERVERS = 'cua-driver,node_repl,figma'
            $mcpDisabledCommand = Get-BridgeProviderLaunchCommand `
                -ProviderId 'codex-local' `
                -Model 'gpt-5.5' `
                -ModelSource 'cli-discovery' `
                -ReasoningEffort 'high' `
                -McpMode 'disabled' `
                -ProjectDir 'C:\Project Root' `
                -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-2' `
                -RootPath $script:settingsTempRoot
        } finally {
            $env:WINSMUX_CODEX_MCP_DISABLE_SERVERS = $previousCodexMcpDisableServers
        }

        $mcpDisabledCommand | Should -Match '--disable plugins'
        $mcpDisabledCommand | Should -Match "-c 'mcp_servers\.cua-driver\.enabled=false'"
        $mcpDisabledCommand | Should -Match "-c 'mcp_servers\.node_repl\.enabled=false'"
        $mcpDisabledCommand | Should -Match "-c 'mcp_servers\.figma\.enabled=false'"

        $mcpEnabledCommand = Get-BridgeProviderLaunchCommand `
            -ProviderId 'codex-local' `
            -Model 'gpt-5.5' `
            -ModelSource 'cli-discovery' `
            -ReasoningEffort 'high' `
            -McpMode 'enabled' `
            -ProjectDir 'C:\Project Root' `
            -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-2' `
            -RootPath $script:settingsTempRoot

        $mcpEnabledCommand | Should -Not -Match '--disable plugins'
        $mcpEnabledCommand | Should -Not -Match 'mcp_servers\.figma\.enabled=false'
    }

    It 'uses built-in launch command metadata for Antigravity and Grok Build providers' {
        $antigravityCommand = Get-BridgeProviderLaunchCommand `
            -ProviderId 'antigravity' `
            -Model 'Gemini 3.5 Flash (High)' `
            -ModelSource 'cli-discovery' `
            -ReasoningEffort 'provider-default' `
            -ProjectDir 'C:\Project Root' `
            -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-3' `
            -RootPath $script:settingsTempRoot

        $antigravityCommand | Should -Be "agy --model 'Gemini 3.5 Flash (High)'"
        $antigravityCommand | Should -Not -Match '^antigravity '

        $grokCommand = Get-BridgeProviderLaunchCommand `
            -ProviderId 'grok-build' `
            -Model 'grok-build' `
            -ModelSource 'cli-discovery' `
            -ReasoningEffort 'provider-default' `
            -ProjectDir 'C:\Project Root' `
            -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-4' `
            -RootPath $script:settingsTempRoot

        $grokCommand | Should -Be "grok --model 'grok-build'"
        $grokCommand | Should -Not -Match '^grok-build '
    }

    It 'adds Claude strict empty MCP config only when MCP mode is disabled' {
        $mcpDisabledCommand = Get-BridgeProviderLaunchCommand `
            -ProviderId 'claude' `
            -Model 'claude-opus-4-8' `
            -ModelSource 'operator-override' `
            -ReasoningEffort 'high' `
            -McpMode 'disabled' `
            -ProjectDir 'C:\Project Root' `
            -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
            -RootPath $script:settingsTempRoot

        $mcpDisabledCommand | Should -Match '--mcp-config'
        $mcpDisabledCommand | Should -Match 'mcpServers'
        $mcpDisabledCommand | Should -Match '--strict-mcp-config'

        $mcpDefaultCommand = Get-BridgeProviderLaunchCommand `
            -ProviderId 'claude' `
            -Model 'claude-opus-4-8' `
            -ModelSource 'operator-override' `
            -ReasoningEffort 'high' `
            -ProjectDir 'C:\Project Root' `
            -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
            -RootPath $script:settingsTempRoot

        $mcpDefaultCommand | Should -Not -Match '--mcp-config'
        $mcpDefaultCommand | Should -Not -Match '--strict-mcp-config'
    }

    It 'rejects structurally malformed provider capability registries' {
        $registryPath = Get-BridgeProviderCapabilityRegistryPath -RootPath $script:settingsTempRoot
        $registryDir = Split-Path -Parent $registryPath
        New-Item -ItemType Directory -Path $registryDir -Force | Out-Null

@'
{
  "version": 2,
  "providers": {}
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot } | Should -Throw '*provider capability registry version*'

@'
{
  "version": "1",
  "providers": {}
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot } | Should -Throw '*provider capability registry version*'

@'
{
  "version": 1.1,
  "providers": {}
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot } | Should -Throw '*provider capability registry version*'

@'
{
  "version": 1,
  "providers": []
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot } | Should -Throw '*provider capability registry providers*'

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": true,
      "command": "codex",
      "prompt_transports": ["argv"]
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot } | Should -Throw "*provider capability field 'adapter'*"

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": 123,
      "prompt_transports": ["argv"]
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot } | Should -Throw "*provider capability field 'command'*"

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "prompt_transports": ["argv"],
      "supports_file_edit": "yes"
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot } | Should -Throw "*provider capability field 'supports_file_edit'*"

@'
{
  "version": 1,
  "providers": {
    "local-openai-compatible": {
      "adapter": "openai-compatible",
      "command": "winsmux-local-llm",
      "prompt_transports": ["stdin"],
      "read_only_launch_args": [
        { "arg": "--read-only" }
      ],
      "supports_file_edit": false
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot } | Should -Throw "*provider capability field 'read_only_launch_args'*"

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "prompt_transports": ["argv"],
      "supports_verificaton": true
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot } | Should -Throw "*provider capability field 'supports_verificaton'*"

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "prompt-transports": ["argv"]
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot } | Should -Throw "*provider capability field 'prompt-transports'*"

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "supports_file_edit": true
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot } | Should -Throw "*Missing provider capability field 'adapter'*"

@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "prompt_transports": ["socket"]
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot } | Should -Throw '*provider capability prompt transport*'
    }

    It 'rejects structurally malformed provider registries' {
        $registryPath = Get-BridgeProviderRegistryPath -RootPath $script:settingsTempRoot
        $registryDir = Split-Path -Parent $registryPath
        New-Item -ItemType Directory -Path $registryDir -Force | Out-Null

        @'
{
  "version": 1,
  "slots": []
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderRegistry -RootPath $script:settingsTempRoot } | Should -Throw '*provider registry slots*'

        @'
{
  "version": 1,
  "slots": {
    "worker-1": "claude"
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderRegistry -RootPath $script:settingsTempRoot } | Should -Throw "*provider registry slot 'worker-1'*"

        @'
{
  "version": 1,
  "slots": {
    "worker-1": {
      "updated_at_utc": "2026-04-21T00:00:00Z",
      "reason": "metadata only"
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderRegistry -RootPath $script:settingsTempRoot } | Should -Throw "*provider registry slot 'worker-1'*"

        @'
{
  "version": 1,
  "slots": {
    "worker-1": {
      "agent": {
        "name": "claude"
      },
      "model": "opus"
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8
        { Read-BridgeProviderRegistry -RootPath $script:settingsTempRoot } | Should -Throw "*provider registry field 'agent'*"
    }

    It 'fails closed when explicit agent slot entries are malformed' {
@'
agent: codex
model: gpt-5.4
external-operator: true
agent-slots:
  - runtime-role: worker
    agent: codex
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        { Get-BridgeSettings } | Should -Throw '*Invalid agent_slots configuration*'
    }

    It 'fails closed when explicit agent slots contain duplicate slot ids' {
@'
agent: codex
model: gpt-5.4
external-operator: true
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: gpt-5.4
  - slot-id: worker-1
    runtime-role: worker
    agent: codex
    model: gpt-5.4
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        { Get-BridgeSettings } | Should -Throw '*duplicate slot_id*'
    }

    It 'fails closed when worker backend values are unsupported' {
@'
worker-backend: unsupported
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        { Get-BridgeSettings } | Should -Throw '*Invalid worker_backend configuration*'
    }

    It 'fails closed when slot-level worker backend values are unsupported' {
@'
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: unsupported
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        { Get-BridgeSettings } | Should -Throw '*unsupported worker_backend*'
    }

    It 'rejects legacy role counts unless legacy_role_layout is explicitly enabled' {
@'
agent: codex
model: gpt-5.4
external-operator: true
builders: 4
reviewers: 1
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        { Get-BridgeSettings } | Should -Throw '*legacy_role_layout=true*'
    }

    It 'reads project settings from an explicit root path even when the current location differs' {
        $projectRoot = Join-Path $script:settingsTempRoot 'repo-root'
        $otherRoot = Join-Path $script:settingsTempRoot 'other-root'
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $otherRoot -Force | Out-Null

@'
agent: claude
model: sonnet
external-operator: true
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    agent: claude
    model: sonnet
'@ | Set-Content -Path (Join-Path $projectRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        Push-Location $otherRoot
        try {
            $settings = Get-BridgeSettings -RootPath $projectRoot
        } finally {
            Pop-Location
        }

        $settings.agent | Should -Be 'claude'
        $settings.model | Should -Be 'sonnet'
        $settings.agent_slots.Count | Should -Be 1
    }
}
