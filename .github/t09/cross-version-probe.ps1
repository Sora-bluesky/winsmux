[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Npm', 'Direct')][string]$Route,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceCommit,
    [Parameter(Mandatory = $true)][string]$CandidateDirectory,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ReferenceTarballSha256,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$OldVersion = '0.36.38'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8

if ($env:CI -ne 'true' -or $env:GITHUB_ACTIONS -ne 'true' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'This probe installs into the real user profile and User PATH. Run it only on a disposable GitHub runner.'
}

$utf8 = [Text.UTF8Encoding]::new($false)
$repoRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$candidateRoot = [IO.Path]::GetFullPath($CandidateDirectory)
$outRoot = [IO.Path]::GetFullPath($OutputRoot)
$work = Join-Path $env:RUNNER_TEMP ('t09-work-' + $Route)
foreach ($fresh in @($outRoot, $work)) {
    if (Test-Path -LiteralPath $fresh) { throw "Probe root must not exist before the run: $fresh" }
    [void][IO.Directory]::CreateDirectory($fresh)
}
$logPath = Join-Path $outRoot 'probe.log'
$resultPath = Join-Path $outRoot 'result.json'
$candidateVersion = ([IO.File]::ReadAllText((Join-Path $repoRoot 'VERSION'))).Trim()
$oldTag = 'v' + $OldVersion
$candidateTag = 'v' + $candidateVersion

$pwsh = (Get-Command pwsh -CommandType Application -TotalCount 1).Source
$node = (Get-Command node -CommandType Application -TotalCount 1).Source
$npm = (Get-Command npm.cmd -CommandType Application -TotalCount 1).Source
$native = Join-Path $HOME '.local\bin\winsmux.exe'
$wrapper = Join-Path $HOME '.winsmux\bin\winsmux.cmd'
$owner = Join-Path $HOME '.winsmux\install-owner.json'
$profileManifest = Join-Path $HOME '.winsmux\install-profile.json'
$versionFile = Join-Path $HOME '.winsmux\version'
$pendingMarker = Join-Path $HOME '.local\bin\winsmux.install.pending.json'
$settings = Join-Path $HOME '.winsmux.conf'
$project = Join-Path $HOME '.winsmux\projects\t09\project.json'
$unknown = Join-Path $HOME '.winsmux\t09-unknown.json'
$fragment = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\winsmux\winsmux.json'

# Public entry for the old release: no installer E2E switch, so it reads only its own published sources.
$oldEnvironment = @{
    WINSMUX_INSTALL_E2E = $null; WINSMUX_INSTALL_SOURCE_REF = $null; WINSMUX_INSTALL_E2E_RELEASE_TAG = $null
    WINSMUX_INSTALL_E2E_GITHUB_ACCESS = $null; WINSMUX_INSTALL_STATE_ROOT = $null
    WINSMUX_RELEASE_TAG = $oldTag; WINSMUX_INSTALL_PROFILE = 'full'
}
# Same candidate selection as scripts/test-install-e2e.ps1 on a GitHub runner with -CandidateDirectory.
$candidateEnvironment = @{
    WINSMUX_INSTALL_E2E = 'true'; WINSMUX_INSTALL_SOURCE_REF = $SourceCommit; WINSMUX_INSTALL_E2E_RELEASE_TAG = $null
    WINSMUX_INSTALL_E2E_GITHUB_ACCESS = $null; WINSMUX_INSTALL_STATE_ROOT = $null
    WINSMUX_RELEASE_TAG = $candidateTag; WINSMUX_INSTALL_PROFILE = 'full'
}

$result = [ordered]@{
    schema = 't09-cross-version-probe/v1'
    route = $Route
    state = 'running'
    outcome = $null
    passed = $false
    failure = $null
    home = $HOME
    old = [ordered]@{ version = $OldVersion; release_tag = $oldTag; entry = $null; package = $null }
    candidate = [ordered]@{ source_commit = $SourceCommit; version = $candidateVersion; release_tag = $candidateTag; assets = @(); fixture = $null; npm = $null }
    update = [ordered]@{ entry = $null; exit = $null; rejected_at = $null; rejection_lines = @(); pending_marker_after = $null }
    observations = [ordered]@{}
    snapshots = [ordered]@{}
    checks = [Collections.Generic.List[object]]::new()
    commands = [Collections.Generic.List[object]]::new()
}

function Save-Result { [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 14), $utf8) }

