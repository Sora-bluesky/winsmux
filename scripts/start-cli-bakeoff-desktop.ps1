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

function Assert-DesktopBuildToolsAvailable {
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if ($null -eq $npm) {
        throw 'npm is required to build the desktop app, but it was not found on PATH.'
    }

    $localTauri = Join-Path $RepoRoot 'winsmux-app\node_modules\.bin\tauri.cmd'
    $pathTauri = Get-Command tauri -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $localTauri -PathType Leaf) -and $null -eq $pathTauri) {
        throw "Tauri CLI is required before the desktop release build starts. Run npm ci in winsmux-app or add @tauri-apps/cli to PATH. Missing: $localTauri"
    }

    return [pscustomobject]@{
        npm = [string]$npm.Source
        tauri = if (Test-Path -LiteralPath $localTauri -PathType Leaf) { $localTauri } else { [string]$pathTauri.Source }
    }
}

function Assert-DesktopExecutableFreshForDist {
    param(
        [Parameter(Mandatory = $true)][string]$DesktopExecutable,
        [string]$DistDir = (Join-Path $RepoRoot 'winsmux-app\dist')
    )

    if (-not (Test-Path -LiteralPath $DesktopExecutable -PathType Leaf)) {
        throw "Production desktop executable was not found: $DesktopExecutable"
    }
    if (-not (Test-Path -LiteralPath $DistDir -PathType Container)) {
        throw "Desktop dist directory was not found: $DistDir"
    }

    $newestDistFile = Get-ChildItem -LiteralPath $DistDir -Recurse -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $newestDistFile) {
        throw "Desktop dist directory is empty: $DistDir"
    }

    $desktopFile = Get-Item -LiteralPath $DesktopExecutable
    if ($desktopFile.LastWriteTimeUtc -lt $newestDistFile.LastWriteTimeUtc) {
        throw "Production desktop executable is older than winsmux-app/dist. Rebuild the desktop app before launch. exeUtc=$($desktopFile.LastWriteTimeUtc.ToString('o')) newestDistUtc=$($newestDistFile.LastWriteTimeUtc.ToString('o')) newestDistFile=$($newestDistFile.FullName)"
    }

    $assetIntegrity = Assert-DesktopDistAssetIntegrity -DistDir $DistDir

    return [pscustomobject]@{
        desktopExecutableUtc = $desktopFile.LastWriteTimeUtc.ToString('o')
        newestDistUtc = $newestDistFile.LastWriteTimeUtc.ToString('o')
        newestDistFile = $newestDistFile.FullName
        distIndexHtml = $assetIntegrity.indexHtml
        distAssetReferenceCount = $assetIntegrity.assetReferenceCount
    }
}

