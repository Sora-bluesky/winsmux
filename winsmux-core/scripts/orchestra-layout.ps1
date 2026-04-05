# orchestra-layout.ps1 - Deterministic psmux grid layout for Orchestra on PowerShell 7
# Creates a fresh window, lays out panes with chained percentage splits, labels them by role,
# and returns pane assignments as PowerShell objects.

[CmdletBinding()]
param(
    [string]$SessionName = $env:WINSMUX_ORCHESTRA_SESSION,
    [int]$Builders = 4,
    [int]$Researchers = 1,
[int]$Reviewers = 1
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$scriptDir = $PSScriptRoot
. "$scriptDir/pane-border.ps1"

function Test-PositiveCount {
    param(
        [string]$Name,
        [int]$Value
    )

    if ($Value -lt 0) {
        throw "$Name must be 0 or greater (got $Value)."
    }
}

function Get-GridDimensions {
    param([int]$PaneCount)

    switch ($PaneCount) {
        1       { return @{ Rows = 1; Cols = 1 } }
        2       { return @{ Rows = 1; Cols = 2 } }
        3       { return @{ Rows = 1; Cols = 3 } }
        4       { return @{ Rows = 2; Cols = 2 } }
        { $_ -in 5, 6 }   { return @{ Rows = 2; Cols = 3 } }
        { $_ -in 7, 8 }   { return @{ Rows = 2; Cols = 4 } }
        9       { return @{ Rows = 3; Cols = 3 } }
        { $_ -in 10, 11, 12 } { return @{ Rows = 3; Cols = 4 } }
        default { throw "Unsupported pane count: $PaneCount" }
    }
}

function Get-PaneIds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    $rawPaneIds = & psmux list-panes -t $Target -F '#{pane_id}' 2>$null
    return @(
        $rawPaneIds |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^%\d+$' }
    )
}

function Split-Equal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target,
        [int]$PaneCount,
        [ValidateSet('-h', '-v')]
        [string]$Direction
    )

    for ($i = 0; $i -lt ($PaneCount - 1); $i++) {
        $remaining = $PaneCount - $i
        $percent = [int](100 / $remaining)
        & psmux split-window -t $Target $Direction -p $percent | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "psmux split-window failed while creating $PaneCount panes in direction $Direction."
        }
    }
}

function Get-RoleLabels {
    param(
        [int]$BuilderCount,
        [int]$ResearcherCount,
        [int]$ReviewerCount
    )

    $labels = [System.Collections.Generic.List[string]]::new()

    for ($i = 1; $i -le $BuilderCount; $i++) {
        $labels.Add("Builder-$i")
    }

    for ($i = 1; $i -le $ResearcherCount; $i++) {
        $labels.Add("Researcher-$i")
    }

    for ($i = 1; $i -le $ReviewerCount; $i++) {
        $labels.Add("Reviewer-$i")
    }

    return $labels
}

Test-PositiveCount -Name 'Builders' -Value $Builders
Test-PositiveCount -Name 'Researchers' -Value $Researchers
Test-PositiveCount -Name 'Reviewers' -Value $Reviewers

if ([string]::IsNullOrWhiteSpace($SessionName)) {
    throw 'SessionName is required. Pass -SessionName or set WINSMUX_ORCHESTRA_SESSION.'
}

$total = $Builders + $Researchers + $Reviewers
if ($total -lt 1 -or $total -gt 12) {
    throw "Total panes must be 1-12 (got $total)."
}

$grid = Get-GridDimensions -PaneCount $total
$rows = $grid.Rows
$cols = $grid.Cols

& psmux has-session -t $SessionName 1>$null 2>$null
if ($LASTEXITCODE -ne 0) {
    & psmux new-session -d -s $SessionName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'psmux new-session failed.'
    }

    Start-Sleep -Milliseconds 500
}

$windowMetadata = (& psmux new-window -t $SessionName -P -F '#{window_id} #{pane_id}' 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'psmux new-window failed.'
}

$windowParts = @($windowMetadata -split '\s+')
if ($windowParts.Count -lt 2) {
    throw "psmux new-window returned unexpected metadata: '$windowMetadata'."
}

$newWindowId = $windowParts[0]
$newPaneId = $windowParts[1]
if ($newWindowId -notmatch '^@\d+$') {
    throw "psmux new-window returned an unexpected window id: '$newWindowId'."
}
if ($newPaneId -notmatch '^%\d+$') {
    throw "psmux new-window returned an unexpected pane id: '$newPaneId'."
}

if (-not (Set-OrchestraPaneBorderOptions -WindowId $newWindowId -PsmuxBin 'psmux')) {
    Write-Warning "Could not enable pane border labels for window $newWindowId."
}

if ($rows -gt 1) {
    Split-Equal -Target $newPaneId -PaneCount $rows -Direction '-v'
}

$rowIds = Get-PaneIds -Target $newWindowId
if ($rowIds.Count -lt $rows) {
    throw "Expected at least $rows row panes but found $($rowIds.Count)."
}

if ($cols -gt 1) {
    for ($rowIndex = 0; $rowIndex -lt $rows; $rowIndex++) {
        & psmux select-pane -t $rowIds[$rowIndex] | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "psmux select-pane failed for row pane $($rowIds[$rowIndex])."
        }

        Split-Equal -Target $rowIds[$rowIndex] -PaneCount $cols -Direction '-h'
    }
}

Start-Sleep -Milliseconds 300

$allIds = Get-PaneIds -Target $newWindowId
if ($allIds.Count -lt $total) {
    throw "Expected at least $total panes but found $($allIds.Count)."
}

$labels = Get-RoleLabels -BuilderCount $Builders -ResearcherCount $Researchers -ReviewerCount $Reviewers
$assignments = [System.Collections.Generic.List[object]]::new()

for ($index = 0; $index -lt $total; $index++) {
    $paneId = $allIds[$index]
    $label = $labels[$index]

    & psmux select-pane -t $paneId -T $label | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "psmux select-pane -T failed for pane $paneId."
    }

    $assignments.Add([PSCustomObject]@{
        PaneId = $paneId
        Role   = $label
    })
}

& psmux select-pane -t $allIds[0] | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "psmux select-pane failed for pane $($allIds[0])."
}

[PSCustomObject]@{
    Builders    = $Builders
    Researchers = $Researchers
    Reviewers   = $Reviewers
    Total       = $total
    Rows        = $rows
    Cols        = $cols
    Panes       = @($assignments)
}
