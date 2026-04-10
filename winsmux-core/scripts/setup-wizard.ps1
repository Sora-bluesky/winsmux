# setup-wizard.ps1 - Interactive setup for first-time winsmux configuration.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'settings.ps1')

function Get-WinsmuxBin {
    foreach ($candidate in @('winsmux', 'pmux', 'tmux')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            if ($command.Path) {
                return $command.Path
            }

            return $command.Name
        }
    }

    return $null
}

function Get-BridgeCommand {
    foreach ($candidate in @('winsmux', 'winsmux-core.ps1')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            if ($command.Path) {
                return $command.Path
            }

            return $command.Name
        }
    }

    $repoBridge = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\winsmux-core.ps1'))
    if (Test-Path $repoBridge) {
        return $repoBridge
    }

    return $null
}

function Read-DefaultValue {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$Default
    )

    $inputValue = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        return $Default
    }

    return $inputValue.Trim()
}

function Read-AgentCli {
    param([string]$Default = 'codex')

    while ($true) {
        $value = (Read-DefaultValue -Prompt 'AI agent CLI (codex/claude)' -Default $Default).ToLowerInvariant()
        if ($value -in @('codex', 'claude')) {
            return $value
        }

        Write-Host "Please enter 'codex' or 'claude'."
    }
}

function Read-PositiveInt {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][int]$Default
    )

    while ($true) {
        $raw = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $Default
        }

        $parsed = 0
        if ([int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -ge 0) {
            return $parsed
        }

        Write-Host 'Please enter a whole number greater than or equal to 0.'
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$Default = $false
    )

    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }

    while ($true) {
        $raw = Read-Host "$Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $Default
        }

        switch ($raw.Trim().ToLowerInvariant()) {
            'y' { return $true }
            'yes' { return $true }
            'n' { return $false }
            'no' { return $false }
            default { Write-Host "Please answer 'y' or 'n'." }
        }
    }
}

