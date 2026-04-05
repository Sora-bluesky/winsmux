$RolePermissions = @{
    Commander = @{
        ReadOwn       = $true
        ReadOther     = $true
        SendAny       = $true
        SendCommander = $true
        HealthCheck   = $true
        Watch         = $true
        WaitReady     = $true
        Vault         = $true
        Dispatch      = $true
        TypeOwn       = $true
        TypeOther     = $false
        KeysOwn       = $true
        KeysOther     = $false
        List          = $true
        Name          = $true
        Resolve       = $true
        Focus         = $true
        Signal        = $true
        Wait          = $true
        Profile       = $true
        Lock          = $true
        Unlock        = $true
        Locks         = $true
        MailboxCreate = $true
        MailboxSend   = $true
        MailboxListen = $true
        Kill          = $true
        Restart       = $true
        Id            = $true
        Version       = $true
        Doctor        = $true
    }
    Builder = @{
        ReadOwn       = $true
        ReadOther     = $false
        SendAny       = $false
        SendCommander = $true
        HealthCheck   = $false
        Watch         = $false
        WaitReady     = $false
        Vault         = $false
        Dispatch      = $false
        TypeOwn       = $true
        TypeOther     = $false
        KeysOwn       = $true
        KeysOther     = $false
        List          = $true
        Name          = $true
        Resolve       = $true
        Focus         = $false
        Signal        = $true
        Wait          = $true
        Profile       = $false
        Lock          = $false
        Unlock        = $false
        Locks         = $true
        MailboxCreate = $false
        MailboxSend   = $true
        MailboxListen = $false
        Kill          = $false
        Restart       = $false
        Id            = $true
        Version       = $true
        Doctor        = $true
    }
    Researcher = @{
        ReadOwn       = $true
        ReadOther     = $false
        SendAny       = $false
        SendCommander = $true
        HealthCheck   = $false
        Watch         = $false
        WaitReady     = $false
        Vault         = $false
        Dispatch      = $false
        TypeOwn       = $true
        TypeOther     = $false
        KeysOwn       = $true
        KeysOther     = $false
        List          = $true
        Name          = $true
        Resolve       = $true
        Focus         = $false
        Signal        = $false
        Wait          = $false
        Profile       = $false
        Lock          = $false
        Unlock        = $false
        Locks         = $true
        MailboxCreate = $false
        MailboxSend   = $true
        MailboxListen = $false
        Kill          = $false
        Restart       = $false
        Id            = $true
        Version       = $true
        Doctor        = $true
    }
    Reviewer = @{
        ReadOwn       = $true
        ReadOther     = $false
        SendAny       = $false
        SendCommander = $true
        HealthCheck   = $false
        Watch         = $false
        WaitReady     = $false
        Vault         = $false
        Dispatch      = $false
        TypeOwn       = $true
        TypeOther     = $false
        KeysOwn       = $true
        KeysOther     = $false
        List          = $true
        Name          = $true
        Resolve       = $true
        Focus         = $false
        Signal        = $false
        Wait          = $false
        Profile       = $false
        Lock          = $false
        Unlock        = $false
        Locks         = $true
        MailboxCreate = $false
        MailboxSend   = $true
        MailboxListen = $false
        Kill          = $false
        Restart       = $false
        Id            = $true
        Version       = $true
        Doctor        = $true
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

function Get-RoleGateRoleMap {
    $raw = $env:WINSMUX_ROLE_MAP
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Error "Invalid WINSMUX_ROLE_MAP JSON: $($_.Exception.Message)" -ErrorAction Continue
        return $null
    }

    $roleMap = @{}
    foreach ($property in $obj.PSObject.Properties) {
        $canonicalRole = ConvertTo-CanonicalWinsmuxRole ([string]$property.Value)
        if ($null -eq $canonicalRole) {
            Write-Error "Invalid WINSMUX_ROLE_MAP role for pane $($property.Name): $($property.Value)" -ErrorAction Continue
            return $null
        }

        $roleMap[[string]$property.Name] = $canonicalRole
    }

    return $roleMap
}

function Get-RoleGateCurrentRole {
    $role = ConvertTo-CanonicalWinsmuxRole $env:WINSMUX_ROLE
    if ([string]::IsNullOrWhiteSpace($env:WINSMUX_ROLE)) {
        Write-Error "WINSMUX_ROLE not set" -ErrorAction Continue
        return $null
    }
    if ($null -eq $role) {
        Write-Error "Invalid WINSMUX_ROLE: $($env:WINSMUX_ROLE)" -ErrorAction Continue
        return $null
    }

    $roleMap = Get-RoleGateRoleMap
    if ($null -eq $roleMap) {
        return $null
    }

    if ($roleMap.Count -eq 0) {
        return $role
    }

    if ([string]::IsNullOrWhiteSpace($env:WINSMUX_PANE_ID)) {
        Write-Error "WINSMUX_PANE_ID not set" -ErrorAction Continue
        return $null
    }

    if (-not $roleMap.ContainsKey($env:WINSMUX_PANE_ID)) {
        Write-Error "WINSMUX_ROLE_MAP missing entry for pane $($env:WINSMUX_PANE_ID)" -ErrorAction Continue
        return $null
    }

    $mappedRole = $roleMap[$env:WINSMUX_PANE_ID]
    if ($mappedRole -ne $role) {
        Write-Error "WINSMUX_ROLE mismatch for pane $($env:WINSMUX_PANE_ID): expected $mappedRole, got $role" -ErrorAction Continue
        return $null
    }

    return $mappedRole
}

function Get-RoleGateTargetRole {
    param([AllowNull()][string]$TargetPane)

    if ([string]::IsNullOrWhiteSpace($TargetPane)) {
        return $null
    }

    $roleMap = Get-RoleGateRoleMap
    if ($null -eq $roleMap -or $roleMap.Count -eq 0) {
        return $null
    }

    $resolvedPane = Resolve-RoleGateTargetPane $TargetPane
    if ([string]::IsNullOrWhiteSpace($resolvedPane)) {
        return $null
    }

    if (-not $roleMap.ContainsKey($resolvedPane)) {
        return $null
    }

    return $roleMap[$resolvedPane]
}

function Test-RoleGateCommanderTarget {
    param([AllowNull()][string]$TargetPane)

    if ([string]::IsNullOrWhiteSpace($TargetPane)) {
        return $false
    }

    return (Get-RoleGateTargetRole $TargetPane) -eq 'Commander'
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

    $role = Get-RoleGateCurrentRole
    if ($null -eq $role) {
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
        'name' {
            if ($permissions.Name) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'resolve' {
            if ($permissions.Resolve) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'focus' {
            if ($permissions.Focus) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'focus-lock' {
            if ($permissions.Focus) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'focus-unlock' {
            if ($permissions.Focus) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'signal' {
            if ($permissions.Signal) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'wait' {
            if ($permissions.Wait) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'profile' {
            if ($permissions.Profile) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'lock' {
            if ($permissions.Lock) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'unlock' {
            if ($permissions.Unlock) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'locks' {
            if ($permissions.Locks) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'mailbox-create' {
            if ($permissions.MailboxCreate) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'mailbox-send' {
            if ($permissions.MailboxSend) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'mailbox-listen' {
            if ($permissions.MailboxListen) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'kill' {
            if ($permissions.Kill) { return $true }
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
        'restart' {
            if ($permissions.Restart) { return $true }
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
        default { # fail-close: unknown commands are denied
            return Deny-RoleCommand -Role $role -Command $normalizedCommand
        }
    }
}
