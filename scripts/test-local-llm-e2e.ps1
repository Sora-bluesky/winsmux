param(
    [string]$ProjectDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory = $true)][string]$ModelRoot,
    [Parameter(Mandatory = $true)][string]$ArtifactRoot,
    [string]$Worker3Model = 'gemma3:1b',
    [string]$Worker4Model = 'qwen2.5-coder:1.5b',
    [string]$Endpoint = 'http://127.0.0.1:11434',
    [string]$Prompt = 'Return a concise JSON object with keys summary, risk, and next_step for a winsmux local LLM worker smoke test.',
    [string]$RunId = '',
    [string]$OllamaPath = '',
    [ValidateRange(1, 3600)][int]$WorkerExecTimeoutSeconds = 600,
    [switch]$CreateRoots,
    [switch]$PullModels,
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'

function Get-SubstTargetForDrive {
    param([Parameter(Mandatory = $true)][string]$DriveLetter)

    $drive = $DriveLetter.TrimEnd(':', '\', '/').ToUpperInvariant()
    if ($drive.Length -ne 1) {
        return ''
    }

    try {
        $lines = @(cmd.exe /c subst 2>$null)
    } catch {
        return ''
    }

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) {
            continue
        }
        if ([string]$line -match '^\s*([A-Za-z]):\\:\s*=>\s*(.+?)\s*$') {
            if ([string]::Equals($matches[1], $drive, [System.StringComparison]::OrdinalIgnoreCase)) {
                return [string]$matches[2]
            }
        }
    }

    return ''
}

function Test-GDrivePath {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $text = ([string]$Path).Trim()
    if ($text -match '^(?i)G:[\\/]') {
        return $true
    }

    if ($text -match '^(?<drive>[A-Za-z]):[\\/]') {
        $substTarget = Get-SubstTargetForDrive -DriveLetter $matches['drive']
        return (-not [string]::IsNullOrWhiteSpace($substTarget) -and $substTarget -match '^(?i)G:[\\/]')
    }

    return $false
}

function Test-AsciiPath {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    return (([string]$Path).Trim() -cmatch '^[\x00-\x7F]+$')
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    return $pathFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Stop-E2E {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Error $Message
    exit 1
}

function Invoke-JsonCommand {
    param(
        [Parameter(Mandatory = $true)][string]$PwshPath,
        [Parameter(Mandatory = $true)][string]$CoreScript,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = & $PwshPath -NoProfile -File $CoreScript @Arguments 2>&1
    $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    [PSCustomObject]@{
        exit_code = $exitCode
        output = @($output | ForEach-Object { [string]$_ })
        json = if ($output.Count -gt 0) { [string]($output | Select-Object -Last 1) } else { '' }
    }
}

function Read-JsonPayload {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    return ($Text | ConvertFrom-Json -Depth 32)
}

function Get-OllamaManifestPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Model
    )

    $modelText = $Model.Trim()
    $tag = 'latest'
    $namePart = $modelText
    if ($modelText.Contains(':')) {
        $parts = $modelText.Split(':', 2)
        $namePart = $parts[0]
        $tag = $parts[1]
    }

    $segments = @('manifests', 'registry.ollama.ai')
    $nameSegments = @($namePart -split '/')
    if ($nameSegments.Count -eq 1) {
        $segments += 'library'
        $segments += $nameSegments[0]
    } else {
        $segments += $nameSegments
    }
    $segments += $tag

    $path = $Root
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -match '[\\/:*?"<>|]') {
            return ''
        }
        $path = Join-Path $path $segment
    }
    return $path
}

function Test-OllamaModelManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Model
    )

    $manifestPath = Get-OllamaManifestPath -Root $Root -Model $Model
    return (-not [string]::IsNullOrWhiteSpace($manifestPath) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf))
}

