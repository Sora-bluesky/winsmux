#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$WorkflowPath = '.github/workflows/test.yml'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$workflowFullPath = if ([IO.Path]::IsPathRooted($WorkflowPath)) {
    $WorkflowPath
} else {
    Join-Path $repositoryRoot $WorkflowPath
}
$workflow = Get-Content -LiteralPath $workflowFullPath -Raw -Encoding UTF8
$modulePath = Join-Path -Path $repositoryRoot -ChildPath 'scripts\winsmux-pester.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop | Out-Null
$bridgeRegistry = @(
    Get-WinsmuxPesterShardRegistry |
        Where-Object {
            $_.job_kind -eq 'matrix' -and
            $_.shard_id.StartsWith('bridge-', [StringComparison]::Ordinal)
        }
)
if ($bridgeRegistry.Count -ne 13) {
    throw "Expected 13 bridge registry shards, found $($bridgeRegistry.Count)."
}
$workflowMatches = [regex]::Matches(
    $workflow,
    '(?ms)^\s{10}- name:\s+(?<name>bridge-[^\r\n]+)\r?\n(?<body>.*?)(?=^\s{10}- name:|^\s{6}[a-zA-Z_-]+:|\z)'
)
if ($workflowMatches.Count -ne $bridgeRegistry.Count) {
    throw "Expected $($bridgeRegistry.Count) bridge CI shards, found $($workflowMatches.Count)."
}

$owners = @{}
$shards = [Collections.Generic.List[object]]::new()
foreach ($registryShard in $bridgeRegistry) {
    $name = [string]$registryShard.shard_id
    $workflowShard = @($workflowMatches | Where-Object { [StringComparer]::Ordinal.Equals([string]$_.Groups['name'].Value, $name) })
    if ($workflowShard.Count -ne 1) {
        throw "Bridge registry shard '$name' has no unique workflow matrix entry."
    }
    $pathsMatch = [regex]::Match($workflowShard[0].Groups['body'].Value, '(?m)^\s+paths:\s*(?<value>[^\r\n]+)$')
    if (-not $pathsMatch.Success) {
        throw "Bridge shard '$name' has no paths entry."
    }
    $workflowPaths = @($pathsMatch.Groups['value'].Value.Trim().Trim('''', '"') -split ';' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $registryPaths = @($registryShard.paths | ForEach-Object { [string]$_ })
    if (@(Compare-Object -ReferenceObject $registryPaths -DifferenceObject $workflowPaths -SyncWindow 0).Count -ne 0) {
        throw "Bridge shard '$name' workflow paths diverge from the registry."
    }
    $resolved = [Collections.Generic.List[string]]::new()
    foreach ($relative in $registryPaths) {
        $path = Join-Path $repositoryRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Bridge shard '$name' registry path is missing: $relative"
        }
        if ([IO.Path]::GetExtension($path) -ne '.ps1' -or $path -notmatch '\.Tests\.ps1$') {
            throw "Bridge shard '$name' registry path is not a test: $relative"
        }
        if (-not $relative.StartsWith('tests/bridge/', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Bridge shard '$name' registry path is outside tests/bridge: $relative"
        }
        if ($owners.ContainsKey($relative)) {
            throw "Bridge test file '$relative' belongs to both '$($owners[$relative])' and '$name'."
        }
        $owners[$relative] = $name
        $resolved.Add([IO.Path]::GetFullPath($path))
    }
    $shards.Add([pscustomobject]@{ Name = $name; Paths = @($resolved | Sort-Object -Unique) })
}

$actual = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'tests\bridge') -Filter '*.Tests.ps1' -File -Recurse |
    ForEach-Object { [IO.Path]::GetRelativePath($repositoryRoot, $_.FullName).Replace('\', '/') } |
    Sort-Object -Unique)
$assigned = @($owners.Keys | Sort-Object -Unique)
$unassigned = @($actual | Where-Object { $_ -notin $assigned })
$missing = @($assigned | Where-Object { $_ -notin $actual })
if ($unassigned.Count -gt 0 -or $missing.Count -gt 0) {
    throw "Bridge shard coverage mismatch. unassigned=[$($unassigned -join ', ')] missing=[$($missing -join ', ')]"
}

[pscustomobject]@{
    status = 'covered'
    shardCount = $shards.Count
    fileCount = $actual.Count
    shards = @($shards)
} | ConvertTo-Json -Depth 5
