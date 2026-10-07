[CmdletBinding()]
param([Parameter(Mandatory)][string]$OperatorRoot,[Parameter(Mandatory)][string]$Manifest,[Parameter(Mandatory)][string]$ManifestHash)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source=Join-Path $repoRoot 'scripts/IntegratedPublicationCustody.cs'
$before=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
Add-Type -Path $source
. (Join-Path $PSScriptRoot 'publication-keeper-fixture.ps1')
$prepared=& 'C:/Program Files/nodejs/node.exe' (Join-Path $PSScriptRoot 'prepare-publication-custody-fixture.mjs') $OperatorRoot
if($LASTEXITCODE -ne 0){throw 'Actual npm native fixture preparation failed'}
$fixture=($prepared -join "`n") | ConvertFrom-Json
$held=[IntegratedPublicationCustody]::new($fixture.bundle_root,[string[]]$fixture.names,[string[]]$fixture.hashes)
$guard=Join-Path $repoRoot 'scripts/publication-node-source-guard.mjs'
$count=$held.FixRuntimeSources([IO.Path]::GetFullPath($Manifest),$ManifestHash,$guard,(Get-FileHash -LiteralPath $guard -Algorithm SHA256).Hash.ToLowerInvariant())
if($count -ne 1876){throw 'Actual source inventory size differs from fixed observation'}
$npmCli='C:/Program Files/nodejs/node_modules/npm/bin/npm-cli.js'
$writeError=$null
try{$writer=[IO.File]::OpenWrite($npmCli);$writer.Dispose()}catch{$errorInner=$_.Exception;while($errorInner.InnerException){$errorInner=$errorInner.InnerException};$writeError=$errorInner.HResult -band 65535}
if($writeError -notin @(5,32)){throw 'Actual npm source write was not refused'}
# Program Files can deny write permission before the sharing check. Prove the
# native read-sharing mechanism on the same inventory's owned bootstrap rather
# than mislabel access denied as a measured sharing violation.
$manifestData=Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$bootstrap=@($manifestData.files | Where-Object {$_.path.EndsWith('\source\bootstrap.mjs',[StringComparison]::Ordinal)})
if($bootstrap.Count -ne 1){throw 'Exact owned bootstrap missing'}
$sharingError=$null
try{$writer=[IO.File]::OpenWrite($bootstrap[0].path);$writer.Dispose()}catch{$errorInner=$_.Exception;while($errorInner.InnerException){$errorInner=$errorInner.InnerException};$sharingError=$errorInner.HResult -band 65535}
if($sharingError -ne 32){throw 'Owned runtime source native sharing proof missing'}
foreach($name in @('user.npmrc','global.npmrc')){[IO.File]::WriteAllText((Join-Path $fixture.fixture_root $name),'',[Text.UTF8Encoding]::new($false))}
function Save-Original([string]$Name,[object]$Value){$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 10 -Compress));$stream=[IO.FileStream]::new((Join-Path $fixture.fixture_root $Name),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}}
$flight=[Action[string]]{param($job)Save-Original 'npm-in-flight.json' @{job_name=$job;publication_admitted=$false}}
$created=[Action[uint32,long,string]]{param($childPid,$birth,$job)Save-Original 'npm-created.json' @{pid=$childPid;creation_filetime=$birth;job_name=$job}}
Start-FixtureKeeper $held $fixture $repoRoot
$node='C:/Program Files/nodejs/node.exe';$nodeHash=(Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant()
$args=[string[]]@($npmCli,'--version',('--userconfig='+(Join-Path $fixture.fixture_root 'user.npmrc')),('--globalconfig='+(Join-Path $fixture.fixture_root 'global.npmrc')),
    ('--cache='+(Join-Path $fixture.fixture_root 'cache')),'--registry=https://registry.npmjs.org','--ignore-scripts')
$child=$held.CreateChild($node,$nodeHash,$args,$fixture.fixture_root,$flight)
$held.ResumeChild($child,$created)
$expires=(Get-Date).AddSeconds(30)
while(-not $held.HasExited($child) -or -not $held.OutputComplete($child)){if((Get-Date) -gt $expires){throw 'Guarded native npm exit/capture incomplete; original retained'};Start-Sleep -Milliseconds 25}
$receipt=$held.ObserveChildOutput($child)
$expected=[Text.Encoding]::UTF8.GetBytes("11.13.0`n")
$expectedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expected)).ToLowerInvariant()
if($receipt.ExitCode -ne 0 -or -not $receipt.Stdout.Complete -or -not $receipt.Stderr.Complete -or $receipt.Stdout.Bytes -ne $expected.Length -or
    $receipt.Stdout.Sha256 -cne $expectedHash -or $receipt.Stderr.Bytes -ne 0){throw 'Actual guarded npm output differs'}
Save-Original 'npm-output-receipt.json' $receipt
$held.Verify()
if($held.ActiveMembers() -ne 0){throw 'Actual native npm Job idle not yet observed'}
$held.SealLaunches();$held.Dispose()
if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $before){throw 'Candidate changed during actual npm native proof'}
Save-Original 'npm-native-result.json' @{passed=$true;files_held=$count;npm_version='11.13.0';source_manifest_sha256=$ManifestHash;source_sha256=$before;actual_source_write_error=$writeError;owned_source_write_error=$sharingError;
    exit_code=0;job_members=0;public_effects_executed=0;publication_admitted=$false;scope='Actual installed npm --version with native source holding, fixed Unicode environment, guarded synchronous loader, native output receipt and Job lifetime. No auth or registry writes.'}
@{passed=$true;files_held=$count;original_result=(Join-Path $fixture.fixture_root 'npm-native-result.json')} | ConvertTo-Json -Compress
