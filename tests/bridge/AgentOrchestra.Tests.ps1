$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'TASK659 declarative orchestra layout' -Tag 'task659-application' {
    BeforeAll {
        $script:task659LayoutPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-layout.ps1'
    }

    BeforeEach {
        Mock Start-Sleep { }
        $env:WINSMUX_BIN = 'winsmux'
        $global:task659PaneIds = @('%2')
        $global:task659LayoutCalls = [System.Collections.Generic.List[string]]::new()
    }

    AfterEach {
        Remove-Item Function:\global:winsmux -ErrorAction SilentlyContinue
        Remove-Item Env:\WINSMUX_BIN -ErrorAction SilentlyContinue
    }

    It 'creates first-occurrence region columns and declaration-order rows with slot labels' {
        $applicationLayout = [ordered]@{
            schema_version = 1
            columns = @(
                [ordered]@{
                    region = 'main'
                    panes = @(
                        [ordered]@{ pane_key = 'implement'; workflow_role = 'implementer'; slot_id = 'worker-1'; worktree = [ordered]@{ mode = 'managed'; name = 'task-659-implement' } },
                        [ordered]@{ pane_key = 'inspect'; workflow_role = 'researcher'; slot_id = 'worker-2'; worktree = [ordered]@{ mode = 'read-only-reference' } }
                    )
                },
                [ordered]@{
                    region = 'side'
                    panes = @(
                        [ordered]@{ pane_key = 'verify'; workflow_role = 'verifier'; slot_id = 'reviewer-1'; worktree = [ordered]@{ mode = 'read-only-reference' } }
                    )
                }
            )
        }

        function global:winsmux {
            $global:LASTEXITCODE = 0
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            $global:task659LayoutCalls.Add($commandLine) | Out-Null
            switch -Regex ($commandLine) {
                '^has-session ' { return @() }
                '^new-window ' { return '@1 %2' }
                '^set-option ' { return @() }
                '^display-message -t %2 -p #\{window_id\}$' { return '@1' }
                '^display-message -t %2 -p #\{pane_width\}x#\{pane_height\}$' { return '120x40' }
                '^split-window -t %2 -h -p 50$' { $global:task659PaneIds = @('%2', '%3'); return @() }
                '^split-window -t %2 -v -p 50$' { $global:task659PaneIds = @('%2', '%3', '%4'); return @() }
                '^list-panes -t @1 -F #\{pane_id\}$' { return $global:task659PaneIds }
                '^list-panes -t @1 -F #\{pane_id\},#\{pane_left\},#\{pane_top\}$' {
                    if ($global:task659PaneIds.Count -eq 2) { return @('%3,60,0', '%2,0,0') }
                    return @('%4,0,20', '%3,60,0', '%2,0,0')
                }
                '^select-pane -t %2 -T worker-1$' { return @() }
                '^select-pane -t %4 -T worker-2$' { return @() }
                '^select-pane -t %3 -T reviewer-1$' { return @() }
                '^select-pane -t %2$' { return @() }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = & $script:task659LayoutPath -SessionName 'winsmux-orchestra' -ApplicationLayout $applicationLayout

        $result.Total | Should -Be 3
        $result.Columns | Should -Be 2
        @($result.Panes | ForEach-Object SlotId) | Should -Be @('worker-1', 'worker-2', 'reviewer-1')
        @($result.Panes | ForEach-Object PaneKey) | Should -Be @('implement', 'inspect', 'verify')
        @($result.Panes | ForEach-Object WorkflowRole) | Should -Be @('implementer', 'researcher', 'verifier')
        @($global:task659LayoutCalls) | Should -Contain 'split-window -t %2 -h -p 50'
        @($global:task659LayoutCalls) | Should -Contain 'split-window -t %2 -v -p 50'
    }
}

Describe 'agent-monitor helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\agent-monitor.ps1')
    }

    BeforeEach {
        Mock Send-MonitorOperatorMailboxMessage { return $true }
    }

    It 'TASK781 C19 threads the respawn snapshot generation into its label update' {
        $script:capturedMonitorGeneration = ''
        Mock Test-Path { $true }
        Mock Get-PaneControlManifestContext {
            [pscustomobject]@{ GenerationId = 'generation-replacement' }
        }
        Mock Set-PaneControlManifestPaneProperties {
            param($ManifestPath, $PaneId, $Properties, $ExpectedGenerationId)
            $script:capturedMonitorGeneration = [string]$ExpectedGenerationId
        }

        Update-MonitorManifestPaneLabel -ManifestPath 'C:\repo\.winsmux\manifest.yaml' -PaneId '%2' `
            -Label 'builder-2' -ExpectedGenerationId 'generation-initial' | Should -BeTrue

        $script:capturedMonitorGeneration | Should -BeExactly 'generation-initial'
        Should -Invoke Get-PaneControlManifestContext -Times 0 -Exactly
    }

    It 'TASK781 C19 carries the cycle generation through the production respawn caller' {
        $manifestPath = Join-Path $TestDrive 'respawn-manifest.yaml'
        'invalid-but-existing' | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $script:respawnCallerGeneration = ''
        Mock Invoke-MonitorWinsmux { }
        Mock Wait-MonitorPaneShellReady { }
        Mock Send-MonitorBridgeCommand { }
        Mock Start-Sleep { }
        Mock Get-PaneAgentStatus {
            [pscustomobject]@{ Status = 'ready'; PaneId = '%2'; SnapshotTail = ''; ExitReason = '' }
        }
        Mock Get-MonitorPaneTitle { 'builder-2' }
        Mock Get-PaneControlManifestContext {
            [pscustomobject]@{ GenerationId = 'generation-replacement' }
        }
        Mock Update-MonitorManifestPaneLabel {
            $script:respawnCallerGeneration = [string]$ExpectedGenerationId
            return $true
        }

        $result = Invoke-AgentRespawn -PaneId '%2' -Agent 'codex' -Model 'gpt-5.4' `
            -ProjectDir $TestDrive -GitWorktreeDir (Join-Path $TestDrive '.git\worktrees\builder-2') `
            -RootPath $TestDrive -ManifestPath $manifestPath -ExpectedGenerationId 'generation-initial' `
            -ReadyTimeoutSeconds 1

        $result.Success | Should -BeTrue
        $script:respawnCallerGeneration | Should -BeExactly 'generation-initial'
        Should -Invoke Get-PaneControlManifestContext -Times 0 -Exactly
    }

    It 'builds v2 mailbox envelope metadata before sending monitor messages' {
        $payload = New-MonitorOperatorMailboxPayload `
            -SessionName 'winsmux-orchestra' `
            -Event 'pane.idle' `
            -Message 'worker idle' `
            -Label 'worker-1' `
            -PaneId '%2' `
            -Role 'Worker' `
            -Status 'ready' `
            -Data ([ordered]@{ idle_threshold_seconds = 120 })

        $payload.mailbox_version | Should -Be 2
        $payload.message_type | Should -Be 'share'
        $payload.state | Should -Be 'created'
        $payload.idempotency_key | Should -Match '^mailbox:v2:winsmux-orchestra:worker-1:pane.idle:'
        $payload.message_id | Should -Not -BeNullOrEmpty
        $payload.correlation_id | Should -Be $payload.message_id
        $payload.causation_id | Should -BeNullOrEmpty
        $payload.ttl_seconds | Should -BeGreaterThan 0
        $payload.ack_required | Should -Be $true
        $payload.content.event | Should -Be 'pane.idle'
        $payload.content.data.idle_threshold_seconds | Should -Be 120
        ($payload | ConvertTo-Json -Depth 8) | Should -Not -Match 'raw_transcript'
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

    It 'keeps context reset disabled for non-Codex adapters even when provider metadata opts in' {
        $slotAgentConfig = [PSCustomObject]@{
            Agent                        = 'claude'
            SupportsContextReset         = $true
            SupportsContextResetDeclared = $true
        }

        $eligible = Test-MonitorContextResetEligible `
            -SlotAgentConfig $slotAgentConfig `
            -StatusAgentName 'claude' `
            -ManifestCapabilityAdapter 'claude' `
            -ManifestProviderTarget 'claude:sonnet'

        $eligible | Should -Be $false
    }

    It 'keeps caller-facing monitor bridge arguments at prompt delivery' {
        $arguments = @(New-MonitorBridgeSendArguments `
            -PaneId '%2' `
            -Text 'codex -C C:\repo')

        $arguments | Should -Be @(
            'send',
            '%2',
            'codex -C C:\repo'
        )
        $arguments | Should -Not -Contain '--delivery-class'
    }

    It 'delivers monitor launch commands in-process without bridge argv' {
        Mock Invoke-MonitorWinsmux { }

        Send-MonitorBridgeCommand `
            -PaneId '%2' `
            -Text 'codex -C C:\repo' `
            -DeliveryClass 'launch'

        Should -Invoke Invoke-MonitorWinsmux -Times 1 -Exactly -ParameterFilter {
            @($Arguments) -join '|' -eq 'send-keys|-t|%2|-l|--|codex -C C:\repo'
        }
        Should -Invoke Invoke-MonitorWinsmux -Times 1 -Exactly -ParameterFilter {
            @($Arguments) -join '|' -eq 'send-keys|-t|%2|Enter'
        }
    }

    It 'chunks oversized monitor launch commands before one immediate submit' {
        $script:monitorLaunchCalls = [System.Collections.Generic.List[object]]::new()
        $launchCommand = 'codex ' + ('x' * 4001)
        Mock New-MonitorBridgeSendArguments { throw 'launch delivery must not build public bridge argv' }
        Mock Invoke-MonitorWinsmux {
            $script:monitorLaunchCalls.Add(@($Arguments)) | Out-Null
        }

        Send-MonitorBridgeCommand `
            -PaneId '%2' `
            -Text $launchCommand `
            -DeliveryClass 'launch'

        $literalCalls = @($script:monitorLaunchCalls | Where-Object { $_[3] -eq '-l' })
        $literalCalls.Count | Should -BeGreaterThan 1
        (($literalCalls | ForEach-Object { [string]$_[5] }) -join '') | Should -BeExactly $launchCommand
        @($script:monitorLaunchCalls[-1]) | Should -Be @('send-keys', '-t', '%2', 'Enter')
        Should -Invoke New-MonitorBridgeSendArguments -Times 0 -Exactly
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
            $Text -eq "codex -c 'model=gpt-5.4' --sandbox danger-full-access -C 'C:\repo\.worktrees\builder-1' --add-dir 'C:\repo\.git\worktrees\builder-1'" -and
            $DeliveryClass -eq 'launch'
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
      "supports_consultation": false,
      "supports_context_reset": true
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
                $Text -match "^codex-nightly -c 'model=gpt-5\.4-nightly'" -and
                $DeliveryClass -eq 'launch'
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
    capability_adapter: codex
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

    It 'does not reset context when provider metadata is missing' {
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
  - label: worker-1
    pane_id: %2
    role: Worker
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
                    SnapshotHash = 'hash-worker'
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
                agent = 'custom-agent'
                model = 'custom-model'
                roles = [ordered]@{}
            }) -ManifestPath $manifestPath -SessionName 'winsmux-orchestra'

            $result.ContextResets | Should -Be 0
            $result.Results.Count | Should -Be 1
            $result.Results[0].ContextReset | Should -Be $false
            Should -Invoke Send-MonitorBridgeCommand -Times 0 -Exactly
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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\agent-watchdog.ps1')
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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\server-watchdog.ps1')
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

    It 'does not restart an existing session on unhealthy strict health' {
        $state = New-ServerWatchdogState

        Mock Get-ServerWatchdogHealthStatus { 'Unhealthy' }
        Mock Invoke-ServerWatchdogWinsmux {
            throw 'restart should not run for unhealthy strict health'
        } -ParameterFilter {
            $AllowFailure -and $Arguments[0] -eq 'new-session'
        }

        $result = Invoke-ServerWatchdogCycle -ManifestPath $script:serverWatchdogManifestPath -SessionName 'winsmux-orchestra' -State $state

        $result.SessionAlive | Should -Be $true
        $result.RestartAttempted | Should -Be $false
        $result.RestartSucceeded | Should -Be $false
        $result.HealthStatus | Should -Be 'Unhealthy'
        $result.Event | Should -Be 'server.healthcheck_failed'
        $state.RestartAttempts.Count | Should -Be 0
        Should -Invoke Invoke-ServerWatchdogWinsmux -Times 0 -Exactly -ParameterFilter {
            $AllowFailure -and $Arguments[0] -eq 'new-session'
        }

        $eventsPath = Join-Path $script:serverWatchdogTempRoot '.winsmux\events.jsonl'
        $events = @(Get-Content -Path $eventsPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $events.Count | Should -Be 1
        $events[0].event | Should -Be 'server.healthcheck_failed'
        $events[0].status | Should -Be 'warning'
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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-preflight.ps1')

        function New-C66ServerProcessSnapshot {
            param([switch]$IncludeServer)

            $processes = @()
            $byId = @{}
            if ($IncludeServer) {
                $server = [PSCustomObject]@{
                    ProcessId       = 41001
                    ParentProcessId = 0
                    Name            = 'winsmux.exe'
                    CommandLine     = 'winsmux server -s winsmux-orchestra'
                    ExecutablePath  = 'C:\tools\winsmux.exe'
                }
                $processes = @($server)
                $byId[41001] = $server
            }
            return [PSCustomObject]@{
                Processes        = $processes
                ById             = $byId
                ChildrenByParent = @{}
            }
        }
    }

    It 'TASK781 C66 propagates a matched server stop failure even when the session is absent' {
        $snapshot = New-C66ServerProcessSnapshot -IncludeServer
        Mock Stop-Process { throw 'synthetic access denied' }

        {
            Remove-OrchestraSessionServerProcesses `
                -SessionName 'winsmux-orchestra' `
                -WinsmuxBin 'C:\tools\winsmux.exe' `
                -IncludeExpectedBinary `
                -ProcessSnapshot $snapshot `
                -PostStopSnapshotResolver { New-C66ServerProcessSnapshot }
        } | Should -Throw '*synthetic access denied*'
    }

    It 'TASK781 C66 rejects a matched server that remains after a successful stop request' {
        $snapshot = New-C66ServerProcessSnapshot -IncludeServer
        Mock Stop-Process { }

        {
            Remove-OrchestraSessionServerProcesses `
                -SessionName 'winsmux-orchestra' `
                -WinsmuxBin 'C:\tools\winsmux.exe' `
                -IncludeExpectedBinary `
                -ProcessSnapshot $snapshot `
                -PostStopSnapshotResolver { New-C66ServerProcessSnapshot -IncludeServer } `
                -VerificationAttempts 1 `
                -VerificationIntervalMilliseconds 0
        } | Should -Throw '*server processes remain*'
    }

    It 'TASK781 C66 rejects a matching server that appears after an initially empty snapshot' {
        Mock Stop-Process { throw 'no stop should occur for the empty initial snapshot' }

        {
            Remove-OrchestraSessionServerProcesses `
                -SessionName 'winsmux-orchestra' `
                -WinsmuxBin 'C:\tools\winsmux.exe' `
                -IncludeExpectedBinary `
                -ProcessSnapshot (New-C66ServerProcessSnapshot) `
                -PostStopSnapshotResolver { New-C66ServerProcessSnapshot -IncludeServer } `
                -VerificationAttempts 1 `
                -VerificationIntervalMilliseconds 0
        } | Should -Throw '*server processes remain*'
    }

    It 'TASK781 C66 succeeds only after a fresh snapshot proves matching server absence' {
        $snapshot = New-C66ServerProcessSnapshot -IncludeServer
        Mock Stop-Process { }

        $result = Remove-OrchestraSessionServerProcesses `
            -SessionName 'winsmux-orchestra' `
            -WinsmuxBin 'C:\tools\winsmux.exe' `
            -IncludeExpectedBinary `
            -ProcessSnapshot $snapshot `
            -PostStopSnapshotResolver { New-C66ServerProcessSnapshot } `
            -VerificationAttempts 1 `
            -VerificationIntervalMilliseconds 0

        @($result.SessionProcesses).Count | Should -Be 1
        @($result.Killed).Count | Should -Be 1
        @($result.RemainingSessionProcesses).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
    }

    It 'isolates stale session server matching to the resolved bridge namespace' {
        $previousNamespace = $env:WINSMUX_BRIDGE_NAMESPACE_L
        $previousSocket = $env:WINSMUX_BRIDGE_SOCKET_S
        $previousSessionNamespace = $env:WINSMUX_BRIDGE_SESSION_NAMESPACE
        try {
            $env:WINSMUX_BRIDGE_SESSION_NAMESPACE = 'task781-smoke-20260715'
            $env:WINSMUX_BRIDGE_SOCKET_S = 'lower-priority-socket'
            $env:WINSMUX_BRIDGE_NAMESPACE_L = 'lower-priority-L'
            $matching = [pscustomobject]@{ Name = 'winsmux.exe'; CommandLine = 'winsmux server -s winsmux-orchestra -L task781-smoke-20260715' }
            $different = [pscustomobject]@{ Name = 'winsmux.exe'; CommandLine = 'winsmux server -s winsmux-orchestra -L other-namespace' }
            $missing = [pscustomobject]@{ Name = 'winsmux.exe'; CommandLine = 'winsmux server -s winsmux-orchestra' }

            (Test-OrchestraSessionServerProcess -Process $matching -SessionName 'winsmux-orchestra') | Should -BeTrue
            (Test-OrchestraSessionServerProcess -Process $different -SessionName 'winsmux-orchestra') | Should -BeFalse
            (Test-OrchestraSessionServerProcess -Process $missing -SessionName 'winsmux-orchestra') | Should -BeFalse

            Remove-Item Env:\WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue
            Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
            Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
            (Test-OrchestraSessionServerProcess -Process $missing -SessionName 'winsmux-orchestra') | Should -BeTrue
            (Test-OrchestraSessionServerProcess -Process $matching -SessionName 'winsmux-orchestra') | Should -BeFalse
        } finally {
            if ($null -eq $previousNamespace) { Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue } else { $env:WINSMUX_BRIDGE_NAMESPACE_L = $previousNamespace }
            if ($null -eq $previousSocket) { Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue } else { $env:WINSMUX_BRIDGE_SOCKET_S = $previousSocket }
            if ($null -eq $previousSessionNamespace) { Remove-Item Env:\WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue } else { $env:WINSMUX_BRIDGE_SESSION_NAMESPACE = $previousSessionNamespace }
        }
    }

    It 'TASK781 C41 resolves server socket selectors before namespace comparison' {
        $matchingNamespace = Get-WinsmuxSocketNamespaceBase -SocketSelector 'C:\tmp\task781.sock'

        (Test-OrchestraServerProcessNamespace `
            -CommandLine 'winsmux -S "C:\tmp\task781.sock" server -s winsmux-orchestra' `
            -Namespace $matchingNamespace) | Should -BeTrue
        (Test-OrchestraServerProcessNamespace `
            -CommandLine 'winsmux -S "C:\tmp\other.sock" server -s winsmux-orchestra' `
            -Namespace $matchingNamespace) | Should -BeFalse
        (Test-OrchestraServerProcessNamespace `
            -CommandLine 'winsmux -S "C:\tmp\task781.sock" server -s winsmux-orchestra' `
            -Namespace '') | Should -BeFalse
        (Test-OrchestraServerProcessNamespace `
            -CommandLine 'winsmux server -s winsmux-orchestra -- tool -S "C:\tmp\task781.sock"' `
            -Namespace '') | Should -BeTrue
    }

    It 'rejects server option lookalike <Case>' -ForEach @(
        @{
            Case = 'namespace option after raw command separator'
            CommandLine = 'winsmux server -s winsmux-orchestra -- tool -L task781-smoke-20260715'
        }
        @{
            Case = 'session name prefix collision'
            CommandLine = 'winsmux server -s winsmux-orchestra-other -L task781-smoke-20260715'
        }
        @{
            Case = 'server subcommand prefix collision'
            CommandLine = 'winsmux server-helper -s winsmux-orchestra -L task781-smoke-20260715'
        }
        @{
            Case = 'duplicate identical session selectors'
            CommandLine = 'winsmux server -s winsmux-orchestra --session winsmux-orchestra -L task781-smoke-20260715'
        }
        @{
            Case = 'conflicting session selectors'
            CommandLine = 'winsmux server -s winsmux-orchestra --session other-session -L task781-smoke-20260715'
        }
        @{
            Case = 'conflicting socket and literal namespace selectors'
            CommandLine = 'winsmux -S task781-smoke-20260715 -L task781-smoke-20260715 server -s winsmux-orchestra'
        }
        @{
            Case = 'duplicate literal namespace selectors'
            CommandLine = 'winsmux server -s winsmux-orchestra -L task781-smoke-20260715 -L task781-smoke-20260715'
        }
        @{
            Case = 'quoted raw separator text before a conflicting selector'
            CommandLine = 'winsmux server -s winsmux-orchestra -L task781-smoke-20260715 --flag "value -- payload" --session other-session'
        }
        @{
            Case = 'unmatched quote after raw command separator'
            CommandLine = 'winsmux server -s winsmux-orchestra -L task781-smoke-20260715 -- tool "unterminated'
        }
    ) {
        $previousNamespace = $env:WINSMUX_BRIDGE_SESSION_NAMESPACE
        $previousSocket = $env:WINSMUX_BRIDGE_SOCKET_S
        $previousNamespaceL = $env:WINSMUX_BRIDGE_NAMESPACE_L
        try {
            $env:WINSMUX_BRIDGE_SESSION_NAMESPACE = 'task781-smoke-20260715'
            Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
            Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
            $process = [pscustomobject]@{ Name = 'winsmux.exe'; CommandLine = $CommandLine }

            (Test-OrchestraSessionServerProcess -Process $process -SessionName 'winsmux-orchestra') | Should -BeFalse
        } finally {
            if ($null -eq $previousNamespace) { Remove-Item Env:\WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue } else { $env:WINSMUX_BRIDGE_SESSION_NAMESPACE = $previousNamespace }
            if ($null -eq $previousSocket) { Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue } else { $env:WINSMUX_BRIDGE_SOCKET_S = $previousSocket }
            if ($null -eq $previousNamespaceL) { Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue } else { $env:WINSMUX_BRIDGE_NAMESPACE_L = $previousNamespaceL }
        }
    }

    It 'TASK781 C41 never stops a server hidden by quoted raw separator text' {
        $previousNamespace = $env:WINSMUX_BRIDGE_SESSION_NAMESPACE
        $server = [pscustomobject]@{
            ProcessId = 41002; ParentProcessId = 0; Name = 'winsmux.exe'
            CommandLine = 'winsmux server -s winsmux-orchestra -L task781-smoke-20260715 --flag "value -- payload" --session other-session'
            ExecutablePath = 'C:\tools\winsmux.exe'
        }
        $snapshot = [pscustomobject]@{ Processes = @($server); ById = @{ 41002 = $server }; ChildrenByParent = @{} }
        Mock Stop-Process { }
        try {
            $env:WINSMUX_BRIDGE_SESSION_NAMESPACE = 'task781-smoke-20260715'
            $result = Remove-OrchestraSessionServerProcesses -SessionName 'winsmux-orchestra' `
                -WinsmuxBin 'C:\tools\winsmux.exe' -IncludeExpectedBinary -ProcessSnapshot $snapshot `
                -PostStopSnapshotResolver { New-C66ServerProcessSnapshot } -VerificationAttempts 1 `
                -VerificationIntervalMilliseconds 0

            @($result.SessionProcesses).Count | Should -Be 0
            Should -Invoke Stop-Process -Times 0 -Exactly
        } finally {
            if ($null -eq $previousNamespace) { Remove-Item Env:\WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue }
            else { $env:WINSMUX_BRIDGE_SESSION_NAMESPACE = $previousNamespace }
        }
    }

    It 'uses the plain session registry path when no bridge namespace is selected' {
        $previousNamespace = $env:WINSMUX_BRIDGE_NAMESPACE_L
        $previousSocket = $env:WINSMUX_BRIDGE_SOCKET_S
        $previousSessionNamespace = $env:WINSMUX_BRIDGE_SESSION_NAMESPACE
        try {
            Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
            Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
            Remove-Item Env:\WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue

            Split-Path -Leaf (Get-OrchestraSessionPortFilePath -SessionName 'winsmux-orchestra') |
                Should -Be 'winsmux-orchestra.port'
            Split-Path -Leaf (Get-OrchestraSessionKeyFilePath -SessionName 'winsmux-orchestra') |
                Should -Be 'winsmux-orchestra.key'
        } finally {
            if ($null -eq $previousNamespace) {
                Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_NAMESPACE_L = $previousNamespace
            }
            if ($null -eq $previousSocket) {
                Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_SOCKET_S = $previousSocket
            }
            if ($null -eq $previousSessionNamespace) {
                Remove-Item Env:\WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_SESSION_NAMESPACE = $previousSessionNamespace
            }
        }
    }

    It 'uses the forwarded bridge namespace for orchestra registry paths' {
        $previousNamespace = $env:WINSMUX_BRIDGE_NAMESPACE_L
        $previousSocket = $env:WINSMUX_BRIDGE_SOCKET_S
        $previousSessionNamespace = $env:WINSMUX_BRIDGE_SESSION_NAMESPACE
        try {
            $env:WINSMUX_BRIDGE_NAMESPACE_L = 'ops'
            Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
            Remove-Item Env:\WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue

            Split-Path -Leaf (Get-OrchestraSessionPortFilePath -SessionName 'winsmux-orchestra') |
                Should -Be 'ops__winsmux-orchestra.port'
            Split-Path -Leaf (Get-OrchestraSessionKeyFilePath -SessionName 'winsmux-orchestra') |
                Should -Be 'ops__winsmux-orchestra.key'
        } finally {
            if ($null -eq $previousNamespace) {
                Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_NAMESPACE_L = $previousNamespace
            }
            if ($null -eq $previousSocket) {
                Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_SOCKET_S = $previousSocket
            }
            if ($null -eq $previousSessionNamespace) {
                Remove-Item Env:\WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_SESSION_NAMESPACE = $previousSessionNamespace
            }
        }
    }

    It 'prefers the forwarded socket namespace over the -L namespace for orchestra registry paths' {
        $previousNamespace = $env:WINSMUX_BRIDGE_NAMESPACE_L
        $previousSocket = $env:WINSMUX_BRIDGE_SOCKET_S
        $previousSessionNamespace = $env:WINSMUX_BRIDGE_SESSION_NAMESPACE
        try {
            $env:WINSMUX_BRIDGE_NAMESPACE_L = 'ops'
            $env:WINSMUX_BRIDGE_SOCKET_S = 'socket-name'
            Remove-Item Env:\WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue

            Split-Path -Leaf (Get-OrchestraSessionPortFilePath -SessionName 'winsmux-orchestra') |
                Should -Be 'socket-name__winsmux-orchestra.port'
            Split-Path -Leaf (Get-OrchestraSessionKeyFilePath -SessionName 'winsmux-orchestra') |
                Should -Be 'socket-name__winsmux-orchestra.key'
        } finally {
            if ($null -eq $previousNamespace) {
                Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_NAMESPACE_L = $previousNamespace
            }
            if ($null -eq $previousSocket) {
                Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_SOCKET_S = $previousSocket
            }
            if ($null -eq $previousSessionNamespace) {
                Remove-Item Env:\WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_SESSION_NAMESPACE = $previousSessionNamespace
            }
        }
    }

    It 'uses the resolved bridge session namespace when the socket selector was path-based' {
        $previousNamespace = $env:WINSMUX_BRIDGE_NAMESPACE_L
        $previousSocket = $env:WINSMUX_BRIDGE_SOCKET_S
        $previousSessionNamespace = $env:WINSMUX_BRIDGE_SESSION_NAMESPACE
        try {
            $env:WINSMUX_BRIDGE_NAMESPACE_L = 'ops'
            $env:WINSMUX_BRIDGE_SOCKET_S = 'C:\tmp\mux.sock'
            $env:WINSMUX_BRIDGE_SESSION_NAMESPACE = 'socket-0123456789abcdef'

            Split-Path -Leaf (Get-OrchestraSessionPortFilePath -SessionName 'winsmux-orchestra') |
                Should -Be 'socket-0123456789abcdef__winsmux-orchestra.port'
        } finally {
            if ($null -eq $previousNamespace) {
                Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_NAMESPACE_L = $previousNamespace
            }
            if ($null -eq $previousSocket) {
                Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_SOCKET_S = $previousSocket
            }
            if ($null -eq $previousSessionNamespace) {
                Remove-Item Env:\WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_SESSION_NAMESPACE = $previousSessionNamespace
            }
        }
    }

    It 'hashes a path-based socket selector when no resolved namespace is available' {
        $previousNamespace = $env:WINSMUX_BRIDGE_NAMESPACE_L
        $previousSocket = $env:WINSMUX_BRIDGE_SOCKET_S
        $previousSessionNamespace = $env:WINSMUX_BRIDGE_SESSION_NAMESPACE
        try {
            $env:WINSMUX_BRIDGE_NAMESPACE_L = 'ops'
            $env:WINSMUX_BRIDGE_SOCKET_S = 'C:\tmp\mux.sock'
            Remove-Item Env:\WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue

            Split-Path -Leaf (Get-OrchestraSessionPortFilePath -SessionName 'winsmux-orchestra') |
                Should -Match '^socket-[0-9a-f]{16}__winsmux-orchestra\.port$'
        } finally {
            if ($null -eq $previousNamespace) {
                Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_NAMESPACE_L = $previousNamespace
            }
            if ($null -eq $previousSocket) {
                Remove-Item Env:\WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_SOCKET_S = $previousSocket
            }
            if ($null -eq $previousSessionNamespace) {
                Remove-Item Env:\WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_BRIDGE_SESSION_NAMESPACE = $previousSessionNamespace
            }
        }
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

    It 'removes excess warm servers while keeping the budgeted warm process' {
        $snapshot = [pscustomobject]@{
            Processes = @(
                [pscustomobject]@{ ProcessId = 11; ParentProcessId = 0; Name = 'winsmux.exe'; CommandLine = 'winsmux server -s __warm__ -x 120 -y 30' },
                [pscustomobject]@{ ProcessId = 22; ParentProcessId = 0; Name = 'pmux.exe'; CommandLine = 'pmux server -s __warm__ -x 120 -y 30' },
                [pscustomobject]@{ ProcessId = 33; ParentProcessId = 0; Name = 'tmux.exe'; CommandLine = 'tmux server -s __warm__ -x 120 -y 30' },
                [pscustomobject]@{ ProcessId = 44; ParentProcessId = 0; Name = 'psmux.exe'; CommandLine = 'psmux server -s __warm__ -x 120 -y 30' },
                [pscustomobject]@{ ProcessId = 55; ParentProcessId = 0; Name = 'pwsh.exe'; CommandLine = 'pwsh -NoProfile' },
                [pscustomobject]@{ ProcessId = 66; ParentProcessId = 0; Name = 'winsmux.exe'; CommandLine = 'winsmux attach-session -t winsmux-orchestra' }
            )
            ById = @{}
            ChildrenByParent = @{}
        }

        Mock Stop-Process { }

        $cleanup = Remove-OrchestraExcessWarmProcesses -MaxWarmProcesses 1 -ProcessSnapshot $snapshot

        @($cleanup.WarmProcesses).Count | Should -Be 4
        @($cleanup.Victims).Count | Should -Be 3
        @($cleanup.Killed).Count | Should -Be 3
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 22 -and $Force }
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 33 -and $Force }
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 44 -and $Force }
        Should -Invoke Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 66 }
    }
}

Describe 'orchestra-start watchdog contract' {
    BeforeAll {
        $script:orchestraStartPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-start.ps1'
        $script:orchestraStartContent = Get-Content -Path $script:orchestraStartPath -Raw -Encoding UTF8
    }

    It 'launches a single orchestra supervisor process for operator and watchdog loops' {
        $script:orchestraStartContent | Should -Match 'function Start-OrchestraSupervisorJob \{'
        $script:orchestraStartContent | Should -Match 'orchestra-supervisor\.ps1'
        $script:orchestraStartContent | Should -Match "'-OperatorPollInterval'"
        $script:orchestraStartContent | Should -Match "'-AgentWatchdogInterval'"
        $script:orchestraStartContent | Should -Match "'-ServerWatchdogInterval'"
        $script:orchestraStartContent | Should -Match '-SupervisorPid \$supervisorProcess\.Id'
        $script:orchestraStartContent | Should -Not -Match '\$operatorPollProcess = Start-OperatorPollJob'
        $script:orchestraStartContent | Should -Not -Match '\$watchdogProcess = Start-AgentWatchdogJob'
        $script:orchestraStartContent | Should -Not -Match '\$serverWatchdogProcess = Start-ServerWatchdogJob'
    }

    It 'launches the supervisor with Start-Process so it survives script exit' {
        $script:orchestraStartContent | Should -Match 'Start-Process\s+-FilePath\s+''pwsh'''
        $script:orchestraStartContent | Should -Match "'-NoProfile'"
        $script:orchestraStartContent | Should -Match "'-File'"
        $script:orchestraStartContent | Should -Match '-WindowStyle\s+Hidden\s+-PassThru'
        $script:orchestraStartContent | Should -Not -Match 'Start-Job\s+-Name\s+\("winsmux-watchdog-'
    }

    It 'persists the supervisor pid and prints cleanup guidance' {
        $script:orchestraStartContent | Should -Match 'supervisor_pid\s*=\s*\$SupervisorPid'
        $script:orchestraStartContent | Should -Match 'process_registry\s*=\s*\$processRegistry'
        $script:orchestraStartContent | Should -Match 'Supervisor PID: \$\(\$supervisorProcess\.Id\)'
        $script:orchestraStartContent | Should -Match 'Stop-Process -Id \{0\}'
    }
}

Describe 'orchestra-start session reuse contract' {
    BeforeAll {
        $script:orchestraStartPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-start.ps1'
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

    It 'does not mark session_ready true in the manifest until the supervisor process is started' {
        $script:orchestraStartContent | Should -Match 'Save-OrchestraSessionState[^\r\n]+SessionReady \$false'
        $script:orchestraStartContent | Should -Match 'Start-OrchestraSupervisorJob[^\r\n]+-StartupToken \$startupToken'
        $script:orchestraStartContent | Should -Match 'Assert-OrchestraBackgroundProcessStarted -Process \$supervisorProcess -Name ''Orchestra supervisor job'''
        $script:orchestraStartContent | Should -Match 'Save-OrchestraSessionState[^\r\n]+SupervisorPid \$supervisorProcess\.Id[^\r\n]+SessionReady \$true'
    }

    It 'TASK781 C42 persists the authoritative expected pane count in legacy and declarative manifests' {
        $script:orchestraStartContent | Should -Match 'expected_pane_count\s*=\s*\$ExpectedPaneCount'
        $expectedPaneCountSaves = [regex]::Matches(
            $script:orchestraStartContent,
            'Save-OrchestraSessionState[^\r\n]+-ExpectedPaneCount \$expectedPaneCount'
        )
        $expectedPaneCountSaves.Count | Should -Be 3
        $script:orchestraStartContent | Should -Match 'Save-OrchestraSessionState[^\r\n]+-PaneSummaries \$prestartPaneSummaries[^\r\n]+-SessionReady \$false[^\r\n]+-ExpectedPaneCount \$expectedPaneCount -DeclarativeWorkspace \$declarativeWorkspace'
        $script:orchestraStartContent | Should -Match 'if \(\$null -eq \$declarativeApplication\) \{\s*\$manifestPath\s*=\s*Save-OrchestraSessionState[^\r\n]+-PaneSummaries \$validPaneSummaries[^\r\n]+-SessionReady \$false[^\r\n]+-ExpectedPaneCount \$expectedPaneCount'
        $script:orchestraStartContent | Should -Match 'Save-OrchestraSessionState[^\r\n]+-PaneSummaries \$validPaneSummaries[^\r\n]+-SessionReady \$true[^\r\n]+-ExpectedPaneCount \$expectedPaneCount -DeclarativeWorkspace \$declarativeWorkspace'
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

    It 'attaches UI and checks session liveness before layout creates worker panes' {
        $script:orchestraStartContent | Should -Match 'refusing to create worker panes'

        $preLayoutAttachIndex = $script:orchestraStartContent.IndexOf('$preLayoutUiAttachResult = Try-StartOrchestraUiAttach -SessionName $sessionName')
        $livenessIndex = $script:orchestraStartContent.IndexOf('if (-not (Test-OrchestraServerSession -SessionName $sessionName)) {')
        $layoutIndex = $script:orchestraStartContent.IndexOf('$layout = . $layoutScript -SessionName $sessionName')
        $rawPaneTitleIndex = $script:orchestraStartContent.IndexOf("Invoke-Winsmux -Arguments @('select-pane', '-t', [string]`$paneSummary.PaneId, '-T', [string]`$paneSummary.Title) -TargetSessionName `$sessionName")
        $postLayoutAttachIndex = $script:orchestraStartContent.LastIndexOf('$uiAttachResult = Try-StartOrchestraUiAttach -SessionName $sessionName')

        $preLayoutAttachIndex | Should -BeGreaterThan -1
        $livenessIndex | Should -BeGreaterThan $preLayoutAttachIndex
        $layoutIndex | Should -BeGreaterThan $livenessIndex
        $postLayoutAttachIndex | Should -BeGreaterThan $layoutIndex
        $rawPaneTitleIndex | Should -BeGreaterThan $postLayoutAttachIndex
    }

    It 'publishes all orchestra labels with one atomic map update while preserving existing labels' {
        $tempAppData = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-label-publish-' + [guid]::NewGuid().ToString('N'))
        $previousAppData = $env:APPDATA
        try {
            $env:APPDATA = $tempAppData
            $labelsPath = Join-Path $tempAppData 'winsmux\labels.json'
            New-Item -ItemType Directory -Path (Split-Path -Parent $labelsPath) -Force | Out-Null
            [System.IO.File]::WriteAllText($labelsPath, '{"existing":"%9","worker-1":"%99"}', [System.Text.UTF8Encoding]::new($false))

            $result = Publish-OrchestraPaneLabels -PaneSummaries @(
                [ordered]@{ Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; Title = 'W1 Codex Reviewer' }
                [ordered]@{ Label = 'worker-2'; SlotId = 'worker-2'; PaneId = '%3'; Title = 'worker-2' }
            )
            $published = Get-Content -LiteralPath $labelsPath -Raw -Encoding UTF8 | ConvertFrom-Json

            $result.PublishedCount | Should -Be 2
            $published.existing | Should -Be '%9'
            $published.'worker-1' | Should -Be '%2'
            $published.'W1 Codex Reviewer' | Should -Be '%2'
            $published.'worker-2' | Should -Be '%3'
        } finally {
            $env:APPDATA = $previousAppData
            if (Test-Path -LiteralPath $tempAppData) { Remove-Item -LiteralPath $tempAppData -Recurse -Force }
        }
    }

    It 'rejects duplicate orchestra titles before creating a label file' {
        $tempAppData = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-label-reject-' + [guid]::NewGuid().ToString('N'))
        $previousAppData = $env:APPDATA
        try {
            $env:APPDATA = $tempAppData
            {
                Publish-OrchestraPaneLabels -PaneSummaries @(
                    [ordered]@{ Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; Title = 'worker' }
                    [ordered]@{ Label = 'worker-2'; SlotId = 'worker-2'; PaneId = '%3'; Title = 'worker' }
                )
            } | Should -Throw '*unique non-empty titles*'
            Test-Path -LiteralPath (Join-Path $tempAppData 'winsmux\labels.json') | Should -BeFalse
        } finally {
            $env:APPDATA = $previousAppData
            if (Test-Path -LiteralPath $tempAppData) { Remove-Item -LiteralPath $tempAppData -Recurse -Force }
        }
    }

    It 'TASK781 C74 rejects a slot alias collision before creating a label file' {
        $tempAppData = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-slot-label-reject-' + [guid]::NewGuid().ToString('N'))
        $previousAppData = $env:APPDATA
        try {
            $env:APPDATA = $tempAppData
            {
                Publish-OrchestraPaneLabels -PaneSummaries @(
                    [ordered]@{ Label = 'worker'; SlotId = 'worker-1'; PaneId = '%2'; Title = 'W1' }
                    [ordered]@{ Label = 'WORKER'; SlotId = 'worker-2'; PaneId = '%3'; Title = 'W2' }
                )
            } | Should -Throw '*unique non-empty titles and slot labels*'
            Test-Path -LiteralPath (Join-Path $tempAppData 'winsmux\labels.json') | Should -BeFalse
        } finally {
            $env:APPDATA = $previousAppData
            if (Test-Path -LiteralPath $tempAppData) { Remove-Item -LiteralPath $tempAppData -Recurse -Force }
        }
    }

    It 'TASK781 C74 rejects a missing Label or SlotId before publishing any alias' {
        $previousAppData = $env:APPDATA
        try {
            foreach ($case in @(
                    [ordered]@{ Label = ''; SlotId = 'worker-1'; PaneId = '%2'; Title = 'W1' },
                    [ordered]@{ Label = 'worker-1'; SlotId = ''; PaneId = '%2'; Title = 'W1' }
                )) {
                $tempAppData = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-slot-label-missing-' + [guid]::NewGuid().ToString('N'))
                $env:APPDATA = $tempAppData
                { Publish-OrchestraPaneLabels -PaneSummaries @($case) } |
                    Should -Throw '*non-empty slot labels*'
                Test-Path -LiteralPath (Join-Path $tempAppData 'winsmux\labels.json') | Should -BeFalse
                if (Test-Path -LiteralPath $tempAppData) { Remove-Item -LiteralPath $tempAppData -Recurse -Force }
            }
        } finally {
            $env:APPDATA = $previousAppData
        }
    }

    It 'publishes the complete label map atomically only after runtime freshness is established' {
        $bootstrapVerificationIndex = $script:orchestraStartContent.IndexOf('Assert-OrchestraBootstrapVerification -PaneSummaries @($paneSummaries) -InvalidCount $invalidCount -ReadyCount $readyCount')
        $rawPaneTitleIndex = $script:orchestraStartContent.IndexOf("Invoke-Winsmux -Arguments @('select-pane', '-t', [string]`$paneSummary.PaneId, '-T', [string]`$paneSummary.Title) -TargetSessionName `$sessionName")
        $pendingManifestIndex = $script:orchestraStartContent.IndexOf('Save-OrchestraSessionState -ProjectDir $projectDir -SessionName $sessionName -Settings $settings -GitWorktreeDir $gitWorktreeDir -PaneSummaries $validPaneSummaries -GenerationId $runtimeGenerationId -ServerSessionId $serverSessionId -BootstrapPaneId $bootstrapPaneId -StartupToken $startupToken -BootstrapMode ([string]$orchestraServer.BootstrapMode) -SessionReady $false')
        $registryReadyIndex = $script:orchestraStartContent.IndexOf('Wait-OrchestraRuntimeRegistryReady -ProjectDir $projectDir')
        $sessionReadyManifestIndex = $script:orchestraStartContent.IndexOf('Save-OrchestraSessionState -ProjectDir $projectDir -SessionName $sessionName -Settings $settings -GitWorktreeDir $gitWorktreeDir -PaneSummaries $validPaneSummaries -GenerationId $runtimeGenerationId -ServerSessionId $serverSessionId -BootstrapPaneId $bootstrapPaneId -StartupToken $startupToken -SupervisorPid $supervisorProcess.Id -BootstrapMode ([string]$orchestraServer.BootstrapMode) -SessionReady $true')
        $labelPublicationIndex = $script:orchestraStartContent.IndexOf('Publish-OrchestraPaneLabels -PaneSummaries $validPaneSummaries')
        $sessionReadyLogIndex = $script:orchestraStartContent.IndexOf("Write-WinsmuxLog -Level INFO -Event 'orchestra.startup.session_ready'")

        $bootstrapVerificationIndex | Should -BeGreaterThan -1
        $rawPaneTitleIndex | Should -BeGreaterThan $bootstrapVerificationIndex
        $pendingManifestIndex | Should -BeGreaterThan $rawPaneTitleIndex
        $registryReadyIndex | Should -BeGreaterThan $pendingManifestIndex
        $sessionReadyManifestIndex | Should -BeGreaterThan $registryReadyIndex
        $labelPublicationIndex | Should -BeGreaterThan $sessionReadyManifestIndex
        $sessionReadyLogIndex | Should -BeGreaterThan $labelPublicationIndex
        $script:orchestraStartContent | Should -Not -Match "Invoke-Bridge -Arguments @\('name'"
        $script:orchestraStartContent | Should -Not -Match '\$env:WINSMUX_[A-Z0-9_]*(?:BOOTSTRAP|BYPASS)[A-Z0-9_]*'
    }

    It 'excludes exactly one known bootstrap pane from the runtime worker handshake' {
        $script:orchestraStartContent | Should -Match '\[Parameter\(Mandatory = \$true\)\]\[string\]\$BootstrapPaneId'
        $script:orchestraStartContent | Should -Match '\$bootstrapMatches\s*=\s*@\(\$serverPanes \| Where-Object \{ \[string\]\$_\.pane_id -ceq \$BootstrapPaneId \}\)'
        $script:orchestraStartContent | Should -Match '\$observedPanes\s*=\s*@\(\$serverPanes \| Where-Object \{ \[string\]\$_\.pane_id -cne \$BootstrapPaneId \}\)'
        $script:orchestraStartContent | Should -Match '\$bootstrapMatches\.Count -ne 1 -or \$serverPanes\.Count -ne \(\$summaries\.Count \+ 1\)'
        $script:orchestraStartContent | Should -Match '-BootstrapPaneId \$bootstrapPaneId -SupervisorProcess \$supervisorProcess'
    }

    It 'checks the expected pane count before layout and requires a pre-layout liveness gate' {
        $script:orchestraStartContent | Should -Match '\$expectedPaneCount\s*=\s*if \(\$null -ne \$declarativeApplication\) \{ \[int\]\$declarativeApplication\.PaneByKey\.Count \} else \{ Get-OrchestraExpectedPaneCount -LayoutSettings \$layoutSettings \}'
        $script:orchestraStartContent | Should -Match '\$bootstrapPaneCount\s*=\s*1'
        $script:orchestraStartContent | Should -Match 'Test-OrchestraServerHealth -SessionName \$sessionName -WinsmuxBin \$winsmuxBin -ExpectedPaneCount \$expectedPaneCount'
        $script:orchestraStartContent | Should -Match 'Reset-OrchestraServerSession -SessionName \$sessionName -WinsmuxBin \$winsmuxBin -ProjectDir \$projectDir -GitWorktreeDir \$gitWorktreeDir -BridgeScript \$bridgeScript -Reason ''healthy_existing_session'' -ExpectedPaneCount \$bootstrapPaneCount'
        $script:orchestraStartContent | Should -Match 'strict health metadata wait is unavailable, so session liveness will be verified before layout'
        $script:orchestraStartContent | Should -Not -Match 'proceeding without strict pre-layout health metadata gate'
        $script:orchestraStartContent | Should -Not -Match 'skipping strict pre-layout health wait'
    }

    It 'uses pane capture evidence when pane_current_path lags behind the builder worktree' {
        $script:orchestraStartContent | Should -Match 'function Test-PaneCaptureContainsLaunchDir'
        $script:orchestraStartContent | Should -Match 'function Test-OrchestraBootstrapMarker'
        $script:orchestraStartContent | Should -Match 'capture-pane'
        $script:orchestraStartContent | Should -Match 'Test-PaneCaptureContainsLaunchDir -CaptureText \$snapshotText -ExpectedLaunchDir \$ExpectedLaunchDir'
        $script:orchestraStartContent | Should -Match 'BootstrapMarkerPath'
    }

    It 'TASK781 C66 routes every replacement startup through one fail-closed retirement helper' {
        $script:orchestraStartContent | Should -Match 'Acquire-OrchestraStartupLock -ProjectDir \$projectDir -SessionName \$sessionName'
        $script:orchestraStartContent | Should -Match 'startup_token\s*=\s*\$StartupToken'

        $lockAcquireIndex = $script:orchestraStartContent.IndexOf('$startupLock = Acquire-OrchestraStartupLock -ProjectDir $projectDir -SessionName $sessionName')
        $sessionExistsIndex = $script:orchestraStartContent.IndexOf('$sessionExistedAtStart = Test-OrchestraServerSession -SessionName $sessionName')
        $retiredManifestIndex = $script:orchestraStartContent.IndexOf('$retiredManifest = Clear-OrchestraManifestAfterServerRetirement')
        $replacementBootstrapIndex = $script:orchestraStartContent.IndexOf('$orchestraServer = Ensure-OrchestraBootstrapSession -SessionName $sessionName -TimeoutSeconds 60')
        $lockAcquireIndex | Should -BeGreaterThan -1
        $sessionExistsIndex | Should -BeGreaterThan -1
        $retiredManifestIndex | Should -BeGreaterThan $sessionExistsIndex
        $replacementBootstrapIndex | Should -BeGreaterThan $retiredManifestIndex
        $lockAcquireIndex | Should -BeLessThan $sessionExistsIndex

        $startupSequence = $script:orchestraStartContent.Substring(
            $sessionExistsIndex,
            $replacementBootstrapIndex - $sessionExistsIndex
        )
        $startupSequence | Should -Not -Match 'Stop-OrchestraBackgroundProcessesFromManifest'
        $startupSequence | Should -Not -Match 'Clear-WinsmuxManifest'
        $startupSequence | Should -Not -Match 'Remove-OrchestraSessionServerProcesses'
        $startupSequence | Should -Not -Match '\$requiresManifestRetirement'
        ([regex]::Matches($startupSequence, 'Clear-OrchestraManifestAfterServerRetirement')).Count | Should -Be 1
        $script:orchestraStartContent | Should -Match '(?s)function Clear-OrchestraManifestAfterServerRetirement.*?Get-OrchestraRuntimeRegistryRetirementPlan.*?Remove-OrchestraSessionServerProcesses.*?Wait-OrchestraServerSessionAbsent.*?Stop-OrchestraBackgroundProcessesFromManifest.*?Complete-OrchestraRuntimeRegistryRetirement.*?Clear-WinsmuxManifest'
    }

    It 'suppresses warm servers and trims excess warm processes during managed startup' {
        $script:orchestraStartContent | Should -Match 'function Enable-OrchestraManagedWarmSuppression'
        $script:orchestraStartContent | Should -Match 'Set-Item -Path "Env:\$name" -Value ''1'''
        $script:orchestraStartContent | Should -Match 'Remove-OrchestraExcessWarmProcesses -MaxWarmProcesses 1'

        $warmSuppressionIndex = $script:orchestraStartContent.IndexOf('        Enable-OrchestraManagedWarmSuppression')
        $winsmuxResolveIndex = $script:orchestraStartContent.IndexOf('$script:winsmuxBin = Get-WinsmuxBin')
        $zombieCleanupIndex = $script:orchestraStartContent.IndexOf('$zombieCleanup = Remove-OrchestraZombieProcesses -SessionName $sessionName -ProjectDir $projectDir -GitWorktreeDir $gitWorktreeDir -BridgeScript $bridgeScript -WinsmuxBin $winsmuxBin')
        $warmCleanupIndex = $script:orchestraStartContent.IndexOf('$warmCleanup = Remove-OrchestraExcessWarmProcesses -MaxWarmProcesses 1')
        $ensureSessionIndex = $script:orchestraStartContent.IndexOf('$orchestraServer = Ensure-OrchestraBootstrapSession -SessionName $sessionName -TimeoutSeconds 60')

        $warmSuppressionIndex | Should -BeGreaterThan -1
        $winsmuxResolveIndex | Should -BeGreaterThan $warmSuppressionIndex
        $warmCleanupIndex | Should -BeGreaterThan $zombieCleanupIndex
        $ensureSessionIndex | Should -BeGreaterThan $warmCleanupIndex
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
        $script:orchestraStartContent | Should -Match 'SupportsContextReset = \[bool\]\$slotAgentConfig\.SupportsContextReset'
        $script:orchestraStartContent | Should -Match 'capability_adapter\s*=\s*\[string\]\$paneSummary\.CapabilityAdapter'
        $script:orchestraStartContent | Should -Match 'supports_file_edit\s*=\s*\[bool\]\$paneSummary\.SupportsFileEdit'
        $script:orchestraStartContent | Should -Match 'supports_verification\s*=\s*\[bool\]\$paneSummary\.SupportsVerification'
        $script:orchestraStartContent | Should -Match 'supports_context_reset\s*=\s*\[bool\]\(Get-OrchestraObjectPropertyValue -InputObject \$paneSummary -Name ''SupportsContextReset'' -Default \$false\)'
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

    It 'skips bootstrap readiness and cwd verification for deferred worker panes' {
        Test-OrchestraPaneBootstrapVerificationDeferred -PaneSummary ([pscustomobject]@{ Status = 'deferred_start' }) | Should -Be $true
        Test-OrchestraPaneBootstrapVerificationDeferred -PaneSummary ([pscustomobject]@{ Status = 'deferred_starting' }) | Should -Be $true
        Test-OrchestraPaneBootstrapVerificationDeferred -PaneSummary ([pscustomobject]@{ Status = 'api_llm_runner_unconfigured' }) | Should -Be $true
        Test-OrchestraPaneBootstrapVerificationDeferred -PaneSummary ([pscustomobject]@{ Status = 'antigravity_runner_unconfigured' }) | Should -Be $true
        Test-OrchestraPaneBootstrapVerificationDeferred -PaneSummary ([pscustomobject]@{ Status = 'ready' }) | Should -Be $false

        $script:orchestraStartContent | Should -Match 'Test-OrchestraPaneBootstrapVerificationDeferred -PaneSummary \$paneSummary'
        $script:orchestraStartContent | Should -Match '\$validPaneSummaries\.Add\(\$paneSummary\)'
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
        $script:orchestraStartPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-start.ps1'
        . $script:orchestraStartPath
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

    It 'TASK781 C66 preserves a retired or competing manifest when rollback did not publish a generation' {
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
        (Test-Path (Join-Path $manifestDir 'manifest.yaml')) | Should -Be $true
    }

    It 'TASK781 C66 clears only the manifest generation published by this startup attempt' {
        $script:rollbackSequence = [System.Collections.Generic.List[string]]::new()
        $script:rollbackRegistryClosed = $false
        Mock Invoke-Winsmux { @('%1') } -ParameterFilter {
            $Arguments[0] -eq 'list-panes'
        }
        Mock Invoke-Winsmux { } -ParameterFilter {
            $Arguments[0] -eq 'respawn-pane'
        }
        Mock Wait-PaneShellReady { }
        Mock Remove-OrchestraCreatedWorktrees { @() }
        Mock Read-WinsmuxRuntimeRegistry {
            [PSCustomObject]@{
                status = if ($script:rollbackRegistryClosed) { 'ended' } else { 'active' }
                session_name = 'winsmux-orchestra'; generation_id = 'owned-generation'; server_session_id = '$41'
                supervisor = [PSCustomObject]@{ pid = 4201; process_started_at = '2026-07-16T04:00:00.0000000Z' }
                lease = [PSCustomObject]@{ state = if ($script:rollbackRegistryClosed) { 'ended' } else { 'active' }; expires_at = '2026-07-16T04:00:15.0000000Z' }
            }
        }
        Mock New-WinsmuxProcessSnapshotResolver { { param([int]$Id) $null } }
        Mock Close-WinsmuxRuntimeRegistry {
            $script:rollbackRegistryClosed = $true
            $script:rollbackSequence.Add('registry-ended') | Out-Null
            return $true
        }
        Mock Clear-WinsmuxManifest {
            $script:rollbackSequence.Add('manifest-cleared') | Out-Null
            return $true
        }

        $rollback = Invoke-OrchestraStartupRollback `
            -ProjectDir $script:orchestraStartTempRoot `
            -SessionName 'winsmux-orchestra' `
            -BootstrapPaneId '%1' `
            -CreatedPaneIds @('%1') `
            -CreatedWorktrees @() `
            -FailureMessage 'post-publication failure' `
            -ManifestPublished `
            -OwnedGenerationId 'owned-generation' `
            -OwnedServerSessionId '$41' `
            -OwnedSupervisorPid 4201 `
            -OwnedSupervisorProcessStartedAt '2026-07-16T04:00:00.0000000Z'

        $rollback.RollbackErrors.Count | Should -Be 0
        $rollback.RegistryClosed | Should -BeTrue
        @($script:rollbackSequence) | Should -Be @('registry-ended', 'manifest-cleared')
        Should -Invoke Close-WinsmuxRuntimeRegistry -Times 1 -Exactly -ParameterFilter {
            $GenerationId -ceq 'owned-generation' -and $SupervisorPid -eq 4201 -and
            $SupervisorProcessStartedAt -ceq '2026-07-16T04:00:00.0000000Z' -and
            $ExpectedSessionName -ceq 'winsmux-orchestra' -and $ExpectedServerSessionId -ceq '$41'
        }
        Should -Invoke Clear-WinsmuxManifest -Times 1 -Exactly -ParameterFilter {
            $ProjectDir -eq $script:orchestraStartTempRoot -and
            $ExpectedGenerationId -ceq 'owned-generation'
        }
    }

    It 'TASK781 C66 guarded manifest clear preserves a competing generation' {
        $manifest = [PSCustomObject][ordered]@{
            version = 2
            session = [PSCustomObject][ordered]@{
                name              = 'winsmux-orchestra'
                generation_id     = 'competing-generation'
                server_session_id = '$9'
                bootstrap_pane_id = '%1'
            }
            panes = [ordered]@{}
        }
        Save-WinsmuxManifest -ProjectDir $script:orchestraStartTempRoot -Manifest $manifest
        $manifestPath = Get-ManifestPath -ProjectDir $script:orchestraStartTempRoot

        { Clear-WinsmuxManifest -ProjectDir $script:orchestraStartTempRoot -ExpectedGenerationId 'owned-generation' } |
            Should -Throw '*generation changed*'
        (Test-Path -LiteralPath $manifestPath -PathType Leaf) | Should -BeTrue
        (Get-WinsmuxVerifiedManifestIdentity -Manifest (Get-WinsmuxManifest -ProjectDir $script:orchestraStartTempRoot)).generation_id |
            Should -BeExactly 'competing-generation'
    }

    It 'TASK781 C66 guarded manifest clear deletes the exactly owned generation' {
        $manifest = [PSCustomObject][ordered]@{
            version = 2
            session = [PSCustomObject][ordered]@{
                name              = 'winsmux-orchestra'
                generation_id     = 'owned-generation'
                server_session_id = '$9'
                bootstrap_pane_id = '%1'
            }
            panes = [ordered]@{}
        }
        Save-WinsmuxManifest -ProjectDir $script:orchestraStartTempRoot -Manifest $manifest
        $manifestPath = Get-ManifestPath -ProjectDir $script:orchestraStartTempRoot

        (Clear-WinsmuxManifest -ProjectDir $script:orchestraStartTempRoot -ExpectedGenerationId 'owned-generation') |
            Should -BeTrue
        (Test-Path -LiteralPath $manifestPath -PathType Leaf) | Should -BeFalse
    }

    It 'TASK781 C66 guarded manifest clear preserves an unverifiable manifest' {
        $manifestDir = Join-Path $script:orchestraStartTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
        $manifestPath = Join-Path $manifestDir 'manifest.yaml'
        [System.IO.File]::WriteAllText($manifestPath, "version: '1'`n", [System.Text.UTF8Encoding]::new($false))

        { Clear-WinsmuxManifest -ProjectDir $script:orchestraStartTempRoot -ExpectedGenerationId 'owned-generation' } |
            Should -Throw
        (Test-Path -LiteralPath $manifestPath -PathType Leaf) | Should -BeTrue
    }

    It 'TASK781 C66 passes published-generation ownership into startup rollback' {
        $source = [System.IO.File]::ReadAllText($script:orchestraStartPath, [System.Text.Encoding]::UTF8)
        $source | Should -Match '\$manifestPublished\s*=\s*\$false'
        $source | Should -Match '\$manifestPublished\s*=\s*\$true'
        $source | Should -Match 'Invoke-OrchestraStartupRollback[^\r\n]+-ManifestPublished:\$manifestPublished[^\r\n]+-OwnedGenerationId \$runtimeGenerationId[^\r\n]+-OwnedServerSessionId \$serverSessionId[^\r\n]+-OwnedSupervisorPid \$rollbackSupervisorPid[^\r\n]+-OwnedSupervisorProcessStartedAt \$supervisorProcessStartedAt'
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

    It 'delivers launch commands in-process without public bridge argv' {
        Mock Invoke-Winsmux { }
        Mock Invoke-Bridge { throw 'launch delivery must not use public bridge argv' }

        Send-OrchestraBridgeCommand `
            -Target '%2' `
            -Text 'pwsh -NoProfile -File bootstrap.ps1' `
            -DeliveryClass 'launch' `
            -SessionName 'winsmux-orchestra'

        Should -Invoke Invoke-Bridge -Times 0 -Exactly
        Should -Invoke Invoke-Winsmux -Times 1 -Exactly -ParameterFilter {
            @($Arguments) -join '|' -eq 'send-keys|-t|%2|-l|--|pwsh -NoProfile -File bootstrap.ps1' -and
            $TargetSessionName -eq 'winsmux-orchestra'
        }
        Should -Invoke Invoke-Winsmux -Times 1 -Exactly -ParameterFilter {
            @($Arguments) -join '|' -eq 'send-keys|-t|%2|Enter' -and
            $TargetSessionName -eq 'winsmux-orchestra'
        }
    }

    It 'writes a pane bootstrap plan and launches it with a single bootstrap command after respawn' {
        $sentCommands = [System.Collections.Generic.List[string]]::new()
        $sentDeliveryClasses = [System.Collections.Generic.List[string]]::new()
        $bridgeCalls = [System.Collections.Generic.List[object]]::new()
        $planRoot = Join-Path $script:orchestraStartTempRoot '.winsmux\orchestra-bootstrap'
        $cleanPtyEnv = [PSCustomObject]@{
            RemoveCommand = "Get-ChildItem Env: | Where-Object { `$_.Name -like 'WINSMUX_*' } | ForEach-Object { Remove-Item -LiteralPath ('Env:' + `$_.Name) -ErrorAction SilentlyContinue }"
            Environment   = [ordered]@{
                WINSMUX_ROLE            = 'Worker'
                WINSMUX_GOVERNANCE_MODE = 'enhanced'
            }
        }
        $approvedLaunch = [ordered]@{
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
            execution_profile = 'local-windows'
            execution_backend = 'local'
            analysis_posture = 'read-write-worker'
            auto_launch = $false
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
            $sentDeliveryClasses.Add($DeliveryClass) | Out-Null
        }

        $planPath = New-OrchestraPaneBootstrapPlan `
            -ProjectDir $script:orchestraStartTempRoot `
            -PaneId '%2' `
            -Label 'worker-1' `
            -SlotId 'worker-1' `
            -Role 'Worker' `
            -WorkerBackend 'local' `
            -WorkerRole 'worker' `
            -PaneTitle 'worker-1' `
            -GenerationId 'generation-bootstrap-123' `
            -ServerSessionId '$123' `
            -Agent 'codex' `
            -Model 'gpt-5.4' `
            -StartupToken 'token-123' `
            -LaunchDir 'C:\repo\.worktrees\builder-1' `
            -CleanPtyEnv $cleanPtyEnv `
            -LaunchCommand 'codex --help' `
            -ApprovedLaunch $approvedLaunch

        Start-OrchestraPaneBootstrap -PaneId '%2' -PlanPath $planPath -SessionName 'winsmux-orchestra'

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
        [string]$plan.approved_launch.packet_type | Should -Be 'worker_launch_approval'
        [string]$plan.approved_launch.model | Should -Be 'gpt-5.4'
        [string]$plan.approved_launch.execution_profile | Should -Be 'local-windows'
        [string]$plan.startup_token | Should -Be 'token-123'
        [string]$plan.ready_marker_path | Should -Match '[\\/]2-generation-bootstrap-123\.ready\.json$'
        $bridgeCalls.Count | Should -Be 1
        @($bridgeCalls[0].Arguments) | Should -Be @('keys', '%2', 'C-c')
        $sentCommands.Count | Should -Be 1
        $sentCommands[0] | Should -Match 'orchestra-pane-bootstrap\.ps1'
        $sentCommands[0] | Should -Match '-PlanFile'
        $sentDeliveryClasses | Should -Be @('launch')
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
            -SlotId 'worker-1' `
            -Role 'Worker' `
            -WorkerBackend 'example' `
            -WorkerRole 'worker' `
            -PaneTitle 'worker-1' `
            -GenerationId 'generation-bootstrap-456' `
            -ServerSessionId '$456' `
            -Agent 'example' `
            -Model 'example-model' `
            -StartupToken 'token-456' `
            -LaunchDir 'C:\repo\.worktrees\builder-1' `
            -CleanPtyEnv $cleanPtyEnv `
            -LaunchCommand 'example-agent --help' `
            -SupportsInterrupt $false

        Start-OrchestraPaneBootstrap -PaneId '%2' -PlanPath $planPath -SessionName 'winsmux-orchestra'

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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\doctor.ps1')
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

    It 'passes the orchestra process contract when smoke reports counts within budget' {
        Mock Invoke-DoctorOrchestraSmokeJson {
            [pscustomobject]@{
                Ok       = $true
                ExitCode = 0
                Error    = ''
                Data     = [pscustomobject]@{
                    process_contract = [pscustomobject]@{
                        ok                      = $true
                        worker_shell_count      = 6
                        background_helper_count = 3
                        attach_host_count       = 1
                        warm_process_count      = 1
                        stale_process_count     = 0
                        budgets                 = [pscustomobject]@{
                            max_worker_shells      = 6
                            max_background_helpers = 3
                            max_attach_hosts       = 1
                            max_warm_processes     = 1
                            max_stale_processes    = 0
                        }
                        warnings                = @()
                    }
                }
            }
        }

        $result = Test-OrchestraProcessContractCheck

        $result.Status | Should -Be 'pass'
        $result.Label | Should -Be 'Orchestra process contract'
        $result.Detail | Should -Be 'workers=6/6; background_helpers=3/3; attach_hosts=1/1; warm_processes=1/1; stale_processes=0/0'
    }

    It 'fails the orchestra process contract when smoke reports process pressure over budget' {
        Mock Invoke-DoctorOrchestraSmokeJson {
            [pscustomobject]@{
                Ok       = $true
                ExitCode = 1
                Error    = ''
                Data     = [pscustomobject]@{
                    process_contract = [pscustomobject]@{
                        ok                      = $false
                        worker_shell_count      = 7
                        background_helper_count = 3
                        attach_host_count       = 1
                        warm_process_count      = 1
                        stale_process_count     = 1
                        budgets                 = [pscustomobject]@{
                            max_worker_shells      = 6
                            max_background_helpers = 3
                            max_attach_hosts       = 1
                            max_warm_processes     = 1
                            max_stale_processes    = 0
                        }
                        warnings                = @(
                            'worker shell count 7 exceeds budget 6.'
                            'stale managed process count 1 exceeds budget 0.'
                        )
                    }
                }
            }
        }

        $result = Test-OrchestraProcessContractCheck

        $result.Status | Should -Be 'fail'
        $result.Label | Should -Be 'Orchestra process contract'
        $result.Detail | Should -Match 'workers=7/6'
        $result.Detail | Should -Match 'stale_processes=1/0'
        $result.Detail | Should -Match 'worker shell count 7 exceeds budget 6'
        $result.Detail | Should -Match 'stale managed process count 1 exceeds budget 0'
    }

    It 'TASK781 fails a parsed orchestra smoke result with invalid runtime identity' {
        Mock Invoke-DoctorOrchestraSmokeJson {
            [pscustomobject]@{
                Ok       = $false
                ExitCode = 0
                Error    = 'orchestra-smoke did not verify the supervisor-owned runtime identity registry'
                Data     = [pscustomobject]@{
                    smoke_ok      = $true
                    runtime_valid = $false
                }
            }
        }

        $result = Test-OrchestraProcessContractCheck

        $result.Status | Should -Be 'fail'
        $result.Label | Should -Be 'Orchestra process contract'
        $result.Detail | Should -Match 'runtime identity registry'
    }

    It 'handles a single orchestra process contract warning from smoke' {
        Mock Invoke-DoctorOrchestraSmokeJson {
            [pscustomobject]@{
                Ok       = $true
                ExitCode = 1
                Error    = ''
                Data     = [pscustomobject]@{
                    process_contract = [pscustomobject]@{
                        ok                      = $false
                        worker_shell_count      = 6
                        background_helper_count = 1
                        attach_host_count       = 1
                        warm_process_count      = 2
                        stale_process_count     = 0
                        budgets                 = [pscustomobject]@{
                            max_worker_shells      = 6
                            max_background_helpers = 1
                            max_attach_hosts       = 1
                            max_warm_processes     = 1
                            max_stale_processes    = 0
                        }
                        warnings                = 'warm process count 2 exceeds budget 1.'
                    }
                }
            }
        }

        $result = Test-OrchestraProcessContractCheck

        $result.Status | Should -Be 'fail'
        $result.Detail | Should -Match 'warm_processes=2/1'
        $result.Detail | Should -Match 'warm process count 2 exceeds budget 1'
    }

    It 'summarizes low-count PowerShell startup evidence without leaking command lines or process ids' {
        $protectedIds = [System.Collections.Generic.HashSet[int]]::new()
        $snapshot = [pscustomobject]@{
            Processes = @(
                [pscustomobject]@{ ProcessId = 2101; ParentProcessId = 0; Name = 'Code.exe'; CommandLine = 'Code.exe' }
                [pscustomobject]@{ ProcessId = 2102; ParentProcessId = 0; Name = 'WindowsTerminal.exe'; CommandLine = 'WindowsTerminal.exe' }
                [pscustomobject]@{ ProcessId = 2103; ParentProcessId = 0; Name = 'codex.exe'; CommandLine = 'codex.exe' }
                [pscustomobject]@{ ProcessId = 2201; ParentProcessId = 2101; Name = 'pwsh.exe'; CommandLine = 'pwsh -NoProfile -Command secret-value' }
                [pscustomobject]@{ ProcessId = 2202; ParentProcessId = 2102; Name = 'pwsh.exe'; CommandLine = 'pwsh -NoLogo' }
                [pscustomobject]@{ ProcessId = 2203; ParentProcessId = 2103; Name = 'powershell.exe'; CommandLine = 'powershell -NoProfile' }
            )
            ById = @{
                2101 = [pscustomobject]@{ ProcessId = 2101; ParentProcessId = 0; Name = 'Code.exe'; CommandLine = 'Code.exe' }
                2102 = [pscustomobject]@{ ProcessId = 2102; ParentProcessId = 0; Name = 'WindowsTerminal.exe'; CommandLine = 'WindowsTerminal.exe' }
                2103 = [pscustomobject]@{ ProcessId = 2103; ParentProcessId = 0; Name = 'codex.exe'; CommandLine = 'codex.exe' }
                2201 = [pscustomobject]@{ ProcessId = 2201; ParentProcessId = 2101; Name = 'pwsh.exe'; CommandLine = 'pwsh -NoProfile -Command secret-value' }
                2202 = [pscustomobject]@{ ProcessId = 2202; ParentProcessId = 2102; Name = 'pwsh.exe'; CommandLine = 'pwsh -NoLogo' }
                2203 = [pscustomobject]@{ ProcessId = 2203; ParentProcessId = 2103; Name = 'powershell.exe'; CommandLine = 'powershell -NoProfile' }
            }
            SupportsCommandLine = $true
        }

        $result = New-PowerShellStartupEvidenceResult -Snapshot $snapshot -ProtectedIds $protectedIds -WarnThreshold 100 -SmokeStatus pass -SmokeDetail '7.5.4'

        $result.Status | Should -Be 'pass'
        $result.Label | Should -Be 'PowerShell startup evidence'
        $result.Detail | Should -Match 'pwsh_count=3'
        $result.Detail | Should -Match 'count_state=below_threshold'
        $result.Detail | Should -Match 'low_count_threshold=8'
        $result.Detail | Should -Match 'startup_risk=normal'
        $result.Detail | Should -Match 'bare_pwsh=pass'
        $result.Detail | Should -Match 'codex=1'
        $result.Detail | Should -Match 'vscode=1'
        $result.Detail | Should -Match 'windows-terminal=1'
        $result.Detail | Should -Match 'command_lines=omitted'
        $result.Detail | Should -Not -Match 'secret-value'
        $result.Detail | Should -Not -Match '2201'
    }

    It 'warns for low-count PowerShell startup recurrence risk below the high process threshold' {
        $protectedIds = [System.Collections.Generic.HashSet[int]]::new()
        $processes = @()
        $byId = @{}
        for ($index = 1; $index -le 12; $index++) {
            $process = [pscustomobject]@{
                ProcessId       = 3000 + $index
                ParentProcessId = 0
                Name            = 'pwsh.exe'
                CommandLine     = "pwsh -NoProfile -Command redacted-$index"
            }
            $processes += $process
            $byId[$process.ProcessId] = $process
        }
        $snapshot = [pscustomobject]@{
            Processes = $processes
            ById = $byId
            SupportsCommandLine = $true
        }

        $result = New-PowerShellStartupEvidenceResult -Snapshot $snapshot -ProtectedIds $protectedIds -WarnThreshold 100 -LowCountWarnThreshold 8 -SmokeStatus pass -SmokeDetail '7.5.4'

        $result.Status | Should -Be 'warn'
        $result.Label | Should -Be 'PowerShell startup evidence'
        $result.Detail | Should -Match 'pwsh_count=12'
        $result.Detail | Should -Match 'count_state=below_threshold'
        $result.Detail | Should -Match 'startup_risk=low_count_risk'
        $result.Detail | Should -Match 'command_lines=omitted'
        $result.Detail | Should -Not -Match 'redacted-'
    }

    It 'warns in startup evidence when the bare PowerShell smoke check fails' {
        $protectedIds = [System.Collections.Generic.HashSet[int]]::new()
        $snapshot = [pscustomobject]@{
            Processes = @()
            ById = @{}
            SupportsCommandLine = $true
        }

        $result = New-PowerShellStartupEvidenceResult -Snapshot $snapshot -ProtectedIds $protectedIds -WarnThreshold 100 -SmokeStatus fail -SmokeDetail 'pwsh exited with code 3221225794'

        $result.Status | Should -Be 'warn'
        $result.Label | Should -Be 'PowerShell startup evidence'
        $result.Detail | Should -Match 'pwsh_count=0'
        $result.Detail | Should -Match 'bare_pwsh=fail'
        $result.Detail | Should -Match 'startup_risk=smoke_failed'
        $result.Detail | Should -Match '3221225794'
    }
}

Describe 'worker isolation diagnostics' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\worker-isolation.ps1')
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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\worker-isolation.ps1')

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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\worker-isolation.ps1')

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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\worker-isolation.ps1')

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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\worker-isolation.ps1')

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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\worker-isolation.ps1')

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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\worker-isolation.ps1')

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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\worker-isolation.ps1')

        $report = Get-WinsmuxWorkerIsolationReport `
            -ProjectDir $script:workerIsolationTempRoot `
            -Manifest (New-TestWorkerIsolationManifest -ExpectedOrigin '') `
            -GitPath 'git' `
            -GitInvoker (New-TestWorkerIsolationGitInvoker -Origin 'https://github.com/example/repo.git')

        $report.ok | Should -Be $false
        $report.findings[0].message | Should -Match 'expected no origin'
    }

    It 'fails when expected gitdir is recorded as empty' {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\worker-isolation.ps1')

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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\worker-isolation.ps1')

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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\worker-isolation.ps1')

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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\worker-isolation.ps1')

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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\worker-isolation.ps1')

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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\pane-scaler.ps1')
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

    It 'TASK781 C56 refuses v2 pane-count changes before any pane worktree or manifest mutation' {
        @"
version: 2
saved_at: 2026-07-15T17:30:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:paneScalerTempRoot
  generation_id: generation-56
  server_session_id: `$56
  bootstrap_pane_id: '%1'
  expected_pane_count: 3
panes:
  builder-1:
    slot_id: builder-1
    pane_id: '%2'
    role: Builder
    worker_role: builder
    worker_backend: codex
    title: Builder-1
  builder-2:
    slot_id: builder-2
    pane_id: '%3'
    role: Builder
    worker_role: builder
    worker_backend: codex
    title: Builder-2
  builder-3:
    slot_id: builder-3
    pane_id: '%4'
    role: Builder
    worker_role: builder
    worker_backend: codex
    title: Builder-3
"@ | Set-Content -LiteralPath $script:paneScalerManifestPath -Encoding UTF8

        Mock New-PaneScalerBuilderWorktree { throw 'worktree creation must not run for v2 scaling' }
        Mock Get-PaneWorkload { throw 'workload probing must not run before the v2 scaling refusal' }
        Mock Invoke-MonitorWinsmux { throw 'pane mutation must not run for v2 scaling' }
        Mock Remove-PaneScalerBuilderWorktree { throw 'worktree removal must not run for v2 scaling' }
        Mock Save-PaneScalerManifest { throw 'manifest save must not run for v2 scaling' }

        { Add-OrchestraPane -ManifestPath $script:paneScalerManifestPath } |
            Should -Throw '*manifest_regeneration_required*supervisor-owned*'
        { Remove-OrchestraPane -ManifestPath $script:paneScalerManifestPath } |
            Should -Throw '*manifest_regeneration_required*supervisor-owned*'

        Should -Invoke New-PaneScalerBuilderWorktree -Times 0 -Exactly
        Should -Invoke Get-PaneWorkload -Times 0 -Exactly
        Should -Invoke Invoke-MonitorWinsmux -Times 0 -Exactly
        Should -Invoke Remove-PaneScalerBuilderWorktree -Times 0 -Exactly
        Should -Invoke Save-PaneScalerManifest -Times 0 -Exactly
    }

    It 'TASK781 C59 persists a v1 scale-down transition before destructive cleanup' {
        @"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:paneScalerTempRoot
panes:
  builder-1:
    pane_id: '%2'
"@ | Set-Content -LiteralPath $script:paneScalerManifestPath -Encoding UTF8
        $manifest = [PSCustomObject]@{
            Version = 1
            SavedAt = '2026-07-15T19:45:00+09:00'
            Session = [PSCustomObject]@{ project_dir = $script:paneScalerTempRoot }
            Panes = [ordered]@{
                'builder-1' = [ordered]@{ pane_id = '%2' }
                'builder-2' = [ordered]@{ pane_id = '%3' }
                'builder-3' = [ordered]@{ pane_id = '%4' }
                'builder-4' = [ordered]@{
                    pane_id = '%5'
                    builder_worktree_path = (Join-Path $script:paneScalerTempRoot '.worktrees\builder-4')
                    builder_branch = 'worktree-builder-4'
                }
            }
        }
        Mock Get-PaneWorkload {
            [PSCustomObject]@{
                BuilderCount = 4
                Results = @(
                    [PSCustomObject]@{ Label = 'builder-1'; Status = 'busy' }
                    [PSCustomObject]@{ Label = 'builder-2'; Status = 'ready' }
                    [PSCustomObject]@{ Label = 'builder-3'; Status = 'ready' }
                    [PSCustomObject]@{ Label = 'builder-4'; Status = 'ready' }
                )
                Manifest = $manifest
                ProjectDir = $script:paneScalerTempRoot
            }
        }
        Mock Get-PaneControlManifestGenerationId { '' }
        Mock Save-PaneScalerManifest { throw 'injected manifest save failure' }
        Mock Invoke-MonitorWinsmux { throw 'pane kill must not run before a successful save' }
        Mock Remove-PaneScalerBuilderWorktree { throw 'worktree cleanup must not run before a successful save' }

        { Remove-OrchestraPane -ManifestPath $script:paneScalerManifestPath } |
            Should -Throw '*injected manifest save failure*'

        Should -Invoke Save-PaneScalerManifest -Times 1 -Exactly
        Should -Invoke Invoke-MonitorWinsmux -Times 0 -Exactly
        Should -Invoke Remove-PaneScalerBuilderWorktree -Times 0 -Exactly
    }

    It 'TASK781 C59 orders a successful v1 scale-down as save then kill then cleanup' {
        @"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:paneScalerTempRoot
panes:
  builder-1:
    pane_id: '%2'
"@ | Set-Content -LiteralPath $script:paneScalerManifestPath -Encoding UTF8
        $manifest = [PSCustomObject]@{
            Version = 1
            SavedAt = '2026-07-15T19:45:00+09:00'
            Session = [PSCustomObject]@{ project_dir = $script:paneScalerTempRoot }
            Panes = [ordered]@{
                'builder-1' = [ordered]@{ pane_id = '%2' }
                'builder-2' = [ordered]@{ pane_id = '%3' }
                'builder-3' = [ordered]@{ pane_id = '%4' }
                'builder-4' = [ordered]@{
                    pane_id = '%5'
                    builder_worktree_path = (Join-Path $script:paneScalerTempRoot '.worktrees\builder-4')
                    builder_branch = 'worktree-builder-4'
                }
            }
        }
        Mock Get-PaneWorkload {
            [PSCustomObject]@{
                BuilderCount = 4
                Results = @(
                    [PSCustomObject]@{ Label = 'builder-1'; Status = 'busy' }
                    [PSCustomObject]@{ Label = 'builder-2'; Status = 'ready' }
                    [PSCustomObject]@{ Label = 'builder-3'; Status = 'ready' }
                    [PSCustomObject]@{ Label = 'builder-4'; Status = 'ready' }
                )
                Manifest = $manifest
                ProjectDir = $script:paneScalerTempRoot
            }
        }
        $script:c59Order = [System.Collections.Generic.List[string]]::new()
        Mock Get-PaneControlManifestGenerationId { '' }
        Mock Save-PaneScalerManifest { $script:c59Order.Add('save') | Out-Null }
        Mock Invoke-MonitorWinsmux { $script:c59Order.Add('kill') | Out-Null }
        Mock Remove-PaneScalerBuilderWorktree { $script:c59Order.Add('cleanup') | Out-Null }

        $result = Remove-OrchestraPane -ManifestPath $script:paneScalerManifestPath

        $result.Changed | Should -BeTrue
        @($script:c59Order) | Should -Be @('save', 'kill', 'cleanup')
    }

    It 'TASK781 C56 preserves a dirty Builder worktree and never force-deletes its branch' {
        $worktreePath = Join-Path $script:paneScalerTempRoot '.worktrees\builder-9'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        $paneScalerSource = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\pane-scaler.ps1') -Raw -Encoding UTF8
        $paneScalerSource.Contains("'--force'") | Should -BeFalse
        $paneScalerSource.Contains("'-D'") | Should -BeFalse
        Mock Invoke-BuilderWorktreeGit {
            param($ProjectDir, $Arguments, [switch]$AllowFailure)
            if ($ProjectDir -eq $worktreePath -and $Arguments[0] -eq 'status') {
                return [PSCustomObject]@{ ExitCode = 0; Output = ' M user-owned.txt'; Lines = @(' M user-owned.txt') }
            }
            throw 'destructive git cleanup must not run for a dirty worktree'
        }

        {
            Remove-PaneScalerBuilderWorktree -ProjectDir $script:paneScalerTempRoot `
                -WorktreePath $worktreePath -BranchName 'worktree-builder-9'
        } | Should -Throw '*uncommitted changes*'

        Test-Path -LiteralPath $worktreePath -PathType Container | Should -Be $true
        Should -Invoke Invoke-BuilderWorktreeGit -Times 1 -Exactly -ParameterFilter {
            $ProjectDir -eq $worktreePath -and $Arguments[0] -eq 'status'
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

    It 'classes an oversized add-Builder agent command as launch delivery' {
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

        $script:oversizedPaneScalerLaunchCommand = 'codex ' + ('x' * 4001)
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
        Mock Get-PaneScalerLaunchCommand { return $script:oversizedPaneScalerLaunchCommand }
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

        $script:oversizedPaneScalerLaunchCommand.Length | Should -BeGreaterThan 4000
        Should -Invoke Send-MonitorBridgeCommand -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%3' -and
            $Text -eq $script:oversizedPaneScalerLaunchCommand -and
            $DeliveryClass -eq 'launch'
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
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\pane-status.ps1')
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
    capability_adapter: codex
  - label: operator
    pane_id: %1
    role: Operator
    capability_adapter: codex
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
"@ -Agent 'codex') | Should -Be 'idle'
        (Get-PaneActualStateFromText -Text @"
Launching codex...
codex --sandbox danger-full-access -C C:\repo
"@ -Agent 'codex') | Should -Be 'codex'
        (Get-PaneActualStateFromText -Text @"
gpt-5.4   61% context left
thinking
Esc to interrupt
"@ -Agent 'codex') | Should -Be 'busy'
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
        $script:orchestraLayoutPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-layout.ps1'
        $script:previousWinsmuxBinForLayout = $env:WINSMUX_BIN
        $script:previousBridgeNamespaceForLayout = $env:WINSMUX_BRIDGE_NAMESPACE_L
    }

    BeforeEach {
        Mock Start-Sleep { }
        $env:WINSMUX_BIN = 'winsmux'
        Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
    }

    AfterEach {
        if ($null -ne $script:previousWinsmuxBinForLayout) {
            $env:WINSMUX_BIN = $script:previousWinsmuxBinForLayout
        } else {
            Remove-Item Env:\WINSMUX_BIN -ErrorAction SilentlyContinue
        }

        Remove-Item Function:\global:winsmux -ErrorAction SilentlyContinue
        if ($null -ne $script:previousBridgeNamespaceForLayout) {
            $env:WINSMUX_BRIDGE_NAMESPACE_L = $script:previousBridgeNamespaceForLayout
        } else {
            Remove-Item Env:\WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
        }
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

    It 'qualifies pane and window targets when a bridge namespace is active' {
        $env:WINSMUX_BRIDGE_NAMESPACE_L = 'task781-layout-test'
        $global:winsmuxCalls = [System.Collections.Generic.List[string]]::new()
        $global:layoutPaneIds = @('%2')

        function global:winsmux {
            $global:LASTEXITCODE = 0
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            $global:winsmuxCalls.Add($commandLine) | Out-Null

            switch -Regex ($commandLine) {
                '^-L task781-layout-test has-session ' { return @() }
                '^-L task781-layout-test new-window ' { return '@1 %2' }
                '^-L task781-layout-test set-option ' { return @() }
                '^-L task781-layout-test display-message -t winsmux-orchestra:%2 -p #\{window_id\}$' { return '@1' }
                '^-L task781-layout-test display-message -t winsmux-orchestra:%2 -p #\{pane_width\}x#\{pane_height\}$' { return '120x40' }
                '^-L task781-layout-test split-window -t winsmux-orchestra:%2 -h -p 50$' {
                    $global:layoutPaneIds = @('%2', '%3')
                    return @()
                }
                '^-L task781-layout-test list-panes -t winsmux-orchestra:@1 -F #\{pane_id\}$' { return $global:layoutPaneIds }
                '^-L task781-layout-test select-pane -t winsmux-orchestra:%2$' { return @() }
                '^-L task781-layout-test select-pane -t winsmux-orchestra:%2 -T Builder-1$' { return @() }
                '^-L task781-layout-test select-pane -t winsmux-orchestra:%3 -T Builder-2$' { return @() }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = & $script:orchestraLayoutPath -SessionName 'winsmux-orchestra' -Builders 2

        $result.Total | Should -Be 2
        @($global:winsmuxCalls) | Should -Contain '-L task781-layout-test display-message -t winsmux-orchestra:%2 -p #{window_id}'
        @($global:winsmuxCalls) | Should -Contain '-L task781-layout-test list-panes -t winsmux-orchestra:@1 -F #{pane_id}'
        @($global:winsmuxCalls | Where-Object { $_ -match ' -t [%@]' }).Count | Should -Be 0
    }

    It 'retries Windows connection refused for a read-only layout query' {
        $global:layoutWindowQueryCalls = 0
        $global:layoutPaneIds = @('%2')
        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^has-session ' { $global:LASTEXITCODE = 0; return @() }
                '^new-window ' { $global:LASTEXITCODE = 0; return '@1 %2' }
                '^set-option ' { $global:LASTEXITCODE = 0; return @() }
                '^display-message -t %2 -p #\{window_id\}$' {
                    $global:layoutWindowQueryCalls++
                    if ($global:layoutWindowQueryCalls -eq 1) {
                        $global:LASTEXITCODE = 1
                        return '対象のコンピューターによって拒否されました。 (os error 10061)'
                    }
                    $global:LASTEXITCODE = 0
                    return '@1'
                }
                '^display-message -t %2 -p #\{pane_width\}x#\{pane_height\}$' { $global:LASTEXITCODE = 0; return '120x40' }
                '^split-window -t %2 -h -p 50$' { $global:LASTEXITCODE = 0; $global:layoutPaneIds = @('%2', '%3'); return @() }
                '^list-panes -t @1 -F #\{pane_id\}$' { $global:LASTEXITCODE = 0; return $global:layoutPaneIds }
                '^select-pane ' { $global:LASTEXITCODE = 0; return @() }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = & $script:orchestraLayoutPath -SessionName 'winsmux-orchestra' -Builders 2

        $result.Total | Should -Be 2
        $global:layoutWindowQueryCalls | Should -Be 2
    }

    It 'does not retry a mutating layout command after Windows connection refused' {
        $global:layoutMutationCalls = 0
        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^has-session ' { $global:LASTEXITCODE = 0; return @() }
                '^new-window ' { $global:LASTEXITCODE = 0; return '@1 %2' }
                '^list-panes -t @1 -F #\{pane_id\}$' { $global:LASTEXITCODE = 0; return '%2' }
                '^set-option ' { $global:LASTEXITCODE = 0; return @() }
                '^select-pane ' {
                    $global:layoutMutationCalls++
                    $global:LASTEXITCODE = 1
                    return 'connection refused (os error 10061)'
                }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        { & $script:orchestraLayoutPath -SessionName 'winsmux-orchestra' -Builders 1 } | Should -Throw '*os error 10061*'
        $global:layoutMutationCalls | Should -Be 1
    }
}
