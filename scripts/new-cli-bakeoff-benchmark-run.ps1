param(
    [string]$ProjectDir = (Get-Location).Path,
    [string]$PackPath = '',
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$RunId = '',
    [string]$DesktopAppVersion = 'unknown',
    [string]$Operator = '',
    [string]$RecordingPath = '',
    [switch]$PrivateEvidence,
    [switch]$AllowMissingRecording,
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

function Get-BakeoffSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function ConvertTo-BakeoffPsLiteral {
    param([AllowNull()][string]$Value)

    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function ConvertTo-BakeoffStableRunId {
    param(
        [string]$Value,
        [string]$PackId,
        [string]$TaskId
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return ($Value.Trim() -replace '[^A-Za-z0-9._-]', '-')
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $prefix = if ([string]::IsNullOrWhiteSpace($PackId)) { 'bakeoff' } else { $PackId }
    return (($prefix, $TaskId, $timestamp) -join '-') -replace '[^A-Za-z0-9._-]', '-'
}

function Resolve-BakeoffPackPath {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedProjectDir,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path $ResolvedProjectDir 'tasks\cli-bakeoff\v1\benchmark-pack.json'
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    return (Resolve-Path -LiteralPath (Join-Path $ResolvedProjectDir $Path)).Path
}

function Resolve-BakeoffTaskPacketPath {
    param(
        [Parameter(Mandatory = $true)][string]$PackDir,
        [Parameter(Mandatory = $true)][string]$PacketPath
    )

    if ([System.IO.Path]::IsPathRooted($PacketPath)) {
        return (Resolve-Path -LiteralPath $PacketPath).Path
    }

    return (Resolve-Path -LiteralPath (Join-Path $PackDir $PacketPath)).Path
}

function Get-BakeoffObjectString {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $Object) {
        return ''
    }

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            $value = [string]$property.Value
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value.Trim()
            }
        }
    }

    return ''
}

function Get-BakeoffObjectBool {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [bool]$Default = $false
    )

    if ($null -eq $Object) {
        return $Default
    }

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            if ($property.Value -is [bool]) {
                return [bool]$property.Value
            }

            $value = ([string]$property.Value).Trim()
            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            if ($value -match '^(?i:true|1|yes|y)$') {
                return $true
            }
            if ($value -match '^(?i:false|0|no|n)$') {
                return $false
            }
        }
    }

    return $Default
}

