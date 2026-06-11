param(
    [string]$ProjectDir = (Get-Location).Path,
    [string]$RunDir = '',
    [string]$OutputDir = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Get-BakeoffJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return $raw | ConvertFrom-Json -Depth 32
}

function Get-BakeoffNumber {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $number = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }

    return $null
}

function Get-BakeoffAverage {
    param([AllowNull()]$Values)

    $numbers = @($Values | ForEach-Object { Get-BakeoffNumber $_ } | Where-Object { $null -ne $_ })
    if ($numbers.Count -eq 0) {
        return $null
    }

    return [Math]::Round((($numbers | Measure-Object -Average).Average), 2)
}

function Get-BakeoffMedian {
    param([AllowNull()]$Values)

    $numbers = @($Values | ForEach-Object { Get-BakeoffNumber $_ } | Where-Object { $null -ne $_ } | Sort-Object)
    if ($numbers.Count -eq 0) {
        return $null
    }

    $middle = [int][Math]::Floor($numbers.Count / 2)
    if (($numbers.Count % 2) -eq 1) {
        return [Math]::Round([double]$numbers[$middle], 2)
    }

    return [Math]::Round(([double]$numbers[$middle - 1] + [double]$numbers[$middle]) / 2.0, 2)
}

function Format-BakeoffMarkdownCell {
    param([AllowNull()]$Value)

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }

    return (($text -replace '\|', '\|') -replace "`r?`n", '<br>')
}

function Get-BakeoffRate {
    param(
        [int]$Numerator,
        [int]$Denominator
    )

    if ($Denominator -le 0) {
        return $null
    }

    return [Math]::Round(($Numerator / [double]$Denominator) * 100.0, 1)
}

function Get-BakeoffSeverityCount {
    param(
        [AllowNull()]$Result,
        [string]$Severity
    )

    if ($null -eq $Result -or $null -eq $Result.review_counts) {
        return 0
    }

    $property = $Result.review_counts.PSObject.Properties[$Severity]
    if ($null -eq $property) {
        return 0
    }

    return [int]$property.Value
}

function Get-BakeoffOverallScore {
    param([AllowNull()]$Result)

    if ($null -eq $Result) {
        return $null
    }

    $overall = Get-BakeoffNumber $Result.scores.overall
    if ($null -ne $overall) {
        return $overall
    }

    $weights = [ordered]@{
        accuracy         = 30
        review_findings  = 20
        speed            = 15
        parallelism      = 15
        async_terminal   = 10
        evidence_quality = 10
    }

    $weighted = 0.0
    $totalWeight = 0.0
    foreach ($axis in $weights.Keys) {
        $score = Get-BakeoffNumber $Result.scores.$axis
        if ($null -eq $score) {
            continue
        }

        $weighted += ($score * $weights[$axis])
        $totalWeight += $weights[$axis]
    }

    if ($totalWeight -le 0) {
        return $null
    }

    return [Math]::Round(($weighted / $totalWeight), 2)
}

function Get-BakeoffFit {
    param(
        [AllowNull()][double]$AverageScore,
        [int]$RunCount,
        [int]$P0,
        [int]$P1
    )

    if ($null -eq $AverageScore) {
        return 'pending'
    }
    if ($P0 -gt 0 -or $AverageScore -lt 40) {
        return 'avoid'
    }
    if ($P1 -gt 1 -or $AverageScore -lt 65) {
        return 'conditional'
    }
    if ($RunCount -lt 2) {
        return 'conditional'
    }
    if ($AverageScore -ge 85 -and $P1 -eq 0) {
        return 'best'
    }
    return 'strong'
}

function Get-BakeoffConfidence {
    param(
        [int]$RunCount,
        [AllowNull()][double]$VarianceHint
    )

    if ($RunCount -ge 5 -and ($null -eq $VarianceHint -or $VarianceHint -le 12)) {
        return 'high'
    }
    if ($RunCount -ge 2) {
        return 'medium'
    }
    return 'low'
}

