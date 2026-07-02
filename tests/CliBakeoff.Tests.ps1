$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'CLI bakeoff evidence harness' {
    BeforeAll {
        $script:RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:RepoRoot)) {
            throw 'Failed to resolve repository root.'
        }
        $script:PreflightScript = Join-Path $script:RepoRoot 'scripts\test-cli-bakeoff-preflight.ps1'
        $script:SummaryScript = Join-Path $script:RepoRoot 'scripts\summarize-cli-bakeoff.ps1'
        $script:DesktopStartScript = Join-Path $script:RepoRoot 'scripts\start-cli-bakeoff-desktop.ps1'
        $script:SessionReadinessScript = Join-Path $script:RepoRoot 'scripts\test-v03623-session-readiness.ps1'
        $script:PackPath = Join-Path $script:RepoRoot 'tasks\cli-bakeoff\v1\benchmark-pack.json'
    }

    It 'validates the tracked bakeoff task pack' {
        $output = & pwsh -NoProfile -File $script:PreflightScript -PackPath $script:PackPath -Json
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json -Depth 20
        $result.all_pass | Should -BeTrue
        $result.pack_id | Should -Be 'winsmux-cli-bakeoff-v1'
        $result.check_count | Should -BeGreaterThan 20
        ($result.checks | Where-Object { $_.name -eq 'official Harness Bench task count is met' }).pass | Should -BeTrue
        ($result.checks | Where-Object { $_.name -eq 'default timeout is 3600 seconds' }).pass | Should -BeTrue
        ($result.checks | Where-Object { $_.name -eq 'operator is not scored' }).pass | Should -BeTrue
        ($result.checks | Where-Object { $_.name -eq 'OpenRouter Sakana Fugu Ultra worker profile exists' }).pass | Should -BeTrue
        ($result.checks | Where-Object { $_.name -eq 'OpenRouter GLM worker profile exists' }).pass | Should -BeTrue
        ($output -join "`n") | Should -Not -Match 'C:\\Users\\'
    }

    It 'resolves the benchmark pack when given the repository root' {
        $output = & pwsh -NoProfile -File $script:PreflightScript -PackPath $script:RepoRoot -Json
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json -Depth 20
        $result.all_pass | Should -BeTrue
        $result.pack_id | Should -Be 'winsmux-cli-bakeoff-v1'
        $result.pack_source | Should -Be 'directory'
        $result.pack_path | Should -Be '<local-path>'
        ($result.checks | Where-Object { $_.name -eq 'benchmark pack input resolves unambiguously' }).pass | Should -BeTrue
        ($output -join "`n") | Should -Not -Match 'C:\\Users\\'
    }

    It 'resolves the benchmark pack when given the task packet directory' {
        $taskRoot = Split-Path $script:PackPath -Parent
        $output = & pwsh -NoProfile -File $script:PreflightScript -PackPath $taskRoot -Json
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json -Depth 20
        $result.all_pass | Should -BeTrue
        $result.pack_id | Should -Be 'winsmux-cli-bakeoff-v1'
        $result.pack_source | Should -Be 'directory'
        $result.task_root | Should -Be '<local-path>'
        ($result.checks | Where-Object { $_.name -eq 'benchmark pack input resolves unambiguously' }).pass | Should -BeTrue
        ($output -join "`n") | Should -Not -Match 'C:\\Users\\'
    }

    It 'routes the formal six-pane benchmark evidence to v0.36.23' {
        $contractDoc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\cli-comparison-bakeoff.md') -Raw -Encoding UTF8
        $contractDoc | Should -Match 'v0\.36\.23'
        $contractDoc | Should -Not -Match 'publishing v0\.36\.22|Before publishing v0\.36\.22|official benchmark evidence.*v0\.36\.22'

        $contractHtml = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\benchmarks\v03617-harness-bench-report.ja.html') -Raw -Encoding UTF8
        $contractHtml | Should -Match 'v0\.36\.23'
        $contractHtml | Should -Not -Match 'v0\.36\.22 測定待ち|v0\.36\.22 で行う正式|6ペイン実測とレポート再作成は v0\.36\.22'
    }

    It 'treats low Codex usage remaining notices as non-blocking readiness warnings' {
        $mainTs = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src\main.ts') -Raw -Encoding UTF8
        $blockerFunction = [regex]::Match(
            $mainTs,
            '(?s)function detectWorkerReadinessBlocker\(text: string\) \{.*?\r?\n\}',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        ).Value
        $warningFunction = [regex]::Match(
            $mainTs,
            '(?s)function detectWorkerReadinessWarnings\(text: string\) \{.*?\r?\n\}',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        ).Value

        $blockerFunction | Should -Not -BeNullOrEmpty
        $warningFunction | Should -Not -BeNullOrEmpty
        $blockerFunction | Should -Not -Match 'less\\s\+than|run\\s\+\\\\/usage|usage\\s\+limit\\s\+resets'
        $warningFunction | Should -Match 'less\\s\+than'
        $warningFunction | Should -Match 'usage\\s\+limit\\s\+resets'
    }

    It 'keeps the operator runtime model and next startup setting distinct in the composer UI' {
        $mainTs = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src\main.ts') -Raw -Encoding UTF8
        $detectIndex = $mainTs.IndexOf('function detectComposerModelFromOperatorText')
        $observeIndex = $mainTs.IndexOf('function updateObservedOperatorRuntimeModelFromOutput')
        $displayIndex = $mainTs.IndexOf('function getComposerModelControlDisplay')
        $menuIndex = $mainTs.IndexOf('function createComposerModelMenu')
        $persistIndex = $mainTs.IndexOf('function persistComposerSessionControls')
        $startupModelOptionIndex = $mainTs.IndexOf('const modelOption = getComposerModelOption()')
        $startupArgsIndex = $mainTs.IndexOf('args.push("--model", modelOption.cliModel)', $startupModelOptionIndex)

        ($detectIndex -ge 0) | Should -BeTrue
        ($observeIndex -gt $detectIndex) | Should -BeTrue
        ($displayIndex -gt $observeIndex) | Should -BeTrue
        ($menuIndex -gt $displayIndex) | Should -BeTrue
        ($persistIndex -ge 0) | Should -BeTrue
        ($startupModelOptionIndex -ge 0) | Should -BeTrue
        ($startupArgsIndex -gt $startupModelOptionIndex) | Should -BeTrue
        $mainTs | Should -Match 'observedOperatorRuntimeModel'
        $mainTs | Should -Match 'Current operator runtime model'
        $mainTs | Should -Match 'Next startup setting'
        $mainTs | Should -Match 'The operator is currently running'
        $mainTs | Should -Match 'Choices here change the next startup setting'
        $mainTs | Should -Match 'activeComposerModel'
        $mainTs | Should -Match 'activeComposerEffort'
        $mainTs | Should -Match 'args\.push\("--model", modelOption\.cliModel\)'
        $mainTs | Should -Match 'args\.push\("--effort", activeComposerEffort\)'
    }

    It 'benchmark_readiness_gate_rejects_mismatched_candidate_identity' {
        $missingDesktopBinary = Join-Path $TestDrive 'missing-winsmux-app.exe'
        $missingCliBinary = Join-Path $TestDrive 'missing-winsmux.exe'

        $output = & pwsh -NoProfile -File $script:PreflightScript `
            -PackPath $script:PackPath `
            -Json `
            -RequireCandidateIdentity `
            -AllowDirty `
            -ExpectedVersion '0.0.0' `
            -ExpectedGitHead 'deadbeef' `
            -CandidateDesktopBinary $missingDesktopBinary `
            -CandidateCliBinary $missingCliBinary 2>$null

        $LASTEXITCODE | Should -Be 1
        $result = $output | ConvertFrom-Json -Depth 20
        $result | Should -Not -BeNullOrEmpty
        $result.all_pass | Should -BeFalse
        $checkNames = @($result.checks | ForEach-Object { $_.name })
        $checkNames | Should -Contain 'candidate git head matches expected'
        $checkNames | Should -Contain 'candidate version metadata matches expected'
        $checkNames | Should -Contain 'candidate desktop binary exists'
        $checkNames | Should -Contain 'candidate desktop binary sha256 is readable'
        $checkNames | Should -Contain 'candidate CLI binary exists'
        $checkNames | Should -Contain 'candidate CLI reported version matches expected'
        $checkNames | Should -Contain 'candidate CLI binary sha256 is readable'
        ($result.checks | Where-Object { $_.name -eq 'candidate git head matches expected' }).pass | Should -BeFalse
        ($result.checks | Where-Object { $_.name -eq 'candidate version metadata matches expected' }).pass | Should -BeFalse
        ($result.checks | Where-Object { $_.name -eq 'candidate desktop binary exists' }).pass | Should -BeFalse
        ($result.checks | Where-Object { $_.name -eq 'candidate desktop binary sha256 is readable' }).pass | Should -BeFalse
        ($result.checks | Where-Object { $_.name -eq 'candidate CLI binary exists' }).pass | Should -BeFalse
        ($result.checks | Where-Object { $_.name -eq 'candidate CLI reported version matches expected' }).pass | Should -BeFalse
        ($result.checks | Where-Object { $_.name -eq 'candidate CLI binary sha256 is readable' }).pass | Should -BeFalse
    }

    It 'rejects a stale CLI candidate even when the file exists' {
        $fakeCliBinary = Join-Path $TestDrive 'winsmux-stale.cmd'
        Set-Content -LiteralPath $fakeCliBinary -Value '@echo winsmux 0.36.16' -Encoding Ascii
        $missingDesktopBinary = Join-Path $TestDrive 'missing-winsmux-app.exe'
        $head = (& git -C $script:RepoRoot rev-parse HEAD | Out-String).Trim()

        $output = & pwsh -NoProfile -File $script:PreflightScript `
            -PackPath $script:PackPath `
            -Json `
            -RequireCandidateIdentity `
            -AllowDirty `
            -ExpectedVersion '0.36.23' `
            -ExpectedGitHead $head `
            -CandidateDesktopBinary $missingDesktopBinary `
            -CandidateCliBinary $fakeCliBinary 2>$null

        $LASTEXITCODE | Should -Be 1
        $result = $output | ConvertFrom-Json -Depth 20
        $result.all_pass | Should -BeFalse
        $cliVersionCheck = $result.checks | Where-Object { $_.name -eq 'candidate CLI reported version matches expected' }
        $cliVersionCheck.pass | Should -BeFalse
        $cliVersionCheck.detail | Should -Match 'reported=0\.36\.16 expected=0\.36\.23'
    }

    It 'normalizes desktop launcher paths before process matching' {
        $output = & pwsh -NoProfile -File $script:DesktopStartScript -SelfTestPathNormalization -Json
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json -Depth 8
        $result.ok | Should -BeTrue
        $result.repoRoot | Should -Match '^[A-Z]:\\'
    }

    It 'stops an existing repo desktop before rebuilding the release desktop executable' {
        $scriptText = Get-Content -LiteralPath $script:DesktopStartScript -Raw -Encoding UTF8
        $buildBlockIndex = $scriptText.IndexOf('if (-not $SkipBuild) {')
        $toolCheckIndex = $scriptText.IndexOf('$desktopBuildTools = Assert-DesktopBuildToolsAvailable', $buildBlockIndex)
        $buildStopIndex = $scriptText.IndexOf('Stop-RepoWinsmuxDesktopTree', $buildBlockIndex)
        $cargoBuildIndex = $scriptText.IndexOf("Invoke-CheckedCommand -FilePath 'cargo'", $buildBlockIndex)
        $tauriBuildIndex = $scriptText.IndexOf("Invoke-CheckedCommand -FilePath 'npm'", $buildBlockIndex)

        ($buildBlockIndex -ge 0) | Should -BeTrue
        ($toolCheckIndex -gt $buildBlockIndex) | Should -BeTrue
        ($toolCheckIndex -lt $buildStopIndex) | Should -BeTrue
        ($cargoBuildIndex -ge 0) | Should -BeTrue
        ($tauriBuildIndex -ge 0) | Should -BeTrue
        ($buildStopIndex -gt $buildBlockIndex) | Should -BeTrue
        ($buildStopIndex -lt $cargoBuildIndex) | Should -BeTrue
        ($buildStopIndex -lt $tauriBuildIndex) | Should -BeTrue
    }

    It 'fails the desktop build gate before release compilation when Tauri CLI is unavailable' {
        $scriptText = Get-Content -LiteralPath $script:DesktopStartScript -Raw -Encoding UTF8
        $toolFunctionIndex = $scriptText.IndexOf('function Assert-DesktopBuildToolsAvailable')
        $buildBlockIndex = $scriptText.IndexOf('if (-not $SkipBuild) {')
        $toolCheckIndex = $scriptText.IndexOf('$desktopBuildTools = Assert-DesktopBuildToolsAvailable', $buildBlockIndex)
        $cargoBuildIndex = $scriptText.IndexOf("Invoke-CheckedCommand -FilePath 'cargo'", $buildBlockIndex)

        ($toolFunctionIndex -ge 0) | Should -BeTrue
        ($toolCheckIndex -gt $buildBlockIndex) | Should -BeTrue
        ($toolCheckIndex -lt $cargoBuildIndex) | Should -BeTrue
        $scriptText | Should -Match 'Tauri CLI is required before the desktop release build starts'
        $scriptText | Should -Match 'Run npm ci in winsmux-app or add @tauri-apps/cli to PATH'
        $scriptText | Should -Match 'desktopBuildTools = \$desktopBuildTools'
    }

    It 'rejects stale desktop executables before benchmark preflight or launch' {
        $scriptText = Get-Content -LiteralPath $script:DesktopStartScript -Raw -Encoding UTF8
        $freshnessFunctionIndex = $scriptText.IndexOf('function Assert-DesktopExecutableFreshForDist')
        $freshnessCallIndex = $scriptText.IndexOf('$desktopFreshness = Assert-DesktopExecutableFreshForDist -DesktopExecutable $releaseApp')
        $preflightArgsIndex = $scriptText.IndexOf('$preflightArgs = @(')
        $launchIndex = $scriptText.IndexOf('$launcherProcess = Start-Process -FilePath $releaseApp')

        ($freshnessFunctionIndex -ge 0) | Should -BeTrue
        ($freshnessCallIndex -gt $freshnessFunctionIndex) | Should -BeTrue
        ($preflightArgsIndex -gt $freshnessCallIndex) | Should -BeTrue
        ($launchIndex -gt $freshnessCallIndex) | Should -BeTrue
        $scriptText | Should -Match 'Production desktop executable is older than winsmux-app/dist'
        $scriptText | Should -Match 'newestDistUtc'
    }

    It 'keeps the v0.36.23 session readiness gate bounded by default' {
        $scriptText = Get-Content -LiteralPath $script:SessionReadinessScript -Raw -Encoding UTF8
        $maxRunsParamIndex = $scriptText.IndexOf('[int]$MaxRuns = 24')
        $timeoutParamIndex = $scriptText.IndexOf('[int]$CommandTimeoutSeconds = 30')
        $plannedRunsIndex = $scriptText.IndexOf('$plannedRuns = @($Build).Count * @($Warm).Count * @($Shell).Count * @($Registry).Count * @($Exit).Count')
        $buildIndex = $scriptText.IndexOf('$binaryByBuild = [ordered]@{}')

        ($maxRunsParamIndex -ge 0) | Should -BeTrue
        ($timeoutParamIndex -ge 0) | Should -BeTrue
        ($plannedRunsIndex -gt $timeoutParamIndex) | Should -BeTrue
        ($buildIndex -gt $plannedRunsIndex) | Should -BeTrue
        $scriptText | Should -Match '\[string\[\]\]\$Warm = @\(''on''\)'
        $scriptText | Should -Match '\[string\[\]\]\$Shell = @\(''default''\)'
        $scriptText | Should -Match '\[string\[\]\]\$Registry = @\(''fresh''\)'
        $scriptText | Should -Match '\[string\[\]\]\$Exit = @\(''normal''\)'
        $scriptText | Should -Match 'readiness matrix has \$plannedRuns runs'
        $scriptText | Should -Match 'raise -MaxRuns explicitly'
    }

    It 'bounds every v0.36.23 session readiness winsmux command and cleans owned processes' {
        $scriptText = Get-Content -LiteralPath $script:SessionReadinessScript -Raw -Encoding UTF8

        $scriptText | Should -Match 'function Invoke-IsolatedWinsmux'
        $scriptText | Should -Match '\[int\]\$TimeoutSeconds'
        $scriptText | Should -Match 'Wait-Job -Job \$job -Timeout \$TimeoutSeconds'
        $scriptText | Should -Match 'exit_code = 124'
        $scriptText | Should -Match 'timed_out = \$true'
        $scriptText | Should -Match 'function Stop-OwnedWinsmuxProcesses'
        $scriptText | Should -Match 'CommandLine -like "\*\$Namespace\*"'
        $scriptText | Should -Match 'Stop-OwnedWinsmuxProcesses -Exe \$exe -Namespace \$namespace'

        $invokeCalls = [regex]::Matches($scriptText, '(?m)^\s*(?:\$\w+\s*=\s*)?(?:return\s+)?Invoke-IsolatedWinsmux\s+-[^\r\n]+')
        $invokeCalls.Count | Should -BeGreaterThan 3
        foreach ($call in $invokeCalls) {
            $call.Value | Should -Match '-TimeoutSeconds '
        }
    }

    It 'requires packaged desktop asset URLs to be relative and present' {
        $viteConfig = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\vite.config.ts') -Raw -Encoding UTF8
        $indexHtml = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\index.html') -Raw -Encoding UTF8
        $scriptText = Get-Content -LiteralPath $script:DesktopStartScript -Raw -Encoding UTF8

        $viteConfig | Should -Match 'base:\s*"\./"'
        $indexHtml | Should -Not -Match '(?:src|href)="/(?:assets/|src/|startup\.css|favicon\.|apple-touch-icon\.png)'
        $indexHtml | Should -Match 'href="\./startup\.css"'
        $indexHtml | Should -Match 'href="\./src/styles\.css"'
        $indexHtml | Should -Match 'src="\./src/main\.ts"'
        $scriptText | Should -Match 'function Assert-DesktopDistAssetIntegrity'
        $scriptText | Should -Match 'root-anchored asset URLs'
        $scriptText | Should -Match 'references missing packaged assets'
        $scriptText | Should -Match 'distAssetReferenceCount'
    }

    It 'normalizes WebView DevTools page arrays before desktop launch verification' {
        $scriptText = Get-Content -LiteralPath $script:DesktopStartScript -Raw -Encoding UTF8

        $scriptText | Should -Match 'function Convert-ToFlatObjectArray'
        $scriptText | Should -Match 'Convert-ToFlatObjectArray\s+\(Invoke-RestMethod'
        $scriptText | Should -Match 'winsmux desktop DevTools endpoint returned no page URLs'
    }

    It 'reads WebView operator surface results without direct dynamic property assumptions' {
        $scriptText = Get-Content -LiteralPath $script:DesktopStartScript -Raw -Encoding UTF8

        $scriptText | Should -Match 'function Get-ObjectPropertyValue'
        $scriptText | Should -Match '\[void\]\$socket\.ConnectAsync'
        $scriptText | Should -Match '\[void\]\$socket\.SendAsync'
        $scriptText | Should -Match '\[void\]\$socket\.CloseAsync'
        $scriptText | Should -Match '\[void\]\$chunks\.Add\(\$receiveBytes\[\$index\]\)'
        $scriptText | Should -Match 'JSON\.stringify'
        $scriptText | Should -Match 'ConvertFrom-Json -Depth 20'
        $scriptText | Should -Match 'Get-ObjectPropertyValue -Object \$surface -Name ''ok'''
        $scriptText | Should -Match 'did not return an ok property'
        $scriptText | Should -Not -Match '\$surface\.ok'
    }

    It 'rejects the Tauri dev server URL during packaged desktop E2E' {
        $scriptText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\scripts\desktop-pane-e2e.mjs') -Raw -Encoding UTF8
        $scriptText | Should -Match 'allowDevServer'
        $scriptText | Should -Match 'Packaged desktop resolved to the Tauri dev server URL'
        $scriptText | Should -Match 'allowDevServer: !RELEASE_POPOUT_ONLY'
    }

    It 'stops the repo desktop when launch readiness fails before the operator UI is usable' {
        $scriptText = Get-Content -LiteralPath $script:DesktopStartScript -Raw -Encoding UTF8
        $launchIndex = $scriptText.IndexOf('$launcherProcess = Start-Process -FilePath $releaseApp')
        $pageCheckIndex = $scriptText.IndexOf('$page = Assert-ProductionDesktopPage -Port $DebugPort', $launchIndex)
        $readinessCatchIndex = $scriptText.IndexOf('winsmux desktop launch failed before a usable operator UI was verified', $pageCheckIndex)
        $cleanupIndex = $scriptText.IndexOf('Stop-RepoWinsmuxDesktopTree', $pageCheckIndex)
        $resultIndex = $scriptText.IndexOf('$result = [pscustomobject]@{', $pageCheckIndex)

        ($launchIndex -ge 0) | Should -BeTrue
        ($pageCheckIndex -gt $launchIndex) | Should -BeTrue
        ($readinessCatchIndex -gt $pageCheckIndex) | Should -BeTrue
        ($cleanupIndex -gt $pageCheckIndex) | Should -BeTrue
        ($cleanupIndex -lt $resultIndex) | Should -BeTrue
        $scriptText | Should -Match 'frozen WebView window'
    }

    It 'requires a rendered operator surface before desktop launch readiness passes' {
        $scriptText = Get-Content -LiteralPath $script:DesktopStartScript -Raw -Encoding UTF8
        $devToolsFunctionIndex = $scriptText.IndexOf('function Invoke-WebViewDevToolsRuntimeExpression')
        $runtimeEvalIndex = $scriptText.IndexOf("method = 'Runtime.evaluate'", $devToolsFunctionIndex)
        $surfaceFunctionIndex = $scriptText.IndexOf('function Test-DesktopOperatorSurface')
        $surfaceRuntimeCallIndex = $scriptText.IndexOf('Invoke-WebViewDevToolsRuntimeExpression -WebSocketDebuggerUrl $webSocketDebuggerUrl -Expression $expression', $surfaceFunctionIndex)
        $surfaceCallIndex = $scriptText.IndexOf('$operatorSurface = Test-DesktopOperatorSurface -Page $productionPage')
        $windowMetricsIndex = $scriptText.IndexOf('$metricsBeforeMove = Get-WindowMetrics -ProcessId ([int]$app.ProcessId)')

        ($devToolsFunctionIndex -ge 0) | Should -BeTrue
        ($runtimeEvalIndex -gt $devToolsFunctionIndex) | Should -BeTrue
        ($surfaceFunctionIndex -ge 0) | Should -BeTrue
        ($surfaceRuntimeCallIndex -gt $surfaceFunctionIndex) | Should -BeTrue
        ($surfaceCallIndex -gt $surfaceRuntimeCallIndex) | Should -BeTrue
        ($surfaceCallIndex -lt $windowMetricsIndex) | Should -BeTrue
        $scriptText | Should -Match '#operator-terminal-panel'
        $scriptText | Should -Match '#composer-input'
        $scriptText | Should -Match 'tauriInvokeAvailable'
        $scriptText | Should -Match 'ERR_CONNECTION_REFUSED'
        $scriptText | Should -Match 'browserError='
        $scriptText | Should -Match 'operatorSurface = \$operatorSurface'
    }

    It 'requires desktop operator API reachability before desktop launch readiness passes' {
        $scriptText = Get-Content -LiteralPath $script:DesktopStartScript -Raw -Encoding UTF8
        $launchIndex = $scriptText.IndexOf('$launcherProcess = Start-Process -FilePath $releaseApp')
        $tokenEnvIndex = $scriptText.IndexOf('$env:WINSMUX_CONTROL_PIPE_TOKEN =')
        $pageCheckIndex = $scriptText.IndexOf('$page = Assert-ProductionDesktopPage -Port $DebugPort', $launchIndex)
        $controlFunctionIndex = $scriptText.IndexOf('function Assert-DesktopOperatorControlPipe')
        $snapshotMethodIndex = $scriptText.IndexOf('operator-snapshot', $controlFunctionIndex)
        $controlCheckIndex = $scriptText.IndexOf('$operatorControlPipe = Assert-DesktopOperatorControlPipe', $pageCheckIndex)
        $windowMetricsIndex = $scriptText.IndexOf('$metricsBeforeMove = Get-WindowMetrics -ProcessId ([int]$app.ProcessId)', $controlCheckIndex)

        ($launchIndex -ge 0) | Should -BeTrue
        ($tokenEnvIndex -ge 0) | Should -BeTrue
        ($launchIndex -gt $tokenEnvIndex) | Should -BeTrue
        ($pageCheckIndex -gt $launchIndex) | Should -BeTrue
        ($controlFunctionIndex -ge 0) | Should -BeTrue
        ($snapshotMethodIndex -gt $controlFunctionIndex) | Should -BeTrue
        ($controlCheckIndex -gt $pageCheckIndex) | Should -BeTrue
        ($controlCheckIndex -lt $windowMetricsIndex) | Should -BeTrue
        $scriptText | Should -Match 'desktop operator API was not reachable'
        $scriptText | Should -Match 'operatorControlPipe = \$operatorControlPipe'
    }

    It 'rejects visible helper windows and WebView console logging before desktop readiness passes' {
        $scriptText = Get-Content -LiteralPath $script:DesktopStartScript -Raw -Encoding UTF8
        $windowEnumerationIndex = $scriptText.IndexOf('function Get-VisibleTopLevelWindowsForProcessTree')
        $helperFunctionIndex = $scriptText.IndexOf('function Assert-NoVisibleDesktopHelperWindows')
        $helperHandleParamIndex = $scriptText.IndexOf('[Parameter(Mandatory = $true)][Int64]$MainWindowHandle', $helperFunctionIndex)
        $webviewArgsIndex = $scriptText.IndexOf('$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS =')
        $webviewArgGuardIndex = $scriptText.IndexOf('Assert-WebViewArgumentsDoNotOpenConsole', $webviewArgsIndex)
        $moveIndex = $scriptText.IndexOf('$metricsAfterMove = Move-WindowToVisibleWorkspace')
        $helperCheckIndex = $scriptText.IndexOf('$visibleWindows = Assert-NoVisibleDesktopHelperWindows', $moveIndex)
        $resultIndex = $scriptText.IndexOf('$result = [pscustomobject]@{', $helperCheckIndex)

        ($windowEnumerationIndex -ge 0) | Should -BeTrue
        ($helperFunctionIndex -gt $windowEnumerationIndex) | Should -BeTrue
        ($helperHandleParamIndex -gt $helperFunctionIndex) | Should -BeTrue
        ($webviewArgsIndex -ge 0) | Should -BeTrue
        ($webviewArgGuardIndex -gt $webviewArgsIndex) | Should -BeTrue
        ($moveIndex -ge 0) | Should -BeTrue
        ($helperCheckIndex -gt $moveIndex) | Should -BeTrue
        ($helperCheckIndex -lt $resultIndex) | Should -BeTrue
        $scriptText | Should -Match 'visible helper windows'
        $scriptText | Should -Match '\$isExpectedMainWindow'
        $scriptText | Should -Match '\$isMainTaoEventTarget'
        $scriptText | Should -Match 'Tao Thread Event Target'
        $scriptText | Should -Match 'bounds=\$\(\$_.x\),\$\(\$_.y\),\$\(\$_.width\)x\$\(\$_.height\)'
        $scriptText | Should -Match '-MainWindowHandle \(\[Int64\]\$metricsAfterMove\.handle\)'
        $scriptText | Should -Match 'msedgewebview2|pwsh|powershell|windowsterminal|conhost|cmd'
        $scriptText | Should -Not -Match 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS\s*=\s*".*--enable-logging'
        $scriptText | Should -Not -Match 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS\s*=\s*".*--v='
        $scriptText | Should -Match 'visibleWindows = \$visibleWindows'
    }

    It 'documents public desktop startup troubleshooting without repo-build process assumptions' {
        $troubleshooting = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\TROUBLESHOOTING.md') -Raw -Encoding UTF8
        $troubleshootingJa = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\TROUBLESHOOTING.ja.md') -Raw -Encoding UTF8
        $installation = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\installation.md') -Raw -Encoding UTF8
        $installationJa = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\installation.ja.md') -Raw -Encoding UTF8
        $readme = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'README.md') -Raw -Encoding UTF8
        $readmeJa = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'README.ja.md') -Raw -Encoding UTF8
        $quickstart = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\quickstart.md') -Raw -Encoding UTF8
        $quickstartJa = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\quickstart.ja.md') -Raw -Encoding UTF8
        $packageReadme = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'packages\winsmux\README.md') -Raw -Encoding UTF8
        $releaseGate = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\project\v1-release-gate.md') -Raw -Encoding UTF8
        $operatorModel = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\operator-model.md') -Raw -Encoding UTF8
        $readmeBeforeCommands = ($readme -split '(?m)^## Main Commands')[0]
        $readmeJaBeforeCommands = ($readmeJa -split '(?m)^## 主要コマンド')[0]
        $publicInstallDocs = @(
            $readme,
            $readmeJa,
            $quickstart,
            $quickstartJa,
            $installation,
            $installationJa,
            $troubleshooting,
            $troubleshootingJa,
            $packageReadme,
            $operatorModel
        ) -join "`n"

        $troubleshooting | Should -Match 'Desktop app opens to a localhost connection error'
        $troubleshooting | Should -Match 'https://github\.com/Sora-bluesky/winsmux/releases/latest'
        $troubleshooting | Should -Match 'winsmux_\.\.\._x64-setup\.exe'
        $troubleshooting | Should -Match 'Start menu or desktop shortcut'
        $troubleshooting | Should -Match 'Get-Process winsmux-app'
        $troubleshooting | Should -Match 'black PowerShell, Windows Terminal, or WebView2 console window'
        $troubleshooting | Should -Not -Match 'Get-Process node,cargo,winsmux-app'
        $troubleshooting | Should -Not -Match '\\target\\'
        $troubleshootingJa | Should -Match 'デスクトップアプリが localhost 接続エラー'
        $troubleshootingJa | Should -Match 'https://github\.com/Sora-bluesky/winsmux/releases/latest'
        $troubleshootingJa | Should -Match 'Get-Process winsmux-app'
        $troubleshootingJa | Should -Not -Match 'Get-Process node,cargo,winsmux-app'
        $troubleshootingJa | Should -Not -Match '\\target\\'
        $publicInstallDocs | Should -Not -Match '(?i)target[\\/](release|debug)([\\/]|\\b)'
        $publicInstallDocs | Should -Not -Match '(?i)\\.local[\\/ ]*bin'
        $installation | Should -Match 'External automation against the desktop operator'
        $installation | Should -Match 'https://github\.com/Sora-bluesky/winsmux/releases/latest'
        $installation | Should -Match 'winsmux_\.\.\._x64-setup\.exe'
        $installation | Should -Match 'winsmux launch.*does not open\s+the desktop app'
        $installation | Should -Match 'Windows Search'
        $installation | Should -Match 'Installed apps'
        $installation | Should -Match 'does not need to show a version number'
        $installation | Should -Match 'builds starting with `v0\.36\.23` check GitHub Releases'
        $installation | Should -Match 'shows a compact update action'
        $installation | Should -Match 'verifies the checksum when release metadata provides'
        $installation | Should -Not -Match 'The `v0\.36\.23` release cannot ship until'
        $installation | Should -Match 'Published\s+builds before `v0\.36\.23`'
        $installationJa | Should -Match 'Windows 検索'
        $installationJa | Should -Match 'https://github\.com/Sora-bluesky/winsmux/releases/latest'
        $installationJa | Should -Match 'winsmux_\.\.\._x64-setup\.exe'
        $installationJa | Should -Match 'インストールされているアプリ'
        $installationJa | Should -Match 'バージョン番号が出る必要はありません'
        $installationJa | Should -Match '`v0\.36\.23` 以降で GitHub Releases にある新しい Windows セットアップインストーラーを確認します'
        $installationJa | Should -Match 'アプリ下部に小さな更新アクションを表示'
        $installationJa | Should -Match 'チェックサムがある場合は検証'
        $installationJa | Should -Not -Match '`v0\.36\.23` は、この実装と検証が終わるまでリリースしません'
        $readme | Should -Match 'For most users, start with the desktop app'
        $readme | Should -Match 'https://github\.com/Sora-bluesky/winsmux/releases/latest'
        $readme | Should -Match 'Use the npm package only when you want a CLI-first'
        $readmeBeforeCommands | Should -Not -Match 'winsmux init'
        $readmeBeforeCommands | Should -Not -Match 'winsmux launch'
        $readmeJa | Should -Match '通常はデスクトップアプリから始めます'
        $readmeJa | Should -Match 'CLI 中心、スクリプト実行、ヘッドレス運用で使う場合だけ'
        $readmeJa | Should -Match 'https://github\.com/Sora-bluesky/winsmux/releases/latest'
        $readmeJaBeforeCommands | Should -Not -Match 'winsmux init'
        $readmeJaBeforeCommands | Should -Not -Match 'winsmux launch'
        $quickstart | Should -Match '# Quickstart: Desktop app'
        $quickstart | Should -Match 'https://github\.com/Sora-bluesky/winsmux/releases/latest'
        $quickstart | Should -Match 'You do not need to run CLI initialization commands by hand for the desktop path'
        $quickstart | Should -Not -Match 'npm install -g winsmux|winsmux init|winsmux launch|Create project settings'
        $quickstartJa | Should -Match '# クイックスタート: デスクトップアプリ'
        $quickstartJa | Should -Match 'https://github\.com/Sora-bluesky/winsmux/releases/latest'
        $quickstartJa | Should -Match 'CLI 用の初期化コマンドを手で実行する必要はありません'
        $quickstartJa | Should -Not -Match 'npm install -g winsmux|winsmux init|winsmux launch|プロジェクト設定を作る'
        $publicInstallDocs | Should -Not -Match 'winsmux_0\.\d+\.\d+_x64-setup\.exe'
        $packageReadme | Should -Match 'It does not install or open the desktop app'
        $packageReadme | Should -Match 'https://github\.com/Sora-bluesky/winsmux/releases/latest'
        $packageReadme | Should -Match 'CLI package path'
        $releaseGate | Should -Match 'Windows Search finds the app by'
        $releaseGate | Should -Match 'Installed apps'
        $releaseGate | Should -Match 'version number is not required in Windows Search'
        $releaseGate | Should -Match 'installed Windows app'
        $releaseGate | Should -Match 'target\\debug'
        $releaseGate | Should -Match 'target\\release'
        $releaseGate | Should -Match '\.local\\bin'
        $releaseGate | Should -Match 'must not be accepted as desktop installer\s+registration or normal-launch proof'
        $releaseGate | Should -Match 'releases/latest'
        $releaseGate | Should -Match 'version-neutral installer example'
        $releaseGate | Should -Match 'winsmux_\.\.\._x64-setup\.exe'
        $releaseGate | Should -Match 'must fail if public install\s+docs contain a fixed release asset name'
        $releaseGate | Should -Match 'winsmux_0\.x\.y_x64-setup\.exe'
        $releaseGate | Should -Match 'Quickstart must stay desktop-app first'
        $releaseGate | Should -Match 'README, Quickstart, Installation, Troubleshooting'
        $releaseGate | Should -Match 'packages/winsmux/README\.md'
        $releaseGate | Should -Match 'Automatic in-app update detection is delivered in the `v0\.36\.23` desktop app'
        $releaseGate | Should -Match 'release gate verifies the update check'
        $releaseGate | Should -Match 'checksum verification when'
        $releaseGate | Should -Not -Match '`v0\.36\.23` cannot ship until update check'
        $releaseGate | Should -Match 'installer-over-existing-install\s+update path'
        $releaseGate | Should -Match 'compact\s+persistent status/action'
        $releaseGate | Should -Match 'download\s+progress\s+from the final update action'
        $releaseGate | Should -Match 'post-install restart guidance'
        $releaseGate | Should -Match 'confirmation dialog'
        $releaseGate | Should -Match 'local active sessions may be interrupted'
        $releaseGate | Should -Match 'installing state with progress text'
        $releaseGate | Should -Match 'Clicking `Cancel` or outside the dialog closes the dialog'
        $releaseGate | Should -Match 'Silent background replacement without user-visible state is not\s+accepted'
        $operatorModel | Should -Match 'https://github\.com/Sora-bluesky/winsmux/releases/latest'
        $operatorModel | Should -Match 'winsmux_\.\.\._x64-setup\.exe'
        $operatorModel | Should -Match 'The desktop path is\s+the recommended first-run path'
        $operatorModel | Should -Match 'must not be presented as required\s+desktop app setup'
    }

    It 'implements desktop update detection and installer handoff UX' {
        $tauriLib = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src-tauri\src\lib.rs') -Raw -Encoding UTF8
        $cargoToml = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src-tauri\Cargo.toml') -Raw -Encoding UTF8
        $desktopClient = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src\desktopClient.ts') -Raw -Encoding UTF8
        $mainTs = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src\main.ts') -Raw -Encoding UTF8
        $styles = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src\styles.css') -Raw -Encoding UTF8

        $cargoToml | Should -Match 'sha2 = "0\.10"'
        $cargoToml | Should -Match 'ureq = \{ version = "2", features = \["json"\] \}'
        $tauriLib | Should -Match 'WINSMUX_RELEASE_API_URL'
        $tauriLib | Should -Match 'repos/Sora-bluesky/winsmux/releases/latest'
        $tauriLib | Should -Match 'winsmux_\{latest_version\}_x64-setup\.exe'
        $tauriLib | Should -Match 'fn desktop_update_check'
        $tauriLib | Should -Match 'fn desktop_update_download_installer'
        $tauriLib | Should -Match 'fn desktop_update_launch_installer'
        $tauriLib | Should -Match 'Desktop in-app updates are supported only for Windows setup installer builds'
        $tauriLib | Should -Match 'Desktop installer updates are supported only on Windows'
        $tauriLib | Should -Match 'sha256:'
        $tauriLib | Should -Match 'checksum mismatch'
        $tauriLib | Should -Match 'hash_file_sha256'
        $tauriLib | Should -Match 'checksum changed before launch'
        $tauriLib | Should -Match 'update installer checksum is required before launch'
        $tauriLib | Should -Match 'must be launched from the winsmux update download directory'
        $tauriLib | Should -Match 'CREATE_NO_WINDOW'
        $tauriLib | Should -Match 'winsmux-update-restart\.ps1'
        $tauriLib | Should -Match 'Wait-Process -Id \$installer\.Id'
        $tauriLib | Should -Match 'Start-Process -FilePath \$AppPath'
        $tauriLib | Should -Match '-WindowStyle'
        $tauriLib | Should -Match 'Stdio::null'
        $tauriLib | Should -Match 'app\.exit\(0\)'
        $tauriLib | Should -Match 'desktop-update-progress'

        $desktopClient | Should -Match '"desktop_update_check"'
        $desktopClient | Should -Match '"desktop_update_download_installer"'
        $desktopClient | Should -Match '"desktop_update_launch_installer"'
        $desktopClient | Should -Match 'checkDesktopUpdate'
        $desktopClient | Should -Match 'downloadDesktopUpdateInstaller'
        $desktopClient | Should -Match 'launchDesktopUpdateInstaller'
        $desktopClient | Should -Match 'subscribeToDesktopUpdateProgress'

        $mainTs | Should -Match 'type DesktopUpdateState'
        $mainTs | Should -Match 'initializeDesktopUpdateState'
        $mainTs | Should -Match 'refreshDesktopUpdateState'
        $mainTs | Should -Match 'openDesktopUpdateDialog'
        $mainTs | Should -Match 'renderDesktopUpdateDialog'
        $mainTs | Should -Match 'startDesktopUpdateInstall'
        $mainTs | Should -Match 'installerSha256'
        $mainTs | Should -Match 'downloaded\.sha256'
        $mainTs | Should -Match 'You can retry from this dialog'
        $mainTs | Should -Match 'ダウンロード中'
        $mainTs | Should -Match '更新する'
        $mainTs | Should -Match 'アップデートをインストール中'
        $mainTs | Should -Match 'このダイアログから再試行できます'
        $mainTs | Should -Match 'インストールが完了すると'
        $mainTs | Should -Match 'winsmux が再起動します'
        $mainTs | Should -Match 'キャンセル'
        $mainTs | Should -Match 'open-update-dialog'

        $styles | Should -Match '\.desktop-update-dialog'
        $styles | Should -Match '\.desktop-update-progress'
        $styles | Should -Not -Match '--ws-panel-bg'
    }

    It 'gates desktop releases on signed updater artifacts' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github\workflows\release-desktop.yml') -Raw -Encoding UTF8
        $releaseGate = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs\project\v1-release-gate.md') -Raw -Encoding UTF8
        $tauriCiConfig = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src-tauri\tauri.ci.conf.json') -Raw -Encoding UTF8
        $signScript = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\src-tauri\scripts\sign-windows-bundle.ps1') -Raw -Encoding UTF8

        $secretGateIndex = $workflow.IndexOf('Require desktop release signing secrets', [StringComparison]::Ordinal)
        $buildIndex = $workflow.IndexOf('Build desktop bundles', [StringComparison]::Ordinal)
        $latestJsonIndex = $workflow.IndexOf('Create desktop updater latest.json', [StringComparison]::Ordinal)
        $collectIndex = $workflow.IndexOf('Collect desktop release assets', [StringComparison]::Ordinal)
        $verifySignaturesIndex = $workflow.IndexOf('Verify desktop installer signatures', [StringComparison]::Ordinal)
        $uploadArtifactIndex = $workflow.IndexOf('Upload desktop artifact', [StringComparison]::Ordinal)
        $uploadReleaseIndex = $workflow.IndexOf('Upload desktop bundles to release', [StringComparison]::Ordinal)

        $secretGateIndex | Should -BeGreaterThan -1
        $buildIndex | Should -BeGreaterThan -1
        $secretGateIndex | Should -BeLessThan $buildIndex
        $latestJsonIndex | Should -BeGreaterThan $buildIndex
        $latestJsonIndex | Should -BeLessThan $collectIndex
        $verifySignaturesIndex | Should -BeGreaterThan $collectIndex
        $verifySignaturesIndex | Should -BeLessThan $uploadArtifactIndex
        $verifySignaturesIndex | Should -BeLessThan $uploadReleaseIndex

        $workflow | Should -Match 'Require desktop release signing secrets'
        $workflow | Should -Match 'WINDOWS_SIGNING_CERTIFICATE_BASE64'
        $workflow | Should -Match 'WINDOWS_SIGNING_CERTIFICATE_PASSWORD'
        $workflow | Should -Match 'TAURI_SIGNING_PRIVATE_KEY'
        $workflow | Should -Match 'TAURI_SIGNING_PRIVATE_KEY_PASSWORD'
        $workflow | Should -Not -Match 'TAURI_UPDATER_PRIVATE_KEY'
        $workflow | Should -Not -Match 'TAURI_UPDATER_PRIVATE_KEY_PASSWORD'
        $workflow | Should -Not -Match 'Sign desktop installer assets'
        $workflow | Should -Match 'tauri\.ci\.conf\.json'
        $workflow | Should -Match 'signtool\.exe'
        $workflow | Should -Match 'Get-AuthenticodeSignature'
        $workflow | Should -Match 'latest\.json'
        $workflow | Should -Match '\.sig'
        $workflow | Should -Match 'Required signed updater metadata'
        $workflow | Should -Match 'not Authenticode signed with a valid signature'
        $workflow | Should -Match 'Unable to locate updater signature next to'

        $tauriCiConfig | Should -Match '"createUpdaterArtifacts"\s*:\s*true'
        $tauriCiConfig | Should -Match '"signCommand"'
        $tauriCiConfig | Should -Match 'sign-windows-bundle\.ps1'
        $tauriCiConfig | Should -Match '\./scripts/sign-windows-bundle\.ps1'
        $tauriCiConfig | Should -Not -Match '\./src-tauri/scripts/sign-windows-bundle\.ps1'
        $signScript | Should -Match 'WINSMUX_WINDOWS_SIGNING_CERTIFICATE_PATH'
        $signScript | Should -Match 'WINDOWS_SIGNING_CERTIFICATE_PASSWORD'
        $signScript | Should -Match 'signtool sign'

        $releaseGate | Should -Match 'TASK-720'
        $releaseGate | Should -Match 'signed desktop updater release assets'
        $releaseGate | Should -Match 'latest\.json'
        $releaseGate | Should -Match '\.sig'
        $releaseGate | Should -Match 'WINDOWS_SIGNING_CERTIFICATE_BASE64'
        $releaseGate | Should -Match 'TAURI_SIGNING_PRIVATE_KEY'
        $releaseGate | Should -Not -Match 'TAURI_UPDATER_PRIVATE_KEY'
        $releaseGate | Should -Match 'unsigned installer'
        $releaseGate | Should -Match 'must\s+not\s+be\s+published'
    }

    It 'filters content-clean status noise before enforcing the candidate clean gate' {
        $scriptText = Get-Content -LiteralPath $script:PreflightScript -Raw -Encoding UTF8
        $scriptText | Should -Match 'function Get-GitContentDirtyStatus'
        $scriptText | Should -Match 'git -C \$RepoRoot diff --quiet -- \$pathSpec'
        $scriptText | Should -Match 'git -C \$RepoRoot diff --cached --quiet -- \$pathSpec'
        $scriptText | Should -Match 'candidate worktree is clean'
        $scriptText.Contains("Add-Check 'candidate worktree is clean' ([bool]`$AllowDirty -or [string]::IsNullOrWhiteSpace(`$statusShort))") | Should -BeFalse
    }

    It 'fails when a task packet is missing' {
        $badRoot = Join-Path $TestDrive 'bad-pack'
        New-Item -ItemType Directory -Path $badRoot -Force | Out-Null
        $badPack = Join-Path $badRoot 'benchmark-pack.json'
        Set-Content -LiteralPath $badPack -Value @'
{
  "version": 1,
  "pack_id": "bad",
  "minimum_task_count_for_directional_findings": 1,
  "scoring": {
    "axes": {
      "accuracy": 30,
      "review_findings": 20,
      "speed": 15,
      "parallelism": 15,
      "async_terminal": 10,
      "evidence_quality": 10
    }
  },
  "qc_gates": [
    "same_task_packet_sha256_for_all_workers",
    "same_timeout_for_all_workers",
    "preflight_all_pass_before_recording",
    "desktop_app_screen_recording_required",
    "non_completed_worker_results_excluded_from_scoring",
    "antigravity_empty_stdout_excluded_from_machine_scoring"
  ],
  "default_workers": [
    { "cli": "Claude Code" },
    { "cli": "Codex" },
    { "cli": "Antigravity CLI" }
  ],
  "tasks": [
    {
      "task_id": "WB-FAIL",
      "task_class": "diagnostic",
      "packet_path": "missing.md",
      "hidden_check_categories": ["must fail"]
    }
  ]
}
'@ -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:PreflightScript -PackPath $badPack -TaskRoot $badRoot -Json 2>$null
        $LASTEXITCODE | Should -Be 1
        $result = $output | ConvertFrom-Json -Depth 20
        $result.all_pass | Should -BeFalse
        ($result.checks | Where-Object { $_.name -eq 'packet exists WB-FAIL' }).pass | Should -BeFalse
    }

    It 'rejects task packet paths that escape the task root' {
        $badRoot = Join-Path $TestDrive 'escaping-pack'
        New-Item -ItemType Directory -Path $badRoot -Force | Out-Null
        $badPack = Join-Path $badRoot 'benchmark-pack.json'
        Set-Content -LiteralPath $badPack -Value @'
{
  "version": 1,
  "pack_id": "bad-escape",
  "minimum_task_count_for_directional_findings": 1,
  "scoring": {
    "axes": {
      "accuracy": 30,
      "review_findings": 20,
      "speed": 15,
      "parallelism": 15,
      "async_terminal": 10,
      "evidence_quality": 10
    }
  },
  "qc_gates": [
    "same_task_packet_sha256_for_all_workers",
    "same_timeout_for_all_workers",
    "preflight_all_pass_before_recording",
    "desktop_app_screen_recording_required",
    "non_completed_worker_results_excluded_from_scoring",
    "antigravity_empty_stdout_excluded_from_machine_scoring"
  ],
  "default_workers": [
    { "cli": "Claude Code" },
    { "cli": "Codex" },
    { "cli": "Antigravity CLI" }
  ],
  "tasks": [
    {
      "task_id": "WB-ESCAPE",
      "task_class": "diagnostic",
      "packet_path": "../escape.md",
      "hidden_check_categories": ["must fail"]
    }
  ]
}
'@ -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:PreflightScript -PackPath $badPack -TaskRoot $badRoot -Json 2>$null
        $LASTEXITCODE | Should -Be 1
        $result = $output | ConvertFrom-Json -Depth 20
        ($result.checks | Where-Object { $_.name -eq 'packet path stays inside task root WB-ESCAPE' }).pass | Should -BeFalse
    }

    It 'scans packet files for obvious secrets and private local paths' {
        $badRoot = Join-Path $TestDrive 'leaky-pack'
        New-Item -ItemType Directory -Path $badRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $badRoot 'leaky.md') -Value @'
