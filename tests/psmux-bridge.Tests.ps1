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

    $escapedPath = $Path -replace '"', '""'
    if ([string]::IsNullOrEmpty($Content)) {
        cmd /d /c ('type nul > "{0}"' -f $escapedPath) | Out-Null
    } else {
        $Content | cmd /d /c ('more > "{0}"' -f $escapedPath) | Out-Null
    }

    if ($LASTEXITCODE -ne 0) {
        throw "cmd.exe failed to write $Path"
    }
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
            commander  = 'pane-commander'
            builder    = 'pane-builder'
            worker     = 'pane-worker'
            researcher = 'pane-researcher'
            reviewer   = 'pane-reviewer'
        } | ConvertTo-Json | Set-Content -Path $labelsPath -Encoding UTF8

        $script:roleGateTempRoot = $tempRoot
        $script:RoleGateLabelsFile = $labelsPath
        $env:WINSMUX_PANE_ID = 'pane-self'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Commander","pane-commander":"Commander","pane-builder":"Builder","pane-worker":"Worker","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'
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
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Reviewer","pane-commander":"Commander","pane-builder":"Builder","pane-worker":"Worker","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'commander') | Should -Be $true
        (Assert-Role -Command 'review-request') | Should -Be $true
        (Assert-Role -Command 'review-approve') | Should -Be $true
        (Assert-Role -Command 'status') | Should -Be $true
        (Assert-Role -Command 'list') | Should -Be $true
        (Assert-Role -Command 'vault') | Should -Be $false
        (Assert-Role -Command 'focus') | Should -Be $false
    }

    It 'allows Worker to act as a review-capable pane while staying non-privileged' {
        $env:WINSMUX_ROLE = 'Worker'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Worker","pane-commander":"Commander","pane-builder":"Builder","pane-worker":"Worker","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'message' -TargetPane 'commander') | Should -Be $true
        (Assert-Role -Command 'review-request') | Should -Be $true
        (Assert-Role -Command 'review-approve') | Should -Be $true
        (Assert-Role -Command 'review-fail') | Should -Be $true
        (Assert-Role -Command 'vault') | Should -Be $false
        (Assert-Role -Command 'focus') | Should -Be $false
    }

    It 'denies review approval commands outside Reviewer role' {
        $env:WINSMUX_ROLE = 'Builder'
        $env:WINSMUX_ROLE_MAP = '{"pane-self":"Builder","pane-commander":"Commander","pane-builder":"Builder","pane-researcher":"Researcher","pane-reviewer":"Reviewer"}'

        (Assert-Role -Command 'review-request') | Should -Be $false
        (Assert-Role -Command 'review-approve') | Should -Be $false
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
        $settings.external_commander | Should -Be $true
        $settings.legacy_role_layout | Should -Be $false
        $settings.commanders | Should -Be 0
        $settings.worker_count | Should -Be 6
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
external-commander: false
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
                '@bridge-external-commander' { 'on' }
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
        $settings.external_commander | Should -Be $false
        $settings.legacy_role_layout | Should -Be $true
        $settings.worker_count | Should -Be 9
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

Describe 'Get-OrchestraLayoutSettings' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-start.ps1')
    }

    It 'uses external commander mode by default' {
        $layout = Get-OrchestraLayoutSettings -Settings ([ordered]@{
            external_commander = $true
            worker_count       = 6
            legacy_role_layout = $false
            commanders         = 0
            builders           = 0
            researchers        = 0
            reviewers          = 0
        })

        $layout.ExternalCommander | Should -Be $true
        $layout.LegacyRoleLayout | Should -Be $false
        $layout.Commanders | Should -Be 0
        $layout.Workers | Should -Be 6
        $layout.Builders | Should -Be 0
        $layout.Researchers | Should -Be 0
        $layout.Reviewers | Should -Be 0
    }

    It 'preserves legacy role layouts when explicit legacy counts are configured' {
        $layout = Get-OrchestraLayoutSettings -Settings ([ordered]@{
            external_commander = $true
            worker_count       = 6
            legacy_role_layout = $false
            commanders         = 0
            builders           = 4
            researchers        = 1
            reviewers          = 1
        })

        $layout.ExternalCommander | Should -Be $false
        $layout.LegacyRoleLayout | Should -Be $true
        $layout.Commanders | Should -Be 0
        $layout.Workers | Should -Be 0
        $layout.Builders | Should -Be 4
        $layout.Researchers | Should -Be 1
        $layout.Reviewers | Should -Be 1
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

        $workerTargets = Get-TeamPipelineStageTargets -BuilderLabel 'worker-1' -ResearcherLabel '' -ReviewerLabel ''
        $workerTargets.PlanTarget | Should -Be 'worker-1'
        $workerTargets.VerifyTarget | Should -Be 'worker-1'

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
      "target_reviewer_label": "reviewer",
      "target_reviewer_pane_id": "%3"
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
}

