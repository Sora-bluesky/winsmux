function Test-OrchestraManagedPaneTitle {
    param([AllowEmptyString()][string]$Title)

    return $Title -match '^(?i)(worker|builder|researcher|reviewer)-\d+$'
}

function Get-StaleOrchestraPaneTargets {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IEnumerable]$PaneRecords,
        [Parameter(Mandatory = $true)]
        [string]$SessionName
    )

    $targets = [System.Collections.Generic.List[object]]::new()

    foreach ($record in @($PaneRecords)) {
        $line = [string]$record
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = $line -split "`t", 3
        if ($parts.Count -lt 3) {
            continue
        }

        $paneSession = $parts[0].Trim()
        $paneId = $parts[1].Trim()
        $paneTitle = $parts[2].Trim()

        if ([string]::IsNullOrWhiteSpace($paneSession) -or $paneSession -eq $SessionName) {
            continue
        }

        if ($paneId -notmatch '^%\d+$') {
            continue
        }

        if (-not (Test-OrchestraManagedPaneTitle -Title $paneTitle)) {
            continue
        }

        $targets.Add([PSCustomObject]@{
            SessionName = $paneSession
            PaneId      = $paneId
            Title       = $paneTitle
        })
    }

    return @($targets)
}
