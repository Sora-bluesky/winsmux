[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Npm', 'Direct', 'DefectDetection')]
    [string]$Route,
    [string]$RepositoryRoot = '',
    [string]$Version = '',
    [string]$ScratchRoot = '',
    [string]$SourceCommit = '',
    [string]$CandidateDirectory = '',
    [switch]$AllowRedirectedLocal,
    [string]$RedirectNonce = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Assert-WinsmuxInstalledEntryChain {
    param([AllowNull()][byte[]]$WrapperBytes, [AllowNull()][byte[]]$EntryBytes)
    foreach ($member in @(
        @{ Bytes=$WrapperBytes; Length=130; Sha256='d059bd613f24aa8ecbc64b0ca56751f87287d69ba71e8f4898859c0391d7428b' },
        @{ Bytes=$EntryBytes; Length=661; Sha256='6775b2aea0087e596b134857c0d680027efec7d95fb2c54f8624d80f69e3877f' }
    )) {
        if ($null -eq $member.Bytes -or $member.Bytes.Length -ne $member.Length -or
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($member.Bytes)).ToLowerInvariant() -cne $member.Sha256) {
            throw 'Installed CMD/entry chain does not bind the installed native and PowerShell Core entrypoints.'
        }
    }
}

$isGitHubRunner = $env:CI -eq 'true' -and $env:GITHUB_ACTIONS -eq 'true' -and
    -not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -and (Test-Path -LiteralPath $env:RUNNER_TEMP -PathType Container)
$isAuthorizedRedirect = $AllowRedirectedLocal -and -not [string]::IsNullOrWhiteSpace($RedirectNonce) -and
    [string]::Equals($RedirectNonce, [string]$env:WINSMUX_REDIRECT_NONCE, [System.StringComparison]::Ordinal)
if (-not $isGitHubRunner -and -not $isAuthorizedRedirect) {
    throw 'This installer E2E mutates user-scoped PATH. Run it through GitHub Actions, or use scripts/test-install-redirected.ps1 locally.'
}
if ($isGitHubRunner -and $SourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'GitHub Actions installer E2E requires -SourceCommit with the candidate 40-character commit SHA.'
}

$repoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw -Encoding UTF8).Trim()
}
if ($Version -notmatch '^\d+\.\d+\.\d+(?:\.[0-9]+)?(?:-[0-9A-Za-z.-]+)?$') {
    throw "Invalid release version: $Version"
}

function ConvertTo-WinsmuxBinaryVersion {
    param([Parameter(Mandatory = $true)][string]$ReleaseTag)

    $normalizedTag = $ReleaseTag.Trim().TrimStart('v', 'V')
    if ($normalizedTag -notmatch '^(?<binary>\d+\.\d+\.\d+)(?:\.\d+)?(?<suffix>-[0-9A-Za-z.-]+)?$') {
        throw "Unsupported winsmux release tag format: $ReleaseTag"
    }
    return $Matches['binary'] + $Matches['suffix']
}

function Get-GitBlobSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Treeish,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $tempPath = Join-Path ([IO.Path]::GetTempPath()) ("winsmux-install-blob-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    $process = $null
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $gitCommand = Get-Command git -CommandType Application -TotalCount 1 -ErrorAction Stop
        $gitPath = [string]$gitCommand.Source
        $startInfo.FileName = $gitPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @('-C', $repoRoot, 'cat-file', 'blob', "${Treeish}:$RelativePath")) {
            $startInfo.ArgumentList.Add($argument)
        }

        $process = [Diagnostics.Process]::Start($startInfo)
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stream = [IO.FileStream]::new($tempPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $process.StandardOutput.BaseStream.CopyTo($stream)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        $process.WaitForExit()
        [void]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git cat-file failed for ${Treeish}:$RelativePath with exit $($process.ExitCode)."
        }
        return (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction Stop
        }
    }
}