Describe 'orchestra-start watchdog contract' {
    BeforeAll {
        $script:orchestraStartPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-start.ps1'
        $script:orchestraStartContent = Get-Content -Path $script:orchestraStartPath -Raw -Encoding UTF8
    }

    It 'launches commander-poll with Start-Process before the watchdog' {
        $script:orchestraStartContent | Should -Match 'function Start-CommanderPollJob \{'
        $script:orchestraStartContent | Should -Match 'commander-poll\.ps1'
        $script:orchestraStartContent | Should -Match "'-Interval'"
        $script:orchestraStartContent | Should -Match '-Interval 20'
        $script:orchestraStartContent | Should -Match '-CommanderPollPid \$commanderPollProcess\.Id'

        $commanderPollIndex = $script:orchestraStartContent.IndexOf('$commanderPollProcess = Start-CommanderPollJob')
        $watchdogIndex = $script:orchestraStartContent.IndexOf('$watchdogProcess = Start-AgentWatchdogJob')
        $commanderPollIndex | Should -BeGreaterThan -1
        $watchdogIndex | Should -BeGreaterThan -1
        $commanderPollIndex | Should -BeLessThan $watchdogIndex
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
        $script:orchestraStartContent | Should -Match 'commander_poll_pid\s*=\s*\$CommanderPollPid'
        $script:orchestraStartContent | Should -Match 'Commander Poll PID: \$\(\$commanderPollProcess\.Id\)'
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

        $result = Ensure-OrchestraServer -SessionName 'winsmux-orchestra'

        $result.SessionName | Should -Be 'winsmux-orchestra'
        $result.SessionCreated | Should -Be $false
        $script:probeCount | Should -Be 1
        $script:newSessionCallCount | Should -Be 0
    }

    It 'launches Windows Terminal and polls until panes are available when the session is missing' {
        $script:probeCount = 0
        $script:startProcessFilePath = $null
        $script:startProcessArgumentList = @()
        $script:listPanesCallCount = 0
        $script:sleepCallCount = 0
        $script:waitHealthyCount = 0

        function Test-OrchestraServerSession {
            param([string]$SessionName)
            $script:probeCount++
            return ($script:probeCount -ge 3)
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

            $script:startProcessFilePath = $FilePath
            $script:startProcessArgumentList = @($ArgumentList)
        }

        function Invoke-Winsmux {
            param([string[]]$Arguments, [switch]$CaptureOutput)

            if ($Arguments[0] -eq 'list-panes') {
                $script:listPanesCallCount++
                return @('%1')
            }

            throw "unexpected winsmux call: $($Arguments -join ' ')"
        }

        function Start-Sleep {
            param([int]$Milliseconds)
            if ($Milliseconds -eq 500) {
                $script:sleepCallCount++
            }
        }

        function Wait-OrchestraServerHealthy {
            param([string]$SessionName, [string]$WinsmuxBin, [int]$TimeoutSeconds, [int]$PollIntervalMilliseconds)
            $script:waitHealthyCount++
            return [ordered]@{ SessionName = $SessionName; Health = 'Healthy'; Attempts = 1 }
        }

        $result = Ensure-OrchestraServer -SessionName 'winsmux-orchestra'

        $result.SessionName | Should -Be 'winsmux-orchestra'
        $result.SessionCreated | Should -Be $true
        $script:probeCount | Should -Be 3
        $script:sleepCallCount | Should -Be 1
        $script:listPanesCallCount | Should -Be 1
        $script:waitHealthyCount | Should -Be 1
        $script:startProcessFilePath | Should -Be 'C:\Windows\System32\wt.exe'
        $script:startProcessArgumentList | Should -Be @(
            '--size', '200,70',
            '--title', 'winsmux-orchestra',
            '--',
            'winsmux', 'new-session', '-s', 'winsmux-orchestra'
        )
    }

    It 'resets a stale session by killing it, clearing registration, and recreating it' {
        $script:killCalls = 0
        $script:clearCalls = 0
        $script:ensureCalls = 0
        $script:waitCalls = 0

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

        function Ensure-OrchestraServer {
            param([string]$SessionName, [int]$TimeoutSeconds = 30)
            $script:ensureCalls++
            return [ordered]@{
                SessionName    = $SessionName
                SessionCreated = $true
            }
        }

        function Wait-OrchestraServerHealthy {
            param([string]$SessionName, [string]$WinsmuxBin, [int]$TimeoutSeconds = 15, [int]$PollIntervalMilliseconds = 500)
            $script:waitCalls++
            return [ordered]@{
                SessionName = $SessionName
                Health      = 'Healthy'
                Attempts    = 1
            }
        }

        Mock Test-OrchestraServerSession { $true }

        $result = Reset-OrchestraServerSession -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux' -Reason 'test'

        $result.SessionCreated | Should -Be $true
        $result.Health | Should -Be 'Healthy'
        $script:killCalls | Should -Be 1
        $script:clearCalls | Should -Be 1
        $script:ensureCalls | Should -Be 1
        $script:waitCalls | Should -Be 1
    }

    It 'fails closed when a background watchdog process exits immediately' {
        $process = [PSCustomObject]@{
            HasExited = $true
            ExitCode  = 23
        }

        { Assert-OrchestraBackgroundProcessStarted -Process $process -Name 'Server watchdog job' -StartupDelayMilliseconds 1 } | Should -Throw '*exited immediately*'
    }

    It 'fails closed when Windows Terminal is unavailable' {
        function Test-OrchestraServerSession {
            param([string]$SessionName)
            return $false
        }

        function Get-Command {
            param([string]$Name)
            return $null
        }

        { Ensure-OrchestraServer -SessionName 'winsmux-orchestra' } | Should -Throw '*wt.exe*'
    }
}

