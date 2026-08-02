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
        [ValidateSet('timed_out', 'exit_nonzero', 'stderr_nonempty', 'parse_failed', 'content_invalid', 'exited', 'live_no_cdp')]
        [string]$State,
        [AllowNull()]$Result
    )

    $exitCode = 'none'
    $stdout = ''
    $stderr = ''
    if ($null -ne $Result) {
        $resultExitCode = Get-ObjectPropertyValue -Object $Result -Name 'exit_code'
        if ($null -ne $resultExitCode) {
            $exitCode = [string][int]$resultExitCode
        }
        $stdoutValue = Get-ObjectPropertyValue -Object $Result -Name 'stdout'
        $stderrValue = Get-ObjectPropertyValue -Object $Result -Name 'stderr'
        if ($null -ne $stdoutValue) { $stdout = [string]$stdoutValue }
        if ($null -ne $stderrValue) { $stderr = [string]$stderrValue }
    }
    $stdoutMetadata = Get-ChildOutputMetadata -Content $stdout
    $stderrMetadata = Get-ChildOutputMetadata -Content $stderr
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
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    Assert-Condition $process.Start() "Unable to start owned process: $FilePath"
    return [pscustomobject]@{
        process = $process
        stdout_task = $process.StandardOutput.ReadToEndAsync()
        stderr_task = $process.StandardError.ReadToEndAsync()
    }
}

function Get-OwnedProcessCapture {
    param([Parameter(Mandatory)]$OwnedProcess)

    $process = $OwnedProcess.process
    Assert-Condition $process.HasExited 'Owned process output was requested before the process became terminal.'
    $process.WaitForExit()
    return [pscustomobject]@{
        exit_code = [int]$process.ExitCode
        stdout = [string]$OwnedProcess.stdout_task.GetAwaiter().GetResult()
        stderr = [string]$OwnedProcess.stderr_task.GetAwaiter().GetResult()
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

function Get-RemoteDebugPage {
    param([Parameter(Mandatory)][int]$Port)

    $pages = @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 5)
    $page = @($pages | Where-Object {
        [string](Get-ObjectPropertyValue -Object $_ -Name 'type') -ceq 'page' -and
        -not [string]::IsNullOrWhiteSpace([string](Get-ObjectPropertyValue -Object $_ -Name 'url'))
    } | Select-Object -First 1)
    Assert-Condition ($page.Count -eq 1) 'WebView2 did not expose a page target.'
    $url = [string](Get-ObjectPropertyValue -Object $page[0] -Name 'url')
    Assert-ProductionPageUrl -Url $url
    return $url
}

function New-DesktopObservationRecord {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('exited', 'live_no_cdp', 'page_ready')]
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
        stdout_bytes = 0
        stdout_truncated = $false
        stderr_present = $false
        stderr_bytes = 0
        stderr_truncated = $false
    }
}

function Set-DesktopObservationCaptureMetadata {
    param(
        [Parameter(Mandatory)]$Observation,
        [Parameter(Mandatory)]$OwnedProcess
    )

    $capture = Get-OwnedProcessCapture -OwnedProcess $OwnedProcess
    $stdoutMetadata = Get-ChildOutputMetadata -Content ([string]$capture.stdout)
    $stderrMetadata = Get-ChildOutputMetadata -Content ([string]$capture.stderr)
    $Observation.stdout_present = [bool]$stdoutMetadata.present
    $Observation.stdout_bytes = [int]$stdoutMetadata.bytes
    $Observation.stdout_truncated = [bool]$stdoutMetadata.truncated
    $Observation.stderr_present = [bool]$stderrMetadata.present
    $Observation.stderr_bytes = [int]$stderrMetadata.bytes
    $Observation.stderr_truncated = [bool]$stderrMetadata.truncated
    return $capture
}