function Get-BakeoffFitRank {
    param([AllowNull()][string]$Fit)

    switch ($Fit) {
        'best' { return 0 }
        'strong' { return 1 }
        'conditional' { return 2 }
        'avoid' { return 3 }
        default { return 4 }
    }
}

function Get-BakeoffConfidenceRank {
    param([AllowNull()][string]$Confidence)

    switch ($Confidence) {
        'high' { return 0 }
        'medium' { return 1 }
        'low' { return 2 }
        default { return 3 }
    }
}

$resolvedProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
$runRoot = Join-Path (Join-Path (Join-Path $resolvedProjectDir '.winsmux') 'evidence') 'cli-bakeoff'
if (-not (Test-Path -LiteralPath $runRoot -PathType Container)) {
    throw "CLI bakeoff evidence directory does not exist: $runRoot"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = if ([string]::IsNullOrWhiteSpace($RunDir)) {
        Join-Path $runRoot 'summary'
    } else {
        Join-Path (Resolve-Path -LiteralPath $RunDir).Path 'summary'
    }
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$runDirectories = if ([string]::IsNullOrWhiteSpace($RunDir)) {
    @(Get-ChildItem -LiteralPath $runRoot -Directory | Where-Object {
        -not [string]::Equals($_.Name, 'summary', [System.StringComparison]::OrdinalIgnoreCase)
    })
} else {
    @(Get-Item -LiteralPath (Resolve-Path -LiteralPath $RunDir).Path)
}

$runs = @()
$workerRuns = @()
foreach ($runDirInfo in $runDirectories) {
    $manifest = Get-BakeoffJsonFile -Path (Join-Path $runDirInfo.FullName 'manifest.json')
    $result = Get-BakeoffJsonFile -Path (Join-Path $runDirInfo.FullName 'result.json')
    $recording = Get-BakeoffJsonFile -Path (Join-Path $runDirInfo.FullName 'screen-recording.json')
    if ($null -eq $manifest -or $null -eq $result) {
        continue
    }

    $runs += [PSCustomObject]@{
        RunId                = [string]$manifest.run_id
        Cli                  = [string]$manifest.cli
        Model                = [string]$manifest.model
        Effort               = [string]$manifest.effort
        TaskClass            = [string]$manifest.task_class
        Overall              = Get-BakeoffOverallScore -Result $result
        Accuracy             = Get-BakeoffNumber $result.scores.accuracy
        ReviewFindings       = Get-BakeoffNumber $result.scores.review_findings
        Speed                = Get-BakeoffNumber $result.scores.speed
        Parallelism          = Get-BakeoffNumber $result.scores.parallelism
        AsyncTerminal        = Get-BakeoffNumber $result.scores.async_terminal
        EvidenceQuality      = Get-BakeoffNumber $result.scores.evidence_quality
        Quality              = Get-BakeoffNumber $result.capability_vector.quality
        CapabilityEvidence   = Get-BakeoffNumber $result.capability_vector.evidence
        Autonomy             = Get-BakeoffNumber $result.capability_vector.autonomy
        TerminalOperation    = Get-BakeoffNumber $result.capability_vector.terminal_operation
        Safety               = Get-BakeoffNumber $result.capability_vector.safety
        Continuity           = Get-BakeoffNumber $result.capability_vector.continuity
        P0                   = Get-BakeoffSeverityCount -Result $result -Severity 'P0'
        P1                   = Get-BakeoffSeverityCount -Result $result -Severity 'P1'
        P2                   = Get-BakeoffSeverityCount -Result $result -Severity 'P2'
        P3                   = Get-BakeoffSeverityCount -Result $result -Severity 'P3'
        Verdict              = [string]$result.verdict
        RecordingStatus      = if ($null -eq $recording) { '' } else { [string]$recording.status }
        RecordingPublishable = if ($null -eq $recording) { $false } else { [bool]$recording.publishable }
        EvidenceDir          = [string]$runDirInfo.FullName
    }

    if ($null -ne $manifest.active_workers) {
        foreach ($worker in @($manifest.active_workers)) {
            $paneId = [string]$worker.pane
            $safePaneId = if ([string]::IsNullOrWhiteSpace($paneId)) {
                'pane'
            } else {
                (($paneId.Trim() -replace '[^A-Za-z0-9._-]', '-').Trim('.'))
            }
            if ([string]::IsNullOrWhiteSpace($safePaneId)) {
                $safePaneId = 'pane'
            }

            $resultFileName = "$safePaneId-result.json"
            $workerExecutions = $manifest.PSObject.Properties['worker_executions']
            if ($null -ne $workerExecutions -and $null -ne $workerExecutions.Value) {
                $execution = $workerExecutions.Value.PSObject.Properties[$paneId]
                if ($null -ne $execution -and -not [string]::IsNullOrWhiteSpace([string]$execution.Value.pane_result)) {
                    $resultFileName = [string]$execution.Value.pane_result
                }
            }

            $workerResult = Get-BakeoffJsonFile -Path (Join-Path $runDirInfo.FullName $resultFileName)
            $workerScores = if ($null -eq $workerResult) { $null } else { $workerResult.scores }
            $workerRuns += [PSCustomObject]@{
                RunId           = [string]$manifest.run_id
                PaneId          = $paneId
                Cli             = [string]$worker.cli
                Model           = [string]$worker.display_model
                ModelArg        = [string]$worker.model_arg
                Effort          = [string]$worker.effort
                TaskClass       = [string]$manifest.task_class
                Status          = if ($null -eq $workerResult) { 'pending' } else { [string]$workerResult.status }
                BlockedReason   = if ($null -eq $workerResult) { '' } else { [string]$workerResult.blocked_reason }
                ElapsedSeconds  = if ($null -eq $workerResult) { $null } else { Get-BakeoffNumber $workerResult.elapsed_seconds }
                TimedOut        = if ($null -eq $workerResult) { $false } else { [bool]$workerResult.timed_out }
                ExitCode        = if ($null -eq $workerResult) { $null } else { $workerResult.exit_code }
                Overall         = if ($null -eq $workerScores) { $null } else { Get-BakeoffOverallScore -Result $workerResult }
                Accuracy        = if ($null -eq $workerScores) { $null } else { Get-BakeoffNumber $workerScores.accuracy }
                ReviewFindings  = if ($null -eq $workerScores) { $null } else { Get-BakeoffNumber $workerScores.review_findings }
                Speed           = if ($null -eq $workerScores) { $null } else { Get-BakeoffNumber $workerScores.speed }
                Parallelism     = if ($null -eq $workerScores) { $null } else { Get-BakeoffNumber $workerScores.parallelism }
                AsyncTerminal   = if ($null -eq $workerScores) { $null } else { Get-BakeoffNumber $workerScores.async_terminal }
                EvidenceQuality = if ($null -eq $workerScores) { $null } else { Get-BakeoffNumber $workerScores.evidence_quality }
                Verdict         = if ($null -eq $workerResult) { 'pending' } else { [string]$workerResult.verdict }
                EvidenceDir     = [string]$runDirInfo.FullName
            }
        }
    }
}

$csvRows = @()
foreach ($run in $runs) {
    foreach ($axis in @('Accuracy', 'ReviewFindings', 'Speed', 'Parallelism', 'AsyncTerminal', 'EvidenceQuality', 'Overall')) {
        $csvRows += [PSCustomObject]@{
            run_id                = $run.RunId
            cli                   = $run.Cli
            model                 = $run.Model
            task_class            = $run.TaskClass
            axis                  = $axis
            score                 = $run.$axis
            p0                    = $run.P0
            p1                    = $run.P1
            p2                    = $run.P2
            p3                    = $run.P3
            verdict               = $run.Verdict
            recording_status      = $run.RecordingStatus
            recording_publishable = $run.RecordingPublishable
            evidence_dir          = $run.EvidenceDir
        }
    }
}

$rawScorePath = Join-Path $OutputDir 'raw-score-matrix.csv'
$csvRows | Export-Csv -LiteralPath $rawScorePath -NoTypeInformation -Encoding UTF8

$conditionRows = @()
$workerSource = if (@($workerRuns).Count -gt 0) { @($workerRuns) } else { @($runs) }
foreach ($group in $workerSource | Group-Object Cli, Model, Effort, TaskClass) {
    $items = @($group.Group)
    if ($items.Count -eq 0) {
        continue
    }

    $started = @($items | Where-Object { [string]$_.Status -ne 'pending' }).Count
    $completed = @($items | Where-Object { [string]$_.Status -eq 'completed' }).Count
    $pending = @($items | Where-Object { [string]$_.Status -eq 'pending' }).Count
    $timeouts = @($items | Where-Object { [bool]$_.TimedOut -or [string]$_.BlockedReason -eq 'timeout' }).Count
    $passItems = @($items | Where-Object { [string]$_.Verdict -in @('pass', 'passed') }).Count
    $passDenominator = @($items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Verdict) -and [string]$_.Verdict -ne 'pending' }).Count
    $conditionRows += [PSCustomObject]@{
        Cli                  = [string]$items[0].Cli
        Model                = [string]$items[0].Model
        Effort               = [string]$items[0].Effort
        TaskClass            = [string]$items[0].TaskClass
        RunCount             = $items.Count
        Started              = $started
        Pending              = $pending
        Completed            = $completed
        CompletionRate       = Get-BakeoffRate -Numerator $completed -Denominator $started
        PassCount            = $passItems
        PassRate             = Get-BakeoffRate -Numerator $passItems -Denominator $passDenominator
        MedianWallTimeSec    = Get-BakeoffMedian ($items | ForEach-Object { $_.ElapsedSeconds })
        TimeoutCount         = $timeouts
        AverageOverall       = Get-BakeoffAverage ($items | ForEach-Object { $_.Overall })
        AverageAccuracy      = Get-BakeoffAverage ($items | ForEach-Object { $_.Accuracy })
        AverageReview        = Get-BakeoffAverage ($items | ForEach-Object { $_.ReviewFindings })
        AverageSpeed         = Get-BakeoffAverage ($items | ForEach-Object { $_.Speed })
        AverageParallelism   = Get-BakeoffAverage ($items | ForEach-Object { $_.Parallelism })
        AverageAsyncTerminal = Get-BakeoffAverage ($items | ForEach-Object { $_.AsyncTerminal })
        AverageEvidence      = Get-BakeoffAverage ($items | ForEach-Object { $_.EvidenceQuality })
        EvidenceRuns         = (@($items | ForEach-Object { $_.RunId }) | Sort-Object -Unique) -join ', '
    }
}

