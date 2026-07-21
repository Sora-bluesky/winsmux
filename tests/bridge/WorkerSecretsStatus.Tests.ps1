$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'desktop orchestra launcher contracts' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $script:BridgeTestsRoot
        $script:settingsContent = Get-Content -LiteralPath (Join-Path $script:repoRoot 'winsmux-core\scripts\settings.ps1') -Raw -Encoding UTF8
        $script:bridgeContent = Get-Content -LiteralPath (Join-Path $script:repoRoot 'scripts\winsmux-core.ps1') -Raw -Encoding UTF8
        $script:attachContent = Get-Content -LiteralPath (Join-Path $script:repoRoot 'winsmux-core\scripts\orchestra-attach.ps1') -Raw -Encoding UTF8
        $script:uiAttachContent = Get-Content -LiteralPath (Join-Path $script:repoRoot 'winsmux-core\scripts\orchestra-ui-attach.ps1') -Raw -Encoding UTF8
    }

    It 'prefers the release winsmux executable before debug fallback' {
        $settingsReleaseIndex = $script:settingsContent.IndexOf("target\release\winsmux.exe")
        $settingsDebugIndex = $script:settingsContent.IndexOf("target\debug\winsmux.exe")
        $bridgeReleaseIndex = $script:bridgeContent.IndexOf("target\release\winsmux.exe")
        $bridgeDebugIndex = $script:bridgeContent.IndexOf("target\debug\winsmux.exe")

        $settingsReleaseIndex | Should -BeGreaterThan -1
        $settingsDebugIndex | Should -BeGreaterThan -1
        $settingsReleaseIndex | Should -BeLessThan $settingsDebugIndex
        $bridgeReleaseIndex | Should -BeGreaterThan -1
        $bridgeDebugIndex | Should -BeGreaterThan -1
        $bridgeReleaseIndex | Should -BeLessThan $bridgeDebugIndex
    }

    It 'uses the shared winsmux executable resolver for orchestra attach' {
        $script:attachContent | Should -Match "\. \(Join-Path [`$]scriptsRoot 'settings\.ps1'\)"
        $script:attachContent | Should -Match '\$winsmuxPath\s*=\s*Get-WinsmuxBin'
        $script:attachContent | Should -Not -Match "Get-Command 'winsmux'"
    }

    It 'can disable Windows Terminal visible attach from desktop child processes' {
        $script:uiAttachContent | Should -Match 'WINSMUX_ORCHESTRA_DISABLE_WINDOWS_TERMINAL_ATTACH'
        $script:uiAttachContent | Should -Match 'windows_terminal_attach_disabled'
        $script:uiAttachContent | Should -Match 'WINSMUX_ORCHESTRA_DISABLE_POWERSHELL_ATTACH'
    }
}

