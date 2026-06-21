[CmdletBinding()]
param(
    [string]$PackPath = 'tasks/cli-bakeoff/v1/benchmark-pack.json',
    [string]$ProjectDir = '.winsmux/evidence/v03617-openrouter-harness-project',
    [string]$RunRoot = '.winsmux/evidence/cli-bakeoff',
    [string]$RunId = '',
    [int]$TaskLimit = 0,
    [int]$MaxTokens = 4096,
    [int]$ApiTimeoutSeconds = 300,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
}
Set-Location -LiteralPath $RepoRoot

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function ConvertTo-Slug {
    param([Parameter(Mandatory = $true)][string]$Value)
    $slug = $Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    return $slug.Trim('-')
}

function ConvertTo-SafeText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $text = $text -replace [regex]::Escape($RepoRoot), '<repo>'
    $text = $text -replace '[A-Za-z]:\\[^,"\r\n]+', '<local-path>'
    $text = $text -replace '(?i)(ResponseID:\s*)[A-Za-z0-9_-]{8,}', '$1<redacted>'
    $text = $text -replace '(?i)(Trace:\s*)0x[a-f0-9]+', '$1<redacted>'
    $text = $text -replace '(?i)(email=)[^\s,]+', '$1<redacted>'
    $text = $text -replace '(?i)(authenticated successfully as\s+)[^\s,]+', '$1<redacted>'
    $text = $text -replace '(?i)(provider[_ -]?request[_ -]?id\s*[:=]\s*)[A-Za-z0-9_-]{8,}', '$1<redacted>'
    $text = $text -replace '(?i)(bearer\s+)[a-z0-9._-]{16,}', '$1<redacted>'
    $text = $text -replace '(?i)(api[_-]?key\s*[:=]\s*)[a-z0-9._-]{16,}', '$1<redacted>'
    return $text
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PacketMarkers {
    param([Parameter(Mandatory = $true)][string]$PacketText)
    $begin = [regex]::Match($PacketText, 'BAKEOFF_[A-Z_]+_BEGIN')
    $end = [regex]::Match($PacketText, 'BAKEOFF_[A-Z_]+_END')
    return [pscustomobject]@{
        begin = if ($begin.Success) { $begin.Value } else { '' }
        end   = if ($end.Success) { $end.Value } else { '' }
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Data
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Data | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Test-JsonProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $InputObject) {
        return $false
    }
    return $null -ne $InputObject.PSObject.Properties[$Name]
}

$resolvedPackPath = Resolve-RepoPath $PackPath
$resolvedProjectDir = Resolve-RepoPath $ProjectDir
$resolvedRunRoot = Resolve-RepoPath $RunRoot
$pack = Get-Content -LiteralPath $resolvedPackPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 80

$apiKey = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'Process')
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $apiKey = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User')
}
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    throw 'OPENROUTER_API_KEY is missing in process and user environment.'
}
$effectiveTimeoutSeconds = if ($ApiTimeoutSeconds -gt 0) { $ApiTimeoutSeconds } else { [int]$pack.default_timeout_seconds }
$env:OPENROUTER_API_KEY = $apiKey
$env:WINSMUX_API_LLM_TIMEOUT_SECONDS = [string]$effectiveTimeoutSeconds
if ($MaxTokens -gt 0) {
    $env:WINSMUX_API_LLM_MAX_TOKENS = [string]$MaxTokens
}

if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = 'v03617-openrouter-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
}
$runIdSlug = ConvertTo-Slug $RunId
$runDir = Join-Path $resolvedRunRoot $runIdSlug
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$commandsPath = Join-Path $runDir 'commands.jsonl'
$scorecardPath = Join-Path $runDir 'scorecard.md'
$taskRoot = Split-Path -Parent $resolvedPackPath
$projectTaskRoot = Join-Path $resolvedProjectDir 'tasks/cli-bakeoff/v1'
New-Item -ItemType Directory -Path $projectTaskRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $resolvedProjectDir '.winsmux') -Force | Out-Null

$workers = @($pack.default_workers | Where-Object {
    ($_.PSObject.Properties.Name -contains 'agent') -and
    ($_.PSObject.Properties.Name -contains 'worker_backend') -and
    $_.agent -eq 'openrouter' -and
    $_.worker_backend -eq 'api_llm'
})
if ($workers.Count -eq 0) {
    throw 'No OpenRouter api_llm workers found in benchmark pack.'
}

