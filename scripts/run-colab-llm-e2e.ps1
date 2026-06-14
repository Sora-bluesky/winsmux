param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectDir,

    [ValidateSet('Concurrent', 'Sequential')]
    [string]$Mode = 'Concurrent',

    [string]$RunIdPrefix = '',

    [string]$Prompt = 'Answer in one concise paragraph. Include the model family, runtime engine, and one practical use case for winsmux worker orchestration.',

    [string]$OutputDir = '',

    [int]$TimeoutSec = 3600,

    [switch]$PlanOnly,

    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Resolve-RequiredPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        throw "$Label not found: $Path"
    }
    return $item.FullName
}

function New-SafeRunId {
    param([Parameter(Mandatory = $true)][string]$Value)
    $safe = ($Value -replace '[^A-Za-z0-9_.-]', '-').Trim('.-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        throw 'run id is empty after sanitization'
    }
    return $safe
}

function ConvertFrom-JsonOrNull {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    try {
        return $Text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

function Invoke-WinsmuxJson {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )
    $raw = & pwsh -NoLogo -NoProfile -File $script:CorePath @Arguments 2>&1 | Out-String
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    Set-Content -LiteralPath $OutputPath -Value $raw -Encoding UTF8
    return [PSCustomObject]@{
        ExitCode = $exitCode
        Raw = $raw
        Json = ConvertFrom-JsonOrNull -Text $raw
    }
}

function Start-WorkerJob {
    param(
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][hashtable]$Environment
    )
    Start-Job -ScriptBlock {
        param($CorePath, $ProjectRoot, $PromptText, $ColabLlmWorkerPath, $WorkerId, $RunId, $OutputPath, $Environment)
        $ErrorActionPreference = 'Stop'
        foreach ($key in $Environment.Keys) {
            Set-Item -Path ("Env:{0}" -f $key) -Value ([string]$Environment[$key])
        }
        $raw = & pwsh -NoLogo -NoProfile -File $CorePath workers exec $WorkerId --script $ColabLlmWorkerPath --prompt $PromptText --run-id $RunId --json --project-dir $ProjectRoot 2>&1 | Out-String
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        Set-Content -LiteralPath $OutputPath -Value $raw -Encoding UTF8
        [PSCustomObject]@{
            WorkerId = $WorkerId
            RunId = $RunId
            ExitCode = $exitCode
            OutputPath = $OutputPath
        }
    } -ArgumentList $script:CorePath, $script:ProjectRoot, $script:PromptText, $script:ColabLlmWorkerPath, $WorkerId, $RunId, $OutputPath, $Environment
}

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:CorePath = Join-Path $script:RepoRoot 'scripts\winsmux-core.ps1'
$script:SourceColabLlmWorkerPath = Join-Path $script:RepoRoot 'workers\colab\llm_worker.py'
$script:ColabLlmWorkerPath = ''
$script:ProjectRoot = Resolve-RequiredPath -Path $ProjectDir -Label 'ProjectDir'
$script:PromptText = $Prompt

if (-not (Test-Path -LiteralPath $script:CorePath -PathType Leaf)) {
    throw "winsmux-core.ps1 not found: $script:CorePath"
}
if ([string]::IsNullOrWhiteSpace($RunIdPrefix)) {
    $RunIdPrefix = 'colab-llm-e2e-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
}
$RunIdPrefix = New-SafeRunId -Value $RunIdPrefix