Describe 'winsmux workers command' {
BeforeAll {
        $script:winsmuxWorkersCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxWorkersCoreRawContent = Get-Content -LiteralPath $script:winsmuxWorkersCorePath -Raw -Encoding UTF8
        . $script:winsmuxWorkersCorePath 'version' *> $null

        function New-Task781WorkersStopFixture {
            param([Parameter(Mandatory = $true)][string]$ProjectDir)

            $bootstrapRoot = Join-Path (Join-Path $ProjectDir '.winsmux') 'orchestra-bootstrap'
            New-Item -ItemType Directory -Path $bootstrapRoot -Force | Out-Null
            $planPath = Join-Path $bootstrapRoot '_2.json'
            $markerPath = Join-Path $bootstrapRoot '_2-synthetic.ready.json'
            '{}' | Set-Content -LiteralPath $planPath -Encoding UTF8
            '{}' | Set-Content -LiteralPath $markerPath -Encoding UTF8

            $entry = [PSCustomObject]@{
                Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; Status = 'ready'; RuntimeReady = $true
                ManifestPath = 'synthetic-manifest'; BootstrapPlanPath = $planPath; BootstrapMarkerPath = $markerPath
            }
            $row = [PSCustomObject]@{
                Slot = 'w1'; SlotId = 'worker-1'; PaneId = '%2'; Backend = 'codex'; State = 'ready'
                LastFailureStage = ''; RecoveryAction = ''; ApprovedLaunch = $null; CurrentLaunch = $null; ApprovalDifferences = @()
            }
            $entriesBySlot = @{}
            $entriesBySlot['worker-1'] = $entry

            return [PSCustomObject]@{
                Entry = $entry; Row = $row; EntriesBySlot = $entriesBySlot; MarkerPath = $markerPath
            }
        }
    }

BeforeEach {
        $script:workersTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-workers-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:workersTempRoot -Force | Out-Null
        $script:previousWorkersNow = $env:WINSMUX_TEST_NOW_UTC
        $script:previousPublicOpenRouterApiKey = $env:OPENROUTER_API_KEY
        $script:previousAntigravityCli = $env:WINSMUX_ANTIGRAVITY_CLI
        $script:previousAntigravityPrintTimeout = $env:WINSMUX_ANTIGRAVITY_PRINT_TIMEOUT
        $env:WINSMUX_TEST_NOW_UTC = ''
        $env:OPENROUTER_API_KEY = ''
        $env:WINSMUX_ANTIGRAVITY_CLI = ''
        $env:WINSMUX_ANTIGRAVITY_PRINT_TIMEOUT = ''
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation)
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode ("{0}_verified" -f $Operation) `
                -Diagnostic 'synthetic worker runtime verified' -Context ([ordered]@{ generation_id = 'generation-workers' })
        }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            [PSCustomObject]@{ Managed = $true; Operation = 'dispatch'; GenerationId = 'generation-workers' }
        }
    }

It 'TASK781 C55 passes the initially captured generation and operation to every workers-start lifecycle write' {
        $startIndex = $script:winsmuxWorkersCoreRawContent.IndexOf('function Invoke-WorkersStart {', [System.StringComparison]::Ordinal)
        $stopIndex = $script:winsmuxWorkersCoreRawContent.IndexOf('function Invoke-WorkersStop {', [System.StringComparison]::Ordinal)
        $startIndex | Should -BeGreaterOrEqual 0
        $stopIndex | Should -BeGreaterThan $startIndex
        $functionText = $script:winsmuxWorkersCoreRawContent.Substring($startIndex, $stopIndex - $startIndex)
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($functionText, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $commands = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Set-WorkersManifestLifecycleCommand'
        }, $true))

        $commands.Count | Should -Be 4
        foreach ($command in $commands) {
            $command.Extent.Text | Should -Match '-ExpectedGenerationId\s+\$runtimeGenerationId'
            $command.Extent.Text | Should -Match '-RuntimeOperation\s+(?:\$runtimeOperation|dispatch)'
        }
    }

It 'TASK781 blocks workers start before pane launch or manifest writes when runtime identity is invalid' {
        $entry = [PSCustomObject]@{ Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; Status = 'deferred_start'; ManifestPath = 'synthetic-manifest' }
        $row = [PSCustomObject]@{
            Slot = 'w1'; SlotId = 'worker-1'; PaneId = '%2'; Backend = 'codex'; State = 'deferred_start'
            LastFailureStage = ''; RecoveryAction = ''; ApprovedLaunch = $null; CurrentLaunch = $null; ApprovalDifferences = @()
        }
        $entriesBySlot = @{}; $entriesBySlot['worker-1'] = $entry
        Mock Read-WorkersOptions { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; Target = 'all'; Json = $true } }
        Mock Get-WorkersLifecycleContext { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; EntriesBySlot = $entriesBySlot } }
        Mock Get-WorkersStatusRows { @($row) }
        Mock Test-PaneControlRuntimeContext { New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'invalid_supervisor_identity' -Diagnostic 'stale supervisor' }
        Mock Start-DeferredPaneFromManifestEntry { throw 'pane start must not occur' }
        Mock Set-WorkersManifestLifecycleCommand { throw 'manifest write must not occur' }
        Mock Write-WorkersLifecycleOutput { param($ProjectDir, $Results, [switch]$Json) $script:task781WorkersResult = @($Results) }

        Invoke-WorkersStart

        $script:task781WorkersResult.Count | Should -Be 1
        $script:task781WorkersResult[0].status | Should -Be 'blocked'
        $script:task781WorkersResult[0].reason_code | Should -Be 'invalid_supervisor_identity'
        Assert-MockCalled Start-DeferredPaneFromManifestEntry -Times 0 -Exactly
        Assert-MockCalled Set-WorkersManifestLifecycleCommand -Times 0 -Exactly
    }

It 'TASK781 C29 preserves a runtime refusal from deferred workers start without repair metadata writes' {
        $entry = [PSCustomObject]@{
            Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; Status = 'deferred_start'; ManifestPath = 'synthetic-manifest'
        }
        $row = [PSCustomObject]@{
            Slot = 'w1'; SlotId = 'worker-1'; PaneId = '%2'; Backend = 'codex'; State = 'deferred_start'
            LastFailureStage = ''; RecoveryAction = ''; ApprovedLaunch = $null; CurrentLaunch = $null; ApprovalDifferences = @()
        }
        $entriesBySlot = @{}; $entriesBySlot['worker-1'] = $entry
        $script:task781WorkersStartWrites = 0
        Mock Read-WorkersOptions { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; Target = 'all'; Json = $true } }
        Mock Get-WorkersLifecycleContext { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; EntriesBySlot = $entriesBySlot } }
        Mock Get-WorkersStatusRows { @($row) }
        Mock Start-DeferredPaneFromManifestEntry {
            throw 'runtime dispatch refused (invalid_supervisor_identity): generation expired during deferred startup'
        }
        Mock Set-WorkersManifestLifecycleCommand { $script:task781WorkersStartWrites++ }
        Mock Write-WorkersLifecycleOutput {
            param($ProjectDir, $Results, [switch]$Json)
            $script:task781WorkersResult = @($Results)
        }

        Invoke-WorkersStart

        $script:task781WorkersResult.Count | Should -Be 1
        $script:task781WorkersResult[0].status | Should -Be 'blocked'
        $script:task781WorkersResult[0].reason_code | Should -Be 'invalid_supervisor_identity'
        $script:task781WorkersResult[0].diagnostic | Should -Be 'generation expired during deferred startup'
        $script:task781WorkersStartWrites | Should -Be 0
    }

It 'TASK781 blocks workers stop before respawn or manifest writes when runtime identity is invalid' {
        $entry = [PSCustomObject]@{ Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; Status = 'ready'; ManifestPath = 'synthetic-manifest' }
        $row = [PSCustomObject]@{
            Slot = 'w1'; SlotId = 'worker-1'; PaneId = '%2'; Backend = 'codex'; State = 'ready'
            LastFailureStage = ''; RecoveryAction = ''; ApprovedLaunch = $null; CurrentLaunch = $null; ApprovalDifferences = @()
        }
        $entriesBySlot = @{}; $entriesBySlot['worker-1'] = $entry
        Mock Read-WorkersOptions { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; Target = 'all'; Json = $true } }
        Mock Get-WorkersLifecycleContext { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; EntriesBySlot = $entriesBySlot } }
        Mock Get-WorkersStatusRows { @($row) }
        Mock Test-PaneControlRuntimeContext { New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'runtime_target_mismatch' -Diagnostic 'stale pane mapping' }
        Mock Invoke-WinsmuxRaw { throw 'respawn must not occur' }
        Mock Set-WorkersManifestLifecycleCommand { throw 'manifest write must not occur' }
        Mock Write-WorkersLifecycleOutput { param($ProjectDir, $Results, [switch]$Json) $script:task781WorkersResult = @($Results) }

        Invoke-WorkersStop

        $script:task781WorkersResult.Count | Should -Be 1
        $script:task781WorkersResult[0].status | Should -Be 'blocked'
        $script:task781WorkersResult[0].reason_code | Should -Be 'runtime_target_mismatch'
        Assert-MockCalled Invoke-WinsmuxRaw -Times 0 -Exactly
        Assert-MockCalled Set-WorkersManifestLifecycleCommand -Times 0 -Exactly
    }

It 'TASK781 C28 blocks workers stop when the runtime generation expires immediately before respawn' {
        $fixture = New-Task781WorkersStopFixture -ProjectDir $script:workersTempRoot
        $script:c28Results = @()

        Mock Read-WorkersOptions { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; Target = 'all'; Json = $true } }
        Mock Get-WorkersLifecycleContext {
            [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; EntriesBySlot = $fixture.EntriesBySlot }
        }
        Mock Get-WorkersStatusRows { @($fixture.Row) }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            throw 'runtime dispatch refused (invalid_supervisor_identity): generation expired before workers stop respawn'
        }
        Mock Invoke-WinsmuxRaw { throw 'respawn must not occur after lease expiry' }
        Mock Set-WorkersManifestLifecycleCommand { throw 'manifest write must not occur after lease expiry' }
        Mock Write-WorkersLifecycleOutput {
            param($ProjectDir, $Results, [switch]$Json)
            $script:c28Results = @($Results)
        }

        Invoke-WorkersStop

        $script:c28Results.Count | Should -Be 1
        $script:c28Results[0].status | Should -Be 'blocked'
        $script:c28Results[0].reason_code | Should -Be 'invalid_supervisor_identity'
        $script:c28Results[0].diagnostic | Should -Be 'generation expired before workers stop respawn'
        Assert-MockCalled Assert-WinsmuxTargetRuntimeWriteAllowed -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%2' -and
            $CurrentProjectDir -eq $script:workersTempRoot -and
            $Operation -eq 'dispatch' -and
            $ExpectedGenerationId -eq 'generation-workers'
        }
        Assert-MockCalled Invoke-WinsmuxRaw -Times 0 -Exactly
        Assert-MockCalled Set-WorkersManifestLifecycleCommand -Times 0 -Exactly
    }

It 'TASK781 C43 blocks the marker-cleanup failure write when the generation expires after respawn' {
        $fixture = New-Task781WorkersStopFixture -ProjectDir $script:workersTempRoot
        $script:c43GuardCount = 0
        $script:c43LifecycleWriteCount = 0
        $script:c43Results = @()

        Mock Read-WorkersOptions { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; Target = 'all'; Json = $true } }
        Mock Get-WorkersLifecycleContext {
            [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; EntriesBySlot = $fixture.EntriesBySlot }
        }
        Mock Get-WorkersStatusRows { @($fixture.Row) }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            $script:c43GuardCount++
            if ($script:c43GuardCount -eq 3) {
                throw 'runtime dispatch refused (invalid_supervisor_identity): generation expired before marker-failure state write'
            }
            [PSCustomObject]@{ Managed = $true; Operation = 'dispatch'; GenerationId = 'generation-workers' }
        }
        Mock Invoke-WinsmuxRaw { $null }
        Mock Get-SafeLastExitCode { 0 }
        Mock Remove-WorkersStoppedBootstrapMarker { throw 'synthetic marker cleanup failure' }
        Mock Set-WorkersManifestLifecycleCommand { $script:c43LifecycleWriteCount++ }
        Mock Write-WorkersLifecycleOutput {
            param($ProjectDir, $Results, [switch]$Json)
            $script:c43Results = @($Results)
        }

        Invoke-WorkersStop

        $script:c43GuardCount | Should -Be 3
        $script:c43LifecycleWriteCount | Should -Be 0
        $script:c43Results.Count | Should -Be 1
        $script:c43Results[0].status | Should -Be 'failed'
        $script:c43Results[0].reason | Should -Match 'generation expired before marker-failure state write'
        Assert-MockCalled Invoke-WinsmuxRaw -Times 1 -Exactly
    }

It 'TASK781 C43 blocks the deferred-state write when the generation expires after marker cleanup' {
        $fixture = New-Task781WorkersStopFixture -ProjectDir $script:workersTempRoot
        $script:c43GuardCount = 0
        $script:c43LifecycleWriteCount = 0
        $script:c43Results = @()

        Mock Read-WorkersOptions { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; Target = 'all'; Json = $true } }
        Mock Get-WorkersLifecycleContext {
            [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; EntriesBySlot = $fixture.EntriesBySlot }
        }
        Mock Get-WorkersStatusRows { @($fixture.Row) }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            $script:c43GuardCount++
            if ($script:c43GuardCount -eq 3) {
                throw 'runtime dispatch refused (invalid_supervisor_identity): generation expired before deferred-state write'
            }
            [PSCustomObject]@{ Managed = $true; Operation = 'dispatch'; GenerationId = 'generation-workers' }
        }
        Mock Invoke-WinsmuxRaw { $null }
        Mock Get-SafeLastExitCode { 0 }
        Mock Remove-WorkersStoppedBootstrapMarker { $true }
        Mock Set-WorkersManifestLifecycleCommand { $script:c43LifecycleWriteCount++ }
        Mock Write-WorkersLifecycleOutput {
            param($ProjectDir, $Results, [switch]$Json)
            $script:c43Results = @($Results)
        }

        Invoke-WorkersStop

        $script:c43GuardCount | Should -Be 3
        $script:c43LifecycleWriteCount | Should -Be 0
        $script:c43Results.Count | Should -Be 1
        $script:c43Results[0].status | Should -Be 'failed'
        $script:c43Results[0].reason | Should -Match 'generation expired before deferred-state write'
    }

It 'TASK781 C43 revalidates separately before read-mark and watermark cleanup' {
        $fixture = New-Task781WorkersStopFixture -ProjectDir $script:workersTempRoot
        $script:c43GuardCount = 0
        $script:c43LifecycleWriteCount = 0
        $script:c43ReadClearCount = 0
        $script:c43WatermarkClearCount = 0
        $script:c43Results = @()

        Mock Read-WorkersOptions { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; Target = 'all'; Json = $true } }
        Mock Get-WorkersLifecycleContext {
            [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; EntriesBySlot = $fixture.EntriesBySlot }
        }
        Mock Get-WorkersStatusRows { @($fixture.Row) }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            $script:c43GuardCount++
            if ($script:c43GuardCount -eq 5) {
                throw 'runtime dispatch refused (invalid_supervisor_identity): generation expired before watermark cleanup'
            }
            [PSCustomObject]@{ Managed = $true; Operation = 'dispatch'; GenerationId = 'generation-workers' }
        }
        Mock Invoke-WinsmuxRaw { $null }
        Mock Get-SafeLastExitCode { 0 }
        Mock Remove-WorkersStoppedBootstrapMarker { $true }
        Mock Set-WorkersManifestLifecycleCommand { $script:c43LifecycleWriteCount++ }
        Mock Get-PaneControlManifestContext { $fixture.Entry }
        Mock Wait-PaneControlRuntimeContext {
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'start_deferred_verified' `
                -Diagnostic 'synthetic deferred runtime verified' -Context ([ordered]@{ generation_id = 'generation-workers' })
        }
        Mock Clear-ReadMark { $script:c43ReadClearCount++ }
        Mock Clear-Watermark { $script:c43WatermarkClearCount++ }
        Mock Write-WorkersLifecycleOutput {
            param($ProjectDir, $Results, [switch]$Json)
            $script:c43Results = @($Results)
        }

        Invoke-WorkersStop

        $script:c43GuardCount | Should -Be 5
        $script:c43LifecycleWriteCount | Should -Be 1
        $script:c43ReadClearCount | Should -Be 1
        $script:c43WatermarkClearCount | Should -Be 0
        $script:c43Results.Count | Should -Be 1
        $script:c43Results[0].status | Should -Be 'failed'
        $script:c43Results[0].reason | Should -Match 'generation expired before watermark cleanup'
    }

