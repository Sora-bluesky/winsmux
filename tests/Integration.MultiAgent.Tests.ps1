$ErrorActionPreference = 'Stop'

Describe 'orchestra cleanup helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-cleanup.ps1')
    }

    It 'matches orchestra-managed pane titles only' {
        (Test-OrchestraManagedPaneTitle -Title 'Builder-1') | Should -Be $true
        (Test-OrchestraManagedPaneTitle -Title 'worker-1') | Should -Be $true
        (Test-OrchestraManagedPaneTitle -Title 'researcher-2') | Should -Be $true
        (Test-OrchestraManagedPaneTitle -Title 'Reviewer-3') | Should -Be $true
        (Test-OrchestraManagedPaneTitle -Title 'Operator') | Should -Be $false
        (Test-OrchestraManagedPaneTitle -Title 'PowerShell') | Should -Be $false
    }

    It 'targets stale orchestra panes from non-orchestra sessions only' {
        $targets = Get-StaleOrchestraPaneTargets -SessionName 'winsmux-orchestra' -PaneRecords @(
            "default`t%1`tBuilder-1"
            "default`t%2`tResearcher-1"
            "winsmux-orchestra`t%3`tBuilder-2"
            "default`t%4`tPowerShell"
            "scratch`t%5`tReviewer-1"
            "malformed line"
        )

        $targets.Count | Should -Be 3
        $targets[0].SessionName | Should -Be 'default'
        $targets[0].PaneId | Should -Be '%1'
        $targets[1].PaneId | Should -Be '%2'
        $targets[2].SessionName | Should -Be 'scratch'
        $targets[2].PaneId | Should -Be '%5'
    }
}

Describe 'Get-BridgeSettings defaults' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\settings.ps1')
    }

    BeforeEach {
        $script:settingsTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-multi-agent-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:settingsTempRoot -Force | Out-Null
        Push-Location $script:settingsTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:settingsTempRoot -and (Test-Path $script:settingsTempRoot)) {
            Remove-Item -Path $script:settingsTempRoot -Recurse -Force
        }
    }

    It 'returns correct built-in defaults for all keys' {
        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings

        $settings.agent | Should -Be 'codex'
        $settings.model | Should -Be ''
        $settings.external_operator | Should -Be $true
        $settings.legacy_role_layout | Should -Be $false
        $settings.operators | Should -Be 0
        $settings.worker_count | Should -Be 6
        $settings.builders | Should -Be 0
        $settings.researchers | Should -Be 0
        $settings.reviewers | Should -Be 0
        $settings.terminal | Should -Be 'background'
        $settings.vault_keys | Should -Be @('GH_TOKEN')
        $settings.roles | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
        $settings.roles.Count | Should -Be 0
    }
}

Describe 'Get-RoleAgentConfig with fallback' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\settings.ps1')
    }

    BeforeEach {
        $script:settingsTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-role-config-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:settingsTempRoot -Force | Out-Null
        Push-Location $script:settingsTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:settingsTempRoot -and (Test-Path $script:settingsTempRoot)) {
            Remove-Item -Path $script:settingsTempRoot -Recurse -Force
        }
    }

    It 'returns per-role config when defined and falls back to global for missing keys' {
        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            roles = [ordered]@{
                builder = [ordered]@{
                    agent = 'codex'
                    model = 'gpt-5.4-codex'
                }
                reviewer = [ordered]@{
                    agent = 'claude'
                }
            }
        }

        $builderConfig = Get-RoleAgentConfig -Role 'builder' -Settings $settings
        $builderConfig.Agent | Should -Be 'codex'
        $builderConfig.Model | Should -Be 'gpt-5.4-codex'

        $reviewerConfig = Get-RoleAgentConfig -Role 'reviewer' -Settings $settings
        $reviewerConfig.Agent | Should -Be 'claude'
        $reviewerConfig.Model | Should -Be 'gpt-5.4'

        $operatorConfig = Get-RoleAgentConfig -Role 'Operator' -Settings $settings
        $operatorConfig.Agent | Should -Be 'codex'
        $operatorConfig.Model | Should -Be 'gpt-5.4'
    }
}

