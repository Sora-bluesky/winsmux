#requires -Version 7.0
param([switch] $SelfTest)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class WorkspaceJourneyWin32 {
    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public int bInheritHandle;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION {
        public uint attributes, creationLow, creationHigh, accessLow, accessHigh;
        public uint writeLow, writeHigh, volumeSerial, sizeHigh, sizeLow, links, indexHigh, indexLow;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHGetKnownFolderPath(ref Guid folder, uint flags, IntPtr token, out IntPtr path);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateDirectoryW(string path, ref SECURITY_ATTRIBUTES security);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr template);
    public static string LocalAppData() {
        Guid id = new Guid("F1B32785-6FBA-4FCF-9D55-7B8E7F157091");
        IntPtr raw;
        int result = SHGetKnownFolderPath(ref id, 0, IntPtr.Zero, out raw);
        if (result != 0) throw new System.Runtime.InteropServices.COMException("FOLDERID_LocalAppData failed", result);
        try { return Marshal.PtrToStringUni(raw); }
        finally { Marshal.FreeCoTaskMem(raw); }
    }
    public static void CreatePrivateDirectory(string path, byte[] descriptor) {
        GCHandle pinned = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
        try {
            SECURITY_ATTRIBUTES security = new SECURITY_ATTRIBUTES {
                nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>(),
                lpSecurityDescriptor = pinned.AddrOfPinnedObject(), bInheritHandle = 0
            };
            if (!CreateDirectoryW(path, ref security)) throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { pinned.Free(); }
    }
    public static string Identity(string path, bool directory) {
        using (SafeFileHandle handle = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3,
            directory ? 0x02000000u : 0u, IntPtr.Zero)) {
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        BY_HANDLE_FILE_INFORMATION info;
        if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return info.volumeSerial.ToString("X8") + ":" + info.indexHigh.ToString("X8") + info.indexLow.ToString("X8");
        }
    }
}
'@

function Assert-NormalPath {
    param([string] $Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path -notmatch '^[A-Za-z]:\\' -or
        $Path.StartsWith('\\?\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('\\.\', [StringComparison]::Ordinal) -or
        @($Path -split '[\\/]' | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -ne 0 -or
        [IO.Path]::GetFullPath($Path) -cne [IO.Path]::TrimEndingDirectorySeparator($Path)) {
        throw 'Noncanonical path refused'
    }
}

function Assert-NoReparseAncestors {
    param([string] $Path)
    $cursor = $Path
    while ($null -ne $cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Reparse point or non-directory ancestor refused'
        }
        $next = [IO.Path]::GetDirectoryName($cursor)
        if ($null -eq $next -or $next -eq $cursor) { break }
        $cursor = $next
    }
}

function Assert-ChildAbsent {
    param([string] $Parent, [string] $Name)
    Assert-NoReparseAncestors $Parent
    $target = Join-Path $Parent $Name
    if (Test-Path -LiteralPath $target) { throw "Preexisting workspace path refused: $Name" }
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Parent)) {
        if ([IO.Path]::GetFileName($entry) -ieq $Name) {
            throw "Preexisting workspace path refused: $Name"
        }
    }
    return $target
}

function Get-NativeFixtureRoot {
    $root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetTempPath())
    Assert-NormalPath $root
    Assert-NoReparseAncestors $root
    return $root
}

function Assert-WorkspacePackages {
    param([string] $RepositoryRoot)
    $manifest = Join-Path $RepositoryRoot 'Cargo.toml'
    $located = & cargo locate-project --workspace --manifest-path $manifest --message-format plain
    if ($LASTEXITCODE -ne 0 -or @($located).Count -ne 1 -or
        [IO.Path]::GetFullPath($located) -ine [IO.Path]::GetFullPath($manifest)) {
        throw 'Cargo workspace root differs from checkout'
    }
    $metadataText = & cargo metadata --no-deps --format-version 1 --manifest-path $manifest
    if ($LASTEXITCODE -ne 0) { throw 'Cargo package metadata unavailable' }
    $metadata = ($metadataText -join "`n") | ConvertFrom-Json -AsHashtable
    if ([IO.Path]::GetFullPath($metadata.workspace_root) -ine [IO.Path]::GetFullPath($RepositoryRoot)) {
        throw 'Cargo workspace metadata points outside checkout'
    }
    foreach ($entry in @(
        @{ name = 'winsmux'; manifest = (Join-Path $RepositoryRoot 'core/Cargo.toml') },
        @{ name = 'winsmux-workspace-mcp'; manifest = (Join-Path $RepositoryRoot 'core/crates/winsmux-workspace-mcp/Cargo.toml') }
    )) {
        $matches = @($metadata.packages | Where-Object { $_.name -ceq $entry.name -and
            [IO.Path]::GetFullPath($_.manifest_path) -ieq [IO.Path]::GetFullPath($entry.manifest) })
        if ($matches.Count -ne 1) { throw "Cargo package is absent or ambiguous: $($entry.name)" }
    }
}