$chartDataPath = Join-Path $OutputDir 'chart-data.json'
([ordered]@{
    version          = 1
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    methodology      = [ordered]@{
        references = @(
            'https://nyosegawa.com/posts/harness-bench/',
            'https://nyosegawa.com/posts/harness-bench-antigravity-composer-25/'
        )
        note = 'Use hidden or deterministic checks for primary scoring; use LLM review for failure audit and explanation.'
    }
    conditions       = @($conditionRows)
    charts           = @(
        [ordered]@{ id = 'completion_rate_bar'; title = 'Completion or pass rate by condition'; x = 'condition'; y = 'completion_rate'; source = 'conditions' },
        [ordered]@{ id = 'median_wall_time_bar'; title = 'Median wall time by condition'; x = 'condition'; y = 'median_wall_time_sec'; source = 'conditions' },
        [ordered]@{ id = 'speed_quality_scatter'; title = 'Speed-quality tradeoff'; x = 'median_wall_time_sec'; y = 'average_overall'; source = 'conditions' },
        [ordered]@{ id = 'capability_radar'; title = 'Capability vector by condition'; axes = @('accuracy', 'review_findings', 'speed', 'parallelism', 'async_terminal', 'evidence_quality'); source = 'conditions' },
        [ordered]@{ id = 'task_class_heatmap'; title = 'Task-class fit heatmap'; x = 'condition'; y = 'task_class'; color = 'average_overall'; source = 'conditions' }
    )
}) | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $chartDataPath -Encoding UTF8