Describe 'agent launch helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\agent-launch.ps1')
    }

    It 'builds the Codex launch command with quoted project and worktree paths' {
        $command = Get-AgentLaunchCommand -Agent 'codex' -Model 'gpt-5.4' -ProjectDir "C:\repo path\builder-1" -GitWorktreeDir "C:\repo path\.git"

        $command | Should -Be "codex -c 'model=gpt-5.4' --sandbox danger-full-access -C 'C:\repo path\builder-1' --add-dir 'C:\repo path\.git'"
    }

    It 'lets Codex use its CLI default model when no model is configured' {
        $command = Get-AgentLaunchCommand -Agent 'codex' -Model '' -ProjectDir "C:\repo path\builder-1" -GitWorktreeDir "C:\repo path\.git"

        $command | Should -Be "codex --sandbox danger-full-access -C 'C:\repo path\builder-1' --add-dir 'C:\repo path\.git'"
    }

    It 'uses provider capability command metadata for launch commands' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-launch-tests-' + [guid]::NewGuid().ToString('N'))
        try {
            $registryDir = Join-Path $root '.winsmux'
            New-Item -ItemType Directory -Path $registryDir -Force | Out-Null
@'
{
  "version": 1,
  "providers": {
    "codex-nightly": {
      "adapter": "codex",
      "command": "C:\\Tools\\Codex Nightly\\codex.exe",
      "prompt_transports": ["argv", "file", "stdin"],
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

            $command = Get-AgentLaunchCommand -Agent 'codex-nightly' -Model 'gpt-5.4' -ProjectDir "C:\repo path\builder-1" -GitWorktreeDir "C:\repo path\.git" -RootPath $root

            $command | Should -Be "& 'C:\Tools\Codex Nightly\codex.exe' -c 'model=gpt-5.4' --sandbox danger-full-access -C 'C:\repo path\builder-1' --add-dir 'C:\repo path\.git'"
        } finally {
            if (Test-Path -LiteralPath $root) {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }
    }

    It 'quotes Codex model config as a single shell argument' {
        $command = Get-AgentLaunchCommand -Agent 'codex' -Model 'gpt 5.4;unsafe' -ProjectDir "C:\repo path\builder-1" -GitWorktreeDir "C:\repo path\.git"

        $command | Should -Be "codex -c 'model=gpt 5.4;unsafe' --sandbox danger-full-access -C 'C:\repo path\builder-1' --add-dir 'C:\repo path\.git'"
    }

    It 'returns a CLM workaround bootstrap for Codex worktree workers' {
        $builderPrompt = Get-AgentBootstrapPrompt -Agent 'codex' -Role 'Builder'
        $builderPrompt | Should -Match 'ConstrainedLanguageMode'
        $builderPrompt | Should -Match 'apply_patch'
        $builderPrompt | Should -Match 'cmd /c'

        $workerPrompt = Get-AgentBootstrapPrompt -Agent 'codex' -Role 'Worker'
        $workerPrompt | Should -Match 'ConstrainedLanguageMode'
        (Get-AgentBootstrapPrompt -Agent 'codex' -Role 'Reviewer') | Should -BeNullOrEmpty
        (Get-AgentBootstrapPrompt -Agent 'claude' -Role 'Builder') | Should -BeNullOrEmpty
    }

    It 'uses provider capability adapters for Codex bootstrap prompts' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-bootstrap-tests-' + [guid]::NewGuid().ToString('N'))
        try {
            $registryDir = Join-Path $root '.winsmux'
            New-Item -ItemType Directory -Path $registryDir -Force | Out-Null
@'
{
  "version": 1,
  "providers": {
    "codex-nightly": {
      "adapter": "codex",
      "command": "codex-nightly",
      "prompt_transports": ["argv", "file", "stdin"],
      "supports_parallel_runs": true,
      "supports_interrupt": true,
      "supports_structured_result": true,
      "supports_file_edit": true,
      "supports_subagents": true,
      "supports_verification": true,
      "supports_consultation": false
    },
    "claude-opus": {
      "adapter": "claude",
      "command": "claude",
      "prompt_transports": ["argv"],
      "supports_parallel_runs": false,
      "supports_interrupt": true,
      "supports_structured_result": false,
      "supports_file_edit": true,
      "supports_subagents": false,
      "supports_verification": false,
      "supports_consultation": true
    }
  }
}
'@ | Set-Content -Path (Join-Path $registryDir 'provider-capabilities.json') -Encoding UTF8

            $prompt = Get-AgentBootstrapPrompt -Agent 'codex-nightly' -Role 'Builder' -RootPath $root
            $prompt | Should -Match 'ConstrainedLanguageMode'
            $prompt | Should -Match 'apply_patch'

            Get-AgentBootstrapPrompt -Agent 'claude-opus' -Role 'Builder' -RootPath $root | Should -BeNullOrEmpty
        } finally {
            if (Test-Path -LiteralPath $root) {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }
    }
}

Describe 'manifest round-trip' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\manifest.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-ui-attach.ps1')
    }

    BeforeEach {
        $script:manifestTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-manifest-rt-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:manifestTempRoot -Force | Out-Null
    }

    AfterEach {
        if ($script:manifestTempRoot -and (Test-Path $script:manifestTempRoot)) {
            Remove-Item -Path $script:manifestTempRoot -Recurse -Force
        }
    }

    It 'creates, reads, updates panes, saves, and reads back correctly' {
        $manifest = New-WinsmuxManifest -ProjectDir $script:manifestTempRoot
        $manifest.version | Should -Be 1
        $manifest.panes.Count | Should -Be 0
        $manifest.saved_at | Should -Not -BeNullOrEmpty
        $manifest.session.started | Should -Not -BeNullOrEmpty

        $loaded = Get-WinsmuxManifest -ProjectDir $script:manifestTempRoot
        $loaded | Should -Not -BeNullOrEmpty
        $loaded.version | Should -Be 1

        $manifestPath = Get-ManifestPath -ProjectDir $script:manifestTempRoot
        $paneSummaries = @(
            [ordered]@{ Label = 'builder-1'; PaneId = '%2'; Role = 'Builder'; BuilderWorktreePath = 'C:\repo\.worktrees\builder-1' }
            [ordered]@{ Label = 'reviewer'; PaneId = '%4'; Role = 'Reviewer'; BuilderWorktreePath = '' }
        )
        Update-ManifestPanes -ManifestPath $manifestPath -PaneSummaries $paneSummaries

        $updated = Get-WinsmuxManifest -ProjectDir $script:manifestTempRoot
        $updated.panes.Count | Should -Be 2
        $updated.panes['builder-1'].pane_id | Should -Be '%2'
        $updated.panes['builder-1'].role | Should -Be 'Builder'
        $updated.panes['builder-1'].builder_worktree_path | Should -Be 'C:\repo\.worktrees\builder-1'
        $updated.panes['reviewer'].role | Should -Be 'Reviewer'
    }

    It 'parses legacy list-style pane entries and preserves extended session metadata' {
        New-Item -ItemType Directory -Path (Join-Path $script:manifestTempRoot '.winsmux') -Force | Out-Null

        Write-ManifestTextFile -Path (Get-ManifestPath -ProjectDir $script:manifestTempRoot) -Content @"
version: 1
saved_at: 2026-04-09T11:00:00+09:00
session:
  name: winsmux-orchestra
  status: running
  project_dir: $script:manifestTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    exec_mode: true
    launch_dir: C:\repo\.worktrees\builder-1
"@

        $loaded = Get-WinsmuxManifest -ProjectDir $script:manifestTempRoot

        $loaded.saved_at | Should -Be '2026-04-09T11:00:00+09:00'
        $loaded.session.name | Should -Be 'winsmux-orchestra'
        $loaded.session.status | Should -Be 'running'
        $loaded.panes['builder-1'].pane_id | Should -Be '%2'
        $loaded.panes['builder-1'].exec_mode | Should -Be 'true'
        $loaded.panes['builder-1'].launch_dir | Should -Be 'C:\repo\.worktrees\builder-1'
    }

    It 'round-trips structured session arrays such as attach adapter trace entries' {
        $manifest = [PSCustomObject]@{
            version  = 1
            saved_at = '2026-04-15T23:30:00+09:00'
            session  = [PSCustomObject]@{
                name              = 'winsmux-orchestra'
                status            = 'running'
                attach_request_id = 'req-123'
                attach_adapter_trace = @(
                    [pscustomobject]@{
                        sequence      = 1
                        host_kind     = 'windows-terminal'
                        launch_result = 'launch_unobserved'
                    },
                    [pscustomobject]@{
                        sequence      = 2
                        host_kind     = 'powershell-window'
                        launch_result = 'attach_confirmed'
                    }
                )
            }
            panes = [ordered]@{}
            tasks = [PSCustomObject]@{
                queued      = @()
                in_progress = @()
                completed   = @()
            }
            worktrees = [ordered]@{}
        }

        Save-WinsmuxManifest -ProjectDir $script:manifestTempRoot -Manifest $manifest
        $loaded = Get-WinsmuxManifest -ProjectDir $script:manifestTempRoot

        $loaded.session.attach_request_id | Should -Be 'req-123'
        $traceEntries = @(Get-OrchestraAttachTraceEntries -State $loaded.session)
        $traceEntries.Count | Should -Be 2
        $traceEntries[0].host_kind | Should -Be 'windows-terminal'
        $traceEntries[0].launch_result | Should -Be 'launch_unobserved'
        $traceEntries[1].host_kind | Should -Be 'powershell-window'
        $traceEntries[1].launch_result | Should -Be 'attach_confirmed'
    }

    It 'keeps multiline session scalar values on one YAML line' {
        $manifest = [PSCustomObject]@{
            version  = 1
            saved_at = '2026-05-12T20:50:00+09:00'
            session  = [PSCustomObject]@{
                name             = 'winsmux-orchestra'
                status           = 'running'
                ui_attach_reason = "Visible attach confirmed`nafter client identity changed."
            }
            panes = [ordered]@{}
            tasks = [PSCustomObject]@{
                queued      = @()
                in_progress = @()
                completed   = @()
            }
            worktrees = [ordered]@{}
        }

        Save-WinsmuxManifest -ProjectDir $script:manifestTempRoot -Manifest $manifest
        $content = Get-Content -Path (Get-ManifestPath -ProjectDir $script:manifestTempRoot) -Raw -Encoding UTF8
        $loaded = Get-WinsmuxManifest -ProjectDir $script:manifestTempRoot

        $content | Should -Match "ui_attach_reason: 'Visible attach confirmed after client identity changed\.'"
        $content | Should -Not -Match "ui_attach_reason: .*`r?`nafter client identity changed"
        $loaded.session.ui_attach_reason | Should -Be 'Visible attach confirmed after client identity changed.'
    }
}

