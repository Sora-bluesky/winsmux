# Pane scaler helpers must land in this script's scope. Dot-sourcing
# orchestra-start.ps1 / pane-scaler.ps1 inside a function would leave
# Add-OrchestraPane / Remove-OrchestraPane defined only in that function.
if (-not (Get-Command Get-OrchestraModeDocument -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'manifest.ps1')
}
if (-not (Get-Command Add-OrchestraPane -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'pane-scaler.ps1')
}

function Get-WinsmuxControlPlaneArguments {
    param(
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($part in @(@($CommandTarget) + @($CommandRest))) {
        if ([string]::IsNullOrWhiteSpace([string]$part)) {
            continue
        }
        $items.Add([string]$part)
    }
    return $items
}

function ConvertTo-WinsmuxControlPlaneArgumentList {
    param([AllowNull()]$Value)

    $items = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Value) {
        return , $items
    }
    if ($Value -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            $items.Add($Value)
        }
        return , $items
    }
    foreach ($part in $Value) {
        if ([string]::IsNullOrWhiteSpace([string]$part)) {
            continue
        }
        $items.Add([string]$part)
    }
    return , $items
}

function Split-WinsmuxDispatchTaskArguments {
    param([AllowNull()]$Parts)

    $slotId = ''
    $taskClass = ''
    $delegation = ''
    $projectDir = ''
    $textParts = New-Object System.Collections.Generic.List[string]
    $index = 0
    $items = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Parts) {
        if ($Parts -is [string]) {
            $items.Add([string]$Parts)
        } else {
            foreach ($part in $Parts) {
                $items.Add([string]$part)
            }
        }
    }
    while ($index -lt $items.Count) {
        $current = [string]$items[$index]
        if ($current -ceq '--') {
            $index++
            while ($index -lt $items.Count) {
                $textParts.Add([string]$items[$index])
                $index++
            }
            break
        }
        if ($current -in @('--slot-id', '--task-class', '--delegation', '--project-dir')) {
            if ($index + 1 -ge $items.Count) {
                Stop-WithError 'usage: winsmux dispatch-task [--slot-id <id>] [--task-class <id>] [--delegation <id>] [--project-dir <path>] [--] <text>'
            }
            $value = [string]$items[$index + 1]
            switch ($current) {
                '--slot-id' { $slotId = $value }
                '--task-class' { $taskClass = $value }
                '--delegation' { $delegation = $value }
                '--project-dir' { $projectDir = $value }
            }
            $index += 2
            continue
        }
        if ($current -ceq '--json') {
            $index++
            continue
        }
        $textParts.Add($current)
        $index++
    }

    return [pscustomobject]@{
        SlotId     = $slotId
        TaskClass  = $taskClass
        Delegation = $delegation
        ProjectDir = $projectDir
        TaskText   = ((@($textParts) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join ' ')
    }
}

function Join-WinsmuxControlPlaneText {
    param([AllowNull()]$Arguments)

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Arguments) {
        return ''
    }
    if ($Arguments -is [string]) {
        $text = $Arguments.Trim()
        if ($text) {
            $parts.Add($text)
        }
        return ($parts -join ' ')
    }
    foreach ($arg in $Arguments) {
        $text = ([string]$arg).Trim()
        if ($text) {
            $parts.Add($text)
        }
    }
    return ($parts -join ' ')
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
    $remaining = ConvertTo-WinsmuxControlPlaneArgumentList -Value (
            Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
        )
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
            $entry = @(Get-PaneControlManifestEntries -ProjectDir $ProjectDir | Where-Object { [string]$_.Label -eq $Label -or [string]$_.SlotId -eq $Label } | Select-Object -First 1)[0]
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

function Get-DispatchTaskObjectText {
    param(
        [AllowNull()]$InputObject = $null,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [AllowEmptyString()][string]$Default = ''
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        $value = $null
        if ($InputObject -is [System.Collections.IDictionary]) {
            if ($InputObject.Contains($name)) {
                $value = $InputObject[$name]
            }
        } elseif ($null -ne $InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains $name) {
            $value = $InputObject.PSObject.Properties[$name].Value
        }
        if ($null -eq $value) {
            continue
        }
        $text = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            return $text
        }
    }

    return $Default
}