Describe 'orchestra-start session reuse contract' {
    BeforeAll {
        $script:orchestraStartPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-start.ps1'
        $script:orchestraStartContent = Get-Content -Path $script:orchestraStartPath -Raw -Encoding UTF8
    }

    It 'reuses the session Ensure-OrchestraServer just created' {
        $script:orchestraStartContent | Should -Match '\$orchestraServer\s*=\s*Ensure-OrchestraServer -SessionName \$sessionName'
        $script:orchestraStartContent | Should -Match "preflight\.session\.ready"
        $script:orchestraStartContent | Should -Match 'Session \$sessionName created by Ensure-OrchestraServer\.'
        $script:orchestraStartContent | Should -Not -Match "preflight\.session\.create"
        $script:orchestraStartContent | Should -Not -Match "new-session', '-d'"
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

Describe 'winsmux send dispatch payload' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\winsmux-core.ps1'
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
        $summary.messages[0] | Should -Be 'builder-1 (%2) がアイドル。次タスクのディスパッチが必要'
        Should -Invoke Write-CommanderPollLog -Times 1 -Exactly -ParameterFilter {
            $EventName -eq 'commander.poll.idle_dispatch_needed' -and
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
  project_dir: $script:commanderPollTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    launch_dir: $script:commanderPollTempRoot
"@ | Set-Content -Path $script:commanderPollManifestPath -Encoding UTF8

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
        $summary.messages[0] | Should -Be 'builder-1 (%2) がアイドル。次タスクのディスパッチが必要'
    }

    It 'prefers a worker as the review target when no reviewer pane exists' {
@"
version: 1
saved_at: 2026-04-09T11:00:00+09:00
session:
  name: winsmux-orchestra
  project_dir: $script:commanderPollTempRoot
panes:
  worker-1:
    pane_id: %2
    role: Worker
    launch_dir: $script:commanderPollTempRoot
"@ | Set-Content -Path $script:commanderPollManifestPath -Encoding UTF8

        $manifest = Read-CommanderPollManifest -Path $script:commanderPollManifestPath
        $reviewPane = Get-CommanderPollPreferredReviewPane -Manifest $manifest

        $reviewPane.PaneId | Should -Be '%2'
        $reviewPane.Label | Should -Be 'worker-1'
        $reviewPane.Role | Should -Be 'Worker'
    }

    It 'appends commander poll log records as jsonl' {
        Write-CommanderPollLog -ProjectDir $script:commanderPollTempRoot -SessionName 'winsmux-orchestra' -EventName 'commander.poll.idle_dispatch_needed' -Message 'idle' -PaneId '%2'
        Write-CommanderPollLog -ProjectDir $script:commanderPollTempRoot -SessionName 'winsmux-orchestra' -EventName 'commander.poll.auto_approved' -Message 'approved' -PaneId '%2'

        $logPath = Get-CommanderPollLogPath -ProjectDir $script:commanderPollTempRoot
        $lines = @(Get-Content -Path $logPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $lines.Count | Should -Be 2
        ($lines[0] | ConvertFrom-Json).event | Should -Be 'commander.poll.idle_dispatch_needed'
        ($lines[1] | ConvertFrom-Json).event | Should -Be 'commander.poll.auto_approved'
    }

    It 'does not forward commander dispatch-needed alerts to Telegram by default' {
        Mock Test-Path { $true }
        Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
        Mock Invoke-RestMethod { }

        Send-CommanderTelegramNotification -ProjectDir $script:commanderPollTempRoot -SessionName 'winsmux-orchestra' `
            -Event 'commander.dispatch_needed' -Message 'idle' -PaneId '%2' -Label 'builder-1' -Role 'Builder'

        Should -Not -Invoke Invoke-RestMethod
    }

    It 'allows internal commander Telegram alerts only when explicitly overridden' {
        $previousOverride = $env:WINSMUX_TELEGRAM_INCLUDE_INTERNAL_EVENTS
        $env:WINSMUX_TELEGRAM_INCLUDE_INTERNAL_EVENTS = 'true'

        try {
            Mock Test-Path { $true }
            Mock Get-Content { 'TELEGRAM_BOT_TOKEN=test-token' }
            Mock Invoke-RestMethod { }

            Send-CommanderTelegramNotification -ProjectDir $script:commanderPollTempRoot -SessionName 'winsmux-orchestra' `
                -Event 'commander.dispatch_needed' -Message 'idle' -PaneId '%2' -Label 'builder-1' -Role 'Builder'

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        } finally {
            if ($null -eq $previousOverride) {
                Remove-Item Env:WINSMUX_TELEGRAM_INCLUDE_INTERNAL_EVENTS -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_TELEGRAM_INCLUDE_INTERNAL_EVENTS = $previousOverride
            }
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
