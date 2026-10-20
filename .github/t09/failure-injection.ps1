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

$script:T09SaferRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'
$script:T09SaferPolicy = [ordered]@{
    DefaultLevel = @(0x40000, 'DWord'); TransparentEnabled = @(1, 'DWord'); PolicyScope = @(0, 'DWord')
    AuthenticodeEnabled = @(0, 'DWord'); ExecutableTypes = @([string[]]@('EXE'), 'MultiString')
}

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

function Get-T09PathRules([string]$Root) {
    $rules = [Collections.Generic.List[string]]::new()
    foreach ($level in @(Get-ChildItem -LiteralPath $Root)) {
        $paths = Join-Path $Root ($level.PSChildName + '\Paths')
        if (Test-Path -LiteralPath $paths) { foreach ($rule in @(Get-ChildItem -LiteralPath $paths)) { $rules.Add($level.PSChildName + '\Paths\' + $rule.PSChildName) } }
    }
    return @($rules)
}

# LaunchPublished: a Software Restriction Policy path rule that disallows exactly one image
# path. The installer's stage path differs, so only the published image is refused. A policy
# the runner image already carries is kept: its key is exported first, its values are put back
# afterwards, and only a policy with its own path rules or a non-Unrestricted default is refused.
function Enable-T09PathRule([string]$ImagePath, [string]$EvidenceDirectory) {
    $root = $script:T09SaferRoot
    $arm = [pscustomobject]@{
        kind = 'srp-path-rule'; image_path = $ImagePath; root = $root; evidence_directory = $EvidenceDirectory
        root_existed = (Test-Path -LiteralPath $root); before_export_sha256 = $null; prior_values = $null; prior_rules = @()
        refused = $null; created_keys = @(); rule_key = $null; armed_values = $null; armed_export_sha256 = $null
    }
    if ($arm.root_existed) {
        $arm.before_export_sha256 = Export-T09Key $root (Join-Path $EvidenceDirectory 'srp-before.reg')
        $arm.prior_values = Get-T09KeyValues $root
        $arm.prior_rules = @(Get-T09PathRules $root)
        if ($arm.prior_rules.Count -gt 0) { $arm.refused = 'The existing policy already has path rules: ' + ($arm.prior_rules -join ', '); return $arm }
        if ($arm.prior_values.Contains('DefaultLevel') -and [long]$arm.prior_values.DefaultLevel.value -ne 0x40000) {
            $arm.refused = 'The existing policy DefaultLevel is ' + $arm.prior_values.DefaultLevel.value + ', not Unrestricted (0x40000).'; return $arm
        }
    }
    $missing = [Collections.Generic.List[string]]::new()
    for ($key = $root; -not (Test-Path -LiteralPath $key); $key = Split-Path -Path $key -Parent) { $missing.Insert(0, $key) }
    foreach ($key in @($missing) + @((Join-Path $root '0'), (Join-Path $root '0\Paths'))) {
        if (-not (Test-Path -LiteralPath $key)) { [void](New-Item -Path $key); $arm.created_keys += $key }
    }
    $arm.rule_key = Join-Path $root ('0\Paths\{' + [Guid]::NewGuid().ToString() + '}')
    [void](New-Item -Path $arm.rule_key)
    foreach ($name in $script:T09SaferPolicy.Keys) {
        Set-ItemProperty -LiteralPath $root -Name $name -Value $script:T09SaferPolicy[$name][0] -Type $script:T09SaferPolicy[$name][1]
    }
    Set-ItemProperty -LiteralPath $arm.rule_key -Name ItemData -Value $ImagePath -Type String
    Set-ItemProperty -LiteralPath $arm.rule_key -Name SaferFlags -Value 0 -Type DWord
    Set-ItemProperty -LiteralPath $arm.rule_key -Name Description -Value 't09 launch-failure injection' -Type String
    $arm.armed_values = Get-T09KeyValues $root
    $arm.armed_export_sha256 = Export-T09Key $root (Join-Path $EvidenceDirectory 'srp-armed.reg')
    return $arm
}

function Disable-T09PathRule($Arm) {
    $root = $Arm.root
    if ($Arm.rule_key -and (Test-Path -LiteralPath $Arm.rule_key)) { Remove-Item -LiteralPath $Arm.rule_key -Recurse -Force }
    if ($Arm.rule_key -and (Test-Path -LiteralPath $root)) {
        foreach ($name in $script:T09SaferPolicy.Keys) {
            if ($null -ne $Arm.prior_values -and $Arm.prior_values.Contains($name)) {
                Set-ItemProperty -LiteralPath $root -Name $name -Value $Arm.prior_values[$name].value -Type $Arm.prior_values[$name].kind
            } else {
                Remove-ItemProperty -LiteralPath $root -Name $name
            }
        }
    }
    $created = @($Arm.created_keys)
    [array]::Reverse($created)
    foreach ($key in $created) { if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key } }
    $afterSha = Export-T09Key $root (Join-Path $Arm.evidence_directory 'srp-after.reg')
    $restored = if ($Arm.root_existed) { $null -ne $afterSha -and $afterSha -ceq $Arm.before_export_sha256 } else { -not (Test-Path -LiteralPath $root) }
    return [ordered]@{
        root_existed = $Arm.root_existed; root_present_after = (Test-Path -LiteralPath $root)
        before_export_sha256 = $Arm.before_export_sha256; after_export_sha256 = $afterSha
        values_after = Get-T09KeyValues $root; restored = $restored
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
