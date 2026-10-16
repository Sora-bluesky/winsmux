[CmdletBinding()]
param(
 [switch]$HeadlessParent,
 [switch]$ObserveCapabilityToken,
 [switch]$ProjectionSelfTest,
 [switch]$SourceAdmissionOnly,
 [switch]$PrepareCompilerRoot,
 [string]$SourceCommit,
 [string]$BuildManifest,
 [string]$Surface,[string]$Version,[string]$ReleaseTag,[string]$Repository,
 [switch]$DesktopNativeLifecycle,[string]$DesktopNativeFormat,
 [string]$DesktopNativeSourceCommit,[string]$DesktopNativeCandidateDirectory,
 [string]$DesktopNativeBaselineDirectory,[switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$utf8=[Text.UTF8Encoding]::new($false,$true)
$tests=@('real_host_without_provider_path_keeps_launch_unadvertised','host_startup_fails_closed_before_discovery_when_security_primitives_fail')
function Assert-Fixed([bool]$Condition,[string]$Code) { if(-not $Condition){throw $Code} }
function Assert-CanonicalSourceInputs([string]$Root) {
 # One raw-byte choke point; no newline conversion or alternate hashes are accepted.
 $pins=ConvertFrom-Json -AsHashtable '[{"path":"scripts/test-public-release.ps1","bytes":579080,"sha256":"4c215216c9d8d90a3cafb6797e249b2bbc26bf8efb2683bc2a3e72a9eb5768b7"},{"path":"scripts/DesktopProcessOwner.cs","bytes":24379,"sha256":"cc9d426f86455395b87d1f2d6524deea0ab5ddb4014ad05c58e1e0b576c09a8c"},{"path":"core/tests-rs/workspace_host_e2e.rs","bytes":176368,"sha256":"4c3cfa6b7e1ab781e153298fb0c8189b0efc93a167861a964b6bb96f8bcaedb7"},{"path":"core/tests-rs/support/conpty_json.rs","bytes":12923,"sha256":"8da14f11218bd84c6d2de17d1904705c56b64c44346c3d73138936a2d05859e9"},{"path":"core/crates/winsmux-workspace/src/host/windows.rs","bytes":109509,"sha256":"0f52ea068911987c3ce5288891b2815732a74bf1abc473811d50ab83ddb74d78"},{"path":"core/crates/winsmux-workspace/src/host/process.rs","bytes":10135,"sha256":"a667b3ee876166f5a88366dd2979ccc9f8d70e84d25de594bae7a6403abacc74"},{"path":"core/crates/winsmux-workspace/src/host/security.rs","bytes":45018,"sha256":"a8d904e0378d651a55ca932875526ad249af04198a6ddcf64d08c3b6e76abb1a"},{"path":"core/crates/winsmux-workspace/src/host/mod.rs","bytes":4569,"sha256":"2854949034e622b7bf1fc31118080ec2ee0df04aba4ff895ded241a6a4675dd6"},{"path":"core/crates/winsmux-workspace/src/client/mod.rs","bytes":73120,"sha256":"4fd2ab3e0cc2635d1dad6f774a31b1ed9076672f0d823167eb8d7606d9157ea1"},{"path":"Cargo.toml","bytes":556,"sha256":"3c50db3d0d7650d46dd3342eef78c678c1261a2b3f75dce6d79b1d648a30b5a3"},{"path":"Cargo.lock","bytes":165475,"sha256":"26d1bef4c5a4fc47330468a719d8ff59e0fb85e483aa84d0e0752bba99d85c30"},{"path":"core/Cargo.toml","bytes":4498,"sha256":"a52039539867a3fcdaa3e0fdf8a5a0eea670d0ba5ff0445c046e63d60bd8085d"},{"path":".github/actions/setup-windows-distribution-toolchain/action.yml","bytes":677,"sha256":"7811950cfe808ec3ab951033da4a4760bd37c4348a668739dd074c86fe56b6f2"},{"path":"core/crates/winsmux-workspace/src/host/testing.rs","bytes":89695,"sha256":"58b303cdbca1728a804b09bd6dcb32a95fd203b5a4dc6d15ee50fdbe7634f2b5"}]'
 $attribute=ConvertFrom-Json -AsHashtable '{"path":".gitattributes","bytes":1481,"sha256":"1288f24e7629cbec0701a6d17ce78ecbce87b9cc13fec4d7efb2a841ab7d354d"}'
 $attributePaths=ConvertFrom-Json '[".gitattributes",".github/.gitattributes",".github/actions/.gitattributes",".github/actions/setup-windows-distribution-toolchain/.gitattributes",".github/workflows/.gitattributes","core/.gitattributes","core/crates/.gitattributes","core/crates/winsmux-workspace/.gitattributes","core/crates/winsmux-workspace/src/.gitattributes","core/crates/winsmux-workspace/src/client/.gitattributes","core/crates/winsmux-workspace/src/host/.gitattributes","core/tests-rs/.gitattributes","core/tests-rs/support/.gitattributes","scripts/.gitattributes"]'
 foreach($name in $attributePaths){Assert-Fixed ((Test-Path -LiteralPath (Join-Path $Root $name)) -eq ($name -ceq '.gitattributes')) 'input_attribute_inventory_changed'}
 foreach($pin in @($attribute)+@($pins)){$p=Join-Path $Root $pin.path;Assert-Fixed ((Get-Item -LiteralPath $p).Length -eq $pin.bytes -and (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $pin.sha256) 'input_source_changed'}
}
function Get-HeadlessCompilerNativeSource {
 return @'
namespace WinsmuxHeadlessOwned {
using System;
using System.IO;
using System.Text;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
public static class WinsmuxHeadlessCompilerInputs {
 const string ReceiptName="winsmux-headless-producer.json";
 const string TemporaryName=".winsmux-headless-cli.tmp";
 const string BackupName=".winsmux-headless-cli.backup";
 [StructLayout(LayoutKind.Sequential)] struct FT {public uint low,high;}
 [StructLayout(LayoutKind.Sequential)] struct FI {public uint attributes;public FT creation,access,write;public uint volume,sizeHigh,sizeLow,links,indexHigh,indexLow;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(IntPtr handle,out FI info);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandleW(IntPtr handle,StringBuilder text,uint size,uint flags);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFileAttributesW(string path);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 static void Need(bool ok){if(!ok)throw new InvalidOperationException("Headless compiler input refused");}
 static string Id(FI info){return info.volume+":"+info.indexHigh+":"+info.indexLow;}
 static FI Facts(IntPtr handle){FI info;if(!GetFileInformationByHandle(handle,out info))throw new Win32Exception(Marshal.GetLastWin32Error());Need((info.attributes&0x400)==0);return info;}
 static string Hash(byte[] bytes){using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","").ToLowerInvariant();}
 static bool Equal(byte[] a,byte[] b){if(a.Length!=b.Length)return false;for(int i=0;i<a.Length;i++)if(a[i]!=b[i])return false;return true;}
 static string Canonical(string value){Need(!String.IsNullOrEmpty(value)&&!value.StartsWith("\\\\",StringComparison.Ordinal)&&value.Length>=3&&value[1]==':'&&value.IndexOf(':',2)<0);string full=Path.GetFullPath(value);Need(String.Equals(full,value,StringComparison.OrdinalIgnoreCase));foreach(char ch in value)Need(ch>=32);return full;}
 static void Physical(string value){string current=Canonical(value);for(;;){var h=CreateFileW(current,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);if(h==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error());try{Facts(h);var text=new StringBuilder(32768);uint n=GetFinalPathNameByHandleW(h,text,(uint)text.Capacity,0);Need(n!=0&&n<text.Capacity);string resolved=text.ToString();if(resolved.StartsWith("\\\\?\\",StringComparison.Ordinal))resolved=resolved.Substring(4);Need(String.Equals(Path.GetFullPath(resolved).TrimEnd('\\'),current.TrimEnd('\\'),StringComparison.OrdinalIgnoreCase));}finally{CloseHandle(h);}string parent=Path.GetDirectoryName(current.TrimEnd('\\'));if(String.IsNullOrEmpty(parent))break;current=parent;}}
 static bool Absent(string value){uint attrs=GetFileAttributesW(value);if(attrs!=UInt32.MaxValue)return false;int error=Marshal.GetLastWin32Error();if(error==2||error==3)return true;throw new Win32Exception(error);}
 sealed class W {public string id,sha;public uint links;public byte[] bytes;public FI info;}
 sealed class Lease:IDisposable {
  readonly string path;readonly FileStream file;
  public Lease(string value){path=Canonical(value);Physical(path);var handle=CreateFileW(path,0x80000000,1,IntPtr.Zero,3,0x00200000,IntPtr.Zero);if(handle==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error());var safe=new SafeFileHandle(handle,true);try{var info=Facts(handle);Need((info.attributes&0x10)==0);file=new FileStream(safe,FileAccess.Read);}catch{safe.Dispose();throw;}}
  public W Read(){var info=Facts(file.SafeFileHandle.DangerousGetHandle());Need(file.Length<=Int32.MaxValue);var bytes=new byte[(int)file.Length];file.Position=0;int at=0;while(at<bytes.Length){int n=file.Read(bytes,at,bytes.Length-at);Need(n>0);at+=n;}var after=Facts(file.SafeFileHandle.DangerousGetHandle());Need(SameInfo(info,after));return new W{id=Id(info),sha=Hash(bytes),links=info.links,bytes=bytes,info=info};}
  public void Check(W old){var now=Read();Need(Same(old,now));using(var named=new Lease(path)){Need(Same(old,named.Read()));}}
  public void Dispose(){file.Dispose();}
 }
 static bool SameInfo(FI a,FI b){return Id(a)==Id(b)&&a.links==b.links&&a.sizeHigh==b.sizeHigh&&a.sizeLow==b.sizeLow&&a.write.low==b.write.low&&a.write.high==b.write.high&&a.attributes==b.attributes;}
 static bool Same(W a,W b){return SameInfo(a.info,b.info)&&Equal(a.bytes,b.bytes);}
 static W Read(string path){using(var lease=new Lease(path))return lease.Read();}
 static W Plain(string path){var native=global::WinsmuxDesktopNativeActor.NativeFile(path);var value=Read(path);Need(value.links==1&&value.id==(string)native["identity"]&&value.sha==(string)native["sha256"]&&value.bytes.Length==Convert.ToInt64(native["bytes"]));return value;}
 public static string ReceiptIdentity(FileStream stream){Need(stream!=null&&stream.CanWrite&&stream.Length==0);var info=Facts(stream.SafeFileHandle.DangerousGetHandle());Need(info.links==1&&(info.attributes&0x10)==0);return Id(info);}
 static void MatchPlain(string path,string id,string sha){var current=Plain(path);Need(current.id==id&&current.sha==sha);}
 static void Fire(Action<string> fault,string stage){if(fault!=null)fault(stage);}
 static string Macro(string path,string cli){var first=Plain(path);string text=new UTF8Encoding(false,true).GetString(first.bytes);Need(text.IndexOf('\0')<0);const string prefix="# env-dep:CARGO_BIN_EXE_winsmux=";string value=null;int count=0;foreach(string raw in text.Split('\n')){string line=raw.EndsWith("\r",StringComparison.Ordinal)?raw.Substring(0,raw.Length-1):raw;if(line.StartsWith(prefix,StringComparison.Ordinal)){count++;value=line.Substring(prefix.Length);}}Need(count==1);var decoded=new StringBuilder();for(int i=0;i<value.Length;i++){char ch=value[i];if(ch=='\\'){Need(i+1<value.Length&&value[i+1]=='\\');decoded.Append('\\');i++;}else{Need(ch>=32);decoded.Append(ch);}}Need(String.Equals(Canonical(decoded.ToString()),cli,StringComparison.OrdinalIgnoreCase));var last=Plain(path);Need(Same(first,last));return first.sha;}
 static string S(IDictionary state,string key){Need(state.Contains(key)&&state[key] is string);return (string)state[key];}
 static readonly string[] Keys={"root","root_id","receipt_id","receipt_sha","manifest","manifest_id","manifest_sha","test","test_id","test_sha","macro","macro_id","macro_sha","script","script_id","script_sha","cli","cli_id","cli_sha","kind","old_id"};
 static void Shape(IDictionary state){Need(state!=null&&state.Count==Keys.Length);foreach(string key in Keys)S(state,key);}
 static string A(string root){return Path.Combine(root,"debug","winsmux.exe");}
 static string B(string root){return Path.Combine(root,"debug","deps","winsmux.exe");}
 static string T(string root){return Path.Combine(root,"debug",TemporaryName);}
 static string K(string root){return Path.Combine(root,"debug",BackupName);}
 static void Producer(string root,string rootId,string receiptId,string receiptSha){Physical(root);Need(global::WinsmuxDesktopNativeActor.NativeDirectory(root,false)==rootId);MatchPlain(Path.Combine(root,ReceiptName),receiptId,receiptSha);}
 static void Paths(string root,string test,string cli,string macro){Canonical(root);Need(String.Equals(Canonical(cli),A(root),StringComparison.OrdinalIgnoreCase));Need(String.Equals(Path.GetDirectoryName(Canonical(test)),Path.Combine(root,"debug","deps"),StringComparison.OrdinalIgnoreCase));Need(System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(test),"^workspace_host_e2e-[a-f0-9]+\\.exe$",System.Text.RegularExpressions.RegexOptions.CultureInvariant));Need(String.Equals(Canonical(macro),Path.ChangeExtension(test,".d"),StringComparison.OrdinalIgnoreCase));Physical(test);Physical(cli);Physical(macro);}
 public static void Verify(IDictionary state){Shape(state);string root=S(state,"root"),test=S(state,"test"),cli=S(state,"cli"),macro=S(state,"macro");Paths(root,test,cli,macro);Producer(root,S(state,"root_id"),S(state,"receipt_id"),S(state,"receipt_sha"));MatchPlain(S(state,"manifest"),S(state,"manifest_id"),S(state,"manifest_sha"));MatchPlain(test,S(state,"test_id"),S(state,"test_sha"));MatchPlain(S(state,"script"),S(state,"script_id"),S(state,"script_sha"));MatchPlain(cli,S(state,"cli_id"),S(state,"cli_sha"));MatchPlain(macro,S(state,"macro_id"),S(state,"macro_sha"));Need(Macro(macro,cli)==S(state,"macro_sha")&&Absent(T(root)));string kind=S(state,"kind");if(kind=="plain"){Need(Absent(K(root))&&S(state,"old_id")=="");}else{Need(kind=="detached");using(var b=new Lease(B(root)))using(var k=new Lease(K(root))){var wb=b.Read();var wk=k.Read();Need(wb.links==2&&wk.links==2&&wb.id==S(state,"old_id")&&wk.id==wb.id&&wb.id!=S(state,"cli_id")&&wb.sha==S(state,"cli_sha")&&Equal(wb.bytes,wk.bytes));b.Check(wb);k.Check(wk);}}}
 public static Dictionary<string,object> Normalize(string root,string rootId,string receiptId,string receiptSha,string manifest,string test,string cli,string script){return NormalizeCore(root,rootId,receiptId,receiptSha,manifest,test,cli,script,null);}
 // The same transaction is exercised with declared fault callbacks only by the local finite runner.
 public static Dictionary<string,object> NormalizeForProof(string root,string rootId,string receiptId,string receiptSha,string manifest,string test,string cli,string script,Action<string> fault){return NormalizeCore(root,rootId,receiptId,receiptSha,manifest,test,cli,script,fault);}
 static Dictionary<string,object> NormalizeCore(string root,string rootId,string receiptId,string receiptSha,string manifest,string test,string cli,string script,Action<string> fault){
  root=Canonical(root);test=Canonical(test);cli=Canonical(cli);manifest=Canonical(manifest);script=Canonical(script);string macro=Path.ChangeExtension(test,".d");Paths(root,test,cli,macro);Producer(root,rootId,receiptId,receiptSha);Need(Absent(T(root))&&Absent(K(root)));
  var wm=Plain(manifest);var wt=Plain(test);var ws=Plain(script);var wd=Plain(macro);Need(Macro(macro,cli)==wd.sha);Fire(fault,"input_read");
  string kind="plain",oldId="";W final;
  using(var a=new Lease(cli)){
   var original=a.Read();Need(original.links==1||original.links==2);
   if(original.links==1){a.Check(original);final=original;}
   else{
    kind="detached";oldId=original.id;
    using(var b=new Lease(B(root))){var peer=b.Read();Need(peer.links==2&&peer.id==original.id&&Equal(peer.bytes,original.bytes));Fire(fault,"copy");
     using(var output=new FileStream(T(root),FileMode.CreateNew,FileAccess.Write,FileShare.None)){output.Write(original.bytes,0,original.bytes.Length);Fire(fault,"flush");output.Flush(true);}
     Fire(fault,"temporary_witness");var temporary=Plain(T(root));Need(temporary.id!=original.id&&Equal(temporary.bytes,original.bytes));a.Check(original);b.Check(peer);Producer(root,rootId,receiptId,receiptSha);MatchPlain(manifest,wm.id,wm.sha);MatchPlain(test,wt.id,wt.sha);MatchPlain(script,ws.id,ws.sha);MatchPlain(macro,wd.id,wd.sha);Need(Macro(macro,cli)==wd.sha&&Absent(K(root)));Fire(fault,"before_replace");a.Check(original);b.Check(peer);MatchPlain(T(root),temporary.id,temporary.sha);Need(Absent(K(root)));
     // Close all leases that deny delete before the one replacement below.
     final=temporary;
    }
   }
  }
  if(kind=="detached"){
   Fire(fault,"replace");Producer(root,rootId,receiptId,receiptSha);MatchPlain(manifest,wm.id,wm.sha);MatchPlain(test,wt.id,wt.sha);MatchPlain(script,ws.id,ws.sha);MatchPlain(macro,wd.id,wd.sha);Need(Macro(macro,cli)==wd.sha);var lastA=Read(cli);var lastB=Read(B(root));Need(lastA.links==2&&lastB.links==2&&lastA.id==oldId&&lastB.id==oldId&&Equal(lastA.bytes,final.bytes)&&Equal(lastB.bytes,final.bytes));MatchPlain(T(root),final.id,final.sha);Need(Absent(K(root)));File.Replace(T(root),cli,K(root));Fire(fault,"after_replace");
   var output=Plain(cli);Need(output.id==final.id&&Equal(output.bytes,final.bytes)&&Absent(T(root)));
   using(var b=new Lease(B(root)))using(var k=new Lease(K(root))){var peer=b.Read();var backup=k.Read();Need(peer.links==2&&backup.links==2&&peer.id==oldId&&backup.id==oldId&&Equal(peer.bytes,final.bytes)&&Equal(backup.bytes,final.bytes));b.Check(peer);k.Check(backup);}final=output;
  }else{var current=Plain(cli);Need(current.id==final.id&&Equal(current.bytes,final.bytes));final=current;}
  var state=new Dictionary<string,object>{{"root",root},{"root_id",rootId},{"receipt_id",receiptId},{"receipt_sha",receiptSha},{"manifest",manifest},{"manifest_id",wm.id},{"manifest_sha",wm.sha},{"test",test},{"test_id",wt.id},{"test_sha",wt.sha},{"macro",macro},{"macro_id",wd.id},{"macro_sha",wd.sha},{"script",script},{"script_id",ws.id},{"script_sha",ws.sha},{"cli",cli},{"cli_id",final.id},{"cli_sha",final.sha},{"kind",kind},{"old_id",oldId}};
  Fire(fault,"post_verify");Verify(state);return state;
 }
}
}
'@
}
function Write-NewJson([string]$Path,$Value){$bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes(($Value|ConvertTo-Json -Depth 12 -Compress)+[char]10);$file=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}}
function Get-HeadlessProducerRoot([string]$Source) {
 return [IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP ('winsmux-headless-build-'+$env:GITHUB_RUN_ID+'.'+$env:GITHUB_RUN_ATTEMPT+'.'+$Source)))
}
function New-HeadlessCompilerProducer([string]$Root,[string]$Source,[string]$Run,[string]$Attempt) {
 Assert-Fixed ($Source -cmatch '^[a-f0-9]{40}$' -and $Run -cmatch '^[1-9][0-9]*$' -and $Attempt -cmatch '^[1-9][0-9]*$') 'producer_identity'
 $Root=[IO.Path]::GetFullPath($Root)
 $id=[WinsmuxDesktopNativeActor]::NativeDirectory($Root,$true)
 $stream=[IO.FileStream]::new((Join-Path $Root 'winsmux-headless-producer.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$receiptId=[WinsmuxHeadlessOwned.WinsmuxHeadlessCompilerInputs]::ReceiptIdentity($stream);$record=[ordered]@{schema='winsmux-headless-compiler-producer/v1';root=$Root;identity=$id;receipt_identity=$receiptId;source_commit=$Source;run=$Run;attempt=$Attempt};$bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes(($record|ConvertTo-Json -Compress)+[char]10);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
 [void](Read-HeadlessCompilerProducer $Root $Source $Run $Attempt)
}
function Read-HeadlessCompilerProducer([string]$Root,[string]$Source,[string]$Run,[string]$Attempt) {
 $Root=[IO.Path]::GetFullPath($Root);$path=Join-Path $Root 'winsmux-headless-producer.json'
 $before=[WinsmuxDesktopNativeActor]::NativeFile($path)
 $row=[WinsmuxDesktopNativeActor]::ReadChild($path)|ConvertFrom-Json -AsHashtable
 $keys=@('schema','root','identity','receipt_identity','source_commit','run','attempt')
 Assert-Fixed ((@($row.Keys|Sort-Object -CaseSensitive)-join [char]10) -ceq (@($keys|Sort-Object -CaseSensitive)-join [char]10)) 'producer_shape'
 Assert-Fixed ($row.schema -ceq 'winsmux-headless-compiler-producer/v1' -and [string]::Equals($row.root,$Root,[StringComparison]::OrdinalIgnoreCase) -and $row.source_commit -ceq $Source -and $row.run -ceq $Run -and $row.attempt -ceq $Attempt -and $row.identity -ceq [WinsmuxDesktopNativeActor]::NativeDirectory($Root,$false) -and $row.receipt_identity -ceq $before['identity']) 'producer_binding'
 $after=[WinsmuxDesktopNativeActor]::NativeFile($path)
 Assert-Fixed ($after['identity'] -ceq $before['identity'] -and $after['sha256'] -ceq $before['sha256']) 'producer_changed'
 return @{identity=$row.identity;receipt_id=$after['identity'];receipt_sha=$after['sha256']}
}
function Read-HeadlessBuildArtifacts([string]$Manifest) {
 $before=[WinsmuxDesktopNativeActor]::NativeFile($Manifest)
 $artifacts=[Collections.Generic.List[object]]::new();$finished=0
 foreach($line in [IO.File]::ReadLines($Manifest,[Text.UTF8Encoding]::new($false,$true))){if([string]::IsNullOrWhiteSpace($line)){continue};$row=$line|ConvertFrom-Json -AsHashtable;if($row.reason -ceq 'compiler-artifact' -and $null -ne $row.executable){$artifacts.Add($row)}elseif($row.reason -ceq 'build-finished'){Assert-Fixed ($row.success -is [bool] -and $row.success -eq $true) 'cargo_failed';$finished++}}
 $after=[WinsmuxDesktopNativeActor]::NativeFile($Manifest)
 Assert-Fixed ($finished -eq 1 -and $after['identity'] -ceq $before['identity'] -and $after['sha256'] -ceq $before['sha256']) 'cargo_terminal'
 $testRows=@($artifacts|Where-Object{$_.target.name -ceq 'workspace_host_e2e' -and $_.target.kind -is [Collections.IList] -and $_.target.kind.Count -eq 1 -and 'test' -cin $_.target.kind -and $_.profile.test -is [bool] -and $_.profile.test -eq $true -and $_.executable -is [string]})
 $cliRows=@($artifacts|Where-Object{$_.target.name -ceq 'winsmux' -and $_.target.kind -is [Collections.IList] -and $_.target.kind.Count -eq 1 -and 'bin' -cin $_.target.kind -and $_.profile.test -is [bool] -and $_.profile.test -eq $false -and $_.executable -is [string]})
 Assert-Fixed ($testRows.Count -eq 1 -and $cliRows.Count -eq 1) 'cargo_artifact_identity'
 foreach($entry in @($testRows[0],$cliRows[0])){Assert-Fixed ([string]::Equals([IO.Path]::GetFullPath($entry.executable),$entry.executable,[StringComparison]::OrdinalIgnoreCase)) 'cargo_path_spelling'}
 return @{test=[IO.Path]::GetFullPath([string]$testRows[0].executable);cli=[IO.Path]::GetFullPath([string]$cliRows[0].executable)}
}
function Assert-HeadlessBoundInputs($Binding,[string]$ExpectedScript) {
 Assert-Fixed ($Binding.compiler_inputs -is [Collections.IDictionary]) 'compiler_binding'
 Assert-Fixed ([string]::Equals($Binding.test_executable,$Binding.compiler_inputs.test,[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($Binding.cli_executable,$Binding.compiler_inputs.cli,[StringComparison]::OrdinalIgnoreCase) -and $Binding.test_sha256 -ceq $Binding.compiler_inputs.test_sha -and $Binding.cli_sha256 -ceq $Binding.compiler_inputs.cli_sha -and $Binding.script_sha256 -ceq $Binding.compiler_inputs.script_sha -and [string]::Equals($ExpectedScript,$Binding.compiler_inputs.script,[StringComparison]::OrdinalIgnoreCase)) 'actual_execution_path'
 [WinsmuxHeadlessOwned.WinsmuxHeadlessCompilerInputs]::Verify($Binding.compiler_inputs)
}
function Assert-CapabilityKeys($Value,[string[]]$Keys) {
 Assert-Fixed ($Value -is [Collections.IDictionary] -and ((@($Value.Keys|Sort-Object -CaseSensitive)-join [char]10) -ceq (@($Keys|Sort-Object -CaseSensitive)-join [char]10))) 'snapshot_keys'
}
function Assert-CapabilityObserved($Field,[string]$Kind,[string[]]$Enums=@()) {
 Assert-CapabilityKeys $Field @('observed','value')
 Assert-Fixed ($Field.observed -is [bool]) 'snapshot_observed'
 if(-not $Field.observed){Assert-Fixed ($null -eq $Field.value) 'snapshot_missing';return}
 if($Kind -ceq 'bool'){Assert-Fixed ($Field.value -is [bool]) 'snapshot_bool'}else{Assert-Fixed ($Field.value -is [string] -and $Field.value -cin $Enums) 'snapshot_enum'}
}
function Assert-CapabilityTokenSnapshot($Value) {
 Assert-CapabilityKeys $Value @('schema','thread_absent_before','thread_absent_after','primary','generation','effective','generation_to_primary','effective_to_generation','operations','operation_failure','revert_failure')
 Assert-Fixed ($Value.schema -is [string] -and $Value.schema -ceq 'winsmux-server-capability-token-observation/v1') 'snapshot_schema'
 foreach($name in @('thread_absent_before','thread_absent_after')){Assert-CapabilityObserved $Value[$name] 'bool'}
 foreach($name in @('primary','generation','effective')){
  $f=$Value[$name];Assert-CapabilityKeys $f @('token_type','impersonation_level','has_restrictions','restricting_sids_empty','se_impersonate_present','se_impersonate_enabled')
  Assert-CapabilityObserved $f.token_type 'enum' @('primary','impersonation')
  Assert-CapabilityObserved $f.impersonation_level 'enum' @('not_applicable','anonymous','identification','impersonation','delegation')
  foreach($key in @('has_restrictions','restricting_sids_empty','se_impersonate_present','se_impersonate_enabled')){Assert-CapabilityObserved $f[$key] 'bool'}
  Assert-Fixed ($f.token_type.observed -eq $f.impersonation_level.observed) 'snapshot_level_presence'
  if($f.token_type.observed){Assert-Fixed (($f.token_type.value -ceq 'primary') -eq ($f.impersonation_level.value -ceq 'not_applicable')) 'snapshot_level_type'}
  Assert-Fixed ($f.se_impersonate_present.observed -eq $f.se_impersonate_enabled.observed) 'snapshot_privilege_presence'
  if($f.se_impersonate_present.observed -and -not $f.se_impersonate_present.value){Assert-Fixed (-not $f.se_impersonate_enabled.value) 'snapshot_privilege_state'}
 }
 foreach($name in @('generation_to_primary','effective_to_generation')){
  Assert-CapabilityKeys $Value[$name] @('same_user','same_logon','same_authentication_id')
  foreach($key in @('same_user','same_logon','same_authentication_id')){Assert-CapabilityObserved $Value[$name][$key] 'bool'}
 }
 Assert-CapabilityKeys $Value.operations @('identity','capability','impersonate','pipe','revert','result')
 foreach($key in @('identity','capability','impersonate','pipe','revert','result')){Assert-Fixed ($Value.operations[$key] -is [string] -and $Value.operations[$key] -cin @('not_attempted','succeeded','failed')) 'snapshot_operation'}
 $failure=$Value.operation_failure;Assert-CapabilityKeys $failure @('observed','value');Assert-Fixed ($failure.observed -is [bool]) 'snapshot_failure_presence'
 if($failure.observed){
  Assert-CapabilityKeys $failure.value @('api','class')
  Assert-Fixed ($failure.value.api -is [string] -and $failure.value.api -cin @('impersonate','sid_to_string','sddl_to_descriptor','create_pipe','descriptor_validation')) 'snapshot_api'
  Assert-Fixed ($failure.value.class -is [string] -and $failure.value.class -cin @('access_denied','privilege_not_held','bad_impersonation_level','invalid_owner','invalid_security_descriptor','unobserved')) 'snapshot_class'
 }else{Assert-Fixed ($null -eq $failure.value) 'snapshot_failure_missing'}
 Assert-CapabilityObserved $Value.revert_failure 'enum' @('access_denied','privilege_not_held','bad_impersonation_level','invalid_owner','invalid_security_descriptor','unobserved')
 $op=$Value.operations
 if(-not $Value.thread_absent_before.observed -or -not $Value.thread_absent_before.value){
  foreach($key in @('identity','capability','impersonate','pipe','revert','result')){Assert-Fixed ($op[$key] -ceq 'not_attempted') 'snapshot_precondition'}
 }
 if($op.capability -cne 'not_attempted'){Assert-Fixed ($op.identity -ceq 'succeeded') 'snapshot_identity_order'}
 if($op.impersonate -cne 'not_attempted'){Assert-Fixed ($op.capability -ceq 'succeeded') 'snapshot_generation_order'}
 if($op.pipe -cne 'not_attempted'){Assert-Fixed ($op.impersonate -ceq 'succeeded') 'snapshot_pipe_order'}
 Assert-Fixed (($op.impersonate -ceq 'succeeded') -eq ($op.revert -cne 'not_attempted')) 'snapshot_revert_order'
 Assert-Fixed (($op.revert -ceq 'failed') -eq $Value.revert_failure.observed) 'snapshot_revert_failure'
 if($op.result -ceq 'succeeded'){Assert-Fixed ($op.pipe -ceq 'succeeded' -and $op.revert -ceq 'succeeded' -and -not $failure.observed) 'snapshot_result_success'}
 if($op.result -ceq 'failed'){Assert-Fixed ($failure.observed -or $Value.revert_failure.observed) 'snapshot_result_failure'}
 if($failure.observed){
  $api=$failure.value.api
  if($api -ceq 'impersonate'){Assert-Fixed ($op.impersonate -ceq 'failed' -and $op.pipe -ceq 'not_attempted') 'snapshot_impersonate_failure'}
  elseif($api -ceq 'create_pipe'){Assert-Fixed ($op.pipe -ceq 'failed') 'snapshot_create_failure'}
  else{Assert-Fixed ($op.impersonate -ceq 'succeeded' -and $op.pipe -ceq 'not_attempted') 'snapshot_descriptor_failure'}
  Assert-Fixed ($op.result -ceq 'failed') 'snapshot_failure_result'
 }

 foreach($pair in @(@('generation','capability'),@('effective','impersonate'))){
  if($op[$pair[1]] -cne 'succeeded'){
   foreach($f in $Value[$pair[0]].Values){Assert-Fixed (-not $f.observed) 'snapshot_token_not_reached'}
   $relation=if($pair[0] -ceq 'generation'){'generation_to_primary'}else{'effective_to_generation'}
   foreach($f in $Value[$relation].Values){Assert-Fixed (-not $f.observed) 'snapshot_relation_not_reached'}
  }
 }
 if($op.revert -ceq 'not_attempted'){Assert-Fixed (-not $Value.thread_absent_after.observed) 'snapshot_after_not_reached'}
 if($Value.thread_absent_before.observed -and $Value.thread_absent_before.value){Assert-Fixed ($op.identity -cne 'not_attempted') 'snapshot_identity_reached'}
 if($op.identity -ceq 'succeeded'){Assert-Fixed ($op.capability -cne 'not_attempted') 'snapshot_capability_reached'}
 if($op.capability -ceq 'succeeded'){Assert-Fixed ($op.impersonate -cne 'not_attempted') 'snapshot_impersonate_reached'}
 if($op.impersonate -cne 'not_attempted'){Assert-Fixed ($op.result -cne 'not_attempted') 'snapshot_result_reached'}
 if($op.result -ceq 'not_attempted'){Assert-Fixed (-not $failure.observed -and $op.impersonate -ceq 'not_attempted') 'snapshot_result_not_reached'}
 if($op.pipe -ceq 'failed'){Assert-Fixed ($failure.observed -and $failure.value.api -ceq 'create_pipe') 'snapshot_pipe_failure'}
 if($op.pipe -ceq 'succeeded' -and $op.result -ceq 'failed'){Assert-Fixed ($Value.revert_failure.observed -and -not $failure.observed) 'snapshot_successful_pipe_failure'}
}
function ConvertFrom-CapabilityTokenPayload([string]$Payload) {
 $doc=[System.Text.Json.JsonDocument]::Parse($Payload,[System.Text.Json.JsonDocumentOptions]::new())
 try{
  function Assert-UniqueSnapshotObject($Node){
   if($Node.ValueKind -eq [System.Text.Json.JsonValueKind]::Object){
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($p in $Node.EnumerateObject()){Assert-Fixed ($seen.Add($p.Name)) 'snapshot_duplicate';Assert-UniqueSnapshotObject $p.Value}
   }elseif($Node.ValueKind -eq [System.Text.Json.JsonValueKind]::Array){throw 'snapshot_array'}
  }
  Assert-UniqueSnapshotObject $doc.RootElement
  $value=$Payload|ConvertFrom-Json -AsHashtable -Depth 16
  Assert-CapabilityTokenSnapshot $value
  return $value
 }finally{$doc.Dispose()}
}
function Read-CapabilityTokenSnapshot([byte[]]$Stdout,[byte[]]$Stderr,[bool]$Truncated) {
 Assert-Fixed (-not $Truncated) 'snapshot_truncated'
 $decoder=[Text.UTF8Encoding]::new($false,$true);$output=$decoder.GetString($Stdout);$errors=$decoder.GetString($Stderr)
 $prefix='WINSMUX_CAPABILITY_TOKEN_SNAPSHOT '
 Assert-Fixed (-not $errors.Contains('WINSMUX_CAPABILITY_TOKEN_SNAPSHOT')) 'snapshot_stderr'
 $lines=@($output -split '\r?\n'|Where-Object{$_.Contains('WINSMUX_CAPABILITY_TOKEN_SNAPSHOT')})
 Assert-Fixed ($lines.Count -eq 1) 'snapshot_count'
 $line=$lines[0];$at=$line.IndexOf($prefix,[StringComparison]::Ordinal)
 Assert-Fixed ($at -ge 0 -and ($at -eq 0 -or $line.Substring(0,$at) -ceq 'test server_capability_token_creation_snapshot ... ')) 'snapshot_prefix'
 return ConvertFrom-CapabilityTokenPayload $line.Substring($at+$prefix.Length)
}
function Test-CapabilityTokenSnapshotComplete($Value) {
 foreach($f in @($Value.thread_absent_before,$Value.thread_absent_after)){if(-not $f.observed){return $false}}
 foreach($name in @('primary','generation','effective','generation_to_primary','effective_to_generation')){foreach($f in $Value[$name].Values){if(-not $f.observed){return $false}}}
 return $true
}

function New-CapabilityTokenCapture([string]$Source) {
 return [ordered]@{schema='winsmux-server-capability-token-capture/v1';source_commit=$Source;actor_admitted=$false;same_sid=$false;same_session=$false;restricted_medium=$false;diagnostic_received=$false;query_complete=$false;observation=$null;capture=[ordered]@{process_exit='unobserved';terminal=$false;job_zero=$false;forced=$false;capture_complete=$false};raw=$null;root_terminal=$false;root_job_zero=$false;forced=$false;failure=$null;product_success_proven=$false;nsis_success_proven=$false;normal_gui_success_proven=$false}
}
function Assert-CapabilityTokenCapture($Value,[string]$Source) {
 Assert-CapabilityKeys $Value @('schema','source_commit','actor_admitted','same_sid','same_session','restricted_medium','diagnostic_received','query_complete','observation','capture','raw','root_terminal','root_job_zero','forced','failure','product_success_proven','nsis_success_proven','normal_gui_success_proven')
 Assert-Fixed ($Value.schema -is [string] -and $Value.schema -ceq 'winsmux-server-capability-token-capture/v1' -and $Value.source_commit -is [string] -and $Value.source_commit -ceq $Source) 'capture_schema'
 foreach($key in @('actor_admitted','same_sid','same_session','restricted_medium','diagnostic_received','query_complete','root_terminal','root_job_zero','forced','product_success_proven','nsis_success_proven','normal_gui_success_proven')){Assert-Fixed ($Value[$key] -is [bool]) 'capture_bool'}
 Assert-Fixed (-not $Value.product_success_proven -and -not $Value.nsis_success_proven -and -not $Value.normal_gui_success_proven) 'capture_scope'
 Assert-Fixed ($Value.actor_admitted -eq ($Value.same_sid -and $Value.same_session -and $Value.restricted_medium)) 'capture_actor'
 Assert-Fixed ($null -eq $Value.failure -or ($Value.failure -is [string] -and $Value.failure -cin @('source_admission','build_binding','medium_bootstrap','token_child_result','token_observation','root_convergence','result_preservation'))) 'capture_failure'
 Assert-CapabilityKeys $Value.capture @('process_exit','terminal','job_zero','forced','capture_complete')
 Assert-Fixed ($Value.capture.process_exit -is [string] -and $Value.capture.process_exit -cin @('unobserved','zero','test_failure','owned_stop','other')) 'capture_exit'
 foreach($key in @('terminal','job_zero','forced','capture_complete')){Assert-Fixed ($Value.capture[$key] -is [bool]) 'capture_ownership'}
 if($null -ne $Value.raw){
  Assert-CapabilityKeys $Value.raw @('stdout_total_bytes','stdout_retained_bytes','stdout_retained_sha256','stderr_total_bytes','stderr_retained_bytes','stderr_retained_sha256')
  foreach($stream in @('stdout','stderr')){
   $total=$Value.raw[($stream+'_total_bytes')];$retained=$Value.raw[($stream+'_retained_bytes')];$sha=$Value.raw[($stream+'_retained_sha256')]
   Assert-Fixed (($total -is [int] -or $total -is [long]) -and ($retained -is [int] -or $retained -is [long]) -and $total -ge 0 -and $retained -ge 0 -and $retained -le $total -and $retained -le 16384 -and $sha -is [string] -and $sha -cmatch '^[a-f0-9]{64}$') 'capture_raw_shape'
  }
 }
 if($Value.diagnostic_received){
  Assert-CapabilityTokenSnapshot $Value.observation
  Assert-Fixed ($null -ne $Value.raw -and $Value.query_complete -eq (Test-CapabilityTokenSnapshotComplete $Value.observation)) 'capture_observation'
 }else{Assert-Fixed ($null -eq $Value.observation -and -not $Value.query_complete) 'capture_missing'}
}
function Invoke-CapabilityTokenCapture($Binding,[string]$ExpectedScript,$Envelope) {
 Assert-HeadlessBoundInputs $Binding $ExpectedScript
 $testImage=[string]$Binding.test_executable;$cliImage=[string]$Binding.cli_executable
 Assert-Fixed ([WinsmuxDesktopNativeActor]::NativeFile($testImage)['sha256'] -ceq $Binding.test_sha256 -and [WinsmuxDesktopNativeActor]::NativeFile($cliImage)['sha256'] -ceq $Binding.cli_sha256) 'test_input_changed'
 $owned=$null;$terminal=$false
 try{
  $owned=[Winsmux.DesktopNative.DesktopProcessOwner]::Start($testImage,[string[]]@('--exact','server_capability_token_creation_snapshot','--ignored','--test-threads=1','--nocapture'),@{},$false,16384,180000)
  $terminal=$owned.WaitTerminal(180000,500)
  if(-not $terminal){$owned.ForceFailureCleanup(180000,500);$terminal=$owned.HasExited -and $owned.ActiveMembers -eq 0 -and $owned.CaptureCompleted}
  $out=$owned.StdoutTask.GetAwaiter().GetResult();$err=$owned.StderrTask.GetAwaiter().GetResult()
  $Envelope.capture=[ordered]@{process_exit=$(if($owned.ExitCode -eq 0){'zero'}elseif($owned.ExitCode -eq 101){'test_failure'}elseif($owned.ExitCode -eq 124){'owned_stop'}else{'other'});terminal=$terminal;job_zero=($owned.ActiveMembers -eq 0);forced=$owned.Forced;capture_complete=($owned.CaptureCompleted -and -not $out.Truncated -and -not $err.Truncated)}
  $Envelope.raw=[ordered]@{stdout_total_bytes=$out.TotalBytes;stdout_retained_bytes=$out.RetainedBytes.LongLength;stdout_retained_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($out.RetainedBytes)).ToLowerInvariant();stderr_total_bytes=$err.TotalBytes;stderr_retained_bytes=$err.RetainedBytes.LongLength;stderr_retained_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($err.RetainedBytes)).ToLowerInvariant()}
  $Envelope.observation=Read-CapabilityTokenSnapshot $out.RetainedBytes $err.RetainedBytes ($out.Truncated -or $err.Truncated)
  $Envelope.diagnostic_received=$true;$Envelope.query_complete=Test-CapabilityTokenSnapshotComplete $Envelope.observation
  # Test raw bytes are memory-only, including failures and arbitrary panic text.
  $out=$null;$err=$null
 }finally{
  if($null -ne $owned){if(-not $terminal){$owned.ForceFailureCleanup(180000,500)};if($owned.HasExited -and $owned.ActiveMembers -eq 0 -and $owned.CaptureCompleted){$owned.Dispose()}}
 }
 Assert-HeadlessBoundInputs $Binding $ExpectedScript
 Assert-Fixed ([WinsmuxDesktopNativeActor]::NativeFile($testImage)['sha256'] -ceq $Binding.test_sha256 -and [WinsmuxDesktopNativeActor]::NativeFile($cliImage)['sha256'] -ceq $Binding.cli_sha256) 'test_output_changed_inputs'
}

function Initialize-HeadlessNativeTypes([string]$repoRoot) {
 $sourcePath=Join-Path $repoRoot 'scripts/test-public-release.ps1'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
 Assert-Fixed (@($errors).Count -eq 0) 'actor_source_parse'
 $initializers=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Initialize-DesktopNativeLifecycleActor'},$false))
 Assert-Fixed ($initializers.Count -eq 1) 'actor_initializer'
 function Read-FixedLiteral($Scope,[string]$Name){
  $rows=@($Scope.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq $Name -and $node.Right -is [Management.Automation.Language.CommandExpressionAst] -and $node.Right.Expression -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Right.Expression.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString},$true))
  Assert-Fixed ($rows.Count -eq 1) 'actor_literal';return [string]$rows[0].Right.Expression.Value
 }
 $actor=Read-FixedLiteral $ast 'actorCSharp';$native=Read-FixedLiteral $initializers[0] 'native'
 $actor=$actor.Replace('public static class WinsmuxDesktopActorProbe {','public static class WinsmuxDesktopNativeActor {').Replace('sealed class TokenFacts {','internal sealed class TokenFacts {').Replace('struct PI {','internal struct PI {')
 $closing=$actor.LastIndexOf('}');Assert-Fixed ($closing -gt 0) 'actor_assembly'
 Add-Type -TypeDefinition ($actor.Substring(0,$closing)+$native+$actor.Substring($closing)+[char]10+(Get-HeadlessCompilerNativeSource)) -ErrorAction Stop 2>$null
 return $ast
}
function ConvertTo-HeadlessFixedProjection {
 param([byte[]]$Stdout,[byte[]]$Stderr,[bool]$Truncated,[string]$Test,[int]$ExitCode,[bool]$Terminal,[bool]$JobZero,[bool]$Forced)
 $result=[ordered]@{test=$Test;outcome='unobserved';process_exit=$(if($ExitCode -eq 0){'zero'}elseif($ExitCode -eq 101){'test_failure'}elseif($ExitCode -eq 124){'owned_stop'}else{'other'});terminal=$Terminal;job_zero=$JobZero;forced=$Forced;capture_complete=(-not $Truncated);child_stages=@();launcher_stages=@();host_classes=@();unknown_marker=$false;conpty_or_debug_only=$false}
 if($Truncated -or -not $Terminal -or -not $JobZero){return $result}
 try{$text=[Text.UTF8Encoding]::new($false,$true).GetString($Stdout)+[char]10+[Text.UTF8Encoding]::new($false,$true).GetString($Stderr)}catch{return $result}
 $text=[regex]::Replace($text,[string][char]27+'\[[0-?]*[ -/]*[@-~]','')
 $child=@('handle','identity','mutex','inheritance_probe','capability','server_key','authorization','cancel_event','supervisor','discovery','public_pipe','public_pipe_impersonate_access_denied','public_pipe_impersonate_privilege_not_held','public_pipe_impersonate_bad_impersonation_level','public_pipe_impersonate_invalid_owner','public_pipe_impersonate_invalid_security_descriptor','public_pipe_impersonate_unobserved','public_pipe_sid_to_string_access_denied','public_pipe_sid_to_string_privilege_not_held','public_pipe_sid_to_string_bad_impersonation_level','public_pipe_sid_to_string_invalid_owner','public_pipe_sid_to_string_invalid_security_descriptor','public_pipe_sid_to_string_unobserved','public_pipe_sddl_to_descriptor_access_denied','public_pipe_sddl_to_descriptor_privilege_not_held','public_pipe_sddl_to_descriptor_bad_impersonation_level','public_pipe_sddl_to_descriptor_invalid_owner','public_pipe_sddl_to_descriptor_invalid_security_descriptor','public_pipe_sddl_to_descriptor_unobserved','public_pipe_create_pipe_access_denied','public_pipe_create_pipe_privilege_not_held','public_pipe_create_pipe_bad_impersonation_level','public_pipe_create_pipe_invalid_owner','public_pipe_create_pipe_invalid_security_descriptor','public_pipe_create_pipe_unobserved','public_pipe_revert_access_denied','public_pipe_revert_privilege_not_held','public_pipe_revert_bad_impersonation_level','public_pipe_revert_invalid_owner','public_pipe_revert_invalid_security_descriptor','public_pipe_revert_unobserved','public_pipe_descriptor_validation_unobserved','accept_thread','discovery_serialization')
 $launcher=@('terminal','identity','inheritance_probe','console','channel','child_spawn','startup_frame','probe_ready','discovery_frame','discovery_parse','discovery_validation','discovery_serialization','output_started')
 foreach($pair in @([pscustomobject]@{kind='CHILD';allowed=$child;field='child_stages'},[pscustomobject]@{kind='OWNER';allowed=$launcher;field='launcher_stages'})){
  $seen=[Collections.Generic.List[string]]::new()
  $pattern='(?<![A-Za-z0-9_])TASK876_'+$pair.kind+'_STARTUP stage=([^\s\x00-\x1f]+)'
  foreach($m in [regex]::Matches($text,$pattern)){
   $value=$m.Groups[1].Value
   if($value -cin $pair.allowed){if(-not $seen.Contains($value)){$seen.Add($value)}}else{$result.unknown_marker=$true}
  }
  $result[$pair.field]=$seen.ToArray()
 }
 $classes=[Collections.Generic.List[string]]::new()
 $allowed=@('usage','interactive_required','startup_failed','transport_failed','protocol_failed','cancelled')
 foreach($m in [regex]::Matches($text,'(?<![A-Za-z0-9_])(?:class=|winsmux workspace: )([^\s\x00-\x1f]+)')){
  $value=$m.Groups[1].Value
  if($value -cin $allowed){if(-not $classes.Contains($value)){$classes.Add($value)}}else{$result.unknown_marker=$true}
 }
 $result.host_classes=$classes.ToArray()
 $result.conpty_or_debug_only=(@($result.launcher_stages|Where-Object{$_ -cin @('terminal','console','inheritance_probe','probe_ready','output_started')}).Count -gt 0 -or 'inheritance_probe' -cin $result.child_stages)
 $name=[regex]::Escape($Test)
 $passed=[regex]::IsMatch($text,'(?m)^test '+$name+' \.\.\. ok\r?$') -and [regex]::IsMatch($text,'(?m)^test result: ok\. 1 passed; 0 failed;')
 $failed=[regex]::IsMatch($text,'(?m)^test '+$name+' \.\.\. FAILED\r?$') -and [regex]::IsMatch($text,'(?m)^test result: FAILED\. 0 passed; 1 failed;')
 if(-not $result.unknown_marker -and -not $Forced){if($ExitCode -eq 0 -and $passed){$result.outcome='passed'}elseif($ExitCode -ne 0 -and $failed){$result.outcome='failed'}}
 return $result
}
function Assert-HeadlessProjectionShape($Row,[string]$ExpectedTest) {
 $keys=@('test','outcome','process_exit','terminal','job_zero','forced','capture_complete','child_stages','launcher_stages','host_classes','unknown_marker','conpty_or_debug_only')
 Assert-Fixed ($Row -is [Collections.IDictionary] -and (@($Row.Keys|Sort-Object -CaseSensitive)-join [char]10) -ceq (@($keys|Sort-Object -CaseSensitive)-join [char]10)) 'projection_shape'
 Assert-Fixed ($Row.test -is [string] -and $Row.outcome -is [string] -and $Row.process_exit -is [string] -and $Row.test -ceq $ExpectedTest -and $Row.outcome -cin @('passed','failed','unobserved') -and $Row.process_exit -cin @('zero','test_failure','owned_stop','other')) 'projection_values'
 foreach($key in @('terminal','job_zero','forced','capture_complete','unknown_marker','conpty_or_debug_only')){Assert-Fixed ($Row[$key] -is [bool]) 'projection_boolean'}
 $sets=@{child_stages=@('handle','identity','mutex','inheritance_probe','capability','server_key','authorization','cancel_event','supervisor','discovery','public_pipe','public_pipe_impersonate_access_denied','public_pipe_impersonate_privilege_not_held','public_pipe_impersonate_bad_impersonation_level','public_pipe_impersonate_invalid_owner','public_pipe_impersonate_invalid_security_descriptor','public_pipe_impersonate_unobserved','public_pipe_sid_to_string_access_denied','public_pipe_sid_to_string_privilege_not_held','public_pipe_sid_to_string_bad_impersonation_level','public_pipe_sid_to_string_invalid_owner','public_pipe_sid_to_string_invalid_security_descriptor','public_pipe_sid_to_string_unobserved','public_pipe_sddl_to_descriptor_access_denied','public_pipe_sddl_to_descriptor_privilege_not_held','public_pipe_sddl_to_descriptor_bad_impersonation_level','public_pipe_sddl_to_descriptor_invalid_owner','public_pipe_sddl_to_descriptor_invalid_security_descriptor','public_pipe_sddl_to_descriptor_unobserved','public_pipe_create_pipe_access_denied','public_pipe_create_pipe_privilege_not_held','public_pipe_create_pipe_bad_impersonation_level','public_pipe_create_pipe_invalid_owner','public_pipe_create_pipe_invalid_security_descriptor','public_pipe_create_pipe_unobserved','public_pipe_revert_access_denied','public_pipe_revert_privilege_not_held','public_pipe_revert_bad_impersonation_level','public_pipe_revert_invalid_owner','public_pipe_revert_invalid_security_descriptor','public_pipe_revert_unobserved','public_pipe_descriptor_validation_unobserved','accept_thread','discovery_serialization');launcher_stages=@('terminal','identity','inheritance_probe','console','channel','child_spawn','startup_frame','probe_ready','discovery_frame','discovery_parse','discovery_validation','discovery_serialization','output_started');host_classes=@('usage','interactive_required','startup_failed','transport_failed','protocol_failed','cancelled')}
 foreach($key in $sets.Keys){Assert-Fixed ($Row[$key] -is [Collections.IList]) 'projection_array';foreach($value in $Row[$key]){Assert-Fixed ($value -is [string] -and $value -cin $sets[$key]) 'projection_enum'}}
 if($Row.outcome -cne 'unobserved'){Assert-Fixed ($Row.terminal -and $Row.job_zero -and -not $Row.forced -and $Row.capture_complete -and -not $Row.unknown_marker) 'projection_acceptance'}
 if($Row.outcome -ceq 'passed'){Assert-Fixed ($Row.process_exit -ceq 'zero') 'projection_pass_exit'}
 if($Row.outcome -ceq 'failed'){Assert-Fixed ($Row.process_exit -cne 'zero') 'projection_failure_exit'}
}
function Test-HeadlessProjection {
 $test='real_host_without_provider_path_keeps_launch_unadvertised'
 $good='test '+$test+' ... ok'+[char]10+'test result: ok. 1 passed; 0 failed; 0 ignored;'
 $convert={param($text,$code=0,$truncated=$false,$terminal=$true,$job=$true,$forced=$false) ConvertTo-HeadlessFixedProjection -Stdout ([Text.Encoding]::UTF8.GetBytes($text)) -Stderr @() -Truncated $truncated -Test $test -ExitCode $code -Terminal $terminal -JobZero $job -Forced $forced}
 Assert-Fixed ((& $convert $good).outcome -ceq 'passed') 'projection_positive'
 Assert-Fixed ((& $convert 'test result: ok. 0 passed; 0 failed;').outcome -ceq 'unobserved') 'projection_zero_is_not_pass'
 Assert-Fixed ((& $convert $good 0 $true).outcome -ceq 'unobserved') 'projection_truncation'
 Assert-Fixed ((& $convert $good 0 $false $false).outcome -ceq 'unobserved') 'projection_nonterminal'
 Assert-Fixed ((& $convert $good 0 $false $true $false).outcome -ceq 'unobserved') 'projection_live_job'
 Assert-Fixed ((& $convert $good 0 $false $true $true $true).outcome -ceq 'unobserved') 'projection_forced'
 $ansi=[string][char]27+'[?9001l'
 $fixed='TASK876_CHILD_STARTUP stage='+$ansi+'capability'+[char]10+'TASK876_OWNER_STARTUP stage=startup_frame class=transport_failed'
 $value=& $convert ($fixed+[char]10+$good)
 Assert-Fixed ($value.child_stages.Count -eq 1 -and $value.child_stages[0] -ceq 'capability' -and $value.host_classes[0] -ceq 'transport_failed') 'projection_fixed_stage'
 $bad=& $convert ('TASK876_CHILD_STARTUP stage=capability-extra'+[char]10+$good)
 Assert-Fixed ($bad.outcome -ceq 'unobserved' -and $bad.child_stages.Count -eq 0 -and $bad.unknown_marker) 'projection_stage_suffix'
 $bad=& $convert ('TASK876_OWNER_STARTUP stage=console class=SECRET_UNKNOWN'+[char]10+$good)
 Assert-Fixed ($bad.outcome -ceq 'unobserved' -and $bad.host_classes.Count -eq 0 -and $bad.conpty_or_debug_only) 'projection_unknown_class'
 $failure='TASK876_CHILD_STARTUP stage=authorization'+[char]10+'test '+$test+' ... FAILED'+[char]10+'test result: FAILED. 0 passed; 1 failed;'
 $value=& $convert $failure 101
 Assert-Fixed ($value.outcome -ceq 'failed' -and $value.child_stages[0] -ceq 'authorization') 'projection_failure_retained'
 $invalid=ConvertTo-HeadlessFixedProjection -Stdout ([byte[]]@(255)) -Stderr @() -Truncated $false -Test $test -ExitCode 0 -Terminal $true -JobZero $true -Forced $false
 Assert-Fixed ($invalid.outcome -ceq 'unobserved') 'projection_utf8'
 $serialized=$value|ConvertTo-Json -Depth 8 -Compress
 Assert-Fixed (-not $serialized.Contains('SECRET_UNKNOWN')) 'projection_no_raw_export'
 Assert-HeadlessProjectionShape $value $test
 $stray=ConvertTo-HeadlessFixedProjection -Stdout ([Text.Encoding]::UTF8.GetBytes($good)) -Stderr @() -Truncated $false -Test $test -ExitCode 0 -Terminal $true -JobZero $true -Forced $false
 $stray['raw']='SECRET_UNKNOWN';$rejected=$false;try{Assert-HeadlessProjectionShape $stray $test}catch{$rejected=$true};Assert-Fixed $rejected 'projection_stray_field'
 [void]$stray.Remove('raw');$stray['terminal']=$false;$rejected=$false;try{Assert-HeadlessProjectionShape $stray $test}catch{$rejected=$true};Assert-Fixed $rejected 'projection_false_pass'
  # The new marker vocabulary stays inside the existing shape. API failures
  # remain failures, and arbitrary/unknown spellings retain missing observation.
  $pipeStages=@('public_pipe_impersonate_access_denied','public_pipe_impersonate_privilege_not_held','public_pipe_impersonate_bad_impersonation_level','public_pipe_impersonate_invalid_owner','public_pipe_impersonate_invalid_security_descriptor','public_pipe_impersonate_unobserved','public_pipe_sid_to_string_access_denied','public_pipe_sid_to_string_privilege_not_held','public_pipe_sid_to_string_bad_impersonation_level','public_pipe_sid_to_string_invalid_owner','public_pipe_sid_to_string_invalid_security_descriptor','public_pipe_sid_to_string_unobserved','public_pipe_sddl_to_descriptor_access_denied','public_pipe_sddl_to_descriptor_privilege_not_held','public_pipe_sddl_to_descriptor_bad_impersonation_level','public_pipe_sddl_to_descriptor_invalid_owner','public_pipe_sddl_to_descriptor_invalid_security_descriptor','public_pipe_sddl_to_descriptor_unobserved','public_pipe_create_pipe_access_denied','public_pipe_create_pipe_privilege_not_held','public_pipe_create_pipe_bad_impersonation_level','public_pipe_create_pipe_invalid_owner','public_pipe_create_pipe_invalid_security_descriptor','public_pipe_create_pipe_unobserved','public_pipe_revert_access_denied','public_pipe_revert_privilege_not_held','public_pipe_revert_bad_impersonation_level','public_pipe_revert_invalid_owner','public_pipe_revert_invalid_security_descriptor','public_pipe_revert_unobserved','public_pipe_descriptor_validation_unobserved')
  $pipeFailure='test '+$test+' ... FAILED'+[char]10+'test result: FAILED. 0 passed; 1 failed;'
  foreach($pipeStage in $pipeStages){
   $pipeValue=& $convert ('TASK876_CHILD_STARTUP stage=public_pipe'+[char]10+'TASK876_CHILD_STARTUP stage='+$pipeStage+[char]10+$pipeFailure) 101
   Assert-Fixed ($pipeValue.outcome -ceq 'failed' -and $pipeValue.process_exit -ceq 'test_failure' -and -not $pipeValue.unknown_marker -and $pipeValue.child_stages.Count -eq 2 -and $pipeValue.child_stages[0] -ceq 'public_pipe' -and $pipeValue.child_stages[1] -ceq $pipeStage) 'projection_pipe_enum'
   Assert-HeadlessProjectionShape $pipeValue $test
  }
  $pipeBoth=& $convert ('TASK876_CHILD_STARTUP stage=public_pipe'+[char]10+'TASK876_CHILD_STARTUP stage=public_pipe_create_pipe_access_denied'+[char]10+'TASK876_CHILD_STARTUP stage=public_pipe_revert_privilege_not_held'+[char]10+$pipeFailure) 101
  Assert-Fixed ($pipeBoth.outcome -ceq 'failed' -and $pipeBoth.child_stages.Count -eq 3) 'projection_pipe_both'
  foreach($pipeBad in @('public_pipe_impersonate_other','public_pipe_revert_access_denied-extra','public_pipe_SECRET_UNKNOWN',('public_pipe_create_pipe_access_denied'+[char]0+'SECRET_UNKNOWN'))){
   $pipeValue=& $convert ('TASK876_CHILD_STARTUP stage='+$pipeBad+[char]10+$pipeFailure) 101
   # A NUL terminates a marker exactly as the unchanged parser specifies. The
   # arbitrary suffix still cannot reach any fixed projected field.
   Assert-Fixed (-not (($pipeValue|ConvertTo-Json -Depth 8 -Compress).Contains('SECRET_UNKNOWN'))) 'projection_pipe_no_raw'
   if(-not $pipeBad.Contains([string][char]0)){Assert-Fixed ($pipeValue.outcome -ceq 'unobserved' -and $pipeValue.unknown_marker -and $pipeValue.process_exit -ceq 'test_failure') 'projection_pipe_unknown'}
  }
 return [ordered]@{schema='winsmux-headless-projection-finite/v1';outcome='passed';cases=50}
}
if($ProjectionSelfTest){try{Test-HeadlessProjection|ConvertTo-Json -Compress;exit 0}catch{[Console]::Out.WriteLine('{"schema":"winsmux-headless-projection-finite/v1","outcome":"failed"}');exit 1}}
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$phase='source_admission';$outer=$null;$outerTerminal=$false;$evidenceRoot=$null;$bindingObservationPoint='unobserved'
$capabilityMode=$HeadlessParent -and $ObserveCapabilityToken;$capabilityResult=$null;$capabilityOuterExitZero=$false
if($capabilityMode){$tests=@('server_capability_token_creation_snapshot')}
$result=[ordered]@{schema='winsmux-headless-restricted-actor/v1';outcome='unobserved';source_commit=$null;actor_admitted=$false;same_sid=$false;same_session=$false;restricted_medium=$false;tests=@();root_terminal=$false;root_job_zero=$false;forced=$false;failure=$null;nsis_success_proven=$false;normal_gui_success_proven=$false}
try {
 Assert-Fixed ($env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_OS -ceq 'Windows' -and $env:GITHUB_RUN_ID -cmatch '^[1-9][0-9]*$' -and $env:GITHUB_RUN_ATTEMPT -cmatch '^[1-9][0-9]*$') 'runner_identity'
 $source=if($HeadlessParent -or $SourceAdmissionOnly -or $PrepareCompilerRoot){$SourceCommit}else{$DesktopNativeSourceCommit}
 Assert-Fixed ($source -cmatch '^[a-f0-9]{40}$' -and $source -ceq $env:GITHUB_SHA) 'source_identity'
 $result.source_commit=$source
 Assert-Fixed (-not $ObserveCapabilityToken -or $HeadlessParent) 'token_parent_mode'
 if($capabilityMode){$capabilityResult=New-CapabilityTokenCapture $source}
 Assert-CanonicalSourceInputs $repoRoot
 if($SourceAdmissionOnly){[Console]::Out.WriteLine('{"schema":"winsmux-headless-source-admission/v1","outcome":"passed","runtime_inputs":14,"attribute_policy":"fixed"}');exit 0}
 $ast=Initialize-HeadlessNativeTypes $repoRoot
 if($PrepareCompilerRoot){New-HeadlessCompilerProducer (Get-HeadlessProducerRoot $source) $source $env:GITHUB_RUN_ID $env:GITHUB_RUN_ATTEMPT;[Console]::Out.WriteLine('{"schema":"winsmux-headless-source-admission/v1","outcome":"passed","runtime_inputs":14,"attribute_policy":"fixed"}');exit 0}
 $query=[WinsmuxDesktopNativeActor]::Query();$facts=$query['facts']
 Assert-Fixed ($query['existing_profile_hive'] -eq $true -and $query['local_app_data_exists'] -eq $true -and $facts['token_type'] -eq 1 -and $facts['app_container'] -eq 0) 'actor_profile'
 function Read-OwnedJson([string]$Path){return ([WinsmuxDesktopNativeActor]::ReadChild($Path)|ConvertFrom-Json -AsHashtable)}
 if($HeadlessParent){
  Assert-Fixed (-not $DesktopNativeLifecycle -and $facts['elevation'] -eq 1 -and $facts['integrity_rid'] -ge 12288) 'high_bootstrap'
  $phase='build_binding'
  $bindingObservationPoint='root'
  $root=Join-Path $env:RUNNER_TEMP ('winsmux-headless-actor-'+$env:GITHUB_RUN_ID+'.'+$env:GITHUB_RUN_ATTEMPT+'.'+$source)
  [void][WinsmuxDesktopNativeActor]::NativeDirectory($root,$true)
  $bindingObservationPoint='inputdirs'
  $inputRoot=Join-Path $root 'input';$evidenceRoot=Join-Path $root 'evidence'
  [void][WinsmuxDesktopNativeActor]::NativeDirectory($inputRoot,$true);[void][WinsmuxDesktopNativeActor]::NativeDirectory($evidenceRoot,$true)
  $bindingObservationPoint='manifest'
  $producer=Get-HeadlessProducerRoot $source
  $expectedManifest=Join-Path $env:RUNNER_TEMP ('winsmux-headless-build-'+$env:GITHUB_RUN_ID+'.'+$env:GITHUB_RUN_ATTEMPT+'.'+$source+'.jsonl')
  Assert-Fixed ([string]::Equals([IO.Path]::GetFullPath($BuildManifest),[IO.Path]::GetFullPath($expectedManifest),[StringComparison]::OrdinalIgnoreCase)) 'cargo_manifest_path'
  $bindingObservationPoint='producer'
  $owner=Read-HeadlessCompilerProducer $producer $source $env:GITHUB_RUN_ID $env:GITHUB_RUN_ATTEMPT
  $bindingObservationPoint='selector'
  $selected=Read-HeadlessBuildArtifacts $BuildManifest
  $testImage=$selected.test;$cliImage=$selected.cli
  $bindingObservationPoint='normalize'
  $compilerInputs=[WinsmuxHeadlessOwned.WinsmuxHeadlessCompilerInputs]::Normalize($producer,$owner.identity,$owner.receipt_id,$owner.receipt_sha,[IO.Path]::GetFullPath($BuildManifest),$testImage,$cliImage,$PSCommandPath)
  $bindingObservationPoint='nativeTest'
  $testWitness=[WinsmuxDesktopNativeActor]::NativeFile($testImage);$bindingObservationPoint='nativeCli';$cliWitness=[WinsmuxDesktopNativeActor]::NativeFile($cliImage)
  $bindingObservationPoint='nativeScript'
  $scriptWitness=[WinsmuxDesktopNativeActor]::NativeFile($PSCommandPath)
  $bindingObservationPoint='bind'
  $binding=[ordered]@{schema='winsmux-headless-actor-input/v1';source_commit=$source;expected_sid=$facts['sid_sha256'];expected_session=$facts['session'];script_sha256=$scriptWitness['sha256'];test_executable=$testImage;test_sha256=$testWitness['sha256'];cli_executable=$cliImage;cli_sha256=$cliWitness['sha256'];tests=$tests;compiler_inputs=$compilerInputs}
  $bindingObservationPoint='guardBefore'
  Assert-HeadlessBoundInputs $binding $PSCommandPath
  $bindingObservationPoint='write'
  Write-NewJson (Join-Path $inputRoot 'binding.json') $binding
  $bindingObservationPoint='guardAfter'
  Assert-HeadlessBoundInputs $binding $PSCommandPath
  $phase='medium_bootstrap'
  $pwsh=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$pwshSha=[WinsmuxDesktopNativeActor]::NativeFile($pwsh)['sha256']
  $outer=[WinsmuxDesktopNativeActor]::StartNative('medium-bootstrap',$pwsh,$pwshSha,$root,$source,$inputRoot,$evidenceRoot,$PSCommandPath)
  $budgetFns=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -cin @('Get-DesktopNativeNsisJourneyObservationSlots','Get-DesktopNativeNsisJourneyBudgetMilliseconds')},$false))
  Assert-Fixed ($budgetFns.Count -eq 2) 'existing_budget';foreach($fn in $budgetFns){. ([scriptblock]::Create($fn.Extent.Text))}
  $outerTerminal=$outer.WaitTerminal((Get-DesktopNativeNsisJourneyBudgetMilliseconds))
  if(-not $outerTerminal){$outer.StopOwnedFailure();$outerTerminal=$true;$result.forced=$true}
  $nativeFacts=$outer.Facts();$medium=$nativeFacts['actor']
  if($capabilityMode){$capabilityOuterExitZero=$outer.ExitCode -eq 0}
  $result.root_terminal=$outerTerminal;$result.root_job_zero=$nativeFacts['active_members'] -eq 0
  $result.same_sid=$medium['sid_sha256'] -ceq $facts['sid_sha256'];$result.same_session=$medium['session'] -eq $facts['session']
  $result.restricted_medium=$medium['elevation'] -eq 0 -and $medium['integrity_rid'] -ge 8192 -and $medium['integrity_rid'] -lt 12288 -and $medium['restricted'] -eq 1
  $result.actor_admitted=$result.same_sid -and $result.same_session -and $result.restricted_medium
  if($capabilityMode){
   $phase='token_child_result'
   $capabilityResult=Read-OwnedJson (Join-Path $evidenceRoot 'capability-token-child.json')
   Assert-CapabilityTokenCapture $capabilityResult $source
   Assert-Fixed ($capabilityResult.actor_admitted -and $capabilityResult.same_sid -and $capabilityResult.same_session -and $capabilityResult.restricted_medium) 'token_child_actor'
  }else{
  $phase='bounded_child_result'
  $child=Read-OwnedJson (Join-Path $evidenceRoot 'child-result.json')
  Assert-Fixed ($child.schema -ceq 'winsmux-headless-restricted-actor/v1' -and $child.source_commit -ceq $source -and $child.actor_admitted -eq $true -and @($child.tests).Count -eq 2) 'child_binding'
  $childKeys=@('schema','outcome','source_commit','actor_admitted','same_sid','same_session','restricted_medium','tests','root_terminal','root_job_zero','forced','failure','nsis_success_proven','normal_gui_success_proven')
  Assert-Fixed ((@($child.Keys|Sort-Object -CaseSensitive)-join [char]10) -ceq (@($childKeys|Sort-Object -CaseSensitive)-join [char]10)) 'child_result_shape'
  Assert-Fixed ($child.nsis_success_proven -eq $false -and $child.normal_gui_success_proven -eq $false -and $child.same_sid -eq $true -and $child.same_session -eq $true -and $child.restricted_medium -eq $true) 'child_result_scope'
  for($i=0;$i -lt 2;$i++){Assert-HeadlessProjectionShape $child.tests[$i] $tests[$i]}
  $result.tests=@($child.tests)
  $result.outcome=if($result.actor_admitted -and $result.root_terminal -and $result.root_job_zero -and -not $result.forced -and @($result.tests|Where-Object{$_.outcome -cne 'passed'}).Count -eq 0 -and $outer.ExitCode -eq 0){'passed'}else{'observed_failure'}
  }
 }else{
  Assert-Fixed ($DesktopNativeLifecycle -and $DesktopNativeFormat -ceq 'NSIS' -and $Surface -ceq 'Desktop' -and $Version -ceq '0.38.0' -and $ReleaseTag -ceq 'v0.38.0' -and $Repository -ceq 'Sora-bluesky/winsmux' -and $Json) 'fixed_child_arguments'
  $inputRoot=[IO.Path]::GetFullPath($DesktopNativeCandidateDirectory);$evidenceRoot=[IO.Path]::GetFullPath($DesktopNativeBaselineDirectory)
  $binding=Read-OwnedJson (Join-Path $inputRoot 'binding.json')
  if(@($binding.tests).Count -eq 1 -and $binding.tests[0] -is [string] -and $binding.tests[0] -ceq 'server_capability_token_creation_snapshot'){$capabilityMode=$true;$tests=@('server_capability_token_creation_snapshot');$capabilityResult=New-CapabilityTokenCapture $source}
  Assert-Fixed ($binding.schema -ceq 'winsmux-headless-actor-input/v1' -and $binding.source_commit -ceq $source -and $binding.script_sha256 -ceq [WinsmuxDesktopNativeActor]::NativeFile($PSCommandPath)['sha256'] -and (@($binding.tests)-join [char]10) -ceq ($tests-join [char]10)) 'child_input_binding'
  $result.same_sid=$facts['sid_sha256'] -ceq $binding.expected_sid;$result.same_session=$facts['session'] -eq $binding.expected_session
  $result.restricted_medium=$facts['elevation'] -eq 0 -and $facts['integrity_rid'] -ge 8192 -and $facts['integrity_rid'] -lt 12288 -and $facts['restricted'] -eq 1
  $result.actor_admitted=$result.same_sid -and $result.same_session -and $result.restricted_medium
  Assert-Fixed $result.actor_admitted 'restricted_actor'
  Assert-HeadlessBoundInputs $binding $PSCommandPath
  Add-Type -Path (Join-Path $repoRoot 'scripts/DesktopProcessOwner.cs') -ErrorAction Stop 2>$null
  $testImage=[string]$binding.test_executable;$cliImage=[string]$binding.cli_executable
  if($capabilityMode){
   $phase='token_observation'
   Invoke-CapabilityTokenCapture $binding $PSCommandPath $capabilityResult
  }else{
  $phase='headless_cases';$observed=[Collections.Generic.List[object]]::new()
  foreach($test in $tests){
   Assert-HeadlessBoundInputs $binding $PSCommandPath
   Assert-Fixed ([WinsmuxDesktopNativeActor]::NativeFile($testImage)['sha256'] -ceq $binding.test_sha256 -and [WinsmuxDesktopNativeActor]::NativeFile($cliImage)['sha256'] -ceq $binding.cli_sha256) 'test_input_changed'
   $owned=$null;$terminal=$false
   try{
    $owned=[Winsmux.DesktopNative.DesktopProcessOwner]::Start($testImage,[string[]]@('--exact',$test,'--test-threads=1','--nocapture'),@{},$false,16384,180000)
    $terminal=$owned.WaitTerminal(180000,500)
    if(-not $terminal){$owned.ForceFailureCleanup(180000,500);$terminal=$owned.HasExited -and $owned.ActiveMembers -eq 0 -and $owned.CaptureCompleted}
    $out=$owned.StdoutTask.GetAwaiter().GetResult();$err=$owned.StderrTask.GetAwaiter().GetResult()
    $projection=ConvertTo-HeadlessFixedProjection -Stdout $out.RetainedBytes -Stderr $err.RetainedBytes -Truncated ($out.Truncated -or $err.Truncated) -Test $test -ExitCode $owned.ExitCode -Terminal $terminal -JobZero ($owned.ActiveMembers -eq 0) -Forced $owned.Forced
    $observed.Add($projection);$result.tests=$observed.ToArray()
    # Raw retained bytes stay in memory and are never written, emitted or uploaded.
    $out=$null;$err=$null
   }finally{
    if($null -ne $owned){if(-not $terminal){$owned.ForceFailureCleanup(180000,500)};if($owned.HasExited -and $owned.ActiveMembers -eq 0 -and $owned.CaptureCompleted){$owned.Dispose()}}
   }
   Assert-HeadlessBoundInputs $binding $PSCommandPath
   Assert-Fixed ([WinsmuxDesktopNativeActor]::NativeFile($testImage)['sha256'] -ceq $binding.test_sha256 -and [WinsmuxDesktopNativeActor]::NativeFile($cliImage)['sha256'] -ceq $binding.cli_sha256) 'test_output_changed_inputs'
  }
  $result.tests=$observed.ToArray();$result.outcome=if(@($result.tests|Where-Object{$_.outcome -cne 'passed'}).Count -eq 0){'passed'}else{'observed_failure'}
  }
 }
}catch{
 if($HeadlessParent -and $phase -is [string] -and $phase -ceq 'build_binding'){
  try{
   $bindingObservationProjected='unobserved'
   if($bindingObservationPoint -is [string] -and $bindingObservationPoint -cin @('root','inputdirs','manifest','producer','selector','normalize','nativeTest','nativeCli','nativeScript','bind','guardBefore','write','guardAfter')){$bindingObservationProjected=$bindingObservationPoint}
   [Console]::Error.WriteLine('WINSMUX_HEADLESS_BINDING point='+$bindingObservationProjected)
  }catch{}
 }
 $result.failure=$phase;$result.outcome='unobserved'}