Describe 'orchestra state model' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\manifest.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-state.ps1')
    }

    BeforeEach {
        $script:orchestraStateTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-orchestra-state-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:orchestraStateTempRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:orchestraStateTempRoot '.winsmux') -Force | Out-Null

        $manifest = [PSCustomObject]@{
            version  = 1
            saved_at = '2026-04-09T12:00:00+09:00'
            session  = [PSCustomObject]@{
                name        = 'winsmux-orchestra'
                project_dir = $script:orchestraStateTempRoot
            }
            panes = [ordered]@{
                'builder-1' = [ordered]@{
                    pane_id               = '%2'
                    role                  = 'Builder'
                    launch_dir            = $script:orchestraStateTempRoot
                    builder_worktree_path = $script:orchestraStateTempRoot
                    builder_branch        = 'codex/task-243'
                }
                'reviewer-1' = [ordered]@{
                    pane_id    = '%4'
                    role       = 'Reviewer'
                    launch_dir = $script:orchestraStateTempRoot
                }
            }
            tasks = [PSCustomObject]@{
                queued      = @()
                in_progress = @('id=task-243;builder=builder-1;task=Implement%20state%20model')
                completed   = @()
            }
            worktrees = [ordered]@{}
        }

        Save-WinsmuxManifest -ProjectDir $script:orchestraStateTempRoot -Manifest $manifest
        Write-WinsmuxTextFile -Path (Join-Path $script:orchestraStateTempRoot '.winsmux\review-state.json') -Content @"
{
  "codex/task-243": {
    "status": "PENDING",
    "request": {
      "branch": "codex/task-243",
      "head_sha": "abcdef1234567",
      "target_reviewer_pane_id": "%4",
      "target_reviewer_label": "reviewer-1"
    }
  }
}
"@
    }

    AfterEach {
        if ($script:orchestraStateTempRoot -and (Test-Path $script:orchestraStateTempRoot)) {
            Remove-Item -Path $script:orchestraStateTempRoot -Recurse -Force
        }
    }

    It 'merges task, review, branch, and changed files into pane state models and persists them to manifest' {
        Mock Get-OrchestraGitSnapshot {
            [ordered]@{
                branch             = 'codex/task-243'
                head_sha           = 'abcdef1234567'
                changed_file_count = 2
                changed_files      = @('winsmux-core/scripts/operator-poll.ps1', 'scripts/winsmux-core.ps1')
            }
        }

        $manifest = Get-WinsmuxManifest -ProjectDir $script:orchestraStateTempRoot
        $models = Sync-OrchestraPaneStateModels -ProjectDir $script:orchestraStateTempRoot -Manifest $manifest
        $builderModel = $models['builder-1']

        $builderModel.task_id | Should -Be 'task-243'
        $builderModel.task | Should -Be 'Implement state model'
        $builderModel.task_state | Should -Be 'in_progress'
        $builderModel.review_state | Should -Be 'PENDING'
        $builderModel.branch | Should -Be 'codex/task-243'
        $builderModel.head_sha | Should -Be 'abcdef1234567'
        $builderModel.changed_file_count | Should -Be 2
        $builderModel.changed_files | Should -Be @('winsmux-core/scripts/operator-poll.ps1', 'scripts/winsmux-core.ps1')

        $saved = Get-WinsmuxManifest -ProjectDir $script:orchestraStateTempRoot
        $saved.panes['builder-1'].task_id | Should -Be 'task-243'
        $saved.panes['builder-1'].task_state | Should -Be 'in_progress'
        $saved.panes['builder-1'].review_state | Should -Be 'PENDING'
        $saved.panes['builder-1'].branch | Should -Be 'codex/task-243'
        $saved.panes['builder-1'].head_sha | Should -Be 'abcdef1234567'
        $saved.panes['builder-1'].changed_file_count | Should -Be '2'
        $saved.panes['builder-1'].changed_files | Should -Be @('winsmux-core/scripts/operator-poll.ps1', 'scripts/winsmux-core.ps1')
    }

    It 'embeds first-class task, git, and review state in emitted event payloads' {
        $stateModel = [ordered]@{
            task_id            = 'task-243'
            task               = 'Implement state model'
            task_state         = 'in_progress'
            task_owner         = 'builder-1'
            branch             = 'codex/task-243'
            head_sha           = 'abcdef1234567'
            changed_file_count = 1
            changed_files      = @('winsmux-core/scripts/manifest.ps1')
            review_state       = 'PENDING'
        }

        $payload = Merge-OrchestraPaneEventData -StateModel $stateModel -Data ([ordered]@{ event_kind = 'pane.completed' })

        $payload.event_kind | Should -Be 'pane.completed'
        $payload.task.id | Should -Be 'task-243'
        $payload.task.text | Should -Be 'Implement state model'
        $payload.task.state | Should -Be 'in_progress'
        $payload.task.owner | Should -Be 'builder-1'
        $payload.git.branch | Should -Be 'codex/task-243'
        $payload.git.head_sha | Should -Be 'abcdef1234567'
        $payload.git.changed_files | Should -Be @('winsmux-core/scripts/manifest.ps1')
        $payload.review.state | Should -Be 'PENDING'
    }
}