function Add-E2EPreflightCheck {
    param(
        [Parameter(Mandatory = $true)]$Checks,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowEmptyString()][string]$Detail = '',
        [AllowEmptyString()][string]$Action = ''
    )

    $Checks.Add([ordered]@{
        name = $Name
        status = $Status
        detail = $Detail
        action = $Action
    }) | Out-Null
}

function Complete-E2EPreflight {
    param(
        [Parameter(Mandatory = $true)]$Checks,
        [AllowEmptyString()][string]$EndpointValue = ''
    )

    $failures = @($Checks | Where-Object { [string]$_['status'] -eq 'fail' })
    $warnings = @($Checks | Where-Object { [string]$_['status'] -eq 'warn' })
    $payload = [ordered]@{
        status = if ($failures.Count -gt 0) { 'blocked' } elseif ($warnings.Count -gt 0) { 'warn' } else { 'ready' }
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        endpoint = $EndpointValue
        checks = @($Checks)
    }
    $payload | ConvertTo-Json -Depth 16
    if ($failures.Count -gt 0) {
        exit 1
    }
    exit 0
}

$preflightChecks = [System.Collections.Generic.List[object]]::new()

$modelRootOnG = Test-GDrivePath -Path $ModelRoot
Add-E2EPreflightCheck -Checks $preflightChecks -Name 'model_root_on_g_drive' -Status $(if ($modelRootOnG) { 'pass' } else { 'fail' }) -Detail $(if ($modelRootOnG) { 'ModelRoot is on G drive.' } else { 'ModelRoot is not on G drive.' }) -Action $(if ($modelRootOnG) { '' } else { 'Use a G drive model root before pulling or running local models.' })
if (-not $modelRootOnG -and -not $PreflightOnly) {
    Stop-E2E 'ModelRoot must be on G drive so Ollama model cache does not use C drive.'
}

$modelRootAscii = Test-AsciiPath -Path $ModelRoot
Add-E2EPreflightCheck -Checks $preflightChecks -Name 'model_root_ascii' -Status $(if ($modelRootAscii) { 'pass' } else { 'fail' }) -Detail $(if ($modelRootAscii) { 'ModelRoot is ASCII-only.' } else { 'ModelRoot contains non-ASCII characters.' }) -Action $(if ($modelRootAscii) { '' } else { 'Use an ASCII-only G drive model root such as G:\winsmux-local-llm\ollama-models. Windows Ollama can fail to load model blobs from localized paths.' })
if (-not $modelRootAscii -and -not $PreflightOnly) {
    Stop-E2E 'ModelRoot must be ASCII-only on Windows because Ollama can fail to load model blobs from localized paths.'
}

$artifactRootOnG = Test-GDrivePath -Path $ArtifactRoot
Add-E2EPreflightCheck -Checks $preflightChecks -Name 'artifact_root_on_g_drive' -Status $(if ($artifactRootOnG) { 'pass' } else { 'fail' }) -Detail $(if ($artifactRootOnG) { 'ArtifactRoot is on G drive.' } else { 'ArtifactRoot is not on G drive.' }) -Action $(if ($artifactRootOnG) { '' } else { 'Use a G drive artifact root before running local models.' })
if (-not $artifactRootOnG -and -not $PreflightOnly) {
    Stop-E2E 'ArtifactRoot must be on G drive so local LLM artifacts do not use C drive.'
}

$artifactRootAscii = Test-AsciiPath -Path $ArtifactRoot
Add-E2EPreflightCheck -Checks $preflightChecks -Name 'artifact_root_ascii' -Status $(if ($artifactRootAscii) { 'pass' } else { 'fail' }) -Detail $(if ($artifactRootAscii) { 'ArtifactRoot is ASCII-only.' } else { 'ArtifactRoot contains non-ASCII characters.' }) -Action $(if ($artifactRootAscii) { '' } else { 'Use an ASCII-only G drive artifact root such as G:\winsmux-local-llm\artifacts.' })
if (-not $artifactRootAscii -and -not $PreflightOnly) {
    Stop-E2E 'ArtifactRoot must be ASCII-only on Windows because run artifacts are shared across CLI and GUI checks.'
}