function Test-DispatchTaskReviewerManifestEntry {
    param([AllowNull()]$Entry = $null)

    if ($null -eq $Entry) {
        return $false
    }

    $role = Get-DispatchTaskObjectText -InputObject $Entry -Names @('Role', 'role')
    $workerRole = Get-DispatchTaskObjectText -InputObject $Entry -Names @('WorkerRole', 'worker_role')
    $agentRole = Get-DispatchTaskObjectText -InputObject $Entry -Names @('AgentRole', 'agent_role')

    return (
        [string]::Equals($role, 'Reviewer', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($workerRole, 'reviewer', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($agentRole, 'reviewer', [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Get-DispatchTaskLiveSpawnBudget {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $mode = 'team'
    if (Get-Command Get-OrchestraModeDocument -ErrorAction SilentlyContinue) {
        try {
            $mode = [string](Get-OrchestraModeDocument -ProjectDir $ProjectDir).mode
        } catch {
            return [pscustomobject]@{
                Mode        = ''
                LiveWorkers = 0
                MaxLive     = 0
                Allowed     = $false
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($mode)) {
        $mode = 'team'
    }

    $maxLive = 6
    if (Get-Command Get-OrchestraMaxLiveWorkerPaneCount -ErrorAction SilentlyContinue) {
        $maxLive = [int](Get-OrchestraMaxLiveWorkerPaneCount -Mode $mode)
    } elseif ($mode -ceq 'simple') {
        $maxLive = 1
    }

    $liveWorkers = 0
    $hasManifestReader = [bool](Get-Command Get-WinsmuxManifest -ErrorAction SilentlyContinue)
    $hasLiveWorkerCounter = [bool](Get-Command Get-OrchestraLiveWorkerRolePaneCount -ErrorAction SilentlyContinue)
    if ($hasManifestReader -and $hasLiveWorkerCounter) {
        try {
            $manifest = Get-WinsmuxManifest -ProjectDir $ProjectDir
            $liveWorkers = [int](Get-OrchestraLiveWorkerRolePaneCount -Manifest $manifest)
        } catch {
            $liveWorkers = 0
        }
    }

    return [pscustomobject]@{
        Mode        = $mode
        LiveWorkers = $liveWorkers
        MaxLive     = $maxLive
        Allowed     = ($liveWorkers -lt $maxLive)
    }
}

function Get-DispatchTaskWinsmuxBin {
    if (Get-Command Get-WinsmuxBin -ErrorAction SilentlyContinue) {
        try {
            return [string](Get-WinsmuxBin)
        } catch {
            return ''
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_BIN) -and (Test-Path -LiteralPath $env:WINSMUX_BIN -PathType Leaf)) {
        return [System.IO.Path]::GetFullPath($env:WINSMUX_BIN)
    }
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    foreach ($candidatePath in @(
            (Join-Path $repoRoot 'target\release\winsmux.exe'),
            (Join-Path $repoRoot 'target\debug\winsmux.exe')
        )) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidatePath)
        }
    }
    $command = Get-Command winsmux -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        return [string]$command.Source
    }
    return ''
}

function Get-DispatchTaskResolvedTeamPayload {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $bin = Get-DispatchTaskWinsmuxBin
    if ([string]::IsNullOrWhiteSpace($bin)) {
        return $null
    }
    $resolveArgs = @('team-profile', '--action', 'resolve', '--json', '--project-dir', $ProjectDir)
    $output = $null
    $code = 1
    if (Get-Command Invoke-WinsmuxBridgeCommand -ErrorAction SilentlyContinue) {
        $output = Invoke-WinsmuxBridgeCommand -WinsmuxBin $bin -Arguments $resolveArgs 2>&1
        $code = $LASTEXITCODE
    } else {
        $output = & $bin @resolveArgs 2>&1
        $code = $LASTEXITCODE
    }
    if ($code -ne 0) {
        return $null
    }
    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    try {
        return ($text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-DispatchTaskResolvedTeamSlots {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $payload = Get-DispatchTaskResolvedTeamPayload -ProjectDir $ProjectDir
    if ($null -eq $payload) {
        return @()
    }
    $okText = Get-DispatchTaskObjectText -InputObject $payload -Names @('ok')
    if ([string]::Equals($okText, 'false', [System.StringComparison]::OrdinalIgnoreCase)) {
        return @()
    }
    $team = $null
    if ($payload -is [System.Collections.IDictionary] -and $payload.Contains('team')) {
        $team = $payload['team']
    } elseif ($null -ne $payload.PSObject -and $payload.PSObject.Properties.Name -contains 'team') {
        $team = $payload.team
    }
    if ($null -eq $team) {
        return @()
    }
    $optedIn = Get-DispatchTaskObjectText -InputObject $team -Names @('opted_in', 'opted-in')
    if ([string]::Equals($optedIn, 'false', [System.StringComparison]::OrdinalIgnoreCase)) {
        return @()
    }
    $slots = @()
    if ($team -is [System.Collections.IDictionary] -and $team.Contains('slots')) {
        $slots = @($team['slots'])
    } elseif ($null -ne $team.PSObject -and $team.PSObject.Properties.Name -contains 'slots') {
        $slots = @($team.slots)
    }

    $ids = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($slot in @($slots)) {
        $slotId = Get-DispatchTaskObjectText -InputObject $slot -Names @('slot-id', 'slot_id', 'SlotId', 'label', 'Label')
        if ([string]::IsNullOrWhiteSpace($slotId)) {
            continue
        }
        $entry = [pscustomobject]@{
            Label      = $slotId
            Role       = (Get-DispatchTaskObjectText -InputObject $slot -Names @('role', 'Role'))
            WorkerRole = (Get-DispatchTaskObjectText -InputObject $slot -Names @('worker_role', 'WorkerRole', 'worker-role'))
            AgentRole  = (Get-DispatchTaskObjectText -InputObject $slot -Names @('agent_role', 'AgentRole', 'agent-role'))
        }
        if (Test-DispatchTaskReviewerManifestEntry -Entry $entry) {
            continue
        }
        $runtimeRole = Get-DispatchTaskObjectText -InputObject $slot -Names @('runtime_role', 'RuntimeRole', 'runtime-role')
        if (-not [string]::IsNullOrWhiteSpace($runtimeRole) -and
            -not [string]::Equals($runtimeRole, 'worker', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($seen.Add($slotId)) {
            $ids.Add($slotId) | Out-Null
        }
    }
    return @($ids)
}

function Get-DispatchTaskCatalogSlotIds {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    # Team Profile resolve owns worker-1..6. YAML agent_slots is an overlay, not the catalog.
    return @(Get-DispatchTaskResolvedTeamSlots -ProjectDir $ProjectDir)
}

function Get-DispatchTaskMissingCatalogSlotIds {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($slotId in @(Get-DispatchTaskCatalogSlotIds -ProjectDir $ProjectDir)) {
        $entry = Get-DispatchTaskManifestEntry -ProjectDir $ProjectDir -Label $slotId
        if ([string]::IsNullOrWhiteSpace((Get-DispatchTaskEntryPaneId -Entry $entry))) {
            $missing.Add($slotId) | Out-Null
        }
    }
    return @($missing)
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

    $budget = Get-DispatchTaskLiveSpawnBudget -ProjectDir $ProjectDir
    if (-not [bool]$budget.Allowed) {
        return @($availableTargets)
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($label in @($availableTargets)) {
        [void]$seen.Add([string]$label)
    }
    foreach ($slotId in @(Get-DispatchTaskMissingCatalogSlotIds -ProjectDir $ProjectDir)) {
        if ($seen.Add($slotId)) {
            $availableTargets += $slotId
        }
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
    $parsed = Split-WinsmuxDispatchTaskArguments -Parts $parts
    $taskText = [string]$parsed.TaskText
    if ([string]::IsNullOrWhiteSpace($taskText)) {
        Stop-WithError "usage: winsmux dispatch-task <text>"
    }

    $submissionId = 'submission-' + [guid]::NewGuid().ToString('N')
    $projectDir = (Get-Location).Path
    if (-not [string]::IsNullOrWhiteSpace([string]$parsed.ProjectDir)) {
        $projectDir = [string]$parsed.ProjectDir
    }
    $routerScript = Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'dispatch-router.ps1'
    if (-not (Test-Path -LiteralPath $routerScript -PathType Leaf)) {
        Stop-WithError "dispatch router not found: $routerScript"
    }

    . $routerScript

    $availableTargets = @(Get-DispatchTaskAvailableTargets -ProjectDir $projectDir)

    $selectedLabel = ''
    $paneId = ''
    $resolvedRole = 'Worker'
    $classifiedSlotId = [string]$parsed.SlotId
    $route = $null
    if (-not [string]::IsNullOrWhiteSpace($classifiedSlotId)) {
        $selectedLabel = $classifiedSlotId
        $resolvedRole = 'Worker'
        $route = Get-DispatchRoute -Text $taskText -AvailableTargets @($classifiedSlotId) -DefaultRole 'Worker'
    } else {
        $route = Get-DispatchRoute -Text $taskText -AvailableTargets $availableTargets -DefaultRole 'Worker'
        if ($route.HandleLocally) {
            $receipt = New-WinsmuxRouterRefusalReceipt -Kind task -Route $route -SubmissionId $submissionId
            ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt | Write-Output
            exit 1
        }

        $selectedLabel = [string]$route.SelectedTarget
        $resolvedRole = [string]$route.SelectedRole
        if ($resolvedRole -ne 'Reviewer' -and $resolvedRole -ne 'Operator') {
            $budget = Get-DispatchTaskLiveSpawnBudget -ProjectDir $projectDir
            $missingSlots = @(Get-DispatchTaskMissingCatalogSlotIds -ProjectDir $projectDir)
            if ([bool]$budget.Allowed -and $missingSlots.Count -gt 0) {
                $selectedIsMissing = $false
                foreach ($missingId in $missingSlots) {
                    if ([string]::Equals([string]$missingId, $selectedLabel, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $selectedIsMissing = $true
                        break
                    }
                }
                if (-not $selectedIsMissing) {
                    $preferredMissing = Get-DispatchRouterPreferredLabel -Role 'Worker' -AvailableTargets $missingSlots
                    if (-not [string]::IsNullOrWhiteSpace([string]$preferredMissing)) {
                        $selectedLabel = [string]$preferredMissing
                        $resolvedRole = 'Worker'
                    }
                }
            }
        }
    }
    if ($null -eq $route) {
        $route = Get-DispatchRoute -Text $taskText -AvailableTargets @($selectedLabel) -DefaultRole 'Worker'
    }

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
        $paneId = Get-DispatchTaskEntryPaneId -Entry $manifestEntry
        if ($null -eq $manifestEntry -or [string]::IsNullOrWhiteSpace($paneId)) {
            $spawn = Ensure-DispatchTaskLiveWorkerPane -ProjectDir $projectDir -Label $selectedLabel -ManifestEntry $manifestEntry
            if (-not [bool]$spawn.Spawned) {
                $reason = [string]$spawn.ReasonCode
                if ([string]::IsNullOrWhiteSpace($reason)) {
                    $reason = 'target_unavailable'
                }
                $diagnostic = [string]$spawn.Diagnostic
                if ([string]::IsNullOrWhiteSpace($diagnostic)) {
                    $diagnostic = "dispatch-task could not resolve target '$selectedLabel' to a pane."
                }
                $receipt = New-WinsmuxSubmissionReceipt -Kind task -Status unavailable -Backend noop -SubmissionId $submissionId -ReasonCode $reason -Diagnostic $diagnostic
                ConvertTo-WinsmuxSubmissionReceiptJson -Receipt $receipt | Write-Output
                exit 1
            }
            $manifestEntry = $spawn.ManifestEntry
            $paneId = Get-DispatchTaskEntryPaneId -Entry $manifestEntry
        }
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
        [AllowNull()][string[]]$CommandRest,
        [switch]$AllowDeclarativeWorkflow
    )

    $declarative = $null
    if ($AllowDeclarativeWorkflow) {
        $declarative = ConvertTo-WinsmuxDeclarativePipelineArguments `
            -CommandTarget $CommandTarget -CommandRest $CommandRest
    }
    if ($null -ne $declarative) {
        if (-not (Get-Command Resolve-WinsmuxRawCommand -CommandType Function -ErrorAction SilentlyContinue)) {
            throw 'workflow_plan_unavailable: parent executable resolver is not loaded.'
        }
        $workflowPlanCommand = [string](Resolve-WinsmuxRawCommand)
        if ([string]::IsNullOrWhiteSpace($workflowPlanCommand)) {
            throw 'workflow_plan_unavailable: parent executable resolver returned an empty command.'
        }
        $pipelineArgs = @(
            '-WorkflowAction', [string]$declarative.workflow_action,
            '-RunId', [string]$declarative.run_id,
            '-TaskFile', [string]$declarative.task_file,
            '-ProjectDir', [string]$declarative.project_dir,
            '-WorkflowPlanCommand', $workflowPlanCommand
        )
        if ($declarative.workflow_action -ceq 'start') {
            $pipelineArgs += @(
                '-RecipeId', [string]$declarative.recipe_id,
                '-WorkflowId', [string]$declarative.workflow_id
            )
        }
        if ($declarative.as_json) {
            $pipelineArgs += '-AsJson'
        }
        Invoke-WinsmuxControlPlaneScript `
            -ScriptPath (Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'team-pipeline.ps1') `
            -Arguments $pipelineArgs `
            -PropagateExitCode
        return
    }

    $taskText = Join-WinsmuxControlPlaneText -Arguments (
        Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
    )
    $legacyPipelineArgs = @()
    if ($taskText) {
        $legacyPipelineArgs = @('-Task', $taskText)
    }

    Invoke-WinsmuxControlPlaneScript `
        -ScriptPath (Get-WinsmuxControlPlaneScriptPath -BridgeScriptRoot $BridgeScriptRoot -ScriptName 'team-pipeline.ps1') `
        -Arguments $legacyPipelineArgs
}

function ConvertTo-WinsmuxDeclarativePipelineArguments {
    param(
        [AllowNull()][string]$CommandTarget,
        [AllowNull()][string[]]$CommandRest
    )

    if ($CommandTarget -cne '--workflow-action') {
        return $null
    }

    $usage = 'usage: winsmux pipeline --workflow-action start --recipe-id <id> --workflow-id <id> --run-id <id> --task-file <path> --project-dir <path> --json | winsmux pipeline --workflow-action resume --run-id <id> --task-file <path> --project-dir <path> --json'
    $tokens = @($CommandRest)
    if ($tokens.Count -lt 1) {
        Stop-WithError '--workflow-action requires start or resume.'
    }
    $action = [string]$tokens[0]
    if ($action -cnotin @('start', 'resume')) {
        Stop-WithError '--workflow-action requires start or resume.'
    }

    $values = [ordered]@{
        recipe_id = ''
        workflow_id = ''
        run_id = ''
        task_file = ''
        project_dir = ''
    }
    $seenJson = $false
    $index = 1
    while ($index -lt $tokens.Count) {
        $token = [string]$tokens[$index]
        if ($token -ceq '--json') {
            if ($seenJson) {
                Stop-WithError $usage
            }
            $seenJson = $true
            $index++
            continue
        }

        $name = switch -CaseSensitive ($token) {
            '--recipe-id' { 'recipe_id' }
            '--workflow-id' { 'workflow_id' }
            '--run-id' { 'run_id' }
            '--task-file' { 'task_file' }
            '--project-dir' { 'project_dir' }
            default { '' }
        }
        if ([string]::IsNullOrWhiteSpace($name) -or
            $index + 1 -ge $tokens.Count -or
            -not [string]::IsNullOrWhiteSpace([string]$values[$name])) {
            Stop-WithError $usage
        }
        $index++
        $value = [string]$tokens[$index]
        if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith('--')) {
            Stop-WithError $usage
        }
        $values[$name] = $value
        $index++
    }

    foreach ($required in @('run_id', 'task_file', 'project_dir')) {
        if ([string]::IsNullOrWhiteSpace([string]$values[$required])) {
            Stop-WithError $usage
        }
    }
    if (-not $seenJson) {
        Stop-WithError $usage
    }
    if ($action -ceq 'start') {
        if ([string]::IsNullOrWhiteSpace([string]$values.recipe_id) -or
            [string]::IsNullOrWhiteSpace([string]$values.workflow_id)) {
            Stop-WithError $usage
        }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$values.recipe_id) -or
        -not [string]::IsNullOrWhiteSpace([string]$values.workflow_id)) {
        Stop-WithError $usage
    }

    return [PSCustomObject][ordered]@{
        workflow_action = $action
        recipe_id = [string]$values.recipe_id
        workflow_id = [string]$values.workflow_id
        run_id = [string]$values.run_id
        task_file = [string]$values.task_file
        project_dir = [string]$values.project_dir
        as_json = $seenJson
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
    $remaining = ConvertTo-WinsmuxControlPlaneArgumentList -Value (
            Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
        )
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
    $remaining = ConvertTo-WinsmuxControlPlaneArgumentList -Value (
            Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
        )
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
    $remaining = ConvertTo-WinsmuxControlPlaneArgumentList -Value (
            Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
        )
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

    $remaining = ConvertTo-WinsmuxControlPlaneArgumentList -Value (
            Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
        )
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
    $remaining = ConvertTo-WinsmuxControlPlaneArgumentList -Value (
            Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
        )
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
    $remaining = ConvertTo-WinsmuxControlPlaneArgumentList -Value (
            Get-WinsmuxControlPlaneArguments -CommandTarget $CommandTarget -CommandRest $CommandRest
        )
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


function Import-Task789OrchestraHelpers {
    param([switch]$IncludePaneScaler)

    # Manifest + pane-scaler are loaded at script scope above. Promoting
    # Team Profile helpers here keeps New-TeamProfileSlotAgentConfig and
    # Invoke-TeamProfileLaunchProjection available after this function returns.
    if (-not $IncludePaneScaler) {
        return
    }
    if ((Get-Command New-TeamProfileSlotAgentConfig -ErrorAction SilentlyContinue) -and
        (Get-Command Add-TeamProfileBundleToLaunchCommand -ErrorAction SilentlyContinue)) {
        return
    }

    $orchestraStartPath = Join-Path $PSScriptRoot 'orchestra-start.ps1'
    if (-not (Test-Path -LiteralPath $orchestraStartPath -PathType Leaf)) {
        return
    }

    $before = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @((Get-ChildItem -Path Function:).Name)) {
        [void]$before.Add([string]$name)
    }

    # Bind RequestedRootPath so leftover CLI args cannot become the project dir.
    . $orchestraStartPath -RequestedRootPath ''

    foreach ($fn in @(Get-ChildItem -Path Function:)) {
        $name = [string]$fn.Name
        if ($before.Contains($name)) {
            continue
        }
        Set-Item -LiteralPath ("Function:script:{0}" -f $name) -Value $fn.ScriptBlock
    }
}

function Get-DispatchTaskEntryPaneId {
    param([AllowNull()]$Entry = $null)

    if ($null -eq $Entry) {
        return ''
    }
    foreach ($name in @('PaneId', 'pane_id')) {
        if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($name)) {
            return [string]$Entry[$name]
        }
        if ($null -ne $Entry.PSObject -and $Entry.PSObject.Properties.Name -contains $name) {
            return [string]$Entry.PSObject.Properties[$name].Value
        }
    }
    return ''
}

function Test-DispatchTaskLiveFileBytesEqual {
    param($Before, $After)
    if ($null -eq $Before -and $null -eq $After) {
        return $true
    }
    if ($null -eq $Before -or $null -eq $After) {
        return $false
    }
    if ($Before.Length -ne $After.Length) {
        return $false
    }
    for ($i = 0; $i -lt $Before.Length; $i++) {
        if ($Before[$i] -ne $After[$i]) {
            return $false
        }
    }
    return $true
}

function Get-DispatchTaskLiveRegistryPaneSetToken {
    param($Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return ''
    }

    try {
        $text = [System.Text.Encoding]::UTF8.GetString($Bytes)
        $registry = $text | ConvertFrom-Json
    } catch {
        return ''
    }

    $count = [string](Get-WinsmuxRuntimeValue -InputObject $registry -Name 'expected_pane_count' -Default '')
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($pane in @($registry.panes)) {
        $slotId = [string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'slot_id' -Default '')
        $paneId = [string](Get-WinsmuxRuntimeValue -InputObject $pane -Name 'pane_id' -Default '')
        $parts.Add(('{0}:{1}' -f $slotId, $paneId)) | Out-Null
    }
    return '{0}|{1}' -f $count, ($parts -join ',')
}

function Test-DispatchTaskLiveRegistryPaneSetEqual {
    param($Before, $After)

    $beforeToken = Get-DispatchTaskLiveRegistryPaneSetToken -Bytes $Before
    $afterToken = Get-DispatchTaskLiveRegistryPaneSetToken -Bytes $After
    if ([string]::IsNullOrWhiteSpace($beforeToken) -or [string]::IsNullOrWhiteSpace($afterToken)) {
        return (Test-DispatchTaskLiveFileBytesEqual -Before $Before -After $After)
    }
    return [string]::Equals($beforeToken, $afterToken, [System.StringComparison]::Ordinal)
}

function Restore-DispatchTaskLiveFileBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $Bytes
    )
    if ($null -eq $Bytes) {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force
        }
        return
    }
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

function Ensure-DispatchTaskLiveWorkerPane {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowNull()]$ManifestEntry = $null
    )

    $paneId = Get-DispatchTaskEntryPaneId -Entry $ManifestEntry
    if (-not [string]::IsNullOrWhiteSpace($paneId)) {
        return [pscustomobject]@{
            Spawned        = $false
            ManifestEntry  = $ManifestEntry
            ReasonCode     = ''
            Diagnostic     = ''
        }
    }

    Import-Task789OrchestraHelpers
    $mode = 'team'
    try {
        $mode = [string](Get-OrchestraModeDocument -ProjectDir $ProjectDir).mode
    } catch {
        return [pscustomobject]@{
            Spawned        = $false
            ManifestEntry  = $null
            ReasonCode     = 'orchestra_mode_invalid'
            Diagnostic     = [string]$_.Exception.Message
        }
    }

    $manifest = $null
    if (Get-Command Get-WinsmuxManifest -ErrorAction SilentlyContinue) {
        try {
            $manifest = Get-WinsmuxManifest -ProjectDir $ProjectDir
        } catch {
            $manifest = $null
        }
    }
    $liveWorkers = 0
    if (Get-Command Get-OrchestraLiveWorkerRolePaneCount -ErrorAction SilentlyContinue) {
        $liveWorkers = [int](Get-OrchestraLiveWorkerRolePaneCount -Manifest $manifest)
    }
    $maxLive = 6
    if (Get-Command Get-OrchestraMaxLiveWorkerPaneCount -ErrorAction SilentlyContinue) {
        $maxLive = [int](Get-OrchestraMaxLiveWorkerPaneCount -Mode $mode)
    } elseif ($mode -ceq 'simple') {
        $maxLive = 1
    }
    if ($liveWorkers -ge $maxLive) {
        $reason = if ($mode -ceq 'simple') { 'simple_mode_live_worker_limit' } else { 'team_mode_live_worker_limit' }
        return [pscustomobject]@{
            Spawned        = $false
            ManifestEntry  = $null
            ReasonCode     = $reason
            Diagnostic     = ("{0}: live worker-role panes={1} max={2}" -f $reason, $liveWorkers, $maxLive)
        }
    }

    Import-Task789OrchestraHelpers -IncludePaneScaler
    $settings = $null
    if (Get-Command Get-BridgeSettings -ErrorAction SilentlyContinue) {
        $settings = Get-BridgeSettings -RootPath $ProjectDir
    }
    if (-not (Get-Command Invoke-TeamProfileLaunchProjection -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Spawned        = $false
            ManifestEntry  = $null
            ReasonCode     = 'team_profile_projection_unavailable'
            Diagnostic     = "Team Profile launch projection is unavailable for slot '$Label'."
        }
    }

    $liveManifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
    $liveRegistryPath = $null
    if (Get-Command Get-WinsmuxRuntimeRegistryPath -ErrorAction SilentlyContinue) {
        $liveRegistryPath = Get-WinsmuxRuntimeRegistryPath -ProjectDir $ProjectDir
    } else {
        $liveRegistryPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'runtime\registry.json'
    }
    $beforeManifest = $null
    $beforeRegistry = $null
    if (Test-Path -LiteralPath $liveManifestPath -PathType Leaf) {
        $beforeManifest = [System.IO.File]::ReadAllBytes($liveManifestPath)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$liveRegistryPath) -and (Test-Path -LiteralPath $liveRegistryPath -PathType Leaf)) {
        $beforeRegistry = [System.IO.File]::ReadAllBytes($liveRegistryPath)
    }

    $assignment = $null
    try {
        $projection = Invoke-TeamProfileLaunchProjection -ProjectDir $ProjectDir -SessionId 'winsmux-orchestra' -SlotId $Label -Worktree '' -ReadWriteScope 'session' -Force
        $afterManifest = $null
        $afterRegistry = $null
        if (Test-Path -LiteralPath $liveManifestPath -PathType Leaf) {
            $afterManifest = [System.IO.File]::ReadAllBytes($liveManifestPath)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$liveRegistryPath) -and (Test-Path -LiteralPath $liveRegistryPath -PathType Leaf)) {
            $afterRegistry = [System.IO.File]::ReadAllBytes($liveRegistryPath)
        }
        $manifestMutated = -not (Test-DispatchTaskLiveFileBytesEqual -Before $beforeManifest -After $afterManifest)
        $registryPaneSetMutated = -not (Test-DispatchTaskLiveRegistryPaneSetEqual -Before $beforeRegistry -After $afterRegistry)
        if ($manifestMutated -or $registryPaneSetMutated) {
            Restore-DispatchTaskLiveFileBytes -Path $liveManifestPath -Bytes $beforeManifest
            if ($registryPaneSetMutated -and -not [string]::IsNullOrWhiteSpace([string]$liveRegistryPath)) {
                Restore-DispatchTaskLiveFileBytes -Path $liveRegistryPath -Bytes $beforeRegistry
            }
            return [pscustomobject]@{
                Spawned        = $false
                ManifestEntry  = $null
                ReasonCode     = 'team_profile_projection_mutated_live_manifest'
                Diagnostic     = "Team Profile launch projection mutated live pane-set files for slot '$Label'."
            }
        }
        $projRoot = $projection
        $nestedProjection = Get-WinsmuxRuntimeValue -InputObject $projection -Name 'projection'
        if ($null -ne $nestedProjection) {
            $projRoot = $nestedProjection
        }
        $projectedPane = Get-WinsmuxRuntimeValue -InputObject $projRoot -Name 'pane'
        $assignment = Get-WinsmuxRuntimeValue -InputObject $projectedPane -Name 'assignment'
        if ($null -eq $assignment) {
            return [pscustomobject]@{
                Spawned        = $false
                ManifestEntry  = $null
                ReasonCode     = 'team_profile_projection_unavailable'
                Diagnostic     = "Team Profile launch projection did not produce an assignment for slot '$Label'."
            }
        }
    } catch {
        Restore-DispatchTaskLiveFileBytes -Path $liveManifestPath -Bytes $beforeManifest
        $currentRegistry = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$liveRegistryPath) -and (Test-Path -LiteralPath $liveRegistryPath -PathType Leaf)) {
            $currentRegistry = [System.IO.File]::ReadAllBytes($liveRegistryPath)
        }
        if (-not (Test-DispatchTaskLiveRegistryPaneSetEqual -Before $beforeRegistry -After $currentRegistry)) {
            Restore-DispatchTaskLiveFileBytes -Path $liveRegistryPath -Bytes $beforeRegistry
        }
        return [pscustomobject]@{
            Spawned        = $false
            ManifestEntry  = $null
            ReasonCode     = 'team_profile_projection_unavailable'
            Diagnostic     = [string]$_.Exception.Message
        }
    }

    $slotAgentConfig = $null
    if (Get-Command New-TeamProfileSlotAgentConfig -ErrorAction SilentlyContinue) {
        # Spawn uses Team Profile assignment.worker_backend via New-TeamProfileSlotAgentConfig.
        $slotAgentConfig = New-TeamProfileSlotAgentConfig -Role 'Worker' -SlotId $Label -Assignment $assignment -Settings $settings -RootPath $ProjectDir
    }
    if ($null -eq $slotAgentConfig) {
        return [pscustomobject]@{
            Spawned        = $false
            ManifestEntry  = $null
            ReasonCode     = 'team_profile_projection_unavailable'
            Diagnostic     = "Team Profile slot agent config is unavailable for slot '$Label'."
        }
    }

    $manifestPath = Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml'
    $null = Add-OrchestraPane -ManifestPath $manifestPath -Role 'Worker' -SlotId $Label -Settings $settings -SlotAgentConfig $slotAgentConfig -Assignment $assignment -Projection $projection
    $spawnedEntry = Get-DispatchTaskManifestEntry -ProjectDir $ProjectDir -Label $Label
    return [pscustomobject]@{
        Spawned        = $true
        ManifestEntry  = $spawnedEntry
        ReasonCode     = ''
        Diagnostic     = ''
    }
}

function New-WinsmuxArchivePaneIdleResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Idle,
        [Parameter(Mandatory = $true)][ValidateSet('idle', 'busy', 'unavailable')][string]$Evidence,
        [AllowEmptyString()][string]$Status = '',
        [AllowEmptyString()][string]$LastEvent = ''
    )

    return [pscustomobject]@{
        Idle      = $Idle
        Evidence  = $Evidence
        Status    = $Status
        LastEvent = $LastEvent
    }
}

