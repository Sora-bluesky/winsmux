[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Npm', 'Direct', 'DefectDetection')]
    [string]$Route,
    [string]$RepositoryRoot = '',
    [string]$Version = '',
    [string]$ScratchRoot = '',
    [string]$SourceCommit = '',
    [switch]$AllowRedirectedLocal,
    [string]$RedirectNonce = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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

$scratch = if ([string]::IsNullOrWhiteSpace($ScratchRoot)) {
    $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    Join-Path $base ("winsmux-install-e2e-" + [System.Guid]::NewGuid().ToString('N'))
} else {
    [System.IO.Path]::GetFullPath($ScratchRoot)
}
if (Test-Path -LiteralPath $scratch) {
    throw "Scratch root must not exist before the run: $scratch"
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

$env:HOME = $fixtureHome
$env:USERPROFILE = $fixtureHome
$env:HOMEDRIVE = [System.IO.Path]::GetPathRoot($fixtureHome).TrimEnd('\')
$env:HOMEPATH = $fixtureHome.Substring($env:HOMEDRIVE.Length)
$env:TEMP = $temp
$env:TMP = $temp
$env:LOCALAPPDATA = $localAppData
$env:APPDATA = $appData
$env:npm_config_prefix = $npmPrefix
$env:npm_config_cache = $npmCache
$env:npm_config_userconfig = Join-Path $scratch 'npmrc'
$env:WINSMUX_RELEASE_TAG = "v$Version"
$env:WINSMUX_INSTALL_PROFILE = 'full'
if ($isGitHubRunner) {
    $env:WINSMUX_INSTALL_E2E = 'true'
    $env:WINSMUX_INSTALL_SOURCE_REF = $SourceCommit
} else {
    $env:WINSMUX_INSTALL_E2E = 'redirected'
    $env:WINSMUX_INSTALL_STATE_ROOT = Join-Path $fixtureHome '.winsmux-install-state'
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = $repoRoot,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 900
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment.Clear()
    foreach ($name in @(
        'SystemRoot', 'WINDIR', 'ComSpec', 'PATH', 'PATHEXT', 'PSModulePath',
        'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'PROCESSOR_ARCHITECTURE', 'NUMBER_OF_PROCESSORS',
        'HOME', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'TEMP', 'TMP', 'LOCALAPPDATA', 'APPDATA',
        'npm_config_prefix', 'npm_config_cache', 'npm_config_userconfig',
        'WINSMUX_RELEASE_TAG', 'WINSMUX_INSTALL_PROFILE', 'WINSMUX_INSTALL_E2E',
        'WINSMUX_INSTALL_E2E_RELEASE_TAG', 'WINSMUX_INSTALL_SOURCE_REF', 'WINSMUX_INSTALL_STATE_ROOT', 'GITHUB_ACTIONS'
    )) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $value) { $startInfo.Environment[$name] = $value }
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
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
            StdOut = $stdout.Trim()
            StdErr = $stderr.Trim()
            Combined = ($stdout + [Environment]::NewLine + $stderr).Trim()
        }
    } finally {
        $process.Dispose()
    }
}

$pwsh = (Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source
$node = (Get-Command node -ErrorAction Stop | Select-Object -First 1).Source
$npm = (Get-Command npm.cmd -ErrorAction Stop | Select-Object -First 1).Source
$installerPath = Join-Path $repoRoot 'install.ps1'

function Invoke-IrmInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$SourceInstaller,
        [Parameter(Mandatory = $true)][string]$ServerDirectory
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
        $result = Invoke-CapturedProcess -FilePath $pwsh -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command)
        if (-not $server.WaitForExit(15000)) { throw 'Loopback installer server did not exit after serving install.ps1.' }
        $serverError = $server.StandardError.ReadToEnd().Trim()
        if ($server.ExitCode -ne 0) { throw "Loopback installer server failed: $serverError" }
        return $result
    } finally {
        if (-not $server.HasExited) { $server.Kill($true) }
        $server.Dispose()
    }
}

if ($Route -eq 'DefectDetection') {
    $brokenInstaller = Join-Path $scratch 'install-pre-fix.ps1'
    $source = Get-Content -LiteralPath $installerPath -Raw -Encoding UTF8
    $anchor = '    Download-File "scripts/winsmux-core.ps1" (Join-Path $SCRIPT_DIR "winsmux-core.ps1")'
    if (-not $source.Contains($anchor)) {
        throw 'Could not construct the pre-fix installer fixture.'
    }
    $broken = $source.Replace($anchor, $anchor + [Environment]::NewLine + [Environment]::NewLine + '    Download-File "winsmux.ps1" (Join-Path $BIN_DIR "winsmux.ps1")')
    [System.IO.File]::WriteAllText($brokenInstaller, $broken, [System.Text.UTF8Encoding]::new($false))
    $result = Invoke-IrmInstaller -SourceInstaller $brokenInstaller -ServerDirectory (Join-Path $scratch 'pre-fix-server')
    if ($result.ExitCode -eq 0 -or $result.Combined -notmatch 'winsmux\.ps1' -or $result.Combined -notmatch '404|Not Found|Failed to download') {
        throw "Pre-fix defect was not detected as expected. exit=$($result.ExitCode)`n$($result.Combined)"
    }
    [ordered]@{
        schema_version = 1
        route = $Route
        expected_failure_exit_code = $result.ExitCode
        detected_missing_target = 'winsmux.ps1'
        scratch_root = $scratch
    } | ConvertTo-Json -Depth 4
    exit 0
}

