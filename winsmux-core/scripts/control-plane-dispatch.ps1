function Get-WinsmuxControlPlaneArguments {
    param(
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    return ,@(@($CommandTarget) + @($CommandRest) | Where-Object { $_ })
}

function Join-WinsmuxControlPlaneText {
    param([AllowNull()][object[]]$Arguments)

    return (@(
        @($Arguments) |
            Where-Object { $_ } |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ }
    ) -join ' ')
}

function Get-WinsmuxControlPlaneScriptPath {
    param(
        [Parameter(Mandatory = $true)][string]$BridgeScriptRoot,
        [Parameter(Mandatory = $true)][string]$ScriptName
    )

    return [System.IO.Path]::GetFullPath((Join-Path $BridgeScriptRoot ("..\winsmux-core\scripts\{0}" -f $ScriptName)))
}

function Invoke-WinsmuxControlPlaneScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [AllowNull()][string[]]$Arguments,
        [switch]$PropagateExitCode
    )

    & pwsh -NoProfile -File $ScriptPath @Arguments
    if ($PropagateExitCode) {
        $exitCode = Get-SafeLastExitCode
        if ($null -ne $exitCode -and $exitCode -ne 0) {
            exit $exitCode
        }
    }
}

function Invoke-WinsmuxGithubPreflightCommand {
    param(
        [Parameter(Mandatory = $true)][string]$BridgeScriptRoot,
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $preflightArgs = @()
    $remaining = Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
    for ($index = 0; $index -lt $remaining.Count; $index++) {
        switch ($remaining[$index]) {
            '--repo' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux github-preflight [--repo <owner/name>] [--json] [--connector-available] [--require-gh]"
                }
                $preflightArgs += @('-Repository', $remaining[$index + 1])
                $index++
            }
            '--json' { $preflightArgs += '-Json' }
            '--connector-available' { $preflightArgs += '-ConnectorAvailable' }
            '--require-gh' { $preflightArgs += '-RequireGh' }
            default {
                Stop-WithError "usage: winsmux github-preflight [--repo <owner/name>] [--json] [--connector-available] [--require-gh]"
            }
        }
    }

    Invoke-WinsmuxControlPlaneScript `
        -ScriptPath (Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'github-write-preflight.ps1') `
        -Arguments $preflightArgs `
        -PropagateExitCode
}

function Invoke-WinsmuxDispatchRouteCommand {
    param(
        [Parameter(Mandatory = $true)][string]$BridgeScriptRoot,
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $routerScript = Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'dispatch-router.ps1'
    $fullText = Join-WinsmuxControlPlaneText -Arguments (Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest)
    & $routerScript -Text $fullText
}

function Invoke-WinsmuxSubmissionAckCommand {
    param(
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $usage = 'usage: winsmux submission-ack --submission-id <id> --run-id <id> --kind <task|review> --backend <local|codex> --slot <slot> --ack-pipe <pipe> --challenge <hex>'
    $tokens = @(@($CommandTarget) + @($CommandRest) | Where-Object { $_ })
    $values = [ordered]@{ submission_id = ''; run_id = ''; kind = ''; backend = ''; slot = ''; ack_pipe = ''; challenge = '' }
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $name = switch ([string]$tokens[$index]) {
            '--submission-id' { 'submission_id' }
            '--run-id' { 'run_id' }
            '--kind' { 'kind' }
            '--backend' { 'backend' }
            '--slot' { 'slot' }
            '--ack-pipe' { 'ack_pipe' }
            '--challenge' { 'challenge' }
            default { '' }
        }
        if ([string]::IsNullOrWhiteSpace($name) -or $index + 1 -ge $tokens.Count) {
            Stop-WithError $usage
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$values[$name])) { Stop-WithError $usage }
        $index++
        $values[$name] = [string]$tokens[$index]
    }
    foreach ($required in $values.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$values[$required])) { Stop-WithError $usage }
    }
    if (-not (Test-WinsmuxSubmissionAckPipeName -Value $values.ack_pipe) -or
        -not (Test-WinsmuxSubmissionAckChallenge -Value $values.challenge)) {
        Stop-WithError $usage
    }
    $projectDir = [string]$env:WINSMUX_ORCHESTRA_PROJECT_DIR
    if ([string]::IsNullOrWhiteSpace($projectDir)) { $projectDir = (Get-Location).Path }
    $receipt = Invoke-WinsmuxSubmissionAcknowledge -ProjectDir $projectDir -SlotId $values.slot `
        -SubmissionId $values.submission_id -RunId $values.run_id -Kind $values.kind -Backend $values.backend `
        -AckPipe $values.ack_pipe -Challenge $values.challenge
    ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt | Write-Output
    if ([string]$receipt.status -ne 'accepted') { exit 1 }
}

function Get-DispatchTaskManifestEntry {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (Get-Command Get-PaneControlManifestEntries -ErrorAction SilentlyContinue) {
        try {
            $entry = @(Get-PaneControlManifestEntries -ProjectDir $ProjectDir | Where-Object { [string]$_.Label -eq $Label } | Select-Object -First 1)[0]
            if ($null -ne $entry) {
                return $entry
            }
        } catch {
            return $null
        }
    }

    $labels = Get-Labels
    if ($labels.ContainsKey($Label)) {
        return [PSCustomObject]@{
            Label  = $Label
            PaneId = [string]$labels[$Label]
            Role   = ''
        }
    }

    return $null
}

function Test-DispatchTaskReviewerManifestEntry {
    param([AllowNull()]$Entry = $null)

    if ($null -eq $Entry) {
        return $false
    }

    $role = [string](Get-SendConfigValue -InputObject $Entry -Name 'Role' -Default '')
    $workerRole = [string](Get-SendConfigValue -InputObject $Entry -Name 'WorkerRole' -Default '')
    $agentRole = [string](Get-SendConfigValue -InputObject $Entry -Name 'AgentRole' -Default '')

    return (
        [string]::Equals($role, 'Reviewer', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($workerRole, 'reviewer', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($agentRole, 'reviewer', [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Get-DispatchTaskAvailableTargets {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $availableTargets = @()
    $manifestTargetsResolved = $false
    if (Get-Command Get-PaneControlManifestEntries -ErrorAction SilentlyContinue) {
        try {
            $manifestEntries = @(Get-PaneControlManifestEntries -ProjectDir $ProjectDir)
            $manifestTargetsResolved = $true
            $availableTargets = @(
                $manifestEntries |
                    Where-Object { -not (Test-DispatchTaskReviewerManifestEntry -Entry $_) } |
                    ForEach-Object { [string]$_.Label } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
        } catch {
            # A missing or malformed manifest is an explicit unavailable state.
            # Do not fall back to process-global labels from another workspace.
            $manifestTargetsResolved = $true
        }
    }
    if (-not $manifestTargetsResolved -and $availableTargets.Count -eq 0) {
        $availableTargets = @((Get-Labels).Keys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return @($availableTargets)
}

function Invoke-WinsmuxDispatchTaskCommand {
    param(
        [Parameter(Mandatory = $true)][string]$BridgeScriptRoot,
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $parts = @(
        Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ }
    )
    if ($parts.Count -lt 1) {
        Stop-WithError "usage: winsmux dispatch-task <text>"
    }

    $taskText = $parts -join ' '
    $submissionId = 'submission-' + [guid]::NewGuid().ToString('N')
    $projectDir = (Get-Location).Path
    $routerScript = Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'dispatch-router.ps1'
    if (-not (Test-Path -LiteralPath $routerScript -PathType Leaf)) {
        Stop-WithError "dispatch router not found: $routerScript"
    }

    . $routerScript

    $availableTargets = @(Get-DispatchTaskAvailableTargets -ProjectDir $projectDir)

    $route = Get-DispatchRoute -Text $taskText -AvailableTargets $availableTargets -DefaultRole 'Worker'
    if ($route.HandleLocally) {
        $receipt = New-WinsmuxRouterRefusalReceipt -Kind task -Route $route -SubmissionId $submissionId
        ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt | Write-Output
        exit 1
    }

    $selectedLabel = [string]$route.SelectedTarget
    $paneId = ''
    $resolvedRole = [string]$route.SelectedRole

    $manifestEntry = $null
    if ($resolvedRole -eq 'Reviewer') {
        $manifestEntry = Get-PreferredReviewPaneEntry -ProjectDir $projectDir
        if ($null -eq $manifestEntry) {
            $receipt = New-WinsmuxSubmissionReceipt -Kind task -Status unavailable -Backend noop -SubmissionId $submissionId -ReasonCode 'review_target_unavailable' -Diagnostic 'No review-capable pane was found in the manifest.'
            ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt | Write-Output
            exit 1
        }

        $selectedLabel = [string]$manifestEntry.Label
        $paneId = [string]$manifestEntry.PaneId
    } else {
        $manifestEntry = Get-DispatchTaskManifestEntry -ProjectDir $projectDir -Label $selectedLabel
        if ($null -eq $manifestEntry -or [string]::IsNullOrWhiteSpace([string]$manifestEntry.PaneId)) {
            $receipt = New-WinsmuxSubmissionReceipt -Kind task -Status unavailable -Backend noop -SubmissionId $submissionId -ReasonCode 'target_unavailable' -Diagnostic "dispatch-task could not resolve target '$selectedLabel' to a pane."
            ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt | Write-Output
            exit 1
        }

        $paneId = [string]$manifestEntry.PaneId
    }

    $entryStatus = [string](Get-WinsmuxSubmissionValue -InputObject $manifestEntry -Name 'Status' -Default '')
    $runtimeOperation = [string](Get-WinsmuxRuntimeStatusClassification -Status $entryStatus).RuntimeOperation
    $runtimeResult = Test-PaneControlRuntimeContext -ProjectDir $projectDir -ManifestEntry $manifestEntry -Operation $runtimeOperation
    if (-not $runtimeResult.valid) {
        $backend = [string](Get-WinsmuxSubmissionValue -InputObject $manifestEntry -Name 'WorkerBackend' -Default 'local')
        if ($backend -notin @('local', 'codex', 'api_llm', 'antigravity', 'noop')) { $backend = 'noop' }
        $receipt = New-WinsmuxSubmissionReceipt -Kind task -Status unavailable -Backend $backend -SubmissionId $submissionId `
            -ReasonCode ([string]$runtimeResult.reason_code) -Diagnostic ([string]$runtimeResult.diagnostic) `
            -Target ([ordered]@{ label = $selectedLabel; pane_id = $paneId; role = $resolvedRole })
        ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt | Write-Output
        exit 1
    }

    try {
        Start-DeferredPaneFromManifestEntry -ProjectDir $projectDir -ManifestEntry $manifestEntry `
            -ExpectedGenerationId ([string](Get-WinsmuxSubmissionValue -InputObject $runtimeResult.context -Name 'generation_id' -Default '')) | Out-Null
    } catch {
        $backend = [string](Get-WinsmuxSubmissionValue -InputObject $manifestEntry -Name 'WorkerBackend' -Default 'local')
        if ($backend -notin @('local', 'codex', 'api_llm', 'antigravity', 'noop')) { $backend = 'noop' }
        $receipt = New-WinsmuxDeferredStartFailureReceipt -Kind task -Backend $backend -SubmissionId $submissionId `
            -PaneId $paneId -Failure $_ -Target ([ordered]@{ label = $selectedLabel; pane_id = $paneId; role = $resolvedRole })
        ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt | Write-Output
        exit 1
    }

    if ($runtimeOperation -ceq 'start_deferred') {
        $manifestEntry = Get-DispatchTaskManifestEntry -ProjectDir $projectDir -Label $selectedLabel
        $runtimeResult = Wait-PaneControlRuntimeContext -ProjectDir $projectDir -ManifestEntry $manifestEntry -Operation dispatch
        if (-not $runtimeResult.valid) {
            $backend = [string](Get-WinsmuxSubmissionValue -InputObject $manifestEntry -Name 'WorkerBackend' -Default 'local')
            if ($backend -notin @('local', 'codex', 'api_llm', 'antigravity', 'noop')) { $backend = 'noop' }
            $receipt = New-WinsmuxSubmissionReceipt -Kind task -Status unavailable -Backend $backend -SubmissionId $submissionId `
                -ReasonCode ([string]$runtimeResult.reason_code) -Diagnostic ([string]$runtimeResult.diagnostic) `
                -Target ([ordered]@{ label = $selectedLabel; pane_id = $paneId; role = $resolvedRole })
            ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt | Write-Output
            exit 1
        }
    }

    $receipt = Invoke-WinsmuxSubmissionAdapter -ProjectDir $projectDir -ManifestEntry $manifestEntry -Kind task -Content $taskText -SubmissionId $submissionId
    $receipt.routing = [ordered]@{
        matched_rule   = [string]$route.RuleId
        expected_owner = $resolvedRole
        next_shape     = ''
    }
    ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt | Write-Output
    if ($receipt.status -ne 'accepted') {
        exit 1
    }
}

function Invoke-WinsmuxTaskSplitCommand {
    param(
        [Parameter(Mandatory = $true)][string]$BridgeScriptRoot,
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $taskText = Join-WinsmuxControlPlaneText -Arguments (Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest)
    if (-not $taskText) {
        Stop-WithError "usage: winsmux task-split <task text>"
    }

    Invoke-WinsmuxControlPlaneScript `
        -ScriptPath (Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'task-splitter.ps1') `
        -Arguments @('-Task', $taskText, '-AsJson')
}

function Invoke-WinsmuxTeamPipelineCommand {
    param(
        [Parameter(Mandatory = $true)][string]$BridgeScriptRoot,
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    if ($CommandTarget -ceq '--workflow-action') {
        try {
            $declarative = ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
        } catch {
            [PSCustomObject][ordered]@{
                schema_version = 1
                status = 'rejected'
                reason = [string]$_.Exception.Message
            } | ConvertTo-Json -Compress | Write-Output
            exit 1
        }
    } else {
        $declarative = ConvertTo-WinsmuxDeclarativePipelineArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
    }
    if ($null -ne $declarative) {
        $pipelineArgs = @(
            '-WorkflowAction', [string]$declarative.workflow_action,
            '-RunId', [string]$declarative.run_id,
            '-GenerationId', [string]$declarative.generation_id,
            '-ConfigFingerprint', [string]$declarative.config_fingerprint,
            '-SourceHead', [string]$declarative.source_head,
            '-TaskFile', [string]$declarative.task_file,
            '-ProjectDir', [string]$declarative.project_dir,
            '-AsJson'
        )
        if ($declarative.workflow_action -ceq 'start') {
            $pipelineArgs += @('-RecipeId', [string]$declarative.recipe_id, '-WorkflowId', [string]$declarative.workflow_id)
        }
        Invoke-WinsmuxControlPlaneScript `
            -ScriptPath (Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'team-pipeline.ps1') `
            -Arguments $pipelineArgs `
            -PropagateExitCode
        return
    }

    $taskText = Join-WinsmuxControlPlaneText -Arguments (Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest)
    $pipelineArgs = @()
    if ($taskText) {
        $pipelineArgs = @('-Task', $taskText)
    }

    Invoke-WinsmuxControlPlaneScript `
        -ScriptPath (Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'team-pipeline.ps1') `
        -Arguments $pipelineArgs
}

