[CmdletBinding()]
param(
    [string]$BacklogPath = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$syncRoadmapScript = Join-Path $repoRoot 'winsmux-core\scripts\sync-roadmap.ps1'

if (-not (Test-Path -LiteralPath $syncRoadmapScript)) {
    throw "sync-roadmap script not found: $syncRoadmapScript"
}

& pwsh $syncRoadmapScript -BacklogPath $BacklogPath -RoadmapPath $OutputPath
exit $LASTEXITCODE