function Get-FileDigest([string]$Path) {
    if ([IO.File]::Exists($Path)) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    return $null
}

function Get-TreeDigest([string]$Path) {
    if (-not [IO.Directory]::Exists($Path)) { return $null }
    $rows = [ordered]@{}
    foreach ($file in @([IO.Directory]::EnumerateFiles($Path, '*', [IO.SearchOption]::AllDirectories) | Sort-Object)) {
        $rows[[IO.Path]::GetRelativePath($Path, $file).Replace('\', '/')] = Get-FileDigest $file
    }
    return $rows
}

function Read-JsonFile([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable) } catch { return @{ unparsable = $_.Exception.Message } }
}

function Get-Snapshot {
    return [ordered]@{
        user_data = [ordered]@{ settings = Get-FileDigest $settings; project = Get-FileDigest $project; unknown = Get-FileDigest $unknown }
        support = [ordered]@{
            local_bin = Get-TreeDigest (Join-Path $HOME '.local\bin')
            winsmux_dir = Get-TreeDigest (Join-Path $HOME '.winsmux')
            ps_profile_all_hosts = Get-FileDigest ([string]$PROFILE.CurrentUserAllHosts)
            ps_profile_current_host = Get-FileDigest ([string]$PROFILE.CurrentUserCurrentHost)
            terminal_fragment = Get-FileDigest $fragment
        }
        user_path = [Environment]::GetEnvironmentVariable('Path', 'User')
    }
}

function Get-SupportState {
    $receipt = Read-JsonFile $owner
    return [ordered]@{
        native_present = [IO.File]::Exists($native)
        wrapper_present = [IO.File]::Exists($wrapper)
        owner_receipt_present = [IO.File]::Exists($owner)
        owner_receipt_sha256 = Get-FileDigest $owner
        owner_receipt_schema = if ($receipt -and $receipt.ContainsKey('schema')) { [string]$receipt.schema } else { $null }
        owner_receipt_files = if ($receipt -and $receipt.ContainsKey('files')) { @($receipt.files).Count } else { $null }
        install_profile = Read-JsonFile $profileManifest
        version_file = if ([IO.File]::Exists($versionFile)) { [IO.File]::ReadAllText($versionFile).Trim() } else { $null }
        pending_marker_present = [IO.File]::Exists($pendingMarker)
    }
}

function Invoke-Probe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $work,
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 900
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    if ([IO.Path]::GetExtension($FilePath) -ieq '.cmd') {
        $info.FileName = $env:ComSpec
        $parts = @(@($FilePath) + @($Arguments) | ForEach-Object { '"' + ([string]$_).Replace('"', '""') + '"' })
        $info.Arguments = '/d /s /c "' + ($parts -join ' ') + '"'
    } else {
        $info.FileName = $FilePath
        foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    }
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) { [void]$info.Environment.Remove($key) } else { $info.Environment[$key] = [string]$Environment[$key] }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $exitCode = $null
    $timedOut = $false
    $process = [Diagnostics.Process]::Start($info)
    try {
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            $process.Kill($true)
            $process.WaitForExit()
        } else {
            $exitCode = $process.ExitCode
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
    $seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
    $header = "===== $Name | exit=$exitCode | timed_out=$timedOut | ${seconds}s`n$FilePath $($Arguments -join ' ')`n"
    [IO.File]::AppendAllText($logPath, $header + "--- stdout`n" + $stdout + "`n--- stderr`n" + $stderr + "`n", $utf8)
    Write-Host $header.TrimEnd()
    $result.commands.Add([ordered]@{ name = $Name; file_path = $FilePath; arguments = @($Arguments); exit = $exitCode; timed_out = $timedOut; seconds = $seconds })
    Save-Result
    return [pscustomobject]@{ Name = $Name; ExitCode = $exitCode; StdOut = $stdout.Trim(); StdErr = $stderr.Trim(); Combined = ($stdout + "`n" + $stderr).Trim() }
}

function Add-Check([string]$Id, $Passed, $Expected, $Observed) {
    $result.checks.Add([ordered]@{ id = $Id; passed = $Passed; expected = $Expected; observed = $Observed })
    Save-Result
}

