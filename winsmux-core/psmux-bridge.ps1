[CmdletBinding()]
param()

function Get-WinsmuxBin { $b = Get-Command winsmux -ErrorAction SilentlyContinue; if ($b) { return $b.Source }; return 'winsmux' }
$winsmuxBin = Get-WinsmuxBin
function Get-WinsmuxOption { param([string]$Name, [string]$Default); $val = (& $winsmuxBin show-options -g -v $Name 2>&1 | Out-String).Trim(); if ($val -and $val -notmatch 'unknown|error|invalid') { return $val }; return $Default }

function Convert-ToForwardSlashPath {
    param([string]$Path)

    return $Path -replace '\\', '/'
}

$orchestraScript = Convert-ToForwardSlashPath (Join-Path $PSScriptRoot "../scripts/orchestra-start.ps1")
$setupWizardScript = Convert-ToForwardSlashPath (Join-Path $PSScriptRoot "../scripts/setup-wizard.ps1")
$firstRunOption = '@winsmux_first_run_done'

& $winsmuxBin bind-key O run-shell "pwsh -NoProfile -File '$orchestraScript'"
& $winsmuxBin bind-key B run-shell "pwsh -NoProfile -File '$setupWizardScript'"
& $winsmuxBin set-hook -g after-new-session "run-shell 'pwsh -NoProfile -File $setupWizardScript -FirstRun'"

if ((Get-WinsmuxOption -Name $firstRunOption -Default '0') -ne '1') {
    & $winsmuxBin display-message "winsmux loaded. Press Prefix+B for setup wizard."
}

. "$PSScriptRoot/../scripts/winsmux-core.ps1" version *> $null
