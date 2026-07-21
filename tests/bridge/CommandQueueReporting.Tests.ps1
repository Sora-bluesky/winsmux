$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'winsmux board command' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:boardTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-board-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:boardTempRoot -Force | Out-Null
        $script:boardManifestDir = Join-Path $script:boardTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:boardManifestDir -Force | Out-Null
        $script:boardManifestPath = Join-Path $script:boardManifestDir 'manifest.yaml'

        Push-Location $script:boardTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:boardTempRoot -and (Test-Path $script:boardTempRoot)) {
            Remove-Item -Path $script:boardTempRoot -Recurse -Force
        }

        $global:Target = $null
        $global:Rest = @()
        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

    It 'renders a session board with task, review, and git state columns' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:boardTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    capability_adapter: codex
    task_id: task-244
    task: Implement session board
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    builder_worktree_path: .worktrees/builder-1
    head_sha: abc1234def5678
    changed_file_count: 2
    changed_files: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    last_event: pane.ready
    last_event_at: 2026-04-10T10:00:00+09:00
  worker-1:
    pane_id: %6
    role: Worker
    capability_adapter: codex
    task_id: ''
    task: ''
    task_state: backlog
    task_owner: ''
    review_state: ''
    branch: ''
    head_sha: ''
    changed_file_count: 0
    changed_files: '[]'
    last_event: pane.idle
    last_event_at: 2026-04-10T10:05:00+09:00
"@ | Set-Content -Path $script:boardManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }
        Mock Invoke-PaneStatusWinsmux {
            param([string[]]$Arguments)

            switch ($Arguments[2]) {
                '%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                '%6' { return @('gpt-5.4   52% context left', 'thinking', 'Esc to interrupt') }
                default { throw "unexpected capture target: $($Arguments[2])" }
            }
        } -ParameterFilter {
            $Arguments[0] -eq 'capture-pane'
        }

        $output = Invoke-Board | Out-String

        $output | Should -Match 'builder-1'
        $output | Should -Match 'worker-1'
        $output | Should -Match 'in_progress'
        $output | Should -Match 'PENDING'
        $output | Should -Match 'worktree-builder-1'
        $output | Should -Match 'abc1234'
    }

    It 'returns full session board data as json' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:boardTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    capability_adapter: codex
    task_id: task-244
    task: Implement session board
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 2
    changed_files: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    last_event: pane.ready
    last_event_at: 2026-04-10T10:00:00+09:00
  worker-1:
    pane_id: %6
    role: Worker
    capability_adapter: codex
    task_id: ''
    task: ''
    task_state: backlog
    task_owner: ''
    review_state: ''
    branch: ''
    head_sha: ''
    changed_file_count: 0
    changed_files: '[]'
    last_event: pane.idle
    last_event_at: 2026-04-10T10:05:00+09:00
"@ | Set-Content -Path $script:boardManifestPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                '^capture-pane .*%6' { return @('gpt-5.4   52% context left', 'thinking', 'Esc to interrupt') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Board -BoardTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)

        $result.project_dir | Should -Be $script:boardTempRoot
        $result.summary.pane_count | Should -Be 2
        $result.summary.dirty_panes | Should -Be 1
        $result.summary.review_pending | Should -Be 1
        $result.summary.tasks_in_progress | Should -Be 1
        $result.summary.by_state.idle | Should -Be 1
        $result.summary.by_state.busy | Should -Be 1
        $result.panes.Count | Should -Be 2
        $result.panes[0].label | Should -Be 'builder-1'
        $result.panes[0].changed_files | Should -Be @('scripts/winsmux-core.ps1', 'tests/winsmux-bridge.Tests.ps1')
        $result.panes[0].last_event | Should -Be 'pane.ready'
        $result.panes[1].label | Should -Be 'worker-1'
        $result.panes[1].state | Should -Be 'busy'
    }

    It 'supports winsmux board --json through the top-level CLI entrypoint' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:boardTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-244
    task: Implement session board
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: pane.ready
    last_event_at: 2026-04-10T10:00:00+09:00
"@ | Set-Content -Path $script:boardManifestPath -Encoding UTF8

        $bridgeScript = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $childScript = @'
Set-Item -Path function:winsmux -Value {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$args)
    $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
    switch -Regex ($commandLine) {
        '^capture-pane .*%2' { @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>'); break }
        default { throw "unexpected winsmux call: $commandLine" }
    }
}
Set-Location '__BOARD_TEMP_ROOT__'
. '__BRIDGE_SCRIPT__' version *> $null
Invoke-Board -BoardTarget '--json'
'@
        $childScript = $childScript.Replace('__BOARD_TEMP_ROOT__', $script:boardTempRoot).Replace('__BRIDGE_SCRIPT__', $bridgeScript)
        $output = & pwsh -NoProfile -Command $childScript

        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.pane_count | Should -Be 1
        $result.panes[0].label | Should -Be 'builder-1'
        $result.panes[0].task_state | Should -Be 'in_progress'
        $result.panes[0].phase | Should -Be 'review'
        $result.panes[0].activity | Should -Be 'waiting_for_input'
        $result.panes[0].detail | Should -Be 'review_pending'
    }
}

Describe 'winsmux inbox command' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:inboxTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-inbox-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:inboxTempRoot -Force | Out-Null
        $script:inboxManifestDir = Join-Path $script:inboxTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:inboxManifestDir -Force | Out-Null
        $script:inboxManifestPath = Join-Path $script:inboxManifestDir 'manifest.yaml'
        $script:inboxEventsPath = Join-Path $script:inboxManifestDir 'events.jsonl'

        Push-Location $script:inboxTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:inboxTempRoot -and (Test-Path $script:inboxTempRoot)) {
            Remove-Item -Path $script:inboxTempRoot -Recurse -Force
        }

        $global:Target = $null
        $global:Rest = @()
        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

    It 'renders actionable inbox items from manifest review and blocked state' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:inboxTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-245
    task: Build inbox surface
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: review.requested
    last_event_at: 2026-04-10T11:00:00+09:00
  worker-1:
    pane_id: %6
    role: Worker
    task_id: task-999
    task: Fix blocker
    task_state: blocked
    task_owner: worker-1
    review_state: ''
    branch: worktree-worker-1
    head_sha: def5678abc1234
    changed_file_count: 0
    changed_files: '[]'
    last_event: operator.state_transition
    last_event_at: 2026-04-10T11:05:00+09:00
"@ | Set-Content -Path $script:inboxManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-10T11:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T11:06:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.state_transition'
                message   = 'State: review_requested -> blocked_no_review_target'
                label     = ''
                pane_id   = ''
                role      = 'Operator'
                status    = 'blocked_no_review_target'
                data      = [ordered]@{
                    from = 'review_requested'
                    to   = 'blocked_no_review_target'
                }
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:inboxEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                '^capture-pane .*%6' { return @('gpt-5.4   52% context left', 'thinking', 'Esc to interrupt') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $output = Invoke-Inbox | Out-String

        $output | Should -Match 'review_pending'
        $output | Should -Match 'approval_waiting'
        $output | Should -Match 'task_blocked'
        $output | Should -Match 'blocked'
        $output | Should -Match 'builder-1'
        $output | Should -Match 'worker-1'
    }

    It 'returns actionable inbox items as json' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:inboxTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-245
    task: Build inbox surface
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: review.requested
    last_event_at: 2026-04-10T11:00:00+09:00
"@ | Set-Content -Path $script:inboxManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-10T11:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T11:07:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.commit_ready'
                message   = 'コミット準備完了。'
                label     = ''
                pane_id   = ''
                role      = 'Operator'
                status    = 'commit_ready'
                head_sha  = 'abc1234def5678'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T11:08:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.completed'
                message   = '作業が完了した。'
                label     = 'builder-2'
                pane_id   = '%3'
                role      = 'Builder'
                status    = 'in_progress'
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:inboxEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Inbox -InboxTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)

        $result.project_dir | Should -Be $script:inboxTempRoot
        $result.summary.item_count | Should -Be 4
        $result.summary.by_kind.review_pending | Should -Be 1
        $result.summary.by_kind.approval_waiting | Should -Be 1
        $result.summary.by_kind.commit_ready | Should -Be 1
        $result.summary.by_kind.task_completed | Should -Be 1
        @($result.items | ForEach-Object { $_.kind }) | Should -Contain 'review_pending'
        @($result.items | ForEach-Object { $_.kind }) | Should -Contain 'approval_waiting'
        @($result.items | ForEach-Object { $_.kind }) | Should -Contain 'commit_ready'
        @($result.items | ForEach-Object { $_.kind }) | Should -Contain 'task_completed'
        ($result.items | Where-Object { $_.kind -eq 'review_pending' } | Select-Object -First 1).phase | Should -Be 'review'
        ($result.items | Where-Object { $_.kind -eq 'review_pending' } | Select-Object -First 1).activity | Should -Be 'waiting_for_input'
        ($result.items | Where-Object { $_.kind -eq 'commit_ready' } | Select-Object -First 1).phase | Should -Be 'package'
        ($result.items | Where-Object { $_.kind -eq 'commit_ready' } | Select-Object -First 1).activity | Should -Be 'completed'
        ($result.items | Where-Object { $_.kind -eq 'task_completed' } | Select-Object -First 1).phase | Should -Be 'package'
        ($result.items | Where-Object { $_.kind -eq 'task_completed' } | Select-Object -First 1).activity | Should -Be 'completed'
        ($result.items | Where-Object { $_.kind -eq 'task_completed' } | Select-Object -First 1).detail | Should -Be 'task_completed'
    }

    It 'supports winsmux inbox --json through the top-level CLI entrypoint' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:inboxTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-245
    task: Build inbox surface
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: review.requested
    last_event_at: 2026-04-10T11:00:00+09:00
