$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'settings.ps1')

function Get-AgentLaunchCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [string]$RootPath,
        [bool]$ExecMode = $false
    )

    return Get-BridgeProviderLaunchCommand `
        -ProviderId $Agent `
        -Model $Model `
        -ProjectDir $ProjectDir `
        -GitWorktreeDir $GitWorktreeDir `
        -RootPath $RootPath `
        -ExecMode $ExecMode
}

function Get-AgentBootstrapPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Role,
        [string]$RootPath
    )

    $adapter = $Agent.Trim()
    $capability = Resolve-BridgeProviderCapability -ProviderId $adapter -RootPath $RootPath -RequireWhenRegistryPresent
    if ($null -ne $capability) {
        $adapter = [string](Get-BridgeProviderCapabilityValue -Capability $capability -Name 'adapter' -Default $adapter)
    }

    if ($adapter.Trim().ToLowerInvariant() -ne 'codex') {
        return $null
    }

    if ($Role.Trim().ToLowerInvariant() -notin @('builder', 'worker')) {
        return $null
    }

    return 'Windows sandbox note: PowerShell is in ConstrainedLanguageMode. For any file edit/write, prefer apply_patch; for simple shell writes use cmd /c. Do not use Set-Content, Out-File, Add-Content, [IO.File]::WriteAllText/WriteAllBytes, or property assignment on non-core types. Reply exactly OK, then wait for the next task.'
}
