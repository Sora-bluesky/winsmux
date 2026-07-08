$ErrorActionPreference = 'Stop'

function New-WinsmuxCommandResult {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [AllowEmptyString()][string]$Status = 'ok',
        [AllowNull()]$Data = $null,
        [AllowEmptyString()][string]$Reason = '',
        [int]$ExitCode = 0
    )

    $ok = ($ExitCode -eq 0 -and $Status -notin @('blocked', 'failed', 'error'))
    return [ordered]@{
        command   = $CommandName
        ok        = [bool]$ok
        status    = $Status
        reason    = $Reason
        exit_code = $ExitCode
        data      = $Data
    }
}

function New-WinsmuxCommandError {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowEmptyString()][string]$Usage = '',
        [int]$ExitCode = 1
    )

    return [ordered]@{
        command   = $CommandName
        ok        = $false
        status    = 'error'
        reason    = $Reason
        message   = $Message
        usage     = $Usage
        exit_code = $ExitCode
    }
}

function Stop-WinsmuxCommandError {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowEmptyString()][string]$Usage = ''
    )

    $script:LastWinsmuxCommandError = New-WinsmuxCommandError -CommandName $CommandName -Reason $Reason -Message $Message -Usage $Usage
    Stop-WithError $Message
}

function Write-WinsmuxCommandResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [switch]$Json,
        [int]$JsonDepth = 16,
        [scriptblock]$TextWriter
    )

    $payload = if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('data')) {
        $Result['data']
    } else {
        $Result.data
    }

    if ($Json) {
        $payload | ConvertTo-Json -Depth $JsonDepth -Compress | Write-Output
        return
    }

    if ($null -ne $TextWriter) {
        & $TextWriter $payload
        return
    }

    $payload | Write-Output
}