function Resolve-WinsmuxArchivePaneIdleState {
    param([AllowNull()]$Result = $null)

    if ($Result -is [bool]) {
        return New-WinsmuxArchivePaneIdleResult -Idle ([bool]$Result) -Evidence $(if ($Result) { 'idle' } else { 'busy' })
    }
    if ($null -eq $Result) {
        return New-WinsmuxArchivePaneIdleResult -Idle $false -Evidence 'unavailable'
    }

    $evidence = [string](Get-WinsmuxRuntimeValue -InputObject $Result -Name 'Evidence' -Default '')
    $idle = $false
    $idleRaw = Get-WinsmuxRuntimeValue -InputObject $Result -Name 'Idle' -Default $null
    if ($idleRaw -is [bool]) {
        $idle = [bool]$idleRaw
    }
    if ([string]::IsNullOrWhiteSpace($evidence)) {
        $evidence = if ($idle) { 'idle' } else { 'unavailable' }
    }
    if ($evidence -cnotin @('idle', 'busy', 'unavailable')) {
        $evidence = 'unavailable'
        $idle = $false
    }
    return New-WinsmuxArchivePaneIdleResult -Idle $idle -Evidence $evidence `
        -Status ([string](Get-WinsmuxRuntimeValue -InputObject $Result -Name 'Status' -Default '')) `
        -LastEvent ([string](Get-WinsmuxRuntimeValue -InputObject $Result -Name 'LastEvent' -Default ''))
}

