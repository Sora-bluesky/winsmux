$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Set-PsmuxWindowOption {
    param(
        [Parameter(Mandatory = $true)][string]$WindowId,
        [Parameter(Mandatory = $true)][string]$OptionName,
        [Parameter(Mandatory = $true)][string]$OptionValue,
        [string]$PsmuxBin = 'psmux'
    )

    $attempts = @(
        @('set-option', '-t', $WindowId, $OptionName, $OptionValue),
        @('set-option', '-w', '-t', $WindowId, $OptionName, $OptionValue),
        @('set-window-option', '-t', $WindowId, $OptionName, $OptionValue)
    )

    foreach ($attempt in $attempts) {
        & $PsmuxBin @attempt 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }

    return $false
}

function Set-OrchestraPaneBorderOptions {
    param(
        [Parameter(Mandatory = $true)][string]$WindowId,
        [string]$PsmuxBin = 'psmux'
    )

    $options = [ordered]@{
        'pane-border-status' = 'top'
        'pane-border-format' = ' #{pane_title} '
    }

    foreach ($entry in $options.GetEnumerator()) {
        $ok = Set-PsmuxWindowOption -WindowId $WindowId -OptionName $entry.Key -OptionValue $entry.Value -PsmuxBin $PsmuxBin
        if (-not $ok) {
            return $false
        }
    }

    return $true
}
