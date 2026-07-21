$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'TASK781 managed target mutation guard' {
    BeforeAll {
        $script:c08CorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $null = . $script:c08CorePath version
        $script:c08CoreContent = Get-Content -LiteralPath $script:c08CorePath -Raw -Encoding UTF8
    }

    BeforeEach {
        $script:c08Root = Join-Path ([IO.Path]::GetTempPath()) ('winsmux-c08-' + [guid]::NewGuid().ToString('N'))
        $script:c08ManagedA = Join-Path $script:c08Root 'managed-a'
        $script:c08ManagedB = Join-Path $script:c08Root 'managed-b'
        $script:c08Unmanaged = Join-Path $script:c08Root 'unmanaged'
        foreach ($root in @($script:c08ManagedA, $script:c08ManagedB)) {
            New-Item -ItemType Directory -Path (Join-Path $root '.winsmux') -Force | Out-Null
            Save-WinsmuxManifest -ProjectDir $root -Manifest ([ordered]@{
                version = 2
                session = [ordered]@{ name = 'winsmux-c08'; generation_id = 'generation-c08'; server_session_id = '$80'; session_ready = $true }
                panes = [ordered]@{
                    'worker-1' = [ordered]@{ slot_id = 'worker-1'; pane_id = '%2'; worker_backend = 'codex'; role = 'Worker'; title = 'W1'; status = 'ready'; runtime_ready = $true }
                }
                tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
                worktrees = [ordered]@{}
            })
            '{}' | Set-Content -LiteralPath (Join-Path $root '.winsmux\runtime-registry.json') -Encoding UTF8
        }
        New-Item -ItemType Directory -Path $script:c08Unmanaged -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:c08ManagedA 'nested\work') -Force | Out-Null

        $script:c08PreviousProjectDir = $env:WINSMUX_ORCHESTRA_PROJECT_DIR
        Remove-Item Env:WINSMUX_ORCHESTRA_PROJECT_DIR -ErrorAction SilentlyContinue
        $script:c08SessionProjectDir = $script:c08ManagedA
        $script:c08MissingContext = $false
        $script:c08SecurityPolicy = $null
        $script:c08SideEffects = 0
        $script:c08Trace = [Collections.Generic.List[string]]::new()
        $script:c08StatusWrites = 0
        $script:c08ValidationCount = 0
        $script:Target = '%2'
        $script:Rest = @('payload')

        Mock Stop-WithError { param([string]$Message) throw $Message }
        Mock Resolve-Target { '%2' }
        Mock Confirm-Target { '%2' }
        Mock Resolve-TerminalBackend { 'tauri' }
        Mock Get-Labels { @{} }
        Mock Save-Labels { $script:c08Trace.Add('mutation') | Out-Null; $script:c08SideEffects++ }
        Mock Clear-ReadMark { }
        Mock Clear-Watermark { }
        Mock Assert-ReadMark {
            $script:c08Trace.Add('mutation') | Out-Null
            $script:c08SideEffects++
            throw 'synthetic downstream side effect'
        }
        Mock Get-SlotAgentConfig {
            [pscustomobject]@{ Agent = 'codex'; Model = ''; PromptTransport = 'argv'; CapabilityAdapter = 'codex'; CapabilityCommand = 'codex' }
        }
        Mock Get-PaneControlManifestContext {
            param([string]$ProjectDir, [string]$PaneId)
            if ($script:c08MissingContext) { throw 'managed pane context missing' }
            [pscustomobject]@{
                ManifestPath = Join-Path $ProjectDir '.winsmux\manifest.yaml'
                ProjectDir = $ProjectDir; SessionName = 'winsmux-c08'; Label = 'worker-1'; PaneId = $PaneId
                Role = 'Worker'; Status = 'ready'; SecurityPolicy = $script:c08SecurityPolicy
                LaunchDir = $ProjectDir; GitWorktreeDir = (Join-Path $ProjectDir '.git')
                Branch = 'codex/task-781'; HeadSha = 'abc781'
            }
        }
        Mock Test-PaneControlRuntimeContext {
            $script:c08ValidationCount++
            $script:c08Trace.Add('runtime') | Out-Null
            New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'invalid_supervisor_identity' -Diagnostic 'synthetic stale managed runtime'
        }
        Mock Write-BridgeEventRecord {
            $script:c08Trace.Add('policy_event') | Out-Null
            $script:c08SideEffects++
        }
        Mock Set-PaneControlManifestPaneProperties { $script:c08StatusWrites++; $script:c08SideEffects++ }
        Mock Wait-PaneShellReady { }
        Mock Test-AgentReadyPrompt { $true }
        Mock Invoke-WinsmuxRaw {
            param([string[]]$Arguments)
            switch ([string]$Arguments[0]) {
                'display-message' {
                    if ($Arguments[-1] -eq '#{session_name}') { return 'winsmux-c08' }
                    if ($Arguments[-1] -like '*pane_id*') { return '%1' }
                    return 'winsmux-c08:0.0'
                }
                'show-environment' {
                    if ([string]::IsNullOrWhiteSpace($script:c08SessionProjectDir)) { return @() }
                    return "WINSMUX_ORCHESTRA_PROJECT_DIR=$script:c08SessionProjectDir"
                }
                'list-panes' { return '%2' }
                default {
                    $script:c08Trace.Add('mutation') | Out-Null
                    $script:c08SideEffects++
                    return @()
                }
            }
        }
    }

    AfterEach {
        if ($null -eq $script:c08PreviousProjectDir) {
            Remove-Item Env:WINSMUX_ORCHESTRA_PROJECT_DIR -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_ORCHESTRA_PROJECT_DIR = $script:c08PreviousProjectDir
        }
        Remove-Item -LiteralPath $script:c08Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'TASK781 C08 blocks stale managed target from <Name> cwd' -ForEach @(
        @{ Name = 'root'; Kind = 'root' }
        @{ Name = 'subdirectory'; Kind = 'subdir' }
        @{ Name = 'unrelated'; Kind = 'unrelated' }
    ) {
        $Target = '%2'
        $Rest = @('payload')
        $cwd = switch ($Kind) {
            'root' { $script:c08ManagedA }
            'subdir' { Join-Path $script:c08ManagedA 'nested\work' }
            default { $script:c08Unmanaged }
        }
        $errorText = ''
        Push-Location $cwd
        try { Invoke-Type } catch { $errorText = [string]$_.Exception.Message } finally { Pop-Location }

        $script:c08SideEffects | Should -Be 0
        $errorText | Should -Match 'invalid_supervisor_identity'
    }

    It 'TASK781 C08 refuses conflicting managed root candidates' {
        $Target = '%2'
        $Rest = @('payload')
        $env:WINSMUX_ORCHESTRA_PROJECT_DIR = $script:c08ManagedB
        $errorText = ''
        Push-Location $script:c08Unmanaged
        try { Invoke-Type } catch { $errorText = [string]$_.Exception.Message } finally { Pop-Location }

        $script:c08SideEffects | Should -Be 0
        $errorText | Should -Match 'manifest_regeneration_required'
    }

    It 'TASK781 C08 refuses a managed session root with missing pane context' {
        $Target = '%2'
        $Rest = @('payload')
        $script:c08MissingContext = $true
        $errorText = ''
        Push-Location $script:c08Unmanaged
        try { Invoke-Type } catch { $errorText = [string]$_.Exception.Message } finally { Pop-Location }

        $script:c08SideEffects | Should -Be 0
        $errorText | Should -Match 'manifest_regeneration_required'
    }

    It 'TASK781 C16 refuses managed writes when runtime freshness validators are unavailable' {
        $script:c16TransportPlans = 0
        $script:c16ResolvedSends = 0
        $script:c16TextSends = 0
        Mock Get-Command { $null } -ParameterFilter {
            $Name -contains 'Get-PaneControlManifestContext' -or
            $Name -contains 'Test-PaneControlRuntimeContext'
        }
        Mock Resolve-SendTransportPlan { $script:c16TransportPlans++ }
        Mock Send-ResolvedTransportPlan { $script:c16ResolvedSends++ }
        Mock Send-TextToPane { $script:c16TextSends++ }

        $errorText = ''
        Push-Location $script:c08Unmanaged
        try {
            try {
                Assert-WinsmuxTargetRuntimeWriteAllowed -PaneId '%2' -CurrentProjectDir $script:c08Unmanaged -Operation dispatch | Out-Null
            } catch {
                $errorText = [string]$_.Exception.Message
            }
        } finally {
            Pop-Location
        }

        $promptDir = Join-Path (Join-Path $script:c08ManagedA '.winsmux') 'dispatch-prompts'
        $actual = [ordered]@{
            error = $errorText
            mutation_side_effects = $script:c08SideEffects
            manifest_status_writes = $script:c08StatusWrites
            validator_calls = $script:c08ValidationCount
            transport_plans = $script:c16TransportPlans
            resolved_sends = $script:c16ResolvedSends
            text_sends = $script:c16TextSends
            prompt_dir_exists = Test-Path -LiteralPath $promptDir -PathType Container
        }
        $expected = [ordered]@{
            error = 'runtime dispatch refused (manifest_regeneration_required): Runtime identity validation is unavailable; regenerate the orchestra session.'
            mutation_side_effects = 0
            manifest_status_writes = 0
            validator_calls = 0
            transport_plans = 0
            resolved_sends = 0
            text_sends = 0
            prompt_dir_exists = $false
        }
        ($actual | ConvertTo-Json -Compress) | Should -Be ($expected | ConvertTo-Json -Compress)
    }

    It 'TASK781 C09 preserves plain unmanaged delivery when no managed candidate exists' {
        $Target = '%2'
        $Rest = @('payload')
        $script:c08SessionProjectDir = ''
        Mock Assert-ReadMark { }
        Push-Location $script:c08Unmanaged
        try { Invoke-Type } finally { Pop-Location }

        $script:c08SideEffects | Should -Be 1
        $script:c08ValidationCount | Should -Be 0
    }

    It 'TASK781 C19 keeps a captured managed write managed when every current candidate disappears' {
        $script:c08SessionProjectDir = ''

        $resolution = Resolve-WinsmuxManagedTargetContext -PaneId '%2' `
            -CurrentProjectDir $script:c08Unmanaged -Operation dispatch `
            -ExpectedGenerationId 'generation-c08'

        $resolution.Managed | Should -BeTrue
        $resolution.Validation.valid | Should -BeFalse
        $resolution.Validation.reason_code | Should -Be 'invalid_supervisor_identity'
    }

    It 'TASK781 C09 ignores cwd and process managed roots that do not map the target pane' {
        $Target = '%99'
        $Rest = @('payload')
        $script:c08SessionProjectDir = ''
        $env:WINSMUX_ORCHESTRA_PROJECT_DIR = $script:c08ManagedB
        Mock Resolve-Target { '%99' }
        Mock Confirm-Target { '%99' }
        Mock Assert-ReadMark { }

        Push-Location $script:c08ManagedA
        try { Invoke-Type } finally { Pop-Location }

        $script:c08SideEffects | Should -Be 1
        $script:c08ValidationCount | Should -Be 0
    }

    It 'TASK781 C15 maps failed deferred target auto validation to start_deferred' {
        $script:c15RuntimeOperation = ''
        Mock Get-PaneControlManifestContext {
            param([string]$ProjectDir, [string]$PaneId)
            [pscustomobject]@{
                ManifestPath = Join-Path $ProjectDir '.winsmux\manifest.yaml'
                ProjectDir = $ProjectDir; SessionName = 'winsmux-c08'; Label = 'worker-1'; PaneId = $PaneId
                Role = 'Worker'; Status = 'deferred_start_failed'; SecurityPolicy = $null
                LaunchDir = $ProjectDir; GitWorktreeDir = (Join-Path $ProjectDir '.git')
                Branch = 'codex/task-781'; HeadSha = 'abc781'
            }
        }
        Mock Test-PaneControlRuntimeContext {
            param([string]$ProjectDir, $ManifestEntry, [string]$Operation)
            $script:c15RuntimeOperation = $Operation
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'deferred_runtime_verified' -Diagnostic 'synthetic failed deferred runtime verified'
        }

        $resolution = Assert-WinsmuxTargetRuntimeWriteAllowed -PaneId '%2' `
            -CurrentProjectDir $script:c08ManagedA -Operation auto

        $script:c15RuntimeOperation | Should -Be 'start_deferred'
        $resolution.Operation | Should -Be 'start_deferred'
    }

    It 'TASK781 C10 blocks invalid managed <CommandName> before any side effect' -ForEach @(
        @{ CommandName = 'send' }
        @{ CommandName = 'type' }
        @{ CommandName = 'keys' }
        @{ CommandName = 'message' }
        @{ CommandName = 'ime' }
        @{ CommandName = 'image' }
        @{ CommandName = 'clipboard' }
        @{ CommandName = 'vault' }
    ) {
        $Target = '%2'
        $Rest = @('payload')
        $errorText = ''
        Push-Location $script:c08ManagedA
        try {
            switch ($CommandName) {
                'send' { Invoke-Send -SendTarget '%2' -SendArguments @('payload') }
                'type' { Invoke-Type }
                'keys' { $Rest = @('Enter'); Invoke-Keys }
                'message' { Invoke-Message }
                'ime' { Invoke-ImeInput }
                'image' { Invoke-ImagePaste }
                'clipboard' { Invoke-ClipboardPaste }
                'vault' { Invoke-VaultInject }
            }
        } catch { $errorText = [string]$_.Exception.Message } finally { Pop-Location }

        $script:c08SideEffects | Should -Be 0
        $errorText | Should -Match 'invalid_supervisor_identity'
    }

    It 'TASK781 C28 revalidates <CommandName> after preparation and refuses an expired generation before pane mutation' -ForEach @(
        @{ CommandName = 'type' }
        @{ CommandName = 'keys' }
        @{ CommandName = 'message' }
    ) {
        $Target = '%2'
        if ($CommandName -eq 'keys') {
            $Rest = @('Enter')
        } else {
            $Rest = @('payload')
        }
        $script:c28GuardCount = 0
        $script:c28PaneMutationCount = 0
        Mock Assert-ReadMark { }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            param($PaneId, $CurrentProjectDir, $Operation, $ExpectedGenerationId)
            $script:c28GuardCount++
            if ($script:c28GuardCount -eq 1) {
                return [PSCustomObject]@{ Managed = $true; Operation = 'dispatch'; GenerationId = 'generation-c08' }
            }
            throw 'runtime dispatch refused (invalid_supervisor_identity): generation expired after command preparation'
        }
        Mock Invoke-WinsmuxRaw {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'display-message') {
                if ($Arguments -contains '#{pane_id}') { return '%1' }
                return 'winsmux-c08:0.0'
            }
            $script:c28PaneMutationCount++
        }

        $errorText = ''
        Push-Location $script:c08ManagedA
        try {
            switch ($CommandName) {
                'type' { Invoke-Type }
                'keys' { Invoke-Keys }
                'message' { Invoke-Message }
            }
        } catch {
            $errorText = [string]$_.Exception.Message
        } finally {
            Pop-Location
        }

        $errorText | Should -Match 'invalid_supervisor_identity'
        $script:c28GuardCount | Should -Be 2
        $script:c28PaneMutationCount | Should -Be 0
    }

    It 'TASK781 C28 revalidates every interactive pane mutation with the original generation' {
        foreach ($functionName in @('Invoke-Type', 'Invoke-Keys', 'Invoke-Message', 'Invoke-ImeInput', 'Invoke-ImagePaste', 'Invoke-ClipboardPaste')) {
            $functionSource = [regex]::Match(
                $script:c08CoreContent,
                ('(?s)function {0} \{{.*?(?=\r?\nfunction |\z)' -f [regex]::Escape($functionName))
            ).Value
            $functionSource | Should -Not -BeNullOrEmpty
            ([regex]::Matches($functionSource, 'Assert-WinsmuxTargetRuntimeWriteAllowed')).Count | Should -BeGreaterOrEqual 2
            $functionSource | Should -Match ([regex]::Escape('-ExpectedGenerationId ([string]$runtimeAccess.GenerationId)'))
            $sendIndex = $functionSource.LastIndexOf("Invoke-WinsmuxRaw -Arguments @('send-keys'", [System.StringComparison]::Ordinal)
            $sendIndex | Should -BeGreaterThan 0
            $sourceBeforeSend = $functionSource.Substring(0, $sendIndex)
            $sendGuardIndex = $sourceBeforeSend.LastIndexOf('Assert-WinsmuxTargetRuntimeWriteAllowed', [System.StringComparison]::Ordinal)
            $sendGuardIndex | Should -BeGreaterThan 0
            $sendGuardIndex | Should -BeLessThan $sendIndex
        }
    }

    It 'TASK781 C44 revalidates after pane send and refuses read-mark cleanup on lease expiry' {
        $Target = '%2'
        $Rest = @('payload')
        $script:c44GuardCount = 0
        $script:c44PaneSends = 0
        $script:c44ReadClears = 0
        Mock Assert-ReadMark { }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            $script:c44GuardCount++
            if ($script:c44GuardCount -eq 1) {
                return [pscustomobject]@{ Managed = $true; Operation = 'dispatch'; GenerationId = 'generation-c08' }
            }
            if ($script:c44GuardCount -eq 3) {
                throw 'runtime dispatch refused (invalid_supervisor_identity): generation expired before read-mark cleanup'
            }
            return [pscustomobject]@{ Managed = $true; Operation = 'dispatch'; GenerationId = 'generation-c08' }
        }
        Mock Invoke-WinsmuxRaw { $script:c44PaneSends++ }
        Mock Clear-ReadMark { $script:c44ReadClears++ }

        $errorText = ''
        Push-Location $script:c08ManagedA
        try { Invoke-Type } catch { $errorText = [string]$_.Exception.Message } finally { Pop-Location }

        $script:c44GuardCount | Should -Be 3
        $script:c44PaneSends | Should -Be 1
        $script:c44ReadClears | Should -Be 0
        $errorText | Should -Match 'invalid_supervisor_identity'
    }

    It 'TASK781 C44 places the captured-generation guard immediately before every interactive read-mark cleanup' {
        foreach ($functionName in @('Invoke-Type', 'Invoke-Keys', 'Invoke-Message', 'Invoke-ImeInput', 'Invoke-ImagePaste', 'Invoke-ClipboardPaste', 'Invoke-VaultInject')) {
            $functionSource = [regex]::Match(
                $script:c08CoreContent,
                ('(?s)function {0} \{{.*?(?=\r?\nfunction |\z)' -f [regex]::Escape($functionName))
            ).Value
            $functionSource | Should -Not -BeNullOrEmpty
            $functionSource | Should -Match '(?s)Assert-WinsmuxTargetRuntimeWriteAllowed.*?-ExpectedGenerationId.*?\| Out-Null\s*Clear-ReadMark'
        }
    }

    It 'TASK781 C11 validates then blocks managed <CommandName> without identity mutation' -ForEach @(
        @{ CommandName = 'role' }
        @{ CommandName = 'restart' }
        @{ CommandName = 'name' }
        @{ CommandName = 'kill' }
    ) {
        $Target = '%2'
        $Rest = @('payload')
        Mock Test-PaneControlRuntimeContext {
            $script:c08Trace.Add('runtime') | Out-Null
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'valid' -Diagnostic 'runtime valid'
        }
        $errorText = ''
        Push-Location $script:c08ManagedA
        try {
            switch ($CommandName) {
                'role' { $Rest = @('worker'); Invoke-Role }
                'restart' { $Rest = @(); Invoke-Restart }
                'name' { $Rest = @('renamed'); Invoke-Name }
                'kill' { $Rest = @(); Invoke-Kill }
            }
        } catch { $errorText = [string]$_.Exception.Message } finally { Pop-Location }

        @($script:c08Trace) | Should -Be @('runtime')
        $script:c08SideEffects | Should -Be 0
        $errorText | Should -Match 'manifest_regeneration_required'
    }

    It 'TASK781 C19 validates runtime before emitting a security BLOCK event' {
        $script:c08SecurityPolicy = [ordered]@{ mode = 'enforce' }
        Mock Find-SendSecurityPolicyViolation {
            [ordered]@{ verdict = 'BLOCK'; reason = 'synthetic policy block'; pattern = 'payload'; mode = 'enforce'; allow = @(); block = @('payload'); next_action = 'stop' }
        }
        $errorText = ''
        Push-Location $script:c08ManagedA
        try { Invoke-Send -SendTarget '%2' -SendArguments @('payload') } catch { $errorText = [string]$_.Exception.Message } finally { Pop-Location }

        $script:c08SideEffects | Should -Be 0
        @($script:c08Trace) | Should -Be @('runtime')
        $errorText | Should -Match 'invalid_supervisor_identity'
    }

    It 'TASK781 C33 revalidates the captured generation immediately before persisting a security BLOCK event' {
        $script:c08SecurityPolicy = [ordered]@{ mode = 'enforce' }
        Mock Find-SendSecurityPolicyViolation {
            [ordered]@{ verdict = 'BLOCK'; reason = 'synthetic policy block'; pattern = 'payload'; mode = 'enforce'; allow = @(); block = @('payload'); next_action = 'stop' }
        }
        Mock Test-PaneControlRuntimeContext {
            $script:c08ValidationCount++
            $script:c08Trace.Add('runtime') | Out-Null
            if ($script:c08ValidationCount -eq 1) {
                return New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' `
                    -Diagnostic 'synthetic initial runtime' -Context ([ordered]@{ generation_id = 'generation-c08' })
            }
            return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'invalid_supervisor_identity' `
                -Diagnostic 'generation changed before security event persistence'
        }
        $errorText = ''
        Push-Location $script:c08ManagedA
        try { Invoke-Send -SendTarget '%2' -SendArguments @('payload') } catch { $errorText = [string]$_.Exception.Message } finally { Pop-Location }

        @($script:c08Trace) | Should -Be @('runtime', 'runtime')
        $script:c08SideEffects | Should -Be 0
        Should -Invoke Write-BridgeEventRecord -Times 0 -Exactly
        $errorText | Should -Match 'invalid_supervisor_identity'
    }

    It 'TASK781 C33 persists exactly one security BLOCK event when both runtime validations remain current' {
        $script:c08SecurityPolicy = [ordered]@{ mode = 'enforce' }
        Mock Find-SendSecurityPolicyViolation {
            [ordered]@{ verdict = 'BLOCK'; reason = 'synthetic policy block'; pattern = 'payload'; mode = 'enforce'; allow = @(); block = @('payload'); next_action = 'stop' }
        }
        Mock Test-PaneControlRuntimeContext {
            $script:c08ValidationCount++
            $script:c08Trace.Add('runtime') | Out-Null
            New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'live_runtime_verified' `
                -Diagnostic 'synthetic current runtime' -Context ([ordered]@{ generation_id = 'generation-c08' })
        }
        $errorText = ''
        Push-Location $script:c08ManagedA
        try { Invoke-Send -SendTarget '%2' -SendArguments @('payload') } catch { $errorText = [string]$_.Exception.Message } finally { Pop-Location }

        @($script:c08Trace) | Should -Be @('runtime', 'runtime', 'policy_event')
        $script:c08SideEffects | Should -Be 1
        Should -Invoke Write-BridgeEventRecord -Times 1 -Exactly
        $errorText | Should -Match 'synthetic policy block'
    }

    It 'TASK781 C19 revalidates deferred start immediately before its first persistent mutation' {
        $planPath = Join-Path $script:c08ManagedA 'worker-1.json'
        ([ordered]@{ agent = 'codex'; ready_marker_path = (Join-Path $script:c08ManagedA 'worker-1.ready.json') } | ConvertTo-Json) |
            Set-Content -LiteralPath $planPath -Encoding UTF8
        $entry = [pscustomobject]@{
            Label = 'worker-1'; PaneId = '%2'; Status = 'deferred_start'; BootstrapPlanPath = $planPath
            CapabilityAdapter = 'codex'; ProviderTarget = ''; ApprovedLaunch = $null
        }
        Mock Test-PaneControlRuntimeContext {
            $script:c08ValidationCount++
            if ($script:c08ValidationCount -eq 1) { return New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'valid' -Diagnostic 'runtime valid' }
            return New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'invalid_supervisor_identity' -Diagnostic 'generation changed before deferred mutation'
        }
        $initial = Test-PaneControlRuntimeContext -ProjectDir $script:c08ManagedA -ManifestEntry $entry -Operation start_deferred
        $initial.valid | Should -BeTrue
        $errorText = ''
        Push-Location $script:c08ManagedA
        try { Start-DeferredPaneFromManifestEntry -ProjectDir $script:c08ManagedA -ManifestEntry $entry } catch { $errorText = [string]$_.Exception.Message } finally { Pop-Location }

        $script:c08StatusWrites | Should -Be 0
        $script:c08SideEffects | Should -Be 0
        $errorText | Should -Match 'invalid_supervisor_identity'
    }

    It 'TASK781 C19 does not enumerate vault credential names or values when initial runtime validation fails' {
        $Target = '%2'
        Mock Get-WinsmuxVaultCredentialNamesInternal { throw 'credential name enumeration must not run' }
        Mock Get-WinsmuxVaultCredentialValueInternal { throw 'credential value read must not run' }
        $errorText = ''

        Push-Location $script:c08ManagedA
        try { Invoke-VaultInject } catch { $errorText = [string]$_.Exception.Message } finally { Pop-Location }

        Should -Invoke Get-WinsmuxVaultCredentialNamesInternal -Times 0 -Exactly
        Should -Invoke Get-WinsmuxVaultCredentialValueInternal -Times 0 -Exactly
        $script:c08SideEffects | Should -Be 0
        $errorText | Should -Match 'invalid_supervisor_identity'
    }

    It 'TASK781 C40 stops vault injection before reading a second secret when the generation changes' {
        $Target = '%2'
        $script:c19GuardCalls = 0
        $script:c19VaultSends = [Collections.Generic.List[string]]::new()
        $script:c19SecretReads = [Collections.Generic.List[string]]::new()
        Mock Assert-ReadMark { }
        Mock Start-Sleep { }
        Mock Get-WinsmuxVaultCredentialNamesInternal { @('SYNTH_ONE', 'SYNTH_TWO') }
        Mock Get-WinsmuxVaultCredentialValueInternal {
            param([string]$Name)
            $script:c19SecretReads.Add($Name) | Out-Null
            if ($Name -eq 'SYNTH_ONE') { return 'synthetic-value-one' }
            return 'synthetic-value-two'
        }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            param([string]$PaneId, [string]$CurrentProjectDir, [string]$Operation, [string]$ExpectedGenerationId)
            $script:c19GuardCalls++
            if ($script:c19GuardCalls -eq 5) {
                throw 'runtime dispatch refused (invalid_supervisor_identity): generation changed before second secret read'
            }
            [pscustomobject]@{ Managed = $true; ProjectDir = $CurrentProjectDir; GenerationId = 'generation-G1' }
        }
        Mock Invoke-WinsmuxRaw {
            param([string[]]$Arguments)
            if ($Arguments[0] -ne 'send-keys') { throw "unexpected vault command: $($Arguments -join ' ')" }
            $script:c19VaultSends.Add(($Arguments -join '|')) | Out-Null
        }
        $errorText = ''

        Push-Location $script:c08ManagedA
        try { Invoke-VaultInject } catch { $errorText = [string]$_.Exception.Message } finally { Pop-Location }

        $script:c19GuardCalls | Should -Be 5
        @($script:c19SecretReads) | Should -Be @('SYNTH_ONE')
        $script:c19VaultSends.Count | Should -Be 2
        $script:c19VaultSends[0] | Should -Match 'SYNTH_ONE'
        $script:c19VaultSends[0] | Should -Not -Match 'SYNTH_TWO'
        $script:c19VaultSends[1] | Should -Match 'Enter$'
        $errorText | Should -Match 'invalid_supervisor_identity'
    }

    It 'TASK781 C35 revalidates the captured generation immediately before Vault Enter' {
        $Target = '%2'
        $script:c35GuardCalls = 0
        $script:c35VaultSends = [Collections.Generic.List[string]]::new()
        Mock Assert-ReadMark { }
        Mock Start-Sleep { }
        Mock Get-WinsmuxVaultCredentialNamesInternal { @('SYNTH_ONE') }
        Mock Get-WinsmuxVaultCredentialValueInternal { 'synthetic-value-one' }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            param([string]$PaneId, [string]$CurrentProjectDir, [string]$Operation, [string]$ExpectedGenerationId)
            $script:c35GuardCalls++
            if ($script:c35GuardCalls -eq 4) {
                throw 'runtime dispatch refused (invalid_supervisor_identity): generation changed before Vault Enter'
            }
            [pscustomobject]@{ Managed = $true; ProjectDir = $CurrentProjectDir; GenerationId = 'generation-G1' }
        }
        Mock Invoke-WinsmuxRaw {
            param([string[]]$Arguments)
            if ($Arguments[0] -ne 'send-keys') { throw "unexpected vault command: $($Arguments -join ' ')" }
            $script:c35VaultSends.Add(($Arguments -join '|')) | Out-Null
        }
        $errorText = ''

        Push-Location $script:c08ManagedA
        try { Invoke-VaultInject } catch { $errorText = [string]$_.Exception.Message } finally { Pop-Location }

        $script:c35GuardCalls | Should -Be 4
        $script:c35VaultSends.Count | Should -Be 1
        $script:c35VaultSends[0] | Should -Match 'SYNTH_ONE'
        $script:c35VaultSends | Should -Not -Match 'Enter'
        $errorText | Should -Match 'invalid_supervisor_identity'
    }

    It 'TASK781 C37 creates collision-proof owned image artifacts without overwriting a sibling' {
        $imageDir = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-c37-images-' + [guid]::NewGuid().ToString('N'))
        Add-Type -AssemblyName System.Drawing
        $imageA = [System.Drawing.Bitmap]::new(1, 1)
        $imageB = [System.Drawing.Bitmap]::new(1, 1)
        try {
            $artifactA = Write-WinsmuxClipboardImageArtifact -Image $imageA -DirectoryPath $imageDir
            $artifactB = Write-WinsmuxClipboardImageArtifact -Image $imageB -DirectoryPath $imageDir

            $artifactA.Path | Should -Not -BeExactly $artifactB.Path
            Test-Path -LiteralPath $artifactA.Path -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath $artifactB.Path -PathType Leaf | Should -BeTrue
            $artifactA.Owned | Should -BeTrue
            $artifactB.Owned | Should -BeTrue
            $writerSource = [regex]::Match(
                $script:c08CoreContent,
                '(?s)function Write-WinsmuxClipboardImageArtifact \{.*?(?=\r?\nfunction |\z)'
            ).Value
            $writerSource | Should -Match '\[System\.IO\.FileMode\]::CreateNew'
        } finally {
            $imageA.Dispose()
            $imageB.Dispose()
            Remove-Item -LiteralPath $imageDir -Recurse -Force -ErrorAction SilentlyContinue
        }
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

It 'defines a brokered execution baseline for prepared isolated runs without starting an external worker' {
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
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id broker-run --json --project-dir $script:workersTempRoot | Out-Null

        $output = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker baseline worker-2 --run-id broker-run --endpoint https://broker.example.invalid/worker --node-id broker-a --json --project-dir $script:workersTempRoot
        $payload = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $serialized = $payload | ConvertTo-Json -Depth 32
        $manifestPath = Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\broker-run\broker-baseline.json'

        $payload.status | Should -Be 'broker_defined'
        $payload.execution_profile | Should -Be 'isolated-enterprise'
        $payload.public_default | Should -Be $false
        $payload.broker_kind | Should -Be 'single_external_worker_node'
        $payload.node.node_id | Should -Be 'broker-a'
        $payload.node.endpoint | Should -Be 'https://broker.example.invalid/worker'
        $payload.node.endpoint_contains_secret | Should -Be $false
        $payload.node.command_starts_process | Should -Be $false
        $payload.topology.multi_broker_supported | Should -Be $false
        $payload.topology.multi_hub_supported | Should -Be $false
        $payload.boundary.workspace.direct_project_write | Should -Be 'prohibited'
        $payload.boundary.heartbeat.broker_must_report_liveness | Should -Be $true
        $payload.boundary.connection.command_connects_network | Should -Be $false
        $payload.boundary.connection.command_launches_external_worker | Should -Be $false
        $payload.boundary.credentials.endpoint_credentials_allowed | Should -Be $false
        $payload.boundary.credentials.secret_values_in_manifest | Should -Be $false
        $payload.failure_policy.unsafe_claims_prohibited | Should -Be $true
        $payload.locations.manifest.reference | Should -Be '.winsmux/isolated-workspaces/worker-2/broker-run/broker-baseline.json'
        @($payload.testable_guards) | Should -Contain 'single_broker_only'
        @($payload.testable_guards) | Should -Contain 'endpoint_credentials_rejected'
        Test-Path -LiteralPath $manifestPath | Should -Be $true
        $serialized | Should -Not -Match ([regex]::Escape($script:workersTempRoot))
        $serialized | Should -Not -Match ([regex]::Escape($script:workersTempRoot.Replace('\', '\\')))

        $statusOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status worker-2 --json --project-dir $script:workersTempRoot
        $statusPayload = ($statusOutput | Select-Object -Last 1) | ConvertFrom-Json
        $statusRow = @($statusPayload.workers)[0]
        $statusRow.broker.run_id | Should -Be 'broker-run'
        $statusRow.broker.execution_profile | Should -Be 'isolated-enterprise'
        $statusRow.broker.status | Should -Be 'broker_defined'
        $statusRow.broker.node_id | Should -Be 'broker-a'
        $statusRow.broker.endpoint | Should -Be 'https://broker.example.invalid/worker'
        $statusRow.broker.manifest | Should -Be '.winsmux/isolated-workspaces/worker-2/broker-run/broker-baseline.json'
    }

It 'issues, checks, refreshes, and expires broker run tokens without exposing token values' {
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
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id broker-token-run --json --project-dir $script:workersTempRoot | Out-Null
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker baseline worker-2 --run-id broker-token-run --endpoint https://broker.example.invalid/worker --node-id broker-a --json --project-dir $script:workersTempRoot | Out-Null

        $tokenPath = Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\broker-token-run\secrets\broker-run-token.txt'
        $manifestPath = Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\broker-token-run\broker-token.json'
        $heartbeatPath = Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\broker-token-run\heartbeat.json'
        $previousNow = $env:WINSMUX_TEST_NOW_UTC

        try {
            $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:00Z'
            $missingOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker token check w2 --run-id broker-token-run --ttl-seconds 60 --json --project-dir $script:workersTempRoot
            $missing = ($missingOutput | Select-Object -Last 1) | ConvertFrom-Json
            $missing.status | Should -Be 'offline'
            $missing.reason | Should -Be 'broker_token_missing'
            $missing.offline_heartbeat.health | Should -Be 'offline'
            Test-Path -LiteralPath $tokenPath | Should -Be $false

            $missingAgainOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker token check w2 --run-id broker-token-run --ttl-seconds 60 --json --project-dir $script:workersTempRoot
            $missingAgain = ($missingAgainOutput | Select-Object -Last 1) | ConvertFrom-Json
            $missingAgain.status | Should -Be 'offline'
            $missingAgain.reason | Should -Be 'broker_token_missing'
            $missingAgain.credential_refresh.failure_reason | Should -Be 'missing_run_token'
            Test-Path -LiteralPath $tokenPath | Should -Be $false

            $issueOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker token issue w2 --run-id broker-token-run --ttl-seconds 60 --json --project-dir $script:workersTempRoot
            $issue = ($issueOutput | Select-Object -Last 1) | ConvertFrom-Json
            $firstTokenValue = Get-Content -LiteralPath $tokenPath -Raw -Encoding UTF8
            $issueSerialized = $issue | ConvertTo-Json -Depth 32
            $manifestRaw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8

            $issue.status | Should -Be 'issued'
            $issue.health | Should -Be 'valid'
            $issue.run_token.kind | Should -Be 'short_lived_broker_run_token'
            $issue.run_token.value_ref | Should -Be '.winsmux/isolated-workspaces/worker-2/broker-token-run/secrets/broker-run-token.txt'
            $issue.run_token.value_output | Should -Be $false
            $issue.run_token.value_in_manifest | Should -Be $false
            $issue.broker_baseline.manifest | Should -Be '.winsmux/isolated-workspaces/worker-2/broker-token-run/broker-baseline.json'
            $issue.broker_baseline.node_id | Should -Be 'broker-a'
            $issue.broker_baseline.endpoint | Should -Be 'https://broker.example.invalid/worker'
            $issue.value_policy.output_contains_token_value | Should -Be $false
            $issueSerialized | Should -Not -Match ([regex]::Escape($firstTokenValue.Trim()))
            $manifestRaw | Should -Not -Match ([regex]::Escape($firstTokenValue.Trim()))

            $statusOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status worker-2 --json --project-dir $script:workersTempRoot
            $statusPayload = ($statusOutput | Select-Object -Last 1) | ConvertFrom-Json
            $statusRow = @($statusPayload.workers)[0]
            $statusRow.broker.token.status | Should -Be 'issued'
            $statusRow.broker.token.health | Should -Be 'valid'
            $statusRow.broker.token.manifest | Should -Be '.winsmux/isolated-workspaces/worker-2/broker-token-run/broker-token.json'

            $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:30Z'
            $validOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker token check w2 --run-id broker-token-run --ttl-seconds 60 --json --project-dir $script:workersTempRoot
            $valid = ($validOutput | Select-Object -Last 1) | ConvertFrom-Json
            $valid.status | Should -Be 'valid'
            $valid.health | Should -Be 'valid'
            $valid.credential_refresh.attempted | Should -Be $false

            Remove-Item -LiteralPath $tokenPath -Force
            $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:00:31Z'
            $missingSecretOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker token check w2 --run-id broker-token-run --ttl-seconds 60 --json --project-dir $script:workersTempRoot
            $missingSecret = ($missingSecretOutput | Select-Object -Last 1) | ConvertFrom-Json
            $secondTokenValue = Get-Content -LiteralPath $tokenPath -Raw -Encoding UTF8
            $missingSecretSerialized = $missingSecret | ConvertTo-Json -Depth 32

            $missingSecret.status | Should -Be 'refreshed'
            $missingSecret.health | Should -Be 'valid'
            $missingSecret.reason | Should -Be 'token_secret_invalid_refreshed'
            $missingSecret.credential_refresh.attempted | Should -Be $true
            $missingSecret.credential_refresh.refreshed | Should -Be $true
            $secondTokenValue | Should -Not -Be $firstTokenValue
            $missingSecretSerialized | Should -Not -Match ([regex]::Escape($secondTokenValue.Trim()))

            $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:01:32Z'
            $refreshOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker token check w2 --run-id broker-token-run --ttl-seconds 60 --json --project-dir $script:workersTempRoot
            $refresh = ($refreshOutput | Select-Object -Last 1) | ConvertFrom-Json
            $thirdTokenValue = Get-Content -LiteralPath $tokenPath -Raw -Encoding UTF8
            $refreshSerialized = $refresh | ConvertTo-Json -Depth 32

            $refresh.status | Should -Be 'refreshed'
            $refresh.health | Should -Be 'valid'
            $refresh.credential_refresh.attempted | Should -Be $true
            $refresh.credential_refresh.refreshed | Should -Be $true
            $thirdTokenValue | Should -Not -Be $secondTokenValue
            $refreshSerialized | Should -Not -Match ([regex]::Escape($thirdTokenValue.Trim()))

            $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:02:33Z'
            $offlineOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker token check w2 --run-id broker-token-run --ttl-seconds 60 --no-refresh --json --project-dir $script:workersTempRoot
            $offline = ($offlineOutput | Select-Object -Last 1) | ConvertFrom-Json

            $offline.status | Should -Be 'offline'
            $offline.health | Should -Be 'offline'
            $offline.reason | Should -Be 'token_expired_refresh_disabled'
            $offline.credential_refresh.failure_reason | Should -Be 'refresh_disabled'
            $offline.offline_heartbeat.health | Should -Be 'offline'
            Test-Path -LiteralPath $heartbeatPath | Should -Be $true

            $offlineStatusOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers status worker-2 --json --project-dir $script:workersTempRoot
            $offlineStatusPayload = ($offlineStatusOutput | Select-Object -Last 1) | ConvertFrom-Json
            $offlineStatusRow = @($offlineStatusPayload.workers)[0]
            $offlineStatusRow.heartbeat_health | Should -Be 'offline'
            $offlineStatusRow.broker.token.health | Should -Be 'offline'

            $env:WINSMUX_TEST_NOW_UTC = '2026-05-16T00:02:34Z'
            $recoveryOutput = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker token check w2 --run-id broker-token-run --ttl-seconds 60 --json --project-dir $script:workersTempRoot
            $recovery = ($recoveryOutput | Select-Object -Last 1) | ConvertFrom-Json
            $fourthTokenValue = Get-Content -LiteralPath $tokenPath -Raw -Encoding UTF8
            $recovery.status | Should -Be 'refreshed'
            $recovery.health | Should -Be 'valid'
            $recovery.credential_refresh.refreshed | Should -Be $true
            $fourthTokenValue | Should -Not -Be $thirdTokenValue
        } finally {
            $env:WINSMUX_TEST_NOW_UTC = $previousNow
        }
    }

It 'fails closed for broker baselines outside the prepared isolated boundary' {
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

        $localProfile = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker baseline worker-2 --run-id broker-local --profile local-windows --endpoint https://broker.example.invalid/worker --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($localProfile | Out-String) | Should -Match 'requires execution profile isolated-enterprise'

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

        $missingRun = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker baseline worker-2 --run-id broker-missing --endpoint https://broker.example.invalid/worker --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($missingRun | Out-String) | Should -Match 'requires an existing isolated workspace run'
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\broker-missing\broker-baseline.json') | Should -Be $false

        $credentialEndpoint = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker baseline worker-2 --run-id broker-credentials --endpoint https://user:pass@broker.example.invalid/worker --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($credentialEndpoint | Out-String) | Should -Match 'must not include credentials'
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\broker-credentials\broker-baseline.json') | Should -Be $false

        'payload' | Set-Content -Path (Join-Path $script:workersTempRoot 'input.txt') -Encoding UTF8
        & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers workspace prepare w2 --include input.txt --run-id token-no-baseline --json --project-dir $script:workersTempRoot | Out-Null
        $tokenWithoutBaseline = & pwsh -NoProfile -File $script:winsmuxWorkersCorePath workers broker token issue worker-2 --run-id token-no-baseline --json --project-dir $script:workersTempRoot 2>&1
        $LASTEXITCODE | Should -Be 1
        ($tokenWithoutBaseline | Out-String) | Should -Match 'requires an existing broker baseline'
        Test-Path -LiteralPath (Join-Path $script:workersTempRoot '.winsmux\isolated-workspaces\worker-2\token-no-baseline\broker-token.json') | Should -Be $false
    }
}
