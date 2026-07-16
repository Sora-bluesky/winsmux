#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(0, 100)]
    [int]$CoverageThreshold = 75,

    [switch]$Coverage,

    [switch]$Parallel = $true,

    [ValidateRange(1, 256)]
    [int]$MaxParallel = [Environment]::ProcessorCount,

    [string]$ResultsDirectory,

    [Parameter(DontShow = $true)]
    [string]$WorkerSpecPath,

    [Parameter(DontShow = $true)]
    [ValidateRange(1, 7200)]
    [int]$WorkerTimeoutSeconds = 1200,

    [Parameter(DontShow = $true)]
    [string]$WorkerStdOutPath,

    [Parameter(DontShow = $true)]
    [string]$WorkerStdErrPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CoverageTargets {
    param([string]$RepositoryRoot)

    $testFiles = Get-ChildItem -Path (Join-Path $RepositoryRoot 'tests') -Filter '*.Tests.ps1' -File -ErrorAction SilentlyContinue
    $targets = [System.Collections.Generic.List[string]]::new()

    foreach ($testFile in $testFiles) {
        $content = Get-Content -Path $testFile.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) {
            continue
        }

        $matches = [regex]::Matches($content, '(?im)(?:Join-Path\s+\$PSScriptRoot\s+[''\"](?<relative>\.\.[\\/][^''\"]+\.(?:ps1|psm1))[''\"]|(?<literal>\.\.[\\/][^\s''\"\"]+\.(?:ps1|psm1)))')
        foreach ($match in $matches) {
            $relativePath = if ($match.Groups['relative'].Success) {
                $match.Groups['relative'].Value
            } else {
                $match.Groups['literal'].Value
            }

            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                continue
            }

            $candidate = [System.IO.Path]::GetFullPath((Join-Path $testFile.DirectoryName $relativePath))
            if ((Test-Path -LiteralPath $candidate) -and ($candidate -notin $targets)) {
                [void]$targets.Add($candidate)
            }
        }
    }

    if ($targets.Count -gt 0) {
        return $targets.ToArray()
    }

    return Get-ChildItem -Path (Join-Path $RepositoryRoot 'scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'run-tests.ps1' } |
        Select-Object -ExpandProperty FullName
}

function Get-CoveragePercent {
    param([object]$CodeCoverage)

    if (-not $CodeCoverage) {
        return $null
    }

    if ($CodeCoverage.PSObject.Properties.Name -contains 'CoveragePercent') {
        return [double]$CodeCoverage.CoveragePercent
    }

    if (($CodeCoverage.PSObject.Properties.Name -contains 'NumberOfCommandsAnalyzed') -and
        ($CodeCoverage.PSObject.Properties.Name -contains 'NumberOfCommandsExecuted')) {
        $analyzed = [double]$CodeCoverage.NumberOfCommandsAnalyzed
        if ($analyzed -le 0) {
            return 0
        }

        return [math]::Round(([double]$CodeCoverage.NumberOfCommandsExecuted / $analyzed) * 100, 2)
    }

    return $null
}

function Write-TestSummary {
    param(
        [string]$Path,
        [int]$PassedCount,
        [int]$FailedCount,
        [int]$TotalCount,
        [Nullable[double]]$CoveragePercent,
        [int]$CoverageThreshold,
        [System.Collections.IDictionary]$Additional = @{}
    )

    $summary = [ordered]@{
        passed = $PassedCount
        failed = $FailedCount
        total = $TotalCount
        coveragePercent = $CoveragePercent
        coverageThreshold = $CoverageThreshold
    }
    foreach ($entry in $Additional.GetEnumerator()) {
        $summary[[string]$entry.Key] = $entry.Value
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-TestIdentity {
    param([Parameter(Mandatory = $true)]$Test)

    $file = ([string]$Test.ScriptBlock.File).Replace('\', '/')
    $testsMarker = '/tests/'
    $testsIndex = $file.LastIndexOf($testsMarker, [StringComparison]::OrdinalIgnoreCase)
    if ($testsIndex -ge 0) {
        $file = 'tests/' + $file.Substring($testsIndex + $testsMarker.Length)
    }
    # Use the unexpanded source name. Discovery intentionally retains <Case>
    # placeholders while execution expands them, so ExpandedName is not a
    # stable identity across the two phases. Repeated dynamic cases remain a
    # multiset because each source-line/name identity is kept once per case.
    return '{0}:{1}|{2}' -f $file, $Test.StartLine, [string]$Test.Name
}

function Get-IdentityHash {
    param([string[]]$Identities)

    $text = (@($Identities | Sort-Object) -join "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)))).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue = $null
    )

    if ($InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }
    return $DefaultValue
}

function Get-IsolatedChildEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$TempDirectory,
        [Parameter(Mandatory = $true)][string]$ProjectDirectory
    )

    # Pass only non-secret platform/runtime context that tests need. In particular,
    # do not inherit credential carriers such as *_TOKEN, GIT_ASKPASS,
    # SSH_AUTH_SOCK, DOCKER_AUTH_CONFIG, or CI_JOB_JWT.
    $allowedNames = @(
        'APPDATA', 'CI', 'COMPUTERNAME', 'ComSpec', 'GITHUB_ACTIONS',
        'GITHUB_EVENT_NAME', 'GITHUB_WORKSPACE', 'HOME', 'HOMEDRIVE',
        'HOMEPATH', 'LOCALAPPDATA', 'NO_PROXY', 'NUMBER_OF_PROCESSORS',
        'OS', 'Path', 'PATHEXT', 'PROCESSOR_ARCHITECTURE',
        'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION',
        'ProgramData', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432',
        'PSModulePath', 'RUNNER_ARCH', 'RUNNER_OS', 'RUNNER_TEMP',
        'SystemDrive', 'SystemRoot', 'TF_BUILD', 'USERDOMAIN', 'USERNAME',
        'USERPROFILE', 'windir'
    )
    $environment = [ordered]@{}
    foreach ($name in $allowedNames) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($value)) {
            $environment[$name] = $value
        }
    }
    $environment['TEMP'] = $TempDirectory
    $environment['TMP'] = $TempDirectory
    $environment['WINSMUX_ORCHESTRA_PROJECT_DIR'] = $ProjectDirectory
    $environment['WINSMUX_TEST_PROJECT_DIR'] = $ProjectDirectory
    $environment['NO_COLOR'] = '1'
    $environment['GIT_TERMINAL_PROMPT'] = '0'
    $environment['GCM_INTERACTIVE'] = 'Never'
    return $environment
}

