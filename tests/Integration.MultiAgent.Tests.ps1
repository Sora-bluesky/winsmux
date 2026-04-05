$ErrorActionPreference = 'Stop'

Describe 'orchestra cleanup helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'psmux-bridge\scripts\orchestra-cleanup.ps1')
    }

    It 'matches orchestra-managed pane titles only' {
        (Test-OrchestraManagedPaneTitle -Title 'Builder-1') | Should -Be $true
        (Test-OrchestraManagedPaneTitle -Title 'researcher-2') | Should -Be $true
        (Test-OrchestraManagedPaneTitle -Title 'Reviewer-3') | Should -Be $true
        (Test-OrchestraManagedPaneTitle -Title 'Commander') | Should -Be $false
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
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'psmux-bridge\scripts\settings.ps1')
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
        Mock Get-PsmuxOption { param($Name, $Default) return $null }

        $settings = Get-BridgeSettings

        $settings.agent | Should -Be 'codex'
        $settings.model | Should -Be 'gpt-5.4'
        $settings.builders | Should -Be 4
        $settings.researchers | Should -Be 1
        $settings.reviewers | Should -Be 1
        $settings.terminal | Should -Be 'background'
        $settings.vault_keys | Should -Be @('GH_TOKEN')
        $settings.roles | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
        $settings.roles.Count | Should -Be 0
    }
}

Describe 'Get-RoleAgentConfig with fallback' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'psmux-bridge\scripts\settings.ps1')
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

        $commanderConfig = Get-RoleAgentConfig -Role 'Commander' -Settings $settings
        $commanderConfig.Agent | Should -Be 'codex'
        $commanderConfig.Model | Should -Be 'gpt-5.4'
    }
}

Describe 'manifest round-trip' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'psmux-bridge\scripts\manifest.ps1')
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
        $manifest.session.started | Should -Not -BeNullOrEmpty

        $loaded = Get-WinsmuxManifest -ProjectDir $script:manifestTempRoot
        $loaded | Should -Not -BeNullOrEmpty
        $loaded.version | Should -Be 1

        $manifestPath = Get-ManifestPath -ProjectDir $script:manifestTempRoot
        $paneSummaries = @(
            [PSCustomObject]@{ Label = 'builder-1'; PaneId = '%2'; Role = 'Builder'; BuilderWorktreePath = 'C:\repo\.worktrees\builder-1' }
            [PSCustomObject]@{ Label = 'reviewer'; PaneId = '%4'; Role = 'Reviewer'; BuilderWorktreePath = '' }
        )
        Update-ManifestPanes -ManifestPath $manifestPath -PaneSummaries $paneSummaries

        $updated = Get-WinsmuxManifest -ProjectDir $script:manifestTempRoot
        $updated.panes.Count | Should -Be 2
        $updated.panes['builder-1'].pane_id | Should -Be '%2'
        $updated.panes['builder-1'].role | Should -Be 'Builder'
        $updated.panes['builder-1'].builder_worktree_path | Should -Be 'C:\repo\.worktrees\builder-1'
        $updated.panes['reviewer'].role | Should -Be 'Reviewer'
    }
}

Describe 'logger Initialize, Write, and Summary' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'psmux-bridge\scripts\logger.ps1')
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