function Get-VersionProbe([string]$Prefix) {
    $probe = [ordered]@{}
    foreach ($row in @(
        @{ key = 'native_raw'; file = $native; args = @('-V') },
        @{ key = 'wrapper_version'; file = $wrapper; args = @('version') },
        @{ key = 'wrapper_raw'; file = $wrapper; args = @('-V') }
    )) {
        if (-not [IO.File]::Exists($row.file)) { $probe[$row.key] = [ordered]@{ present = $false; exit = $null; stdout = $null }; continue }
        $run = Invoke-Probe -Name "$Prefix-$($row.key)" -FilePath $row.file -Arguments $row.args -TimeoutSeconds 120
        $probe[$row.key] = [ordered]@{ present = $true; exit = $run.ExitCode; stdout = $run.StdOut }
    }
    return $probe
}

function Test-VersionLine($Probe, [string]$Version) {
    return ($Probe.present -and $Probe.exit -eq 0 -and [string]$Probe.stdout -ceq "winsmux $Version")
}

function Get-RejectionLines([string]$Text) {
    return @($Text -split "`r?`n" | Where-Object { $_ -match '(?i)error|fail|refus|reject|invalid|cannot|preserved|denied|throw|exception' } | Select-Object -First 40)
}

$exitCode = 0
try {
    $result.candidate.assets = @(Get-ChildItem -LiteralPath $candidateRoot -File | Sort-Object Name | ForEach-Object {
        [ordered]@{ name = $_.Name; bytes = $_.Length; sha256 = Get-FileDigest $_.FullName }
    })
    $fixtureRun = Invoke-Probe -Name 'candidate-fixture' -FilePath $node -WorkingDirectory $repoRoot -Arguments @(
        (Join-Path $repoRoot 'scripts/prepare-install-e2e-fixture.mjs'), $candidateRoot, $SourceCommit, $candidateVersion, (Join-Path $work 'fixture'))
    if ($fixtureRun.ExitCode -ne 0) { throw "Candidate transport preparation failed: $($fixtureRun.Combined)" }
    $fixture = $fixtureRun.StdOut | ConvertFrom-Json -AsHashtable
    if ($fixture.schema -cne 'install-e2e-fixture/v1' -or -not $fixture.product_body_unchanged -or $fixture.public_release_acquisition_proven -or $fixture.source_commit -cne $SourceCommit) {
        throw 'Invalid private candidate transport receipt.'
    }
    $result.candidate.fixture = [ordered]@{
        original_installer_sha256 = $fixture.original_installer_sha256; fixture_installer_sha256 = $fixture.fixture_installer_sha256
        transport_sha256 = $fixture.transport_sha256; candidate_receipt_sha256 = $fixture.candidate_receipt_sha256; product_body_unchanged = $fixture.product_body_unchanged
    }

    $fixtureTarball = $null
    if ($Route -ceq 'Npm') {
        $stage = Join-Path $work 'stage'
        $staged = Invoke-Probe -Name 'candidate-npm-stage' -FilePath $node -WorkingDirectory $repoRoot -Arguments @((Join-Path $repoRoot 'scripts/stage-npm-release.mjs'), '--version', $candidateVersion, '--out', $stage)
        if ($staged.ExitCode -ne 0) { throw 'Candidate npm stage failed.' }
        $packs = [ordered]@{}
        foreach ($kind in @('pristine', 'fixture')) {
            if ($kind -ceq 'fixture') { Copy-Item -LiteralPath $fixture.installer -Destination (Join-Path $stage 'install.ps1') -Force }
            $destination = Join-Path $work "$kind-package"
            [void][IO.Directory]::CreateDirectory($destination)
            $packed = Invoke-Probe -Name "candidate-npm-pack-$kind" -FilePath $npm -WorkingDirectory $stage -Arguments @('pack', '--json', '--pack-destination', $destination)
            if ($packed.ExitCode -ne 0) { throw "Candidate npm pack ($kind) failed." }
            $packs[$kind] = Join-Path $destination (($packed.StdOut | ConvertFrom-Json)[0].filename)
        }
        $fixtureTarball = $packs.fixture
        $pristineSha = Get-FileDigest $packs.pristine
        $result.candidate.npm = [ordered]@{ pristine_tarball_sha256 = $pristineSha; reference_tarball_sha256 = $ReferenceTarballSha256; fixture_tarball_sha256 = Get-FileDigest $fixtureTarball }
        Add-Check 'candidate-npm-pristine-tarball-is-reference' ($pristineSha -ceq $ReferenceTarballSha256) $ReferenceTarballSha256 $pristineSha
    }

    $npmShim = $null
    if ($Route -ceq 'Npm') {
        $result.old.entry = "npm install --global winsmux@$OldVersion; winsmux install --profile full"
        $oldPackage = Invoke-Probe -Name 'old-npm-package-install' -FilePath $npm -Arguments @('install', '--global', "winsmux@$OldVersion") -Environment $oldEnvironment
        if ($oldPackage.ExitCode -ne 0) { throw "npm install of winsmux@$OldVersion failed." }
        $prefix = (Invoke-Probe -Name 'npm-global-prefix' -FilePath $npm -Arguments @('prefix', '--global')).StdOut.Trim()
        $npmShim = Join-Path $prefix 'winsmux.cmd'
        $packageRoot = Join-Path $prefix 'node_modules\winsmux'
        $result.old.package = [ordered]@{ prefix = $prefix; package_json = Read-JsonFile (Join-Path $packageRoot 'package.json'); install_ps1_sha256 = Get-FileDigest (Join-Path $packageRoot 'install.ps1') }
        $oldInstall = Invoke-Probe -Name 'old-install' -FilePath $npmShim -Arguments @('install', '--profile', 'full') -Environment $oldEnvironment
    } else {
        $directUrl = "https://raw.githubusercontent.com/Sora-bluesky/winsmux/$oldTag/install.ps1"
        $result.old.entry = "`$env:WINSMUX_RELEASE_TAG='$oldTag'; irm $directUrl | iex"
        $served = Join-Path $work 'old-direct-install.ps1'
        Invoke-WebRequest -Uri $directUrl -OutFile $served
        $result.old.package = [ordered]@{ url = $directUrl; served_install_ps1_sha256 = Get-FileDigest $served }
        $oldInstall = Invoke-Probe -Name 'old-install' -FilePath $pwsh -Environment $oldEnvironment -Arguments @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "`$ErrorActionPreference = 'Stop'; irm '$directUrl' | iex")
    }
    $result.observations.old_install_exit = $oldInstall.ExitCode
    $result.observations.old_support = Get-SupportState
    $oldVersions = Get-VersionProbe 'old'
    $result.observations.old_versions = $oldVersions
    Add-Check 'old-install-exit-zero' ($oldInstall.ExitCode -eq 0) 0 $oldInstall.ExitCode
    Add-Check 'old-native-runs' (Test-VersionLine $oldVersions.native_raw $OldVersion) "winsmux $OldVersion" $oldVersions.native_raw
    if ($oldInstall.ExitCode -ne 0 -or -not [IO.File]::Exists($native)) { throw "The $OldVersion public install did not complete; cross-version update cannot be observed." }

    $result.observations.old_default_settings_sha256 = Get-FileDigest $settings
    $existing = if ([IO.File]::Exists($settings)) { [IO.File]::ReadAllBytes($settings) } else { [byte[]]@() }
    [IO.File]::WriteAllBytes($settings, [byte[]]($existing + $utf8.GetBytes("`n# t09 user edit after the $OldVersion install`n")))
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($project))
    [IO.File]::WriteAllText($project, '{"t09":"protected-project"}', $utf8)
    [IO.File]::WriteAllText($unknown, 't09 unknown user bytes', $utf8)
    $before = Get-Snapshot
    $result.snapshots.before_update = $before

    if ($Route -ceq 'Npm') {
        $result.update.entry = "npm install --global <candidate tarball>; winsmux update --profile full"
        $candidatePackage = Invoke-Probe -Name 'candidate-npm-package-install' -FilePath $npm -Arguments @('install', '--global', $fixtureTarball) -Environment $candidateEnvironment
        $result.observations.candidate_package_json = Read-JsonFile (Join-Path $prefix 'node_modules\winsmux\package.json')
        if ($candidatePackage.ExitCode -ne 0) {
            $update = $candidatePackage
            $result.update.rejected_at = 'npm-package-install'
        } else {
            $update = Invoke-Probe -Name 'candidate-update' -FilePath $npmShim -Arguments @('update', '--profile', 'full') -Environment $candidateEnvironment
        }
    } else {
        $result.update.entry = "pwsh -File <candidate install.ps1> update -ReleaseTag $candidateTag -InstallProfile full"
        $update = Invoke-Probe -Name 'candidate-update' -FilePath $pwsh -Environment $candidateEnvironment -Arguments @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fixture.installer, 'update', '-ReleaseTag', $candidateTag, '-InstallProfile', 'full')
    }
    $result.update.exit = $update.ExitCode
    $result.update.pending_marker_after = [IO.File]::Exists($pendingMarker)
    $after = Get-Snapshot
    $result.snapshots.after_update = $after
    $result.observations.after_support = Get-SupportState
    $afterVersions = Get-VersionProbe 'after'
    $result.observations.after_versions = $afterVersions
    if ($Route -ceq 'Npm') {
        $shimVersion = Invoke-Probe -Name 'after-npm-shim-version' -FilePath $npmShim -Arguments @('version') -TimeoutSeconds 120
        $result.observations.after_npm_shim_version = [ordered]@{ exit = $shimVersion.ExitCode; stdout = $shimVersion.StdOut }
    }

    foreach ($key in @('settings', 'project', 'unknown')) {
        Add-Check "user-data-$key-preserved" ($before.user_data[$key] -ceq $after.user_data[$key]) $before.user_data[$key] $after.user_data[$key]
    }
    if ($update.ExitCode -eq 0) {
        $result.outcome = 'updated'
        Add-Check 'updated-native-version' (Test-VersionLine $afterVersions.native_raw $candidateVersion) "winsmux $candidateVersion" $afterVersions.native_raw
        Add-Check 'updated-wrapper-version' (Test-VersionLine $afterVersions.wrapper_version $candidateVersion) "winsmux $candidateVersion" $afterVersions.wrapper_version
        Add-Check 'updated-wrapper-raw-version' (Test-VersionLine $afterVersions.wrapper_raw $candidateVersion) "winsmux $candidateVersion" $afterVersions.wrapper_raw
        Add-Check 'updated-owner-receipt-present' ([IO.File]::Exists($owner)) $true ([IO.File]::Exists($owner))
        Add-Check 'updated-no-pending-marker' (-not $result.update.pending_marker_after) $false $result.update.pending_marker_after
        Add-Check 'user-path-after-update' $null 'recorded only' ([ordered]@{ before = $before.user_path; after = $after.user_path })
    } else {
        $result.outcome = 'rejected'
        if (-not $result.update.rejected_at) { $result.update.rejected_at = 'candidate-update' }
        $result.update.rejection_lines = @(Get-RejectionLines $update.Combined)
        Add-Check 'rejected-old-native-still-runs' (Test-VersionLine $afterVersions.native_raw $OldVersion) "winsmux $OldVersion" $afterVersions.native_raw
        Add-Check 'rejected-old-wrapper-still-runs' ($afterVersions.wrapper_version.present -and $afterVersions.wrapper_version.exit -eq 0) 'exit 0' $afterVersions.wrapper_version
        Add-Check 'rejected-old-wrapper-raw-still-runs' (Test-VersionLine $afterVersions.wrapper_raw $OldVersion) "winsmux $OldVersion" $afterVersions.wrapper_raw
        $supportBefore = $before.support | ConvertTo-Json -Depth 8 -Compress
        $supportAfter = $after.support | ConvertTo-Json -Depth 8 -Compress
        Add-Check 'rejected-support-state-unchanged' ($supportBefore -ceq $supportAfter) 'support snapshot equal' ([ordered]@{ equal = ($supportBefore -ceq $supportAfter) })
        Add-Check 'rejected-user-path-unchanged' ($before.user_path -ceq $after.user_path) $before.user_path $after.user_path
        Add-Check 'rejected-no-pending-marker' (-not $result.update.pending_marker_after) $false $result.update.pending_marker_after
    }
    $scored = @($result.checks | Where-Object { $null -ne $_.passed })
    $result.passed = ($scored.Count -gt 0 -and @($scored | Where-Object { -not $_.passed }).Count -eq 0)
    $result.state = 'complete'
} catch {
    $result.state = 'harness_error'
    $result.failure = [string]$_.Exception.Message
    $exitCode = 1
} finally {
    Save-Result
    Write-Host ($result | ConvertTo-Json -Depth 14)
}
exit $exitCode