function Invoke-IsolatedPwshWorkers {
    param(
        [Parameter(Mandatory = $true)][string[]]$SpecPaths,
        [Parameter(Mandatory = $true)][string]$RunnerPath,
        [Parameter(Mandatory = $true)][string]$PwshPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][int]$ThrottleLimit,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $pending = [System.Collections.Generic.Queue[string]]::new()
    foreach ($specPath in $SpecPaths) {
        $pending.Enqueue($specPath)
    }
    $running = [System.Collections.Generic.List[object]]::new()
    $completed = [System.Collections.Generic.List[object]]::new()

    try {
        while (($pending.Count -gt 0) -or ($running.Count -gt 0)) {
            while (($pending.Count -gt 0) -and ($running.Count -lt $ThrottleLimit)) {
                $specPath = $pending.Dequeue()
                $spec = Get-Content -LiteralPath $specPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                $process = $null
                try {
                    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
                    $startInfo.FileName = $PwshPath
                    foreach ($argument in @(
                        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $RunnerPath,
                        '-WorkerSpecPath', $specPath,
                        '-WorkerTimeoutSeconds', [string]$TimeoutSeconds,
                        '-WorkerStdOutPath', [string]$spec.StdOutPath,
                        '-WorkerStdErrPath', [string]$spec.StdErrPath
                    )) {
                        $startInfo.ArgumentList.Add($argument)
                    }
                    $startInfo.WorkingDirectory = $RepositoryRoot
                    $startInfo.UseShellExecute = $false
                    $startInfo.CreateNoWindow = $true
                    $startInfo.RedirectStandardInput = $true
                    $startInfo.Environment.Clear()
                    $childEnvironment = Get-IsolatedChildEnvironment -TempDirectory ([string]$spec.TempDirectory) -ProjectDirectory ([string]$spec.ProjectDirectory)
                    foreach ($entry in $childEnvironment.GetEnumerator()) {
                        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
                    }

                    $process = [System.Diagnostics.Process]::new()
                    $process.StartInfo = $startInfo
                    [void]$process.Start()
                    $process.StandardInput.Close()
                    $running.Add([PSCustomObject]@{
                        WorkerId = [string]$spec.WorkerId
                        SpecPath = $specPath
                        Process = $process
                        StdOutPath = [string]$spec.StdOutPath
                        StdErrPath = [string]$spec.StdErrPath
                        DeadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
                    })
                    $process = $null
                } catch {
                    if ($null -ne $process) {
                        try {
                            if (-not $process.HasExited) { $process.Kill($true) }
                        } catch {}
                        $process.Dispose()
                    }
                    $completed.Add([PSCustomObject]@{
                        WorkerId = [string]$spec.WorkerId
                        SpecPath = $specPath
                        ExitCode = -1
                        StdOut = ''
                        StdErr = ''
                        LaunchError = $_.Exception.Message
                    })
                }
            }

            foreach ($state in @($running)) {
                $timedOut = (-not $state.Process.HasExited) -and ([DateTime]::UtcNow -ge $state.DeadlineUtc)
                if ($timedOut) {
                    try { $state.Process.Kill($true) } catch {}
                }
                if ($timedOut -or $state.Process.HasExited) {
                    $stopped = $state.Process.WaitForExit(5000)
                    if (-not $stopped) {
                        try { $state.Process.Kill($true) } catch {}
                        $stopped = $state.Process.WaitForExit(5000)
                    }
                    $completed.Add([PSCustomObject]@{
                        WorkerId = [string]$state.WorkerId
                        SpecPath = [string]$state.SpecPath
                        ExitCode = $(if (-not $stopped) { -3 } elseif ($timedOut) { -2 } else { [int]$state.Process.ExitCode })
                        StdOut = $(if (Test-Path -LiteralPath $state.StdOutPath) { Get-Content -LiteralPath $state.StdOutPath -Raw -Encoding UTF8 } else { '' })
                        StdErr = $(if (Test-Path -LiteralPath $state.StdErrPath) { Get-Content -LiteralPath $state.StdErrPath -Raw -Encoding UTF8 } else { '' })
                        LaunchError = $(if (-not $stopped) { 'worker process tree could not be terminated' } elseif ($timedOut) { "worker exceeded ${TimeoutSeconds}s timeout" } else { '' })
                    })
                    $state.Process.Dispose()
                    [void]$running.Remove($state)
                }
            }
            if ($running.Count -gt 0) {
                Start-Sleep -Milliseconds 50
            }
        }
    } finally {
        foreach ($state in @($running)) {
            try {
                if (-not $state.Process.HasExited) { $state.Process.Kill($true) }
                if (-not $state.Process.WaitForExit(5000)) {
                    try { $state.Process.Kill($true) } catch {}
                    [void]$state.Process.WaitForExit(5000)
                }
            } catch {
            } finally {
                $state.Process.Dispose()
            }
        }
    }

    return $completed.ToArray()
}

function Invoke-PesterIsolated {
    param([Parameter(Mandatory = $true)]$Configuration)

    return & {
        # The runner's StrictMode must not leak into third-party test scopes.
        Set-StrictMode -Off
        Invoke-Pester -Configuration $Configuration
    }
}

function Get-PesterModule {
    return Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
}

