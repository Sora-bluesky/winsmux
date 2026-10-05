param([switch]$Release)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Keep the quoted TOML config argument intact even when the caller uses Legacy.
$PSNativeCommandArgumentPassing = 'Standard'

function Assert-PlainPath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException] { $current = [IO.Path]::GetDirectoryName($current); continue }
        catch [IO.DirectoryNotFoundException] { $current = [IO.Path]::GetDirectoryName($current); continue }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked build/transaction path is unsupported: $current" }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Test-Overlap([string]$A, [string]$B) {
    $left = [IO.Path]::GetFullPath($A).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $right = [IO.Path]::GetFullPath($B).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [string]::Equals($left, $right, $comparison) -or $left.StartsWith($right + [IO.Path]::DirectorySeparatorChar, $comparison) -or $right.StartsWith($left + [IO.Path]::DirectorySeparatorChar, $comparison)
}
function Read-Generation([string]$Root, [switch]$PathsOnly) {
    Assert-PlainPath $Root
    $files = @{}
    if (-not [IO.Directory]::Exists($Root)) { throw "Generation directory missing: $Root" }
    $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($Root)
    while ($pending.Count) {
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Pop())) {
            $attributes = [IO.File]::GetAttributes($entry)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked generation/build entry is unsupported: $entry" }
            $relative = [IO.Path]::GetRelativePath($Root, $entry)
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $files[$relative] = 'directory'; $pending.Push($entry) }
            elseif (-not $PathsOnly) { $files[$relative] = (Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash }
        }
    }
    return ,$files
}
function Assert-Generation([string]$Root, $Expected) {
    $actual = Read-Generation $Root
    if ($actual.Count -ne $Expected.Count) { throw 'Generation entry inventory differs.' }
    foreach ($key in $Expected.Keys) { if (-not $actual.ContainsKey($key) -or $actual[$key] -cne $Expected[$key]) { throw "Generation bytes differ: $key" } }
}
function Publish-Generation([string]$Canonical, [string]$Stage, [string]$Backup, [string]$Barrier) {
    $expected = Read-Generation $Stage
    $original = if ([IO.Directory]::Exists($Canonical)) { Read-Generation $Canonical } else { $null }
    $marker = [IO.File]::Open($Barrier, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes((@{canonical=$Canonical; stage=$Stage; backup=$Backup} | ConvertTo-Json -Compress))
        $marker.Write($bytes); $marker.Flush($true)
    } finally { $marker.Dispose() }
    $parked = $false; $published = $false
    try {
        if ($null -ne $original) { Move-Item -LiteralPath $Canonical -Destination $Backup; $parked = $true }
        Move-Item -LiteralPath $Stage -Destination $Canonical; $published = $true
        Assert-Generation $Canonical $expected
    } catch {
        $publicationError = $_
        try {
            if ($published) { Move-Item -LiteralPath $Canonical -Destination $Stage }
            if ($parked) { Move-Item -LiteralPath $Backup -Destination $Canonical }
            if ($null -ne $original) { Assert-Generation $Canonical $original }
            elseif (Test-Path -LiteralPath $Canonical) { throw 'Initial restoration left canonical binaries.' }
            Remove-Item -LiteralPath $Barrier
        } catch { throw "Companion recovery required; barrier and generations retained: $Barrier. $($_.Exception.Message)" }
        throw $publicationError
    }
    Remove-Item -LiteralPath $Barrier
}