function Wait-DesktopProcessObservation {
    param(
        [Parameter(Mandatory)]$OwnedProcess,
        [Parameter(Mandatory)][int]$Port,
        [int]$MaxAttempts = $script:RetryCount,
        [scriptblock]$PageProbe,
        [scriptblock]$DelayInvoker
    )

    Assert-Condition ($MaxAttempts -ge 1) 'Desktop observation requires at least one attempt.'
    $process = $OwnedProcess.process
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt += 1) {
        $process.Refresh()
        if ($process.HasExited) {
            return (New-DesktopObservationRecord -State 'exited' -Port $Port -Attempts $attempt -ExitCode $process.ExitCode -PageUrl $null)
        }

        $pageUrl = $null
        try {
            $pageUrl = if ($null -eq $PageProbe) {
                Get-RemoteDebugPage -Port $Port
            } else {
                & $PageProbe $Port $attempt $OwnedProcess
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$pageUrl)) {
                Assert-ProductionPageUrl -Url ([string]$pageUrl)
            }
        } catch {
            $pageUrl = $null
        }

        $process.Refresh()
        if ($process.HasExited) {
            return (New-DesktopObservationRecord -State 'exited' -Port $Port -Attempts $attempt -ExitCode $process.ExitCode -PageUrl $null)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$pageUrl)) {
            return (New-DesktopObservationRecord -State 'page_ready' -Port $Port -Attempts $attempt -ExitCode $null -PageUrl ([string]$pageUrl))
        }
        if ($attempt -eq $MaxAttempts) {
            return (New-DesktopObservationRecord -State 'live_no_cdp' -Port $Port -Attempts $attempt -ExitCode $null -PageUrl $null)
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
        [Parameter(Mandatory)][int]$Port,
        [int]$MaxAttempts = $script:RetryCount,
        [scriptblock]$PageProbe,
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
    try {
        $observation = Wait-DesktopProcessObservation -OwnedProcess $Context.app_process -Port $Port -MaxAttempts $MaxAttempts -PageProbe $PageProbe -DelayInvoker $DelayInvoker
        if ([string]$observation.state -cne 'page_ready') {
            $pendingObservationFailure = $true
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
                stdout = $capture.stdout
                stderr = $capture.stderr
            }
            $message = Format-PublicChildProcessDiagnostic -Operation 'desktop_observer' -State ([string]$observation.state) -Result $diagnosticResult
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
    $runNpmProcess = {
        param(
            [Parameter(Mandatory, Position = 0)][string]$Operation,
            [Parameter(Mandatory, Position = 1)][string]$FilePath,
            [Parameter(Position = 2, ValueFromRemainingArguments = $true)][object[]]$ProcessArguments
        )

        if ($null -ne $ProcessInvoker) {
            return (& $ProcessInvoker $Operation $FilePath @($ProcessArguments))
        }
        $timeout = if ($Operation -ceq 'npm_pack') { 120 } else { 90 }
        return Invoke-PublicChildProcess -Operation $Operation -FilePath $FilePath -ArgumentList @($ProcessArguments) -Environment $npmEnvironment -TimeoutSeconds $timeout
    }.GetNewClosure()
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
        $result = & $runNpmProcess 'npm_view' $node $npmCli `
            'view',
            "winsmux@$Version",
            'version',
            'dist.integrity',
            '--json',
            '--registry=https://registry.npmjs.org/'
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
        $packResult = & $runNpmProcess 'npm_pack' $node $npmCli `
            'pack',
            "winsmux@$Version",
            '--pack-destination',
            $Root,
            '--json',
            '--registry=https://registry.npmjs.org/'
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
    $listing = & $runNpmProcess 'tar_list' $npmToolchain.tar_path -tf $tarballPath
    if ($listing.exit_code -ne 0) {
        throw (Format-PublicChildProcessDiagnostic -Operation 'tar_list' -State 'exit_nonzero' -Result $listing)
    }
    $archiveEntries = @($listing.stdout -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    try {
        Assert-SafeNpmArchiveEntries -Entries $archiveEntries
    } catch {
        throw (Format-PublicChildProcessDiagnostic -Operation 'tar_list' -State 'content_invalid' -Result $listing)
    }
    $extract = & $runNpmProcess 'tar_extract' $npmToolchain.tar_path -xf $tarballPath -C $extractRoot
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

    $help = & $runNpmProcess 'npm_help' $node $entryPath 'help'
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

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $listener.Stop()
        $webViewRoot = Join-Path $childRoot 'WebView2'
        $childEnvironment.WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$port --remote-allow-origins=*"
        $childEnvironment.WEBVIEW2_USER_DATA_FOLDER = $webViewRoot

        $context.app_process = Start-OwnedProcess -FilePath (Join-Path $installRoot 'winsmux-app.exe') -Environment $childEnvironment
        $observation = Invoke-DesktopLifecycleOperation -Context $context -Environment $childEnvironment -Port $port
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
            $pageReady = { param($Port, $Attempt, $OwnedProcess) return 'tauri://localhost/' }.GetNewClosure()
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