$profileModels = [ordered]@{}
$fitRows = @()
foreach ($group in $runs | Group-Object Cli, Model, TaskClass) {
    $items = @($group.Group)
    if ($items.Count -eq 0) {
        continue
    }

    $cli = [string]$items[0].Cli
    $model = [string]$items[0].Model
    $taskClass = [string]$items[0].TaskClass
    $profileKey = "$cli`t$model"
    $averageOverall = Get-BakeoffAverage ($items | ForEach-Object { $_.Overall })
    $p0 = [int](($items | Measure-Object -Property P0 -Sum).Sum)
    $p1 = [int](($items | Measure-Object -Property P1 -Sum).Sum)
    $fit = Get-BakeoffFit -AverageScore $averageOverall -RunCount $items.Count -P0 $p0 -P1 $p1
    $confidence = Get-BakeoffConfidence -RunCount $items.Count -VarianceHint $null
    $evidenceRuns = @($items | ForEach-Object { $_.RunId })
    $caveat = if ($fit -eq 'pending') {
        'Scores are incomplete.'
    } elseif ($confidence -eq 'low') {
        'Only one run is available; treat this as a hypothesis.'
    } elseif ($p0 -gt 0 -or $p1 -gt 0) {
        'Review findings require cross-family review before assignment.'
    } else {
        ''
    }

    $fitRows += [PSCustomObject]@{
        Cli        = $cli
        Model      = $model
        TaskClass  = $taskClass
        Fit        = $fit
        Confidence = $confidence
        Caveat     = $caveat
        Evidence   = ($evidenceRuns -join ', ')
    }

    if (-not $profileModels.Contains($profileKey)) {
        $profileModels[$profileKey] = [ordered]@{
            cli            = $cli
            model          = $model
            run_count      = 0
            task_classes   = @()
            evidence_runs  = @()
            scores_average = [ordered]@{}
            capability_average = [ordered]@{}
        }
    }

    $profileModels[$profileKey].run_count += $items.Count
    $profileModels[$profileKey].task_classes = @($profileModels[$profileKey].task_classes + $taskClass | Sort-Object -Unique)
    $profileModels[$profileKey].evidence_runs = @($profileModels[$profileKey].evidence_runs + $evidenceRuns | Sort-Object -Unique)
}

