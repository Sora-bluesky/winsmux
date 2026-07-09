$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'v0.36.28 race abnormal soak gate' {
    BeforeAll {
        $script:repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:repoRoot)) {
            throw 'Failed to resolve repository root.'
        }
        $script:gateScript = Join-Path $script:repoRoot 'scripts/test-v03628-race-abnormal-soak.ps1'
    }

    It 'passes the static wiring gate under PowerShell 7' {
        $output = & pwsh -NoProfile -File $script:gateScript -Json
        $LASTEXITCODE | Should -Be 0
        $result = ($output | Out-String | ConvertFrom-Json)

        $result.gate_id | Should -Be 'v03628-race-abnormal-soak'
        $result.evidence_mode | Should -Be 'static-wiring'
        $result.release_ready | Should -Be $false
        $result.all_pass | Should -Be $true
        $result.failed_count | Should -Be 0
        [int]$result.check_count | Should -BeGreaterThan 8
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

        $result.gate_id | Should -Be 'v03628-race-abnormal-soak'
        $result.all_pass | Should -Be $true
        $result.failed_count | Should -Be 0
    }

    It 'requires release evidence before marking the gate release-ready' {
        $evidenceRelative = ".winsmux/evidence/v03628-race-abnormal-soak-test-$([guid]::NewGuid().ToString('N'))/soak-summary.json"
        $evidencePath = Join-Path $script:repoRoot $evidenceRelative
        $evidenceDir = Split-Path -Parent $evidencePath

        try {
            $missingOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $missingResult = ($missingOutput | Out-String | ConvertFrom-Json)
            $missingResult.release_ready | Should -Be $false
            @($missingResult.checks | Where-Object { $_.name -eq 'soak evidence file exists' }).pass | Should -Contain $false

            New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
            Set-Content -LiteralPath $evidencePath -Encoding UTF8 -Value @'
{
  "ok": false,
  "run_count": 99,
  "classes": [
    "startup-cleanup-concurrency"
  ],
  "failures": [
    "simulated failure"
  ]
}
'@

            $failedOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $failedResult = ($failedOutput | Out-String | ConvertFrom-Json)
            $failedResult.release_ready | Should -Be $false
            @($failedResult.checks | Where-Object { $_.name -eq 'soak evidence reports boolean ok true' }).pass | Should -Contain $false
            @($failedResult.checks | Where-Object { $_.name -eq 'soak evidence records at least 100 runs' }).pass | Should -Contain $false

            Set-Content -LiteralPath $evidencePath -Encoding UTF8 -Value @'
{
  "ok": "false",
  "run_count": 100,
  "classes": [
    "startup-cleanup-concurrency",
    "property-matrix",
    "hundred-run-soak",
    "abnormal-exit",
    "long-running"
  ],
  "failures": []
}
'@

            $stringFalseOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 1
            $stringFalseResult = ($stringFalseOutput | Out-String | ConvertFrom-Json)
            $stringFalseResult.release_ready | Should -Be $false
            @($stringFalseResult.checks | Where-Object { $_.name -eq 'soak evidence reports boolean ok true' }).pass | Should -Contain $false

            Set-Content -LiteralPath $evidencePath -Encoding UTF8 -Value @'
{
  "ok": true,
  "run_count": 100,
  "classes": [
    "startup-cleanup-concurrency",
    "property-matrix",
    "hundred-run-soak",
    "abnormal-exit",
    "long-running"
  ],
  "failures": []
}
'@

            $successOutput = & pwsh -NoProfile -File $script:gateScript -Json -RequireEvidence -EvidencePath $evidenceRelative
            $LASTEXITCODE | Should -Be 0
            $successResult = ($successOutput | Out-String | ConvertFrom-Json)
            $successResult.all_pass | Should -Be $true
            $successResult.release_ready | Should -Be $true
            $successResult.failed_count | Should -Be 0
        } finally {
            if (Test-Path -LiteralPath $evidenceDir) {
                Remove-Item -LiteralPath $evidenceDir -Recurse -Force
            }
        }
    }

    It 'is wired into public-surface allowlists and CI' {
        $gitignore = Get-Content -LiteralPath (Join-Path $script:repoRoot '.gitignore') -Raw
        $whitelist = Get-Content -LiteralPath (Join-Path $script:repoRoot '.githooks/pre-commit-whitelist.ps1') -Raw
        $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github/workflows/test.yml') -Raw

        $gitignore | Should -Match ([regex]::Escape('!tests/V03628RaceAbnormalSoak.Tests.ps1'))
        $whitelist | Should -Match ([regex]::Escape('scripts/test-v03628-race-abnormal-soak.ps1'))
        $whitelist | Should -Match ([regex]::Escape('tests/V03628RaceAbnormalSoak.Tests.ps1'))
        $workflow | Should -Match 'race-abnormal-soak-v03628'
        $workflow | Should -Match 'tests/V03628RaceAbnormalSoak\.Tests\.ps1'
    }
}
