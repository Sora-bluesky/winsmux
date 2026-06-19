[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseNotesPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ReleaseNotesPath)) {
    throw "Release notes file not found: $ReleaseNotesPath"
}

$content = Get-Content -LiteralPath $ReleaseNotesPath -Raw -Encoding UTF8
$issues = New-Object System.Collections.Generic.List[string]

function Get-SectionBody {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    $escapedTitle = [regex]::Escape($Title)
    $match = [regex]::Match($Content, "(?ms)^##\s+$escapedTitle\s*$\r?\n(?<body>.*?)(?=^##\s+|\z)")
    if (-not $match.Success) {
        return $null
    }

    return [string]$match.Groups['body'].Value
}

function Count-Bullets {
    param(
        [AllowNull()]
        [string]$Text
    )

    return @(Get-Bullets -Text $Text).Count
}

function Get-Bullets {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    return @(
        foreach ($match in [regex]::Matches($Text, '(?m)^-\s+(?<text>\S.*)$')) {
            [string]$match.Groups['text'].Value.Trim()
        }
    )
}

$requiredSections = @(
    'Highlights',
    'Safety and operations',
    'Validation',
    'Full Changelog'
)

foreach ($section in $requiredSections) {
    if (-not [regex]::IsMatch($content, "(?m)^##\s+$([regex]::Escape($section))\s*$")) {
        $issues.Add("missing required section: $section")
    }
}

$nonWhitespaceLength = [regex]::Matches($content, '\S').Count
if ($nonWhitespaceLength -lt 1400) {
    $issues.Add('release notes are too terse; expected at least 1400 non-whitespace characters')
}

$highlightBody = Get-SectionBody -Content $content -Title 'Highlights'
if ((Count-Bullets -Text $highlightBody) -lt 3) {
    $issues.Add('Highlights must contain at least 3 concrete bullets')
}

$safetyBody = Get-SectionBody -Content $content -Title 'Safety and operations'
if ((Count-Bullets -Text $safetyBody) -lt 2) {
    $issues.Add('Safety and operations must contain at least 2 concrete bullets')
}

$validationBody = Get-SectionBody -Content $content -Title 'Validation'
if ((Count-Bullets -Text $validationBody) -lt 4) {
    $issues.Add('Validation must contain at least 4 command or workflow bullets')
}

$allBullets = @(Get-Bullets -Text $content)
$uniqueBullets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($bullet in $allBullets) {
    [void]$uniqueBullets.Add($bullet)
}
if ($uniqueBullets.Count -lt 9) {
    $issues.Add('release notes must contain at least 9 unique bullets')
}

$fullChangelogBody = Get-SectionBody -Content $content -Title 'Full Changelog'
if ($null -eq $fullChangelogBody -or $fullChangelogBody -notmatch 'https://github\.com/Sora-bluesky/winsmux/(compare|releases/tag)/') {
    $issues.Add('Full Changelog must link to the GitHub compare or release page')
}

if ($issues.Count -gt 0) {
    foreach ($issue in $issues) {
        Write-Error "[release-notes-quality] $issue" -ErrorAction Continue
    }

    exit 1
}

Write-Host "[release-notes-quality] passed: $ReleaseNotesPath"
