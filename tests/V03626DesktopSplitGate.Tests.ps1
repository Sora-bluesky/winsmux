$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$negativeCases = @(
    @{
        Name = 'nonzero child exit with stderr'
        Marker = 'TASK859_RAW_STDERR_NONZERO'
        Body = "process.stderr.write('TASK859_RAW_STDERR_NONZERO'); process.exit(23);"
    }
    @{
        Name = 'empty child stdout'
        Marker = 'TASK859_RAW_STDERR_EMPTY'
        Body = "process.stderr.write('TASK859_RAW_STDERR_EMPTY');"
    }
    @{
        Name = 'malformed child stdout'
        Marker = 'TASK859_RAW_STDERR_MALFORMED'
        Body = "process.stderr.write('TASK859_RAW_STDERR_MALFORMED'); process.stdout.write('{not-json');"
    }
    @{
        Name = 'child ok false'
        Marker = 'TASK859_RAW_STDERR_FALSE'
        Body = "process.stderr.write('TASK859_RAW_STDERR_FALSE'); process.stdout.write(JSON.stringify({ok:false,check_count:1,checks:[{name:'fixture',pass:true}]}));"
    }
    @{
        Name = 'child ok string true'
        Marker = 'TASK859_RAW_STDERR_STRING_TRUE'
        Body = "process.stderr.write('TASK859_RAW_STDERR_STRING_TRUE'); process.stdout.write(JSON.stringify({ok:'true',check_count:1,checks:[{name:'fixture',pass:true}]}));"
    }
)

