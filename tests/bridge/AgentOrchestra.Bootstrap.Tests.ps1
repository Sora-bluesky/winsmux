$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'TASK659 declarative worktree transaction boundary' -Tag 'task659-application' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-start.ps1')
    }

    It 'rejects all managed worktree collisions before invoking a mutating git command' {
        $projectDir = Join-Path $TestDrive 'task659-collision'
        $worktreeRoot = Join-Path $projectDir '.worktrees'
        New-Item -ItemType Directory -Path $worktreeRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $worktreeRoot 'task-659-implement') -Force | Out-Null
        $application = [ordered]@{
            ManagedWorktrees = [ordered]@{
                implement = [ordered]@{
                    PaneKey = 'implement'
                    Name = 'task-659-implement'
                    PathSuffix = '.worktrees\task-659-implement'
                    BranchName = 'worktree-task-659-implement'
                }
            }
        }
        Mock Invoke-BuilderWorktreeGit {
            if ($Arguments[0] -eq 'worktree' -and $Arguments[1] -eq 'list') {
                return [pscustomobject]@{ ExitCode = 0; Output = ''; Lines = @() }
            }
            if ($Arguments[0] -eq 'branch' -and $Arguments[1] -eq '--list') {
                return [pscustomobject]@{ ExitCode = 0; Output = ''; Lines = @() }
            }
            throw 'mutating git command must not run during preflight'
        }

        { Assert-OrchestraDeclarativeWorktreePreflight -ProjectDir $projectDir -Application $application } |
            Should -Throw '*already exists*'
        Should -Invoke Invoke-BuilderWorktreeGit -Times 0 -Exactly -ParameterFilter {
            $Arguments -contains 'add' -or $Arguments -contains 'remove'
        }
    }

    It 'preserves every declarative worktree after any slot has started' {
        $created = @(
            [ordered]@{
                Declarative = $true
                PaneKey = 'implement'
                BranchName = 'worktree-task-659-implement'
                WorktreePath = 'C:\repo\.worktrees\task-659-implement'
                GitWorktreeDir = 'C:\repo\.git\worktrees\task-659-implement'
                BaseHead = ('a' * 40)
            }
        )
        Mock Invoke-BuilderWorktreeGit { throw 'git cleanup must not run after a slot starts' }

        $result = Remove-OrchestraCreatedWorktrees -ProjectDir 'C:\repo' -CreatedWorktrees $created -PreserveDeclarativeWorktrees

        @($result.RemovedWorktrees).Count | Should -Be 0
        @($result.PreservedWorktrees).Count | Should -Be 1
        $result.PreservedWorktrees[0].Reason | Should -Be 'slot_started'
        Should -Invoke Invoke-BuilderWorktreeGit -Times 0 -Exactly
    }
}

