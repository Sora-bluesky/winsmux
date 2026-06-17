param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectDir,

    [ValidateSet('Concurrent', 'Sequential')]
    [string]$Mode = 'Concurrent',

    [string]$RunIdPrefix = '',

    [string]$Prompt = 'Answer in one concise paragraph. Include the model family, runtime engine, and one practical use case for winsmux worker orchestration.',

    [string]$OutputDir = '',

    [int]$TimeoutSec = 3600,

    [string[]]$Workers = @('worker-1', 'worker-2'),

    [string]$ExpectedModelId = '',

    [switch]$PlanOnly,

    [switch]$CapacityPreflightOnly,

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

function Resolve-WorkerId {
    param([Parameter(Mandatory = $true)][string]$Value)
    $text = ([string]$Value).Trim()
    if ($text -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
        throw "Invalid worker id '$Value'. Worker ids must start with an ASCII letter or digit and contain only letters, digits, '.', '_' or '-'."
    }
    return $text
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

function Get-ColabLlmProjectHint {
    return 'Pass -ProjectDir to a Git-ignored project configured with the requested colab_llm worker slots. The source checkout defaults are public-safe and are not a live Colab LLM E2E project.'
}

function Get-ColabLlmModelId {
    param([Parameter(Mandatory = $true)]$Worker)
    if ($null -ne $Worker.colab_llm -and $null -ne $Worker.colab_llm.model_id) {
        return [string]$Worker.colab_llm.model_id
    }
    if ($null -ne $Worker.model_id) {
        return [string]$Worker.model_id
    }
    return ''
}

function Test-TruthyEnv {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$Default = $true
    )
    $value = [string](Get-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue).Value
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return ($value.Trim().ToLowerInvariant() -notin @('0', 'false', 'no', 'off'))
}

function Get-PositiveInt64Env {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Int64]$Default
    )
    $value = [string](Get-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue).Value
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    $parsed = 0L
    if ([Int64]::TryParse($value.Trim(), [ref]$parsed) -and $parsed -gt 0) {
        return $parsed
    }
    return $Default
}

function Get-PositiveDoubleEnv {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][double]$Default
    )
    $value = [string](Get-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue).Value
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    $parsed = 0.0
    if ([double]::TryParse($value.Trim(), [ref]$parsed) -and $parsed -gt 0) {
        return $parsed
    }
    return $Default
}

function ConvertTo-HfPathSegment {
    param([AllowEmptyString()][string]$Value)
    return [System.Uri]::EscapeDataString([string]$Value)
}

function ConvertTo-HfModelPath {
    param([Parameter(Mandatory = $true)][string]$ModelId)
    return (([string]$ModelId -split '/') | ForEach-Object { ConvertTo-HfPathSegment -Value $_ }) -join '/'
}

function ConvertTo-HfFilePath {
    param([Parameter(Mandatory = $true)][string]$FileName)
    return (([string]$FileName -split '/') | ForEach-Object { ConvertTo-HfPathSegment -Value $_ }) -join '/'
}

function ConvertTo-PlainHashtable {
    param([Parameter(Mandatory = $true)]$Value)
    $result = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }
    return $result
}

function Get-CapacityEstimateFixture {
    param([Parameter(Mandatory = $true)][string]$ModelId)
    $raw = [string]$env:WINSMUX_COLAB_LLM_E2E_CAPACITY_ESTIMATE_JSON
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    $candidates = @()
    if ($parsed -is [array]) {
        $candidates = @($parsed)
    } else {
        $directProperty = $parsed.PSObject.Properties | Where-Object { $_.Name -eq $ModelId } | Select-Object -First 1
        if ($null -ne $directProperty) {
            $candidates = @($directProperty.Value)
        } elseif ($null -ne $parsed.models) {
            $candidates = @($parsed.models)
        } else {
            $candidates = @($parsed)
        }
    }
    foreach ($candidate in $candidates) {
        if ($null -eq $candidate) {
            continue
        }
        $candidateModel = [string]$candidate.model_id
        if ([string]::IsNullOrWhiteSpace($candidateModel) -or $candidateModel -eq $ModelId) {
            $estimate = ConvertTo-PlainHashtable -Value $candidate
            if (-not $estimate.Contains('model_id')) {
                $estimate['model_id'] = $ModelId
            }
            $estimate['source'] = 'env_fixture'
            return $estimate
        }
    }
    return $null
}

