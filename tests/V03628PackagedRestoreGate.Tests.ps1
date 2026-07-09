$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'v0.36.28 packaged restore gate' {
    BeforeAll {
        $script:repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:repoRoot)) {
            throw 'Failed to resolve repository root.'
        }
        $script:gateScript = Join-Path $script:repoRoot 'scripts/test-v03628-packaged-restore-gate.ps1'
        $script:currentGitHead = (& git -C $script:repoRoot rev-parse HEAD 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:currentGitHead)) {
            throw 'Failed to resolve current git head.'
        }

        function New-PackagedRestoreSnapshot {
            param([Parameter(Mandatory = $true)][string]$Phase)

            return [ordered]@{
                phase                 = $Phase
                activeProjectMatches  = $true
                projectSessionRecorded = $true
                runtimeAssignmentMode = 'per-pane'
                shellLayout           = 'focus'
                shellFocusedPaneId    = 'worker-2'
                drawerLayout          = 'focus'
                drawerFocusedPaneId   = 'worker-2'
                paneCount             = 6
                visiblePaneIds        = @('worker-2')
                workerAssignments     = @(
                    [ordered]@{
                        slotId          = 'worker-1'
                        provider        = 'codex'
                        model           = 'gpt-5.4'
                        modelSource     = 'operator-override'
                        reasoningEffort = 'high'
                    },
                    [ordered]@{
                        slotId          = 'worker-2'
                        provider        = 'grok-build'
                        model           = 'grok-4.5'
                        modelSource     = 'operator-override'
                        reasoningEffort = 'high'
                    }
                )
                restoreCandidateCount = 1
                restoreCandidateTransport = 'desktop.session.restore_candidates'
                restoreCandidate      = [ordered]@{
                    candidateVersion     = 1
                    source               = 'desktop.session.restore_candidates'
                    session              = 'ops__packaged_restore_e2e'
                    registryDir          = '.psmux'
                    paneLayout           = [ordered]@{
                        layout          = 'focus'
                        focused_pane_id = 'worker-2'
                        pane_order      = @('worker-1', 'worker-2')
                    }
                    assignmentTargets    = @('codex:gpt-5.4', 'grok-build:grok-4.5')
                    contextCapsuleRef    = 'capsule:desktop-packaged-restore-e2e'
                    checkpointRef        = 'checkpoint:desktop-packaged-restore-e2e'
                    transcriptRingSummary = [ordered]@{
                        state                 = 'captured'
                        byte_count            = 128
                        sha256                = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
                        raw_transcript_stored = $false
                    }
                    privacy             = [ordered]@{
                        raw_transcript_stored        = $false
                        local_reference_paths_stored = $false
                    }
                    restoreState         = 'candidate'
                }
            }
        }

        function New-PackagedRestoreEvidence {
            param(
                [Parameter(Mandatory = $false)]$Ok = $true,
                [Parameter(Mandatory = $false)][scriptblock]$Mutate
            )

            $evidence = [ordered]@{
                ok              = $Ok
                timestamp       = '2026-07-09T00:00:00.000Z'
                source          = [ordered]@{
                    git_head         = $script:currentGitHead
                    command          = 'npm --prefix winsmux-app run test:desktop-packaged-restore-e2e'
                    generated_at_utc = '2026-07-09T00:00:00.000Z'
                }
                mode            = 'packaged-restore-only'
                tauriOutputTail = '<omitted-for-packaged-restore-privacy>'
                tauriErrorTail  = '<omitted-for-packaged-restore-privacy>'
                packagedRestore = [ordered]@{
                    debugPorts      = @(49152, 49153)
                    webviewUserData = '<isolated-webview2-user-data>'
                    projectDir      = '<packaged-restore-e2e-project>'
                    preRestart     = New-PackagedRestoreSnapshot -Phase 'pre-restart'
                    postRestart    = New-PackagedRestoreSnapshot -Phase 'post-restart'
                    privacy         = [ordered]@{
                        evidence_redacts_local_paths = $true
                        raw_transcript_stored        = $false
                        local_reference_paths_stored = $false
                    }
                }
            }

            if ($Mutate) {
                & $Mutate $evidence
            }

            return $evidence
        }

        function Write-TestEvidence {
            param(
                [Parameter(Mandatory = $true)][string]$RelativePath,
                [Parameter(Mandatory = $true)]$Evidence
            )

            $path = Join-Path $script:repoRoot $RelativePath
            $dir = Split-Path -Parent $path
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $Evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding UTF8
        }
    }

    It 'passes the static wiring gate' {
        $output = & pwsh -NoProfile -File $script:gateScript -Json
        $LASTEXITCODE | Should -Be 0
        $result = ($output | Out-String | ConvertFrom-Json)

        $result.gate_id | Should -Be 'v03628-packaged-restore-gate'
        $result.evidence_mode | Should -Be 'static-wiring'
        $result.release_ready | Should -Be $false
        $result.release_gate_inputs_complete | Should -Be $false
        $result.all_pass | Should -Be $true
        $result.failed_count | Should -Be 0
        [int]$result.check_count | Should -BeGreaterThan 9
        @($result.required_evidence_classes) | Should -Contain 'packaged-restore-e2e'
        @($result.required_evidence_classes) | Should -Contain 'restart-state'
        @($result.required_evidence_classes) | Should -Contain 'model-assignment'
        @($result.required_evidence_classes) | Should -Contain 'privacy'
    }

    It 'requires packaged restore evidence before marking release-ready' {
        $evidenceRelative = ".winsmux/evidence/v03628-packaged-restore-test-$([guid]::NewGuid().ToString('N'))/desktop-pane-e2e.json"
        $evidencePath = Join-Path $script:repoRoot $evidenceRelative
        $evidenceDir = Split-Path -Parent $evidencePath

        try {
            $missingOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $missingResult = ($missingOutput | Out-String | ConvertFrom-Json)
            $missingResult.release_ready | Should -Be $false
            @($missingResult.checks | Where-Object { $_.name -eq 'packaged restore evidence file exists and is valid JSON' }).pass | Should -Contain $false

            Write-TestEvidence -RelativePath $evidenceRelative -Evidence (New-PackagedRestoreEvidence -Mutate {
                param($evidence)
                $evidence.packagedRestore.preRestart.restoreCandidate.transcriptRingSummary.raw_transcript_stored = $true
            })

            $rawTranscriptOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $rawTranscriptResult = ($rawTranscriptOutput | Out-String | ConvertFrom-Json)
            $rawTranscriptResult.release_ready | Should -Be $false
            @($rawTranscriptResult.checks | Where-Object { $_.name -eq 'pre-restart restore candidate does not store raw transcript' }).pass | Should -Contain $false

            Write-TestEvidence -RelativePath $evidenceRelative -Evidence (New-PackagedRestoreEvidence -Mutate {
                param($evidence)
                $evidence.packagedRestore.postRestart.workerAssignments[1].model = 'provider-default'
            })

            $modelOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $modelResult = ($modelOutput | Out-String | ConvertFrom-Json)
            $modelResult.release_ready | Should -Be $false
            @($modelResult.checks | Where-Object { $_.name -eq 'post-restart snapshot keeps worker-2 Grok model assignment' }).pass | Should -Contain $false

            Write-TestEvidence -RelativePath $evidenceRelative -Evidence (New-PackagedRestoreEvidence -Mutate {
                param($evidence)
                $evidence.source.git_head = '0000000000000000000000000000000000000000'
            })

            $staleHeadOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $staleHeadResult = ($staleHeadOutput | Out-String | ConvertFrom-Json)
            $staleHeadResult.release_ready | Should -Be $false
            @($staleHeadResult.checks | Where-Object { $_.name -eq 'packaged restore evidence was generated from the current git head' }).pass | Should -Contain $false

            Write-TestEvidence -RelativePath $evidenceRelative -Evidence (New-PackagedRestoreEvidence)

            $successOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 0
            $successResult = ($successOutput | Out-String | ConvertFrom-Json)
            $successResult.release_ready | Should -Be $true
            $successResult.release_gate_inputs_complete | Should -Be $true
            $successResult.all_pass | Should -Be $true
            $successResult.failed_count | Should -Be 0
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

        [string]$package.scripts.'test:desktop-packaged-restore-e2e' | Should -Match 'desktop-pane-e2e\.mjs --packaged-restore-only'
        [string]$package.scripts.'test:v03628-packaged-restore-static' | Should -Match 'test-v03628-packaged-restore-gate\.ps1'
        [string]$package.scripts.'test:v03628-packaged-restore-static' | Should -Not -Match '-RequireEvidence'
        [string]$package.scripts.'test:v03628-packaged-restore-gate' | Should -Match 'test-v03628-packaged-restore-gate\.ps1'
        [string]$package.scripts.'test:v03628-packaged-restore-gate' | Should -Match '-RequireEvidence'
        $gitignore | Should -Match ([regex]::Escape('!tests/V03628PackagedRestoreGate.Tests.ps1'))
        $whitelist | Should -Match ([regex]::Escape('scripts/test-v03628-packaged-restore-gate.ps1'))
        $whitelist | Should -Match ([regex]::Escape('tests/V03628PackagedRestoreGate.Tests.ps1'))
        $workflow | Should -Match 'packaged-restore-v03628'
        $workflow | Should -Match 'tests/V03628PackagedRestoreGate\.Tests\.ps1'
    }
}
