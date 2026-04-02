$RolePermissions = @{
    Commander = @{
        ReadOwn      = $true
        ReadOther    = $true
        SendAny      = $true
        SendCommander = $true
        HealthCheck  = $true
        Watch        = $true
        WaitReady    = $true
        Vault        = $true
        Dispatch     = $true
        TypeOwn      = $true
        TypeOther    = $false
        KeysOwn      = $true
        KeysOther    = $false
        List         = $true
        Id           = $true
        Version      = $true
        Doctor       = $true
    }
    Builder = @{
        ReadOwn      = $true
        ReadOther    = $false
        SendAny      = $false
        SendCommander = $true
        HealthCheck  = $false
        Watch        = $false
        WaitReady    = $false
        Vault        = $false
        Dispatch     = $false
        TypeOwn      = $true
        TypeOther    = $false
        KeysOwn      = $true
        KeysOther    = $false
        List         = $true
        Id           = $true
        Version      = $true
        Doctor       = $true
    }
    Researcher = @{
        ReadOwn      = $true
        ReadOther    = $false
        SendAny      = $false
        SendCommander = $true
        HealthCheck  = $false
        Watch        = $false
        WaitReady    = $false
        Vault        = $false
        Dispatch     = $false
        TypeOwn      = $true
        TypeOther    = $false
        KeysOwn      = $true
        KeysOther    = $false
        List         = $true
        Id           = $true
        Version      = $true
        Doctor       = $true
    }
    Reviewer = @{
        ReadOwn      = $true
        ReadOther    = $false
        SendAny      = $false
        SendCommander = $true
        HealthCheck  = $false
        Watch        = $false
        WaitReady    = $false
        Vault        = $false
        Dispatch     = $false
        TypeOwn      = $true
        TypeOther    = $false
        KeysOwn      = $true
        KeysOther    = $false
        List         = $true
        Id           = $true
        Version      = $true
        Doctor       = $true
    }
}

$script:RoleGateLabelsFile = Join-Path $env:APPDATA "winsmux\labels.json"

function ConvertTo-CanonicalWinsmuxRole {
    param([AllowNull()][string]$RoleName)

    if ([string]::IsNullOrWhiteSpace($RoleName)) {
        return $null
    }

    switch -Regex ($RoleName.Trim()) {
        '^(?i)Commander$' { return 'Commander' }
        '^(?i)Builder$' { return 'Builder' }
        '^(?i)Researcher$' { return 'Researcher' }
        '^(?i)Reviewer$' { return 'Reviewer' }
        default { return $null }
    }
}

function ConvertTo-InferredWinsmuxRole {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    switch -Regex ($Value.Trim()) {
        '^(?i)Commander(?:$|[-_:/\s])' { return 'Commander' }
        '^(?i)Builder(?:$|[-_:/\s])' { return 'Builder' }
        '^(?i)Researcher(?:$|[-_:/\s])' { return 'Researcher' }
        '^(?i)Reviewer(?:$|[-_:/\s])' { return 'Reviewer' }
        default { return $null }
    }
}

function Get-RoleGateLabels {
    if (-not (Test-Path $script:RoleGateLabelsFile)) {
        return @{}
    }

    $raw = Get-Content -Path $script:RoleGateLabelsFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    $obj = $raw | ConvertFrom-Json
    $ht = @{}
    $obj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
    return $ht
}

function Resolve-RoleGateTargetPane {
    param([AllowNull()][string]$TargetPane)

    if ([string]::IsNullOrWhiteSpace($TargetPane)) {
        return $null
    }

    $labels = Get-RoleGateLabels
    if ($labels.ContainsKey($TargetPane)) {
        return $labels[$TargetPane]
    }

    return $TargetPane
}

function Get-RoleGatePaneLabel {
    param([AllowNull()][string]$TargetPane)

    if ([string]::IsNullOrWhiteSpace($TargetPane)) {
        return $null
    }

    $resolvedPane = Resolve-RoleGateTargetPane $TargetPane
    $labels = Get-RoleGateLabels

    foreach ($label in $labels.Keys) {
        if ($labels[$label] -eq $resolvedPane) {
            return $label
        }
    }

    return $null
}

