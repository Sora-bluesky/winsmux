$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'v0.36.28 runtime reliability gate' {
    BeforeAll {
        $script:repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:repoRoot)) {
            throw 'Failed to resolve repository root.'
        }
        $script:gateScript = Join-Path $script:repoRoot 'scripts/test-v03628-runtime-reliability-gate.ps1'
        $script:currentHead = (& git -C $script:repoRoot rev-parse HEAD 2>$null | Out-String).Trim()

        function New-RuntimeReliabilityEvidence {
            param(
                [Parameter(Mandatory = $false)]$Ok = $true,
                [bool]$DiagnosticOverride = $false,
                [string[]]$DiagnosticOverrides = @(),
                [int]$ExpectedEvents = 100,
                [int]$ReceivedEvents = 100,
                [int]$LostEvents = 0,
                [double]$CpuPeakPercent = 12.5,
                [double]$CpuBudgetPercent = 80,
                [int]$CpuSampleCount = 4,
                [int]$CpuSampleDurationMs = 1000,
                [double]$MemoryPeakMb = 256,
                [double]$MemoryBudgetMb = 1024,
                [int]$MemorySampleCount = 4,
                [int]$MemorySampleDurationMs = 1000,
                [string]$DependencyHead = $script:currentHead
            )

            $envObservation = [ordered]@{
                WINSMUX_RUNTIME_GATE_OVERRIDE = $null
                WINSMUX_DIAGNOSTIC_OVERRIDE   = $null
            }
            $cliArgs = @()
            if ($DiagnosticOverride) {
                $envObservation.WINSMUX_RUNTIME_GATE_OVERRIDE = '1'
                $cliArgs = @('--diagnostic-override')
            }

            return [ordered]@{
                ok                               = $Ok
                source                           = [ordered]@{
                    git_head         = $script:currentHead
                    command          = 'pwsh -NoProfile -File scripts/test-v03628-runtime-reliability-gate.ps1 -Json -RequireEvidence'
                    generated_at_utc = '2026-07-09T00:00:00Z'
                }
                classes                          = @(
                    'cpu',
                    'memory',
                    'event-loss',
                    'compatibility-report',
                    'no-diagnostic-override'
                )
                diagnostic_override              = $DiagnosticOverride
                diagnostic_overrides             = @($DiagnosticOverrides)
                diagnostic_override_observations = [ordered]@{
                    env      = $envObservation
                    cli_args = @($cliArgs)
                }
                metrics                          = [ordered]@{
                    cpu        = [ordered]@{
                        peak_percent       = $CpuPeakPercent
                        budget_peak_percent = $CpuBudgetPercent
                        sample_count       = $CpuSampleCount
                        sample_duration_ms = $CpuSampleDurationMs
                        within_budget      = ($CpuPeakPercent -le $CpuBudgetPercent)
                        target             = [ordered]@{
                            kind       = 'desktop-app'
                            process_id = 1234
                            executable = 'winsmux-app.exe'
                        }
                    }
                    memory     = [ordered]@{
                        peak_mb            = $MemoryPeakMb
                        budget_peak_mb     = $MemoryBudgetMb
                        sample_count       = $MemorySampleCount
                        sample_duration_ms = $MemorySampleDurationMs
                        within_budget      = ($MemoryPeakMb -le $MemoryBudgetMb)
                        target             = [ordered]@{
                            kind       = 'desktop-app'
                            process_id = 1234
                            executable = 'winsmux-app.exe'
                        }
                    }
                    event_loss = [ordered]@{
                        scenario        = 'pty-output-batch-runtime-reliability'
                        source          = 'pty-output'
                        duration_ms     = 1000
                        expected_events = $ExpectedEvents
                        received_events = $ReceivedEvents
                        lost_events     = $LostEvents
                    }
                }
                compatibility_report             = [ordered]@{
                    ok                            = $true
                    generated_at_utc              = '2026-07-09T00:00:00Z'
                    compat_performance_gate       = [ordered]@{
                        gate_id                     = 'v03627-compat-performance-gate'
                        release_ready               = $true
                        all_pass                    = $true
                        failed_count                = 0
                        release_gate_inputs_complete = $true
                        missing_release_gate_inputs = @()
                        command                     = 'pwsh -NoProfile -File scripts/test-v03627-compat-performance-gate.ps1 -Json -RequireEvidence'
                        evidence_path               = '<repo-root>/.winsmux/evidence/v03627-compat-performance/compat-performance.json'
                        head_sha                    = $DependencyHead
                    }
                    race_abnormal_soak_gate       = [ordered]@{
                        gate_id       = 'v03628-race-abnormal-soak'
                        release_ready = $true
                        all_pass      = $true
                        failed_count  = 0
                        command       = 'pwsh -NoProfile -File scripts/test-v03628-race-abnormal-soak.ps1 -Json -RequireEvidence'
                        evidence_path = '<repo-root>/.winsmux/evidence/v03628-race-abnormal-soak/soak-summary.json'
                        head_sha      = $DependencyHead
                    }
                }
            }
        }

        function Write-RuntimeReliabilityEvidence {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)]$Evidence
            )

            $Evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
        }
    }

    It 'passes the static wiring gate under PowerShell 7' {
        $output = & pwsh -NoProfile -File $script:gateScript -Json
        $LASTEXITCODE | Should -Be 0
        $result = ($output | Out-String | ConvertFrom-Json)

        $result.gate_id | Should -Be 'v03628-runtime-reliability-gate'
        $result.evidence_mode | Should -Be 'static-wiring'
        $result.release_ready | Should -Be $false
        $result.release_gate_inputs_complete | Should -Be $false
        $result.all_pass | Should -Be $true
        $result.failed_count | Should -Be 0
        [int]$result.check_count | Should -BeGreaterThan 5
        @($result.required_evidence_classes) | Should -Contain 'cpu'
        @($result.required_evidence_classes) | Should -Contain 'memory'
        @($result.required_evidence_classes) | Should -Contain 'event-loss'
        @($result.required_evidence_classes) | Should -Contain 'compatibility-report'
        @($result.required_evidence_classes) | Should -Contain 'no-diagnostic-override'
    }

    It 'passes the static wiring gate under Windows PowerShell when available' {
        $windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $windowsPowerShell) {
            $true | Should -Be $true
            return
        }

        $output = & $windowsPowerShell.Path -NoProfile -ExecutionPolicy Bypass -File $script:gateScript -Json
        $LASTEXITCODE | Should -Be 0
        $result = ($output | Out-String | ConvertFrom-Json)

        $result.gate_id | Should -Be 'v03628-runtime-reliability-gate'
        $result.all_pass | Should -Be $true
        $result.failed_count | Should -Be 0
    }

    It 'requires complete typed runtime evidence before marking release-ready' {
        $evidenceRelative = ".winsmux/evidence/v03628-runtime-reliability-test-$([guid]::NewGuid().ToString('N'))/runtime-reliability-report.json"
        $evidencePath = Join-Path $script:repoRoot $evidenceRelative
        $evidenceDir = Split-Path -Parent $evidencePath

        try {
            $missingOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $missingResult = ($missingOutput | Out-String | ConvertFrom-Json)
            $missingResult.release_ready | Should -Be $false
            @($missingResult.checks | Where-Object { $_.name -eq 'runtime reliability evidence file exists' }).pass | Should -Contain $false

            New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence (New-RuntimeReliabilityEvidence -Ok 'true')

            $stringOkOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $stringOkResult = ($stringOkOutput | Out-String | ConvertFrom-Json)
            $stringOkResult.release_ready | Should -Be $false
            @($stringOkResult.checks | Where-Object { $_.name -eq 'runtime reliability evidence reports boolean ok true' }).pass | Should -Contain $false

            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence (
                New-RuntimeReliabilityEvidence -DiagnosticOverride $true -DiagnosticOverrides @('WINSMUX_RUNTIME_GATE_OVERRIDE')
            )

            $overrideOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $overrideResult = ($overrideOutput | Out-String | ConvertFrom-Json)
            $overrideResult.release_ready | Should -Be $false
            @($overrideResult.checks | Where-Object { $_.name -eq 'runtime reliability evidence uses no diagnostic override' }).pass | Should -Contain $false

            $missingObservation = New-RuntimeReliabilityEvidence
            [void]$missingObservation.diagnostic_override_observations.Remove('env')
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $missingObservation

            $missingObservationOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $missingObservationResult = ($missingObservationOutput | Out-String | ConvertFrom-Json)
            $missingObservationResult.release_ready | Should -Be $false
            @($missingObservationResult.checks | Where-Object { $_.name -eq 'runtime reliability evidence uses no diagnostic override' }).pass | Should -Contain $false

            $missingRuntimeOverrideObservation = New-RuntimeReliabilityEvidence
            [void]$missingRuntimeOverrideObservation.diagnostic_override_observations.env.Remove('WINSMUX_RUNTIME_GATE_OVERRIDE')
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $missingRuntimeOverrideObservation

            $missingRuntimeOverrideOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $missingRuntimeOverrideResult = ($missingRuntimeOverrideOutput | Out-String | ConvertFrom-Json)
            $missingRuntimeOverrideResult.release_ready | Should -Be $false
            @($missingRuntimeOverrideResult.checks | Where-Object { $_.name -eq 'runtime reliability evidence uses no diagnostic override' }).pass | Should -Contain $false

            $arraySourceGitHead = New-RuntimeReliabilityEvidence
            $arraySourceGitHead.source.git_head = @($script:currentHead)
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $arraySourceGitHead

            $arraySourceGitHeadOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $arraySourceGitHeadResult = ($arraySourceGitHeadOutput | Out-String | ConvertFrom-Json)
            $arraySourceGitHeadResult.release_ready | Should -Be $false
            @($arraySourceGitHeadResult.checks | Where-Object { $_.name -eq 'runtime reliability evidence matches current git head' }).pass | Should -Contain $false

            $nonStringSourceCommand = New-RuntimeReliabilityEvidence
            $nonStringSourceCommand.source.command = 123
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $nonStringSourceCommand

            $nonStringSourceCommandOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $nonStringSourceCommandResult = ($nonStringSourceCommandOutput | Out-String | ConvertFrom-Json)
            $nonStringSourceCommandResult.release_ready | Should -Be $false
            @($nonStringSourceCommandResult.checks | Where-Object { $_.name -eq 'runtime reliability evidence records generation command' }).pass | Should -Contain $false

            $nonStringGeneratedAt = New-RuntimeReliabilityEvidence
            $nonStringGeneratedAt.source.generated_at_utc = 123
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $nonStringGeneratedAt

            $nonStringGeneratedAtOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $nonStringGeneratedAtResult = ($nonStringGeneratedAtOutput | Out-String | ConvertFrom-Json)
            $nonStringGeneratedAtResult.release_ready | Should -Be $false
            @($nonStringGeneratedAtResult.checks | Where-Object { $_.name -eq 'runtime reliability evidence records generation timestamp' }).pass | Should -Contain $false

            $nonStringExecutable = New-RuntimeReliabilityEvidence
            $nonStringExecutable.metrics.cpu.target.executable = [ordered]@{
                path = 'winsmux-app.exe'
            }
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $nonStringExecutable

            $nonStringExecutableOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $nonStringExecutableResult = ($nonStringExecutableOutput | Out-String | ConvertFrom-Json)
            $nonStringExecutableResult.release_ready | Should -Be $false
            @($nonStringExecutableResult.checks | Where-Object { $_.name -eq 'CPU evidence has target samples and is within budget' }).pass | Should -Contain $false

            $arrayTargetKind = New-RuntimeReliabilityEvidence
            $arrayTargetKind.metrics.cpu.target.kind = @('desktop-app')
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $arrayTargetKind

            $arrayTargetKindOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $arrayTargetKindResult = ($arrayTargetKindOutput | Out-String | ConvertFrom-Json)
            $arrayTargetKindResult.release_ready | Should -Be $false
            @($arrayTargetKindResult.checks | Where-Object { $_.name -eq 'CPU evidence has target samples and is within budget' }).pass | Should -Contain $false

            $nonStringEventScenario = New-RuntimeReliabilityEvidence
            $nonStringEventScenario.metrics.event_loss.scenario = [ordered]@{
                name = 'pty-output-batch-runtime-reliability'
            }
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $nonStringEventScenario

            $nonStringEventScenarioOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $nonStringEventScenarioResult = ($nonStringEventScenarioOutput | Out-String | ConvertFrom-Json)
            $nonStringEventScenarioResult.release_ready | Should -Be $false
            @($nonStringEventScenarioResult.checks | Where-Object { $_.name -eq 'event-loss evidence records zero dropped PTY events' }).pass | Should -Contain $false

            $arrayEventSource = New-RuntimeReliabilityEvidence
            $arrayEventSource.metrics.event_loss.source = @('pty-output')
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $arrayEventSource

            $arrayEventSourceOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $arrayEventSourceResult = ($arrayEventSourceOutput | Out-String | ConvertFrom-Json)
            $arrayEventSourceResult.release_ready | Should -Be $false
            @($arrayEventSourceResult.checks | Where-Object { $_.name -eq 'event-loss evidence records zero dropped PTY events' }).pass | Should -Contain $false

            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence (
                New-RuntimeReliabilityEvidence -ExpectedEvents 100 -ReceivedEvents 99 -LostEvents 1
            )

            $eventLossOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $eventLossResult = ($eventLossOutput | Out-String | ConvertFrom-Json)
            $eventLossResult.release_ready | Should -Be $false
            @($eventLossResult.checks | Where-Object { $_.name -eq 'event-loss evidence records zero dropped PTY events' }).pass | Should -Contain $false

            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence (
                New-RuntimeReliabilityEvidence -CpuPeakPercent 90 -CpuBudgetPercent 80
            )

            $cpuBudgetOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $cpuBudgetResult = ($cpuBudgetOutput | Out-String | ConvertFrom-Json)
            $cpuBudgetResult.release_ready | Should -Be $false
            @($cpuBudgetResult.checks | Where-Object { $_.name -eq 'CPU evidence has target samples and is within budget' }).pass | Should -Contain $false

            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence (
                New-RuntimeReliabilityEvidence -DependencyHead '0000000000000000000000000000000000000000'
            )

            $staleDependencyOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $staleDependencyResult = ($staleDependencyOutput | Out-String | ConvertFrom-Json)
            $staleDependencyResult.release_ready | Should -Be $false
            @($staleDependencyResult.checks | Where-Object { $_.name -eq 'compatibility report includes release-ready dependency gates' }).pass | Should -Contain $false

            $staleHeadWithCurrentSource = New-RuntimeReliabilityEvidence -DependencyHead '0000000000000000000000000000000000000000'
            $staleHeadWithCurrentSource.compatibility_report.compat_performance_gate.source = [ordered]@{
                git_head = $script:currentHead
            }
            $staleHeadWithCurrentSource.compatibility_report.race_abnormal_soak_gate.source = [ordered]@{
                git_head = $script:currentHead
            }
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $staleHeadWithCurrentSource

            $staleHeadWithCurrentSourceOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $staleHeadWithCurrentSourceResult = ($staleHeadWithCurrentSourceOutput | Out-String | ConvertFrom-Json)
            $staleHeadWithCurrentSourceResult.release_ready | Should -Be $false
            @($staleHeadWithCurrentSourceResult.checks | Where-Object { $_.name -eq 'compatibility report includes release-ready dependency gates' }).pass | Should -Contain $false

            $currentHeadWithStaleSource = New-RuntimeReliabilityEvidence
            $currentHeadWithStaleSource.compatibility_report.compat_performance_gate.source = [ordered]@{
                git_head = '0000000000000000000000000000000000000000'
            }
            $currentHeadWithStaleSource.compatibility_report.race_abnormal_soak_gate.source = [ordered]@{
                git_head = '0000000000000000000000000000000000000000'
            }
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $currentHeadWithStaleSource

            $currentHeadWithStaleSourceOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $currentHeadWithStaleSourceResult = ($currentHeadWithStaleSourceOutput | Out-String | ConvertFrom-Json)
            $currentHeadWithStaleSourceResult.release_ready | Should -Be $false
            @($currentHeadWithStaleSourceResult.checks | Where-Object { $_.name -eq 'compatibility report includes release-ready dependency gates' }).pass | Should -Contain $false

            $directDependencyOutputs = New-RuntimeReliabilityEvidence
            $directDependencyOutputs.compatibility_report.compat_performance_gate = [ordered]@{
                gate_id                     = 'v03627-compat-performance-gate'
                evidence_mode               = 'required-evidence'
                source                      = [ordered]@{
                    git_head = $script:currentHead
                }
                release_ready               = $true
                release_gate_inputs_complete = $true
                missing_release_gate_inputs = @()
                all_pass                    = $true
                failed_count                = 0
                check_count                 = 12
                release_gate_inputs         = @()
                checks                      = @()
            }
            $directDependencyOutputs.compatibility_report.race_abnormal_soak_gate = [ordered]@{
                gate_id                   = 'v03628-race-abnormal-soak'
                evidence_mode             = 'required-evidence'
                source                    = [ordered]@{
                    git_head = $script:currentHead
                }
                all_pass                  = $true
                release_ready             = $true
                failed_count              = 0
                check_count               = 6
                required_evidence_classes = @('startup-cleanup-concurrency', 'hundred-run-soak', 'long-running')
                evidence_path             = '<repo-root>/.winsmux/evidence/v03628-race-abnormal-soak/soak-summary.json'
                checks                    = @()
            }
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $directDependencyOutputs

            $directDependencyOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 0
            $directDependencyResult = ($directDependencyOutput | Out-String | ConvertFrom-Json)
            $directDependencyResult.release_ready | Should -Be $true
            @($directDependencyResult.checks | Where-Object { $_.name -eq 'compatibility report includes release-ready dependency gates' }).pass | Should -Contain $true

            $unboundDependencyOutputs = New-RuntimeReliabilityEvidence
            $unboundDependencyOutputs.compatibility_report.compat_performance_gate = [ordered]@{
                gate_id                     = 'v03627-compat-performance-gate'
                evidence_mode               = 'required-evidence'
                release_ready               = $true
                release_gate_inputs_complete = $true
                missing_release_gate_inputs = @()
                all_pass                    = $true
                failed_count                = 0
                check_count                 = 12
                release_gate_inputs         = @()
                checks                      = @()
            }
            $unboundDependencyOutputs.compatibility_report.race_abnormal_soak_gate = [ordered]@{
                gate_id                   = 'v03628-race-abnormal-soak'
                evidence_mode             = 'required-evidence'
                all_pass                  = $true
                release_ready             = $true
                failed_count              = 0
                check_count               = 6
                required_evidence_classes = @('startup-cleanup-concurrency', 'hundred-run-soak', 'long-running')
                evidence_path             = '<repo-root>/.winsmux/evidence/v03628-race-abnormal-soak/soak-summary.json'
                checks                    = @()
            }
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $unboundDependencyOutputs

            $unboundDependencyOutputText = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $unboundDependencyResult = ($unboundDependencyOutputText | Out-String | ConvertFrom-Json)
            $unboundDependencyResult.release_ready | Should -Be $false
            @($unboundDependencyResult.checks | Where-Object { $_.name -eq 'compatibility report includes release-ready dependency gates' }).pass | Should -Contain $false

            $incompleteDependencyOutput = New-RuntimeReliabilityEvidence
            [void]$incompleteDependencyOutput.compatibility_report.compat_performance_gate.Remove('all_pass')
            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence $incompleteDependencyOutput

            $incompleteDependencyOutputText = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $incompleteDependencyResult = ($incompleteDependencyOutputText | Out-String | ConvertFrom-Json)
            $incompleteDependencyResult.release_ready | Should -Be $false
            @($incompleteDependencyResult.checks | Where-Object { $_.name -eq 'compatibility report includes release-ready dependency gates' }).pass | Should -Contain $false

            Write-RuntimeReliabilityEvidence -Path $evidencePath -Evidence (New-RuntimeReliabilityEvidence)

            $successOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 0
            $successResult = ($successOutput | Out-String | ConvertFrom-Json)
            $successResult.all_pass | Should -Be $true
            $successResult.release_ready | Should -Be $true
            $successResult.release_gate_inputs_complete | Should -Be $true
            @($successResult.missing_release_gate_inputs).Count | Should -Be 0
        } finally {
            if (Test-Path -LiteralPath $evidenceDir) {
                Remove-Item -LiteralPath $evidenceDir -Recurse -Force
            }
        }
    }

    It 'is wired into npm scripts, public-surface allowlists, and CI' {
        $package = Get-Content -LiteralPath (Join-Path $script:repoRoot 'winsmux-app/package.json') -Raw | ConvertFrom-Json
        $gitignore = Get-Content -LiteralPath (Join-Path $script:repoRoot '.gitignore') -Raw
        $whitelist = Get-Content -LiteralPath (Join-Path $script:repoRoot '.githooks/pre-commit-whitelist.ps1') -Raw
        $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github/workflows/test.yml') -Raw

        [string]$package.scripts.'test:v03628-runtime-reliability-static' | Should -Match 'test-v03628-runtime-reliability-gate\.ps1'
        [string]$package.scripts.'test:v03628-runtime-reliability-static' | Should -Not -Match '-RequireEvidence'
        [string]$package.scripts.'test:v03628-runtime-reliability-gate' | Should -Match 'test-v03628-runtime-reliability-gate\.ps1'
        [string]$package.scripts.'test:v03628-runtime-reliability-gate' | Should -Match '-RequireEvidence'
        $gitignore | Should -Match ([regex]::Escape('!tests/V03628RuntimeReliabilityGate.Tests.ps1'))
        $whitelist | Should -Match ([regex]::Escape('scripts/test-v03628-runtime-reliability-gate.ps1'))
        $whitelist | Should -Match ([regex]::Escape('tests/V03628RuntimeReliabilityGate.Tests.ps1'))
        $workflow | Should -Match 'runtime-reliability-v03628'
        $workflow | Should -Match 'tests/V03628RuntimeReliabilityGate\.Tests\.ps1'
    }
}
