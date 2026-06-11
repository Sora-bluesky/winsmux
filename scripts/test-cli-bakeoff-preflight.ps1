param(
    [string]$ProjectDir = (Get-Location).Path,
    [Parameter(Mandatory = $true)][string]$RunDir,
    [string]$WorkerSpecPath = '',
    [int]$TimeoutSeconds = 120,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Write-BakeoffJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $Value | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-BakeoffJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
}

function Get-BakeoffClaudeChannels {
    param([AllowNull()]$Worker)

    if ($null -eq $Worker) {
        return @()
    }

    foreach ($propertyName in @('claudeChannels', 'claude_channels')) {
        $property = $Worker.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value) {
            return @($property.Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }

    return @()
}

function Get-BakeoffSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-BakeoffWorkerSpecs {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedRunDir,
        [string]$SpecPath
    )

    if (-not [string]::IsNullOrWhiteSpace($SpecPath)) {
        return @(Read-BakeoffJson -Path (Resolve-Path -LiteralPath $SpecPath).Path)
    }

    $manifestPath = Join-Path $ResolvedRunDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "WorkerSpecPath or manifest.json is required: $ResolvedRunDir"
    }

    $manifest = Read-BakeoffJson -Path $manifestPath
    if ($null -eq $manifest.active_workers) {
        throw "manifest.json must contain active_workers: $manifestPath"
    }

    return @($manifest.active_workers | ForEach-Object {
        $modelArg = [string]$_.model_arg
        if ([string]::IsNullOrWhiteSpace($modelArg)) {
            $modelArg = [string]$_.model
        }
        $displayModel = [string]$_.display_model
        if ([string]::IsNullOrWhiteSpace($displayModel)) {
            $displayModel = [string]$_.model
        }

        [pscustomobject]@{
            paneId          = [string]$_.pane
            cli             = [string]$_.cli
            model           = $modelArg
            effort          = [string]$_.effort
            displayModel    = $displayModel
            task_sha256     = [string]$_.task_sha256
            commandPath     = [string]$_.commandPath
            commandArgsJson = [string]$_.commandArgsJson
            claudeChannels  = @(Get-BakeoffClaudeChannels -Worker $_)
            workspace       = [string]$_.workspace
            workspaceIsolated = [string]$_.workspace_isolated
            workspaceRepo   = [string]$_.workspace_repo
            workspaceBaseRef = [string]$_.workspace_base_ref
            workspaceHead   = [string]$_.workspace_head
        }
    })
}

function ConvertTo-BakeoffWorkerContract {
    param(
        [Parameter(Mandatory = $true)]$Worker,
        [switch]$FromManifest
    )

    $paneId = [string]$Worker.paneId
    if ([string]::IsNullOrWhiteSpace($paneId)) {
        $paneId = [string]$Worker.pane
    }

    $model = [string]$Worker.model
    if ($FromManifest -and -not [string]::IsNullOrWhiteSpace([string]$Worker.model_arg)) {
        $model = [string]$Worker.model_arg
    }

    $displayModel = [string]$Worker.displayModel
    if ([string]::IsNullOrWhiteSpace($displayModel)) {
        $displayModel = [string]$Worker.display_model
    }
    if ([string]::IsNullOrWhiteSpace($displayModel)) {
        $displayModel = [string]$Worker.model
    }

    return [ordered]@{
        pane_id           = $paneId
        cli               = [string]$Worker.cli
        model             = $model
        effort            = [string]$Worker.effort
        display_model     = $displayModel
        task_sha256       = [string]$Worker.task_sha256
        command_path      = [string]$Worker.commandPath
        command_args_json = [string]$Worker.commandArgsJson
        claude_channels   = (@(Get-BakeoffClaudeChannels -Worker $Worker) -join "`n")
        workspace         = if ($FromManifest) { [string]$Worker.workspace } else { [string]$Worker.workspace }
        workspace_isolated = if ($FromManifest) { [string]$Worker.workspace_isolated } else { [string]$Worker.workspaceIsolated }
        workspace_repo    = if ($FromManifest) { [string]$Worker.workspace_repo } else { [string]$Worker.workspaceRepo }
        workspace_base_ref = if ($FromManifest) { [string]$Worker.workspace_base_ref } else { [string]$Worker.workspaceBaseRef }
        workspace_head    = if ($FromManifest) { [string]$Worker.workspace_head } else { [string]$Worker.workspaceHead }
    }
}