function Get-HeaderFirstValue {
    param(
        [Parameter(Mandatory = $true)]$Headers,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $value = $Headers[$Name]
    if ($value -is [array]) {
        return [string]$value[0]
    }
    return [string]$value
}

function Get-HfModelStorageEstimate {
    param([Parameter(Mandatory = $true)][string]$ModelId)

    $fixture = Get-CapacityEstimateFixture -ModelId $ModelId
    if ($null -ne $fixture) {
        return $fixture
    }

    $timeout = [int][Math]::Ceiling((Get-PositiveDoubleEnv -Name 'WINSMUX_COLAB_LLM_HF_METADATA_TIMEOUT_SECONDS' -Default 30.0))
    $modelPath = ConvertTo-HfModelPath -ModelId $ModelId
    $metadata = Invoke-RestMethod -Method Get -Uri "https://huggingface.co/api/models/$modelPath" -TimeoutSec $timeout -Headers @{ Accept = 'application/json' }
    $weightFiles = @()
    $safetensors = @()
    $shardCount = 0
    $firstShard = ''
    foreach ($sibling in @($metadata.siblings)) {
        $name = [string]$sibling.rfilename
        if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch '\.(safetensors|bin|gguf)$') {
            continue
        }
        $weightFiles += $name
        if ($name.EndsWith('.safetensors', [System.StringComparison]::OrdinalIgnoreCase)) {
            $safetensors += $name
        }
        $match = [regex]::Match($name, '^(?:.*-)?([0-9]{5})-of-([0-9]{5})\.(?:safetensors|bin)$')
        if ($match.Success) {
            $shardCount = [Math]::Max($shardCount, [int]$match.Groups[2].Value)
            if ([string]::IsNullOrWhiteSpace($firstShard) -or $name -lt $firstShard) {
                $firstShard = $name
            }
        }
    }
    if ($weightFiles.Count -eq 0) {
        return [ordered]@{
            model_id = $ModelId
            status = 'model_size_unavailable'
            reason = 'Hugging Face model weight files were not found for capacity preflight'
            weight_files = 0
            estimated_total_bytes = 0
            source = 'huggingface'
        }
    }
    $sampleFile = if ([string]::IsNullOrWhiteSpace($firstShard)) { @($weightFiles | Sort-Object)[0] } else { $firstShard }
    $samplePath = ConvertTo-HfFilePath -FileName $sampleFile
    $head = Invoke-WebRequest -Method Head -Uri "https://huggingface.co/$modelPath/resolve/main/$samplePath" -TimeoutSec $timeout -MaximumRedirection 8 -UseBasicParsing
    $linkedSize = Get-HeaderFirstValue -Headers $head.Headers -Name 'X-Linked-Size'
    if ([string]::IsNullOrWhiteSpace($linkedSize)) {
        $linkedSize = Get-HeaderFirstValue -Headers $head.Headers -Name 'Content-Length'
    }
    $sampleSize = 0L
    [void][Int64]::TryParse(([string]$linkedSize).Trim(), [ref]$sampleSize)
    $effectiveShards = if ($shardCount -gt 0) { $shardCount } else { $weightFiles.Count }
    return [ordered]@{
        model_id = $ModelId
        weight_files = $weightFiles.Count
        safetensor_files = $safetensors.Count
        shard_count = $effectiveShards
        sample_file = $sampleFile
        sample_size_bytes = $sampleSize
        estimated_total_bytes = if ($sampleSize -gt 0) { $sampleSize * [Int64]$effectiveShards } else { 0 }
        source = 'huggingface'
    }
}

