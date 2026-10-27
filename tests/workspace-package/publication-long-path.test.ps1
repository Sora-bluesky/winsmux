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
function Get-LongDirectory([string]$Parent, [int]$MinimumLength) {
    $path = $Parent
    while ($path.Length -lt $MinimumLength) { $path = Join-Path $path ('long-path-segment-' + ('x' * 40)) }
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot ('.evidence/workspace-package/long-path-' + [Guid]::NewGuid().ToString('N'))))
$bundleRoot = Get-LongDirectory (Join-Path $fixtureRoot 'bundle') 270
$toolRoot = Get-LongDirectory (Join-Path $fixtureRoot 'tool') 270
$names = [string[]]@('core/SHA256SUMS', 'core/winsmux-arm64.exe', 'core/winsmux-arm64.exe.licenses.zip',
    'core/winsmux-remote-helper-linux-x64', 'core/winsmux-x64.exe', 'core/winsmux-x64.exe.licenses.zip',
    'desktop/SHA256SUMS-desktop', 'desktop/latest.json', 'desktop/winsmux_0.38.0_x64-setup.exe',
    'desktop/winsmux_0.38.0_x64-setup.exe.sig', 'desktop/winsmux_0.38.0_x64-setup.inventory.json',
    'desktop/winsmux_0.38.0_x64_en-US.msi', 'npm/winsmux-0.38.0.tgz', 'release-body.md')
$hashes = foreach ($name in $names) {
    $target = Join-Path $bundleRoot $name
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes('synthetic long-path asset ' + $name)
    [IO.File]::WriteAllBytes($target, $bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
$hashes = [string[]]$hashes
Assert-Check ($bundleRoot.Length -gt 260 -and @($names | Where-Object { (Join-Path $bundleRoot $_).Length -le 260 }).Count -eq 0) 'Bundle fixture does not exceed MAX_PATH.'
$executable = Join-Path $toolRoot 'where.exe'
[IO.File]::Copy((Join-Path ([Environment]::SystemDirectory) 'where.exe'), $executable)
$executableHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-Check ($executable.Length -gt 260) 'Child image fixture does not exceed MAX_PATH.'
$fixture = [pscustomobject]@{ fixture_root = $fixtureRoot; candidate_identity = [pscustomobject]@{ attempt = [Guid]::NewGuid().ToString('D') } }
[IO.File]::WriteAllText((Join-Path $fixtureRoot 'publication-assets.json'), '{"synthetic":true}', [Text.UTF8Encoding]::new($false))
$script:flightPath = Join-Path $fixtureRoot 'in-flight.json'
$flight = [Action[string]] { param($jobName) [IO.File]::WriteAllText($script:flightPath, $jobName) }
$created = [Action[uint32,long,string]] { param($childPid, $creationTime, $jobName) }
$held = [IntegratedPublicationCustody]::new($bundleRoot, $names, $hashes)
$child = $null; $resumed = $false
try {
    Assert-Check ($held.HeldFileCount -eq 14) 'Long-path asset custody missing.'
    $held.Verify()
    $refusal = $null
    try { [void]$held.CreateChild($executable, $executableHash, [string[]]@('/?'), $bundleRoot, $flight) } catch {
        $refusal = $_.Exception
        while ($refusal.InnerException) { $refusal = $refusal.InnerException }
    }
    Assert-Check ($refusal -is [IO.PathTooLongException] -and $refusal.Message.Contains('258-character Win32 current-directory limit')) 'Over-long child working directory was not refused by name.'
    Assert-Check ($held.NativeCreateCalls -eq 0 -and -not [IO.File]::Exists($script:flightPath)) 'Over-long working directory reached persistence or native creation.'
    Start-FixtureKeeper $held $fixture $repoRoot
    $child = $held.CreateChild($executable, $executableHash, [string[]]@('/?'), $fixtureRoot, $flight)
    Assert-Check ($held.NativeCreateCalls -eq 1 -and -not $held.HasExited($child)) 'Long-path child was not created suspended.'
    $held.ResumeChild($child, $created); $resumed = $true
    Wait-Observed { $held.HasExited($child) -and $held.OutputComplete($child) } 'Long-path child exit not observed.'
    $observation = $held.ObserveChildOutput($child)
    Assert-Check ($observation.ExitCode -eq 0 -and $observation.Stdout.Complete) ('Long-path child did not run to a normal exit: exit=' + $observation.ExitCode)
    $held.SealLaunches()
    Wait-Observed { $held.ActiveMembers() -eq 0 } 'Long-path child still a Job member.'
    $held.Verify(); $held.Dispose()
    Assert-Check $held.Released 'Long-path custody failed to release.'
} finally {
    if (-not $held.Released) {
        if ($child -and -not $resumed) { $held.ResumeChild($child, $created) }
        $held.SealLaunches()
        Wait-Observed { $held.ActiveMembers() -eq 0 } 'Failed fixture still live; custody retained.'
        $held.Dispose()
    }
}
[IO.Directory]::Delete($fixtureRoot, $true)
[ordered]@{ passed = $true; checks = $script:checks; bundle_root_length = $bundleRoot.Length; child_image_length = $executable.Length } | ConvertTo-Json -Compress
