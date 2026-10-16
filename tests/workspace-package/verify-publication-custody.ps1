[CmdletBinding()]
param([Parameter(Mandatory)][string]$OperatorRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Real Windows custody proof required.' }
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixtureOutput = & node (Join-Path $PSScriptRoot 'prepare-publication-custody-fixture.mjs') $OperatorRoot
if ($LASTEXITCODE -ne 0) { throw 'Fixture preparation failed.' }
$fixture = ($fixtureOutput -join "`n") | ConvertFrom-Json
if ($fixture.synthetic -ne $true -or $fixture.publication_admitted -ne $false) { throw 'Unexpected fixture authority.' }
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.evidence/workspace-package')) + [IO.Path]::DirectorySeparatorChar
$bundleRoot = [IO.Path]::GetFullPath($fixture.bundle_root)
if (-not $bundleRoot.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture is outside test workspace.' }
Add-Type -Path (Join-Path $repoRoot 'scripts/IntegratedPublicationCustody.cs')
$checks = 0
function Assert-Check([bool]$Condition, [string]$Reason) {
    if (-not $Condition) { throw $Reason }
    $script:checks++
}
function Assert-SharingRefusal([scriptblock]$Operation, [bool]$DirectoryRename = $false) {
    $denied = $false
    try { & $Operation } catch {
        $errorObject = $_.Exception
        while ($errorObject.InnerException) { $errorObject = $errorObject.InnerException }
        $nativeCode = $errorObject.HResult -band 65535
        if ($errorObject -is [IO.IOException] -and ($nativeCode -eq 32 -or ($DirectoryRename -and $nativeCode -eq 5))) { $denied = $true }
        else { throw }
    }
    Assert-Check $denied 'Expected Windows sharing violation was not observed.'
}
$inventoryName = 'desktop/winsmux_0.38.0_x64-setup.inventory.json'
$inventoryIndex = [Array]::IndexOf([string[]]$fixture.names, $inventoryName)
Assert-Check ($fixture.names.Count -eq 14 -and $inventoryIndex -ge 0) 'Fixed inventory asset missing from issued JS bundle.'
foreach ($replacement in @('', $inventoryName.ToUpperInvariant(),
    'desktop/winsmux_0.38.1_x64-setup.inventory.json', $fixture.names[0], ($inventoryName + ':stream'))) {
    $names = [string[]]$fixture.names.Clone()
    $names[$inventoryIndex] = $replacement
    if ($replacement -ceq '') { $names = [string[]]@($names | Where-Object { $_ -cne '' }) }
    $rejected = $false
    $observedFailure = 'none'
    try { $invalid = [IntegratedPublicationCustody]::new($bundleRoot, $names, [string[]]$fixture.hashes); $invalid.Dispose() }
    catch { $observedFailure = $_.Exception.GetBaseException().Message; $rejected = $observedFailure.Contains('Exact integrated asset paths') }
    Assert-Check $rejected "Native inventory name refusal differed: replacement=[$replacement], failure=[$observedFailure]"
}
$inventoryPath = Join-Path $bundleRoot $inventoryName
$parkedInventory = Join-Path $fixture.fixture_root 'parked-inventory.json'
[IO.File]::Move($inventoryPath, $parkedInventory)
try {
    $rejected = $false
    try { $invalid = [IntegratedPublicationCustody]::new($bundleRoot, [string[]]$fixture.names, [string[]]$fixture.hashes); $invalid.Dispose() }
    catch { $rejected = $_.Exception.ToString().Contains('additional custody assets') }
    Assert-Check $rejected 'Native custody accepted a missing installed inventory asset.'
} finally { [IO.File]::Move($parkedInventory, $inventoryPath) }
$extraInventory = Join-Path $bundleRoot 'desktop/winsmux_0.38.1_x64-setup.inventory.json'
[IO.File]::WriteAllText($extraInventory, 'synthetic unknown sibling')
try {
    $rejected = $false
    try { $invalid = [IntegratedPublicationCustody]::new($bundleRoot, [string[]]$fixture.names, [string[]]$fixture.hashes); $invalid.Dispose() }
    catch { $rejected = $_.Exception.ToString().Contains('additional custody assets') }
    Assert-Check $rejected 'Native custody accepted an extra inventory asset.'
} finally { [IO.File]::Delete($extraInventory) }
$custody = [IntegratedPublicationCustody]::new($bundleRoot, [string[]]$fixture.names, [string[]]$fixture.hashes)
$npmSource = Join-Path $fixture.fixture_root 'npm-cli.js'
[IO.File]::WriteAllText($npmSource, '// Synthetic npm interpreter source only', [Text.UTF8Encoding]::new($false))
$npmHash = (Get-FileHash -LiteralPath $npmSource -Algorithm SHA256).Hash.ToLowerInvariant()
try {
    Assert-Check (-not $custody.NpmCliHeld) 'npm input was held before observation.'
    $wrongHashRefused = $false
    try { $custody.HoldNpmCli($npmSource, ('0' * 64)) } catch { $wrongHashRefused = $_.Exception.ToString().Contains('input hash differs') }
    Assert-Check $wrongHashRefused 'Wrong npm source hash was accepted.'
    Assert-Check (-not $custody.NpmCliHeld -and $custody.NativeCreateCalls -eq 0) 'Wrong source started publication.'
    $custody.HoldNpmCli($npmSource, $npmHash)
    Assert-Check $custody.NpmCliHeld 'Actual npm source HANDLE missing.'
    Assert-SharingRefusal { $writer = [IO.File]::OpenWrite($npmSource); $writer.Dispose() }
    Assert-SharingRefusal { [IO.File]::Delete($npmSource) }
    Assert-SharingRefusal { [IO.File]::Move($npmSource, $npmSource + '.renamed') }
    Assert-Check ([IO.File]::ReadAllText($npmSource) -eq '// Synthetic npm interpreter source only') 'npm consumer read differs.'
    $replacementRefused = $false
    try { $custody.HoldNpmCli($npmSource, $npmHash) } catch { $replacementRefused = $_.Exception.ToString().Contains('already fixed') }
    Assert-Check $replacementRefused 'Fixed npm source was replaced.'
    Assert-Check ($custody.HeldFileCount -eq 14) 'Complete asset custody missing.'
    foreach ($name in $fixture.names) {
        $assetPath = Join-Path $bundleRoot $name
        Assert-Check ([IO.File]::ReadAllBytes($assetPath).Length -gt 0) 'Read-only consumer could not read.'
        Assert-SharingRefusal { $writer = [IO.File]::Open($assetPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite); $writer.Dispose() }
        Assert-SharingRefusal { [IO.File]::Delete($assetPath) }
        Assert-SharingRefusal { [IO.File]::Move($assetPath, $assetPath + '.renamed') }
    }
    Assert-SharingRefusal { [IO.Directory]::Move($bundleRoot, $bundleRoot + '.renamed') } $true
    $custody.Verify()
    Assert-Check (-not $custody.Released) 'Custody released before verification.'
} finally { $custody.Dispose() }
Assert-Check $custody.Released 'Custody failed to release.'
Assert-Check (-not $custody.NpmCliHeld) 'npm source remained held after valid release.'
$npmWriter = [IO.File]::OpenWrite($npmSource)
$npmWriter.Dispose()
Assert-Check ((Get-FileHash -LiteralPath $npmSource -Algorithm SHA256).Hash.ToLowerInvariant() -eq $npmHash) 'npm source changed after release.'
[IO.Directory]::Move($bundleRoot, $bundleRoot + '.renamed')
[IO.Directory]::Move($bundleRoot + '.renamed', $bundleRoot)
Assert-Check ([IO.Directory]::Exists($bundleRoot)) 'Directory rename remained denied after custody release.'
foreach ($name in $fixture.names) {
    $assetPath = Join-Path $bundleRoot $name
    $writer = [IO.File]::Open($assetPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    $writer.Dispose()
    Assert-Check ([IO.File]::Exists($assetPath)) 'Asset was lost by a negative test.'
    $index = [Array]::IndexOf([string[]]$fixture.names, [string]$name)
    Assert-Check ((Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $fixture.hashes[$index]) 'Asset bytes changed during custody.'
}
$names = [string[]]$fixture.names
$hashes = [string[]]$fixture.hashes
foreach ($badIndex in @(0, $inventoryIndex)) {
    $changed = [string[]]$hashes.Clone()
    $changed[$badIndex] = '0' * 64
    $rejected = $false
    try { $invalid = [IntegratedPublicationCustody]::new($bundleRoot, $names, $changed); $invalid.Dispose() } catch { $rejected = $true }
    Assert-Check $rejected 'Changed expected asset hash accepted.'
    foreach ($name in $names) {
        $writer = [IO.File]::Open((Join-Path $bundleRoot $name), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        $writer.Dispose()
        Assert-Check $true 'Failed acquisition leaked a read lock.'
    }
}
$result = [ordered]@{ observed_at = (Get-Date).ToUniversalTime().ToString('o'); passed = $true; checks = $checks;
    windows_version = [Environment]::OSVersion.Version.ToString(); powershell_version = $PSVersionTable.PSVersion.ToString();
    held_files = 14; native_sharing_violation_verified = $true; released_read_write_verified = $true;
    candidate_identity = $fixture.candidate_identity; publication_admitted = $false;
    scope = 'Synthetic files, real Windows read/write/delete/rename custody. Child lifecycle and real publication are not claimed.' }
$json = $result | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $fixture.fixture_root 'custody-native-result.json'), ($json + "`n"), [Text.UTF8Encoding]::new($false))
$json