function Invoke-SerialSuite {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$TestResultPath,
        [Parameter(Mandatory = $true)][string]$CoverageReportPath,
        [Parameter(Mandatory = $true)]$PesterModule,
        [switch]$EnableCoverage
    )

    $coverageTargets = @()
    if ($EnableCoverage) {
        $coverageTargets = @(Get-CoverageTargets -RepositoryRoot $RepositoryRoot)
        if ($coverageTargets.Count -eq 0) {
            throw 'Pester coverage was requested, but no coverage targets were found.'
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($PesterModule.Version.Major -ge 5) {
        Import-Module $PesterModule.Path -Force -ErrorAction Stop | Out-Null
        $configuration = [PesterConfiguration]::Default
        $configuration.Run.Path = @((Join-Path $RepositoryRoot 'tests'))
        $configuration.Run.PassThru = $true
        $configuration.Run.Exit = $false
        $configuration.Output.Verbosity = 'None'
        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = 'NUnitXml'
        $configuration.TestResult.OutputPath = $TestResultPath
        $configuration.CodeCoverage.Enabled = [bool]$EnableCoverage
        if ($EnableCoverage) {
            $configuration.CodeCoverage.Path = $coverageTargets
            $configuration.CodeCoverage.OutputPath = $CoverageReportPath
        }
        $result = Invoke-PesterIsolated -Configuration $configuration
    } else {
        if ($EnableCoverage) {
            $result = Invoke-Pester (Join-Path $RepositoryRoot 'tests') -PassThru -Quiet -CodeCoverage $coverageTargets -OutputFormat NUnitXml -OutputFile $TestResultPath
        } else {
            $result = Invoke-Pester (Join-Path $RepositoryRoot 'tests') -PassThru -Quiet -OutputFormat NUnitXml -OutputFile $TestResultPath
        }
    }
    $stopwatch.Stop()

    return [PSCustomObject]@{
        Result = $result
        DurationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    }
}

function Invoke-PesterWorker {
    param([Parameter(Mandatory = $true)][string]$SpecPath)

    $spec = Get-Content -LiteralPath $SpecPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    New-Item -ItemType Directory -Path $spec.TempDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $spec.ProjectDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $spec.ResultPath) -Force | Out-Null

    try {
        if ([string]$spec.Mode -eq 'Discovery') {
            $discovery = Invoke-TestDiscovery -TestsPath ([string]$spec.TestsPath) -PesterModulePath ([string]$spec.PesterModulePath)
            $tests = @($discovery.Tests | ForEach-Object {
                $pathParts = @($_.Path | ForEach-Object { [string]$_ })
                $expandedName = if ($_.PSObject.Properties.Name -contains 'ExpandedName') { [string]$_.ExpandedName } else { [string]$_.Name }
                [PSCustomObject]@{
                    file = [System.IO.Path]::GetFullPath([string]$_.ScriptBlock.File)
                    startLine = [int]$_.StartLine
                    identity = Get-TestIdentity -Test $_
                    topLevelName = $(if ($pathParts.Count -gt 0) { [string]$pathParts[0] } else { $expandedName })
                    fullNameCandidates = @(
                        $expandedName
                        ([string]$_.ExpandedPath)
                        ($pathParts -join ' ')
                        ($pathParts -join ' > ')
                    )
                    skipped = $(
                        (($_.PSObject.Properties.Name -contains 'Skipped') -and [bool]$_.Skipped) -or
                        (($_.PSObject.Properties.Name -contains 'Skip') -and [bool]$_.Skip)
                    )
                }
            })
            $payload = [ordered]@{
                mode = 'discovery'
                workerId = [string]$spec.WorkerId
                total = [int]$discovery.TotalCount
                failedBlocks = [int]$discovery.FailedBlocksCount
                failedContainers = [int]$discovery.FailedContainersCount
                identityHash = Get-IdentityHash -Identities @($tests.identity)
                tests = $tests
            }
            $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $spec.ResultPath -Encoding UTF8
            return 0
        }

        Import-Module ([string]$spec.PesterModulePath) -Force -ErrorAction Stop | Out-Null
        $configuration = [PesterConfiguration]::Default
        $configuration.Run.Path = @($spec.Paths)
        $configuration.Run.PassThru = $true
        $configuration.Run.Exit = $false
        $configuration.Output.Verbosity = 'None'
        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = 'NUnitXml'
        $configuration.TestResult.OutputPath = [string]$spec.NUnitPath
        $configuration.CodeCoverage.Enabled = $false
        if (@($spec.LineFilters).Count -gt 0) {
            $configuration.Filter.Line = @($spec.LineFilters)
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-PesterIsolated -Configuration $configuration
        $stopwatch.Stop()

        $selectedTests = if (@($spec.LineFilters).Count -gt 0) {
            $selectedLines = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($line in @($spec.LineFilters)) { [void]$selectedLines.Add(([string]$line).Replace('\', '/')) }
            @($result.Tests | Where-Object {
                $lineIdentity = '{0}:{1}' -f ([string]$_.ScriptBlock.File).Replace('\', '/'), [int]$_.StartLine
                $selectedLines.Contains($lineIdentity)
            })
        } else {
            @($result.Tests)
        }
        $selectedTests = @($selectedTests)
        $identities = @($selectedTests | ForEach-Object { Get-TestIdentity -Test $_ })
        $passed = @($selectedTests | Where-Object { [string]$_.Result -eq 'Passed' }).Count
        $failed = @($selectedTests | Where-Object { [string]$_.Result -eq 'Failed' }).Count
        $skipped = @($selectedTests | Where-Object { [string]$_.Result -eq 'Skipped' }).Count
        $notRun = @($selectedTests | Where-Object { [string]$_.Result -eq 'NotRun' }).Count
        $inconclusive = @($selectedTests | Where-Object { [string]$_.Result -eq 'Inconclusive' }).Count
        $payload = [ordered]@{
            workerId = [string]$spec.WorkerId
            expectedCount = [int]$spec.ExpectedCount
            total = [int]$selectedTests.Count
            passed = [int]$passed
            failed = [int]$failed
            skipped = [int]$skipped
            notRun = [int]$notRun
            inconclusive = [int]$inconclusive
            failedBlocks = [int]$result.FailedBlocksCount
            failedContainers = [int]$result.FailedContainersCount
            result = [string]$result.Result
            durationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
            pesterVersion = [string]$result.Version
            nunitPath = [string]$spec.NUnitPath
            tempDirectory = [string]$spec.TempDirectory
            projectDirectory = [string]$spec.ProjectDirectory
            identityHash = Get-IdentityHash -Identities $identities
            identities = $identities
        }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $spec.ResultPath -Encoding UTF8

        if (($payload.failed -eq 0) -and ($payload.failedBlocks -eq 0) -and ($payload.failedContainers -eq 0)) {
            return 0
        }
        return 1
    } catch {
        $failure = [ordered]@{
            workerId = [string]$spec.WorkerId
            expectedCount = [int]$spec.ExpectedCount
            total = 0
            passed = 0
            failed = 0
            skipped = 0
            notRun = 0
            inconclusive = 0
            failedBlocks = 0
            failedContainers = 1
            result = 'HarnessError'
            durationSeconds = 0
            pesterVersion = ''
            nunitPath = [string]$spec.NUnitPath
            tempDirectory = [string]$spec.TempDirectory
            projectDirectory = [string]$spec.ProjectDirectory
            identityHash = ''
            identities = @()
            harnessError = $_.Exception.Message
        }
        $failure | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $spec.ResultPath -Encoding UTF8
        [Console]::Error.WriteLine(('Pester worker {0} failed: {1}' -f $spec.WorkerId, $_.Exception.Message))
        return 2
    }
}

function Invoke-TestDiscovery {
    param(
        [Parameter(Mandatory = $true)][string]$TestsPath,
        [Parameter(Mandatory = $true)][string]$PesterModulePath
    )

    Import-Module $PesterModulePath -Force -ErrorAction Stop | Out-Null
    $configuration = [PesterConfiguration]::Default
    $configuration.Run.Path = @($TestsPath)
    $configuration.Run.PassThru = $true
    $configuration.Run.Exit = $false
    $configuration.Run.SkipRun = $true
    $configuration.Output.Verbosity = 'None'
    $configuration.TestResult.Enabled = $false
    $configuration.CodeCoverage.Enabled = $false
    $result = Invoke-PesterIsolated -Configuration $configuration

    if (($result.FailedBlocksCount -gt 0) -or ($result.FailedContainersCount -gt 0)) {
        throw "Pester discovery failed: blocks=$($result.FailedBlocksCount) containers=$($result.FailedContainersCount)"
    }
    return $result
}

function Get-BridgeShards {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $workflowPath = Join-Path $RepositoryRoot '.github\workflows\test.yml'
    if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) {
        throw "Bridge shard source is missing: $workflowPath"
    }
    $workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
    $matches = [regex]::Matches(
        $workflow,
        '(?ms)^\s{10}- name:\s+(?<name>bridge-[^\r\n]+)\r?\n(?<body>.*?)(?=^\s{10}- name:|^\s{6}[a-zA-Z_-]+:|\z)'
    )
    $shards = [System.Collections.Generic.List[object]]::new()
    foreach ($match in $matches) {
        $fullNameMatch = [regex]::Match($match.Groups['body'].Value, '(?m)^\s+full_name:\s*(?<value>[^\r\n]+)$')
        if (-not $fullNameMatch.Success) {
            throw "Bridge shard $($match.Groups['name'].Value) has no full_name filter."
        }
        $value = $fullNameMatch.Groups['value'].Value.Trim().Trim('''', '"')
        $filters = @($value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($filters.Count -eq 0) {
            throw "Bridge shard $($match.Groups['name'].Value) has an empty full_name filter."
        }
        $shards.Add([PSCustomObject]@{
            Name = [string]$match.Groups['name'].Value
            Filters = $filters
            Tests = [System.Collections.Generic.List[object]]::new()
        })
    }
    if ($shards.Count -ne 13) {
        throw "Expected 13 bridge CI shards, found $($shards.Count)."
    }
    return $shards.ToArray()
}

function New-PesterWorkUnits {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]$DiscoveryResult
    )

    $testsPath = Join-Path $RepositoryRoot 'tests'
    $testFiles = @(Get-ChildItem -LiteralPath $testsPath -Filter '*.Tests.ps1' -File | Sort-Object Name)
    if ($testFiles.Count -eq 0) {
        throw 'No Pester test files were found.'
    }

    $testsByFile = @{}
    foreach ($test in $DiscoveryResult.tests) {
        $file = [System.IO.Path]::GetFullPath([string]$test.file)
        if (-not $testsByFile.ContainsKey($file)) {
            $testsByFile[$file] = [System.Collections.Generic.List[object]]::new()
        }
        $testsByFile[$file].Add($test)
    }

    $units = [System.Collections.Generic.List[object]]::new()
    $bridgeFile = $testFiles | Where-Object Name -EQ 'winsmux-bridge.Tests.ps1' | Select-Object -First 1
    foreach ($file in $testFiles | Where-Object Name -NE 'winsmux-bridge.Tests.ps1') {
        $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
        if (-not $testsByFile.ContainsKey($fullPath)) {
            throw "Pester discovery did not return tests for $fullPath"
        }
        $units.Add([PSCustomObject]@{
            WorkerId = 'file-' + [System.IO.Path]::GetFileNameWithoutExtension($file.Name).ToLowerInvariant().Replace('.', '-')
            Paths = @($fullPath)
            LineFilters = @()
            ExpectedCount = [int]$testsByFile[$fullPath].Count
        })
    }

    if ($null -ne $bridgeFile) {
        $bridgePath = [System.IO.Path]::GetFullPath($bridgeFile.FullName)
        if (-not $testsByFile.ContainsKey($bridgePath)) {
            throw 'Pester discovery did not return bridge tests.'
        }
        $bridgeTests = @($testsByFile[$bridgePath])
        if (@($bridgeTests | Where-Object { [bool]$_.skipped }).Count -gt 0) {
            throw 'Bridge line sharding cannot safely override skipped tests.'
        }

        $shards = @(Get-BridgeShards -RepositoryRoot $RepositoryRoot)
        $unmatched = [System.Collections.Generic.List[object]]::new()
        foreach ($test in $bridgeTests) {
            $matchingShards = @($shards | Where-Object {
                $shard = $_
                @($shard.Filters | Where-Object {
                    $filter = $_
                    @($test.fullNameCandidates | Where-Object { [string]$_ -like $filter }).Count -gt 0
                }).Count -gt 0
            })
            if ($matchingShards.Count -gt 0) {
                # CI filters can overlap. Assign once to preserve the serial identity
                # multiset while retaining the first CI matrix lane as precedence.
                $matchingShards[0].Tests.Add($test)
            } else {
                $unmatched.Add($test)
            }
        }

        # The current CI matrix has known coverage gaps. Keep every previously
        # unlisted top-level Describe together and place it in the least-loaded
        # CI lane so the local full gate cannot silently omit tests.
        foreach ($group in @($unmatched | Group-Object topLevelName | Sort-Object @{ Expression = 'Count'; Descending = $true }, Name)) {
            $target = $shards | Sort-Object @{ Expression = { $_.Tests.Count } }, Name | Select-Object -First 1
            foreach ($test in $group.Group) {
                $target.Tests.Add($test)
            }
        }

        foreach ($shard in $shards) {
            if ($shard.Tests.Count -eq 0) {
                throw "Bridge CI shard $($shard.Name) resolved to zero tests."
            }
            $lineFilters = @($shard.Tests | ForEach-Object {
                '{0}:{1}' -f ([string]$_.file).Replace('\', '/'), [int]$_.startLine
            } | Sort-Object -Unique)
            $units.Add([PSCustomObject]@{
                WorkerId = [string]$shard.Name
                Paths = @($bridgePath)
                LineFilters = $lineFilters
                ExpectedCount = [int]$shard.Tests.Count
            })
        }
    }

    $expected = [int](($units | Measure-Object ExpectedCount -Sum).Sum)
    if ($expected -ne [int]$DiscoveryResult.total) {
        throw "Pester work-unit coverage mismatch: units=$expected discovery=$($DiscoveryResult.total)"
    }
    return $units.ToArray()
}

function Merge-NUnitResults {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][int]$TotalCount,
        [Parameter(Mandatory = $true)][int]$FailedCount,
        [Parameter(Mandatory = $true)][int]$ErrorsCount,
        [Parameter(Mandatory = $true)][int]$SkippedCount,
        [Parameter(Mandatory = $true)][int]$NotRunCount,
        [Parameter(Mandatory = $true)][int]$InconclusiveCount,
        [Parameter(Mandatory = $true)][double]$DurationSeconds
    )

    if ($Paths.Count -eq 0) {
        throw 'No NUnit result files were supplied for merge.'
    }
    [xml]$merged = Get-Content -LiteralPath $Paths[0] -Raw -Encoding UTF8
    if ($merged.DocumentElement.LocalName -ne 'test-results') {
        throw "Unexpected NUnit root in $($Paths[0])"
    }
    $mergedSuite = $merged.DocumentElement.SelectSingleNode('test-suite')
    $mergedResults = $mergedSuite.SelectSingleNode('results')
    if ($null -eq $mergedResults) {
        throw "NUnit result has no test-suite/results node: $($Paths[0])"
    }
    $mergedResults.RemoveAll()

    foreach ($path in $Paths) {
        [xml]$worker = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ($worker.DocumentElement.LocalName -ne 'test-results') {
            throw "Unexpected NUnit root in $path"
        }
        $workerResults = $worker.DocumentElement.SelectSingleNode('test-suite/results')
        if ($null -eq $workerResults) {
            throw "NUnit result has no test-suite/results node: $path"
        }
        foreach ($node in @($workerResults.ChildNodes)) {
            [void]$mergedResults.AppendChild($merged.ImportNode($node, $true))
        }
    }

    $executedCount = $TotalCount - $NotRunCount
    $suiteResult = if (($FailedCount -gt 0) -or ($ErrorsCount -gt 0)) {
        'Failure'
    } elseif ($SkippedCount -gt 0) {
        'Ignored'
    } elseif ($InconclusiveCount -gt 0) {
        'Inconclusive'
    } else {
        'Success'
    }
    $success = ($FailedCount -eq 0) -and ($ErrorsCount -eq 0)
    $merged.DocumentElement.SetAttribute('name', 'Pester')
    $merged.DocumentElement.SetAttribute('total', [string]$executedCount)
    $merged.DocumentElement.SetAttribute('errors', [string]$ErrorsCount)
    $merged.DocumentElement.SetAttribute('failures', [string]$FailedCount)
    $merged.DocumentElement.SetAttribute('not-run', [string]$NotRunCount)
    $merged.DocumentElement.SetAttribute('inconclusive', [string]$InconclusiveCount)
    $merged.DocumentElement.SetAttribute('ignored', '0')
    $merged.DocumentElement.SetAttribute('skipped', [string]$SkippedCount)
    $merged.DocumentElement.SetAttribute('invalid', '0')
    $merged.DocumentElement.SetAttribute('date', (Get-Date).ToString('yyyy-MM-dd'))
    $merged.DocumentElement.SetAttribute('time', (Get-Date).ToString('HH:mm:ss'))
    $mergedSuite.SetAttribute('name', 'Pester')
    $mergedSuite.SetAttribute('executed', 'True')
    $mergedSuite.SetAttribute('result', $suiteResult)
    $mergedSuite.SetAttribute('success', $(if ($success) { 'True' } else { 'False' }))
    $mergedSuite.SetAttribute('time', $DurationSeconds.ToString('0.000', [System.Globalization.CultureInfo]::InvariantCulture))

    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $settings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($OutputPath, $settings)
    try {
        $merged.Save($writer)
    } finally {
        $writer.Dispose()
    }

    [xml]$verification = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8
    if ([int]$verification.DocumentElement.GetAttribute('total') -ne $executedCount -or
        [int]$verification.DocumentElement.GetAttribute('not-run') -ne $NotRunCount -or
        [int]$verification.DocumentElement.GetAttribute('skipped') -ne $SkippedCount) {
        throw 'Merged NUnit result counts do not match the aggregate.'
    }
}

function Invoke-ParallelSuite {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ResultsRoot,
        [Parameter(Mandatory = $true)][string]$TestResultPath,
        [Parameter(Mandatory = $true)]$PesterModule,
        [Parameter(Mandatory = $true)][int]$ThrottleLimit,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $workerResultsRoot = Join-Path $ResultsRoot 'pester-workers'
    if (Test-Path -LiteralPath $workerResultsRoot) {
        Remove-Item -LiteralPath $workerResultsRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $workerResultsRoot -Force | Out-Null
    $executionRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-pester-' + $runId)
    New-Item -ItemType Directory -Path $executionRoot -Force | Out-Null

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $harnessFailures = [System.Collections.Generic.List[string]]::new()
    try {
        $runnerPath = $PSCommandPath
        $pwshPath = (Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source
        $discoveryRoot = Join-Path $workerResultsRoot '000-discovery'
        $discoveryTemp = Join-Path $executionRoot '000-discovery'
        $discoveryProject = Join-Path $discoveryTemp 'project'
        New-Item -ItemType Directory -Path $discoveryRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $discoveryProject -Force | Out-Null
        $discoverySpec = [ordered]@{
            Mode = 'Discovery'
            WorkerId = 'discovery'
            TestsPath = Join-Path $RepositoryRoot 'tests'
            ResultPath = Join-Path $discoveryRoot 'result.json'
            StdOutPath = Join-Path $discoveryRoot 'stdout.log'
            StdErrPath = Join-Path $discoveryRoot 'stderr.log'
            TempDirectory = $discoveryTemp
            ProjectDirectory = $discoveryProject
            PesterModulePath = [string]$PesterModule.Path
        }
        $discoverySpecPath = Join-Path $discoveryRoot 'spec.json'
        $discoverySpec | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $discoverySpecPath -Encoding UTF8
        $discoveryLaunch = @(Invoke-IsolatedPwshWorkers -SpecPaths @($discoverySpecPath) -RunnerPath $runnerPath -PwshPath $pwshPath -RepositoryRoot $RepositoryRoot -ThrottleLimit 1 -TimeoutSeconds $TimeoutSeconds)
        if (($discoveryLaunch.Count -ne 1) -or ($discoveryLaunch[0].ExitCode -ne 0) -or (-not [string]::IsNullOrWhiteSpace([string]$discoveryLaunch[0].LaunchError))) {
            $detail = if ($discoveryLaunch.Count -eq 1) { "$($discoveryLaunch[0].LaunchError) $($discoveryLaunch[0].StdErr)" } else { 'no launch result' }
            throw "Isolated Pester discovery failed: $detail"
        }
        if (-not (Test-Path -LiteralPath $discoverySpec.ResultPath -PathType Leaf)) {
            throw 'Isolated Pester discovery did not write result JSON.'
        }
        $discovery = Get-Content -LiteralPath $discoverySpec.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if (([string]$discovery.mode -ne 'discovery') -or ([int]$discovery.total -le 0)) {
            throw 'Isolated Pester discovery returned an invalid payload.'
        }
        $expectedIdentities = @($discovery.tests.identity | ForEach-Object { [string]$_ } | Sort-Object)
        $units = @(New-PesterWorkUnits -RepositoryRoot $RepositoryRoot -DiscoveryResult $discovery)
        $specs = [System.Collections.Generic.List[object]]::new()
        $specPaths = [System.Collections.Generic.List[string]]::new()
        $index = 0
        foreach ($unit in $units) {
            $index++
            $workerRoot = Join-Path $workerResultsRoot ('{0:d3}-{1}' -f $index, $unit.WorkerId)
            $workerTemp = Join-Path $executionRoot ('{0:d3}' -f $index)
            $projectDirectory = Join-Path $workerTemp 'project'
            New-Item -ItemType Directory -Path $workerRoot -Force | Out-Null
            New-Item -ItemType Directory -Path $projectDirectory -Force | Out-Null
            $spec = [ordered]@{
                Mode = 'Test'
                WorkerId = [string]$unit.WorkerId
                RepositoryRoot = $RepositoryRoot
                Paths = @($unit.Paths)
                LineFilters = @($unit.LineFilters)
                ExpectedCount = [int]$unit.ExpectedCount
                ResultPath = Join-Path $workerRoot 'result.json'
                NUnitPath = Join-Path $workerRoot 'result.xml'
                StdOutPath = Join-Path $workerRoot 'stdout.log'
                StdErrPath = Join-Path $workerRoot 'stderr.log'
                TempDirectory = $workerTemp
                ProjectDirectory = $projectDirectory
                PesterModulePath = [string]$PesterModule.Path
            }
            $specPath = Join-Path $workerRoot 'spec.json'
            $spec | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $specPath -Encoding UTF8
            $specs.Add([PSCustomObject]$spec)
            $specPaths.Add($specPath)
        }

        if (@($specs.TempDirectory | Sort-Object -Unique).Count -ne $specs.Count) {
            throw 'Pester worker TEMP directories are not unique.'
        }
        if (@($specs.ProjectDirectory | Sort-Object -Unique).Count -ne $specs.Count) {
            throw 'Pester worker project directories are not unique.'
        }

        $launches = @(Invoke-IsolatedPwshWorkers -SpecPaths $specPaths.ToArray() -RunnerPath $runnerPath -PwshPath $pwshPath -RepositoryRoot $RepositoryRoot -ThrottleLimit ([math]::Min($ThrottleLimit, $specPaths.Count)) -TimeoutSeconds $TimeoutSeconds)

        $workerPayloads = [System.Collections.Generic.List[object]]::new()
        foreach ($launch in $launches | Sort-Object WorkerId) {
            if (-not [string]::IsNullOrWhiteSpace([string]$launch.LaunchError)) {
                $harnessFailures.Add("$($launch.WorkerId): launch failed: $($launch.LaunchError)")
                continue
            }
            $spec = Get-Content -LiteralPath $launch.SpecPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not (Test-Path -LiteralPath $spec.ResultPath -PathType Leaf)) {
                $harnessFailures.Add("$($launch.WorkerId): result JSON is missing")
                continue
            }
            try {
                $payload = Get-Content -LiteralPath $spec.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $harnessFailures.Add("$($launch.WorkerId): result JSON is invalid: $($_.Exception.Message)")
                continue
            }
            if ([string]$payload.workerId -ne [string]$launch.WorkerId) {
                $harnessFailures.Add("$($launch.WorkerId): result worker identity mismatch")
            }
            if ([int]$payload.total -ne [int]$spec.ExpectedCount) {
                $harnessFailures.Add("$($launch.WorkerId): expected $($spec.ExpectedCount) tests, got $($payload.total)")
            }
            if (-not (Test-Path -LiteralPath $payload.nunitPath -PathType Leaf)) {
                $harnessFailures.Add("$($launch.WorkerId): NUnit XML is missing")
            } else {
                try {
                    [xml](Get-Content -LiteralPath $payload.nunitPath -Raw -Encoding UTF8) | Out-Null
                } catch {
                    $harnessFailures.Add("$($launch.WorkerId): NUnit XML is invalid: $($_.Exception.Message)")
                }
            }
            if ([int]$launch.ExitCode -ne 0) {
                $detail = if ($payload.PSObject.Properties.Name -contains 'harnessError') { [string]$payload.harnessError } else { [string]$launch.StdErr }
                $harnessFailures.Add("$($launch.WorkerId): child exit $($launch.ExitCode) $detail")
            }
            $workerPayloads.Add($payload)
        }

        $totalCount = [int](($workerPayloads | Measure-Object total -Sum).Sum)
        $passedCount = [int](($workerPayloads | Measure-Object passed -Sum).Sum)
        $failedCount = [int](($workerPayloads | Measure-Object failed -Sum).Sum)
        $skippedCount = [int](($workerPayloads | Measure-Object skipped -Sum).Sum)
        $notRunCount = [int](($workerPayloads | Measure-Object notRun -Sum).Sum)
        $inconclusiveCount = [int](($workerPayloads | Measure-Object inconclusive -Sum).Sum)
        $failedBlocks = [int](($workerPayloads | Measure-Object failedBlocks -Sum).Sum)
        $failedContainers = [int](($workerPayloads | Measure-Object failedContainers -Sum).Sum)
        $actualIdentities = @($workerPayloads.identities | ForEach-Object { [string]$_ } | Sort-Object)
        if ($totalCount -ne [int]$discovery.total) {
            $harnessFailures.Add("aggregate total $totalCount does not match discovery total $($discovery.total)")
        }
        if ($actualIdentities.Count -ne $expectedIdentities.Count) {
            $harnessFailures.Add("identity count $($actualIdentities.Count) does not match discovery $($expectedIdentities.Count)")
        } else {
            for ($identityIndex = 0; $identityIndex -lt $expectedIdentities.Count; $identityIndex++) {
                if ($expectedIdentities[$identityIndex] -cne $actualIdentities[$identityIndex]) {
                    $harnessFailures.Add("test identity multiset mismatch at index $identityIndex")
                    break
                }
            }
        }

        $stopwatch.Stop()
        $nunitPaths = @($workerPayloads.nunitPath | ForEach-Object { [string]$_ })
        if ($nunitPaths.Count -eq $workerPayloads.Count) {
            Merge-NUnitResults -Paths $nunitPaths -OutputPath $TestResultPath -TotalCount $totalCount -FailedCount $failedCount -ErrorsCount ($failedBlocks + $failedContainers) -SkippedCount $skippedCount -NotRunCount $notRunCount -InconclusiveCount $inconclusiveCount -DurationSeconds $stopwatch.Elapsed.TotalSeconds
        }

        return [PSCustomObject]@{
            RunId = $runId
            DurationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
            WorkerCount = $units.Count
            TotalCount = $totalCount
            PassedCount = $passedCount
            FailedCount = $failedCount
            SkippedCount = $skippedCount
            NotRunCount = $notRunCount
            FailedBlocksCount = $failedBlocks
            FailedContainersCount = $failedContainers
            IdentityHash = Get-IdentityHash -Identities $actualIdentities
            DiscoveryIdentityHash = Get-IdentityHash -Identities $expectedIdentities
            HarnessFailures = $harnessFailures
        }
    } finally {
        if ($stopwatch.IsRunning) {
            $stopwatch.Stop()
        }
        if (Test-Path -LiteralPath $executionRoot) {
            try {
                Remove-Item -LiteralPath $executionRoot -Recurse -Force -ErrorAction Stop
            } catch {
                $harnessFailures.Add("worker TEMP cleanup failed: $($_.Exception.Message)")
            }
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($WorkerSpecPath)) {
    $workerExitCode = 2
    if (-not [string]::IsNullOrWhiteSpace($WorkerStdOutPath) -and -not [string]::IsNullOrWhiteSpace($WorkerStdErrPath)) {
        $WorkerStdOutPath = [System.IO.Path]::GetFullPath($WorkerStdOutPath)
        $WorkerStdErrPath = [System.IO.Path]::GetFullPath($WorkerStdErrPath)
        New-Item -ItemType Directory -Path (Split-Path -Parent $WorkerStdOutPath) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $WorkerStdErrPath) -Force | Out-Null
        & {
            $script:workerExitCode = Invoke-PesterWorker -SpecPath ([System.IO.Path]::GetFullPath($WorkerSpecPath))
        } 1> $WorkerStdOutPath 2> $WorkerStdErrPath
    } else {
        $workerExitCode = Invoke-PesterWorker -SpecPath ([System.IO.Path]::GetFullPath($WorkerSpecPath))
    }
    exit $workerExitCode
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ResultsDirectory)) {
    $ResultsDirectory = Join-Path $repositoryRoot 'artifacts\test-results'
} else {
    $ResultsDirectory = [System.IO.Path]::GetFullPath($ResultsDirectory)
}
$testResultPath = Join-Path $ResultsDirectory 'pester-results.xml'
$coverageReportPath = Join-Path $ResultsDirectory 'coverage.xml'
$summaryPath = Join-Path $ResultsDirectory 'summary.json'
New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
foreach ($stalePath in @($testResultPath, $coverageReportPath, $summaryPath)) {
    if (Test-Path -LiteralPath $stalePath) {
        Remove-Item -LiteralPath $stalePath -Force
    }
}

$pesterModule = Get-PesterModule
if (-not $pesterModule) {
    Write-TestSummary -Path $summaryPath -PassedCount 0 -FailedCount 1 -TotalCount 0 -CoveragePercent $null -CoverageThreshold $CoverageThreshold -Additional @{ mode = 'unavailable' }
    Write-Output 'Pester: module not found'
    Write-Output 'Coverage: unavailable'
    exit 1
}

$useParallel = [bool]$Parallel -and -not [bool]$Coverage -and ($pesterModule.Version.Major -ge 5)
if ($env:WINSMUX_UPDATE_GOLDEN -eq '1') {
    $useParallel = $false
    Write-Output 'Pester: parallel execution disabled because WINSMUX_UPDATE_GOLDEN=1'
}

try {
    if ($useParallel) {
        Import-Module $pesterModule.Path -Force -ErrorAction Stop | Out-Null
        $probe = [PesterConfiguration]::Default
        $requiredRunProperties = @('Path', 'PassThru', 'Exit', 'SkipRun')
        if (@($requiredRunProperties | Where-Object { $probe.Run.PSObject.Properties.Name -notcontains $_ }).Count -gt 0 -or
            $probe.Filter.PSObject.Properties.Name -notcontains 'Line') {
            $useParallel = $false
            Write-Output 'Pester: parallel features unavailable; using serial execution'
        }
    }

    if ($useParallel) {
        $parallelResult = Invoke-ParallelSuite -RepositoryRoot $repositoryRoot -ResultsRoot $ResultsDirectory -TestResultPath $testResultPath -PesterModule $pesterModule -ThrottleLimit $MaxParallel -TimeoutSeconds $WorkerTimeoutSeconds
        $additional = [ordered]@{
            skipped = $parallelResult.SkippedCount
            notRun = $parallelResult.NotRunCount
            failedBlocks = $parallelResult.FailedBlocksCount
            failedContainers = $parallelResult.FailedContainersCount
            parallel = $true
            durationSeconds = $parallelResult.DurationSeconds
            workerCount = $parallelResult.WorkerCount
            runId = $parallelResult.RunId
            identityHash = $parallelResult.IdentityHash
            discoveryIdentityHash = $parallelResult.DiscoveryIdentityHash
            harnessFailures = @($parallelResult.HarnessFailures)
        }
        Write-TestSummary -Path $summaryPath -PassedCount $parallelResult.PassedCount -FailedCount $parallelResult.FailedCount -TotalCount $parallelResult.TotalCount -CoveragePercent $null -CoverageThreshold $CoverageThreshold -Additional $additional
        Write-Output ('Pester: Passed={0} Failed={1} Total={2}' -f $parallelResult.PassedCount, $parallelResult.FailedCount, $parallelResult.TotalCount)
        Write-Output 'Coverage: disabled'
        Write-Output ('Parallel: Workers={0} Duration={1:N3}s MaxParallel={2}' -f $parallelResult.WorkerCount, $parallelResult.DurationSeconds, $MaxParallel)
        foreach ($failure in @($parallelResult.HarnessFailures)) {
            Write-Warning $failure
        }
        if (($parallelResult.FailedCount -eq 0) -and
            ($parallelResult.FailedBlocksCount -eq 0) -and
            ($parallelResult.FailedContainersCount -eq 0) -and
            (@($parallelResult.HarnessFailures).Count -eq 0)) {
            exit 0
        }
        exit 1
    }

    $serial = Invoke-SerialSuite -RepositoryRoot $repositoryRoot -TestResultPath $testResultPath -CoverageReportPath $coverageReportPath -PesterModule $pesterModule -EnableCoverage:$Coverage
    $result = $serial.Result
    $passedCount = [int](Get-ObjectProperty -InputObject $result -Name 'PassedCount' -DefaultValue 0)
    $failedCount = [int](Get-ObjectProperty -InputObject $result -Name 'FailedCount' -DefaultValue 0)
    $totalCount = [int](Get-ObjectProperty -InputObject $result -Name 'TotalCount' -DefaultValue ($passedCount + $failedCount))
    $skippedCount = [int](Get-ObjectProperty -InputObject $result -Name 'SkippedCount' -DefaultValue 0)
    $notRunCount = [int](Get-ObjectProperty -InputObject $result -Name 'NotRunCount' -DefaultValue 0)
    $failedBlocksCount = [int](Get-ObjectProperty -InputObject $result -Name 'FailedBlocksCount' -DefaultValue 0)
    $failedContainersCount = [int](Get-ObjectProperty -InputObject $result -Name 'FailedContainersCount' -DefaultValue 0)
    $resultTests = @(Get-ObjectProperty -InputObject $result -Name 'Tests' -DefaultValue @())
    $coveragePercent = Get-CoveragePercent -CodeCoverage (Get-ObjectProperty -InputObject $result -Name 'CodeCoverage')
    $thresholdMet = (-not $Coverage) -or (($null -ne $coveragePercent) -and ($coveragePercent -ge $CoverageThreshold))
    $identities = @($resultTests | ForEach-Object { Get-TestIdentity -Test $_ })
    $additional = [ordered]@{
        skipped = $skippedCount
        notRun = $notRunCount
        failedBlocks = $failedBlocksCount
        failedContainers = $failedContainersCount
        parallel = $false
        durationSeconds = $serial.DurationSeconds
        workerCount = 1
        identityHash = Get-IdentityHash -Identities $identities
    }
    Write-TestSummary -Path $summaryPath -PassedCount $passedCount -FailedCount $failedCount -TotalCount $totalCount -CoveragePercent $coveragePercent -CoverageThreshold $CoverageThreshold -Additional $additional
    Write-Output ('Pester: Passed={0} Failed={1} Total={2}' -f $passedCount, $failedCount, $totalCount)
    if ($Coverage) {
        if ($null -ne $coveragePercent) {
            Write-Output ('Coverage: {0:N2}% (threshold: {1}%)' -f $coveragePercent, $CoverageThreshold)
        } else {
            Write-Output ('Coverage: unavailable (threshold: {0}%)' -f $CoverageThreshold)
        }
    } else {
        Write-Output 'Coverage: disabled'
    }
    Write-Output ('Parallel: disabled Duration={0:N3}s' -f $serial.DurationSeconds)

    if (($failedCount -eq 0) -and
        ($failedBlocksCount -eq 0) -and
        ($failedContainersCount -eq 0) -and
        $thresholdMet) {
        exit 0
    }
    exit 1
} catch {
    Write-TestSummary -Path $summaryPath -PassedCount 0 -FailedCount 1 -TotalCount 0 -CoveragePercent $null -CoverageThreshold $CoverageThreshold -Additional @{ mode = 'harness-error'; error = $_.Exception.Message }
    Write-Output 'Pester: Passed=0 Failed=1 Total=0'
    Write-Output $(if ($Coverage) { 'Coverage: unavailable' } else { 'Coverage: disabled' })
    Write-Error $_
    exit 1
}
