# TASK-811 Pester/operator infrastructure gate. Bounded to this file.
# Runtime receipt: artifacts/operator-infra/task811-receipt.json (never committed).

Set-StrictMode -Version Latest

Describe 'TASK-811 byte provenance, process graph, receipt, and release binding' -Tag 'integration' {
    BeforeAll {
        $script:RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:RepoRoot)) {
            $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        }
        $script:AuthorityPath = Join-Path $script:RepoRoot 'scripts/winsmux-task811-authority.ps1'
        $script:PesterModulePath = Join-Path $script:RepoRoot 'scripts/winsmux-pester.psm1'
        $script:ReceiptPath = Join-Path $script:RepoRoot 'artifacts/operator-infra/task811-receipt.json'
        $script:PublicReleasePath = Join-Path $script:RepoRoot 'scripts/test-public-release.ps1'
        $script:WorkflowPath = Join-Path $script:RepoRoot '.github/workflows/test.yml'
        $script:WhitelistPath = Join-Path $script:RepoRoot '.githooks/pre-commit-whitelist.ps1'

        . $script:AuthorityPath

        function Get-Task811IndependentTreeEvidence {
            param([Parameter(Mandatory)][string]$ModuleBase)
            $base = [IO.Path]::GetFullPath($ModuleBase).TrimEnd('\', '/')
            $entries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            foreach ($file in @(Get-ChildItem -LiteralPath $base -File -Recurse -Force)) {
                $relative = [IO.Path]::GetRelativePath($base, $file.FullName).Replace('\', '/')
                $entries.Add($relative, [pscustomobject]@{
                    sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                })
            }
            $paths = [string[]]@($entries.Keys)
            [Array]::Sort($paths, [StringComparer]::Ordinal)
            $utf8 = [Text.UTF8Encoding]::new($false, $true)
            $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
            try {
                foreach ($relative in $paths) {
                    $hasher.AppendData($utf8.GetBytes(('{0}{1}{2}{3}' -f $relative, "`t", $entries[$relative].sha256, "`n")))
                }
                $hash = [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
            } finally {
                $hasher.Dispose()
            }
            return [pscustomobject]@{ file_count = $paths.Count; sha256 = $hash }
        }

        function Copy-Task811Receipt {
            param([Parameter(Mandatory)]$Receipt)
            return (($Receipt | ConvertTo-Json -Depth 32 -Compress) | ConvertFrom-Json -Depth 32)
        }

        function Get-Task811FixtureBytes {
            param([Parameter(Mandatory)]$Receipt)
            $utf8 = [Text.UTF8Encoding]::new($false, $true)
            $Receipt.artifact_bind.receipt_sha256 = ''
            $bindingBytes = $utf8.GetBytes((($Receipt | ConvertTo-Json -Depth 32 -Compress) + "`n"))
            $Receipt.artifact_bind.receipt_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bindingBytes)).ToLowerInvariant()
            return $utf8.GetBytes((($Receipt | ConvertTo-Json -Depth 32 -Compress) + "`n"))
        }

        function Write-Task811FixtureReceipt {
            param([Parameter(Mandatory)]$Receipt)
            [IO.File]::WriteAllBytes($script:ReceiptPath, (Get-Task811FixtureBytes -Receipt $Receipt))
        }

        function Get-Task811FunctionExtent {
            param(
                [Parameter(Mandatory)][string]$Text,
                [Parameter(Mandatory)][string]$Name
            )
            $parseTokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$parseTokens, [ref]$parseErrors)
            @($parseErrors).Count | Should -Be 0
            $matches = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
            }, $true))
            $matches.Count | Should -Be 1
            return ($matches[0].Extent.Text -replace "`r`n", "`n")
        }

        function Invoke-Task811GitQuietDiff {
            param([Parameter(Mandatory)][string]$Path)
            & git diff --quiet HEAD -- $Path
            return $LASTEXITCODE
        }

        if (Test-Path -LiteralPath $script:ReceiptPath -PathType Leaf) {
            Remove-Item -LiteralPath $script:ReceiptPath -Force
        }
        $script:HappyResult = Invoke-WinsmuxTask811Transaction
        $script:GoodReceiptBytes = [IO.File]::ReadAllBytes($script:ReceiptPath)
        $script:GoodReceipt = ([Text.UTF8Encoding]::new($false, $true).GetString($script:GoodReceiptBytes) | ConvertFrom-Json -Depth 32)
    }

    BeforeEach {
        [IO.File]::WriteAllBytes($script:ReceiptPath, $script:GoodReceiptBytes)
    }

    AfterEach {
        if (-not (Test-Path -LiteralPath $script:ReceiptPath -PathType Leaf)) {
            $parent = Split-Path -Parent $script:ReceiptPath
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [IO.File]::WriteAllBytes($script:ReceiptPath, $script:GoodReceiptBytes)
    }

    AfterAll {
        if ($script:ReceiptPath -and (Test-Path -LiteralPath $script:ReceiptPath -PathType Leaf)) {
            Remove-Item -LiteralPath $script:ReceiptPath -Force
        }
        $receiptDirectory = Split-Path -Parent $script:ReceiptPath
        if (Test-Path -LiteralPath $receiptDirectory -PathType Container) {
            $remaining = @(Get-ChildItem -LiteralPath $receiptDirectory -Force)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $receiptDirectory -Force
            }
        }
    }

    It 'writes one canonical status-ok receipt and all four real readers observe identical bytes' {
        $script:HappyResult.status | Should -BeExactly 'ok'
        $script:GoodReceipt.schema | Should -BeExactly 'winsmux.task811.receipt.v1'
        $script:GoodReceipt.authority | Should -BeExactly 'TASK-811'
        $script:GoodReceipt.status | Should -BeExactly 'ok'
        $script:GoodReceipt.fail_closed_reason | Should -BeExactly ''
        $readerHashes = @(
            $script:HappyResult.reader_hashes.controller
            $script:HappyResult.reader_hashes.discovery
            $script:HappyResult.reader_hashes.worker
            $script:HappyResult.reader_hashes.ci_consumer
        )
        (@($readerHashes | Sort-Object -Unique)).Count | Should -Be 1
        $readerHashes[0] | Should -BeExactly $script:HappyResult.receipt_file_sha256
        { Assert-WinsmuxTask811Receipt | Out-Null } | Should -Not -Throw
    }

    It 'accepts a published terminal result after its child exits' {
        $terminalResultPath = Join-Path $TestDrive 'terminal-result.json'
        $escapedResultPath = $terminalResultPath.Replace("'", "''")
        $writerScript = @"
[IO.File]::WriteAllBytes('$escapedResultPath', [Text.UTF8Encoding]::new(`$false).GetBytes('{"status":"ok"}'))
"@
        $encodedWriter = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($writerScript))
        $terminalProcess = Start-Task811PwshProcess `
            -PwshPath ([string]$script:GoodReceipt.pwsh.path) `
            -WorkingDirectory $script:RepoRoot `
            -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedWriter)
        try {
            $terminalProcess.WaitForExit()
            $terminalProcess.ExitCode | Should -Be 0
            $terminalResult = Wait-Task811ResultFile -Path $terminalResultPath -Process $terminalProcess
            [string]$terminalResult.status | Should -BeExactly 'ok'
        } finally {
            $terminalProcess.Dispose()
        }
    }

    It 'F1 binds the resolved pwsh executable bytes and rejects version-text-only evidence' {
        $resolvedPwsh = [IO.Path]::GetFullPath((Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source)
        [IO.Path]::GetFullPath([string]$script:GoodReceipt.pwsh.path) | Should -BeExactly $resolvedPwsh
        $actual = Get-Item -LiteralPath $resolvedPwsh
        [long]$script:GoodReceipt.pwsh.byte_length | Should -Be $actual.Length
        [string]$script:GoodReceipt.pwsh.sha256 | Should -BeExactly (Get-FileHash -LiteralPath $resolvedPwsh -Algorithm SHA256).Hash.ToLowerInvariant()

        $versionOnly = Copy-Task811Receipt -Receipt $script:GoodReceipt
        $versionOnly.pwsh.PSObject.Properties.Remove('sha256')
        $versionOnly.pwsh.PSObject.Properties.Remove('byte_length')
        $versionOnly.pwsh | Add-Member -NotePropertyName version_text -NotePropertyValue '7.x'
        Write-Task811FixtureReceipt -Receipt $versionOnly
        { Assert-WinsmuxTask811Receipt | Out-Null } | Should -Throw '*TASK811_FAIL_CLOSED*'
    }

    It 'F2 hashes the loaded module-base tree canonical bytes and rejects manifest metadata as the package' {
        $script:GoodReceipt.pester_package.representation | Should -BeExactly 'module_base_tree'
        $script:GoodReceipt.pester_package.resolver_status | Should -BeExactly 'resolved'
        $independent = Get-Task811IndependentTreeEvidence -ModuleBase $script:GoodReceipt.pester_package.module_base
        [int]$script:GoodReceipt.pester_package.file_count | Should -Be $independent.file_count
        [string]$script:GoodReceipt.pester_package.sha256 | Should -BeExactly $independent.sha256

        $metadataOnly = Copy-Task811Receipt -Receipt $script:GoodReceipt
        $manifestPath = Join-Path $metadataOnly.pester_package.module_base 'Pester.psd1'
        $metadataOnly.pester_package.representation = 'manifest_only'
        $metadataOnly.pester_package.file_count = 1
        $metadataOnly.pester_package.sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Task811FixtureReceipt -Receipt $metadataOnly
        { Assert-WinsmuxTask811Receipt -ArtifactBindingOnly | Out-Null } | Should -Throw '*pester_representation_invalid*'
    }

    It 'F3 rejects summary JSON and binds controller discovery worker and consumer to the receipt leaf' {
        $script:GoodReceipt.artifact_bind.receipt_path | Should -BeExactly 'artifacts/operator-infra/task811-receipt.json'
        $summaryBytes = [Text.UTF8Encoding]::new($false).GetBytes((@{ passed = 1; failed = 0; WorkerId = 'not-a-receipt' } | ConvertTo-Json -Compress) + "`n")
        [IO.File]::WriteAllBytes($script:ReceiptPath, $summaryBytes)
        { Assert-WinsmuxTask811Receipt -ArtifactBindingOnly | Out-Null } | Should -Throw '*TASK811_FAIL_CLOSED*'
    }

    It 'F4 records four distinct live-process identities and rejects WorkerId mock or token fields' {
        $graph = $script:GoodReceipt.process_graph
        $pids = [Collections.Generic.List[int]]::new()
        foreach ($role in @('controller', 'discovery', 'worker', 'ci_consumer')) {
            $node = $graph.$role
            [int]$node.pid | Should -BeGreaterThan 0
            [int]$node.parent_pid | Should -BeGreaterThan 0
            Test-Path -LiteralPath ([string]$node.image_path) -PathType Leaf | Should -BeTrue
            [string]$node.image_sha256 | Should -BeExactly (Get-FileHash -LiteralPath ([string]$node.image_path) -Algorithm SHA256).Hash.ToLowerInvariant()
            $pids.Add([int]$node.pid)
        }
        (@($pids | Sort-Object -Unique)).Count | Should -Be 4
        [int]$graph.controller.parent_pid | Should -Be ([int]$graph.ci_consumer.pid)
        [int]$graph.discovery.parent_pid | Should -Be ([int]$graph.controller.pid)
        [int]$graph.worker.parent_pid | Should -Be ([int]$graph.controller.pid)

        $tokenOnly = Copy-Task811Receipt -Receipt $script:GoodReceipt
        $tokenOnly.process_graph.discovery | Add-Member -NotePropertyName WorkerId -NotePropertyValue 'discovery'
        $tokenOnly.process_graph.worker | Add-Member -NotePropertyName mock -NotePropertyValue $true
        $tokenOnly.process_graph.ci_consumer | Add-Member -NotePropertyName token -NotePropertyValue 'opaque'
        Write-Task811FixtureReceipt -Receipt $tokenOnly
        { Assert-WinsmuxTask811Receipt -ArtifactBindingOnly | Out-Null } | Should -Throw '*banned_evidence_field*'
    }

    It 'F5 and F6 bind receipt tree and provenance after the required ordered checkpoints' {
        @($script:GoodReceipt.transaction.order) -join '|' | Should -BeExactly 'measure_bytes|spawn_graph|child_entry|write_receipt|bind_artifact|upload|merge'
        @($script:GoodReceipt.transaction.completed) -join '|' | Should -BeExactly 'measure_bytes|spawn_graph|child_entry|write_receipt|bind_artifact'
        @($script:GoodReceipt.transaction.deferred_hooks) -join '|' | Should -BeExactly 'upload|merge'
        $script:GoodReceipt.artifact_bind.tree_id | Should -BeExactly $script:GoodReceipt.tree_id

        $bindMismatch = Copy-Task811Receipt -Receipt $script:GoodReceipt
        $bindMismatch.pester_package.sha256 = ('0' * 64)
        [IO.File]::WriteAllBytes($script:ReceiptPath, ([Text.UTF8Encoding]::new($false).GetBytes((($bindMismatch | ConvertTo-Json -Depth 32 -Compress) + "`n"))))
        { Assert-WinsmuxTask811Receipt -ArtifactBindingOnly | Out-Null } | Should -Throw '*artifact_receipt_hash_mismatch*'

        $reordered = Copy-Task811Receipt -Receipt $script:GoodReceipt
        $reordered.transaction.order = @('spawn_graph', 'measure_bytes', 'child_entry', 'write_receipt', 'bind_artifact', 'upload', 'merge')
        Write-Task811FixtureReceipt -Receipt $reordered
        { Assert-WinsmuxTask811Receipt -ArtifactBindingOnly | Out-Null } | Should -Throw '*transaction_order_invalid*'
    }

    It 'F7 leaves no ok receipt at the adjacent crash cut or when a required child dies' {
        { Invoke-WinsmuxTask811Transaction -TestCrashBeforeReceiptWrite | Out-Null } | Should -Throw '*controller_exit_87*'
        Test-Path -LiteralPath $script:ReceiptPath | Should -BeFalse

        { Invoke-WinsmuxTask811Transaction -TestTerminateWorkerBeforeReceiptWrite | Out-Null } | Should -Throw '*TASK811_FAIL_CLOSED*'
        Test-Path -LiteralPath $script:ReceiptPath | Should -BeFalse
    }

    It 'F7 recovers only with the same byte pin tree and receipt binding' {
        { Invoke-WinsmuxTask811Transaction -TestCrashBeforeReceiptWrite | Out-Null } | Should -Throw
        Test-Path -LiteralPath $script:ReceiptPath | Should -BeFalse
        $recovery = Invoke-WinsmuxTask811Transaction
        $recoveredReceipt = (Get-Content -LiteralPath $script:ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32)
        $recovery.status | Should -BeExactly 'ok'
        $recoveredReceipt.tree_id | Should -BeExactly $script:GoodReceipt.tree_id
        $recoveredReceipt.pwsh.sha256 | Should -BeExactly $script:GoodReceipt.pwsh.sha256
        $recoveredReceipt.pester_package.sha256 | Should -BeExactly $script:GoodReceipt.pester_package.sha256
        { Assert-WinsmuxTask811Receipt | Out-Null } | Should -Not -Throw

        $differentPin = Copy-Task811Receipt -Receipt $recoveredReceipt
        $differentPin.pwsh.sha256 = ('1' * 64)
        foreach ($role in @('controller', 'discovery', 'worker', 'ci_consumer')) {
            $differentPin.process_graph.$role.image_sha256 = ('1' * 64)
        }
        Write-Task811FixtureReceipt -Receipt $differentPin
        { Assert-WinsmuxTask811Receipt | Out-Null } | Should -Throw '*local_pwsh_hash_mismatch*'
    }

    It 'F8 keeps all four child implementations untouched and preserves the TASK-810 resolver body' {
        foreach ($path in @(
            'scripts/run-tests.ps1'
            'scripts/operator-run-full-tests.ps1'
            '.claude/hooks/sh-task-gate.js'
        )) {
            (Invoke-Task811GitQuietDiff -Path $path) | Should -Be 0 -Because "$path belongs to a landed child task"
        }

        $currentModule = Get-Content -LiteralPath $script:PesterModulePath -Raw -Encoding UTF8
        $baselineModule = (& git show 'HEAD:scripts/winsmux-pester.psm1' 2>$null | Out-String)
        $LASTEXITCODE | Should -Be 0
        $currentResolver = Get-Task811FunctionExtent -Text $currentModule -Name 'Resolve-WinsmuxPester571'
        $baselineResolver = Get-Task811FunctionExtent -Text $baselineModule -Name 'Resolve-WinsmuxPester571'
        $currentResolver | Should -BeExactly $baselineResolver
        $resolverHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.UTF8Encoding]::new($false, $true).GetBytes($currentResolver)
        )).ToLowerInvariant()
        $resolverHash | Should -BeExactly '1b0ace9fdb81ad94c90ad4397b7152942668428f852682e8970a2028786c2099'

        Import-Module -Name $script:PesterModulePath -Force
        $integration = @(Get-WinsmuxPesterShardRegistry | Where-Object shard_id -CEQ 'integration')
        $integration.Count | Should -Be 1
        @($integration[0].test_paths | Where-Object { $_ -ceq 'tests/Task811OperatorInfraGate.Tests.ps1' }).Count | Should -Be 1
    }

    It 'F9 rejects version metadata and proxy observations as proof' {
        $proxyReceipt = Copy-Task811Receipt -Receipt $script:GoodReceipt
        $proxyReceipt.pester_package | Add-Member -NotePropertyName semantic_version -NotePropertyValue '5.7.1'
        $proxyReceipt.pwsh | Add-Member -NotePropertyName file_version -NotePropertyValue '7.x'
        $proxyReceipt.process_graph.controller | Add-Member -NotePropertyName proxy_path -NotePropertyValue 'pwsh'
        Write-Task811FixtureReceipt -Receipt $proxyReceipt
        { Assert-WinsmuxTask811Receipt -ArtifactBindingOnly | Out-Null } | Should -Throw '*banned_evidence_field*'
    }

    It 'F10 has one v0.36.31 owner reuses Core Desktop Npm and creates no tag or version change' {
        $script:GoodReceipt.release.owner | Should -BeExactly 'TASK-811'
        $script:GoodReceipt.release.target | Should -BeExactly 'v0.36.31'
        $script:GoodReceipt.release.do_not_overwrite | Should -BeExactly 'v0.36.30.1'
        $script:GoodReceipt.release.verifier | Should -BeExactly 'scripts/test-public-release.ps1'
        @($script:GoodReceipt.release.surfaces) -join '|' | Should -BeExactly 'Core|Desktop|Npm'
        [bool]$script:GoodReceipt.release.tag_created | Should -BeFalse

        $releaseText = Get-Content -LiteralPath $script:PublicReleasePath -Raw -Encoding UTF8
        $releaseTokens = $null
        $releaseErrors = $null
        $releaseAst = [Management.Automation.Language.Parser]::ParseInput($releaseText, [ref]$releaseTokens, [ref]$releaseErrors)
        @($releaseErrors).Count | Should -Be 0
        $surfaceParameter = @($releaseAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'Surface' })
        $surfaceParameter.Count | Should -Be 1
        $validateSet = @($surfaceParameter[0].Attributes | Where-Object { $_.TypeName.Name -ceq 'ValidateSet' })
        $validateSet.Count | Should -Be 1
        @($validateSet[0].PositionalArguments | ForEach-Object { [string]$_.SafeGetValue() }) -join '|' | Should -BeExactly 'Core|Desktop|Npm'

        (Invoke-Task811GitQuietDiff -Path 'VERSION') | Should -Be 0
        foreach ($releaseWorkflow in @(
            '.github/workflows/release-core.yml'
            '.github/workflows/release-desktop.yml'
            '.github/workflows/release-npm.yml'
        )) {
            (Invoke-Task811GitQuietDiff -Path $releaseWorkflow) | Should -Be 0
        }
    }

    It 'wires the same receipt through integration upload assertion and the existing merge gate' {
        $workflow = Get-Content -LiteralPath $script:WorkflowPath -Raw -Encoding UTF8
        $producerMatch = [regex]::Match($workflow, '(?ms)^  task811-operator-infra:\r?\n(?<body>.*?)(?=^  task811-receipt-bind:)')
        $consumerMatch = [regex]::Match($workflow, '(?ms)^  task811-receipt-bind:\r?\n(?<body>.*?)(?=^  merge-gate:)')
        $mergeMatch = [regex]::Match($workflow, '(?ms)^  merge-gate:\r?\n(?<body>.*)\z')
        $producerMatch.Success | Should -BeTrue
        $consumerMatch.Success | Should -BeTrue
        $mergeMatch.Success | Should -BeTrue
        $producer = [string]$producerMatch.Groups['body'].Value
        $consumer = [string]$consumerMatch.Groups['body'].Value
        $merge = [string]$mergeMatch.Groups['body'].Value
        $integrationMatch = [regex]::Match($workflow, '(?ms)^          - name: integration\r?\n(?<body>.*?)(?=^          - name: worker-benchmark)')
        $integrationMatch.Success | Should -BeTrue
        ([regex]::Matches($integrationMatch.Groups['body'].Value, 'tests/Task811OperatorInfraGate\.Tests\.ps1')).Count | Should -Be 1
        $producer | Should -Match '(?m)^    runs-on: windows-latest$'
        ([regex]::Matches($producer, 'actions/upload-artifact@v7')).Count | Should -Be 1
        ([regex]::Matches($producer, 'path: artifacts/operator-infra/task811-receipt\.json')).Count | Should -Be 1
        $producer | Should -Match 'name: task811-receipt-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}-\$\{\{ github\.sha \}\}'
        $producer | Should -Match '(?m)^    needs: pester$'
        $producer | Should -Match '(?m)^          if-no-files-found: error$'
        $consumer | Should -Match '(?m)^    runs-on: windows-latest$'
        ([regex]::Matches($consumer, 'actions/download-artifact@v8')).Count | Should -Be 1
        $consumer | Should -Match '(?m)^    needs: task811-operator-infra$'
        $consumer | Should -Match 'name: task811-receipt-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}-\$\{\{ github\.sha \}\}'
        $consumer | Should -Match '(?m)^          path: artifacts/operator-infra$'
        $consumer | Should -Match '\$downloadedFiles\.Count -ne 1'
        $consumer | Should -Match 'Assert-WinsmuxTask811Receipt -ArtifactBindingOnly'
        $merge | Should -Match '(?m)^      - task811-receipt-bind$'
        ([regex]::Matches($merge, 'needs\.task811-receipt-bind\.result')).Count | Should -Be 1

        $whitelist = Get-Content -LiteralPath $script:WhitelistPath -Raw -Encoding UTF8
        ([regex]::Matches($whitelist, "'scripts/winsmux-task811-authority\.ps1'")).Count | Should -Be 1
        ([regex]::Matches($whitelist, "'tests/Task811OperatorInfraGate\.Tests\.ps1'")).Count | Should -Be 1
    }
}
