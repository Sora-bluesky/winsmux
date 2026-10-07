[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$fixtureRoot=Join-Path (Get-Location) ('.evidence/workspace-package/runtime-environment-'+[Guid]::NewGuid().ToString())
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$source='scripts/IntegratedPublicationCustody.cs'
$before=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
Add-Type -Path $source
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.ComponentModel;
public static class PublicationEnvironmentFixture {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Startup {
  public uint Size; public string Reserved,Desktop,Title; public uint X,Y,Width,Height,XChars,YChars,Fill,Flags;
  public ushort Show,ReservedSize; public IntPtr ReservedBytes,Input,Output,Error;
 }
 [StructLayout(LayoutKind.Sequential)] struct Created {public IntPtr Process,Thread;public uint Pid,Tid;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 static extern bool CreateProcessW(string image,StringBuilder command,IntPtr ps,IntPtr ts,bool inherit,uint flags,IntPtr environment,string cwd,ref Startup startup,out Created created);
 [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr process,uint timeout);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 static string Q(string value) {if(value.Contains('"')||value.EndsWith("\\"))throw new ArgumentException("Fixture path quote");return "\""+value+"\"";}
 public static uint Run(string image,string script,string output,string cwd,IntPtr environment) {
  var startup=new Startup{Size=(uint)Marshal.SizeOf<Startup>()};Created created;
  if(!CreateProcessW(image,new StringBuilder(Q(image)+" "+Q(script)+" "+Q(output)),IntPtr.Zero,IntPtr.Zero,false,0x08000400,environment,cwd,ref startup,out created))throw new Win32Exception();
  try {if(WaitForSingleObject(created.Process,30000)!=0)throw new InvalidOperationException("Controlled fixture exit unknown; no forced termination");
   uint code;if(!GetExitCodeProcess(created.Process,out code))throw new Win32Exception();return code;
  }finally{CloseHandle(created.Thread);CloseHandle(created.Process);}
 }
}
'@
$script:checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Refuse([scriptblock]$Operation){$refused=$false;try{& $Operation | Out-Null}catch{$refused=$true};Check $refused ('Expected explicit profile refusal missing: '+$Operation.ToString())}
Check ([IntegratedPublicationEnvironment]::Canonicalize([string[]]@('b=2','A=1')) -ceq "A=1`0B=2`0`0") 'Canonical sorted Unicode block differs'
Refuse {[IntegratedPublicationEnvironment]::Canonicalize([string[]]@('Node_Options=one','NODE_OPTIONS=two'))}
Refuse {[IntegratedPublicationEnvironment]::Canonicalize([string[]]@("NAME=a`0b"))}
Refuse {[IntegratedPublicationEnvironment]::Canonicalize([string[]]@('=drive'))}
Refuse {[IntegratedPublicationEnvironment]::Canonicalize([string[]]@('BAD-NAME=x'))}
Refuse {[IntegratedPublicationEnvironment]::Create('arbitrary',$fixtureRoot,'C:/Program Files/nodejs/node.exe',$null,$null)}
$nodeImage='C:/Program Files/nodejs/node.exe'
$probe=Join-Path $fixtureRoot 'probe.cjs'
$output=Join-Path $fixtureRoot 'observed.json'
[IO.File]::WriteAllText($probe,"const fs=require('node:fs');fs.writeFileSync(process.argv[2],JSON.stringify(process.env),{flag:'wx'});",[Text.UTF8Encoding]::new($false))
$environment=[IntegratedPublicationEnvironment]::Create('fixture',$fixtureRoot,$nodeImage,$null,$null)
try {
    Check (-not $environment.PublicationAdmitted) 'Environment must not grant authority'
    $canonical=[IntegratedPublicationEnvironment]::Canonicalize($environment.Entries)
    $actualSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::Unicode.GetBytes($canonical))).ToLowerInvariant()
    Check ($actualSha -ceq $environment.Sha256) 'Native environment digest differs'
    # Synthetic owner-only canary; no OS or parent application settings change.
    [Environment]::SetEnvironmentVariable('WINSMUX_ENV_CANARY','synthetic-must-not-inherit','Process')
    try {$exitCode=[PublicationEnvironmentFixture]::Run($nodeImage,$probe,$output,$fixtureRoot,$environment.Block)}
    finally {[Environment]::SetEnvironmentVariable('WINSMUX_ENV_CANARY',$null,'Process')}
    Check ($exitCode -eq 0) 'Controlled native fixture failed'
    $observed=[IO.File]::ReadAllText($output) | ConvertFrom-Json -AsHashtable
    Check ($observed.Count -eq $environment.Entries.Count) 'Native child inherited undeclared entries'
    foreach($entry in $environment.Entries){$split=$entry.IndexOf('=');Check ($observed[$entry.Substring(0,$split)] -ceq $entry.Substring($split+1)) 'Native child environment differs'}
    foreach($name in @('WINSMUX_ENV_CANARY','NODE_OPTIONS','NODE_PATH','NODE_COMPILE_CACHE','DOTNET_STARTUP_HOOKS','CORECLR_ENABLE_PROFILING','COR_ENABLE_PROFILING','GH_HOST','HTTP_PROXY','HTTPS_PROXY')) {
        Check (-not $observed.ContainsKey($name)) ('Unexpected native environment key: '+$name)
    }
    $profileSha=$environment.Sha256
}finally{$environment.Dispose()}
Refuse {$environment.get_Block()}
$manifest=Join-Path $fixtureRoot 'controlled-manifest.json'
[IO.File]::WriteAllText($manifest,'{}',[Text.UTF8Encoding]::new($false))
$nodeProfile=[IntegratedPublicationEnvironment]::Create('authority',$fixtureRoot,$nodeImage,$manifest,'0'*64)
try {Check ($nodeProfile.Entries -contains 'NODE_DISABLE_COMPILE_CACHE=1') 'Compile cache disable missing';Check ($nodeProfile.Entries.Count -eq 9) 'Unexpected Node profile entries'}finally{$nodeProfile.Dispose()}
Refuse {[IntegratedPublicationEnvironment]::Create('authority',$fixtureRoot,$nodeImage,$manifest,'bad')}
Refuse {[IntegratedPublicationEnvironment]::Create('fixture',$fixtureRoot,$nodeImage,$manifest,'0'*64)}
$authProbe=Join-Path $fixtureRoot 'auth-probe.cjs';$authOutput=Join-Path $fixtureRoot 'auth-observation.json'
$syntheticToken='SYNTHETIC_ONLY_DO_NOT_PERSIST_AUTH_BYTES'
[IO.File]::WriteAllText($authProbe,"const fs=require('node:fs');fs.writeFileSync(process.argv[2],JSON.stringify({received:process.env.WINSMUX_NPM_TOKEN==='SYNTHETIC_ONLY_DO_NOT_PERSIST_AUTH_BYTES',otherProvider:process.env.GH_TOKEN!==undefined}),{flag:'wx'});",[Text.UTF8Encoding]::new($false))
$plain=[IntegratedPublicationEnvironment]::Create('npm',$fixtureRoot,$nodeImage,$manifest,'0'*64)
$authenticated=[IntegratedPublicationEnvironment]::CreateAuthenticated('npm',$fixtureRoot,$nodeImage,$manifest,'0'*64,$syntheticToken)
try {
    Check ($authenticated.AuthenticationVariable -ceq 'WINSMUX_NPM_TOKEN') 'Wrong scoped authentication provider'
    Check ($authenticated.Sha256 -ceq $plain.Sha256) 'Public profile digest contains authentication bytes'
    Check (-not (($authenticated.Entries -join "`n").Contains($syntheticToken))) 'Authentication bytes escaped through profile entries'
    Check ([PublicationEnvironmentFixture]::Run($nodeImage,$authProbe,$authOutput,$fixtureRoot,$authenticated.Block) -eq 0) 'Scoped authentication fixture failed'
    $authObserved=Get-Content -LiteralPath $authOutput -Raw | ConvertFrom-Json
    Check ($authObserved.received -and -not $authObserved.otherProvider) 'Scoped actual native authentication variable differs'
    Check (-not ([IO.File]::ReadAllText($authOutput).Contains($syntheticToken))) 'Raw authentication bytes persisted'
}finally{$authenticated.Dispose();$plain.Dispose()}
Refuse {[IntegratedPublicationEnvironment]::CreateAuthenticated('fixture',$fixtureRoot,$nodeImage,$null,$null,$syntheticToken)}
Refuse {[IntegratedPublicationEnvironment]::CreateAuthenticated('npm',$fixtureRoot,$nodeImage,$manifest,'0'*64,"bad`nvalue")}
Check ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $before) 'Candidate changed during test'
$result=@{passed=$true;checks=$checks;environment_sha256=$profileSha;source_sha256=$before;native_unicode_environment_verified=$true;public_effects_executed=0;publication_admitted=$false;
    scope='Explicit environment canonicalization and actual controlled native Node fixture; synthetic provider-only authentication not exposed in entries/digest/output. No real credential, public actor, source custody or dispatch.'}
[IO.File]::WriteAllText((Join-Path $fixtureRoot 'result.json'),($result | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
@{passed=$true;checks=$checks;original_result=(Join-Path $fixtureRoot 'result.json')} | ConvertTo-Json -Compress