Describe 'logger Initialize, Write, and Summary' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\logger.ps1')
    }

    BeforeEach {
        $script:loggerTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-logger-multi-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:loggerTempRoot -Force | Out-Null
    }

    AfterEach {
        if ($script:loggerTempRoot -and (Test-Path $script:loggerTempRoot)) {
            Remove-Item -Path $script:loggerTempRoot -Recurse -Force
        }
    }

    It 'initializes logger, writes entries, and reads them back as structured records' {
        $logPath = Initialize-OrchestraLogger -ProjectDir $script:loggerTempRoot -SessionName 'multi-agent-test'
        Test-Path $logPath | Should -Be $true

        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'multi-agent-test' -Event 'session.started' -Message 'orchestra booted' -Data ([ordered]@{ panes = 4 }) | Out-Null
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'multi-agent-test' -Event 'pane.started' -Role 'Builder' -PaneId '%2' -Target 'builder-1' -Data ([ordered]@{ agent = 'codex' }) | Out-Null
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'multi-agent-test' -Event 'review.failed' -Level 'warn' -Message 'lint errors' -Data ([ordered]@{ finding_count = 3 }) | Out-Null

        $records = Read-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'multi-agent-test'
        $records.Count | Should -Be 3
        $records[0].event | Should -Be 'session.started'
        $records[0].data.panes | Should -Be 4
        $records[1].role | Should -Be 'Builder'
        $records[1].target | Should -Be 'builder-1'
        $records[2].level | Should -Be 'warn'
        $records[2].data.finding_count | Should -Be 3
    }

    It 'produces a per-event count summary from log records' {
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'summary-test' -Event 'pane.started' | Out-Null
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'summary-test' -Event 'pane.started' | Out-Null
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'summary-test' -Event 'review.passed' | Out-Null
        Write-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'summary-test' -Event 'session.ended' | Out-Null

        $records = Read-OrchestraLog -ProjectDir $script:loggerTempRoot -SessionName 'summary-test'
        $summary = @{}
        foreach ($record in $records) {
            $eventName = $record.event
            if ($summary.ContainsKey($eventName)) {
                $summary[$eventName]++
            } else {
                $summary[$eventName] = 1
            }
        }

        $summary['pane.started'] | Should -Be 2
        $summary['review.passed'] | Should -Be 1
        $summary['session.ended'] | Should -Be 1
        $summary.Count | Should -Be 3
    }
}

