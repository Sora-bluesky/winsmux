[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Installer,
    [Parameter(Mandatory)][ValidateSet('en-root', 'ja-root')][string]$ProfileName,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or -not $env:RUNNER_TEMP) {
    throw 'This procedure requires an owned disposable GitHub Windows runner.'
}
$expectedHash = 'c1f3ea807a035978a78ec12df3bb70bbf1e869cf83c7563715821df0887798e2'
$inputFile = Get-Item -LiteralPath $Installer
if ($inputFile.Length -ne 9920209 -or (Get-FileHash -LiteralPath $inputFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
    throw 'The fixed original installer identity does not match.'
}
$runnerRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$localRoot = [IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')
$ownedRoot = [IO.Path]::GetFullPath((Join-Path $localRoot "winsmux-task880-legacy/$ProfileName"))
$installRoot = Join-Path $ownedRoot $(if ($ProfileName -eq 'ja-root') { '日本語 & winsmux' } else { 'winsmux baseline' })
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $ownedRoot.StartsWith($localRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Install fixture is outside current-user LocalApplicationData.' }
if (-not $outputRoot.StartsWith($runnerRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence is outside RUNNER_TEMP.' }
foreach ($checkedPath in @($ownedRoot, $outputRoot)) {
    if (Test-Path -LiteralPath $checkedPath) { throw 'Run-owned output must be absent before capture.' }
}
$slots = @(
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
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class Task880RawRegistry {
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
    private static extern int RegOpenKeyExW(IntPtr key, string subkey, uint options, uint access, out IntPtr result);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
    private static extern int RegQueryValueExW(IntPtr key, string name, IntPtr reserved, out uint type, byte[] data, ref uint bytes);
    [DllImport("advapi32.dll")] private static extern int RegCloseKey(IntPtr key);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool GetVolumePathNameW(string path, StringBuilder mount, uint size);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool GetVolumeNameForVolumeMountPointW(string mount, StringBuilder name, uint size);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool GetTokenInformation(IntPtr token, int info, IntPtr buffer, uint size, out uint returned);
    [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
    public sealed class Value { public uint type; public byte[] data; }
    public sealed class TokenFacts { public int elevation; public int elevation_type; public uint integrity_rid; public bool linked_token_available; public int linked_token_error; }
    public static string Volume(string path) {
        var mount=new StringBuilder(32768); var name=new StringBuilder(64);
        if(!GetVolumePathNameW(path,mount,(uint)mount.Capacity) || !GetVolumeNameForVolumeMountPointW(mount.ToString(),name,(uint)name.Capacity))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return name.ToString();
    }
    private static int TokenInt(IntPtr token, int info) {
        IntPtr value=Marshal.AllocHGlobal(4);
        try { uint size; if(!GetTokenInformation(token,info,value,4,out size) || size!=4) throw new Win32Exception(Marshal.GetLastWin32Error()); return Marshal.ReadInt32(value); }
        finally { Marshal.FreeHGlobal(value); }
    }
    public static TokenFacts Token() {
        IntPtr token;
        if(!OpenProcessToken(GetCurrentProcess(),0x0008,out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            var facts=new TokenFacts { elevation=TokenInt(token,20), elevation_type=TokenInt(token,18) };
            uint size; GetTokenInformation(token,25,IntPtr.Zero,0,out size);
            if(size==0) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr label=Marshal.AllocHGlobal((int)size);
            try {
                if(!GetTokenInformation(token,25,label,size,out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
                IntPtr sid=Marshal.ReadIntPtr(label); byte count=Marshal.ReadByte(GetSidSubAuthorityCount(sid));
                if(count==0) throw new InvalidOperationException("Integrity SID has no RID");
                facts.integrity_rid=unchecked((uint)Marshal.ReadInt32(GetSidSubAuthority(sid,(uint)(count-1))));
            } finally { Marshal.FreeHGlobal(label); }
            IntPtr linked=Marshal.AllocHGlobal(IntPtr.Size);
            try {
                if(GetTokenInformation(token,19,linked,(uint)IntPtr.Size,out size)) { facts.linked_token_available=true; CloseHandle(Marshal.ReadIntPtr(linked)); }
                else facts.linked_token_error=Marshal.GetLastWin32Error();
            } finally { Marshal.FreeHGlobal(linked); }
            return facts;
        } finally { CloseHandle(token); }
    }
    public static Value Read(string key, string name) {
        IntPtr handle;
        int status=RegOpenKeyExW(new IntPtr(unchecked((int)0x80000001)),key,0,0x0001|0x0100,out handle);
        if(status==2) return null;
        if(status!=0) throw new Win32Exception(status);
        try {
            uint kind, size=0;
            status=RegQueryValueExW(handle,name,IntPtr.Zero,out kind,null,ref size);
            if(status==2) return null;
            if(status!=0) throw new Win32Exception(status);
            byte[] data=new byte[size];
            status=RegQueryValueExW(handle,name,IntPtr.Zero,out kind,data,ref size);
            if(status!=0 || size!=data.Length) throw new InvalidOperationException("Registry value changed during capture: "+status);
            return new Value { type=kind, data=data };
        } finally { RegCloseKey(handle); }
    }
}
'@
function Read-Registration {
    $result = [Collections.Generic.List[object]]::new()
    foreach ($slot in $slots) {
        $value = [Task880RawRegistry]::Read($slot[0], $slot[1])
        $result.Add($(if ($null -eq $value) { $null } else { [ordered]@{ type = $value.type; data = @($value.data | ForEach-Object { [int]$_ }) } }))
    }
    return ,$result.ToArray()
}
$linkPaths = [ordered]@{
    desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'winsmux.lnk'
    start_menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'winsmux.lnk'
}
$before = Read-Registration
if (@($before | Where-Object { $null -ne $_ }).Count -ne 0) { throw 'A pre-existing product registration prevents this fresh capture.' }
foreach ($linkPath in $linkPaths.Values) { if (Test-Path -LiteralPath $linkPath) { throw 'A pre-existing shortcut prevents this fresh capture.' } }
if (@(Get-Process -Name 'winsmux*' -ErrorAction SilentlyContinue).Count) { throw 'A winsmux process is already running.' }
New-Item -ItemType Directory -Path $ownedRoot, $outputRoot | Out-Null
$project = Join-Path $ownedRoot 'user-project'
New-Item -ItemType Directory -Path $project | Out-Null
$sentinel = Join-Path $project 'keep.txt'
[IO.File]::WriteAllText($sentinel, 'TASK880 protected project bytes', [Text.UTF8Encoding]::new($false))
$sentinelHash = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash.ToLowerInvariant()
$receipt = [ordered]@{
    schema = 'winsmux-task880-legacy-install-capture/v1'; outcome = 'pending'; failure = $null
    original_installer = [ordered]@{ bytes = 9920209; sha256 = $expectedHash }
    profile_name = $ProfileName; root = $installRoot; install_exit_code = $null
    arguments = @('/S', "/D=$installRoot"); installed_inventory_complete = $false
    files = @(); registration = @(); shortcuts = @(); language = $null
    protected_project_before_sha256 = $sentinelHash; protected_project_after_sha256 = $null
    environment = [ordered]@{
        os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powershell = $PSVersionTable.PSVersion.ToString(); image_os = $env:ImageOS; image_version = $env:ImageVersion
        run_id = $env:GITHUB_RUN_ID; run_attempt = $env:GITHUB_RUN_ATTEMPT
        actor_sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        process_token = [Task880RawRegistry]::Token()
        owned_volume = [Task880RawRegistry]::Volume($ownedRoot)
    }
}
try {
    foreach ($linkPath in $linkPaths.Values) {
        $linkVolume = [Task880RawRegistry]::Volume([IO.Path]::GetDirectoryName($linkPath))
        if ($linkVolume -ne $receipt.environment.owned_volume) { throw 'Baseline root and owned shortcuts must use the same measured volume.' }
    }
    $start = [Diagnostics.ProcessStartInfo]::new($inputFile.FullName)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    # NSIS consumes /D as the final unquoted command-line suffix, including spaces.
    # ProcessStartInfo does not invoke a shell, so the ampersand remains path data.
    if ($installRoot.Contains('"') -or $installRoot.Contains("`r") -or $installRoot.Contains("`n")) { throw 'Invalid literal NSIS destination.' }
    $start.Arguments = "/S /D=$installRoot"
    $process = [Diagnostics.Process]::Start($start)
    $process.WaitForExit()
    $receipt.install_exit_code = $process.ExitCode
    if ($process.ExitCode -ne 0) { throw 'Original installer did not complete successfully.' }
    $process.Dispose()
    $guiPath = Join-Path $installRoot 'winsmux-app.exe'
    foreach ($required in @($guiPath, (Join-Path $installRoot 'uninstall.exe'))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw 'The installer did not create a required member.' }
    }
    $files = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $installRoot -Recurse -Force) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected reparse member in installed tree.' }
        if ($file.PSIsContainer) { continue }
        $relative = [IO.Path]::GetRelativePath($installRoot, $file.FullName).Replace('\', '/')
        $role = switch -Regex ($relative) {
            '^winsmux-app\.exe$' { 'gui'; break }
            '^winsmux\.exe$' { 'cli'; break }
            '^winsmux-workspace-mcp\.exe$' { 'mcp'; break }
            '^uninstall\.exe$' { 'uninstaller'; break }
            '^licenses/' { 'license'; break }
            default { 'auxiliary' }
        }
        $files.Add([ordered]@{ role = $role; path = $relative; bytes = $file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
    }
    $receipt.files = @($files | Sort-Object path)
    $receipt.registration = Read-Registration
    $languageValue = $receipt.registration[1]
    if ($null -eq $languageValue -or $languageValue.type -ne 1) { throw 'Installer language was not recorded as REG_SZ.' }
    $language = [Text.Encoding]::Unicode.GetString([byte[]]$languageValue.data).TrimEnd([char]0)
    if ($language -notin @('1033', '1041')) { throw 'Observed installer language is outside the fixed profile.' }
    $receipt.language = [int]$language
    $shell = New-Object -ComObject WScript.Shell
    $shellApp = New-Object -ComObject Shell.Application
    foreach ($kind in $linkPaths.Keys) {
        $linkPath = $linkPaths[$kind]
        if (-not (Test-Path -LiteralPath $linkPath -PathType Leaf)) { continue }
        $link = $shell.CreateShortcut($linkPath)
        $target = [IO.Path]::GetFullPath($link.TargetPath)
        if (-not $target.Equals($guiPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Shortcut target is not the observed installed GUI.' }
        $item = $shellApp.NameSpace([IO.Path]::GetDirectoryName($linkPath)).ParseName([IO.Path]::GetFileName($linkPath))
        $aumid = [string]$item.ExtendedProperty('System.AppUserModel.ID')
        if ($aumid -ne 'io.github.sora-bluesky.winsmux') { throw 'Shortcut AUMID does not match this product.' }
        $receipt.shortcuts += [ordered]@{ kind = $kind; bytes = (Get-Item -LiteralPath $linkPath).Length; sha256 = (Get-FileHash -LiteralPath $linkPath -Algorithm SHA256).Hash.ToLowerInvariant(); target = $target; aumid = $aumid }
    }
    $receipt.protected_project_after_sha256 = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($receipt.protected_project_after_sha256 -ne $sentinelHash) { throw 'The project sentinel changed.' }
    $receipt.installed_inventory_complete = $true
    $receipt.outcome = 'passed'
} catch {
    $receipt.outcome = 'failed'
    $receipt.failure = $_.Exception.Message
    throw
} finally {
    [IO.File]::WriteAllText((Join-Path $outputRoot 'capture.json'), ($receipt | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}
