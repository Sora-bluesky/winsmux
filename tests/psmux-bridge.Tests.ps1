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
        (Assert-Role -Command 'status') | Should -Be $true
        (Assert-Role -Command 'context-reset' -TargetPane 'reviewer') | Should -Be $true
        (Assert-Role -Command 'poll-events') | Should -Be $true
        (Assert-Role -Command 'vault') | Should -Be $true
        (Assert-Role -Command 'type' -TargetPane 'reviewer') | Should -Be $false
    }

    It 'allows Builder to message Commander and denies sending to peers' {
        $env:WINSMUX_ROLE = 'Builder'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Builder","pane-commander":"Commander","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'send' -TargetPane 'commander') | Should -Be $true
        (Assert-Role -Command 'status') | Should -Be $true
        (Assert-Role -Command 'type' -TargetPane 'self') | Should -Be $true
        (Assert-Role -Command 'context-reset' -TargetPane 'commander') | Should -Be $false
        (Assert-Role -Command 'send' -TargetPane 'reviewer') | Should -Be $false
        (Assert-Role -Command 'read' -TargetPane 'reviewer') | Should -Be $false
    }

    It 'allows Researcher to message Commander and denies orchestration commands' {
        $env:WINSMUX_ROLE = 'Researcher'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Researcher","pane-commander":"Commander","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'commander') | Should -Be $true
        (Assert-Role -Command 'read' -TargetPane 'self') | Should -Be $true
        (Assert-Role -Command 'poll-events') | Should -Be $false
        (Assert-Role -Command 'signal') | Should -Be $false
        (Assert-Role -Command 'wait') | Should -Be $false
    }

    It 'allows Reviewer to message Commander and denies privileged commands' {
        $env:WINSMUX_ROLE = 'Reviewer'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Reviewer","pane-commander":"Commander","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'commander') | Should -Be $true
        (Assert-Role -Command 'status') | Should -Be $true
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
        Mock Get-WinsmuxOption { param($Name, $Default) return $null }

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
'@ | Set-Content -Path (Join-Path $script:settingsTempRoot '.winsmux.yaml') -Encoding UTF8

        Mock Get-WinsmuxOption {
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
        $manifestContent | Should -Match $([regex]::Escape("- label: 'builder-2'"))
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

    BeforeEach {
        Mock Send-MonitorCommanderMailboxMessage { return $true }
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
            $manifestContent | Should -Match '(?m)^  - label: builder-2$'
            $manifestContent | Should -Not -Match '(?m)^  - label: builder-1$'
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
                        Message     = 'Commander alert: idle pane builder-1 (%2, role=Builder)'
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
  - label: commander
    pane_id: %1
    role: Commander
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
        $entries[2].Label | Should -Be 'commander'
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

        $records[2].Label | Should -Be 'commander'
        $records[2].State | Should -Be 'busy'
        $records[2].TokensRemaining | Should -Be '61% context left'
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
                '^capture-pane .*%2' { return @('Implementation finished.', '>') }
                '^capture-pane .*%4' { return @('Review in progress...') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
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

Describe 'commander-poll helpers' {
    BeforeAll {
        $script:commanderPollScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\commander-poll.ps1'
    }

    BeforeEach {
        $script:commanderPollTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-commander-poll-tests-' + [guid]::NewGuid().ToString('N'))
        $script:commanderPollManifestDir = Join-Path $script:commanderPollTempRoot '.winsmux'
        $script:commanderPollManifestPath = Join-Path $script:commanderPollManifestDir 'manifest.yaml'
        New-Item -ItemType Directory -Path $script:commanderPollManifestDir -Force | Out-Null

@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:commanderPollTempRoot
panes:
  - label: builder-1
    pane_id: %2
    role: Builder
    launch_dir: $script:commanderPollTempRoot
"@ | Set-Content -Path $script:commanderPollManifestPath -Encoding UTF8

        . $script:commanderPollScriptPath -ManifestPath $script:commanderPollManifestPath
    }

    AfterEach {
        if ($script:commanderPollTempRoot -and (Test-Path $script:commanderPollTempRoot)) {
            Remove-Item -Path $script:commanderPollTempRoot -Recurse -Force
        }
    }

    It 'processes mailbox idle messages and logs dispatch-needed guidance' {
        Mock Receive-CommanderPollMailboxMessages {
            @(
                [ordered]@{
                    timestamp   = '2026-04-07T09:00:00.0000000+09:00'
                    session     = 'winsmux-orchestra'
                    event       = 'pane.idle'
                    message     = 'Commander alert: idle pane builder-1 (%2, role=Builder)'
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
        Mock Write-CommanderPollLog { }

        $cycle = Invoke-CommanderPollCycle -ManifestPath $script:commanderPollManifestPath -ProcessedLineCount 0 -ProcessedEventSignatures ([ordered]@{})
        $summary = $cycle['Summary']

        $summary.mailbox_events | Should -Be 1
        $summary.new_events | Should -Be 1
        $summary.dispatches | Should -Be 1
        $summary.messages[0] | Should -Be 'Commander should dispatch next task to builder-1 (%2)'
        Should -Invoke Write-CommanderPollLog -Times 1 -Exactly -ParameterFilter {
            $EventName -eq 'commander.poll.idle_dispatch_needed' -and
            $PaneId -eq '%2' -and
            $Message -eq 'Commander should dispatch next task to builder-1 (%2)'
        }
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
}