function ConvertTo-WinsmuxDeclarativePipelineArguments {
    param(
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )
    if ($CommandTarget -cne '--workflow-action') { return $null }
    $arguments = @(@($CommandTarget) + @($CommandRest) | Where-Object { $null -ne $_ })
    $values = [ordered]@{}
    $allowed = @(
        '--workflow-action', '--recipe-id', '--workflow-id', '--run-id',
        '--generation-id', '--config-fingerprint', '--source-head', '--task-file',
        '--project-dir', '--json'
    )
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $name = [string]$arguments[$index]
        if ($name -notin $allowed -or $name -cnotmatch '^--') {
            throw "Unknown or positional declarative pipeline argument '$name'."
        }
        if ($values.Contains($name)) { throw "Duplicate declarative pipeline argument '$name'." }
        if ($name -ceq '--json') {
            $values[$name] = $true
            continue
        }
        if ($index + 1 -ge $arguments.Count -or [string]$arguments[$index + 1] -cmatch '^--') {
            throw "Declarative pipeline argument '$name' requires one value."
        }
        $values[$name] = [string]$arguments[$index + 1]
        $index++
    }
    foreach ($required in @('--workflow-action', '--run-id', '--generation-id', '--config-fingerprint', '--source-head', '--task-file', '--json')) {
        if (-not $values.Contains($required)) { throw "Missing declarative pipeline argument '$required'." }
    }
    $action = [string]$values['--workflow-action']
    if ($action -notin @('start', 'resume')) { throw 'Declarative workflow action must be start or resume.' }
    if ($action -ceq 'start') {
        foreach ($required in @('--recipe-id', '--workflow-id')) {
            if (-not $values.Contains($required)) { throw "Missing declarative pipeline argument '$required'." }
        }
    } elseif ($values.Contains('--recipe-id') -or $values.Contains('--workflow-id')) {
        throw 'Declarative resume uses the persisted recipe and workflow identity.'
    }
    $projectDir = if ($values.Contains('--project-dir')) { [string]$values['--project-dir'] } else { (Get-Location).Path }
    return [PSCustomObject]@{
        workflow_action   = $action
        recipe_id        = if ($values.Contains('--recipe-id')) { [string]$values['--recipe-id'] } else { '' }
        workflow_id      = if ($values.Contains('--workflow-id')) { [string]$values['--workflow-id'] } else { '' }
        run_id           = [string]$values['--run-id']
        generation_id    = [string]$values['--generation-id']
        config_fingerprint = [string]$values['--config-fingerprint']
        source_head      = [string]$values['--source-head']
        task_file        = [string]$values['--task-file']
        project_dir      = $projectDir
    }
}

