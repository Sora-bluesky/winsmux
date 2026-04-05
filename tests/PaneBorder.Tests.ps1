$ErrorActionPreference = 'Stop'

Describe 'pane border helpers' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-core\scripts\pane-border.ps1')
    }

    BeforeEach {
        $script:FakeWinsmuxCalls = [System.Collections.Generic.List[string]]::new()
        $script:FakeWinsmuxExitCodes = [System.Collections.Generic.Queue[int]]::new()

        function Invoke-FakeWinsmux {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

            $script:FakeWinsmuxCalls.Add(($Arguments -join '|')) | Out-Null
            if ($script:FakeWinsmuxExitCodes.Count -gt 0) {
                $global:LASTEXITCODE = $script:FakeWinsmuxExitCodes.Dequeue()
            } else {
                $global:LASTEXITCODE = 0
            }
        }
    }

    It 'sets pane border options on the first window-option command path' {
        $script:FakeWinsmuxExitCodes.Enqueue(0)
        $script:FakeWinsmuxExitCodes.Enqueue(0)

        $ok = Set-OrchestraPaneBorderOptions -WindowId '@7' -WinsmuxBin 'Invoke-FakeWinsmux'

        $ok | Should -Be $true
        @($script:FakeWinsmuxCalls) | Should -Be @(
            'set-option|-t|@7|pane-border-status|top'
            'set-option|-t|@7|pane-border-format| #{pane_title} '
        )
    }

    It 'falls back to window-scoped compatibility commands when needed' {
        $script:FakeWinsmuxExitCodes.Enqueue(1)
        $script:FakeWinsmuxExitCodes.Enqueue(0)
        $script:FakeWinsmuxExitCodes.Enqueue(1)
        $script:FakeWinsmuxExitCodes.Enqueue(0)

        $ok = Set-OrchestraPaneBorderOptions -WindowId '@8' -WinsmuxBin 'Invoke-FakeWinsmux'

        $ok | Should -Be $true
        @($script:FakeWinsmuxCalls) | Should -Be @(
            'set-option|-t|@8|pane-border-status|top'
            'set-option|-w|-t|@8|pane-border-status|top'
            'set-option|-t|@8|pane-border-format| #{pane_title} '
            'set-option|-w|-t|@8|pane-border-format| #{pane_title} '
        )
    }

    It 'returns false when no supported option command succeeds' {
        1..3 | ForEach-Object { $script:FakeWinsmuxExitCodes.Enqueue(1) }

        $ok = Set-OrchestraPaneBorderOptions -WindowId '@9' -WinsmuxBin 'Invoke-FakeWinsmux'

        $ok | Should -Be $false
        @($script:FakeWinsmuxCalls).Count | Should -Be 3
        $script:FakeWinsmuxCalls[2] | Should -Be 'set-window-option|-t|@9|pane-border-status|top'
    }
}
