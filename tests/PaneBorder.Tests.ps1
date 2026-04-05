$ErrorActionPreference = 'Stop'

Describe 'pane border helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\pane-border.ps1')
    }

    BeforeEach {
        $script:FakePsmuxCalls = [System.Collections.Generic.List[string]]::new()
        $script:FakePsmuxExitCodes = [System.Collections.Generic.Queue[int]]::new()

        function Invoke-FakePsmux {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

            $script:FakePsmuxCalls.Add(($Arguments -join '|')) | Out-Null
            if ($script:FakePsmuxExitCodes.Count -gt 0) {
                $global:LASTEXITCODE = $script:FakePsmuxExitCodes.Dequeue()
            } else {
                $global:LASTEXITCODE = 0
            }
        }
    }

    It 'sets pane border options on the first window-option command path' {
        $script:FakePsmuxExitCodes.Enqueue(0)
        $script:FakePsmuxExitCodes.Enqueue(0)

        $ok = Set-OrchestraPaneBorderOptions -WindowId '@7' -PsmuxBin 'Invoke-FakePsmux'

        $ok | Should -Be $true
        @($script:FakePsmuxCalls) | Should -Be @(
            'set-option|-t|@7|pane-border-status|top'
            'set-option|-t|@7|pane-border-format| #{pane_title} '
        )
    }

    It 'falls back to window-scoped compatibility commands when needed' {
        $script:FakePsmuxExitCodes.Enqueue(1)
        $script:FakePsmuxExitCodes.Enqueue(0)
        $script:FakePsmuxExitCodes.Enqueue(1)
        $script:FakePsmuxExitCodes.Enqueue(0)

        $ok = Set-OrchestraPaneBorderOptions -WindowId '@8' -PsmuxBin 'Invoke-FakePsmux'

        $ok | Should -Be $true
        @($script:FakePsmuxCalls) | Should -Be @(
            'set-option|-t|@8|pane-border-status|top'
            'set-option|-w|-t|@8|pane-border-status|top'
            'set-option|-t|@8|pane-border-format| #{pane_title} '
            'set-option|-w|-t|@8|pane-border-format| #{pane_title} '
        )
    }

    It 'returns false when no supported option command succeeds' {
        1..3 | ForEach-Object { $script:FakePsmuxExitCodes.Enqueue(1) }

        $ok = Set-OrchestraPaneBorderOptions -WindowId '@9' -PsmuxBin 'Invoke-FakePsmux'

        $ok | Should -Be $false
        @($script:FakePsmuxCalls).Count | Should -Be 3
        $script:FakePsmuxCalls[2] | Should -Be 'set-window-option|-t|@9|pane-border-status|top'
    }
}
