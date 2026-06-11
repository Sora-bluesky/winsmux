[CmdletBinding()]
param(
    [string]$ReleaseNotesPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'audit-public-surface: failed to determine repository root.'
}

Set-Location -LiteralPath $repoRoot

function Get-TrackedFiles {
    $files = @(
        & git ls-files -- 2>$null |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($LASTEXITCODE -ne 0) {
        throw 'audit-public-surface: failed to list tracked files.'
    }

    return $files
}

function Test-IsPublicDoc {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('\', '/')
    return $normalized -in @(
        'README.md',
        'README.ja.md',
        'THIRD_PARTY_NOTICES.md',
        'docs/README.md',
        'docs/README.ja.md',
        'docs/brand-hero.svg',
        'docs/operator-model.md',
        'docs/quickstart.md',
        'docs/quickstart.ja.md',
        'docs/installation.md',
        'docs/installation.ja.md',
        'docs/customization.md',
        'docs/customization.ja.md',
        'docs/TROUBLESHOOTING.md',
        'docs/TROUBLESHOOTING.ja.md',
        'packages/winsmux/README.md'
    )
}

function Test-IsExternalProductReferenceAuditSurface {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('\', '/')
    if ($normalized -eq 'THIRD_PARTY_NOTICES.md') { return $false }
    if (Test-IsPublicDoc -Path $Path) { return $true }
    if ($normalized -match '^docs/[^/]+\.md$') { return $true }
    return $normalized -match '^core/docs/.+\.md$'
}

function Test-IsTrackedTextSurface {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('\', '/')
    if ($normalized -match '^\.claude/logs/') { return $false }
    if ($normalized -match '^docs/internal/') { return $false }
    if ($normalized -eq 'docs/brand-hero.svg') { return $true }
    return $normalized -match '(^README(\.ja)?\.md$)|(^AGENTS?(-BASE)?\.md$)|(^GEMINI\.md$)|(^docs/.+\.md$)|(^\.claude/CLAUDE\.md$)|(^\.agents/.+\.md$)|(^tests/.+\.(ps1|md|json|txt)$)|(^workers/colab/.+\.py$)|(^\.github/workflows/.+\.ya?ml$)|(^\.githooks/.+$)|(^scripts/.+\.ps1$)'
}

function Test-IsPublicMaterialScanSurface {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('\', '/')
    if ($normalized -match '^docs/internal/') { return $false }
    if ($normalized -match '^\.') { return $false }
    return $normalized -match '(^README(\.ja)?\.md$)|(^docs/.+\.md$)|(^core/docs/.+\.md$)|(^packages/winsmux/README\.md$)'
}

function Test-IsMaintainerPathScanSurface {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('\', '/')
    if ($normalized -match '^tests/') { return $false }
    if ($normalized -match '^scripts/') { return $false }
    if ($normalized -match '^\.githooks/') { return $false }
    if ($normalized -match '^\.github/workflows/') { return $false }
    if ($normalized -eq 'docs/repo-surface-policy.md') { return $false }
    return Test-IsTrackedTextSurface -Path $Path
}

function Test-IsMaintainerIdentityScanSurface {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('\', '/')
    if ($normalized -in @(
        'docs/repo-surface-policy.md',
        'scripts/audit-public-surface.ps1',
        'scripts/git-guard.ps1'
    )) {
        return $false
    }
    return Test-IsTrackedTextSurface -Path $Path
}

function Get-ForbiddenExternalProductReferencePatterns {
    return @(
        [pscustomobject]@{ Name = 'Visual Studio Code'; Pattern = '(?i)(?<![A-Za-z0-9])Visual Studio Code(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'VS Code'; Pattern = '(?i)(?<![A-Za-z0-9])VS Code(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'vscode'; Pattern = '(?i)(?<![A-Za-z0-9])vscode(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Cursor'; Pattern = '(?i)(?<![A-Za-z0-9])Cursor(?:[- ](?:AI|agent|editor|IDE|workbench)| style workbench)(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Windsurf'; Pattern = '(?i)(?<![A-Za-z0-9])Windsurf(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'JetBrains'; Pattern = '(?i)(?<![A-Za-z0-9])JetBrains(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'IntelliJ'; Pattern = '(?i)(?<![A-Za-z0-9])IntelliJ(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'WebStorm'; Pattern = '(?i)(?<![A-Za-z0-9])WebStorm(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'PyCharm'; Pattern = '(?i)(?<![A-Za-z0-9])PyCharm(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Rider'; Pattern = '(?<![A-Za-z0-9])Rider(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'CLion'; Pattern = '(?i)(?<![A-Za-z0-9])CLion(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'GoLand'; Pattern = '(?i)(?<![A-Za-z0-9])GoLand(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'PhpStorm'; Pattern = '(?i)(?<![A-Za-z0-9])PhpStorm(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Android Studio'; Pattern = '(?i)(?<![A-Za-z0-9])Android Studio(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Eclipse'; Pattern = '(?<![A-Za-z0-9])Eclipse(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'NetBeans'; Pattern = '(?i)(?<![A-Za-z0-9])NetBeans(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Zed'; Pattern = '(?<![A-Za-z0-9])Zed(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Sublime Text'; Pattern = '(?i)(?<![A-Za-z0-9])Sublime Text(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Neovim'; Pattern = '(?i)(?<![A-Za-z0-9])Neovim(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Warp'; Pattern = '(?<![A-Za-z0-9])Warp(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'WezTerm'; Pattern = '(?i)(?<![A-Za-z0-9])WezTerm(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Alacritty'; Pattern = '(?i)(?<![A-Za-z0-9])Alacritty(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'iTerm2'; Pattern = '(?i)(?<![A-Za-z0-9])iTerm2(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Hyper terminal'; Pattern = '(?i)(?<![A-Za-z0-9])Hyper terminal(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Tabby'; Pattern = '(?i)(?<![A-Za-z0-9])Tabby(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'ConEmu'; Pattern = '(?i)(?<![A-Za-z0-9])ConEmu(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Cmder'; Pattern = '(?i)(?<![A-Za-z0-9])Cmder(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'OpenHands'; Pattern = '(?i)(?<![A-Za-z0-9])OpenHands(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Devin'; Pattern = '(?<![A-Za-z0-9])Devin(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Cline'; Pattern = '(?i)(?<![A-Za-z0-9])Cline(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'Roo Code'; Pattern = '(?i)(?<![A-Za-z0-9])Roo Code(?![A-Za-z0-9])' }
    )
}

function Get-ForbiddenPaidSourceDisclosurePatterns {
    return @(
        [pscustomobject]@{ Name = 'Substack'; Pattern = '(?i)(?<![A-Za-z0-9])Substack(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'paid-member'; Pattern = '(?i)(?<![A-Za-z0-9])paid[- ]member(?:s)?(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'member-only'; Pattern = '(?i)(?<![A-Za-z0-9])member[- ]only(?![A-Za-z0-9])' },
        [pscustomobject]@{ Name = 'member source program'; Pattern = '(?i)(member source program|source community|member community program)' },
        [pscustomobject]@{ Name = 'paid source access'; Pattern = '(?i)paid.{0,40}source access' },
        [pscustomobject]@{ Name = 'Japanese paid member'; Pattern = '有料会員' },
        [pscustomobject]@{ Name = 'Japanese member-only'; Pattern = '会員限定' },
        [pscustomobject]@{ Name = 'Japanese source community'; Pattern = 'ソースコミュニティ' },
        [pscustomobject]@{ Name = 'Japanese limited community'; Pattern = '限定コミュニティ' }
    )
}

function Test-IsReservedEmailDomain {
    param([Parameter(Mandatory = $true)][string]$Domain)

    $normalized = $Domain.Trim().TrimEnd('.').ToLowerInvariant()
    if ($normalized -in @('example.com', 'example.net', 'example.org', 'example.invalid')) { return $true }
    return $normalized -match '(^|\.)((example)|(invalid)|(test)|(localhost))$'
}

function Add-PersonalEmailFailures {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Surface
    )

    $fullPath = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $repoRoot $Path }
    if (-not (Test-Path -LiteralPath $fullPath)) {
        $failures.Add("$Surface path does not exist: $Path")
        return
    }

    $content = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
    $emailPattern = '(?i)\b[A-Z0-9._%+\-]+@([A-Z0-9.\-]+\.[A-Z]{2,})\b'
    $matches = [Regex]::Matches($content, $emailPattern)
    foreach ($match in $matches) {
        $domain = $match.Groups[1].Value
        if (-not (Test-IsReservedEmailDomain -Domain $domain)) {
            $failures.Add("$Surface contains non-reserved email address: $Path")
            return
        }
    }
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

function Add-PrivateRuntimeReferenceFailures {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Surface
    )

    $normalizedPath = $Path.Replace('\', '/')
    if ($normalizedPath -eq 'docs/repo-surface-policy.md') {
        return
    }

    $fullPath = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $repoRoot $Path }
    if (-not (Test-Path -LiteralPath $fullPath)) {
        $failures.Add("$Surface path does not exist: $Path")
        return
    }

    $content = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
    $googleDriveUrlPattern = '(?i)https?://(?:drive|docs)\.google\.com/(?:drive/(?:u/\d+/)?folders/|file/d/|open\?id=|uc\?id=|document/d/|spreadsheets/d/|presentation/d/)[A-Za-z0-9_-]{10,}'
    if ($content -match $googleDriveUrlPattern) {
        $failures.Add("$Surface contains a Google Drive document or folder URL: $Path")
        return
    }

    $localPathPattern = '(?i)\b[A-Z]:[\\/][^\s`''"<>|]+'
    foreach ($match in [Regex]::Matches($content, $localPathPattern)) {
        $candidate = [string]$match.Value
        if (-not (Test-IsAllowedPublicLocalPathExample -Value $candidate)) {
            $failures.Add("$Surface contains a local absolute path: $Path")
            return
        }
    }
}

function Add-ForbiddenExternalProductReferenceFailures {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Surface
    )

    $fullPath = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $repoRoot $Path }
    if (-not (Test-Path -LiteralPath $fullPath)) {
        $failures.Add("$Surface path does not exist: $Path")
        return
    }

    $content = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
    foreach ($reference in Get-ForbiddenExternalProductReferencePatterns) {
        if ($content -match $reference.Pattern) {
            $failures.Add("$Surface contains forbidden external product/reference name '$($reference.Name)': $Path")
        }
    }
}

function Add-ForbiddenPaidSourceDisclosureFailures {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Surface
    )

    $fullPath = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $repoRoot $Path }
    if (-not (Test-Path -LiteralPath $fullPath)) {
        $failures.Add("$Surface path does not exist: $Path")
        return
    }

    $content = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
    foreach ($reference in Get-ForbiddenPaidSourceDisclosurePatterns) {
        if ($content -match $reference.Pattern) {
            $failures.Add("$Surface contains paid-source disclosure strategy '$($reference.Name)': $Path")
        }
    }
}

$failures = New-Object System.Collections.Generic.List[string]

$trackedIgnored = @(
    & git ls-files -ci --exclude-standard 2>$null |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($LASTEXITCODE -ne 0) {
    throw 'audit-public-surface: failed to evaluate tracked/ignore overlap.'
}
if ($trackedIgnored.Count -gt 0) {
    $failures.Add("tracked files also matched .gitignore: $($trackedIgnored -join ', ')")
}

$trackedFiles = Get-TrackedFiles

$forbiddenTracked = @(
    'HANDOFF.md',
    'docs/HANDOFF.md',
    'docs/handoff.md',
    'testResults.xml',
    'tasks/roadmap-title-ja.psd1'
)
foreach ($path in $forbiddenTracked) {
    if ($trackedFiles -contains $path) {
        $failures.Add("tracked live-ops file must not be committed: $path")
    }
}

$forbiddenTrackedPrefixes = @(
    '.playwright-mcp/'
)
foreach ($file in $trackedFiles) {
    $normalized = $file.Replace('\', '/')
    foreach ($prefix in $forbiddenTrackedPrefixes) {
        if ($normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $failures.Add("tracked generated/runtime artifact must not be committed: $file")
        }
    }

    if ($normalized -match '[\uE000-\uF8FF]') {
        $failures.Add("tracked path contains a private-use Unicode character and must be renamed or removed: $file")
    }
}

$trackedPrivateSkillFiles = @(
    $trackedFiles |
        Where-Object { $_.Replace('\', '/') -match '^\.agents/skills/' }
)
if ($trackedPrivateSkillFiles.Count -gt 0) {
    $failures.Add("private maintainer skill pack must not be tracked in the public repo: $($trackedPrivateSkillFiles -join ', ')")
}

$personalPathPatterns = @(
    'C:\\Users\\',
    'iCloudDrive',
    'MainVault'
)
foreach ($file in ($trackedFiles | Where-Object { Test-IsMaintainerPathScanSurface -Path $_ })) {
    $content = Get-Content -LiteralPath $file -Raw -ErrorAction Stop
    foreach ($pattern in $personalPathPatterns) {
        if ($content -match [Regex]::Escape($pattern)) {
            $failures.Add("tracked text surface contains maintainer-local path pattern '$pattern': $file")
        }
    }
}

$personalIdentityPatterns = @(
    ('C:\Users\' + 'komei'),
    'iCloudDrive',
    'MainVault'
)
foreach ($file in ($trackedFiles | Where-Object { Test-IsMaintainerIdentityScanSurface -Path $_ })) {
    $content = Get-Content -LiteralPath $file -Raw -ErrorAction Stop
    foreach ($pattern in $personalIdentityPatterns) {
        if ($content -match [Regex]::Escape($pattern)) {
            $failures.Add("tracked text surface contains maintainer-local identity pattern '$pattern': $file")
        }
    }
}

$forbiddenPublicRefs = @(
    '.claude/CLAUDE.md',
    'AGENT.md',
    'GEMINI.md',
    'docs/internal/',
    'docs/handoff.md',
    'tasks/roadmap-title-ja.psd1',
    '.agents/skills/'
)
$forbiddenPublicProductFragments = @(
    '/winsmux-start',
    'test this repository itself',
    '動作確認専用',
    'dogfooding',
    'Repository-operated',
    'contributor/runtime'
)
foreach ($file in ($trackedFiles | Where-Object { Test-IsPublicDoc -Path $_ })) {
    $content = Get-Content -LiteralPath $file -Raw -ErrorAction Stop
    foreach ($reference in $forbiddenPublicRefs) {
        if ($content -match [Regex]::Escape($reference)) {
            $failures.Add("public doc directly references private/contributor surface '$reference': $file")
        }
    }
    foreach ($fragment in $forbiddenPublicProductFragments) {
        if ($content -match [Regex]::Escape($fragment)) {
            $failures.Add("public doc exposes repository-only startup wording '$fragment': $file")
        }
    }

}

foreach ($file in ($trackedFiles | Where-Object { Test-IsExternalProductReferenceAuditSurface -Path $_ })) {
    Add-ForbiddenExternalProductReferenceFailures -Path $file -Surface 'public doc'
}

foreach ($file in ($trackedFiles | Where-Object { Test-IsPublicMaterialScanSurface -Path $_ })) {
    Add-PersonalEmailFailures -Path $file -Surface 'public material'
    Add-PrivateRuntimeReferenceFailures -Path $file -Surface 'public material'
    Add-ForbiddenPaidSourceDisclosureFailures -Path $file -Surface 'public material'
}

if (-not [string]::IsNullOrWhiteSpace($ReleaseNotesPath)) {
    Add-PersonalEmailFailures -Path $ReleaseNotesPath -Surface 'release notes'
    Add-PrivateRuntimeReferenceFailures -Path $ReleaseNotesPath -Surface 'release notes'
    Add-ForbiddenExternalProductReferenceFailures -Path $ReleaseNotesPath -Surface 'release notes'
    Add-ForbiddenPaidSourceDisclosureFailures -Path $ReleaseNotesPath -Surface 'release notes'
}

$claudeContractPath = Join-Path $repoRoot '.claude/CLAUDE.md'
if (Test-Path -LiteralPath $claudeContractPath) {
    $claudeContract = Get-Content -LiteralPath $claudeContractPath -Raw -ErrorAction Stop
    $legacyProbeLines = @(
        ($claudeContract -split "`r?`n") |
            Where-Object { $_ -match 'psmux --version|Get-Process psmux-server' }
    )
    $nonNegatedLegacyProbeLines = @(
        $legacyProbeLines |
            Where-Object { $_ -notmatch 'Do not|禁止|使わない|use only the structured smoke states' }
    )
    if ($nonNegatedLegacyProbeLines.Count -gt 0) {
        $failures.Add('.claude/CLAUDE.md still contains legacy startup probe guidance outside explicit prohibition.')
    }
    if ($claudeContract -notmatch 'winsmux orchestra-smoke --json') {
        $failures.Add('.claude/CLAUDE.md must reference winsmux orchestra-smoke --json as startup source of truth.')
    }
    if ($claudeContract -notmatch 'operator_contract') {
        $failures.Add('.claude/CLAUDE.md must reference operator_contract as startup source of truth.')
    }
}

$hooksPath = (& git config --get core.hooksPath 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($hooksPath)) {
    $failures.Add('core.hooksPath is not configured. Run scripts/bootstrap-git-guard.ps1.')
} else {
    $normalizedHooksPath = $hooksPath.Replace('\', '/')
    if ($normalizedHooksPath -notmatch '(^|/)\.githooks$') {
        $failures.Add("core.hooksPath must point to .githooks, found '$hooksPath'.")
    }
}

if ($failures.Count -gt 0) {
    Write-Error ("audit-public-surface blocked:`n- " + ($failures -join "`n- "))
    exit 1
}

Write-Output 'audit-public-surface passed'
