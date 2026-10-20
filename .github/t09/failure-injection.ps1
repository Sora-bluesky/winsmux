Set-StrictMode -Version 3.0

if (-not ('T09.Acl' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace T09 {
public static class Acl {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetFileSecurityW(string name, uint info, byte[] descriptor);
    // SetFileSecurity writes the directory's own descriptor and, unlike SetNamedSecurityInfo,
    // does not propagate inheritable ACEs to children that already exist.
    public static void SetDacl(string path, byte[] descriptor) {
        if (!SetFileSecurityW(path, 4u, descriptor)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
}
'@
}

# Starts an image and reports whether the OS let it run, without throwing on a refused start.
function Invoke-T09Launch([string]$Path, [string[]]$Arguments = @('-V'), [hashtable]$Environment = @{}) {
    $info = [Diagnostics.ProcessStartInfo]::new($Path)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($key in $Environment.Keys) { $info.Environment[$key] = [string]$Environment[$key] }
    try { $process = [Diagnostics.Process]::Start($info) }
    catch {
        $cause = if ($_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception }
        return [ordered]@{ path = $Path; started = $false; exit = $null; stdout = $null; error = $cause.Message; hresult = $cause.HResult }
    }
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill($true); $process.WaitForExit() }
        return [ordered]@{ path = $Path; started = $true; exit = $process.ExitCode; stdout = $stdout.GetAwaiter().GetResult().Trim(); error = $stderr.GetAwaiter().GetResult().Trim(); hresult = $null }
    } finally { $process.Dispose() }
}

# LaunchStage: an inherit-only deny FILE_EXECUTE ACE on the install directory. Files created
# under it afterwards (the installer's stage) cannot be mapped for execution; the installed
# old image predates the ACE and keeps its own descriptor.
function Enable-T09ExecuteDeny([string]$Directory) {
    $original = (Get-Acl -LiteralPath $Directory).Sddl
    $sd = [Security.AccessControl.RawSecurityDescriptor]::new($original)
    $everyone = [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::WorldSid, $null)
    $flags = [Security.AccessControl.AceFlags]::ObjectInherit -bor [Security.AccessControl.AceFlags]::ContainerInherit -bor [Security.AccessControl.AceFlags]::InheritOnly
    $ace = [Security.AccessControl.CommonAce]::new($flags, [Security.AccessControl.AceQualifier]::AccessDenied, 0x20, $everyone, $false, $null)
    $sd.DiscretionaryAcl.InsertAce(0, $ace)
    $bytes = [byte[]]::new($sd.BinaryLength)
    $sd.GetBinaryForm($bytes, 0)
    [T09.Acl]::SetDacl($Directory, $bytes)
    return [pscustomobject]@{ kind = 'execute-deny-ace'; directory = $Directory; original_sddl = $original; armed_sddl = (Get-Acl -LiteralPath $Directory).Sddl }
}

function Disable-T09ExecuteDeny($Arm) {
    # The propagating setter restores the auto-inherited flag and strips the deny from
    # children created while armed.
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetSecurityDescriptorSddlForm($Arm.original_sddl, [Security.AccessControl.AccessControlSections]::Access)
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Arm.directory), $acl)
    return ((Get-Acl -LiteralPath $Arm.directory).Sddl -ceq $Arm.original_sddl)
}

$script:T09SaferRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'

