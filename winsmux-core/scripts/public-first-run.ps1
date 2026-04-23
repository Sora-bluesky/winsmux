[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'settings.ps1')

function Resolve-WinsmuxPublicProjectDir {
    param([string]$ProjectDir)

    $resolved = if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
        (Get-Location).Path
    } else {
        $ProjectDir
    }

    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "project directory not found: $resolved"
    }

    return (Get-Item -LiteralPath $resolved -Force).FullName
}

function Get-WinsmuxPublicWorkspaceLifecyclePresetNames {
    return @('none', 'managed-worktree', 'ephemeral-worktree')
}

function Assert-WinsmuxPublicWorkspaceLifecyclePreset {
    param([Parameter(Mandatory = $true)][string]$Preset)

    if ([string]::IsNullOrWhiteSpace($Preset) -or $Preset -notin (Get-WinsmuxPublicWorkspaceLifecyclePresetNames)) {
        throw "unsupported workspace lifecycle preset: $Preset"
    }
}

function Invoke-WinsmuxPublicInit {
    param(
        [string]$ProjectDir,
        [switch]$Force,
        [string]$Agent = 'codex',
        [string]$Model = 'gpt-5.4',
        [int]$WorkerCount = 6,
        [string]$WorkspaceLifecyclePreset = 'managed-worktree'
    )

    if ($WorkerCount -lt 1) {
        throw 'worker count must be 1 or greater.'
    }
    Assert-WinsmuxPublicWorkspaceLifecyclePreset -Preset $WorkspaceLifecyclePreset

    $resolvedProjectDir = Resolve-WinsmuxPublicProjectDir -ProjectDir $ProjectDir
    $configPath = Get-BridgeProjectSettingsPath -RootPath $resolvedProjectDir

    if ((Test-Path -LiteralPath $configPath) -and -not $Force) {
        $existing = Get-BridgeSettings -RootPath $resolvedProjectDir
        return [PSCustomObject][ordered]@{
            command             = 'init'
            status              = 'already_initialized'
            project_dir         = $resolvedProjectDir
            config_path         = $configPath
            created             = $false
            external_operator  = [bool]$existing.external_operator
            worker_count        = [int]$existing.worker_count
            slot_count          = @($existing.agent_slots).Count
            workspace_lifecycle_preset = [string]$existing.workspace_lifecycle_preset
            next_action         = 'Run winsmux launch.'
        }
    }

    $agentSlots = New-BridgeManagedAgentSlots -Count $WorkerCount -Agent $Agent -Model $Model
    Save-BridgeSettings -Scope project -RootPath $resolvedProjectDir -Settings ([ordered]@{
        agent               = $Agent
        model               = $Model
        external_operator  = $true
        worker_count        = $WorkerCount
        agent_slots         = @($agentSlots)
        legacy_role_layout  = $false
        operators          = 0
        builders            = 0
        researchers         = 0
        reviewers           = 0
        vault_keys          = @('GH_TOKEN')
        workspace_lifecycle_preset = $WorkspaceLifecyclePreset
    })

    return [PSCustomObject][ordered]@{
        command             = 'init'
        status              = 'initialized'
        project_dir         = $resolvedProjectDir
        config_path         = $configPath
        created             = $true
        external_operator  = $true
        worker_count        = $WorkerCount
        slot_count          = @($agentSlots).Count
        workspace_lifecycle_preset = $WorkspaceLifecyclePreset
        next_action         = 'Run winsmux launch.'
    }
}

