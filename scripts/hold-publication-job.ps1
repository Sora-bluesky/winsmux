[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Implementation,
    [Parameter(Mandatory)][string]$ImplementationHash,
    [Parameter(Mandatory)][string]$ScriptHash,
    [Parameter(Mandatory)][string]$JobName,
    [Parameter(Mandatory)][uint32]$OwnerPid,
    [Parameter(Mandatory)][long]$OwnerCreationTime,
    [Parameter(Mandatory)][string]$Attempt,
    [Parameter(Mandatory)][string]$CandidateHash,
    [Parameter(Mandatory)][int]$ObservationTimeout
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Native Windows query keeper required.' }
# Parent holds these exact files while launching this hidden process. The
# loaded implementation retains only QUERY authority, never public authority.
if ((Get-FileHash -LiteralPath $Implementation -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ImplementationHash -or
    (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ScriptHash) { throw 'Keeper implementation differs.' }
Add-Type -Path $Implementation
[IntegratedPublicationCustody]::RunKeeper($JobName, $OwnerPid, $OwnerCreationTime, $Attempt, $CandidateHash, $ImplementationHash, $ScriptHash, $ObservationTimeout)
