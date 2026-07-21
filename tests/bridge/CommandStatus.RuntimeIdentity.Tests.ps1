$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'TASK781 runtime identity registry' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\manifest.ps1')

        function New-Task781RuntimeFixture {
            $supervisorStart = '2026-07-15T00:00:00.0000000Z'
            $bootstrapStart = '2026-07-15T00:00:01.0000000Z'
            return [PSCustomObject]@{
                Manifest = [PSCustomObject]@{
                    version = 2
                    session = [PSCustomObject]@{
                        name              = 'winsmux-task781-test'
                        generation_id     = 'generation-1'
                        server_session_id = '$9'
                        bootstrap_pane_id = '%1'
                        expected_pane_count = 1
                        session_ready     = $true
                    }
                    panes = [ordered]@{
                        'worker-1' = [ordered]@{
                            slot_id        = 'worker-1'
                            pane_id        = '%2'
                            worker_backend = 'codex'
                            worker_role    = 'reviewer'
                            role           = 'Reviewer'
                            title          = 'W1 Codex Reviewer'
                            status         = 'ready'
                        }
                    }
                }
                Registry = [PSCustomObject]@{
                    schema_version    = 1
                    status            = 'active'
                    session_name      = 'winsmux-task781-test'
                    generation_id     = 'generation-1'
                    server_session_id = '$9'
                    bootstrap_pane_id = '%1'
                    supervisor        = [PSCustomObject]@{
                        pid                = 4100
                        process_started_at = $supervisorStart
                    }
                    lease = [PSCustomObject]@{
                        state      = 'active'
                        expires_at = '2026-07-15T00:10:00.0000000Z'
                    }
                    expected_pane_count = 1
                    panes = @(
                        [PSCustomObject]@{
                            label                        = 'worker-1'
                            slot_id                      = 'worker-1'
                            pane_id                      = '%2'
                            backend                      = 'codex'
                            role                         = 'reviewer'
                            title                        = 'W1 Codex Reviewer'
                            state                        = 'live'
                            bootstrap_pid                = 4200
                            bootstrap_process_started_at = $bootstrapStart
                        }
                    )
                }
                Entry = [PSCustomObject]@{
                    Label         = 'worker-1'
                    SlotId        = 'worker-1'
                    PaneId        = '%2'
                    WorkerBackend = 'codex'
                    WorkerRole    = 'reviewer'
                    Role          = 'Reviewer'
                    Title         = 'W1 Codex Reviewer'
                    Status        = 'ready'
                }
                Marker = [PSCustomObject]@{
                    generation_id             = 'generation-1'
                    server_session_id         = '$9'
                    slot_id                   = 'worker-1'
                    pane_id                   = '%2'
                    backend                   = 'codex'
                    role                      = 'reviewer'
                    title                     = 'W1 Codex Reviewer'
                    bootstrap_pid             = 4200
                    bootstrap_process_started_at = $bootstrapStart
                }
                Caller = [PSCustomObject]@{
                    process_id                   = 4300
                    process_started_at           = '2026-07-15T00:00:02.0000000Z'
                    generation_id                = 'generation-1'
                    server_session_id            = '$9'
                    slot_id                      = 'worker-1'
                    pane_id                      = '%2'
                    backend                      = 'codex'
                    ancestry                     = @(
                        [PSCustomObject]@{ pid = 4300; process_started_at = '2026-07-15T00:00:02.0000000Z' }
                        [PSCustomObject]@{ pid = 4200; process_started_at = $bootstrapStart }
                    )
                }
                ObservedPanes = @(
                    [PSCustomObject]@{ pane_id = '%2'; title = 'W1 Codex Reviewer' }
                    [PSCustomObject]@{ pane_id = '%1'; title = 'winsmux-orchestra-bootstrap' }
                )
                ProcessResolver = {
                    param([int]$Id)
                    switch ($Id) {
                        4100 { return [PSCustomObject]@{ Id = 4100; StartTime = [datetime]'2026-07-15T00:00:00Z'; ParentProcessId = 1; Name = 'pwsh.exe' } }
                        4200 { return [PSCustomObject]@{ Id = 4200; StartTime = [datetime]'2026-07-15T00:00:01Z'; ParentProcessId = 1; Name = 'pwsh.exe' } }
                        4300 { return [PSCustomObject]@{ Id = 4300; StartTime = [datetime]'2026-07-15T00:00:02Z'; ParentProcessId = 4200; Name = 'codex.exe' } }
                        default { return $null }
                    }
                }
            }
        }

        function Invoke-Task781RuntimeFixture {
            param(
                [Parameter(Mandatory = $true)]$Fixture,
                [ValidateSet('dispatch', 'start_deferred', 'caller_ack', 'stop_transition')][string]$Operation = 'dispatch'
            )

            return Test-WinsmuxRuntimeContext -Manifest $Fixture.Manifest -Registry $Fixture.Registry `
                -ObservedServerSessionId '$9' -ObservedPanes $Fixture.ObservedPanes `
                -ManifestEntry $Fixture.Entry -PaneMarker $Fixture.Marker `
                -CallerIdentity $Fixture.Caller -ProcessResolver $Fixture.ProcessResolver `
                -Operation $Operation -Now ([datetime]'2026-07-15T00:05:00Z')
        }

        function Add-Task781UnrelatedRuntimeSlot {
            param([Parameter(Mandatory = $true)]$Fixture)

            $Fixture.Manifest.panes['worker-2'] = [ordered]@{
                slot_id        = 'worker-2'
                pane_id        = '%3'
                worker_backend = 'api_llm'
                worker_role    = 'worker'
                role           = 'Worker'
                title          = 'W2 API Worker'
                status         = 'ready'
            }
            $Fixture.Registry.panes += [PSCustomObject]@{
                label                        = 'worker-2'
                slot_id                      = 'worker-2'
                pane_id                      = '%3'
                backend                      = 'api_llm'
                role                         = 'worker'
                title                        = 'W2 API Worker'
                state                        = 'live'
                bootstrap_pid                = 4400
                bootstrap_process_started_at = '2026-07-15T00:00:04.0000000Z'
            }
            $Fixture.ObservedPanes += [PSCustomObject]@{ pane_id = '%3'; title = 'W2 API Worker' }
            $Fixture.Manifest.session.expected_pane_count = 2
            $Fixture.Registry.expected_pane_count = 2
            return $Fixture
        }
    }

    BeforeEach {
        $script:task781TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-task781-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:task781TempRoot '.winsmux') -Force | Out-Null
    }

    AfterEach {
        if ($script:task781TempRoot -and (Test-Path -LiteralPath $script:task781TempRoot)) {
            Remove-Item -LiteralPath $script:task781TempRoot -Recurse -Force
        }
    }

    It 'TASK781 refuses invalid supervisor identity' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.supervisor.process_started_at = '2026-07-15T00:00:05.0000000Z'

        $result = Test-WinsmuxRuntimeContext -Manifest $fixture.Manifest -Registry $fixture.Registry `
            -ObservedServerSessionId '$9' -ManifestEntry $fixture.Entry -PaneMarker $fixture.Marker `
            -CallerIdentity $fixture.Caller -ObservedPanes $fixture.ObservedPanes -ProcessResolver $fixture.ProcessResolver `
            -Operation caller_ack -Now ([datetime]'2026-07-15T00:05:00Z')

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'invalid_supervisor_identity'
    }

    It 'TASK781 requires manifest regeneration for unverified or stale session' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Manifest.version = 1

        $result = Test-WinsmuxRuntimeContext -Manifest $fixture.Manifest -Registry $fixture.Registry `
            -ObservedServerSessionId '$9' -ManifestEntry $fixture.Entry -PaneMarker $fixture.Marker `
            -CallerIdentity $fixture.Caller -ObservedPanes $fixture.ObservedPanes -ProcessResolver $fixture.ProcessResolver `
            -Now ([datetime]'2026-07-15T00:05:00Z')

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'manifest_regeneration_required'
    }

    It 'TASK781 refuses mismatched runtime target before deferred start' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.panes[0].backend = 'api_llm'

        $result = Test-WinsmuxRuntimeContext -Manifest $fixture.Manifest -Registry $fixture.Registry `
            -ObservedServerSessionId '$9' -ManifestEntry $fixture.Entry -PaneMarker $fixture.Marker `
            -CallerIdentity $fixture.Caller -ObservedPanes $fixture.ObservedPanes -ProcessResolver $fixture.ProcessResolver `
            -Now ([datetime]'2026-07-15T00:05:00Z')

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'runtime_target_mismatch'
    }

    It 'TASK781 C42 refuses a consistently incomplete runtime pane set' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Manifest.session.expected_pane_count = 6
        $fixture.Registry.expected_pane_count = 6

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'runtime_target_mismatch'
        $result.diagnostic | Should -Match 'pane sets do not match exactly'
    }

    It 'TASK781 C42 requires matching authoritative expected pane counts for <Mode>' -ForEach @(
        @{ Mode = 'missing_manifest_count' }
        @{ Mode = 'registry_count_mismatch' }
    ) {
        $fixture = New-Task781RuntimeFixture
        if ($Mode -eq 'missing_manifest_count') {
            $fixture.Manifest.session.PSObject.Properties.Remove('expected_pane_count')
        } else {
            $fixture.Registry.expected_pane_count = 2
        }

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'manifest_regeneration_required'
    }

    It 'TASK781 refuses spoofed local or Codex caller' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Caller.process_id = 4999

        $result = Test-WinsmuxRuntimeContext -Manifest $fixture.Manifest -Registry $fixture.Registry `
            -ObservedServerSessionId '$9' -ManifestEntry $fixture.Entry -PaneMarker $fixture.Marker `
            -CallerIdentity $fixture.Caller -ObservedPanes $fixture.ObservedPanes -ProcessResolver $fixture.ProcessResolver `
            -Operation caller_ack -Now ([datetime]'2026-07-15T00:05:00Z')

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'caller_identity_mismatch'
    }

    It 'TASK781 accepts fully matched live runtime context' {
        $fixture = New-Task781RuntimeFixture

        $result = Test-WinsmuxRuntimeContext -Manifest $fixture.Manifest -Registry $fixture.Registry `
            -ObservedServerSessionId '$9' -ManifestEntry $fixture.Entry -PaneMarker $fixture.Marker `
            -CallerIdentity $fixture.Caller -ObservedPanes $fixture.ObservedPanes -ProcessResolver $fixture.ProcessResolver `
            -Now ([datetime]'2026-07-15T00:05:00Z')

        $result.valid | Should -BeTrue
        $result.reason_code | Should -Be 'live_runtime_verified'
        $result.context.pane_id | Should -Be '%2'
        $result.context.generation_id | Should -Be 'generation-1'
    }

    It 'TASK781 C46 authorizes an intentional stop transition without the terminated bootstrap process' {
        $fixture = New-Task781RuntimeFixture
        $fixture.ProcessResolver = {
            param([int]$Id)
            if ($Id -eq 4100) {
                return [PSCustomObject]@{ Id = 4100; StartTime = [datetime]'2026-07-15T00:00:00Z'; ParentProcessId = 1; Name = 'pwsh.exe' }
            }
            return $null
        }

        $transition = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation stop_transition
        $dispatch = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation dispatch

        $transition.valid | Should -BeTrue
        $transition.reason_code | Should -Be 'stop_transition_verified'
        $transition.context.generation_id | Should -Be 'generation-1'
        $dispatch.valid | Should -BeFalse
        $dispatch.reason_code | Should -Be 'runtime_target_mismatch'
    }

    It 'TASK781 C49 rejects duplicate v2 pane labels' {
        $content = @'
version: 2
saved_at: '2026-07-15T00:00:00Z'
session:
  name: 'winsmux-orchestra'
panes:
  worker-1:
    pane_id: '%2'
  worker-1:
    pane_id: '%3'
'@

        { ConvertFrom-ManifestYaml -Content $content } | Should -Throw '*duplicate*panes.worker-1*'
    }

    It 'TASK781 C49 rejects duplicate v2 pane identity properties' {
        $content = @'
version: 2
saved_at: '2026-07-15T00:00:00Z'
session:
  name: 'winsmux-orchestra'
panes:
  worker-1:
    pane_id: '%2'
    pane_id: '%3'
'@

        { ConvertFrom-ManifestYaml -Content $content } | Should -Throw '*duplicate*panes.worker-1.pane_id*'
    }

    It 'TASK781 C58 rejects case-variant v2 duplicate <Case>' -ForEach @(
        @{
            Case = 'top-level section'
            Content = @'
version: 2
session:
  name: winsmux-orchestra
Session:
  generation_id: generation-58
'@
        }
        @{
            Case = 'session property'
            Content = @'
version: 2
session:
  name: winsmux-orchestra
  Name: overwritten
'@
        }
        @{
            Case = 'pane label'
            Content = @'
version: 2
panes:
  worker-1:
    pane_id: '%2'
  Worker-1:
    pane_id: '%3'
'@
        }
        @{
            Case = 'pane property'
            Content = @'
version: 2
panes:
  worker-1:
    pane_id: '%2'
    PANE_ID: '%3'
'@
        }
        @{
            Case = 'worktree label'
            Content = @'
version: 2
worktrees:
  worker-1:
    path: C:\repo\one
  Worker-1:
    path: C:\repo\two
'@
        }
        @{
            Case = 'worktree property'
            Content = @'
version: 2
worktrees:
  worker-1:
    path: C:\repo\one
    PATH: C:\repo\two
'@
        }
    ) {
        { ConvertFrom-ManifestYaml -Content $Content } | Should -Throw '*duplicate manifest key*'
    }

    It 'TASK781 C58 preserves case-insensitive last-value parsing for legacy v1 diagnostics' {
        $content = @'
version: 1
panes:
  worker-1:
    pane_id: '%2'
    PANE_ID: '%3'
'@

        $legacy = ConvertFrom-ManifestYaml -Content $content

        $legacy.version | Should -Be 1
        $legacy.panes['worker-1'].pane_id | Should -Be '%3'
    }

    It 'TASK781 C49 preserves v1 diagnostic parsing when a legacy property is duplicated' {
        $content = @'
version: 1
saved_at: '2026-07-15T00:00:00Z'
session:
  name: 'winsmux-orchestra'
panes:
  worker-1:
    pane_id: '%2'
    pane_id: '%3'
'@

        $legacy = ConvertFrom-ManifestYaml -Content $content

        $legacy.version | Should -Be 1
        $legacy.panes['worker-1'].pane_id | Should -Be '%3'
    }

    It 'TASK781 enforces the full desired runtime and observed pane set for <Mode>' -ForEach @(
        @{ Mode = 'registry_missing' }
        @{ Mode = 'registry_extra' }
        @{ Mode = 'backend_drift' }
        @{ Mode = 'role_drift' }
        @{ Mode = 'title_drift' }
        @{ Mode = 'pane_drift' }
        @{ Mode = 'observed_missing' }
        @{ Mode = 'observed_extra' }
        @{ Mode = 'observed_title_drift' }
        @{ Mode = 'bootstrap_missing' }
        @{ Mode = 'bootstrap_duplicate' }
        @{ Mode = 'canonical' }
    ) {
        $fixture = Add-Task781UnrelatedRuntimeSlot -Fixture (New-Task781RuntimeFixture)
        switch ($Mode) {
            'registry_missing'     { $fixture.Registry.panes = @($fixture.Registry.panes[0]) }
            'registry_extra'       {
                $extra = $fixture.Registry.panes[1].PSObject.Copy()
                $extra.label = 'worker-3'; $extra.slot_id = 'worker-3'; $extra.pane_id = '%4'
                $fixture.Registry.panes += $extra
            }
            'backend_drift'        { $fixture.Registry.panes[1].backend = 'codex' }
            'role_drift'           { $fixture.Registry.panes[1].role = 'reviewer' }
            'title_drift'          { $fixture.Registry.panes[1].title = 'wrong title' }
            'pane_drift'           { $fixture.Registry.panes[1].pane_id = '%7' }
            'observed_missing'     { $fixture.ObservedPanes = @($fixture.ObservedPanes[0]) }
            'observed_extra'       { $fixture.ObservedPanes += [PSCustomObject]@{ pane_id = '%9'; title = 'unexpected pane' } }
            'observed_title_drift' { @($fixture.ObservedPanes | Where-Object pane_id -EQ '%3')[0].title = 'wrong title' }
            'bootstrap_missing'    { $fixture.ObservedPanes = @($fixture.ObservedPanes | Where-Object pane_id -NE '%1') }
            'bootstrap_duplicate'  { $fixture.ObservedPanes += [PSCustomObject]@{ pane_id = '%1'; title = 'duplicate bootstrap' } }
        }

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture
        if ($Mode -eq 'canonical') {
            $result.valid | Should -BeTrue
            $result.reason_code | Should -Be 'live_runtime_verified'
        } else {
            $result.valid | Should -BeFalse
            $result.reason_code | Should -Be 'runtime_target_mismatch'
        }
    }

    It 'TASK781 requires matching manifest and registry bootstrap pane identity' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.bootstrap_pane_id = '%8'

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'manifest_regeneration_required'
    }

    It 'TASK781 preserves a verified v2 manifest against <Mode> replacement' -ForEach @(
        @{ Mode = 'schema_downgrade' }
        @{ Mode = 'generation_drift' }
    ) {
        $current = (New-Task781RuntimeFixture).Manifest
        Save-WinsmuxManifest -ProjectDir $script:task781TempRoot -Manifest $current
        $path = Get-ManifestPath -ProjectDir $script:task781TempRoot
        $before = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $replacement = ConvertFrom-ManifestYaml -Content (ConvertTo-ManifestYaml -Manifest $current)
        if ($Mode -eq 'schema_downgrade') {
            $replacement.version = 1
        } else {
            $replacement.session.generation_id = 'generation-stale'
        }

        { Save-WinsmuxManifest -ProjectDir $script:task781TempRoot -Manifest $replacement } | Should -Throw '*Refusing to replace a verified v2 runtime manifest*'

        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $before
        (Get-WinsmuxManifest -ProjectDir $script:task781TempRoot).version | Should -Be 2
    }

    It 'TASK781 refuses a missing supervisor process' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.supervisor.pid = 4999

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation caller_ack

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'invalid_supervisor_identity'
    }

    It 'TASK781 refuses missing or malformed supervisor StartTime' -ForEach @('', 'not-a-time') {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.supervisor.process_started_at = $_

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation caller_ack

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'invalid_supervisor_identity'
    }

    It 'TASK781 refuses an expired supervisor lease' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.lease.expires_at = '2026-07-15T00:04:59.0000000Z'

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation caller_ack

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'invalid_supervisor_identity'
    }

    It 'TASK781 requires regeneration when the registry is missing' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry = $null

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation caller_ack

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'manifest_regeneration_required'
    }

    It 'TASK781 requires regeneration for a stale generation' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.generation_id = 'generation-old'

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation caller_ack

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'manifest_regeneration_required'
    }

    It 'TASK781 requires regeneration for a stale observed server session' {
        $fixture = New-Task781RuntimeFixture

        $result = Test-WinsmuxRuntimeContext -Manifest $fixture.Manifest -Registry $fixture.Registry `
            -ObservedServerSessionId '$8' -ObservedPanes $fixture.ObservedPanes `
            -ManifestEntry $fixture.Entry -PaneMarker $fixture.Marker `
            -CallerIdentity $fixture.Caller -ProcessResolver $fixture.ProcessResolver `
            -Now ([datetime]'2026-07-15T00:05:00Z')

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'manifest_regeneration_required'
    }

    It 'TASK781 refuses duplicate runtime slots' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.panes = @($fixture.Registry.panes[0], $fixture.Registry.panes[0].PSObject.Copy())
        $fixture.Registry.panes[1].pane_id = '%3'

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation caller_ack

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'runtime_target_mismatch'
    }

    It 'TASK781 refuses duplicate runtime panes' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.panes = @($fixture.Registry.panes[0], $fixture.Registry.panes[0].PSObject.Copy())
        $fixture.Registry.panes[1].label = 'worker-2'
        $fixture.Registry.panes[1].slot_id = 'worker-2'

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'runtime_target_mismatch'
    }

    It 'TASK781 refuses pane role title or live-state drift' -ForEach @(
        @{ Property = 'pane_id'; Value = '%7' }
        @{ Property = 'role'; Value = 'builder' }
        @{ Property = 'title'; Value = 'wrong title' }
        @{ Property = 'state'; Value = 'deferred' }
    ) {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.panes[0].$($_.Property) = $_.Value

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'runtime_target_mismatch'
    }

    It 'TASK781 refuses a marker from an old generation' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Marker.generation_id = 'generation-old'

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'runtime_target_mismatch'
    }

    It 'TASK781 refuses environment-only caller evidence' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Caller = [PSCustomObject]@{ pane_id = '%2'; backend = 'codex' }

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation caller_ack

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'caller_identity_mismatch'
    }

    It 'TASK781 refuses a caller with the same PID and a different StartTime' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Caller.process_started_at = '2026-07-15T00:00:03.0000000Z'

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation caller_ack

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'caller_identity_mismatch'
    }

    It 'TASK781 refuses a caller from another backend or generation' -ForEach @(
        @{ Property = 'backend'; Value = 'api_llm' }
        @{ Property = 'generation_id'; Value = 'generation-old' }
    ) {
        $fixture = New-Task781RuntimeFixture
        $fixture.Caller.$($_.Property) = $_.Value

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation caller_ack

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'caller_identity_mismatch'
    }

    It 'TASK781 accepts six of six uniquely matched live slots' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Manifest.panes = [ordered]@{}
        $fixture.Registry.panes = @()
        $fixture.Manifest.session.expected_pane_count = 6
        $fixture.Registry.expected_pane_count = 6
        $fixture.ObservedPanes = @([PSCustomObject]@{ pane_id = '%1'; title = 'winsmux-orchestra-bootstrap' })
        $processes = @{
            4100 = [PSCustomObject]@{ Id = 4100; StartTime = [datetime]'2026-07-15T00:00:00Z'; ParentProcessId = 1; Name = 'pwsh.exe' }
        }

        foreach ($index in 1..6) {
            $label = "worker-$index"
            $paneId = "%$($index + 1)"
            $title = "W$index Codex Reviewer"
            $bootstrapPid = 4200 + $index
            $callerPid = 4300 + $index
            $bootstrapStartedAt = "2026-07-15T00:00:$('{0:D2}' -f $index).0000000Z"
            $callerStartedAt = "2026-07-15T00:01:$('{0:D2}' -f $index).0000000Z"
            $fixture.Manifest.panes[$label] = [ordered]@{
                slot_id = $label; pane_id = $paneId; worker_backend = 'codex'; worker_role = 'reviewer'
                role = 'Reviewer'; title = $title; status = 'ready'
            }
            $fixture.Registry.panes += [PSCustomObject]@{
                label = $label; slot_id = $label; pane_id = $paneId; backend = 'codex'; role = 'reviewer'
                title = $title; state = 'live'; bootstrap_pid = $bootstrapPid
                bootstrap_process_started_at = $bootstrapStartedAt
            }
            $fixture.ObservedPanes += [PSCustomObject]@{ pane_id = $paneId; title = $title }
            $processes[$bootstrapPid] = [PSCustomObject]@{ Id = $bootstrapPid; StartTime = [datetime]$bootstrapStartedAt; ParentProcessId = 1; Name = 'pwsh.exe' }
            $processes[$callerPid] = [PSCustomObject]@{ Id = $callerPid; StartTime = [datetime]$callerStartedAt; ParentProcessId = $bootstrapPid; Name = 'codex.exe' }
        }
        $fixture.ProcessResolver = { param([int]$Id) return $processes[$Id] }

        $verified = 0
        foreach ($index in 1..6) {
            $label = "worker-$index"
            $pane = $fixture.Manifest.panes[$label]
            $runtimePane = $fixture.Registry.panes[$index - 1]
            $callerPid = 4300 + $index
            $callerStartedAt = "2026-07-15T00:01:$('{0:D2}' -f $index).0000000Z"
            $fixture.Entry = [PSCustomObject]@{
                Label = $label; SlotId = $label; PaneId = $pane.pane_id; WorkerBackend = 'codex'
                WorkerRole = 'reviewer'; Role = 'Reviewer'; Title = $pane.title; Status = 'ready'
            }
            $fixture.Marker = [PSCustomObject]@{
                generation_id = 'generation-1'; server_session_id = '$9'; slot_id = $label
                pane_id = $pane.pane_id; backend = 'codex'; role = 'reviewer'; title = $pane.title
                bootstrap_pid = $runtimePane.bootstrap_pid
                bootstrap_process_started_at = $runtimePane.bootstrap_process_started_at
            }
            $fixture.Caller = [PSCustomObject]@{
                process_id = $callerPid; process_started_at = $callerStartedAt; generation_id = 'generation-1'
                server_session_id = '$9'; slot_id = $label; pane_id = $pane.pane_id; backend = 'codex'
                ancestry = @(
                    [PSCustomObject]@{ pid = $callerPid; process_started_at = $callerStartedAt }
                    [PSCustomObject]@{ pid = $runtimePane.bootstrap_pid; process_started_at = $runtimePane.bootstrap_process_started_at }
                )
            }

            $result = Invoke-Task781RuntimeFixture -Fixture $fixture
            if ($result.valid) { $verified++ }
        }

        $verified | Should -Be 6
        (($verified / 6) * 100) | Should -Be 100
    }

    It 'TASK781 rejects unknown future and malformed manifest schemas without throwing' -ForEach @(3, 'future') {
        $fixture = New-Task781RuntimeFixture
        $fixture.Manifest.version = $_

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'manifest_regeneration_required'
    }

    It 'TASK781 refuses supervisor identity when process observation throws' {
        $fixture = New-Task781RuntimeFixture
        $fixture.ProcessResolver = { param([int]$Id) throw "process unavailable: $Id" }

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'invalid_supervisor_identity'
    }

    It 'TASK781 writes and reads a separate supervisor-owned runtime registry' {
        $fixture = New-Task781RuntimeFixture
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-task781-test' -ServerSessionId '$9' `
            -GenerationId 'generation-1' -SupervisorPid 4100 `
            -SupervisorProcessStartedAt '2026-07-15T00:00:00.0000000Z' -ExpectedPaneCount 1 -Panes $fixture.Registry.panes `
            -Now ([datetime]'2026-07-15T00:05:00Z') -LeaseSeconds 15

        $path = Save-WinsmuxRuntimeRegistry -ProjectDir $script:task781TempRoot -Registry $registry
        $read = Read-WinsmuxRuntimeRegistry -ProjectDir $script:task781TempRoot

        $path | Should -Be (Join-Path $script:task781TempRoot '.winsmux\runtime-registry.json')
        $read.schema_version | Should -Be 1
        $read.generation_id | Should -Be 'generation-1'
        $read.expected_pane_count | Should -Be 1
        $read.supervisor.process_started_at | Should -Be '2026-07-15T00:00:00.0000000Z'
        ($read | ConvertTo-Json -Depth 20) | Should -Not -Match 'startup_token|credential|launch_command'
    }

    It 'TASK781 refreshes only the exact generation owner and closes its lease' {
        $fixture = New-Task781RuntimeFixture
        $registry = New-WinsmuxRuntimeRegistryDocument -SessionName 'winsmux-task781-test' -ServerSessionId '$9' `
            -GenerationId 'generation-1' -SupervisorPid 4100 `
            -SupervisorProcessStartedAt '2026-07-15T00:00:00.0000000Z' -ExpectedPaneCount 1 -Panes $fixture.Registry.panes `
            -Now ([datetime]'2026-07-15T00:05:00Z') -LeaseSeconds 15
        Save-WinsmuxRuntimeRegistry -ProjectDir $script:task781TempRoot -Registry $registry | Out-Null

        { Update-WinsmuxRuntimeRegistryLease -ProjectDir $script:task781TempRoot -GenerationId 'generation-old' `
            -SupervisorPid 4100 -SupervisorProcessStartedAt '2026-07-15T00:00:00.0000000Z' `
            -Now ([datetime]'2026-07-15T00:05:05Z') } | Should -Throw '*does not own this generation*'

        $refreshed = Update-WinsmuxRuntimeRegistryLease -ProjectDir $script:task781TempRoot -GenerationId 'generation-1' `
            -SupervisorPid 4100 -SupervisorProcessStartedAt '2026-07-15T00:00:00.0000000Z' `
            -Now ([datetime]'2026-07-15T00:05:05Z') -LeaseSeconds 15
        $refreshed.lease.expires_at | Should -Be '2026-07-15T00:05:20.0000000Z'

        $foreignSessionClose = Close-WinsmuxRuntimeRegistry -ProjectDir $script:task781TempRoot -GenerationId 'generation-1' `
            -SupervisorPid 4100 -SupervisorProcessStartedAt '2026-07-15T00:00:00.0000000Z' `
            -ExpectedSessionName 'winsmux-other' -ExpectedServerSessionId '$9'
        $foreignSessionClose | Should -BeFalse
        (Read-WinsmuxRuntimeRegistry -ProjectDir $script:task781TempRoot).status | Should -Be 'active'

        $foreignServerClose = Close-WinsmuxRuntimeRegistry -ProjectDir $script:task781TempRoot -GenerationId 'generation-1' `
            -SupervisorPid 4100 -SupervisorProcessStartedAt '2026-07-15T00:00:00.0000000Z' `
            -ExpectedSessionName 'winsmux-task781-test' -ExpectedServerSessionId '$10'
        $foreignServerClose | Should -BeFalse
        (Read-WinsmuxRuntimeRegistry -ProjectDir $script:task781TempRoot).status | Should -Be 'active'

        $closed = Close-WinsmuxRuntimeRegistry -ProjectDir $script:task781TempRoot -GenerationId 'generation-1' `
            -SupervisorPid 4100 -SupervisorProcessStartedAt '2026-07-15T00:00:00.0000000Z' `
            -ExpectedSessionName 'winsmux-task781-test' -ExpectedServerSessionId '$9' `
            -Now ([datetime]'2026-07-15T00:05:06Z')
        $closed | Should -BeTrue
        $ended = Read-WinsmuxRuntimeRegistry -ProjectDir $script:task781TempRoot
        $ended.status | Should -Be 'ended'
        $ended.lease.state | Should -Be 'ended'
        $ended.lease.expires_at | Should -Be '2026-07-15T00:05:06.0000000Z'
    }

    It 'TASK781 allows operator dispatch without treating the operator PID as the pane caller' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Caller = $null

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation dispatch

        $result.valid | Should -BeTrue
        $result.reason_code | Should -Be 'live_runtime_verified'
    }

    It 'TASK781 accepts caller acknowledgement only with observed ancestry to the bootstrap' {
        $fixture = New-Task781RuntimeFixture

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation caller_ack

        $result.valid | Should -BeTrue
        $result.reason_code | Should -Be 'live_runtime_verified'
    }

    It 'TASK781 ignores self-reported ancestry when the OS parent chain does not reach bootstrap' {
        $fixture = New-Task781RuntimeFixture
        $fixture.ProcessResolver = {
            param([int]$Id)
            switch ($Id) {
                4100 { [PSCustomObject]@{ Id = 4100; StartTime = [datetime]'2026-07-15T00:00:00Z'; ParentProcessId = 1; Name = 'pwsh.exe' } }
                4200 { [PSCustomObject]@{ Id = 4200; StartTime = [datetime]'2026-07-15T00:00:01Z'; ParentProcessId = 1; Name = 'pwsh.exe' } }
                4300 { [PSCustomObject]@{ Id = 4300; StartTime = [datetime]'2026-07-15T00:00:02Z'; ParentProcessId = 4999; Name = 'codex.exe' } }
                default { $null }
            }
        }

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation caller_ack

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'caller_identity_mismatch'
    }

    It 'TASK781 refuses Codex acknowledgement without a Codex process in the observed chain' {
        $fixture = New-Task781RuntimeFixture
        $fixture.ProcessResolver = {
            param([int]$Id)
            switch ($Id) {
                4100 { [PSCustomObject]@{ Id = 4100; StartTime = [datetime]'2026-07-15T00:00:00Z'; ParentProcessId = 1; Name = 'pwsh.exe' } }
                4200 { [PSCustomObject]@{ Id = 4200; StartTime = [datetime]'2026-07-15T00:00:01Z'; ParentProcessId = 1; Name = 'pwsh.exe' } }
                4300 { [PSCustomObject]@{ Id = 4300; StartTime = [datetime]'2026-07-15T00:00:02Z'; ParentProcessId = 4200; Name = 'pwsh.exe' } }
                default { $null }
            }
        }

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation caller_ack

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'caller_identity_mismatch'
    }

    It 'TASK781 allows deferred start only for a verified deferred registry entry' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.panes[0].state = 'deferred'
        $fixture.Registry.panes[0].bootstrap_pid = 0
        $fixture.Registry.panes[0].bootstrap_process_started_at = ''
        $fixture.Manifest.panes['worker-1'].status = 'deferred_start'
        $fixture.Entry.Status = 'deferred_start'
        $fixture.Marker = $null

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation start_deferred

        $result.valid | Should -BeTrue
        $result.reason_code | Should -Be 'deferred_runtime_verified'
    }

    It 'TASK781 C15 allows retry start for a verified failed deferred registry entry' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.panes[0].state = 'deferred'
        $fixture.Registry.panes[0].bootstrap_pid = 0
        $fixture.Registry.panes[0].bootstrap_process_started_at = ''
        $fixture.Manifest.panes['worker-1'].status = 'deferred_start_failed'
        $fixture.Entry.Status = 'deferred_start_failed'
        $fixture.Marker = $null

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation start_deferred

        $result.reason_code | Should -Be 'deferred_runtime_verified'
        $result.valid | Should -BeTrue
        $fixture.Registry.lease.state | Should -Be 'active'
        $fixture.Registry.panes[0].state | Should -Be 'deferred'
    }

    It 'TASK781 C32 allows an authenticated current-generation failed marker to be reused without duplicate bootstrap' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.panes[0].state = 'deferred'
        $fixture.Registry.panes[0].bootstrap_pid = 0
        $fixture.Registry.panes[0].bootstrap_process_started_at = ''
        $fixture.Manifest.panes['worker-1'].status = 'deferred_start_failed'
        $fixture.Entry.Status = 'deferred_start_failed'
        $fixture.Marker | Add-Member -NotePropertyName state -NotePropertyValue 'bootstrap_pending'

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation start_deferred

        $result.valid | Should -BeTrue
        $result.reason_code | Should -Be 'deferred_retry_marker_verified'
        [string]$result.context.retry_marker_state | Should -Be 'live'
        $fixture.Registry.panes[0].state | Should -Be 'deferred'
    }

    It 'TASK781 C73 authenticates a deferred-starting marker so readiness failure can become retryable' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.panes[0].state = 'deferred'
        $fixture.Registry.panes[0].bootstrap_pid = 0
        $fixture.Registry.panes[0].bootstrap_process_started_at = ''
        $fixture.Manifest.panes['worker-1'].status = 'deferred_starting'
        $fixture.Entry.Status = 'deferred_starting'
        $fixture.Marker | Add-Member -NotePropertyName state -NotePropertyValue 'bootstrap_pending'

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation start_deferred

        $result.valid | Should -BeTrue
        $result.reason_code | Should -Be 'deferred_starting_marker_verified'
        [string]$result.context.marker_process_state | Should -Be 'live'
        $fixture.Registry.panes[0].state | Should -Be 'deferred'
    }

    It 'TASK781 C32 refuses a failed deferred retry marker with a different generation' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.panes[0].state = 'deferred'
        $fixture.Registry.panes[0].bootstrap_pid = 0
        $fixture.Registry.panes[0].bootstrap_process_started_at = ''
        $fixture.Manifest.panes['worker-1'].status = 'deferred_start_failed'
        $fixture.Entry.Status = 'deferred_start_failed'
        $fixture.Marker | Add-Member -NotePropertyName state -NotePropertyValue 'bootstrap_pending'
        $fixture.Marker.generation_id = 'generation-stale'

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation start_deferred

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'runtime_target_mismatch'
    }

    It 'TASK781 keeps bootstrap-pending panes unavailable to dispatch' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.panes[0].state = 'bootstrap_pending'

        $result = Invoke-Task781RuntimeFixture -Fixture $fixture -Operation dispatch

        $result.valid | Should -BeFalse
        $result.reason_code | Should -Be 'runtime_target_mismatch'
    }

    It 'TASK781 refuses live registry overwrite and permits only ended or expired-dead replacement' {
        $fixture = New-Task781RuntimeFixture
        (Test-WinsmuxRuntimeRegistryReplacementAllowed -Registry $fixture.Registry -ProcessResolver $fixture.ProcessResolver `
            -Now ([datetime]'2026-07-15T00:05:00Z')) | Should -BeFalse

        $fixture.Registry.lease.expires_at = '2026-07-15T00:04:00.0000000Z'
        (Test-WinsmuxRuntimeRegistryReplacementAllowed -Registry $fixture.Registry -ProcessResolver $fixture.ProcessResolver `
            -Now ([datetime]'2026-07-15T00:05:00Z')) | Should -BeFalse

        $fixture.Registry.supervisor.pid = 4999
        (Test-WinsmuxRuntimeRegistryReplacementAllowed -Registry $fixture.Registry -ProcessResolver $fixture.ProcessResolver `
            -Now ([datetime]'2026-07-15T00:05:00Z')) | Should -BeTrue

        $fixture.Registry.status = 'ended'
        (Test-WinsmuxRuntimeRegistryReplacementAllowed -Registry $fixture.Registry -ProcessResolver $fixture.ProcessResolver `
            -Now ([datetime]'2026-07-15T00:05:00Z')) | Should -BeTrue
    }

    It 'TASK781 builds an ancestry resolver from a single secret-free CIM snapshot' {
        $resolver = New-WinsmuxProcessSnapshotResolver -Snapshots @(
            [PSCustomObject]@{ ProcessId = 4200; ParentProcessId = 1; CreationDate = [datetime]'2026-07-15T00:00:01Z'; Name = 'pwsh.exe' }
            [PSCustomObject]@{ ProcessId = 4300; ParentProcessId = 4200; CreationDate = [datetime]'2026-07-15T00:00:02Z'; Name = 'codex.exe' }
        )

        $snapshot = & $resolver 4300
        $snapshot.Id | Should -Be 4300
        $snapshot.ParentProcessId | Should -Be 4200
        $snapshot.StartTime | Should -Be '2026-07-15T00:00:02.0000000Z'
        ($snapshot.PSObject.Properties.Name) | Should -Not -Contain 'CommandLine'
    }

    It 'TASK781 normalizes six default worker roles identically across manifest marker and registry' {
        $roles = foreach ($index in 1..6) {
            Resolve-WinsmuxRuntimeRole -WorkerRole '' -CanonicalRole 'Worker'
        }

        $roles.Count | Should -Be 6
        @($roles | Where-Object { $_ -cne 'worker' }).Count | Should -Be 0
    }

    It 'TASK781 retains incomplete live process rows as unverifiable identities and rejects duplicate process IDs' {
        $resolver = New-WinsmuxProcessSnapshotResolver -Snapshots @(
            [PSCustomObject]@{ ProcessId = 999; ParentProcessId = $null; CreationDate = $null; Name = '' }
            [PSCustomObject]@{ ProcessId = 4300; ParentProcessId = 4200; CreationDate = [datetime]'2026-07-15T00:00:02Z'; Name = 'codex.exe' }
        )
        (& $resolver 4300).Id | Should -Be 4300
        $incomplete = & $resolver 999
        $incomplete.Id | Should -Be 999
        (Test-WinsmuxStrictProcessIdentity -ProcessId 999 -ExpectedStartTime '2026-07-15T00:00:01.0000000Z' -ProcessResolver $resolver) |
            Should -BeFalse

        { New-WinsmuxProcessSnapshotResolver -Snapshots @(
                [PSCustomObject]@{ ProcessId = 4300; ParentProcessId = 4200; CreationDate = [datetime]'2026-07-15T00:00:02Z'; Name = 'codex.exe' }
                [PSCustomObject]@{ ProcessId = 4300; ParentProcessId = 1; CreationDate = [datetime]'2026-07-15T00:00:03Z'; Name = 'codex.exe' }
            ) } | Should -Throw '*duplicate process identity*'
    }

    It 'TASK781 refuses expired registry replacement when the live owner identity is incomplete' {
        $fixture = New-Task781RuntimeFixture
        $fixture.Registry.lease.expires_at = '2026-07-15T00:04:00.0000000Z'
        $fixture.ProcessResolver = {
            param([int]$Id)
            if ($Id -eq 4100) {
                return [PSCustomObject]@{ Id = 4100; ParentProcessId = 1; StartTime = ''; Name = 'pwsh.exe' }
            }
            return $null
        }

        (Test-WinsmuxRuntimeRegistryReplacementAllowed -Registry $fixture.Registry -ProcessResolver $fixture.ProcessResolver `
            -Now ([datetime]'2026-07-15T00:05:00Z')) | Should -BeFalse
    }
}