$configLines = [System.Collections.Generic.List[string]]::new()
$configLines.Add('agent: openrouter') | Out-Null
$configLines.Add('model: provider-default') | Out-Null
$configLines.Add('agent-slots:') | Out-Null
foreach ($worker in $workers) {
    $slotNumber = if ([string]$worker.pane -match '(\d+)$') { $Matches[1] } else { ($workers.IndexOf($worker) + 1) }
    $slotId = "worker-$slotNumber"
    $configLines.Add("  - slot-id: $slotId") | Out-Null
    $configLines.Add('    runtime-role: worker') | Out-Null
    $configLines.Add('    worker-backend: api_llm') | Out-Null
    $configLines.Add("    worker-role: $($worker.role)") | Out-Null
    $configLines.Add('    agent: openrouter') | Out-Null
    $configLines.Add("    model: $($worker.model)") | Out-Null
    $configLines.Add('    model-source: operator-override') | Out-Null
    $configLines.Add('    prompt-transport: file') | Out-Null
    $configLines.Add('    auth-mode: api-key-env') | Out-Null
    $configLines.Add('    worktree-mode: managed') | Out-Null
}
Set-Content -LiteralPath (Join-Path $resolvedProjectDir '.winsmux.yaml') -Value $configLines -Encoding UTF8

$providerCapabilities = [ordered]@{
    version   = 1
    providers = [ordered]@{
        openrouter = [ordered]@{
            adapter                  = 'openai-compatible'
            display_name             = 'OpenRouter'
            command                  = 'openrouter'
            prompt_transports        = @('file')
            auth_modes               = @('api-key-env', 'api-key-vault')
            model_sources            = @('provider-default', 'operator-override')
            reasoning_efforts        = @('provider-default', 'low', 'medium', 'high')
            credential_requirements  = 'runtime-owned-api-key'
            execution_backend        = 'openai-compatible-chat-completions'
            api_base_url             = 'https://openrouter.ai/api/v1'
            api_key_env              = 'OPENROUTER_API_KEY'
            analysis_posture         = 'hosted-api-worker'
            supports_file_edit       = $false
            supports_structured_result = $true
        }
    }
}
Write-JsonFile -Path (Join-Path $resolvedProjectDir '.winsmux/provider-capabilities.json') -Data $providerCapabilities

$selectedTasks = @($pack.tasks)
if ($TaskLimit -gt 0) {
    $selectedTasks = @($selectedTasks | Select-Object -First $TaskLimit)
}
$workerAssignments = @($workers | ForEach-Object {
    [ordered]@{
        pane           = [string]$_.pane
        role           = [string]$_.role
        cli            = [string]$_.cli
        model          = [string]$_.model
        display_model  = [string]$_.display_model
        worker_backend = [string]$_.worker_backend
        agent          = [string]$_.agent
        auth_mode      = [string]$_.auth_mode
        required_env   = [string]$_.required_env
        scored         = if (Test-JsonProperty -InputObject $_ -Name 'scored') { [bool]$_.scored } else { $true }
    }
})

$commands = [System.Collections.Generic.List[object]]::new()
$scorecardLines = [System.Collections.Generic.List[string]]::new()
$scorecardLines.Add("# OpenRouter Harness Bench Evidence: $runIdSlug") | Out-Null
$scorecardLines.Add('') | Out-Null
$scorecardLines.Add('| Worker | Task | Status | Deterministic score | Tokens | Evidence |') | Out-Null
$scorecardLines.Add('| --- | --- | --- | ---: | ---: | --- |') | Out-Null
[System.IO.File]::WriteAllLines($scorecardPath, $scorecardLines, [System.Text.UTF8Encoding]::new($false))