# Leaky

BAKEOFF_ROUND_A_BEGIN
api_key = abcdefghijklmnop
C:\Users\example\private
BAKEOFF_ROUND_A_END
'@ -Encoding UTF8
        $badPack = Join-Path $badRoot 'benchmark-pack.json'
        Set-Content -LiteralPath $badPack -Value @'
{
  "version": 1,
  "pack_id": "bad-secret",
  "minimum_task_count_for_directional_findings": 1,
  "scoring": {
    "axes": {
      "accuracy": 30,
      "review_findings": 20,
      "speed": 15,
      "parallelism": 15,
      "async_terminal": 10,
      "evidence_quality": 10
    }
  },
  "qc_gates": [
    "same_task_packet_sha256_for_all_workers",
    "same_timeout_for_all_workers",
    "preflight_all_pass_before_recording",
    "desktop_app_screen_recording_required",
    "non_completed_worker_results_excluded_from_scoring",
    "antigravity_empty_stdout_excluded_from_machine_scoring"
  ],
  "default_workers": [
    { "cli": "Claude Code" },
    { "cli": "Codex" },
    { "cli": "Antigravity CLI" }
  ],
  "tasks": [
    {
      "task_id": "WB-LEAK",
      "task_class": "diagnostic",
      "packet_path": "leaky.md",
      "hidden_check_categories": ["must fail"]
    }
  ]
}
'@ -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:PreflightScript -PackPath $badPack -TaskRoot $badRoot -Json 2>$null
        $LASTEXITCODE | Should -Be 1
        $result = $output | ConvertFrom-Json -Depth 20
        ($result.checks | Where-Object { $_.name -eq 'packet does not contain obvious secrets WB-LEAK' }).pass | Should -BeFalse
        ($result.checks | Where-Object { $_.name -eq 'packet does not contain private local paths WB-LEAK' }).pass | Should -BeFalse
    }

    It 'summarizes run evidence without copying local paths into public outputs' {
        $runRoot = Join-Path $TestDrive 'runs'
        $runDir = Join-Path $runRoot 'sample-run'
        $outputDir = Join-Path $TestDrive 'summary'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $runDir 'manifest.json') -Value @'
{
  "version": 1,
  "run_id": "sample-run",
  "task_class": "readonly_diagnostic",
  "recording": {
    "status": "publishable",
    "publishable": true
  },
  "active_workers": [
    {
      "cli": "Codex",
      "display_model": "Codex / gpt-5.3-spark"
    }
  ]
}
'@ -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $runDir 'commands.jsonl') -Value @'
{"cli":"Codex","model":"Codex / gpt-5.3-spark","status":"completed","elapsed_seconds":12.5,"working_dir":"C:\\Users\\example\\repo","end_marker_present":true,"packet_hash_match":true,"stdout_empty":false}
'@ -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:SummaryScript -RunRoot $runRoot -OutputDir $outputDir -PackPath $script:PackPath -Json
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json -Depth 20
        $result.scoreable_runs | Should -Be 1

        foreach ($name in @('raw-score-matrix.csv', 'model-evidence-profile.json', 'model-task-fit.md', 'assignment-policy.md')) {
            Test-Path -LiteralPath (Join-Path $outputDir $name) | Should -BeTrue
        }

        $combined = @(
            Get-Content -LiteralPath (Join-Path $outputDir 'raw-score-matrix.csv') -Raw -Encoding UTF8
            Get-Content -LiteralPath (Join-Path $outputDir 'model-task-fit.md') -Raw -Encoding UTF8
            Get-Content -LiteralPath (Join-Path $outputDir 'assignment-policy.md') -Raw -Encoding UTF8
        ) -join "`n"
        $combined | Should -Match '"overall","100","scoreable"'
        $combined | Should -Not -Match [regex]::Escape($TestDrive)
        $combined | Should -Not -Match '[A-Za-z]:\\Users\\'
    }

    It 'excludes incomplete scoreability evidence from model scoring' {
        $runRoot = Join-Path $TestDrive 'runs-excluded'
        $outputDir = Join-Path $TestDrive 'summary-excluded'
        foreach ($name in @('empty-stdout', 'missing-marker', 'bad-hash')) {
            New-Item -ItemType Directory -Path (Join-Path $runRoot $name) -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $runRoot $name 'manifest.json') -Value @"
{
  "version": 1,
  "run_id": "$name",
  "task_class": "readonly_diagnostic",
  "recording": {
    "status": "publishable",
    "publishable": true
  }
}
"@ -Encoding UTF8
        }
        Set-Content -LiteralPath (Join-Path $runRoot 'empty-stdout' 'commands.jsonl') -Value @'
{"cli":"Antigravity CLI","model":"Opus 4.7","status":"completed","end_marker_present":true,"packet_hash_match":true,"stdout_empty":true}
'@ -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $runRoot 'missing-marker' 'commands.jsonl') -Value @'
{"cli":"Codex","model":"gpt-5.5","status":"completed","end_marker_present":false,"packet_hash_match":true,"stdout_empty":false}
'@ -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $runRoot 'bad-hash' 'commands.jsonl') -Value @'
{"cli":"Claude Code","model":"Opus 4.8","status":"completed","end_marker_present":true,"packet_hash_match":false,"stdout_empty":false}
'@ -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:SummaryScript -RunRoot $runRoot -OutputDir $outputDir -PackPath $script:PackPath -Json
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json -Depth 20
        $result.scoreable_runs | Should -Be 0

        $raw = Get-Content -LiteralPath (Join-Path $outputDir 'raw-score-matrix.csv') -Raw -Encoding UTF8
        $raw | Should -Match 'antigravity_empty_stdout'
        $raw | Should -Match 'empty_stdout'
        $raw | Should -Match 'missing_end_marker'
        $raw | Should -Match 'packet_hash_mismatch'
    }

    It 'records Harness Bench exclusion reasons without scoring operator or blocked workers' {
        $runRoot = Join-Path $TestDrive 'runs-harness-exclusions'
        $outputDir = Join-Path $TestDrive 'summary-harness-exclusions'
        foreach ($name in @('missing-key', 'timeout', 'crash', 'invalid-output', 'operator')) {
            New-Item -ItemType Directory -Path (Join-Path $runRoot $name) -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $runRoot $name 'manifest.json') -Value @"
{
  "version": 1,
  "run_id": "$name",
  "task_class": "harness_contract",
  "recording": {
    "status": "publishable",
    "publishable": true
  }
}
"@ -Encoding UTF8
        }
        Set-Content -LiteralPath (Join-Path $runRoot 'missing-key' 'commands.jsonl') -Value @'
{"cli":"OpenRouter API","model":"OpenRouter / GLM-5.2","status":"api_llm_api_key_env_missing","end_marker_present":true,"packet_hash_match":true,"stdout_empty":false}
'@ -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $runRoot 'timeout' 'commands.jsonl') -Value @'
{"cli":"Codex","model":"gpt-5.5","status":"timeout","timed_out":true,"end_marker_present":true,"packet_hash_match":true,"stdout_empty":false}
'@ -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $runRoot 'crash' 'commands.jsonl') -Value @'
{"cli":"Claude Code","model":"Sonnet","status":"crashed","crashed":true,"end_marker_present":true,"packet_hash_match":true,"stdout_empty":false}
'@ -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $runRoot 'invalid-output' 'commands.jsonl') -Value @'
{"cli":"Antigravity CLI","model":"Gemini High","status":"completed","invalid_output":true,"end_marker_present":true,"packet_hash_match":true,"stdout_empty":false}
'@ -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $runRoot 'operator' 'commands.jsonl') -Value @'
{"cli":"operator","model":"run-control","role":"operator","status":"completed","end_marker_present":true,"packet_hash_match":true,"stdout_empty":false}
'@ -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:SummaryScript -RunRoot $runRoot -OutputDir $outputDir -PackPath $script:PackPath -Json
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json -Depth 20
        $result.scoreable_runs | Should -Be 0

        $raw = Get-Content -LiteralPath (Join-Path $outputDir 'raw-score-matrix.csv') -Raw -Encoding UTF8
        $raw | Should -Match 'missing_api_key'
        $raw | Should -Match 'timeout'
        $raw | Should -Match 'crash'
        $raw | Should -Match 'invalid_output'
        $raw | Should -Match 'operator_run'
    }

    It 'keeps malformed manifests as blocked evidence instead of aborting the summary' {
        $runRoot = Join-Path $TestDrive 'runs-malformed'
        $runDir = Join-Path $runRoot 'bad-json'
        $outputDir = Join-Path $TestDrive 'summary-malformed'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $runDir 'manifest.json') -Value '{ invalid json' -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:SummaryScript -RunRoot $runRoot -OutputDir $outputDir -PackPath $script:PackPath -Json
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json -Depth 20
        $result.scoreable_runs | Should -Be 0
        $raw = Get-Content -LiteralPath (Join-Path $outputDir 'raw-score-matrix.csv') -Raw -Encoding UTF8
        $raw | Should -Match 'invalid_json'
    }
}
