$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'v0.36.27 compat performance gate' {
    BeforeAll {
        $script:repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:repoRoot)) {
            throw 'Failed to resolve repository root.'
        }
        $script:gateScript = Join-Path $script:repoRoot 'scripts/test-v03627-compat-performance-gate.ps1'
    }

    It 'passes the static wiring gate under PowerShell 7' {
        $output = & pwsh -NoProfile -File $script:gateScript -Json
        $LASTEXITCODE | Should -Be 0
        $result = ($output | Out-String | ConvertFrom-Json)

        $result.gate_id | Should -Be 'v03627-compat-performance-gate'
        $result.evidence_mode | Should -Be 'static-wiring'
        $result.release_ready | Should -Be $false
        $result.all_pass | Should -Be $true
        $result.failed_count | Should -Be 0
        [int]$result.check_count | Should -BeGreaterThan 25
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

        $result.gate_id | Should -Be 'v03627-compat-performance-gate'
        $result.all_pass | Should -Be $true
        $result.failed_count | Should -Be 0
    }

    It 'publishes the required release gate input classes' {
        $output = & pwsh -NoProfile -File $script:gateScript -Json
        $result = ($output | Out-String | ConvertFrom-Json)
        $classes = @($result.release_gate_inputs | ForEach-Object { $_.class })

        foreach ($requiredClass in @('old-cli-fixture', 'powershell-5', 'powershell-7', 'latency', 'process-benchmark', 'worker-benchmark')) {
            $classes | Should -Contain $requiredClass
        }

        foreach ($input in @($result.release_gate_inputs)) {
            [bool]$input.required_for_release | Should -Be $true
        }
    }

    It 'keeps the npm release gate evidence-required and exposes static wiring separately' {
        $packagePath = Join-Path $script:repoRoot 'winsmux-app/package.json'
        $package = (Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json)
        $scripts = $package.scripts

        [string]$scripts.'test:v03627-compat-performance-static' | Should -Match 'test-v03627-compat-performance-gate\.ps1'
        [string]$scripts.'test:v03627-compat-performance-static' | Should -Not -Match '-RequireEvidence'
        [string]$scripts.'test:v03627-compat-performance-gate' | Should -Match 'test-v03627-compat-performance-gate\.ps1'
        [string]$scripts.'test:v03627-compat-performance-gate' | Should -Match '-RequireEvidence'
    }

    It 'defines required evidence mode for release readiness' {
        $content = Get-Content -LiteralPath $script:gateScript -Raw

        $content | Should -Match 'RequireEvidence'
        $content | Should -Match 'latency evidence reports ok true'
        $content | Should -Match 'latency evidence includes measured durationMs'
        $content | Should -Match 'release_ready'
        $content | Should -Match 'release_gate_inputs_complete'
        $content | Should -Match 'missing_release_gate_inputs'
        $content | Should -Match 'powershell-5'
        $content | Should -Match 'process-benchmark'
    }

    It 'does not mark failed desktop evidence as release ready and passes the advertised gate with complete evidence' {
        $evidencePath = Join-Path $script:repoRoot 'winsmux-app/output/playwright/desktop-pane-e2e/desktop-pane-e2e.json'
        $evidenceDir = Split-Path -Parent $evidencePath
        $hadOriginal = Test-Path -LiteralPath $evidencePath -PathType Leaf
        $originalEvidence = if ($hadOriginal) { Get-Content -LiteralPath $evidencePath -Raw } else { $null }
        $realPwsh = (Get-Command pwsh -ErrorAction Stop).Source
        $fakeBin = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-v03627-gate-{0}" -f ([guid]::NewGuid().ToString('N')))
        $commandLog = Join-Path $fakeBin 'commands.log'
        $originalPath = $env:PATH
        $originalFakeLog = $env:WINSMUX_FAKE_COMMAND_LOG

        try {
            New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
            New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
            $env:WINSMUX_FAKE_COMMAND_LOG = $commandLog
            $env:PATH = "$fakeBin;$originalPath"

            Set-Content -LiteralPath (Join-Path $fakeBin 'npm.cmd') -Encoding ASCII -Value @'
@echo off
echo npm %*>>"%WINSMUX_FAKE_COMMAND_LOG%"
exit /b 0
'@
            Set-Content -LiteralPath (Join-Path $fakeBin 'cargo.cmd') -Encoding ASCII -Value @'
@echo off
echo cargo %*>>"%WINSMUX_FAKE_COMMAND_LOG%"
exit /b 0
'@
            Set-Content -LiteralPath (Join-Path $fakeBin 'pwsh.cmd') -Encoding ASCII -Value @'
@echo off
echo pwsh %*>>"%WINSMUX_FAKE_COMMAND_LOG%"
echo {"all_pass":true}
exit /b 0
'@

            Set-Content -LiteralPath $evidencePath -Encoding UTF8 -Value @'
{
  "ok": false,
  "steps": [
    {
      "name": "failed step with timing",
      "ok": false,
      "durationMs": 42
    }
  ]
}
'@

            $failedOutput = & $realPwsh -NoProfile -File $script:gateScript -Json -RequireEvidence
            $LASTEXITCODE | Should -Be 1
            $failedResult = ($failedOutput | Out-String | ConvertFrom-Json)
            $failedResult.all_pass | Should -Be $false
            $failedResult.release_ready | Should -Be $false
            @($failedResult.checks | Where-Object { $_.name -eq 'latency evidence reports ok true' }).pass | Should -Contain $false

            Set-Content -LiteralPath $evidencePath -Encoding UTF8 -Value @'
{
  "ok": true,
  "steps": [
    {
      "name": "successful step with timing",
      "ok": true,
      "durationMs": 42
    }
  ]
}
'@

            $successOutput = & $realPwsh -NoProfile -File $script:gateScript -Json -RequireEvidence
            $LASTEXITCODE | Should -Be 0
            $successResult = ($successOutput | Out-String | ConvertFrom-Json)
            $successResult.all_pass | Should -Be $true
            $successResult.release_ready | Should -Be $true
            $successResult.release_gate_inputs_complete | Should -Be $true
            @($successResult.missing_release_gate_inputs).Count | Should -Be 0
            @($successResult.release_command_results | Where-Object { $_.class -eq 'old-cli-fixture' -and -not $_.passed }).Count | Should -Be 0
            @($successResult.release_command_results | Where-Object { $_.class -eq 'process-benchmark' -and -not $_.passed }).Count | Should -Be 0
            @($successResult.release_command_results | Where-Object { $_.class -eq 'worker-benchmark' -and -not $_.passed }).Count | Should -Be 0

            $log = Get-Content -LiteralPath $commandLog -Raw
            $log | Should -Match 'npm --prefix winsmux-app run test:common-contract-package'
            $log | Should -Match 'cargo test --manifest-path core/Cargo.toml --test common_contract'
            $log | Should -Match 'cargo test --manifest-path core/Cargo.toml --test fixture_comparison'
            $log | Should -Match 'npm --prefix winsmux-app run test:bakeoff-runner'
            $log | Should -Match 'npm --prefix winsmux-app run test:desktop-status-e2e'
            $log | Should -Match 'npm --prefix winsmux-app run test:automation-driver-pool'
        } finally {
            $env:PATH = $originalPath
            if ($null -eq $originalFakeLog) {
                Remove-Item Env:\WINSMUX_FAKE_COMMAND_LOG -ErrorAction SilentlyContinue
            } else {
                $env:WINSMUX_FAKE_COMMAND_LOG = $originalFakeLog
            }

            if ($hadOriginal) {
                Set-Content -LiteralPath $evidencePath -Encoding UTF8 -Value $originalEvidence
            } elseif (Test-Path -LiteralPath $evidencePath -PathType Leaf) {
                Remove-Item -LiteralPath $evidencePath -Force
            }

            if (Test-Path -LiteralPath $fakeBin) {
                Remove-Item -LiteralPath $fakeBin -Recurse -Force
            }
        }
    }

    It 'is wired into public-surface allowlists and CI' {
        $gitignore = Get-Content -LiteralPath (Join-Path $script:repoRoot '.gitignore') -Raw
        $whitelist = Get-Content -LiteralPath (Join-Path $script:repoRoot '.githooks/pre-commit-whitelist.ps1') -Raw
        $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github/workflows/test.yml') -Raw

        $gitignore | Should -Match ([regex]::Escape('!tests/V03627CompatPerformanceGate.Tests.ps1'))
        $whitelist | Should -Match ([regex]::Escape('scripts/test-v03627-compat-performance-gate.ps1'))
        $whitelist | Should -Match ([regex]::Escape('tests/V03627CompatPerformanceGate.Tests.ps1'))
        $workflow | Should -Match 'compat-performance-v03627'
        $workflow | Should -Match 'tests/V03627CompatPerformanceGate\.Tests\.ps1'
    }
}