$initialManifest = [ordered]@{
    run_id                = $runIdSlug
    pack_id               = [string]$pack.pack_id
    task_count            = @($selectedTasks).Count
    worker_count          = @($workers).Count
    generated_at_utc      = (Get-Date).ToUniversalTime().ToString('o')
    task_class            = 'mixed'
    recording             = [ordered]@{
        status      = 'api_worker_redacted_artifact'
        publishable = $true
        note        = 'OpenRouter api_llm worker evidence; raw prompts, API key values, provider request ids, and local paths are not published.'
    }
    evidence              = [ordered]@{
        end_marker_present = $false
        packet_hash_match  = $true
    }
    execution             = [ordered]@{
        status                      = 'running'
        benchmark_timeout_seconds   = [int]$pack.default_timeout_seconds
        api_request_timeout_seconds = $effectiveTimeoutSeconds
        max_tokens                  = if ($MaxTokens -gt 0) { $MaxTokens } else { 1024 }
    }
    worker_assignments    = $workerAssignments
    workspace_policy      = $pack.workspace_policy
    operator              = $pack.operator
}
Write-JsonFile -Path (Join-Path $runDir 'manifest.json') -Data $initialManifest

foreach ($task in $selectedTasks) {
    $taskId = [string]$task.task_id
    $packetPath = [string]$task.packet_path
    $sourcePacket = Join-Path $taskRoot $packetPath
    $targetPacket = Join-Path $projectTaskRoot $packetPath
    Copy-Item -LiteralPath $sourcePacket -Destination $targetPacket -Force
    $packetText = Get-Content -LiteralPath $sourcePacket -Raw -Encoding UTF8
    $markers = Get-PacketMarkers -PacketText $packetText
    $packetSha = Get-FileSha256 -Path $sourcePacket
    $relativePacket = 'tasks/cli-bakeoff/v1/' + $packetPath

    foreach ($worker in $workers) {
        $slotNumber = if ([string]$worker.pane -match '(\d+)$') { $Matches[1] } else { ($workers.IndexOf($worker) + 1) }
        $slot = "w$slotNumber"
        $workerSlug = ConvertTo-Slug ([string]$worker.role)
        $singleRunId = "$runIdSlug-$workerSlug-$($taskId.ToLowerInvariant())"
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 'failed'
        $failureClass = ''
        $exclusionReason = ''
        $runJson = $null
        $responseText = ''
        $usageTotal = 0
        $providerResponseIdPresent = $false
        $network = 'not_started'

        try {
            $raw = & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts/winsmux-core.ps1') workers exec $slot --script $relativePacket --task-id $taskId --run-id $singleRunId --json --project-dir $ProjectDir
            $runJson = ($raw | Out-String | ConvertFrom-Json -Depth 80)
            if (Test-JsonProperty -InputObject $runJson -Name 'network') {
                $network = [string]$runJson.network
            }
            if (Test-JsonProperty -InputObject $runJson -Name 'provider_response_id_present') {
                $providerResponseIdPresent = [bool]$runJson.provider_response_id_present
            }
            if (Test-JsonProperty -InputObject $runJson.usage -Name 'total_tokens') {
                $usageTotal = [int]$runJson.usage.total_tokens
            }
            if ($runJson.status -eq 'succeeded') {
                $status = 'completed'
            } else {
                $status = [string]$runJson.status
                $failureClass = [string]$runJson.reason
                $exclusionReason = [string]$runJson.reason
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$runJson.response)) {
                $responsePath = Join-Path $resolvedProjectDir ([string]$runJson.response)
                if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
                    $responseText = Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8
                }
            }
        } catch {
            $status = 'crash'
            $failureClass = 'crash'
            $exclusionReason = ConvertTo-SafeText $_.Exception.Message
        } finally {
            $stopwatch.Stop()
        }

        $hasBegin = -not [string]::IsNullOrWhiteSpace($markers.begin) -and $responseText.Contains($markers.begin)
        $hasEnd = -not [string]::IsNullOrWhiteSpace($markers.end) -and $responseText.Contains($markers.end)
        $hasNoObviousSecrets = $responseText -notmatch '(?i)(bearer\s+[a-z0-9._-]{16,}|api[_-]?key\s*[:=]\s*[a-z0-9._-]{16,}|secret\s*[:=]\s*[a-z0-9._-]{16,})'
        $hasNoPrivatePaths = $responseText -notmatch '(?i)([A-Za-z]:\\Users\\|/Users/|/home/)'
        $hiddenPassed = @($hasBegin, $hasEnd, $hasNoObviousSecrets, $hasNoPrivatePaths) |
            Where-Object { $_ } |
            Measure-Object |
            Select-Object -ExpandProperty Count
        $hiddenTotal = 4
        $deterministicScore = [math]::Round(($hiddenPassed / $hiddenTotal) * 100, 2)
        $endMarkerPresent = $hasBegin -and $hasEnd
        if ($status -eq 'completed' -and -not $endMarkerPresent) {
            $status = 'invalid_output'
            $failureClass = 'invalid_output'
            $exclusionReason = 'invalid_output'
        }

        $command = [ordered]@{
            cli                          = [string]$worker.cli
            model                        = [string]$worker.display_model
            provider_model               = [string]$worker.model
            role                         = [string]$worker.role
            pane                         = [string]$worker.pane
            scored                       = if (Test-JsonProperty -InputObject $worker -Name 'scored') { [bool]$worker.scored } else { $true }
            task_id                      = $taskId
            task_class                   = [string]$task.task_class
            status                       = $status
            elapsed_seconds              = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
            end_marker_present           = $endMarkerPresent
            packet_hash_match            = $true
            packet_sha256                = $packetSha
            stdout_empty                 = [string]::IsNullOrWhiteSpace($responseText)
            hidden_tests_passed          = $hiddenPassed
            hidden_tests_total           = $hiddenTotal
            deterministic_score          = $deterministicScore
            failure_class                = $failureClass
            exclusion_reason             = $exclusionReason
            network                      = $network
            provider_response_id_present = $providerResponseIdPresent
            tokens_total                 = $usageTotal
            api_key_env                  = 'OPENROUTER_API_KEY'
            response_ref                 = if ($null -ne $runJson) { [string]$runJson.response } else { '' }
            run_json_ref                 = if ($null -ne $runJson) { [string]$runJson.run_json } else { '' }
        }
        $commandObject = [pscustomobject]$command
        $commands.Add($commandObject) | Out-Null
        $commandObject | ConvertTo-Json -Depth 40 -Compress | Add-Content -LiteralPath $commandsPath -Encoding UTF8
        $scorecardLine = ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f
            (ConvertTo-SafeText $worker.display_model),
            $taskId,
            $status,
            $deterministicScore,
            $usageTotal,
            (ConvertTo-SafeText $command.response_ref)
        )
        $scorecardLines.Add($scorecardLine) | Out-Null
        Add-Content -LiteralPath $scorecardPath -Value $scorecardLine -Encoding UTF8
    }
}