It 'TASK781 C46 uses stop-transition guards only after respawn and deferred guards after the manifest transition' {
        $fixture = New-Task781WorkersStopFixture -ProjectDir $script:workersTempRoot
        $script:c46Operations = [System.Collections.Generic.List[string]]::new()
        $script:c46Results = @()

        Mock Read-WorkersOptions { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; Target = 'all'; Json = $true } }
        Mock Get-WorkersLifecycleContext {
            [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; EntriesBySlot = $fixture.EntriesBySlot }
        }
        Mock Get-WorkersStatusRows { @($fixture.Row) }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            param($PaneId, $CurrentProjectDir, $Operation, $ExpectedGenerationId)
            $script:c46Operations.Add([string]$Operation)
            [PSCustomObject]@{
                Managed = $true
                Operation = [string]$Operation
                GenerationId = 'generation-workers'
            }
        }
        Mock Invoke-WinsmuxRaw { $null }
        Mock Get-SafeLastExitCode { 0 }
        Mock Remove-WorkersStoppedBootstrapMarker { $true }
        Mock Set-WorkersManifestLifecycleCommand {}
        Mock Get-PaneControlManifestContext { $fixture.Entry }
        Mock Wait-PaneControlRuntimeContext {
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'start_deferred_verified' `
                -Diagnostic 'synthetic deferred runtime verified' -Context ([ordered]@{ generation_id = 'generation-workers' })
        }
        Mock Clear-ReadMark {}
        Mock Clear-Watermark {}
        Mock Write-WorkersLifecycleOutput {
            param($ProjectDir, $Results, [switch]$Json)
            $script:c46Results = @($Results)
        }

        Invoke-WorkersStop

        ($script:c46Operations.ToArray() | ConvertTo-Json -Compress) |
            Should -Be ((@('dispatch', 'stop_transition', 'stop_transition', 'start_deferred', 'start_deferred') | ConvertTo-Json -Compress))
        $script:c46Results.Count | Should -Be 1
        $script:c46Results[0].status | Should -Be 'stopped'
    }

It 'TASK781 C13 preserves ready state when workers stop respawn fails before the stop boundary' {
        $fixture = New-Task781WorkersStopFixture -ProjectDir $script:workersTempRoot
        $script:c13LifecycleWrites = [System.Collections.Generic.List[object]]::new()
        $script:c13ReadClearCount = 0
        $script:c13WatermarkClearCount = 0
        $script:c13Results = @()

        Mock Read-WorkersOptions { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; Target = 'all'; Json = $true } }
        Mock Get-WorkersLifecycleContext {
            [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; EntriesBySlot = $fixture.EntriesBySlot }
        }
        Mock Get-WorkersStatusRows { @($fixture.Row) }
        Mock Set-WorkersManifestLifecycleCommand {
            param($Entry, $CommandName, $Status, $ExtraProperties)
            $runtimeReady = if ($null -ne $ExtraProperties -and $ExtraProperties.Contains('runtime_ready')) {
                [bool]$ExtraProperties['runtime_ready']
            } else {
                $null
            }
            $script:c13LifecycleWrites.Add([PSCustomObject][ordered]@{
                command_name = [string]$CommandName
                status = [string]$Status
                runtime_ready = $runtimeReady
            }) | Out-Null
            if (-not [string]::IsNullOrWhiteSpace([string]$Status)) {
                $Entry.Status = [string]$Status
            }
            if ($null -ne $runtimeReady) {
                $Entry.RuntimeReady = [bool]$runtimeReady
            }
        }
        Mock Invoke-WinsmuxRaw { throw 'synthetic respawn failure before stop boundary' }
        Mock Clear-ReadMark { $script:c13ReadClearCount++ }
        Mock Clear-Watermark { $script:c13WatermarkClearCount++ }
        Mock Write-WorkersLifecycleOutput {
            param($ProjectDir, $Results, [switch]$Json)
            $script:c13Results = @($Results)
        }

        Invoke-WorkersStop

        $actual = [ordered]@{
            result_status = [string]$script:c13Results[0].status
            reason = [string]$script:c13Results[0].reason
            failed_stage = [string]$script:c13Results[0].failed_stage
            recovery_action = [string]$script:c13Results[0].recovery_action
            lifecycle_writes = @($script:c13LifecycleWrites)
            entry_status = [string]$fixture.Entry.Status
            runtime_ready = [bool]$fixture.Entry.RuntimeReady
            marker_exists = Test-Path -LiteralPath $fixture.MarkerPath -PathType Leaf
            read_clears = $script:c13ReadClearCount
            watermark_clears = $script:c13WatermarkClearCount
        }
        $expected = [ordered]@{
            result_status = 'failed'
            reason = 'stop_respawn_failed'
            failed_stage = 'pane_stop'
            recovery_action = 'inspect-pane-and-rerun-workers-stop'
            lifecycle_writes = @()
            entry_status = 'ready'
            runtime_ready = $true
            marker_exists = $true
            read_clears = 0
            watermark_clears = 0
        }
        ($actual | ConvertTo-Json -Depth 8 -Compress) | Should -Be ($expected | ConvertTo-Json -Depth 8 -Compress)
    }

It 'TASK781 C13 records explicit failed state when marker cleanup fails after the stop boundary' {
        $fixture = New-Task781WorkersStopFixture -ProjectDir $script:workersTempRoot
        $script:c13LifecycleWrites = [System.Collections.Generic.List[object]]::new()
        $script:c13WaitCount = 0
        $script:c13ReadClearCount = 0
        $script:c13WatermarkClearCount = 0
        $script:c13Results = @()

        Mock Read-WorkersOptions { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; Target = 'all'; Json = $true } }
        Mock Get-WorkersLifecycleContext {
            [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; EntriesBySlot = $fixture.EntriesBySlot }
        }
        Mock Get-WorkersStatusRows { @($fixture.Row) }
        Mock Set-WorkersManifestLifecycleCommand {
            param($Entry, $CommandName, $Status, $ExtraProperties)
            $runtimeReady = if ($null -ne $ExtraProperties -and $ExtraProperties.Contains('runtime_ready')) {
                [bool]$ExtraProperties['runtime_ready']
            } else {
                $null
            }
            $failureStage = if ($null -ne $ExtraProperties -and $ExtraProperties.Contains('last_failure_stage')) {
                [string]$ExtraProperties['last_failure_stage']
            } else {
                ''
            }
            $recoveryAction = if ($null -ne $ExtraProperties -and $ExtraProperties.Contains('recovery_action')) {
                [string]$ExtraProperties['recovery_action']
            } else {
                ''
            }
            $script:c13LifecycleWrites.Add([PSCustomObject][ordered]@{
                command_name = [string]$CommandName
                status = [string]$Status
                runtime_ready = $runtimeReady
                last_failure_stage = $failureStage
                recovery_action = $recoveryAction
            }) | Out-Null
            if (-not [string]::IsNullOrWhiteSpace([string]$Status)) {
                $Entry.Status = [string]$Status
            }
            if ($null -ne $runtimeReady) {
                $Entry.RuntimeReady = [bool]$runtimeReady
            }
        }
        Mock Invoke-WinsmuxRaw { @() }
        Mock Get-SafeLastExitCode { 0 }
        Mock Remove-WorkersStoppedBootstrapMarker { throw 'synthetic marker cleanup failure after stop boundary' }
        Mock Wait-PaneControlRuntimeContext {
            $script:c13WaitCount++
            throw 'deferred runtime wait must not occur after marker cleanup failure'
        }
        Mock Clear-ReadMark { $script:c13ReadClearCount++ }
        Mock Clear-Watermark { $script:c13WatermarkClearCount++ }
        Mock Write-WorkersLifecycleOutput {
            param($ProjectDir, $Results, [switch]$Json)
            $script:c13Results = @($Results)
        }

        Invoke-WorkersStop

        $actual = [ordered]@{
            result_status = [string]$script:c13Results[0].status
            reason = [string]$script:c13Results[0].reason
            failed_stage = [string]$script:c13Results[0].failed_stage
            recovery_action = [string]$script:c13Results[0].recovery_action
            lifecycle_writes = @($script:c13LifecycleWrites)
            entry_status = [string]$fixture.Entry.Status
            runtime_ready = [bool]$fixture.Entry.RuntimeReady
            runtime_waits = $script:c13WaitCount
            read_clears = $script:c13ReadClearCount
            watermark_clears = $script:c13WatermarkClearCount
        }
        $expected = [ordered]@{
            result_status = 'failed'
            reason = 'stop_marker_cleanup_failed'
            failed_stage = 'marker_cleanup'
            recovery_action = 'inspect-bootstrap-marker-and-rerun-workers-stop'
            lifecycle_writes = @([PSCustomObject][ordered]@{
                command_name = 'workers.stop'
                status = 'deferred_start_failed'
                runtime_ready = $false
                last_failure_stage = 'marker_cleanup'
                recovery_action = 'inspect-bootstrap-marker-and-rerun-workers-stop'
            })
            entry_status = 'deferred_start_failed'
            runtime_ready = $false
            runtime_waits = 0
            read_clears = 0
            watermark_clears = 0
        }
        ($actual | ConvertTo-Json -Depth 8 -Compress) | Should -Be ($expected | ConvertTo-Json -Depth 8 -Compress)
    }

It 'TASK781 removes the stopped bootstrap marker and permits the default stop then start sequence' {
        $bootstrapRoot = Join-Path (Join-Path $script:workersTempRoot '.winsmux') 'orchestra-bootstrap'
        New-Item -ItemType Directory -Path $bootstrapRoot -Force | Out-Null
        $planPath = Join-Path $bootstrapRoot '_2.json'
        $markerPath = Join-Path $bootstrapRoot '_2-synthetic.ready.json'
        '{}' | Set-Content -LiteralPath $planPath -Encoding UTF8
        '{}' | Set-Content -LiteralPath $markerPath -Encoding UTF8

        $entry = [PSCustomObject]@{
            Label = 'worker-1'; SlotId = 'worker-1'; PaneId = '%2'; Status = 'ready'; RuntimeReady = $true
            ManifestPath = 'synthetic-manifest'; BootstrapPlanPath = $planPath; BootstrapMarkerPath = $markerPath
        }
        $row = [PSCustomObject]@{
            Slot = 'w1'; SlotId = 'worker-1'; PaneId = '%2'; Backend = 'codex'; State = 'ready'
            LastFailureStage = ''; RecoveryAction = ''; ApprovedLaunch = $null; CurrentLaunch = $null; ApprovalDifferences = @()
        }
        $entriesBySlot = @{}; $entriesBySlot['worker-1'] = $entry
        $script:task781RuntimeOperations = [System.Collections.Generic.List[string]]::new()
        $script:task781LifecycleStatuses = [System.Collections.Generic.List[string]]::new()
        $script:task781StartSawMarkerAbsent = $false
        Mock Read-WorkersOptions { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; Target = 'all'; Json = $true } }
        Mock Get-WorkersLifecycleContext { [PSCustomObject]@{ ProjectDir = $script:workersTempRoot; EntriesBySlot = $entriesBySlot } }
        Mock Get-WorkersStatusRows { @($row) }
        Mock Test-PaneControlRuntimeContext {
            param($ProjectDir, $ManifestEntry, $Operation)
            $script:task781RuntimeOperations.Add([string]$Operation) | Out-Null
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode ("{0}_verified" -f $Operation) `
                -Diagnostic 'verified' -Context ([ordered]@{ generation_id = 'generation-workers' })
        }
        Mock Set-WorkersManifestLifecycleCommand {
            param($Entry, $CommandName, $Status, $ExtraProperties)
            if (-not [string]::IsNullOrWhiteSpace([string]$Status)) {
                $Entry.Status = [string]$Status
                $script:task781LifecycleStatuses.Add([string]$Status) | Out-Null
            }
            if ($null -ne $ExtraProperties -and $ExtraProperties.Contains('runtime_ready')) {
                $Entry.RuntimeReady = [bool]$ExtraProperties['runtime_ready']
            }
        }
        Mock Invoke-WinsmuxRaw { @() }
        Mock Get-SafeLastExitCode { 0 }
        Mock Get-PaneControlManifestContext { $entry }
        Mock Clear-ReadMark {}
        Mock Clear-Watermark {}
        Mock Start-DeferredPaneFromManifestEntry {
            $script:task781StartSawMarkerAbsent = -not (Test-Path -LiteralPath $markerPath -PathType Leaf)
            $entry.Status = 'ready'
            $entry.RuntimeReady = $true
            return $true
        }
        Mock Write-WorkersLifecycleOutput {}

        Invoke-WorkersStop
        $runtimeReadyAfterStop = $entry.RuntimeReady
        Invoke-WorkersStart

        Test-Path -LiteralPath $markerPath -PathType Leaf | Should -BeFalse
        $script:task781StartSawMarkerAbsent | Should -BeTrue
        @($script:task781RuntimeOperations) | Should -Be @('dispatch', 'start_deferred', 'start_deferred', 'dispatch')
        @($script:task781LifecycleStatuses) | Should -Be @('deferred_start', 'ready')
        $runtimeReadyAfterStop | Should -BeFalse
        $entry.RuntimeReady | Should -BeTrue
        Assert-MockCalled Invoke-WinsmuxRaw -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'respawn-pane' }
        Assert-MockCalled Start-DeferredPaneFromManifestEntry -Times 1 -Exactly
    }