function Get-CargoBuiltExecutable {
    param([string] $BuildLog, [string] $TargetName, [string] $TargetKind, [string] $ExpectedDirectory)
    $rows = @(Get-Content -LiteralPath $BuildLog -Encoding utf8 | Where-Object { $_.Trim().Length -ne 0 } |
        ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
    $artifacts = @($rows | Where-Object { $_.reason -eq 'compiler-artifact' -and
        $_.target.name -ceq $TargetName -and @($_.target.kind) -contains $TargetKind -and $_.executable })
    if ($artifacts.Count -ne 1) { throw "Cargo executable is absent or ambiguous: $TargetName" }
    $executable = $artifacts[0].executable
    if (-not [IO.Path]::IsPathFullyQualified($executable)) { throw 'Cargo executable path is not absolute' }
    $actual = [IO.Path]::GetFullPath($executable)
    $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($ExpectedDirectory), $actual)
    if ([IO.Path]::IsPathRooted($relative) -or $relative.StartsWith('..') -or $relative -match '[\\/]') {
        throw "Cargo executable escaped expected target directory: $TargetName"
    }
    return $actual
}

function Assert-RunnerCapturedEvidence {
    param([string] $ReceiptBase, [hashtable] $Eof, [string] $Label)
    foreach ($streamName in @('stdout', 'stderr')) {
        $rawPath = "$ReceiptBase.$streamName.bin"
        if (-not [IO.File]::Exists($rawPath) -or
            (Get-Item -LiteralPath $rawPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Missing or redirected $Label $streamName evidence"
        }
        $bytes = [IO.File]::ReadAllBytes($rawPath)
        $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if ($Eof["${streamName}_bytes"] -ne $bytes.Length -or
            $Eof["${streamName}_sha256"] -cne $actualHash) {
            throw "Corrupt $Label $streamName evidence"
        }
    }
}

function New-PrivateSecurity {
    param([switch] $Directory)
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    if ($Directory) {
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        $security = [Security.AccessControl.FileSecurity]::new()
        $inherit = [Security.AccessControl.InheritanceFlags]::None
    }
    $security.SetOwner($owner)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($owner, $system)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid,
            [Security.AccessControl.FileSystemRights]::FullControl, $inherit,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    return $security
}

function Assert-PrivateAcl {
    param([string] $Path)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowed = @($owner, 'S-1-5-18')
    if (-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $owner) {
        throw 'Owned private ACL is absent'
    }
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 2) { throw 'Private ACL has unexpected rule count' }
    foreach ($rule in $rules) {
        if ($rule.IsInherited -or $rule.IdentityReference.Value -notin $allowed -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
                [Security.AccessControl.FileSystemRights]::FullControl) {
            throw 'Private ACL has unexpected principal or rights'
        }
    }
    if (@($rules | Where-Object { $_.IdentityReference.Value -eq $owner }).Count -ne 1 -or
        @($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-18' }).Count -ne 1) {
        throw 'Private ACL lacks owner or SYSTEM'
    }
    return $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Owner, Access')
}

function Assert-PrivateSnapshotSecurity {
    param([Security.AccessControl.FileSystemSecurity] $Acl)
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowed = @($owner, 'S-1-5-18', 'S-1-5-32-544')
    if (-not $Acl.AreAccessRulesProtected -or
        $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $owner) {
        throw 'Private snapshot owner or protected DACL changed'
    }
    $rules = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -eq 0) { throw 'Private snapshot DACL is empty' }
    $userRights = [Security.AccessControl.FileSystemRights]0
    foreach ($rule in $rules) {
        if ($rule.IsInherited -or $rule.IdentityReference.Value -notin $allowed -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            throw 'Private snapshot DACL has an unapproved ACE'
        }
        if ($rule.IdentityReference.Value -eq $owner) {
            $userRights = $userRights -bor $rule.FileSystemRights
        }
    }
    if (($userRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
        [Security.AccessControl.FileSystemRights]::FullControl) {
        throw 'Private snapshot owner rights are insufficient'
    }
    return $Acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Owner, Access')
}

function Get-ItemProof {
    param([string] $Path, [switch] $Directory)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -ne [bool]$Directory -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Workspace object type changed: $Path expected_directory=$([bool]$Directory) actual_directory=$($item.PSIsContainer) attributes=$($item.Attributes)"
    }
    $identity = [WorkspaceJourneyWin32]::Identity($Path, [bool]$Directory)
    $acl = if ($Directory) { Assert-PrivateAcl $Path } else {
        Assert-PrivateSnapshotSecurity (Get-Acl -LiteralPath $Path -ErrorAction Stop)
    }
    $proof = @{ identity = $identity; acl = $acl; bytes = $null; sha256 = $null }
    if (-not $Directory) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $proof.bytes = $bytes.Length
        $proof.sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $value = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable
        $keys = @('schema_version','generation','topology_revision','projects','panes','layouts','selected_project_id','selected_pane_id')
        if ($value.Count -ne $keys.Count -or @($keys | Where-Object { -not $value.ContainsKey($_) }).Count -ne 0 -or
            $value.schema_version -ne 1 -or $value.generation -ne 0 -or $value.topology_revision -ne 0 -or
            $value.projects.Count -ne 0 -or $value.panes.Count -ne 0 -or $value.layouts.Count -ne 0 -or
            $null -ne $value.selected_project_id -or $null -ne $value.selected_pane_id) {
            throw 'Store snapshot is not schema-1 logical empty'
        }
    }
    return $proof
}

