$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'TASK-799 final runtime architecture contract' {
    BeforeAll {
        $script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:runnerPath = Join-Path $script:repoRoot 'scripts/run-tests.ps1'
        $script:authorityPath = Join-Path $script:repoRoot 'scripts/pester-runtime-contract.ps1'
        $script:portablePwsh = [IO.Path]::GetFullPath(
            [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        )

        function Get-Task799Hash {
            param([Parameter(Mandatory = $true)][string]$Path)
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        }

        function Get-Task799Value {
            param($Object, [Parameter(Mandatory = $true)][string]$Name)
            if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
            $null
        }

        function New-Task799Fixture {
            param([Parameter(Mandatory = $true)][string]$Name)
            $root = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Force -Path (Join-Path $root 'scripts'), (Join-Path $root 'tests/bridge'), (Join-Path $root '.github/workflows') | Out-Null
            Copy-Item -LiteralPath $script:runnerPath -Destination (Join-Path $root 'scripts/run-tests.ps1') -Force
            if (Test-Path -LiteralPath $script:authorityPath -PathType Leaf) {
                Copy-Item -LiteralPath $script:authorityPath -Destination (Join-Path $root 'scripts/pester-runtime-contract.ps1') -Force
            }
            @"
function Get-Task799FixtureValue { 'fixture' }
"@ | Set-Content -LiteralPath (Join-Path $root 'scripts/fixture.ps1') -Encoding utf8NoBOM
            @"
Describe 'TASK799 fixture' {
    It 'runs once' { . (Join-Path `$PSScriptRoot '../scripts/fixture.ps1'); Get-Task799FixtureValue | Should -Be 'fixture' }
}
"@ | Set-Content -LiteralPath (Join-Path $root 'tests/Fixture.Tests.ps1') -Encoding utf8NoBOM
            $lines = [Collections.Generic.List[string]]::new()
            $lines.Add('jobs:'); $lines.Add('  pester:'); $lines.Add('    strategy:'); $lines.Add('      matrix:'); $lines.Add('        include:')
            foreach ($number in 1..13) {
                $name = 'Bridge{0:D2}.Tests.ps1' -f $number
                "Describe 'bridge $number' { It 'runs' { 1 | Should -Be 1 } }" | Set-Content -LiteralPath (Join-Path $root "tests/bridge/$name") -Encoding utf8NoBOM
                $lines.Add("          - name: bridge-$number"); $lines.Add("            result: bridge-$number"); $lines.Add('            timeout_minutes: 1'); $lines.Add("            paths: tests/bridge/$name"); $lines.Add('            full_name: ""')
            }
            [IO.File]::WriteAllText((Join-Path $root '.github/workflows/test.yml'), (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
            $root
        }

        function Invoke-Task799Runner {
            param([Parameter(Mandatory = $true)][string]$Fixture, [switch]$Serial, [switch]$Coverage)
            $results = Join-Path $Fixture ('results-' + [guid]::NewGuid().ToString('N'))
            $arguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $Fixture 'scripts/run-tests.ps1'), '-ResultsDirectory', $results, '-CoverageThreshold', '0')
            if ($Serial) { $arguments += '-Parallel:$false' }
            if ($Coverage) { $arguments += '-Coverage' }
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $script:portablePwsh
            $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            foreach ($argument in $arguments) { [void]$start.ArgumentList.Add($argument) }
            $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
            [void]$process.Start(); $out = $process.StandardOutput.ReadToEnd(); $err = $process.StandardError.ReadToEnd(); $process.WaitForExit()
            $summaryPath = Join-Path $results 'summary.json'
            [ordered]@{
                launcher_pid = $process.Id; exit_code = $process.ExitCode; stdout = $out; stderr = $err
                results_directory = $results; summary_path = $summaryPath
                summary = if (Test-Path -LiteralPath $summaryPath -PathType Leaf) { Get-Content -LiteralPath $summaryPath -Raw -Encoding utf8 | ConvertFrom-Json } else { $null }
            }
        }

        function Get-Task799State {
            param([Parameter(Mandatory = $true)][string]$StatePath, [Parameter(Mandatory = $true)][string]$ResultsPath)
            [ordered]@{ before_sha256 = Get-Task799Hash $StatePath; results_directory_before = Test-Path -LiteralPath $ResultsPath }
        }

        function Get-Task799WorkflowShape {
            param([Parameter(Mandatory = $true)][string]$Path)
            $lines = Get-Content -LiteralPath $Path -Encoding utf8
            $jobs = [ordered]@{}; $current = $null; $inMatrix = $false; $inNeeds = $false
            $matrixEntries = [Collections.Generic.List[object]]::new()
            foreach ($line in $lines) {
                if ($line -match '^  (?<job>[a-z0-9][a-z0-9-]+):\s*$') {
                    $current = $Matches.job
                    $jobs[$current] = [ordered]@{ lines = [Collections.Generic.List[string]]::new(); needs = [Collections.Generic.List[string]]::new() }
                    $inMatrix = $false; $inNeeds = $false; continue
                }
                if ($null -eq $current) { continue }
                $jobs[$current].lines.Add($line)
                if ($line -match '^    needs:\s*$') { $inNeeds = $true; continue }
                if ($line -match '^    needs:\s*(?<needs>.+)$') {
                    foreach ($need in @($Matches.needs -replace '[\[\],]', ' ' -split '\s+' | Where-Object { $_ })) { $jobs[$current].needs.Add($need) }
                    $inNeeds = $false
                } elseif ($inNeeds -and $line -match '^      -\s*(?<need>[a-z0-9][a-z0-9-]+)\s*$') {
                    $jobs[$current].needs.Add($Matches.need)
                } elseif ($inNeeds -and $line -match '^    \S') {
                    $inNeeds = $false
                }
                if ($current -eq 'pester' -and $line -match '^        include:\s*$') { $inMatrix = $true; continue }
                if ($inMatrix -and $line -match '^          - name:\s*(?<name>.+)$') { $matrixEntries.Add([ordered]@{ name = $Matches.name.Trim(); lines = [Collections.Generic.List[string]]::new() }); continue }
                if ($inMatrix -and $line -match '^          - ') { continue }
                if ($inMatrix -and $line -match '^            ' -and $matrixEntries.Count -gt 0) { $matrixEntries[$matrixEntries.Count - 1].lines.Add($line); continue }
                if ($inMatrix -and $line -notmatch '^\s*$' -and $line -notmatch '^            ') { $inMatrix = $false }
            }
            [ordered]@{ jobs = $jobs; pester_matrix = @($matrixEntries) }
        }

        function Get-Task799FenceCommands {
            param([Parameter(Mandatory = $true)][string]$Path)
            $text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
            @([regex]::Matches($text, '(?ms)^```(?:powershell|pwsh)\s*\r?\n(?<body>.*?)^```\s*$') | ForEach-Object { $_.Groups['body'].Value })
        }

        function Get-Task799InvokePesterInventory {
            $records = [Collections.Generic.List[object]]::new()
            $tracked = @(& git -C $script:repoRoot ls-files)
            foreach ($relative in $tracked) {
                $path = Join-Path $script:repoRoot $relative
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                try { $text = Get-Content -LiteralPath $path -Raw -Encoding utf8 -ErrorAction Stop } catch { continue }
                if ($null -eq $text) { $text = '' }
                foreach ($match in [regex]::Matches($text, 'Invoke-Pester')) {
                    $owner = if ($relative -in @('scripts/run-tests.ps1', '.github/workflows/test.yml')) { 'TASK-799-allowed' }
                    elseif ($relative -in @('tests/README.md', 'docs/project/DETAILED_DESIGN.md', 'docs/project/THREAT_MODEL_AUDIT.md', 'docs/project/design-freeze-gate.md')) { 'TASK-799-prohibited-direct' }
                    elseif ($relative -in @('.claude/rules/dispatch.md', 'scripts/winsmux-core.ps1')) { 'TASK-800-preserved' }
                    elseif ($relative -eq '.claude/hooks/sh-task-gate.js') { 'TASK-798' }
                    elseif (
                        $relative -match '^(tests/|core/tests-rs/|tests/fixtures/)' -or
                        $relative -eq 'winsmux-app/src-tauri/src/desktop_backend.rs'
                    ) { 'non-executing-data' }
                    else { 'unknown' }
                    $records.Add([pscustomobject]@{ path = $relative; index = $match.Index; owner = $owner })
                }
            }
            @($records)
        }
    }

    It 'RT799-01: authority file/7.6/7.6.4/archive URI/hash plus official #Requires/docs contracts absent => RED' {
        # RT799-01-entry RT799-01-authority RT799-01-source RT799-01-consumer RT799-01-sink RT799-01-state RT799-01-assert
        $docs = @('CONTRIBUTING.md', 'tests/README.md') | ForEach-Object { Get-Content -LiteralPath (Join-Path $script:repoRoot $_) -Raw -Encoding utf8 }
        $authorityExists = Test-Path -LiteralPath $script:authorityPath -PathType Leaf
        $authorityText = if ($authorityExists) { Get-Content -LiteralPath $script:authorityPath -Raw -Encoding utf8 } else { '' }
        $runnerText = Get-Content $script:runnerPath -Raw -Encoding utf8
        $verifyText = Get-Content (Join-Path $script:repoRoot 'winsmux-core/scripts/verify.ps1') -Raw -Encoding utf8
        $hasPolicy = ($authorityText -match 'runtime_train\s*=\s*''7\.6''') -and
            ($authorityText -match 'ci_proof_version\s*=\s*''7\.6\.4''') -and
            ($authorityText -match 'PowerShell-7\.6\.4-win-x64\.zip') -and
            ($authorityText -match '80832551C52809301E6071C8BAC977BEB5A2F1EC953EB4DB9F94DEB953333793')
        $docsBound = @($docs | Where-Object { ($_ -match 'scripts/run-tests\.ps1') -and ($_ -match '7\.6') }).Count -eq 2
        $ok = $authorityExists -and $hasPolicy -and
            ($authorityText -match '#Requires -Version 7\.6') -and
            ($runnerText -match '#Requires -Version 7\.6') -and
            ($verifyText -match '#Requires -Version 7\.6') -and
            $docsBound
        $ok | Should -BeTrue
    }

    It 'RT799-02: default runner result binds a real portable process self-observation' {
        # RT799-02-entry RT799-02-authority RT799-02-source RT799-02-consumer RT799-02-sink RT799-02-state RT799-02-observation-id RT799-02-controller RT799-02-public-process RT799-02-exit RT799-02-assert
        $fixture = New-Task799Fixture 'RT799-02'; $sentinel = Join-Path $fixture 'state.txt'; 'stable' | Set-Content $sentinel -Encoding utf8NoBOM
        $before = Get-Task799State $sentinel (Join-Path $fixture 'pending-results'); $run = Invoke-Task799Runner $fixture
        $summary = $run.summary; $runtime = Get-Task799Value $summary 'runtime'
        $ok = ($run.exit_code -eq 0) -and ($null -ne $summary) -and
            ((Get-Task799Value $runtime 'observation_id') -as [string]) -and
            ([int64](Get-Task799Value $runtime 'pid') -eq $run.launcher_pid) -and
            ([string](Get-Task799Value $runtime 'executable') -ieq $script:portablePwsh) -and
            ([string](Get-Task799Value $runtime 'version') -match '^7\.6\.') -and
            ([bool](Get-Task799Value $summary 'parallel')) -and
            ((Get-Task799Value $summary 'identityHash') -as [string]) -and
            ((Get-Task799Hash $sentinel) -eq $before.before_sha256)
        $ok | Should -BeTrue
    }

    It 'RT799-03: serial runner result binds a real portable process self-observation' {
        # RT799-03-entry RT799-03-authority RT799-03-source RT799-03-consumer RT799-03-sink RT799-03-state RT799-03-observation-id RT799-03-controller RT799-03-public-process RT799-03-exit RT799-03-assert
        $fixture = New-Task799Fixture 'RT799-03'; $sentinel = Join-Path $fixture 'state.txt'; 'stable' | Set-Content $sentinel -Encoding utf8NoBOM
        $before = Get-Task799State $sentinel (Join-Path $fixture 'pending-results'); $run = Invoke-Task799Runner $fixture -Serial
        $summary = $run.summary; $runtime = Get-Task799Value $summary 'runtime'
        $ok = ($run.exit_code -eq 0) -and ($null -ne $summary) -and
            ((Get-Task799Value $runtime 'observation_id') -as [string]) -and
            ([int64](Get-Task799Value $runtime 'pid') -eq $run.launcher_pid) -and
            ([string](Get-Task799Value $runtime 'executable') -ieq $script:portablePwsh) -and
            ([string](Get-Task799Value $runtime 'version') -match '^7\.6\.') -and
            (-not [bool](Get-Task799Value $summary 'parallel')) -and
            ((Get-Task799Value $summary 'identityHash') -as [string]) -and
            ((Get-Task799Hash $sentinel) -eq $before.before_sha256)
        $ok | Should -BeTrue
    }

    It 'RT799-04: default and coverage runs have distinct observations and one runtime identity' {
        # RT799-04-entry RT799-04-authority RT799-04-source RT799-04-consumer RT799-04-sink RT799-04-state RT799-04-observation-id RT799-04-controller RT799-04-public-process RT799-04-exit RT799-04-assert
        $fixture = New-Task799Fixture 'RT799-04'; $default = Invoke-Task799Runner $fixture; $coverage = Invoke-Task799Runner $fixture -Coverage
        $one = $default.summary; $two = $coverage.summary; $oneRuntime = Get-Task799Value $one 'runtime'; $twoRuntime = Get-Task799Value $two 'runtime'
        $ok = ($default.exit_code -eq 0) -and ($coverage.exit_code -eq 0) -and
            ($null -ne $one) -and ($null -ne $two) -and
            ((Get-Task799Value $oneRuntime 'observation_id') -as [string]) -and
            ((Get-Task799Value $twoRuntime 'observation_id') -as [string]) -and
            ([string](Get-Task799Value $oneRuntime 'observation_id') -cne [string](Get-Task799Value $twoRuntime 'observation_id')) -and
            ([int64](Get-Task799Value $oneRuntime 'pid') -eq $default.launcher_pid) -and
            ([int64](Get-Task799Value $twoRuntime 'pid') -eq $coverage.launcher_pid) -and
            ([string](Get-Task799Value $oneRuntime 'executable') -ieq [string](Get-Task799Value $twoRuntime 'executable')) -and
            ([string](Get-Task799Value $oneRuntime 'version') -eq [string](Get-Task799Value $twoRuntime 'version')) -and
            ([string](Get-Task799Value $one 'identityHash') -eq [string](Get-Task799Value $two 'identityHash'))
        $ok | Should -BeTrue
    }

    It 'RT799-05: verify delegates one selected portable executable to the runner summary' {
        # RT799-05-entry RT799-05-authority RT799-05-source RT799-05-consumer RT799-05-sink RT799-05-state RT799-05-observation-id RT799-05-controller RT799-05-public-process RT799-05-exit RT799-05-assert
        $fixture = New-Task799Fixture 'RT799-05'; $shim = Join-Path $fixture 'shim'; New-Item -ItemType Directory -Force -Path $shim | Out-Null
        [IO.File]::WriteAllText((Join-Path $shim 'git.cmd'), "@echo off`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText((Join-Path $shim 'gh.cmd'), "@echo off`r`necho []`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
        $priorPath = $env:PATH
        try { $env:PATH = (Split-Path -Parent $script:portablePwsh) + [IO.Path]::PathSeparator + $shim + [IO.Path]::PathSeparator + $priorPath; $output = & $script:portablePwsh -NoProfile -File (Join-Path $script:repoRoot 'winsmux-core/scripts/verify.ps1') -PRNumber 1 -ProjectDir $fixture 2>&1 | Out-String; $exit = $LASTEXITCODE } finally { $env:PATH = $priorPath }
        $verifyText = Get-Content -LiteralPath (Join-Path $script:repoRoot 'winsmux-core/scripts/verify.ps1') -Raw -Encoding utf8
        $ok = ($exit -eq 0) -and
            ($verifyText -notmatch 'Get-Command\s+pwsh') -and
            ($verifyText -match 'pester-runtime-contract') -and
            ($verifyText -match 'pesterSummary\.runtime') -and
            ($output -match 'Pester runtime:.*7\.6') -and
            ($output.IndexOf($script:portablePwsh, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        $ok | Should -BeTrue
    }

    It 'RT799-06: Windows PowerShell pre-entry reject preserves protected state' {
        # RT799-06-entry RT799-06-authority RT799-06-source RT799-06-consumer RT799-06-sink RT799-06-state RT799-06-observation-id RT799-06-controller RT799-06-public-process RT799-06-exit RT799-06-assert
        $windows = (Get-Command powershell.exe -ErrorAction Stop | Select-Object -First 1).Source; $state = Join-Path $TestDrive 'RT799-06.txt'; 'stable' | Set-Content $state -Encoding utf8NoBOM; $before = Get-Task799Hash $state; $results = Join-Path $TestDrive 'RT799-06-results'
        $start = [Diagnostics.ProcessStartInfo]::new(); $start.FileName = $windows; $start.UseShellExecute = $false; [void]$start.ArgumentList.Add('-NoProfile'); [void]$start.ArgumentList.Add('-File'); [void]$start.ArgumentList.Add($script:runnerPath); [void]$start.ArgumentList.Add('-ResultsDirectory'); [void]$start.ArgumentList.Add($results)
        $process = [Diagnostics.Process]::new(); $process.StartInfo = $start; [void]$process.Start(); $process.WaitForExit()
        $ok = ($process.Id -gt 0) -and ($process.ExitCode -ne 0) -and (-not (Test-Path -LiteralPath $results)) -and ((Get-Task799Hash $state) -eq $before) -and ((Get-Content $script:runnerPath -Raw -Encoding utf8) -match '#Requires -Version 7\.6')
        $ok | Should -BeTrue
    }

    It 'RT799-07: semantic version 7.7.0 is fail-closed without a real-process claim' {
        # RT799-07-entry RT799-07-authority RT799-07-source RT799-07-consumer RT799-07-sink RT799-07-state RT799-07-assert
        $hasAuthorityPredicate = (Test-Path $script:authorityPath) -and ((Get-Content $script:authorityPath -Raw -Encoding utf8) -match 'Assert-WinsmuxPesterRuntime')
        $rejected = $false
        if ($hasAuthorityPredicate) {
            . $script:authorityPath
            $semanticVersion = [version]'7.7.0'
            $contract = Get-WinsmuxPesterRuntimeContract -RepositoryRoot $script:repoRoot -Executable $script:portablePwsh -Version $semanticVersion
            try {
                Assert-WinsmuxPesterRuntime -Contract $contract -Executable $script:portablePwsh -Version $semanticVersion | Out-Null
            } catch {
                $rejected = $_.Exception.Message -match 'requires PowerShell 7\.6\.x'
            }
        }
        $ok = $hasAuthorityPredicate -and $rejected
        $ok | Should -BeTrue
    }

    It 'RT799-08: DETAILED_DESIGN executable Pester fences route through the runner' {
        # RT799-08-entry RT799-08-authority RT799-08-source RT799-08-consumer RT799-08-sink RT799-08-state RT799-08-assert
        $fences = Get-Task799FenceCommands (Join-Path $script:repoRoot 'docs/project/DETAILED_DESIGN.md')
        $ok = (@($fences | Where-Object { $_ -match 'Invoke-Pester' }).Count -eq 0) -and
            (@($fences | Where-Object { $_ -match 'scripts[\\/]run-tests\.ps1' }).Count -ge 2)
        $ok | Should -BeTrue
    }

    It 'RT799-09: THREAT_MODEL_AUDIT release-gate Pester fences route through the runner' {
        # RT799-09-entry RT799-09-authority RT799-09-source RT799-09-consumer RT799-09-sink RT799-09-state RT799-09-assert
        $fences = Get-Task799FenceCommands (Join-Path $script:repoRoot 'docs/project/THREAT_MODEL_AUDIT.md')
        $ok = (@($fences | Where-Object { $_ -match 'Invoke-Pester' }).Count -eq 0) -and
            (@($fences | Where-Object { $_ -match 'scripts[\\/]run-tests\.ps1' }).Count -ge 1)
        $ok | Should -BeTrue
    }

    It 'RT799-10: design-freeze verification Pester fences route through the runner' {
        # RT799-10-entry RT799-10-authority RT799-10-source RT799-10-consumer RT799-10-sink RT799-10-state RT799-10-assert
        $documentPath = Join-Path $script:repoRoot 'docs/project/design-freeze-gate.md'
        $document = Get-Content -LiteralPath $documentPath -Raw -Encoding utf8
        $fences = Get-Task799FenceCommands $documentPath
        $ok = (@($fences | Where-Object { $_ -match 'Invoke-Pester' }).Count -eq 0) -and
            (@($fences | Where-Object { $_ -match 'scripts[\\/]run-tests\.ps1' }).Count -ge 1) -and
            ($document -match 'tests/PublicSurfacePolicy\.Tests\.ps1')
        $ok | Should -BeTrue
    }

    It 'RT799-11: every CI Pester shard consumes and reports the verified runtime' {
        # RT799-11-entry RT799-11-authority RT799-11-source RT799-11-consumer RT799-11-sink RT799-11-state RT799-11-assert
        $shape = Get-Task799WorkflowShape (Join-Path $script:repoRoot '.github/workflows/test.yml'); $shards = @($shape.pester_matrix)
        $expectedNames = @(
            'bridge-foundation', 'bridge-agent-orchestra', 'bridge-command-status',
            'bridge-worker-workspace-sandbox', 'bridge-worker-broker-token', 'bridge-worker-policy',
            'bridge-worker-secrets-status', 'bridge-worker-heartbeat-start', 'bridge-worker-api-agy-exec',
            'bridge-command-queue-reporting', 'bridge-command-review-dispatch', 'bridge-provider-commands',
            'bridge-artifacts-runtime', 'integration', 'worker-benchmark', 'release-public',
            'shell-support', 'repo-audit-v03619', 'coordinator-v03620', 'local-router-v03621',
            'desktop-split-v03626', 'compat-performance-v03627', 'race-abnormal-soak-v03628',
            'runtime-reliability-v03628', 'packaged-restore-v03628'
        )
        $pesterLines = if ($shape.jobs.Contains('pester')) { $shape.jobs['pester'].lines -join "`n" } else { '' }
        $ok = $shape.jobs.Contains('pester') -and
            ((@($shards.name) -join "`n") -ceq ($expectedNames -join "`n")) -and
            ($pesterLines -match 'pester-runtime-contract') -and
            ($pesterLines -match 'download-artifact') -and
            ($pesterLines -match 'pwsh\.exe') -and
            ($pesterLines -match 'runtime.*observation|observation.*runtime') -and
            ($pesterLines -match 'upload-artifact')
        $ok | Should -BeTrue
    }

    It 'RT799-12: CI proof derives authority metadata and feeds matrix and Merge Gate' {
        # RT799-12-entry RT799-12-authority RT799-12-source RT799-12-consumer RT799-12-sink RT799-12-state RT799-12-assert
        $shape = Get-Task799WorkflowShape (Join-Path $script:repoRoot '.github/workflows/test.yml')
        $proof = $shape.jobs['pester-runtime-contract']; $matrix = $shape.jobs['pester']; $merge = $shape.jobs['merge-gate']
        $proofLines = if ($null -ne $proof) { $proof.lines -join "`n" } else { '' }; $matrixLines = if ($null -ne $matrix) { $matrix.lines -join "`n" } else { '' }
        $ok = ($null -ne $proof) -and ($null -ne $matrix) -and ($null -ne $merge) -and
            ($proofLines -match 'pester-runtime-contract\.ps1') -and
            ($proofLines -match 'archive_uri') -and
            ($proofLines -match 'archive_sha256') -and
            ($proofLines -notmatch '80832551C52809301E6071C8BAC977BEB5A2F1EC953EB4DB9F94DEB953333793') -and
            ($matrixLines -match 'download-artifact') -and
            (@($matrix.needs | Where-Object { $_ -eq 'pester-runtime-contract' }).Count -eq 1) -and
            (@($merge.needs | Where-Object { $_ -eq 'pester-runtime-contract' }).Count -eq 1)
        $ok | Should -BeTrue
    }

    It 'RT799-13: tracked Invoke-Pester inventory has one exact owner per occurrence' {
        # RT799-13-entry RT799-13-authority RT799-13-source RT799-13-consumer RT799-13-sink RT799-13-state RT799-13-assert
        $inventory = Get-Task799InvokePesterInventory
        $counts = @{}
        foreach ($owner in @('TASK-799-allowed', 'TASK-799-prohibited-direct', 'TASK-800-preserved', 'TASK-798', 'non-executing-data', 'unknown')) {
            $counts[$owner] = @($inventory | Where-Object owner -eq $owner).Count
        }
        # Preserved out-of-scope owners must agree with the frozen baseline
        # before the TASK-799 cutover assertions are evaluated.
        $counts['TASK-800-preserved'] | Should -Be 4
        $counts['TASK-798'] | Should -Be 1
        $counts['unknown'] | Should -Be 0

        $counts['TASK-799-allowed'] | Should -Be 4
        $counts['TASK-799-prohibited-direct'] | Should -Be 0
        $counts['non-executing-data'] | Should -BeGreaterOrEqual 61
    }
}