It 'TASK781 rejects bootstrap marker cleanup outside the managed bootstrap directory' {
        $bootstrapRoot = Join-Path (Join-Path $script:workersTempRoot '.winsmux') 'orchestra-bootstrap'
        New-Item -ItemType Directory -Path $bootstrapRoot -Force | Out-Null
        $planPath = Join-Path $bootstrapRoot '_2.json'
        $outsideMarker = Join-Path $script:workersTempRoot '_2-synthetic.ready.json'
        '{}' | Set-Content -LiteralPath $planPath -Encoding UTF8
        '{}' | Set-Content -LiteralPath $outsideMarker -Encoding UTF8
        $entry = [pscustomobject]@{
            BootstrapPlanPath = $planPath
            BootstrapMarkerPath = $outsideMarker
        }

        { Resolve-WorkersStoppedBootstrapMarkerPath -ProjectDir $script:workersTempRoot -Entry $entry } |
            Should -Throw '*escaped the orchestra bootstrap directory*'
        Test-Path -LiteralPath $outsideMarker -PathType Leaf | Should -BeTrue
    }

It 'TASK781 C12 returns process exit <ExpectedExitCode> for workers <Action> with <RuntimeState> runtime and parseable <OutputMode> output' -ForEach @(
        @{ Action = 'status'; RuntimeValid = $false; RuntimeState = 'invalid'; OutputMode = 'json'; ExpectedExitCode = 1 }
        @{ Action = 'status'; RuntimeValid = $true; RuntimeState = 'valid'; OutputMode = 'text'; ExpectedExitCode = 0 }
        @{ Action = 'doctor'; RuntimeValid = $false; RuntimeState = 'invalid'; OutputMode = 'json'; ExpectedExitCode = 1 }
        @{ Action = 'doctor'; RuntimeValid = $true; RuntimeState = 'valid'; OutputMode = 'text'; ExpectedExitCode = 0 }
    ) {
        $dispatchMarker = '# --- Dispatch ---'
        ([regex]::Matches($script:winsmuxWorkersCoreRawContent, [regex]::Escape($dispatchMarker))).Count | Should -Be 1
        $syntheticOverrides = @'
$script:syntheticRuntimeValid = [bool]::Parse([string]$env:WINSMUX_C12_RUNTIME_VALID)
$script:syntheticRow = [pscustomobject][ordered]@{
    Slot                   = 'w1'
    SlotId                 = 'worker-1'
    PaneId                 = '%2'
    State                  = 'ready'
    PaneState              = 'ready'
    ManifestStatus         = 'ready'
    Backend                = 'codex'
    Role                   = 'reviewer'
    ExecutionProfile       = 'local-windows'
    Provider               = 'codex'
    Model                  = 'gpt-5.5'
    ModelSource            = 'operator-override'
    ReasoningEffort        = 'high'
    PromptTransport        = 'argv'
    McpMode                = ''
    AuthMode               = 'local-cli'
    AuthPolicy             = ''
    CapabilityAdapter      = ''
    CredentialRequirements = 'local-cli-owned'
    ExecutionBackend       = 'local'
    ApiBaseUrl             = ''
    ApiKeyEnv              = ''
    ApiKeyEnvStatus        = ''
    CredentialStatus       = ''
    AnalysisPosture        = 'read-only-review'
    LastFailureStage       = ''
    LastFailureReason      = ''
    RecoveryAction         = ''
    LastCommand            = ''
    LastCommandAt          = ''
    ApprovedLaunch         = $null
    CurrentLaunch          = $null
    ApprovalDifferences    = @()
    LaunchCommand          = ''
    LaunchCommandStatus    = 'available'
    LaunchCommandError     = ''
    Heartbeat              = $null
    HeartbeatHealth        = ''
    HeartbeatState         = ''
    Workspace              = $null
    SecretProjection       = $null
    Broker                 = $null
    Policy                 = $null
}

function Read-WorkersOptions {
    param([string[]]$Tokens, [string]$Usage, [string]$DefaultTarget)

    return [pscustomobject]@{
        ProjectDir = 'C:\synthetic-winsmux'
        Target     = if ([string]::IsNullOrWhiteSpace($DefaultTarget)) { '' } else { $DefaultTarget }
        Json       = @($Tokens) -contains '--json'
    }
}

function Get-WorkersLifecycleContext {
    param([string]$ProjectDir)

    return [pscustomobject]@{
        ProjectDir    = $ProjectDir
        Slots         = @()
        EntriesBySlot = @{}
        ManifestError = ''
    }
}

function Get-WorkersStatusRows {
    param($Context)
    return @($script:syntheticRow)
}

function Add-WorkersRuntimeValidity {
    param($Context, [object[]]$Rows)

    $reasonCode = if ($script:syntheticRuntimeValid) { 'dispatch_verified' } else { 'invalid_supervisor_identity' }
    $diagnostic = if ($script:syntheticRuntimeValid) { 'synthetic runtime verified' } else { 'synthetic supervisor is stale' }
    foreach ($row in @($Rows)) {
        $row | Add-Member -NotePropertyName RuntimeValid -NotePropertyValue $script:syntheticRuntimeValid -Force
        $row | Add-Member -NotePropertyName RuntimeState -NotePropertyValue $(if ($script:syntheticRuntimeValid) { [string]$row.State } else { 'runtime_invalid' }) -Force
        $row | Add-Member -NotePropertyName RuntimeReasonCode -NotePropertyValue $reasonCode -Force
        $row | Add-Member -NotePropertyName RuntimeDiagnostic -NotePropertyValue $diagnostic -Force
    }
    return @($Rows)
}
'@
        $syntheticCorePath = Join-Path (
            Split-Path -Parent $script:winsmuxWorkersCorePath
        ) ('winsmux-core.c12-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $syntheticCoreContent = $script:winsmuxWorkersCoreRawContent.Replace(
            $dispatchMarker,
            "$syntheticOverrides`r`n$dispatchMarker"
        )
        $previousRuntimeValid = $env:WINSMUX_C12_RUNTIME_VALID
        try {
            [IO.File]::WriteAllText($syntheticCorePath, $syntheticCoreContent, [Text.UTF8Encoding]::new($false))
            $env:WINSMUX_C12_RUNTIME_VALID = ([bool]$RuntimeValid).ToString()
            $childArguments = @('-NoProfile', '-File', $syntheticCorePath, 'workers', $Action)
            if ($OutputMode -eq 'json') {
                $childArguments += '--json'
            }
            $output = @(& pwsh @childArguments 2>&1 | ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE
        } finally {
            $env:WINSMUX_C12_RUNTIME_VALID = $previousRuntimeValid
            Remove-Item -LiteralPath $syntheticCorePath -Force -ErrorAction SilentlyContinue
        }

        $outputText = ($output -join "`n").Trim()
        if ($OutputMode -eq 'json') {
            $payload = $outputText | ConvertFrom-Json -ErrorAction Stop
            [bool]$payload.runtime_valid | Should -Be ([bool]$RuntimeValid)
            if ($Action -eq 'status') {
                @($payload.workers).Count | Should -Be 1
                [bool]$payload.workers[0].runtime_valid | Should -Be ([bool]$RuntimeValid)
            } else {
                $runtimeCheck = @($payload.checks | Where-Object { $_.label -eq 'runtime identity' })
                $runtimeCheck.Count | Should -Be 1
                $runtimeCheck[0].status | Should -Be $(if ($RuntimeValid) { 'pass' } else { 'fail' })
            }
        } elseif ($Action -eq 'status') {
            $lines = @($outputText -split '\r?\n')
            @($lines | Where-Object { $_ -match '^Slot\s+SlotId\s+RuntimeState\s+' }).Count | Should -Be 1
            $workerLine = @($lines | Where-Object { $_ -match '^w1\s+worker-1\s+' })
            $workerLine.Count | Should -Be 1
            $workerLine[0] | Should -Match '\sTrue(?:\s|$)'
        } else {
            $lines = @($outputText -split '\r?\n')
            $lines[0] | Should -Be '=== winsmux workers doctor ==='
            $runtimeLine = @($lines | Where-Object { $_ -match '^\[PASS\] runtime identity: ' })
            $runtimeLine.Count | Should -Be 1
            $runtimeLine[0] | Should -Match '1 worker runtime identities verified$'
        }

        $exitCode | Should -Be $ExpectedExitCode -Because "$Action with $RuntimeState runtime emitted parseable $OutputMode output: $outputText"
    }

AfterEach {
        $env:WINSMUX_TEST_NOW_UTC = $script:previousWorkersNow
        $env:OPENROUTER_API_KEY = $script:previousPublicOpenRouterApiKey
        $env:WINSMUX_ANTIGRAVITY_CLI = $script:previousAntigravityCli
        $env:WINSMUX_ANTIGRAVITY_PRINT_TIMEOUT = $script:previousAntigravityPrintTimeout
        if ($script:workersTempRoot -and (Test-Path -LiteralPath $script:workersTempRoot)) {
            Remove-Item -LiteralPath $script:workersTempRoot -Recurse -Force
        }

        Remove-Item function:\winsmux -ErrorAction SilentlyContinue
    }

function script:New-WorkersFakeAntigravityCli {
        param(
            [int]$ExitCode = 0,
            [string]$OutputLine = 'fake-antigravity response',
            [switch]$EmptyStdout
        )

        $fakeCli = Join-Path $script:workersTempRoot 'agy.cmd'
        $argsPath = Join-Path $script:workersTempRoot 'agy-args.txt'
        $outputCommand = if ($EmptyStdout) { 'rem intentionally empty stdout' } else { "echo $OutputLine" }
$content = @'
@echo off
if "%1"=="--help" (
  echo Usage: agy --print PROMPT --print-timeout DURATION --model MODEL
  exit /b 0
)
echo %* > "__ARGS_PATH__"
__OUTPUT_COMMAND__
exit /b __EXIT_CODE__
'@
        $content.Replace('__EXIT_CODE__', [string]$ExitCode).Replace('__OUTPUT_COMMAND__', $outputCommand).Replace('__ARGS_PATH__', $argsPath) | Set-Content -Path $fakeCli -Encoding ASCII
        $env:WINSMUX_ANTIGRAVITY_CLI = $fakeCli
        return $fakeCli
    }

function script:Write-WorkersAntigravityProjectConfig {
@'
agent: codex
model: provider-default
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: antigravity
    worker-role: impl
    agent: antigravity
    model: gemini-3.5-flash
    model-source: operator-override
    prompt-transport: file
    auth-mode: antigravity-official-cli
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot '.winsmux') -Force | Out-Null
@'
{
  "version": 1,
  "providers": {
    "antigravity": {
      "adapter": "antigravity",
      "display_name": "Antigravity CLI",
      "command": "agy",
      "prompt_transports": ["argv", "file"],
      "auth_modes": ["antigravity-official-cli"],
      "model_sources": ["provider-default", "cli-discovery", "operator-override"],
      "credential_requirements": "local-cli-owned",
      "execution_backend": "antigravity-cli-print",
      "runtime_requirements": "Antigravity CLI agy installed in the pane environment.",
      "analysis_posture": "read-write-worker",
      "supports_file_edit": true,
      "supports_structured_result": true
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux\provider-capabilities.json') -Encoding UTF8
    }

function script:Write-WorkersApiLlmProjectConfig {
@'
agent: codex
model: provider-default
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: api_llm
    worker-role: impl
    agent: openrouter
    model: z-ai/glm-5.2
    model-source: operator-override
    prompt-transport: file
    auth-mode: api-key-env
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot '.winsmux') -Force | Out-Null
@'
{
  "version": 1,
  "providers": {
    "openrouter": {
      "adapter": "openai-compatible",
      "display_name": "OpenRouter",
      "command": "openrouter",
      "prompt_transports": ["file"],
      "auth_modes": ["api-key-env", "api-key-vault"],
      "model_sources": ["provider-default", "operator-override"],
      "reasoning_efforts": ["provider-default"],
      "credential_requirements": "runtime-owned-api-key",
      "execution_backend": "openai-compatible-chat-completions",
      "api_base_url": "https://openrouter.ai/api/v1",
      "api_key_env": "OPENROUTER_API_KEY",
      "analysis_posture": "hosted-api-worker",
      "supports_file_edit": false,
      "supports_structured_result": true
    }
  }
}
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux\provider-capabilities.json') -Encoding UTF8
    }

It 'projects typed secrets for local Windows runs without printing secret values' {
@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    execution-profile: local-windows
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        $previousVaultMode = $env:WINSMUX_TEST_SECRET_VAULT_MODE
        $previousVaultJson = $env:WINSMUX_TEST_SECRET_VAULT_JSON
        $env:WINSMUX_TEST_SECRET_VAULT_MODE = '1'
        $env:WINSMUX_TEST_SECRET_VAULT_JSON = '{"api":"local-secret-token-123","cert":"CERT-DATA-456","var":"variable-secret-789"}'
        $runDir = Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-2\secret-local'

        try {
            $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers secrets project w2 --run-id secret-local --env OPENAI_API_KEY=api --file creds/token.txt=cert --variable model_token=var --json --project-dir $script:workersTempRoot
            $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
            $serialized = $payload | ConvertTo-Json -Depth 24

            $payload.status | Should -Be 'projected'
            $payload.execution_profile | Should -Be 'local-windows'
            $payload.binding | Should -Be 'late-bound-at-run-start'
            $payload.scope.slot_id | Should -Be 'worker-2'
            $payload.scope.run_id | Should -Be 'secret-local'
            $payload.value_policy.output_contains_secret_values | Should -Be $false
            $payload.value_policy.manifest_contains_secret_values | Should -Be $false
            @($payload.projections | ForEach-Object { $_.kind }) | Should -Contain 'env'
            @($payload.projections | ForEach-Object { $_.kind }) | Should -Contain 'file'
            @($payload.projections | ForEach-Object { $_.kind }) | Should -Contain 'variable'
            $serialized | Should -Not -Match 'local-secret-token-123'
            $serialized | Should -Not -Match 'CERT-DATA-456'
            $serialized | Should -Not -Match 'variable-secret-789'

            (Get-Content -Raw -Path (Join-Path $runDir 'secrets\env.ps1')) | Should -Match 'local-secret-token-123'
            (Get-Content -Raw -Path (Join-Path $runDir 'secrets\files\creds\token.txt')) | Should -Match 'CERT-DATA-456'
            (Get-Content -Raw -Path (Join-Path $runDir 'secrets\variables.json')) | Should -Match 'variable-secret-789'
        } finally {
            $env:WINSMUX_TEST_SECRET_VAULT_MODE = $previousVaultMode
            $env:WINSMUX_TEST_SECRET_VAULT_JSON = $previousVaultJson
        }
    }

It 'projects typed secrets for isolated workspace runs under the isolated run boundary' {
@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    execution-profile: isolated-enterprise
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        'payload' | Set-Content -Path (Join-Path $script:workersTempRoot 'input.txt') -Encoding UTF8
        $previousVaultMode = $env:WINSMUX_TEST_SECRET_VAULT_MODE
        $previousVaultJson = $env:WINSMUX_TEST_SECRET_VAULT_JSON
        $env:WINSMUX_TEST_SECRET_VAULT_MODE = '1'
        $env:WINSMUX_TEST_SECRET_VAULT_JSON = '{"api":"isolated-secret-token"}'
        $runDir = Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\secret-isolated'

        try {
            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id secret-isolated --json --project-dir $script:workersTempRoot | Out-Null

            $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers secrets project w2 --run-id secret-isolated --profile isolated-enterprise --env OPENAI_API_KEY=api --json --project-dir $script:workersTempRoot
            $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
            $serialized = $payload | ConvertTo-Json -Depth 24

            $payload.status | Should -Be 'projected'
            $payload.execution_profile | Should -Be 'isolated-enterprise'
            $payload.locations.secrets.reference | Should -Match '\.winsmux/isolated-workspaces/worker-2/secret-isolated/secrets'
            $serialized | Should -Not -Match 'isolated-secret-token'
            (Get-Content -Raw -Path (Join-Path $runDir 'secrets\env.ps1')) | Should -Match 'isolated-secret-token'
        } finally {
            $env:WINSMUX_TEST_SECRET_VAULT_MODE = $previousVaultMode
            $env:WINSMUX_TEST_SECRET_VAULT_JSON = $previousVaultJson
        }
    }

It 'includes execution profile workspace and secret projection state in status rows for desktop consumers' {
@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    execution-profile: isolated-enterprise
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:workersTempRoot '.winsmux') -Force | Out-Null
        Save-WinsmuxManifest -ProjectDir $script:workersTempRoot -Manifest ([ordered]@{
            version = 1
            saved_at = '2026-05-16T00:00:00Z'
            session = [ordered]@{
                name = 'winsmux-orchestra'
                project_dir = $script:workersTempRoot
                git_worktree_dir = (Join-Path $script:workersTempRoot '.git')
            }
            panes = [ordered]@{
                'worker-2' = [ordered]@{
                    pane_id = '%2'
                    slot_id = 'worker-2'
                    worker_backend = 'local'
                    role = 'Worker'
                    launch_dir = $script:workersTempRoot
                    status = 'ready'
                }
            }
            tasks = [ordered]@{
                queued = @()
                in_progress = @()
                completed = @()
            }
            worktrees = [ordered]@{}
        })
        'payload' | Set-Content -Path (Join-Path $script:workersTempRoot 'input.txt') -Encoding UTF8
        $previousVaultMode = $env:WINSMUX_TEST_SECRET_VAULT_MODE
        $previousVaultJson = $env:WINSMUX_TEST_SECRET_VAULT_JSON
        $previousNow = $env:WINSMUX_TEST_NOW_UTC
        $env:WINSMUX_TEST_SECRET_VAULT_MODE = '1'
        $env:WINSMUX_TEST_SECRET_VAULT_JSON = '{"api":"desktop-secret-token"}'
        $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:00Z'

        try {
            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id desktop-profile --json --project-dir $script:workersTempRoot | Out-Null
            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers secrets project w2 --run-id desktop-profile --profile isolated-enterprise --env OPENAI_API_KEY=api --json --project-dir $script:workersTempRoot | Out-Null
            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers heartbeat mark w2 --run-id desktop-profile --profile isolated-enterprise --state offline --message 'credential refresh required' --json --project-dir $script:workersTempRoot | Out-Null

            $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status worker-2 --json --project-dir $script:workersTempRoot
            $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
            $row = @($payload.workers)[0]

            $row.execution_profile | Should -Be 'isolated-enterprise'
            $row.state | Should -Be 'offline'
            $row.heartbeat_health | Should -Be 'offline'
            $row.heartbeat.message | Should -Be 'credential refresh required'
            $row.workspace.type | Should -Be 'isolated-workspace'
            $row.workspace.status | Should -Be 'prepared'
            $row.workspace.lifecycle | Should -Be 'disposable'
            $row.workspace.workspace | Should -Be '.winsmux/isolated-workspaces/worker-2/desktop-profile/workspace'
            $row.workspace.manifest | Should -Be '.winsmux/isolated-workspaces/worker-2/desktop-profile/workspace.json'
            $row.secret_projection.status | Should -Be 'projected'
            $row.secret_projection.binding | Should -Be 'late-bound-at-run-start'
            $row.secret_projection.projection_count | Should -Be '1'
            $row.secret_projection.manifest | Should -Be '.winsmux/isolated-workspaces/worker-2/desktop-profile/secrets/secret-projection.json'
            $row.secret_projection.value_output | Should -Be $false

            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id desktop-profile-next --json --project-dir $script:workersTempRoot | Out-Null

            $nextOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status worker-2 --json --project-dir $script:workersTempRoot
            $nextPayload = ($nextOutput | Select-Object -Last 1) | ConvertFrom-Json
            $nextRow = @($nextPayload.workers)[0]

            $nextRow.workspace.run_id | Should -Be 'desktop-profile-next'
            $nextRow.workspace.status | Should -Be 'prepared'
            $nextRow.secret_projection | Should -BeNullOrEmpty

            & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace cleanup w2 --run-id desktop-profile --json --project-dir $script:workersTempRoot | Out-Null

            $afterOldCleanupOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status worker-2 --json --project-dir $script:workersTempRoot
            $afterOldCleanupPayload = ($afterOldCleanupOutput | Select-Object -Last 1) | ConvertFrom-Json
            $afterOldCleanupRow = @($afterOldCleanupPayload.workers)[0]

            $afterOldCleanupRow.workspace.run_id | Should -Be 'desktop-profile-next'
            $afterOldCleanupRow.workspace.status | Should -Be 'prepared'
            $afterOldCleanupRow.secret_projection | Should -BeNullOrEmpty
        } finally {
            $env:WINSMUX_TEST_SECRET_VAULT_MODE = $previousVaultMode
            $env:WINSMUX_TEST_SECRET_VAULT_JSON = $previousVaultJson
            $env:WINSMUX_TEST_NOW_UTC = $previousNow
        }
    }

It 'rejects unsafe or unresolved secret projections before writing files' {
@'
agent: codex
model: gpt-5.4
agent-slots:
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: local
    execution-profile: local-windows
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8
        $previousVaultMode = $env:WINSMUX_TEST_SECRET_VAULT_MODE
        $previousVaultJson = $env:WINSMUX_TEST_SECRET_VAULT_JSON
        $env:WINSMUX_TEST_SECRET_VAULT_MODE = '1'
        $env:WINSMUX_TEST_SECRET_VAULT_JSON = '{"api":"secret-value"}'

        try {
            $invalidEnv = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers secrets project w2 --run-id bad-env --env 1BAD=api --json --project-dir $script:workersTempRoot 2>&1
            $LASTEXITCODE | Should -Be 1
            ($invalidEnv | Out-String) | Should -Match 'valid variable name'

            $escapeFile = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers secrets project w2 --run-id bad-file --file ..\token.txt=api --json --project-dir $script:workersTempRoot 2>&1
            $LASTEXITCODE | Should -Be 1
            ($escapeFile | Out-String) | Should -Match 'unsupported path segment'

            $missing = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers secrets project w2 --run-id missing-key --env API_TOKEN=missing --json --project-dir $script:workersTempRoot 2>&1
            $LASTEXITCODE | Should -Be 1
            ($missing | Out-String) | Should -Match 'credential not found'

            Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-2\bad-env') | Should -Be $false
            Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-2\bad-file') | Should -Be $false
            Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\worker-runs\worker-2\missing-key') | Should -Be $false
        } finally {
            $env:WINSMUX_TEST_SECRET_VAULT_MODE = $previousVaultMode
            $env:WINSMUX_TEST_SECRET_VAULT_JSON = $previousVaultJson
        }
    }

It 'reports MCP-disabled launch commands for benchmark worker slots only when requested' {
@'
agent: codex
model: provider-default
agent-slots:
  - slot-id: worker-1
    runtime-role: worker
    worker-backend: local
    agent: claude
    model: claude-opus-4-8
    model-source: operator-override
    reasoning-effort: high
    mcp-mode: disabled
    worktree-mode: managed
  - slot-id: worker-2
    runtime-role: worker
    worker-backend: codex
    agent: codex
    model: gpt-5.5
    model-source: operator-override
    reasoning-effort: high
    mcp-mode: disabled
    worktree-mode: managed
  - slot-id: worker-3
    runtime-role: worker
    worker-backend: local
    agent: codex
    model: gpt-5.5
    model-source: operator-override
    reasoning-effort: high
    worktree-mode: managed
'@ | Set-Content -Path (Join-Path $script:workersTempRoot '.winsmux.yaml') -Encoding UTF8

        $previousCodexMcpDisableServers = $env:WINSMUX_CODEX_MCP_DISABLE_SERVERS
        try {
            $env:WINSMUX_CODEX_MCP_DISABLE_SERVERS = 'cua-driver,node_repl,figma'
            $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status --json --project-dir $script:workersTempRoot
        } finally {
            $env:WINSMUX_CODEX_MCP_DISABLE_SERVERS = $previousCodexMcpDisableServers
        }
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $claudeRow = @($payload.workers | Where-Object { $_.slot_id -eq 'worker-1' })[0]
        $codexRow = @($payload.workers | Where-Object { $_.slot_id -eq 'worker-2' })[0]
        $defaultMcpRow = @($payload.workers | Where-Object { $_.slot_id -eq 'worker-3' })[0]

        $claudeRow.mcp_mode | Should -Be 'disabled'
        $claudeRow.launch_command | Should -Match '--mcp-config'
        $claudeRow.launch_command | Should -Match 'mcpServers'
        $claudeRow.launch_command | Should -Match '--strict-mcp-config'
        $codexRow.mcp_mode | Should -Be 'disabled'
        $codexRow.launch_command | Should -Match '--disable plugins'
        $codexRow.launch_command | Should -Match "mcp_servers\.cua-driver\.enabled=false"
        $codexRow.launch_command | Should -Match "mcp_servers\.node_repl\.enabled=false"
        $codexRow.launch_command | Should -Match "mcp_servers\.figma\.enabled=false"
        $defaultMcpRow.mcp_mode | Should -Be ''
        $defaultMcpRow.launch_command | Should -Not -Match '--disable plugins'
        $defaultMcpRow.launch_command | Should -Not -Match 'mcp_servers\.figma\.enabled=false'
        $defaultMcpRow.launch_command | Should -Not -Match '--mcp-config'
    }

It 'rejects direct api_llm pane worker startup without a real slot id' {
        $paneWorkerScript = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'winsmux-core\scripts\api-llm-pane-worker.ps1'
        $previousSlotId = $env:WINSMUX_SLOT_ID
        try {
            $env:WINSMUX_SLOT_ID = ''
            $output = & pwsh -NoProfile -File $paneWorkerScript -Provider openrouter -Model z-ai/glm-5.2 -ProjectDir $script:workersTempRoot 2>&1
        } finally {
            $env:WINSMUX_SLOT_ID = $previousSlotId
        }

        $LASTEXITCODE | Should -Be 2
        ($output | Out-String) | Should -Match 'status: failed'
        ($output | Out-String) | Should -Match 'missing SlotId'
        ($output | Out-String) | Should -Not -Match 'status: ready'
        ($output | Out-String) | Should -Not -Match 'api_llm\[worker\]>'
    }

It 'persists a run-bound api_llm started record before the network call' {
        Write-WorkersApiLlmProjectConfig
        $submissionId = 'submission-api-start-order'
        $packetRef = New-WinsmuxSubmissionPacket -ProjectDir $script:workersTempRoot -Kind task -Content ([ordered]@{ title = 'Synthetic API task'; request = 'Consume synthetic task input.' }) -SubmissionId $submissionId -TargetLabel 'worker-1'
        $env:OPENROUTER_API_KEY = 'test-openrouter-key'
        $script:apiLlmStatusAtNetworkCall = ''

        Mock Invoke-RestMethod {
            $runPath = Join-Path $script:workersTempRoot ".winsmux\worker-runs\worker-1\$submissionId\run.json"
            $started = Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:apiLlmStatusAtNetworkCall = [string]$started.status
            return [pscustomobject]@{
                id = 'chatcmpl-synthetic-start-order'
                choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = 'Synthetic response.' } })
                usage = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 1; total_tokens = 2 }
            }
        }

        $Rest = @('w1', '--task-json', $packetRef.RelativePath, '--task-id', $submissionId, '--run-id', $submissionId, '--json', '--project-dir', $script:workersTempRoot)
        $output = Invoke-WorkersExec
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $script:apiLlmStatusAtNetworkCall | Should -Be 'started'
        $payload.status | Should -Be 'succeeded'
        $payload.submission_id | Should -Be $submissionId
        $payload.kind | Should -Be 'task'
        $payload.request_consumed | Should -Be $true
    }

