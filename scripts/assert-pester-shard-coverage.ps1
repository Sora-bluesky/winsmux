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
$matches = [regex]::Matches(
    $workflow,
    '(?ms)^\s{10}- name:\s+(?<name>bridge-[^\r\n]+)\r?\n(?<body>.*?)(?=^\s{10}- name:|^\s{6}[a-zA-Z_-]+:|\z)'
)
if ($matches.Count -ne 13) {
    throw "Expected 13 bridge CI shards, found $($matches.Count)."
}

$owners = @{}
$shards = [Collections.Generic.List[object]]::new()
foreach ($match in $matches) {
    $name = [string]$match.Groups['name'].Value
    $pathsMatch = [regex]::Match($match.Groups['body'].Value, '(?m)^\s+paths:\s*(?<value>[^\r\n]+)$')
    if (-not $pathsMatch.Success) {
        throw "Bridge shard '$name' has no paths entry."
    }
    $patterns = @($pathsMatch.Groups['value'].Value.Trim().Trim('''', '"') -split ';' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $resolved = [Collections.Generic.List[string]]::new()
    foreach ($pattern in $patterns) {
        $matchesForPattern = @(Resolve-Path -Path (Join-Path $repositoryRoot $pattern) -ErrorAction Stop |
            ForEach-Object { [IO.Path]::GetFullPath($_.ProviderPath) })
        if ($matchesForPattern.Count -eq 0) {
            throw "Bridge shard '$name' pattern matched no files: $pattern"
        }
        foreach ($path in $matchesForPattern) {
            if ([IO.Path]::GetExtension($path) -ne '.ps1' -or $path -notmatch '\.Tests\.ps1$') {
                throw "Bridge shard '$name' resolved a non-test path: $path"
            }
            $relative = [IO.Path]::GetRelativePath($repositoryRoot, $path).Replace('\', '/')
            if (-not $relative.StartsWith('tests/bridge/', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Bridge shard '$name' resolved outside tests/bridge: $relative"
            }
            if ($owners.ContainsKey($relative)) {
                throw "Bridge test file '$relative' belongs to both '$($owners[$relative])' and '$name'."
            }
            $owners[$relative] = $name
            $resolved.Add($path)
        }
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