finally{
 if($null -ne $outer){try{if(-not $outerTerminal){$outer.StopOwnedFailure();$outerTerminal=$true;$result.forced=$true};$result.root_terminal=$outerTerminal;$result.root_job_zero=$outer.ActiveMembers -eq 0;if($outerTerminal -and $result.root_job_zero){$outer.Dispose()}}catch{$result.failure='root_convergence';$result.outcome='unobserved'}}
}
if($capabilityMode){
 if($null -eq $capabilityResult){$capabilityResult=New-CapabilityTokenCapture $result.source_commit}
 foreach($name in @('actor_admitted','same_sid','same_session','restricted_medium','root_terminal','root_job_zero','forced')){$capabilityResult[$name]=$result[$name]}
 if($null -ne $result.failure){$capabilityResult.failure=$result.failure}
 try{
  Assert-CapabilityTokenCapture $capabilityResult $result.source_commit
  if($null -ne $evidenceRoot){$name=if($HeadlessParent){'capability-token-result.json'}else{'capability-token-child.json'};Write-NewJson (Join-Path $evidenceRoot $name) $capabilityResult}
 }catch{$capabilityResult.failure='result_preservation'}
 $capabilityResult|ConvertTo-Json -Depth 16 -Compress
 $closed=$capabilityResult.capture.terminal -and $capabilityResult.capture.job_zero -and $capabilityResult.capture.capture_complete -and -not $capabilityResult.capture.forced -and $capabilityResult.capture.process_exit -ceq 'zero'
 $rootClosed=(-not $HeadlessParent) -or ($capabilityResult.root_terminal -and $capabilityResult.root_job_zero -and -not $capabilityResult.forced -and $capabilityOuterExitZero)
 exit $(if($capabilityResult.diagnostic_received -and $capabilityResult.query_complete -and $capabilityResult.actor_admitted -and $closed -and $rootClosed -and $null -eq $capabilityResult.failure){0}else{1})
}

if(-not $HeadlessParent -and $null -ne $evidenceRoot){try{Write-NewJson (Join-Path $evidenceRoot 'child-result.json') $result}catch{$result.failure='result_preservation';$result.outcome='unobserved'}}
if($HeadlessParent -and $null -ne $evidenceRoot){try{Write-NewJson (Join-Path $evidenceRoot 'headless-result.json') $result}catch{$result.failure='result_preservation';$result.outcome='unobserved'}}
$result|ConvertTo-Json -Depth 12 -Compress
exit $(if($result.outcome -ceq 'passed'){0}else{1})
