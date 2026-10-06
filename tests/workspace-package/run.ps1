#requires -Version 7.0
param([string]$SelectedCase = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'version-contract.ps1') -LibraryOnly
$source = Join-Path $repoRoot 'winsmux-app/src-tauri/scripts/prepare-companion-cli.ps1'
$outDir = Join-Path $repoRoot ('.evidence/workspace-package/' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($outDir)
$results = [Collections.Generic.List[object]]::new()
function Assert-Outcome([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Invoke-Fixture([string]$Root, [string]$Mode, [bool]$Release, [bool]$CustomTarget) {
    $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    foreach ($arg in @('-NoLogo', '-NoProfile', '-File', (Join-Path $Root 'child.ps1'), '-Mode', $Mode)) {
        $start.ArgumentList.Add($arg)
    }
    if ($Release) { $start.ArgumentList.Add('-Release') }
    if ($CustomTarget) { $start.ArgumentList.Add('-CustomTarget') }
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false, $true)
    $start.WorkingDirectory = $Root
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return @{ exit = $process.ExitCode; stdout = $stdout.GetAwaiter().GetResult(); stderr = $stderr.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}
function Assert-Pair([string]$Directory, [string]$Prefix, [switch]$Signed) {
    foreach ($name in @('winsmux', 'winsmux-workspace-mcp')) {
        $file = Join-Path $Directory "$name-x86_64-pc-windows-msvc.exe"
        Assert-Outcome (Test-Path -LiteralPath $file -PathType Leaf) "Missing $name"
        if ($Prefix -ceq 'new') {
            $bytes = [IO.File]::ReadAllBytes($file)
            $length = if ($Signed) { 2048 + [Text.Encoding]::UTF8.GetByteCount('signed-fixture') } else { 2048 }
            Assert-Outcome ($bytes.Length -eq $length -and [Text.Encoding]::UTF8.GetString($bytes, 1900, ("$Prefix-$name").Length) -ceq "$Prefix-$name") "Changed $Prefix generation: $name"
        } else { Assert-Outcome ([IO.File]::ReadAllText($file) -ceq "$Prefix-$name") "Changed $Prefix generation: $name" }
    }
}
try {
    $config = Get-Content (Join-Path $repoRoot 'winsmux-app/src-tauri/tauri.conf.json') -Raw | ConvertFrom-Json
    foreach ($name in @('winsmux', 'winsmux-workspace-mcp')) {
        Assert-Outcome ("binaries/$name" -cin $config.bundle.externalBin) "Tauri does not bundle $name"
    }
    $cases = @(
        @{ name='debug-default'; mode='ok'; release=$false; custom=$false; prior=$true },
        @{ name='debug-custom'; mode='ok'; release=$false; custom=$true; prior=$true },
        @{ name='release-default'; mode='ok'; release=$true; custom=$false; prior=$true },
        @{ name='release-custom'; mode='ok'; release=$true; custom=$true; prior=$true },
        @{ name='initial-debug'; mode='ok'; release=$false; custom=$false; prior=$false },
        @{ name='initial-release'; mode='ok'; release=$true; custom=$false; prior=$false },
        @{ name='signed-release'; mode='signed_ok'; release=$true; custom=$false; prior=$true },
        @{ name='signed-initial'; mode='signed_ok'; release=$true; custom=$false; prior=$false },
        @{ name='signed-debug-refused'; mode='signed_ok'; release=$false; custom=$false; prior=$true; refused=$true },
        @{ name='signed-cli-failure'; mode='signed_cli_fail'; release=$true; custom=$false; prior=$true },
        @{ name='signed-mcp-failure'; mode='signed_mcp_fail'; release=$true; custom=$false; prior=$true },
        @{ name='signed-invalid-refused'; mode='signed_invalid'; release=$true; custom=$false; prior=$true },
        @{ name='signed-other-cert-refused'; mode='signed_other_cert'; release=$true; custom=$false; prior=$true },
        @{ name='signed-policy-refused'; mode='signed_verify_fail'; release=$true; custom=$false; prior=$true },
        @{ name='signed-verify-mutation-refused'; mode='signed_verify_change'; release=$true; custom=$false; prior=$true },
        @{ name='signed-stage-mutation-refused'; mode='signed_changed'; release=$true; custom=$false; prior=$true },
        @{ name='signed-runtime-refused'; mode='signed_dynamic'; release=$true; custom=$false; prior=$true },
        @{ name='release-to-debug'; mode='ok'; release=$false; custom=$false; prior=$true; previousRelease=$true },
        @{ name='debug-to-release'; mode='ok'; release=$true; custom=$true; prior=$true; previousRelease=$false },
        @{ name='debug-license-stage-failure'; mode='stage_fail'; release=$false; custom=$false; prior=$true },
        @{ name='release-license-stage-failure'; mode='stage_fail'; release=$true; custom=$false; prior=$true },
        @{ name='debug-manifest-failure'; mode='manifest_fail'; release=$false; custom=$false; prior=$true },
        @{ name='release-manifest-failure'; mode='manifest_fail'; release=$true; custom=$false; prior=$true },
        @{ name='build-failure'; mode='build_fail'; release=$false; custom=$false; prior=$true },
        @{ name='version-mismatch'; mode='version_fail'; release=$false; custom=$false; prior=$true },
        @{ name='missing-cli'; mode='missing_cli'; release=$false; custom=$false; prior=$true },
        @{ name='missing-mcp'; mode='missing_mcp'; release=$false; custom=$false; prior=$true },
        @{ name='dynamic-cli-refused'; mode='dynamic_cli'; release=$false; custom=$false; prior=$true },
        @{ name='delayed-mcp-refused'; mode='delayed_mcp'; release=$true; custom=$false; prior=$true },
        @{ name='wrong-machine-refused'; mode='wrong_cpu'; release=$false; custom=$false; prior=$true },
        @{ name='build-flags-refused'; mode='flags_override'; release=$false; custom=$false; prior=$true },
        @{ name='empty-flags-refused-before-metadata'; mode='flags_empty'; release=$false; custom=$false; prior=$true },
        @{ name='empty-encoded-flags-refused-before-metadata'; mode='encoded_empty'; release=$true; custom=$false; prior=$true },
        @{ name='wrapper-alias-refused-before-metadata'; mode='wrapper_alias'; release=$false; custom=$false; prior=$true },
        @{ name='workspace-wrapper-alias-refused-before-metadata'; mode='workspace_wrapper_alias'; release=$true; custom=$false; prior=$true },
        @{ name='unmapped-import-refused'; mode='unmapped_import'; release=$false; custom=$false; prior=$true },
        @{ name='unmapped-delay-refused'; mode='unmapped_delay'; release=$true; custom=$false; prior=$true },
        @{ name='unmapped-iat-refused'; mode='unmapped_iat'; release=$false; custom=$false; prior=$true },
        @{ name='partial-iat-refused'; mode='partial_iat'; release=$true; custom=$false; prior=$true },
        @{ name='unknown-api-refused'; mode='unknown_api'; release=$false; custom=$false; prior=$true },
        @{ name='unknown-delay-api-refused'; mode='unknown_delay_api'; release=$true; custom=$false; prior=$true },
        @{ name='second-copy-failure'; mode='copy_mcp_fail'; release=$false; custom=$false; prior=$true },
        @{ name='publication-failure'; mode='publish_fail'; release=$false; custom=$false; prior=$true },
        @{ name='restoration-failure'; mode='rollback_fail'; release=$false; custom=$false; prior=$true },
        @{ name='concurrent-builder-refused'; mode='lock_fail'; release=$false; custom=$false; prior=$true },
        @{ name='initial-copy-failure'; mode='copy_mcp_fail'; release=$false; custom=$false; prior=$false },
        @{ name='initial-publication-failure'; mode='publish_fail'; release=$false; custom=$false; prior=$false },
        @{ name='wrong-package-artifact'; mode='wrong_package'; release=$false; custom=$false; prior=$true },
        @{ name='duplicate-artifact'; mode='duplicate_artifact'; release=$false; custom=$false; prior=$true },
        @{ name='wrong-artifact-path'; mode='wrong_path'; release=$false; custom=$false; prior=$true },
        @{ name='old-park-failure'; mode='park_old_fail'; release=$false; custom=$false; prior=$true },
        @{ name='readback-restored'; mode='readback_fail'; release=$false; custom=$false; prior=$true },
        @{ name='initial-readback-restored'; mode='readback_fail'; release=$false; custom=$false; prior=$false },
        @{ name='readback-park-failure'; mode='readback_park_fail'; release=$false; custom=$false; prior=$true },
        @{ name='initial-readback-park-failure'; mode='readback_park_fail'; release=$false; custom=$false; prior=$false },
        @{ name='readback-restore-failure'; mode='readback_restore_fail'; release=$false; custom=$false; prior=$true },
        @{ name='barrier-removal-failure'; mode='barrier_remove_fail'; release=$false; custom=$false; prior=$true },
        @{ name='initial-barrier-removal-failure'; mode='barrier_remove_fail'; release=$false; custom=$false; prior=$false },
        @{ name='existing-empty-barrier'; mode='pending'; release=$false; custom=$false; prior=$true }
    )
    foreach ($release in @($false,$true)) {
        foreach ($mode in @('profile_missing','assertions_missing','assertions_wrong','assertions_nonbool')) {
            $cases += @{name="profile-$release-$mode"; mode=$mode; release=$release; custom=$false; prior=$true}
            $cases += @{name="profile-$release-$mode-mcp"; mode=($mode+'_mcp'); release=$release; custom=$false; prior=$true}
        }
    }
    if ($SelectedCase) {
        $cases = @($cases | Where-Object { $_['name'] -ceq $SelectedCase })
        Assert-Outcome ($cases.Count -eq 1) 'Unknown targeted transaction case'
    }
    foreach ($case in $cases) {
        $root = Join-Path $outDir $case.name
        New-VersionFixture $root
        if ($case.mode -eq 'version_fail') {
            [IO.File]::WriteAllText((Join-Path $root 'winsmux-app/package.json'), '{"version":"0.37.0"}')
        }
        $tauri = Join-Path $root 'winsmux-app/src-tauri'
        $scriptDir = Join-Path $tauri 'scripts'
        [void][IO.Directory]::CreateDirectory($scriptDir)
        [IO.File]::WriteAllBytes((Join-Path $scriptDir 'prepare-companion-cli.ps1'), [IO.File]::ReadAllBytes($source))
        [IO.File]::WriteAllBytes((Join-Path $scriptDir 'sign-windows-bundle.ps1'), [IO.File]::ReadAllBytes((Join-Path $repoRoot 'winsmux-app/src-tauri/scripts/sign-windows-bundle.ps1')))
        [IO.File]::WriteAllText((Join-Path $root 'synthetic-signtool.ps1'), @'
# Synthetic command collaborator: no certificate, trust store or native signing.
$mode = $env:COMPANION_TEST_MODE
$asset = [string]$args[-1]
if ($args[0] -ceq 'sign') {
    if (($mode -ceq 'signed_cli_fail' -and $asset.EndsWith('winsmux.exe')) -or
        ($mode -ceq 'signed_mcp_fail' -and $asset.EndsWith('winsmux-workspace-mcp.exe'))) { $global:LASTEXITCODE=11; return }
    if ($mode -ceq 'signed_dynamic') {
        $nativeNode = Get-Command node -CommandType Application | Select-Object -First 1
        & $nativeNode.Source (Join-Path $env:COMPANION_TEST_ROOT 'fixture-pe.mjs') $asset 'signed-invalid-runtime' 'dynamic'
    } else { [IO.File]::AppendAllText($asset, 'signed-fixture') }
} elseif ($args[0] -ceq 'verify' -and $args[1] -ceq '/pa') {
    if ($mode -ceq 'signed_verify_fail') { $global:LASTEXITCODE=12; return }
    if ($mode -ceq 'signed_verify_change') { [IO.File]::AppendAllText($asset, 'changed') }
} else { throw 'Unexpected synthetic signing command' }
$global:LASTEXITCODE=0
'@)
        [IO.File]::WriteAllBytes((Join-Path $root 'child.ps1'), [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixture-child.ps1')))
        foreach ($helper in @('windows-distribution-build.mjs','assert-windows-runtime.mjs','distribution-prelaunch.mjs')) {
            [IO.File]::WriteAllBytes((Join-Path $root "scripts/$helper"), [IO.File]::ReadAllBytes((Join-Path $repoRoot "scripts/$helper")))
        }
        [IO.File]::WriteAllBytes((Join-Path $root 'fixture-pe.mjs'), [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixture-pe.mjs')))
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'core/.cargo'))
        [IO.File]::WriteAllBytes((Join-Path $root 'core/.cargo/config.toml'), [IO.File]::ReadAllBytes((Join-Path $repoRoot 'core/.cargo/config.toml')))
        $binaries = Join-Path $tauri 'binaries'
        if ($case.prior) {
            [void][IO.Directory]::CreateDirectory($binaries)
            foreach ($name in @('winsmux', 'winsmux-workspace-mcp')) {
                [IO.File]::WriteAllText((Join-Path $binaries "$name-x86_64-pc-windows-msvc.exe"), "old-$name")
            }
            [IO.File]::WriteAllText((Join-Path $binaries 'other-asset.txt'), 'retained')
            [void][IO.Directory]::CreateDirectory((Join-Path $binaries 'licenses'))
            [IO.File]::WriteAllText((Join-Path $binaries 'licenses/stale.txt'), 'old license')
            [IO.File]::WriteAllText((Join-Path $binaries 'distribution-manifest.json'), 'old manifest')
        }
        if ($case.ContainsKey('previousRelease')) {
            $previous = Invoke-Fixture $root 'ok' $case.previousRelease $case.custom
            Assert-Outcome ($previous.exit -eq 0) "Previous profile preparation failed: $($previous.stderr)"
        }
        $heldLock = $null
        if ($case.mode -eq 'pending') { [IO.File]::WriteAllText((Join-Path $tauri 'binaries.recovery.pending'), '') }
        try {
            if ($case.mode -eq 'lock_fail') {
                $heldLock = [IO.File]::Open((Join-Path $tauri 'binaries.prepare.lock'),
                    [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            }
            $actual = Invoke-Fixture $root $case.mode $case.release $case.custom
        } finally { if ($null -ne $heldLock) { $heldLock.Dispose() } }
        $success = $case.mode -in @('ok','signed_ok') -and -not $case['refused']
        Assert-Outcome (($actual.exit -eq 0) -eq $success) "Unexpected exit for $($case.name): $($actual.stderr)"
        Assert-Outcome ((Test-Path -LiteralPath (Join-Path $root 'bundle-started')) -eq $success) 'Bundle crossed a failed preparation'
        if ($success) {
            Assert-Pair $binaries 'new' -Signed:($case.mode -ceq 'signed_ok')
            $target = if ($case.custom) { 'custom-target' } else { 'target' }
            $profile = if ($case.release) { 'release' } else { 'debug' }
            foreach ($name in @('winsmux', 'winsmux-workspace-mcp')) {
                $built = Join-Path $root "$target/x86_64-pc-windows-msvc/$profile/$name.exe"
                $staged = Join-Path $binaries "$name-x86_64-pc-windows-msvc.exe"
                if ($case.mode -ceq 'signed_ok') {
                    $expected = [byte[]]([IO.File]::ReadAllBytes($built) + [Text.Encoding]::UTF8.GetBytes('signed-fixture'))
                    Assert-Outcome ([Convert]::ToHexString($expected) -ceq [Convert]::ToHexString([IO.File]::ReadAllBytes($staged))) 'Signed generation differs from frozen post-sign bytes'
                } else {
                    Assert-Outcome ((Get-FileHash $built).Hash -ceq (Get-FileHash $staged).Hash) 'Build/staging identity differs'
                }
                $bytes = [IO.File]::ReadAllBytes($staged)
                $marker = "new-$name-$profile"
                Assert-Outcome ([Text.Encoding]::UTF8.GetString($bytes,1900,$marker.Length) -ceq $marker) 'Stale or wrong companion profile'
            }
            if ($case.prior) { Assert-Outcome ([IO.File]::ReadAllText((Join-Path $binaries 'other-asset.txt')) -ceq 'retained') 'Unrelated asset changed' }
            Assert-Outcome (-not (Test-Path -LiteralPath (Join-Path $binaries 'licenses/stale.txt'))) 'Old license entered fresh generation'
            Assert-Outcome ([IO.File]::ReadAllText((Join-Path $binaries 'licenses/manifest.json')) -ceq 'synthetic licensed transaction generation') 'Fresh license generation is absent'
            $manifest = Get-Content -LiteralPath (Join-Path $binaries 'distribution-manifest.json') -Raw | ConvertFrom-Json
            Assert-Outcome ($manifest.build_profile -ceq $profile) 'Manifest build profile differs'
            foreach ($row in $manifest.files) {
                Assert-Outcome ((Get-FileHash -LiteralPath (Join-Path $binaries $row.path)).Hash.ToLowerInvariant() -ceq $row.sha256) 'Whole-generation manifest identity differs'
            }
            $argsObserved = Get-Content (Join-Path $root 'cargo.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
            Assert-Outcome (('--release' -cin $argsObserved) -eq $case.release) 'Selected Cargo profile differs'
            Assert-Outcome (('build' -in $argsObserved) -and ('--locked' -in $argsObserved) -and
                ('winsmux' -in $argsObserved) -and ('winsmux-workspace-mcp' -in $argsObserved) -and
                ('--manifest-path' -in $argsObserved) -and ('--target-dir' -in $argsObserved) -and ('--config' -in $argsObserved)) 'Companions did not share the locked build and fixed output authority'
            Assert-Outcome ((Join-Path $root 'core/.cargo/config.toml') -cin $argsObserved) 'Static CRT configuration did not reach Cargo'
        } elseif ($case.mode -in @('rollback_fail','readback_park_fail','readback_restore_fail','barrier_remove_fail')) {
            $canonicalPresent = $case.mode -in @('readback_park_fail','barrier_remove_fail')
            Assert-Outcome ((Test-Path -LiteralPath $binaries) -eq $canonicalPresent) 'Unexpected unresolved canonical state'
            Assert-Outcome (Test-Path -LiteralPath (Join-Path $tauri 'binaries.recovery.pending')) 'Missing unresolved barrier'
            $backups = @(Get-ChildItem -LiteralPath $tauri -Directory -Filter 'binaries.backup.*')
            Assert-Outcome ($backups.Count -eq [int]$case.prior) 'Original backup inventory differs'
            if ($case.prior) { Assert-Pair $backups[0].FullName 'old' }
            if ($canonicalPresent) { Assert-Pair $binaries 'new' }
            $logBefore = [IO.File]::ReadAllBytes((Join-Path $root 'cargo.jsonl'))
            $retry = Invoke-Fixture $root 'ok' $case.release $case.custom
            Assert-Outcome ($retry.exit -ne 0 -and $retry.stderr.Contains('recovery required')) 'Unresolved restoration was bypassed'
            Assert-Outcome ([Convert]::ToHexString($logBefore) -ceq [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $root 'cargo.jsonl')))) 'Retry built before recovery'
        } elseif ($case.prior) {
            Assert-Pair $binaries 'old'
            if ($case.mode -match '^(profile_|assertions_)') {
                Assert-Outcome (@(Get-ChildItem -LiteralPath $tauri -Directory -Filter 'binaries.stage.*').Count -eq 0) 'Wrong Cargo profile reached staging'
            }
            Assert-Outcome ([IO.File]::ReadAllText((Join-Path $binaries 'licenses/stale.txt')) -ceq 'old license') 'Failed generation changed old license'
            Assert-Outcome ([IO.File]::ReadAllText((Join-Path $binaries 'distribution-manifest.json')) -ceq 'old manifest') 'Failed generation changed old manifest'
            if ($case.mode -in @('flags_override','flags_empty','encoded_empty','wrapper_alias','workspace_wrapper_alias')) {
                Assert-Outcome (-not (Test-Path -LiteralPath (Join-Path $root 'metadata-reached.txt'))) 'Rejected environment reached Cargo metadata'
                Assert-Outcome (-not (Test-Path -LiteralPath (Join-Path $root 'cargo.jsonl'))) 'Rejected environment reached Cargo build'
                Assert-Outcome (-not (Test-Path -LiteralPath (Join-Path $tauri 'binaries.prepare.lock'))) 'Rejected environment wrote staging lease'
            }
            if ($case.mode -eq 'pending') {
                Assert-Outcome (-not (Test-Path -LiteralPath (Join-Path $root 'cargo.jsonl'))) 'Pending transaction reached build'
                Assert-Outcome (-not (Test-Path -LiteralPath (Join-Path $tauri 'binaries.prepare.lock'))) 'Pending transaction reached lease'
            } else {
                Assert-Outcome (-not (Test-Path -LiteralPath (Join-Path $tauri 'binaries.recovery.pending'))) 'Completed restoration left barrier'
            }
            if ($case.mode -eq 'version_fail') {
                Assert-Outcome (-not (Test-Path -LiteralPath (Join-Path $root 'cargo.jsonl'))) 'Version mismatch reached build'
                Assert-Outcome (-not (Test-Path -LiteralPath (Join-Path $tauri 'binaries.prepare.lock'))) 'Version mismatch reached staging lease'
            }
            if ($case.mode -eq 'lock_fail') {
                Assert-Outcome (-not (Test-Path -LiteralPath (Join-Path $root 'cargo.jsonl'))) 'Concurrent builder reached cargo'
                $retry = Invoke-Fixture $root 'ok' $case.release $case.custom
                Assert-Outcome ($retry.exit -eq 0) 'Released builder lock did not permit retry'
                Assert-Pair $binaries 'new'
            }
        } else {
            Assert-Outcome (-not (Test-Path -LiteralPath $binaries)) 'Initial failure left a canonical generation'
            $retry = Invoke-Fixture $root 'ok' $case.release $case.custom
            Assert-Outcome ($retry.exit -eq 0) "Initial retry failed: $($retry.stderr)"
            Assert-Pair $binaries 'new'
        }
        $results.Add(@{ name=$case.name; passed=$true; exit=$actual.exit; expected_success=$success })
        Write-Host "PASS $($case.name)"
    }
    $barrierProof = Join-Path $outDir 'barrier-faults'
    [void][IO.Directory]::CreateDirectory($barrierProof)
    & (Join-Path $PSScriptRoot 'barrier-fault.ps1') -ProducerSource $source -OutputDirectory $barrierProof
    $barriers = Get-Content -LiteralPath (Join-Path $barrierProof 'result.json') -Raw | ConvertFrom-Json
    Assert-Outcome $barriers.passed 'Barrier fault proof failed'
    foreach ($row in $barriers.results) { $results.Add($row); Write-Host "PASS $($row.name)" }
    $passed = $true
} catch {
    $passed = $false
    $failure = $_.Exception.Message
    [Console]::Error.WriteLine($failure)
}
$receipt = @{ schema='workspace-package-preparation/v1'; passed=$passed; results=@($results.ToArray());
    source_sha256=(Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant();
    gate_sha256=(Get-FileHash -LiteralPath (Join-Path $repoRoot 'scripts/assert-distribution-version.ps1')).Hash.ToLowerInvariant(); output_directory=$outDir }
if (-not $passed) { $receipt.failure = $failure }
[IO.File]::WriteAllText((Join-Path $outDir 'result.json'), ($receipt | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
Write-Host "Result: $outDir/result.json"
if (-not $passed) { exit 1 }
