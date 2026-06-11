param(
    [Parameter(Mandatory = $true)][string]$RunDir,
    [switch]$RequirePreflight,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Read-BakeoffJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
}

function Get-BakeoffSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

$resolvedRunDir = (Resolve-Path -LiteralPath $RunDir).Path
$requiredFiles = @(
    'manifest.json',
    'task-packet.md',
    'worker-spec.json',
    'operator-start.ps1',
    'recording-ready-checklist.md',
    'screen-recording.json',
    'scorecard.md'
)

$fileChecks = @($requiredFiles | ForEach-Object {
    $path = Join-Path $resolvedRunDir $_
    [ordered]@{
        file   = $_
        passed = (Test-Path -LiteralPath $path -PathType Leaf)
        path   = $path
    }
})

$manifestPath = Join-Path $resolvedRunDir 'manifest.json'
$manifest = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    Read-BakeoffJson -Path $manifestPath
} else {
    $null
}

$taskHash = Get-BakeoffSha256 -Path (Join-Path $resolvedRunDir 'task-packet.md')
$workerHashChecks = @()
if ($null -ne $manifest -and $null -ne $manifest.active_workers) {
    $workerHashChecks = @($manifest.active_workers | ForEach-Object {
        $workerHash = [string]$_.task_sha256
        [ordered]@{
            pane          = [string]$_.pane
            cli           = [string]$_.cli
            effort        = [string]$_.effort
            display_model = [string]$_.display_model
            passed        = (-not [string]::IsNullOrWhiteSpace($taskHash) -and [string]::Equals($workerHash, $taskHash, [System.StringComparison]::OrdinalIgnoreCase))
            expected      = $taskHash
            actual        = $workerHash
        }
    })
}

$preflightPath = Join-Path $resolvedRunDir 'preflight.json'
$preflight = if (Test-Path -LiteralPath $preflightPath -PathType Leaf) {
    Read-BakeoffJson -Path $preflightPath
} else {
    $null
}
$preflightPassed = if ($RequirePreflight) {
    ($null -ne $preflight -and [bool]$preflight.all_pass)
} else {
    ($null -eq $preflight -or [bool]$preflight.all_pass)
}

$fileChecksPassed = -not [bool](@($fileChecks | Where-Object { -not $_.passed }))
$workerHashesPassed = @($workerHashChecks).Count -gt 0 -and -not [bool](@($workerHashChecks | Where-Object { -not $_.passed }))
$recordingStatus = if ($null -eq $manifest -or $null -eq $manifest.recording) { '' } else { [string]$manifest.recording.status }
$recordingPassed = $recordingStatus -in @('present', 'missing_pending_recording')
$allPass = $fileChecksPassed -and $workerHashesPassed -and $recordingPassed -and $preflightPassed

$report = [ordered]@{
    version             = 1
    run_dir             = $resolvedRunDir
    all_pass            = $allPass
    files               = @($fileChecks)
    task_sha256         = $taskHash
    worker_task_hashes  = @($workerHashChecks)
    recording           = [ordered]@{
        passed = $recordingPassed
        status = $recordingStatus
    }
    preflight           = [ordered]@{
        required = [bool]$RequirePreflight
        present  = ($null -ne $preflight)
        passed   = $preflightPassed
        path     = $preflightPath
    }
}

if ($Json) {
    $report | ConvertTo-Json -Depth 32
} else {
    if ($allPass) {
        Write-Output "CLI bakeoff recording preparation passed: $resolvedRunDir"
    } else {
        Write-Output "CLI bakeoff recording preparation failed: $resolvedRunDir"
        foreach ($file in @($fileChecks | Where-Object { -not $_.passed })) {
            Write-Output ("- missing: {0}" -f $file.file)
        }
        foreach ($worker in @($workerHashChecks | Where-Object { -not $_.passed })) {
            Write-Output ("- worker task hash mismatch: {0}" -f $worker.pane)
        }
        if (-not $recordingPassed) {
            Write-Output "- recording status is not acceptable: $recordingStatus"
        }
        if (-not $preflightPassed) {
            Write-Output '- preflight is missing or failed'
        }
    }
}

if (-not $allPass) {
    exit 1
}
