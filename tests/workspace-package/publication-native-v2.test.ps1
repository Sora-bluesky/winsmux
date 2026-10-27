[CmdletBinding()]
param([Parameter(Mandatory)][string]$OperatorRoot,
 [Parameter(Mandatory)][string]$NodeImage,
 [Parameter(Mandatory)][string]$NodeHash,
 [ValidateSet('normal','persist-actor','callback-actor','stopped-actor','keeper-dead')][string]$Scenario='normal')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Synthetic custody proof: the three original fixed operations reach the shared
# authenticated native path with fake in-memory values and safe Node endpoints.
# It never reads a credential store or resumes an actual gh/npm payload.
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$implementation=Join-Path $repoRoot 'scripts/IntegratedPublicationCustody.cs'
$expectedImplementation='e818758b4ae0a1933e98d14ad97f8744b2798a05fdf0fd22ce1b6479dbaf2067'
if(-not $IsWindows -or (Get-FileHash -LiteralPath $implementation -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedImplementation){throw 'Exact candidate Windows implementation required'}
if($NodeHash -cne 'd702daa815eabbff763c7d3808e235cf031cf2ca70211b56847bc72f51e240e5' -or (Get-FileHash -LiteralPath $NodeImage -Algorithm SHA256).Hash.ToLowerInvariant() -cne $NodeHash){throw 'Fixed Node image differs'}
$lease=[IO.FileStream]::new($implementation,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$reader=[IO.StreamReader]::new($lease,[Text.UTF8Encoding]::new($false,$true),$true,1024,$true)
$fixtureHelper=@'
public static class PublicationV2CustodyProof {
 const BindingFlags Hidden=BindingFlags.Instance|BindingFlags.NonPublic;
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr h,out long c,out long e,out long k,out long u);
 [DllImport("kernel32.dll",SetLastError=true)] static extern uint GetProcessId(IntPtr h);
 [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr h,uint ms);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr h,uint code);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr h,uint code);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessInJob(IntPtr p,IntPtr j,out bool yes);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageNameW(IntPtr p,uint flags,StringBuilder s,ref uint n);
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool DuplicateHandle(IntPtr a,IntPtr b,IntPtr c,out IntPtr d,uint access,bool inherit,uint options);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr h);
 static object Field(object o,string n)=>o.GetType().GetField(n,Hidden).GetValue(o);
 static IntPtr Handle(object o,string n)=>(IntPtr)Field(o,n);
 static void Check(bool yes){if(!yes)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());}
 static void Original(IntPtr h,uint pid,long birth,string image){
  long c,e,k,u;Check(GetProcessTimes(h,out c,out e,out k,out u));
  if(GetProcessId(h)!=pid||c!=birth)throw new Exception("Original fixture PID/birth differs");
  var text=new StringBuilder(32768);uint count=(uint)text.Capacity;Check(QueryFullProcessImageNameW(h,0,text,ref count));
  if(!String.Equals(text.ToString(),Path.GetFullPath(image),StringComparison.OrdinalIgnoreCase))throw new Exception("Original fixture image differs");
 }
 public static IntegratedPublicationCustody.PublicationOperation NonOriginal(IntegratedPublicationCustody.PublicationOperation op)=>(IntegratedPublicationCustody.PublicationOperation)typeof(object).GetMethod("MemberwiseClone",Hidden).Invoke(op,null);
 public static bool BindingPublished(IntegratedPublicationCustody o)=>Field(o,"fixedOperations")!=null||Field(o,"npmCliInput")!=null;
 public static void SafeArguments(IntegratedPublicationCustody.PublicationOperation o,string[] arguments){
  // The only positive reflection mutation: endpoint argv after strict table checks.
  o.GetType().GetField("Arguments",Hidden).SetValue(o,arguments.ToArray());
 }
 public static void KillActor(IntegratedPublicationCustody o,IntegratedPublicationCustody.AuthorityConnection a,uint ownerPid,string image){
  if(IntegratedPublicationCustody.CurrentOwnerIdentity().Pid!=ownerPid||a.Owner.Pid!=ownerPid)throw new Exception("Original fixture owner differs");
  var h=Handle(a,"actorProcess");Original(h,a.Actor.Pid,a.Actor.CreationFileTime,image);
  long c,e,k,u;Check(GetProcessTimes(h,out c,out e,out k,out u));
  if(GetProcessId(h)!=a.Actor.Pid||c!=a.Actor.CreationFileTime||WaitForSingleObject(h,0)!=258)throw new Exception("Original actor differs");
  Check(TerminateProcess(h,95));if(WaitForSingleObject(h,uint.MaxValue)!=0||!a.ActorExited||a.ActorExitCode!=95)throw new Exception("Original actor death not established");
 }
 public static void KillKeeper(IntegratedPublicationCustody o){
  var h=Handle(o,"keeperNativeProcess");var k=o.Keeper;Original(h,k.Pid,k.CreationFileTime,System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName);
  long c,e,t,u;Check(GetProcessTimes(h,out c,out e,out t,out u));
  if(GetProcessId(h)!=k.Pid||c!=k.CreationFileTime||WaitForSingleObject(h,0)!=258)throw new Exception("Original keeper differs");
  Check(TerminateProcess(h,96));if(WaitForSingleObject(h,uint.MaxValue)!=0)throw new Exception("Original keeper death not established");
 }
 public static bool ForcedCleanup(IntegratedPublicationCustody o,IntegratedPublicationCustody.AuthorityConnection a,IntegratedPublicationCustody.Child child){
  // Test-only owner retains actual handles. No lookup by image name or PID is used.
  IntPtr copy=IntPtr.Zero;var job=Handle(o,"job");
  try{
   Check(DuplicateHandle(GetCurrentProcess(),job,GetCurrentProcess(),out copy,0,false,2));
   if(child!=null){var process=Handle(child,"Process");var image=(FileStream)Field(child,"Image");
    Original(process,child.Pid,child.CreationFileTime,image.Name);bool member;Check(IsProcessInJob(process,copy,out member));
    if(!member||!o.ActiveMemberPids().SequenceEqual(new[]{child.Pid})||(bool)Field(child,"Resumed"))throw new Exception("Exact stopped fixture Job/root required");
    Check(TerminateJobObject(copy,137));if(WaitForSingleObject(process,uint.MaxValue)!=0)throw new Exception("Fixture cleanup root not terminal");
   }
   while(o.ActiveMembers()!=0)System.Threading.Thread.Sleep(20);
   var keeper=Handle(o,"keeperNativeProcess");if(keeper!=IntPtr.Zero&&WaitForSingleObject(keeper,0)==258)KillKeeper(o);
   if(!a.ActorExited){var actorImage=new StringBuilder(32768);uint actorLength=(uint)actorImage.Capacity;Check(QueryFullProcessImageNameW(Handle(a,"actorProcess"),0,actorImage,ref actorLength));KillActor(o,a,a.Owner.Pid,actorImage.ToString());}
  }finally{if(copy!=IntPtr.Zero)Check(CloseHandle(copy));}
  return true;
 }
}
'@
Add-Type -TypeDefinition ('using System.Reflection;'+[Environment]::NewLine+$reader.ReadToEnd()+[Environment]::NewLine+$fixtureHelper)
. (Join-Path $PSScriptRoot 'publication-keeper-fixture.ps1')
$fixture=$null
trap {
 $originalError=$_
 if($fixture){$failure=Join-Path $fixture.fixture_root 'authority-owner-failure.json';if(-not [IO.File]::Exists($failure)){
  $errorDetails=@{failure='native-v2-proof-failed';exception_type=$originalError.Exception.GetType().FullName;exception_message=$originalError.Exception.Message;error_id=$originalError.FullyQualifiedErrorId;position=$originalError.InvocationInfo.PositionMessage;script_stack=$originalError.ScriptStackTrace;publication_admitted=$false}
  [IO.File]::WriteAllText($failure,($errorDetails | ConvertTo-Json -Depth 6 -Compress),[Text.UTF8Encoding]::new($false))}}
 throw $originalError
}
$prepared=& $NodeImage (Join-Path $PSScriptRoot 'prepare-publication-custody-fixture.mjs') $OperatorRoot
if($LASTEXITCODE -ne 0){throw 'Synthetic bundle fixture preparation failed'}
$fixture=($prepared -join "`n") | ConvertFrom-Json
if($fixture.synthetic -ne $true -or $fixture.publication_admitted -ne $false){throw 'Synthetic closed bundle required'}
function Hash([string]$File){(Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()}
function Save([string]$Name,[object]$Value){
 $file=Join-Path $fixture.fixture_root $Name
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 30 -Compress))
 $stream=[IO.FileStream]::new($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
 if([IO.File]::ReadAllText($file) -cne [Text.Encoding]::UTF8.GetString($bytes)){throw 'Proof readback differs'}
 return $file
}
$sourceDir=Join-Path $fixture.fixture_root 'source'
[IO.Directory]::CreateDirectory($sourceDir) | Out-Null
$actorScript=Join-Path $sourceDir 'publication-authority.test.mjs'
$fixedActor=@'
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const [root,pipe,owner]=process.argv.slice(2), hash=p=>createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const read=name=>JSON.parse(fs.readFileSync(path.join(root,name))), seen=new Set(), phases=new Map();
let socket,ended=false;
const tick=setInterval(()=>{
 if(fs.existsSync(path.join(root,'authority-result.json'))){clearInterval(tick);socket?.end();process.exit(0);}
 if(socket||!fs.existsSync(path.join(root,'authority-listening.json')))return;
 const boot=read('authority-bootstrap.json');
 assert.equal(boot.actor_pid,process.pid);assert.equal(boot.owner_pid,Number(owner));
 assert.equal(boot.node_sha256,hash(process.execPath));assert.equal(boot.script_sha256,hash(fileURLToPath(import.meta.url)));
 socket=net.createConnection('\\\\.\\pipe\\'+pipe);let pending='';
 socket.setEncoding('utf8');socket.on('error',()=>{ended=true;process.exitCode=97;});
 socket.on('end',()=>{ended=true;clearInterval(tick);});
 socket.on('data',part=>{assert.equal(ended,false);pending+=part;
  while(pending.includes('\n')){const cut=pending.indexOf('\n'),line=pending.slice(0,cut).replace(/\r$/u,'');pending=pending.slice(cut+1);
   const [kind,id,phase,binding,nonce,...extra]=line.split('|');
   assert.equal(kind,'DECIDE');assert.equal(extra.length,0);assert.match(nonce,/^[a-f0-9]{64}$/u);assert.ok(!seen.has(nonce));
   const row=read('native-operation-table-v2.json').entries.find(row=>row.operation_id===id);
   assert.ok(row);assert.equal(row.binding_sha256,binding);assert.equal(phase,phases.has(id)?'resume':'create');
   assert.ok(fs.existsSync(path.join(root,'flight-'+id+'.json')));
   if(phase==='resume')assert.ok(fs.existsSync(path.join(root,'stopped-'+id+'.json')));
   seen.add(nonce);phases.set(id,phase);
   const result={operation_id:id,phase,binding_sha256:binding,nonce,publication_admitted:false};
   const file=path.join(root,'decision-'+id+'-'+phase+'.json'),fd=fs.openSync(file,'wx');
   try{fs.writeFileSync(fd,JSON.stringify(result));fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
   assert.deepEqual(JSON.parse(fs.readFileSync(file)),result);
   socket.write('PROCEED|'+[id,phase,binding,nonce].join('|')+'\n');
  }
 });
},20);
'@
[IO.File]::WriteAllText($actorScript,$fixedActor,[Text.UTF8Encoding]::new($false))
$npmCli=Join-Path $sourceDir 'npm-cli.js'
$safeNpm=@'
'use strict';
if(process.env.WINSMUX_NPM_TOKEN!=='synthetic-provider-fixture-value'||process.env.GH_TOKEN)process.exit(41);
process.stdout.write('safe-native-fixture-output\n');
'@
[IO.File]::WriteAllText($npmCli,$safeNpm,[Text.UTF8Encoding]::new($false))
# Node records its own bigint filesystem identities; no Python/Node-width bridge.
$inventoryProgram=@'
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const root=fs.realpathSync.native(process.argv[1]);
const identity=file=>Object.fromEntries(['dev','ino','nlink','size','mtimeNs','ctimeNs'].map(key=>[key,String(fs.lstatSync(file,{bigint:true})[key])]));
const names=fs.readdirSync(root).sort();
if(JSON.stringify(names)!==JSON.stringify(['npm-cli.js','publication-authority.test.mjs']))throw Error('Closed fixture sources required');
console.log(JSON.stringify({files:names.map(name=>{const file=path.join(root,name),raw=fs.readFileSync(file);return {path:file,bytes:raw.length,sha256:crypto.createHash('sha256').update(raw).digest('hex'),identity:identity(file)};}),directories:[{path:root,names,identity:identity(root)}],publication_admitted:false}));
'@
$manifestJson=& $NodeImage '-e' $inventoryProgram $sourceDir
if($LASTEXITCODE -ne 0){throw 'Owned fixture identity preparation failed'}
$sourceManifest=Save 'runtime-source-manifest.json' (($manifestJson -join "`n") | ConvertFrom-Json)
$guard=Join-Path $repoRoot 'scripts/publication-node-source-guard.mjs'
$held=[IntegratedPublicationCustody]::new($fixture.bundle_root,[string[]]$fixture.names,[string[]]$fixture.hashes)
$count=$held.FixRuntimeSources($sourceManifest,(Hash $sourceManifest),$guard,(Hash $guard))
if($count -ne 2){throw 'Exact two-file fixture source closure required'}
$profile=$held.PreparePublicationRuntime()
$foreignDir=Join-Path $fixture.fixture_root 'foreign-source';[IO.Directory]::CreateDirectory($foreignDir) | Out-Null
$foreignCli=Join-Path $foreignDir 'npm-cli.js';[IO.File]::Copy($npmCli,$foreignCli,$false)
$foreignHoldRefused=$false
try{$held.HoldNpmCli($foreignCli,(Hash $foreignCli))}catch{$foreignHoldRefused=$true}
if(-not $foreignHoldRefused -or $held.NpmCliHeld){throw 'Same bytes at different identity/outside source closure were admitted'}
$owner=[IntegratedPublicationCustody]::CurrentOwnerIdentity()
$pipe=[Guid]::NewGuid().ToString('D')
$actorHash=Hash $actorScript
$persistActor=[Action[IntegratedPublicationCustody+ActorIdentity]]{param($identity)
 Save 'authority-actor.json' @{pid=$identity.Pid;creation_filetime=$identity.CreationFileTime.ToString()} | Out-Null
 Save 'authority-owner.json' @{pid=$owner.Pid;creation_filetime=$owner.CreationFileTime.ToString();job_name=$held.JobName} | Out-Null
 Save 'authority-bootstrap.json' @{actor_pid=$identity.Pid;actor_creation_filetime=$identity.CreationFileTime.ToString();owner_pid=$owner.Pid;owner_creation_filetime=$owner.CreationFileTime.ToString();node_sha256=$NodeHash;script_sha256=$actorHash;synthetic=$true;publication_admitted=$false} | Out-Null
}
$authority=$held.StartAuthorityActor($pipe,$NodeImage,$NodeHash,$actorScript,$actorHash,[string[]]@($fixture.fixture_root,$pipe,$owner.Pid.ToString()),$fixture.fixture_root,15000,$persistActor)
Save 'authority-listening.json' @{event='listening'} | Out-Null
$authority.Accept()
$gh=Join-Path $fixture.fixture_root 'gh.exe'
# This renamed pinned Node image is the sole safe GitHub endpoint; no gh bytes run.
[IO.File]::Copy($NodeImage,$gh,$false)
$assetManifest=Get-Content -LiteralPath (Join-Path $fixture.fixture_root 'publication-assets.json') -Raw | ConvertFrom-Json
$runtime=@{source_manifest=$profile.SourceManifest;source_manifest_sha256=$profile.SourceManifestSha256;guard_file=$profile.GuardFile;guard_sha256=$profile.GuardSha256;temp_directory=$profile.TemporaryDirectory;user_config=$profile.UserConfig;global_config=$profile.GlobalConfig;npm_cache=$profile.NpmCache}
$npmSource=($manifestJson -join "`n") | ConvertFrom-Json
$npmRow=@($npmSource.files | Where-Object {$_.path -ceq $npmCli})[0]
$releaseAssets=@($assetManifest.assets | Where-Object {$_.path -ceq 'release-body.md'})
$uploadAssets=@($assetManifest.assets | Where-Object {$_.path.StartsWith('core/') -or $_.path.StartsWith('desktop/')})
$npmAssets=@($assetManifest.assets | Where-Object {$_.path -ceq 'npm/winsmux-0.38.0.tgz'})
$entries=@(
 @{operation_id='github-release';binding_sha256=('1'*64);destination='https://github.com/Sora-bluesky/winsmux/releases/tag/v0.38.0';assets=$releaseAssets;kind='github_release_create';executable=$gh;executable_sha256=(Hash $gh);arguments=@('release','create','v0.38.0','--repo','github.com/Sora-bluesky/winsmux','--target',$fixture.candidate_identity.source_commit,'--title','v0.38.0','--notes-file',(Join-Path $fixture.bundle_root 'release-body.md'));additional_read_inputs=@();working_directory=$fixture.bundle_root;publication_admitted=$false},
 @{operation_id='github-assets';binding_sha256=('2'*64);destination='https://github.com/Sora-bluesky/winsmux/releases/tag/v0.38.0';assets=$uploadAssets;kind='github_release_upload';executable=$gh;executable_sha256=(Hash $gh);arguments=(@('release','upload','v0.38.0','--repo','github.com/Sora-bluesky/winsmux')+@($uploadAssets | ForEach-Object {Join-Path $fixture.bundle_root $_.path}));additional_read_inputs=@();working_directory=$fixture.bundle_root;publication_admitted=$false},
 @{operation_id='npm-archive';binding_sha256=('3'*64);destination='https://registry.npmjs.org/winsmux';assets=$npmAssets;kind='npm_publish';executable=$NodeImage;executable_sha256=$NodeHash;arguments=@('--no-addons','--import',([Uri]::new($guard).AbsoluteUri),$npmCli,'publish',(Join-Path $fixture.bundle_root 'npm/winsmux-0.38.0.tgz'),'--ignore-scripts','--registry=https://registry.npmjs.org','--tag','latest',('--userconfig='+$profile.UserConfig),('--globalconfig='+$profile.GlobalConfig),('--cache='+$profile.NpmCache),('--prefix='+$fixture.bundle_root),'--logs-max=0','--loglevel=silent','--update-notifier=false','--audit=false','--fund=false','--provenance=false');additional_read_inputs=@($npmRow);working_directory=$fixture.bundle_root;publication_admitted=$false}
)
$table=@{schema='winsmux-native-publication-operation-table/v2';candidate_identity=$fixture.candidate_identity;bundle_root=$fixture.bundle_root;parent_session='synthetic-native-v2';entries=$entries;runtime_inputs=$runtime;action_time_authority_verified=$false;native_custody_verified=$false;publication_admitted=$false}
$tableFile=Save 'native-operation-table-v2.json' $table
$tableJson=[IO.File]::ReadAllText($tableFile)
$checks=0
function RejectTable([string]$Name,[scriptblock]$Change){
 $mutated=$tableJson | ConvertFrom-Json
 & $Change $mutated
 $file=Save ('refused-'+$Name+'.json') $mutated
 $refused=$false
 try{$held.FixPublicationOperations($file,(Hash $file),'synthetic-native-v2') | Out-Null}catch{$refused=$true}
 if(-not $refused -or $held.NativeCreateCalls -ne 0){throw ('Expected native table refusal missing: '+$Name)}
 if([PublicationV2CustodyProof]::BindingPublished($held)){throw 'Invalid table published an operation/CLI binding'}
 $script:checks++
}
RejectTable 'prefix-twice' {param($v)$v.entries[2].arguments=@('--no-addons','--import',([Uri]::new($guard).AbsoluteUri))+$v.entries[2].arguments}
RejectTable 'prefix-missing' {param($v)$v.entries[2].arguments=@($v.entries[2].arguments | Select-Object -Skip 3)}
RejectTable 'runtime' {param($v)$v.runtime_inputs.user_config=$profile.GlobalConfig}
RejectTable 'foreign-cli' {param($v)$v.entries[2].additional_read_inputs[0].path=$actorScript}
RejectTable 'unknown-provider-operation' {param($v)$v.entries[2].operation_id='arbitrary'}
RejectTable 'image' {param($v)$v.entries[2].executable=$gh}
RejectTable 'binding-duplicate' {param($v)$v.entries[1].binding_sha256=$v.entries[0].binding_sha256}
RejectTable 'argv-credential' {param($v)$v.entries[2].arguments+=@('--token=synthetic')}
RejectTable 'true-authority' {param($v)$v.publication_admitted=$true}
if($held.FixPublicationOperations($tableFile,(Hash $tableFile),'synthetic-native-v2') -ne 3){throw 'Fixed native v2 table not accepted'}
foreach($entry in $entries){$op=$held.SelectPublicationOperation($entry.operation_id);if($op.Id -cne $entry.operation_id -or $op.BindingSha256 -cne $entry.binding_sha256){throw 'Original operation selection differs'};$checks++}
# Provider omission must fail before callback/native create; no field is repaired.
$missingProvider=$false
try{$held.CreatePublicationOperation($held.SelectPublicationOperation('github-release'),[Action[string]]{param($j)throw 'Unbound provider reached persistence'},[Action[uint,long,string]]{param($p,$t,$j)throw 'Unbound provider created root'}) | Out-Null}catch{$missingProvider=$true}
if(-not $missingProvider -or $held.NativeCreateCalls -ne 0){throw 'Missing provider accepted'};$checks++
# Fake in-memory sources only. Actual store/public payload remains outside this proof.
$script:credentialReads=0
$fakeSource=[Func[string]]{$script:credentialReads++;if($Scenario -ceq 'callback-actor'){[PublicationV2CustodyProof]::KillActor($held,$authority,$owner.Pid,$NodeImage)};return 'synthetic-provider-fixture-value'}
foreach($provider in @('github','npm')){$held.BindProviderCredentialSource($provider,[Guid]::NewGuid().ToString('D'),$fakeSource);$checks++}
foreach($provider in @('unknown','github','npm')){$refused=$false;try{$held.BindProviderCredentialSource($provider,[Guid]::NewGuid().ToString('D'),$fakeSource)}catch{$refused=$true};if(-not $refused){throw 'Provider source inventory refusal missing'};$checks++}
foreach($provider in @('github','npm')){
 $image=if($provider -eq 'github'){$gh}else{$NodeImage}
 $manifest=if($provider -eq 'npm'){$sourceManifest}else{$null}
 $manifestHash=if($provider -eq 'npm'){Hash $sourceManifest}else{$null}
 $plain=[IntegratedPublicationEnvironment]::Create($provider,$profile.TemporaryDirectory,$image,$manifest,$manifestHash)
 $auth=[IntegratedPublicationEnvironment]::CreateAuthenticated($provider,$profile.TemporaryDirectory,$image,$manifest,$manifestHash,'synthetic-provider-fixture-value')
 try{
  if($plain.Sha256 -cne $auth.Sha256 -or ($auth.Entries -join "`n").Contains('synthetic-provider-fixture-value')){throw 'Credential leaked into environment observation/hash'}
  $expectedName=if($provider -eq 'github'){'GH_TOKEN'}else{'WINSMUX_NPM_TOKEN'}
  if($auth.AuthenticationVariable -cne $expectedName){throw 'Provider authentication key differs'}
  # Read the private block only through its measured private field length.
  $length=[IntegratedPublicationEnvironment].GetField('blockBytes',[Reflection.BindingFlags]'NonPublic,Instance').GetValue($auth)
  $raw=[byte[]]::new($length);[Runtime.InteropServices.Marshal]::Copy($auth.Block,$raw,0,$length)
  $block=[Text.Encoding]::Unicode.GetString($raw);[Array]::Clear($raw,0,$raw.Length)
  if(-not $block.Contains($expectedName+'=synthetic-provider-fixture-value') -or ($provider -eq 'github' -and $block.Contains('WINSMUX_NPM_TOKEN=')) -or ($provider -eq 'npm' -and $block.Contains('GH_TOKEN='))){throw 'Provider isolation differs'}
  $block=$null;$checks++
 }finally{$plain.Dispose();$auth.Dispose()}
}
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Reflection;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
public static class PublicationV2FiniteProof {
 const BindingFlags Private=BindingFlags.NonPublic|BindingFlags.Instance;
 public static int Capture(Type owner){
  var type=owner.GetNestedType("SensitiveCapture",BindingFlags.NonPublic);
  var constructor=type.GetConstructor(Private,null,new[]{typeof(byte[][])},null);
  var feed=type.GetMethod("Feed",Private);var finish=type.GetMethod("Finish",Private);int checks=0;
  var value="synthetic-provider-fixture-value";
  var patterns=new[]{Encoding.UTF8.GetBytes(value),Encoding.Unicode.GetBytes(value),Encoding.BigEndianUnicode.GetBytes(value)};
  foreach(var encoding in new[]{Encoding.UTF8,Encoding.Unicode,Encoding.BigEndianUnicode}){
   var output=encoding.GetBytes("prefix:"+value+":suffix");
   for(int split=1;split<output.Length;split++){
    using(var capture=(IDisposable)constructor.Invoke(new object[]{patterns}))using(var hash=IncrementalHash.CreateHash(HashAlgorithmName.SHA256)){
     feed.Invoke(capture,new object[]{output.Take(split).ToArray(),split,hash});
     feed.Invoke(capture,new object[]{output.Skip(split).ToArray(),output.Length-split,hash});
     if(finish.Invoke(capture,new object[]{hash})!=null)throw new Exception("Sensitive capture was not refused");checks++;
    }
   }
  }
  var safe=Encoding.UTF8.GetBytes("safe output without provider material");
  using(var capture=(IDisposable)constructor.Invoke(new object[]{patterns}))using(var hash=IncrementalHash.CreateHash(HashAlgorithmName.SHA256)){
   for(int i=0;i<safe.Length;i++)feed.Invoke(capture,new object[]{new[]{safe[i]},1,hash});
   if((string)finish.Invoke(capture,new object[]{hash})!=Convert.ToHexString(SHA256.HashData(safe)).ToLowerInvariant())throw new Exception("Safe output digest differs");checks++;
  }
  var pipeType=owner.GetNestedType("ChildOutput",BindingFlags.NonPublic);
  foreach(bool sensitive in new[]{false,true}){
   using(var child=(IDisposable)Activator.CreateInstance(pipeType,true)){
    pipeType.GetMethod("ProtectSensitiveValue",Private).Invoke(child,new object[]{value});
    var output=Encoding.UTF8.GetBytes(sensitive?"prefix:"+value+":suffix":"safe-pipe-output");
    var handle=(IntPtr)pipeType.GetField("OutWrite",Private).GetValue(child);
    using(var stream=new FileStream(new SafeFileHandle(handle,false),FileAccess.Write)){stream.Write(output);stream.Flush();}
    pipeType.GetMethod("Created",Private).Invoke(child,null);
    var result=pipeType.GetProperty("OutResult",Private).GetValue(child);
    var resultType=result.GetType();var failure=(string)resultType.GetProperty("FailureKind").GetValue(result);
    var digest=(string)resultType.GetProperty("Sha256").GetValue(result);
    if(!(bool)resultType.GetProperty("Complete").GetValue(result))throw new Exception("Pipe capture incomplete");
    if(sensitive?(failure!="SensitiveOutputRefused"||digest!=null):(failure!=null||digest!=Convert.ToHexString(SHA256.HashData(output)).ToLowerInvariant()))throw new Exception("Actual pipe capture refusal/hash differs");
    pipeType.GetProperty("ErrorResult",Private).GetValue(child);checks++;
   }
  }
  return checks;
 }
}
'@
$captureChecks=[PublicationV2FiniteProof]::Capture([IntegratedPublicationCustody]);$checks+=$captureChecks
if($script:credentialReads -ne 0 -or $held.NativeCreateCalls -ne 0){throw 'Premature credential read/native create'}
$lateHoldRefused=$false
try{$held.HoldNpmCli($npmCli,(Hash $npmCli))}catch{$lateHoldRefused=$true}
if(-not $lateHoldRefused){throw 'Late CLI Hold accepted'};$checks++
$arbitraryRefused=$false
try{$held.CreateChild($NodeImage,$NodeHash,[string[]]@('--version'),$fixture.bundle_root,[Action[string]]{param($h)throw 'Arbitrary flight reached'}) | Out-Null}catch{$arbitraryRefused=$true}
if(-not $arbitraryRefused -or $held.NativeCreateCalls -ne 0){throw 'Arbitrary child bypass accepted'};$checks++
Start-FixtureKeeper $held $fixture $repoRoot
$held.Verify();if($held.ActiveMembers() -ne 0){throw 'Fixture publication Job is not idle'}
$script:nativeRoots=@();$script:callbackBefore=$script:credentialReads
$nonOriginalRefused=$false
try{$held.CreatePublicationOperation([PublicationV2CustodyProof]::NonOriginal($held.SelectPublicationOperation('github-release')),[Action[string]]{param($j)throw 'Foreign object reached persistence'},[Action[uint,long,string]]{param($p,$b,$j)throw 'Foreign object created root'}) | Out-Null}catch{$nonOriginalRefused=$true}
if(-not $nonOriginalRefused -or $held.NativeCreateCalls -ne 0){throw 'Non-original operation admitted'};$checks++
$safeGithub='if(process.env.GH_TOKEN!=="synthetic-provider-fixture-value"||process.env.WINSMUX_NPM_TOKEN)process.exit(42);process.stdout.write("safe-native-fixture-output\n");'
foreach($entry in $entries){
 $operation=$held.SelectPublicationOperation($entry.operation_id)
 $arguments=if($entry.kind -ceq 'npm_publish'){@('--no-addons','--import',([Uri]::new($guard).AbsoluteUri),$npmCli)}else{@('--no-addons','--input-type=commonjs','--eval',$safeGithub)}
 [PublicationV2CustodyProof]::SafeArguments($operation,[string[]]$arguments)
}
$persist=[Action[string]]{param($jobName)
 Save ('flight-'+$script:currentId+'.json') @{operation_id=$script:currentId;job=$jobName;publication_admitted=$false} | Out-Null
 if($Scenario -ceq 'persist-actor'){[PublicationV2CustodyProof]::KillActor($held,$authority,$owner.Pid,$NodeImage)}
}
$stopped=[Action[uint,long,string]]{param($pidValue,$birth,$job)
 Save ('stopped-'+$script:currentId+'.json') @{pid=$pidValue;birth=$birth.ToString();job=$job;stopped=$true;publication_admitted=$false} | Out-Null
 if($Scenario -ceq 'stopped-actor'){[PublicationV2CustodyProof]::KillActor($held,$authority,$owner.Pid,$NodeImage)}
}
$created=[Action[uint,long,string]]{param($pidValue,$birth,$job)
 Save ('resume-'+$script:currentId+'.json') @{pid=$pidValue;birth=$birth.ToString();job=$job;publication_admitted=$false} | Out-Null
}
if($Scenario -ceq 'keeper-dead'){[PublicationV2CustodyProof]::KillKeeper($held)}
$failureRefused=$false;$normalDisposeRefused=$false;$forcedCleanup=$false
foreach($entry in $entries){
 $script:currentId=$entry.operation_id;$operation=$held.SelectPublicationOperation($entry.operation_id)
 $child=$null
 try{
  $child=$held.CreatePublicationOperation($operation,$persist,$stopped)
  if($Scenario -notin @('normal','stopped-actor')){throw 'Failure scenario unexpectedly created a native root'}
  $held.ResumeChild($child,$created)
  if($Scenario -cne 'normal'){throw 'Actor-dead root was resumed'}
  while(-not $held.HasExited($child)){[Threading.Thread]::Sleep(20)}
  $output=$held.ObserveChildOutput($child)
  if($output.Pid -ne $child.Pid -or $output.CreationFileTime -ne $child.CreationFileTime -or $output.ExitCode -ne 0 -or $held.ActiveMembers() -ne 0 -or -not $output.Stdout.Complete -or -not $output.Stderr.Complete -or $output.Stdout.FailureKind -or $output.Stderr.FailureKind){throw 'Synthetic terminal tuple/capture/Job differs'}
  $safeBytes=[Text.Encoding]::UTF8.GetBytes('safe-native-fixture-output'+[char]10)
  $expectedOut=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($safeBytes)).ToLowerInvariant()
  if($output.Stdout.Sha256 -cne $expectedOut -or $output.Stdout.Bytes -ne $safeBytes.Length -or $output.Stderr.Bytes -ne 0){throw 'Safe endpoint output differs'}
  Save ('terminal-'+$script:currentId+'.json') @{pid=$child.Pid;birth=$child.CreationFileTime.ToString();exit_code=$output.ExitCode;job_active=$held.ActiveMembers();stdout_sha256=$output.Stdout.Sha256;stderr_sha256=$output.Stderr.Sha256;capture_complete=$true;publication_admitted=$false} | Out-Null
  $twiceCreate=$false;$twiceResume=$false
  try{$held.CreatePublicationOperation($operation,$persist,$stopped) | Out-Null}catch{$twiceCreate=$true}
  try{$held.ResumeChild($child,$created)}catch{$twiceResume=$true}
  if(-not $twiceCreate -or -not $twiceResume){throw 'Repeated operation accepted'}
  $script:nativeRoots+=@{id=$script:currentId;pid=$child.Pid;birth=$child.CreationFileTime.ToString();native_create=1;native_resume=1;nonces=2;terminal=$true;job_active=0}
 }catch{
  $originalOperationError=$_
  $actualActorExited=$authority.ActorExited
  Save 'original-operation-failure.json' @{scenario=$Scenario;operation_id=$script:currentId;exception_type=$originalOperationError.Exception.GetType().FullName;exception_message=$originalOperationError.Exception.Message;inner_exception=if($originalOperationError.Exception.InnerException){$originalOperationError.Exception.InnerException.Message}else{$null};error_id=$originalOperationError.FullyQualifiedErrorId;position=$originalOperationError.InvocationInfo.PositionMessage;script_stack=$originalOperationError.ScriptStackTrace;actor_pid=$authority.Actor.Pid;actor_birth=$authority.Actor.CreationFileTime.ToString();owner_pid=$authority.Owner.Pid;owner_birth=$authority.Owner.CreationFileTime.ToString();actor_exited=$actualActorExited;actor_exit_code=if($actualActorExited){$authority.ActorExitCode}else{$null};native_create_calls=$held.NativeCreateCalls;native_resume_calls=$held.NativeResumeCalls;callback_calls=$script:credentialReads;publication_admitted=$false} | Out-Null
  if($Scenario -ceq 'normal'){throw $originalOperationError}
  $failureRefused=$true
  $roots=$held.ObserveCreatedChildren()
  if($Scenario -ceq 'stopped-actor'){
   if($roots.Length -ne 1 -or $held.NativeCreateCalls -ne 1 -or $held.NativeResumeCalls -ne 0 -or $held.ActiveMembers() -ne 1){throw 'Stopped root identity/counters not retained'}
   $child=$roots[0]
  }elseif($roots.Length -ne 0 -or $held.NativeCreateCalls -ne 0 -or $held.NativeResumeCalls -ne 0){throw 'Refused scenario created/resumed a root'}
  $expectedReads=if($Scenario -in @('callback-actor','stopped-actor')){1}else{0}
  if($script:credentialReads -ne $expectedReads){throw 'Credential callback count differs'}
  if($Scenario -cne 'keeper-dead'){try{$held.Dispose()}catch{$normalDisposeRefused=$true}
   if(-not $normalDisposeRefused){throw 'Disconnected custody released normally'}}
  Save 'original-refusal-before-cleanup.json' @{scenario=$Scenario;refused=$failureRefused;normal_dispose_refused=$normalDisposeRefused;native_create_calls=$held.NativeCreateCalls;native_resume_calls=$held.NativeResumeCalls;callback_calls=$script:credentialReads;root=if($child){@{pid=$child.Pid;birth=$child.CreationFileTime.ToString();job=$held.JobName;stopped=$true}}else{$null};publication_admitted=$false} | Out-Null
  $forcedCleanup=[PublicationV2CustodyProof]::ForcedCleanup($held,$authority,$child)
  if($held.ActiveMembers() -ne 0){throw 'Forced fixture cleanup incomplete'}
  break
 }
}
if($Scenario -ceq 'normal'){
 if($held.NativeCreateCalls -ne 3 -or $held.NativeResumeCalls -ne 3 -or $script:credentialReads -ne 3 -or $script:nativeRoots.Length -ne 3){throw 'Shared native normal path counts differ'}
 foreach($entry in $entries){foreach($phase in @('create','resume')){if(-not [IO.File]::Exists((Join-Path $fixture.fixture_root ('decision-'+$entry.operation_id+'-'+$phase+'.json')))){throw 'Original live nonce missing'}}}
 $held.SealLaunches();$held.Dispose()
 Save 'authority-result.json' @{passed=$true;mode='safe-native-three';native_create_calls=3;native_resume_calls=3;normal_release=$true;publication_admitted=$false} | Out-Null
}
$resultFile=Save 'native-v2-result.json' @{passed=$true;scenario=$Scenario;checks=$checks;capture_checks=$captureChecks;provider_reads=$script:credentialReads;synthetic_main_path_operation_attempts=if($Scenario -ceq 'normal'){3}else{1};synthetic_native_create_calls=$held.NativeCreateCalls;synthetic_native_resume_calls=$held.NativeResumeCalls;actual_public_payload_resume_calls=0;credential_store_reads=0;roots=$script:nativeRoots;source_sha256=$expectedImplementation;normal_release=($Scenario -ceq 'normal');original_refusal=$failureRefused;normal_dispose_refused=$normalDisposeRefused;forced_cleanup=@{performed=$forcedCleanup;job_active=0;duplicate_job_handle_closed=$forcedCleanup;original_handles_retained_until_owner_exit=($Scenario -cne 'normal')};publication_admitted=$false;scope='Strict v2 before safe endpoint argv reflection only. Synthetic authenticated custody/callback/nonce/root/capture/Job; actual public payload/store zero. Failure cleanup is separate from normal release.'}
if((Hash $implementation) -cne $expectedImplementation){throw 'Candidate changed during proof'}
$reader.Dispose();$lease.Dispose()
@{passed=$true;result=$resultFile;checks=$checks;scenario=$Scenario;publication_admitted=$false} | ConvertTo-Json -Compress