# LaunchPublished: a Software Restriction Policy path rule that disallows exactly one image
# path. The installer's stage path differs, so only the published image is refused.
function Enable-T09PathRule([string]$ImagePath) {
    if (Test-Path -LiteralPath $script:T09SaferRoot) { throw 'A Software Restriction Policy already exists; the probe does not overwrite it.' }
    $guid = '{' + [Guid]::NewGuid().ToString() + '}'
    $rule = Join-Path $script:T09SaferRoot ('0\Paths\' + $guid)
    [void](New-Item -Path $rule -Force)
    Set-ItemProperty -LiteralPath $script:T09SaferRoot -Name DefaultLevel -Value 0x40000 -Type DWord
    Set-ItemProperty -LiteralPath $script:T09SaferRoot -Name TransparentEnabled -Value 1 -Type DWord
    Set-ItemProperty -LiteralPath $script:T09SaferRoot -Name PolicyScope -Value 0 -Type DWord
    Set-ItemProperty -LiteralPath $script:T09SaferRoot -Name AuthenticodeEnabled -Value 0 -Type DWord
    Set-ItemProperty -LiteralPath $script:T09SaferRoot -Name ExecutableTypes -Value @('EXE') -Type MultiString
    Set-ItemProperty -LiteralPath $rule -Name ItemData -Value $ImagePath -Type String
    Set-ItemProperty -LiteralPath $rule -Name SaferFlags -Value 0 -Type DWord
    Set-ItemProperty -LiteralPath $rule -Name Description -Value 't09 launch-failure injection' -Type String
    return [pscustomobject]@{ kind = 'srp-path-rule'; image_path = $ImagePath; rule_key = $rule }
}

function Disable-T09PathRule($Arm) {
    Remove-Item -LiteralPath $script:T09SaferRoot -Recurse -Force
    return -not (Test-Path -LiteralPath $script:T09SaferRoot)
}

# Capacity: a fresh NTFS volume on an owned VHDX, so the profile's free space can be driven
# below what the update needs without touching the runner's system volume.
function New-T09Volume([string]$Root, [int]$MiB) {
    if (Test-Path -LiteralPath $Root) { throw "Volume root must be fresh: $Root" }
    [void][IO.Directory]::CreateDirectory($Root)
    $image = Join-Path $Root 't09-capacity.vhdx'
    Invoke-T09DiskPart $Root 'create' @("create vdisk file=""$image"" maximum=$MiB type=expandable", "select vdisk file=""$image""", 'attach vdisk')
    $disk = Get-DiskImage -ImagePath $image | Get-Disk
    if ($disk.IsBoot -or $disk.IsSystem) { throw 'Owned VHD resolved to a boot or system disk.' }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    [void](Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel 't09cap' -Confirm:$false -Force)
    $letter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber).DriveLetter
    if ([string]$letter -notmatch '^[A-Z]$') { throw 'Owned VHD volume has no drive letter.' }
    return [pscustomobject]@{ kind = 'owned-vhd'; image = $image; root = "${letter}:\"; disk_number = $disk.Number; mib = $MiB; filler = $null }
}

function Invoke-T09DiskPart([string]$Root, [string]$Name, [string[]]$Commands) {
    $script = Join-Path $Root "$Name.diskpart.txt"
    [IO.File]::WriteAllText($script, (($Commands + 'exit') -join "`r`n") + "`r`n", [Text.ASCIIEncoding]::new())
    $text = (& (Join-Path ([Environment]::SystemDirectory) 'diskpart.exe') /s $script | Out-String)
    [IO.File]::WriteAllText((Join-Path $Root "$Name.diskpart.out.txt"), $text, [Text.UTF8Encoding]::new($false))
    if ($LASTEXITCODE -ne 0) { throw "diskpart $Name failed with $LASTEXITCODE." }
}

# Allocates all but a few MiB of the volume to one owned file (SetLength allocates clusters).
function Set-T09Shortage($Volume, [long]$RequiredBytes) {
    $before = [IO.DriveInfo]::new($Volume.root).AvailableFreeSpace
    $path = Join-Path $Volume.root ('t09-filler-' + [Guid]::NewGuid().ToString('N') + '.bin')
    foreach ($leave in @(4MB, 8MB, 16MB)) {
        try {
            $stream = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try { $stream.SetLength($before - $leave); $stream.Flush($true) } finally { $stream.Dispose() }
            break
        } catch { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
    }
    if (-not [IO.File]::Exists($path)) { throw 'Could not allocate the capacity filler.' }
    $Volume.filler = $path
    $after = [IO.DriveInfo]::new($Volume.root).AvailableFreeSpace
    return [ordered]@{ free_before = $before; free_after = $after; filler_bytes = (Get-Item -LiteralPath $path).Length; required_lower_bound = $RequiredBytes; armed = ($after -lt $RequiredBytes) }
}

function Clear-T09Shortage($Volume) {
    if ($Volume.filler -and [IO.File]::Exists($Volume.filler)) { [IO.File]::Delete($Volume.filler) }
    return [IO.DriveInfo]::new($Volume.root).AvailableFreeSpace
}

function Remove-T09Volume($Volume) {
    Invoke-T09DiskPart ([IO.Path]::GetDirectoryName($Volume.image)) 'detach' @("select vdisk file=""$($Volume.image)""", 'detach vdisk')
}