function Assert-StoreInvariant {
    param([string[]] $Paths, [hashtable] $Before)
    if ($Paths.Count -ne 5) { throw 'Store proof inventory is incomplete' }
    for ($index = 0; $index -lt $Paths.Count; $index++) {
        $path = $Paths[$index]
        Assert-NormalPath $path
        $after = Get-ItemProof -Path $path -Directory:($index -lt 3)
        if (($index -lt 3 -and $Before[$path].identity -cne $after.identity) -or
            ($index -lt 3 -and $Before[$path].acl -cne $after.acl) -or
            $Before[$path].bytes -ne $after.bytes -or
            $Before[$path].sha256 -cne $after.sha256) {
            throw 'Store parent identity, ACL, or snapshot bytes changed'
        }
    }
}

if ($SelfTest) {
    $selfRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    Assert-WorkspacePackages -RepositoryRoot $selfRepo
    foreach ($bad in @('relative', 'C:\bad\..\child', '\\?\C:\bad')) {
        $rejected = $false
        try { Assert-NormalPath $bad } catch { $rejected = $true }
        if (-not $rejected) { throw "Unsafe path accepted: $bad" }
    }
    $testRoot = Join-Path $PSScriptRoot ('.ci-self-test-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $testRoot) { throw 'Self-test root collision' }
    try {
        $security = New-PrivateSecurity -Directory
        [WorkspaceJourneyWin32]::CreatePrivateDirectory($testRoot, $security.GetSecurityDescriptorBinaryForm())
        $debugPath = Join-Path $testRoot 'target/debug/winsmux-workspace-mcp.exe'
        $releasePath = Join-Path $testRoot 'target/release/winsmux-workspace-mcp.exe'
        $debugLog = Join-Path $testRoot 'debug-build.jsonl'
        $releaseLog = Join-Path $testRoot 'release-build.jsonl'
        foreach ($case in @(
            @{ path = $debugPath; log = $debugLog },
            @{ path = $releasePath; log = $releaseLog }
        )) {
            $row = @{ reason = 'compiler-artifact'; target = @{ name = 'winsmux-workspace-mcp'; kind = @('bin') };
                executable = $case.path } | ConvertTo-Json -Compress -Depth 5
            [IO.File]::WriteAllText($case.log, $row, [Text.UTF8Encoding]::new($false))
        }
        if ((Get-CargoBuiltExecutable -BuildLog $debugLog -TargetName 'winsmux-workspace-mcp' -TargetKind 'bin' `
                -ExpectedDirectory (Join-Path $testRoot 'target/debug')) -ine $debugPath -or
            (Get-CargoBuiltExecutable -BuildLog $releaseLog -TargetName 'winsmux-workspace-mcp' -TargetKind 'bin' `
                -ExpectedDirectory (Join-Path $testRoot 'target/release')) -ine $releasePath) {
            throw 'Cargo profile artifact selection failed'
        }
        $rejected = $false
        try { [void](Get-CargoBuiltExecutable -BuildLog $releaseLog -TargetName 'winsmux-workspace-mcp' `
            -TargetKind 'bin' -ExpectedDirectory (Join-Path $testRoot 'target/debug')) }
        catch { $rejected = $_.Exception.Message -like 'Cargo executable escaped expected target directory*' }
        if (-not $rejected) { throw 'Release MCP was accepted as debug MCP' }
        $rejected = $false
        try { [void](Get-CargoBuiltExecutable -BuildLog $debugLog -TargetName 'stdio_e2e' `
            -TargetKind 'test' -ExpectedDirectory (Join-Path $testRoot 'target/debug/deps')) }
        catch { $rejected = $_.Exception.Message -like 'Cargo executable is absent or ambiguous*' }
        if (-not $rejected) { throw 'Missing native test executable was accepted' }
        $evidenceBase = Join-Path $testRoot 'captured'
        $rawOut = [Text.Encoding]::UTF8.GetBytes('native raw output')
        $rawErr = [byte[]]@()
        [IO.File]::WriteAllBytes("$evidenceBase.stdout.bin", $rawOut)
        [IO.File]::WriteAllBytes("$evidenceBase.stderr.bin", $rawErr)
        $streamProof = @{
            stdout_bytes = $rawOut.Length
            stderr_bytes = 0
            stdout_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawOut)).ToLowerInvariant()
            stderr_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawErr)).ToLowerInvariant()
        }
        Assert-RunnerCapturedEvidence -ReceiptBase $evidenceBase -Eof $streamProof -Label 'mock'
        Remove-Item -LiteralPath "$evidenceBase.stdout.bin" -Force
        $rejected = $false
        try { Assert-RunnerCapturedEvidence -ReceiptBase $evidenceBase -Eof $streamProof -Label 'mock' }
        catch { $rejected = $_.Exception.Message -ceq 'Missing or redirected mock stdout evidence' }
        if (-not $rejected) { throw 'Missing runner stdout evidence accepted' }
        [IO.File]::WriteAllBytes("$evidenceBase.stdout.bin", [byte[]]@(0x58))
        $rejected = $false
        try { Assert-RunnerCapturedEvidence -ReceiptBase $evidenceBase -Eof $streamProof -Label 'mock' }
        catch { $rejected = $_.Exception.Message -ceq 'Corrupt mock stdout evidence' }
        if (-not $rejected) { throw 'Corrupt runner stdout evidence accepted' }
        $original = Get-ItemProof -Path $testRoot -Directory
        if ($original.identity -ne (Get-ItemProof -Path $testRoot -Directory).identity) {
            throw 'Directory identity unstable'
        }
        $oldTemp = $env:TEMP
        $oldTmp = $env:TMP
        $oldRunnerTemp = $env:RUNNER_TEMP
        try {
            $childTemp = Join-Path $testRoot 'child-temp'
            [WorkspaceJourneyWin32]::CreatePrivateDirectory($childTemp, $security.GetSecurityDescriptorBinaryForm())
            $env:TEMP = $childTemp
            $env:TMP = $childTemp
            $env:RUNNER_TEMP = $testRoot
            $selectedFixtureRoot = Get-NativeFixtureRoot
            if ($selectedFixtureRoot -ine $childTemp -or $selectedFixtureRoot -ieq $env:RUNNER_TEMP -or
                (Assert-ChildAbsent -Parent $selectedFixtureRoot -Name 'workspace-journey-project') -ine
                    (Join-Path $childTemp 'workspace-journey-project')) {
                throw 'Fixture root did not follow native child TEMP/TMP'
            }
        } finally {
            if ($null -eq $oldTemp) { Remove-Item Env:TEMP -ErrorAction SilentlyContinue }
            else { $env:TEMP = $oldTemp }
            if ($null -eq $oldTmp) { Remove-Item Env:TMP -ErrorAction SilentlyContinue }
            else { $env:TMP = $oldTmp }
            if ($null -eq $oldRunnerTemp) { Remove-Item Env:RUNNER_TEMP -ErrorAction SilentlyContinue }
            else { $env:RUNNER_TEMP = $oldRunnerTemp }
        }
        $rejected = $false
        try { [void](Assert-ChildAbsent -Parent $PSScriptRoot -Name ([IO.Path]::GetFileName($testRoot))) }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Preexisting child accepted' }
        $filePath = Join-Path $testRoot 'snapshot.json'
        $fileSecurity = New-PrivateSecurity
        $file = [IO.FileInfo]::new($filePath)
        $stream = [IO.FileSystemAclExtensions]::Create($file, [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None,
            4096, [IO.FileOptions]::None, $fileSecurity)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes('{"schema_version":1,"generation":0,"topology_revision":0,"projects":[],"panes":[],"layouts":[],"selected_project_id":null,"selected_pane_id":null}')
            $stream.Write($bytes)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        $fileProof = Get-ItemProof -Path $filePath
        if ($fileProof.bytes -ne $bytes.Length) { throw 'Snapshot byte proof mismatch' }
        $rejected = $false
        try { [void][IO.FileSystemAclExtensions]::Create($file, [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None,
            4096, [IO.FileOptions]::None, $fileSecurity) } catch { $rejected = $true }
        if (-not $rejected) { throw 'Snapshot replacement was accepted' }

        $workspacePath = Join-Path $testRoot 'workspace'
        [WorkspaceJourneyWin32]::CreatePrivateDirectory($workspacePath, $security.GetSecurityDescriptorBinaryForm())
        $v1Path = Join-Path $workspacePath 'v1'
        [WorkspaceJourneyWin32]::CreatePrivateDirectory($v1Path, $security.GetSecurityDescriptorBinaryForm())
        $confirmedPath = Join-Path $v1Path 'confirmed.json'
        $backupPath = Join-Path $v1Path 'backup.json'
        foreach ($path in @($confirmedPath, $backupPath)) {
            $handle = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($path), [IO.FileMode]::CreateNew,
                [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None,
                4096, [IO.FileOptions]::None, $fileSecurity)
            try { $handle.Write($bytes); $handle.Flush($true) } finally { $handle.Dispose() }
        }
        $proofPaths = @($testRoot, $workspacePath, $v1Path, $confirmedPath, $backupPath)
        $baseline = @{}
        for ($index = 0; $index -lt $proofPaths.Count; $index++) {
            $baseline[$proofPaths[$index]] = Get-ItemProof -Path $proofPaths[$index] -Directory:($index -lt 3)
        }
        $replacement = Join-Path $v1Path 'replacement.json'
        $handle = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($replacement), [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None,
            4096, [IO.FileOptions]::None, $fileSecurity)
        try { $handle.Write($bytes); $handle.Flush($true) } finally { $handle.Dispose() }
        [IO.File]::Move($replacement, $confirmedPath, $true)
        if ($baseline[$confirmedPath].identity -ceq (Get-ItemProof -Path $confirmedPath).identity) {
            throw 'Self-test did not replace snapshot identity'
        }
        Assert-StoreInvariant -Paths $proofPaths -Before $baseline

        $productSecurity = New-PrivateSecurity
        $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $productSecurity.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow))
        $productReplacement = Join-Path $v1Path 'product-replacement.json'
        $handle = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($productReplacement), [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None,
            4096, [IO.FileOptions]::None, $productSecurity)
        try { $handle.Write($bytes); $handle.Flush($true) } finally { $handle.Dispose() }
        [IO.File]::Move($productReplacement, $confirmedPath, $true)
        Assert-StoreInvariant -Paths $proofPaths -Before $baseline

        [IO.File]::AppendAllText($confirmedPath, "`n", [Text.UTF8Encoding]::new($false))
        $rejected = $false
        try { Assert-StoreInvariant -Paths $proofPaths -Before $baseline }
        catch { $rejected = $_.Exception.Message -ceq 'Store parent identity, ACL, or snapshot bytes changed' }
        if (-not $rejected) { throw 'Different snapshot bytes accepted' }
        [IO.File]::WriteAllBytes($confirmedPath, $bytes)
        Assert-StoreInvariant -Paths $proofPaths -Before $baseline

        $weakened = [IO.FileSystemAclExtensions]::GetAccessControl(
            [IO.FileInfo]::new($confirmedPath), [Security.AccessControl.AccessControlSections]::Access)
        $everyone = [Security.Principal.SecurityIdentifier]::new('S-1-1-0')
        $weakened.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($everyone,
            [Security.AccessControl.FileSystemRights]::ReadData,
            [Security.AccessControl.AccessControlType]::Allow))
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($confirmedPath), $weakened)
        $rejected = $false
        try { Assert-StoreInvariant -Paths $proofPaths -Before $baseline }
        catch { $rejected = $_.Exception.Message -ceq 'Private snapshot DACL has an unapproved ACE' }
        if (-not $rejected) { throw 'Weakened snapshot ACL accepted' }

        $wrongOwner = New-PrivateSecurity
        $wrongOwner.SetOwner($administrators)
        $rejected = $false
        try { [void](Assert-PrivateSnapshotSecurity $wrongOwner) }
        catch { $rejected = $_.Exception.Message -ceq 'Private snapshot owner or protected DACL changed' }
        if (-not $rejected) { throw 'Wrong snapshot owner accepted' }

        $downgraded = [Security.AccessControl.FileSecurity]::new()
        $downgraded.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
        $downgraded.SetAccessRuleProtection($true, $false)
        $downgraded.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().User,
            [Security.AccessControl.FileSystemRights]::ReadData,
            [Security.AccessControl.AccessControlType]::Allow))
        $rejected = $false
        try { [void](Assert-PrivateSnapshotSecurity $downgraded) }
        catch { $rejected = $_.Exception.Message -ceq 'Private snapshot owner rights are insufficient' }
        if (-not $rejected) { throw 'Downgraded snapshot owner rights accepted' }
        $repair = Join-Path $v1Path 'repair.json'
        $handle = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($repair), [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None,
            4096, [IO.FileOptions]::None, $fileSecurity)
        try { $handle.Write($bytes); $handle.Flush($true) } finally { $handle.Dispose() }
        [IO.File]::Move($repair, $confirmedPath, $true)
        Assert-StoreInvariant -Paths $proofPaths -Before $baseline

        $saved = Join-Path $v1Path 'saved.json'
        [IO.File]::Move($confirmedPath, $saved)
        $linkTarget = Join-Path $testRoot 'link-target'
        [WorkspaceJourneyWin32]::CreatePrivateDirectory($linkTarget, $security.GetSecurityDescriptorBinaryForm())
        [void](New-Item -ItemType Junction -Path $confirmedPath -Target $linkTarget -ErrorAction Stop)
        $rejected = $false
        try { Assert-StoreInvariant -Paths $proofPaths -Before $baseline }
        catch { $rejected = $_.Exception.Message -like 'Workspace object type changed*' }
        if (-not $rejected) { throw 'Reparse snapshot accepted' }
        Remove-Item -LiteralPath $confirmedPath -Force
        [IO.File]::Move($saved, $confirmedPath)
        Assert-StoreInvariant -Paths $proofPaths -Before $baseline

        $oldV1 = Join-Path $workspacePath 'old-v1'
        [IO.Directory]::Move($v1Path, $oldV1)
        [WorkspaceJourneyWin32]::CreatePrivateDirectory($v1Path, $security.GetSecurityDescriptorBinaryForm())
        foreach ($path in @($confirmedPath, $backupPath)) {
            $handle = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($path), [IO.FileMode]::CreateNew,
                [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None,
                4096, [IO.FileOptions]::None, $fileSecurity)
            try { $handle.Write($bytes); $handle.Flush($true) } finally { $handle.Dispose() }
        }
        $rejected = $false
        try { Assert-StoreInvariant -Paths $proofPaths -Before $baseline }
        catch { $rejected = $_.Exception.Message -ceq 'Store parent identity, ACL, or snapshot bytes changed' }
        if (-not $rejected) { throw 'Replaced store parent accepted' }
    } finally {
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($testRoot)) -ine [IO.Path]::GetFullPath($PSScriptRoot)) {
            throw 'Self-test cleanup target escaped its directory'
        }
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    }
    @{ gate = 'workspace-journey/ci-preflight'; self_test = 'pass';
        workspace_packages = 'pass'; debug_release_mcp = 'distinct'; missing_artifact = 'rejected';
        raw_stdout = 'preserved'; raw_stdout_missing = 'rejected'; raw_stdout_corrupt = 'rejected';
        separate_temp_roots = 'pass';
        same_bytes_atomic_replace = 'accepted'; product_three_ace = 'accepted'; bytes_change = 'rejected';
        everyone_ace = 'rejected'; wrong_owner = 'rejected'; owner_rights_downgrade = 'rejected';
        reparse = 'rejected'; parent_replacement = 'rejected' } | ConvertTo-Json -Compress
    exit 0
}

