param(
    [string]$ProjectDir = (Get-Location).Path,
    [Parameter(Mandatory = $true)][string]$CasesPath,
    [string]$OutputDir = '',
    [string]$PackId = '',
    [int]$RunsPerCase = 5,
    [string]$ReviewModel = 'gpt-5.5',
    [int]$DefaultTimeoutSeconds = 3600,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $script:Utf8NoBom
$OutputEncoding = $script:Utf8NoBom

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][string]$Value
    )

    [System.IO.File]::WriteAllText($Path, [string]$Value, $script:Utf8NoBom)
}

function Write-BakeoffJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    Write-Utf8File -Path $Path -Value ($Value | ConvertTo-Json -Depth 64)
}

function ConvertTo-BakeoffSafeId {
    param(
        [AllowNull()][string]$Value,
        [string]$Fallback = 'case'
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = $Fallback
    }

    $safe = $text.Trim() -replace '[^A-Za-z0-9._-]', '-'
    $safe = $safe.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return $Fallback
    }

    return $safe
}

function Get-BakeoffArray {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    return @($Value)
}

function Get-BakeoffCaseValue {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Case.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }

    return $null
}

function Get-BakeoffCaseString {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [string[]]$Names,
        [string]$Default = ''
    )

    $value = Get-BakeoffCaseValue -Case $Case -Names $Names
    if ($null -eq $value) {
        return $Default
    }

    return [string]$value
}

function ConvertTo-BakeoffProjectRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDir,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $baseFullPath = [System.IO.Path]::GetFullPath($BaseDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $targetFullPath = [System.IO.Path]::GetFullPath($Path)
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if ($targetFullPath.StartsWith($baseFullPath + [System.IO.Path]::DirectorySeparatorChar, $comparison) -or
        $targetFullPath.StartsWith($baseFullPath + [System.IO.Path]::AltDirectorySeparatorChar, $comparison)) {
        return [System.IO.Path]::GetRelativePath($baseFullPath, $targetFullPath)
    }

    return [System.IO.Path]::GetFileName($targetFullPath)
}

function ConvertTo-BakeoffTaskPacket {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][string]$CaseId,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$BaseRef,
        [Parameter(Mandatory = $true)][string]$PublicPrompt,
        [object[]]$AllowedPaths,
        [object[]]$PublicChecks,
        [object[]]$SuccessCriteria
    )

    $lines = @(
        "# HarnessBench-style task packet: $CaseId",
        '',
        "Title: $Title",
        "Repository: $Repo",
        "Base ref: $BaseRef",
        '',
        '## Task',
        '',
        $PublicPrompt.Trim(),
        '',
        '## Allowed paths',
        ''
    )

    if ($AllowedPaths.Count -eq 0) {
        $lines += '- No explicit path limit was provided. Keep the change minimal.'
    } else {
        foreach ($path in $AllowedPaths) {
            $lines += "- $([string]$path)"
        }
    }

    $lines += @(
        '',
        '## Public checks',
        ''
    )

    if ($PublicChecks.Count -eq 0) {
        $lines += '- No public check was provided. Explain any local check you run.'
    } else {
        foreach ($check in $PublicChecks) {
            $lines += "- ``$([string]$check)``"
        }
    }

    $lines += @(
        '',
        '## Success criteria',
        ''
    )

    if ($SuccessCriteria.Count -eq 0) {
        $lines += '- The implementation should satisfy the observable user-facing behavior in the task.'
    } else {
        foreach ($criterion in $SuccessCriteria) {
            $lines += "- $([string]$criterion)"
        }
    }

    $lines += @(
        '',
        '## Output contract',
        '',
        '- Print `BAKEOFF_ROUND_A_BEGIN` before the work summary.',
        '- Print changed files, public checks, and unresolved risks.',
        '- Print `BAKEOFF_ROUND_A_END` as the final line after the final answer.',
        '- The run is invalid and cannot be scored if `BAKEOFF_ROUND_A_END` is omitted.',
        '- Treat the listed public checks as the required local verification for this task.',
        '- You may run narrower or broader checks while debugging, but do not treat unrelated failures outside the listed public checks as task failure unless your change caused them.',
        '- Do not ask for hidden tests or scorer-only files.',
        '- Do not modify the benchmark harness, hidden tests, or scoring scripts unless the task explicitly asks for that.',
        ''
    )

    return ($lines -join "`n") + "`n"
}

if ($RunsPerCase -lt 1) {
    throw 'RunsPerCase must be 1 or greater.'
}
if ($DefaultTimeoutSeconds -lt 60) {
    throw 'DefaultTimeoutSeconds must be at least 60.'
}

$resolvedProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
$resolvedCasesPath = (Resolve-Path -LiteralPath $CasesPath).Path
$casesSourcePath = ConvertTo-BakeoffProjectRelativePath -BaseDir $resolvedProjectDir -Path $resolvedCasesPath
$casesDocument = Get-Content -LiteralPath $resolvedCasesPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64

if ([string]::IsNullOrWhiteSpace($PackId)) {
    $documentPackId = [string]$casesDocument.suite_id
    if ([string]::IsNullOrWhiteSpace($documentPackId)) {
        $documentPackId = [string]$casesDocument.pack_id
    }
    if ([string]::IsNullOrWhiteSpace($documentPackId)) {
        $documentPackId = 'harnessbench-local'
    }
    $PackId = $documentPackId
}
$safePackId = ConvertTo-BakeoffSafeId -Value $PackId -Fallback 'harnessbench-local'

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path (Join-Path (Join-Path $resolvedProjectDir 'tasks') 'cli-bakeoff') $safePackId
}
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $resolvedProjectDir $OutputDir
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$resolvedOutputDir = (Resolve-Path -LiteralPath $OutputDir).Path

$cases = Get-BakeoffArray $casesDocument.cases
if ($cases.Count -eq 0) {
    $cases = Get-BakeoffArray $casesDocument.tasks
}
if ($cases.Count -eq 0) {
    throw 'CasesPath must define cases or tasks.'
}

$workers = Get-BakeoffArray $casesDocument.default_workers
if ($workers.Count -eq 0) {
    throw 'CasesPath must define default_workers.'
}