function Test-WinsmuxArchivePaneIdle {
    param(
        [AllowNull()]$Entry = $null,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    $status = ''
    $lastEvent = ''
    $label = ''
    $paneId = ''
    if ($null -ne $Entry) {
        foreach ($pair in @(@('Status', 'status'), @('LastEvent', 'last_event'), @('Label', 'label'), @('PaneId', 'pane_id'))) {
            $value = ''
            foreach ($name in $pair) {
                if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($name)) {
                    $value = [string]$Entry[$name]
                    break
                }
                if ($null -ne $Entry.PSObject -and $Entry.PSObject.Properties.Name -contains $name) {
                    $value = [string]$Entry.PSObject.Properties[$name].Value
                    break
                }
            }
            switch ($pair[0]) {
                'Status' { $status = $value }
                'LastEvent' { $lastEvent = $value }
                'Label' { $label = $value }
                'PaneId' { $paneId = $value }
            }
        }
    }

    $idleEvents = @('pane.idle', 'pane.completed', 'pane.ready')
    $busyEvents = @('pane.progress', 'pane.approval_waiting', 'pane.busy', 'pane.hung', 'pane.stalled')
    if ($busyEvents -contains $lastEvent) {
        return New-WinsmuxArchivePaneIdleResult -Idle $false -Evidence 'busy' -Status $status -LastEvent $lastEvent
    }

    if (Get-Command Get-BridgeEventRecords -ErrorAction SilentlyContinue) {
        $events = @(Get-BridgeEventRecords -ProjectDir $ProjectDir)
        $matching = @(
            $events | Where-Object {
                $eventLabel = [string]$_['label']
                $eventPane = [string]$_['pane_id']
                ((-not [string]::IsNullOrWhiteSpace($label) -and $eventLabel -ceq $label) -or
                 (-not [string]::IsNullOrWhiteSpace($paneId) -and $eventPane -ceq $paneId))
            }
        )
        if ($matching.Count -gt 0) {
            $eventName = [string]$matching[-1]['event']
            if ($busyEvents -contains $eventName) {
                return New-WinsmuxArchivePaneIdleResult -Idle $false -Evidence 'busy' -Status $status -LastEvent $eventName
            }
            if ($idleEvents -contains $eventName) {
                return New-WinsmuxArchivePaneIdleResult -Idle $true -Evidence 'idle' -Status $status -LastEvent $eventName
            }
        }
    }

    if ($idleEvents -contains $lastEvent) {
        return New-WinsmuxArchivePaneIdleResult -Idle $true -Evidence 'idle' -Status $status -LastEvent $lastEvent
    }
    if ($status -in @('busy', 'approval_waiting', 'hung', 'stalled')) {
        return New-WinsmuxArchivePaneIdleResult -Idle $false -Evidence 'busy' -Status $status -LastEvent $lastEvent
    }
    if ($status -in @('ready', 'waiting_for_dispatch', 'deferred_start', 'deferred_starting')) {
        return New-WinsmuxArchivePaneIdleResult -Idle $true -Evidence 'idle' -Status $status -LastEvent $lastEvent
    }

    return New-WinsmuxArchivePaneIdleResult -Idle $false -Evidence 'unavailable' -Status $status -LastEvent $lastEvent
}

