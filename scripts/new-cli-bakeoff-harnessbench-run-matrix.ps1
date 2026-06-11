param(
    [string]$ProjectDir = (Get-Location).Path,
    [Parameter(Mandatory = $true)][string]$PackPath,
    [string]$MatrixPath = '',
    [string]$DesktopAppVersion = 'unknown',
    [string]$Operator = '',
    [int]$MaxRuns = 0,
    [switch]$SkipExisting,
    [switch]$AllowMissingRecording,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $script:Utf8NoBom
$OutputEncoding = $script:Utf8NoBom

function Write-BakeoffJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 64), $script:Utf8NoBom)
}

function Resolve-BakeoffPath {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDir,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    return (Resolve-Path -LiteralPath (Join-Path $BaseDir $Path)).Path
}

function Get-BakeoffRunDir {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedProjectDir,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    return Join-Path (Join-Path (Join-Path $ResolvedProjectDir '.winsmux') 'evidence\cli-bakeoff') $RunId
}

$resolvedProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
$resolvedPackPath = Resolve-BakeoffPath -BaseDir $resolvedProjectDir -Path $PackPath
$packDir = Split-Path -Parent $resolvedPackPath

if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
    $MatrixPath = Join-Path $packDir 'run-matrix.csv'
}
$resolvedMatrixPath = Resolve-BakeoffPath -BaseDir $resolvedProjectDir -Path $MatrixPath

$rows = @(Import-Csv -LiteralPath $resolvedMatrixPath)
if ($rows.Count -eq 0) {
    throw "Run matrix has no rows: $resolvedMatrixPath"
}

if ($MaxRuns -gt 0) {
    $rows = @($rows | Select-Object -First $MaxRuns)
}

$scriptDir = Split-Path -Parent $PSCommandPath
$benchmarkRunScript = Join-Path $scriptDir 'new-cli-bakeoff-benchmark-run.ps1'
if (-not (Test-Path -LiteralPath $benchmarkRunScript -PathType Leaf)) {
    throw "Missing benchmark run script: $benchmarkRunScript"
}

$created = @()
$skipped = @()
foreach ($row in $rows) {
    $taskId = [string]$row.task_id
    $runId = [string]$row.recommended_run_id
    if ([string]::IsNullOrWhiteSpace($taskId)) {
        throw "Run matrix row is missing task_id: $resolvedMatrixPath"
    }
    if ([string]::IsNullOrWhiteSpace($runId)) {
        throw "Run matrix row is missing recommended_run_id for task: $taskId"
    }

    $runDir = Get-BakeoffRunDir -ResolvedProjectDir $resolvedProjectDir -RunId $runId
    if (Test-Path -LiteralPath $runDir) {
        if ($SkipExisting) {
            $skipped += [ordered]@{
                task_id = $taskId
                run_id  = $runId
                evidence_dir = $runDir
                reason = 'already_exists'
            }
            continue
        }

        throw "Bakeoff run already exists: $runDir"
    }

    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-File',
        $benchmarkRunScript,
        '-ProjectDir',
        $resolvedProjectDir,
        '-PackPath',
        $resolvedPackPath,
        '-TaskId',
        $taskId,
        '-RunId',
        $runId,
        '-DesktopAppVersion',
        $DesktopAppVersion,
        '-Json'
    )
    if (-not [string]::IsNullOrWhiteSpace($Operator)) {
        $arguments += @('-Operator', $Operator)
    }
    if ($AllowMissingRecording) {
        $arguments += '-AllowMissingRecording'
    }

    $jsonText = & pwsh @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create bakeoff run: $runId"
    }

    $created += ($jsonText | ConvertFrom-Json -Depth 64)
}

$output = [ordered]@{
    pack_path = $resolvedPackPath
    matrix_path = $resolvedMatrixPath
    requested_rows = $rows.Count
    created_count = $created.Count
    skipped_count = $skipped.Count
    created = @($created)
    skipped = @($skipped)
}

$summaryPath = Join-Path (Split-Path -Parent $resolvedMatrixPath) 'run-matrix-created.json'
Write-BakeoffJson -Path $summaryPath -Value $output
$output['summary_path'] = $summaryPath

if ($Json) {
    $output | ConvertTo-Json -Depth 64
} else {
    Write-Output "created $($created.Count) HarnessBench-style bakeoff run directories"
    if ($skipped.Count -gt 0) {
        Write-Output "skipped $($skipped.Count) existing run directories"
    }
}