function Invoke-WinsmuxBuilderQueueCommand {
    param(
        [Parameter(Mandatory = $true)][string]$BridgeScriptRoot,
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $queueScript = Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'builder-queue.ps1'
    $projectDir = (Get-Location).Path
    switch ($CommandTarget) {
        'add' {
            if (-not $CommandRest -or $CommandRest.Count -lt 2) {
                Stop-WithError "usage: winsmux builder-queue add <builder-label> <task>"
            }

            $builderLabel = $CommandRest[0]
            $taskText = Join-WinsmuxControlPlaneText -Arguments @($CommandRest | Select-Object -Skip 1)
            Invoke-WinsmuxControlPlaneScript -ScriptPath $queueScript -Arguments @('-Action', 'add', '-ProjectDir', $projectDir, '-BuilderLabel', $builderLabel, '-Task', $taskText)
        }
        'list' {
            $builderLabel = if ($CommandRest -and $CommandRest.Count -gt 0) { $CommandRest[0] } else { '' }
            Invoke-WinsmuxControlPlaneScript -ScriptPath $queueScript -Arguments @('-Action', 'list', '-ProjectDir', $projectDir, '-BuilderLabel', $builderLabel)
        }
        'dispatch-next' {
            if (-not $CommandRest -or $CommandRest.Count -lt 1) {
                Stop-WithError "usage: winsmux builder-queue dispatch-next <builder-label>"
            }

            Invoke-WinsmuxControlPlaneScript -ScriptPath $queueScript -Arguments @('-Action', 'dispatch-next', '-ProjectDir', $projectDir, '-BuilderLabel', $CommandRest[0]) -PropagateExitCode
        }
        'complete' {
            if (-not $CommandRest -or $CommandRest.Count -lt 1) {
                Stop-WithError "usage: winsmux builder-queue complete <builder-label> [task]"
            }

            $builderLabel = $CommandRest[0]
            $taskText = Join-WinsmuxControlPlaneText -Arguments @($CommandRest | Select-Object -Skip 1)
            $queueArgs = @('-Action', 'complete', '-ProjectDir', $projectDir, '-BuilderLabel', $builderLabel)
            if ($taskText) {
                $queueArgs += @('-Task', $taskText)
            }
            Invoke-WinsmuxControlPlaneScript -ScriptPath $queueScript -Arguments $queueArgs
        }
        default {
            Stop-WithError "usage: winsmux builder-queue [add|list|dispatch-next|complete] ..."
        }
    }
}

function Invoke-WinsmuxOrchestraSmokeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$BridgeScriptRoot,
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $smokeArgs = @()
    $remaining = Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
    for ($index = 0; $index -lt $remaining.Count; $index++) {
        switch ($remaining[$index]) {
            '--json' { $smokeArgs += '-AsJson' }
            '--project-dir' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux orchestra-smoke [--json] [--auto-start] [--project-dir <path>]"
                }
                $smokeArgs += @('-ProjectDir', $remaining[$index + 1])
                $index++
            }
            '--auto-start' { $smokeArgs += '-AutoStart' }
            default {
                Stop-WithError "usage: winsmux orchestra-smoke [--json] [--auto-start] [--project-dir <path>]"
            }
        }
    }

    Invoke-WinsmuxControlPlaneScript `
        -ScriptPath (Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'orchestra-smoke.ps1') `
        -Arguments $smokeArgs
}