function Get-WinsmuxArchivePaneRefusal {
    param(
        [AllowNull()]$Entry = $null,
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowNull()]$Manifest = $null
    )

    $paneId = Get-DispatchTaskEntryPaneId -Entry $Entry
    if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace($paneId)) {
        return [pscustomobject]@{
            ReasonCode = 'pane_not_live'
            Diagnostic = "archive-pane: slot '$Label' has no live pane."
        }
    }

    $role = ''
    if (Get-Command Get-OrchestraCanonicalPaneRole -ErrorAction SilentlyContinue) {
        $role = [string](Get-OrchestraCanonicalPaneRole -Pane $Entry -Label $Label)
    }
    if ($role -cne 'Worker') {
        return [pscustomobject]@{
            ReasonCode = 'archive_role_not_worker'
            Diagnostic = "archive-pane: slot '$Label' is not a Worker pane."
        }
    }

    if (Get-Command Test-OrchestraArchiveRemovesLastRequiredWorker -ErrorAction SilentlyContinue) {
        if (Test-OrchestraArchiveRemovesLastRequiredWorker -Manifest $Manifest -Label $Label) {
            return [pscustomobject]@{
                ReasonCode = 'last_required_worker'
                Diagnostic = "archive-pane: refusing to archive the last required worker pane '$Label'."
            }
        }
    }

    return $null
}

