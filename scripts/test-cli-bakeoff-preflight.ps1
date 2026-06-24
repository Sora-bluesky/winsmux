[CmdletBinding()]
param(
    [string]$PackPath = 'tasks/cli-bakeoff/v1/benchmark-pack.json',
    [string]$TaskRoot = '',
    [string]$RunDir = '',
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

function ConvertTo-SafeDetail {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $text = $text -replace [regex]::Escape($RepoRoot), '<repo>'
    $text = $text -replace '[A-Za-z]:\\[^,"\r\n]+', '<local-path>'
    return $text
}

function Test-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    return $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + [System.IO.Path]::AltDirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Pass,
        [string]$Detail = ''
    )
    $script:checks.Add([pscustomobject]@{ name = $Name; pass = $Pass; detail = (ConvertTo-SafeDetail $Detail) }) | Out-Null
}

$checks = [System.Collections.Generic.List[object]]::new()
$resolvedPackPath = Resolve-LocalPath $PackPath
$resolvedTaskRoot = if ([string]::IsNullOrWhiteSpace($TaskRoot)) {
    Split-Path $resolvedPackPath -Parent
} else {
    Resolve-LocalPath $TaskRoot
}

Add-Check 'benchmark pack exists' (Test-Path -LiteralPath $resolvedPackPath -PathType Leaf) $resolvedPackPath

$pack = $null
if (Test-Path -LiteralPath $resolvedPackPath -PathType Leaf) {
    $pack = Get-Content -LiteralPath $resolvedPackPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 40
}