if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:WINSMUX_EPHEMERAL_RUNNER -cne 'github-hosted' -or
    [string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE) -or
    [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'This store gate runs only on a GitHub Windows job'
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workspace = [IO.Path]::TrimEndingDirectorySeparator($env:GITHUB_WORKSPACE)
Assert-NormalPath $workspace
if ($repo -ine $workspace) { throw 'Runner checkout does not match script checkout' }
Assert-WorkspacePackages -RepositoryRoot $repo
$runnerTemp = [IO.Path]::TrimEndingDirectorySeparator($env:RUNNER_TEMP)
Assert-NormalPath $runnerTemp
Assert-NoReparseAncestors $runnerTemp
$fixtureRoot = Get-NativeFixtureRoot
$fixture = Assert-ChildAbsent -Parent $fixtureRoot -Name 'workspace-journey-project'
$known = [IO.Path]::TrimEndingDirectorySeparator([WorkspaceJourneyWin32]::LocalAppData())
$local = [IO.Path]::TrimEndingDirectorySeparator($env:LOCALAPPDATA)
Assert-NormalPath $known
Assert-NormalPath $local
if ($known -ine $local) { throw 'LOCALAPPDATA does not match FOLDERID_LocalAppData' }
Assert-NoReparseAncestors $known

$winsmux = Assert-ChildAbsent -Parent $known -Name 'winsmux'
$directorySecurity = New-PrivateSecurity -Directory
[WorkspaceJourneyWin32]::CreatePrivateDirectory($winsmux, $directorySecurity.GetSecurityDescriptorBinaryForm())
$workspaceRoot = Assert-ChildAbsent -Parent $winsmux -Name 'workspace'
[WorkspaceJourneyWin32]::CreatePrivateDirectory($workspaceRoot, $directorySecurity.GetSecurityDescriptorBinaryForm())
$store = Assert-ChildAbsent -Parent $workspaceRoot -Name 'v1'
[WorkspaceJourneyWin32]::CreatePrivateDirectory($store, $directorySecurity.GetSecurityDescriptorBinaryForm())
$paths = @($winsmux, $workspaceRoot, $store)
$fileSecurity = New-PrivateSecurity
$snapshot = [Text.Encoding]::UTF8.GetBytes('{"schema_version":1,"generation":0,"topology_revision":0,"projects":[],"panes":[],"layouts":[],"selected_project_id":null,"selected_pane_id":null}')
foreach ($name in @('confirmed.json', 'backup.json')) {
    $path = Assert-ChildAbsent -Parent $store -Name $name
    $file = [IO.FileInfo]::new($path)
    $stream = [IO.FileSystemAclExtensions]::Create($file, [IO.FileMode]::CreateNew,
        [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None,
        4096, [IO.FileOptions]::None, $fileSecurity)
    try { $stream.Write($snapshot); $stream.Flush($true) } finally { $stream.Dispose() }
    $paths += $path
}
$before = @{}
for ($index = 0; $index -lt $paths.Count; $index++) {
    $before[$paths[$index]] = Get-ItemProof -Path $paths[$index] -Directory:($index -lt 3)
}

$evidence = Assert-ChildAbsent -Parent $runnerTemp -Name 'workspace-journey'
[IO.Directory]::CreateDirectory($evidence) | Out-Null
$tree = (& git -C $repo rev-parse 'HEAD^{tree}').Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $tree -notmatch '^[0-9a-f]{40}$') { throw 'Candidate tree unavailable' }
& git -C $repo diff --quiet HEAD --
if ($LASTEXITCODE -ne 0) { throw 'Checkout tracked files differ from the candidate tree' }
$env:CARGO_TARGET_DIR = Join-Path $repo 'target'
$releaseCliLog = Join-Path $evidence 'release-cli-build.jsonl'
& cargo build --release -p winsmux --bin winsmux --message-format=json > $releaseCliLog
if ($LASTEXITCODE -ne 0) { throw 'CLI build failed' }
$releaseMcpLog = Join-Path $evidence 'release-mcp-build.jsonl'
& cargo build --release -p winsmux-workspace-mcp --bin winsmux-workspace-mcp --message-format=json > $releaseMcpLog
if ($LASTEXITCODE -ne 0) { throw 'MCP build failed' }
$debugMcpLog = Join-Path $evidence 'debug-mcp-build.jsonl'
& cargo build -p winsmux-workspace-mcp --bin winsmux-workspace-mcp --message-format=json > $debugMcpLog
if ($LASTEXITCODE -ne 0) { throw 'Debug MCP build failed' }
$buildJson = Join-Path $evidence 'native-build.jsonl'
& cargo test -p winsmux-workspace-mcp --test stdio_e2e --no-run --message-format=json > $buildJson
if ($LASTEXITCODE -ne 0) { throw 'Native test build failed' }
$cli = Get-CargoBuiltExecutable -BuildLog $releaseCliLog -TargetName 'winsmux' -TargetKind 'bin' `
    -ExpectedDirectory (Join-Path $repo 'target/release')
$mcp = Get-CargoBuiltExecutable -BuildLog $releaseMcpLog -TargetName 'winsmux-workspace-mcp' -TargetKind 'bin' `
    -ExpectedDirectory (Join-Path $repo 'target/release')
$debugMcp = Get-CargoBuiltExecutable -BuildLog $debugMcpLog -TargetName 'winsmux-workspace-mcp' -TargetKind 'bin' `
    -ExpectedDirectory (Join-Path $repo 'target/debug')
$native = Get-CargoBuiltExecutable -BuildLog $buildJson -TargetName 'stdio_e2e' -TargetKind 'test' `
    -ExpectedDirectory (Join-Path $repo 'target/debug/deps')
if ($debugMcp -ieq $mcp) { throw 'Release and debug MCP resolved to one executable' }
foreach ($path in @($cli, $mcp, $debugMcp, $native)) {
    if (-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Built executable absent or redirected'
    }
}
$hashes = @{}
foreach ($path in @($cli, $mcp, $debugMcp, $native)) { $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
$receipt = Join-Path $evidence 'native-receipt.jsonl'
$output = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'run.ps1') `
    -CliExe $cli -CliSha256 $hashes[$cli] -McpExe $mcp -McpSha256 $hashes[$mcp] `
    -NativeTestExe $native -NativeTestSha256 $hashes[$native] `
    -NativeMcpExe $debugMcp -NativeMcpSha256 $hashes[$debugMcp] `
    -CandidateTree $tree -StoreRoot $store -FixtureParentRoot $fixtureRoot -FixturePath $fixture -ReceiptPath $receipt
if ($LASTEXITCODE -ne 0) { throw 'Non-PTY workspace journey failed; runner receipts retained' }
$results = @($output | Where-Object { $_ -match '^\{' } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
if ($results.Count -ne 1 -or $results[0].status -cne 'pass' -or $results[0].candidate_tree -cne $tree -or
    $results[0].mcp_sha256 -cne $hashes[$mcp] -or
    $results[0].native_mcp_sha256 -cne $hashes[$debugMcp] -or
    $results[0].native_test_sha256 -cne $hashes[$native]) {
    throw 'Non-PTY result absent or mismatched'
}
foreach ($label in @('host', 'mcp', 'native')) {
    $base = "$receipt.runner-$label"
    $start = Get-Content -LiteralPath "$base.start.json" -Raw | ConvertFrom-Json -AsHashtable
    $exit = Get-Content -LiteralPath "$base.exit.json" -Raw | ConvertFrom-Json -AsHashtable
    $eof = Get-Content -LiteralPath "$base.eof.json" -Raw | ConvertFrom-Json -AsHashtable
    $expected = if ($label -eq 'host') { $hashes[$cli] } elseif ($label -eq 'mcp') { $hashes[$mcp] } else { $hashes[$native] }
    $code = if ($label -eq 'native') { 0 } else { 2 }
    if ($start.stage -cne 'started' -or $exit.stage -cne 'exited' -or $eof.stage -cne 'streams_eof' -or
        $start.pid -ne $exit.pid -or $start.pid -ne $eof.pid -or
        $start.creation_filetime_utc -ne $exit.creation_filetime_utc -or
        $start.creation_filetime_utc -ne $eof.creation_filetime_utc -or
        $start.executable_sha256 -cne $expected -or $exit.executable_sha256 -cne $expected -or
        $exit.exit_code -ne $code) { throw "Incomplete or mismatched $label process receipt" }
    Assert-RunnerCapturedEvidence -ReceiptBase $base -Eof $eof -Label $label
}
foreach ($path in @($cli, $mcp, $debugMcp, $native)) {
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $hashes[$path]) { throw 'Executable changed after run' }
}
Assert-StoreInvariant -Paths $paths -Before $before
if ((& git -C $repo rev-parse 'HEAD^{tree}').Trim().ToLowerInvariant() -cne $tree) {
    throw 'Checkout tree changed during runner execution'
}
& git -C $repo diff --quiet HEAD --
if ($LASTEXITCODE -ne 0) { throw 'Checkout tracked files changed during runner execution' }
@{ gate = 'workspace-journey/ci'; status = 'pass'; tree = $tree;
    cli_sha256 = $hashes[$cli]; release_mcp_sha256 = $hashes[$mcp];
    debug_mcp_sha256 = $hashes[$debugMcp]; native_sha256 = $hashes[$native] } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $evidence 'result.json') -Encoding utf8
Get-Content -LiteralPath (Join-Path $evidence 'result.json')
