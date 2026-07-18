[CmdletBinding()]
param(
    [ValidateSet('Npm', 'Direct')]
    [string]$Route = 'Direct',
    [string]$RepositoryRoot = '',
    [string]$Version = '',
    [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("winsmux-install-redirected-" + [System.Guid]::NewGuid().ToString('N'))
$fixtureLocalBin = Join-Path $scratch 'home\.local\bin'
$fixtureBridgeBin = Join-Path $scratch 'home\.winsmux\bin'
$fixtureStateRoot = Join-Path $scratch 'home\.winsmux-install-state'
$fixtureUserPathFile = Join-Path $fixtureStateRoot 'user-path.txt'
$fixtureProfile = Join-Path $fixtureStateRoot 'Microsoft.PowerShell_profile.ps1'
$actualProfile = $PROFILE.CurrentUserAllHosts
$profileExisted = Test-Path -LiteralPath $actualProfile -PathType Leaf
$profileBeforeHash = if ($profileExisted) { (Get-FileHash -LiteralPath $actualProfile -Algorithm SHA256).Hash } else { '' }
$liveUserPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')

function Get-InstallOwnedStateManifest {
    $paths = @(
        (Join-Path $HOME '.winsmux\bin'),
        (Join-Path $HOME '.winsmux\backups'),
        (Join-Path $HOME '.winsmux\scripts'),
        (Join-Path $HOME '.winsmux\winsmux-core'),
        (Join-Path $HOME '.winsmux\version'),
        (Join-Path $HOME '.winsmux\install-profile'),
        (Join-Path $HOME '.winsmux\install-profile.json'),
        (Join-Path $HOME '.winsmux.conf'),
        (Join-Path $HOME '.local\bin\winsmux.exe'),
        (Join-Path $env:APPDATA 'winsmux'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\winsmux\winsmux.json')
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $paths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $item = Get-Item -LiteralPath $fullPath -Force
            $rows.Add([ordered]@{ path = $fullPath; kind = 'file'; length = $item.Length; sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash })
            continue
        }
        if (Test-Path -LiteralPath $fullPath -PathType Container) {
            $rows.Add([ordered]@{ path = $fullPath; kind = 'directory'; length = 0; sha256 = '' })
            foreach ($item in @(Get-ChildItem -LiteralPath $fullPath -Recurse -Force | Sort-Object FullName)) {
                if ($item.PSIsContainer) {
                    $rows.Add([ordered]@{ path = $item.FullName; kind = 'directory'; length = 0; sha256 = '' })
                } else {
                    $rows.Add([ordered]@{ path = $item.FullName; kind = 'file'; length = $item.Length; sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash })
                }
            }
            continue
        }
        $rows.Add([ordered]@{ path = $fullPath; kind = 'missing'; length = 0; sha256 = '' })
    }
    return @($rows)
}

function Remove-FixturePathEntry {
    param([AllowNull()][string]$CurrentPath, [Parameter(Mandatory = $true)][string]$FixturePath)

    $kept = @($CurrentPath -split ';' | Where-Object {
        -not [string]::Equals($_.Trim().TrimEnd('\'), $FixturePath.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
    })
    return ($kept -join ';')
}

function Remove-FixtureProfileBlock {
    param([Parameter(Mandatory = $true)][string]$ProfilePath, [Parameter(Mandatory = $true)][string]$FixtureBin)

    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) { return $false }
    $stream = [System.IO.FileStream]::new($ProfilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $originalBytes = [byte[]]::new([int]$stream.Length)
        $read = $stream.Read($originalBytes, 0, $originalBytes.Length)
        if ($read -ne $originalBytes.Length) { throw "Failed to read the complete redirected profile: $ProfilePath" }
        $encoding = [System.Text.UTF8Encoding]::new($false)
        $preamble = [byte[]]::new(0)
        if ($originalBytes.Length -ge 3 -and $originalBytes[0] -eq 0xEF -and $originalBytes[1] -eq 0xBB -and $originalBytes[2] -eq 0xBF) {
            $encoding = [System.Text.UTF8Encoding]::new($true)
            $preamble = $encoding.GetPreamble()
        } elseif ($originalBytes.Length -ge 2 -and $originalBytes[0] -eq 0xFF -and $originalBytes[1] -eq 0xFE) {
            $encoding = [System.Text.UnicodeEncoding]::new($false, $true)
            $preamble = $encoding.GetPreamble()
        } elseif ($originalBytes.Length -ge 2 -and $originalBytes[0] -eq 0xFE -and $originalBytes[1] -eq 0xFF) {
            $encoding = [System.Text.UnicodeEncoding]::new($true, $true)
            $preamble = $encoding.GetPreamble()
        }
        $current = $encoding.GetString($originalBytes, $preamble.Length, $originalBytes.Length - $preamble.Length)
        $line = '$env:PATH = "' + $FixtureBin + ';$env:PATH"'
        $pattern = '(?:\r?\n)?# winsmux\r?\n' + [regex]::Escape($line) + '(?:\r?\n)?'
        $regex = [regex]::new($pattern)
        $cleaned = $regex.Replace($current, '', 1)
        if ($cleaned -eq $current) {
            if ($current.Contains($FixtureBin, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Detected unrecognized redirected installer residue in profile: $ProfilePath"
            }
            return $false
        }

        $contentBytes = $encoding.GetBytes($cleaned)
        $bytes = [byte[]]::new($preamble.Length + $contentBytes.Length)
        [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
        [Array]::Copy($contentBytes, 0, $bytes, $preamble.Length, $contentBytes.Length)
        $stream.Position = 0
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    return $true
}

$stateBefore = @(Get-InstallOwnedStateManifest)
$nonce = [System.Guid]::NewGuid().ToString('N')
$runError = $null
$cleanupErrors = [System.Collections.Generic.List[string]]::new()
$summary = $null
$profileResidueRemoved = $false

try {
    $env:WINSMUX_REDIRECT_NONCE = $nonce
    $pwshCommand = Get-Command pwsh -All -ErrorAction Stop |
        Where-Object { $_.Source -notmatch '\\WindowsApps\\' } |
        Select-Object -First 1
    if ($null -eq $pwshCommand) {
        throw 'Redirected installer smoke requires a non-WindowsApps PowerShell 7 executable.'
    }
    $pwsh = $pwshCommand.Source
    $env:PATH = "$(Split-Path -Parent $pwsh);$env:PATH"
    $sourceCommit = (& git -C $repoRoot rev-parse HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'Redirected installer smoke requires a repository HEAD commit SHA.'
    }
    $arguments = @(
        '-NoProfile', '-File', (Join-Path $repoRoot 'scripts\test-install-e2e.ps1'),
        '-Route', $Route, '-RepositoryRoot', $repoRoot, '-ScratchRoot', $scratch,
        '-SourceCommit', $sourceCommit, '-AllowRedirectedLocal', '-RedirectNonce', $nonce
    )
    if (-not [string]::IsNullOrWhiteSpace($Version)) { $arguments += @('-Version', $Version) }
    $output = & $pwsh @arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "Redirected installer smoke failed with exit $exitCode`n$output" }
    $summary = $output | ConvertFrom-Json -Depth 10
} catch {
    $runError = $_
} finally {
    Remove-Item Env:WINSMUX_REDIRECT_NONCE -ErrorAction SilentlyContinue
    try {
        if (-not (Test-Path -LiteralPath $fixtureUserPathFile -PathType Leaf)) {
            if ($null -eq $runError) { throw 'Redirected installer did not record the isolated user PATH state.' }
        } else {
            $currentUserPath = Get-Content -LiteralPath $fixtureUserPathFile -Raw -Encoding UTF8
            $cleanedUserPath = Remove-FixturePathEntry -CurrentPath $currentUserPath -FixturePath $fixtureLocalBin
            [System.IO.File]::WriteAllText($fixtureUserPathFile, $cleanedUserPath, [System.Text.UTF8Encoding]::new($false))
            if (($cleanedUserPath -split ';') -contains $fixtureLocalBin) {
                throw 'Redirected native path remains in the user PATH after cleanup.'
            }
        }
    } catch {
        $cleanupErrors.Add("PATH cleanup: $($_.Exception.Message)")
    }
    try {
        if (Test-Path -LiteralPath $fixtureProfile -PathType Leaf) {
            $profileResidueRemoved = Remove-FixtureProfileBlock -ProfilePath $fixtureProfile -FixtureBin $fixtureBridgeBin
        } elseif ($null -eq $runError) {
            throw 'Redirected installer did not record the isolated PowerShell profile state.'
        }
    } catch {
        $cleanupErrors.Add("profile cleanup: $($_.Exception.Message)")
    }
}

$invariantErrors = [System.Collections.Generic.List[string]]::new()
$profileAfterHash = ''
try {
    $liveUserPathAfter = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($liveUserPathAfter -cne $liveUserPathBefore) {
        throw 'Redirected installer changed the live user PATH.'
    }
} catch { $invariantErrors.Add("live PATH invariant: $($_.Exception.Message)") }
try {
    $profileAfterExists = Test-Path -LiteralPath $actualProfile -PathType Leaf
    $profileAfterHash = if ($profileAfterExists) { (Get-FileHash -LiteralPath $actualProfile -Algorithm SHA256).Hash } else { '' }
    if ($profileAfterExists -ne $profileExisted -or $profileAfterHash -cne $profileBeforeHash) {
        throw 'Redirected installer changed the live PowerShell profile.'
    }
} catch { $invariantErrors.Add("live profile invariant: $($_.Exception.Message)") }
try {
    $stateAfter = @(Get-InstallOwnedStateManifest)
    $stateBeforeJson = $stateBefore | ConvertTo-Json -Depth 5 -Compress
    $stateAfterJson = $stateAfter | ConvertTo-Json -Depth 5 -Compress
    if ($stateAfterJson -cne $stateBeforeJson) {
        throw 'Redirected smoke changed an install-owned live path outside the redirected scratch root.'
    }
} catch { $invariantErrors.Add("live install-state invariant: $($_.Exception.Message)") }

$failureParts = [System.Collections.Generic.List[string]]::new()
if ($null -ne $runError) { $failureParts.Add("run: $($runError.Exception.Message)") }
foreach ($errorText in $cleanupErrors) { $failureParts.Add($errorText) }
foreach ($errorText in $invariantErrors) { $failureParts.Add($errorText) }
if ($failureParts.Count -gt 0) {
    throw "Redirected installer smoke failed: $($failureParts -join '; ')"
}
if ((Get-Content -LiteralPath $fixtureProfile -Raw).Contains($fixtureBridgeBin, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Redirected installer left its bridge path in the isolated PowerShell profile.'
}

$evidence = [ordered]@{
    schema_version = 1
    route = $Route
    redirected_run = $summary
    isolated_user_path_residue_removed = $true
    isolated_profile_residue_removed = $profileResidueRemoved
    live_user_path_untouched = $true
    live_profile_untouched = $true
    profile_preexisting_hash = $profileBeforeHash
    profile_post_cleanup_hash = $profileAfterHash
    install_owned_live_state_preserved = $true
    scratch_root = $scratch
}
$json = $evidence | ConvertTo-Json -Depth 8
if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    $resolvedEvidence = [System.IO.Path]::GetFullPath($EvidencePath)
    $parent = Split-Path -Parent $resolvedEvidence
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($resolvedEvidence, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}
$json