$projectRoot = ''
try {
    $projectRoot = (Resolve-Path -LiteralPath $ProjectDir -ErrorAction Stop).Path
    Add-E2EPreflightCheck -Checks $preflightChecks -Name 'project_dir' -Status 'pass' -Detail 'ProjectDir exists.'
} catch {
    Add-E2EPreflightCheck -Checks $preflightChecks -Name 'project_dir' -Status 'fail' -Detail 'ProjectDir does not exist.' -Action 'Pass a winsmux repository root as ProjectDir.'
    if ($PreflightOnly) {
        Complete-E2EPreflight -Checks $preflightChecks -EndpointValue $Endpoint
    }
    Stop-E2E "ProjectDir does not exist: $ProjectDir"
}
$coreScript = Join-Path $projectRoot 'scripts\winsmux-core.ps1'
if (Test-Path -LiteralPath $coreScript -PathType Leaf) {
    Add-E2EPreflightCheck -Checks $preflightChecks -Name 'winsmux_core_script' -Status 'pass' -Detail 'winsmux core script exists.'
} else {
    Add-E2EPreflightCheck -Checks $preflightChecks -Name 'winsmux_core_script' -Status 'fail' -Detail 'winsmux core script is missing.' -Action 'Run the E2E from a winsmux repository checkout.'
}
if (-not (Test-Path -LiteralPath $coreScript -PathType Leaf) -and -not $PreflightOnly) {
    Stop-E2E "winsmux core script not found: $coreScript"
}

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1)
if ($null -eq $pwsh) {
    Add-E2EPreflightCheck -Checks $preflightChecks -Name 'pwsh' -Status 'fail' -Detail 'PowerShell 7 was not found.' -Action 'Install PowerShell 7 or add pwsh to PATH.'
} else {
    Add-E2EPreflightCheck -Checks $preflightChecks -Name 'pwsh' -Status 'pass' -Detail 'PowerShell 7 is available.'
}
if ($null -eq $pwsh -and -not $PreflightOnly) {
    Stop-E2E 'pwsh is required for the local LLM E2E runner.'
}