function Get-RoleGatePaneTitle {
    param([AllowNull()][string]$TargetPane)

    if ([string]::IsNullOrWhiteSpace($TargetPane)) {
        return $null
    }

    $resolvedPane = Resolve-RoleGateTargetPane $TargetPane

    try {
        $title = & psmux display-message -p -t $resolvedPane '#{pane_title}' 2>$null
        return ($title | Out-String).Trim()
    } catch {
        return $null
    }
}

function Test-RoleGateOwnPane {
    param([AllowNull()][string]$TargetPane)

    if ([string]::IsNullOrWhiteSpace($TargetPane)) {
        return $false
    }

    $resolvedPane = Resolve-RoleGateTargetPane $TargetPane
    $ownPane = $env:WINSMUX_PANE_ID

    if ([string]::IsNullOrWhiteSpace($ownPane)) {
        return $false
    }

    return $resolvedPane -eq $ownPane
}

function Test-RoleGateCommanderTarget {
    param([AllowNull()][string]$TargetPane)

    if ([string]::IsNullOrWhiteSpace($TargetPane)) {
        return $false
    }

    $candidates = @(
        $TargetPane
        (Get-RoleGatePaneLabel $TargetPane)
        (Get-RoleGatePaneTitle $TargetPane)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($candidate in $candidates) {
        if ((ConvertTo-InferredWinsmuxRole $candidate) -eq 'Commander') {
            return $true
        }
    }

    return $false
}

function Deny-RoleCommand {
    param(
        [string]$Role,
        [string]$Command
    )

    Write-Error "DENIED: [$Role] cannot execute [$Command]" -ErrorAction Continue
    return $false
}

function Assert-Role {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$TargetPane
    )

    $role = ConvertTo-CanonicalWinsmuxRole $env:WINSMUX_ROLE
    if ([string]::IsNullOrWhiteSpace($env:WINSMUX_ROLE)) {
        Write-Error "WINSMUX_ROLE not set" -ErrorAction Continue
        return $false
    }
    if ($null -eq $role) {
        Write-Error "Invalid WINSMUX_ROLE: $($env:WINSMUX_ROLE)" -ErrorAction Continue
        return $false
    }

    $permissions = $RolePermissions[$role]
    $normalizedCommand = if ($null -eq $Command) { '' } else { $Command.Trim().ToLowerInvariant() }
    $isOwnPane = Test-RoleGateOwnPane $TargetPane

    switch ($normalizedCommand) {
        '' { return $true }
        'read' {
            if ($isOwnPane -and $permissions.ReadOwn) { return $true }
            if ((-not $isOwnPane) -and $permissions.ReadOther) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'send' {
            if ($permissions.SendAny) { return $true }
            if ($permissions.SendCommander -and (Test-RoleGateCommanderTarget $TargetPane)) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'message' {
            if ($permissions.SendAny) { return $true }
            if ($permissions.SendCommander -and (Test-RoleGateCommanderTarget $TargetPane)) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'health-check' {
            if ($permissions.HealthCheck) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'watch' {
            if ($permissions.Watch) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'wait-ready' {
            if ($permissions.WaitReady) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'vault' {
            if ($permissions.Vault) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'dispatch' {
            if ($permissions.Dispatch) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'type' {
            if ($isOwnPane -and $permissions.TypeOwn) { return $true }
            if ((-not $isOwnPane) -and $permissions.TypeOther) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'clipboard-paste' {
            if ($isOwnPane -and $permissions.TypeOwn) { return $true }
            if ((-not $isOwnPane) -and $permissions.TypeOther) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'image-paste' {
            if ($isOwnPane -and $permissions.TypeOwn) { return $true }
            if ((-not $isOwnPane) -and $permissions.TypeOther) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'ime-input' {
            if ($isOwnPane -and $permissions.TypeOwn) { return $true }
            if ((-not $isOwnPane) -and $permissions.TypeOther) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'keys' {
            if ($isOwnPane -and $permissions.KeysOwn) { return $true }
            if ((-not $isOwnPane) -and $permissions.KeysOther) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'list' {
            if ($permissions.List) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'id' {
            if ($permissions.Id) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'version' {
            if ($permissions.Version) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'doctor' {
            if ($permissions.Doctor) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        default { return $true }
    }
}