if (-not $PlanOnly -and [string]$env:WINSMUX_COLAB_ACCEPTANCE_REAL -ne '1') {
    throw 'Refusing to run live Colab GPU E2E without WINSMUX_COLAB_ACCEPTANCE_REAL=1. Use -PlanOnly for a non-executing preflight.'
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path (Join-Path $script:ProjectRoot '.winsmux') (Join-Path 'colab-llm-e2e' $RunIdPrefix)
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$OutputDir = (Get-Item -LiteralPath $OutputDir).FullName

$doctor = Invoke-WinsmuxJson -Arguments @('workers', 'doctor', '--json', '--project-dir', $script:ProjectRoot) -OutputPath (Join-Path $OutputDir 'doctor.json')
$status = Invoke-WinsmuxJson -Arguments @('workers', 'status', '--json', '--project-dir', $script:ProjectRoot) -OutputPath (Join-Path $OutputDir 'status.json')
if ($doctor.ExitCode -ne 0) {
    throw "workers doctor failed; see $OutputDir"
}
if ($status.ExitCode -ne 0 -or $null -eq $status.Json) {
    throw "workers status failed; see $OutputDir"
}

$workers = @($status.Json.workers | Where-Object { $_.slot_id -in @('worker-1', 'worker-2') })
foreach ($required in @('worker-1', 'worker-2')) {
    $worker = @($workers | Where-Object { $_.slot_id -eq $required })[0]
    if ($null -eq $worker) {
        throw "missing required worker slot: $required"
    }
    if ([string]$worker.backend -ne 'colab_llm') {
        throw "worker slot $required uses backend '$($worker.backend)', not colab_llm"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$worker.degraded_reason)) {
        throw "worker slot $required is degraded: $($worker.degraded_reason)"
    }
}

$runIds = @{
    'worker-1' = New-SafeRunId -Value "$RunIdPrefix-worker-1"
    'worker-2' = New-SafeRunId -Value "$RunIdPrefix-worker-2"
}

$summary = [ordered]@{
    schema_version = 'winsmux.colab_llm.e2e_runner.v1'
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    mode = $Mode
    plan_only = [bool]$PlanOnly
    project_dir = '[PROJECT_DIR_REDACTED]'
    output_dir = '[OUTPUT_DIR_REDACTED]'
    run_id_prefix = $RunIdPrefix
    workers = @(
        [ordered]@{ slot_id = 'worker-1'; run_id = $runIds['worker-1']; status = 'pending' }
        [ordered]@{ slot_id = 'worker-2'; run_id = $runIds['worker-2']; status = 'pending' }
    )
}

if ($PlanOnly) {
    $summary.workers[0].status = 'planned'
    $summary.workers[1].status = 'planned'
    $summaryPath = Join-Path $OutputDir 'summary.json'
    Set-Content -LiteralPath $summaryPath -Value ($summary | ConvertTo-Json -Depth 12) -Encoding UTF8
    if ($Json) {
        $summary | ConvertTo-Json -Depth 12
    } else {
        "Plan only. Doctor/status artifacts written to: $OutputDir"
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $script:SourceColabLlmWorkerPath -PathType Leaf)) {
    throw "Colab LLM worker script not found: $script:SourceColabLlmWorkerPath"
}
$projectWorkerDir = Join-Path (Join-Path $script:ProjectRoot 'workers') 'colab'
New-Item -ItemType Directory -Path $projectWorkerDir -Force | Out-Null
$script:ColabLlmWorkerPath = Join-Path $projectWorkerDir 'llm_worker.py'
if (-not (Test-Path -LiteralPath $script:ColabLlmWorkerPath -PathType Leaf)) {
    Copy-Item -LiteralPath $script:SourceColabLlmWorkerPath -Destination $script:ColabLlmWorkerPath
}
$script:ColabLlmWorkerPath = (Get-Item -LiteralPath $script:ColabLlmWorkerPath).FullName

$envSnapshot = @{}
foreach ($envPattern in @('WINSMUX_COLAB*', 'COLAB_MCP_*')) {
    Get-ChildItem "Env:$envPattern" | ForEach-Object {
        $envSnapshot[$_.Name] = $_.Value
    }
}

