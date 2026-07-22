$ErrorActionPreference = 'Stop'
BeforeAll {
    $script:BridgeTestsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot '_helpers\BridgeTestCommon.ps1')
}

Describe 'winsmux send dispatch payload' {
    BeforeAll {
        $script:winsmuxCorePath = Join-Path (Split-Path -Parent $script:BridgeTestsRoot) 'scripts\winsmux-core.ps1'
        $script:winsmuxCoreSendRawContent = Get-Content -Path $script:winsmuxCorePath -Raw -Encoding UTF8
        . $script:winsmuxCorePath 'version' *> $null
    }

    BeforeEach {
        $script:sendTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-send-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sendTempRoot -Force | Out-Null
        $script:sendHadPreviousProjectDir = Test-Path Env:WINSMUX_ORCHESTRA_PROJECT_DIR
        $script:sendPreviousProjectDir = [string]$env:WINSMUX_ORCHESTRA_PROJECT_DIR
        Remove-Item Env:WINSMUX_ORCHESTRA_PROJECT_DIR -ErrorAction SilentlyContinue
        $script:sendSessionProjectDir = ''
        Mock Invoke-WinsmuxRaw {
            param([string[]]$Arguments)

            if ($Arguments[0] -eq 'display-message' -and $Arguments[-1] -eq '#{session_name}') {
                return 'winsmux-send-tests'
            }
            if ($Arguments[0] -eq 'show-environment') {
                if (-not [string]::IsNullOrWhiteSpace($script:sendSessionProjectDir)) {
                    return "WINSMUX_ORCHESTRA_PROJECT_DIR=$($script:sendSessionProjectDir)"
                }
                return @()
            }

            throw "unexpected Invoke-WinsmuxRaw arguments: $($Arguments -join ' ')"
        }
    }

    AfterEach {
        if ($script:sendHadPreviousProjectDir) {
            $env:WINSMUX_ORCHESTRA_PROJECT_DIR = $script:sendPreviousProjectDir
        } else {
            Remove-Item Env:WINSMUX_ORCHESTRA_PROJECT_DIR -ErrorAction SilentlyContinue
        }
        if ($script:sendTempRoot -and (Test-Path $script:sendTempRoot)) {
            Remove-Item -Path $script:sendTempRoot -Recurse -Force
        }
    }

    It 'keeps short text inline without creating a dispatch file' {
        $payload = Resolve-SendDispatchPayload -Text 'Write-Host short' -ProjectDir $script:sendTempRoot -LengthLimit 4000

        $payload['IsFileBacked'] | Should -Be $false
        $payload['TextToSend'] | Should -Be 'Write-Host short'
        $payload['PromptPath'] | Should -Be $null
        Test-Path (Join-Path $script:sendTempRoot '.winsmux\dispatch-prompts') | Should -Be $false
    }

    It 'resolves managed pane send settings through the project capability root' {
        $script:winsmuxCoreSendRawContent | Should -Match 'Get-SlotAgentConfig -Role \$context\.Role -SlotId \$context\.Label -RootPath \$projectDir'
        $script:winsmuxCoreSendRawContent | Should -Match 'Provider capability'
        $script:winsmuxCoreSendRawContent | Should -Match 'CapabilityAdapter'
        $script:winsmuxCoreSendRawContent | Should -Match 'CapabilityCommand'
    }

    It 'TASK781 resolves a managed slot target from the nearest ancestor manifest for <Name>' -ForEach @(
        @{ Name = 'project root'; RelativeCwd = '.' }
        @{ Name = 'project subdirectory'; RelativeCwd = 'nested\work' }
    ) {
        New-Item -ItemType Directory -Path (Join-Path $script:sendTempRoot '.winsmux') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:sendTempRoot 'nested\work') -Force | Out-Null
        Save-WinsmuxManifest -ProjectDir $script:sendTempRoot -Manifest ([ordered]@{
            version = 2
            session = [ordered]@{ name = 'winsmux-orchestra'; generation_id = 'generation-send'; server_session_id = '$41'; session_ready = $true }
            panes = [ordered]@{
                'worker-1' = [ordered]@{ slot_id = 'worker-1'; pane_id = '%2'; worker_backend = 'codex'; worker_role = 'reviewer'; role = 'Worker'; title = 'W1 Codex Reviewer'; status = 'ready'; runtime_ready = $true }
            }
            tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
            worktrees = [ordered]@{}
        })
        Mock Get-Labels { @{} }

        Push-Location (Join-Path $script:sendTempRoot $RelativeCwd)
        try {
            Resolve-Target 'worker-1' | Should -BeExactly '%2'
        } finally {
            Pop-Location
        }
    }

    It 'TASK781 C27 prefers the nearest managed manifest over a stale global label mapping' {
        New-Item -ItemType Directory -Path (Join-Path $script:sendTempRoot '.winsmux') -Force | Out-Null
        Save-WinsmuxManifest -ProjectDir $script:sendTempRoot -Manifest ([ordered]@{
            version = 2
            session = [ordered]@{ name = 'winsmux-orchestra'; generation_id = 'generation-send'; server_session_id = '$41'; session_ready = $true }
            panes = [ordered]@{
                'worker-1' = [ordered]@{ slot_id = 'worker-1'; pane_id = '%2'; worker_backend = 'codex'; worker_role = 'reviewer'; role = 'Worker'; title = 'W1 Codex Reviewer'; status = 'ready'; runtime_ready = $true }
            }
            tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
            worktrees = [ordered]@{}
        })
        Mock Get-Labels { @{ 'worker-1' = '%99' } }

        Push-Location $script:sendTempRoot
        try {
            Resolve-Target 'worker-1' | Should -BeExactly '%2'
        } finally {
            Pop-Location
        }
    }

    It 'TASK781 C27 refuses a label omitted by the nearest managed manifest instead of returning the raw target' {
        New-Item -ItemType Directory -Path (Join-Path $script:sendTempRoot '.winsmux') -Force | Out-Null
        Save-WinsmuxManifest -ProjectDir $script:sendTempRoot -Manifest ([ordered]@{
            version = 2
            session = [ordered]@{ name = 'winsmux-orchestra'; generation_id = 'generation-send'; server_session_id = '$41'; session_ready = $true }
            panes = [ordered]@{
                'worker-2' = [ordered]@{ slot_id = 'worker-2'; pane_id = '%3'; worker_backend = 'codex'; role = 'Worker'; title = 'W2'; status = 'ready'; runtime_ready = $true }
            }
            tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
            worktrees = [ordered]@{}
        })
        Mock Get-Labels { @{ 'worker-1' = '%99' } }

        Push-Location $script:sendTempRoot
        try {
            { Resolve-Target 'worker-1' } | Should -Throw '*managed manifest does not contain target*'
        } finally {
            Pop-Location
        }
    }

    It 'TASK781 C38 refuses an omitted managed label before creating an artifact or sending' {
        New-Item -ItemType Directory -Path (Join-Path $script:sendTempRoot '.winsmux') -Force | Out-Null
        Save-WinsmuxManifest -ProjectDir $script:sendTempRoot -Manifest ([ordered]@{
            version = 2
            session = [ordered]@{ name = 'winsmux-orchestra'; generation_id = 'generation-send'; server_session_id = '$41'; session_ready = $true }
            panes = [ordered]@{
                'worker-2' = [ordered]@{ slot_id = 'worker-2'; pane_id = '%3'; worker_backend = 'codex'; role = 'Worker'; title = 'W2'; status = 'ready'; runtime_ready = $true }
            }
            tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
            worktrees = [ordered]@{}
        })
        Mock Get-Labels { @{ 'worker-1' = '%99' } }
        Mock Resolve-TerminalBackend { 'tauri' }
        Mock Stop-WithError { param([string]$Message) throw $Message }
        Mock Send-ResolvedTransportPlan { throw 'send must not occur' }

        Push-Location $script:sendTempRoot
        try {
            { Invoke-Send -SendTarget 'worker-1' -SendArguments @(('x' * 5000)) } |
                Should -Throw '*managed manifest does not contain target*'
        } finally {
            Pop-Location
        }

        Test-Path -LiteralPath (Join-Path $script:sendTempRoot '.winsmux\dispatch-prompts') | Should -BeFalse
        Assert-MockCalled Send-ResolvedTransportPlan -Times 0 -Exactly
    }

    It 'TASK781 C39 refuses a stale role label before pane or persistent-state mutation' {
        New-Item -ItemType Directory -Path (Join-Path $script:sendTempRoot '.winsmux') -Force | Out-Null
        Save-WinsmuxManifest -ProjectDir $script:sendTempRoot -Manifest ([ordered]@{
            version = 2
            session = [ordered]@{ name = 'winsmux-orchestra'; generation_id = 'generation-role'; server_session_id = '$41'; session_ready = $true }
            panes = [ordered]@{
                'worker-2' = [ordered]@{ slot_id = 'worker-2'; pane_id = '%3'; worker_backend = 'codex'; role = 'Worker'; title = 'W2'; status = 'ready'; runtime_ready = $true }
            }
            tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
            worktrees = [ordered]@{}
        })
        $script:c39MutationAttempts = 0
        Mock Get-Labels { @{ 'worker-1' = '%99' } }
        Mock Stop-WithError { param([string]$Message) throw $Message }
        Mock Get-ManagedPaneLifecycleMutationRefusal { $null }
        Mock Get-BridgeSettings { [ordered]@{} }
        Mock Get-SlotAgentConfig {
            [pscustomobject]@{
                Agent = 'codex'; Model = ''; ModelSource = 'provider-default'; ReasoningEffort = '';
                McpMode = ''; CapabilityAdapter = 'codex'; CapabilityCommand = 'codex';
                HarnessAvailability = ''; CredentialRequirements = ''; ExecutionBackend = '';
                RuntimeRequirements = ''; AnalysisPosture = ''; SupportsParallelRuns = $false;
                SupportsInterrupt = $false; SupportsStructuredResult = $false; SupportsFileEdit = $true;
                SupportsSubagents = $false; SupportsVerification = $true; SupportsConsultation = $false;
                SupportsContextReset = $false
            }
        }
        Mock Get-BridgeProviderLaunchCommand { 'codex' }
        Mock Invoke-WinsmuxRaw {
            $script:c39MutationAttempts++
            throw 'pane mutation must not occur'
        }
        Mock Save-Labels {
            $script:c39MutationAttempts++
            throw 'label mutation must not occur'
        }
        Mock Set-PaneControlManifestPaneProperties {
            $script:c39MutationAttempts++
            throw 'manifest mutation must not occur'
        }

        $Target = 'worker-1'
        $Rest = @('reviewer')
        Push-Location $script:sendTempRoot
        try {
            { Invoke-Role } | Should -Throw '*managed manifest does not contain target*'
        } finally {
            Pop-Location
        }

        $script:c39MutationAttempts | Should -Be 0
        Assert-MockCalled Save-Labels -Times 0 -Exactly
        Assert-MockCalled Set-PaneControlManifestPaneProperties -Times 0 -Exactly
    }

    It 'TASK781 refuses a managed direct pane send when manifest context does not resolve' {
        $script:sendSessionProjectDir = $script:sendTempRoot
        New-Item -ItemType Directory -Path (Join-Path $script:sendTempRoot '.winsmux') -Force | Out-Null
        Save-WinsmuxManifest -ProjectDir $script:sendTempRoot -Manifest ([ordered]@{
            version = 2
            session = [ordered]@{ name = 'winsmux-orchestra'; generation_id = 'generation-send'; server_session_id = '$41'; session_ready = $true }
            panes = [ordered]@{
                'worker-1' = [ordered]@{ slot_id = 'worker-1'; pane_id = '%2'; worker_backend = 'codex'; role = 'Worker'; title = 'W1'; status = 'ready'; runtime_ready = $true }
            }
            tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
            worktrees = [ordered]@{}
        })
        Mock Resolve-Target { '%99' }
        Mock Resolve-TerminalBackend { 'tauri' }
        Mock Stop-WithError { param([string]$Message) throw $Message }
        Mock Send-ResolvedTransportPlan { throw 'send must not occur' }

        Push-Location $script:sendTempRoot
        try {
            { Invoke-Send -SendTarget '%99' -SendArguments @('typed payload') } | Should -Throw '*manifest_regeneration_required*'
        } finally {
            Pop-Location
        }
        Assert-MockCalled Send-ResolvedTransportPlan -Times 0 -Exactly
    }

    It 'TASK781 revalidates deferred bootstrap delivery even when recursive start is skipped' {
        $script:sendSessionProjectDir = $script:sendTempRoot
        New-Item -ItemType Directory -Path (Join-Path $script:sendTempRoot '.winsmux') -Force | Out-Null
        Save-WinsmuxManifest -ProjectDir $script:sendTempRoot -Manifest ([ordered]@{
            version = 2
            session = [ordered]@{ name = 'winsmux-orchestra'; generation_id = 'generation-send'; server_session_id = '$41'; session_ready = $true }
            panes = [ordered]@{
                'worker-1' = [ordered]@{ slot_id = 'worker-1'; pane_id = '%2'; worker_backend = 'codex'; role = 'Worker'; title = 'W1'; status = 'deferred_starting'; runtime_ready = $false }
            }
            tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
            worktrees = [ordered]@{}
        })
        Mock Resolve-Target { '%2' }
        Mock Resolve-TerminalBackend { 'tauri' }
        Mock Get-SlotAgentConfig { [PSCustomObject]@{ Agent = 'codex'; Model = 'gpt-5.5'; PromptTransport = 'argv'; CapabilityAdapter = 'codex'; CapabilityCommand = 'codex' } }
        Mock Test-PaneControlRuntimeContext { New-WinsmuxRuntimeValidationResult -Valid $false -ReasonCode 'invalid_supervisor_identity' -Diagnostic 'lease expired before bootstrap delivery' }
        Mock Stop-WithError { param([string]$Message) throw $Message }
        Mock Send-ResolvedTransportPlan { throw 'send must not occur' }

        Push-Location $script:sendTempRoot
        try {
            { Invoke-Send -SendTarget '%2' -SendArguments @('bootstrap') -DeliveryClass launch -SkipDeferredPaneStart } | Should -Throw '*invalid_supervisor_identity*'
        } finally {
            Pop-Location
        }
        Assert-MockCalled Send-ResolvedTransportPlan -Times 0 -Exactly
    }

    It 'TASK781 C14 validates final runtime before creating a long prompt artifact' {
        $script:sendSessionProjectDir = $script:sendTempRoot
        New-Item -ItemType Directory -Path (Join-Path $script:sendTempRoot '.winsmux') -Force | Out-Null
        Save-WinsmuxManifest -ProjectDir $script:sendTempRoot -Manifest ([ordered]@{
            version = 2
            session = [ordered]@{ name = 'winsmux-orchestra'; generation_id = 'G1'; server_session_id = '$41'; session_ready = $true }
            panes = [ordered]@{
                'worker-1' = [ordered]@{
                    slot_id = 'worker-1'; pane_id = '%2'; worker_backend = 'codex'; role = 'Worker'; title = 'W1'
                    status = 'ready'; runtime_ready = $true; exec_mode = $false
                }
            }
            tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
            worktrees = [ordered]@{}
        })
        $manifestPath = Join-Path (Join-Path $script:sendTempRoot '.winsmux') 'manifest.yaml'
        $script:c14Context = [PSCustomObject]@{
            ManifestPath = $manifestPath; ProjectDir = $script:sendTempRoot; SessionName = 'winsmux-orchestra'
            Label = 'worker-1'; PaneId = '%2'; Role = 'Worker'; Status = 'ready'; SecurityPolicy = $null
            LaunchDir = $script:sendTempRoot; GitWorktreeDir = (Join-Path $script:sendTempRoot '.git')
            Branch = 'codex/task-781'; HeadSha = 'abc781'
        }
        $script:c14GuardCalls = [System.Collections.Generic.List[object]]::new()
        $script:c14DeferredStartCalls = 0
        $script:c14ResolvedSendCount = 0
        $script:c14TextSendCount = 0
        $script:c14RestoreCalls = 0
        $taskPromptPath = Get-TaskPromptPath -TaskSlug 'lease-before-materialization' -ProjectDir $script:sendTempRoot
        Write-ClmSafeTextFile -Path $taskPromptPath -Content 'existing prompt evidence'
        $taskPromptHashBefore = (Get-FileHash -LiteralPath $taskPromptPath -Algorithm SHA256).Hash
        $taskPromptMtimeBefore = (Get-Item -LiteralPath $taskPromptPath).LastWriteTimeUtc

        Mock Resolve-Target { '%2' }
        Mock Resolve-TerminalBackend { 'tauri' }
        Mock Get-SlotAgentConfig {
            [PSCustomObject]@{
                Agent = 'codex'; Model = 'gpt-5.5'; PromptTransport = 'argv'
                CapabilityAdapter = 'codex'; CapabilityCommand = 'codex'
            }
        }
        Mock Get-RoleAgentConfig {
            [PSCustomObject]@{
                Agent = 'codex'; Model = 'gpt-5.5'; PromptTransport = 'argv'
                CapabilityAdapter = 'codex'; CapabilityCommand = 'codex'
            }
        }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            param($PaneId, $CurrentProjectDir, $Operation, $ExpectedGenerationId)
            $script:c14GuardCalls.Add([PSCustomObject][ordered]@{
                operation = [string]$Operation
                expected_generation_id = [string]$ExpectedGenerationId
            }) | Out-Null
            if ($script:c14GuardCalls.Count -le 2) {
                return [PSCustomObject]@{
                    Managed = $true; ProjectDir = $script:sendTempRoot; Context = $script:c14Context
                    Operation = 'dispatch'; GenerationId = 'G1'
                    Validation = (New-WinsmuxRuntimeValidationResult -Valid $true -ReasonCode 'dispatch_verified' -Diagnostic 'synthetic runtime verified')
                }
            }
            throw 'runtime dispatch refused (invalid_supervisor_identity): lease expired before final send validation'
        }
        Mock Start-DeferredPaneFromManifestEntry {
            $script:c14DeferredStartCalls++
            return $false
        }
        Mock Send-ResolvedTransportPlan { $script:c14ResolvedSendCount++ }
        Mock Send-TextToPane { $script:c14TextSendCount++ }
        Mock Restore-SendPromptArtifactCheckpoint { $script:c14RestoreCalls++ }

        $errorText = ''
        Push-Location $script:sendTempRoot
        try {
            try {
                Invoke-Send -SendTarget '%2' -SendArguments @('--expected-generation-id', 'G-client', '--task-slug', 'lease-before-materialization', ('x' * 5000))
            } catch {
                $errorText = [string]$_.Exception.Message
            }
        } finally {
            Pop-Location
        }

        $invokeSendSource = [regex]::Match(
            $script:winsmuxCoreSendRawContent,
            '(?s)function Invoke-Send \{.*?\r?\n\}\r?\n\r?\nfunction Invoke-Name'
        ).Value
        $transportIntentIndex = $invokeSendSource.IndexOf('Resolve-SendTransportIntent', [System.StringComparison]::Ordinal)
        $transportMaterializationIndex = $invokeSendSource.IndexOf('New-SendTransportPlan', [System.StringComparison]::Ordinal)
        $checkpointIndex = $invokeSendSource.IndexOf('New-SendPromptArtifactCheckpoint', [System.StringComparison]::Ordinal)
        $postCheckpointGuardIndex = $invokeSendSource.IndexOf('Assert-SendPaneRuntimeLease', $checkpointIndex, [System.StringComparison]::Ordinal)
        $promptDir = Join-Path (Join-Path $script:sendTempRoot '.winsmux') 'dispatch-prompts'
        $actual = [ordered]@{
            error = $errorText
            prompt_dir_exists = Test-Path -LiteralPath $promptDir -PathType Container
            resolved_send_count = $script:c14ResolvedSendCount
            text_send_count = $script:c14TextSendCount
            guard_calls = $script:c14GuardCalls.Count
            guard_sequence = @($script:c14GuardCalls)
            deferred_start_calls = $script:c14DeferredStartCalls
            restore_calls = $script:c14RestoreCalls
            prompt_hash_unchanged = ((Get-FileHash -LiteralPath $taskPromptPath -Algorithm SHA256).Hash -ceq $taskPromptHashBefore)
            prompt_mtime_unchanged = ((Get-Item -LiteralPath $taskPromptPath).LastWriteTimeUtc -eq $taskPromptMtimeBefore)
            pure_intent_precedes_checkpoint = (
                $transportIntentIndex -ge 0 -and $checkpointIndex -ge 0 -and $transportIntentIndex -lt $checkpointIndex
            )
            checkpoint_guard_precedes_materialization = (
                $checkpointIndex -ge 0 -and $postCheckpointGuardIndex -gt $checkpointIndex -and
                $transportMaterializationIndex -gt $postCheckpointGuardIndex
            )
        }
        $expected = [ordered]@{
            error = 'runtime dispatch refused (invalid_supervisor_identity): lease expired before final send validation'
            prompt_dir_exists = $false
            resolved_send_count = 0
            text_send_count = 0
            guard_calls = 3
            guard_sequence = @(
                [PSCustomObject][ordered]@{ operation = 'auto'; expected_generation_id = 'G-client' }
                [PSCustomObject][ordered]@{ operation = 'dispatch'; expected_generation_id = 'G-client' }
                [PSCustomObject][ordered]@{ operation = 'dispatch'; expected_generation_id = 'G-client' }
            )
            deferred_start_calls = 1
            restore_calls = 0
            prompt_hash_unchanged = $true
            prompt_mtime_unchanged = $true
            pure_intent_precedes_checkpoint = $true
            checkpoint_guard_precedes_materialization = $true
        }
        ($actual | ConvertTo-Json -Depth 8 -Compress) | Should -Be ($expected | ConvertTo-Json -Depth 8 -Compress)
    }

    It 'TASK781 C29 restores an existing task prompt when the lease expires after materialization' {
        $script:sendSessionProjectDir = $script:sendTempRoot
        New-Item -ItemType Directory -Path (Join-Path $script:sendTempRoot '.winsmux') -Force | Out-Null
        Save-WinsmuxManifest -ProjectDir $script:sendTempRoot -Manifest ([ordered]@{
            version = 2
            session = [ordered]@{ name = 'winsmux-orchestra'; generation_id = 'G1'; server_session_id = '$41'; session_ready = $true }
            panes = [ordered]@{
                'worker-1' = [ordered]@{
                    slot_id = 'worker-1'; pane_id = '%2'; worker_backend = 'codex'; role = 'Worker'; title = 'W1'
                    status = 'ready'; runtime_ready = $true; exec_mode = $false
                }
            }
            tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
            worktrees = [ordered]@{}
        })
        $manifestPath = Join-Path (Join-Path $script:sendTempRoot '.winsmux') 'manifest.yaml'
        $script:c29SendContext = [PSCustomObject]@{
            ManifestPath = $manifestPath; ProjectDir = $script:sendTempRoot; SessionName = 'winsmux-orchestra'
            Label = 'worker-1'; PaneId = '%2'; Role = 'Worker'; Status = 'ready'; SecurityPolicy = $null
            LaunchDir = $script:sendTempRoot; GitWorktreeDir = (Join-Path $script:sendTempRoot '.git')
            Branch = 'codex/task-781'; HeadSha = 'abc781'
        }
        $taskPromptPath = Get-TaskPromptPath -TaskSlug 'lease-rollback' -ProjectDir $script:sendTempRoot
        Write-ClmSafeTextFile -Path $taskPromptPath -Content 'previous prompt evidence'
        $taskPromptHashBefore = (Get-FileHash -LiteralPath $taskPromptPath -Algorithm SHA256).Hash
        $script:c29SendGuardCalls = 0

        Mock Resolve-Target { '%2' }
        Mock Resolve-TerminalBackend { 'tauri' }
        Mock Get-SlotAgentConfig {
            [PSCustomObject]@{
                Agent = 'codex'; Model = 'gpt-5.5'; PromptTransport = 'argv'
                CapabilityAdapter = 'codex'; CapabilityCommand = 'codex'
            }
        }
        Mock Assert-WinsmuxTargetRuntimeWriteAllowed {
            param($PaneId, $CurrentProjectDir, $Operation, $ExpectedGenerationId)
            $script:c29SendGuardCalls++
            if ($script:c29SendGuardCalls -eq 1) {
                return [PSCustomObject]@{
                    Managed = $true; ProjectDir = $script:sendTempRoot; Context = $script:c29SendContext
                    Operation = 'dispatch'; GenerationId = 'G1'
                }
            }
            if ($script:c29SendGuardCalls -eq 2) {
                return [PSCustomObject]@{ Managed = $true; ProjectDir = $script:sendTempRoot; Operation = 'dispatch'; GenerationId = 'G1' }
            }
            throw 'runtime dispatch refused (invalid_supervisor_identity): generation expired after prompt materialization'
        }
        Mock Start-DeferredPaneFromManifestEntry { return $false }
        Mock Send-ResolvedTransportPlan {
            throw 'runtime dispatch refused (invalid_supervisor_identity): generation expired after prompt materialization'
        }

        $errorText = ''
        Push-Location $script:sendTempRoot
        try {
            try {
                Invoke-Send -SendTarget '%2' -SendArguments @('--task-slug', 'lease-rollback', 'replacement prompt')
            } catch {
                $errorText = [string]$_.Exception.Message
            }
        } finally {
            Pop-Location
        }

        $errorText | Should -Match 'invalid_supervisor_identity'
        $script:c29SendGuardCalls | Should -BeGreaterOrEqual 3
        (Get-Content -LiteralPath $taskPromptPath -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should -BeExactly 'previous prompt evidence'
        (Get-FileHash -LiteralPath $taskPromptPath -Algorithm SHA256).Hash | Should -Be $taskPromptHashBefore
        Test-Path -LiteralPath ($taskPromptPath + '.tmp') | Should -BeFalse
    }

    It 'TASK781 C29 removes a newly materialized unique prompt artifact during rollback' {
        $intent = Resolve-SendTransportIntent -Text ('x' * 5000) -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 -PromptTransport argv
        $checkpoint = New-SendPromptArtifactCheckpoint -ProjectDir $script:sendTempRoot -Intent $intent
        $plan = New-SendTransportPlan -Text ('x' * 5000) -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 -PromptTransport argv -Intent $intent
        $promptDir = Get-DispatchPromptDirectory -ProjectDir $script:sendTempRoot

        Test-Path -LiteralPath ([string]$plan['PromptPath']) -PathType Leaf | Should -BeTrue
        Restore-SendPromptArtifactCheckpoint -Checkpoint $checkpoint -MaterializedPromptPath ([string]$plan['PromptPath'])

        Test-Path -LiteralPath ([string]$plan['PromptPath']) | Should -BeFalse
        Test-Path -LiteralPath $promptDir | Should -BeFalse
    }

    It 'TASK781 C29 refuses rollback cleanup outside its dispatch prompt directory' {
        $intent = Resolve-SendTransportIntent -Text ('x' * 5000) -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 -PromptTransport argv
        $checkpoint = New-SendPromptArtifactCheckpoint -ProjectDir $script:sendTempRoot -Intent $intent
        $outsidePath = Join-Path $script:sendTempRoot 'outside-evidence.txt'
        Write-ClmSafeTextFile -Path $outsidePath -Content 'preserve outside evidence'

        {
            Restore-SendPromptArtifactCheckpoint -Checkpoint $checkpoint -MaterializedPromptPath $outsidePath
        } | Should -Throw '*outside its rollback checkpoint*'

        (Get-Content -LiteralPath $outsidePath -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should -BeExactly 'preserve outside evidence'
    }

    It 'TASK781 C53 serializes same-slug materialization and makes an expired rollback ownership-safe' {
        $taskPromptPath = Get-TaskPromptPath -TaskSlug 'concurrent-owner' -ProjectDir $script:sendTempRoot
        Write-ClmSafeTextFile -Path $taskPromptPath -Content 'original evidence'
        $intent = Resolve-SendTransportIntent -Text 'first materialization' -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 -PromptTransport argv -TaskSlug 'concurrent-owner'
        $firstCheckpoint = New-SendPromptArtifactCheckpoint -ProjectDir $script:sendTempRoot -Intent $intent
        $firstPlan = New-SendTransportPlan -Text 'first materialization' -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 -PromptTransport argv -TaskSlug 'concurrent-owner' -Intent $intent

        {
            $competingLease = [System.IO.File]::Open(
                [string]$firstCheckpoint.LeasePath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            $competingLease.Dispose()
        } | Should -Throw

        Restore-SendPromptArtifactCheckpoint -Checkpoint $firstCheckpoint -MaterializedPromptPath ([string]$firstPlan['PromptPath'])

        $secondIntent = Resolve-SendTransportIntent -Text 'second materialization' -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 -PromptTransport argv -TaskSlug 'concurrent-owner'
        $secondCheckpoint = New-SendPromptArtifactCheckpoint -ProjectDir $script:sendTempRoot -Intent $secondIntent
        $secondPlan = New-SendTransportPlan -Text 'second materialization' -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 -PromptTransport argv -TaskSlug 'concurrent-owner' -Intent $secondIntent

        Restore-SendPromptArtifactCheckpoint -Checkpoint $firstCheckpoint -MaterializedPromptPath ([string]$firstPlan['PromptPath'])
        (Get-Content -LiteralPath $taskPromptPath -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should -BeExactly 'second materialization'

        Restore-SendPromptArtifactCheckpoint -Checkpoint $secondCheckpoint -MaterializedPromptPath ([string]$secondPlan['PromptPath'])
        (Get-Content -LiteralPath $taskPromptPath -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should -BeExactly 'original evidence'
        Test-Path -LiteralPath ($taskPromptPath + '.send.lock') | Should -BeFalse
    }

    It 'resolves restart readiness through dictionary capability adapters' {
        $plan = [ordered]@{
            Agent = 'codex-nightly'
            CapabilityAdapter = 'codex'
        }

        Get-RestartReadinessAgentName -Plan $plan | Should -Be 'codex'
    }

    It 'writes long text to a dispatch file and returns a prompt pointer for non-exec panes' {
        $longText = 'a' * 4001

        $payload = Resolve-SendDispatchPayload -Text $longText -ProjectDir $script:sendTempRoot -LengthLimit 4000

        $payload['IsFileBacked'] | Should -Be $true
        $payload['TextToSend'] | Should -Not -Be $longText
        $payload['FallbackMode'] | Should -Be 'pointer'
        $payload['TextToSend'] | Should -Match "Read the full prompt from '"
        $payload['PromptPath'] | Should -Not -BeNullOrEmpty
        $payload['PromptReference'] | Should -BeLike '.winsmux/dispatch-prompts/*'
        $promptContent = Get-Content -LiteralPath $payload['PromptPath'] -Raw -Encoding UTF8
        $promptContent.TrimEnd("`r", "`n") | Should -BeExactly $longText
        $payload['TextToSend'] | Should -Match ([regex]::Escape($payload['PromptReference']))
    }

    It 'defers an oversized prompt pointer until the agent prompt is ready' {
        $script:pointerReadinessProbes = 0
        $script:pointerProbeCountAtSend = 0

        Mock Test-AgentReadyPrompt {
            $script:pointerReadinessProbes++
            return $script:pointerReadinessProbes -ge 2
        }
        Mock Start-Sleep { }
        Mock Send-TextToPane {
            $script:pointerProbeCountAtSend = $script:pointerReadinessProbes
            return "sent to $PaneId"
        }

        $result = Send-PromptPointerWhenAgentReady `
            -PaneId '%2' `
            -PointerText "Read the full prompt from '.winsmux/dispatch-prompts/race.txt' and follow it exactly." `
            -Agent 'codex' `
            -PromptTransport 'argv' `
            -TimeoutSeconds 5

        $result | Should -Be 'sent to %2'
        $script:pointerReadinessProbes | Should -Be 2
        $script:pointerProbeCountAtSend | Should -Be 2
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 250 }
        Should -Invoke Send-TextToPane -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%2' -and
            $CommandText -like "Read the full prompt from*" -and
            $PromptTransport -eq 'argv'
        }
    }

    It 'delivers an oversized launch pointer immediately without agent readiness' {
        $launchMarkerPath = Join-Path $script:sendTempRoot 'launch-ran.txt'
        $launchCommand = "[System.IO.File]::WriteAllText(" +
            (ConvertTo-DispatchPowerShellLiteral -Value $launchMarkerPath) +
            ", 'launched', [System.Text.UTF8Encoding]::new(`$false))`n# " + ('a' * 4001)
        $overflowPlan = Resolve-SendTransportPlan `
            -Text $launchCommand `
            -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 `
            -PromptTransport 'argv'

        Mock Get-PaneReadinessAgent { throw 'launch delivery must not resolve agent readiness' }
        Mock Send-PromptPointerWhenAgentReady { throw 'launch delivery must not wait for agent readiness' }
        Mock Send-TextToPane {
            & ([scriptblock]::Create($CommandText))
            return "sent to $PaneId"
        }

        $result = Send-ResolvedTransportPlan `
            -PaneId '%2' `
            -TransportPlan $overflowPlan `
            -DeliveryClass 'launch' `
            -Target 'worker-1' `
            -ProjectDir $script:sendTempRoot `
            -AgentConfig ([ordered]@{ Agent = 'codex'; CapabilityAdapter = 'codex' })

        $result | Should -Be 'sent to %2'
        Should -Invoke Get-PaneReadinessAgent -Times 0 -Exactly
        Should -Invoke Send-PromptPointerWhenAgentReady -Times 0 -Exactly
        Should -Invoke Send-TextToPane -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%2' -and
            $CommandText -match 'ReadAllText' -and
            $CommandText -notmatch 'Read the full prompt from' -and
            $PromptTransport -eq 'argv'
        }
        Get-Content -Raw -LiteralPath $launchMarkerPath -Encoding UTF8 | Should -BeExactly 'launched'
    }

    It 'rejects an argv-supplied launch delivery class' {
        {
            Resolve-SendInvocationArguments -Arguments @(
                '--delivery-class',
                'launch',
                'pwsh -NoProfile -File bootstrap.ps1 -PlanFile plan.json'
            )
        } | Should -Throw '*--delivery-class is internal-only*'
    }

    It 'D03 separates and validates an explicit send generation lease from prompt text' {
        $resolved = Resolve-SendInvocationArguments -Arguments @(
            '--expected-generation-id',
            'generation-123',
            '--task-slug',
            'declarative-node',
            'typed payload'
        )

        $resolved['ExpectedGenerationId'] | Should -BeExactly 'generation-123'
        $resolved['TaskSlug'] | Should -BeExactly 'declarative-node'
        @($resolved['MessageParts']) | Should -Be @('typed payload')
        { Resolve-SendInvocationArguments -Arguments @('--expected-generation-id') } | Should -Throw '*--expected-generation-id requires a value*'
        { Resolve-SendInvocationArguments -Arguments @('--expected-generation-id', 'Generation_123', 'typed payload') } | Should -Throw '*invalid expected generation id*'
    }

    It 'routes an oversized prompt pointer through agent readiness' {
        $overflowPlan = Resolve-SendTransportPlan `
            -Text ('a' * 4001) `
            -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 `
            -PromptTransport 'argv'

        Mock Get-PaneReadinessAgent { return 'codex' }
        Mock Send-PromptPointerWhenAgentReady { return "sent to $PaneId" }
        Mock Send-TextToPane { throw 'oversized prompt delivery must use agent readiness' }

        $result = Send-ResolvedTransportPlan `
            -PaneId '%2' `
            -TransportPlan $overflowPlan `
            -DeliveryClass 'prompt' `
            -Target 'worker-1' `
            -ProjectDir $script:sendTempRoot `
            -AgentConfig ([ordered]@{ Agent = 'codex'; CapabilityAdapter = 'codex' })

        $result | Should -Be 'sent to %2'
        Should -Invoke Get-PaneReadinessAgent -Times 1 -Exactly
        Should -Invoke Send-PromptPointerWhenAgentReady -Times 1 -Exactly -ParameterFilter {
            $PaneId -eq '%2' -and
            $PointerText -like "Read the full prompt from*" -and
            $Agent -eq 'codex' -and
            $PromptTransport -eq 'argv'
        }
        Should -Invoke Send-TextToPane -Times 0 -Exactly
    }

    It 'keeps non-oversized send transports outside the pointer readiness gate' {
        $inlinePlan = Resolve-SendTransportPlan `
            -Text 'Write-Host short' `
            -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 `
            -PromptTransport 'argv'
        $configuredFilePlan = Resolve-SendTransportPlan `
            -Text 'Write-Host short' `
            -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 `
            -PromptTransport 'file'
        $overflowPlan = Resolve-SendTransportPlan `
            -Text ('a' * 4001) `
            -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 `
            -PromptTransport 'argv'

        Test-SendTransportRequiresPointerReadiness -TransportPlan $inlinePlan | Should -BeFalse
        Test-SendTransportRequiresPointerReadiness -TransportPlan $configuredFilePlan | Should -BeFalse
        Test-SendTransportRequiresPointerReadiness -TransportPlan $overflowPlan | Should -BeTrue
    }

    It 'always writes a dispatch file when prompt_transport is file' {
        $payload = Resolve-SendDispatchPayload -Text 'Write-Host short' -ProjectDir $script:sendTempRoot -LengthLimit 4000 -PromptTransport 'file'

        $payload['PromptTransport'] | Should -Be 'file'
        $payload['IsFileBacked'] | Should -Be $true
        $payload['TextToSend'] | Should -Match "Read the full prompt from '"
        $payload['PromptPath'] | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $payload['PromptPath'] -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should -BeExactly 'Write-Host short'
    }

    It 'normalizes blank prompt_transport to argv' {
        $payload = Resolve-SendDispatchPayload -Text 'Write-Host short' -ProjectDir $script:sendTempRoot -LengthLimit 4000 -PromptTransport '   '

        $payload['PromptTransport'] | Should -Be 'argv'
        $payload['IsFileBacked'] | Should -Be $false
    }

    It 'keeps stdin prompt_transport inline even when the payload exceeds the argv length limit' {
        $payload = Resolve-SendDispatchPayload -Text ('a' * 5000) -ProjectDir $script:sendTempRoot -LengthLimit 4000 -PromptTransport 'stdin'

        $payload['PromptTransport'] | Should -Be 'stdin'
        $payload['IsFileBacked'] | Should -Be $false
        $payload['PromptPath'] | Should -Be $null
        $payload['TextLength'] | Should -Be 5000
    }

    It 'keeps exec-mode transport file-backed even when prompt_transport is stdin' {
        $plan = Resolve-SendTransportPlan `
            -Text ('a' * 5000) `
            -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 `
            -PromptTransport 'stdin' `
            -ExecMode:$true `
            -LaunchDir 'C:\repo' `
            -GitWorktreeDir 'C:\repo' `
            -Model 'gpt-5.4'

        $plan['Mode'] | Should -Be 'codex_exec_file'
        $plan['PromptTransport'] | Should -Be 'stdin'
        $plan['IsFileBacked'] | Should -Be $true
        $plan['FallbackMode'] | Should -Be 'exec_file'
        $plan['PromptPath'] | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $plan['PromptPath'] -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should -BeExactly ('a' * 5000)
        $plan['ExecInstruction'] | Should -Match 'codex exec'
    }

    It 'uses the provider capability command for exec-mode send plans' {
        $plan = Resolve-SendTransportPlan `
            -Text 'Summarize status' `
            -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 `
            -PromptTransport 'argv' `
            -ExecMode:$true `
            -LaunchDir 'C:\repo' `
            -GitWorktreeDir 'C:\repo' `
            -Model 'gpt-5.4-nightly' `
            -ExecCommand 'codex-nightly'

        $plan['Mode'] | Should -Be 'codex_exec_file'
        $plan['ExecInstruction'] | Should -Match '^codex-nightly exec'
        $plan['ExecInstruction'] | Should -Not -Match '^codex exec'
    }

    It 'quotes provider capability executable paths for exec-mode send plans' {
        $plan = Resolve-SendTransportPlan `
            -Text 'Summarize status' `
            -ProjectDir $script:sendTempRoot `
            -LengthLimit 4000 `
            -PromptTransport 'argv' `
            -ExecMode:$true `
            -LaunchDir 'C:\repo' `
            -GitWorktreeDir 'C:\repo' `
            -Model 'gpt-5.4-nightly' `
            -ExecCommand 'C:\Tools\Codex Nightly\codex.exe'

        $plan['Mode'] | Should -Be 'codex_exec_file'
        $plan['ExecInstruction'] | Should -Match "^& 'C:\\Tools\\Codex Nightly\\codex.exe' exec"
    }

    It 'normalizes task prompt slugs and writes a stable task prompt file when task_slug is supplied' {
        (ConvertTo-TaskPromptSlug -TaskSlug ' Cache Drift / Build ') | Should -Be 'cache-drift-build'

        $payload = Resolve-SendDispatchPayload -Text 'Write-Host short' -ProjectDir $script:sendTempRoot -LengthLimit 4000 -TaskSlug ' Cache Drift / Build '

        $payload['TaskSlug'] | Should -Be 'cache-drift-build'
        $payload['IsFileBacked'] | Should -Be $true
        $payload['FallbackMode'] | Should -Be 'task_file'
        $payload['PromptPath'] | Should -Be (Join-Path $script:sendTempRoot '.winsmux\task-cache-drift-build.md')
        $payload['PromptReference'] | Should -Be '.winsmux/task-cache-drift-build.md'
        (Get-Content -LiteralPath $payload['PromptPath'] -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should -BeExactly 'Write-Host short'
    }

    It 'overwrites the same task prompt path when the same task_slug is reused' {
        $first = Resolve-SendDispatchPayload -Text 'first prompt' -ProjectDir $script:sendTempRoot -LengthLimit 4000 -TaskSlug 'cache-drift'
        $second = Resolve-SendDispatchPayload -Text 'second prompt' -ProjectDir $script:sendTempRoot -LengthLimit 4000 -TaskSlug 'cache-drift'

        $first['PromptPath'] | Should -Be $second['PromptPath']
        $second['PromptReference'] | Should -Be '.winsmux/task-cache-drift.md'
        (Get-Content -LiteralPath $second['PromptPath'] -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should -BeExactly 'second prompt'
    }

    It 'rejects unsupported prompt transport values with the stable-core contract in the error' {
        { Resolve-SendDispatchPayload -Text 'Write-Host short' -ProjectDir $script:sendTempRoot -LengthLimit 4000 -PromptTransport 'socket' } | Should -Throw '*Supported values: argv, file, stdin*'
    }

    It 'blocks send text when a blocklist security policy pattern matches' {
        $violation = Find-SendSecurityPolicyViolation -Text 'git reset --hard origin/main' -SecurityPolicy ([ordered]@{
            mode = 'blocklist'
            allow_patterns = @('Invoke-Pester')
            block_patterns = @('git reset --hard')
        })

        $violation.verdict | Should -Be 'BLOCK'
        $violation.mode | Should -Be 'blocklist'
        @($violation.block) | Should -Be @('git reset --hard')
    }

    It 'blocks allowlist sends when no allow pattern matches' {
        $violation = Find-SendSecurityPolicyViolation -Text 'Write-Host short' -SecurityPolicy ([ordered]@{
            mode = 'allowlist'
            allow_patterns = @('Invoke-Pester')
            block_patterns = @()
        })

        $violation.verdict | Should -Be 'BLOCK'
        $violation.reason | Should -Match 'allow_patterns'
    }

    It 'F01 durably publishes workflow completion without a pipe listener and enforces channel and create-once identity' {
        $project = Join-Path $script:sendTempRoot 'durable-workflow-mailbox'
        [IO.Directory]::CreateDirectory((Join-Path $project '.winsmux')) | Out-Null
        Save-WinsmuxManifest -ProjectDir $project -Manifest ([ordered]@{
            version = 2
            session = [ordered]@{ name = 'winsmux-orchestra'; generation_id = 'generation-123'; server_session_id = '$41'; session_ready = $true }
            panes = [ordered]@{
                'builder-1' = [ordered]@{ pane_id = '%2'; role = 'Builder'; status = 'ready'; runtime_ready = $true }
            }
            tasks = [ordered]@{ queued = @(); in_progress = @(); completed = @() }
            worktrees = [ordered]@{}
        })
        $payload = [ordered]@{
            mailbox_version = 2; message_id = 'workflow-ack-f01'; correlation_id = 'workflow-ack-f01'; causation_id = $null
            idempotency_key = 'workflow-completion-f01'; message_type = 'workflow-completion'; state = 'created'; ttl_seconds = 300
            ack_required = $true; from = 'builder-1'; to = 'Operator'; timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            content = [ordered]@{
                session = 'winsmux-orchestra'; event = 'workflow.node.acknowledged'; message = 'Declarative workflow completion.'
                label = 'builder-1'; pane_id = '%2'; role = 'Builder'; status = 'succeeded'; exit_reason = ''
                data = [ordered]@{
                    schema_version = 1; run_id = 'run-123'; node_id = 'inspect'; idempotency_key = 'run-123:inspect'
                    generation_id = 'generation-123'; config_fingerprint = ('sha256:' + ('a' * 64)); workflow_fingerprint = ('sha256:' + ('d' * 64))
                    source_head = ('b' * 40); pane_id = '%2'; status = 'succeeded'; evidence_ref = 'workflow-ack:run-123:inspect'
                }
            }
        }
        $json = $payload | ConvertTo-Json -Compress -Depth 20

        Publish-WinsmuxWorkflowCompletionEnvelope -ProjectDir $project -Channel 'winsmux-orchestra-operator' -Payload $json | Out-Null
        $pending = Join-Path $project '.winsmux\mailbox\winsmux-orchestra-operator\pending\workflow-ack-f01.json'
        Test-Path -LiteralPath $pending -PathType Leaf | Should -BeTrue
        [IO.File]::ReadAllText($pending, [Text.UTF8Encoding]::new($false, $true)) | Should -BeExactly $json

        $env:WINSMUX_ORCHESTRA_PROJECT_DIR = $project
        $pwsh = (Get-Process -Id $PID).Path
        $commandOutput = @(& $pwsh -NoLogo -NoProfile -NonInteractive -File $script:winsmuxCorePath mailbox-send 'winsmux-orchestra-operator' $json)
        $LASTEXITCODE | Should -Be 0
        $commandOutput | Should -Contain 'mailbox queued: winsmux-orchestra-operator'
        $changedPayload = $json | ConvertFrom-Json -AsHashtable
        $changedPayload.timestamp = [DateTimeOffset]::UtcNow.AddSeconds(1).ToString('o')
        $changed = $changedPayload | ConvertTo-Json -Compress -Depth 20
        { Publish-WinsmuxWorkflowCompletionEnvelope -ProjectDir $project -Channel 'winsmux-orchestra-operator' -Payload $changed } |
            Should -Throw '*message_id conflict*'
        { Publish-WinsmuxWorkflowCompletionEnvelope -ProjectDir $project -Channel 'wrong-session-operator' -Payload $json } |
            Should -Throw '*channel*'
        (Get-MailboxPipeName ('a' * 65)) | Should -BeExactly ('winsmux-mailbox-' + ('a' * 65))
        { Publish-WinsmuxWorkflowCompletionEnvelope -ProjectDir $project -Channel ('a' * 65) -Payload $json } |
            Should -Throw '*channel*'

        $racePayload = $json | ConvertFrom-Json -AsHashtable
        $racePayload.message_id = 'workflow-ack-race'
        $racePayload.correlation_id = 'workflow-ack-race'
        $racePayload.idempotency_key = 'workflow-completion-race'
        $raceJson = $racePayload | ConvertTo-Json -Compress -Depth 20
        $escapedCorePath = $script:winsmuxCorePath.Replace("'", "''")
        $escapedRaceJson = $raceJson.Replace("'", "''")
        $childCommand = "& '$escapedCorePath' mailbox-send 'winsmux-orchestra-operator' '$escapedRaceJson'; exit `$LASTEXITCODE"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
        $publishers = @(
            Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WindowStyle Hidden -PassThru
            Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WindowStyle Hidden -PassThru
        )
        try {
            foreach ($publisher in $publishers) {
                $publisher.WaitForExit(10000) | Should -BeTrue
                $publisher.ExitCode | Should -Be 0
            }
        } finally {
            foreach ($publisher in $publishers) {
                if (-not $publisher.HasExited) { Stop-Process -Id $publisher.Id -Force -ErrorAction SilentlyContinue }
                $publisher.Dispose()
            }
        }
        $racePending = Join-Path $project '.winsmux\mailbox\winsmux-orchestra-operator\pending\workflow-ack-race.json'
        [IO.File]::ReadAllText($racePending, [Text.UTF8Encoding]::new($false, $true)) | Should -BeExactly $raceJson
    }
}
