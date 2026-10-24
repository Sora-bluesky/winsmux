[CmdletBinding()]
param([Parameter(Mandatory)][string]$OperatorRoot, [Parameter(Mandatory)][string]$FixtureFile)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.evidence/workspace-package')) + [IO.Path]::DirectorySeparatorChar
$FixtureFile = [IO.Path]::GetFullPath($FixtureFile)
if (-not $FixtureFile.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Foreign fixture file.' }
$fixture = Get-Content -LiteralPath $FixtureFile -Raw | ConvertFrom-Json
if ($fixture.synthetic -ne $true -or $fixture.publication_admitted -ne $false) { throw 'Synthetic fixture required.' }
Add-Type -Path (Join-Path $repoRoot 'scripts/IntegratedPublicationCustody.cs')
. (Join-Path $PSScriptRoot 'publication-keeper-fixture.ps1')
function Persist-Original([string]$Name, [object]$Value) {
    $target = Join-Path $fixture.fixture_root $Name
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 8 -Compress))
    $file = [IO.FileStream]::new($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $file.Write($bytes); $file.Flush($true) } finally { $file.Dispose() }
    if ([IO.File]::ReadAllText($target) -cne [Text.Encoding]::UTF8.GetString($bytes)) { throw 'Persistence readback differs.' }
}
$node = @(Get-Command node -CommandType Application)[0].Source
$nodeHash = (Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant()
$ownerPid = [Environment]::ProcessId
$ownerCreation = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToFileTime()
$held = [IntegratedPublicationCustody]::new($fixture.bundle_root, [string[]]$fixture.names, [string[]]$fixture.hashes)
Start-FixtureKeeper $held $fixture $repoRoot
$flight = [Action[string]] { param($jobName)
    Persist-Original 'owner.json' ([ordered]@{ pid = $ownerPid; creation_filetime = $ownerCreation.ToString(); job_name = $jobName })
    & $node (Join-Path $PSScriptRoot 'publication-owner-freeze-fixture.mjs') freeze $OperatorRoot $fixture.fixture_root
    if ($LASTEXITCODE -ne 0) { throw 'Native owner could not freeze its candidate.' }
}
$created = [Action[uint32,long,string]] { param($childPid, $creationTime, $jobName)
    Persist-Original 'created.json' ([ordered]@{ pid = $childPid; creation_filetime = $creationTime.ToString(); job_name = $jobName })
}
$root = $held.CreateChild($node, $nodeHash, [string[]]@((Join-Path $PSScriptRoot 'publication-custody-child.mjs'), 'root', $fixture.fixture_root), $fixture.fixture_root, $flight)
$held.ResumeChild($root, $created)
$deadline = (Get-Date).AddSeconds(12)
while (-not [IO.File]::Exists((Join-Path $fixture.fixture_root 'descendant-ready.json')) -or -not $held.HasExited($root)) {
    if ((Get-Date) -gt $deadline) { throw 'Fixture root/descendant transition missing.' }
    Start-Sleep -Milliseconds 50
}
$held.SealLaunches(); $held.Verify()
$before = [IntegratedPublicationCustody]::ObserveRecovery($ownerPid, $ownerCreation, $held.JobName, [uint32[]]@($root.Pid), [long[]]@($root.CreationFileTime))
if ($before.OwnerGone -or -not $before.RootsGone -or $before.ActiveMembers -ne 1 -or $before.Idle) { throw 'Before-exit live ownership proof differs.' }
Persist-Original 'before-owner-exit.json' ([ordered]@{ owner_gone = $before.OwnerGone; roots_gone = $before.RootsGone; active_members = $before.ActiveMembers; job_found = $before.JobFound; idle = $before.Idle; root_exit_code = $held.ExitCode($root) })
# Deliberate abrupt fixture exit, not termination of an existing user process.
# Dispose/finally do not run: the recovery test must observe the surviving Job.
[Environment]::Exit(95)
