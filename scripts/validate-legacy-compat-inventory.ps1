$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$inventoryPath = Join-Path $repoRoot 'docs/project/legacy-compat-surface-inventory.json'

if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) {
    throw "Missing inventory: $inventoryPath"
}

$inventory = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
if ($inventory.task -ne 'TASK-408') {
    throw 'Inventory task must be TASK-408.'
}

$allowedClasses = @($inventory.allowed_classes)
$terms = @(
    $inventory.terms |
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($terms.Count -eq 0) {
    throw 'Inventory must contain at least one compatibility term.'
}

$entries = @($inventory.entries)
if ($entries.Count -eq 0) {
    throw 'Inventory must contain at least one entry.'
}

$tracked = @(& git -C $repoRoot ls-files --cached --others --exclude-standard 2>$null)
if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) {
    throw 'Failed to list repository files.'
}

$tracked = @($tracked | ForEach-Object { $_ -replace '\\', '/' } | Sort-Object -Unique)
$covered = @{}
$classCounts = @{}
foreach ($class in $allowedClasses) {
    $classCounts[$class] = 0
}

foreach ($entry in $entries) {
    if ($allowedClasses -notcontains $entry.class) {
        throw "Unknown compatibility class '$($entry.class)'."
    }

    foreach ($required in @('owner', 'surface', 'reason', 'target')) {
        if (-not ($entry.PSObject.Properties.Name -contains $required) -or [string]::IsNullOrWhiteSpace([string]$entry.$required)) {
            throw "Entry '$($entry.surface)' is missing '$required'."
        }
    }

    $paths = @()
    if ($entry.PSObject.Properties.Name -contains 'paths') {
        $paths = @($entry.paths)
    }

    $globs = @()
    if ($entry.PSObject.Properties.Name -contains 'globs') {
        $globs = @($entry.globs)
    }

    foreach ($path in $paths) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) { continue }

        $normalized = ([string]$path) -replace '\\', '/'
        if ($tracked -notcontains $normalized) {
            throw "Inventory path is not a repository file: $normalized"
        }
        $covered[$normalized] = [string]$entry.class
    }

    foreach ($glob in $globs) {
        if ([string]::IsNullOrWhiteSpace([string]$glob)) { continue }

        $pattern = ([string]$glob) -replace '\\', '/'
        $regex = '^' + [Regex]::Escape($pattern).Replace('\*\*', '.*').Replace('\*', '[^/]*') + '$'
        $matches = @($tracked | Where-Object { $_ -match $regex })
        if ($matches.Count -eq 0) {
            throw "Inventory glob matched no repository files: $pattern"
        }

        foreach ($match in $matches) {
            $covered[$match] = [string]$entry.class
        }
    }
}

$matchedFiles = @()
foreach ($file in $tracked) {
    $path = Join-Path $repoRoot $file
    try {
        $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
    } catch {
        continue
    }
    if ($null -eq $content) {
        continue
    }

    $lowered = $content.ToLowerInvariant()
    foreach ($term in $terms) {
        if ($lowered.Contains($term)) {
            $matchedFiles += $file
            break
        }
    }
}

$matchedFiles = @($matchedFiles | ForEach-Object { $_ -replace '\\', '/' } | Sort-Object -Unique)
$missing = @($matchedFiles | Where-Object { -not $covered.ContainsKey($_) })
if ($missing.Count -gt 0) {
    throw "Repository compatibility files missing from inventory: $($missing -join ', ')"
}

foreach ($file in $matchedFiles) {
    $class = [string]$covered[$file]
    if (-not $classCounts.ContainsKey($class)) {
        $classCounts[$class] = 0
    }
    $classCounts[$class] = [int]$classCounts[$class] + 1
}

$forbiddenPatterns = @(
    'C:\\Users\\',
    '/Users/',
    '\.claude/local',
    'WINSMUX_PRIVATE_SKILLS_ROOT',
    'private-skills-root'
)

foreach ($relativePath in @(
    'docs/project/legacy-compat-surface-inventory.json',
    'docs/project/legacy-compat-surface-inventory.md'
)) {
    $content = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw -Encoding UTF8
    foreach ($pattern in $forbiddenPatterns) {
        if ($content -match $pattern) {
            throw "Forbidden private/local reference '$pattern' found in $relativePath."
        }
    }
}

Write-Output ("Legacy compatibility inventory OK: {0} repository files covered; intentional_shim={1}; removal_candidate={2}." -f $matchedFiles.Count, $classCounts['intentional-shim'], $classCounts['removal-candidate'])