function Test-BakeoffWorkerSpecConsistency {
    param(
        [Parameter(Mandatory = $true)]$Workers,
        [AllowNull()]$Manifest,
        [bool]$ExternalSpecSupplied
    )

    if (-not $ExternalSpecSupplied) {
        return [ordered]@{
            passed     = $true
            reason     = ''
            mismatches = @()
        }
    }

    $mismatches = @()
    if ($null -eq $Manifest) {
        return [ordered]@{
            passed     = $false
            reason     = 'missing_worker_manifest'
            mismatches = @()
        }
    }

    $activeWorkersProperty = $Manifest.PSObject.Properties['active_workers']
    if ($null -eq $activeWorkersProperty -or $null -eq $activeWorkersProperty.Value) {
        return [ordered]@{
            passed     = $false
            reason     = 'missing_manifest_active_workers'
            mismatches = @()
        }
    }

    $expectedWorkers = @($activeWorkersProperty.Value | ForEach-Object {
        ConvertTo-BakeoffWorkerContract -Worker $_ -FromManifest
    })
    $actualWorkers = @($Workers | ForEach-Object {
        ConvertTo-BakeoffWorkerContract -Worker $_
    })

    $expectedByPane = @{}
    foreach ($worker in $expectedWorkers) {
        $paneId = [string]$worker.pane_id
        if ($expectedByPane.ContainsKey($paneId)) {
            $mismatches += [ordered]@{
                pane_id = $paneId
                field   = 'pane_id'
                reason  = 'duplicate_manifest_worker'
            }
            continue
        }
        $expectedByPane[$paneId] = $worker
    }

    $actualByPane = @{}
    foreach ($worker in $actualWorkers) {
        $paneId = [string]$worker.pane_id
        if ($actualByPane.ContainsKey($paneId)) {
            $mismatches += [ordered]@{
                pane_id = $paneId
                field   = 'pane_id'
                reason  = 'duplicate_worker_spec'
            }
            continue
        }
        $actualByPane[$paneId] = $worker
    }

    foreach ($paneId in @($expectedByPane.Keys)) {
        if (-not $actualByPane.ContainsKey($paneId)) {
            $mismatches += [ordered]@{
                pane_id = $paneId
                field   = 'pane_id'
                reason  = 'missing_worker_spec'
            }
        }
    }

    foreach ($paneId in @($actualByPane.Keys)) {
        if (-not $expectedByPane.ContainsKey($paneId)) {
            $mismatches += [ordered]@{
                pane_id = $paneId
                field   = 'pane_id'
                reason  = 'unexpected_worker_spec'
            }
            continue
        }

        $expected = $expectedByPane[$paneId]
        $actual = $actualByPane[$paneId]
        foreach ($field in @('cli', 'model', 'effort', 'display_model', 'task_sha256', 'command_path', 'command_args_json', 'claude_channels', 'workspace', 'workspace_isolated', 'workspace_repo', 'workspace_base_ref', 'workspace_head')) {
            $expectedValue = [string]$expected[$field]
            $actualValue = [string]$actual[$field]
            $matches = if ($field -eq 'task_sha256') {
                [string]::Equals($expectedValue, $actualValue, [System.StringComparison]::OrdinalIgnoreCase)
            } else {
                [string]::Equals($expectedValue, $actualValue, [System.StringComparison]::Ordinal)
            }

            if (-not $matches) {
                $mismatches += [ordered]@{
                    pane_id  = $paneId
                    field    = $field
                    expected = $expectedValue
                    actual   = $actualValue
                    reason   = 'stale_worker_spec'
                }
            }
        }
    }

    return [ordered]@{
        passed     = (@($mismatches).Count -eq 0)
        reason     = if (@($mismatches).Count -eq 0) { '' } else { 'stale_worker_spec' }
        mismatches = @($mismatches)
    }
}

