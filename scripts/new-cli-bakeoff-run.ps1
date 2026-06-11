param(
    [string]$ProjectDir = (Get-Location).Path,
    [string]$RunId = '',
    [Parameter(Mandatory = $true)][string]$Cli,
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][string]$TaskClass,
    [string]$TaskAttributesJson = '{}',
    [string]$TaskPacketPath = '',
    [string]$TaskPacketText = '',
    [string]$DesktopAppVersion = 'unknown',
    [string]$Operator = '',
    [string]$RecordingPath = '',
    [switch]$PrivateEvidence,
    [switch]$AllowMissingRecording,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function ConvertTo-BakeoffStableRunId {
    param([string]$Value)

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return ($Value.Trim() -replace '[^A-Za-z0-9._-]', '-')
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return "bakeoff-$timestamp-$suffix"
}

function Get-BakeoffSha256 {
    param([byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

function ConvertTo-BakeoffPsLiteral {
    param([AllowNull()][string]$Value)

    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Write-BakeoffJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $Value | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $Path -Encoding UTF8
}

if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
    throw 'ProjectDir must not be empty.'
}
$resolvedProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path

$taskPacketSource = ''
$taskPacketHash = ''
$taskPacketInlineText = ''
if (-not [string]::IsNullOrWhiteSpace($TaskPacketPath)) {
    $resolvedTaskPacketPath = (Resolve-Path -LiteralPath $TaskPacketPath).Path
    $taskPacketSource = $resolvedTaskPacketPath
} elseif (-not [string]::IsNullOrWhiteSpace($TaskPacketText)) {
    $taskPacketSource = 'inline'
    $taskPacketInlineText = $TaskPacketText
} else {
    throw 'TaskPacketPath or TaskPacketText is required.'
}

try {
    $taskAttributes = $TaskAttributesJson | ConvertFrom-Json -Depth 32 -ErrorAction Stop
} catch {
    throw 'TaskAttributesJson must be valid JSON.'
}

$runIdValue = ConvertTo-BakeoffStableRunId -Value $RunId
$runRoot = Join-Path (Join-Path (Join-Path $resolvedProjectDir '.winsmux') 'evidence') 'cli-bakeoff'
$runDir = Join-Path $runRoot $runIdValue
if (Test-Path -LiteralPath $runDir) {
    throw "Bakeoff run already exists: $runDir"
}

New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$taskPacketTargetPath = Join-Path $runDir 'task-packet.md'
if (-not [string]::IsNullOrWhiteSpace($TaskPacketPath)) {
    Copy-Item -LiteralPath $resolvedTaskPacketPath -Destination $taskPacketTargetPath -Force
} else {
    Set-Content -LiteralPath $taskPacketTargetPath -Value $taskPacketInlineText -Encoding UTF8
}
$taskPacketHash = Get-BakeoffSha256 -Bytes ([System.IO.File]::ReadAllBytes($taskPacketTargetPath))

$scriptDir = Split-Path -Parent $PSCommandPath
$workerRunnerPath = Join-Path $scriptDir 'invoke-cli-bakeoff-worker.ps1'
$workerPaneId = 'worker-1'
$launcherPath = Join-Path $runDir 'run-worker-1.ps1'
$launcherContent = @"
param([int]`$TimeoutSeconds = 900)
`$ErrorActionPreference = 'Stop'
& pwsh -NoLogo -NoProfile -File $(ConvertTo-BakeoffPsLiteral -Value $workerRunnerPath) `
  -ProjectDir $(ConvertTo-BakeoffPsLiteral -Value $resolvedProjectDir) `
  -RunDir $(ConvertTo-BakeoffPsLiteral -Value $runDir) `
  -PaneId $(ConvertTo-BakeoffPsLiteral -Value $workerPaneId) `
  -Cli $(ConvertTo-BakeoffPsLiteral -Value $Cli) `
  -Model $(ConvertTo-BakeoffPsLiteral -Value $Model) `
  -PromptPath $(ConvertTo-BakeoffPsLiteral -Value $taskPacketTargetPath) `
  -TimeoutSeconds `$TimeoutSeconds `
  -Json
"@
Set-Content -LiteralPath $launcherPath -Value $launcherContent -Encoding UTF8
$launcherHash = Get-BakeoffSha256 -Bytes ([System.IO.File]::ReadAllBytes($launcherPath))

$now = (Get-Date).ToUniversalTime().ToString('o')
$recordingStatus = 'missing'
$recordingRelativePath = ''
$recordingSourcePath = ''
if (-not [string]::IsNullOrWhiteSpace($RecordingPath)) {
    $recordingSourcePath = (Resolve-Path -LiteralPath $RecordingPath).Path
    $recordingTargetPath = Join-Path $runDir 'screen-recording.mp4'
    Copy-Item -LiteralPath $recordingSourcePath -Destination $recordingTargetPath -Force
    $recordingStatus = 'present'
    $recordingRelativePath = 'screen-recording.mp4'
} elseif (-not $AllowMissingRecording) {
    throw 'RecordingPath is required unless AllowMissingRecording is set.'
} else {
    $recordingStatus = 'missing_allowed_for_scaffold'
}

$manifest = [ordered]@{
    version             = 1
    run_id              = $runIdValue
    cli                 = $Cli
    model               = $Model
    task_class          = $TaskClass
    task_attributes     = $taskAttributes
    task_packet_hash    = $taskPacketHash
    task_packet_source  = $taskPacketSource
    active_workers      = @(
        [ordered]@{
            pane          = $workerPaneId
            cli           = $Cli
            model         = $Model
            display_model = $Model
            task_sha256   = $taskPacketHash
        }
    )
    launch_scripts      = @(
        [ordered]@{
            name   = [System.IO.Path]::GetFileName($launcherPath)
            sha256 = $launcherHash
        }
    )
    desktop_app_version = $DesktopAppVersion
    operator            = $Operator
    started_at_utc      = $now
    ended_at_utc        = $null
    evidence_dir        = $runDir
    recording           = [ordered]@{
        required          = $true
        status            = $recordingStatus
        path              = $recordingRelativePath
        private_evidence  = [bool]$PrivateEvidence
        publishable       = (-not [bool]$PrivateEvidence -and $recordingStatus -eq 'present')
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
    target_windows    = @('winsmux desktop app', 'operator pane', 'worker panes', 'Agent Vault', 'status bar')
    private_evidence  = [bool]$PrivateEvidence
    publishable       = (-not [bool]$PrivateEvidence -and $recordingStatus -eq 'present')
    redaction         = [ordered]@{
        required = [bool]$PrivateEvidence
        notes    = ''
    }
}

$result = [ordered]@{
    version           = 1
    run_id            = $runIdValue
    cli               = $Cli
    model             = $Model
    task_class        = $TaskClass
    scores            = [ordered]@{
        accuracy        = $null
        review_findings = $null
        speed           = $null
        parallelism     = $null
        async_terminal  = $null
        evidence_quality = $null
        overall         = $null
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
    review_counts      = [ordered]@{
        P0 = 0
        P1 = 0
        P2 = 0
        P3 = 0
    }
    caps               = @()
    derived_metrics    = [ordered]@{
        quality_efficiency  = $null
        operator_efficiency = $null
        review_resistance   = $null
        resource_efficiency = $null
        stability           = $null
    }
    verdict            = 'pending'
}

$scorecard = @"
# CLI Bakeoff Scorecard

Run: ``$runIdValue``

| CLI | Model | Task class | Accuracy | Review findings | Speed | Parallelism | Async terminal | Evidence | Overall | Verdict |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| $Cli | $Model | $TaskClass |  |  |  |  |  |  |  | pending |

## Recording

- Required: yes
- Status: $recordingStatus
- Private evidence: $([bool]$PrivateEvidence)

## Notes

- Fill this after Codex review, cross-family review, and rule-based checks.
- Do not publish raw recordings that contain secrets, account-specific quota, or non-public operating details.
"@

Write-BakeoffJson -Path (Join-Path $runDir 'manifest.json') -Value $manifest
Write-BakeoffJson -Path (Join-Path $runDir 'screen-recording.json') -Value $recording
Write-BakeoffJson -Path (Join-Path $runDir 'result.json') -Value $result
Set-Content -LiteralPath (Join-Path $runDir 'scorecard.md') -Value $scorecard -Encoding UTF8
Set-Content -LiteralPath (Join-Path $runDir 'pane-transcript.txt') -Value '' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $runDir 'commands.jsonl') -Value '' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $runDir 'resource-samples.jsonl') -Value '' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $runDir 'review-findings.jsonl') -Value '' -Encoding UTF8

$output = [ordered]@{
    run_id       = $runIdValue
    evidence_dir = $runDir
    manifest     = Join-Path $runDir 'manifest.json'
    recording    = Join-Path $runDir 'screen-recording.json'
    scorecard    = Join-Path $runDir 'scorecard.md'
}

if ($Json) {
    $output | ConvertTo-Json -Depth 8
} else {
    Write-Output "created CLI bakeoff run: $runDir"
}
