[CmdletBinding()]
param(
    [string]$RunRoot = '.winsmux/evidence/cli-bakeoff',
    [string]$OutputDir = '.winsmux/evidence/cli-bakeoff/summary',
    [string]$PackPath = 'tasks/cli-bakeoff/v1/benchmark-pack.json',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
}

function Resolve-LocalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function ConvertTo-SafeCell {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $text = $text -replace [regex]::Escape($RepoRoot), '<repo>'
    $text = $text -replace '[A-Za-z]:\\[^,"\r\n]+', '<local-path>'
    return $text
}

function ConvertTo-CsvCell {
    param([AllowNull()][object]$Value)
    $text = ConvertTo-SafeCell $Value
    '"' + ($text -replace '"', '""') + '"'
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 80
}

function TryRead-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ ok = $false; value = $null; error = 'missing' }
    }

    try {
        return [pscustomobject]@{ ok = $true; value = (Read-JsonFile $Path); error = '' }
    } catch {
        return [pscustomobject]@{ ok = $false; value = $null; error = 'invalid_json' }
    }
}

function Get-ObjectProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )
    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $Default
}

function ConvertTo-StrictBool {
    param(
        [AllowNull()][object]$Value,
        [bool]$Default = $false
    )
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
    if ($text -match '^(?i:true|yes|1|present|matched|pass|passed|ok)$') { return $true }
    if ($text -match '^(?i:false|no|0|missing|mismatch|fail|failed)$') { return $false }
    return $Default
}

function ConvertTo-NormalizedReason {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim().ToLowerInvariant() -replace '[\s-]+', '_'
}

function Get-ScoreabilityDecision {
    param(
        [Parameter(Mandatory = $true)][string]$Cli,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][bool]$RecordingPublishable,
        [Parameter(Mandatory = $true)][bool]$EndMarkerPresent,
        [Parameter(Mandatory = $true)][bool]$PacketHashMatch,
        [Parameter(Mandatory = $true)][bool]$StdoutEmpty,
        [bool]$OperatorRun = $false,
        [AllowEmptyString()][string]$FailureClass = '',
        [AllowEmptyString()][string]$ExclusionReason = '',
        [bool]$MissingApiKey = $false,
        [bool]$TimedOut = $false,
        [bool]$Crashed = $false,
        [bool]$InvalidOutput = $false
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $normalizedStatus = ConvertTo-NormalizedReason $Status
    $normalizedFailureClass = ConvertTo-NormalizedReason $FailureClass
    $normalizedExclusionReason = ConvertTo-NormalizedReason $ExclusionReason
    if ($OperatorRun) { $reasons.Add('operator_run') | Out-Null }
    if ($MissingApiKey -or $normalizedStatus -in @('missing_api_key', 'api_llm_api_key_env_missing') -or $normalizedFailureClass -in @('missing_api_key', 'api_llm_api_key_env_missing') -or $normalizedExclusionReason -in @('missing_api_key', 'api_llm_api_key_env_missing')) { $reasons.Add('missing_api_key') | Out-Null }
    if ($TimedOut -or $normalizedStatus -in @('timeout', 'timed_out') -or $normalizedFailureClass -in @('timeout', 'timed_out') -or $normalizedExclusionReason -in @('timeout', 'timed_out')) { $reasons.Add('timeout') | Out-Null }
    if ($Crashed -or $normalizedStatus -in @('crash', 'crashed') -or $normalizedFailureClass -in @('crash', 'crashed') -or $normalizedExclusionReason -in @('crash', 'crashed')) { $reasons.Add('crash') | Out-Null }
    if ($InvalidOutput -or $normalizedStatus -in @('invalid_output', 'invalid_json', 'malformed') -or $normalizedFailureClass -in @('invalid_output', 'invalid_json', 'malformed') -or $normalizedExclusionReason -in @('invalid_output', 'invalid_json', 'malformed')) { $reasons.Add('invalid_output') | Out-Null }
    if ($Status -ne 'completed') { $reasons.Add('not_completed') | Out-Null }
    if (-not $RecordingPublishable) { $reasons.Add('recording_not_publishable') | Out-Null }
    if (-not $EndMarkerPresent) { $reasons.Add('missing_end_marker') | Out-Null }
    if (-not $PacketHashMatch) { $reasons.Add('packet_hash_mismatch') | Out-Null }
    if ($StdoutEmpty) { $reasons.Add('empty_stdout') | Out-Null }
    if ($Cli -match '(?i)Antigravity' -and $StdoutEmpty) { $reasons.Add('antigravity_empty_stdout') | Out-Null }

    return [pscustomobject]@{
        scoreable = ($reasons.Count -eq 0)
        reason    = if ($reasons.Count -eq 0) { '' } else { (($reasons.ToArray() | Select-Object -Unique) -join ';') }
    }
}

