$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'v0.36.38 router reliability gate' {
    BeforeAll {
        $script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:gateScript = Join-Path $script:repoRoot 'scripts/test-v03638-router-reliability.ps1'
        $script:pesterRegistryPath = Join-Path $script:repoRoot 'scripts/winsmux-pester.psm1'
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/test.yml'
        $script:gitignorePath = Join-Path $script:repoRoot '.gitignore'
        $script:whitelistPath = Join-Path $script:repoRoot '.githooks/pre-commit-whitelist.ps1'
        $script:expectedBase = '7aab75f7f831993c0621d74ad4e772b3971c40e5'
        $script:expectedAuthorityHashes = [ordered]@{
            coordinator_router    = '24a6493aa9dff3a52175bba7b4f9c19b278e484b5c15d685df5d02f5a252e866'
            local_router_shadow   = '0303361289e95d33aafc4280c166cc8b9281ed31a10092830d8b5e9d2fe39ffc'
            local_router_manifest = '231f5a69959caadaefb2b000d73b95bbac12547bda6c5e538b7fff40fb69bd57'
            local_router_weights  = '2b0a2bf7d4cf00ff4c85f3bcbc8c0f5bf8ae0cb380396279ded764fac1ed210d'
        }
    }

    It 'runs the fixed 100-case parent-child reliability receipt' {
        $output = @(& pwsh -NoProfile -File $script:gateScript -Json)
        $LASTEXITCODE | Should -Be 0

        $result = ($output | Out-String | ConvertFrom-Json)
        $result.all_pass | Should -BeTrue
        $result.release_ready | Should -BeTrue
        $result.receipt.schema | Should -BeExactly 'winsmux.v03638.router_reliability_receipt.v1'
        $result.receipt.gate_id | Should -BeExactly 'v03638-router-reliability'
        $result.receipt.target_version | Should -BeExactly 'v0.36.38'
        $result.receipt.task_base_sha | Should -BeExactly $script:expectedBase
        [string]$result.receipt.executed_head_sha | Should -Match '^[0-9a-f]{40}$'
        $actualHead = (@(& git -c ("safe.directory={0}" -f $script:repoRoot) -C $script:repoRoot rev-parse HEAD 2>$null) | Out-String).Trim()
        $LASTEXITCODE | Should -Be 0
        $result.receipt.executed_head_sha | Should -BeExactly $actualHead
        [int]$result.receipt.run_count | Should -Be 100
        [int]$result.receipt.max_batch_size | Should -Be 1
        [int]$result.receipt.provider_calls | Should -Be 0
        [int]$result.receipt.prompt_canary_occurrences | Should -Be 0
        @($result.receipt.failures).Count | Should -Be 0
        [int]$result.receipt.child.pid | Should -BeGreaterThan 0
        [int]$result.receipt.child.parent_pid | Should -BeGreaterThan 0
        [string]$result.receipt.child.started_at_utc | Should -Not -BeNullOrEmpty
        [int]$result.receipt.child.exit_code | Should -Be 0
        $result.receipt.child.exited | Should -BeTrue
        [int]$result.receipt.cleanup.remaining_processes | Should -Be 0
        [int]$result.receipt.cleanup.remaining_temp_entries | Should -Be 0

        $expectedCounts = [ordered]@{
            normal                          = 17
            'previous-model-failure'        = 17
            'previous-infrastructure-failure' = 17
            'write-scope-conflict'          = 17
            'all-offline'                   = 16
            'threshold-fallback'            = 16
        }
        $observedCount = 0
        foreach ($classification in $expectedCounts.Keys) {
            $expectedCount = [int]$expectedCounts[$classification]
            [int]$result.receipt.class_counts.$classification | Should -Be $expectedCount
            $classResult = @($result.receipt.class_results | Where-Object { $_.classification -eq $classification })
            $classResult.Count | Should -Be 1
            [int]$classResult[0].deterministic_matches | Should -Be $expectedCount
            [int]$classResult[0].shadow_final_matches | Should -Be $expectedCount
            [int]$classResult[0].fallback_matches | Should -Be $expectedCount
            $observedCount += [int]$result.receipt.class_counts.$classification
        }
        $observedCount | Should -Be 100

        $sourcePaths = [ordered]@{
            coordinator_router    = 'winsmux-core/scripts/coordinator-router.ps1'
            local_router_shadow   = 'winsmux-core/scripts/local-router-shadow.ps1'
            local_router_manifest = 'winsmux-core/router/local-small-router-v03621.manifest.json'
            local_router_weights  = 'winsmux-core/router/local-small-router-v03621.weights.json'
        }
        foreach ($source in $sourcePaths.GetEnumerator()) {
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:repoRoot ([string]$source.Value))).Hash.ToLowerInvariant()
            $actualHash | Should -BeExactly ([string]$script:expectedAuthorityHashes[$source.Key])
            [string]$result.receipt.source_sha256.($source.Key) | Should -BeExactly ([string]$script:expectedAuthorityHashes[$source.Key])
        }
        $gate = Get-Content -LiteralPath $script:gateScript -Raw -Encoding UTF8

        [regex]::IsMatch($gate, '\$executedHead\s+-c(?:eq|ne)\s+\$script:Task613BaseSha') | Should -BeFalse
        foreach ($entry in $script:expectedAuthorityHashes.GetEnumerator()) {
            [regex]::IsMatch($gate, [regex]::Escape([string]$entry.Value)) | Should -BeTrue
        }
        $gate.Contains('authority_source_hash_mismatch') | Should -BeTrue
    }

    It 'never allows a standalone worker invocation to report release readiness' {
        $output = @(& pwsh -NoProfile -File $script:gateScript -Worker -Json 2>$null)
        $LASTEXITCODE | Should -Be 1

        $workerResult = ($output | Out-String | ConvertFrom-Json)
        $workerResult.mode | Should -BeExactly 'worker'
        $workerResult.all_pass | Should -BeFalse
        $workerResult.release_ready | Should -BeFalse
    }

    It 'adds the reliability test to the existing local-router-v03621 shard only' {
        Import-Module -Name $script:pesterRegistryPath -Force
        $rows = @(Get-WinsmuxPesterShardRegistry)
        $rows.Count | Should -Be 27
        $row = @($rows | Where-Object { $_.shard_id -eq 'local-router-v03621' })
        $row.Count | Should -Be 1
        @($row[0].test_paths) | Should -Be @(
            'tests/V03621LocalRouterShadow.Tests.ps1',
            'tests/V03638RouterReliability.Tests.ps1'
        )

        $workflow = Get-Content -LiteralPath $script:workflowPath -Raw -Encoding UTF8
        ([regex]::Matches($workflow, '(?m)^          - name:').Count) | Should -Be 26
        $workflow | Should -Match ([regex]::Escape("`$shardId = 'desktop-debug-process'"))
        $workflow | Should -Match ([regex]::Escape('paths: tests/V03621LocalRouterShadow.Tests.ps1;tests/V03638RouterReliability.Tests.ps1'))

        $gitignore = Get-Content -LiteralPath $script:gitignorePath -Raw -Encoding UTF8
        $gitignore | Should -Match ([regex]::Escape('!tests/V03638RouterReliability.Tests.ps1'))
        $whitelist = Get-Content -LiteralPath $script:whitelistPath -Raw -Encoding UTF8
        $whitelist | Should -Match ([regex]::Escape('scripts/test-v03638-router-reliability.ps1'))
        $whitelist | Should -Match ([regex]::Escape('tests/V03638RouterReliability.Tests.ps1'))
    }
}
