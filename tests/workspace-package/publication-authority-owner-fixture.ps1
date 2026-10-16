[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot, [Parameter(Mandatory)][string]$PipeName,
    [Parameter(Mandatory)][string]$NodeImage, [Parameter(Mandatory)][string]$NodeHash,
    [Parameter(Mandatory)][ValidateSet('normal','disconnect-before-create','disconnect-after-resume','disconnect-after-resume-eof','wrong-response','fixed-table-only')][string]$Mode,
    [switch]$Guarded)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
trap {
    $errorPath=Join-Path $FixtureRoot 'authority-owner-failure.json'
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((@{failure=$_.Exception.ToString(); publication_admitted=$false} | ConvertTo-Json -Compress))
    $file=[IO.FileStream]::new($errorPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {$file.Write($bytes);$file.Flush($true)} finally {$file.Dispose()}
    exit 96
}
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture = Get-Content -LiteralPath (Join-Path $FixtureRoot 'custody-fixture.json') -Raw | ConvertFrom-Json
if (-not $IsWindows -or $fixture.synthetic -ne $true -or $fixture.publication_admitted -ne $false) { throw 'Synthetic Windows fixture required' }
$implementation = Join-Path $repoRoot 'scripts/IntegratedPublicationCustody.cs'
$sourceLease = [IO.FileStream]::new($implementation, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
$sourceReader = [IO.StreamReader]::new($sourceLease, [Text.UTF8Encoding]::new($false, $true), $true, 1024, $true)
Add-Type -TypeDefinition $sourceReader.ReadToEnd()
. (Join-Path $PSScriptRoot 'publication-keeper-fixture.ps1')
function Save-Original([string]$Name, [object]$Value) {
    $target = Join-Path $FixtureRoot $Name
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Compress -Depth 12))
    $file = [IO.FileStream]::new($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $file.Write($bytes); $file.Flush($true) } finally { $file.Dispose() }
    if ([IO.File]::ReadAllText($target) -cne [Text.Encoding]::UTF8.GetString($bytes)) { throw 'Original readback differs' }
}
function Refused([scriptblock]$Action) {
    try { & $Action; throw 'Expected authority refusal missing' }
    catch { if (-not $_.Exception.ToString().Contains('Authority disconnected')) { throw } }
}
$held = [IntegratedPublicationCustody]::new($fixture.bundle_root, [string[]]$fixture.names, [string[]]$fixture.hashes)
$actorScript = Join-Path $PSScriptRoot 'publication-authority.test.mjs'
$actorHash = (Get-FileHash -LiteralPath $actorScript -Algorithm SHA256).Hash.ToLowerInvariant()
if($Guarded) {
    $manifestFile=Join-Path $FixtureRoot 'runtime-source-manifest.json'
    $guardFile=Join-Path $repoRoot 'scripts/publication-node-source-guard.mjs'
    $held.FixRuntimeSources($manifestFile,(Get-FileHash -LiteralPath $manifestFile -Algorithm SHA256).Hash.ToLowerInvariant(),
        $guardFile,(Get-FileHash -LiteralPath $guardFile -Algorithm SHA256).Hash.ToLowerInvariant()) | Out-Null
    foreach($heldSource in @($manifestFile,$guardFile,$actorScript)) {
        $denied=$false
        try {$writer=[IO.File]::OpenWrite($heldSource);$writer.Dispose()}catch{$inner=$_.Exception;while($inner.InnerException){$inner=$inner.InnerException};$denied=($inner.HResult -band 65535) -eq 32}
        if(-not $denied){throw 'Native runtime source write custody missing'}
    }
    Save-Original 'runtime-source-custody.json' @{source_manifest_sha256=$held.RuntimeSourceSha256;write_refusals=3;publication_admitted=$false}
}
$ownerIdentity = [IntegratedPublicationCustody]::CurrentOwnerIdentity()
$saveActor = [Action[IntegratedPublicationCustody+ActorIdentity]] { param($identity)
    Save-Original 'authority-actor.json' @{pid=$identity.Pid; creation_filetime=$identity.CreationFileTime.ToString();environment_sha256=$identity.EnvironmentSha256;source_manifest_sha256=$identity.SourceManifestSha256}
    Save-Original 'authority-owner.json' @{pid=$ownerIdentity.Pid; creation_filetime=$ownerIdentity.CreationFileTime.ToString(); job_name=$held.JobName}
    Save-Original 'authority-bootstrap.json' @{actor_pid=$identity.Pid; actor_creation_filetime=$identity.CreationFileTime.ToString();
        owner_pid=$ownerIdentity.Pid; owner_creation_filetime=$ownerIdentity.CreationFileTime.ToString();
        job_name=$held.JobName; node_sha256=$NodeHash; script_sha256=$actorHash; synthetic=$true; publication_admitted=$false}
}
$authority = $held.StartAuthorityActor($PipeName,$NodeImage,$NodeHash,$actorScript,$actorHash,
    [string[]]@('actor',$FixtureRoot,$Mode,$PipeName,$ownerIdentity.Pid.ToString()),$FixtureRoot,15000,$saveActor)
