$ErrorActionPreference = 'Stop'

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
            commander  = 'pane-commander'
            builder    = 'pane-builder'
            researcher = 'pane-researcher'
            reviewer   = 'pane-reviewer'
        } | ConvertTo-Json | Set-Content -Path $labelsPath -Encoding UTF8

        $script:roleGateTempRoot = $tempRoot
        $script:RoleGateLabelsFile = $labelsPath
        $env:WINSMUX_PANE_ID = 'pane-self'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Commander","pane-commander":"Commander","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'
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

    It 'allows Commander to send anywhere and denies typing into another pane' {
        $env:WINSMUX_ROLE = 'Commander'

        (Assert-Role -Command 'send' -TargetPane 'reviewer') | Should -Be $true
        (Assert-Role -Command 'vault') | Should -Be $true
        (Assert-Role -Command 'type' -TargetPane 'reviewer') | Should -Be $false
    }

    It 'allows Builder to message Commander and denies sending to peers' {
        $env:WINSMUX_ROLE = 'Builder'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Builder","pane-commander":"Commander","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'send' -TargetPane 'commander') | Should -Be $true
        (Assert-Role -Command 'type' -TargetPane 'self') | Should -Be $true
        (Assert-Role -Command 'send' -TargetPane 'reviewer') | Should -Be $false
        (Assert-Role -Command 'read' -TargetPane 'reviewer') | Should -Be $false
    }

    It 'allows Researcher to message Commander and denies orchestration commands' {
        $env:WINSMUX_ROLE = 'Researcher'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Researcher","pane-commander":"Commander","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'commander') | Should -Be $true
        (Assert-Role -Command 'read' -TargetPane 'self') | Should -Be $true
        (Assert-Role -Command 'signal') | Should -Be $false
        (Assert-Role -Command 'wait') | Should -Be $false
    }

    It 'allows Reviewer to message Commander and denies privileged commands' {
        $env:WINSMUX_ROLE = 'Reviewer'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Reviewer","pane-commander":"Commander","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'commander') | Should -Be $true
        (Assert-Role -Command 'list') | Should -Be $true
        (Assert-Role -Command 'vault') | Should -Be $false
        (Assert-Role -Command 'focus') | Should -Be $false
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
        Mock Get-PsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings

        $settings.agent | Should -Be 'codex'
        $settings.model | Should -Be 'gpt-5.4'
        $settings.builders | Should -Be 4
        $settings.researchers | Should -Be 1
        $settings.reviewers | Should -Be 1
        $settings.terminal | Should -Be 'background'
        $settings.vault_keys | Should -Be @('GH_TOKEN')
    }

    It 'applies global overrides and lets project settings take precedence per key' {
        @'
agent: claude
reviewers: 3
vault-keys:
  - GH_TOKEN
  - OPENAI_API_KEY
terminal: tab
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.psmux-bridge.yaml') -Encoding UTF8

        Mock Get-PsmuxOption {
            param($Name, $Default)

            switch ($Name) {
                '@bridge-agent' { 'gemini' }
                '@bridge-model' { 'gpt-5.5-mini' }
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
        $settings.builders | Should -Be 7
        $settings.researchers | Should -Be 2
        $settings.reviewers | Should -Be 3
        $settings.terminal | Should -Be 'tab'
        $settings.vault_keys | Should -Be @('GH_TOKEN', 'OPENAI_API_KEY')
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
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.psmux-bridge.yaml') -Encoding UTF8

        Mock Get-PsmuxOption { param($Name, $Default) return $null }

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

        $commanderConfig = Get-RoleAgentConfig -Role 'Commander' -Settings $settings
        $commanderConfig.Agent | Should -Be 'codex'
        $commanderConfig.Model | Should -Be 'gpt-5.4'
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

    It 'detects approval prompts and blocks dangerous confirmations' {
        $typeEnter = Get-TeamPipelineApprovalAction -Text "Do you want to proceed?`n1. Yes"
        $typeEnter.Kind | Should -Be 'TypeEnter'
        $typeEnter.Value | Should -Be '1'

        $shellConfirm = Get-TeamPipelineApprovalAction -Text 'Continue [Y/n]'
        $shellConfirm.Value | Should -Be 'y'

        { Get-TeamPipelineApprovalAction -Text 'Approve command: git reset --hard origin/main' } | Should -Throw
    }

    It 'selects sensible planning and verification targets from the available roles' {
        $defaultTargets = Get-TeamPipelineStageTargets -BuilderLabel 'builder-1' -ResearcherLabel 'researcher' -ReviewerLabel 'reviewer'
        $defaultTargets.PlanTarget | Should -Be 'researcher'
        $defaultTargets.BuildTarget | Should -Be 'builder-1'
        $defaultTargets.VerifyTarget | Should -Be 'reviewer'

        $fallbackTargets = Get-TeamPipelineStageTargets -BuilderLabel 'builder-1' -ResearcherLabel '' -ReviewerLabel ''
        $fallbackTargets.PlanTarget | Should -Be 'builder-1'
        $fallbackTargets.VerifyTarget | Should -Be 'builder-1'

        $skipTargets = Get-TeamPipelineStageTargets -BuilderLabel 'builder-1' -ResearcherLabel 'researcher' -ReviewerLabel 'reviewer' -SkipPlan -SkipVerify
        $skipTargets.PlanTarget | Should -BeNullOrEmpty
        $skipTargets.VerifyTarget | Should -BeNullOrEmpty
    }
}

Describe 'logger helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\logger.ps1')
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

        $lines = @(Get-Content -Path $logPath -Encoding UTF8)
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
}

