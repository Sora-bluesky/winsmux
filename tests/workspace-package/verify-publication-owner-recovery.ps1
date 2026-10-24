[CmdletBinding()]
param([Parameter(Mandatory)][string]$OperatorRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Real Windows owner recovery proof required.' }
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixtureOutput = & node (Join-Path $PSScriptRoot 'prepare-publication-custody-fixture.mjs') $OperatorRoot
if ($LASTEXITCODE -ne 0) { throw 'Fixture creation failed.' }
$fixture = ($fixtureOutput -join "`n") | ConvertFrom-Json
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.evidence/workspace-package')) + [IO.Path]::DirectorySeparatorChar
if (-not ([IO.Path]::GetFullPath($fixture.fixture_root)).StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -or $fixture.synthetic -ne $true) { throw 'Foreign fixture.' }
Add-Type -Path (Join-Path $repoRoot 'scripts/IntegratedPublicationCustody.cs')
$script:checks = 0
function Assert-Check([bool]$Condition, [string]$Reason) { if (-not $Condition) { throw $Reason }; $script:checks++ }
function Wait-Observed([scriptblock]$Condition, [string]$Reason) {
    $deadline = (Get-Date).AddSeconds(15)
    while (-not (& $Condition)) { if ((Get-Date) -gt $deadline) { throw $Reason }; Start-Sleep -Milliseconds 50 }
}
function Assert-Refused([scriptblock]$Operation) {
    $refused = $false
    try { & $Operation } catch { $refused = $true }
    Assert-Check $refused 'Native identity mismatch or premature handoff was accepted.'
}
$ownerScript = Join-Path $PSScriptRoot 'publication-owner-death-fixture.ps1'
$fixtureFile = Join-Path $fixture.fixture_root 'custody-fixture.json'
$pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$owner = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-File', ('"' + $ownerScript + '"'), '-OperatorRoot', ('"' + $OperatorRoot + '"'), '-FixtureFile', ('"' + $fixtureFile + '"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $fixture.fixture_root 'owner-stdout.txt') -RedirectStandardError (Join-Path $fixture.fixture_root 'owner-stderr.txt')
$replacementHold = $null
$queryLease = $null
$keeperIdentity = $null
trap {
    $errorRecord = $_
    [IO.File]::WriteAllText((Join-Path $fixture.fixture_root 'failure.json'),
        ([ordered]@{ message = $errorRecord.Exception.Message; stack = $errorRecord.ScriptStackTrace; qualified_error_id = $errorRecord.FullyQualifiedErrorId } | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    break
}
try {
    Wait-Observed { $owner.Refresh(); $owner.HasExited } 'Fixture owner remains live.'
    Assert-Check ($owner.ExitCode -eq 95) 'Fixture owner failed before deliberate abrupt exit.'
    $originalOwner = Get-Content -LiteralPath (Join-Path $fixture.fixture_root 'owner.json') -Raw | ConvertFrom-Json
    $originalRoot = Get-Content -LiteralPath (Join-Path $fixture.fixture_root 'created.json') -Raw | ConvertFrom-Json
    $before = Get-Content -LiteralPath (Join-Path $fixture.fixture_root 'before-owner-exit.json') -Raw | ConvertFrom-Json
    $freeze = Get-Content -LiteralPath (Join-Path $fixture.fixture_root 'freeze-result.json') -Raw | ConvertFrom-Json
    $keeperRecord = Get-Content -LiteralPath (Join-Path $fixture.fixture_root 'keeper.json') -Raw | ConvertFrom-Json
    $keeperIdentity = [IntegratedPublicationCustody]::LocateKeeper([uint32]$keeperRecord.Pid, [long]$keeperRecord.CreationFileTime,
        [uint32]$originalOwner.pid, [long]$originalOwner.creation_filetime, $originalOwner.job_name, $keeperRecord.Attempt,
        $keeperRecord.CandidateSha256, $keeperRecord.ImplementationSha256, $keeperRecord.ScriptSha256)
    $queryLease = [IntegratedPublicationCustody+QueryLease]::new($originalOwner.job_name)
    [IntegratedPublicationCustody]::ObserveKeeper($keeperIdentity, $queryLease, 15000)
    Assert-Check ($keeperRecord.Attempt -ceq $fixture.candidate_identity.attempt -and $keeperRecord.CandidateSha256 -ceq (Get-FileHash -LiteralPath (Join-Path $fixture.fixture_root 'publication-assets.json') -Algorithm SHA256).Hash.ToLowerInvariant()) 'Keeper candidate or attempt binding differs.'
    Assert-Check (-not $before.owner_gone -and $before.roots_gone -and $before.active_members -eq 1 -and $before.job_found -and -not $before.idle) 'Live owner was accepted as idle.'
    Assert-Check ($originalOwner.pid -eq $owner.Id -and [long]$originalOwner.creation_filetime -eq $owner.StartTime.ToFileTime()) 'Original owner identity differs.'
    $live = [IntegratedPublicationCustody]::ObserveRecovery([uint32]$originalOwner.pid, [long]$originalOwner.creation_filetime, $originalOwner.job_name, [uint32[]]@($originalRoot.pid), [long[]]@([long]$originalRoot.creation_filetime))
    [IO.File]::WriteAllText((Join-Path $fixture.fixture_root 'after-owner-exit-observation.json'), ($live | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-Check ($live.OwnerGone -and $live.RootsGone -and $live.JobFound -and $live.ActiveMembers -eq 1 -and -not $live.Idle) 'Abrupt owner exit concealed a surviving descendant.'
    Assert-Refused { [IntegratedPublicationCustody]::HandoffKeeper($keeperIdentity, $queryLease, [uint32[]]@($originalRoot.pid), [long[]]@([long]$originalRoot.creation_filetime), 15000) }
    $guardOutput = & node (Join-Path $PSScriptRoot 'publication-owner-freeze-fixture.mjs') guard $OperatorRoot $fixture.fixture_root 2>&1
    $guardExit = $LASTEXITCODE
    Assert-Check ($guardExit -ne 0 -and ($guardOutput -join "`n").Contains('Publication attempt is frozen')) 'Preparation was allowed after owner death.'
    Assert-Check ((Get-FileHash -LiteralPath $freeze.file -Algorithm SHA256).Hash.ToLowerInvariant() -eq $freeze.original_sha256) 'Frozen record changed after owner death.'
    $replacementHold = [IntegratedPublicationCustody]::new($fixture.bundle_root, [string[]]$fixture.names, [string[]]$fixture.hashes)
    $replacementHold.Verify()
    [IO.File]::WriteAllText((Join-Path $fixture.fixture_root 'finish-descendant'), 'finish', [Text.UTF8Encoding]::new($false))
    $script:idle = $null
    Wait-Observed { $script:idle = $queryLease.Observe([uint32]$originalOwner.pid, [long]$originalOwner.creation_filetime, [uint32[]]@($originalRoot.pid), [long[]]@([long]$originalRoot.creation_filetime)); $script:idle.Idle } 'Original descendant exit not observed.'
    Assert-Check ($script:idle.OwnerGone -and $script:idle.RootsGone -and $script:idle.ActiveMembers -eq 0) 'Native original-process idle proof incomplete.'
    Assert-Check ([IO.File]::Exists((Join-Path $fixture.fixture_root 'descendant-result.json'))) 'Surviving descendant did not read all fixed bytes.'
    [IntegratedPublicationCustody]::ObserveKeeper($keeperIdentity, $queryLease, 15000)
    Assert-Check ($queryLease.ActiveMembers() -eq 0 -and (Get-Process -Id $keeperIdentity.Pid -ErrorAction Stop)) 'Keeper self-released at orphaned Job zero.'
    foreach ($badKind in @('pid', 'time', 'attempt', 'candidate', 'implementation', 'script')) {
        $badPid = [uint32]$keeperRecord.Pid; $badTime = [long]$keeperRecord.CreationFileTime
        $badAttempt = $keeperRecord.Attempt; $badCandidate = $keeperRecord.CandidateSha256
        $badImplementation = $keeperRecord.ImplementationSha256; $badScript = $keeperRecord.ScriptSha256
        switch ($badKind) {
            'pid' { $badPid = [uint32][Environment]::ProcessId }
            'time' { $badTime++ }
            'attempt' { $badAttempt = [Guid]::NewGuid().ToString() }
            'candidate' { $badCandidate = '0' * 64 }
            'implementation' { $badImplementation = '0' * 64 }
            'script' { $badScript = '0' * 64 }
        }
        $bad = [IntegratedPublicationCustody]::LocateKeeper($badPid, $badTime, [uint32]$originalOwner.pid, [long]$originalOwner.creation_filetime,
            $originalOwner.job_name, $badAttempt, $badCandidate, $badImplementation, $badScript)
        Assert-Refused { [IntegratedPublicationCustody]::ObserveKeeper($bad, $queryLease, 15000) }
        [IntegratedPublicationCustody]::ObserveKeeper($keeperIdentity, $queryLease, 15000)
        Assert-Check ($queryLease.ActiveMembers() -eq 0) 'Rejected claimant caused keeper loss.'
    }
    # Arbitrary successful flags or a handle number cannot authorize keeper
    # release. This real peer offers no valid held Job HANDLE and is refused.
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $keeperIdentity.PipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::CurrentUserOnly)
    $writer = $null; $reader = $null
    try {
        $pipe.Connect(15000)
        $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true); $writer.AutoFlush = $true
        $null = $reader.ReadLine(); $writer.WriteLine('QUERY'); $null = $reader.ReadLine()
        $writer.WriteLine('HANDOFF|0')
        $replyTask = $reader.ReadLineAsync()
        if (-not $replyTask.Wait(15000)) { throw 'Invalid handle response not observed.' }
        Assert-Check ($replyTask.GetAwaiter().GetResult() -cne 'TRANSFERRED') 'Invalid handle released keeper.'
    } finally {
        if ($writer) {
            try { $writer.Dispose() } catch {
                $failure = $_.Exception
                while ($failure.InnerException) { $failure = $failure.InnerException }
                if ($failure -isnot [IO.IOException] -or $pipe.IsConnected) { throw }
                # Invalid-handle claimant was disconnected by the server. Its
                # empty flush can report broken pipe; this is not keeper exit.
            }
        }
        if ($reader) { $reader.Dispose() }; $pipe.Dispose()
    }
    [IntegratedPublicationCustody]::ObserveKeeper($keeperIdentity, $queryLease, 15000)
    Assert-Check ($queryLease.ActiveMembers() -eq 0) 'Invalid claimant lost the original Job.'
    [IO.File]::WriteAllText((Join-Path $fixture.fixture_root 'before-handoff-observation.json'), ($script:idle | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    [IntegratedPublicationCustody]::HandoffKeeper($keeperIdentity, $queryLease, [uint32[]]@($originalRoot.pid), [long[]]@([long]$originalRoot.creation_filetime), 15000)
    Assert-Check ($queryLease.ActiveMembers() -eq 0 -and -not (Get-Process -Id $keeperIdentity.Pid -ErrorAction SilentlyContinue)) 'Keeper handoff or normal exit unproven.'
    $queryLease.Dispose(); $queryLease = $null
    $replacementHold.Verify(); $replacementHold.Dispose()
    Assert-Check ((Get-FileHash -LiteralPath $freeze.file -Algorithm SHA256).Hash.ToLowerInvariant() -eq $freeze.original_sha256) 'Successful idle observation cleared or altered freeze.'
    for ($index = 0; $index -lt $fixture.names.Count; $index++) {
        Assert-Check ((Get-FileHash -LiteralPath (Join-Path $fixture.bundle_root $fixture.names[$index]) -Algorithm SHA256).Hash.ToLowerInvariant() -eq $fixture.hashes[$index]) 'Owner death changed fixed asset bytes.'
    }
} finally {
    [IO.File]::WriteAllText((Join-Path $fixture.fixture_root 'finish-descendant'), 'finish', [Text.UTF8Encoding]::new($false))
    if ($replacementHold -and -not $replacementHold.Released) { $replacementHold.Dispose() }
    if ($queryLease -and $keeperIdentity) {
        Wait-Observed { $queryLease.ActiveMembers() -eq 0 } 'Failed fixture descendants remain live.'
        if (Get-Process -Id $keeperIdentity.Pid -ErrorAction SilentlyContinue) {
            [IntegratedPublicationCustody]::HandoffKeeper($keeperIdentity, $queryLease, [uint32[]]@($originalRoot.pid), [long[]]@([long]$originalRoot.creation_filetime), 15000)
        }
        $queryLease.Dispose()
    }
    $owner.Dispose()
}
$result = [ordered]@{ observed_at = (Get-Date).ToUniversalTime().ToString('o'); passed = $true; checks = $script:checks;
    windows_version = [Environment]::OSVersion.Version.ToString(); powershell_version = $PSVersionTable.PSVersion.ToString();
    actual_owner_pid = $originalOwner.pid; actual_owner_creation_filetime = $originalOwner.creation_filetime; owner_exit_code = 95;
    actual_root_pid = $originalRoot.pid; surviving_descendants_after_owner_exit = 1; all_exit_job_members = 0;
    actual_keeper_pid = $keeperIdentity.Pid; actual_keeper_creation_filetime = $keeperIdentity.CreationFileTime.ToString(); keeper_exit_code = 0;
    keeper_outside_publication_job = $true; same_kernel_job_handoff = $true; orphaned_job_zero_kept_until_handoff = $true;
    preparation_denied_after_owner_exit = $true; frozen_record_sha256 = $freeze.original_sha256; candidate_identity = $fixture.candidate_identity;
    publication_admitted = $false; scope = 'Real Windows abrupt fixture owner exit, surviving named Job, original identity query, fixed bytes and managed preparation refusal. Real public query/retry and production entrance cutover are not claimed.' }
$json = $result | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $fixture.fixture_root 'owner-recovery-native-result.json'), ($json + "`n"), [Text.UTF8Encoding]::new($false))
$json
