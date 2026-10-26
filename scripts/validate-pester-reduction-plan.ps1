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

$retired = $inventory.retired_core_suites
if ($inventory.version -ne 2 -or $retired.source_root -cne 'core/tests') {
    throw 'Pester inventory must describe the completed core script migration.'
}
$retiredRoot = Join-Path $repoRoot $retired.source_root
if (Test-Path -LiteralPath $retiredRoot) {
    if (@(Get-ChildItem -LiteralPath $retiredRoot -Recurse -File).Count -gt 0) {
        throw 'Retired core script entrypoints remain in the public tree.'
    }
}
$retiredNames = @($retired.scripts | ForEach-Object { [string]$_.name }) +
    @($retired.retired_groups | ForEach-Object { $_.names })
if ($retiredNames.Count -ne $retired.source_file_count -or
    @($retiredNames | Sort-Object -Unique).Count -ne $retiredNames.Count) {
    throw 'Retired core script inventory must list every source file exactly once.'
}
$replacementPath = Join-Path $repoRoot $retired.test_source
$replacement = Get-Content -LiteralPath $replacementPath -Raw -Encoding UTF8
$entrypoint = Get-Content -LiteralPath (Join-Path $repoRoot $retired.test_entrypoint) -Raw -Encoding UTF8
if (-not $entrypoint.Contains('include!("' + [IO.Path]::GetFileName($replacementPath) + '")')) {
    throw 'Rust replacement assertions are not connected to the session contract test target.'
}
foreach ($script in $retired.scripts) {
    if ($script.former_bucket -eq 'migrate-rust' -and $script.disposition -ne 'guarded') {
        throw "Required runtime coverage cannot be retired without a Rust replacement: $($script.name)."
    }
    if ($script.disposition -eq 'guarded') {
        if (@($script.tests).Count -eq 0) { throw "Missing Rust replacement for $($script.name)." }
        foreach ($test in $script.tests) {
            $pattern = '(?m)^\s*#\[test\]\s*fn\s+' + [regex]::Escape([string]$test) + '\s*\('
            if ($replacement -notmatch $pattern) { throw "Missing Rust test $test for $($script.name)." }
        }
    } elseif ($script.disposition -ne 'retired' -or [string]::IsNullOrWhiteSpace([string]$script.reason)) {
        throw "Missing retirement basis for $($script.name)."
    }
}
foreach ($group in $retired.retired_groups) {
    if ($group.disposition -ne 'retired' -or $group.former_bucket -notin @('archive-reference', 'delete-after-coverage') -or
        [string]::IsNullOrWhiteSpace([string]$group.reason) -or @($group.names).Count -eq 0) {
        throw 'Reference and diagnostic retirements require an explicit basis and file list.'
    }
}
foreach ($path in $retired.current_reference_suites) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $path) -PathType Leaf)) {
        throw "Missing current Rust reference suite: $path"
    }
}

$tracked = @(& git -C $repoRoot ls-files --cached --others --exclude-standard 'tests/*.Tests.ps1' 2>$null)
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
    'docs/project/pester-suite-inventory.json'
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