Describe 'agent-monitor helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\agent-monitor.ps1')
    }

    It 'treats Codex context exhaustion followed by a PowerShell prompt as a crash reason' {
        Mock Invoke-MonitorPsmux {
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
        Mock Invoke-MonitorPsmux {
            @(
                'gpt-5.4   0% context left'
                '⏎ send   Ctrl+J newline'
            )
        }

        $status = Get-PaneAgentStatus -PaneId '%2' -Agent 'codex'

        $status.Status | Should -Be 'ready'
        $status.ExitReason | Should -Be ''
    }

    It 'respawns the pane in the launch directory before sending the agent command' {
        Mock Invoke-MonitorPsmux { } -ParameterFilter {
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
        Should -Invoke Invoke-MonitorPsmux -Times 1 -Exactly -ParameterFilter {
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
            $Text -eq "codex -c model=gpt-5.4 --full-auto -C 'C:\repo\.worktrees\builder-1' --add-dir 'C:\repo\.git\worktrees\builder-1'"
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
}

Describe 'agent-watchdog helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\agent-watchdog.ps1')
    }

    It 'runs a watchdog cycle through Invoke-AgentMonitorCycle with the requested thresholds' {
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

        $result = Invoke-AgentWatchdogCycle -ManifestPath 'C:\repo\.winsmux\manifest.yaml' -SessionName 'winsmux-orchestra' -IdleThreshold 120

        $result.Checked | Should -Be 1
        Should -Invoke Invoke-AgentMonitorCycle -Times 1 -Exactly -ParameterFilter {
            $ManifestPath -eq 'C:\repo\.winsmux\manifest.yaml' -and
            $SessionName -eq 'winsmux-orchestra' -and
            $IdleThreshold -eq 120
        }
    }
}

Describe 'orchestra-start watchdog contract' {
    BeforeAll {
        $script:orchestraStartPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-start.ps1'
        $script:orchestraStartContent = Get-Content -Path $script:orchestraStartPath -Raw -Encoding UTF8
    }

    It 'launches the watchdog with Start-Process so it survives script exit' {
        $script:orchestraStartContent | Should -Match 'function Start-AgentWatchdogJob \{'
        $script:orchestraStartContent | Should -Match 'Start-Process\s+-FilePath\s+''pwsh'''
        $script:orchestraStartContent | Should -Match "'-NoProfile'"
        $script:orchestraStartContent | Should -Match "'-File'"
        $script:orchestraStartContent | Should -Match '-WindowStyle\s+Hidden\s+-PassThru'
        $script:orchestraStartContent | Should -Not -Match 'Start-Job\s+-Name\s+\("winsmux-watchdog-'
    }

    It 'persists watchdog_pid and prints watchdog cleanup guidance' {
        $script:orchestraStartContent | Should -Match 'watchdog_pid:'
        $script:orchestraStartContent | Should -Match '-WatchdogPid \$watchdogProcess\.Id'
        $script:orchestraStartContent | Should -Match 'Watchdog PID: \$\(\$watchdogProcess\.Id\)'
        $script:orchestraStartContent | Should -Match 'Stop-Process -Id'
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

    It 'scales up when workload exceeds the threshold' {
        Mock Get-PaneWorkload {
            [PSCustomObject]@{
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