function ConvertTo-PlainText {
    param([Parameter(Mandatory = $true)][Security.SecureString]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Set-WinsmuxOption {
    param(
        [Parameter(Mandatory = $true)][string]$WinsmuxBin,
        [Parameter(Mandatory = $true)][string]$OptionName,
        [Parameter(Mandatory = $true)][string]$OptionValue
    )

    & $WinsmuxBin set-option -g $OptionName $OptionValue | Out-Null
}

function Set-GitHubTokenVault {
    param([Parameter(Mandatory = $true)][string]$BridgeCommand)

    $secureToken = Read-Host -AsSecureString "Enter GH_TOKEN"
    $plainToken = ConvertTo-PlainText -SecureString $secureToken

    try {
        if ([string]::IsNullOrWhiteSpace($plainToken)) {
            Write-Host 'Skipped vault storage because GH_TOKEN was empty.'
            return $false
        }

        if ($BridgeCommand.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
            & pwsh -NoProfile -File $BridgeCommand vault set GH_TOKEN $plainToken
        } else {
            & $BridgeCommand vault set GH_TOKEN $plainToken
        }

        return $true
    } finally {
        $plainToken = $null
    }
}

$winsmuxBin = Get-WinsmuxBin
if (-not $winsmuxBin) {
    Write-Error "Could not find a winsmux binary. Tried: winsmux, pmux, tmux."
    exit 1
}

Write-Host 'winsmux setup wizard'
Write-Host ''
Write-Host "Using multiplexer binary: $winsmuxBin"
Write-Host ''

$agentCli = Read-AgentCli -Default 'codex'
$model = Read-DefaultValue -Prompt 'Model' -Default 'gpt-5.4'
$externalCommander = Read-YesNo -Prompt 'Use an external Operator terminal?' -Default $true
$legacyRoleLayout = $false
$commanders = 0
$workerCount = 6
$agentSlots = @()
$builders = 0
$researchers = 0
$reviewers = 0

if ($externalCommander) {
    $workerCount = Read-PositiveInt -Prompt 'Managed worker pane count' -Default 6
    $agentSlots = New-BridgeManagedAgentSlots -Count $workerCount -Agent $agentCli -Model $model
} else {
    $legacyRoleLayout = Read-YesNo -Prompt 'Use legacy role layout (Commander/Builder/Researcher/Reviewer panes)?' -Default $true
    if ($legacyRoleLayout) {
        $commanders = Read-PositiveInt -Prompt 'Commanders count' -Default 1
        $builders = Read-PositiveInt -Prompt 'Builders count' -Default 4
        $researchers = Read-PositiveInt -Prompt 'Researchers count' -Default 1
        $reviewers = Read-PositiveInt -Prompt 'Reviewers count' -Default 1
    } else {
        $commanders = Read-PositiveInt -Prompt 'Embedded operator count' -Default 1
        $workerCount = Read-PositiveInt -Prompt 'Managed worker pane count' -Default 6
        $agentSlots = New-BridgeManagedAgentSlots -Count $workerCount -Agent $agentCli -Model $model
    }
}
$storeVault = Read-YesNo -Prompt 'Store GH_TOKEN in the winsmux vault?' -Default $false

Set-WinsmuxOption -WinsmuxBin $winsmuxBin -OptionName '@bridge-agent' -OptionValue $agentCli
Set-WinsmuxOption -WinsmuxBin $winsmuxBin -OptionName '@bridge-model' -OptionValue $model
Set-WinsmuxOption -WinsmuxBin $winsmuxBin -OptionName '@bridge-external-commander' -OptionValue $(if ($externalCommander) { 'on' } else { 'off' })
Set-WinsmuxOption -WinsmuxBin $winsmuxBin -OptionName '@bridge-legacy-role-layout' -OptionValue $(if ($legacyRoleLayout) { 'on' } else { 'off' })
Set-WinsmuxOption -WinsmuxBin $winsmuxBin -OptionName '@bridge-commanders' -OptionValue $commanders.ToString()
Set-WinsmuxOption -WinsmuxBin $winsmuxBin -OptionName '@bridge-worker-count' -OptionValue $workerCount.ToString()
Set-WinsmuxOption -WinsmuxBin $winsmuxBin -OptionName '@bridge-builders' -OptionValue $builders.ToString()
Set-WinsmuxOption -WinsmuxBin $winsmuxBin -OptionName '@bridge-researchers' -OptionValue $researchers.ToString()
Set-WinsmuxOption -WinsmuxBin $winsmuxBin -OptionName '@bridge-reviewers' -OptionValue $reviewers.ToString()

Save-BridgeSettings -Scope project -Settings ([ordered]@{
    agent               = $agentCli
    model               = $model
    external_commander  = $externalCommander
    worker_count        = $workerCount
    agent_slots         = @($agentSlots)
    legacy_role_layout  = $legacyRoleLayout
    commanders          = $commanders
    builders            = $builders
    researchers         = $researchers
    reviewers           = $reviewers
    vault_keys          = @('GH_TOKEN')
})

$vaultStored = $false
if ($storeVault) {
    $bridgeCommand = Get-BridgeCommand
    if (-not $bridgeCommand) {
        Write-Warning 'Could not find winsmux CLI. Skipping GH_TOKEN vault setup.'
    } else {
        $vaultStored = Set-GitHubTokenVault -BridgeCommand $bridgeCommand
    }
}

Write-Host ''
Write-Host 'Saved settings:'
Write-Host "  winsmux binary:         $winsmuxBin"
Write-Host "  @bridge-agent:        $agentCli"
Write-Host "  @bridge-model:        $model"
Write-Host "  @bridge-external-commander: $externalCommander"
Write-Host "  @bridge-legacy-role-layout: $legacyRoleLayout"
Write-Host "  @bridge-commanders:   $commanders"
Write-Host "  @bridge-worker-count: $workerCount"
Write-Host "  @bridge-builders:     $builders"
Write-Host "  @bridge-researchers:  $researchers"
Write-Host "  @bridge-reviewers:    $reviewers"
Write-Host "  project agent_slots:  $(@($agentSlots).Count)"
Write-Host "  GH_TOKEN stored:      $(if ($vaultStored) { 'yes' } else { 'no' })"