function Get-DeterministicAxisScore {
    param(
        [Parameter(Mandatory = $true)]$Command,
        [Parameter(Mandatory = $true)][bool]$Scoreable,
        [Parameter(Mandatory = $true)][string]$Axis
    )

    if (-not $Scoreable) { return '' }

    $scores = Get-ObjectProperty $Command 'scores' $null
    if ($null -ne $scores -and $scores.PSObject.Properties.Name -contains $Axis) {
        return [string](Get-ObjectProperty $scores $Axis '')
    }

    $deterministicScore = Get-ObjectProperty $Command 'deterministic_score' $null
    if ($null -ne $deterministicScore -and -not [string]::IsNullOrWhiteSpace([string]$deterministicScore)) {
        return [string]$deterministicScore
    }

    $passed = Get-ObjectProperty $Command 'hidden_tests_passed' $null
    $total = Get-ObjectProperty $Command 'hidden_tests_total' $null
    $passedInt = 0
    $totalInt = 0
    if ($null -ne $passed -and $null -ne $total -and [int]::TryParse([string]$passed, [ref]$passedInt) -and [int]::TryParse([string]$total, [ref]$totalInt) -and $totalInt -gt 0) {
        return [string][math]::Round(($passedInt / $totalInt) * 100, 2)
    }

    return '100'
}

$resolvedRunRoot = Resolve-LocalPath $RunRoot
$resolvedOutputDir = Resolve-LocalPath $OutputDir
$resolvedPackPath = Resolve-LocalPath $PackPath
$packResult = TryRead-JsonFile $resolvedPackPath
$pack = if ($packResult.ok) { $packResult.value } else { $null }

$axes = @('accuracy', 'review_findings', 'speed', 'parallelism', 'async_terminal', 'evidence_quality')
if ($null -ne $pack -and $null -ne $pack.scoring -and $null -ne $pack.scoring.axes) {
    $axes = @($pack.scoring.axes.PSObject.Properties.Name)
}
$allAxes = @($axes + @('overall'))
$runs = [System.Collections.Generic.List[object]]::new()

