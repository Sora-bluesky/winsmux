[CmdletBinding()]
param(
    [string]$ProjectDir = '.winsmux/evidence/v03623-coordination-benchmark-project',
    [string]$PackPath = 'tasks/cli-bakeoff/v1/benchmark-pack.json',
    [int]$DebugPort = 9237,
    [switch]$SkipBuild,
    [switch]$NoLaunch,
    [switch]$AllowDirty,
    [switch]$NoMoveToExtendedDisplay,
    [switch]$SelfTestPathNormalization,
    [switch]$Json,
    [int]$VisibleWidth = 1440,
    [int]$VisibleHeight = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

function Convert-ToCanonicalPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    return [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathInsideRepo {
    param([AllowNull()][string]$Path)

    $candidate = Convert-ToCanonicalPath $Path
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $false
    }

    if ($candidate.Equals($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $repoPrefix = $RepoRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    return $candidate.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [string]$WorkingDirectory = $RepoRoot
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')"
        }
    } finally {
        Pop-Location
    }
}

function Copy-BenchmarkTaskPack {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$DestinationDir
    )

    if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
        throw "Benchmark task pack source was not found: $SourceDir"
    }

    New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    Get-ChildItem -LiteralPath $SourceDir -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $DestinationDir $_.Name) -Force
    }
}