$installResult = $null
if ($Route -eq 'Npm') {
    $stage = Join-Path $scratch 'stage'
    $stageResult = Invoke-CapturedProcess -FilePath $node -Arguments @(
        (Join-Path $repoRoot 'scripts\stage-npm-release.mjs'), '--version', $Version, '--out', $stage
    )
    if ($stageResult.ExitCode -ne 0) { throw "npm stage failed:`n$($stageResult.Combined)" }
    $packResult = Invoke-CapturedProcess -FilePath $npm -Arguments @('pack', '--json') -WorkingDirectory $stage
    if ($packResult.ExitCode -ne 0) { throw "npm pack failed:`n$($packResult.Combined)" }
    $pack = $packResult.StdOut | ConvertFrom-Json -Depth 10
    $tarball = Join-Path $stage $pack[0].filename
    $npmInstall = Invoke-CapturedProcess -FilePath $npm -Arguments @('install', '--global', '--prefix', $npmPrefix, $tarball)
    if ($npmInstall.ExitCode -ne 0) { throw "npm global install failed:`n$($npmInstall.Combined)" }
    $npmShim = Join-Path $npmPrefix 'winsmux.cmd'
    if (-not (Test-Path -LiteralPath $npmShim -PathType Leaf)) { throw "npm shim missing: $npmShim" }
    $installResult = Invoke-CapturedProcess -FilePath $npmShim -Arguments @('install', '--profile', 'full')
} else {
    $installResult = Invoke-IrmInstaller -SourceInstaller $installerPath -ServerDirectory (Join-Path $scratch 'direct-server')
}
if ($installResult.ExitCode -ne 0) { throw "$Route full install failed:`n$($installResult.Combined)" }
if ($installResult.Combined -match '\[winsmux\]\s+Failed to download\b') {
    throw "$Route install log contains an installer download failure:`n$($installResult.Combined)"
}

$core = Join-Path $fixtureHome '.winsmux\bin\winsmux-core.ps1'
$wrapper = Join-Path $fixtureHome '.winsmux\bin\winsmux.cmd'
$native = Join-Path $fixtureHome '.local\bin\winsmux.exe'
$manifestPath = Join-Path $fixtureHome '.winsmux\install-profile.json'
$fragment = Join-Path $localAppData 'Microsoft\Windows Terminal\Fragments\winsmux\winsmux.json'
foreach ($path in @($core, $wrapper, $native, $manifestPath, $fragment)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "installed artifact missing: $path" }
}

$wrapperText = Get-Content -LiteralPath $wrapper -Raw -Encoding ASCII
if ($wrapperText -notmatch 'winsmux-core\.ps1' -or $wrapperText -match '(?<!-core)winsmux\.ps1' -or
    $wrapperText -notmatch 'WINSMUX_RAW_EXE=%USERPROFILE%\\\.local\\bin\\winsmux\.exe') {
    throw 'winsmux.cmd does not bind the bridge to the installed native and PowerShell entrypoints.'
}
$fragmentText = Get-Content -LiteralPath $fragment -Raw -Encoding UTF8
if ($fragmentText -notmatch 'winsmux\.cmd' -or $fragmentText -notmatch 'launch --project-dir' -or $fragmentText -match 'winsmux\.ps1|start -C') {
    throw 'Windows Terminal fragment does not use the canonical installed launch entrypoint.'
}

$env:PATH = "$(Split-Path -Parent $wrapper);$(Split-Path -Parent $native);$env:PATH"
$expectedNativeVersion = if ($isGitHubRunner -and -not [string]::IsNullOrWhiteSpace($env:WINSMUX_INSTALL_E2E_RELEASE_TAG)) {
    $env:WINSMUX_INSTALL_E2E_RELEASE_TAG.TrimStart('v', 'V')
} else {
    $Version
}
$versionResult = Invoke-CapturedProcess -FilePath $wrapper -Arguments @('version')
if ($versionResult.ExitCode -ne 0 -or $versionResult.StdOut -ne "winsmux $Version") {
    throw "installed wrapper version failed: exit=$($versionResult.ExitCode) output=$($versionResult.Combined)"
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
if ($manifest.profile -ne 'full' -or $manifest.version -ne $expectedNativeVersion -or $manifest.release_tag -ne "v$expectedNativeVersion") {
    throw 'Installed profile manifest does not match the requested full release.'
}

[ordered]@{
    schema_version = 1
    route = $Route
    package_version = $Version
    native_asset_version = $expectedNativeVersion
    install_exit_code = $installResult.ExitCode
    wrapper_version_exit_code = $versionResult.ExitCode
    wrapper_doctor_exit_code = $doctorResult.ExitCode
    wrapper_doctor_native_version_verified = $true
    wrapper_doctor_terminal_absence_verified = $true
    wrapper_launch_project_dir_verified = $true
    wrapper_target = $core
    native_target = $native
    fragment = $fragment
    scratch_root = $scratch
} | ConvertTo-Json -Depth 4
