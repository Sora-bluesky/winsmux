param()

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
    [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -or
    [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    throw 'Legacy CLI proof requires an isolated GitHub Windows runner'
}

$expectedHash = 'a9955ecda181af710f98ff543b37705699dfacb94a64fbf77f67d8ebd8271724'
$destination = Join-Path $env:RUNNER_TEMP 'winsmux-legacy-cli-v03628'
if (Test-Path -LiteralPath $destination) {
    throw 'Legacy CLI destination already exists'
}
[IO.Directory]::CreateDirectory($destination) | Out-Null

& gh release download v0.36.28 --repo Sora-bluesky/winsmux --pattern winsmux-x64.exe --dir $destination
if ($LASTEXITCODE -ne 0) { throw 'Legacy CLI release download failed' }
$downloaded = Join-Path $destination 'winsmux-x64.exe'
if (-not [IO.File]::Exists($downloaded) -or
    (Get-FileHash -LiteralPath $downloaded -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedHash) {
    throw 'Legacy CLI release bytes differ from pinned SHA-256'
}

$legacy = Join-Path $destination 'winsmux.exe'
Copy-Item -LiteralPath $downloaded -Destination $legacy -ErrorAction Stop
if ((Get-FileHash -LiteralPath $legacy -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedHash) {
    throw 'Legacy CLI renamed copy differs from pinned SHA-256'
}
$version = (& $legacy --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $version -cne 'winsmux 0.36.28') {
    throw 'Legacy CLI version proof failed'
}
[IO.File]::AppendAllText($env:GITHUB_ENV, "TASK870_ROLLBACK_CLI=$legacy`n",
    [Text.UTF8Encoding]::new($false))
Write-Output 'Pinned v0.36.28 CLI prepared for native version-pair proof'
