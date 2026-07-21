$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'winsmux status command' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
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
version: 2
saved_at: '2026-07-15T00:00:00Z'
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

        $manifest.version | Should -Be 2
        $manifest.saved_at | Should -Be '2026-07-15T00:00:00Z'
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
    capability_adapter: codex
  - label: reviewer
    pane_id: %4
    role: Reviewer
    capability_adapter: codex
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
        Mock Invoke-PaneStatusWinsmux {
            param([string[]]$Arguments)

            switch ($Arguments[2]) {
                '%2' { return @('Implementation finished.', '>') }
                '%4' { return @('Review in progress...') }
                default { throw "unexpected capture target: $($Arguments[2])" }
            }
        } -ParameterFilter {
            $Arguments[0] -eq 'capture-pane'
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