foreach ($profileKey in @($profileModels.Keys)) {
    $profile = $profileModels[$profileKey]
    $modelRuns = @($runs | Where-Object { $_.Cli -eq $profile.cli -and $_.Model -eq $profile.model })
    $profileModels[$profileKey].scores_average = [ordered]@{
        accuracy         = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Accuracy })
        review_findings  = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.ReviewFindings })
        speed            = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Speed })
        parallelism      = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Parallelism })
        async_terminal   = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.AsyncTerminal })
        evidence_quality = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.EvidenceQuality })
        overall          = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Overall })
    }
    $profileModels[$profileKey].capability_average = [ordered]@{
        quality            = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Quality })
        speed              = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Speed })
        autonomy           = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Autonomy })
        parallelism        = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Parallelism })
        terminal_operation = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.TerminalOperation })
        evidence           = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.CapabilityEvidence })
        safety             = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Safety })
        continuity         = Get-BakeoffAverage ($modelRuns | ForEach-Object { $_.Continuity })
    }
}

$profilePath = Join-Path $OutputDir 'model-evidence-profile.json'
([ordered]@{
    version      = 1
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    run_count    = @($runs).Count
    models       = @($profileModels.Values)
}) | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $profilePath -Encoding UTF8

$fitPath = Join-Path $OutputDir 'model-task-fit.md'
$fitLines = @(
    '# Model Task Fit',
    '',
    '| CLI | Model | Task class | Fit | Confidence | Caveat | Evidence |',
    '| --- | --- | --- | --- | --- | --- | --- |'
)
foreach ($row in $fitRows | Sort-Object Cli, Model, TaskClass) {
    $fitLines += "| $($row.Cli) | $($row.Model) | $($row.TaskClass) | $($row.Fit) | $($row.Confidence) | $($row.Caveat) | $($row.Evidence) |"
}
if ($fitRows.Count -eq 0) {
    $fitLines += '|  |  |  | pending | low | No scored runs found. |  |'
}
$fitLines | Set-Content -LiteralPath $fitPath -Encoding UTF8