if ($null -ne $pack) {
    Add-Check 'benchmark pack version is 1' ([int]$pack.version -eq 1) "version=$($pack.version)"
    Add-Check 'pack id is present' (-not [string]::IsNullOrWhiteSpace([string]$pack.pack_id)) ([string]$pack.pack_id)

    foreach ($axis in @('accuracy', 'review_findings', 'speed', 'parallelism', 'async_terminal', 'evidence_quality')) {
        $hasAxis = $null -ne $pack.scoring -and $null -ne $pack.scoring.axes -and ($pack.scoring.axes.PSObject.Properties.Name -contains $axis)
        Add-Check "scoring axis $axis" $hasAxis
    }

    $requiredGates = @(
        'same_task_packet_sha256_for_all_workers',
        'same_timeout_for_all_workers',
        'preflight_all_pass_before_recording',
        'desktop_app_screen_recording_required',
        'non_completed_worker_results_excluded_from_scoring',
        'antigravity_empty_stdout_excluded_from_machine_scoring',
        'harness_bench_27_tasks_required',
        'hidden_tests_required',
        'sanitized_workspace_required',
        'operator_rows_excluded_from_scoring',
        'missing_key_timeout_crash_empty_stdout_invalid_output_excluded_from_scoring'
    )
    $qcGates = @($pack.qc_gates)
    foreach ($gate in $requiredGates) {
        Add-Check "qc gate $gate" ($qcGates -contains $gate)
    }

    $workers = @($pack.default_workers)
    Add-Check 'Claude worker profile exists' (@($workers | Where-Object { $_.cli -eq 'Claude Code' }).Count -ge 1)
    Add-Check 'Codex worker profile exists' (@($workers | Where-Object { $_.cli -eq 'Codex' }).Count -ge 1)
    Add-Check 'Codex worker uses GPT-5.5 High canonical scenario' (@($workers | Where-Object {
        ($_.PSObject.Properties.Name -contains 'cli') -and
        ($_.PSObject.Properties.Name -contains 'model') -and
        ($_.PSObject.Properties.Name -contains 'effort') -and
        $_.cli -eq 'Codex' -and
        $_.model -eq 'gpt-5.5' -and
        $_.effort -eq 'high'
    }).Count -ge 1)
    Add-Check 'Codex GPT-5.5 worker does not use lower effort' (@($workers | Where-Object {
        ($_.PSObject.Properties.Name -contains 'cli') -and
        ($_.PSObject.Properties.Name -contains 'model') -and
        ($_.PSObject.Properties.Name -contains 'effort') -and
        $_.cli -eq 'Codex' -and
        $_.model -eq 'gpt-5.5' -and
        $_.effort -ne 'high'
    }).Count -eq 0)
    Add-Check 'Antigravity worker profile exists' (@($workers | Where-Object { $_.cli -eq 'Antigravity CLI' }).Count -ge 1)
    Add-Check 'OpenRouter Kimi worker profile exists' (@($workers | Where-Object {
        ($_.PSObject.Properties.Name -contains 'agent') -and
        ($_.PSObject.Properties.Name -contains 'model') -and
        ($_.PSObject.Properties.Name -contains 'worker_backend') -and
        $_.agent -eq 'openrouter' -and
        $_.model -eq 'moonshotai/kimi-k2.7-code' -and
        $_.worker_backend -eq 'api_llm'
    }).Count -ge 1)
    Add-Check 'OpenRouter GLM worker profile exists' (@($workers | Where-Object {
        ($_.PSObject.Properties.Name -contains 'agent') -and
        ($_.PSObject.Properties.Name -contains 'model') -and
        ($_.PSObject.Properties.Name -contains 'worker_backend') -and
        $_.agent -eq 'openrouter' -and
        $_.model -eq 'z-ai/glm-5.2' -and
        $_.worker_backend -eq 'api_llm'
    }).Count -ge 1)
    Add-Check 'OpenRouter workers use public env name' (@($workers | Where-Object {
        ($_.PSObject.Properties.Name -contains 'agent') -and
        $_.agent -eq 'openrouter' -and
        (-not ($_.PSObject.Properties.Name -contains 'required_env') -or $_.required_env -ne 'OPENROUTER_API_KEY')
    }).Count -eq 0)

    $operator = $pack.operator
    Add-Check 'operator role is declared' ($null -ne $operator)
    Add-Check 'operator is not scored' ($null -ne $operator -and -not [bool]$operator.scored)

    $workspacePolicy = $pack.workspace_policy
    Add-Check 'sanitized workspace policy exists' ($null -ne $workspacePolicy -and [bool]$workspacePolicy.sanitized_workspace_required)
    Add-Check 'same workspace conditions required' ($null -ne $workspacePolicy -and [bool]$workspacePolicy.same_workspace_conditions_for_all_workers)
    Add-Check 'default timeout is 3600 seconds' ([int]$pack.default_timeout_seconds -eq 3600) "timeout=$($pack.default_timeout_seconds)"

    $tasks = @($pack.tasks)
    $minimumTaskCount = [int]$pack.minimum_task_count_for_directional_findings
    Add-Check 'minimum directional task count is met' ($tasks.Count -ge $minimumTaskCount) "$($tasks.Count)/$minimumTaskCount"
    Add-Check 'official Harness Bench task count is met' ($tasks.Count -eq [int]$pack.official_task_count_target -and [int]$pack.official_task_count_target -eq 27) "$($tasks.Count)/$($pack.official_task_count_target)"

    foreach ($task in $tasks) {
        $taskId = [string]$task.task_id
        $packetPath = [string]$task.packet_path
        $packet = [System.IO.Path]::GetFullPath((Join-Path $resolvedTaskRoot $packetPath))
        $packetInsideRoot = Test-PathInsideRoot -Path $packet -Root $resolvedTaskRoot
        Add-Check "packet path stays inside task root $taskId" $packetInsideRoot $packetPath
        Add-Check "packet exists $taskId" ($packetInsideRoot -and (Test-Path -LiteralPath $packet -PathType Leaf)) $packetPath
        Add-Check "task class exists $taskId" (-not [string]::IsNullOrWhiteSpace([string]$task.task_class))
        Add-Check "hidden checks exist $taskId" (@($task.hidden_check_categories).Count -gt 0)
        Add-Check "hidden test contract exists $taskId" ($null -ne $task.hidden_test -and -not [string]::IsNullOrWhiteSpace([string]$task.hidden_test.result_schema))
        Add-Check "task timeout is 3600 seconds $taskId" ([int]$task.timeout_seconds -eq 3600)
        Add-Check "task requires sanitized workspace $taskId" ([bool]$task.sanitized_workspace_required)

        if ($packetInsideRoot -and (Test-Path -LiteralPath $packet -PathType Leaf)) {
            $packetText = Get-Content -LiteralPath $packet -Raw -Encoding UTF8
            Add-Check "packet has begin marker $taskId" ($packetText -match 'BAKEOFF_[A-Z_]+_BEGIN')
            Add-Check "packet has end marker $taskId" ($packetText -match 'BAKEOFF_[A-Z_]+_END')
        }
    }

    $packText = Get-Content -LiteralPath $resolvedPackPath -Raw -Encoding UTF8
    $secretPattern = '(?i)(bearer\s+[a-z0-9._-]{16,}|api[_-]?key\s*[:=]\s*[a-z0-9._-]{16,}|secret\s*[:=]\s*[a-z0-9._-]{16,}|BEGIN (RSA|OPENSSH|PRIVATE) KEY)'
    $privatePathFragments = @(
        'C:\Users\',
        ('iCloud' + 'Drive'),
        ('Main' + 'Vault')
    )
    $privatePathPattern = '(?i)(' + (($privatePathFragments | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'
    Add-Check 'pack does not contain obvious secrets' (-not ($packText -match $secretPattern))
    Add-Check 'pack does not contain private local paths' (-not ($packText -match $privatePathPattern))
    foreach ($task in $tasks) {
        $taskId = [string]$task.task_id
        $packetPath = [string]$task.packet_path
        $packet = [System.IO.Path]::GetFullPath((Join-Path $resolvedTaskRoot $packetPath))
        if (-not (Test-PathInsideRoot -Path $packet -Root $resolvedTaskRoot) -or -not (Test-Path -LiteralPath $packet -PathType Leaf)) {
            continue
        }
        $packetText = Get-Content -LiteralPath $packet -Raw -Encoding UTF8
        Add-Check "packet does not contain obvious secrets $taskId" (-not ($packetText -match $secretPattern)) $packetPath
        Add-Check "packet does not contain private local paths $taskId" (-not ($packetText -match $privatePathPattern)) $packetPath
    }
}

if (-not [string]::IsNullOrWhiteSpace($RunDir)) {
    $resolvedRunDir = Resolve-LocalPath $RunDir
    Add-Check 'run dir exists' (Test-Path -LiteralPath $resolvedRunDir -PathType Container) $resolvedRunDir
    foreach ($requiredFile in @('manifest.json', 'commands.jsonl', 'scorecard.md')) {
        Add-Check "run file $requiredFile" (Test-Path -LiteralPath (Join-Path $resolvedRunDir $requiredFile) -PathType Leaf)
    }
}

$failed = @($checks | Where-Object { -not $_.pass })
$result = [pscustomobject]@{
    version      = 1
    pack_id      = if ($null -ne $pack) { [string]$pack.pack_id } else { '' }
    all_pass     = ($failed.Count -eq 0)
    check_count  = $checks.Count
    failed_count = $failed.Count
    checks       = @($checks)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 20
} else {
    foreach ($check in $checks) {
        $status = if ($check.pass) { 'PASS' } else { 'FAIL' }
        Write-Host ("[{0}] {1} {2}" -f $status, $check.name, $check.detail)
    }
}

if (-not $result.all_pass) {
    exit 1
}