$ollamaCommand = ''
if (-not [string]::IsNullOrWhiteSpace($OllamaPath)) {
    $ollamaPathExists = $false
    try {
        $ollamaPathExists = Test-Path -LiteralPath $OllamaPath -PathType Leaf -ErrorAction Stop
    } catch {
        Add-E2EPreflightCheck -Checks $preflightChecks -Name 'ollama_command' -Status 'fail' -Detail 'Explicit OllamaPath is not readable.' -Action 'Pass a readable ollama.exe path or add Ollama to PATH.'
        if ($PreflightOnly) {
            Complete-E2EPreflight -Checks $preflightChecks -EndpointValue $Endpoint
        }
        Stop-E2E "OllamaPath is not readable or does not point to a file: $OllamaPath"
    }
    if (-not $ollamaPathExists) {
        Add-E2EPreflightCheck -Checks $preflightChecks -Name 'ollama_command' -Status 'fail' -Detail 'Explicit OllamaPath does not point to a file.' -Action 'Pass a readable ollama.exe path or add Ollama to PATH.'
        if ($PreflightOnly) {
            Complete-E2EPreflight -Checks $preflightChecks -EndpointValue $Endpoint
        }
        Stop-E2E "OllamaPath is not readable or does not point to a file: $OllamaPath"
    }
    $ollamaCommand = (Resolve-Path -LiteralPath $OllamaPath).Path
    Add-E2EPreflightCheck -Checks $preflightChecks -Name 'ollama_command' -Status 'pass' -Detail 'OllamaPath points to a readable executable.'
} else {
    $ollama = (Get-Command ollama -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($null -eq $ollama) {
        Add-E2EPreflightCheck -Checks $preflightChecks -Name 'ollama_command' -Status 'fail' -Detail 'ollama was not found on PATH.' -Action 'Install Ollama, add it to PATH, or pass -OllamaPath.'
        if ($PreflightOnly) {
            Complete-E2EPreflight -Checks $preflightChecks -EndpointValue $Endpoint
        }
        Stop-E2E 'ollama was not found on PATH. Install Ollama, add it to PATH, or pass -OllamaPath before running this E2E.'
    }
    $ollamaCommand = [string]$ollama.Source
    Add-E2EPreflightCheck -Checks $preflightChecks -Name 'ollama_command' -Status 'pass' -Detail 'ollama was found on PATH.'
}

foreach ($path in @($ModelRoot, $ArtifactRoot)) {
    $pathExists = $false
    try {
        $pathExists = Test-Path -LiteralPath $path -PathType Container -ErrorAction Stop
    } catch {
        $pathExists = $false
    }

    $name = if ([string]::Equals($path, $ModelRoot, [System.StringComparison]::OrdinalIgnoreCase)) { 'model_root_exists' } else { 'artifact_root_exists' }
    if ($pathExists) {
        Add-E2EPreflightCheck -Checks $preflightChecks -Name $name -Status 'pass' -Detail "$name directory exists."
    } else {
        Add-E2EPreflightCheck -Checks $preflightChecks -Name $name -Status $(if ($CreateRoots -and -not $PreflightOnly) { 'warn' } else { 'fail' }) -Detail "$name directory does not exist." -Action 'Create the G drive directory before running E2E, or rerun without PreflightOnly and with -CreateRoots.'
        if ($CreateRoots -and -not $PreflightOnly) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        } elseif (-not $PreflightOnly) {
            Stop-E2E "Required G drive directory does not exist: $path. Rerun with -CreateRoots after confirming the path."
        }
    }
}

if (-not $PreflightOnly) {
    $env:OLLAMA_MODELS = $ModelRoot
    $env:WINSMUX_LOCAL_LLM_ARTIFACT_ROOT = $ArtifactRoot
    $env:WINSMUX_OLLAMA_ENDPOINT = $Endpoint
}

try {
    $version = Invoke-RestMethod -Uri "$($Endpoint.TrimEnd('/'))/api/version" -Method Get -TimeoutSec 5
    $versionText = if ($null -ne $version -and $version.PSObject.Properties.Name -contains 'version') { [string]$version.version } else { 'available' }
    Add-E2EPreflightCheck -Checks $preflightChecks -Name 'ollama_endpoint' -Status 'pass' -Detail "Ollama endpoint is available: $versionText"
} catch {
    Add-E2EPreflightCheck -Checks $preflightChecks -Name 'ollama_endpoint' -Status 'fail' -Detail 'Ollama endpoint is not available.' -Action 'Start Ollama after configuring OLLAMA_MODELS to the G drive model root.'
    if ($PreflightOnly) {
        Complete-E2EPreflight -Checks $preflightChecks -EndpointValue $Endpoint
    }
    Stop-E2E "Ollama endpoint is not available at $Endpoint. Start Ollama and retry. $($_.Exception.Message)"
}

if ($PullModels) {
    foreach ($model in @($Worker3Model, $Worker4Model)) {
        & $ollamaCommand pull $model
        if ($LASTEXITCODE -ne 0) {
            Stop-E2E "ollama pull failed for $model"
        }
    }
}

