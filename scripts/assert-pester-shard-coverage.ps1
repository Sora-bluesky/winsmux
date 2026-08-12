#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$WorkflowPath = '.github/workflows/test.yml'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$modulePath = Join-Path $PSScriptRoot 'winsmux-pester.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

$registry = @(Get-WinsmuxPesterShardRegistry)
if ($registry.Count -ne 26) {
    throw "Expected 26 registry rows, found $($registry.Count)."
}

$matrix = @($registry | Where-Object { [string]$_.job_kind -eq 'matrix' })
$desktop = @($registry | Where-Object { [string]$_.job_kind -eq 'Desktop' })
if ($matrix.Count -ne 25) { throw "Expected 25 matrix rows, found $($matrix.Count)." }
if ($desktop.Count -ne 1) { throw "Expected 1 Desktop row, found $($desktop.Count)." }

$workflowFullPath = if ([IO.Path]::IsPathRooted($WorkflowPath)) { $WorkflowPath } else { Join-Path $repositoryRoot $WorkflowPath }
$workflow = Get-Content -LiteralPath $workflowFullPath -Raw -Encoding UTF8

$owners = @{}
$shards = [Collections.Generic.List[object]]::new()
foreach ($row in $registry) {
    $name = [string]$row.shard_id
    $resolved = [Collections.Generic.List[string]]::new()
    foreach ($rel in @([string[]]$row.test_paths)) {
        $full = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $rel))
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Shard '$name' path missing: $rel"
        }
        if ([IO.Path]::GetExtension($full) -ne '.ps1' -or $full -notmatch '\.Tests\.ps1$') {
            throw "Shard '$name' resolved a non-test path: $rel"
        }
        $relative = $rel.Replace('\', '/')
        if ($owners.ContainsKey($relative)) {
            throw "Test file '$relative' belongs to both '$($owners[$relative])' and '$name'."
        }
        $owners[$relative] = $name
        $resolved.Add($full) | Out-Null
    }
    if ($workflow -notmatch [regex]::Escape($name) -and $name -ne 'desktop-debug-process') {
        # matrix IDs must appear; desktop uses fixed id in runner step
        throw "Workflow does not reference shard id '$name'."
    }
    $shards.Add([pscustomobject]@{ Name = $name; Paths = @($resolved.ToArray()) }) | Out-Null
}

# TASK-810: forbid unused matrix full_name; gate matrix paths against registry (Ordinal).
if ($workflow -match '(?m)^\s+full_name\s*:') {
    throw 'Workflow matrix still declares unused full_name; remove it (Pester-native / registry identity owns this surface).'
}
foreach ($row in $matrix) {
    $name = [string]$row.shard_id
    $expectedPaths = (@([string[]]$row.test_paths) -join ';')
    $blockPat = '(?ms)^\s{10}- name:\s+' + [regex]::Escape($name) + '\r?\n(?<body>.*?)(?=^\s{10}- name:|^\s{4}steps:)'
    $bm = [regex]::Match($workflow, $blockPat)
    if (-not $bm.Success) {
        throw "Matrix include block missing for shard '$name'."
    }
    $body = [string]$bm.Groups['body'].Value
    if ($body -match '(?m)^\s+full_name\s*:') {
        throw "Matrix full_name still present for shard '$name'."
    }
    $pm = [regex]::Match($body, '(?m)^\s+paths:\s*(?<value>[^\r\n]+)$')
    if (-not $pm.Success) {
        throw "Matrix paths missing for shard '$name' (local bridge discovery still reads paths; keep aligned with registry)."
    }
    $actualPaths = $pm.Groups['value'].Value.Trim()
    if (-not [System.StringComparer]::Ordinal.Equals($actualPaths, $expectedPaths)) {
        throw "Matrix paths drift for '$name'. matrix='$actualPaths' registry='$expectedPaths'"
    }
    $tm = [regex]::Match($body, '(?m)^\s+timeout_minutes:\s*(?<value>\d+)\s*$')
    if (-not $tm.Success) {
        throw "Matrix timeout_minutes missing for shard '$name'."
    }
    if ([int]$tm.Groups['value'].Value -ne [int]$row.timeout_minutes) {
        throw "Matrix timeout_minutes drift for '$name'. matrix=$($tm.Groups['value'].Value) registry=$($row.timeout_minutes)"
    }
    $rm = [regex]::Match($body, '(?m)^\s+result:\s*(?<value>[^\r\n]+)$')
    if (-not $rm.Success) {
        throw "Matrix result missing for shard '$name'."
    }
    $resultToken = $rm.Groups['value'].Value.Trim().Trim("'", '"')
    $expectedFile = 'test-results-' + $resultToken + '.xml'
    if (-not [System.StringComparer]::Ordinal.Equals($expectedFile, [string]$row.result_file)) {
        throw "Matrix result/file drift for '$name'. matrixResult='$resultToken' registryFile='$([string]$row.result_file)'"
    }
}

if ($workflow -notmatch 'desktop-debug-process') {
    throw 'Workflow does not reference desktop-debug-process.'
}
if ($workflow -notmatch 'run-pester-shard\.ps1') {
    throw 'Workflow does not invoke scripts/run-pester-shard.ps1.'
}

# Root-level tests/*.Tests.ps1 plus nested descendants (git pathspec ** skips zero-depth).
$tracked = @(
    & git -C $repositoryRoot ls-files -- 'tests/*.Tests.ps1' 'tests/**/*.Tests.ps1' |
        ForEach-Object { $_.Replace('\', '/') } |
        Sort-Object -Unique
)
$assigned = @($owners.Keys | Sort-Object -Unique)
$unassigned = @($tracked | Where-Object { $_ -notin $assigned })
$absent = @($assigned | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repositoryRoot ($_ -replace '/', [IO.Path]::DirectorySeparatorChar)) -PathType Leaf) })
if ($unassigned.Count -gt 0 -or $absent.Count -gt 0) {
    throw "Pester shard coverage mismatch. unassigned=[$($unassigned -join ', ')] absent=[$($absent -join ', ')]"
}

# Bridge subset still reported for compatibility with bridge-* CI gate messaging.
$bridgeShards = @($shards | Where-Object { $_.Name -like 'bridge-*' })
if ($bridgeShards.Count -ne 13) {
    throw "Expected 13 bridge CI shards, found $($bridgeShards.Count)."
}

[pscustomobject]@{
    status = 'covered'
    shardCount = $shards.Count
    matrixCount = $matrix.Count
    desktopCount = $desktop.Count
    fileCount = $assigned.Count
    bridgeShardCount = $bridgeShards.Count
    shards = @($shards)
} | ConvertTo-Json -Depth 5