if (Test-Path -LiteralPath $resolvedRunRoot -PathType Container) {
    foreach ($dir in (Get-ChildItem -LiteralPath $resolvedRunRoot -Directory | Where-Object { $_.Name -ne 'summary' })) {
        $manifestResult = TryRead-JsonFile (Join-Path $dir.FullName 'manifest.json')
        if (-not $manifestResult.ok -or $null -eq $manifestResult.value) {
            $runs.Add([pscustomobject]@{
                run_id                = $dir.Name
                cli                   = 'unknown'
                model                 = 'provider-default'
                task_class            = 'unknown'
                status                = $manifestResult.error
                elapsed_seconds       = $null
                recording_status      = 'not_declared'
                recording_publishable = $false
                end_marker_present    = $false
                packet_hash_match     = $false
                stdout_empty          = $false
                operator_run          = $false
                scoreable             = $false
                score_exclusion       = $manifestResult.error
                axis_scores           = @{}
            }) | Out-Null
            continue
        }
        $manifest = $manifestResult.value

        $runIdValue = Get-ObjectProperty $manifest 'run_id' ''
        $taskClassValue = Get-ObjectProperty $manifest 'task_class' ''
        $recording = Get-ObjectProperty $manifest 'recording' $null
        $evidence = Get-ObjectProperty $manifest 'evidence' $null
        $runId = if (-not [string]::IsNullOrWhiteSpace([string]$runIdValue)) { [string]$runIdValue } else { $dir.Name }
        $taskClass = if (-not [string]::IsNullOrWhiteSpace([string]$taskClassValue)) { [string]$taskClassValue } else { 'unknown' }
        $recordingStatusValue = Get-ObjectProperty $recording 'status' ''
        $recordingStatus = if (-not [string]::IsNullOrWhiteSpace([string]$recordingStatusValue)) { [string]$recordingStatusValue } else { 'not_declared' }
        $recordingPublishable = $false
        $publishableValue = Get-ObjectProperty $recording 'publishable' $null
        if ($null -ne $publishableValue) {
            $recordingPublishable = [bool]$publishableValue
        }
        $manifestEndMarkerPresent = ConvertTo-StrictBool (Get-ObjectProperty $evidence 'end_marker_present' (Get-ObjectProperty $manifest 'end_marker_present' $null)) $false
        $manifestPacketHashMatch = ConvertTo-StrictBool (Get-ObjectProperty $evidence 'packet_hash_match' (Get-ObjectProperty $manifest 'packet_hash_match' $null)) $false

        $commands = [System.Collections.Generic.List[object]]::new()
        $commandsPath = Join-Path $dir.FullName 'commands.jsonl'
        if (Test-Path -LiteralPath $commandsPath -PathType Leaf) {
            foreach ($line in (Get-Content -LiteralPath $commandsPath -Encoding UTF8)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $commands.Add(($line | ConvertFrom-Json -Depth 80)) | Out-Null
                } catch {
                    $commands.Add([pscustomobject]@{ cli = 'unknown'; model = 'unknown'; status = 'invalid_json'; elapsed_seconds = $null }) | Out-Null
                }
            }
        }

        $activeWorkers = Get-ObjectProperty $manifest 'active_workers' @()
        if ($commands.Count -eq 0 -and $null -ne $activeWorkers) {
            $execution = Get-ObjectProperty $manifest 'execution' $null
            $executionStatus = Get-ObjectProperty $execution 'status' 'unknown'
            foreach ($worker in @($activeWorkers)) {
                $commands.Add([pscustomobject]@{
                    cli             = [string](Get-ObjectProperty $worker 'cli' 'unknown')
                    model           = [string](Get-ObjectProperty $worker 'display_model' 'provider-default')
                    status          = [string]$executionStatus
                    elapsed_seconds = $null
                }) | Out-Null
            }
        }

        foreach ($command in $commands) {
            $statusValue = Get-ObjectProperty $command 'status' ''
            $status = if (-not [string]::IsNullOrWhiteSpace([string]$statusValue)) { [string]$statusValue } else { 'unknown' }
            $cliValue = Get-ObjectProperty $command 'cli' ''
            $modelValue = Get-ObjectProperty $command 'model' ''
            $cli = if (-not [string]::IsNullOrWhiteSpace([string]$cliValue)) { [string]$cliValue } else { 'unknown' }
            $endMarkerPresent = ConvertTo-StrictBool (Get-ObjectProperty $command 'end_marker_present' $manifestEndMarkerPresent) $false
            $packetHashMatch = ConvertTo-StrictBool (Get-ObjectProperty $command 'packet_hash_match' $manifestPacketHashMatch) $false
            $stdoutEmpty = ConvertTo-StrictBool (Get-ObjectProperty $command 'stdout_empty' $null) $false
            $operatorRun = ConvertTo-StrictBool (Get-ObjectProperty $command 'operator_run' $false) $false
            $scoredValue = Get-ObjectProperty $command 'scored' $null
            if ($null -ne $scoredValue -and -not (ConvertTo-StrictBool $scoredValue $true)) {
                $operatorRun = $true
            }
            if ((Get-ObjectProperty $command 'role' '') -eq 'operator' -or (Get-ObjectProperty $command 'pane' '') -eq 'operator') {
                $operatorRun = $true
            }
            $decision = Get-ScoreabilityDecision `
                -Cli $cli `
                -Status $status `
                -RecordingPublishable $recordingPublishable `
                -EndMarkerPresent $endMarkerPresent `
                -PacketHashMatch $packetHashMatch `
                -StdoutEmpty $stdoutEmpty `
                -OperatorRun $operatorRun `
                -FailureClass ([string](Get-ObjectProperty $command 'failure_class' '')) `
                -ExclusionReason ([string](Get-ObjectProperty $command 'exclusion_reason' '')) `
                -MissingApiKey (ConvertTo-StrictBool (Get-ObjectProperty $command 'missing_api_key' $false) $false) `
                -TimedOut (ConvertTo-StrictBool (Get-ObjectProperty $command 'timed_out' $false) $false) `
                -Crashed (ConvertTo-StrictBool (Get-ObjectProperty $command 'crashed' $false) $false) `
                -InvalidOutput (ConvertTo-StrictBool (Get-ObjectProperty $command 'invalid_output' $false) $false)
            $axisScores = [ordered]@{}
            foreach ($axis in $allAxes) {
                $axisScores[$axis] = Get-DeterministicAxisScore -Command $command -Scoreable ([bool]$decision.scoreable) -Axis $axis
            }
            $runs.Add([pscustomobject]@{
                run_id                = $runId
                cli                   = $cli
                model                 = if (-not [string]::IsNullOrWhiteSpace([string]$modelValue)) { [string]$modelValue } else { 'provider-default' }
                task_class            = $taskClass
                status                = $status
                elapsed_seconds       = Get-ObjectProperty $command 'elapsed_seconds' $null
                recording_status      = $recordingStatus
                recording_publishable = $recordingPublishable
                end_marker_present    = $endMarkerPresent
                packet_hash_match     = $packetHashMatch
                stdout_empty          = $stdoutEmpty
                operator_run          = $operatorRun
                scoreable             = $decision.scoreable
                score_exclusion       = $decision.reason
                axis_scores           = $axisScores
            }) | Out-Null
        }
    }
}

New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null

$csvLines = [System.Collections.Generic.List[string]]::new()
$csvLines.Add('"run_id","cli","model","task_class","axis","score","verdict","recording_status","recording_publishable","score_exclusion"') | Out-Null
foreach ($run in $runs) {
    foreach ($axis in $allAxes) {
        $verdict = if ($run.scoreable) { 'scoreable' } elseif ($run.status -ne 'completed') { 'blocked' } else { 'evidence_incomplete' }
        $csvLines.Add((@(
            (ConvertTo-CsvCell $run.run_id),
            (ConvertTo-CsvCell $run.cli),
            (ConvertTo-CsvCell $run.model),
            (ConvertTo-CsvCell $run.task_class),
            (ConvertTo-CsvCell $axis),
            (ConvertTo-CsvCell $run.axis_scores[$axis]),
            (ConvertTo-CsvCell $verdict),
            (ConvertTo-CsvCell $run.recording_status),
            (ConvertTo-CsvCell $run.recording_publishable),
            (ConvertTo-CsvCell $run.score_exclusion)
        ) -join ',')) | Out-Null
    }
}
[System.IO.File]::WriteAllLines((Join-Path $resolvedOutputDir 'raw-score-matrix.csv'), $csvLines, [System.Text.UTF8Encoding]::new($false))

$profiles = @(
    $runs |
        Group-Object cli, model |
        ForEach-Object {
            $sample = $_.Group[0]
            [pscustomobject]@{
                cli              = $sample.cli
                model            = $sample.model
                run_count        = $_.Count
                scoreable_count  = @($_.Group | Where-Object { $_.scoreable }).Count
                task_classes     = @($_.Group | Select-Object -ExpandProperty task_class -Unique)
                evidence_runs    = @($_.Group | Select-Object -ExpandProperty run_id -Unique)
                blocked_count    = @($_.Group | Where-Object { $_.status -ne 'completed' }).Count
                incomplete_count = @($_.Group | Where-Object { $_.status -eq 'completed' -and -not $_.scoreable }).Count
            }
        }
)

[pscustomobject]@{
    version          = 1
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    run_count        = @($runs | Select-Object -ExpandProperty run_id -Unique).Count
    scoreable_runs   = @($runs | Where-Object { $_.scoreable } | Select-Object -ExpandProperty run_id -Unique).Count
    models           = @($profiles)
} | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $resolvedOutputDir 'model-evidence-profile.json') -Encoding UTF8

$fitLines = [System.Collections.Generic.List[string]]::new()
$fitLines.Add('# Model Task Fit') | Out-Null
$fitLines.Add('') | Out-Null
$fitLines.Add('| CLI | Model | Task classes | Fit | Confidence | Caveat | Evidence |') | Out-Null
$fitLines.Add('| --- | --- | --- | --- | --- | --- | --- |') | Out-Null
foreach ($profile in $profiles) {
    $fit = if ($profile.scoreable_count -ge 3) { 'candidate' } else { 'needs-more-evidence' }
    $confidence = if ($profile.scoreable_count -ge 9) { 'high' } elseif ($profile.scoreable_count -ge 3) { 'medium' } else { 'low' }
    $caveat = if ($profile.scoreable_count -lt 3) { 'No automatic worker assignment change; completed runs still need publishable recording evidence.' } else { 'Human review required before default policy changes.' }
    $fitLines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f
        (ConvertTo-SafeCell $profile.cli),
        (ConvertTo-SafeCell $profile.model),
        ((@($profile.task_classes) | ForEach-Object { ConvertTo-SafeCell $_ }) -join ', '),
        $fit,
        $confidence,
        $caveat,
        ((@($profile.evidence_runs) | Select-Object -First 8 | ForEach-Object { ConvertTo-SafeCell $_ }) -join ', ')
    )) | Out-Null
}
[System.IO.File]::WriteAllLines((Join-Path $resolvedOutputDir 'model-task-fit.md'), $fitLines, [System.Text.UTF8Encoding]::new($false))

$policyLines = [System.Collections.Generic.List[string]]::new()
$policyLines.Add('# Assignment Policy') | Out-Null
$policyLines.Add('') | Out-Null
$policyLines.Add('This file is generated from local bakeoff evidence. It is advisory until a human reviewer accepts the evidence packet.') | Out-Null
$policyLines.Add('') | Out-Null
foreach ($classGroup in ($runs | Group-Object task_class)) {
    $policyLines.Add("## $($classGroup.Name)") | Out-Null
    $policyLines.Add('') | Out-Null
    $scoreableByModel = @($classGroup.Group | Where-Object { $_.scoreable } | Group-Object cli, model | Sort-Object Count -Descending)
    if ($scoreableByModel.Count -eq 0) {
        $policyLines.Add('No automatic worker assignment change. The available runs are blocked or lack publishable recording evidence.') | Out-Null
    } else {
        $top = $scoreableByModel[0].Group[0]
        $policyLines.Add(("Candidate: {0} / {1}. Keep the current default until reviewer sign-off." -f (ConvertTo-SafeCell $top.cli), (ConvertTo-SafeCell $top.model))) | Out-Null
    }
    $policyLines.Add('') | Out-Null
}
[System.IO.File]::WriteAllLines((Join-Path $resolvedOutputDir 'assignment-policy.md'), $policyLines, [System.Text.UTF8Encoding]::new($false))

$result = [pscustomobject]@{
    version            = 1
    run_count          = @($runs | Select-Object -ExpandProperty run_id -Unique).Count
    worker_result_rows = $runs.Count
    scoreable_runs     = @($runs | Where-Object { $_.scoreable } | Select-Object -ExpandProperty run_id -Unique).Count
    output_dir         = $resolvedOutputDir
    outputs            = @('raw-score-matrix.csv', 'model-evidence-profile.json', 'model-task-fit.md', 'assignment-policy.md')
}

if ($Json) {
    $result | ConvertTo-Json -Depth 10
} else {
    Write-Host ("cli-bakeoff-summary wrote {0} files to {1}" -f $result.outputs.Count, $resolvedOutputDir)
}