$tags = Invoke-RestMethod -Uri "$($Endpoint.TrimEnd('/'))/api/tags" -Method Get -TimeoutSec 10
$availableModels = @($tags.models | ForEach-Object { [string]$_.name })
foreach ($model in @($Worker3Model, $Worker4Model)) {
    if ($availableModels -notcontains $model) {
        Add-E2EPreflightCheck -Checks $preflightChecks -Name "model_available:$model" -Status 'fail' -Detail 'Model is not available from Ollama.' -Action "Run ollama pull $model after OLLAMA_MODELS points to the G drive model root."
        if ($PreflightOnly) {
            continue
        }
        Stop-E2E "Ollama model is not available: $model. Set OLLAMA_MODELS to the G drive model root and run: ollama pull $model"
    } else {
        Add-E2EPreflightCheck -Checks $preflightChecks -Name "model_available:$model" -Status 'pass' -Detail 'Model is available from Ollama.'
    }
    if (-not (Test-OllamaModelManifest -Root $ModelRoot -Model $model)) {
        Add-E2EPreflightCheck -Checks $preflightChecks -Name "model_manifest_on_g_drive:$model" -Status 'fail' -Detail 'Ollama manifest was not found under the G drive ModelRoot.' -Action 'Restart Ollama after setting OLLAMA_MODELS to the G drive model root, then pull the model again.'
        if ($PreflightOnly) {
            continue
        }
        Stop-E2E "Ollama reports $model as available, but its manifest was not found under the G drive ModelRoot. Quit Ollama, set OLLAMA_MODELS persistently to the G drive model root, restart Ollama, and pull the model again."
    } else {
        Add-E2EPreflightCheck -Checks $preflightChecks -Name "model_manifest_on_g_drive:$model" -Status 'pass' -Detail 'Ollama manifest exists under the G drive ModelRoot.'
    }
}

if ($PreflightOnly) {
    Complete-E2EPreflight -Checks $preflightChecks -EndpointValue $Endpoint
}

if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = 'local-llm-e2e-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
}
$safeRunId = ($RunId -replace '[^A-Za-z0-9_.-]', '-')
$evidenceRoot = Join-Path (Join-Path $projectRoot '.winsmux') (Join-Path 'local-llm-e2e' $safeRunId)
$e2eProjectDir = Join-Path $evidenceRoot 'project'
New-Item -ItemType Directory -Path $e2eProjectDir -Force | Out-Null

@"
agent: ollama
agent-slots:
  - slot-id: worker-3
    runtime-role: worker
    worker-backend: local_llm
    worker-role: consult
    agent: ollama
    model-id: $Worker3Model
    runtime: ollama
    endpoint: $Endpoint
    artifact-root: $ArtifactRoot
    worktree-mode: managed
  - slot-id: worker-4
    runtime-role: worker
    worker-backend: local_llm
    worker-role: consult
    agent: ollama
    model-id: $Worker4Model
    runtime: ollama
    endpoint: $Endpoint
    artifact-root: $ArtifactRoot
    worktree-mode: managed
"@ | Set-Content -LiteralPath (Join-Path $e2eProjectDir '.winsmux.yaml') -Encoding UTF8

$doctor = Invoke-JsonCommand -PwshPath $pwsh.Source -CoreScript $coreScript -Arguments @('workers', 'doctor', '--json', '--project-dir', $e2eProjectDir)
$doctor.output | Set-Content -LiteralPath (Join-Path $evidenceRoot 'doctor-output.txt') -Encoding UTF8
$doctorPayload = Read-JsonPayload -Text $doctor.json
$doctorPayload | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath (Join-Path $evidenceRoot 'doctor.json') -Encoding UTF8
if ($doctor.exit_code -ne 0) {
    Stop-E2E 'winsmux workers doctor failed for the local LLM E2E project.'
}

$statusBefore = Invoke-JsonCommand -PwshPath $pwsh.Source -CoreScript $coreScript -Arguments @('workers', 'status', '--json', '--project-dir', $e2eProjectDir)
$statusBefore.output | Set-Content -LiteralPath (Join-Path $evidenceRoot 'status-before-output.txt') -Encoding UTF8
$statusBeforePayload = Read-JsonPayload -Text $statusBefore.json
$statusBeforePayload | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath (Join-Path $evidenceRoot 'status-before.json') -Encoding UTF8