Describe 'v0.36.26 desktop split gate' {
    BeforeAll {
        $script:behaviorCheckName = 'desktop status behavioral contract executes successfully'

        function Invoke-DesktopSplitGate {
            param(
                [Parameter(Mandatory = $true)][string]$GateScript,
                [Parameter(Mandatory = $true)][string]$WorkingDirectory,
                [switch]$RequireEvidence
            )

            $pwshCommand = Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = if ($pwshCommand.Path) { $pwshCommand.Path } else { $pwshCommand.Name }
            $startInfo.WorkingDirectory = $WorkingDirectory
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @('-NoProfile', '-File', $GateScript, '-Json')) {
                $null = $startInfo.ArgumentList.Add($argument)
            }
            if ($RequireEvidence) {
                $null = $startInfo.ArgumentList.Add('-RequireEvidence')
            }

            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            try {
                if (-not $process.Start()) {
                    throw 'Desktop split gate process did not start.'
                }
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                $process.WaitForExit()
                $stdout = $stdoutTask.GetAwaiter().GetResult()
                $stderr = $stderrTask.GetAwaiter().GetResult()
                $json = $stdout | ConvertFrom-Json -AsHashtable -ErrorAction Stop

                return [pscustomobject]@{
                    ExitCode = $process.ExitCode
                    StdOut   = $stdout
                    StdErr   = $stderr
                    Json     = $json
                }
            } finally {
                $process.Dispose()
            }
        }

        $script:repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:repoRoot)) {
            throw 'Failed to resolve repository root.'
        }
        $script:sourceStatusBefore = (& git -C $script:repoRoot status --porcelain=v1 | Out-String).TrimEnd()

        $script:fixtureRoot = Join-Path $TestDrive 'tracked-working-tree'
        $null = New-Item -ItemType Directory -Path $script:fixtureRoot
        $script:trackedPaths = @(& git -C $script:repoRoot ls-files)
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to enumerate tracked files.'
        }
        if ($script:trackedPaths.Count -eq 0) {
            throw 'Tracked file enumeration returned no paths.'
        }

        $script:sourceBytes = [int64]0
        foreach ($relativePath in $script:trackedPaths) {
            $sourcePath = Join-Path $script:repoRoot $relativePath
            $destinationPath = Join-Path $script:fixtureRoot $relativePath
            $destinationDirectory = Split-Path -Parent $destinationPath
            if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $destinationDirectory
            }
            [System.IO.File]::Copy($sourcePath, $destinationPath, $false)
            $script:sourceBytes += (Get-Item -LiteralPath $sourcePath).Length
        }

        $script:fixtureCopiedPaths = @(
            Get-ChildItem -LiteralPath $script:fixtureRoot -Recurse -File -Force |
                ForEach-Object {
                    [System.IO.Path]::GetRelativePath($script:fixtureRoot, $_.FullName).Replace('\', '/')
                }
        )
        $script:sourcePathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($relativePath in $script:trackedPaths) {
            $null = $script:sourcePathSet.Add($relativePath)
        }
        $script:fixturePathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($relativePath in $script:fixtureCopiedPaths) {
            $null = $script:fixturePathSet.Add($relativePath)
        }
        if (
            $script:fixtureCopiedPaths.Count -ne $script:trackedPaths.Count -or
            -not $script:sourcePathSet.SetEquals($script:fixturePathSet)
        ) {
            throw 'Tracked fixture path set does not match the source enumeration.'
        }

        $script:fixtureBytes = [int64]0
        foreach ($relativePath in $script:trackedPaths) {
            $script:fixtureBytes += (Get-Item -LiteralPath (Join-Path $script:fixtureRoot $relativePath)).Length
        }
        if ($script:fixtureBytes -ne $script:sourceBytes) {
            throw "Tracked fixture byte count mismatch: source=$($script:sourceBytes) fixture=$($script:fixtureBytes)."
        }

        & git -C $script:fixtureRoot init --quiet
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to initialize the tracked working-tree fixture.'
        }

        $script:gateScript = Join-Path $script:fixtureRoot 'scripts/test-v03626-desktop-split-gate.ps1'
        $script:desktopStatusCheckPath = Join-Path $script:fixtureRoot 'winsmux-app/scripts/desktop-status-e2e-check.mjs'
        $script:desktopStatusCheckBytes = [System.IO.File]::ReadAllBytes($script:desktopStatusCheckPath)
    }

    AfterEach {
        [System.IO.File]::WriteAllBytes($script:desktopStatusCheckPath, $script:desktopStatusCheckBytes)
    }

    It 'copies the complete tracked working tree into one isolated git fixture' {
        $script:trackedPaths.Count | Should -BeGreaterThan 0
        $script:fixtureCopiedPaths.Count | Should -Be $script:trackedPaths.Count
        $script:sourcePathSet.SetEquals($script:fixturePathSet) | Should -BeTrue
        $script:fixtureBytes | Should -Be $script:sourceBytes
        $fixtureGitRoot = [System.IO.Path]::GetFullPath((& git -C $script:fixtureRoot rev-parse --show-toplevel).Trim())
        $fixtureGitRoot | Should -Be ([System.IO.Path]::GetFullPath($script:fixtureRoot))
    }

    It 'passes the desktop split static wiring gate and executes the behavioral contract once' {
        $capture = Invoke-DesktopSplitGate -GateScript $script:gateScript -WorkingDirectory $script:fixtureRoot
        $capture.ExitCode | Should -Be 0
        $result = $capture.Json

        $result['gate_id'] | Should -Be 'v03626-desktop-split-gate'
        $result['evidence_mode'] | Should -Be 'static-wiring'
        $result['release_ready'] | Should -Be $false
        $result['all_pass'] | Should -Be $true
        $result['failed_count'] | Should -Be 0
        [int]$result['check_count'] | Should -BeGreaterThan 30
        $behaviorChecks = @($result['checks'] | Where-Object { $_['name'] -eq $script:behaviorCheckName })
        $behaviorChecks.Count | Should -Be 1
        $behaviorChecks[0]['pass'] | Should -Be $true
    }

    It 'publishes the required release gate input classes' {
        $capture = Invoke-DesktopSplitGate -GateScript $script:gateScript -WorkingDirectory $script:fixtureRoot
        $result = $capture.Json
        $classes = @($result['release_gate_inputs'] | ForEach-Object { $_['class'] })

        foreach ($requiredClass in @('visual', 'accessibility', 'clickable-coverage', 'desktop-e2e', 'module-budget', 'performance')) {
            $classes | Should -Contain $requiredClass
        }

        foreach ($input in @($result['release_gate_inputs'])) {
            [bool]$input['required_for_release'] | Should -Be $true
        }
    }

    It 'defines a required evidence mode for release readiness' {
        $content = Get-Content -LiteralPath $script:gateScript -Raw

        $content | Should -Match 'RequireEvidence'
        $content | Should -Match 'visual evidence file exists and reports ok'
        $content | Should -Match 'clickable coverage evidence file exists and reports ok'
        $content | Should -Match 'desktop E2E evidence file exists and reports ok'
        $content | Should -Match 'performance evidence includes measured durationMs'
        $content | Should -Match 'release_ready'
    }

    It 'keeps the npm release gate evidence-required and exposes static wiring separately' {
        $packagePath = Join-Path $script:fixtureRoot 'winsmux-app/package.json'
        $package = (Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json -AsHashtable)
        $scripts = $package['scripts']

        [string]$scripts['test:desktop-split-static'] | Should -Match 'test-v03626-desktop-split-gate\.ps1'
        [string]$scripts['test:desktop-split-static'] | Should -Not -Match '-RequireEvidence'
        [string]$scripts['test:desktop-split-gate'] | Should -Match 'test-v03626-desktop-split-gate\.ps1'
        [string]$scripts['test:desktop-split-gate'] | Should -Match '-RequireEvidence'
    }

    It 'keeps all frozen desktop split modules within their release budget' {
        $capture = Invoke-DesktopSplitGate -GateScript $script:gateScript -WorkingDirectory $script:fixtureRoot
        $result = $capture.Json

        foreach ($budget in @($result['module_budgets'])) {
            [int]$budget['physical_lines'] | Should -BeLessOrEqual ([int]$budget['limit'])
            [int]$budget['physical_lines'] | Should -BeLessOrEqual ([int]$budget['baseline'])
        }
    }

    It 'executes the behavioral contract once on the required-evidence path' {
        $capture = Invoke-DesktopSplitGate -GateScript $script:gateScript -WorkingDirectory $script:fixtureRoot -RequireEvidence
        $capture.ExitCode | Should -BeIn @(0, 1)
        $capture.Json['evidence_mode'] | Should -Be 'required'
        $behaviorChecks = @($capture.Json['checks'] | Where-Object { $_['name'] -eq $script:behaviorCheckName })
        $behaviorChecks.Count | Should -Be 1
        $behaviorChecks[0]['pass'] | Should -Be $true
    }

    It 'rejects <Name> through one parseable gate result without stderr leakage' -ForEach $negativeCases {
        [System.IO.File]::WriteAllText(
            $script:desktopStatusCheckPath,
            $Body,
            [System.Text.UTF8Encoding]::new($false)
        )

        $capture = Invoke-DesktopSplitGate -GateScript $script:gateScript -WorkingDirectory $script:fixtureRoot
        $capture.ExitCode | Should -Be 1
        $capture.Json | Should -BeOfType ([System.Collections.IDictionary])
        $behaviorChecks = @($capture.Json['checks'] | Where-Object { $_['name'] -eq $script:behaviorCheckName })
        $behaviorChecks.Count | Should -Be 1
        $behaviorChecks[0]['pass'] | Should -Be $false
        $capture.StdOut | Should -Not -Match ([regex]::Escape($Marker))
    }

    It 'leaves the candidate working tree unchanged by fixture probes' {
        $sourceStatusAfter = (& git -C $script:repoRoot status --porcelain=v1 | Out-String).TrimEnd()
        $sourceStatusAfter | Should -Be $script:sourceStatusBefore
    }
}
