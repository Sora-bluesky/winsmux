Set-StrictMode -Version Latest

Describe 'Orchestra end-to-end workflow' {
    BeforeAll {
        $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:RepoRoot = $repoRoot
        . (Join-Path $repoRoot 'psmux-bridge/scripts/settings.ps1')
        . (Join-Path $repoRoot 'psmux-bridge/scripts/role-gate.ps1')
        . (Join-Path $repoRoot 'psmux-bridge/scripts/shared-task-list.ps1')
        . (Join-Path $repoRoot 'psmux-bridge/scripts/task-hooks.ps1')
        . (Join-Path $repoRoot 'psmux-bridge/scripts/agent-lifecycle.ps1')

        function Get-VaultValue {
            throw 'Get-VaultValue must be mocked in tests.'
        }

        function Set-TestAgentLabels {
            param([hashtable]$Labels)

            $winsmuxDir = Join-Path $env:APPDATA 'winsmux'
            New-Item -ItemType Directory -Path $winsmuxDir -Force | Out-Null
            $Labels | ConvertTo-Json | Set-Content -Path (Join-Path $winsmuxDir 'labels.json') -Encoding UTF8
        }

        function Invoke-TestRoleMessage {
            param(
                [string]$Role,
                [string]$FromPane,
                [string]$Command,
                [string]$Target,
                [string]$Text
            )

            $previousRole = $env:WINSMUX_ROLE
            $previousPane = $env:WINSMUX_PANE_ID

            try {
                $env:WINSMUX_ROLE = $Role
                $env:WINSMUX_PANE_ID = $FromPane

                if (-not (Assert-Role -Command $Command -TargetPane $Target)) {
                    throw "Role '$Role' cannot execute '$Command' against '$Target'."
                }

                $script:DeliveredMessages.Add([PSCustomObject]@{
                    From   = $Role
                    Target = $Target
                    Text   = $Text
                }) | Out-Null
            } finally {
                $env:WINSMUX_ROLE = $previousRole
                $env:WINSMUX_PANE_ID = $previousPane
            }
        }

        function New-TestLayout {
            param(
                [int]$Builders,
                [int]$Researchers,
                [int]$Reviewers
            )

            $roles = @()
            for ($i = 1; $i -le $Builders; $i++) { $roles += "Builder-$i" }
            for ($i = 1; $i -le $Researchers; $i++) { $roles += "Researcher-$i" }
            for ($i = 1; $i -le $Reviewers; $i++) { $roles += "Reviewer-$i" }

            return [PSCustomObject]@{
                Total = $roles.Count
                Panes = @(
                    for ($index = 0; $index -lt $roles.Count; $index++) {
                        [PSCustomObject]@{
                            PaneId = "%$($index + 1)"
                            Role   = $roles[$index]
                        }
                    }
                )
            }
        }

        function Invoke-TestOrchestraStartup {
            param([string]$ProjectDir)

            $settings = Get-BridgeSettings
            $vaultValues = [ordered]@{}
            foreach ($key in @($settings.vault_keys)) {
                $vaultValues[$key] = Get-VaultValue -Key $key
            }

            $layout = New-TestLayout -Builders $settings.builders -Researchers $settings.researchers -Reviewers $settings.reviewers
            $launchCommand = Get-AgentLaunchCommandFromSettings -ProjectDir $ProjectDir
            $roleAssignments = @{}

            foreach ($pane in @($layout.Panes)) {
                $canonicalRole = ConvertTo-InferredWinsmuxRole -Value ([string]$pane.Role)
                $roleAssignments[[string]$pane.PaneId] = $canonicalRole
                $script:DeliveredMessages.Add([PSCustomObject]@{
                    From   = 'startup'
                    Target = [string]$pane.PaneId
                    Text   = $launchCommand
                }) | Out-Null
            }

            return [PSCustomObject]@{
                Settings        = $settings
                VaultValues     = $vaultValues
                Layout          = $layout
                LaunchCommand   = $launchCommand
                RoleAssignments = $roleAssignments
            }
        }
    }

    BeforeEach {
        $script:OriginalAppData = $env:APPDATA
        $script:OriginalRole = $env:WINSMUX_ROLE
        $script:OriginalPane = $env:WINSMUX_PANE_ID
        $script:OriginalCommanderTarget = $env:WINSMUX_COMMANDER_TARGET
        $env:APPDATA = Join-Path $TestDrive 'AppData'
        New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null
        Set-TestAgentLabels @{
            commander = '%1'
            'builder-1' = '%2'
            'reviewer-1' = '%3'
            'researcher-1' = '%4'
        }
        $env:WINSMUX_COMMANDER_TARGET = 'commander'
        Set-Location -LiteralPath $TestDrive
        Initialize-SharedTaskStore
        $script:DeliveredMessages = [System.Collections.Generic.List[object]]::new()
        $script:AgentLifecycleState = @{}
        $script:AgentConfigCache = @{}
        Mock Start-Sleep {}
    }

    AfterEach {
        Set-Location -LiteralPath $script:RepoRoot
        $env:APPDATA = $script:OriginalAppData
        $env:WINSMUX_ROLE = $script:OriginalRole
        $env:WINSMUX_PANE_ID = $script:OriginalPane
        $env:WINSMUX_COMMANDER_TARGET = $script:OriginalCommanderTarget
    }

    Context 'startup sequence' {
        It 'loads settings, validates vault keys, creates layout, assigns roles, and launches agents' {
            Mock Get-BridgeSettings {
                [ordered]@{
                    agent       = 'codex'
                    model       = 'gpt-5.4'
                    builders    = 2
                    researchers = 1
                    reviewers   = 1
                    vault_keys  = @('GH_TOKEN', 'OPENAI_API_KEY')
                }
            }
            Mock Get-VaultValue { param([string]$Key) "value-for-$Key" }
            Mock Get-AgentLifecycleSettings { Get-BridgeSettings }
            Mock Get-AgentLifecycleGitWorktreeDir { 'C:\repo\.git' }

            $result = Invoke-TestOrchestraStartup -ProjectDir 'C:\repo'

            $result.Settings.builders | Should Be 2
            $result.Layout.Total | Should Be 4
            $result.VaultValues.Keys.Count | Should Be 2
            ((@($result.RoleAssignments.Values) -contains 'Builder')) | Should Be $true
            ((@($result.RoleAssignments.Values) -contains 'Researcher')) | Should Be $true
            ((@($result.RoleAssignments.Values) -contains 'Reviewer')) | Should Be $true
            $script:DeliveredMessages.Count | Should Be 4
            $script:DeliveredMessages[0].Text | Should Match '^codex -c model=gpt-5\.4'
            Assert-MockCalled Get-BridgeSettings -Times 2 -Exactly
            Assert-MockCalled Get-VaultValue -Times 2 -Exactly
        }
    }

    Context 'Commander dispatch workflow' {
        It 'routes work from Commander to Builder and Reviewer with completion notifications' {
            function Get-CommanderTargets {
                return @('commander', 'commander-shadow')
            }

            function Invoke-BridgeSend {
                param([string]$Target, [string]$Text)
                $script:DeliveredMessages.Add([PSCustomObject]@{
                    From   = 'task-hooks'
                    Target = $Target
                    Text   = $Text
                }) | Out-Null
                'ok'
            }

            $task = Add-SharedTask -Title 'Implement orchestration flow'

            Invoke-TestRoleMessage -Role 'Commander' -FromPane '%1' -Command 'dispatch' -Target 'builder-1' -Text "Build $($task.id)"
            $builderTask = Claim-SharedTask -TaskId $task.id -AgentName 'builder-1'
            $completion = OnTaskCompleted -Task $builderTask -NewlyUnblocked @()
            Invoke-TestRoleMessage -Role 'Commander' -FromPane '%1' -Command 'dispatch' -Target 'reviewer-1' -Text "Review $($task.id)"
            Invoke-TestRoleMessage -Role 'Reviewer' -FromPane '%3' -Command 'send' -Target 'commander' -Text "PASS $($task.id)"

            ((@($script:DeliveredMessages.Target) -contains 'builder-1')) | Should Be $true
            ((@($script:DeliveredMessages.Text) -contains "Build $($task.id)")) | Should Be $true
            $completion.Notified | Should Be $true
            ((@($script:DeliveredMessages.Target) -contains 'commander')) | Should Be $true
            ((@($script:DeliveredMessages.Text | Where-Object { $_ -like 'Task completed:*' }).Count) -ge 1) | Should Be $true
            ((@($script:DeliveredMessages.Target) -contains 'reviewer-1')) | Should Be $true
            ((@($script:DeliveredMessages.Text) -contains "Review $($task.id)")) | Should Be $true
            ((@($script:DeliveredMessages.Text) -contains "PASS $($task.id)")) | Should Be $true
        }
    }

    Context 'role isolation' {
        It 'blocks cross-pane reads, vault access, and unauthorized dispatch' {
            $env:WINSMUX_ROLE = 'Builder'
            $env:WINSMUX_PANE_ID = '%2'
            $builderReadOther = Assert-Role -Command 'read' -TargetPane 'reviewer-1'
            $builderVault = Assert-Role -Command 'vault'

            $env:WINSMUX_ROLE = 'Researcher'
            $env:WINSMUX_PANE_ID = '%4'
            $researcherDispatch = Assert-Role -Command 'dispatch' -TargetPane 'builder-1'

            $builderReadOther | Should Be $false
            $builderVault | Should Be $false
            $researcherDispatch | Should Be $false
        }
    }

    Context 'agent lifecycle' {
        It 'respawns dead agents and notifies Commander' {
            Mock Get-LabeledPaneAssignments {
                @([PSCustomObject]@{ Label = 'builder-1'; PaneId = '%2' })
            }
            Mock Get-AgentConfig {
                [PSCustomObject]@{
                    PaneId           = '%2'
                    Label            = 'builder-1'
                    LaunchCommand    = 'codex -c model=gpt-5.4'
                    WorkingDirectory = 'C:\repo'
                }
            }
            Mock Get-AgentHealth {
                [PSCustomObject]@{
                    PaneId = '%2'
                    Label  = 'builder-1'
                    State  = 'DEAD'
                }
            }
            Mock Restart-Agent { [PSCustomObject]@{ PaneId = '%2'; RestartedAt = 'now' } }
            function Get-AgentLifecycleCommanderTargets {
                return @('commander', 'commander-shadow')
            }
            function Send-AgentLifecycleBridgeMessage {
                param([string]$Target, [string]$Text)
                $script:DeliveredMessages.Add([PSCustomObject]@{
                    From   = 'lifecycle'
                    Target = $Target
                    Text   = $Text
                }) | Out-Null
            }

            Invoke-AgentMonitorPass -IntervalSeconds 0

            Assert-MockCalled Restart-Agent -Times 1 -Exactly
            $script:DeliveredMessages.Count | Should Be 2
            ((@($script:DeliveredMessages.Target) -contains 'commander')) | Should Be $true
            ((@($script:DeliveredMessages.Text) -contains 'Agent restarted: builder-1 (%2) after DEAD')) | Should Be $true
        }
    }
}
