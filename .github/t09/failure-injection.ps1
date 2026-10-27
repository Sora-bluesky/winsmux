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

function Get-T09ComparableSddl([string]$Sddl) {
    $match = [regex]::Match($Sddl, '^(?<head>.*?D:)(?<flags>[A-Z]*)(?<aces>\(.*)$')
    if (-not $match.Success) { return $Sddl }
    return $match.Groups['head'].Value + ($match.Groups['flags'].Value -creplace 'AI|AR', '') + $match.Groups['aces'].Value
}

function Disable-T09ExecuteDeny($Arm) {
    # The propagating setter restores the auto-inherited flag and strips the deny from
    # children created while armed.
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetSecurityDescriptorSddlForm($Arm.original_sddl, [Security.AccessControl.AccessControlSections]::Access)
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Arm.directory), $acl)
    $restored = (Get-Acl -LiteralPath $Arm.directory).Sddl
    # That setter also sets the DACL's AI flag, which a runner directory may not have had,
    # so the ACEs and the protected flag are compared and AI/AR are not.
    $equivalent = (Get-T09ComparableSddl $restored) -ceq (Get-T09ComparableSddl $Arm.original_sddl)
    return [ordered]@{
        original_sddl = $Arm.original_sddl; armed_sddl = $Arm.armed_sddl; restored_sddl = $restored
        exact_equal = ($restored -ceq $Arm.original_sddl); equal_ignoring_auto_inherit_flags = $equivalent; restored = $equivalent
    }
}

$script:T09IfeoRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'

function Export-T09Key([string]$Path, [string]$File) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $reg = Join-Path ([Environment]::SystemDirectory) 'reg.exe'
    $text = (& $reg export ($Path -replace '^(HK[A-Z]+):\\', '$1\') $File /y 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "reg export of $Path failed with ${LASTEXITCODE}: $text" }
    return (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-T09KeyValues([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $key = Get-Item -LiteralPath $Path
    $rows = [ordered]@{}
    foreach ($name in $key.GetValueNames()) {
        $rows[$name] = [ordered]@{ kind = [string]$key.GetValueKind($name); value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    }
    return $rows
}

# LaunchPublished: an Image File Execution Options filter scoped to exactly one full image
# path. Windows keys IFEO by the image file name, and the installer's stage copy carries the
# same winsmux.exe name at its own full path, so a bare Debugger would also stop the stage
# readback. UseFilter=1 plus a subkey whose FilterFullPath is the published path redirects only
# that path to a debugger that exits non-zero immediately; the staged winsmux.exe at a
# different full path keeps running. Unlike a Software Restriction Policy path rule, which the
# hosted runner does not enforce (run 39354125187 armed the rule yet the published image still
# ran), the loader applies IFEO unconditionally. A winsmux.exe IFEO key the runner already
# carries is refused after being exported, never modified. The $IfeoRoot parameter lets the
# arm and disarm logic run against an HKCU scratch key off the runner.
function Enable-T09ImageExecutionFilter {
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [string]$IfeoRoot = $script:T09IfeoRoot,
        [string]$Debugger = ((Join-Path ([Environment]::SystemDirectory) 'cmd.exe') + ' /d /c exit 87'),
        [int]$ExpectedExit = 87
    )
    $fullPath = [IO.Path]::GetFullPath($ImagePath)
    $imageName = [IO.Path]::GetFileName($fullPath)
    $imageKey = Join-Path $IfeoRoot $imageName
    $arm = [pscustomobject]@{
        kind = 'ifeo-filter'; image_path = $fullPath; image_name = $imageName; ifeo_root = $IfeoRoot
        image_key = $imageKey; filter_key = $null; debugger = $Debugger; expected_exit = $ExpectedExit
        evidence_directory = $EvidenceDirectory; image_key_existed = (Test-Path -LiteralPath $imageKey)
        before_export_sha256 = $null; refused = $null; created_keys = @(); armed_values = $null; armed_export_sha256 = $null
    }
    if ($arm.image_key_existed) {
        $arm.before_export_sha256 = Export-T09Key $imageKey (Join-Path $EvidenceDirectory 'ifeo-before.reg')
        $arm.refused = "An Image File Execution Options key for $imageName already exists: $imageKey"
        return $arm
    }
    $parent = Split-Path -Path $imageKey -Parent
    if (-not (Test-Path -LiteralPath $parent)) { throw "The Image File Execution Options root is absent: $parent" }
    # No base-key Debugger: unmatched full paths (the stage copy's winsmux.exe) stay unaffected.
    [void](New-Item -Path $imageKey); $arm.created_keys += $imageKey
    Set-ItemProperty -LiteralPath $imageKey -Name 'UseFilter' -Value 1 -Type DWord
    $arm.filter_key = Join-Path $imageKey ('{' + [Guid]::NewGuid().ToString() + '}')
    [void](New-Item -Path $arm.filter_key); $arm.created_keys += $arm.filter_key
    Set-ItemProperty -LiteralPath $arm.filter_key -Name 'FilterFullPath' -Value $fullPath -Type String
    Set-ItemProperty -LiteralPath $arm.filter_key -Name 'Debugger' -Value $Debugger -Type String
    $arm.armed_values = [ordered]@{ image = Get-T09KeyValues $imageKey; filter = Get-T09KeyValues $arm.filter_key }
    $arm.armed_export_sha256 = Export-T09Key $imageKey (Join-Path $EvidenceDirectory 'ifeo-armed.reg')
    return $arm
}

function Disable-T09ImageExecutionFilter($Arm) {
    if ($Arm.image_key_existed) {
        # Nothing was created; the pre-existing key is proven untouched by re-export.
        $afterSha = Export-T09Key $Arm.image_key (Join-Path $Arm.evidence_directory 'ifeo-after.reg')
        return [ordered]@{
            image_key_existed = $true; image_key_present_after = (Test-Path -LiteralPath $Arm.image_key)
            before_export_sha256 = $Arm.before_export_sha256; after_export_sha256 = $afterSha
            values_after = Get-T09KeyValues $Arm.image_key
            restored = ($null -ne $afterSha -and $afterSha -ceq $Arm.before_export_sha256)
        }
    }
    $created = @($Arm.created_keys)
    [array]::Reverse($created)
    foreach ($key in $created) { if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force } }
    $present = (Test-Path -LiteralPath $Arm.image_key)
    $afterSha = Export-T09Key $Arm.image_key (Join-Path $Arm.evidence_directory 'ifeo-after.reg')
    return [ordered]@{
        image_key_existed = $false; image_key_present_after = $present
        before_export_sha256 = $Arm.before_export_sha256; after_export_sha256 = $afterSha
        values_after = Get-T09KeyValues $Arm.image_key; restored = (-not $present)
    }
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
