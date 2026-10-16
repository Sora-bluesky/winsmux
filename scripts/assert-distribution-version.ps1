#requires -Version 7.0
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('Companions', 'Npm')][string]$Preparation = 'Companions',
    [string]$ProtectedOutputsJson = '[]',
    [switch]$AsJson
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$requestedRepoRoot = $RepoRoot
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)

# Both preparation entrances inspect this read-set before reading source bytes.
# The trusted-filesystem contract excludes replacement during this operation.
$pathComparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$attributes = [Collections.Generic.Dictionary[string, IO.FileAttributes]]::new($pathComparer)
if ($IsWindows -and -not ('Winsmux.DistributionPathInfo' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace Winsmux {
    public sealed class DistributionPathInfo {
        public string Name;
        public uint Links;
        public uint Attributes;
        [StructLayout(LayoutKind.Sequential)]
        private struct Information {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint sharing,
            IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
        [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Information information);
        public static DistributionPathInfo Query(string path) {
            // Metadata only, existing object only, shared with ordinary operator handles.
            // The caller validates an ordinary absolute drive path. The internal
            // prefix permits long existing names without accepting device inputs.
            using (var handle = CreateFileW(@"\\?\" + path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                Information information;
                if (!GetFileInformationByHandle(handle, out information)) throw new Win32Exception(Marshal.GetLastWin32Error());
                var name = new StringBuilder(512);
                uint length = GetFinalPathNameByHandleW(handle, name, (uint)name.Capacity, 1);
                if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (length >= name.Capacity) {
                    name = new StringBuilder(checked((int)length + 1));
                    length = GetFinalPathNameByHandleW(handle, name, (uint)name.Capacity, 1);
                    if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                    if (length >= name.Capacity) throw new InvalidOperationException("Physical path size changed.");
                }
                return new DistributionPathInfo { Name=name.ToString(), Links=information.Links, Attributes=information.Attributes };
            }
        }
    }
}
'@
}
$physicalInfo = [Collections.Generic.Dictionary[string, object]]::new($pathComparer)
function Assert-OrdinaryPath([string]$Path) {
    if ($IsWindows) {
        # GetFullPath removes trailing dots/spaces. Validate before it can erase them.
        foreach ($component in $Path.Replace('/','\').Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
            if ($component -in @('.', '..') -or $component -match '^[A-Za-z]:$') { continue }
            if ($component -match '[<>:"|?*\x00-\x1f]' -or $component -match '[. ]$' -or
                $component -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)') {
                throw 'Unsupported distribution path component or namespace.'
            }
        }
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ($IsWindows) {
        if ($full -notmatch '^[A-Za-z]:\\') { throw 'Unsupported distribution path namespace: local drive paths are required.' }
        foreach ($component in $full.Substring(3).Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
            if ($component -match '[<>:"|?*\x00-\x1f]' -or $component -match '[. ]$' -or
                $component -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)') {
                throw 'Unsupported distribution path component.'
            }
        }
    }
    return $full
}
function Get-PhysicalInfo([string]$Path) {
    if (-not $physicalInfo.ContainsKey($Path)) {
        try { $information = [Winsmux.DistributionPathInfo]::Query($Path) }
        catch { throw "Cannot verify physical distribution path $Path`: $($_.Exception.Message)" }
        if ($information.Name -notmatch '^\\\\\?\\Volume\{[0-9a-fA-F-]+\}\\' -or
            ($information.Attributes -band [uint32][IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Unsupported or linked physical distribution path.'
        }
        $physicalInfo.Add($Path, $information)
    }
    return $physicalInfo[$Path]
}
function Get-PhysicalName([string]$Path) {
    $full = Assert-OrdinaryPath $Path
    if (-not $IsWindows) { return $full }
    $current = $full; $suffix = [Collections.Generic.Stack[string]]::new()
    while ($true) {
        try { [void][IO.File]::GetAttributes($current); break }
        catch [IO.FileNotFoundException] { }
        catch [IO.DirectoryNotFoundException] { }
        $parent = [IO.Path]::GetDirectoryName($current)
        if (-not $parent) { throw 'Distribution path has no existing physical ancestor.' }
        $suffix.Push([IO.Path]::GetFileName($current)); $current = $parent
    }
    $information = Get-PhysicalInfo $current
    if ($suffix.Count -and ($information.Attributes -band [uint32][IO.FileAttributes]::Directory) -eq 0) {
        throw 'Distribution path has a file ancestor.'
    }
    $name = $information.Name.TrimEnd('\')
    while ($suffix.Count) { $name += '\' + $suffix.Pop() }
    return $name
}
function Assert-PlainSourcePath([string]$Path, [bool]$Directory) {
    $full = Assert-OrdinaryPath $Path
    $current = $full
    while (-not [string]::IsNullOrEmpty($current)) {
        if (-not $attributes.ContainsKey($current)) {
            $value = [IO.File]::GetAttributes($current)
            if (($value -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked distribution source is unsupported: $current" }
            $attributes.Add($current, $value)
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    $actualDirectory = ($attributes[$full] -band [IO.FileAttributes]::Directory) -ne 0
    if ($actualDirectory -ne $Directory) { throw "Distribution source has the wrong file kind: $full" }
    if ($IsWindows) {
        $information = Get-PhysicalInfo $full
        if (-not $Directory -and $information.Links -ne 1) { throw 'Hardlinked protected distribution file is unsupported.' }
    }
    return $full
}
function Inspect-SourceReadSet {
    $leaves = [Collections.Generic.List[string]]::new()
    foreach ($relative in @('VERSION', 'Cargo.toml', 'Cargo.lock', 'install.ps1',
        'scripts/assert-distribution-version.ps1', 'scripts/distribution-prelaunch.mjs', 'winsmux-app/package.json', 'winsmux-app/package-lock.json',
        'winsmux-app/src-tauri/tauri.conf.json', 'core/Cargo.toml',
        'core/crates/winsmux-workspace-mcp/Cargo.toml', 'winsmux-app/src-tauri/Cargo.toml')) {
        $leaves.Add((Assert-PlainSourcePath (Join-Path $RepoRoot $relative) $false))
    }
    $directories = [Collections.Generic.List[string]]::new()
    $directories.Add((Join-Path $RepoRoot 'core'))
    $directories.Add((Join-Path $RepoRoot 'winsmux-app/src-tauri'))
    if ([IO.Directory]::Exists((Join-Path $RepoRoot 'git-graph'))) { $directories.Add((Join-Path $RepoRoot 'git-graph')) }
    if ($Preparation -eq 'Npm') {
        $directories.Add((Join-Path $RepoRoot 'packages/winsmux'))
        foreach ($relative in @('LICENSE', 'scripts/stage-npm-release.mjs')) {
            $leaves.Add((Assert-PlainSourcePath (Join-Path $RepoRoot $relative) $false))
        }
    }
    $roots = [Collections.Generic.List[string]]::new()
    foreach ($directory in $directories) {
        $roots.Add((Assert-PlainSourcePath $directory $true))
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($directory)
        while ($pending.Count -gt 0) {
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Pop())) {
                $value = [IO.File]::GetAttributes($entry)
                $isDirectory = ($value -band [IO.FileAttributes]::Directory) -ne 0
                [void](Assert-PlainSourcePath $entry $isDirectory)
                if ($isDirectory) { $pending.Push($entry) }
            }
        }
    }
    return @{ roots = [string[]]$roots.ToArray(); leaves = [string[]]$leaves.ToArray() }
}
[void](Assert-OrdinaryPath $requestedRepoRoot)
$readSet = Inspect-SourceReadSet

function Assert-PlainOutputPath([string]$Path) {
    $current = Assert-OrdinaryPath $Path
    while ($current) {
        try { $value = [IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException] { $current = [IO.Path]::GetDirectoryName($current); continue }
        catch [IO.DirectoryNotFoundException] { $current = [IO.Path]::GetDirectoryName($current); continue }
        if (($value -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked distribution output is unsupported: $current" }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    [void](Get-PhysicalName $Path)
}
function Test-OutputOverlap([string]$A, [string]$B) {
    $left = (Get-PhysicalName $A).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $right = (Get-PhysicalName $B).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [string]::Equals($left, $right, $comparison) -or $left.StartsWith($right + [IO.Path]::DirectorySeparatorChar, $comparison) -or $right.StartsWith($left + [IO.Path]::DirectorySeparatorChar, $comparison)
}
$outputDocument = [System.Text.Json.JsonDocument]::Parse($ProtectedOutputsJson)
try {
    if ($outputDocument.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { throw 'Protected output inventory requires an array.' }
    $protectedOutputs = @($outputDocument.RootElement.EnumerateArray() | ForEach-Object {
        if ($_.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or -not [IO.Path]::IsPathFullyQualified($_.GetString())) { throw 'Protected output inventory requires absolute strings.' }
        Assert-OrdinaryPath $_.GetString()
    })
} finally { $outputDocument.Dispose() }
$cargoTargetRoot = $null; $cargoIntermediateRoot = $null
if ($Preparation -eq 'Companions') {
    $tauri = Join-Path $RepoRoot 'winsmux-app/src-tauri'
    if (Test-Path -LiteralPath (Join-Path $tauri 'binaries.recovery.pending')) { throw 'Companion recovery required: unresolved generation barrier exists.' }
    $protectedOutputs += @((Join-Path $tauri 'binaries'), (Join-Path $tauri 'binaries.prepare.lock'), (Join-Path $tauri 'binaries.recovery.pending'))
    $protectedOutputs += @(Get-ChildItem -LiteralPath $tauri -Force | Where-Object { $_.Name.StartsWith('binaries.backup.') -or $_.Name.StartsWith('binaries.stage.') } | ForEach-Object FullName)
    if (-not [string]::IsNullOrWhiteSpace($env:CARGO_TARGET_DIR)) { [void](Assert-OrdinaryPath $env:CARGO_TARGET_DIR) }
    $cargoTargetRoot = if ([string]::IsNullOrWhiteSpace($env:CARGO_TARGET_DIR)) { Join-Path $RepoRoot 'target' }
        elseif ([IO.Path]::IsPathRooted($env:CARGO_TARGET_DIR)) { [IO.Path]::GetFullPath($env:CARGO_TARGET_DIR) }
        else { [IO.Path]::GetFullPath((Join-Path $RepoRoot $env:CARGO_TARGET_DIR)) }
    $cargoIntermediateRoot = Join-Path $cargoTargetRoot '.build'
}
$protectedFootprints = @($readSet.roots) + @($readSet.leaves) + $protectedOutputs
foreach ($protected in $protectedOutputs) { Assert-PlainOutputPath $protected }
foreach ($protected in $protectedOutputs) {
    if (-not (Test-Path -LiteralPath $protected)) { continue }
    $pendingProtected = [Collections.Generic.Stack[string]]::new(); $pendingProtected.Push($protected)
    while ($pendingProtected.Count) {
        $entry = $pendingProtected.Pop()
        $isDirectory = ([IO.File]::GetAttributes($entry) -band [IO.FileAttributes]::Directory) -ne 0
        [void](Assert-PlainSourcePath $entry $isDirectory)
        if ($isDirectory) {
            foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($entry)) { $pendingProtected.Push($child) }
        }
    }
}
if ($Preparation -eq 'Npm') {
    foreach ($output in $protectedOutputs) {
        foreach ($source in (@($readSet.roots) + @($readSet.leaves))) {
            if (Test-OutputOverlap $output $source) { throw 'Npm output and protected distribution source paths overlap.' }
        }
    }
}
if ($Preparation -eq 'Companions') {
    foreach ($output in @($cargoTargetRoot, $cargoIntermediateRoot)) {
        Assert-PlainOutputPath $output
        if ([IO.File]::Exists($output)) { throw 'Cargo output root must be a directory.' }
        foreach ($protected in $protectedFootprints) { if (Test-OutputOverlap $output $protected) { throw 'Cargo output and protected distribution paths overlap.' } }
    }
    if ([IO.Directory]::Exists($cargoTargetRoot)) {
        $pendingBuildPaths = [Collections.Generic.Stack[string]]::new(); $pendingBuildPaths.Push($cargoTargetRoot)
        while ($pendingBuildPaths.Count) {
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($pendingBuildPaths.Pop())) {
                $value = [IO.File]::GetAttributes($entry)
                if (($value -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked Cargo output entry is unsupported: $entry" }
                if (($value -band [IO.FileAttributes]::Directory) -ne 0) { $pendingBuildPaths.Push($entry) }
            }
        }
    }
}
# Full locked resolution can write rustc probes: never inherit its output locations.
if ($IsWindows) {
    foreach ($configuredTemp in @($env:TMP, $env:TEMP)) {
        if (-not [string]::IsNullOrWhiteSpace($configuredTemp)) { [void](Assert-OrdinaryPath $configuredTemp) }
    }
}
$resolutionRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('winsmux-distribution-resolution-' + [Guid]::NewGuid().ToString('N'))))
Assert-PlainOutputPath $resolutionRoot
foreach ($protected in $protectedFootprints) { if (Test-OutputOverlap $resolutionRoot $protected) { throw 'Cargo resolution temp and protected distribution paths overlap.' } }

function Assert-UniqueJsonKeys($Element) {
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $keys.Add($property.Name)) { throw "Duplicate JSON key: $($property.Name)" }
            Assert-UniqueJsonKeys $property.Value
        }
    } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { Assert-UniqueJsonKeys $item }
    }
}
function Read-DistributionJson([string]$RelativePath) {
    $text = [IO.File]::ReadAllText((Join-Path $RepoRoot $RelativePath), [Text.UTF8Encoding]::new($false, $true))
    $document = [System.Text.Json.JsonDocument]::Parse($text)
    try {
        Assert-UniqueJsonKeys $document.RootElement
        return $document.RootElement.Clone()
    } finally { $document.Dispose() }
}
function Assert-JsonObject($Element) {
    if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'Distribution JSON requires an object.' }
}
function Assert-JsonVersion($Element, [string]$Position) {
    Assert-JsonObject $Element
    $field = $Element.GetProperty('version')
    if ($field.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
        -not [string]::Equals($field.GetString(), $version, [StringComparison]::Ordinal)) {
        throw "Distribution JSON version is not the exact VERSION string: $Position"
    }
}

$version = [IO.File]::ReadAllText((Join-Path $RepoRoot 'VERSION')).Trim()
$number = '(?:0|[1-9][0-9]*)'
$identifier = '(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
if ($version -cnotmatch "^$number\.$number\.$number(?:-$identifier(?:\.$identifier)*)?$" -or
    $version -cmatch '-pkgfix(?:\.|$)') { throw 'VERSION is not a supported native release version.' }

$lockPath = Join-Path $RepoRoot 'Cargo.lock'
if (-not [IO.File]::Exists($lockPath)) { throw 'Root Cargo.lock is required before resolution.' }
if (([IO.File]::GetAttributes($lockPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Root Cargo.lock must be a regular file, not a link.'
}
$before = [IO.File]::ReadAllBytes($lockPath)
$expected = @{
    winsmux = 'core/Cargo.toml'
    'winsmux-app' = 'winsmux-app/src-tauri/Cargo.toml'
    'winsmux-workspace-mcp' = 'core/crates/winsmux-workspace-mcp/Cargo.toml'
}
$publicPackages = @{}
$resolutionCreated = $false
try {
    # Full resolution is essential: --no-deps can succeed with a missing/stale lock.
    if (Test-Path -LiteralPath $resolutionRoot) { throw 'Cargo resolution directory already exists.' }
    [void][IO.Directory]::CreateDirectory($resolutionRoot); $resolutionCreated = $true
    $resolutionConfig = 'build.target-dir="' + $resolutionRoot.Replace('\','/') + '"'
    $intermediateConfig = 'build.build-dir="' + (Join-Path $resolutionRoot '.build').Replace('\','/') + '"'
    Push-Location -LiteralPath $RepoRoot
    try {
        $metadataText = @(& cargo metadata --locked --format-version 1 --manifest-path (Join-Path $RepoRoot 'Cargo.toml') --config $resolutionConfig --config $intermediateConfig)
        $metadataExit = $LASTEXITCODE
    } finally { Pop-Location }
    if ($metadataExit -ne 0) { throw "Locked distribution resolution failed with exit $metadataExit" }
    $metadata = ($metadataText -join "`n") | ConvertFrom-Json
    if ($null -eq $metadata.resolve) { throw 'Cargo metadata did not resolve the lock graph.' }
    foreach ($name in $expected.Keys) {
        $packages = @($metadata.packages | Where-Object name -CEQ $name)
        if ($packages.Count -ne 1) { throw "Distribution package is missing or ambiguous: $name" }
        $package = $packages[0]
        $manifest = [IO.Path]::GetFullPath((Join-Path $RepoRoot $expected[$name]))
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not [string]::Equals([IO.Path]::GetFullPath($package.manifest_path), $manifest, $comparison) -or
            $package.version -cne $version -or $package.id -cnotin $metadata.workspace_members -or
            $package.id -cnotin @($metadata.resolve.nodes | ForEach-Object id)) {
            throw "Distribution package does not match VERSION/workspace/lock graph: $name"
        }
        $publicPackages[$name] = @{ id = $package.id; manifest_path = $manifest }
    }
} finally {
    try {
        if (-not [IO.File]::Exists($lockPath) -or [Convert]::ToHexString($before) -cne [Convert]::ToHexString([IO.File]::ReadAllBytes($lockPath))) { throw 'Locked distribution resolution changed Cargo.lock.' }
    } finally {
        if ($resolutionCreated) {
            # Exact fresh owned root, source/output separation established before creation.
            [void](Assert-PlainSourcePath $resolutionRoot $true)
            Remove-Item -LiteralPath $resolutionRoot -Recurse -Force
        }
    }
}

foreach ($relative in @('winsmux-app/package.json', 'winsmux-app/src-tauri/tauri.conf.json')) {
    $value = Read-DistributionJson $relative
    Assert-JsonVersion $value $relative
}
$appLock = Read-DistributionJson 'winsmux-app/package-lock.json'
Assert-JsonVersion $appLock 'package-lock root'
$packages = $appLock.GetProperty('packages')
Assert-JsonObject $packages
Assert-JsonVersion ($packages.GetProperty('')) 'package-lock empty package'
$installer = [IO.File]::ReadAllText((Join-Path $RepoRoot 'install.ps1'))
$assignments = [regex]::Matches($installer, '(?m)^\s*\$VERSION\s*=\s*"([^"]+)"\s*$')
if ($assignments.Count -ne 1 -or $assignments[0].Groups[1].Value -cne $version) {
    throw 'Installer native version does not match VERSION.'
}
if ($AsJson) {
    Write-Output (@{ schema = 'distribution-read-set/v1'; version = $version;
        source_roots = $readSet.roots; source_leaves = $readSet.leaves;
        public_packages = $publicPackages; protected_outputs = $protectedOutputs;
        build_target_root = $cargoTargetRoot; build_intermediate_root = $cargoIntermediateRoot } | ConvertTo-Json -Depth 5 -Compress)
} else {
    Write-Output "Distribution version verified: $version"
}