function Test-ColabLlmCapacity {
    param(
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [Parameter(Mandatory = $true)][string]$ModelId
    )
    if (-not (Test-TruthyEnv -Name 'WINSMUX_COLAB_LLM_MODEL_CAPACITY_PREFLIGHT' -Default $true)) {
        return [ordered]@{
            enabled = $false
            status = 'skipped'
            worker_id = $WorkerId
            model_id = $ModelId
        }
    }
    $maxBytes = Get-PositiveInt64Env -Name 'WINSMUX_COLAB_LLM_MAX_MODEL_BYTES' -Default ([Int64]350 * 1024 * 1024 * 1024)
    try {
        $estimate = Get-HfModelStorageEstimate -ModelId $ModelId
    } catch {
        return [ordered]@{
            enabled = $true
            status = 'model_capacity_preflight_failed'
            worker_id = $WorkerId
            model_id = $ModelId
            max_total_bytes = $maxBytes
            estimated_total_bytes = 0
            error = $_.Exception.Message
        }
    }
    $estimatedBytes = 0L
    [void][Int64]::TryParse(([string]$estimate['estimated_total_bytes']), [ref]$estimatedBytes)
    $estimateStatus = if ($estimate.Contains('status')) { [string]$estimate['status'] } else { '' }
    $status = if ($estimatedBytes -gt $maxBytes) { 'model_capacity_exceeded' } elseif ($estimateStatus -eq 'model_size_unavailable') { 'model_size_unavailable' } else { 'capacity_ok' }
    return [ordered]@{
        enabled = $true
        status = $status
        worker_id = $WorkerId
        model_id = $ModelId
        max_total_bytes = $maxBytes
        estimated_total_bytes = $estimatedBytes
        estimate = $estimate
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

$targetWorkers = @()
foreach ($workerId in @($Workers)) {
    $resolvedWorkerId = Resolve-WorkerId -Value ([string]$workerId)
    if ($targetWorkers -notcontains $resolvedWorkerId) {
        $targetWorkers += $resolvedWorkerId
    }
}
if ($targetWorkers.Count -eq 0) {
    throw 'At least one worker must be selected.'
}

if (-not (Test-Path -LiteralPath $script:CorePath -PathType Leaf)) {
    throw "winsmux-core.ps1 not found: $script:CorePath"
}
if ([string]::IsNullOrWhiteSpace($RunIdPrefix)) {
    $RunIdPrefix = 'colab-llm-e2e-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
}
$RunIdPrefix = New-SafeRunId -Value $RunIdPrefix

if (-not $PlanOnly -and -not $CapacityPreflightOnly -and [string]$env:WINSMUX_COLAB_ACCEPTANCE_REAL -ne '1') {
    throw 'Refusing to run live Colab GPU E2E without WINSMUX_COLAB_ACCEPTANCE_REAL=1. Use -PlanOnly for a non-executing preflight.'
}

if (-not $PlanOnly) {
    if ([string]::IsNullOrWhiteSpace([string]$env:WINSMUX_COLAB_CLI_ADAPTER_PROXY_TIMEOUT_SEC)) {
        $env:WINSMUX_COLAB_CLI_ADAPTER_PROXY_TIMEOUT_SEC = '600'
    }
    if ([string]::IsNullOrWhiteSpace([string]$env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_SETUP)) {
        $env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_SETUP = '1'
    }
    if ([string]::IsNullOrWhiteSpace([string]$env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_GPU)) {
        $env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_GPU = 'A100'
    }
    if ([string]::IsNullOrWhiteSpace([string]$env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_HEADLESS)) {
        $env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_HEADLESS = '0'
    }
    if ([string]::IsNullOrWhiteSpace([string]$env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_CHANNEL)) {
        $env:WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_CHANNEL = 'chrome'
    }
    if ([string]::IsNullOrWhiteSpace([string]$env:WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER)) {
        $env:WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER = '1'
    }
    if ([string]::IsNullOrWhiteSpace([string]$env:WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER_TIMEOUT_SEC)) {
        $env:WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER_TIMEOUT_SEC = [string][Math]::Max(30, ([int]$TimeoutSec - 30))
    }
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

$statusWorkers = @($status.Json.workers)
foreach ($required in $targetWorkers) {
    $worker = $null
    foreach ($candidate in $statusWorkers) {
        if ([string]$candidate.slot_id -eq $required) {
            $worker = $candidate
            break
        }
    }
    if ($null -eq $worker) {
        throw "missing required worker slot: $required. $(Get-ColabLlmProjectHint)"
    }
    if ([string]$worker.backend -ne 'colab_llm') {
        throw "worker slot $required uses backend '$($worker.backend)', not colab_llm. $(Get-ColabLlmProjectHint)"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$worker.degraded_reason)) {
        throw "worker slot $required is degraded: $($worker.degraded_reason)"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedModelId)) {
        $actualModelId = Get-ColabLlmModelId -Worker $worker
        if ($actualModelId -ne $ExpectedModelId) {
            throw "worker slot $required uses model_id '$actualModelId', not expected '$ExpectedModelId'."
        }
    }
}

$runIds = @{}
foreach ($workerId in $targetWorkers) {
    $runIds[$workerId] = New-SafeRunId -Value "$RunIdPrefix-$workerId"
}

$summaryWorkers = @()
foreach ($workerId in $targetWorkers) {
    $worker = $null
    foreach ($candidate in $statusWorkers) {
        if ([string]$candidate.slot_id -eq $workerId) {
            $worker = $candidate
            break
        }
    }
    $summaryWorkers += [ordered]@{
        slot_id  = $workerId
        run_id   = $runIds[$workerId]
        model_id = Get-ColabLlmModelId -Worker $worker
        status   = 'pending'
    }
}

$summary = [ordered]@{
    schema_version = 'winsmux.colab_llm.e2e_runner.v1'
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    mode = $Mode
    plan_only = [bool]$PlanOnly
    project_dir = '[PROJECT_DIR_REDACTED]'
    output_dir = '[OUTPUT_DIR_REDACTED]'
    run_id_prefix = $RunIdPrefix
    expected_model_id = if ([string]::IsNullOrWhiteSpace($ExpectedModelId)) { '' } else { $ExpectedModelId }
    workers = @($summaryWorkers)
}

if ($PlanOnly) {
    foreach ($workerEntry in @($summary.workers)) {
        $workerEntry.status = 'planned'
    }
    $summaryPath = Join-Path $OutputDir 'summary.json'
    Set-Content -LiteralPath $summaryPath -Value ($summary | ConvertTo-Json -Depth 12) -Encoding UTF8
    if ($Json) {
        $summary | ConvertTo-Json -Depth 12
    } else {
        "Plan only. Doctor/status artifacts written to: $OutputDir"
    }
    exit 0
}

$shouldRunCapacityPreflight = $CapacityPreflightOnly -or (-not $PlanOnly -and (Test-TruthyEnv -Name 'WINSMUX_COLAB_LLM_MODEL_CAPACITY_PREFLIGHT' -Default $true))
if ($shouldRunCapacityPreflight) {
    $capacityFailures = @()
    foreach ($workerEntry in @($summary.workers)) {
        $capacity = Test-ColabLlmCapacity -WorkerId ([string]$workerEntry.slot_id) -ModelId ([string]$workerEntry.model_id)
        $workerEntry.capacity_preflight = $capacity
        if ([string]$capacity.status -eq 'model_capacity_exceeded') {
            $workerEntry.status = 'model_capacity_exceeded'
            $workerEntry.exit_code = 1
            $workerEntry.blocked_reason = 'model_capacity_exceeded'
            $capacityFailures += $workerEntry
        } elseif ([string]$capacity.status -eq 'model_size_unavailable') {
            $workerEntry.status = 'model_size_unavailable'
            $workerEntry.exit_code = 1
            $workerEntry.blocked_reason = 'model_size_unavailable'
            $capacityFailures += $workerEntry
        } elseif ([string]$capacity.status -eq 'model_capacity_preflight_failed') {
            $workerEntry.status = 'model_capacity_preflight_failed'
            $workerEntry.exit_code = 1
            $workerEntry.blocked_reason = 'model_capacity_preflight_failed'
            $capacityFailures += $workerEntry
        } elseif ($CapacityPreflightOnly) {
            $workerEntry.status = 'capacity_ok'
        }
    }

    if ($CapacityPreflightOnly -or $capacityFailures.Count -gt 0) {
        $summaryPath = Join-Path $OutputDir 'summary.json'
        Set-Content -LiteralPath $summaryPath -Value ($summary | ConvertTo-Json -Depth 16) -Encoding UTF8
        if ($Json) {
            $summary | ConvertTo-Json -Depth 16
        } else {
            "Capacity preflight artifacts written to: $OutputDir"
            "Summary: $summaryPath"
        }
        if ($capacityFailures.Count -gt 0) {
            exit 1
        }
        exit 0
    }
}

if (-not (Test-Path -LiteralPath $script:SourceColabLlmWorkerPath -PathType Leaf)) {
    throw "Colab LLM worker script not found: $script:SourceColabLlmWorkerPath"
}
$projectWorkerDir = Join-Path (Join-Path $script:ProjectRoot 'workers') 'colab'
New-Item -ItemType Directory -Path $projectWorkerDir -Force | Out-Null
$script:ColabLlmWorkerPath = Join-Path $projectWorkerDir 'llm_worker.py'
Copy-Item -LiteralPath $script:SourceColabLlmWorkerPath -Destination $script:ColabLlmWorkerPath -Force
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
    foreach ($workerId in $targetWorkers) {
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
            Stop-Job -Job $job -ErrorAction SilentlyContinue
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
    foreach ($workerId in $targetWorkers) {
        $outputPath = Join-Path $OutputDir "exec-$workerId.json"
        $job = Start-WorkerJob -WorkerId $workerId -RunId $runIds[$workerId] -OutputPath $outputPath -Environment $envSnapshot
        $null = Wait-Job -Job $job -Timeout $TimeoutSec
        if ($job.State -eq 'Running') {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
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

foreach ($workerId in $targetWorkers) {
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
