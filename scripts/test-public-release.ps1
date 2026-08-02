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
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try {
            $process.Kill($true)
        } catch {
        }
        throw "Process timed out after $TimeoutSeconds seconds: $FilePath"
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{
        exit_code = $process.ExitCode
        stdout = $stdout
        stderr = $stderr
    }
}

function Start-OwnedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [hashtable]$Environment
    )

    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FilePath
    $info.UseShellExecute = $false
    foreach ($name in @($Environment.Keys)) {
        $info.Environment[[string]$name] = [string]$Environment[$name]
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    Assert-Condition $process.Start() "Unable to start owned process: $FilePath"
    return $process
}

function Stop-OwnedProcessTree {
    param([Diagnostics.Process]$RootProcess)

    if ($null -eq $RootProcess) {
        return
    }
    try {
        if (-not $RootProcess.HasExited) {
            $RootProcess.Kill($true)
            $stopped = $RootProcess.WaitForExit(15000)
            Assert-Condition $stopped "Timed out while stopping owned process tree $($RootProcess.Id)."
        }
    } catch {
        throw "Unable to stop owned process tree $($RootProcess.Id): $($_.Exception.Message)"
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

    Assert-Condition ($Result.exit_code -eq 0) "Core --version exited with $($Result.exit_code)."
    Assert-Condition ([string]::IsNullOrWhiteSpace([string]$Result.stderr)) "Core --version wrote stderr: $($Result.stderr)"
    Assert-Condition ([string]$Result.stdout.Trim() -ceq "$ExpectedProgramName $ExpectedVersion") "Core --version returned '$([string]$Result.stdout.Trim())'."
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

    Assert-Condition ($Result.exit_code -eq 0) "npm package help exited with $($Result.exit_code)."
    Assert-Condition ([string]::IsNullOrWhiteSpace([string]$Result.stderr)) "npm package help wrote stderr: $($Result.stderr)"
    $output = [string]$Result.stdout
    foreach ($token in @('install', 'update', 'uninstall', 'version', 'help')) {
        Assert-Condition ($output -match "(?m)^\s+$([regex]::Escape($token))\s+") "npm package help omitted action '$token'."
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
        Invoke-NativeProcess -FilePath $expectedUninstaller -ArgumentList $arguments -Environment $Environment -TimeoutSeconds 180
    } else {
        & $ProcessInvoker $expectedUninstaller $arguments $Environment
    }
    Assert-Condition ($uninstall.exit_code -eq 0) "Desktop uninstaller exited with $($uninstall.exit_code): $($uninstall.stderr)"

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

    return Invoke-Retry -Description 'packaged WebView2 observation' -Operation {
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
    $result = Invoke-NativeProcess -FilePath $assetPaths[$executedAssetName] -ArgumentList @('--version') -Environment $environment -TimeoutSeconds 30
    Assert-CoreVersionResult -Result $result -ExpectedProgramName $expectedProgramName -ExpectedVersion $Version
    return [ordered]@{
        asset = $executedAssetName
        sha256 = $expectedHashes[$executedAssetName]
        version = $Version
    }
}

function Invoke-NpmCli {
    param(
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$NpmCliPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][hashtable]$Environment,
        [int]$TimeoutSeconds = 90
    )

    $allArguments = @($NpmCliPath) + @($Arguments)
    return Invoke-NativeProcess -FilePath $NodePath -ArgumentList $allArguments -Environment $Environment -TimeoutSeconds $TimeoutSeconds
}

function Resolve-NpmPathPrecedenceToolchain {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$NodeCandidates
    )

    $candidates = @($NodeCandidates)
    Assert-Condition ($candidates.Count -ge 1) 'No Node application was found on PATH.'
    $nodePath = [string]$candidates[0].Source
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($nodePath)) 'The first PATH-precedence Node application did not expose Source.'
    Assert-Condition (Test-Path -LiteralPath $nodePath -PathType Leaf) "The first PATH-precedence Node application was not found: $nodePath"

    $npmCliPath = Join-Path (Split-Path -Parent $nodePath) 'node_modules\npm\bin\npm-cli.js'
    Assert-Condition (Test-Path -LiteralPath $npmCliPath -PathType Leaf) "npm CLI was not found next to the first PATH-precedence Node application: $npmCliPath"
    return [pscustomobject]@{
        node_path = $nodePath
        npm_cli_path = $npmCliPath
    }
}

