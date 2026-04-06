# sync-project-views.ps1 — Generate ROADMAP.md from backlog.yaml
# Usage: pwsh scripts/sync-project-views.ps1
# Input:  tasks/backlog.yaml (SoT)
# Output: docs/project/ROADMAP.md
param(
    [string]$BacklogPath = (Join-Path $PSScriptRoot '..' 'tasks' 'backlog.yaml'),
    [string]$OutputPath  = (Join-Path $PSScriptRoot '..' 'docs' 'project' 'ROADMAP.md')
)

$ErrorActionPreference = 'Stop'

# --- Simple YAML parser (no external modules) ---
function Parse-BacklogYaml {
    param([string]$Path)
    $lines = Get-Content $Path -Encoding utf8
    $tasks = @()
    $current = $null

    foreach ($line in $lines) {
        if ($line -match '^\s+-\s+id:\s+"?(.+?)"?\s*$') {
            if ($current) { $tasks += [PSCustomObject]$current }
            $current = @{ id = $Matches[1] }
        }
        elseif ($current -and $line -match '^\s+(\w[\w_]*):\s+"?(.+?)"?\s*$') {
            $key = $Matches[1]
            $val = $Matches[2]
            if ($val -match '^\[(.+)\]$') {
                $current[$key] = ($Matches[1] -split ',\s*') | ForEach-Object { $_.Trim() }
            }
            else {
                $current[$key] = $val
            }
        }
    }
    if ($current) { $tasks += [PSCustomObject]$current }
    return $tasks
}

# --- Status emoji ---
function Get-StatusIcon {
    param([string]$Status)
    switch ($Status) {
        'done'        { return '[x]' }
        'in_progress' { return '[-]' }
        'review'      { return '[R]' }
        'ready'       { return '[ ]' }
        default       { return '[ ]' }
    }
}

# --- Progress bar ---
function Get-ProgressBar {
    param([int]$Done, [int]$Total)
    if ($Total -eq 0) { return '``````' }
    $pct = [math]::Round(($Done / $Total) * 100)
    $filled = [math]::Round($pct / 5)
    $empty = 20 - $filled
    $bar = ('=' * $filled) + ('-' * $empty)
    return "[$bar] $pct% ($Done/$Total)"
}

# --- Version sort (semver) ---
function Get-SemverKey {
    param([string]$Version)
    if ($Version -match 'v?(\d+)\.(\d+)\.(\d+)') {
        return ([int]$Matches[1] * 10000 + [int]$Matches[2] * 100 + [int]$Matches[3])
    }
    return 999999
}

# --- Main ---
$tasks = Parse-BacklogYaml -Path (Resolve-Path $BacklogPath)

# Group by version
$versions = $tasks | Group-Object -Property target_version | Sort-Object {
    Get-SemverKey $_.Name
}

# Ensure output directory
$outDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# Generate markdown
$md = @()
$md += "# Roadmap"
$md += ""
$md += "> Auto-generated from ``tasks/backlog.yaml`` — do not edit manually."
$md += "> Last sync: $(Get-Date -Format 'yyyy-MM-dd HH:mm (K)')"
$md += ""

# Summary table
$md += "## Version Summary"
$md += ""
$md += "| Version | Tasks | Progress |"
$md += "|---------|-------|----------|"

foreach ($vg in $versions) {
    $ver = $vg.Name
    $total = $vg.Group.Count
    $done = ($vg.Group | Where-Object { $_.status -eq 'done' }).Count
    $bar = Get-ProgressBar -Done $done -Total $total
    $md += "| $ver | $total | $bar |"
}
$md += ""

# Per-version details (WBS)
$md += "## Work Breakdown"
$md += ""

foreach ($vg in $versions) {
    $ver = $vg.Name
    $total = $vg.Group.Count
    $done = ($vg.Group | Where-Object { $_.status -eq 'done' }).Count
    $md += "### $ver"
    $md += ""
    $md += "| | ID | Title | Priority | Repo | Status |"
    $md += "|-|-----|-------|----------|------|--------|"

    $sorted = $vg.Group | Sort-Object { switch ($_.priority) { 'P0'{0} 'P1'{1} 'P2'{2} 'P3'{3} default{9} } }
    foreach ($t in $sorted) {
        $icon = Get-StatusIcon $t.status
        $labels = if ($t.labels -is [array]) { ($t.labels -join ', ') } else { $t.labels }
        $md += "| $icon | $($t.id) | $($t.title) | $($t.priority) | $($t.repo) | $($t.status) |"
    }
    $md += ""
}

# Legend
$md += "## Legend"
$md += ""
$md += "| Symbol | Meaning |"
$md += "|--------|---------|"
$md += "| [x] | Done |"
$md += "| [-] | In progress |"
$md += "| [R] | In review |"
$md += "| [ ] | Backlog / Ready |"
$md += ""
$md += "| Priority | Meaning |"
$md += "|----------|---------|"
$md += "| P0 | Critical / Blocker |"
$md += "| P1 | High |"
$md += "| P2 | Medium |"
$md += "| P3 | Low |"

# Write
$md -join "`n" | Set-Content $OutputPath -Encoding utf8 -NoNewline
Write-Host "Generated: $OutputPath ($($tasks.Count) tasks across $($versions.Count) versions)"
