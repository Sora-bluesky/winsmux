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

if ($workflow -notmatch 'desktop-debug-process') {
    throw 'Workflow does not reference desktop-debug-process.'
}
if ($workflow -notmatch 'run-pester-shard\.ps1') {
    throw 'Workflow does not invoke scripts/run-pester-shard.ps1.'
}

$tracked = @(
    & git -C $repositoryRoot ls-files -- 'tests/**/*.Tests.ps1' |
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