Save-Original 'authority-listening.json' @{event='listening'}
$authority.Accept()
$actor = @{ pid=$authority.Actor.Pid; creation_filetime=$authority.Actor.CreationFileTime.ToString() }
if($Mode -eq 'fixed-table-only') {
    $tableFile=Join-Path $FixtureRoot 'native-operation-table.json'
    $originalJson=[IO.File]::ReadAllText($tableFile)
    $table=$originalJson | ConvertFrom-Json
    $script:tableChecks=0
    function Reject-Table([string]$Label,[scriptblock]$Change) {
        $altered=$originalJson | ConvertFrom-Json
        & $Change $altered
        $inputFile=Join-Path $FixtureRoot ('table-refused-'+$Label+'.json')
        Save-Original ('table-refused-'+$Label+'.json') $altered
        $didRefuse=$false
        try{$held.FixPublicationOperations($inputFile,(Get-FileHash -LiteralPath $inputFile -Algorithm SHA256).Hash.ToLowerInvariant(),$table.parent_session) | Out-Null}
        catch{$didRefuse=$true}
        if(-not $didRefuse -or $held.NativeCreateCalls -ne 0){throw ('Native table refusal failed: '+$Label)}
        $script:tableChecks++
    }
    Reject-Table 'authority' {param($item)$item.publication_admitted=$true}
    Reject-Table 'parent' {param($item)$item.parent_session='other-parent'}
    Reject-Table 'bundle' {param($item)$item.bundle_root=$FixtureRoot}
    Reject-Table 'version' {param($item)$item.candidate_identity.version='0.38.1'}
    Reject-Table 'destination' {param($item)$item.entries[0].destination='https://example.invalid/release'}
    Reject-Table 'argv' {param($item)$item.entries[0].arguments[0]='api'}
    Reject-Table 'overwrite' {param($item)$item.entries[1].arguments+=@('--clobber')}
    Reject-Table 'id' {param($item)$item.entries[0].operation_id='arbitrary'}
    Reject-Table 'duplicate-binding' {param($item)$item.entries[1].binding_sha256=$item.entries[0].binding_sha256}
    Reject-Table 'asset-hash' {param($item)$item.entries[0].assets[0].sha256='0'*64}
    Reject-Table 'asset-size' {param($item)$item.entries[0].assets[0].bytes++}
    Reject-Table 'npm-script' {param($item)$item.entries[2].arguments[0]=$table.entries[0].executable}
    Reject-Table 'npm-registry' {param($item)$item.entries[2].arguments[4]='--registry=https://example.invalid'}
    $count=$held.FixPublicationOperations($tableFile,(Get-FileHash -LiteralPath $tableFile -Algorithm SHA256).Hash.ToLowerInvariant(),$table.parent_session)
    if($count -ne 3 -or $held.NativeCreateCalls -ne 0){throw 'Native fixed table did not bind without dispatch'}
    foreach($entry in $table.entries){$operation=$held.SelectPublicationOperation($entry.operation_id);if($operation.Id -cne $entry.operation_id -or $operation.BindingSha256 -cne $entry.binding_sha256){throw 'Original operation selection differs'};$script:tableChecks++}
    $didRefuse=$false
    try{$held.SelectPublicationOperation('arbitrary') | Out-Null}catch{$didRefuse=$true}
    if(-not $didRefuse){throw 'Arbitrary ID accepted'};$script:tableChecks++
    $didRefuse=$false
    try{$held.CreateChild($NodeImage,$NodeHash,[string[]]@('-e','process.exit(0)'),$FixtureRoot,[Action[string]]{},'0'*64,[Action[uint32,long,string]]{}) | Out-Null}
    catch{$didRefuse=$_.Exception.ToString().Contains('Arbitrary native argv is closed')}
    if(-not $didRefuse -or $held.NativeCreateCalls -ne 0){throw 'Arbitrary argv was not closed'};$script:tableChecks++
    $denied=$false
    try{$writer=[IO.File]::OpenWrite($tableFile);$writer.Dispose()}catch{$inner=$_.Exception;while($inner.InnerException){$inner=$inner.InnerException};$denied=($inner.HResult -band 65535) -eq 32}
    if(-not $denied){throw 'Fixed table write custody missing'};$script:tableChecks++
    Start-FixtureKeeper $held $fixture $repoRoot
    $held.SealLaunches();$held.Dispose()
    Save-Original 'authority-result.json' @{passed=$true;mode=$Mode;native_create_calls=0;actor=$actor;normal_release=$true;
        fixed_operation_checks=$script:tableChecks;table_sha256=(Get-FileHash -LiteralPath $tableFile -Algorithm SHA256).Hash.ToLowerInvariant();publication_admitted=$false}
    exit 0
}
Start-FixtureKeeper $held $fixture $repoRoot
Save-Original 'authority-bound.json' @{event='bound'}
$childScript = Join-Path $PSScriptRoot 'publication-custody-child.mjs'
$childMode = if ($Mode.StartsWith('disconnect-after-resume')) { 'root' } else { 'nonzero' }
$arguments = [string[]]@($childScript, $childMode, $FixtureRoot)
$binding = (Get-FileHash -LiteralPath $childScript -Algorithm SHA256).Hash.ToLowerInvariant()
$flight = [Action[string]] { param($jobName) Save-Original 'authority-flight.json' @{job_name=$jobName; actor=$actor; binding=$binding; synthetic=$true} }
$created = [Action[uint32,long,string]] { param($childPid,$birth,$jobName)
    Save-Original 'authority-created.json' @{pid=$childPid; creation_filetime=$birth.ToString(); job_name=$jobName; binding=$binding} }
