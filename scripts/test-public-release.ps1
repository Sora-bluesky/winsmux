[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Core', 'Desktop', 'Npm')]
    [string]$Surface,

    [Parameter(Mandatory)]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$ReleaseTag,

    [Parameter(Mandatory)]
    [string]$Repository,

    [string]$CandidateInstallerPath,

    [string]$DesktopInventoryPath,

    [string]$PriorInstallerPath,

    [string]$PriorVersion,

    [ValidateSet('PortAndMarker', 'MarkerOnly')]
    [string]$DesktopLegacyEnvMode = 'PortAndMarker',

    [switch]$DesktopNativeActorProbeOnly,

    [switch]$DesktopNativeLifecycle,

    [ValidateSet('MSI', 'NSIS')]
    [string]$DesktopNativeFormat,

    [string]$DesktopNativeSourceCommit,

    [string]$DesktopNativeCandidateDirectory,

    [string]$DesktopNativeBaselineDirectory,

    [switch]$SelfTest,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function Assert-DesktopNativeActorRequest {
    param([Collections.IDictionary]$Arguments, [string]$CallerHead, [string]$ActualHead)
    foreach ($key in @('Surface', 'Version', 'ReleaseTag', 'Repository', 'DesktopNativeSourceCommit', 'DesktopNativeActorProbeOnly', 'Json')) { if (-not $Arguments.ContainsKey($key)) { throw 'actor_probe_input_missing' } }
    if ($Arguments['Surface'] -cne 'Desktop' -or $Arguments['Version'] -cne '0.38.0' -or $Arguments['ReleaseTag'] -cne 'v0.38.0' -or $Arguments['Repository'] -cne 'Sora-bluesky/winsmux' -or -not [bool]$Arguments['Json'] -or -not [bool]$Arguments['DesktopNativeActorProbeOnly']) { throw 'actor_probe_identity_refused' }
    foreach ($mixed in @('DesktopNativeLifecycle', 'DesktopNativeFormat', 'DesktopNativeCandidateDirectory', 'DesktopNativeBaselineDirectory', 'CandidateInstallerPath', 'DesktopInventoryPath', 'PriorInstallerPath', 'PriorVersion', 'DesktopLegacyEnvMode', 'SelfTest')) { if ($Arguments.ContainsKey($mixed)) { throw 'actor_probe_mixed_mode_refused' } }
    $source = [string]$Arguments['DesktopNativeSourceCommit']
    if ($source -cnotmatch '^[a-f0-9]{40}$' -or $source -cne $CallerHead -or $source -cne $ActualHead) { throw 'actor_probe_source_refused' }
}

# This isolated entry runs before inventory imports and every installer validator.
if ($DesktopNativeActorProbeOnly) {
    $actorResult = [ordered]@{ schema = 'winsmux-desktop-native-actor-probe/v1'; outcome = 'failed'; created = $false; resumed = $false; installer_started = $false }
    try {
        Assert-DesktopNativeActorRequest $PSBoundParameters $env:GITHUB_SHA $DesktopNativeSourceCommit
        $actorRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $actualHead = (& git -C $actorRepo rev-parse HEAD | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'actor_probe_checkout_refused' }
        Assert-DesktopNativeActorRequest $PSBoundParameters $env:GITHUB_SHA $actualHead
        if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_RUN_ID -cnotmatch '^[1-9][0-9]*$' -or $env:GITHUB_RUN_ATTEMPT -cnotmatch '^[1-9][0-9]*$') { throw 'actor_probe_runner_identity_refused' }
        $temp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
        $tempItem = Get-Item -LiteralPath $temp -Force
        if (-not $tempItem.PSIsContainer -or ($tempItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'actor_probe_temp_refused' }
        $actorRoot = Join-Path $temp ('winsmux-native-actor-' + $env:GITHUB_RUN_ID + '.' + $env:GITHUB_RUN_ATTEMPT + '.' + $DesktopNativeSourceCommit)
        if (Test-Path -LiteralPath $actorRoot) { throw 'actor_probe_namespace_exists' }
        $actorSourceHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $actorCSharp = @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
public static class WinsmuxDesktopActorProbe {
 [StructLayout(LayoutKind.Sequential)] struct SA { public IntPtr Sid; public uint Attributes; }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct SI { public uint cb; public string reserved,desktop,title; public uint x,y,xs,ys,xc,yc,fill,flags; public ushort show,reserved2; public IntPtr bytes,stdin,stdout,stderr; }
 [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr process,thread; public uint pid,tid; }
 [StructLayout(LayoutKind.Sequential)] struct BASIC { public long processTime,jobTime; public uint flags; public UIntPtr minWork,maxWork; public uint active; public UIntPtr affinity; public uint priority,scheduling; }
 [StructLayout(LayoutKind.Sequential)] struct IO { public ulong readOps,writeOps,otherOps,readBytes,writeBytes,otherBytes; }
 [StructLayout(LayoutKind.Sequential)] struct LIMIT { public BASIC basic; public IO io; public UIntPtr processMemory,jobMemory,peakProcess,peakJob; }
 [StructLayout(LayoutKind.Sequential)] struct ACCOUNT { public long totalUser,totalKernel,periodUser,periodKernel; public uint faults,totalProcesses,activeProcesses,terminatedProcesses; }
 [StructLayout(LayoutKind.Sequential)] struct FILEINFO { public uint attributes; public System.Runtime.InteropServices.ComTypes.FILETIME creation,access,write; public uint volume,sizeHigh,sizeLow,links,indexHigh,indexLow; }
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool ProcessIdToSessionId(uint pid,out uint session);
 [DllImport("kernel32.dll")] static extern uint GetCurrentProcessId();
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr p,uint access,out IntPtr h);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenThreadToken(IntPtr p,uint access,bool self,out IntPtr h);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr h,int kind,IntPtr b,uint size,out uint n);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool SetTokenInformation(IntPtr h,int kind,IntPtr b,uint size);
 [DllImport("advapi32.dll")] static extern uint GetLengthSid(IntPtr sid);
 [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
 [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid,uint index);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool CreateWellKnownSid(int kind,IntPtr domain,IntPtr sid,ref uint size);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool CreateRestrictedToken(IntPtr token,uint flags,uint disableCount,ref SA disable,uint deleteCount,IntPtr delete,uint restrictCount,IntPtr restrict,out IntPtr result);
 [DllImport("advapi32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool CreateProcessAsUserW(IntPtr token,string app,StringBuilder command,IntPtr psa,IntPtr tsa,bool inherit,uint flags,IntPtr env,string cwd,ref SI startup,out PI process);
 [DllImport("userenv.dll",SetLastError=true)] static extern bool CreateEnvironmentBlock(out IntPtr env,IntPtr token,bool inherit);
 [DllImport("userenv.dll",SetLastError=true)] static extern bool DestroyEnvironmentBlock(IntPtr env);
 [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr sa,string name);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr h,int kind,ref LIMIT b,uint size);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr h,int kind,out ACCOUNT b,uint size,IntPtr returned);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool member);
 [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
 [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr h,uint timeout);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h,out uint code);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr h,uint code);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr h,uint code);
 [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool QueryFullProcessImageNameW(IntPtr h,uint flags,StringBuilder name,ref uint size);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr h,out long creation,out long exit,out long kernel,out long user);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(IntPtr h,out FILEINFO info);
 [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool CreateDirectoryW(string path,IntPtr sa);
 [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern IntPtr CreateFileW(string path,uint access,uint share,IntPtr sa,uint disposition,uint flags,IntPtr template);
 [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
 [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint id);
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 [DllImport("user32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr h,int kind,StringBuilder text,uint bytes,out uint needed);
 static void Check(bool value,string where) { if(!value) throw new Win32Exception(Marshal.GetLastWin32Error(),where); }
 static string Hash(byte[] b) { using(var h=SHA256.Create()) return BitConverter.ToString(h.ComputeHash(b)).Replace("-","").ToLowerInvariant(); }
 static IntPtr Info(IntPtr h,int kind) { uint returned; return Info(h,kind,out returned); }
 static IntPtr Info(IntPtr h,int kind,out uint returned) {
  uint capacity; GetTokenInformation(h,kind,IntPtr.Zero,0,out capacity);
  // The size query may report ERROR_BAD_LENGTH for TokenElevation while returning its exact four-byte size.
  // Only the final API success and written range authorize reads; no size-query error-code assumption.
  if(capacity==0 || capacity>65536) throw new InvalidOperationException("Token information size refused");
  IntPtr b=Marshal.AllocHGlobal((int)capacity); try {
   Marshal.Copy(new byte[capacity],0,b,(int)capacity);
   Check(GetTokenInformation(h,kind,b,capacity,out returned),"GetTokenInformation "+kind);
   if(returned==0 || returned>capacity) throw new InvalidOperationException("Token information returned range refused");
   return b;
  } catch { Marshal.FreeHGlobal(b); throw; }
 }
 static uint NormalizeTokenNumber(int kind,byte[] data) {
  if(data==null) throw new InvalidOperationException("Token numeric bytes missing");
  // TokenHasRestrictions is documented as DWORD but the measured Windows provider also returns one BOOLEAN byte.
  // Both closed widths express nonzero TRUE; read only returned bytes and canonicalize the same fact to zero or one.
  if(kind==21) {
   if(data.Length==1) return data[0]==0?0u:1u;
   if(data.Length!=4) throw new InvalidOperationException("Token restriction width refused");
   return BitConverter.ToUInt32(data,0)==0?0u:1u;
  }
  if(kind!=8 && kind!=18 && kind!=12 && kind!=20 && kind!=29) throw new InvalidOperationException("Token numeric class refused");
  if(data.Length!=4) throw new InvalidOperationException("Token DWORD width refused");
  uint value=BitConverter.ToUInt32(data,0);
  if(kind==20 || kind==29) return value==0?0u:1u;
  if((kind==8 && value!=1 && value!=2)||(kind==18 && value!=1 && value!=2 && value!=3)) throw new InvalidOperationException("Token enum value refused");
  return value;
 }
 static uint Value(IntPtr h,int kind) { uint returned; var b=Info(h,kind,out returned); try {var data=new byte[returned];Marshal.Copy(b,data,0,(int)returned);return NormalizeTokenNumber(kind,data);} finally {Marshal.FreeHGlobal(b);} }
 sealed class TokenFacts {
  internal byte[] sid; internal string sidText; internal uint elevation,type,rid,session,tokenType,restricted,appContainer;
  internal Dictionary<string,object> Public() { return new Dictionary<string,object>{{"sid_sha256",Hash(sid)},{"elevation",elevation},{"elevation_type",type},{"integrity_rid",rid},{"session",session},{"token_type",tokenType},{"restricted",restricted},{"app_container",appContainer}}; }
 }
 static TokenFacts Observe(IntPtr token) {
  var t=new TokenFacts(); var u=Info(token,1); var m=Info(token,25);
  try { var sid=Marshal.ReadIntPtr(u); t.sid=new byte[GetLengthSid(sid)]; Marshal.Copy(sid,t.sid,0,t.sid.Length); t.sidText=new SecurityIdentifier(sid).Value; var integrity=Marshal.ReadIntPtr(m); uint count=Marshal.ReadByte(GetSidSubAuthorityCount(integrity)); if(count==0) throw new InvalidOperationException("Integrity SID refused"); t.rid=(uint)Marshal.ReadInt32(GetSidSubAuthority(integrity,count-1)); }
  finally { Marshal.FreeHGlobal(u); Marshal.FreeHGlobal(m); }
  t.elevation=Value(token,20); t.type=Value(token,18); t.session=Value(token,12); t.tokenType=Value(token,8); t.restricted=Value(token,21); t.appContainer=Value(token,29); return t;
 }
 static bool Equal(byte[] a,byte[] b) { if(a.Length!=b.Length)return false; for(int i=0;i<a.Length;i++)if(a[i]!=b[i])return false; return true; }
 static void Medium(TokenFacts t,TokenFacts caller) { if(!Equal(t.sid,caller.sid)||t.session!=caller.session||t.tokenType!=1||t.elevation!=0||t.rid<8192||t.rid>=12288||t.appContainer!=0) throw new InvalidOperationException("Actual medium actor identity refused"); }
 static IntPtr Sid(int kind,out uint n) { n=68; var b=Marshal.AllocHGlobal(68); try { Check(CreateWellKnownSid(kind,IntPtr.Zero,b,ref n),"CreateWellKnownSid"); return b; } catch { Marshal.FreeHGlobal(b); throw; } }
 // Default object security belongs only to a newly created restricted primary.
 [StructLayout(LayoutKind.Sequential)] struct GROUPS_HEAD { public uint count; public SA first; }
 [StructLayout(LayoutKind.Sequential)] struct PRIVILEGE { public uint low; public int high; public uint attributes; }
 [StructLayout(LayoutKind.Sequential)] struct PRIVILEGES_HEAD { public uint count; public PRIVILEGE first; }
 sealed class SidAttributes { internal byte[] sid; internal uint attributes; }
 sealed class TokenSecurity { internal TokenFacts facts; internal byte[] user,owner,primaryGroup,integrity,dacl; internal uint userAttributes,integrityAttributes; internal SidAttributes[] groups,restricting; internal PRIVILEGE[] privileges; }
 static int SidBytesLength(byte[] bytes,int offset,int limit) {
  if(bytes==null||offset<0||limit>bytes.Length||offset>limit-8||bytes[offset]!=1||bytes[offset+1]>15)throw new InvalidOperationException("SID bounds refused");
  int n=8+4*bytes[offset+1];if(n>limit-offset)throw new InvalidOperationException("SID length refused");return n;
 }
 static byte[] CopyBytes(byte[] bytes,int offset,int count) {var value=new byte[count];Buffer.BlockCopy(bytes,offset,value,0,count);return value;}
 static byte[] PointerSid(IntPtr buffer,uint returned,int offset) {
  if(offset<0||(ulong)offset+(uint)IntPtr.Size>returned)throw new InvalidOperationException("Token SID pointer bounds refused");
  var sid=Marshal.ReadIntPtr(buffer,offset);long delta=sid.ToInt64()-buffer.ToInt64();if(delta<0||delta>(long)returned-8)throw new InvalidOperationException("Token SID range refused");
  var head=new byte[8];Marshal.Copy(sid,head,0,8);int size=8+4*head[1];if(head[0]!=1||head[1]>15||size>(long)returned-delta)throw new InvalidOperationException("Token SID bytes refused");
  var bytes=new byte[size];Marshal.Copy(sid,bytes,0,size);return bytes;
 }
 static byte[] TokenSid(IntPtr token,int kind,out uint attributes) {
  uint n;var p=Info(token,kind,out n);try{var value=PointerSid(p,n,0);attributes=0;if(kind==1||kind==25){if(n<(uint)(IntPtr.Size+4))throw new InvalidOperationException("Token SID attributes bounds refused");attributes=unchecked((uint)Marshal.ReadInt32(p,IntPtr.Size));}return value;}finally{Marshal.FreeHGlobal(p);}
 }
 static SidAttributes[] TokenGroups(IntPtr token,int kind) {
  uint n;var p=Info(token,kind,out n);try{if(n<4)throw new InvalidOperationException("Token group count bounds refused");uint count=unchecked((uint)Marshal.ReadInt32(p));int offset=Marshal.OffsetOf<GROUPS_HEAD>("first").ToInt32(),stride=Marshal.SizeOf<SA>();if(count>0&&(ulong)offset+(ulong)count*(uint)stride>n)throw new InvalidOperationException("Token group array bounds refused");var rows=new SidAttributes[count];for(uint i=0;i<count;i++){int at=checked(offset+(int)i*stride);rows[i]=new SidAttributes{sid=PointerSid(p,n,at),attributes=unchecked((uint)Marshal.ReadInt32(p,at+IntPtr.Size))};}return rows;}finally{Marshal.FreeHGlobal(p);}
 }
 static PRIVILEGE[] TokenPrivileges(IntPtr token) {
  uint n;var p=Info(token,3,out n);try{if(n<4)throw new InvalidOperationException("Token privilege count bounds refused");uint count=unchecked((uint)Marshal.ReadInt32(p));int offset=Marshal.OffsetOf<PRIVILEGES_HEAD>("first").ToInt32(),stride=Marshal.SizeOf<PRIVILEGE>();if((ulong)offset+(ulong)count*(uint)stride>n)throw new InvalidOperationException("Token privilege array bounds refused");var rows=new PRIVILEGE[count];for(uint i=0;i<count;i++)rows[i]=Marshal.PtrToStructure<PRIVILEGE>(IntPtr.Add(p,checked(offset+(int)i*stride)));return rows;}finally{Marshal.FreeHGlobal(p);}
 }
 static byte[] TokenDefaultAcl(IntPtr token) {
  uint n;var p=Info(token,6,out n);try{if(n<(uint)IntPtr.Size)throw new InvalidOperationException("Token default ACL pointer bounds refused");var acl=Marshal.ReadIntPtr(p);if(acl==IntPtr.Zero)return null;long offset=acl.ToInt64()-p.ToInt64();if(offset<0||offset>(long)n-8)throw new InvalidOperationException("Token default ACL range refused");int length=unchecked((ushort)Marshal.ReadInt16(acl,2));if(length<8||length>(long)n-offset)throw new InvalidOperationException("Token default ACL bytes refused");var bytes=new byte[length];Marshal.Copy(acl,bytes,0,length);return bytes;}finally{Marshal.FreeHGlobal(p);}
 }
 static TokenSecurity SecuritySnapshot(IntPtr token) {
  uint unused;var value=new TokenSecurity{facts=Observe(token)};value.user=TokenSid(token,1,out value.userAttributes);value.owner=TokenSid(token,4,out unused);value.primaryGroup=TokenSid(token,5,out unused);value.integrity=TokenSid(token,25,out value.integrityAttributes);value.dacl=TokenDefaultAcl(token);value.groups=TokenGroups(token,2);value.restricting=TokenGroups(token,11);value.privileges=TokenPrivileges(token);if(!Equal(value.user,value.facts.sid))throw new InvalidOperationException("Token user snapshot changed");return value;
 }
 static bool NullableBytesEqual(byte[] a,byte[] b) {return a==null?b==null:b!=null&&Equal(a,b);}
 static string[] GroupState(SidAttributes[] rows,byte[] oldIntegrity,byte[] newIntegrity) {
  var values=new List<string>();int mapped=0;foreach(var row in rows){var sid=row.sid;if(oldIntegrity!=null&&Equal(sid,oldIntegrity)){sid=newIntegrity;mapped++;}values.Add(Convert.ToBase64String(sid)+":"+row.attributes);}if(mapped>1)throw new InvalidOperationException("Duplicate integrity group refused");values.Sort(StringComparer.Ordinal);return values.ToArray();
 }
 static string[] PrivilegeState(PRIVILEGE[] rows) {var values=new List<string>();foreach(var row in rows)values.Add(row.low+":"+row.high+":"+row.attributes);values.Sort(StringComparer.Ordinal);return values.ToArray();}
 static bool SameStrings(string[] a,string[] b) {if(a.Length!=b.Length)return false;for(int i=0;i<a.Length;i++)if(a[i]!=b[i])return false;return true;}
 static byte[] MediumIntegritySid() {var sid=new SecurityIdentifier("S-1-16-8192");var b=new byte[sid.BinaryLength];sid.GetBinaryForm(b,0);return b;}
 static void RequireSecuritySame(TokenSecurity expected,TokenSecurity actual,byte[] expectedDacl,bool mediumRid) {
  var a=expected.facts;var b=actual.facts;
  if(!Equal(a.sid,b.sid)||a.elevation!=b.elevation||a.type!=b.type||a.session!=b.session||a.tokenType!=b.tokenType||a.restricted!=b.restricted||a.appContainer!=b.appContainer||b.rid!=(mediumRid?8192u:a.rid)||!Equal(expected.user,actual.user)||expected.userAttributes!=actual.userAttributes||!Equal(expected.owner,actual.owner)||!Equal(expected.primaryGroup,actual.primaryGroup)||expected.integrityAttributes!=actual.integrityAttributes||!Equal(mediumRid?MediumIntegritySid():expected.integrity,actual.integrity)||!NullableBytesEqual(expectedDacl,actual.dacl)||!SameStrings(GroupState(expected.groups,mediumRid?expected.integrity:null,mediumRid?actual.integrity:null),GroupState(actual.groups,null,null))||!SameStrings(GroupState(expected.restricting,null,null),GroupState(actual.restricting,null,null))||!SameStrings(PrivilegeState(expected.privileges),PrivilegeState(actual.privileges)))throw new InvalidOperationException("Token security snapshot changed beyond admitted delta");
 }
 static void RequireFreshProfile(TokenSecurity fresh,TokenSecurity caller) {
  var a=fresh.facts;var c=caller.facts;if(!Equal(a.sid,c.sid)||a.session!=c.session||a.tokenType!=1||a.elevation!=0||a.rid<8192||a.restricted!=1||a.appContainer!=0||!Equal(fresh.owner,fresh.user)||fresh.restricting.Length!=0)throw new InvalidOperationException("Fresh restricted primary profile refused");
  var admin=new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid,null);var adminSid=new byte[admin.BinaryLength];admin.GetBinaryForm(adminSid,0);int count=0;foreach(var row in fresh.groups)if(Equal(row.sid,adminSid)){count++;if((row.attributes&0x10)==0||(row.attributes&6)!=0)throw new InvalidOperationException("Administrators deny-only state refused");}if(count!=1)throw new InvalidOperationException("Administrators group profile refused");
  foreach(var privilege in fresh.privileges)if((privilege.attributes&2)!=0){bool prior=false;foreach(var old in caller.privileges)if(privilege.low==old.low&&privilege.high==old.high&&(old.attributes&2)!=0)prior=true;if(!prior)throw new InvalidOperationException("Fresh privilege enable refused");}
 }
 static byte[] PrivateUserDefaultAcl(byte[] before,byte[] user) {
  if(user==null||SidBytesLength(user,0,user.Length)!=user.Length||before==null||before.Length<8||before.Length>65535||(before[0]!=2&&before[0]!=4)||before[1]!=0||BitConverter.ToUInt16(before,6)!=0||BitConverter.ToUInt16(before,2)!=before.Length)throw new InvalidOperationException("Default ACL header refused");
  int count=BitConverter.ToUInt16(before,4),at=8,userGa=0;if(count==0)throw new InvalidOperationException("Empty default ACL refused");
  for(int i=0;i<count;i++){if(at>before.Length-8||before[at]!=0||before[at+1]!=0)throw new InvalidOperationException("Unmodeled default ACE refused");int size=BitConverter.ToUInt16(before,at+2);if(size<16||(size&3)!=0||size>before.Length-at)throw new InvalidOperationException("Default ACE bounds refused");int sidSize=SidBytesLength(before,at+8,at+size);if(size!=8+sidSize)throw new InvalidOperationException("Default ACE SID bounds refused");if(BitConverter.ToUInt32(before,at+4)==0x10000000u&&Equal(CopyBytes(before,at+8,sidSize),user))userGa++;at+=size;}
  if(at!=before.Length||userGa>1)throw new InvalidOperationException("Default ACL inventory refused");if(userGa==1)return (byte[])before.Clone();int extra=8+user.Length;if(before.Length+extra>65535||count==65535)throw new InvalidOperationException("Default ACL append bounds refused");var after=new byte[before.Length+extra];Buffer.BlockCopy(before,0,after,0,before.Length);Buffer.BlockCopy(BitConverter.GetBytes((ushort)after.Length),0,after,2,2);Buffer.BlockCopy(BitConverter.GetBytes((ushort)(count+1)),0,after,4,2);after[at]=0;after[at+1]=0;Buffer.BlockCopy(BitConverter.GetBytes((ushort)extra),0,after,at+2,2);Buffer.BlockCopy(BitConverter.GetBytes(0x10000000u),0,after,at+4,4);Buffer.BlockCopy(user,0,after,at+8,user.Length);return after;
 }
 static void SetFreshDefaultAcl(IntPtr derived,byte[] bytes) {
  IntPtr acl=IntPtr.Zero,descriptor=IntPtr.Zero;try{acl=Marshal.AllocHGlobal(bytes.Length);Marshal.Copy(bytes,0,acl,bytes.Length);descriptor=Marshal.AllocHGlobal(IntPtr.Size);Marshal.WriteIntPtr(descriptor,acl);Check(SetTokenInformation(derived,6,descriptor,(uint)IntPtr.Size),"Set fresh derived default ACL");}finally{if(descriptor!=IntPtr.Zero)Marshal.FreeHGlobal(descriptor);if(acl!=IntPtr.Zero)Marshal.FreeHGlobal(acl);}
 }
 static bool SameActorFacts(TokenFacts a,TokenFacts b) {return Equal(a.sid,b.sid)&&a.elevation==b.elevation&&a.type==b.type&&a.rid==b.rid&&a.session==b.session&&a.tokenType==b.tokenType&&a.restricted==b.restricted&&a.appContainer==b.appContainer;}
 static IntPtr CreateRestrictedMediumPrimary(IntPtr callerToken,TokenFacts caller,out TokenFacts initial) {
  var callerBefore=SecuritySnapshot(callerToken);if(!SameActorFacts(callerBefore.facts,caller)||callerBefore.facts.elevation!=1||callerBefore.facts.rid<12288)throw new InvalidOperationException("Fresh primary caller changed");
  IntPtr derived=IntPtr.Zero,admin=IntPtr.Zero,medium=IntPtr.Zero;bool transfer=false;initial=null;
  try{uint n;admin=Sid(26,out n);var disabled=new SA{Sid=admin,Attributes=0};Check(CreateRestrictedToken(callerToken,5,1,ref disabled,0,IntPtr.Zero,0,IntPtr.Zero,out derived),"Create fresh restricted primary flags 5");var fresh=SecuritySnapshot(derived);RequireFreshProfile(fresh,callerBefore);initial=fresh.facts;
   if(fresh.facts.rid>8192){medium=Sid(67,out n);var label=new SA{Sid=medium,Attributes=0x20};var memory=Marshal.AllocHGlobal(Marshal.SizeOf<SA>());try{Marshal.StructureToPtr(label,memory,false);Check(SetTokenInformation(derived,25,memory,(uint)Marshal.SizeOf<SA>()+n),"Set fresh derived medium label");}finally{Marshal.FreeHGlobal(memory);}}
   var expected=PrivateUserDefaultAcl(fresh.dacl,fresh.user);if(!Equal(fresh.dacl,expected))SetFreshDefaultAcl(derived,expected);var after=SecuritySnapshot(derived);RequireFreshProfile(after,callerBefore);RequireSecuritySame(fresh,after,expected,true);Medium(after.facts,caller);transfer=true;return derived;
  }finally{bool callerSame=false;try{RequireSecuritySame(callerBefore,SecuritySnapshot(callerToken),callerBefore.dacl,false);callerSame=true;}finally{if((!transfer||!callerSame)&&derived!=IntPtr.Zero)CloseHandle(derived);if(admin!=IntPtr.Zero)Marshal.FreeHGlobal(admin);if(medium!=IntPtr.Zero)Marshal.FreeHGlobal(medium);}}
 }
 static string DesktopName(IntPtr h) { uint n; var b=new StringBuilder(256); Check(GetUserObjectInformationW(h,2,b,512,out n),"GetUserObjectInformation"); var s=b.ToString(); if(s.Length==0||s.Contains("\\")||s.Contains("\0"))throw new InvalidOperationException("Desktop name refused"); return s; }
 static FileStream OpenPlain(string path) { var handle=CreateFileW(path,0x80000000,1,IntPtr.Zero,3,0x00200000,IntPtr.Zero); if(handle==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error(),"Open plain file lease"); var safe=new Microsoft.Win32.SafeHandles.SafeFileHandle(handle,true); try {var facts=FileFacts(handle);if(facts.links!=1||(facts.attributes&0x10)!=0)throw new InvalidOperationException("Plain single-link file required");return new FileStream(safe,FileAccess.Read);}catch{safe.Dispose();throw;} }
 static FILEINFO FileFacts(IntPtr h) { FILEINFO f; Check(GetFileInformationByHandle(h,out f),"GetFileInformationByHandle"); if((f.attributes&0x400)!=0)throw new InvalidOperationException("Reparse object refused"); return f; }
 static string FileId(FILEINFO f) { return f.volume+":"+f.indexHigh+":"+f.indexLow; }
 static Dictionary<string,string> UserEnvironment(IntPtr token) {
  IntPtr block; Check(CreateEnvironmentBlock(out block,token,false),"CreateEnvironmentBlock"); var env=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
  try { int offset=0; for(int count=0;count<4096;count++) { var s=Marshal.PtrToStringUni(IntPtr.Add(block,offset)); if(String.IsNullOrEmpty(s))break; offset+=(s.Length+1)*2; int at=s.IndexOf('='); if(at>0) { var key=s.Substring(0,at); if(Array.Exists(new[]{"SystemRoot","WINDIR","SystemDrive","ComSpec","PATH","PATHEXT","TEMP","TMP","USERPROFILE","HOMEDRIVE","HOMEPATH","APPDATA","LOCALAPPDATA","USERNAME","USERDOMAIN","ProgramData","ProgramFiles","ProgramFiles(x86)","CommonProgramFiles","CommonProgramFiles(x86)","PROCESSOR_ARCHITECTURE","NUMBER_OF_PROCESSORS"}, x=>String.Equals(x,key,StringComparison.OrdinalIgnoreCase)))env[key]=s.Substring(at+1); } } } finally { Check(DestroyEnvironmentBlock(block),"DestroyEnvironmentBlock"); }
  foreach(string key in new[]{"GITHUB_ACTIONS","RUNNER_OS","RUNNER_TEMP","GITHUB_SHA","GITHUB_RUN_ID","GITHUB_RUN_ATTEMPT"}) { var value=Environment.GetEnvironmentVariable(key); if(value!=null)env[key]=value; }
  return env;
 }
 public static Dictionary<string,object> Query() { IntPtr h; Check(OpenProcessToken(GetCurrentProcess(),8,out h),"OpenProcessToken query"); try { var facts=Observe(h); bool profile; using(var hive=Microsoft.Win32.Registry.Users.OpenSubKey(facts.sidText,false))profile=hive!=null; return new Dictionary<string,object>{{"facts",facts.Public()},{"pid",GetCurrentProcessId()},{"existing_profile_hive",profile},{"local_app_data_exists",Directory.Exists(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData))}}; } finally { CloseHandle(h); } }
 public static string ReadChild(string path) { using(var f=OpenPlain(path)) {var info=FileFacts(f.SafeFileHandle.DangerousGetHandle()); if(info.links!=1||(info.attributes&0x10)!=0||f.Length<2||f.Length>16384)throw new InvalidOperationException("Child receipt file refused"); byte[] b=new byte[f.Length]; int at=0;while(at<b.Length){int n=f.Read(b,at,b.Length-at);if(n==0)throw new EndOfStreamException();at+=n;}if(FileId(FileFacts(f.SafeFileHandle.DangerousGetHandle()))!=FileId(info)||Hash(File.ReadAllBytes(path))!=Hash(b))throw new InvalidOperationException("Child receipt changed");return new UTF8Encoding(false,true).GetString(b);} }
 public static Dictionary<string,object> Probe(string image,string root,string childScript) {
  var result=new Dictionary<string,object>{{"schema","winsmux-desktop-native-actor-probe/v1"},{"outcome","failed"},{"created",false},{"resumed",false},{"installer_started",false}};
  IntPtr callerToken=IntPtr.Zero,derived=IntPtr.Zero,job=IntPtr.Zero,environment=IntPtr.Zero,dir=IntPtr.Zero; PI pi=new PI(); bool assigned=false,terminal=false; FileStream imageLease=null,scriptLease=null;
  try {
   IntPtr impersonation; if(OpenThreadToken(GetCurrentThread(),8,true,out impersonation)) { CloseHandle(impersonation); throw new InvalidOperationException("Thread impersonation refused"); } if(Marshal.GetLastWin32Error()!=1008)throw new Win32Exception(Marshal.GetLastWin32Error(),"OpenThreadToken");
   Check(OpenProcessToken(GetCurrentProcess(),0x8b,out callerToken),"OpenProcessToken caller"); var caller=Observe(callerToken); result["caller"]=caller.Public(); uint session; Check(ProcessIdToSessionId(GetCurrentProcessId(),out session),"ProcessIdToSessionId");
   if(caller.tokenType!=1||caller.session!=session||caller.appContainer!=0||caller.sidText=="S-1-5-18"||caller.sidText=="S-1-5-19"||caller.sidText=="S-1-5-20"||caller.sidText.StartsWith("S-1-5-80-",StringComparison.Ordinal))throw new InvalidOperationException("Caller identity refused");
   if(caller.elevation!=1||caller.rid<12288) { result["outcome"]="host_not_applicable"; return result; }
   TokenFacts initial;derived=CreateRestrictedMediumPrimary(callerToken,caller,out initial);result["derived_initial"]=initial.Public();
   var actor=Observe(derived);result["derived"]=actor.Public();Medium(actor,caller);
   var env=UserEnvironment(derived); string local; if(!env.TryGetValue("LOCALAPPDATA",out local)||!String.Equals(Path.GetFullPath(local),Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)),StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Existing same-SID profile refused");
   image=Path.GetFullPath(image); imageLease=OpenPlain(image); var imageInfo=FileFacts(imageLease.SafeFileHandle.DangerousGetHandle()); if(imageInfo.links!=1||(imageInfo.attributes&0x10)!=0)throw new InvalidOperationException("PowerShell image is not a plain single-link file"); var imageBytes=new byte[imageLease.Length]; int read=0; while(read<imageBytes.Length) { int n=imageLease.Read(imageBytes,read,imageBytes.Length-read); if(n==0)throw new EndOfStreamException();read+=n; } string imageHash=Hash(imageBytes); result["image_sha256"]=imageHash;
   Check(CreateDirectoryW(root,IntPtr.Zero),"CreateDirectoryW exclusive probe root"); dir=CreateFileW(root,0,1|2|4,IntPtr.Zero,3,0x02000000|0x00200000,IntPtr.Zero); if(dir==new IntPtr(-1)) {dir=IntPtr.Zero;throw new Win32Exception(Marshal.GetLastWin32Error(),"Open owned probe root");} var rootInfo=FileFacts(dir); if((rootInfo.attributes&0x10)==0||Directory.GetFileSystemEntries(root).Length!=0)throw new InvalidOperationException("Owned empty directory refused"); result["evidence_root_id"]=FileId(rootInfo);
   string scriptPath=Path.Combine(root,"token-query.ps1"); using(var output=new FileStream(scriptPath,FileMode.CreateNew,FileAccess.Write,FileShare.None)) { var bytes=new UTF8Encoding(false,true).GetBytes(childScript); output.Write(bytes,0,bytes.Length); } scriptLease=OpenPlain(scriptPath); var scriptInfo=FileFacts(scriptLease.SafeFileHandle.DangerousGetHandle()); if(scriptInfo.links!=1||(scriptInfo.attributes&0x10)!=0)throw new InvalidOperationException("Token-query script is not plain single-link"); result["child_script_sha256"]=Hash(File.ReadAllBytes(scriptPath));
   job=CreateJobObjectW(IntPtr.Zero,null); Check(job!=IntPtr.Zero,"CreateJobObjectW"); var limits=new LIMIT(); limits.basic.flags=0x2000; Check(SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf<LIMIT>()),"SetInformationJobObject kill-on-close");
   var sorted=new List<string>(env.Keys); sorted.Sort(StringComparer.OrdinalIgnoreCase); var envText=new StringBuilder(); foreach(var key in sorted)envText.Append(key).Append('=').Append(env[key]).Append('\0'); envText.Append('\0'); environment=Marshal.StringToHGlobalUni(envText.ToString());
   var start=new SI{cb=(uint)Marshal.SizeOf<SI>(),desktop=DesktopName(GetProcessWindowStation())+"\\"+DesktopName(GetThreadDesktop(GetCurrentThreadId()))}; var command=new StringBuilder("\""+image+"\" -NoLogo -NoProfile -NonInteractive -File \""+scriptPath+"\"");
   Check(CreateProcessAsUserW(derived,image,command,IntPtr.Zero,IntPtr.Zero,false,0x00000404,environment,root,ref start,out pi),"CreateProcessAsUserW suspended"); result["created"]=true; result["child_pid"]=pi.pid;
   Check(AssignProcessToJobObject(job,pi.process),"AssignProcessToJobObject");assigned=true; bool member; Check(IsProcessInJob(pi.process,job,out member),"IsProcessInJob");if(!member)throw new InvalidOperationException("Owned Job membership refused");
   IntPtr childToken; Check(OpenProcessToken(pi.process,8,out childToken),"OpenProcessToken child"); TokenFacts child; try {child=Observe(childToken);}finally{CloseHandle(childToken);} Medium(child,caller);result["child_before_resume"]=child.Public();
   uint nameSize=32768; var name=new StringBuilder((int)nameSize);Check(QueryFullProcessImageNameW(pi.process,0,name,ref nameSize),"QueryFullProcessImageNameW");if(!String.Equals(Path.GetFullPath(name.ToString()),image,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Owned child image path refused"); if(FileId(FileFacts(imageLease.SafeFileHandle.DangerousGetHandle()))!=FileId(imageInfo)||Hash(File.ReadAllBytes(image))!=imageHash)throw new InvalidOperationException("Owned child image bytes changed"); long creation,exit,kernel,user;Check(GetProcessTimes(pi.process,out creation,out exit,out kernel,out user),"GetProcessTimes");result["child_creation_time"]=creation;
   uint count=ResumeThread(pi.thread);result["resume_previous_count"]=count;if(count!=1)throw new InvalidOperationException("ResumeThread count refused");result["resumed"]=true;
   if(WaitForSingleObject(pi.process,60000)!=0)throw new InvalidOperationException("Owned token-query child did not terminate");terminal=true;uint code;Check(GetExitCodeProcess(pi.process,out code),"GetExitCodeProcess");result["child_exit_code"]=code;if(code!=0)throw new InvalidOperationException("Token-query child failed");
   ACCOUNT account;Check(QueryInformationJobObject(job,1,out account,(uint)Marshal.SizeOf<ACCOUNT>(),IntPtr.Zero),"QueryInformationJobObject");result["job_active_processes"]=account.activeProcesses;if(account.activeProcesses!=0)throw new InvalidOperationException("Owned Job has live members");var currentDir=CreateFileW(root,0,1|2|4,IntPtr.Zero,3,0x02000000|0x00200000,IntPtr.Zero); if(currentDir==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error(),"Readback owned root"); try { if(FileId(FileFacts(dir))!=FileId(rootInfo)||FileId(FileFacts(currentDir))!=FileId(rootInfo))throw new InvalidOperationException("Owned root identity changed"); } finally {CloseHandle(currentDir);} if(Hash(File.ReadAllBytes(scriptPath))!=(string)result["child_script_sha256"]||FileId(FileFacts(scriptLease.SafeFileHandle.DangerousGetHandle()))!=FileId(scriptInfo))throw new InvalidOperationException("Token-query script changed");
   if(FileId(FileFacts(imageLease.SafeFileHandle.DangerousGetHandle()))!=FileId(imageInfo)||Hash(File.ReadAllBytes(image))!=imageHash)throw new InvalidOperationException("PowerShell image changed");result["outcome"]="child_terminal";
  } catch(Exception e) { result["outcome"]="failed";result["error_type"]=e.GetType().Name;result["error"]=e.Message; if(e is Win32Exception)result["winerror"]=((Win32Exception)e).NativeErrorCode; }
  finally {
   try {
    if(pi.process!=IntPtr.Zero) {
     bool live=!terminal;
     if(assigned) { ACCOUNT remaining; if(!QueryInformationJobObject(job,1,out remaining,(uint)Marshal.SizeOf<ACCOUNT>(),IntPtr.Zero))live=true; else live=live||remaining.activeProcesses!=0; }
     if(live) {
      bool stopped=assigned?TerminateJobObject(job,124):TerminateProcess(pi.process,124); result["owned_failure_stop"]=stopped; bool ended=WaitForSingleObject(pi.process,10000)==0; result["cleanup_terminal"]=ended;
      ACCOUNT remaining; bool jobEnded=!assigned||(QueryInformationJobObject(job,1,out remaining,(uint)Marshal.SizeOf<ACCOUNT>(),IntPtr.Zero)&&remaining.activeProcesses==0); result["cleanup_job_terminal"]=jobEnded;
      if(!stopped||!ended||!jobEnded)result["outcome"]="failed";
     }
    }
   } catch(Exception e) {result["outcome"]="failed";result["cleanup_error"]=e.GetType().Name+": "+e.Message;}
   foreach(var h in new[]{pi.thread,pi.process,job,derived,callerToken,dir})if(h!=IntPtr.Zero)CloseHandle(h);if(imageLease!=null)imageLease.Dispose();if(scriptLease!=null)scriptLease.Dispose();if(environment!=IntPtr.Zero)Marshal.FreeHGlobal(environment);
  }
  return result;
 }
}
'@
        Add-Type -TypeDefinition $actorCSharp
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($actorCSharp))
        $childScript = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__QUERY_SOURCE__'))
Add-Type -TypeDefinition $source
$facts = [WinsmuxDesktopActorProbe]::Query()
$bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(($facts | ConvertTo-Json -Depth 8 -Compress) + [char]10)
$file = [IO.FileStream]::new((Join-Path $PSScriptRoot 'child-result.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
'@
        $childScript = $childScript.Replace('__QUERY_SOURCE__', $encoded)
        $pwshImage = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ([IO.Path]::GetFileName($pwshImage) -ine 'pwsh.exe') { throw 'actor_probe_host_image_refused' }
        $actorResult = [WinsmuxDesktopActorProbe]::Probe($pwshImage, $actorRoot, $childScript)
        $actorResult['source_commit'] = $actualHead
        $actorResult['source_sha256'] = $actorSourceHash
        if ($actorResult['outcome'] -ceq 'child_terminal') {
            $child = [WinsmuxDesktopActorProbe]::ReadChild((Join-Path $actorRoot 'child-result.json')) | ConvertFrom-Json -AsHashtable
            if (@($child.Keys).Count -ne 4 -or -not $child.ContainsKey('facts') -or -not $child.ContainsKey('pid') -or -not $child.ContainsKey('existing_profile_hive') -or -not $child.ContainsKey('local_app_data_exists')) { throw 'actor_probe_child_receipt_shape_refused' }
            if ($child['pid'] -ne $actorResult['child_pid'] -or $child['existing_profile_hive'] -ne $true -or $child['local_app_data_exists'] -ne $true -or @($child['facts'].Keys).Count -ne 8) { throw 'actor_probe_child_profile_refused' }
            foreach ($key in $actorResult['child_before_resume'].Keys) { if (-not $child['facts'].ContainsKey($key) -or $child['facts'][$key] -cne $actorResult['child_before_resume'][$key]) { throw 'actor_probe_child_actor_changed' } }
            $actorResult['child_result'] = $child
            $actorResult['outcome'] = 'passed'
        }
        if ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $actorSourceHash) { throw 'actor_probe_source_changed' }
    } catch {
        $actorResult['outcome'] = 'failed'
        $actorResult['error'] = $_.Exception.Message
    }
    $actorResult | ConvertTo-Json -Depth 12 -Compress
    if ($actorResult['outcome'] -ceq 'passed') { exit 0 }
    exit 1
}


if ($PSBoundParameters.ContainsKey('DesktopNativeActorProbeOnly')) { throw 'actor_probe_mode_refused' }

$script:DesktopOwnerSourceRoot = $PSScriptRoot
$script:RetryCount = 6
$script:RetryDelaySeconds = 10
$script:DesktopObservationTimeoutMilliseconds = 180000
$script:DesktopObservationPollMilliseconds = 500
$script:DesktopTeardownProbeTimeoutMilliseconds = 5000
$script:DesktopTeardownProbeTotalBudgetMilliseconds = 20000
$script:DesktopOutputRetainLimitBytes = 16384
# The stdio adapter's MAX_MCP_MESSAGE_BYTES = 2 * MAX_MESSAGE_BYTES.
$script:DesktopMcpMessageLimitBytes = 2097152
$script:OwnedRootPrefix = 'winsmux-public-release-'
$script:DesktopLifecycle = $null
$script:DesktopRouterInventory = $null
$script:DesktopInstalledInventory = $null
$script:DesktopRuntimeReceipt = $null
$script:DesktopFailureStage = 'preflight'
$script:DesktopCleanupStage = 'not_started'
$script:DesktopFolderContextPath = 'Registry::HKEY_CURRENT_USER\Software\Classes\Directory\shell\winsmux'
$script:DesktopBackgroundContextPath = 'Registry::HKEY_CURRENT_USER\Software\Classes\Directory\Background\shell\winsmux'
$script:DesktopProductPath = 'Registry::HKEY_CURRENT_USER\Software\github\winsmux'
$script:DesktopUninstallPath = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\winsmux'
$script:DesktopSmokeEnvMarkerArgument = '--winsmux-smoke-env-marker'
$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'desktop-install-inventory.ps1')

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-DesktopNativeRequest {
    param(
        [Parameter(Mandatory)][string]$RequestedSurface,
        [Parameter(Mandatory)][string]$CandidateVersion,
        [Parameter(Mandatory)][string]$CandidateReleaseTag,
        [Parameter(Mandatory)][Collections.IDictionary]$Arguments,
        [string]$ActualHead,
        [string]$CallerHead
    )
    $enabled = $Arguments.ContainsKey('DesktopNativeLifecycle') -and [bool]$Arguments['DesktopNativeLifecycle']
    $nativeKeys = @('DesktopNativeFormat', 'DesktopNativeSourceCommit', 'DesktopNativeCandidateDirectory', 'DesktopNativeBaselineDirectory')
    if (-not $enabled) {
        foreach ($key in $nativeKeys) { Assert-Condition (-not $Arguments.ContainsKey($key)) 'desktop_native_mode_required' }
        return
    }
    Assert-Condition ($RequestedSurface -ceq 'Desktop' -and $CandidateVersion -ceq '0.38.0' -and $CandidateReleaseTag -ceq 'v0.38.0') 'desktop_native_identity_refused'
    foreach ($key in @('CandidateInstallerPath', 'DesktopInventoryPath', 'PriorInstallerPath', 'PriorVersion', 'DesktopLegacyEnvMode')) {
        Assert-Condition (-not $Arguments.ContainsKey($key)) 'desktop_native_mixed_mode_refused'
    }
    if ($Arguments.ContainsKey('SelfTest') -and [bool]$Arguments['SelfTest']) {
        foreach ($key in $nativeKeys) { Assert-Condition (-not $Arguments.ContainsKey($key)) 'desktop_native_selftest_input_refused' }
        return
    }
    foreach ($key in $nativeKeys) { Assert-Condition ($Arguments.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$Arguments[$key])) 'desktop_native_input_missing' }
    Assert-Condition ([string]$Arguments['DesktopNativeFormat'] -cin @('MSI', 'NSIS')) 'desktop_native_format_refused'
    $source = [string]$Arguments['DesktopNativeSourceCommit']
    Assert-Condition ($source -cmatch '^[a-f0-9]{40}$' -and $source -ceq $ActualHead -and $source -ceq $CallerHead) 'desktop_native_source_refused'
    # Physical artifact admission and every case root are checked by the finite mode before any installer starts.
}

function Assert-DesktopInstallerRequest {
    param(
        [Parameter(Mandatory)][string]$RequestedSurface,
        [Parameter(Mandatory)][string]$CandidateVersion,
        [Parameter(Mandatory)][Collections.IDictionary]$Arguments
    )

    $candidateSpecified = $Arguments.ContainsKey('CandidateInstallerPath') -and
        -not [string]::IsNullOrEmpty([string]$Arguments['CandidateInstallerPath'])
    if ($candidateSpecified) {
        $candidatePath = [string]$Arguments['CandidateInstallerPath']
        Assert-Condition ($RequestedSurface -eq 'Desktop') 'CandidateInstallerPath requires -Surface Desktop; it is only valid for the Desktop surface.'
        Assert-Condition (Test-Path -LiteralPath $candidatePath -PathType Leaf) "Candidate installer path does not exist: $candidatePath"
    }

    $priorInstallerSpecified = $Arguments.ContainsKey('PriorInstallerPath')
    $priorVersionSpecified = $Arguments.ContainsKey('PriorVersion')
    if (-not $priorInstallerSpecified -and -not $priorVersionSpecified) {
        return
    }

    Assert-Condition ($RequestedSurface -eq 'Desktop') 'PriorInstallerPath and PriorVersion require -Surface Desktop; they are only valid for the Desktop surface.'
    Assert-Condition ($priorInstallerSpecified -and $priorVersionSpecified) 'PriorInstallerPath and PriorVersion must be supplied together.'
    Assert-Condition $candidateSpecified 'PriorInstallerPath and PriorVersion require CandidateInstallerPath.'

    $priorPath = [string]$Arguments['PriorInstallerPath']
    $requestedPriorVersion = [string]$Arguments['PriorVersion']
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($priorPath)) 'PriorInstallerPath must not be empty.'
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($requestedPriorVersion)) 'PriorVersion must not be empty.'
    Assert-Condition (Test-Path -LiteralPath $priorPath -PathType Leaf) "Prior installer path does not exist: $priorPath"
    Assert-Condition (-not [string]::Equals($requestedPriorVersion, $CandidateVersion, [StringComparison]::Ordinal)) "PriorVersion '$requestedPriorVersion' must not equal candidate Version '$CandidateVersion'."
}
if ($DesktopNativeLifecycle) {
    $nativeHead = if ($SelfTest) { '' } else { (& git -C $script:RepositoryRoot rev-parse --verify HEAD | Out-String).Trim() }
    if (-not $SelfTest) { Assert-Condition ($LASTEXITCODE -eq 0) 'desktop_native_source_unavailable' }
    Assert-DesktopNativeRequest -RequestedSurface $Surface -CandidateVersion $Version -CandidateReleaseTag $ReleaseTag -Arguments $PSBoundParameters -ActualHead $nativeHead -CallerHead ([string]$env:GITHUB_SHA)
} else {
    Assert-DesktopNativeRequest -RequestedSurface $Surface -CandidateVersion $Version -CandidateReleaseTag $ReleaseTag -Arguments $PSBoundParameters
    Assert-DesktopInstallerRequest -RequestedSurface $Surface -CandidateVersion $Version -Arguments $PSBoundParameters
}
if ($PSBoundParameters.ContainsKey('DesktopLegacyEnvMode')) {
    Assert-Condition ($Surface -eq 'Desktop') 'DesktopLegacyEnvMode requires -Surface Desktop; it is only valid for the Desktop surface.'
}
if ($PSBoundParameters.ContainsKey('DesktopInventoryPath')) {
    Assert-Condition ($Surface -ceq 'Desktop') 'DesktopInventoryPath requires -Surface Desktop.'
    Assert-Condition (-not [string]::IsNullOrEmpty($CandidateInstallerPath) -and (Test-Path -LiteralPath $DesktopInventoryPath -PathType Leaf)) 'DesktopInventoryPath requires an existing candidate installer and inventory pair.'
}

function Get-DesktopLegacyBrowserArgumentsValue {
    param(
        [Parameter(Mandatory)][ValidateSet('PortAndMarker', 'MarkerOnly')][string]$Mode,
        [Parameter(Mandatory)][string]$DebugArgument
    )

    if ($Mode -ceq 'MarkerOnly') {
        return $script:DesktopSmokeEnvMarkerArgument
    }
    return ('{0} {1}' -f $DebugArgument, $script:DesktopSmokeEnvMarkerArgument)
}

function Get-CoreReleaseAssetNames {
    return @(
        'winsmux-x64.exe'
        'winsmux-arm64.exe'
        'winsmux-remote-helper-linux-x64'
    )
}

function Get-GitBlobSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Treeish,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $process = $null
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $gitCommand = Get-Command git -CommandType Application -TotalCount 1 -ErrorAction Stop
        $gitPath = [string]$gitCommand.Source
        $startInfo.FileName = $gitPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @('-C', $script:RepositoryRoot, 'cat-file', 'blob', "${Treeish}:$RelativePath")) {
            $startInfo.ArgumentList.Add($argument)
        }

        $process = [Diagnostics.Process]::Start($startInfo)
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha256.ComputeHash($process.StandardOutput.BaseStream)
        } finally {
            $sha256.Dispose()
        }
        $process.WaitForExit()
        [void]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git cat-file failed for ${Treeish}:$RelativePath with exit $($process.ExitCode)."
        }
        return [Convert]::ToHexString($hash).ToLowerInvariant()
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Resolve-DesktopRouterInventoryPolicy {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$ReleaseTag,
        [AllowEmptyString()][string]$CandidateInstallerPath
    )

    if ($Version -ceq '0.38.0' -and $ReleaseTag -ceq 'v0.38.0') {
        return [pscustomobject]@{ generation = 'workspace'; required = $false; treeish = $null }
    }
    Assert-Condition ([string]::IsNullOrEmpty($CandidateInstallerPath)) 'desktop_legacy_candidate_unsupported'
    if ($Version -ceq '0.36.38' -and $ReleaseTag -ceq 'v0.36.38') {
        return [pscustomobject]@{ generation = 'legacy_router'; required = $true; treeish = $ReleaseTag }
    }
    $legacyVersions = @('0.36.0','0.36.1','0.36.2','0.36.3','0.36.4','0.36.5','0.36.6','0.36.7','0.36.8','0.36.9','0.36.10','0.36.13','0.36.14','0.36.15','0.36.16','0.36.17','0.36.18','0.36.19','0.36.20','0.36.21','0.36.22','0.36.23','0.36.24','0.36.25','0.36.26','0.36.27','0.36.28','0.36.29','0.36.30','0.36.31','0.36.32','0.36.33','0.36.34','0.36.35','0.36.36','0.36.37')
    if ($Version -cin $legacyVersions -and ($ReleaseTag -ceq "v$Version" -or ($Version -cin @('0.36.28','0.36.30') -and $ReleaseTag -ceq "v$Version.1"))) {
        return [pscustomobject]@{ generation = 'legacy_pre_router'; required = $false; treeish = $null }
    }
    throw 'desktop_distribution_generation_unknown'
}

function Get-DesktopRouterInventory {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$Treeish
    )

    $relativePaths = @(
        'winsmux-core/scripts/coordinator-router.ps1',
        'winsmux-core/scripts/local-router-shadow.ps1',
        'winsmux-core/router/local-small-router-v03621.manifest.json',
        'winsmux-core/router/local-small-router-v03621.weights.json'
    )
    foreach ($relativePath in $relativePaths) {
        $installedPath = Join-Path $InstallRoot $relativePath
        Assert-Condition (Test-Path -LiteralPath $installedPath -PathType Leaf) "Candidate Desktop installer omitted router artifact: $relativePath"
        $sourceHash = Get-GitBlobSha256 -Treeish $Treeish -RelativePath $relativePath
        $installedHash = (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-Condition ($installedHash -ceq $sourceHash) "Candidate Desktop router artifact hash mismatch: $relativePath expected=$sourceHash actual=$installedHash"
    }

    $installedShadowPath = Join-Path $InstallRoot 'winsmux-core/scripts/local-router-shadow.ps1'
    $resolvedInstalledRouter = & {
        param([Parameter(Mandatory)][string]$ShadowPath)
        . $ShadowPath
        Resolve-WinsmuxLocalRouterArtifact
    } $installedShadowPath
    $expectedManifestPath = Join-Path $InstallRoot 'winsmux-core/router/local-small-router-v03621.manifest.json'
    $expectedWeightsPath = Join-Path $InstallRoot 'winsmux-core/router/local-small-router-v03621.weights.json'
    Assert-Condition (
        [string]::Equals([IO.Path]::GetFullPath([string]$resolvedInstalledRouter.manifest_path), [IO.Path]::GetFullPath($expectedManifestPath), [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([IO.Path]::GetFullPath([string]$resolvedInstalledRouter.weights_path), [IO.Path]::GetFullPath($expectedWeightsPath), [StringComparison]::OrdinalIgnoreCase)
    ) 'Candidate Desktop default local-router manifest did not resolve to its installed sibling artifacts.'

    return [ordered]@{
        found = $relativePaths.Count
        expected = $relativePaths.Count
        sha256_match = $relativePaths.Count
        manifest_resolvable = $true
    }
}

function Resolve-ReleaseCoordinates {
    param(
        [Parameter(Mandatory)][string]$Surface,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$ReleaseTag,
        [Parameter(Mandatory)][string]$Repository
    )

    $tagMatch = [regex]::Match($ReleaseTag, '^v(?<binary>\d+\.\d+\.\d+)(?:\.(?<revision>\d+))?(?<suffix>-[0-9A-Za-z.-]+)?$')
    Assert-Condition $tagMatch.Success "Unsupported release tag: $ReleaseTag"
    Assert-Condition ($Repository -match '^[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?$') "Unsupported repository coordinate: $Repository"

    $binaryVersion = $tagMatch.Groups['binary'].Value
    $revision = $tagMatch.Groups['revision'].Value
    $suffix = $tagMatch.Groups['suffix'].Value
    if ($Surface -in @('Core', 'Desktop')) {
        $workflowVersion = $ReleaseTag.Substring(1)
        Assert-Condition ($Version -ceq $workflowVersion) "Release tag '$ReleaseTag' does not exactly match workflow version '$Version'."
        return "$binaryVersion$suffix"
    }

    if ([string]::IsNullOrEmpty($revision) -and $suffix -cmatch '^-pkgfix(?:\.|$)') {
        throw "Reserved npm packaging-hotfix tag namespace: $ReleaseTag"
    }
    $packageVersion = if ([string]::IsNullOrEmpty($revision)) {
        "$binaryVersion$suffix"
    } elseif ([string]::IsNullOrEmpty($suffix)) {
        "$binaryVersion-pkgfix.$revision"
    } else {
        "$binaryVersion-pkgfix.$revision.$($suffix.Substring(1))"
    }
    Assert-Condition ($Version -ceq $packageVersion) "Release tag '$ReleaseTag' does not exactly match staged npm version '$Version'."
    return $packageVersion
}

function Get-CanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathInsideRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $fullPath = Get-CanonicalPath -Path $Path
    $fullRoot = (Get-CanonicalPath -Path $Root).TrimEnd('\') + '\'
    return $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
}

function New-PublicIsolatedProfile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('Core', 'Desktop', 'Npm')][string]$Surface
    )

    Assert-Condition ([IO.Path]::IsPathFullyQualified($Root) -and (Test-Path -LiteralPath $Root -PathType Container)) 'isolated_profile_root_invalid'
    $ownedRoot = Get-CanonicalPath -Path $Root
    switch ($Surface) {
        'Core' { $profileRoot = Join-Path $ownedRoot 'core-profile'; $homeRoot = Join-Path $profileRoot 'Home'; $tempRoot = Join-Path $profileRoot 'Temp' }
        'Desktop' { $profileRoot = Join-Path $ownedRoot 'profile'; $homeRoot = Join-Path $profileRoot 'Home'; $tempRoot = Join-Path $profileRoot 'Temp' }
        'Npm' { $homeRoot = Join-Path $ownedRoot 'npm-home'; $tempRoot = Join-Path $ownedRoot 'npm-temp' }
    }
    # Native flags0 resolves %USERPROFILE%\AppData\Local and requires it to exist.
    $environment = @{
        LOCALAPPDATA = Get-CanonicalPath -Path (Join-Path $homeRoot 'AppData\Local')
        APPDATA = Get-CanonicalPath -Path (Join-Path $homeRoot 'AppData\Roaming')
        TEMP = Get-CanonicalPath -Path $tempRoot
        TMP = Get-CanonicalPath -Path $tempRoot
        USERPROFILE = Get-CanonicalPath -Path $homeRoot
        HOME = Get-CanonicalPath -Path $homeRoot
    }
    $directories = @($environment.HOME, $environment.TEMP, $environment.LOCALAPPDATA, $environment.APPDATA)
    foreach ($directory in $directories) {
        Assert-Condition (Test-PathInsideRoot -Path $directory -Root $ownedRoot) 'isolated_profile_path_outside_root'
    }
    New-Item -ItemType Directory -Path $directories -ErrorAction Stop | Out-Null
    return $environment
}

function New-OwnedRoot {
    $base = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        $env:RUNNER_TEMP
    } else {
        [System.IO.Path]::GetTempPath()
    }
    $base = Get-CanonicalPath -Path $base
    Assert-Condition (Test-Path -LiteralPath $base -PathType Container) "Temporary base does not exist: $base"

    $root = Join-Path $base "$($script:OwnedRootPrefix)$([guid]::NewGuid().ToString('N'))"
    Assert-Condition (Test-PathInsideRoot -Path $root -Root $base) "Owned root escaped its temporary base: $root"
    New-Item -ItemType Directory -Path $root | Out-Null
    return (Get-CanonicalPath -Path $root)
}

function Remove-OwnedRoot {
    param([Parameter(Mandatory)][string]$Root)

    $fullRoot = Get-CanonicalPath -Path $Root
    $leaf = Split-Path -Leaf $fullRoot
    Assert-Condition ($leaf.StartsWith($script:OwnedRootPrefix, [StringComparison]::Ordinal)) "Refusing to remove an unowned root: $fullRoot"

    if (-not (Test-Path -LiteralPath $fullRoot)) {
        return
    }
    $item = Get-Item -LiteralPath $fullRoot -Force
    Assert-Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Refusing to remove a reparse-point root: $fullRoot"
    Remove-Item -LiteralPath $fullRoot -Recurse -Force
    Assert-Condition (-not (Test-Path -LiteralPath $fullRoot)) "Owned temporary root remained after cleanup: $fullRoot"
}

function Invoke-Retry {
    param(
        [Parameter(Mandatory)][scriptblock]$Operation,
        [string]$Description = 'operation'
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $script:RetryCount; $attempt += 1) {
        try {
            return (& $Operation)
        } catch {
            $lastError = $_
            if ($attempt -lt $script:RetryCount) {
                Start-Sleep -Seconds $script:RetryDelaySeconds
            }
        }
    }
    throw "$Description failed after $($script:RetryCount) attempts: $($lastError.Exception.Message)"
}

function Get-ChildOutputMetadata {
    param([AllowNull()][string]$Content)

    $value = if ($null -eq $Content) { '' } else { [string]$Content }
    $encoding = [Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes($value)
    $retainedLength = [Math]::Min($bytes.Length, 16384)
    $retained = if ($retainedLength -eq 0) {
        ''
    } else {
        $encoding.GetString($bytes, 0, $retainedLength)
    }
    return [pscustomobject]@{
        present = $bytes.Length -gt 0
        bytes = $bytes.Length
        truncated = $bytes.Length -gt 16384
        retained = $retained
    }
}

function Format-PublicChildProcessDiagnostic {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('core_version', 'npm_view', 'npm_pack', 'tar_list', 'tar_extract', 'npm_help', 'desktop_installer', 'desktop_observer', 'desktop_uninstaller')]
        [string]$Operation,
        [Parameter(Mandatory)]
        [ValidateSet(
            'timed_out',
            'exit_nonzero',
            'stderr_nonempty',
            'parse_failed',
            'content_invalid',
            'exited',
            'live_no_cdp',
            'live_cdp_user_data_reparse',
            'live_cdp_port_file_missing',
            'live_cdp_port_file_reparse',
            'live_cdp_port_file_invalid_encoding',
            'live_cdp_port_file_invalid_shape',
            'live_cdp_port_invalid',
            'live_cdp_browser_path_invalid',
            'live_cdp_listener_missing',
            'live_cdp_listener_ambiguous',
            'live_cdp_listener_foreign',
            'live_cdp_browser_identity_invalid',
            'live_cdp_version_identity_mismatch',
            'live_cdp_transport_unavailable',
            'live_cdp_http_error',
            'live_cdp_payload_invalid',
            'live_cdp_page_absent',
            'live_cdp_url_rejected'
        )]
        [string]$State,
        [AllowNull()]$Result
    )

    $exitCode = 'none'
    $stdout = ''
    $stderr = ''
    $stdoutMetadata = $null
    $stderrMetadata = $null
    if ($null -ne $Result) {
        $resultExitCode = Get-ObjectPropertyValue -Object $Result -Name 'exit_code'
        if ($null -ne $resultExitCode) {
            $exitCode = [string][int]$resultExitCode
        }
        $stdoutValue = Get-ObjectPropertyValue -Object $Result -Name 'stdout'
        $stderrValue = Get-ObjectPropertyValue -Object $Result -Name 'stderr'
        if ($null -ne $stdoutValue) { $stdout = [string]$stdoutValue }
        if ($null -ne $stderrValue) { $stderr = [string]$stderrValue }
        $stdoutMetadata = Get-ObjectPropertyValue -Object $Result -Name 'stdout_metadata'
        $stderrMetadata = Get-ObjectPropertyValue -Object $Result -Name 'stderr_metadata'
    }
    if ($null -eq $stdoutMetadata) { $stdoutMetadata = Get-ChildOutputMetadata -Content $stdout }
    if ($null -eq $stderrMetadata) { $stderrMetadata = Get-ChildOutputMetadata -Content $stderr }
    return 'child_process_failure operation={0} state={1} exit_code={2} stdout_present={3} stdout_bytes={4} stdout_truncated={5} stderr_present={6} stderr_bytes={7} stderr_truncated={8}' -f @(
        $Operation,
        $State,
        $exitCode,
        ([string]$stdoutMetadata.present).ToLowerInvariant(),
        $stdoutMetadata.bytes,
        ([string]$stdoutMetadata.truncated).ToLowerInvariant(),
        ([string]$stderrMetadata.present).ToLowerInvariant(),
        $stderrMetadata.bytes,
        ([string]$stderrMetadata.truncated).ToLowerInvariant()
    )
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 60
    )

    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FilePath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in @($ArgumentList)) {
        $info.ArgumentList.Add([string]$argument)
    }
    foreach ($name in @($Environment.Keys)) {
        $info.Environment[[string]$name] = [string]$Environment[$name]
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    Assert-Condition $process.Start() "Unable to start process: $FilePath"
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        try {
            $process.Refresh()
            if (-not $process.HasExited) {
                $process.Kill($true)
            }
            if (-not $process.WaitForExit(15000)) {
                throw [TimeoutException]::new('Timed-out child process did not become terminal after termination.')
            }
        } catch {
            throw [InvalidOperationException]::new('Unable to terminate a timed-out child process.', $_.Exception)
        }
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $result = [pscustomobject]@{
        exit_code = if ($timedOut) { $null } else { [int]$process.ExitCode }
        stdout = $stdout
        stderr = $stderr
    }
    if ($timedOut) {
        $failure = [TimeoutException]::new('Child process exceeded the allowed timeout.')
        $failure.Data['process_result'] = $result
        throw $failure
    }
    return $result
}

function Invoke-PublicChildProcess {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('core_version', 'npm_view', 'npm_pack', 'tar_list', 'tar_extract', 'npm_help', 'desktop_installer', 'desktop_observer', 'desktop_uninstaller')]
        [string]$Operation,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 60
    )

    try {
        if ($Operation -cin @('desktop_installer', 'desktop_observer', 'desktop_uninstaller')) {
            return Invoke-DesktopOwnedNativeProcess -FilePath $FilePath -ArgumentList $ArgumentList -Environment $Environment -TimeoutSeconds $TimeoutSeconds
        }
        return Invoke-NativeProcess -FilePath $FilePath -ArgumentList $ArgumentList -Environment $Environment -TimeoutSeconds $TimeoutSeconds
    } catch [TimeoutException] {
        $result = $_.Exception.Data['process_result']
        $message = if ($null -eq $result) { 'Timed-out child process did not provide a terminal output capture.' }
            else { Format-PublicChildProcessDiagnostic -Operation $Operation -State 'timed_out' -Result $result }
        $failure = [InvalidOperationException]::new($message, $_.Exception)
        foreach ($key in $_.Exception.Data.Keys) { $failure.Data[$key] = $_.Exception.Data[$key] }
        throw $failure
    }
}

function Get-DesktopFailureEvidence {
    param([AllowNull()]$Failure)
    $queue = [Collections.Generic.Queue[Exception]]::new()
    $seen = [Collections.Generic.List[Exception]]::new()
    if ($Failure -is [Management.Automation.ErrorRecord]) { $Failure = $Failure.Exception }
    if ($Failure -is [Exception]) { $queue.Enqueue($Failure) }
    $present = [ordered]@{ operation_failure = $false; cleanup_failure = $false; native_result = $false; observation = $false; native_observation = $false }
    $evidence = [ordered]@{ reason_code = $(if ($null -eq $Failure) { 'none' } else { 'desktop_operation_failed' }); operation_failure = $null; cleanup_failure = $null; native_result = $null; observation = $null; native_observation = $null; present = $present }
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $alreadySeen = $false
        foreach ($visited in $seen) { if ([object]::ReferenceEquals($visited, $current)) { $alreadySeen = $true; break } }
        if ($alreadySeen) { continue }
        $seen.Add($current)
        if ($evidence.reason_code -ceq 'desktop_operation_failed' -and $current.Message -cmatch '^desktop_[a-z_]+$') { $evidence.reason_code = $current.Message }
        foreach ($key in @('operation_failure', 'cleanup_failure', 'native_result', 'observation', 'native_observation')) {
            if (-not $present[$key] -and $current.Data.Contains($key)) { $evidence[$key] = $current.Data[$key]; $present[$key] = $true }
        }
        if (-not $present.native_result -and $current.Data.Contains('process_result')) { $evidence.native_result = $current.Data['process_result']; $present.native_result = $true }
        foreach ($key in @('operation_failure', 'cleanup_failure', 'original_exception')) {
            if ($current.Data.Contains($key) -and $current.Data[$key] -is [Exception]) { $queue.Enqueue($current.Data[$key]) }
        }
        if ($null -ne $current.InnerException) { $queue.Enqueue($current.InnerException) }
        if ($current -is [AggregateException]) { foreach ($inner in $current.InnerExceptions) { $queue.Enqueue($inner) } }
    }
    return [pscustomobject]$evidence
}

function Get-DesktopOwnedProcessObservation {
    param($OwnedProcess)
    $observation = [ordered]@{ root_exited = $null; root_exit_code = $null; active_members = $null; stdout_state = 'unknown'; stderr_state = 'unknown'; forced = $null }
    if ($null -eq $OwnedProcess -or $null -eq (Get-ObjectPropertyValue $OwnedProcess 'owner')) { return [pscustomobject]$observation }
    try {
        if ($null -eq $OwnedProcess.owner.PSObject.Properties['HasExited']) { throw 'unobserved' }
        $observation.root_exited = [bool]$OwnedProcess.owner.HasExited
        if ($observation.root_exited) { $observation.root_exit_code = [int]$OwnedProcess.owner.ExitCode }
    } catch { }
    try { if ($null -ne $OwnedProcess.owner.PSObject.Properties['ActiveMembers']) { $observation.active_members = [long]$OwnedProcess.owner.ActiveMembers } } catch { }
    try { if ($null -ne $OwnedProcess.owner.PSObject.Properties['Forced']) { $observation.forced = [bool]$OwnedProcess.owner.Forced } } catch { }
    foreach ($stream in @('stdout', 'stderr')) {
        try {
            $task = $OwnedProcess.owner.($stream.Substring(0,1).ToUpperInvariant() + $stream.Substring(1) + 'Task')
            if ($null -ne $task) {
                $observation[$stream + '_state'] = if (-not $task.IsCompleted) { 'pending' } elseif ($task.IsFaulted -or $task.IsCanceled) { 'failed' } else { 'eof' }
            }
        } catch { }
    }
    return [pscustomobject]$observation
}

function New-DesktopFailureReceipt {
    param($Failure, $CleanupFailure, [string]$Version, [string]$ReleaseTag, [string]$Stage, [string]$CleanupStage, [string]$Phase)
    $primaryFailure = if ($null -ne $Failure) { $Failure } else { $CleanupFailure }
    $evidence = Get-DesktopFailureEvidence $primaryFailure
    $originalOperation = if ($evidence.present.operation_failure) { $evidence.operation_failure } else { $Failure }
    $originalCleanup = if ($evidence.present.cleanup_failure) { $evidence.cleanup_failure } else { $CleanupFailure }
    $operation = Get-DesktopFailureEvidence $originalOperation
    $cleanup = Get-DesktopFailureEvidence $originalCleanup
    $nativeResult = if ($evidence.present.native_result) { $evidence.native_result } else { $cleanup.native_result }
    $failedObservation = if ($evidence.present.observation) { $evidence.observation } else { $cleanup.observation }
    $nativeObservation = if ($evidence.present.native_observation) { $evidence.native_observation } else { $cleanup.native_observation }
    if (-not $evidence.present.native_observation -and -not $cleanup.present.native_observation -and $null -ne $nativeResult) { $nativeObservation = Get-ObjectPropertyValue $nativeResult 'native_observation' }
    if ($null -eq $nativeObservation) { $nativeObservation = Get-DesktopOwnedProcessObservation $null }
    $projectedObservation = Get-DesktopOwnedProcessObservation $null
    foreach ($key in @('root_exited', 'forced', 'root_exit_code', 'active_members', 'stdout_state', 'stderr_state')) {
        try {
            $value = Get-ObjectPropertyValue $nativeObservation $key
            if ($key -cin @('root_exited', 'forced') -and $value -is [bool]) { $projectedObservation.$key = $value }
            elseif ($key -cin @('root_exit_code', 'active_members') -and ($value -is [int] -or $value -is [long]) -and ($key -cne 'active_members' -or $value -ge 0)) { $projectedObservation.$key = $value }
            elseif ($key -cin @('stdout_state', 'stderr_state') -and $value -is [string] -and $value -cin @('unknown', 'pending', 'failed', 'eof')) { $projectedObservation.$key = $value }
        } catch { }
    }
    $nativeObservation = $projectedObservation
    $nativeExit = if ($null -ne $nativeResult) { Get-ObjectPropertyValue $nativeResult 'exit_code' } elseif ($null -ne $failedObservation) { Get-ObjectPropertyValue $failedObservation 'exit_code' } else { $null }
    $stdoutMetadata = if ($null -ne $nativeResult) { Get-ObjectPropertyValue $nativeResult 'stdout_metadata' } else { $null }
    $stderrMetadata = if ($null -ne $nativeResult) { Get-ObjectPropertyValue $nativeResult 'stderr_metadata' } else { $null }
    $stdoutBytes = if ($null -ne $stdoutMetadata) { Get-ObjectPropertyValue $stdoutMetadata 'bytes' } elseif ($null -ne $failedObservation) { Get-ObjectPropertyValue $failedObservation 'stdout_bytes' } else { $null }
    $stderrBytes = if ($null -ne $stderrMetadata) { Get-ObjectPropertyValue $stderrMetadata 'bytes' } elseif ($null -ne $failedObservation) { Get-ObjectPropertyValue $failedObservation 'stderr_bytes' } else { $null }
    $state = if ($null -ne $failedObservation) { [string](Get-ObjectPropertyValue $failedObservation 'state') } else { 'unconfirmed' }
    return [ordered]@{ schema = 'winsmux-desktop-smoke-failure/v1'; ok = $false; surface = 'Desktop'; version = $Version; release_tag = $ReleaseTag; stage = $Stage; reason_code = $evidence.reason_code; helper_exit_code = 1; native_exit_code = $nativeExit; stdout_bytes = $stdoutBytes; stderr_bytes = $stderrBytes; observation_state = $state; native_observation = $nativeObservation; operation_failure = $operation.reason_code; cleanup_failure = $cleanup.reason_code; cleanup_stage = $CleanupStage; cleanup = $Phase }
}

function Initialize-DesktopNativeTypes {
    if ($null -eq ([Management.Automation.PSTypeName]'Winsmux.DesktopNative.DesktopProcessOwner').Type) {
        Add-Type -Path (Join-Path $script:DesktopOwnerSourceRoot 'DesktopProcessOwner.cs') -ErrorAction Stop
    }
    if ($null -ne ([Management.Automation.PSTypeName]'Winsmux.PublicRelease.BoundedStreamCapture').Type) {
        return
    }

    $source = @'
using System;
using System.ComponentModel;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace Winsmux.PublicRelease
{
    public sealed class BoundedCaptureResult
    {
        public BoundedCaptureResult(long totalBytes, byte[] retainedBytes)
        {
            TotalBytes = totalBytes;
            RetainedBytes = retainedBytes ?? Array.Empty<byte>();
        }

        public long TotalBytes { get; }
        public byte[] RetainedBytes { get; }
        public bool Truncated => TotalBytes > RetainedBytes.LongLength;
    }

    public static class BoundedStreamCapture
    {
        public static async Task<string> ReadLineAsync(TextReader reader, int limit)
        {
            var text = new StringBuilder(); var one = new char[1];
            while (true)
            {
                int count = await reader.ReadAsync(one, 0, 1).ConfigureAwait(false);
                if (count == 0) return text.Length == 0 ? null : text.ToString();
                if (one[0] == '\n') return text.ToString();
                if (text.Length >= limit) throw new InvalidDataException("desktop_mcp_response_oversized");
                text.Append(one[0]);
            }
        }

        public static async Task<long> DrainTextAsync(TextReader reader)
        {
            var buffer = new char[4096]; long total = 0;
            while (true)
            {
                int count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                if (count == 0) return total;
                total = checked(total + count);
            }
        }

        public static Task<BoundedCaptureResult> ReadAsync(Stream stream, int retainLimit)
        {
            if (stream == null) throw new ArgumentNullException(nameof(stream));
            if (retainLimit < 0) throw new ArgumentOutOfRangeException(nameof(retainLimit));
            return ReadCoreAsync(stream, retainLimit);
        }

        private static async Task<BoundedCaptureResult> ReadCoreAsync(Stream stream, int retainLimit)
        {
            byte[] buffer = new byte[4096];
            using (var retained = new MemoryStream(retainLimit))
            {
                long total = 0;
                while (true)
                {
                    int read = await stream.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                    if (read == 0) break;
                    total = checked(total + read);
                    int remaining = retainLimit - checked((int)retained.Length);
                    int keep = Math.Min(read, Math.Max(remaining, 0));
                    if (keep > 0) retained.Write(buffer, 0, keep);
                }
                return new BoundedCaptureResult(total, retained.ToArray());
            }
        }
    }

    public static class WindowsCommandLine
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CommandLineToArgvW(string commandLine, out int argumentCount);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        public static string[] Parse(string commandLine)
        {
            if (string.IsNullOrWhiteSpace(commandLine)) return Array.Empty<string>();
            int count;
            IntPtr values = CommandLineToArgvW(commandLine, out count);
            if (values == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                var result = new string[count];
                for (int index = 0; index < count; index++)
                {
                    IntPtr value = Marshal.ReadIntPtr(values, index * IntPtr.Size);
                    result[index] = Marshal.PtrToStringUni(value) ?? string.Empty;
                }
                return result;
            }
            finally
            {
                LocalFree(values);
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function Start-OwnedProcess {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [hashtable]$Environment = @{}, [switch]$Interactive)
    Initialize-DesktopNativeTypes
    $owner = [Winsmux.DesktopNative.DesktopProcessOwner]::Start($FilePath, [string[]]$ArgumentList, $Environment, [bool]$Interactive, $script:DesktopOutputRetainLimitBytes, $script:DesktopObservationTimeoutMilliseconds)
    return [pscustomobject]@{ process = $owner; owner = $owner; stdout_task = $owner.StdoutTask; stderr_task = $owner.StderrTask }
}

function Invoke-DesktopOwnedNativeProcess {
    param([string]$FilePath, [string[]]$ArgumentList, [hashtable]$Environment, [int]$TimeoutSeconds, [switch]$NsisJourney)
    if ($NsisJourney) { [void](Get-DesktopNativeNsisJourneyRemainingMilliseconds) }
    $owned = Start-OwnedProcess -FilePath $FilePath -ArgumentList $ArgumentList -Environment $Environment
    return Wait-DesktopOwnedNativeProcess -Owned $owned -TimeoutSeconds $TimeoutSeconds -NsisJourney:$NsisJourney
}

function Invoke-DesktopNsisProcess {
    param(
        [Parameter(Mandatory)][ValidateSet('desktop_installer', 'desktop_uninstaller')][string]$Operation,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)]$Context,
        [hashtable]$Environment = @{},
        [scriptblock]$ProcessInvoker
    )

    Initialize-DesktopNativeTypes
    $runRoot = [string]$script:DesktopRunOwnedRoot
    Assert-Condition ([IO.Path]::IsPathFullyQualified($runRoot)) 'desktop_nsis_run_root_invalid'
    $runRoot = Get-CanonicalPath -Path $runRoot
    $installRoot = Join-Path $runRoot 'installed'
    Assert-DesktopInstallRootOwnership -InstallRoot $installRoot
    Assert-Condition (Test-CanonicalPathEqual -ActualPath ([string]$Context.owned_root) -ExpectedPath $runRoot) 'desktop_nsis_owned_root_mismatch'
    Assert-Condition (Test-CanonicalPathEqual -ActualPath ([string]$Context.install_root) -ExpectedPath $installRoot) 'desktop_nsis_install_root_mismatch'
    # Validate the exact NSIS tail even when a SelfTest invoker replaces native execution.
    Assert-Condition ([IO.Path]::IsPathFullyQualified([string]$Context.owned_root) -and [IO.Path]::IsPathFullyQualified([string]$Context.install_root)) 'desktop_nsis_context_root_invalid'
    Assert-Condition ([string]$Context.install_root -ceq $installRoot) 'desktop_nsis_install_root_not_canonical'
    Assert-Condition ($installRoot -notmatch '[\x00-\x1f\x7f-\x9f"]| _\?=') 'desktop_nsis_install_root_invalid'
    if ($null -ne $ProcessInvoker) {
        $arguments = if ($Operation -ceq 'desktop_installer') { @('/S', "/D=$installRoot") } else { @('/S', "_?=$installRoot") }
        return (& $ProcessInvoker $FilePath $arguments $Environment)
    }
    $owner = if ($Operation -ceq 'desktop_installer') {
        [Winsmux.DesktopNative.DesktopProcessOwner]::StartNsisInstaller($FilePath, $installRoot, $Environment, $script:DesktopOutputRetainLimitBytes, $script:DesktopObservationTimeoutMilliseconds)
    } else {
        [Winsmux.DesktopNative.DesktopProcessOwner]::StartNsisUninstaller($FilePath, $installRoot, $Environment, $script:DesktopOutputRetainLimitBytes, $script:DesktopObservationTimeoutMilliseconds)
    }
    $owned = [pscustomobject]@{ process = $owner; owner = $owner; stdout_task = $owner.StdoutTask; stderr_task = $owner.StderrTask }
    try { return Wait-DesktopOwnedNativeProcess -Owned $owned -TimeoutSeconds 180 }
    catch [TimeoutException] {
        $result = $_.Exception.Data['process_result']
        $message = if ($null -eq $result) { 'Timed-out child process did not provide a terminal output capture.' }
            else { Format-PublicChildProcessDiagnostic -Operation $Operation -State 'timed_out' -Result $result }
        $failure = [InvalidOperationException]::new($message, $_.Exception)
        foreach ($key in $_.Exception.Data.Keys) { $failure.Data[$key] = $_.Exception.Data[$key] }
        throw $failure
    }
}

function Wait-DesktopOwnedNativeProcess {
    param([Parameter(Mandatory)]$Owned, [int]$TimeoutSeconds, [switch]$NsisJourney)
    try {
        if (-not $owned.owner.WaitTerminal($(if ($NsisJourney) { Get-DesktopNativeNsisJourneyRemainingMilliseconds -AllowExpired } else { $TimeoutSeconds * 1000 }), $script:DesktopObservationPollMilliseconds)) {
            $failure = [TimeoutException]::new('desktop_owned_child_timeout')
            $failure.Data['native_observation'] = Get-DesktopOwnedProcessObservation $owned
            try { $owned.owner.ForceFailureCleanup($script:DesktopObservationTimeoutMilliseconds, $script:DesktopObservationPollMilliseconds) }
            catch { $failure.Data['cleanup_failure'] = $_.Exception; throw $failure }
            $failure.Data['process_result'] = Get-OwnedProcessCapture $owned
            throw $failure
        }
        return (Get-OwnedProcessCapture $owned)
    } catch {
        $failure = $_.Exception
        if (-not $failure.Data.Contains('native_observation')) { $failure.Data['native_observation'] = Get-DesktopOwnedProcessObservation $owned }
        if (-not $owned.owner.Forced -and (-not $owned.process.HasExited -or $owned.owner.ActiveMembers -ne 0)) {
            try { $owned.owner.ForceFailureCleanup($script:DesktopObservationTimeoutMilliseconds, $script:DesktopObservationPollMilliseconds) }
            catch { $failure.Data['cleanup_failure'] = $_.Exception }
        }
        throw $failure
    } finally {
        if ($owned.process.HasExited -and $owned.owner.ActiveMembers -eq 0 -and $owned.owner.CaptureCompleted) { $owned.owner.Dispose() }
    }
}

function Get-OwnedProcessCapture {
    param([Parameter(Mandatory)]$OwnedProcess)

    $process = $OwnedProcess.process
    Assert-Condition $process.HasExited 'Owned process output was requested before the process became terminal.'
    Assert-Condition ($OwnedProcess.owner.WaitTerminal($script:DesktopObservationTimeoutMilliseconds, $script:DesktopObservationPollMilliseconds)) 'desktop_owned_capture_incomplete'
    $stdoutResult = $OwnedProcess.owner.StdoutTask.GetAwaiter().GetResult()
    $stderrResult = $OwnedProcess.owner.StderrTask.GetAwaiter().GetResult()
    $encoding = [Text.UTF8Encoding]::new($false, $false)
    return [pscustomobject]@{
        exit_code = [int]$process.ExitCode
        native_observation = Get-DesktopOwnedProcessObservation $OwnedProcess
        stdout = $encoding.GetString([byte[]]$stdoutResult.RetainedBytes)
        stderr = $encoding.GetString([byte[]]$stderrResult.RetainedBytes)
        stdout_metadata = [pscustomobject][ordered]@{
            present = [long]$stdoutResult.TotalBytes -gt 0
            bytes = [long]$stdoutResult.TotalBytes
            retained_bytes = [long]$stdoutResult.RetainedBytes.LongLength
            truncated = [bool]$stdoutResult.Truncated
        }
        stderr_metadata = [pscustomobject][ordered]@{
            present = [long]$stderrResult.TotalBytes -gt 0
            bytes = [long]$stderrResult.TotalBytes
            retained_bytes = [long]$stderrResult.RetainedBytes.LongLength
            truncated = [bool]$stderrResult.Truncated
        }
    }
}

function Stop-OwnedProcessTree {
    param($RootProcess)
    if ($null -eq $RootProcess) { return }
    Assert-Condition ($null -ne (Get-ObjectPropertyValue $RootProcess 'owner')) 'desktop_owner_missing'
    # This is failure/fixture teardown. Its irreversible forced state never earns normal-close success.
    if (-not $RootProcess.owner.WaitTerminal(0, $script:DesktopObservationPollMilliseconds)) {
        $RootProcess.owner.ForceFailureCleanup($script:DesktopObservationTimeoutMilliseconds, $script:DesktopObservationPollMilliseconds)
    }
}

function Invoke-PublicDownload {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Root
    )

    Assert-Condition ($Uri.Scheme -ceq 'https') "Only HTTPS public downloads are supported: $Uri"
    Assert-Condition (Test-PathInsideRoot -Path $Destination -Root $Root) "Download destination escaped the owned root: $Destination"
    Invoke-Retry -Description "download $Uri" -Operation {
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Force
        }
        Invoke-WebRequest -Uri $Uri -OutFile $Destination -MaximumRedirection 5
        Assert-Condition (Test-Path -LiteralPath $Destination -PathType Leaf) "Download did not create a file: $Destination"
        Assert-Condition ((Get-Item -LiteralPath $Destination).Length -gt 0) "Download was empty: $Uri"
    } | Out-Null
}

function Get-ChecksumEntry {
    param(
        [Parameter(Mandatory)][string]$ManifestText,
        [Parameter(Mandatory)][string]$AssetName
    )

    $matches = @()
    foreach ($line in @($ManifestText -split '\r?\n')) {
        $match = [regex]::Match($line, '^([0-9A-Fa-f]{64})  ([^\r\n]+)$')
        if ($match.Success -and $match.Groups[2].Value -ceq $AssetName) {
            $matches += $match.Groups[1].Value.ToLowerInvariant()
        }
    }
    Assert-Condition ($matches.Count -eq 1) "Checksum manifest must contain exactly one entry for '$AssetName'; found $($matches.Count)."
    return $matches[0]
}

function Assert-FileChecksum {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedHash
    )

    Assert-Condition ($ExpectedHash -match '^[0-9a-f]{64}$') 'Expected SHA-256 must be lowercase hexadecimal.'
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Condition ($actual -ceq $ExpectedHash) "SHA-256 mismatch for $(Split-Path -Leaf $Path): expected $ExpectedHash, got $actual."
}

function Assert-CoreVersionResult {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$ExpectedProgramName,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )

    if ($Result.exit_code -ne 0) {
        throw (Format-PublicChildProcessDiagnostic -Operation 'core_version' -State 'exit_nonzero' -Result $Result)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.stderr)) {
        throw (Format-PublicChildProcessDiagnostic -Operation 'core_version' -State 'stderr_nonempty' -Result $Result)
    }
    if ([string]$Result.stdout.Trim() -cne "$ExpectedProgramName $ExpectedVersion") {
        throw (Format-PublicChildProcessDiagnostic -Operation 'core_version' -State 'content_invalid' -Result $Result)
    }
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-NpmIntegrity {
    param([Parameter(Mandatory)]$Metadata)

    $direct = Get-ObjectPropertyValue -Object $Metadata -Name 'dist.integrity'
    if (-not [string]::IsNullOrWhiteSpace([string]$direct)) {
        return [string]$direct
    }
    $dist = Get-ObjectPropertyValue -Object $Metadata -Name 'dist'
    if ($null -ne $dist) {
        return [string](Get-ObjectPropertyValue -Object $dist -Name 'integrity')
    }
    return ''
}

function Assert-NpmMetadata {
    param(
        [Parameter(Mandatory)]$Metadata,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )

    $actualVersion = [string](Get-ObjectPropertyValue -Object $Metadata -Name 'version')
    $integrity = Get-NpmIntegrity -Metadata $Metadata
    Assert-Condition ($actualVersion -ceq $ExpectedVersion) "npm registry version '$actualVersion' does not match '$ExpectedVersion'."
    Assert-Condition ($integrity -match '^sha512-[A-Za-z0-9+/]+={0,2}$') 'npm registry metadata is missing a valid dist.integrity.'
}

function Assert-NpmHelpResult {
    param([Parameter(Mandatory)]$Result)

    if ($Result.exit_code -ne 0) {
        throw (Format-PublicChildProcessDiagnostic -Operation 'npm_help' -State 'exit_nonzero' -Result $Result)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.stderr)) {
        throw (Format-PublicChildProcessDiagnostic -Operation 'npm_help' -State 'stderr_nonempty' -Result $Result)
    }
    $output = [string]$Result.stdout
    foreach ($token in @('install', 'update', 'uninstall', 'version', 'help')) {
        if ($output -notmatch "(?m)^\s+$([regex]::Escape($token))\s+") {
            throw (Format-PublicChildProcessDiagnostic -Operation 'npm_help' -State 'content_invalid' -Result $Result)
        }
    }
}

function Assert-SafeNpmArchiveEntries {
    param([Parameter(Mandatory)][string[]]$Entries)

    Assert-Condition ($Entries.Count -gt 0) 'Public npm tarball contained no entries.'
    foreach ($entry in $Entries) {
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($entry)) 'Public npm tarball contained an empty entry.'
        Assert-Condition ($entry -notmatch '\\') "Public npm tarball used a backslash path: $entry"
        Assert-Condition ($entry.StartsWith('package/', [StringComparison]::Ordinal)) "Public npm tarball entry escaped package/: $entry"
        foreach ($segment in @($entry -split '/')) {
            if ([string]::IsNullOrEmpty($segment)) {
                continue
            }
            Assert-Condition ($segment -notin @('.', '..')) "Public npm tarball contained a traversal segment: $entry"
            Assert-Condition ($segment -notmatch ':') "Public npm tarball contained a drive-qualified segment: $entry"
        }
    }
}

function Assert-ProductionPageUrl {
    param([Parameter(Mandatory)][string]$Url)

    Assert-Condition ($Url -notmatch '^https?://(?:localhost|127\.0\.0\.1):1420(?:/|$)') "Desktop loaded the development server: $Url"
    Assert-Condition ($Url -match '^(?:tauri://localhost|https?://tauri\.localhost)(?:/|$)') "Desktop did not load a packaged Tauri page: $Url"
}

function Assert-DesktopProductVersion {
    param(
        [Parameter(Mandatory)][string]$ActualVersion,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )

    Assert-Condition ([string]::Equals($ActualVersion, $ExpectedVersion, [StringComparison]::Ordinal)) "Installed desktop ProductVersion '$ActualVersion' does not exactly match '$ExpectedVersion'."
}

function Test-CanonicalPathEqual {
    param(
        [Parameter(Mandatory)][string]$ActualPath,
        [Parameter(Mandatory)][string]$ExpectedPath
    )

    $actual = (Get-CanonicalPath -Path $ActualPath).TrimEnd('\')
    $expected = (Get-CanonicalPath -Path $ExpectedPath).TrimEnd('\')
    return [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DesktopProductStateOwnership {
    param(
        [Parameter(Mandatory)][string]$MaterializedInstallRoot,
        [Parameter(Mandatory)][string]$ExpectedInstallRoot
    )

    Assert-Condition (-not [string]::IsNullOrWhiteSpace($MaterializedInstallRoot)) 'Desktop product state did not contain an install root.'
    Assert-Condition (Test-CanonicalPathEqual -ActualPath $MaterializedInstallRoot -ExpectedPath $ExpectedInstallRoot) "Desktop product state install root '$MaterializedInstallRoot' does not match the run-owned root '$ExpectedInstallRoot'."
}

function Get-ExactDesktopInstallLocation {
    param(
        [Parameter(Mandatory)][string]$InstallLocation,
        [Parameter(Mandatory)][string]$ExpectedInstallRoot
    )

    Assert-Condition (-not [string]::IsNullOrWhiteSpace($InstallLocation)) 'Desktop uninstall registration did not contain InstallLocation.'
    $candidate = $InstallLocation
    $startsWithQuote = $candidate.StartsWith('"', [StringComparison]::Ordinal)
    $endsWithQuote = $candidate.EndsWith('"', [StringComparison]::Ordinal)
    if ($startsWithQuote -or $endsWithQuote) {
        Assert-Condition ($startsWithQuote -and $endsWithQuote -and $candidate.Length -gt 2) "Desktop uninstall InstallLocation has an unsupported quote shape: $InstallLocation"
        $candidate = $candidate.Substring(1, $candidate.Length - 2)
    }
    Assert-Condition ($candidate -notmatch '"') "Desktop uninstall InstallLocation has an unsupported quote shape: $InstallLocation"
    Assert-Condition ([string]::Equals($candidate, $ExpectedInstallRoot, [StringComparison]::OrdinalIgnoreCase)) "Desktop uninstall InstallLocation '$InstallLocation' does not exactly match the run-owned root '$ExpectedInstallRoot'."
    return $candidate
}

function Get-DesktopUninstallCommandPath {
    param([Parameter(Mandatory)][string]$UninstallString)

    $value = $UninstallString.Trim()
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($value)) 'Desktop uninstall registration did not contain UninstallString.'
    if ($value.StartsWith('"', [StringComparison]::Ordinal)) {
        Assert-Condition ($value.EndsWith('"', [StringComparison]::Ordinal) -and $value.Length -ge 2) "Desktop UninstallString has an unsupported command shape: $UninstallString"
        $value = $value.Substring(1, $value.Length - 2)
        Assert-Condition ($value -notmatch '"') "Desktop UninstallString has an unsupported command shape: $UninstallString"
    } else {
        Assert-Condition ($value -notmatch '[\s"]') "Desktop UninstallString has an unsupported command shape: $UninstallString"
    }
    return $value
}

function Assert-DesktopUninstallRegistrationOwnership {
    param(
        [Parameter(Mandatory)]$Registration,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$ExpectedInstallRoot,
        [Parameter(Mandatory)][string]$ExpectedUninstaller
    )

    $displayVersion = [string](Get-ObjectPropertyValue -Object $Registration -Name 'DisplayVersion')
    $installLocation = [string](Get-ObjectPropertyValue -Object $Registration -Name 'InstallLocation')
    $uninstallString = [string](Get-ObjectPropertyValue -Object $Registration -Name 'UninstallString')
    Assert-Condition ([string]::Equals($displayVersion, $ExpectedVersion, [StringComparison]::Ordinal)) "Desktop uninstall DisplayVersion '$displayVersion' does not exactly match '$ExpectedVersion'."
    Get-ExactDesktopInstallLocation -InstallLocation $installLocation -ExpectedInstallRoot $ExpectedInstallRoot | Out-Null
    $registeredUninstaller = Get-DesktopUninstallCommandPath -UninstallString $uninstallString
    Assert-Condition (Test-CanonicalPathEqual -ActualPath $registeredUninstaller -ExpectedPath $ExpectedUninstaller) "Desktop UninstallString '$uninstallString' does not name the run-owned uninstaller '$ExpectedUninstaller'."
}

function Assert-DesktopShortcutOwnership {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ShortcutPath
    )

    Assert-Condition (-not [string]::IsNullOrWhiteSpace($TargetPath)) "Desktop shortcut did not contain a target: $ShortcutPath"
    Assert-Condition (Test-PathInsideRoot -Path $TargetPath -Root $InstallRoot) "Refusing to remove an unexpected shortcut: $ShortcutPath -> $TargetPath"
}

function Assert-DesktopInstallRootOwnership {
    param([Parameter(Mandatory)][string]$InstallRoot)

    $fullRoot = Get-CanonicalPath -Path $InstallRoot
    Assert-Condition ([string]::Equals((Split-Path -Leaf $fullRoot), 'installed', [StringComparison]::Ordinal)) "Desktop install root has an unexpected leaf: $fullRoot"
    $ownerLeaf = Split-Path -Leaf (Split-Path -Parent $fullRoot)
    Assert-Condition ($ownerLeaf -match '^winsmux-public-release-[0-9a-f]{32}$') "Desktop install root is not under a GUID run root: $fullRoot"
}

function Assert-DesktopMaterializedOwnership {
    param([Parameter(Mandatory)]$Context)

    Assert-DesktopLifecyclePhase -Context $Context -ExpectedPhase 'installer_started'
    $installRoot = [string]$Context.install_root
    $appPath = Join-Path $installRoot 'winsmux-app.exe'
    $uninstallPath = [string]$Context.expected_uninstaller

    Assert-Condition (Test-Path -LiteralPath $installRoot -PathType Container) "Desktop installer did not materialize the run-owned install root: $installRoot"
    foreach ($materializedPath in @($appPath, $uninstallPath)) {
        Assert-Condition (Test-Path -LiteralPath $materializedPath -PathType Leaf) "Desktop installer did not materialize the expected file: $materializedPath"
    }
    foreach ($materializedPath in @($installRoot, $appPath, $uninstallPath)) {
        $materializedItem = Get-Item -LiteralPath $materializedPath -Force
        Assert-Condition (($materializedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Desktop installer materialized a reparse point: $materializedPath"
    }

    $productVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($appPath).ProductVersion
    Assert-DesktopProductVersion -ActualVersion $productVersion -ExpectedVersion ([string]$Context.expected_version)

    Assert-Condition (Test-Path -LiteralPath $script:DesktopProductPath) 'Desktop installer did not materialize the product-state registration.'
    $materializedInstallRoot = Get-RegistryDefaultValue -Path $script:DesktopProductPath
    Assert-DesktopProductStateOwnership -MaterializedInstallRoot $materializedInstallRoot -ExpectedInstallRoot $installRoot

    Assert-Condition (Test-Path -LiteralPath $script:DesktopUninstallPath) 'Desktop installer did not materialize the uninstall registration.'
    $uninstallRegistration = Get-ItemProperty -LiteralPath $script:DesktopUninstallPath
    Assert-DesktopUninstallRegistrationOwnership -Registration $uninstallRegistration -ExpectedVersion ([string]$Context.expected_version) -ExpectedInstallRoot $installRoot -ExpectedUninstaller $uninstallPath

    foreach ($shortcutPath in @((Get-DesktopShortcutPath), (Get-DesktopStartMenuShortcutPath))) {
        if (Test-Path -LiteralPath $shortcutPath) {
            $targetPath = Get-DesktopShortcutTarget -Path $shortcutPath
            Assert-DesktopShortcutOwnership -TargetPath $targetPath -InstallRoot $installRoot -ShortcutPath $shortcutPath
        }
    }
}

function Get-DesktopShortcutPath {
    $desktop = [Environment]::GetFolderPath('Desktop')
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($desktop)) 'Desktop shell folder could not be resolved.'
    return (Join-Path $desktop 'winsmux.lnk')
}

function Get-DesktopStartMenuShortcutPath {
    $programs = [Environment]::GetFolderPath('Programs')
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($programs)) 'Start Menu Programs shell folder could not be resolved.'
    return (Join-Path $programs 'winsmux.lnk')
}

function Get-RegistryDefaultValue {
    param([Parameter(Mandatory)][string]$Path)

    return [string](Get-Item -LiteralPath $Path).GetValue('')
}

function Get-DesktopShortcutTarget {
    param([Parameter(Mandatory)][string]$Path)

    $shell = New-Object -ComObject WScript.Shell
    return [string]$shell.CreateShortcut($Path).TargetPath
}

function Get-DesktopProtectedState {
    param([string]$InstallRoot)

    return [pscustomobject]@{
        folder_context_exists = Test-Path -LiteralPath $script:DesktopFolderContextPath
        background_context_exists = Test-Path -LiteralPath $script:DesktopBackgroundContextPath
        product_state_exists = Test-Path -LiteralPath $script:DesktopProductPath
        uninstall_registration_exists = Test-Path -LiteralPath $script:DesktopUninstallPath
        desktop_shortcut_exists = Test-Path -LiteralPath (Get-DesktopShortcutPath)
        start_menu_shortcut_exists = Test-Path -LiteralPath (Get-DesktopStartMenuShortcutPath)
        process_count = @(Get-Process -Name 'winsmux-app' -ErrorAction SilentlyContinue).Count
        app_payload_exists = -not [string]::IsNullOrWhiteSpace($InstallRoot) -and (Test-Path -LiteralPath (Join-Path $InstallRoot 'winsmux-app.exe'))
        install_root_exists = -not [string]::IsNullOrWhiteSpace($InstallRoot) -and (Test-Path -LiteralPath $InstallRoot)
    }
}

function Assert-NoDesktopProtectedState {
    param(
        [Parameter(Mandatory)]$State,
        [string]$Phase = 'desktop smoke'
    )

    Assert-Condition (-not $State.folder_context_exists) "$Phase observed an existing winsmux folder-context registration."
    Assert-Condition (-not $State.background_context_exists) "$Phase observed an existing winsmux background-context registration."
    Assert-Condition (-not $State.product_state_exists) "$Phase observed existing winsmux product state."
    Assert-Condition (-not $State.uninstall_registration_exists) "$Phase observed an existing winsmux uninstall registration."
    Assert-Condition (-not $State.desktop_shortcut_exists) "$Phase observed an existing winsmux Desktop shortcut."
    Assert-Condition (-not $State.start_menu_shortcut_exists) "$Phase observed an existing winsmux Start Menu shortcut."
    Assert-Condition ($State.process_count -eq 0) "$Phase observed $($State.process_count) winsmux-app process(es)."
    Assert-Condition (-not $State.app_payload_exists) "$Phase observed a remaining winsmux-app.exe payload."
    Assert-Condition (-not $State.install_root_exists) "$Phase observed a remaining install root."
}

function Assert-DesktopPreUninstallOwnedState {
    param([Parameter(Mandatory)]$State)

    Assert-Condition ([bool]$State.product_state_exists) 'Desktop product-state registration was absent immediately before the registered uninstaller.'
    Assert-Condition ([bool]$State.uninstall_registration_exists) 'Desktop uninstall registration was absent immediately before the registered uninstaller.'
    Assert-Condition ([bool]$State.app_payload_exists) 'winsmux-app.exe was absent immediately before the registered uninstaller.'
}

function Assert-DesktopPostUninstallOwnedState {
    param([Parameter(Mandatory)]$State)

    Assert-Condition (-not $State.folder_context_exists) 'Desktop folder-context registration remained immediately after the normal uninstaller.'
    Assert-Condition (-not $State.background_context_exists) 'Desktop background-context registration remained immediately after the normal uninstaller.'
    Assert-Condition (-not $State.product_state_exists) 'Desktop product state remained immediately after the normal uninstaller.'
    Assert-Condition (-not $State.uninstall_registration_exists) 'Desktop uninstall registration remained immediately after the normal uninstaller.'
    Assert-Condition (-not $State.desktop_shortcut_exists) 'Desktop shortcut remained immediately after the normal uninstaller.'
    Assert-Condition (-not $State.start_menu_shortcut_exists) 'Start Menu shortcut remained immediately after the normal uninstaller.'
    Assert-Condition (-not $State.app_payload_exists) 'winsmux-app.exe remained immediately after the normal uninstaller.'
}

function New-EmptyDesktopProtectedState {
    return [pscustomobject]@{
        folder_context_exists = $false
        background_context_exists = $false
        product_state_exists = $false
        uninstall_registration_exists = $false
        desktop_shortcut_exists = $false
        start_menu_shortcut_exists = $false
        process_count = 0
        app_payload_exists = $false
        install_root_exists = $false
    }
}

function New-DesktopLifecycleContext {
    param(
        [Parameter(Mandatory)][string]$OwnedRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )

    $canonicalOwnedRoot = Get-CanonicalPath -Path $OwnedRoot
    $canonicalInstallRoot = Get-CanonicalPath -Path $InstallRoot
    Assert-DesktopInstallRootOwnership -InstallRoot $canonicalInstallRoot
    Assert-Condition (Test-CanonicalPathEqual -ActualPath $canonicalInstallRoot -ExpectedPath (Join-Path $canonicalOwnedRoot 'installed')) 'Desktop lifecycle install root is not the owned root installed child.'
    return [pscustomobject]@{
        phase = 'new'
        owned_root = $canonicalOwnedRoot
        install_root = $canonicalInstallRoot
        expected_version = $ExpectedVersion
        expected_uninstaller = Join-Path $canonicalInstallRoot 'uninstall.exe'
        app_process = $null
        block_error = ''
    }
}

function Assert-DesktopLifecyclePhase {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]
        [ValidateSet('new', 'preflight_clean', 'installer_started', 'materialized_verified', 'uninstall_verified', 'residue_clean', 'preserve', 'clean')]
        [string]$ExpectedPhase
    )

    Assert-Condition ([string]$Context.phase -ceq $ExpectedPhase) "Desktop lifecycle phase '$($Context.phase)' does not match required phase '$ExpectedPhase'."
}

function Set-DesktopLifecyclePhase {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]
        [ValidateSet('preflight_clean', 'installer_started', 'materialized_verified', 'uninstall_verified', 'residue_clean', 'clean')]
        [string]$NextPhase
    )

    $allowedTransitions = @{
        new = @('preflight_clean', 'clean')
        preflight_clean = @('installer_started', 'clean')
        installer_started = @('materialized_verified')
        materialized_verified = @('uninstall_verified')
        uninstall_verified = @('residue_clean')
        residue_clean = @('clean')
        preserve = @()
        clean = @()
    }
    Assert-Condition ($NextPhase -cin @($allowedTransitions[[string]$Context.phase])) "Desktop lifecycle transition '$($Context.phase)' -> '$NextPhase' is not permitted."
    $Context.phase = $NextPhase
}

function Set-DesktopLifecyclePreserve {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Message
    )

    if ([string]$Context.phase -cin @('preserve', 'clean')) {
        return
    }
    $Context.phase = 'preserve'
    if ([string]::IsNullOrWhiteSpace([string]$Context.block_error)) {
        $Context.block_error = $Message
    }
}

function Start-DesktopLifecycle {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$PreflightState
    )

    Assert-NoDesktopProtectedState -State $PreflightState -Phase 'desktop preflight'
    Set-DesktopLifecyclePhase -Context $Context -NextPhase 'preflight_clean'
}

function Assert-DesktopRunner {
    Assert-Condition ($env:GITHUB_ACTIONS -ceq 'true') 'Desktop public smoke may run only on a GitHub Actions disposable runner.'
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) 'Desktop public smoke requires RUNNER_TEMP.'
}

function Invoke-VerifiedDesktopUninstaller {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][hashtable]$Environment,
        [scriptblock]$ProcessInvoker,
        [scriptblock]$ProtectedStateProbe
    )

    Assert-DesktopLifecyclePhase -Context $Context -ExpectedPhase 'materialized_verified'
    $installRoot = [string]$Context.install_root
    $uninstallerPath = [string]$Context.expected_uninstaller
    Assert-DesktopInstallRootOwnership -InstallRoot $InstallRoot
    $expectedUninstaller = Join-Path $InstallRoot 'uninstall.exe'
    Assert-Condition (Test-CanonicalPathEqual -ActualPath $UninstallerPath -ExpectedPath $expectedUninstaller) "Desktop uninstall invocation path '$UninstallerPath' does not name the run-owned uninstaller '$expectedUninstaller'."
    Assert-Condition (Test-Path -LiteralPath $expectedUninstaller -PathType Leaf) "Run-owned Desktop uninstaller was not found: $expectedUninstaller"

    $preUninstallState = if ($null -eq $ProtectedStateProbe) {
        Get-DesktopProtectedState -InstallRoot $InstallRoot
    } else {
        & $ProtectedStateProbe $InstallRoot 'pre_uninstall'
    }
    Assert-DesktopPreUninstallOwnedState -State $preUninstallState

    $uninstall = Invoke-DesktopNsisProcess -Operation 'desktop_uninstaller' -FilePath $expectedUninstaller -Context $Context -Environment $Environment -ProcessInvoker $ProcessInvoker
    if ($uninstall.exit_code -ne 0) {
        $failure = [InvalidOperationException]::new('desktop_uninstaller_exit_nonzero')
        $failure.Data['native_result'] = $uninstall
        throw $failure
    }

    $postUninstallState = if ($null -eq $ProtectedStateProbe) {
        Get-DesktopProtectedState -InstallRoot $InstallRoot
    } else {
        & $ProtectedStateProbe $InstallRoot 'post_uninstall'
    }
    Assert-DesktopPostUninstallOwnedState -State $postUninstallState
    return $uninstall
}

function Remove-DesktopOwnedResidue {
    param(
        [Parameter(Mandatory)]$Context,
        [scriptblock]$ProtectedStateProbe
    )

    Assert-DesktopLifecyclePhase -Context $Context -ExpectedPhase 'uninstall_verified'
    $installRoot = [string]$Context.install_root
    Assert-DesktopInstallRootOwnership -InstallRoot $InstallRoot

    $postUninstallState = if ($null -eq $ProtectedStateProbe) {
        Get-DesktopProtectedState -InstallRoot $InstallRoot
    } else {
        & $ProtectedStateProbe $InstallRoot 'pre_residue_cleanup'
    }
    Assert-DesktopPostUninstallOwnedState -State $postUninstallState

    $installRootExists = Test-Path -LiteralPath $InstallRoot
    if ($installRootExists) {
        $item = Get-Item -LiteralPath $InstallRoot -Force
        Assert-Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Refusing to remove a reparse-point install root: $InstallRoot"
        $expectedUninstaller = Join-Path $InstallRoot 'uninstall.exe'
        $unexpectedEntries = @(Get-ChildItem -LiteralPath $InstallRoot -Force | Where-Object {
            -not (Test-CanonicalPathEqual -ActualPath $_.FullName -ExpectedPath $expectedUninstaller)
        })
        Assert-Condition ($unexpectedEntries.Count -eq 0) 'Desktop uninstaller left unexpected install-root residue; refusing harness cleanup.'

        if (Test-Path -LiteralPath $expectedUninstaller) {
            $uninstallerItem = Get-Item -LiteralPath $expectedUninstaller -Force
            Assert-Condition (-not $uninstallerItem.PSIsContainer) "Leftover Desktop uninstaller path was not a file: $expectedUninstaller"
            Assert-Condition (($uninstallerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Refusing to remove a reparse-point Desktop uninstaller: $expectedUninstaller"
            Remove-Item -LiteralPath $expectedUninstaller -Force
        }

        Assert-Condition (@(Get-ChildItem -LiteralPath $InstallRoot -Force).Count -eq 0) 'Desktop install root was not empty after deleting leftover uninstall.exe.'
        Remove-Item -LiteralPath $InstallRoot -Force
    }

    $finalState = Get-DesktopProtectedState -InstallRoot $InstallRoot
    Assert-NoDesktopProtectedState -State $finalState -Phase 'desktop final cleanup'
}

function Invoke-DesktopCleanup {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][hashtable]$Environment,
        [string]$OperationErrorMessage = '',
        [scriptblock]$StopInvoker,
        [scriptblock]$UninstallInvoker,
        [scriptblock]$ResidueInvoker,
        [scriptblock]$RootRemover
    )

    if ([string]$Context.phase -cin @('clean', 'preserve')) {
        return $Context
    }

    try {
        if ([string]$Context.phase -cin @('new', 'preflight_clean')) {
            if ($null -eq $RootRemover) {
                Remove-OwnedRoot -Root ([string]$Context.owned_root)
            } else {
                & $RootRemover ([string]$Context.owned_root) | Out-Null
            }
            Set-DesktopLifecyclePhase -Context $Context -NextPhase 'clean'
            return $Context
        }

        if ([string]$Context.phase -ceq 'installer_started') {
            $reason = if ([string]::IsNullOrWhiteSpace($OperationErrorMessage)) {
                'Desktop materialized ownership was not verified after the installer started.'
            } else {
                $OperationErrorMessage
            }
            Set-DesktopLifecyclePreserve -Context $Context -Message $reason
            return $Context
        }

        Assert-DesktopLifecyclePhase -Context $Context -ExpectedPhase 'materialized_verified'
        if ($null -eq $StopInvoker) {
            $script:DesktopCleanupStage = 'normal_close'
            Stop-DesktopNormally -RootProcess $Context.app_process
        } else {
            & $StopInvoker $Context.app_process | Out-Null
        }

        if ($null -eq $UninstallInvoker) {
            $script:DesktopCleanupStage = 'uninstall'
            Invoke-VerifiedDesktopUninstaller -Context $Context -Environment $Environment | Out-Null
        } else {
            & $UninstallInvoker $Context $Environment | Out-Null
        }
        Set-DesktopLifecyclePhase -Context $Context -NextPhase 'uninstall_verified'

        if ($null -eq $ResidueInvoker) {
            $script:DesktopCleanupStage = 'residue'
            Remove-DesktopOwnedResidue -Context $Context
        } else {
            & $ResidueInvoker $Context | Out-Null
        }
        Set-DesktopLifecyclePhase -Context $Context -NextPhase 'residue_clean'

        if ($null -eq $RootRemover) {
            Remove-OwnedRoot -Root ([string]$Context.owned_root)
        } else {
            & $RootRemover ([string]$Context.owned_root) | Out-Null
        }
        Set-DesktopLifecyclePhase -Context $Context -NextPhase 'clean'
        return $Context
    } catch {
        $failure = $_.Exception
        Set-DesktopLifecyclePreserve -Context $Context -Message $failure.Message
        # Failure is established and the installation is preserved before owned Job recovery.
        if ($null -ne $Context.app_process -and $null -ne (Get-ObjectPropertyValue $Context.app_process 'owner')) {
            try { $Context.app_process.owner.ForceFailureCleanup($script:DesktopObservationTimeoutMilliseconds, $script:DesktopObservationPollMilliseconds) }
            catch { $failure.Data['owned_process_cleanup_failure'] = $_.Exception }
        }
        throw $failure
    }
}

function Get-DesktopDevToolsPortFileSnapshot {
    param([Parameter(Mandatory)][string]$UserDataFolder)

    if (-not (Test-Path -LiteralPath $UserDataFolder -PathType Container)) {
        return [pscustomobject]@{
            user_data_exists = $false
            user_data_reparse = $false
            file_exists = $false
            file_reparse = $false
            too_large = $false
            bytes = [byte[]]::new(0)
        }
    }
    $userDataItem = Get-Item -LiteralPath $UserDataFolder -Force
    $userDataReparse = ($userDataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    # WebView2 stores the Chromium profile in the 'EBWebView' subfolder of the
    # configured user data folder; DevToolsActivePort appears at that profile
    # root, never at the configured folder itself.
    $profileRoot = Join-Path $UserDataFolder 'EBWebView'
    if (-not $userDataReparse -and (Test-Path -LiteralPath $profileRoot -PathType Container)) {
        $profileItem = Get-Item -LiteralPath $profileRoot -Force
        $userDataReparse = ($profileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    }
    $path = Join-Path $profileRoot 'DevToolsActivePort'
    if ($userDataReparse -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            user_data_exists = $true
            user_data_reparse = $userDataReparse
            file_exists = $false
            file_reparse = $false
            too_large = $false
            bytes = [byte[]]::new(0)
        }
    }
    $item = Get-Item -LiteralPath $path -Force
    $fileReparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    $tooLarge = $item.Length -gt 4096
    $bytes = if ($fileReparse -or $tooLarge) {
        [byte[]]::new(0)
    } else {
        [IO.File]::ReadAllBytes($path)
    }
    return [pscustomobject]@{
        user_data_exists = $true
        user_data_reparse = $false
        file_exists = $true
        file_reparse = $fileReparse
        too_large = $tooLarge
        bytes = [byte[]]$bytes
    }
}

function Read-DesktopDevToolsActivePort {
    param(
        [Parameter(Mandatory)][string]$UserDataFolder,
        [scriptblock]$SnapshotProvider
    )

    $snapshot = if ($null -eq $SnapshotProvider) {
        Get-DesktopDevToolsPortFileSnapshot -UserDataFolder $UserDataFolder
    } else {
        & $SnapshotProvider $UserDataFolder
    }
    Assert-Condition ($null -ne $snapshot) 'Desktop DevTools port-file snapshot was absent.'
    if (-not [bool](Get-ObjectPropertyValue -Object $snapshot -Name 'user_data_exists')) {
        return [pscustomobject]@{ state = 'port_file_missing'; port = 0; browser_path = $null }
    }
    if ([bool](Get-ObjectPropertyValue -Object $snapshot -Name 'user_data_reparse')) {
        return [pscustomobject]@{ state = 'user_data_reparse'; port = 0; browser_path = $null }
    }
    if (-not [bool](Get-ObjectPropertyValue -Object $snapshot -Name 'file_exists')) {
        return [pscustomobject]@{ state = 'port_file_missing'; port = 0; browser_path = $null }
    }
    if ([bool](Get-ObjectPropertyValue -Object $snapshot -Name 'file_reparse')) {
        return [pscustomobject]@{ state = 'port_file_reparse'; port = 0; browser_path = $null }
    }
    if ([bool](Get-ObjectPropertyValue -Object $snapshot -Name 'too_large')) {
        return [pscustomobject]@{ state = 'port_file_invalid_shape'; port = 0; browser_path = $null }
    }

    $bytes = [byte[]](Get-ObjectPropertyValue -Object $snapshot -Name 'bytes')
    if ($bytes.Length -gt 4096) {
        return [pscustomobject]@{ state = 'port_file_invalid_shape'; port = 0; browser_path = $null }
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        return [pscustomobject]@{ state = 'port_file_invalid_encoding'; port = 0; browser_path = $null }
    }
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } catch {
        return [pscustomobject]@{ state = 'port_file_invalid_encoding'; port = 0; browser_path = $null }
    }
    if ($text.Contains("`r", [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ state = 'port_file_invalid_shape'; port = 0; browser_path = $null }
    }
    $parts = $text.Split([char]"`n")
    if ($parts.Count -ne 2 -or [string]::IsNullOrEmpty($parts[0]) -or [string]::IsNullOrEmpty($parts[1])) {
        return [pscustomobject]@{ state = 'port_file_invalid_shape'; port = 0; browser_path = $null }
    }

    $port = 0
    if ($parts[0] -cnotmatch '^[0-9]+$' -or -not [int]::TryParse($parts[0], [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        return [pscustomobject]@{ state = 'port_invalid'; port = 0; browser_path = $null }
    }
    $browserPath = [string]$parts[1]
    if ($browserPath -cnotmatch '^/devtools/browser/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        return [pscustomobject]@{ state = 'browser_path_invalid'; port = 0; browser_path = $null }
    }
    return [pscustomobject]@{ state = 'authority_ready'; port = $port; browser_path = $browserPath }
}

function New-DesktopDebugEndpointRecord {
    param([Parameter(Mandatory)][int]$Port)

    Assert-Condition ($Port -ge 1 -and $Port -le 65535) 'Desktop fixed debug endpoint received an invalid loopback port.'
    return [pscustomobject][ordered]@{
        port = [int]$Port
        argument = "--remote-debugging-port=$Port"
    }
}

function New-DesktopFixedDebugEndpoint {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        return New-DesktopDebugEndpointRecord -Port $port
    } finally {
        $listener.Stop()
    }
}

function Invoke-BoundedDiagnosisProbe {
    param(
        [Parameter(Mandatory)][scriptblock]$Probe,
        [AllowNull()]$Argument,
        [int]$TimeoutMilliseconds = $script:DesktopTeardownProbeTimeoutMilliseconds
    )

    if ($TimeoutMilliseconds -le 0) {
        return 'unknown'
    }
    $runner = [powershell]::Create()
    $abandonRunner = $false
    try {
        $null = $runner.AddScript($Probe.ToString()).AddArgument($Argument)
        $handle = $runner.BeginInvoke()
        if (-not $handle.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            $abandonRunner = $true
            try { [void]$runner.BeginStop($null, $null) } catch { }
            # Abandonment is bounded per run: the probe table is finite and the helper process is short-lived.
            return 'error:timeout'
        }
        $output = $runner.EndInvoke($handle)
        if ($runner.HadErrors) {
            return 'error:io'
        }
        if ($output.Count -lt 1) {
            return 'false'
        }
        $lastOutputText = [string]$output[$output.Count - 1]
        if ($lastOutputText -ceq [bool]::TrueString) {
            return 'true'
        }
        if ($lastOutputText -ceq [bool]::FalseString) {
            return 'false'
        }
        if ($lastOutputText -cmatch '^(?:true|false|unknown|error:[a-z]+)$') {
            return $lastOutputText
        }
        return 'error:io'
    } catch {
        return 'error:io'
    } finally {
        if (-not $abandonRunner) {
            try { $runner.Dispose() } catch { }
        }
    }
}

function New-DesktopTeardownProbeTable {
    param(
        [Parameter(Mandatory)][string]$UserDataFolder,
        [Parameter(Mandatory)][long]$RootProcessId,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$DebugPort,
        [AllowNull()][object[]]$ProcessSnapshotItems = $null
    )

    Initialize-DesktopNativeTypes
    $profileRoot = Join-Path $UserDataFolder 'EBWebView'
    $processProbeArgument = [pscustomobject]@{
        root_process_id = [long]$RootProcessId
        debug_argument = "--remote-debugging-port=$DebugPort"
        env_marker_argument = $script:DesktopSmokeEnvMarkerArgument
        processes = $ProcessSnapshotItems
    }
    return [ordered]@{
        desktop_probe_runtime_registry = @{
            Script = {
                param($ProbeArgument)

                $registrationPaths = @(
                    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
                    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
                    'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
                )
                foreach ($registrationPath in $registrationPaths) {
                    if (-not (Test-Path -LiteralPath $registrationPath)) {
                        continue
                    }
                    $candidateVersion = [string](Get-ItemProperty -LiteralPath $registrationPath -Name 'pv' -ErrorAction Stop).pv
                    if (-not [string]::IsNullOrWhiteSpace($candidateVersion)) {
                        return $true
                    }
                }
                return $false
            }
            Argument = $null
        }
        desktop_probe_runtime_binary = @{
            Script = {
                param($ProbeArgument)

                $registrationPaths = @(
                    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
                    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
                    'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
                )
                $runtimeVersions = [Collections.Generic.List[string]]::new()
                foreach ($registrationPath in $registrationPaths) {
                    if (-not (Test-Path -LiteralPath $registrationPath)) {
                        continue
                    }
                    $candidateVersion = [string](Get-ItemProperty -LiteralPath $registrationPath -Name 'pv' -ErrorAction Stop).pv
                    if (-not [string]::IsNullOrWhiteSpace($candidateVersion)) {
                        $runtimeVersions.Add($candidateVersion)
                    }
                }
                if ($runtimeVersions.Count -eq 0) {
                    return 'unknown'
                }
                $binaryCandidates = [Collections.Generic.List[string]]::new()
                foreach ($runtimeVersion in $runtimeVersions) {
                    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
                        $binaryCandidates.Add((Join-Path ${env:ProgramFiles(x86)} "Microsoft\EdgeWebView\Application\$runtimeVersion\msedgewebview2.exe"))
                    }
                    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
                        $binaryCandidates.Add((Join-Path $env:LOCALAPPDATA "Microsoft\EdgeWebView\Application\$runtimeVersion\msedgewebview2.exe"))
                    }
                }
                foreach ($binaryPath in $binaryCandidates) {
                    if (Test-Path -LiteralPath $binaryPath -PathType Leaf) {
                        return $true
                    }
                }
                return $false
            }
            Argument = $null
        }
        desktop_probe_profile_dir = @{
            Script = { param($ProbeArgument) Test-Path -LiteralPath $ProbeArgument -PathType Container }
            Argument = $profileRoot
        }
        desktop_probe_init_trace = @{
            Script = {
                param($ProbeArgument)
                (Test-Path -LiteralPath (Join-Path $ProbeArgument 'Local State') -PathType Leaf) -or
                    (Test-Path -LiteralPath (Join-Path $ProbeArgument 'Crashpad') -PathType Container)
            }
            Argument = $profileRoot
        }
        desktop_probe_port_file_redirected = @{
            Script = { param($ProbeArgument) Test-Path -LiteralPath $ProbeArgument -PathType Leaf }
            Argument = Join-Path $profileRoot 'DevToolsActivePort'
        }
        desktop_probe_port_file_fallback = @{
            Script = { param($ProbeArgument) Test-Path -LiteralPath $ProbeArgument -PathType Leaf }
            Argument = Join-Path (Split-Path -Parent $UserDataFolder) 'LocalAppData\io.github.sora-bluesky.winsmux\EBWebView\DevToolsActivePort'
        }
        desktop_probe_webview_process_present = @{
            Script = {
                param($ProbeArgument)

                $processes = if ($null -eq $ProbeArgument.processes) {
                    @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine -ErrorAction Stop)
                } else {
                    @($ProbeArgument.processes)
                }
                $descendantProcessIds = [Collections.Generic.HashSet[long]]::new()
                [void]$descendantProcessIds.Add([long]$ProbeArgument.root_process_id)
                do {
                    $addedDescendant = $false
                    foreach ($process in $processes) {
                        if ($descendantProcessIds.Contains([long]$process.ParentProcessId) -and
                            $descendantProcessIds.Add([long]$process.ProcessId)) {
                            $addedDescendant = $true
                        }
                    }
                } while ($addedDescendant)
                foreach ($process in $processes) {
                    if ($descendantProcessIds.Contains([long]$process.ProcessId) -and
                        [string]::Equals([string]$process.Name, 'msedgewebview2.exe', [StringComparison]::OrdinalIgnoreCase)) {
                        return $true
                    }
                }
                return $false
            }
            Argument = $processProbeArgument
        }
        desktop_probe_debug_arg = @{
            Script = {
                param($ProbeArgument)

                $processes = if ($null -eq $ProbeArgument.processes) {
                    @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine -ErrorAction Stop)
                } else {
                    @($ProbeArgument.processes)
                }
                $descendantProcessIds = [Collections.Generic.HashSet[long]]::new()
                [void]$descendantProcessIds.Add([long]$ProbeArgument.root_process_id)
                do {
                    $addedDescendant = $false
                    foreach ($process in $processes) {
                        if ($descendantProcessIds.Contains([long]$process.ParentProcessId) -and
                            $descendantProcessIds.Add([long]$process.ProcessId)) {
                            $addedDescendant = $true
                        }
                    }
                } while ($addedDescendant)
                foreach ($process in $processes) {
                    if (-not $descendantProcessIds.Contains([long]$process.ProcessId) -or
                        -not [string]::Equals([string]$process.Name, 'msedgewebview2.exe', [StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }
                    $arguments = @([Winsmux.PublicRelease.WindowsCommandLine]::Parse([string]$process.CommandLine))
                    if (@($arguments | Where-Object { [string]$_ -ceq [string]$ProbeArgument.debug_argument }).Count -gt 0) {
                        return $true
                    }
                }
                return $false
            }
            Argument = $processProbeArgument
        }
        desktop_probe_env_channel = @{
            Script = {
                param($ProbeArgument)

                $processes = if ($null -eq $ProbeArgument.processes) {
                    @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine -ErrorAction Stop)
                } else {
                    @($ProbeArgument.processes)
                }
                $descendantProcessIds = [Collections.Generic.HashSet[long]]::new()
                [void]$descendantProcessIds.Add([long]$ProbeArgument.root_process_id)
                do {
                    $addedDescendant = $false
                    foreach ($process in $processes) {
                        if ($descendantProcessIds.Contains([long]$process.ParentProcessId) -and
                            $descendantProcessIds.Add([long]$process.ProcessId)) {
                            $addedDescendant = $true
                        }
                    }
                } while ($addedDescendant)
                foreach ($process in $processes) {
                    if (-not $descendantProcessIds.Contains([long]$process.ProcessId) -or
                        -not [string]::Equals([string]$process.Name, 'msedgewebview2.exe', [StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }
                    $arguments = @([Winsmux.PublicRelease.WindowsCommandLine]::Parse([string]$process.CommandLine))
                    if (@($arguments | Where-Object { [string]$_ -ceq [string]$ProbeArgument.env_marker_argument }).Count -gt 0) {
                        return $true
                    }
                }
                return $false
            }
            Argument = $processProbeArgument
        }
    }
}

function Get-DesktopTeardownDiagnosis {
    param(
        [Parameter(Mandatory)][string]$UserDataFolder,
        [long]$RootProcessId = 0,
        [int]$DebugPort = 0,
        $ProbeTable,
        [int]$ProbeTimeoutMilliseconds = $script:DesktopTeardownProbeTimeoutMilliseconds,
        [int]$TotalBudgetMilliseconds = $script:DesktopTeardownProbeTotalBudgetMilliseconds
    )

    if ($null -eq $ProbeTable) {
        Assert-Condition ($RootProcessId -gt 0) 'Desktop teardown diagnosis requires a positive root process ID when building the real probe table.'
        Assert-Condition ($DebugPort -ge 1 -and $DebugPort -le 65535) 'Desktop teardown diagnosis requires the injected fixed debug port when building the real probe table.'
        $ProbeTable = New-DesktopTeardownProbeTable -UserDataFolder $UserDataFolder -RootProcessId $RootProcessId -DebugPort $DebugPort
    }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $diagnosis = [ordered]@{}
    foreach ($name in @($ProbeTable.Keys)) {
        $remaining = $TotalBudgetMilliseconds - $stopwatch.ElapsedMilliseconds
        if ($remaining -le 0) {
            $diagnosis[[string]$name] = 'unknown'
            continue
        }
        $entry = $ProbeTable[$name]
        $timeout = [int][Math]::Min([long]$ProbeTimeoutMilliseconds, $remaining)
        $diagnosis[[string]$name] = Invoke-BoundedDiagnosisProbe -Probe $entry.Script -Argument $entry.Argument -TimeoutMilliseconds $timeout
    }
    return $diagnosis
}

function Get-DesktopTeardownDiagnosisSegment {
    param([Parameter(Mandatory)]$Diagnosis)

    $pairs = [Collections.Generic.List[string]]::new()
    foreach ($name in @($Diagnosis.Keys)) {
        $pairs.Add(('{0}={1}' -f [string]$name, [string]$Diagnosis[$name]))
    }
    $segment = [string]::Join(' ', $pairs)
    foreach ($pair in $pairs) {
        Assert-Condition ($pair -cmatch '^desktop_probe_[a-z_]+=(?:true|false|unknown|error:[a-z]+)$') 'Teardown diagnosis pair violated the fixed key/value allowlist.'
    }
    Assert-Condition ($segment -notmatch 'DevToolsActivePort|msedgewebview2|--remote-debugging-port|/devtools/browser/|listener_owner_pid|root_pid|browser_pid') 'Teardown diagnosis segment violated the raw-absent pattern.'
    return $segment
}

function Write-DesktopProbeDiagnosticsLine {
    param(
        [Parameter(Mandatory)]$Diagnosis,
        [scriptblock]$Emitter
    )

    $line = 'desktop_probe_diagnosis {0}' -f (Get-DesktopTeardownDiagnosisSegment -Diagnosis $Diagnosis)
    if ($null -eq $Emitter) {
        [Console]::Error.WriteLine($line)
    } else {
        & $Emitter $line | Out-Null
    }
    return $line
}

function New-DesktopSnapshotEnvelope {
    param(
        [Parameter(Mandatory)][ValidateSet('processes', 'listeners')][string]$Kind,
        [AllowEmptyCollection()][object[]]$Items = @()
    )

    $materialized = [Collections.Generic.List[object]]::new()
    foreach ($item in @($Items)) {
        Assert-Condition ($null -ne $item) "Desktop $Kind snapshot contained a null item."
        $materialized.Add($item)
    }
    return [pscustomobject][ordered]@{
        kind = $Kind
        items = [object[]]$materialized.ToArray()
    }
}

function Get-DesktopProcessSnapshot {
    $items = [Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
        $items.Add([pscustomobject]@{
            process_id = [int64]$process.ProcessId
            parent_process_id = [int64]$process.ParentProcessId
            name = [string]$process.Name
            command_line = [string]$process.CommandLine
        })
    }
    return (New-DesktopSnapshotEnvelope -Kind 'processes' -Items $items.ToArray())
}

function Get-DesktopListenerSnapshot {
    param([Parameter(Mandatory)][int]$Port)

    $items = [Collections.Generic.List[object]]::new()
    foreach ($listener in @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {
        [int]$_.LocalPort -eq $Port
    })) {
        $items.Add([pscustomobject]@{
            local_address = [string]$listener.LocalAddress
            local_port = [int]$listener.LocalPort
            owning_process = [int64]$listener.OwningProcess
        })
    }
    return (New-DesktopSnapshotEnvelope -Kind 'listeners' -Items $items.ToArray())
}

function Test-DesktopProcessDescendant {
    param(
        [Parameter(Mandatory)][int64]$RootProcessId,
        [Parameter(Mandatory)][int64]$CandidateProcessId,
        [Parameter(Mandatory)]$ProcessSnapshot
    )

    Assert-Condition ([string](Get-ObjectPropertyValue -Object $ProcessSnapshot -Name 'kind') -ceq 'processes') 'Desktop process snapshot envelope kind was invalid.'
    $parentByProcess = @{}
    foreach ($entry in @((Get-ObjectPropertyValue -Object $ProcessSnapshot -Name 'items'))) {
        Assert-Condition ($null -ne $entry) 'Desktop process snapshot envelope contained a null item.'
        $processId = [int64](Get-ObjectPropertyValue -Object $entry -Name 'process_id')
        $parentProcessId = [int64](Get-ObjectPropertyValue -Object $entry -Name 'parent_process_id')
        if (-not $parentByProcess.ContainsKey($processId)) {
            $parentByProcess[$processId] = $parentProcessId
        }
    }
    $seen = [Collections.Generic.HashSet[int64]]::new()
    $current = $CandidateProcessId
    while ($parentByProcess.ContainsKey($current) -and $seen.Add($current)) {
        $parent = [int64]$parentByProcess[$current]
        if ($parent -eq $RootProcessId) { return $true }
        if ($parent -le 0 -or $parent -eq $current) { return $false }
        $current = $parent
    }
    return $false
}

function Resolve-DesktopWebViewListenerAuthority {
    param(
        [Parameter(Mandatory)][int64]$RootProcessId,
        [Parameter(Mandatory)][int]$Port,
        [AllowNull()][string]$BrowserPath,
        [Parameter(Mandatory)]$ProcessSnapshot,
        [Parameter(Mandatory)]$ListenerSnapshot
    )

    Assert-Condition ([string](Get-ObjectPropertyValue -Object $ProcessSnapshot -Name 'kind') -ceq 'processes') 'Desktop process snapshot envelope kind was invalid.'
    Assert-Condition ([string](Get-ObjectPropertyValue -Object $ListenerSnapshot -Name 'kind') -ceq 'listeners') 'Desktop listener snapshot envelope kind was invalid.'
    $processItems = [Collections.Generic.List[object]]::new()
    foreach ($entry in @((Get-ObjectPropertyValue -Object $ProcessSnapshot -Name 'items'))) {
        Assert-Condition ($null -ne $entry) 'Desktop process snapshot envelope contained a null item.'
        $processItems.Add($entry)
    }
    $listeners = [Collections.Generic.List[object]]::new()
    foreach ($entry in @((Get-ObjectPropertyValue -Object $ListenerSnapshot -Name 'items'))) {
        Assert-Condition ($null -ne $entry) 'Desktop listener snapshot envelope contained a null item.'
        if ([int](Get-ObjectPropertyValue -Object $entry -Name 'local_port') -eq $Port) {
            $listeners.Add($entry)
        }
    }
    if ($listeners.Count -eq 0) {
        return [pscustomobject]@{ state = 'listener_missing'; host = $null; port = 0; browser_path = $null }
    }
    $addresses = [Collections.Generic.List[string]]::new()
    $owners = [Collections.Generic.HashSet[int64]]::new()
    foreach ($listener in $listeners) {
        $address = [string](Get-ObjectPropertyValue -Object $listener -Name 'local_address')
        if ($address -cnotin @('127.0.0.1', '::1')) {
            return [pscustomobject]@{ state = 'listener_foreign'; host = $null; port = 0; browser_path = $null }
        }
        $addresses.Add($address)
        [void]$owners.Add([int64](Get-ObjectPropertyValue -Object $listener -Name 'owning_process'))
    }
    if ($owners.Count -ne 1) {
        return [pscustomobject]@{ state = 'listener_ambiguous'; host = $null; port = 0; browser_path = $null }
    }
    [int64]$ownerProcessId = 0
    foreach ($owner in $owners) { $ownerProcessId = $owner }

    $ownerProcesses = [Collections.Generic.List[object]]::new()
    foreach ($processEntry in $processItems) {
        if ([int64](Get-ObjectPropertyValue -Object $processEntry -Name 'process_id') -eq $ownerProcessId) {
            $ownerProcesses.Add($processEntry)
        }
    }
    if ($ownerProcesses.Count -ne 1 -or
        -not (Test-DesktopProcessDescendant -RootProcessId $RootProcessId -CandidateProcessId $ownerProcessId -ProcessSnapshot $ProcessSnapshot) -or
        -not [string]::Equals(
            [string](Get-ObjectPropertyValue -Object $ownerProcesses[0] -Name 'name'),
            'msedgewebview2.exe',
            [StringComparison]::OrdinalIgnoreCase
        )) {
        return [pscustomobject]@{ state = 'listener_foreign'; host = $null; port = 0; browser_path = $null }
    }
    try {
        Initialize-DesktopNativeTypes
        $arguments = @([Winsmux.PublicRelease.WindowsCommandLine]::Parse(
            [string](Get-ObjectPropertyValue -Object $ownerProcesses[0] -Name 'command_line')
        ))
    } catch {
        return [pscustomobject]@{ state = 'browser_identity_invalid'; host = $null; port = 0; browser_path = $null }
    }
    $expectedDebugArgument = "--remote-debugging-port=$Port"
    if (@($arguments | Where-Object { [string]$_ -ceq $expectedDebugArgument }).Count -ne 1 -or
        @($arguments | Where-Object { ([string]$_).StartsWith('--type=', [StringComparison]::Ordinal) }).Count -ne 0) {
        return [pscustomobject]@{ state = 'browser_identity_invalid'; host = $null; port = 0; browser_path = $null }
    }

    $hostName = if ($addresses -ccontains '127.0.0.1') { '127.0.0.1' } else { '[::1]' }
    return [pscustomobject]@{
        state = 'authority_ready'
        host = $hostName
        port = $Port
        browser_path = $BrowserPath
    }
}

function New-DesktopCdpProbeRecord {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'user_data_reparse',
            'port_file_missing',
            'port_file_reparse',
            'port_file_invalid_encoding',
            'port_file_invalid_shape',
            'port_invalid',
            'browser_path_invalid',
            'listener_missing',
            'listener_ambiguous',
            'listener_foreign',
            'browser_identity_invalid',
            'version_identity_mismatch',
            'transport_unavailable',
            'http_error',
            'payload_invalid',
            'page_absent',
            'url_rejected',
            'page_ready'
        )]
        [string]$State,
        [AllowNull()][string]$PageUrl,
        [int]$Port = 0,
        [AllowNull()][ValidateSet('cross_checked', 'shape_verified')][string]$PathAuthority = $null
    )

    $projectedPageUrl = $null
    if ($State -ceq 'page_ready') {
        Assert-ProductionPageUrl -Url ([string]$PageUrl)
        $projectedPageUrl = 'tauri://localhost/'
    }
    return [pscustomobject][ordered]@{
        state = $State
        page_url = $projectedPageUrl
        port = $Port
        path_authority = if ([string]::IsNullOrWhiteSpace($PathAuthority)) { $null } else { [string]$PathAuthority }
        terminal_failure = $State -cin @(
            'user_data_reparse',
            'port_file_reparse',
            'port_file_invalid_encoding',
            'port_file_invalid_shape',
            'port_invalid',
            'browser_path_invalid',
            'listener_ambiguous',
            'listener_foreign',
            'browser_identity_invalid',
            'version_identity_mismatch'
        )
    }
}

function Resolve-DesktopWebSocketPathAuthority {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$WebSocketDebuggerUrl,
        [Parameter(Mandatory)][ValidateSet('127.0.0.1', '[::1]')][string]$HostName,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [AllowNull()][string]$BrowserPath
    )

    [Uri]$webSocketUri = $null
    $expectedHost = $HostName.Trim('[', ']')
    if ([string]::IsNullOrWhiteSpace($WebSocketDebuggerUrl) -or
        -not [Uri]::TryCreate($WebSocketDebuggerUrl, [UriKind]::Absolute, [ref]$webSocketUri) -or
        $webSocketUri.Scheme -cne 'ws' -or
        -not [string]::Equals($webSocketUri.Host.Trim('[', ']'), $expectedHost, [StringComparison]::OrdinalIgnoreCase) -or
        $webSocketUri.Port -ne $Port -or
        -not [string]::IsNullOrEmpty($webSocketUri.Query) -or
        -not [string]::IsNullOrEmpty($webSocketUri.Fragment) -or
        -not [string]::IsNullOrEmpty($webSocketUri.UserInfo)) {
        return [pscustomobject]@{ state = 'version_identity_mismatch' }
    }
    if (-not [string]::IsNullOrWhiteSpace($BrowserPath)) {
        if ($webSocketUri.AbsolutePath -cne $BrowserPath) {
            return [pscustomobject]@{ state = 'version_identity_mismatch' }
        }
        return [pscustomobject]@{ state = 'cross_checked' }
    }
    if ($webSocketUri.AbsolutePath -cnotmatch '^/devtools/browser/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') {
        return [pscustomobject]@{ state = 'version_identity_mismatch' }
    }
    return [pscustomobject]@{ state = 'shape_verified' }
}

function Get-RemoteDebugPage {
    param([Parameter(Mandatory)][int]$Port)

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $response = $null
    $document = $null
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(5)
        try {
            $response = $client.GetAsync("http://127.0.0.1:$Port/json/list").GetAwaiter().GetResult()
        } catch {
            return (New-DesktopCdpProbeRecord -State 'transport_unavailable' -PageUrl $null)
        }
        if (-not $response.IsSuccessStatusCode) {
            return (New-DesktopCdpProbeRecord -State 'http_error' -PageUrl $null)
        }

        try {
            $payload = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $document = [Text.Json.JsonDocument]::Parse($payload)
            if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Array) {
                return (New-DesktopCdpProbeRecord -State 'payload_invalid' -PageUrl $null)
            }
            $pages = @($payload | ConvertFrom-Json -Depth 20)
        } catch {
            return (New-DesktopCdpProbeRecord -State 'payload_invalid' -PageUrl $null)
        }

        $page = @($pages | Where-Object {
            [string](Get-ObjectPropertyValue -Object $_ -Name 'type') -ceq 'page' -and
            -not [string]::IsNullOrWhiteSpace([string](Get-ObjectPropertyValue -Object $_ -Name 'url'))
        } | Select-Object -First 1)
        if ($page.Count -ne 1) {
            return (New-DesktopCdpProbeRecord -State 'page_absent' -PageUrl $null)
        }
        $url = [string](Get-ObjectPropertyValue -Object $page[0] -Name 'url')
        try {
            return (New-DesktopCdpProbeRecord -State 'page_ready' -PageUrl $url)
        } catch {
            return (New-DesktopCdpProbeRecord -State 'url_rejected' -PageUrl $null)
        }
    } finally {
        if ($null -ne $document) {
            $document.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
        $client.Dispose()
    }
}

function Get-VerifiedRemoteDebugPage {
    param(
        [Parameter(Mandatory)][ValidateSet('127.0.0.1', '[::1]')][string]$HostName,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [AllowNull()][string]$BrowserPath,
        [DateTime]$Deadline = [DateTime]::MinValue
    )

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $versionResponse = $null
    $versionDocument = $null
    $listResponse = $null
    $listDocument = $null
    $cancel = $null
    try {
        if ($Deadline -ne [DateTime]::MinValue) {
            $remaining = ($Deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($remaining -le 0) { try { [Console]::Error.WriteLine(('desktop_http_transport stage=initial_deadline remaining_ms={0} exception=none hresult=none' -f $(if ($Deadline -eq [DateTime]::MinValue) { 'none' } else { [Math]::Floor(($Deadline - [DateTime]::UtcNow).TotalMilliseconds).ToString([Globalization.CultureInfo]::InvariantCulture) }))) } catch { }; return (New-DesktopCdpProbeRecord -State 'transport_unavailable' -PageUrl $null -Port $Port) }
            $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMilliseconds($remaining))
        }
        $client.Timeout = [TimeSpan]::FromSeconds(5)
        $client.MaxResponseContentBufferSize = 65536
        try {
            if ($null -ne $cancel) {
                if ([DateTime]::UtcNow -ge $Deadline) { try { [Console]::Error.WriteLine(('desktop_http_transport stage=version_deadline remaining_ms={0} exception=none hresult=none' -f $(if ($Deadline -eq [DateTime]::MinValue) { 'none' } else { [Math]::Floor(($Deadline - [DateTime]::UtcNow).TotalMilliseconds).ToString([Globalization.CultureInfo]::InvariantCulture) }))) } catch { }; return (New-DesktopCdpProbeRecord -State 'transport_unavailable' -PageUrl $null -Port $Port) }
                $versionResponse = $client.GetAsync("http://${HostName}:$Port/json/version", $cancel.Token).GetAwaiter().GetResult()
            } else { $versionResponse = $client.GetAsync("http://${HostName}:$Port/json/version").GetAwaiter().GetResult() }
        } catch {
            try { [Console]::Error.WriteLine(('desktop_http_transport stage=version_request remaining_ms={0} exception={1} hresult={2}' -f $(if ($Deadline -eq [DateTime]::MinValue) { 'none' } else { [Math]::Floor(($Deadline - [DateTime]::UtcNow).TotalMilliseconds).ToString([Globalization.CultureInfo]::InvariantCulture) }), $_.Exception.GetBaseException().GetType().FullName, $_.Exception.GetBaseException().HResult.ToString([Globalization.CultureInfo]::InvariantCulture))) } catch { }
            return (New-DesktopCdpProbeRecord -State 'transport_unavailable' -PageUrl $null -Port $Port)
        }
        if (-not $versionResponse.IsSuccessStatusCode) {
            return (New-DesktopCdpProbeRecord -State 'http_error' -PageUrl $null -Port $Port)
        }

        try {
            $versionPayload = if ($null -ne $cancel) { $versionResponse.Content.ReadAsStringAsync($cancel.Token).GetAwaiter().GetResult() } else { $versionResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
            $versionDocument = [Text.Json.JsonDocument]::Parse($versionPayload)
            if ($versionDocument.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
                return (New-DesktopCdpProbeRecord -State 'payload_invalid' -PageUrl $null -Port $Port)
            }
            $versionRecord = $versionPayload | ConvertFrom-Json -Depth 20
            $webSocketText = [string](Get-ObjectPropertyValue -Object $versionRecord -Name 'webSocketDebuggerUrl')
        } catch {
            return (New-DesktopCdpProbeRecord -State 'payload_invalid' -PageUrl $null -Port $Port)
        }

        $pathAuthority = Resolve-DesktopWebSocketPathAuthority `
            -WebSocketDebuggerUrl $webSocketText `
            -HostName $HostName `
            -Port $Port `
            -BrowserPath $BrowserPath
        if ([string]$pathAuthority.state -ceq 'version_identity_mismatch') {
            return (New-DesktopCdpProbeRecord -State 'version_identity_mismatch' -PageUrl $null -Port $Port)
        }

        try {
            if ($null -ne $cancel) {
                if ([DateTime]::UtcNow -ge $Deadline) { try { [Console]::Error.WriteLine(('desktop_http_transport stage=list_deadline remaining_ms={0} exception=none hresult=none' -f $(if ($Deadline -eq [DateTime]::MinValue) { 'none' } else { [Math]::Floor(($Deadline - [DateTime]::UtcNow).TotalMilliseconds).ToString([Globalization.CultureInfo]::InvariantCulture) }))) } catch { }; return (New-DesktopCdpProbeRecord -State 'transport_unavailable' -PageUrl $null -Port $Port) }
                $listResponse = $client.GetAsync("http://${HostName}:$Port/json/list", $cancel.Token).GetAwaiter().GetResult()
            } else { $listResponse = $client.GetAsync("http://${HostName}:$Port/json/list").GetAwaiter().GetResult() }
        } catch {
            try { [Console]::Error.WriteLine(('desktop_http_transport stage=list_request remaining_ms={0} exception={1} hresult={2}' -f $(if ($Deadline -eq [DateTime]::MinValue) { 'none' } else { [Math]::Floor(($Deadline - [DateTime]::UtcNow).TotalMilliseconds).ToString([Globalization.CultureInfo]::InvariantCulture) }), $_.Exception.GetBaseException().GetType().FullName, $_.Exception.GetBaseException().HResult.ToString([Globalization.CultureInfo]::InvariantCulture))) } catch { }
            return (New-DesktopCdpProbeRecord -State 'transport_unavailable' -PageUrl $null -Port $Port -PathAuthority ([string]$pathAuthority.state))
        }
        if (-not $listResponse.IsSuccessStatusCode) {
            return (New-DesktopCdpProbeRecord -State 'http_error' -PageUrl $null -Port $Port -PathAuthority ([string]$pathAuthority.state))
        }
        try {
            $listPayload = if ($null -ne $cancel) { $listResponse.Content.ReadAsStringAsync($cancel.Token).GetAwaiter().GetResult() } else { $listResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
            $listDocument = [Text.Json.JsonDocument]::Parse($listPayload)
            if ($listDocument.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Array) {
                return (New-DesktopCdpProbeRecord -State 'payload_invalid' -PageUrl $null -Port $Port -PathAuthority ([string]$pathAuthority.state))
            }
            $pages = @($listPayload | ConvertFrom-Json -Depth 20)
        } catch {
            return (New-DesktopCdpProbeRecord -State 'payload_invalid' -PageUrl $null -Port $Port -PathAuthority ([string]$pathAuthority.state))
        }

        $page = @($pages | Where-Object {
            [string](Get-ObjectPropertyValue -Object $_ -Name 'type') -ceq 'page' -and
            -not [string]::IsNullOrWhiteSpace([string](Get-ObjectPropertyValue -Object $_ -Name 'url'))
        } | Select-Object -First 1)
        if ($page.Count -ne 1) {
            return (New-DesktopCdpProbeRecord -State 'page_absent' -PageUrl $null -Port $Port -PathAuthority ([string]$pathAuthority.state))
        }
        $url = [string](Get-ObjectPropertyValue -Object $page[0] -Name 'url')
        try {
            return (New-DesktopCdpProbeRecord -State 'page_ready' -PageUrl $url -Port $Port -PathAuthority ([string]$pathAuthority.state))
        } catch {
            return (New-DesktopCdpProbeRecord -State 'url_rejected' -PageUrl $null -Port $Port -PathAuthority ([string]$pathAuthority.state))
        }
    } finally {
        if ($null -ne $listDocument) { $listDocument.Dispose() }
        if ($null -ne $listResponse) { $listResponse.Dispose() }
        if ($null -ne $versionDocument) { $versionDocument.Dispose() }
        if ($null -ne $versionResponse) { $versionResponse.Dispose() }
        $client.Dispose()
        if ($null -ne $cancel) { $cancel.Dispose() }
    }
}

function Get-DesktopWebViewAuthorityProbe {
    param(
        [Parameter(Mandatory)]$OwnedProcess,
        [Parameter(Mandatory)][string]$UserDataFolder,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [scriptblock]$PortFileSnapshotProvider,
        [scriptblock]$ProcessSnapshotProvider,
        [scriptblock]$ListenerSnapshotProvider,
        [scriptblock]$PageProbe,
        [DateTime]$Deadline = [DateTime]::MinValue
    )

    if ($Deadline -ne [DateTime]::MinValue -and [DateTime]::UtcNow -ge $Deadline) { return (New-DesktopCdpProbeRecord -State 'transport_unavailable' -PageUrl $null -Port $Port) }
    $portRecord = Read-DesktopDevToolsActivePort -UserDataFolder $UserDataFolder -SnapshotProvider $PortFileSnapshotProvider
    if ($Deadline -ne [DateTime]::MinValue -and [DateTime]::UtcNow -ge $Deadline) { return (New-DesktopCdpProbeRecord -State 'transport_unavailable' -PageUrl $null -Port $Port) }
    $portState = [string](Get-ObjectPropertyValue -Object $portRecord -Name 'state')
    $browserPath = $null
    if ($portState -ceq 'authority_ready') {
        if ([int]$portRecord.port -ne $Port) {
            return (New-DesktopCdpProbeRecord -State 'version_identity_mismatch' -PageUrl $null -Port $Port)
        }
        $browserPath = [string]$portRecord.browser_path
    } elseif ($portState -cne 'port_file_missing') {
        return (New-DesktopCdpProbeRecord -State $portState -PageUrl $null)
    }

    $listenerSnapshot = if ($null -eq $ListenerSnapshotProvider) {
        Get-DesktopListenerSnapshot -Port $Port
    } else {
        & $ListenerSnapshotProvider $Port $OwnedProcess
    }
    if ($Deadline -ne [DateTime]::MinValue -and [DateTime]::UtcNow -ge $Deadline) { return (New-DesktopCdpProbeRecord -State 'transport_unavailable' -PageUrl $null -Port $Port) }
    Assert-Condition ($null -ne $listenerSnapshot) 'Desktop listener snapshot envelope was absent.'
    $processSnapshot = if ($null -eq $ProcessSnapshotProvider) {
        Get-DesktopProcessSnapshot
    } else {
        & $ProcessSnapshotProvider $OwnedProcess
    }
    if ($Deadline -ne [DateTime]::MinValue -and [DateTime]::UtcNow -ge $Deadline) { return (New-DesktopCdpProbeRecord -State 'transport_unavailable' -PageUrl $null -Port $Port) }
    Assert-Condition ($null -ne $processSnapshot) 'Desktop process snapshot envelope was absent.'
    $authority = Resolve-DesktopWebViewListenerAuthority `
        -RootProcessId ([int64]$OwnedProcess.process.Id) `
        -Port $Port `
        -BrowserPath $browserPath `
        -ProcessSnapshot $processSnapshot `
        -ListenerSnapshot $listenerSnapshot
    $authorityState = [string](Get-ObjectPropertyValue -Object $authority -Name 'state')
    if ($authorityState -cne 'authority_ready') {
        return (New-DesktopCdpProbeRecord -State $authorityState -PageUrl $null)
    }

    if ($Deadline -ne [DateTime]::MinValue -and [DateTime]::UtcNow -ge $Deadline) { return (New-DesktopCdpProbeRecord -State 'transport_unavailable' -PageUrl $null -Port $Port) }
    $probe = if ($null -eq $PageProbe) {
        if ($Deadline -ne [DateTime]::MinValue) { Get-VerifiedRemoteDebugPage -HostName ([string]$authority.host) -Port ([int]$authority.port) -BrowserPath ([string]$authority.browser_path) -Deadline $Deadline }
        else { Get-VerifiedRemoteDebugPage -HostName ([string]$authority.host) -Port ([int]$authority.port) -BrowserPath ([string]$authority.browser_path) }
    } else {
        & $PageProbe $authority $OwnedProcess
    }
    Assert-Condition ($null -ne $probe) 'Desktop verified page probe returned no result.'
    $probeState = [string](Get-ObjectPropertyValue -Object $probe -Name 'state')
    Assert-Condition ($probeState -cin @(
        'version_identity_mismatch',
        'transport_unavailable',
        'http_error',
        'payload_invalid',
        'page_absent',
        'url_rejected',
        'page_ready'
    )) 'Desktop verified page probe returned an unsupported state.'
    $pageUrl = if ($probeState -ceq 'page_ready') {
        [string](Get-ObjectPropertyValue -Object $probe -Name 'page_url')
    } else {
        $null
    }
    $pathAuthorityValue = Get-ObjectPropertyValue -Object $probe -Name 'path_authority'
    if ($null -eq $pathAuthorityValue -or [string]::IsNullOrWhiteSpace([string]$pathAuthorityValue)) {
        return (New-DesktopCdpProbeRecord -State $probeState -PageUrl $pageUrl -Port ([int]$authority.port))
    }
    return (New-DesktopCdpProbeRecord -State $probeState -PageUrl $pageUrl -Port ([int]$authority.port) -PathAuthority ([string]$pathAuthorityValue))
}

function New-DesktopObservationRecord {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'exited',
            'live_no_cdp',
            'live_cdp_user_data_reparse',
            'live_cdp_port_file_missing',
            'live_cdp_port_file_reparse',
            'live_cdp_port_file_invalid_encoding',
            'live_cdp_port_file_invalid_shape',
            'live_cdp_port_invalid',
            'live_cdp_browser_path_invalid',
            'live_cdp_listener_missing',
            'live_cdp_listener_ambiguous',
            'live_cdp_listener_foreign',
            'live_cdp_browser_identity_invalid',
            'live_cdp_version_identity_mismatch',
            'live_cdp_transport_unavailable',
            'live_cdp_http_error',
            'live_cdp_payload_invalid',
            'live_cdp_page_absent',
            'live_cdp_url_rejected',
            'page_ready'
        )]
        [string]$State,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][int]$Attempts,
        [AllowNull()]$ExitCode,
        [AllowNull()][string]$PageUrl
    )

    return [pscustomobject][ordered]@{
        state = $State
        is_live = $State -cne 'exited'
        has_exited = $State -ceq 'exited'
        exit_code = if ($State -ceq 'exited') { [int]$ExitCode } else { $null }
        port = $Port
        page_present = $State -ceq 'page_ready'
        page_url = if ($State -ceq 'page_ready') { [string]$PageUrl } else { $null }
        attempts = $Attempts
        stdout_present = $false
        stdout_bytes = [long]0
        stdout_truncated = $false
        stderr_present = $false
        stderr_bytes = [long]0
        stderr_truncated = $false
    }
}

function Set-DesktopObservationCaptureMetadata {
    param(
        [Parameter(Mandatory)]$Observation,
        [Parameter(Mandatory)]$OwnedProcess
    )

    $capture = Get-OwnedProcessCapture -OwnedProcess $OwnedProcess
    $stdoutMetadata = $capture.stdout_metadata
    $stderrMetadata = $capture.stderr_metadata
    $Observation.stdout_present = [bool]$stdoutMetadata.present
    $Observation.stdout_bytes = [long]$stdoutMetadata.bytes
    $Observation.stdout_truncated = [bool]$stdoutMetadata.truncated
    $Observation.stderr_present = [bool]$stderrMetadata.present
    $Observation.stderr_bytes = [long]$stderrMetadata.bytes
    $Observation.stderr_truncated = [bool]$stderrMetadata.truncated
    return $capture
}

function Wait-DesktopProcessObservation {
    param(
        [Parameter(Mandatory)]$OwnedProcess,
        [int]$Port = 0,
        [string]$UserDataFolder = '',
        [int]$MaxAttempts = $script:RetryCount,
        [scriptblock]$PageProbe,
        [scriptblock]$AuthorityProbe,
        [scriptblock]$DelayInvoker
    )

    $process = $OwnedProcess.process
    if (-not [string]::IsNullOrWhiteSpace($UserDataFolder)) {
        Assert-Condition ($Port -ge 1 -and $Port -le 65535) 'Typed Desktop observation requires the injected fixed debug port.'
        Assert-Condition ($null -eq $PageProbe) 'Typed Desktop observation requires the authority probe boundary.'
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $attempt = 0
        while ($true) {
            $attempt += 1
            $process.Refresh()
            if ($process.HasExited) {
                return (New-DesktopObservationRecord -State 'exited' -Port $Port -Attempts $attempt -ExitCode $process.ExitCode -PageUrl $null)
            }

            try {
                $probe = if ($null -eq $AuthorityProbe) {
                    Get-DesktopWebViewAuthorityProbe -OwnedProcess $OwnedProcess -UserDataFolder $UserDataFolder -Port $Port
                } else {
                    & $AuthorityProbe $OwnedProcess $UserDataFolder $Port $attempt
                }
            } catch {
                throw [InvalidOperationException]::new('Desktop typed authority probe failed unexpectedly.', $_.Exception)
            }
            Assert-Condition ($null -ne $probe) 'Desktop typed authority probe returned no result.'
            $probeState = [string](Get-ObjectPropertyValue -Object $probe -Name 'state')
            Assert-Condition ($probeState -cin @(
                'user_data_reparse',
                'port_file_missing',
                'port_file_reparse',
                'port_file_invalid_encoding',
                'port_file_invalid_shape',
                'port_invalid',
                'browser_path_invalid',
                'listener_missing',
                'listener_ambiguous',
                'listener_foreign',
                'browser_identity_invalid',
                'version_identity_mismatch',
                'transport_unavailable',
                'http_error',
                'payload_invalid',
                'page_absent',
                'url_rejected',
                'page_ready'
            )) 'Desktop typed authority probe returned an unsupported state.'
            $probePortValue = Get-ObjectPropertyValue -Object $probe -Name 'port'
            $probePort = if ($null -eq $probePortValue) { 0 } else { [int]$probePortValue }

            $process.Refresh()
            if ($process.HasExited) {
                return (New-DesktopObservationRecord -State 'exited' -Port $probePort -Attempts $attempt -ExitCode $process.ExitCode -PageUrl $null)
            }
            if ($probeState -ceq 'page_ready') {
                return (New-DesktopObservationRecord -State 'page_ready' -Port $probePort -Attempts $attempt -ExitCode $null -PageUrl ([string]$probe.page_url))
            }

            $terminalValue = Get-ObjectPropertyValue -Object $probe -Name 'terminal_failure'
            $deadlineReached = $stopwatch.ElapsedMilliseconds -ge $script:DesktopObservationTimeoutMilliseconds
            if ([bool]$terminalValue -or $deadlineReached) {
                return (New-DesktopObservationRecord -State "live_cdp_$probeState" -Port $probePort -Attempts $attempt -ExitCode $null -PageUrl $null)
            }
            if ($null -eq $DelayInvoker) {
                Start-Sleep -Milliseconds $script:DesktopObservationPollMilliseconds
            } else {
                & $DelayInvoker $attempt | Out-Null
            }
        }
    }

    Assert-Condition ($MaxAttempts -ge 1) 'Desktop observation requires at least one attempt.'
    Assert-Condition ($Port -ge 1 -and $Port -le 65535) 'Legacy Desktop observation requires a valid caller-selected port.'
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt += 1) {
        $process.Refresh()
        if ($process.HasExited) {
            return (New-DesktopObservationRecord -State 'exited' -Port $Port -Attempts $attempt -ExitCode $process.ExitCode -PageUrl $null)
        }

        $probe = $null
        $legacyNullProbe = $false
        try {
            $probe = if ($null -eq $PageProbe) {
                Get-RemoteDebugPage -Port $Port
            } else {
                & $PageProbe $Port $attempt $OwnedProcess
            }
        } catch {
            throw [InvalidOperationException]::new('Desktop CDP probe failed unexpectedly.', $_.Exception)
        }

        if ($null -ne $PageProbe -and [string]::IsNullOrWhiteSpace([string]$probe)) {
            $legacyNullProbe = $true
        } elseif ($probe -is [string]) {
            $probe = New-DesktopCdpProbeRecord -State 'page_ready' -PageUrl ([string]$probe)
        } else {
            $probeState = [string](Get-ObjectPropertyValue -Object $probe -Name 'state')
            Assert-Condition ($probeState -cin @(
                'transport_unavailable',
                'http_error',
                'payload_invalid',
                'page_absent',
                'url_rejected',
                'page_ready'
            )) 'Desktop CDP probe returned an unsupported state.'
            if ($probeState -ceq 'page_ready') {
                $probeUrl = [string](Get-ObjectPropertyValue -Object $probe -Name 'page_url')
                $probe = New-DesktopCdpProbeRecord -State 'page_ready' -PageUrl $probeUrl
            }
        }

        $process.Refresh()
        if ($process.HasExited) {
            return (New-DesktopObservationRecord -State 'exited' -Port $Port -Attempts $attempt -ExitCode $process.ExitCode -PageUrl $null)
        }
        if (-not $legacyNullProbe -and [string]$probe.state -ceq 'page_ready') {
            return (New-DesktopObservationRecord -State 'page_ready' -Port $Port -Attempts $attempt -ExitCode $null -PageUrl ([string]$probe.page_url))
        }
        if ($attempt -eq $MaxAttempts) {
            $terminalState = if ($legacyNullProbe) {
                'live_no_cdp'
            } else {
                "live_cdp_$([string]$probe.state)"
            }
            return (New-DesktopObservationRecord -State $terminalState -Port $Port -Attempts $attempt -ExitCode $null -PageUrl $null)
        }
        if ($null -eq $DelayInvoker) {
            Start-Sleep -Seconds $script:RetryDelaySeconds
        } else {
            & $DelayInvoker $attempt | Out-Null
        }
    }
}

function Invoke-DesktopRuntimeExpression {
    param([string]$WebSocketUrl, [string]$Expression, [DateTime]$Deadline = [DateTime]::MinValue)
    $timeout = $script:DesktopObservationTimeoutMilliseconds
    if ($Deadline -ne [DateTime]::MinValue) {
        $remaining = ($Deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0) { throw 'desktop_cdp_evaluation_timeout' }
        $timeout = [Math]::Min($timeout, $remaining)
    }
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMilliseconds($timeout))
    try {
        [void]$socket.ConnectAsync([uri]$WebSocketUrl, $cancel.Token).GetAwaiter().GetResult()
        $id = 1
        $request = @{ id = $id; method = 'Runtime.evaluate'; params = @{ expression = $Expression; returnByValue = $true; awaitPromise = $true } } | ConvertTo-Json -Depth 8 -Compress
        [void]$socket.SendAsync([ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes($request)), [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(65536)
        while (-not $cancel.IsCancellationRequested) {
            $bytes = [Collections.Generic.List[byte]]::new()
            do {
                $part = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $cancel.Token).GetAwaiter().GetResult()
                Assert-Condition ($part.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Text) 'desktop_cdp_response_invalid'
                Assert-Condition (($bytes.Count + $part.Count) -le 65536) 'desktop_cdp_response_oversized'
                for ($i = 0; $i -lt $part.Count; $i++) { $bytes.Add($buffer[$i]) }
            } while (-not $part.EndOfMessage)
            $response = ConvertFrom-DesktopStrictJsonText ([Text.UTF8Encoding]::new($false, $true).GetString($bytes.ToArray()))
            if ([string](Get-ObjectPropertyValue $response 'id') -cne $id) { continue }
            Assert-Condition ($null -eq (Get-ObjectPropertyValue $response 'error') -and $null -eq (Get-ObjectPropertyValue $response.result 'exceptionDetails')) 'desktop_cdp_evaluation_failed'
            Assert-Condition ($response.result.result.type -ceq 'string') 'desktop_cdp_evaluation_invalid'
            return ([string]$response.result.result.value | ConvertFrom-Json -Depth 30)
        }
        throw 'desktop_cdp_evaluation_timeout'
    } finally { $socket.Dispose(); $cancel.Dispose() }
}

function Format-DesktopStartupDiagnostic {
    param($Value)
    $fallback = 'startup=missing view=absent host=unavailable attempt=unknown stability=unavailable'
    try {
        $sets = [ordered]@{
            startup = @('root_missing','missing','invalid','connecting','mounted','unconfirmed','unknown','recovering','disposed')
            view = @('root_missing','absent','present')
            host = @('unavailable','invalid','Empty','Opening','Ready','Busy','Stopping','Unknown','ForcePrompt','Finishing','FailedClosed','MainClosed','ExitReleased')
            attempt = @('unknown','zero','nonzero')
            stability = @('unavailable','changed','stable')
        }
        if ($Value -is [string]) {
            $parts = $Value.Split(' ')
            if ($parts.Count -ne $sets.Count) { return $fallback }
            $index = 0
            foreach ($key in $sets.Keys) {
                $pair = $parts[$index++].Split('=')
                if ($pair.Count -ne 2 -or $pair[0] -cne $key -or $pair[1] -cnotin $sets[$key]) { return $fallback }
            }
            return $Value
        }
        if ($Value -isnot [pscustomobject]) { return $fallback }
        $properties = @($Value.PSObject.Properties)
        if ($properties.Count -ne $sets.Count) { return $fallback }
        foreach ($key in $sets.Keys) {
            $property = $Value.PSObject.Properties[$key]
            if ($properties.Name -cnotcontains $key -or $null -eq $property -or $property.MemberType -ne 'NoteProperty' -or $property.Value -isnot [string] -or $property.Value -cnotin $sets[$key]) { return $fallback }
        }
        $tokens = foreach ($key in $sets.Keys) { $key + '=' + $Value.PSObject.Properties[$key].Value }
        return ($tokens -join ' ')
    } catch { return $fallback }
}

function Get-DesktopStartupDiagnostic {
    param($Context, [int]$Port, [string]$UserDataFolder, [DateTime]$Deadline = [DateTime]::MinValue)
    if ($Deadline -eq [DateTime]::MinValue -or [DateTime]::UtcNow -ge $Deadline) { return $null }
    $authority = Get-DesktopWebViewAuthorityProbe -OwnedProcess $Context.app_process -UserDataFolder $UserDataFolder -Port $Port -Deadline $Deadline
    if ([string]$authority.state -cne 'page_ready' -or [DateTime]::UtcNow -ge $Deadline) { return $null }
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler); $cancel = $null
    try {
        $remaining = ($Deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0) { return $null }
        $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMilliseconds($remaining))
        $client.Timeout = [TimeSpan]::FromSeconds(5); $client.MaxResponseContentBufferSize = 65536
        $pages = $client.GetStringAsync("http://127.0.0.1:$Port/json/list", $cancel.Token).GetAwaiter().GetResult() | ConvertFrom-Json -Depth 12
    } finally { $client.Dispose(); if ($null -ne $cancel) { $cancel.Dispose() } }
    if ([DateTime]::UtcNow -ge $Deadline) { return $null }
    $matching = @($pages | Where-Object { [string]$_.type -ceq 'page' -and [string]$_.url -match '^(?:tauri://localhost|https?://tauri\.localhost)/?$' })
    Assert-Condition ($matching.Count -eq 1) 'desktop_main_page_ambiguous'
    $ws = [uri][string]$matching[0].webSocketDebuggerUrl
    Assert-Condition ($ws.Scheme -ceq 'ws' -and $ws.Host -ceq '127.0.0.1' -and $ws.Port -eq $Port -and $ws.AbsolutePath -match '^/devtools/page/[A-Za-z0-9-]+$' -and [string]::IsNullOrEmpty($ws.Query) -and [string]::IsNullOrEmpty($ws.Fragment) -and [string]::IsNullOrEmpty($ws.UserInfo)) 'desktop_page_websocket_invalid'
    $expression = @'
(async () => {
 const phases=['Empty','Opening','Ready','Busy','Stopping','Unknown','ForcePrompt','Finishing','FailedClosed','MainClosed','ExitReleased'];
 const startupStates=['connecting','mounted','unconfirmed','unknown','recovering','disposed'];
 const closed=(v,k)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).length===k.length&&k.every(x=>Object.hasOwn(v,x));
 const uuid=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);
 const u64=v=>typeof v==='string'&&/^(0|[1-9][0-9]{0,19})$/.test(v)&&BigInt(v)<=18446744073709551615n;
 const result={startup:'missing',view:'absent',host:'unavailable',attempt:'unknown',stability:'unavailable'};
 const finish=()=>JSON.stringify(result);
 const invoke=window.__TAURI__?.core?.invoke,label=window.__TAURI_INTERNALS__?.metadata?.currentWindow?.label;
 if(typeof invoke!=='function'||label!=='main'||window.top!==window||location.search||!/^https?:\/\/tauri\.localhost\/?$|^tauri:\/\/localhost\/?$/.test(location.href))return finish();
 const snapshot=()=>{
  const root=document.getElementById('workspace-startup'),view=root?.querySelector('.workspace-project-pane')??null;
  return {root,view,rootConnected:root?.isConnected,viewConnected:view?.isConnected,startup:root?.dataset.startupState,session:root?.dataset.session,generation:root?.dataset.generation,viewGeneration:view?.dataset?.generation,viewInstance:view?.dataset?.instanceId};
 };
 const before=snapshot();
 result.startup=!before.root?'root_missing':before.startup===undefined?'missing':typeof before.startup==='string'&&startupStates.includes(before.startup)?before.startup:'invalid';
 result.view=!before.root?'root_missing':before.view?'present':'absent';
 try {
  const host=await invoke('workspace_host_status');
  if(!closed(host,['instance_id','generation','revision','phase'])||(host.instance_id!==null&&!uuid(host.instance_id))||!u64(host.generation)||!u64(host.revision)||typeof host.phase!=='string'||!phases.includes(host.phase))result.host='invalid';
  else {result.host=host.phase;result.attempt=host.generation==='0'?'zero':'nonzero';}
 } catch { }
 const after=snapshot();
 result.stability=Object.keys(before).every(k=>before[k]===after[k])?'stable':'changed';
 return finish();
})()
'@
    if ([DateTime]::UtcNow -ge $Deadline) { return $null }
    return (Invoke-DesktopRuntimeExpression -WebSocketUrl $ws.AbsoluteUri -Expression $expression -Deadline $Deadline)
}

function Get-DesktopWorkspaceRuntime {
    param($Context, [int]$Port, [string]$UserDataFolder, [DateTime]$DiagnosticDeadline = [DateTime]::MinValue)
    # Recheck the listener ownership at action time before opening its page websocket.
    $authority = Get-DesktopWebViewAuthorityProbe -OwnedProcess $Context.app_process -UserDataFolder $UserDataFolder -Port $Port
    Assert-Condition ([string]$authority.state -ceq 'page_ready') 'desktop_cdp_authority_unconfirmed'
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(5); $client.MaxResponseContentBufferSize = 65536
    try { $pages = $client.GetStringAsync("http://127.0.0.1:$Port/json/list").GetAwaiter().GetResult() | ConvertFrom-Json -Depth 12 }
    finally { $client.Dispose() }
    $matching = @($pages | Where-Object { [string]$_.type -ceq 'page' -and [string]$_.url -match '^(?:tauri://localhost|https?://tauri\.localhost)/?$' })
    Assert-Condition ($matching.Count -eq 1) 'desktop_main_page_ambiguous'
    $ws = [uri][string]$matching[0].webSocketDebuggerUrl
    Assert-Condition ($ws.Scheme -ceq 'ws' -and $ws.Host -ceq '127.0.0.1' -and $ws.Port -eq $Port -and $ws.AbsolutePath -match '^/devtools/page/[A-Za-z0-9-]+$' -and [string]::IsNullOrEmpty($ws.Query) -and [string]::IsNullOrEmpty($ws.Fragment) -and [string]::IsNullOrEmpty($ws.UserInfo)) 'desktop_page_websocket_invalid'
    $expression = @'
(async () => {
 const closed=(v,k)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).length===k.length&&k.every(x=>Object.hasOwn(v,x));
 const uuid=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);
 const uint=v=>Number.isSafeInteger(v)&&v>=0;
 const invoke=window.__TAURI__?.core?.invoke, label=window.__TAURI_INTERNALS__?.metadata?.currentWindow?.label;
 const root=document.getElementById('workspace-startup'), view=root?.querySelector('.workspace-project-pane');
  const fail=stage=>JSON.stringify({ok:false,stage});
  if(!invoke)return fail('invoke_unavailable');
  if(label!=='main'||window.top!==window)return fail('window_binding_invalid');
  if(location.search||!/^https?:\/\/tauri\.localhost\/?$|^tauri:\/\/localhost\/?$/.test(location.href))return fail('location_invalid');
  if(!root)return fail('startup_root_missing');
  if(!view)return fail('project_view_missing');
  if(root.dataset.startupState!=='mounted')return fail('startup_not_mounted');
  if(view.dataset.availability!=='available')return fail('project_view_unavailable');
  let session;try{session=JSON.parse(root.dataset.session);}catch{return fail('session_json_invalid');}
  if(!closed(session,['instance_id','schema_version'])||!uuid(session.instance_id)||session.schema_version!==1||session.instance_id!==view.dataset.instanceId||!uuid(root.dataset.generation)||root.dataset.generation!==view.dataset.generation)return fail('session_binding_invalid');
 const identity=JSON.stringify([root.dataset.session,root.dataset.generation,view.dataset.topologyRevision,view.dataset.selectedProjectId]);
 const stable=()=>root.isConnected&&view.isConnected&&root.dataset.startupState==='mounted'&&view.dataset.availability==='available'&&identity===JSON.stringify([root.dataset.session,root.dataset.generation,view.dataset.topologyRevision,view.dataset.selectedProjectId]);
  const revision=Number(view.dataset.topologyRevision);if(!uint(revision))return fail('topology_revision_invalid');
  let stage='unclassified';
  async function read(operation){const request={schema_version:1,instance_id:session.instance_id,operation_id:crypto.randomUUID(),expected_topology_revision:null,operation,params:{}};
   if(!stable()){stage='runtime_changed';throw 0;}stage=operation==='capabilities.get'?'capabilities_read_failed':'projects_read_failed';
   const response=await invoke('workspace_request',{requestJson:JSON.stringify(request)});
   if(!stable()){stage='runtime_changed';throw 0;}
   if(!closed(response,['schema_version','instance_id','operation_id','accepted','topology_revision','event_seq','result','error'])||response.schema_version!==1||response.instance_id!==session.instance_id||response.operation_id!==request.operation_id||response.accepted!==true||response.error!==null||!uint(response.event_seq)||response.topology_revision!==revision||!closed(response.result,['operation','data'])||response.result.operation!==operation)throw 0;return response.result.data;
  }
  try{const caps=await read('capabilities.get'), projects=await read('project.list');
   stage='capabilities_invalid';
   if(!closed(caps,['max_message_bytes','operations','providers','replay_capacity','schema_version','shell_profile_ids'])||caps.schema_version!==1||!Array.isArray(caps.operations)||!caps.operations.includes('project.list'))return fail(stage);
   stage='projects_invalid';
   if(!closed(projects,['projects','selected_project_id'])||!Array.isArray(projects.projects)||(projects.selected_project_id!==null&&!uuid(projects.selected_project_id))||(projects.selected_project_id??'')!==view.dataset.selectedProjectId||!projects.projects.every(p=>closed(p,['project_id','display_name','path','root_state'])&&uuid(p.project_id)&&(p.display_name===null||typeof p.display_name==='string')&&(p.path===null||typeof p.path==='string')&&['verified','unavailable','changed','unknown'].includes(p.root_state)))return fail(stage);
   stage='discovery_read_failed';
   const discovery=await invoke('workspace_discovery_get');
   if(!stable())return fail('runtime_changed');
   if(!closed(discovery,['instance_id','pipe_name','schema_version'])||discovery.instance_id!==session.instance_id||discovery.schema_version!==1||typeof discovery.pipe_name!=='string'||!discovery.pipe_name)return fail('discovery_invalid');
  return JSON.stringify({ok:true,instance_id:session.instance_id,generation:root.dataset.generation,revision,discovery});
  }catch{return fail(stage);}
})()
'@
    $result = Invoke-DesktopRuntimeExpression -WebSocketUrl $ws.AbsoluteUri -Expression $expression
    try { Assert-Condition ((Get-ObjectPropertyValue $result 'ok') -eq $true) 'desktop_workspace_read_unconfirmed' }
    catch {
        if ($_.Exception.Message -ceq 'desktop_workspace_read_unconfirmed') {
            $failure = $_.Exception
            try {
                # Read the property value directly: a pipeline-returned singleton
                # array would otherwise become a string and pass the finite check.
                $stage = $null
                $stageProperty = $result.PSObject.Properties['stage']
                if ($null -ne $stageProperty) { $stage = $stageProperty.Value }
                $allowed = @('invoke_unavailable','window_binding_invalid','location_invalid','startup_root_missing','project_view_missing','startup_not_mounted','project_view_unavailable','session_json_invalid','session_binding_invalid','topology_revision_invalid','runtime_changed','capabilities_read_failed','projects_read_failed','capabilities_invalid','projects_invalid','discovery_read_failed','discovery_invalid','unclassified')
                $failure.Data['winsmux_workspace_mount_stage'] = if ($stage -is [string] -and $stage -cin $allowed) { $stage } else { 'unclassified' }
            } catch { }
            try {
                $diagnostic = Get-DesktopStartupDiagnostic -Context $Context -Port $Port -UserDataFolder $UserDataFolder -Deadline $DiagnosticDeadline
                $failure.Data['winsmux_workspace_startup_diagnostic'] = Format-DesktopStartupDiagnostic $diagnostic
            } catch { }
        }
        throw
    }
    return $result
}

function Wait-DesktopWorkspaceRuntime {
    param($Context, [int]$Port, [string]$UserDataFolder)
    $lastStage = 'unclassified'
    $lastDiagnostic = Format-DesktopStartupDiagnostic $null
    $deadline = [DateTime]::UtcNow.AddMilliseconds($script:DesktopObservationTimeoutMilliseconds)
    do {
        try { return (Get-DesktopWorkspaceRuntime -Context $Context -Port $Port -UserDataFolder $UserDataFolder -DiagnosticDeadline $deadline) }
        catch {
            if ($_.Exception.Message -cne 'desktop_workspace_read_unconfirmed') { throw }
            $lastDiagnostic = Format-DesktopStartupDiagnostic $_.Exception.Data['winsmux_workspace_startup_diagnostic']
            try {
                $stage = $_.Exception.Data['winsmux_workspace_mount_stage']
                $allowed = @('invoke_unavailable','window_binding_invalid','location_invalid','startup_root_missing','project_view_missing','startup_not_mounted','project_view_unavailable','session_json_invalid','session_binding_invalid','topology_revision_invalid','runtime_changed','capabilities_read_failed','projects_read_failed','capabilities_invalid','projects_invalid','discovery_read_failed','discovery_invalid','unclassified')
                $lastStage = if ($stage -is [string] -and $stage -cin $allowed) { $stage } else { 'unclassified' }
            } catch { $lastStage = 'unclassified' }
        }
        Start-Sleep -Milliseconds $script:DesktopObservationPollMilliseconds
    } while ([DateTime]::UtcNow -lt $deadline -and -not $Context.app_process.process.HasExited)
    try { [Console]::Error.WriteLine('desktop_workspace_mount_probe stage=' + $lastStage + ' ' + $lastDiagnostic) } catch { }
    throw 'desktop_workspace_mount_unconfirmed'
}

function Assert-DesktopMcpResponse {
    param($Response, [string]$Id)
    Assert-DesktopInventoryShape $Response @('jsonrpc', 'id', 'result')
    Assert-Condition ($Response.jsonrpc -ceq '2.0' -and [string]$Response.id -ceq $Id -and $null -eq (Get-ObjectPropertyValue $Response 'error') -and $null -ne (Get-ObjectPropertyValue $Response 'result')) 'desktop_mcp_response_uncorrelated'
}

function Invoke-DesktopInstalledMcp {
    param($Context, [hashtable]$Environment, $Workspace)
    $owned = Start-OwnedProcess -FilePath (Join-Path $Context.install_root 'winsmux-workspace-mcp.exe') -ArgumentList @('--discovery-json', ($Workspace.discovery | ConvertTo-Json -Compress)) -Environment $Environment -Interactive
    $process = $owned.owner
    try {
        function Send-DesktopMcp($Request) { $process.StandardInput.WriteLine(($Request | ConvertTo-Json -Depth 20 -Compress)); $process.StandardInput.Flush() }
        function Read-DesktopMcp {
            $task = $process.ReadLineAsync($script:DesktopMcpMessageLimitBytes)
            Assert-Condition ($task.Wait($script:DesktopObservationTimeoutMilliseconds)) 'desktop_mcp_response_timeout'
            $line = $task.GetAwaiter().GetResult()
            Assert-Condition ($null -ne $line -and [Text.Encoding]::UTF8.GetByteCount($line) -le $script:DesktopMcpMessageLimitBytes) 'desktop_mcp_response_invalid'
            return (ConvertFrom-DesktopStrictJsonText $line)
        }
        $initId = [Guid]::NewGuid().ToString('D')
        Send-DesktopMcp @{ jsonrpc = '2.0'; id = $initId; method = 'initialize'; params = @{ protocolVersion = '2025-11-25'; capabilities = @{}; clientInfo = @{ name = 'winsmux-desktop-install-smoke'; version = '1' } } }
        $init = Read-DesktopMcp; Assert-DesktopMcpResponse $init $initId
        Assert-DesktopInventoryShape $init.result @('protocolVersion','capabilities','serverInfo')
        Assert-DesktopInventoryShape $init.result.serverInfo @('name','version')
        Assert-DesktopInventoryShape $init.result.capabilities @('tools')
        Assert-DesktopInventoryShape $init.result.capabilities.tools @()
        Assert-Condition ($init.result.protocolVersion -ceq '2025-11-25' -and $init.result.serverInfo.name -ceq 'winsmux-workspace-mcp' -and $init.result.serverInfo.version -ceq $Version -and $null -ne (Get-ObjectPropertyValue $init.result.capabilities 'tools')) 'desktop_mcp_initialize_invalid'
        Send-DesktopMcp @{ jsonrpc = '2.0'; method = 'notifications/initialized' }
        $listId = [Guid]::NewGuid().ToString('D'); Send-DesktopMcp @{ jsonrpc = '2.0'; id = $listId; method = 'tools/list' }
        $list = Read-DesktopMcp; Assert-DesktopMcpResponse $list $listId
        Assert-DesktopInventoryShape $list.result @('tools')
        Assert-Condition (@($list.result.tools).Count -eq 1 -and $list.result.tools[0].name -ceq 'winsmux_workspace_request' -and $list.result.tools[0].inputSchema.type -ceq 'object' -and $list.result.tools[0].outputSchema.type -ceq 'object') 'desktop_mcp_tools_invalid'
        Assert-DesktopInventoryShape $list.result.tools[0] @('name','inputSchema','outputSchema')
        $callId = [Guid]::NewGuid().ToString('D'); $operationId = [Guid]::NewGuid().ToString('D')
        Send-DesktopMcp @{ jsonrpc = '2.0'; id = $callId; method = 'tools/call'; params = @{ name = 'winsmux_workspace_request'; arguments = @{ schema_version = 1; instance_id = $Workspace.instance_id; operation_id = $operationId; expected_topology_revision = $null; operation = 'capabilities.get'; params = @{} } } }
        $call = Read-DesktopMcp; Assert-DesktopMcpResponse $call $callId; $response = $call.result.structuredContent
        Assert-DesktopInventoryShape $call.result @('structuredContent','content','isError')
        Assert-DesktopInventoryShape $response @('schema_version','instance_id','operation_id','accepted','topology_revision','event_seq','result','error')
        Assert-DesktopInventoryShape $response.result @('operation','data')
        Assert-Condition ($call.result.isError -eq $false -and $response.schema_version -eq 1 -and $response.instance_id -ceq $Workspace.instance_id -and $response.operation_id -ceq $operationId -and $response.accepted -eq $true -and $null -eq $response.error -and $response.result.operation -ceq 'capabilities.get' -and $response.topology_revision -eq $Workspace.revision) 'desktop_mcp_host_read_unconfirmed'
        Assert-Condition (@($call.result.content).Count -eq 1 -and $call.result.content[0].type -ceq 'text') 'desktop_mcp_content_invalid'
        Assert-DesktopInventoryShape $call.result.content[0] @('type','text')
        $textResponse = ConvertFrom-DesktopStrictJsonText ([string]$call.result.content[0].text)
        Assert-Condition (($textResponse | ConvertTo-Json -Depth 30 -Compress) -ceq ($response | ConvertTo-Json -Depth 30 -Compress)) 'desktop_mcp_content_mismatch'
        $process.FinishInputAndDrain()
        Assert-Condition ($process.WaitTerminal($script:DesktopObservationTimeoutMilliseconds, $script:DesktopObservationPollMilliseconds) -and $process.ExitCode -eq 0 -and -not $process.Forced) 'desktop_mcp_eof_exit_unconfirmed'
        Assert-Condition ($process.StdoutTask.GetAwaiter().GetResult().TotalBytes -eq 0 -and $process.StderrTask.GetAwaiter().GetResult().TotalBytes -eq 0) 'desktop_mcp_terminal_output_invalid'
        return $true
    } catch {
        $failure = $_.Exception
        try { $process.ForceFailureCleanup($script:DesktopObservationTimeoutMilliseconds, $script:DesktopObservationPollMilliseconds) }
        catch { $failure.Data['cleanup_failure'] = $_.Exception }
        throw $failure
    } finally {
        if ($process.HasExited -and $process.ActiveMembers -eq 0 -and $process.CaptureCompleted) { $process.Dispose() }
    }
}

function Stop-DesktopNormally {
    param($RootProcess)
    if ($null -eq $RootProcess) { return }
    Assert-Condition ($null -ne (Get-ObjectPropertyValue $RootProcess 'owner')) 'desktop_owner_missing'
    $owner = $RootProcess.owner
    Assert-Condition (-not $owner.HasExited) 'desktop_normal_close_app_already_exited'
    Assert-Condition $owner.CloseMainWindow() 'desktop_normal_close_refused'
    if ($null -ne $script:DesktopRuntimeReceipt) { $script:DesktopRuntimeReceipt.normal_close_requested = $true }
    $owner.RequireNormalCompletion($script:DesktopObservationTimeoutMilliseconds, $script:DesktopObservationPollMilliseconds)
    if ($null -ne $script:DesktopRuntimeReceipt) { $script:DesktopRuntimeReceipt.owned_processes_exited = $true }
}

function Invoke-DesktopLifecycleOperation {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][hashtable]$Environment,
        [int]$Port = 0,
        [string]$UserDataFolder = '',
        [int]$MaxAttempts = $script:RetryCount,
        [scriptblock]$PageProbe,
        [scriptblock]$AuthorityProbe,
        [scriptblock]$DelayInvoker,
        [scriptblock]$StopInvoker,
        [scriptblock]$UninstallInvoker,
        [scriptblock]$ResidueInvoker,
        [scriptblock]$RootRemover
    )

    $observation = $null
    $operationFailure = $null
    $cleanupFailure = $null
    $captureFailure = $null
    $capture = $null
    $pendingObservationFailure = $false
    $teardownDiagnosis = $null
    try {
        $observation = Wait-DesktopProcessObservation -OwnedProcess $Context.app_process -Port $Port -UserDataFolder $UserDataFolder `
            -MaxAttempts $MaxAttempts -PageProbe $PageProbe -AuthorityProbe $AuthorityProbe -DelayInvoker $DelayInvoker
        if ([string]$observation.state -cne 'page_ready') {
            $pendingObservationFailure = $true
        }
        if (-not $pendingObservationFailure -and $null -eq $PageProbe -and (Get-ObjectPropertyValue $Context 'workspace_generation') -eq $true) {
            $script:DesktopFailureStage = 'workspace_runtime'
            $workspace = Wait-DesktopWorkspaceRuntime -Context $Context -Port $Port -UserDataFolder $UserDataFolder
            $script:DesktopFailureStage = 'mcp_runtime'
            $mcp = Invoke-DesktopInstalledMcp -Context $Context -Environment $Environment -Workspace $workspace
            $again = Get-DesktopWorkspaceRuntime -Context $Context -Port $Port -UserDataFolder $UserDataFolder
            Assert-Condition ($again.instance_id -ceq $workspace.instance_id -and $again.generation -ceq $workspace.generation -and $again.discovery.pipe_name -ceq $workspace.discovery.pipe_name) 'desktop_workspace_generation_changed'
            $script:DesktopRuntimeReceipt = [ordered]@{ workspace_read_verified = $true; mcp_roundtrip_verified = $true; mcp_eof_exit_verified = $true; normal_close_requested = $false; owned_processes_exited = $false }
        }
        if (-not [string]::IsNullOrWhiteSpace($UserDataFolder)) {
            try {
                $teardownDiagnosis = Get-DesktopTeardownDiagnosis -UserDataFolder $UserDataFolder -RootProcessId ([long]$Context.app_process.process.Id) -DebugPort $Port
            } catch {
                $teardownDiagnosis = $null
            }
            if ($null -ne $teardownDiagnosis) {
                try {
                    Write-DesktopProbeDiagnosticsLine -Diagnosis $teardownDiagnosis | Out-Null
                } catch {
                    # diagnostics emission must never mask the run outcome
                }
            }
        }
    } catch {
        $operationFailure = $_.Exception
    } finally {
        try {
            $operationErrorMessage = if ($null -eq $operationFailure) { '' } else { $operationFailure.Message }
            Invoke-DesktopCleanup -Context $Context -Environment $Environment -OperationErrorMessage $operationErrorMessage `
                -StopInvoker $StopInvoker -UninstallInvoker $UninstallInvoker -ResidueInvoker $ResidueInvoker -RootRemover $RootRemover | Out-Null
        } catch {
            $cleanupFailure = $_.Exception
        }
        if ($null -ne $observation -and $Context.app_process.process.HasExited) {
            try {
                $capture = Set-DesktopObservationCaptureMetadata -Observation $observation -OwnedProcess $Context.app_process
            } catch {
                $captureFailure = $_.Exception
            }
        }
    }

    if ($null -ne $captureFailure -and $null -eq $operationFailure) {
        $operationFailure = $captureFailure
    }
    if ($pendingObservationFailure -and $null -eq $operationFailure) {
        if ($null -eq $capture) {
            $failure = [InvalidOperationException]::new('Desktop child output capture did not become terminal after cleanup.')
        } else {
            $diagnosticResult = [pscustomobject]@{
                exit_code = $observation.exit_code
                stdout_metadata = $capture.stdout_metadata
                stderr_metadata = $capture.stderr_metadata
            }
            $message = Format-PublicChildProcessDiagnostic -Operation 'desktop_observer' -State ([string]$observation.state) -Result $diagnosticResult
            if ($null -ne $teardownDiagnosis) {
                try {
                    $message = '{0} {1}' -f $message, (Get-DesktopTeardownDiagnosisSegment -Diagnosis $teardownDiagnosis)
                } catch {
                    # privacy/allowlist assert failure must not mask the original failure
                }
            }
            $failure = [InvalidOperationException]::new($message)
        }
        $failure.Data['observation'] = $observation
        $failure.Data['original_exception'] = $failure
        $operationFailure = $failure
    }

    if ($null -ne $operationFailure -and $null -ne $cleanupFailure) {
        $aggregate = [System.AggregateException]::new('Desktop observation and cleanup failed.', [Exception[]]@($operationFailure, $cleanupFailure))
        $aggregate.Data['operation_failure'] = $operationFailure
        $aggregate.Data['cleanup_failure'] = $cleanupFailure
        throw $aggregate
    }
    if ($null -ne $operationFailure) {
        throw $operationFailure
    }
    if ($null -ne $cleanupFailure) {
        $cleanupFailure.Data['operation_failure'] = $null
        $cleanupFailure.Data['cleanup_failure'] = $cleanupFailure
        throw $cleanupFailure
    }
    return $observation
}

function Invoke-CoreSmoke {
    param([Parameter(Mandatory)][string]$Root)

    $coreAssetNames = @(Get-CoreReleaseAssetNames)
    $baseUrl = "https://github.com/$Repository/releases/download/$ReleaseTag"
    $manifestPath = Join-Path $Root 'SHA256SUMS'
    Invoke-PublicDownload -Uri "$baseUrl/SHA256SUMS" -Destination $manifestPath -Root $Root
    $assetPaths = [ordered]@{}
    foreach ($assetName in $coreAssetNames) {
        $assetPath = Join-Path $Root $assetName
        $assetPaths[$assetName] = $assetPath
        Invoke-PublicDownload -Uri "$baseUrl/$assetName" -Destination $assetPath -Root $Root
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
    $expectedHashes = [ordered]@{}
    foreach ($assetName in $coreAssetNames) {
        $expectedHashes[$assetName] = Get-ChecksumEntry -ManifestText $manifest -AssetName $assetName
    }
    foreach ($assetName in $coreAssetNames) {
        Assert-FileChecksum -Path $assetPaths[$assetName] -ExpectedHash $expectedHashes[$assetName]
    }

    $environment = New-PublicIsolatedProfile -Root $Root -Surface 'Core'
    $executedAssetName = $coreAssetNames[0]
    Assert-Condition ($executedAssetName -ceq 'winsmux-x64.exe') 'Core executable inventory did not keep x64 as the runnable asset.'
    $expectedProgramName = [IO.Path]::GetFileNameWithoutExtension($executedAssetName)
    $result = Invoke-PublicChildProcess -Operation 'core_version' -FilePath $assetPaths[$executedAssetName] -ArgumentList @('--version') -Environment $environment -TimeoutSeconds 30
    Assert-CoreVersionResult -Result $result -ExpectedProgramName $expectedProgramName -ExpectedVersion $Version
    return [ordered]@{
        asset = $executedAssetName
        sha256 = $expectedHashes[$executedAssetName]
        version = $Version
        verified_assets = @($coreAssetNames)
    }
}

function Resolve-NpmPathPrecedenceToolchain {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$NodeCandidates,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$TarCandidates
    )

    $candidates = @($NodeCandidates)
    Assert-Condition ($candidates.Count -ge 1) 'No Node application was found on PATH.'
    $nodePath = [string]$candidates[0].Source
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($nodePath)) 'The first PATH-precedence Node application did not expose Source.'
    Assert-Condition (Test-Path -LiteralPath $nodePath -PathType Leaf) "The first PATH-precedence Node application was not found: $nodePath"

    $npmCliPath = Join-Path (Split-Path -Parent $nodePath) 'node_modules\npm\bin\npm-cli.js'
    Assert-Condition (Test-Path -LiteralPath $npmCliPath -PathType Leaf) "npm CLI was not found next to the first PATH-precedence Node application: $npmCliPath"

    $tarCandidates = @($TarCandidates)
    Assert-Condition ($tarCandidates.Count -ge 1) 'No tar application was found on PATH.'
    $tarPath = [string]$tarCandidates[0].Source
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($tarPath)) 'The first PATH-precedence tar application did not expose Source.'
    Assert-Condition (Test-Path -LiteralPath $tarPath -PathType Leaf) "The first PATH-precedence tar application was not found: $tarPath"
    return [pscustomobject]@{
        node_path = $nodePath
        npm_cli_path = $npmCliPath
        tar_path = $tarPath
    }
}

function Invoke-NpmProcessOperation {
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('npm_view', 'npm_pack', 'tar_list', 'tar_extract', 'npm_help')]
        [string]$Operation,
        [Parameter(Mandatory, Position = 1)][string]$FilePath,
        [Parameter(Position = 2, ValueFromRemainingArguments = $true)][object[]]$ProcessArguments = @(),
        [hashtable]$Environment = @{},
        [scriptblock]$ProcessInvoker
    )

    if ($null -ne $ProcessInvoker) {
        return (& $ProcessInvoker $Operation $FilePath @($ProcessArguments))
    }
    $timeout = if ($Operation -ceq 'npm_pack') { 120 } else { 90 }
    return Invoke-PublicChildProcess -Operation $Operation -FilePath $FilePath -ArgumentList @($ProcessArguments) -Environment $Environment -TimeoutSeconds $timeout
}

function Invoke-NpmSmoke {
    param(
        [Parameter(Mandatory)][string]$Root,
        [object[]]$NodeCandidates,
        [object[]]$TarCandidates,
        [scriptblock]$ProcessInvoker
    )

    if (-not $PSBoundParameters.ContainsKey('NodeCandidates')) {
        $nodeCandidates = @(Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue)
    }
    if (-not $PSBoundParameters.ContainsKey('TarCandidates')) {
        $tarCandidates = @(Get-Command tar.exe -CommandType Application -ErrorAction SilentlyContinue)
    }
    $npmToolchain = Resolve-NpmPathPrecedenceToolchain -NodeCandidates $nodeCandidates -TarCandidates $tarCandidates
    $node = [string]$npmToolchain.node_path
    $npmCli = [string]$npmToolchain.npm_cli_path
    $npmEnvironment = New-PublicIsolatedProfile -Root $Root -Surface 'Npm'
    $npmEnvironment.NPM_CONFIG_CACHE = Join-Path $Root 'npm-cache'
    $npmEnvironment.NPM_CONFIG_PREFIX = Join-Path $Root 'npm-prefix'
    $npmEnvironment.NPM_CONFIG_USERCONFIG = Join-Path $Root 'npmrc'
    $npmEnvironment.NPM_CONFIG_AUDIT = 'false'
    $npmEnvironment.NPM_CONFIG_FUND = 'false'
    $npmEnvironment.NPM_CONFIG_UPDATE_NOTIFIER = 'false'
    New-Item -ItemType Directory -Path @(
        $npmEnvironment.NPM_CONFIG_CACHE,
        $npmEnvironment.NPM_CONFIG_PREFIX
    ) | Out-Null
    Set-Content -LiteralPath $npmEnvironment.NPM_CONFIG_USERCONFIG -Value 'registry=https://registry.npmjs.org/' -Encoding ascii

    $metadataResult = Invoke-Retry -Description 'npm registry metadata' -Operation {
        $result = Invoke-NpmProcessOperation -Operation 'npm_view' -FilePath $node -ProcessArguments @(
            $npmCli,
            'view',
            "winsmux@$Version",
            'version',
            'dist.integrity',
            '--json',
            '--registry=https://registry.npmjs.org/'
        ) -Environment $npmEnvironment -ProcessInvoker $ProcessInvoker
        if ($result.exit_code -ne 0) {
            throw (Format-PublicChildProcessDiagnostic -Operation 'npm_view' -State 'exit_nonzero' -Result $result)
        }
        try {
            $metadata = $result.stdout | ConvertFrom-Json -Depth 20
        } catch {
            throw (Format-PublicChildProcessDiagnostic -Operation 'npm_view' -State 'parse_failed' -Result $result)
        }
        try {
            Assert-NpmMetadata -Metadata $metadata -ExpectedVersion $Version
        } catch {
            throw (Format-PublicChildProcessDiagnostic -Operation 'npm_view' -State 'content_invalid' -Result $result)
        }
        return $metadata
    }
    $integrity = Get-NpmIntegrity -Metadata $metadataResult

    $packRecord = Invoke-Retry -Description 'npm public tarball' -Operation {
        $packResult = Invoke-NpmProcessOperation -Operation 'npm_pack' -FilePath $node -ProcessArguments @(
            $npmCli,
            'pack',
            "winsmux@$Version",
            '--pack-destination',
            $Root,
            '--json',
            '--registry=https://registry.npmjs.org/'
        ) -Environment $npmEnvironment -ProcessInvoker $ProcessInvoker
        if ($packResult.exit_code -ne 0) {
            throw (Format-PublicChildProcessDiagnostic -Operation 'npm_pack' -State 'exit_nonzero' -Result $packResult)
        }
        try {
            $packData = @($packResult.stdout | ConvertFrom-Json -Depth 20)
        } catch {
            throw (Format-PublicChildProcessDiagnostic -Operation 'npm_pack' -State 'parse_failed' -Result $packResult)
        }
        if ($packData.Count -ne 1) {
            throw (Format-PublicChildProcessDiagnostic -Operation 'npm_pack' -State 'content_invalid' -Result $packResult)
        }
        $packedIntegrity = [string](Get-ObjectPropertyValue -Object $packData[0] -Name 'integrity')
        if ($packedIntegrity -cne $integrity) {
            throw (Format-PublicChildProcessDiagnostic -Operation 'npm_pack' -State 'content_invalid' -Result $packResult)
        }
        return $packData[0]
    }
    $filename = [string](Get-ObjectPropertyValue -Object $packRecord -Name 'filename')
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($filename)) 'npm pack did not report a tarball filename.'
    $tarballPath = Get-CanonicalPath -Path (Join-Path $Root $filename)
    Assert-Condition (Test-PathInsideRoot -Path $tarballPath -Root $Root) 'npm tarball escaped the owned root.'
    Assert-Condition (Test-Path -LiteralPath $tarballPath -PathType Leaf) 'npm pack reported a tarball filename, but the archive was not created.'

    $extractRoot = Join-Path $Root 'unpacked'
    New-Item -ItemType Directory -Path $extractRoot | Out-Null
    $listing = Invoke-NpmProcessOperation -Environment $npmEnvironment -ProcessInvoker $ProcessInvoker 'tar_list' $npmToolchain.tar_path -tf $tarballPath
    if ($listing.exit_code -ne 0) {
        throw (Format-PublicChildProcessDiagnostic -Operation 'tar_list' -State 'exit_nonzero' -Result $listing)
    }
    $archiveEntries = @($listing.stdout -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    try {
        Assert-SafeNpmArchiveEntries -Entries $archiveEntries
    } catch {
        throw (Format-PublicChildProcessDiagnostic -Operation 'tar_list' -State 'content_invalid' -Result $listing)
    }
    $extract = Invoke-NpmProcessOperation -Environment $npmEnvironment -ProcessInvoker $ProcessInvoker 'tar_extract' $npmToolchain.tar_path -xf $tarballPath -C $extractRoot
    if ($extract.exit_code -ne 0) {
        throw (Format-PublicChildProcessDiagnostic -Operation 'tar_extract' -State 'exit_nonzero' -Result $extract)
    }
    $reparseEntries = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -Force | Where-Object {
        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    })
    Assert-Condition ($reparseEntries.Count -eq 0) "Public npm tarball materialized $($reparseEntries.Count) reparse point(s)."

    $packageRoot = Join-Path $extractRoot 'package'
    $packageJsonPath = Join-Path $packageRoot 'package.json'
    $entryPath = Join-Path $packageRoot 'index.mjs'
    $installScriptPath = Join-Path $packageRoot 'install.ps1'
    Assert-Condition (Test-Path -LiteralPath $packageJsonPath -PathType Leaf) 'Public npm tarball omitted package.json.'
    Assert-Condition (Test-Path -LiteralPath $entryPath -PathType Leaf) 'Public npm tarball omitted index.mjs.'
    Assert-Condition (Test-Path -LiteralPath $installScriptPath -PathType Leaf) 'Public npm tarball omitted install.ps1.'
    foreach ($publicPath in @($packageRoot, $packageJsonPath, $entryPath, $installScriptPath)) {
        $item = Get-Item -LiteralPath $publicPath -Force
        Assert-Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Public npm tarball materialized a reparse point: $publicPath"
    }
    $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    Assert-Condition ([string]$packageJson.name -ceq 'winsmux') "Public tarball package name was '$($packageJson.name)'."
    Assert-Condition ([string]$packageJson.version -ceq $Version) "Public tarball version was '$($packageJson.version)'."
    Assert-Condition ([string]$packageJson.winsmuxReleaseTag -ceq $ReleaseTag) "Public tarball release tag was '$($packageJson.winsmuxReleaseTag)'."

    $help = Invoke-NpmProcessOperation -Operation 'npm_help' -FilePath $node -ProcessArguments @($entryPath, 'help') -Environment $npmEnvironment -ProcessInvoker $ProcessInvoker
    Assert-NpmHelpResult -Result $help
    return [ordered]@{
        package = "winsmux@$Version"
        integrity = $integrity
        release_tag = $ReleaseTag
        node_path = $node
        npm_cli_path = $npmCli
    }
}

function Invoke-DesktopSmoke {
    param([Parameter(Mandatory)][string]$Root)

    $script:DesktopRunOwnedRoot = Get-CanonicalPath -Path $Root
    $installRoot = Join-Path $Root 'installed'
    $context = New-DesktopLifecycleContext -OwnedRoot $Root -InstallRoot $installRoot -ExpectedVersion $Version
    $script:DesktopLifecycle = $context
    $assetName = "winsmux_$($Version)_x64-setup.exe"
    $baseUrl = "https://github.com/$Repository/releases/download/$ReleaseTag"
    $manifestPath = Join-Path $Root 'SHA256SUMS-desktop'
    $setupPath = Join-Path $Root $assetName
    $priorSetupPath = Join-Path $Root 'prior-setup.exe'
    $expectedHash = ''
    $childEnvironment = @{}
    $observation = $null
    $routerInventory = $null
    $routerPolicy = $null
    $inventoryAsset = "winsmux_${Version}_x64-setup.inventory.json"
    $inventoryPath = Join-Path $Root $inventoryAsset
    $inventory = $null
    $inventoryHash = ''
    $setupFailure = $null
    try {
        Assert-DesktopRunner
        $routerPolicy = Resolve-DesktopRouterInventoryPolicy -Version $Version -ReleaseTag $ReleaseTag -CandidateInstallerPath $CandidateInstallerPath
        $context | Add-Member -NotePropertyName workspace_generation -NotePropertyValue ($routerPolicy.generation -ceq 'workspace')
        $initial = Get-DesktopProtectedState -InstallRoot $installRoot
        Start-DesktopLifecycle -Context $context -PreflightState $initial

        if (-not [string]::IsNullOrEmpty($CandidateInstallerPath)) {
            Assert-Condition (-not [string]::IsNullOrEmpty($DesktopInventoryPath)) 'desktop_candidate_inventory_missing'
            Copy-Item -LiteralPath $CandidateInstallerPath -Destination $setupPath
            Copy-Item -LiteralPath $DesktopInventoryPath -Destination $inventoryPath
            $expectedHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if (-not [string]::IsNullOrEmpty($PriorInstallerPath)) {
                Copy-Item -LiteralPath $PriorInstallerPath -Destination $priorSetupPath
            }
        } else {
            Invoke-PublicDownload -Uri "$baseUrl/SHA256SUMS-desktop" -Destination $manifestPath -Root $Root
            Invoke-PublicDownload -Uri "$baseUrl/$assetName" -Destination $setupPath -Root $Root
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
            $expectedHash = Get-ChecksumEntry -ManifestText $manifest -AssetName $assetName
            Assert-FileChecksum -Path $setupPath -ExpectedHash $expectedHash
            if ($routerPolicy.generation -ceq 'workspace') {
                Invoke-PublicDownload -Uri "$baseUrl/$inventoryAsset" -Destination $inventoryPath -Root $Root
                Assert-FileChecksum -Path $inventoryPath -ExpectedHash (Get-ChecksumEntry -ManifestText $manifest -AssetName $inventoryAsset)
            }
        }
        if ($routerPolicy.generation -ceq 'workspace') {
            $script:DesktopFailureStage = 'generation_inventory'
            $treeish = if (-not [string]::IsNullOrEmpty($CandidateInstallerPath)) { 'HEAD' } else { "$ReleaseTag^{commit}" }
            $sourceCommit = (& git -C $script:RepositoryRoot rev-parse --verify $treeish | Out-String).Trim().ToLowerInvariant()
            Assert-Condition ($LASTEXITCODE -eq 0 -and $sourceCommit -cmatch '^[a-f0-9]{40}$') 'desktop_inventory_source_unavailable'
            $inventory = Assert-DesktopInstallInventory -Inventory (Read-DesktopStrictJson $inventoryPath) -Version $Version -InstallerSha256 $expectedHash -SourceCommit $sourceCommit
            $inventoryHash = (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }

        $childRoot = Join-Path $Root 'profile'
        $childEnvironment = New-PublicIsolatedProfile -Root $Root -Surface 'Desktop'
        $childEnvironment.WINSMUX_ORCHESTRA_ATTACH_MODE = 'desktop-app'
        $childEnvironment.WINSMUX_ORCHESTRA_DISABLE_POWERSHELL_ATTACH = '1'
        $childEnvironment.WINSMUX_ORCHESTRA_DISABLE_WINDOWS_TERMINAL_ATTACH = '1'
        $childEnvironment.WINSMUX_CODEX_LAUNCHER = ''

        Set-DesktopLifecyclePhase -Context $context -NextPhase 'installer_started'
        $priorAppHash = ''
        $installerStages = [Collections.Generic.List[object]]::new()
        if (-not [string]::IsNullOrEmpty($PriorInstallerPath)) {
            $priorContext = New-DesktopLifecycleContext -OwnedRoot $Root -InstallRoot $installRoot -ExpectedVersion $PriorVersion
            Set-DesktopLifecyclePhase -Context $priorContext -NextPhase 'preflight_clean'
            Set-DesktopLifecyclePhase -Context $priorContext -NextPhase 'installer_started'
            $installerStages.Add([pscustomobject]@{ role = 'prior'; path = $priorSetupPath; context = $priorContext }) | Out-Null
        }
        $installerStages.Add([pscustomobject]@{ role = 'candidate'; path = $setupPath; context = $context }) | Out-Null
        foreach ($stage in $installerStages) {
            $script:DesktopFailureStage = if ([string]$stage.role -ceq 'prior') { 'prior_install' } else { 'candidate_install' }
            $install = Invoke-DesktopNsisProcess -Operation 'desktop_installer' -FilePath ([string]$stage.path) -Context $stage.context -Environment $childEnvironment
            if ($install.exit_code -ne 0) {
                $failure = [InvalidOperationException]::new('desktop_installer_exit_nonzero')
                $failure.Data['native_result'] = $install
                throw $failure
            }
            Assert-DesktopMaterializedOwnership -Context $stage.context
            if ([string]$stage.role -ceq 'prior') {
                Set-DesktopLifecyclePhase -Context $stage.context -NextPhase 'materialized_verified'
                $priorAppHash = (Get-FileHash -LiteralPath (Join-Path $installRoot 'winsmux-app.exe') -Algorithm SHA256).Hash
                continue
            }
            if (-not [string]::IsNullOrEmpty($PriorInstallerPath)) {
                $candidateAppHash = (Get-FileHash -LiteralPath (Join-Path $installRoot 'winsmux-app.exe') -Algorithm SHA256).Hash
                Assert-Condition (-not [string]::Equals($priorAppHash, $candidateAppHash, [StringComparison]::OrdinalIgnoreCase)) 'Candidate over-install did not replace the prior winsmux-app.exe payload.'
            }
            Set-DesktopLifecyclePhase -Context $context -NextPhase 'materialized_verified'
            if ($routerPolicy.required) {
                $routerInventory = Get-DesktopRouterInventory -InstallRoot $installRoot -Treeish $routerPolicy.treeish
            }
            if ($routerPolicy.generation -ceq 'workspace') {
                $script:DesktopFailureStage = 'installed_inventory'
                $script:DesktopInstalledInventory = Get-DesktopInstalledInventory -InstallRoot $installRoot -Inventory $inventory -InventorySha256 $inventoryHash
            }
        }

        $webViewRoot = Join-Path $childRoot 'WebView2'
        New-Item -ItemType Directory -Path $webViewRoot | Out-Null
        $debugEndpoint = New-DesktopFixedDebugEndpoint
        $childEnvironment.WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = Get-DesktopLegacyBrowserArgumentsValue -Mode $DesktopLegacyEnvMode -DebugArgument ([string]$debugEndpoint.argument)
        $childEnvironment.WINSMUX_DESKTOP_TEST_PROFILE = 'public-smoke'
        $childEnvironment.WINSMUX_DESKTOP_REMOTE_DEBUG_PORT = [string]$debugEndpoint.port
        $childEnvironment.WEBVIEW2_USER_DATA_FOLDER = $webViewRoot

        $context.app_process = Start-OwnedProcess -FilePath (Join-Path $installRoot 'winsmux-app.exe') -Environment $childEnvironment
        $script:DesktopFailureStage = 'cdp_observation'
        $observation = Invoke-DesktopLifecycleOperation -Context $context -Environment $childEnvironment -Port ([int]$debugEndpoint.port) -UserDataFolder $webViewRoot
    } catch {
        $setupFailure = $_.Exception
        if ($null -ne $context.app_process) {
            throw $setupFailure
        }
        $setupCleanupFailure = $null
        try {
            Invoke-DesktopCleanup -Context $context -Environment $childEnvironment -OperationErrorMessage $setupFailure.Message | Out-Null
        } catch {
            $setupCleanupFailure = $_.Exception
        }
        if ($null -ne $setupCleanupFailure) {
            $aggregate = [AggregateException]::new('Desktop setup and cleanup failed.', [Exception[]]@($setupFailure, $setupCleanupFailure))
            $aggregate.Data['operation_failure'] = $setupFailure
            $aggregate.Data['cleanup_failure'] = $setupCleanupFailure
            throw $aggregate
        }
        throw $setupFailure
    }
    Assert-DesktopLifecyclePhase -Context $context -ExpectedPhase 'clean'
    $script:DesktopRouterInventory = $routerInventory
    return [ordered]@{
        asset = $assetName
        sha256 = $expectedHash
        version = $Version
        page_url = [string]$observation.page_url
    }
}

function Test-Throws {
    param([Parameter(Mandatory)][scriptblock]$Operation)

    try {
        & $Operation | Out-Null
        return $false
    } catch {
        return $true
    }
}



function Get-DesktopNativeTransportModule {
    return @'
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
const [mode,sourceCommit,format,repoArgument]=process.argv.slice(1);
const need=(v,r)=>{if(!v)throw new Error(r);};
const digest=b=>createHash('sha256').update(b).digest('hex');
const sameKeys=(v,k)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).sort().join('\0')===k.slice().sort().join('\0');
need(['create','verify'].includes(mode)&&/^[a-f0-9]{40}$/.test(sourceCommit)&&['MSI','NSIS'].includes(format),'native_transport_request_refused');
need(sourceCommit===process.env.GITHUB_SHA&&process.env.GITHUB_ACTIONS==='true'&&process.env.RUNNER_OS==='Windows'&&/^[1-9][0-9]*$/.test(process.env.GITHUB_RUN_ID??'')&&/^[1-9][0-9]*$/.test(process.env.GITHUB_RUN_ATTEMPT??''),'native_transport_caller_refused');
const repo=path.resolve(repoArgument);
const { physicalPath }=await import(pathToFileURL(path.join(repo,'scripts/distribution-prelaunch.mjs')));
const { parseStrictJson }=await import(pathToFileURL(path.join(repo,'scripts/assert-license-inputs.mjs')));
const { assertCanonicalBundledDistribution }=await import(pathToFileURL(path.join(repo,'scripts/stage-bundled-distribution.mjs')));
const { assertDesktopBundleNamespace }=await import(pathToFileURL(path.join(repo,'scripts/stage-desktop-msi-plan.mjs')));
const { assertWindowsRuntime }=await import(pathToFileURL(path.join(repo,'scripts/assert-windows-runtime.mjs')));
const head=spawnSync('git',['-C',repo,'rev-parse','HEAD'],{encoding:'utf8',windowsHide:true});
need(!head.error&&head.status===0&&head.stdout.trim()===sourceCommit,'native_transport_source_refused');
const diff=spawnSync('git',['-C',repo,'diff','--exit-code','--no-ext-diff','HEAD','--'],{windowsHide:true});
need(!diff.error&&diff.status===0,'native_transport_tracked_source_changed');
const root=path.join(path.resolve(process.env.RUNNER_TEMP),'winsmux-native-input-'+process.env.GITHUB_RUN_ID+'.'+process.env.GITHUB_RUN_ATTEMPT+'.'+sourceCommit+'.'+format);
const directory=p=>{const s=fs.lstatSync(p,{bigint:true});need(s.isDirectory()&&!s.isSymbolicLink()&&s.dev>=0n&&s.ino>0n&&physicalPath(p)===p,'native_transport_plain_directory_required');return s.dev+':'+s.ino;};
const plain=p=>{need(physicalPath(p)===p,'native_transport_physical_file_required');const s=fs.lstatSync(p,{bigint:true});need(s.isFile()&&!s.isSymbolicLink()&&s.nlink===1n&&s.dev>=0n&&s.ino>0n,'native_transport_single_link_required');const b=fs.readFileSync(p);const t=fs.lstatSync(p,{bigint:true});need(s.dev===t.dev&&s.ino===t.ino&&s.size===t.size&&b.length===Number(s.size),'native_transport_readback_changed');return b;};
const originDirectoryIds=new Map();for(const p of [repo,root,path.join(root,'build'),path.join(root,'build/release'),path.join(root,'sdk-temp'),path.join(root,'candidate')])originDirectoryIds.set(p,directory(p));
const release=path.join(root,'build/release'),candidate=path.join(root,'candidate'),src=path.join(repo,'winsmux-app/src-tauri'),canonical=path.join(src,'binaries'),gui=path.join(release,'winsmux-app.exe');
const phasePath=gui+'.winsmux-bundle-phase.json';const phaseBytes=plain(phasePath),phase=parseStrictJson(phaseBytes);
assertDesktopBundleNamespace(gui);
need(sameKeys(phase,['schema','invocation_id','gui_path','host','version','signed','generation_manifest_sha256','input_gui_sha256','input_app_lib_sha256','sdk_temp_root','expected_pre_sign','phase','records','prior_pairs'])&&phase.schema==='winsmux-desktop-bundle-phase/v1'&&phase.gui_path===gui&&phase.host==='x86_64-pc-windows-msvc'&&phase.version==='0.38.0'&&phase.signed===false&&phase.phase==='frozen'&&phase.sdk_temp_root===path.join(root,'sdk-temp')&&sameKeys(phase.expected_pre_sign,['msi','nsis'])&&phase.expected_pre_sign.msi===null&&phase.expected_pre_sign.nsis===null&&Array.isArray(phase.prior_pairs)&&phase.prior_pairs.length===0&&Array.isArray(phase.records)&&phase.records.length===2&&phase.records[0].flavor==='msi'&&phase.records[1].flavor==='nsis','native_transport_phase_refused');
const manifestPath=path.join(canonical,'distribution-manifest.json'),manifestBytes=plain(manifestPath),manifest=parseStrictJson(manifestBytes);
const binding=parseStrictJson(plain(path.join(repo,'distribution/windows-licenses/binding.json')));
assertCanonicalBundledDistribution({repoRoot:repo,host:phase.host,version:phase.version,rustcCommit:binding.rustc_commit,projectOutput:release});
need(digest(manifestBytes)===phase.generation_manifest_sha256,'native_transport_generation_changed');
const mapping=[
 ['installer_msi_en','winsmux_0.38.0_x64_en-US.msi',path.join(release,'bundle/msi/winsmux_0.38.0_x64_en-US.msi')],
 ['installer_msi_ja','winsmux_0.38.0_x64_ja-JP.msi',path.join(release,'bundle/msi/winsmux_0.38.0_x64_ja-JP.msi')],
 ['installer_nsis_setup','winsmux_0.38.0_x64-setup.exe',path.join(release,'bundle/nsis/winsmux_0.38.0_x64-setup.exe')],
 ['plan_msi','winsmux-msi-plan.json',gui+'.winsmux-msi-plan.json'],
 ['plan_nsis','winsmux-nsis-plan.json',gui+'.winsmux-nsis-plan.json'],
 ['pe_gui_original','winsmux-app.exe',gui],['pe_app_lib','winsmux_app_lib.dll',path.join(release,'winsmux_app_lib.dll')],
 ['pe_cli','winsmux.exe',path.join(canonical,'winsmux-x86_64-pc-windows-msvc.exe')],
 ['pe_mcp','winsmux-workspace-mcp.exe',path.join(canonical,'winsmux-workspace-mcp-x86_64-pc-windows-msvc.exe')]
];
const sources=new Map(mapping.map(([role,name,p])=>[role,plain(p)]));
const identities=mapping.map(([role,name])=>({role,path:name,bytes:sources.get(role).length,sha256:digest(sources.get(role))}));
const plans={msi:parseStrictJson(sources.get('plan_msi')),nsis:parseStrictJson(sources.get('plan_nsis'))};
// Complete required license inventory/bytes are owned by assertCanonicalBundledDistribution above.
const { selectTransportLicenseRows }=await import(pathToFileURL(path.join(repo,'scripts/desktop-native-nsis-observer.mjs')));
const licenseRows=selectTransportLicenseRows(manifest);
for(const flavor of ['msi','nsis']) {
 const record=phase.records.find(r=>r.flavor===flavor),plan=plans[flavor];
 need(sameKeys(record,['flavor','gui_sha256','plan_sha256','include_sha256','compiler_inputs_ready','artifacts'])&&record.compiler_inputs_ready===true&&Array.isArray(record.artifacts),'native_transport_record_refused');
 const planBytes=sources.get('plan_'+flavor);need(digest(planBytes)===record.plan_sha256,'native_transport_plan_changed');
 need(sameKeys(plan,['schema','flavor','version','host','files'])&&plan.schema==='winsmux-desktop-install-plan/v1'&&plan.flavor===flavor&&plan.version==='0.38.0'&&plan.host===phase.host&&Array.isArray(plan.files)&&Buffer.from(JSON.stringify(plan,null,2)+'\n').equals(planBytes),'native_transport_plan_encoding_refused');
 const roles=[['gui','winsmux-app.exe','pe_gui_original'],['cli','winsmux.exe','pe_cli'],['mcp','winsmux-workspace-mcp.exe','pe_mcp']];if(flavor==='msi')roles.push(['app_lib','winsmux_app_lib.dll','pe_app_lib']);
 const expected=[...licenseRows,...roles.map(([role,name,sourceRole])=>({role,path:name,bytes:sources.get(sourceRole).length,sha256:role==='gui'?record.gui_sha256:digest(sources.get(sourceRole))}))].sort((a,b)=>a.path<b.path?-1:a.path>b.path?1:0);
 need(JSON.stringify(plan.files)===JSON.stringify(expected),'native_transport_plan_inventory_changed');
 need(plan.files.find(r=>r.role==='gui').sha256===record.gui_sha256,'native_transport_gui_plan_changed');
 const includePath=flavor==='msi'?gui+'.winsmux-plan.wxi':gui+'.winsmux-nsis-plan.nsh';need(digest(plain(includePath))===record.include_sha256,'native_transport_include_changed');
 const artifacts=flavor==='msi'?[['en-US','installer_msi_en'],['ja-JP','installer_msi_ja']]:[['setup','installer_nsis_setup']];
 need(record.artifacts.length===artifacts.length,'native_transport_artifact_set_refused');
 for(const [output,role] of artifacts){const rows=record.artifacts.filter(a=>a.output===output);need(rows.length===1&&sameKeys(rows[0],['output','bytes','sha256'])&&rows[0].bytes===sources.get(role).length&&rows[0].sha256===digest(sources.get(role)),'native_transport_artifact_changed');}
}
const original=sources.get('pe_gui_original'),marker=Buffer.from('__TAURI_BUNDLE_TYPE_VAR_'),at=original.indexOf(marker);
need(at>=0&&original.indexOf(marker,at+1)<0&&at+marker.length+3<=original.length&&original.subarray(at+marker.length,at+marker.length+3).toString('ascii')==='UNK'&&digest(original)===phase.input_gui_sha256,'native_transport_original_gui_changed');
for(const [flavor,tag] of [['msi','MSI'],['nsis','NSS']]){const projected=Buffer.from(original);projected.write(tag,at+marker.length,3,'ascii');need(digest(projected)===phase.records.find(r=>r.flavor===flavor).gui_sha256,'native_transport_gui_projection_changed');}
need(digest(sources.get('pe_app_lib'))===phase.input_app_lib_sha256,'native_transport_app_library_changed');
for(const role of ['pe_gui_original','pe_app_lib','pe_cli','pe_mcp'])assertWindowsRuntime(sources.get(role),phase.host);
const receipt={schema:'winsmux-desktop-native-ci-candidate/v1',source_commit:sourceCommit,version:'0.38.0',release_tag:'v0.38.0',host:phase.host,run_id:process.env.GITHUB_RUN_ID,run_attempt:process.env.GITHUB_RUN_ATTEMPT,format,build_phase_sha256:digest(phaseBytes),generation_manifest_sha256:digest(manifestBytes),files:identities};
const receiptName='desktop-native-candidate.json',allowed=new Set([...mapping.map(r=>r[1]),receiptName]);
const checkNamespace=()=>{const names=fs.readdirSync(candidate);need(names.length===allowed.size&&new Set(names.map(x=>x.toLowerCase())).size===names.length&&names.every(x=>allowed.has(x)),'native_transport_candidate_namespace_refused');};
if(mode==='create') {
 need(fs.readdirSync(candidate).length===0,'native_transport_candidate_not_empty');
 for(const [role,name] of mapping){const b=sources.get(role);fs.writeFileSync(path.join(candidate,name),b,{flag:'wx'});need(plain(path.join(candidate,name)).equals(b),'native_transport_copy_readback_changed');}
 const b=Buffer.from(JSON.stringify(receipt,null,2)+'\n');fs.writeFileSync(path.join(candidate,receiptName),b,{flag:'wx'});need(plain(path.join(candidate,receiptName)).equals(b),'native_transport_receipt_readback_changed');
}
checkNamespace();const receiptBytes=plain(path.join(candidate,receiptName));const received=parseStrictJson(receiptBytes);
need(sameKeys(received,['schema','source_commit','version','release_tag','host','run_id','run_attempt','format','build_phase_sha256','generation_manifest_sha256','files'])&&Array.isArray(received.files)&&received.files.length===9&&received.files.every(r=>sameKeys(r,['role','path','bytes','sha256'])&&Number.isSafeInteger(r.bytes)&&r.bytes>0&&/^[a-f0-9]{64}$/.test(r.sha256))&&Buffer.from(JSON.stringify(receipt,null,2)+'\n').equals(receiptBytes),'native_transport_receipt_refused');
for(const [role,name,p] of mapping)need(plain(p).equals(sources.get(role))&&plain(path.join(candidate,name)).equals(sources.get(role)),'native_transport_source_or_copy_changed');
need(plain(phasePath).equals(phaseBytes)&&plain(manifestPath).equals(manifestBytes),'native_transport_origin_changed');
for(const [p,id] of originDirectoryIds)need(directory(p)===id,'native_transport_directory_replaced');
console.log(JSON.stringify({schema:'winsmux-desktop-native-transport-check/v1',mode,source_commit:sourceCommit,format,files:9,receipt_sha256:digest(receiptBytes),build_phase_sha256:digest(phaseBytes),generation_manifest_sha256:digest(manifestBytes),runtime_pe_count:4}));
'@
}










function Initialize-DesktopNativeLifecycleActor {
    if ($null -ne ([Management.Automation.PSTypeName]'WinsmuxDesktopNativeActor').Type) { return }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$errors)
    Assert-Condition (@($errors).Count -eq 0) 'desktop_native_source_parse_refused'
    $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq 'actorCSharp' }, $true))
    Assert-Condition ($definitions.Count -eq 1) 'desktop_native_actor_definition_refused'
    Assert-Condition ($definitions[0].Right -is [Management.Automation.Language.CommandExpressionAst] -and $definitions[0].Right.Expression -is [Management.Automation.Language.StringConstantExpressionAst] -and $definitions[0].Right.Expression.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString) 'desktop_native_actor_literal_refused'
    $actor = [string]$definitions[0].Right.Expression.Value
    $actor = $actor.Replace('public static class WinsmuxDesktopActorProbe {', 'public static class WinsmuxDesktopNativeActor {').Replace('sealed class TokenFacts {', 'internal sealed class TokenFacts {').Replace('struct PI {', 'internal struct PI {')
    $closing = $actor.LastIndexOf('}')
    Assert-Condition ($closing -gt 0) 'desktop_native_actor_source_refused'
    $native = @'

 [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool CreateProcessW(string app,StringBuilder command,IntPtr psa,IntPtr tsa,bool inherit,uint flags,IntPtr env,string cwd,ref SI startup,out PI process);
 static string Quote(string value) { if(value==null||value.IndexOf('\0')>=0||value.IndexOf('\r')>=0||value.IndexOf('\n')>=0)throw new InvalidOperationException("Native argument refused");var b=new StringBuilder("\"");int slashes=0;foreach(char c in value){if(c=='\\'){slashes++;continue;}if(c=='\"'){b.Append('\\',slashes*2+1).Append(c);slashes=0;continue;}b.Append('\\',slashes).Append(c);slashes=0;}return b.Append('\\',slashes*2).Append('"').ToString(); }
 public static string NativeCommand(string purpose,string image,string root,string source,string candidate,string baseline,string script) {
  image=Path.GetFullPath(image);root=Path.GetFullPath(root);if(root.IndexOf('"')>=0||root.IndexOf('\r')>=0||root.IndexOf('\n')>=0||root.IndexOf(" _?=",StringComparison.OrdinalIgnoreCase)>=0)throw new InvalidOperationException("Native root refused");
  switch(purpose) {
   case "msi-nsis-conflict":
   case "nsis-fresh":return Quote(image)+" /S /D="+root;
   case "nsis-update":return Quote(image)+" /S /UPDATE /D="+root;
   case "nsis-fresh-no-shortcuts":return Quote(image)+" /S /NS /D="+root;
   case "nsis-update-no-shortcuts":return Quote(image)+" /S /UPDATE /NS /D="+root;
   case "nsis-uninstall":return Quote(image)+" /S";
   case "msi-capacity-install-en":
   case "msi-capacity-update-ja":
   case "msi-capacity-uninstall":
   case "msi-install-en":
   case "msi-update-ja":
   case "msi-uninstall":
    if(!String.Equals(image,Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"msiexec.exe"),StringComparison.OrdinalIgnoreCase)||!candidate.EndsWith(".msi",StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Native MSI entry refused");
    bool uninstall=purpose=="msi-uninstall"||purpose=="msi-capacity-uninstall";bool capacity=purpose=="msi-capacity-install-en"||purpose=="msi-capacity-update-ja";
    return Quote(image)+(uninstall?" /x ":" /i ")+Quote(Path.GetFullPath(candidate))+" /qn /norestart"+(uninstall?"":" INSTALLDIR="+Quote(root))+(capacity?" ADDLOCAL=MainProgram,Environment":"")+" /l*v "+Quote(Path.Combine(Path.GetDirectoryName(root),purpose+".log"));
   case "medium-bootstrap":
    if(source==null||source.Length!=40||source!=Environment.GetEnvironmentVariable("GITHUB_SHA")||Path.GetFileName(image).ToLowerInvariant()!="pwsh.exe")throw new InvalidOperationException("Native bootstrap source refused");
    return Quote(image)+" -NoLogo -NoProfile -NonInteractive -File "+Quote(Path.GetFullPath(script))+" -Surface Desktop -Version 0.38.0 -ReleaseTag v0.38.0 -Repository Sora-bluesky/winsmux -DesktopNativeLifecycle -DesktopNativeFormat NSIS -DesktopNativeSourceCommit "+source+" -DesktopNativeCandidateDirectory "+Quote(Path.GetFullPath(candidate))+" -DesktopNativeBaselineDirectory "+Quote(Path.GetFullPath(baseline))+" -Json";
   default:throw new InvalidOperationException("Native purpose refused");
  }
 }
 public sealed class NativeOwned : IDisposable {

  // Private, query-only seam for the NSIS update's existing wait loop.
  sealed class StartupWindowProcess { internal IntPtr Handle;internal uint Pid,Session,Wait;internal long Creation;internal string Image;internal TokenFacts Actor;internal bool Member; }
  sealed class StartupWindow { internal IntPtr Handle;internal uint Pid,Thread; }
  static class StartupWindowApi {
   [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern int GetWindowTextW(IntPtr window,StringBuilder text,int capacity);
   [DllImport("user32.dll")]static extern bool IsWindow(IntPtr window);
   [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern IntPtr GetPropW(IntPtr window,string name);
   internal static long Property(StartupWindow window,string name){return GetPropW(window.Handle,name).ToInt64();}
   internal static string CurrentDesktop(){return DesktopName(GetProcessWindowStation())+"\\"+DesktopName(GetThreadDesktop(GetCurrentThreadId()));}
   internal static string WindowDesktop(uint thread){return DesktopName(GetProcessWindowStation())+"\\"+DesktopName(GetThreadDesktop(thread));}
   internal static uint CurrentPid(){return GetCurrentProcessId();}
   internal static uint[] Pids(IntPtr job){IntPtr b=Marshal.AllocHGlobal(4194304);try{uint used;if(!ReadJobMembers(job,3,b,4194304,out used))throw new InvalidOperationException("window_job_unobserved");uint assigned=unchecked((uint)Marshal.ReadInt32(b)),listed=unchecked((uint)Marshal.ReadInt32(b,4));if(assigned!=listed||8UL+(ulong)listed*(ulong)IntPtr.Size>4194304)throw new InvalidOperationException("window_job_partial");var rows=new List<uint>();for(uint n=0;n<listed;n++){ulong raw=IntPtr.Size==8?unchecked((ulong)Marshal.ReadInt64(b,8+(int)n*IntPtr.Size)):unchecked((uint)Marshal.ReadInt32(b,8+(int)n*IntPtr.Size));if(raw==0||raw>UInt32.MaxValue||rows.Contains((uint)raw))throw new InvalidOperationException("window_job_pid_unobserved");rows.Add((uint)raw);}return rows.ToArray();}finally{Marshal.FreeHGlobal(b);}}
   static StartupWindowProcess Read(IntPtr handle,IntPtr job,uint pid){bool member;Check(IsProcessInJob(handle,job,out member),"window_job_member");if(!member)throw new InvalidOperationException("window_job_nonmember");uint wait=WaitForSingleObject(handle,0);if(wait!=0&&wait!=258)throw new InvalidOperationException("window_gui_wait_unobserved");long creation,exit,kernel,user;Check(GetProcessTimes(handle,out creation,out exit,out kernel,out user),"window_gui_creation");var r=new StartupWindowProcess{Handle=handle,Pid=pid,Creation=creation,Wait=wait,Member=member};if(wait==0)return r;uint count=32768;var text=new StringBuilder((int)count);Check(QueryFullProcessImageNameW(handle,0,text,ref count),"window_gui_image");r.Image=Path.GetFullPath(text.ToString());Check(ProcessIdToSessionId(pid,out r.Session),"window_gui_session");IntPtr token;Check(OpenProcessToken(handle,8,out token),"window_gui_actor");try{r.Actor=Observe(token);}finally{CloseHandle(token);}return r;}
   internal static StartupWindowProcess Open(IntPtr job,uint pid){IntPtr h=OpenProcess(0x101000,false,pid);if(h==IntPtr.Zero)throw new InvalidOperationException("window_gui_open_unobserved");try{return Read(h,job,pid);}catch{CloseHandle(h);throw;}}
   internal static StartupWindowProcess Reobserve(StartupWindowProcess p,IntPtr job){return Read(p.Handle,job,p.Pid);}
   internal static string ImageSha(string image){return Hash(File.ReadAllBytes(image));}
   internal static void Close(IntPtr handle){if(handle!=IntPtr.Zero)Check(CloseHandle(handle),"window_observer_handle_close");}
   internal static StartupWindow[] Windows(uint expectedPid){var rows=new List<StartupWindow>();OwnedWindowCallback callback=(window,data)=>{uint pid;uint thread=GetWindowThreadProcessId(window,out pid);if(pid==expectedPid)rows.Add(new StartupWindow{Handle=window,Pid=pid,Thread=thread});return true;};if(!EnumWindows(callback,IntPtr.Zero))throw new InvalidOperationException("window_enumeration_unobserved");return rows.ToArray();}
   internal static bool Owned(StartupWindow w,uint pid){uint now;uint thread=GetWindowThreadProcessId(w.Handle,out now);return thread!=0&&thread==w.Thread&&now==pid&&IsWindow(w.Handle);}
   internal static bool Visible(StartupWindow w){return IsWindowVisible(w.Handle);}
   internal static string Class(StartupWindow w){var text=new StringBuilder(256);int n=GetClassNameW(w.Handle,text,text.Capacity);return n<=0||n>=text.Capacity-1?"unobserved":text.ToString()=="#32770"?"native_dialog":text.ToString()=="Window Class"?"known_app_default":"other";}
   internal static string Caption(StartupWindow w){var text=new StringBuilder(8192);int n=GetWindowTextW(w.Handle,text,text.Capacity);return n<=0||n>=text.Capacity-1?null:text.ToString();}
  }

  // BEGIN PRIVATE PROPERTY DECODER
  sealed class StartupPropertyWindow { internal IntPtr Handle; internal uint Thread; internal long Native,Frontend; internal bool Stable; }
  sealed class WindowPropertyClaims {
   internal const string NativeName="Winsmux.InstallerProbe.Native.v1",FrontendName="Winsmux.InstallerProbe.Frontend.v1";
   internal const ulong Tag=(0x5753UL<<40)|(1UL<<32);
   internal static readonly string[] NativeNames=new string[]{"context_valid","hwnd_bound","policy_pending","policy_ready","policy_failed","policy_closed","confirm_entered","confirm_origin_refused","confirm_window_refused","confirm_policy_refused","send_entered","send_completed","send_refused","trace_stopped"};
   internal static readonly string[] FrontendNames=new string[]{"mount_entered","policy_entered","policy_completed","listeners_entered","listeners_completed","input_entered","input_completed","connect_entered","open_entered","open_completed","host_entered","host_completed","initial_project_entered","initial_project_completed","refresh_entered","refresh_completed","reveal_entered","reveal_completed","confirm_entered","confirm_completed","catch_entered","catch_observe_entered","catch_observe_completed","catch_reveal_entered","catch_reveal_completed","early_return"};
   uint priorNative,priorFrontend,pid;long creation;IntPtr window;uint thread;Dictionary<string,object> last;
   internal static bool ValidMask(uint mask,bool frontend){
    if(frontend){if((mask&~((1U<<26)-1))!=0)return false;foreach(var pair in new[]{new[]{1,2},new[]{3,4},new[]{5,6},new[]{8,9},new[]{10,11},new[]{12,13},new[]{14,15},new[]{16,17},new[]{18,19},new[]{21,22},new[]{23,24}})if((mask&(1U<<pair[1]))!=0&&(mask&(1U<<pair[0]))==0)return false;}
    else {if((mask&~((1U<<14)-1))!=0)return false;if(mask!=0&&(mask&1)==0)return false;if((mask&((1U<<3)|(1U<<4)|(1U<<5)))!=0&&(mask&(1U<<2))==0)return false;if((mask&(1U<<3))!=0&&(mask&(1U<<4))!=0)return false;if((mask&(1U<<6))!=0&&(mask&(1U<<1))==0)return false;if((mask&((1U<<7)|(1U<<8)|(1U<<9)|(1U<<10)))!=0&&(mask&(1U<<6))==0)return false;if((mask&((1U<<11)|(1U<<12)))!=0&&(mask&(1U<<10))==0)return false;if((mask&(1U<<11))!=0&&(mask&(1U<<12))!=0)return false;}
    return true;
   }
   internal static bool Decode(long value,bool frontend,out uint mask){mask=0;if(value<=0||((ulong)value&~(ulong)UInt32.MaxValue)!=Tag)return false;mask=(uint)value;return ValidMask(mask,frontend);}
   static string[] Names(uint mask,string[] names){var result=new List<string>();for(int i=0;i<names.Length;i++)if((mask&(1U<<i))!=0)result.Add(names[i]);return result.ToArray();}
   internal Dictionary<string,object> Observe(uint observedPid,long observedCreation,StartupPropertyWindow[] rows,bool readFailed){
    string status="unobserved";
    if(readFailed)status="unobserved";
    else if(rows.Length>1)status="ambiguous";
    else if(rows.Length==1){var row=rows[0];uint n,f;
     if(!row.Stable)status="changed";
     else if(!Decode(row.Native,false,out n)||!Decode(row.Frontend,true,out f))status="invalid";
     else if((n&3U)!=3U)status="invalid";
     else if(window!=IntPtr.Zero&&(pid!=observedPid||creation!=observedCreation||window!=row.Handle||thread!=row.Thread))status="stale_identity";
     else if((n&priorNative)!=priorNative||(f&priorFrontend)!=priorFrontend)status="changed";
     else {pid=observedPid;creation=observedCreation;window=row.Handle;thread=row.Thread;priorNative=n;priorFrontend=f;last=new Dictionary<string,object>{{"native",Names(n,NativeNames)},{"frontend",Names(f,FrontendNames)}};status="observed";}
    }
    return new Dictionary<string,object>{{"schema","winsmux-private-startup-window-claims/v1"},{"last_attempt_status",status},{"last_observed",last},{"snapshot_is_current",false},{"scope","mutable_owned_window_claims"},{"native_source","native_self_report"},{"frontend_source","frontend_self_report"}};
   }
  }
  // END PRIVATE PROPERTY DECODER

  sealed class StartupWindowObserver {
   readonly WindowPropertyClaims startupClaims=new WindowPropertyClaims();
   readonly IntPtr job;readonly TokenFacts caller;readonly string expectedImage,expectedSha,launchDesktop;
   StartupWindowProcess held;Dictionary<string,object> lastObserved;string status="not_seen";bool closed,handleCloseUnconfirmed;
   internal StartupWindowObserver(IntPtr j,TokenFacts c,string image,string sha,string desktop){job=j;caller=c;expectedImage=Path.GetFullPath(image);expectedSha=sha;launchDesktop=desktop;if(sha==null||!System.Text.RegularExpressions.Regex.IsMatch(sha,@"\A[0-9a-f]{64}\z",System.Text.RegularExpressions.RegexOptions.CultureInvariant))status="configuration_refused";}
   bool Actor(StartupWindowProcess p){return p.Member&&p.Wait==258&&p.Session==caller.session&&p.Actor!=null&&SameActorFacts(p.Actor,caller)&&String.Equals(p.Image,expectedImage,StringComparison.OrdinalIgnoreCase);}
   void CloseProcess(StartupWindowProcess p){if(p!=null&&p.Handle!=IntPtr.Zero){IntPtr h=p.Handle;p.Handle=IntPtr.Zero;try{StartupWindowApi.Close(h);}catch{handleCloseUnconfirmed=true;status="handle_close_unobserved";}}}
   void Release(){if(held!=null){var p=held;held=null;try{CloseProcess(p);}catch{status="handle_close_unobserved";}}}
   internal void Sample(){try{SampleInner();}catch{status="observation_unobserved";}}
   void SampleInner(){
    if(closed||status=="configuration_refused")return;
    if(!String.Equals(StartupWindowApi.CurrentDesktop(),launchDesktop,StringComparison.OrdinalIgnoreCase)){status="desktop_unconfirmed";return;}
    var candidates=new List<StartupWindowProcess>();bool uncertain=false;string uncertainStatus="candidate_unconfirmed";
    try{
     foreach(uint id in StartupWindowApi.Pids(job)){
      if(held!=null&&id==held.Pid){var current=StartupWindowApi.Reobserve(held,job);if(current.Creation!=held.Creation||!Actor(current)){uncertain=true;if(current.Wait==0)uncertainStatus="candidate_exited";continue;}candidates.Add(held);continue;}
      StartupWindowProcess p=null;try{p=StartupWindowApi.Open(job,id);if(p.Wait==258&&String.Equals(p.Image,expectedImage,StringComparison.OrdinalIgnoreCase)){candidates.Add(p);p=null;}}catch{uncertain=true;}finally{CloseProcess(p);}
     }
     if(uncertain){status=uncertainStatus;Release();return;}
     if(candidates.Count!=1){status=candidates.Count>1?"multiple_candidates":held!=null?"candidate_disappeared":"not_seen";if(held!=null)Release();return;}
     var candidate=candidates[0];
     if(!Actor(candidate)){status="candidate_refused";if(ReferenceEquals(candidate,held))Release();return;}
     if(!ReferenceEquals(candidate,held)){
      if(held!=null)Release();
      if(!String.Equals(StartupWindowApi.ImageSha(expectedImage),expectedSha,StringComparison.Ordinal)){status="candidate_refused";return;}
      var after=StartupWindowApi.Reobserve(candidate,job);if(after.Creation!=candidate.Creation||!Actor(after)){status="candidate_unconfirmed";return;}
      held=candidate;
     }
     ReadWindows();
    }finally{foreach(var p in candidates)if(!ReferenceEquals(p,held))CloseProcess(p);}
   }
   void ReadWindows(){
    var propertyWindows=new List<StartupPropertyWindow>();bool propertyReadFailed=false;
    int total=0,visible=0,hidden=0;bool desktop=true,captionObserved=false,captionUnknown=false,accelerator=false,noToken=false,webview=false;
    var classes=new Dictionary<string,int>{{"native_dialog",0},{"known_app_default",0},{"other",0},{"unobserved",0}};
    foreach(var w in StartupWindowApi.Windows(held.Pid)){
     if(w.Pid!=held.Pid)continue;
     if(!StartupWindowApi.Owned(w,held.Pid)){status="window_identity_unconfirmed";return;}
     if(!String.Equals(StartupWindowApi.WindowDesktop(w.Thread),launchDesktop,StringComparison.OrdinalIgnoreCase)){desktop=false;continue;}
     total++;bool shown=StartupWindowApi.Visible(w);if(shown)visible++;else hidden++;
     if(!StartupWindowApi.Owned(w,held.Pid)){status="window_identity_unconfirmed";return;}
     string kind=StartupWindowApi.Class(w);classes[kind]++;
     try {
      long native=StartupWindowApi.Property(w,WindowPropertyClaims.NativeName),frontend=StartupWindowApi.Property(w,WindowPropertyClaims.FrontendName);
      bool stable=StartupWindowApi.Owned(w,held.Pid)&&native==StartupWindowApi.Property(w,WindowPropertyClaims.NativeName)&&frontend==StartupWindowApi.Property(w,WindowPropertyClaims.FrontendName);
      if(native!=0||frontend!=0||!stable)propertyWindows.Add(new StartupPropertyWindow{Handle=w.Handle,Thread=w.Thread,Native=native,Frontend=frontend,Stable=stable});
     }catch{propertyReadFailed=true;}
     if(kind=="native_dialog"){
      if(held.Pid==StartupWindowApi.CurrentPid()||!StartupWindowApi.Owned(w,held.Pid)){status="window_identity_unconfirmed";return;}
      string caption=StartupWindowApi.Caption(w);
      if(!StartupWindowApi.Owned(w,held.Pid)){status="window_identity_unconfirmed";return;}
      if(caption==null){captionUnknown=true;continue;}
      captionObserved=true;
      accelerator|=caption=="winsmux — 起動を確認できません";
      noToken|=System.Text.RegularExpressions.Regex.IsMatch(caption,@"(?<![A-Za-z0-9])(?:ERROR_NO_TOKEN|0x800703f0|0x3f0)(?![A-Za-z0-9])",System.Text.RegularExpressions.RegexOptions.IgnoreCase|System.Text.RegularExpressions.RegexOptions.CultureInvariant);
      webview|=System.Text.RegularExpressions.Regex.IsMatch(caption,@"\bWebView2\b",System.Text.RegularExpressions.RegexOptions.IgnoreCase|System.Text.RegularExpressions.RegexOptions.CultureInvariant);
     }
    }
    if(!desktop){status="desktop_unconfirmed";return;}
    if(total==0){status="scope_limited_no_owned_window";return;}
    var after=StartupWindowApi.Reobserve(held,job);if(after.Creation!=held.Creation||!Actor(after)){status="candidate_unconfirmed";Release();return;}
    status=classes["unobserved"]==0?"observed":"partial";
    lastObserved=new Dictionary<string,object>{{"pid",held.Pid},{"creation_time",held.Creation},{"gui_sha256",expectedSha},{"actor",caller.Public()},{"owned_job_member",true},{"desktop_scope","owned_window_threads_match_launch"},{"window_count",total},{"visible_count",visible},{"hidden_count",hidden},{"class_counts",classes},{"caption_status",captionObserved?(captionUnknown?"partial":"observed"):"unobserved"},{"body_status","not_observed"},{"marker_scope","caption_only"},{"accelerator_failure_title",accelerator?(object)true:captionObserved&&!captionUnknown?(object)false:null},{"error_no_token_marker",noToken?(object)true:captionObserved&&!captionUnknown?(object)false:null},{"webview2_marker",webview?(object)true:captionObserved&&!captionUnknown?(object)false:null}};
    try{lastObserved["startup_boundary_claims"]=startupClaims.Observe(held.Pid,held.Creation,propertyWindows.ToArray(),propertyReadFailed);}catch{lastObserved["startup_boundary_claims"]=new Dictionary<string,object>{{"schema","winsmux-private-startup-window-claims/v1"},{"last_attempt_status","unobserved"},{"last_observed",null},{"snapshot_is_current",false},{"scope","mutable_owned_window_claims"}};}
   }
   internal void Finish(){Release();closed=true;}
   internal Dictionary<string,object> Snapshot(){return new Dictionary<string,object>{{"schema","winsmux-owned-startup-gui-window/v1"},{"last_attempt_status",status},{"last_observed",lastObserved},{"snapshot_is_current",false},{"snapshot_scope","last_observation_during_installer_wait"},{"observer_handle_closed",held==null&&!handleCloseUnconfirmed}};}
  }
  StartupWindowObserver startupWindowObserver;
  internal string startupLaunchDesktop;
  public void ArmStartupWindowObservation(string expectedImage,string expectedSha){try{if(startupWindowObserver==null)startupWindowObserver=new StartupWindowObserver(job,caller,expectedImage,expectedSha,startupLaunchDesktop);}catch{startupWindowObserver=null;}}
  void SampleStartupWindowObservation(){if(startupWindowObserver!=null)startupWindowObserver.Sample();}
  void FinishStartupWindowObservation(){if(startupWindowObserver!=null)startupWindowObserver.Finish();}
  public Dictionary<string,object> StartupWindowObservation(){return startupWindowObserver==null?new Dictionary<string,object>{{"schema","winsmux-owned-startup-gui-window/v1"},{"last_attempt_status","not_armed"},{"last_observed",null},{"snapshot_is_current",false}}:startupWindowObserver.Snapshot();}

  IntPtr job,process,thread; bool terminal,disposed; uint pid; long creation; TokenFacts caller; string image,imageHash; FileStream lease,scriptLease;
  internal NativeOwned(IntPtr j,PI p,TokenFacts c,string i,string sha,FileStream f,FileStream extra) {scriptLease=extra;job=j;process=p.process;thread=p.thread;pid=p.pid;caller=c;image=i;imageHash=sha;lease=f;long exit,kernel,user;Check(GetProcessTimes(process,out creation,out exit,out kernel,out user),"Native creation");}


  static readonly string[] StartupRejectNames={"open_access_denied","open_unavailable","open_other","not_member_expected_image","not_member_other_image","not_member_unobserved","exited","image","hash","sid","session","token_type","app_container","exited_after_actor","held"};
  readonly Dictionary<string,int> startupObservations=NewStartupObservations();
  static Dictionary<string,int> NewStartupObservations(){var r=new Dictionary<string,int>();foreach(string n in StartupRejectNames)r.Add(n,0);return r;}
  static string StartupOpenRejection(int error){return error==5?"open_access_denied":error==87?"open_unavailable":"open_other";}
  void NoteStartup(string reason){startupObservations[reason]++;}
  public Dictionary<string,int> StartupObservations(){return new Dictionary<string,int>(startupObservations);}
  static string NonmemberStartupObservation(IntPtr handle,string expectedImage,string expectedSha){
   try{uint length=32768;var actual=new StringBuilder((int)length);if(!QueryFullProcessImageNameW(handle,0,actual,ref length))return "not_member_unobserved";if(!String.Equals(Path.GetFullPath(actual.ToString()),Path.GetFullPath(expectedImage),StringComparison.OrdinalIgnoreCase))return "not_member_other_image";return Hash(File.ReadAllBytes(expectedImage))==expectedSha?"not_member_expected_image":"not_member_other_image";}catch{return "not_member_unobserved";}
  }
  public NativeGui HoldStartupGui(uint guiPid,string expectedImage,string expectedSha) {
   var h=OpenProcess(0x00101001,false,guiPid);if(h==IntPtr.Zero){int error=Marshal.GetLastWin32Error();NoteStartup(StartupOpenRejection(error));return null;}bool adopted=false;try{
    bool member;Check(IsProcessInJob(h,job,out member),"Startup GUI own Job");if(!member){NoteStartup(NonmemberStartupObservation(h,expectedImage,expectedSha));return null;}if(WaitForSingleObject(h,0)==0){NoteStartup("exited");return null;}
    uint length=32768;var actual=new StringBuilder((int)length);Check(QueryFullProcessImageNameW(h,0,actual,ref length),"Startup GUI retained image");if(!String.Equals(Path.GetFullPath(actual.ToString()),Path.GetFullPath(expectedImage),StringComparison.OrdinalIgnoreCase)){NoteStartup("image");return null;}if(Hash(File.ReadAllBytes(expectedImage))!=expectedSha){NoteStartup("hash");return null;}
    IntPtr token;Check(OpenProcessToken(h,8,out token),"Startup GUI retained actor");TokenFacts facts;try{facts=Observe(token);}finally{CloseHandle(token);}if(!Equal(facts.sid,caller.sid)){NoteStartup("sid");return null;}if(facts.session!=caller.session){NoteStartup("session");return null;}if(facts.tokenType!=1){NoteStartup("token_type");return null;}if(facts.appContainer!=0){NoteStartup("app_container");return null;}
    if(WaitForSingleObject(h,0)==0){NoteStartup("exited_after_actor");return null;}var gui=new NativeGui(h,guiPid,Path.GetFullPath(expectedImage),expectedSha,facts);adopted=true;NoteStartup("held");return gui;
   }finally{if(!adopted)CloseHandle(h);}
  }


  [DllImport("kernel32.dll",EntryPoint="QueryInformationJobObject",SetLastError=true)]static extern bool ReadJobMembers(IntPtr job,uint kind,IntPtr data,uint length,out uint used);
  delegate bool OwnedWindowCallback(IntPtr window,IntPtr data);
  [DllImport("user32.dll",SetLastError=true)]static extern bool EnumWindows(OwnedWindowCallback callback,IntPtr data);
  [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr window,out uint process);
  [DllImport("user32.dll")]static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetClassNameW(IntPtr window,StringBuilder text,int count);
  public Dictionary<string,object> RootWindowCounts(){
   var result=new Dictionary<string,object>{{"status","unknown"},{"total",null},{"visible",null},{"native_dialog",null},{"visible_native_dialog",null},{"class_unobserved",null}};
   if(HasExited)return result;
   int total=0,visible=0,dialogs=0,visibleDialogs=0,classUnknown=0;
   OwnedWindowCallback callback=(window,data)=>{uint owner;GetWindowThreadProcessId(window,out owner);if(owner!=pid)return true;total++;bool shown=IsWindowVisible(window);if(shown)visible++;var name=new StringBuilder(256);int length=GetClassNameW(window,name,name.Capacity);if(length<=0)classUnknown++;else if(name.ToString()=="#32770"){dialogs++;if(shown)visibleDialogs++;}return true;};
   if(!EnumWindows(callback,IntPtr.Zero)||HasExited)return result;
   result["status"]=classUnknown==0?"observed":"partial";result["class_unobserved"]=classUnknown;result["total"]=total;result["visible"]=visible;result["native_dialog"]=dialogs;result["visible_native_dialog"]=visibleDialogs;return result;
  }
  static string OwnedRole(uint observedPid,uint rootPid,string actualPath,string expectedRoot,string actualSha,string cliSha,string guiSha){
   if(observedPid==rootPid)return "root";
   if(String.Equals(Path.GetFullPath(actualPath),Path.Combine(Path.GetFullPath(expectedRoot),"winsmux-app.exe"),StringComparison.OrdinalIgnoreCase)&&actualSha==guiSha)return "gui";
   if(String.Equals(Path.GetFileName(actualPath),"winsmux.exe",StringComparison.OrdinalIgnoreCase)&&actualSha==cliSha)return "cli";
   return "other";
  }
  public Dictionary<string,object> OwnedRoleCounts(string root,string cliSha,string guiSha){
   var result=new Dictionary<string,object>{{"status","unknown"},{"root",null},{"cli",null},{"gui",null},{"other",null},{"unobserved",null},{"exited_during_snapshot",null}};
   IntPtr buffer=Marshal.AllocHGlobal(4194304);
   try{uint used;if(!ReadJobMembers(job,3,buffer,4194304,out used))return result;
    uint assigned=unchecked((uint)Marshal.ReadInt32(buffer)),listed=unchecked((uint)Marshal.ReadInt32(buffer,4));if(listed>assigned||8UL+(ulong)listed*(ulong)IntPtr.Size>4194304)return result;
    foreach(string key in new[]{"root","cli","gui","other","unobserved","exited_during_snapshot"})result[key]=0;
    for(uint index=0;index<listed;index++){
     ulong raw=IntPtr.Size==8?unchecked((ulong)Marshal.ReadInt64(buffer,8+(int)index*IntPtr.Size)):unchecked((uint)Marshal.ReadInt32(buffer,8+(int)index*IntPtr.Size));
     if(raw==0||raw>UInt32.MaxValue){result["unobserved"]=(int)result["unobserved"]+1;continue;}
     var handle=OpenProcess(0x00101000,false,(uint)raw);if(handle==IntPtr.Zero){result["unobserved"]=(int)result["unobserved"]+1;continue;}
     try{bool member;if(!IsProcessInJob(handle,job,out member)||!member){result["unobserved"]=(int)result["unobserved"]+1;continue;}
      if(WaitForSingleObject(handle,0)==0){result["exited_during_snapshot"]=(int)result["exited_during_snapshot"]+1;continue;}
      uint size=32768;var imagePath=new StringBuilder((int)size);if(!QueryFullProcessImageNameW(handle,0,imagePath,ref size)){result["unobserved"]=(int)result["unobserved"]+1;continue;}
      string actual=imagePath.ToString(),hash=null;
      if((uint)raw!=pid&&(String.Equals(Path.GetFileName(actual),"winsmux.exe",StringComparison.OrdinalIgnoreCase)||String.Equals(Path.GetFullPath(actual),Path.Combine(Path.GetFullPath(root),"winsmux-app.exe"),StringComparison.OrdinalIgnoreCase))){try{hash=Hash(File.ReadAllBytes(actual));}catch{result["unobserved"]=(int)result["unobserved"]+1;continue;}}
      string role=OwnedRole((uint)raw,pid,actual,root,hash,cliSha,guiSha);result[role]=(int)result[role]+1;
     }finally{CloseHandle(handle);}
    }
    result["status"]=assigned==listed?"observed":"partial";return result;
   }finally{Marshal.FreeHGlobal(buffer);}
  }
  public uint Id { get {return pid;} }
  public bool HasExited { get {return WaitForSingleObject(process,0)==0;} }
  public uint ActiveMembers {get{ACCOUNT a;Check(QueryInformationJobObject(job,1,out a,(uint)Marshal.SizeOf<ACCOUNT>(),IntPtr.Zero),"Native Job observation");return a.activeProcesses;}}
  public uint ExitCode {get{uint code;Check(GetExitCodeProcess(process,out code),"Native exit code");if(code==259)throw new InvalidOperationException("Native child still active");return code;}}
  public bool WaitTerminal(int milliseconds) {var end=DateTime.UtcNow.AddMilliseconds(milliseconds);do {SampleStartupWindowObservation();if(HasExited&&ActiveMembers==0){FinishStartupWindowObservation();terminal=true;return true;}System.Threading.Thread.Sleep(50);}while(DateTime.UtcNow<end);return false;}
  public void StopOwnedFailure() {Check(TerminateJobObject(job,124),"Stop native owned Job");if(!WaitTerminal(10000))throw new InvalidOperationException("Native owned Job did not terminate");}
  public Dictionary<string,object> Facts() {return new Dictionary<string,object>{{"pid",pid},{"creation_time",creation},{"image",image},{"image_sha256",imageHash},{"actor",caller.Public()},{"active_members",ActiveMembers},{"terminal",terminal}};}
  public void Dispose() {if(disposed)return;if(!terminal||ActiveMembers!=0)throw new InvalidOperationException("Native handles retained for nonterminal Job");FinishStartupWindowObservation();CloseHandle(thread);CloseHandle(process);CloseHandle(job);if(lease!=null)lease.Dispose();if(scriptLease!=null)scriptLease.Dispose();disposed=true;}
 }
 public static NativeOwned StartNative(string purpose,string image,string imageSha,string root,string source,string candidate,string baseline,string script) {
  IntPtr callerToken=IntPtr.Zero,derived=IntPtr.Zero,environment=IntPtr.Zero,job=IntPtr.Zero;PI pi=new PI();bool assigned=false;FileStream imageLease=null,scriptLease=null;
  try {
   IntPtr impersonation;if(OpenThreadToken(GetCurrentThread(),8,true,out impersonation)){CloseHandle(impersonation);throw new InvalidOperationException("Native thread impersonation refused");}if(Marshal.GetLastWin32Error()!=1008)throw new Win32Exception(Marshal.GetLastWin32Error(),"Native thread token");
   Check(OpenProcessToken(GetCurrentProcess(),0x8b,out callerToken),"Native caller token");var caller=Observe(callerToken);uint session;Check(ProcessIdToSessionId(GetCurrentProcessId(),out session),"Native caller session");if(caller.tokenType!=1||caller.session!=session||caller.appContainer!=0||caller.sidText=="S-1-5-18"||caller.sidText=="S-1-5-19"||caller.sidText=="S-1-5-20"||caller.sidText.StartsWith("S-1-5-80-",StringComparison.Ordinal))throw new InvalidOperationException("Native caller identity refused");
   IntPtr launchToken=callerToken;bool msi=purpose=="msi-install-en"||purpose=="msi-update-ja"||purpose=="msi-uninstall"||purpose=="msi-capacity-install-en"||purpose=="msi-capacity-update-ja"||purpose=="msi-capacity-uninstall";bool bootstrap=purpose=="medium-bootstrap"||purpose=="msi-nsis-conflict";
   if(bootstrap) {
    if(caller.elevation!=1||caller.rid<12288)throw new InvalidOperationException("Native high bootstrap required");TokenFacts initial;derived=CreateRestrictedMediumPrimary(callerToken,caller,out initial);launchToken=derived;
   } else if(!msi) { Medium(caller,caller); }
   var env=UserEnvironment(launchToken);string local;if(!env.TryGetValue("LOCALAPPDATA",out local)||!String.Equals(Path.GetFullPath(local),Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)),StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Native same-SID profile refused");using(var hive=Microsoft.Win32.Registry.Users.OpenSubKey(caller.sidText,false))if(hive==null)throw new InvalidOperationException("Native existing profile hive missing");
   image=Path.GetFullPath(image);NativePhysical(image);if(purpose=="nsis-uninstall"||msi){var h=CreateFileW(image,0x80000000,purpose=="nsis-uninstall"?5u:1u,IntPtr.Zero,3,0x00200000,IntPtr.Zero);if(h==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error(),"Native image lease");var safe=new Microsoft.Win32.SafeHandles.SafeFileHandle(h,true);try{var f=FileFacts(h);if((f.attributes&0x10)!=0||f.links<1||(purpose=="nsis-uninstall"&&f.links!=1))throw new InvalidOperationException("Native image plain identity refused");imageLease=new FileStream(safe,FileAccess.Read);}catch{safe.Dispose();throw;}}else imageLease=OpenPlain(image);if(Hash(File.ReadAllBytes(image))!=imageSha)throw new InvalidOperationException("Native image identity refused");string command=NativeCommand(purpose,image,root,source,candidate,baseline,script);if(purpose=="medium-bootstrap"){NativePhysical(script);scriptLease=OpenPlain(script);}
   var keys=new List<string>(env.Keys);keys.Sort(StringComparer.OrdinalIgnoreCase);var text=new StringBuilder();foreach(var key in keys)text.Append(key).Append('=').Append(env[key]).Append('\0');text.Append('\0');environment=Marshal.StringToHGlobalUni(text.ToString());
   job=CreateJobObjectW(IntPtr.Zero,null);Check(job!=IntPtr.Zero,"Native unnamed Job");var limits=new LIMIT();limits.basic.flags=0x2000;Check(SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf<LIMIT>()),"Native kill-on-close");var si=new SI{cb=(uint)Marshal.SizeOf<SI>(),desktop=DesktopName(GetProcessWindowStation())+"\\"+DesktopName(GetThreadDesktop(GetCurrentThreadId()))};
   bool created=bootstrap?CreateProcessAsUserW(launchToken,image,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x404,environment,Path.GetDirectoryName(image),ref si,out pi):CreateProcessW(image,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x404,environment,Path.GetDirectoryName(image),ref si,out pi);Check(created,"Native suspended launch");Check(AssignProcessToJobObject(job,pi.process),"Native Job assignment");assigned=true;bool member;Check(IsProcessInJob(pi.process,job,out member),"Native Job membership");if(!member)throw new InvalidOperationException("Native member refused");IntPtr childToken;Check(OpenProcessToken(pi.process,8,out childToken),"Native retained child token");TokenFacts child;try{child=Observe(childToken);if(msi){if(!Equal(child.sid,caller.sid)||child.session!=caller.session||child.tokenType!=1||child.appContainer!=0||child.elevation!=caller.elevation||child.rid!=caller.rid)throw new InvalidOperationException("Native MSI actor changed");}else Medium(child,caller);}finally{CloseHandle(childToken);}uint length=32768;var actual=new StringBuilder((int)length);Check(QueryFullProcessImageNameW(pi.process,0,actual,ref length),"Native retained child image");if(!String.Equals(Path.GetFullPath(actual.ToString()),image,StringComparison.OrdinalIgnoreCase)||Hash(File.ReadAllBytes(image))!=imageSha)throw new InvalidOperationException("Native retained child image changed");
   var owned=new NativeOwned(job,pi,child,image,imageSha,purpose=="nsis-uninstall"?null:imageLease,scriptLease);owned.startupLaunchDesktop=si.desktop;if(purpose=="nsis-uninstall"){imageLease.Dispose();imageLease=null;}uint count=ResumeThread(pi.thread);if(count!=1)throw new InvalidOperationException("Native resume count refused");job=IntPtr.Zero;pi=new PI();imageLease=null;scriptLease=null;return owned;
  } catch { if(pi.process!=IntPtr.Zero){bool stopped=assigned?TerminateJobObject(job,124):TerminateProcess(pi.process,124);if(!stopped||WaitForSingleObject(pi.process,10000)!=0)throw new InvalidOperationException("Native failed launch cleanup unconfirmed");if(assigned){ACCOUNT a;Check(QueryInformationJobObject(job,1,out a,(uint)Marshal.SizeOf<ACCOUNT>(),IntPtr.Zero),"Native failed Job cleanup");if(a.activeProcesses!=0)throw new InvalidOperationException("Native failed Job retains members");}}throw; }
  finally {foreach(var h in new[]{pi.thread,pi.process,job,derived,callerToken})if(h!=IntPtr.Zero)CloseHandle(h);if(environment!=IntPtr.Zero)Marshal.FreeHGlobal(environment);if(imageLease!=null)imageLease.Dispose();if(scriptLease!=null)scriptLease.Dispose();}
 }
 public static Dictionary<string,object> ReadMsiLogObservationInput(string path) {
  var result=new Dictionary<string,object>{{"status","unreadable"},{"bytes",null},{"sha256",null},{"text",null}};
  try {
   path=Path.GetFullPath(path);NativePhysical(path);
   using(var file=OpenPlain(path)) {
    var before=FileFacts(file.SafeFileHandle.DangerousGetHandle());long length=file.Length;
    if(length==0){result["status"]="empty";return result;}
    if(length>4194304){result["status"]="overlong";return result;}
    var first=new byte[(int)length];int at=0;
    while(at<first.Length){int count=file.Read(first,at,first.Length-at);if(count==0){result["status"]="changed";return result;}at+=count;}
    var middle=FileFacts(file.SafeFileHandle.DangerousGetHandle());
    if(file.Length!=length||middle.links!=1||FileId(middle)!=FileId(before)){result["status"]="changed";return result;}
    file.Position=0;var second=new byte[(int)length];at=0;
    while(at<second.Length){int count=file.Read(second,at,second.Length-at);if(count==0){result["status"]="changed";return result;}at+=count;}
    string sha=Hash(first);
    var after=FileFacts(file.SafeFileHandle.DangerousGetHandle());
    if(file.Length!=length||after.links!=1||FileId(after)!=FileId(before)||Hash(second)!=sha){result["status"]="changed";return result;}
    result["bytes"]=length;result["sha256"]=sha;
    if((first.Length>=4&&first[0]==0xff&&first[1]==0xfe&&first[2]==0&&first[3]==0)||(first.Length>=4&&first[0]==0&&first[1]==0&&first[2]==0xfe&&first[3]==0xff)||(first.Length>=2&&first[0]==0xfe&&first[1]==0xff)){result["status"]="unknown_encoding";return result;}
    try {
     string text;
     if(first.Length>=2&&first[0]==0xff&&first[1]==0xfe)text=new UnicodeEncoding(false,false,true).GetString(first,2,first.Length-2);
     else {int offset=first.Length>=3&&first[0]==0xef&&first[1]==0xbb&&first[2]==0xbf?3:0;text=new UTF8Encoding(false,true).GetString(first,offset,first.Length-offset);}
     if(text.IndexOf('\0')>=0){result["status"]="unknown_encoding";return result;}
     result["text"]=text;result["status"]="observed";return result;
    } catch(DecoderFallbackException){result["status"]="unknown_encoding";return result;}
   }
  } catch(Win32Exception error){result["status"]=error.NativeErrorCode==2||error.NativeErrorCode==3?"absent":"unreadable";return result;}
  catch(FileNotFoundException){result["status"]="absent";return result;}
  catch(DirectoryNotFoundException){result["status"]="absent";return result;}
  catch {return result;}
 }
 public static Dictionary<string,object> ReadNsisJournalObservationInput(string path) {
  var result=new Dictionary<string,object>{{"status","unreadable"},{"bytes",null},{"sha256",null},{"text",null}};
  try {
   path=Path.GetFullPath(path);NativePhysical(path);
   using(var file=OpenPlain(path)) {
    var before=FileFacts(file.SafeFileHandle.DangerousGetHandle());long length=file.Length;
    if(length==0){result["status"]="empty";return result;}
    if(length>4194304){result["status"]="overlong";return result;}
    var first=new byte[(int)length];int at=0;
    while(at<first.Length){int count=file.Read(first,at,first.Length-at);if(count==0){result["status"]="changed";return result;}at+=count;}
    var middle=FileFacts(file.SafeFileHandle.DangerousGetHandle());
    if(file.Length!=length||middle.links!=1||FileId(middle)!=FileId(before)){result["status"]="changed";return result;}
    file.Position=0;var second=new byte[(int)length];at=0;
    while(at<second.Length){int count=file.Read(second,at,second.Length-at);if(count==0){result["status"]="changed";return result;}at+=count;}
    string sha=Hash(first);
    var after=FileFacts(file.SafeFileHandle.DangerousGetHandle());
    if(file.Length!=length||after.links!=1||FileId(after)!=FileId(before)||Hash(second)!=sha){result["status"]="changed";return result;}
    result["bytes"]=length;result["sha256"]=sha;
    try{if(first.Length>=3&&first[0]==0xef&&first[1]==0xbb&&first[2]==0xbf){result["status"]="unknown_encoding";return result;}string text=new UTF8Encoding(false,true).GetString(first);if(text.IndexOf('\0')>=0){result["status"]="unknown_encoding";return result;}result["text"]=text;result["status"]="observed";return result;}catch(DecoderFallbackException){result["status"]="unknown_encoding";return result;}
   }
  } catch(Win32Exception error){result["status"]=error.NativeErrorCode==2||error.NativeErrorCode==3?"absent":"unreadable";return result;}
  catch(FileNotFoundException){result["status"]="absent";return result;}
  catch(DirectoryNotFoundException){result["status"]="absent";return result;}
  catch {return result;}
 }
 [StructLayout(LayoutKind.Sequential)] struct MSI_FAULT_SECURITY { public uint length;public IntPtr descriptor;public int inherit; }
 [DllImport("advapi32.dll",EntryPoint="ConvertStringSecurityDescriptorToSecurityDescriptorW",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool MsiFaultDescriptor(string text,uint revision,out IntPtr descriptor,out uint size);
 [DllImport("kernel32.dll",EntryPoint="LocalFree")]static extern IntPtr MsiFaultLocalFree(IntPtr value);
 public static void CreateMsiFaultRequest(string root,string nonce) {
  Guid id;if(!Guid.TryParseExact(nonce,"D",out id)||id.ToString()!=nonce||nonce[14]!='4'||"89ab".IndexOf(nonce[19])<0)throw new InvalidOperationException("MSI fault nonce refused");
  string parent=Path.GetDirectoryName(Path.GetFullPath(root));NativePhysical(parent);
  string sid;using(var identity=System.Security.Principal.WindowsIdentity.GetCurrent()){sid=identity.User.Value;}
  IntPtr descriptor=IntPtr.Zero,attributes=IntPtr.Zero;uint size;
  try{
   Check(MsiFaultDescriptor("O:"+sid+"D:P(A;OICI;FA;;;"+sid+")",1,out descriptor,out size),"MSI fault private file security");if(descriptor==IntPtr.Zero)throw new InvalidOperationException("MSI fault private descriptor missing");
   var security=new MSI_FAULT_SECURITY{length=(uint)Marshal.SizeOf<MSI_FAULT_SECURITY>(),descriptor=descriptor,inherit=0};attributes=Marshal.AllocHGlobal((int)security.length);Marshal.StructureToPtr(security,attributes,false);
   var handle=CreateFileW(Path.Combine(parent,"msi-startup-fault-request.json"),0x40000000,0,attributes,1,0x00200000,IntPtr.Zero);
   if(handle==IntPtr.Zero||handle==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error(),"MSI fault exclusive request");
   var safe=new Microsoft.Win32.SafeHandles.SafeFileHandle(handle,true);
   try{var facts=FileFacts(handle);if((facts.attributes&0x10)!=0||facts.links!=1)throw new InvalidOperationException("MSI fault plain request required");using(var file=new FileStream(safe,FileAccess.Write)){var bytes=Encoding.UTF8.GetBytes("{\"schema\":\"winsmux-msi-startup-fault-request/v1\",\"nonce\":\""+nonce+"\"}");file.Write(bytes,0,bytes.Length);file.Flush(true);}}
   finally{safe.Dispose();}
  }finally{if(attributes!=IntPtr.Zero)Marshal.FreeHGlobal(attributes);if(descriptor!=IntPtr.Zero)MsiFaultLocalFree(descriptor);}
 }

 public static Dictionary<string,object> ReadMsiFaultControlInput(string path) {
  var result=new Dictionary<string,object>{{"status","unreadable"},{"bytes",null},{"sha256",null},{"text",null},{"identity",null}};
  try {
   path=Path.GetFullPath(path);NativePhysical(path);
   using(var file=OpenPlain(path)) {
    var before=FileFacts(file.SafeFileHandle.DangerousGetHandle());long length=file.Length;
    if(length==0){result["status"]="empty";return result;}
    if(length>Encoding.UTF8.GetByteCount("{\"schema\":\"winsmux-msi-startup-fault-consumed/v1\",\"nonce\":\""+new string('0',36)+"\",\"operation_id\":\""+new string('0',36)+"\",\"applied\":false}")){result["status"]="overlong";return result;}
    var first=new byte[(int)length];int at=0;
    while(at<first.Length){int count=file.Read(first,at,first.Length-at);if(count==0){result["status"]="changed";return result;}at+=count;}
    var middle=FileFacts(file.SafeFileHandle.DangerousGetHandle());
    if(file.Length!=length||middle.links!=1||FileId(middle)!=FileId(before)){result["status"]="changed";return result;}
    file.Position=0;var second=new byte[(int)length];at=0;
    while(at<second.Length){int count=file.Read(second,at,second.Length-at);if(count==0){result["status"]="changed";return result;}at+=count;}
    string sha=Hash(first);
    var after=FileFacts(file.SafeFileHandle.DangerousGetHandle());
    if(file.Length!=length||after.links!=1||FileId(after)!=FileId(before)||Hash(second)!=sha){result["status"]="changed";return result;}
    result["bytes"]=length;result["sha256"]=sha;result["identity"]=FileId(before);
    try{if(first.Length>=3&&first[0]==0xef&&first[1]==0xbb&&first[2]==0xbf){result["status"]="unknown_encoding";return result;}string text=new UTF8Encoding(false,true).GetString(first);if(text.IndexOf('\0')>=0){result["status"]="unknown_encoding";return result;}result["text"]=text;result["status"]="observed";return result;}catch(DecoderFallbackException){result["status"]="unknown_encoding";return result;}
   }
  } catch(Win32Exception error){result["status"]=error.NativeErrorCode==2||error.NativeErrorCode==3?"absent":"unreadable";return result;}
  catch(FileNotFoundException){result["status"]="absent";return result;}
  catch(DirectoryNotFoundException){result["status"]="absent";return result;}
  catch {return result;}
 }
 public static Dictionary<string,object> NativeFile(string path) {NativePhysical(path);using(var f=OpenPlain(Path.GetFullPath(path))){var info=FileFacts(f.SafeFileHandle.DangerousGetHandle());var b=new byte[f.Length];int at=0;while(at<b.Length){int n=f.Read(b,at,b.Length-at);if(n==0)throw new EndOfStreamException();at+=n;}if(FileId(FileFacts(f.SafeFileHandle.DangerousGetHandle()))!=FileId(info)||Hash(File.ReadAllBytes(path))!=Hash(b))throw new InvalidOperationException("Native witness changed");return new Dictionary<string,object>{{"bytes",b.Length},{"sha256",Hash(b)},{"identity",FileId(info)}};}}

 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegOpenKeyExW(IntPtr key,string subkey,uint options,uint access,out IntPtr result);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegQueryValueExW(IntPtr key,string name,IntPtr reserved,out uint type,byte[] data,ref uint bytes);
 [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr key);
 public static Dictionary<string,object> NativeRegistry(string key,string name) {IntPtr handle;int status=RegOpenKeyExW(new IntPtr(unchecked((int)0x80000001)),key,0,0x101,out handle);if(status==2)return null;if(status!=0)throw new Win32Exception(status);try{uint kind,size=0;status=RegQueryValueExW(handle,name,IntPtr.Zero,out kind,null,ref size);if(status==2)return null;if(status!=0||size>65536)throw new InvalidOperationException("Native registry query refused");var data=new byte[size];status=RegQueryValueExW(handle,name,IntPtr.Zero,out kind,data,ref size);if(status!=0||size!=data.Length)throw new InvalidOperationException("Native registry changed during capture");return new Dictionary<string,object>{{"type",kind},{"data",data}};}finally{RegCloseKey(handle);}}

 public static string NativeDirectory(string path,bool create) {path=Path.GetFullPath(path);if(create)NativePhysical(Path.GetDirectoryName(path));else NativePhysical(path);if(create)Check(CreateDirectoryW(path,IntPtr.Zero),"Native exclusive directory");var h=CreateFileW(path,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);if(h==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error(),"Native directory lease");try{var f=FileFacts(h);if((f.attributes&0x10)==0)throw new InvalidOperationException("Native directory required");return FileId(f);}finally{CloseHandle(h);}}

 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
 public sealed class NativeGui : IDisposable {
  IntPtr handle; uint pid; long creation; string image,sha; TokenFacts actor; bool disposed;
  internal NativeGui(IntPtr h,uint p,string i,string s,TokenFacts a) {handle=h;pid=p;image=i;sha=s;actor=a;long exit,kernel,user;Check(GetProcessTimes(h,out creation,out exit,out kernel,out user),"Retained GUI creation");}
  public bool HasExited {get{return WaitForSingleObject(handle,0)==0;}}
  public Dictionary<string,object> StopForStartup(string[] arguments) {
   if(HasExited||arguments==null||arguments.Length!=7||!String.Equals(Path.GetFullPath(arguments[0]),image,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Startup GUI arguments unavailable");
   var values=new Dictionary<string,string>(StringComparer.Ordinal);for(int i=1;i<arguments.Length;i+=2){if(arguments[i]!="--winsmux-installer-probe"&&arguments[i]!="--winsmux-installer-pipe"&&arguments[i]!="--project-dir")throw new InvalidOperationException("Startup GUI argument refused");values.Add(arguments[i],arguments[i+1]);}
   string operation=values["--winsmux-installer-probe"];Guid id;if(!Guid.TryParseExact(operation,"D",out id)||id.ToString()!=operation||operation[14]!='4'||"89ab".IndexOf(operation[19])<0||values["--winsmux-installer-pipe"]!="\\\\.\\pipe\\winsmux-installer-"+operation)throw new InvalidOperationException("Startup GUI operation refused");
   string project=Path.Combine(Path.GetTempPath(),"winsmux-installer-"+operation,"project");if(!String.Equals(Path.GetFullPath(values["--project-dir"]),project,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Startup GUI project refused");NativeDirectory(project,false);
   if(Hash(File.ReadAllBytes(image))!=sha||HasExited)throw new InvalidOperationException("Startup GUI changed or receipt may have completed");Check(TerminateProcess(handle,123),"Stop retained owned startup GUI");if(WaitForSingleObject(handle,10000)!=0)throw new InvalidOperationException("Stopped GUI terminal unconfirmed");return new Dictionary<string,object>{{"pid",pid},{"creation_time",creation},{"image",image},{"image_sha256",sha},{"actor",actor.Public()},{"operation_id",operation},{"pipe",values["--winsmux-installer-pipe"]},{"project",project},{"owned_job_member",true},{"terminated",true}};
  }
  public void Dispose(){if(!disposed){CloseHandle(handle);disposed=true;}}
 }

 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetVolumePathNameW(string path,StringBuilder mount,uint size);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetVolumeNameForVolumeMountPointW(string mount,StringBuilder name,uint size);
 public static string NativeVolume(string path) {var mount=new StringBuilder(32768);var name=new StringBuilder(64);Check(GetVolumePathNameW(Path.GetFullPath(path),mount,(uint)mount.Capacity),"Native volume path");Check(GetVolumeNameForVolumeMountPointW(mount.ToString(),name,(uint)name.Capacity),"Native volume identity");return name.ToString().ToLowerInvariant();}

 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandleW(IntPtr handle,StringBuilder path,uint size,uint flags);
 static void NativePhysical(string path) {
  path=Path.GetFullPath(path);if(path.StartsWith("\\\\",StringComparison.Ordinal)||path.Length<3||path[1]!=':')throw new InvalidOperationException("Native physical DOS path required");
  string current=path;for(;;){var h=CreateFileW(current,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);if(h==new IntPtr(-1)){int error=Marshal.GetLastWin32Error();throw new Win32Exception(error,"Native physical parent lease win32="+error.ToString(System.Globalization.CultureInfo.InvariantCulture)+" requested_sha256="+Hash(Encoding.UTF8.GetBytes(path.ToUpperInvariant()))+" component_sha256="+Hash(Encoding.UTF8.GetBytes(current.ToUpperInvariant())));}try{FileFacts(h);var final=new StringBuilder(32768);uint n=GetFinalPathNameByHandleW(h,final,(uint)final.Capacity,0);if(n==0||n>=final.Capacity)throw new Win32Exception(Marshal.GetLastWin32Error(),"Native physical final path");string resolved=final.ToString();if(resolved.StartsWith("\\\\?\\",StringComparison.Ordinal))resolved=resolved.Substring(4);if(!String.Equals(Path.GetFullPath(resolved).TrimEnd('\\'),current.TrimEnd('\\'),StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Native physical alias refused");}finally{CloseHandle(h);}var parent=Path.GetDirectoryName(current.TrimEnd('\\'));if(String.IsNullOrEmpty(parent))break;current=parent;}
 }

'@
    $actor = $actor.Substring(0, $closing) + $native + $actor.Substring($closing)
    Add-Type -TypeDefinition $actor
}

function New-DesktopNativeNsisContextText {
    param(
        [Parameter(Mandatory)][ValidateSet('install', 'uninstall')][string]$Command,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$PlanSha256,
        [Parameter(Mandatory)][ValidateSet(1033, 1041)][int]$Language,
        [Parameter(Mandatory)][bool]$StartMenu,
        [Parameter(Mandatory)][bool]$Desktop,
        [Parameter(Mandatory)][bool]$Update
    )
    foreach ($path in @($Root, $Source)) {
        Assert-Condition ([IO.Path]::IsPathFullyQualified($path) -and [IO.Path]::GetFullPath($path) -ceq $path -and $path -cmatch '^[A-Za-z]:\\' -and $path -notmatch '[\x00-\x1f\x7f-\x9f\uFEFF]') 'desktop_native_context_path_refused'
    }
    Assert-Condition ($PlanSha256 -cmatch '^[a-f0-9]{64}$') 'desktop_native_context_plan_refused'
    # Existing Rust parser and NSIS template consume exactly these ten fields.
    # The helper's CLI SHA is bound by the actual plan role, not an extra context key.
    $end = [string][char]13 + [char]10
    return [string]::Join($end, @(
        'schema=winsmux-nsis-context/v1', ('command=' + $Command), ('root=' + $Root),
        ('source=' + $Source), ('plan_sha256=' + $PlanSha256), 'version=0.38.0',
        ('language=' + $Language), ('start_menu=' + [int]$StartMenu),
        ('desktop=' + [int]$Desktop), ('update=' + [int]$Update)
    )) + $end
}

function Assert-DesktopNativeNsisResult {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][ValidateSet('install', 'uninstall')][string]$Command,
        [Parameter(Mandatory)][string]$PlanSha256,
        [Parameter(Mandatory)][string]$GuiSha256
    )
    Assert-Condition ($Result.exit_code -eq 0 -and [string]::IsNullOrWhiteSpace([string]$Result.stderr) -and -not $Result.stdout_metadata.truncated) 'desktop_native_action_failed'
    $receipt = ConvertFrom-DesktopStrictJsonText ([string]$Result.stdout)
    Assert-DesktopInventoryShape $receipt @('schema', 'operation_id', 'action', 'version', 'plan_sha256', 'startup_receipt', 'owned_registration_verified', 'durable_commit', 'outcome')
    Assert-Condition ($receipt.schema -ceq 'winsmux-desktop-nsis-transaction-receipt/v1' -and $receipt.action -ceq $Command -and $receipt.version -ceq '0.38.0' -and $receipt.plan_sha256 -ceq $PlanSha256 -and $receipt.operation_id -cmatch '^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$' -and $receipt.durable_commit -eq $true -and $receipt.owned_registration_verified -eq $true -and $receipt.outcome -ceq 'committed') 'desktop_native_action_receipt_refused'
    if ($Command -ceq 'install') {
        $startup = $receipt.startup_receipt
        Assert-DesktopInventoryShape $startup @('schema', 'operation_id', 'version', 'gui_sha256', 'normal_mount', 'native_ready', 'actor_verified', 'probe_processes_exited')
        Assert-Condition ($startup.schema -ceq 'winsmux-desktop-startup-receipt/v1' -and $startup.version -ceq '0.38.0' -and $startup.gui_sha256 -ceq $GuiSha256 -and $startup.operation_id -cmatch '^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$' -and $startup.normal_mount -eq $true -and $startup.native_ready -eq $true -and $startup.actor_verified -eq $true -and $startup.probe_processes_exited -eq $true) 'desktop_native_startup_receipt_refused'
    } else { Assert-Condition ($null -eq $receipt.startup_receipt) 'desktop_native_uninstall_receipt_refused' }
    return $receipt
}

function Assert-DesktopNativeBaselineReceipt {
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)]$Legacy)
    Assert-Condition ($Legacy.schema -ceq 'winsmux-desktop-nsis-legacy-v0380/v1' -and $Legacy.version -ceq '0.38.0' -and $Legacy.host -ceq 'x86_64-pc-windows-msvc' -and $Legacy.installed_inventory_complete -is [bool] -and $Legacy.installed_inventory_complete) 'desktop_native_legacy_profile_refused'
    Assert-Condition ($Receipt.schema -ceq 'winsmux-task880-legacy-install-capture/v1' -and $Receipt.outcome -ceq 'passed' -and $Receipt.installed_inventory_complete -is [bool] -and $Receipt.installed_inventory_complete -and $Receipt.profile_name -ceq 'ja-root') 'desktop_native_legacy_capture_refused'
    Assert-Condition ($Receipt.original_installer.bytes -eq 9920209 -and $Receipt.original_installer.sha256 -ceq 'c1f3ea807a035978a78ec12df3bb70bbf1e869cf83c7563715821df0887798e2') 'desktop_native_legacy_installer_refused'
    Assert-Condition ($null -eq $Receipt.failure -and @($Receipt.validation_failures).Count -eq 0 -and $Receipt.install_exit_code -eq 0) 'desktop_native_legacy_capture_incomplete'
    $profile = $Legacy.registration_profile
    Assert-Condition (@($Receipt.arguments).Count -eq 2 -and $Receipt.arguments[0] -ceq '/S' -and $Receipt.arguments[1] -ceq ('/D=' + $profile.root)) 'desktop_native_legacy_arguments_refused'
    Assert-Condition ($Receipt.root -ceq $profile.root -and $null -eq $Receipt.language -and $null -eq $profile.language) 'desktop_native_legacy_root_language_refused'
    Assert-Condition (@($Receipt.files).Count -eq 323 -and @($Legacy.files).Count -eq 323 -and @($Receipt.registration).Count -eq 22 -and @($profile.registration).Count -eq 22 -and @($Receipt.shortcuts).Count -eq 2 -and @($profile.shortcuts).Count -eq 2) 'desktop_native_legacy_shape_refused'
    $members = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $aliases = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $Receipt.files) {
        Assert-Condition ($row.path -is [string] -and $aliases.Add([string]$row.path)) 'desktop_native_legacy_member_alias_refused'
        $members.Add([string]$row.path, $row)
    }
    foreach ($row in $Legacy.files) {
        Assert-Condition ($members.ContainsKey([string]$row.path)) 'desktop_native_legacy_member_refused'
        $actual = $members[[string]$row.path]
        Assert-Condition ($actual.role -ceq $row.role -and $actual.bytes -eq $row.bytes -and $actual.sha256 -ceq $row.sha256) 'desktop_native_legacy_member_refused'
    }
    $raw = ConvertTo-Json -InputObject @($Receipt.registration) -Depth 32 -Compress
    $expected = ConvertTo-Json -InputObject @($profile.registration) -Depth 32 -Compress
    Assert-Condition ($raw -ceq $expected) 'desktop_native_legacy_registration_refused'
    for ($index = 0; $index -lt 2; $index++) {
        $actual = $Receipt.shortcuts[$index]; $link = $profile.shortcuts[$index]
        Assert-Condition ($actual.kind -ceq $link.kind -and $actual.bytes -eq $link.bytes -and $actual.sha256 -cmatch '^[a-f0-9]{64}$' -and $actual.target -ceq $link.target -and $actual.expected_gui -ceq $link.target -and $actual.aumid -ceq $link.aumid) 'desktop_native_legacy_shortcut_refused'
    }
    Assert-Condition ($Receipt.protected_project_before_sha256 -cmatch '^[a-f0-9]{64}$' -and $Receipt.protected_project_after_sha256 -ceq $Receipt.protected_project_before_sha256) 'desktop_native_legacy_project_refused'
    # Clause6: old VM shortcut SHA is provenance only. This transport receipt does not contain shortcut arguments or file IDs.
    # Before a real legacy update, reacquire each exactly known-folder/basename link as a plain single-link lease,
    # decode Unicode raw target/empty arguments/AUMID from the same bytes, and retain acquired ID/fullbytes/SHA.
    # Every subsequent backup/restore/uninstall must match that acquired witness. No copied link or repin.
    # Run-specific capture JSON hashes are evidence, never a replacement for compiled legacy identity.
}


function Write-DesktopNativeEvidence {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Value)
    Assert-Condition ($Name -cmatch '^[a-z0-9-]+\.json$') 'desktop_native_evidence_name_refused'
    $text = ($Value | ConvertTo-Json -Depth 64 -Compress) + [char]10
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($text)
    Assert-Condition ($bytes.Length -le 4194304) 'desktop_native_evidence_limit'
    $file = [IO.FileStream]::new((Join-Path $script:DesktopNativeEvidenceRoot $Name), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
}

function Get-DesktopNativeRawRegistration {
$nativeSlots = @(
    @('Software\github\winsmux', ''), @('Software\github\winsmux', 'Installer Language'),
    @('Software\Microsoft\Windows\CurrentVersion\Uninstall\winsmux', 'MainBinaryName'),
    @('Software\Microsoft\Windows\CurrentVersion\Uninstall\winsmux', 'DisplayName'),
    @('Software\Microsoft\Windows\CurrentVersion\Uninstall\winsmux', 'DisplayIcon'),
    @('Software\Microsoft\Windows\CurrentVersion\Uninstall\winsmux', 'DisplayVersion'),
    @('Software\Microsoft\Windows\CurrentVersion\Uninstall\winsmux', 'Publisher'),
    @('Software\Microsoft\Windows\CurrentVersion\Uninstall\winsmux', 'InstallLocation'),
    @('Software\Microsoft\Windows\CurrentVersion\Uninstall\winsmux', 'UninstallString'),
    @('Software\Microsoft\Windows\CurrentVersion\Uninstall\winsmux', 'NoModify'),
    @('Software\Microsoft\Windows\CurrentVersion\Uninstall\winsmux', 'NoRepair'),
    @('Software\Microsoft\Windows\CurrentVersion\Uninstall\winsmux', 'EstimatedSize'),
    @('Software\Classes\Directory\shell\winsmux', ''), @('Software\Classes\Directory\shell\winsmux', 'MUIVerb'),
    @('Software\Classes\Directory\shell\winsmux', 'Icon'), @('Software\Classes\Directory\shell\winsmux', 'Position'),
    @('Software\Classes\Directory\shell\winsmux\command', ''),
    @('Software\Classes\Directory\Background\shell\winsmux', ''), @('Software\Classes\Directory\Background\shell\winsmux', 'MUIVerb'),
    @('Software\Classes\Directory\Background\shell\winsmux', 'Icon'), @('Software\Classes\Directory\Background\shell\winsmux', 'Position'),
    @('Software\Classes\Directory\Background\shell\winsmux\command', '')
)
    $values = [Collections.Generic.List[object]]::new()
    foreach ($slot in $nativeSlots) {
        $value = [WinsmuxDesktopNativeActor]::NativeRegistry($slot[0], $slot[1])
        if ($null -eq $value) { $values.Add($null) } else { $values.Add([ordered]@{ type = [uint32]$value['type']; data = @($value['data'] | ForEach-Object { [int]$_ }) }) }
    }
    return ,$values.ToArray()
}

function Get-DesktopNativeWitness {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Sentinel)
    $rows = [Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $Root) {
        $rootId = [WinsmuxDesktopNativeActor]::NativeDirectory($Root, $false)
        $stack = [Collections.Generic.Stack[string]]::new(); $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $directory = $stack.Pop(); [void][WinsmuxDesktopNativeActor]::NativeDirectory($directory, $false)
            foreach ($path in @([IO.Directory]::GetFileSystemEntries($directory) | Sort-Object -CaseSensitive)) {
                $attr = [IO.File]::GetAttributes($path)
                Assert-Condition (($attr -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'desktop_native_witness_reparse'
                if (($attr -band [IO.FileAttributes]::Directory) -ne 0) { $stack.Push($path) } else {
                    $f = [WinsmuxDesktopNativeActor]::NativeFile($path)
                    $rows.Add([ordered]@{ path = [IO.Path]::GetRelativePath($Root, $path).Replace('\','/'); bytes = $f['bytes']; sha256 = $f['sha256']; identity = $f['identity'] })
                }
            }
        }
    } else { $rootId = $null }
    $links = [Collections.Generic.List[object]]::new()
    foreach ($kind in @('desktop', 'start_menu')) {
        $path = if ($kind -ceq 'desktop') { Get-DesktopShortcutPath } else { Get-DesktopStartMenuShortcutPath }
        if (Test-Path -LiteralPath $path) { $f = [WinsmuxDesktopNativeActor]::NativeFile($path); $links.Add([ordered]@{ kind = $kind; path = $path; bytes = $f['bytes']; sha256 = $f['sha256']; identity = $f['identity'] }) } else { $links.Add($null) }
    }
    if ($DesktopNativeFormat -ceq 'MSI') {
        foreach ($path in @((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)) 'winsmux.lnk'), (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) 'winsmux/winsmux.lnk'), (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonPrograms)) 'winsmux/winsmux.lnk'))) {
            if (Test-Path -LiteralPath $path) { $f = [WinsmuxDesktopNativeActor]::NativeFile($path); $links.Add([ordered]@{ kind = 'msi-fixed-slot'; path = $path; bytes = $f['bytes']; sha256 = $f['sha256']; identity = $f['identity'] }) } else { $links.Add($null) }
        }
    }
    $user = [WinsmuxDesktopNativeActor]::NativeFile($Sentinel)
    return [ordered]@{ root = $Root; root_identity = $rootId; files = @($rows | Sort-Object -Property path -CaseSensitive); registration = (Get-DesktopNativeRawRegistration); shortcuts = $links.ToArray(); user_sentinel = $user }
}

function Assert-DesktopNativeWitnessEqual {
    param([Parameter(Mandatory)]$Expected, [Parameter(Mandatory)]$Actual)
    $before = ConvertTo-Json -InputObject $Expected -Depth 64 -Compress
    $after = ConvertTo-Json -InputObject $Actual -Depth 64 -Compress
    Assert-Condition ($before -ceq $after) 'desktop_native_restoration_or_preservation_mismatch'
}

function Assert-DesktopNativeInstalledPayload {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$PlanSha256, [switch]$Managed)
    [void][WinsmuxDesktopNativeActor]::NativeDirectory($Root, $false)
    foreach ($row in $Plan.files) {
        $path = [IO.Path]::GetFullPath((Join-Path $Root ([string]$row.path).Replace('/', '\')))
        Assert-Condition (Test-PathInsideRoot -Path $path -Root $Root) 'desktop_native_installed_path_refused'
        $actual = [WinsmuxDesktopNativeActor]::NativeFile($path)
        Assert-Condition ($actual['bytes'] -eq $row.bytes -and $actual['sha256'] -ceq $row.sha256) 'desktop_native_installed_payload_mismatch'
    }
    $planPath = Join-Path $Root 'winsmux.install-plan.json'
    Assert-Condition ([WinsmuxDesktopNativeActor]::NativeFile($planPath)['sha256'] -ceq $PlanSha256) 'desktop_native_installed_plan_mismatch'
    if ($Managed) {
        $statePath = Join-Path $Root '.winsmux-desktop/installed.json'
        $state = Read-DesktopStrictJson $statePath
        Assert-Condition ($state.schema -ceq 'winsmux-desktop-nsis-installed/v1' -and $state.version -ceq '0.38.0' -and $state.root -ceq $Root -and $state.plan_sha256 -ceq $PlanSha256 -and $state.action -ceq 'install') 'desktop_native_installed_state_mismatch'
        [void](Assert-DesktopNativeNsisObservation -Kind installed -Binding (Get-DesktopNativeNsisObservationBinding -Root $Root) -PlanSha256 $PlanSha256 -State $state)
        foreach ($member in $state.members) {
            $actual = [WinsmuxDesktopNativeActor]::NativeFile((Join-Path $Root ([string]$member.path).Replace('/', '\')))
            $parts = ([string]$actual['identity']).Split(':'); $index = ([uint64]$parts[1] -shl 32) -bor [uint64]$parts[2]
            Assert-Condition ($actual['bytes'] -eq $member.bytes -and $actual['sha256'] -ceq $member.sha256 -and $index -eq [uint64]$member.identity.index -and ([WinsmuxDesktopNativeActor]::NativeVolume((Join-Path $Root ([string]$member.path).Replace('/', '\')))).TrimEnd([char]92) -ceq $member.identity.volume) 'desktop_native_installed_state_member_mismatch'
        }
        return $state
    }
}

function ConvertTo-DesktopNativeMsiLogProjection {
    param([Parameter(Mandatory)][Collections.IDictionary]$ObservationInput)
    $actionNames = @('AppSearch','CostFinalize','CostInitialize','CreateFolders','CreateShortcuts','CreateUpdateTask','DeleteUpdateTask','DownloadAndInvokeBootstrapper','FileCost','FindRelatedProducts','InstallFiles','InstallFinalize','InstallInitialize','InstallValidate','InvokeBootstrapper','InvokeStandalone','LaunchApplication','MigrateFeatureStates','ProcessComponents','PublishFeatures','PublishProduct','RegisterProduct','RegisterUser','RemoveExistingProducts','RemoveFiles','RemoveFolders','RemoveRegistryValues','RemoveShortcuts','SetARPINSTALLLOCATION','SetARPNOMODIFY','UnpublishFeatures','UpdateWebView2ViaEdgeUpdate','ValidateProductID','WinsmuxVerifyStartup','WixUIPrintEula','WixUIValidatePath','WriteRegistryValues')
    $helperNames = @('usage','plan_refused','path_refused','member_unconfirmed','actor_refused','isolation_failed','launch_failed','startup_unconfirmed','startup_timeout','probe_exit_unconfirmed')
    $diagnosticMsiExitNames = [ordered]@{'64'='usage';'65'='plan_refused';'66'='path_refused';'67'='member_unconfirmed';'68'='actor_refused';'69'='isolation_failed';'70'='launch_failed';'71'='startup_unconfirmed';'72'='startup_timeout';'73'='probe_exit_unconfirmed'}
    $diagnosticMsiPathCodes = @('1000','1001','1002','1003','1004','1005','1006','1007','1008','1009','1010','1011','1012','1013','1014','1015','1016','1017','1018','1019','1020','1021','1022','1023','1024','1025','1026','1027','1028','1029','1030','1031','1032','1033','1034','1035','1036','1037','1038','1039','1040','1041','1042','1043','1044','1045','1046','1047','1048','1049','1050','1051','1052','1053','1054','1055','1056','1057','1058','1059','1060','1061','1062','1063','1064','1065','1066','1067','1068','1069','1070','1071','1072','1073','1074','1075','1076','1077','1078','1079','1080','1081','1082','1083','1084','1085','1086','1087','1088','1089','1090','1091','1092','1093','1094','1095','1096','1097','1098','1099','1100','1101','1102','1103','1104','1105','1106','1107','1108','1109','1110','1111','1112','1113','1114','1115','1116','1117','1118','1119','1120','1121','1122','1123','1124','1125','1126','1127','1128','1129','1130','1131','1132','1133','1134','1135','1136','1137','1138','1139','1140','1141','1142','1143','1144','1145','1146','1147','1148','1149','1150','1151','1152','1153','1154','1155','1156','1157','1158','1159','1160','1161','1162','1163','1164','1165','1166','1167','1168','1169','1170','1171','1172','1173','1174','1175','1176','1177','1178','1179','1180','1181','1182','1183','1184','1185','1186','1187','1188','1189','1190','1191','1192','1193','1194','1195','1196','1197','1198','1199','1200','1201','1202','1203','1204','1205','1206','1207','1208','1209','1210','1211','1212','1213','1214','1215','1216','1217','1218','1219','1220','1221','1222','1223','1224','1225','1226','1227','1228','1229','1230','1231','1232','1233','1234','1235','1236','1237','1238','1239','1240','1241','1242','1243','1244','1245','1246','1247','1248','1249','1250','1251','1252','1253','1254','1255','1256','1257','1258','1259','1260','1261','1262','1263','1264','1265','1266')
    $errorCodes = @('112','1303','1304','1305','1307','1317','1335','1603','1618','1619','1620','1638','1708','1721','1722','2203')
    $actions = [ordered]@{}
    foreach ($name in $actionNames) {
        $returns = [ordered]@{}; foreach ($number in 0..8) { $returns[[string]$number] = 0 }
        $actions[$name] = [ordered]@{ start_count = 0; end_returns = $returns; custom_errors = [ordered]@{'2'=0;'3'=0} }
    }
    foreach ($number in $diagnosticMsiPathCodes) { $actions['WinsmuxVerifyStartup'].custom_errors[$number] = 0 }
    $errors = [ordered]@{}; foreach ($number in $errorCodes) { $errors[$number] = 0 }
    $helper = [ordered]@{}; foreach ($name in $helperNames) { $helper[$name] = 0 }
    $status = [string]$ObservationInput['status']
    if (@('observed','absent','unreadable','overlong','empty','unknown_encoding','changed') -cnotcontains $status) { $status = 'unreadable' }
    $log = $null
    if ($null -ne $ObservationInput['bytes'] -and [long]$ObservationInput['bytes'] -gt 0 -and [long]$ObservationInput['bytes'] -le 4194304 -and [string]$ObservationInput['sha256'] -cmatch '^[a-f0-9]{64}$') {
        $log = [ordered]@{ bytes = [long]$ObservationInput['bytes']; sha256 = [string]$ObservationInput['sha256'] }
    }
    $result = [ordered]@{ schema = 'winsmux-desktop-native-msi-log-observation/v1'; purpose = 'msi-install-en'; status = $status; log = $log; actions = $actions; markers = [ordered]@{INSTALL_return3=0;ExecuteAction_return3=0;MainEngineThread_return1603=0}; errors = $errors; helper = $helper; unknown = [ordered]@{action_count=0;return_count=0;code_count=0;line_count=0} }
    if ($status -cne 'observed') { return $result }
    $text = [string]$ObservationInput['text']
    if ($null -eq $log -or $text.Length -eq 0 -or $text.Length -gt 4194304) { $result.status = 'unrecognized'; return $result }
    $recognized = 0
    foreach ($line in ($text -split '\r?\n')) {
        if ($line.Length -eq 0) { continue }
        $record = $line
        if ($line -cmatch '^MSI \([cs]\) \([0-9A-Fa-f]+:[0-9A-Fa-f]+\) \[[0-9:.]+\]: (.*)$') { $record = $Matches[1] }
        if ($record -cmatch '^Action start [0-9]{1,2}:[0-9]{2}:[0-9]{2}: ([A-Za-z][A-Za-z0-9_]{0,63})\.$') {
            $name = $Matches[1]
            if ($actionNames -ccontains $name) { $actions[$name].start_count += 1; $recognized += 1 } else { $result.unknown.action_count += 1 }
        } elseif ($record -cmatch '^Action ended [0-9]{1,2}:[0-9]{2}:[0-9]{2}: ([A-Za-z][A-Za-z0-9_]{0,63})\. Return value ([0-9]{1,5})\.$') {
            $name = $Matches[1]; $number = $Matches[2]
            if ($name -ceq 'INSTALL' -and $number -ceq '3') { $result.markers.INSTALL_return3 += 1; $recognized += 1 }
            elseif ($name -ceq 'ExecuteAction' -and $number -ceq '3') { $result.markers.ExecuteAction_return3 += 1; $recognized += 1 }
            elseif ($actionNames -ccontains $name) {
                if (@('0','1','2','3','4','5','6','7','8') -ccontains $number) { $actions[$name].end_returns[$number] += 1; $recognized += 1 } else { $result.unknown.return_count += 1 }
            } else { $result.unknown.action_count += 1 }
        } elseif ($record -cmatch '^CustomAction ([A-Za-z][A-Za-z0-9_]{0,63}) returned actual error code ([0-9]{1,5})(?: \(note this may not be 100% accurate if translation happened inside sandbox\))?$') {
            $name = $Matches[1]; $number = $Matches[2]
            if ($name -ceq 'WinsmuxVerifyStartup' -and $diagnosticMsiPathCodes -ccontains $number) {
                $actions[$name].custom_errors[$number] += 1; $helper.path_refused += 1; $recognized += 1
            } elseif ($name -ceq 'WinsmuxVerifyStartup' -and $diagnosticMsiExitNames.Contains($number)) {
                $helper[$diagnosticMsiExitNames[$number]] += 1; $recognized += 1
            } elseif ($actionNames -ccontains $name) {
                if (@('2','3') -ccontains $number) { $actions[$name].custom_errors[$number] += 1; $recognized += 1 } else { $result.unknown.return_count += 1 }
            } else { $result.unknown.action_count += 1 }
        } elseif ($record -ceq 'MainEngineThread is returning 1603') { $result.markers.MainEngineThread_return1603 += 1; $recognized += 1 }
        elseif ($record -cmatch '^Error ([0-9]{1,5})(?:[.: ].*)?$' -or $record -cmatch '^Note: 1: ([0-9]{1,5})(?: 2:.*)?$') {
            $number = $Matches[1]
            if ($errorCodes -ccontains $number) { $errors[$number] += 1; $recognized += 1 } else { $result.unknown.code_count += 1 }
        } elseif ($record -cmatch '^winsmux installer: ([a-z_]+)$') {
            $name = $Matches[1]
            if ($helperNames -ccontains $name) { $helper[$name] += 1; $recognized += 1 } else { $result.unknown.code_count += 1 }
        } else { $result.unknown.line_count += 1 }
    }
    if ($recognized -eq 0) { $result.status = 'unrecognized' }
    return $result
}

function Get-DesktopNativeMsiLogObservation {
    param([Parameter(Mandatory)][string]$Root)
    try {
        $path = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Root))) 'msi-install-en.log'
        $observation = [WinsmuxDesktopNativeActor]::ReadMsiLogObservationInput($path)
    } catch { $observation = @{status='unreadable';bytes=$null;sha256=$null;text=$null} }
    $projection = ConvertTo-DesktopNativeMsiLogProjection -ObservationInput $observation
    $encoded = [Text.UTF8Encoding]::new($false,$true).GetBytes(($projection | ConvertTo-Json -Depth 8 -Compress))
    if ($encoded.Length -gt 16384) { $projection = ConvertTo-DesktopNativeMsiLogProjection -ObservationInput @{status='unreadable';bytes=$null;sha256=$null;text=$null} }
    return $projection
}

function ConvertTo-DesktopNativeNsisJournalObservation {
    param($ObservationInput,[string]$ExpectedRoot,[string]$ExpectedPlanSha,[string]$ExpectedActor)
    $unknown = [ordered]@{ status='unknown'; binding_verified=$false; phase=$null; action=$null; root_matches=$null; plan_matches=$null; actor_matches=$null; old=$null; new=$null; slots=$null }
    try {
        if ($ObservationInput.status -cne 'observed' -or $ObservationInput.bytes -le 0 -or $ObservationInput.bytes -gt 4194304) { return $unknown }
        $envelope = ConvertFrom-DesktopStrictJsonText ([string]$ObservationInput.text)
        Assert-DesktopInventoryShape $envelope @('schema','sha256','payload')
        if ($envelope.schema -cne 'winsmux-desktop-nsis-journal/v1') { return $unknown }
        $p = $envelope.payload
        Assert-DesktopInventoryShape $p @('schema','operation_id','action','actor_sid','root','root_identity','plan_sha256','plan_bytes','prior_state','old','new','slots','phase','commit_bytes','journal_identity','control_identity','ops_identity','owned_dirs')
        $phases = @('prepared','backing_up','publishing','startup_verified','registering','commit_intent','committed','restoring','restored','pending_unconfirmed')
        if ($p.schema -cne 'winsmux-desktop-nsis-pending/v1' -or $p.phase -isnot [string] -or $phases -cnotcontains $p.phase -or $p.action -isnot [string] -or @('install','uninstall') -cnotcontains $p.action) { return $unknown }
        foreach ($name in @('root','plan_sha256','actor_sid')) { if ($p.$name -isnot [string]) { return $unknown } }
        $counts = [ordered]@{}
        foreach ($name in @('old','new','slots')) {
            if ($p.$name -isnot [array]) { return $unknown }
            $allowed = if ($name -ceq 'slots') { @('prepared','write_intent','published_confirmed','restore_intent','restored') } else { @('prepared','move_intent','moved_confirmed','restore_intent','restored') }
            $map = [ordered]@{}; foreach ($phase in $allowed) { $map[$phase] = 0 }
            foreach ($row in $p.$name) {
                if ($null -eq $row -or $row.phase -isnot [string] -or $allowed -cnotcontains $row.phase) { return $unknown }
                $map[$row.phase]++
            }
            $counts[$name] = $map
        }
        return [ordered]@{ status='unverified'; binding_verified=$false; phase=$p.phase; action=$p.action; root_matches=[string]::Equals($p.root,$ExpectedRoot,[StringComparison]::OrdinalIgnoreCase); plan_matches=($p.plan_sha256 -ceq $ExpectedPlanSha); actor_matches=($p.actor_sid -ceq $ExpectedActor); old=$counts.old; new=$counts.new; slots=$counts.slots }
    } catch { return $unknown }
}

function Get-DesktopNativeNsisTimeoutJournal {
    param([string]$Root)
    try {
        $inputObservation = [WinsmuxDesktopNativeActor]::ReadNsisJournalObservationInput((Join-Path $Root '.winsmux-desktop/pending.json'))
        $planPath = Join-Path $DesktopNativeCandidateDirectory 'winsmux-nsis-plan.json'
        $planSha = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $actor = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        return ConvertTo-DesktopNativeNsisJournalObservation $inputObservation $Root $planSha $actor
    } catch { return ConvertTo-DesktopNativeNsisJournalObservation @{status='unreadable'} '' '' '' }
}

function Get-DesktopNativeNsisTimeoutSnapshot {
    param($Owned,[string]$Root)
    $snapshot = [ordered]@{ root_exited=$null; active_members=$null; exit_code=$null; roles=$null; root_windows=$null }
    try { $snapshot.root_exited = $Owned.HasExited } catch {}
    try { $snapshot.active_members = $Owned.ActiveMembers } catch {}
    if ($snapshot.root_exited -eq $true) { try { $snapshot.exit_code = $Owned.ExitCode } catch {} }
    try {
        $cli = @($script:DesktopNativePlan.files | Where-Object role -CEQ 'cli')[0]
        $gui = @($script:DesktopNativePlan.files | Where-Object role -CEQ 'gui')[0]
        $snapshot.roles = $Owned.OwnedRoleCounts($Root,[string]$cli.sha256,[string]$gui.sha256)
    } catch {}
    try { $snapshot.root_windows = $Owned.RootWindowCounts() } catch {}
    return $snapshot
}

function Get-DesktopNativeTerminalExitCode {
    param([Parameter(Mandatory)]$Owned)
    $code = $Owned.ExitCode
    Assert-Condition ($code -is [uint32] -and $code -ne [uint32]259) 'desktop_native_terminal_exit_unobserved'
    return $code
}

function Get-DesktopNativeNsisJourneyObservationSlots {
    return @('transport-before', 'legacy-capture', 'legacy-update', 'hash', 'missing', 'same-version', 'legacy-uninstall', 'fresh', 'startup-observe', 'startup-terminal', 'crash-observe', 'crash-terminal', 'crash-reentry', 'fresh-uninstall', 'transport-after')
}
function Get-DesktopNativeNsisJourneyBudgetMilliseconds {
    return [int](180000 * @(Get-DesktopNativeNsisJourneyObservationSlots).Count)
}
function Start-DesktopNativeNsisJourneyDeadline {
    Assert-Condition ($null -eq (Get-Variable -Name DesktopNativeNsisJourneyDeadline -Scope Script -ErrorAction SilentlyContinue)) 'desktop_native_nsis_journey_already_started'
    $budget=Get-DesktopNativeNsisJourneyBudgetMilliseconds
    $started=[DateTime]::UtcNow
    $script:DesktopNativeNsisJourneyDeadline=[pscustomobject]@{started=$started;deadline=$started.AddMilliseconds($budget);budget=$budget;clock=[Diagnostics.Stopwatch]::StartNew()}
}
function Get-DesktopNativeNsisJourneyRemainingMilliseconds {
    param([switch]$AllowExpired)
    $variable=Get-Variable -Name DesktopNativeNsisJourneyDeadline -Scope Script -ErrorAction SilentlyContinue
    Assert-Condition ($null -ne $variable -and $null -ne $variable.Value) 'desktop_native_nsis_journey_context_missing'
    $context=$variable.Value
    Assert-Condition ($context.started -is [DateTime] -and $context.started.Kind -eq [DateTimeKind]::Utc -and $context.deadline -is [DateTime] -and $context.deadline.Kind -eq [DateTimeKind]::Utc -and $context.budget -is [int] -and $context.budget -eq (Get-DesktopNativeNsisJourneyBudgetMilliseconds) -and $context.deadline -eq $context.started.AddMilliseconds($context.budget) -and $context.clock -is [Diagnostics.Stopwatch] -and $context.clock.IsRunning) 'desktop_native_nsis_journey_context_invalid'
    $elapsed=$context.clock.ElapsedMilliseconds
    Assert-Condition ($elapsed -ge 0) 'desktop_native_nsis_journey_context_invalid'
    $remaining=[int][Math]::Max(0,[Math]::Floor([Math]::Min(($context.deadline-[DateTime]::UtcNow).TotalMilliseconds,($context.budget-$elapsed))))
    Assert-Condition ($AllowExpired -or $remaining -gt 0) 'desktop_native_nsis_journey_expired'
    return $remaining
}

function Invoke-DesktopNativeOwnedEntry {
    param([Parameter(Mandatory)][string]$Purpose, [Parameter(Mandatory)][string]$Image, [Parameter(Mandatory)][string]$ImageSha256, [Parameter(Mandatory)][string]$Root, [string]$Package = '', [switch]$NsisJourney, [string]$StartupGuiSha256 = '')
    if ($NsisJourney) {
        Assert-Condition ($Purpose -cin @('nsis-update','nsis-fresh','nsis-uninstall')) 'desktop_native_nsis_journey_purpose_refused'
        [void](Get-DesktopNativeNsisJourneyRemainingMilliseconds)
    }
    $owned = [WinsmuxDesktopNativeActor]::StartNative($Purpose, $Image, $ImageSha256, $Root, $DesktopNativeSourceCommit, $Package, $DesktopNativeBaselineDirectory, $PSCommandPath)
    if ($Purpose -ceq 'nsis-update') { try { $owned.ArmStartupWindowObservation((Join-Path $Root 'winsmux-app.exe'), $StartupGuiSha256) } catch { } }
    $terminal = $false
    try {
        $terminal = $owned.WaitTerminal($(if ($NsisJourney) { Get-DesktopNativeNsisJourneyRemainingMilliseconds -AllowExpired } else { 180000 }))
        if (-not $terminal) {
            if ($Purpose -ceq 'msi-install-en') {
                $timeoutObservation = [ordered]@{
                    purpose = 'msi-install-en'
                    before = [ordered]@{ root_exited = $null; active_members = $null }
                    after = [ordered]@{ terminal = $null; root_exited = $null; active_members = $null; exit_code = $null }
                    msi_log = $null
                }
                try { $timeoutObservation.before.root_exited = $owned.HasExited } catch {}
                try { $timeoutObservation.before.active_members = $owned.ActiveMembers } catch {}
            }
            if ($Purpose -ceq 'nsis-update') {
                $nsisTimeout = [ordered]@{ purpose='nsis-update'; before=$null; after=$null; journal=$null }
                try { $nsisTimeout.before = Get-DesktopNativeNsisTimeoutSnapshot $owned $Root } catch {}
            }
            $owned.StopOwnedFailure()
            $terminal = $true
            if ($Purpose -ceq 'msi-install-en') {
                $timeoutObservation.after.terminal = $true
                try { $timeoutObservation.after.root_exited = $owned.HasExited } catch {}
                try { $timeoutObservation.after.active_members = $owned.ActiveMembers } catch {}
                try { $timeoutObservation.after.exit_code = $owned.ExitCode } catch {}
                try { $timeoutObservation.msi_log = Get-DesktopNativeMsiLogObservation -Root $Root } catch {}
                try { Write-DesktopNativeEvidence 'msi-en-timeout.json' $timeoutObservation } catch {}
            }
            if ($Purpose -ceq 'nsis-update') {
                $nsisTimeout.after = [ordered]@{ terminal=$true; snapshot=$null }
                try { $nsisTimeout.after.snapshot = Get-DesktopNativeNsisTimeoutSnapshot $owned $Root } catch {}
                try { $nsisTimeout.journal = Get-DesktopNativeNsisTimeoutJournal $Root } catch {}
                try { Write-DesktopNativeEvidence 'nsis-legacy-update-timeout.json' $nsisTimeout } catch {}
            }
            throw 'desktop_native_entry_timeout'
        }
        $receipt = [ordered]@{ purpose = $Purpose; exit_code = (Get-DesktopNativeTerminalExitCode $owned); process = $owned.Facts() }
        if ($Purpose -ceq 'nsis-uninstall') { $receipt.exit_code_scope = 'retained_root_process'; $receipt.helper_exit_observed = $false }
        if ($Purpose -ceq 'nsis-update') { try { $receipt.startup_gui_observation = $owned.StartupWindowObservation() } catch { $receipt.startup_gui_observation = [ordered]@{ schema='winsmux-owned-startup-gui-window/v1'; last_attempt_status='observation_unobserved'; last_observed=$null; snapshot_is_current=$false } } }
        if ($Purpose -ceq 'msi-install-en') { $receipt.msi_log = Get-DesktopNativeMsiLogObservation -Root $Root }
        return $receipt
    } finally {
        if (-not $terminal) { $owned.StopOwnedFailure(); $terminal = $true }
        if ($terminal) { $owned.Dispose() }
    }
}

function Invoke-DesktopNativeTransportCheck {
    param([Parameter(Mandatory)][string]$NodeImage, [switch]$NsisJourney)
    $result = Invoke-DesktopOwnedNativeProcess -FilePath $NodeImage -ArgumentList @('--input-type=module', '--eval', (Get-DesktopNativeTransportModule), 'verify', $DesktopNativeSourceCommit, $DesktopNativeFormat, $script:RepositoryRoot) -Environment @{} -TimeoutSeconds 180 -NsisJourney:$NsisJourney
    Assert-Condition ($result.exit_code -eq 0 -and [string]::IsNullOrWhiteSpace($result.stderr) -and -not $result.stdout_metadata.truncated) 'desktop_native_transport_refused'
    $receipt = ConvertFrom-DesktopStrictJsonText $result.Stdout
    Assert-Condition ($receipt.schema -ceq 'winsmux-desktop-native-transport-check/v1' -and $receipt.mode -ceq 'verify' -and $receipt.source_commit -ceq $DesktopNativeSourceCommit -and $receipt.format -ceq $DesktopNativeFormat -and $receipt.files -eq 9 -and $receipt.runtime_pe_count -eq 4) 'desktop_native_transport_result_refused'
    return $receipt
}


function Get-DesktopNativeInputRoot {
    $expected = Join-Path ([IO.Path]::GetFullPath($env:RUNNER_TEMP)) ('winsmux-native-input-' + $env:GITHUB_RUN_ID + '.' + $env:GITHUB_RUN_ATTEMPT + '.' + $DesktopNativeSourceCommit + '.' + $DesktopNativeFormat)
    Assert-Condition ([string]$env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_OS -ceq 'Windows' -and $env:GITHUB_RUN_ID -cmatch '^[1-9][0-9]*$' -and $env:GITHUB_RUN_ATTEMPT -cmatch '^[1-9][0-9]*$') 'desktop_native_runner_refused'
    Assert-Condition ([IO.Path]::GetFullPath($DesktopNativeCandidateDirectory) -ceq (Join-Path $expected 'candidate') -and [IO.Path]::GetFullPath($DesktopNativeBaselineDirectory) -ceq (Join-Path $expected 'baseline')) 'desktop_native_artifact_namespace_refused'
    [void][WinsmuxDesktopNativeActor]::NativeDirectory($expected, $false)
    return $expected
}

function Assert-DesktopNativeBaselineArtifact {
    $items = @([IO.Directory]::GetFileSystemEntries($DesktopNativeBaselineDirectory))
    Assert-Condition ($items.Count -eq 2 -and [string]::Join('|', @($items | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object -CaseSensitive)) -ceq 'capture.json|winsmux_0.38.0_x64-setup.exe') 'desktop_native_baseline_namespace_refused'
    $installer = Join-Path $DesktopNativeBaselineDirectory 'winsmux_0.38.0_x64-setup.exe'
    $file = [WinsmuxDesktopNativeActor]::NativeFile($installer)
    Assert-Condition ($file['bytes'] -eq 9920209 -and $file['sha256'] -ceq 'c1f3ea807a035978a78ec12df3bb70bbf1e869cf83c7563715821df0887798e2') 'desktop_native_baseline_asset_refused'
    [void][WinsmuxDesktopNativeActor]::NativeFile((Join-Path $DesktopNativeBaselineDirectory 'capture.json'))
    $legacy = Read-DesktopStrictJson (Join-Path $script:RepositoryRoot 'core/crates/winsmux-workspace/src/desktop_nsis_legacy_v0380.json')
    $receipt = Read-DesktopStrictJson (Join-Path $DesktopNativeBaselineDirectory 'capture.json')
    Assert-DesktopNativeBaselineReceipt $receipt $legacy
    return $legacy
}

function Invoke-DesktopNativeBaselineRecapture {
    param([Parameter(Mandatory)]$Legacy)
    $baseSource = Join-Path $script:RepositoryRoot '.native-baseline-source'
    $head = (& git -C $baseSource rev-parse --verify HEAD | Out-String).Trim()
    Assert-Condition ($LASTEXITCODE -eq 0 -and $head -ceq '0eaed56da31826b48fc153293c9407ec49547c91') 'desktop_native_baseline_source_refused'
    $capture = Join-Path $baseSource 'scripts/capture-desktop-baseline.ps1'
    $owner = Join-Path $baseSource 'scripts/DesktopProcessOwner.cs'
    Assert-Condition ([WinsmuxDesktopNativeActor]::NativeFile($capture)['sha256'] -ceq 'a4223bd1fde0c6c35f1d136ae933f09b3deffb9f6076bee43f572c483f1505b6' -and [WinsmuxDesktopNativeActor]::NativeFile($owner)['sha256'] -ceq 'b2ec09ebdbc9557e9a09c052186478ce1d71af95d194f88f3c5152bd5324e936') 'desktop_native_baseline_source_bytes_refused'
    $output = Join-Path $script:DesktopNativeEvidenceRoot 'legacy-actual'
    Assert-Condition (-not (Test-Path -LiteralPath $output) -and -not (Test-Path -LiteralPath $Legacy.registration_profile.root)) 'desktop_native_legacy_fixture_exists'
    $pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $result = Invoke-DesktopOwnedNativeProcess -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $capture, '-Installer', (Join-Path $DesktopNativeBaselineDirectory 'winsmux_0.38.0_x64-setup.exe'), '-Profile', 'ja-root', '-OutputDirectory', $output) -Environment @{} -NsisJourney
    Assert-Condition ($result.exit_code -eq 0 -and -not $result.stderr_metadata.truncated) 'desktop_native_actual_legacy_capture_failed'
    $receipt = Read-DesktopStrictJson (Join-Path $output 'capture.json')
    Assert-DesktopNativeBaselineReceipt $receipt $Legacy
    # This is an actual new-VM capture, not inferred from the artifact. Production admit_previous performs
    # the clause6 same-lease Unicode target / empty arguments / AUMID admission before any native mutation.
    Write-DesktopNativeEvidence 'legacy-actual-admission.json' ([ordered]@{ schema = 'winsmux-desktop-native-legacy-preflight/v1'; outcome = 'immutable_profile_matched'; capture = [WinsmuxDesktopNativeActor]::NativeFile((Join-Path $output 'capture.json')); process = $result.native_observation; shortcut_authority = 'production-same-lease-clause6-before-mutation' })
    return [string]$Legacy.registration_profile.root
}

function New-DesktopNativeFaultSource {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][ValidateSet('hash', 'missing', 'complete')][string]$Kind, [ValidateSet('legacy', 'fresh', 'capacity')][string]$Role = 'legacy')
    $sourceParent = if ($Role -ceq 'capacity') { $script:DesktopNativeCapacityVolume } else { $script:DesktopNativeEvidenceRoot }
    $source = Join-Path $sourceParent ('nsis-source-' + $Role + '-' + $Kind)
    [void][WinsmuxDesktopNativeActor]::NativeDirectory($source, $true)
    $paths = @($Plan.files | ForEach-Object { [string]$_.path }) + @('winsmux.install-plan.json', 'uninstall.exe')
    $state = Read-DesktopStrictJson (Join-Path $Root '.winsmux-desktop/installed.json')
    foreach ($link in $state.shortcuts) { $paths += 'shortcuts/' + [string]$link.kind + '.lnk' }
    foreach ($relative in $paths) {
        $from = Join-Path $Root $relative.Replace('/', '\')
        if ($relative.StartsWith('shortcuts/')) {
            $shortcut = @($state.shortcuts | Where-Object { ('shortcuts/' + $_.kind + '.lnk') -ceq $relative })[0]
            $from = if ($shortcut.kind -ceq 'desktop') { Get-DesktopShortcutPath } else { Get-DesktopStartMenuShortcutPath }
        }
        $witness = [WinsmuxDesktopNativeActor]::NativeFile($from)
        if ($Kind -ceq 'missing' -and $relative -ceq 'winsmux-app.exe') { continue }
        $to = Join-Path $source $relative.Replace('/', '\'); $parent = [IO.Path]::GetDirectoryName($to)
        $relativeParent = [IO.Path]::GetRelativePath($source, $parent)
        $cursor = $source
        foreach ($part in @($relativeParent -split '\\' | Where-Object { $_ -cne '.' -and $_ -cne '' })) {
            $cursor = Join-Path $cursor $part
            if (-not (Test-Path -LiteralPath $cursor)) { [void][WinsmuxDesktopNativeActor]::NativeDirectory($cursor, $true) } else { [void][WinsmuxDesktopNativeActor]::NativeDirectory($cursor, $false) }
        }
        $bytes = [IO.File]::ReadAllBytes($from)
        Assert-Condition ($bytes.Length -eq $witness['bytes'] -and (Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $witness['sha256']) 'desktop_native_fault_source_changed'
        if ($Kind -ceq 'hash' -and $relative -ceq 'winsmux-app.exe') { $bytes[0] = $bytes[0] -bxor 1 }
        $stream = [IO.FileStream]::new($to, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        $copied = [WinsmuxDesktopNativeActor]::NativeFile($to)
        if (-not ($Kind -ceq 'hash' -and $relative -ceq 'winsmux-app.exe')) { Assert-Condition ($copied['bytes'] -eq $witness['bytes'] -and $copied['sha256'] -ceq $witness['sha256']) 'desktop_native_fault_copy_mismatch' }
        Assert-Condition ([WinsmuxDesktopNativeActor]::NativeFile($from)['identity'] -ceq $witness['identity']) 'desktop_native_fault_source_replaced'
    }
    return $source
}

function Invoke-DesktopNativeNsisAction {
    param([Parameter(Mandatory)][ValidateSet('install', 'uninstall')][string]$Command, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Case, [Parameter(Mandatory)][string]$PlanSha256, [bool]$Links = $true, [bool]$Update = $true)
    Assert-Condition ($Case -cmatch '^[a-z0-9-]+$') 'desktop_native_case_refused'
    $context = New-DesktopNativeNsisContextText -Command $Command -Root $Root -Source $Source -PlanSha256 $PlanSha256 -Language 1041 -StartMenu $Links -Desktop $Links -Update $Update
    $path = Join-Path $script:DesktopNativeEvidenceRoot ($Case + '.context')
    $bytes = [Text.UnicodeEncoding]::new($false, $false, $true).GetBytes($context)
    $file = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
    $witness = [WinsmuxDesktopNativeActor]::NativeFile($path)
    $cli = Join-Path $DesktopNativeCandidateDirectory 'winsmux.exe'
    $expectedCli = @($script:DesktopNativePlan.files | Where-Object role -CEQ 'cli')[0]
    Assert-Condition ([WinsmuxDesktopNativeActor]::NativeFile($cli)['sha256'] -ceq $expectedCli.sha256) 'desktop_native_action_cli_mismatch'
    $result = Invoke-DesktopOwnedNativeProcess -FilePath $cli -ArgumentList @('--winsmux-internal-desktop-installer', ('nsis-' + $Command), '--context', $path) -Environment @{} -NsisJourney
    Assert-Condition ([WinsmuxDesktopNativeActor]::NativeFile($path)['identity'] -ceq $witness['identity'] -and [WinsmuxDesktopNativeActor]::NativeFile($path)['sha256'] -ceq $witness['sha256']) 'desktop_native_action_context_changed'
    Write-DesktopNativeEvidence ($Case + '-action.json') ([ordered]@{ schema = 'winsmux-desktop-native-action-observation/v1'; command = $Command; context = $witness; process = $result })
    return $result
}


function Convert-DesktopNativeObservedIdentity {
    param([Parameter(Mandatory)][string]$Identity, [Parameter(Mandatory)][string]$Volume)
    $parts = $Identity.Split(':')
    Assert-Condition ($parts.Length -eq 3) 'desktop_native_observed_identity_refused'
    return [ordered]@{ volume = $Volume.TrimEnd([char]92); index = (([uint64]$parts[1] -shl 32) -bor [uint64]$parts[2]) }
}

function Get-DesktopNativeJournalPayloadSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $document = [Text.Json.JsonDocument]::Parse([Text.UTF8Encoding]::new($false, $true).GetString($Bytes))
    try { $payloadBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($document.RootElement.GetProperty('payload').GetRawText()) } finally { $document.Dispose() }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payloadBytes)).ToLowerInvariant()
}

function Get-DesktopNativeNsisObservationBinding {
    param([Parameter(Mandatory)][string]$Root, [switch]$Journal)
    $volume = [WinsmuxDesktopNativeActor]::NativeVolume($Root)
    $binding = [ordered]@{ root = $Root; actor_sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; root_identity = (Convert-DesktopNativeObservedIdentity ([WinsmuxDesktopNativeActor]::NativeDirectory($Root, $false)) $volume) }
    if ($Journal) {
        $control = Join-Path $Root '.winsmux-desktop'; $ops = Join-Path $control 'ops'; $path = Join-Path $control 'pending.json'
        $before = [WinsmuxDesktopNativeActor]::NativeFile($path)
        $raw = [IO.File]::ReadAllBytes($path)
        $envelope = Read-DesktopStrictJson $path
        $after = [WinsmuxDesktopNativeActor]::NativeFile($path)
        $rawSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
        Assert-Condition ($before['identity'] -ceq $after['identity'] -and $before['sha256'] -ceq $after['sha256'] -and $rawSha -ceq $before['sha256']) 'desktop_native_journal_observation_changed'
        $binding.envelope = $envelope; $binding.payload_sha256 = Get-DesktopNativeJournalPayloadSha256 $raw
        $binding.journal_identity = Convert-DesktopNativeObservedIdentity $before['identity'] $volume
        $binding.journal_bytes = $before['bytes']; $binding.journal_sha256 = $before['sha256']
        $binding.control_identity = Convert-DesktopNativeObservedIdentity ([WinsmuxDesktopNativeActor]::NativeDirectory($control, $false)) $volume
        $binding.ops_identity = Convert-DesktopNativeObservedIdentity ([WinsmuxDesktopNativeActor]::NativeDirectory($ops, $false)) $volume
        $binding.ops_empty = [IO.Directory]::GetFileSystemEntries($ops).Length -eq 0
    }
    return $binding
}

function Assert-DesktopNativeNsisObservation {
    param([Parameter(Mandatory)][ValidateSet('installed','updated','publishing','uninstalled')][string]$Kind, [Parameter(Mandatory)]$Binding, [Parameter(Mandatory)][string]$PlanSha256, $State, $PriorState, $Receipt, $Witness, $PriorWitness, $Published)
    $equal = { param($Left, $Right) (ConvertTo-Json -InputObject $Left -Depth 64 -Compress) -ceq (ConvertTo-Json -InputObject $Right -Depth 64 -Compress) }
    $uuid = '^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$'
    if ($Kind -cin @('installed','updated')) {
        Assert-DesktopInventoryShape $State @('schema','generation','legacy_capture','actor_sid','root','root_identity','host','version','plan_sha256','plan_bytes','members','registration','shortcuts','operation_id','action')
        Assert-Condition ($State.schema -ceq 'winsmux-desktop-nsis-installed/v1' -and $State.generation -ceq 'managed' -and $State.action -ceq 'install' -and $State.version -ceq '0.38.0' -and $State.host -ceq 'x86_64-pc-windows-msvc' -and $State.root -ceq $Binding.root -and $State.actor_sid -ceq $Binding.actor_sid -and (& $equal $State.root_identity $Binding.root_identity) -and $State.plan_sha256 -ceq $PlanSha256 -and $State.operation_id -cmatch $uuid) 'desktop_native_managed_observation_refused'
        Assert-Condition ($State.registration.Count -eq 22 -and [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$State.plan_bytes)).ToLowerInvariant() -ceq $PlanSha256) 'desktop_native_managed_plan_bytes_refused'
        if ($null -ne $State.legacy_capture) { Assert-DesktopInventoryShape $State.legacy_capture @('original_installer_sha256','capture_receipt_sha256'); Assert-Condition ($State.legacy_capture.original_installer_sha256 -ceq 'c1f3ea807a035978a78ec12df3bb70bbf1e869cf83c7563715821df0887798e2' -and $State.legacy_capture.capture_receipt_sha256 -cmatch '^[a-f0-9]{64}$') 'desktop_native_legacy_binding_refused' }
        if ($Kind -ceq 'updated') {
            Assert-Condition ($State.operation_id -cne $PriorState.operation_id -and $State.operation_id -ceq $Receipt.operation_id -and $Receipt.action -ceq 'install' -and $Receipt.plan_sha256 -ceq $PlanSha256 -and $Receipt.outcome -ceq 'committed' -and $Receipt.durable_commit -eq $true -and $Receipt.owned_registration_verified -eq $true -and (& $equal $State.legacy_capture $PriorState.legacy_capture)) 'desktop_native_same_version_update_not_committed'
            $language = [Text.UnicodeEncoding]::new($false,$false,$true).GetBytes('1041' + [char]0)
            Assert-Condition ($State.registration.Count -eq 22 -and $State.registration[1].type -eq 1 -and [Convert]::ToBase64String([byte[]]$State.registration[1].data) -ceq [Convert]::ToBase64String($language)) 'desktop_native_update_language_not_committed'
        }
        return $State
    }
    $envelope = $Binding.envelope
    Assert-DesktopInventoryShape $envelope @('schema','sha256','payload')
    $p = $envelope.payload
    Assert-DesktopInventoryShape $p @('schema','operation_id','action','actor_sid','root','root_identity','plan_sha256','plan_bytes','prior_state','old','new','slots','phase','commit_bytes','journal_identity','control_identity','ops_identity','owned_dirs')
    Assert-Condition ($envelope.schema -ceq 'winsmux-desktop-nsis-journal/v1' -and $envelope.sha256 -ceq $Binding.payload_sha256 -and $p.schema -ceq 'winsmux-desktop-nsis-pending/v1' -and $p.operation_id -cmatch $uuid -and $p.root -ceq $Binding.root -and $p.actor_sid -ceq $Binding.actor_sid -and $p.plan_sha256 -ceq $PlanSha256 -and (& $equal $p.root_identity $Binding.root_identity) -and (& $equal $p.journal_identity $Binding.journal_identity) -and (& $equal $p.control_identity $Binding.control_identity) -and (& $equal $p.ops_identity $Binding.ops_identity)) 'desktop_native_journal_projection_refused'
    $stateRow = @($PriorWitness.files | Where-Object path -CEQ '.winsmux-desktop/installed.json')
    Assert-Condition ($stateRow.Count -eq 1 -and $null -ne $p.prior_state) 'desktop_native_journal_prior_missing'
    $priorBytes = [byte[]]$p.prior_state
    $parsedPrior = ConvertFrom-Json -InputObject ([Text.UTF8Encoding]::new($false,$true).GetString($priorBytes)) -AsHashtable -Depth 64
    Assert-Condition ((& $equal $parsedPrior $PriorState)) 'desktop_native_journal_prior_projection_mismatch'
    Assert-Condition ($priorBytes.Length -eq $stateRow[0].bytes -and [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($priorBytes)).ToLowerInvariant() -ceq $stateRow[0].sha256 -and $p.operation_id -cne $PriorState.operation_id) 'desktop_native_journal_prior_mismatch'
    if ($Kind -ceq 'publishing') {
        $row = @($p.new | Where-Object { $_.domain -ceq 'root' -and $_.member.path -ceq $Published.path })
        Assert-Condition ($p.phase -ceq 'publishing' -and $p.action -ceq 'install' -and $row.Count -eq 1 -and $row[0].member.bytes -eq $Published.bytes -and $row[0].member.sha256 -ceq $Published.sha256 -and (& $equal $row[0].member.identity $Published.identity)) 'desktop_native_crash_wrong_cut'
        return $p
    }
    Assert-Condition ($p.phase -ceq 'committed' -and $p.action -ceq 'uninstall' -and @($p.new).Count -eq 0 -and $null -eq $p.commit_bytes -and $Binding.ops_empty -eq $true) 'desktop_native_uninstall_terminal_refused'
    Assert-Condition ($Witness.root -ceq $Binding.root -and $PriorWitness.root -ceq $Binding.root -and @($Witness.files).Count -eq 1 -and $Witness.files[0].path -ceq '.winsmux-desktop/pending.json' -and $Witness.files[0].bytes -eq $Binding.journal_bytes -and $Witness.files[0].sha256 -ceq $Binding.journal_sha256 -and (& $equal (Convert-DesktopNativeObservedIdentity $Witness.files[0].identity $Binding.root_identity.volume) $Binding.journal_identity) -and @($Witness.registration | Where-Object { $null -ne $_ }).Count -eq 0 -and @($Witness.shortcuts | Where-Object { $null -ne $_ }).Count -eq 0 -and $Witness.root_identity -ceq $PriorWitness.root_identity -and $Witness.user_sentinel['identity'] -ceq $PriorWitness.user_sentinel['identity'] -and $Witness.user_sentinel['bytes'] -eq $PriorWitness.user_sentinel['bytes'] -and $Witness.user_sentinel['sha256'] -ceq $PriorWitness.user_sentinel['sha256']) 'desktop_native_uninstall_preservation_failed'
    $seenOld = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expected = @($PriorState.members | ForEach-Object { [ordered]@{domain='root';member=$_} })
    $expected += [ordered]@{domain='state';member=[ordered]@{path='installed.json';bytes=$stateRow[0].bytes;sha256=$stateRow[0].sha256;identity=(Convert-DesktopNativeObservedIdentity $stateRow[0].identity $Binding.root_identity.volume)}}
    foreach ($link in $PriorState.shortcuts) { $expected += [ordered]@{domain=$link.kind;member=$link.member} }
    Assert-Condition (@($p.old).Count -eq $expected.Count) 'desktop_native_uninstall_old_inventory_refused'
    foreach ($old in $p.old) {
        Assert-DesktopInventoryShape $old @('member','domain','phase')
        Assert-DesktopInventoryShape $old.member @('path','bytes','sha256','identity')
        Assert-Condition ($seenOld.Add($old.domain + ':' + $old.member.path)) 'desktop_native_uninstall_duplicate_row'
        $match = @($expected | Where-Object { $_.domain -ceq $old.domain -and $_.member.path -ceq $old.member.path })
        Assert-Condition ($match.Count -eq 1 -and $old.phase -ceq 'moved_confirmed' -and (& $equal $old.member $match[0].member)) 'desktop_native_uninstall_owned_row_refused'
    }
    Assert-Condition ($p.slots.Count -ge 22 -and $p.slots.Count -le 23) 'desktop_native_uninstall_slots_refused'
    for ($i=0; $i -lt $p.slots.Count; $i++) { Assert-DesktopInventoryShape $p.slots[$i] @('id','prior','desired','phase'); Assert-Condition ($p.slots[$i].id -eq $i -and $p.slots[$i].phase -ceq 'published_confirmed' -and $null -eq $p.slots[$i].desired -and ($i -ge 22 -or (& $equal $p.slots[$i].prior $PriorState.registration[$i]))) 'desktop_native_uninstall_slot_refused' }
    if ($p.slots.Count -eq 23) {
        $raw = $p.slots[22].prior; $expectedPath = [Text.UnicodeEncoding]::new($false,$false,$true).GetBytes(([string][char]34) + $Binding.root + '\winsmux-app.exe' + [char]34 + [char]0)
        Assert-Condition ($raw.type -eq 1 -and [Convert]::ToBase64String([byte[]]$raw.data) -ceq [Convert]::ToBase64String($expectedPath)) 'desktop_native_uninstall_application_slot_refused'
    }
    return $p
}


function Get-DesktopNativeNsisObserver {
    param([Parameter(Mandatory)][string]$InputRoot)
    if ($DesktopNativeFormat -cne 'NSIS') { return $null }
    $path = Join-Path (Join-Path $InputRoot 'evidence') 'nsis-observer-build.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $before = [WinsmuxDesktopNativeActor]::NativeFile($path)
    $value = Read-DesktopStrictJson $path
    Assert-DesktopInventoryShape $value @('schema','diagnostic','release_admissible','source_commit','original','diagnostic_setup','compiler','closure_files','closure_sha256','original_unchanged')
    Assert-Condition ($value.schema -ceq 'winsmux-nsis-observer-build/v1' -and $value.diagnostic -eq $true -and $value.release_admissible -eq $false -and $value.source_commit -ceq $DesktopNativeSourceCommit -and $value.original_unchanged -eq $true) 'desktop_native_observer_build_refused'
    Assert-DesktopInventoryShape $value.diagnostic_setup @('bytes','sha256')
    $setup = Join-Path (Join-Path (Join-Path $InputRoot 'diagnostic-nsis') 'output') 'nsis-output.exe'
    $actual = [WinsmuxDesktopNativeActor]::NativeFile($setup)
    Assert-Condition ($actual['bytes'] -eq $value.diagnostic_setup.bytes -and $actual['sha256'] -ceq $value.diagnostic_setup.sha256 -and [WinsmuxDesktopNativeActor]::NativeFile($path)['sha256'] -ceq $before['sha256'] -and [WinsmuxDesktopNativeActor]::NativeFile($path)['identity'] -ceq $before['identity']) 'desktop_native_observer_setup_changed'
    return [ordered]@{ setup=$setup; sha256=$actual['sha256']; root=(Join-Path $InputRoot 'diagnostic-nsis') }
}

function Write-DesktopNativeNsisObserverPrivate {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Value)
    Assert-Condition ($Name -cin @('before.json','after.json','update-process.json','uninstall-process.json','result.json','failure.json')) 'desktop_native_observer_private_name_refused'
    $text = ($Value | ConvertTo-Json -Depth 64 -Compress) + [char]10
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($text)
    $path = Join-Path $script:DesktopNativeNsisObserver.root $Name
    $stream = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

function Invoke-DesktopNativeNsisObserverJourney {
    param([Parameter(Mandatory)]$Legacy, [Parameter(Mandatory)][string]$Sentinel)
    $planPath = Join-Path $DesktopNativeCandidateDirectory 'winsmux-nsis-plan.json'
    $script:DesktopNativePlan = Read-DesktopStrictJson $planPath
    $planSha = [WinsmuxDesktopNativeActor]::NativeFile($planPath)['sha256']
    $gui = @($script:DesktopNativePlan.files | Where-Object role -CEQ 'gui')[0]
    $legacyRoot = Invoke-DesktopNativeBaselineRecapture $Legacy
    $legacyBefore = Get-DesktopNativeWitness -Root $legacyRoot -Sentinel $Sentinel
    $first = Invoke-DesktopNativeOwnedEntry -Purpose 'nsis-update' -Image $script:DesktopNativeNsisObserver.setup -ImageSha256 $script:DesktopNativeNsisObserver.sha256 -Root $legacyRoot -NsisJourney -StartupGuiSha256 $gui.sha256
    Write-DesktopNativeNsisObserverPrivate 'update-process.json' $first
    Assert-Condition ($first.exit_code -eq 0) 'LegacyProfileMismatch-or-native-update-failed'
    $state = Assert-DesktopNativeInstalledPayload -Root $legacyRoot -Plan $script:DesktopNativePlan -PlanSha256 $planSha -Managed
    Assert-Condition ($null -ne $state.legacy_capture -and $state.legacy_capture.capture_receipt_sha256 -ceq $Legacy.capture_receipt_sha256 -and $state.legacy_capture.original_installer_sha256 -ceq $Legacy.original_installer.sha256) 'desktop_native_legacy_authority_not_committed'
    Assert-Condition ([WinsmuxDesktopNativeActor]::NativeFile($Sentinel)['sha256'] -ceq $legacyBefore.user_sentinel['sha256']) 'desktop_native_user_sentinel_changed'
    $source = New-DesktopNativeFaultSource -Root $legacyRoot -Plan $script:DesktopNativePlan -Kind complete
    $updated = Invoke-DesktopNativeNsisAction -Command install -Root $legacyRoot -Source $source -Case 'nsis-same-version-ja' -PlanSha256 $planSha
    $receipt = Assert-DesktopNativeNsisResult -Result $updated -Command install -PlanSha256 $planSha -GuiSha256 $gui.sha256
    $same = Assert-DesktopNativeInstalledPayload -Root $legacyRoot -Plan $script:DesktopNativePlan -PlanSha256 $planSha -Managed
    [void](Assert-DesktopNativeNsisObservation -Kind updated -Binding (Get-DesktopNativeNsisObservationBinding -Root $legacyRoot) -PlanSha256 $planSha -State $same -PriorState $state -Receipt $receipt)
    $uninstallPrior = Get-DesktopNativeWitness -Root $legacyRoot -Sentinel $Sentinel
    Write-DesktopNativeNsisObserverPrivate 'before.json' $uninstallPrior
    $uninstaller = Join-Path $legacyRoot 'uninstall.exe'; $unSha = [WinsmuxDesktopNativeActor]::NativeFile($uninstaller)['sha256']
    $removed = Invoke-DesktopNativeOwnedEntry -Purpose 'nsis-uninstall' -Image $uninstaller -ImageSha256 $unSha -Root $legacyRoot -NsisJourney
    Write-DesktopNativeNsisObserverPrivate 'uninstall-process.json' $removed
    $afterWitness = Get-DesktopNativeWitness -Root $legacyRoot -Sentinel $Sentinel
    Write-DesktopNativeNsisObserverPrivate 'after.json' $afterWitness
    Assert-Condition ($removed.exit_code -eq 0) 'desktop_native_managed_uninstall_failed'
    [void](Assert-DesktopNativeNsisObservation -Kind uninstalled -Binding (Get-DesktopNativeNsisObservationBinding -Root $legacyRoot -Journal) -PlanSha256 $planSha -PriorState $same -PriorWitness $uninstallPrior -Witness $afterWitness)
    return [ordered]@{ diagnostic=$true; release_admissible=$false; observed_journey='completed'; original_journey_passed=$false }
}

function Invoke-DesktopNativeNsisJourney {
    param([Parameter(Mandatory)]$Legacy, [Parameter(Mandatory)][string]$Sentinel)
    $planPath = Join-Path $DesktopNativeCandidateDirectory 'winsmux-nsis-plan.json'
    $script:DesktopNativePlan = Read-DesktopStrictJson $planPath
    $planSha = [WinsmuxDesktopNativeActor]::NativeFile($planPath)['sha256']
    $gui = @($script:DesktopNativePlan.files | Where-Object role -CEQ 'gui')[0]
    $setup = Join-Path $DesktopNativeCandidateDirectory 'winsmux_0.38.0_x64-setup.exe'
    $setupSha = [WinsmuxDesktopNativeActor]::NativeFile($setup)['sha256']
    $legacyRoot = Invoke-DesktopNativeBaselineRecapture $Legacy
    $legacyBefore = Get-DesktopNativeWitness -Root $legacyRoot -Sentinel $Sentinel
    Write-DesktopNativeEvidence 'legacy-before.json' $legacyBefore
    $first = Invoke-DesktopNativeOwnedEntry -Purpose 'nsis-update' -Image $setup -ImageSha256 $setupSha -Root $legacyRoot -NsisJourney -StartupGuiSha256 $gui.sha256
    Write-DesktopNativeEvidence 'legacy-update-process.json' $first
    Assert-Condition ($first.exit_code -eq 0) 'LegacyProfileMismatch-or-native-update-failed'
    $state = Assert-DesktopNativeInstalledPayload -Root $legacyRoot -Plan $script:DesktopNativePlan -PlanSha256 $planSha -Managed
    Assert-Condition ($null -ne $state.legacy_capture -and $state.legacy_capture.capture_receipt_sha256 -ceq $Legacy.capture_receipt_sha256 -and $state.legacy_capture.original_installer_sha256 -ceq $Legacy.original_installer.sha256) 'desktop_native_legacy_authority_not_committed'
    Assert-Condition ([WinsmuxDesktopNativeActor]::NativeFile($Sentinel)['sha256'] -ceq $legacyBefore.user_sentinel['sha256']) 'desktop_native_user_sentinel_changed'
    Write-DesktopNativeEvidence 'legacy-update-state.json' $state
    $prior = Get-DesktopNativeWitness -Root $legacyRoot -Sentinel $Sentinel
    foreach ($kind in @('hash', 'missing')) {
        $source = New-DesktopNativeFaultSource -Root $legacyRoot -Plan $script:DesktopNativePlan -Kind $kind
        $failed = Invoke-DesktopNativeNsisAction -Command install -Root $legacyRoot -Source $source -Case ('nsis-' + $kind) -PlanSha256 $planSha
        Assert-Condition ($failed.exit_code -ne 0 -and [string]::IsNullOrWhiteSpace($failed.stdout) -and $failed.stderr -match '^winsmux installer: (plan_refused|member_unconfirmed|io_unconfirmed)\s*$') 'desktop_native_payload_fault_not_reached'
        $restored = Get-DesktopNativeWitness -Root $legacyRoot -Sentinel $Sentinel
        Assert-DesktopNativeWitnessEqual $prior $restored
        Write-DesktopNativeEvidence ('nsis-' + $kind + '-preserved.json') $restored
    }
    $source = New-DesktopNativeFaultSource -Root $legacyRoot -Plan $script:DesktopNativePlan -Kind complete
    $updated = Invoke-DesktopNativeNsisAction -Command install -Root $legacyRoot -Source $source -Case 'nsis-same-version-ja' -PlanSha256 $planSha
    $receipt = Assert-DesktopNativeNsisResult -Result $updated -Command install -PlanSha256 $planSha -GuiSha256 $gui.sha256
    $same = Assert-DesktopNativeInstalledPayload -Root $legacyRoot -Plan $script:DesktopNativePlan -PlanSha256 $planSha -Managed
    [void](Assert-DesktopNativeNsisObservation -Kind updated -Binding (Get-DesktopNativeNsisObservationBinding -Root $legacyRoot) -PlanSha256 $planSha -State $same -PriorState $state -Receipt $receipt)
    Write-DesktopNativeEvidence 'nsis-same-version-ja-state.json' $same
    $uninstallPrior = Get-DesktopNativeWitness -Root $legacyRoot -Sentinel $Sentinel
    $uninstaller = Join-Path $legacyRoot 'uninstall.exe'; $unSha = [WinsmuxDesktopNativeActor]::NativeFile($uninstaller)['sha256']
    $removed = Invoke-DesktopNativeOwnedEntry -Purpose 'nsis-uninstall' -Image $uninstaller -ImageSha256 $unSha -Root $legacyRoot -NsisJourney
    Write-DesktopNativeEvidence 'legacy-managed-uninstall-process.json' $removed
    Assert-Condition ($removed.exit_code -eq 0) 'desktop_native_managed_uninstall_failed'
    $after = Get-DesktopNativeWitness -Root $legacyRoot -Sentinel $Sentinel
    [void](Assert-DesktopNativeNsisObservation -Kind uninstalled -Binding (Get-DesktopNativeNsisObservationBinding -Root $legacyRoot -Journal) -PlanSha256 $planSha -PriorState $same -PriorWitness $uninstallPrior -Witness $after)
    Write-DesktopNativeEvidence 'legacy-managed-uninstall-after.json' $after
    return [ordered]@{ legacy_update = 'passed'; hash_failure = 'passed'; missing_failure = 'passed'; same_version_ja = 'passed'; managed_uninstall = 'passed' }
}

function Invoke-DesktopNativeMsiJourney {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Sentinel)
    $planPath = Join-Path $DesktopNativeCandidateDirectory 'winsmux-msi-plan.json'
    $plan = Read-DesktopStrictJson $planPath; $sha = [WinsmuxDesktopNativeActor]::NativeFile($planPath)['sha256']
    $msiexec = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'msiexec.exe'
    $msiSha = (Get-FileHash -LiteralPath $msiexec -Algorithm SHA256).Hash.ToLowerInvariant()
    $en = Join-Path $DesktopNativeCandidateDirectory 'winsmux_0.38.0_x64_en-US.msi'; $ja = Join-Path $DesktopNativeCandidateDirectory 'winsmux_0.38.0_x64_ja-JP.msi'
    $enProperties = Get-DesktopNativeMsiProperties $en; $jaProperties = Get-DesktopNativeMsiProperties $ja
    Assert-Condition ($enProperties.properties.ProductCode -cne $jaProperties.properties.ProductCode -and $enProperties.properties.ProductLanguage -ceq '1033' -and $jaProperties.properties.ProductLanguage -ceq '1041' -and $enProperties.properties.UpgradeCode -ceq $jaProperties.properties.UpgradeCode) 'desktop_native_msi_locale_upgrade_identity_refused'
    Write-DesktopNativeEvidence 'msi-container-property-admission.json' ([ordered]@{ english = $enProperties; japanese = $jaProperties })
    Assert-NoDesktopProtectedState -State (Get-DesktopProtectedState -InstallRoot $Root) -Phase 'native MSI preflight'
    $before = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
    $installed = Invoke-DesktopNativeOwnedEntry -Purpose 'msi-install-en' -Image $msiexec -ImageSha256 $msiSha -Root $Root -Package $en
    Write-DesktopNativeEvidence 'msi-en-process.json' $installed
    Assert-Condition ($installed.exit_code -eq 0) 'desktop_native_msi_en_install_failed'
    Assert-DesktopNativeInstalledPayload -Root $Root -Plan $plan -PlanSha256 $sha
    Write-DesktopNativeEvidence 'msi-en-installed.json' (Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel)
    $updated = Invoke-DesktopNativeOwnedEntry -Purpose 'msi-update-ja' -Image $msiexec -ImageSha256 $msiSha -Root $Root -Package $ja
    Write-DesktopNativeEvidence 'msi-ja-process.json' $updated
    Assert-Condition ($updated.exit_code -eq 0) 'desktop_native_msi_ja_same_version_failed'
    Assert-DesktopNativeInstalledPayload -Root $Root -Plan $plan -PlanSha256 $sha
    Write-DesktopNativeEvidence 'msi-ja-installed.json' (Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel)
    $conflict = Invoke-DesktopNativeMsiNsisConflict -Root $Root -Sentinel $Sentinel
    $gui = @($plan.files | Where-Object role -CEQ 'gui')[0]
    $startup = Invoke-DesktopNativeStartupFault -Purpose 'msi-install-en' -Image $msiexec -ImageSha256 $msiSha -Root $Root -GuiSha256 $gui.sha256 -Sentinel $Sentinel -Package $en
    $removed = Invoke-DesktopNativeOwnedEntry -Purpose 'msi-uninstall' -Image $msiexec -ImageSha256 $msiSha -Root $Root -Package $ja
    Write-DesktopNativeEvidence 'msi-uninstall-process.json' $removed
    Assert-Condition ($removed.exit_code -eq 0) 'desktop_native_msi_uninstall_failed'
    $after = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
    Assert-Condition (@($after.files).Count -eq 0 -and @($after.shortcuts | Where-Object { $null -ne $_ }).Count -eq 0 -and $after.user_sentinel['sha256'] -ceq $before.user_sentinel['sha256']) 'desktop_native_msi_uninstall_preservation_failed'
    Assert-DesktopPostUninstallOwnedState -State (Get-DesktopProtectedState -InstallRoot $Root)
    Write-DesktopNativeEvidence 'msi-uninstall-after.json' $after
    return [ordered]@{ english_install = 'passed'; japanese_same_version_update = 'passed'; nsis_conflict = $conflict; startup_failure = $startup; uninstall = 'passed' }
}


function New-DesktopNativeMsiStartupFaultArm {
    param([string]$Root)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Root))
    $admission = Read-DesktopStrictJson (Join-Path $script:DesktopNativeEvidenceRoot 'fresh-root-admission.json')
    Assert-Condition ([string]::Equals([string]$admission.root,[IO.Path]::GetFullPath($Root),[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string]$admission.parent,$parent,[StringComparison]::OrdinalIgnoreCase) -and [WinsmuxDesktopNativeActor]::NativeDirectory($parent,$false) -ceq $admission.identity) 'desktop_native_msi_fault_fixture_refused'
    $nonce = [guid]::NewGuid().ToString('D')
    $text = [ordered]@{schema='winsmux-msi-startup-fault-request/v1';nonce=$nonce} | ConvertTo-Json -Compress
    $path = Join-Path $parent 'msi-startup-fault-request.json'
    $consumed = Join-Path $parent 'msi-startup-fault-consumed.json'
    Assert-Condition (-not [IO.File]::Exists($consumed) -and -not [IO.Directory]::Exists($consumed)) 'desktop_native_msi_fault_already_consumed'
    [WinsmuxDesktopNativeActor]::CreateMsiFaultRequest($Root,$nonce)
    $actual = [WinsmuxDesktopNativeActor]::ReadMsiFaultControlInput($path)
    Assert-Condition ($actual['status'] -ceq 'observed' -and $actual['text'] -ceq $text -and $null -ne $actual['identity'] -and [WinsmuxDesktopNativeActor]::NativeDirectory($parent,$false) -ceq $admission.identity) 'desktop_native_msi_fault_arm_refused'
    return [ordered]@{nonce=$nonce;identity=$actual['identity']}
}

function ConvertTo-DesktopNativeMsiStartupFaultObservation {
    param($InputObservation,[string]$ExpectedNonce,[string]$ExpectedIdentity)
    $result = [ordered]@{ consumed=$false; identity_matches=$false; nonce_matches=$false; operation_valid=$false; applied=$false }
    try {
        if ($InputObservation['status'] -cne 'observed') { return $result }
        $claim = ConvertFrom-DesktopStrictJsonText ([string]$InputObservation['text'])
        Assert-DesktopInventoryShape $claim @('schema','nonce','operation_id','applied')
        if ($claim.schema -cne 'winsmux-msi-startup-fault-consumed/v1' -or $claim.nonce -isnot [string] -or $claim.operation_id -isnot [string] -or $claim.applied -isnot [bool]) { return $result }
        $result.consumed = $true
        $result.identity_matches = ($InputObservation['identity'] -ceq $ExpectedIdentity)
        $result.nonce_matches = ($claim.nonce -ceq $ExpectedNonce)
        $id = [guid]::Empty
        $result.operation_valid = [guid]::TryParseExact($claim.operation_id,'D',[ref]$id) -and $id.ToString('D') -ceq $claim.operation_id -and $claim.operation_id[14] -ceq '4' -and '89ab'.Contains($claim.operation_id[19])
        $result.applied = $claim.applied -and $result.identity_matches -and $result.nonce_matches -and $result.operation_valid
    } catch {}
    return $result
}

function Invoke-DesktopNativeMsiOwnedStartupFault {
    param([string]$Image,[string]$ImageSha256,[string]$Root,[string]$Sentinel,[string]$Package)
    $prior = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
    $arm = New-DesktopNativeMsiStartupFaultArm -Root $Root
    $owned = [WinsmuxDesktopNativeActor]::StartNative('msi-install-en',$Image,$ImageSha256,$Root,$DesktopNativeSourceCommit,$Package,$DesktopNativeBaselineDirectory,$PSCommandPath)
    $terminal = $false
    try {
        $terminal = $owned.WaitTerminal(180000)
        if (-not $terminal) { $owned.StopOwnedFailure();$terminal=$true;throw 'desktop_native_startup_fault_timeout' }
        $observation = ConvertTo-DesktopNativeMsiStartupFaultObservation @{'status'='unreadable'} $arm.nonce $arm.identity
        try {
            $inputObservation = [WinsmuxDesktopNativeActor]::ReadMsiFaultControlInput((Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Root))) 'msi-startup-fault-consumed.json'))
            $observation = ConvertTo-DesktopNativeMsiStartupFaultObservation $inputObservation $arm.nonce $arm.identity
        } catch {}
        $receipt = [ordered]@{exit_code=(Get-DesktopNativeTerminalExitCode $owned);process=$owned.Facts();owned_startup_fault=$observation;msi_log=$null}
        try { $receipt.msi_log = Get-DesktopNativeMsiLogObservation -Root $Root } catch {}
        Write-DesktopNativeEvidence 'msi-startup-fault-process.json' $receipt
        $realReceiptFailure = $null -ne $receipt.msi_log -and $receipt.msi_log.status -ceq 'observed' -and $receipt.msi_log.actions.WinsmuxVerifyStartup.start_count -eq 1 -and $receipt.msi_log.actions.InstallFinalize.end_returns['3'] -gt 0 -and $receipt.msi_log.markers.INSTALL_return3 -gt 0 -and $receipt.msi_log.helper.startup_unconfirmed -gt 0 -and $receipt.msi_log.helper.probe_exit_unconfirmed -eq 0
        Assert-Condition ($observation.applied -and $receipt.exit_code -ne 0 -and $realReceiptFailure) 'desktop_native_startup_fault_unmet'
        $restored = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
        Assert-DesktopNativeWitnessEqual $prior $restored
        Write-DesktopNativeEvidence 'msi-startup-fault-restored.json' $restored
        return 'passed'
    } finally {
        if (-not $terminal) { $owned.StopOwnedFailure();$terminal=$true }
        if ($terminal) { $owned.Dispose() }
    }
}

function Invoke-DesktopNativeStartupFault {
    param([Parameter(Mandatory)][string]$Purpose, [Parameter(Mandatory)][string]$Image, [Parameter(Mandatory)][string]$ImageSha256, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$GuiSha256, [Parameter(Mandatory)][string]$Sentinel, [string]$Package = '')
    if ($Purpose -ceq 'msi-install-en') { return Invoke-DesktopNativeMsiOwnedStartupFault -Image $Image -ImageSha256 $ImageSha256 -Root $Root -Sentinel $Sentinel -Package $Package }
    $prior = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
    [void](Get-DesktopNativeNsisJourneyRemainingMilliseconds)
    $owned = [WinsmuxDesktopNativeActor]::StartNative($Purpose, $Image, $ImageSha256, $Root, $DesktopNativeSourceCommit, $Package, $DesktopNativeBaselineDirectory, $PSCommandPath)
    $terminal = $false; $stopped = $null; $nonmemberObserved = $false
    try {
        while (-not $owned.HasExited -and (Get-DesktopNativeNsisJourneyRemainingMilliseconds -AllowExpired) -gt 0 -and $null -eq $stopped) {
            foreach ($process in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='winsmux-app.exe'")) {
                $held = $owned.HoldStartupGui([uint32]$process.ProcessId, (Join-Path $Root 'winsmux-app.exe'), $GuiSha256)
                if ($null -eq $held) { $nonmemberObserved = $true; continue }
                try {
                    # Keep the handle and creation identity across this command-line read. An exited/reused PID is refused.
                    $actual = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + $process.ProcessId)
                    if ($null -ne $actual -and -not $held.HasExited -and -not [string]::IsNullOrWhiteSpace([string]$actual.CommandLine)) {
                        Initialize-DesktopNativeTypes
                        $arguments = [Winsmux.PublicRelease.WindowsCommandLine]::Parse([string]$actual.CommandLine)
                        $stopped = $held.StopForStartup([string[]]$arguments)
                    }
                } finally { $held.Dispose() }
                if ($null -ne $stopped) { break }
            }
            if ($null -eq $stopped) { Start-Sleep -Milliseconds 20 }
        }
        $terminal = $owned.WaitTerminal((Get-DesktopNativeNsisJourneyRemainingMilliseconds -AllowExpired))
        if (-not $terminal) { $owned.StopOwnedFailure(); $terminal = $true; throw 'desktop_native_startup_fault_timeout' }
        $processReceipt = [ordered]@{ exit_code = (Get-DesktopNativeTerminalExitCode $owned); process = $owned.Facts(); stopped_gui = $stopped; observed_gui_outside_job = $nonmemberObserved }
        try { $processReceipt.startup_gui_observations = $owned.StartupObservations() } catch {}
        if ($Purpose -ceq 'msi-install-en') { try { $processReceipt.msi_log = Get-DesktopNativeMsiLogObservation -Root $Root } catch {} }
        Write-DesktopNativeEvidence ($DesktopNativeFormat.ToLowerInvariant() + '-startup-fault-process.json') $processReceipt
        Assert-Condition ($null -ne $stopped -and $processReceipt.exit_code -ne 0) 'desktop_native_startup_fault_unmet'
        $restored = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
        Assert-DesktopNativeWitnessEqual $prior $restored
        Write-DesktopNativeEvidence ($DesktopNativeFormat.ToLowerInvariant() + '-startup-fault-restored.json') $restored
        return 'passed'
    } finally {
        if (-not $terminal) { $owned.StopOwnedFailure(); $terminal = $true }
        if ($terminal) { $owned.Dispose() }
    }
}

function Invoke-DesktopNativeNsisCrashFault {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$PlanSha256, [Parameter(Mandatory)][string]$Sentinel)
    $prior = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
    $priorState = Read-DesktopStrictJson (Join-Path $Root '.winsmux-desktop/installed.json')
    $first = $script:DesktopNativePlan.files[0]
    $before = [WinsmuxDesktopNativeActor]::NativeFile((Join-Path $Root $first.path))
    $text = New-DesktopNativeNsisContextText -Command install -Root $Root -Source $Source -PlanSha256 $PlanSha256 -Language 1041 -StartMenu $true -Desktop $true -Update $true
    $context = Join-Path $script:DesktopNativeEvidenceRoot 'nsis-crash.context'
    $bytes = [Text.UnicodeEncoding]::new($false, $false, $true).GetBytes($text)
    $stream = [IO.FileStream]::new($context, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $cli = Join-Path $DesktopNativeCandidateDirectory 'winsmux.exe'
    [void](Get-DesktopNativeNsisJourneyRemainingMilliseconds)
    $owned = Start-OwnedProcess -FilePath $cli -ArgumentList @('--winsmux-internal-desktop-installer', 'nsis-install', '--context', $context) -Environment @{}
    $observed = $null; $terminal = $false
    try {
        while (-not $owned.process.HasExited -and (Get-DesktopNativeNsisJourneyRemainingMilliseconds -AllowExpired) -gt 0) {
            try {
                $published = [WinsmuxDesktopNativeActor]::NativeFile((Join-Path $Root $first.path))
                if ($published['identity'] -cne $before['identity'] -and $published['sha256'] -ceq $first.sha256 -and $published['bytes'] -eq $first.bytes) { $observed = $published; break }
            } catch [ComponentModel.Win32Exception] { } catch [IO.IOException] { }
            Start-Sleep -Milliseconds 1
        }
        Assert-Condition ($null -ne $observed) 'desktop_native_publication_cut_unmet'
        $owned.owner.ForceFailureCleanup(180000, 50)
        Assert-Condition ($owned.owner.WaitTerminal(180000, 50)) 'desktop_native_crash_job_terminal_unconfirmed'
        $terminal = $true
        $process = Get-OwnedProcessCapture $owned
        # Active share-mode-zero journal is never read. Read only after this exact owned Job and pipe capture terminate.
        $journal = Get-DesktopNativeNsisObservationBinding -Root $Root -Journal
        $published = [ordered]@{path=$first.path;bytes=$observed['bytes'];sha256=$observed['sha256'];identity=(Convert-DesktopNativeObservedIdentity $observed['identity'] $journal.root_identity.volume)}
        $pending = Assert-DesktopNativeNsisObservation -Kind publishing -Binding $journal -PlanSha256 $PlanSha256 -PriorState $priorState -PriorWitness $prior -Published $published
        Write-DesktopNativeEvidence 'nsis-crash-publishing-cut.json' ([ordered]@{ observed = $observed; process = $process; pending = $pending })
    } finally {
        if (-not $terminal -and -not $owned.owner.WaitTerminal(0, 50)) { $owned.owner.ForceFailureCleanup(180000, 50) }
        if ($owned.owner.WaitTerminal(180000, 50)) { $owned.owner.Dispose() }
    }
    $reentry = Invoke-DesktopNativeNsisAction -Command install -Root $Root -Source $Source -Case 'nsis-crash-reentry' -PlanSha256 $PlanSha256
    $current = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
    if ($reentry.exit_code -eq 0) {
        $gui = @($script:DesktopNativePlan.files | Where-Object role -CEQ 'gui')[0]
        [void](Assert-DesktopNativeNsisResult -Result $reentry -Command install -PlanSha256 $PlanSha256 -GuiSha256 $gui.sha256)
        [void](Assert-DesktopNativeInstalledPayload -Root $Root -Plan $script:DesktopNativePlan -PlanSha256 $PlanSha256 -Managed)
        Assert-Condition ($current.user_sentinel['identity'] -ceq $prior.user_sentinel['identity'] -and $current.user_sentinel['sha256'] -ceq $prior.user_sentinel['sha256']) 'desktop_native_crash_user_data_changed'
        $outcome = 'full-q'
    } elseif ($reentry.exit_code -eq 3 -and $reentry.stderr -match '^winsmux installer: pending_unconfirmed\s*$') {
        $outcome = 'truthful-pending'
    } else { Assert-DesktopNativeWitnessEqual $prior $current; $outcome = 'exact-p' }
    Write-DesktopNativeEvidence 'nsis-crash-reentry-state.json' ([ordered]@{ outcome = $outcome; witness = $current })
    Assert-Condition ($outcome -cne 'truthful-pending') 'desktop_native_crash_preserved_pending_needs_recovery'
    return 'passed'
}


function Get-DesktopNativeMsiProperties {
    param([Parameter(Mandatory)][string]$Path)
    $witness = [WinsmuxDesktopNativeActor]::NativeFile($Path)
    $installer = $null; $database = $null; $view = $null; $record = $null
    $values = [ordered]@{}
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.OpenDatabase($Path, 0)
        $view = $database.OpenView('SELECT `Property`, `Value` FROM `Property`')
        [void]$view.Execute()
        while ($null -ne ($record = $view.Fetch())) {
            $key = [string]$record.StringData(1)
            if ($key -cin @('ProductCode', 'UpgradeCode', 'ProductVersion', 'ProductLanguage', 'ProductName', 'Manufacturer')) { Assert-Condition (-not $values.Contains($key)) 'desktop_native_msi_property_duplicate'; $values[$key] = [string]$record.StringData(2) }
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record); $record = $null
        }
        [void]$view.Close()
    } finally {
        foreach ($com in @($record, $view, $database, $installer)) { if ($null -ne $com) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) } }
    }
    $after = [WinsmuxDesktopNativeActor]::NativeFile($Path)
    Assert-Condition ($after['identity'] -ceq $witness['identity'] -and $after['sha256'] -ceq $witness['sha256'] -and $values.Count -eq 6) 'desktop_native_msi_property_source_changed'
    Assert-Condition ($values.ProductCode -cmatch '^\{[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}\}$' -and $values.UpgradeCode -ceq '{5A7BA441-A5F4-5622-B257-7BF2575E6D74}' -and $values.ProductVersion -ceq '0.38.0' -and $values.ProductName -ceq 'winsmux' -and $values.Manufacturer -ceq 'github') 'desktop_native_msi_product_identity_refused'
    return [ordered]@{ properties = $values; file = $witness }
}

function New-DesktopNativeFreshRoot {
    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($local) -and [IO.Path]::IsPathFullyQualified($local)) 'desktop_native_local_profile_refused'
    [void][WinsmuxDesktopNativeActor]::NativeDirectory($local, $false)
    $prefix = Join-Path $local 'winsmux-task880-native'
    if (Test-Path -LiteralPath $prefix) { [void][WinsmuxDesktopNativeActor]::NativeDirectory($prefix, $false) } else { [void][WinsmuxDesktopNativeActor]::NativeDirectory($prefix, $true) }
    $owned = Join-Path $prefix ($env:GITHUB_RUN_ID + '.' + $env:GITHUB_RUN_ATTEMPT + '.' + $DesktopNativeSourceCommit + '.' + $DesktopNativeFormat)
    $id = [WinsmuxDesktopNativeActor]::NativeDirectory($owned, $true)
    $root = Join-Path $owned '日本語 & winsmux'
    $volume = [WinsmuxDesktopNativeActor]::NativeVolume($owned)
    foreach ($known in @([Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory), [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs))) {
        [void][WinsmuxDesktopNativeActor]::NativeDirectory($known, $false)
        Assert-Condition ([WinsmuxDesktopNativeActor]::NativeVolume($known) -ceq $volume) 'desktop_native_known_folder_volume_mismatch'
    }
    Write-DesktopNativeEvidence 'fresh-root-admission.json' ([ordered]@{ parent = $owned; identity = $id; root = $root; volume = $volume })
    return $root
}

function Invoke-DesktopNativeFreshNsis {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Sentinel)
    $setup = Join-Path $DesktopNativeCandidateDirectory 'winsmux_0.38.0_x64-setup.exe'; $setupSha = [WinsmuxDesktopNativeActor]::NativeFile($setup)['sha256']
    $planPath = Join-Path $DesktopNativeCandidateDirectory 'winsmux-nsis-plan.json'; $plan = Read-DesktopStrictJson $planPath; $sha = [WinsmuxDesktopNativeActor]::NativeFile($planPath)['sha256']; $gui = @($plan.files | Where-Object role -CEQ 'gui')[0]
    Assert-NoDesktopProtectedState -State (Get-DesktopProtectedState -InstallRoot $Root) -Phase 'native NSIS fresh preflight'
    $installed = Invoke-DesktopNativeOwnedEntry -Purpose 'nsis-fresh' -Image $setup -ImageSha256 $setupSha -Root $Root -NsisJourney
    Write-DesktopNativeEvidence 'nsis-fresh-process.json' $installed
    Assert-Condition ($installed.exit_code -eq 0) 'desktop_native_nsis_fresh_failed'
    [void](Assert-DesktopNativeInstalledPayload -Root $Root -Plan $plan -PlanSha256 $sha -Managed)
    Write-DesktopNativeEvidence 'nsis-fresh-state.json' (Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel)
    $script:DesktopNativePlan = $plan
    $complete = New-DesktopNativeFaultSource -Root $Root -Plan $plan -Kind complete -Role fresh
    $startup = Invoke-DesktopNativeStartupFault -Purpose 'nsis-update' -Image $setup -ImageSha256 $setupSha -Root $Root -GuiSha256 $gui.sha256 -Sentinel $Sentinel
    $crash = Invoke-DesktopNativeNsisCrashFault -Root $Root -Source $complete -PlanSha256 $sha -Sentinel $Sentinel
    $uninstallState = Read-DesktopStrictJson (Join-Path $Root '.winsmux-desktop/installed.json')
    $uninstallPrior = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
    $uninstaller = Join-Path $Root 'uninstall.exe'; $unSha = [WinsmuxDesktopNativeActor]::NativeFile($uninstaller)['sha256']
    $removed = Invoke-DesktopNativeOwnedEntry -Purpose 'nsis-uninstall' -Image $uninstaller -ImageSha256 $unSha -Root $Root -NsisJourney
    Write-DesktopNativeEvidence 'nsis-fresh-uninstall-process.json' $removed
    Assert-Condition ($removed.exit_code -eq 0) 'desktop_native_nsis_fresh_uninstall_failed'
    $after = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
    [void](Assert-DesktopNativeNsisObservation -Kind uninstalled -Binding (Get-DesktopNativeNsisObservationBinding -Root $Root -Journal) -PlanSha256 $sha -PriorState $uninstallState -PriorWitness $uninstallPrior -Witness $after)
    Write-DesktopNativeEvidence 'nsis-fresh-uninstall-after.json' $after
    return [ordered]@{ fresh = 'passed'; startup_failure = $startup; publishing_crash = $crash; uninstall = 'passed' }
}


function Get-DesktopNativeBootstrapBinding {
    param([Parameter(Mandatory)][string]$InputRoot, [switch]$Create)
    $path = Join-Path (Join-Path $InputRoot 'evidence') 'bootstrap-input.json'
    $scriptWitness = [WinsmuxDesktopNativeActor]::NativeFile($PSCommandPath)
    if ($Create) {
        $command = Get-Command node -CommandType Application -TotalCount 1 -ErrorAction Stop
        $nodePath = [string]$command.Source
        Assert-Condition ($command.CommandType -eq [Management.Automation.CommandTypes]::Application -and [IO.Path]::IsPathFullyQualified($nodePath) -and [IO.Path]::GetFileName($nodePath) -ieq 'node.exe') 'desktop_native_node_image_refused'
        $node = [WinsmuxDesktopNativeActor]::NativeFile($nodePath)
        $version = Invoke-DesktopOwnedNativeProcess -FilePath $nodePath -ArgumentList @('--version') -Environment @{} -TimeoutSeconds 180
        Assert-Condition ($version.exit_code -eq 0 -and $version.stdout.Trim() -cmatch '^v24\.[0-9]+\.[0-9]+$' -and [string]::IsNullOrWhiteSpace($version.stderr) -and -not $version.stdout_metadata.truncated) 'desktop_native_node_version_refused'
        $binding = [ordered]@{ schema = 'winsmux-desktop-native-bootstrap-helper/v1'; source_commit = $DesktopNativeSourceCommit; script_sha256 = $scriptWitness['sha256']; node_path = [IO.Path]::GetFullPath($nodePath); node_sha256 = $node['sha256']; node_identity = $node['identity'] }
        Write-DesktopNativeEvidence 'bootstrap-input.json' $binding
    }
    $before = [WinsmuxDesktopNativeActor]::NativeFile($path)
    $binding = Read-DesktopStrictJson $path
    Assert-DesktopInventoryShape $binding @('schema', 'source_commit', 'script_sha256', 'node_path', 'node_sha256', 'node_identity')
    Assert-Condition ($binding.schema -ceq 'winsmux-desktop-native-bootstrap-helper/v1' -and $binding.source_commit -ceq $DesktopNativeSourceCommit -and $binding.script_sha256 -ceq $scriptWitness['sha256'] -and $binding.node_sha256 -cmatch '^[a-f0-9]{64}$' -and [IO.Path]::IsPathFullyQualified([string]$binding.node_path) -and [IO.Path]::GetFileName([string]$binding.node_path) -ieq 'node.exe') 'desktop_native_bootstrap_binding_refused'
    $node = [WinsmuxDesktopNativeActor]::NativeFile([string]$binding.node_path)
    Assert-Condition ($node['sha256'] -ceq $binding.node_sha256 -and $node['identity'] -ceq $binding.node_identity -and [WinsmuxDesktopNativeActor]::NativeFile($path)['identity'] -ceq $before['identity'] -and [WinsmuxDesktopNativeActor]::NativeFile($path)['sha256'] -ceq $before['sha256']) 'desktop_native_bootstrap_helper_changed'
    return $binding
}

function Invoke-DesktopNativeLifecycle {
    Assert-Condition ($Repository -ceq 'Sora-bluesky/winsmux') 'desktop_native_repository_refused'
    Initialize-DesktopNativeLifecycleActor
    $inputRoot = Get-DesktopNativeInputRoot
    $script:DesktopNativeEvidenceRoot = Join-Path $inputRoot 'evidence'
    $actor = [WinsmuxDesktopNativeActor]::Query()
    $facts = $actor['facts']; $high = [uint32]$facts['elevation'] -eq 1 -and [uint32]$facts['integrity_rid'] -ge 12288
    $medium = [uint32]$facts['elevation'] -eq 0 -and [uint32]$facts['integrity_rid'] -ge 8192 -and [uint32]$facts['integrity_rid'] -lt 12288
    Assert-Condition ($actor['existing_profile_hive'] -eq $true -and $actor['local_app_data_exists'] -eq $true -and [uint32]$facts['token_type'] -eq 1 -and [uint32]$facts['app_container'] -eq 0 -and ($high -or $medium)) 'desktop_native_actual_actor_refused'
    $bootstrap = $DesktopNativeFormat -ceq 'NSIS' -and $high
    if (-not $bootstrap -and $DesktopNativeFormat -ceq 'NSIS') { Assert-Condition $medium 'desktop_native_medium_required' }
    if ($high) {
        $observerBuild = Join-Path $script:DesktopNativeEvidenceRoot 'nsis-observer-build.json'
        if ($DesktopNativeFormat -ceq 'NSIS' -and (Test-Path -LiteralPath $observerBuild)) { [void][WinsmuxDesktopNativeActor]::NativeDirectory($script:DesktopNativeEvidenceRoot, $false) } else { [void][WinsmuxDesktopNativeActor]::NativeDirectory($script:DesktopNativeEvidenceRoot, $true) }
        $binding = Get-DesktopNativeBootstrapBinding -InputRoot $inputRoot -Create
    } else {
        [void][WinsmuxDesktopNativeActor]::NativeDirectory($script:DesktopNativeEvidenceRoot, $false)
        $binding = Get-DesktopNativeBootstrapBinding -InputRoot $inputRoot
    }
    $capacityStage = $medium -and $DesktopNativeFormat -ceq 'NSIS' -and (Test-Path -LiteralPath (Join-Path $script:DesktopNativeEvidenceRoot 'capacity-request.json'))
    $normalNsisJourney = $medium -and $DesktopNativeFormat -ceq 'NSIS' -and -not $capacityStage
    if ($normalNsisJourney) { Start-DesktopNativeNsisJourneyDeadline }
    $transport = Invoke-DesktopNativeTransportCheck -NodeImage $binding.node_path -NsisJourney:$normalNsisJourney
    $legacy = Assert-DesktopNativeBaselineArtifact
    $script:DesktopNativeNsisObserver = Get-DesktopNativeNsisObserver -InputRoot $inputRoot
    if ($null -ne $script:DesktopNativeNsisObserver) { Assert-Condition (-not $capacityStage) 'desktop_native_observer_capacity_refused' }
    if ($capacityStage) { return Invoke-DesktopNativeCapacityStage -InputRoot $inputRoot }
    Write-DesktopNativeEvidence $(if ($bootstrap) { 'high-parent-admission.json' } else { 'native-admission.json' }) ([ordered]@{ transport = $transport; actor = $actor; baseline_artifact = [WinsmuxDesktopNativeActor]::NativeFile((Join-Path $DesktopNativeBaselineDirectory 'capture.json')); script_sha256 = $binding.script_sha256 })
    if ($bootstrap) {
        $pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $sha = [WinsmuxDesktopNativeActor]::NativeFile($pwsh)['sha256']
        $owned = [WinsmuxDesktopNativeActor]::StartNative('medium-bootstrap', $pwsh, $sha, $inputRoot, $DesktopNativeSourceCommit, $DesktopNativeCandidateDirectory, $DesktopNativeBaselineDirectory, $PSCommandPath)
        $terminal = $false
        try {
            $terminal = $owned.WaitTerminal((Get-DesktopNativeNsisJourneyBudgetMilliseconds))
            if (-not $terminal) { $owned.StopOwnedFailure(); $terminal = $true; throw 'desktop_native_medium_bootstrap_timeout' }
            Write-DesktopNativeEvidence 'medium-bootstrap-process.json' ([ordered]@{ exit_code = $owned.ExitCode; process = $owned.Facts() })
            $resultPath = Join-Path $script:DesktopNativeEvidenceRoot 'native-journey-result.json'
            if ($null -eq $script:DesktopNativeNsisObserver) { [void][WinsmuxDesktopNativeActor]::NativeFile($resultPath) }
            if ($null -ne $script:DesktopNativeNsisObserver) {
                $diagnosticPath = Join-Path $script:DesktopNativeNsisObserver.root 'result.json'
                $diagnostic = Read-DesktopStrictJson $diagnosticPath
                Assert-DesktopInventoryShape $diagnostic @('schema','source_commit','diagnostic','release_admissible','original_journey_passed','outcome')
                Assert-Condition ($diagnostic.schema -ceq 'winsmux-nsis-observer-journey/v1' -and $diagnostic.source_commit -ceq $DesktopNativeSourceCommit -and $diagnostic.diagnostic -eq $true -and $diagnostic.release_admissible -eq $false -and $diagnostic.original_journey_passed -eq $false -and $diagnostic.outcome -cin @('observed','failed')) 'desktop_native_observer_journey_refused'
                return $diagnostic
            }
            $result = Read-DesktopStrictJson $resultPath
            Assert-Condition ($owned.ExitCode -eq 0 -and $result.outcome -ceq 'journey_passed' -and $result.schema -ceq 'winsmux-desktop-native-journey-ci/v1' -and $result.source_commit -ceq $DesktopNativeSourceCommit -and $result.format -ceq 'NSIS') 'desktop_native_medium_journey_failed'
            $final = [ordered]@{ schema = 'winsmux-desktop-native-lifecycle-ci/v1'; source_commit = $DesktopNativeSourceCommit; format = 'NSIS'; outcome = 'failed'; transport = $transport; actor = $result.actor; cases = [ordered]@{ legacy = $result.cases.legacy; fresh = $result.cases.fresh }; failure = $null; preserved_user = $result.preserved_user }
            try {
                $sentinel = Join-Path (Join-Path (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'winsmux-task880-native') ($env:GITHUB_RUN_ID + '.' + $env:GITHUB_RUN_ATTEMPT + '.' + $DesktopNativeSourceCommit + '.NSIS')) 'user-project-sentinel.txt'
                $final.cases.capacity = Invoke-DesktopNativeCapacityCases -Sentinel $sentinel
                [void](Invoke-DesktopNativeTransportCheck -NodeImage $binding.node_path)
                $final.outcome = 'passed'
            } catch { $final.failure = $_.Exception.GetType().FullName + ': ' + $_.Exception.Message }
            Write-DesktopNativeEvidence 'native-result.json' $final
            return $final
        } finally {
            if (-not $terminal) { $owned.StopOwnedFailure(); $terminal = $true }
            if ($terminal) { $owned.Dispose() }
        }
    }
    $root = New-DesktopNativeFreshRoot
    $sentinel = Join-Path ([IO.Path]::GetDirectoryName($root)) 'user-project-sentinel.txt'
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes('TASK880 owned user project; installer must preserve these bytes.' + [char]10)
    $file = [IO.FileStream]::new($sentinel, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
    $user = [WinsmuxDesktopNativeActor]::NativeFile($sentinel)
    if ($null -ne $script:DesktopNativeNsisObserver) {
        $diagnostic = [ordered]@{ schema='winsmux-nsis-observer-journey/v1'; source_commit=$DesktopNativeSourceCommit; diagnostic=$true; release_admissible=$false; original_journey_passed=$false; outcome='failed' }
        try {
            [void](Invoke-DesktopNativeNsisObserverJourney -Legacy $legacy -Sentinel $sentinel)
            $afterUser = [WinsmuxDesktopNativeActor]::NativeFile($sentinel)
            Assert-Condition ($afterUser['identity'] -ceq $user['identity'] -and $afterUser['sha256'] -ceq $user['sha256']) 'desktop_native_final_user_preservation_failed'
            [void](Invoke-DesktopNativeTransportCheck -NodeImage $binding.node_path -NsisJourney)
            $diagnostic.outcome = 'observed'
        } catch {
            try { Write-DesktopNativeNsisObserverPrivate 'failure.json' ([ordered]@{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message; stack=$_.ScriptStackTrace }) } catch { }
        }
        Write-DesktopNativeNsisObserverPrivate 'result.json' $diagnostic
        return $diagnostic
    }
    $result = [ordered]@{ schema = 'winsmux-desktop-native-lifecycle-ci/v1'; source_commit = $DesktopNativeSourceCommit; format = $DesktopNativeFormat; outcome = 'failed'; transport = $transport; actor = $actor; cases = [ordered]@{}; failure = $null; preserved_user = $null }
    try {
        if ($DesktopNativeFormat -ceq 'NSIS') {
            $result.cases.legacy = Invoke-DesktopNativeNsisJourney -Legacy $legacy -Sentinel $sentinel
            $result.cases.fresh = Invoke-DesktopNativeFreshNsis -Root $root -Sentinel $sentinel
        } else { $result.cases.msi = Invoke-DesktopNativeMsiJourney -Root $root -Sentinel $sentinel }
        if ($DesktopNativeFormat -ceq 'MSI') { $result.cases.capacity = Invoke-DesktopNativeCapacityCases -Sentinel $sentinel }
        $after = [WinsmuxDesktopNativeActor]::NativeFile($sentinel)
        Assert-Condition ($after['identity'] -ceq $user['identity'] -and $after['sha256'] -ceq $user['sha256']) 'desktop_native_final_user_preservation_failed'
        $result.preserved_user = $after
        [void](Invoke-DesktopNativeTransportCheck -NodeImage $binding.node_path -NsisJourney:$normalNsisJourney)
        $result.outcome = if ($medium -and $DesktopNativeFormat -ceq 'NSIS') { 'journey_passed' } else { 'passed' }
        if ($medium -and $DesktopNativeFormat -ceq 'NSIS') { $result.schema = 'winsmux-desktop-native-journey-ci/v1' }
    } catch {
        $result.failure = $_.Exception.GetType().FullName + ': ' + $_.Exception.Message
        try {
            $nativeStack = [Collections.Generic.List[string]]::new()
            foreach ($frame in ([string]$_.ScriptStackTrace -split '\r?\n')) {
                $match = [regex]::Match($frame, '^\s*at (?<name>Get-DesktopNativeWitness|Get-DesktopNativeNsisObservationBinding|Invoke-DesktopNativeNsisJourney|Invoke-DesktopNativeFreshNsis|Invoke-DesktopNativeMsiJourney|Invoke-DesktopNativeLifecycle), [^\r\n]*: line (?<line>[1-9][0-9]*)\s*$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
                $nativeLine = 0
                if ($match.Success -and [int]::TryParse($match.Groups['line'].Value, [ref]$nativeLine) -and $nativeLine -gt 0) {
                    $nativeStack.Add($match.Groups['name'].Value + ':' + $nativeLine.ToString([Globalization.CultureInfo]::InvariantCulture))
                }
            }
            if ($nativeStack.Count -gt 0) { $result.failure += ' [desktop_native_stack=' + [string]::Join(',', $nativeStack) + ']' }
        } catch { }
    }
    Write-DesktopNativeEvidence $(if ($medium -and $DesktopNativeFormat -ceq 'NSIS') { 'native-journey-result.json' } else { 'native-result.json' }) $result
    return $result
}


function Invoke-DesktopNativeMsiNsisConflict {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Sentinel)
    $before = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
    $setup = Join-Path $DesktopNativeCandidateDirectory 'winsmux_0.38.0_x64-setup.exe'
    $sha = [WinsmuxDesktopNativeActor]::NativeFile($setup)['sha256']
    $process = Invoke-DesktopNativeOwnedEntry -Purpose 'msi-nsis-conflict' -Image $setup -ImageSha256 $sha -Root $Root
    Write-DesktopNativeEvidence 'msi-nsis-conflict-process.json' $process
    Assert-Condition ($process.exit_code -ne 0) 'desktop_native_msi_nsis_conflict_not_refused'
    $after = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
    Assert-DesktopNativeWitnessEqual $before $after
    Write-DesktopNativeEvidence 'msi-nsis-conflict-preserved.json' $after
    return 'passed'
}

function Initialize-DesktopNativeOwnedVhdSupport {
    if ($null -ne ([Management.Automation.PSTypeName]'Winsmux.DesktopNativeVhd.Lease').Type) { return }
# Private TASK-880 fragment. Calls require the single disposable-CI supervisor.
# No native child, other writer, or other disk operation may run concurrently.
# Dot-sourcing only defines helpers and compiles the private file-witness type.
$script:DesktopNativeVhdStates = [Collections.Generic.Dictionary[object,object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Winsmux.DesktopNativeVhd {
 public sealed class Witness {
  public string canonical_path; public uint volume_serial; public ulong file_id;
 }
 public sealed class Lease : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct Info {
   public uint attr,ctlo,cthi,atlo,athi,wtlo,wthi,serial,sizehi,sizelo,links,indexhi,indexlo;
  }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr sa,uint c,uint f,IntPtr t);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info i);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder b,uint n,uint f);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle h,int kind,ref byte flag,uint size);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetDiskFreeSpaceExW(string p,out ulong available,out ulong total,out ulong free);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetVolumeNameForVolumeMountPointW(string p,StringBuilder b,uint n);
  readonly SafeFileHandle handle; readonly bool directory; readonly string path;
  public readonly Witness identity;
  static void Check(bool ok) { if(!ok)throw new Win32Exception(Marshal.GetLastWin32Error()); }
  static string Final(SafeFileHandle h) {
   uint n=GetFinalPathNameByHandleW(h,null,0,0); Check(n!=0);
   var b=new StringBuilder(checked((int)n+1)); uint got=GetFinalPathNameByHandleW(h,b,(uint)b.Capacity,0); Check(got!=0 && got<b.Capacity);
   string p=b.ToString(); if(p.StartsWith(@"\\?\",StringComparison.Ordinal))p=p.Substring(4); return p;
  }
  public static Witness Read(SafeFileHandle h,string path,bool dir) {
   Info i; Check(GetFileInformationByHandle(h,out i));
   if((i.attr&0x400)!=0 || ((i.attr&0x10)!=0)!=dir || (!dir && (i.links!=1 || (i.attr&(0x200|0x800))!=0)))throw new IOException("Nonplain witness refused");
   string actual=Final(h); if(!String.Equals(actual.TrimEnd('\\'),path.TrimEnd('\\'),StringComparison.OrdinalIgnoreCase))throw new IOException("Canonical witness mismatch");
   return new Witness{canonical_path=actual,volume_serial=i.serial,file_id=((ulong)i.indexhi<<32)|i.indexlo};
  }
  public Lease(string p,bool dir,bool deleteAccess) {
   path=Path.GetFullPath(p); directory=dir;
   handle=CreateFileW(path,(dir?0x80u:0x80000000u)|(deleteAccess?0x10000u:0u),3,IntPtr.Zero,3,0x200000|(dir?0x2000000u:0u),IntPtr.Zero);
   if(handle.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());
   try { identity=Read(handle,path,dir); } catch {handle.Dispose();throw;}
  }
  public void Verify() { var x=Read(handle,path,directory); if(x.volume_serial!=identity.volume_serial || x.file_id!=identity.file_id)throw new IOException("Held identity changed"); }
  public void CheckVhdxMagic() { Verify(); byte[] b=new byte[8]; if(RandomAccess.Read(handle,b,0)!=8 || Encoding.ASCII.GetString(b)!="vhdxfile")throw new IOException("VHDX magic refused"); }
  public void Delete() { Verify(); byte flag=1; Check(SetFileInformationByHandle(handle,4,ref flag,1)); }
  public void Dispose() { handle.Dispose(); }
  public static ulong[] Free(string p) { ulong a,t,f;Check(GetDiskFreeSpaceExW(p,out a,out t,out f));return new[]{a,t,f}; }
  public static string Volume(string p) { var b=new StringBuilder(50);Check(GetVolumeNameForVolumeMountPointW(p,b,(uint)b.Capacity));return b.ToString(); }
  public static long[] Budget(long payload) {
   if(payload<=0)throw new ArgumentOutOfRangeException("payload");
   // Three resident payloads (source/current/incoming; rollback is a same-volume move).
   // Two payloads are a filesystem-format allowance, checked against actual free space.
   long data=checked(payload*3), requested=checked(payload*5), mib=1048576;
   long units=checked(requested/mib+(requested%mib==0?0:1)); return new[]{units,checked(units*mib),data};
  }
 }
}
'@


}

function Assert-DesktopNativeVhdCondition { param([bool]$Condition,[string]$Reason) if(-not $Condition){throw $Reason} }
function Get-DesktopNativeVhdJson { param($Value) ConvertTo-Json -InputObject $Value -Depth 12 -Compress }
function Get-DesktopNativeVhdOwnedRoot {
 param([string]$OwnedRoot)
 Assert-DesktopNativeVhdCondition ($env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_OS -ceq 'Windows' -and [IntPtr]::Size -eq 8) 'owned_vhd_ci_only'
 Assert-DesktopNativeVhdCondition ($env:GITHUB_RUN_ID -cmatch '^[1-9][0-9]*$' -and $env:GITHUB_RUN_ATTEMPT -cmatch '^[1-9][0-9]*$') 'owned_vhd_run_identity'
 Assert-DesktopNativeVhdCondition ($DesktopNativeSourceCommit -cmatch '^[0-9a-f]{40}$' -and $DesktopNativeFormat -cin @('NSIS','MSI')) 'owned_vhd_source_identity'
 $tempRoot=[IO.Path]::GetFullPath($env:RUNNER_TEMP)
 $inputRoot=Join-Path $tempRoot ('winsmux-native-input-'+$env:GITHUB_RUN_ID+'.'+$env:GITHUB_RUN_ATTEMPT+'.'+$DesktopNativeSourceCommit+'.'+$DesktopNativeFormat)
 $evidenceRoot=Join-Path $inputRoot 'evidence'
 $full=[IO.Path]::GetFullPath($OwnedRoot)
 Assert-DesktopNativeVhdCondition ($OwnedRoot -ceq $full -and $full.StartsWith($evidenceRoot+'\',[StringComparison]::Ordinal) -and [IO.Path]::GetDirectoryName($full) -ceq $evidenceRoot -and [IO.Path]::GetFileName($full) -cmatch '^vhd-owned-[0-9a-f]{32}$') 'owned_vhd_root_scope'
 Assert-DesktopNativeVhdCondition ($full -cmatch '^[A-Za-z]:\\[^\r\n"]+$' -and $full -notmatch '[^\x20-\x7e]' -and $full -notmatch '[~]' -and $full.Substring(2) -notmatch ':') 'owned_vhd_plain_ascii_control_path'
 return $full
}
function Update-DesktopNativeVhdRecord {
 param($State)
 $State.Record.image_path=$State.ImagePath; $State.Record.image_witness=$State.ImageWitness
 $State.Record.volume_root=$State.VolumeRoot; $State.Record.disk_number=$State.DiskNumber
 $State.Record.mount_witness=$State.MountWitness; $State.Record.filler_path=$State.FillerPath
 $State.RecordJson=Get-DesktopNativeVhdJson $State.Record
}
function Get-DesktopNativeVhdState {
 param($Owned)
 Assert-DesktopNativeVhdCondition ($null -ne $Owned -and $script:DesktopNativeVhdStates.ContainsKey($Owned)) 'owned_vhd_unknown_record'
 $state=$script:DesktopNativeVhdStates[$Owned]
 Assert-DesktopNativeVhdCondition ((Get-DesktopNativeVhdJson $Owned) -ceq $state.RecordJson) 'owned_vhd_record_changed'
 return $state
}
function Write-DesktopNativeVhdReceipt {
 param($State,[string]$Phase,$Facts)
 $State.Phase=$Phase
 foreach($lease in $State.RootLeases){$lease.Verify()}
 $line=Get-DesktopNativeVhdJson ([ordered]@{phase=$Phase;owned=$State.Record;capacity_bytes=$State.Capacity;payload_bytes=$State.Payload;facts=$Facts})
 $bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($line+"`n")
 $State.ReceiptStream.Write($bytes,0,$bytes.Length);$State.ReceiptStream.Flush($true)
}
function Invoke-DesktopNativeVhdDiskPart {
 param($State,[ValidateSet('create','attach','detach')][string]$Operation)
 $registered=Get-DesktopNativeVhdState $State.Record
 Assert-DesktopNativeVhdCondition ([object]::ReferenceEquals($State,$registered)) 'owned_vhd_unknown_state'
 $requiredPhase=@{create='creating';attach='image-witnessed';detach='detach-intent'}[$Operation]
 Assert-DesktopNativeVhdCondition ($State.Phase -ceq $requiredPhase) 'owned_vhd_operation_phase'
 foreach($lease in $State.RootLeases){$lease.Verify()}
 if($Operation -ne 'create'){$State.ImageLease.CheckVhdxMagic()}
 $commands=switch($Operation){
  create { Assert-DesktopNativeVhdCondition (-not [IO.File]::Exists($State.ImagePath)) 'owned_vhd_preexisting_image'; 'create vdisk file="'+$State.ImagePath+'" maximum='+$State.MiB+' type=expandable' }
  attach { 'select vdisk file="'+$State.ImagePath+'"'; 'attach vdisk' }
  detach { 'select vdisk file="'+$State.ImagePath+'"'; 'detach vdisk' }
 }
 $text=([string]::Join("`r`n",@($commands)+@('exit')))+"`r`n"
 $commandPath=Join-Path $State.Root ($Operation+'.diskpart.txt')
 $ascii=[Text.ASCIIEncoding]::new().Clone();$ascii.EncoderFallback=[Text.EncoderExceptionFallback]::new()
 $cmdStream=[IO.FileStream]::new($commandPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 try{$b=$ascii.GetBytes($text);$cmdStream.Write($b,0,$b.Length);$cmdStream.Flush($true)}finally{$cmdStream.Dispose()}
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path ([Environment]::SystemDirectory) 'diskpart.exe';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.ArgumentList.Add('/s');$start.ArgumentList.Add($commandPath);$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $process=[Diagnostics.Process]::new();$process.StartInfo=$start
 $out=[IO.FileStream]::new((Join-Path $State.Root ($Operation+'.stdout.bin')),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 $err=[IO.FileStream]::new((Join-Path $State.Root ($Operation+'.stderr.bin')),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 try{
  Assert-DesktopNativeVhdCondition ($process.Start()) 'owned_vhd_diskpart_start_failed'
  $outTask=$process.StandardOutput.BaseStream.CopyToAsync($out);$errTask=$process.StandardError.BaseStream.CopyToAsync($err)
  $process.WaitForExit();[void]$outTask.GetAwaiter().GetResult();[void]$errTask.GetAwaiter().GetResult()
  $exit=$process.ExitCode;$out.Flush($true);$err.Flush($true)
  Write-DesktopNativeVhdReceipt $State ($Operation+'-terminal') @{exit_code=$exit;command_file=$commandPath}
  Assert-DesktopNativeVhdCondition ($exit -eq 0) ('owned_vhd_diskpart_'+$Operation+'_failed')
 }finally{$out.Dispose();$err.Dispose();$process.Dispose()}
}
function Assert-DesktopNativeVhdDiskFacts {
 param($Image,$Disk,$State)
 Assert-DesktopNativeVhdCondition ($null -ne $Image -and $Image.Attached -is [bool] -and $Image.Attached -and [int]$Image.StorageType -eq 3 -and [string]$Image.ImagePath -ceq $State.ImagePath -and [uint64]$Image.Size -eq [uint64]$State.Capacity) 'owned_vhd_image_mapping'
 $busTypeProperty=if($null -ne $Disk){$Disk.psBase.CimInstanceProperties['BusType']}else{$null}
 $busType=if($null -ne $busTypeProperty){$busTypeProperty.Value}else{$null}
 Assert-DesktopNativeVhdCondition ($null -ne $Disk -and $Disk.IsBoot -is [bool] -and $Disk.IsSystem -is [bool] -and -not $Disk.IsBoot -and -not $Disk.IsSystem -and $null -ne $busTypeProperty -and $busTypeProperty.CimType -eq [Microsoft.Management.Infrastructure.CimType]::UInt16 -and $busType -is [uint16] -and $busType -eq 15 -and [uint64]$Disk.Size -eq [uint64]$State.Capacity -and -not [string]::IsNullOrWhiteSpace([string]$Disk.Path)) 'owned_vhd_nonboot_filebacked_disk'
 $key=[ordered]@{number=[uint32]$Disk.Number;path=[string]$Disk.Path;serial=[string]$Disk.SerialNumber;size=[uint64]$Disk.Size;bus_type=[int]$busType;device_path=[string]$Image.DevicePath}
 $expectedDevicePath='\\.\PHYSICALDRIVE'+$key.number.ToString([Globalization.CultureInfo]::InvariantCulture)
 Assert-DesktopNativeVhdCondition ([regex]::IsMatch($key.device_path,'\A[\x00-\x7F]+\z',[Text.RegularExpressions.RegexOptions]::CultureInvariant) -and [string]::Equals($key.device_path,$expectedDevicePath,[StringComparison]::OrdinalIgnoreCase)) 'owned_vhd_device_number'
 $key.device_path=$expectedDevicePath
 if($null -ne $State.DiskAnchor){Assert-DesktopNativeVhdCondition ((Get-DesktopNativeVhdJson $key) -ceq $State.DiskAnchor) 'owned_vhd_disk_identity_changed'}
 return $key
}
function Get-DesktopNativeVhdMapping {
 param($State,[ValidateSet('raw','gpt','mounted')][string]$Stage)
 $registered=Get-DesktopNativeVhdState $State.Record
 Assert-DesktopNativeVhdCondition ([object]::ReferenceEquals($State,$registered)) 'owned_vhd_unknown_mapping_state'
 $State.ImageLease.CheckVhdxMagic()
 $images=@(Storage\Get-DiskImage -ImagePath $State.ImagePath -ErrorAction Stop)
 Assert-DesktopNativeVhdCondition ($images.Count -eq 1) 'owned_vhd_image_count'
 $disks=@($images[0] | Storage\Get-Disk -ErrorAction Stop)
 Assert-DesktopNativeVhdCondition ($disks.Count -eq 1) 'owned_vhd_disk_count'
 $disk=$disks[0];$key=Assert-DesktopNativeVhdDiskFacts $images[0] $disk $State
 if($null -eq $State.DiskAnchor){$State.DiskAnchor=Get-DesktopNativeVhdJson $key;$State.DiskNumber=[int]$disk.Number;Update-DesktopNativeVhdRecord $State}
 if($Stage -eq 'raw'){Assert-DesktopNativeVhdCondition ([string]$disk.PartitionStyle -ceq 'RAW' -and [uint32]$disk.NumberOfPartitions -eq 0) 'owned_vhd_expected_fresh_raw'}
 else {
  Assert-DesktopNativeVhdCondition ([string]$disk.PartitionStyle -ceq 'GPT' -and -not [string]::IsNullOrWhiteSpace([string]$disk.UniqueId)) 'owned_vhd_expected_gpt'
  if($null -ne $State.GptId){Assert-DesktopNativeVhdCondition ([string]$disk.UniqueId -ceq $State.GptId) 'owned_vhd_gpt_id_changed'}
 }
 if($Stage -eq 'mounted'){
  $partitions=@($disk | Storage\Get-Partition -ErrorAction Stop | Where-Object PartitionNumber -eq $State.PartitionNumber)
  Assert-DesktopNativeVhdCondition ($partitions.Count -eq 1) 'owned_vhd_partition_count'
  $partition=$partitions[0]
  Assert-DesktopNativeVhdCondition ([string]$partition.Guid -ceq $State.PartitionGuid -and [uint32]$partition.DiskNumber -eq [uint32]$State.DiskNumber) 'owned_vhd_partition_identity'
  $volumes=@($partition | Storage\Get-Volume -ErrorAction Stop)
  Assert-DesktopNativeVhdCondition ($volumes.Count -eq 1) 'owned_vhd_volume_count'
  $volume=$volumes[0]
  $actual=[ordered]@{unique_id=[string]$volume.UniqueId;path=[string]$volume.Path;drive_letter=[string]$volume.DriveLetter;size=[uint64]$volume.Size;filesystem=[string]$volume.FileSystem;label=[string]$volume.FileSystemLabel;partition_guid=[string]$partition.Guid;disk_number=[int]$disk.Number}
  if($null -ne $State.MountJson){Assert-DesktopNativeVhdCondition ((Get-DesktopNativeVhdJson $actual) -ceq $State.MountJson) 'owned_vhd_mount_changed'}
  return @{Disk=$disk;Partition=$partition;Volume=$volume;Mount=$actual}
 }
 return @{Disk=$disk}
}

function New-DesktopNativeOwnedVhd {
 [CmdletBinding()] param([Parameter(Mandatory)][string]$OwnedRoot,[Parameter(Mandatory)][long]$PayloadBytes)
 $budget=[Winsmux.DesktopNativeVhd.Lease]::Budget($PayloadBytes)
 $root=Get-DesktopNativeVhdOwnedRoot $OwnedRoot
 $state=$null;$leases=[Collections.Generic.List[object]]::new();$cursor=$root
 try{
  while($null -ne $cursor){$leases.Add([Winsmux.DesktopNativeVhd.Lease]::new($cursor,$true,$false));$parent=[IO.Directory]::GetParent($cursor);$cursor=if($null -eq $parent){$null}else{$parent.FullName}}
  Assert-DesktopNativeVhdCondition ([IO.Directory]::GetFileSystemEntries($root).Length -eq 0) 'owned_vhd_root_not_fresh_empty'
  $nonce=[Guid]::NewGuid().ToString('N')
  $record=[pscustomobject][ordered]@{image_path=(Join-Path $root 'owned.vhdx');image_witness=$null;volume_root=$null;disk_number=$null;mount_witness=$null;filler_path=$null}
  $state=@{Record=$record;Root=$root;RootLeases=$leases;ImagePath=$record.image_path;ImageWitness=$null;ImageLease=$null;VolumeRoot=$null;VolumeLease=$null;DiskNumber=$null;MountWitness=$null;MountJson=$null;DiskAnchor=$null;GptId=$null;PartitionNumber=$null;PartitionGuid=$null;FillerPath=$null;FillerStream=$null;FillerWitness=$null;Payload=$PayloadBytes;MiB=$budget[0];Capacity=$budget[1];DataBudget=$budget[2];Nonce=$nonce;Phase='new';Closed=$false;Shortage=$null;ReceiptStream=$null}
  $state.ReceiptStream=[IO.FileStream]::new((Join-Path $root 'ownership.jsonl'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  Update-DesktopNativeVhdRecord $state;$script:DesktopNativeVhdStates.Add($record,$state)
  Write-DesktopNativeVhdReceipt $state 'creating' @{exclusive_ci_scope=$true;initial_image_witness=$false}
  Invoke-DesktopNativeVhdDiskPart $state create
  $state.ImageLease=[Winsmux.DesktopNativeVhd.Lease]::new($state.ImagePath,$false,$false);$state.ImageLease.CheckVhdxMagic()
  $state.ImageWitness=$state.ImageLease.identity;Update-DesktopNativeVhdRecord $state
  $created=@(Storage\Get-DiskImage -ImagePath $state.ImagePath -ErrorAction Stop)
  Assert-DesktopNativeVhdCondition ($created.Count -eq 1 -and $created[0].Attached -is [bool] -and -not $created[0].Attached -and [int]$created[0].StorageType -eq 3 -and [uint64]$created[0].Size -eq [uint64]$state.Capacity) 'owned_vhd_created_image_refused'
  Write-DesktopNativeVhdReceipt $state 'image-witnessed' @{witness_begins_after_successful_create=$true}
  Invoke-DesktopNativeVhdDiskPart $state attach
  $mapping=Get-DesktopNativeVhdMapping $state raw
  Write-DesktopNativeVhdReceipt $state 'initialize-intent' @{disk_anchor=$state.DiskAnchor}
  $null=Storage\Initialize-Disk -InputObject $mapping.Disk -PartitionStyle GPT -PassThru -ErrorAction Stop
  $mapping=Get-DesktopNativeVhdMapping $state gpt;$state.GptId=[string]$mapping.Disk.UniqueId
  Write-DesktopNativeVhdReceipt $state 'partition-intent' @{gpt_id=$state.GptId}
  $parts=@(Storage\New-Partition -InputObject $mapping.Disk -UseMaximumSize -AssignDriveLetter -ErrorAction Stop)
  Assert-DesktopNativeVhdCondition ($parts.Count -eq 1 -and [uint32]$parts[0].DiskNumber -eq [uint32]$state.DiskNumber -and -not [string]::IsNullOrWhiteSpace([string]$parts[0].Guid)) 'owned_vhd_new_partition_refused'
  $state.PartitionNumber=[uint32]$parts[0].PartitionNumber;$state.PartitionGuid=[string]$parts[0].Guid
  $mapping=Get-DesktopNativeVhdMapping $state mounted
  Write-DesktopNativeVhdReceipt $state 'format-intent' @{partition_guid=$state.PartitionGuid;volume_unique_id=[string]$mapping.Volume.UniqueId}
  $null=Storage\Format-Volume -InputObject $mapping.Volume -FileSystem NTFS -AllocationUnitSize 4096 -NewFileSystemLabel ('winsmux-vhd-'+$nonce.Substring(0,16)) -Force -Confirm:$false -ErrorAction Stop
  $mapping=Get-DesktopNativeVhdMapping $state mounted
  Assert-DesktopNativeVhdCondition ($mapping.Mount.filesystem -ceq 'NTFS' -and $mapping.Mount.drive_letter -cmatch '^[A-Z]$') 'owned_vhd_formatted_volume_refused'
  $state.VolumeRoot=$mapping.Mount.drive_letter+':\';$state.VolumeLease=[Winsmux.DesktopNativeVhd.Lease]::new($state.VolumeRoot,$true,$false)
  $nativeVolume=[Winsmux.DesktopNativeVhd.Lease]::Volume($state.VolumeRoot)
  Assert-DesktopNativeVhdCondition ($nativeVolume.Equals($mapping.Mount.path,[StringComparison]::OrdinalIgnoreCase) -or $nativeVolume.Equals($mapping.Mount.unique_id,[StringComparison]::OrdinalIgnoreCase)) 'owned_vhd_drive_volume_mismatch'
  $state.MountJson=Get-DesktopNativeVhdJson $mapping.Mount
  $state.MountWitness=[pscustomobject]@{mapping=$mapping.Mount;root=$state.VolumeLease.identity;volume_guid=$nativeVolume}
  $state.FillerPath=Join-Path $state.VolumeRoot ('.winsmux-native-capacity-'+$nonce+'.bin')
  Update-DesktopNativeVhdRecord $state
  $free=[Winsmux.DesktopNativeVhd.Lease]::Free($nativeVolume)
  Assert-DesktopNativeVhdCondition ($free[2] -ge [uint64]$state.DataBudget) 'owned_vhd_actual_format_overhead_exceeded_budget'
  Write-DesktopNativeVhdReceipt $state 'ready' @{free_available=$free[0];free_total=$free[2];filesystem_and_partition_consumed=([uint64]$state.Capacity-$free[2]);required_data_budget=$state.DataBudget}
  return $record
 }catch{
  if($null -ne $state -and $null -ne $state.ReceiptStream){Write-DesktopNativeVhdReceipt $state 'failed' @{reason=$_.Exception.Message};$errorOwned=[InvalidOperationException]::new('owned_vhd_new_failed_preserved',$_.Exception);$errorOwned.Data['OwnedVhd']=$state.Record;throw $errorOwned}
  foreach($lease in $leases){$lease.Dispose()};throw
 }
}
function Set-DesktopNativeVhdShortage {
 [CmdletBinding()] param([Parameter(Mandatory)]$Owned,[Parameter(Mandatory)][long]$RequiredBytes)
 Assert-DesktopNativeVhdCondition ($RequiredBytes -gt 0) 'owned_vhd_required_bytes'
 $state=Get-DesktopNativeVhdState $Owned
 Assert-DesktopNativeVhdCondition (-not $state.Closed -and $state.Phase -cin @('ready','shortage')) 'owned_vhd_not_ready'
 $null=Get-DesktopNativeVhdMapping $state mounted;$state.VolumeLease.Verify()
 $writeError=$null
 $before=[Winsmux.DesktopNativeVhd.Lease]::Free($state.MountWitness.volume_guid)
 if($null -ne $state.Shortage){Assert-DesktopNativeVhdCondition ($state.Shortage.required_bytes -eq $RequiredBytes -and $before[2] -lt [uint64]$RequiredBytes) 'owned_vhd_shortage_reentry_changed';return @{before_free_bytes=$before[2];after_free_bytes=$before[2];required_bytes=$RequiredBytes;reused=$true}}
 if($before[2] -ge [uint64]$RequiredBytes){
  $state.FillerStream=[IO.FileStream]::new($state.FillerPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
  $state.FillerWitness=[Winsmux.DesktopNativeVhd.Lease]::Read($state.FillerStream.SafeFileHandle,$state.FillerPath,$false)
  Assert-DesktopNativeVhdCondition ($state.FillerWitness.volume_serial -eq $state.VolumeLease.identity.volume_serial) 'owned_vhd_filler_cross_volume'
  $remaining=[uint64]$before[2]-[uint64][decimal]::Floor(([decimal]$RequiredBytes)/2)
  $buffer=[byte[]]::new(1048576);$writeError=$null
  try{while($remaining -gt 0){$count=if($remaining -gt [uint64]$buffer.Length){$buffer.Length}else{[int]$remaining};$state.FillerStream.Write($buffer,0,$count);$remaining-=[uint64]$count};$state.FillerStream.Flush($true)}catch{$writeError=$_.Exception;Assert-DesktopNativeVhdCondition (($writeError.HResult -band 0xffff) -in @(39,112)) 'owned_vhd_filler_write_failed'}
 }
 $null=Get-DesktopNativeVhdMapping $state mounted;$state.VolumeLease.Verify()
 $after=[Winsmux.DesktopNativeVhd.Lease]::Free($state.MountWitness.volume_guid)
 Assert-DesktopNativeVhdCondition ($after[2] -lt [uint64]$RequiredBytes) 'owned_vhd_shortage_not_observed'
 $state.Shortage=@{before_free_bytes=$before[2];after_free_bytes=$after[2];before_available_bytes=$before[0];after_available_bytes=$after[0];required_bytes=$RequiredBytes;filler_path=$state.FillerPath;filler_witness=$state.FillerWitness;disk_full_write_observed=($null -ne $writeError)}
 Write-DesktopNativeVhdReceipt $state 'shortage' $state.Shortage
 return $state.Shortage
}
function Close-DesktopNativeOwnedVhd {
 [CmdletBinding()] param([Parameter(Mandatory)]$Owned)
 $state=Get-DesktopNativeVhdState $Owned
 if($state.Closed){return @{closed=$true;reused=$true;observed_close=$state.CloseResult}}
 Assert-DesktopNativeVhdCondition ($null -ne $state.ImageLease -and $null -ne $state.MountWitness -and $state.Phase -cin @('ready','shortage')) 'owned_vhd_partial_or_unknown_preserved'
 $null=Get-DesktopNativeVhdMapping $state mounted;$state.VolumeLease.Verify()
 if($null -ne $state.FillerStream){$held=[Winsmux.DesktopNativeVhd.Lease]::Read($state.FillerStream.SafeFileHandle,$state.FillerPath,$false);Assert-DesktopNativeVhdCondition ((Get-DesktopNativeVhdJson $held) -ceq (Get-DesktopNativeVhdJson $state.FillerWitness)) 'owned_vhd_filler_changed';$state.FillerStream.Dispose();$state.FillerStream=$null}
 $state.VolumeLease.Dispose();$state.VolumeLease=$null
 Write-DesktopNativeVhdReceipt $state 'detach-intent' @{mount_witness=$state.MountWitness}
 Invoke-DesktopNativeVhdDiskPart $state detach
 $state.ImageLease.CheckVhdxMagic();$images=@(Storage\Get-DiskImage -ImagePath $state.ImagePath -ErrorAction Stop)
 Assert-DesktopNativeVhdCondition ($images.Count -eq 1 -and $images[0].Attached -is [bool] -and -not $images[0].Attached -and [string]$images[0].ImagePath -ceq $state.ImagePath) 'owned_vhd_detach_not_observed'
 $state.ImageLease.Dispose();$state.ImageLease=$null
 $deletion=[Winsmux.DesktopNativeVhd.Lease]::new($state.ImagePath,$false,$true)
 try{Assert-DesktopNativeVhdCondition ((Get-DesktopNativeVhdJson $deletion.identity) -ceq (Get-DesktopNativeVhdJson $state.ImageWitness)) 'owned_vhd_delete_identity_changed';$deletion.Delete()}finally{$deletion.Dispose()}
 Assert-DesktopNativeVhdCondition (-not [IO.File]::Exists($state.ImagePath) -and -not [IO.Directory]::Exists($state.ImagePath)) 'owned_vhd_post_delete_unknown_preserved'
 $state.CloseResult=@{closed=$true;detached_observed=$true;owned_image_removed=$true;image_witness=$state.ImageWitness;mount_witness=$state.MountWitness}
 Write-DesktopNativeVhdReceipt $state 'closed' $state.CloseResult;$state.Closed=$true
 $state.ReceiptStream.Dispose();foreach($lease in $state.RootLeases){$lease.Dispose()}
 return $state.CloseResult
}


function Invoke-DesktopNativeCapacityStage {
    param([Parameter(Mandatory)][string]$InputRoot)
    $requestPath = Join-Path $script:DesktopNativeEvidenceRoot 'capacity-request.json'
    $requestFile = [WinsmuxDesktopNativeActor]::NativeFile($requestPath)
    $request = Read-DesktopStrictJson $requestPath
    Assert-DesktopInventoryShape $request @('schema', 'stage', 'source_commit', 'script_sha256', 'candidate_receipt_sha256', 'plan_sha256', 'cli_sha256', 'setup_sha256', 'owned_vhd', 'root', 'root_identity', 'volume_identity', 'source', 'context', 'user_sentinel')
    Assert-Condition ($request.schema -ceq 'winsmux-desktop-native-capacity-request/v1' -and $request.stage -cin @('fresh-container', 'native-shortage', 'cleanup') -and $request.source_commit -ceq $DesktopNativeSourceCommit -and $request.script_sha256 -ceq [WinsmuxDesktopNativeActor]::NativeFile($PSCommandPath)['sha256']) 'desktop_native_capacity_request_refused'
    $candidate = Read-DesktopStrictJson (Join-Path $DesktopNativeCandidateDirectory 'desktop-native-candidate.json')
    Assert-Condition ($request.candidate_receipt_sha256 -ceq [WinsmuxDesktopNativeActor]::NativeFile((Join-Path $DesktopNativeCandidateDirectory 'desktop-native-candidate.json'))['sha256'] -and $candidate.format -ceq 'NSIS') 'desktop_native_capacity_origin_refused'
    $planPath = Join-Path $DesktopNativeCandidateDirectory 'winsmux-nsis-plan.json'
    $script:DesktopNativePlan = Read-DesktopStrictJson $planPath
    $sha = [WinsmuxDesktopNativeActor]::NativeFile($planPath)['sha256']
    $cli = Join-Path $DesktopNativeCandidateDirectory 'winsmux.exe'; $setup = Join-Path $DesktopNativeCandidateDirectory 'winsmux_0.38.0_x64-setup.exe'
    Assert-Condition ($request.plan_sha256 -ceq $sha -and $request.cli_sha256 -ceq [WinsmuxDesktopNativeActor]::NativeFile($cli)['sha256'] -and $request.setup_sha256 -ceq [WinsmuxDesktopNativeActor]::NativeFile($setup)['sha256']) 'desktop_native_capacity_image_binding_refused'
    Assert-DesktopInventoryShape $request.owned_vhd @('image_path', 'image_witness', 'volume_root', 'disk_number', 'mount_witness', 'filler_path')
    $volume = [string]$request.owned_vhd.volume_root
    Assert-Condition ($volume -cmatch '^[A-Z]:\\$' -and $request.root -ceq (Join-Path $volume '日本語 & winsmux') -and $request.owned_vhd.image_path -cmatch '\\vhd-owned-[a-f0-9]{32}\\owned\.vhdx$' -and [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($request.owned_vhd.image_path)) -ceq $script:DesktopNativeEvidenceRoot) 'desktop_native_capacity_namespace_refused'
    Assert-Condition ([WinsmuxDesktopNativeActor]::NativeVolume($volume) -ceq $request.volume_identity) 'desktop_native_capacity_actual_volume_mismatch'
    [void][WinsmuxDesktopNativeActor]::NativeDirectory($volume, $false)
    $sentinel = Join-Path $volume 'user-project-sentinel.txt'
    Assert-DesktopInventoryShape $request.user_sentinel @('bytes', 'sha256', 'identity')
    $user = [WinsmuxDesktopNativeActor]::NativeFile($sentinel)
    Assert-Condition ($user['bytes'] -eq $request.user_sentinel.bytes -and $user['sha256'] -ceq $request.user_sentinel.sha256 -and $user['identity'] -ceq $request.user_sentinel.identity) 'desktop_native_capacity_user_witness_mismatch'
    if ($request.stage -ceq 'fresh-container') {
        Assert-Condition ($null -eq $request.root_identity -and $null -eq $request.source -and $null -eq $request.context -and -not (Test-Path -LiteralPath $request.root)) 'desktop_native_capacity_fresh_root_refused'
    } else {
        Assert-Condition ([WinsmuxDesktopNativeActor]::NativeDirectory($request.root, $false) -ceq $request.root_identity -and [WinsmuxDesktopNativeActor]::NativeVolume($request.root) -ceq $request.volume_identity) 'desktop_native_capacity_root_identity_changed'
    }
    $result = [ordered]@{ schema = 'winsmux-desktop-native-capacity-result/v1'; source_commit = $DesktopNativeSourceCommit; stage = $request.stage; outcome = 'failed'; process = $null; before = $null; after = $null; state = $null; failure = $null }
    try {
        if ($request.stage -ceq 'fresh-container') {
            $process = Invoke-DesktopNativeOwnedEntry -Purpose 'nsis-fresh-no-shortcuts' -Image $setup -ImageSha256 $request.setup_sha256 -Root $request.root
            $result.process = $process
            Assert-Condition ($process.exit_code -eq 0) 'desktop_native_capacity_fresh_install_failed'
            $result.state = Assert-DesktopNativeInstalledPayload -Root $request.root -Plan $script:DesktopNativePlan -PlanSha256 $sha -Managed
            Assert-Condition (@($result.state.shortcuts).Count -eq 0) 'desktop_native_capacity_cross_volume_old_links'
        } elseif ($request.stage -ceq 'native-shortage') {
            Assert-Condition ($request.source -ceq (Join-Path $volume 'nsis-source-capacity-complete')) 'desktop_native_capacity_source_refused'
            Assert-DesktopInventoryShape $request.context @('path', 'bytes', 'sha256', 'identity')
            Assert-Condition ($request.context.path -ceq (Join-Path $script:DesktopNativeEvidenceRoot 'capacity-native-shortage.context')) 'desktop_native_capacity_context_path_refused'
            $expected = New-DesktopNativeNsisContextText -Command install -Root $request.root -Source $request.source -PlanSha256 $sha -Language 1041 -StartMenu $false -Desktop $false -Update $true
            $encoded = [Text.UnicodeEncoding]::new($false, $false, $true).GetBytes($expected)
            $ctx = [WinsmuxDesktopNativeActor]::NativeFile($request.context.path)
            Assert-Condition ($ctx['bytes'] -eq $request.context.bytes -and $ctx['sha256'] -ceq $request.context.sha256 -and $ctx['identity'] -ceq $request.context.identity -and [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($encoded)).ToLowerInvariant() -ceq $ctx['sha256']) 'desktop_native_capacity_context_bytes_refused'
            $old = Assert-DesktopNativeInstalledPayload -Root $request.root -Plan $script:DesktopNativePlan -PlanSha256 $sha -Managed
            Assert-Condition (@($old.shortcuts).Count -eq 0) 'desktop_native_capacity_old_links_refused'
            $result.before = Get-DesktopNativeWitness -Root $request.root -Sentinel $sentinel
            $process = Invoke-DesktopOwnedNativeProcess -FilePath $cli -ArgumentList @('--winsmux-internal-desktop-installer', 'nsis-install', '--context', $request.context.path) -Environment @{} -TimeoutSeconds 180
            $result.process = $process
            Assert-Condition ($process.exit_code -ne 0 -and [string]::IsNullOrWhiteSpace($process.stdout) -and $process.stderr -match '^winsmux installer: io_unconfirmed\s*$') 'desktop_native_capacity_failure_class_unmet'
            $result.after = Get-DesktopNativeWitness -Root $request.root -Sentinel $sentinel
            Assert-DesktopNativeWitnessEqual $result.before $result.after
            Assert-Condition ([WinsmuxDesktopNativeActor]::NativeFile($request.context.path)['identity'] -ceq $ctx['identity'] -and [WinsmuxDesktopNativeActor]::NativeFile($request.context.path)['sha256'] -ceq $ctx['sha256']) 'desktop_native_capacity_context_changed'
        } else {
            Assert-Condition ($null -eq $request.context -and $null -eq $request.source) 'desktop_native_capacity_cleanup_input_refused'
            $uninstallState = Read-DesktopStrictJson (Join-Path $request.root '.winsmux-desktop/installed.json')
            $before = Get-DesktopNativeWitness -Root $request.root -Sentinel $sentinel
            $uninstaller = Join-Path $request.root 'uninstall.exe'; $unSha = [WinsmuxDesktopNativeActor]::NativeFile($uninstaller)['sha256']
            $result.process = Invoke-DesktopNativeOwnedEntry -Purpose 'nsis-uninstall' -Image $uninstaller -ImageSha256 $unSha -Root $request.root
            Assert-Condition ($result.process.exit_code -eq 0) 'desktop_native_capacity_uninstall_failed'
            $result.after = Get-DesktopNativeWitness -Root $request.root -Sentinel $sentinel
            [void](Assert-DesktopNativeNsisObservation -Kind uninstalled -Binding (Get-DesktopNativeNsisObservationBinding -Root $request.root -Journal) -PlanSha256 $sha -PriorState $uninstallState -PriorWitness $before -Witness $result.after)
        }
        Assert-Condition ([WinsmuxDesktopNativeActor]::NativeFile($requestPath)['identity'] -ceq $requestFile['identity'] -and [WinsmuxDesktopNativeActor]::NativeFile($requestPath)['sha256'] -ceq $requestFile['sha256']) 'desktop_native_capacity_request_changed'
        $result.outcome = 'passed'
    } catch { $result.failure = $_.Exception.GetType().FullName + ': ' + $_.Exception.Message }
    Write-DesktopNativeEvidence 'capacity-result.json' $result
    return $result
}

function Invoke-DesktopNativeCapacityBootstrap {
    param([Parameter(Mandatory)]$Owned, [Parameter(Mandatory)][ValidateSet('fresh-container', 'native-shortage', 'cleanup')][string]$Stage, [Parameter(Mandatory)][string]$Root, [string]$Source, $Context)
    $held = Get-DesktopNativeVhdState $Owned
    foreach ($lease in $held.RootLeases) { $lease.Verify() }; $held.ImageLease.Verify(); $held.VolumeLease.Verify()
    [void](Get-DesktopNativeVhdMapping $held 'mounted')
    $planPath = Join-Path $DesktopNativeCandidateDirectory 'winsmux-nsis-plan.json'; $sha = [WinsmuxDesktopNativeActor]::NativeFile($planPath)['sha256']
    $cli = Join-Path $DesktopNativeCandidateDirectory 'winsmux.exe'; $setup = Join-Path $DesktopNativeCandidateDirectory 'winsmux_0.38.0_x64-setup.exe'
    $rootIdentity = if ($Stage -ceq 'fresh-container') { $null } else { [WinsmuxDesktopNativeActor]::NativeDirectory($Root, $false) }
    $request = [ordered]@{ schema = 'winsmux-desktop-native-capacity-request/v1'; stage = $Stage; source_commit = $DesktopNativeSourceCommit; script_sha256 = [WinsmuxDesktopNativeActor]::NativeFile($PSCommandPath)['sha256']; candidate_receipt_sha256 = [WinsmuxDesktopNativeActor]::NativeFile((Join-Path $DesktopNativeCandidateDirectory 'desktop-native-candidate.json'))['sha256']; plan_sha256 = $sha; cli_sha256 = [WinsmuxDesktopNativeActor]::NativeFile($cli)['sha256']; setup_sha256 = [WinsmuxDesktopNativeActor]::NativeFile($setup)['sha256']; owned_vhd = $Owned; root = $Root; root_identity = $rootIdentity; volume_identity = [WinsmuxDesktopNativeActor]::NativeVolume($Owned.volume_root); source = $Source; context = $Context; user_sentinel = [WinsmuxDesktopNativeActor]::NativeFile((Join-Path $Owned.volume_root 'user-project-sentinel.txt')) }
    Write-DesktopNativeEvidence 'capacity-request.json' $request
    $pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName; $pwshSha = [WinsmuxDesktopNativeActor]::NativeFile($pwsh)['sha256']
    $inputRoot = Get-DesktopNativeInputRoot
    $child = [WinsmuxDesktopNativeActor]::StartNative('medium-bootstrap', $pwsh, $pwshSha, $inputRoot, $DesktopNativeSourceCommit, $DesktopNativeCandidateDirectory, $DesktopNativeBaselineDirectory, $PSCommandPath)
    $terminal = $false
    try {
        $terminal = $child.WaitTerminal($script:DesktopObservationTimeoutMilliseconds * 2)
        if (-not $terminal) { $child.StopOwnedFailure(); $terminal = $true; throw 'desktop_native_capacity_medium_timeout' }
        $resultPath = Join-Path $script:DesktopNativeEvidenceRoot 'capacity-result.json'; [void][WinsmuxDesktopNativeActor]::NativeFile($resultPath)
        $result = Read-DesktopStrictJson $resultPath
        Assert-Condition ($child.ExitCode -eq 0 -and $result.schema -ceq 'winsmux-desktop-native-capacity-result/v1' -and $result.source_commit -ceq $DesktopNativeSourceCommit -and $result.stage -ceq $Stage -and $result.outcome -ceq 'passed') 'desktop_native_capacity_medium_stage_failed'
        Write-DesktopNativeEvidence ('capacity-' + $Stage + '-bootstrap.json') ([ordered]@{ process = $child.Facts(); result = $result })
        # Retire only this verified request/result pair after its exact owned Job is terminal. Each stage retains original bytes.
        foreach ($name in @('capacity-request.json', 'capacity-result.json')) {
            $from = Join-Path $script:DesktopNativeEvidenceRoot $name; $to = Join-Path $script:DesktopNativeEvidenceRoot ('capacity-' + $Stage + '-' + $name)
            $witness = [WinsmuxDesktopNativeActor]::NativeFile($from)
            Assert-Condition ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($from)) -ceq $script:DesktopNativeEvidenceRoot -and [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($to)) -ceq $script:DesktopNativeEvidenceRoot -and -not (Test-Path -LiteralPath $to)) 'desktop_native_capacity_pair_retire_refused'
            [IO.File]::Move($from, $to, $false)
            Assert-Condition ([WinsmuxDesktopNativeActor]::NativeFile($to)['identity'] -ceq $witness['identity'] -and [WinsmuxDesktopNativeActor]::NativeFile($to)['sha256'] -ceq $witness['sha256']) 'desktop_native_capacity_pair_retire_changed'
        }
        foreach ($lease in $held.RootLeases) { $lease.Verify() }; $held.ImageLease.Verify(); $held.VolumeLease.Verify(); [void](Get-DesktopNativeVhdMapping $held 'mounted')
        return $result
    } finally { if (-not $terminal) { $child.StopOwnedFailure(); $terminal = $true }; if ($terminal) { $child.Dispose() } }
}

function Invoke-DesktopNativeCapacityCases {
    param([Parameter(Mandatory)][string]$Sentinel)
    Initialize-DesktopNativeOwnedVhdSupport
    $format = $DesktopNativeFormat.ToLowerInvariant(); $planPath = Join-Path $DesktopNativeCandidateDirectory ('winsmux-' + $format + '-plan.json')
    $plan = Read-DesktopStrictJson $planPath; $sha = [WinsmuxDesktopNativeActor]::NativeFile($planPath)['sha256']
    [long]$payload = 0; foreach ($row in $plan.files) { $payload += [long]$row.bytes }; $payload += [long][WinsmuxDesktopNativeActor]::NativeFile($planPath)['bytes']
    if ($DesktopNativeFormat -ceq 'NSIS') { $payload += [long][WinsmuxDesktopNativeActor]::NativeFile((Join-Path $DesktopNativeCandidateDirectory 'winsmux_0.38.0_x64-setup.exe'))['bytes'] }
    $ownedRoot = Join-Path $script:DesktopNativeEvidenceRoot ('vhd-owned-' + [Guid]::NewGuid().ToString('N'))
    [void][WinsmuxDesktopNativeActor]::NativeDirectory($ownedRoot, $true)
    $vhd = $null; $outcome = $null; $operationError = $null; $cleanupError = $null; $dataObservedClean = $false
    try {
        $vhd = New-DesktopNativeOwnedVhd -OwnedRoot $ownedRoot -PayloadBytes $payload
        $root = Join-Path $vhd.volume_root '日本語 & winsmux'
        Assert-Condition (-not (Test-PathInsideRoot -Path $vhd.filler_path -Root $root) -and -not (Test-PathInsideRoot -Path $root -Root $vhd.filler_path)) 'desktop_native_capacity_filler_overlap'
        $sentinelPath = Join-Path $vhd.volume_root 'user-project-sentinel.txt'
        $sentinelBytes = [IO.File]::ReadAllBytes($Sentinel)
        $file = [IO.FileStream]::new($sentinelPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $file.Write($sentinelBytes, 0, $sentinelBytes.Length); $file.Flush($true) } finally { $file.Dispose() }
        if ($DesktopNativeFormat -ceq 'NSIS') {
            $fresh = Invoke-DesktopNativeCapacityBootstrap -Owned $vhd -Stage fresh-container -Root $root
            Assert-Condition (@($fresh.state.shortcuts).Count -eq 0) 'desktop_native_capacity_shortcuts_not_empty'
            $script:DesktopNativeCapacityVolume = $vhd.volume_root; $script:DesktopNativePlan = $plan
            $source = New-DesktopNativeFaultSource -Root $root -Plan $plan -Kind complete -Role capacity
            [long]$required = 0; foreach ($row in $fresh.state.members) { $required += [long]$row.bytes }
            $contextPath = Join-Path $script:DesktopNativeEvidenceRoot 'capacity-native-shortage.context'
            $text = New-DesktopNativeNsisContextText -Command install -Root $root -Source $source -PlanSha256 $sha -Language 1041 -StartMenu $false -Desktop $false -Update $true
            $bytes = [Text.UnicodeEncoding]::new($false, $false, $true).GetBytes($text)
            $stream = [IO.FileStream]::new($contextPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            $shortage = Set-DesktopNativeVhdShortage -Owned $vhd -RequiredBytes $required
            Assert-Condition ($shortage.after_free_bytes -lt $required -and [WinsmuxDesktopNativeActor]::NativeVolume($source) -ceq [WinsmuxDesktopNativeActor]::NativeVolume($vhd.volume_root)) 'desktop_native_capacity_shortage_not_bound'
            Write-DesktopNativeEvidence 'capacity-actual-shortage.json' $shortage
            $ctx = [WinsmuxDesktopNativeActor]::NativeFile($contextPath)
            $context = [ordered]@{ path = $contextPath; bytes = $ctx['bytes']; sha256 = $ctx['sha256']; identity = $ctx['identity'] }
            $failed = Invoke-DesktopNativeCapacityBootstrap -Owned $vhd -Stage native-shortage -Root $root -Source $source -Context $context
            $cleanup = Invoke-DesktopNativeCapacityBootstrap -Owned $vhd -Stage cleanup -Root $root
            $outcome = [ordered]@{ outcome = 'passed'; fresh = $fresh; shortage = $shortage; failure = $failed; uninstall = $cleanup }
        } else { $outcome = Invoke-DesktopNativeMsiCapacity -Owned $vhd -Root $root -Sentinel $sentinelPath -Plan $plan -PlanSha256 $sha -RequiredBytes $payload }
        $dataObservedClean = $outcome.outcome -ceq 'passed'
    } catch { $operationError = $_.Exception; if ($null -eq $vhd -and $_.Exception.Data.Contains('OwnedVhd')) { $vhd = $_.Exception.Data['OwnedVhd'] } }
    finally {
        if ($null -ne $vhd -and $dataObservedClean) {
            try { $close = Close-DesktopNativeOwnedVhd $vhd; Write-DesktopNativeEvidence 'capacity-owned-vhd-closed.json' $close } catch { $cleanupError = $_.Exception }
        } elseif ($null -ne $vhd) {
            # Unknown/partial native data is not detached/deleted to manufacture a clean result.
            $cleanupError = [InvalidOperationException]::new('owned_vhd_preserved_without_verified_data_terminal')
            try { if (-not [string]::IsNullOrWhiteSpace([string]$vhd.volume_root)) { Write-DesktopNativeEvidence 'capacity-unconfirmed-state.json' (Get-DesktopNativeWitness -Root (Join-Path $vhd.volume_root '日本語 & winsmux') -Sentinel (Join-Path $vhd.volume_root 'user-project-sentinel.txt')) } } catch { }
        }
    }
    if ($null -ne $operationError -or $null -ne $cleanupError) {
        Write-DesktopNativeEvidence 'capacity-preserved-failure.json' ([ordered]@{ operation_failure = $(if ($null -ne $operationError) { $operationError.Message } else { $null }); cleanup_failure = $(if ($null -ne $cleanupError) { $cleanupError.Message } else { $null }); owned_vhd = $vhd })
        throw 'desktop_native_capacity_failed_or_preserved_unconfirmed'
    }
    return $outcome
}


function Invoke-DesktopNativeMsiCapacity {
    param([Parameter(Mandatory)]$Owned, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Sentinel, [Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$PlanSha256, [Parameter(Mandatory)][long]$RequiredBytes)
    $msiexec = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'msiexec.exe'; $sha = (Get-FileHash -LiteralPath $msiexec -Algorithm SHA256).Hash.ToLowerInvariant()
    $en = Join-Path $DesktopNativeCandidateDirectory 'winsmux_0.38.0_x64_en-US.msi'; $ja = Join-Path $DesktopNativeCandidateDirectory 'winsmux_0.38.0_x64_ja-JP.msi'
    $enProperties = Get-DesktopNativeMsiProperties $en; $jaProperties = Get-DesktopNativeMsiProperties $ja
    Assert-Condition ($enProperties.properties.ProductCode -cne $jaProperties.properties.ProductCode -and $enProperties.properties.ProductLanguage -ceq '1033' -and $jaProperties.properties.ProductLanguage -ceq '1041') 'desktop_native_capacity_msi_pair_refused'
    $fresh = Invoke-DesktopNativeOwnedEntry -Purpose msi-capacity-install-en -Image $msiexec -ImageSha256 $sha -Root $Root -Package $en
    Write-DesktopNativeEvidence 'capacity-msi-fresh-process.json' $fresh
    Assert-Condition ($fresh.exit_code -eq 0) 'desktop_native_capacity_msi_fresh_failed'
    Assert-DesktopNativeInstalledPayload -Root $Root -Plan $Plan -PlanSha256 $PlanSha256
    $prior = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
    Assert-Condition (@($prior.shortcuts | Where-Object { $null -ne $_ }).Count -eq 0) 'desktop_native_capacity_msi_shortcuts_present'
    Write-DesktopNativeEvidence 'capacity-msi-prior.json' $prior
    $shortage = Set-DesktopNativeVhdShortage -Owned $Owned -RequiredBytes $RequiredBytes
    Assert-Condition ($shortage.after_free_bytes -lt $RequiredBytes) 'desktop_native_capacity_msi_shortage_unobserved'
    Write-DesktopNativeEvidence 'capacity-msi-shortage.json' $shortage
    $failed = Invoke-DesktopNativeOwnedEntry -Purpose msi-capacity-update-ja -Image $msiexec -ImageSha256 $sha -Root $Root -Package $ja
    Write-DesktopNativeEvidence 'capacity-msi-update-process.json' $failed
    Assert-Condition ($failed.exit_code -ne 0) 'desktop_native_capacity_msi_failure_unmet'
    $logPath = Join-Path ([IO.Path]::GetDirectoryName($Root)) 'msi-capacity-update-ja.log'
    $log = [IO.File]::ReadAllText($logPath)
    $space = @($log -split '\r?\n' | Where-Object { $_ -match 'OutOfDiskSpace[ =:]+1|Error (112|1307)|insufficient.*(disk|space)|not enough.*(disk|space)' })
    Assert-Condition ($space.Count -gt 0) 'desktop_native_capacity_msi_wrong_failure_class'
    Write-DesktopNativeEvidence 'capacity-msi-space-error.json' ([ordered]@{ log = [WinsmuxDesktopNativeActor]::NativeFile($logPath); matches = $space })
    $after = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
    Assert-DesktopNativeWitnessEqual $prior $after
    Write-DesktopNativeEvidence 'capacity-msi-restored.json' $after
    $removed = Invoke-DesktopNativeOwnedEntry -Purpose msi-capacity-uninstall -Image $msiexec -ImageSha256 $sha -Root $Root -Package $en
    Write-DesktopNativeEvidence 'capacity-msi-uninstall-process.json' $removed
    Assert-Condition ($removed.exit_code -eq 0) 'desktop_native_capacity_msi_uninstall_failed'
    $clean = Get-DesktopNativeWitness -Root $Root -Sentinel $Sentinel
    Assert-Condition (@($clean.files).Count -eq 0 -and @($clean.shortcuts | Where-Object { $null -ne $_ }).Count -eq 0 -and $clean.user_sentinel['identity'] -ceq $prior.user_sentinel['identity'] -and $clean.user_sentinel['sha256'] -ceq $prior.user_sentinel['sha256']) 'desktop_native_capacity_msi_uninstall_preservation_failed'
    Write-DesktopNativeEvidence 'capacity-msi-uninstall-after.json' $clean
    return [ordered]@{ outcome = 'passed'; fresh = $fresh; shortage = $shortage; failed_update = $failed; uninstall = $removed }
}

function Invoke-DesktopNativeLifecycleSelfTest {
    $source = 'f792c631829d850c8b025e9308487432becc9be7'
    $valid = @{ DesktopNativeLifecycle = $true; DesktopNativeFormat = 'MSI'; DesktopNativeSourceCommit = $source; DesktopNativeCandidateDirectory = 'C:\run-owned\candidate'; DesktopNativeBaselineDirectory = 'C:\run-owned\baseline' }
    $cases = [Collections.Generic.List[object]]::new()
    $run = {
        param([string]$Name, [hashtable]$Arguments, [string]$RequestedSurface = 'Desktop', [string]$CandidateVersion = '0.38.0', [string]$CandidateReleaseTag = 'v0.38.0', [string]$ActualHead = $source, [string]$CallerHead = $source, [bool]$Reject = $true)
        $refused = Test-Throws { Assert-DesktopNativeRequest -RequestedSurface $RequestedSurface -CandidateVersion $CandidateVersion -CandidateReleaseTag $CandidateReleaseTag -Arguments $Arguments -ActualHead $ActualHead -CallerHead $CallerHead }
        Assert-Condition ($refused -eq $Reject) ('desktop_native_selftest_' + $Name)
        $cases.Add([ordered]@{ name = $Name; refused = $refused; passed = $true })
    }.GetNewClosure()
    & $run 'msi' $valid -Reject $false
    $nsis = $valid.Clone(); $nsis.DesktopNativeFormat = 'NSIS'; & $run 'nsis' $nsis -Reject $false
    & $run 'ordinary_unmodified' @{} -Reject $false
    foreach ($surface in @('Core', 'Npm')) { & $run ('surface_' + $surface) $valid -RequestedSurface $surface }
    & $run 'version' $valid -CandidateVersion '0.37.0'
    & $run 'release_tag' $valid -CandidateReleaseTag 'v0.37.0'
    foreach ($key in @('DesktopNativeFormat', 'DesktopNativeSourceCommit', 'DesktopNativeCandidateDirectory', 'DesktopNativeBaselineDirectory')) {
        $missing = $valid.Clone(); $missing.Remove($key); & $run ('missing_' + $key) $missing
        $withoutMode = @{ }; $withoutMode[$key] = $valid[$key]; & $run ('without_mode_' + $key) $withoutMode
    }
    foreach ($key in @('CandidateInstallerPath', 'DesktopInventoryPath', 'PriorInstallerPath', 'PriorVersion', 'DesktopLegacyEnvMode')) {
        $mixed = $valid.Clone(); $mixed[$key] = 'unrelated-smoke-input'; & $run ('mixed_' + $key) $mixed
    }
    $badFormat = $valid.Clone(); $badFormat.DesktopNativeFormat = 'other'; & $run 'format' $badFormat
    $short = $valid.Clone(); $short.DesktopNativeSourceCommit = 'f792'; & $run 'short_source' $short
    $upper = $valid.Clone(); $upper.DesktopNativeSourceCommit = $source.ToUpperInvariant(); & $run 'uppercase_source' $upper
    & $run 'checkout_mismatch' $valid -ActualHead ('0' * 40)
    & $run 'caller_mismatch' $valid -CallerHead ('0' * 40)
    & $run 'finite_selftest' @{ DesktopNativeLifecycle = $true; SelfTest = $true } -Reject $false
    foreach ($key in @('DesktopNativeFormat', 'DesktopNativeSourceCommit', 'DesktopNativeCandidateDirectory', 'DesktopNativeBaselineDirectory')) {
        $selfInput = @{ DesktopNativeLifecycle = $true; SelfTest = $true }; $selfInput[$key] = $valid[$key]; & $run ('selftest_external_' + $key) $selfInput
    }
    return [ordered]@{ schema = 'winsmux-desktop-native-input-selftest/v1'; ok = $true; surface = 'Desktop'; passed = $cases.Count; failed = 0; cases = @($cases.ToArray()); native_processes_started = 0; installer_executed = $false; scope = 'Finite native-mode request admission only; physical artifact, real installer/runtime and rollback evidence are separate.' }
}

function Assert-DesktopNativeNsisUninstallAdapterSource {
    param([Parameter(Mandatory)][string]$HookSource, [Parameter(Mandatory)][string]$TemplateSource)
    # The native helper owns exact state/registration/link removal and rollback.
    # This static check binds the template entry to that authority; it does not prove installation.
    $hook = $HookSource.Replace(([string][char]13 + [char]10), [string][char]10)
    $template = $TemplateSource.Replace(([string][char]13 + [char]10), [string][char]10)
    $anchor = '!define WINSMUX_NSIS_INPUTS "${__FILEDIR__}\binaries\nsis"'
    Assert-Condition ([regex]::Matches($hook, '(?m)^' + [regex]::Escape($anchor) + '$').Count -eq 1) 'Desktop NSIS generation anchor differs.'
    $sections = [regex]::Matches($template, '(?ms)^Section Uninstall\n(?<body>.*?)^SectionEnd$')
    Assert-Condition ($sections.Count -eq 1) 'Desktop NSIS native uninstall section must be unique.'
    $body = $sections[0].Groups['body'].Value
    foreach ($line in @(
        '  Call un.WinsmuxInitWorkspace',
        '  SetOutPath "$WinsmuxWorkspace\winsmux-bootstrap"',
        '  SetOutPath $WinsmuxSource',
        '  File /oname=winsmux.exe "${WINSMUX_NSIS_HELPER_PATH}"',
        '  File /oname=winsmux.install-plan.json "${WINSMUX_NSIS_PLAN_PATH}"',
        '  Call un.WinsmuxWriteUninstallContext',
        '  nsExec::ExecToStack $WinsmuxCommand',
        '  Pop $0',
        '  Pop $1'
    )) {
        Assert-Condition ([regex]::Matches($body, '(?m)^' + [regex]::Escape($line) + '$').Count -eq 1) 'Desktop NSIS native uninstall helper, plan or dispatch differs.'
    }
    $failure = @'
  ${If} $0 != 0
    SetErrorLevel 2
    Abort "$(WINSMUX_TRANSACTION_FAILED)"
  ${EndIf}
'@
    $failure = $failure.Replace(([string][char]13 + [char]10), [string][char]10)
    Assert-Condition ($body.Contains($failure)) 'Desktop NSIS native uninstall must stop on helper failure.'
    Assert-Condition (-not [regex]::IsMatch($body, '(?im)^\s*(?:DeleteRegKey|DeleteRegValue|WriteReg[A-Za-z]*|Delete|RMDir)\b')) 'Desktop NSIS uninstall must delegate owned mutations to the native helper.'
    $workspaces = [regex]::Matches($template, '(?ms)^!macro WINSMUX_WORKSPACE_FUNCTION NAME ACTION COMMAND_OVERHEAD\n(?<body>.*?)^!macroend$')
    Assert-Condition ($workspaces.Count -eq 1) 'Desktop NSIS workspace initialization must be shared and unique.'
    foreach ($line in @(
        '  StrCpy $0 $PLUGINSDIR',
        '  System::Call ''kernel32::GetLongPathNameW(w r0, w .r1, i ${NSIS_MAX_STRLEN}) i.r2''',
        '  StrCpy $WinsmuxSource "$WinsmuxWorkspace\winsmux-source"',
        '  StrCpy $WinsmuxHelper "$WinsmuxWorkspace\winsmux-bootstrap\winsmux.exe"',
        '  StrCpy $WinsmuxContext "$WinsmuxWorkspace\winsmux-context.txt"',
        '  StrCpy $WinsmuxCommand ''$\"$WinsmuxHelper$\" --winsmux-internal-desktop-installer nsis-${ACTION} --context $\"$WinsmuxContext$\"'''
    )) {
        Assert-Condition ([regex]::Matches($workspaces[0].Groups['body'].Value, '(?m)^' + [regex]::Escape($line) + '$').Count -eq 1) 'Desktop NSIS workspace source, helper, context or command differs.'
    }
    foreach ($line in @(
        '!insertmacro WINSMUX_WORKSPACE_FUNCTION WinsmuxInitWorkspace install 115',
        '!insertmacro WINSMUX_WORKSPACE_FUNCTION un.WinsmuxInitWorkspace uninstall 117'
    )) {
        Assert-Condition ([regex]::Matches($template, '(?m)^' + [regex]::Escape($line) + '$').Count -eq 1) 'Desktop NSIS workspace action or command bound differs.'
    }
    $contexts = [regex]::Matches($template, '(?ms)^!macro WINSMUX_CONTEXT_FUNCTION NAME ACTION\n(?<body>.*?)^!macroend$')
    Assert-Condition ($contexts.Count -eq 1) 'Desktop NSIS native context writer must be unique.'
    $keys = @([regex]::Matches($contexts[0].Groups['body'].Value, '(?m)^  FileWriteUTF16LE \$0 "(?<key>[a-z0-9_]+)=') | ForEach-Object { $_.Groups['key'].Value })
    Assert-Condition (($keys -join ',') -ceq 'schema,command,root,source,plan_sha256,version,language,start_menu,desktop,update') 'Desktop NSIS native context keys differ.'
    Assert-Condition ([regex]::Matches($template, '(?m)^!insertmacro WINSMUX_CONTEXT_FUNCTION un\.WinsmuxWriteUninstallContext uninstall$').Count -eq 1) 'Desktop NSIS native uninstall context action differs.'
}

function Invoke-SelfTest {
    # GetNewClosure captures factory-local values, not inherited script parameters.
    # Pin the normalized coordinates for every surface and every fixture callback.
    $Version = $script:Version
    $ReleaseTag = $script:ReleaseTag
    # Preserve the original function session state inside dynamic fixture modules.
    $selfTestFunctions = @{
        'Assert-Condition' = (Get-Command -Name 'Assert-Condition' -CommandType Function).ScriptBlock
        'Get-DesktopTeardownDiagnosis' = (Get-Command -Name 'Get-DesktopTeardownDiagnosis' -CommandType Function).ScriptBlock
        'Invoke-VerifiedDesktopUninstaller' = (Get-Command -Name 'Invoke-VerifiedDesktopUninstaller' -CommandType Function).ScriptBlock
        'New-DesktopCdpProbeRecord' = (Get-Command -Name 'New-DesktopCdpProbeRecord' -CommandType Function).ScriptBlock
        'New-DesktopLifecycleContext' = (Get-Command -Name 'New-DesktopLifecycleContext' -CommandType Function).ScriptBlock
        'Set-DesktopLifecyclePhase' = (Get-Command -Name 'Set-DesktopLifecyclePhase' -CommandType Function).ScriptBlock
        'Start-DesktopLifecycle' = (Get-Command -Name 'Start-DesktopLifecycle' -CommandType Function).ScriptBlock
        'Stop-OwnedProcessTree' = (Get-Command -Name 'Stop-OwnedProcessTree' -CommandType Function).ScriptBlock
    }
    $caseIds = [Collections.Generic.List[string]]::new()
    $evidence = [ordered]@{}
    if ($Surface -eq 'Npm') {
        Assert-Condition ((Resolve-ReleaseCoordinates -Surface Npm -Version '0.36.28-pkgfix.1' -ReleaseTag 'v0.36.28.1' -Repository $Repository) -ceq '0.36.28-pkgfix.1') 'npm packaging-hotfix coordinates did not resolve to the staged package version.'
    } else {
        Assert-Condition ((Resolve-ReleaseCoordinates -Surface $Surface -Version '0.36.28.1' -ReleaseTag 'v0.36.28.1' -Repository $Repository) -ceq '0.36.28') "$Surface packaging-hotfix coordinates did not resolve to the native version."
    }
    $caseIds.Add('packaging_hotfix_coordinates')

    Assert-Condition (Test-Throws {
        Resolve-ReleaseCoordinates -Surface $Surface -Version '0.36.28' -ReleaseTag 'v0.36.28.1' -Repository $Repository
    }) "$Surface coordinate mismatch was accepted."
    $caseIds.Add('coordinate_mismatch')

    Assert-Condition ((Resolve-ReleaseCoordinates -Surface $Surface -Version '0.36.28-rc.1' -ReleaseTag 'v0.36.28-rc.1' -Repository $Repository) -ceq '0.36.28-rc.1') "$Surface ordinary prerelease coordinates did not resolve exactly."
    $caseIds.Add('ordinary_prerelease_coordinates')

    if ($Surface -eq 'Npm') {
        Assert-Condition (Test-Throws {
            Resolve-ReleaseCoordinates -Surface Npm -Version '0.36.28-pkgfix.1' -ReleaseTag 'v0.36.28-pkgfix.1' -Repository $Repository
        }) 'Reserved npm packaging-hotfix tag namespace was accepted.'
        $caseIds.Add('reserved_pkgfix_namespace')
    }

    $root = New-OwnedRoot
    $script:DesktopRunOwnedRoot = $root
    try {

        if ($Surface -eq 'Core') {
            $coreAssetNames = @(Get-CoreReleaseAssetNames)
            $x64Payload = Join-Path $root 'winsmux-x64.exe'
            $arm64Payload = Join-Path $root 'winsmux-arm64.exe'
            $helperPayload = Join-Path $root 'winsmux-remote-helper-linux-x64'
            Set-Content -LiteralPath $x64Payload -Value 'public-core-x64' -Encoding ascii -NoNewline
            Set-Content -LiteralPath $arm64Payload -Value 'public-core-arm64' -Encoding ascii -NoNewline
            Set-Content -LiteralPath $helperPayload -Value 'public-remote-helper-x64' -Encoding ascii -NoNewline
            $x64Hash = (Get-FileHash -LiteralPath $x64Payload -Algorithm SHA256).Hash.ToLowerInvariant()
            $arm64Hash = (Get-FileHash -LiteralPath $arm64Payload -Algorithm SHA256).Hash.ToLowerInvariant()
            $helperHash = (Get-FileHash -LiteralPath $helperPayload -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [string]::Join([Environment]::NewLine, @(
                "$x64Hash  winsmux-x64.exe",
                "$arm64Hash  winsmux-arm64.exe",
                "$helperHash  winsmux-remote-helper-linux-x64"
            ))

            Assert-Condition ($coreAssetNames.Count -eq 3) 'Core asset inventory did not contain exactly three assets.'
            Assert-Condition ($coreAssetNames[0] -ceq 'winsmux-x64.exe') 'Core asset inventory did not keep x64 first.'
            Assert-Condition ($coreAssetNames[1] -ceq 'winsmux-arm64.exe') 'Core asset inventory did not keep ARM64 second.'
            Assert-Condition ($coreAssetNames[2] -ceq 'winsmux-remote-helper-linux-x64') 'Core asset inventory did not keep the Linux x64 helper third.'
            $caseIds.Add('core_asset_inventory')

            Assert-Condition (Test-Throws { Get-ChecksumEntry -ManifestText "$x64Hash  winsmux-x64.exe" -AssetName 'winsmux-arm64.exe' }) 'Missing ARM64 checksum entry was accepted.'
            $caseIds.Add('missing_arm64_checksum_entry')

            $duplicateArm64Manifest = [string]::Join([Environment]::NewLine, @($manifest, "$arm64Hash  winsmux-arm64.exe"))
            Assert-Condition (Test-Throws { Get-ChecksumEntry -ManifestText $duplicateArm64Manifest -AssetName 'winsmux-arm64.exe' }) 'Duplicate ARM64 checksum entry was accepted.'
            $caseIds.Add('duplicate_arm64_checksum_entry')

            Assert-Condition (Test-Throws { Assert-FileChecksum -Path $arm64Payload -ExpectedHash ('0' * 64) }) 'ARM64 checksum mismatch was accepted.'
            $caseIds.Add('arm64_checksum_mismatch')

            Assert-Condition (Test-Throws { Get-ChecksumEntry -ManifestText "$x64Hash  winsmux-x64.exe" -AssetName 'winsmux-remote-helper-linux-x64' }) 'Missing helper checksum entry was accepted.'
            $caseIds.Add('missing_helper_checksum_entry')

            $duplicateHelperManifest = [string]::Join([Environment]::NewLine, @($manifest, "$helperHash  winsmux-remote-helper-linux-x64"))
            Assert-Condition (Test-Throws { Get-ChecksumEntry -ManifestText $duplicateHelperManifest -AssetName 'winsmux-remote-helper-linux-x64' }) 'Duplicate helper checksum entry was accepted.'
            $caseIds.Add('duplicate_helper_checksum_entry')

            Assert-Condition (Test-Throws { Assert-FileChecksum -Path $helperPayload -ExpectedHash ('0' * 64) }) 'Helper checksum mismatch was accepted.'
            $caseIds.Add('helper_checksum_mismatch')

            Assert-Condition ((Get-ChecksumEntry -ManifestText $manifest -AssetName 'winsmux-x64.exe') -ceq $x64Hash) 'Valid x64 checksum entry was rejected.'
            Assert-Condition ((Get-ChecksumEntry -ManifestText $manifest -AssetName 'winsmux-arm64.exe') -ceq $arm64Hash) 'Valid ARM64 checksum entry was rejected.'
            Assert-Condition ((Get-ChecksumEntry -ManifestText $manifest -AssetName 'winsmux-remote-helper-linux-x64') -ceq $helperHash) 'Valid helper checksum entry was rejected.'
            Assert-FileChecksum -Path $x64Payload -ExpectedHash $x64Hash
            Assert-FileChecksum -Path $arm64Payload -ExpectedHash $arm64Hash
            Assert-FileChecksum -Path $helperPayload -ExpectedHash $helperHash
            $expectedCoreProgramName = [IO.Path]::GetFileNameWithoutExtension($coreAssetNames[0])
            Assert-CoreVersionResult -Result ([pscustomobject]@{ exit_code = 0; stdout = "$expectedCoreProgramName $Version"; stderr = '' }) -ExpectedProgramName $expectedCoreProgramName -ExpectedVersion $Version
            $caseIds.Add('valid')

            Assert-Condition (Test-Throws { Get-ChecksumEntry -ManifestText '' -AssetName 'winsmux-x64.exe' }) 'Missing checksum entry was accepted.'
            $caseIds.Add('missing_checksum_entry')

            Assert-Condition (Test-Throws { Get-ChecksumEntry -ManifestText ([string]::Join([Environment]::NewLine, @($manifest, $manifest))) -AssetName 'winsmux-x64.exe' }) 'Duplicate checksum entry was accepted.'
            $caseIds.Add('duplicate_checksum_entry')

            Assert-Condition (Test-Throws { Assert-FileChecksum -Path $x64Payload -ExpectedHash ('0' * 64) }) 'Checksum mismatch was accepted.'
            $caseIds.Add('checksum_mismatch')

            Assert-Condition (Test-Throws { Assert-CoreVersionResult -Result ([pscustomobject]@{ exit_code = 0; stdout = "$expectedCoreProgramName 0.0.0"; stderr = '' }) -ExpectedProgramName $expectedCoreProgramName -ExpectedVersion $Version }) 'Version mismatch was accepted.'
            Assert-Condition (Test-Throws { Assert-CoreVersionResult -Result ([pscustomobject]@{ exit_code = 0; stdout = "winsmux $Version"; stderr = '' }) -ExpectedProgramName $expectedCoreProgramName -ExpectedVersion $Version }) 'Release-asset program-name mismatch was accepted.'
            $caseIds.Add('version_mismatch')
        } elseif ($Surface -eq 'Desktop') {
            $installRoot = Join-Path $root 'installed'
            $uninstallPath = Join-Path $installRoot 'uninstall.exe'
            $appPath = Join-Path $installRoot 'winsmux-app.exe'
            $outsidePath = Join-Path $root 'outside\winsmux-app.exe'

            $candidateInstaller = Join-Path $root 'candidate-installer.exe'
            $priorInstaller = Join-Path $root 'prior-installer.exe'
            $missingPriorInstaller = Join-Path $root 'missing-prior-installer.exe'
            Set-Content -LiteralPath $candidateInstaller -Value 'self-test candidate installer' -Encoding ascii -NoNewline
            Set-Content -LiteralPath $priorInstaller -Value 'self-test prior installer' -Encoding ascii -NoNewline
            $priorVersionForSelfTest = if ($Version -cne '0.0.1') { '0.0.1' } else { '0.0.2' }

            Assert-DesktopInstallerRequest -RequestedSurface Desktop -CandidateVersion $Version -Arguments @{
                CandidateInstallerPath = $candidateInstaller
                PriorInstallerPath = $priorInstaller
                PriorVersion = $priorVersionForSelfTest
            }

            Assert-Condition (Test-Throws {
                Assert-DesktopInstallerRequest -RequestedSurface Core -CandidateVersion $Version -Arguments @{
                    CandidateInstallerPath = $candidateInstaller
                    PriorInstallerPath = $priorInstaller
                    PriorVersion = $priorVersionForSelfTest
                }
            }) 'PriorInstallerPath was accepted outside the Desktop surface.'
            Assert-Condition (Test-Throws {
                Assert-DesktopInstallerRequest -RequestedSurface Npm -CandidateVersion $Version -Arguments @{
                    CandidateInstallerPath = $candidateInstaller
                    PriorVersion = $priorVersionForSelfTest
                }
            }) 'PriorVersion was accepted outside the Desktop surface.'

            Assert-Condition (Test-Throws {
                Assert-DesktopInstallerRequest -RequestedSurface Desktop -CandidateVersion $Version -Arguments @{
                    CandidateInstallerPath = $candidateInstaller
                    PriorInstallerPath = $missingPriorInstaller
                    PriorVersion = $priorVersionForSelfTest
                }
            }) 'A missing prior installer path was accepted.'

            Assert-Condition (Test-Throws {
                Assert-DesktopInstallerRequest -RequestedSurface Desktop -CandidateVersion $Version -Arguments @{
                    CandidateInstallerPath = $candidateInstaller
                    PriorInstallerPath = $priorInstaller
                    PriorVersion = $Version
                }
            }) 'A same-version prior installer was accepted as upgrade evidence.'

            Assert-Condition (Test-Throws {
                Assert-DesktopInstallerRequest -RequestedSurface Desktop -CandidateVersion $Version -Arguments @{
                    PriorInstallerPath = $priorInstaller
                    PriorVersion = $priorVersionForSelfTest
                }
            }) 'Prior installer inputs were accepted without CandidateInstallerPath.'
            Assert-Condition (Test-Throws {
                Assert-DesktopInstallerRequest -RequestedSurface Desktop -CandidateVersion $Version -Arguments @{
                    CandidateInstallerPath = $candidateInstaller
                    PriorInstallerPath = $priorInstaller
                }
            }) 'PriorInstallerPath was accepted without PriorVersion.'

            $nsisHookPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-app\src-tauri\nsis-installer-hooks.nsh'
            $nsisTemplatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winsmux-app\src-tauri\nsis\installer.nsi'
            Assert-Condition (Test-Path -LiteralPath $nsisHookPath -PathType Leaf) 'Desktop NSIS installer hook source was not found.'
            Assert-Condition (Test-Path -LiteralPath $nsisTemplatePath -PathType Leaf) 'Desktop NSIS native template source was not found.'
            $nsisHookSource = [IO.File]::ReadAllText($nsisHookPath)
            $nsisTemplateSource = [IO.File]::ReadAllText($nsisTemplatePath)
            Assert-DesktopNativeNsisUninstallAdapterSource -HookSource $nsisHookSource -TemplateSource $nsisTemplateSource
            $caseIds.Add('desktop_native_uninstall_adapter')
            $nativeUninstallDispatch = '  nsExec::ExecToStack $WinsmuxCommand'
            $uninstallSection = [regex]::Matches($nsisTemplateSource, '(?ms)^Section Uninstall\n.*?^SectionEnd$')
            Assert-Condition ($uninstallSection.Count -eq 1) 'Desktop NSIS uninstall mutation section differs.'
            $uninstallSource = $uninstallSection[0].Value
            Assert-Condition ([regex]::Matches($uninstallSource, [regex]::Escape($nativeUninstallDispatch)).Count -eq 1) 'Desktop NSIS uninstall mutation dispatch differs.'
            $adapterMutations = [ordered]@{
                missing_dispatch = $nsisTemplateSource.Replace($uninstallSource, $uninstallSource.Replace($nativeUninstallDispatch, '  ; native dispatch missing'))
                wrong_action = $nsisTemplateSource.Replace('!insertmacro WINSMUX_WORKSPACE_FUNCTION un.WinsmuxInitWorkspace uninstall 117', '!insertmacro WINSMUX_WORKSPACE_FUNCTION un.WinsmuxInitWorkspace install 115')
                missing_failure_guard = $nsisTemplateSource.Replace('${If} $0 != 0', '${If} $0 = 0')
                direct_registry_delete = $nsisTemplateSource.Replace('Section Uninstall', ('Section Uninstall' + [char]10 + '  DeleteRegKey HKCU "Software\github\winsmux"'))
            }
            foreach ($mutation in $adapterMutations.GetEnumerator()) {
                Assert-Condition ($mutation.Value -cne $nsisTemplateSource) 'Desktop NSIS native adapter negative fixture was unchanged.'
                Assert-Condition (Test-Throws { Assert-DesktopNativeNsisUninstallAdapterSource -HookSource $nsisHookSource -TemplateSource $mutation.Value }) ('Desktop NSIS native adapter accepted ' + $mutation.Key)
                $caseIds.Add('desktop_native_uninstall_' + $mutation.Key)
            }

            Assert-DesktopProductVersion -ActualVersion $Version -ExpectedVersion $Version
            $caseIds.Add('product_version_exact')

            Assert-Condition (Test-Throws { Assert-DesktopProductVersion -ActualVersion "$Version-beta.1" -ExpectedVersion $Version }) 'A suffixed Desktop ProductVersion was accepted.'
            $caseIds.Add('product_version_suffix_rejected')

            $versionParts = @($Version -split '\.')
            $paddedVersion = "$($versionParts[0]).0$($versionParts[1]).$($versionParts[2])"
            Assert-Condition (Test-Throws { Assert-DesktopProductVersion -ActualVersion $paddedVersion -ExpectedVersion $Version }) 'A numerically padded Desktop ProductVersion was accepted.'
            $caseIds.Add('product_version_padding_rejected')

            $state = New-EmptyDesktopProtectedState
            $state.folder_context_exists = $true
            Assert-Condition (Test-Throws { Assert-NoDesktopProtectedState -State $state -Phase 'self-test' }) 'Pre-existing folder-context state was accepted.'
            $caseIds.Add('preexisting_folder_context')

            $state = New-EmptyDesktopProtectedState
            $state.background_context_exists = $true
            Assert-Condition (Test-Throws { Assert-NoDesktopProtectedState -State $state -Phase 'self-test' }) 'Pre-existing background-context state was accepted.'
            $caseIds.Add('preexisting_background_context')

            $state = New-EmptyDesktopProtectedState
            $state.product_state_exists = $true
            Assert-Condition (Test-Throws { Assert-NoDesktopProtectedState -State $state -Phase 'self-test' }) 'Pre-existing product state was accepted.'
            $caseIds.Add('preexisting_product_state')

            Assert-DesktopProductStateOwnership -MaterializedInstallRoot $installRoot -ExpectedInstallRoot $installRoot
            Assert-Condition (Test-Throws { Assert-DesktopProductStateOwnership -MaterializedInstallRoot (Join-Path $root 'other-install') -ExpectedInstallRoot $installRoot }) 'A foreign product-state install root was accepted for cleanup.'
            $caseIds.Add('owned_product_state_cleanup')

            $state = New-EmptyDesktopProtectedState
            $state.uninstall_registration_exists = $true
            Assert-Condition (Test-Throws { Assert-NoDesktopProtectedState -State $state -Phase 'self-test' }) 'Pre-existing uninstall registration was accepted.'
            $caseIds.Add('preexisting_uninstall_registration')

            $registration = [pscustomobject]@{
                DisplayVersion = $Version
                InstallLocation = $installRoot
                UninstallString = "`"$uninstallPath`""
            }
            Assert-Condition ((Get-ExactDesktopInstallLocation -InstallLocation $installRoot -ExpectedInstallRoot $installRoot) -ceq $installRoot) 'An exact unquoted Desktop InstallLocation was rejected.'
            $caseIds.Add('desktop_install_location_unquoted')

            $quotedInstallRoot = "`"$installRoot`""
            Assert-Condition ((Get-ExactDesktopInstallLocation -InstallLocation $quotedInstallRoot -ExpectedInstallRoot $installRoot) -ceq $installRoot) 'An exact outer-quoted Desktop InstallLocation was rejected.'
            $caseIds.Add('desktop_install_location_outer_quoted')

            foreach ($malformedInstallLocation in @(
                "`"$installRoot",
                "$installRoot`"",
                "`"`"$installRoot`"`"",
                "`"$installRoot`"suffix",
                "$installRoot`"suffix"
            )) {
                Assert-Condition (Test-Throws {
                    Get-ExactDesktopInstallLocation -InstallLocation $malformedInstallLocation -ExpectedInstallRoot $installRoot
                }) "Malformed Desktop InstallLocation was accepted: $malformedInstallLocation"
            }
            $caseIds.Add('desktop_install_location_malformed')

            Assert-Condition (Test-Throws {
                Get-ExactDesktopInstallLocation -InstallLocation (Join-Path $root 'other-install') -ExpectedInstallRoot $installRoot
            }) 'A foreign Desktop InstallLocation was accepted.'
            $caseIds.Add('desktop_install_location_foreign')

            Assert-DesktopUninstallRegistrationOwnership -Registration $registration -ExpectedVersion $Version -ExpectedInstallRoot $installRoot -ExpectedUninstaller $uninstallPath
            Assert-Condition (Test-Throws {
                Assert-DesktopUninstallRegistrationOwnership -Registration ([pscustomobject]@{
                    DisplayVersion = "$Version-beta.1"
                    InstallLocation = $installRoot
                    UninstallString = "`"$uninstallPath`""
                }) -ExpectedVersion $Version -ExpectedInstallRoot $installRoot -ExpectedUninstaller $uninstallPath
            }) 'A foreign uninstall DisplayVersion was accepted.'
            Assert-Condition (Test-Throws {
                Assert-DesktopUninstallRegistrationOwnership -Registration ([pscustomobject]@{
                    DisplayVersion = $Version
                    InstallLocation = (Join-Path $root 'other-install')
                    UninstallString = "`"$uninstallPath`""
                }) -ExpectedVersion $Version -ExpectedInstallRoot $installRoot -ExpectedUninstaller $uninstallPath
            }) 'A foreign uninstall InstallLocation was accepted.'
            Assert-Condition (Test-Throws {
                Assert-DesktopUninstallRegistrationOwnership -Registration ([pscustomobject]@{
                    DisplayVersion = $Version
                    InstallLocation = $installRoot
                    UninstallString = "`"$(Join-Path $root 'other-install\uninstall.exe')`""
                }) -ExpectedVersion $Version -ExpectedInstallRoot $installRoot -ExpectedUninstaller $uninstallPath
            }) 'A foreign UninstallString was accepted.'
            Assert-Condition (Test-Throws { Assert-NoDesktopProtectedState -State $state -Phase 'self-test post-uninstall' }) 'Uninstall-registration residue was accepted.'
            $caseIds.Add('uninstall_registration_residue')

            $state = New-EmptyDesktopProtectedState
            $state.desktop_shortcut_exists = $true
            Assert-Condition (Test-Throws { Assert-NoDesktopProtectedState -State $state -Phase 'self-test' }) 'Pre-existing Desktop shortcut was accepted.'
            Assert-DesktopShortcutOwnership -TargetPath $appPath -InstallRoot $installRoot -ShortcutPath 'Desktop\winsmux.lnk'
            Assert-Condition (Test-Throws { Assert-DesktopShortcutOwnership -TargetPath $outsidePath -InstallRoot $installRoot -ShortcutPath 'Desktop\winsmux.lnk' }) 'A foreign Desktop shortcut target was accepted for cleanup.'
            $caseIds.Add('preexisting_desktop_shortcut')

            $state = New-EmptyDesktopProtectedState
            $state.start_menu_shortcut_exists = $true
            Assert-Condition (Test-Throws { Assert-NoDesktopProtectedState -State $state -Phase 'self-test' }) 'Pre-existing Start Menu shortcut was accepted.'
            Assert-DesktopShortcutOwnership -TargetPath $appPath -InstallRoot $installRoot -ShortcutPath 'Programs\winsmux.lnk'
            Assert-Condition (Test-Throws { Assert-DesktopShortcutOwnership -TargetPath $outsidePath -InstallRoot $installRoot -ShortcutPath 'Programs\winsmux.lnk' }) 'A foreign Start Menu shortcut target was accepted for cleanup.'
            $caseIds.Add('preexisting_start_menu_shortcut')

            $state = New-EmptyDesktopProtectedState
            $state.process_count = 1
            Assert-Condition (Test-Throws { Assert-NoDesktopProtectedState -State $state -Phase 'self-test' }) 'A pre-existing winsmux-app process was accepted.'
            $caseIds.Add('preexisting_process')

            $state = New-EmptyDesktopProtectedState
            $state.install_root_exists = $true
            Assert-Condition (Test-Throws { Assert-NoDesktopProtectedState -State $state -Phase 'self-test' }) 'A pre-existing install root was accepted.'
            $caseIds.Add('preexisting_install_root')

            Assert-DesktopInstallRootOwnership -InstallRoot $installRoot
            New-Item -ItemType Directory -Path $installRoot | Out-Null
            Set-Content -LiteralPath $uninstallPath -Value 'self-test uninstaller' -Encoding ascii -NoNewline
            Set-Content -LiteralPath $appPath -Value 'self-test app' -Encoding ascii -NoNewline
            $emptyState = New-EmptyDesktopProtectedState
            $presentPreUninstallState = [pscustomobject]@{
                folder_context_exists = $true
                background_context_exists = $true
                product_state_exists = $true
                uninstall_registration_exists = $true
                desktop_shortcut_exists = $true
                start_menu_shortcut_exists = $true
                process_count = 0
                app_payload_exists = $true
                install_root_exists = $true
            }
            $cleanPostUninstallState = [pscustomobject]@{
                folder_context_exists = $false
                background_context_exists = $false
                product_state_exists = $false
                uninstall_registration_exists = $false
                desktop_shortcut_exists = $false
                start_menu_shortcut_exists = $false
                process_count = 0
                app_payload_exists = $false
                install_root_exists = $true
            }
            $newProtectedStateProbe = {
                param(
                    [Parameter(Mandatory)]$PreState,
                    [Parameter(Mandatory)]$PostState
                )
                # This factory creates another dynamic module; capture its helpers locally too.
                $selfTestFunctions = $selfTestFunctions
                $record = [pscustomobject]@{ phases = [Collections.Generic.List[string]]::new() }
                $invoke = {
                    param($ObservedInstallRoot, $Phase)
                    & $selfTestFunctions['Assert-Condition'] (-not [string]::IsNullOrWhiteSpace([string]$ObservedInstallRoot)) 'Desktop protected-state probe observed an empty install root.'
                    $record.phases.Add([string]$Phase) | Out-Null
                    switch ([string]$Phase) {
                        'pre_uninstall' { return $PreState }
                        'post_uninstall' { return $PostState }
                        'pre_residue_cleanup' { return $PostState }
                        default { throw "Unexpected Desktop protected-state probe phase: $Phase" }
                    }
                }.GetNewClosure()
                return [pscustomobject]@{ record = $record; invoke = $invoke }
            }.GetNewClosure()
            $newMaterializedContext = {
                $candidateContext = & $selfTestFunctions['New-DesktopLifecycleContext'] -OwnedRoot $root -InstallRoot $installRoot -ExpectedVersion $Version
                & $selfTestFunctions['Start-DesktopLifecycle'] -Context $candidateContext -PreflightState $emptyState
                & $selfTestFunctions['Set-DesktopLifecyclePhase'] -Context $candidateContext -NextPhase 'installer_started'
                & $selfTestFunctions['Set-DesktopLifecyclePhase'] -Context $candidateContext -NextPhase 'materialized_verified'
                return $candidateContext
            }.GetNewClosure()
            $uninstallCapture = [pscustomobject]@{
                call_count = 0
                file_path = ''
                arguments = @()
            }
            $processInvoker = {
                param($FilePath, $Arguments, $Environment)
                $uninstallCapture.call_count += 1
                $uninstallCapture.file_path = [string]$FilePath
                $uninstallCapture.arguments = @($Arguments)
                return [pscustomobject]@{ exit_code = 0; stdout = ''; stderr = '' }
            }.GetNewClosure()
            $cleanStateProbe = & $newProtectedStateProbe -PreState $presentPreUninstallState -PostState $cleanPostUninstallState
            $leafContext = & $newMaterializedContext
            Invoke-VerifiedDesktopUninstaller -Context $leafContext -Environment @{} -ProcessInvoker $processInvoker -ProtectedStateProbe $cleanStateProbe.invoke | Out-Null
            Assert-Condition ($uninstallCapture.call_count -eq 1) 'Desktop uninstaller was not invoked exactly once.'
            Assert-Condition ([string]::Equals($uninstallCapture.file_path, $uninstallPath, [StringComparison]::OrdinalIgnoreCase)) 'Desktop uninstaller invocation did not use the verified run-owned path.'
            Assert-Condition ($uninstallCapture.arguments.Count -eq 2) 'Desktop uninstaller invocation did not contain exactly two arguments.'
            Assert-Condition ($uninstallCapture.arguments[0] -ceq '/S') 'Desktop uninstaller invocation did not put /S first.'
            Assert-Condition ($uninstallCapture.arguments[1] -ceq "_?=$installRoot") 'Desktop uninstaller invocation did not put the run-owned _? argument last.'
            Assert-Condition ([string]::Join(',', @($cleanStateProbe.record.phases)) -ceq 'pre_uninstall,post_uninstall') 'Desktop uninstaller did not prove owned state immediately before and after invocation.'
            $caseIds.Add('desktop_uninstall_argv_order')

            $preUninstallCases = @(
                [pscustomobject]@{ property = 'product_state_exists'; message = 'product-state registration was absent' },
                [pscustomobject]@{ property = 'uninstall_registration_exists'; message = 'uninstall registration was absent' },
                [pscustomobject]@{ property = 'app_payload_exists'; message = 'winsmux-app.exe was absent' }
            )
            foreach ($preUninstallCase in $preUninstallCases) {
                $preState = $presentPreUninstallState.PSObject.Copy()
                $preState.($preUninstallCase.property) = $false
                $preStateProbe = & $newProtectedStateProbe -PreState $preState -PostState $cleanPostUninstallState
                $preStateContext = & $newMaterializedContext
                $callCountBefore = $uninstallCapture.call_count
                $preStateError = $null
                try {
                    Invoke-VerifiedDesktopUninstaller -Context $preStateContext -Environment @{} -ProcessInvoker $processInvoker -ProtectedStateProbe $preStateProbe.invoke | Out-Null
                } catch {
                    $preStateError = $_
                }
                Assert-Condition ($null -ne $preStateError) "Missing pre-uninstall state was accepted: $($preUninstallCase.property)"
                Assert-Condition ($preStateError.Exception.Message -match [regex]::Escape([string]$preUninstallCase.message)) "Missing pre-uninstall state failed for the wrong reason: $($preUninstallCase.property)"
                Assert-Condition ($uninstallCapture.call_count -eq $callCountBefore) "Missing pre-uninstall state reached the Desktop uninstaller: $($preUninstallCase.property)"
                Assert-Condition ([string]::Join(',', @($preStateProbe.record.phases)) -ceq 'pre_uninstall') "Missing pre-uninstall state reached a post-uninstall probe: $($preUninstallCase.property)"
            }
            $caseIds.Add('desktop_uninstall_requires_owned_state_present')

            $postUninstallCases = @(
                [pscustomobject]@{ property = 'folder_context_exists'; message = 'folder-context registration remained' },
                [pscustomobject]@{ property = 'background_context_exists'; message = 'background-context registration remained' },
                [pscustomobject]@{ property = 'product_state_exists'; message = 'product state remained' },
                [pscustomobject]@{ property = 'uninstall_registration_exists'; message = 'uninstall registration remained' },
                [pscustomobject]@{ property = 'desktop_shortcut_exists'; message = 'Desktop shortcut remained' },
                [pscustomobject]@{ property = 'start_menu_shortcut_exists'; message = 'Start Menu shortcut remained' },
                [pscustomobject]@{ property = 'app_payload_exists'; message = 'winsmux-app.exe remained' }
            )
            foreach ($postUninstallCase in $postUninstallCases) {
                $postState = $cleanPostUninstallState.PSObject.Copy()
                $postState.($postUninstallCase.property) = $true
                $postStateProbe = & $newProtectedStateProbe -PreState $presentPreUninstallState -PostState $postState
                $postStateContext = & $newMaterializedContext
                $callCountBefore = $uninstallCapture.call_count
                $postStateError = $null
                try {
                    Invoke-VerifiedDesktopUninstaller -Context $postStateContext -Environment @{} -ProcessInvoker $processInvoker -ProtectedStateProbe $postStateProbe.invoke | Out-Null
                } catch {
                    $postStateError = $_
                }
                Assert-Condition ($null -ne $postStateError) "Post-uninstall owned-state residue was accepted: $($postUninstallCase.property)"
                Assert-Condition ($postStateError.Exception.Message -match [regex]::Escape([string]$postUninstallCase.message)) "Post-uninstall owned-state residue failed for the wrong reason: $($postUninstallCase.property)"
                Assert-Condition ($uninstallCapture.call_count -eq ($callCountBefore + 1)) "Post-uninstall owned-state residue did not reach exactly one normal uninstaller invocation: $($postUninstallCase.property)"
                Assert-Condition ([string]::Join(',', @($postStateProbe.record.phases)) -ceq 'pre_uninstall,post_uninstall') "Post-uninstall owned-state residue was not observed immediately around invocation: $($postUninstallCase.property)"
            }
            $caseIds.Add('desktop_uninstall_rejects_owned_state_residue')

            $helperParseErrors = $null
            $helperTokens = $null
            $helperAst = [Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$helperTokens, [ref]$helperParseErrors)
            Assert-Condition (@($helperParseErrors).Count -eq 0) 'Desktop helper source did not parse for residue-cleanup pinning.'
            $residueFunctions = @($helperAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Remove-DesktopOwnedResidue'
            }, $true))
            Assert-Condition ($residueFunctions.Count -eq 1) 'Desktop helper did not contain exactly one Remove-DesktopOwnedResidue function.'
            $residueRemoveCommands = @($residueFunctions[0].Body.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Remove-Item'
            }, $true))
            Assert-Condition ($residueRemoveCommands.Count -eq 2) 'Desktop residue cleanup must remove only leftover uninstall.exe and the empty install root.'
            $residueRemoveText = @($residueRemoveCommands | ForEach-Object { $_.Extent.Text })
            Assert-Condition (@($residueRemoveText | Where-Object { $_ -match '(?i)-LiteralPath\s+\$expectedUninstaller(?:\s|$)' }).Count -eq 1) 'Desktop residue cleanup did not narrowly remove leftover uninstall.exe.'
            Assert-Condition (@($residueRemoveText | Where-Object { $_ -match '(?i)-LiteralPath\s+\$InstallRoot(?:\s|$)' -and $_ -notmatch '(?i)(?:^|\s)-Recurse(?:\s|$)' }).Count -eq 1) 'Desktop residue cleanup did not remove the empty install root non-recursively.'
            Assert-Condition (($residueRemoveText -join "`n") -notmatch '(?i)DesktopProductPath|shortcutPath|winsmux-app\.exe') 'Desktop residue cleanup still removes uninstaller-owned product state, shortcuts, or payload.'
            $caseIds.Add('desktop_residue_cleanup_only_removes_uninstaller_and_empty_root')

            $foreignUninstaller = Join-Path $root 'outside\uninstall.exe'
            $foreignContext = & $newMaterializedContext
            $foreignContext.expected_uninstaller = $foreignUninstaller
            $callCountBeforeForeign = $uninstallCapture.call_count
            Assert-Condition (Test-Throws {
                Invoke-VerifiedDesktopUninstaller -Context $foreignContext -Environment @{} -ProcessInvoker $processInvoker -ProtectedStateProbe $cleanStateProbe.invoke
            }) 'A foreign Desktop uninstaller path reached invocation.'
            Assert-Condition ($uninstallCapture.call_count -eq $callCountBeforeForeign) 'A foreign Desktop uninstaller path reached the process invoker.'
            $caseIds.Add('desktop_uninstall_foreign_path')

            $ownershipCalls = [pscustomobject]@{ stop = 0; uninstall = 0; residue = 0; root = 0 }
            $ownershipContext = New-DesktopLifecycleContext -OwnedRoot $root -InstallRoot $installRoot -ExpectedVersion $Version
            Start-DesktopLifecycle -Context $ownershipContext -PreflightState $emptyState
            Set-DesktopLifecyclePhase -Context $ownershipContext -NextPhase 'installer_started'
            $ownershipStopInvoker = { $ownershipCalls.stop += 1 }.GetNewClosure()
            $ownershipUninstallInvoker = { $ownershipCalls.uninstall += 1 }.GetNewClosure()
            $ownershipResidueInvoker = { $ownershipCalls.residue += 1 }.GetNewClosure()
            $ownershipRootRemover = { $ownershipCalls.root += 1 }.GetNewClosure()
            Invoke-DesktopCleanup -Context $ownershipContext -Environment @{} -OperationErrorMessage 'foreign registration rejected' `
                -StopInvoker $ownershipStopInvoker `
                -UninstallInvoker $ownershipUninstallInvoker `
                -ResidueInvoker $ownershipResidueInvoker `
                -RootRemover $ownershipRootRemover | Out-Null
            Assert-Condition ($ownershipContext.phase -ceq 'preserve') 'Ownership rejection did not enter the Desktop preserve state.'
            Assert-Condition (($ownershipCalls.stop + $ownershipCalls.uninstall + $ownershipCalls.residue + $ownershipCalls.root) -eq 0) 'Ownership rejection reached a Desktop cleanup effect.'
            $caseIds.Add('desktop_lifecycle_ownership_reject_preserves_state')

            $stopFailureCalls = [pscustomobject]@{ stop = 0; uninstall = 0; residue = 0; root = 0 }
            $stopFailureContext = & $newMaterializedContext
            $stopFailureStopInvoker = {
                $stopFailureCalls.stop += 1
                throw 'synthetic stop failure'
            }.GetNewClosure()
            $stopFailureUninstallInvoker = { $stopFailureCalls.uninstall += 1 }.GetNewClosure()
            $stopFailureResidueInvoker = { $stopFailureCalls.residue += 1 }.GetNewClosure()
            $stopFailureRootRemover = { $stopFailureCalls.root += 1 }.GetNewClosure()
            Assert-Condition (Test-Throws {
                Invoke-DesktopCleanup -Context $stopFailureContext -Environment @{} `
                    -StopInvoker $stopFailureStopInvoker `
                    -UninstallInvoker $stopFailureUninstallInvoker `
                    -ResidueInvoker $stopFailureResidueInvoker `
                    -RootRemover $stopFailureRootRemover
            }) 'A Desktop process-stop failure was accepted.'
            Assert-Condition ($stopFailureContext.phase -ceq 'preserve') 'Process-stop failure did not enter the Desktop preserve state.'
            Assert-Condition ($stopFailureCalls.stop -eq 1) 'Process-stop failure did not execute the stop owner exactly once.'
            Assert-Condition (($stopFailureCalls.uninstall + $stopFailureCalls.residue + $stopFailureCalls.root) -eq 0) 'Process-stop failure reached a later Desktop cleanup effect.'
            $caseIds.Add('desktop_lifecycle_stop_failure_preserves_state')

            $uninstallFailureCalls = [pscustomobject]@{ stop = 0; uninstall = 0; residue = 0; root = 0 }
            $uninstallFailureContext = & $newMaterializedContext
            $nonzeroProcessInvoker = {
                param($FilePath, $Arguments, $Environment)
                return [pscustomobject]@{ exit_code = 1; stdout = ''; stderr = 'synthetic uninstall failure' }
            }
            $uninstallFailureStateProbe = & $newProtectedStateProbe -PreState $presentPreUninstallState -PostState $cleanPostUninstallState
            $uninstallFailureStopInvoker = { $uninstallFailureCalls.stop += 1 }.GetNewClosure()
            $uninstallFailureUninstallInvoker = {
                param($Context, $Environment)
                $uninstallFailureCalls.uninstall += 1
                & $selfTestFunctions['Invoke-VerifiedDesktopUninstaller'] -Context $Context -Environment $Environment -ProcessInvoker $nonzeroProcessInvoker -ProtectedStateProbe $uninstallFailureStateProbe.invoke | Out-Null
            }.GetNewClosure()
            $uninstallFailureResidueInvoker = { $uninstallFailureCalls.residue += 1 }.GetNewClosure()
            $uninstallFailureRootRemover = { $uninstallFailureCalls.root += 1 }.GetNewClosure()
            Assert-Condition (Test-Throws {
                Invoke-DesktopCleanup -Context $uninstallFailureContext -Environment @{} `
                    -StopInvoker $uninstallFailureStopInvoker `
                    -UninstallInvoker $uninstallFailureUninstallInvoker `
                    -ResidueInvoker $uninstallFailureResidueInvoker `
                    -RootRemover $uninstallFailureRootRemover
            }) 'A non-zero Desktop uninstaller result was accepted.'
            Assert-Condition ($uninstallFailureContext.phase -ceq 'preserve') 'Uninstaller failure did not enter the Desktop preserve state.'
            Assert-Condition (($uninstallFailureCalls.stop -eq 1) -and ($uninstallFailureCalls.uninstall -eq 1)) 'Uninstaller failure did not execute the owned stop/uninstall prefix exactly once.'
            Assert-Condition (($uninstallFailureCalls.residue + $uninstallFailureCalls.root) -eq 0) 'Uninstaller failure reached Desktop residue or root cleanup.'
            $caseIds.Add('desktop_lifecycle_uninstall_failure_preserves_state')

            $registrationCalls = [pscustomobject]@{ stop = 0; uninstall = 0; residue = 0; root = 0 }
            $registrationContext = & $newMaterializedContext
            $registrationPostState = $cleanPostUninstallState.PSObject.Copy()
            $registrationPostState.uninstall_registration_exists = $true
            $registrationStateProbe = & $newProtectedStateProbe -PreState $presentPreUninstallState -PostState $registrationPostState
            $registrationStopInvoker = { $registrationCalls.stop += 1 }.GetNewClosure()
            $registrationUninstallInvoker = {
                param($Context, $Environment)
                $registrationCalls.uninstall += 1
                & $selfTestFunctions['Invoke-VerifiedDesktopUninstaller'] -Context $Context -Environment $Environment -ProcessInvoker $processInvoker -ProtectedStateProbe $registrationStateProbe.invoke | Out-Null
            }.GetNewClosure()
            $registrationResidueInvoker = { $registrationCalls.residue += 1 }.GetNewClosure()
            $registrationRootRemover = { $registrationCalls.root += 1 }.GetNewClosure()
            Assert-Condition (Test-Throws {
                Invoke-DesktopCleanup -Context $registrationContext -Environment @{} `
                    -StopInvoker $registrationStopInvoker `
                    -UninstallInvoker $registrationUninstallInvoker `
                    -ResidueInvoker $registrationResidueInvoker `
                    -RootRemover $registrationRootRemover
            }) 'An exit-zero Desktop uninstall with remaining registration was accepted.'
            Assert-Condition ($registrationContext.phase -ceq 'preserve') 'Remaining registration did not enter the Desktop preserve state.'
            Assert-Condition (($registrationCalls.stop -eq 1) -and ($registrationCalls.uninstall -eq 1)) 'Remaining-registration case did not execute the owned stop/uninstall prefix exactly once.'
            Assert-Condition (($registrationCalls.residue + $registrationCalls.root) -eq 0) 'Remaining registration reached Desktop residue or root cleanup.'
            $caseIds.Add('desktop_lifecycle_registration_remains_preserves_state')

            $successOrder = [Collections.Generic.List[string]]::new()
            $successContext = & $newMaterializedContext
            $successStopInvoker = { $successOrder.Add('stop') | Out-Null }.GetNewClosure()
            $successUninstallInvoker = { $successOrder.Add('uninstall') | Out-Null }.GetNewClosure()
            $successResidueInvoker = { $successOrder.Add('residue') | Out-Null }.GetNewClosure()
            $successRootRemover = { $successOrder.Add('root') | Out-Null }.GetNewClosure()
            Invoke-DesktopCleanup -Context $successContext -Environment @{} `
                -StopInvoker $successStopInvoker `
                -UninstallInvoker $successUninstallInvoker `
                -ResidueInvoker $successResidueInvoker `
                -RootRemover $successRootRemover | Out-Null
            Assert-Condition ($successContext.phase -ceq 'clean') 'Successful Desktop lifecycle did not reach clean.'
            Assert-Condition ([string]::Join(',', @($successOrder)) -ceq 'stop,uninstall,residue,root') 'Desktop lifecycle cleanup order changed.'
            $unexpectedStopInvoker = { $successOrder.Add('unexpected-stop') | Out-Null }.GetNewClosure()
            $unexpectedUninstallInvoker = { $successOrder.Add('unexpected-uninstall') | Out-Null }.GetNewClosure()
            $unexpectedResidueInvoker = { $successOrder.Add('unexpected-residue') | Out-Null }.GetNewClosure()
            $unexpectedRootRemover = { $successOrder.Add('unexpected-root') | Out-Null }.GetNewClosure()
            Invoke-DesktopCleanup -Context $successContext -Environment @{} `
                -StopInvoker $unexpectedStopInvoker `
                -UninstallInvoker $unexpectedUninstallInvoker `
                -ResidueInvoker $unexpectedResidueInvoker `
                -RootRemover $unexpectedRootRemover | Out-Null
            Assert-Condition ([string]::Join(',', @($successOrder)) -ceq 'stop,uninstall,residue,root') 'Clean Desktop lifecycle re-entry repeated a cleanup effect.'
            $caseIds.Add('desktop_lifecycle_success_orders_cleanup')

            $residueFailureCalls = [pscustomobject]@{ stop = 0; uninstall = 0; residue = 0; root = 0 }
            $residueFailureContext = & $newMaterializedContext
            $residueFailureStopInvoker = { $residueFailureCalls.stop += 1 }.GetNewClosure()
            $residueFailureUninstallInvoker = { $residueFailureCalls.uninstall += 1 }.GetNewClosure()
            $residueFailureResidueInvoker = {
                $residueFailureCalls.residue += 1
                throw 'synthetic residue failure'
            }.GetNewClosure()
            $residueFailureRootRemover = { $residueFailureCalls.root += 1 }.GetNewClosure()
            Assert-Condition (Test-Throws {
                Invoke-DesktopCleanup -Context $residueFailureContext -Environment @{} `
                    -StopInvoker $residueFailureStopInvoker `
                    -UninstallInvoker $residueFailureUninstallInvoker `
                    -ResidueInvoker $residueFailureResidueInvoker `
                    -RootRemover $residueFailureRootRemover
            }) 'A Desktop residue failure was accepted.'
            Assert-Condition ($residueFailureContext.phase -ceq 'preserve') 'Residue failure did not enter the Desktop preserve state.'
            Assert-Condition (($residueFailureCalls.stop -eq 1) -and ($residueFailureCalls.uninstall -eq 1) -and ($residueFailureCalls.residue -eq 1)) 'Residue failure did not execute the owned cleanup prefix exactly once.'
            Assert-Condition ($residueFailureCalls.root -eq 0) 'Residue failure reached generic root cleanup.'
            $caseIds.Add('desktop_lifecycle_residue_failure_blocks_root_cleanup')

            $diagnosticFixtures = @(
                [pscustomobject]@{ operation = 'core_version'; state = 'stderr_nonempty'; exit_code = 0; stdout = 'T825_CORE_OUT'; stderr = 'T825_CORE_ERR'; marker = 'T825_CORE' },
                [pscustomobject]@{ operation = 'npm_view'; state = 'parse_failed'; exit_code = 0; stdout = 'T825_NPM_VIEW_OUT'; stderr = ''; marker = 'T825_NPM_VIEW' },
                [pscustomobject]@{ operation = 'npm_pack'; state = 'parse_failed'; exit_code = 0; stdout = 'T825_NPM_PACK_OUT'; stderr = ''; marker = 'T825_NPM_PACK' },
                [pscustomobject]@{ operation = 'tar_list'; state = 'content_invalid'; exit_code = 0; stdout = 'T825_TAR_LIST_OUT'; stderr = ''; marker = 'T825_TAR_LIST' },
                [pscustomobject]@{ operation = 'tar_extract'; state = 'exit_nonzero'; exit_code = 23; stdout = ''; stderr = 'T825_TAR_EXTRACT_ERR'; marker = 'T825_TAR_EXTRACT' },
                [pscustomobject]@{ operation = 'npm_help'; state = 'content_invalid'; exit_code = 0; stdout = 'T825_NPM_HELP_OUT'; stderr = ''; marker = 'T825_NPM_HELP' },
                [pscustomobject]@{ operation = 'desktop_installer'; state = 'exit_nonzero'; exit_code = 23; stdout = ''; stderr = 'T825_DESKTOP_INSTALLER_ERR'; marker = 'T825_DESKTOP_INSTALLER' },
                [pscustomobject]@{ operation = 'desktop_observer'; state = 'exited'; exit_code = 23; stdout = 'T825_DESKTOP_OBSERVER_OUT'; stderr = 'T825_DESKTOP_OBSERVER_ERR'; marker = 'T825_DESKTOP_OBSERVER' },
                [pscustomobject]@{ operation = 'desktop_uninstaller'; state = 'exit_nonzero'; exit_code = 23; stdout = ''; stderr = ('T825_DESKTOP_UNINSTALLER_ERR-' + ('X' * 16384)); marker = 'T825_DESKTOP_UNINSTALLER' }
            )
            $diagnosticRecords = [Collections.Generic.List[object]]::new()
            $diagnosticMessages = [Collections.Generic.List[string]]::new()
            foreach ($fixture in $diagnosticFixtures) {
                $rawResult = [pscustomobject]@{ exit_code = [int]$fixture.exit_code; stdout = [string]$fixture.stdout; stderr = [string]$fixture.stderr }
                $message = Format-PublicChildProcessDiagnostic -Operation $fixture.operation -State $fixture.state -Result $rawResult
                $diagnosticMessages.Add($message) | Out-Null
                $match = [regex]::Match($message, '^child_process_failure operation=(?<operation>[a-z_]+) state=(?<state>[a-z_]+) exit_code=(?<exit_code>\d+|none) stdout_present=(?<stdout_present>true|false) stdout_bytes=(?<stdout_bytes>\d+) stdout_truncated=(?<stdout_truncated>true|false) stderr_present=(?<stderr_present>true|false) stderr_bytes=(?<stderr_bytes>\d+) stderr_truncated=(?<stderr_truncated>true|false)$')
                Assert-Condition $match.Success 'Public child-process diagnostic did not match the fixed grammar.'
                $rawBytes = [Text.Encoding]::UTF8.GetBytes(([string]$fixture.stdout + [string]$fixture.stderr))
                $rawDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes)).ToLowerInvariant()
                $diagnosticRecords.Add([ordered]@{
                    operation = $match.Groups['operation'].Value
                    state = $match.Groups['state'].Value
                    exit_code = [int]$match.Groups['exit_code'].Value
                    stdout_present = [bool]::Parse($match.Groups['stdout_present'].Value)
                    stdout_bytes = [int]$match.Groups['stdout_bytes'].Value
                    stdout_truncated = [bool]::Parse($match.Groups['stdout_truncated'].Value)
                    stderr_present = [bool]::Parse($match.Groups['stderr_present'].Value)
                    stderr_bytes = [int]$match.Groups['stderr_bytes'].Value
                    stderr_truncated = [bool]::Parse($match.Groups['stderr_truncated'].Value)
                    marker_absent = $message -notmatch [regex]::Escape([string]$fixture.marker)
                    digest_absent = $message -notmatch [regex]::Escape($rawDigest)
                    formatted_once = @([regex]::Matches($message, 'child_process_failure')).Count -eq 1
                })
            }
            $allDiagnosticMessages = [string]::Join("`n", @($diagnosticMessages))
            $evidence.process_diagnostics = [ordered]@{
                records = @($diagnosticRecords)
                public_error_marker_absent = $allDiagnosticMessages -notmatch 'T825_(CORE|NPM|TAR|DESKTOP)'
                self_test_json_marker_absent = ((@($diagnosticRecords) | ConvertTo-Json -Depth 10 -Compress) -notmatch 'T825_(CORE|NPM|TAR|DESKTOP)')
                block_error_marker_absent = $true
            }
            $caseIds.Add('process_diagnostics_metadata_only')

            $pwshPath = Join-Path $PSHOME 'pwsh.exe'
            Assert-Condition (Test-Path -LiteralPath $pwshPath -PathType Leaf) 'PowerShell self-test child executable was not found.'
            $diagnosticCorrectionFailures = [Collections.Generic.List[string]]::new()
            $timeoutStdout = 'T825_TIMEOUT_OUT'
            $timeoutStderr = 'T825_TIMEOUT_ERR'
            $timeoutFailure = $null
            try {
                Invoke-NativeProcess -FilePath $pwshPath -ArgumentList @(
                    '-NoProfile',
                    '-Command',
                    "[Console]::Out.Write('$timeoutStdout'); [Console]::Out.Flush(); [Console]::Error.Write('$timeoutStderr'); [Console]::Error.Flush(); Start-Sleep -Seconds 30"
                ) -Environment @{} -TimeoutSeconds 2 | Out-Null
            } catch {
                $timeoutFailure = $_.Exception
            }
            if ($timeoutFailure -isnot [TimeoutException]) {
                $diagnosticCorrectionFailures.Add('timeout_exception_type') | Out-Null
            } else {
                $timeoutResult = $timeoutFailure.Data['process_result']
                if ($null -eq $timeoutResult) {
                    $diagnosticCorrectionFailures.Add('timeout_capture_missing') | Out-Null
                } else {
                    $timeoutMessage = Format-PublicChildProcessDiagnostic -Operation 'core_version' -State 'timed_out' -Result $timeoutResult
                    $expectedTimeoutMessage = 'child_process_failure operation=core_version state=timed_out exit_code=none stdout_present=true stdout_bytes={0} stdout_truncated=false stderr_present=true stderr_bytes={1} stderr_truncated=false' -f @(
                        [Text.Encoding]::UTF8.GetByteCount($timeoutStdout),
                        [Text.Encoding]::UTF8.GetByteCount($timeoutStderr)
                    )
                    if ($timeoutMessage -cne $expectedTimeoutMessage) {
                        $diagnosticCorrectionFailures.Add('timeout_metadata_mismatch') | Out-Null
                    }
                    if ($timeoutMessage.Contains($timeoutStdout, [StringComparison]::Ordinal) -or
                        $timeoutMessage.Contains($timeoutStderr, [StringComparison]::Ordinal)) {
                        $diagnosticCorrectionFailures.Add('timeout_raw_output_exposed') | Out-Null
                    }
                }
            }
            $newObservationContext = {
                $candidate = & $selfTestFunctions['New-DesktopLifecycleContext'] -OwnedRoot $root -InstallRoot $installRoot -ExpectedVersion $Version
                & $selfTestFunctions['Start-DesktopLifecycle'] -Context $candidate -PreflightState $emptyState
                & $selfTestFunctions['Set-DesktopLifecyclePhase'] -Context $candidate -NextPhase 'installer_started'
                & $selfTestFunctions['Set-DesktopLifecyclePhase'] -Context $candidate -NextPhase 'materialized_verified'
                return $candidate
            }.GetNewClosure()
            $observerStop = { param($OwnedProcess) & $selfTestFunctions['Stop-OwnedProcessTree'] -RootProcess $OwnedProcess }.GetNewClosure()
            $observerUninstall = { param($Context, $Environment) }.GetNewClosure()
            $observerResidue = { param($Context) }.GetNewClosure()
            $observerRoot = { param($OwnedRoot) }.GetNewClosure()
            $noDelay = { param($Attempt) }.GetNewClosure()
            $noPage = { param($Port, $Attempt, $OwnedProcess) return $null }.GetNewClosure()
            $injectedAcceptedUrlMarker = 'T825_DESKTOP_ACCEPTED_SUFFIX_MARKER'
            $injectedAcceptedPageUrl = "tauri://localhost/$injectedAcceptedUrlMarker`?probe=$injectedAcceptedUrlMarker#$injectedAcceptedUrlMarker"
            $httpAcceptedUrlMarker = 'T826_CDP_ACCEPTED_SUFFIX_MARKER'
            $pageReady = { param($Port, $Attempt, $OwnedProcess) return $injectedAcceptedPageUrl }.GetNewClosure()
            $lifecycleCounts = [pscustomobject]@{ owner = 0; cleanup = 0 }
            $lifecycleRoot = { param($OwnedRoot) $lifecycleCounts.cleanup += 1 }.GetNewClosure()

            $exitedContext = & $newObservationContext
            $exitedContext.app_process = Start-OwnedProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-Command', "[Console]::Out.Write('T825_DESKTOP_OBSERVER_OUT'); [Console]::Error.Write('T825_DESKTOP_OBSERVER_ERR'); exit 23")
            [void]$exitedContext.app_process.process.WaitForExit(10000)
            $exitedFailure = $null
            $lifecycleCounts.owner += 1
            try {
                Invoke-DesktopLifecycleOperation -Context $exitedContext -Environment @{} -Port 48251 -MaxAttempts 1 -PageProbe $noPage -DelayInvoker $noDelay `
                    -StopInvoker $observerStop -UninstallInvoker $observerUninstall -ResidueInvoker $observerResidue -RootRemover $lifecycleRoot | Out-Null
            } catch {
                $exitedFailure = $_.Exception
            }
            Assert-Condition ($null -ne $exitedFailure) 'Exited Desktop observer probe did not fail.'
            $exitedObservation = $exitedFailure.Data['observation']

            $liveContext = & $newObservationContext
            $liveContext.app_process = Start-OwnedProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
            $liveFailure = $null
            try {
                Invoke-DesktopLifecycleOperation -Context $liveContext -Environment @{} -Port 48252 -MaxAttempts 2 -PageProbe $noPage -DelayInvoker $noDelay `
                    -StopInvoker $observerStop -UninstallInvoker $observerUninstall -ResidueInvoker $observerResidue -RootRemover $observerRoot | Out-Null
            } catch {
                $liveFailure = $_.Exception
            }
            Assert-Condition ($null -ne $liveFailure) 'Live-without-CDP Desktop observer probe did not fail.'
            $liveObservation = $liveFailure.Data['observation']

            $pageContext = & $newObservationContext
            $pageContext.app_process = Start-OwnedProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
            $lifecycleCounts.owner += 1
            $pageObservation = Invoke-DesktopLifecycleOperation -Context $pageContext -Environment @{} -Port 48253 -MaxAttempts 1 -PageProbe $pageReady -DelayInvoker $noDelay `
                -StopInvoker $observerStop -UninstallInvoker $observerUninstall -ResidueInvoker $observerResidue -RootRemover $lifecycleRoot

            $raceContext = & $newObservationContext
            $raceContext.app_process = Start-OwnedProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
            $racePage = {
                param($Port, $Attempt, $OwnedProcess)
                & $selfTestFunctions['Stop-OwnedProcessTree'] -RootProcess $OwnedProcess
                [void]$OwnedProcess.process.WaitForExit(10000)
                return 'tauri://localhost/'
            }.GetNewClosure()
            $raceFailure = $null
            try {
                Invoke-DesktopLifecycleOperation -Context $raceContext -Environment @{} -Port 48254 -MaxAttempts 1 -PageProbe $racePage -DelayInvoker $noDelay `
                    -StopInvoker $observerStop -UninstallInvoker $observerUninstall -ResidueInvoker $observerResidue -RootRemover $observerRoot | Out-Null
            } catch {
                $raceFailure = $_.Exception
            }
            Assert-Condition ($null -ne $raceFailure) 'Post-probe Desktop exit was accepted as page-ready.'
            $raceObservation = $raceFailure.Data['observation']
            $evidence.desktop_observer = [ordered]@{
                records = @($exitedObservation, $liveObservation, $pageObservation)
                post_probe_exit_wins = [string]$raceObservation.state -ceq 'exited'
            }
            Assert-Condition ([string]$pageObservation.page_url -ceq 'tauri://localhost/') 'Injected accepted Desktop page URL was not projected to the canonical public identity.'
            Assert-Condition ((@($evidence.desktop_observer) | ConvertTo-Json -Depth 10 -Compress) -notmatch [regex]::Escape($injectedAcceptedUrlMarker)) 'Injected accepted Desktop page evidence exposed its hostile suffix.'
            $caseIds.Add('desktop_observer_states')

            $liveOutputStdout = 'T825_LIVE_OUT'
            $liveOutputStderr = 'T825_LIVE_ERR'
            $liveOutputReady = Join-Path $root 'desktop-live-output.ready'
            $liveOutputContext = & $newObservationContext
            $liveOutputContext.app_process = Start-OwnedProcess -FilePath $pwshPath -ArgumentList @(
                '-NoProfile',
                '-Command',
                "[Console]::Out.Write('$liveOutputStdout'); [Console]::Out.Flush(); [Console]::Error.Write('$liveOutputStderr'); [Console]::Error.Flush(); [IO.File]::WriteAllText(`$env:T825_LIVE_READY, 'ready', [Text.UTF8Encoding]::new(`$false)); Start-Sleep -Seconds 30"
            ) -Environment @{ T825_LIVE_READY = $liveOutputReady }
            $readyDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $liveOutputReady -PathType Leaf) -and
                [DateTimeOffset]::UtcNow -lt $readyDeadline) {
                Start-Sleep -Milliseconds 25
            }
            if (-not (Test-Path -LiteralPath $liveOutputReady -PathType Leaf)) {
                $diagnosticCorrectionFailures.Add('live_output_readiness_missing') | Out-Null
            }
            $liveOutputFailure = $null
            try {
                Invoke-DesktopLifecycleOperation -Context $liveOutputContext -Environment @{} -Port 48252 -MaxAttempts 1 -PageProbe $noPage -DelayInvoker $noDelay `
                    -StopInvoker $observerStop -UninstallInvoker $observerUninstall -ResidueInvoker $observerResidue -RootRemover $observerRoot | Out-Null
            } catch {
                $liveOutputFailure = $_.Exception
            }
            if ($null -eq $liveOutputFailure) {
                $diagnosticCorrectionFailures.Add('live_output_failure_missing') | Out-Null
            } else {
                $expectedLiveMessage = 'child_process_failure operation=desktop_observer state=live_no_cdp exit_code=none stdout_present=true stdout_bytes={0} stdout_truncated=false stderr_present=true stderr_bytes={1} stderr_truncated=false' -f @(
                    [Text.Encoding]::UTF8.GetByteCount($liveOutputStdout),
                    [Text.Encoding]::UTF8.GetByteCount($liveOutputStderr)
                )
                if ($liveOutputFailure.Message -cne $expectedLiveMessage) {
                    $diagnosticCorrectionFailures.Add('live_output_metadata_mismatch') | Out-Null
                }
                if ($liveOutputFailure.Message.Contains($liveOutputStdout, [StringComparison]::Ordinal) -or
                    $liveOutputFailure.Message.Contains($liveOutputStderr, [StringComparison]::Ordinal)) {
                    $diagnosticCorrectionFailures.Add('live_output_raw_exposed') | Out-Null
                }
            }
            Assert-Condition ($diagnosticCorrectionFailures.Count -eq 0) (
                'TASK-825 capture-order correction probes failed: ' +
                [string]::Join(',', @($diagnosticCorrectionFailures))
            )

            $cleanupOnlyContext = & $newObservationContext
            $cleanupOnlyContext.app_process = Start-OwnedProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
            $cleanupOnlyExpected = [InvalidOperationException]::new('synthetic bounded root cleanup failure')
            $cleanupOnlyRoot = {
                param($OwnedRoot)
                $lifecycleCounts.cleanup += 1
                throw $cleanupOnlyExpected
            }.GetNewClosure()
            $cleanupOnlyActual = $null
            $lifecycleCounts.owner += 1
            try {
                Invoke-DesktopLifecycleOperation -Context $cleanupOnlyContext -Environment @{} -Port 48253 -MaxAttempts 1 -PageProbe $pageReady -DelayInvoker $noDelay `
                    -StopInvoker $observerStop -UninstallInvoker $observerUninstall -ResidueInvoker $observerResidue -RootRemover $cleanupOnlyRoot | Out-Null
            } catch {
                $cleanupOnlyActual = $_.Exception
            }

            $dualContext = & $newObservationContext
            $dualContext.app_process = Start-OwnedProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-Command', 'exit 23')
            [void]$dualContext.app_process.process.WaitForExit(10000)
            $dualCleanupExpected = [InvalidOperationException]::new('synthetic bounded root cleanup failure')
            $dualRoot = {
                param($OwnedRoot)
                $lifecycleCounts.cleanup += 1
                throw $dualCleanupExpected
            }.GetNewClosure()
            $dualActual = $null
            $lifecycleCounts.owner += 1
            try {
                Invoke-DesktopLifecycleOperation -Context $dualContext -Environment @{} -Port 48251 -MaxAttempts 1 -PageProbe $noPage -DelayInvoker $noDelay `
                    -StopInvoker $observerStop -UninstallInvoker $observerUninstall -ResidueInvoker $observerResidue -RootRemover $dualRoot | Out-Null
            } catch {
                $dualActual = $_.Exception
            }
            Assert-Condition ($null -ne $cleanupOnlyActual) 'Cleanup-only Desktop lifecycle probe did not fail.'
            Assert-Condition ($dualActual -is [AggregateException]) 'Dual Desktop lifecycle failure did not preserve an AggregateException.'
            $dualOperationExpected = $dualActual.Data['operation_failure']
            $dualCleanupRecorded = $dualActual.Data['cleanup_failure']
            $dualReferenceIdentity = [bool[]]::new(2)
            $dualReferenceIdentity[0] = [object]::ReferenceEquals($dualOperationExpected, $dualActual.InnerExceptions[0])
            $dualReferenceIdentity[1] = [object]::ReferenceEquals($dualCleanupExpected, $dualActual.InnerExceptions[1]) -and [object]::ReferenceEquals($dualCleanupRecorded, $dualActual.InnerExceptions[1])
            $evidence.desktop_lifecycle = [ordered]@{
                owner_invocations = [int]$lifecycleCounts.owner
                cleanup_invocations = [int]$lifecycleCounts.cleanup
                success = [ordered]@{
                    result_returned = $null -ne $pageObservation
                    terminal_phase = [string]$pageContext.phase
                }
                operation_only = [ordered]@{
                    exception_role = 'observer'
                    reference_identity = [object]::ReferenceEquals($exitedFailure, $exitedFailure.Data['original_exception'])
                    terminal_phase = [string]$exitedContext.phase
                }
                cleanup_only = [ordered]@{
                    exception_role = 'cleanup'
                    reference_identity = [object]::ReferenceEquals($cleanupOnlyExpected, $cleanupOnlyActual)
                    terminal_phase = [string]$cleanupOnlyContext.phase
                }
                dual = [ordered]@{
                    aggregate_type = $dualActual.GetType().FullName
                    inner_count = [int]$dualActual.InnerExceptions.Count
                    inner_roles = @('observer', 'cleanup')
                    reference_identity = $dualReferenceIdentity
                    terminal_phase = [string]$dualContext.phase
                }
            }
            $evidence.process_diagnostics.block_error_marker_absent = [string]$dualContext.block_error -notmatch 'T825_(CORE|NPM|TAR|DESKTOP)'
            $caseIds.Add('desktop_observation_cleanup_aggregate')

            Assert-Condition (Test-Throws { Assert-NoDesktopProtectedState -State $state -Phase 'self-test final cleanup' }) 'Install-root residue was accepted.'
            $caseIds.Add('install_root_residue')

            Assert-NoDesktopProtectedState -State $emptyState -Phase 'self-test final state'

            Assert-ProductionPageUrl -Url 'tauri://localhost/'
            $caseIds.Add('production_page_url')

            $payload = Join-Path $root 'setup.exe'
            Set-Content -LiteralPath $payload -Value 'public-desktop' -Encoding ascii -NoNewline
            Assert-Condition (Test-Throws { Assert-FileChecksum -Path $payload -ExpectedHash ('0' * 64) }) 'Desktop checksum mismatch was accepted.'
            $caseIds.Add('checksum_mismatch')

            Assert-Condition (Test-Throws { Assert-ProductionPageUrl -Url 'http://localhost:1420/' }) 'Development WebView URL was accepted.'
            $caseIds.Add('nonproduction_url')

            $fixedDebugEndpoint = New-DesktopFixedDebugEndpoint
            $fixedDebugArguments = @([string]$fixedDebugEndpoint.argument)
            Assert-Condition ([int]$fixedDebugEndpoint.port -ge 1 -and [int]$fixedDebugEndpoint.port -le 65535) 'Fixed Desktop debug endpoint returned an out-of-range port.'
            Assert-Condition (@($fixedDebugArguments | Where-Object { [string]$_ -ceq "--remote-debugging-port=$([int]$fixedDebugEndpoint.port)" }).Count -eq 1) 'Fixed Desktop debug endpoint did not produce exactly one matching argument.'
            Assert-Condition (@($fixedDebugArguments | Where-Object { ([string]$_).StartsWith('--type=', [StringComparison]::Ordinal) }).Count -eq 0) 'Fixed Desktop debug injection included a process-type argument.'
            Assert-Condition (@($fixedDebugArguments | Where-Object { ([string]$_).StartsWith('--remote-allow-origins', [StringComparison]::Ordinal) }).Count -eq 0) 'Fixed Desktop debug injection widened the remote origin policy.'
            $fixedPortEvidence = [ordered]@{
                exact_argument_count = [long]1
                no_type_argument = $true
                port_in_range = $true
                raw_absent = $true
                wildcard_origin_absent = $true
            }
            $fixedPortEvidence.raw_absent = ((@($fixedPortEvidence) | ConvertTo-Json -Depth 10 -Compress) -notmatch '--remote-debugging-port|--type=|--remote-allow-origins')
            Assert-Condition $fixedPortEvidence.raw_absent 'Fixed Desktop debug injection evidence exposed a raw argument.'
            $evidence.desktop_fixed_port_injection = $fixedPortEvidence
            $caseIds.Add('desktop_fixed_port_injection')

            $cdpReadyPath = Join-Path $root 'task826-cdp.ready'
            $cdpStopPath = Join-Path $root 'task826-cdp.stop'
            $rawBodyMarker = 'T826_CDP_RAW_BODY_MARKER'
            $rejectedUrlMarker = 'T826_CDP_REJECTED_URL_MARKER'
            $responderCommand = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
try {
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    [IO.File]::WriteAllText($env:T826_CDP_READY_PATH, [string]$port, [Text.UTF8Encoding]::new($false))
    $responses = @(
        [pscustomobject]@{ status = '500 Internal Server Error'; body = 'T826_CDP_RAW_BODY_MARKER' },
        [pscustomobject]@{ status = '200 OK'; body = 'not-json-T826_CDP_RAW_BODY_MARKER' },
        [pscustomobject]@{ status = '200 OK'; body = '[]' },
        [pscustomobject]@{ status = '200 OK'; body = '[{"type":"page","url":"http://127.0.0.1:1420/T826_CDP_REJECTED_URL_MARKER"}]' },
        [pscustomobject]@{ status = '200 OK'; body = '[{"type":"page","url":"tauri://localhost/T826_CDP_ACCEPTED_SUFFIX_MARKER?probe=T826_CDP_ACCEPTED_SUFFIX_MARKER#T826_CDP_ACCEPTED_SUFFIX_MARKER"}]' }
    )
    foreach ($response in $responses) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $requestBytes = [Collections.Generic.List[byte]]::new()
            $buffer = [byte[]]::new(1024)
            do {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) {
                    throw 'Loopback HTTP client closed before completing its request headers.'
                }
                for ($index = 0; $index -lt $read; $index += 1) {
                    $requestBytes.Add($buffer[$index])
                }
                $requestText = [Text.Encoding]::ASCII.GetString($requestBytes.ToArray())
            } while (-not $requestText.Contains("`r`n`r`n", [StringComparison]::Ordinal))

            $bodyBytes = [Text.Encoding]::UTF8.GetBytes([string]$response.body)
            $headers = "HTTP/1.1 $($response.status)`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
            $headerBytes = [Text.Encoding]::ASCII.GetBytes($headers)
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $stream.Write($bodyBytes, 0, $bodyBytes.Length)
            $stream.Flush()
        } finally {
            $client.Dispose()
        }
    }
    while (-not [IO.File]::Exists($env:T826_CDP_STOP_PATH)) {
        [Threading.Thread]::Sleep(20)
    }
} finally {
    $listener.Stop()
}
'@
            $encodedResponder = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($responderCommand))
            $cdpResponder = Start-OwnedProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-EncodedCommand', $encodedResponder) -Environment @{
                T826_CDP_READY_PATH = $cdpReadyPath
                T826_CDP_STOP_PATH = $cdpStopPath
            }
            $unavailableSocket = $null
            try {
                $readyDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
                while (-not (Test-Path -LiteralPath $cdpReadyPath -PathType Leaf) -and
                    -not $cdpResponder.process.HasExited -and
                    [DateTimeOffset]::UtcNow -lt $readyDeadline) {
                    [Threading.Thread]::Sleep(20)
                    $cdpResponder.process.Refresh()
                }
                Assert-Condition (Test-Path -LiteralPath $cdpReadyPath -PathType Leaf) 'Loopback CDP responder did not publish its ready record.'
                $cdpPortText = (Get-Content -LiteralPath $cdpReadyPath -Raw -Encoding UTF8).Trim()
                $cdpPort = 0
                Assert-Condition ([int]::TryParse($cdpPortText, [ref]$cdpPort)) 'Loopback CDP responder published an invalid port.'
                Assert-Condition ($cdpPort -ge 1 -and $cdpPort -le 65535) 'Loopback CDP responder published an out-of-range port.'

                $unavailableSocket = [Net.Sockets.Socket]::new(
                    [Net.Sockets.AddressFamily]::InterNetwork,
                    [Net.Sockets.SocketType]::Stream,
                    [Net.Sockets.ProtocolType]::Tcp
                )
                $unavailableSocket.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
                $unavailablePort = ([Net.IPEndPoint]$unavailableSocket.LocalEndPoint).Port
                $taxonomy = @(
                    [pscustomobject]@{ probe_state = 'transport_unavailable'; port = $unavailablePort; public_state = 'live_cdp_transport_unavailable' },
                    [pscustomobject]@{ probe_state = 'http_error'; port = $cdpPort; public_state = 'live_cdp_http_error' },
                    [pscustomobject]@{ probe_state = 'payload_invalid'; port = $cdpPort; public_state = 'live_cdp_payload_invalid' },
                    [pscustomobject]@{ probe_state = 'page_absent'; port = $cdpPort; public_state = 'live_cdp_page_absent' },
                    [pscustomobject]@{ probe_state = 'url_rejected'; port = $cdpPort; public_state = 'live_cdp_url_rejected' },
                    [pscustomobject]@{ probe_state = 'page_ready'; port = $cdpPort; public_state = 'page_ready' }
                )
                $taxonomyRecords = [Collections.Generic.List[object]]::new()
                foreach ($definition in $taxonomy) {
                    $observation = Wait-DesktopProcessObservation -OwnedProcess $cdpResponder -Port ([int]$definition.port) -MaxAttempts 1 -DelayInvoker $noDelay
                    Assert-Condition ([string]$observation.state -ceq [string]$definition.public_state) "CDP probe state '$($definition.probe_state)' mapped to an unexpected public state."
                    if ([string]$definition.probe_state -ceq 'page_ready') {
                        Assert-Condition ([string]$observation.page_url -ceq 'tauri://localhost/') 'Accepted loopback CDP page URL was not projected to the canonical public identity.'
                    }
                    $publicText = if ([string]$observation.state -ceq 'page_ready') {
                        'desktop_observer state=page_ready'
                    } else {
                        Format-PublicChildProcessDiagnostic -Operation 'desktop_observer' -State ([string]$observation.state) -Result $null
                    }
                    $taxonomyRecords.Add([ordered]@{
                        probe_state = [string]$definition.probe_state
                        public_state = [string]$observation.state
                        raw_body_absent = -not $publicText.Contains($rawBodyMarker, [StringComparison]::Ordinal)
                        raw_url_absent = -not $publicText.Contains($rejectedUrlMarker, [StringComparison]::Ordinal) -and
                            -not $publicText.Contains($httpAcceptedUrlMarker, [StringComparison]::Ordinal)
                    })
                }
                Set-Content -LiteralPath $cdpStopPath -Value 'stop' -Encoding ascii -NoNewline
                Assert-Condition $cdpResponder.process.WaitForExit(10000) 'Loopback CDP responder did not exit after its stop record.'
                $cdpCapture = Get-OwnedProcessCapture -OwnedProcess $cdpResponder
                Assert-Condition ($cdpCapture.exit_code -eq 0) 'Loopback CDP responder exited unsuccessfully.'
                Assert-Condition ([string]::IsNullOrEmpty([string]$cdpCapture.stdout)) 'Loopback CDP responder wrote unexpected stdout.'
                Assert-Condition ([string]::IsNullOrEmpty([string]$cdpCapture.stderr)) 'Loopback CDP responder wrote unexpected stderr.'
                $taxonomyEvidence = [ordered]@{
                    real_http_boundary = $true
                    records = @($taxonomyRecords)
                }
                $taxonomyJson = @($taxonomyEvidence) | ConvertTo-Json -Depth 10 -Compress
                Assert-Condition ($taxonomyJson -notmatch [regex]::Escape($rawBodyMarker)) 'CDP taxonomy evidence exposed a raw response body.'
                Assert-Condition ($taxonomyJson -notmatch [regex]::Escape($rejectedUrlMarker)) 'CDP taxonomy evidence exposed a rejected raw URL.'
                Assert-Condition ($taxonomyJson -notmatch [regex]::Escape($httpAcceptedUrlMarker)) 'CDP taxonomy evidence exposed an accepted hostile URL suffix.'
                $evidence.desktop_cdp_probe_taxonomy = $taxonomyEvidence
                $caseIds.Add('desktop_cdp_probe_taxonomy')
            } finally {
                if ($null -ne $unavailableSocket) {
                    $unavailableSocket.Dispose()
                }
                if (-not $cdpResponder.process.HasExited) {
                    Stop-OwnedProcessTree -RootProcess $cdpResponder
                }
            }

            $typedRoot = Join-Path $root 'task831-typed-observer'
            $typedUserData = Join-Path $typedRoot 'user-data'
            $typedProfileRoot = Join-Path $typedUserData 'EBWebView'
            New-Item -ItemType Directory -Path $typedProfileRoot -Force | Out-Null
            $typedPort = 49161
            $typedBrowserPath = '/devtools/browser/11111111-1111-4111-8111-111111111111'
            [IO.File]::WriteAllText(
                (Join-Path $typedProfileRoot 'DevToolsActivePort'),
                "$typedPort`n$typedBrowserPath",
                [Text.UTF8Encoding]::new($false)
            )
            $typedRootProcess = [pscustomobject]@{ process = [Diagnostics.Process]::GetCurrentProcess() }
            $typedRootPid = [int64]$typedRootProcess.process.Id
            $typedBrowserPid = $typedRootPid + 100000
            $typedBrowserCommand = '"C:\Program Files (x86)\Microsoft\EdgeWebView\Application\msedgewebview2.exe" --remote-debugging-port=49161'
            $typedProcessSnapshotItems = @(
                [pscustomobject]@{
                    process_id = $typedRootPid
                    parent_process_id = 0L
                    name = 'pwsh.exe'
                    command_line = 'pwsh.exe'
                },
                [pscustomobject]@{
                    process_id = $typedBrowserPid
                    parent_process_id = $typedRootPid
                    name = 'msedgewebview2.exe'
                    command_line = $typedBrowserCommand
                }
            )
            $typedListenerSnapshotItems = @([pscustomobject]@{
                local_address = '127.0.0.1'
                local_port = $typedPort
                owning_process = $typedBrowserPid
            })
            $typedProcessSnapshot = New-DesktopSnapshotEnvelope -Kind 'processes' -Items $typedProcessSnapshotItems
            $typedListenerSnapshot = New-DesktopSnapshotEnvelope -Kind 'listeners' -Items $typedListenerSnapshotItems
            $typedPortRecord = Read-DesktopDevToolsActivePort -UserDataFolder $typedUserData
            $typedAuthority = Resolve-DesktopWebViewListenerAuthority `
                -RootProcessId $typedRootPid `
                -Port $typedPort `
                -BrowserPath $typedBrowserPath `
                -ProcessSnapshot $typedProcessSnapshot `
                -ListenerSnapshot $typedListenerSnapshot
            $typedPageProbe = {
                param($Authority, $OwnedProcess)
                & $selfTestFunctions['Assert-Condition'] ([string]$Authority.state -ceq 'authority_ready') 'Typed page probe received an incomplete authority.'
                & $selfTestFunctions['Assert-Condition'] ([string]$Authority.host -ceq '127.0.0.1') 'Typed page probe received a non-loopback host.'
                & $selfTestFunctions['Assert-Condition'] ([int]$Authority.port -eq $typedPort) 'Typed page probe received a foreign port.'
                & $selfTestFunctions['Assert-Condition'] ([string]$Authority.browser_path -ceq $typedBrowserPath) 'Typed page probe received a foreign browser path.'
                return (& $selfTestFunctions['New-DesktopCdpProbeRecord'] -State 'page_ready' -PageUrl 'tauri://localhost/' -Port $typedPort -PathAuthority 'cross_checked')
            }.GetNewClosure()
            $typedProcessProvider = { param($OwnedProcess) return $typedProcessSnapshot }.GetNewClosure()
            $typedListenerProvider = { param($Port, $OwnedProcess) return $typedListenerSnapshot }.GetNewClosure()
            $typedProbe = Get-DesktopWebViewAuthorityProbe `
                -OwnedProcess $typedRootProcess `
                -UserDataFolder $typedUserData `
                -Port $typedPort `
                -ProcessSnapshotProvider $typedProcessProvider `
                -ListenerSnapshotProvider $typedListenerProvider `
                -PageProbe $typedPageProbe
            Assert-Condition ([string]$typedPortRecord.state -ceq 'authority_ready') 'Direct typed port-file identity was rejected.'
            Assert-Condition ([string]$typedAuthority.state -ceq 'authority_ready') 'Typed process/listener authority was rejected.'
            Assert-Condition ([string]$typedProbe.state -ceq 'page_ready') 'Typed observation authority did not reach the verified page.'
            Assert-Condition ([string]$typedProbe.page_url -ceq 'tauri://localhost/') 'Typed observation authority did not project the canonical page URL.'
            Initialize-DesktopNativeTypes
            $typedArguments = @([Winsmux.PublicRelease.WindowsCommandLine]::Parse($typedBrowserCommand))
            $typedUserDataItem = Get-Item -LiteralPath $typedUserData -Force
            $typedPortFileItem = Get-Item -LiteralPath (Join-Path $typedProfileRoot 'DevToolsActivePort') -Force
            $typedAuthorityEvidence = [ordered]@{
                browser_process_identity = [string]::Equals([string]$typedProcessSnapshotItems[1].name, 'msedgewebview2.exe', [StringComparison]::OrdinalIgnoreCase)
                debug_port_exact = @($typedArguments | Where-Object { [string]$_ -ceq "--remote-debugging-port=$typedPort" }).Count -eq 1
                listener_loopback = [string]$typedListenerSnapshotItems[0].local_address -ceq '127.0.0.1'
                listener_owner_identity = [int64]$typedListenerSnapshotItems[0].owning_process -eq $typedBrowserPid
                page_url = [string]$typedProbe.page_url
                port_file_identity = [int]$typedPortRecord.port -eq $typedPort -and [string]$typedPortRecord.browser_path -ceq $typedBrowserPath -and (($typedPortFileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
                raw_absent = $true
                root_descendant = Test-DesktopProcessDescendant -RootProcessId $typedRootPid -CandidateProcessId $typedBrowserPid -ProcessSnapshot $typedProcessSnapshot
                user_data_identity = ($typedUserDataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
                version_browser_path_identity = [string]$typedAuthority.browser_path -ceq $typedBrowserPath
            }
            $typedAuthorityJson = @($typedAuthorityEvidence) | ConvertTo-Json -Depth 10 -Compress
            $typedAuthorityEvidence.raw_absent = $typedAuthorityJson -notmatch 'DevToolsActivePort|msedgewebview2|--remote-debugging-port|/devtools/browser/|listener_owner_pid|root_pid|browser_pid'
            Assert-Condition $typedAuthorityEvidence.raw_absent 'Typed authority evidence exposed a raw authority identity.'
            $evidence.desktop_typed_observation_authority = $typedAuthorityEvidence
            $caseIds.Add('desktop_typed_observation_authority')

            $missingListenerAuthority = Resolve-DesktopWebViewListenerAuthority `
                -RootProcessId $typedRootPid `
                -Port $typedPort `
                -BrowserPath $typedBrowserPath `
                -ProcessSnapshot $typedProcessSnapshot `
                -ListenerSnapshot (New-DesktopSnapshotEnvelope -Kind 'listeners' -Items @())
            Assert-Condition ([string]$missingListenerAuthority.state -ceq 'listener_missing') 'Fixed Desktop authority did not preserve the listener-missing wait state.'
            Assert-Condition ([string]$typedAuthority.state -ceq 'authority_ready') 'Fixed Desktop authority did not accept the run-owned listener after it appeared.'
            $unusedListener = [Net.Sockets.Socket]::new(
                [Net.Sockets.AddressFamily]::InterNetwork,
                [Net.Sockets.SocketType]::Stream,
                [Net.Sockets.ProtocolType]::Tcp
            )
            try {
                $unusedListener.ExclusiveAddressUse = $true
                $unusedListener.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
                $unusedListenerPort = ([Net.IPEndPoint]$unusedListener.LocalEndPoint).Port
                $actualEmptyListenerSnapshot = Get-DesktopListenerSnapshot -Port $unusedListenerPort
            } finally {
                $unusedListener.Dispose()
            }
            Assert-Condition ([string]$actualEmptyListenerSnapshot.kind -ceq 'listeners') 'Actual listener no-match control returned the wrong envelope kind.'
            Assert-Condition (@($actualEmptyListenerSnapshot.items).Count -eq 0) 'Actual listener no-match control did not return an empty typed envelope.'
            $listenerAuthorityEvidence = [ordered]@{
                exact_argument = @($typedArguments | Where-Object { [string]$_ -ceq "--remote-debugging-port=$typedPort" }).Count -eq 1
                no_type_argument = @($typedArguments | Where-Object { ([string]$_).StartsWith('--type=', [StringComparison]::Ordinal) }).Count -eq 0
                owner_verified = [string]$typedAuthority.state -ceq 'authority_ready'
                raw_absent = $true
                real_empty_snapshot = [string]$actualEmptyListenerSnapshot.kind -ceq 'listeners' -and @($actualEmptyListenerSnapshot.items).Count -eq 0
                states = @([string]$missingListenerAuthority.state, [string]$typedAuthority.state)
            }
            $listenerAuthorityEvidence.raw_absent = ((@($listenerAuthorityEvidence) | ConvertTo-Json -Depth 10 -Compress) -notmatch 'DevToolsActivePort|msedgewebview2|--remote-debugging-port|/devtools/browser/|listener_owner_pid|root_pid|browser_pid')
            Assert-Condition $listenerAuthorityEvidence.raw_absent 'Fixed Desktop listener evidence exposed a raw authority identity.'
            $evidence.desktop_fixed_port_listener_authority = $listenerAuthorityEvidence
            $caseIds.Add('desktop_fixed_port_listener_authority')

            $validPortSnapshot = Get-DesktopDevToolsPortFileSnapshot -UserDataFolder $typedUserData
            $utf8 = [Text.UTF8Encoding]::new($false)
            $snapshotTemplate = {
                param([bool]$UserDataExists, [bool]$UserDataReparse, [bool]$FileExists, [bool]$FileReparse, [byte[]]$Bytes)
                return [pscustomobject]@{
                    user_data_exists = $UserDataExists
                    user_data_reparse = $UserDataReparse
                    file_exists = $FileExists
                    file_reparse = $FileReparse
                    too_large = $false
                    bytes = $Bytes
                }
            }
            $invalidBrowserProcessSnapshotItems = @(
                $typedProcessSnapshotItems[0],
                [pscustomobject]@{
                    process_id = $typedBrowserPid
                    parent_process_id = $typedRootPid
                    name = 'msedgewebview2.exe'
                    command_line = '"C:\Program Files (x86)\Microsoft\EdgeWebView\Application\msedgewebview2.exe" --remote-debugging-port=49162'
                }
            )
            $invalidBrowserProcessSnapshot = New-DesktopSnapshotEnvelope -Kind 'processes' -Items $invalidBrowserProcessSnapshotItems
            $ambiguousListenerSnapshotItems = @(
                $typedListenerSnapshotItems[0],
                [pscustomobject]@{
                    local_address = '::1'
                    local_port = $typedPort
                    owning_process = $typedBrowserPid + 1
                }
            )
            $ambiguousListenerSnapshot = New-DesktopSnapshotEnvelope -Kind 'listeners' -Items $ambiguousListenerSnapshotItems
            $foreignListenerSnapshotItems = @([pscustomobject]@{
                local_address = '0.0.0.0'
                local_port = $typedPort
                owning_process = $typedBrowserPid
            })
            $foreignListenerSnapshot = New-DesktopSnapshotEnvelope -Kind 'listeners' -Items $foreignListenerSnapshotItems
            $emptyListenerSnapshot = New-DesktopSnapshotEnvelope -Kind 'listeners' -Items @()
            $rejectDefinitions = @(
                [pscustomobject]@{ state = 'user_data_reparse'; port_snapshot = (& $snapshotTemplate $true $true $false $false ([byte[]]::new(0))); processes = $typedProcessSnapshot; listeners = $typedListenerSnapshot; page_state = $null },
                [pscustomobject]@{ state = 'port_file_reparse'; port_snapshot = (& $snapshotTemplate $true $false $true $true ([byte[]]::new(0))); processes = $typedProcessSnapshot; listeners = $typedListenerSnapshot; page_state = $null },
                [pscustomobject]@{ state = 'port_file_invalid_encoding'; port_snapshot = (& $snapshotTemplate $true $false $true $false ([byte[]](0xff, 0xfe))); processes = $typedProcessSnapshot; listeners = $typedListenerSnapshot; page_state = $null },
                [pscustomobject]@{ state = 'port_file_invalid_shape'; port_snapshot = (& $snapshotTemplate $true $false $true $false ($utf8.GetBytes("$typedPort`n$typedBrowserPath`n"))); processes = $typedProcessSnapshot; listeners = $typedListenerSnapshot; page_state = $null },
                [pscustomobject]@{ state = 'port_invalid'; port_snapshot = (& $snapshotTemplate $true $false $true $false ($utf8.GetBytes("0`n$typedBrowserPath"))); processes = $typedProcessSnapshot; listeners = $typedListenerSnapshot; page_state = $null },
                [pscustomobject]@{ state = 'browser_path_invalid'; port_snapshot = (& $snapshotTemplate $true $false $true $false ($utf8.GetBytes("$typedPort`n/devtools/browser/not-a-uuid"))); processes = $typedProcessSnapshot; listeners = $typedListenerSnapshot; page_state = $null },
                [pscustomobject]@{ state = 'listener_missing'; port_snapshot = $validPortSnapshot; processes = $typedProcessSnapshot; listeners = $emptyListenerSnapshot; page_state = $null },
                [pscustomobject]@{ state = 'listener_ambiguous'; port_snapshot = $validPortSnapshot; processes = $typedProcessSnapshot; listeners = $ambiguousListenerSnapshot; page_state = $null },
                [pscustomobject]@{ state = 'listener_foreign'; port_snapshot = $validPortSnapshot; processes = $typedProcessSnapshot; listeners = $foreignListenerSnapshot; page_state = $null },
                [pscustomobject]@{ state = 'browser_identity_invalid'; port_snapshot = $validPortSnapshot; processes = $invalidBrowserProcessSnapshot; listeners = $typedListenerSnapshot; page_state = $null },
                [pscustomobject]@{ state = 'version_identity_mismatch'; port_snapshot = $validPortSnapshot; processes = $typedProcessSnapshot; listeners = $typedListenerSnapshot; page_state = 'version_identity_mismatch' }
            )
            $protectedSentinel = Join-Path $typedRoot 'protected.sentinel'
            [IO.File]::WriteAllText($protectedSentinel, 'protected-state', [Text.UTF8Encoding]::new($false))
            $rejectRecords = [Collections.Generic.List[object]]::new()
            [long]$httpRequestsBeforeAuthority = 0
            foreach ($definition in $rejectDefinitions) {
                $beforeHash = (Get-FileHash -LiteralPath $protectedSentinel -Algorithm SHA256).Hash
                $requestCounts = [pscustomobject]@{ calls = 0; premature = 0 }
                $portSnapshotProvider = { param($UserDataFolder) return $definition.port_snapshot }.GetNewClosure()
                $processSnapshotProvider = { param($OwnedProcess) return $definition.processes }.GetNewClosure()
                $listenerSnapshotProvider = { param($Port, $OwnedProcess) return $definition.listeners }.GetNewClosure()
                $rejectPageProbe = {
                    param($Authority, $OwnedProcess)
                    $requestCounts.calls += 1
                    if ([string]$Authority.state -cne 'authority_ready' -or [int]$Authority.port -ne $typedPort -or [string]$Authority.browser_path -cne $typedBrowserPath) {
                        $requestCounts.premature += 1
                    }
                    return (& $selfTestFunctions['New-DesktopCdpProbeRecord'] -State ([string]$definition.page_state) -PageUrl $null -Port $typedPort)
                }.GetNewClosure()
                $rejectProbe = Get-DesktopWebViewAuthorityProbe `
                    -OwnedProcess $typedRootProcess `
                    -UserDataFolder $typedUserData `
                    -Port $typedPort `
                    -PortFileSnapshotProvider $portSnapshotProvider `
                    -ProcessSnapshotProvider $processSnapshotProvider `
                    -ListenerSnapshotProvider $listenerSnapshotProvider `
                    -PageProbe $rejectPageProbe
                Assert-Condition ([string]$rejectProbe.state -ceq [string]$definition.state) "Typed fail-closed state '$($definition.state)' was not preserved."
                if ([string]$definition.state -ceq 'version_identity_mismatch') {
                    Assert-Condition ($requestCounts.calls -eq 1) 'Version identity mismatch did not cross the verified HTTP boundary exactly once.'
                } else {
                    Assert-Condition ($requestCounts.calls -eq 0) "Typed fail-closed state '$($definition.state)' reached HTTP before authority."
                }
                $httpRequestsBeforeAuthority += [long]$requestCounts.premature
                $afterHash = (Get-FileHash -LiteralPath $protectedSentinel -Algorithm SHA256).Hash
                $publicState = "live_cdp_$([string]$definition.state)"
                $publicDiagnostic = Format-PublicChildProcessDiagnostic -Operation 'desktop_observer' -State $publicState -Result $null
                $rawAbsent = $publicDiagnostic -notmatch 'DevToolsActivePort|msedgewebview2|--remote-debugging-port|/devtools/browser/|listener_owner_pid|root_pid|browser_pid'
                $rejectRecords.Add([ordered]@{
                    protected_state_unchanged = [string]::Equals($beforeHash, $afterHash, [StringComparison]::Ordinal)
                    raw_absent = $rawAbsent
                    state = [string]$definition.state
                })
            }
            Assert-Condition ($httpRequestsBeforeAuthority -eq 0) 'Typed authority probes issued an HTTP request before authority was complete.'
            $rejectEvidence = [ordered]@{
                http_requests_before_authority = [long]$httpRequestsBeforeAuthority
                records = @($rejectRecords)
            }
            $rejectJson = @($rejectEvidence) | ConvertTo-Json -Depth 10 -Compress
            Assert-Condition ($rejectJson -notmatch 'DevToolsActivePort|msedgewebview2|--remote-debugging-port|/devtools/browser/|listener_owner_pid|root_pid|browser_pid') 'Typed fail-closed evidence exposed a raw authority identity.'
            $evidence.desktop_typed_observation_fail_closed = $rejectEvidence
            $caseIds.Add('desktop_typed_observation_fail_closed')

            $alternateBrowserPath = '/devtools/browser/22222222-2222-4222-8222-222222222222'
            $wsAuthorityDefinitions = @(
                [pscustomobject]@{
                    scenario = 'present_mismatch'
                    expected = 'version_identity_mismatch'
                    browser_path = $typedBrowserPath
                    url = "ws://127.0.0.1:$typedPort$alternateBrowserPath"
                },
                [pscustomobject]@{
                    scenario = 'absent_malformed'
                    expected = 'version_identity_mismatch'
                    browser_path = $null
                    url = "ws://127.0.0.1:$typedPort/devtools/browser/not-a-v4-uuid"
                },
                [pscustomobject]@{
                    scenario = 'absent_valid'
                    expected = 'shape_verified'
                    browser_path = $null
                    url = "ws://127.0.0.1:$typedPort$typedBrowserPath"
                },
                [pscustomobject]@{
                    scenario = 'present_match'
                    expected = 'cross_checked'
                    browser_path = $typedBrowserPath
                    url = "ws://127.0.0.1:$typedPort$typedBrowserPath"
                }
            )
            $wsAuthorityRecords = [Collections.Generic.List[object]]::new()
            foreach ($definition in $wsAuthorityDefinitions) {
                $resolvedPathAuthority = Resolve-DesktopWebSocketPathAuthority `
                    -WebSocketDebuggerUrl ([string]$definition.url) `
                    -HostName '127.0.0.1' `
                    -Port $typedPort `
                    -BrowserPath $definition.browser_path
                Assert-Condition ([string]$resolvedPathAuthority.state -ceq [string]$definition.expected) "WebSocket path authority scenario '$([string]$definition.scenario)' returned the wrong typed state."
                $wsAuthorityRecords.Add([ordered]@{
                    scenario = [string]$definition.scenario
                    state = [string]$resolvedPathAuthority.state
                })
            }
            $wsPathAuthorityEvidence = [ordered]@{
                raw_absent = $true
                records = @($wsAuthorityRecords)
            }
            $wsPathAuthorityEvidence.raw_absent = ((@($wsPathAuthorityEvidence) | ConvertTo-Json -Depth 10 -Compress) -notmatch 'DevToolsActivePort|msedgewebview2|--remote-debugging-port|/devtools/browser/|listener_owner_pid|root_pid|browser_pid')
            Assert-Condition $wsPathAuthorityEvidence.raw_absent 'WebSocket path authority evidence exposed a raw identity.'
            $evidence.desktop_ws_path_authority = $wsPathAuthorityEvidence
            $caseIds.Add('desktop_ws_path_authority')

            $captureScenarios = @(
                [pscustomobject]@{ name = 'zero'; command = 'exit 0' },
                [pscustomobject]@{ name = 'limit'; command = "[Console]::Out.Write(('x' * 16384)); [Console]::Error.Write(('y' * 16384)); exit 0" },
                [pscustomobject]@{ name = 'over_limit'; command = "[Console]::Out.Write(('x' * 16385)); [Console]::Error.Write(('y' * 16385)); exit 0" }
            )
            $captureByScenario = [ordered]@{}
            foreach ($scenario in $captureScenarios) {
                $ownedCaptureProcess = Start-OwnedProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', [string]$scenario.command)
                Assert-Condition $ownedCaptureProcess.process.WaitForExit(10000) "Bounded capture scenario '$($scenario.name)' did not become terminal."
                $captureByScenario[[string]$scenario.name] = Get-OwnedProcessCapture -OwnedProcess $ownedCaptureProcess
            }
            $captureRecords = [Collections.Generic.List[object]]::new()
            foreach ($definition in @(
                [pscustomobject]@{ stream = 'stdout'; scenario = 'zero' },
                [pscustomobject]@{ stream = 'stderr'; scenario = 'zero' },
                [pscustomobject]@{ stream = 'stdout'; scenario = 'limit' },
                [pscustomobject]@{ stream = 'stdout'; scenario = 'over_limit' },
                [pscustomobject]@{ stream = 'stderr'; scenario = 'limit' },
                [pscustomobject]@{ stream = 'stderr'; scenario = 'over_limit' }
            )) {
                $capture = $captureByScenario[[string]$definition.scenario]
                $metadata = Get-ObjectPropertyValue -Object $capture -Name "$([string]$definition.stream)_metadata"
                $captureRecords.Add([ordered]@{
                    retained_bytes = [long](Get-ObjectPropertyValue -Object $metadata -Name 'retained_bytes')
                    scenario = [string]$definition.scenario
                    stream = [string]$definition.stream
                    terminal = $true
                    total_bytes = [long](Get-ObjectPropertyValue -Object $metadata -Name 'bytes')
                    truncated = [bool](Get-ObjectPropertyValue -Object $metadata -Name 'truncated')
                })
            }
            $captureEvidence = [ordered]@{
                limit_bytes = [long]$script:DesktopOutputRetainLimitBytes
                raw_absent = $true
                records = @($captureRecords)
            }
            $captureJson = @($captureEvidence) | ConvertTo-Json -Depth 10 -Compress
            $captureEvidence.raw_absent = $captureJson -notmatch '[xy]{64}'
            Assert-Condition $captureEvidence.raw_absent 'Bounded capture evidence exposed retained child output.'
            $evidence.desktop_owned_capture_bounded = $captureEvidence
            $caseIds.Add('desktop_owned_capture_bounded')

            $unexpectedMarker = 'T826_UNEXPECTED_PROBE_RAW_MARKER'
            $unexpectedCounts = [pscustomobject]@{ cleanup = 0 }
            $unexpectedContext = & $newObservationContext
            $unexpectedContext.app_process = Start-OwnedProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
            $unexpectedProbe = {
                param($Port, $Attempt, $OwnedProcess)
                throw [InvalidOperationException]::new($unexpectedMarker)
            }.GetNewClosure()
            $unexpectedRoot = { param($OwnedRoot) $unexpectedCounts.cleanup += 1 }.GetNewClosure()
            $unexpectedFailure = $null
            try {
                Invoke-DesktopLifecycleOperation -Context $unexpectedContext -Environment @{} -Port 48255 -MaxAttempts 1 -PageProbe $unexpectedProbe -DelayInvoker $noDelay `
                    -StopInvoker $observerStop -UninstallInvoker $observerUninstall -ResidueInvoker $observerResidue -RootRemover $unexpectedRoot | Out-Null
            } catch {
                $unexpectedFailure = $_.Exception
            }
            Assert-Condition ($null -ne $unexpectedFailure) 'Unexpected Desktop probe failure was accepted.'
            $unexpectedPublicText = [string]$unexpectedFailure.Message + "`n" + [string]$unexpectedContext.block_error
            $unexpectedEvidence = [ordered]@{
                cleanup_count = [int]$unexpectedCounts.cleanup
                failed = $null -ne $unexpectedFailure
                flattened = $null -ne $unexpectedFailure.Data['observation'] -or $unexpectedFailure.Message -match 'live_(?:no_cdp|cdp_)'
                public_marker_absent = $unexpectedPublicText -notmatch [regex]::Escape($unexpectedMarker)
            }
            Assert-Condition ($unexpectedEvidence.cleanup_count -eq 1) 'Unexpected Desktop probe failure did not clean up exactly once.'
            Assert-Condition (-not $unexpectedEvidence.flattened) 'Unexpected Desktop probe failure was flattened into a live observation state.'
            Assert-Condition $unexpectedEvidence.public_marker_absent 'Unexpected Desktop probe failure exposed its raw marker.'
            Assert-Condition ((@($unexpectedEvidence) | ConvertTo-Json -Depth 10 -Compress) -notmatch [regex]::Escape($unexpectedMarker)) 'Unexpected Desktop probe evidence exposed its raw marker.'
            $evidence.desktop_unexpected_probe_failure = $unexpectedEvidence
            $caseIds.Add('desktop_unexpected_probe_failure')

            $diagnosisRoot = Join-Path $root 'task832-teardown-diagnosis'
            $syntheticProbeTable = [ordered]@{
                probe_true = @{ Script = { param($ProbeArgument) $true }; Argument = $null }
                probe_false = @{ Script = { param($ProbeArgument) $false }; Argument = $null }
                probe_error = @{ Script = { param($ProbeArgument) throw 'synthetic diagnosis failure' }; Argument = $null }
                probe_invalid_output = @{ Script = { param($ProbeArgument) 'unexpected' }; Argument = $null }
            }
            $syntheticDiagnosis = Get-DesktopTeardownDiagnosis -UserDataFolder $diagnosisRoot -ProbeTable $syntheticProbeTable
            Assert-Condition ([string]$syntheticDiagnosis.probe_true -ceq 'true') 'The immediate true teardown probe did not return true.'
            Assert-Condition ([string]$syntheticDiagnosis.probe_false -ceq 'false') 'The immediate false teardown probe did not return false.'
            Assert-Condition ([string]$syntheticDiagnosis.probe_error -ceq 'error:io') 'The throwing teardown probe did not return error:io.'
            Assert-Condition ([string]$syntheticDiagnosis.probe_invalid_output -ceq 'error:io') 'The teardown probe accepted output outside the closed value domain.'

            $syntheticTimeoutProbeTable = [ordered]@{
                probe_timeout = @{ Script = { param($ProbeArgument) Start-Sleep -Milliseconds 400; $true }; Argument = $null }
            }
            $syntheticTimeoutDiagnosis = Get-DesktopTeardownDiagnosis -UserDataFolder $diagnosisRoot -ProbeTable $syntheticTimeoutProbeTable -ProbeTimeoutMilliseconds 100 -TotalBudgetMilliseconds 500
            Assert-Condition ([string]$syntheticTimeoutDiagnosis.probe_timeout -ceq 'error:timeout') 'The sleeping teardown probe did not return error:timeout.'

            $missingDiagnosisUserData = Join-Path $diagnosisRoot 'missing-user-data'
            $realProbeTable = New-DesktopTeardownProbeTable -UserDataFolder $missingDiagnosisUserData -RootProcessId $PID -DebugPort 49161
            $expectedProbeKeys = @(
                'desktop_probe_runtime_registry',
                'desktop_probe_runtime_binary',
                'desktop_probe_profile_dir',
                'desktop_probe_init_trace',
                'desktop_probe_port_file_redirected',
                'desktop_probe_port_file_fallback',
                'desktop_probe_webview_process_present',
                'desktop_probe_debug_arg',
                'desktop_probe_env_channel'
            )
            Assert-Condition ([string]::Join(',', @($realProbeTable.Keys)) -ceq [string]::Join(',', $expectedProbeKeys)) 'The teardown probe table did not preserve the nine-key contract.'
            $realDiagnosis = Get-DesktopTeardownDiagnosis -UserDataFolder $missingDiagnosisUserData -ProbeTable $realProbeTable -ProbeTimeoutMilliseconds 1000 -TotalBudgetMilliseconds 10000
            foreach ($value in @($realDiagnosis.Values)) {
                Assert-Condition ([string]$value -cmatch '^(?:true|false|unknown|error:[a-z]+)$') 'A teardown probe returned a value outside the four-value domain.'
            }
            $evidence.desktop_teardown_diagnosis_keys = $realDiagnosis
            $caseIds.Add('desktop_teardown_diagnosis_keys')

            $budgetProbeTable = [ordered]@{
                sleep_one = @{ Script = { param($ProbeArgument) Start-Sleep -Milliseconds 400; $true }; Argument = $null }
                sleep_two = @{ Script = { param($ProbeArgument) Start-Sleep -Milliseconds 400; $true }; Argument = $null }
                sleep_three = @{ Script = { param($ProbeArgument) Start-Sleep -Milliseconds 400; $true }; Argument = $null }
            }
            $budgetStopwatch = [Diagnostics.Stopwatch]::StartNew()
            $budgetDiagnosis = Get-DesktopTeardownDiagnosis -UserDataFolder $diagnosisRoot -ProbeTable $budgetProbeTable -ProbeTimeoutMilliseconds 100 -TotalBudgetMilliseconds 150
            $budgetStopwatch.Stop()
            Assert-Condition ([string]$budgetDiagnosis.sleep_one -ceq 'error:timeout') 'The first bounded teardown probe did not time out.'
            Assert-Condition ([string]$budgetDiagnosis.sleep_three -ceq 'unknown') 'A teardown probe after total-budget exhaustion was not marked unknown.'
            Assert-Condition ($budgetStopwatch.ElapsedMilliseconds -lt 2000) 'The teardown diagnosis exceeded its bounded self-test duration.'

            $nonCooperativeProbeTable = [ordered]@{
                non_cooperative = @{ Script = { param($ProbeArgument) [System.Threading.Thread]::Sleep(2000); $true }; Argument = $null }
            }
            $nonCooperativeStopwatch = [Diagnostics.Stopwatch]::StartNew()
            $nonCooperativeDiagnosis = Get-DesktopTeardownDiagnosis -UserDataFolder $diagnosisRoot -ProbeTable $nonCooperativeProbeTable -ProbeTimeoutMilliseconds 100 -TotalBudgetMilliseconds 500
            $nonCooperativeStopwatch.Stop()
            Assert-Condition ([string]$nonCooperativeDiagnosis.non_cooperative -ceq 'error:timeout') 'The non-cooperative teardown probe did not return error:timeout.'
            Assert-Condition ($nonCooperativeStopwatch.ElapsedMilliseconds -lt 1500) 'The non-cooperative teardown probe blocked after its timeout.'

            $immediateProbeTable = [ordered]@{
                immediate_true = @{ Script = { param($ProbeArgument) $true }; Argument = $null }
                immediate_false = @{ Script = { param($ProbeArgument) $false }; Argument = $null }
            }
            $independentStopwatch = [Diagnostics.Stopwatch]::StartNew()
            $immediateDiagnosis = Get-DesktopTeardownDiagnosis -UserDataFolder $diagnosisRoot -ProbeTable $immediateProbeTable -ProbeTimeoutMilliseconds 100 -TotalBudgetMilliseconds 500
            $independentStopwatch.Stop()
            Assert-Condition ([string]$immediateDiagnosis.immediate_true -ceq 'true' -and [string]$immediateDiagnosis.immediate_false -ceq 'false') 'Immediate teardown probes did not complete independently.'
            Assert-Condition ($independentStopwatch.ElapsedMilliseconds -lt 2000) 'Immediate teardown diagnosis unexpectedly waited for cleanup.'

            $diagnosisGuard = [pscustomobject]@{ value = [ordered]@{ stale = 'true' } }
            $diagnosisEscaped = Test-Throws ({
                try {
                    $invalidProbeTable = [ordered]@{ invalid_probe = @{ Script = $null; Argument = $null } }
                    $diagnosisGuard.value = & $selfTestFunctions['Get-DesktopTeardownDiagnosis'] -UserDataFolder $diagnosisRoot -ProbeTable $invalidProbeTable -ProbeTimeoutMilliseconds 100 -TotalBudgetMilliseconds 500
                } catch {
                    $diagnosisGuard.value = $null
                }
            }.GetNewClosure())
            Assert-Condition (-not $diagnosisEscaped) 'A teardown diagnosis failure escaped the lifecycle guard.'
            Assert-Condition ($null -eq $diagnosisGuard.value) 'A teardown diagnosis failure did not clear the guarded diagnosis.'
            $caseIds.Add('desktop_teardown_diagnosis_budget')

            $validDiagnosis = [ordered]@{
                desktop_probe_runtime_binary = 'true'
                desktop_probe_profile_dir = 'false'
            }
            $validDiagnosisSegment = Get-DesktopTeardownDiagnosisSegment -Diagnosis $validDiagnosis
            Assert-Condition ($validDiagnosisSegment -ceq 'desktop_probe_runtime_binary=true desktop_probe_profile_dir=false') 'The teardown diagnosis segment did not preserve ordered typed pairs.'
            Assert-Condition (Test-Throws {
                Get-DesktopTeardownDiagnosisSegment -Diagnosis ([ordered]@{ desktop_probe_runtime_binary = '/devtools/browser/x' })
            }) 'A teardown diagnosis segment accepted a raw browser path.'
            Assert-Condition (Test-Throws {
                Get-DesktopTeardownDiagnosisSegment -Diagnosis ([ordered]@{ desktop_probe_Runtime_binary = 'true' })
            }) 'A teardown diagnosis segment accepted a key outside the lowercase allowlist.'
            $caseIds.Add('desktop_teardown_diagnosis_privacy')

            $debugProbeRootPid = [long]$PID
            $debugProbeBrowserPid = $debugProbeRootPid + 200000L
            $debugProbeRootItem = [pscustomobject]@{
                ProcessId = $debugProbeRootPid
                ParentProcessId = 0L
                Name = 'pwsh.exe'
                CommandLine = 'pwsh.exe'
            }
            $matchingDebugProcesses = @(
                $debugProbeRootItem,
                [pscustomobject]@{
                    ProcessId = $debugProbeBrowserPid
                    ParentProcessId = $debugProbeRootPid
                    Name = 'msedgewebview2.exe'
                    CommandLine = '"C:\Program Files (x86)\Microsoft\EdgeWebView\Application\msedgewebview2.exe" --remote-debugging-port=49161'
                }
            )
            $missingDebugProcesses = @(
                $debugProbeRootItem,
                [pscustomobject]@{
                    ProcessId = $debugProbeBrowserPid
                    ParentProcessId = $debugProbeRootPid
                    Name = 'msedgewebview2.exe'
                    CommandLine = '"C:\Program Files (x86)\Microsoft\EdgeWebView\Application\msedgewebview2.exe" --remote-debugging-port=49162'
                }
            )
            $matchingDebugTable = New-DesktopTeardownProbeTable `
                -UserDataFolder $missingDiagnosisUserData `
                -RootProcessId $debugProbeRootPid `
                -DebugPort 49161 `
                -ProcessSnapshotItems $matchingDebugProcesses
            $missingDebugTable = New-DesktopTeardownProbeTable `
                -UserDataFolder $missingDiagnosisUserData `
                -RootProcessId $debugProbeRootPid `
                -DebugPort 49161 `
                -ProcessSnapshotItems $missingDebugProcesses
            $matchingDebugProbe = $matchingDebugTable.desktop_probe_debug_arg
            $missingDebugProbe = $missingDebugTable.desktop_probe_debug_arg
            $debugTrue = if (& ([scriptblock]$matchingDebugProbe.Script) $matchingDebugProbe.Argument) { 'true' } else { 'false' }
            $debugFalse = if (& ([scriptblock]$missingDebugProbe.Script) $missingDebugProbe.Argument) { 'true' } else { 'false' }
            $debugErrorTable = [ordered]@{
                desktop_probe_debug_arg = @{ Script = { param($ProbeArgument) throw 'synthetic debug argument probe failure' }; Argument = $null }
            }
            $debugUnknownTable = [ordered]@{
                desktop_probe_debug_arg = @{ Script = { param($ProbeArgument) $true }; Argument = $null }
            }
            $debugError = (Get-DesktopTeardownDiagnosis -UserDataFolder $diagnosisRoot -ProbeTable $debugErrorTable -ProbeTimeoutMilliseconds 100 -TotalBudgetMilliseconds 500).desktop_probe_debug_arg
            $debugUnknown = (Get-DesktopTeardownDiagnosis -UserDataFolder $diagnosisRoot -ProbeTable $debugUnknownTable -ProbeTimeoutMilliseconds 100 -TotalBudgetMilliseconds 0).desktop_probe_debug_arg
            Assert-Condition ([string]$debugTrue -ceq 'true') 'The debug argument probe did not detect the exact injected argument.'
            Assert-Condition ([string]$debugFalse -ceq 'false') 'The debug argument probe accepted a nonmatching argument.'
            Assert-Condition ([string]$debugError -ceq 'error:io') 'The debug argument probe did not preserve its bounded error value.'
            Assert-Condition ([string]$debugUnknown -ceq 'unknown') 'The debug argument probe did not preserve its exhausted-budget value.'
            $debugArgumentRecords = @(
                [ordered]@{ scenario = 'match'; value = [string]$debugTrue },
                [ordered]@{ scenario = 'missing'; value = [string]$debugFalse },
                [ordered]@{ scenario = 'error'; value = [string]$debugError },
                [ordered]@{ scenario = 'budget'; value = [string]$debugUnknown }
            )
            foreach ($record in $debugArgumentRecords) {
                Assert-Condition ([string]$record.value -cmatch '^(?:true|false|unknown|error:[a-z]+)$') 'The debug argument diagnosis escaped its four-value domain.'
            }
            $debugArgumentEvidence = [ordered]@{
                raw_absent = $true
                records = $debugArgumentRecords
            }
            $debugArgumentEvidence.raw_absent = ((@($debugArgumentEvidence) | ConvertTo-Json -Depth 10 -Compress) -notmatch 'DevToolsActivePort|msedgewebview2|--remote-debugging-port|/devtools/browser/|listener_owner_pid|root_pid|browser_pid')
            Assert-Condition $debugArgumentEvidence.raw_absent 'Debug argument diagnosis evidence exposed a raw identity.'
            $null = Get-DesktopTeardownDiagnosisSegment -Diagnosis ([ordered]@{ desktop_probe_debug_arg = [string]$debugTrue })
            $evidence.desktop_debug_arg_diagnosis = $debugArgumentEvidence
            $caseIds.Add('desktop_debug_arg_diagnosis')
            $debugArgument = '--remote-debugging-port=49161'
            $legacyPortAndMarker = Get-DesktopLegacyBrowserArgumentsValue -Mode PortAndMarker -DebugArgument $debugArgument
            $expectedPortAndMarker = '{0} {1}' -f $debugArgument, $script:DesktopSmokeEnvMarkerArgument
            Assert-Condition ($legacyPortAndMarker -ceq $expectedPortAndMarker) 'PortAndMarker legacy browser arguments value mismatch.'
            $evidence.desktop_legacy_env_port_and_marker = [ordered]@{
                mode = 'PortAndMarker'
                contains_port = $legacyPortAndMarker.Contains('--remote-debugging-port')
                contains_marker = $legacyPortAndMarker.Contains($script:DesktopSmokeEnvMarkerArgument)
            }
            $caseIds.Add('legacy_env_port_and_marker')
            $legacyMarkerOnly = Get-DesktopLegacyBrowserArgumentsValue -Mode MarkerOnly -DebugArgument $debugArgument
            Assert-Condition ($legacyMarkerOnly -ceq $script:DesktopSmokeEnvMarkerArgument) 'MarkerOnly legacy browser arguments value mismatch.'
            Assert-Condition (-not $legacyMarkerOnly.Contains('--remote-debugging-port')) 'MarkerOnly must not contain remote-debugging-port.'
            $evidence.desktop_legacy_env_marker_only = [ordered]@{
                mode = 'MarkerOnly'
                contains_port = $legacyMarkerOnly.Contains('--remote-debugging-port')
                contains_marker = $legacyMarkerOnly.Contains($script:DesktopSmokeEnvMarkerArgument)
            }
            Assert-Condition (Test-Throws { Get-DesktopLegacyBrowserArgumentsValue -Mode Legacy -DebugArgument $debugArgument }) 'Unsupported Mode must be rejected by ValidateSet.'
            $caseIds.Add('legacy_env_marker_only')
            $successDiagnosis = [ordered]@{
                desktop_probe_webview_process_present = 'true'
                desktop_probe_debug_arg = 'true'
                desktop_probe_env_channel = 'false'
                desktop_probe_profile_dir = 'true'
            }
            $successLines = [Collections.Generic.List[string]]::new()
            $successEmitter = { param($Line) $successLines.Add($Line) }.GetNewClosure()
            $successLine = Write-DesktopProbeDiagnosticsLine -Diagnosis $successDiagnosis -Emitter $successEmitter
            Assert-Condition ($successLines.Count -eq 1) 'Success diagnosis emission count mismatch.'
            Assert-Condition ($successLines[0] -ceq $successLine) 'Success diagnosis captured line mismatch.'
            Assert-Condition ($successLine.StartsWith('desktop_probe_diagnosis ', [StringComparison]::Ordinal)) 'Success diagnosis line prefix mismatch.'
            Assert-Condition ([string]$successDiagnosis['desktop_probe_debug_arg'] -ceq 'true') 'The success diagnosis did not carry the pass-fail debug argument probe value.'
            $evidence.desktop_probe_diag_success_emission = [ordered]@{
                emitted_count = $successLines.Count
                has_prefix = $successLine.StartsWith('desktop_probe_diagnosis ', [StringComparison]::Ordinal)
            }
            $caseIds.Add('desktop_probe_diag_success_emission')
            $failureDiagnosis = [ordered]@{
                desktop_probe_webview_process_present = 'true'
                desktop_probe_debug_arg = 'false'
                desktop_probe_env_channel = 'true'
                desktop_probe_profile_dir = 'unknown'
            }
            $failureLines = [Collections.Generic.List[string]]::new()
            $failureEmitter = { param($Line) $failureLines.Add($Line) }.GetNewClosure()
            $failureLine = Write-DesktopProbeDiagnosticsLine -Diagnosis $failureDiagnosis -Emitter $failureEmitter
            Assert-Condition ($failureLines.Count -eq 1) 'Failure diagnosis emission count mismatch.'
            Assert-Condition ($failureLines[0] -ceq $failureLine) 'Failure diagnosis captured line mismatch.'
            $rejectsRawIdentity = Test-Throws { Write-DesktopProbeDiagnosticsLine -Diagnosis ([ordered]@{ desktop_probe_debug_arg = '/devtools/browser/x' }) -Emitter { param($Line) } }
            Assert-Condition ($rejectsRawIdentity) 'Diagnosis value outside the four-value domain must be rejected.'
            $evidence.desktop_probe_diag_failure_emission = [ordered]@{
                emitted_count = $failureLines.Count
                rejects_raw_identity = $rejectsRawIdentity
            }
            $caseIds.Add('desktop_probe_diag_failure_emission')
        } else {
            $nodeFixtureRoot = Join-Path $root 'node-toolchains'
            $firstNodeRoot = Join-Path $nodeFixtureRoot 'first'
            $secondNodeRoot = Join-Path $nodeFixtureRoot 'second'
            $invalidFirstNodeRoot = Join-Path $nodeFixtureRoot 'invalid-first'
            $missingAdjacentNodeRoot = Join-Path $nodeFixtureRoot 'missing-adjacent'
            $firstNpmRoot = Join-Path $firstNodeRoot 'node_modules\npm\bin'
            $secondNpmRoot = Join-Path $secondNodeRoot 'node_modules\npm\bin'
            $tarFixtureRoot = Join-Path $root 'tar-toolchains'
            New-Item -ItemType Directory -Path $firstNpmRoot, $secondNpmRoot, $invalidFirstNodeRoot, $missingAdjacentNodeRoot, $tarFixtureRoot | Out-Null
            $firstNode = Join-Path $firstNodeRoot 'node.exe'
            $secondNode = Join-Path $secondNodeRoot 'node.exe'
            $invalidFirstNode = Join-Path $invalidFirstNodeRoot 'node.exe'
            $missingAdjacentNode = Join-Path $missingAdjacentNodeRoot 'node.exe'
            $missingNode = Join-Path $nodeFixtureRoot 'missing\node.exe'
            $firstNpmCli = Join-Path $firstNpmRoot 'npm-cli.js'
            $secondNpmCli = Join-Path $secondNpmRoot 'npm-cli.js'
            $firstTar = Join-Path $tarFixtureRoot 'first-tar.exe'
            $secondTar = Join-Path $tarFixtureRoot 'second-tar.exe'
            $missingTar = Join-Path $tarFixtureRoot 'missing-tar.exe'
            Set-Content -LiteralPath $firstNode, $secondNode, $invalidFirstNode, $missingAdjacentNode, $firstNpmCli, $secondNpmCli, $firstTar, $secondTar -Value 'self-test toolchain' -Encoding ascii -NoNewline

            Assert-Condition (Test-Throws {
                Resolve-NpmPathPrecedenceToolchain -NodeCandidates @() -TarCandidates @([pscustomobject]@{ Source = $firstTar })
            }) 'An empty Node application candidate collection was accepted.'
            $caseIds.Add('node_path_precedence_zero')

            $oneNode = Resolve-NpmPathPrecedenceToolchain -NodeCandidates @([pscustomobject]@{ Source = $firstNode }) -TarCandidates @([pscustomobject]@{ Source = $firstTar })
            Assert-Condition ($oneNode.node_path -ceq $firstNode) 'A single Node application candidate did not remain scalar.'
            Assert-Condition ($oneNode.npm_cli_path -ceq $firstNpmCli) 'A single Node application candidate did not bind its adjacent npm CLI.'
            $caseIds.Add('node_path_precedence_one')

            $multipleNodes = Resolve-NpmPathPrecedenceToolchain -NodeCandidates @(
                [pscustomobject]@{ Source = $firstNode },
                [pscustomobject]@{ Source = $secondNode }
            ) -TarCandidates @([pscustomobject]@{ Source = $firstTar })
            Assert-Condition ($multipleNodes.node_path -ceq $firstNode) 'Multiple Node application candidates did not select the first PATH-precedence Source.'
            Assert-Condition ($multipleNodes.npm_cli_path -ceq $firstNpmCli) 'Multiple Node application candidates did not couple npm to the selected Node.'
            $caseIds.Add('node_path_precedence_multiple')

            Assert-Condition (Test-Throws {
                Resolve-NpmPathPrecedenceToolchain -NodeCandidates @(
                    [pscustomobject]@{ Source = $invalidFirstNode },
                    [pscustomobject]@{ Source = $secondNode }
                ) -TarCandidates @([pscustomobject]@{ Source = $firstTar })
            }) 'A missing npm CLI beside the first Node fell back to a lower valid candidate.'
            $caseIds.Add('node_path_precedence_invalid_first')

            $npmSmokeRoot = Join-Path $root 'npm-complete-smoke'
            New-Item -ItemType Directory -Path $npmSmokeRoot | Out-Null
            $operationOrder = [Collections.Generic.List[string]]::new()
            $tarOperationPaths = [Collections.Generic.List[string]]::new()
            $integrityFixture = 'sha512-YWJjZA=='
            $npmProcessInvoker = {
                param(
                    [string]$Operation,
                    [string]$FilePath,
                    [Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments
                )
                $operationOrder.Add($Operation) | Out-Null
                if ($Operation -cin @('tar_list', 'tar_extract')) {
                    $tarOperationPaths.Add($FilePath) | Out-Null
                }
                switch ($Operation) {
                    'npm_view' {
                        return [pscustomobject]@{ exit_code = 0; stdout = (@{ version = $Version; dist = @{ integrity = $integrityFixture } } | ConvertTo-Json -Compress); stderr = '' }
                    }
                    'npm_pack' {
                        $tarballName = 'winsmux-self-test.tgz'
                        Set-Content -LiteralPath (Join-Path $npmSmokeRoot $tarballName) -Value 'self-test archive' -Encoding ascii -NoNewline
                        return [pscustomobject]@{ exit_code = 0; stdout = (@(@{ filename = $tarballName; integrity = $integrityFixture }) | ConvertTo-Json -Compress); stderr = '' }
                    }
                    'tar_list' {
                        return [pscustomobject]@{ exit_code = 0; stdout = "package/package.json`npackage/index.mjs`npackage/install.ps1`n"; stderr = '' }
                    }
                    'tar_extract' {
                        $packageRoot = Join-Path $npmSmokeRoot 'unpacked\package'
                        New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
                        Set-Content -LiteralPath (Join-Path $packageRoot 'package.json') -Value (@{ name = 'winsmux'; version = $Version; winsmuxReleaseTag = $ReleaseTag } | ConvertTo-Json -Compress) -Encoding UTF8
                        Set-Content -LiteralPath (Join-Path $packageRoot 'index.mjs') -Value 'self-test entry' -Encoding ascii -NoNewline
                        Set-Content -LiteralPath (Join-Path $packageRoot 'install.ps1') -Value 'self-test installer' -Encoding ascii -NoNewline
                        return [pscustomobject]@{ exit_code = 0; stdout = ''; stderr = '' }
                    }
                    'npm_help' {
                        return [pscustomobject]@{
                            exit_code = 0
                            stderr = ''
                            stdout = "  install     Install winsmux`n  update      Update winsmux`n  uninstall   Uninstall winsmux`n  version     Show version`n  help        Show help"
                        }
                    }
                    default { throw "Unexpected npm self-test operation: $Operation" }
                }
            }.GetNewClosure()
            Invoke-NpmSmoke -Root $npmSmokeRoot `
                -NodeCandidates @([pscustomobject]@{ Source = $firstNode }, [pscustomobject]@{ Source = $secondNode }) `
                -TarCandidates @([pscustomobject]@{ Source = $firstTar }, [pscustomobject]@{ Source = $secondTar }) `
                -ProcessInvoker $npmProcessInvoker | Out-Null
            $evidence.npm_complete_toolchain = [ordered]@{
                selected_node_index = 0
                selected_tar_index = 0
                npm_adjacent = [string]::Equals((Join-Path (Split-Path -Parent $firstNode) 'node_modules\npm\bin\npm-cli.js'), $firstNpmCli, [StringComparison]::OrdinalIgnoreCase)
                same_tar_for_list_extract = $tarOperationPaths.Count -eq 2 -and $tarOperationPaths[0] -ceq $firstTar -and $tarOperationPaths[1] -ceq $firstTar
                operation_order = @($operationOrder)
            }
            $caseIds.Add('npm_complete_toolchain_consumed')

            $snapshotRoot = {
                param([string]$Path)
                return [string]::Join('|', @(
                    Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName | ForEach-Object {
                        $relative = [IO.Path]::GetRelativePath($Path, $_.FullName)
                        if ($_.PSIsContainer) { "D:$relative" } else { "F:${relative}:$($_.Length):$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
                    }
                ))
            }.GetNewClosure()
            $incompleteCases = [Collections.Generic.List[object]]::new()
            $invalidDefinitions = @(
                [pscustomobject]@{ name = 'missing_node'; nodes = @(); tars = @([pscustomobject]@{ Source = $firstTar }) },
                [pscustomobject]@{ name = 'invalid_first_node'; nodes = @([pscustomobject]@{ Source = $missingNode }, [pscustomobject]@{ Source = $firstNode }); tars = @([pscustomobject]@{ Source = $firstTar }) },
                [pscustomobject]@{ name = 'missing_adjacent_npm'; nodes = @([pscustomobject]@{ Source = $missingAdjacentNode }); tars = @([pscustomobject]@{ Source = $firstTar }) },
                [pscustomobject]@{ name = 'missing_tar'; nodes = @([pscustomobject]@{ Source = $firstNode }); tars = @() },
                [pscustomobject]@{ name = 'invalid_first_tar'; nodes = @([pscustomobject]@{ Source = $firstNode }); tars = @([pscustomobject]@{ Source = $missingTar }, [pscustomobject]@{ Source = $firstTar }) }
            )
            foreach ($definition in $invalidDefinitions) {
                $caseRoot = Join-Path $root "npm-incomplete-$($definition.name)"
                New-Item -ItemType Directory -Path $caseRoot | Out-Null
                Set-Content -LiteralPath (Join-Path $caseRoot 'sentinel.bin') -Value "sentinel-$($definition.name)" -Encoding ascii -NoNewline
                $before = & $snapshotRoot $caseRoot
                $processOperations = [pscustomobject]@{ count = 0 }
                $rejectProcessInvoker = { $processOperations.count += 1; throw 'incomplete toolchain reached process execution' }.GetNewClosure()
                $rejected = Test-Throws {
                    Invoke-NpmSmoke -Root $caseRoot -NodeCandidates @($definition.nodes) -TarCandidates @($definition.tars) -ProcessInvoker $rejectProcessInvoker
                }
                $after = & $snapshotRoot $caseRoot
                Assert-Condition $rejected "Incomplete npm toolchain case '$($definition.name)' was accepted."
                Assert-Condition ($processOperations.count -eq 0) "Incomplete npm toolchain case '$($definition.name)' reached a process operation."
                Assert-Condition ($before -ceq $after) "Incomplete npm toolchain case '$($definition.name)' changed owned-root bytes or entries."
                $incompleteCases.Add([ordered]@{
                    name = [string]$definition.name
                    root_unchanged = $before -ceq $after
                    process_operations = [int]$processOperations.count
                })
            }
            $evidence.npm_incomplete_toolchain = [ordered]@{ cases = @($incompleteCases) }
            $caseIds.Add('npm_incomplete_toolchain_no_effects')

            Assert-SafeNpmArchiveEntries -Entries @('package/package.json', 'package/index.mjs', 'package/install.ps1')
            Assert-Condition (Test-Throws { Assert-SafeNpmArchiveEntries -Entries @('package/../outside.txt') }) 'npm archive traversal was accepted.'
            $metadata = [pscustomobject]@{
                version = $Version
                dist = [pscustomobject]@{ integrity = 'sha512-YWJjZA==' }
            }
            Assert-NpmMetadata -Metadata $metadata -ExpectedVersion $Version
            Assert-NpmHelpResult -Result ([pscustomobject]@{
                exit_code = 0
                stderr = ''
                stdout = [string]::Join([Environment]::NewLine, @(
                    '  install     Install winsmux',
                    '  update      Update winsmux',
                    '  uninstall   Uninstall winsmux',
                    '  version     Show version',
                    '  help        Show help'
                ))
            })
            $caseIds.Add('valid')

            Assert-Condition (Test-Throws { Assert-NpmMetadata -Metadata ([pscustomobject]@{ version = $Version }) -ExpectedVersion $Version }) 'Missing npm integrity was accepted.'
            $caseIds.Add('missing_integrity')

            Assert-Condition (Test-Throws { Assert-NpmMetadata -Metadata ([pscustomobject]@{ version = '0.0.0'; dist = [pscustomobject]@{ integrity = 'sha512-YWJjZA==' } }) -ExpectedVersion $Version }) 'npm version mismatch was accepted.'
            $caseIds.Add('version_mismatch')

            Assert-Condition (Test-Throws { Assert-NpmHelpResult -Result ([pscustomobject]@{ exit_code = 1; stderr = 'failed'; stdout = '' }) }) 'npm help failure was accepted.'
            $caseIds.Add('help_failure')
        }
    } finally {
        if ($Surface -eq 'Desktop') {
            if (Test-Path -LiteralPath $installRoot) {
                Remove-Item -LiteralPath $installRoot -Recurse -Force
            }
            $selfTestCleanup = New-DesktopLifecycleContext -OwnedRoot $root -InstallRoot $installRoot -ExpectedVersion $Version
            $script:DesktopLifecycle = $selfTestCleanup
            Start-DesktopLifecycle -Context $selfTestCleanup -PreflightState (New-EmptyDesktopProtectedState)
            Invoke-DesktopCleanup -Context $selfTestCleanup -Environment @{} | Out-Null
        } else {
            Remove-OwnedRoot -Root $root
        }
    }
    Assert-Condition (-not (Test-Path -LiteralPath $root)) 'Self-test temporary root remained.'
    if ($Surface -ne 'Desktop') {
        $caseIds.Add('temp_cleanup')
    }
    if ($Surface -eq 'Npm') {
        $pwshPath = Join-Path $PSHOME 'pwsh.exe'
        Assert-Condition (Test-Path -LiteralPath $pwshPath -PathType Leaf) 'PowerShell self-test child executable was not found.'
        $rawChildMarker = 'T826_NPM_DEFAULT_CHILD_RAW'
        $defaultResult = Invoke-NpmProcessOperation -Operation 'npm_view' -FilePath $pwshPath -ProcessArguments @(
            '-NoProfile',
            '-Command',
            "[Console]::Out.Write('$rawChildMarker'); exit 0"
        ) -Environment @{}
        Assert-Condition ($defaultResult.exit_code -eq 0) 'Default npm dispatcher child did not exit successfully.'
        Assert-Condition ([string]$defaultResult.stdout -ceq $rawChildMarker) 'Default npm dispatcher child output was not captured exactly.'
        Assert-Condition ([string]::IsNullOrEmpty([string]$defaultResult.stderr)) 'Default npm dispatcher child wrote unexpected stderr.'
        $defaultScopeEvidence = [ordered]@{
            child_started = $true
            child_exit_code = [int]$defaultResult.exit_code
            default_dispatcher = $true
            operation = 'npm_view'
            raw_output_excluded = $true
            sibling_operations = @('npm_view', 'npm_pack', 'tar_list', 'tar_extract', 'npm_help')
        }
        Assert-Condition ((@($defaultScopeEvidence) | ConvertTo-Json -Depth 10 -Compress) -notmatch [regex]::Escape($rawChildMarker)) 'Default npm dispatcher evidence exposed raw child output.'
        $evidence.npm_default_real_scope = $defaultScopeEvidence
        $caseIds.Add('npm_default_real_scope')
    }
    return [ordered]@{
        ok = $true
        surface = $Surface
        case_ids = @($caseIds)
        evidence = $evidence
    }
}

$Version = Resolve-ReleaseCoordinates -Surface $Surface -Version $Version -ReleaseTag $ReleaseTag -Repository $Repository

if ($SelfTest) {
    $result = if ($DesktopNativeLifecycle) { Invoke-DesktopNativeLifecycleSelfTest } else { Invoke-SelfTest }
    if ($Json) {
        $result | ConvertTo-Json -Depth 10 -Compress
    } else {
        [pscustomobject]$result
    }
    exit 0
}

if ($DesktopNativeLifecycle) {
    $nativeResult = Invoke-DesktopNativeLifecycle
    if ($Json) { $nativeResult | ConvertTo-Json -Depth 64 -Compress } else { [pscustomobject]$nativeResult }
    if ($nativeResult.outcome -ceq 'passed' -or ($nativeResult.schema -ceq 'winsmux-desktop-native-journey-ci/v1' -and $nativeResult.outcome -ceq 'journey_passed')) { exit 0 }
    exit 1
}

$ownedRoot = New-OwnedRoot
$operationError = $null
$cleanupError = $null
$surfaceResult = $null
try {
    switch ($Surface) {
        'Core' {
            $surfaceResult = Invoke-CoreSmoke -Root $ownedRoot
        }
        'Desktop' {
            $surfaceResult = Invoke-DesktopSmoke -Root $ownedRoot
        }
        'Npm' {
            $surfaceResult = Invoke-NpmSmoke -Root $ownedRoot
        }
    }
} catch {
    $operationError = $_
} finally {
    try {
        if ($Surface -eq 'Desktop') {
            Assert-Condition ($null -ne $script:DesktopLifecycle) 'Desktop lifecycle context was not created.'
            Assert-Condition ([string]$script:DesktopLifecycle.phase -cin @('clean', 'preserve')) "Desktop lifecycle exited in non-terminal phase '$($script:DesktopLifecycle.phase)'."
        } else {
            Remove-OwnedRoot -Root $ownedRoot
        }
    } catch {
        $cleanupError = $_
    }
}

if ($Surface -ceq 'Desktop' -and $Json -and ($null -ne $operationError -or $null -ne $cleanupError)) {
    $exception = if ($null -ne $operationError) { $operationError.Exception } else { $null }
    $phase = if ($null -ne $script:DesktopLifecycle) { [string]$script:DesktopLifecycle.phase } else { 'not_created' }
    $cleanupException = if ($null -ne $cleanupError) { $cleanupError.Exception } else { $null }
    New-DesktopFailureReceipt -Failure $exception -CleanupFailure $cleanupException -Version $Version -ReleaseTag $ReleaseTag -Stage $script:DesktopFailureStage -CleanupStage $script:DesktopCleanupStage -Phase $phase | ConvertTo-Json -Depth 8 -Compress
    exit 1
}
if ($null -ne $operationError) {
    if ($null -ne $cleanupError) {
        throw "Public $Surface smoke failed: $($operationError.Exception.Message); cleanup also failed: $($cleanupError.Exception.Message)"
    }
    throw $operationError
}
if ($null -ne $cleanupError) {
    throw $cleanupError
}

$result = [ordered]@{
    ok = $true
    surface = $Surface
    version = $Version
    release_tag = $ReleaseTag
    repository = $Repository
    evidence = $surfaceResult
    attempts = $script:RetryCount
    retry_delay_seconds = $script:RetryDelaySeconds
    cleanup = 'clean'
}
if ($Surface -eq 'Desktop' -and $null -ne $script:DesktopRouterInventory) {
    $result.router_inventory = $script:DesktopRouterInventory
}
if ($Surface -ceq 'Desktop' -and $null -ne $script:DesktopInstalledInventory) {
    $result.installed_inventory = $script:DesktopInstalledInventory
    $result.desktop_runtime = $script:DesktopRuntimeReceipt
    Assert-DesktopInstallReceipt -Receipt $result -Version $Version -InstallerSha256 $surfaceResult.sha256 -SourceCommit $script:DesktopInstalledInventory.source_commit -InventorySha256 $script:DesktopInstalledInventory.inventory_sha256 | Out-Null
}
if ($Json) {
    $result | ConvertTo-Json -Depth 10 -Compress
} else {
    [pscustomobject]$result
}
