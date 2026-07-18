[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateBinary
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$candidate = [System.IO.Path]::GetFullPath($CandidateBinary)
if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "Candidate binary not found: $candidate"
}
$pwshCommand = Get-Command pwsh -All -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path -notmatch '\\WindowsApps\\' -and (Test-Path -LiteralPath $_.Path -PathType Leaf) } |
    Select-Object -First 1
if ($null -eq $pwshCommand) {
    throw 'Native bridge E2E requires a non-WindowsApps PowerShell 7 executable.'
}
$pwshDirectory = Split-Path -Parent $pwshCommand.Path

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$scratch = Join-Path $tempRoot ("winsmux-native-bridge-{0}" -f [Guid]::NewGuid().ToString('N'))
$scratch = [System.IO.Path]::GetFullPath($scratch)
if (-not $scratch.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Scratch path escaped the temporary directory: $scratch"
}

$fixtureHome = Join-Path $scratch 'home'
$installedBin = Join-Path $fixtureHome '.winsmux\bin'
$localBin = Join-Path $fixtureHome '.local\bin'
$hostileRoot = Join-Path $scratch 'hostile-cwd'
$hostileScripts = Join-Path $hostileRoot 'scripts'
$native = Join-Path $localBin 'winsmux.exe'
$installedBridge = Join-Path $installedBin 'winsmux-core.ps1'
$hostileBridge = Join-Path $hostileScripts 'winsmux-core.ps1'
$installedMarker = Join-Path $scratch 'installed-bridge.json'
$hostileMarker = Join-Path $scratch 'hostile-bridge.txt'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Invoke-NativeLifecycleProbe {
    param([Parameter(Mandatory = $true)][string]$Action)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $native
    $startInfo.ArgumentList.Add($Action)
    $startInfo.WorkingDirectory = $hostileRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment.Clear()
    foreach ($name in @('SystemRoot', 'WINDIR', 'ComSpec', 'PATH', 'PATHEXT', 'PSModulePath')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $value) { $startInfo.Environment[$name] = $value }
    }
    $startInfo.Environment['PATH'] = "$pwshDirectory;$($startInfo.Environment['PATH'])"
    $startInfo.Environment['HOME'] = $fixtureHome
    $startInfo.Environment['USERPROFILE'] = $fixtureHome

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            throw "Native lifecycle probe timed out: $Action"
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult().Trim()
            StdErr = $stderrTask.GetAwaiter().GetResult().Trim()
        }
    } finally {
        $process.Dispose()
    }
}

try {
    New-Item -ItemType Directory -Path $installedBin, $localBin, $hostileScripts -Force | Out-Null
    Copy-Item -LiteralPath $candidate -Destination $native -Force

    $installedMarkerLiteral = $installedMarker.Replace("'", "''")
    $hostileMarkerLiteral = $hostileMarker.Replace("'", "''")
    $installedProbe = @"
param([Parameter(Position=0)][string]`$Action)
@{ action = `$Action } | ConvertTo-Json -Compress | Set-Content -LiteralPath '$installedMarkerLiteral' -Encoding UTF8
"@
    $hostileProbe = "Set-Content -LiteralPath '$hostileMarkerLiteral' -Value 'unexpected' -Encoding UTF8; exit 86"
    [System.IO.File]::WriteAllText($installedBridge, $installedProbe, $utf8)
    [System.IO.File]::WriteAllText($hostileBridge, $hostileProbe, $utf8)

    foreach ($action in @('install', 'update', 'uninstall')) {
        Remove-Item -LiteralPath $installedMarker, $hostileMarker -Force -ErrorAction SilentlyContinue
        $result = Invoke-NativeLifecycleProbe -Action $action
        if ($result.ExitCode -ne 0) {
            throw "Native lifecycle '$action' did not use the installed bridge: $($result.StdErr)"
        }
        if (Test-Path -LiteralPath $hostileMarker) {
            throw "Native lifecycle '$action' executed the hostile CWD bridge."
        }
        $record = Get-Content -LiteralPath $installedMarker -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record.action -ne $action) {
            throw "Installed bridge received '$($record.action)' instead of '$action'."
        }
    }

    Remove-Item -LiteralPath $installedBridge -Force
    foreach ($action in @('install', 'update', 'uninstall')) {
        Remove-Item -LiteralPath $hostileMarker -Force -ErrorAction SilentlyContinue
        $result = Invoke-NativeLifecycleProbe -Action $action
        if ($result.ExitCode -eq 0) {
            throw "Native lifecycle '$action' succeeded without an installed bridge."
        }
        if (Test-Path -LiteralPath $hostileMarker) {
            throw "Native lifecycle '$action' fell back to the hostile CWD bridge."
        }
    }

    [ordered]@{
        schema_version = 1
        lifecycle_actions = 3
        installed_bridge_selected = $true
        hostile_cwd_rejected = $true
        missing_installed_bridge_failed_closed = $true
    } | ConvertTo-Json -Compress
} finally {
    if (Test-Path -LiteralPath $scratch -PathType Container) {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