$taskEntries = @()
$hiddenFiles = @()
$matrixRows = @('case_id,repeat_index,task_id,recommended_run_id')
$caseIndex = 0
foreach ($case in $cases) {
    $caseIndex += 1
    $caseId = Get-BakeoffCaseString -Case $case -Names @('case_id', 'task_id', 'id') -Default ('HB-{0:000}' -f $caseIndex)
    $caseId = ConvertTo-BakeoffSafeId -Value $caseId -Fallback ('HB-{0:000}' -f $caseIndex)
    $title = Get-BakeoffCaseString -Case $case -Names @('title', 'name') -Default $caseId
    $repo = Get-BakeoffCaseString -Case $case -Names @('repo', 'repository', 'repository_url')
    $baseRef = Get-BakeoffCaseString -Case $case -Names @('base_ref', 'baseRef', 'base_commit', 'baseCommit')
    $publicPrompt = Get-BakeoffCaseString -Case $case -Names @('public_prompt', 'prompt', 'task_prompt', 'description')

    if ([string]::IsNullOrWhiteSpace($repo)) {
        throw "Case $caseId must define repo or repository."
    }
    if ([string]::IsNullOrWhiteSpace($baseRef)) {
        throw "Case $caseId must define base_ref."
    }
    if ([string]::IsNullOrWhiteSpace($publicPrompt)) {
        throw "Case $caseId must define public_prompt or prompt."
    }

    $allowedPaths = Get-BakeoffArray (Get-BakeoffCaseValue -Case $case -Names @('allowed_paths', 'allowedPaths'))
    $publicChecks = Get-BakeoffArray (Get-BakeoffCaseValue -Case $case -Names @('public_checks', 'publicChecks'))
    $hiddenChecks = Get-BakeoffArray (Get-BakeoffCaseValue -Case $case -Names @('hidden_checks', 'hiddenChecks'))
    $successCriteria = Get-BakeoffArray (Get-BakeoffCaseValue -Case $case -Names @('success_criteria', 'successCriteria'))
    if ($hiddenChecks.Count -eq 0) {
        throw "Case $caseId must define hidden_checks."
    }

    $packetName = "$caseId.md"
    $hiddenName = "$caseId.hidden-checks.json"
    $packetPath = Join-Path $resolvedOutputDir $packetName
    $hiddenPath = Join-Path $resolvedOutputDir $hiddenName

    $packetText = ConvertTo-BakeoffTaskPacket `
        -Case $case `
        -CaseId $caseId `
        -Title $title `
        -Repo $repo `
        -BaseRef $baseRef `
        -PublicPrompt $publicPrompt `
        -AllowedPaths $allowedPaths `
        -PublicChecks $publicChecks `
        -SuccessCriteria $successCriteria
    Write-Utf8File -Path $packetPath -Value $packetText

    $hiddenPayload = [ordered]@{
        version = 1
        case_id = $caseId
        scorer_only = $true
        note = 'Do not forward this file or its commands to candidate workers.'
        repo = $repo
        base_ref = $baseRef
        hidden_checks = @($hiddenChecks)
    }
    Write-BakeoffJson -Path $hiddenPath -Value $hiddenPayload
    $hiddenFiles += $hiddenName

    $attributes = [ordered]@{
        benchmark_style = 'harnessbench'
        repo = $repo
        base_ref = $baseRef
        runs_per_case = $RunsPerCase
        hidden_checks_path = $hiddenName
        public_checks = @($publicChecks)
        allowed_paths = @($allowedPaths)
        success_criteria = @($successCriteria)
    }

    $difficulty = Get-BakeoffCaseString -Case $case -Names @('difficulty', 'level')
    if (-not [string]::IsNullOrWhiteSpace($difficulty)) {
        $attributes['difficulty'] = $difficulty
    }

    $taskEntries += [ordered]@{
        task_id = $caseId
        title = $title
        task_class = 'real_repo_fix'
        packet_path = $packetName
        attributes = $attributes
    }

    for ($repeat = 1; $repeat -le $RunsPerCase; $repeat += 1) {
        $runId = "$safePackId-$caseId-r$repeat"
        $matrixRows += "$caseId,$repeat,$caseId,$runId"
    }
}

$pack = [ordered]@{
    version = 1
    pack_id = $safePackId
    methodology = 'harnessbench-style-real-repo-hidden-tests'
    source_cases_path = $casesSourcePath
    review_model = $ReviewModel
    default_timeout_seconds = $DefaultTimeoutSeconds
    runs_per_case = $RunsPerCase
    scoring = [ordered]@{
        pass_rule = 'hidden_core_and_regression_must_pass'
        axes = [ordered]@{
            hidden_core = 40
            hidden_regression = 25
            public_checks = 10
            review_findings = 15
            speed = 10
        }
        auxiliary_review = [ordered]@{
            model = $ReviewModel
            purpose = 'failure audit and quality control, not primary scoring'
        }
    }
    qc_gates = @(
        'same_task_packet_sha256_for_all_workers',
        'hidden_tests_not_in_prompt',
        'isolated_worktree_per_worker',
        'sanitized_steering_files',
        'preflight_all_pass',
        'n_repeats_per_condition',
        'scorer_only_hidden_checks'
    )
    default_workers = @($workers)
    tasks = @($taskEntries)
}

$packPath = Join-Path $resolvedOutputDir 'benchmark-pack.json'
$matrixPath = Join-Path $resolvedOutputDir 'run-matrix.csv'
$rubricPath = Join-Path $resolvedOutputDir 'scoring-rubric.md'
Write-BakeoffJson -Path $packPath -Value $pack
Write-Utf8File -Path $matrixPath -Value (($matrixRows -join "`n") + "`n")

$rubric = @(
    '# HarnessBench-style scoring rubric',
    '',
    "Pack: ``$safePackId``",
    '',
    '## Primary scoring',
    '',
    '- Hidden core checks are the main correctness signal.',
    '- Hidden regression checks guard surrounding behavior.',
    '- Public checks are recorded, but they do not replace hidden checks.',
    '- LLM review is a failure audit and quality-control step, not the primary judge.',
    '',
    '## QC gates',
    '',
    '- Every worker receives the same task packet hash.',
    '- Hidden check commands stay in `*.hidden-checks.json` and are not included in task packets.',
    '- Each worker uses an isolated worktree at the same base ref.',
    '- Steering files and local memories that could leak the answer are removed or neutralized before candidate runs.',
    '- Repeat each case the configured number of times before producing a model-fit ranking.',
    '',
    '## Output',
    '',
    '- Use `benchmark-pack.json` with `new-cli-bakeoff-benchmark-run.ps1` for recording runs.',
    '- Use `run-matrix.csv` to schedule repeated runs.',
    '- Use hidden check files only from the scorer process after worker output is complete.',
    ''
)
Write-Utf8File -Path $rubricPath -Value (($rubric -join "`n") + "`n")

$output = [ordered]@{
    pack_id = $safePackId
    output_dir = $resolvedOutputDir
    benchmark_pack = $packPath
    run_matrix = $matrixPath
    scoring_rubric = $rubricPath
    hidden_check_files = @($hiddenFiles)
    task_count = $taskEntries.Count
    worker_count = $workers.Count
    runs_per_case = $RunsPerCase
    planned_runs = $taskEntries.Count * $workers.Count * $RunsPerCase
}

if ($Json) {
    $output | ConvertTo-Json -Depth 8
} else {
    Write-Output "created HarnessBench-style CLI bakeoff pack: $packPath"
}