function Invoke-WinsmuxLauncherCommand {
    param(
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $usage = "usage: winsmux launcher <presets|lifecycle|list|save> [name] [--lifecycle <preset>] [--json]"
    $tokens = @(@($CommandTarget) + @($CommandRest) | Where-Object { $_ })
    $mode = 'presets'
    $templateName = ''
    $lifecyclePreset = ''
    $clearLifecycleOverride = $false
    $jsonOutput = $false

    for ($index = 0; $index -lt $tokens.Count; $index++) {
        switch ($tokens[$index]) {
            '--json' {
                $jsonOutput = $true
            }
            '--clear' {
                $clearLifecycleOverride = $true
            }
            '--lifecycle' {
                $index++
                if ($index -ge $tokens.Count -or [string]::IsNullOrWhiteSpace([string]$tokens[$index])) {
                    Stop-WinsmuxCommandError -CommandName 'launcher' -Reason 'missing_lifecycle_preset' -Message $usage -Usage $usage
                }

                $lifecyclePreset = [string]$tokens[$index]
            }
            'presets' {
                $mode = 'presets'
            }
            'lifecycle' {
                $mode = 'lifecycle'
            }
            'list' {
                $mode = 'list'
            }
            'save' {
                $mode = 'save'
            }
            default {
                if ([string]::Equals($mode, 'save', [System.StringComparison]::OrdinalIgnoreCase) -and [string]::IsNullOrWhiteSpace($templateName)) {
                    $templateName = [string]$tokens[$index]
                } elseif ([string]::Equals($mode, 'lifecycle', [System.StringComparison]::OrdinalIgnoreCase) -and [string]::IsNullOrWhiteSpace($lifecyclePreset)) {
                    $lifecyclePreset = [string]$tokens[$index]
                } else {
                    Stop-WinsmuxCommandError -CommandName 'launcher' -Reason 'invalid_argument' -Message $usage -Usage $usage
                }
            }
        }
    }

    if ($clearLifecycleOverride -and -not [string]::Equals($mode, 'lifecycle', [System.StringComparison]::OrdinalIgnoreCase)) {
        $lifecycleUsage = "usage: winsmux launcher lifecycle [preset|--clear] [--json]"
        Stop-WinsmuxCommandError -CommandName 'launcher' -Reason 'clear_requires_lifecycle_mode' -Message $lifecycleUsage -Usage $lifecycleUsage
    }

    if ($clearLifecycleOverride -and -not [string]::IsNullOrWhiteSpace($lifecyclePreset)) {
        $lifecycleUsage = "usage: winsmux launcher lifecycle [preset|--clear] [--json]"
        Stop-WinsmuxCommandError -CommandName 'launcher' -Reason 'clear_conflicts_with_lifecycle_preset' -Message $lifecycleUsage -Usage $lifecycleUsage
    }

    $projectDir = (Get-Location).Path
    if ([string]::Equals($mode, 'save', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ([string]::IsNullOrWhiteSpace($templateName)) {
            $saveUsage = "usage: winsmux launcher save <name> [--json]"
            Stop-WinsmuxCommandError -CommandName 'launcher' -Reason 'missing_template_name' -Message $saveUsage -Usage $saveUsage
        }

        $saveResult = Save-LauncherTemplate -ProjectDir $projectDir -Name $templateName -LifecyclePreset $lifecyclePreset
        $result = New-WinsmuxCommandResult -CommandName 'launcher' -Status 'saved' -Data $saveResult
        Write-WinsmuxCommandResult -Result $result -Json:([bool]$jsonOutput) -JsonDepth 32 -TextWriter {
            param($data)
            Write-Output "launcher template saved: $($data.name)"
            Write-Output "templates: $($data.templates_path)"
        }
        return
    }

    if ([string]::Equals($mode, 'list', [System.StringComparison]::OrdinalIgnoreCase)) {
        $listResult = Get-LauncherTemplateListPayload -ProjectDir $projectDir
        $result = New-WinsmuxCommandResult -CommandName 'launcher' -Status 'listed' -Data $listResult
        Write-WinsmuxCommandResult -Result $result -Json:([bool]$jsonOutput) -JsonDepth 32 -TextWriter {
            param($data)
            Write-Output "launcher templates: $($data.template_count)"
            foreach ($template in @($data.templates)) {
                Write-Output "  $($template.name)"
            }
            Write-Output "templates: $($data.templates_path)"
        }
        return
    }

    if ([string]::Equals($mode, 'lifecycle', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($clearLifecycleOverride) {
            $clearedPath = Clear-LauncherWorkspaceLifecycleOverride -ProjectDir $projectDir
            $lifecycleResult = Get-LauncherWorkspaceLifecyclePayload -ProjectDir $projectDir
            $lifecycleResult['override_cleared'] = $true
            $lifecycleResult['cleared_path'] = $clearedPath
        } elseif (-not [string]::IsNullOrWhiteSpace($lifecyclePreset)) {
            $lifecycleResult = Get-LauncherWorkspaceLifecyclePayload -ProjectDir $projectDir -SelectedPreset $lifecyclePreset
            $overridePath = Set-LauncherWorkspaceLifecycleOverride -ProjectDir $projectDir -Preset $lifecyclePreset
            $lifecycleResult['override_saved'] = $true
            $lifecycleResult['saved_path'] = $overridePath
        } else {
            $lifecycleResult = Get-LauncherWorkspaceLifecyclePayload -ProjectDir $projectDir
        }

        $result = New-WinsmuxCommandResult -CommandName 'launcher' -Status 'lifecycle' -Data $lifecycleResult
        Write-WinsmuxCommandResult -Result $result -Json:([bool]$jsonOutput) -JsonDepth 32 -TextWriter {
            param($data)
            Write-Output "workspace lifecycle presets: $(@($data.presets).Count)"
            Write-Output "selected: $($data.selected_preset)"
            foreach ($preset in @($data.presets)) {
                Write-Output "  $($preset.name): setup=$($preset.setup_policy) teardown=$($preset.teardown_policy)"
            }
            Write-Output "project default: $($data.project_default)"
            Write-Output "user override: $($data.user_override)"
            Write-Output "override path: $($data.override_path)"
        }
        return
    }

    $presetPayload = Get-LauncherPresetPayload -ProjectDir $projectDir -LifecyclePreset $lifecyclePreset
    $result = New-WinsmuxCommandResult -CommandName 'launcher' -Status 'presets' -Data $presetPayload
    Write-WinsmuxCommandResult -Result $result -Json:([bool]$jsonOutput) -JsonDepth 16 -TextWriter {
        param($data)
        Write-Output "launcher presets: $(@($data.presets).Count)"
        foreach ($preset in @($data.presets)) {
            Write-Output "  $($preset.name): $($preset.slot_ids -join ',')"
        }
        Write-Output "pair templates: $(@($data.pair_templates).Count)"
        foreach ($pair in @($data.pair_templates)) {
            Write-Output "  $($pair.name): $($pair.left_slot_id),$($pair.right_slot_id)"
        }
        Write-Output "workspace lifecycle: $($data.workspace_lifecycle.selected_preset)"
        Write-Output "templates: $($data.templates_path)"
    }
}

function Invoke-WinsmuxProviderCapabilitiesCommand {
    param(
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $usage = "usage: winsmux provider-capabilities [provider] [--json]"
    $tokens = @(@($CommandTarget) + @($CommandRest) | Where-Object { $_ })
    $providerId = ''
    $jsonOutput = $false

    for ($index = 0; $index -lt $tokens.Count; $index++) {
        switch ($tokens[$index]) {
            '--json' {
                $jsonOutput = $true
            }
            default {
                if ([string]::IsNullOrWhiteSpace($providerId)) {
                    $providerId = [string]$tokens[$index]
                    continue
                }

                Stop-WinsmuxCommandError -CommandName 'provider-capabilities' -Reason 'invalid_argument' -Message $usage -Usage $usage
            }
        }
    }

    $projectDir = (Get-Location).Path
    $registry = Read-BridgeProviderCapabilityRegistry -RootPath $projectDir
    if (-not [string]::IsNullOrWhiteSpace($providerId)) {
        $capabilities = Get-BridgeProviderCapability -RootPath $projectDir -ProviderId $providerId
        if ($null -eq $capabilities) {
            Stop-WinsmuxCommandError -CommandName 'provider-capabilities' -Reason 'provider_not_found' -Message "provider capability '$providerId' was not found."
        }

        $payload = [ordered]@{
            provider_id   = $providerId
            capabilities  = $capabilities
            registry_path = Get-BridgeProviderCapabilityRegistryPath -RootPath $projectDir
        }
        $result = New-WinsmuxCommandResult -CommandName 'provider-capabilities' -Status 'found' -Data $payload
        Write-WinsmuxCommandResult -Result $result -Json:([bool]$jsonOutput) -JsonDepth 16 -TextWriter {
            param($data)
            Write-Output "provider capability $($data.provider_id)"
            foreach ($property in $data.capabilities.GetEnumerator()) {
                $value = $property.Value
                if ($value -is [System.Array]) {
                    $value = ($value -join ',')
                }
                Write-Output "  $($property.Key): $value"
            }
        }
        return
    }

    $payload = [ordered]@{
        version       = [int]$registry.version
        registry_path = Get-BridgeProviderCapabilityRegistryPath -RootPath $projectDir
        providers     = $registry.providers
    }
    $result = New-WinsmuxCommandResult -CommandName 'provider-capabilities' -Status 'listed' -Data $payload
    Write-WinsmuxCommandResult -Result $result -Json:([bool]$jsonOutput) -JsonDepth 16 -TextWriter {
        param($data)
        if ($data.providers.Count -lt 1) {
            Write-Output 'provider capabilities: none'
            return
        }

        Write-Output 'provider capabilities'
        foreach ($entry in $data.providers.GetEnumerator()) {
            Write-Output "  $($entry.Key)"
        }
    }
}

function Invoke-WinsmuxProviderSwitchCommand {
    param(
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $usage = "usage: winsmux provider-switch <slot> [--agent <name>] [--model <name>] [--model-source <source>] [--reasoning-effort <level>] [--prompt-transport <argv|file|stdin>] [--auth-mode <mode>] [--reason <text>] [--restart] [--clear] [--json]"
    $tokens = @(@($CommandTarget) + @($CommandRest) | Where-Object { $_ })
    if ($tokens.Count -lt 1) {
        Stop-WinsmuxCommandError -CommandName 'provider-switch' -Reason 'missing_slot' -Message $usage -Usage $usage
    }

    $slotId = [string]$tokens[0]
    $agent = ''
    $model = ''
    $modelSource = ''
    $reasoningEffort = ''
    $promptTransport = ''
    $authMode = ''
    $reason = ''
    $restartRequested = $false
    $clearRequested = $false
    $jsonOutput = $false

    for ($index = 1; $index -lt $tokens.Count; $index++) {
        switch ($tokens[$index]) {
            '--agent' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WinsmuxCommandError -CommandName 'provider-switch' -Reason 'missing_agent' -Message '--agent requires a value' -Usage $usage
                }
                $agent = [string]$tokens[$index + 1]
                $index++
            }
            '--model' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WinsmuxCommandError -CommandName 'provider-switch' -Reason 'missing_model' -Message '--model requires a value' -Usage $usage
                }
                $model = [string]$tokens[$index + 1]
                $index++
            }
            '--model-source' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WinsmuxCommandError -CommandName 'provider-switch' -Reason 'missing_model_source' -Message '--model-source requires a value' -Usage $usage
                }
                $modelSource = [string]$tokens[$index + 1]
                $index++
            }
            '--reasoning-effort' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WinsmuxCommandError -CommandName 'provider-switch' -Reason 'missing_reasoning_effort' -Message '--reasoning-effort requires a value' -Usage $usage
                }
                $reasoningEffort = [string]$tokens[$index + 1]
                $index++
            }
            '--prompt-transport' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WinsmuxCommandError -CommandName 'provider-switch' -Reason 'missing_prompt_transport' -Message '--prompt-transport requires a value' -Usage $usage
                }
                $promptTransport = [string]$tokens[$index + 1]
                $index++
            }
            '--auth-mode' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WinsmuxCommandError -CommandName 'provider-switch' -Reason 'missing_auth_mode' -Message '--auth-mode requires a value' -Usage $usage
                }
                $authMode = [string]$tokens[$index + 1]
                $index++
            }
            '--reason' {
                if ($index + 1 -ge $tokens.Count) {
                    Stop-WinsmuxCommandError -CommandName 'provider-switch' -Reason 'missing_reason' -Message '--reason requires a value' -Usage $usage
                }
                $reason = [string]$tokens[$index + 1]
                $index++
            }
            '--json' {
                $jsonOutput = $true
            }
            '--restart' {
                $restartRequested = $true
            }
            '--clear' {
                $clearRequested = $true
            }
            default {
                Stop-WinsmuxCommandError -CommandName 'provider-switch' -Reason 'invalid_argument' -Message $usage -Usage $usage
            }
        }
    }

    if ($clearRequested -and (-not [string]::IsNullOrWhiteSpace($agent) -or -not [string]::IsNullOrWhiteSpace($model) -or -not [string]::IsNullOrWhiteSpace($modelSource) -or -not [string]::IsNullOrWhiteSpace($reasoningEffort) -or -not [string]::IsNullOrWhiteSpace($promptTransport) -or -not [string]::IsNullOrWhiteSpace($authMode))) {
        Stop-WinsmuxCommandError -CommandName 'provider-switch' -Reason 'clear_conflicts_with_selector' -Message 'provider-switch --clear cannot be combined with --agent, --model, --model-source, --reasoning-effort, --prompt-transport, or --auth-mode.' -Usage $usage
    }

    $projectDir = (Get-Location).Path
    $settings = Get-BridgeSettings -RootPath $projectDir
    $knownSlot = $false
    foreach ($slot in @($settings.agent_slots)) {
        if ([string]::Equals([string]$slot.slot_id, $slotId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $knownSlot = $true
            break
        }
    }
    if (-not $knownSlot) {
        Stop-WinsmuxCommandError -CommandName 'provider-switch' -Reason 'unknown_slot' -Message "provider-switch target slot '$slotId' is not present in agent_slots."
    }

    $restartPaneId = ''
    if ($restartRequested) {
        $manifestEntry = @(Get-PaneControlManifestEntries -ProjectDir $projectDir | Where-Object {
            [string]::Equals([string]$_.Label, $slotId, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)

        if ($manifestEntry.Count -lt 1) {
            Stop-WinsmuxCommandError -CommandName 'provider-switch' -Reason 'restart_slot_missing' -Message "provider-switch --restart target slot '$slotId' is not present in the orchestra manifest."
        }

        $restartPaneId = Confirm-Target ([string]$manifestEntry[0].PaneId)
    }

    $entry = $null
    $cleared = $false
    if ($clearRequested) {
        $clearResult = Remove-BridgeProviderRegistryEntry -RootPath $projectDir -SlotId $slotId
        $cleared = [bool]$clearResult.Removed
    } else {
        $candidateInput = [ordered]@{}
        if (-not [string]::IsNullOrWhiteSpace($agent)) { $candidateInput.agent = $agent }
        if (-not [string]::IsNullOrWhiteSpace($model)) { $candidateInput.model = $model }
        if (-not [string]::IsNullOrWhiteSpace($modelSource)) { $candidateInput.model_source = $modelSource }
        if (-not [string]::IsNullOrWhiteSpace($reasoningEffort)) { $candidateInput.reasoning_effort = $reasoningEffort }
        if (-not [string]::IsNullOrWhiteSpace($promptTransport)) { $candidateInput.prompt_transport = $promptTransport }
        if (-not [string]::IsNullOrWhiteSpace($authMode)) { $candidateInput.auth_mode = $authMode }
        $candidateEntry = ConvertTo-BridgeProviderRegistryEntry $candidateInput
        $null = Get-SlotAgentConfig -Role 'Worker' -SlotId $slotId -Settings $settings -RootPath $projectDir -ProviderRegistryEntryOverride $candidateEntry
        $entry = Write-BridgeProviderRegistryEntry -RootPath $projectDir -SlotId $slotId -Agent $agent -Model $model -ModelSource $modelSource -ReasoningEffort $reasoningEffort -PromptTransport $promptTransport -AuthMode $authMode -Reason $reason
    }

    $effective = Get-SlotAgentConfig -Role 'Worker' -SlotId $slotId -Settings $settings -RootPath $projectDir
    $payload = [ordered]@{
        slot_id                    = $slotId
        agent                      = [string]$effective.Agent
        model                      = [string]$effective.Model
        model_source               = [string]$effective.ModelSource
        reasoning_effort           = [string]$effective.ReasoningEffort
        prompt_transport           = [string]$effective.PromptTransport
        auth_mode                  = [string]$effective.AuthMode
        auth_policy                = [string]$effective.AuthPolicy
        local_access_note          = [string]$effective.LocalAccessNote
        harness_availability       = [string]$effective.HarnessAvailability
        credential_requirements    = [string]$effective.CredentialRequirements
        execution_backend          = [string]$effective.ExecutionBackend
        api_base_url               = [string]$effective.ApiBaseUrl
        api_key_env                = [string]$effective.ApiKeyEnv
        runtime_requirements       = [string]$effective.RuntimeRequirements
        analysis_posture           = [string]$effective.AnalysisPosture
        source                     = [string]$effective.Source
        capability_adapter         = [string]$effective.CapabilityAdapter
        capability_command         = [string]$effective.CapabilityCommand
        supports_parallel_runs     = [bool]$effective.SupportsParallelRuns
        supports_interrupt         = [bool]$effective.SupportsInterrupt
        supports_structured_result = [bool]$effective.SupportsStructuredResult
        supports_file_edit         = [bool]$effective.SupportsFileEdit
        supports_subagents         = [bool]$effective.SupportsSubagents
        supports_verification      = [bool]$effective.SupportsVerification
        supports_consultation      = [bool]$effective.SupportsConsultation
        supports_context_reset     = [bool]$effective.SupportsContextReset
        registry_path              = Get-BridgeProviderRegistryPath -RootPath $projectDir
        updated_at_utc             = if ($clearRequested) { [string]$clearResult.UpdatedAtUtc } else { [string]$entry.updated_at_utc }
        reason                     = if ((-not $clearRequested) -and $entry.Contains('reason')) { [string]$entry.reason } else { '' }
        clear_requested            = $clearRequested
        cleared                    = $cleared
        restart_requested          = $restartRequested
        restarted                  = $false
        restart_pane_id            = ''
    }

    if ($restartRequested) {
        $restartResult = Invoke-RestartPane -PaneId $restartPaneId -ProjectDir $projectDir
        $payload['restarted'] = $true
        $payload['restart_pane_id'] = [string]$restartResult.PaneId
    }

    $status = if ($clearRequested) { 'cleared' } else { 'updated' }
    $result = New-WinsmuxCommandResult -CommandName 'provider-switch' -Status $status -Data $payload
    Write-WinsmuxCommandResult -Result $result -Json:([bool]$jsonOutput) -JsonDepth 8 -TextWriter {
        param($data)
        if ([bool]$data.clear_requested) {
            Write-Output "provider switch cleared for $($data.slot_id): $($data.agent) / $($data.model) ($($data.prompt_transport), $($data.auth_policy))"
            return
        }

        Write-Output "provider switched for $($data.slot_id): $($data.agent) / $($data.model) ($($data.prompt_transport), $($data.auth_policy))"
    }
}
