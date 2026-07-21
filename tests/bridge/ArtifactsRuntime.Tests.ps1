$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'operator startup restore contract docs' {
    BeforeAll {
        $script:claudeGuidePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) '.claude\CLAUDE.md'
        $script:claudeGuideContent = Get-Content -Path $script:claudeGuidePath -Raw -Encoding UTF8
        $script:dispatchRulePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) '.claude\rules\dispatch.md'
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
        $settingsPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\settings.ps1'
        $setupWizardPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\setup-wizard.ps1'
        $operatorPollPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\operator-poll.ps1'
        $agentMonitorPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\agent-monitor.ps1'
        $watchdogPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\server-watchdog.ps1'
        $orchestraStartPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-start.ps1'

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
        $setupWizardContent | Should -Match "(?s)if \(\[string\]::IsNullOrWhiteSpace\(\`$model\)\) \{\s*Clear-WinsmuxOption -WinsmuxBin \`$winsmuxBin -OptionName '@bridge-model'\s*\} else \{\s*Set-WinsmuxOption -WinsmuxBin \`$winsmuxBin -OptionName '@bridge-model' -OptionValue \`$model"
        $setupWizardContent | Should -Match 'vault set GH_TOKEN'
        $setupWizardContent | Should -Not -Match 'vault set GH_TOKEN\s+\$plainToken'
        $setupWizardContent | Should -Not -Match 'ConvertTo-PlainText'
        $setupWizardContent | Should -Not -Match 'Read-Host -AsSecureString "Enter GH_TOKEN"'
        $setupWizardContent | Should -Not -Match 'AI agent CLI \(codex/claude\)'
        $setupWizardContent | Should -Not -Match "Please enter 'codex' or 'claude'\."
        $setupWizardContent | Should -Not -Match 'Tried: winsmux, pmux, tmux'
        $operatorPollContent | Should -Not -Match 'Tried: winsmux, pmux, tmux'
        $agentMonitorContent | Should -Not -Match 'Tried: winsmux, pmux, tmux'
        $watchdogContent | Should -Not -Match 'Tried: winsmux, pmux, tmux'
        $orchestraStartContent | Should -Not -Match 'Tried: winsmux, pmux, tmux'
    }

    It 'clears stale setup wizard model overrides when provider default is selected' {
        $setupWizardPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\setup-wizard.ps1'
        $setupWizardContent = Get-Content -Path $setupWizardPath -Raw -Encoding UTF8

        $setupWizardContent | Should -Match 'function Clear-WinsmuxOption'
        $setupWizardContent | Should -Match 'set-option -gu \$OptionName'
        $setupWizardContent | Should -Match "(?s)if \(\[string\]::IsNullOrWhiteSpace\(\`$model\)\) \{\s*Clear-WinsmuxOption -WinsmuxBin \`$winsmuxBin -OptionName '@bridge-model'"
    }

    It 'keeps the legacy orchestra prompt provider-neutral' {
        $legacyStartPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\start-orchestra.ps1'
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
        $script:orchestraStartPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-start.ps1'
        $script:orchestraStartContent = Get-Content -Path $script:orchestraStartPath -Raw -Encoding UTF8
        $script:orchestraPaneBootstrapPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-pane-bootstrap.ps1'
        $script:orchestraPaneBootstrapContent = Get-Content -Path $script:orchestraPaneBootstrapPath -Raw -Encoding UTF8
    }

    It 'uses a plan file driven pane bootstrap instead of sending many environment commands directly' {
        $script:orchestraStartContent | Should -Match 'function New-OrchestraPaneBootstrapPlan'
        $script:orchestraStartContent | Should -Match 'function Get-OrchestraPaneBootstrapMarkerPath'
        $script:orchestraStartContent | Should -Match 'function Start-OrchestraPaneBootstrap'
        $script:orchestraStartContent | Should -Match 'function Test-OrchestraPaneDeferredStart'
        $script:orchestraStartContent | Should -Match 'function Wait-OrchestraServerSessionAbsent'
        $script:orchestraStartContent | Should -Match 'orchestra-pane-bootstrap\.ps1'
        $script:orchestraStartContent | Should -Match 'Start-OrchestraPaneBootstrap -PaneId \$paneId -PlanPath \$bootstrapPlanPath -SessionName \$sessionName'
        $script:orchestraStartContent | Should -Match 'deferred_start'
        $script:orchestraStartContent | Should -Match 'preflight\.worker\.deferred_start'
        $script:orchestraStartContent | Should -Match 'ready_marker_path'
        $script:orchestraStartContent | Should -Match 'function New-OrchestraWorkerLaunchApproval'
        $script:orchestraStartContent | Should -Match 'approved_launch'
        $script:orchestraStartContent | Should -Match 'Wait-OrchestraServerSessionAbsent -SessionName \$SessionName -TimeoutSeconds 20'
    }

    It 'passes the project root into slot provider resolution' {
        $script:orchestraStartContent | Should -Match 'Get-SlotAgentConfig -Role \$canonicalRole -SlotId \$label -Settings \$settings -RootPath \$projectDir'
    }

    It 'builds pane launch commands through provider capability metadata' {
        $script:orchestraStartContent | Should -Match 'Get-BridgeProviderLaunchCommand'
        $script:orchestraStartContent | Should -Match 'Get-AgentLaunchCommand -Agent \$slotAgentConfig\.Agent -Model \$slotAgentConfig\.Model -ModelSource \$slotAgentConfig\.ModelSource -ReasoningEffort \$slotAgentConfig\.ReasoningEffort -McpMode \$slotAgentConfig\.McpMode -SlotId \$label -ProjectDir \$launchDir -GitWorktreeDir \$launchGitWorktreeDir -RootPath \$projectDir'
    }

    It 'defers one-shot workers before resolving provider launch commands' {
        $apiLlmDeferIndex = $script:orchestraStartContent.IndexOf('$apiLlmPaneStartDeferred = [string]::Equals(([string]$slotAgentConfig.WorkerBackend), ''api_llm''')
        $antigravityDeferIndex = $script:orchestraStartContent.IndexOf('$antigravityPaneStartDeferred = [string]::Equals(([string]$slotAgentConfig.WorkerBackend), ''antigravity''')
        $providerLaunchIndex = $script:orchestraStartContent.IndexOf('$launchCommand = Get-AgentLaunchCommand')

        $apiLlmDeferIndex | Should -BeGreaterThan -1
        $antigravityDeferIndex | Should -BeGreaterThan -1
        $providerLaunchIndex | Should -BeGreaterThan $apiLlmDeferIndex
        $providerLaunchIndex | Should -BeGreaterThan $antigravityDeferIndex
        $script:orchestraStartContent | Should -Match 'if \(-not \$oneShotPaneStartDeferred\) \{'
        $script:orchestraStartContent | Should -Match "\$deferredPaneStatus = 'api_llm_runner_unconfigured'"
        $script:orchestraStartContent | Should -Match 'preflight\.worker\.api_llm_runner_unconfigured'
        $script:orchestraStartContent | Should -Match "\$deferredPaneStatus = 'antigravity_runner_unconfigured'"
        $script:orchestraStartContent | Should -Match 'preflight\.worker\.antigravity_runner_unconfigured'
    }

    It 'prints a concise startup summary before invoking the agent launch command' {
        $script:orchestraPaneBootstrapContent | Should -Match '\[winsmux\] pane bootstrap:'
        $script:orchestraPaneBootstrapContent | Should -Match 'launch_command'
        $script:orchestraPaneBootstrapContent | Should -Match 'Invoke-Expression \$launchCommand'
    }

    It 'TASK781 clean-imports pane bootstrap and writes process identity with <HostName>' -ForEach @(
        @{ HostName = 'pwsh' }
        @{ HostName = 'powershell.exe' }
    ) {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('winsmux-task781-bootstrap-' + [guid]::NewGuid().ToString('N'))
        $planPath = Join-Path $root 'plan.json'
        $markerPath = Join-Path $root 'worker-1.ready.json'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            $plan = [ordered]@{
                launch_dir       = $root
                launch_command   = "[Console]::WriteLine('bootstrap-launch-ok')"
                ready_marker_path = $markerPath
                generation_id    = 'generation-bootstrap-clean-import'
                server_session_id = '$99'
                slot_id          = 'worker-1'
                pane_id          = '%2'
                worker_backend   = 'codex'
                worker_role      = 'reviewer'
                pane_title       = 'W1 Codex Reviewer'
                role             = 'Reviewer'
                label            = 'worker-1'
                model            = 'gpt-5'
                environment      = [ordered]@{}
            }
            [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

            $output = @(& $HostName -NoProfile -File $script:orchestraPaneBootstrapPath -PlanFile $planPath 2>&1 |
                ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE

            $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
            Test-Path -LiteralPath $markerPath -PathType Leaf | Should -BeTrue
            $markerJson = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8
            $marker = $markerJson | ConvertFrom-Json -Depth 8
            [int]$marker.bootstrap_pid | Should -BeGreaterThan 0
            [string]$marker.bootstrap_process_started_at | Should -Not -BeNullOrEmpty
            $startedAtMatch = [regex]::Match(
                $markerJson,
                '"bootstrap_process_started_at"\s*:\s*"(?<value>[^"]+)"'
            )
            $startedAtMatch.Success | Should -BeTrue
            $startedAt = [DateTimeOffset]::MinValue
            [DateTimeOffset]::TryParseExact(
                $startedAtMatch.Groups['value'].Value,
                'o',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$startedAt
            ) | Should -BeTrue
            $output | Should -Contain 'bootstrap-launch-ok'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'TASK-278 golden corpus fixtures' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
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
    capability_adapter: codex
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
    capability_adapter: codex
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
                } | ConvertTo-Json -Compress),
                ([ordered]@{
                    timestamp = '2026-04-10T12:03:00+09:00'
                    session   = 'winsmux-orchestra'
                    event     = 'pipeline.tdd.red'
                    message   = 'test failed before implementation'
                    label     = 'operator'
                    pane_id   = ''
                    role      = 'Operator'
                    branch    = 'worktree-builder-1'
                    head_sha  = 'abc1234def5678'
                    data      = [ordered]@{
                        task_id   = 'task-256'
                        run_id    = 'task:task-256'
                        tdd_phase = 'red'
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
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
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
                timestamp = '2026-04-12T10:00:30+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.mailbox.message_received'
                message   = 'compare winner memory reference captured'
                label     = 'operator'
                pane_id   = ''
                role      = 'Operator'
                source    = 'mailbox'
                branch    = 'worktree-builder-a'
                head_sha  = 'aaaabbbbccccdddd'
                data      = [ordered]@{
                    task_id          = 'task-compare-a'
                    run_id           = 'task:task-compare-a'
                    source           = 'mailbox'
                    team_memory_refs = @('team-memory:task-compare-a:operator-standard')
                }
            } | ConvertTo-Json -Compress -Depth 8),
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
        $result.recommend.playbook_template.packet_type | Should -Be 'playbook_template_contract'
        $result.recommend.playbook_template.flow | Should -Be 'compare_winner_follow_up'
        $result.recommend.playbook_template.source_run_id | Should -Be 'task:task-compare-a'
        $result.recommend.playbook_template.required_evidence | Should -Be @('winning_run', 'comparison_evidence', 'promotion_candidate')
        $result.recommend.playbook_template.team_memory_refs | Should -Contain 'team-memory:task-compare-a:operator-standard'
        $result.recommend.playbook_template.execution_backend | Should -Be 'operator_managed'
        $result.recommend.playbook_template.backend_profile_required | Should -Be $false
        $result.recommend.playbook_template.approval_defaults.review_required | Should -Be $true
        $result.recommend.playbook_template.approval_defaults.human_approval_required | Should -Be $true
        $result.recommend.playbook_template.approval_defaults.auto_merge_allowed | Should -Be $false
        $result.recommend.playbook_template.freeform_body_stored | Should -Be $false
        $result.recommend.playbook_template.private_guidance_stored | Should -Be $false
        $result.recommend.playbook_template.PSObject.Properties.Name | Should -Not -Contain 'freeform_body'
        $result.recommend.playbook_template.PSObject.Properties.Name | Should -Not -Contain 'private_guidance'
        $result.recommend.follow_up_run.packet_type | Should -Be 'managed_follow_up_run_contract'
        $result.recommend.follow_up_run.source_run_id | Should -Be 'task:task-compare-a'
        $result.recommend.follow_up_run.run_mode | Should -Be 'operator_managed'
        $result.recommend.follow_up_run.playbook_template_ref | Should -Be 'playbook:compare_winner_follow_up'
        $result.recommend.follow_up_run.required_evidence | Should -Be @('winning_run', 'comparison_evidence', 'promotion_candidate')
        $result.recommend.follow_up_run.changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $unsafeFollowUp = New-CompareWinnerFollowUpRunContract `
            -Run ([pscustomobject]@{
                run_id = 'task:task-compare-a'
                task_id = 'task-compare-a'
                experiment_packet = [pscustomobject]@{
                    observation_pack_ref = $script:compareObsA.reference
                    consultation_ref = $script:compareConsultA.reference
                }
            }) `
            -EvidenceDigest ([pscustomobject]@{ changed_files = @('scripts/winsmux-core.ps1', 'C:\Users\Example\secret.txt', '../private.md') }) `
            -PlaybookTemplate $result.recommend.playbook_template
        $unsafeFollowUp.changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $result.recommend.follow_up_run.source_evidence_refs | Should -Contain $script:compareObsA.reference
        $result.recommend.follow_up_run.source_evidence_refs | Should -Contain $script:compareConsultA.reference
        $result.recommend.follow_up_run.team_memory_refs | Should -Contain 'team-memory:task-compare-a:operator-standard'
        $result.recommend.follow_up_run.review_required | Should -Be $true
        $result.recommend.follow_up_run.human_approval_required | Should -Be $true
        $result.recommend.follow_up_run.auto_merge_allowed | Should -Be $false
        $result.recommend.follow_up_run.merge_requires_human | Should -Be $true
        $result.recommend.follow_up_run.operator_controls_merge | Should -Be $true
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
                timestamp = '2026-04-12T10:00:10+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.mailbox.message_received'
                message   = 'compare winner memory reference captured'
                label     = 'operator'
                pane_id   = ''
                role      = 'Operator'
                source    = 'mailbox'
                branch    = 'worktree-builder-a'
                head_sha  = 'aaaabbbbccccdddd'
                data      = [ordered]@{
                    task_id          = 'task-compare-a'
                    run_id           = 'task:task-compare-a'
                    source           = 'mailbox'
                    team_memory_refs = @('team-memory:task-compare-a:operator-standard')
                }
            } | ConvertTo-Json -Compress -Depth 8),
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
        $result.recommend.playbook_template.flow | Should -Be 'conflict_resolution'
        $result.recommend.playbook_template.compare_run_ids | Should -Be @('task:task-compare-a', 'task:task-compare-b')
        $result.recommend.playbook_template.required_evidence | Should -Be @('overlap_paths', 'reconcile_consult', 'human_decision')
        $result.recommend.playbook_template.team_memory_refs | Should -Contain 'team-memory:task-compare-a:operator-standard'
        $result.recommend.playbook_template.approval_defaults.review_required | Should -Be $true
        $result.recommend.playbook_template.approval_defaults.human_approval_required | Should -Be $true
        $result.recommend.playbook_template.approval_defaults.auto_merge_allowed | Should -Be $false
        $result.recommend.playbook_template.freeform_body_stored | Should -Be $false
        $result.recommend.follow_up_run | Should -Be $null
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
        $result.candidate.playbook_template.packet_type | Should -Be 'playbook_template_contract'
        $result.candidate.playbook_template.flow | Should -Be 'bugfix'
        $result.candidate.playbook_template.role_policy.reviewer | Should -Be 'return findings first with evidence references'
        $result.candidate.playbook_template.required_evidence | Should -Be @('reproduction', 'fix', 'regression_test')
        $result.candidate.playbook_template.team_memory_refs | Should -Contain 'team-memory:task-compare-a:operator-standard'
        $result.candidate.playbook_template.execution_backend | Should -Be 'operator_managed'
        $result.candidate.playbook_template.backend_profile_required | Should -Be $false
        $result.candidate.playbook_template.approval_defaults.review_required | Should -Be $true
        $result.candidate.playbook_template.approval_defaults.human_approval_required | Should -Be $true
        $result.candidate.playbook_template.approval_defaults.auto_merge_allowed | Should -Be $false
        $result.candidate.playbook_template.approval_defaults.merge_requires_human | Should -Be $true
        $result.candidate.playbook_template.freeform_body_stored | Should -Be $false
        $result.candidate.playbook_template.private_guidance_stored | Should -Be $false
        $result.candidate.playbook_template.PSObject.Properties.Name | Should -Not -Contain 'freeform_body'
        $result.candidate.playbook_template.PSObject.Properties.Name | Should -Not -Contain 'private_guidance'
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

    It 'rejects promote-tactic when architecture drift has not been reviewed' {
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
    review_state: ''
    branch: worktree-builder-a
    head_sha: aaaabbbbccccdddd
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: pipeline.verify.pass
    last_event_at: 2026-04-12T10:05:10+09:00
"@ | Set-Content -Path $script:compareManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-12T10:00:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.consult_result'
                message   = 'architecture drift detected before promotion'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                branch    = 'worktree-builder-a'
                head_sha  = 'aaaabbbbccccdddd'
                data      = [ordered]@{
                    task_id              = 'task-compare-a'
                    run_id               = 'task:task-compare-a'
                    slot                 = 'slot-builder-a'
                    hypothesis           = 'deterministic command fixes cache'
                    result               = 'cache hit done'
                    confidence           = 0.85
                    next_action          = 'promote tactic'
                    observation_pack_ref = $script:compareObsA.reference
                    consultation_ref     = $script:compareConsultA.reference
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
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:compareEventsPath -Encoding UTF8

        { Invoke-PromoteTactic -PromoteTarget 'task:task-compare-a' } | Should -Throw '*run is not promotable*'
    }
}

Describe 'winsmux observation and consultation artifacts' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
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

    It 'resolves local paths for local location identities' {
        $localLocation = New-WinsmuxLocationIdentity `
            -Kind 'local_file' `
            -DisplayName 'artifact.json' `
            -Backend 'local-windows' `
            -AccessMethod 'artifact_ref' `
            -Reference '.winsmux/artifact.json' `
            -LocalPath (Join-Path $script:artifactTempRoot 'artifact.json') `
            -Provenance 'test.local'

        Resolve-WinsmuxLocationIdentityLocalPath -Location $localLocation | Should -Be (Join-Path $script:artifactTempRoot 'artifact.json')

        $referenceLocation = New-WinsmuxLocationIdentity `
            -Kind 'source_ref' `
            -DisplayName 'source:task-300' `
            -Backend 'local-windows' `
            -AccessMethod 'source_reference' `
            -Reference 'task:task-300' `
            -Provenance 'test.source'

        $referenceLocation.local_path | Should -Be ''
        { Resolve-WinsmuxLocationIdentityLocalPath -Location $referenceLocation } | Should -Throw '*local path is not available for source_ref locations*'
    }
}