"@ | Set-Content -Path $script:inboxManifestPath -Encoding UTF8

        ([ordered]@{
            timestamp = '2026-04-10T11:02:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pane.approval_waiting'
            message   = 'approval prompt detected'
            label     = 'builder-1'
            pane_id   = '%2'
            role      = 'Builder'
            status    = 'approval_waiting'
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:inboxEventsPath -Encoding UTF8

        $bridgeScript = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $childScript = @'
Set-Item -Path function:winsmux -Value {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$args)
    $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
    switch -Regex ($commandLine) {
        '^capture-pane .*%2' { @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>'); break }
        default { throw "unexpected winsmux call: $commandLine" }
    }
}
Set-Location '__INBOX_TEMP_ROOT__'
. '__BRIDGE_SCRIPT__' version *> $null
Invoke-Inbox -InboxTarget '--json'
'@
        $childScript = $childScript.Replace('__INBOX_TEMP_ROOT__', $script:inboxTempRoot).Replace('__BRIDGE_SCRIPT__', $bridgeScript)
        $output = & pwsh -NoProfile -Command $childScript

        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.item_count | Should -Be 2
        @($result.items | ForEach-Object { $_.kind }) | Should -Contain 'review_pending'
        @($result.items | ForEach-Object { $_.kind }) | Should -Contain 'approval_waiting'
    }

    It 'classifies the actionable inbox event taxonomy' {
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.approval_waiting'; status = 'approval_waiting' })) | Should -Be 'approval_waiting'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.idle'; status = 'ready' })) | Should -Be 'dispatch_needed'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.completed'; status = 'waiting_for_dispatch' })) | Should -Be 'task_completed'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.bootstrap_invalid'; status = 'bootstrap_invalid' })) | Should -Be 'bootstrap_invalid'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.crashed'; status = 'crashed' })) | Should -Be 'crashed'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.hung'; status = 'hung' })) | Should -Be 'hung'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'pane.stalled'; status = 'stalled' })) | Should -Be 'stalled'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'operator.state_transition'; status = 'blocked_no_review_target'; data = [ordered]@{ to = 'blocked_no_review_target' } })) | Should -Be 'blocked'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'operator.commit_ready'; status = 'commit_ready' })) | Should -Be 'commit_ready'
    }

    It 'starts inbox stream after the current event cursor instead of replaying full history' {
        @(
            ([ordered]@{
                timestamp = '2026-04-10T11:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T11:03:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.ready'
                message   = 'ready'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'ready'
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:inboxEventsPath -Encoding UTF8

        $cursor = Get-InboxStreamStartCursor -ProjectDir $script:inboxTempRoot

        $cursor | Should -Be 2
        $delta = Get-BridgeEventDelta -ProjectDir $script:inboxTempRoot -Cursor $cursor
        $delta.cursor | Should -Be 2
        @($delta.events).Count | Should -Be 0
    }
}

Describe 'winsmux runs command' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:runsTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-runs-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:runsTempRoot -Force | Out-Null
        $script:runsManifestDir = Join-Path $script:runsTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:runsManifestDir -Force | Out-Null
        $script:runsManifestPath = Join-Path $script:runsManifestDir 'manifest.yaml'
        $script:runsEventsPath = Join-Path $script:runsManifestDir 'events.jsonl'

        Push-Location $script:runsTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:runsTempRoot -and (Test-Path $script:runsTempRoot)) {
            Remove-Item -Path $script:runsTempRoot -Recurse -Force
        }

        $global:Target = $null
        $global:Rest = @()
        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

    It 'renders run-oriented grouped output from manifest and actionable items' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:runsTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 2
    changed_files: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
  worker-1:
    pane_id: %6
    role: Worker
    task_id: ''
    task: ''
    task_state: backlog
    task_owner: ''
    review_state: ''
    branch: ''
    head_sha: ''
    changed_file_count: 0
    changed_files: '[]'
    last_event: pane.idle
    last_event_at: 2026-04-10T12:05:00+09:00
"@ | Set-Content -Path $script:runsManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-10T12:01:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T12:06:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.idle'
                message   = 'idle pane'
                label     = 'worker-1'
                pane_id   = '%6'
                role      = 'Worker'
                status    = 'ready'
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:runsEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                '^capture-pane .*%6' { return @('gpt-5.4   52% context left', 'thinking', 'Esc to interrupt') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $output = Invoke-Runs | Out-String

        $output | Should -Match 'task:task-256'
        $output | Should -Match 'builder-1'
        $output | Should -Match 'Implement run ledger'
        $output | Should -Match 'PENDING'
        $output | Should -Match '\s2\s*$'
    }

    It 'returns runs as json' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:runsTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    parent_run_id: operator:session-1
    goal: Ship run contract primitives
    task: Implement run ledger
    task_type: implementation
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    priority: P0
    blocking: true
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    write_scope: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    read_scope: '["winsmux-core/scripts/pane-status.ps1"]'
    constraints: '["preserve existing board schema"]'
    expected_output: Stable run_packet JSON
    verification_plan: '["Invoke-Pester tests/winsmux-bridge.Tests.ps1","verify runs --json contract"]'
    review_required: true
    provider_target: codex:gpt-5.4
    agent_role: worker
    timeout_policy: standard
    handoff_refs: '["docs/handoff.md"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:runsManifestPath -Encoding UTF8

        $runsObservationPack = New-ObservationPackFile -ProjectDir $script:runsTempRoot -ObservationPack ([ordered]@{
            run_id              = 'task:task-256'
            task_id             = 'task-256'
            pane_id             = '%2'
            slot                = 'slot-builder-1'
            hypothesis          = 'branch-scoped event data is enough for experiment ledger'
            test_plan           = @('capture matching events', 'render experiment packet')
            env_fingerprint     = 'env:abc123'
            command_hash        = 'cmd:def456'
            changed_files       = @('scripts/winsmux-core.ps1')
        })
        $runsConsultationPacket = New-ConsultationPacketFile -ProjectDir $script:runsTempRoot -ConsultationPacket ([ordered]@{
            run_id         = 'task:task-256'
            task_id        = 'task-256'
            pane_id        = '%2'
            slot           = 'slot-builder-1'
            kind           = 'consult_result'
            mode           = 'early'
            target_slot    = 'slot-review-1'
            confidence     = 0.72
            recommendation = 'keep experiment packet read-only'
            next_test      = 'review_pending'
            risks          = @('result still provisional')
        })

        @(
        ([ordered]@{
            timestamp = '2026-04-10T12:01:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pane.approval_waiting'
            message   = 'approval prompt detected'
            label     = 'builder-1'
            pane_id   = '%2'
            role      = 'Builder'
            status    = 'approval_waiting'
            data      = [ordered]@{
                task_id              = 'task-256'
                hypothesis           = 'branch-scoped event data is enough for experiment ledger'
                test_plan            = @('capture matching events', 'render experiment packet')
                result               = 'hypothesis still pending'
                confidence           = 0.72
                next_action          = 'review_pending'
                observation_pack_ref = $runsObservationPack.reference
                consultation_ref     = $runsConsultationPacket.reference
                run_id               = 'task:task-256'
                slot                 = 'slot-builder-1'
                worktree             = '.worktrees/builder-1'
                env_fingerprint      = 'env:abc123'
                command_hash         = 'cmd:def456'
            }
        } | ConvertTo-Json -Compress -Depth 8),
        ([ordered]@{
            timestamp = '2026-04-10T12:01:15+09:00'
            session   = 'winsmux-orchestra'
            event     = 'operator.mailbox.message_received'
            message   = 'team memory reference captured'
            label     = 'operator'
            pane_id   = ''
            role      = 'Operator'
            source    = 'mailbox'
            data      = [ordered]@{
                task_id            = 'task-256'
                run_id             = 'task:task-256'
                source             = 'mailbox'
                team_memory_refs   = @('team-memory:task-256:operator-standard', 'C:\Users\Example\private.md', 'private note body')
                evidence_note_refs = @('evidence-note:task-256:operator-standard', '%LOCALAPPDATA%\winsmux\private.md')
                message_body       = 'operator direction body must not be exposed'
            }
        } | ConvertTo-Json -Compress -Depth 8),
        ([ordered]@{
            timestamp = '2026-04-10T12:01:20+09:00'
            session   = 'winsmux-orchestra'
            event     = 'operator.mailbox.message_received'
            message   = 'mailbox event without explicit ref'
            label     = 'operator'
            pane_id   = ''
            role      = 'Operator'
            source    = 'mailbox'
            data      = [ordered]@{
                task_id          = 'task-256'
                run_id           = 'task:task-256'
                source           = 'mailbox'
                team_memory_refs = @('C:\Users\Example\private-2.md')
                message_body     = 'fallback should expose only durable ref'
            }
        } | ConvertTo-Json -Compress -Depth 8),
        ([ordered]@{
            timestamp = '2026-04-10T12:01:30+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.decompose.completed'
            message   = 'operator decomposed task'
            label     = 'researcher-1'
            pane_id   = ''
            role      = 'Operator'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id              = 'task-256'
                run_id               = 'task:task-256'
                stage                = 'decompose'
                state                = 'completed'
                upper_operator       = 'claude_code'
                aggregation_point    = 'claude_code_operator'
                worker_topology      = 'operator_managed_panes'
                peer_to_peer_allowed = $false
                target               = 'researcher-1'
                summary              = 'split implementation and verification'
            }
        } | ConvertTo-Json -Compress),
        ([ordered]@{
            timestamp = '2026-04-10T12:01:40+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.dispatch.assigned'
            message   = 'operator assigned builder'
            label     = 'builder-1'
            pane_id   = ''
            role      = 'Operator'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id              = 'task-256'
                run_id               = 'task:task-256'
                stage                = 'dispatch'
                state                = 'assigned'
                upper_operator       = 'claude_code'
                aggregation_point    = 'claude_code_operator'
                worker_topology      = 'operator_managed_panes'
                peer_to_peer_allowed = $false
                target               = 'builder-1'
                summary              = 'builder owns implementation'
            }
        } | ConvertTo-Json -Compress),
        ([ordered]@{
            timestamp = '2026-04-10T12:01:45+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.tdd.red'
            message   = 'test failed before implementation'
            label     = 'operator'
            pane_id   = ''
            role      = 'Operator'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id   = 'task-256'
                run_id    = 'task:task-256'
                tdd_phase = 'red'
            }
        } | ConvertTo-Json -Compress),
        ([ordered]@{
            timestamp = '2026-04-10T12:01:50+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.collect.completed'
            message   = 'operator collected builder result'
            label     = 'builder-1'
            pane_id   = ''
            role      = 'Operator'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id              = 'task-256'
                run_id               = 'task:task-256'
                stage                = 'collect'
                state                = 'builder_result_collected'
                upper_operator       = 'claude_code'
                aggregation_point    = 'claude_code_operator'
                worker_topology      = 'operator_managed_panes'
                peer_to_peer_allowed = $false
                target               = 'builder-1'
                summary              = 'builder result is ready for review'
            }
        } | ConvertTo-Json -Compress),
        ([ordered]@{
            timestamp = '2026-04-10T12:02:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.verify.partial'
            message   = 'verification partially complete after drift retry'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id = 'task-256'
                run_id  = 'task:task-256'
                verification_contract = [ordered]@{
                    mode = 'adversarial_verify'
                    context_budget = 120000
                    context_estimate = 42000
                    context_pack_id = 'ctx-runs'
                    context_pack_version = '1'
                    tool_output_pruned_count = 3
                    context_pressure = 'high'
                    context_mode = 'isolated'
                    semantic_context_pack_id = 'sem-runs'
                    semantic_context_pack_ref = 'context-packs/sem-runs.json'
                        source_refs = @('ADR-001', 'docs/operator-model.md#context', 'C:\Users\Example\private.md', 'private note body')
                    hard_constraints = @('do not store prompt bodies')
                    safety_rules = @('keep local paths out')
                    performance_budget = [ordered]@{ max_context_tokens = 42000 }
                    rationale = 'keep worker context scoped'
                    knowledge_pack_id = 'know-runs'
                    knowledge_pack_ref = 'knowledge/know-runs.json'
                        knowledge_source_refs = @('GUARDRAILS.md#17-git-guard-gate', 'docs/operator-model.md#knowledge', '%LOCALAPPDATA%\winsmux\private.md', 'private guidance body')
                    operating_guidance_refs = @('guidance:git-guard', 'guidance:review-before-merge')
                    knowledge_hard_constraints = @('never bypass git-guard')
                    capability_contract = [ordered]@{ can_edit = $true; can_merge = $false }
                        evidence_refs = @('evidence:run-ledger', 'C:\Users\Example\evidence.md', 'pasted evidence body')
                        rationale_refs = @('ADR-knowledge-layer', '%LOCALAPPDATA%\winsmux\rationale.md', 'pasted rationale body')
                }
                attempt = 2
                verification_result = [ordered]@{
                    outcome = 'PARTIAL'
                    summary = 'rerun focused verification'
                    next_action = 'rerun_verify'
                }
            }
        } | ConvertTo-Json -Compress -Depth 8),
        ([ordered]@{
            timestamp = '2026-04-10T12:03:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.escalate.required'
            message   = 'operator escalation required'
            label     = 'reviewer-1'
            pane_id   = ''
            role      = 'Operator'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id              = 'task-256'
                run_id               = 'task:task-256'
                stage                = 'escalate'
                state                = 'required'
                reason               = 'VERIFY_PARTIAL'
                upper_operator       = 'claude_code'
                aggregation_point    = 'claude_code_operator'
                worker_topology      = 'operator_managed_panes'
                peer_to_peer_allowed = $false
                target               = 'reviewer-1'
                summary              = 'verification needs an operator decision'
            }
        } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:runsEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Runs -RunsTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.run_count | Should -Be 1
        $result.summary.review_pending | Should -Be 1
        $result.summary.dirty_runs | Should -Be 1
        $result.runs[0].run_id | Should -Be 'task:task-256'
        @($result.runs[0].action_items | ForEach-Object { $_.kind }) | Should -Contain 'approval_waiting'
        @($result.runs[0].action_items | ForEach-Object { $_.kind }) | Should -Contain 'review_pending'
        $result.runs[0].changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $result.runs[0].run_packet.parent_run_id | Should -Be 'operator:session-1'
        $result.runs[0].run_packet.goal | Should -Be 'Ship run contract primitives'
        $result.runs[0].run_packet.task_type | Should -Be 'implementation'
        $result.runs[0].run_packet.priority | Should -Be 'P0'
        $result.runs[0].run_packet.blocking | Should -Be $true
        $result.runs[0].run_packet.write_scope | Should -Be @('scripts/winsmux-core.ps1', 'tests/winsmux-bridge.Tests.ps1')
        $result.runs[0].run_packet.read_scope | Should -Be @('winsmux-core/scripts/pane-status.ps1')
        $result.runs[0].run_packet.constraints | Should -Be @('preserve existing board schema')
        $result.runs[0].run_packet.expected_output | Should -Be 'Stable run_packet JSON'
        $result.runs[0].run_packet.verification_plan | Should -Be @('Invoke-Pester tests/winsmux-bridge.Tests.ps1', 'verify runs --json contract')
        $result.runs[0].run_packet.review_required | Should -Be $true
        $result.runs[0].run_packet.provider_target | Should -Be 'codex:gpt-5.4'
        $result.runs[0].run_packet.agent_role | Should -Be 'worker'
        $result.runs[0].run_packet.timeout_policy | Should -Be 'standard'
        $result.runs[0].run_packet.handoff_refs | Should -Be @('docs/handoff.md')
        $result.runs[0].experiment_packet.hypothesis | Should -Be 'branch-scoped event data is enough for experiment ledger'
        $result.runs[0].experiment_packet.test_plan | Should -Be @('capture matching events', 'render experiment packet')
        $result.runs[0].experiment_packet.result | Should -Be 'hypothesis still pending'
        $result.runs[0].experiment_packet.confidence | Should -Be 0.72
        $result.runs[0].experiment_packet.next_action | Should -Be 'review_pending'
        $result.runs[0].experiment_packet.observation_pack_ref | Should -Be $runsObservationPack.reference
        $result.runs[0].experiment_packet.consultation_ref | Should -Be $runsConsultationPacket.reference
        $result.runs[0].experiment_packet.run_id | Should -Be 'task:task-256'
        $result.runs[0].experiment_packet.slot | Should -Be 'slot-builder-1'
        $result.runs[0].experiment_packet.worktree | Should -Be '.worktrees/builder-1'
        $result.runs[0].experiment_packet.env_fingerprint | Should -Be 'env:abc123'
        $result.runs[0].experiment_packet.command_hash | Should -Be 'cmd:def456'
        $result.runs[0].verification_contract.mode | Should -Be 'adversarial_verify'
        $result.runs[0].verification_result.outcome | Should -Be 'PARTIAL'
        $result.runs[0].run_packet.verification_result.outcome | Should -Be 'PARTIAL'
        $result.runs[0].context_contract.context_pack_id | Should -Be 'ctx-runs'
        $result.runs[0].context_contract.context_capsule.capsule_version | Should -Be 1
        $result.runs[0].context_contract.context_capsule.run_id | Should -Be 'task:task-256'
        $result.runs[0].context_contract.context_capsule.task_id | Should -Be 'task-256'
        $result.runs[0].context_contract.context_capsule.source_slot | Should -Be 'builder-1'
        $result.runs[0].context_contract.context_capsule.next_action | Should -Be 'review_pending'
        $result.runs[0].context_contract.context_capsule.claim_level | Should -Be 'MOCK_INTEGRATION_VERIFIED'
        $result.runs[0].context_contract.context_capsule.source_head_sha | Should -Be 'abc1234def5678'
        $result.runs[0].context_contract.context_capsule.validation.valid | Should -Be $true
        $result.runs[0].context_contract.context_capsule.privacy.raw_transcript_stored | Should -Be $false
        $result.runs[0].context_contract.context_capsule.context_pressure.state | Should -Be 'checkpoint-recommended'
        $result.runs[0].context_contract.context_capsule.context_pressure.recommended_action | Should -Be 'write_checkpoint'
        $result.runs[0].context_contract.context_capsule.context_pressure.usage.percent | Should -Be 35
        $result.runs[0].context_contract.context_capsule.context_pressure.usage.source | Should -Be 'estimated'
        $result.runs[0].context_contract.context_capsule.context_pressure.pending_mailbox_count | Should -Be 2
        $result.runs[0].context_contract.context_capsule.summary_quality_gate.valid | Should -Be $true
        $result.runs[0].context_contract.context_capsule.summary_quality_gate.action | Should -Be 'allow_routing'
        $result.runs[0].context_contract.context_pressure_status.state | Should -Be 'checkpoint-recommended'
        $result.runs[0].context_contract.summary_quality_gate.valid | Should -Be $true
        $result.runs[0].context_contract.router_policy.usable_for_routing | Should -Be $true
        $result.runs[0].context_contract.context_pressure | Should -Be 'high'
        $result.runs[0].context_contract.context_mode | Should -Be 'isolated'
        $result.runs[0].context_contract.tool_output_pruned_count | Should -Be 3
        $result.runs[0].context_contract.semantic_context.context_pack_id | Should -Be 'sem-runs'
        $result.runs[0].context_contract.semantic_context.source_refs | Should -Be @('ADR-001', 'docs/operator-model.md#context')
        ($result.runs[0].context_contract.semantic_context.source_refs -join '|') | Should -Not -Match 'Users'
        ($result.runs[0].context_contract.semantic_context.source_refs -join '|') | Should -Not -Match 'private note'
        $result.runs[0].context_contract.semantic_context.hard_constraints | Should -Be @('do not store prompt bodies')
        $result.runs[0].context_contract.semantic_context.adr_body_stored | Should -Be $false
        $result.runs[0].context_contract.semantic_context.persona_prompt_stored | Should -Be $false
        $result.runs[0].context_contract.semantic_context.private_source_body_stored | Should -Be $false
        $result.runs[0].context_contract.knowledge_layer.packet_type | Should -Be 'knowledge_layer_contract'
        $result.runs[0].context_contract.knowledge_layer.knowledge_pack_id | Should -Be 'know-runs'
        $result.runs[0].context_contract.knowledge_layer.knowledge_pack_ref | Should -Be 'knowledge/know-runs.json'
        $result.runs[0].context_contract.knowledge_layer.source_refs | Should -Be @('GUARDRAILS.md#17-git-guard-gate', 'docs/operator-model.md#knowledge')
        ($result.runs[0].context_contract.knowledge_layer.source_refs -join '|') | Should -Not -Match 'LOCALAPPDATA'
        ($result.runs[0].context_contract.knowledge_layer.source_refs -join '|') | Should -Not -Match 'private guidance'
        $result.runs[0].context_contract.knowledge_layer.operating_guidance_refs | Should -Be @('guidance:git-guard', 'guidance:review-before-merge')
        $result.runs[0].context_contract.knowledge_layer.hard_constraints | Should -Be @('never bypass git-guard')
        $result.runs[0].context_contract.knowledge_layer.capability_contract.can_edit | Should -Be $true
        $result.runs[0].context_contract.knowledge_layer.capability_contract.can_merge | Should -Be $false
        $result.runs[0].context_contract.knowledge_layer.evidence_refs | Should -Be @('evidence:run-ledger')
        ($result.runs[0].context_contract.knowledge_layer.evidence_refs -join '|') | Should -Not -Match 'Users'
        ($result.runs[0].context_contract.knowledge_layer.evidence_refs -join '|') | Should -Not -Match 'pasted evidence'
        $result.runs[0].context_contract.knowledge_layer.rationale_refs | Should -Be @('ADR-knowledge-layer')
        ($result.runs[0].context_contract.knowledge_layer.rationale_refs -join '|') | Should -Not -Match 'LOCALAPPDATA'
        ($result.runs[0].context_contract.knowledge_layer.rationale_refs -join '|') | Should -Not -Match 'pasted rationale'
        $result.runs[0].context_contract.knowledge_layer.team_memory_refs | Should -Contain 'team-memory:task-256:operator-standard'
        $result.runs[0].context_contract.knowledge_layer.team_memory_refs | Should -Contain 'team-memory:task:task-256:event-3'
        $result.runs[0].context_contract.knowledge_layer.freeform_body_stored | Should -Be $false
        $result.runs[0].context_contract.knowledge_layer.private_guidance_stored | Should -Be $false
        $result.runs[0].context_contract.knowledge_layer.local_reference_paths_stored | Should -Be $false
        $result.runs[0].context_contract.knowledge_layer.PSObject.Properties.Name | Should -Not -Contain 'freeform_body'
        $result.runs[0].context_contract.knowledge_layer.PSObject.Properties.Name | Should -Not -Contain 'private_guidance'
        $result.runs[0].context_contract.prompt_body_stored | Should -Be $false
        $result.runs[0].context_contract.private_memory_stored | Should -Be $false
        $result.runs[0].team_memory.packet_type | Should -Be 'team_memory_contract'
        $result.runs[0].team_memory.team_memory_refs | Should -Contain 'team-memory:task-256:operator-standard'
        $result.runs[0].team_memory.team_memory_refs | Should -Contain 'team-memory:task:task-256:event-3'
        $result.runs[0].team_memory.evidence_note_refs | Should -Be @('evidence-note:task-256:operator-standard')
        $result.runs[0].team_memory.mailbox_event_count | Should -Be 2
        $result.runs[0].team_memory.freeform_body_stored | Should -Be $false
        $result.runs[0].team_memory.private_memory_body_stored | Should -Be $false
        $result.runs[0].team_memory.local_reference_paths_stored | Should -Be $false
        $result.runs[0].team_memory.PSObject.Properties.Name | Should -Not -Contain 'message_body'
        $result.runs[0].team_memory.PSObject.Properties.Name | Should -Not -Contain 'private_memory_body'
        ($result.runs[0].team_memory.team_memory_refs -join '|') | Should -Not -Match 'Users'
        ($result.runs[0].team_memory.team_memory_refs -join '|') | Should -Not -Match 'private note'
        $result.runs[0].run_insights.retry_count | Should -Be 1
        $result.runs[0].run_insights.drift_signals | Should -Be @('drift_detected')
        $result.runs[0].run_insights.unhealthy_session_size | Should -Be $true
        $result.runs[0].run_insights.next_improvements | Should -Contain 'split the next run into a smaller scope'
        $result.runs[0].run_insights.split_worthiness.split | Should -Be $true
        $result.runs[0].run_insights.split_worthiness.reason_codes | Should -Contain 'context_pressure_high'
        $result.runs[0].run_insights.split_worthiness.enforcement | Should -Be 'suggestion_only'
        $result.runs[0].architecture_contract.packet_type | Should -Be 'architecture_contract'
        $result.runs[0].architecture_contract.baseline.max_drift_score | Should -Be 0
        $result.runs[0].architecture_contract.current.drift_score | Should -Be 1
        $result.runs[0].architecture_contract.current.drift_signals | Should -Be @('drift_detected')
        $result.runs[0].architecture_contract.score_regression | Should -Be $true
        $result.runs[0].architecture_contract.status | Should -Be 'baseline_mismatch'
        $result.runs[0].architecture_contract.storage_policy.local_reference_paths_stored | Should -Be $false
        $result.runs[0].verification_envelope.static_gates.required_fields | Should -Contain 'architecture_contract'
        $result.runs[0].verification_envelope.dynamic_gates.architecture.status | Should -Be 'baseline_mismatch'
        $result.runs[0].verification_envelope.release_decision.blocked_reasons | Should -Contain 'architecture baseline mismatch requires review'
        $result.runs[0].child_launch_contract.packet_type | Should -Be 'child_launch_contract'
        $result.runs[0].child_launch_contract.scope | Should -Be 'operator_managed_child_run'
        $result.runs[0].child_launch_contract.role | Should -Be 'Builder'
        $result.runs[0].child_launch_contract.role_intent | Should -Be 'worker'
        $result.runs[0].child_launch_contract.agent_kind | Should -Be 'codex'
        $result.runs[0].child_launch_contract.worktree | Should -Be '.worktrees/builder-1'
        $result.runs[0].child_launch_contract.launch_dir | Should -Be '.worktrees/builder-1'
        $result.runs[0].child_launch_contract.session_type | Should -Be 'managed_worktree'
        $result.runs[0].child_launch_contract.structured_handoff.packet_type | Should -Be 'structured_handoff_contract'
        $result.runs[0].child_launch_contract.structured_handoff.mode | Should -Be 'plan_document_pipe'
        $result.runs[0].child_launch_contract.structured_handoff.plan_ref | Should -Be 'plan.md'
        $result.runs[0].child_launch_contract.structured_handoff.plan_body_stored | Should -Be $false
        $result.runs[0].child_launch_contract.structured_handoff.target_role | Should -Be 'Builder'
        $result.runs[0].child_launch_contract.structured_handoff.target_role_intent | Should -Be 'worker'
        $result.runs[0].child_launch_contract.structured_handoff.target_agent_kind | Should -Be 'codex'
        $result.runs[0].child_launch_contract.structured_handoff.independent_verification | Should -Be $true
        $result.runs[0].child_launch_contract.structured_handoff.freeform_prompt_body_stored | Should -Be $false
        $result.runs[0].child_launch_contract.startup_command_ref | Should -Be 'managed-pane-launch'
        $result.runs[0].child_launch_contract.startup_command_stored | Should -Be $false
        $result.runs[0].child_launch_contract.project_root_stored | Should -Be $false
        $result.runs[0].child_launch_contract.operator_controls_merge | Should -Be $true
        $result.runs[0].child_launch_contract.peer_to_peer_allowed | Should -Be $false
        ($result.runs[0].child_launch_contract | ConvertTo-Json -Depth 8) | Should -Not -Match 'Users'
        ($result.runs[0].child_launch_contract | ConvertTo-Json -Depth 8) | Should -Not -Match 'private next action'
        $result.runs[0].checkpoint_package.packet_type | Should -Be 'checkpoint_package'
        $result.runs[0].checkpoint_package.checkpoint_version | Should -Be 1
        $result.runs[0].checkpoint_package.resume_handle | Should -Be 'checkpoint:task-task-256:abc1234def5678'
        $result.runs[0].checkpoint_package.next_exact_step | Should -Be 'review_pending'
        $result.runs[0].checkpoint_package.claim_level | Should -Be 'MOCK_INTEGRATION_VERIFIED'
        $result.runs[0].checkpoint_package.resume_policy.resume_allowed | Should -Be $true
        $result.runs[0].checkpoint_package.resume_policy.completed_task_resume_rejected | Should -Be $false
        $result.runs[0].checkpoint_package.checkpoint_freshness.state | Should -Be 'fresh'
        $result.runs[0].checkpoint_package.context_pressure_status.state | Should -Be 'checkpoint-recommended'
        $result.runs[0].checkpoint_package.summary_quality_gate.valid | Should -Be $true
        $result.runs[0].checkpoint_package.assigned_worktree | Should -Be '.worktrees/builder-1'
        $result.runs[0].checkpoint_package.session_type | Should -Be 'managed_worktree'
        $result.runs[0].checkpoint_package.changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $result.runs[0].checkpoint_package.verification.outcome | Should -Be 'PARTIAL'
        $result.runs[0].checkpoint_package.end_of_run_snapshot.packet_type | Should -Be 'end_of_run_snapshot_manifest'
        $result.runs[0].checkpoint_package.end_of_run_snapshot.status | Should -Be 'partial'
        $result.runs[0].checkpoint_package.end_of_run_snapshot.capture_policy.snapshot_failure_does_not_fail_worker | Should -Be $true
        $result.runs[0].checkpoint_package.end_of_run_snapshot.repo_diff.changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $result.runs[0].checkpoint_package.end_of_run_snapshot.repo_diff.untracked_files.file_names_stored | Should -Be $false
        $result.runs[0].checkpoint_package.end_of_run_snapshot.terminal.raw_transcript_stored | Should -Be $false
        $result.runs[0].checkpoint_package.end_of_run_snapshot.context.context_pack_id | Should -Be 'ctx-runs'
        $result.runs[0].checkpoint_package.end_of_run_snapshot.context.semantic_context_pack_id | Should -Be 'sem-runs'
        $result.runs[0].checkpoint_package.end_of_run_snapshot.hydration.assigned_worktree | Should -Be '.worktrees/builder-1'
        ($result.runs[0].checkpoint_package | ConvertTo-Json -Depth 8) | Should -Not -Match 'Users'
        ($result.runs[0].checkpoint_package | ConvertTo-Json -Depth 8) | Should -Not -Match 'private next action'
        $result.runs[0].checkpoint_package.project_root_stored | Should -Be $false
        $result.runs[0].checkpoint_package.local_reference_paths_stored | Should -Be $false
        $result.runs[0].checkpoint_package.worker_git_write_allowed | Should -Be $false
        $result.summary.restore_candidate_count | Should -Be 1
        $result.restore_candidates.Count | Should -Be 1
        $result.restore_candidates[0].candidate_version | Should -Be 1
        $result.restore_candidates[0].run_id | Should -Be 'task:task-256'
        $result.restore_candidates[0].task_id | Should -Be 'task-256'
        $result.restore_candidates[0].source_slot | Should -Be 'builder-1'
        $result.restore_candidates[0].agent_cli_session_id | Should -Be '%2'
        $result.restore_candidates[0].agent_cli_session_id_source | Should -Be 'pane_id'
        $result.restore_candidates[0].resume_handle | Should -Be 'checkpoint:task-task-256:abc1234def5678'
        $result.restore_candidates[0].next_exact_step | Should -Be 'review_pending'
        $result.restore_candidates[0].assigned_worktree | Should -Be '.worktrees/builder-1'
        $result.restore_candidates[0].assignment.provider_target | Should -Be 'codex:gpt-5.4'
        $result.restore_candidates[0].assignment.agent_kind | Should -Be 'codex'
        $result.restore_candidates[0].assignment.agent_model | Should -Be 'gpt-5.4'
        $result.restore_candidates[0].assignment.agent_role | Should -Be 'worker'
        $result.restore_candidates[0].context_capsule_id | Should -Be 'capsule:task-task-256:abc1234def5678'
        $result.restore_candidates[0].context_capsule_valid | Should -Be $true
        $result.restore_candidates[0].summary_quality_valid | Should -Be $true
        $result.restore_candidates[0].resume_policy.resume_allowed | Should -Be $true
        $result.restore_candidates[0].transcript_ring_summary.state | Should -Be 'not_captured'
        $result.restore_candidates[0].transcript_ring_summary.raw_transcript_stored | Should -Be $false
        $result.restore_candidates[0].privacy.raw_transcript_stored | Should -Be $false
        $result.restore_candidates[0].privacy.local_reference_paths_stored | Should -Be $false
        ($result.restore_candidates[0] | ConvertTo-Json -Depth 8) | Should -Not -Match 'Users'
        ($result.restore_candidates[0] | ConvertTo-Json -Depth 8) | Should -Not -Match 'private next action'
        $result.runs[0].run_packet.context_contract.context_pack_id | Should -Be 'ctx-runs'
        $result.runs[0].run_packet.team_memory.team_memory_refs | Should -Contain 'team-memory:task-256:operator-standard'
        $result.runs[0].run_packet.team_memory.team_memory_refs | Should -Contain 'team-memory:task:task-256:event-3'
        $result.runs[0].run_packet.run_insights.retry_count | Should -Be 1
        $result.runs[0].run_packet.architecture_contract.status | Should -Be 'baseline_mismatch'
        $result.runs[0].run_packet.child_launch_contract.packet_type | Should -Be 'child_launch_contract'
        $result.runs[0].run_packet.child_launch_contract.structured_handoff.plan_ref | Should -Be 'plan.md'
        $result.runs[0].run_packet.child_launch_contract.operator_controls_merge | Should -Be $true
        $result.runs[0].run_packet.checkpoint_package.assigned_worktree | Should -Be '.worktrees/builder-1'
        $result.runs[0].run_packet.checkpoint_package.operator_git_required | Should -Be $true
        $result.runs[0].tdd_gate.required | Should -Be $true
        $result.runs[0].tdd_gate.state | Should -Be 'passed'
        $result.runs[0].tdd_gate.red_event | Should -Be 'pipeline.tdd.red'
        $result.runs[0].run_packet.tdd_gate.state | Should -Be 'passed'
        $result.runs[0].phase | Should -Be 'review'
        $result.runs[0].activity | Should -Be 'waiting_for_input'
        $result.runs[0].detail | Should -Be 'review_pending'
        $result.runs[0].run_packet.phase | Should -Be 'review'
        $result.runs[0].run_packet.activity | Should -Be 'waiting_for_input'
        $result.runs[0].run_packet.detail | Should -Be 'review_pending'
        $result.runs[0].plan.goal | Should -Be 'Ship run contract primitives'
        $result.runs[0].plan.verification_plan | Should -Be @('Invoke-Pester tests/winsmux-bridge.Tests.ps1', 'verify runs --json contract')
        $result.runs[0].plan_checkpoints.Count | Should -Be 6
        @($result.runs[0].plan_checkpoints | ForEach-Object { $_.name }) | Should -Be @('pane.approval_waiting', 'pipeline.decompose.completed', 'pipeline.dispatch.assigned', 'pipeline.collect.completed', 'pipeline.verify.partial', 'pipeline.escalate.required')
        $result.runs[0].plan_checkpoints[0].at.ToString('o') | Should -Be '2026-04-10T03:01:00.0000000Z'
        $result.runs[0].managed_loop.upper_operator | Should -Be 'claude_code'
        $result.runs[0].managed_loop.aggregation_point | Should -Be 'claude_code_operator'
        $result.runs[0].managed_loop.peer_to_peer_allowed | Should -Be $false
        $result.runs[0].managed_loop.decompose_state | Should -Be 'completed'
        $result.runs[0].managed_loop.assignment_state | Should -Be 'assigned'
        $result.runs[0].managed_loop.collection_state | Should -Be 'builder_result_collected'
        $result.runs[0].managed_loop.escalation_state | Should -Be 'required'
        $result.runs[0].managed_loop.escalation_reason | Should -Be 'VERIFY_PARTIAL'
        $result.runs[0].managed_loop.stages.Count | Should -Be 4
        $result.runs[0].phase_gate.order | Should -Be @('plan', 'build', 'test', 'review', 'package')
        $result.runs[0].phase_gate.current_stage | Should -Be 'review'
        $result.runs[0].phase_gate.stop_required | Should -Be $true
        $result.runs[0].phase_gate.stop_reason | Should -Be 'needs_user_decision'
        $result.runs[0].phase_gate.auto_continue_allowed | Should -Be $false
        $result.runs[0].phase_gate.requires_human_decision | Should -Be $true
        ($result.runs[0].phase_gate.stages | Where-Object { $_.stage -eq 'test' } | Select-Object -First 1).status | Should -Be 'waiting_for_input'
        ($result.runs[0].phase_gate.stages | Where-Object { $_.stage -eq 'review' } | Select-Object -First 1).reason | Should -Be 'review_pending'
        $result.runs[0].outcome.status | Should -Be 'needs_user_decision'
        $result.runs[0].outcome.reason | Should -Be 'rerun focused verification'
        $result.runs[0].outcome.confidence | Should -Be 0.72
        $result.runs[0].draft_pr_gate.kind | Should -Be 'human_judgement'
        $result.runs[0].draft_pr_gate.target | Should -Be 'draft_pr'
        $result.runs[0].draft_pr_gate.state | Should -Be 'blocked'
        $result.runs[0].draft_pr_gate.auto_merge_allowed | Should -Be $false
        $result.runs[0].draft_pr_gate.handoff_package.summary | Should -Be 'rerun focused verification'
        $result.runs[0].draft_pr_gate.handoff_package.validation.outcome | Should -Be 'PARTIAL'
        $result.runs[0].draft_pr_gate.handoff_package.remaining_risks | Should -Contain 'verification outcome is PARTIAL'
        $result.runs[0].draft_pr_gate.handoff_package.blocked_reasons | Should -Contain 'review state is unresolved: PENDING'
        $result.runs[0].draft_pr_gate.handoff_package.blocked_reasons | Should -Contain 'architecture baseline mismatch requires review'
        $result.runs[0].draft_pr_gate.handoff_package.package_complete | Should -Be $false
        $result.runs[0].draft_pr_gate.handoff_package.automatic_merge_allowed | Should -Be $false
        $result.runs[0].run_packet.plan.goal | Should -Be 'Ship run contract primitives'
        $result.runs[0].run_packet.plan_checkpoints.Count | Should -Be 6
        $result.runs[0].run_packet.managed_loop.peer_to_peer_allowed | Should -Be $false
        $result.runs[0].run_packet.managed_loop.assignment_state | Should -Be 'assigned'
        $result.runs[0].run_packet.phase_gate.stop_reason | Should -Be 'needs_user_decision'
        $result.runs[0].run_packet.outcome.status | Should -Be 'needs_user_decision'
        $result.runs[0].run_packet.draft_pr_gate.merge_requires_human | Should -Be $true
        $result.runs[0].run_packet.draft_pr_gate.handoff_package.suggested_next_action | Should -Be 'rerun_verify'
        $result.runs[0].Contains('observation_pack') | Should -Be $false
        $result.runs[0].Contains('consultation_packet') | Should -Be $false
    }

    It 'excludes completed or review-passed runs from restore candidates' {
        $run = [ordered]@{
            run_id             = 'task:task-done'
            task_id            = 'task-done'
            task_state         = 'completed'
            review_state       = 'PASS'
            primary_label      = 'builder-1'
            primary_pane_id    = '%2'
            provider_target    = 'codex:gpt-5.4'
            agent_role         = 'worker'
            branch             = 'worktree-done'
            head_sha           = 'done1234'
            checkpoint_package = [ordered]@{
                resume_handle          = 'checkpoint:task-task-done:done1234'
                next_exact_step        = 'done'
                claim_level            = 'PASS'
                assigned_worktree      = '.worktrees/builder-1'
                branch                 = 'worktree-done'
                head_sha               = 'done1234'
                session_type           = 'managed_worktree'
                checkpoint_freshness   = [ordered]@{ state = 'fresh' }
                context_pressure_status = [ordered]@{ state = 'healthy' }
                summary_quality_gate   = [ordered]@{ valid = $true }
                resume_policy          = [ordered]@{
                    resume_allowed                 = $false
                    completed_task_resume_rejected = $true
                    requires_same_head_sha         = $true
                    requires_operator_control      = $true
                }
            }
            context_contract   = [ordered]@{
                context_capsule = [ordered]@{
                    capsule_id = 'capsule:task-task-done:done1234'
                    validation = [ordered]@{ valid = $true }
                    privacy    = [ordered]@{ raw_transcript_stored = $false }
                }
            }
        }

        @(Get-RunRestoreCandidates -Runs @($run)).Count | Should -Be 0
    }

    It 'blocks draft PR gate when draft PR evidence exists without verification evidence' {
        $run = [ordered]@{
            review_state      = 'PASS'
            review_required   = $true
            verification_plan = @('Invoke-Pester')
            changed_files     = @('scripts/winsmux-core.ps1')
            task              = 'Create draft package'
            goal              = 'Create draft package'
            verification_result = $null
            security_verdict  = $null
            experiment_packet = $null
        }
        $events = @(
            [ordered]@{
                timestamp   = '2026-04-10T12:04:00+09:00'
                line_number = 1
                event       = 'operator.draft_pr.created'
                data        = [ordered]@{ draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/999' }
            }
        )

        $gate = New-RunDraftPrGate -Run $run -EventRecords $events

        $gate.state | Should -Be 'blocked'
        $gate.draft_pr_url | Should -Be 'https://github.com/Sora-bluesky/winsmux/pull/999'
        $gate.auto_merge_allowed | Should -Be $false
        $gate.merge_requires_human | Should -Be $true
        $gate.handoff_package.validation.evidence_complete | Should -Be $false
        $gate.handoff_package.blocked_reasons | Should -Contain 'verification evidence is missing'
        $gate.handoff_package.suggested_next_action | Should -Be 'resolve blocked reasons before creating or merging a draft PR'
    }

    It 'requires final human approval for enterprise approval chains' {
        $run = [PSCustomObject]@{
            run_id                = 'task:task-359'
            task_id               = 'TASK-359'
            task                  = 'Enterprise approval chain'
            task_type             = 'feature'
            priority              = 'P1'
            branch                = 'worktree-builder-1'
            head_sha              = 'abc1234def5678'
            changed_files         = @('scripts/winsmux-core.ps1')
            primary_label         = 'builder-1'
            primary_pane_id       = '%2'
            primary_role          = 'Builder'
            provider_target       = 'codex:gpt-5.5'
            agent_role            = 'worker'
            review_required       = $true
            review_state          = 'PASS'
            verification_plan     = @('Invoke-Pester')
            verification_result   = [ordered]@{ outcome = 'PASS'; summary = 'tests passed' }
            verification_evidence = [ordered]@{ packet_type = 'verification_evidence' }
            context_contract      = [ordered]@{ context_mode = 'isolated' }
            security_policy       = [ordered]@{ execution_profile = 'isolated-enterprise' }
            security_verdict      = [ordered]@{ verdict = 'ALLOW'; reason = 'policy passed' }
            draft_pr_gate         = [ordered]@{ state = 'passed' }
            phase_gate            = [ordered]@{ stop_reason = ''; stop_stage = '' }
            architecture_contract = [ordered]@{
                score_regression = $false
                baseline = [ordered]@{ review_required_on_drift = $true }
            }
            last_event            = 'operator.review_passed'
        }
        $events = @(
            [ordered]@{ timestamp = '2026-05-16T12:00:00+09:00'; line_number = 1; event = 'operator.review_requested'; label = 'reviewer-1'; pane_id = '%3'; role = 'Reviewer'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T12:05:00+09:00'; line_number = 2; event = 'operator.review_passed'; label = 'reviewer-1'; pane_id = '%3'; role = 'Reviewer'; data = [ordered]@{} }
        )

        $run | Add-Member -NotePropertyName audit_chain -NotePropertyValue (New-RunAuditChainContract -Run $run -EventRecords $events)
        $envelope = New-RunVerificationEnvelope -Run $run

        $run.audit_chain.approval.mode | Should -Be 'enterprise_multi_stage'
        $run.audit_chain.approval.chain_required | Should -Be $true
        $run.audit_chain.approval.state | Should -Be 'missing'
        $run.audit_chain.approval.final_approval_required | Should -Be $true
        @($run.audit_chain.approval.stages | ForEach-Object { $_.name }) | Should -Be @('static_verification', 'policy_gate', 'operator_review', 'human_final_approval')
        ($run.audit_chain.approval.stages | Where-Object { $_.name -eq 'human_final_approval' } | Select-Object -First 1).state | Should -Be 'missing'
        $envelope.release_decision.status | Should -Be 'blocked'
        $envelope.release_decision.blocked_reasons | Should -Contain 'approval stage human_final_approval is missing'
    }

    It 'rejects enterprise final approval from the builder actor' {
        $run = [PSCustomObject]@{
            run_id                = 'task:task-359-self'
            task_id               = 'TASK-359'
            task                  = 'Enterprise approval chain'
            task_type             = 'feature'
            priority              = 'P1'
            branch                = 'worktree-builder-1'
            head_sha              = 'abc1234def5678'
            changed_files         = @('scripts/winsmux-core.ps1')
            primary_label         = 'builder-1'
            primary_pane_id       = '%2'
            primary_role          = 'Builder'
            provider_target       = 'codex:gpt-5.5'
            agent_role            = 'worker'
            review_required       = $true
            review_state          = 'PASS'
            verification_plan     = @('Invoke-Pester')
            verification_result   = [ordered]@{ outcome = 'PASS'; summary = 'tests passed' }
            verification_evidence = [ordered]@{ packet_type = 'verification_evidence' }
            context_contract      = [ordered]@{ context_mode = 'isolated' }
            security_policy       = [ordered]@{ execution_profile = 'isolated-enterprise' }
            security_verdict      = [ordered]@{ verdict = 'ALLOW'; reason = 'policy passed' }
            draft_pr_gate         = [ordered]@{ state = 'passed' }
            phase_gate            = [ordered]@{ stop_reason = ''; stop_stage = '' }
            architecture_contract = [ordered]@{
                score_regression = $false
                baseline = [ordered]@{ review_required_on_drift = $true }
            }
            last_event            = 'operator.final_approval_granted'
        }
        $events = @(
            [ordered]@{ timestamp = '2026-05-16T12:00:00+09:00'; line_number = 1; event = 'operator.review_requested'; label = 'reviewer-1'; pane_id = '%3'; role = 'Reviewer'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T12:05:00+09:00'; line_number = 2; event = 'operator.review_passed'; label = 'reviewer-1'; pane_id = '%3'; role = 'Reviewer'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T12:06:00+09:00'; line_number = 3; event = 'operator.final_approval_granted'; label = 'builder-1'; pane_id = '%2'; role = 'Builder'; data = [ordered]@{} }
        )

        $run | Add-Member -NotePropertyName audit_chain -NotePropertyValue (New-RunAuditChainContract -Run $run -EventRecords $events)
        $envelope = New-RunVerificationEnvelope -Run $run
        $finalStage = $run.audit_chain.approval.stages | Where-Object { $_.name -eq 'human_final_approval' } | Select-Object -First 1

        $run.audit_chain.approval.state | Should -Be 'failed'
        $finalStage.state | Should -Be 'failed'
        $finalStage.actor_separation_satisfied | Should -Be $false
        $envelope.release_decision.blocked_reasons | Should -Contain 'approval stage human_final_approval violates actor separation'
    }

    It 'rejects enterprise final approval without approver identity' {
        $run = [PSCustomObject]@{
            run_id                = 'task:task-359-blank-final'
            task_id               = 'TASK-359'
            task                  = 'Enterprise approval chain'
            task_type             = 'feature'
            priority              = 'P1'
            branch                = 'worktree-builder-1'
            head_sha              = 'abc1234def5678'
            changed_files         = @('scripts/winsmux-core.ps1')
            primary_label         = 'builder-1'
            primary_pane_id       = '%2'
            primary_role          = 'Builder'
            provider_target       = 'codex:gpt-5.5'
            agent_role            = 'worker'
            review_required       = $true
            review_state          = 'PASS'
            verification_plan     = @('Invoke-Pester')
            verification_result   = [ordered]@{ outcome = 'PASS'; summary = 'tests passed' }
            verification_evidence = [ordered]@{ packet_type = 'verification_evidence' }
            context_contract      = [ordered]@{ context_mode = 'isolated' }
            security_policy       = [ordered]@{ execution_profile = 'isolated-enterprise' }
            security_verdict      = [ordered]@{ verdict = 'ALLOW'; reason = 'policy passed' }
            draft_pr_gate         = [ordered]@{ state = 'passed' }
            phase_gate            = [ordered]@{ stop_reason = ''; stop_stage = '' }
            architecture_contract = [ordered]@{
                score_regression = $false
                baseline = [ordered]@{ review_required_on_drift = $true }
            }
            last_event            = 'operator.final_approval_granted'
        }
        $events = @(
            [ordered]@{ timestamp = '2026-05-16T12:00:00+09:00'; line_number = 1; event = 'operator.review_requested'; label = 'reviewer-1'; pane_id = '%3'; role = 'Reviewer'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T12:05:00+09:00'; line_number = 2; event = 'operator.review_passed'; label = 'reviewer-1'; pane_id = '%3'; role = 'Reviewer'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T12:06:00+09:00'; line_number = 3; event = 'operator.final_approval_granted'; label = ''; pane_id = ''; role = ''; data = [ordered]@{} }
        )

        $run | Add-Member -NotePropertyName audit_chain -NotePropertyValue (New-RunAuditChainContract -Run $run -EventRecords $events)
        $envelope = New-RunVerificationEnvelope -Run $run
        $finalStage = $run.audit_chain.approval.stages | Where-Object { $_.name -eq 'human_final_approval' } | Select-Object -First 1

        $run.audit_chain.approval.state | Should -Be 'failed'
        $finalStage.state | Should -Be 'failed'
        $finalStage.actor_separation_satisfied | Should -Be $false
        $envelope.release_decision.blocked_reasons | Should -Contain 'approval stage human_final_approval violates actor separation'
    }

    It 'rejects enterprise review approval from the builder actor' {
        $run = [PSCustomObject]@{
            run_id                = 'task:task-359-review-self'
            task_id               = 'TASK-359'
            task                  = 'Enterprise approval chain'
            task_type             = 'feature'
            priority              = 'P1'
            branch                = 'worktree-builder-1'
            head_sha              = 'abc1234def5678'
            changed_files         = @('scripts/winsmux-core.ps1')
            primary_label         = 'builder-1'
            primary_pane_id       = '%2'
            primary_role          = 'Builder'
            provider_target       = 'codex:gpt-5.5'
            agent_role            = 'worker'
            review_required       = $true
            review_state          = 'PASS'
            verification_plan     = @('Invoke-Pester')
            verification_result   = [ordered]@{ outcome = 'PASS'; summary = 'tests passed' }
            verification_evidence = [ordered]@{ packet_type = 'verification_evidence' }
            context_contract      = [ordered]@{ context_mode = 'isolated' }
            security_policy       = [ordered]@{ execution_profile = 'isolated-enterprise' }
            security_verdict      = [ordered]@{ verdict = 'ALLOW'; reason = 'policy passed' }
            draft_pr_gate         = [ordered]@{ state = 'passed' }
            phase_gate            = [ordered]@{ stop_reason = ''; stop_stage = '' }
            architecture_contract = [ordered]@{
                score_regression = $false
                baseline = [ordered]@{ review_required_on_drift = $true }
            }
            last_event            = 'operator.final_approval_granted'
        }
        $events = @(
            [ordered]@{ timestamp = '2026-05-16T12:00:00+09:00'; line_number = 1; event = 'operator.review_requested'; label = 'reviewer-1'; pane_id = '%3'; role = 'Reviewer'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T12:05:00+09:00'; line_number = 2; event = 'operator.review_passed'; label = 'builder-1'; pane_id = '%2'; role = 'Builder'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T12:06:00+09:00'; line_number = 3; event = 'operator.final_approval_granted'; label = 'operator-1'; pane_id = '%1'; role = 'Operator'; data = [ordered]@{} }
        )

        $run | Add-Member -NotePropertyName audit_chain -NotePropertyValue (New-RunAuditChainContract -Run $run -EventRecords $events)
        $envelope = New-RunVerificationEnvelope -Run $run
        $reviewStage = $run.audit_chain.approval.stages | Where-Object { $_.name -eq 'operator_review' } | Select-Object -First 1

        $run.audit_chain.approval.state | Should -Be 'failed'
        $reviewStage.state | Should -Be 'failed'
        $reviewStage.actor_separation_satisfied | Should -Be $false
        $envelope.release_decision.blocked_reasons | Should -Contain 'approval stage operator_review violates actor separation'
    }

    It 'allows enterprise approval chain only after separated final approval' {
        $run = [PSCustomObject]@{
            run_id                = 'task:task-359-approved'
            task_id               = 'TASK-359'
            task                  = 'Enterprise approval chain'
            task_type             = 'feature'
            priority              = 'P1'
            branch                = 'worktree-builder-1'
            head_sha              = 'abc1234def5678'
            changed_files         = @('scripts/winsmux-core.ps1')
            primary_label         = 'builder-1'
            primary_pane_id       = '%2'
            primary_role          = 'Builder'
            provider_target       = 'codex:gpt-5.5'
            agent_role            = 'worker'
            review_required       = $true
            review_state          = 'PASS'
            verification_plan     = @('Invoke-Pester')
            verification_result   = [ordered]@{ outcome = 'PASS'; summary = 'tests passed' }
            verification_evidence = [ordered]@{ packet_type = 'verification_evidence' }
            context_contract      = [ordered]@{ context_mode = 'isolated' }
            security_policy       = [ordered]@{ execution_profile = 'isolated-enterprise' }
            security_verdict      = [ordered]@{ verdict = 'ALLOW'; reason = 'policy passed' }
            draft_pr_gate         = [ordered]@{ state = 'passed' }
            phase_gate            = [ordered]@{ stop_reason = ''; stop_stage = '' }
            architecture_contract = [ordered]@{
                score_regression = $false
                baseline = [ordered]@{ review_required_on_drift = $true }
            }
            last_event            = 'operator.final_approval_granted'
        }
        $events = @(
            [ordered]@{ timestamp = '2026-05-16T12:00:00+09:00'; line_number = 1; event = 'operator.review_requested'; label = 'reviewer-1'; pane_id = '%3'; role = 'Reviewer'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T12:04:00+09:00'; line_number = 2; event = 'operator.review_passed'; label = 'builder-1'; pane_id = '%2'; role = 'Builder'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T03:05:00Z'; line_number = 3; event = 'operator.review_passed'; label = 'reviewer-1'; pane_id = '%3'; role = 'Reviewer'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T12:06:00+09:00'; line_number = 4; event = 'operator.final_approval_denied'; label = 'operator-1'; pane_id = '%1'; role = 'Operator'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T03:07:00Z'; line_number = 5; event = 'operator.final_approval_granted'; label = 'operator-1'; pane_id = '%1'; role = 'Operator'; data = [ordered]@{} }
        )

        $run | Add-Member -NotePropertyName audit_chain -NotePropertyValue (New-RunAuditChainContract -Run $run -EventRecords $events)
        $envelope = New-RunVerificationEnvelope -Run $run
        $reviewStage = $run.audit_chain.approval.stages | Where-Object { $_.name -eq 'operator_review' } | Select-Object -First 1
        $finalStage = $run.audit_chain.approval.stages | Where-Object { $_.name -eq 'human_final_approval' } | Select-Object -First 1

        $run.audit_chain.approval.state | Should -Be 'approved'
        $reviewStage.state | Should -Be 'approved'
        $reviewStage.actor_separation_satisfied | Should -Be $true
        $finalStage.state | Should -Be 'approved'
        $finalStage.decided_event | Should -Be 'operator.final_approval_granted'
        $finalStage.actor_separation_satisfied | Should -Be $true
        $envelope.release_decision.status | Should -Be 'approved'
        $envelope.release_decision.blocked_reasons | Should -Be @()
    }

    It 'marks failed enterprise verification as a failed approval stage' {
        $run = [PSCustomObject]@{
            run_id                = 'task:task-359-verify-fail'
            task_id               = 'TASK-359'
            task                  = 'Enterprise approval chain'
            task_type             = 'feature'
            priority              = 'P1'
            branch                = 'worktree-builder-1'
            head_sha              = 'abc1234def5678'
            changed_files         = @('scripts/winsmux-core.ps1')
            primary_label         = 'builder-1'
            primary_pane_id       = '%2'
            primary_role          = 'Builder'
            provider_target       = 'codex:gpt-5.5'
            agent_role            = 'worker'
            review_required       = $true
            review_state          = 'PASS'
            verification_plan     = @('Invoke-Pester')
            verification_result   = [ordered]@{ outcome = 'FAIL'; summary = 'tests failed' }
            verification_evidence = [ordered]@{ packet_type = 'verification_evidence' }
            context_contract      = [ordered]@{ context_mode = 'isolated' }
            security_policy       = [ordered]@{ execution_profile = 'isolated-enterprise' }
            security_verdict      = [ordered]@{ verdict = 'ALLOW'; reason = 'policy passed' }
            draft_pr_gate         = [ordered]@{ state = 'passed' }
            phase_gate            = [ordered]@{ stop_reason = ''; stop_stage = '' }
            architecture_contract = [ordered]@{
                score_regression = $false
                baseline = [ordered]@{ review_required_on_drift = $true }
            }
            last_event            = 'pipeline.verify.fail'
        }
        $events = @(
            [ordered]@{ timestamp = '2026-05-16T12:00:00+09:00'; line_number = 1; event = 'operator.review_requested'; label = 'reviewer-1'; pane_id = '%3'; role = 'Reviewer'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T12:05:00+09:00'; line_number = 2; event = 'operator.review_passed'; label = 'reviewer-1'; pane_id = '%3'; role = 'Reviewer'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T12:06:00+09:00'; line_number = 3; event = 'pipeline.verify.fail'; label = 'builder-1'; pane_id = '%2'; role = 'Builder'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-05-16T12:07:00+09:00'; line_number = 4; event = 'operator.final_approval_granted'; label = 'operator-1'; pane_id = '%1'; role = 'Operator'; data = [ordered]@{} }
        )

        $run | Add-Member -NotePropertyName audit_chain -NotePropertyValue (New-RunAuditChainContract -Run $run -EventRecords $events)
        $envelope = New-RunVerificationEnvelope -Run $run
        $verificationStage = $run.audit_chain.approval.stages | Where-Object { $_.name -eq 'static_verification' } | Select-Object -First 1

        $run.audit_chain.approval.state | Should -Be 'failed'
        $verificationStage.state | Should -Be 'failed'
        $envelope.release_decision.blocked_reasons | Should -Contain 'verification outcome is FAIL'
    }

    It 'keeps in-progress outcome when draft PR gate is blocked only for missing evidence' {
        $run = [ordered]@{
            task_state            = 'in_progress'
            review_state          = 'PENDING'
            last_event            = ''
            experiment_packet     = $null
            verification_result   = $null
            phase_gate            = [ordered]@{ stop_reason = '' }
            draft_pr_gate         = [ordered]@{ state = 'blocked' }
            architecture_contract = [ordered]@{
                score_regression = $false
                baseline = [ordered]@{ review_required_on_drift = $true }
            }
        }

        $outcome = New-RunOutcomeContract -Run $run

        $outcome.status | Should -Be 'in_progress'
    }

    It 'does not treat benign drift text as architecture mismatch' {
        $run = [ordered]@{
            run_id        = 'task:task-drift-ok'
            task_id       = 'task-drift-ok'
            action_items  = @()
            pane_count    = 1
            changed_file_count = 0
            phase_gate    = [ordered]@{ stop_reason = '' }
            draft_pr_gate = [ordered]@{ state = '' }
            tdd_gate      = [ordered]@{ state = '' }
            verification_result = [ordered]@{ outcome = 'PASS' }
            verification_evidence = [ordered]@{}
            security_verdict    = [ordered]@{ verdict = 'ALLOW' }
        }
        $events = @(
            [ordered]@{
                event   = 'pipeline.drift_check.pass'
                message = 'no drift detected; drift check passed'
                status  = 'completed'
                data    = [ordered]@{ task_id = 'task-drift-ok' }
            }
        )

        $run.run_insights = New-RunInsightsContract -Run $run -EventRecords $events
        $contract = New-RunArchitectureContract -Run $run

        @($run.run_insights.drift_signals).Count | Should -Be 0
        $contract.current.drift_score | Should -Be 0
        $contract.score_regression | Should -Be $false
        $contract.status | Should -Be 'baseline_match'
    }

    It 'scrubs checkpoint package path and body fields' {
        $run = [PSCustomObject]@{
            run_id              = 'task:task-999'
            task_id             = 'task-999'
            worktree            = 'C:\Users\Example\repo\.worktrees\builder-1'
            experiment_packet   = $null
            branch              = 'worktree-builder-1'
            head_sha            = 'abc123'
            task_state          = 'in_progress'
            review_state        = 'PENDING'
            changed_files       = @('C:\Users\Example\repo\secret.txt', 'scripts/winsmux-core.ps1', '..\private.md')
            verification_plan   = @('Invoke-Pester')
            verification_result = [ordered]@{
                outcome     = 'PARTIAL'
                summary     = 'C:\Users\Example must not leak'
                next_action = 'private next action'
            }
            context_contract    = [ordered]@{
                context_pack_id = 'ctx-C:/Users/Example/context.md'
                semantic_context = [ordered]@{
                    context_pack_id = 'sem-C:/Users/Example/semantic.md'
                }
            }
        }

        $package = New-RunCheckpointPackage -Run $run

        $package.assigned_worktree | Should -Be '.worktrees/builder-1'
        $package.changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $package.changed_file_count | Should -Be 1
        $package.verification.outcome | Should -Be 'PARTIAL'
        $package.end_of_run_snapshot.context.context_pack_id | Should -Be $null
        $package.end_of_run_snapshot.context.semantic_context_pack_id | Should -Be $null
        ($package | ConvertTo-Json -Depth 8) | Should -Not -Match 'Users'
        ($package | ConvertTo-Json -Depth 8) | Should -Not -Match 'private next action'
        $package.worker_git_write_allowed | Should -Be $false
    }

    It 'exposes needs-user-decision as a phase-gated stop before package completion' {
        $run = [PSCustomObject]@{
            goal              = 'Ship guarded package'
            task_state        = 'in_progress'
            review_state      = 'PASS'
            verification_plan = @('Invoke-Pester')
            review_required   = $true
            changed_files     = @('scripts/winsmux-core.ps1')
            task              = 'Create guarded package'
            last_event        = 'operator.draft_pr.required'
            verification_result = [ordered]@{ outcome = 'PASS'; summary = 'verification passed' }
            security_verdict  = [ordered]@{ verdict = 'ALLOW'; reason = '' }
            experiment_packet = $null
        }
        $events = @(
            [ordered]@{ timestamp = '2026-04-10T12:01:00+09:00'; line_number = 1; event = 'pipeline.decompose.completed'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-04-10T12:02:00+09:00'; line_number = 2; event = 'pipeline.collect.completed'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-04-10T12:03:00+09:00'; line_number = 3; event = 'pipeline.verify.pass'; data = [ordered]@{ verification_result = [ordered]@{ outcome = 'PASS' } } },
            [ordered]@{ timestamp = '2026-04-10T12:04:00+09:00'; line_number = 4; event = 'operator.draft_pr.required'; data = [ordered]@{} }
        )

        $run | Add-Member -NotePropertyName draft_pr_gate -NotePropertyValue (New-RunDraftPrGate -Run $run -EventRecords $events)
        $run | Add-Member -NotePropertyName phase_gate -NotePropertyValue (New-RunPhaseGateContract -Run $run -EventRecords $events)
        $outcome = New-RunOutcomeContract -Run $run

        $run.phase_gate.current_stage | Should -Be 'package'
        $run.phase_gate.stop_required | Should -Be $true
        $run.phase_gate.stop_reason | Should -Be 'needs_user_decision'
        $run.phase_gate.auto_continue_allowed | Should -Be $false
        ($run.phase_gate.stages | Where-Object { $_.stage -eq 'package' } | Select-Object -First 1).status | Should -Be 'waiting_for_input'
        ($run.phase_gate.stages | Where-Object { $_.stage -eq 'package' } | Select-Object -First 1).reason | Should -Be 'needs_user_decision'
        $outcome.status | Should -Be 'needs_user_decision'
        (Get-InboxActionableEventKind -EventRecord ([ordered]@{ event = 'operator.draft_pr.required'; status = 'blocked_draft_pr_required' })) | Should -Be 'needs_user_decision'
        $stateModel = New-RunStateModel -EventKind 'needs_user_decision' -LastEvent 'operator.draft_pr.required'
        $stateModel.phase | Should -Be 'package'
        $stateModel.activity | Should -Be 'waiting_for_input'
        $stateModel.detail | Should -Be 'needs_user_decision'
        $passStateModel = New-RunStateModel -ReviewState 'PASS'
        $passStateModel.phase | Should -Be 'package'
        $passStateModel.activity | Should -Be 'waiting_for_input'
        $passStateModel.detail | Should -Be 'needs_user_decision'
    }

    It 'clears stale verification stops when later verification passes' {
        $run = [PSCustomObject]@{
            goal              = 'Recover guarded package'
            task_state        = 'in_progress'
            review_state      = 'PENDING'
            verification_plan = @('Invoke-Pester')
            review_required   = $true
        }
        $events = @(
            [ordered]@{ timestamp = '2026-04-10T12:01:00+09:00'; line_number = 1; event = 'pipeline.verify.partial'; data = [ordered]@{} },
            [ordered]@{ timestamp = '2026-04-10T12:02:00+09:00'; line_number = 2; event = 'pipeline.verify.pass'; data = [ordered]@{ verification_result = [ordered]@{ outcome = 'PASS' } } }
        )

        $phaseGate = New-RunPhaseGateContract -Run $run -EventRecords $events

        $phaseGate.stop_required | Should -Be $false
        $phaseGate.stop_reason | Should -Be ''
        ($phaseGate.stages | Where-Object { $_.stage -eq 'test' } | Select-Object -First 1).status | Should -Be 'completed'
    }

    It 'blocks core logic runs when test-first evidence is missing' {
        $run = [PSCustomObject]@{
            goal              = 'Fix core contract'
            task_type         = 'bugfix'
            task_state        = 'in_progress'
            review_state      = 'PENDING'
            changed_files     = @('scripts/winsmux-core.ps1')
            verification_plan = @('Invoke-Pester')
            review_required   = $true
            verification_result = $null
            experiment_packet = $null
            last_event        = 'pipeline.verify.pass'
        }
        $events = @(
            [ordered]@{ timestamp = '2026-04-10T12:01:00+09:00'; line_number = 1; event = 'pipeline.verify.pass'; data = [ordered]@{ verification_result = [ordered]@{ outcome = 'PASS' } } }
        )

        $run | Add-Member -NotePropertyName tdd_gate -NotePropertyValue (New-RunTddGateContract -Run $run -EventRecords $events)
        $phaseGate = New-RunPhaseGateContract -Run $run -EventRecords $events
        $run | Add-Member -NotePropertyName phase_gate -NotePropertyValue $phaseGate
        $outcome = New-RunOutcomeContract -Run $run

        $run.tdd_gate.required | Should -Be $true
        $run.tdd_gate.state | Should -Be 'blocked'
        $run.tdd_gate.reason | Should -Be 'tdd_evidence_missing'
        $run.tdd_gate.blocked_reasons | Should -Contain 'test-first evidence is missing for a bug fix or core logic change'
        $phaseGate.stop_required | Should -Be $true
        $phaseGate.stop_reason | Should -Be 'tdd_evidence_missing'
        ($phaseGate.stages | Where-Object { $_.stage -eq 'test' } | Select-Object -First 1).status | Should -Be 'blocked'
        $outcome.status | Should -Be 'blocked'
    }

    It 'passes core logic runs when red test evidence exists' {
        $run = [PSCustomObject]@{
            goal              = 'Fix core contract'
            task_type         = 'core_logic'
            task_state        = 'in_progress'
            review_state      = 'PENDING'
            changed_files     = @('scripts/winsmux-core.ps1')
            verification_plan = @('Invoke-Pester')
            review_required   = $true
        }
        $events = @(
            [ordered]@{ timestamp = '2026-04-10T12:00:00+09:00'; line_number = 1; event = 'pipeline.tdd.red'; data = [ordered]@{ tdd_phase = 'red' } },
            [ordered]@{ timestamp = '2026-04-10T12:01:00+09:00'; line_number = 2; event = 'pipeline.verify.pass'; data = [ordered]@{ verification_result = [ordered]@{ outcome = 'PASS' } } }
        )

        $run | Add-Member -NotePropertyName tdd_gate -NotePropertyValue (New-RunTddGateContract -Run $run -EventRecords $events)
        $phaseGate = New-RunPhaseGateContract -Run $run -EventRecords $events

        $run.tdd_gate.required | Should -Be $true
        $run.tdd_gate.state | Should -Be 'passed'
        $run.tdd_gate.red_event | Should -Be 'pipeline.tdd.red'
        $phaseGate.stop_required | Should -Be $false
        ($phaseGate.stages | Where-Object { $_.stage -eq 'test' } | Select-Object -First 1).status | Should -Be 'completed'
    }

    It 'waives test-first evidence only when an exception reason is recorded' {
        $run = [PSCustomObject]@{
            goal              = 'Fix core contract'
            task_type         = 'bugfix'
            task_state        = 'in_progress'
            review_state      = 'PENDING'
            changed_files     = @('scripts/winsmux-core.ps1')
            verification_plan = @('Invoke-Pester')
            review_required   = $true
        }
        $events = @(
            [ordered]@{
                timestamp   = '2026-04-10T12:00:00+09:00'
                line_number = 1
                event       = 'pipeline.tdd.exception'
                data        = [ordered]@{ tdd_exception_reason = 'legacy behavior has no deterministic fixture yet' }
            }
        )

        $gate = New-RunTddGateContract -Run $run -EventRecords $events

        $gate.required | Should -Be $true
        $gate.state | Should -Be 'waived'
        $gate.exception_event | Should -Be 'pipeline.tdd.exception'
        $gate.exception_reason | Should -Be 'legacy behavior has no deterministic fixture yet'
    }

    It 'blocks test-first exceptions that omit an exception reason' {
        $run = [PSCustomObject]@{
            goal              = 'Fix core contract'
            task_type         = 'BugFix'
            task_state        = 'in_progress'
            review_state      = 'PENDING'
            changed_files     = @('Scripts\Winsmux-Core.ps1')
            verification_plan = @('Invoke-Pester')
            review_required   = $true
        }
        $events = @(
            [ordered]@{
                timestamp   = '2026-04-10T12:00:00+09:00'
                line_number = 1
                event       = 'pipeline.tdd.exception'
                data        = [ordered]@{}
            }
        )

        $gate = New-RunTddGateContract -Run $run -EventRecords $events

        $gate.required | Should -Be $true
        $gate.state | Should -Be 'blocked'
        $gate.reason | Should -Be 'tdd_evidence_missing'
        $gate.exception_event | Should -Be ''
    }

    It 'ignores stale draft PR evidence that does not match the run head sha' {
        $run = [PSCustomObject]@{
            head_sha          = 'current-sha'
            review_state      = 'PASS'
            review_required   = $true
            verification_plan = @('Invoke-Pester')
            changed_files     = @('scripts/winsmux-core.ps1')
            task              = 'Create draft package'
            goal              = 'Create draft package'
            verification_result = [ordered]@{ outcome = 'PASS'; summary = 'verification passed' }
            security_verdict  = [ordered]@{ verdict = 'ALLOW'; reason = '' }
            experiment_packet = $null
        }
        $events = @(
            [ordered]@{
                timestamp   = '2026-04-10T12:04:00+09:00'
                line_number = 1
                event       = 'operator.draft_pr.created'
                head_sha    = ''
                data        = [ordered]@{ draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/999' }
            },
            [ordered]@{
                timestamp   = '2026-04-10T12:05:00+09:00'
                line_number = 2
                event       = 'operator.draft_pr.created'
                head_sha    = 'old-sha'
                data        = [ordered]@{ draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/998' }
            }
        )

        $gate = New-RunDraftPrGate -Run $run -EventRecords $events
        $run | Add-Member -NotePropertyName draft_pr_gate -NotePropertyValue $gate
        $phaseGate = New-RunPhaseGateContract -Run $run -EventRecords $events

        $gate.state | Should -Be 'required'
        $gate.draft_pr_url | Should -Be ''
        $phaseGate.stop_required | Should -Be $true
        $phaseGate.stop_reason | Should -Be 'needs_user_decision'
        ($phaseGate.stages | Where-Object { $_.stage -eq 'package' } | Select-Object -First 1).reason | Should -Be 'needs_user_decision'
    }

    It 'uses the newest same-timestamp draft PR evidence for the run head sha' {
        $run = [PSCustomObject]@{
            head_sha            = 'current-sha'
            review_state        = 'PASS'
            review_required     = $true
            verification_plan   = @('Invoke-Pester')
            changed_files       = @('scripts/winsmux-core.ps1')
            task                = 'Create draft package'
            goal                = 'Create draft package'
            verification_result = [ordered]@{ outcome = 'PASS'; summary = 'verification passed' }
            security_verdict    = [ordered]@{ verdict = 'ALLOW'; reason = '' }
            experiment_packet   = $null
        }
        $events = @(
            [ordered]@{
                timestamp   = '2026-04-10T12:04:00+09:00'
                line_number = 1
                event       = 'operator.draft_pr.created'
                head_sha    = 'current-sha'
                data        = [ordered]@{ draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/997' }
            },
            [ordered]@{
                timestamp   = '2026-04-10T12:04:00+09:00'
                line_number = 2
                event       = 'operator.draft_pr.created'
                head_sha    = 'current-sha'
                data        = [ordered]@{ draft_pr_url = 'https://github.com/Sora-bluesky/winsmux/pull/998' }
            }
        )

        $gate = New-RunDraftPrGate -Run $run -EventRecords $events

        $gate.state | Should -Be 'passed'
        $gate.draft_pr_url | Should -Be 'https://github.com/Sora-bluesky/winsmux/pull/998'
    }

    It 'supports winsmux runs --json through the top-level CLI entrypoint' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:runsTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Implement run ledger
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
"@ | Set-Content -Path $script:runsManifestPath -Encoding UTF8

        $bridgeScript = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $childScript = @'
Set-Item -Path function:winsmux -Value {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$args)
    $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
    switch -Regex ($commandLine) {
        '^capture-pane .*%2' { @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>'); break }
        default { throw "unexpected winsmux call: $commandLine" }
    }
}
Set-Location '__RUNS_TEMP_ROOT__'
& '__BRIDGE_SCRIPT__' runs --json
'@
        $childScript = $childScript.Replace('__RUNS_TEMP_ROOT__', $script:runsTempRoot).Replace('__BRIDGE_SCRIPT__', $bridgeScript)
        $output = & pwsh -NoProfile -Command $childScript

        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.run_count | Should -Be 1
        $result.runs[0].run_id | Should -Be 'task:task-256'
        $result.runs[0].experiment_packet | Should -Be $null
        $result.runs[0].run_insights.retry_count | Should -Be 0
        @($result.runs[0].run_insights.drift_signals).Count | Should -Be 0
        $result.runs[0].run_insights.intervention_count | Should -Be 1
        $result.runs[0].run_insights.unhealthy_session_size | Should -Be $false
        $result.runs[0].run_insights.blocked_reasons | Should -Contain 'tdd_evidence_missing'
        $result.runs[0].run_insights.blocked_reasons | Should -Contain 'draft_pr_gate_blocked'
        $result.runs[0].run_insights.blocked_reasons | Should -Contain 'tdd_gate_blocked'
        $result.runs[0].run_insights.next_improvements | Should -Contain 'capture operator decisions as reusable guidance'
        $result.runs[0].run_insights.next_improvements | Should -Contain 'resolve blocked reasons before release'
        $result.runs[0].architecture_contract.current.drift_score | Should -Be 0
        $result.runs[0].architecture_contract.score_regression | Should -Be $false
        $result.runs[0].architecture_contract.status | Should -Be 'baseline_match'
        $result.runs[0].run_packet.run_insights.retry_count | Should -Be 0
    }

    It 'keeps experiment packets scoped to strong run keys when multiple runs share a branch' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:runsTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-256
    task: Investigate cache mismatch
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: shared-worktree
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:00:00+09:00
  builder-2:
    pane_id: %6
    role: Builder
    task_id: task-999
    task: Investigate cache mismatch separately
    task_state: in_progress
    task_owner: builder-2
    review_state: PENDING
    branch: shared-worktree
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["tests/winsmux-bridge.Tests.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T12:01:00+09:00
"@ | Set-Content -Path $script:runsManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-10T12:01:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.progress'
                message   = 'builder-1 hypothesis update'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'busy'
                branch    = 'shared-worktree'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id    = 'task-256'
                    run_id     = 'task:task-256'
                    hypothesis = 'builder-1 owns this experiment packet'
                    result     = 'pending'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T12:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.progress'
                message   = 'builder-2 hypothesis update'
                label     = 'builder-2'
                pane_id   = '%6'
                role      = 'Builder'
                status    = 'busy'
                branch    = 'shared-worktree'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id    = 'task-999'
                    run_id     = 'task:task-999'
                    hypothesis = 'builder-2 owns this experiment packet'
                    result     = 'pending'
                }
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:runsEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                '^capture-pane .*%6' { return @('gpt-5.4   61% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Runs -RunsTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)

        @($result.runs).Count | Should -Be 2
        $first = @($result.runs | Where-Object { $_.run_id -eq 'task:task-256' })[0]
        $second = @($result.runs | Where-Object { $_.run_id -eq 'task:task-999' })[0]
        $first.experiment_packet.run_id | Should -Be 'task:task-256'
        $first.experiment_packet.hypothesis | Should -Be 'builder-1 owns this experiment packet'
        $second.experiment_packet.run_id | Should -Be 'task:task-999'
        $second.experiment_packet.hypothesis | Should -Be 'builder-2 owns this experiment packet'
    }

    It 'surfaces security policy and latest security verdict in runs json' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:runsTempRoot
panes:
  worker-1:
    pane_id: %2
    role: Worker
    task_id: task-273
    task: Enforce security policy
    task_state: blocked
    task_owner: worker-1
    review_state: ''
    branch: worktree-worker-1
    head_sha: def5678abc1234
    changed_file_count: 0
    changed_files: '[]'
    security_policy: '{\"mode\":\"blocklist\",\"allow_patterns\":[\"Invoke-Pester\"],\"block_patterns\":[\"git reset --hard\"]}'
    last_event: pipeline.security.blocked
    last_event_at: 2026-04-10T12:03:00+09:00
"@ | Set-Content -Path $script:runsManifestPath -Encoding UTF8

        ([ordered]@{
            timestamp = '2026-04-10T12:03:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'pipeline.security.blocked'
            message   = 'security monitor blocked exec'
            label     = 'worker-1'
            pane_id   = '%2'
            role      = 'Worker'
            branch    = 'worktree-worker-1'
            head_sha  = 'def5678abc1234'
            data      = [ordered]@{
                task_id = 'task-273'
                run_id  = 'task:task-273'
                stage   = 'EXEC'
                verdict = 'BLOCK'
                reason  = 'dangerous command approval'
                advisory_mode = $false
                allow   = @('read', 'write')
                block   = @('hard_reset')
                next_action = 'revise_request_or_override'
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:runsEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Runs -RunsTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)

        $result.runs[0].security_policy.mode | Should -Be 'blocklist'
        @($result.runs[0].security_policy.block_patterns) | Should -Be @('git reset --hard')
        $result.runs[0].security_verdict.verdict | Should -Be 'BLOCK'
        $result.runs[0].run_packet.security_verdict.reason | Should -Be 'dangerous command approval'
    }
}

Describe 'winsmux digest command' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:digestTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-digest-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:digestTempRoot -Force | Out-Null
        $script:digestManifestDir = Join-Path $script:digestTempRoot '.winsmux'
        New-Item -ItemType Directory -Path $script:digestManifestDir -Force | Out-Null
        $script:digestManifestPath = Join-Path $script:digestManifestDir 'manifest.yaml'
        $script:digestEventsPath = Join-Path $script:digestManifestDir 'events.jsonl'

        Push-Location $script:digestTempRoot
    }

    AfterEach {
        Pop-Location
        if ($script:digestTempRoot -and (Test-Path $script:digestTempRoot)) {
            Remove-Item -Path $script:digestTempRoot -Recurse -Force
        }

        $global:Target = $null
        $global:Rest = @()
        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

    It 'renders a high-signal evidence digest per run' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:digestTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-246
    task: Build evidence digest
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 2
    changed_files: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T14:00:00+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-10T14:01:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:digestEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $output = Invoke-Digest | Out-String

        $output | Should -Match 'Run: task:task-246'
        $output | Should -Match 'Next: approval_waiting'
        $output | Should -Match 'Git: worktree-builder-1 @ abc1234'
        $output | Should -Match 'Changed files \(2\):'
        $output | Should -Match 'scripts/winsmux-core.ps1'
    }

    It 'returns digest items as json' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:digestTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-246
    task: Build evidence digest
    task_state: blocked
    task_owner: builder-1
    review_state: FAIL
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_failed
    last_event_at: 2026-04-10T14:00:00+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        $digestObservationPack = New-ObservationPackFile -ProjectDir $script:digestTempRoot -ObservationPack ([ordered]@{
            run_id          = 'task:task-246'
            task_id         = 'task-246'
            pane_id         = '%2'
            slot            = 'slot-builder-1'
            hypothesis      = 'result summary should appear in digest'
            env_fingerprint = 'env:abc123'
        })
        $digestConsultationPacket = New-ConsultationPacketFile -ProjectDir $script:digestTempRoot -ConsultationPacket ([ordered]@{
            run_id         = 'task:task-246'
            task_id        = 'task-246'
            pane_id        = '%2'
            slot           = 'slot-builder-1'
            kind           = 'consult_result'
            mode           = 'reconcile'
            target_slot    = 'slot-review-1'
            confidence     = 0.88
            recommendation = 'treat review failure as blocking'
            next_test      = 'review_failed'
        })

        ([ordered]@{
            timestamp = '2026-04-10T14:01:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'operator.review_failed'
            message   = 'review failed'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id              = 'task-246'
                hypothesis           = 'result summary should appear in digest'
                result               = 'review failure reproduced'
                confidence           = 0.88
                next_action          = 'review_failed'
                observation_pack_ref = $digestObservationPack.reference
                consultation_ref     = $digestConsultationPacket.reference
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:digestEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Digest -DigestTarget '--json' | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.item_count | Should -Be 1
        $result.summary.review_failed | Should -Be 1
        $result.items[0].run_id | Should -Be 'task:task-246'
        $result.items[0].next_action | Should -Be 'review_failed'
        $result.items[0].head_short | Should -Be 'abc1234'
        $result.items[0].changed_files | Should -Be @('scripts/winsmux-core.ps1')
        $result.items[0].hypothesis | Should -Be 'result summary should appear in digest'
        $result.items[0].confidence | Should -Be 0.88
        $result.items[0].observation_pack_ref | Should -Be $digestObservationPack.reference
        $result.items[0].consultation_ref | Should -Be $digestConsultationPacket.reference
        $result.items[0].Contains('observation_pack') | Should -Be $false
        $result.items[0].Contains('consultation_packet') | Should -Be $false
    }

    It 'returns digest event summaries when --events is supplied' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:digestTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-274
    task: Build event summaries
    task_state: blocked
    task_owner: builder-1
    review_state: ''
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 0
    changed_files: '[]'
    last_event: pipeline.security.blocked
    last_event_at: 2026-04-10T14:02:00+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        @(
            ([ordered]@{
                timestamp = '2026-04-10T14:01:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.noise'
                message   = 'ignore me'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T14:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pipeline.security.blocked'
                message   = 'security monitor blocked exec'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                data      = [ordered]@{
                    task_id = 'task-274'
                    run_id  = 'task:task-274'
                    next_action = 'revise_request_or_override'
                }
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $script:digestEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $result = (Invoke-Digest -DigestTarget '--events' -DigestRest @('--json') | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.item_count | Should -Be 1
        $result.items[0].kind | Should -Be 'blocked'
        $result.items[0].source_event | Should -Be 'pipeline.security.blocked'
        $result.items[0].run_id | Should -Be 'task:task-274'
        $result.items[0].next_action | Should -Be 'revise_request_or_override'
    }

    It 'returns digest delta items only for runs affected after the current cursor' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:digestTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-246
    task: Build evidence digest
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 2
    changed_files: '["scripts/winsmux-core.ps1","tests/winsmux-bridge.Tests.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T14:00:00+09:00
  worker-1:
    pane_id: %6
    role: Worker
    task_id: ''
    task: ''
    task_state: backlog
    task_owner: ''
    review_state: ''
    branch: ''
    head_sha: ''
    changed_file_count: 0
    changed_files: '[]'
    last_event: pane.idle
    last_event_at: 2026-04-10T14:00:30+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        ([ordered]@{
            timestamp = '2026-04-10T14:01:00+09:00'
            session   = 'winsmux-orchestra'
            event     = 'operator.review_requested'
            message   = 'review requested'
            label     = 'reviewer-1'
            pane_id   = '%3'
            role      = 'Reviewer'
            branch    = 'worktree-builder-1'
            head_sha  = 'abc1234def5678'
            data      = [ordered]@{
                task_id = 'task-246'
            }
        } | ConvertTo-Json -Compress) | Set-Content -Path $script:digestEventsPath -Encoding UTF8

        function global:winsmux {
            $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
            switch -Regex ($commandLine) {
                '^capture-pane .*%2' { return @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>') }
                '^capture-pane .*%6' { return @('gpt-5.4   52% context left', 'thinking', 'Esc to interrupt') }
                default { throw "unexpected winsmux call: $commandLine" }
            }
        }

        $cursor = @(Get-BridgeEventRecords -ProjectDir $script:digestTempRoot).Count

        @(
            ([ordered]@{
                timestamp = '2026-04-10T14:02:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.idle'
                message   = 'idle pane'
                label     = 'worker-1'
                pane_id   = '%6'
                role      = 'Worker'
                status    = 'ready'
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T14:03:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'operator.commit_ready'
                message   = 'commit ready'
                label     = ''
                pane_id   = ''
                role      = 'Operator'
                branch    = 'worktree-builder-1'
                head_sha  = 'abc1234def5678'
                status    = 'commit_ready'
                data      = [ordered]@{
                    task_id = 'task-246'
                }
            } | ConvertTo-Json -Compress),
            ([ordered]@{
                timestamp = '2026-04-10T14:04:00+09:00'
                session   = 'winsmux-orchestra'
                event     = 'pane.approval_waiting'
                message   = 'approval prompt detected'
                label     = 'builder-1'
                pane_id   = '%2'
                role      = 'Builder'
                status    = 'approval_waiting'
            } | ConvertTo-Json -Compress)
        ) | Add-Content -Path $script:digestEventsPath -Encoding UTF8

        $delta = Get-BridgeEventDelta -ProjectDir $script:digestTempRoot -Cursor $cursor
        $items = @(Get-DigestDeltaItems -ProjectDir $script:digestTempRoot -EventRecords @($delta.events))

        $delta.cursor | Should -Be 4
        $items.Count | Should -Be 1
        $items[0].run_id | Should -Be 'task:task-246'
        $items[0].next_action | Should -Be 'approval_waiting'
        $items[0].changed_file_count | Should -Be 2
    }

    It 'writes digest stream items as one-line summary records' {
        $item = [ordered]@{
            run_id             = 'task:task-246'
            label              = 'builder-1'
            pane_id            = '%2'
            next_action        = 'commit_ready'
            changed_file_count = 2
            last_event_at      = '2026-04-10T14:03:00+09:00'
        }

        $output = Write-DigestStreamItem -Item $item | Out-String

        $output | Should -Match 'digest task:task-246 builder-1 \(%2\) next=commit_ready files=2'
    }

    It 'supports winsmux digest --json through the top-level CLI entrypoint' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:digestTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-246
    task: Build evidence digest
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T14:00:00+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        $bridgeScript = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $childScript = @'
Set-Item -Path function:winsmux -Value {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$args)
    $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
    switch -Regex ($commandLine) {
        '^capture-pane .*%2' { @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>'); break }
        default { throw "unexpected winsmux call: $commandLine" }
    }
}
Set-Location '__DIGEST_TEMP_ROOT__'
& '__BRIDGE_SCRIPT__' digest --json
'@
        $childScript = $childScript.Replace('__DIGEST_TEMP_ROOT__', $script:digestTempRoot).Replace('__BRIDGE_SCRIPT__', $bridgeScript)
        $output = & pwsh -NoProfile -Command $childScript

        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result.summary.item_count | Should -Be 1
        $result.items[0].run_id | Should -Be 'task:task-246'
    }

    It 'supports winsmux desktop-summary --json through the top-level CLI entrypoint' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: $script:digestTempRoot
panes:
  builder-1:
    pane_id: %2
    role: Builder
    task_id: task-246
    task: Build evidence digest
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T14:00:00+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        $bridgeScript = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $childScript = @'
Set-Item -Path function:winsmux -Value {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$args)
    $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
    switch -Regex ($commandLine) {
        '^capture-pane .*%2' { @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>'); break }
        default { throw "unexpected winsmux call: $commandLine" }
    }
}
Set-Location '__DIGEST_TEMP_ROOT__'
& '__BRIDGE_SCRIPT__' desktop-summary --json
'@
        $childScript = $childScript.Replace('__DIGEST_TEMP_ROOT__', $script:digestTempRoot).Replace('__BRIDGE_SCRIPT__', $bridgeScript)
        $output = & pwsh -NoProfile -Command $childScript

        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        $result.board.summary.pane_count | Should -Be 1
        $result.digest.summary.item_count | Should -Be 1
        @($result.run_projections).Count | Should -Be 1
        $result.run_projections[0].run_id | Should -Be 'task:task-246'
        $result.run_projections[0].worktree | Should -Be '.worktrees/builder-1'
        $result.run_projections[0].Contains('reasons') | Should -Be $true
        @($result.run_projections[0]['reasons']).Count | Should -Be 0
    }

    It 'converts event records into desktop summary refresh items' {
        $item = ConvertTo-DesktopSummaryRefreshItem -EventRecord ([ordered]@{
                timestamp = '2026-04-10T14:02:00+09:00'
                event     = 'pane.completed'
                pane_id   = '%2'
                branch    = 'worktree-builder-1'
                data      = [ordered]@{
                    task_id = 'task-246'
                }
            })

        $item.source | Should -Be 'summary'
        $item.reason | Should -Be 'pane.completed'
        $item.pane_id | Should -Be '%2'
        $item.run_id | Should -Be 'task:task-246'
    }

    It 'derives desktop summary refresh run ids from branch context when task metadata is absent' {
        $runId = Get-DesktopSummaryRefreshRunId -EventRecord ([ordered]@{
                event   = 'pane.idle'
                pane_id = '%6'
                branch  = 'worktree-builder-1'
            })

        $runId | Should -Be 'branch:worktree-builder-1'
    }

    It 'prefers launch_dir in desktop-summary projections when the builder path lags behind' {
@"
version: 1
session:
  name: winsmux-orchestra
  project_dir: C:\repo
panes:
  builder-1:
    pane_id: %2
    role: Builder
    launch_dir: C:\repo\.worktrees\builder-9
    builder_worktree_path: C:\repo\.worktrees\builder-1
    task_id: task-246
    task: Build evidence digest
    task_state: in_progress
    task_owner: builder-1
    review_state: PENDING
    branch: worktree-builder-1
    head_sha: abc1234def5678
    changed_file_count: 1
    changed_files: '["scripts/winsmux-core.ps1"]'
    last_event: operator.review_requested
    last_event_at: 2026-04-10T14:00:00+09:00
"@ | Set-Content -Path $script:digestManifestPath -Encoding UTF8

        $bridgeScript = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $childScript = @'
Set-Item -Path function:winsmux -Value {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$args)
    $commandLine = ($args | ForEach-Object { [string]$_ }) -join ' '
    switch -Regex ($commandLine) {
        '^capture-pane .*%2' { @('gpt-5.4   64% context left', '? send   Ctrl+J newline', '>'); break }
        default { throw "unexpected winsmux call: $commandLine" }
    }
}
Set-Location '__DIGEST_TEMP_ROOT__'
& '__BRIDGE_SCRIPT__' desktop-summary --json
'@
        $childScript = $childScript.Replace('__DIGEST_TEMP_ROOT__', $script:digestTempRoot).Replace('__BRIDGE_SCRIPT__', $bridgeScript)
        $output = & pwsh -NoProfile -Command $childScript

        $result = ($output | Out-String | ConvertFrom-Json -AsHashtable)

        @($result.run_projections).Count | Should -Be 1
        $result.run_projections[0].worktree | Should -Be '.worktrees/builder-9'
    }
}
