$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$inventoryPath = Join-Path $repoRoot 'docs/project/pester-suite-inventory.json'

if (-not (Test-Path $inventoryPath)) {
    throw "Missing inventory: $inventoryPath"
}

$inventoryRaw = Get-Content $inventoryPath -Raw
$inventory = $inventoryRaw | ConvertFrom-Json
$allowedBuckets = @($inventory.allowed_buckets)
$entries = @($inventory.entries)

if ($inventory.task -ne 'TASK-407') {
    throw 'Inventory task must be TASK-407.'
}

if ($entries.Count -eq 0) {
    throw 'Inventory must contain at least one entry.'
}

foreach ($entry in $entries) {
    if ($allowedBuckets -notcontains $entry.bucket) {
        throw "Unknown bucket '$($entry.bucket)'."
    }

    foreach ($required in @('owner', 'contract', 'target', 'batch')) {
        if (-not ($entry.PSObject.Properties.Name -contains $required) -or [string]::IsNullOrWhiteSpace([string]$entry.$required)) {
            throw "Entry for bucket '$($entry.bucket)' is missing '$required'."
        }
    }
}

$tracked = @(& git -C $repoRoot ls-files 'tests/*.Tests.ps1' 'core/tests/*.ps1' 2>$null)
if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) {
    throw 'Failed to list tracked Pester files.'
}

$tracked = @($tracked | ForEach-Object { $_ -replace '\\', '/' } | Sort-Object -Unique)
$covered = @{}

foreach ($entry in $entries) {
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
            throw "Inventory path is not a tracked Pester file: $normalized"
        }
        $covered[$normalized] = $true
    }

    foreach ($glob in $globs) {
        if ([string]::IsNullOrWhiteSpace([string]$glob)) { continue }

        $pattern = ([string]$glob) -replace '\\', '/'
        $regex = '^' + [Regex]::Escape($pattern).Replace('\*', '[^/]*') + '$'
        $matches = @($tracked | Where-Object { $_ -match $regex })

        if ($matches.Count -eq 0) {
            throw "Inventory glob matched no tracked Pester files: $pattern"
        }

        foreach ($match in $matches) {
            $covered[$match] = $true
        }
    }
}

$missing = @($tracked | Where-Object { -not $covered.ContainsKey($_) })
if ($missing.Count -gt 0) {
    throw "Tracked Pester files missing from inventory: $($missing -join ', ')"
}

$forbiddenPatterns = @(
    'C:\\Users\\',
    '/Users/',
    '\.claude/local',
    'WINSMUX_PRIVATE_SKILLS_ROOT',
    'private-skills-root'
)

$docsToScan = @(
    'docs/project/pester-suite-inventory.json',
    'docs/project/pester-suite-reduction-plan.md'
)

foreach ($relativePath in $docsToScan) {
    $content = Get-Content (Join-Path $repoRoot $relativePath) -Raw
    foreach ($pattern in $forbiddenPatterns) {
        if ($content -match $pattern) {
            throw "Forbidden private/local reference '$pattern' found in $relativePath."
        }
    }
}

Write-Output ("Pester reduction inventory OK: {0} tracked files covered by {1} entries." -f $tracked.Count, $entries.Count)