Describe 'orchestra-start server bootstrap' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-start.ps1')
    }

    BeforeEach {
        $script:winsmuxBin = 'winsmux'
        $script:attachStateStore = $null

        Mock Read-OrchestraAttachState {
            $script:attachStateStore
        }

        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)

            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }

            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }

            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
    }

    Context 'TASK-784 attach render truth' {
        BeforeEach {
            Mock Test-OrchestraProcessAlive { $true }
            Mock Get-OrchestraProcessStartedAtUnixMs { 123456 }
        }

        It 'isolates attach state by the effective bridge namespace' {
            $previousNamespace = $env:WINSMUX_BRIDGE_NAMESPACE_L
            $previousSocket = $env:WINSMUX_BRIDGE_SOCKET_S
            $previousResolvedNamespace = $env:WINSMUX_BRIDGE_SESSION_NAMESPACE
            try {
                Remove-Item Env:WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
                Remove-Item Env:WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue

                $env:WINSMUX_BRIDGE_NAMESPACE_L = 'namespace-a'
                $pathA = Get-OrchestraAttachStatePath -SessionName 'winsmux-orchestra' -ProjectDir 'C:\repo'
                $pathARepeat = Get-OrchestraAttachStatePath -SessionName 'winsmux-orchestra' -ProjectDir 'C:\repo'
                $env:WINSMUX_BRIDGE_NAMESPACE_L = 'namespace-b'
                $pathB = Get-OrchestraAttachStatePath -SessionName 'winsmux-orchestra' -ProjectDir 'C:\repo'
                Remove-Item Env:WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
                $defaultPath = Get-OrchestraAttachStatePath -SessionName 'winsmux-orchestra' -ProjectDir 'C:\repo'

                $pathA | Should -Be $pathARepeat
                $pathA | Should -Not -Be $pathB
                [System.IO.Path]::GetFileName($pathA) | Should -Match '^winsmux-orchestra\.[0-9a-f]{16}\.json$'
                [System.IO.Path]::GetFileName($defaultPath) | Should -Be 'winsmux-orchestra.json'
            } finally {
                foreach ($entry in @(
                    @{ Name = 'WINSMUX_BRIDGE_NAMESPACE_L'; Value = $previousNamespace },
                    @{ Name = 'WINSMUX_BRIDGE_SOCKET_S'; Value = $previousSocket },
                    @{ Name = 'WINSMUX_BRIDGE_SESSION_NAMESPACE'; Value = $previousResolvedNamespace }
                )) {
                    if ($null -eq $entry.Value) {
                        Remove-Item ("Env:{0}" -f $entry.Name) -ErrorAction SilentlyContinue
                    } else {
                        Set-Item ("Env:{0}" -f $entry.Name) -Value ([string]$entry.Value)
                    }
                }
            }
        }

        It 'serializes ownership comparison with the state write across processes' {
            $scratchLocalAppData = Join-Path $TestDrive 'local-app-data'
            $stateDir = Join-Path $scratchLocalAppData 'winsmux\ui-attach'
            $statePath = Join-Path $stateDir 'winsmux-orchestra.json'
            $uiAttachScriptPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-ui-attach.ps1'
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            '{"attach_request_id":"request-old","request_id":"request-old"}' | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM

            $mutex = [System.Threading.Mutex]::new($false, (Get-OrchestraAttachStateLockName -StatePath $statePath))
            $job = $null
            $lockAcquired = $false
            try {
                $lockAcquired = $mutex.WaitOne([TimeSpan]::FromSeconds(5))
                $lockAcquired | Should -Be $true
                $job = Start-ThreadJob -ArgumentList $uiAttachScriptPath, $scratchLocalAppData, $TestDrive -ScriptBlock {
                    param($ScriptPath, $LocalAppData, $ProjectDir)
                    $env:LOCALAPPDATA = $LocalAppData
                    Remove-Item Env:WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
                    Remove-Item Env:WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
                    Remove-Item Env:WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue
                    . $ScriptPath
                    Write-OrchestraAttachState -SessionName 'winsmux-orchestra' -ProjectDir $ProjectDir -ExpectedRequestId 'request-old' -Properties @{
                        attach_status = 'stale_writer_won'
                    }
                }

                Start-Sleep -Milliseconds 250
                $job.State | Should -Be 'Running'
                '{"attach_request_id":"request-new-owner","request_id":"request-new-owner","attach_status":"attach_requested"}' |
                    Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
            } finally {
                if ($lockAcquired) {
                    $mutex.ReleaseMutex()
                }
                $mutex.Dispose()
            }

            try {
                Wait-Job -Job $job -Timeout 15 | Should -Not -BeNullOrEmpty
                $result = Receive-Job -Job $job
                [string]$result.attach_request_id | Should -Be 'request-new-owner'
                $finalState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                $finalState.attach_request_id | Should -Be 'request-new-owner'
                $finalState.attach_status | Should -Be 'attach_requested'
            } finally {
                if ($null -ne $job) {
                    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'fails closed when the winsmux executable is unavailable' {
            $state = [pscustomobject]@{
                session_name        = 'winsmux-orchestra'
                attach_status       = 'attach_confirmed'
                attach_request_id   = 'request-784'
                render_receipt_path = 'C:\temp\request-784.render.json'
            }

            Test-OrchestraLiveVisibleAttachState -State $state -SessionName 'winsmux-orchestra' -WinsmuxBin '' |
                Should -Be $false
        }

        It 'rejects client registration without a render receipt' {
            $result = Test-OrchestraRenderReceipt `
                -Receipt $null `
                -SessionName 'winsmux-orchestra' `
                -RequestId 'request-784' `
                -LivePaneIds @('%1', '%2')

            $result.Confirmed | Should -Be $false
            $result.Reason | Should -Be 'render_receipt_missing'
        }

        It 'rejects stale nonce and dead renderer receipts' {
            $receipt = [pscustomobject]@{
                version             = 1
                request_id          = 'stale-request'
                session_name        = 'winsmux-orchestra'
                renderer_process_id = 4242
                renderer_process_started_at_unix_ms = 123456
                rendered_at_unix_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                pane_ids            = @('%1', '%2')
            }

            $stale = Test-OrchestraRenderReceipt -Receipt $receipt -SessionName 'winsmux-orchestra' -RequestId 'request-784' -LivePaneIds @('%1', '%2')
            $stale.Confirmed | Should -Be $false
            $stale.Reason | Should -Be 'render_receipt_request_mismatch'

            $receipt.request_id = 'request-784'
            Mock Test-OrchestraProcessAlive { $false }
            $dead = Test-OrchestraRenderReceipt -Receipt $receipt -SessionName 'winsmux-orchestra' -RequestId 'request-784' -LivePaneIds @('%1', '%2')
            $dead.Confirmed | Should -Be $false
            $dead.Reason | Should -Be 'render_receipt_renderer_not_live'
        }

        It 'rejects pane-set mismatch and accepts an exact rendered set' {
            $receipt = [pscustomobject]@{
                version             = 1
                request_id          = 'request-784'
                session_name        = 'winsmux-orchestra'
                renderer_process_id = 4242
                renderer_process_started_at_unix_ms = 123456
                rendered_at_unix_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                pane_ids            = @('%1')
            }

            $mismatch = Test-OrchestraRenderReceipt -Receipt $receipt -SessionName 'winsmux-orchestra' -RequestId 'request-784' -LivePaneIds @('%1', '%2')
            $mismatch.Confirmed | Should -Be $false
            $mismatch.Reason | Should -Be 'render_receipt_pane_set_mismatch'

            $receipt.pane_ids = @('%2', '%1')
            $exact = Test-OrchestraRenderReceipt -Receipt $receipt -SessionName 'winsmux-orchestra' -RequestId 'request-784' -LivePaneIds @('%1', '%2')
            $exact.Confirmed | Should -Be $true
            $exact.Reason | Should -Be 'render_receipt_confirmed'
            $exact.RendererProcessId | Should -Be 4242
            $exact.RenderedPaneIds | Should -Be @('%1', '%2')
        }

        It 'rejects malformed, wrong-session, and pre-request receipts' {
            $receipt = [pscustomobject]@{
                version             = 'invalid'
                request_id          = 'request-784'
                session_name        = 'winsmux-orchestra'
                renderer_process_id = 4242
                renderer_process_started_at_unix_ms = 123456
                rendered_at_unix_ms = 2000
                pane_ids            = @('%1')
            }

            (Test-OrchestraRenderReceipt -Receipt $receipt -SessionName 'winsmux-orchestra' -RequestId 'request-784' -LivePaneIds @('%1')).Reason |
                Should -Be 'render_receipt_version_unsupported'

            $receipt.version = 1
            $receipt.session_name = 'other-session'
            (Test-OrchestraRenderReceipt -Receipt $receipt -SessionName 'winsmux-orchestra' -RequestId 'request-784' -LivePaneIds @('%1')).Reason |
                Should -Be 'render_receipt_session_mismatch'

            $receipt.session_name = 'winsmux-orchestra'
            (Test-OrchestraRenderReceipt -Receipt $receipt -SessionName 'winsmux-orchestra' -RequestId 'request-784' -LivePaneIds @('%1') -RequestedAtUnixMs 2001).Reason |
                Should -Be 'render_receipt_not_fresh'
        }

        It 'rejects duplicate and superset pane identities' {
            $receipt = [pscustomobject]@{
                version             = 1
                request_id          = 'request-784'
                session_name        = 'winsmux-orchestra'
                renderer_process_id = 4242
                renderer_process_started_at_unix_ms = 123456
                rendered_at_unix_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                pane_ids            = @('%1', '%1')
            }

            (Test-OrchestraRenderReceipt -Receipt $receipt -SessionName 'winsmux-orchestra' -RequestId 'request-784' -LivePaneIds @('%1')).Reason |
                Should -Be 'render_receipt_pane_set_mismatch'

            $receipt.pane_ids = @('%1', '%2')
            (Test-OrchestraRenderReceipt -Receipt $receipt -SessionName 'winsmux-orchestra' -RequestId 'request-784' -LivePaneIds @('%1')).Reason |
                Should -Be 'render_receipt_pane_set_mismatch'
        }

        It 'rejects a reused renderer PID with a different process start time' {
            $receipt = [pscustomobject]@{
                version                              = 1
                request_id                           = 'request-784'
                session_name                         = 'winsmux-orchestra'
                renderer_process_id                  = 4242
                renderer_process_started_at_unix_ms  = 123456
                rendered_at_unix_ms                  = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                pane_ids                             = @('%1')
            }
            Mock Get-OrchestraProcessStartedAtUnixMs { 654321 }

            $result = Test-OrchestraRenderReceipt -Receipt $receipt -SessionName 'winsmux-orchestra' -RequestId 'request-784' -LivePaneIds @('%1')

            $result.Confirmed | Should -Be $false
            $result.Reason | Should -Be 'render_receipt_renderer_instance_mismatch'
        }

        It 'requires a refreshed receipt after the session pane topology changes' {
            $script:receiptPaneIds = @('%1')
            $state = [pscustomobject]@{
                session_name        = 'winsmux-orchestra'
                render_session_identity = 'winsmux-orchestra'
                attach_status       = 'attach_confirmed'
                attach_request_id   = 'request-784'
                requested_at        = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
                render_receipt_path = 'C:\temp\request-784.render.json'
                project_dir         = 'C:\repo'
            }
            Mock Get-OrchestraLivePaneSnapshot {
                [pscustomobject]@{ Ok = $true; Count = 2; Error = ''; PaneIds = @('%1', '%2') }
            }
            Mock Read-OrchestraRenderReceipt {
                [pscustomobject]@{
                    version                              = 1
                    request_id                           = 'request-784'
                    session_name                         = 'winsmux-orchestra'
                    renderer_process_id                  = 4242
                    renderer_process_started_at_unix_ms  = 123456
                    rendered_at_unix_ms                  = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    pane_ids                             = @($script:receiptPaneIds)
                }
            }

            Test-OrchestraLiveVisibleAttachState -State $state -SessionName 'winsmux-orchestra' -WinsmuxBin 'C:\winsmux\winsmux.exe' |
                Should -Be $false

            $script:receiptPaneIds = @('%1', '%2')
            Test-OrchestraLiveVisibleAttachState -State $state -SessionName 'winsmux-orchestra' -WinsmuxBin 'C:\winsmux\winsmux.exe' |
                Should -Be $true
        }

        It 'rejects a receipt from a different namespace with identical pane ids' {
            $previousNamespace = $env:WINSMUX_BRIDGE_NAMESPACE_L
            $previousSocket = $env:WINSMUX_BRIDGE_SOCKET_S
            $previousResolvedNamespace = $env:WINSMUX_BRIDGE_SESSION_NAMESPACE
            try {
                $env:WINSMUX_BRIDGE_NAMESPACE_L = 'requested'
                Remove-Item Env:WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
                Remove-Item Env:WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue
                $state = [pscustomobject]@{
                    session_name            = 'winsmux-orchestra'
                    render_session_identity = 'other__winsmux-orchestra'
                    attach_status           = 'attach_confirmed'
                    attach_request_id       = 'request-784'
                    requested_at            = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
                    render_receipt_path     = 'C:\temp\request-784.render.json'
                    project_dir             = 'C:\repo'
                }
                Mock Get-OrchestraLivePaneSnapshot {
                    [pscustomobject]@{ Ok = $true; Count = 1; Error = ''; PaneIds = @('%1') }
                }
                Mock Read-OrchestraRenderReceipt {
                    [pscustomobject]@{
                        version                              = 1
                        request_id                           = 'request-784'
                        session_name                         = 'other__winsmux-orchestra'
                        renderer_process_id                  = 4242
                        renderer_process_started_at_unix_ms  = 123456
                        rendered_at_unix_ms                  = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                        pane_ids                             = @('%1')
                    }
                }

                Test-OrchestraLiveVisibleAttachState -State $state -SessionName 'winsmux-orchestra' -WinsmuxBin 'C:\winsmux\winsmux.exe' |
                    Should -Be $false
            } finally {
                if ($null -eq $previousNamespace) {
                    Remove-Item Env:WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
                } else {
                    $env:WINSMUX_BRIDGE_NAMESPACE_L = $previousNamespace
                }
                if ($null -eq $previousSocket) {
                    Remove-Item Env:WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
                } else {
                    $env:WINSMUX_BRIDGE_SOCKET_S = $previousSocket
                }
                if ($null -eq $previousResolvedNamespace) {
                    Remove-Item Env:WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue
                } else {
                    $env:WINSMUX_BRIDGE_SESSION_NAMESPACE = $previousResolvedNamespace
                }
            }
        }

        It 'rejects an expired render lease even when process and panes still match' {
            $receipt = [pscustomobject]@{
                version                              = 1
                request_id                           = 'request-784'
                session_name                         = 'winsmux-orchestra'
                renderer_process_id                  = 4242
                renderer_process_started_at_unix_ms  = 123456
                rendered_at_unix_ms                  = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeMilliseconds()
                pane_ids                             = @('%1')
            }

            $result = Test-OrchestraRenderReceipt -Receipt $receipt -SessionName 'winsmux-orchestra' -RequestId 'request-784' -LivePaneIds @('%1')

            $result.Confirmed | Should -Be $false
            $result.Reason | Should -Be 'render_receipt_expired'
        }

        It 'does not treat client registration as launch observation' {
            Mock Read-OrchestraAttachState { $null }
            Mock Get-OrchestraAttachedClientSnapshot {
                [pscustomobject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-1') }
            }
            Mock Start-Sleep {}

            $result = Wait-OrchestraAttachLaunchObservation `
                -SessionName 'winsmux-orchestra' `
                -WinsmuxBin 'C:\winsmux\winsmux.exe' `
                -BaselineClientCount 0 `
                -TimeoutMilliseconds 1 `
                -PollMilliseconds 1

            $result.Observed | Should -Be $false
        }

        It 'derives the exact render identity from L and S namespace selectors' {
            $previousNamespace = $env:WINSMUX_BRIDGE_NAMESPACE_L
            $previousSocket = $env:WINSMUX_BRIDGE_SOCKET_S
            $previousResolvedNamespace = $env:WINSMUX_BRIDGE_SESSION_NAMESPACE
            try {
                Remove-Item Env:WINSMUX_BRIDGE_SOCKET_S -ErrorAction SilentlyContinue
                Remove-Item Env:WINSMUX_BRIDGE_SESSION_NAMESPACE -ErrorAction SilentlyContinue
                $env:WINSMUX_BRIDGE_NAMESPACE_L = 'requested'
                Get-OrchestraRenderSessionIdentity -SessionName 'winsmux-orchestra' -ProjectDir 'C:\repo' |
                    Should -Be 'requested__winsmux-orchestra'

                Remove-Item Env:WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
                $env:WINSMUX_BRIDGE_SOCKET_S = 'socket-name'
                Get-OrchestraRenderSessionIdentity -SessionName 'winsmux-orchestra' -ProjectDir 'C:\repo' |
                    Should -Be 'socket-name__winsmux-orchestra'
            } finally {
                foreach ($entry in @(
                    @{ Name = 'WINSMUX_BRIDGE_NAMESPACE_L'; Value = $previousNamespace },
                    @{ Name = 'WINSMUX_BRIDGE_SOCKET_S'; Value = $previousSocket },
                    @{ Name = 'WINSMUX_BRIDGE_SESSION_NAMESPACE'; Value = $previousResolvedNamespace }
                )) {
                    if ($null -eq $entry.Value) {
                        Remove-Item ("Env:{0}" -f $entry.Name) -ErrorAction SilentlyContinue
                    } else {
                        Set-Item ("Env:{0}" -f $entry.Name) -Value ([string]$entry.Value)
                    }
                }
            }
        }

        It 'passes render metadata and clears inherited mux markers before attach-session' {
            $entryPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-attach-entry.ps1'
            $entryContent = Get-Content -LiteralPath $entryPath -Raw -Encoding UTF8
            $uiAttachPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\orchestra-ui-attach.ps1'
            $uiAttachContent = Get-Content -LiteralPath $uiAttachPath -Raw -Encoding UTF8

            $entryContent | Should -Match '\$launchRequestId\s*=\s*\[string\]\$env:WINSMUX_ATTACH_REQUEST_ID'
            $entryContent | Should -Match 'Get-OrchestraAttachRequestId -State \$state\) -ne \$launchRequestId'
            $entryContent | Should -Match '\$env:WINSMUX_RENDER_RECEIPT_PATH\s*=\s*\$renderReceiptPath'
            $entryContent | Should -Match '\$env:WINSMUX_RENDER_REQUEST_ID\s*=\s*\$attachRequestId'
            $entryContent | Should -Match '\$env:WINSMUX_RENDER_SESSION_NAME\s*=\s*\$renderSessionIdentity'
            $entryContent | Should -Match 'Name = ''WINSMUX_BRIDGE_NAMESPACE_L''; Value = \$bridgeNamespaceL'
            $entryContent | Should -Match 'Name = ''WINSMUX_BRIDGE_SOCKET_S''; Value = \$bridgeSocketS'
            $entryContent | Should -Match '''-ProjectDir'', \$projectDir'
            $entryContent | Should -Match '''-RequestId'', \$launchRequestId'
            $entryContent | Should -Match 'Remove-Item Env:PSMUX_ACTIVE'
            $entryContent | Should -Match 'Remove-Item Env:PSMUX_SESSION'
            $entryContent | Should -Match 'Invoke-WinsmuxBridgeCommand.+@\(''attach-session'', ''-t'', \$sessionName\)'
            $uiAttachContent | Should -Match '\$env:WINSMUX_ATTACH_REQUEST_ID\s*=\s*\$attachRequestId'
            $uiAttachContent | Should -Match 'Wait-OrchestraAttachHandshake.+-ExpectedRequestId \$attachRequestId'
        }

        It 'promotes pending state only from a current exact render receipt' {
            $script:attachStateStore = [pscustomobject]@{
                session_name        = 'winsmux-orchestra'
                attach_status       = 'attach_confirming'
                attach_request_id   = 'request-784'
                requested_at        = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
                render_receipt_path = 'C:\temp\request-784.render.json'
                render_session_identity = Get-OrchestraRenderSessionIdentity -SessionName 'winsmux-orchestra' -ProjectDir 'C:\repo'
            }
            Mock Read-OrchestraRenderReceipt {
                [pscustomobject]@{
                    version             = 1
                    request_id          = 'request-784'
                    session_name        = 'winsmux-orchestra'
                    renderer_process_id = 4242
                    renderer_process_started_at_unix_ms = 123456
                    rendered_at_unix_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    pane_ids            = @('%2', '%1')
                }
            }
            Mock Get-OrchestraLivePaneSnapshot {
                [pscustomobject]@{ Ok = $true; Count = 2; Error = ''; PaneIds = @('%1', '%2') }
            }
            Mock Get-OrchestraAttachedClientSnapshot {
                [pscustomobject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-1') }
            }

            $result = Wait-OrchestraAttachHandshake -SessionName 'winsmux-orchestra' -WinsmuxBin 'C:\winsmux\winsmux.exe' -BaselineClientCount 0 -ProjectDir 'C:\repo' -TimeoutMilliseconds 100 -PollMilliseconds 1

            $result.Confirmed | Should -Be $true
            $result.Source | Should -Be 'render-receipt'
            $result.State.renderer_process_id | Should -Be 4242
            $result.State.rendered_pane_ids | Should -Be @('%1', '%2')
        }

        It 'rejects a handshake state written by another namespace' {
            $previousNamespace = $env:WINSMUX_BRIDGE_NAMESPACE_L
            try {
                $env:WINSMUX_BRIDGE_NAMESPACE_L = 'namespace-a'
                $script:attachStateStore = [pscustomobject]@{
                    session_name            = 'winsmux-orchestra'
                    attach_status           = 'attach_confirming'
                    attach_request_id       = 'request-b'
                    requested_at            = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
                    render_receipt_path     = 'C:\temp\request-b.render.json'
                    render_session_identity = 'namespace-b__winsmux-orchestra'
                }
                Mock Read-OrchestraRenderReceipt {
                    [pscustomobject]@{
                        version             = 1
                        request_id          = 'request-b'
                        session_name        = 'namespace-b__winsmux-orchestra'
                        renderer_process_id = 4242
                        renderer_process_started_at_unix_ms = 123456
                        rendered_at_unix_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                        pane_ids            = @('%1', '%2')
                    }
                }
                Mock Get-OrchestraLivePaneSnapshot {
                    [pscustomobject]@{ Ok = $true; Count = 2; Error = ''; PaneIds = @('%1', '%2') }
                }
                Mock Get-OrchestraAttachedClientSnapshot {
                    [pscustomobject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-a') }
                }

                $result = Wait-OrchestraAttachHandshake -SessionName 'winsmux-orchestra' -WinsmuxBin 'C:\winsmux\winsmux.exe' -BaselineClientCount 0 -ProjectDir 'C:\repo-a' -TimeoutMilliseconds 5 -PollMilliseconds 1

                $result.Confirmed | Should -Be $false
                $result.Reason | Should -Match 'render_receipt_session_mismatch'
            } finally {
                if ($null -eq $previousNamespace) {
                    Remove-Item Env:WINSMUX_BRIDGE_NAMESPACE_L -ErrorAction SilentlyContinue
                } else {
                    $env:WINSMUX_BRIDGE_NAMESPACE_L = $previousNamespace
                }
            }
        }

        It 'rejects a superseded launch request before reading its receipt' {
            $script:attachStateStore = [pscustomobject]@{
                session_name      = 'winsmux-orchestra'
                attach_status     = 'attach_requested'
                attach_request_id = 'request-new'
            }

            $result = Wait-OrchestraAttachHandshake -SessionName 'winsmux-orchestra' -WinsmuxBin 'C:\winsmux\winsmux.exe' -BaselineClientCount 0 -ProjectDir 'C:\repo' -ExpectedRequestId 'request-old' -TimeoutMilliseconds 5 -PollMilliseconds 1

            $result.Confirmed | Should -Be $false
            $result.Status | Should -Be 'attach_superseded'
            $result.Reason | Should -Match "request-old.+request-new"
            Should -Invoke Write-OrchestraAttachState -Times 0 -Exactly
        }

        It 'does not confirm a live desktop host without the same render receipt contract' {
            $previousMode = $env:WINSMUX_ORCHESTRA_ATTACH_MODE
            $previousPid = $env:WINSMUX_DESKTOP_APP_PID
            try {
                $env:WINSMUX_ORCHESTRA_ATTACH_MODE = 'desktop-app'
                $env:WINSMUX_DESKTOP_APP_PID = '4242'

                $result = Invoke-OrchestraVisibleAttachRequest -SessionName 'winsmux-orchestra' -ProjectDir 'C:\repo' -WinsmuxPathForAttach 'C:\winsmux\winsmux.exe'

                $result.Attached | Should -Be $false
                $result.Status | Should -Be 'attach_failed'
                $result.Reason | Should -Match 'post-draw render receipt'
            } finally {
                if ($null -eq $previousMode) { Remove-Item Env:WINSMUX_ORCHESTRA_ATTACH_MODE -ErrorAction SilentlyContinue } else { $env:WINSMUX_ORCHESTRA_ATTACH_MODE = $previousMode }
                if ($null -eq $previousPid) { Remove-Item Env:WINSMUX_DESKTOP_APP_PID -ErrorAction SilentlyContinue } else { $env:WINSMUX_DESKTOP_APP_PID = $previousPid }
            }
        }

        It 'keeps receipt paths request-specific and writes only after terminal draw returns' {
            $firstPath = Get-OrchestraRenderReceiptPath -SessionName 'winsmux-orchestra' -RequestId 'request-one'
            $secondPath = Get-OrchestraRenderReceiptPath -SessionName 'winsmux-orchestra' -RequestId 'request-two'
            $firstPath | Should -Not -Be $secondPath

            $clientPath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'core\src\client.rs'
            $clientContent = Get-Content -LiteralPath $clientPath -Raw -Encoding UTF8
            $drawIndex = $clientContent.IndexOf('terminal.draw(|f|')
            $receiptIndex = $clientContent.IndexOf('write_render_receipt(config, &pane_ids)', $drawIndex)
            $drawIndex | Should -BeGreaterThan -1
            $receiptIndex | Should -BeGreaterThan $drawIndex
        }
    }

    It 'redacts credentials from expected origin metadata' {
        ConvertTo-SafeGitRemoteUrl -RemoteUrl 'https://token@example.com/org/repo.git' |
            Should -Be 'https://example.com/org/repo.git'
        ConvertTo-SafeGitRemoteUrl -RemoteUrl 'ssh://user:secret@example.com/org/repo.git' |
            Should -Be 'ssh://example.com/org/repo.git'
        ConvertTo-SafeGitRemoteUrl -RemoteUrl 'git@example.com:org/repo.git' |
            Should -Be 'git@example.com:org/repo.git'
    }

    It 'allocates the next free builder worktree slot when the first slot is locked' {
        $testProjectDir = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-builder-slot-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testProjectDir -Force | Out-Null
        $lockedWorktreePath = Join-Path $testProjectDir '.worktrees\builder-1'
        New-Item -ItemType Directory -Path $lockedWorktreePath -Force | Out-Null
        $script:builderWorktreeGitCalls = [System.Collections.Generic.List[object]]::new()
        $originalGitFunction = Get-Item -Path Function:\git -ErrorAction SilentlyContinue

        function global:git {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)

            $script:builderWorktreeGitCalls.Add(@($Args)) | Out-Null
            if ($Args[2] -eq 'branch' -and $Args[3] -eq '--list') {
                $global:LASTEXITCODE = 0
                return ''
            }

            if ($Args[2] -eq 'worktree' -and $Args[3] -eq 'add') {
                $global:LASTEXITCODE = 0
                return ''
            }

            $global:LASTEXITCODE = 0
        }

        try {
            $worktree = New-BuilderWorktree -ProjectDir $testProjectDir -BuilderIndex 1

            $worktree.BranchName | Should -Be 'worktree-builder-2'
            $worktree.WorktreePath | Should -Be (Join-Path $testProjectDir '.worktrees\builder-2')
            @($script:builderWorktreeGitCalls | Where-Object { $_[2] -eq 'worktree' -and $_[3] -eq 'add' -and $_[4] -eq '.worktrees/builder-2' -and $_[6] -eq 'worktree-builder-2' }).Count | Should -Be 1
        } finally {
            Remove-Item -Path Function:\git -ErrorAction SilentlyContinue
            if ($null -ne $originalGitFunction) {
                Set-Item -Path Function:\git -Value $originalGitFunction.ScriptBlock
            }
            if (Test-Path -LiteralPath $testProjectDir) {
                Remove-Item -LiteralPath $testProjectDir -Recurse -Force
            }
        }
    }

    It 'keeps stale builder cleanup non-fatal when a registered worktree is locked' {
        $testProjectDir = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-builder-cleanup-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testProjectDir -Force | Out-Null
        $lockedWorktreePath = Join-Path $testProjectDir '.worktrees\builder-1'
        New-Item -ItemType Directory -Path $lockedWorktreePath -Force | Out-Null
        $originalGitFunction = Get-Item -Path Function:\git -ErrorAction SilentlyContinue

        function global:git {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)

            if ($Args[2] -eq 'worktree' -and $Args[3] -eq 'prune') {
                $global:LASTEXITCODE = 0
                return ''
            }

            if ($Args[2] -eq 'worktree' -and $Args[3] -eq 'list') {
                $global:LASTEXITCODE = 0
                return @(
                    "worktree $testProjectDir",
                    'branch refs/heads/main',
                    '',
                    "worktree $lockedWorktreePath",
                    'branch refs/heads/worktree-builder-1',
                    ''
                )
            }

            if ($Args[2] -eq 'branch' -and $Args[3] -eq '--list') {
                $global:LASTEXITCODE = 0
                return 'worktree-builder-1'
            }

            if ($Args[2] -eq 'worktree' -and $Args[3] -eq 'remove') {
                $global:LASTEXITCODE = 1
                return 'permission denied'
            }

            if ($Args[2] -eq 'branch' -and $Args[3] -eq '-D') {
                $global:LASTEXITCODE = 1
                return 'branch is checked out'
            }

            $global:LASTEXITCODE = 0
        }

        Mock Get-CimInstance {
            @(
                [PSCustomObject]@{
                    ProcessId   = 12345
                    Name        = 'pwsh.exe'
                    CommandLine = "pwsh -NoProfile -File worker.ps1 -ProjectDir `"$lockedWorktreePath`""
                }
            )
        }

        try {
            $cleanup = Invoke-StaleBuilderWorktreeCleanup -ProjectDir $testProjectDir

            @($cleanup.RemovedWorktreePaths).Count | Should -Be 0
            @($cleanup.CleanupErrors | Where-Object { $_ -like "worktree remove $lockedWorktreePath failed:*" }).Count | Should -Be 1
            @($cleanup.CleanupErrors | Where-Object { $_ -like '*owner candidates: pid=12345 name=pwsh.exe reason=command_line_matches_worktree*' }).Count | Should -Be 1
            @($cleanup.CleanupErrors | Where-Object { $_ -like 'branch delete worktree-builder-1 failed:*' }).Count | Should -Be 1
            (Test-Path -LiteralPath $lockedWorktreePath) | Should -Be $true
        } finally {
            Remove-Item -Path Function:\git -ErrorAction SilentlyContinue
            if ($null -ne $originalGitFunction) {
                Set-Item -Path Function:\git -Value $originalGitFunction.ScriptBlock
            }
            if (Test-Path -LiteralPath $testProjectDir) {
                Remove-Item -LiteralPath $testProjectDir -Recurse -Force
            }
        }
    }

    It 'preserves the selectorless manifest pane shape' -Tag 'task659-application' {
        $script:savedManifest = $null
        Mock Save-WinsmuxManifest {
            param([string]$ProjectDir, $Manifest)
            $script:savedManifest = $Manifest
        }

        Save-OrchestraSessionState `
            -ProjectDir 'C:\repo' `
            -SessionName 'winsmux-orchestra' `
            -Settings ([ordered]@{ agent = 'codex'; model = 'gpt-5.4' }) `
            -GitWorktreeDir 'C:\repo\.git\worktrees' `
            -PaneSummaries @([ordered]@{
                Label                  = 'worker-1'
                PaneId                 = '%2'
                SlotId                 = 'worker-1'
                PaneKey               = 'ignored-without-declarative-workspace'
                WorkflowRole          = 'ignored-without-declarative-workspace'
                Role                   = 'Worker'
                ExecMode               = $false
                ProjectDir             = 'C:\repo'
                LaunchDir              = 'C:\repo\.worktrees\worker-1'
                BuilderBranch          = 'worktree-worker-1'
                BuilderWorktreePath    = 'C:\repo\.worktrees\worker-1'
                WorktreeGitDir         = 'C:\repo\.git\worktrees\worker-1'
                ExpectedOrigin         = 'https://github.com/example/repo.git'
                Status                 = 'ready'
                CapabilityAdapter      = 'codex'
                CapabilityCommand      = 'codex'
                SupportsParallelRuns   = $true
                SupportsInterrupt      = $true
                SupportsStructuredResult = $true
                SupportsFileEdit       = $true
                SupportsSubagents      = $true
                SupportsVerification   = $true
                SupportsConsultation   = $true
            }) `
            -ExpectedPaneCount 1 | Out-Null

        $script:savedManifest | Should -Not -BeNullOrEmpty
        $script:savedManifest.session.expected_pane_count | Should -Be 1
        $pane = $script:savedManifest.panes.'worker-1'
        $pane.slot_id | Should -Be 'worker-1'
        $pane.project_dir | Should -Be 'C:\repo'
        $pane.worktree_git_dir | Should -Be 'C:\repo\.git\worktrees\worker-1'
        $pane.expected_origin | Should -Be 'https://github.com/example/repo.git'
        $pane.supports_context_reset | Should -Be $false
        $pane.PSObject.Properties.Name | Should -Not -Contain 'pane_key'
        $pane.PSObject.Properties.Name | Should -Not -Contain 'workflow_role'
    }

    It 'persists background process registry entries with owner lease and recovery policy' {
        $script:savedManifest = $null
        Mock Save-WinsmuxManifest {
            param([string]$ProjectDir, $Manifest)
            $script:savedManifest = $Manifest
        }

        Save-OrchestraSessionState `
            -ProjectDir 'C:\repo' `
            -SessionName 'winsmux-orchestra' `
            -Settings ([ordered]@{ agent = 'codex'; model = 'gpt-5.4' }) `
            -GitWorktreeDir 'C:\repo\.git\worktrees' `
            -PaneSummaries @() `
            -ExpectedPaneCount 1 `
            -StartupToken 'token-123' `
            -SupervisorPid 707 `
            -IdleThreshold 180 `
            -MaxRestartAttempts 4 `
            -RestartWindowMinutes 12 | Out-Null

        $registry = $script:savedManifest.session.process_registry
        $registry.version | Should -Be 1
        @($registry.entries).Count | Should -Be 1
        $entry = @($registry.entries)[0]
        $entry.label | Should -Be 'supervisor_pid'
        $entry.pid | Should -Be 707
        $entry.owner | Should -Be 'orchestra-start'
        $entry.lease.token | Should -Be 'token-123'
        $entry.lease.session_name | Should -Be 'winsmux-orchestra'
        $entry.lease.manifest_path | Should -Be 'C:\repo\.winsmux\manifest.yaml'
        $entry.idle.timeout_seconds | Should -Be 0
        $entry.crash_recovery.policy | Should -Be 'fail_closed'
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

        $result = Ensure-OrchestraBootstrapSession -SessionName 'winsmux-orchestra'

        $result.SessionName | Should -Be 'winsmux-orchestra'
        $result.BootstrapReady | Should -Be $false
        $result.StartupReady | Should -Be $false
        $script:probeCount | Should -Be 1
        $script:newSessionCallCount | Should -Be 0
    }

    It 'creates a detached bootstrap session and waits for a single pane when the session is missing' {
        $script:newSessionCalls = @()
        $script:paneCountCallCount = 0
        $script:probeCount = 0

        function Test-OrchestraServerSession {
            param([string]$SessionName)
            $script:probeCount++
            return ($script:probeCount -ge 2)
        }

        function Invoke-Winsmux {
            param([string[]]$Arguments, [switch]$CaptureOutput)
            $script:newSessionCalls += ,@($Arguments)
            if ($CaptureOutput) { return @() }
        }

        function Get-OrchestraSessionPaneCount {
            param([string]$SessionName, [string]$WinsmuxBin)
            $script:paneCountCallCount++
            return 1
        }

        function Start-Sleep {
            param([int]$Milliseconds)
        }

        $result = Ensure-OrchestraBootstrapSession -SessionName 'winsmux-orchestra'

        $result.SessionName | Should -Be 'winsmux-orchestra'
        $result.BootstrapReady | Should -Be $true
        $result.StartupReady | Should -Be $false
        $result.BootstrapMode | Should -Be 'detached_primary'
        $result.UiAttachStatus | Should -Be 'not_requested'
        @($script:newSessionCalls | Where-Object { $_[0] -eq 'new-session' -and $_[1] -eq '-d' -and $_[2] -eq '-s' -and $_[3] -eq 'winsmux-orchestra' }).Count | Should -Be 1
        $script:paneCountCallCount | Should -Be 1
        $script:probeCount | Should -Be 2
    }

    It 'launches visible attach through Windows Terminal without relying on profile reload timing' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 0; Error = ''; Clients = @() }
        }
        Mock Get-OrchestraWindowsTerminalInfo {
            [PSCustomObject][ordered]@{
                Available   = $true
                Path        = 'C:\Windows\System32\wt.exe'
                AliasPath   = ''
                IsAliasStub = $false
                PathSource  = 'command'
                Reason      = 'ready'
            }
        }
        Mock Ensure-OrchestraAttachProfile {
            [PSCustomObject][ordered]@{
                ProfileName  = 'winsmux orchestra attach'
                FragmentPath = 'C:\Users\Example\AppData\Local\Microsoft\Windows Terminal\Fragments\winsmux\winsmux-orchestra-attach.json'
                Commandline  = '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoExit -File "C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1"'
            }
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Wait-OrchestraAttachLaunchObservation {
            [PSCustomObject]@{ Observed = $true; Reason = 'launch observed' }
        }
        Mock Get-OrchestraAttachEntryArgumentList { @('-NoLogo', '-NoExit', '-File', 'C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1') }
        Mock Wait-OrchestraAttachHandshake {
            param([string]$ExpectedRequestId)
            [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'render-receipt'
                Status              = 'attach_confirmed'
                Reason              = 'Attach confirmed'
                AttachedClientCount = 1
                State               = [pscustomobject]@{
                    attach_request_id      = $ExpectedRequestId
                    attached_client_snapshot = @('client-1')
                    ui_host_kind           = 'windows-terminal'
                }
            }
        }

        function Start-Process {
            param(
                [string]$FilePath,
                [object[]]$ArgumentList,
                [switch]$PassThru
            )

            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $true }
        }

        function Start-Sleep {
            param([int]$Milliseconds)
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $true
        $result.Launched | Should -Be $true
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_confirmed'
        $result.Source | Should -Be 'render-receipt'
        $result.attach_request_id | Should -Match '^[0-9a-f]{32}$'
        $result.attached_client_snapshot | Should -Be @('client-1')
        $result.ui_host_kind | Should -Be 'windows-terminal'
        $result.attach_adapter_trace.Count | Should -Be 1
        $result.attach_adapter_trace[0].host_kind | Should -Be 'windows-terminal'
        $result.attach_adapter_trace[0].launch_result | Should -Be 'attach_confirmed'
        $script:startProcessCalls.Count | Should -Be 1
        $script:startProcessCalls[0].FilePath | Should -Be 'C:\Windows\System32\wt.exe'
        $script:startProcessCalls[0].ArgumentList | Should -Contain 'new-window'
        $script:startProcessCalls[0].ArgumentList | Should -Not -Contain '-p'
        $script:startProcessCalls[0].ArgumentList | Should -Contain '--title'
        $script:startProcessCalls[0].ArgumentList | Should -Contain 'winsmux-orchestra'
        $script:startProcessCalls[0].ArgumentList | Should -Contain '--'
        $script:startProcessCalls[0].ArgumentList | Should -Contain 'pwsh.exe'
        $script:startProcessCalls[0].ArgumentList | Should -Contain '-File'
        $script:startProcessCalls[0].ArgumentList | Should -Contain 'C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1'
    }

    It 'skips Appx-resolved Windows Terminal direct launch and uses PowerShell attach' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 0; Error = ''; Clients = @() }
        }
        Mock Read-OrchestraAttachState { $script:attachStateStore }
        Mock Test-OrchestraLiveVisibleAttachState { $false }
        Mock Get-OrchestraWindowsTerminalInfo {
            [PSCustomObject][ordered]@{
                Available   = $true
                Path        = 'C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_1.24.10921.0_x64__8wekyb3d8bbwe\wt.exe'
                AliasPath   = 'C:\Users\Example\AppData\Local\Microsoft\WindowsApps\wt.exe'
                IsAliasStub = $true
                PathSource  = 'appx'
                Reason      = 'resolved_from_appx'
            }
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Get-OrchestraPowerShellPath { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Get-OrchestraAttachEntryArgumentList { @('-NoLogo', '-NoExit', '-File', 'C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1') }
        Mock Wait-OrchestraAttachHandshake {
            param([string]$ExpectedRequestId)
            [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'handshake'
                Status              = 'attach_confirmed'
                Reason              = 'Attach confirmed via PowerShell'
                AttachedClientCount = 1
                State               = [pscustomobject]@{ attach_request_id = $ExpectedRequestId }
            }
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $false }
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $true
        $result.Launched | Should -Be $true
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_confirmed'
        $result.Path | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        $result.attach_adapter_trace.Count | Should -Be 2
        $result.attach_adapter_trace[0].host_kind | Should -Be 'windows-terminal'
        $result.attach_adapter_trace[0].available | Should -Be $false
        $result.attach_adapter_trace[0].availability_reason | Should -Be 'wt_appx_direct_launch_unsupported'
        $result.attach_adapter_trace[0].launch_result | Should -Be 'skipped_unavailable'
        $result.attach_adapter_trace[1].host_kind | Should -Be 'powershell-window'
        $result.attach_adapter_trace[1].launch_result | Should -Be 'attach_confirmed'
        $script:startProcessCalls.Count | Should -Be 1
        $script:startProcessCalls[0].FilePath | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
    }

    It 'returns attach_already_present only when a live visible attach state already exists' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-1') }
        }
        Mock Read-OrchestraAttachState {
            [pscustomobject]@{
                session_name     = 'winsmux-orchestra'
                attach_status    = 'attach_confirmed'
                ui_attach_source = 'handshake'
                attach_process_id = 4242
            }
        }
        Mock Test-OrchestraLiveVisibleAttachState { $true }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $false }
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $false
        $result.Launched | Should -Be $false
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_already_present'
        $result.Source | Should -Be 'render-receipt'
        $script:startProcessCalls.Count | Should -Be 0
    }

    It 'preserves a render receipt confirmation source while the verified renderer is alive' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-1') }
        }
        Mock Read-OrchestraAttachState {
            [pscustomobject]@{
                session_name      = 'winsmux-orchestra'
                attach_status     = 'attach_confirmed'
                ui_attach_source  = 'render-receipt'
                attach_process_id = 4242
            }
        }
        Mock Test-OrchestraLiveVisibleAttachState { $true }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $false
        $result.Launched | Should -Be $false
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_already_present'
        $result.Source | Should -Be 'render-receipt'
        $script:startProcessCalls.Count | Should -Be 0
    }

    It 'does not reuse attached-client registry confirmation when render evidence is absent' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'
        $script:attachStateStore = $null

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-1') }
        }
        Mock Read-OrchestraAttachState {
            [pscustomobject]@{
                session_name              = 'winsmux-orchestra'
                attach_status             = 'attach_confirmed'
                ui_attach_source          = 'attached-client-registry'
                attach_process_id         = 4242
                attached_client_count     = 1
                attached_client_snapshot  = @('client-1')
            }
        }
        Mock Test-OrchestraLiveVisibleAttachState { $false }
        Mock Get-OrchestraVisibleAttachHostCandidates { @() }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $false }
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $false
        $result.Launched | Should -Be $false
        $result.Attached | Should -Be $false
        $result.Status | Should -Be 'attach_failed'
        $result.Source | Should -Be 'none'
        $script:startProcessCalls.Count | Should -Be 0
    }

    It 'does not suppress attach from client-probe alone when no live visible attach state exists' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'
        $script:attachStateStore = $null

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-1') }
        }
        Mock Read-OrchestraAttachState { $script:attachStateStore }
        Mock Test-OrchestraLiveVisibleAttachState { $false }
        Mock Get-OrchestraWindowsTerminalInfo {
            [PSCustomObject][ordered]@{
                Available   = $true
                Path        = 'C:\Windows\System32\wt.exe'
                AliasPath   = ''
                IsAliasStub = $false
                PathSource  = 'command'
                Reason      = 'ready'
            }
        }
        Mock Ensure-OrchestraAttachProfile {
            [PSCustomObject][ordered]@{
                ProfileName  = 'winsmux orchestra attach'
                FragmentPath = 'C:\Users\Example\AppData\Local\Microsoft\Windows Terminal\Fragments\winsmux\winsmux-orchestra-attach.json'
                Commandline  = '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoExit -File "C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1"'
            }
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Wait-OrchestraAttachLaunchObservation {
            [PSCustomObject]@{ Observed = $true; Reason = 'launch observed' }
        }
        Mock Wait-OrchestraAttachHandshake {
            param([string]$ExpectedRequestId)
            [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'handshake'
                Status              = 'attach_confirmed'
                Reason              = 'Attach confirmed'
                AttachedClientCount = 2
                State               = [pscustomobject]@{ attach_request_id = $ExpectedRequestId }
            }
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $true }
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $true
        $result.Launched | Should -Be $true
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_confirmed'
        $result.Source | Should -Be 'handshake'
        $script:startProcessCalls.Count | Should -Be 1
    }

    It 'falls back to a direct PowerShell visible attach host when Windows Terminal launch does not advance attach state' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-1') }
        }
        Mock Read-OrchestraAttachState { $script:attachStateStore }
        Mock Test-OrchestraLiveVisibleAttachState { $false }
        Mock Get-OrchestraWindowsTerminalInfo {
            [PSCustomObject][ordered]@{
                Available   = $true
                Path        = 'C:\Windows\System32\wt.exe'
                AliasPath   = ''
                IsAliasStub = $false
                PathSource  = 'command'
                Reason      = 'ready'
            }
        }
        Mock Ensure-OrchestraAttachProfile {
            [PSCustomObject][ordered]@{
                ProfileName  = 'winsmux orchestra attach'
                FragmentPath = 'C:\Users\Example\AppData\Local\Microsoft\Windows Terminal\Fragments\winsmux\winsmux-orchestra-attach.json'
                Commandline  = '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoExit -File "C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1"'
            }
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Wait-OrchestraAttachLaunchObservation {
            [PSCustomObject]@{ Observed = $false; Reason = 'no attach state change observed' }
        }
        Mock Get-OrchestraPowerShellPath { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Get-OrchestraAttachEntryArgumentList { @('-NoLogo', '-NoExit', '-File', 'C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1') }
        Mock Wait-OrchestraAttachHandshake {
            param([string]$ExpectedRequestId)
            [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'handshake'
                Status              = 'attach_confirmed'
                Reason              = 'Attach confirmed after fallback'
                AttachedClientCount = 1
                State               = [pscustomobject]@{ attach_request_id = $ExpectedRequestId }
            }
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $false }
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $true
        $result.Launched | Should -Be $true
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_confirmed'
        $result.Path | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        $result.attach_adapter_trace.Count | Should -Be 2
        $result.attach_adapter_trace[0].host_kind | Should -Be 'windows-terminal'
        $result.attach_adapter_trace[0].launch_result | Should -Be 'launch_unobserved'
        $result.attach_adapter_trace[1].host_kind | Should -Be 'powershell-window'
        $result.attach_adapter_trace[1].launch_result | Should -Be 'attach_confirmed'
        $script:startProcessCalls.Count | Should -Be 2
        $script:startProcessCalls[0].FilePath | Should -Be 'C:\Windows\System32\wt.exe'
        $script:startProcessCalls[1].FilePath | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
    }

    It 'falls back to a direct PowerShell visible attach host when Windows Terminal is unavailable' {
        $script:startProcessCalls = @()
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'
        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 0; Error = ''; Clients = @() }
        }
        Mock Read-OrchestraAttachState { $script:attachStateStore }
        Mock Test-OrchestraLiveVisibleAttachState { $false }
        Mock Get-OrchestraWindowsTerminalInfo {
            [PSCustomObject][ordered]@{
                Available   = $false
                Path        = ''
                AliasPath   = ''
                IsAliasStub = $false
                PathSource  = ''
                Reason      = 'wt_unavailable'
            }
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Get-OrchestraPowerShellPath { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Get-OrchestraAttachEntryArgumentList { @('-NoLogo', '-NoExit', '-File', 'C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1') }
        Mock Wait-OrchestraAttachHandshake {
            param([string]$ExpectedRequestId)
            [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'handshake'
                Status              = 'attach_confirmed'
                Reason              = 'Attach confirmed via fallback host'
                AttachedClientCount = 1
                State               = [pscustomobject]@{ attach_request_id = $ExpectedRequestId }
            }
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $false }
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $true
        $result.Launched | Should -Be $true
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_confirmed'
        $result.Path | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        $result.Source | Should -Be 'handshake'
        $result.attach_adapter_trace.Count | Should -Be 2
        $result.attach_adapter_trace[0].host_kind | Should -Be 'windows-terminal'
        $result.attach_adapter_trace[0].launch_result | Should -Be 'skipped_unavailable'
        $result.attach_adapter_trace[1].host_kind | Should -Be 'powershell-window'
        $result.attach_adapter_trace[1].launch_result | Should -Be 'attach_confirmed'
        $script:startProcessCalls.Count | Should -Be 1
        $script:startProcessCalls[0].FilePath | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
    }

    It 'falls back to the next visible attach host when the first host fails handshake confirmation' {
        $script:startProcessCalls = @()
        $script:attachStateStore = $null
        $script:handshakeCalls = 0
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 1; Error = ''; Clients = @('client-1') }
        }
        Mock Read-OrchestraAttachState { $script:attachStateStore }
        Mock Test-OrchestraLiveVisibleAttachState { $false }
        Mock Get-OrchestraWindowsTerminalInfo {
            [PSCustomObject][ordered]@{
                Available   = $true
                Path        = 'C:\Windows\System32\wt.exe'
                AliasPath   = ''
                IsAliasStub = $false
                PathSource  = 'command'
                Reason      = 'ready'
            }
        }
        Mock Ensure-OrchestraAttachProfile {
            [PSCustomObject][ordered]@{
                ProfileName  = 'winsmux orchestra attach'
                FragmentPath = 'C:\Users\Example\AppData\Local\Microsoft\Windows Terminal\Fragments\winsmux\winsmux-orchestra-attach.json'
                Commandline  = '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoExit -File "C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1"'
            }
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Wait-OrchestraAttachLaunchObservation {
            [PSCustomObject]@{ Observed = $true; Reason = 'launch observed' }
        }
        Mock Get-OrchestraPowerShellPath { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Get-OrchestraAttachEntryArgumentList { @('-NoLogo', '-NoExit', '-File', 'C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1') }
        Mock Wait-OrchestraAttachHandshake {
            param([string]$ExpectedRequestId)
            $script:handshakeCalls++
            if ($script:handshakeCalls -eq 1) {
                return [PSCustomObject][ordered]@{
                    Confirmed           = $false
                    Source              = 'timeout'
                    Status              = 'attach_failed'
                    Reason              = 'first host timed out'
                    AttachedClientCount = 1
                    State               = [pscustomobject]@{
                        attach_request_id = $ExpectedRequestId
                        ui_host_kind      = 'windows-terminal'
                    }
                }
            }

            return [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'handshake'
                Status              = 'attach_confirmed'
                Reason              = 'fallback host confirmed'
                AttachedClientCount = 1
                State               = [pscustomobject]@{
                    attach_request_id        = $ExpectedRequestId
                    attached_client_snapshot = @('client-1')
                    ui_host_kind             = 'powershell-window'
                }
            }
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $false }
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_confirmed'
        $result.Path | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        $result.attach_request_id | Should -Match '^[0-9a-f]{32}$'
        $result.ui_host_kind | Should -Be 'powershell-window'
        $result.attach_adapter_trace.Count | Should -Be 2
        $result.attach_adapter_trace[0].host_kind | Should -Be 'windows-terminal'
        $result.attach_adapter_trace[0].launch_result | Should -Be 'attach_failed'
        $result.attach_adapter_trace[1].host_kind | Should -Be 'powershell-window'
        $result.attach_adapter_trace[1].launch_result | Should -Be 'attach_confirmed'
        $script:startProcessCalls.Count | Should -Be 2
    }

    It 'treats ownership supersession as terminal and never launches a fallback host' {
        $script:attachStateStore = $null
        $script:candidateLaunchCount = 0
        $script:winsmuxBin = 'C:\winsmux\winsmux.exe'

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{ Ok = $true; Count = 0; Error = ''; Clients = @() }
        }
        Mock Read-OrchestraAttachState { $script:attachStateStore }
        Mock Test-OrchestraLiveVisibleAttachState { $false }
        Mock Get-OrchestraVisibleAttachHostCandidates {
            @(
                [pscustomobject]@{ Available = $true; HostKind = 'host-a'; Path = 'C:\host-a.exe'; Reason = 'ready'; UseLaunchObservation = $false },
                [pscustomobject]@{ Available = $true; HostKind = 'host-b'; Path = 'C:\host-b.exe'; Reason = 'ready'; UseLaunchObservation = $false }
            )
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties, [string]$ProjectDir, [string]$ExpectedRequestId)
            $currentRequestId = if ($null -ne $script:attachStateStore) { [string]$script:attachStateStore.attach_request_id } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedRequestId) -and $currentRequestId -ne $ExpectedRequestId) {
                return $script:attachStateStore
            }
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            if ($Properties.ContainsKey('attach_request_id')) {
                $merged.request_id = $Properties.attach_request_id
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Start-OrchestraVisibleAttachHostCandidate {
            param($Candidate)
            $script:candidateLaunchCount++
            [pscustomobject]@{ HostKind = $Candidate.HostKind; Path = $Candidate.Path; Process = [pscustomobject]@{ Id = 4001 } }
        }
        Mock Wait-OrchestraAttachHandshake {
            param([string]$ExpectedRequestId)
            $script:attachStateStore = [pscustomobject]@{
                attach_request_id    = 'request-new-owner'
                request_id           = 'request-new-owner'
                attach_status        = 'attach_requested'
                ui_host_kind         = 'host-new-owner'
                attach_adapter_trace = @('{"sequence":1,"host_kind":"host-new-owner","launch_result":"launched"}')
            }
            [pscustomobject]@{
                Confirmed           = $false
                Source              = 'none'
                Status              = 'attach_superseded'
                Reason              = "Attach request '$ExpectedRequestId' was superseded by 'request-new-owner'."
                AttachedClientCount = 0
                State               = $script:attachStateStore
            }
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attached | Should -Be $false
        $result.Status | Should -Be 'attach_superseded'
        $result.attach_request_id | Should -Be 'request-new-owner'
        $result.ui_host_kind | Should -Be 'host-new-owner'
        $script:candidateLaunchCount | Should -Be 1
        $script:attachStateStore.attach_request_id | Should -Be 'request-new-owner'
        $script:attachStateStore.attach_adapter_trace | Should -Be @('{"sequence":1,"host_kind":"host-new-owner","launch_result":"launched"}')
    }

    It 'does not confirm visible attach from client transition without render evidence' {
        $script:attachStateReads = 0

        Mock Read-OrchestraAttachState {
            $script:attachStateReads++
            [pscustomobject]@{
                session_name      = 'winsmux-orchestra'
                attach_status     = 'attach_entry_started'
                ui_attach_source  = 'none'
                attach_process_id = 4242
                baseline_clients  = @('client-old')
            }
        }
        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{
                Ok      = $true
                Count   = 1
                Error   = ''
                Clients = @('client-new')
            }
        }
        Mock Get-OrchestraLivePaneSnapshot {
            [pscustomobject]@{ Ok = $true; Count = 2; Error = ''; PaneIds = @('%1', '%2') }
        }
        Mock Test-OrchestraProcessAlive { $true }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            [pscustomobject]$Properties
        }
        function Start-Sleep {
            param([int]$Milliseconds)
        }

        $result = Wait-OrchestraAttachHandshake -SessionName 'winsmux-orchestra' -WinsmuxBin 'C:\winsmux\winsmux.exe' -BaselineClientCount 1 -BaselineClients @('client-old') -TimeoutMilliseconds 1000 -PollMilliseconds 1

        $result.Confirmed | Should -Be $false
        $result.Source | Should -Be 'none'
        $result.Status | Should -Be 'attach_failed'
        $result.AttachedClientCount | Should -Be 1
    }

    It 'does not confirm attach from a first client when baseline is empty and attach entry never started' {
        Mock Read-OrchestraAttachState {
            [pscustomobject]@{
                session_name      = 'winsmux-orchestra'
                attach_status     = 'attach_requested'
                ui_attach_source  = 'none'
                attach_process_id = 0
                baseline_clients  = @()
            }
        }
        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject]@{
                Ok      = $true
                Count   = 1
                Error   = ''
                Clients = @('client-1')
            }
        }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            [pscustomobject]$Properties
        }
        function Start-Sleep {
            param([int]$Milliseconds)
        }

        $result = Wait-OrchestraAttachHandshake -SessionName 'winsmux-orchestra' -WinsmuxBin 'C:\winsmux\winsmux.exe' -BaselineClientCount 0 -BaselineClients @() -TimeoutMilliseconds 5 -PollMilliseconds 1

        $result.Confirmed | Should -Be $false
        $result.Status | Should -Be 'attach_failed'
        $result.Reason | Should -Match 'Attach confirmation timed out: render_receipt_'
    }

    It 'checks the bootstrap pane count before reporting startup ready' {
        $script:probeCount = 0
        $script:paneCountCallCount = 0
        $script:newSessionCalls = 0

        function Test-OrchestraServerSession {
            param([string]$SessionName)
            $script:probeCount++
            return ($script:probeCount -ge 2)
        }

        function Invoke-Winsmux {
            param([string[]]$Arguments, [switch]$CaptureOutput)
            if ($Arguments[0] -eq 'new-session') {
                $script:newSessionCalls++
                return
            }

            throw "unexpected winsmux call: $($Arguments -join ' ')"
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
        }

        Mock Get-OrchestraSessionPaneCount { $script:paneCountCallCount++; return 1 }

        function Start-Sleep {
            param([int]$Milliseconds)
        }

        $result = Ensure-OrchestraBootstrapSession -SessionName 'winsmux-orchestra' -ExpectedPaneCount 1

        $result.BootstrapReady | Should -Be $true
        $result.StartupReady | Should -Be $false
        $result.BootstrapMode | Should -Be 'detached_primary'
        $result.UiAttachStatus | Should -Be 'not_requested'
        $script:newSessionCalls | Should -Be 1
        $script:paneCountCallCount | Should -Be 1
        $script:probeCount | Should -Be 2
    }

    It 'resets a stale session by killing it, clearing registration, and recreating it' {
        $script:killCalls = 0
        $script:clearCalls = 0
        $script:ensureCalls = 0
        $script:waitCalls = 0
        $script:ensureTimeoutSeconds = $null

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

        function Wait-OrchestraServerSessionAbsent {
            param([string]$SessionName, [int]$TimeoutSeconds = 20)
            $script:waitCalls++
            return [ordered]@{
                Ready       = $true
                PollAttempt = 1
            }
        }

        function Ensure-OrchestraBootstrapSession {
            param([string]$SessionName, [int]$TimeoutSeconds = 60, [int]$ExpectedPaneCount = 1)
            $script:ensureCalls++
            $script:ensureTimeoutSeconds = $TimeoutSeconds
            $script:ensureExpectedPaneCount = $ExpectedPaneCount
            return [ordered]@{
                SessionName    = $SessionName
                BootstrapReady = $true
                StartupReady   = $false
                BootstrapMode  = 'detached_primary'
            }
        }

        Mock Test-OrchestraServerSession { $true }

        $result = Reset-OrchestraServerSession -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux' -Reason 'test'

        $result.BootstrapReady | Should -Be $true
        $result.StartupReady | Should -Be $false
        $result.Health | Should -Be 'BootstrapOnly'
        $script:killCalls | Should -Be 1
        $script:clearCalls | Should -Be 1
        $script:ensureCalls | Should -Be 1
        $script:waitCalls | Should -Be 1
        $script:ensureTimeoutSeconds | Should -Be 60
        $script:ensureExpectedPaneCount | Should -Be 1
    }

    It 'TASK781 C66 routes manifest-owning reset through fail-closed retirement before bootstrap' {
        Mock Test-OrchestraServerSession { $true }
        Mock Invoke-Winsmux { throw 'manifest-owning reset must not kill outside the retirement helper' }
        Mock Wait-OrchestraServerSessionAbsent { throw 'manifest-owning reset must not wait outside the retirement helper' }
        Mock Clear-OrchestraManifestAfterServerRetirement {
            param($ProjectDir, $GitWorktreeDir, $BridgeScript, $SessionName, $WinsmuxBin)
            $WinsmuxBin | Should -BeExactly 'winsmux'
            [PSCustomObject]@{ Stopped = @(); Errors = @(); Cleared = $true }
        }
        Mock Stop-OrchestraBackgroundProcessesFromManifest { throw 'direct background cleanup is forbidden' }
        Mock Clear-WinsmuxManifest { throw 'direct manifest clear is forbidden' }
        Mock Clear-OrchestraSessionRegistration { }
        Mock Ensure-OrchestraBootstrapSession {
            [PSCustomObject]@{
                SessionName = 'winsmux-orchestra'; BootstrapReady = $true
                StartupReady = $false; BootstrapMode = 'detached_primary'
            }
        }

        $result = Reset-OrchestraServerSession -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux' `
            -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
            -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -Reason 'test'

        $result.BootstrapReady | Should -BeTrue
        Should -Invoke Clear-OrchestraManifestAfterServerRetirement -Times 1 -Exactly
        Should -Invoke Invoke-Winsmux -Times 0 -Exactly
        Should -Invoke Wait-OrchestraServerSessionAbsent -Times 0 -Exactly
        Should -Invoke Stop-OrchestraBackgroundProcessesFromManifest -Times 0 -Exactly
        Should -Invoke Clear-WinsmuxManifest -Times 0 -Exactly
        Should -Invoke Ensure-OrchestraBootstrapSession -Times 1 -Exactly
    }

    It 'TASK781 C66 does not bootstrap reset when fail-closed retirement fails' {
        Mock Test-OrchestraServerSession { $false }
        Mock Clear-OrchestraManifestAfterServerRetirement { throw 'synthetic reset retirement failure' }
        Mock Clear-OrchestraSessionRegistration { }
        Mock Ensure-OrchestraBootstrapSession { throw 'replacement bootstrap must not run' }

        {
            Reset-OrchestraServerSession -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux' `
                -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
                -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -Reason 'test'
        } | Should -Throw '*reset retirement failure*'

        Should -Invoke Ensure-OrchestraBootstrapSession -Times 0 -Exactly
    }

    It 'retires background state and deletes the old manifest before replacement generation creation' {
        $script:retiredManifestSequence = [System.Collections.Generic.List[string]]::new()
        $script:retiredRegistryClosed = $false
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                session = [PSCustomObject]@{
                    name = 'winsmux-orchestra'; generation_id = 'generation-retired'
                    server_session_id = '$41'; supervisor_pid = 4201
                }
            }
        }
        Mock Read-WinsmuxRuntimeRegistry {
            [PSCustomObject]@{
                status = if ($script:retiredRegistryClosed) { 'ended' } else { 'active' }
                session_name = 'winsmux-orchestra'; generation_id = 'generation-retired'; server_session_id = '$41'
                supervisor = [PSCustomObject]@{ pid = 4201; process_started_at = '2026-07-16T04:00:00.0000000Z' }
                lease = [PSCustomObject]@{ state = if ($script:retiredRegistryClosed) { 'ended' } else { 'active' }; expires_at = '2026-07-16T04:00:15.0000000Z' }
            }
        }
        Mock New-WinsmuxProcessSnapshotResolver {
            {
                param([int]$Id)
                [PSCustomObject]@{ Id = $Id; StartTime = '2026-07-16T04:00:00.0000000Z' }
            }
        }
        Mock Remove-OrchestraSessionServerProcesses {
            $script:retiredManifestSequence.Add('matched-processes-retired') | Out-Null
            return [PSCustomObject]@{ SessionProcesses = @(); Killed = @(); RemainingSessionProcesses = @(); Errors = @() }
        }
        Mock Wait-OrchestraServerSessionAbsent {
            $script:retiredManifestSequence.Add('server-absent') | Out-Null
            return [PSCustomObject]@{ Ready = $true; PollAttempt = 1 }
        }
        Mock Stop-OrchestraBackgroundProcessesFromManifest {
            $script:retiredManifestSequence.Add('backgrounds-retired') | Out-Null
            return [PSCustomObject]@{ Stopped = @([PSCustomObject]@{ pid = 42 }); Errors = @() }
        }
        Mock Close-WinsmuxRuntimeRegistry {
            param($ProjectDir, $GenerationId, $SupervisorPid, $SupervisorProcessStartedAt, $ExpectedSessionName, $ExpectedServerSessionId)
            $GenerationId | Should -BeExactly 'generation-retired'
            $SupervisorPid | Should -Be 4201
            $SupervisorProcessStartedAt | Should -BeExactly '2026-07-16T04:00:00.0000000Z'
            $ExpectedSessionName | Should -BeExactly 'winsmux-orchestra'
            $ExpectedServerSessionId | Should -BeExactly '$41'
            $script:retiredRegistryClosed = $true
            $script:retiredManifestSequence.Add('registry-ended') | Out-Null
            return $true
        }
        Mock Clear-WinsmuxManifest {
            $script:retiredManifestSequence.Add('manifest-cleared') | Out-Null
            return $true
        }

        $result = Clear-OrchestraManifestAfterServerRetirement `
            -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
            -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'

        @($script:retiredManifestSequence) | Should -Be @('matched-processes-retired', 'server-absent', 'backgrounds-retired', 'registry-ended', 'manifest-cleared')
        $result.RegistryClosed | Should -BeTrue
        $result.Cleared | Should -BeTrue
        @($result.Stopped).Count | Should -Be 1
        @($result.Errors).Count | Should -Be 0
    }

    It 'TASK781 C71 refuses a competing active runtime registry before retiring any process' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                session = [PSCustomObject]@{
                    name = 'winsmux-orchestra'; generation_id = 'generation-retired'
                    server_session_id = '$41'; supervisor_pid = 4201
                }
            }
        }
        Mock Read-WinsmuxRuntimeRegistry {
            [PSCustomObject]@{
                status = 'active'; session_name = 'winsmux-orchestra'
                generation_id = 'generation-competing'; server_session_id = '$41'
                supervisor = [PSCustomObject]@{ pid = 4201; process_started_at = '2026-07-16T04:00:00.0000000Z' }
                lease = [PSCustomObject]@{ state = 'active'; expires_at = '2026-07-16T04:00:15.0000000Z' }
            }
        }
        Mock Remove-OrchestraSessionServerProcesses { throw 'process retirement must not start' }
        Mock Wait-OrchestraServerSessionAbsent { throw 'logical retirement must not start' }
        Mock Stop-OrchestraBackgroundProcessesFromManifest { throw 'background retirement must not start' }
        Mock Close-WinsmuxRuntimeRegistry { throw 'competing registry must not be closed' }
        Mock Clear-WinsmuxManifest { throw 'manifest must be preserved' }

        {
            Clear-OrchestraManifestAfterServerRetirement `
                -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
                -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'
        } | Should -Throw '*runtime registry identity does not match*'

        Should -Invoke Remove-OrchestraSessionServerProcesses -Times 0 -Exactly
        Should -Invoke Stop-OrchestraBackgroundProcessesFromManifest -Times 0 -Exactly
        Should -Invoke Close-WinsmuxRuntimeRegistry -Times 0 -Exactly
        Should -Invoke Clear-WinsmuxManifest -Times 0 -Exactly
    }

    It 'TASK781 C71 refuses a foreign manifest session before retiring any process even without a registry' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                session = [PSCustomObject]@{
                    name = 'winsmux-foreign'; generation_id = 'generation-retired'
                    server_session_id = '$41'; supervisor_pid = 4201
                }
            }
        }
        Mock Read-WinsmuxRuntimeRegistry { $null }
        Mock Remove-OrchestraSessionServerProcesses { throw 'process retirement must not start' }
        Mock Wait-OrchestraServerSessionAbsent { throw 'logical retirement must not start' }
        Mock Stop-OrchestraBackgroundProcessesFromManifest { throw 'background retirement must not start' }
        Mock Clear-WinsmuxManifest { throw 'foreign manifest must be preserved' }

        {
            Clear-OrchestraManifestAfterServerRetirement `
                -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
                -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'
        } | Should -Throw '*manifest session identity does not match*'

        Should -Invoke Remove-OrchestraSessionServerProcesses -Times 0 -Exactly
        Should -Invoke Stop-OrchestraBackgroundProcessesFromManifest -Times 0 -Exactly
        Should -Invoke Clear-WinsmuxManifest -Times 0 -Exactly
    }

    It 'TASK781 C71 refuses a reused supervisor PID before retiring any process' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                session = [PSCustomObject]@{
                    name = 'winsmux-orchestra'; generation_id = 'generation-retired'
                    server_session_id = '$41'; supervisor_pid = 4201
                }
            }
        }
        Mock Read-WinsmuxRuntimeRegistry {
            [PSCustomObject]@{
                status = 'active'; session_name = 'winsmux-orchestra'
                generation_id = 'generation-retired'; server_session_id = '$41'
                supervisor = [PSCustomObject]@{ pid = 4201; process_started_at = '2026-07-16T04:00:00.0000000Z' }
                lease = [PSCustomObject]@{ state = 'active'; expires_at = '2026-07-16T04:00:15.0000000Z' }
            }
        }
        Mock New-WinsmuxProcessSnapshotResolver {
            {
                param([int]$Id)
                [PSCustomObject]@{ Id = $Id; StartTime = '2026-07-16T04:00:01.0000000Z' }
            }
        }
        Mock Remove-OrchestraSessionServerProcesses { throw 'process retirement must not start' }
        Mock Wait-OrchestraServerSessionAbsent { throw 'logical retirement must not start' }
        Mock Stop-OrchestraBackgroundProcessesFromManifest { throw 'background retirement must not start' }
        Mock Close-WinsmuxRuntimeRegistry { throw 'reused PID registry must not be closed' }
        Mock Clear-WinsmuxManifest { throw 'manifest must be preserved' }

        {
            Clear-OrchestraManifestAfterServerRetirement `
                -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
                -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'
        } | Should -Throw '*OS process identity does not match*'

        Should -Invoke Remove-OrchestraSessionServerProcesses -Times 0 -Exactly
        Should -Invoke Close-WinsmuxRuntimeRegistry -Times 0 -Exactly
        Should -Invoke Clear-WinsmuxManifest -Times 0 -Exactly
    }

    It 'TASK781 C71 refuses an incomplete live supervisor identity before retiring any process' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                session = [PSCustomObject]@{
                    name = 'winsmux-orchestra'; generation_id = 'generation-retired'
                    server_session_id = '$41'; supervisor_pid = 4201
                }
            }
        }
        Mock Read-WinsmuxRuntimeRegistry {
            [PSCustomObject]@{
                status = 'active'; session_name = 'winsmux-orchestra'
                generation_id = 'generation-retired'; server_session_id = '$41'
                supervisor = [PSCustomObject]@{ pid = 4201; process_started_at = '2026-07-16T04:00:00.0000000Z' }
                lease = [PSCustomObject]@{ state = 'active'; expires_at = '2026-07-16T04:00:15.0000000Z' }
            }
        }
        Mock Get-CimInstance {
            [PSCustomObject]@{ ProcessId = 4201; ParentProcessId = 1; CreationDate = $null; Name = 'pwsh.exe' }
        } -ParameterFilter { $ClassName -eq 'Win32_Process' }
        Mock Remove-OrchestraSessionServerProcesses { throw 'process retirement must not start' }
        Mock Wait-OrchestraServerSessionAbsent { throw 'logical retirement must not start' }
        Mock Stop-OrchestraBackgroundProcessesFromManifest { throw 'background retirement must not start' }
        Mock Close-WinsmuxRuntimeRegistry { throw 'unverifiable registry must not be closed' }
        Mock Clear-WinsmuxManifest { throw 'manifest must be preserved' }

        {
            Clear-OrchestraManifestAfterServerRetirement `
                -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
                -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'
        } | Should -Throw '*OS process identity does not match*'

        Should -Invoke Remove-OrchestraSessionServerProcesses -Times 0 -Exactly
        Should -Invoke Close-WinsmuxRuntimeRegistry -Times 0 -Exactly
        Should -Invoke Clear-WinsmuxManifest -Times 0 -Exactly
    }

    It 'TASK781 C71 preserves the manifest when the matched runtime registry close is refused' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                session = [PSCustomObject]@{
                    name = 'winsmux-orchestra'; generation_id = 'generation-retired'
                    server_session_id = '$41'; supervisor_pid = 4201
                }
            }
        }
        Mock Read-WinsmuxRuntimeRegistry {
            [PSCustomObject]@{
                status = 'active'; session_name = 'winsmux-orchestra'
                generation_id = 'generation-retired'; server_session_id = '$41'
                supervisor = [PSCustomObject]@{ pid = 4201; process_started_at = '2026-07-16T04:00:00.0000000Z' }
                lease = [PSCustomObject]@{ state = 'active'; expires_at = '2026-07-16T04:00:15.0000000Z' }
            }
        }
        Mock New-WinsmuxProcessSnapshotResolver { { param([int]$Id) $null } }
        Mock Remove-OrchestraSessionServerProcesses {
            [PSCustomObject]@{ SessionProcesses = @(); Killed = @(); RemainingSessionProcesses = @(); Errors = @() }
        }
        Mock Wait-OrchestraServerSessionAbsent { [PSCustomObject]@{ Ready = $true; PollAttempt = 1 } }
        Mock Stop-OrchestraBackgroundProcessesFromManifest {
            [PSCustomObject]@{ Stopped = @([PSCustomObject]@{ pid = 4201 }); Errors = @() }
        }
        Mock Close-WinsmuxRuntimeRegistry { $false }
        Mock Clear-WinsmuxManifest { throw 'manifest must be preserved after close refusal' }

        {
            Clear-OrchestraManifestAfterServerRetirement `
                -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
                -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'
        } | Should -Throw '*retirement was refused because ownership changed*'

        Should -Invoke Close-WinsmuxRuntimeRegistry -Times 1 -Exactly
        Should -Invoke Clear-WinsmuxManifest -Times 0 -Exactly
    }

    It 'TASK781 C71 accepts an absent registry as the legacy retirement path' {
        Mock Get-WinsmuxManifest { $null }
        Mock Read-WinsmuxRuntimeRegistry { $null }
        Mock Remove-OrchestraSessionServerProcesses {
            [PSCustomObject]@{ SessionProcesses = @(); Killed = @(); RemainingSessionProcesses = @(); Errors = @() }
        }
        Mock Wait-OrchestraServerSessionAbsent { [PSCustomObject]@{ Ready = $true; PollAttempt = 1 } }
        Mock Stop-OrchestraBackgroundProcessesFromManifest {
            [PSCustomObject]@{ Stopped = @(); Errors = @() }
        }
        Mock Close-WinsmuxRuntimeRegistry { throw 'absent registry must not be closed' }
        Mock Clear-WinsmuxManifest { $false }

        $result = Clear-OrchestraManifestAfterServerRetirement `
            -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
            -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'

        $result.RegistryPresent | Should -BeFalse
        $result.RegistryClosed | Should -BeFalse
        Should -Invoke Close-WinsmuxRuntimeRegistry -Times 0 -Exactly
        Should -Invoke Clear-WinsmuxManifest -Times 1 -Exactly
    }

    It 'TASK781 C72 retires a nameless v1 manifest as an explicit upgrade compatibility path' {
        $script:c72Sequence = [System.Collections.Generic.List[string]]::new()
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                version = 1
                session = [PSCustomObject]@{
                    started = '2026-07-01T00:00:00Z'
                    project_dir = 'C:\project'
                }
                panes = [ordered]@{}
            }
        }
        Mock Read-WinsmuxRuntimeRegistry { $null }
        Mock Remove-OrchestraSessionServerProcesses {
            $script:c72Sequence.Add('server-processes-retired') | Out-Null
            [PSCustomObject]@{ SessionProcesses = @(); Killed = @(); RemainingSessionProcesses = @(); Errors = @() }
        }
        Mock Wait-OrchestraServerSessionAbsent {
            $script:c72Sequence.Add('server-absent') | Out-Null
            [PSCustomObject]@{ Ready = $true; PollAttempt = 1 }
        }
        Mock Stop-OrchestraBackgroundProcessesFromManifest {
            $script:c72Sequence.Add('backgrounds-retired') | Out-Null
            [PSCustomObject]@{ Stopped = @(); Errors = @() }
        }
        Mock Close-WinsmuxRuntimeRegistry { throw 'v1 upgrade path has no registry to close' }
        Mock Clear-WinsmuxManifest {
            $script:c72Sequence.Add('manifest-cleared') | Out-Null
            $true
        }

        $result = Clear-OrchestraManifestAfterServerRetirement `
            -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
            -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'

        @($script:c72Sequence) | Should -Be @('server-processes-retired', 'server-absent', 'backgrounds-retired', 'manifest-cleared')
        $result.RegistryPresent | Should -BeFalse
        $result.Cleared | Should -BeTrue
        Should -Invoke Close-WinsmuxRuntimeRegistry -Times 0 -Exactly
    }

    It 'TASK781 C72 keeps the nameless legacy exception version-scoped and target-scoped' {
        Mock Get-WinsmuxManifest { $script:c72RejectedManifest }
        Mock Read-WinsmuxRuntimeRegistry { $null }
        Mock Remove-OrchestraSessionServerProcesses { throw 'rejected manifest must not retire processes' }
        Mock Wait-OrchestraServerSessionAbsent { throw 'rejected manifest must not wait for retirement' }
        Mock Stop-OrchestraBackgroundProcessesFromManifest { throw 'rejected manifest must not retire backgrounds' }
        Mock Clear-WinsmuxManifest { throw 'rejected manifest must be preserved' }

        $cases = @(
            [PSCustomObject]@{ version = 1; session = [PSCustomObject]@{ name = 'foreign-session' } }
            [PSCustomObject]@{ version = 2; session = [PSCustomObject]@{} }
            [PSCustomObject]@{ version = 99; session = [PSCustomObject]@{} }
            [PSCustomObject]@{ session = [PSCustomObject]@{} }
        )
        foreach ($case in $cases) {
            $script:c72RejectedManifest = $case
            {
                Clear-OrchestraManifestAfterServerRetirement `
                    -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
                    -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'
            } | Should -Throw '*manifest session identity does not match*'
        }

        Should -Invoke Remove-OrchestraSessionServerProcesses -Times 0 -Exactly
        Should -Invoke Stop-OrchestraBackgroundProcessesFromManifest -Times 0 -Exactly
        Should -Invoke Clear-WinsmuxManifest -Times 0 -Exactly
    }

    It 'TASK781 C72 refuses a nameless v1 manifest when an active registry cannot be ownership-matched' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{ version = 1; session = [PSCustomObject]@{ started = '2026-07-01T00:00:00Z' } }
        }
        Mock Read-WinsmuxRuntimeRegistry {
            [PSCustomObject]@{
                status = 'active'; session_name = 'winsmux-orchestra'
                generation_id = 'unverifiable-generation'; server_session_id = '$72'
                supervisor = [PSCustomObject]@{ pid = 4272; process_started_at = '2026-07-16T06:00:00.0000000Z' }
                lease = [PSCustomObject]@{ state = 'active'; expires_at = '2026-07-16T06:00:15.0000000Z' }
            }
        }
        Mock Remove-OrchestraSessionServerProcesses { throw 'unmatched active registry must block process retirement' }
        Mock Stop-OrchestraBackgroundProcessesFromManifest { throw 'unmatched active registry must block background retirement' }
        Mock Clear-WinsmuxManifest { throw 'unmatched active registry must preserve the manifest' }

        {
            Clear-OrchestraManifestAfterServerRetirement `
                -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
                -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'
        } | Should -Throw '*runtime registry identity does not match*'

        Should -Invoke Remove-OrchestraSessionServerProcesses -Times 0 -Exactly
        Should -Invoke Stop-OrchestraBackgroundProcessesFromManifest -Times 0 -Exactly
        Should -Invoke Clear-WinsmuxManifest -Times 0 -Exactly
    }

    It 'TASK781 C72 completes the production background-cleanup boundary for a tokenless v1 upgrade' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                version = 1
                session = [PSCustomObject]@{ started = '2026-07-01T00:00:00Z'; project_dir = 'C:\project' }
                panes = [ordered]@{}
            }
        }
        Mock Read-WinsmuxRuntimeRegistry { $null }
        Mock Remove-OrchestraSessionServerProcesses {
            [PSCustomObject]@{ SessionProcesses = @(); Killed = @(); RemainingSessionProcesses = @(); Errors = @() }
        }
        Mock Wait-OrchestraServerSessionAbsent { [PSCustomObject]@{ Ready = $true; PollAttempt = 1 } }
        Mock Get-ProcessSnapshot { throw 'tokenless v1 cleanup must not inspect arbitrary processes' }
        Mock Stop-Process { throw 'tokenless v1 cleanup must not stop arbitrary processes' }
        Mock Clear-WinsmuxManifest { $true }

        $result = Clear-OrchestraManifestAfterServerRetirement `
            -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
            -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'

        $result.Cleared | Should -BeTrue
        @($result.Stopped).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
        Should -Invoke Get-ProcessSnapshot -Times 0 -Exactly
        Should -Invoke Stop-Process -Times 0 -Exactly
        Should -Invoke Clear-WinsmuxManifest -Times 1 -Exactly
    }

    It 'does not clear the old manifest while the retired server remains observable' {
        Mock Remove-OrchestraSessionServerProcesses {
            [PSCustomObject]@{ SessionProcesses = @(); Killed = @(); RemainingSessionProcesses = @(); Errors = @() }
        }
        Mock Wait-OrchestraServerSessionAbsent { throw 'synthetic server still present' }
        Mock Stop-OrchestraBackgroundProcessesFromManifest { throw 'must not inspect backgrounds before server absence' }
        Mock Clear-WinsmuxManifest { throw 'must not clear manifest before server absence' }

        {
            Clear-OrchestraManifestAfterServerRetirement `
                -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
                -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'
        } | Should -Throw '*server still present*'
        Should -Invoke Stop-OrchestraBackgroundProcessesFromManifest -Times 0 -Exactly
        Should -Invoke Clear-WinsmuxManifest -Times 0 -Exactly
    }

    It 'does not clear the old manifest when owned background retirement is incomplete' {
        Mock Remove-OrchestraSessionServerProcesses {
            [PSCustomObject]@{ SessionProcesses = @(); Killed = @(); RemainingSessionProcesses = @(); Errors = @() }
        }
        Mock Wait-OrchestraServerSessionAbsent { [PSCustomObject]@{ Ready = $true; PollAttempt = 1 } }
        Mock Stop-OrchestraBackgroundProcessesFromManifest {
            [PSCustomObject]@{ Stopped = @(); Errors = @('supervisor identity could not be retired') }
        }
        Mock Clear-WinsmuxManifest { throw 'must not clear manifest with unresolved background ownership' }

        {
            Clear-OrchestraManifestAfterServerRetirement `
                -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
                -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'
        } | Should -Throw '*background cleanup is incomplete*'
        Should -Invoke Clear-WinsmuxManifest -Times 0 -Exactly
    }

    It 'TASK781 C66 keeps the old manifest when complete server-process retirement fails' {
        Mock Remove-OrchestraSessionServerProcesses { throw 'synthetic matched server remains' }
        Mock Wait-OrchestraServerSessionAbsent { throw 'logical-session check must not run' }
        Mock Stop-OrchestraBackgroundProcessesFromManifest { throw 'background cleanup must not run' }
        Mock Clear-WinsmuxManifest { throw 'old manifest must be preserved' }

        {
            Clear-OrchestraManifestAfterServerRetirement `
                -ProjectDir 'C:\project' -GitWorktreeDir 'C:\project' `
                -BridgeScript 'C:\project\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra' -WinsmuxBin 'winsmux'
        } | Should -Throw '*matched server remains*'

        Should -Invoke Wait-OrchestraServerSessionAbsent -Times 0 -Exactly
        Should -Invoke Stop-OrchestraBackgroundProcessesFromManifest -Times 0 -Exactly
        Should -Invoke Clear-WinsmuxManifest -Times 0 -Exactly
    }

    It 'throws when the layout leaves the session below the expected pane count' {
        Mock Get-OrchestraSessionPaneIds { @('%1') }

        {
            Assert-OrchestraSessionPaneCount -SessionName 'winsmux-orchestra' -ExpectedPaneCount 2 -StageName 'layout'
        } | Should -Throw '*expected 2 pane(s)*found 1*'
    }

    It 'fails closed when a background watchdog process exits immediately' {
        $process = [PSCustomObject]@{
            HasExited = $true
            ExitCode  = 23
        }

        { Assert-OrchestraBackgroundProcessStarted -Process $process -Name 'Server watchdog job' -StartupDelayMilliseconds 1 } | Should -Throw '*exited immediately*'
    }

    It 'accepts builder pane launch-dir evidence from the recent capture when pane_current_path lags behind' {
        function Invoke-Winsmux {
            param([string[]]$Arguments, [switch]$CaptureOutput)
            if ($Arguments[0] -eq 'display-message') {
                return 'C:\Users\Example\Documents\Projects\apps\winsmux'
            }

            if ($Arguments[0] -eq 'capture-pane') {
                return @'
› Write tests for @filename

  gpt-5.4 high · ~\Documents\Projects\apps\winsmux\.worktrees\builder-6
'@
            }

            throw "unexpected winsmux call: $($Arguments -join ' ')"
        }

        $failures = @(Test-PaneBootstrapInvariants `
            -PaneId '%8' `
            -Label 'worker-6' `
            -ExpectedRole 'Worker' `
            -ExpectedLaunchDir 'C:\Users\Example\Documents\Projects\apps\winsmux\.worktrees\builder-6' `
            -ExpectedWorktreePath 'C:\Users\Example\Documents\Projects\apps\winsmux\.worktrees\builder-6')

        $failures.Count | Should -Be 0
    }

    It 'accepts a matching bootstrap marker when pane_current_path lags behind' {
        $markerPath = Join-Path $TestDrive 'worker-6.ready.json'
        @'
{
  "launch_dir": "C:\\Users\\Example\\Documents\\Projects\\apps\\winsmux\\.worktrees\\builder-6",
  "current_dir": "C:\\Users\\Example\\Documents\\Projects\\apps\\winsmux\\.worktrees\\builder-6"
}
'@ | Set-Content -LiteralPath $markerPath -Encoding UTF8

        function Invoke-Winsmux {
            param([string[]]$Arguments, [switch]$CaptureOutput)
            if ($Arguments[0] -eq 'display-message') {
                return 'C:\Users\Example\Documents\Projects\apps\winsmux'
            }

            if ($Arguments[0] -eq 'capture-pane') {
                return 'capture fallback not needed'
            }

            throw "unexpected winsmux call: $($Arguments -join ' ')"
        }

        $failures = @(Test-PaneBootstrapInvariants `
            -PaneId '%8' `
            -Label 'worker-6' `
            -ExpectedRole 'Worker' `
            -ExpectedLaunchDir 'C:\Users\Example\Documents\Projects\apps\winsmux\.worktrees\builder-6' `
            -ExpectedWorktreePath 'C:\Users\Example\Documents\Projects\apps\winsmux\.worktrees\builder-6' `
            -BootstrapMarkerPath $markerPath)

        $failures.Count | Should -Be 0
    }

    It 'treats missing Windows Terminal as a non-fatal UI attach condition' {
        $script:startProcessCalls = @()

        function Get-Command {
            param([string]$Name)
            if ($Name -eq 'pwsh') {
                return [PSCustomObject]@{ Source = 'C:\Program Files\PowerShell\7\pwsh.exe' }
            }
            if ($Name -eq 'winsmux') {
                return [PSCustomObject]@{ Source = 'C:\Users\Example\.local\bin\winsmux.exe' }
            }

            throw "unexpected command lookup: $Name"
        }

        Mock Get-OrchestraWindowsTerminalInfo {
            [PSCustomObject][ordered]@{
                Available   = $false
                Path        = ''
                AliasPath   = ''
                IsAliasStub = $false
                PathSource  = ''
                Reason      = 'wt_unavailable'
            }
        }

        Mock Get-OrchestraAttachedClientSnapshot {
            [PSCustomObject][ordered]@{
                Ok      = $true
                Count   = 0
                Clients = @()
            }
        }
        Mock Read-OrchestraAttachState { $null }
        Mock Test-OrchestraLiveVisibleAttachState { $false }
        Mock Write-OrchestraAttachState {
            param([string]$SessionName, [hashtable]$Properties)
            $merged = [ordered]@{}
            if ($null -ne $script:attachStateStore) {
                foreach ($property in $script:attachStateStore.PSObject.Properties) {
                    $merged[$property.Name] = $property.Value
                }
            }
            foreach ($key in $Properties.Keys) {
                $merged[$key] = $Properties[$key]
            }
            $script:attachStateStore = [pscustomobject]$merged
            return $script:attachStateStore
        }
        Mock Get-OrchestraPowerShellPath { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Get-OrchestraAttachEntryArgumentList { @('-NoLogo', '-NoExit', '-File', 'C:\repo\winsmux-core\scripts\orchestra-attach-entry.ps1') }
        Mock Wait-OrchestraAttachHandshake {
            param([string]$ExpectedRequestId)
            [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'handshake'
                Status              = 'attach_confirmed'
                Reason              = 'Attach confirmed via fallback host'
                AttachedClientCount = 1
                State               = [pscustomobject]@{ attach_request_id = $ExpectedRequestId }
            }
        }

        function Start-Process {
            param([string]$FilePath, [object[]]$ArgumentList, [switch]$PassThru)
            $script:startProcessCalls += ,([PSCustomObject]@{
                FilePath     = $FilePath
                ArgumentList = @($ArgumentList)
            })
            return [PSCustomObject]@{ HasExited = $false }
        }

        function Start-Sleep {
            param([int]$Milliseconds)
        }

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $true
        $result.Launched | Should -Be $true
        $result.Attached | Should -Be $true
        $result.Status | Should -Be 'attach_confirmed'
        $script:startProcessCalls.Count | Should -Be 1
        $script:startProcessCalls[0].FilePath | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
    }

    It 'skips UI attach when winsmux cannot be resolved to an absolute path for the child process' {
        function Get-Command {
            param([string]$Name)
            if ($Name -eq 'wt.exe') {
                return [PSCustomObject]@{ Source = 'C:\Windows\System32\wt.exe' }
            }
            if ($Name -eq 'pwsh') {
                return [PSCustomObject]@{ Source = 'C:\Program Files\PowerShell\7\pwsh.exe' }
            }
            if ($Name -eq 'winsmux') {
                return $null
            }

            throw "unexpected command lookup: $Name"
        }

        function Get-Item {
            param([string]$LiteralPath)
            return [PSCustomObject]@{ Length = 4096 }
        }

        $script:winsmuxBin = 'winsmux'

        $result = Try-StartOrchestraUiAttach -SessionName 'winsmux-orchestra'

        $result.Attempted | Should -Be $false
        $result.Launched | Should -Be $false
        $result.Attached | Should -Be $false
        $result.Status | Should -Be 'winsmux_unresolved'
    }

    It 'stops stale background processes recorded in the manifest before fresh startup' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                session = [PSCustomObject]@{
                    startup_token       = 'token-123'
                    operator_poll_pid  = '101'
                    watchdog_pid        = '202'
                    server_watchdog_pid = '303'
                }
            }
        }

        $script:stoppedProcessIds = @()
        Mock Get-ProcessSnapshot {
            [PSCustomObject]@{
                ById = @{
                    101 = [PSCustomObject]@{ ProcessId = 101; ParentProcessId = 1; CommandLine = 'pwsh operator-poll.ps1 C:\repo\.winsmux\manifest.yaml -StartupToken token-123 winsmux-orchestra C:\repo\scripts\winsmux-core.ps1'; Name = 'pwsh.exe' }
                    202 = [PSCustomObject]@{ ProcessId = 202; ParentProcessId = 1; CommandLine = 'pwsh agent-watchdog.ps1 C:\repo\.winsmux\manifest.yaml -StartupToken token-123 winsmux-orchestra C:\repo\scripts\winsmux-core.ps1'; Name = 'pwsh.exe' }
                    303 = [PSCustomObject]@{ ProcessId = 303; ParentProcessId = 1; CommandLine = 'pwsh server-watchdog.ps1 C:\repo\.winsmux\manifest.yaml -StartupToken token-123 winsmux-orchestra C:\repo\scripts\winsmux-core.ps1'; Name = 'pwsh.exe' }
                }
            }
        }
        Mock Stop-Process { $script:stoppedProcessIds += $Id }

        $result = Stop-OrchestraBackgroundProcessesFromManifest -ProjectDir 'C:\repo' -GitWorktreeDir 'C:\repo\.git' -BridgeScript 'C:\repo\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra'

        @($result.Stopped).Count | Should -Be 3
        @($result.Errors).Count | Should -Be 0
        $script:stoppedProcessIds | Should -Be @(101, 202, 303)
    }

    It 'stops stale background processes recorded in process_registry before legacy pid fields' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                session = [PSCustomObject]@{
                    startup_token = 'token-123'
                    supervisor_pid = '999'
                    process_registry = [PSCustomObject]@{
                        entries = @(
                            [PSCustomObject]@{
                                label = 'supervisor_pid'
                                pid = 707
                                script = 'orchestra-supervisor.ps1'
                            }
                        )
                    }
                }
            }
        }

        $script:stoppedProcessIds = @()
        Mock Get-ProcessSnapshot {
            [PSCustomObject]@{
                ById = @{
                    707 = [PSCustomObject]@{ ProcessId = 707; ParentProcessId = 1; CommandLine = 'pwsh -NoProfile -File orchestra-supervisor.ps1 -ManifestPath C:\repo\.winsmux\manifest.yaml -SessionName winsmux-orchestra -StartupToken token-123'; Name = 'pwsh.exe' }
                    999 = [PSCustomObject]@{ ProcessId = 999; ParentProcessId = 1; CommandLine = 'pwsh -NoProfile -File old-supervisor.ps1 -ManifestPath C:\repo\.winsmux\manifest.yaml -SessionName winsmux-orchestra -StartupToken token-123'; Name = 'pwsh.exe' }
                }
            }
        }
        Mock Stop-Process { $script:stoppedProcessIds += $Id }

        $result = Stop-OrchestraBackgroundProcessesFromManifest -ProjectDir 'C:\repo' -GitWorktreeDir 'C:\repo\.git' -BridgeScript 'C:\repo\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra'

        @($result.Stopped).Count | Should -Be 1
        $result.Stopped[0].label | Should -Be 'supervisor_pid'
        $result.Stopped[0].pid | Should -Be 707
        @($result.Errors).Count | Should -Be 1
        $result.Errors[0] | Should -Match '999'
        $script:stoppedProcessIds | Should -Be @(707)
    }

    It 'stops process_registry entries after a manifest save and read round trip' {
        $testProjectDir = Join-Path $TestDrive 'process-registry-roundtrip'
        New-Item -ItemType Directory -Path $testProjectDir -Force | Out-Null

        Save-OrchestraSessionState `
            -ProjectDir $testProjectDir `
            -SessionName 'winsmux-orchestra' `
            -Settings ([ordered]@{ agent = 'codex'; model = 'gpt-5.4' }) `
            -GitWorktreeDir (Join-Path $testProjectDir '.git\worktrees') `
            -PaneSummaries @() `
            -ExpectedPaneCount 1 `
            -StartupToken 'token-123' `
            -SupervisorPid 707 `
            -IdleThreshold 180 | Out-Null

        $manifestPath = Join-Path $testProjectDir '.winsmux\manifest.yaml'
        (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8) | Should -Match 'process_registry:'

        $script:stoppedProcessIds = @()
        Mock Get-ProcessSnapshot {
            [PSCustomObject]@{
                ById = @{
                    707 = [PSCustomObject]@{ ProcessId = 707; ParentProcessId = 1; CommandLine = "pwsh -NoProfile -File orchestra-supervisor.ps1 -ManifestPath $manifestPath -SessionName winsmux-orchestra -StartupToken token-123"; Name = 'pwsh.exe' }
                }
            }
        }
        Mock Stop-Process { $script:stoppedProcessIds += $Id }

        $result = Stop-OrchestraBackgroundProcessesFromManifest -ProjectDir $testProjectDir -GitWorktreeDir (Join-Path $testProjectDir '.git') -BridgeScript (Join-Path $testProjectDir 'scripts\winsmux-core.ps1') -SessionName 'winsmux-orchestra'

        @($result.Stopped).Count | Should -Be 1
        $result.Stopped[0].pid | Should -Be 707
        @($result.Errors).Count | Should -Be 0
        $script:stoppedProcessIds | Should -Be @(707)
    }

    It 'treats legacy commander_poll_pid as the operator poll process during manifest cleanup' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                session = [PSCustomObject]@{
                    startup_token      = 'token-123'
                    commander_poll_pid = '101'
                }
            }
        }

        $script:stoppedProcessIds = @()
        Mock Get-ProcessSnapshot {
            [PSCustomObject]@{
                ById = @{
                    101 = [PSCustomObject]@{ ProcessId = 101; ParentProcessId = 1; CommandLine = 'pwsh operator-poll.ps1 C:\repo\.winsmux\manifest.yaml -StartupToken token-123 winsmux-orchestra C:\repo\scripts\winsmux-core.ps1'; Name = 'pwsh.exe' }
                }
            }
        }
        Mock Stop-Process { $script:stoppedProcessIds += $Id }

        $result = Stop-OrchestraBackgroundProcessesFromManifest -ProjectDir 'C:\repo' -GitWorktreeDir 'C:\repo\.git' -BridgeScript 'C:\repo\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra'

        @($result.Stopped).Count | Should -Be 1
        $result.Stopped[0].label | Should -Be 'operator_poll_pid'
        @($result.Errors).Count | Should -Be 0
        $script:stoppedProcessIds | Should -Be @(101)
    }

    It 'skips targeted background cleanup when the manifest has no startup token' {
        Mock Get-WinsmuxManifest {
            [PSCustomObject]@{
                session = [PSCustomObject]@{
                    operator_poll_pid = '101'
                }
            }
        }

        Mock Get-ProcessSnapshot { throw 'should not read process snapshot without startup token' }
        Mock Stop-Process { throw 'should not stop any process without startup token' }

        $result = Stop-OrchestraBackgroundProcessesFromManifest -ProjectDir 'C:\repo' -GitWorktreeDir 'C:\repo\.git' -BridgeScript 'C:\repo\scripts\winsmux-core.ps1' -SessionName 'winsmux-orchestra'

        @($result.Stopped).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 1
        $result.Errors[0] | Should -Match 'startup_token'
    }
}