$manifest = [ordered]@{
    run_id                = $runIdSlug
    pack_id               = [string]$pack.pack_id
    task_count            = @($selectedTasks).Count
    worker_count          = @($workers).Count
    generated_at_utc      = (Get-Date).ToUniversalTime().ToString('o')
    task_class            = 'mixed'
    recording             = [ordered]@{
        status      = 'api_worker_redacted_artifact'
        publishable = $true
        note        = 'OpenRouter api_llm worker evidence; raw prompts, API key values, provider request ids, and local paths are not published.'
    }
    evidence              = [ordered]@{
        end_marker_present = (@($commands | Where-Object { -not $_.end_marker_present }).Count -eq 0)
        packet_hash_match  = $true
    }
    execution             = [ordered]@{
        status                      = 'completed'
        benchmark_timeout_seconds   = [int]$pack.default_timeout_seconds
        api_request_timeout_seconds = $effectiveTimeoutSeconds
        max_tokens                  = if ($MaxTokens -gt 0) { $MaxTokens } else { 1024 }
    }
    worker_assignments    = $workerAssignments
    workspace_policy      = $pack.workspace_policy
    operator              = $pack.operator
}
Write-JsonFile -Path (Join-Path $runDir 'manifest.json') -Data $manifest
$commands | ForEach-Object { $_ | ConvertTo-Json -Depth 40 -Compress } | Set-Content -LiteralPath (Join-Path $runDir 'commands.jsonl') -Encoding UTF8
[System.IO.File]::WriteAllLines($scorecardPath, $scorecardLines, [System.Text.UTF8Encoding]::new($false))

$result = [pscustomobject]@{
    run_id         = $runIdSlug
    run_dir        = $runDir
    task_count     = @($selectedTasks).Count
    worker_count   = @($workers).Count
    command_rows   = $commands.Count
    completed_rows = @($commands | Where-Object { $_.status -eq 'completed' }).Count
    failed_rows    = @($commands | Where-Object { $_.status -ne 'completed' }).Count
}
if ($Json) {
    $result | ConvertTo-Json -Depth 10
} else {
    Write-Host ("run-cli-bakeoff-openrouter wrote {0} rows to {1}" -f $result.command_rows, $runDir)
}