function Assert-DesktopDistAssetIntegrity {
    param([Parameter(Mandatory = $true)][string]$DistDir)

    $indexHtmlPath = Join-Path $DistDir 'index.html'
    if (-not (Test-Path -LiteralPath $indexHtmlPath -PathType Leaf)) {
        throw "Desktop dist index.html was not found: $indexHtmlPath"
    }

    $html = Get-Content -LiteralPath $indexHtmlPath -Raw -Encoding UTF8
    $matches = [regex]::Matches($html, '(?i)\b(?:src|href)=["'']([^"'']+)["'']')
    $references = @($matches | ForEach-Object { [string]$_.Groups[1].Value } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $appReferences = @($references | Where-Object {
            $_ -match '^\.?/?(?:assets/|startup\.css|favicon\.(?:svg|ico)|apple-touch-icon\.png)'
        })

    $rootAnchoredReferences = @($appReferences | Where-Object { $_ -match '^/' })
    if ($rootAnchoredReferences.Count -gt 0) {
        throw "Desktop dist index.html contains root-anchored asset URLs that can render as a blank packaged Tauri page: $($rootAnchoredReferences -join ', ')"
    }

    $missingReferences = @()
    foreach ($reference in $appReferences) {
        $pathPart = ($reference -replace '[?#].*$', '')
        $relativePath = $pathPart -replace '^\./', ''
        if ($relativePath -match '^\.\./') {
            $missingReferences += $reference
            continue
        }

        $assetPath = Join-Path $DistDir ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
            $missingReferences += $reference
        }
    }

    if ($missingReferences.Count -gt 0) {
        throw "Desktop dist index.html references missing packaged assets: $($missingReferences -join ', ')"
    }

    return [pscustomobject]@{
        indexHtml = $indexHtmlPath
        assetReferenceCount = $appReferences.Count
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

function Assert-NoExternalWinsmuxDesktopApp {
    $externalApps = @(
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.Name -eq 'winsmux-app.exe' -and
                -not (Test-PathInsideRepo ([string]$_.ExecutablePath))
            } |
            Select-Object ProcessId, ExecutablePath, CommandLine
    )

    if ($externalApps.Count -gt 0) {
        $details = ($externalApps | ForEach-Object { "pid=$($_.ProcessId) exe=$($_.ExecutablePath)" }) -join '; '
        throw "External winsmux desktop app is already running. Close it before benchmark launch. $details"
    }
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

function Invoke-WebViewDevToolsRuntimeExpression {
    param(
        [Parameter(Mandatory = $true)][string]$WebSocketDebuggerUrl,
        [Parameter(Mandatory = $true)][string]$Expression,
        [int]$TimeoutSeconds = 5
    )

    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $cancellation = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        [void]$socket.ConnectAsync([Uri]$WebSocketDebuggerUrl, $cancellation.Token).GetAwaiter().GetResult()
        $request = @{
            id = 1
            method = 'Runtime.evaluate'
            params = @{
                expression = $Expression
                returnByValue = $true
                awaitPromise = $true
            }
        } | ConvertTo-Json -Depth 12 -Compress
        $requestBytes = [System.Text.Encoding]::UTF8.GetBytes($request)
        $sendBuffer = [ArraySegment[byte]]::new($requestBytes)
        [void]$socket.SendAsync($sendBuffer, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cancellation.Token).GetAwaiter().GetResult()

        $receiveBytes = New-Object byte[] 65536
        while ($true) {
            $chunks = [System.Collections.Generic.List[byte]]::new()
            do {
                $receiveBuffer = [ArraySegment[byte]]::new($receiveBytes)
                $receiveResult = $socket.ReceiveAsync($receiveBuffer, $cancellation.Token).GetAwaiter().GetResult()
                if ($receiveResult.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    throw 'DevTools runtime websocket closed before an evaluation response was received.'
                }
                for ($index = 0; $index -lt $receiveResult.Count; $index++) {
                    [void]$chunks.Add($receiveBytes[$index])
                }
            } while (-not $receiveResult.EndOfMessage)

            if ($chunks.Count -eq 0) {
                continue
            }

            $responseText = [System.Text.Encoding]::UTF8.GetString($chunks.ToArray())
            $response = $responseText | ConvertFrom-Json -Depth 100
            $idProperty = $response.PSObject.Properties['id']
            if ($null -eq $idProperty -or [int]$idProperty.Value -ne 1) {
                continue
            }

            $errorProperty = $response.PSObject.Properties['error']
            if ($null -ne $errorProperty -and $null -ne $errorProperty.Value) {
                $errorMessageProperty = $errorProperty.Value.PSObject.Properties['message']
                $errorMessage = if ($null -ne $errorMessageProperty) { [string]$errorMessageProperty.Value } else { 'unknown error' }
                throw "DevTools runtime evaluation failed: $errorMessage"
            }
            $resultProperty = $response.PSObject.Properties['result']
            if ($null -eq $resultProperty -or $null -eq $resultProperty.Value) {
                throw 'DevTools runtime evaluation did not return a result envelope.'
            }
            $resultEnvelope = $resultProperty.Value
            $exceptionProperty = $resultEnvelope.PSObject.Properties['exceptionDetails']
            if ($null -ne $exceptionProperty -and $null -ne $exceptionProperty.Value) {
                $exceptionTextProperty = $exceptionProperty.Value.PSObject.Properties['text']
                $exceptionText = if ($null -ne $exceptionTextProperty) { [string]$exceptionTextProperty.Value } else { 'unknown exception' }
                throw "DevTools runtime evaluation threw an exception: $exceptionText"
            }
            $runtimeResultProperty = $resultEnvelope.PSObject.Properties['result']
            if ($null -eq $runtimeResultProperty -or $null -eq $runtimeResultProperty.Value) {
                throw 'DevTools runtime evaluation did not return a runtime result.'
            }
            $valueProperty = $runtimeResultProperty.Value.PSObject.Properties['value']
            if ($null -eq $valueProperty) {
                throw 'DevTools runtime evaluation did not return a by-value result.'
            }

            return $valueProperty.Value
        }
    } finally {
        if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            try {
                [void]$socket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            } catch {
            }
        }
        $socket.Dispose()
        $cancellation.Dispose()
    }
}