function Get-WinsmuxArchivePaneRuntimeRefusal {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [AllowNull()]$Entry = $null
    )

    if (-not (Get-Command Test-PaneControlRuntimeContext -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            ReasonCode = 'runtime_target_mismatch'
            Diagnostic = 'archive-pane: runtime ownership validation is unavailable.'
        }
    }

    $runtimeResult = Test-PaneControlRuntimeContext -ProjectDir $ProjectDir -ManifestEntry $Entry -Operation stop_transition
    if ($null -ne $runtimeResult -and [bool]$runtimeResult.valid) {
        return $null
    }

    $reasonCode = 'runtime_target_mismatch'
    $diagnostic = 'archive-pane: runtime ownership validation failed.'
    if ($null -ne $runtimeResult) {
        $candidateReason = [string](Get-WinsmuxRuntimeValue -InputObject $runtimeResult -Name 'reason_code' -Default '')
        $candidateDiagnostic = [string](Get-WinsmuxRuntimeValue -InputObject $runtimeResult -Name 'diagnostic' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($candidateReason)) {
            $reasonCode = $candidateReason
        }
        if (-not [string]::IsNullOrWhiteSpace($candidateDiagnostic)) {
            $diagnostic = $candidateDiagnostic
        }
    }
    return [pscustomobject]@{
        ReasonCode = $reasonCode
        Diagnostic = $diagnostic
    }
}