function Stop-RepoWinsmuxDesktopTree {
    $processes = @(Get-CimInstance Win32_Process)
    $appPids = @(
        $processes |
            Where-Object {
                $_.Name -eq 'winsmux-app.exe' -and
                (Test-PathInsideRepo ([string]$_.ExecutablePath))
            } |
            ForEach-Object { [int]$_.ProcessId }
    )

    if ($appPids.Count -eq 0) {
        return
    }

    $ids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($pidValue in $appPids) {
        [void]$ids.Add($pidValue)
    }

    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($process in $processes) {
            if ($ids.Contains([int]$process.ParentProcessId) -and -not $ids.Contains([int]$process.ProcessId)) {
                [void]$ids.Add([int]$process.ProcessId)
                $changed = $true
            }
        }
    }

    foreach ($id in (@($ids) | Sort-Object -Descending)) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds(15)
    do {
        $remaining = @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($remaining.Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    throw "Existing repo-built winsmux desktop process did not exit: $($remaining -join ', ')"
}

function Wait-RepoWinsmuxDesktopApp {
    param(
        [int]$TimeoutSeconds = 120,
        [int]$ExpectedProcessId = 0
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $candidate = Get-CimInstance Win32_Process |
            Where-Object {
                $_.Name -eq 'winsmux-app.exe' -and
                (Test-PathInsideRepo ([string]$_.ExecutablePath)) -and
                ($ExpectedProcessId -le 0 -or [int]$_.ProcessId -eq $ExpectedProcessId)
            } |
            Sort-Object ProcessId -Descending |
            Select-Object -First 1
        if ($null -ne $candidate) {
            return $candidate
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    throw "winsmux desktop app did not start within $TimeoutSeconds seconds."
}

function Assert-ProductionDesktopPage {
    param([int]$Port, [int]$TimeoutSeconds = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = ''
    do {
        try {
            $pages = @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 2)
            $urls = @($pages | ForEach-Object { [string]$_.url })
            if ($urls.Count -gt 0) {
                if ($urls | Where-Object { $_ -match '^http://(localhost|127\.0\.0\.1):1420/?' }) {
                    throw 'winsmux desktop is using the Tauri dev server URL instead of the production page.'
                }
                if (-not ($urls | Where-Object { $_ -match 'tauri\.localhost|tauri://localhost' })) {
                    throw "winsmux desktop did not expose a production Tauri page. urls=$($urls -join ', ')"
                }
                return @{
                    mode = 'production'
                    urls = $urls
                }
            }
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    throw "Could not verify the production desktop page on port $Port. Last error: $lastError"
}

function Get-WindowMetrics {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    Add-Type -AssemblyName System.Windows.Forms
    if (-not ('WinsmuxBenchmarkUser32' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class WinsmuxBenchmarkUser32 {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
    }

    $deadline = (Get-Date).AddSeconds(30)
    $handle = [IntPtr]::Zero
    do {
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -ne $process) {
            $process.Refresh()
            $handle = $process.MainWindowHandle
            if ($handle -ne [IntPtr]::Zero) {
                break
            }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    if ($handle -eq [IntPtr]::Zero) {
        throw 'winsmux desktop app started, but no visible window handle was found.'
    }

    $rect = New-Object WinsmuxBenchmarkUser32+RECT
    [void][WinsmuxBenchmarkUser32]::GetWindowRect($handle, [ref]$rect)
    return [pscustomobject]@{
        handle = $handle.ToInt64()
        x = [int]$rect.Left
        y = [int]$rect.Top
        width = [int]($rect.Right - $rect.Left)
        height = [int]($rect.Bottom - $rect.Top)
    }
}

function Move-WindowToVisibleWorkspace {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int]$Width,
        [int]$Height
    )

    $metrics = Get-WindowMetrics -ProcessId $ProcessId
    $handle = [IntPtr]$metrics.handle
    $screens = @([System.Windows.Forms.Screen]::AllScreens)
    $targetScreen = $screens | Where-Object { -not $_.Primary } | Select-Object -First 1
    if ($null -eq $targetScreen) {
        $targetScreen = $screens | Select-Object -First 1
    }
    $area = $targetScreen.WorkingArea
    $targetWidth = [Math]::Max([int]$area.Width, $Width)
    $targetHeight = [Math]::Max([int]$area.Height, $Height)

    [void][WinsmuxBenchmarkUser32]::ShowWindow($handle, 9)
    [void][WinsmuxBenchmarkUser32]::MoveWindow($handle, [int]$area.X, [int]$area.Y, $targetWidth, $targetHeight, $true)
    [void][WinsmuxBenchmarkUser32]::ShowWindow($handle, 3)
    Start-Sleep -Milliseconds 500
    return Get-WindowMetrics -ProcessId $ProcessId
}

if ($SelfTestPathNormalization) {
    $releaseAppSelfTestPath = Join-Path $RepoRoot 'target\release\winsmux-app.exe'
    $forwardSlashPath = $releaseAppSelfTestPath -replace '\\', '/'
    $siblingRepoPath = $RepoRoot.TrimEnd('\', '/') + '-sibling\target\release\winsmux-app.exe'

    $result = [pscustomobject]@{
        ok = (Test-PathInsideRepo $releaseAppSelfTestPath) -and
            (Test-PathInsideRepo $forwardSlashPath) -and
            -not (Test-PathInsideRepo $siblingRepoPath)
        repoRoot = $RepoRoot
        releaseAppPath = $releaseAppSelfTestPath
    }

    if (-not $result.ok) {
        throw 'Path normalization self-test failed.'
    }

    if ($Json) {
        $result | ConvertTo-Json -Depth 4
    } else {
        Write-Output 'winsmux desktop path normalization self-test passed.'
    }
    exit 0
}

$resolvedProjectDir = Resolve-RepoPath $ProjectDir
$resolvedPackPath = Resolve-RepoPath $PackPath
$canonicalTaskDir = Split-Path $resolvedPackPath -Parent
$projectTaskDir = Join-Path $resolvedProjectDir 'tasks\cli-bakeoff\v1'
$releaseCli = Join-Path $RepoRoot 'target\release\winsmux.exe'
$releaseApp = Join-Path $RepoRoot 'target\release\winsmux-app.exe'
$version = (Get-Content -LiteralPath (Join-Path $RepoRoot 'VERSION') -Raw -Encoding UTF8).Trim()
$head = (& git -C $RepoRoot rev-parse HEAD | Out-String).Trim()

New-Item -ItemType Directory -Path $resolvedProjectDir -Force | Out-Null
Copy-BenchmarkTaskPack -SourceDir $canonicalTaskDir -DestinationDir $projectTaskDir

if (-not $SkipBuild) {
    Invoke-CheckedCommand -FilePath 'cargo' -ArgumentList @('build', '--release', '-p', 'winsmux') -WorkingDirectory $RepoRoot
    Invoke-CheckedCommand -FilePath 'npm' -ArgumentList @('run', 'tauri', '--', 'build', '--no-bundle') -WorkingDirectory (Join-Path $RepoRoot 'winsmux-app')
}

$preflightArgs = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    (Join-Path $RepoRoot 'scripts\test-cli-bakeoff-preflight.ps1'),
    '-PackPath',
    $resolvedProjectDir,
    '-Json',
    '-RequireCandidateIdentity',
    '-ExpectedVersion',
    $version,
    '-ExpectedGitHead',
    $head,
    '-CandidateDesktopBinary',
    $releaseApp,
    '-CandidateCliBinary',
    $releaseCli
)
if ($AllowDirty) {
    $preflightArgs += '-AllowDirty'
}
$preflightJson = (& pwsh @preflightArgs | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Benchmark preflight failed before desktop launch.`n$preflightJson"
}
$preflight = $preflightJson | ConvertFrom-Json -Depth 100
if (-not [bool]$preflight.all_pass) {
    throw "Benchmark preflight did not pass before desktop launch.`n$preflightJson"
}

if ($NoLaunch) {
    $result = [pscustomobject]@{
        ok = $true
        launch = 'skipped'
        projectDir = $resolvedProjectDir
        packPath = $resolvedPackPath
        projectPackPath = Join-Path $projectTaskDir 'benchmark-pack.json'
        version = $version
        gitHead = $head
        releaseCli = $releaseCli
        releaseApp = $releaseApp
        preflight = $preflight
    }
    if ($Json) {
        $result | ConvertTo-Json -Depth 100
    } else {
        Write-Output "winsmux Harness Bench desktop path is ready."
        Write-Output "launch: skipped"
        Write-Output "version: $version"
        Write-Output "pack: $($result.projectPackPath)"
        Write-Output "preflight: $($preflight.check_count) checks, $($preflight.failed_count) failures"
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $releaseApp -PathType Leaf)) {
    throw "Production desktop executable was not found: $releaseApp"
}

Stop-RepoWinsmuxDesktopTree

$webviewUserData = Join-Path $RepoRoot '.winsmux\tmp\webview2-v03623-harness'
New-Item -ItemType Directory -Path $webviewUserData -Force | Out-Null
$env:WINSMUX_BIN = $releaseCli
$env:WINSMUX_ORCHESTRA_PROJECT_DIR = $resolvedProjectDir
$env:WINSMUX_ORCHESTRA_ATTACH_MODE = 'desktop-app'
$env:WINSMUX_ORCHESTRA_DISABLE_POWERSHELL_ATTACH = '1'
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$DebugPort --remote-allow-origins=*"
$env:WEBVIEW2_USER_DATA_FOLDER = $webviewUserData
$env:NO_COLOR = '1'

$launcherProcess = Start-Process -FilePath $releaseApp -ArgumentList @('--project-dir', $resolvedProjectDir) -WorkingDirectory $RepoRoot -PassThru
$app = Wait-RepoWinsmuxDesktopApp -ExpectedProcessId ([int]$launcherProcess.Id)
$page = Assert-ProductionDesktopPage -Port $DebugPort
$metricsBeforeMove = Get-WindowMetrics -ProcessId ([int]$app.ProcessId)
if (-not $NoMoveToExtendedDisplay) {
    $metricsAfterMove = Move-WindowToVisibleWorkspace -ProcessId ([int]$app.ProcessId) -Width $VisibleWidth -Height $VisibleHeight
} else {
    $metricsAfterMove = $metricsBeforeMove
}

if ([int]$metricsAfterMove.width -lt $VisibleWidth -or [int]$metricsAfterMove.height -lt $VisibleHeight) {
    throw "winsmux desktop window is smaller than required after launch: $($metricsAfterMove.width)x$($metricsAfterMove.height)"
}

$result = [pscustomobject]@{
    ok = $true
    launch = 'production-desktop'
    launcherPid = [int]$launcherProcess.Id
    appPid = [int]$app.ProcessId
    projectDir = $resolvedProjectDir
    projectPackPath = Join-Path $projectTaskDir 'benchmark-pack.json'
    releaseCli = $releaseCli
    releaseApp = $releaseApp
    debugPort = $DebugPort
    page = $page
    windowBeforeMove = $metricsBeforeMove
    windowAfterMove = $metricsAfterMove
    attachMode = $env:WINSMUX_ORCHESTRA_ATTACH_MODE
    powershellAttach = 'disabled'
    preflight = $preflight
}
if ($Json) {
    $result | ConvertTo-Json -Depth 100
} else {
    Write-Output "winsmux Harness Bench desktop path is ready."
    Write-Output "launch: production desktop"
    Write-Output "app pid: $($result.appPid)"
    Write-Output "version: $version"
    Write-Output "pack: $($result.projectPackPath)"
    Write-Output "window: $($metricsAfterMove.width)x$($metricsAfterMove.height)"
    Write-Output "preflight: $($preflight.check_count) checks, $($preflight.failed_count) failures"
}