Describe 'winsmux consultation commands' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
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

    It 'TASK781 C19 threads the caller snapshot through review state updates' {
        $snapshot = [ordered]@{
            ManifestPath = 'C:\repo\.winsmux\manifest.yaml'
            PaneId = '%2'
            GenerationId = 'generation-initial'
        }
        $script:capturedReviewGeneration = ''
        Mock Get-CurrentReviewPaneManifestContext {
            [pscustomobject]@{ ManifestPath = 'replacement'; PaneId = '%9'; GenerationId = 'generation-replacement' }
        }
        Mock Set-PaneControlManifestPaneProperties {
            param($ManifestPath, $PaneId, $Properties, $ExpectedGenerationId)
            $script:capturedReviewGeneration = [string]$ExpectedGenerationId
        }

        Update-ReviewPaneManifestState -Context $snapshot -Properties ([ordered]@{ review_state = 'pending' })

        $script:capturedReviewGeneration | Should -BeExactly 'generation-initial'
        Should -Invoke Get-CurrentReviewPaneManifestContext -Times 0 -Exactly
    }

    It 'TASK781 C19 clears authoritative review state when manifest context is unavailable' {
        $script:reviewResetState = [ordered]@{ 'codex/test-review-reset' = [ordered]@{ status = 'PASS' } }
        Save-ReviewState -State $script:reviewResetState -ProjectDir $script:consultTempRoot
        Mock Get-CurrentGitBranch { 'codex/test-review-reset' }
        Mock Get-CurrentReviewPaneManifestContext { throw 'manifest unavailable' }
        Mock Set-PaneControlManifestPaneProperties { throw 'must not sync without a snapshot' }

        $output = & { $Target = $null; $Rest = @(); Invoke-ReviewReset }

        $output | Should -Match 'review PASS cleared'
        (Get-ReviewState -ProjectDir $script:consultTempRoot).Contains('codex/test-review-reset') | Should -BeFalse
        Should -Invoke Set-PaneControlManifestPaneProperties -Times 0 -Exactly
    }

    It 'TASK781 C19 carries the initial snapshot through the production consultation caller' {
        $script:consultCallerGeneration = ''
        Mock Get-CurrentReviewPaneManifestContext {
            [pscustomobject]@{
                ManifestPath = $script:consultManifestPath
                PaneId = '%2'
                GenerationId = 'generation-initial'
            }
        }
        Mock Get-PaneControlManifestGenerationId { 'generation-replacement' }
        Mock Set-PaneControlManifestPaneProperties {
            $script:consultCallerGeneration = [string]$ExpectedGenerationId
        }

        Write-ConsultationCommandRecord -Kind 'consult_request' -Mode 'early' -Message 'verify snapshot' `
            -ProjectDir $script:consultTempRoot | Out-Null

        $script:consultCallerGeneration | Should -BeExactly 'generation-initial'
        Should -Invoke Get-PaneControlManifestGenerationId -Times 0 -Exactly
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
        $bridgeScript = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'

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

Describe 'winsmux control-rpc command' {
    BeforeAll {
        $script:controlRpcBridgePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:controlRpcBridgeContent = Get-Content -Raw -Path $script:controlRpcBridgePath -Encoding UTF8
        $null = . $script:controlRpcBridgePath version
    }

    BeforeEach {
        $script:previousControlPipeToken = $env:WINSMUX_CONTROL_PIPE_TOKEN
        Remove-Item Env:\WINSMUX_CONTROL_PIPE_TOKEN -ErrorAction SilentlyContinue
    }

    AfterEach {
        if ($null -eq $script:previousControlPipeToken) {
            Remove-Item Env:\WINSMUX_CONTROL_PIPE_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_CONTROL_PIPE_TOKEN = $script:previousControlPipeToken
        }
    }

    It 'documents control-rpc in usage and fixes the named pipe endpoint' {
        $script:controlRpcBridgeContent | Should -Match 'control-rpc <json>'
        $script:controlRpcBridgeContent | Should -Match "'control-rpc'\s*\{\s*Invoke-ControlRpc\s*\}"
        $script:controlRpcBridgeContent | Should -Match 'operator-submit <text>'
        $script:controlRpcBridgeContent | Should -Match 'operator-snapshot \[--lines <n>\]'
        $script:controlRpcBridgeContent | Should -Match "'operator-submit'\s*\{\s*Invoke-OperatorSubmit\s*\}"
        $script:controlRpcBridgeContent | Should -Match "'operator-snapshot'\s*\{\s*Invoke-OperatorSnapshot\s*\}"
        $script:controlRpcBridgeContent | Should -Match '\$client\.ReadAsync\(\$buffer, 0, \$buffer\.Length\)'
        $script:controlRpcBridgeContent | Should -Match 'timed out waiting for response'
        $script:controlRpcBridgeContent | Should -Match 'WINSMUX_CONTROL_PIPE_TOKEN'
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

    It 'adds the control pipe token from the environment for non-contract methods' {
        $env:WINSMUX_CONTROL_PIPE_TOKEN = 'test-control-token'

        $payload = ConvertTo-ControlRpcPayload -JsonText '{"jsonrpc":"2.0","id":1,"method":"pty.capture","params":{"paneId":"pane-1"}}'
        $request = $payload | ConvertFrom-Json

        $request.method | Should -Be 'pty.capture'
        $request.auth.token | Should -Be 'test-control-token'
    }

    It 'fails closed when a non-contract method has no control pipe token' {
        { ConvertTo-ControlRpcPayload -JsonText '{"jsonrpc":"2.0","id":1,"method":"pty.capture","params":{"paneId":"pane-1"}}' } |
            Should -Throw '*WINSMUX_CONTROL_PIPE_TOKEN*'
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

    It 'submits operator messages through the dedicated operator control API' {
        $env:WINSMUX_CONTROL_PIPE_TOKEN = 'test-control-token'
        Mock Invoke-ControlRpcPipeExchange {
            param([string]$Payload)
            $script:operatorSubmitPayload = $Payload
            return '{"jsonrpc":"2.0","id":"operator-submit","result":{"ok":true}}'
        }

        $script:operatorSubmitPayload = ''
        $output = Invoke-OperatorSubmit -ControlTarget '--text' -ControlRest @('Restore', 'the', 'six-pane', 'orchestra')

        Should -Invoke Invoke-ControlRpcPipeExchange -Times 1 -Exactly
        $request = $script:operatorSubmitPayload | ConvertFrom-Json
        $request.method | Should -Be 'desktop.operator.submit'
        $request.params.message | Should -Be 'Restore the six-pane orchestra'
        $request.auth.token | Should -Be 'test-control-token'
        $request.PSObject.Properties.Name | Should -Not -Contain 'paneId'
        $output | Should -Be '{"jsonrpc":"2.0","id":"operator-submit","result":{"ok":true}}'
    }

    It 'captures operator output through the dedicated operator control API' {
        $env:WINSMUX_CONTROL_PIPE_TOKEN = 'test-control-token'
        Mock Invoke-ControlRpcPipeExchange {
            param([string]$Payload)
            $script:operatorSnapshotPayload = $Payload
            return '{"jsonrpc":"2.0","id":"operator-snapshot","result":{"paneId":"operator","output":"ready"}}'
        }

        $script:operatorSnapshotPayload = ''
        $output = Invoke-OperatorSnapshot -ControlTarget '--lines' -ControlRest @('40')

        Should -Invoke Invoke-ControlRpcPipeExchange -Times 1 -Exactly
        $request = $script:operatorSnapshotPayload | ConvertFrom-Json
        $request.method | Should -Be 'desktop.operator.snapshot'
        $request.params.lines | Should -Be 40
        $request.auth.token | Should -Be 'test-control-token'
        $request.PSObject.Properties.Name | Should -Not -Contain 'paneId'
        $output | Should -Be '{"jsonrpc":"2.0","id":"operator-snapshot","result":{"paneId":"operator","output":"ready"}}'
    }
}

Describe 'winsmux raw namespace forwarding' {
    BeforeAll {
        $script:namespaceBridgePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:previousBridgeNamespaceL = $env:WINSMUX_BRIDGE_NAMESPACE_L
        $script:previousBridgeSocketS = $env:WINSMUX_BRIDGE_SOCKET_S
    }

    AfterAll {
        if ($null -eq $script:previousBridgeNamespaceL) {
            Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_BRIDGE_NAMESPACE_L = $script:previousBridgeNamespaceL
        }
        if ($null -eq $script:previousBridgeSocketS) {
            Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_BRIDGE_SOCKET_S = $script:previousBridgeSocketS
        }
    }

    It 'prepends namespace selectors to nested raw winsmux calls' {
        $env:WINSMUX_BRIDGE_NAMESPACE_L = 'ops'
        $env:WINSMUX_BRIDGE_SOCKET_S = 'socket-name'
        $null = . $script:namespaceBridgePath version

        $script:namespaceRawCalls = [System.Collections.Generic.List[string]]::new()
        function winsmux {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

            $script:namespaceRawCalls.Add(($Arguments -join '|')) | Out-Null
            return 'ok'
        }
        $script:WinsmuxRawCommand = 'winsmux'

        try {
            Invoke-WinsmuxRaw -Arguments @('list-panes', '-a') | Out-Null
        } finally {
            Remove-Item Function:\winsmux -ErrorAction SilentlyContinue
        }

        $script:namespaceRawCalls.Count | Should -Be 1
        $script:namespaceRawCalls[0] | Should -Be '-L|ops|-S|socket-name|list-panes|-a'
    }

    It 'forwards unrecognized bridge commands to the native executable with exit status intact' {
        $script:forwardedRawArguments = @()
        function winsmux {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

            $script:forwardedRawArguments = @($Arguments)
            $global:LASTEXITCODE = 7
            'native-output'
        }

        $previousRawExe = $env:WINSMUX_RAW_EXE
        $previousNamespaceL = $env:WINSMUX_BRIDGE_NAMESPACE_L
        $previousSocketS = $env:WINSMUX_BRIDGE_SOCKET_S
        $env:WINSMUX_RAW_EXE = 'winsmux'
        Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
        Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
        try {
            $output = . $script:namespaceBridgePath new-session -d -s fixture
        } finally {
            if ($null -eq $previousRawExe) {
                Remove-Item Env:\WINSMUX_RAW_EXE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_RAW_EXE = $previousRawExe
            }
            if ($null -eq $previousNamespaceL) {
                Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_NAMESPACE_L = $previousNamespaceL
            }
            if ($null -eq $previousSocketS) {
                Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_SOCKET_S = $previousSocketS
            }
            Remove-Item Function:\winsmux -ErrorAction SilentlyContinue
        }

        $output | Should -Be 'native-output'
        $script:forwardedRawArguments | Should -Be @('new-session', '-d', '-s', 'fixture')
        $script:WinsmuxRequestedProcessExitCode | Should -Be 7
    }

    It 'routes documented lifecycle commands to the installed installer with profile aliases preserved' {
        $bridgeContent = Get-Content -LiteralPath $script:namespaceBridgePath -Raw -Encoding UTF8

        $bridgeContent | Should -Match '''install''\s+\{ Invoke-WinsmuxInstallerLifecycle -Action install'
        $bridgeContent | Should -Match '''update''\s+\{ Invoke-WinsmuxInstallerLifecycle -Action update'
        $bridgeContent | Should -Match '''uninstall''\s+\{ Invoke-WinsmuxInstallerLifecycle -Action uninstall'
        $bridgeContent | Should -Match '\$argument -eq ''--profile'''
        $bridgeContent | Should -Match 'StartsWith\(''--profile='', \[System\.StringComparison\]::Ordinal\)'
        $bridgeContent | Should -Match 'function Resolve-WinsmuxLifecycleInstaller'
        $bridgeContent | Should -Match 'core\\Cargo\.toml'
        $bridgeContent | Should -Match 'stage-npm-release\.mjs'
        $bridgeContent | Should -Match '\$script:WinsmuxRawCommand = \$null'
        $bridgeContent | Should -Match 'if \(\[string\]::IsNullOrWhiteSpace\(\[string\]\$script:WinsmuxRawCommand\)\)'
    }

    It 'resolves the lifecycle installer from the repository root when running the source bridge' {
        $previousRawExe = $env:WINSMUX_RAW_EXE
        $env:WINSMUX_RAW_EXE = 'winsmux'
        function winsmux {
            $global:LASTEXITCODE = 0
            return 'winsmux 0.0.0'
        }
        try {
            $null = . $script:namespaceBridgePath version
            $resolved = Resolve-WinsmuxLifecycleInstaller
        } finally {
            Remove-Item Function:\winsmux -ErrorAction SilentlyContinue
            if ($null -eq $previousRawExe) {
                Remove-Item Env:\WINSMUX_RAW_EXE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_RAW_EXE = $previousRawExe
            }
        }

        $expected = Join-Path (Split-Path -Parent (Split-Path -Parent $script:namespaceBridgePath)) 'install.ps1'
        $resolved | Should -Be ([System.IO.Path]::GetFullPath($expected))
    }

    It 'does not trust a parent installer when the bridge is in an installed bin layout' {
        $installedRoot = Join-Path $TestDrive 'installed-home'
        $installedBin = Join-Path $installedRoot 'bin'
        New-Item -ItemType Directory -Path $installedBin -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $installedRoot 'install.ps1'),
            'throw ''untrusted parent installer executed''',
            [System.Text.UTF8Encoding]::new($false)
        )
        $previousRawExe = $env:WINSMUX_RAW_EXE
        $env:WINSMUX_RAW_EXE = 'winsmux'
        function winsmux {
            $global:LASTEXITCODE = 0
            return 'winsmux 0.0.0'
        }
        try {
            $null = . $script:namespaceBridgePath version
            $resolved = Resolve-WinsmuxLifecycleInstaller -BridgeRoot $installedBin
        } finally {
            Remove-Item Function:\winsmux -ErrorAction SilentlyContinue
            if ($null -eq $previousRawExe) {
                Remove-Item Env:\WINSMUX_RAW_EXE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_RAW_EXE = $previousRawExe
            }
        }

        $resolved | Should -BeNullOrEmpty
    }

    It 'does not let a source scripts installer shadow the repository root installer' {
        $sourceRoot = Join-Path $TestDrive 'source-layout'
        $sourceScripts = Join-Path $sourceRoot 'scripts'
        $sourceCore = Join-Path $sourceRoot 'core'
        New-Item -ItemType Directory -Path $sourceScripts,$sourceCore -Force | Out-Null
        foreach ($file in @(
            @{ Path = (Join-Path $sourceRoot 'install.ps1'); Content = 'root installer' },
            @{ Path = (Join-Path $sourceScripts 'install.ps1'); Content = 'shadow installer' },
            @{ Path = (Join-Path $sourceScripts 'stage-npm-release.mjs'); Content = '// source marker' },
            @{ Path = (Join-Path $sourceCore 'Cargo.toml'); Content = '[package]' }
        )) {
            [System.IO.File]::WriteAllText($file.Path, $file.Content, [System.Text.UTF8Encoding]::new($false))
        }
        $previousRawExe = $env:WINSMUX_RAW_EXE
        $env:WINSMUX_RAW_EXE = 'winsmux'
        function winsmux {
            $global:LASTEXITCODE = 0
            return 'winsmux 0.0.0'
        }
        try {
            $null = . $script:namespaceBridgePath version
            $resolved = Resolve-WinsmuxLifecycleInstaller -BridgeRoot $sourceScripts
        } finally {
            Remove-Item Function:\winsmux -ErrorAction SilentlyContinue
            if ($null -eq $previousRawExe) {
                Remove-Item Env:\WINSMUX_RAW_EXE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_RAW_EXE = $previousRawExe
            }
        }

        $resolved | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $sourceRoot 'install.ps1')))
    }

    It 'keeps command-scoped socket flags after the delegated command name' {
        $env:WINSMUX_BRIDGE_NAMESPACE_L = 'ops'
        $env:WINSMUX_BRIDGE_SOCKET_S = 'socket-name'
        $null = . $script:namespaceBridgePath version

        $script:namespaceRawCalls = [System.Collections.Generic.List[string]]::new()
        function winsmux {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

            $script:namespaceRawCalls.Add(($Arguments -join '|')) | Out-Null
            return 'ok'
        }
        $script:WinsmuxRawCommand = 'winsmux'

        try {
            Invoke-WinsmuxRaw -Arguments @('capture-pane', '-t', '%1', '-p', '-J', '-S', '-50') | Out-Null
        } finally {
            Remove-Item Function:\winsmux -ErrorAction SilentlyContinue
        }

        $script:namespaceRawCalls.Count | Should -Be 1
        $script:namespaceRawCalls[0] | Should -Be '-L|ops|-S|socket-name|capture-pane|-t|%1|-p|-J|-S|-50'
    }

    It 'prepends namespace selectors through the shared helper command' {
        $env:WINSMUX_BRIDGE_NAMESPACE_L = 'ops'
        $env:WINSMUX_BRIDGE_SOCKET_S = 'socket-name'
        $settingsPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\settings.ps1'
        . $settingsPath

        $script:namespaceRawCalls = [System.Collections.Generic.List[string]]::new()
        function winsmux {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

            $script:namespaceRawCalls.Add(($Arguments -join '|')) | Out-Null
            return 'ok'
        }

        try {
            Invoke-WinsmuxBridgeCommand -WinsmuxBin 'winsmux' -Arguments @('list-panes', '-t', 'winsmux-orchestra') | Out-Null
        } finally {
            Remove-Item Function:\winsmux -ErrorAction SilentlyContinue
        }

        $script:namespaceRawCalls.Count | Should -Be 1
        $script:namespaceRawCalls[0] | Should -Be '-L|ops|-S|socket-name|list-panes|-t|winsmux-orchestra'
    }

    It 'keeps nested winsmux calls behind Invoke-WinsmuxRaw' {
        $bridgeContent = Get-Content -LiteralPath $script:namespaceBridgePath -Raw -Encoding UTF8

        $directCallMatches = [regex]::Matches($bridgeContent, '(?m)^\s*(?!return\s+)&\s+winsmux\b')
        $directAssignmentMatches = [regex]::Matches($bridgeContent, '(?m)^\s*\$[A-Za-z0-9_]+\s*=\s*&\s+winsmux\b')

        $directCallMatches.Count | Should -Be 0
        $directAssignmentMatches.Count | Should -Be 0
    }

    It 'keeps helper-script winsmux probes behind the bridge-aware helper' {
        $repoRoot = Split-Path -Parent $script:BridgeTestsRoot
        $helperPaths = @(
            'winsmux-core\scripts\agent-monitor.ps1',
            'winsmux-core\scripts\orchestra-attach-entry.ps1',
            'winsmux-core\scripts\orchestra-attach.ps1',
            'winsmux-core\scripts\orchestra-bootstrap.ps1',
            'winsmux-core\scripts\orchestra-layout.ps1',
            'winsmux-core\scripts\orchestra-preflight.ps1',
            'winsmux-core\scripts\orchestra-smoke.ps1',
            'winsmux-core\scripts\orchestra-start.ps1',
            'winsmux-core\scripts\orchestra-ui-attach.ps1',
            'winsmux-core\scripts\operator-poll.ps1',
            'winsmux-core\scripts\pane-border.ps1',
            'winsmux-core\scripts\pane-control.ps1',
            'winsmux-core\scripts\pane-status.ps1',
            'winsmux-core\scripts\server-watchdog.ps1',
            'winsmux-core\scripts\vault.ps1'
        )

        foreach ($relativePath in $helperPaths) {
            $content = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw -Encoding UTF8
            $directMatches = [regex]::Matches($content, '(?m)&\s+(winsmux|\$winsmuxBin|\$WinsmuxBin|\$winsmuxPath|\$WinsmuxPath|\$script:winsmuxBin)\b')
            $directMatches.Count | Should -Be 0 -Because "$relativePath should use Invoke-WinsmuxBridgeCommand"
        }
    }
}

Describe 'winsmux terminal backend switch' {
    BeforeAll {
        $bridgePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $null = . $bridgePath version
    }

    BeforeEach {
        $script:previousWinsmuxBackend = $env:WINSMUX_BACKEND
        $script:previousTerminalControlPipeToken = $env:WINSMUX_CONTROL_PIPE_TOKEN
        Remove-Item Env:\WINSMUX_BACKEND -ErrorAction SilentlyContinue
        $env:WINSMUX_CONTROL_PIPE_TOKEN = 'test-control-token'
        $script:terminalRpcPayloads = [System.Collections.Generic.List[string]]::new()
    }

    AfterEach {
        if ($null -eq $script:previousWinsmuxBackend) {
            Remove-Item Env:\WINSMUX_BACKEND -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_BACKEND = $script:previousWinsmuxBackend
        }
        if ($null -eq $script:previousTerminalControlPipeToken) {
            Remove-Item Env:\WINSMUX_CONTROL_PIPE_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_CONTROL_PIPE_TOKEN = $script:previousTerminalControlPipeToken
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

Describe 'deferred worker startup' {
    BeforeAll {
        $bridgePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $null = . $bridgePath version
        $script:deferredCoreContent = Get-Content -LiteralPath $bridgePath -Raw -Encoding UTF8
        $script:deferredControlPlaneDispatchContent = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\control-plane-dispatch.ps1') -Raw -Encoding UTF8
        $script:deferredMonitorContent = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\agent-monitor.ps1') -Raw -Encoding UTF8
    }

    BeforeEach {
        $script:deferredTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-deferred-worker-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:deferredTempRoot -Force | Out-Null
        $script:deferredPlanPath = Join-Path $script:deferredTempRoot 'worker-2.json'
        $script:deferredMarkerPath = Join-Path $script:deferredTempRoot 'worker-2.ready.json'
        ([ordered]@{
            agent             = 'codex'
            ready_marker_path = $script:deferredMarkerPath
        } | ConvertTo-Json -Depth 6) | Set-Content -Path $script:deferredPlanPath -Encoding UTF8
        $script:deferredSendCommands = [System.Collections.Generic.List[string]]::new()
        $script:deferredCanonicalSendCalls = [System.Collections.Generic.List[object]]::new()
        $script:deferredStatusWrites = [System.Collections.Generic.List[string]]::new()
        $script:deferredPropertyWrites = [System.Collections.Generic.List[object]]::new()
        $script:deferredReadyProbeCount = 0
        $script:deferredPreRetryProbeApplies = $false
        $script:deferredPreRetryReady = $false

        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            [pscustomobject]@{
                Managed      = $true
                ProjectDir   = $script:deferredTempRoot
                GenerationId = 'generation-deferred'
                Validation   = [pscustomobject]@{ valid = $true }
            }
        }
        Mock Wait-PaneShellReady { }
        Mock Invoke-Send {
            param(
                [string]$SendTarget,
                [string[]]$SendArguments,
                [ValidateSet('prompt', 'launch')][string]$DeliveryClass,
                [switch]$SkipDeferredPaneStart
            )
            $script:deferredSendCommands.Add([string]$SendArguments[-1]) | Out-Null
            $script:deferredCanonicalSendCalls.Add([PSCustomObject]@{
                Target                = $SendTarget
                Arguments             = @($SendArguments)
                DeliveryClass         = $DeliveryClass
                SkipDeferredPaneStart = [bool]$SkipDeferredPaneStart
            }) | Out-Null
            return "sent to $SendTarget"
        }
        Mock Send-TextToPane { throw 'deferred bootstrap must use canonical Invoke-Send delivery' }
        Mock Test-AgentReadyPrompt {
            $script:deferredReadyProbeCount++
            if ($script:deferredReadyProbeCount -eq 1 -and $script:deferredPreRetryProbeApplies) {
                return [bool]$script:deferredPreRetryReady
            }

            return $true
        }
        Mock Set-PaneControlManifestPaneProperties {
            param([string]$ManifestPath, [string]$PaneId, [System.Collections.IDictionary]$Properties)
            $script:deferredStatusWrites.Add([string]$Properties['status']) | Out-Null
            $capturedProperties = [ordered]@{}
            foreach ($key in @($Properties.Keys)) {
                $capturedProperties[[string]$key] = $Properties[$key]
            }
            $script:deferredPropertyWrites.Add([PSCustomObject]@{
                PaneId = $PaneId
                Properties = $capturedProperties
            }) | Out-Null
        }
        Mock Get-PaneControlManifestContext {
            param([string]$ProjectDir, [string]$PaneId)
            [PSCustomObject]@{
                Label = 'worker-2'; SlotId = 'worker-2'; PaneId = $PaneId; WorkerBackend = 'codex'
                WorkerRole = 'worker'; Role = 'Worker'; Title = 'W2'; Status = 'deferred_starting'
                BootstrapMarkerPath = $script:deferredMarkerPath
            }
        }
        Mock Wait-PaneControlRuntimeContext {
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' `
                -Diagnostic 'synthetic promoted runtime verified' -Context ([ordered]@{ generation_id = 'generation-deferred' })
        }
    }

    AfterEach {
        if ($script:deferredTempRoot -and (Test-Path -LiteralPath $script:deferredTempRoot)) {
            Remove-Item -LiteralPath $script:deferredTempRoot -Recurse -Force
        }
    }

    It 'starts a deferred pane from its bootstrap plan before delivery' {
        $entry = [PSCustomObject]@{
            Label             = 'worker-2'
            PaneId            = '%3'
            Status            = 'deferred_start'
            BootstrapPlanPath = $script:deferredPlanPath
            CapabilityAdapter = 'codex'
            ProviderTarget    = ''
        }

        $started = Start-DeferredPaneFromManifestEntry -ProjectDir $script:deferredTempRoot -ManifestEntry $entry

        $started | Should -Be $true
        Should -Invoke Wait-PaneShellReady -Times 1 -Exactly -ParameterFilter { $PaneId -eq '%3' }
        Should -Invoke Test-AgentReadyPrompt -Times 1 -Exactly -ParameterFilter { $PaneId -eq '%3' -and $Agent -eq 'codex' }
        $script:deferredSendCommands.Count | Should -Be 1
        $script:deferredSendCommands[0] | Should -Match 'orchestra-pane-bootstrap\.ps1'
        $script:deferredSendCommands[0] | Should -Match '-PlanFile'
        $script:deferredCanonicalSendCalls.Count | Should -Be 1
        $script:deferredCanonicalSendCalls[0].Target | Should -Be '%3'
        @($script:deferredCanonicalSendCalls[0].Arguments) | Should -Be @($script:deferredSendCommands[0])
        $script:deferredCanonicalSendCalls[0].DeliveryClass | Should -Be 'launch'
        $script:deferredCanonicalSendCalls[0].SkipDeferredPaneStart | Should -Be $true
        Should -Invoke Send-TextToPane -Times 0 -Exactly
        $script:deferredStatusWrites | Should -Be @('deferred_starting', 'ready')
    }

    It 'TASK781 C29 waits for supervisor live promotion before publishing ready' {
        $entry = [PSCustomObject]@{
            Label = 'worker-2'; PaneId = '%3'; Status = 'deferred_starting'; BootstrapPlanPath = $script:deferredPlanPath
            CapabilityAdapter = 'codex'; ProviderTarget = ''; ApprovedLaunch = $null
        }
        $script:c29DeferredTrace = [System.Collections.Generic.List[string]]::new()
        Mock Wait-DeferredPaneReady { $script:c29DeferredTrace.Add('marker-ready') | Out-Null }
        Mock Wait-PaneControlRuntimeContext {
            $script:c29DeferredTrace.Add('registry-live') | Out-Null
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' `
                -Diagnostic 'synthetic promoted runtime verified' -Context ([ordered]@{ generation_id = 'generation-deferred' })
        }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            param($PaneId, $CurrentProjectDir, $Operation, $ExpectedGenerationId)
            if ($Operation -eq 'dispatch') { $script:c29DeferredTrace.Add('final-guard') | Out-Null }
            [PSCustomObject]@{ Managed = $true; ProjectDir = $script:deferredTempRoot; GenerationId = 'generation-deferred' }
        }
        Mock Set-PaneControlManifestPaneProperties {
            param([string]$ManifestPath, [string]$PaneId, [System.Collections.IDictionary]$Properties)
            if ([string]$Properties['status'] -eq 'ready') { $script:c29DeferredTrace.Add('manifest-ready') | Out-Null }
        }

        Start-DeferredPaneFromManifestEntry -ProjectDir $script:deferredTempRoot -ManifestEntry $entry `
            -ExpectedGenerationId 'generation-deferred' | Should -BeTrue

        @($script:c29DeferredTrace) | Should -Be @('marker-ready', 'registry-live', 'final-guard', 'manifest-ready')
    }

    It 'waits for an already-starting deferred pane without launching a duplicate bootstrap' {
        $entry = [PSCustomObject]@{
            Label             = 'worker-2'
            PaneId            = '%3'
            Status            = 'deferred_starting'
            BootstrapPlanPath = $script:deferredPlanPath
            CapabilityAdapter = 'codex'
            ProviderTarget    = ''
        }

        $started = Start-DeferredPaneFromManifestEntry -ProjectDir $script:deferredTempRoot -ManifestEntry $entry

        $started | Should -Be $true
        Should -Invoke Wait-PaneShellReady -Times 0 -Exactly
        $script:deferredSendCommands.Count | Should -Be 0
        $script:deferredStatusWrites | Should -Be @('ready')
    }

    It 'TASK781 C73 records readiness timeout as retryable after one deferred bootstrap launch' {
        $entry = [PSCustomObject]@{
            Label = 'worker-2'; PaneId = '%3'; Status = 'deferred_start'; BootstrapPlanPath = $script:deferredPlanPath
            CapabilityAdapter = 'codex'; ProviderTarget = ''; ApprovedLaunch = $null
        }
        Mock Wait-DeferredPaneReady { throw 'synthetic deferred readiness timeout' }

        {
            Start-DeferredPaneFromManifestEntry -ProjectDir $script:deferredTempRoot -ManifestEntry $entry `
                -ExpectedGenerationId 'generation-deferred'
        } | Should -Throw '*synthetic deferred readiness timeout*'

        $script:deferredSendCommands.Count | Should -Be 1
        $script:deferredStatusWrites | Should -Be @('deferred_starting', 'deferred_start_failed')
        $failure = $script:deferredPropertyWrites[$script:deferredPropertyWrites.Count - 1].Properties
        $failure['last_failure_stage'] | Should -Be 'readiness_probe'
        $failure['last_failure_reason'] | Should -Match 'synthetic deferred readiness timeout'
    }

    It 'TASK781 C29 leaves non-retryable unconfigured deferred states unchanged' -ForEach @(
        'api_llm_runner_unconfigured',
        'antigravity_runner_unconfigured'
    ) {
        $entry = [PSCustomObject]@{
            Label = 'worker-2'; PaneId = '%3'; Status = [string]$_; BootstrapPlanPath = $script:deferredPlanPath
            CapabilityAdapter = 'codex'; ProviderTarget = ''; ApprovedLaunch = $null
        }

        $started = Start-DeferredPaneFromManifestEntry -ProjectDir $script:deferredTempRoot -ManifestEntry $entry

        $started | Should -BeFalse
        (Get-WinsmuxRuntimeStatusClassification -Status ([string]$_)).Retryable | Should -BeFalse
        $script:deferredSendCommands.Count | Should -Be 0
        $script:deferredStatusWrites.Count | Should -Be 0
        Should -Invoke Wait-PaneShellReady -Times 0 -Exactly
        Should -Invoke Wait-PaneControlRuntimeContext -Times 0 -Exactly
    }

    It 'retries a previously failed deferred pane instead of sending task text to the shell' {
        $script:deferredPreRetryProbeApplies = $true
        $script:deferredPreRetryReady = $false
        $entry = [PSCustomObject]@{
            Label             = 'worker-2'
            PaneId            = '%3'
            Status            = 'deferred_start_failed'
            BootstrapPlanPath = $script:deferredPlanPath
            CapabilityAdapter = 'codex'
            ProviderTarget    = ''
        }

        $started = Start-DeferredPaneFromManifestEntry -ProjectDir $script:deferredTempRoot -ManifestEntry $entry

        $started | Should -Be $true
        Should -Invoke Wait-PaneShellReady -Times 1 -Exactly -ParameterFilter { $PaneId -eq '%3' }
        $script:deferredSendCommands.Count | Should -Be 1
        $script:deferredSendCommands[0] | Should -Match 'orchestra-pane-bootstrap\.ps1'
        $script:deferredCanonicalSendCalls.Count | Should -Be 1
        $script:deferredCanonicalSendCalls[0].Target | Should -Be '%3'
        @($script:deferredCanonicalSendCalls[0].Arguments) | Should -Be @($script:deferredSendCommands[0])
        $script:deferredCanonicalSendCalls[0].DeliveryClass | Should -Be 'launch'
        $script:deferredCanonicalSendCalls[0].SkipDeferredPaneStart | Should -Be $true
        Should -Invoke Send-TextToPane -Times 0 -Exactly
        $script:deferredStatusWrites | Should -Be @('deferred_starting', 'ready')
    }

    It 'TASK781 C32 reuses a live authenticated failed marker without launching a duplicate bootstrap' {
        $entry = [PSCustomObject]@{
            Label = 'worker-2'; PaneId = '%3'; Status = 'deferred_start_failed'
            BootstrapPlanPath = $script:deferredPlanPath; BootstrapMarkerPath = $script:deferredMarkerPath
            CapabilityAdapter = 'codex'; ProviderTarget = ''
        }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            [pscustomobject]@{
                Managed = $true; ProjectDir = $script:deferredTempRoot; GenerationId = 'generation-deferred'
                Validation = [pscustomobject]@{
                    valid = $true
                    context = [pscustomobject]@{ retry_marker_state = 'live'; generation_id = 'generation-deferred' }
                }
            }
        }

        $started = Start-DeferredPaneFromManifestEntry -ProjectDir $script:deferredTempRoot -ManifestEntry $entry `
            -ExpectedGenerationId 'generation-deferred'

        $started | Should -BeTrue
        Should -Invoke Wait-PaneShellReady -Times 0 -Exactly
        $script:deferredSendCommands.Count | Should -Be 0
        $script:deferredStatusWrites | Should -Be @('deferred_starting', 'ready')
    }

    It 'TASK781 C36 refuses a live retry manifest write when the marker changes after validation' {
        $entry = [PSCustomObject]@{
            Label = 'worker-2'; PaneId = '%3'; Status = 'deferred_start_failed'
            BootstrapPlanPath = $script:deferredPlanPath; BootstrapMarkerPath = $script:deferredMarkerPath
            CapabilityAdapter = 'codex'; ProviderTarget = ''
        }
        $script:c36GuardCalls = 0
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            $script:c36GuardCalls++
            $markerState = if ($script:c36GuardCalls -eq 1) { 'live' } else { 'stale' }
            [pscustomobject]@{
                Managed = $true; ProjectDir = $script:deferredTempRoot; GenerationId = 'generation-deferred'
                Validation = [pscustomobject]@{
                    valid = $true
                    context = [pscustomobject]@{ retry_marker_state = $markerState; generation_id = 'generation-deferred' }
                }
            }
        }
        $errorText = ''

        try {
            Start-DeferredPaneFromManifestEntry -ProjectDir $script:deferredTempRoot -ManifestEntry $entry `
                -ExpectedGenerationId 'generation-deferred' | Out-Null
        } catch {
            $errorText = [string]$_.Exception.Message
        }

        $script:c36GuardCalls | Should -Be 2
        $script:deferredStatusWrites.Count | Should -Be 0
        $script:deferredSendCommands.Count | Should -Be 0
        $errorText | Should -Match 'changed before deferred retry manifest update'
    }

    It 'TASK781 C32 safely removes a stale authenticated failed marker before one bootstrap retry' {
        $bootstrapRoot = Join-Path (Join-Path $script:deferredTempRoot '.winsmux') 'orchestra-bootstrap'
        New-Item -ItemType Directory -Path $bootstrapRoot -Force | Out-Null
        $planPath = Join-Path $bootstrapRoot '2.json'
        $markerPath = Join-Path $bootstrapRoot '2-generation-deferred.ready.json'
        ([ordered]@{ agent = 'codex'; ready_marker_path = $markerPath } | ConvertTo-Json) |
            Set-Content -LiteralPath $planPath -Encoding UTF8
        '{}' | Set-Content -LiteralPath $markerPath -Encoding UTF8
        $entry = [PSCustomObject]@{
            Label = 'worker-2'; PaneId = '%3'; Status = 'deferred_start_failed'
            BootstrapPlanPath = $planPath; BootstrapMarkerPath = $markerPath
            CapabilityAdapter = 'codex'; ProviderTarget = ''
        }
        $script:c32RetryGuardCount = 0
        $script:c32MarkerAbsentAtLaunch = $false
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            $script:c32RetryGuardCount++
            $markerState = if ($script:c32RetryGuardCount -le 2) { 'stale' } else { '' }
            [pscustomobject]@{
                Managed = $true; ProjectDir = $script:deferredTempRoot; GenerationId = 'generation-deferred'
                Validation = [pscustomobject]@{
                    valid = $true
                    context = [pscustomobject]@{ retry_marker_state = $markerState; generation_id = 'generation-deferred' }
                }
            }
        }
        Mock Invoke-Send {
            param([string]$SendTarget, [string[]]$SendArguments, [string]$DeliveryClass, [switch]$SkipDeferredPaneStart)
            $script:c32MarkerAbsentAtLaunch = -not (Test-Path -LiteralPath $markerPath -PathType Leaf)
            $script:deferredSendCommands.Add([string]$SendArguments[-1]) | Out-Null
            return "sent to $SendTarget"
        }
        $script:deferredPreRetryProbeApplies = $true
        $script:deferredPreRetryReady = $false

        $started = Start-DeferredPaneFromManifestEntry -ProjectDir $script:deferredTempRoot -ManifestEntry $entry `
            -ExpectedGenerationId 'generation-deferred'

        $started | Should -BeTrue
        $script:c32MarkerAbsentAtLaunch | Should -BeTrue
        $script:deferredSendCommands.Count | Should -Be 1
        $script:c32RetryGuardCount | Should -BeGreaterOrEqual 2
        $script:deferredStatusWrites | Should -Be @('deferred_starting', 'ready')
    }

    It 'does not trust a delayed prompt without an authenticated marker and launches one retry' {
        $script:deferredPreRetryProbeApplies = $true
        $script:deferredPreRetryReady = $true
        $entry = [PSCustomObject]@{
            Label             = 'worker-2'
            PaneId            = '%3'
            Status            = 'deferred_start_failed'
            BootstrapPlanPath = $script:deferredPlanPath
            CapabilityAdapter = 'codex'
            ProviderTarget    = ''
        }

        $started = Start-DeferredPaneFromManifestEntry -ProjectDir $script:deferredTempRoot -ManifestEntry $entry

        $started | Should -Be $true
        Should -Invoke Wait-PaneShellReady -Times 1 -Exactly
        $script:deferredSendCommands.Count | Should -Be 1
        $script:deferredReadyProbeCount | Should -Be 1
        $script:deferredStatusWrites | Should -Be @('deferred_starting', 'ready')
    }

    It 'blocks a previously failed deferred pane when the bootstrap plan is still missing' {
        $script:deferredPreRetryProbeApplies = $true
        $script:deferredPreRetryReady = $false
        $missingPlan = Join-Path $script:deferredTempRoot 'missing-worker-2.json'
        $entry = [PSCustomObject]@{
            Label             = 'worker-2'
            PaneId            = '%3'
            Status            = 'deferred_start_failed'
            BootstrapPlanPath = $missingPlan
            CapabilityAdapter = 'codex'
            ProviderTarget    = ''
        }

        { Start-DeferredPaneFromManifestEntry -ProjectDir $script:deferredTempRoot -ManifestEntry $entry } |
            Should -Throw "*bootstrap plan not found*"

        $script:deferredSendCommands.Count | Should -Be 0
        $script:deferredStatusWrites | Should -Be @('deferred_start_failed')
        $lastWrite = $script:deferredPropertyWrites[$script:deferredPropertyWrites.Count - 1].Properties
        $lastWrite['last_failure_stage'] | Should -Be 'bootstrap_plan_not_found'
        $lastWrite['last_failure_reason'] | Should -Match 'bootstrap plan not found'
        $lastWrite['recovery_action'] | Should -Be 'rerun-winsmux-launch'
    }

    It 'blocks a deferred pane when its bootstrap plan does not match the approved launch' {
        $entry = [PSCustomObject]@{
            Label             = 'worker-2'
            PaneId            = '%3'
            Status            = 'deferred_start'
            BootstrapPlanPath = $script:deferredPlanPath
            CapabilityAdapter = 'codex'
            ProviderTarget    = ''
            ApprovedLaunch    = [PSCustomObject]@{
                packet_type = 'worker_launch_approval'
                source = 'user_approved_worker_config'
                slot_id = 'worker-2'
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
        }
        ([ordered]@{
            agent = 'codex'
            ready_marker_path = $script:deferredMarkerPath
            approved_launch = [ordered]@{
                packet_type = 'worker_launch_approval'
                source = 'user_approved_worker_config'
                slot_id = 'worker-2'
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
        } | ConvertTo-Json -Depth 8) | Set-Content -Path $script:deferredPlanPath -Encoding UTF8

        { Start-DeferredPaneFromManifestEntry -ProjectDir $script:deferredTempRoot -ManifestEntry $entry } |
            Should -Throw "*worker launch approval mismatch*"

        Should -Invoke Wait-PaneShellReady -Times 0 -Exactly
        $script:deferredSendCommands.Count | Should -Be 0
        $script:deferredStatusWrites | Should -Be @('deferred_start_failed')
        $lastWrite = $script:deferredPropertyWrites[$script:deferredPropertyWrites.Count - 1].Properties
        $lastWrite['last_failure_stage'] | Should -Be 'launch_approval'
        $lastWrite['last_failure_reason'] | Should -Match 'worker launch approval mismatch'
        $lastWrite['recovery_action'] | Should -Be 'review-worker-settings-and-rerun-launch'
    }

    It 'keeps send, dispatch-task, and monitor paths aware of deferred panes' {
        $script:deferredCoreContent | Should -Match 'function Start-DeferredPaneFromManifestEntry'
        $script:deferredCoreContent | Should -Match 'Start-DeferredPaneFromManifestEntry -ProjectDir \$projectDir -ManifestEntry \$context'
        $script:deferredCoreContent | Should -Match 'Invoke-WinsmuxDispatchTaskCommand'
        $script:deferredControlPlaneDispatchContent | Should -Match 'Start-DeferredPaneFromManifestEntry -ProjectDir \$projectDir -ManifestEntry \$manifestEntry'
        $script:deferredCoreContent | Should -Match 'deferred_starting'
        $script:deferredMonitorContent | Should -Match 'deferred_start_failed'
    }
}

Describe 'winsmux send fallback' {
    BeforeAll {
        $bridgePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
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

    It 'TASK781 C29 revalidates the captured generation immediately before every pane mutation' {
        $script:c29SendLeaseTrace = [System.Collections.Generic.List[string]]::new()
        $script:c29SendSnapshotCount = 0
        $deliveryState = [ordered]@{}
        Mock Resolve-TerminalBackend { 'tauri' }
        Mock Split-SendKeysLiteralChunks { @('echo ', 'test') }
        Mock Get-PaneSnapshotText {
            $script:c29SendSnapshotCount++
            switch ($script:c29SendSnapshotCount) {
                1 { return '> ' }
                2 { return '> echo test' }
                3 { return "> echo test`nresult" }
                default { return "> echo test`nresult" }
            }
        }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            param($PaneId, $CurrentProjectDir, $Operation, $ExpectedGenerationId)
            $script:c29SendLeaseTrace.Add("guard:${Operation}:${ExpectedGenerationId}") | Out-Null
            [PSCustomObject]@{ Managed = $true; ProjectDir = $CurrentProjectDir; GenerationId = $ExpectedGenerationId }
        }
        Mock Invoke-WinsmuxSendKeys {
            param($Target, $Keys, [switch]$Literal)
            $kind = if ($Literal) { 'literal' } else { [string]$Keys[0] }
            $script:c29SendLeaseTrace.Add("mutation:$kind") | Out-Null
            [PSCustomObject]@{ ExitCode = 0; Output = '' }
        }
        Mock Save-Watermark { }
        Mock Set-ReadMark { }

        $result = Send-TextToPane -PaneId '%7' -CommandText 'echo test' `
            -RuntimeProjectDir 'C:\synthetic-project' -RuntimeOperation dispatch `
            -ExpectedGenerationId 'generation-G1' -DeliveryState $deliveryState

        $result | Should -Be 'sent to %7 via %7'
        $mutations = @($script:c29SendLeaseTrace | Where-Object { $_ -like 'mutation:*' })
        $mutations | Should -Be @('mutation:literal', 'mutation:literal', 'mutation:Enter')
        for ($index = 0; $index -lt $script:c29SendLeaseTrace.Count; $index++) {
            if ($script:c29SendLeaseTrace[$index] -like 'mutation:*') {
                $index | Should -BeGreaterThan 0
                $script:c29SendLeaseTrace[$index - 1] | Should -Be 'guard:dispatch:generation-G1'
            }
        }
        $deliveryState['SubmissionCommitted'] | Should -BeTrue
    }

    It 'TASK781 C68 marks packet retention at the first successful Enter before snapshot failure' {
        $deliveryState = [ordered]@{}
        $script:c68SnapshotCount = 0
        Mock Resolve-TerminalBackend { 'tauri' }
        Mock Split-SendKeysLiteralChunks { @('echo test') }
        Mock Get-PaneSnapshotText {
            $script:c68SnapshotCount++
            switch ($script:c68SnapshotCount) {
                1 { return '> ' }
                2 { return '> echo test' }
                default { throw 'synthetic post-Enter snapshot failure' }
            }
        }
        Mock Assert-SendPaneRuntimeLease { }
        Mock Invoke-WinsmuxSendKeys { [PSCustomObject]@{ ExitCode = 0; Output = '' } }

        { Send-TextToPane -PaneId '%7' -CommandText 'echo test' -DeliveryState $deliveryState } |
            Should -Throw '*post-Enter snapshot failure*'

        $deliveryState['SubmissionCommitted'] | Should -BeTrue
        Should -Invoke Invoke-WinsmuxSendKeys -Times 1 -Exactly -ParameterFilter {
            -not $Literal -and [string]$Keys[0] -ceq 'Enter'
        }
    }

    It 'TASK781 C68 aborts fallback after committed Enter when pasted-content confirmation fails' {
        $deliveryState = [ordered]@{}
        $script:c68SecondEnterCount = 0
        $script:c68FallbackTargetCalls = 0
        Mock Resolve-TerminalBackend { 'cli' }
        Mock Get-PaneTargetCandidates { @('%7', 'default:0.3') }
        Mock Split-SendKeysLiteralChunks { @('echo test') }
        Mock Get-PaneSnapshotText {
            if ($script:sendBuffer -eq '') { return '> ' }
            if ($script:sendBuffer -eq 'typed') { return '> echo test' }
            if ($script:sendBuffer -eq 'pasted') { return '> [Pasted Content 1 lines]' }
            return '> '
        }
        Mock Invoke-WinsmuxSendKeys {
            param($Target, $Keys, [switch]$Literal)
            if ($Target -eq 'default:0.3') {
                $script:c68FallbackTargetCalls++
                throw 'committed attempt must not reach fallback target'
            }
            if ($Literal) {
                $script:sendBuffer = 'typed'
                return [PSCustomObject]@{ ExitCode = 0; Output = '' }
            }
            $script:c68SecondEnterCount++
            if ($script:c68SecondEnterCount -eq 1) {
                $script:sendBuffer = 'pasted'
                return [PSCustomObject]@{ ExitCode = 0; Output = '' }
            }
            return [PSCustomObject]@{ ExitCode = 1; Output = 'synthetic second Enter failed' }
        }

        { Send-TextToPane -PaneId '%7' -CommandText 'echo test' -DeliveryState $deliveryState } |
            Should -Throw '*second Enter failed*'

        $deliveryState['SubmissionCommitted'] | Should -BeTrue
        $script:c68FallbackTargetCalls | Should -Be 0
    }

    It 'TASK781 C68 has no control-flow continue after the committed boundary' {
        $content = [System.IO.File]::ReadAllText($bridgePath, [System.Text.Encoding]::UTF8)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $content,
            $bridgePath,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
        $sendFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Send-TextToPane'
        }, $true)
        $source = $sendFunction.Extent.Text
        $committedIndex = $source.IndexOf("`$DeliveryState['SubmissionCommitted'] = `$true", [System.StringComparison]::Ordinal)
        $committedIndex | Should -BeGreaterThan -1
        $postCommitSource = $source.Substring($committedIndex)
        $postCommitSource | Should -Not -Match '(?m)^\s*continue\b'
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
        $bridgePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
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
