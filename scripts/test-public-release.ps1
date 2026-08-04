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

    [switch]$SelfTest,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RetryCount = 6
$script:RetryDelaySeconds = 10
$script:DesktopObservationTimeoutMilliseconds = 180000
$script:DesktopObservationPollMilliseconds = 500
$script:DesktopTeardownProbeTimeoutMilliseconds = 5000
$script:DesktopTeardownProbeTotalBudgetMilliseconds = 20000
$script:DesktopOutputRetainLimitBytes = 16384
$script:OwnedRootPrefix = 'winsmux-public-release-'
$script:DesktopLifecycle = $null
$script:DesktopFolderContextPath = 'Registry::HKEY_CURRENT_USER\Software\Classes\Directory\shell\winsmux'
$script:DesktopBackgroundContextPath = 'Registry::HKEY_CURRENT_USER\Software\Classes\Directory\Background\shell\winsmux'
$script:DesktopProductPath = 'Registry::HKEY_CURRENT_USER\Software\github\winsmux'
$script:DesktopUninstallPath = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\winsmux'

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-CoreReleaseAssetNames {
    return @(
        'winsmux-x64.exe'
        'winsmux-arm64.exe'
    )
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
        return Invoke-NativeProcess -FilePath $FilePath -ArgumentList $ArgumentList -Environment $Environment -TimeoutSeconds $TimeoutSeconds
    } catch [TimeoutException] {
        $result = $_.Exception.Data['process_result']
        Assert-Condition ($null -ne $result) 'Timed-out child process did not provide a terminal output capture.'
        throw (Format-PublicChildProcessDiagnostic -Operation $Operation -State 'timed_out' -Result $result)
    }
}

function Initialize-DesktopNativeTypes {
    if ($null -ne ([Management.Automation.PSTypeName]'Winsmux.PublicRelease.BoundedStreamCapture').Type) {
        return
    }

    $source = @'
using System;
using System.ComponentModel;
using System.IO;
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
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{}
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
    Initialize-DesktopNativeTypes
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    Assert-Condition $process.Start() "Unable to start owned process: $FilePath"
    return [pscustomobject]@{
        process = $process
        stdout_task = [Winsmux.PublicRelease.BoundedStreamCapture]::ReadAsync(
            $process.StandardOutput.BaseStream,
            $script:DesktopOutputRetainLimitBytes
        )
        stderr_task = [Winsmux.PublicRelease.BoundedStreamCapture]::ReadAsync(
            $process.StandardError.BaseStream,
            $script:DesktopOutputRetainLimitBytes
        )
    }
}