function Test-BakeoffTaskPacketConsistency {
    param(
        [Parameter(Mandatory = $true)]$Workers,
        [AllowNull()][string]$ExpectedSha256,
        [AllowNull()][string]$ManifestSha256
    )

    $mismatchedWorkers = @()
    $manifestMatchesTask = $true
    $manifestReason = ''
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $manifestMatchesTask = $false
        $manifestReason = 'missing_task_packet'
    } elseif ([string]::IsNullOrWhiteSpace($ManifestSha256)) {
        $manifestMatchesTask = $false
        $manifestReason = 'missing_task_packet_manifest'
    } elseif (
        -not [string]::Equals([string]$ManifestSha256, [string]$ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        $manifestMatchesTask = $false
        $manifestReason = 'stale_task_packet_manifest'
    }

    foreach ($worker in @($Workers)) {
        $paneId = [string]$worker.paneId
        if ([string]::IsNullOrWhiteSpace($paneId)) {
            $paneId = [string]$worker.pane
        }

        $actualSha = ''
        $taskHashProperty = $worker.PSObject.Properties['task_sha256']
        if ($null -ne $taskHashProperty) {
            $actualSha = [string]$taskHashProperty.Value
        }

        if ([string]::IsNullOrWhiteSpace($actualSha)) {
            $mismatchedWorkers += [ordered]@{
                pane_id         = $paneId
                expected_sha256 = [string]$ExpectedSha256
                actual_sha256   = ''
                reason          = 'missing_worker_task_packet_hash'
            }
            continue
        }

        if (-not [string]::Equals($actualSha, [string]$ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            $mismatchedWorkers += [ordered]@{
                pane_id         = $paneId
                expected_sha256 = [string]$ExpectedSha256
                actual_sha256   = $actualSha
                reason          = 'stale_task_packet'
            }
        }
    }

    return [ordered]@{
        passed             = ($manifestMatchesTask -and (@($mismatchedWorkers).Count -eq 0))
        expected_sha256    = [string]$ExpectedSha256
        manifest_sha256    = [string]$ManifestSha256
        manifest_matches_task = $manifestMatchesTask
        manifest_reason    = $manifestReason
        mismatched_workers = @($mismatchedWorkers)
    }
}

function Get-BakeoffLaunchScriptStatuses {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedRunDir,
        [AllowNull()]$Manifest
    )

    $expectedByName = @{}
    $launchScriptProperty = if ($null -eq $Manifest) { $null } else { $Manifest.PSObject.Properties['launch_scripts'] }
    if ($null -ne $launchScriptProperty -and $null -ne $launchScriptProperty.Value) {
        foreach ($entry in @($launchScriptProperty.Value)) {
            $name = [string]$entry.name
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $expectedByName[$name] = [string]$entry.sha256
            }
        }
    }

    $seenNames = @{}
    $statuses = @(
        Get-ChildItem -LiteralPath $ResolvedRunDir -Filter 'run-worker-*.ps1' -File -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object {
                $currentSha = Get-BakeoffSha256 -Path $_.FullName
                $expectedSha = ''
                $status = 'current'
                $reason = ''
                if ($expectedByName.ContainsKey($_.Name)) {
                    $expectedSha = [string]$expectedByName[$_.Name]
                    if ([string]::IsNullOrWhiteSpace($expectedSha)) {
                        $status = 'missing_baseline'
                        $reason = 'missing_launch_script_hash'
                    } elseif ([string]::Equals($expectedSha, $currentSha, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $status = 'unchanged'
                    } else {
                        $status = 'changed'
                        $reason = 'stale_launch_script'
                    }
                } elseif ($expectedByName.Count -gt 0) {
                    $status = 'unexpected'
                    $reason = 'stale_launch_script'
                } else {
                    $status = 'unexpected'
                    $reason = 'missing_launch_script_manifest'
                }
                $seenNames[$_.Name] = $true

                [ordered]@{
                    name            = $_.Name
                    sha256          = $currentSha
                    expected_sha256 = $expectedSha
                    status          = $status
                    reason          = $reason
                }
            }
    )

    foreach ($expectedName in @($expectedByName.Keys | Sort-Object)) {
        if (-not $seenNames.ContainsKey($expectedName)) {
            $statuses += [ordered]@{
                name            = $expectedName
                sha256          = ''
                expected_sha256 = [string]$expectedByName[$expectedName]
                status          = 'missing'
                reason          = 'stale_launch_script'
            }
        }
    }

    return @($statuses)
}