function Get-BakeoffStringSha256 {
    param([AllowNull()][string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $script:Utf8NoBom.GetBytes([string]$Value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function ConvertTo-BakeoffRepoCacheName {
    param([Parameter(Mandatory = $true)][string]$Repo)

    $name = $Repo.Trim()
    $name = $name -replace '^[A-Za-z][A-Za-z0-9+.-]*://', ''
    $name = $name -replace '\.git$', ''
    $name = $name -replace '[:/\\]+', '-'
    $name = ($name -replace '[^A-Za-z0-9._-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = 'repo'
    }
    if ($name.Length -gt 48) {
        $name = $name.Substring($name.Length - 48)
    }

    $hash = (Get-BakeoffStringSha256 -Value $Repo).Substring(0, 12)
    return "$name-$hash"
}

function Invoke-BakeoffGit {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = ''
    )

    $oldPrompt = $env:GIT_TERMINAL_PROMPT
    try {
        $env:GIT_TERMINAL_PROMPT = '0'
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $output = & git @Arguments 2>&1
        } else {
            $output = & git -C $WorkingDirectory @Arguments 2>&1
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $env:GIT_TERMINAL_PROMPT = $oldPrompt
    }

    if ($exitCode -ne 0) {
        $text = [string]::Join("`n", @($output))
        throw "git $($Arguments -join ' ') failed with exit code ${exitCode}: $text"
    }

    return @($output)
}

function Test-BakeoffGitCommitExists {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string]$Commitish
    )

    try {
        Invoke-BakeoffGit -WorkingDirectory $RepositoryPath -Arguments @('cat-file', '-e', "$Commitish^{commit}") | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Initialize-BakeoffRepositoryCache {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedProjectDir,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$BaseRef
    )

    $cacheName = ConvertTo-BakeoffRepoCacheName -Repo $Repo
    $cacheRoot = Join-Path (Join-Path (Join-Path $ResolvedProjectDir '.winsmux') 'private') 'cli-bakeoff\repo-cache'
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    $cachePath = Join-Path $cacheRoot "$cacheName.git"

    if (-not (Test-Path -LiteralPath $cachePath -PathType Container)) {
        Invoke-BakeoffGit -Arguments @('clone', '--mirror', $Repo, $cachePath) | Out-Null
    } elseif (-not (Test-BakeoffGitCommitExists -RepositoryPath $cachePath -Commitish $BaseRef)) {
        Invoke-BakeoffGit -WorkingDirectory $cachePath -Arguments @('remote', 'update', '--prune') | Out-Null
    }

    if (-not (Test-BakeoffGitCommitExists -RepositoryPath $cachePath -Commitish $BaseRef)) {
        throw "Base ref was not found in cached repository: $BaseRef"
    }

    return [ordered]@{
        repo       = $Repo
        base_ref   = $BaseRef
        cache_name = $cacheName
        cache_path = $cachePath
    }
}

function New-BakeoffWorkerWorkspace {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$SafePane,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$BaseRef,
        [Parameter(Mandatory = $true)][string]$CachePath,
        [bool]$UpdateSubmodules = $false
    )

    New-Item -ItemType Directory -Path $WorkspaceRoot -Force | Out-Null
    $workspacePath = Join-Path $WorkspaceRoot $SafePane
    if (Test-Path -LiteralPath $workspacePath) {
        throw "Worker workspace already exists: $workspacePath"
    }

    try {
        Invoke-BakeoffGit -Arguments @('clone', '--shared', '--no-checkout', $CachePath, $workspacePath) | Out-Null
        Invoke-BakeoffGit -WorkingDirectory $workspacePath -Arguments @('config', 'core.longpaths', 'true') | Out-Null
        Invoke-BakeoffGit -WorkingDirectory $workspacePath -Arguments @('-c', 'core.longpaths=true', 'checkout', '--detach', $BaseRef) | Out-Null

        $gitmodulesPath = Join-Path $workspacePath '.gitmodules'
        if ($UpdateSubmodules -and (Test-Path -LiteralPath $gitmodulesPath -PathType Leaf)) {
            Invoke-BakeoffGit -WorkingDirectory $workspacePath -Arguments @('-c', 'core.longpaths=true', 'submodule', 'update', '--init', '--recursive', '--depth', '1') | Out-Null
        }
    } catch {
        if (Test-Path -LiteralPath $workspacePath) {
            Remove-Item -LiteralPath $workspacePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }

    $head = [string]((Invoke-BakeoffGit -WorkingDirectory $workspacePath -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1))
    return [ordered]@{
        pane      = $SafePane
        path      = $workspacePath
        repo      = $Repo
        base_ref  = $BaseRef
        head      = $head.Trim()
        cache     = $CachePath
    }
}

$resolvedProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
$resolvedPackPath = Resolve-BakeoffPackPath -ResolvedProjectDir $resolvedProjectDir -Path $PackPath
$packDir = Split-Path -Parent $resolvedPackPath
$pack = Get-Content -LiteralPath $resolvedPackPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
$task = @($pack.tasks | Where-Object { [string]$_.task_id -eq $TaskId } | Select-Object -First 1)
if (@($task).Count -eq 0) {
    throw "TaskId was not found in benchmark pack: $TaskId"
}
$task = $task[0]

$workers = @($pack.default_workers)
if ($workers.Count -eq 0) {
    throw 'benchmark pack must define default_workers.'
}

$paneNames = @($workers | ForEach-Object { [string]$_.pane })
if (($paneNames | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw 'default_workers must define pane for every worker.'
}
if (@($paneNames | Select-Object -Unique).Count -ne $paneNames.Count) {
    throw 'default_workers must use unique pane names.'
}

$runIdValue = ConvertTo-BakeoffStableRunId -Value $RunId -PackId ([string]$pack.pack_id) -TaskId $TaskId
$runRoot = Join-Path (Join-Path (Join-Path $resolvedProjectDir '.winsmux') 'evidence') 'cli-bakeoff'
$runDir = Join-Path $runRoot $runIdValue
if (Test-Path -LiteralPath $runDir) {
    throw "Bakeoff run already exists: $runDir"
}
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$packetSourcePath = Resolve-BakeoffTaskPacketPath -PackDir $packDir -PacketPath ([string]$task.packet_path)
$taskPacketTargetPath = Join-Path $runDir 'task-packet.md'
Copy-Item -LiteralPath $packetSourcePath -Destination $taskPacketTargetPath -Force
$taskPacketHash = Get-BakeoffSha256 -Path $taskPacketTargetPath

$packTargetPath = Join-Path $runDir 'benchmark-pack.json'
Copy-Item -LiteralPath $resolvedPackPath -Destination $packTargetPath -Force
Write-BakeoffJson -Path (Join-Path $runDir 'selected-task.json') -Value $task

$taskRepo = Get-BakeoffObjectString -Object $task.attributes -Names @('repo', 'repository', 'repository_url')
$taskBaseRef = Get-BakeoffObjectString -Object $task.attributes -Names @('base_ref', 'baseRef', 'base_commit', 'baseCommit')
$taskUpdateSubmodules = Get-BakeoffObjectBool -Object $task.attributes -Names @('update_submodules', 'submodules', 'recursive_submodules') -Default $false
$usesIsolatedWorkspaces = (-not [string]::IsNullOrWhiteSpace($taskRepo) -or -not [string]::IsNullOrWhiteSpace($taskBaseRef))
if ($usesIsolatedWorkspaces -and ([string]::IsNullOrWhiteSpace($taskRepo) -or [string]::IsNullOrWhiteSpace($taskBaseRef))) {
    throw 'Real-repository bakeoff tasks must define both repo and base_ref.'
}

$repositoryCache = $null
$workspaceRoot = ''
if ($usesIsolatedWorkspaces) {
    $repositoryCache = Initialize-BakeoffRepositoryCache -ResolvedProjectDir $resolvedProjectDir -Repo $taskRepo -BaseRef $taskBaseRef
    $workspaceBase = if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_BAKEOFF_WORKSPACE_ROOT)) {
        $env:WINSMUX_BAKEOFF_WORKSPACE_ROOT
    } elseif (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        Join-Path $env:TEMP 'winsmux-bakeoff-workspaces'
    } else {
        Join-Path (Join-Path (Join-Path $resolvedProjectDir '.winsmux') 'private') 'cli-bakeoff\workspaces'
    }
    $runWorkspaceName = (Get-BakeoffStringSha256 -Value $runDir).Substring(0, 12)
    $workspaceRoot = Join-Path $workspaceBase $runWorkspaceName
}
$workspaceRecords = @()

$scriptDir = Split-Path -Parent $PSCommandPath
$workerRunnerPath = Join-Path $scriptDir 'invoke-cli-bakeoff-worker.ps1'
if (-not (Test-Path -LiteralPath $workerRunnerPath -PathType Leaf)) {
    throw "Missing worker runner: $workerRunnerPath"
}

$launchScripts = @()
$activeWorkers = @()
$workerSpecs = @()
foreach ($worker in $workers) {
    $pane = [string]$worker.pane
    $cli = [string]$worker.cli
    $modelArg = [string]$worker.model
    $effort = [string]$worker.effort
    $displayModel = [string]$worker.display_model
    $commandPath = [string]$worker.commandPath
    if ([string]::IsNullOrWhiteSpace($commandPath)) {
        $commandPath = [string]$worker.command_path
    }
    $commandArgsJson = [string]$worker.commandArgsJson
    if ([string]::IsNullOrWhiteSpace($commandArgsJson)) {
        $commandArgsJson = [string]$worker.command_args_json
    }
    $claudeChannels = @()
    foreach ($propertyName in @('claudeChannels', 'claude_channels')) {
        $property = $worker.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value) {
            $claudeChannels = @($property.Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($displayModel)) {
        $displayModel = $modelArg
    }
    if ([string]::IsNullOrWhiteSpace($cli) -or [string]::IsNullOrWhiteSpace($modelArg)) {
        throw "default worker $pane must define cli and model."
    }
    if ([string]::Equals($cli, 'custom', [System.StringComparison]::OrdinalIgnoreCase) -and [string]::IsNullOrWhiteSpace($commandPath)) {
        throw "custom worker $pane must define commandPath."
    }

    $safePane = ($pane -replace '[^A-Za-z0-9._-]', '-')
    $workerProjectDir = $resolvedProjectDir
    $workerWorkspace = $null
    if ($usesIsolatedWorkspaces) {
        $workerWorkspace = New-BakeoffWorkerWorkspace `
            -WorkspaceRoot $workspaceRoot `
            -SafePane $safePane `
            -Repo $taskRepo `
            -BaseRef $taskBaseRef `
            -CachePath ([string]$repositoryCache.cache_path) `
            -UpdateSubmodules $taskUpdateSubmodules
        $workerProjectDir = [string]$workerWorkspace.path
        $workspaceRecords += $workerWorkspace
    }

    $launcherPath = Join-Path $runDir "run-$safePane.ps1"
    $launcherContent = @"
param([int]`$TimeoutSeconds = $([int]$pack.default_timeout_seconds))
`$ErrorActionPreference = 'Stop'
Write-Output $(ConvertTo-BakeoffPsLiteral -Value "WINSMUX_WORKER_START $pane")
Write-Output $(ConvertTo-BakeoffPsLiteral -Value "WINSMUX_WORKER_CLI $cli")
Write-Output $(ConvertTo-BakeoffPsLiteral -Value "WINSMUX_WORKER_MODEL $displayModel")
Write-Output $(ConvertTo-BakeoffPsLiteral -Value "WINSMUX_WORKER_EFFORT $effort")
Write-Output $(ConvertTo-BakeoffPsLiteral -Value "WINSMUX_WORKER_PROGRESS_NOTE heartbeat lines mean the same child process is still running, not a relaunch")
& pwsh -NoLogo -NoProfile -File $(ConvertTo-BakeoffPsLiteral -Value $workerRunnerPath) ``
  -ProjectDir $(ConvertTo-BakeoffPsLiteral -Value $workerProjectDir) ``
  -RunDir $(ConvertTo-BakeoffPsLiteral -Value $runDir) ``
  -PaneId $(ConvertTo-BakeoffPsLiteral -Value $pane) ``
  -Cli $(ConvertTo-BakeoffPsLiteral -Value $cli) ``
  -Model $(ConvertTo-BakeoffPsLiteral -Value $modelArg) ``
  -Effort $(ConvertTo-BakeoffPsLiteral -Value $effort) ``
  -PromptPath $(ConvertTo-BakeoffPsLiteral -Value $taskPacketTargetPath) ``
  -TimeoutSeconds `$TimeoutSeconds ``
  -Json ``
  -LiveProgress ``
  -LiveProgressIntervalSeconds 60
"@
    if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
        $launcherContent = $launcherContent.TrimEnd() + " ``" + "`n  -CommandPath $(ConvertTo-BakeoffPsLiteral -Value $commandPath)"
    }
if (-not [string]::IsNullOrWhiteSpace($commandArgsJson)) {
    $launcherContent = $launcherContent.TrimEnd() + " ``" + "`n  -CommandArgsJson $(ConvertTo-BakeoffPsLiteral -Value $commandArgsJson)"
}
if (@($claudeChannels).Count -gt 0) {
    $launcherContent = $launcherContent.TrimEnd() + " ``" + "`n  -ClaudeChannels"
    foreach ($claudeChannel in @($claudeChannels)) {
        $launcherContent = $launcherContent.TrimEnd() + " ``" + "`n  $(ConvertTo-BakeoffPsLiteral -Value $claudeChannel)"
    }
}
    $launcherContent = $launcherContent.TrimEnd() + @"

`$resultPath = Join-Path `$PSScriptRoot $(ConvertTo-BakeoffPsLiteral -Value "$safePane-result.json")
if (Test-Path -LiteralPath `$resultPath -PathType Leaf) {
    `$result = Get-Content -LiteralPath `$resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Output ("WINSMUX_WORKER_RESULT {0} status={1} elapsed={2}s" -f $(ConvertTo-BakeoffPsLiteral -Value $pane), `$result.status, `$result.elapsed_seconds)
    `$transcriptPath = Join-Path `$PSScriptRoot ([string]`$result.transcript_file)
    if (Test-Path -LiteralPath `$transcriptPath -PathType Leaf) {
        Write-Output $(ConvertTo-BakeoffPsLiteral -Value "WINSMUX_WORKER_TRANSCRIPT_TAIL $pane")
        Get-Content -LiteralPath `$transcriptPath -Tail 40 -Encoding UTF8
    }
} else {
    Write-Output $(ConvertTo-BakeoffPsLiteral -Value "WINSMUX_WORKER_RESULT_MISSING $pane")
}
"@
    Write-Utf8File -Path $launcherPath -Value $launcherContent
    $launcherHash = Get-BakeoffSha256 -Path $launcherPath

    $launchScripts += [ordered]@{
        name    = [System.IO.Path]::GetFileName($launcherPath)
        sha256  = $launcherHash
        pane    = $pane
        cli     = $cli
        model   = $modelArg
        effort  = $effort
        display_model = $displayModel
    }
    $activeWorkers += [ordered]@{
        pane          = $pane
        role          = [string]$worker.role
        cli           = $cli
        model         = $displayModel
        model_arg     = $modelArg
        effort        = $effort
        display_model = $displayModel
        task_sha256   = $taskPacketHash
        commandPath   = $commandPath
        commandArgsJson = $commandArgsJson
        claude_channels = @($claudeChannels)
        workspace     = $workerProjectDir
        workspace_isolated = [bool]$usesIsolatedWorkspaces
        workspace_repo = $taskRepo
        workspace_base_ref = $taskBaseRef
        workspace_head = if ($null -eq $workerWorkspace) { '' } else { [string]$workerWorkspace.head }
        workspace_update_submodules = [bool]$taskUpdateSubmodules
    }
    $workerSpecs += [ordered]@{
        paneId       = $pane
        role         = [string]$worker.role
        cli          = $cli
        model        = $modelArg
        effort       = $effort
        displayModel = $displayModel
        task_sha256  = $taskPacketHash
        commandPath  = $commandPath
        commandArgsJson = $commandArgsJson
        claudeChannels  = @($claudeChannels)
        workspace    = $workerProjectDir
        workspaceIsolated = [bool]$usesIsolatedWorkspaces
        workspaceRepo = $taskRepo
        workspaceBaseRef = $taskBaseRef
        workspaceHead = if ($null -eq $workerWorkspace) { '' } else { [string]$workerWorkspace.head }
    }
}
Write-BakeoffJson -Path (Join-Path $runDir 'worker-spec.json') -Value @($workerSpecs)

$operatorScriptPath = Join-Path $runDir 'operator-start.ps1'
$operatorLines = @(
    "Write-Output 'WINSMUX_BAKEOFF_READY operator'",
    "Write-Output 'Run ID: $runIdValue'",
    "Write-Output 'Task: $TaskId - $([string]$task.title)'",
    "Write-Output 'Recording must start before worker launch scripts run.'",
    "Write-Output 'The same task-packet.md is assigned to every worker.'"
)
foreach ($script in $launchScripts) {
    $operatorLines += "Write-Output 'Operator -> $($script.pane): .\$($script.name)'"
}
$summaryScriptPath = Join-Path $scriptDir 'summarize-cli-bakeoff.ps1'
$summaryCommand = "pwsh -NoLogo -NoProfile -File $summaryScriptPath -ProjectDir $resolvedProjectDir -RunDir $runDir -Json"
$operatorLines += "Write-Output $(ConvertTo-BakeoffPsLiteral -Value "After workers finish, run: $summaryCommand")"
$operatorLines += "Write-Output 'Keep scorecard.md visible after the summary is generated.'"
Write-Utf8File -Path $operatorScriptPath -Value (($operatorLines -join "`n") + "`n")
$operatorHash = Get-BakeoffSha256 -Path $operatorScriptPath

$recordingStatus = 'missing'
$recordingRelativePath = ''
$recordingSourcePath = ''
if (-not [string]::IsNullOrWhiteSpace($RecordingPath)) {
    $recordingSourcePath = (Resolve-Path -LiteralPath $RecordingPath).Path
    Copy-Item -LiteralPath $recordingSourcePath -Destination (Join-Path $runDir 'screen-recording.mp4') -Force
    $recordingStatus = 'present'
    $recordingRelativePath = 'screen-recording.mp4'
} elseif ($AllowMissingRecording) {
    $recordingStatus = 'missing_pending_recording'
} else {
    throw 'RecordingPath is required unless AllowMissingRecording is set.'
}

$now = (Get-Date).ToUniversalTime().ToString('o')
$manifest = [ordered]@{
    version             = 1
    run_id              = $runIdValue
    cli                 = 'multi-worker'
    model               = 'multi-model'
    task_class          = [string]$task.task_class
    task_attributes     = $task.attributes
    task_packet_hash    = $taskPacketHash
    task_packet_source  = $packetSourcePath
    benchmark_pack      = [ordered]@{
        pack_id       = [string]$pack.pack_id
        version       = $pack.version
        source_path   = $resolvedPackPath
        task_id       = [string]$task.task_id
        review_model  = [string]$pack.review_model
        scoring       = $pack.scoring
        qc_gates      = @($pack.qc_gates)
    }
    active_workers      = @($activeWorkers)
    workspace_setup     = [ordered]@{
        enabled    = [bool]$usesIsolatedWorkspaces
        repo       = $taskRepo
        base_ref   = $taskBaseRef
        cache_path = if ($null -eq $repositoryCache) { '' } else { [string]$repositoryCache.cache_path }
        root       = $workspaceRoot
        update_submodules = [bool]$taskUpdateSubmodules
        workspaces = @($workspaceRecords)
    }
    launch_scripts      = @($launchScripts)
    operator_script     = [ordered]@{
        name   = 'operator-start.ps1'
        sha256 = $operatorHash
        pane   = 'operator'
    }
    desktop_app_version = $DesktopAppVersion
    operator            = $Operator
    started_at_utc      = $now
    ended_at_utc        = $null
    evidence_dir        = $runDir
    recording           = [ordered]@{
        required         = $true
        status           = $recordingStatus
        path             = $recordingRelativePath
        private_evidence = [bool]$PrivateEvidence
        publishable      = (-not [bool]$PrivateEvidence -and $recordingStatus -eq 'present')
    }
}

$recording = [ordered]@{
    version           = 1
    required          = $true
    status            = $recordingStatus
    path              = $recordingRelativePath
    source_path       = $recordingSourcePath
    started_at_utc    = $null
    ended_at_utc      = $null
    resolution        = ''
    target_windows    = @('winsmux desktop app', 'operator pane', 'worker panes', 'status bar')
    private_evidence  = [bool]$PrivateEvidence
    publishable       = (-not [bool]$PrivateEvidence -and $recordingStatus -eq 'present')
    redaction         = [ordered]@{
        required = [bool]$PrivateEvidence
        notes    = ''
    }
}

$scorecardRows = @()
foreach ($worker in $activeWorkers) {
    $scorecardRows += "| $($worker.cli) | $($worker.display_model) | $($worker.effort) | $($task.task_class) |  |  |  |  |  |  |  | pending |"
}
$scorecard = @(
    '# CLI Bakeoff Scorecard',
    '',
    "Run: ``$runIdValue``",
    '',
    "Task: ``$TaskId`` - $([string]$task.title)",
    '',
    '| CLI | Model | Effort | Task class | Accuracy | Review findings | Speed | Parallelism | Async terminal | Evidence | Overall | Verdict |',
    '| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |'
) + $scorecardRows + @(
    '',
    '## Recording',
    '',
    '- Required: yes',
    "- Status: $recordingStatus",
    "- Private evidence: $([bool]$PrivateEvidence)",
    '',
    '## QC',
    '',
    '- Use only workers with `status=completed` for scoring.',
    '- Use `gpt-5.5` for anonymous failure review.',
    '- Keep blocked or empty-output runs as evidence, not as scoreable results.',
    '- Generate the final article report and graph prompts with `summarize-cli-bakeoff.ps1`.',
    '',
    '## Report Requirements',
    '',
    '- Include condition table, pass or completion table, median wall time, timeout count, task-class breakdown, quality-control notes, and cautious interpretation.',
    '- Export chart data for pass rate, wall time, score vector, task-class heatmap, and speed-quality scatter.',
    '- Use the generated `gpt-image-2-chart-prompts.md` when producing high-quality charts with GPT image 2.0.',
    ''
)

$checklist = @(
    '# Recording Readiness Checklist',
    '',
    "Run: ``$runIdValue``",
    "Task: ``$TaskId``",
    '',
    '## Before Recording',
    '',
    '- [ ] winsmux desktop app is visible on the recorded display.',
    '- [ ] Operator pane is visible.',
    '- [ ] Worker panes are visible.',
    '- [ ] `operator-start.ps1` is visible or ready in the operator pane.',
    '- [ ] `preflight.json` has `all_pass=true`.',
    '- [ ] No private account, quota, or token details are visible.',
    '',
    '## Start Sequence',
    '',
    '1. Start the screen recording.',
    '2. Run `operator-start.ps1` in the operator pane so the recording shows the assignments.',
    '3. Launch each `run-worker-*.ps1` script in its matching worker pane.',
    '4. Keep `scorecard.md` visible after the workers finish.',
    "5. Generate ``article-report.md``, ``chart-data.json``, and ``gpt-image-2-chart-prompts.md`` with ``$summaryCommand``.",
    ''
)

$result = [ordered]@{
    version           = 1
    run_id            = $runIdValue
    cli               = 'multi-worker'
    model             = 'multi-model'
    task_class        = [string]$task.task_class
    scores            = [ordered]@{
        accuracy         = $null
        review_findings  = $null
        speed            = $null
        parallelism      = $null
        async_terminal   = $null
        evidence_quality = $null
        overall          = $null
    }
    capability_vector = [ordered]@{
        quality            = $null
        speed              = $null
        autonomy           = $null
        parallelism        = $null
        terminal_operation = $null
        evidence           = $null
        safety             = $null
        continuity         = $null
    }
    review_counts      = [ordered]@{ P0 = 0; P1 = 0; P2 = 0; P3 = 0 }
    caps               = @()
    derived_metrics    = [ordered]@{}
    verdict            = 'pending'
}

Write-BakeoffJson -Path (Join-Path $runDir 'manifest.json') -Value $manifest
Write-BakeoffJson -Path (Join-Path $runDir 'screen-recording.json') -Value $recording
Write-BakeoffJson -Path (Join-Path $runDir 'result.json') -Value $result
Write-Utf8File -Path (Join-Path $runDir 'scorecard.md') -Value (($scorecard -join "`n") + "`n")
Write-Utf8File -Path (Join-Path $runDir 'recording-ready-checklist.md') -Value (($checklist -join "`n") + "`n")
Write-Utf8File -Path (Join-Path $runDir 'pane-transcript.txt') -Value ''
Write-Utf8File -Path (Join-Path $runDir 'commands.jsonl') -Value ''
Write-Utf8File -Path (Join-Path $runDir 'resource-samples.jsonl') -Value ''
Write-Utf8File -Path (Join-Path $runDir 'review-findings.jsonl') -Value ''

$output = [ordered]@{
    run_id             = $runIdValue
    evidence_dir       = $runDir
    manifest           = Join-Path $runDir 'manifest.json'
    task_packet        = $taskPacketTargetPath
    worker_spec        = Join-Path $runDir 'worker-spec.json'
    operator_start     = $operatorScriptPath
    recording_checklist = Join-Path $runDir 'recording-ready-checklist.md'
    scorecard          = Join-Path $runDir 'scorecard.md'
}

if ($Json) {
    $output | ConvertTo-Json -Depth 8
} else {
    Write-Output "created CLI benchmark recording run: $runDir"
}