It 'ROUND3 P1 keeps stable task identity through the real api_llm exec path with only the provider call stubbed' {
        Write-WorkersApiLlmProjectConfig
        $taskId = 'task-round3-api-stable'
        $attemptId = 'attempt-round3-api-1'
        $packetRef = New-WinsmuxSubmissionPacket -ProjectDir $script:workersTempRoot -Kind task -Content ([ordered]@{ title = 'Synthetic API task'; request = 'Consume the API packet.' }) -SubmissionId $attemptId -TaskId $taskId -TargetLabel 'worker-1'
        $env:OPENROUTER_API_KEY = 'test-openrouter-key'
        $script:round3ApiStartedTaskId = ''

        Mock Invoke-RestMethod {
            $runPath = Join-Path $script:workersTempRoot ".winsmux\worker-runs\worker-1\$attemptId\run.json"
            $started = Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:round3ApiStartedTaskId = [string]$started.task_id
            return [pscustomobject]@{
                id = 'chatcmpl-round3-api'
                choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = 'Synthetic API response.' } })
                usage = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 1; total_tokens = 2 }
            }
        }

        $Rest = @('w1', '--task-json', $packetRef.RelativePath, '--task-id', $taskId, '--run-id', $attemptId, '--json', '--project-dir', $script:workersTempRoot)
        $payload = (Invoke-WorkersExec | Select-Object -Last 1) | ConvertFrom-Json
        $runPath = Join-Path $script:workersTempRoot ".winsmux\worker-runs\worker-1\$attemptId\run.json"
        $run = Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $payload.status | Should -Be 'succeeded'
        $payload.submission_id | Should -Be $attemptId
        $payload.run_id | Should -Be $attemptId
        $payload.task_id | Should -Be $taskId
        $script:round3ApiStartedTaskId | Should -Be $taskId
        $run.submission_id | Should -Be $attemptId
        $run.run_id | Should -Be $attemptId
        $run.task_id | Should -Be $taskId
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

