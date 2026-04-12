$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertFrom-WinsmuxEnvScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $trimmed = $text.Trim()
    if ($trimmed.Length -ge 2) {
        if (($trimmed.StartsWith("'") -and $trimmed.EndsWith("'")) -or ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"'))) {
            $trimmed = $trimmed.Substring(1, $trimmed.Length - 2)
        }
    }

    if ($trimmed -eq 'null') {
        return $null
    }

    return $trimmed
}

function Get-WinsmuxGovernanceFilePath {
    param([string]$ProjectDir = (Get-Location).Path)

    return Join-Path (Join-Path $ProjectDir '.winsmux') 'governance.yaml'
}

function Read-WinsmuxGovernanceFile {
    param([string]$ProjectDir = (Get-Location).Path)

    $path = Get-WinsmuxGovernanceFilePath -ProjectDir $ProjectDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [ordered]@{}
    }

    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        return [ordered]@{}
    }

    $result = [ordered]@{}
    foreach ($rawLine in ($content -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($rawLine)) {
            continue
        }

        $trimmed = $rawLine.Trim()
        if ($trimmed.StartsWith('#')) {
            continue
        }

        if ($rawLine -match '^\s') {
            continue
        }

        if ($trimmed -notmatch '^([A-Za-z0-9_\-]+):\s*(.+?)\s*$') {
            continue
        }

        $key = [string]$Matches[1]
        $value = ConvertFrom-WinsmuxEnvScalar -Value $Matches[2]
        $result[$key] = $value
    }

    return $result
}

function Get-WinsmuxSupportedHookProfiles {
    return @('standard', 'commander', 'builder', 'ci')
}

function Resolve-WinsmuxHookProfile {
    param(
        [string]$ProjectDir = (Get-Location).Path,
        [string]$EnvironmentValue = $env:WINSMUX_HOOK_PROFILE
    )

    $resolved = $EnvironmentValue
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $governance = Read-WinsmuxGovernanceFile -ProjectDir $ProjectDir
        if ($governance.Contains('hook_profile')) {
            $resolved = [string]$governance['hook_profile']
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = 'standard'
    }

    $resolved = $resolved.Trim().ToLowerInvariant()
    if ($resolved -notin (Get-WinsmuxSupportedHookProfiles)) {
        throw "Unsupported WINSMUX_HOOK_PROFILE '$resolved'. Supported profiles: $((Get-WinsmuxSupportedHookProfiles) -join ', ')."
    }

    return $resolved
}

function Get-WinsmuxSupportedGovernanceModes {
    return @('core', 'standard', 'enhanced')
}

function Resolve-WinsmuxGovernanceMode {
    param(
        [string]$ProjectDir = (Get-Location).Path,
        [string]$EnvironmentValue = $env:WINSMUX_GOVERNANCE_MODE
    )

    $resolved = $EnvironmentValue
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $governance = Read-WinsmuxGovernanceFile -ProjectDir $ProjectDir
        if ($governance.Contains('mode')) {
            $resolved = [string]$governance['mode']
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = 'standard'
    }

    $resolved = $resolved.Trim().ToLowerInvariant()
    if ($resolved -notin (Get-WinsmuxSupportedGovernanceModes)) {
        throw "Unsupported WINSMUX_GOVERNANCE_MODE '$resolved'. Supported modes: $((Get-WinsmuxSupportedGovernanceModes) -join ', ')."
    }

    return $resolved
}

function Get-WinsmuxEnvironmentVariableNames {
    return @(
        'WINSMUX_ORCHESTRA_SESSION',
        'WINSMUX_ORCHESTRA_PROJECT_DIR',
        'WINSMUX_ROLE_MAP',
        'WINSMUX_ROLE',
        'WINSMUX_PANE_ID',
        'WINSMUX_BUILDER_WORKTREE',
        'WINSMUX_HOOK_PROFILE',
        'WINSMUX_GOVERNANCE_MODE'
    )
}

function Get-WinsmuxEnvironmentContract {
    param([string]$ProjectDir = (Get-Location).Path)

    return [ordered]@{
        hook_profile     = Resolve-WinsmuxHookProfile -ProjectDir $ProjectDir
        governance_mode  = Resolve-WinsmuxGovernanceMode -ProjectDir $ProjectDir
        governance_path  = Get-WinsmuxGovernanceFilePath -ProjectDir $ProjectDir
        variable_names   = @(Get-WinsmuxEnvironmentVariableNames)
    }
}

function Get-WinsmuxPaneEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [string]$SessionName = '',
        [string]$ProjectDir = (Get-Location).Path,
        [string]$RoleMapJson = '',
        [string]$BuilderWorktreePath = ''
    )

    $contract = Get-WinsmuxEnvironmentContract -ProjectDir $ProjectDir
    $environment = [ordered]@{
        WINSMUX_ORCHESTRA_PROJECT_DIR = $ProjectDir
        WINSMUX_ROLE            = $Role
        WINSMUX_PANE_ID         = $PaneId
        WINSMUX_HOOK_PROFILE    = [string]$contract['hook_profile']
        WINSMUX_GOVERNANCE_MODE = [string]$contract['governance_mode']
    }

    if (-not [string]::IsNullOrWhiteSpace($SessionName)) {
        $environment['WINSMUX_ORCHESTRA_SESSION'] = $SessionName
    }

    if (-not [string]::IsNullOrWhiteSpace($RoleMapJson)) {
        $environment['WINSMUX_ROLE_MAP'] = $RoleMapJson
    }

    if (-not [string]::IsNullOrWhiteSpace($BuilderWorktreePath)) {
        $environment['WINSMUX_BUILDER_WORKTREE'] = $BuilderWorktreePath
    }

    return $environment
}
