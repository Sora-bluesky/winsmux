$ErrorActionPreference = 'Stop'

Describe 'orchestra preflight zombie detection' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\orchestra-preflight.ps1')
        $script:NewPreflightSnapshot = {
            param([Parameter(Mandatory = $true)][object[]]$Processes)

            $byId = @{}
            $childrenByParent = @{}

            foreach ($process in $Processes) {
                $processId = [int]$process.ProcessId
                $parentId = [int]$process.ParentProcessId
                $byId[$processId] = $process

                if (-not $childrenByParent.ContainsKey($parentId)) {
                    $childrenByParent[$parentId] = [System.Collections.Generic.List[object]]::new()
                }

                $childrenByParent[$parentId].Add($process) | Out-Null
            }

            return [PSCustomObject]@{
                Processes        = $Processes
                ById             = $byId
                ChildrenByParent = $childrenByParent
            }
        }
    }

    It 'detects parentless pwsh zombies that still point at builder worktrees' {
        $snapshot = & $script:NewPreflightSnapshot -Processes @(
            [PSCustomObject]@{
                ProcessId       = 101
                ParentProcessId = 0
                Name            = 'pwsh.exe'
                CommandLine     = "pwsh -NoProfile -File C:\repo\scripts\winsmux-core.ps1 send builder-1 -C C:\repo\.worktrees\builder-1"
            }
            [PSCustomObject]@{
                ProcessId       = 201
                ParentProcessId = 77
                Name            = 'pwsh.exe'
                CommandLine     = 'pwsh -NoProfile'
            }
        )

        $victims = Get-OrchestraZombieVictims `
            -Snapshot $snapshot `
            -ProtectedIds ([System.Collections.Generic.HashSet[int]]::new()) `
            -ProjectDir 'C:\repo' `
            -GitWorktreeDir 'C:\repo\.git' `
            -BridgeScript 'C:\repo\scripts\winsmux-core.ps1' `
            -SessionName 'winsmux-orchestra'

        @($victims | ForEach-Object { [int]$_.ProcessId }) | Should -Be @(101)
    }

    It 'ignores unrelated parentless pwsh processes outside orchestra context' {
        $snapshot = & $script:NewPreflightSnapshot -Processes @(
            [PSCustomObject]@{
                ProcessId       = 301
                ParentProcessId = 0
                Name            = 'pwsh.exe'
                CommandLine     = 'pwsh -NoProfile -File C:\other\maintenance.ps1'
            }
        )

        $victims = Get-OrchestraZombieVictims `
            -Snapshot $snapshot `
            -ProtectedIds ([System.Collections.Generic.HashSet[int]]::new()) `
            -ProjectDir 'C:\repo' `
            -GitWorktreeDir 'C:\repo\.git' `
            -BridgeScript 'C:\repo\scripts\winsmux-core.ps1' `
            -SessionName 'winsmux-orchestra'

        @($victims).Count | Should -Be 0
    }

    It 'includes pwsh descendants of an existing orchestra session for cleanup' {
        $snapshot = & $script:NewPreflightSnapshot -Processes @(
            [PSCustomObject]@{
                ProcessId       = 401
                ParentProcessId = 0
                Name            = 'WindowsTerminal.exe'
                CommandLine     = 'wt.exe'
            }
            [PSCustomObject]@{
                ProcessId       = 402
                ParentProcessId = 401
                Name            = 'pwsh.exe'
                CommandLine     = 'pwsh -NoProfile'
            }
            [PSCustomObject]@{
                ProcessId       = 403
                ParentProcessId = 402
                Name            = 'codex.exe'
                CommandLine     = 'codex'
            }
        )

        $victims = Get-OrchestraZombieVictims `
            -Snapshot $snapshot `
            -ProtectedIds ([System.Collections.Generic.HashSet[int]]::new()) `
            -ProjectDir 'C:\repo' `
            -GitWorktreeDir 'C:\repo\.git' `
            -BridgeScript 'C:\repo\scripts\winsmux-core.ps1' `
            -SessionName 'winsmux-orchestra' `
            -PaneRootIds @(401)

        @($victims | ForEach-Object { [int]$_.ProcessId } | Sort-Object) | Should -Be @(402, 403)
    }
}