$assignmentPath = Join-Path $OutputDir 'assignment-policy.md'
$assignmentLines = @(
    '# Assignment Policy',
    '',
    'Use this as a generated starting point. Human review remains required before changing the default worker layout.',
    ''
)
foreach ($taskGroup in $fitRows | Group-Object TaskClass | Sort-Object Name) {
    $best = @(
        $taskGroup.Group |
            Where-Object { $_.Fit -in @('best', 'strong') } |
            Sort-Object `
                @{ Expression = { Get-BakeoffFitRank -Fit $_.Fit }; Descending = $false },
                @{ Expression = { Get-BakeoffConfidenceRank -Confidence $_.Confidence }; Descending = $false },
                Cli,
                Model |
            Select-Object -First 1
    )
    $assignmentLines += "## $($taskGroup.Name)"
    if ($best.Count -eq 0) {
        $assignmentLines += ''
        $assignmentLines += 'No model has enough evidence for an automatic recommendation.'
        $assignmentLines += ''
        continue
    }
    $assignmentLines += ''
    $assignmentLines += "- Recommended CLI/model: $($best[0].Cli) / $($best[0].Model)"
    $assignmentLines += "- Fit: $($best[0].Fit)"
    $assignmentLines += "- Confidence: $($best[0].Confidence)"
    $assignmentLines += "- Evidence: $($best[0].Evidence)"
    if (-not [string]::IsNullOrWhiteSpace($best[0].Caveat)) {
        $assignmentLines += "- Caveat: $($best[0].Caveat)"
    }
    $assignmentLines += ''
}
$assignmentLines | Set-Content -LiteralPath $assignmentPath -Encoding UTF8

$articleReportPath = Join-Path $OutputDir 'article-report.md'
$conditionTableLines = @(
    '| CLI | Model | Effort | Task class | Started | Pending | Completed | Completion rate | Pass | Pass rate | Median wall time | Timeout | Avg overall |',
    '| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |'
)
foreach ($row in $conditionRows | Sort-Object TaskClass, Cli, Model, Effort) {
    $completionRate = if ($null -eq $row.CompletionRate) { '' } else { "$($row.CompletionRate)%" }
    $passRate = if ($null -eq $row.PassRate) { '' } else { "$($row.PassRate)%" }
    $conditionTableLines += "| $(Format-BakeoffMarkdownCell $row.Cli) | $(Format-BakeoffMarkdownCell $row.Model) | $(Format-BakeoffMarkdownCell $row.Effort) | $(Format-BakeoffMarkdownCell $row.TaskClass) | $($row.Started)/$($row.RunCount) | $($row.Pending) | $($row.Completed) | $completionRate | $($row.PassCount) | $passRate | $($row.MedianWallTimeSec) | $($row.TimeoutCount) | $($row.AverageOverall) |"
}
if ($conditionRows.Count -eq 0) {
    $conditionTableLines += '|  |  |  |  | 0/0 | 0 | 0 |  | 0 |  |  |  |  |'
}

$chartPromptPath = Join-Path $OutputDir 'gpt-image-2-chart-prompts.md'
$articleLines = @(
    '# winsmux CLI Bakeoff Report',
    '',
    '## What Was Evaluated',
    '',
    'This report compares CLI harness and model conditions inside winsmux worker panes. The primary unit is not only the model; it is the combination of CLI, model, effort, permissions, timeout behavior, terminal handling, and evidence quality.',
    '',
    '## Methodology',
    '',
    '- Every candidate receives the same saved `task-packet.md`.',
    '- `preflight.json` must pass before a recorded run starts.',
    '- Deterministic checks and hidden-style assertions are preferred for primary scoring.',
    '- `gpt-5.5` review is used for failure audit, quality control, and explanation, not as the only score source.',
    '- Completion, timeout, wall time, review findings, evidence quality, and task-class fit are reported separately.',
    '',
    '## Conditions And Results',
    ''
) + $conditionTableLines + @(
    '',
    '## How To Read The Result',
    '',
    'Small differences should be treated as directional until the task count is large enough. A condition can be useful even when it is not the top scorer, if it has a better speed-to-quality tradeoff or produces cleaner evidence for winsmux operation.',
    '',
    '## Chart Outputs',
    '',
    ('- Chart data: `' + $chartDataPath + '`'),
    ('- GPT image 2.0 prompts: `' + $chartPromptPath + '`'),
    '',
    'Recommended charts:',
    '',
    '- Completion or pass rate by condition.',
    '- Median wall time by condition.',
    '- Speed-quality scatter plot.',
    '- Capability radar chart.',
    '- Task-class fit heatmap.',
    '',
    '## References',
    '',
    '- https://nyosegawa.com/posts/harness-bench/',
    '- https://nyosegawa.com/posts/harness-bench-antigravity-composer-25/',
    ''
)
$articleLines | Set-Content -LiteralPath $articleReportPath -Encoding UTF8

$chartPromptLines = @(
    '# GPT image 2.0 Chart Prompts',
    '',
    'Use GPT image 2.0 for every final chart image. Use the data in `chart-data.json`; do not invent scores, pass counts, or wall times.',
    '',
    '## Visual Direction',
    '',
    'Create a polished benchmark-report visual style: clean white or deep charcoal background, precise gridlines, high-contrast labels, readable axis titles, and restrained accent colors. The chart should look suitable for a technical blog post and a product demo slide.',
    '',
    '## Prompt: Pass Or Completion Rate',
    '',
    'Use GPT image 2.0 to create a high-quality horizontal bar chart from `chart-data.json`. Show each condition as `CLI / Model / Effort`. Plot completion rate only for started runs, or pass rate when pass data is available. Show pending runs as a separate neutral badge, not as failures. Sort descending. Include counts next to each bar. Add a small footnote: "Small differences are directional unless the task count is large enough."',
    '',
    '## Prompt: Median Wall Time',
    '',
    'Use GPT image 2.0 to create a high-quality median wall-time chart from `chart-data.json`. Show minutes or seconds consistently. Highlight the fastest condition and mark timeout count as a small badge. Keep labels readable at 16:9 and 4:3 crops.',
    '',
    '## Prompt: Speed-Quality Scatter',
    '',
    'Use GPT image 2.0 to create a high-quality scatter plot from `chart-data.json`. X axis is median wall time; Y axis is average overall score, or completion rate if overall score is unavailable. Place the best speed-quality balance in the upper-left region. Label every point directly.',
    '',
    '## Prompt: Capability Radar',
    '',
    'Use GPT image 2.0 to create a high-quality radar chart for accuracy, review findings, speed, parallelism, async terminal, and evidence quality. Use one translucent polygon per condition. Avoid clutter; if more than five conditions exist, split into two panels.',
    '',
    '## Prompt: Task-Class Heatmap',
    '',
    'Use GPT image 2.0 to create a high-quality heatmap from `chart-data.json`. Rows are task classes. Columns are conditions. Color is average overall score, or completion rate if score is unavailable. Include a legend and explain missing values as "not enough scored runs".',
    ''
)
$chartPromptLines | Set-Content -LiteralPath $chartPromptPath -Encoding UTF8

$output = [ordered]@{
    run_count = @($runs).Count
    output_dir = (Resolve-Path -LiteralPath $OutputDir).Path
    raw_score_matrix = $rawScorePath
    chart_data = $chartDataPath
    article_report = $articleReportPath
    gpt_image_2_chart_prompts = $chartPromptPath
    model_task_fit = $fitPath
    assignment_policy = $assignmentPath
    model_evidence_profile = $profilePath
}

if ($Json) {
    $output | ConvertTo-Json -Depth 8
} else {
    Write-Output "summarized CLI bakeoff runs: $($output.output_dir)"
}