function Invoke-WinsmuxPublicDoctorProbe {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$DoctorScriptPath
    )

    Push-Location -LiteralPath $ProjectDir
    try {
        $output = & pwsh -NoProfile -File $DoctorScriptPath repo 2>&1
        $exitCode = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    } finally {
        Pop-Location
    }

    return [PSCustomObject][ordered]@{
        exit_code = $exitCode
        output    = ((@($output) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    }
}

function Invoke-WinsmuxPublicSmokeProbe {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$BridgeScriptPath
    )

    Push-Location -LiteralPath $ProjectDir
    try {
        $output = & pwsh -NoProfile -File $BridgeScriptPath orchestra-smoke --json --auto-start --project-dir $ProjectDir 2>&1
        $exitCode = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    } finally {
        Pop-Location
    }

    $rawOutput = ((@($output) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    $parsed = $null
    $parseError = ''
    if (-not [string]::IsNullOrWhiteSpace($rawOutput)) {
        $jsonLine = @($rawOutput -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1
        if (-not [string]::IsNullOrWhiteSpace([string]$jsonLine)) {
            try {
                $parsed = $jsonLine | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $parseError = $_.Exception.Message
            }
        }
    }

    return [PSCustomObject][ordered]@{
        exit_code   = $exitCode
        raw_output  = $rawOutput
        parsed      = $parsed
        parse_error = $parseError
    }
}

function Invoke-WinsmuxPublicLaunch {
    param(
        [string]$ProjectDir,
        [switch]$SkipDoctor,
        [string]$BridgeScriptPath = '',
        [string]$DoctorScriptPath = ''
    )

    $resolvedProjectDir = Resolve-WinsmuxPublicProjectDir -ProjectDir $ProjectDir
    $configPath = Get-BridgeProjectSettingsPath -RootPath $resolvedProjectDir
    if (-not (Test-Path -LiteralPath $configPath)) {
        return [PSCustomObject][ordered]@{
            command       = 'launch'
            status        = 'blocked'
            reason        = 'missing_config'
            project_dir   = $resolvedProjectDir
            config_path   = $configPath
            next_action   = 'Run winsmux init first.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($BridgeScriptPath)) {
        throw 'bridge script path must not be empty.'
    }

    if (-not $SkipDoctor) {
        if ([string]::IsNullOrWhiteSpace($DoctorScriptPath)) {
            throw 'doctor script path must not be empty when doctor is enabled.'
        }

        $doctorResult = Invoke-WinsmuxPublicDoctorProbe -ProjectDir $resolvedProjectDir -DoctorScriptPath $DoctorScriptPath
        if ([int]$doctorResult.exit_code -ne 0) {
            return [PSCustomObject][ordered]@{
                command          = 'launch'
                status           = 'blocked'
                reason           = 'doctor_failed'
                project_dir      = $resolvedProjectDir
                config_path      = $configPath
                doctor_exit_code = [int]$doctorResult.exit_code
                doctor_output    = [string]$doctorResult.output
                next_action      = 'Fix doctor failures and rerun winsmux launch.'
            }
        }
    }

    $smokeResult = Invoke-WinsmuxPublicSmokeProbe -ProjectDir $resolvedProjectDir -BridgeScriptPath $BridgeScriptPath
    if ([int]$smokeResult.exit_code -ne 0) {
        return [PSCustomObject][ordered]@{
            command          = 'launch'
            status           = 'blocked'
            reason           = 'startup_failed'
            project_dir      = $resolvedProjectDir
            config_path      = $configPath
            smoke_exit_code  = [int]$smokeResult.exit_code
            smoke_output     = [string]$smokeResult.raw_output
            next_action      = 'Inspect orchestra-smoke output and rerun winsmux launch.'
        }
    }

    if ($null -eq $smokeResult.parsed -or $null -eq $smokeResult.parsed.operator_contract) {
        return [PSCustomObject][ordered]@{
            command          = 'launch'
            status           = 'blocked'
            reason           = 'invalid_smoke_output'
            project_dir      = $resolvedProjectDir
            config_path      = $configPath
            smoke_output     = [string]$smokeResult.raw_output
            parse_error      = [string]$smokeResult.parse_error
            next_action      = 'Inspect orchestra-smoke output and rerun winsmux launch.'
        }
    }

    $operatorContract = $smokeResult.parsed.operator_contract
    return [PSCustomObject][ordered]@{
        command            = 'launch'
        status             = [string]$operatorContract.operator_state
        project_dir        = $resolvedProjectDir
        config_path        = $configPath
        can_dispatch       = [bool]$operatorContract.can_dispatch
        requires_startup   = [bool]$operatorContract.requires_startup
        operator_message   = [string]$operatorContract.operator_message
        next_action        = [string]$operatorContract.next_action
        smoke_output       = [string]$smokeResult.raw_output
    }
}