function Invoke-WinsmuxOrchestraAttachCommand {
    param(
        [Parameter(Mandatory = $true)][string]$BridgeScriptRoot,
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $attachArgs = @()
    $remaining = Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
    for ($index = 0; $index -lt $remaining.Count; $index++) {
        switch ($remaining[$index]) {
            '--json' { $attachArgs += '-AsJson' }
            '--project-dir' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux orchestra-attach [--json] [--project-dir <path>]"
                }
                $attachArgs += @('-ProjectDir', $remaining[$index + 1])
                $index++
            }
            default {
                Stop-WithError "usage: winsmux orchestra-attach [--json] [--project-dir <path>]"
            }
        }
    }

    Invoke-WinsmuxControlPlaneScript `
        -ScriptPath (Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'orchestra-attach.ps1') `
        -Arguments $attachArgs
}

function Invoke-WinsmuxHarnessCheckCommand {
    param(
        [Parameter(Mandatory = $true)][string]$BridgeScriptRoot,
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $checkArgs = @()
    $remaining = Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
    for ($index = 0; $index -lt $remaining.Count; $index++) {
        switch ($remaining[$index]) {
            '--json' { $checkArgs += '-AsJson' }
            '--project-dir' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux harness-check [--json] [--project-dir <path>]"
                }
                $checkArgs += @('-ProjectDir', $remaining[$index + 1])
                $index++
            }
            default {
                Stop-WithError "usage: winsmux harness-check [--json] [--project-dir <path>]"
            }
        }
    }

    Invoke-WinsmuxControlPlaneScript `
        -ScriptPath (Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'harness-check.ps1') `
        -Arguments $checkArgs `
        -PropagateExitCode
}

function Invoke-WinsmuxShadowCutoverGateCommand {
    param(
        [Parameter(Mandatory = $true)][string]$BridgeScriptRoot,
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $remaining = Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
    $expectedPath = ''
    $actualPath = ''
    $surface = 'unspecified'
    $asJson = $false
    for ($index = 0; $index -lt $remaining.Count; $index++) {
        switch ($remaining[$index]) {
            '--expected' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux shadow-cutover-gate --expected <path> --actual <path> [--surface <name>] [--json]"
                }
                $expectedPath = $remaining[$index + 1]
                $index++
            }
            '--actual' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux shadow-cutover-gate --expected <path> --actual <path> [--surface <name>] [--json]"
                }
                $actualPath = $remaining[$index + 1]
                $index++
            }
            '--surface' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux shadow-cutover-gate --expected <path> --actual <path> [--surface <name>] [--json]"
                }
                $surface = $remaining[$index + 1]
                $index++
            }
            '--json' { $asJson = $true }
            default {
                Stop-WithError "usage: winsmux shadow-cutover-gate --expected <path> --actual <path> [--surface <name>] [--json]"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($expectedPath) -or [string]::IsNullOrWhiteSpace($actualPath)) {
        Stop-WithError "usage: winsmux shadow-cutover-gate --expected <path> --actual <path> [--surface <name>] [--json]"
    }

    $gateArgs = @('-ExpectedPath', $expectedPath, '-ActualPath', $actualPath, '-Surface', $surface)
    if ($asJson) {
        $gateArgs += '-AsJson'
    }

    Invoke-WinsmuxControlPlaneScript `
        -ScriptPath (Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'shadow-cutover-gate.ps1') `
        -Arguments $gateArgs
}

function Invoke-WinsmuxPowerShellDeescalationCommand {
    param(
        [Parameter(Mandatory = $true)][string]$BridgeScriptRoot,
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $contractArgs = @()
    $remaining = Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
    foreach ($argument in $remaining) {
        switch ($argument) {
            '--json' { $contractArgs += '-AsJson' }
            default {
                Stop-WithError "usage: winsmux powershell-deescalation [--json]"
            }
        }
    }

    Invoke-WinsmuxControlPlaneScript `
        -ScriptPath (Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'powershell-deescalation.ps1') `
        -Arguments $contractArgs
}

function Invoke-WinsmuxAssignCommand {
    param(
        [Parameter(Mandatory = $true)][string]$BridgeScriptRoot,
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $assignArgs = @()
    $remaining = Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
    for ($index = 0; $index -lt $remaining.Count; $index++) {
        switch ($remaining[$index]) {
            '--task' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux assign --task <TASK-ID> [--json] [--text <text>]"
                }
                $assignArgs += @('-TaskId', $remaining[$index + 1])
                $index++
            }
            '--text' {
                if ($index + 1 -ge $remaining.Count) {
                    Stop-WithError "usage: winsmux assign --task <TASK-ID> [--json] [--text <text>]"
                }
                $assignArgs += @('-Text', $remaining[$index + 1])
                $index++
            }
            '--json' { $assignArgs += '-Json' }
            default {
                Stop-WithError "usage: winsmux assign --task <TASK-ID> [--json] [--text <text>]"
            }
        }
    }

    Invoke-WinsmuxControlPlaneScript `
        -ScriptPath (Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'assignment-policy.ps1') `
        -Arguments $assignArgs `
        -PropagateExitCode
}