function Invoke-NpmSmoke {
    param([Parameter(Mandatory)][string]$Root)

    $nodeCandidates = @(Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue)
    $npmToolchain = Resolve-NpmPathPrecedenceToolchain -NodeCandidates $nodeCandidates
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
        $result = Invoke-NpmCli -NodePath $node -NpmCliPath $npmCli -Arguments @(
            'view',
            "winsmux@$Version",
            'version',
            'dist.integrity',
            '--json',
            '--registry=https://registry.npmjs.org/'
        ) -Environment $npmEnvironment
        Assert-Condition ($result.exit_code -eq 0) "npm view failed: $($result.stderr)"
        $metadata = $result.stdout | ConvertFrom-Json -Depth 20
        Assert-NpmMetadata -Metadata $metadata -ExpectedVersion $Version
        return $metadata
    }
    $integrity = Get-NpmIntegrity -Metadata $metadataResult

    $packRecord = Invoke-Retry -Description 'npm public tarball' -Operation {
        $packResult = Invoke-NpmCli -NodePath $node -NpmCliPath $npmCli -Arguments @(
            'pack',
            "winsmux@$Version",
            '--pack-destination',
            $Root,
            '--json',
            '--registry=https://registry.npmjs.org/'
        ) -Environment $npmEnvironment -TimeoutSeconds 120
        Assert-Condition ($packResult.exit_code -eq 0) "npm pack failed: $($packResult.stderr)"
        $packData = @($packResult.stdout | ConvertFrom-Json -Depth 20)
        Assert-Condition ($packData.Count -eq 1) "npm pack returned $($packData.Count) package records."
        $packedIntegrity = [string](Get-ObjectPropertyValue -Object $packData[0] -Name 'integrity')
        Assert-Condition ($packedIntegrity -ceq $integrity) "npm tarball integrity '$packedIntegrity' does not match registry metadata '$integrity'."
        return $packData[0]
    }
    $filename = [string](Get-ObjectPropertyValue -Object $packRecord -Name 'filename')
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($filename)) 'npm pack did not report a tarball filename.'
    $tarballPath = Get-CanonicalPath -Path (Join-Path $Root $filename)
    Assert-Condition (Test-PathInsideRoot -Path $tarballPath -Root $Root) 'npm tarball escaped the owned root.'
    Assert-Condition (Test-Path -LiteralPath $tarballPath -PathType Leaf) "npm tarball was not created: $tarballPath"

    $extractRoot = Join-Path $Root 'unpacked'
    New-Item -ItemType Directory -Path $extractRoot | Out-Null
    $tar = (Get-Command tar.exe -CommandType Application -ErrorAction Stop).Source
    $listing = Invoke-NativeProcess -FilePath $tar -ArgumentList @('-tf', $tarballPath)
    Assert-Condition ($listing.exit_code -eq 0) "Unable to list public npm tarball: $($listing.stderr)"
    $archiveEntries = @($listing.stdout -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-SafeNpmArchiveEntries -Entries $archiveEntries
    $extract = Invoke-NativeProcess -FilePath $tar -ArgumentList @('-xf', $tarballPath, '-C', $extractRoot)
    Assert-Condition ($extract.exit_code -eq 0) "Unable to extract public npm tarball: $($extract.stderr)"
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

    $help = Invoke-NativeProcess -FilePath $node -ArgumentList @($entryPath, 'help') -Environment $npmEnvironment -TimeoutSeconds 60
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
    $pageUrl = ''
    $desktopFailure = $null
    $cleanupFailure = $null
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
        $install = Invoke-NativeProcess -FilePath $setupPath -ArgumentList @('/S', "/D=$installRoot") -Environment $childEnvironment -TimeoutSeconds 180
        Assert-Condition ($install.exit_code -eq 0) "Desktop installer exited with $($install.exit_code): $($install.stderr)"
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
        $pageUrl = Get-RemoteDebugPage -Port $port
    } catch {
        $desktopFailure = $_
    } finally {
        try {
            $operationErrorMessage = if ($null -eq $desktopFailure) { '' } else { $desktopFailure.Exception.Message }
            Invoke-DesktopCleanup -Context $context -Environment $childEnvironment -OperationErrorMessage $operationErrorMessage | Out-Null
        } catch {
            $cleanupFailure = $_
        }
    }
    if ($null -ne $desktopFailure) {
        if ($null -ne $cleanupFailure) {
            throw "Desktop public smoke failed: $($desktopFailure.Exception.Message); cleanup also failed: $($cleanupFailure.Exception.Message)"
        }
        throw $desktopFailure
    }
    if ($null -ne $cleanupFailure) {
        throw $cleanupFailure
    }
    Assert-DesktopLifecyclePhase -Context $context -ExpectedPhase 'clean'
    return [ordered]@{
        asset = $assetName
        sha256 = $expectedHash
        version = $Version
        page_url = $pageUrl
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
            Assert-Condition (Test-Throws {
                Resolve-NpmPathPrecedenceToolchain -NodeCandidates @()
            }) 'An empty Node application candidate collection was accepted.'
            $caseIds.Add('node_path_precedence_zero')

            $nodeFixtureRoot = Join-Path $root 'node-toolchains'
            $firstNodeRoot = Join-Path $nodeFixtureRoot 'first'
            $secondNodeRoot = Join-Path $nodeFixtureRoot 'second'
            $invalidFirstNodeRoot = Join-Path $nodeFixtureRoot 'invalid-first'
            $firstNpmRoot = Join-Path $firstNodeRoot 'node_modules\npm\bin'
            $secondNpmRoot = Join-Path $secondNodeRoot 'node_modules\npm\bin'
            New-Item -ItemType Directory -Path $firstNpmRoot, $secondNpmRoot, $invalidFirstNodeRoot | Out-Null
            $firstNode = Join-Path $firstNodeRoot 'node.exe'
            $secondNode = Join-Path $secondNodeRoot 'node.exe'
            $invalidFirstNode = Join-Path $invalidFirstNodeRoot 'node.exe'
            $firstNpmCli = Join-Path $firstNpmRoot 'npm-cli.js'
            $secondNpmCli = Join-Path $secondNpmRoot 'npm-cli.js'
            Set-Content -LiteralPath $firstNode, $secondNode, $invalidFirstNode, $firstNpmCli, $secondNpmCli -Value 'self-test toolchain' -Encoding ascii -NoNewline

            $oneNode = Resolve-NpmPathPrecedenceToolchain -NodeCandidates @([pscustomobject]@{ Source = $firstNode })
            Assert-Condition ($oneNode.node_path -ceq $firstNode) 'A single Node application candidate did not remain scalar.'
            Assert-Condition ($oneNode.npm_cli_path -ceq $firstNpmCli) 'A single Node application candidate did not bind its adjacent npm CLI.'
            $caseIds.Add('node_path_precedence_one')

            $multipleNodes = Resolve-NpmPathPrecedenceToolchain -NodeCandidates @(
                [pscustomobject]@{ Source = $firstNode },
                [pscustomobject]@{ Source = $secondNode }
            )
            Assert-Condition ($multipleNodes.node_path -ceq $firstNode) 'Multiple Node application candidates did not select the first PATH-precedence Source.'
            Assert-Condition ($multipleNodes.npm_cli_path -ceq $firstNpmCli) 'Multiple Node application candidates did not couple npm to the selected Node.'
            $caseIds.Add('node_path_precedence_multiple')

            Assert-Condition (Test-Throws {
                Resolve-NpmPathPrecedenceToolchain -NodeCandidates @(
                    [pscustomobject]@{ Source = $invalidFirstNode },
                    [pscustomobject]@{ Source = $secondNode }
                )
            }) 'A missing npm CLI beside the first Node fell back to a lower valid candidate.'
            $caseIds.Add('node_path_precedence_invalid_first')

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