function Get-BakeoffPreflightWorkerStatus {
    param(
        [Parameter(Mandatory = $true)]$Worker,
        [Parameter(Mandatory = $true)][string]$ResolvedProjectDir,
        [Parameter(Mandatory = $true)][string]$PreflightRoot,
        [Parameter(Mandatory = $true)][string]$WorkerRunnerPath,
        [int]$TimeoutSeconds
    )

    $paneId = [string]$Worker.paneId
    if ([string]::IsNullOrWhiteSpace($paneId)) {
        throw 'worker paneId must not be empty.'
    }

    $cli = [string]$Worker.cli
    if ([string]::IsNullOrWhiteSpace($cli)) {
        throw "worker $paneId cli must not be empty."
    }

    $model = [string]$Worker.model
    $workerProjectDir = [string]$Worker.workspace
    if ([string]::IsNullOrWhiteSpace($workerProjectDir)) {
        $workerProjectDir = $ResolvedProjectDir
    }
    $workerRunDir = Join-Path $PreflightRoot ($paneId -replace '[^A-Za-z0-9._-]', '-')
    New-Item -ItemType Directory -Path $workerRunDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $workerRunDir 'pane-transcript.txt') -Value '' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $workerRunDir 'commands.jsonl') -Value '' -Encoding UTF8
    [ordered]@{
        version = 1
        run_id  = "preflight-$paneId"
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $workerRunDir 'manifest.json') -Encoding UTF8

    $expectedMarker = "PREFLIGHT_OK $paneId"
    $prompt = @"
This is a winsmux CLI connectivity preflight.
Do not use tools.
Return exactly this single line:
$expectedMarker
"@

    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-File', $WorkerRunnerPath,
        '-ProjectDir', $workerProjectDir,
        '-RunDir', $workerRunDir,
        '-PaneId', $paneId,
        '-Cli', $cli,
        '-Model', $model,
        '-Effort', [string]$Worker.effort,
        '-PromptText', $prompt,
        '-EndMarker', '',
        '-TimeoutSeconds', [string]$TimeoutSeconds,
        '-Json'
    )

    if ([string]::Equals($cli, 'custom', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ([string]::IsNullOrWhiteSpace([string]$Worker.commandPath)) {
            throw "custom worker $paneId requires commandPath."
        }
        $arguments += @('-CommandPath', [string]$Worker.commandPath)
        if (-not [string]::IsNullOrWhiteSpace([string]$Worker.commandArgsJson)) {
            $arguments += @('-CommandArgsJson', [string]$Worker.commandArgsJson)
        }
    }
    $claudeChannels = @(Get-BakeoffClaudeChannels -Worker $Worker)
    if ($claudeChannels.Count -gt 0) {
        $arguments += @('-ClaudeChannels')
        $arguments += @($claudeChannels)
    }

    $stdout = ''
    $stderr = ''
    $exitCode = 0
    try {
        $stdout = & pwsh @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } catch {
        $stderr = $_.Exception.Message
        $exitCode = 1
    }

    $runnerResult = $null
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        try {
            $runnerResult = $stdout | ConvertFrom-Json -Depth 16
        } catch {
            $runnerResult = $null
        }
    }

    $resultPath = ''
    if ($null -ne $runnerResult -and -not [string]::IsNullOrWhiteSpace([string]$runnerResult.result)) {
        $resultPath = [string]$runnerResult.result
    } else {
        $resultPath = Join-Path $workerRunDir "$($paneId -replace '[^A-Za-z0-9._-]', '-')-result.json"
    }

    $result = if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        Read-BakeoffJson -Path $resultPath
    } else {
        $null
    }
    $workerStdout = ''
    if ($null -ne $result -and -not [string]::IsNullOrWhiteSpace([string]$result.stdout_file)) {
        $stdoutPath = Join-Path $workerRunDir ([string]$result.stdout_file)
        if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
            $workerStdout = Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8
        }
    }

    $passed = $false
    $reason = ''
    if ($exitCode -ne 0) {
        $reason = "preflight_runner_exit_$exitCode"
    } elseif ($null -eq $result) {
        $reason = 'missing_worker_result'
    } elseif ([string]$result.status -ne 'completed') {
        $reason = if ([string]::IsNullOrWhiteSpace([string]$result.blocked_reason)) {
            [string]$result.status
        } else {
            [string]$result.blocked_reason
        }
    } elseif ($workerStdout -notmatch [regex]::Escape($expectedMarker)) {
        $reason = 'missing_expected_preflight_marker'
    } else {
        $passed = $true
    }

    return [ordered]@{
        pane_id         = $paneId
        cli             = $cli
        model           = $model
        effort          = [string]$Worker.effort
        display_model   = [string]$Worker.displayModel
        passed          = $passed
        reason          = $reason
        expected_marker = $expectedMarker
        status          = if ($null -eq $result) { '' } else { [string]$result.status }
        blocked_reason  = if ($null -eq $result) { '' } else { [string]$result.blocked_reason }
        exit_code       = if ($null -eq $result) { $null } else { $result.exit_code }
        evidence_dir    = $workerRunDir
        runner_output   = $stdout.Trim()
        runner_error    = $stderr
    }
}

$resolvedProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
$resolvedRunDir = (Resolve-Path -LiteralPath $RunDir).Path
$manifestPath = Join-Path $resolvedRunDir 'manifest.json'
$taskPath = Join-Path $resolvedRunDir 'task-packet.md'
$manifest = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    Read-BakeoffJson -Path $manifestPath
} else {
    $null
}
$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
$workerRunnerPath = Join-Path $repoRoot 'scripts\invoke-cli-bakeoff-worker.ps1'
if (-not (Test-Path -LiteralPath $workerRunnerPath -PathType Leaf)) {
    throw "Missing worker runner: $workerRunnerPath"
}

$workers = Get-BakeoffWorkerSpecs -ResolvedRunDir $resolvedRunDir -SpecPath $WorkerSpecPath
if (@($workers).Count -eq 0) {
    throw 'At least one worker is required for preflight.'
}
$externalWorkerSpecSupplied = -not [string]::IsNullOrWhiteSpace($WorkerSpecPath)

$preflightRoot = Join-Path $resolvedRunDir '.preflight'
if (Test-Path -LiteralPath $preflightRoot) {
    Remove-Item -LiteralPath $preflightRoot -Recurse -Force
}

$startedAt = (Get-Date).ToUniversalTime()
$taskSha256 = Get-BakeoffSha256 -Path $taskPath
$manifestTaskSha256 = if ($null -eq $manifest) { '' } else { [string]$manifest.task_packet_hash }
$workerSpecConsistency = Test-BakeoffWorkerSpecConsistency -Workers $workers -Manifest $manifest -ExternalSpecSupplied $externalWorkerSpecSupplied
$taskPacketConsistency = Test-BakeoffTaskPacketConsistency -Workers $workers -ExpectedSha256 $taskSha256 -ManifestSha256 $manifestTaskSha256
$launchScripts = @(Get-BakeoffLaunchScriptStatuses -ResolvedRunDir $resolvedRunDir -Manifest $manifest)
$launchScriptCount = if ($null -eq $launchScripts) { 0 } else { @($launchScripts).Count }
$taskArtifactPass = -not [string]::IsNullOrWhiteSpace($taskSha256)
$launchScriptFailures = @($launchScripts | Where-Object { $_.status -in @('changed', 'missing', 'unexpected', 'missing_baseline') })
$launchScriptsPass = ($launchScriptCount -gt 0) -and ($launchScriptFailures.Count -eq 0)
$launchScriptsReason = if ($launchScriptsPass) {
    ''
} elseif (@($launchScriptFailures | Where-Object { $_.reason -eq 'missing_launch_script_manifest' }).Count -gt 0) {
    'missing_launch_script_manifest'
} elseif (@($launchScriptFailures | Where-Object { $_.reason -eq 'missing_launch_script_hash' }).Count -gt 0) {
    'missing_launch_script_hash'
} elseif ($launchScriptCount -eq 0) {
    'missing_launch_script'
} else {
    'stale_launch_script'
}
$staticChecksPass = [bool]$workerSpecConsistency.passed -and $taskArtifactPass -and [bool]$taskPacketConsistency.passed -and $launchScriptsPass
$workerResults = @()
if ($staticChecksPass) {
    New-Item -ItemType Directory -Path $preflightRoot -Force | Out-Null
    $workerResults = @(foreach ($worker in $workers) {
        Get-BakeoffPreflightWorkerStatus `
            -Worker $worker `
            -ResolvedProjectDir $resolvedProjectDir `
            -PreflightRoot $preflightRoot `
            -WorkerRunnerPath $workerRunnerPath `
            -TimeoutSeconds $TimeoutSeconds
    })
}
$endedAt = (Get-Date).ToUniversalTime()
$workerChecksPass = -not [bool](@($workerResults | Where-Object { -not $_.passed }))
$allPass = $staticChecksPass -and $workerChecksPass
$workerSpecSnapshot = @($workers | ForEach-Object {
    [ordered]@{
        pane_id       = [string]$_.paneId
        cli           = [string]$_.cli
        model         = [string]$_.model
        display_model = [string]$_.displayModel
        task_sha256   = [string]$_.task_sha256
        claude_channels = @(Get-BakeoffClaudeChannels -Worker $_)
        workspace     = [string]$_.workspace
        workspace_isolated = [string]$_.workspaceIsolated
        workspace_repo = [string]$_.workspaceRepo
        workspace_base_ref = [string]$_.workspaceBaseRef
        workspace_head = [string]$_.workspaceHead
    }
})

$report = [ordered]@{
    version         = 1
    run_dir         = $resolvedRunDir
    all_pass        = $allPass
    manifest_sha256 = Get-BakeoffSha256 -Path $manifestPath
    task_sha256     = $taskSha256
    task_packet_artifact = [ordered]@{
        passed = $taskArtifactPass
        reason = if ($taskArtifactPass) { '' } else { 'missing_task_packet' }
    }
    task_packet_consistency = $taskPacketConsistency
    worker_spec_consistency = $workerSpecConsistency
    launch_scripts_artifact = [ordered]@{
        passed = $launchScriptsPass
        count  = $launchScriptCount
        reason = $launchScriptsReason
    }
    worker_specs    = $workerSpecSnapshot
    launch_scripts  = @($launchScripts)
    started_at_utc  = $startedAt.ToString('o')
    ended_at_utc    = $endedAt.ToString('o')
    workers         = @($workerResults)
}
$reportPath = Join-Path $resolvedRunDir 'preflight.json'
Write-BakeoffJson -Path $reportPath -Value $report

if ($Json) {
    $report | ConvertTo-Json -Depth 32
} else {
    if ($allPass) {
        Write-Output "CLI bakeoff preflight passed: $reportPath"
    } else {
        Write-Output "CLI bakeoff preflight failed: $reportPath"
        foreach ($worker in $workerResults | Where-Object { -not $_.passed }) {
            Write-Output ("- {0}: {1} {2}" -f $worker.pane_id, $worker.status, $worker.reason)
        }
        foreach ($worker in @($taskPacketConsistency.mismatched_workers)) {
            Write-Output ("- {0}: {1}" -f $worker.pane_id, $worker.reason)
        }
        if (-not [bool]$taskPacketConsistency.manifest_matches_task) {
            Write-Output ("- task-packet.md: {0}" -f $taskPacketConsistency.manifest_reason)
        }
        if (-not [bool]$workerSpecConsistency.passed) {
            Write-Output ("- worker specs: {0}" -f $workerSpecConsistency.reason)
            foreach ($mismatch in @($workerSpecConsistency.mismatches)) {
                Write-Output ("- {0}: {1}" -f $mismatch.pane_id, $mismatch.reason)
            }
        }
        if (-not $taskArtifactPass) {
            Write-Output '- task-packet.md: missing_task_packet'
        }
        if ($launchScriptCount -eq 0) {
            Write-Output '- run-worker-*.ps1: missing_launch_script'
        }
        foreach ($launchScript in $launchScripts | Where-Object { $_.status -in @('changed', 'missing', 'unexpected', 'missing_baseline') }) {
            Write-Output ("- {0}: {1}" -f $launchScript.name, $launchScript.reason)
        }
    }
}

if (-not $allPass) {
    exit 1
}
