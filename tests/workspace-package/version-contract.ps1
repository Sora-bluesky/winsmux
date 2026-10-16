#requires -Version 7.0
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function New-VersionFixture([string]$Root, [string]$Version = '0.38.0') {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $files = @{
        'VERSION' = "$Version`n"
        'Cargo.toml' = "[workspace]`nmembers = [`"core`", `"core/crates/winsmux-workspace-mcp`", `"winsmux-app/src-tauri`"]`nresolver = `"2`"`n"
        'Cargo.lock' = "version = 4`n`n[[package]]`nname = `"winsmux`"`nversion = `"$Version`"`n`n[[package]]`nname = `"winsmux-app`"`nversion = `"$Version`"`n`n[[package]]`nname = `"winsmux-workspace-mcp`"`nversion = `"$Version`"`n"
        'install.ps1' = "`$VERSION = `"$Version`"`n"
        'winsmux-app/package.json' = "{`"version`":`"$Version`"}"
        'winsmux-app/package-lock.json' = "{`"version`":`"$Version`",`"packages`":{`"`":{`"version`":`"$Version`"}}}"
        'winsmux-app/src-tauri/tauri.conf.json' = "{`"version`":`"$Version`"}"
    }
    foreach ($entry in @(@('winsmux','core'), @('winsmux-app','winsmux-app/src-tauri'), @('winsmux-workspace-mcp','core/crates/winsmux-workspace-mcp'))) {
        $files["$($entry[1])/Cargo.toml"] = "[package]`nname = `"$($entry[0])`"`nversion = `"$Version`"`nedition = `"2021`"`n"
        $files["$($entry[1])/src/main.rs"] = 'fn main() {}'
    }
    foreach ($relative in $files.Keys) {
        $destination = Join-Path $Root $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        [IO.File]::WriteAllText($destination, $files[$relative], $utf8)
    }
    $gate = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../scripts/assert-distribution-version.ps1'))
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'scripts'))
    [IO.File]::WriteAllBytes((Join-Path $Root 'scripts/assert-distribution-version.ps1'), [IO.File]::ReadAllBytes($gate))
    [IO.File]::WriteAllBytes((Join-Path $Root 'scripts/distribution-prelaunch.mjs'), [IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $gate) 'distribution-prelaunch.mjs')))
}
if ($LibraryOnly) { return }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$out = Join-Path $repoRoot ('.evidence/workspace-package/version-' + [Guid]::NewGuid().ToString('N'))
$results = [Collections.Generic.List[object]]::new()
$cases = @('valid', 'prerelease', 'missing-lock', 'stale-lock', 'invalid-lock', 'cli-version', 'mcp-version',
    'app-version', 'frontend-version', 'frontend-lock', 'tauri-version', 'installer-version', 'duplicate-json', 'invalid-version')
foreach ($case in $cases) {
    $root = Join-Path $out $case
    $version = if ($case -eq 'prerelease') { '0.38.0-rc.1' } else { '0.38.0' }
    New-VersionFixture $root $version
    $path = $null
    switch ($case) {
        'missing-lock' { [IO.File]::Move((Join-Path $root 'Cargo.lock'), (Join-Path $root 'retained.lock')) }
        'stale-lock' { $path='Cargo.lock' }
        'invalid-lock' { [IO.File]::WriteAllText((Join-Path $root 'Cargo.lock'), 'not = [valid') }
        'cli-version' { $path='core/Cargo.toml' }
        'mcp-version' { $path='core/crates/winsmux-workspace-mcp/Cargo.toml' }
        'app-version' { $path='winsmux-app/src-tauri/Cargo.toml' }
        'frontend-version' { $path='winsmux-app/package.json' }
        'frontend-lock' { $path='winsmux-app/package-lock.json' }
        'tauri-version' { $path='winsmux-app/src-tauri/tauri.conf.json' }
        'installer-version' { $path='install.ps1' }
        'invalid-version' { [IO.File]::WriteAllText((Join-Path $root 'VERSION'), '0.38.0-01') }
        'duplicate-json' { [IO.File]::WriteAllText((Join-Path $root 'winsmux-app/package.json'), '{"version":"0.38.0","version":"0.38.0"}') }
    }
    if ($path) { $file=Join-Path $root $path; [IO.File]::WriteAllText($file, [IO.File]::ReadAllText($file).Replace('0.38.0','0.37.0')) }
    $lock = Join-Path $root 'Cargo.lock'
    $before = if ([IO.File]::Exists($lock)) { [Convert]::ToHexString([IO.File]::ReadAllBytes($lock)) } else { $null }
    $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    foreach ($arg in @('-NoLogo','-NoProfile','-File',(Join-Path $root 'scripts/assert-distribution-version.ps1'),'-RepoRoot',$root)) { $start.ArgumentList.Add($arg) }
    $start.WorkingDirectory=$root; $start.UseShellExecute=$false; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.Environment['CARGO_NET_OFFLINE']='true'
    $process=[Diagnostics.Process]::Start($start)
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
    $expected=$case -in @('valid','prerelease')
    $actual=$process.ExitCode
    [IO.File]::WriteAllText((Join-Path $root 'stdout.txt'),$stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText((Join-Path $root 'stderr.txt'),$stderr.GetAwaiter().GetResult())
    $process.Dispose()
    $after=if ([IO.File]::Exists($lock)) { [Convert]::ToHexString([IO.File]::ReadAllBytes($lock)) } else { $null }
    if (($actual -eq 0) -ne $expected -or $before -cne $after) { throw "Version proof failed: $case (exit $actual)" }
    $results.Add(@{name=$case; passed=$true; exit=$actual; lock_unchanged=$true})
    Write-Host "PASS $case"
}
[IO.File]::WriteAllText((Join-Path $out 'result.json'), (@{passed=$true; results=@($results.ToArray())} | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
Write-Host "Result: $out/result.json"
