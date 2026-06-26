[CmdletBinding()]
param(
    [string]$PackPath = 'tasks/cli-bakeoff/v1/benchmark-pack.json',
    [string]$TaskRoot = '',
    [string]$RunDir = '',
    [switch]$RequireCandidateIdentity,
    [string]$ExpectedVersion = '',
    [string]$ExpectedGitHead = '',
    [string]$CandidateDesktopBinary = '',
    [string]$CandidateCliBinary = '',
    [string]$ExpectedDesktopSha256 = '',
    [string]$ExpectedCliSha256 = '',
    [switch]$AllowDirty,
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

function Resolve-BenchmarkPackInput {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [AllowNull()][string]$ExplicitTaskRoot
    )

    $resolvedInput = Resolve-LocalPath $InputPath
    $resolvedTaskRoot = ''

    if (Test-Path -LiteralPath $resolvedInput -PathType Leaf) {
        $resolvedTaskRoot = if ([string]::IsNullOrWhiteSpace($ExplicitTaskRoot)) {
            Split-Path $resolvedInput -Parent
        } else {
            Resolve-LocalPath $ExplicitTaskRoot
        }

        return [pscustomobject]@{
            PackPath = $resolvedInput
            TaskRoot = $resolvedTaskRoot
            Source = 'file'
            Candidates = @($resolvedInput)
        }
    }

    if (Test-Path -LiteralPath $resolvedInput -PathType Container) {
        $candidateRelativePaths = @(
            'benchmark-pack.json',
            'tasks\cli-bakeoff\v1\benchmark-pack.json',
            'cli-bakeoff\v1\benchmark-pack.json',
            'v1\benchmark-pack.json'
        )
        $candidates = @(
            $candidateRelativePaths |
                ForEach-Object { Join-Path $resolvedInput $_ } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                ForEach-Object { [System.IO.Path]::GetFullPath($_) } |
                Sort-Object -Unique
        )

        if ($candidates.Count -eq 1) {
            $resolvedTaskRoot = if ([string]::IsNullOrWhiteSpace($ExplicitTaskRoot)) {
                Split-Path $candidates[0] -Parent
            } else {
                Resolve-LocalPath $ExplicitTaskRoot
            }

            return [pscustomobject]@{
                PackPath = $candidates[0]
                TaskRoot = $resolvedTaskRoot
                Source = 'directory'
                Candidates = @($candidates)
            }
        }

        return [pscustomobject]@{
            PackPath = $resolvedInput
            TaskRoot = if ([string]::IsNullOrWhiteSpace($ExplicitTaskRoot)) { $resolvedInput } else { Resolve-LocalPath $ExplicitTaskRoot }
            Source = 'directory-unresolved'
            Candidates = @($candidates)
        }
    }

    return [pscustomobject]@{
        PackPath = $resolvedInput
        TaskRoot = if ([string]::IsNullOrWhiteSpace($ExplicitTaskRoot)) { Split-Path $resolvedInput -Parent } else { Resolve-LocalPath $ExplicitTaskRoot }
        Source = 'missing'
        Candidates = @()
    }
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

function Get-GitOutput {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    try {
        return (& git -C $RepoRoot @Arguments 2>$null | Out-String).Trim()
    } catch {
        return ''
    }
}

function Get-FileProductVersion {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    try {
        return [string]([System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path).ProductVersion)
    } catch {
        return ''
    }
}

function Get-FileSha256 {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    try {
        return [string]((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).ToLowerInvariant()
    } catch {
        return ''
    }
}

function Get-CliReportedVersion {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    try {
        $output = (& $Path --version 2>&1 | Out-String).Trim()
        $match = [regex]::Match($output, '(\d+\.\d+\.\d+)')
        if ($match.Success) {
            return $match.Groups[1].Value
        }
        return $output
    } catch {
        return ''
    }
}

function Get-ProjectVersionMetadata {
    $versionPath = Join-Path $RepoRoot 'VERSION'
    $cargoPath = Join-Path $RepoRoot 'core\Cargo.toml'
    $tauriConfigPath = Join-Path $RepoRoot 'winsmux-app\src-tauri\tauri.conf.json'

    $version = if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
        (Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
    } else {
        ''
    }

    $cargoVersion = ''
    if (Test-Path -LiteralPath $cargoPath -PathType Leaf) {
        $cargoText = Get-Content -LiteralPath $cargoPath -Raw -Encoding UTF8
        $match = [regex]::Match($cargoText, '(?m)^\s*version\s*=\s*"([^"]+)"')
        if ($match.Success) {
            $cargoVersion = $match.Groups[1].Value
        }
    }

    $tauriVersion = ''
    if (Test-Path -LiteralPath $tauriConfigPath -PathType Leaf) {
        try {
            $tauriConfig = Get-Content -LiteralPath $tauriConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
            $tauriVersion = [string]$tauriConfig.version
        } catch {
            $tauriVersion = ''
        }
    }

    return [pscustomobject]@{
        VERSION    = $version
        CargoToml  = $cargoVersion
        TauriConf  = $tauriVersion
    }
}

function Test-VersionSetMatches {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    if ([string]::IsNullOrWhiteSpace($Expected)) {
        return $false
    }
    return [string]$Metadata.VERSION -eq $Expected -and
        [string]$Metadata.CargoToml -eq $Expected -and
        [string]$Metadata.TauriConf -eq $Expected
}

$checks = [System.Collections.Generic.List[object]]::new()
$resolvedPackInput = Resolve-BenchmarkPackInput -InputPath $PackPath -ExplicitTaskRoot $TaskRoot
$resolvedPackPath = [string]$resolvedPackInput.PackPath
$resolvedTaskRoot = [string]$resolvedPackInput.TaskRoot

Add-Check 'benchmark pack exists' (Test-Path -LiteralPath $resolvedPackPath -PathType Leaf) $resolvedPackPath
Add-Check 'benchmark pack input resolves unambiguously' (
    [string]$resolvedPackInput.Source -ne 'directory-unresolved'
) "source=$($resolvedPackInput.Source); candidates=$(@($resolvedPackInput.Candidates).Count)"

if ($RequireCandidateIdentity) {
    $actualHead = Get-GitOutput -Arguments @('rev-parse', 'HEAD')
    $statusShort = Get-GitOutput -Arguments @('status', '--porcelain')
    $versionMetadata = Get-ProjectVersionMetadata
    $resolvedDesktopBinary = if ([string]::IsNullOrWhiteSpace($CandidateDesktopBinary)) { '' } else { Resolve-LocalPath $CandidateDesktopBinary }
    $resolvedCliBinary = if ([string]::IsNullOrWhiteSpace($CandidateCliBinary)) { '' } else { Resolve-LocalPath $CandidateCliBinary }
    $desktopBinaryExists = -not [string]::IsNullOrWhiteSpace($resolvedDesktopBinary) -and (Test-Path -LiteralPath $resolvedDesktopBinary -PathType Leaf)
    $cliBinaryExists = -not [string]::IsNullOrWhiteSpace($resolvedCliBinary) -and (Test-Path -LiteralPath $resolvedCliBinary -PathType Leaf)
    $desktopProductVersion = Get-FileProductVersion -Path $resolvedDesktopBinary
    $desktopSha256 = Get-FileSha256 -Path $resolvedDesktopBinary
    $cliReportedVersion = Get-CliReportedVersion -Path $resolvedCliBinary
    $cliSha256 = Get-FileSha256 -Path $resolvedCliBinary
    $expectedHeadMatches = -not [string]::IsNullOrWhiteSpace($ExpectedGitHead) -and
        -not [string]::IsNullOrWhiteSpace($actualHead) -and
        $actualHead.StartsWith($ExpectedGitHead, [System.StringComparison]::OrdinalIgnoreCase)

    Add-Check 'candidate expected version is present' (-not [string]::IsNullOrWhiteSpace($ExpectedVersion)) $ExpectedVersion
    Add-Check 'candidate expected git head is present' (-not [string]::IsNullOrWhiteSpace($ExpectedGitHead)) $ExpectedGitHead
    Add-Check 'candidate git head matches expected' $expectedHeadMatches "actual=$actualHead expected=$ExpectedGitHead"
    Add-Check 'candidate worktree is clean' ([bool]$AllowDirty -or [string]::IsNullOrWhiteSpace($statusShort)) $statusShort
    Add-Check 'candidate version metadata matches expected' (Test-VersionSetMatches -Metadata $versionMetadata -Expected $ExpectedVersion) (
        "VERSION=$($versionMetadata.VERSION); Cargo.toml=$($versionMetadata.CargoToml); tauri.conf.json=$($versionMetadata.TauriConf); expected=$ExpectedVersion"
    )
    Add-Check 'candidate desktop binary path is provided' (-not [string]::IsNullOrWhiteSpace($resolvedDesktopBinary))
    Add-Check 'candidate desktop binary exists' $desktopBinaryExists $resolvedDesktopBinary
    Add-Check 'candidate desktop binary version matches expected' (
        $desktopBinaryExists -and
        -not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and
        [string]$desktopProductVersion -eq $ExpectedVersion
    ) "ProductVersion=$desktopProductVersion expected=$ExpectedVersion"
    Add-Check 'candidate desktop binary sha256 is readable' (
        $desktopBinaryExists -and -not [string]::IsNullOrWhiteSpace($desktopSha256)
    ) "sha256=$desktopSha256"
    if (-not [string]::IsNullOrWhiteSpace($ExpectedDesktopSha256)) {
        Add-Check 'candidate desktop binary sha256 matches expected' (
            -not [string]::IsNullOrWhiteSpace($desktopSha256) -and
            [string]$desktopSha256 -eq [string]$ExpectedDesktopSha256.ToLowerInvariant()
        ) "actual=$desktopSha256 expected=$ExpectedDesktopSha256"
    }
    Add-Check 'candidate CLI binary path is provided' (-not [string]::IsNullOrWhiteSpace($resolvedCliBinary))
    Add-Check 'candidate CLI binary exists' $cliBinaryExists $resolvedCliBinary
    Add-Check 'candidate CLI reported version matches expected' (
        $cliBinaryExists -and
        -not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and
        [string]$cliReportedVersion -eq $ExpectedVersion
    ) "reported=$cliReportedVersion expected=$ExpectedVersion"
    Add-Check 'candidate CLI binary sha256 is readable' (
        $cliBinaryExists -and -not [string]::IsNullOrWhiteSpace($cliSha256)
    ) "sha256=$cliSha256"
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCliSha256)) {
        Add-Check 'candidate CLI binary sha256 matches expected' (
            -not [string]::IsNullOrWhiteSpace($cliSha256) -and
            [string]$cliSha256 -eq [string]$ExpectedCliSha256.ToLowerInvariant()
        ) "actual=$cliSha256 expected=$ExpectedCliSha256"
    }
}

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
    $scoredWorkerRoles = @($workers | Where-Object { [bool]$_.scored } | ForEach-Object { [string]$_.role } | Sort-Object -Unique)
    Add-Check 'scored workers share one Harness Bench role' (
        $scoredWorkerRoles.Count -eq 1 -and $scoredWorkerRoles[0] -eq 'harness-bench-worker'
    ) ($scoredWorkerRoles -join ',')
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
    pack_path    = ConvertTo-SafeDetail $resolvedPackPath
    task_root    = ConvertTo-SafeDetail $resolvedTaskRoot
    pack_source  = [string]$resolvedPackInput.Source
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