if ($Mode -eq 'disconnect-before-create') {
    # The live Node test actor closes its pipe upon the bound event.
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not $held.AuthorityDisconnected) { if ([DateTime]::UtcNow -gt $deadline) { throw 'EOF unobserved' }; Start-Sleep -Milliseconds 20 }
    Refused { $held.CreateChild($NodeImage,$NodeHash,$arguments,$FixtureRoot,$flight,$binding,$created) }
    Refused { $held.Dispose() }
    Save-Original 'authority-result.json' @{ passed=$true; mode=$Mode; native_create_calls=$held.NativeCreateCalls; actor=$actor;
        normal_release_refused=$true; keeper_retained=$true; publication_admitted=$false }
    exit 0 # No Dispose/NORMAL; keeper remains for independent native handoff.
}
try { $child = $held.CreateChild($NodeImage,$NodeHash,$arguments,$FixtureRoot,$flight,$binding,$created) }
catch {
    if ($Mode -ne 'wrong-response' -or -not $_.Exception.ToString().Contains('one-operation decision missing')) { throw }
    Refused { $held.Dispose() }
    Save-Original 'authority-result.json' @{ passed=$true; mode=$Mode; native_create_calls=$held.NativeCreateCalls; actor=$actor;
        normal_release_refused=$true; keeper_retained=$true; publication_admitted=$false }
    exit 0
}
# The native choke point persisted/read back identity before returning the child.
$persistSame = [Action[uint32,long,string]] { param($childPid,$birth,$jobName)
    $record = Get-Content -LiteralPath (Join-Path $FixtureRoot 'authority-created.json') -Raw | ConvertFrom-Json
    if ($record.pid -ne $childPid -or $record.creation_filetime -cne $birth.ToString() -or $record.job_name -cne $jobName -or $record.binding -cne $binding) { throw 'Created identity differs' } }