function Get-OwnedProcessCapture {
    param([Parameter(Mandatory)]$OwnedProcess)

    $process = $OwnedProcess.process
    Assert-Condition $process.HasExited 'Owned process output was requested before the process became terminal.'
    $process.WaitForExit()
    $stdoutResult = $OwnedProcess.stdout_task.GetAwaiter().GetResult()
    $stderrResult = $OwnedProcess.stderr_task.GetAwaiter().GetResult()
    $encoding = [Text.UTF8Encoding]::new($false, $false)
    return [pscustomobject]@{
        exit_code = [int]$process.ExitCode
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

    if ($null -eq $RootProcess) {
        return
    }
    $process = if ($null -ne (Get-ObjectPropertyValue -Object $RootProcess -Name 'process')) {
        $RootProcess.process
    } else {
        $RootProcess
    }
    try {
        if (-not $process.HasExited) {
            $process.Kill($true)
            $stopped = $process.WaitForExit(15000)
            Assert-Condition $stopped "Timed out while stopping owned process tree $($process.Id)."
        }
    } catch {
        throw "Unable to stop owned process tree $($process.Id): $($_.Exception.Message)"
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
    Assert-Condition (-not $State.install_root_exists) "$Phase observed a remaining install root."
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
        [scriptblock]$UninstallRegistrationProbe
    )

    Assert-DesktopLifecyclePhase -Context $Context -ExpectedPhase 'materialized_verified'
    $installRoot = [string]$Context.install_root
    $uninstallerPath = [string]$Context.expected_uninstaller
    Assert-DesktopInstallRootOwnership -InstallRoot $InstallRoot
    $expectedUninstaller = Join-Path $InstallRoot 'uninstall.exe'
    Assert-Condition (Test-CanonicalPathEqual -ActualPath $UninstallerPath -ExpectedPath $expectedUninstaller) "Desktop uninstall invocation path '$UninstallerPath' does not name the run-owned uninstaller '$expectedUninstaller'."
    Assert-Condition (Test-Path -LiteralPath $expectedUninstaller -PathType Leaf) "Run-owned Desktop uninstaller was not found: $expectedUninstaller"

    $arguments = @('/S', "_?=$InstallRoot")
    $uninstall = if ($null -eq $ProcessInvoker) {
        Invoke-PublicChildProcess -Operation 'desktop_uninstaller' -FilePath $expectedUninstaller -ArgumentList $arguments -Environment $Environment -TimeoutSeconds 180
    } else {
        & $ProcessInvoker $expectedUninstaller $arguments $Environment
    }
    if ($uninstall.exit_code -ne 0) {
        throw (Format-PublicChildProcessDiagnostic -Operation 'desktop_uninstaller' -State 'exit_nonzero' -Result $uninstall)
    }

    $registrationExists = if ($null -eq $UninstallRegistrationProbe) {
        Test-Path -LiteralPath $script:DesktopUninstallPath
    } else {
        [bool](& $UninstallRegistrationProbe)
    }
    Assert-Condition (-not $registrationExists) 'Desktop uninstall registration remained immediately after the normal uninstaller.'
    return $uninstall
}

function Remove-DesktopOwnedResidue {
    param([Parameter(Mandatory)]$Context)

    Assert-DesktopLifecyclePhase -Context $Context -ExpectedPhase 'uninstall_verified'
    $installRoot = [string]$Context.install_root
    Assert-DesktopInstallRootOwnership -InstallRoot $InstallRoot
    Assert-Condition (-not (Test-Path -LiteralPath $script:DesktopUninstallPath)) 'Desktop uninstall registration must be absent before residue cleanup.'

    $removeProductState = Test-Path -LiteralPath $script:DesktopProductPath
    if ($removeProductState) {
        $materializedInstallRoot = Get-RegistryDefaultValue -Path $script:DesktopProductPath
        Assert-DesktopProductStateOwnership -MaterializedInstallRoot $materializedInstallRoot -ExpectedInstallRoot $InstallRoot
    }

    $shortcutPathsToRemove = @()
    foreach ($shortcutPath in @((Get-DesktopShortcutPath), (Get-DesktopStartMenuShortcutPath))) {
        if (Test-Path -LiteralPath $shortcutPath) {
            $targetPath = Get-DesktopShortcutTarget -Path $shortcutPath
            Assert-DesktopShortcutOwnership -TargetPath $targetPath -InstallRoot $InstallRoot -ShortcutPath $shortcutPath
            $shortcutPathsToRemove += $shortcutPath
        }
    }

    $installRootExists = Test-Path -LiteralPath $InstallRoot
    if ($installRootExists) {
        $item = Get-Item -LiteralPath $InstallRoot -Force
        Assert-Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Refusing to remove a reparse-point install root: $InstallRoot"
    }

    if ($removeProductState) {
        Remove-Item -LiteralPath $script:DesktopProductPath -Recurse -Force
    }

    foreach ($shortcutPath in $shortcutPathsToRemove) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }

    if ($installRootExists) {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force
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
            Stop-OwnedProcessTree -RootProcess $Context.app_process
        } else {
            & $StopInvoker $Context.app_process | Out-Null
        }

        if ($null -eq $UninstallInvoker) {
            Invoke-VerifiedDesktopUninstaller -Context $Context -Environment $Environment | Out-Null
        } else {
            & $UninstallInvoker $Context $Environment | Out-Null
        }
        Set-DesktopLifecyclePhase -Context $Context -NextPhase 'uninstall_verified'

        if ($null -eq $ResidueInvoker) {
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
        Set-DesktopLifecyclePreserve -Context $Context -Message $_.Exception.Message
        throw
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
        $value = $false
        if ($output.Count -ge 1) {
            $lastOutput = $output[$output.Count - 1]
            if ($lastOutput -is [string] -and $lastOutput -cmatch '^(?:true|false|unknown|error:[a-z]+)$') {
                return [string]$lastOutput
            }
            $value = [bool]$lastOutput
        }
        if ($value) { return 'true' }
        return 'false'
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
        [Parameter(Mandatory)][string]$WebSocketDebuggerUrl,
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
        [AllowNull()][string]$BrowserPath
    )

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $versionResponse = $null
    $versionDocument = $null
    $listResponse = $null
    $listDocument = $null
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(5)
        $client.MaxResponseContentBufferSize = 65536
        try {
            $versionResponse = $client.GetAsync("http://${HostName}:$Port/json/version").GetAwaiter().GetResult()
        } catch {
            return (New-DesktopCdpProbeRecord -State 'transport_unavailable' -PageUrl $null -Port $Port)
        }
        if (-not $versionResponse.IsSuccessStatusCode) {
            return (New-DesktopCdpProbeRecord -State 'http_error' -PageUrl $null -Port $Port)
        }

        try {
            $versionPayload = $versionResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
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
            $listResponse = $client.GetAsync("http://${HostName}:$Port/json/list").GetAwaiter().GetResult()
        } catch {
            return (New-DesktopCdpProbeRecord -State 'transport_unavailable' -PageUrl $null -Port $Port -PathAuthority ([string]$pathAuthority.state))
        }
        if (-not $listResponse.IsSuccessStatusCode) {
            return (New-DesktopCdpProbeRecord -State 'http_error' -PageUrl $null -Port $Port -PathAuthority ([string]$pathAuthority.state))
        }
        try {
            $listPayload = $listResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
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
        [scriptblock]$PageProbe
    )

    $portRecord = Read-DesktopDevToolsActivePort -UserDataFolder $UserDataFolder -SnapshotProvider $PortFileSnapshotProvider
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

    $processSnapshot = if ($null -eq $ProcessSnapshotProvider) {
        Get-DesktopProcessSnapshot
    } else {
        & $ProcessSnapshotProvider $OwnedProcess
    }
    $listenerSnapshot = if ($null -eq $ListenerSnapshotProvider) {
        Get-DesktopListenerSnapshot -Port $Port
    } else {
        & $ListenerSnapshotProvider $Port $OwnedProcess
    }
    Assert-Condition ($null -ne $processSnapshot) 'Desktop process snapshot envelope was absent.'
    Assert-Condition ($null -ne $listenerSnapshot) 'Desktop listener snapshot envelope was absent.'
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

    $probe = if ($null -eq $PageProbe) {
        Get-VerifiedRemoteDebugPage -HostName ([string]$authority.host) -Port ([int]$authority.port) -BrowserPath ([string]$authority.browser_path)
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
            if (-not [string]::IsNullOrWhiteSpace($UserDataFolder)) {
                try {
                    $teardownDiagnosis = Get-DesktopTeardownDiagnosis -UserDataFolder $UserDataFolder -RootProcessId ([long]$Context.app_process.process.Id) -DebugPort $Port
                } catch {
                    $teardownDiagnosis = $null
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

    $profileRoot = Join-Path $Root 'core-profile'
    $localAppData = Join-Path $profileRoot 'LocalAppData'
    $roamingAppData = Join-Path $profileRoot 'AppData'
    $tempRoot = Join-Path $profileRoot 'Temp'
    $homeRoot = Join-Path $profileRoot 'Home'
    New-Item -ItemType Directory -Path $localAppData, $roamingAppData, $tempRoot, $homeRoot | Out-Null
    $environment = @{
        LOCALAPPDATA = $localAppData
        APPDATA = $roamingAppData
        TEMP = $tempRoot
        TMP = $tempRoot
        USERPROFILE = $homeRoot
        HOME = $homeRoot
    }
    $executedAssetName = $coreAssetNames[0]
    Assert-Condition ($executedAssetName -ceq 'winsmux-x64.exe') 'Core executable inventory did not keep x64 as the runnable asset.'
    $expectedProgramName = [IO.Path]::GetFileNameWithoutExtension($executedAssetName)
    $result = Invoke-PublicChildProcess -Operation 'core_version' -FilePath $assetPaths[$executedAssetName] -ArgumentList @('--version') -Environment $environment -TimeoutSeconds 30
    Assert-CoreVersionResult -Result $result -ExpectedProgramName $expectedProgramName -ExpectedVersion $Version
    return [ordered]@{
        asset = $executedAssetName
        sha256 = $expectedHashes[$executedAssetName]
        version = $Version
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
    $npmEnvironment = @{
        NPM_CONFIG_CACHE = Join-Path $Root 'npm-cache'
        NPM_CONFIG_PREFIX = Join-Path $Root 'npm-prefix'
        NPM_CONFIG_USERCONFIG = Join-Path $Root 'npmrc'
        NPM_CONFIG_AUDIT = 'false'
        NPM_CONFIG_FUND = 'false'
        NPM_CONFIG_UPDATE_NOTIFIER = 'false'
        LOCALAPPDATA = Join-Path $Root 'npm-local-app-data'
        APPDATA = Join-Path $Root 'npm-app-data'
        TEMP = Join-Path $Root 'npm-temp'
        TMP = Join-Path $Root 'npm-temp'
        USERPROFILE = Join-Path $Root 'npm-home'
        HOME = Join-Path $Root 'npm-home'
    }
    New-Item -ItemType Directory -Path @(
        $npmEnvironment.NPM_CONFIG_CACHE,
        $npmEnvironment.NPM_CONFIG_PREFIX,
        $npmEnvironment.LOCALAPPDATA,
        $npmEnvironment.APPDATA,
        $npmEnvironment.TEMP,
        $npmEnvironment.USERPROFILE
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

    $installRoot = Join-Path $Root 'installed'
    $context = New-DesktopLifecycleContext -OwnedRoot $Root -InstallRoot $installRoot -ExpectedVersion $Version
    $script:DesktopLifecycle = $context
    $assetName = "winsmux_$($Version)_x64-setup.exe"
    $baseUrl = "https://github.com/$Repository/releases/download/$ReleaseTag"
    $manifestPath = Join-Path $Root 'SHA256SUMS-desktop'
    $setupPath = Join-Path $Root $assetName
    $expectedHash = ''
    $childEnvironment = @{}
    $observation = $null
    $setupFailure = $null
    try {
        Assert-DesktopRunner
        $initial = Get-DesktopProtectedState -InstallRoot $installRoot
        Start-DesktopLifecycle -Context $context -PreflightState $initial

        Invoke-PublicDownload -Uri "$baseUrl/SHA256SUMS-desktop" -Destination $manifestPath -Root $Root
        Invoke-PublicDownload -Uri "$baseUrl/$assetName" -Destination $setupPath -Root $Root
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
        $expectedHash = Get-ChecksumEntry -ManifestText $manifest -AssetName $assetName
        Assert-FileChecksum -Path $setupPath -ExpectedHash $expectedHash

        $childRoot = Join-Path $Root 'profile'
        $localAppData = Join-Path $childRoot 'LocalAppData'
        $roamingAppData = Join-Path $childRoot 'AppData'
        $tempRoot = Join-Path $childRoot 'Temp'
        $homeRoot = Join-Path $childRoot 'Home'
        New-Item -ItemType Directory -Path $localAppData, $roamingAppData, $tempRoot, $homeRoot | Out-Null
        $childEnvironment = @{
            LOCALAPPDATA = $localAppData
            APPDATA = $roamingAppData
            TEMP = $tempRoot
            TMP = $tempRoot
            USERPROFILE = $homeRoot
            HOME = $homeRoot
            WINSMUX_ORCHESTRA_ATTACH_MODE = 'desktop-app'
            WINSMUX_ORCHESTRA_DISABLE_POWERSHELL_ATTACH = '1'
            WINSMUX_ORCHESTRA_DISABLE_WINDOWS_TERMINAL_ATTACH = '1'
            WINSMUX_CODEX_LAUNCHER = ''
        }

        Set-DesktopLifecyclePhase -Context $context -NextPhase 'installer_started'
        $install = Invoke-PublicChildProcess -Operation 'desktop_installer' -FilePath $setupPath -ArgumentList @('/S', "/D=$installRoot") -Environment $childEnvironment -TimeoutSeconds 180
        if ($install.exit_code -ne 0) {
            throw (Format-PublicChildProcessDiagnostic -Operation 'desktop_installer' -State 'exit_nonzero' -Result $install)
        }
        Assert-DesktopMaterializedOwnership -Context $context
        Set-DesktopLifecyclePhase -Context $context -NextPhase 'materialized_verified'

        $webViewRoot = Join-Path $childRoot 'WebView2'
        New-Item -ItemType Directory -Path $webViewRoot | Out-Null
        $debugEndpoint = New-DesktopFixedDebugEndpoint
        $childEnvironment.WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = [string]$debugEndpoint.argument
        $childEnvironment.WEBVIEW2_USER_DATA_FOLDER = $webViewRoot

        $context.app_process = Start-OwnedProcess -FilePath (Join-Path $installRoot 'winsmux-app.exe') -Environment $childEnvironment
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
            throw [AggregateException]::new('Desktop setup and cleanup failed.', [Exception[]]@($setupFailure, $setupCleanupFailure))
        }
        throw $setupFailure
    }
    Assert-DesktopLifecyclePhase -Context $context -ExpectedPhase 'clean'
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

function Invoke-SelfTest {
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
    try {

        if ($Surface -eq 'Core') {
            $coreAssetNames = @(Get-CoreReleaseAssetNames)
            $x64Payload = Join-Path $root 'winsmux-x64.exe'
            $arm64Payload = Join-Path $root 'winsmux-arm64.exe'
            Set-Content -LiteralPath $x64Payload -Value 'public-core-x64' -Encoding ascii -NoNewline
            Set-Content -LiteralPath $arm64Payload -Value 'public-core-arm64' -Encoding ascii -NoNewline
            $x64Hash = (Get-FileHash -LiteralPath $x64Payload -Algorithm SHA256).Hash.ToLowerInvariant()
            $arm64Hash = (Get-FileHash -LiteralPath $arm64Payload -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [string]::Join([Environment]::NewLine, @(
                "$x64Hash  winsmux-x64.exe",
                "$arm64Hash  winsmux-arm64.exe"
            ))

            Assert-Condition ($coreAssetNames.Count -eq 2) 'Core asset inventory did not contain exactly two assets.'
            Assert-Condition ($coreAssetNames[0] -ceq 'winsmux-x64.exe') 'Core asset inventory did not keep x64 first.'
            Assert-Condition ($coreAssetNames[1] -ceq 'winsmux-arm64.exe') 'Core asset inventory did not keep ARM64 second.'
            $caseIds.Add('core_asset_inventory')

            Assert-Condition (Test-Throws { Get-ChecksumEntry -ManifestText "$x64Hash  winsmux-x64.exe" -AssetName 'winsmux-arm64.exe' }) 'Missing ARM64 checksum entry was accepted.'
            $caseIds.Add('missing_arm64_checksum_entry')

            $duplicateArm64Manifest = [string]::Join([Environment]::NewLine, @($manifest, "$arm64Hash  winsmux-arm64.exe"))
            Assert-Condition (Test-Throws { Get-ChecksumEntry -ManifestText $duplicateArm64Manifest -AssetName 'winsmux-arm64.exe' }) 'Duplicate ARM64 checksum entry was accepted.'
            $caseIds.Add('duplicate_arm64_checksum_entry')

            Assert-Condition (Test-Throws { Assert-FileChecksum -Path $arm64Payload -ExpectedHash ('0' * 64) }) 'ARM64 checksum mismatch was accepted.'
            $caseIds.Add('arm64_checksum_mismatch')

            Assert-Condition ((Get-ChecksumEntry -ManifestText $manifest -AssetName 'winsmux-x64.exe') -ceq $x64Hash) 'Valid x64 checksum entry was rejected.'
            Assert-Condition ((Get-ChecksumEntry -ManifestText $manifest -AssetName 'winsmux-arm64.exe') -ceq $arm64Hash) 'Valid ARM64 checksum entry was rejected.'
            Assert-FileChecksum -Path $x64Payload -ExpectedHash $x64Hash
            Assert-FileChecksum -Path $arm64Payload -ExpectedHash $arm64Hash
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
            $newMaterializedContext = {
                $candidateContext = New-DesktopLifecycleContext -OwnedRoot $root -InstallRoot $installRoot -ExpectedVersion $Version
                Start-DesktopLifecycle -Context $candidateContext -PreflightState $emptyState
                Set-DesktopLifecyclePhase -Context $candidateContext -NextPhase 'installer_started'
                Set-DesktopLifecyclePhase -Context $candidateContext -NextPhase 'materialized_verified'
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
            $registrationProbe = { return $false }
            $leafContext = & $newMaterializedContext
            Invoke-VerifiedDesktopUninstaller -Context $leafContext -Environment @{} -ProcessInvoker $processInvoker -UninstallRegistrationProbe $registrationProbe | Out-Null
            Assert-Condition ($uninstallCapture.call_count -eq 1) 'Desktop uninstaller was not invoked exactly once.'
            Assert-Condition ([string]::Equals($uninstallCapture.file_path, $uninstallPath, [StringComparison]::OrdinalIgnoreCase)) 'Desktop uninstaller invocation did not use the verified run-owned path.'
            Assert-Condition ($uninstallCapture.arguments.Count -eq 2) 'Desktop uninstaller invocation did not contain exactly two arguments.'
            Assert-Condition ($uninstallCapture.arguments[0] -ceq '/S') 'Desktop uninstaller invocation did not put /S first.'
            Assert-Condition ($uninstallCapture.arguments[1] -ceq "_?=$installRoot") 'Desktop uninstaller invocation did not put the run-owned _? argument last.'
            $caseIds.Add('desktop_uninstall_argv_order')

            $foreignUninstaller = Join-Path $root 'outside\uninstall.exe'
            $foreignContext = & $newMaterializedContext
            $foreignContext.expected_uninstaller = $foreignUninstaller
            Assert-Condition (Test-Throws {
                Invoke-VerifiedDesktopUninstaller -Context $foreignContext -Environment @{} -ProcessInvoker $processInvoker -UninstallRegistrationProbe $registrationProbe
            }) 'A foreign Desktop uninstaller path reached invocation.'
            Assert-Condition ($uninstallCapture.call_count -eq 1) 'A foreign Desktop uninstaller path reached the process invoker.'
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
            $uninstallFailureStopInvoker = { $uninstallFailureCalls.stop += 1 }.GetNewClosure()
            $uninstallFailureUninstallInvoker = {
                param($Context, $Environment)
                $uninstallFailureCalls.uninstall += 1
                Invoke-VerifiedDesktopUninstaller -Context $Context -Environment $Environment -ProcessInvoker $nonzeroProcessInvoker -UninstallRegistrationProbe { return $false } | Out-Null
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
            $registrationStopInvoker = { $registrationCalls.stop += 1 }.GetNewClosure()
            $registrationUninstallInvoker = {
                param($Context, $Environment)
                $registrationCalls.uninstall += 1
                Invoke-VerifiedDesktopUninstaller -Context $Context -Environment $Environment -ProcessInvoker $processInvoker -UninstallRegistrationProbe { return $true } | Out-Null
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
                $candidate = New-DesktopLifecycleContext -OwnedRoot $root -InstallRoot $installRoot -ExpectedVersion $Version
                Start-DesktopLifecycle -Context $candidate -PreflightState $emptyState
                Set-DesktopLifecyclePhase -Context $candidate -NextPhase 'installer_started'
                Set-DesktopLifecyclePhase -Context $candidate -NextPhase 'materialized_verified'
                return $candidate
            }.GetNewClosure()
            $observerStop = { param($OwnedProcess) Stop-OwnedProcessTree -RootProcess $OwnedProcess }.GetNewClosure()
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
                $OwnedProcess.process.Kill($true)
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

            $fixedDebugEndpoint = New-DesktopDebugEndpointRecord -Port 49161
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
                Assert-Condition ([string]$Authority.state -ceq 'authority_ready') 'Typed page probe received an incomplete authority.'
                Assert-Condition ([string]$Authority.host -ceq '127.0.0.1') 'Typed page probe received a non-loopback host.'
                Assert-Condition ([int]$Authority.port -eq $typedPort) 'Typed page probe received a foreign port.'
                Assert-Condition ([string]$Authority.browser_path -ceq $typedBrowserPath) 'Typed page probe received a foreign browser path.'
                return (New-DesktopCdpProbeRecord -State 'page_ready' -PageUrl 'tauri://localhost/' -Port $typedPort -PathAuthority 'cross_checked')
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
            $listenerAuthorityEvidence = [ordered]@{
                exact_argument = @($typedArguments | Where-Object { [string]$_ -ceq "--remote-debugging-port=$typedPort" }).Count -eq 1
                no_type_argument = @($typedArguments | Where-Object { ([string]$_).StartsWith('--type=', [StringComparison]::Ordinal) }).Count -eq 0
                owner_verified = [string]$typedAuthority.state -ceq 'authority_ready'
                raw_absent = $true
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
            $actualEmptyListenerSnapshot = New-DesktopSnapshotEnvelope -Kind 'listeners' -Items @()
            Assert-Condition ([string]$actualEmptyListenerSnapshot.kind -ceq 'listeners') 'Fixture listener no-match control returned the wrong envelope kind.'
            Assert-Condition (@($actualEmptyListenerSnapshot.items).Count -eq 0) 'Fixture listener no-match control did not return an empty typed envelope.'
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
                    return (New-DesktopCdpProbeRecord -State ([string]$definition.page_state) -PageUrl $null -Port $typedPort)
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
                probe_timeout = @{ Script = { param($ProbeArgument) Start-Sleep -Milliseconds 400; $true }; Argument = $null }
            }
            $syntheticDiagnosis = Get-DesktopTeardownDiagnosis -UserDataFolder $diagnosisRoot -ProbeTable $syntheticProbeTable -ProbeTimeoutMilliseconds 100 -TotalBudgetMilliseconds 5000
            Assert-Condition ([string]$syntheticDiagnosis.probe_true -ceq 'true') 'The immediate true teardown probe did not return true.'
            Assert-Condition ([string]$syntheticDiagnosis.probe_false -ceq 'false') 'The immediate false teardown probe did not return false.'
            Assert-Condition ([string]$syntheticDiagnosis.probe_error -ceq 'error:io') 'The throwing teardown probe did not return error:io.'
            Assert-Condition ([string]$syntheticDiagnosis.probe_timeout -ceq 'error:timeout') 'The sleeping teardown probe did not return error:timeout.'

            $missingDiagnosisUserData = Join-Path $diagnosisRoot 'missing-user-data'
            $realProbeTable = New-DesktopTeardownProbeTable -UserDataFolder $missingDiagnosisUserData -RootProcessId $PID -DebugPort 49161 -ProcessSnapshotItems @()
            $expectedProbeKeys = @(
                'desktop_probe_runtime_registry',
                'desktop_probe_runtime_binary',
                'desktop_probe_profile_dir',
                'desktop_probe_init_trace',
                'desktop_probe_port_file_redirected',
                'desktop_probe_port_file_fallback',
                'desktop_probe_webview_process_present',
                'desktop_probe_debug_arg'
            )
            Assert-Condition ([string]::Join(',', @($realProbeTable.Keys)) -ceq [string]::Join(',', $expectedProbeKeys)) 'The teardown probe table did not preserve the eight-key contract.'
            $fixtureDomainProbeTable = [ordered]@{}
            foreach ($probeKey in $expectedProbeKeys) {
                $fixtureDomainProbeTable[$probeKey] = @{ Script = { param($ProbeArgument) $true }; Argument = $null }
            }
            $fixtureDomainDiagnosis = Get-DesktopTeardownDiagnosis -UserDataFolder $missingDiagnosisUserData -ProbeTable $fixtureDomainProbeTable -ProbeTimeoutMilliseconds 1000 -TotalBudgetMilliseconds 10000
            foreach ($value in @($fixtureDomainDiagnosis.Values)) {
                Assert-Condition ([string]$value -cmatch '^(?:true|false|unknown|error:[a-z]+)$') 'A teardown probe returned a value outside the four-value domain.'
            }
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
                    $diagnosisGuard.value = Get-DesktopTeardownDiagnosis -UserDataFolder $diagnosisRoot -ProbeTable $invalidProbeTable -ProbeTimeoutMilliseconds 100 -TotalBudgetMilliseconds 500
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
    $result = Invoke-SelfTest
    if ($Json) {
        $result | ConvertTo-Json -Depth 10 -Compress
    } else {
        [pscustomobject]$result
    }
    exit 0
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
if ($Json) {
    $result | ConvertTo-Json -Depth 10 -Compress
} else {
    [pscustomobject]$result
}
