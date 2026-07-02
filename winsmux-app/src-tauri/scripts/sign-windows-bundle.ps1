param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$AssetPath
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

& $signtool sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com /f $env:WINSMUX_WINDOWS_SIGNING_CERTIFICATE_PATH /p $env:WINDOWS_SIGNING_CERTIFICATE_PASSWORD $AssetPath
if ($LASTEXITCODE -ne 0) {
    throw "signtool failed for $AssetPath"
}
