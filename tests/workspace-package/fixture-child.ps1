# Executes the real preparation script with tools/faults confined to this fixture.
param([string]$Mode = 'ok', [switch]$Release, [switch]$CustomTarget)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:COMPANION_TEST_MODE = $Mode
$env:COMPANION_TEST_ROOT = $PSScriptRoot
$env:CARGO_TARGET_DIR = if ($CustomTarget) { Join-Path $PSScriptRoot 'custom-target' } else { $null }
if ($Mode -ceq 'flags_override') { $env:RUSTFLAGS = '-C target-feature=-crt-static' }
if ($Mode -ceq 'flags_empty') { $env:RUSTFLAGS = '' }
if ($Mode -ceq 'encoded_empty') { $env:CARGO_ENCODED_RUSTFLAGS = '' }
if ($Mode -ceq 'wrapper_alias') { $env:CARGO_BUILD_RUSTC_WRAPPER = 'fixture-wrapper-must-not-run.exe' }
if ($Mode -ceq 'workspace_wrapper_alias') { $env:CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER = 'fixture-wrapper-must-not-run.exe' }
function global:cargo {
    $buildArgs = @($args)
    if ($buildArgs[0] -eq 'metadata') {
        [IO.File]::WriteAllText((Join-Path $env:COMPANION_TEST_ROOT 'metadata-reached.txt'), 'reached')
        $nativeCargo = @(Get-Command cargo -CommandType Application | Where-Object Extension -EQ '.exe')
        if ($nativeCargo.Count -ne 1) { throw 'Native Cargo executable is missing or ambiguous.' }
        $metadataText = @(& $nativeCargo[0].Source @buildArgs)
        $global:LASTEXITCODE = $LASTEXITCODE
        $global:fixtureMetadata = ($metadataText -join "`n") | ConvertFrom-Json
        $metadataText
        return
    }
    [IO.File]::AppendAllText((Join-Path $env:COMPANION_TEST_ROOT 'cargo.jsonl'),
        ($buildArgs | ConvertTo-Json -Compress) + "`n", [Text.UTF8Encoding]::new($false))
    if ($env:COMPANION_TEST_MODE -eq 'build_fail') { $global:LASTEXITCODE = 9; return }
    $target = $buildArgs[[array]::IndexOf($buildArgs, '--target-dir') + 1]
    $triple = $buildArgs[[array]::IndexOf($buildArgs, '--target') + 1]
    $profile = if ('--release' -in $buildArgs) { 'release' } else { 'debug' }
    $output = Join-Path (Join-Path $target $triple) $profile
    [void][IO.Directory]::CreateDirectory($output)
    foreach ($name in @('winsmux', 'winsmux-workspace-mcp')) {
        if (($name -eq 'winsmux' -and $env:COMPANION_TEST_MODE -eq 'missing_cli') -or
            ($name -eq 'winsmux-workspace-mcp' -and $env:COMPANION_TEST_MODE -eq 'missing_mcp')) { continue }
        $peMode = if ($name -ceq 'winsmux' -and $Mode -ceq 'dynamic_cli') { 'dynamic' }
            elseif ($name -ceq 'winsmux-workspace-mcp' -and $Mode -ceq 'delayed_mcp') { 'delayed' }
            elseif ($Mode -ceq 'unmapped_import') { 'unmapped-import' }
            elseif ($Mode -ceq 'unmapped_delay') { 'unmapped-delay' }
            elseif ($Mode -ceq 'unmapped_iat') { 'unmapped-iat' }
            elseif ($Mode -ceq 'partial_iat') { 'partial-iat' }
            elseif ($Mode -ceq 'unknown_api') { 'unknown-api' }
            elseif ($Mode -ceq 'unknown_delay_api') { 'unknown-delay-api' }
            elseif ($Mode -ceq 'wrong_cpu') { 'wrong-cpu' } else { 'ok' }
        $nativeNode = Get-Command node -CommandType Application | Select-Object -First 1
        & $nativeNode.Source (Join-Path $PSScriptRoot 'fixture-pe.mjs') (Join-Path $output "$name.exe") "new-$name-$profile" $peMode
        if ($LASTEXITCODE -ne 0) { throw 'PE fixture construction failed.' }
        $package = $global:fixtureMetadata.packages | Where-Object name -CEQ $name
        $artifact = @{ reason='compiler-artifact'; package_id=$package.id; target=@{name=$name;kind=@('bin')}; executable=(Join-Path $output "$name.exe"); profile=@{debug_assertions=($profile -ceq 'debug')} }
        $profileFault = $Mode -replace '_mcp$', ''
        $faultTarget = if ($Mode.EndsWith('_mcp')) { 'winsmux-workspace-mcp' } else { 'winsmux' }
        if ($name -ceq $faultTarget) {
            if ($profileFault -ceq 'profile_missing') { $artifact.Remove('profile') }
            if ($profileFault -ceq 'assertions_missing') { $artifact.profile.Remove('debug_assertions') }
            if ($profileFault -ceq 'assertions_wrong') { $artifact.profile.debug_assertions = -not $artifact.profile.debug_assertions }
            if ($profileFault -ceq 'assertions_nonbool') { $artifact.profile.debug_assertions = 'false' }
        }
        if ($name -eq 'winsmux') {
            if ($env:COMPANION_TEST_MODE -eq 'wrong_package') { $artifact.package_id = 'unverified-package' }
            if ($env:COMPANION_TEST_MODE -eq 'wrong_path') { $artifact.executable = Join-Path $env:COMPANION_TEST_ROOT 'stale.exe' }
        }
        $artifact | ConvertTo-Json -Compress
        if ($name -eq 'winsmux' -and $env:COMPANION_TEST_MODE -eq 'duplicate_artifact') { $artifact | ConvertTo-Json -Compress }
    }
    $global:LASTEXITCODE = 0
}
function global:rustc { $global:LASTEXITCODE = 0; 'host: x86_64-pc-windows-msvc'; 'commit-hash: ac68faa20c58cbccd01ee7208bf3b6e93a7d7f96' }
function global:node {
    if ([IO.Path]::GetFileName([string]$args[0]) -cin @('windows-distribution-build.mjs','assert-windows-runtime.mjs')) {
        $nativeNode = Get-Command node -CommandType Application | Select-Object -First 1
        & $nativeNode.Source @args
        $global:LASTEXITCODE = $LASTEXITCODE
        return
    }
    # Synthetic staging collaborator for the existing transaction fault tests only.
    # The real Node producer and complete original license assets have their own executable proof.
    if ($args.Count -ne 2 -or [IO.Path]::GetFileName([string]$args[0]) -cne 'stage-bundled-distribution.mjs') { throw 'Unexpected fixture Node invocation' }
    $stageInput = Get-Content -LiteralPath $args[1] -Raw | ConvertFrom-Json
    if ($Mode -ceq 'signed_changed') { [IO.File]::AppendAllText($stageInput.companions[0].path, 'changed') }
    if ($Mode -ceq 'stage_fail') { $global:LASTEXITCODE = 7; return }
    [void][IO.Directory]::CreateDirectory($stageInput.destination)
    $old = Join-Path $stageInput.repoRoot 'winsmux-app/src-tauri/binaries'
    if (Test-Path -LiteralPath $old) { Copy-Item -LiteralPath (Join-Path $old 'other-asset.txt') -Destination (Join-Path $stageInput.destination 'other-asset.txt') }
    foreach ($companion in $stageInput.companions) {
        Copy-Item -LiteralPath $companion.path -Destination (Join-Path $stageInput.destination ($companion.name + '-' + $stageInput.host + '.exe'))
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $stageInput.destination 'licenses'))
    [IO.File]::WriteAllText((Join-Path $stageInput.destination 'licenses/manifest.json'), 'synthetic licensed transaction generation')
    $manifest = Join-Path $stageInput.destination 'distribution-manifest.json'
    $files = @(Get-ChildItem -LiteralPath $stageInput.destination -File -Recurse | ForEach-Object {
        @{path=[IO.Path]::GetRelativePath($stageInput.destination,$_.FullName).Replace('\','/');
          sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    [IO.File]::WriteAllText($manifest, (@{synthetic='transaction only'; build_profile=$stageInput.buildProfile; files=$files} | ConvertTo-Json -Depth 5))
    $global:LASTEXITCODE = 0
    $manifestHash = if ($Mode -ceq 'manifest_fail') { '0' * 64 } else { (Get-FileHash -LiteralPath $manifest).Hash.ToLowerInvariant() }
    @{status='distribution_generation_staged'; distribution_complete=$false; manifest_sha256=$manifestHash} | ConvertTo-Json -Compress
}
function global:Copy-Item {
    param([string]$LiteralPath, [string]$Destination, [switch]$Recurse, [switch]$Force)
    if ($env:COMPANION_TEST_MODE -eq 'copy_mcp_fail' -and
        [IO.Path]::GetFileName($LiteralPath) -eq 'winsmux-workspace-mcp.exe') { throw 'Injected second staging copy failure' }
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
}
function global:Move-Item {
    param([string]$LiteralPath, [string]$Destination)
    $leaf = [IO.Path]::GetFileName($LiteralPath)
    if ($env:COMPANION_TEST_MODE -eq 'park_old_fail' -and $leaf -eq 'binaries' -and -not $global:fixturePublished) { throw 'Injected old park failure' }
    if ($env:COMPANION_TEST_MODE -eq 'readback_park_fail' -and $leaf -eq 'binaries' -and $global:fixturePublished) { throw 'Injected new canonical park failure' }
    if ($env:COMPANION_TEST_MODE -in @('publish_fail', 'rollback_fail') -and $leaf.StartsWith('binaries.stage.')) {
        throw 'Injected generation publication failure'
    }
    if ($env:COMPANION_TEST_MODE -in @('rollback_fail','readback_restore_fail') -and $leaf.StartsWith('binaries.backup.')) {
        throw 'Injected original generation restoration failure'
    }
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
    if ($leaf.StartsWith('binaries.stage.')) { $global:fixturePublished = $true }
}
$global:fixturePublished = $false
$global:fixtureReadbackFailed = $false
function global:Get-FileHash {
    param([string]$LiteralPath, [string]$Algorithm = 'SHA256')
    if ($env:COMPANION_TEST_MODE -in @('readback_fail','readback_park_fail','readback_restore_fail') -and
        $global:fixturePublished -and -not $global:fixtureReadbackFailed -and
        [IO.Path]::GetDirectoryName($LiteralPath) -eq (Join-Path $env:COMPANION_TEST_ROOT 'winsmux-app/src-tauri/binaries')) {
        $global:fixtureReadbackFailed = $true
        throw 'Injected published readback failure'
    }
    Microsoft.PowerShell.Utility\Get-FileHash @PSBoundParameters
}
function global:Remove-Item {
    param([string]$LiteralPath, [switch]$Force, [switch]$Recurse)
    if ($env:COMPANION_TEST_MODE -eq 'barrier_remove_fail' -and $LiteralPath.EndsWith('binaries.recovery.pending')) { throw 'Injected barrier removal failure' }
    Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}
$scriptPath = Join-Path $PSScriptRoot 'winsmux-app/src-tauri/scripts/prepare-companion-cli.ps1'
if ($Mode.StartsWith('signed_')) {
    $env:WINSMUX_WINDOWS_SIGNING_CERTIFICATE_PATH = Join-Path $PSScriptRoot 'synthetic.pfx'
    $env:WINDOWS_SIGNING_CERTIFICATE_PASSWORD = 'synthetic-fixture-only'
    $env:WINSMUX_SIGNTOOL_EXE = Join-Path $PSScriptRoot 'synthetic-signtool.ps1'
    function global:Get-PfxCertificate { param($LiteralPath,$Password,[switch]$NoPromptForPassword); [pscustomobject]@{RawData=[byte[]](1,2,3)} }
    function global:Get-AuthenticodeSignature {
        param($LiteralPath)
        [pscustomobject]@{Status=$(if ($Mode -ceq 'signed_invalid') {'HashMismatch'} else {'Valid'});
            SignerCertificate=[pscustomobject]@{RawData=$(if ($Mode -ceq 'signed_other_cert') {[byte[]](4,5,6)} else {[byte[]](1,2,3)})}}
    }
}
try {
    & $scriptPath -Release:$Release -SignCompanions:($Mode.StartsWith('signed_'))
    # A fixture equivalent of the existing npm &&/beforeBuild continuation.
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'bundle-started'), 'yes')
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