function Invoke-WinsmuxArchivePaneCommand {
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
    $projectDir = (Get-Location).Path
    $json = $false
    $slot = ''
    $index = 0
    while ($index -lt $parts.Count) {
        $current = [string]$parts[$index]
        if ($current -ceq '--project-dir') {
            if ($index + 1 -ge $parts.Count) {
                Stop-WithError 'usage: winsmux archive-pane <slot> [--json] [--project-dir <path>]'
            }
            $projectDir = [string]$parts[$index + 1]
            $index += 2
            continue
        }
        if ($current -ceq '--json') {
            $json = $true
            $index++
            continue
        }
        if ([string]::IsNullOrWhiteSpace($slot)) {
            $slot = $current
            $index++
            continue
        }
        Stop-WithError 'usage: winsmux archive-pane <slot> [--json] [--project-dir <path>]'
    }
    if ([string]::IsNullOrWhiteSpace($slot)) {
        Stop-WithError 'usage: winsmux archive-pane <slot> [--json] [--project-dir <path>]'
    }

    Import-Task789OrchestraHelpers -IncludePaneScaler
    $entry = Get-DispatchTaskManifestEntry -ProjectDir $projectDir -Label $slot
    $paneId = Get-DispatchTaskEntryPaneId -Entry $entry
    $manifestPath = Join-Path (Join-Path $projectDir '.winsmux') 'manifest.yaml'
    $manifest = $null
    if (Get-Command Read-PaneScalerManifest -ErrorAction SilentlyContinue -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        try {
            $manifest = Read-PaneScalerManifest -ManifestPath $manifestPath
        } catch {
            $manifest = $null
        }
    }
    $refusal = Get-WinsmuxArchivePaneRefusal -Entry $entry -Label $slot -Manifest $manifest
    if ($null -ne $refusal) {
        $payload = [ordered]@{
            ok          = $false
            action      = 'archive-pane'
            slot        = $slot
            pane_id     = $paneId
            reason_code = [string]$refusal.ReasonCode
            diagnostic  = [string]$refusal.Diagnostic
        }
        if ($json) {
            $payload | ConvertTo-Json -Compress
        } else {
            Write-Output $payload.diagnostic
        }
        exit 1
    }

    $runtimeRefusal = Get-WinsmuxArchivePaneRuntimeRefusal -ProjectDir $projectDir -Entry $entry
    if ($null -ne $runtimeRefusal) {
        $payload = [ordered]@{
            ok          = $false
            action      = 'archive-pane'
            slot        = $slot
            pane_id     = $paneId
            reason_code = [string]$runtimeRefusal.ReasonCode
            diagnostic  = [string]$runtimeRefusal.Diagnostic
        }
        if ($json) {
            $payload | ConvertTo-Json -Compress
        } else {
            Write-Output $payload.diagnostic
        }
        exit 1
    }

    $idleState = Resolve-WinsmuxArchivePaneIdleState -Result (Test-WinsmuxArchivePaneIdle -Entry $entry -ProjectDir $projectDir)
    # Unknown/empty status with no recognized idle event is not interruptible busy.
    if ($idleState.Evidence -ceq 'unavailable') {
        $payload = [ordered]@{
            ok          = $false
            action      = 'archive-pane'
            slot        = $slot
            pane_id     = $paneId
            reason_code = 'archive_idle_required'
            diagnostic  = "archive-pane: idle evidence is unavailable for '$slot'; pane was left in place."
        }
        if ($json) {
            $payload | ConvertTo-Json -Compress
        } else {
            Write-Output $payload.diagnostic
        }
        exit 1
    }
    # Collect requires pane.idle (or equivalent idle status) after interrupt before kill-pane.
    if (-not [bool]$idleState.Idle) {
        if (Get-Command Invoke-WinsmuxRaw -ErrorAction SilentlyContinue) {
            Invoke-WinsmuxRaw -Arguments @('keys', $paneId, 'C-c') | Out-Null
        } elseif (Get-Command Invoke-MonitorWinsmux -ErrorAction SilentlyContinue) {
            Invoke-MonitorWinsmux -Arguments @('keys', $paneId, 'C-c') | Out-Null
        } else {
            throw "archive-pane could not send interrupt to pane $paneId"
        }

        $becameIdle = $false
        for ($attempt = 1; $attempt -le 8; $attempt++) {
            Start-Sleep -Milliseconds 250
            if (Get-Command Get-PaneAgentStatus -ErrorAction SilentlyContinue) {
                $liveStatus = ''
                try {
                    $live = Get-PaneAgentStatus -PaneId $paneId -Role 'Worker'
                    $liveStatus = [string](Get-WinsmuxRuntimeValue -InputObject $live -Name 'Status' -Default '')
                } catch {
                    $liveStatus = ''
                }
                if ($liveStatus -in @('ready', 'waiting_for_dispatch')) {
                    $becameIdle = $true
                    break
                }
            }
            $entry = Get-DispatchTaskManifestEntry -ProjectDir $projectDir -Label $slot
            $waitState = Resolve-WinsmuxArchivePaneIdleState -Result (Test-WinsmuxArchivePaneIdle -Entry $entry -ProjectDir $projectDir)
            if ([bool]$waitState.Idle -and $waitState.Evidence -ceq 'idle') {
                $becameIdle = $true
                break
            }
        }
        if (-not $becameIdle) {
            $payload = [ordered]@{
                ok          = $false
                action      = 'archive-pane'
                slot        = $slot
                pane_id     = $paneId
                reason_code = 'archive_idle_required'
                diagnostic  = "archive-pane: interrupt did not make '$slot' idle; pane was left in place."
            }
            if ($json) {
                $payload | ConvertTo-Json -Compress
            } else {
                Write-Output $payload.diagnostic
            }
            exit 1
        }
    }

    $removed = Remove-OrchestraPane -ManifestPath $manifestPath -Role 'Worker' -Label $slot
    $payload = [ordered]@{
        ok          = [bool]$removed.Changed
        action      = 'archive-pane'
        slot        = $slot
        pane_id     = $paneId
        removed     = [bool]$removed.Changed
        reason_code = if ([bool]$removed.Changed) { '' } else { [string]$removed.Reason }
    }
    if ($json) {
        $payload | ConvertTo-Json -Compress
    } else {
        Write-Output ("archive-pane {0}: {1}" -f $slot, $(if ($payload.ok) { 'archived' } else { 'unchanged' }))
    }
    if (-not $payload.ok) {
        exit 1
    }
}
