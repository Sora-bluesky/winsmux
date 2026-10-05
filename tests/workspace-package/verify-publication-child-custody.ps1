[CmdletBinding()]
param([Parameter(Mandatory)][string]$OperatorRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Real Windows process custody proof required.' }
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixtureOutput = & node (Join-Path $PSScriptRoot 'prepare-publication-custody-fixture.mjs') $OperatorRoot
if ($LASTEXITCODE -ne 0) { throw 'Fixture preparation failed.' }
$fixture = ($fixtureOutput -join "`n") | ConvertFrom-Json
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.evidence/workspace-package')) + [IO.Path]::DirectorySeparatorChar
if (-not ([IO.Path]::GetFullPath($fixture.fixture_root)).StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -or $fixture.synthetic -ne $true) { throw 'Foreign fixture.' }
Add-Type -Path (Join-Path $repoRoot 'scripts/IntegratedPublicationCustody.cs')
. (Join-Path $PSScriptRoot 'publication-keeper-fixture.ps1')
$script:checks = 0
function Assert-Check([bool]$Condition, [string]$Reason) { if (-not $Condition) { throw $Reason }; $script:checks++ }
function Assert-Refused([scriptblock]$Operation, [string]$Reason) {
    $refused = $false
    try { & $Operation } catch {
        $failure = $_.Exception
        while ($failure.InnerException) { $failure = $failure.InnerException }
        if ($failure -is [InvalidOperationException] -and $failure.Message.Contains($Reason)) { $refused = $true } else { throw }
    }
    Assert-Check $refused ('Expected refusal missing: ' + $Reason)
}
function Persist-Original([string]$Path, [object]$Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 8 -Compress))
    $file = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $file.Write($bytes); $file.Flush($true) } finally { $file.Dispose() }
    Assert-Check ([IO.File]::ReadAllText($Path) -ceq [Text.Encoding]::UTF8.GetString($bytes)) 'Parent persistence readback differs.'
}
function Wait-Observed([scriptblock]$Condition, [string]$Reason) {
    $deadline = (Get-Date).AddSeconds(12)
    while (-not (& $Condition)) { if ((Get-Date) -gt $deadline) { throw $Reason }; Start-Sleep -Milliseconds 50 }
}
$node = @(Get-Command node -CommandType Application)[0].Source
$nodeHash = (Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant()
$childScript = Join-Path $PSScriptRoot 'publication-custody-child.mjs'
$held = [IntegratedPublicationCustody]::new($fixture.bundle_root, [string[]]$fixture.names, [string[]]$fixture.hashes)
$script:flightPath = Join-Path $fixture.fixture_root 'in-flight.json'
$script:createdPath = Join-Path $fixture.fixture_root 'created.json'
$flight = [Action[string]] { param($jobName)
    Persist-Original $script:flightPath ([ordered]@{ state = 'in_flight'; job_name = $jobName; candidate_identity = $fixture.candidate_identity })
}
$created = [Action[uint32,long,string]] { param($childPid, $creationTime, $jobName)
    Persist-Original $script:createdPath ([ordered]@{ pid = $childPid; creation_filetime = $creationTime; job_name = $jobName })
}
$root = $null
try {
    $npmSource = Join-Path $fixture.fixture_root 'npm-cli.js'
    [IO.File]::WriteAllText($npmSource, '// Synthetic source retained through descendant exit', [Text.UTF8Encoding]::new($false))
    $npmHash = (Get-FileHash -LiteralPath $npmSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $held.HoldNpmCli($npmSource, $npmHash)
    Assert-Check $held.NpmCliHeld 'npm source was not pinned before child creation.'
    Assert-Refused { $held.CreateChild($node, ('0' * 64), [string[]]@($childScript, 'root', $fixture.fixture_root), $fixture.fixture_root, $flight) } 'Child image hash differs'
    Assert-Check ($held.NativeCreateCalls -eq 0 -and -not [IO.File]::Exists($script:flightPath)) 'Changed image reached creation or persistence.'
    Assert-Refused { $held.CreateChild($node, $nodeHash, [string[]]@($childScript, 'root', $fixture.fixture_root), $fixture.fixture_root, $flight) } 'Keeper native ready missing'
    Assert-Check ($held.NativeCreateCalls -eq 0 -and -not [IO.File]::Exists($script:flightPath)) 'Missing keeper created a publication process.'
    $failedKeeperPersistence = [Action[IntegratedPublicationCustody+KeeperIdentity]]{ param($identity) throw [InvalidOperationException]::new('keeper persistence failed') }
    Assert-Refused { Start-FixtureKeeper $held $fixture $repoRoot $failedKeeperPersistence } 'keeper persistence failed'
    Assert-Check ($held.NativeCreateCalls -eq 0 -and $held.KeeperNativeCreateCalls -eq 1 -and $held.ActiveMembers() -eq 0) 'Keeper persistence failure created a publication child.'
    Assert-Check (-not [IO.File]::Exists((Join-Path $fixture.fixture_root 'keeper.json'))) 'Failed keeper persistence wrote an original record.'
    Assert-Refused { $held.Dispose() } 'suspended keeper persistence'
    $fixtureForKeeper = $fixture
    $keeperPersistence = [Action[IntegratedPublicationCustody+KeeperIdentity]]{ param($identity) Persist-FixtureKeeper $identity $fixtureForKeeper }
    $held.ResumeKeeper($keeperPersistence)
    Assert-Check ($held.KeeperNativeCreateCalls -eq 1 -and [IO.File]::Exists((Join-Path $fixture.fixture_root 'keeper.json'))) 'Keeper recovery spawned a replacement or missed original persistence.'
    $keeperIdentity = $held.Keeper
    Assert-Check ($keeperIdentity.Pid -ne [Environment]::ProcessId -and $keeperIdentity.JobName -ceq $held.JobName) 'Keeper actual identity missing.'
    $queryLease = [IntegratedPublicationCustody+QueryLease]::new($held.JobName)
    try {
        Assert-Refused { [IntegratedPublicationCustody]::HandoffKeeper($keeperIdentity, $queryLease, [uint32[]]@(), [long[]]@(), 15000) } 'Keeper recovery is not idle'
    } finally { $queryLease.Dispose() }
    $failedFlight = [Action[string]] { param($jobName) throw [InvalidOperationException]::new('in-flight persistence failed') }
    Assert-Refused { $held.CreateChild($node, $nodeHash, [string[]]@($childScript, 'root', $fixture.fixture_root), $fixture.fixture_root, $failedFlight) } 'in-flight persistence failed'
    Assert-Check ($held.NativeCreateCalls -eq 0 -and $held.ActiveMembers() -eq 0) 'Failed persistence created a process.'
    $arguments = [string[]]@($childScript, 'root', $fixture.fixture_root, 'space 日本語', 'quote"value', 'C:\ends with slash\', '')
    $root = $held.CreateChild($node, $nodeHash, $arguments, $fixture.fixture_root, $flight)
    Assert-Check ($held.NativeCreateCalls -eq 1 -and $held.ActiveMembers() -eq 1 -and -not $held.HasExited($root)) 'Atomic suspended child observation differs.'
    Assert-Check (-not [IO.File]::Exists((Join-Path $fixture.fixture_root 'root-result.json'))) 'Child ran before creation receipt.'
    Assert-Refused { $held.SealLaunches() } 'pending suspended child'
    Assert-Refused { $held.Dispose() } 'Keep custody'
    $failedCreated = [Action[uint32,long,string]] { param($childPid, $creationTime, $jobName) throw [InvalidOperationException]::new('creation persistence failed') }
    Assert-Refused { $held.ResumeChild($root, $failedCreated) } 'creation persistence failed'
    Assert-Check (-not [IO.File]::Exists((Join-Path $fixture.fixture_root 'root-result.json')) -and $held.ActiveMembers() -eq 1) 'Failed receipt resumed child.'
    $held.ResumeChild($root, $created)
    Assert-Refused { $held.ResumeChild($root, $created) } 'Resume closed'
    Wait-Observed { [IO.File]::Exists((Join-Path $fixture.fixture_root 'descendant-ready.json')) -and $held.HasExited($root) } 'Root/descendant transition not observed.'
    $rootResult = Get-Content -LiteralPath (Join-Path $fixture.fixture_root 'root-result.json') -Raw | ConvertFrom-Json
    $descendant = Get-Content -LiteralPath (Join-Path $fixture.fixture_root 'descendant-ready.json') -Raw | ConvertFrom-Json
    Assert-Check ($held.ExitCode($root) -eq 0 -and $held.ActiveMembers() -eq 1) 'Root exited but descendant not retained in Job.'
    Assert-Check ($descendant.pid -eq $rootResult.descendant -and $rootResult.files_read -eq 13 -and $descendant.files_read -eq 13) 'Child reads or descendant identity differ.'
    Assert-Check (($rootResult.arguments | ConvertTo-Json -Compress) -ceq (@('space 日本語', 'quote"value', 'C:\ends with slash\', '') | ConvertTo-Json -Compress)) 'Native argument quoting differs.'
    $otherCustody = [IntegratedPublicationCustody]::new($fixture.bundle_root, [string[]]$fixture.names, [string[]]$fixture.hashes)
    try { Assert-Refused { $otherCustody.ResumeChild($root, $created) } 'Foreign or released custody child' } finally { $otherCustody.Dispose() }
    $script:flightPath = Join-Path $fixture.fixture_root 'nonzero-in-flight.json'
    $script:createdPath = Join-Path $fixture.fixture_root 'nonzero-created.json'
    $nonzero = $held.CreateChild($node, $nodeHash, [string[]]@($childScript, 'nonzero', $fixture.fixture_root), $fixture.fixture_root, $flight)
    $held.ResumeChild($nonzero, $created)
    Wait-Observed { $held.HasExited($nonzero) } 'Nonzero root did not finish.'
    Persist-Original (Join-Path $fixture.fixture_root 'nonzero-exit-observation.json') ([ordered]@{
        exit_code = $held.ExitCode($nonzero); active_members = $held.ActiveMembers(); active_member_pids = @($held.ActiveMemberPids()); expected_descendant_pid = $descendant.pid })
    Wait-Observed { $held.ActiveMembers() -eq 1 } 'Exited root remains assigned or surviving descendant missing.'
    Assert-Check ($held.ExitCode($nonzero) -eq 37 -and $held.ActiveMembers() -eq 1) 'Nonzero exit was rewritten or descendant escaped.'
    Assert-Check (@($held.ActiveMemberPids())[0] -eq $descendant.pid) 'Remaining Job member is not the actual descendant.'
    $held.SealLaunches()
    Assert-Refused { $held.CreateChild($node, $nodeHash, $arguments, $fixture.fixture_root, $flight) } 'Child launch closed'
    Assert-Check ($held.NativeCreateCalls -eq 2) 'Sealed launch reached native creation.'
    Assert-Refused { $held.Dispose() } 'Keep custody'
    $writeDenied = $false
    try { $writer = [IO.File]::OpenWrite((Join-Path $fixture.bundle_root $fixture.names[0])); $writer.Dispose() } catch {
        $failure = $_.Exception
        while ($failure.InnerException) { $failure = $failure.InnerException }
        if ($failure -is [IO.IOException] -and ($failure.HResult -band 65535) -eq 32) { $writeDenied = $true } else { throw }
    }
    Assert-Check ($writeDenied -and -not $held.Released) 'Root exit released file custody while descendant live.'
    $npmWriteDenied = $false
    try { $writer = [IO.File]::OpenWrite($npmSource); $writer.Dispose() } catch {
        $failure = $_.Exception
        while ($failure.InnerException) { $failure = $failure.InnerException }
        if ($failure -is [IO.IOException] -and ($failure.HResult -band 65535) -eq 32) { $npmWriteDenied = $true } else { throw }
    }
    Assert-Check ($npmWriteDenied -and $held.NpmCliHeld) 'npm source was writable while publication descendant live.'
    [IO.File]::WriteAllText((Join-Path $fixture.fixture_root 'finish-descendant'), 'finish', [Text.UTF8Encoding]::new($false))
    Wait-Observed { $held.ActiveMembers() -eq 0 } 'Descendant normal exit not observed.'
    Assert-Check ([IO.File]::Exists((Join-Path $fixture.fixture_root 'descendant-result.json'))) 'Descendant did not read fixed bytes after root exit.'
    $held.Verify(); $held.Dispose()
    Assert-Check $held.Released 'Idle custody failed to release.'
    Assert-Check (-not $held.NpmCliHeld) 'npm source retained after native idle release.'
    Assert-Check (-not (Get-Process -Id $keeperIdentity.Pid -ErrorAction SilentlyContinue)) 'Keeper did not exit normally.'
} finally {
    # No force termination. Even a failed test asks only for normal fixture exit.
    if (-not $held.Released) {
        if ($root -and -not [IO.File]::Exists((Join-Path $fixture.fixture_root 'created.json'))) { $held.ResumeChild($root, $created) }
        [IO.File]::WriteAllText((Join-Path $fixture.fixture_root 'finish-descendant'), 'finish', [Text.UTF8Encoding]::new($false))
        $held.SealLaunches()
        Wait-Observed { $held.ActiveMembers() -eq 0 } 'Failed fixture still live; custody retained.'
        $held.Dispose()
    }
}
$writer = [IO.File]::OpenWrite((Join-Path $fixture.bundle_root $fixture.names[0])); $writer.Dispose()
$npmWriter = [IO.File]::OpenWrite($npmSource); $npmWriter.Dispose()
Assert-Check ((Get-FileHash -LiteralPath $npmSource -Algorithm SHA256).Hash.ToLowerInvariant() -eq $npmHash) 'npm source bytes changed after release.'
Assert-Check $true 'Post-exit write access missing.'
for ($index = 0; $index -lt $fixture.names.Count; $index++) {
    Assert-Check ((Get-FileHash -LiteralPath (Join-Path $fixture.bundle_root $fixture.names[$index]) -Algorithm SHA256).Hash.ToLowerInvariant() -eq $fixture.hashes[$index]) 'Child custody changed fixture bytes.'
}
$result = [ordered]@{ observed_at = (Get-Date).ToUniversalTime().ToString('o'); passed = $true; checks = $script:checks;
    windows_version = [Environment]::OSVersion.Version.ToString(); powershell_version = $PSVersionTable.PSVersion.ToString();
    root_pid = $root.Pid; root_creation_filetime = $root.CreationFileTime; descendant_pid = $descendant.pid;
    root_exit_code = 0; nonzero_root_exit_code = 37; all_exit_job_members = 0; held_files = 13; publication_admitted = $false;
    candidate_identity = $fixture.candidate_identity; node_sha256 = $nodeHash;
    scope = 'Real Windows atomic Job, suspended root, parent persistence ordering, descendant lifetime and fixed synthetic file reads. No public dispatch or real distribution proof.' }
$json = $result | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $fixture.fixture_root 'child-custody-native-result.json'), ($json + "`n"), [Text.UTF8Encoding]::new($false))
$json
