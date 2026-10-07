param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$AssetPath,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:WINSMUX_WINDOWS_SIGNING_CERTIFICATE_PATH)) {
    throw 'WINSMUX_WINDOWS_SIGNING_CERTIFICATE_PATH is required for CI Windows signing.'
}

if ([string]::IsNullOrWhiteSpace($env:WINDOWS_SIGNING_CERTIFICATE_PASSWORD)) {
    throw 'WINDOWS_SIGNING_CERTIFICATE_PASSWORD is required for CI Windows signing.'
}

$signtool = $env:WINSMUX_SIGNTOOL_EXE
if ([string]::IsNullOrWhiteSpace($signtool)) {
    $signtool = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
        Select-Object -First 1 -ExpandProperty FullName
}

if ([string]::IsNullOrWhiteSpace($signtool) -or -not (Test-Path -LiteralPath $signtool -PathType Leaf)) {
    throw 'signtool.exe was not found for CI Windows signing.'
}

if (-not (Test-Path -LiteralPath $AssetPath -PathType Leaf)) {
    throw "Windows signing asset was not found: $AssetPath"
}

$before = (Get-FileHash -LiteralPath $AssetPath -Algorithm SHA256).Hash
if (-not $VerifyOnly) {
    & $signtool sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com /f $env:WINSMUX_WINDOWS_SIGNING_CERTIFICATE_PATH /p $env:WINDOWS_SIGNING_CERTIFICATE_PASSWORD $AssetPath
    if ($LASTEXITCODE -ne 0) { throw 'Windows asset signing failed.' }
}
$signedHash = (Get-FileHash -LiteralPath $AssetPath -Algorithm SHA256).Hash
$password = ConvertTo-SecureString -String $env:WINDOWS_SIGNING_CERTIFICATE_PASSWORD -AsPlainText -Force
$expected = Get-PfxCertificate -LiteralPath $env:WINSMUX_WINDOWS_SIGNING_CERTIFICATE_PATH -Password $password -NoPromptForPassword
try {
    $signature = Get-AuthenticodeSignature -LiteralPath $AssetPath
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $null -eq $expected -or
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($signature.SignerCertificate.RawData)) -cne
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expected.RawData))) {
        throw 'Windows asset signature or expected signer differs.'
    }
    & $signtool verify /pa $AssetPath
    if ($LASTEXITCODE -ne 0) { throw 'Windows signature policy verification failed.' }
    $after = (Get-FileHash -LiteralPath $AssetPath -Algorithm SHA256).Hash
    if ($after -cne $signedHash -or ($VerifyOnly -and $after -cne $before)) {
        throw 'Windows asset changed during signature verification.'
    }
} finally {
    if ($expected -is [IDisposable]) { $expected.Dispose() }
    $password.Dispose()
}
