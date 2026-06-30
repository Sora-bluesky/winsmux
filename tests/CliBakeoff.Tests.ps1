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
        $buildStopIndex = $scriptText.IndexOf('Stop-RepoWinsmuxDesktopTree', $buildBlockIndex)
        $cargoBuildIndex = $scriptText.IndexOf("Invoke-CheckedCommand -FilePath 'cargo'", $buildBlockIndex)
        $tauriBuildIndex = $scriptText.IndexOf("Invoke-CheckedCommand -FilePath 'npm'", $buildBlockIndex)

        ($buildBlockIndex -ge 0) | Should -BeTrue
        ($cargoBuildIndex -ge 0) | Should -BeTrue
        ($tauriBuildIndex -ge 0) | Should -BeTrue
        ($buildStopIndex -gt $buildBlockIndex) | Should -BeTrue
        ($buildStopIndex -lt $cargoBuildIndex) | Should -BeTrue
        ($buildStopIndex -lt $tauriBuildIndex) | Should -BeTrue
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

    It 'rejects the Tauri dev server URL during packaged desktop E2E' {
        $scriptText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'winsmux-app\scripts\desktop-pane-e2e.mjs') -Raw -Encoding UTF8
        $scriptText | Should -Match 'allowDevServer'
        $scriptText | Should -Match 'Packaged desktop resolved to the Tauri dev server URL'
        $scriptText | Should -Match 'allowDevServer: !RELEASE_POPOUT_ONLY'
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