$srcTauriDir = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$repoRoot = Split-Path -Parent (Split-Path -Parent $srcTauriDir)
$environmentProof = @(& node (Join-Path $repoRoot 'scripts/windows-distribution-build.mjs') --check-environment)
if ($LASTEXITCODE -ne 0 -or $environmentProof.Count -ne 1) { throw 'Unsupported companion build environment; no Cargo process was started.' }
$environmentResult = $environmentProof[0] | ConvertFrom-Json
if ($environmentResult.schema -cne 'windows-build-environment/v1' -or $environmentResult.accepted -ne $true) { throw 'Invalid build environment proof.' }
$verified = (& (Join-Path $repoRoot 'scripts/assert-distribution-version.ps1') -RepoRoot $repoRoot -AsJson) | ConvertFrom-Json
$binariesDir = Join-Path $srcTauriDir 'binaries'
$lockPath = Join-Path $srcTauriDir 'binaries.prepare.lock'
$barrierPath = Join-Path $srcTauriDir 'binaries.recovery.pending'
foreach ($path in @($binariesDir, $lockPath, $barrierPath)) { Assert-PlainPath $path }
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    if (Test-Path -LiteralPath $barrierPath) { throw 'Companion recovery required: unresolved generation barrier exists.' }
    if (-not (Test-Path -LiteralPath $binariesDir) -and @(Get-ChildItem -LiteralPath $srcTauriDir -Directory -Filter 'binaries.backup.*').Count -gt 0) {
        throw 'Companion recovery required: canonical binaries is absent and a retained backup exists.'
    }
    # All Cargo write locations were validated before locked resolution began.
    $targetRoot = $verified.build_target_root
    $intermediateRoot = $verified.build_intermediate_root
    if (-not [IO.Path]::IsPathRooted($targetRoot) -or -not [IO.Path]::IsPathRooted($intermediateRoot)) { throw 'Gate did not return absolute Cargo outputs.' }
    $rustVersion = @(& rustc -vV)
    if ($LASTEXITCODE -ne 0) { throw "rustc -vV failed with exit $LASTEXITCODE" }
    $hostLine = @($rustVersion | Select-String -Pattern '^host: ')
    if ($hostLine.Count -ne 1) { throw 'rustc host triple was not available' }
    $hostTriple = $hostLine[0].ToString().Substring(6).Trim()
    if ($hostTriple -notmatch '^[A-Za-z0-9_-]+$') { throw 'rustc host triple was invalid' }
    $commitLine = @($rustVersion | Select-String -Pattern '^commit-hash: [a-f0-9]{40}$')
    if ($commitLine.Count -ne 1) { throw 'rustc commit identity was not available' }
    $rustcCommit = $commitLine[0].ToString().Substring(13).Trim()
    $buildRequest = Join-Path $srcTauriDir ("binaries.buildrequest." + [Guid]::NewGuid().ToString('N') + '.json')
    Assert-PlainPath $buildRequest
    [IO.File]::WriteAllText($buildRequest, (@{repoRoot=$repoRoot; target=$hostTriple;
        targetRoot=$targetRoot; intermediateRoot=$intermediateRoot; companions=$true;
        release=[bool]$Release} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $planOutput = @(& node (Join-Path $repoRoot 'scripts/windows-distribution-build.mjs') $buildRequest)
    if ($LASTEXITCODE -ne 0 -or $planOutput.Count -ne 1) { throw 'Windows companion build policy failed; existing generation is preserved.' }
    $buildPlan = $planOutput[0] | ConvertFrom-Json
    if ($buildPlan.schema -cne 'windows-distribution-build/v1' -or $buildPlan.target -cne $hostTriple -or
        $buildPlan.runtime_policy -cne 'static-crt-os-imports') { throw 'Invalid Windows companion build plan.' }
    $cargoArgs = @($buildPlan.args)
    Push-Location -LiteralPath $repoRoot
    try { $messages = @(& cargo @cargoArgs); $buildExit = $LASTEXITCODE } finally { Pop-Location }
    if ($buildExit -ne 0) { throw "companion cargo build failed with exit $buildExit" }
    $artifacts = @($messages | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object reason -EQ 'compiler-artifact')
    $profile = if ($Release) { 'release' } else { 'debug' }
    $companions = @('winsmux', 'winsmux-workspace-mcp'); $sources = @{}
    foreach ($name in $companions) {
        $package = $verified.public_packages.$name
        $matches = @($artifacts | Where-Object { $_.package_id -ceq $package.id -and $_.target.name -ceq $name -and 'bin' -in $_.target.kind -and $null -ne $_.executable })
        if ($matches.Count -ne 1) { throw "Built companion artifact is missing or ambiguous: $name" }
        $expectedPath = [IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $targetRoot $hostTriple) $profile) "$name.exe"))
        $actualPath = [IO.Path]::GetFullPath($matches[0].executable)
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not [string]::Equals($actualPath, $expectedPath, $comparison) -or -not [IO.File]::Exists($actualPath)) { throw "Built companion artifact path differs: $name" }
        Assert-PlainPath $actualPath
        $runtimeOutput = @(& node (Join-Path $repoRoot 'scripts/assert-windows-runtime.mjs') $actualPath $hostTriple)
        if ($LASTEXITCODE -ne 0 -or $runtimeOutput.Count -ne 1) { throw "Unsupported Windows runtime dependencies: $name" }
        $runtimeProof = $runtimeOutput[0] | ConvertFrom-Json
        if ($runtimeProof.schema -cne 'windows-runtime-proof/v1' -or $runtimeProof.target -cne $hostTriple -or
            $runtimeProof.sha256 -cne (Get-FileHash -LiteralPath $actualPath -Algorithm SHA256).Hash.ToLowerInvariant()) {
            throw "Runtime inspection identity differs: $name"
        }
        $sources[$name] = $actualPath
    }
    $generation = [Guid]::NewGuid().ToString('N')
    $stageDir = Join-Path $srcTauriDir "binaries.stage.$generation"
    $backupDir = Join-Path $srcTauriDir "binaries.backup.$generation"
    if ($Release) {
        # Prepare CLI, MCP, original license texts, covered sources and the owned NSIS inputs
        # as one fresh generation. No old license subtree is copied into the new generation.
        $requestFile = Join-Path $srcTauriDir "binaries.request.$generation.json"
        # Cargo's executable may share an inode with its deps artifact. Freeze read-only
        # build bytes in new single-link inputs before handing them to the strict producer.
        $artifactInputs = Join-Path $srcTauriDir "binaries.inputs.$generation"
        Assert-PlainPath $artifactInputs
        New-Item -ItemType Directory -Path $artifactInputs | Out-Null
        $frozenSources = @{}
        foreach ($name in $companions) {
            $inputFile = Join-Path $artifactInputs "$name.exe"
            $expectedInputHash = (Get-FileHash -LiteralPath $sources[$name] -Algorithm SHA256).Hash
            Copy-Item -LiteralPath $sources[$name] -Destination $inputFile
            if ((Get-FileHash -LiteralPath $inputFile -Algorithm SHA256).Hash -cne $expectedInputHash) {
                throw 'Frozen Cargo executable bytes differ.'
            }
            $frozenSources[$name] = $inputFile
        }
        $request = @{repoRoot=$repoRoot; destination=$stageDir; host=$hostTriple;
            version=$verified.version; rustcCommit=$rustcCommit; companions=@(
                @{name='winsmux'; path=$frozenSources['winsmux']; sha256=(Get-FileHash -LiteralPath $frozenSources['winsmux'] -Algorithm SHA256).Hash.ToLowerInvariant()},
                @{name='winsmux-workspace-mcp'; path=$frozenSources['winsmux-workspace-mcp']; sha256=(Get-FileHash -LiteralPath $frozenSources['winsmux-workspace-mcp'] -Algorithm SHA256).Hash.ToLowerInvariant()})}
        [IO.File]::WriteAllText($requestFile, ($request | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        $stageResult = @(& node (Join-Path $repoRoot 'scripts/stage-bundled-distribution.mjs') $requestFile)
        if ($LASTEXITCODE -ne 0 -or $stageResult.Count -ne 1) { throw 'Licensed distribution preparation failed; existing generation is preserved.' }
        $stageProof = $stageResult[0] | ConvertFrom-Json
        if ($stageProof.status -cne 'distribution_generation_staged' -or $stageProof.distribution_complete -ne $false) {
            throw 'Licensed distribution preparation returned an invalid receipt.'
        }
        if ((Get-FileHash -LiteralPath (Join-Path $stageDir 'distribution-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant() -cne $stageProof.manifest_sha256) {
            throw 'Licensed distribution manifest differs from preparation receipt.'
        }
    } elseif (Test-Path -LiteralPath $binariesDir -PathType Container) {
        [void](Read-Generation $binariesDir)
        Copy-Item -LiteralPath $binariesDir -Destination $stageDir -Recurse
    } else { New-Item -ItemType Directory -Path $stageDir | Out-Null }
    foreach ($name in $companions) {
        $destination = Join-Path $stageDir ("{0}-{1}.exe" -f $name, $hostTriple)
        $expectedHash = (Get-FileHash -LiteralPath $sources[$name] -Algorithm SHA256).Hash
        if (-not $Release) { Copy-Item -LiteralPath $sources[$name] -Destination $destination -Force }
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne $expectedHash) { throw "Companion staging hash differs: $name" }
    }
    # Bridge resources stay in tauri.conf.json; exclude the obsolete flat entry.
    $legacyFlat = Join-Path $stageDir 'winsmux-core.ps1'
    if (Test-Path -LiteralPath $legacyFlat -PathType Leaf) { Remove-Item -LiteralPath $legacyFlat -Force }
    Publish-Generation $binariesDir $stageDir $backupDir $barrierPath
    foreach ($name in $companions) { Write-Host ("prepared companion sidecar " + (Join-Path $binariesDir ("{0}-{1}.exe" -f $name, $hostTriple))) }
} finally { $lock.Dispose() }