Describe 'agent monitor idle alerts' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\agent-monitor.ps1')
    }

    BeforeEach {
        $script:agentMonitorTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-agent-monitor-tests-' + [guid]::NewGuid().ToString('N'))
        $script:agentMonitorIdleStateDir = Join-Path $script:agentMonitorTempRoot 'idle'
        New-Item -ItemType Directory -Path $script:agentMonitorTempRoot -Force | Out-Null
        $script:IdleStateDir = $script:agentMonitorIdleStateDir
        Mock Send-MonitorOperatorMailboxMessage { return $true }
    }

    AfterEach {
        if ($script:agentMonitorTempRoot -and (Test-Path $script:agentMonitorTempRoot)) {
            Remove-Item -Path $script:agentMonitorTempRoot -Recurse -Force
        }
    }

    It 'alerts only once after a pane stays ready past the idle threshold' {
        $start = [datetime]'2026-04-05T10:00:00+09:00'

        $initial = Update-MonitorIdleAlertState -PaneId '%2' -Label 'builder-1' -Role 'Builder' -Status 'ready' -SnapshotTail '> ' -IdleThresholdSeconds 120 -Now $start
        $initial.ShouldAlert | Should -Be $false

        $alert = Update-MonitorIdleAlertState -PaneId '%2' -Label 'builder-1' -Role 'Builder' -Status 'ready' -SnapshotTail '> ' -IdleThresholdSeconds 120 -Now $start.AddSeconds(121)
        $alert.ShouldAlert | Should -Be $true
        $alert.Message | Should -Match 'Operator alert: idle pane builder-1 \(%2, role=Builder\)'

        $repeat = Update-MonitorIdleAlertState -PaneId '%2' -Label 'builder-1' -Role 'Builder' -Status 'ready' -SnapshotTail '> ' -IdleThresholdSeconds 120 -Now $start.AddSeconds(240)
        $repeat.ShouldAlert | Should -Be $false
    }

    It 'clears idle tracking once the pane is no longer ready' {
        $start = [datetime]'2026-04-05T11:00:00+09:00'

        Update-MonitorIdleAlertState -PaneId '%3' -Label 'reviewer-1' -Role 'Reviewer' -Status 'ready' -SnapshotTail '> ' -IdleThresholdSeconds 120 -Now $start | Out-Null
        Update-MonitorIdleAlertState -PaneId '%3' -Label 'reviewer-1' -Role 'Reviewer' -Status 'busy' -SnapshotTail 'working' -IdleThresholdSeconds 120 -Now $start.AddSeconds(60) | Out-Null

        $stateAfterBusy = Get-MonitorIdleState -PaneId '%3'
        $stateAfterBusy | Should -BeNullOrEmpty
    }

    It 'emits operator alerts to stdout and monitor events during a monitor cycle' {
        $manifestDir = Join-Path $script:agentMonitorTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
        @"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:agentMonitorTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: $script:agentMonitorTempRoot
"@ | Set-Content -Path (Join-Path $manifestDir 'manifest.yaml') -Encoding UTF8

        Save-MonitorIdleState -PaneId '%2' -ReadySince '2026-04-05T09:57:00+09:00' -AlertSent $false
        Mock Get-PaneAgentStatus {
            [ordered]@{
                Status       = 'ready'
                PaneId       = '%2'
                SnapshotTail = '> '
            }
        }
        Mock Write-MonitorEvent {
            return [ordered]@{
                event   = $Event
                message = $Message
            }
        }

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            roles = [ordered]@{}
        }

        $output = @(Invoke-AgentMonitorCycle -Settings $settings -ManifestPath (Join-Path $manifestDir 'manifest.yaml') -SessionName 'winsmux-orchestra' -IdleThreshold 120)

        $output.Count | Should -Be 2
        $output[0] | Should -Match 'Operator alert: idle pane builder-1 \(%2, role=Builder\)'
        $output[1].IdleAlerts | Should -Be 1
        $output[1].Results[0].IdleAlerted | Should -Be $true
        $output[1].Results[0].Message | Should -Match 'Operator alert: idle pane builder-1'
        Should -Invoke Write-MonitorEvent -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'pane.idle' -and
            $PaneId -eq '%2' -and
            $Role -eq 'Builder' -and
            $Message -match 'Operator alert: idle pane builder-1'
        }
        Should -Invoke Send-MonitorOperatorMailboxMessage -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'pane.idle' -and
            $Label -eq 'builder-1' -and
            $PaneId -eq '%2'
        }
    }

    It 'reads dict-style pane manifests during a monitor cycle' {
        $manifestDir = Join-Path $script:agentMonitorTempRoot '.winsmux'
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
        Write-WinsmuxTextFile -Path $manifestPath -Content @"
version: 1
saved_at: 2026-04-09T11:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:agentMonitorTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    launch_dir: $script:agentMonitorTempRoot
"@

        Save-MonitorIdleState -PaneId '%2' -ReadySince '2026-04-05T09:57:00+09:00' -AlertSent $false
        Mock Get-PaneAgentStatus {
            [ordered]@{
                Status       = 'ready'
                PaneId       = '%2'
                SnapshotTail = '> '
            }
        }
        Mock Write-MonitorEvent {
            return [ordered]@{
                event   = $Event
                message = $Message
            }
        }

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            roles = [ordered]@{}
        }

        $output = @(Invoke-AgentMonitorCycle -Settings $settings -ManifestPath $manifestPath -SessionName 'winsmux-orchestra' -IdleThreshold 120)

        $output.Count | Should -Be 2
        $output[0] | Should -Match 'Operator alert: idle pane builder-1 \(%2, role=Builder\)'
        $output[1].IdleAlerts | Should -Be 1
        $output[1].Results[0].Label | Should -Be 'builder-1'
        Should -Invoke Write-MonitorEvent -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'pane.idle' -and
            $Label -eq 'builder-1' -and
            $PaneId -eq '%2'
        }
    }

    It 'emits approval waiting alerts and counts them during a monitor cycle' {
        $manifestDir = Join-Path $script:agentMonitorTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
        @"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:agentMonitorTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: $script:agentMonitorTempRoot
"@ | Set-Content -Path (Join-Path $manifestDir 'manifest.yaml') -Encoding UTF8

        Mock Get-PaneAgentStatus {
            [ordered]@{
                Status       = 'approval_waiting'
                PaneId       = '%2'
                SnapshotTail = 'Do you want to allow this command?'
                SnapshotHash = 'approval-hash'
                ExitReason   = ''
            }
        }
        Mock Write-MonitorEvent {
            return [ordered]@{
                event   = $Event
                message = $Message
            }
        }

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            roles = [ordered]@{}
        }

        $output = @(Invoke-AgentMonitorCycle -Settings $settings -ManifestPath (Join-Path $manifestDir 'manifest.yaml') -SessionName 'winsmux-orchestra' -IdleThreshold 120)

        $output.Count | Should -Be 2
        $output[0] | Should -Be 'Operator alert: builder-1 (%2) awaiting approval'
        $output[1].ApprovalWaiting | Should -Be 1
        $output[1].Results[0].Status | Should -Be 'approval_waiting'
        $output[1].Results[0].Message | Should -Be 'Operator alert: builder-1 (%2) awaiting approval'
        Should -Invoke Write-MonitorEvent -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'pane.approval_waiting' -and
            $PaneId -eq '%2' -and
            $Role -eq 'Builder' -and
            $Message -eq 'Pane builder-1 (%2) awaiting approval.'
        }
    }

    It 'auto-approves trust prompts during a monitor cycle' {
        $manifestDir = Join-Path $script:agentMonitorTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
        @"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:agentMonitorTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: $script:agentMonitorTempRoot
"@ | Set-Content -Path (Join-Path $manifestDir 'manifest.yaml') -Encoding UTF8

        Mock Get-PaneAgentStatus {
            [ordered]@{
                Status         = 'approval_waiting'
                PaneId         = '%2'
                SnapshotTail   = 'Trust this folder? Enter to confirm'
                SnapshotHash   = 'approval-hash'
                ApprovalAction = 'enter'
                ExitReason     = ''
            }
        }
        Mock Invoke-MonitorAutoApprovePrompt {
            [ordered]@{
                Success = $true
                PaneId  = '%2'
                Message = 'Auto-approved trust prompt in pane %2'
            }
        }
        Mock Write-MonitorEvent {
            return [ordered]@{
                event   = $Event
                message = $Message
            }
        }

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            roles = [ordered]@{}
        }

        $output = @(Invoke-AgentMonitorCycle -Settings $settings -ManifestPath (Join-Path $manifestDir 'manifest.yaml') -SessionName 'winsmux-orchestra' -IdleThreshold 120)

        $output.Count | Should -Be 2
        $output[0] | Should -Be 'Auto-approved trust prompt in pane %2'
        $output[1].ApprovalWaiting | Should -Be 1
        $output[1].Results[0].Status | Should -Be 'approval_waiting'
        $output[1].Results[0].Message | Should -Be 'Auto-approved trust prompt in pane %2'
        Should -Invoke Invoke-MonitorAutoApprovePrompt -Times 1 -Exactly
        Should -Invoke Write-MonitorEvent -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'pane.approval_waiting' -and
            $PaneId -eq '%2' -and
            $Role -eq 'Builder' -and
            $Message -eq 'Pane builder-1 (%2) awaiting approval.'
        }
    }

    It 'emits operator alerts when a Builder stays busy with the same snapshot for three cycles' {
        $script:BuilderStallHistory = @{}
        $manifestDir = Join-Path $script:agentMonitorTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
        @"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:agentMonitorTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: $script:agentMonitorTempRoot
"@ | Set-Content -Path (Join-Path $manifestDir 'manifest.yaml') -Encoding UTF8

        Mock Get-PaneAgentStatus {
            [ordered]@{
                Status       = 'busy'
                PaneId       = '%2'
                SnapshotTail = 'working'
                SnapshotHash = 'stall-hash'
                ExitReason   = ''
            }
        }
        Mock Write-MonitorEvent {
            return [ordered]@{
                event   = $Event
                message = $Message
            }
        }

        $settings = [ordered]@{
            agent = 'codex'
            model = 'gpt-5.4'
            roles = [ordered]@{}
        }

        @(Invoke-AgentMonitorCycle -Settings $settings -ManifestPath (Join-Path $manifestDir 'manifest.yaml') -SessionName 'winsmux-orchestra' -IdleThreshold 120) | Out-Null
        @(Invoke-AgentMonitorCycle -Settings $settings -ManifestPath (Join-Path $manifestDir 'manifest.yaml') -SessionName 'winsmux-orchestra' -IdleThreshold 120) | Out-Null
        $output = @(Invoke-AgentMonitorCycle -Settings $settings -ManifestPath (Join-Path $manifestDir 'manifest.yaml') -SessionName 'winsmux-orchestra' -IdleThreshold 120)

        $output.Count | Should -Be 2
        $output[0] | Should -Match 'Operator alert: stalled Builder pane builder-1 \(%2\)'
        $output[1].Stalls | Should -Be 1
        $output[1].Results[0].StallDetected | Should -Be $true
        $output[1].Results[0].Message | Should -Match 'Operator alert: stalled Builder pane builder-1'
        Should -Invoke Write-MonitorEvent -Times 1 -Exactly -ParameterFilter {
            $Event -eq 'pane.stalled' -and
            $PaneId -eq '%2' -and
            $Role -eq 'Builder' -and
            $Message -match 'Operator alert: stalled Builder pane builder-1'
        }
    }

    It 'appends monitor events as jsonl records' {
        $eventsPath = Get-MonitorEventsPath -ProjectDir $script:agentMonitorTempRoot

        Write-MonitorEvent -ProjectDir $script:agentMonitorTempRoot -SessionName 'winsmux-orchestra' -Event 'pane.idle' -Message 'idle alert' -Label 'builder-1' -PaneId '%2' -Role 'Builder' -Status 'ready' | Out-Null
        Write-MonitorEvent -ProjectDir $script:agentMonitorTempRoot -SessionName 'winsmux-orchestra' -Event 'pane.stalled' -Message 'stall alert' -Label 'builder-1' -PaneId '%2' -Role 'Builder' -Status 'busy' | Out-Null

        $lines = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 2

        $first = $lines[0] | ConvertFrom-Json
        $second = $lines[1] | ConvertFrom-Json

        $first.event | Should -Be 'pane.idle'
        $first.label | Should -Be 'builder-1'
        $second.event | Should -Be 'pane.stalled'
        $second.status | Should -Be 'busy'
    }
}