$held.ResumeChild($child,$persistSame)
Save-Original 'authority-resumed.json' @{event='resumed'}
$deadline = [DateTime]::UtcNow.AddSeconds(25)
if ($Mode.StartsWith('disconnect-after-resume')) {
    while (-not $held.AuthorityDisconnected -or -not $held.HasExited($child)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Actor/root exit unobserved' }; Start-Sleep -Milliseconds 20
    }
    $members = $held.ActiveMembers()
    if ($members -le 0) { throw 'Living descendant was lost' }
    Refused { $held.CreateChild($NodeImage,$NodeHash,$arguments,$FixtureRoot,$flight,$binding,$created) }
    Refused { $held.ResumeChild($child,$persistSame) }
    Refused { $held.Dispose() }
    $denied = $false
    try { $writer = [IO.File]::OpenWrite((Join-Path $fixture.bundle_root $fixture.names[0])); $writer.Dispose() }
    catch { $errorObject=$_.Exception; while($errorObject.InnerException){$errorObject=$errorObject.InnerException}; $denied=($errorObject.HResult -band 65535) -eq 32 }
    if (-not $denied) { throw 'Custody write denial lost while descendant lives' }
    $sameOwner=[IntegratedPublicationCustody]::CurrentOwnerIdentity()
    if($sameOwner.Pid -ne $ownerIdentity.Pid -or $sameOwner.CreationFileTime -ne $ownerIdentity.CreationFileTime){throw 'Original native owner differs'}
    if($Mode -eq 'disconnect-after-resume' -and (-not $authority.ActorExited -or $authority.ActorExitCode -ne 95)){throw 'Actual original actor exit unproven'}
    Save-Original 'authority-disconnected.json' @{ members=$members; write_denied=$denied; keeper_retained=$true; normal_release_refused=$true;
        owner_pid=$sameOwner.Pid; owner_creation_filetime=$sameOwner.CreationFileTime.ToString(); actor=$actor; actor_exited=$authority.ActorExited;
        actor_exit_code=$(if($authority.ActorExited){$authority.ActorExitCode}else{$null}) }
}
while (-not $held.HasExited($child) -or $held.ActiveMembers() -ne 0) {
    if ([DateTime]::UtcNow -gt $deadline) { throw 'Native Job zero unobserved' }; Start-Sleep -Milliseconds 20
}
$exitCode = $held.ExitCode($child)
if ($Mode -eq 'normal') { $held.SealLaunches(); $held.Dispose() }
else { Refused { $held.Dispose() } }
Save-Original 'authority-result.json' @{ passed=$true; mode=$Mode; native_create_calls=$held.NativeCreateCalls; actor=$actor;
    root_pid=$child.Pid; root_creation_filetime=$child.CreationFileTime.ToString(); root_exit_code=$exitCode;
    job_members=0; normal_release=($Mode -eq 'normal'); keeper_retained=($Mode -ne 'normal'); publication_admitted=$false }
# On disconnect, normal process exit releases only this helper's local handles.
# The QUERY keeper is intentionally not disposed and must outlive this helper.
exit 0