function Convert-ToFlatObjectArray {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return @()
    }

    $items = [System.Collections.Generic.List[object]]::new()
    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            foreach ($flatItem in @(Convert-ToFlatObjectArray $item)) {
                $null = $items.Add($flatItem)
            }
        }
    } else {
        $null = $items.Add($Value)
    }

    return @($items)
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Test-DesktopOperatorSurface {
    param([Parameter(Mandatory = $true)]$Page)

    $webSocketDebuggerUrlProperty = $Page.PSObject.Properties['webSocketDebuggerUrl']
    $webSocketDebuggerUrl = if ($null -ne $webSocketDebuggerUrlProperty) { [string]$webSocketDebuggerUrlProperty.Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($webSocketDebuggerUrl)) {
        throw 'Production desktop page does not expose a DevTools websocket URL.'
    }

    $expression = @'
(() => {
  const requiredSelectors = [
    "#app-shell",
    "#workspace",
    "#operator-terminal-panel",
    "#composer",
    "#composer-input",
    "#panes-container"
  ];
  const missingSelectors = requiredSelectors.filter((selector) => !document.querySelector(selector));
  const title = document.title || "";
  const href = location.href || "";
  const bodyText = ((document.body && document.body.innerText) || "").slice(0, 4000);
  const browserErrorPattern = /(ERR_CONNECTION_REFUSED|refused to connect|This site can't be reached|This site cannot be reached|localhost:1420|127\.0\.0\.1:1420)/i;
  const hasBrowserError = browserErrorPattern.test(title) || browserErrorPattern.test(bodyText);
  const tauriInvokeAvailable = Boolean(window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke);
  return JSON.stringify({
    ok: document.readyState !== "loading" && missingSelectors.length === 0 && !hasBrowserError && tauriInvokeAvailable,
    readyState: document.readyState,
    title,
    href,
    missingSelectors,
    hasBrowserError,
    browserErrorSnippet: hasBrowserError ? bodyText.slice(0, 300) : "",
    tauriInvokeAvailable
  });
})()
'@

    $surfaceJson = [string](Invoke-WebViewDevToolsRuntimeExpression -WebSocketDebuggerUrl $webSocketDebuggerUrl -Expression $expression)
    if ([string]::IsNullOrWhiteSpace($surfaceJson)) {
        throw 'DevTools operator surface evaluation returned an empty result.'
    }
    try {
        $surface = $surfaceJson | ConvertFrom-Json -Depth 20
    } catch {
        $surfaceSnippet = $surfaceJson.Substring(0, [Math]::Min(200, $surfaceJson.Length))
        throw "DevTools operator surface evaluation did not return valid JSON. snippet=$surfaceSnippet error=$($_.Exception.Message)"
    }
    $surfaceOk = Get-ObjectPropertyValue -Object $surface -Name 'ok'
    if ($null -eq $surfaceOk) {
        $properties = @($surface.PSObject.Properties | ForEach-Object { $_.Name })
        throw "DevTools operator surface evaluation did not return an ok property. properties=$($properties -join ',')"
    }

    if (-not [bool]$surfaceOk) {
        $reasons = @()
        $readyState = [string](Get-ObjectPropertyValue -Object $surface -Name 'readyState')
        if ($readyState -eq 'loading') {
            $reasons += 'readyState=loading'
        }
        $missingSelectors = @(Get-ObjectPropertyValue -Object $surface -Name 'missingSelectors')
        if ($missingSelectors.Count -gt 0) {
            $reasons += "missingSelectors=$($missingSelectors -join ',')"
        }
        $tauriInvokeAvailable = Get-ObjectPropertyValue -Object $surface -Name 'tauriInvokeAvailable'
        if (-not [bool]$tauriInvokeAvailable) {
            $reasons += 'tauriInvokeAvailable=false'
        }
        $hasBrowserError = Get-ObjectPropertyValue -Object $surface -Name 'hasBrowserError'
        if ([bool]$hasBrowserError) {
            $browserErrorSnippet = Get-ObjectPropertyValue -Object $surface -Name 'browserErrorSnippet'
            $reasons += "browserError=$browserErrorSnippet"
        }
        if ($reasons.Count -eq 0) {
            $reasons += 'unknown'
        }
        $href = Get-ObjectPropertyValue -Object $surface -Name 'href'
        $title = Get-ObjectPropertyValue -Object $surface -Name 'title'
        throw "winsmux desktop page is not a usable operator UI yet. $($reasons -join '; ') location=$href title=$title"
    }

    return $surface
}

function Assert-ProductionDesktopPage {
    param([int]$Port, [int]$TimeoutSeconds = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = ''
    do {
        try {
            $pages = @(Convert-ToFlatObjectArray (Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 2))
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 500
            continue
        }

        $urls = @($pages | ForEach-Object {
                $urlProperty = $_.PSObject.Properties['url']
                if ($null -ne $urlProperty) {
                    [string]$urlProperty.Value
                }
            })
        if ($urls.Count -gt 0) {
            if ($urls | Where-Object { $_ -match '^http://(localhost|127\.0\.0\.1):1420/?' }) {
                throw 'winsmux desktop is using the Tauri dev server URL instead of the production page.'
            }

            $productionPages = @($pages | Where-Object {
                    $urlProperty = $_.PSObject.Properties['url']
                    $null -ne $urlProperty -and [string]$urlProperty.Value -match 'tauri\.localhost|tauri://localhost'
                })
            if ($productionPages.Count -gt 0) {
                foreach ($productionPage in $productionPages) {
                    try {
                        $operatorSurface = Test-DesktopOperatorSurface -Page $productionPage
                        return @{
                            mode = 'production'
                            urls = $urls
                            operatorSurface = $operatorSurface
                        }
                    } catch {
                        $lastError = $_.Exception.Message
                        if ($lastError -match 'ERR_CONNECTION_REFUSED|refused to connect|browserError=') {
                            throw $lastError
                        }
                    }
                }
            } else {
                $lastError = "winsmux desktop did not expose a production Tauri page. urls=$($urls -join ', ')"
            }
        } else {
            $lastError = 'winsmux desktop DevTools endpoint returned no page URLs.'
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    throw "Could not verify the production desktop operator UI on port $Port. Last error: $lastError"
}

function Initialize-WinsmuxBenchmarkUser32 {
    Add-Type -AssemblyName System.Windows.Forms
    if (-not ('WinsmuxBenchmarkUser32' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WinsmuxBenchmarkUser32 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int processId);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
    }
}

function Get-WindowMetrics {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    Initialize-WinsmuxBenchmarkUser32

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

function Get-ProcessTreeIds {
    param([Parameter(Mandatory = $true)][int]$RootProcessId)

    $processes = @(Get-CimInstance Win32_Process)
    $ids = [System.Collections.Generic.HashSet[int]]::new()
    [void]$ids.Add($RootProcessId)

    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($process in $processes) {
            if ($null -ne $process.ParentProcessId -and $ids.Contains([int]$process.ParentProcessId)) {
                if ($ids.Add([int]$process.ProcessId)) {
                    $changed = $true
                }
            }
        }
    }

    return @($ids)
}

function Get-VisibleTopLevelWindowsForProcessTree {
    param([Parameter(Mandatory = $true)][int[]]$ProcessIds)

    Initialize-WinsmuxBenchmarkUser32

    $processIdSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($processId in $ProcessIds) {
        [void]$processIdSet.Add([int]$processId)
    }

    $processNames = @{}
    foreach ($processId in $ProcessIds) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -ne $process) {
            $processNames[[int]$processId] = [string]$process.ProcessName
        }
    }

    $windows = [System.Collections.Generic.List[object]]::new()
    $callback = [WinsmuxBenchmarkUser32+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)

        if (-not [WinsmuxBenchmarkUser32]::IsWindowVisible($hWnd)) {
            return $true
        }

        $windowProcessId = 0
        [void][WinsmuxBenchmarkUser32]::GetWindowThreadProcessId($hWnd, [ref]$windowProcessId)
        if (-not $processIdSet.Contains([int]$windowProcessId)) {
            return $true
        }

        $titleBuilder = [System.Text.StringBuilder]::new(512)
        $classBuilder = [System.Text.StringBuilder]::new(256)
        [void][WinsmuxBenchmarkUser32]::GetWindowText($hWnd, $titleBuilder, $titleBuilder.Capacity)
        [void][WinsmuxBenchmarkUser32]::GetClassName($hWnd, $classBuilder, $classBuilder.Capacity)
        $rect = New-Object WinsmuxBenchmarkUser32+RECT
        [void][WinsmuxBenchmarkUser32]::GetWindowRect($hWnd, [ref]$rect)

        $processName = ''
        if ($processNames.ContainsKey([int]$windowProcessId)) {
            $processName = $processNames[[int]$windowProcessId]
        }

        $windows.Add([pscustomobject]@{
            processId = [int]$windowProcessId
            processName = $processName
            handle = $hWnd.ToInt64()
            title = $titleBuilder.ToString()
            className = $classBuilder.ToString()
            x = [int]$rect.Left
            y = [int]$rect.Top
            width = [int]($rect.Right - $rect.Left)
            height = [int]($rect.Bottom - $rect.Top)
        }) | Out-Null

        return $true
    }

    [void][WinsmuxBenchmarkUser32]::EnumWindows($callback, [IntPtr]::Zero)
    return @($windows)
}

function Assert-NoVisibleDesktopHelperWindows {
    param(
        [Parameter(Mandatory = $true)][int]$RootProcessId,
        [Parameter(Mandatory = $true)][int]$MainProcessId,
        [Parameter(Mandatory = $true)][Int64]$MainWindowHandle
    )

    $processIds = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($processId in @(Get-ProcessTreeIds -RootProcessId $RootProcessId)) {
        [void]$processIds.Add([int]$processId)
    }
    [void]$processIds.Add($MainProcessId)

    $visibleWindows = @(Get-VisibleTopLevelWindowsForProcessTree -ProcessIds @($processIds))
    $unexpected = @(
        $visibleWindows |
            Where-Object {
                $isExpectedMainWindow = [int]$_.processId -eq $MainProcessId -and [Int64]$_.handle -eq $MainWindowHandle
                $isMainTaoEventTarget = [int]$_.processId -eq $MainProcessId -and
                    [string]::IsNullOrWhiteSpace([string]$_.title) -and
                    [string]$_.className -eq 'Tao Thread Event Target'
                -not $isExpectedMainWindow -and (
                    -not $isMainTaoEventTarget -and (
                    [int]$_.processId -ne $MainProcessId -or
                    [string]$_.processName -match 'msedgewebview2|pwsh|powershell|windowsterminal|conhost|cmd' -or
                    [string]$_.className -match 'ConsoleWindowClass|CASCADIA_HOSTING_WINDOW_CLASS|Chrome_WidgetWin'
                    )
                )
            }
    )

    if ($unexpected.Count -gt 0) {
        $summary = ($unexpected | ForEach-Object { "pid=$($_.processId) process=$($_.processName) title=$($_.title) class=$($_.className) bounds=$($_.x),$($_.y),$($_.width)x$($_.height)" }) -join '; '
        throw "winsmux desktop opened visible helper windows during launch readiness: $summary"
    }

    return $visibleWindows
}

function Assert-WebViewArgumentsDoNotOpenConsole {
    param([Parameter(Mandatory = $true)][string]$Arguments)

    if ($Arguments -match '--enable-logging|--v=') {
        throw "WebView2 launch arguments would open or amplify diagnostic console output: $Arguments"
    }
}

function Assert-DesktopOperatorControlPipe {
    param([int]$TimeoutSeconds = 30)

    $coreScript = Join-Path $RepoRoot 'scripts\winsmux-core.ps1'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastOutput = ''

    do {
        $output = (& pwsh -NoProfile -ExecutionPolicy Bypass -File $coreScript operator-snapshot --lines 5 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($output)) {
            $normalizedOutput = $output -replace '\s+', ' '
            return [pscustomobject]@{
                ok = $true
                command = 'operator-snapshot --lines 5'
                outputSnippet = $normalizedOutput.Substring(0, [Math]::Min(240, $normalizedOutput.Length))
            }
        }
        $lastOutput = $output
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    throw "winsmux desktop operator API was not reachable through the control pipe. Last output: $lastOutput"
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

$desktopBuildTools = $null
if (-not $SkipBuild) {
    $desktopBuildTools = Assert-DesktopBuildToolsAvailable
    Stop-RepoWinsmuxDesktopTree
    Invoke-CheckedCommand -FilePath 'cargo' -ArgumentList @('build', '--release', '-p', 'winsmux') -WorkingDirectory $RepoRoot
    Invoke-CheckedCommand -FilePath 'npm' -ArgumentList @('run', 'tauri', '--', 'build', '--no-bundle') -WorkingDirectory (Join-Path $RepoRoot 'winsmux-app')
}

$desktopFreshness = Assert-DesktopExecutableFreshForDist -DesktopExecutable $releaseApp

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
        desktopBuildTools = $desktopBuildTools
        desktopFreshness = $desktopFreshness
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
Assert-NoExternalWinsmuxDesktopApp

$webviewUserData = Join-Path $RepoRoot '.winsmux\tmp\webview2-v03623-harness'
New-Item -ItemType Directory -Path $webviewUserData -Force | Out-Null
$env:WINSMUX_BIN = $releaseCli
$env:WINSMUX_ORCHESTRA_PROJECT_DIR = $resolvedProjectDir
$env:WINSMUX_ORCHESTRA_ATTACH_MODE = 'desktop-app'
$env:WINSMUX_ORCHESTRA_DISABLE_POWERSHELL_ATTACH = '1'
$env:WINSMUX_CONTROL_PIPE_TOKEN = "winsmux-desktop-launch-$([guid]::NewGuid().ToString('N'))"
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$DebugPort --remote-allow-origins=*"
Assert-WebViewArgumentsDoNotOpenConsole -Arguments $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
$env:WEBVIEW2_USER_DATA_FOLDER = $webviewUserData
$env:NO_COLOR = '1'

$launcherProcess = $null
$app = $null
try {
    $launcherProcess = Start-Process -FilePath $releaseApp -ArgumentList @('--project-dir', $resolvedProjectDir) -WorkingDirectory $RepoRoot -PassThru
    $app = Wait-RepoWinsmuxDesktopApp -ExpectedProcessId ([int]$launcherProcess.Id)
    $page = Assert-ProductionDesktopPage -Port $DebugPort
    $operatorControlPipe = Assert-DesktopOperatorControlPipe
    $metricsBeforeMove = Get-WindowMetrics -ProcessId ([int]$app.ProcessId)
    if (-not $NoMoveToExtendedDisplay) {
        $metricsAfterMove = Move-WindowToVisibleWorkspace -ProcessId ([int]$app.ProcessId) -Width $VisibleWidth -Height $VisibleHeight
    } else {
        $metricsAfterMove = $metricsBeforeMove
    }

    if ([int]$metricsAfterMove.width -lt $VisibleWidth -or [int]$metricsAfterMove.height -lt $VisibleHeight) {
        throw "winsmux desktop window is smaller than required after launch: $($metricsAfterMove.width)x$($metricsAfterMove.height)"
    }
    $visibleWindows = Assert-NoVisibleDesktopHelperWindows -RootProcessId ([int]$launcherProcess.Id) -MainProcessId ([int]$app.ProcessId) -MainWindowHandle ([Int64]$metricsAfterMove.handle)
} catch {
    $reason = $_.Exception.Message
    Stop-RepoWinsmuxDesktopTree
    throw "winsmux desktop launch failed before a usable operator UI was verified. The repo-built desktop process tree was stopped to avoid leaving a frozen WebView window. Reason: $reason"
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
    desktopFreshness = $desktopFreshness
    debugPort = $DebugPort
    page = $page
    operatorControlPipe = $operatorControlPipe
    windowBeforeMove = $metricsBeforeMove
    windowAfterMove = $metricsAfterMove
    visibleWindows = $visibleWindows
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
