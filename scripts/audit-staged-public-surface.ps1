[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'audit-staged-public-surface: failed to determine repository root.'
}

Set-Location -LiteralPath $repoRoot

function Test-IsPublicMaterialScanSurface {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('\', '/')
    if ($normalized -match '^docs/internal/') { return $false }
    if ($normalized -match '^\.') { return $false }
    return $normalized -match '(^README(\.ja)?\.md$)|(^docs/.+\.md$)|(^core/docs/.+\.md$)|(^packages/winsmux/README\.md$)'
}

function Test-IsReservedEmailDomain {
    param([Parameter(Mandatory = $true)][string]$Domain)

    $normalized = $Domain.Trim().TrimEnd('.').ToLowerInvariant()
    if ($normalized -in @('example.com', 'example.net', 'example.org')) { return $true }
    return $normalized -match '(^|\.)((example)|(invalid)|(test)|(localhost))$'
}

function Test-ContentContainsPersonalEmail {
    param([Parameter(Mandatory = $true)][string]$Content)

    $emailPattern = '(?i)\b[A-Z0-9._%+\-]+@([A-Z0-9.\-]+\.[A-Z]{2,})\b'
    $matches = [Regex]::Matches($Content, $emailPattern)
    foreach ($match in $matches) {
        $domain = $match.Groups[1].Value
        if (-not (Test-IsReservedEmailDomain -Domain $domain)) {
            return $true
        }
    }
    return $false
}

function Test-IsAllowedPublicLocalPathExample {
    param([Parameter(Mandatory = $true)][string]$Value)

    $normalized = $Value.Trim().TrimEnd('.', ',', ';', ':', ')', ']', '}').Replace('/', '\')
    if ($normalized -match '(?i)^C:\\path\\to(?:\\|$)') { return $true }
    if ($normalized -match '(?i)^C:\\Program(?:\\|$)') { return $true }
    if ($normalized -match '(?i)^C:\\Users\\me(?:\\|$)') { return $true }
    if ($normalized -match '(?i)^C:\\project(?:\\|$|>)') { return $true }
    if ($normalized -match '(?i)^[GW]:\\winsmux-local-llm(?:\\|$)') { return $true }
    return $false
}

function Test-ContentContainsGoogleDriveUrl {
    param([Parameter(Mandatory = $true)][string]$Content)

    $googleDriveUrlPattern = '(?i)https?://(?:drive|docs)\.google\.com/(?:drive/(?:u/\d+/)?folders/|file/d/|open\?id=|uc\?id=|document/d/|spreadsheets/d/|presentation/d/)[A-Za-z0-9_-]{10,}'
    return $Content -match $googleDriveUrlPattern
}

function Test-ContentContainsPrivateLocalPath {
    param([Parameter(Mandatory = $true)][string]$Content)

    $localPathPattern = '(?i)\b[A-Z]:[\\/][^\s`''"<>|]+'
    foreach ($match in [Regex]::Matches($Content, $localPathPattern)) {
        if (-not (Test-IsAllowedPublicLocalPathExample -Value ([string]$match.Value))) {
            return $true
        }
    }
    return $false
}

$stagedFiles = @(
    & git diff --cached --name-only --diff-filter=ACMR -- 2>$null |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($LASTEXITCODE -ne 0) {
    throw 'audit-staged-public-surface: failed to list staged files.'
}

$failures = New-Object System.Collections.Generic.List[string]
foreach ($file in ($stagedFiles | Where-Object { Test-IsPublicMaterialScanSurface -Path $_ })) {
    $content = (& git show --textconv ":$file" 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "audit-staged-public-surface: failed to read staged content for $file."
    }

    if (Test-ContentContainsPersonalEmail -Content $content) {
        $failures.Add("staged public material contains non-reserved email address: $file")
    }
    if (Test-ContentContainsGoogleDriveUrl -Content $content) {
        $failures.Add("staged public material contains a Google Drive document or folder URL: $file")
    }
    if (Test-ContentContainsPrivateLocalPath -Content $content) {
        $failures.Add("staged public material contains a local absolute path: $file")
    }
}

if ($failures.Count -gt 0) {
    Write-Error ("audit-staged-public-surface blocked:`n- " + ($failures -join "`n- "))
    exit 1
}

Write-Output 'audit-staged-public-surface passed'
