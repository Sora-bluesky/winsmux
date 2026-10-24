[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Add-Type -Path (Join-Path $repoRoot 'scripts/IntegratedPublicationCustody.cs')
$owner=Get-Content -LiteralPath (Join-Path $FixtureRoot 'authority-owner.json') -Raw | ConvertFrom-Json
$actor=Get-Content -LiteralPath (Join-Path $FixtureRoot 'authority-actor.json') -Raw | ConvertFrom-Json
$keeper=Get-Content -LiteralPath (Join-Path $FixtureRoot 'keeper.json') -Raw | ConvertFrom-Json
$result=Get-Content -LiteralPath (Join-Path $FixtureRoot 'authority-result.json') -Raw | ConvertFrom-Json
$pids=[uint32[]]@(); $times=[long[]]@()
if ($result.PSObject.Properties.Name -contains 'root_pid') { $pids=[uint32[]]@($result.root_pid); $times=[long[]]@([long]$result.root_creation_filetime) }
$identity=[IntegratedPublicationCustody]::LocateKeeper($keeper.Pid,[long]$keeper.creation_filetime_exact,$owner.pid,[long]$owner.creation_filetime,
    $owner.job_name,$keeper.Attempt,$keeper.CandidateSha256,$keeper.ImplementationSha256,$keeper.ScriptSha256)
$lease=[IntegratedPublicationCustody+QueryLease]::new($owner.job_name)
try {
    $state=$lease.Observe($actor.pid,[long]$actor.creation_filetime,$owner.pid,[long]$owner.creation_filetime,$pids,$times)
    if (-not $state.Idle) { throw 'Original actor/owner/root exit or same Job zero unproven' }
    [IntegratedPublicationCustody]::ObserveKeeper($identity,$lease,15000)
    [IntegratedPublicationCustody]::HandoffKeeperAfterActorExit($identity,$lease,$actor.pid,[long]$actor.creation_filetime,$pids,$times,15000)
    if ($lease.ActiveMembers() -ne 0) { throw 'Successor same Job lease lost' }
    $value=@{passed=$true; actor_gone=$state.ActorGone; owner_gone=$state.OwnerGone; roots_gone=$state.RootsGone;
        job_members=0; keeper_exit_code=0; query_handoff_job_name=$owner.job_name; publication_admitted=$false}
    $target=Join-Path $FixtureRoot 'authority-recovery-result.json'
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($value | ConvertTo-Json -Compress))
    $file=[IO.FileStream]::new($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {$file.Write($bytes); $file.Flush($true)} finally {$file.Dispose()}
    if ([IO.File]::ReadAllText($target) -cne [Text.Encoding]::UTF8.GetString($bytes)) {throw 'Recovery readback differs'}
} finally {$lease.Dispose()}
