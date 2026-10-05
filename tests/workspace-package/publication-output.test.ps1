[CmdletBinding()]
param([Parameter(Mandatory)][string]$OperatorRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixtureOutput=& 'C:/Program Files/nodejs/node.exe' (Join-Path $PSScriptRoot 'prepare-publication-custody-fixture.mjs') $OperatorRoot
if($LASTEXITCODE -ne 0){throw 'Output fixture preparation failed'}
$fixture=($fixtureOutput -join "`n") | ConvertFrom-Json
Add-Type -Path (Join-Path $repoRoot 'scripts/IntegratedPublicationCustody.cs')
. (Join-Path $PSScriptRoot 'publication-keeper-fixture.ps1')
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class PublicationOutputCanary {
 [StructLayout(LayoutKind.Sequential)] struct Security {public int Size;public IntPtr Descriptor;[MarshalAs(UnmanagedType.Bool)]public bool Inherit;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateEventW(ref Security security,bool manual,bool initial,string name);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr OpenEventW(uint access,bool inherit,string name);
 [DllImport("kernelbase.dll")] static extern bool CompareObjectHandles(IntPtr first,IntPtr second);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
 public static IntPtr Create(string name) {var security=new Security{Size=Marshal.SizeOf<Security>(),Inherit=true};var handle=CreateEventW(ref security,false,false,name);
  if(handle==IntPtr.Zero)throw new Exception("Canary creation failed");var probe=OpenEventW(0x100000,false,name);
  try{if(probe==IntPtr.Zero||!CompareObjectHandles(handle,probe))throw new Exception("Canary same-object comparison failed");}finally{if(probe!=IntPtr.Zero)CloseHandle(probe);}return handle;}
}
'@
$childSource=@'
param([string]$Fixture,[long]$Canary,[string]$EventName)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @"
using System;using System.Runtime.InteropServices;
public static class OutputHandleProbe {
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetHandleInformation(IntPtr handle,out uint flags);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr OpenEventW(uint access,bool inherit,string name);
 [DllImport("kernelbase.dll")] static extern bool CompareObjectHandles(IntPtr first,IntPtr second);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 public static bool Inherited(long value,string name){uint flags;bool valid=GetHandleInformation(new IntPtr(value),out flags);var actual=OpenEventW(0x100000,false,name);
  if(actual==IntPtr.Zero)throw new Exception("Exact event unavailable");try{return valid&&CompareObjectHandles(new IntPtr(value),actual);}finally{CloseHandle(actual);}}
}
"@
$inherited=[OutputHandleProbe]::Inherited($Canary,$EventName)
if($inherited){throw 'Unlisted native handle inherited'}
$inputStream=[Console]::OpenStandardInput();$stdinEof=$inputStream.ReadByte() -eq -1;$inputStream.Dispose()
if(-not $stdinEof){throw 'Fixed stdin did not return EOF'}
$marker=[Text.Encoding]::UTF8.GetBytes('SYNTHETIC_NOT_A_CREDENTIAL_CAPTURE_CANARY')
$outBytes=[byte[]]::new(400000);[Array]::Fill[byte]($outBytes,65);[Array]::Copy($marker,$outBytes,$marker.Length)
$errBytes=[byte[]]::new(600000);[Array]::Fill[byte]($errBytes,66);[Array]::Copy($marker,$errBytes,$marker.Length)
$outStream=[Console]::OpenStandardOutput();$errStream=[Console]::OpenStandardError()
$outStream.Write($outBytes);$outStream.Flush();$errStream.Write($errBytes);$errStream.Flush()
[IO.File]::WriteAllText((Join-Path $Fixture 'controlled-output-flags.json'),(@{stdin_eof=$stdinEof;unlisted_handle_inherited=$inherited} | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
exit 37
'@
$childScript=Join-Path $fixture.fixture_root 'controlled-output-child.ps1'
[IO.File]::WriteAllText($childScript,$childSource,[Text.UTF8Encoding]::new($false))
$pwshImage='C:/Users/sorab/AppData/Local/Programs/PowerShell/7/pwsh.exe'
$imageHash=(Get-FileHash -LiteralPath $pwshImage -Algorithm SHA256).Hash.ToLowerInvariant()
$sourceHash=(Get-FileHash -LiteralPath (Join-Path $repoRoot 'scripts/IntegratedPublicationCustody.cs') -Algorithm SHA256).Hash.ToLowerInvariant()
$held=[IntegratedPublicationCustody]::new($fixture.bundle_root,[string[]]$fixture.names,[string[]]$fixture.hashes)
$eventName='Local\winsmux-output-canary-'+[Guid]::NewGuid().ToString('N')
$canary=[PublicationOutputCanary]::Create($eventName)
function Save-Original([string]$Name,[object]$Value){$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 10 -Compress));$file=[IO.FileStream]::new((Join-Path $fixture.fixture_root $Name),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$file.Write($bytes);$file.Flush($true)}finally{$file.Dispose()}}
$flight=[Action[string]]{param($job)Save-Original 'output-in-flight.json' @{job_name=$job}}
$created=[Action[uint32,long,string]]{param($childPid,$birth,$job)Save-Original 'output-created.json' @{pid=$childPid;creation_filetime=$birth;job_name=$job}}
Start-FixtureKeeper $held $fixture $repoRoot
$child=$held.CreateChild($pwshImage,$imageHash,[string[]]@('-NoLogo','-NoProfile','-NonInteractive','-File',$childScript,$fixture.fixture_root,$canary.ToInt64().ToString(),$eventName),$fixture.fixture_root,$flight)
$held.ResumeChild($child,$created)
$expires=(Get-Date).AddSeconds(30)
while(-not $held.HasExited($child) -or -not $held.OutputComplete($child)){if((Get-Date) -gt $expires){throw 'Controlled output/exit incomplete; retained original custody'};Start-Sleep -Milliseconds 25}
$receipt=$held.ObserveChildOutput($child)
$marker=[Text.Encoding]::UTF8.GetBytes('SYNTHETIC_NOT_A_CREDENTIAL_CAPTURE_CANARY')
function Expected-Hash([int]$Count,[byte]$Fill){$bytes=[byte[]]::new($Count);[Array]::Fill[byte]($bytes,$Fill);[Array]::Copy($marker,$bytes,$marker.Length);[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}
if($receipt.ExitCode -ne 37 -or -not $receipt.Stdout.Complete -or -not $receipt.Stderr.Complete -or $receipt.Stdout.Bytes -ne 400000 -or $receipt.Stderr.Bytes -ne 600000 -or
    $receipt.Stdout.Sha256 -cne (Expected-Hash 400000 65) -or $receipt.Stderr.Sha256 -cne (Expected-Hash 600000 66)){throw 'Actual output count, hash, capture or original exit differs'}
$flags=Get-Content -LiteralPath (Join-Path $fixture.fixture_root 'controlled-output-flags.json') -Raw | ConvertFrom-Json
if(-not $flags.stdin_eof -or $flags.unlisted_handle_inherited){throw 'Native handle allowlist/EOF proof differs'}
$saved=$receipt | ConvertTo-Json -Depth 10 -Compress
if($saved.Contains([Text.Encoding]::UTF8.GetString($marker))){throw 'Raw output persisted in receipt'}
Save-Original 'output-receipt.json' $receipt
if($held.ActiveMembers() -ne 0){throw 'Actual Job idle not yet observed'}
$held.SealLaunches();$held.Dispose();[PublicationOutputCanary]::CloseHandle($canary) | Out-Null
if((Get-FileHash -LiteralPath (Join-Path $repoRoot 'scripts/IntegratedPublicationCustody.cs') -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash){throw 'Source changed during output proof'}
Save-Original 'output-result.json' @{passed=$true;stdout_bytes=400000;stderr_bytes=600000;exit_code=37;stdin_eof=$true;unlisted_handle_inherited=$false;raw_output_persisted=$false;source_sha256=$sourceHash;public_effects_executed=0;publication_admitted=$false}
@{passed=$true;original_result=(Join-Path $fixture.fixture_root 'output-result.json')} | ConvertTo-Json -Compress
