[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Real Windows long-path custody proof required.' }
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Add-Type -Path (Join-Path $repoRoot 'scripts/IntegratedPublicationCustody.cs')
. (Join-Path $PSScriptRoot 'publication-keeper-fixture.ps1')
$script:checks = 0
function Assert-Check([bool]$Condition, [string]$Reason) { if (-not $Condition) { throw $Reason }; $script:checks++ }
function Wait-Observed([scriptblock]$Condition, [string]$Reason) {
    $deadline = (Get-Date).AddSeconds(15)
    while (-not (& $Condition)) { if ((Get-Date) -gt $deadline) { throw $Reason }; Start-Sleep -Milliseconds 50 }
}
function Get-Refusal([scriptblock]$Action) {
    try { & $Action } catch {
        $refusal = $_.Exception
        while ($refusal.InnerException) { $refusal = $refusal.InnerException }
        return $refusal
    }
    return $null
}
function Test-NamedRefusal([object]$Refusal, [string]$Use) {
    return $Refusal -is [IO.PathTooLongException] -and $Refusal.Message.StartsWith($Use + ' exceeds the 258-character Win32 current-directory limit', [StringComparison]::Ordinal)
}
function New-ExactDirectory([string]$Parent, [int]$Length, [bool]$Create = $true) {
    $path = $Parent
    while ($Length - $path.Length - 1 -gt 100) { $path = Join-Path $path ('segment-' + ('x' * 52)) }
    $tail = $Length - $path.Length - 1
    if ($tail -lt 1) { throw "Parent is too long for an exact $Length-character directory." }
    $path = Join-Path $path ('d' * $tail)
    if ($path.Length -ne $Length) { throw "Directory fixture is $($path.Length) characters, not $Length." }
    if ($Create) { [void][IO.Directory]::CreateDirectory($path) }
    return $path
}
$names = [string[]]@('core/SHA256SUMS', 'core/winsmux-arm64.exe', 'core/winsmux-arm64.exe.licenses.zip',
    'core/winsmux-remote-helper-linux-x64', 'core/winsmux-x64.exe', 'core/winsmux-x64.exe.licenses.zip',
    'desktop/SHA256SUMS-desktop', 'desktop/latest.json', 'desktop/winsmux_0.38.0_x64-setup.exe',
    'desktop/winsmux_0.38.0_x64-setup.exe.sig', 'desktop/winsmux_0.38.0_x64-setup.inventory.json',
    'desktop/winsmux_0.38.0_x64_en-US.msi', 'npm/winsmux-0.38.0.tgz', 'release-body.md')
function Write-Bundle([string]$Root) {
    $hashes = foreach ($name in $names) {
        $target = Join-Path $Root $name
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes('synthetic long-path asset ' + $name)
        [IO.File]::WriteAllBytes($target, $bytes)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
    return [string[]]$hashes
}
function Copy-Image([string]$Directory) {
    [void][IO.Directory]::CreateDirectory($Directory)
    $image = Join-Path $Directory 'where.exe'
    [IO.File]::Copy((Join-Path ([Environment]::SystemDirectory) 'where.exe'), $image)
    return $image
}
function Invoke-Child([string]$Image, [string]$Directory, [string]$Step) {
    $before = $held.NativeCreateCalls
    $child = $held.CreateChild($Image, $script:imageHash, [string[]]@('/?'), $Directory, $flight)
    $script:pendingChild = $child
    Assert-Check ($held.NativeCreateCalls -eq $before + 1 -and -not $held.HasExited($child)) "${Step}: child was not created suspended."
    $held.ResumeChild($child, $created); $script:pendingChild = $null
    Wait-Observed { $held.HasExited($child) -and $held.OutputComplete($child) } "${Step}: child exit not observed."
    $observation = $held.ObserveChildOutput($child)
    Assert-Check ($observation.ExitCode -eq 0 -and $observation.Stdout.Complete) ("${Step}: child did not run to a normal exit: exit=" + $observation.ExitCode)
}
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot ('.evidence/workspace-package/long-path-' + [Guid]::NewGuid().ToString('N'))))
$held = $null; $script:pendingChild = $null; $succeeded = $false
$created = [Action[uint32,long,string]] { param($childPid, $creationTime, $jobName) }
$script:flightPath = Join-Path $fixtureRoot 'in-flight.json'
$flight = [Action[string]] { param($jobName) [IO.File]::WriteAllText($script:flightPath, $jobName) }
try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $bundleRoot = New-ExactDirectory (Join-Path $fixtureRoot 'a') 258
    $hashes = Write-Bundle $bundleRoot
    Assert-Check (@($names | Where-Object { (Join-Path $bundleRoot $_).Length -le 260 }).Count -eq 0) 'a: bundle files do not exceed MAX_PATH.'
    $held = [IntegratedPublicationCustody]::new($bundleRoot, $names, $hashes)
    Assert-Check ($held.HeldFileCount -eq 14) 'a: 258-character bundle root custody missing.'
    $held.Verify()

    $refusedRoot = New-ExactDirectory (Join-Path $fixtureRoot 'b') 259
    $refusedHashes = Write-Bundle $refusedRoot
    $script:accepted = $null
    $refusal = Get-Refusal { $script:accepted = [IntegratedPublicationCustody]::new($refusedRoot, $names, $refusedHashes) }
    if ($script:accepted) { $script:accepted.Dispose() }
    Assert-Check (Test-NamedRefusal $refusal 'Bundle root (fixed publication working directory)') ('b: 259-character bundle root was not refused by name: ' + $refusal)
    foreach ($name in $names) { [IO.File]::Open((Join-Path $refusedRoot $name), 'Open', 'ReadWrite', 'None').Dispose() }
    Assert-Check (@([IO.Directory]::GetFileSystemEntries([IO.Path]::GetDirectoryName($refusedRoot))).Count -eq 1) 'b: refused bundle root left a runtime directory.'
    $absentRoot = New-ExactDirectory (Join-Path $fixtureRoot 'b-absent') 259 $false
    $refusal = Get-Refusal { [void][IntegratedPublicationCustody]::new($absentRoot, $names, $refusedHashes) }
    Assert-Check ((Test-NamedRefusal $refusal 'Bundle root (fixed publication working directory)') -and -not [IO.Directory]::Exists($absentRoot)) ('b: refusal did not precede every filesystem hold: ' + $refusal)

    $fixture = [pscustomobject]@{ fixture_root = $fixtureRoot; candidate_identity = [pscustomobject]@{ attempt = [Guid]::NewGuid().ToString('D') } }
    $candidateManifest = Join-Path $fixtureRoot 'publication-assets.json'
    [IO.File]::WriteAllText($candidateManifest, '{"synthetic":true}', [Text.UTF8Encoding]::new($false))
    $pwshImage = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $implementation = Join-Path $repoRoot 'scripts/IntegratedPublicationCustody.cs'
    $longScript = Join-Path (New-ExactDirectory (Join-Path $fixtureRoot 'k') 259) 'hold-publication-job.ps1'
    [IO.File]::Copy((Join-Path $repoRoot 'scripts/hold-publication-job.ps1'), $longScript)
    $persist = [Action[IntegratedPublicationCustody+KeeperIdentity]] { param($identity) throw 'k: refused keeper reached persistence.' }
    $refusal = Get-Refusal { $held.StartKeeper($pwshImage, (Get-FileHash -LiteralPath $pwshImage -Algorithm SHA256).Hash.ToLowerInvariant(),
        $longScript, (Get-FileHash -LiteralPath $longScript -Algorithm SHA256).Hash.ToLowerInvariant(),
        $implementation, (Get-FileHash -LiteralPath $implementation -Algorithm SHA256).Hash.ToLowerInvariant(),
        $fixture.candidate_identity.attempt, (Get-FileHash -LiteralPath $candidateManifest -Algorithm SHA256).Hash.ToLowerInvariant(), 15000, $persist) }
    Assert-Check (Test-NamedRefusal $refusal 'Keeper working directory') ('k: 259-character keeper directory was not refused by name: ' + $refusal)
    Assert-Check ($null -eq $held.JobName -and $held.KeeperNativeCreateCalls -eq 0 -and $null -eq $held.Keeper) 'k: keeper refusal followed Job creation or native creation.'
    Start-FixtureKeeper $held $fixture $repoRoot

    $shortImage = Copy-Image (Join-Path $fixtureRoot 'tool')
    $script:imageHash = (Get-FileHash -LiteralPath $shortImage -Algorithm SHA256).Hash.ToLowerInvariant()
    Invoke-Child $shortImage (New-ExactDirectory (Join-Path $fixtureRoot 'c') 258) 'c: 258-character working directory'
    $before = $held.NativeCreateCalls
    $script:flightPath = Join-Path $fixtureRoot 'in-flight-refused.json'
    $longDirectory = New-ExactDirectory (Join-Path $fixtureRoot 'c-refused') 259
    $refusal = Get-Refusal { [void]$held.CreateChild($shortImage, $script:imageHash, [string[]]@('/?'), $longDirectory, $flight) }
    Assert-Check (Test-NamedRefusal $refusal 'Child working directory') ('c: 259-character child working directory was not refused by name: ' + $refusal)
    Assert-Check ($held.NativeCreateCalls -eq $before -and -not [IO.File]::Exists($script:flightPath)) 'c: over-long working directory reached persistence or native creation.'
    $script:flightPath = Join-Path $fixtureRoot 'in-flight.json'

    $longImage = Copy-Image (New-ExactDirectory (Join-Path $fixtureRoot 'd') 270)
    Assert-Check ($longImage.Length -gt 260) 'd: child image does not exceed MAX_PATH.'
    Invoke-Child $longImage $fixtureRoot 'd: long child image'
    Invoke-Child $shortImage $fixtureRoot 'd: short child image'

    $held.SealLaunches()
    Wait-Observed { $held.ActiveMembers() -eq 0 } 'Long-path children still Job members.'
    $held.Verify(); $held.Dispose()
    Assert-Check $held.Released 'a: long-path custody failed to release.'
    $succeeded = $true
} finally {
    try {
        if ($held -and -not $held.Released) {
            if ($script:pendingChild) { $held.ResumeChild($script:pendingChild, $created) }
            $held.SealLaunches()
            Wait-Observed { $held.ActiveMembers() -eq 0 } 'Failed fixture still live; custody retained.'
            $held.Dispose()
        }
    } finally {
        try { if ([IO.Directory]::Exists($fixtureRoot)) { [IO.Directory]::Delete($fixtureRoot, $true) } }
        catch { if ($succeeded) { throw }; Write-Warning ('Long-path fixture cleanup failed: ' + $_.Exception.Message) }
    }
}
[ordered]@{ passed = $true; checks = $script:checks; bundle_root_length = $bundleRoot.Length; refused_root_length = $refusedRoot.Length; child_image_length = $longImage.Length } | ConvertTo-Json -Compress
