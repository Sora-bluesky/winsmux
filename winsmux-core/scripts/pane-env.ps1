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
    return @('standard', 'operator', 'builder', 'ci')
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

function New-WinsmuxGovernanceCostUnit {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [string]$Mode = '',
        [string]$Task = '',
        [string]$RunId = '',
        [string]$Stage = '',
        [string]$Role = '',
        [string]$Target = '',
        [int]$Attempt = 0,
        [string]$Source = 'winsmux'
    )

    $normalizedKind = $Kind.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedKind)) {
        throw 'governance cost unit kind is required'
    }

    $normalizedMode = $Mode.Trim().ToLowerInvariant()
    $normalizedStage = $Stage.Trim().ToLowerInvariant()
    $safeParts = @(
        'governance',
        $normalizedKind,
        $normalizedMode,
        $normalizedStage,
        ([string]$Task).Trim(),
        ([string]$RunId).Trim(),
        ([string]$Target).Trim(),
        [string]$Attempt
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

    [PSCustomObject]@{
        unit_id   = ($safeParts -join ':')
        unit_type = 'governance_invocation'
        kind      = $normalizedKind
        mode      = $normalizedMode
        stage     = $normalizedStage
        task      = [string]$Task
        run_id    = [string]$RunId
        role      = [string]$Role
        target    = [string]$Target
        attempt   = $Attempt
        source    = [string]$Source
        quantity  = 1
    }
}

function Get-WinsmuxEnvironmentVariableNames {
    return @(
        'WINSMUX_ORCHESTRA_SESSION',
        'WINSMUX_ORCHESTRA_PROJECT_DIR',
        'WINSMUX_ROLE_MAP',
        'WINSMUX_ROLE',
        'WINSMUX_PANE_ID',
        'WINSMUX_BUILDER_WORKTREE',
        'WINSMUX_ASSIGNED_WORKTREE',
        'WINSMUX_ASSIGNED_BRANCH',
        'WINSMUX_WORKTREE_GITDIR',
        'WINSMUX_SLOT_ID',
        'WINSMUX_EXPECTED_ORIGIN',
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
        [string]$BuilderWorktreePath = '',
        [string]$SlotId = '',
        [string]$AssignedBranch = '',
        [string]$GitWorktreeDir = '',
        [string]$ExpectedOrigin = ''
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
        $environment['WINSMUX_ASSIGNED_WORKTREE'] = $BuilderWorktreePath
    }

    if (-not [string]::IsNullOrWhiteSpace($SlotId)) {
        $environment['WINSMUX_SLOT_ID'] = $SlotId
    }

    if (-not [string]::IsNullOrWhiteSpace($AssignedBranch)) {
        $environment['WINSMUX_ASSIGNED_BRANCH'] = $AssignedBranch
    }

    if (-not [string]::IsNullOrWhiteSpace($GitWorktreeDir)) {
        $environment['WINSMUX_WORKTREE_GITDIR'] = $GitWorktreeDir
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedOrigin)) {
        $environment['WINSMUX_EXPECTED_ORIGIN'] = $ExpectedOrigin
    }

    return $environment
}

function Get-CleanPtyEnv {
    param(
        [Parameter(Mandatory = $true)]$AllowedEnvironment
    )

    $environment = [ordered]@{}
    if ($AllowedEnvironment -is [System.Collections.IDictionary]) {
        foreach ($entry in $AllowedEnvironment.GetEnumerator()) {
            $environment[[string]$entry.Key] = [string]$entry.Value
        }
    } elseif ($null -ne $AllowedEnvironment.PSObject) {
        foreach ($property in $AllowedEnvironment.PSObject.Properties) {
            $environment[[string]$property.Name] = [string]$property.Value
        }
    } else {
        throw 'AllowedEnvironment must be a dictionary-like object.'
    }

    $allowedNames = @($environment.Keys)
    $removeCommand = "Get-ChildItem Env: | Where-Object { `$_.Name -like 'WINSMUX_*' } | ForEach-Object { Remove-Item -LiteralPath ('Env:' + `$_.Name) -ErrorAction SilentlyContinue }"

    return [PSCustomObject]@{
        RemoveCommand      = $removeCommand
        Environment        = $environment
        AllowedVariableNames = $allowedNames
    }
}