$execResults = @()
if ($Mode -eq 'Concurrent') {
    $jobInfos = @()
    foreach ($workerId in @('worker-1', 'worker-2')) {
        $outputPath = Join-Path $OutputDir "exec-$workerId.json"
        $jobInfos += [PSCustomObject]@{
            WorkerId = $workerId
            RunId = $runIds[$workerId]
            OutputPath = $outputPath
            Job = Start-WorkerJob -WorkerId $workerId -RunId $runIds[$workerId] -OutputPath $outputPath -Environment $envSnapshot
        }
    }
    $jobs = @($jobInfos | ForEach-Object { $_.Job })
    $null = Wait-Job -Job $jobs -Timeout $TimeoutSec
    foreach ($jobInfo in $jobInfos) {
        $job = $jobInfo.Job
        if ($job.State -eq 'Running') {
            Stop-Job -Job $job -Force
            Set-Content -LiteralPath $jobInfo.OutputPath -Value "Timed out after $TimeoutSec seconds." -Encoding UTF8
            $execResults += [PSCustomObject]@{
                WorkerId = $jobInfo.WorkerId
                RunId = $jobInfo.RunId
                ExitCode = 124
                OutputPath = $jobInfo.OutputPath
            }
            continue
        }
        $received = Receive-Job -Job $job -ErrorAction SilentlyContinue
        if ($null -ne $received) {
            $execResults += $received
        } else {
            $execResults += [PSCustomObject]@{
                WorkerId = $jobInfo.WorkerId
                RunId = $jobInfo.RunId
                ExitCode = if ($job.State -eq 'Failed') { 1 } else { 124 }
                OutputPath = $jobInfo.OutputPath
            }
        }
    }
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
} else {
    foreach ($workerId in @('worker-1', 'worker-2')) {
        $outputPath = Join-Path $OutputDir "exec-$workerId.json"
        $job = Start-WorkerJob -WorkerId $workerId -RunId $runIds[$workerId] -OutputPath $outputPath -Environment $envSnapshot
        $null = Wait-Job -Job $job -Timeout $TimeoutSec
        if ($job.State -eq 'Running') {
            Stop-Job -Job $job -Force
            Set-Content -LiteralPath $outputPath -Value "Timed out after $TimeoutSec seconds." -Encoding UTF8
            $execResults += [PSCustomObject]@{
                WorkerId = $workerId
                RunId = $runIds[$workerId]
                ExitCode = 124
                OutputPath = $outputPath
            }
        } else {
            $received = Receive-Job -Job $job -ErrorAction SilentlyContinue
            if ($null -ne $received) {
                $execResults += $received
            } else {
                $execResults += [PSCustomObject]@{
                    WorkerId = $workerId
                    RunId = $runIds[$workerId]
                    ExitCode = 1
                    OutputPath = $outputPath
                }
            }
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

foreach ($result in @($execResults)) {
    $workerEntry = @($summary.workers | Where-Object { $_.slot_id -eq $result.WorkerId })[0]
    if ($null -ne $workerEntry) {
        $workerEntry.status = if ([int]$result.ExitCode -eq 0) { 'succeeded' } else { 'failed' }
        $workerEntry.exit_code = [int]$result.ExitCode
        $workerEntry.exec_output = if ([string]::IsNullOrWhiteSpace([string]$result.OutputPath)) { '' } else { Split-Path -Leaf $result.OutputPath }
    }
}

foreach ($workerId in @('worker-1', 'worker-2')) {
    $logPath = Join-Path $OutputDir "logs-$workerId.json"
    $logResult = Invoke-WinsmuxJson -Arguments @('workers', 'logs', $workerId, '--run-id', $runIds[$workerId], '--json', '--project-dir', $script:ProjectRoot) -OutputPath $logPath
    $workerEntry = @($summary.workers | Where-Object { $_.slot_id -eq $workerId })[0]
    if ($null -ne $workerEntry) {
        $workerEntry.logs_output = Split-Path -Leaf $logPath
        $workerEntry.logs_exit_code = [int]$logResult.ExitCode
        $workerEntry.logs_status = if ([int]$logResult.ExitCode -eq 0) { 'succeeded' } else { 'failed' }
        if ([int]$logResult.ExitCode -ne 0 -and [string]$workerEntry.status -eq 'succeeded') {
            $workerEntry.status = 'failed'
        }
    }
}

$summaryPath = Join-Path $OutputDir 'summary.json'
Set-Content -LiteralPath $summaryPath -Value ($summary | ConvertTo-Json -Depth 12) -Encoding UTF8
$failed = @($summary.workers | Where-Object { $_.status -ne 'succeeded' })
if ($Json) {
    $summary | ConvertTo-Json -Depth 12
} else {
    "Colab LLM E2E artifacts written to: $OutputDir"
    "Summary: $summaryPath"
}
if ($failed.Count -gt 0) {
    exit 1
}