$profileVolume = $null
$ownRootVolume = $null
if ($isGitHubRunner) {
    $sourceTokens=$null;$sourceErrors=$null
    $sourceAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'install.ps1'),[ref]$sourceTokens,[ref]$sourceErrors)
    if($sourceErrors.Count){throw 'Current installer source cannot be parsed for volume measurement.'}
    foreach($name in @('Initialize-WinsmuxInstallPathInfo','Assert-WinsmuxInstallPath','Get-WinsmuxInstallVolume')) {
        $definitions=@($sourceAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
        if($definitions.Count -ne 1){throw 'Installer volume observation function is ambiguous.'}
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $profilePath=[IO.Path]::GetFullPath([string]$PROFILE.CurrentUserAllHosts)
    $profileParent=[IO.Path]::GetDirectoryName($profilePath)
    $profileVolume=Get-WinsmuxInstallVolume $profilePath File
    $scratch=if([string]::IsNullOrWhiteSpace($ScratchRoot)){Join-Path $profileParent ('winsmux-install-e2e-'+[Guid]::NewGuid().ToString('N'))}else{[IO.Path]::GetFullPath($ScratchRoot)}
    if([IO.Path]::GetDirectoryName($scratch) -ine $profileParent -or [IO.Path]::GetFileName($scratch) -cnotmatch '^winsmux-install-e2e-[a-f0-9]{32}$') {throw 'Disposable CI requires its own exact fresh GUID root beside the actual profile.'}
    if(Test-Path -LiteralPath $scratch){throw 'Own CI root already exists.'}
    $ownRootVolume=Get-WinsmuxInstallVolume $scratch Directory
    if($ownRootVolume -cne $profileVolume){throw 'CI HOME and the actual profile are on different physical volumes.'}
} else {
    $scratch=if([string]::IsNullOrWhiteSpace($ScratchRoot)) {
        $base=if($env:RUNNER_TEMP){$env:RUNNER_TEMP}else{[IO.Path]::GetTempPath()}
        Join-Path $base ('winsmux-install-e2e-'+[Guid]::NewGuid().ToString('N'))
    } else {[IO.Path]::GetFullPath($ScratchRoot)}
    if(Test-Path -LiteralPath $scratch){throw "Scratch root must not exist before the run: $scratch"}
}

$fixtureHome = Join-Path $scratch 'home'
$temp = Join-Path $scratch 'temp'
$localAppData = Join-Path $fixtureHome 'AppData\Local'
$appData = Join-Path $fixtureHome 'AppData\Roaming'
$npmPrefix = Join-Path $scratch 'npm-global'
$npmCache = Join-Path $scratch 'npm-cache'
@($fixtureHome, $temp, $localAppData, $appData, $npmPrefix, $npmCache) | ForEach-Object {
    New-Item -ItemType Directory -Path $_ -Force | Out-Null
}

$realRoot = Join-Path $scratch 'task880-real-lifecycle'
if($isGitHubRunner) {
    [void][IO.Directory]::CreateDirectory($realRoot)
    $resultOutput=Join-Path $realRoot 'result.json';$environmentOutput=Join-Path $realRoot 'environment.json'
    [IO.File]::WriteAllText($resultOutput,(ConvertTo-Json @{schema='task880-real-lifecycle/v1';passed=$false;state='not_run';route=$Route;source_commit=$SourceCommit;reason='Real entry assertions have not completed.'}),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($environmentOutput,(ConvertTo-Json @{source_commit=$SourceCommit;profile_volume_guid=$profileVolume;home_volume_guid=$ownRootVolume;os=[Environment]::OSVersion.VersionString;architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();powershell=$PSVersionTable.PSVersion.ToString();state='not_run'}),[Text.UTF8Encoding]::new($false))
    if(-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        [IO.File]::AppendAllText($env:GITHUB_OUTPUT,('task880_result_path='+$resultOutput+[Environment]::NewLine+'task880_environment_path='+$environmentOutput+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    }
}

$env:TEMP = $temp
$env:TMP = $temp
$env:npm_config_prefix = $npmPrefix
$env:npm_config_cache = $npmCache
$env:npm_config_userconfig = Join-Path $scratch 'npmrc'
$repositoryPreparationOpen = $true

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = $repoRoot,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 900,
        [switch]$IncludeGitHubAccess,
        [switch]$IncludeTargetInstallerBootstrapMarker,
        [switch]$RepositoryPreparation,
        [switch]$OmitReleaseTagSelection,
        [switch]$InterruptAfterRegistration
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    if ([System.IO.Path]::GetExtension($FilePath) -ieq '.cmd') {
        $startInfo.FileName = $env:ComSpec
        $commandParts = @($FilePath) + @($Arguments) | ForEach-Object {
            '"' + ([string]$_).Replace('"', '""') + '"'
        }
        $startInfo.Arguments = '/d /s /c "' + ($commandParts -join ' ') + '"'
    } else {
        $startInfo.FileName = $FilePath
        foreach ($argument in $Arguments) {
            $startInfo.ArgumentList.Add($argument)
        }
    }
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($RepositoryPreparation -and (-not $repositoryPreparationOpen -or $FilePath -notin @($node, $npm))) {
        throw 'Repository preparation is limited to Node/npm before installer HOME isolation.'
    }
    if (-not $RepositoryPreparation) {
    $startInfo.Environment.Clear()
    foreach ($name in @(
        'SystemRoot', 'WINDIR', 'ComSpec', 'PATH', 'PATHEXT', 'PSModulePath',
        'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'PROCESSOR_ARCHITECTURE', 'NUMBER_OF_PROCESSORS',
        'HOME', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'TEMP', 'TMP', 'LOCALAPPDATA', 'APPDATA',
        'npm_config_prefix', 'npm_config_cache', 'npm_config_userconfig',
        'WINSMUX_RELEASE_TAG', 'WINSMUX_INSTALL_PROFILE', 'WINSMUX_INSTALL_E2E',
        'WINSMUX_INSTALL_E2E_RELEASE_TAG', 'WINSMUX_INSTALL_SOURCE_REF',
        'WINSMUX_INSTALL_STATE_ROOT', 'GITHUB_ACTIONS'
    )) {
        if ($OmitReleaseTagSelection -and $name -in @('WINSMUX_RELEASE_TAG', 'WINSMUX_INSTALL_E2E_RELEASE_TAG')) {
            continue
        }
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $value) { $startInfo.Environment[$name] = $value }
    }
    }
    if ($IncludeGitHubAccess -and $isGitHubRunner) {
        $gitHubAccess = [Environment]::GetEnvironmentVariable('WINSMUX_INSTALL_E2E_GITHUB_ACCESS')
        if (-not [string]::IsNullOrWhiteSpace($gitHubAccess)) {
            $startInfo.Environment['WINSMUX_INSTALL_E2E_GITHUB_ACCESS'] = $gitHubAccess
        }
    }
    if ($IncludeTargetInstallerBootstrapMarker) {
        $startInfo.Environment['WINSMUX_INTERNAL_TARGET_INSTALLER_BOOTSTRAPPED'] = '1'
    }

    $captureWatch = [Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $interruption = $null
        if ($InterruptAfterRegistration) {
            if (-not $isGitHubRunner -or -not $candidateFixture -or $RepositoryPreparation) { throw 'Real lifecycle interruption requires the disposable private-candidate route.' }
            $bin = Join-Path $fixtureHome '.local/bin'
            $markerPath = Join-Path $bin 'winsmux.install.pending.json'
            $watcher = [IO.FileSystemWatcher]::new($bin)
            $watcher.IncludeSubdirectories = $true
            $watcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite
            $watcher.EnableRaisingEvents = $true
            $watch = [Diagnostics.Stopwatch]::StartNew()
            try {
                while (-not $process.HasExited -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
                    $journal = $null;$operation = ''; $journalBytes = $null
                    try {
                        if ([IO.File]::Exists($markerPath)) {
                            $markerValue = [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json -AsHashtable
                            if ($markerValue.operation_id -cnotmatch '^[a-f0-9]{32}$') { throw 'Unexpected own pending identity.' }
                            $operation = Join-Path $bin ('.winsmux-install-' + $markerValue.operation_id)
                            $journalBytes = [IO.File]::ReadAllBytes((Join-Path $operation 'recovery.json'))
                            $journal = [Text.UTF8Encoding]::new($false,$true).GetString($journalBytes) | ConvertFrom-Json -AsHashtable
                        }
                    } catch { $journal = $null }
                    if ($journal -and $journal.operation_id -ceq $markerValue.operation_id -and
                        $journal.registration.ContainsKey('user') -and $journal.registration.user.phase -ceq 'confirmed' -and
                        -not [IO.File]::Exists((Join-Path $operation 'committed'))) {
                        $interruption = @{ operation_id=$markerValue.operation_id; phase=$journal.registration.user.phase;
                            journal_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($journalBytes)).ToLowerInvariant();
                            controller_pid=$process.Id; controller_start_utc=$process.StartTime.ToUniversalTime().ToString('o'); committed_before=$false }
                        $process.Kill($true);$process.WaitForExit()
                        $interruption.operation_matches = $false
                        try { $afterMarker = [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json -AsHashtable; $interruption.operation_matches = $afterMarker.operation_id -ceq $interruption.operation_id } catch {}
                        $interruption.committed_after = [IO.File]::Exists((Join-Path $operation 'committed'))
                        break
                    }
                    $remaining = [Math]::Max(1,[int]($TimeoutSeconds * 1000 - $watch.Elapsed.TotalMilliseconds))
                    [void]$watcher.WaitForChanged([IO.WatcherChangeTypes]::All,$remaining)
                }
            } finally { $watcher.Dispose() }
        }
        $captureRemaining = [Math]::Max(0,[int]($TimeoutSeconds * 1000 - $captureWatch.Elapsed.TotalMilliseconds))
        if (-not $process.WaitForExit($captureRemaining)) {
            $process.Kill($true)
            $process.WaitForExit()
            $timedOutStdOut = $stdoutTask.GetAwaiter().GetResult()
            $timedOutStdErr = $stderrTask.GetAwaiter().GetResult()
            throw "Child process exceeded ${TimeoutSeconds}s and was terminated: $FilePath`n$timedOutStdOut`n$timedOutStdErr"
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [PSCustomObject]@{
            ExitCode = $process.ExitCode
            Interruption = $interruption
            FilePath = $FilePath
            Arguments = $Arguments
            WorkingDirectory = $WorkingDirectory
            StdOut = $stdout.Trim()
            StdErr = $stderr.Trim()
            Combined = ($stdout + [Environment]::NewLine + $stderr).Trim()
        }
    } finally {
        if (-not $process.HasExited) { $process.Kill($true);$process.WaitForExit() }
        $process.Dispose()
    }
}

$pwsh = (Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source
$node = (Get-Command node -ErrorAction Stop | Select-Object -First 1).Source
$npm = (Get-Command npm.cmd -ErrorAction Stop | Select-Object -First 1).Source
$installerPath = Join-Path $repoRoot 'install.ps1'
$candidateFixture = -not [string]::IsNullOrWhiteSpace($CandidateDirectory)
$fixtureProof = $null
if ($candidateFixture) {
    if ($Route -eq 'DefectDetection' -or -not [string]::IsNullOrWhiteSpace($env:WINSMUX_INSTALL_E2E_RELEASE_TAG)) {
        throw 'Private candidate fixture must not use a public release override or the historical defect route.'
    }
    $fixtureResult = Invoke-CapturedProcess -FilePath $node -RepositoryPreparation -Arguments @(
        (Join-Path $repoRoot 'scripts/prepare-install-e2e-fixture.mjs'),
        [IO.Path]::GetFullPath($CandidateDirectory), $SourceCommit, $Version, (Join-Path $scratch 'fixture')
    )
    if ($fixtureResult.ExitCode -ne 0) { throw "Candidate transport preparation failed:`n$($fixtureResult.Combined)" }
    $fixtureProof = $fixtureResult.StdOut | ConvertFrom-Json -Depth 20
    if ($fixtureProof.schema -cne 'install-e2e-fixture/v1' -or -not $fixtureProof.product_body_unchanged -or
        $fixtureProof.public_release_acquisition_proven -or $fixtureProof.source_commit -cne $SourceCommit) {
        throw 'Invalid private candidate transport receipt.'
    }
    $installerPath = $fixtureProof.installer
}

# Cargo resolves the complete locked graph in the ordinary repository context.
# No Rust home or compiler settings are passed to the isolated installer child.
$tarball = $null
if ($Route -eq 'Npm') {
    $stage = Join-Path $scratch 'stage'
    $stageResult = Invoke-CapturedProcess -FilePath $node -RepositoryPreparation -Arguments @(
        (Join-Path $repoRoot 'scripts/stage-npm-release.mjs'), '--version', $Version, '--out', $stage
    )
    if ($stageResult.ExitCode -ne 0) { throw "npm stage failed:`n$($stageResult.Combined)" }
    $pristine = Join-Path $scratch 'pristine-package'
    [void][IO.Directory]::CreateDirectory($pristine)
    $packResult = Invoke-CapturedProcess -FilePath $npm -RepositoryPreparation -Arguments @('pack', '--json', '--pack-destination', $pristine) -WorkingDirectory $stage
    if ($packResult.ExitCode -ne 0) { throw "npm pack failed:`n$($packResult.Combined)" }
    $pack = $packResult.StdOut | ConvertFrom-Json -Depth 10
    $tarball = Join-Path $pristine $pack[0].filename
    $packageEvidence = [ordered]@{
        pristine_tarball_sha256 = (Get-FileHash -LiteralPath $tarball -Algorithm SHA256).Hash.ToLowerInvariant()
        pristine_installer_sha256 = (Get-FileHash -LiteralPath (Join-Path $stage 'install.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
        index_sha256 = (Get-FileHash -LiteralPath (Join-Path $stage 'index.mjs') -Algorithm SHA256).Hash.ToLowerInvariant()
        metadata_sha256 = (Get-FileHash -LiteralPath (Join-Path $stage 'package.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        transport_projected = $candidateFixture
        public_release_acquisition_proven = $false
    }
    if ($candidateFixture) {
        if ($packageEvidence.pristine_installer_sha256 -cne $fixtureProof.original_installer_sha256) { throw 'Pristine npm installer differs from the candidate Git source.' }
        Copy-Item -LiteralPath $installerPath -Destination (Join-Path $stage 'install.ps1') -Force
        $fixturePack = Join-Path $scratch 'fixture-package'
        [void][IO.Directory]::CreateDirectory($fixturePack)
        $projectedPack = Invoke-CapturedProcess -FilePath $npm -RepositoryPreparation -Arguments @('pack', '--json', '--pack-destination', $fixturePack) -WorkingDirectory $stage
        if ($projectedPack.ExitCode -ne 0) { throw "Fixture npm pack failed:`n$($projectedPack.Combined)" }
        $projected = $projectedPack.StdOut | ConvertFrom-Json -Depth 10
        $tarball = Join-Path $fixturePack $projected[0].filename
        $packageEvidence.fixture_tarball_sha256 = (Get-FileHash -LiteralPath $tarball -Algorithm SHA256).Hash.ToLowerInvariant()
        $packageEvidence.fixture_installer_sha256 = (Get-FileHash -LiteralPath (Join-Path $stage 'install.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($packageEvidence.fixture_installer_sha256 -cne $fixtureProof.fixture_installer_sha256 -or
            $packageEvidence.index_sha256 -cne (Get-FileHash -LiteralPath (Join-Path $stage 'index.mjs') -Algorithm SHA256).Hash.ToLowerInvariant() -or
            $packageEvidence.metadata_sha256 -cne (Get-FileHash -LiteralPath (Join-Path $stage 'package.json') -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Fixture npm projection changed its index, metadata, or declared installer.' }
    }
    $packageEvidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $scratch 'npm-package-evidence.json') -Encoding utf8NoBOM
}
$repositoryPreparationOpen = $false
$env:HOME = $fixtureHome
$env:USERPROFILE = $fixtureHome
$env:HOMEDRIVE = [System.IO.Path]::GetPathRoot($fixtureHome).TrimEnd('\')
$env:HOMEPATH = $fixtureHome.Substring($env:HOMEDRIVE.Length)
$env:LOCALAPPDATA = $localAppData
$env:APPDATA = $appData
$env:WINSMUX_RELEASE_TAG = "v$Version"
$env:WINSMUX_INSTALL_PROFILE = 'full'
if ($isGitHubRunner) {
    $env:WINSMUX_INSTALL_E2E = 'true'
    $env:WINSMUX_INSTALL_SOURCE_REF = $SourceCommit
} else {
    $env:WINSMUX_INSTALL_E2E = 'redirected'
    $env:WINSMUX_INSTALL_STATE_ROOT = Join-Path $fixtureHome '.winsmux-install-state'
    $env:WINSMUX_INSTALL_SOURCE_REF = $SourceCommit
}

function Invoke-IrmInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$SourceInstaller,
        [Parameter(Mandatory = $true)][string]$ServerDirectory,
        [switch]$IncludeGitHubAccess,
        [switch]$IncludeTargetInstallerBootstrapMarker,
        [switch]$OmitReleaseTagSelection
    )

    New-Item -ItemType Directory -Path $ServerDirectory -Force | Out-Null
    $readyPath = Join-Path $ServerDirectory 'ready.txt'
    $serverScript = Join-Path $ServerDirectory 'serve-installer-once.ps1'
    $sourceLiteral = $SourceInstaller.Replace("'", "''")
    $readyLiteral = $readyPath.Replace("'", "''")
    $serverContent = @"
`$ErrorActionPreference = 'Stop'
`$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
try {
    `$listener.Start()
    `$port = ([System.Net.IPEndPoint]`$listener.LocalEndpoint).Port
    [System.IO.File]::WriteAllText('$readyLiteral', [string]`$port, [System.Text.UTF8Encoding]::new(`$false))
    `$client = `$listener.AcceptTcpClient()
    try {
        `$stream = `$client.GetStream()
        `$reader = [System.IO.StreamReader]::new(`$stream, [System.Text.Encoding]::ASCII, `$false, 1024, `$true)
        `$requestLine = `$reader.ReadLine()
        while (`$null -ne (`$line = `$reader.ReadLine()) -and `$line.Length -gt 0) {}
        if (`$requestLine -notmatch '^GET /install\.ps1 HTTP/') { throw "Unexpected request: `$requestLine" }
        `$body = [System.IO.File]::ReadAllBytes('$sourceLiteral')
        `$header = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK``r``nContent-Type: text/plain; charset=utf-8``r``nContent-Length: `$(`$body.Length)``r``nConnection: close``r``n``r``n")
        `$stream.Write(`$header, 0, `$header.Length)
        `$stream.Write(`$body, 0, `$body.Length)
        `$stream.Flush()
    } finally {
        `$client.Dispose()
    }
} finally {
    `$listener.Stop()
}
"@
    [System.IO.File]::WriteAllText($serverScript, $serverContent, [System.Text.UTF8Encoding]::new($false))

    $serverInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $serverInfo.FileName = $pwsh
    foreach ($argument in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $serverScript)) {
        $serverInfo.ArgumentList.Add($argument)
    }
    $serverInfo.WorkingDirectory = $repoRoot
    $serverInfo.UseShellExecute = $false
    $serverInfo.CreateNoWindow = $true
    $serverInfo.RedirectStandardOutput = $true
    $serverInfo.RedirectStandardError = $true
    $serverInfo.Environment.Clear()
    foreach ($name in @('SystemRoot', 'WINDIR', 'ComSpec', 'PATH', 'PATHEXT', 'PSModulePath', 'TEMP', 'TMP')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $value) { $serverInfo.Environment[$name] = $value }
    }
    $server = [System.Diagnostics.Process]::Start($serverInfo)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
            if ($server.HasExited) {
                throw "Loopback installer server exited before becoming ready: $($server.StandardError.ReadToEnd())"
            }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out waiting for the loopback installer server.' }
            Start-Sleep -Milliseconds 50
        }
        $port = (Get-Content -LiteralPath $readyPath -Raw -Encoding UTF8).Trim()
        if ($port -notmatch '^\d+$') { throw "Loopback installer server returned an invalid port: $port" }
        $url = "http://127.0.0.1:$port/install.ps1"
        $command = "`$ErrorActionPreference = 'Stop'; irm '$url' | iex"
        $result = Invoke-CapturedProcess -FilePath $pwsh -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command) -IncludeGitHubAccess:$IncludeGitHubAccess -IncludeTargetInstallerBootstrapMarker:$IncludeTargetInstallerBootstrapMarker -OmitReleaseTagSelection:$OmitReleaseTagSelection
        if (-not $server.WaitForExit(15000)) { throw 'Loopback installer server did not exit after serving install.ps1.' }
        $serverError = $server.StandardError.ReadToEnd().Trim()
        if ($server.ExitCode -ne 0) { throw "Loopback installer server failed: $serverError" }
        return $result
    } finally {
        if (-not $server.HasExited) { $server.Kill($true) }
        $server.Dispose()
    }
}

function New-WinsmuxMissingSourceFixture {
    param([Parameter(Mandatory=$true)][string]$Source)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Missing-source fixture input cannot be parsed.'}
    $functions=@{}
    foreach($name in @('New-WinsmuxSupportStage','Invoke-WinsmuxInstallLifecycle')) {
        $definitions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
        if($definitions.Count -ne 1){throw 'Missing-source fixture function is ambiguous.'}
        $functions[$name]=$definitions[0]
    }
    # The current producer creates its own stage before the two core downloads.
    # Select the SCRIPT_DIR command structurally, without depending on quote style.
    $stage=$functions['New-WinsmuxSupportStage']
    $coreCalls=@($stage.Body.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Download-File' -and $n.CommandElements.Count -eq 3 -and $n.CommandElements[1] -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.CommandElements[1].Value -ceq 'scripts/winsmux-core.ps1'},$true))
    if($coreCalls.Count -ne 2){throw 'Missing-source fixture requires the current paired core-stage downloads.'}
    $selected=$null
    foreach($call in $coreCalls) {
        $destinations=@($call.CommandElements[2].FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Join-Path'},$true))
        if($destinations.Count -ne 1 -or $destinations[0].CommandElements.Count -ne 3 -or
            $destinations[0].CommandElements[1] -isnot [Management.Automation.Language.VariableExpressionAst] -or
            $destinations[0].CommandElements[2] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
            $destinations[0].CommandElements[2].Value -cne 'winsmux-core.ps1'){throw 'Unexpected core-stage destination.'}
        $variable=$destinations[0].CommandElements[1].VariablePath.UserPath
        if($variable -ceq 'SCRIPT_DIR') {
            if($selected){throw 'Ambiguous script-stage core download.'};$selected=$call
        } elseif($variable -cne 'BIN_DIR'){throw 'Unexpected core-stage directory.'}
    }
    if(-not $selected -or $coreCalls[0].Extent.StartOffset -ge $coreCalls[1].Extent.StartOffset -or $selected -ne $coreCalls[1]){throw 'Unexpected core-stage download order.'}
    $lifecycle=$functions['Invoke-WinsmuxInstallLifecycle']
    $binaryCalls=@($lifecycle.Body.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Install-WinsmuxBinary'},$true))
    if($binaryCalls.Count -ne 1){throw 'Missing-source fixture lifecycle dispatch is ambiguous.'}
    $binary=$binaryCalls[0]
    $shape=@($binary.CommandElements|ForEach-Object {$_.Extent.Text}) -join ' '
    if($shape -cne 'Install-WinsmuxBinary -Lease $lease -SupportProfile $profile -IsUpdate:$IsUpdate'){throw 'Unsupported current lifecycle dispatch.'}
    $insertion=[Environment]::NewLine+"    Write-Host 'TASK880_DEFECT_MISSING_SOURCE_READY'"+[Environment]::NewLine+"    Download-File 'winsmux.ps1' (Join-Path `$BIN_DIR 'winsmux.ps1')"
    $replacement='$null = New-WinsmuxSupportStage $lease $profile ([bool]$IsUpdate)'+[Environment]::NewLine+"        throw 'Historical missing-source download unexpectedly succeeded.'"
    $edits=@(@{start=$selected.Extent.EndOffset;length=0;text=$insertion},@{start=$binary.Extent.StartOffset;length=$binary.Extent.EndOffset-$binary.Extent.StartOffset;text=$replacement})
    $broken=$Source
    foreach($edit in @($edits|Sort-Object start -Descending)) {$broken=$broken.Remove($edit.start,$edit.length).Insert($edit.start,$edit.text)}
    if([regex]::Matches($broken,[regex]::Escape($insertion)).Count -ne 1 -or [regex]::Matches($broken,[regex]::Escape($replacement)).Count -ne 1 -or
        $broken.Replace($insertion,'').Replace($replacement,$binary.Extent.Text) -cne $Source){throw 'Missing-source fixture changed bytes beyond its two declared projections.'}
    $checkTokens=$null;$checkErrors=$null
    [void][Management.Automation.Language.Parser]::ParseInput($broken,[ref]$checkTokens,[ref]$checkErrors)
    if($checkErrors.Count){throw 'Missing-source fixture projection cannot be parsed.'}
    return @{source=$broken;proof=@{original_installer_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Source))).ToLowerInvariant();fixture_installer_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($broken))).ToLowerInvariant();inverse_projection_exact=$true;core_stage_calls=$coreCalls.Count;binary_dispatch_calls=$binaryCalls.Count;stage_function='New-WinsmuxSupportStage';lifecycle_function='Invoke-WinsmuxInstallLifecycle';historical_target='winsmux.ps1';stage_reached_marker='TASK880_DEFECT_MISSING_SOURCE_READY';release_binary_acquisition='excluded in this historical-source fixture';publication_registration='not reached; fixture invokes only the current own-stage producer';real_http_404='not_run'}}
}

if ($Route -eq 'DefectDetection') {
    $brokenInstaller = Join-Path $scratch 'install-pre-fix.ps1'
    $source = Get-Content -LiteralPath $installerPath -Raw -Encoding UTF8
    $fixture=New-WinsmuxMissingSourceFixture $source
    if($fixture.proof.original_installer_sha256 -cne (Get-GitBlobSha256 -Treeish $SourceCommit -RelativePath 'install.ps1')){throw 'Historical detection source differs from the committed installer.'}
    [System.IO.File]::WriteAllText($brokenInstaller, $fixture.source, [System.Text.UTF8Encoding]::new($false))
    $result = Invoke-IrmInstaller -SourceInstaller $brokenInstaller -ServerDirectory (Join-Path $scratch 'pre-fix-server') -IncludeTargetInstallerBootstrapMarker
    if ($result.ExitCode -eq 0 -or $result.Combined -notmatch $fixture.proof.stage_reached_marker -or $result.Combined -notmatch 'winsmux\.ps1' -or $result.Combined -notmatch '404|Not Found') {
        throw "Pre-fix defect was not detected as expected. exit=$($result.ExitCode)`n$($result.Combined)"
    }
    $fixture.proof.real_http_404='observed by this CI run'
    [ordered]@{
        schema_version = 1
        route = $Route
        expected_failure_exit_code = $result.ExitCode
        detected_missing_target = 'winsmux.ps1'
        fixture = $fixture.proof
        scratch_root = $scratch
    } | ConvertTo-Json -Depth 5
    exit 0
}

$taglessInstallVerified = $false
if ($Route -eq 'Direct' -and $isGitHubRunner) {
    $taglessResult = Invoke-IrmInstaller -SourceInstaller $installerPath -ServerDirectory (Join-Path $scratch 'tagless-direct-server') -IncludeGitHubAccess:($isGitHubRunner -and -not $candidateFixture) -OmitReleaseTagSelection
    if ($taglessResult.ExitCode -ne 0 -or $taglessResult.Combined -match '\[winsmux\]\s+Failed to download\b') {
        throw "Tagless direct install did not stay on the fixed main installer:`n$($taglessResult.Combined)"
    }
    $taglessInstallerText = Get-Content -LiteralPath (Join-Path $fixtureHome '.winsmux\bin\install.ps1') -Raw -Encoding UTF8
    $taglessCoreText = Get-Content -LiteralPath (Join-Path $fixtureHome '.winsmux\bin\winsmux-core.ps1') -Raw -Encoding UTF8
    if ($taglessInstallerText -notmatch 'Get-WinsmuxExecutingInstallerSource' -or $taglessInstallerText -notmatch 'Publish-WinsmuxLifecycle' -or $taglessCoreText -notmatch '\$sourceRoot') {
        throw 'Tagless direct install replaced the fixed main scripts with the previous release scripts.'
    }
    $taglessInstallVerified = $true
}

$installResult = $null
if ($Route -eq 'Npm') {
    $stage = Join-Path $scratch 'stage'
    $npmInstall = Invoke-CapturedProcess -FilePath $npm -Arguments @('install', '--global', '--prefix', $npmPrefix, $tarball)
    if ($npmInstall.ExitCode -ne 0) { throw "npm global install failed:`n$($npmInstall.Combined)" }
    $npmShim = Join-Path $npmPrefix 'winsmux.cmd'
    if (-not (Test-Path -LiteralPath $npmShim -PathType Leaf)) { throw "npm shim missing: $npmShim" }
    $installResult = Invoke-CapturedProcess -FilePath $npmShim -Arguments @('install', '--profile', 'full') -IncludeGitHubAccess:($isGitHubRunner -and -not $candidateFixture)
} else {
    $installResult = Invoke-IrmInstaller -SourceInstaller $installerPath -ServerDirectory (Join-Path $scratch 'direct-server') -IncludeGitHubAccess:($isGitHubRunner -and -not $candidateFixture)
}
if ($installResult.ExitCode -ne 0) { throw "$Route full install failed:`n$($installResult.Combined)" }
if ($installResult.Combined -match '\[winsmux\]\s+Failed to download\b') {
    throw "$Route install log contains an installer download failure:`n$($installResult.Combined)"
}

$core = Join-Path $fixtureHome '.winsmux\bin\winsmux-core.ps1'
$wrapper = Join-Path $fixtureHome '.winsmux\bin\winsmux.cmd'
$entry = Join-Path $fixtureHome '.winsmux\bin\winsmux-entry.ps1'
$installedInstaller = Join-Path $fixtureHome '.winsmux\bin\install.ps1'
$native = Join-Path $fixtureHome '.local\bin\winsmux.exe'
$manifestPath = Join-Path $fixtureHome '.winsmux\install-profile.json'
$fragment = Join-Path $localAppData 'Microsoft\Windows Terminal\Fragments\winsmux\winsmux.json'
foreach ($path in @($core, $wrapper, $entry, $installedInstaller, $native, $manifestPath, $fragment)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "installed artifact missing: $path" }
}

Assert-WinsmuxInstalledEntryChain -WrapperBytes ([IO.File]::ReadAllBytes($wrapper)) -EntryBytes ([IO.File]::ReadAllBytes($entry))
$fragmentText = Get-Content -LiteralPath $fragment -Raw -Encoding UTF8
if ($fragmentText -notmatch 'winsmux\.cmd' -or $fragmentText -notmatch 'launch --project-dir' -or $fragmentText -match 'winsmux\.ps1|start -C') {
    throw 'Windows Terminal fragment does not use the canonical installed launch entrypoint.'
}

$env:PATH = "$(Split-Path -Parent $wrapper);$(Split-Path -Parent $native);$env:PATH"
$expectedReleaseTag = if ($isGitHubRunner -and -not [string]::IsNullOrWhiteSpace($env:WINSMUX_INSTALL_E2E_RELEASE_TAG)) {
    $env:WINSMUX_INSTALL_E2E_RELEASE_TAG.Trim()
} else {
    "v$Version"
}
$expectedNativeVersion = ConvertTo-WinsmuxBinaryVersion -ReleaseTag $expectedReleaseTag
$versionResult = Invoke-CapturedProcess -FilePath $wrapper -Arguments @('version')
if ($versionResult.ExitCode -ne 0 -or $versionResult.StdOut -ne "winsmux $Version") {
    throw "installed wrapper version failed: exit=$($versionResult.ExitCode) output=$($versionResult.Combined)"
}
$rawVersionResult = Invoke-CapturedProcess -FilePath $wrapper -Arguments @('-V')
if ($rawVersionResult.ExitCode -ne 0 -or $rawVersionResult.StdOut -ne "winsmux $expectedNativeVersion") {
    throw "installed wrapper native forwarding failed: exit=$($rawVersionResult.ExitCode) output=$($rawVersionResult.Combined)"
}
$doctorResult = Invoke-CapturedProcess -FilePath $wrapper -Arguments @('doctor')
$doctorOutput = $doctorResult.Combined
if ($doctorOutput -notmatch '(?m)^=== winsmux doctor ===\s*$') {
    throw "installed wrapper doctor did not start the expected diagnostics:`n$doctorOutput"
}
if ($doctorOutput -notmatch "(?m)^winsmux:\s+winsmux $([regex]::Escape($expectedNativeVersion))\s*$") {
    throw "installed wrapper doctor did not resolve the installed native version:`n$doctorOutput"
}

$launchProject = Join-Path $scratch 'project with spaces'
New-Item -ItemType Directory -Path $launchProject -Force | Out-Null
$launchResult = Invoke-CapturedProcess -FilePath $wrapper -Arguments @('launch', '--json', '--project-dir', $launchProject)
if ($launchResult.ExitCode -ne 0) { throw "installed wrapper launch contract failed:`n$($launchResult.Combined)" }
$launchContract = $launchResult.StdOut | ConvertFrom-Json -Depth 10
$expectedProject = [System.IO.Path]::GetFullPath($launchProject)
if ($launchContract.status -ne 'blocked' -or $launchContract.reason -ne 'missing_config' -or
    -not [string]::Equals([string]$launchContract.project_dir, $expectedProject, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "installed wrapper did not preserve launch --project-dir exactly:`n$($launchResult.Combined)"
}
if ($doctorOutput -notmatch '(?m)^WT settings: not found \(not using Windows Terminal\?\)\s*$') {
    throw "installed wrapper doctor did not report the expected Windows Terminal absence:`n$doctorOutput"
}
if ($doctorOutput -match 'winsmux:\s+NOT FOUND|winsmux-core\.ps1.*(?:not found|cannot find)|CommandNotFoundException') {
    throw "installed wrapper doctor reported an entrypoint failure:`n$doctorOutput"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 10
if ($manifest.profile -ne 'full' -or $manifest.version -ne $expectedNativeVersion -or $manifest.release_tag -ne $expectedReleaseTag) {
    throw 'Installed profile manifest does not match the requested full release.'
}

$routerArtifactPaths = @(
    'winsmux-core/scripts/coordinator-router.ps1',
    'winsmux-core/scripts/local-router-shadow.ps1',
    'winsmux-core/router/local-small-router-v03621.manifest.json',
    'winsmux-core/router/local-small-router-v03621.weights.json'
)
$routerInventoryItems = @($routerArtifactPaths | ForEach-Object {
    $relativePath = $_
    $installedPath = Join-Path (Join-Path $fixtureHome '.winsmux') $relativePath
    if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
        throw "$Route full install omitted router artifact: $relativePath"
    }
    $sourceHash = Get-GitBlobSha256 -Treeish $SourceCommit -RelativePath $relativePath
    $installedHash = (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($installedHash -cne $sourceHash) {
        throw "$Route full install router artifact hash mismatch: $relativePath expected=$sourceHash actual=$installedHash"
    }
    [ordered]@{
        path = $relativePath
        sha256 = $installedHash
    }
})
$installedShadowPath = Join-Path (Join-Path $fixtureHome '.winsmux') 'winsmux-core/scripts/local-router-shadow.ps1'
$resolvedInstalledRouter = & {
    param([Parameter(Mandatory)][string]$ShadowPath)
    . $ShadowPath
    Resolve-WinsmuxLocalRouterArtifact
} $installedShadowPath
$expectedInstalledManifest = Join-Path (Join-Path $fixtureHome '.winsmux') 'winsmux-core/router/local-small-router-v03621.manifest.json'
$expectedInstalledWeights = Join-Path (Join-Path $fixtureHome '.winsmux') 'winsmux-core/router/local-small-router-v03621.weights.json'
if (-not [string]::Equals([IO.Path]::GetFullPath([string]$resolvedInstalledRouter.manifest_path), [IO.Path]::GetFullPath($expectedInstalledManifest), [StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::Equals([IO.Path]::GetFullPath([string]$resolvedInstalledRouter.weights_path), [IO.Path]::GetFullPath($expectedInstalledWeights), [StringComparison]::OrdinalIgnoreCase)) {
    throw "$Route full install did not resolve the default local-router manifest to its installed sibling artifacts."
}
$routerInventory = [ordered]@{
    found = $routerInventoryItems.Count
    expected = $routerArtifactPaths.Count
    sha256_match = $routerInventoryItems.Count
    manifest_resolvable = $true
}

$lockedNativeUpdateVerified = $false
if ($Route -eq 'Direct' -and $isGitHubRunner) {
    $cmdFixture = Join-Path $env:SystemRoot 'System32\cmd.exe'
    if (-not (Test-Path -LiteralPath $cmdFixture -PathType Leaf)) { throw "cmd fixture not found: $cmdFixture" }
    Copy-Item -LiteralPath $cmdFixture -Destination $native -Force
    $lockInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $lockInfo.FileName = $native
    foreach ($argument in @('/d', '/c', 'ping.exe -n 120 127.0.0.1 >NUL')) {
        $lockInfo.ArgumentList.Add($argument)
    }
    $lockInfo.UseShellExecute = $false
    $lockInfo.CreateNoWindow = $true
    $lockedNative = [System.Diagnostics.Process]::Start($lockInfo)
    try {
        Start-Sleep -Milliseconds 500
        if ($lockedNative.HasExited) { throw 'locked native fixture exited before update.' }
        $lockedUpdate = Invoke-CapturedProcess -FilePath $pwsh -Arguments @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installedInstaller,
            'update', '-ReleaseTag', $expectedReleaseTag, '-InstallProfile', 'full'
        ) -IncludeGitHubAccess:($isGitHubRunner -and -not $candidateFixture)
        if ($lockedUpdate.ExitCode -ne 0) {
            throw "update could not replace a running native executable:`n$($lockedUpdate.Combined)"
        }
        $updatedNativeVersion = Invoke-CapturedProcess -FilePath $native -Arguments @('-V')
        if ($updatedNativeVersion.ExitCode -ne 0 -or $updatedNativeVersion.StdOut -ne "winsmux $expectedNativeVersion") {
            throw "replacement native is not runnable after locked update:`n$($updatedNativeVersion.Combined)"
        }
        $rotationResidue = @(
            Get-ChildItem -LiteralPath (Split-Path -Parent $native) -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^winsmux\.exe\.previous-[0-9a-f]{32}$' }
        )
        if ($rotationResidue.Count -gt 1) {
            throw "locked update left more than one owned rotation file: $($rotationResidue.Name -join ', ')"
        }
        $lockedNativeUpdateVerified = $true
    } finally {
        if (-not $lockedNative.HasExited) { $lockedNative.Kill($true) }
        $lockedNative.WaitForExit()
        $lockedNative.Dispose()
    }
    $cleanupUpdate = Invoke-CapturedProcess -FilePath $pwsh -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installedInstaller,
        'update', '-ReleaseTag', $expectedReleaseTag, '-InstallProfile', 'full'
    ) -IncludeGitHubAccess:($isGitHubRunner -and -not $candidateFixture)
    if ($cleanupUpdate.ExitCode -ne 0) {
        throw "follow-up update could not clean rotation residue:`n$($cleanupUpdate.Combined)"
    }
    $remainingRotationResidue = @(
        Get-ChildItem -LiteralPath (Split-Path -Parent $native) -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^winsmux\.exe\.previous-[0-9a-f]{32}$' }
    )
    if ($remainingRotationResidue.Count -ne 0) {
        throw "follow-up update left owned rotation residue: $($remainingRotationResidue.Name -join ', ')"
    }
}

$realLifecycle = $null
if ($isGitHubRunner -and $candidateFixture) {
    $realRoot = Join-Path $scratch 'task880-real-lifecycle'
    [void][IO.Directory]::CreateDirectory($realRoot)
    [IO.File]::WriteAllText((Join-Path $realRoot 'result.json'),(ConvertTo-Json @{schema='task880-real-lifecycle/v1';passed=$false;state='not_run';route=$Route;source_commit=$SourceCommit;reason='All real-entry assertions have not completed.'}),[Text.UTF8Encoding]::new($false))
    $environment=@{source_commit=$SourceCommit;profile_volume_guid=$profileVolume;home_volume_guid=$ownRootVolume;os=[Environment]::OSVersion.VersionString;architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();powershell=$PSVersionTable.PSVersion.ToString();node=(& $node --version | Out-String).Trim();npm=(& $npm --version | Out-String).Trim();candidate_receipt_sha256=$fixtureProof.candidate_receipt_sha256;pristine_transport_sha256=$fixtureProof.transport_sha256;real_lifecycle_state='not_run'}
    [IO.File]::WriteAllText((Join-Path $realRoot 'environment.json'),(ConvertTo-Json $environment -Depth 10),[Text.UTF8Encoding]::new($false))
    $task880Evidence=@{commands=[Collections.Generic.List[object]]::new();preservation=[Collections.Generic.List[object]]::new()}
    function Write-Task880Progress([string]$State='running',[string]$Reason='Real entry assertions are incomplete.') {
        $progress=@{schema='task880-real-lifecycle/v1';passed=$false;state=$State;route=$Route;source_commit=$SourceCommit;reason=$Reason;commands=@($task880Evidence.commands.ToArray());preservation=@($task880Evidence.preservation.ToArray())}
        [IO.File]::WriteAllText((Join-Path $realRoot 'result.json'),(ConvertTo-Json $progress -Depth 16),[Text.UTF8Encoding]::new($false))
    }
    function Assert-Task880([bool]$Condition,[string]$Message) { if(-not $Condition){Write-Task880Progress 'failed' $Message;throw $Message} }
    function Test-Task880Nullable($Actual,$Expected) {
        if($null -eq $Actual -or $null -eq $Expected){return ($null -eq $Actual -and $null -eq $Expected)}
        return ($Actual -is [string] -and $Expected -is [string] -and $Actual -ceq $Expected)
    }
    function Get-Task880Snapshot {
        $rows=[ordered]@{}
        foreach($relative in @('.local/bin/winsmux.exe','.local/bin/winsmux-licenses.owner.json','.local/bin/winsmux-licenses','.winsmux/install-owner.json','.winsmux/bin/winsmux-core.ps1','.winsmux.conf','.winsmux/projects/task880/project.json','.winsmux/task880-unknown.json')) {
            $path=Join-Path $fixtureHome $relative
            if([IO.Directory]::Exists($path)) {
                $rows[$relative]=@([IO.Directory]::EnumerateFiles($path,'*',[IO.SearchOption]::AllDirectories)|Sort-Object|ForEach-Object {@{path=[IO.Path]::GetRelativePath($path,$_);sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()}})
            } elseif([IO.File]::Exists($path)) {$rows[$relative]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
            else {$rows[$relative]=$null}
        }
        foreach($extra in @(@{name='actual-profile';path=$profilePath},@{name='terminal-fragment';path=$fragment})) {
            $rows[$extra.name]=if([IO.File]::Exists($extra.path)){(Get-FileHash -LiteralPath $extra.path -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null}
        }
        return (ConvertTo-Json $rows -Depth 10 -Compress)
    }
    function Save-Task880Equality([string]$Name,[string]$Before,[string]$After,$PriorUser,$CurrentUser) {
        function Get-Task880NullableDigest($Value) {
            if($null -eq $Value){return @{present=$false;bytes=$null;sha256=$null}}
            $bytes=[Text.Encoding]::UTF8.GetBytes($Value)
            return @{present=$true;bytes=$bytes.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}
        }
        $data=@{name=$Name;before_inventory=($Before|ConvertFrom-Json -AsHashtable);after_inventory=($After|ConvertFrom-Json -AsHashtable);prior_user_path=(Get-Task880NullableDigest $PriorUser);current_user_path=(Get-Task880NullableDigest $CurrentUser);paired_settings_project_equal=$Before -ceq $After;user_path_equal=(Test-Task880Nullable $CurrentUser $PriorUser);canonical_lifecycle_excluded='Current entrance migration is permanent by the fixed contract.'}
        $task880Evidence.preservation.Add($data)
        Write-Task880Progress
    }
    $pristineInstaller=$fixtureProof.installer
    $packagedInstaller=if($Route -ceq 'Npm'){Join-Path $npmPrefix 'node_modules/winsmux/install.ps1'}else{''}
    $pristinePackageBytes=if($Route -ceq 'Npm'){[IO.File]::ReadAllBytes($packagedInstaller)}else{$null}
    function Invoke-Task880Action([string]$Action,[string]$Body=$pristineInstaller,[switch]$Interrupt) {
        if($Route -ceq 'Npm') {
            # Both files come from the verified fixture producer: only its fixed
            # transport block differs. The public npm index/metadata stay exact.
            $beforeIndex=(Get-FileHash -LiteralPath (Join-Path $npmPrefix 'node_modules/winsmux/index.mjs') -Algorithm SHA256).Hash
            [IO.File]::WriteAllBytes($packagedInstaller,[IO.File]::ReadAllBytes($Body))
            try { $result=Invoke-CapturedProcess -FilePath $npmShim -Arguments @($Action,'--profile','full') -InterruptAfterRegistration:$Interrupt }
            finally {[IO.File]::WriteAllBytes($packagedInstaller,$pristinePackageBytes)}
            Assert-Task880 ((Get-FileHash -LiteralPath (Join-Path $npmPrefix 'node_modules/winsmux/index.mjs') -Algorithm SHA256).Hash -ceq $beforeIndex) 'npm index changed during lifecycle invocation.'
            return $result
        }
        return (Invoke-CapturedProcess -FilePath $pwsh -Arguments @('-NoProfile','-File',$Body,$Action,'-ReleaseTag',$expectedReleaseTag,'-InstallProfile','full') -InterruptAfterRegistration:$Interrupt)
    }
    function Save-Task880Command([string]$Name,$Command) {
        $record=@{name=$Name;route=$Route;file_path=$Command.FilePath;arguments=$Command.Arguments;working_directory=$Command.WorkingDirectory;exit=$Command.ExitCode;interruption=$Command.Interruption;stdout_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Command.StdOut))).ToLowerInvariant();stderr_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Command.StdErr))).ToLowerInvariant()}
        $task880Evidence.commands.Add($record)
        Write-Task880Progress
    }
    Save-Task880Command 'initial-install' $installResult
    $project=Join-Path $fixtureHome '.winsmux/projects/task880/project.json'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($project))
    [IO.File]::WriteAllBytes($project,[Text.Encoding]::UTF8.GetBytes('{"task880":"protected-project"}'))
    $unknown=Join-Path $fixtureHome '.winsmux/task880-unknown.json'
    [IO.File]::WriteAllText($unknown,'task880 unknown user bytes',[Text.UTF8Encoding]::new($false))
    $projectHash=(Get-FileHash -LiteralPath $project -Algorithm SHA256).Hash
    $unknownHash=(Get-FileHash -LiteralPath $unknown -Algorithm SHA256).Hash
    $positive=Invoke-Task880Action 'update';Save-Task880Command 'normal-update' $positive
    Assert-Task880 ($positive.ExitCode -eq 0) 'Real public update failed.'
    $nativeVersion=Invoke-CapturedProcess -FilePath $native -Arguments @('-V')
    Assert-Task880 ($nativeVersion.ExitCode -eq 0 -and $nativeVersion.StdOut -ceq ('winsmux '+$expectedNativeVersion)) 'Real PE did not run after update.'
    $config=Join-Path $fixtureHome '.winsmux.conf'
    [IO.File]::WriteAllText($config,'task880 user settings kept across update',[Text.UTF8Encoding]::new($false))
    $configHash=(Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    $lock=[IO.File]::Open($config,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {$kept=Invoke-Task880Action 'update'}finally{$lock.Dispose()}
    Save-Task880Command 'edited-settings-update' $kept
    Assert-Task880 ($kept.ExitCode -eq 0) 'Update failed while the user-edited settings were open.'
    Assert-Task880 ((Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -ceq $configHash) 'Update changed user-edited settings.'
    $supportOwner=[IO.File]::ReadAllText((Join-Path $fixtureHome '.winsmux/install-owner.json'))|ConvertFrom-Json -AsHashtable
    Assert-Task880 (@($supportOwner.files|Where-Object {$_.name -ceq '.winsmux.conf'}).Count -eq 0) 'Support receipt claimed user-edited settings.'
    $before=Get-Task880Snapshot;$priorUser=[Environment]::GetEnvironmentVariable('Path','User')
    $lock=[IO.File]::Open((Join-Path $fixtureHome '.winsmux/bin/winsmux-core.ps1'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {$locked=Invoke-Task880Action 'update'}finally{$lock.Dispose()}
    Save-Task880Command 'external-rename-lock' $locked
    Save-Task880Equality 'external-rename-lock' $before (Get-Task880Snapshot) $priorUser ([Environment]::GetEnvironmentVariable('Path','User'))
    Assert-Task880 ($locked.ExitCode -ne 0) 'External no-delete lock did not reject publication.'
    Assert-Task880 ((Get-Task880Snapshot) -ceq $before) 'Real locked publication did not restore old paired/settings/project bytes.'
    Assert-Task880 (Test-Task880Nullable ([Environment]::GetEnvironmentVariable('Path','User')) $priorUser) 'Real locked publication changed User PATH.'
    $marker=Join-Path $fixtureHome '.local/bin/winsmux.install.pending.json'
    Assert-Task880 (-not [IO.File]::Exists($marker)) 'Verified lock failure restoration retained pending.'
    $faults=@{}
    foreach($mode in @('tamper','missing')) {
        $prepared=Invoke-CapturedProcess -FilePath $node -Arguments @((Join-Path $repoRoot 'scripts/prepare-install-e2e-fixture.mjs'),[IO.Path]::GetFullPath($CandidateDirectory),$SourceCommit,$Version,(Join-Path $scratch ('fault-'+$mode)),'--fault',$mode)
        Assert-Task880 ($prepared.ExitCode -eq 0) 'Fault transport preparation failed.'
        $proof=$prepared.StdOut|ConvertFrom-Json -AsHashtable
        Assert-Task880 ($proof.product_body_unchanged -and $proof.original_installer_sha256 -ceq $fixtureProof.original_installer_sha256 -and $proof.fault -ceq $mode) 'Fault transport changed product source identity.'
        $faults[$mode]=$proof
        $before=Get-Task880Snapshot;$priorUser=[Environment]::GetEnvironmentVariable('Path','User')
        $failed=Invoke-Task880Action 'update' $proof.installer;Save-Task880Command ('transport-'+$mode) $failed
        Save-Task880Equality ('transport-'+$mode) $before (Get-Task880Snapshot) $priorUser ([Environment]::GetEnvironmentVariable('Path','User'))
        Assert-Task880 ($failed.ExitCode -ne 0) 'Real update accepted a damaged or missing response.'
        if($mode -ceq 'tamper'){Assert-Task880 ($failed.Combined -match 'checksum') 'Transport tamper did not reach the product checksum rejection.'}
        Assert-Task880 ((Get-Task880Snapshot) -ceq $before) 'Transport failure changed installed paired/settings/project bytes.'
        Assert-Task880 (Test-Task880Nullable ([Environment]::GetEnvironmentVariable('Path','User')) $priorUser) 'Transport failure changed User PATH.'
        Assert-Task880 (-not [IO.File]::Exists($marker)) 'Failed acquisition created pending publication.'
    }
    $before=Get-Task880Snapshot;$priorUser=[Environment]::GetEnvironmentVariable('Path','User')
    $crash=Invoke-Task880Action 'update' $pristineInstaller -Interrupt;Save-Task880Command 'external-interruption' $crash
    Assert-Task880 ($crash.ExitCode -ne 0 -and $null -ne $crash.Interruption -and $crash.Interruption.operation_matches -and -not $crash.Interruption.committed_after) 'Uncommitted own-operation interruption evidence missing; lifecycle not proven.'
    Assert-Task880 ([IO.File]::Exists($marker)) 'Interrupted actual update lost pending.'
    # The next public update recovers first, then intentionally fails acquisition.
    # It cannot publish a fresh generation over the old bytes we must observe.
    $recovery=Invoke-Task880Action 'update' $faults.missing.installer;Save-Task880Command 'pending-recovery-missing-response' $recovery
    Save-Task880Equality 'pending-recovery' $before (Get-Task880Snapshot) $priorUser ([Environment]::GetEnvironmentVariable('Path','User'))
    Assert-Task880 ($recovery.ExitCode -ne 0 -and -not [IO.File]::Exists($marker)) 'Next public entry did not complete old-generation recovery before missing acquisition.'
    Assert-Task880 ((Get-Task880Snapshot) -ceq $before) 'Real pending recovery did not restore old paired/settings/project bytes.'
    Assert-Task880 (Test-Task880Nullable ([Environment]::GetEnvironmentVariable('Path','User')) $priorUser) 'Real pending recovery did not restore exact User PATH.'
    # Keep the public lifecycle usable when its standalone executable is missing.
    [IO.File]::Delete($native)
    $missingNative=Invoke-CapturedProcess -FilePath $wrapper -Arguments @('update','--profile','full');Save-Task880Command 'missing-native-recovery' $missingNative
    Assert-Task880 ($missingNative.ExitCode -eq 0 -and [IO.File]::Exists($native)) 'Actual public update did not recover a missing standalone native.'
    $beforeNative=(Get-FileHash -LiteralPath $native -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($config,'task880 modified user settings preserved at uninstall',[Text.UTF8Encoding]::new($false))
    $beforeConfig=(Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    $beforeUninstallUser=[Environment]::GetEnvironmentVariable('Path','User')
    $removed=Invoke-Task880Action 'uninstall';Save-Task880Command 'real-uninstall' $removed
    Assert-Task880 ($removed.ExitCode -eq 0) 'Real public uninstall failed.'
    $preservedBefore=[ordered]@{};$preservedAfter=[ordered]@{}
    foreach($pair in @(@{path=$project;sha=$projectHash},@{path=$unknown;sha=$unknownHash},@{path=$config;sha=$beforeConfig},@{path=$native;sha=$beforeNative})) {
        $key=[IO.Path]::GetRelativePath($fixtureHome,$pair.path)
        $preservedBefore[$key]=$pair.sha
        $preservedAfter[$key]=if([IO.File]::Exists($pair.path)){(Get-FileHash -LiteralPath $pair.path -Algorithm SHA256).Hash}else{$null}
    }
    Save-Task880Equality 'real-uninstall' (ConvertTo-Json $preservedBefore -Compress) (ConvertTo-Json $preservedAfter -Compress) $beforeUninstallUser ([Environment]::GetEnvironmentVariable('Path','User'))
    Assert-Task880 ((ConvertTo-Json $preservedBefore -Compress) -ceq (ConvertTo-Json $preservedAfter -Compress)) 'Real uninstall changed protected user/standalone bytes.'
    Assert-Task880 (-not [IO.File]::Exists((Join-Path $fixtureHome '.winsmux/install-owner.json')) -and -not [IO.File]::Exists($core)) 'Real uninstall retained unchanged owned support.'
    Assert-Task880 (Test-Task880Nullable ([Environment]::GetEnvironmentVariable('Path','User')) $beforeUninstallUser) 'Support-only uninstall changed standalone User PATH registration.'
    # Retain the installed-wrapper uninstall guarantee with a real second owned
    # generation; the route-specific npm/direct uninstall above already removed
    # its own inventory and proved preservation independently.
    $reinstall=Invoke-Task880Action 'update';Save-Task880Command 'wrapper-uninstall-preparation' $reinstall
    Assert-Task880 ($reinstall.ExitCode -eq 0) 'Could not prepare the real installed-wrapper uninstall.'
    [IO.File]::WriteAllText($config,'task880 modified wrapper-uninstall settings',[Text.UTF8Encoding]::new($false))
    $wrapperConfig=(Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    $wrapperUser=[Environment]::GetEnvironmentVariable('Path','User')
    $wrappedRemove=Invoke-CapturedProcess -FilePath $wrapper -Arguments @('uninstall');Save-Task880Command 'real-wrapper-uninstall' $wrappedRemove
    Assert-Task880 ($wrappedRemove.ExitCode -eq 0) 'Real installed wrapper uninstall failed.'
    $preservedBefore=[ordered]@{};$preservedAfter=[ordered]@{}
    foreach($pair in @(@{path=$project;sha=$projectHash},@{path=$unknown;sha=$unknownHash},@{path=$config;sha=$wrapperConfig},@{path=$native;sha=$beforeNative})) {
        $key=[IO.Path]::GetRelativePath($fixtureHome,$pair.path)
        $preservedBefore[$key]=$pair.sha
        $preservedAfter[$key]=if([IO.File]::Exists($pair.path)){(Get-FileHash -LiteralPath $pair.path -Algorithm SHA256).Hash}else{$null}
    }
    Save-Task880Equality 'real-wrapper-uninstall' (ConvertTo-Json $preservedBefore -Compress) (ConvertTo-Json $preservedAfter -Compress) $wrapperUser ([Environment]::GetEnvironmentVariable('Path','User'))
    Assert-Task880 ((ConvertTo-Json $preservedBefore -Compress) -ceq (ConvertTo-Json $preservedAfter -Compress)) 'Real wrapper uninstall changed protected bytes.'
    Assert-Task880 (Test-Task880Nullable ([Environment]::GetEnvironmentVariable('Path','User')) $wrapperUser) 'Real wrapper uninstall changed standalone PATH.'
    $realLifecycle=@{schema='task880-real-lifecycle/v1';passed=$true;state='passed';route=$Route;source_commit=$SourceCommit;product_installer_sha256=$fixtureProof.original_installer_sha256;transport_only=$true;real_pe_sha256=$beforeNative;normal_update=$true;external_rename_lock_restore=$true;transport_tamper_rejected=$true;transport_missing_rejected=$true;own_uncommitted_interruption=$crash.Interruption;pending_recovery_old_bytes=$true;missing_native_recovery=$true;real_uninstall=$true;project_unknown_modified_settings_standalone_preserved=$true;user_path_registration_actual=$true;same_version_generation_update=$true;different_version_migration='not_run'}
    $realLifecycle.commands=@($task880Evidence.commands.ToArray());$realLifecycle.preservation=@($task880Evidence.preservation.ToArray())
    $realLifecycle.initial_install=$true;$realLifecycle.real_wrapper_update=$true;$realLifecycle.real_wrapper_uninstall=$true
    [IO.File]::WriteAllText((Join-Path $realRoot 'result.json'),(ConvertTo-Json $realLifecycle -Depth 16),[Text.UTF8Encoding]::new($false))
    $environment=@{source_commit=$SourceCommit;profile_volume_guid=$profileVolume;home_volume_guid=$ownRootVolume;os=[Environment]::OSVersion.VersionString;architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();powershell=$PSVersionTable.PSVersion.ToString();node=(& $node --version | Out-String).Trim();npm=(& $npm --version | Out-String).Trim();candidate_receipt_sha256=$fixtureProof.candidate_receipt_sha256;pristine_transport_sha256=$fixtureProof.transport_sha256;tamper_transport_sha256=$faults.tamper.transport_sha256;missing_transport_sha256=$faults.missing.transport_sha256;package=if($Route -ceq 'Npm'){$packageEvidence}else{$null}}
    [IO.File]::WriteAllText((Join-Path $realRoot 'environment.json'),(ConvertTo-Json $environment -Depth 10),[Text.UTF8Encoding]::new($false))
} else {
$lifecycleProbePath = Join-Path $scratch 'lifecycle-probe.json'
$lifecycleProbeLiteral = $lifecycleProbePath.Replace("'", "''")
$lifecycleProbeScript = @"
param(
    [Parameter(Position=0)][string]`$Action,
    [Alias('Profile')][string]`$InstallProfile = ''
)
@{ action = `$Action; profile = `$InstallProfile } | ConvertTo-Json -Compress | Set-Content -LiteralPath '$lifecycleProbeLiteral' -Encoding UTF8
"@
[System.IO.File]::WriteAllText($installedInstaller, $lifecycleProbeScript, [System.Text.UTF8Encoding]::new($false))
Remove-Item -LiteralPath $native -Force
if (Test-Path -LiteralPath $native) { throw 'native recovery fixture could not remove the installed executable.' }
$updateResult = Invoke-CapturedProcess -FilePath $wrapper -Arguments @('update', '--profile', 'orchestra')
if ($updateResult.ExitCode -ne 0) { throw "installed wrapper update dispatch failed:`n$($updateResult.Combined)" }
$updateProbe = Get-Content -LiteralPath $lifecycleProbePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($updateProbe.action -ne 'update' -or $updateProbe.profile -ne 'orchestra') {
    throw "installed wrapper did not preserve update lifecycle arguments: $($updateProbe | ConvertTo-Json -Compress)"
}
$uninstallResult = Invoke-CapturedProcess -FilePath $wrapper -Arguments @('uninstall')
if ($uninstallResult.ExitCode -ne 0) { throw "installed wrapper uninstall dispatch failed:`n$($uninstallResult.Combined)" }
$uninstallProbe = Get-Content -LiteralPath $lifecycleProbePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($uninstallProbe.action -ne 'uninstall' -or -not [string]::IsNullOrWhiteSpace([string]$uninstallProbe.profile)) {
    throw "installed wrapper did not preserve uninstall lifecycle arguments: $($uninstallProbe | ConvertTo-Json -Compress)"
}

}

[ordered]@{
    schema_version = 1
    route = $Route
    private_candidate_transport = $candidateFixture
    real_lifecycle = $realLifecycle
    task880_result_path = if($isGitHubRunner){Join-Path $realRoot 'result.json'}else{$null}
    task880_environment_path = if($isGitHubRunner){Join-Path $realRoot 'environment.json'}else{$null}
    public_release_acquisition_proven = $false
    package_version = $Version
    native_asset_version = $expectedNativeVersion
    install_exit_code = $installResult.ExitCode
    wrapper_version_exit_code = $versionResult.ExitCode
    wrapper_raw_version_exit_code = $rawVersionResult.ExitCode
    wrapper_raw_command_forwarding_verified = $true
    wrapper_update_dispatch_verified = $true
    wrapper_uninstall_dispatch_verified = $true
    wrapper_lifecycle_without_native_verified = $true
    locked_native_update_verified = $lockedNativeUpdateVerified
    tagless_install_verified = $taglessInstallVerified
    wrapper_doctor_exit_code = $doctorResult.ExitCode
    wrapper_doctor_native_version_verified = $true
    wrapper_doctor_terminal_absence_verified = $true
    wrapper_launch_project_dir_verified = $true
    router_inventory = $routerInventory
    wrapper_target = $core
    native_target = $native
    fragment = $fragment
    scratch_root = $scratch
} | ConvertTo-Json -Depth 4
