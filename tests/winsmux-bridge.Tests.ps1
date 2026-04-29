$ErrorActionPreference = 'Stop'

function script:Write-PsmuxBridgeTestFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Content = ''
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if ([string]::IsNullOrEmpty($Content)) {
        Set-Content -Path $Path -Value '' -Encoding UTF8
    } else {
        Set-Content -Path $Path -Value $Content -Encoding UTF8
    }
}

function script:ConvertTo-GoldenCorpusJson {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    $json = $InputObject | ConvertTo-Json -Depth 20
    $escapedProjectDir = [Regex]::Escape(($ProjectDir -replace '\\', '\\'))
    $normalized = $json -replace $escapedProjectDir, '__PROJECT_DIR__'
    $normalized = [Regex]::Replace(
        $normalized,
        '"generated_at"\s*:\s*"[^"]+"',
        '"generated_at": "__GENERATED_AT__"'
    )
    $normalized = [Regex]::Replace(
        $normalized,
        '"timestamp"\s*:\s*"[^"]*"',
        '"timestamp": "__TIMESTAMP__"'
    )
    $normalized = [Regex]::Replace(
        $normalized,
        '"last_event_at"\s*:\s*"[^"]+"',
        '"last_event_at": "__LAST_EVENT_AT__"'
    )
    $normalized = [Regex]::Replace(
        $normalized,
        'observation-pack-[a-f0-9]+\.json',
        'observation-pack-__ID__.json'
    )
    $normalized = [Regex]::Replace(
        $normalized,
        'consult-result-[a-f0-9]+\.json',
        'consult-result-__ID__.json'
    )

    return ($normalized.TrimEnd() + "`n")
}

function script:Assert-GoldenCorpusFixture {
    param(
        [Parameter(Mandatory = $true)][string]$FixturePath,
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $fullFixturePath = Join-Path $repoRoot $FixturePath
    $actual = ConvertTo-GoldenCorpusJson -InputObject $InputObject -ProjectDir $ProjectDir

    if ($env:WINSMUX_UPDATE_GOLDEN -eq '1') {
        Write-PsmuxBridgeTestFile -Path $fullFixturePath -Content $actual
    }

    Test-Path -LiteralPath $fullFixturePath | Should -Be $true
    $expected = (Get-Content -Raw -Path $fullFixturePath -Encoding UTF8).TrimEnd("`r", "`n")
    $expected = $expected -replace "`r`n", "`n"
    $actual = $actual.TrimEnd("`r", "`n") -replace "`r`n", "`n"
    $actual | Should -Be $expected
}

Describe 'Assert-Role' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\role-gate.ps1')
    }

    BeforeEach {
        $script:originalRole = $env:WINSMUX_ROLE
        $script:originalPaneId = $env:WINSMUX_PANE_ID
        $script:originalRoleMap = $env:WINSMUX_ROLE_MAP
        $script:originalRoleGateLabelsFile = $script:RoleGateLabelsFile
        Mock Deny-RoleCommand { return $false }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-role-gate-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $labelsPath = Join-Path $tempRoot 'labels.json'
        @{
            self       = 'pane-self'
            operator  = 'pane-operator'
            builder    = 'pane-builder'
            worker     = 'pane-worker'
            researcher = 'pane-researcher'
            reviewer   = 'pane-reviewer'
        } | ConvertTo-Json | Set-Content -Path $labelsPath -Encoding UTF8

        $script:roleGateTempRoot = $tempRoot
        $script:RoleGateLabelsFile = $labelsPath
        $env:WINSMUX_PANE_ID = 'pane-self'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Operator","pane-operator":"Operator","pane-builder":"Builder","pane-worker":"Worker","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'
    }

    AfterEach {
        $env:WINSMUX_ROLE = $script:originalRole
        $env:WINSMUX_PANE_ID = $script:originalPaneId
        $env:WINSMUX_ROLE_MAP = $script:originalRoleMap
        $script:RoleGateLabelsFile = $script:originalRoleGateLabelsFile

        if ($script:roleGateTempRoot -and (Test-Path $script:roleGateTempRoot)) {
            Remove-Item -Path $script:roleGateTempRoot -Recurse -Force
        }
    }

    It 'allows Operator to send anywhere and denies typing into another pane' {
        $env:WINSMUX_ROLE = 'Operator'

        (Assert-Role -Command 'send' -TargetPane 'reviewer') | Should -Be $true
        (Assert-Role -Command 'status') | Should -Be $true
        (Assert-Role -Command 'board') | Should -Be $true
        (Assert-Role -Command 'inbox') | Should -Be $true
        (Assert-Role -Command 'runs') | Should -Be $true
        (Assert-Role -Command 'digest') | Should -Be $true
        (Assert-Role -Command 'explain') | Should -Be $true
        (Assert-Role -Command 'context-reset' -TargetPane 'reviewer') | Should -Be $true
        (Assert-Role -Command 'poll-events') | Should -Be $true
        (Assert-Role -Command 'vault') | Should -Be $true
        (Assert-Role -Command 'consult-request') | Should -Be $true
        (Assert-Role -Command 'type' -TargetPane 'reviewer') | Should -Be $false
    }

    It 'allows Builder to message Operator and denies sending to peers' {
        $env:WINSMUX_ROLE = 'Builder'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Builder","pane-operator":"Operator","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'send' -TargetPane 'operator') | Should -Be $true
        (Assert-Role -Command 'status') | Should -Be $true
        (Assert-Role -Command 'board') | Should -Be $true
        (Assert-Role -Command 'inbox') | Should -Be $true
        (Assert-Role -Command 'runs') | Should -Be $true
        (Assert-Role -Command 'digest') | Should -Be $true
        (Assert-Role -Command 'explain') | Should -Be $true
        (Assert-Role -Command 'consult-result') | Should -Be $true
        (Assert-Role -Command 'type' -TargetPane 'self') | Should -Be $true
        (Assert-Role -Command 'context-reset' -TargetPane 'operator') | Should -Be $false
        (Assert-Role -Command 'send' -TargetPane 'reviewer') | Should -Be $false
        (Assert-Role -Command 'read' -TargetPane 'reviewer') | Should -Be $false
    }

    It 'allows Researcher to message Operator and denies orchestration commands' {
        $env:WINSMUX_ROLE = 'Researcher'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Researcher","pane-operator":"Operator","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'operator') | Should -Be $true
        (Assert-Role -Command 'read' -TargetPane 'self') | Should -Be $true
        (Assert-Role -Command 'digest') | Should -Be $true
        (Assert-Role -Command 'consult-error') | Should -Be $true
        (Assert-Role -Command 'poll-events') | Should -Be $false
        (Assert-Role -Command 'signal') | Should -Be $false
        (Assert-Role -Command 'wait') | Should -Be $false
    }

    It 'allows Reviewer to message Operator and denies privileged commands' {
        $env:WINSMUX_ROLE = 'Reviewer'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Reviewer","pane-operator":"Operator","pane-builder":"Builder","pane-worker":"Worker","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'operator') | Should -Be $true
        (Assert-Role -Command 'review-request') | Should -Be $true
        (Assert-Role -Command 'review-approve') | Should -Be $true
        (Assert-Role -Command 'consult-result') | Should -Be $true
        (Assert-Role -Command 'status') | Should -Be $true
        (Assert-Role -Command 'digest') | Should -Be $true
        (Assert-Role -Command 'list') | Should -Be $true
        (Assert-Role -Command 'vault') | Should -Be $false
        (Assert-Role -Command 'focus') | Should -Be $false
    }

    It 'allows Worker to act as a review-capable pane while staying non-privileged' {
        $env:WINSMUX_ROLE = 'Worker'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Worker","pane-operator":"Operator","pane-builder":"Builder","pane-worker":"Worker","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'operator') | Should -Be $true
        (Assert-Role -Command 'review-request') | Should -Be $true
        (Assert-Role -Command 'review-approve') | Should -Be $true
        (Assert-Role -Command 'review-fail') | Should -Be $true
        (Assert-Role -Command 'consult-request') | Should -Be $true
        (Assert-Role -Command 'digest') | Should -Be $true
        (Assert-Role -Command 'vault') | Should -Be $false
        (Assert-Role -Command 'focus') | Should -Be $false
    }

    It 'denies review approval commands outside Reviewer role' {
        $env:WINSMUX_ROLE = 'Builder'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Builder","pane-operator":"Operator","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'review-request') | Should -Be $false
        (Assert-Role -Command 'review-approve') | Should -Be $false
    }
}

Describe 'reviewer.sh prompt contract' {
    It 'includes mandatory design-impact checklist items' {
        $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\agents\reviewer.sh'
        $content = Get-Content -Path $scriptPath -Raw -Encoding UTF8

        $content | Should -Match 'downstream behavior, workflow, or monitoring capability'
        $content | Should -Match 'removed or changed capability replaced elsewhere'
        $content | Should -Match 'orphaned artifacts such as dead mocks'
        $content | Should -Match 'files defining called functions'
        $content | Should -Match 'missing definition-host file'
        $content | Should -Match 'DIFF_PATHSPEC'
        $content | Should -Match 'design impact'
        $content | Should -Match 'replacement check'
        $content | Should -Match 'orphaned artifacts'
    }
}

Describe 'Get-BridgeSettings' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\settings.ps1')
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

    It 'returns built-in defaults when no global or project settings exist' {
        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings

        $settings.agent | Should -Be 'codex'
        $settings.model | Should -Be 'gpt-5.4'
        $settings.config_version | Should -Be 1
        $settings.prompt_transport | Should -Be 'argv'
        $settings.external_operator | Should -Be $true
        $settings.legacy_role_layout | Should -Be $false
        $settings.operators | Should -Be 0
        $settings.worker_count | Should -Be 6
        $settings.agent_slots.Count | Should -Be 6
        $settings.agent_slots[0].slot_id | Should -Be 'worker-1'
        $settings.agent_slots[0].runtime_role | Should -Be 'worker'
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
                '@bridge-prompt-transport' { "psmux: no server running on session 'default'" }
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
                '@bridge-prompt-transport' { "psmux: no server running on session 'default'" }
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
      "prompt_transports": ["argv", "file", "stdin"],
      "auth_modes": ["api-key", "codex-chatgpt-local"],
      "local_interactive_oauth_modes": ["codex-chatgpt-local"],
      "supports_parallel_runs": true,
      "supports_interrupt": true,
      "supports_structured_result": true,
      "supports_file_edit": true,
      "supports_subagents": true,
      "supports_verification": true,
      "supports_consultation": false
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8

        $registry = Read-BridgeProviderCapabilityRegistry -RootPath $script:settingsTempRoot
        $registry.providers.codex.adapter | Should -Be 'codex'
        $registry.providers.codex.prompt_transports | Should -Be @('argv', 'file', 'stdin')
        $registry.providers.codex.auth_modes | Should -Be @('api-key', 'codex-chatgpt-local')
        $registry.providers.codex.local_interactive_oauth_modes | Should -Be @('codex-chatgpt-local')
        $registry.providers.codex.supports_file_edit | Should -Be $true

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
      "prompt_transports": ["argv", "file", "stdin"],
      "auth_modes": ["api-key", "codex-chatgpt-local"],
      "local_interactive_oauth_modes": ["codex-chatgpt-local"],
      "supports_parallel_runs": true,
      "supports_interrupt": true,
      "supports_structured_result": true,
      "supports_file_edit": true,
      "supports_subagents": true,
      "supports_verification": true,
      "supports_consultation": false
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
    auth-mode: codex-chatgpt-local
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings
        $config = Get-SlotAgentConfig -Role 'Worker' -SlotId 'worker-1' -Settings $settings -RootPath $script:settingsTempRoot

        $config.CapabilityAdapter | Should -Be 'codex'
        $config.CapabilityCommand | Should -Be 'codex'
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
      "prompt_transports": ["argv", "file"]
    }
  }
}
'@ | Set-Content -Path $registryPath -Encoding UTF8

        $command = Get-BridgeProviderLaunchCommand `
            -ProviderId 'codex-local' `
            -Model 'gpt-5.4' `
            -ProjectDir 'C:\Project Root' `
            -GitWorktreeDir 'C:\Project Root\.git\worktrees\worker-1' `
            -RootPath $script:settingsTempRoot

        $command | Should -Match 'codex-beta'
        $command | Should -Match '-c model=gpt-5\.4'
        $command | Should -Match "-C 'C:\\Project Root'"
        $command | Should -Match "--add-dir 'C:\\Project Root\\.git\\worktrees\\worker-1'"
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

Describe 'Get-OrchestraLayoutSettings' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-start.ps1')
    }

    It 'uses external operator mode by default' {
        $layout = Get-OrchestraLayoutSettings -Settings ([ordered]@{
            external_operator = $true
            worker_count       = 6
            legacy_role_layout = $false
            operators         = 0
            builders           = 0
            researchers        = 0
            reviewers          = 0
        })

        $layout.ExternalOperator | Should -Be $true
        $layout.LegacyRoleLayout | Should -Be $false
        $layout.Operators | Should -Be 0
        $layout.Workers | Should -Be 6
        $layout.Builders | Should -Be 0
        $layout.Researchers | Should -Be 0
        $layout.Reviewers | Should -Be 0
    }

    It 'prefers explicit agent slots over worker_count when deriving managed slot count' {
        $layout = Get-OrchestraLayoutSettings -Settings ([ordered]@{
            external_operator = $true
            worker_count       = 2
            agent_slots        = @(
                [ordered]@{ slot_id = 'worker-1'; runtime_role = 'worker'; agent = 'codex'; model = 'gpt-5.4'; worktree_mode = 'managed' },
                [ordered]@{ slot_id = 'worker-2'; runtime_role = 'worker'; agent = 'codex'; model = 'gpt-5.4'; worktree_mode = 'managed' },
                [ordered]@{ slot_id = 'worker-3'; runtime_role = 'worker'; agent = 'codex'; model = 'gpt-5.4'; worktree_mode = 'managed' }
            )
            agent             = 'codex'
            model             = 'gpt-5.4'
            legacy_role_layout = $false
            operators         = 0
            builders           = 0
            researchers        = 0
            reviewers          = 0
        })

        $layout.ExternalOperator | Should -Be $true
        $layout.LegacyRoleLayout | Should -Be $false
        $layout.Operators | Should -Be 0
        $layout.Workers | Should -Be 3
    }

    It 'allows agent slots without agent or model fields under strict mode' {
        $layout = Get-OrchestraLayoutSettings -Settings ([ordered]@{
            external_operator = $true
            worker_count       = 1
            agent_slots        = @(
                [pscustomobject]@{
                    slot_id       = 'worker-1'
                    runtime_role  = 'worker'
                    worktree_mode = 'managed'
                },
                [ordered]@{
                    slot_id       = 'worker-2'
                    runtime_role  = 'worker'
                    worktree_mode = 'managed'
                }
            )
            legacy_role_layout = $false
            operators         = 0
            builders           = 0
            researchers        = 0
            reviewers          = 0
        })

        $layout.ExternalOperator | Should -Be $true
        $layout.LegacyRoleLayout | Should -Be $false
        $layout.Operators | Should -Be 0
        $layout.Workers | Should -Be 2
    }

    It 'rejects unsupported non-worker runtime_role overrides until slot runtime wiring expands' {
        {
            Get-OrchestraLayoutSettings -Settings ([ordered]@{
                external_operator = $true
                worker_count       = 2
                agent_slots        = @(
                    [ordered]@{ slot_id = 'worker-1'; runtime_role = 'worker'; agent = 'codex'; model = 'gpt-5.4'; worktree_mode = 'managed' },
                    [ordered]@{ slot_id = 'review-1'; runtime_role = 'reviewer'; agent = 'claude'; model = 'sonnet'; worktree_mode = 'managed' }
                )
                agent              = 'codex'
                model              = 'gpt-5.4'
                legacy_role_layout = $false
                operators         = 0
                builders           = 0
                researchers        = 0
                reviewers          = 0
            })
        } | Should -Throw '*runtime_role overrides are not supported yet at runtime*'
    }

    It 'writes project settings to an explicit root path and omits worker_count when agent slots are present' {
        $projectRoot = Join-Path $script:settingsTempRoot 'repo-root'
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

        Save-BridgeSettings -Scope project -RootPath $projectRoot -Settings ([ordered]@{
            agent              = 'codex'
            model              = 'gpt-5.4'
            external_operator = $true
            worker_count       = 2
            agent_slots        = @(
                [ordered]@{ slot_id = 'worker-1'; runtime_role = 'worker'; agent = 'codex'; model = 'gpt-5.4'; worktree_mode = 'managed' },
                [ordered]@{ slot_id = 'worker-2'; runtime_role = 'worker'; agent = 'codex'; model = 'gpt-5.4'; worktree_mode = 'managed' }
            )
            vault_keys         = @('GH_TOKEN')
        })

        $projectConfigPath = Join-Path $projectRoot '.winsmux.yaml'
        Test-Path $projectConfigPath | Should -Be $true
        $projectConfig = Get-Content -Raw -Path $projectConfigPath -Encoding UTF8
        $projectConfig | Should -Match 'agent_slots:'
        $projectConfig | Should -Not -Match 'worker_count:'
    }

    It 'preserves legacy role layouts only when explicit opt-in is enabled' {
        $layout = Get-OrchestraLayoutSettings -Settings ([ordered]@{
            external_operator = $false
            worker_count       = 0
            legacy_role_layout = $true
            operators         = 1
            builders           = 4
            researchers        = 1
            reviewers          = 1
        })

        $layout.ExternalOperator | Should -Be $false
        $layout.LegacyRoleLayout | Should -Be $true
        $layout.Operators | Should -Be 1
        $layout.Workers | Should -Be 0
        $layout.Builders | Should -Be 4
        $layout.Researchers | Should -Be 1
        $layout.Reviewers | Should -Be 1
    }

    It 'rejects implicit legacy role counts when legacy_role_layout is false' {
        {
            Get-OrchestraLayoutSettings -Settings ([ordered]@{
                external_operator = $true
                worker_count       = 6
                legacy_role_layout = $false
                operators         = 0
                builders           = 4
                researchers        = 1
                reviewers          = 1
            })
        } | Should -Throw '*legacy_role_layout=true*'
    }
}

Describe 'Vault helpers' {
    BeforeAll {
        function Stop-WithError {
            param([string]$Message)
            throw $Message
        }

        function Resolve-Target {
            param([string]$RawTarget)
            return $RawTarget
        }

        function Confirm-Target {
            param([string]$PaneId)
            return $PaneId
        }

        function Assert-ReadMark {
            param([string]$PaneId)
        }

        function Clear-ReadMark {
            param([string]$PaneId)
        }

        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\vault.ps1')
    }

    BeforeEach {
        $script:originalTarget = $script:Target
        $script:originalRest = $script:Rest
        $script:originalPrefix = $script:WinCredTargetPrefix

        $script:Target = $null
        $script:Rest = @()
        $script:WinCredTargetPrefix = 'winsmux-test:{0}:' -f [guid]::NewGuid().ToString('N')
    }

    AfterEach {
        $testPrefix = $script:WinCredTargetPrefix
        $filter = '{0}*' -f $testPrefix
        $count = 0
        $credsPtr = [IntPtr]::Zero

        $ok = [WinCred]::CredEnumerate($filter, 0, [ref]$count, [ref]$credsPtr)
        if ($ok) {
            try {
                $ptrSize = [Runtime.InteropServices.Marshal]::SizeOf([Type][IntPtr])
                for ($i = 0; $i -lt $count; $i++) {
                    $entryPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($credsPtr, $i * $ptrSize)
                    $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($entryPtr, [Type][WinCred+CREDENTIAL])
                    [WinCred]::CredDelete($cred.TargetName, [WinCred]::CRED_TYPE_GENERIC, 0) | Out-Null
                }
            } finally {
                [WinCred]::CredFree($credsPtr) | Out-Null
            }
        }

        $script:Target = $script:originalTarget
        $script:Rest = $script:originalRest
        $script:WinCredTargetPrefix = $script:originalPrefix
    }

    It 'stores, retrieves, and lists credentials inside the test prefix only' {
        $script:Target = 'alpha'
        $script:Rest = @('one')
        Invoke-VaultSet | Out-Null

        $script:Target = 'beta'
        $script:Rest = @('two')
        Invoke-VaultSet | Out-Null

        $script:Target = 'alpha'
        $script:Rest = @()
        (Invoke-VaultGet) | Should -Be 'one'

        $listedKeys = @(Invoke-VaultList | Sort-Object)
        $listedKeys | Should -Contain 'alpha'
        $listedKeys | Should -Contain 'beta'
    }
}

Describe 'team-pipeline helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\team-pipeline.ps1')
    }

    It 'parses the orchestra manifest list format and resolves builder worktree paths' {
        $manifest = ConvertFrom-TeamPipelineManifestContent -Content @'
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: C:\repo\.worktrees\builder-1
    builder_worktree_path: C:\repo\.worktrees\builder-1
  - label: reviewer
    pane_id: %4
    role: Reviewer
    launch_dir: C:\repo
'@

        $manifest.Session.project_dir | Should -Be 'C:\repo'
        $manifest.Panes['builder-1'].pane_id | Should -Be '%2'
        $manifest.Panes['builder-1'].builder_worktree_path | Should -Be 'C:\repo\.worktrees\builder-1'

        $context = Resolve-TeamPipelineBuilderContext -BuilderLabel 'builder-1' -Manifest $manifest
        $context.ProjectDir | Should -Be 'C:\repo'
        $context.BuilderWorktreePath | Should -Be 'C:\repo\.worktrees\builder-1'
    }

    It 'supports the dictionary pane format used by the manifest helper module' {
        $manifest = ConvertFrom-TeamPipelineManifestContent -Content @'
version: 1
session:
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: %2
    role: Builder
    builder_worktree_path: C:\repo\.worktrees\builder-1
  reviewer:
    pane_id: %4
    role: Reviewer
    builder_worktree_path: ""
'@

        $manifest.Panes['builder-1'].role | Should -Be 'Builder'
        $manifest.Panes['reviewer'].pane_id | Should -Be '%4'
    }

    It 'extracts the last STATUS marker and strips it from the summary' {
        $output = @'
Work finished.
STATUS: EXEC_DONE

Follow-up note.
STATUS: VERIFY_PASS
'@

        (Get-TeamPipelineStatusFromOutput -Text $output) | Should -Be 'VERIFY_PASS'
        ((Get-TeamPipelineSummaryFromOutput -Text $output) -replace "`r`n", "`n") | Should -Be "Work finished.`n`nFollow-up note."
    }

    It 'parses structured verification output including VERIFY_PARTIAL' {
        $output = @'
STATUS: VERIFY_PARTIAL
SUMMARY: verify contract incomplete but evidence is usable
CHECK: diff|PASS|changed files inspected
CHECK: tests|FAIL|missing rerun evidence
NEXT_ACTION: rerun focused verification
'@

        $result = Get-TeamPipelineVerificationResultFromOutput -Text $output

        $result.outcome | Should -Be 'PARTIAL'
        $result.summary | Should -Be 'verify contract incomplete but evidence is usable'
        $result.checks.Count | Should -Be 2
        $result.checks[0].name | Should -Be 'diff'
        $result.checks[0].status | Should -Be 'PASS'
        $result.next_action | Should -Be 'rerun focused verification'
        $result.adversarial | Should -Be $true
    }

    It 'detects approval prompts and blocks dangerous confirmations' {
        $typeEnter = Get-TeamPipelineApprovalAction -Text "Do you want to proceed?`n1. Yes"
        $typeEnter.Kind | Should -Be 'TypeEnter'
        $typeEnter.Value | Should -Be '1'

        $shellConfirm = Get-TeamPipelineApprovalAction -Text 'Continue [Y/n]'
        $shellConfirm.Value | Should -Be 'y'

        { Get-TeamPipelineApprovalAction -Text 'Approve command: git reset --hard origin/main' } | Should -Throw
    }

    It 'returns a blocked security verdict when dangerous approval text appears during a stage wait' {
        Mock Invoke-TeamPipelineBridge {
            [PSCustomObject]@{
                ExitCode = 0
                Output = "Approve command: git reset --hard origin/main"
            }
        }
        $script:securityEventWrites = @()
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:securityEventWrites += [PSCustomObject]@{
                Event = $Event
                Target = $Target
                Data = $Data
            }
        }

        $result = Wait-TeamPipelineStage -Target 'builder-1' -StageName 'EXEC' -TimeoutSeconds 1 -PollIntervalSeconds 0 -ProjectDir 'C:\repo' -SessionName 'winsmux-orchestra' -Role 'Builder' -Task 'Investigate cache drift' -Attempt 1

        $result.Status | Should -Be 'BLOCKED'
        $result.SecurityVerdict.verdict | Should -Be 'BLOCK'
        $result.SecurityVerdict.stage | Should -Be 'EXEC'
        $script:securityEventWrites.Count | Should -Be 1
        $script:securityEventWrites[0].Event | Should -Be 'pipeline.security.blocked'
        $script:securityEventWrites[0].Data.verdict | Should -Be 'BLOCK'
    }

    It 'blocks explicit git commands in plan prompts before dispatch' {
        $script:securityEventWrites = @()
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:securityEventWrites += [PSCustomObject]@{
                Event = $Event
                Target = $Target
                Data = $Data
            }
        }

        $result = Invoke-TeamPipelineGuardedSend -StageName 'PLAN' -Target 'researcher' -Prompt "git commit -m 'oops'" -ProjectDir 'C:\repo' -SessionName 'winsmux-orchestra' -Role 'Researcher' -Task 'Investigate cache drift'

        $result.Status | Should -Be 'BLOCKED'
        $result.SecurityVerdict.verdict | Should -Be 'BLOCK'
        $result.SecurityVerdict.stage | Should -Be 'PLAN'
        $script:securityEventWrites.Count | Should -Be 1
        $script:securityEventWrites[0].Data.category | Should -Be 'git'
    }

    It 'blocks explicit destructive commands in consult prompts before dispatch' {
        $script:securityEventWrites = @()
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:securityEventWrites += [PSCustomObject]@{
                Event = $Event
                Target = $Target
                Data = $Data
            }
        }

        $result = Invoke-TeamPipelineConsultStage -Mode 'stuck' -Task 'Investigate cache drift' -BuilderLabel 'builder-1' -ProjectDir 'C:\repo' -SessionName 'winsmux-orchestra' -TargetLabel 'reviewer' -ReviewerLabel 'reviewer' -BuilderWorktreePath 'C:\repo\.worktrees\builder-1' -BuildSummary 'Remove-Item logs -Recurse -Force'

        $result.Status | Should -Be 'BLOCKED'
        $result.SecurityVerdict.verdict | Should -Be 'BLOCK'
        $result.SecurityVerdict.stage | Should -Be 'CONSULT_STUCK'
        $script:securityEventWrites.Count | Should -Be 1
        @($script:securityEventWrites | Select-Object -ExpandProperty Event) | Should -Be @('pipeline.security.blocked')
    }

    It 'does not record review dispatched when verify prompt is blocked before send' {
        $manifest = [PSCustomObject]@{
            Session = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = 'C:\repo'
            }
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\repo\.worktrees\builder-1' }
                'reviewer'  = [PSCustomObject]@{ pane_id = '%4'; role = 'Reviewer'; launch_dir = 'C:\repo' }
            }
        }

        $script:teamPipelineBridgeCalls = @()
        $script:teamPipelineEvents = @()

        Mock Read-TeamPipelineManifest { $manifest }
        Mock Invoke-TeamPipelineBridge {
            param([string[]]$Arguments, [switch]$AllowFailure)
            $script:teamPipelineBridgeCalls += ,@($Arguments)
            [PSCustomObject]@{ ExitCode = 0; Output = '' }
        }
        Mock Wait-TeamPipelineStage {
            param([string]$Target, [string]$StageName, [int]$TimeoutSeconds, [int]$PollIntervalSeconds)
            switch ($StageName) {
                'PLAN' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'PLAN_DONE'; Summary = 'plan summary'; Transcript = '' } }
                'CONSULT_EARLY' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'CONSULT_DONE'; Summary = 'early consult summary'; Transcript = '' } }
                'EXEC' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'EXEC_DONE'; Summary = "git commit -m 'oops'"; Transcript = '' } }
                default { throw "Unexpected stage $StageName" }
            }
        }
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:teamPipelineEvents += [PSCustomObject]@{
                Event = $Event
                Role = $Role
                Target = $Target
                Data = $Data
            }
        }

        $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -Reviewer 'reviewer'

        $result.FinalStatus | Should -Be 'VERIFY_BLOCKED'
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.review.dispatched' }).Count | Should -Be 0
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.security.blocked' }).Count | Should -BeGreaterThan 0
        $verifyResult = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.verify.partial' })[0]
        $verifyResult.Data.Contains('cost_unit_refs') | Should -BeFalse
    }

    It 'selects sensible planning and verification targets from the available roles' {
        $defaultTargets = Get-TeamPipelineStageTargets -BuilderLabel 'builder-1' -ResearcherLabel 'researcher' -ReviewerLabel 'reviewer'
        $defaultTargets.PlanTarget | Should -Be 'researcher'
        $defaultTargets.BuildTarget | Should -Be 'builder-1'
        $defaultTargets.VerifyTarget | Should -Be 'reviewer'

        $workerTargets = Get-TeamPipelineStageTargets -BuilderLabel 'worker-1' -ResearcherLabel '' -ReviewerLabel ''
        $workerTargets.PlanTarget | Should -Be 'worker-1'
        $workerTargets.VerifyTarget | Should -Be 'worker-1'

        $skipTargets = Get-TeamPipelineStageTargets -BuilderLabel 'builder-1' -ResearcherLabel 'researcher' -ReviewerLabel 'reviewer' -SkipPlan -SkipVerify
        $skipTargets.PlanTarget | Should -BeNullOrEmpty
        $skipTargets.VerifyTarget | Should -BeNullOrEmpty
    }

    It 'uses manifest capability flags when no explicit verification target is supplied' {
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ role = 'Worker'; supports_verification = 'false'; supports_structured_result = 'true' }
                'worker-2' = [ordered]@{ role = 'Worker'; supports_verification = 'true'; supports_structured_result = 'true' }
                'reviewer' = [ordered]@{ role = 'Reviewer'; supports_verification = 'true'; supports_structured_result = 'true' }
            }
        }

        $targets = Get-TeamPipelineStageTargets -BuilderLabel 'worker-1' -ResearcherLabel '' -ReviewerLabel '' -Manifest $manifest

        $targets.VerifyTarget | Should -Be 'reviewer'
    }

    It 'requires structured results for automatic verification targets' {
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ role = 'Worker'; supports_verification = 'false'; supports_structured_result = 'true' }
                'reviewer' = [ordered]@{ role = 'Reviewer'; supports_verification = 'true'; supports_structured_result = 'false' }
                'worker-2' = [ordered]@{ role = 'Worker'; supports_verification = 'true'; supports_structured_result = 'true' }
            }
        }

        $targets = Get-TeamPipelineStageTargets -BuilderLabel 'worker-1' -ResearcherLabel '' -ReviewerLabel '' -Manifest $manifest

        $targets.VerifyTarget | Should -Be 'worker-2'
    }

    It 'falls back to configured researcher when no manifest verification capability is available' {
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ role = 'Worker'; supports_verification = 'false'; supports_structured_result = 'true' }
                'worker-2' = [ordered]@{ role = 'Worker'; supports_verification = 'true'; supports_structured_result = 'false' }
            }
        }

        $targets = Get-TeamPipelineStageTargets -BuilderLabel 'worker-1' -ResearcherLabel 'researcher' -ReviewerLabel '' -Manifest $manifest

        $targets.VerifyTarget | Should -Be 'researcher'
    }

    It 'does not fall back to unstructured verification targets from the manifest' {
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ role = 'Worker'; supports_verification = 'true'; supports_structured_result = 'false' }
                'researcher' = [ordered]@{ role = 'Researcher'; supports_verification = 'true'; supports_structured_result = 'false' }
            }
        }

        $targets = Get-TeamPipelineStageTargets -BuilderLabel 'worker-1' -ResearcherLabel 'researcher' -ReviewerLabel '' -Manifest $manifest

        $targets.VerifyTarget | Should -BeNullOrEmpty
    }

    It 'blocks one-shot orchestration when verification is required but no structured verifier exists' {
        $manifest = [PSCustomObject]@{
            Session = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = 'C:\repo'
            }
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\repo\.worktrees\builder-1'; supports_verification = 'true'; supports_structured_result = 'false' }
                'researcher' = [PSCustomObject]@{ pane_id = '%3'; role = 'Researcher'; supports_verification = 'true'; supports_structured_result = 'false' }
            }
        }

        Mock Read-TeamPipelineManifest { $manifest }
        Mock Invoke-TeamPipelineBridge { throw 'pipeline should not dispatch without a structured verifier' }

        $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -Researcher 'researcher'

        $result.Success | Should -Be $false
        $result.FinalStatus | Should -Be 'VERIFY_UNAVAILABLE'
        $result.VerificationUnavailableReason | Should -Match 'structured results'
        Should -Invoke Invoke-TeamPipelineBridge -Times 0 -Exactly
    }

    It 'blocks one-shot orchestration when the build target cannot edit files' {
        $manifest = [PSCustomObject]@{
            Session = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = 'C:\repo'
            }
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\repo\.worktrees\builder-1'; capability_adapter = 'codex'; capability_command = 'codex'; supports_file_edit = 'false'; supports_verification = 'true'; supports_structured_result = 'true' }
                'reviewer'  = [PSCustomObject]@{ pane_id = '%3'; role = 'Reviewer'; supports_file_edit = 'false'; supports_verification = 'true'; supports_structured_result = 'true' }
            }
        }

        Mock Read-TeamPipelineManifest { $manifest }
        Mock Invoke-TeamPipelineBridge { throw 'pipeline should not dispatch to a build target without file edit support' }

        $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -Reviewer 'reviewer' -SkipVerify

        $result.Success | Should -Be $false
        $result.FinalStatus | Should -Be 'EXEC_UNAVAILABLE'
        $result.BuildUnavailableReason | Should -Match 'file edits'
        Should -Invoke Invoke-TeamPipelineBridge -Times 0 -Exactly
    }

    It 'treats generated default file edit flags without capability identity as unknown' {
        $manifest = [PSCustomObject]@{
            Session = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = 'C:\repo'
            }
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\repo\.worktrees\builder-1'; supports_file_edit = 'false' }
            }
        }

        $script:teamPipelineBridgeCalls = @()

        Mock Read-TeamPipelineManifest { $manifest }
        Mock Invoke-TeamPipelineBridge {
            param([string[]]$Arguments, [switch]$AllowFailure)
            $script:teamPipelineBridgeCalls += ,@($Arguments)
            [PSCustomObject]@{ ExitCode = 0; Output = '' }
        }
        Mock Wait-TeamPipelineStage {
            [PSCustomObject]@{ Stage = 'EXEC'; Target = 'builder-1'; Status = 'EXEC_DONE'; Summary = 'build summary'; Transcript = '' }
        }

        $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -SkipPlan -SkipVerify

        $result.Success | Should -Be $true
        $result.FinalStatus | Should -Be 'EXEC_DONE'
        @($script:teamPipelineBridgeCalls | Where-Object { $_[0] -eq 'send' -and $_[1] -eq 'builder-1' }).Count | Should -Be 1
    }

    It 'prefers reviewer then researcher for consult targets and skips builder-only runs' {
        (Get-TeamPipelineConsultTarget -BuilderLabel 'builder-1' -ResearcherLabel 'researcher' -ReviewerLabel 'reviewer') | Should -Be 'reviewer'
        (Get-TeamPipelineConsultTarget -BuilderLabel 'builder-1' -ResearcherLabel 'researcher' -ReviewerLabel '') | Should -Be 'researcher'
        (Get-TeamPipelineConsultTarget -BuilderLabel 'builder-1' -ResearcherLabel '' -ReviewerLabel 'builder-1') | Should -BeNullOrEmpty
        (Get-TeamPipelineConsultTarget -BuilderLabel 'builder-1' -ResearcherLabel '' -ReviewerLabel '') | Should -BeNullOrEmpty
    }

    It 'uses manifest consultation capability when no explicit consult target is supplied' {
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'worker-1' = [ordered]@{ role = 'Worker'; supports_consultation = 'false' }
                'worker-2' = [ordered]@{ role = 'Worker'; supports_consultation = 'true' }
            }
        }

        $target = Get-TeamPipelineConsultTarget -BuilderLabel 'worker-1' -ResearcherLabel '' -ReviewerLabel '' -Manifest $manifest

        $target | Should -Be 'worker-2'
    }

    It 'inserts early and final consult stages into successful one-shot orchestration when a consult target exists' {
        $manifest = [PSCustomObject]@{
            Session = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = 'C:\repo'
            }
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\repo\.worktrees\builder-1' }
                'reviewer'  = [PSCustomObject]@{ pane_id = '%4'; role = 'Reviewer'; launch_dir = 'C:\repo' }
            }
        }

        $script:teamPipelineBridgeCalls = @()
        $script:teamPipelineEvents = @()

        Mock Read-TeamPipelineManifest { $manifest }
        Mock Invoke-TeamPipelineBridge {
            param([string[]]$Arguments, [switch]$AllowFailure)
            $script:teamPipelineBridgeCalls += ,@($Arguments)
            [PSCustomObject]@{ ExitCode = 0; Output = '' }
        }
        Mock Wait-TeamPipelineStage {
            param([string]$Target, [string]$StageName, [int]$TimeoutSeconds, [int]$PollIntervalSeconds)
            switch ($StageName) {
                'PLAN'          { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'PLAN_DONE'; Summary = 'plan summary'; Transcript = '' } }
                'CONSULT_EARLY' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'CONSULT_DONE'; Summary = 'early consult summary'; Transcript = '' } }
                'EXEC'          { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'EXEC_DONE'; Summary = 'build summary'; Transcript = '' } }
                'VERIFY'        { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'VERIFY_PASS'; Summary = 'verify summary'; Transcript = '' } }
                'CONSULT_FINAL' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'CONSULT_DONE'; Summary = 'final consult summary'; Transcript = '' } }
                default         { throw "Unexpected stage $StageName" }
            }
        }
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:teamPipelineEvents += [PSCustomObject]@{
                Event = $Event
                Role = $Role
                Target = $Target
                Data = $Data
            }
        }

        $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -Reviewer 'reviewer'

        $result.FinalStatus | Should -Be 'VERIFY_PASS'
        $result.Success | Should -Be $true
        $result.PreWorkConsult.Status | Should -Be 'CONSULT_DONE'
        $result.FinalConsult.Status | Should -Be 'CONSULT_DONE'
        @($script:teamPipelineBridgeCalls | Where-Object { $_[0] -eq 'send' -and $_[1] -eq 'reviewer' }).Count | Should -Be 3
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.consult.dispatched' }).Count | Should -Be 2
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.consult.completed' }).Count | Should -Be 2
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.decompose.completed' }).Count | Should -Be 1
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.dispatch.assigned' }).Count | Should -Be 1
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.collect.completed' }).Count | Should -Be 1
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.review.dispatched' }).Count | Should -Be 1

        $managedDispatch = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.dispatch.assigned' })[0]
        $managedDispatch.Role | Should -Be 'Operator'
        $managedDispatch.Data.upper_operator | Should -Be 'claude_code'
        $managedDispatch.Data.aggregation_point | Should -Be 'claude_code_operator'
        $managedDispatch.Data.peer_to_peer_allowed | Should -Be $false
        $managedDispatch.Data.state | Should -Be 'assigned'

        $consultDispatch = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.consult.dispatched' })[0]
        $consultDispatch.Data.governance_cost_units[0].unit_type | Should -Be 'governance_invocation'
        $consultDispatch.Data.governance_cost_units[0].kind | Should -Be 'consult'
        $consultDispatch.Data.governance_cost_units[0].mode | Should -Be 'early'

        $consultComplete = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.consult.completed' })[0]
        $consultComplete.Data.cost_unit_refs[0] | Should -Be $consultDispatch.Data.governance_cost_units[0].unit_id

        $verifyDispatch = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.review.dispatched' })[0]
        $verifyDispatch.Data.governance_cost_units[0].unit_type | Should -Be 'governance_invocation'
        $verifyDispatch.Data.governance_cost_units[0].kind | Should -Be 'verify'

        $verifyResult = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.verify.pass' })[0]
        $verifyResult.Data.cost_unit_refs[0] | Should -Be $verifyDispatch.Data.governance_cost_units[0].unit_id
    }

    It 'inserts a stuck consult before returning blocked execution' {
        $manifest = [PSCustomObject]@{
            Session = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = 'C:\repo'
            }
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\repo\.worktrees\builder-1' }
                'reviewer'  = [PSCustomObject]@{ pane_id = '%4'; role = 'Reviewer'; launch_dir = 'C:\repo' }
            }
        }

        $script:teamPipelineBridgeCalls = @()
        $script:teamPipelineEvents = @()

        Mock Read-TeamPipelineManifest { $manifest }
        Mock Invoke-TeamPipelineBridge {
            param([string[]]$Arguments, [switch]$AllowFailure)
            $script:teamPipelineBridgeCalls += ,@($Arguments)
            [PSCustomObject]@{ ExitCode = 0; Output = '' }
        }
        Mock Wait-TeamPipelineStage {
            param([string]$Target, [string]$StageName, [int]$TimeoutSeconds, [int]$PollIntervalSeconds)
            switch ($StageName) {
                'PLAN'          { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'PLAN_DONE'; Summary = 'plan summary'; Transcript = '' } }
                'CONSULT_EARLY' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'CONSULT_DONE'; Summary = 'early consult summary'; Transcript = '' } }
                'EXEC'          { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'BLOCKED'; Summary = 'builder blocked summary'; Transcript = '' } }
                'CONSULT_STUCK' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'CONSULT_DONE'; Summary = 'stuck consult summary'; Transcript = '' } }
                default         { throw "Unexpected stage $StageName" }
            }
        }
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:teamPipelineEvents += [PSCustomObject]@{
                Event = $Event
                Role = $Role
                Target = $Target
                Data = $Data
            }
        }

        $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -Reviewer 'reviewer'

        $result.FinalStatus | Should -Be 'EXEC_BLOCKED'
        $result.Success | Should -Be $false
        $result.StuckConsults.Count | Should -Be 1
        $result.StuckConsults[0].Status | Should -Be 'CONSULT_DONE'
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.consult.dispatched' }).Count | Should -Be 2
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.consult.completed' }).Count | Should -Be 2
        @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.escalate.required' }).Count | Should -Be 1

        $escalation = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.escalate.required' })[0]
        $escalation.Role | Should -Be 'Operator'
        $escalation.Data.state | Should -Be 'required'
        $escalation.Data.reason | Should -Be 'EXEC_BLOCKED'
        $escalation.Data.peer_to_peer_allowed | Should -Be $false
    }

    It 'keeps escalation target visible when no consult pane is configured' {
        $manifest = [PSCustomObject]@{
            Session = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = 'C:\repo'
            }
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder'; builder_worktree_path = 'C:\repo\.worktrees\builder-1' }
                'reviewer'  = [PSCustomObject]@{ pane_id = '%4'; role = 'Reviewer'; launch_dir = 'C:\repo'; supports_structured_result = 'true'; supports_verification = 'true'; supports_consultation = 'false' }
            }
        }

        $script:teamPipelineEvents = @()

        Mock Read-TeamPipelineManifest { $manifest }
        Mock Invoke-TeamPipelineBridge { [PSCustomObject]@{ ExitCode = 0; Output = '' } }
        Mock Wait-TeamPipelineStage {
            param([string]$Target, [string]$StageName)
            switch ($StageName) {
                'EXEC'   { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'EXEC_DONE'; Summary = 'build summary'; Transcript = '' } }
                'VERIFY' { return [PSCustomObject]@{ Stage = $StageName; Target = $Target; Status = 'VERIFY_PARTIAL'; Summary = 'needs operator decision'; Transcript = '' } }
                default  { throw "Unexpected stage $StageName" }
            }
        }
        Mock Write-TeamPipelineEvent {
            param($ProjectDir, $SessionName, $Event, $Message, $Role, $PaneId, $Target, $Data)
            $script:teamPipelineEvents += [PSCustomObject]@{
                Event  = $Event
                Role   = $Role
                Target = $Target
                Data   = $Data
            }
        }

        $result = Invoke-TeamPipeline -Task 'Investigate cache drift' -Builder 'builder-1' -SkipPlan

        $result.FinalStatus | Should -Be 'VERIFY_PARTIAL'
        $escalation = @($script:teamPipelineEvents | Where-Object { $_.Event -eq 'pipeline.escalate.required' })[0]
        $escalation.Target | Should -Be 'claude_code_operator'
        $escalation.Data.target | Should -Be 'claude_code_operator'
        $escalation.Data.peer_to_peer_allowed | Should -Be $false
    }
}

Describe 'manifest worker isolation metadata' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\manifest.ps1')
    }

    It 'persists worker assignment fields in pane entries' {
        $entry = ConvertTo-ManifestPaneEntry -PaneSummary ([ordered]@{
            Label = 'worker-1'
            PaneId = '%2'
            SlotId = 'worker-1'
            Role = 'Worker'
            ProjectDir = 'C:\repo'
            BuilderBranch = 'worktree-worker-1'
            BuilderWorktreePath = 'C:\repo\.worktrees\worker-1'
            WorktreeGitDir = 'C:\repo\.git\worktrees\worker-1'
            ExpectedOrigin = 'https://github.com/example/repo.git'
        })

        $entry.pane_id | Should -Be '%2'
        $entry.slot_id | Should -Be 'worker-1'
        $entry.project_dir | Should -Be 'C:\repo'
        $entry.builder_branch | Should -Be 'worktree-worker-1'
        $entry.builder_worktree_path | Should -Be 'C:\repo\.worktrees\worker-1'
        $entry.worktree_git_dir | Should -Be 'C:\repo\.git\worktrees\worker-1'
        $entry.expected_origin | Should -Be 'https://github.com/example/repo.git'
    }
}

Describe 'winsmux pane env contract' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\pane-env.ps1')
    }

    BeforeEach {
        $script:paneEnvTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-pane-env-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:paneEnvTempRoot '.winsmux') -Force | Out-Null
        $script:previousHookProfile = $env:WINSMUX_HOOK_PROFILE
        $script:previousGovernanceMode = $env:WINSMUX_GOVERNANCE_MODE
    }

    AfterEach {
        if ($null -eq $script:previousHookProfile) {
            Remove-Item Env:WINSMUX_HOOK_PROFILE -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_HOOK_PROFILE = $script:previousHookProfile
        }

        if ($null -eq $script:previousGovernanceMode) {
            Remove-Item Env:WINSMUX_GOVERNANCE_MODE -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_GOVERNANCE_MODE = $script:previousGovernanceMode
        }

        if ($script:paneEnvTempRoot -and (Test-Path $script:paneEnvTempRoot)) {
            Remove-Item -Path $script:paneEnvTempRoot -Recurse -Force
        }
    }

    It 'reads hook profile and governance mode from governance.yaml when env vars are absent' {
@'
mode: enhanced
hook_profile: builder
'@ | Set-Content -Path (Join-Path $script:paneEnvTempRoot '.winsmux\governance.yaml') -Encoding UTF8

        $contract = Get-WinsmuxEnvironmentContract -ProjectDir $script:paneEnvTempRoot

        $contract.hook_profile | Should -Be 'builder'
        $contract.governance_mode | Should -Be 'enhanced'
        $contract.variable_names | Should -Contain 'WINSMUX_HOOK_PROFILE'
        $contract.variable_names | Should -Contain 'WINSMUX_GOVERNANCE_MODE'
    }

    It 'lets WINSMUX_HOOK_PROFILE and WINSMUX_GOVERNANCE_MODE override governance.yaml' {
@'
mode: core
hook_profile: ci
'@ | Set-Content -Path (Join-Path $script:paneEnvTempRoot '.winsmux\governance.yaml') -Encoding UTF8
        $env:WINSMUX_HOOK_PROFILE = 'operator'
        $env:WINSMUX_GOVERNANCE_MODE = 'standard'

        (Resolve-WinsmuxHookProfile -ProjectDir $script:paneEnvTempRoot) | Should -Be 'operator'
        (Resolve-WinsmuxGovernanceMode -ProjectDir $script:paneEnvTempRoot) | Should -Be 'standard'
    }

    It 'builds a normalized pane environment payload' {
        $env:WINSMUX_HOOK_PROFILE = 'builder'
        $env:WINSMUX_GOVERNANCE_MODE = 'enhanced'

        $payload = Get-WinsmuxPaneEnvironment -Role 'Worker' -PaneId '%4' -SessionName 'winsmux-orchestra' -ProjectDir $script:paneEnvTempRoot -RoleMapJson '{"%4":"Worker"}' -BuilderWorktreePath 'C:\repo\.worktrees\builder-1' -SlotId 'worker-1' -AssignedBranch 'worktree-worker-1' -GitWorktreeDir 'C:\repo\.git\worktrees\worker-1' -ExpectedOrigin 'https://github.com/example/repo.git'

        $payload.WINSMUX_ORCHESTRA_SESSION | Should -Be 'winsmux-orchestra'
        $payload.WINSMUX_ORCHESTRA_PROJECT_DIR | Should -Be $script:paneEnvTempRoot
        $payload.WINSMUX_ROLE | Should -Be 'Worker'
        $payload.WINSMUX_PANE_ID | Should -Be '%4'
        $payload.WINSMUX_ROLE_MAP | Should -Be '{"%4":"Worker"}'
        $payload.WINSMUX_BUILDER_WORKTREE | Should -Be 'C:\repo\.worktrees\builder-1'
        $payload.WINSMUX_ASSIGNED_WORKTREE | Should -Be 'C:\repo\.worktrees\builder-1'
        $payload.WINSMUX_SLOT_ID | Should -Be 'worker-1'
        $payload.WINSMUX_ASSIGNED_BRANCH | Should -Be 'worktree-worker-1'
        $payload.WINSMUX_WORKTREE_GITDIR | Should -Be 'C:\repo\.git\worktrees\worker-1'
        $payload.WINSMUX_EXPECTED_ORIGIN | Should -Be 'https://github.com/example/repo.git'
        $payload.WINSMUX_HOOK_PROFILE | Should -Be 'builder'
        $payload.WINSMUX_GOVERNANCE_MODE | Should -Be 'enhanced'
    }

    It 'builds a clean ConPTY boundary that scrubs stray WINSMUX variables before reinjection' {
        $env:WINSMUX_HOOK_PROFILE = 'builder'
        $env:WINSMUX_GOVERNANCE_MODE = 'enhanced'

        $payload = Get-WinsmuxPaneEnvironment -Role 'Worker' -PaneId '%4' -SessionName 'winsmux-orchestra' -ProjectDir $script:paneEnvTempRoot -RoleMapJson '{"%4":"Worker"}' -BuilderWorktreePath 'C:\repo\.worktrees\builder-1'
        $clean = Get-CleanPtyEnv -AllowedEnvironment $payload

        $clean.RemoveCommand | Should -Match 'WINSMUX_\*'
        $clean.RemoveCommand | Should -Match 'Remove-Item'
        $clean.AllowedVariableNames | Should -Contain 'WINSMUX_ROLE'
        $clean.AllowedVariableNames | Should -Contain 'WINSMUX_GOVERNANCE_MODE'
        $clean.Environment.WINSMUX_ROLE | Should -Be 'Worker'
        $clean.Environment.WINSMUX_PANE_ID | Should -Be '%4'
    }

    It 'creates a normalized governance cost unit' {
        $unit = New-WinsmuxGovernanceCostUnit -Kind 'Consult' -Mode 'Final' -Task 'TASK-310' -RunId 'task:310' -Stage 'CONSULT_FINAL' -Role 'Reviewer' -Target 'reviewer' -Attempt 1 -Source 'test'

        $unit.unit_type | Should -Be 'governance_invocation'
        $unit.kind | Should -Be 'consult'
        $unit.mode | Should -Be 'final'
        $unit.stage | Should -Be 'consult_final'
        $unit.quantity | Should -Be 1
        $unit.unit_id | Should -Match 'TASK-310'
    }
}

Describe 'pane-control helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\pane-control.ps1')
    }

    BeforeEach {
        $script:paneControlTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-pane-control-tests-' + [guid]::NewGuid().ToString('N'))
        $script:paneControlManifestDir = Join-Path $script:paneControlTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:paneControlManifestDir -Force | Out-Null
    }

    AfterEach {
        if ($script:paneControlTempRoot -and (Test-Path $script:paneControlTempRoot)) {
            Remove-Item -Path $script:paneControlTempRoot -Recurse -Force
        }
    }

    It 'prefers launch_dir over builder_worktree_path when building a restart plan' {
        @'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'builder-1'
    pane_id: '%2'
    role: 'Builder'
    exec_mode: true
    launch_dir: 'C:\repo\.worktrees\builder-2'
    builder_branch: 'worktree-builder-1'
    builder_worktree_path: 'C:\repo\.worktrees\builder-1'
    task: null
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            roles = [ordered]@{}
        }

        $plan = Get-PaneControlRestartPlan -ProjectDir $script:paneControlTempRoot -PaneId '%2' -Settings $settings

        $plan.LaunchDir | Should -Be 'C:\repo\.worktrees\builder-2'
        $plan.GitWorktreeDir | Should -Be 'C:\repo\.worktrees\builder-2'
        $plan.LaunchCommand | Should -Match $([regex]::Escape("-C 'C:\repo\.worktrees\builder-2'"))
    }

    It 'preserves explicit worktree_git_dir when reading a worker entry' {
@'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'worker-1'
    pane_id: '%2'
    role: 'Worker'
    exec_mode: true
    launch_dir: 'C:\repo\.worktrees\worker-1'
    builder_branch: 'worktree-worker-1'
    builder_worktree_path: 'C:\repo\.worktrees\worker-1'
    worktree_git_dir: 'C:\repo\.git\worktrees\worker-1'
    task: null
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $entries = @(Get-PaneControlManifestEntries -ProjectDir $script:paneControlTempRoot)

        $entries.Count | Should -Be 1
        $entries[0].LaunchDir | Should -Be 'C:\repo\.worktrees\worker-1'
        $entries[0].BuilderBranch | Should -Be 'worktree-worker-1'
        $entries[0].GitWorktreeDir | Should -Be 'C:\repo\.git\worktrees\worker-1'
    }

    It 'ignores stale worker worktree metadata when reading a non-worker entry' {
@'
version: 1
saved_at: '2026-04-23T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'reviewer'
    pane_id: '%4'
    role: 'Reviewer'
    exec_mode: true
    launch_dir: ''
    builder_branch: 'worktree-worker-1'
    builder_worktree_path: 'C:\repo\.worktrees\worker-1'
    worktree_git_dir: 'C:\repo\.git\worktrees\worker-1'
    task: null
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $entries = @(Get-PaneControlManifestEntries -ProjectDir $script:paneControlTempRoot)

        $entries.Count | Should -Be 1
        $entries[0].Role | Should -Be 'Reviewer'
        $entries[0].LaunchDir | Should -Be 'C:\repo'
        $entries[0].BuilderBranch | Should -Be ''
        $entries[0].BuilderWorktreePath | Should -Be ''
        $entries[0].GitWorktreeDir | Should -Be 'C:\repo\.git'
    }

    It 'uses slot-level agent and model overrides when building a restart plan' {
@'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'worker-1'
    pane_id: '%2'
    role: 'Worker'
    exec_mode: false
    launch_dir: 'C:\repo'
    task: null
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            roles = [ordered]@{
                worker = [ordered]@{
                    agent = 'codex'
                    model = 'gpt-5.4'
                }
            }
            agent_slots = @(
                [ordered]@{
                    slot_id = 'worker-1'
                    runtime_role = 'worker'
                    agent = 'claude'
                    model = 'sonnet'
                }
            )
        }

        $plan = Get-PaneControlRestartPlan -ProjectDir $script:paneControlTempRoot -PaneId '%2' -Settings $settings

        $plan.Agent | Should -Be 'claude'
        $plan.Model | Should -Be 'sonnet'
        $plan.PromptTransport | Should -Be 'argv'
        $plan.LaunchCommand | Should -Be "claude --model 'sonnet' --permission-mode bypassPermissions"
    }

    It 'uses provider registry overrides when building a restart plan' {
@"
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: '${script:paneControlTempRoot}'
  git_worktree_dir: '${script:paneControlTempRoot}\.git'
panes:
  - label: 'worker-1'
    pane_id: '%2'
    role: 'Worker'
    exec_mode: false
    launch_dir: '${script:paneControlTempRoot}'
    task: null
"@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        @"
agent: codex
model: gpt-5.4
agent_slots:
  - slot_id: worker-1
    runtime_role: worker
    agent: codex
    model: gpt-5.4
    prompt_transport: argv
"@ | Set-Content -Path (Join-Path $script:paneControlTempRoot '.winsmux.yaml') -Encoding UTF8

        Write-BridgeProviderRegistryEntry `
            -RootPath $script:paneControlTempRoot `
            -SlotId 'worker-1' `
            -Agent 'claude' `
            -Model 'opus' `
            -PromptTransport 'file' `
            -Reason 'operator requested provider hot-swap' | Out-Null
        $settings = Get-BridgeSettings -RootPath $script:paneControlTempRoot

        $plan = Get-PaneControlRestartPlan -ProjectDir $script:paneControlTempRoot -PaneId '%2' -Settings $settings

        $plan.Agent | Should -Be 'claude'
        $plan.Model | Should -Be 'opus'
        $plan.PromptTransport | Should -Be 'file'
        $plan.Source | Should -Be 'registry'
        $plan.LaunchCommand | Should -Be "claude --model 'opus' --permission-mode bypassPermissions"
    }

    It 'projects provider capability adapters into restart plans' {
@"
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: '${script:paneControlTempRoot}'
  git_worktree_dir: '${script:paneControlTempRoot}\.git'
panes:
  - label: 'worker-1'
    pane_id: '%2'
    role: 'Worker'
    exec_mode: false
    launch_dir: '${script:paneControlTempRoot}'
    task: null
"@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8
@'
{
  "version": 1,
  "providers": {
    "codex-nightly": {
      "adapter": "codex",
      "command": "codex-nightly",
      "prompt_transports": ["argv", "file"],
      "supports_parallel_runs": true,
      "supports_interrupt": true,
      "supports_structured_result": true,
      "supports_file_edit": true,
      "supports_subagents": true,
      "supports_verification": true,
      "supports_consultation": false
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'provider-capabilities.json') -Encoding UTF8
        Write-BridgeProviderRegistryEntry `
            -RootPath $script:paneControlTempRoot `
            -SlotId 'worker-1' `
            -Agent 'codex-nightly' `
            -Model 'gpt-5.4-nightly' `
            -PromptTransport 'argv' `
            -Reason 'operator requested provider hot-swap' | Out-Null
        $settings = Get-BridgeSettings -RootPath $script:paneControlTempRoot

        $plan = Get-PaneControlRestartPlan -ProjectDir $script:paneControlTempRoot -PaneId '%2' -Settings $settings

        $plan.Agent | Should -Be 'codex-nightly'
        $plan.CapabilityAdapter | Should -Be 'codex'
        $plan.LaunchCommand | Should -Match '^codex-nightly -c model=gpt-5\.4-nightly'
    }

    It 'includes slot-level prompt transport overrides in the restart plan' {
@'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'worker-1'
    pane_id: '%2'
    role: 'Worker'
    exec_mode: false
    launch_dir: 'C:\repo'
    task: null
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            prompt_transport = 'argv'
            roles = [ordered]@{
                worker = [ordered]@{
                    agent = 'codex'
                    model = 'gpt-5.4'
                    prompt_transport = 'file'
                }
            }
            agent_slots = @(
                [ordered]@{
                    slot_id = 'worker-1'
                    runtime_role = 'worker'
                    agent = 'claude'
                    model = 'sonnet'
                    prompt_transport = 'argv'
                }
            )
        }

        $plan = Get-PaneControlRestartPlan -ProjectDir $script:paneControlTempRoot -PaneId '%2' -Settings $settings

        $plan.Agent | Should -Be 'claude'
        $plan.Model | Should -Be 'sonnet'
        $plan.PromptTransport | Should -Be 'argv'
    }

    It 'updates launch_dir and builder_worktree_path together for builder panes' {
@'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'builder-1'
    pane_id: '%2'
    role: 'Builder'
    exec_mode: true
    launch_dir: 'C:\repo\.worktrees\builder-1'
    builder_branch: 'worktree-builder-1'
    builder_worktree_path: 'C:\repo\.worktrees\builder-1'
    task: null
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        Set-PaneControlManifestPanePaths -ProjectDir $script:paneControlTempRoot -PaneId '%2' -LaunchDir 'C:\repo\.worktrees\builder-9' -BuilderWorktreePath 'C:\repo\.worktrees\builder-9'

        $context = Get-PaneControlManifestContext -ProjectDir $script:paneControlTempRoot -PaneId '%2'
        $manifestContent = Get-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Raw -Encoding UTF8
        $context.LaunchDir | Should -Be 'C:\repo\.worktrees\builder-9'
        $context.BuilderWorktreePath | Should -Be 'C:\repo\.worktrees\builder-9'
        $manifestContent | Should -Match $([regex]::Escape("launch_dir: 'C:\repo\.worktrees\builder-9'"))
        $manifestContent | Should -Match $([regex]::Escape("builder_worktree_path: 'C:\repo\.worktrees\builder-9'"))
    }

    It 'updates the manifest label from the respawned pane title' {
@'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'builder-1'
    pane_id: '%2'
    role: 'Builder'
    exec_mode: true
    launch_dir: 'C:\repo\.worktrees\builder-1'
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        Mock Get-PaneControlPaneTitle { 'builder-2' }

        $updated = Update-PaneControlManifestPaneLabel -ProjectDir $script:paneControlTempRoot -PaneId '%2'

        $context = Get-PaneControlManifestContext -ProjectDir $script:paneControlTempRoot -PaneId '%2'
        $manifestContent = Get-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Raw -Encoding UTF8

        $updated | Should -Be $true
        $context.Label | Should -Be 'builder-2'
        $manifestContent | Should -Match $([regex]::Escape("'builder-2':"))
    }

    It 'updates the manifest label when panes are stored in dictionary format' {
@'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  builder-1:
    pane_id: '%2'
    role: 'Builder'
    exec_mode: true
    launch_dir: 'C:\repo\.worktrees\builder-1'
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        Mock Get-PaneControlPaneTitle { 'builder-2' }

        $updated = Update-PaneControlManifestPaneLabel -ProjectDir $script:paneControlTempRoot -PaneId '%2'

        $context = Get-PaneControlManifestContext -ProjectDir $script:paneControlTempRoot -PaneId '%2'
        $manifestContent = Get-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Raw -Encoding UTF8

        $updated | Should -Be $true
        $context.Label | Should -Be 'builder-2'
        $manifestContent | Should -Match $([regex]::Escape("'builder-2':"))
    }

    It 'reads pane titles through the pane-control winsmux wrapper' {
        Mock Invoke-PaneControlWinsmux { @('ignored', 'builder-7') } -ParameterFilter {
            $Arguments.Count -eq 5 -and
            $Arguments[0] -eq 'display-message' -and
            $Arguments[1] -eq '-p' -and
            $Arguments[2] -eq '-t' -and
            $Arguments[3] -eq '%7' -and
            $Arguments[4] -eq '#{pane_title}'
        }

        $title = Get-PaneControlPaneTitle -PaneId '%7'

        $title | Should -Be 'builder-7'
        Should -Invoke Invoke-PaneControlWinsmux -Times 1 -Exactly
    }

    It 'keeps changed_files empty when the manifest stores an empty array' {
@'
version: 1
saved_at: '2026-04-09T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
panes:
  builder-1:
    pane_id: '%2'
    role: 'Builder'
    changed_file_count: '0'
    changed_files: '[]'
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $entries = @(Get-PaneControlManifestEntries -ProjectDir $script:paneControlTempRoot)

        $entries.Count | Should -Be 1
        $entries[0].ChangedFileCount | Should -Be 0
        $entries[0].ChangedFiles | Should -Be @()
    }

    It 'surfaces security_policy from the manifest entry' {
@'
version: 1
saved_at: '2026-04-09T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
panes:
  worker-1:
    pane_id: '%2'
    role: 'Worker'
    security_policy: '{\"mode\":\"blocklist\",\"allow_patterns\":[\"Invoke-Pester\"],\"block_patterns\":[\"git reset --hard\"]}'
'@ | Set-Content -Path (Join-Path $script:paneControlManifestDir 'manifest.yaml') -Encoding UTF8

        $entries = @(Get-PaneControlManifestEntries -ProjectDir $script:paneControlTempRoot)
        $entry = @($entries | Where-Object { $_.Label -eq 'worker-1' } | Select-Object -First 1)[0]

        $entry | Should -Not -BeNullOrEmpty
        $entry.SecurityPolicy.mode | Should -Be 'blocklist'
        @($entry.SecurityPolicy.allow_patterns) | Should -Be @('Invoke-Pester')
        @($entry.SecurityPolicy.block_patterns) | Should -Be @('git reset --hard')
    }

}

Describe 'logger helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\logger.ps1')
        $script:clmSafeIoContent = Get-Content -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\clm-safe-io.ps1') -Raw -Encoding UTF8
        $script:loggerPwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    }

    BeforeEach {
        $script:loggerTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-logger-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:loggerTempRoot -Force | Out-Null
    }

    AfterEach {
        if ($script:loggerTempRoot -and (Test-Path $script:loggerTempRoot)) {
            Remove-Item -Path $script:loggerTempRoot -Recurse -Force
        }
    }

    It 'resolves the orchestra log path under .winsmux logs' {
        $path = Get-OrchestraLogPath -ProjectDir $script:loggerTempRoot -SessionName 'winsmux-orchestra'
        $path | Should -Be (Join-Path $script:loggerTempRoot '.winsmux\logs\winsmux-orchestra.jsonl')
    }

    It 'initializes the log file and appends structured jsonl records' {
        $logPath = Initialize-OrchestraLogger -ProjectDir $script:loggerTempRoot -SessionName 'session-a'
        Test-Path $logPath | Should -Be $true

        $record = Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-a' -Event 'pane.started' -Message 'builder booted' -Role 'Builder' -PaneId '%2' -Target 'builder-1' -Data ([ordered]@{ agent = 'codex'; model = 'gpt-5.4' })
        $record.session | Should -Be 'session-a'
        $record.event | Should -Be 'pane.started'
        $record.role | Should -Be 'Builder'
        $record.data.agent | Should -Be 'codex'

        $lines = @(Get-Content -Path $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 1
        $parsed = $lines[0] | ConvertFrom-Json
        $parsed.message | Should -Be 'builder booted'
        $parsed.target | Should -Be 'builder-1'
        $parsed.data.model | Should -Be 'gpt-5.4'
    }

    It 'reads back structured log records in order' {
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-b' -Event 'session.started' -Data ([ordered]@{ panes = 3 }) | Out-Null
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-b' -Event 'review.failed' -Level 'warn' -Data ([ordered]@{ finding_count = 2 }) | Out-Null

        $records = Read-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'session-b'
        $records.Count | Should -Be 2
        $records[0].event | Should -Be 'session.started'
        $records[0].data.panes | Should -Be 3
        $records[1].level | Should -Be 'warn'
        $records[1].data.finding_count | Should -Be 2
    }

    It 'serializes concurrent jsonl appends across multiple PowerShell processes' {
        $logPath = Join-Path $script:loggerTempRoot '.winsmux\logs\concurrent.jsonl'
        $workerScriptPath = Join-Path $script:loggerTempRoot 'append-worker.ps1'
        $clmSafeIoPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\clm-safe-io.ps1'
        $workerScript = (@'
param(
    [Parameter(Mandatory = $true)][string]$TargetPath,
    [Parameter(Mandatory = $true)][int]$WorkerId
)

. '{0}'

1..20 | ForEach-Object {{
    Write-WinsmuxTextFile -Path $TargetPath -Content ("worker=$WorkerId seq=$_") -Append
}}
'@) -f ($clmSafeIoPath -replace "'", "''")

        Set-Content -Path $workerScriptPath -Value $workerScript -Encoding UTF8

        $processes = 1..3 | ForEach-Object {
            Start-Process -FilePath $script:loggerPwshPath -ArgumentList @('-NoProfile', '-File', $workerScriptPath, '-TargetPath', $logPath, '-WorkerId', $_) -PassThru -WindowStyle Hidden
        }

        foreach ($process in $processes) {
            $process.WaitForExit(180000) | Should -Be $true
            $process.ExitCode | Should -Be 0
        }

        $lines = @(Get-Content -Path $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 60
        @($lines | Select-Object -Unique).Count | Should -Be 60
    }

    It 'reclaims stale file locks left by dead processes' {
        $logPath = Join-Path $script:loggerTempRoot '.winsmux\logs\stale.jsonl'
        $lockDir = "$logPath.lock"
        $metadataPath = Join-Path $lockDir 'owner.json'

        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
        @"
{"pid":999999,"started_at":"2000-01-01T00:00:00Z"}
"@ | Set-Content -Path $metadataPath -Encoding UTF8

        Write-WinsmuxTextFile -Path $logPath -Content 'stale-lock-recovered' -Append

        $lines = @(Get-Content -Path $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be 'stale-lock-recovered'
        (Test-Path -LiteralPath $lockDir -PathType Container) | Should -Be $false
    }

    It 'reclaims file locks when the owner pid has been reused by a different process instance' {
        $logPath = Join-Path $script:loggerTempRoot '.winsmux\logs\pid-reuse.jsonl'
        $lockDir = "$logPath.lock"
        $metadataPath = Join-Path $lockDir 'owner.json'

        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
        @"
{"pid":$PID,"started_at":"2000-01-01T00:00:00Z","process_started_at":"2000-01-01T00:00:00Z"}
"@ | Set-Content -Path $metadataPath -Encoding UTF8

        Write-WinsmuxTextFile -Path $logPath -Content 'pid-reuse-recovered' -Append

        $lines = @(Get-Content -Path $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be 'pid-reuse-recovered'
        (Test-Path -LiteralPath $lockDir -PathType Container) | Should -Be $false
    }

    It 'keeps CLM-safe writes on cmd-based lock and replace primitives' {
        $script:clmSafeIoContent | Should -Match 'function Get-WinsmuxFileLockDir'
        $script:clmSafeIoContent | Should -Match 'function Test-WinsmuxFileLockStale'
        $script:clmSafeIoContent | Should -Match 'function Get-WinsmuxProcessStartedAt'
        $script:clmSafeIoContent | Should -Match 'cmd /d /c \(''mkdir'
        $script:clmSafeIoContent | Should -Match 'cmd /d /c \(''move /y'
        $script:clmSafeIoContent | Should -Match 'owner\.json'
        $script:clmSafeIoContent | Should -Match 'process_started_at'
        $script:clmSafeIoContent | Should -Not -Match 'System\.Threading\.Mutex'
        $script:clmSafeIoContent | Should -Not -Match 'System\.IO\.File'
        $script:clmSafeIoContent | Should -Not -Match 'StreamWriter'
    }
}

Describe 'agent-monitor helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\agent-monitor.ps1')
    }

    BeforeEach {
        Mock Send-MonitorOperatorMailboxMessage { return $true }
    }

    It 'treats Codex context exhaustion followed by a PowerShell prompt as a crash reason' {
        Mock Invoke-MonitorWinsmux {
            @(
                'Error: context window exhausted for this session.'
                'Start a new conversation to continue.'
                'PS C:\repo>'
            )
        }

        $status = Get-PaneAgentStatus -PaneId '%2' -Agent 'codex'

        $status.Status | Should -Be 'crashed'
        $status.ExitReason | Should -Be 'context_exhausted'
    }

    It 'keeps normal Codex prompts in ready state even when context is low' {
        Mock Invoke-MonitorWinsmux {
            @(
                'gpt-5.4   0% context left'
                '⏎ send   Ctrl+J newline'
            )
        }

        $status = Get-PaneAgentStatus -PaneId '%2' -Agent 'codex'

        $status.Status | Should -Be 'ready'
        $status.ExitReason | Should -Be ''
    }

    It 'parses Codex context percentages from monitor capture text' {
        (Get-MonitorContextRemainingPercent -Text 'gpt-5.4   10% context left') | Should -Be 10
        (Get-MonitorContextRemainingPercent -Text 'gpt-5.4   · 8% left') | Should -Be 8
        (Get-MonitorContextRemainingPercent -Text '') | Should -BeNullOrEmpty
    }

    It 'respawns the pane in the launch directory before sending the agent command' {
        Mock Invoke-MonitorWinsmux { } -ParameterFilter {
            $Arguments[0] -eq 'respawn-pane'
        }
        Mock Wait-MonitorPaneShellReady { }
        Mock Send-MonitorBridgeCommand { }
        Mock Get-PaneAgentStatus {
            [PSCustomObject]@{
                Status       = 'ready'
                PaneId       = '%2'
                SnapshotTail = ''
                ExitReason   = ''
            }
        }

        $result = Invoke-AgentRespawn `
            -PaneId '%2' `
            -Agent 'codex' `
            -Model 'gpt-5.4' `
            -ProjectDir 'C:\repo\.worktrees\builder-1' `
            -GitWorktreeDir 'C:\repo\.git\worktrees\builder-1'

        $result.Success | Should -Be $true
        Should -Invoke Invoke-MonitorWinsmux -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'respawn-pane' -and
            $Arguments[1] -eq '-k' -and
            $Arguments[2] -eq '-t' -and
            $Arguments[3] -eq '%2' -and
            $Arguments[4] -eq '-c' -and
            $Arguments[5] -eq 'C:\repo\.worktrees\builder-1'
        }
        Should -Invoke Wait-MonitorPaneShellReady -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%2'
        }
        Should -Invoke Send-MonitorBridgeCommand -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%2' -and
            $Text -eq "codex -c model=gpt-5.4 --sandbox danger-full-access -C 'C:\repo\.worktrees\builder-1' --add-dir 'C:\repo\.git\worktrees\builder-1'"
        }
    }

    It 'uses provider capability adapters while waiting for respawn readiness' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
        $registryDir = Join-Path $tempRoot '.winsmux'

        try {
            New-Item -ItemType Directory -Path $registryDir -Force | Out-Null
@'
{
  "version": 1,
  "providers": {
    "codex-nightly": {
      "adapter": "codex",
      "command": "codex-nightly",
      "prompt_transports": ["argv", "file"],
      "supports_parallel_runs": true,
      "supports_interrupt": true,
      "supports_structured_result": true,
      "supports_file_edit": true,
      "supports_subagents": true,
      "supports_verification": true,
      "supports_consultation": false
    }
  }
}
'@ | Set-Content -Path (Join-Path $registryDir 'provider-capabilities.json') -Encoding UTF8

            Mock Invoke-MonitorWinsmux { } -ParameterFilter {
                $Arguments[0] -eq 'respawn-pane'
            }
            Mock Wait-MonitorPaneShellReady { }
            Mock Send-MonitorBridgeCommand { }
            Mock Get-PaneAgentStatus {
                [PSCustomObject]@{
                    Status       = 'ready'
                    PaneId       = '%2'
                    SnapshotTail = ''
                    ExitReason   = ''
                }
            }

            $result = Invoke-AgentRespawn `
                -PaneId '%2' `
                -Agent 'codex-nightly' `
                -Model 'gpt-5.4-nightly' `
                -ProjectDir $tempRoot `
                -GitWorktreeDir 'C:\repo\.git\worktrees\builder-1' `
                -RootPath $tempRoot `
                -ReadyTimeoutSeconds 5

            $result.Success | Should -Be $true
            Should -Invoke Send-MonitorBridgeCommand -Times 1 -Exactly -ParameterFilter {
                $PaneId -eq '%2' -and
                $Text -match '^codex-nightly -c model=gpt-5\.4-nightly'
            }
            Should -Invoke Get-PaneAgentStatus -Times 1 -Exactly -ParameterFilter {
                $PaneId -eq '%2' -and $Agent -eq 'codex'
            }
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'updates the manifest pane label after a successful respawn' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'

        try {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: $tempRoot
"@ | Set-Content -Path $manifestPath -Encoding UTF8

            Mock Invoke-MonitorWinsmux { } -ParameterFilter {
                $Arguments[0] -eq 'respawn-pane'
            }
            Mock Invoke-MonitorWinsmux { 'builder-2' } -ParameterFilter {
                $Arguments[0] -eq 'display-message'
            }
            Mock Wait-MonitorPaneShellReady { }
            Mock Send-MonitorBridgeCommand { }
            Mock Get-PaneAgentStatus {
                [PSCustomObject]@{
                    Status       = 'ready'
                    PaneId       = '%2'
                    SnapshotTail = ''
                    ExitReason   = ''
                }
            }

            $result = Invoke-AgentRespawn `
                -PaneId '%2' `
                -Agent 'codex' `
                -Model 'gpt-5.4' `
                -ProjectDir $tempRoot `
                -GitWorktreeDir 'C:\repo\.git\worktrees\builder-1' `
                -ManifestPath $manifestPath

            $result.Success | Should -Be $true
            $manifestContent = Get-Content -Path $manifestPath -Raw -Encoding UTF8
        $manifestContent | Should -Match $([regex]::Escape("'builder-2':"))
            $manifestContent | Should -Not -Match $([regex]::Escape("  - label: 'builder-1'"))
            Should -Invoke Invoke-MonitorWinsmux -Times 1 -Exactly -ParameterFilter {
                $Arguments[0] -eq 'display-message' -and
                $Arguments[1] -eq '-p' -and
                $Arguments[2] -eq '-t' -and
                $Arguments[3] -eq '%2' -and
                $Arguments[4] -eq '#{pane_title}'
            }
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'writes completion and crash events during a monitor cycle' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'
        $eventsPath = Join-Path $manifestDir 'events.jsonl'

        try {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
  - label: reviewer
    pane_id: %4
    role: Reviewer
"@ | Set-Content -Path $manifestPath -Encoding UTF8

            Mock Get-PaneAgentStatus {
                [PSCustomObject]@{
                    Status       = 'ready'
                    PaneId       = '%2'
                    SnapshotTail = ''
                    SnapshotHash = 'hash-builder'
                    ExitReason   = 'exec_completed'
                }
            } -ParameterFilter {
                $PaneId -eq '%2'
            }
            Mock Get-PaneAgentStatus {
                [PSCustomObject]@{
                    Status       = 'crashed'
                    PaneId       = '%4'
                    SnapshotTail = ''
                    SnapshotHash = 'hash-reviewer'
                    ExitReason   = 'context_exhausted'
                }
            } -ParameterFilter {
                $PaneId -eq '%4'
            }
            Mock Update-MonitorIdleAlertState {
                [ordered]@{
                    ShouldAlert = $false
                    Message     = ''
                }
            }
            Mock Test-BuilderStall { $false }
            Mock Invoke-AgentRespawn {
                param($PaneId, $Agent, $Model, $ProjectDir, $GitWorktreeDir, $ManifestPath)

                [PSCustomObject]@{
                    Success = $true
                    PaneId  = $PaneId
                    Message = "respawned $PaneId"
                }
            }

            $result = Invoke-AgentMonitorCycle -Settings ([ordered]@{
                agent = 'codex'
                model = 'gpt-5.4'
                roles = [ordered]@{}
            }) -ManifestPath $manifestPath -SessionName 'winsmux-orchestra'

            $result.Crashed | Should -Be 2
            (Test-Path $eventsPath) | Should -Be $true

            $events = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
            $events.Count | Should -Be 2
            $events[0].event | Should -Be 'pane.completed'
            $events[0].pane_id | Should -Be '%2'
            $events[0].exit_reason | Should -Be 'exec_completed'
            $events[1].event | Should -Be 'pane.crashed'
            $events[1].pane_id | Should -Be '%4'
            $events[1].exit_reason | Should -Be 'context_exhausted'
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'uses slot-level agent and model overrides during a monitor cycle' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'

        try {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  worker-2:
    pane_id: %4
    role: Worker
    launch_dir: $tempRoot
"@ | Set-Content -Path $manifestPath -Encoding UTF8

            Mock Get-PaneAgentStatus {
                [PSCustomObject]@{
                    Status       = 'ready'
                    PaneId       = '%4'
                    SnapshotTail = ''
                    SnapshotHash = 'hash-worker'
                    ExitReason   = ''
                }
            }
            Mock Update-MonitorIdleAlertState {
                [ordered]@{
                    ShouldAlert = $false
                    Message     = ''
                }
            }
            Mock Test-BuilderStall { $false }
            Mock Invoke-AgentRespawn {
                [PSCustomObject]@{
                    Success = $true
                    PaneId  = '%4'
                    Message = 'respawned'
                }
            }

            Invoke-AgentMonitorCycle -Settings ([ordered]@{
                agent = 'codex'
                model = 'gpt-5.4'
                roles = [ordered]@{
                    worker = [ordered]@{
                        agent = 'codex'
                        model = 'gpt-5.4'
                    }
                }
                agent_slots = @(
                    [ordered]@{
                        slot_id = 'worker-2'
                        runtime_role = 'worker'
                        agent = 'claude'
                        model = 'sonnet'
                    }
                )
            }) -ManifestPath $manifestPath -SessionName 'winsmux-orchestra' | Out-Null

            Should -Invoke Get-PaneAgentStatus -Times 1 -Exactly -ParameterFilter {
                $PaneId -eq '%4' -and $Agent -eq 'claude' -and $Role -eq 'Worker'
            }
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'uses provider registry overrides during a monitor cycle' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'

        try {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  worker-2:
    pane_id: %4
    role: Worker
    launch_dir: $tempRoot
"@ | Set-Content -Path $manifestPath -Encoding UTF8
            Write-BridgeProviderRegistryEntry `
                -RootPath $tempRoot `
                -SlotId 'worker-2' `
                -Agent 'claude' `
                -Model 'opus' `
                -PromptTransport 'file' `
                -Reason 'operator requested provider hot-swap' | Out-Null

            Mock Get-PaneAgentStatus {
                [PSCustomObject]@{
                    Status       = 'ready'
                    PaneId       = '%4'
                    SnapshotTail = ''
                    SnapshotHash = 'hash-worker'
                    ExitReason   = ''
                }
            }
            Mock Update-MonitorIdleAlertState {
                [ordered]@{
                    ShouldAlert = $false
                    Message     = ''
                }
            }
            Mock Test-BuilderStall { $false }

            Invoke-AgentMonitorCycle -Settings ([ordered]@{
                agent = 'codex'
                model = 'gpt-5.4'
                roles = [ordered]@{
                    worker = [ordered]@{
                        agent = 'codex'
                        model = 'gpt-5.4'
                    }
                }
                agent_slots = @(
                    [ordered]@{
                        slot_id = 'worker-2'
                        runtime_role = 'worker'
                        agent = 'codex'
                        model = 'gpt-5.4'
                    }
                )
            }) -ManifestPath $manifestPath -SessionName 'winsmux-orchestra' | Out-Null

            Should -Invoke Get-PaneAgentStatus -Times 1 -Exactly -ParameterFilter {
                $PaneId -eq '%4' -and $Agent -eq 'claude' -and $Role -eq 'Worker'
            }
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'uses provider capability adapters during a monitor cycle' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'

        try {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  worker-2:
    pane_id: %4
    role: Worker
    launch_dir: $tempRoot
"@ | Set-Content -Path $manifestPath -Encoding UTF8
@'
{
  "version": 1,
  "providers": {
    "codex-nightly": {
      "adapter": "codex",
      "command": "codex-nightly",
      "prompt_transports": ["argv"],
      "supports_parallel_runs": true,
      "supports_interrupt": true,
      "supports_structured_result": true,
      "supports_file_edit": true,
      "supports_subagents": true,
      "supports_verification": true,
      "supports_consultation": false
    }
  }
}
'@ | Set-Content -Path (Join-Path $manifestDir 'provider-capabilities.json') -Encoding UTF8
            Write-BridgeProviderRegistryEntry `
                -RootPath $tempRoot `
                -SlotId 'worker-2' `
                -Agent 'codex-nightly' `
                -Model 'gpt-5.4-nightly' `
                -PromptTransport 'argv' `
                -Reason 'operator requested provider hot-swap' | Out-Null

            Mock Get-PaneAgentStatus {
                [PSCustomObject]@{
                    Status       = 'ready'
                    PaneId       = '%4'
                    SnapshotTail = 'gpt-5.4   42% context left'
                    SnapshotHash = 'hash-worker'
                    ExitReason   = ''
                }
            }
            Mock Update-MonitorIdleAlertState {
                [ordered]@{
                    ShouldAlert = $false
                    Message     = ''
                }
            }
            Mock Test-BuilderStall { $false }

            Invoke-AgentMonitorCycle -Settings ([ordered]@{
                agent = 'codex'
                model = 'gpt-5.4'
                roles = [ordered]@{
                    worker = [ordered]@{
                        agent = 'codex'
                        model = 'gpt-5.4'
                    }
                }
                agent_slots = @(
                    [ordered]@{
                        slot_id = 'worker-2'
                        runtime_role = 'worker'
                        agent = 'codex'
                        model = 'gpt-5.4'
                    }
                )
            }) -ManifestPath $manifestPath -SessionName 'winsmux-orchestra' | Out-Null

            Should -Invoke Get-PaneAgentStatus -Times 1 -Exactly -ParameterFilter {
                $PaneId -eq '%4' -and $Agent -eq 'codex' -and $Role -eq 'Worker'
            }
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'fails closed when the provider registry is malformed during a monitor cycle' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'
        $registryPath = Join-Path $manifestDir 'provider-registry.json'

        try {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  worker-2:
    pane_id: %4
    role: Worker
    launch_dir: $tempRoot
"@ | Set-Content -Path $manifestPath -Encoding UTF8
            '{ invalid json' | Set-Content -Path $registryPath -Encoding UTF8

            Mock Get-PaneAgentStatus {
                throw 'Get-PaneAgentStatus should not be called when provider registry is malformed.'
            }
            Mock Update-MonitorIdleAlertState { throw 'Update-MonitorIdleAlertState should not be called.' }
            Mock Test-BuilderStall { throw 'Test-BuilderStall should not be called.' }

            {
                Invoke-AgentMonitorCycle -Settings ([ordered]@{
                    agent = 'codex'
                    model = 'gpt-5.4'
                    roles = [ordered]@{
                        worker = [ordered]@{
                            agent = 'codex'
                            model = 'gpt-5.4'
                        }
                    }
                }) -ManifestPath $manifestPath -SessionName 'winsmux-orchestra'
            } | Should -Throw "*Invalid provider registry JSON*"
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'fails closed when the provider registry structure is invalid during a monitor cycle' {
        $cases = @(
            [PSCustomObject]@{
                Name = 'slots array'
                Body = @'
{
  "version": 1,
  "slots": []
}
'@
                Message = '*provider registry slots*'
            },
            [PSCustomObject]@{
                Name = 'scalar slot entry'
                Body = @'
{
  "version": 1,
  "slots": {
    "worker-2": "claude"
  }
}
'@
                Message = "*provider registry slot 'worker-2'*"
            },
            [PSCustomObject]@{
                Name = 'metadata-only slot entry'
                Body = @'
{
  "version": 1,
  "slots": {
    "worker-2": {
      "updated_at_utc": "2026-04-21T00:00:00Z",
      "reason": "metadata only"
    }
  }
}
'@
                Message = "*provider registry slot 'worker-2'*"
            },
            [PSCustomObject]@{
                Name = 'non-scalar provider field'
                Body = @'
{
  "version": 1,
  "slots": {
    "worker-2": {
      "agent": {
        "name": "claude"
      },
      "model": "opus"
    }
  }
}
'@
                Message = "*provider registry field 'agent'*"
            }
        )

        foreach ($case in $cases) {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
            $manifestDir = Join-Path $tempRoot '.winsmux'
            $manifestPath = Join-Path $manifestDir 'manifest.yaml'
            $registryPath = Join-Path $manifestDir 'provider-registry.json'

            try {
                New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  worker-2:
    pane_id: %4
    role: Worker
    launch_dir: $tempRoot
"@ | Set-Content -Path $manifestPath -Encoding UTF8
                $case.Body | Set-Content -Path $registryPath -Encoding UTF8

                Mock Get-PaneAgentStatus {
                    throw "Get-PaneAgentStatus should not be called for malformed provider registry case '$($case.Name)'."
                }
                Mock Update-MonitorIdleAlertState { throw 'Update-MonitorIdleAlertState should not be called.' }
                Mock Test-BuilderStall { throw 'Test-BuilderStall should not be called.' }

                {
                    Invoke-AgentMonitorCycle -Settings ([ordered]@{
                        agent = 'codex'
                        model = 'gpt-5.4'
                        roles = [ordered]@{
                            worker = [ordered]@{
                                agent = 'codex'
                                model = 'gpt-5.4'
                            }
                        }
                    }) -ManifestPath $manifestPath -SessionName 'winsmux-orchestra'
                } | Should -Throw $case.Message
            } finally {
                if (Test-Path $tempRoot) {
                    Remove-Item -Path $tempRoot -Recurse -Force
                }
            }
        }
    }

    It 'writes state, idle, and stalled events for detected pane states during a monitor cycle' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'
        $eventsPath = Join-Path $manifestDir 'events.jsonl'

        try {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
  - label: reviewer-1
    pane_id: %3
    role: Reviewer
  - label: builder-2
    pane_id: %4
    role: Builder
  - label: researcher-1
    pane_id: %5
    role: Researcher
  - label: reviewer-2
    pane_id: %6
    role: Reviewer
  - label: builder-3
    pane_id: %7
    role: Builder
"@ | Set-Content -Path $manifestPath -Encoding UTF8

            Mock Get-PaneAgentStatus {
                switch ($PaneId) {
                    '%2' {
                        return [ordered]@{
                            Status       = 'ready'
                            PaneId       = '%2'
                            SnapshotTail = '> '
                            SnapshotHash = 'hash-ready'
                            ExitReason   = ''
                        }
                    }
                    '%3' {
                        return [ordered]@{
                            Status       = 'approval_waiting'
                            PaneId       = '%3'
                            SnapshotTail = 'approval'
                            SnapshotHash = 'hash-approval'
                            ExitReason   = ''
                        }
                    }
                    '%4' {
                        return [ordered]@{
                            Status       = 'busy'
                            PaneId       = '%4'
                            SnapshotTail = 'working'
                            SnapshotHash = 'hash-busy'
                            ExitReason   = ''
                        }
                    }
                    '%5' {
                        return [ordered]@{
                            Status       = 'waiting_for_dispatch'
                            PaneId       = '%5'
                            SnapshotTail = 'PS C:\repo>'
                            SnapshotHash = 'hash-dispatch'
                            ExitReason   = ''
                        }
                    }
                    '%6' {
                        return [ordered]@{
                            Status       = 'hung'
                            PaneId       = '%6'
                            SnapshotTail = 'same output'
                            SnapshotHash = 'hash-hung'
                            ExitReason   = ''
                        }
                    }
                    '%7' {
                        return [ordered]@{
                            Status       = 'empty'
                            PaneId       = '%7'
                            SnapshotTail = ''
                            SnapshotHash = ''
                            ExitReason   = ''
                        }
                    }
                    default {
                        throw "unexpected pane id: $PaneId"
                    }
                }
            }
            Mock Update-MonitorIdleAlertState {
                if ($PaneId -eq '%2') {
                    return [ordered]@{
                        ShouldAlert = $true
                        Message     = 'Operator alert: idle pane builder-1 (%2, role=Builder)'
                    }
                }

                return [ordered]@{
                    ShouldAlert = $false
                    Message     = ''
                }
            }
            Mock Test-BuilderStall {
                return $PaneId -eq '%4'
            }
            $output = @(Invoke-AgentMonitorCycle -Settings ([ordered]@{
                agent = 'codex'
                model = 'gpt-5.4'
                roles = [ordered]@{}
            }) -ManifestPath $manifestPath -SessionName 'winsmux-orchestra' -IdleThreshold 120)
            $result = $output[-1]

            $result.Checked | Should -Be 6
            $result.Crashed | Should -Be 0
            $result.ApprovalWaiting | Should -Be 1
            $result.IdleAlerts | Should -Be 1
            $result.Stalls | Should -Be 1

            $events = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
            $eventNames = @($events | ForEach-Object { $_.event })

            $eventNames.Count | Should -Be 8
            $eventNames | Should -Be @(
                'pane.ready',
                'pane.idle',
                'pane.approval_waiting',
                'pane.busy',
                'pane.stalled',
                'pane.waiting_for_dispatch',
                'pane.hung',
                'pane.empty'
            )
            $events[1].data.idle_threshold_seconds | Should -Be 120
            $events[4].data.required_cycles | Should -Be 3
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'emits pane.completed when a busy pane returns to waiting_for_dispatch' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'

        try {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    exec_mode: true
"@ | Set-Content -Path (Join-Path $manifestDir 'manifest.yaml') -Encoding UTF8

        Mock Get-PaneAgentStatus {
            [ordered]@{
                Status       = 'waiting_for_dispatch'
                PaneId       = '%2'
                SnapshotTail = 'PS C:\repo>'
                SnapshotHash = 'hash-dispatch'
                ExitReason   = ''
            }
        }
        Mock Write-MonitorEvent {
            return [ordered]@{
                event   = $Event
                pane_id = $PaneId
                status  = $Status
            }
        }
        Mock Update-MonitorIdleAlertState {
            [ordered]@{
                ShouldAlert = $false
                Message     = ''
            }
        }
        Mock Test-BuilderStall { $false }

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            roles = [ordered]@{}
        }
        $previousResults = [ordered]@{
            '%2' = 'busy'
        }

        $result = Invoke-AgentMonitorCycle -Settings $settings -ManifestPath (Join-Path $manifestDir 'manifest.yaml') -SessionName 'winsmux-orchestra' -PreviousResults $previousResults

        $result.CurrentResults['%2'] | Should -Be 'waiting_for_dispatch'
        Should -Invoke Write-MonitorEvent -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'pane.completed' -and
            $PaneId -eq '%2' -and
            $Role -eq 'Builder' -and
            $Status -eq 'waiting_for_dispatch'
        }
        Should -Invoke Write-MonitorEvent -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'pane.waiting_for_dispatch' -and
            $PaneId -eq '%2'
        }
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'skips relaunch dispatch for exec_mode Researcher panes' {
        $manifestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestPath = Join-Path $manifestRoot 'manifest.yaml'
        New-Item -ItemType Directory -Path $manifestRoot -Force | Out-Null

        try {
            @'
version: 1
saved_at: '2026-04-07T00:00:00+09:00'
session:
  name: 'winsmux-orchestra'
  project_dir: 'C:\repo'
  git_worktree_dir: 'C:\repo\.git'
panes:
  - label: 'researcher-1'
    pane_id: '%3'
    role: 'Researcher'
    exec_mode: true
    launch_dir: 'C:\repo'
    builder_branch: null
    builder_worktree_path: null
    task: null
'@ | Set-Content -Path $manifestPath -Encoding UTF8

            Mock Invoke-MonitorWinsmux { } -ParameterFilter {
                $Arguments[0] -eq 'respawn-pane'
            }
            Mock Wait-MonitorPaneShellReady { }
            Mock Send-MonitorBridgeCommand { }
            Mock Get-PaneAgentStatus {
                [PSCustomObject]@{
                    Status       = 'ready'
                    PaneId       = '%3'
                    SnapshotTail = ''
                    ExitReason   = ''
                }
            }

            $result = Invoke-AgentRespawn `
                -PaneId '%3' `
                -Agent 'codex' `
                -Model 'gpt-5.4' `
                -ProjectDir 'C:\repo' `
                -GitWorktreeDir 'C:\repo\.git' `
                -ManifestPath $manifestPath

            $result.Success | Should -Be $true
            $result.Message | Should -Match 'exec_mode'
            Should -Invoke Send-MonitorBridgeCommand -Times 0 -Exactly
        } finally {
            if (Test-Path $manifestRoot) {
                Remove-Item -Path $manifestRoot -Recurse -Force
            }
        }
    }

    It 'detects a stalled Builder after three busy cycles with the same snapshot hash' {
        $script:BuilderStallHistory = @{}

        (Test-BuilderStall -PaneId '%2' -Role 'Builder' -Status 'busy' -SnapshotHash 'hash-1') | Should -Be $false
        (Test-BuilderStall -PaneId '%2' -Role 'Builder' -Status 'busy' -SnapshotHash 'hash-1') | Should -Be $false
        (Test-BuilderStall -PaneId '%2' -Role 'Builder' -Status 'busy' -SnapshotHash 'hash-1') | Should -Be $true
    }

    It 'resets Builder stall history when the pane is no longer busy' {
        $script:BuilderStallHistory = @{}

        Test-BuilderStall -PaneId '%2' -Role 'Builder' -Status 'busy' -SnapshotHash 'hash-1' | Out-Null
        Test-BuilderStall -PaneId '%2' -Role 'Builder' -Status 'busy' -SnapshotHash 'hash-1' | Out-Null
        (Test-BuilderStall -PaneId '%2' -Role 'Builder' -Status 'ready' -SnapshotHash 'hash-1') | Should -Be $false
        (Test-BuilderStall -PaneId '%2' -Role 'Builder' -Status 'busy' -SnapshotHash 'hash-1') | Should -Be $false
    }

    It 'resets Codex context at the configured threshold using /new' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'
        $eventsPath = Join-Path $manifestDir 'events.jsonl'

        try {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: $tempRoot
"@ | Set-Content -Path $manifestPath -Encoding UTF8

            Mock Get-PaneAgentStatus {
                [ordered]@{
                    Status       = 'ready'
                    PaneId       = '%2'
                    SnapshotTail = @"
gpt-5.4   10% context left
>
"@
                    SnapshotHash = 'hash-builder'
                    ExitReason   = ''
                }
            }
            Mock Send-MonitorBridgeCommand { }
            Mock Update-MonitorIdleAlertState {
                [ordered]@{
                    ShouldAlert = $false
                    Message     = ''
                }
            }
            Mock Test-BuilderStall { $false }

            $result = Invoke-AgentMonitorCycle -Settings ([ordered]@{
                agent = 'codex'
                model = 'gpt-5.4'
                roles = [ordered]@{}
            }) -ManifestPath $manifestPath -SessionName 'winsmux-orchestra'

            $result.ContextResets | Should -Be 1
            $result.Results.Count | Should -Be 1
            $result.Results[0].ContextReset | Should -Be $true
            $result.Results[0].ContextRemainingPercent | Should -Be 10
            Should -Invoke Send-MonitorBridgeCommand -Times 1 -Exactly -ParameterFilter {
                $PaneId -eq '%2' -and $Text -eq '/new'
            }
            Should -Invoke Send-MonitorBridgeCommand -Times 0 -Exactly -ParameterFilter {
                $Text -eq '/clear'
            }

            $events = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
            $events.Count | Should -Be 2
            $events[0].event | Should -Be 'pane.ready'
            $events[1].event | Should -Be 'pane.context_reset'
            $events[1].data.command | Should -Be '/new'
            $events[1].data.context_remaining_percent | Should -Be 10
            $events[1].data.threshold_percent | Should -Be 10
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'syncs task review git state into manifest and monitor events' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'
        $eventsPath = Join-Path $manifestDir 'events.jsonl'
        $reviewStatePath = Join-Path $manifestDir 'review-state.json'

        try {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    exec_mode: true
    builder_branch: worktree-builder-1
    builder_worktree_path: $tempRoot
tasks:
  queued: []
  in_progress:
    - 'id=task-243;builder=builder-1;task=Implement%20TASK-243'
  completed: []
"@ | Set-Content -Path $manifestPath -Encoding UTF8

@'
{
  "worktree-builder-1": {
    "status": "PENDING",
    "request": {
      "target_review_label": "reviewer",
      "target_review_pane_id": "%3"
    }
  }
}
'@ | Set-Content -Path $reviewStatePath -Encoding UTF8

            Mock Get-OrchestraGitSnapshot {
                [ordered]@{
                    branch             = 'worktree-builder-1'
                    head_sha           = 'abc1234def5678'
                    changed_file_count = 2
                    changed_files      = @(
                        'winsmux-core/scripts/orchestra-state.ps1',
                        'winsmux-core/scripts/agent-monitor.ps1'
                    )
                }
            }
            Mock Get-PaneAgentStatus {
                [ordered]@{
                    Status       = 'ready'
                    PaneId       = '%2'
                    SnapshotTail = 'gpt-5.4   74% context left'
                    SnapshotHash = 'hash-ready'
                    ExitReason   = ''
                }
            }
            Mock Update-MonitorIdleAlertState {
                [ordered]@{
                    ShouldAlert = $false
                    Message     = ''
                }
            }
            Mock Test-BuilderStall { $false }

            $result = Invoke-AgentMonitorCycle -Settings ([ordered]@{
                agent = 'codex'
                model = 'gpt-5.4'
                roles = [ordered]@{}
            }) -ManifestPath $manifestPath -SessionName 'winsmux-orchestra'

            $result.Checked | Should -Be 1
            $entries = @(Get-PaneControlManifestEntries -ProjectDir $tempRoot)
            $entries.Count | Should -Be 1
            $entries[0].TaskId | Should -Be 'task-243'
            $entries[0].Task | Should -Be 'Implement TASK-243'
            $entries[0].TaskState | Should -Be 'in_progress'
            $entries[0].TaskOwner | Should -Be 'builder-1'
            $entries[0].ReviewState | Should -Be 'PENDING'
            $entries[0].Branch | Should -Be 'worktree-builder-1'
            $entries[0].HeadSha | Should -Be 'abc1234def5678'
            $entries[0].ChangedFileCount | Should -Be 2
            $entries[0].ChangedFiles | Should -Be @(
                'winsmux-core/scripts/orchestra-state.ps1',
                'winsmux-core/scripts/agent-monitor.ps1'
            )

            $events = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
            $events.Count | Should -Be 1
            $events[0].event | Should -Be 'pane.ready'
            $events[0].data.task.id | Should -Be 'task-243'
            $events[0].data.task.text | Should -Be 'Implement TASK-243'
            $events[0].data.task.state | Should -Be 'in_progress'
            $events[0].data.task.owner | Should -Be 'builder-1'
            $events[0].data.git.branch | Should -Be 'worktree-builder-1'
            $events[0].data.git.head_sha | Should -Be 'abc1234def5678'
            $events[0].data.git.changed_file_count | Should -Be 2
            $events[0].data.git.changed_files | Should -Be @(
                'winsmux-core/scripts/orchestra-state.ps1',
                'winsmux-core/scripts/agent-monitor.ps1'
            )
            $events[0].data.review.state | Should -Be 'PENDING'
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }
}

Describe 'agent-watchdog helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\agent-watchdog.ps1')
    }

    It 'runs a watchdog cycle through Invoke-AgentMonitorCycle with the requested thresholds' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-watchdog-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  worker-1:
    pane_id: %2
    role: Worker
"@ | Set-Content -Path $manifestPath -Encoding UTF8

        Mock Get-BridgeSettings {
            [ordered]@{
                agent = 'codex'
                model = 'gpt-5.4'
                roles = [ordered]@{}
            }
        }
        Mock Invoke-AgentMonitorCycle {
            [PSCustomObject]@{
                Checked   = 1
                Crashed   = 0
                Respawned = 0
                IdleAlerts = 0
                Stalls    = 0
                Results   = @()
            }
        }

        try {
            $result = Invoke-AgentWatchdogCycle -ManifestPath $manifestPath -SessionName 'winsmux-orchestra' -IdleThreshold 120

            $result.Checked | Should -Be 1
            Should -Invoke Get-BridgeSettings -Times 1 -Exactly -ParameterFilter {
                $RootPath -eq $tempRoot
            }
            Should -Invoke Invoke-AgentMonitorCycle -Times 1 -Exactly -ParameterFilter {
                $ManifestPath -eq $manifestPath -and
                $SessionName -eq 'winsmux-orchestra' -and
                $IdleThreshold -eq 120
            }
        } finally {
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'carries previous pane states across watchdog cycles' {
        $script:watchdogCycleCount = 0
        $script:watchdogPreviousStates = @()
        $script:watchdogSleepCalls = 0

        Mock Invoke-AgentWatchdogCycle {
            param($ManifestPath, $SessionName, $IdleThreshold, $PreviousResults)

            $capturedPreviousResults = [ordered]@{}
            if ($null -ne $PreviousResults) {
                foreach ($entry in $PreviousResults.GetEnumerator()) {
                    $capturedPreviousResults[$entry.Key] = $entry.Value
                }
            }
            $script:watchdogPreviousStates += ,$capturedPreviousResults
            $script:watchdogCycleCount++

            if ($script:watchdogCycleCount -eq 1) {
                return [ordered]@{
                    Checked         = 1
                    Crashed         = 0
                    Respawned       = 0
                    ApprovalWaiting = 0
                    IdleAlerts      = 0
                    Stalls          = 0
                    CurrentResults  = [ordered]@{ '%2' = 'busy' }
                    Results         = @()
                }
            }

            return [ordered]@{
                Checked         = 1
                Crashed         = 0
                Respawned       = 0
                ApprovalWaiting = 0
                IdleAlerts      = 0
                Stalls          = 0
                CurrentResults  = [ordered]@{ '%2' = 'waiting_for_dispatch' }
                Results         = @()
            }
        }
        Mock Start-Sleep {
            $script:watchdogSleepCalls++
            if ($script:watchdogSleepCalls -ge 2) {
                throw 'stop-loop'
            }
        }

        $stopLoopThrown = $false
        try {
            Start-AgentWatchdogLoop -ManifestPath 'C:\repo\.winsmux\manifest.yaml' -SessionName 'winsmux-orchestra' -IdleThreshold 120 -PollInterval 1
        } catch {
            $stopLoopThrown = $_.Exception.Message -eq 'stop-loop'
        }

        $stopLoopThrown | Should -Be $true
        $script:watchdogPreviousStates.Count | Should -Be 2
        $script:watchdogPreviousStates[0].Count | Should -Be 0
        $script:watchdogPreviousStates[1]['%2'] | Should -Be 'busy'
    }

    It 'builds a stdout summary that points to events.jsonl' {
        $summary = Get-AgentWatchdogSummary -CycleResult ([ordered]@{
            Checked         = 2
            Crashed         = 1
            Respawned       = 1
            ApprovalWaiting = 1
            IdleAlerts      = 1
            Stalls          = 1
            Results         = @(
                [ordered]@{
                    Label      = 'builder-1'
                    PaneId     = '%2'
                    Status     = 'busy'
                    ExitReason = ''
                    Respawned  = $false
                    Message    = ''
                }
            )
        }) -ManifestPath 'C:\repo\.winsmux\manifest.yaml' -SessionName 'winsmux-orchestra'

        $summary.session | Should -Be 'winsmux-orchestra'
        $summary.events_path | Should -Be 'C:\repo\.winsmux\events.jsonl'
        $summary.checked | Should -Be 2
        $summary.approval_waiting | Should -Be 1
        $summary.idle_alerts | Should -Be 1
        $summary.stalls | Should -Be 1
        $summary.results.Count | Should -Be 1
        $summary.results[0].Label | Should -Be 'builder-1'
    }
}

Describe 'server-watchdog helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\server-watchdog.ps1')
    }

    BeforeEach {
        $script:serverWatchdogTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-server-watchdog-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:serverWatchdogTempRoot '.winsmux') -Force | Out-Null
        $script:serverWatchdogManifestPath = Join-Path $script:serverWatchdogTempRoot '.winsmux\manifest.yaml'
        Write-PsmuxBridgeTestFile -Path $script:serverWatchdogManifestPath -Content @"
version: 1
saved_at: 2026-04-07T00:00:00+09:00
session:
  name: 'winsmux-orchestra'
  project_dir: '$script:serverWatchdogTempRoot'
"@
    }

    AfterEach {
        if ($script:serverWatchdogTempRoot -and (Test-Path $script:serverWatchdogTempRoot)) {
            Remove-Item -Path $script:serverWatchdogTempRoot -Recurse -Force
        }
    }

    It 'detects a missing session and restarts it' {
        $state = New-ServerWatchdogState

        Mock Get-ServerWatchdogHealthStatus { 'Missing' }

        Mock Invoke-ServerWatchdogWinsmux {
            [ordered]@{
                ExitCode = 0
                Output   = @()
            }
        } -ParameterFilter {
            $AllowFailure -and
            $Arguments[0] -eq 'new-session' -and
            $Arguments[1] -eq '-d' -and
            $Arguments[2] -eq '-s' -and
            $Arguments[3] -eq 'winsmux-orchestra'
        }

        $result = Invoke-ServerWatchdogCycle -ManifestPath $script:serverWatchdogManifestPath -SessionName 'winsmux-orchestra' -State $state

        $result.SessionAlive | Should -Be $false
        $result.RestartAttempted | Should -Be $true
        $result.RestartSucceeded | Should -Be $true
        $result.Event | Should -Be 'server.restarted'
        $state.RestartAttempts.Count | Should -Be 1

        $eventsPath = Join-Path $script:serverWatchdogTempRoot '.winsmux\events.jsonl'
        $events = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $events.Count | Should -Be 1
        $events[0].event | Should -Be 'server.restarted'
        $events[0].status | Should -Be 'restarted'
        $events[0].exit_reason | Should -Be 'session_missing'
        $events[0].data.health_status | Should -Be 'Missing'
    }

    It 'logs restart failures when restart attempt fails' {
        $state = New-ServerWatchdogState

        Mock Get-ServerWatchdogHealthStatus { 'Missing' }

        Mock Invoke-ServerWatchdogWinsmux {
            [ordered]@{
                ExitCode = 1
                Output   = @('cannot start')
            }
        } -ParameterFilter {
            $AllowFailure -and $Arguments[0] -eq 'new-session'
        }

        $result = Invoke-ServerWatchdogCycle -ManifestPath $script:serverWatchdogManifestPath -SessionName 'winsmux-orchestra' -State $state

        $result.RestartAttempted | Should -Be $true
        $result.RestartSucceeded | Should -Be $false
        $result.Event | Should -Be 'server.restart_failed'
        $state.RestartAttempts.Count | Should -Be 1

        $eventsPath = Join-Path $script:serverWatchdogTempRoot '.winsmux\events.jsonl'
        $events = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $events.Count | Should -Be 1
        $events[0].event | Should -Be 'server.restart_failed'
        $events[0].exit_reason | Should -Be 'restart_failed'
        $events[0].data.restart_output | Should -Be 'cannot start'
        $events[0].data.health_status | Should -Be 'Missing'
    }

    It 'treats unhealthy strict health as a restartable server failure' {
        $state = New-ServerWatchdogState

        Mock Get-ServerWatchdogHealthStatus { 'Unhealthy' }
        Mock Invoke-ServerWatchdogWinsmux {
            [ordered]@{
                ExitCode = 0
                Output   = @()
            }
        } -ParameterFilter {
            $AllowFailure -and $Arguments[0] -eq 'new-session'
        }

        $result = Invoke-ServerWatchdogCycle -ManifestPath $script:serverWatchdogManifestPath -SessionName 'winsmux-orchestra' -State $state

        $result.RestartAttempted | Should -Be $true
        $result.RestartSucceeded | Should -Be $true
        $result.HealthStatus | Should -Be 'Unhealthy'

        $eventsPath = Join-Path $script:serverWatchdogTempRoot '.winsmux\events.jsonl'
        $events = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $events[0].exit_reason | Should -Be 'healthcheck_failed'
        $events[0].data.health_status | Should -Be 'Unhealthy'
    }

    It 'enters degraded state after three restart attempts in ten minutes' {
        $state = New-ServerWatchdogState
        $now = Get-Date
        $state['RestartAttempts'] = @(
            $now.AddMinutes(-9).ToString('o'),
            $now.AddMinutes(-5).ToString('o'),
            $now.AddMinutes(-1).ToString('o')
        )

        Mock Get-ServerWatchdogHealthStatus { 'Missing' }
        Mock Invoke-ServerWatchdogWinsmux {
            throw 'restart should not be attempted while degraded'
        } -ParameterFilter {
            $Arguments[0] -eq 'new-session'
        }

        $result = Invoke-ServerWatchdogCycle -ManifestPath $script:serverWatchdogManifestPath -SessionName 'winsmux-orchestra' -State $state

        $result.RestartAttempted | Should -Be $false
        $result.Degraded | Should -Be $true
        $result.Event | Should -Be 'server.restart_failed'
        $state.Degraded | Should -Be $true
        Should -Invoke Invoke-ServerWatchdogWinsmux -Times 0 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'new-session'
        }

        $eventsPath = Join-Path $script:serverWatchdogTempRoot '.winsmux\events.jsonl'
        $events = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $events.Count | Should -Be 1
        $events[0].event | Should -Be 'server.restart_failed'
        $events[0].status | Should -Be 'degraded'
        $events[0].exit_reason | Should -Be 'crash_loop_protection'
        $events[0].data.attempt_count | Should -Be 3
        $events[0].data.health_status | Should -Be 'Missing'
    }

    It 'passes expected pane count from the manifest into strict health checks' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                panes = [ordered]@{
                    'worker-1' = [ordered]@{}
                    'worker-2' = [ordered]@{}
                }
            }
        }
        Mock Get-WinsmuxBin { 'winsmux' }
        Mock Test-OrchestraServerHealth { 'Unhealthy' } -ParameterFilter {
            $SessionName -eq 'winsmux-orchestra' -and $ExpectedPaneCount -eq 2
        }

        $status = Get-ServerWatchdogHealthStatus -SessionName 'winsmux-orchestra' -ManifestPath $script:serverWatchdogManifestPath

        $status | Should -Be 'Unhealthy'
        Should -Invoke Test-OrchestraServerHealth -Times 1 -Exactly -ParameterFilter {
            $SessionName -eq 'winsmux-orchestra' -and $ExpectedPaneCount -eq 2
        }
    }

    It 'returns unhealthy health when the manifest is missing during reset' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq $script:serverWatchdogManifestPath }
        Mock Get-WinsmuxBin { 'winsmux' }
        Mock Test-OrchestraServerHealth { throw 'should not be called without a manifest' }

        $status = Get-ServerWatchdogHealthStatus -SessionName 'winsmux-orchestra' -ManifestPath $script:serverWatchdogManifestPath

        $status | Should -Be 'Unhealthy'
        Should -Invoke Test-OrchestraServerHealth -Times 0 -Exactly
    }
}

Describe 'orchestra-preflight health contract' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-preflight.ps1')
    }

    It 'marks health unhealthy when the pane count does not match the expected topology' {
        Mock Get-OrchestraSessionPortFilePath { 'C:\temp\winsmux-orchestra.port' }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'C:\temp\winsmux-orchestra.port' }
        Mock Get-OrchestraSessionPort { 4242 }
        Mock Test-OrchestraTcpConnection { $true }
        Mock Test-OrchestraSessionAuthResponse { $true }
        Mock Invoke-OrchestraHasSessionProbe { $true }
        Mock Get-OrchestraSessionPaneCount { 1 }

        $health = Test-OrchestraServerHealth -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux' -ExpectedPaneCount 2

        $health | Should -Be 'Unhealthy'
    }

    It 'marks health unhealthy when the pane count exceeds the expected topology' {
        Mock Get-OrchestraSessionPortFilePath { 'C:\temp\winsmux-orchestra.port' }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'C:\temp\winsmux-orchestra.port' }
        Mock Get-OrchestraSessionPort { 4242 }
        Mock Test-OrchestraTcpConnection { $true }
        Mock Test-OrchestraSessionAuthResponse { $true }
        Mock Invoke-OrchestraHasSessionProbe { $true }
        Mock Get-OrchestraSessionPaneCount { 3 }

        $health = Test-OrchestraServerHealth -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux' -ExpectedPaneCount 2

        $health | Should -Be 'Unhealthy'
    }
}

Describe 'orchestra-start watchdog contract' {
    BeforeAll {
        $script:orchestraStartPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-start.ps1'
        $script:orchestraStartContent = Get-Content -Path $script:orchestraStartPath -Raw -Encoding UTF8
    }

    It 'launches operator-poll with Start-Process before the watchdog' {
        $script:orchestraStartContent | Should -Match 'function Start-OperatorPollJob \{'
        $script:orchestraStartContent | Should -Match 'operator-poll\.ps1'
        $script:orchestraStartContent | Should -Match "'-Interval'"
        $script:orchestraStartContent | Should -Match '-Interval 20'
        $script:orchestraStartContent | Should -Match '-OperatorPollPid \$operatorPollProcess\.Id'

        $operatorPollIndex = $script:orchestraStartContent.IndexOf('$operatorPollProcess = Start-OperatorPollJob')
        $watchdogIndex = $script:orchestraStartContent.IndexOf('$watchdogProcess = Start-AgentWatchdogJob')
        $operatorPollIndex | Should -BeGreaterThan -1
        $watchdogIndex | Should -BeGreaterThan -1
        $operatorPollIndex | Should -BeLessThan $watchdogIndex
    }

    It 'launches the watchdog with Start-Process so it survives script exit' {
        $script:orchestraStartContent | Should -Match 'function Start-AgentWatchdogJob \{'
        $script:orchestraStartContent | Should -Match 'function Start-ServerWatchdogJob \{'
        $script:orchestraStartContent | Should -Match 'Start-Process\s+-FilePath\s+''pwsh'''
        $script:orchestraStartContent | Should -Match "'-NoProfile'"
        $script:orchestraStartContent | Should -Match "'-File'"
        $script:orchestraStartContent | Should -Match '-WindowStyle\s+Hidden\s+-PassThru'
        $script:orchestraStartContent | Should -Not -Match 'Start-Job\s+-Name\s+\("winsmux-watchdog-'
    }

    It 'persists both process pids and prints cleanup guidance' {
        $script:orchestraStartContent | Should -Match 'operator_poll_pid\s*=\s*\$OperatorPollPid'
        $script:orchestraStartContent | Should -Match 'Operator Poll PID: \$\(\$operatorPollProcess\.Id\)'
        $script:orchestraStartContent | Should -Match 'watchdog_pid\s*=\s*\$WatchdogPid'
        $script:orchestraStartContent | Should -Match 'server_watchdog_pid\s*=\s*\$ServerWatchdogPid'
        $script:orchestraStartContent | Should -Match '-WatchdogPid \$watchdogProcess\.Id'
        $script:orchestraStartContent | Should -Match '-ServerWatchdogPid \$serverWatchdogProcess\.Id'
        $script:orchestraStartContent | Should -Match 'Watchdog PID: \$\(\$watchdogProcess\.Id\)'
        $script:orchestraStartContent | Should -Match 'Server Watchdog PID: \$\(\$serverWatchdogProcess\.Id\)'
        $script:orchestraStartContent | Should -Match 'Stop-Process -Id \{0\},\{1\}'
    }
}

Describe 'orchestra-start server bootstrap' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-start.ps1')
    }

    BeforeEach {
        $script:winsmuxBin = 'winsmux'
        $script:attachStateStore = $null

        Mock Read-OrchestraAttachState {
            $script:attachStateStore
        }

        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)

            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }

            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }

            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
    }

    It 'redacts credentials from expected origin metadata' {
        ConvertTo-SafeGitRemoteUrl -RemoteUrl 'https://token@example.com/org/repo.git' |
            Should -Be 'https://example.com/org/repo.git'
        ConvertTo-SafeGitRemoteUrl -RemoteUrl 'ssh://user:secret@example.com/org/repo.git' |
            Should -Be 'ssh://example.com/org/repo.git'
        ConvertTo-SafeGitRemoteUrl -RemoteUrl 'git@example.com:org/repo.git' |
            Should -Be 'git@example.com:org/repo.git'
    }

    It 'persists worker isolation metadata through Save-OrchestraSessionState' {
        $script:savedManifest = $null
        Mock Save-WinsmuxManifest {
            param([string]$ProjectDir, $Manifest)
            $script:savedManifest = $Manifest
        }

        Save-OrchestraSessionState `
            -ProjectDir 'C:\repo' `
            -SessionName 'winsmux-orchestra' `
            -Settings ([ordered]@{ agent = 'codex'; model = 'gpt-5.4' }) `
            -GitWorktreeDir 'C:\repo\.git\worktrees' `
            -PaneSummaries @([ordered]@{
                Label                  = 'worker-1'
                PaneId                 = '%2'
                SlotId                 = 'worker-1'
                Role                   = 'Worker'
                ExecMode               = $false
                ProjectDir             = 'C:\repo'
                LaunchDir              = 'C:\repo\.worktrees\worker-1'
                BuilderBranch          = 'worktree-worker-1'
                BuilderWorktreePath    = 'C:\repo\.worktrees\worker-1'
                WorktreeGitDir         = 'C:\repo\.git\worktrees\worker-1'
                ExpectedOrigin         = 'https://github.com/example/repo.git'
                Status                 = 'ready'
                CapabilityAdapter      = 'codex'
                CapabilityCommand      = 'codex'
                SupportsParallelRuns   = $true
                SupportsInterrupt      = $true
                SupportsStructuredResult = $true
                SupportsFileEdit       = $true
                SupportsSubagents      = $true
                SupportsVerification   = $true
                SupportsConsultation   = $true
            }) | Out-Null

        $script:savedManifest | Should -Not -BeNullOrEmpty
        $pane = $script:savedManifest.panes.'worker-1'
        $pane.slot_id | Should -Be 'worker-1'
        $pane.project_dir | Should -Be 'C:\repo'
        $pane.worktree_git_dir | Should -Be 'C:\repo\.git\worktrees\worker-1'
        $pane.expected_origin | Should -Be 'https://github.com/example/repo.git'
    }

    It 'returns success when the server session already exists' {
        $script:probeCount = 0
        $script:newSessionCallCount = 0

        function Test-OrchestraServerSession {
            param([string]$SessionName)
            $script:probeCount++
            return $true
        }

        function Invoke-Winsmux {
            param([string[]]$Arguments, [switch]$CaptureOutput)
            $script:newSessionCallCount++
        }

        $result = Ensure-OrchestraBootstrapSession -SessionName 'winsmux-orchestra'

        $result.SessionName | Should -Be 'winsmux-orchestra'
        $result.BootstrapReady | Should -Be $false
        $result.StartupReady | Should -Be $false
        $script:probeCount | Should -Be 1
        $script:newSessionCallCount | Should -Be 0
    }

    It 'creates a detached bootstrap session and waits for a single pane when the session is missing' {
        $script:newSessionCalls = @()
        $script:paneCountCallCount = 0
        $script:probeCount = 0

        function Test-OrchestraServerSession {
            param([string]$SessionName)
            $script:probeCount++
            return ($script:probeCount -ge 2)
        }

        function Invoke-Winsmux {
            param([string[]]$Arguments, [switch]$CaptureOutput)
            $script:newSessionCalls += ,@($Arguments)
            if ($CaptureOutput) { return @() }
        }

        function Get-OrchestraSessionPaneCount {
            param([string]$SessionName, [string]$WinsmuxBin)
            $script:paneCountCallCount++
            return 1
        }

        function Start-Sleep {
            param([int]$Milliseconds)
        }

        $result = Ensure-OrchestraBootstrapSession -SessionName 'winsmux-orchestra'

        $result.SessionName | Should -Be 'winsmux-orchestra'
        $result.BootstrapReady | Should -Be $true
        $result.StartupReady | Should -Be $false
        $result.BootstrapMode | Should -Be 'detached_primary'
        $result.UiAttachStatus | Should -Be 'not_requested'
        @($script:newSessionCalls | Where-Object { $_[0] -eq 'new-session' -and $_[1] -eq '-d' -and $_[2] -eq '-s' -and $_[3] -eq 'winsmux-orchestra' }).Count | Should -Be 1
        $script:paneCountCallCount | Should -Be 1
        $script:probeCount | Should -Be 2
    }

    It 'launches visible attach through a fixed Windows Terminal profile and handshake' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 0; Error = ''; Clients = @() }
        }
        Mock Get-OrchestraWindowsTerminalInfo {
            [PSCustomObject][ordered]@{
                Available   = $true
                Path        = 'C:\Windows\System32\wt.exe'
                AliasPath   = ''
                IsAliasStub = $false
                PathSource  = 'command'
                Reason      = 'ready'
            }
        }
        Mock Ensure-OrchestraAttachProfile {
            [PSCustomObject][ordered]@{
                ProfileName  = 'winsmux orchestra attach'
                FragmentPath = 'C:\Users\Example\AppData\Local\Microsoft\Windows Terminal\Fragments\winsmux\winsmux-orchestra-attach.json'
                Commandline  = '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoExit -File "C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1"'
            }
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Wait-OrchestraAttachLaunchObservation {
            [PSCustomObject]@{ Observed = $true; Reason = 'launch observed' }
        }
        Mock Wait-OrchestraAttachHandshake {
            [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'handshake'
                Status              = 'attach_confirmed'
                Reason              = 'Attach confirmed'
                AttachedClientCount = 1
                State               = [pscustomobject]@{
                    attach_request_id      = 'req-123'
                    attached_client_snapshot = @('client-1')
                    ui_host_kind           = 'windows-terminal'
                }
            }
        }

        function Start-Process {
            param(
                [string]$FilePath,
                [object[]]$ArgumentList,
                [switch]$PassThru
            )

            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $true }
        }

        function Start-Sleep {
            param([int]$Milliseconds)
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $true
        $result.Launched | Should -Be $true
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_confirmed'
        $result.Source | Should -Be 'handshake'
        $result.attach_request_id | Should -Be 'req-123'
        $result.attached_client_snapshot | Should -Be @('client-1')
        $result.ui_host_kind | Should -Be 'windows-terminal'
        $result.attach_adapter_trace.Count | Should -Be 1
        $result.attach_adapter_trace[0].host_kind | Should -Be 'windows-terminal'
        $result.attach_adapter_trace[0].launch_result | Should -Be 'attach_confirmed'
        $script:startProcessCalls.Count | Should -Be 1
        $script:startProcessCalls[0].FilePath | Should -Be 'C:\Windows\System32\wt.exe'
        $script:startProcessCalls[0].ArgumentList | Should -Be @('-w', '-1', 'new-window', '-p', 'winsmux orchestra attach')
    }

    It 'returns attach_already_present only when a live visible attach state already exists' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-1') }
        }
        Mock Read-OrchestraAttachState {
            [pscustomobject]@{
                session_name     = 'winsmux-orchestra'
                attach_status    = 'attach_confirmed'
                ui_attach_source = 'handshake'
                attach_process_id = 4242
            }
        }
        Mock Test-OrchestraLiveVisibleAttachState { $true }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $false }
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $false
        $result.Launched | Should -Be $false
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_already_present'
        $result.Source | Should -Be 'handshake'
        $script:startProcessCalls.Count | Should -Be 0
    }

    It 'preserves a client-probe confirmation source when the live attach process is still alive' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-1') }
        }
        Mock Read-OrchestraAttachState {
            [pscustomobject]@{
                session_name      = 'winsmux-orchestra'
                attach_status     = 'attach_confirmed'
                ui_attach_source  = 'client-probe'
                attach_process_id = 4242
            }
        }
        Mock Test-OrchestraProcessAlive { $true }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $false
        $result.Launched | Should -Be $false
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_already_present'
        $result.Source | Should -Be 'client-probe'
        $script:startProcessCalls.Count | Should -Be 0
    }

    It 'does not suppress attach from client-probe alone when no live visible attach state exists' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-1') }
        }
        Mock Read-OrchestraAttachState { $script:attachStateStore }
        Mock Test-OrchestraLiveVisibleAttachState { $false }
        Mock Get-OrchestraWindowsTerminalInfo {
            [PSCustomObject][ordered]@{
                Available   = $true
                Path        = 'C:\Windows\System32\wt.exe'
                AliasPath   = ''
                IsAliasStub = $false
                PathSource  = 'command'
                Reason      = 'ready'
            }
        }
        Mock Ensure-OrchestraAttachProfile {
            [PSCustomObject][ordered]@{
                ProfileName  = 'winsmux orchestra attach'
                FragmentPath = 'C:\Users\Example\AppData\Local\Microsoft\Windows Terminal\Fragments\winsmux\winsmux-orchestra-attach.json'
                Commandline  = '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoExit -File "C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1"'
            }
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Wait-OrchestraAttachLaunchObservation {
            [PSCustomObject]@{ Observed = $true; Reason = 'launch observed' }
        }
        Mock Wait-OrchestraAttachHandshake {
            [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'handshake'
                Status              = 'attach_confirmed'
                Reason              = 'Attach confirmed'
                AttachedClientCount = 2
                State               = [pscustomobject]@{}
            }
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $true }
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $true
        $result.Launched | Should -Be $true
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_confirmed'
        $result.Source | Should -Be 'handshake'
        $script:startProcessCalls.Count | Should -Be 1
    }

    It 'falls back to a direct PowerShell visible attach host when Windows Terminal launch does not advance attach state' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-1') }
        }
        Mock Read-OrchestraAttachState { $script:attachStateStore }
        Mock Test-OrchestraLiveVisibleAttachState { $false }
        Mock Get-OrchestraWindowsTerminalInfo {
            [PSCustomObject][ordered]@{
                Available   = $true
                Path        = 'C:\Windows\System32\wt.exe'
                AliasPath   = ''
                IsAliasStub = $false
                PathSource  = 'command'
                Reason      = 'ready'
            }
        }
        Mock Ensure-OrchestraAttachProfile {
            [PSCustomObject][ordered]@{
                ProfileName  = 'winsmux orchestra attach'
                FragmentPath = 'C:\Users\Example\AppData\Local\Microsoft\Windows Terminal\Fragments\winsmux\winsmux-orchestra-attach.json'
                Commandline  = '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoExit -File "C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1"'
            }
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Wait-OrchestraAttachLaunchObservation {
            [PSCustomObject]@{ Observed = $false; Reason = 'no attach state change observed' }
        }
        Mock Get-OrchestraPowerShellPath { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Get-OrchestraAttachEntryArgumentList { @('-NoLogo', '-NoExit', '-File', 'C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1') }
        Mock Wait-OrchestraAttachHandshake {
            [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'handshake'
                Status              = 'attach_confirmed'
                Reason              = 'Attach confirmed after fallback'
                AttachedClientCount = 1
                State               = [pscustomobject]@{}
            }
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $false }
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $true
        $result.Launched | Should -Be $true
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_confirmed'
        $result.Path | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        $result.attach_adapter_trace.Count | Should -Be 2
        $result.attach_adapter_trace[0].host_kind | Should -Be 'windows-terminal'
        $result.attach_adapter_trace[0].launch_result | Should -Be 'launch_unobserved'
        $result.attach_adapter_trace[1].host_kind | Should -Be 'powershell-window'
        $result.attach_adapter_trace[1].launch_result | Should -Be 'attach_confirmed'
        $script:startProcessCalls.Count | Should -Be 2
        $script:startProcessCalls[0].FilePath | Should -Be 'C:\Windows\System32\wt.exe'
        $script:startProcessCalls[1].FilePath | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
    }

    It 'falls back to a direct PowerShell visible attach host when Windows Terminal is unavailable' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'
        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 0; Error = ''; Clients = @() }
        }
        Mock Read-OrchestraAttachState { $script:attachStateStore }
        Mock Test-OrchestraLiveVisibleAttachState { $false }
        Mock Get-OrchestraWindowsTerminalInfo {
            [PSCustomObject][ordered]@{
                Available   = $false
                Path        = ''
                AliasPath   = ''
                IsAliasStub = $false
                PathSource  = ''
                Reason      = 'wt_unavailable'
            }
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Get-OrchestraPowerShellPath { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Get-OrchestraAttachEntryArgumentList { @('-NoLogo', '-NoExit', '-File', 'C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1') }
        Mock Wait-OrchestraAttachHandshake {
            [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'handshake'
                Status              = 'attach_confirmed'
                Reason              = 'Attach confirmed via fallback host'
                AttachedClientCount = 1
                State               = [pscustomobject]@{}
            }
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $false }
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $true
        $result.Launched | Should -Be $true
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_confirmed'
        $result.Path | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        $result.Source | Should -Be 'handshake'
        $result.attach_adapter_trace.Count | Should -Be 2
        $result.attach_adapter_trace[0].host_kind | Should -Be 'windows-terminal'
        $result.attach_adapter_trace[0].launch_result | Should -Be 'skipped_unavailable'
        $result.attach_adapter_trace[1].host_kind | Should -Be 'powershell-window'
        $result.attach_adapter_trace[1].launch_result | Should -Be 'attach_confirmed'
        $script:startProcessCalls.Count | Should -Be 1
        $script:startProcessCalls[0].FilePath | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
    }

    It 'falls back to the next visible attach host when the first host fails handshake confirmation' {
        $script:startProcessCalls = @()
        $script:attachStateStore = $null
        $script:handshakeCalls = 0
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-1') }
        }
        Mock Read-OrchestraAttachState { $script:attachStateStore }
        Mock Test-OrchestraLiveVisibleAttachState { $false }
        Mock Get-OrchestraWindowsTerminalInfo {
            [PSCustomObject][ordered]@{
                Available   = $true
                Path        = 'C:\Windows\System32\wt.exe'
                AliasPath   = ''
                IsAliasStub = $false
                PathSource  = 'command'
                Reason      = 'ready'
            }
        }
        Mock Ensure-OrchestraAttachProfile {
            [PSCustomObject][ordered]@{
                ProfileName  = 'winsmux orchestra attach'
                FragmentPath = 'C:\Users\Example\AppData\Local\Microsoft\Windows Terminal\Fragments\winsmux\winsmux-orchestra-attach.json'
                Commandline  = '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoExit -File "C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1"'
            }
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Wait-OrchestraAttachLaunchObservation {
            [PSCustomObject]@{ Observed = $true; Reason = 'launch observed' }
        }
        Mock Get-OrchestraPowerShellPath { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Get-OrchestraAttachEntryArgumentList { @('-NoLogo', '-NoExit', '-File', 'C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1') }
        Mock Wait-OrchestraAttachHandshake {
            $script:handshakeCalls++
            if ($script:handshakeCalls -eq 1) {
                return [PSCustomObject][ordered]@{
                    Confirmed           = $false
                    Source              = 'timeout'
                    Status              = 'attach_failed'
                    Reason              = 'first host timed out'
                    AttachedClientCount = 1
                    State               = [pscustomobject]@{
                        attach_request_id = 'req-fail-1'
                        ui_host_kind      = 'windows-terminal'
                    }
                }
            }

            return [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'handshake'
                Status              = 'attach_confirmed'
                Reason              = 'fallback host confirmed'
                AttachedClientCount = 1
                State               = [pscustomobject]@{
                    attach_request_id        = 'req-ok-2'
                    attached_client_snapshot = @('client-1')
                    ui_host_kind             = 'powershell-window'
                }
            }
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $false }
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_confirmed'
        $result.Path | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        $result.attach_request_id | Should -Be 'req-ok-2'
        $result.ui_host_kind | Should -Be 'powershell-window'
        $result.attach_adapter_trace.Count | Should -Be 2
        $result.attach_adapter_trace[0].host_kind | Should -Be 'windows-terminal'
        $result.attach_adapter_trace[0].launch_result | Should -Be 'attach_failed'
        $result.attach_adapter_trace[1].host_kind | Should -Be 'powershell-window'
        $result.attach_adapter_trace[1].launch_result | Should -Be 'attach_confirmed'
        $script:startProcessCalls.Count | Should -Be 2
    }

    It 'confirms visible attach on client transition even when client count does not increase' {
        $script:attachStateReads = 0

        Mock Read-OrchestraAttachState {
            $script:attachStateReads++
            [pscustomobject]@{
                session_name      = 'winsmux-orchestra'
                attach_status     = 'attach_entry_started'
                ui_attach_source  = 'none'
                attach_process_id = 4242
                baseline_clients  = @('client-old')
            }
        }
        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{
                Ok      = $true
                Count   = 1
                Error   = ''
                Clients = @('client-new')
            }
        }
        Mock Test-OrchestraProcessAlive { $true }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            [pscustomobject]$Properties
        }
        function Start-Sleep {
            param([int]$Milliseconds)
        }

        $result = Wait-OrchestraAttachHandshake -SessionName 'winsmux-orchestra' -WinsmuxBin 'C:\winsmux\winsmux.exe' -BaselineClientCount 1 -BaselineClients @('client-old') -TimeoutMilliseconds 1000 -PollMilliseconds 1

        $result.Confirmed | Should -Be $true
        $result.Source | Should -Be 'handshake'
        $result.Status | Should -Be 'attach_confirmed'
        $result.AttachedClientCount | Should -Be 1
    }

    It 'does not confirm attach from a first client when baseline is empty and attach entry never started' {
        Mock Read-OrchestraAttachState {
            [pscustomobject]@{
                session_name      = 'winsmux-orchestra'
                attach_status     = 'attach_requested'
                ui_attach_source  = 'none'
                attach_process_id = 0
                baseline_clients  = @()
            }
        }
        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{
                Ok      = $true
                Count   = 1
                Error   = ''
                Clients = @('client-1')
            }
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            [pscustomobject]$Properties
        }
        function Start-Sleep {
            param([int]$Milliseconds)
        }

        $result = Wait-OrchestraAttachHandshake -SessionName 'winsmux-orchestra' -WinsmuxBin 'C:\winsmux\winsmux.exe' -BaselineClientCount 0 -BaselineClients @() -TimeoutMilliseconds 5 -PollMilliseconds 1

        $result.Confirmed | Should -Be $false
        $result.Status | Should -Be 'attach_failed'
        $result.Reason | Should -Match 'Attach confirmation timed out before client count reached 1'
    }

    It 'checks the bootstrap pane count before reporting startup ready' {
        $script:probeCount = 0
        $script:paneCountCallCount = 0
        $script:newSessionCalls = 0

        function Test-OrchestraServerSession {
            param([string]$SessionName)
            $script:probeCount++
            return ($script:probeCount -ge 2)
        }

        function Invoke-Winsmux {
            param([string[]]$Arguments, [switch]$CaptureOutput)
            if ($Arguments[0] -eq 'new-session') {
                $script:newSessionCalls++
                return
            }

            throw "unexpected winsmux call: $($Arguments -join ' ')"
        }

        function Get-Command {
            param([string]$Name)
            if ($Name -eq 'wt.exe') {
                return [PSCustomObject]@{ Source = 'C:\Windows\System32\wt.exe' }
            }

            throw "unexpected command lookup: $Name"
        }

        function Start-Process {
            param(
                [string]$FilePath,
                [object[]]$ArgumentList
            )
        }

        Mock Get-OrchestraSessionPaneCount { $script:paneCountCallCount++; return 1 }

        function Start-Sleep {
            param([int]$Milliseconds)
        }

        $result = Ensure-OrchestraBootstrapSession -SessionName 'winsmux-orchestra' -ExpectedPaneCount 1

        $result.BootstrapReady | Should -Be $true
        $result.StartupReady | Should -Be $false
        $result.BootstrapMode | Should -Be 'detached_primary'
        $result.UiAttachStatus | Should -Be 'not_requested'
        $script:newSessionCalls | Should -Be 1
        $script:paneCountCallCount | Should -Be 1
        $script:probeCount | Should -Be 2
    }

    It 'resets a stale session by killing it, clearing registration, and recreating it' {
        $script:killCalls = 0
        $script:clearCalls = 0
        $script:ensureCalls = 0
        $script:waitCalls = 0
        $script:ensureTimeoutSeconds = $null

        function Invoke-Winsmux {
            param([string[]]$Arguments, [switch]$CaptureOutput)
            if ($Arguments[0] -eq 'kill-session') {
                $script:killCalls++
                return
            }

            throw "unexpected winsmux call: $($Arguments -join ' ')"
        }

        function Clear-OrchestraSessionRegistration {
            param([string]$SessionName)
            $script:clearCalls++
        }

        function Wait-OrchestraServerSessionAbsent {
            param([string]$SessionName, [int]$TimeoutSeconds = 20)
            $script:waitCalls++
            return [ordered]@{
                Ready       = $true
                PollAttempt = 1
            }
        }

        function Ensure-OrchestraBootstrapSession {
            param([string]$SessionName, [int]$TimeoutSeconds = 60, [int]$ExpectedPaneCount = 1)
            $script:ensureCalls++
            $script:ensureTimeoutSeconds = $TimeoutSeconds
            $script:ensureExpectedPaneCount = $ExpectedPaneCount
            return [ordered]@{
                SessionName    = $SessionName
                BootstrapReady = $true
                StartupReady   = $false
                BootstrapMode  = 'detached_primary'
            }
        }

        Mock Test-OrchestraServerSession { $true }

        $result = Reset-OrchestraServerSession -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux' -Reason 'test'

        $result.BootstrapReady | Should -Be $true
        $result.StartupReady | Should -Be $false
        $result.Health | Should -Be 'BootstrapOnly'
        $script:killCalls | Should -Be 1
        $script:clearCalls | Should -Be 1
        $script:ensureCalls | Should -Be 1
        $script:waitCalls | Should -Be 1
        $script:ensureTimeoutSeconds | Should -Be 60
        $script:ensureExpectedPaneCount | Should -Be 1
    }

    It 'throws when the layout leaves the session below the expected pane count' {
        Mock Get-OrchestraSessionPaneIds { @('%1') }

        {
            Assert-OrchestraSessionPaneCount -SessionName 'winsmux-orchestra' -ExpectedPaneCount 2 -StageName 'layout'
        } | Should -Throw '*expected 2 pane(s)*found 1*'
    }

    It 'fails closed when a background watchdog process exits immediately' {
        $process = [PSCustomObject]@{
            HasExited = $true
            ExitCode  = 23
        }

        { Assert-OrchestraBackgroundProcessStarted -Process $process -Name 'Server watchdog job' -StartupDelayMilliseconds 1 } | Should -Throw '*exited immediately*'
    }

    It 'accepts builder pane launch-dir evidence from the recent capture when pane_current_path lags behind' {
        function Invoke-Winsmux {
            param([string[]]$Arguments, [switch]$CaptureOutput)
            if ($Arguments[0] -eq 'display-message') {
                return 'C:\Users\Example\Documents\Projects\apps\winsmux'
            }

            if ($Arguments[0] -eq 'capture-pane') {
                return @'
› Write tests for @filename

  gpt-5.4 high · ~\Documents\Projects\apps\winsmux\.worktrees\builder-6
'@
            }

            throw "unexpected winsmux call: $($Arguments -join ' ')"
        }

        $failures = @(Test-PaneBootstrapInvariants `
            -PaneId '%8' `
            -Label 'worker-6' `
            -ExpectedRole 'Worker' `
            -ExpectedLaunchDir 'C:\Users\Example\Documents\Projects\apps\winsmux\.worktrees\builder-6' `
            -ExpectedWorktreePath 'C:\Users\Example\Documents\Projects\apps\winsmux\.worktrees\builder-6')

        $failures.Count | Should -Be 0
    }

    It 'accepts a matching bootstrap marker when pane_current_path lags behind' {
        $markerPath = Join-Path $TestDrive 'worker-6.ready.json'
        @'
{
  "launch_dir": "C:\\Users\\Example\\Documents\\Projects\\apps\\winsmux\\.worktrees\\builder-6",
  "current_dir": "C:\\Users\\Example\\Documents\\Projects\\apps\\winsmux\\.worktrees\\builder-6"
}
'@ | Set-Content -LiteralPath $markerPath -Encoding UTF8

        function Invoke-Winsmux {
            param([string[]]$Arguments, [switch]$CaptureOutput)
            if ($Arguments[0] -eq 'display-message') {
                return 'C:\Users\Example\Documents\Projects\apps\winsmux'
            }

            if ($Arguments[0] -eq 'capture-pane') {
                return 'capture fallback not needed'
            }

            throw "unexpected winsmux call: $($Arguments -join ' ')"
        }

        $failures = @(Test-PaneBootstrapInvariants `
            -PaneId '%8' `
            -Label 'worker-6' `
            -ExpectedRole 'Worker' `
            -ExpectedLaunchDir 'C:\Users\Example\Documents\Projects\apps\winsmux\.worktrees\builder-6' `
            -ExpectedWorktreePath 'C:\Users\Example\Documents\Projects\apps\winsmux\.worktrees\builder-6' `
            -BootstrapMarkerPath $markerPath)

        $failures.Count | Should -Be 0
    }

    It 'treats missing Windows Terminal as a non-fatal UI attach condition' {
        $script:startProcessCalls = @()

        function Get-Command {
            param([string]$Name)
            if ($Name -eq 'pwsh') {
                return [PSCustomObject]@{ Source = 'C:\Program Files\PowerShell\7\pwsh.exe' }
            }
            if ($Name -eq 'winsmux') {
                return [PSCustomObject]@{ Source = 'C:\Users\Example\.local\bin\winsmux.exe' }
            }

            throw "unexpected command lookup: $Name"
        }

        Mock Get-OrchestraWindowsTerminalInfo {
            [PSCustomObject][ordered]@{
                Available   = $false
                Path        = ''
                AliasPath   = ''
                IsAliasStub = $false
                PathSource  = ''
                Reason      = 'wt_unavailable'
            }
        }

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject][ordered]@{
                Ok      = $true
                Count   = 0
                Clients = @()
            }
        }
        Mock Read-OrchestraAttachState { $null }
        Mock Test-OrchestraLiveVisibleAttachState { $false }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Get-OrchestraPowerShellPath { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Get-OrchestraAttachEntryArgumentList { @('-NoLogo', '-NoExit', '-File', 'C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1') }
        Mock Wait-OrchestraAttachHandshake {
            [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'handshake'
                Status              = 'attach_confirmed'
                Reason              = 'Attach confirmed via fallback host'
                AttachedClientCount = 1
                State               = [pscustomobject]@{}
            }
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $false }
        }

        function Start-Sleep {
            param([int]$Milliseconds)
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $true
        $result.Launched | Should -Be $true
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_confirmed'
        $script:startProcessCalls.Count | Should -Be 1
        $script:startProcessCalls[0].FilePath | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
    }

    It 'skips UI attach when winsmux cannot be resolved to an absolute path for the child process' {
        function Get-Command {
            param([string]$Name)
            if ($Name -eq 'wt.exe') {
                return [PSCustomObject]@{ Source = 'C:\Windows\System32\wt.exe' }
            }
            if ($Name -eq 'pwsh') {
                return [PSCustomObject]@{ Source = 'C:\Program Files\PowerShell\7\pwsh.exe' }
            }
            if ($Name -eq 'winsmux') {
                return $null
            }

            throw "unexpected command lookup: $Name"
        }

        function Get-Item {
            param([string]$LiteralPath)
            return [PSCustomObject]@{ Length = 4096 }
        }

        $script:winsmuxBin = 'winsmux'

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $false
        $result.Launched | Should -Be $false
        $result.Attached | Should -Be $false
        $result.Status | Should -Be 'winsmux_unresolved'
    }

    It 'stops stale background processes recorded in the manifest before fresh startup' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                session = [PSCustomObject]@{
                    startup_token       = 'token-123'
                    operator_poll_pid  = '101'
                    watchdog_pid        = '202'
                    server_watchdog_pid = '303'
                }
            }
        }

        $script:stoppedProcessIds = @()
        Mock Get-ProcessSnapshot {
            [PSCustomObject]@{
                ById = @{
                    101 = [PSCustomObject]@{ ProcessId = 101; ParentProcessId = 1; CommandLine = 'pwsh operator-poll.ps1 C:\repo\.winsmux\manifest.yaml -StartupToken token-123 winsmux-orchestra C:\repo\scripts\winsmux-core.ps1'; Name = 'pwsh.exe' }
                    202 = [PSCustomObject]@{ ProcessId = 202; ParentProcessId = 1; CommandLine = 'pwsh agent-watchdog.ps1 C:\repo\.winsmux\manifest.yaml -StartupToken token-123 winsmux-orchestra C:\repo\scripts\winsmux-core.ps1'; Name = 'pwsh.exe' }
                    303 = [PSCustomObject]@{ ProcessId = 303; ParentProcessId = 1; CommandLine = 'pwsh server-watchdog.ps1 C:\repo\.winsmux\manifest.yaml -StartupToken token-123 winsmux-orchestra C:\repo\scripts\winsmux-core.ps1'; Name = 'pwsh.exe' }
                }
            }
        }
        Mock Stop-Process { $script:stoppedProcessIds += $Id }

        $result = Stop-OrchestraBackgroundProcessesFromManifest -ProjectDir 'C:\repo' -GitWorktreeDir 'C:\repo\.git' -BridgeScript 'C:\repo\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra'

        @($result.Stopped).Count | Should -Be 3
        @($result.Errors).Count | Should -Be 0
        $script:stoppedProcessIds | Should -Be @(101, 202, 303)
    }

    It 'treats legacy commander_poll_pid as the operator poll process during manifest cleanup' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                session = [PSCustomObject]@{
                    startup_token      = 'token-123'
                    commander_poll_pid = '101'
                }
            }
        }

        $script:stoppedProcessIds = @()
        Mock Get-ProcessSnapshot {
            [PSCustomObject]@{
                ById = @{
                    101 = [PSCustomObject]@{ ProcessId = 101; ParentProcessId = 1; CommandLine = 'pwsh operator-poll.ps1 C:\repo\.winsmux\manifest.yaml -StartupToken token-123 winsmux-orchestra C:\repo\scripts\winsmux-core.ps1'; Name = 'pwsh.exe' }
                }
            }
        }
        Mock Stop-Process { $script:stoppedProcessIds += $Id }

        $result = Stop-OrchestraBackgroundProcessesFromManifest -ProjectDir 'C:\repo' -GitWorktreeDir 'C:\repo\.git' -BridgeScript 'C:\repo\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra'

        @($result.Stopped).Count | Should -Be 1
        $result.Stopped[0].label | Should -Be 'operator_poll_pid'
        @($result.Errors).Count | Should -Be 0
        $script:stoppedProcessIds | Should -Be @(101)
    }

    It 'skips targeted background cleanup when the manifest has no startup token' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                session = [PSCustomObject]@{
                    operator_poll_pid = '101'
                }
            }
        }

        Mock Get-ProcessSnapshot { throw 'should not read process snapshot without startup token' }
        Mock Stop-Process { throw 'should not stop any process without startup token' }

        $result = Stop-OrchestraBackgroundProcessesFromManifest -ProjectDir 'C:\repo' -GitWorktreeDir 'C:\repo\.git' -BridgeScript 'C:\repo\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra'

        @($result.Stopped).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 1
        $result.Errors[0] | Should -Match 'startup_token'
    }
}

Describe 'orchestra-start session reuse contract' {
    BeforeAll {
        $script:orchestraStartPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-start.ps1'
        . $script:orchestraStartPath
        $script:orchestraStartContent = Get-Content -Path $script:orchestraStartPath -Raw -Encoding UTF8
    }

    It 'reuses the session Ensure-OrchestraBootstrapSession just created' {
        $script:orchestraStartContent | Should -Match '\$orchestraServer\s*=\s*Ensure-OrchestraBootstrapSession -SessionName \$sessionName'
        $script:orchestraStartContent | Should -Match '\$uiAttachResult\s*=\s*Try-StartOrchestraUiAttach -SessionName \$sessionName'
        $script:orchestraStartContent | Should -Match "preflight\.bootstrap\.ready"
        $script:orchestraStartContent | Should -Match "orchestra\.startup\.session_ready"
        $script:orchestraStartContent | Should -Match 'Bootstrap session \$sessionName created by Ensure-OrchestraBootstrapSession\.'
        $script:orchestraStartContent | Should -Not -Match "preflight\.session\.create"
        $script:orchestraStartContent | Should -Match 'detached_primary'
        $script:orchestraStartContent | Should -Match 'UiAttachLaunched'
        $script:orchestraStartContent | Should -Match 'ui_attach_launched'
        $script:orchestraStartContent | Should -Match 'ui_attach_status'
        $script:orchestraStartContent | Should -Match 'attach_adapter_trace'
    }

    It 'does not mark session_ready true in the manifest until watchdog processes are started' {
        $script:orchestraStartContent | Should -Match 'Save-OrchestraSessionState[^\r\n]+SessionReady \$false'
        $script:orchestraStartContent | Should -Match 'Save-OrchestraSessionState[^\r\n]+OperatorPollPid \$operatorPollProcess\.Id[^\r\n]+SessionReady \$true'
    }

    It 'keeps detached startup on the session-ready path even when visible attach still needs retry' {
        $script:orchestraStartContent | Should -Match '\$successfulAttachStatuses\s*=\s*@\(''attach_confirmed'', ''attach_already_present''\)'
        $script:orchestraStartContent | Should -Match 'if \(\$successfulAttachStatuses -notcontains \[string\]\$uiAttachResult\.Status\) \{\s*Write-Warning'
        $script:orchestraStartContent | Should -Match 'Save-OrchestraSessionState[^\r\n]+SessionReady \$false[^\r\n]+UiAttachLaunched \(\[bool\]\$uiAttachResult\.Launched\)[^\r\n]+UiAttached \(\[bool\]\$uiAttachResult\.Attached\)'
        $script:orchestraStartContent | Should -Match 'Save-OrchestraSessionState[^\r\n]+SessionReady \$true[^\r\n]+UiAttachLaunched \(\[bool\]\$uiAttachResult\.Launched\)[^\r\n]+UiAttached \(\[bool\]\$uiAttachResult\.Attached\)'
        $script:orchestraStartContent | Should -Match 'reached session-ready; UI attach remains a separate state'
    }

    It 'does not route visible attach retry conditions into startup rollback handling' {
        $script:orchestraStartContent | Should -Match '\$uiAttachResult\s*=\s*Try-StartOrchestraUiAttach -SessionName \$sessionName'
        $script:orchestraStartContent | Should -Match 'Write-Warning "Orchestra UI attach status for \$\{sessionName\}: \$\(\$uiAttachResult\.Status\) \(\$\(\$uiAttachResult\.Reason\)\)"'
        $script:orchestraStartContent | Should -Match '\$rollback = Invoke-OrchestraStartupRollback -ProjectDir \$projectDir -SessionName \$sessionName'

        $uiAttachIndex = $script:orchestraStartContent.IndexOf('$uiAttachResult = Try-StartOrchestraUiAttach -SessionName $sessionName')
        $warningIndex = $script:orchestraStartContent.IndexOf('Write-Warning "Orchestra UI attach status for ${sessionName}: $($uiAttachResult.Status) ($($uiAttachResult.Reason))"')
        $rollbackIndex = $script:orchestraStartContent.IndexOf('$rollback = Invoke-OrchestraStartupRollback -ProjectDir $projectDir -SessionName $sessionName')
        $sessionReadyLogIndex = $script:orchestraStartContent.IndexOf("Write-WinsmuxLog -Level INFO -Event 'orchestra.startup.session_ready'")

        $uiAttachIndex | Should -BeGreaterThan -1
        $warningIndex | Should -BeGreaterThan $uiAttachIndex
        $sessionReadyLogIndex | Should -BeGreaterThan $warningIndex
        $rollbackIndex | Should -BeGreaterThan $sessionReadyLogIndex
    }

    It 'checks the expected pane count before layout without requiring strict health metadata' {
        $script:orchestraStartContent | Should -Match '\$expectedPaneCount\s*=\s*Get-OrchestraExpectedPaneCount -LayoutSettings \$layoutSettings'
        $script:orchestraStartContent | Should -Match '\$bootstrapPaneCount\s*=\s*1'
        $script:orchestraStartContent | Should -Match 'Test-OrchestraServerHealth -SessionName \$sessionName -WinsmuxBin \$winsmuxBin -ExpectedPaneCount \$expectedPaneCount'
        $script:orchestraStartContent | Should -Match 'Reset-OrchestraServerSession -SessionName \$sessionName -WinsmuxBin \$winsmuxBin -ProjectDir \$projectDir -GitWorktreeDir \$gitWorktreeDir -BridgeScript \$bridgeScript -Reason ''healthy_existing_session'' -ExpectedPaneCount \$bootstrapPaneCount'
        $script:orchestraStartContent | Should -Match 'proceeding without strict pre-layout health metadata gate'
    }

    It 'uses pane capture evidence when pane_current_path lags behind the builder worktree' {
        $script:orchestraStartContent | Should -Match 'function Test-PaneCaptureContainsLaunchDir'
        $script:orchestraStartContent | Should -Match 'function Test-OrchestraBootstrapMarker'
        $script:orchestraStartContent | Should -Match 'capture-pane'
        $script:orchestraStartContent | Should -Match 'Test-PaneCaptureContainsLaunchDir -CaptureText \$snapshotText -ExpectedLaunchDir \$ExpectedLaunchDir'
        $script:orchestraStartContent | Should -Match 'BootstrapMarkerPath'
    }

    It 'clears stale manifest state before zombie cleanup and bootstrap' {
        $script:orchestraStartContent | Should -Match 'Acquire-OrchestraStartupLock -ProjectDir \$projectDir -SessionName \$sessionName'
        $script:orchestraStartContent | Should -Match 'Stop-OrchestraBackgroundProcessesFromManifest -ProjectDir \$projectDir -GitWorktreeDir \$gitWorktreeDir -BridgeScript \$bridgeScript -SessionName \$sessionName'
        $script:orchestraStartContent | Should -Match 'if \(Clear-WinsmuxManifest -ProjectDir \$projectDir\)'
        $script:orchestraStartContent | Should -Match 'startup_token\s*=\s*\$StartupToken'

        $lockAcquireIndex = $script:orchestraStartContent.IndexOf('$startupLock = Acquire-OrchestraStartupLock -ProjectDir $projectDir -SessionName $sessionName')
        $manifestCleanupIndex = $script:orchestraStartContent.IndexOf('$manifestBackgroundCleanup = Stop-OrchestraBackgroundProcessesFromManifest -ProjectDir $projectDir -GitWorktreeDir $gitWorktreeDir -BridgeScript $bridgeScript -SessionName $sessionName')
        $clearManifestIndex = $script:orchestraStartContent.IndexOf('if (Clear-WinsmuxManifest -ProjectDir $projectDir) {')
        $zombieCleanupIndex = $script:orchestraStartContent.IndexOf('$zombieCleanup = Remove-OrchestraZombieProcesses -SessionName $sessionName -ProjectDir $projectDir -GitWorktreeDir $gitWorktreeDir -BridgeScript $bridgeScript -WinsmuxBin $winsmuxBin')
        $sessionExistsIndex = $script:orchestraStartContent.IndexOf('$sessionExistedAtStart = Test-OrchestraServerSession -SessionName $sessionName')
        $lockAcquireIndex | Should -BeGreaterThan -1
        $manifestCleanupIndex | Should -BeGreaterThan -1
        $clearManifestIndex | Should -BeGreaterThan -1
        $zombieCleanupIndex | Should -BeGreaterThan -1
        $sessionExistsIndex | Should -BeGreaterThan -1
        $lockAcquireIndex | Should -BeLessThan $sessionExistsIndex
        $sessionExistsIndex | Should -BeLessThan $manifestCleanupIndex
        $manifestCleanupIndex | Should -BeLessThan $clearManifestIndex
        $clearManifestIndex | Should -BeLessThan $zombieCleanupIndex
    }

    It 'requires the bootstrap pane topology before considering a fresh session ready' {
        $script:orchestraStartContent | Should -Match '\[int\]\$ExpectedPaneCount = 1'
        $script:orchestraStartContent | Should -Match '\$paneCount = Get-OrchestraSessionPaneCount -SessionName \$SessionName -WinsmuxBin \$script:winsmuxBin'
        $script:orchestraStartContent | Should -Match 'if \(\$paneCount -eq \$ExpectedPaneCount\)'
    }

    It 'prints safe labels when default agent and model are omitted from project config' {
        $script:orchestraStartContent | Should -Match "per-slot / override only"
        $script:orchestraStartContent | Should -Match '\$defaultAgent'
        $script:orchestraStartContent | Should -Match '\$defaultModel'
    }

    It 'persists provider capability fields in pane manifest entries' {
        $script:orchestraStartContent | Should -Match 'CapabilityAdapter = \[string\]\$slotAgentConfig\.CapabilityAdapter'
        $script:orchestraStartContent | Should -Match 'SupportsFileEdit = \[bool\]\$slotAgentConfig\.SupportsFileEdit'
        $script:orchestraStartContent | Should -Match 'SupportsVerification = \[bool\]\$slotAgentConfig\.SupportsVerification'
        $script:orchestraStartContent | Should -Match 'capability_adapter\s*=\s*\[string\]\$paneSummary\.CapabilityAdapter'
        $script:orchestraStartContent | Should -Match 'supports_file_edit\s*=\s*\[bool\]\$paneSummary\.SupportsFileEdit'
        $script:orchestraStartContent | Should -Match 'supports_verification\s*=\s*\[bool\]\$paneSummary\.SupportsVerification'
    }

    It 'uses the capability adapter for startup readiness detection' {
        $summary = [pscustomobject]@{
            Agent = 'codex-nightly'
            CapabilityAdapter = 'codex'
        }

        Get-OrchestraReadinessAgentName -PaneSummary $summary | Should -Be 'codex'

        $legacySummary = [pscustomobject]@{
            Agent = 'codex'
            CapabilityAdapter = ''
        }

        Get-OrchestraReadinessAgentName -PaneSummary $legacySummary | Should -Be 'codex'
        $script:orchestraStartContent | Should -Match '\$readinessAgent\s*=\s*Get-OrchestraReadinessAgentName -PaneSummary \$paneSummary'
        $script:orchestraStartContent | Should -Match 'Wait-AgentReady -PaneId \$paneSummary\.PaneId -Agent \$readinessAgent'
    }

    It 'uses the capability adapter for startup exec-mode labels' {
        $script:orchestraStartContent | Should -Match '\$execModeAgent = \[string\]\$slotAgentConfig\.CapabilityAdapter'
        $script:orchestraStartContent | Should -Match '\$execMode = \$execModeAgent\.Trim\(\)\.ToLowerInvariant\(\) -eq ''codex'''
        $script:orchestraStartContent | Should -Not -Match '\$execMode = \(\[string\]\$slotAgentConfig\.Agent\)\.Trim\(\)\.ToLowerInvariant\(\) -eq ''codex'''
    }

    It 'routes partial bootstrap invalid state into the startup rollback path by throwing' {
        {
            Assert-OrchestraBootstrapVerification -PaneSummaries @(
                [pscustomobject]@{ PaneId = '%1'; Label = 'operator' },
                [pscustomobject]@{ PaneId = '%2'; Label = 'builder-1' }
            ) -InvalidCount 1 -ReadyCount 1
        } | Should -Throw -ExpectedMessage '*startup aborted because 1 pane(s) are bootstrap_invalid and only 1 of 2 expected pane(s) are ready.*'
    }

    It 'throws when bootstrap verification finds no ready panes' {
        {
            Assert-OrchestraBootstrapVerification -PaneSummaries @(
                [pscustomobject]@{ PaneId = '%1'; Label = 'operator' }
            ) -InvalidCount 1 -ReadyCount 0
        } | Should -Throw -ExpectedMessage '*no panes passed bootstrap verification*'
    }
}

Describe 'orchestra-start rollback helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-start.ps1')
    }

    BeforeEach {
        $script:orchestraStartTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-orchestra-start-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:orchestraStartTempRoot -Force | Out-Null
    }

    AfterEach {
        if ($script:orchestraStartTempRoot -and (Test-Path $script:orchestraStartTempRoot)) {
            Remove-Item -Path $script:orchestraStartTempRoot -Recurse -Force
        }
    }

    It 'kills only created non-bootstrap panes and preserves the bootstrap pane during rollback' {
        $createdWorktrees = @(
            [ordered]@{
                BranchName   = 'worktree-builder-1'
                WorktreePath = (Join-Path $script:orchestraStartTempRoot '.worktrees\builder-1')
            }
        )

        Mock Invoke-Winsmux { @('%1', '%2', '%3') } -ParameterFilter {
            $Arguments[0] -eq 'list-panes'
        }
        Mock Invoke-Winsmux { } -ParameterFilter {
            $Arguments[0] -eq 'kill-pane'
        }
        Mock Invoke-Winsmux { } -ParameterFilter {
            $Arguments[0] -eq 'respawn-pane'
        }
        Mock Wait-PaneShellReady { }
        Mock Remove-OrchestraCreatedWorktrees {
            @(
                [ordered]@{
                    BranchName   = 'worktree-builder-1'
                    WorktreePath = (Join-Path $script:orchestraStartTempRoot '.worktrees\builder-1')
                }
            )
        }

        $rollback = Invoke-OrchestraStartupRollback `
            -ProjectDir $script:orchestraStartTempRoot `
            -SessionName 'winsmux-orchestra' `
            -BootstrapPaneId '%1' `
            -CreatedPaneIds @('%1', '%2', '%3') `
            -CreatedWorktrees $createdWorktrees `
            -FailureMessage 'layout failed'

        $rollback.RemovedPaneIds | Should -Be @('%2', '%3')
        $rollback.RemovedWorktrees.Count | Should -Be 1
        $rollback.BootstrapRespawned | Should -Be $true
        $rollback.RollbackErrors.Count | Should -Be 0

        Should -Invoke Invoke-Winsmux -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'list-panes' -and
            $Arguments[1] -eq '-t' -and
            $Arguments[2] -eq 'winsmux-orchestra' -and
            $Arguments[3] -eq '-F' -and
            $Arguments[4] -eq '#{pane_id}'
        }
        Should -Invoke Invoke-Winsmux -Times 2 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'kill-pane'
        }
        Should -Invoke Invoke-Winsmux -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'respawn-pane' -and
            $Arguments[1] -eq '-k' -and
            $Arguments[2] -eq '-t' -and
            $Arguments[3] -eq '%1' -and
            $Arguments[4] -eq '-c' -and
            $Arguments[5] -eq $script:orchestraStartTempRoot
        }
        Should -Invoke Invoke-Winsmux -Times 0 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'kill-session'
        }
        Should -Invoke Wait-PaneShellReady -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%1'
        }

        $eventsPath = Join-Path $script:orchestraStartTempRoot '.winsmux\events.jsonl'
        (Test-Path $eventsPath) | Should -Be $true

        $events = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $events.Count | Should -Be 1
        $events[0].event | Should -Be 'orchestra.startup.failed'
        $events[0].pane_id | Should -Be '%1'
        $events[0].status | Should -Be 'failed'
        $events[0].data.bootstrap_respawned | Should -Be $true
        $events[0].data.removed_pane_ids | Should -Be @('%2', '%3')
        $events[0].data.removed_worktrees[0].BranchName | Should -Be 'worktree-builder-1'
    }

    It 'clears a stale manifest when startup rollback runs' {
        $manifestDir = Join-Path $script:orchestraStartTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
        Set-Content -Path (Join-Path $manifestDir 'manifest.yaml') -Value "version: '1'" -Encoding UTF8

        Mock Invoke-Winsmux { @('%1') } -ParameterFilter {
            $Arguments[0] -eq 'list-panes'
        }
        Mock Invoke-Winsmux { } -ParameterFilter {
            $Arguments[0] -eq 'respawn-pane'
        }
        Mock Wait-PaneShellReady { }
        Mock Remove-OrchestraCreatedWorktrees { @() }

        $rollback = Invoke-OrchestraStartupRollback `
            -ProjectDir $script:orchestraStartTempRoot `
            -SessionName 'winsmux-orchestra' `
            -BootstrapPaneId '%1' `
            -CreatedPaneIds @('%1') `
            -CreatedWorktrees @() `
            -FailureMessage 'health timeout'

        $rollback.RollbackErrors.Count | Should -Be 0
        (Test-Path (Join-Path $manifestDir 'manifest.yaml')) | Should -Be $false
    }

    It 'continues rollback when listing session panes fails and still removes created non-bootstrap panes' {
        Mock Invoke-Winsmux { throw 'list failure' } -ParameterFilter {
            $Arguments[0] -eq 'list-panes'
        }
        Mock Invoke-Winsmux { } -ParameterFilter {
            $Arguments[0] -eq 'kill-pane'
        }
        Mock Invoke-Winsmux { } -ParameterFilter {
            $Arguments[0] -eq 'respawn-pane'
        }
        Mock Wait-PaneShellReady { }
        Mock Remove-OrchestraCreatedWorktrees {
            [ordered]@{
                RemovedWorktrees = @()
                Errors           = @()
            }
        }

        $rollback = Invoke-OrchestraStartupRollback `
            -ProjectDir $script:orchestraStartTempRoot `
            -SessionName 'winsmux-orchestra' `
            -BootstrapPaneId '%1' `
            -CreatedPaneIds @('%1', '%2', '%3') `
            -CreatedWorktrees @() `
            -FailureMessage 'list panes unavailable'

        $rollback.RemovedPaneIds | Should -Be @('%2', '%3')
        @($rollback.RollbackErrors | Where-Object { $_ -like 'list-panes failed:*' }).Count | Should -Be 1
        Should -Invoke Invoke-Winsmux -Times 2 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'kill-pane'
        }
    }

    It 'records respawn and worktree cleanup failures in rollback errors without aborting rollback completion' {
        $createdWorktrees = @(
            [ordered]@{
                BranchName   = 'worktree-builder-1'
                WorktreePath = (Join-Path $script:orchestraStartTempRoot '.worktrees\builder-1')
            }
        )

        Mock Invoke-Winsmux { @('%1', '%2') } -ParameterFilter {
            $Arguments[0] -eq 'list-panes'
        }
        Mock Invoke-Winsmux { } -ParameterFilter {
            $Arguments[0] -eq 'kill-pane'
        }
        Mock Invoke-Winsmux { throw 'respawn failed' } -ParameterFilter {
            $Arguments[0] -eq 'respawn-pane'
        }
        Mock Wait-PaneShellReady { throw 'should not wait after respawn failure' }
        Mock Remove-OrchestraCreatedWorktrees {
            [ordered]@{
                RemovedWorktrees = @(
                    [ordered]@{
                        BranchName   = 'worktree-builder-1'
                        WorktreePath = (Join-Path $script:orchestraStartTempRoot '.worktrees\builder-1')
                    }
                )
                Errors = @('branch delete worktree-builder-1 failed with exit code 1.')
            }
        }

        $rollback = Invoke-OrchestraStartupRollback `
            -ProjectDir $script:orchestraStartTempRoot `
            -SessionName 'winsmux-orchestra' `
            -BootstrapPaneId '%1' `
            -CreatedPaneIds @('%1', '%2') `
            -CreatedWorktrees $createdWorktrees `
            -FailureMessage 'respawn path failed'

        $rollback.RemovedPaneIds | Should -Be @('%2')
        $rollback.BootstrapRespawned | Should -Be $false
        @($rollback.RollbackErrors | Where-Object { $_ -like 'respawn-pane %1 failed:*' }).Count | Should -Be 1
        @($rollback.RollbackErrors | Where-Object { $_ -like 'branch delete worktree-builder-1 failed*' }).Count | Should -Be 1

        $eventsPath = Join-Path $script:orchestraStartTempRoot '.winsmux\events.jsonl'
        $events = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $events.Count | Should -Be 1
        @($events[0].data.rollback_errors | Where-Object { $_ -like 'respawn-pane %1 failed:*' }).Count | Should -Be 1
        @($events[0].data.rollback_errors | Where-Object { $_ -like 'branch delete worktree-builder-1 failed*' }).Count | Should -Be 1
    }

    It 'surfaces worktree cleanup exit-code failures without dropping the attempted cleanup record' {
        $worktreePath = Join-Path $script:orchestraStartTempRoot '.worktrees\builder-1'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        $originalGitFunction = Get-Item -Path Function:\git -ErrorAction SilentlyContinue

        function global:git {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)

            if ($Args[2] -eq 'worktree' -and $Args[3] -eq 'remove') {
                $global:LASTEXITCODE = 1
                return
            }

            if ($Args[2] -eq 'branch' -and $Args[3] -eq 'worktree-builder-1') {
                $global:LASTEXITCODE = 1
                return
            }

            if ($Args[2] -eq 'rev-parse') {
                $global:LASTEXITCODE = 0
                return
            }

            $global:LASTEXITCODE = 0
        }

        try {
            $result = Remove-OrchestraCreatedWorktrees `
                -ProjectDir $script:orchestraStartTempRoot `
                -CreatedWorktrees @(
                    [ordered]@{
                        BranchName   = 'worktree-builder-1'
                        WorktreePath = $worktreePath
                    }
                )

            @($result.RemovedWorktrees).Count | Should -Be 1
            @($result.Errors | Where-Object { $_ -like 'worktree remove *' }).Count | Should -Be 1
            @($result.Errors | Where-Object { $_ -like 'branch delete worktree-builder-1 failed*' }).Count | Should -Be 1
            (Test-Path -LiteralPath $worktreePath) | Should -Be $true
        } finally {
            Remove-Item -Path Function:\git -ErrorAction SilentlyContinue
            if ($null -ne $originalGitFunction) {
                Set-Item -Path Function:\git -Value $originalGitFunction.ScriptBlock
            }
        }
    }

    It 'writes a pane bootstrap plan and launches it with a single bootstrap command after respawn' {
        $sentCommands = [System.Collections.Generic.List[string]]::new()
        $bridgeCalls = [System.Collections.Generic.List[object]]::new()
        $planRoot = Join-Path $script:orchestraStartTempRoot '.winsmux\orchestra-bootstrap'
        $cleanPtyEnv = [PSCustomObject]@{
            RemoveCommand = "Get-ChildItem Env: | Where-Object { `$_.Name -like 'WINSMUX_*' } | ForEach-Object { Remove-Item -LiteralPath ('Env:' + `$_.Name) -ErrorAction SilentlyContinue }"
            Environment   = [ordered]@{
                WINSMUX_ROLE            = 'Worker'
                WINSMUX_GOVERNANCE_MODE = 'enhanced'
            }
        }

        Mock Wait-PaneShellReady { }
        Mock Invoke-Bridge {
            $bridgeCalls.Add([ordered]@{
                Arguments    = @($Arguments)
                CaptureOutput = [bool]$CaptureOutput
                AllowFailure  = [bool]$AllowFailure
            }) | Out-Null

            return [ordered]@{
                ExitCode = 0
                Output   = @()
            }
        } -ParameterFilter {
            $Arguments[0] -eq 'keys'
        }
        Mock Send-OrchestraBridgeCommand {
            $sentCommands.Add($Text) | Out-Null
        }

        $planPath = New-OrchestraPaneBootstrapPlan `
            -ProjectDir $script:orchestraStartTempRoot `
            -PaneId '%2' `
            -Label 'worker-1' `
            -Role 'Worker' `
            -Agent 'codex' `
            -Model 'gpt-5.4' `
            -StartupToken 'token-123' `
            -LaunchDir 'C:\repo\.worktrees\builder-1' `
            -CleanPtyEnv $cleanPtyEnv `
            -LaunchCommand 'codex --help'

        Start-OrchestraPaneBootstrap -PaneId '%2' -PlanPath $planPath

        Should -Invoke Wait-PaneShellReady -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%2'
        }
        (Test-Path -LiteralPath $planRoot) | Should -Be $true
        (Test-Path -LiteralPath $planPath) | Should -Be $true
        $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 8
        [string]$plan.launch_dir | Should -Be 'C:\repo\.worktrees\builder-1'
        [string]$plan.environment.WINSMUX_ROLE | Should -Be 'Worker'
        [string]$plan.environment.WINSMUX_GOVERNANCE_MODE | Should -Be 'enhanced'
        [string]$plan.launch_command | Should -Be 'codex --help'
        [bool]$plan.supports_interrupt | Should -Be $true
        [string]$plan.startup_token | Should -Be 'token-123'
        [string]$plan.ready_marker_path | Should -Match '[\\/]2-token-123\.ready\.json$'
        $bridgeCalls.Count | Should -Be 1
        @($bridgeCalls[0].Arguments) | Should -Be @('keys', '%2', 'C-c')
        $sentCommands.Count | Should -Be 1
        $sentCommands[0] | Should -Match 'orchestra-pane-bootstrap\.ps1'
        $sentCommands[0] | Should -Match '-PlanFile'
    }

    It 'does not send an interrupt key when the provider cannot interrupt' {
        $sentCommands = [System.Collections.Generic.List[string]]::new()
        $bridgeCalls = [System.Collections.Generic.List[object]]::new()
        $cleanPtyEnv = [PSCustomObject]@{
            RemoveCommand = ''
            Environment   = [ordered]@{
                WINSMUX_ROLE = 'Worker'
            }
        }

        Mock Wait-PaneShellReady { }
        Mock Invoke-Bridge {
            $bridgeCalls.Add([ordered]@{
                Arguments    = @($Arguments)
                CaptureOutput = [bool]$CaptureOutput
                AllowFailure  = [bool]$AllowFailure
            }) | Out-Null

            return [ordered]@{
                ExitCode = 0
                Output   = @()
            }
        } -ParameterFilter {
            $Arguments[0] -eq 'keys'
        }
        Mock Send-OrchestraBridgeCommand {
            $sentCommands.Add($Text) | Out-Null
        }

        $planPath = New-OrchestraPaneBootstrapPlan `
            -ProjectDir $script:orchestraStartTempRoot `
            -PaneId '%2' `
            -Label 'worker-1' `
            -Role 'Worker' `
            -Agent 'example' `
            -Model 'example-model' `
            -StartupToken 'token-456' `
            -LaunchDir 'C:\repo\.worktrees\builder-1' `
            -CleanPtyEnv $cleanPtyEnv `
            -LaunchCommand 'example-agent --help' `
            -SupportsInterrupt $false

        Start-OrchestraPaneBootstrap -PaneId '%2' -PlanPath $planPath

        Should -Invoke Wait-PaneShellReady -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%2'
        }
        $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 8
        [bool]$plan.supports_interrupt | Should -Be $false
        $bridgeCalls.Count | Should -Be 0
        $sentCommands.Count | Should -Be 1
        $sentCommands[0] | Should -Match 'orchestra-pane-bootstrap\.ps1'
        $sentCommands[0] | Should -Match '-PlanFile'
    }

    It 'keeps bootstrap interrupts enabled when the capability flag is absent' {
        $unknownInterrupt = [PSCustomObject]@{
            CapabilityAdapter = 'example'
            CapabilityCommand = 'example'
            SupportsInterrupt = $false
        }
        $explicitNoInterrupt = [PSCustomObject]@{
            CapabilityAdapter = 'example'
            CapabilityCommand = 'example'
            SupportsInterrupt = $false
            SupportsInterruptDeclared = $true
        }
        $legacyConfig = [PSCustomObject]@{
            Agent = 'example'
            Model = 'example-model'
            SupportsInterrupt = $false
        }

        Test-OrchestraProviderInterruptAvailable -SlotAgentConfig $unknownInterrupt | Should -Be $true
        Test-OrchestraProviderInterruptAvailable -SlotAgentConfig $explicitNoInterrupt | Should -Be $false
        Test-OrchestraProviderInterruptAvailable -SlotAgentConfig $legacyConfig | Should -Be $true
    }
}

Describe 'doctor bridge config metadata check' {
    BeforeAll {
        $script:__winsmux_doctor_functions_only = $true
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\doctor.ps1')
        Remove-Variable -Name __winsmux_doctor_functions_only -Scope Script -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:doctorTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-doctor-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:doctorTempRoot -Force | Out-Null
    }

    AfterEach {
        if ($script:doctorTempRoot -and (Test-Path $script:doctorTempRoot)) {
            Remove-Item -Path $script:doctorTempRoot -Recurse -Force
        }
    }

    It 'fails bridge config metadata check when .winsmux.yaml is missing' {
        Mock Get-DoctorRepoRoot { $script:doctorTempRoot }

        $result = Test-BridgeConfigMetadataCheck

        $result.Status | Should -Be 'fail'
        $result.Label | Should -Be 'Bridge config metadata'
        $result.Detail | Should -Be '.winsmux.yaml not found'
    }

    It 'fails worker drift check with operator remediation text' {
        Mock Get-DoctorRepoRoot { $script:doctorTempRoot }
        Mock Get-DoctorGitCommandPath { 'git' }
        Mock Get-WinsmuxManifest { [pscustomobject]@{} }
        Mock Get-WinsmuxWorkerIsolationReport {
            [pscustomobject]@{
                ok          = $false
                summary     = '1 worker isolation issue'
                findings    = @([pscustomobject]@{ label = 'worker-1'; message = 'branch is main; expected worktree-worker-1' })
                remediation = 'Run git add, git commit, git push, and PR merge from the Operator shell.'
            }
        }

        New-Item -ItemType Directory -Path (Join-Path $script:doctorTempRoot '.winsmux') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:doctorTempRoot '.winsmux\manifest.yaml') -Force | Out-Null

        $result = Test-WorkerGitDriftCheck

        $result.Status | Should -Be 'fail'
        $result.Label | Should -Be 'Worker isolation drift'
        $result.Detail | Should -Match 'branch is main'
        $result.Detail | Should -Match 'Operator shell'
    }

    It 'warns when too many background PowerShell processes remain' {
        $protectedIds = [System.Collections.Generic.HashSet[int]]::new()
        $protectedIds.Add(1001) | Out-Null
        $snapshot = [pscustomobject]@{
            Processes = @(
                [pscustomobject]@{ ProcessId = 1001; ParentProcessId = 0; Name = 'pwsh.exe'; CommandLine = 'pwsh -NoProfile' }
                [pscustomobject]@{ ProcessId = 1002; ParentProcessId = 0; Name = 'pwsh.exe'; CommandLine = 'pwsh -NoProfile -Command secret-value' }
                [pscustomobject]@{ ProcessId = 1003; ParentProcessId = 0; Name = 'powershell.exe'; CommandLine = 'powershell -NoProfile' }
                [pscustomobject]@{ ProcessId = 1004; ParentProcessId = 0; Name = 'cmd.exe'; CommandLine = 'cmd /c echo ignored' }
            )
            ById = @{}
            SupportsCommandLine = $true
        }

        $result = New-PowerShellProcessPressureResult -Snapshot $snapshot -ProtectedIds $protectedIds -WarnThreshold 2

        $result.Status | Should -Be 'warn'
        $result.Label | Should -Be 'PowerShell process pressure'
        $result.Detail | Should -Be '2 found; close unneeded pwsh.exe or powershell.exe sessions before starting more winsmux panes'
        $result.Detail | Should -Not -Match 'secret-value'
        $result.Detail | Should -Not -Match '1002'
    }

    It 'passes when background PowerShell process count stays below the warning threshold' {
        $protectedIds = [System.Collections.Generic.HashSet[int]]::new()
        $snapshot = [pscustomobject]@{
            Processes = @(
                [pscustomobject]@{ ProcessId = 1101; ParentProcessId = 0; Name = 'pwsh'; CommandLine = '' }
                [pscustomobject]@{ ProcessId = 1102; ParentProcessId = 0; Name = 'codex.exe'; CommandLine = '' }
            )
            ById = @{}
            SupportsCommandLine = $true
        }

        $result = New-PowerShellProcessPressureResult -Snapshot $snapshot -ProtectedIds $protectedIds -WarnThreshold 2

        $result.Status | Should -Be 'pass'
        $result.Label | Should -Be 'PowerShell process pressure'
        $result.Detail | Should -Be '1 found'
    }

    It 'uses the environment override for the PowerShell process warning threshold' {
        $originalValue = $env:WINSMUX_DOCTOR_POWERSHELL_PROCESS_WARN_THRESHOLD
        try {
            $env:WINSMUX_DOCTOR_POWERSHELL_PROCESS_WARN_THRESHOLD = '7'
            Get-DoctorPowerShellProcessWarnThreshold | Should -Be 7

            $env:WINSMUX_DOCTOR_POWERSHELL_PROCESS_WARN_THRESHOLD = 'invalid'
            Get-DoctorPowerShellProcessWarnThreshold | Should -Be 100
        } finally {
            $env:WINSMUX_DOCTOR_POWERSHELL_PROCESS_WARN_THRESHOLD = $originalValue
        }
    }
}

Describe 'worker isolation diagnostics' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\worker-isolation.ps1')
    }

    BeforeEach {
        $script:workerIsolationTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-worker-isolation-tests-' + [guid]::NewGuid().ToString('N'))
        $script:workerIsolationWorktree = Join-Path $script:workerIsolationTempRoot '.worktrees\worker-1'
        $script:workerIsolationGitDir = Join-Path $script:workerIsolationTempRoot '.git\worktrees\worker-1'
        New-Item -ItemType Directory -Path $script:workerIsolationWorktree -Force | Out-Null
        New-Item -ItemType Directory -Path $script:workerIsolationGitDir -Force | Out-Null
    }

    AfterEach {
        if ($script:workerIsolationTempRoot -and (Test-Path $script:workerIsolationTempRoot)) {
            Remove-Item -Path $script:workerIsolationTempRoot -Recurse -Force
        }
    }

    BeforeAll {
        function script:New-TestWorkerIsolationManifest {
            param(
                [string]$ExpectedOrigin = 'https://github.com/example/repo.git',
                [string]$Role = 'Worker'
            )

            [pscustomobject]@{
                panes = [ordered]@{
                    'worker-1' = [pscustomobject]@{
                        role                  = $Role
                        launch_dir            = $script:workerIsolationWorktree
                        builder_worktree_path = $script:workerIsolationWorktree
                        builder_branch        = 'worktree-worker-1'
                        worktree_git_dir      = $script:workerIsolationGitDir
                        expected_origin       = $ExpectedOrigin
                    }
                }
            }
        }

        function script:New-TestWorkerIsolationGitInvoker {
            param(
                [string]$Branch = 'worktree-worker-1',
                [string]$Origin = 'https://github.com/example/repo.git'
            )

            return {
                param([string]$WorktreePath, [string[]]$Arguments)

                switch ($Arguments -join ' ') {
                    'rev-parse --show-toplevel' { $WorktreePath; break }
                    'branch --show-current' { $Branch; break }
                    'config --get remote.origin.url' { $Origin; break }
                    'rev-parse --git-dir' { $script:workerIsolationGitDir; break }
                    default { throw "unexpected git args: $($Arguments -join ' ')" }
                }
            }.GetNewClosure()
        }
    }

    It 'passes when worker root, branch, origin, and gitdir match the manifest' {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\worker-isolation.ps1')

        $report = Get-WinsmuxWorkerIsolationReport `
            -ProjectDir $script:workerIsolationTempRoot `
            -Manifest (New-TestWorkerIsolationManifest) `
            -GitPath 'git' `
            -GitInvoker {
                param([string]$WorktreePath, [string[]]$Arguments)

                switch ($Arguments -join ' ') {
                    'rev-parse --show-toplevel' { $WorktreePath; break }
                    'branch --show-current' { 'worktree-worker-1'; break }
                    'config --get remote.origin.url' { 'https://github.com/example/repo.git'; break }
                    'rev-parse --git-dir' { $script:workerIsolationGitDir; break }
                    default { throw "unexpected git args: $($Arguments -join ' ')" }
                }
            }

        $report.ok | Should -Be $true
        $report.status | Should -Be 'pass'
        $report.worker_count | Should -Be 1
        $report.summary | Should -Be '1 worker pane(s) isolated'
    }

    It 'audits legacy Builder panes with worktree metadata' {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\worker-isolation.ps1')

        $report = Get-WinsmuxWorkerIsolationReport `
            -ProjectDir $script:workerIsolationTempRoot `
            -Manifest (New-TestWorkerIsolationManifest -Role 'Builder') `
            -GitPath 'git' `
            -GitInvoker (New-TestWorkerIsolationGitInvoker -Branch 'main')

        $report.ok | Should -Be $false
        $report.worker_count | Should -Be 1
        $report.findings[0].message | Should -Match 'branch is main'
    }

    It 'audits pane entries that expose worktree metadata even without worker role' {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\worker-isolation.ps1')

        $report = Get-WinsmuxWorkerIsolationReport `
            -ProjectDir $script:workerIsolationTempRoot `
            -Manifest (New-TestWorkerIsolationManifest -Role 'Researcher') `
            -GitPath 'git' `
            -GitInvoker (New-TestWorkerIsolationGitInvoker -Branch 'main')

        $report.ok | Should -Be $false
        $report.worker_count | Should -Be 1
        $report.findings[0].message | Should -Match 'branch is main'
    }

    It 'ignores non-worker panes without assigned worktree metadata' {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\worker-isolation.ps1')

        $manifest = [pscustomobject]@{
            panes = [ordered]@{
                operator = [pscustomobject]@{
                    role             = 'Operator'
                    launch_dir       = $script:workerIsolationTempRoot
                    worktree_git_dir = $script:workerIsolationGitDir
                    expected_origin  = 'https://github.com/example/repo.git'
                }
            }
        }

        $report = Get-WinsmuxWorkerIsolationReport `
            -ProjectDir $script:workerIsolationTempRoot `
            -Manifest $manifest `
            -GitPath 'git' `
            -GitInvoker (New-TestWorkerIsolationGitInvoker -Branch 'main')

        $report.ok | Should -Be $true
        $report.worker_count | Should -Be 0
    }

    It 'allows scaled worker panes before gitdir and origin metadata are refreshed' {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\worker-isolation.ps1')

        $manifest = [pscustomobject]@{
            panes = [ordered]@{
                'worker-7' = [pscustomobject]@{
                    role                  = 'Worker'
                    launch_dir            = $script:workerIsolationWorktree
                    builder_worktree_path = $script:workerIsolationWorktree
                    builder_branch        = 'worktree-worker-1'
                }
            }
        }

        $report = Get-WinsmuxWorkerIsolationReport `
            -ProjectDir $script:workerIsolationTempRoot `
            -Manifest $manifest `
            -GitPath 'git' `
            -GitInvoker (New-TestWorkerIsolationGitInvoker)

        $report.ok | Should -Be $true
        $report.worker_count | Should -Be 1
    }

    It 'allows local-only repositories when expected origin is recorded as empty' {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\worker-isolation.ps1')

        $report = Get-WinsmuxWorkerIsolationReport `
            -ProjectDir $script:workerIsolationTempRoot `
            -Manifest (New-TestWorkerIsolationManifest -ExpectedOrigin '') `
            -GitPath 'git' `
            -GitInvoker {
                param([string]$WorktreePath, [string[]]$Arguments)

                switch ($Arguments -join ' ') {
                    'rev-parse --show-toplevel' { $WorktreePath; break }
                    'branch --show-current' { 'worktree-worker-1'; break }
                    'config --get remote.origin.url' { throw 'remote origin not configured' }
                    'rev-parse --git-dir' { $script:workerIsolationGitDir; break }
                    default { throw "unexpected git args: $($Arguments -join ' ')" }
                }
            }

        $report.ok | Should -Be $true
        $report.findings.Count | Should -Be 0
    }

    It 'fails when expected origin is empty but the worker has an origin' {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\worker-isolation.ps1')

        $report = Get-WinsmuxWorkerIsolationReport `
            -ProjectDir $script:workerIsolationTempRoot `
            -Manifest (New-TestWorkerIsolationManifest -ExpectedOrigin '') `
            -GitPath 'git' `
            -GitInvoker (New-TestWorkerIsolationGitInvoker -Origin 'https://github.com/example/repo.git')

        $report.ok | Should -Be $false
        $report.findings[0].message | Should -Match 'expected no origin'
    }

    It 'fails when expected gitdir is recorded as empty' {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\worker-isolation.ps1')

        $manifest = New-TestWorkerIsolationManifest
        $manifest.panes.'worker-1'.worktree_git_dir = ''

        $report = Get-WinsmuxWorkerIsolationReport `
            -ProjectDir $script:workerIsolationTempRoot `
            -Manifest $manifest `
            -GitPath 'git' `
            -GitInvoker (New-TestWorkerIsolationGitInvoker)

        $report.ok | Should -Be $false
        $report.findings[0].message | Should -Be 'worktree_git_dir is empty'
    }

    It 'fails when actual gitdir drifts from the manifest' {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\worker-isolation.ps1')

        $otherGitDir = Join-Path $script:workerIsolationTempRoot '.git\worktrees\other-worker'
        $report = Get-WinsmuxWorkerIsolationReport `
            -ProjectDir $script:workerIsolationTempRoot `
            -Manifest (New-TestWorkerIsolationManifest) `
            -GitPath 'git' `
            -GitInvoker {
                param([string]$WorktreePath, [string[]]$Arguments)

                switch ($Arguments -join ' ') {
                    'rev-parse --show-toplevel' { $WorktreePath; break }
                    'branch --show-current' { 'worktree-worker-1'; break }
                    'config --get remote.origin.url' { 'https://github.com/example/repo.git'; break }
                    'rev-parse --git-dir' { $otherGitDir; break }
                    default { throw "unexpected git args: $($Arguments -join ' ')" }
                }
            }

        $report.ok | Should -Be $false
        $report.findings[0].message | Should -Match 'gitdir is'
    }

    It 'fails when the worker branch drifts from the manifest' {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\worker-isolation.ps1')

        $report = Get-WinsmuxWorkerIsolationReport `
            -ProjectDir $script:workerIsolationTempRoot `
            -Manifest (New-TestWorkerIsolationManifest) `
            -GitPath 'git' `
            -GitInvoker (New-TestWorkerIsolationGitInvoker -Branch 'main')

        $report.ok | Should -Be $false
        $report.status | Should -Be 'fail'
        $report.findings[0].message | Should -Match 'branch is main'
        $report.remediation | Should -Match 'Operator shell'
    }

    It 'passes when actual origin only differs by credentials' {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\worker-isolation.ps1')

        $report = Get-WinsmuxWorkerIsolationReport `
            -ProjectDir $script:workerIsolationTempRoot `
            -Manifest (New-TestWorkerIsolationManifest -ExpectedOrigin 'https://github.com/example/repo.git') `
            -GitPath 'git' `
            -GitInvoker {
                param([string]$WorktreePath, [string[]]$Arguments)

                switch ($Arguments -join ' ') {
                    'rev-parse --show-toplevel' { $WorktreePath; break }
                    'branch --show-current' { 'worktree-worker-1'; break }
                    'config --get remote.origin.url' { 'https://actual-token@github.com/example/repo.git'; break }
                    'rev-parse --git-dir' { $script:workerIsolationGitDir; break }
                    default { throw "unexpected git args: $($Arguments -join ' ')" }
                }
            }

        $report.ok | Should -Be $true
        $report.findings.Count | Should -Be 0
        $report.workers[0].actual_origin | Should -Be 'https://[redacted]@github.com/example/repo.git'
    }

    It 'redacts credentials from origin drift findings' {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\worker-isolation.ps1')

        $report = Get-WinsmuxWorkerIsolationReport `
            -ProjectDir $script:workerIsolationTempRoot `
            -Manifest (New-TestWorkerIsolationManifest -ExpectedOrigin 'ssh://expected-token@example.com/example/repo.git') `
            -GitPath 'git' `
            -GitInvoker (New-TestWorkerIsolationGitInvoker -Origin 'ssh://actual-token@github.com/example/other.git')

        $message = ($report.findings | ForEach-Object { $_.message }) -join '; '
        $message | Should -Match '\[redacted\]@github.com'
        $message | Should -Match '\[redacted\]@example.com'
        $message | Should -Not -Match 'expected-token'
        $message | Should -Not -Match 'actual-token'
    }
}

Describe 'pane scaler helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\pane-scaler.ps1')
    }

    BeforeEach {
        $script:paneScalerTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-pane-scaler-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:paneScalerTempRoot -Force | Out-Null
        $script:paneScalerManifestDir = Join-Path $script:paneScalerTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:paneScalerManifestDir -Force | Out-Null
        $script:paneScalerManifestPath = Join-Path $script:paneScalerManifestDir 'manifest.yaml'
    }

    AfterEach {
        if ($script:paneScalerTempRoot -and (Test-Path $script:paneScalerTempRoot)) {
            Remove-Item -Path $script:paneScalerTempRoot -Recurse -Force
        }
    }

    It 'calculates Builder workload using busy and approval_waiting panes' {
        @"
version: 1
saved_at: 2026-04-05T10:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:paneScalerTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
  - label: builder-2
    pane_id: %3
    role: Builder
  - label: builder-3
    pane_id: %4
    role: Builder
"@ | Set-Content -Path $script:paneScalerManifestPath -Encoding UTF8

        Mock Get-PaneAgentStatus {
            param($PaneId)

            switch ($PaneId) {
                '%2' { [PSCustomObject]@{ Status = 'busy'; ExitReason = '' } }
                '%3' { [PSCustomObject]@{ Status = 'approval_waiting'; ExitReason = '' } }
                default { [PSCustomObject]@{ Status = 'ready'; ExitReason = '' } }
            }
        }

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            roles = [ordered]@{}
        }

        $workload = Get-PaneWorkload -ManifestPath $script:paneScalerManifestPath -Settings $settings

        $workload.BusyPanes | Should -Be 2
        $workload.TotalPanes | Should -Be 3
        $workload.BuilderCount | Should -Be 3
        $workload.BusyRatio | Should -BeGreaterThan 0.66
        $workload.BusyRatio | Should -BeLessThan 0.67
    }

    It 'uses provider registry overrides when calculating Builder workload' {
        @"
version: 1
saved_at: 2026-04-05T10:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:paneScalerTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
"@ | Set-Content -Path $script:paneScalerManifestPath -Encoding UTF8
        Write-BridgeProviderRegistryEntry `
            -RootPath $script:paneScalerTempRoot `
            -SlotId 'builder-1' `
            -Agent 'claude' `
            -Model 'opus' `
            -PromptTransport 'file' `
            -Reason 'operator requested provider hot-swap' | Out-Null

        Mock Get-PaneAgentStatus {
            [PSCustomObject]@{ Status = 'ready'; ExitReason = '' }
        }

        Get-PaneWorkload -ManifestPath $script:paneScalerManifestPath | Out-Null

        Should -Invoke Get-PaneAgentStatus -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%2' -and $Agent -eq 'claude' -and $Role -eq 'Builder'
        }
    }

    It 'uses capability adapters when calculating Builder workload' {
        @"
version: 1
saved_at: 2026-04-05T10:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:paneScalerTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
"@ | Set-Content -Path $script:paneScalerManifestPath -Encoding UTF8

        Mock Get-SlotAgentConfig {
            [PSCustomObject]@{
                Agent             = 'codex-nightly'
                Model             = 'gpt-5.4-nightly'
                CapabilityAdapter = 'codex'
            }
        }
        Mock Get-PaneAgentStatus {
            [PSCustomObject]@{ Status = 'ready'; ExitReason = '' }
        }

        Get-PaneWorkload -ManifestPath $script:paneScalerManifestPath -Settings ([ordered]@{ agent = 'codex-nightly'; model = 'gpt-5.4-nightly'; roles = [ordered]@{} }) | Out-Null

        Should -Invoke Get-PaneAgentStatus -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%2' -and $Agent -eq 'codex' -and $Role -eq 'Builder'
        }
    }

    It 'uses provider registry overrides through the pane scaling entrypoint without explicit settings' {
        @"
version: 1
saved_at: 2026-04-05T10:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:paneScalerTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
"@ | Set-Content -Path $script:paneScalerManifestPath -Encoding UTF8
        Write-BridgeProviderRegistryEntry `
            -RootPath $script:paneScalerTempRoot `
            -SlotId 'builder-1' `
            -Agent 'claude' `
            -Model 'opus' `
            -PromptTransport 'file' `
            -Reason 'operator requested provider hot-swap' | Out-Null

        Mock Get-PaneAgentStatus {
            [PSCustomObject]@{ Status = 'ready'; ExitReason = '' }
        }

        Push-Location ([System.IO.Path]::GetTempPath())
        try {
            Invoke-PaneScalingCheck -ManifestPath $script:paneScalerManifestPath -ScaleUpThreshold 0.95 -ScaleDownThreshold 0.0 | Out-Null
        } finally {
            Pop-Location
        }

        Should -Invoke Get-PaneAgentStatus -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%2' -and $Agent -eq 'claude' -and $Role -eq 'Builder'
        }
    }

    It 'fails closed when the provider registry is malformed during Builder workload calculation' {
        @"
version: 1
saved_at: 2026-04-05T10:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:paneScalerTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
"@ | Set-Content -Path $script:paneScalerManifestPath -Encoding UTF8
        @'
{
  "version": 1,
  "slots": {
    "builder-1": {
      "prompt_transport": "pipe"
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:paneScalerManifestDir 'provider-registry.json') -Encoding UTF8

        Mock Get-PaneAgentStatus {
            throw 'Get-PaneAgentStatus should not be called when provider registry is malformed.'
        }

        {
            Get-PaneWorkload -ManifestPath $script:paneScalerManifestPath
        } | Should -Throw "*Invalid provider registry prompt_transport*"
    }

    It 'fails closed when provider registry structure is invalid through the pane scaling entrypoint' {
        $cases = @(
            [PSCustomObject]@{
                Name = 'slots array'
                Body = @'
{
  "version": 1,
  "slots": []
}
'@
                Message = '*provider registry slots*'
            },
            [PSCustomObject]@{
                Name = 'scalar slot entry'
                Body = @'
{
  "version": 1,
  "slots": {
    "builder-1": "claude"
  }
}
'@
                Message = "*provider registry slot 'builder-1'*"
            },
            [PSCustomObject]@{
                Name = 'metadata-only slot entry'
                Body = @'
{
  "version": 1,
  "slots": {
    "builder-1": {
      "updated_at_utc": "2026-04-21T00:00:00Z",
      "reason": "metadata only"
    }
  }
}
'@
                Message = "*provider registry slot 'builder-1'*"
            },
            [PSCustomObject]@{
                Name = 'non-scalar provider field'
                Body = @'
{
  "version": 1,
  "slots": {
    "builder-1": {
      "agent": {
        "name": "claude"
      },
      "model": "opus"
    }
  }
}
'@
                Message = "*provider registry field 'agent'*"
            }
        )

        foreach ($case in $cases) {
            @"
version: 1
saved_at: 2026-04-05T10:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:paneScalerTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
"@ | Set-Content -Path $script:paneScalerManifestPath -Encoding UTF8
            $case.Body | Set-Content -Path (Join-Path $script:paneScalerManifestDir 'provider-registry.json') -Encoding UTF8

            Mock Get-PaneAgentStatus {
                throw "Get-PaneAgentStatus should not be called for malformed provider registry case '$($case.Name)'."
            }

            Push-Location ([System.IO.Path]::GetTempPath())
            try {
                {
                    Invoke-PaneScalingCheck -ManifestPath $script:paneScalerManifestPath -ScaleUpThreshold 0.95 -ScaleDownThreshold 0.0
                } | Should -Throw $case.Message
            } finally {
                Pop-Location
            }
        }
    }

    It 'reads dictionary-style pane manifests written by orchestra-start' {
        @"
version: 1
saved_at: 2026-04-05T10:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:paneScalerTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
  builder-2:
    pane_id: %3
    role: Builder
"@ | Set-Content -Path $script:paneScalerManifestPath -Encoding UTF8

        $manifest = Read-PaneScalerManifest -ManifestPath $script:paneScalerManifestPath

        $manifest.Panes.Keys | Should -Be @('builder-1', 'builder-2')
        $manifest.Panes['builder-1'].pane_id | Should -Be '%2'
        $manifest.Panes['builder-2'].role | Should -Be 'Builder'
    }

    It 'writes canonical dictionary-style panes when saving the manifest' {
        $manifest = [PSCustomObject]@{
            Version = 1
            SavedAt = '2026-04-09T11:00:00+09:00'
            Session = [ordered]@{
                name = 'winsmux-orchestra'
                project_dir = $script:paneScalerTempRoot
            }
            Panes = [ordered]@{
                'builder-1' = [ordered]@{
                    pane_id = '%2'
                    role = 'Builder'
                    launch_dir = $script:paneScalerTempRoot
                }
            }
            Tasks = [PSCustomObject]@{
                queued = @()
                in_progress = @()
                completed = @()
            }
            Worktrees = [ordered]@{}
        }

        Save-PaneScalerManifest -ManifestPath $script:paneScalerManifestPath -Manifest $manifest

        $content = Get-Content -Path $script:paneScalerManifestPath -Raw -Encoding UTF8
        $content | Should -Match "panes:\r?\n  'builder-1':"
        $content | Should -Not -Match "panes:\r?\n  - label:"
        $content | Should -Match "saved_at: '2026-04-09T11:00:00\+09:00'"
    }

    It 'uses provider registry overrides when adding a Builder pane' {
        @"
version: 1
saved_at: 2026-04-05T10:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:paneScalerTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    launch_dir: $script:paneScalerTempRoot
"@ | Set-Content -Path $script:paneScalerManifestPath -Encoding UTF8
        Write-BridgeProviderRegistryEntry `
            -RootPath $script:paneScalerTempRoot `
            -SlotId 'builder-2' `
            -Agent 'claude' `
            -Model 'opus' `
            -PromptTransport 'file' `
            -Reason 'operator requested provider hot-swap' | Out-Null

        Mock New-PaneScalerBuilderWorktree {
            [PSCustomObject]@{
                BranchName     = 'worktree-builder-2'
                WorktreePath   = Join-Path $script:paneScalerTempRoot '.worktrees\builder-2'
                GitWorktreeDir = Join-Path $script:paneScalerTempRoot '.git\worktrees\builder-2'
            }
        }
        Mock Invoke-MonitorWinsmux {
            if ($Arguments -contains '-F') {
                return '%3'
            }
            return ''
        }
        Mock Wait-MonitorPaneShellReady { }
        Mock Send-MonitorBridgeCommand { }

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            roles = [ordered]@{
                builder = [ordered]@{
                    agent = 'codex'
                    model = 'gpt-5.4'
                }
            }
        }

        Add-OrchestraPane -ManifestPath $script:paneScalerManifestPath -Settings $settings | Out-Null

        Should -Invoke Send-MonitorBridgeCommand -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%3' -and $Text -eq "claude --model 'opus' --permission-mode bypassPermissions"
        }
    }

    It 'scales up when workload exceeds the threshold' {
        $manifest = [PSCustomObject]@{
            Panes = [ordered]@{
                'builder-1' = [PSCustomObject]@{ pane_id = '%2'; role = 'Builder' }
                'builder-2' = [PSCustomObject]@{ pane_id = '%3'; role = 'Builder' }
                'builder-3' = [PSCustomObject]@{ pane_id = '%4'; role = 'Builder' }
            }
        }
        Mock Get-PaneWorkload {
            [PSCustomObject]@{
                Manifest     = $manifest
                ProjectDir   = $script:paneScalerTempRoot
                BusyRatio    = 0.9
                BusyPanes    = 3
                TotalPanes   = 3
                BuilderCount = 3
                Results      = @()
            }
        }
        Mock Add-OrchestraPane {
            [PSCustomObject]@{
                Changed = $true
                Action  = 'scale_up'
                Label   = 'builder-4'
                PaneId  = '%8'
            }
        }
        Mock Remove-OrchestraPane { throw 'should not remove' }

        $result = Invoke-PaneScalingCheck -ManifestPath $script:paneScalerManifestPath -Settings ([ordered]@{ agent = 'codex'; model = 'gpt-5.4'; roles = [ordered]@{} })

        $result.Action | Should -Be 'scale_up'
        $result.Label | Should -Be 'builder-4'
        Should -Invoke Add-OrchestraPane -Times 1 -Exactly
        Should -Invoke Remove-OrchestraPane -Times 0 -Exactly
    }

    It 'does not scale up when the next Builder provider cannot run in parallel' {
        @"
version: 1
saved_at: 2026-04-05T10:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:paneScalerTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
  builder-2:
    pane_id: %3
    role: Builder
  builder-3:
    pane_id: %4
    role: Builder
"@ | Set-Content -Path $script:paneScalerManifestPath -Encoding UTF8

        @'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "prompt_transports": ["argv"],
      "supports_parallel_runs": false,
      "supports_interrupt": true,
      "supports_structured_result": true,
      "supports_file_edit": true,
      "supports_subagents": true,
      "supports_verification": true,
      "supports_consultation": false
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:paneScalerManifestDir 'provider-capabilities.json') -Encoding UTF8

        Mock Get-PaneAgentStatus {
            [PSCustomObject]@{ Status = 'busy'; ExitReason = '' }
        }
        Mock Add-OrchestraPane { throw 'should not add a Builder pane without parallel-run support' }
        Mock Remove-OrchestraPane { throw 'should not remove' }

        $result = Invoke-PaneScalingCheck -ManifestPath $script:paneScalerManifestPath -ScaleUpThreshold 0.8 -ScaleDownThreshold 0.0

        $result.Action | Should -Be 'no_change'
        $result.Reason | Should -Be 'parallel_runs_unsupported'
        $result.Provider | Should -Be 'codex'
        $result.SlotId | Should -Be 'builder-4'
        Should -Invoke Add-OrchestraPane -Times 0 -Exactly
    }

    It 'scales down when workload is low and more than two builders exist' {
        Mock Get-PaneWorkload {
            [PSCustomObject]@{
                BusyRatio    = 0.25
                BusyPanes    = 1
                TotalPanes   = 4
                BuilderCount = 4
                Results      = @(
                    [PSCustomObject]@{ Label = 'builder-1'; Status = 'busy' },
                    [PSCustomObject]@{ Label = 'builder-2'; Status = 'ready' },
                    [PSCustomObject]@{ Label = 'builder-3'; Status = 'ready' },
                    [PSCustomObject]@{ Label = 'builder-4'; Status = 'ready' }
                )
            }
        }
        Mock Remove-OrchestraPane {
            [PSCustomObject]@{
                Changed = $true
                Action  = 'scale_down'
                Label   = 'builder-4'
                PaneId  = '%9'
            }
        }
        Mock Add-OrchestraPane { throw 'should not add' }

        $result = Invoke-PaneScalingCheck -ManifestPath $script:paneScalerManifestPath -Settings ([ordered]@{ agent = 'codex'; model = 'gpt-5.4'; roles = [ordered]@{} })

        $result.Action | Should -Be 'scale_down'
        $result.Label | Should -Be 'builder-4'
        Should -Invoke Remove-OrchestraPane -Times 1 -Exactly
        Should -Invoke Add-OrchestraPane -Times 0 -Exactly
    }
}

Describe 'pane status helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\pane-status.ps1')
    }

    BeforeEach {
        $script:paneStatusTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-pane-status-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $script:paneStatusTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null

        @'
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: C:\repo\.worktrees\builder-1
    builder_worktree_path: C:\repo\.worktrees\builder-1
  - label: reviewer
    pane_id: %4
    role: Reviewer
  - label: operator
    pane_id: %1
    role: Operator
'@ | Set-Content -Path (Join-Path $manifestDir 'manifest.yaml') -Encoding UTF8
    }

    AfterEach {
        if ($script:paneStatusTempRoot -and (Test-Path $script:paneStatusTempRoot)) {
            Remove-Item -Path $script:paneStatusTempRoot -Recurse -Force
        }
    }

    It 'reads every pane entry from the orchestra manifest' {
        $entries = Get-PaneControlManifestEntries -ProjectDir $script:paneStatusTempRoot

        $entries.Count | Should -Be 3
        $entries[0].Label | Should -Be 'builder-1'
        $entries[0].PaneId | Should -Be '%2'
        $entries[0].Role | Should -Be 'Builder'
        $entries[0].GitWorktreeDir | Should -Be 'C:\repo\.worktrees\builder-1'
        $entries[1].Role | Should -Be 'Reviewer'
        $entries[2].Label | Should -Be 'operator'
    }

    It 'classifies pane captures into pwsh, codex, idle, and busy states' {
        (Get-PaneActualStateFromText -Text "PS C:\repo>") | Should -Be 'pwsh'
        (Get-PaneActualStateFromText -Text @"
gpt-5.4   82% context left
? send   Ctrl+J newline
>
"@) | Should -Be 'idle'
        (Get-PaneActualStateFromText -Text @"
Launching codex...
codex --sandbox danger-full-access -C C:\repo
"@) | Should -Be 'codex'
        (Get-PaneActualStateFromText -Text @"
gpt-5.4   61% context left
thinking
Esc to interrupt
"@) | Should -Be 'busy'
    }

    It 'uses manifest capability adapters when classifying pane captures' {
        $manifestPath = Join-Path (Join-Path $script:paneStatusTempRoot '.winsmux') 'manifest.yaml'
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
'@ | Set-Content -Path $manifestPath -Encoding UTF8

        $records = Get-PaneStatusRecords -ProjectDir $script:paneStatusTempRoot -SnapshotProvider {
            param($PaneId)

            if ($PaneId -eq '%4') {
                return 'Welcome to Claude Code!'
            }

            throw "unexpected pane id: $PaneId"
        }

        $records.Count | Should -Be 1
        $records[0].Label | Should -Be 'reviewer'
        $records[0].State | Should -Be 'idle'
    }

    It 'uses manifest provider targets when classifying pane captures' {
        $manifestPath = Join-Path (Join-Path $script:paneStatusTempRoot '.winsmux') 'manifest.yaml'
@'
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  reviewer:
    pane_id: %4
    role: Reviewer
    provider_target: claude:opus
'@ | Set-Content -Path $manifestPath -Encoding UTF8

        $records = Get-PaneStatusRecords -ProjectDir $script:paneStatusTempRoot -SnapshotProvider {
            param($PaneId)

            if ($PaneId -eq '%4') {
                return 'Welcome to Claude Code!'
            }

            throw "unexpected pane id: $PaneId"
        }

        $records.Count | Should -Be 1
        $records[0].Label | Should -Be 'reviewer'
        $records[0].State | Should -Be 'idle'
    }

    It 'builds status rows from manifest panes and capture snapshots' {
        $records = Get-PaneStatusRecords -ProjectDir $script:paneStatusTempRoot -SnapshotProvider {
            param($PaneId)

            switch ($PaneId) {
                '%2' {
                    return "PS C:\repo\.worktrees\builder-1>"
                }
                '%4' {
                    return @"
gpt-5.4   82% context left
? send   Ctrl+J newline
>
"@
                }
                '%1' {
                    return @"
gpt-5.4   61% context left
thinking
Esc to interrupt
"@
                }
                default {
                    throw "unexpected pane id: $PaneId"
                }
            }
        }

        $records.Count | Should -Be 3
        $records[0].Label | Should -Be 'builder-1'
        $records[0].State | Should -Be 'pwsh'
        $records[0].TokensRemaining | Should -Be ''

        $records[1].Label | Should -Be 'reviewer'
        $records[1].State | Should -Be 'idle'
        $records[1].TokensRemaining | Should -Be '82% context left'

        $records[2].Label | Should -Be 'operator'
        $records[2].State | Should -Be 'busy'
        $records[2].TokensRemaining | Should -Be '61% context left'
    }

    It 'uses the pane-status winsmux wrapper when no snapshot provider is passed' {
        Mock Invoke-PaneStatusWinsmux {
            param([string[]]$Arguments)

            switch ($Arguments[2]) {
                '%2' { return "PS C:\repo\.worktrees\builder-1>" }
                '%4' { return "gpt-5.4   82% context left`n?" }
                '%1' { return "thinking`nEsc to interrupt" }
                default { throw "unexpected capture target: $($Arguments[2])" }
            }
        } -ParameterFilter {
            $Arguments.Count -eq 7 -and
            $Arguments[0] -eq 'capture-pane' -and
            $Arguments[1] -eq '-t' -and
            $Arguments[3] -eq '-p' -and
            $Arguments[4] -eq '-J' -and
            $Arguments[5] -eq '-S' -and
            $Arguments[6] -eq '-80'
        }

        $records = Get-PaneStatusRecords -ProjectDir $script:paneStatusTempRoot

        $records.Count | Should -Be 3
        $records[0].State | Should -Be 'pwsh'
        $records[1].State | Should -Be 'idle'
        $records[2].State | Should -Be 'busy'
        Should -Invoke Invoke-PaneStatusWinsmux -Times 3 -Exactly
    }

    It 'includes task review git fields from the manifest state model' {
        @'
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: C:\repo\.worktrees\builder-1
    task_id: task-243
    task: Implement TASK-243
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    builder_worktree_path: .worktrees/builder-1
    head_sha: abc1234def5678
    changed_file_count: 2
    changed_files: '["winsmux-core/scripts/orchestra-state.ps1","winsmux-core/scripts/agent-monitor.ps1"]'
    last_event: pane.ready
    last_event_at: 2026-04-09T12:00:00+09:00
'@ | Set-Content -Path (Join-Path (Join-Path $script:paneStatusTempRoot '.winsmux') 'manifest.yaml') -Encoding UTF8

        $records = Get-PaneStatusRecords -ProjectDir $script:paneStatusTempRoot -SnapshotProvider {
            param($PaneId)
            'gpt-5.4   74% context left'
        }

        $records.Count | Should -Be 1
        $records[0].TaskId | Should -Be 'task-243'
        $records[0].Task | Should -Be 'Implement TASK-243'
        $records[0].TaskState | Should -Be 'in_progress'
        $records[0].TaskOwner | Should -Be 'builder-1'
        $records[0].ReviewState | Should -Be 'PENDING'
        $records[0].Branch | Should -Be 'worktree-builder-1'
        $records[0].HeadSha | Should -Be 'abc1234def5678'
        $records[0].ChangedFileCount | Should -Be 2
        $records[0].ChangedFiles | Should -Be @(
            'winsmux-core/scripts/orchestra-state.ps1',
            'winsmux-core/scripts/agent-monitor.ps1'
        )
        $records[0].LastEvent | Should -Be 'pane.ready'
        $records[0].LastEventAt | Should -Be '2026-04-09T12:00:00+09:00'
    }

    It 'infers a conventional worktree from branch and label when the manifest path is omitted' {
        @'
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    task_id: task-243
    task: Implement TASK-243
    task_state: in_progress
    review_state: PENDING
    branch: worktree-builder-1
'@ | Set-Content -Path (Join-Path (Join-Path $script:paneStatusTempRoot '.winsmux') 'manifest.yaml') -Encoding UTF8

        $records = Get-PaneStatusRecords -ProjectDir $script:paneStatusTempRoot -SnapshotProvider {
            param($PaneId)
            'gpt-5.4   74% context left'
        }

        $records.Count | Should -Be 1
        $records[0].Worktree | Should -Be '.worktrees/builder-1'
    }

    It 'prefers launch_dir over builder_worktree_path when both are present' {
        @'
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: C:\repo\.worktrees\builder-9
    builder_worktree_path: C:\repo\.worktrees\builder-1
    branch: worktree-builder-1
'@ | Set-Content -Path (Join-Path (Join-Path $script:paneStatusTempRoot '.winsmux') 'manifest.yaml') -Encoding UTF8

        $records = Get-PaneStatusRecords -ProjectDir $script:paneStatusTempRoot -SnapshotProvider {
            param($PaneId)
            'gpt-5.4   74% context left'
        }

        $records.Count | Should -Be 1
        $records[0].Worktree | Should -Be '.worktrees/builder-9'
    }

    It 'relativizes explicit worktrees against the manifest session project root' {
        @'
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    builder_worktree_path: C:\repo\.worktrees\builder-1
    branch: worktree-builder-1
'@ | Set-Content -Path (Join-Path (Join-Path $script:paneStatusTempRoot '.winsmux') 'manifest.yaml') -Encoding UTF8

        $records = Get-PaneStatusRecords -ProjectDir $script:paneStatusTempRoot -SnapshotProvider {
            param($PaneId)
            'gpt-5.4   74% context left'
        }

        $records.Count | Should -Be 1
        $records[0].Worktree | Should -Be '.worktrees/builder-1'
    }
}

Describe 'orchestra layout script' {
    BeforeAll {
        $script:orchestraLayoutPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-layout.ps1'
    }

    BeforeEach {
        Mock Start-Sleep { }
    }

    It 'creates a single labeled pane through the orchestra wrapper' {
        $global:winsmuxCalls = [System.Collections.Generic.List[string]]::new()

        function global:winsmux {
            $global:LASTEXITCODE = 0
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            $global:winsmuxCalls.Add($commandLine) | Out-Null

            switch -Regex ($commandLine) {
                '^has-session ' { return @() }
                '^new-window ' { return '@1 %2' }
                '^list-panes -t @1 -F #\{pane_id\}$' { return '%2' }
                '^set-option ' { return @() }
                '^select-pane -t %2 -T Builder-1$' { return @() }
                '^select-pane -t %2$' { return @() }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = & $script:orchestraLayoutPath -SessionName 'winsmux-orchestra' -Builders 1

        $result.Total | Should -Be 1
        $result.Rows | Should -Be 1
        $result.Cols | Should -Be 1
        $result.Panes.Count | Should -Be 1
        $result.Panes[0].PaneId | Should -Be '%2'
        $result.Panes[0].Role | Should -Be 'Builder-1'
        @($global:winsmuxCalls) | Should -Contain 'list-panes -t @1 -F #{pane_id}'
        @($global:winsmuxCalls) | Should -Contain 'select-pane -t %2 -T Builder-1'
    }

    It 'uses wrapper-mediated split flow for a two-pane layout' {
        $global:winsmuxCalls = [System.Collections.Generic.List[string]]::new()
        $global:layoutPaneIds = @('%2')

        function global:winsmux {
            $global:LASTEXITCODE = 0
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            $global:winsmuxCalls.Add($commandLine) | Out-Null

            switch -Regex ($commandLine) {
                '^has-session ' { return @() }
                '^new-window ' { return '@1 %2' }
                '^set-option ' { return @() }
                '^display-message -t %2 -p #\{window_id\}$' { return '@1' }
                '^display-message -t %2 -p #\{pane_width\}x#\{pane_height\}$' { return '120x40' }
                '^split-window -t %2 -h -p 50$' {
                    $global:layoutPaneIds = @('%2', '%3')
                    return @()
                }
                '^list-panes -t @1 -F #\{pane_id\}$' { return $global:layoutPaneIds }
                '^select-pane -t %2$' { return @() }
                '^select-pane -t %2 -T Builder-1$' { return @() }
                '^select-pane -t %3 -T Builder-2$' { return @() }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = & $script:orchestraLayoutPath -SessionName 'winsmux-orchestra' -Builders 2

        $result.Total | Should -Be 2
        $result.Rows | Should -Be 1
        $result.Cols | Should -Be 2
        $result.Panes.Count | Should -Be 2
        $result.Panes[0].Role | Should -Be 'Builder-1'
        $result.Panes[1].Role | Should -Be 'Builder-2'
        @($global:winsmuxCalls) | Should -Contain 'split-window -t %2 -h -p 50'
        @($global:winsmuxCalls) | Should -Contain 'select-pane -t %3 -T Builder-2'
    }
}

Describe 'winsmux status command' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:statusTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-status-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:statusTempRoot -Force | Out-Null
        $script:statusManifestDir = Join-Path $script:statusTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:statusManifestDir -Force | Out-Null
        $script:statusManifestPath = Join-Path $script:statusManifestDir 'manifest.yaml'

        Push-Location $script:statusTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:statusTempRoot -and (Test-Path $script:statusTempRoot)) {
            Remove-Item -Path $script:statusTempRoot -Recurse -Force
        }

        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

    It 'parses both list and dictionary pane formats' {
        $manifest = ConvertFrom-PaneControlManifestContent -Content @'
version: 1
session:
  project_dir: C:\repo
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
  reviewer:
    pane_id: %4
    role: Reviewer
'@

        $manifest.Session.project_dir | Should -Be 'C:\repo'
        $manifest.Panes['builder-1'].pane_id | Should -Be '%2'
        $manifest.Panes['reviewer'].role | Should -Be 'Reviewer'
    }

    It 'renders a manifest-backed pane state table' {
        @"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:statusTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
  - label: reviewer
    pane_id: %4
    role: Reviewer
  - label: builder-2
    pane_id: %8
    role: Builder
"@ | Set-Content -Path $script:statusManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^list-panes ' { return @('%2 111', '%4 222') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }
        Mock Invoke-PaneStatusWinsmux {
            param([string[]]$Arguments)

            switch ($Arguments[2]) {
                '%2' { return @('Implementation finished.', '>') }
                '%4' { return @('Review in progress...') }
                default { throw "unexpected capture target: $($Arguments[2])" }
            }
        } -ParameterFilter {
            $Arguments[0] -eq 'capture-pane'
        }

        Mock Get-Process {
            param([int]$Id)

            switch ($Id) {
                111 { return [PSCustomObject]@{ Id = 111 } }
                222 { return [PSCustomObject]@{ Id = 222 } }
                default { throw "process not found: $Id" }
            }
        }

        $script:Target = $null
        $script:Rest = @()
        $output = Invoke-Status | Out-String

        $output | Should -Match 'builder-1'
        $output | Should -Match 'reviewer'
        $output | Should -Match 'builder-2'
        $output | Should -Match 'idle'
        $output | Should -Match 'busy'
        $output | Should -Match 'unknown'
    }
}

Describe 'winsmux board command' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:boardTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-board-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:boardTempRoot -Force | Out-Null
        $script:boardManifestDir = Join-Path $script:boardTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:boardManifestDir -Force | Out-Null
        $script:boardManifestPath = Join-Path $script:boardManifestDir 'manifest.yaml'

        Push-Location $script:boardTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:boardTempRoot -and (Test-Path $script:boardTempRoot)) {
            Remove-Item -Path $script:boardTempRoot -Recurse -Force
        }

        $global:Target = $null
        $global:Rest = @()
        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

    It 'renders a session board with task, review, and git state columns' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:boardTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-244
    task: Implement session board
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    builder_worktree_path: .worktrees/builder-1
    head_sha: abc1234def5678
    changed_file_count: 2
    changed_files: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    last_event: pane.ready
    last_event_at: 2026-04-10T10:00:00+09:00
  worker-1:
    pane_id: %6
    role: Worker
    task_id: ''
    task: ''
    task_state: backlog
    task_owner: ''
    review_state: ''
    branch: ''
    head_sha: ''
    changed_file_count: 0
    changed_files: '[]'
    last_event: pane.idle
    last_event_at: 2026-04-10T10:05:00+09:00
"@ | Set-Content -Path $script:boardManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }
        Mock Invoke-PaneStatusWinsmux {
            param([string[]]$Arguments)

            switch ($Arguments[2]) {
                '%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                '%6' { return @('gpt-5.4   52% context left', 'thinking', 'Esc to interrupt') }
                default { throw "unexpected capture target: $($Arguments[2])" }
            }
        } -ParameterFilter {
            $Arguments[0] -eq 'capture-pane'
        }

        $output = Invoke-Board | Out-String

        $output | Should -Match 'builder-1'
        $output | Should -Match 'worker-1'
        $output | Should -Match 'in_progress'
        $output | Should -Match 'PENDING'
        $output | Should -Match 'worktree-builder-1'
        $output | Should -Match 'abc1234'
    }

    It 'returns full session board data as json' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:boardTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-244
    task: Implement session board
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 2
    changed_files: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    last_event: pane.ready
    last_event_at: 2026-04-10T10:00:00+09:00
  worker-1:
    pane_id: %6
    role: Worker
    task_id: ''
    task: ''
    task_state: backlog
    task_owner: ''
    review_state: ''
    branch: ''
    head_sha: ''
    changed_file_count: 0
    changed_files: '[]'
    last_event: pane.idle
    last_event_at: 2026-04-10T10:05:00+09:00
"@ | Set-Content -Path $script:boardManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                '^capture-pane .*%6' { return @('gpt-5.4   52% context left', 'thinking', 'Esc to interrupt') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Board -BoardTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)

        $result.project_dir | Should -Be $script:boardTempRoot
        $result.summary.pane_count | Should -Be 2
        $result.summary.dirty_panes | Should -Be 1
        $result.summary.review_pending | Should -Be 1
        $result.summary.tasks_in_progress | Should -Be 1
        $result.summary.by_state.idle | Should -Be 1
        $result.summary.by_state.busy | Should -Be 1
        $result.panes.Count | Should -Be 2
        $result.panes[0].label | Should -Be 'builder-1'
        $result.panes[0].changed_files | Should -Be @('scripts/winsmux-core.ps1', 'tests/winsmux-bridge.Tests.ps1')
        $result.panes[0].last_event | Should -Be 'pane.ready'
        $result.panes[1].label | Should -Be 'worker-1'
        $result.panes[1].state | Should -Be 'busy'
    }

    It 'supports winsmux board --json through the top-level CLI entrypoint' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:boardTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-244
    task: Implement session board
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: pane.ready
    last_event_at: 2026-04-10T10:00:00+09:00
"@ | Set-Content -Path $script:boardManifestPath -Encoding UTF8

        $bridgeScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $childScript = @'
Set-Item -Path function:winsmux -Value {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$args)
    $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
    switch -Regex ($commandLine) {
        '^capture-pane .*%2' { @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>'); break }
        default { throw "unexpected winsmux call: $commandLine" }
    }
}
Set-Location '__BOARD_TEMP_ROOT__'
. '__BRIDGE_SCRIPT__' version *> $null
Invoke-Board -BoardTarget '--json'
'@
        $childScript = $childScript.Replace('__BOARD_TEMP_ROOT__', $script:boardTempRoot).Replace('__BRIDGE_SCRIPT__', $bridgeScript)
        $output = & pwsh -NoProfile -Command $childScript

        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.pane_count | Should -Be 1
        $result.panes[0].label | Should -Be 'builder-1'
        $result.panes[0].task_state | Should -Be 'in_progress'
        $result.panes[0].phase | Should -Be 'review'
        $result.panes[0].activity | Should -Be 'waiting_for_input'
        $result.panes[0].detail | Should -Be 'review_pending'
    }
}

Describe 'winsmux inbox command' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:inboxTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-inbox-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:inboxTempRoot -Force | Out-Null
        $script:inboxManifestDir = Join-Path $script:inboxTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:inboxManifestDir -Force | Out-Null
        $script:inboxManifestPath = Join-Path $script:inboxManifestDir 'manifest.yaml'
        $script:inboxEventsPath = Join-Path $script:inboxManifestDir 'events.jsonl'

        Push-Location $script:inboxTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:inboxTempRoot -and (Test-Path $script:inboxTempRoot)) {
            Remove-Item -Path $script:inboxTempRoot -Recurse -Force
        }

        $global:Target = $null
        $global:Rest = @()
        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

    It 'renders actionable inbox items from manifest review and blocked state' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:inboxTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-245
    task: Build inbox surface
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: review.requested
    last_event_at: 2026-04-10T11:00:00+09:00
  worker-1:
    pane_id: %6
    role: Worker
    task_id: task-999
    task: Fix blocker
    task_state: blocked
    task_owner: worker-1
    review_state: ''
    branch: worktree-worker-1
    head_sha: def5678abc1234
    changed_file_count: 0
    changed_files: '[]'
    last_event: operator.state_transition
    last_event_at: 2026-04-10T11:05:00+09:00
"@ | Set-Content -Path $script:inboxManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-10T11:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T11:06:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.state_transition'
                message   = 'State: review_requested -> blocked_no_review_target'
                label     = ''
                pane_id   = ''
                role      = 'Operator'
                status    = 'blocked_no_review_target'
                data      = [ordered]@{
                    from = 'review_requested'
                    to   = 'blocked_no_review_target'
                }
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:inboxEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                '^capture-pane .*%6' { return @('gpt-5.4   52% context left', 'thinking', 'Esc to interrupt') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $output = Invoke-Inbox | Out-String

        $output | Should -Match 'review_pending'
        $output | Should -Match 'approval_waiting'
        $output | Should -Match 'task_blocked'
        $output | Should -Match 'blocked'
        $output | Should -Match 'builder-1'
        $output | Should -Match 'worker-1'
    }

    It 'returns actionable inbox items as json' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:inboxTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-245
    task: Build inbox surface
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: review.requested
    last_event_at: 2026-04-10T11:00:00+09:00
"@ | Set-Content -Path $script:inboxManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-10T11:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T11:07:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.commit_ready'
                message   = 'コミット準備完了。'
                label     = ''
                pane_id   = ''
                role      = 'Operator'
                status    = 'commit_ready'
                head_sha  = 'abc1234def5678'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T11:08:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.completed'
                message   = '作業が完了した。'
                label     = 'builder-2'
                pane_id   = '%3'
                role      = 'Builder'
                status    = 'in_progress'
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:inboxEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Inbox -InboxTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)

        $result.project_dir | Should -Be $script:inboxTempRoot
        $result.summary.item_count | Should -Be 4
        $result.summary.by_kind.review_pending | Should -Be 1
        $result.summary.by_kind.approval_waiting | Should -Be 1
        $result.summary.by_kind.commit_ready | Should -Be 1
        $result.summary.by_kind.task_completed | Should -Be 1
        @($result.items | ForEach-Object { $_.kind }) | Should -Contain 'review_pending'
        @($result.items | ForEach-Object { $_.kind }) | Should -Contain 'approval_waiting'
        @($result.items | ForEach-Object { $_.kind }) | Should -Contain 'commit_ready'
        @($result.items | ForEach-Object { $_.kind }) | Should -Contain 'task_completed'
        ($result.items | Where-Object { $_.kind -eq 'review_pending' } | Select-Object -First 1).phase | Should -Be 'review'
        ($result.items | Where-Object { $_.kind -eq 'review_pending' } | Select-Object -First 1).activity | Should -Be 'waiting_for_input'
        ($result.items | Where-Object { $_.kind -eq 'commit_ready' } | Select-Object -First 1).phase | Should -Be 'package'
        ($result.items | Where-Object { $_.kind -eq 'commit_ready' } | Select-Object -First 1).activity | Should -Be 'completed'
        ($result.items | Where-Object { $_.kind -eq 'task_completed' } | Select-Object -First 1).phase | Should -Be 'package'
        ($result.items | Where-Object { $_.kind -eq 'task_completed' } | Select-Object -First 1).activity | Should -Be 'completed'
        ($result.items | Where-Object { $_.kind -eq 'task_completed' } | Select-Object -First 1).detail | Should -Be 'task_completed'
    }

    It 'supports winsmux inbox --json through the top-level CLI entrypoint' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:inboxTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-245
    task: Build inbox surface
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: review.requested
    last_event_at: 2026-04-10T11:00:00+09:00
"@ | Set-Content -Path $script:inboxManifestPath -Encoding UTF8

        ([ordered]@{
            timestamp = '2026-04-10T11:02:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pane.approval_waiting'
            message   = 'approval prompt detected'
            label     = 'builder-1'
            pane_id   = '%2'
            role      = 'Builder'
            status    = 'approval_waiting'
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:inboxEventsPath -Encoding UTF8

        $bridgeScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $childScript = @'
Set-Item -Path function:winsmux -Value {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$args)
    $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
    switch -Regex ($commandLine) {
        '^capture-pane .*%2' { @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>'); break }
        default { throw "unexpected winsmux call: $commandLine" }
    }
}
Set-Location '__INBOX_TEMP_ROOT__'
. '__BRIDGE_SCRIPT__' version *> $null
Invoke-Inbox -InboxTarget '--json'
'@
        $childScript = $childScript.Replace('__INBOX_TEMP_ROOT__', $script:inboxTempRoot).Replace('__BRIDGE_SCRIPT__', $bridgeScript)
        $output = & pwsh -NoProfile -Command $childScript

        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.item_count | Should -Be 2
        @($result.items | ForEach-Object { $_.kind }) | Should -Contain 'review_pending'
        @($result.items | ForEach-Object { $_.kind }) | Should -Contain 'approval_waiting'
    }

    It 'classifies the actionable inbox event taxonomy' {
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.approval_waiting'; status = 'approval_waiting' })) | Should -Be 'approval_waiting'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.idle'; status = 'ready' })) | Should -Be 'dispatch_needed'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.completed'; status = 'waiting_for_dispatch' })) | Should -Be 'task_completed'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.bootstrap_invalid'; status = 'bootstrap_invalid' })) | Should -Be 'bootstrap_invalid'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.crashed'; status = 'crashed' })) | Should -Be 'crashed'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.hung'; status = 'hung' })) | Should -Be 'hung'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.stalled'; status = 'stalled' })) | Should -Be 'stalled'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'operator.state_transition'; status = 'blocked_no_review_target'; data = [ordered]@{ to = 'blocked_no_review_target' } })) | Should -Be 'blocked'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'operator.commit_ready'; status = 'commit_ready' })) | Should -Be 'commit_ready'
    }

    It 'starts inbox stream after the current event cursor instead of replaying full history' {
        @(
            ([ordered]@{
                timestamp = '2026-04-10T11:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T11:03:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.ready'
                message   = 'ready'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'ready'
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:inboxEventsPath -Encoding UTF8

        $cursor = Get-InboxStreamStartCursor -ProjectDir $script:inboxTempRoot

        $cursor | Should -Be 2
        $delta = Get-BridgeEventDelta -ProjectDir $script:inboxTempRoot -Cursor $cursor
        $delta.cursor | Should -Be 2
        @($delta.events).Count | Should -Be 0
    }
}

Describe 'winsmux runs command' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:runsTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-runs-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:runsTempRoot -Force | Out-Null
        $script:runsManifestDir = Join-Path $script:runsTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:runsManifestDir -Force | Out-Null
        $script:runsManifestPath = Join-Path $script:runsManifestDir 'manifest.yaml'
        $script:runsEventsPath = Join-Path $script:runsManifestDir 'events.jsonl'

        Push-Location $script:runsTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:runsTempRoot -and (Test-Path $script:runsTempRoot)) {
            Remove-Item -Path $script:runsTempRoot -Recurse -Force
        }

        $global:Target = $null
        $global:Rest = @()
        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

    It 'renders run-oriented grouped output from manifest and actionable items' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:runsTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 2
    changed_files: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
  worker-1:
    pane_id: %6
    role: Worker
    task_id: ''
    task: ''
    task_state: backlog
    task_owner: ''
    review_state: ''
    branch: ''
    head_sha: ''
    changed_file_count: 0
    changed_files: '[]'
    last_event: pane.idle
    last_event_at: 2026-04-10T12:05:00+09:00
"@ | Set-Content -Path $script:runsManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-10T12:01:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T12:06:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.idle'
                message   = 'idle pane'
                label     = 'worker-1'
                pane_id   = '%6'
                role      = 'Worker'
                status    = 'ready'
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:runsEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                '^capture-pane .*%6' { return @('gpt-5.4   52% context left', 'thinking', 'Esc to interrupt') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $output = Invoke-Runs | Out-String

        $output | Should -Match 'task:task-256'
        $output | Should -Match 'builder-1'
        $output | Should -Match 'Implement run ledger'
        $output | Should -Match 'PENDING'
        $output | Should -Match '\s2\s*$'
    }

    It 'returns runs as json' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:runsTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    parent_run_id: operator:session-1
    goal: Ship run contract primitives
    task: Implement run ledger
    task_type: implementation
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    priority: P0
    blocking: true
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    write_scope: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    read_scope: '["winsmux-core/scripts/pane-status.ps1"]'
    constraints: '["preserve existing board schema"]'
    expected_output: Stable run_packet JSON
    verification_plan: '["Invoke-Pester tests/winsmux-bridge.Tests.ps1","verify runs --json contract"]'
    review_required: true
    provider_target: codex:gpt-5.4
    agent_role: worker
    timeout_policy: standard
    handoff_refs: '["docs/handoff.md"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:runsManifestPath -Encoding UTF8

        $runsObservationPack = New-ObservationPackFile -ProjectDir $script:runsTempRoot -ObservationPack ([ordered]@{
            run_id              = 'task:task-256'
            task_id             = 'task-256'
            pane_id             = '%2'
            slot                = 'slot-builder-1'
            hypothesis          = 'branch-scoped event data is enough for experiment ledger'
            test_plan           = @('capture matching events', 'render experiment packet')
            env_fingerprint     = 'env:abc123'
            command_hash        = 'cmd:def456'
            changed_files       = @('scripts/winsmux-core.ps1')
        })
        $runsConsultationPacket = New-ConsultationPacketFile -ProjectDir $script:runsTempRoot -ConsultationPacket ([ordered]@{
            run_id         = 'task:task-256'
            task_id        = 'task-256'
            pane_id        = '%2'
            slot           = 'slot-builder-1'
            kind           = 'consult_result'
            mode           = 'early'
            target_slot    = 'slot-review-1'
            confidence     = 0.72
            recommendation = 'keep experiment packet read-only'
            next_test      = 'review_pending'
            risks          = @('result still provisional')
        })

        @(
        ([ordered]@{
            timestamp = '2026-04-10T12:01:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pane.approval_waiting'
            message   = 'approval prompt detected'
            label     = 'builder-1'
            pane_id   = '%2'
            role      = 'Builder'
            status    = 'approval_waiting'
            data      = [ordered]@{
                task_id              = 'task-256'
                hypothesis           = 'branch-scoped event data is enough for experiment ledger'
                test_plan            = @('capture matching events', 'render experiment packet')
                result               = 'hypothesis still pending'
                confidence           = 0.72
                next_action          = 'review_pending'
                observation_pack_ref = $runsObservationPack.reference
                consultation_ref     = $runsConsultationPacket.reference
                run_id               = 'task:task-256'
                slot                 = 'slot-builder-1'
                worktree             = '.worktrees/builder-1'
                env_fingerprint      = 'env:abc123'
                command_hash         = 'cmd:def456'
            }
        } | ConvertTo-Json -Compress),
        ([ordered]@{
            timestamp = '2026-04-10T12:01:30+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.decompose.completed'
            message   = 'operator decomposed task'
            label     = 'researcher-1'
            pane_id   = ''
            role      = 'Operator'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id              = 'task-256'
                run_id               = 'task:task-256'
                stage                = 'decompose'
                state                = 'completed'
                upper_operator       = 'claude_code'
                aggregation_point    = 'claude_code_operator'
                worker_topology      = 'operator_managed_panes'
                peer_to_peer_allowed = $false
                target               = 'researcher-1'
                summary              = 'split implementation and verification'
            }
        } | ConvertTo-Json -Compress),
        ([ordered]@{
            timestamp = '2026-04-10T12:01:40+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.dispatch.assigned'
            message   = 'operator assigned builder'
            label     = 'builder-1'
            pane_id   = ''
            role      = 'Operator'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id              = 'task-256'
                run_id               = 'task:task-256'
                stage                = 'dispatch'
                state                = 'assigned'
                upper_operator       = 'claude_code'
                aggregation_point    = 'claude_code_operator'
                worker_topology      = 'operator_managed_panes'
                peer_to_peer_allowed = $false
                target               = 'builder-1'
                summary              = 'builder owns implementation'
            }
        } | ConvertTo-Json -Compress),
        ([ordered]@{
            timestamp = '2026-04-10T12:01:50+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.collect.completed'
            message   = 'operator collected builder result'
            label     = 'builder-1'
            pane_id   = ''
            role      = 'Operator'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id              = 'task-256'
                run_id               = 'task:task-256'
                stage                = 'collect'
                state                = 'builder_result_collected'
                upper_operator       = 'claude_code'
                aggregation_point    = 'claude_code_operator'
                worker_topology      = 'operator_managed_panes'
                peer_to_peer_allowed = $false
                target               = 'builder-1'
                summary              = 'builder result is ready for review'
            }
        } | ConvertTo-Json -Compress),
        ([ordered]@{
            timestamp = '2026-04-10T12:02:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.verify.partial'
            message   = 'verification partially complete'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id = 'task-256'
                run_id  = 'task:task-256'
                verification_contract = [ordered]@{
                    mode = 'adversarial_verify'
                }
                verification_result = [ordered]@{
                    outcome = 'PARTIAL'
                    summary = 'rerun focused verification'
                    next_action = 'rerun_verify'
                }
            }
        } | ConvertTo-Json -Compress),
        ([ordered]@{
            timestamp = '2026-04-10T12:03:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.escalate.required'
            message   = 'operator escalation required'
            label     = 'reviewer-1'
            pane_id   = ''
            role      = 'Operator'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id              = 'task-256'
                run_id               = 'task:task-256'
                stage                = 'escalate'
                state                = 'required'
                reason               = 'VERIFY_PARTIAL'
                upper_operator       = 'claude_code'
                aggregation_point    = 'claude_code_operator'
                worker_topology      = 'operator_managed_panes'
                peer_to_peer_allowed = $false
                target               = 'reviewer-1'
                summary              = 'verification needs an operator decision'
            }
        } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:runsEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Runs -RunsTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.run_count | Should -Be 1
        $result.summary.review_pending | Should -Be 1
        $result.summary.dirty_runs | Should -Be 1
        $result.runs[0].run_id | Should -Be 'task:task-256'
        @($result.runs[0].action_items | ForEach-Object { $_.kind }) | Should -Contain 'approval_waiting'
        @($result.runs[0].action_items | ForEach-Object { $_.kind }) | Should -Contain 'review_pending'
        $result.runs[0].changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $result.runs[0].run_packet.parent_run_id | Should -Be 'operator:session-1'
        $result.runs[0].run_packet.goal | Should -Be 'Ship run contract primitives'
        $result.runs[0].run_packet.task_type | Should -Be 'implementation'
        $result.runs[0].run_packet.priority | Should -Be 'P0'
        $result.runs[0].run_packet.blocking | Should -Be $true
        $result.runs[0].run_packet.write_scope | Should -Be @('scripts/winsmux-core.ps1', 'tests/winsmux-bridge.Tests.ps1')
        $result.runs[0].run_packet.read_scope | Should -Be @('winsmux-core/scripts/pane-status.ps1')
        $result.runs[0].run_packet.constraints | Should -Be @('preserve existing board schema')
        $result.runs[0].run_packet.expected_output | Should -Be 'Stable run_packet JSON'
        $result.runs[0].run_packet.verification_plan | Should -Be @('Invoke-Pester tests/winsmux-bridge.Tests.ps1', 'verify runs --json contract')
        $result.runs[0].run_packet.review_required | Should -Be $true
        $result.runs[0].run_packet.provider_target | Should -Be 'codex:gpt-5.4'
        $result.runs[0].run_packet.agent_role | Should -Be 'worker'
        $result.runs[0].run_packet.timeout_policy | Should -Be 'standard'
        $result.runs[0].run_packet.handoff_refs | Should -Be @('docs/handoff.md')
        $result.runs[0].experiment_packet.hypothesis | Should -Be 'branch-scoped event data is enough for experiment ledger'
        $result.runs[0].experiment_packet.test_plan | Should -Be @('capture matching events', 'render experiment packet')
        $result.runs[0].experiment_packet.result | Should -Be 'hypothesis still pending'
        $result.runs[0].experiment_packet.confidence | Should -Be 0.72
        $result.runs[0].experiment_packet.next_action | Should -Be 'review_pending'
        $result.runs[0].experiment_packet.observation_pack_ref | Should -Be $runsObservationPack.reference
        $result.runs[0].experiment_packet.consultation_ref | Should -Be $runsConsultationPacket.reference
        $result.runs[0].experiment_packet.run_id | Should -Be 'task:task-256'
        $result.runs[0].experiment_packet.slot | Should -Be 'slot-builder-1'
        $result.runs[0].experiment_packet.worktree | Should -Be '.worktrees/builder-1'
        $result.runs[0].experiment_packet.env_fingerprint | Should -Be 'env:abc123'
        $result.runs[0].experiment_packet.command_hash | Should -Be 'cmd:def456'
        $result.runs[0].verification_contract.mode | Should -Be 'adversarial_verify'
        $result.runs[0].verification_result.outcome | Should -Be 'PARTIAL'
        $result.runs[0].run_packet.verification_result.outcome | Should -Be 'PARTIAL'
        $result.runs[0].phase | Should -Be 'review'
        $result.runs[0].activity | Should -Be 'waiting_for_input'
        $result.runs[0].detail | Should -Be 'review_pending'
        $result.runs[0].run_packet.phase | Should -Be 'review'
        $result.runs[0].run_packet.activity | Should -Be 'waiting_for_input'
        $result.runs[0].run_packet.detail | Should -Be 'review_pending'
        $result.runs[0].plan.goal | Should -Be 'Ship run contract primitives'
        $result.runs[0].plan.verification_plan | Should -Be @('Invoke-Pester tests/winsmux-bridge.Tests.ps1', 'verify runs --json contract')
        $result.runs[0].plan_checkpoints.Count | Should -Be 6
        @($result.runs[0].plan_checkpoints | ForEach-Object { $_.name }) | Should -Be @('pane.approval_waiting', 'pipeline.decompose.completed', 'pipeline.dispatch.assigned', 'pipeline.collect.completed', 'pipeline.verify.partial', 'pipeline.escalate.required')
        $result.runs[0].plan_checkpoints[0].at.ToString('o') | Should -Be '2026-04-10T03:01:00.0000000Z'
        $result.runs[0].managed_loop.upper_operator | Should -Be 'claude_code'
        $result.runs[0].managed_loop.aggregation_point | Should -Be 'claude_code_operator'
        $result.runs[0].managed_loop.peer_to_peer_allowed | Should -Be $false
        $result.runs[0].managed_loop.decompose_state | Should -Be 'completed'
        $result.runs[0].managed_loop.assignment_state | Should -Be 'assigned'
        $result.runs[0].managed_loop.collection_state | Should -Be 'builder_result_collected'
        $result.runs[0].managed_loop.escalation_state | Should -Be 'required'
        $result.runs[0].managed_loop.escalation_reason | Should -Be 'VERIFY_PARTIAL'
        $result.runs[0].managed_loop.stages.Count | Should -Be 4
        $result.runs[0].phase_gate.order | Should -Be @('plan', 'build', 'test', 'review', 'package')
        $result.runs[0].phase_gate.current_stage | Should -Be 'review'
        $result.runs[0].phase_gate.stop_required | Should -Be $true
        $result.runs[0].phase_gate.stop_reason | Should -Be 'needs_user_decision'
        $result.runs[0].phase_gate.auto_continue_allowed | Should -Be $false
        $result.runs[0].phase_gate.requires_human_decision | Should -Be $true
        ($result.runs[0].phase_gate.stages | Where-Object { $_.stage -eq 'test' } | Select-Object -First 1).status | Should -Be 'waiting_for_input'
        ($result.runs[0].phase_gate.stages | Where-Object { $_.stage -eq 'review' } | Select-Object -First 1).reason | Should -Be 'review_pending'
        $result.runs[0].outcome.status | Should -Be 'needs_user_decision'
        $result.runs[0].outcome.reason | Should -Be 'rerun focused verification'
        $result.runs[0].outcome.confidence | Should -Be 0.72
        $result.runs[0].draft_pr_gate.kind | Should -Be 'human_judgement'
        $result.runs[0].draft_pr_gate.target | Should -Be 'draft_pr'
        $result.runs[0].draft_pr_gate.state | Should -Be 'blocked'
        $result.runs[0].draft_pr_gate.auto_merge_allowed | Should -Be $false
        $result.runs[0].draft_pr_gate.handoff_package.summary | Should -Be 'rerun focused verification'
        $result.runs[0].draft_pr_gate.handoff_package.validation.outcome | Should -Be 'PARTIAL'
        $result.runs[0].draft_pr_gate.handoff_package.remaining_risks | Should -Contain 'verification outcome is PARTIAL'
        $result.runs[0].draft_pr_gate.handoff_package.blocked_reasons | Should -Contain 'review state is unresolved: PENDING'
        $result.runs[0].draft_pr_gate.handoff_package.package_complete | Should -Be $false
        $result.runs[0].draft_pr_gate.handoff_package.automatic_merge_allowed | Should -Be $false
        $result.runs[0].run_packet.plan.goal | Should -Be 'Ship run contract primitives'
        $result.runs[0].run_packet.plan_checkpoints.Count | Should -Be 6
        $result.runs[0].run_packet.managed_loop.peer_to_peer_allowed | Should -Be $false
        $result.runs[0].run_packet.managed_loop.assignment_state | Should -Be 'assigned'
        $result.runs[0].run_packet.phase_gate.stop_reason | Should -Be 'needs_user_decision'
        $result.runs[0].run_packet.outcome.status | Should -Be 'needs_user_decision'
        $result.runs[0].run_packet.draft_pr_gate.merge_requires_human | Should -Be $true
        $result.runs[0].run_packet.draft_pr_gate.handoff_package.suggested_next_action | Should -Be 'rerun_verify'
        $result.runs[0].Contains('observation_pack') | Should -Be $false
        $result.runs[0].Contains('consultation_packet') | Should -Be $false
    }

    It 'blocks draft PR gate when draft PR evidence exists without verification evidence' {
        $run = [ordered]@{
            review_state      = 'PASS'
            review_required   = $true
            verification_plan = @('Invoke-Pester')
            changed_files     = @('scripts/winsmux-core.ps1')
            task              = 'Create draft package'
            goal              = 'Create draft package'
            verification_result = $null
            security_verdict  = $null
            experiment_packet = $null
        }
        $events = @(
            [ordered]@{
                timestamp   = '2026-04-10T12:04:00+09:00'
                line_number = 1
                event       = 'operator.draft_pr.created'
                data        = [ordered]@{ draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/999' }
            }
        )

        $gate = New-RunDraftPrGate -Run $run -EventRecords $events

        $gate.state | Should -Be 'blocked'
        $gate.draft_pr_url | Should -Be 'https://github.com/Sora-bluesky/winsmux/pull/999'
        $gate.auto_merge_allowed | Should -Be $false
        $gate.merge_requires_human | Should -Be $true
        $gate.handoff_package.validation.evidence_complete | Should -Be $false
        $gate.handoff_package.blocked_reasons | Should -Contain 'verification evidence is missing'
        $gate.handoff_package.suggested_next_action | Should -Be 'resolve blocked reasons before creating or merging a draft PR'
    }

    It 'exposes needs-user-decision as a phase-gated stop before package completion' {
        $run = [PSCustomObject]@{
            goal              = 'Ship guarded package'
            task_state        = 'in_progress'
            review_state      = 'PASS'
            verification_plan = @('Invoke-Pester')
            review_required   = $true
            changed_files     = @('scripts/winsmux-core.ps1')
            task              = 'Create guarded package'
            last_event        = 'operator.draft_pr.required'
            verification_result = [ordered]@{ outcome = 'PASS'; summary = 'verification passed' }
            security_verdict  = [ordered]@{ verdict = 'ALLOW'; reason = '' }
            experiment_packet = $null
        }
        $events = @(
            [ordered]@{ timestamp = '2026-04-10T12:01:00+09:00'; line_number = 1; event = 'pipeline.decompose.completed'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-04-10T12:02:00+09:00'; line_number = 2; event = 'pipeline.collect.completed'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-04-10T12:03:00+09:00'; line_number = 3; event = 'pipeline.verify.pass'; data = [ordered]@{ verification_result = [ordered]@{ outcome = 'PASS' } } },
            [ordered]@{ timestamp = '2026-04-10T12:04:00+09:00'; line_number = 4; event = 'operator.draft_pr.required'; data = [ordered]@{} }
        )

        $run | Add-Member -NotePropertyName draft_pr_gate -NotePropertyValue (New-RunDraftPrGate -Run $run -EventRecords $events)
        $run | Add-Member -NotePropertyName phase_gate -NotePropertyValue (New-RunPhaseGateContract -Run $run -EventRecords $events)
        $outcome = New-RunOutcomeContract -Run $run

        $run.phase_gate.current_stage | Should -Be 'package'
        $run.phase_gate.stop_required | Should -Be $true
        $run.phase_gate.stop_reason | Should -Be 'needs_user_decision'
        $run.phase_gate.auto_continue_allowed | Should -Be $false
        ($run.phase_gate.stages | Where-Object { $_.stage -eq 'package' } | Select-Object -First 1).status | Should -Be 'waiting_for_input'
        ($run.phase_gate.stages | Where-Object { $_.stage -eq 'package' } | Select-Object -First 1).reason | Should -Be 'needs_user_decision'
        $outcome.status | Should -Be 'needs_user_decision'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'operator.draft_pr.required'; status = 'blocked_draft_pr_required' })) | Should -Be 'needs_user_decision'
        $stateModel = New-RunStateModel -EventKind 'needs_user_decision' -LastEvent 'operator.draft_pr.required'
        $stateModel.phase | Should -Be 'package'
        $stateModel.activity | Should -Be 'waiting_for_input'
        $stateModel.detail | Should -Be 'needs_user_decision'
        $passStateModel = New-RunStateModel -ReviewState 'PASS'
        $passStateModel.phase | Should -Be 'package'
        $passStateModel.activity | Should -Be 'waiting_for_input'
        $passStateModel.detail | Should -Be 'needs_user_decision'
    }

    It 'clears stale verification stops when later verification passes' {
        $run = [PSCustomObject]@{
            goal              = 'Recover guarded package'
            task_state        = 'in_progress'
            review_state      = 'PENDING'
            verification_plan = @('Invoke-Pester')
            review_required   = $true
        }
        $events = @(
            [ordered]@{ timestamp = '2026-04-10T12:01:00+09:00'; line_number = 1; event = 'pipeline.verify.partial'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-04-10T12:02:00+09:00'; line_number = 2; event = 'pipeline.verify.pass'; data = [ordered]@{ verification_result = [ordered]@{ outcome = 'PASS' } } }
        )

        $phaseGate = New-RunPhaseGateContract -Run $run -EventRecords $events

        $phaseGate.stop_required | Should -Be $false
        $phaseGate.stop_reason | Should -Be ''
        ($phaseGate.stages | Where-Object { $_.stage -eq 'test' } | Select-Object -First 1).status | Should -Be 'completed'
    }

    It 'ignores stale draft PR evidence that does not match the run head sha' {
        $run = [PSCustomObject]@{
            head_sha          = 'current-sha'
            review_state      = 'PASS'
            review_required   = $true
            verification_plan = @('Invoke-Pester')
            changed_files     = @('scripts/winsmux-core.ps1')
            task              = 'Create draft package'
            goal              = 'Create draft package'
            verification_result = [ordered]@{ outcome = 'PASS'; summary = 'verification passed' }
            security_verdict  = [ordered]@{ verdict = 'ALLOW'; reason = '' }
            experiment_packet = $null
        }
        $events = @(
            [ordered]@{
                timestamp   = '2026-04-10T12:04:00+09:00'
                line_number = 1
                event       = 'operator.draft_pr.created'
                head_sha    = ''
                data        = [ordered]@{ draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/999' }
            },
            [ordered]@{
                timestamp   = '2026-04-10T12:05:00+09:00'
                line_number = 2
                event       = 'operator.draft_pr.created'
                head_sha    = 'old-sha'
                data        = [ordered]@{ draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/998' }
            }
        )

        $gate = New-RunDraftPrGate -Run $run -EventRecords $events
        $run | Add-Member -NotePropertyName draft_pr_gate -NotePropertyValue $gate
        $phaseGate = New-RunPhaseGateContract -Run $run -EventRecords $events

        $gate.state | Should -Be 'required'
        $gate.draft_pr_url | Should -Be ''
        $phaseGate.stop_required | Should -Be $true
        $phaseGate.stop_reason | Should -Be 'needs_user_decision'
        ($phaseGate.stages | Where-Object { $_.stage -eq 'package' } | Select-Object -First 1).reason | Should -Be 'needs_user_decision'
    }

    It 'uses the newest same-timestamp draft PR evidence for the run head sha' {
        $run = [PSCustomObject]@{
            head_sha            = 'current-sha'
            review_state        = 'PASS'
            review_required     = $true
            verification_plan   = @('Invoke-Pester')
            changed_files       = @('scripts/winsmux-core.ps1')
            task                = 'Create draft package'
            goal                = 'Create draft package'
            verification_result = [ordered]@{ outcome = 'PASS'; summary = 'verification passed' }
            security_verdict    = [ordered]@{ verdict = 'ALLOW'; reason = '' }
            experiment_packet   = $null
        }
        $events = @(
            [ordered]@{
                timestamp   = '2026-04-10T12:04:00+09:00'
                line_number = 1
                event       = 'operator.draft_pr.created'
                head_sha    = 'current-sha'
                data        = [ordered]@{ draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/997' }
            },
            [ordered]@{
                timestamp   = '2026-04-10T12:04:00+09:00'
                line_number = 2
                event       = 'operator.draft_pr.created'
                head_sha    = 'current-sha'
                data        = [ordered]@{ draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/998' }
            }
        )

        $gate = New-RunDraftPrGate -Run $run -EventRecords $events

        $gate.state | Should -Be 'passed'
        $gate.draft_pr_url | Should -Be 'https://github.com/Sora-bluesky/winsmux/pull/998'
    }

    It 'supports winsmux runs --json through the top-level CLI entrypoint' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:runsTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:runsManifestPath -Encoding UTF8

        $bridgeScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $childScript = @'
Set-Item -Path function:winsmux -Value {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$args)
    $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
    switch -Regex ($commandLine) {
        '^capture-pane .*%2' { @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>'); break }
        default { throw "unexpected winsmux call: $commandLine" }
    }
}
Set-Location '__RUNS_TEMP_ROOT__'
& '__BRIDGE_SCRIPT__' runs --json
'@
        $childScript = $childScript.Replace('__RUNS_TEMP_ROOT__', $script:runsTempRoot).Replace('__BRIDGE_SCRIPT__', $bridgeScript)
        $output = & pwsh -NoProfile -Command $childScript

        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.run_count | Should -Be 1
        $result.runs[0].run_id | Should -Be 'task:task-256'
        $result.runs[0].experiment_packet | Should -Be $null
    }

    It 'keeps experiment packets scoped to strong run keys when multiple runs share a branch' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:runsTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Investigate cache mismatch
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: shared-worktree
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
  builder-2:
    pane_id: %6
    role: Builder
    task_id: task-999
    task: Investigate cache mismatch separately
    task_state: in_progress
    task_owner: builder-2
    review_state: PENDING
    branch: shared-worktree
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["tests/winsmux-bridge.Tests.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:01:00+09:00
"@ | Set-Content -Path $script:runsManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-10T12:01:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.progress'
                message   = 'builder-1 hypothesis update'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'busy'
                branch    = 'shared-worktree'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id    = 'task-256'
                    run_id     = 'task:task-256'
                    hypothesis = 'builder-1 owns this experiment packet'
                    result     = 'pending'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T12:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.progress'
                message   = 'builder-2 hypothesis update'
                label     = 'builder-2'
                pane_id   = '%6'
                role      = 'Builder'
                status    = 'busy'
                branch    = 'shared-worktree'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id    = 'task-999'
                    run_id     = 'task:task-999'
                    hypothesis = 'builder-2 owns this experiment packet'
                    result     = 'pending'
                }
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:runsEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                '^capture-pane .*%6' { return @('gpt-5.4   61% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Runs -RunsTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)

        @($result.runs).Count | Should -Be 2
        $first = @($result.runs | Where-Object { $_.run_id -eq 'task:task-256' })[0]
        $second = @($result.runs | Where-Object { $_.run_id -eq 'task:task-999' })[0]
        $first.experiment_packet.run_id | Should -Be 'task:task-256'
        $first.experiment_packet.hypothesis | Should -Be 'builder-1 owns this experiment packet'
        $second.experiment_packet.run_id | Should -Be 'task:task-999'
        $second.experiment_packet.hypothesis | Should -Be 'builder-2 owns this experiment packet'
    }

    It 'surfaces security policy and latest security verdict in runs json' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:runsTempRoot
panes:
  worker-1:
    pane_id: %2
    role: Worker
    task_id: task-273
    task: Enforce security policy
    task_state: blocked
    task_owner: worker-1
    review_state: ''
    branch: worktree-worker-1
    head_sha: def5678abc1234
    changed_file_count: 0
    changed_files: '[]'
    security_policy: '{\"mode\":\"blocklist\",\"allow_patterns\":[\"Invoke-Pester\"],\"block_patterns\":[\"git reset --hard\"]}'
    last_event: pipeline.security.blocked
    last_event_at: 2026-04-10T12:03:00+09:00
"@ | Set-Content -Path $script:runsManifestPath -Encoding UTF8

        ([ordered]@{
            timestamp = '2026-04-10T12:03:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.security.blocked'
            message   = 'security monitor blocked exec'
            label     = 'worker-1'
            pane_id   = '%2'
            role      = 'Worker'
            branch    = 'worktree-worker-1'
            head_sha  = 'def5678abc1234'
            data      = [ordered]@{
                task_id = 'task-273'
                run_id  = 'task:task-273'
                stage   = 'EXEC'
                verdict = 'BLOCK'
                reason  = 'dangerous command approval'
                advisory_mode = $false
                allow   = @('read', 'write')
                block   = @('hard_reset')
                next_action = 'revise_request_or_override'
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:runsEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Runs -RunsTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)

        $result.runs[0].security_policy.mode | Should -Be 'blocklist'
        @($result.runs[0].security_policy.block_patterns) | Should -Be @('git reset --hard')
        $result.runs[0].security_verdict.verdict | Should -Be 'BLOCK'
        $result.runs[0].run_packet.security_verdict.reason | Should -Be 'dangerous command approval'
    }
}

Describe 'winsmux digest command' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:digestTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-digest-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:digestTempRoot -Force | Out-Null
        $script:digestManifestDir = Join-Path $script:digestTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:digestManifestDir -Force | Out-Null
        $script:digestManifestPath = Join-Path $script:digestManifestDir 'manifest.yaml'
        $script:digestEventsPath = Join-Path $script:digestManifestDir 'events.jsonl'

        Push-Location $script:digestTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:digestTempRoot -and (Test-Path $script:digestTempRoot)) {
            Remove-Item -Path $script:digestTempRoot -Recurse -Force
        }

        $global:Target = $null
        $global:Rest = @()
        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

    It 'renders a high-signal evidence digest per run' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:digestTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-246
    task: Build evidence digest
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 2
    changed_files: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T14:00:00+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-10T14:01:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:digestEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $output = Invoke-Digest | Out-String

        $output | Should -Match 'Run: task:task-246'
        $output | Should -Match 'Next: approval_waiting'
        $output | Should -Match 'Git: worktree-builder-1 @ abc1234'
        $output | Should -Match 'Changed files \(2\):'
        $output | Should -Match 'scripts/winsmux-core.ps1'
    }

    It 'returns digest items as json' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:digestTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-246
    task: Build evidence digest
    task_state: blocked
    task_owner: builder-1
    review_state: FAIL
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_failed
    last_event_at: 2026-04-10T14:00:00+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        $digestObservationPack = New-ObservationPackFile -ProjectDir $script:digestTempRoot -ObservationPack ([ordered]@{
            run_id          = 'task:task-246'
            task_id         = 'task-246'
            pane_id         = '%2'
            slot            = 'slot-builder-1'
            hypothesis      = 'result summary should appear in digest'
            env_fingerprint = 'env:abc123'
        })
        $digestConsultationPacket = New-ConsultationPacketFile -ProjectDir $script:digestTempRoot -ConsultationPacket ([ordered]@{
            run_id         = 'task:task-246'
            task_id        = 'task-246'
            pane_id        = '%2'
            slot           = 'slot-builder-1'
            kind           = 'consult_result'
            mode           = 'reconcile'
            target_slot    = 'slot-review-1'
            confidence     = 0.88
            recommendation = 'treat review failure as blocking'
            next_test      = 'review_failed'
        })

        ([ordered]@{
            timestamp = '2026-04-10T14:01:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'operator.review_failed'
            message   = 'review failed'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id              = 'task-246'
                hypothesis           = 'result summary should appear in digest'
                result               = 'review failure reproduced'
                confidence           = 0.88
                next_action          = 'review_failed'
                observation_pack_ref = $digestObservationPack.reference
                consultation_ref     = $digestConsultationPacket.reference
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:digestEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Digest -DigestTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.item_count | Should -Be 1
        $result.summary.review_failed | Should -Be 1
        $result.items[0].run_id | Should -Be 'task:task-246'
        $result.items[0].next_action | Should -Be 'review_failed'
        $result.items[0].head_short | Should -Be 'abc1234'
        $result.items[0].changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $result.items[0].hypothesis | Should -Be 'result summary should appear in digest'
        $result.items[0].confidence | Should -Be 0.88
        $result.items[0].observation_pack_ref | Should -Be $digestObservationPack.reference
        $result.items[0].consultation_ref | Should -Be $digestConsultationPacket.reference
        $result.items[0].Contains('observation_pack') | Should -Be $false
        $result.items[0].Contains('consultation_packet') | Should -Be $false
    }

    It 'returns digest event summaries when --events is supplied' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:digestTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-274
    task: Build event summaries
    task_state: blocked
    task_owner: builder-1
    review_state: ''
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 0
    changed_files: '[]'
    last_event: pipeline.security.blocked
    last_event_at: 2026-04-10T14:02:00+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-10T14:01:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.noise'
                message   = 'ignore me'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T14:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.security.blocked'
                message   = 'security monitor blocked exec'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id = 'task-274'
                    run_id  = 'task:task-274'
                    next_action = 'revise_request_or_override'
                }
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:digestEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Digest -DigestTarget '--events' -DigestRest @('--json') | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.item_count | Should -Be 1
        $result.items[0].kind | Should -Be 'blocked'
        $result.items[0].source_event | Should -Be 'pipeline.security.blocked'
        $result.items[0].run_id | Should -Be 'task:task-274'
        $result.items[0].next_action | Should -Be 'revise_request_or_override'
    }

    It 'returns digest delta items only for runs affected after the current cursor' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:digestTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-246
    task: Build evidence digest
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 2
    changed_files: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T14:00:00+09:00
  worker-1:
    pane_id: %6
    role: Worker
    task_id: ''
    task: ''
    task_state: backlog
    task_owner: ''
    review_state: ''
    branch: ''
    head_sha: ''
    changed_file_count: 0
    changed_files: '[]'
    last_event: pane.idle
    last_event_at: 2026-04-10T14:00:30+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        ([ordered]@{
            timestamp = '2026-04-10T14:01:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'operator.review_requested'
            message   = 'review requested'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id = 'task-246'
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:digestEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                '^capture-pane .*%6' { return @('gpt-5.4   52% context left', 'thinking', 'Esc to interrupt') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $cursor = @(Get-BridgeEventRecords -ProjectDir $script:digestTempRoot).Count

        @(
            ([ordered]@{
                timestamp = '2026-04-10T14:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.idle'
                message   = 'idle pane'
                label     = 'worker-1'
                pane_id   = '%6'
                role      = 'Worker'
                status    = 'ready'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T14:03:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.commit_ready'
                message   = 'commit ready'
                label     = ''
                pane_id   = ''
                role      = 'Operator'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                status    = 'commit_ready'
                data      = [ordered]@{
                    task_id = 'task-246'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T14:04:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress)
        ) | Add-Content -Path $script:digestEventsPath -Encoding UTF8

        $delta = Get-BridgeEventDelta -ProjectDir $script:digestTempRoot -Cursor $cursor
        $items = @(Get-DigestDeltaItems -ProjectDir $script:digestTempRoot -EventRecords @($delta.events))

        $delta.cursor | Should -Be 4
        $items.Count | Should -Be 1
        $items[0].run_id | Should -Be 'task:task-246'
        $items[0].next_action | Should -Be 'approval_waiting'
        $items[0].changed_file_count | Should -Be 2
    }

    It 'writes digest stream items as one-line summary records' {
        $item = [ordered]@{
            run_id             = 'task:task-246'
            label              = 'builder-1'
            pane_id            = '%2'
            next_action        = 'commit_ready'
            changed_file_count = 2
            last_event_at      = '2026-04-10T14:03:00+09:00'
        }

        $output = Write-DigestStreamItem -Item $item | Out-String

        $output | Should -Match 'digest task:task-246 builder-1 \(%2\) next=commit_ready files=2'
    }

    It 'supports winsmux digest --json through the top-level CLI entrypoint' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:digestTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-246
    task: Build evidence digest
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T14:00:00+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        $bridgeScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $childScript = @'
Set-Item -Path function:winsmux -Value {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$args)
    $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
    switch -Regex ($commandLine) {
        '^capture-pane .*%2' { @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>'); break }
        default { throw "unexpected winsmux call: $commandLine" }
    }
}
Set-Location '__DIGEST_TEMP_ROOT__'
& '__BRIDGE_SCRIPT__' digest --json
'@
        $childScript = $childScript.Replace('__DIGEST_TEMP_ROOT__', $script:digestTempRoot).Replace('__BRIDGE_SCRIPT__', $bridgeScript)
        $output = & pwsh -NoProfile -Command $childScript

        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.item_count | Should -Be 1
        $result.items[0].run_id | Should -Be 'task:task-246'
    }

    It 'supports winsmux desktop-summary --json through the top-level CLI entrypoint' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:digestTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-246
    task: Build evidence digest
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T14:00:00+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        $bridgeScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $childScript = @'
Set-Item -Path function:winsmux -Value {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$args)
    $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
    switch -Regex ($commandLine) {
        '^capture-pane .*%2' { @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>'); break }
        default { throw "unexpected winsmux call: $commandLine" }
    }
}
Set-Location '__DIGEST_TEMP_ROOT__'
& '__BRIDGE_SCRIPT__' desktop-summary --json
'@
        $childScript = $childScript.Replace('__DIGEST_TEMP_ROOT__', $script:digestTempRoot).Replace('__BRIDGE_SCRIPT__', $bridgeScript)
        $output = & pwsh -NoProfile -Command $childScript

        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result.board.summary.pane_count | Should -Be 1
        $result.digest.summary.item_count | Should -Be 1
        @($result.run_projections).Count | Should -Be 1
        $result.run_projections[0].run_id | Should -Be 'task:task-246'
        $result.run_projections[0].worktree | Should -Be '.worktrees/builder-1'
    }

    It 'converts event records into desktop summary refresh items' {
        $item = ConvertTo-DesktopSummaryRefreshItem -EventRecord ([ordered]@{
                timestamp = '2026-04-10T14:02:00+09:00'
                event     = 'pane.completed'
                pane_id   = '%2'
                branch    = 'worktree-builder-1'
                data      = [ordered]@{
                    task_id = 'task-246'
                }
            })

        $item.source | Should -Be 'summary'
        $item.reason | Should -Be 'pane.completed'
        $item.pane_id | Should -Be '%2'
        $item.run_id | Should -Be 'task:task-246'
    }

    It 'derives desktop summary refresh run ids from branch context when task metadata is absent' {
        $runId = Get-DesktopSummaryRefreshRunId -EventRecord ([ordered]@{
                event   = 'pane.idle'
                pane_id = '%6'
                branch  = 'worktree-builder-1'
            })

        $runId | Should -Be 'branch:worktree-builder-1'
    }

    It 'prefers launch_dir in desktop-summary projections when the builder path lags behind' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: %2
    role: Builder
    launch_dir: C:\repo\.worktrees\builder-9
    builder_worktree_path: C:\repo\.worktrees\builder-1
    task_id: task-246
    task: Build evidence digest
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T14:00:00+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        $bridgeScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $childScript = @'
Set-Item -Path function:winsmux -Value {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$args)
    $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
    switch -Regex ($commandLine) {
        '^capture-pane .*%2' { @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>'); break }
        default { throw "unexpected winsmux call: $commandLine" }
    }
}
Set-Location '__DIGEST_TEMP_ROOT__'
& '__BRIDGE_SCRIPT__' desktop-summary --json
'@
        $childScript = $childScript.Replace('__DIGEST_TEMP_ROOT__', $script:digestTempRoot).Replace('__BRIDGE_SCRIPT__', $bridgeScript)
        $output = & pwsh -NoProfile -Command $childScript

        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        @($result.run_projections).Count | Should -Be 1
        $result.run_projections[0].worktree | Should -Be '.worktrees/builder-9'
    }
}

Describe 'winsmux explain command' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:explainTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-explain-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:explainTempRoot -Force | Out-Null
        $script:explainManifestDir = Join-Path $script:explainTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:explainManifestDir -Force | Out-Null
        $script:explainManifestPath = Join-Path $script:explainManifestDir 'manifest.yaml'
        $script:explainEventsPath = Join-Path $script:explainManifestDir 'events.jsonl'
        $script:explainReviewStatePath = Join-Path $script:explainManifestDir 'review-state.json'

        Push-Location $script:explainTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:explainTempRoot -and (Test-Path $script:explainTempRoot)) {
            Remove-Item -Path $script:explainTempRoot -Recurse -Force
        }

        $global:Target = $null
        $global:Rest = @()
        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

    It 'returns a json explanation with related events and review state' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    parent_run_id: operator:session-1
    goal: Ship run contract primitives
    task: Implement run ledger
    task_type: implementation
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    priority: P0
    blocking: true
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    write_scope: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    read_scope: '["winsmux-core/scripts/pane-status.ps1"]'
    constraints: '["preserve existing board schema"]'
    expected_output: Stable explain JSON
    verification_plan: '["Invoke-Pester tests/winsmux-bridge.Tests.ps1","verify explain --json contract"]'
    review_required: true
    provider_target: codex:gpt-5.4
    agent_role: worker
    timeout_policy: standard
    handoff_refs: '["docs/handoff.md"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        $explainObservationPack = New-ObservationPackFile -ProjectDir $script:explainTempRoot -ObservationPack ([ordered]@{
            run_id               = 'task:task-256'
            task_id              = 'task-256'
            pane_id              = '%2'
            slot                 = 'slot-builder-1'
            hypothesis           = 'experiment packet should flow into explain'
            test_plan            = @('collect matching events', 'normalize packet')
            changed_files        = @('scripts/winsmux-core.ps1')
            working_tree_summary = '1 file modified'
            failing_command      = 'Invoke-Pester tests/winsmux-bridge.Tests.ps1'
            env_fingerprint      = 'env:abc123'
            command_hash         = 'cmd:def456'
        })
        $explainConsultationPacket = New-ConsultationPacketFile -ProjectDir $script:explainTempRoot -ConsultationPacket ([ordered]@{
            run_id         = 'task:task-256'
            task_id        = 'task-256'
            pane_id        = '%2'
            slot           = 'slot-builder-1'
            kind           = 'consult_result'
            mode           = 'early'
            target_slot    = 'slot-review-1'
            confidence     = 0.66
            recommendation = 'consult before work'
            next_test      = 'approval_waiting'
            risks          = @('needs reviewer confirmation')
        })

        @(
            ([ordered]@{
                timestamp = '2026-04-10T12:01:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.review_requested'
                message   = 'review requested'
                label     = 'reviewer-1'
                pane_id   = '%3'
                role      = 'Reviewer'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id              = 'task-256'
                    hypothesis           = 'experiment packet should flow into explain'
                    test_plan            = @('collect matching events', 'normalize packet')
                    result               = 'consult before work'
                    confidence           = 0.66
                    next_action          = 'approval_waiting'
                    observation_pack_ref = $explainObservationPack.reference
                    consultation_ref     = $explainConsultationPacket.reference
                    run_id               = 'task:task-256'
                    slot                 = 'slot-builder-1'
                    worktree             = '.worktrees/builder-1'
                    env_fingerprint      = 'env:abc123'
                    command_hash         = 'cmd:def456'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T12:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.verify.partial'
                message   = 'verification partial'
                label     = 'reviewer-1'
                pane_id   = '%3'
                role      = 'Reviewer'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id = 'task-256'
                    run_id  = 'task:task-256'
                    verification_contract = [ordered]@{
                        mode = 'adversarial_verify'
                    }
                    verification_result = [ordered]@{
                        outcome = 'PARTIAL'
                        summary = 'rerun focused verification'
                        next_action = 'rerun_verify'
                    }
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T12:02:30+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T12:03:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.idle'
                message   = 'idle pane'
                label     = 'worker-1'
                pane_id   = '%6'
                role      = 'Worker'
                status    = 'ready'
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:explainEventsPath -Encoding UTF8

@'
{
  "worktree-builder-1": {
    "status": "PENDING",
    "branch": "worktree-builder-1",
    "head_sha": "abc1234def5678",
    "request": {
      "id": "review-request-__ID__",
      "branch": "worktree-builder-1",
      "head_sha": "abc1234def5678",
      "target_review_label": "reviewer-1",
      "target_review_pane_id": "%3",
      "target_review_role": "Reviewer",
      "target_reviewer_label": "reviewer-1",
      "target_reviewer_pane_id": "%3",
      "target_reviewer_role": "Reviewer",
      "review_contract": {
        "version": 1,
        "source_task": "TASK-210",
        "issue_ref": "#315",
        "style": "utility_first",
        "required_scope": [
          "design_impact",
          "replacement_coverage",
          "orphaned_artifacts",
          "pathspec_completeness"
        ]
      },
      "dispatched_at": "__TIMESTAMP__"
    },
    "reviewer": {
      "pane_id": "%3",
      "label": "reviewer-1",
      "role": "Reviewer",
      "agent_name": "codex"
    },
    "updatedAt": "__TIMESTAMP__"
  }
}
'@ | Set-Content -Path $script:explainReviewStatePath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Explain -ExplainTarget 'task:task-256' -ExplainRest @('--json') | Out-String | ConvertFrom-Json -AsHashtable)

        $result.run.run_id | Should -Be 'task:task-256'
        $result.run.task | Should -Be 'Implement run ledger'
        $result.run.parent_run_id | Should -Be 'operator:session-1'
        $result.run.goal | Should -Be 'Ship run contract primitives'
        $result.run.task_type | Should -Be 'implementation'
        $result.run.priority | Should -Be 'P0'
        $result.run.blocking | Should -Be $true
        $result.run.write_scope | Should -Be @('scripts/winsmux-core.ps1', 'tests/winsmux-bridge.Tests.ps1')
        $result.run.read_scope | Should -Be @('winsmux-core/scripts/pane-status.ps1')
        $result.run.constraints | Should -Be @('preserve existing board schema')
        $result.run.expected_output | Should -Be 'Stable explain JSON'
        $result.run.verification_plan | Should -Be @('Invoke-Pester tests/winsmux-bridge.Tests.ps1', 'verify explain --json contract')
        $result.run.review_required | Should -Be $true
        $result.run.provider_target | Should -Be 'codex:gpt-5.4'
        $result.run.agent_role | Should -Be 'worker'
        $result.run.timeout_policy | Should -Be 'standard'
        $result.run.handoff_refs | Should -Be @('docs/handoff.md')
        $result.run.experiment_packet.hypothesis | Should -Be 'experiment packet should flow into explain'
        $result.run.experiment_packet.test_plan | Should -Be @('collect matching events', 'normalize packet')
        $result.run.experiment_packet.result | Should -Be 'consult before work'
        $result.run.experiment_packet.confidence | Should -Be 0.66
        $result.run.experiment_packet.next_action | Should -Be 'approval_waiting'
        $result.run.experiment_packet.observation_pack_ref | Should -Be $explainObservationPack.reference
        $result.run.experiment_packet.consultation_ref | Should -Be $explainConsultationPacket.reference
        $result.run.experiment_packet.run_id | Should -Be 'task:task-256'
        $result.run.experiment_packet.slot | Should -Be 'slot-builder-1'
        $result.run.experiment_packet.worktree | Should -Be '.worktrees/builder-1'
        $result.run.experiment_packet.env_fingerprint | Should -Be 'env:abc123'
        $result.run.experiment_packet.command_hash | Should -Be 'cmd:def456'
        $result.run.verification_contract.mode | Should -Be 'adversarial_verify'
        $result.run.verification_result.outcome | Should -Be 'PARTIAL'
        $result.run.phase | Should -Be 'review'
        $result.run.activity | Should -Be 'waiting_for_input'
        $result.run.detail | Should -Be 'review_pending'
        $result.run.plan.goal | Should -Be 'Ship run contract primitives'
        $result.run.plan.verification_plan | Should -Be @('Invoke-Pester tests/winsmux-bridge.Tests.ps1', 'verify explain --json contract')
        $result.run.plan_checkpoints.Count | Should -Be 3
        @($result.run.plan_checkpoints | ForEach-Object { $_.name }) | Should -Be @('operator.review_requested', 'pipeline.verify.partial', 'pane.approval_waiting')
        $result.run.plan_checkpoints[0].at.ToString('o') | Should -Be '2026-04-10T03:01:00.0000000Z'
        $result.run.phase_gate.order | Should -Be @('plan', 'build', 'test', 'review', 'package')
        $result.run.phase_gate.current_stage | Should -Be 'review'
        $result.run.phase_gate.stop_required | Should -Be $true
        $result.run.phase_gate.stop_reason | Should -Be 'needs_user_decision'
        $result.run.phase_gate.auto_continue_allowed | Should -Be $false
        $result.run.outcome.status | Should -Be 'needs_user_decision'
        $result.run.outcome.reason | Should -Be 'rerun focused verification'
        $result.run.outcome.confidence | Should -Be 0.66
        $result.run.draft_pr_gate.kind | Should -Be 'human_judgement'
        $result.run.draft_pr_gate.target | Should -Be 'draft_pr'
        $result.run.draft_pr_gate.state | Should -Be 'blocked'
        $result.run.draft_pr_gate.merge_requires_human | Should -Be $true
        $result.run.draft_pr_gate.handoff_package.summary | Should -Be 'rerun focused verification'
        $result.run.draft_pr_gate.handoff_package.remaining_risks | Should -Contain 'verification outcome is PARTIAL'
        $result.run.draft_pr_gate.handoff_package.blocked_reasons | Should -Contain 'review state is unresolved: PENDING'
        $result.run.draft_pr_gate.handoff_package.automatic_merge_allowed | Should -Be $false
        $result.observation_pack.failing_command | Should -Be 'Invoke-Pester tests/winsmux-bridge.Tests.ps1'
        $result.observation_pack.changed_files | Should -Contain 'scripts/winsmux-core.ps1'
        $result.consultation_packet.kind | Should -Be 'consult_result'
        $result.consultation_packet.mode | Should -Be 'early'
        $result.observation_pack.Contains('packet_type') | Should -BeFalse
        $result.consultation_packet.Contains('packet_type') | Should -BeFalse
        $result.Contains('experiment_packet') | Should -BeFalse
        $result.Contains('consultation_summary') | Should -BeFalse
        $result.evidence_digest.run_id | Should -Be 'task:task-256'
        $result.evidence_digest.next_action | Should -Be 'approval_waiting'
        $result.evidence_digest.phase | Should -Be 'review'
        $result.evidence_digest.activity | Should -Be 'waiting_for_input'
        $result.evidence_digest.detail | Should -Be 'review_pending'
        $result.evidence_digest.changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $result.explanation.current_state.review_state | Should -Be 'PENDING'
        $result.explanation.current_state.phase | Should -Be 'review'
        $result.explanation.current_state.activity | Should -Be 'waiting_for_input'
        $result.explanation.current_state.detail | Should -Be 'review_pending'
        $result.explanation.reasons | Should -Contain 'task_state=in_progress'
        $result.explanation.reasons | Should -Contain 'review_state=PENDING'
        $result.explanation.reasons | Should -Contain 'verify=PARTIAL'
        $result.explanation.reasons | Should -Contain 'review_contract=design_impact,replacement_coverage,orphaned_artifacts,pathspec_completeness'
        $result.review_state.status | Should -Be 'PENDING'
        $result.review_state.request.review_contract.style | Should -Be 'utility_first'
        $result.review_state.request.review_contract.source_task | Should -Be 'TASK-210'
        $result.review_state.request.review_contract.required_scope | Should -Be @('design_impact', 'replacement_coverage', 'orphaned_artifacts', 'pathspec_completeness')
        $result.run.Contains('run_packet') | Should -BeFalse
        $result.Contains('run_packet') | Should -Be $false
        $result.Contains('result_packet') | Should -Be $false
        $result.recent_events.Count | Should -Be 3
        @($result.recent_events | ForEach-Object { $_.event }) | Should -Contain 'operator.review_requested'
        @($result.recent_events | ForEach-Object { $_.event }) | Should -Contain 'pipeline.verify.partial'
        @($result.recent_events | ForEach-Object { $_.event }) | Should -Contain 'pane.approval_waiting'
        ($result.recent_events | Where-Object { $_.event -eq 'operator.review_requested' } | Select-Object -First 1).hypothesis | Should -Be 'experiment packet should flow into explain'
        ($result.recent_events | Where-Object { $_.event -eq 'operator.review_requested' } | Select-Object -First 1).observation_pack.changed_files | Should -Contain 'scripts/winsmux-core.ps1'
        ($result.recent_events | Where-Object { $_.event -eq 'operator.review_requested' } | Select-Object -First 1).observation_pack.packet_type | Should -Be 'observation_pack'
        ($result.recent_events | Where-Object { $_.event -eq 'operator.review_requested' } | Select-Object -First 1).consultation_packet.kind | Should -Be 'consult_result'
    }

    It 'rejects explain when matching review-state record is missing reviewer' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        ([ordered]@{
            timestamp = '2026-04-10T12:01:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'operator.review_requested'
            message   = 'review requested'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id = 'task-256'
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:explainEventsPath -Encoding UTF8

@'
{
  "worktree-builder-1": {
    "status": "PENDING",
    "branch": "worktree-builder-1",
    "head_sha": "abc1234def5678",
    "request": {
      "branch": "worktree-builder-1",
      "head_sha": "abc1234def5678",
      "target_review_label": "reviewer-1",
      "target_review_pane_id": "%3",
      "target_review_role": "Reviewer",
      "review_contract": {
        "version": 1,
        "source_task": "TASK-210",
        "issue_ref": "#315",
        "style": "utility_first",
        "required_scope": [
          "design_impact",
          "replacement_coverage",
          "orphaned_artifacts",
          "pathspec_completeness"
        ]
      }
    },
    "updatedAt": "2026-04-10T12:01:00+09:00"
  }
}
'@ | Set-Content -Path $script:explainReviewStatePath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid review state*reviewer*'
    }

    It 'rejects explain when PASS review-state evidence is missing approved_via' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: done
    task_owner: builder-1
    review_state: PASS
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: review.pass
    last_event_at: 2026-04-10T12:10:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        ([ordered]@{
            timestamp = '2026-04-10T12:10:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'review.pass'
            message   = 'review PASS recorded'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id = 'task-256'
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:explainEventsPath -Encoding UTF8

@'
{
  "worktree-builder-1": {
    "status": "PASS",
    "branch": "worktree-builder-1",
    "head_sha": "abc1234def5678",
    "request": {
      "branch": "worktree-builder-1",
      "head_sha": "abc1234def5678",
      "target_review_label": "reviewer-1",
      "target_review_pane_id": "%3",
      "target_review_role": "Reviewer",
      "review_contract": {
        "version": 1,
        "source_task": "TASK-210",
        "issue_ref": "#315",
        "style": "utility_first",
        "required_scope": [
          "design_impact",
          "replacement_coverage",
          "orphaned_artifacts",
          "pathspec_completeness"
        ]
      }
    },
    "reviewer": {
      "pane_id": "%3",
      "label": "reviewer-1",
      "role": "Reviewer"
    },
    "updatedAt": "2026-04-10T12:10:00+09:00",
    "evidence": {
      "approved_at": "2026-04-10T12:10:00+09:00",
      "review_contract_snapshot": {
        "version": 1,
        "source_task": "TASK-210",
        "issue_ref": "#315",
        "style": "utility_first",
        "required_scope": [
          "design_impact",
          "replacement_coverage",
          "orphaned_artifacts",
          "pathspec_completeness"
        ]
      }
    }
  }
}
'@ | Set-Content -Path $script:explainReviewStatePath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid review state*approved_via*'
    }

    It 'rejects explain when manifest review_state is present without head_sha' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' review_state requires head_sha*'
    }

    It 'rejects explain when manifest changed_file_count is present without changed_files' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '[]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' changed_file_count requires changed_files*'
    }

    It 'rejects explain when manifest last_event is present without last_event_at' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' last_event requires last_event_at*'
    }

    It 'rejects explain when manifest planning metadata is missing parent_run_id' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    goal: Ship run contract primitives
    task_type: implementation
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    priority: P0
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' planning metadata requires parent_run_id*'
    }

    It 'rejects explain when manifest planning metadata is missing goal' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    parent_run_id: operator:session-1
    task: Implement run ledger
    task_type: implementation
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    priority: P0
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' planning metadata requires goal*'
    }

    It 'rejects explain when manifest planning metadata is missing task_type' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    parent_run_id: operator:session-1
    task: Implement run ledger
    goal: Ship run contract primitives
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    priority: P0
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' planning metadata requires task_type*'
    }

    It 'rejects explain when manifest planning metadata is missing priority' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    parent_run_id: operator:session-1
    task: Implement run ledger
    goal: Ship run contract primitives
    task_type: implementation
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256' } | Should -Throw '*invalid manifest*pane ''builder-1'' planning metadata requires priority*'
    }

    It 'keeps refs and returns null packets when artifact files are missing or malformed' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-777
    task: Explain missing packets
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 0
    changed_files: '[]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        $badConsultDir = Get-ConsultationDirectory -ProjectDir $script:explainTempRoot
        New-Item -ItemType Directory -Path $badConsultDir -Force | Out-Null
        Write-PsmuxBridgeTestFile -Path (Join-Path $badConsultDir 'consult-result-bad.json') -Content '{ nope }'

        ([ordered]@{
            timestamp = '2026-04-10T12:01:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'operator.review_requested'
            message   = 'review requested'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id              = 'task-777'
                hypothesis           = 'hydrate should be resilient'
                observation_pack_ref = '.winsmux/observation-packs/missing.json'
                consultation_ref     = '.winsmux/consultations/consult-result-bad.json'
                run_id               = 'task:task-777'
                slot                 = 'slot-builder-1'
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:explainEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Explain -ExplainTarget 'task:task-777' -ExplainRest @('--json') | Out-String | ConvertFrom-Json -AsHashtable)

        $result.run.experiment_packet.observation_pack_ref | Should -Be '.winsmux/observation-packs/missing.json'
        $result.run.experiment_packet.consultation_ref | Should -Be '.winsmux/consultations/consult-result-bad.json'
        $result.observation_pack | Should -Be $null
        $result.consultation_packet | Should -Be $null
        $result.Contains('consultation_summary') | Should -BeFalse
        $result.Contains('experiment_packet') | Should -BeFalse
    }

    It 'filters explain follow events from the current cursor forward' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:explainTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:explainManifestPath -Encoding UTF8

        ([ordered]@{
            timestamp = '2026-04-10T12:01:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'operator.review_requested'
            message   = 'review requested'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id = 'task-256'
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:explainEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $payload = Get-ExplainPayload -ProjectDir $script:explainTempRoot -RunId 'task:task-256'
        $cursor = @(Get-BridgeEventRecords -ProjectDir $script:explainTempRoot).Count

        @(
            ([ordered]@{
                timestamp = '2026-04-10T12:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.idle'
                message   = 'idle pane'
                label     = 'worker-1'
                pane_id   = '%6'
                role      = 'Worker'
                status    = 'ready'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T12:03:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.commit_ready'
                message   = 'commit ready'
                label     = ''
                pane_id   = ''
                role      = 'Operator'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                status    = 'commit_ready'
                data      = [ordered]@{
                    task_id              = 'task-256'
                    hypothesis           = 'follow path should keep experiment fields'
                    result               = 'ready to commit'
                    next_action          = 'commit_ready'
                    observation_pack_ref = '.winsmux/observation-packs/task-256.json'
                }
            } | ConvertTo-Json -Compress)
        ) | Add-Content -Path $script:explainEventsPath -Encoding UTF8

        $delta = Get-BridgeEventDelta -ProjectDir $script:explainTempRoot -Cursor $cursor
        $matching = @(
            $delta.events |
                Where-Object { Test-RunMatchesEventRecord -Run $payload.run -EventRecord $_ } |
                ForEach-Object { ConvertTo-RunEventRecord -EventRecord $_ }
        )

        $delta.cursor | Should -Be 3
        $matching.Count | Should -Be 1
        $matching[0].event | Should -Be 'operator.commit_ready'
        $matching[0].hypothesis | Should -Be 'follow path should keep experiment fields'
        $matching[0].next_action | Should -Be 'commit_ready'
        $matching[0].observation_pack_ref | Should -Be '.winsmux/observation-packs/task-256.json'
    }
}

Describe 'winsmux send dispatch payload' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreSendRawContent = Get-Content -Path $script:winsmuxCorePath -Raw -Encoding UTF8
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:sendTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-send-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sendTempRoot -Force | Out-Null
    }

    AfterEach {
        if ($script:sendTempRoot -and (Test-Path $script:sendTempRoot)) {
            Remove-Item -Path $script:sendTempRoot -Recurse -Force
        }
    }

    It 'keeps short text inline without creating a dispatch file' {
        $payload = Resolve-SendDispatchPayload -Text 'Write-Host short' -ProjectDir $script:sendTempRoot -LengthLimit 4000

        $payload['IsFileBacked'] | Should -Be $false
        $payload['TextToSend'] | Should -Be 'Write-Host short'
        $payload['PromptPath'] | Should -Be $null
        Test-Path (Join-Path $script:sendTempRoot '.winsmux\dispatch-prompts') | Should -Be $false
    }

    It 'resolves managed pane send settings through the project capability root' {
        $script:winsmuxCoreSendRawContent | Should -Match 'Get-SlotAgentConfig -Role \$context\.Role -SlotId \$context\.Label -RootPath \$projectDir'
        $script:winsmuxCoreSendRawContent | Should -Match 'Provider capability'
        $script:winsmuxCoreSendRawContent | Should -Match 'CapabilityAdapter'
        $script:winsmuxCoreSendRawContent | Should -Match 'CapabilityCommand'
    }

    It 'resolves restart readiness through dictionary capability adapters' {
        $plan = [ordered]@{
            Agent = 'codex-nightly'
            CapabilityAdapter = 'codex'
        }

        Get-RestartReadinessAgentName -Plan $plan | Should -Be 'codex'
    }

    It 'writes long text to a dispatch file and returns a prompt pointer for non-exec panes' {
        $longText = 'a' * 4001

        $payload = Resolve-SendDispatchPayload -Text $longText -ProjectDir $script:sendTempRoot -LengthLimit 4000

        $payload['IsFileBacked'] | Should -Be $true
        $payload['TextToSend'] | Should -Not -Be $longText
        $payload['FallbackMode'] | Should -Be 'pointer'
        $payload['TextToSend'] | Should -Match "Read the full prompt from '"
        $payload['PromptPath'] | Should -Not -BeNullOrEmpty
        $payload['PromptReference'] | Should -BeLike '.winsmux/dispatch-prompts/*'
        $promptContent = Get-Content -LiteralPath $payload['PromptPath'] -Raw -Encoding UTF8
        $promptContent.TrimEnd("`r", "`n") | Should -BeExactly $longText
        $payload['TextToSend'] | Should -Match ([regex]::Escape($payload['PromptReference']))
    }

    It 'always writes a dispatch file when prompt_transport is file' {
        $payload = Resolve-SendDispatchPayload -Text 'Write-Host short' -ProjectDir $script:sendTempRoot -LengthLimit 4000 -PromptTransport 'file'

        $payload['PromptTransport'] | Should -Be 'file'
        $payload['IsFileBacked'] | Should -Be $true
        $payload['TextToSend'] | Should -Match "Read the full prompt from '"
        $payload['PromptPath'] | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $payload['PromptPath'] -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should -BeExactly 'Write-Host short'
    }

    It 'normalizes blank prompt_transport to argv' {
        $payload = Resolve-SendDispatchPayload -Text 'Write-Host short' -ProjectDir $script:sendTempRoot -LengthLimit 4000 -PromptTransport '   '

        $payload['PromptTransport'] | Should -Be 'argv'
        $payload['IsFileBacked'] | Should -Be $false
    }

    It 'keeps stdin prompt_transport inline even when the payload exceeds the argv length limit' {
        $payload = Resolve-SendDispatchPayload -Text ('a' * 5000) -ProjectDir $script:sendTempRoot -LengthLimit 4000 -PromptTransport 'stdin'

        $payload['PromptTransport'] | Should -Be 'stdin'
        $payload['IsFileBacked'] | Should -Be $false
        $payload['PromptPath'] | Should -Be $null
        $payload['TextLength'] | Should -Be 5000
    }

    It 'keeps exec-mode transport file-backed even when prompt_transport is stdin' {
        $plan = Resolve-SendTransportPlan `
            -Text ('a' * 5000) `
            -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 `
            -PromptTransport 'stdin' `
            -ExecMode:$true `
            -LaunchDir 'C:\repo' `
            -GitWorktreeDir 'C:\repo' `
            -Model 'gpt-5.4'

        $plan['Mode'] | Should -Be 'codex_exec_file'
        $plan['PromptTransport'] | Should -Be 'stdin'
        $plan['IsFileBacked'] | Should -Be $true
        $plan['FallbackMode'] | Should -Be 'exec_file'
        $plan['PromptPath'] | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $plan['PromptPath'] -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should -BeExactly ('a' * 5000)
        $plan['ExecInstruction'] | Should -Match 'codex exec'
    }

    It 'uses the provider capability command for exec-mode send plans' {
        $plan = Resolve-SendTransportPlan `
            -Text 'Summarize status' `
            -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 `
            -PromptTransport 'argv' `
            -ExecMode:$true `
            -LaunchDir 'C:\repo' `
            -GitWorktreeDir 'C:\repo' `
            -Model 'gpt-5.4-nightly' `
            -ExecCommand 'codex-nightly'

        $plan['Mode'] | Should -Be 'codex_exec_file'
        $plan['ExecInstruction'] | Should -Match '^codex-nightly exec'
        $plan['ExecInstruction'] | Should -Not -Match '^codex exec'
    }

    It 'quotes provider capability executable paths for exec-mode send plans' {
        $plan = Resolve-SendTransportPlan `
            -Text 'Summarize status' `
            -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 `
            -PromptTransport 'argv' `
            -ExecMode:$true `
            -LaunchDir 'C:\repo' `
            -GitWorktreeDir 'C:\repo' `
            -Model 'gpt-5.4-nightly' `
            -ExecCommand 'C:\Tools\Codex Nightly\codex.exe'

        $plan['Mode'] | Should -Be 'codex_exec_file'
        $plan['ExecInstruction'] | Should -Match "^& 'C:\\Tools\\Codex Nightly\\codex.exe' exec"
    }

    It 'normalizes task prompt slugs and writes a stable task prompt file when task_slug is supplied' {
        (ConvertTo-TaskPromptSlug -TaskSlug ' Cache Drift / Build ') | Should -Be 'cache-drift-build'

        $payload = Resolve-SendDispatchPayload -Text 'Write-Host short' -ProjectDir $script:sendTempRoot -LengthLimit 4000 -TaskSlug ' Cache Drift / Build '

        $payload['TaskSlug'] | Should -Be 'cache-drift-build'
        $payload['IsFileBacked'] | Should -Be $true
        $payload['FallbackMode'] | Should -Be 'task_file'
        $payload['PromptPath'] | Should -Be (Join-Path $script:sendTempRoot '.winsmux\task-cache-drift-build.md')
        $payload['PromptReference'] | Should -Be '.winsmux/task-cache-drift-build.md'
        (Get-Content -LiteralPath $payload['PromptPath'] -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should -BeExactly 'Write-Host short'
    }

    It 'overwrites the same task prompt path when the same task_slug is reused' {
        $first = Resolve-SendDispatchPayload -Text 'first prompt' -ProjectDir $script:sendTempRoot -LengthLimit 4000 -TaskSlug 'cache-drift'
        $second = Resolve-SendDispatchPayload -Text 'second prompt' -ProjectDir $script:sendTempRoot -LengthLimit 4000 -TaskSlug 'cache-drift'

        $first['PromptPath'] | Should -Be $second['PromptPath']
        $second['PromptReference'] | Should -Be '.winsmux/task-cache-drift.md'
        (Get-Content -LiteralPath $second['PromptPath'] -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should -BeExactly 'second prompt'
    }

    It 'rejects unsupported prompt transport values with the stable-core contract in the error' {
        { Resolve-SendDispatchPayload -Text 'Write-Host short' -ProjectDir $script:sendTempRoot -LengthLimit 4000 -PromptTransport 'socket' } | Should -Throw '*Supported values: argv, file, stdin*'
    }

    It 'blocks send text when a blocklist security policy pattern matches' {
        $violation = Find-SendSecurityPolicyViolation -Text 'git reset --hard origin/main' -SecurityPolicy ([ordered]@{
            mode = 'blocklist'
            allow_patterns = @('Invoke-Pester')
            block_patterns = @('git reset --hard')
        })

        $violation.verdict | Should -Be 'BLOCK'
        $violation.mode | Should -Be 'blocklist'
        @($violation.block) | Should -Be @('git reset --hard')
    }

    It 'blocks allowlist sends when no allow pattern matches' {
        $violation = Find-SendSecurityPolicyViolation -Text 'Write-Host short' -SecurityPolicy ([ordered]@{
            mode = 'allowlist'
            allow_patterns = @('Invoke-Pester')
            block_patterns = @()
        })

        $violation.verdict | Should -Be 'BLOCK'
        $violation.reason | Should -Match 'allow_patterns'
    }
}

Describe 'winsmux task-run command' {
    BeforeAll {
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
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
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
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
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreRawContent = Get-Content -Path $script:winsmuxCoreRawPath -Raw -Encoding UTF8
        $script:publicFirstRunPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\public-first-run.ps1'
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
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreRawContent = Get-Content -Path $script:winsmuxCoreRawPath -Raw -Encoding UTF8
        $script:conflictPreflightPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\conflict-preflight.ps1'
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
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\conflict-preflight.ps1')
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
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\settings.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\public-first-run.ps1')
    }

    BeforeEach {
        $script:publicFirstRunTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-public-first-run-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:publicFirstRunTempRoot -Force | Out-Null
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
        $settings.agent_slots.Count | Should -Be 6
        $settings.agent_slots[0].slot_id | Should -Be 'worker-1'
        $settings.workspace_lifecycle_preset | Should -Be 'managed-worktree'
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
        $settings.agent_slots[0].agent | Should -Be 'codex-nightly'
        $settings.agent_slots[0].model | Should -Be 'gpt-5.4-code'
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
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
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
        Get-PaneReadinessAgent -Target 'missing' -PaneId '%9' -ProjectDir $script:readinessTempRoot | Should -Be 'codex'
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
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
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
      "prompt_transports": ["argv", "file", "stdin"],
      "supports_file_edit": true,
      "supports_verification": true,
      "supports_subagents": true
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
        $payload.providers.codex.prompt_transports | Should -Be @('argv', 'file', 'stdin')
        $payload.providers.codex.supports_file_edit | Should -Be $true
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
        $payload.capabilities.supports_verification | Should -Be $true
    }
}

Describe 'winsmux assign command' {
    BeforeAll {
        $script:winsmuxAssignRawPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
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
        $payload.assignment.approval_policy | Should -Be 'operator_review_required'
        $payload.security.stores_provider_tokens | Should -BeFalse
        $payload.security.brokers_oauth | Should -BeFalse
        $payload.generated_outputs | Should -Contain 'provider_capability_catalog.generated.json'
        $payload.generated_outputs | Should -Contain 'model_resolution_report.json'
    }
}

Describe 'winsmux launcher command' {
    BeforeAll {
        $script:winsmuxLauncherRawPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
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
        $script:winsmuxRoleRawPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxRoleRawContent = Get-Content -Raw -Path $script:winsmuxRoleRawPath -Encoding UTF8
    }

    It 'builds reassigned role launch commands through provider capabilities' {
        $script:winsmuxRoleRawContent | Should -Match 'Get-SlotAgentConfig -Role \$newRole -SlotId \$newLabel'
        $script:winsmuxRoleRawContent | Should -Match 'Get-BridgeProviderLaunchCommand'
        $script:winsmuxRoleRawContent | Should -Match '\$launchDir = \[string\]\$manifestEntry\.LaunchDir'
        $script:winsmuxRoleRawContent | Should -Match '\$gitDir = \[string\]\$manifestEntry\.GitWorktreeDir'
        $script:winsmuxRoleRawContent | Should -Match 'ProjectDir \$launchDir'
        $script:winsmuxRoleRawContent | Should -Match 'respawn-pane -k -t \$paneId -c \$launchDir'
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
        $script:winsmuxRoleRawContent | Should -Match 'set-environment -t \$sessionName'
        $script:winsmuxRoleRawContent | Should -Match 'set-environment -u -t \$sessionName \$name'
        $script:winsmuxRoleRawContent | Should -Not -Match 'codex --sandbox danger-full-access -C'
        $launchIndex = $script:winsmuxRoleRawContent.IndexOf('$launchCmd = Get-BridgeProviderLaunchCommand')
        $nonWorkerResetIndex = $script:winsmuxRoleRawContent.IndexOf('$manifestRole -notin @(''Builder'', ''Worker'')')
        $renameIndex = $script:winsmuxRoleRawContent.IndexOf('& winsmux select-pane -t $paneId -T $newLabel')
        $manifestUpdateIndex = $script:winsmuxRoleRawContent.IndexOf('Set-PaneControlManifestPaneProperties -ManifestPath $manifestPath')
        $environmentIndex = $script:winsmuxRoleRawContent.IndexOf('$paneEnvironment = Get-WinsmuxPaneEnvironment')
        $environmentClearIndex = $script:winsmuxRoleRawContent.IndexOf('& winsmux set-environment -u -t $sessionName $name')
        $respawnIndex = $script:winsmuxRoleRawContent.IndexOf('& winsmux respawn-pane -k -t $paneId -c $launchDir')
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
}

Describe 'winsmux provider-switch command' {
    BeforeAll {
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreRawContent = Get-Content -Path $script:winsmuxCoreRawPath -Raw -Encoding UTF8
    }

    BeforeEach {
        $script:providerSwitchTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-provider-switch-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:providerSwitchTempRoot -Force | Out-Null
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
'@ | Set-Content -Path (Join-Path $script:providerSwitchTempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:providerSwitchTempRoot '.winsmux') -Force | Out-Null
@'
{
  "version": 1,
  "providers": {
    "codex": {
      "adapter": "codex",
      "command": "codex",
      "prompt_transports": ["argv", "file", "stdin"],
      "auth_modes": ["api-key", "codex-chatgpt-local"],
      "local_interactive_oauth_modes": ["codex-chatgpt-local"],
      "supports_parallel_runs": true,
      "supports_interrupt": true,
      "supports_structured_result": true,
      "supports_file_edit": true,
      "supports_subagents": true,
      "supports_verification": true,
      "supports_consultation": false
    },
    "claude": {
      "adapter": "claude",
      "command": "claude",
      "prompt_transports": ["file"],
      "auth_modes": ["api-key", "claude-pro-max-oauth"],
      "local_interactive_oauth_modes": ["claude-pro-max-oauth"],
      "supports_parallel_runs": false,
      "supports_interrupt": true,
      "supports_structured_result": false,
      "supports_file_edit": true,
      "supports_subagents": false,
      "supports_verification": true,
      "supports_consultation": true
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
        $script:winsmuxCoreRawContent | Should -Match 'provider-switch <slot> \[--agent <name>\] \[--model <name>\] \[--prompt-transport <argv\|file\|stdin>\] \[--auth-mode <mode>\] \[--reason <text>\] \[--restart\] \[--clear\] \[--json\]'
        $script:winsmuxCoreRawContent | Should -Match "'provider-switch'\s*\{"

        Push-Location $script:providerSwitchTempRoot
        try {
            $output = & pwsh -NoProfile -File $script:winsmuxCoreRawPath provider-switch worker-1 --agent claude --model opus --prompt-transport file --auth-mode claude-pro-max-oauth --reason 'operator requested provider switch' --json
        } finally {
            Pop-Location
        }

        $result = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $result.slot_id | Should -Be 'worker-1'
        $result.agent | Should -Be 'claude'
        $result.model | Should -Be 'opus'
        $result.prompt_transport | Should -Be 'file'
        $result.auth_mode | Should -Be 'claude-pro-max-oauth'
        $result.auth_policy | Should -Be 'local_interactive_only'
        $result.source | Should -Be 'registry'
        $result.capability_adapter | Should -Be 'claude'
        $result.capability_command | Should -Be 'claude'
        $result.supports_file_edit | Should -Be $true
        $result.supports_subagents | Should -Be $false
        $result.supports_consultation | Should -Be $true
        $result.restart_requested | Should -Be $false
        $result.restarted | Should -Be $false

        $registryPath = Join-Path $script:providerSwitchTempRoot '.winsmux\provider-registry.json'
        Test-Path -LiteralPath $registryPath | Should -Be $true
        $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $registry.slots.'worker-1'.agent | Should -Be 'claude'
        $registry.slots.'worker-1'.model | Should -Be 'opus'
        $registry.slots.'worker-1'.prompt_transport | Should -Be 'file'
        $registry.slots.'worker-1'.reason | Should -Be 'operator requested provider switch'
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
        $result.clear_requested | Should -Be $true
        $result.cleared | Should -Be $true
        $registry = Get-Content -LiteralPath (Join-Path $script:providerSwitchTempRoot '.winsmux\provider-registry.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $registry.slots.PSObject.Properties.Name | Should -Not -Contain 'worker-1'
    }

    It 'documents provider-switch restart and routes it through the manifest-backed restart helper' {
        $script:winsmuxCoreRawContent | Should -Match "'--restart'\s*\{"
        $script:winsmuxCoreRawContent | Should -Match "'--clear'\s*\{"
        $script:winsmuxCoreRawContent | Should -Match 'Get-PaneControlManifestEntries -ProjectDir \$projectDir'
        $script:winsmuxCoreRawContent | Should -Match 'Confirm-Target \(\[string\]\$manifestEntry\[0\]\.PaneId\)'
        $script:winsmuxCoreRawContent | Should -Match 'Invoke-RestartPane -PaneId'
        $script:winsmuxCoreRawContent | Should -Match '\$restartReadinessAgent\s*=\s*Get-RestartReadinessAgentName -Plan \$plan'
        $script:winsmuxCoreRawContent | Should -Match 'Test-AgentReadyPrompt -PaneId \$PaneId -Agent \$restartReadinessAgent'
        $script:winsmuxCoreRawContent | Should -Not -Match 'timed out waiting for Codex after restart'
        $script:winsmuxCoreRawContent | Should -Match 'Remove-BridgeProviderRegistryEntry -RootPath \$projectDir -SlotId \$slotId'
        $script:winsmuxCoreRawContent | Should -Match 'clear_requested'
        $script:winsmuxCoreRawContent | Should -Match 'restart_requested'
        $script:winsmuxCoreRawContent | Should -Match 'restart_pane_id'
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
        $script:winsmuxCoreRawPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreRawContent = Get-Content -Path $script:winsmuxCoreRawPath -Raw -Encoding UTF8
        $script:orchestraSmokePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-smoke.ps1'
        $script:orchestraSmokeContent = Get-Content -Path $script:orchestraSmokePath -Raw -Encoding UTF8

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
                    param($State, [string]$SessionName)
                    return $LiveVisibleAttach
                }

                function Test-OrchestraAttachClientSnapshotMatch {
                    param([string[]]$ExpectedClients, [string[]]$CurrentClients)
                    if ($ExpectedClients.Count -ne $CurrentClients.Count) {
                        return $false
                    }

                    for ($i = 0; $i -lt $ExpectedClients.Count; $i++) {
                        if ($ExpectedClients[$i] -ne $CurrentClients[$i]) {
                            return $false
                        }
                    }

                    return $true
                }

                function Get-OrchestraAttachTraceEntries {
                    param($State)
                    if ($null -eq $State -or $null -eq $State.PSObject.Properties['attach_adapter_trace']) {
                        return @()
                    }

                    return @($State.attach_adapter_trace)
                }

                Invoke-Expression $resolverSource
                Resolve-OrchestraSmokeAttachState -ProbeState $ProbeState -AttachState $AttachState -ClientProbeOk $ClientProbeOk -ClientSnapshot $ClientSnapshot
            } $ProbeState $AttachState $ClientProbeOk $ClientSnapshot $LiveVisibleAttach
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

    It 'accepts attached-client registry matches as attach truth when the host launcher process is gone' {
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

        $resolution.UiAttached | Should -Be $true
        $resolution.UiAttachStatus | Should -Be 'attach_confirmed'
        $resolution.UiAttachSource | Should -Be 'attached-client-registry'
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
}

Describe 'operator startup restore contract docs' {
    BeforeAll {
        $script:claudeGuidePath = Join-Path (Split-Path -Parent $PSScriptRoot) '.claude\CLAUDE.md'
        $script:claudeGuideContent = Get-Content -Path $script:claudeGuidePath -Raw -Encoding UTF8
        $script:dispatchRulePath = Join-Path (Split-Path -Parent $PSScriptRoot) '.claude\rules\dispatch.md'
        $script:dispatchRuleContent = Get-Content -Path $script:dispatchRulePath -Raw -Encoding UTF8
    }

    It 'requires orchestra-smoke operator_contract instead of legacy psmux probes' {
        $script:claudeGuideContent | Should -Match 'winsmux orchestra-smoke --json'
        $script:claudeGuideContent | Should -Match 'use the term\s+\*\*operator\*\*'
        $script:claudeGuideContent | Should -Match 'needs-startup'
        $script:claudeGuideContent | Should -Match 'orchestra-start\.ps1'
        $script:claudeGuideContent | Should -Match 'operator_contract\.operator_state'
        $script:claudeGuideContent | Should -Match 'operator_contract\.can_dispatch'
        $script:claudeGuideContent | Should -Match 'operator_contract\.requires_startup'
        $script:claudeGuideContent | Should -Match 'ready-with-ui-warning'
        $script:claudeGuideContent | Should -Match 'not dispatch-ready'
        $script:claudeGuideContent | Should -Match 'attached-client confirmation is still missing'
        $script:claudeGuideContent | Should -Match 'winsmux orchestra-attach --json'
        $script:claudeGuideContent | Should -Match 'winsmux dispatch-task'
        $script:claudeGuideContent | Should -Match 'called MCP'
        $script:claudeGuideContent | Should -Match 'plugin bootstrap messages must not be used as readiness evidence'
        $script:claudeGuideContent | Should -Match 'hook validation noise'
        $script:claudeGuideContent | Should -Match 'prevents a clean `winsmux orchestra-smoke --json` result from being obtained'
        $script:claudeGuideContent | Should -Match 'start the first pending action automatically instead of asking which task to begin'
        $script:claudeGuideContent | Should -Match 'do not use Explore subagents for PR/task analysis'
        $script:claudeGuideContent | Should -Match 'Do not perform operator-side code review judgements'
        $script:claudeGuideContent | Should -Match 'Do not report that review was dispatched until formal review evidence is observed'
        $script:claudeGuideContent | Should -Match 'review dispatch blocked'
        $script:claudeGuideContent | Should -Match 'psmux --version'
        $script:claudeGuideContent | Should -Match 'Get-Process psmux-server'
        $script:claudeGuideContent | Should -Match 'manually start a `psmux` server'
        $script:dispatchRuleContent | Should -Match '# Operator Dispatch Procedure'
        $script:dispatchRuleContent | Should -Match 'User-facing progress updates must use \*\*operator\*\*'
        $script:dispatchRuleContent | Should -Match 'scripts/winsmux-core\.ps1 orchestra-smoke --json'
        $script:dispatchRuleContent | Should -Match 'scripts/winsmux-core\.ps1 orchestra-attach --json'
        $script:dispatchRuleContent | Should -Match 'scripts/winsmux-core\.ps1 dispatch-task'
        $script:dispatchRuleContent | Should -Match 'needs-startup'
        $script:dispatchRuleContent | Should -Match 'orchestra-start\.ps1'
        $script:dispatchRuleContent | Should -Match 'operator_contract\.operator_state'
        $script:dispatchRuleContent | Should -Match 'operator_contract\.can_dispatch'
        $script:dispatchRuleContent | Should -Match 'operator_contract\.requires_startup'
        $script:dispatchRuleContent | Should -Match 'ready-with-ui-warning'
        $script:dispatchRuleContent | Should -Match 'Allowed structured startup states'
        $script:dispatchRuleContent | Should -Match 'not dispatch-ready'
        $script:dispatchRuleContent | Should -Match 'attached-client confirmation is still missing'
        $script:dispatchRuleContent | Should -Match 'called MCP'
        $script:dispatchRuleContent | Should -Match 'must not be used as readiness evidence'
        $script:dispatchRuleContent | Should -Match 'hook validation noise'
        $script:dispatchRuleContent | Should -Match 'prevents a clean `orchestra-smoke --json` result from being obtained'
        $script:dispatchRuleContent | Should -Match 'Never ask the user which task to begin'
        $script:dispatchRuleContent | Should -Match 'Explore subagents are reserved for orchestra startup/status diagnosis only'
        $script:dispatchRuleContent | Should -Match 'Operator runs tests'
        $script:dispatchRuleContent | Should -Match 'operator-side code review judgement is not'
        $script:dispatchRuleContent | Should -Match 'Before reporting that review was dispatched'
        $script:dispatchRuleContent | Should -Match 'review dispatch blocked'
        $script:dispatchRuleContent | Should -Match 'psmux --version'
        $script:dispatchRuleContent | Should -Match 'Get-Process psmux-server'
    }

    It 'keeps operator-facing script errors pinned to winsmux instead of exposing compatibility aliases' {
        $settingsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\settings.ps1'
        $setupWizardPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\setup-wizard.ps1'
        $operatorPollPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\operator-poll.ps1'
        $agentMonitorPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\agent-monitor.ps1'
        $watchdogPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\server-watchdog.ps1'
        $orchestraStartPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-start.ps1'

        $settingsContent = Get-Content -Path $settingsPath -Raw -Encoding UTF8
        $setupWizardContent = Get-Content -Path $setupWizardPath -Raw -Encoding UTF8
        $operatorPollContent = Get-Content -Path $operatorPollPath -Raw -Encoding UTF8
        $agentMonitorContent = Get-Content -Path $agentMonitorPath -Raw -Encoding UTF8
        $watchdogContent = Get-Content -Path $watchdogPath -Raw -Encoding UTF8
        $orchestraStartContent = Get-Content -Path $orchestraStartPath -Raw -Encoding UTF8

        $settingsContent | Should -Match 'function Get-WinsmuxOperatorNotFoundMessage'
        $settingsContent | Should -Match 'Could not resolve the winsmux executable from PATH'
        $setupWizardContent | Should -Match 'AI agent provider'
        $setupWizardContent | Should -Match 'Test-SetupWizardAgentProvider'
        $setupWizardContent | Should -Match 'provider-capabilities\.json first'
        $setupWizardContent | Should -Not -Match 'AI agent CLI \(codex/claude\)'
        $setupWizardContent | Should -Not -Match "Please enter 'codex' or 'claude'\."
        $setupWizardContent | Should -Not -Match 'Tried: winsmux, pmux, tmux'
        $operatorPollContent | Should -Not -Match 'Tried: winsmux, pmux, tmux'
        $agentMonitorContent | Should -Not -Match 'Tried: winsmux, pmux, tmux'
        $watchdogContent | Should -Not -Match 'Tried: winsmux, pmux, tmux'
        $orchestraStartContent | Should -Not -Match 'Tried: winsmux, pmux, tmux'
    }

    It 'keeps the legacy orchestra prompt provider-neutral' {
        $legacyStartPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\start-orchestra.ps1'
        $legacyStartContent = Get-Content -Path $legacyStartPath -Raw -Encoding UTF8

        $legacyStartContent | Should -Match '## Builder Agents'
        $legacyStartContent | Should -Match 'configured agent'
        $legacyStartContent | Should -Match 'configured agent command'
        $legacyStartContent | Should -Match 'settings\.ps1'
        $legacyStartContent | Should -Match 'function ConvertTo-LegacyCodexModelArgument'
        $legacyStartContent | Should -Match '\$modelArgument = "model=\$Model"'
        $legacyStartContent | Should -Match 'ConvertTo-BridgePowerShellLiteral -Value \$modelArgument'
        $legacyStartContent | Should -Match 'function Get-LegacyDefaultAgentSpec'
        $legacyStartContent | Should -Match 'Read-BridgeGlobalSettings'
        $legacyStartContent | Should -Match 'Read-BridgeProjectSettings -RootPath \$ProjectDir'
        $legacyStartContent | Should -Match 'ConvertTo-BridgeSettingsSource'
        $legacyStartContent | Should -Match 'Get-BridgeProviderRegistryEntry -SlotId \$SlotId -RootPath \$ProjectDir'
        $legacyStartContent | Should -Match '\$hasExplicitSlotConfig = \$true'
        $legacyStartContent | Should -Match '\$hasExplicitAgentOverride = \$true'
        $legacyStartContent | Should -Match '\$hasExplicitModelOverride = \$true'
        $legacyStartContent | Should -Match '\$globalSettings\.Contains\(''agent''\)'
        $legacyStartContent | Should -Match '\$globalSettings\.Contains\(''model''\)'
        $legacyStartContent | Should -Match '\$projectSettings\.Contains\(''agent''\)'
        $legacyStartContent | Should -Match '\$projectSettings\.Contains\(''model''\)'
        $legacyStartContent | Should -Match '\$null -eq \$registryEntry'
        $legacyStartContent | Should -Match 'Get-SlotAgentConfig -Role \$Role -SlotId \$SlotId -Settings \$settings -RootPath \$ProjectDir'
        $legacyStartContent | Should -Match '\$slotAgentConfig\.Source -eq ''role'' -and -not \$hasExplicitRoleConfig -and -not \$hasExplicitAgentOverride'
        $legacyStartContent | Should -Match 'if \(-not \$hasExplicitAgentOverride\)'
        $legacyStartContent | Should -Match '\$effectiveProvider = \(\[string\]\$slotAgentConfig\.Agent\)\.Trim\(\)'
        $legacyStartContent | Should -Match '\[string\]::Equals\(\$effectiveProvider, \$FallbackAdapter, \[System\.StringComparison\]::OrdinalIgnoreCase\)'
        $legacyStartContent | Should -Match 'ConvertTo-LegacyCodexModelArgument -Model \$fallbackModel'
        $legacyStartContent | Should -Match 'if \(-not \$hasExplicitModelOverride\)'
        $legacyStartContent | Should -Match 'ConvertTo-LegacyCodexModelArgument -Model \$model'
        $legacyStartContent | Should -Match 'claude --model \$modelLiteral'
        $legacyStartContent | Should -Match 'Resolve-BridgeProviderCapability -ProviderId \$provider -RootPath \$ProjectDir -RequireWhenRegistryPresent'
        $legacyStartContent | Should -Match 'Get-ApprovalFreeCommand -Cmd \$agent\.command -Adapter \$agent\.adapter'
        $legacyStartContent | Should -Match '\$adapterKey -eq ''codex'''
        $legacyStartContent | Should -Match '\$_.adapter -eq ''codex'''
        $legacyStartContent | Should -Match 'Get-Command Resolve-BridgeProviderCapability -ErrorAction SilentlyContinue'
        $legacyStartContent | Should -Match 'Get-Command Get-BridgeProviderCapabilityValue -ErrorAction SilentlyContinue'
        $legacyStartContent | Should -Not -Match 'Falling back to legacy command'
        $legacyStartContent | Should -Not -Match '## Codex Builders'
        $legacyStartContent | Should -Not -Match 'Codex idle prompt'
        $legacyStartContent | Should -Not -Match 'restart codex'
    }
}

Describe 'orchestra pane bootstrap plan' {
    BeforeAll {
        $script:orchestraStartPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-start.ps1'
        $script:orchestraStartContent = Get-Content -Path $script:orchestraStartPath -Raw -Encoding UTF8
        $script:orchestraPaneBootstrapPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-pane-bootstrap.ps1'
        $script:orchestraPaneBootstrapContent = Get-Content -Path $script:orchestraPaneBootstrapPath -Raw -Encoding UTF8
    }

    It 'uses a plan file driven pane bootstrap instead of sending many environment commands directly' {
        $script:orchestraStartContent | Should -Match 'function New-OrchestraPaneBootstrapPlan'
        $script:orchestraStartContent | Should -Match 'function Get-OrchestraPaneBootstrapMarkerPath'
        $script:orchestraStartContent | Should -Match 'function Start-OrchestraPaneBootstrap'
        $script:orchestraStartContent | Should -Match 'function Wait-OrchestraServerSessionAbsent'
        $script:orchestraStartContent | Should -Match 'orchestra-pane-bootstrap\.ps1'
        $script:orchestraStartContent | Should -Match 'Start-OrchestraPaneBootstrap -PaneId \$paneId -PlanPath \$bootstrapPlanPath'
        $script:orchestraStartContent | Should -Match 'ready_marker_path'
        $script:orchestraStartContent | Should -Match 'Wait-OrchestraServerSessionAbsent -SessionName \$SessionName -TimeoutSeconds 20'
    }

    It 'passes the project root into slot provider resolution' {
        $script:orchestraStartContent | Should -Match 'Get-SlotAgentConfig -Role \$canonicalRole -SlotId \$label -Settings \$settings -RootPath \$projectDir'
    }

    It 'builds pane launch commands through provider capability metadata' {
        $script:orchestraStartContent | Should -Match 'Get-BridgeProviderLaunchCommand'
        $script:orchestraStartContent | Should -Match 'Get-AgentLaunchCommand -Agent \$slotAgentConfig\.Agent -Model \$slotAgentConfig\.Model -ProjectDir \$launchDir -GitWorktreeDir \$launchGitWorktreeDir -RootPath \$projectDir'
    }

    It 'prints a concise startup summary before invoking the agent launch command' {
        $script:orchestraPaneBootstrapContent | Should -Match '\[winsmux\] pane bootstrap:'
        $script:orchestraPaneBootstrapContent | Should -Match 'launch_command'
        $script:orchestraPaneBootstrapContent | Should -Match 'Invoke-Expression \$launchCommand'
    }
}

Describe 'TASK-278 golden corpus fixtures' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    AfterEach {
        $global:Target = $null
        $global:Rest = @()
        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

    It 'keeps board json fixture stable' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-board-golden-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null

        try {
            Push-Location $tempRoot
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-244
    task: Implement session board
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    builder_worktree_path: .worktrees/builder-1
    head_sha: abc1234def5678
    changed_file_count: 2
    changed_files: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    last_event: pane.ready
    last_event_at: 2026-04-10T10:00:00+09:00
  worker-1:
    pane_id: %6
    role: Worker
    task_id: ''
    task: ''
    task_state: backlog
    task_owner: ''
    review_state: ''
    branch: ''
    head_sha: ''
    changed_file_count: 0
    changed_files: '[]'
    last_event: pane.idle
    last_event_at: 2026-04-10T10:05:00+09:00
"@ | Set-Content -Path $manifestPath -Encoding UTF8

            function global:winsmux {
                $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
                switch -Regex ($commandLine) {
                    '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                    '^capture-pane .*%6' { return @('gpt-5.4   52% context left', 'thinking', 'Esc to interrupt') }
                    default { throw "unexpected winsmux call: $commandLine" }
                }
            }

            $result = (Invoke-Board -BoardTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)
            Assert-GoldenCorpusFixture -FixturePath 'tests/fixtures/rust-parity/board.json' -InputObject $result -ProjectDir $tempRoot
        } finally {
            Pop-Location
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'keeps inbox json fixture stable' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-inbox-golden-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'
        $eventsPath = Join-Path $manifestDir 'events.jsonl'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null

        try {
            Push-Location $tempRoot
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-245
    task: Build inbox surface
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: review.requested
    last_event_at: 2026-04-10T11:00:00+09:00
  worker-1:
    pane_id: %6
    role: Worker
    task_id: task-999
    task: Fix blocker
    task_state: blocked
    task_owner: worker-1
    review_state: ''
    branch: worktree-worker-1
    head_sha: def5678abc1234
    changed_file_count: 0
    changed_files: '[]'
    last_event: operator.state_transition
    last_event_at: 2026-04-10T11:05:00+09:00
"@ | Set-Content -Path $manifestPath -Encoding UTF8

            @(
                ([ordered]@{
                    timestamp = '2026-04-10T11:02:00+09:00'
                    session   = 'winsmux-orchestra'
                    event     = 'pane.approval_waiting'
                    message   = 'approval prompt detected'
                    label     = 'builder-1'
                    pane_id   = '%2'
                    role      = 'Builder'
                    status    = 'approval_waiting'
                } | ConvertTo-Json -Compress),
                ([ordered]@{
                    timestamp = '2026-04-10T11:06:00+09:00'
                    session   = 'winsmux-orchestra'
                    event     = 'operator.state_transition'
                    message   = 'State: review_requested -> blocked_no_review_target'
                    label     = ''
                    pane_id   = ''
                    role      = 'Operator'
                    status    = 'blocked_no_review_target'
                    data      = [ordered]@{
                        from = 'review_requested'
                        to   = 'blocked_no_review_target'
                    }
                } | ConvertTo-Json -Compress),
                ([ordered]@{
                    timestamp = '2026-04-10T11:08:00+09:00'
                    session   = 'winsmux-orchestra'
                    event     = 'operator.commit_ready'
                    message   = 'コミット準備完了。'
                    label     = ''
                    pane_id   = ''
                    role      = 'Operator'
                    status    = 'commit_ready'
                    head_sha  = 'abc1234def5678'
                } | ConvertTo-Json -Compress)
            ) | Set-Content -Path $eventsPath -Encoding UTF8

            function global:winsmux {
                $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
                switch -Regex ($commandLine) {
                    '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                    default { throw "unexpected winsmux call: $commandLine" }
                }
            }

            $result = (Invoke-Inbox -InboxTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)
            Assert-GoldenCorpusFixture -FixturePath 'tests/fixtures/rust-parity/inbox.json' -InputObject $result -ProjectDir $tempRoot
        } finally {
            Pop-Location
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'keeps digest json fixture stable' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-digest-golden-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'
        $eventsPath = Join-Path $manifestDir 'events.jsonl'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null

        try {
            Push-Location $tempRoot
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-246
    task: Build evidence digest
    task_state: blocked
    task_owner: builder-1
    review_state: FAIL
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_failed
    last_event_at: 2026-04-10T14:00:00+09:00
"@ | Set-Content -Path $manifestPath -Encoding UTF8

            $digestObservationPack = New-ObservationPackFile -ProjectDir $tempRoot -ObservationPack ([ordered]@{
                run_id          = 'task:task-246'
                task_id         = 'task-246'
                pane_id         = '%2'
                slot            = 'slot-builder-1'
                hypothesis      = 'result summary should appear in digest'
                env_fingerprint = 'env:abc123'
            })
            $digestConsultationPacket = New-ConsultationPacketFile -ProjectDir $tempRoot -ConsultationPacket ([ordered]@{
                run_id         = 'task:task-246'
                task_id        = 'task-246'
                pane_id        = '%2'
                slot           = 'slot-builder-1'
                kind           = 'consult_result'
                mode           = 'reconcile'
                target_slot    = 'slot-review-1'
                confidence     = 0.88
                recommendation = 'treat review failure as blocking'
                next_test      = 'review_failed'
            })

            ([ordered]@{
                timestamp = '2026-04-10T14:03:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.review_failed'
                message   = 'review failed'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'review_failed'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id              = 'task-246'
                    hypothesis           = 'result summary should appear in digest'
                    result               = 'review failure reproduced'
                    confidence           = 0.88
                    next_action          = 'review_failed'
                    observation_pack_ref = $digestObservationPack.reference
                    consultation_ref     = $digestConsultationPacket.reference
                }
            } | ConvertTo-Json -Compress) | Set-Content -Path $eventsPath -Encoding UTF8

            function global:winsmux {
                $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
                switch -Regex ($commandLine) {
                    '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                    default { throw "unexpected winsmux call: $commandLine" }
                }
            }

            $result = (Invoke-Digest -DigestTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)
            Assert-GoldenCorpusFixture -FixturePath 'tests/fixtures/rust-parity/digest.json' -InputObject $result -ProjectDir $tempRoot
        } finally {
            Pop-Location
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }

    It 'keeps explain json fixture stable' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-explain-golden-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $tempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'
        $eventsPath = Join-Path $manifestDir 'events.jsonl'
        $reviewStatePath = Join-Path $manifestDir 'review-state.json'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null

        try {
            Push-Location $tempRoot
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $tempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    parent_run_id: operator:session-1
    goal: Ship run contract primitives
    task: Implement run ledger
    task_type: implementation
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    priority: P0
    blocking: true
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    write_scope: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    read_scope: '["winsmux-core/scripts/pane-status.ps1"]'
    constraints: '["preserve existing board schema"]'
    expected_output: Stable explain JSON
    verification_plan: '["Invoke-Pester tests/winsmux-bridge.Tests.ps1","verify explain --json contract"]'
    review_required: true
    provider_target: codex:gpt-5.4
    agent_role: worker
    timeout_policy: standard
    handoff_refs: '["docs/handoff.md"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $manifestPath -Encoding UTF8

            $explainObservationPack = New-ObservationPackFile -ProjectDir $tempRoot -ObservationPack ([ordered]@{
                run_id               = 'task:task-256'
                task_id              = 'task-256'
                pane_id              = '%2'
                slot                 = 'slot-builder-1'
                hypothesis           = 'experiment packet should flow into explain'
                test_plan            = @('collect matching events', 'normalize packet')
                changed_files        = @('scripts/winsmux-core.ps1')
                working_tree_summary = '1 file modified'
                failing_command      = 'Invoke-Pester tests/winsmux-bridge.Tests.ps1'
                env_fingerprint      = 'env:abc123'
                command_hash         = 'cmd:def456'
            })
            $explainConsultationPacket = New-ConsultationPacketFile -ProjectDir $tempRoot -ConsultationPacket ([ordered]@{
                run_id         = 'task:task-256'
                task_id        = 'task-256'
                pane_id        = '%2'
                slot           = 'slot-builder-1'
                kind           = 'consult_result'
                mode           = 'early'
                target_slot    = 'slot-review-1'
                confidence     = 0.66
                recommendation = 'consult before work'
                next_test      = 'approval_waiting'
                risks          = @('needs reviewer confirmation')
            })

            @(
                ([ordered]@{
                    timestamp = '2026-04-10T12:01:00+09:00'
                    session   = 'winsmux-orchestra'
                    event     = 'operator.review_requested'
                    message   = 'review requested'
                    label     = 'reviewer-1'
                    pane_id   = '%3'
                    role      = 'Reviewer'
                    branch    = 'worktree-builder-1'
                    head_sha  = 'abc1234def5678'
                    data      = [ordered]@{
                        task_id = 'task-256'
                        slot    = 'slot-builder-1'
                    }
                } | ConvertTo-Json -Compress),
                ([ordered]@{
                    timestamp = '2026-04-10T12:02:00+09:00'
                    session   = 'winsmux-orchestra'
                    event     = 'consult.result'
                    message   = 'consult before work'
                    label     = 'builder-1'
                    pane_id   = '%2'
                    role      = 'Builder'
                    branch    = 'worktree-builder-1'
                    head_sha  = 'abc1234def5678'
                    data      = [ordered]@{
                        task_id              = 'task-256'
                        result               = 'consult before work'
                        confidence           = 0.66
                        next_action          = 'approval_waiting'
                        observation_pack_ref = $explainObservationPack.reference
                        consultation_ref     = $explainConsultationPacket.reference
                    }
                } | ConvertTo-Json -Compress)
            ) | Set-Content -Path $eventsPath -Encoding UTF8

@'
{
  "task:task-256": {
    "verification_contract": {
      "mode": "adversarial_verify",
      "required_evidence": [
        "tests",
        "review"
      ]
    },
    "verification_result": {
      "outcome": "PARTIAL",
      "summary": "review pending"
    }
  }
}
'@ | Set-Content -Path $reviewStatePath -Encoding UTF8

            function global:winsmux {
                $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
                switch -Regex ($commandLine) {
                    '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                    default { throw "unexpected winsmux call: $commandLine" }
                }
            }

            $result = (Invoke-Explain -ExplainTarget 'task:task-256' -ExplainRest @('--json') | Out-String | ConvertFrom-Json -AsHashtable)
            Assert-GoldenCorpusFixture -FixturePath 'tests/fixtures/rust-parity/explain.json' -InputObject $result -ProjectDir $tempRoot
        } finally {
            Pop-Location
            if (Test-Path $tempRoot) {
                Remove-Item -Path $tempRoot -Recurse -Force
            }
        }
    }
}

Describe 'winsmux compare-runs and promote-tactic commands' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:compareTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-compare-tests-' + [guid]::NewGuid().ToString('N'))
        $script:compareManifestDir = Join-Path $script:compareTempRoot '.winsmux'
        $script:compareManifestPath = Join-Path $script:compareManifestDir 'manifest.yaml'
        $script:compareEventsPath = Join-Path $script:compareManifestDir 'events.jsonl'
        New-Item -ItemType Directory -Path $script:compareManifestDir -Force | Out-Null

@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:compareTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-compare-a
    task: Compare run A
    task_state: completed
    review_state: PASS
    branch: worktree-builder-a
    head_sha: aaaabbbbccccdddd
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-12T10:00:00+09:00
  builder-2:
    pane_id: %4
    role: Worker
    task_id: task-compare-b
    task: Compare run B
    task_state: completed
    review_state: PASS
    branch: worktree-builder-b
    head_sha: eeeeffff11112222
    changed_file_count: 2
    changed_files: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    last_event: pane.consult_result
    last_event_at: 2026-04-12T10:05:00+09:00
"@ | Set-Content -Path $script:compareManifestPath -Encoding UTF8

        $script:compareObsA = New-ObservationPackFile -ProjectDir $script:compareTempRoot -ObservationPack ([ordered]@{
            run_id          = 'task:task-compare-a'
            task_id         = 'task-compare-a'
            pane_id         = '%2'
            slot            = 'slot-builder-a'
            hypothesis      = 'deterministic command fixes cache drift'
            test_plan       = @('rerun build', 'check cache hit')
            env_fingerprint = 'env:a'
            command_hash    = 'cmd:a'
            changed_files   = @('scripts/winsmux-core.ps1')
        })
        $script:compareObsB = New-ObservationPackFile -ProjectDir $script:compareTempRoot -ObservationPack ([ordered]@{
            run_id          = 'task:task-compare-b'
            task_id         = 'task-compare-b'
            pane_id         = '%4'
            slot            = 'slot-builder-b'
            hypothesis      = 'framework inference is re-injecting noise'
            test_plan       = @('disable inference', 'rerun build')
            env_fingerprint = 'env:b'
            command_hash    = 'cmd:b'
            changed_files   = @('scripts/winsmux-core.ps1', 'tests/winsmux-bridge.Tests.ps1')
        })
        $script:compareConsultA = New-ConsultationPacketFile -ProjectDir $script:compareTempRoot -ConsultationPacket ([ordered]@{
            run_id         = 'task:task-compare-a'
            task_id        = 'task-compare-a'
            pane_id        = '%2'
            slot           = 'slot-builder-a'
            kind           = 'consult_result'
            mode           = 'early'
            confidence     = 0.85
            recommendation = 'prefer deterministic command'
            next_test      = 'promote tactic'
        })
        $script:compareConsultB = New-ConsultationPacketFile -ProjectDir $script:compareTempRoot -ConsultationPacket ([ordered]@{
            run_id         = 'task:task-compare-b'
            task_id        = 'task-compare-b'
            pane_id        = '%4'
            slot           = 'slot-builder-b'
            kind           = 'consult_result'
            mode           = 'reconcile'
            confidence     = 0.4
            recommendation = 'needs reconcile consult'
            next_test      = 'reconcile consult'
        })

        @(
            ([ordered]@{
                timestamp = '2026-04-12T10:00:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.review_requested'
                message   = 'review requested'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                branch    = 'worktree-builder-a'
                head_sha  = 'aaaabbbbccccdddd'
                data      = [ordered]@{
                    task_id              = 'task-compare-a'
                    run_id               = 'task:task-compare-a'
                    slot                 = 'slot-builder-a'
                    hypothesis           = 'deterministic command fixes cache drift'
                    result               = 'cache hit done'
                    confidence           = 0.85
                    next_action          = 'promote tactic'
                    observation_pack_ref = $script:compareObsA.reference
                    consultation_ref     = $script:compareConsultA.reference
                    worktree             = '.worktrees/builder-a'
                    env_fingerprint      = 'env:a'
                    command_hash         = 'cmd:a'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-12T10:05:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.consult_result'
                message   = 'consultation completed'
                label     = 'builder-2'
                pane_id   = '%4'
                role      = 'Worker'
                branch    = 'worktree-builder-b'
                head_sha  = 'eeeeffff11112222'
                data      = [ordered]@{
                    task_id              = 'task-compare-b'
                    run_id               = 'task:task-compare-b'
                    slot                 = 'slot-builder-b'
                    hypothesis           = 'framework inference is re-injecting noise'
                    result               = 'still dirty'
                    confidence           = 0.4
                    next_action          = 'reconcile consult'
                    observation_pack_ref = $script:compareObsB.reference
                    consultation_ref     = $script:compareConsultB.reference
                    worktree             = '.worktrees/builder-b'
                    env_fingerprint      = 'env:b'
                    command_hash         = 'cmd:b'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-12T10:05:10+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.verify.pass'
                message   = 'verification passed'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                branch    = 'worktree-builder-a'
                head_sha  = 'aaaabbbbccccdddd'
                data      = [ordered]@{
                    task_id = 'task-compare-a'
                    run_id  = 'task:task-compare-a'
                    verification_result = [ordered]@{
                        outcome = 'PASS'
                        summary = 'cache hit confirmed'
                    }
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-12T10:05:20+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.verify.pass'
                message   = 'verification passed'
                label     = 'builder-2'
                pane_id   = '%4'
                role      = 'Worker'
                branch    = 'worktree-builder-b'
                head_sha  = 'eeeeffff11112222'
                data      = [ordered]@{
                    task_id = 'task-compare-b'
                    run_id  = 'task:task-compare-b'
                    verification_result = [ordered]@{
                        outcome = 'PASS'
                        summary = 'rebuild confirmed'
                    }
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-12T10:05:30+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.security.allowed'
                message   = 'security allowed'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                branch    = 'worktree-builder-a'
                head_sha  = 'aaaabbbbccccdddd'
                data      = [ordered]@{
                    task_id = 'task-compare-a'
                    run_id  = 'task:task-compare-a'
                    verdict = 'ALLOW'
                    reason  = 'verified safe'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-12T10:05:40+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.security.allowed'
                message   = 'security allowed'
                label     = 'builder-2'
                pane_id   = '%4'
                role      = 'Worker'
                branch    = 'worktree-builder-b'
                head_sha  = 'eeeeffff11112222'
                data      = [ordered]@{
                    task_id = 'task-compare-b'
                    run_id  = 'task:task-compare-b'
                    verdict = 'ALLOW'
                    reason  = 'verified safe'
                }
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:compareEventsPath -Encoding UTF8

        Push-Location $script:compareTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:compareTempRoot -and (Test-Path $script:compareTempRoot)) {
            Remove-Item -Path $script:compareTempRoot -Recurse -Force
        }
    }

    It 'compares two runs and reports confidence and evidence deltas in json' {
        $result = (Invoke-CompareRuns -CompareTarget 'task:task-compare-a' -CompareRest @('task:task-compare-b', '--json') | Out-String | ConvertFrom-Json -AsHashtable)

        $result.left.run_id | Should -Be 'task:task-compare-a'
        $result.right.run_id | Should -Be 'task:task-compare-b'
        $result.confidence_delta | Should -Be 0.45
        $result.shared_changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $result.left_only_changed_files | Should -Be @()
        $result.right_only_changed_files | Should -Be @('tests/winsmux-bridge.Tests.ps1')
        $result.recommend.winning_run_id | Should -Be 'task:task-compare-a'
        $result.recommend.reconcile_consult | Should -Be $true
        @($result.differences | ForEach-Object { $_.field }) | Should -Contain 'result'
        @($result.differences | ForEach-Object { $_.field }) | Should -Contain 'confidence'
        @($result.differences | ForEach-Object { $_.field }) | Should -Contain 'changed_files'
    }

    It 'routes public compare runs through the same run comparison contract' {
        $result = (Invoke-Compare -CompareTarget 'runs' -CompareRest @('task:task-compare-a', 'task:task-compare-b', '--json') | Out-String | ConvertFrom-Json -AsHashtable)

        $result.left.run_id | Should -Be 'task:task-compare-a'
        $result.right.run_id | Should -Be 'task:task-compare-b'
        $result.recommend.winning_run_id | Should -Be 'task:task-compare-a'
    }

    It 'routes public compare preflight with compare-specific command guidance' {
        Mock Invoke-WinsmuxGitProbe {
            param($ProjectDir, [string[]]$Arguments)

            $commandLine = ($Arguments | ForEach-Object { [string]$_ }) -join ' '
            switch ($commandLine) {
                'rev-parse --show-toplevel' { return [PSCustomObject]@{ exit_code = 0; output = $script:compareTempRoot } }
                'rev-parse --verify left^{commit}' { return [PSCustomObject]@{ exit_code = 0; output = '1111111111111111111111111111111111111111' } }
                'rev-parse --verify right^{commit}' { return [PSCustomObject]@{ exit_code = 0; output = '2222222222222222222222222222222222222222' } }
                'merge-base left right' { return [PSCustomObject]@{ exit_code = 1; output = '' } }
                default { throw "unexpected git probe: $commandLine" }
            }
        }

        $result = (Invoke-Compare -CompareTarget 'preflight' -CompareRest @('left', 'right', '--json') | Out-String | ConvertFrom-Json -AsHashtable)

        $result.command | Should -Be 'compare preflight'
        $result.status | Should -Be 'blocked'
        $result.next_action | Should -Match 'winsmux compare preflight'
    }

    It 'routes public compare promote through follow-up candidate export' {
        $result = (Invoke-Compare -CompareTarget 'promote' -CompareRest @('task:task-compare-a', '--title', 'Deterministic build command', '--json') | Out-String | ConvertFrom-Json -AsHashtable)

        $result.run_id | Should -Be 'task:task-compare-a'
        $result.candidate.title | Should -Be 'Deterministic build command'
        $result.candidate.observation_pack_ref | Should -Be $script:compareObsA.reference
    }

    It 'documents public compare and dispatches it from the top-level command table' {
        $raw = Get-Content -Path $script:winsmuxCorePath -Raw -Encoding UTF8

        $raw | Should -Match 'compare <runs\|preflight\|promote> \.\.\. \[--json\]\s+Public compare entrypoint'
        $raw | Should -Match "'compare'\s*\{\s*Invoke-Compare\s*\}"
    }

    It 'suppresses winner selection when a higher-confidence run is unhealthy' {
        @"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:compareTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-compare-a
    task: Compare run A
    task_state: completed
    review_state: PASS
    branch: worktree-builder-a
    head_sha: aaaabbbbccccdddd
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-12T10:00:00+09:00
  builder-2:
    pane_id: %4
    role: Worker
    task_id: task-compare-b
    task: Compare run B
    task_state: blocked
    review_state: FAIL
    branch: worktree-builder-b
    head_sha: eeeeffff11112222
    changed_file_count: 2
    changed_files: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    last_event: pane.consult_result
    last_event_at: 2026-04-12T10:05:00+09:00
"@ | Set-Content -Path $script:compareManifestPath -Encoding UTF8

        $unhealthyEvents = @(
            ([ordered]@{
                timestamp = '2026-04-12T10:00:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.review_requested'
                message   = 'review requested'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                branch    = 'worktree-builder-a'
                head_sha  = 'aaaabbbbccccdddd'
                data      = [ordered]@{
                    task_id              = 'task-compare-a'
                    run_id               = 'task:task-compare-a'
                    slot                 = 'slot-builder-a'
                    hypothesis           = 'deterministic command fixes cache drift'
                    result               = 'cache hit done'
                    confidence           = 0.85
                    next_action          = 'promote tactic'
                    observation_pack_ref = $script:compareObsA.reference
                    consultation_ref     = $script:compareConsultA.reference
                    worktree             = '.worktrees/builder-a'
                    env_fingerprint      = 'env:a'
                    command_hash         = 'cmd:a'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-12T10:00:20+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.verify.pass'
                message   = 'verification passed'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                branch    = 'worktree-builder-a'
                head_sha  = 'aaaabbbbccccdddd'
                data      = [ordered]@{
                    task_id = 'task-compare-a'
                    run_id  = 'task:task-compare-a'
                    verification_result = [ordered]@{
                        outcome = 'PASS'
                        summary = 'cache hit confirmed'
                    }
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-12T10:00:30+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.security.allowed'
                message   = 'security allowed'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                branch    = 'worktree-builder-a'
                head_sha  = 'aaaabbbbccccdddd'
                data      = [ordered]@{
                    task_id = 'task-compare-a'
                    run_id  = 'task:task-compare-a'
                    verdict = 'ALLOW'
                    reason  = 'verified safe'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-12T10:05:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.consult_result'
                message   = 'consultation completed'
                label     = 'builder-2'
                pane_id   = '%4'
                role      = 'Worker'
                branch    = 'worktree-builder-b'
                head_sha  = 'eeeeffff11112222'
                data      = [ordered]@{
                    task_id              = 'task-compare-b'
                    run_id               = 'task:task-compare-b'
                    slot                 = 'slot-builder-b'
                    hypothesis           = 'framework inference is re-injecting noise'
                    result               = 'still dirty'
                    confidence           = 0.95
                    next_action          = 'reconcile consult'
                    observation_pack_ref = $script:compareObsB.reference
                    consultation_ref     = $script:compareConsultB.reference
                    worktree             = '.worktrees/builder-b'
                    env_fingerprint      = 'env:b'
                    command_hash         = 'cmd:b'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-12T10:05:20+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.verify.fail'
                message   = 'verification failed'
                label     = 'builder-2'
                pane_id   = '%4'
                role      = 'Worker'
                branch    = 'worktree-builder-b'
                head_sha  = 'eeeeffff11112222'
                data      = [ordered]@{
                    task_id = 'task-compare-b'
                    run_id  = 'task:task-compare-b'
                    verification_result = [ordered]@{
                        outcome = 'FAIL'
                        summary = 'dirty build remains'
                    }
                }
            } | ConvertTo-Json -Compress)
        )
        $unhealthyEvents | Set-Content -Path $script:compareEventsPath -Encoding UTF8

        $result = (Invoke-CompareRuns -CompareTarget 'task:task-compare-a' -CompareRest @('task:task-compare-b', '--json') | Out-String | ConvertFrom-Json -AsHashtable)

        $result.left.recommendable | Should -Be $true
        $result.right.recommendable | Should -Be $false
        $result.recommend.winning_run_id | Should -Be ''
        $result.recommend.reconcile_consult | Should -Be $true
    }

    It 'exports a playbook candidate from a run and writes a file-backed artifact' {
        $result = (Invoke-PromoteTactic -PromoteTarget 'task:task-compare-a' -PromoteRest @('--title', 'Deterministic build command', '--json') | Out-String | ConvertFrom-Json -AsHashtable)

        $result.run_id | Should -Be 'task:task-compare-a'
        $result.candidate_ref | Should -BeLike '.winsmux/playbook-candidates/playbook-candidate-*.json'
        Test-Path -LiteralPath $result.candidate_path | Should -Be $true
        $result.candidate.packet_type | Should -Be 'playbook_candidate'
        $result.candidate.kind | Should -Be 'playbook'
        $result.candidate.title | Should -Be 'Deterministic build command'
        $result.candidate.summary | Should -Be 'prefer deterministic command'
        $result.candidate.hypothesis | Should -Be 'deterministic command fixes cache drift'
        $result.candidate.changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $result.candidate.observation_pack_ref | Should -Be $script:compareObsA.reference
        $result.candidate.consultation_ref | Should -Be $script:compareConsultA.reference
    }

    It 'fails closed for unsupported promote kind' {
        { Invoke-PromoteTactic -PromoteTarget 'task:task-compare-a' -PromoteRest @('--kind', 'unknown') } | Should -Throw '*Unsupported promote kind*'
    }

    It 'rejects promote-tactic for unhealthy runs' {
        @"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:compareTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-compare-a
    task: Compare run A
    task_state: blocked
    review_state: FAIL
    branch: worktree-builder-a
    head_sha: aaaabbbbccccdddd
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-12T10:00:00+09:00
"@ | Set-Content -Path $script:compareManifestPath -Encoding UTF8

        { Invoke-PromoteTactic -PromoteTarget 'task:task-compare-a' } | Should -Throw '*run is not promotable*'
    }

    It 'rejects promote-tactic when security clearance is missing' {
        @"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:compareTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-compare-a
    task: Compare run A
    task_state: completed
    review_state: PASS
    branch: worktree-builder-a
    head_sha: aaaabbbbccccdddd
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-12T10:00:00+09:00
"@ | Set-Content -Path $script:compareManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-12T10:00:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.review_requested'
                message   = 'review requested'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                branch    = 'worktree-builder-a'
                head_sha  = 'aaaabbbbccccdddd'
                data      = [ordered]@{
                    task_id              = 'task-compare-a'
                    run_id               = 'task:task-compare-a'
                    slot                 = 'slot-builder-a'
                    hypothesis           = 'deterministic command fixes cache drift'
                    result               = 'cache hit done'
                    confidence           = 0.85
                    next_action          = 'promote tactic'
                    observation_pack_ref = $script:compareObsA.reference
                    consultation_ref     = $script:compareConsultA.reference
                    worktree             = '.worktrees/builder-a'
                    env_fingerprint      = 'env:a'
                    command_hash         = 'cmd:a'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-12T10:05:10+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.verify.pass'
                message   = 'verification passed'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                branch    = 'worktree-builder-a'
                head_sha  = 'aaaabbbbccccdddd'
                data      = [ordered]@{
                    task_id = 'task-compare-a'
                    run_id  = 'task:task-compare-a'
                    verification_result = [ordered]@{
                        outcome = 'PASS'
                        summary = 'cache hit confirmed'
                    }
                }
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:compareEventsPath -Encoding UTF8

        { Invoke-PromoteTactic -PromoteTarget 'task:task-compare-a' } | Should -Throw '*run is not promotable*'
    }
}

Describe 'winsmux observation and consultation artifacts' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:artifactTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-artifact-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:artifactTempRoot -Force | Out-Null
    }

    AfterEach {
        if ($script:artifactTempRoot -and (Test-Path $script:artifactTempRoot)) {
            Remove-Item -Path $script:artifactTempRoot -Recurse -Force
        }
    }

    It 'writes and reads an observation pack with a stable relative reference' {
        $written = New-ObservationPackFile -ProjectDir $script:artifactTempRoot -ObservationPack ([ordered]@{
            run_id              = 'task:task-300'
            task_id             = 'task-300'
            pane_id             = '%2'
            slot                = 'slot-builder-1'
            hypothesis          = 'observation packs should be file-backed'
            test_plan           = @('write file', 'hydrate explain')
            env_fingerprint     = 'env:abc123'
            command_hash        = 'cmd:def456'
            changed_files       = @('scripts/winsmux-core.ps1')
            relevant_links      = @('https://example.test/logs/1')
        })

        $written.reference | Should -BeLike '.winsmux/observation-packs/observation-pack-*.json'
        Test-Path -LiteralPath $written.path | Should -Be $true

        $hydrated = Read-WinsmuxArtifactJson -Reference $written.reference -ProjectDir $script:artifactTempRoot -ExpectedDirectoryPath (Get-ObservationPackDirectory -ProjectDir $script:artifactTempRoot) -ExpectedRunId 'task:task-300'
        $hydrated.packet_type | Should -Be 'observation_pack'
        $hydrated.hypothesis | Should -Be 'observation packs should be file-backed'
        $hydrated.test_plan | Should -Be @('write file', 'hydrate explain')
        $hydrated.env_fingerprint | Should -Be 'env:abc123'
    }

    It 'rejects consultation packets with unsupported kind' {
        {
            New-ConsultationPacketFile -ProjectDir $script:artifactTempRoot -ConsultationPacket ([ordered]@{
                run_id  = 'task:task-301'
                task_id = 'task-301'
                pane_id = '%2'
                kind    = 'consult_maybe'
                mode    = 'early'
            })
        } | Should -Throw '*Unsupported consultation packet kind*'
    }

    It 'returns null when a packet file contains malformed json' {
        $badDir = Get-ObservationPackDirectory -ProjectDir $script:artifactTempRoot
        New-Item -ItemType Directory -Path $badDir -Force | Out-Null
        $badPath = Join-Path $badDir 'observation-pack-bad.json'
        Write-PsmuxBridgeTestFile -Path $badPath -Content '{ not-valid-json }'

        $hydrated = Read-WinsmuxArtifactJson -Reference '.winsmux/observation-packs/observation-pack-bad.json' -ProjectDir $script:artifactTempRoot -ExpectedDirectoryPath $badDir -ExpectedRunId 'task:task-300'
        $hydrated | Should -Be $null
    }
}

Describe 'winsmux consultation commands' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:consultTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-consult-tests-' + [guid]::NewGuid().ToString('N'))
        $manifestDir = Join-Path $script:consultTempRoot '.winsmux'
        $script:consultManifestPath = Join-Path $manifestDir 'manifest.yaml'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:consultTempRoot '.worktrees\builder-1') -Force | Out-Null

@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:consultTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    launch_dir: $script:consultTempRoot
    builder_worktree_path: $(Join-Path $script:consultTempRoot '.worktrees\builder-1')
    task_id: task-301
    task: Investigate consultation packets
    task_state: in_progress
    branch: worktree-builder-1
    head_sha: abc1234def5678
"@ | Set-Content -Path $script:consultManifestPath -Encoding UTF8

        Push-Location $script:consultTempRoot
        $script:originalPaneId = $env:WINSMUX_PANE_ID
        $script:originalAgentName = $env:WINSMUX_AGENT_NAME
        $script:originalRole = $env:WINSMUX_ROLE
        $env:WINSMUX_PANE_ID = '%2'
        $env:WINSMUX_AGENT_NAME = 'codex'
        $env:WINSMUX_ROLE = 'Builder'
    }

    AfterEach {
        $env:WINSMUX_PANE_ID = $script:originalPaneId
        $env:WINSMUX_AGENT_NAME = $script:originalAgentName
        $env:WINSMUX_ROLE = $script:originalRole
        Pop-Location

        if ($script:consultTempRoot -and (Test-Path $script:consultTempRoot)) {
            Remove-Item -Path $script:consultTempRoot -Recurse -Force
        }
    }

    It 'records a consult request as a file-backed packet and event' {
        $args = Parse-ConsultCommandArgs -Mode 'early' -Args @('--target-slot', 'slot-review-1', '--message', 'sanity-check the current hypothesis')

        $output = Write-ConsultationCommandRecord -Kind 'consult_request' -Mode ([string]$args.mode) -Message ([string]$args.message) -TargetSlot ([string]$args.target_slot) -ProjectDir $script:consultTempRoot

        $output | Should -Match 'consult request recorded for task:task-301'
        $events = @(Get-BridgeEventRecords -ProjectDir $script:consultTempRoot)
        $events.Count | Should -Be 1
        $events[0].event | Should -Be 'pane.consult_request'
        $events[0].data.consultation_ref | Should -BeLike '.winsmux/consultations/consult-request-*.json'
        $events[0].data.run_id | Should -Be 'task:task-301'
        $events[0].data.governance_cost_units[0].unit_type | Should -Be 'governance_invocation'
        $events[0].data.governance_cost_units[0].kind | Should -Be 'consult'
        $events[0].data.governance_cost_units[0].mode | Should -Be 'early'

        $packet = Read-WinsmuxArtifactJson -Reference ([string]$events[0].data.consultation_ref) -ProjectDir $script:consultTempRoot -ExpectedDirectoryPath (Get-ConsultationDirectory -ProjectDir $script:consultTempRoot) -ExpectedRunId 'task:task-301'
        $packet.kind | Should -Be 'consult_request'
        $packet.mode | Should -Be 'early'
        $packet.target_slot | Should -Be 'slot-review-1'
        $packet.request | Should -Be 'sanity-check the current hypothesis'
        $packet.governance_cost_units[0].unit_id | Should -Be $events[0].data.governance_cost_units[0].unit_id
    }

    It 'records a consult result with summary projection fields' {
        $args = Parse-ConsultCommandArgs -Mode 'final' -Args @('--message', 'keep deterministic build command', '--confidence', '0.8', '--next-test', 'rerun build', '--risk', 'cache mismatch')

        $output = Write-ConsultationCommandRecord -Kind 'consult_result' -Mode ([string]$args.mode) -Message ([string]$args.message) -TargetSlot ([string]$args.target_slot) -Confidence $args.confidence -NextTest ([string]$args.next_test) -Risks @($args.risks) -ProjectDir $script:consultTempRoot

        $output | Should -Match 'consult result recorded for task:task-301'
        $events = @(Get-BridgeEventRecords -ProjectDir $script:consultTempRoot)
        $events.Count | Should -Be 1
        $events[0].event | Should -Be 'pane.consult_result'
        $events[0].data.result | Should -Be 'keep deterministic build command'
        $events[0].data.confidence | Should -Be 0.8
        $events[0].data.next_action | Should -Be 'rerun build'
        $events[0].data.cost_unit_refs[0] | Should -Match 'governance:consult:final'
        $events[0].data.cost_unit_refs[0] | Should -Match 'builder-1'
        $events[0].data.governance_cost_units[0].unit_id | Should -Be $events[0].data.cost_unit_refs[0]

        $packet = Read-WinsmuxArtifactJson -Reference ([string]$events[0].data.consultation_ref) -ProjectDir $script:consultTempRoot -ExpectedDirectoryPath (Get-ConsultationDirectory -ProjectDir $script:consultTempRoot) -ExpectedRunId 'task:task-301'
        $packet.kind | Should -Be 'consult_result'
        $packet.mode | Should -Be 'final'
        $packet.recommendation | Should -Be 'keep deterministic build command'
        $packet.next_test | Should -Be 'rerun build'
        $packet.confidence | Should -Be 0.8
        $packet.risks | Should -Be @('cache mismatch')
        $packet.cost_unit_refs[0] | Should -Be $events[0].data.cost_unit_refs[0]
        $packet.governance_cost_units[0].unit_id | Should -Be $events[0].data.cost_unit_refs[0]
    }

    It 'ignores prior events without governance cost units when recording a consult result' {
        Write-BridgeEventRecord -ProjectDir $script:consultTempRoot -EventRecord ([ordered]@{
            timestamp = '2026-04-27T09:00:00.0000000+09:00'
            event     = 'pane.completed'
            message   = 'completed before consult'
            data      = [ordered]@{ task = 'task-301' }
        }) | Out-Null

        $output = Write-ConsultationCommandRecord -Kind 'consult_result' -Mode 'final' -Message 'safe with old events' -ProjectDir $script:consultTempRoot

        $output | Should -Match 'consult result recorded for task:task-301'
        $events = @(Get-BridgeEventRecords -ProjectDir $script:consultTempRoot)
        $events.Count | Should -Be 2
        $events[-1].data.cost_unit_refs[0] | Should -Match 'governance:consult:final'
        $events[-1].data.governance_cost_units[0].unit_id | Should -Be $events[-1].data.cost_unit_refs[0]
    }

    It 'accepts run override and json output for consult result' {
        $args = Parse-ConsultCommandArgs -Mode 'final' -Args @('--run-id', 'task:task-301', '--json', '--message', 'pick builder-1', '--target-slot', 'builder-2', '--next-test', 'promote tactic')

        $args.run_id | Should -Be 'task:task-301'
        $args.json | Should -Be $true

        $output = Write-ConsultationCommandRecord -Kind 'consult_result' -Mode ([string]$args.mode) -Message ([string]$args.message) -TargetSlot ([string]$args.target_slot) -RunId ([string]$args.run_id) -NextTest ([string]$args.next_test) -JsonOutput ([bool]$args.json) -ProjectDir $script:consultTempRoot
        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result.run_id | Should -Be 'task:task-301'
        $result.mode | Should -Be 'final'
        $result.target_slot | Should -Be 'builder-2'
        $result.recommendation | Should -Be 'pick builder-1'
        $result.next_test | Should -Be 'promote tactic'
        $result.consultation_ref | Should -BeLike '.winsmux/consultations/consult-result-*.json'
        $result.cost_unit_refs[0] | Should -Match 'governance:consult:final'
    }

    It 'fails closed for unsupported consult mode' {
        { Parse-ConsultCommandArgs -Mode 'later' -Args @('--message', 'invalid mode test') } | Should -Throw '*Unsupported consult mode*'
    }
}

Describe 'winsmux poll-events command' {
    BeforeEach {
        $script:pollEventsTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-poll-events-tests-' + [guid]::NewGuid().ToString('N'))
        $eventsDir = Join-Path $script:pollEventsTempRoot '.winsmux'
        $script:pollEventsPath = Join-Path $eventsDir 'events.jsonl'
        New-Item -ItemType Directory -Path $eventsDir -Force | Out-Null

        @(
            ([ordered]@{ timestamp = '2026-04-07T09:00:00.0000000+09:00'; event = 'pane.completed'; pane_id = '%2'; label = 'builder-1' } | ConvertTo-Json -Compress),
            ([ordered]@{ timestamp = '2026-04-07T09:00:01.0000000+09:00'; event = 'pane.crashed'; pane_id = '%4'; label = 'reviewer' } | ConvertTo-Json -Compress),
            ([ordered]@{ timestamp = '2026-04-07T09:00:02.0000000+09:00'; event = 'pane.completed'; pane_id = '%5'; label = 'builder-2' } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:pollEventsPath -Encoding UTF8
    }

    AfterEach {
        if ($script:pollEventsTempRoot -and (Test-Path $script:pollEventsTempRoot)) {
            Remove-Item -Path $script:pollEventsTempRoot -Recurse -Force
        }
    }

    It 'returns only events newer than the supplied cursor' {
        $bridgeScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'

        Push-Location $script:pollEventsTempRoot
        try {
            $output = & pwsh -NoProfile -File $bridgeScript poll-events 1
        } finally {
            Pop-Location
        }

        $result = $output | ConvertFrom-Json -AsHashtable

        $result.cursor | Should -Be 3
        $result.events.Count | Should -Be 2
        $result.events[0].event | Should -Be 'pane.crashed'
        $result.events[0].pane_id | Should -Be '%4'
        $result.events[1].event | Should -Be 'pane.completed'
        $result.events[1].pane_id | Should -Be '%5'
    }
}

Describe 'operator-poll helpers' {
    BeforeAll {
        $script:operatorPollScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\operator-poll.ps1'
    }

    BeforeEach {
        $script:operatorPollTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-operator-poll-tests-' + [guid]::NewGuid().ToString('N'))
        $script:operatorPollManifestDir = Join-Path $script:operatorPollTempRoot '.winsmux'
        $script:operatorPollManifestPath = Join-Path $script:operatorPollManifestDir 'manifest.yaml'
        New-Item -ItemType Directory -Path $script:operatorPollManifestDir -Force | Out-Null

@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:operatorPollTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: $script:operatorPollTempRoot
"@ | Set-Content -Path $script:operatorPollManifestPath -Encoding UTF8

        . $script:operatorPollScriptPath -ManifestPath $script:operatorPollManifestPath
    }

    AfterEach {
        if ($script:operatorPollTempRoot -and (Test-Path $script:operatorPollTempRoot)) {
            Remove-Item -Path $script:operatorPollTempRoot -Recurse -Force
        }
    }

    It 'processes mailbox idle messages and logs dispatch-needed guidance' {
        Mock Receive-OperatorPollMailboxMessages {
            @(
                [ordered]@{
                    timestamp   = '2026-04-07T09:00:00.0000000+09:00'
                    session     = 'winsmux-orchestra'
                    event       = 'pane.idle'
                    message     = 'Operator alert: idle pane builder-1 (%2, role=Builder)'
                    label       = 'builder-1'
                    pane_id     = '%2'
                    role        = 'Builder'
                    status      = 'ready'
                    exit_reason = ''
                    data        = [ordered]@{
                        idle_threshold_seconds = 120
                    }
                    source      = 'mailbox'
                }
            )
        }
        Mock Write-OperatorPollLog { }

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
        $summary = $cycle['Summary']

        $summary.mailbox_events | Should -Be 1
        $summary.new_events | Should -Be 1
        $summary.dispatches | Should -Be 1
        $summary.messages[0] | Should -Be 'builder-1 (%2) がアイドル。次タスクのディスパッチが必要'
        Should -Invoke Write-OperatorPollLog -Times 1 -Exactly -ParameterFilter {
            $EventName -eq 'operator.poll.idle_dispatch_needed' -and
            $PaneId -eq '%2' -and
            $Message -eq 'builder-1 (%2) がアイドル。次タスクのディスパッチが必要'
        }
    }

    It 'processes mailbox idle messages when panes are stored in dictionary format' {
        @"
version: 1
saved_at: 2026-04-09T11:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:operatorPollTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    launch_dir: $script:operatorPollTempRoot
"@ | Set-Content -Path $script:operatorPollManifestPath -Encoding UTF8

        Mock Receive-OperatorPollMailboxMessages {
            @(
                [ordered]@{
                    timestamp   = '2026-04-07T09:00:00.0000000+09:00'
                    session     = 'winsmux-orchestra'
                    event       = 'pane.idle'
                    message     = 'Operator alert: idle pane builder-1 (%2, role=Builder)'
                    label       = 'builder-1'
                    pane_id     = '%2'
                    role        = 'Builder'
                    status      = 'ready'
                    exit_reason = ''
                    data        = [ordered]@{
                        idle_threshold_seconds = 120
                    }
                    source      = 'mailbox'
                }
            )
        }
        Mock Write-OperatorPollLog { }

        $cycle = Invoke-OperatorPollCycle -ManifestPath $script:operatorPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
        $summary = $cycle['Summary']

        $summary.mailbox_events | Should -Be 1
        $summary.new_events | Should -Be 1
        $summary.dispatches | Should -Be 1
        $summary.messages[0] | Should -Be 'builder-1 (%2) がアイドル。次タスクのディスパッチが必要'
    }

    It 'prefers a worker as the review target when no reviewer pane exists' {
@"
version: 1
saved_at: 2026-04-09T11:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:operatorPollTempRoot
panes:
  worker-1:
    pane_id: %2
    role: Worker
    launch_dir: $script:operatorPollTempRoot
"@ | Set-Content -Path $script:operatorPollManifestPath -Encoding UTF8

        $manifest = Read-OperatorPollManifest -Path $script:operatorPollManifestPath
        $reviewPane = Get-OperatorPollPreferredReviewPane -Manifest $manifest

        $reviewPane.PaneId | Should -Be '%2'
        $reviewPane.Label | Should -Be 'worker-1'
        $reviewPane.Role | Should -Be 'Worker'
    }

    It 'matches review-state records that use generic review target keys' {
@"
version: 1
saved_at: 2026-04-09T11:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:operatorPollTempRoot
panes:
  worker-1:
    pane_id: %2
    role: Worker
    launch_dir: $script:operatorPollTempRoot
"@ | Set-Content -Path $script:operatorPollManifestPath -Encoding UTF8

        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-state.ps1')

        $reviewState = @{
            'feature/test' = @{
                status = 'PENDING'
                request = @{
                    target_review_label = 'worker-1'
                    target_review_pane_id = '%2'
                }
            }
        }

        $record = Get-OrchestraPaneReviewRecord -ReviewState $reviewState -Branch '' -Label 'worker-1' -PaneId '%2' -Role 'Worker'

        $record.status | Should -Be 'PENDING'
    }

    It 'appends operator poll log records as jsonl' {
        Write-OperatorPollLog -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' -EventName 'operator.poll.idle_dispatch_needed' -Message 'idle' -PaneId '%2'
        Write-OperatorPollLog -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' -EventName 'operator.poll.auto_approved' -Message 'approved' -PaneId '%2'

        $logPath = Get-OperatorPollLogPath -ProjectDir $script:operatorPollTempRoot
        $lines = @(Get-Content -Path $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $lines.Count | Should -Be 2
        ($lines[0] | ConvertFrom-Json).event | Should -Be 'operator.poll.idle_dispatch_needed'
        ($lines[1] | ConvertFrom-Json).event | Should -Be 'operator.poll.auto_approved'
    }

    It 'does not forward operator dispatch-needed alerts to Telegram by default' {
        Mock Test-Path { $true }
        Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
        Mock Invoke-RestMethod { }

        Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
            -Event 'operator.dispatch_needed' -Message 'idle' -PaneId '%2' -Label 'builder-1' -Role 'Builder'

        Should -Not -Invoke Invoke-RestMethod
    }

    It 'does not forward auto-approved alerts to Telegram by default' {
        Mock Test-Path { $true }
        Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
        Mock Invoke-RestMethod { }

        Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
            -Event 'operator.auto_approved' -Message 'approved' -PaneId '%2' -Label 'builder-1' -Role 'Builder'

        Should -Not -Invoke Invoke-RestMethod
    }

    It 'sends external review-requested alerts to Telegram by default' {
        Mock Test-Path { $true }
        Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
        Mock Invoke-RestMethod { }

        Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
            -Event 'operator.review_requested' -Message 'review requested' -PaneId '%4' -Label 'worker-1' -Role 'Worker'

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'sends commit-ready alerts to Telegram by default' {
        Mock Test-Path { $true }
        Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
        Mock Invoke-RestMethod { }

        Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
            -Event 'operator.commit_ready' -Message 'ready to commit' -HeadSha 'abc1234def5678'

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'allows all operator Telegram alerts when verbose profile is enabled' {
        $previousProfile = $env:WINSMUX_TELEGRAM_PROFILE
        $env:WINSMUX_TELEGRAM_PROFILE = 'verbose'

        try {
            Mock Test-Path { $true }
            Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
            Mock Invoke-RestMethod { }

            Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
                -Event 'operator.dispatch_needed' -Message 'idle' -PaneId '%2' -Label 'builder-1' -Role 'Builder'

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        } finally {
            if ($null -eq $previousProfile) {
                Remove-Item Env:WINSMUX_TELEGRAM_PROFILE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_TELEGRAM_PROFILE = $previousProfile
            }
        }
    }

    It 'suppresses all Telegram alerts when profile is none' {
        $previousProfile = $env:WINSMUX_TELEGRAM_PROFILE
        $env:WINSMUX_TELEGRAM_PROFILE = 'none'

        try {
            Mock Test-Path { $true }
            Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
            Mock Invoke-RestMethod { }

            Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
                -Event 'operator.review_failed' -Message 'review failed' -HeadSha 'abc1234def5678'

            Should -Not -Invoke Invoke-RestMethod
        } finally {
            if ($null -eq $previousProfile) {
                Remove-Item Env:WINSMUX_TELEGRAM_PROFILE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_TELEGRAM_PROFILE = $previousProfile
            }
        }
    }

    It 'allows internal operator Telegram alerts only when explicitly overridden' {
        $previousOverride = $env:WINSMUX_TELEGRAM_INCLUDE_INTERNAL_EVENTS
        $env:WINSMUX_TELEGRAM_INCLUDE_INTERNAL_EVENTS = 'true'

        try {
            Mock Test-Path { $true }
            Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
            Mock Invoke-RestMethod { }

            Send-OperatorTelegramNotification -ProjectDir $script:operatorPollTempRoot -SessionName 'winsmux-orchestra' `
                -Event 'operator.dispatch_needed' -Message 'idle' -PaneId '%2' -Label 'builder-1' -Role 'Builder'

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        } finally {
            if ($null -eq $previousOverride) {
                Remove-Item Env:WINSMUX_TELEGRAM_INCLUDE_INTERNAL_EVENTS -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_TELEGRAM_INCLUDE_INTERNAL_EVENTS = $previousOverride
            }
        }
    }

    It 'dispatches review requests through operator poll wrappers' {
@"
version: 1
saved_at: 2026-04-12T10:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:operatorPollTempRoot
panes:
  reviewer-1:
    pane_id: %4
    role: Reviewer
    launch_dir: $script:operatorPollTempRoot
"@ | Set-Content -Path $script:operatorPollManifestPath -Encoding UTF8

        Mock Send-OperatorPollLiteral { }
        Mock Approve-OperatorPollPane { }
        Mock Send-OperatorTelegramNotification { }

        $result = Invoke-OperatorStateMachine `
            -CurrentState 'waiting_for_review' `
            -CycleSummary @{ completions = 1 } `
            -ProjectDir $script:operatorPollTempRoot `
            -SessionName 'winsmux-orchestra' `
            -ManifestPath $script:operatorPollManifestPath

        $result.State | Should -Be 'review_requested'
        Should -Invoke Send-OperatorPollLiteral -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%4' -and $Text -eq 'winsmux review-request'
        }
        Should -Invoke Approve-OperatorPollPane -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%4'
        }
    }

    It 'stops at the draft PR gate after review passed' {
        Mock Send-OperatorTelegramNotification { }

        $result = Invoke-OperatorStateMachine `
            -CurrentState 'review_passed' `
            -CycleSummary @{ completions = 0 } `
            -ProjectDir $script:operatorPollTempRoot `
            -SessionName 'winsmux-orchestra' `
            -ManifestPath $script:operatorPollManifestPath

        $result.State | Should -Be 'blocked_draft_pr_required'
        $result.CommitReadySha | Should -Be ''

        $eventsPath = Join-Path $script:operatorPollManifestDir 'events.jsonl'
        $events = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        @($events | ForEach-Object { $_['event'] }) | Should -Contain 'operator.draft_pr.required'
        $draftEvent = @($events | Where-Object { $_['event'] -eq 'operator.draft_pr.required' })[0]
        $draftEvent['status'] | Should -Be 'blocked_draft_pr_required'
        $draftEvent['data']['human_merge_required'] | Should -Be $true
        $draftEvent['data']['auto_merge_allowed'] | Should -Be $false
        @($events | ForEach-Object { $_['event'] }) | Should -Not -Contain 'operator.commit_ready'

        Should -Invoke Send-OperatorTelegramNotification -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'operator.draft_pr.required'
        }
    }

    It 'ignores draft PR events without a matching head sha' {
        $eventsPath = Join-Path $script:operatorPollManifestDir 'events.jsonl'
        @(
            ([ordered]@{
                timestamp = '2026-04-12T10:00:00+09:00'
                event     = 'operator.draft_pr.created'
                head_sha  = ''
                data      = [ordered]@{ target = 'draft_pr'; draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/900' }
            } | ConvertTo-Json -Compress -Depth 10),
            ([ordered]@{
                timestamp = '2026-04-12T10:01:00+09:00'
                event     = 'operator.draft_pr.created'
                head_sha  = 'old-sha'
                data      = [ordered]@{ target = 'draft_pr'; draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/901' }
            } | ConvertTo-Json -Compress -Depth 10)
        ) | Set-Content -Path $eventsPath -Encoding UTF8

        Test-OperatorDraftPrCreated -ProjectDir $script:operatorPollTempRoot -HeadSha 'current-sha' | Should -Be $false
    }

    It 'resumes from the draft PR gate when matching draft PR evidence appears' {
        Mock git { 'abc123' }
        Mock Send-OperatorTelegramNotification { }

        $eventsPath = Join-Path $script:operatorPollManifestDir 'events.jsonl'
        ([ordered]@{
            timestamp = '2026-04-12T10:02:00+09:00'
            event     = 'operator.draft_pr.created'
            head_sha  = 'abc123'
            data      = [ordered]@{ target = 'draft_pr'; draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/902' }
        } | ConvertTo-Json -Compress -Depth 10) | Set-Content -Path $eventsPath -Encoding UTF8

        $result = Invoke-OperatorStateMachine `
            -CurrentState 'blocked_draft_pr_required' `
            -CycleSummary @{ completions = 0 } `
            -ProjectDir $script:operatorPollTempRoot `
            -SessionName 'winsmux-orchestra' `
            -ManifestPath $script:operatorPollManifestPath

        $result.State | Should -Be 'commit_ready'
        $result.CommitReadySha | Should -Be 'abc123'
        Should -Invoke Send-OperatorTelegramNotification -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'operator.commit_ready' -and $HeadSha -eq 'abc123'
        }
    }
}

Describe 'winsmux control-rpc command' {
    BeforeAll {
        $script:controlRpcBridgePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $script:controlRpcBridgeContent = Get-Content -Raw -Path $script:controlRpcBridgePath -Encoding UTF8
        $null = . $script:controlRpcBridgePath version
    }

    It 'documents control-rpc in usage and fixes the named pipe endpoint' {
        $script:controlRpcBridgeContent | Should -Match 'control-rpc <json>'
        $script:controlRpcBridgeContent | Should -Match "'control-rpc'\s*\{\s*Invoke-ControlRpc\s*\}"
        $script:controlRpcBridgeContent | Should -Match '\$client\.ReadAsync\(\$buffer, 0, \$buffer\.Length\)'
        $script:controlRpcBridgeContent | Should -Match 'timed out waiting for response'
        Get-ControlRpcPipeName | Should -Be 'winsmux-control'
        Get-ControlRpcPipeDisplayName | Should -Be '\\.\pipe\winsmux-control'
    }

    It 'normalizes JSON-RPC requests before sending them to the control pipe' {
        Mock Invoke-ControlRpcPipeExchange {
            param([string]$Payload)
            $script:controlRpcPayload = $Payload
            return '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}'
        }

        $script:controlRpcPayload = ''
        $output = Invoke-ControlRpc `
            -ControlTarget '{"jsonrpc":"2.0","id":1,' `
            -ControlRest @('"method":"desktop.control_plane.contract"}')

        Should -Invoke Invoke-ControlRpcPipeExchange -Times 1 -Exactly
        $script:controlRpcPayload | Should -Be '{"jsonrpc":"2.0","id":1,"method":"desktop.control_plane.contract"}'
        $output | Should -Be '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}'
    }

    It 'rejects missing JSON-RPC payloads' {
        { ConvertTo-ControlRpcPayload -JsonText '' } | Should -Throw 'usage: winsmux control-rpc <json>'
    }

    It 'rejects invalid JSON payloads' {
        { ConvertTo-ControlRpcPayload -JsonText '{' } | Should -Throw 'control-rpc payload must be valid JSON:*'
    }

    It 'rejects non JSON-RPC 2.0 payloads' {
        { ConvertTo-ControlRpcPayload -JsonText '{"jsonrpc":"1.0","method":"desktop.summary.snapshot"}' } |
            Should -Throw 'control-rpc payload must be a JSON-RPC 2.0 request'
    }

    It 'rejects JSON-RPC requests without a method' {
        { ConvertTo-ControlRpcPayload -JsonText '{"jsonrpc":"2.0","id":1}' } |
            Should -Throw 'control-rpc payload must include a non-empty method'
    }
}

Describe 'winsmux terminal backend switch' {
    BeforeAll {
        $bridgePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $null = . $bridgePath version
    }

    BeforeEach {
        $script:previousWinsmuxBackend = $env:WINSMUX_BACKEND
        Remove-Item Env:\WINSMUX_BACKEND -ErrorAction SilentlyContinue
        $script:terminalRpcPayloads = [System.Collections.Generic.List[string]]::new()
    }

    AfterEach {
        if ($null -eq $script:previousWinsmuxBackend) {
            Remove-Item Env:\WINSMUX_BACKEND -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_BACKEND = $script:previousWinsmuxBackend
        }
    }

    It 'defaults terminal operations to the CLI backend and accepts Tauri aliases' {
        Resolve-TerminalBackend | Should -Be 'cli'

        $env:WINSMUX_BACKEND = 'desktop'
        Resolve-TerminalBackend | Should -Be 'tauri'

        $env:WINSMUX_BACKEND = 'winsmux'
        Resolve-TerminalBackend | Should -Be 'cli'
    }

    It 'rejects unsupported terminal backend values' {
        $env:WINSMUX_BACKEND = 'remote'

        { Resolve-TerminalBackend } | Should -Throw "*WINSMUX_BACKEND must be cli or tauri*"
    }

    It 'captures pane text through the Tauri pty JSON-RPC path' {
        Mock Invoke-ControlRpcPipeExchange {
            param([string]$Payload)
            $script:terminalRpcPayloads.Add($Payload) | Out-Null
            return '{"jsonrpc":"2.0","id":"terminal-test","result":{"paneId":"pane-1","output":"ready"}}'
        }

        $env:WINSMUX_BACKEND = 'tauri'
        $output = Get-PaneSnapshotText -PaneId 'pane-1' -Lines 25

        $output | Should -Be 'ready'
        Should -Invoke Invoke-ControlRpcPipeExchange -Times 1 -Exactly
        $request = $script:terminalRpcPayloads[0] | ConvertFrom-Json
        $request.method | Should -Be 'pty.capture'
        $request.params.paneId | Should -Be 'pane-1'
        $request.params.lines | Should -Be 25
    }

    It 'writes literal text and Enter through the Tauri pty JSON-RPC path' {
        Mock Invoke-ControlRpcPipeExchange {
            param([string]$Payload)
            $script:terminalRpcPayloads.Add($Payload) | Out-Null
            return '{"jsonrpc":"2.0","id":"terminal-test","result":{"paneId":"pane-1"}}'
        }

        $env:WINSMUX_BACKEND = 'tauri'
        $literal = Invoke-WinsmuxSendKeys -Target 'pane-1' -Keys @('echo test') -Literal
        $enter = Invoke-WinsmuxSendKeys -Target 'pane-1' -Keys @('Enter')

        $literal.ExitCode | Should -Be 0
        $enter.ExitCode | Should -Be 0
        Should -Invoke Invoke-ControlRpcPipeExchange -Times 2 -Exactly
        $literalRequest = $script:terminalRpcPayloads[0] | ConvertFrom-Json
        $enterRequest = $script:terminalRpcPayloads[1] | ConvertFrom-Json
        $literalRequest.method | Should -Be 'pty.write'
        $literalRequest.params.data | Should -Be 'echo test'
        $enterRequest.method | Should -Be 'pty.write'
        $enterRequest.params.data | Should -Be "`r"
    }

    It 'sends text through one Tauri pane target without CLI fallback resolution' {
        Mock Start-Sleep { }
        Mock Save-Watermark { }
        Mock Set-ReadMark { }
        Mock Invoke-WinsmuxRaw { throw "CLI backend should not be called: $($Arguments -join ' ')" }
        Mock Invoke-ControlRpcPipeExchange {
            param([string]$Payload)
            $script:terminalRpcPayloads.Add($Payload) | Out-Null
            $request = $Payload | ConvertFrom-Json
            if ($request.method -eq 'pty.write') {
                if ($request.params.data -eq "`r") {
                    $script:terminalPaneText = "> echo test`nresult"
                } else {
                    $script:terminalPaneText = "> $($request.params.data)"
                }
                return '{"jsonrpc":"2.0","id":"terminal-test","result":{"paneId":"pane-1"}}'
            }

            $escaped = ([string]$script:terminalPaneText | ConvertTo-Json -Compress)
            return '{"jsonrpc":"2.0","id":"terminal-test","result":{"paneId":"pane-1","output":' + $escaped + '}}'
        }

        $env:WINSMUX_BACKEND = 'tauri'
        $script:terminalPaneText = '> '
        $result = Send-TextToPane -PaneId 'pane-1' -CommandText 'echo test'

        $result | Should -Be 'sent to pane-1 via pane-1'
        $writes = @($script:terminalRpcPayloads |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.method -eq 'pty.write' })
        $writes.Count | Should -Be 2
        $writes[0].params.data | Should -Be 'echo test'
        $writes[1].params.data | Should -Be "`r"
    }
}

Describe 'winsmux send fallback' {
    BeforeAll {
        $bridgePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $null = . $bridgePath version
    }

    BeforeEach {
        $script:sendBuffer = ''
        $script:sendAttempts = [System.Collections.Generic.List[string]]::new()

        Mock Start-Sleep { }
        Mock Save-Watermark { }
        Mock Set-ReadMark { }
        Mock Invoke-WinsmuxRaw {
            param([string[]]$Arguments)

            $command = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }
            $global:LASTEXITCODE = 0

            switch ($command) {
                'list-panes' {
                    $format = $Arguments[-1]
                    if ($format -eq '#{pane_id}') {
                        return '%7'
                    }

                    if ($format -eq "#{pane_id}`t#{session_name}:#{window_index}.#{pane_index}") {
                        return '%7' + "`t" + 'default:0.3'
                    }

                    return @()
                }
                'capture-pane' {
                    return $script:sendBuffer
                }
                'send-keys' {
                    $targetIndex = [Array]::IndexOf($Arguments, '-t')
                    $target = if ($targetIndex -ge 0 -and $targetIndex + 1 -lt $Arguments.Count) {
                        $Arguments[$targetIndex + 1]
                    } else {
                        ''
                    }

                    if ($Arguments -contains '-l') {
                        $script:sendAttempts.Add("$target literal") | Out-Null
                        if ($target -eq 'default:0.3') {
                            $script:sendBuffer = '> echo test'
                        }

                        return
                    }

                    $script:sendAttempts.Add("$target Enter") | Out-Null
                    if ($target -eq 'default:0.3') {
                        $script:sendBuffer = "> echo test`nresult"
                    }
                    return
                }
                default {
                    throw "Unexpected winsmux command: $($Arguments -join ' ')"
                }
            }
        }
    }

    It 'adds a coordinate target as a fallback candidate for a pane id' {
        $candidates = @(Get-PaneTargetCandidates -PaneId '%7')

        $candidates | Should -Be @('%7', 'default:0.3')
    }

    It 'falls back to pane coordinates when direct pane id delivery leaves the buffer unchanged' {
        $result = Send-TextToPane -PaneId '%7' -CommandText 'echo test'

        $result | Should -Be 'sent to %7 via default:0.3'
        $script:sendBuffer | Should -Be "> echo test`nresult"
        $script:sendAttempts | Should -Be @('%7 literal', 'default:0.3 literal', 'default:0.3 Enter')
    }

    It 'falls back when direct pane id delivery redraws the buffer but does not contain the typed command' {
        $script:sendAttempts = [System.Collections.Generic.List[string]]::new()
        $script:sendBuffer = '> '
        $script:sendCommandText = 'claude research --topic winsmux'

        Mock Invoke-WinsmuxRaw {
            param([string[]]$Arguments)

            switch ($Arguments[0]) {
                'list-panes' {
                    $format = $Arguments[-1]
                    if ($format -eq '#{pane_id}') {
                        return '%7'
                    }

                    if ($format -eq "#{pane_id}`t#{session_name}:#{window_index}.#{pane_index}") {
                        return '%7' + "`t" + 'default:0.3'
                    }

                    return @()
                }
                'capture-pane' {
                    return $script:sendBuffer
                }
                'send-keys' {
                    $targetIndex = [Array]::IndexOf($Arguments, '-t')
                    $target = if ($targetIndex -ge 0 -and $targetIndex + 1 -lt $Arguments.Count) {
                        $Arguments[$targetIndex + 1]
                    } else {
                        ''
                    }

                    if ($Arguments -contains '-l') {
                        $script:sendAttempts.Add("$target literal") | Out-Null
                        if ($target -eq '%7') {
                            $script:sendBuffer = "> [status redraw only]"
                        } elseif ($target -eq 'default:0.3') {
                            $script:sendBuffer = "> $script:sendCommandText"
                        }

                        return
                    }

                    $script:sendAttempts.Add("$target Enter") | Out-Null
                    if ($target -eq 'default:0.3') {
                        $script:sendBuffer += "`nresult"
                    }
                    return
                }
                default {
                    throw "Unexpected winsmux command: $($Arguments -join ' ')"
                }
            }
        }

        $result = Send-TextToPane -PaneId '%7' -CommandText $script:sendCommandText

        $result | Should -Be 'sent to %7 via default:0.3'
        $script:sendBuffer | Should -Be "> $script:sendCommandText`nresult"
        $script:sendAttempts | Should -Be @('%7 literal', 'default:0.3 literal', 'default:0.3 Enter')
    }

    It 'chunks long literal sends before pressing Enter' {
        $script:sendAttempts = [System.Collections.Generic.List[string]]::new()
        $script:sendBuffer = '> '
        $script:longCommandText = ('a' * 1200) + 'UNIQUE-TAIL-1234567890'

        Mock Invoke-WinsmuxRaw {
            param([string[]]$Arguments)

            switch ($Arguments[0]) {
                'list-panes' {
                    $format = $Arguments[-1]
                    if ($format -eq '#{pane_id}') {
                        return '%7'
                    }

                    if ($format -eq "#{pane_id}`t#{session_name}:#{window_index}.#{pane_index}") {
                        return '%7' + "`t" + 'default:0.3'
                    }

                    return @()
                }
                'capture-pane' {
                    return $script:sendBuffer
                }
                'send-keys' {
                    $targetIndex = [Array]::IndexOf($Arguments, '-t')
                    $target = if ($targetIndex -ge 0 -and $targetIndex + 1 -lt $Arguments.Count) {
                        $Arguments[$targetIndex + 1]
                    } else {
                        ''
                    }

                    if ($Arguments -contains '-l') {
                        $literalText = $Arguments[-1]
                        $script:sendAttempts.Add("$target literal:$($literalText.Length)") | Out-Null
                        if ($target -eq 'default:0.3') {
                            $script:sendBuffer += $literalText
                        }

                        return
                    }

                    $script:sendAttempts.Add("$target Enter") | Out-Null
                    if ($target -eq 'default:0.3') {
                        $script:sendBuffer += "`nresult"
                    }
                    return
                }
                default {
                    throw "Unexpected winsmux command: $($Arguments -join ' ')"
                }
            }
        }

        $result = Send-TextToPane -PaneId '%7' -CommandText $script:longCommandText

        $result | Should -Be 'sent to %7 via default:0.3'
        (@($script:sendAttempts | Where-Object { $_ -like '* literal*' })).Count | Should -Be 4
        $script:sendAttempts[-1] | Should -Be 'default:0.3 Enter'
    }

    It 'uses send-paste when prompt_transport is stdin' {
        $script:sendAttempts = [System.Collections.Generic.List[string]]::new()
        $script:sendBuffer = '> '
        $script:sendCommandText = "line 1`nline 2"

        Mock Invoke-WinsmuxRaw {
            param([string[]]$Arguments)

            switch ($Arguments[0]) {
                'list-panes' {
                    $format = $Arguments[-1]
                    if ($format -eq '#{pane_id}') {
                        return '%7'
                    }

                    if ($format -eq "#{pane_id}`t#{session_name}:#{window_index}.#{pane_index}") {
                        return '%7' + "`t" + 'default:0.3'
                    }

                    return @()
                }
                'capture-pane' {
                    return $script:sendBuffer
                }
                'send-paste' {
                    $targetIndex = [Array]::IndexOf($Arguments, '-t')
                    $target = if ($targetIndex -ge 0 -and $targetIndex + 1 -lt $Arguments.Count) {
                        $Arguments[$targetIndex + 1]
                    } else {
                        ''
                    }

                    $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Arguments[-1]))
                    $script:sendAttempts.Add("$target paste") | Out-Null
                    if ($target -eq 'default:0.3') {
                        $script:sendBuffer = "> $decoded"
                    }
                    return
                }
                'send-keys' {
                    $targetIndex = [Array]::IndexOf($Arguments, '-t')
                    $target = if ($targetIndex -ge 0 -and $targetIndex + 1 -lt $Arguments.Count) {
                        $Arguments[$targetIndex + 1]
                    } else {
                        ''
                    }

                    $script:sendAttempts.Add("$target Enter") | Out-Null
                    if ($target -eq 'default:0.3') {
                        $script:sendBuffer += "`nresult"
                    }
                    return
                }
                default {
                    throw "Unexpected winsmux command: $($Arguments -join ' ')"
                }
            }
        }

        $result = Send-TextToPane -PaneId '%7' -CommandText $script:sendCommandText -PromptTransport 'stdin'

        $result | Should -Be 'sent to %7 via default:0.3'
        $script:sendBuffer | Should -Be "> $script:sendCommandText`nresult"
        $script:sendAttempts | Should -Be @('%7 paste', 'default:0.3 paste', 'default:0.3 Enter')
    }

}

Describe 'watermark helpers' {
    BeforeAll {
        $bridgePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
        $null = . $bridgePath version
    }

    BeforeEach {
        $script:watermarkTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-watermark-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:watermarkTempRoot -Force | Out-Null
        $WatermarkDir = $script:watermarkTempRoot
    }

    AfterEach {
        if ($script:watermarkTempRoot -and (Test-Path $script:watermarkTempRoot)) {
            Remove-Item -Path $script:watermarkTempRoot -Recurse -Force
        }
    }

    It 'writes and reuses watermark hashes via the CLM-safe helper' {
        Save-Watermark -PaneId '%7' -Content 'hello'

        $path = Get-WatermarkPath -PaneId '%7'
        $savedHash = Get-Content -Path $path -Raw -Encoding UTF8

        Test-Path $path | Should -Be $true
        $savedHash | Should -Not -BeNullOrEmpty
        (Test-WatermarkChanged -PaneId '%7' -CurrentContent 'hello') | Should -Be $false
        (Test-WatermarkChanged -PaneId '%7' -CurrentContent 'updated') | Should -Be $true
    }
}