$workerJobs = @(
    @{ worker = 'worker-3'; run_id = "$safeRunId-worker-3" },
    @{ worker = 'worker-4'; run_id = "$safeRunId-worker-4" }
)
$runIdByWorker = @{}
foreach ($jobSpec in $workerJobs) {
    $runIdByWorker[[string]$jobSpec.worker] = [string]$jobSpec.run_id
}

$jobs = foreach ($jobSpec in $workerJobs) {
    Start-Job -Name ([string]$jobSpec.worker) -ArgumentList $pwsh.Source, $coreScript, $e2eProjectDir, $jobSpec.worker, $Prompt, $jobSpec.run_id -ScriptBlock {
        param($PwshPath, $CoreScript, $ProjectDir, $Worker, $PromptText, $RunId)
        $output = & $PwshPath -NoProfile -File $CoreScript workers exec $Worker --prompt $PromptText --run-id $RunId --json --project-dir $ProjectDir 2>&1
        [PSCustomObject]@{
            worker = $Worker
            run_id = $RunId
            exit_code = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
            output = @($output | ForEach-Object { [string]$_ })
            json = if ($output.Count -gt 0) { [string]($output | Select-Object -Last 1) } else { '' }
        }
    }
}

$null = Wait-Job -Job $jobs -Timeout $WorkerExecTimeoutSeconds
$execResults = @(
    foreach ($job in $jobs) {
        if ($job.State -eq 'Completed') {
            Receive-Job -Job $job
            continue
        }

        $workerName = [string]$job.Name
        $state = [string]$job.State
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            worker = $workerName
            run_id = [string]$runIdByWorker[$workerName]
            exit_code = 124
            output = @("workers exec timed out after $WorkerExecTimeoutSeconds seconds; job state was $state")
            json = ''
            timed_out = $true
            job_state = $state
        }
    }
)
Remove-Job -Job $jobs -Force