It 'ROUND3 P1 keeps stable task identity through the real antigravity exec path with only the CLI call stubbed' {
        Write-WorkersAntigravityProjectConfig
        New-WorkersFakeAntigravityCli | Out-Null
        $taskId = 'task-round3-antigravity-stable'
        $attemptId = 'attempt-round3-antigravity-1'
        $packetRef = New-WinsmuxSubmissionPacket -ProjectDir $script:workersTempRoot -Kind task -Content ([ordered]@{ title = 'Synthetic Antigravity task'; request = 'Consume the Antigravity packet.' }) -SubmissionId $attemptId -TaskId $taskId -TargetLabel 'worker-1'
        $script:round3AntigravityStartedTaskId = ''

        Mock Invoke-WorkersAntigravityCli {
            param([string[]]$Arguments, [string]$WorkingDirectory)
            $runPath = Join-Path $script:workersTempRoot ".winsmux\worker-runs\worker-1\$attemptId\run.json"
            $started = Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:round3AntigravityStartedTaskId = [string]$started.task_id
            return [pscustomobject]@{ Command = 'agy'; Arguments = @($Arguments); ExitCode = 0; Output = 'Synthetic Antigravity response.' }
        }

        $Rest = @('w1', '--task-json', $packetRef.RelativePath, '--task-id', $taskId, '--run-id', $attemptId, '--json', '--project-dir', $script:workersTempRoot)
        $payload = (Invoke-WorkersExec | Select-Object -Last 1) | ConvertFrom-Json
        $runPath = Join-Path $script:workersTempRoot ".winsmux\worker-runs\worker-1\$attemptId\run.json"
        $run = Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $payload.status | Should -Be 'succeeded'
        $payload.submission_id | Should -Be $attemptId
        $payload.run_id | Should -Be $attemptId
        $payload.task_id | Should -Be $taskId
        $script:round3AntigravityStartedTaskId | Should -Be $taskId
        $run.submission_id | Should -Be $attemptId
        $run.run_id | Should -Be $attemptId
        $run.task_id | Should -Be $taskId
        Should -Invoke Invoke-WorkersAntigravityCli -Times 1 -Exactly
    }
}