$execResults | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath (Join-Path $evidenceRoot 'exec-results.json') -Encoding UTF8
foreach ($result in $execResults) {
    $result.output | Set-Content -LiteralPath (Join-Path $evidenceRoot ("exec-$($result.worker)-output.txt")) -Encoding UTF8
    if ([bool](Get-Member -InputObject $result -Name timed_out -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
        if ([bool]$result.timed_out) {
            Stop-E2E "workers exec timed out for $($result.worker)"
        }
    }
    if ([int]$result.exit_code -ne 0) {
        Stop-E2E "workers exec failed for $($result.worker)"
    }
}

$logPayloads = @()
foreach ($jobSpec in $workerJobs) {
    $logs = Invoke-JsonCommand -PwshPath $pwsh.Source -CoreScript $coreScript -Arguments @('workers', 'logs', $jobSpec.worker, '--run-id', $jobSpec.run_id, '--json', '--project-dir', $e2eProjectDir)
    $logs.output | Set-Content -LiteralPath (Join-Path $evidenceRoot ("logs-$($jobSpec.worker)-output.txt")) -Encoding UTF8
    $logPayloads += [PSCustomObject]@{
        worker = $jobSpec.worker
        exit_code = $logs.exit_code
        payload = Read-JsonPayload -Text $logs.json
    }
    if ($logs.exit_code -ne 0) {
        Stop-E2E "workers logs failed for $($jobSpec.worker)"
    }
}
$logPayloads | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath (Join-Path $evidenceRoot 'logs.json') -Encoding UTF8

$statusAfter = Invoke-JsonCommand -PwshPath $pwsh.Source -CoreScript $coreScript -Arguments @('workers', 'status', '--json', '--project-dir', $e2eProjectDir)
$statusAfter.output | Set-Content -LiteralPath (Join-Path $evidenceRoot 'status-after-output.txt') -Encoding UTF8
$statusAfterPayload = Read-JsonPayload -Text $statusAfter.json
$statusAfterPayload | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath (Join-Path $evidenceRoot 'status-after.json') -Encoding UTF8

$worker3Exec = @($execResults | Where-Object { $_.worker -eq 'worker-3' })[0]
$worker4Exec = @($execResults | Where-Object { $_.worker -eq 'worker-4' })[0]
$worker3Payload = Read-JsonPayload -Text $worker3Exec.json
$worker4Payload = Read-JsonPayload -Text $worker4Exec.json

foreach ($workerPayload in @($worker3Payload, $worker4Payload)) {
    if ($null -eq $workerPayload) {
        Stop-E2E 'workers exec did not return JSON payload.'
    }
    if ([string]$workerPayload.status -ne 'succeeded') {
        Stop-E2E "workers exec returned non-succeeded status: $($workerPayload.status)"
    }
    foreach ($field in @('run_id', 'model_id', 'stdout_log', 'large_artifact')) {
        if ([string]::IsNullOrWhiteSpace([string]$workerPayload.$field)) {
            Stop-E2E "workers exec payload is missing $field for $($workerPayload.run_id)"
        }
    }

    $stdoutPath = Join-Path $e2eProjectDir ([string]$workerPayload.stdout_log)
    if (-not (Test-Path -LiteralPath $stdoutPath -PathType Leaf)) {
        Stop-E2E "workers exec stdout log does not exist for $($workerPayload.run_id)"
    }
    $stdoutText = Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace([string]$stdoutText)) {
        Stop-E2E "workers exec stdout log is empty for $($workerPayload.run_id)"
    }

    $runJsonPath = Join-Path $e2eProjectDir ([string]$workerPayload.run_json)
    if (-not (Test-Path -LiteralPath $runJsonPath -PathType Leaf)) {
        Stop-E2E "workers exec run.json does not exist for $($workerPayload.run_id)"
    }

    $artifactRef = [string]$workerPayload.large_artifact
    if (-not $artifactRef.StartsWith('local_llm_artifacts/', [System.StringComparison]::Ordinal)) {
        Stop-E2E "workers exec large_artifact reference is not a local LLM artifact for $($workerPayload.run_id)"
    }
    $artifactRelativePath = $artifactRef.Substring('local_llm_artifacts/'.Length).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $artifactPath = Join-Path $ArtifactRoot $artifactRelativePath
    if (-not (Test-PathWithinRoot -Path $artifactPath -Root $ArtifactRoot)) {
        Stop-E2E "workers exec large artifact escaped ArtifactRoot for $($workerPayload.run_id)"
    }
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        Stop-E2E "workers exec large artifact does not exist under ArtifactRoot for $($workerPayload.run_id)"
    }
}

foreach ($logRecord in $logPayloads) {
    if ($null -eq $logRecord.payload) {
        Stop-E2E "workers logs returned empty JSON for $($logRecord.worker)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$logRecord.payload.log)) {
        Stop-E2E "workers logs returned empty log for $($logRecord.worker)"
    }
}

$summary = [ordered]@{
    run_id = $safeRunId
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    project_dir = '<repo>/.winsmux/local-llm-e2e/' + $safeRunId + '/project'
    evidence_dir = '<repo>/.winsmux/local-llm-e2e/' + $safeRunId
    model_root_on_g_drive = (Test-GDrivePath -Path $ModelRoot)
    artifact_root_on_g_drive = (Test-GDrivePath -Path $ArtifactRoot)
    endpoint = $Endpoint
    workers = @(
        [ordered]@{ slot = 'worker-3'; model_id = $Worker3Model; status = [string]$worker3Payload.status },
        [ordered]@{ slot = 'worker-4'; model_id = $Worker4Model; status = [string]$worker4Payload.status }
    )
}
$summary | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $evidenceRoot 'summary.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 16
