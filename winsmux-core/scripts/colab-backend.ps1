$ErrorActionPreference = 'Stop'

$script:WinsmuxColabStateVersion = 1
$script:WinsmuxColabDefaultGpuFallback = @('H100', 'A100', 'L4', 'T4', 'CPU')

function Get-WinsmuxColabValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }

        return $Default
    }

    if ($null -ne $InputObject.PSObject -and ($InputObject.PSObject.Properties.Name -contains $Name)) {
        return $InputObject.$Name
    }

    return $Default
}

function ConvertTo-WinsmuxColabStringArray {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        return @($Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Value)) {
        $text = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $items.Add($text.Trim()) | Out-Null
        }
    }

    return @($items)
}

function Get-WinsmuxColabStatePath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path (Join-Path (Join-Path $ProjectDir '.winsmux') 'state') 'colab_sessions.json'
}

function Read-WinsmuxColabSessionStore {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $path = Get-WinsmuxColabStatePath -ProjectDir $ProjectDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [PSCustomObject]@{
            version    = $script:WinsmuxColabStateVersion
            updated_at = ''
            sessions   = @()
        }
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [PSCustomObject]@{
            version    = $script:WinsmuxColabStateVersion
            updated_at = ''
            sessions   = @()
        }
    }

    try {
        $store = $raw | ConvertFrom-Json -Depth 20
    } catch {
        return [PSCustomObject]@{
            version           = $script:WinsmuxColabStateVersion
            updated_at        = ''
            sessions          = @()
            read_error        = 'colab_state_unreadable'
            read_error_detail = $_.Exception.Message
        }
    }
    if ($null -eq $store) {
        return [PSCustomObject]@{
            version    = $script:WinsmuxColabStateVersion
            updated_at = ''
            sessions   = @()
        }
    }

    return $store
}

function Write-WinsmuxColabSessionStore {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Store
    )

    $path = Get-WinsmuxColabStatePath -ProjectDir $ProjectDir
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    ($Store | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Get-WinsmuxColabProjectSlug {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $leaf = Split-Path -Leaf ([System.IO.Path]::GetFullPath($ProjectDir))
    $slug = ($leaf.ToLowerInvariant() -replace '[^a-z0-9_-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return 'winsmux-project'
    }

    return $slug
}

function Resolve-WinsmuxColabSessionName {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [AllowEmptyString()][string]$Template = ''
    )

    $projectSlug = Get-WinsmuxColabProjectSlug -ProjectDir $ProjectDir
    $slotSlug = ($SlotId.ToLowerInvariant() -replace '[^a-z0-9_-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slotSlug)) {
        $slotSlug = 'worker'
    }

    if ([string]::IsNullOrWhiteSpace($Template)) {
        return ("{0}_{1}" -f $projectSlug, ($slotSlug -replace '-', '_'))
    }

    return $Template.Replace('{{project_slug}}', $projectSlug).Replace('{{slot_id}}', $slotSlug)
}

function Get-WinsmuxColabCliAvailability {
    param([AllowEmptyString()][string]$Command = '')

    $requested = $Command
    if ([string]::IsNullOrWhiteSpace($requested)) {
        $requested = [string]$env:WINSMUX_COLAB_CLI
    }
    if ([string]::IsNullOrWhiteSpace($requested)) {
        $requested = 'google-colab-cli'
    }

    try {
        $resolved = Get-Command -Name $requested -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $resolved) {
            return [PSCustomObject]@{
                available = $true
                command   = $requested
                path      = [string]$resolved.Source
                reason    = ''
            }
        }
    } catch {
    }

    return [PSCustomObject]@{
        available = $false
        command   = $requested
        path      = ''
        reason    = 'colab_cli_missing'
    }
}

function Get-WinsmuxColabAuthState {
    param([Parameter(Mandatory = $true)]$CliAvailability)

    if (-not [bool](Get-WinsmuxColabValue -InputObject $CliAvailability -Name 'available' -Default $false)) {
        return [PSCustomObject]@{
            state     = 'unknown'
            available = $false
            reason    = 'colab_cli_missing'
        }
    }

    $raw = ([string]$env:WINSMUX_COLAB_AUTH_STATE).Trim().ToLowerInvariant()
    switch ($raw) {
        { $_ -in @('authenticated', 'ok', 'signed_in', 'signed-in') } {
            return [PSCustomObject]@{
                state     = 'authenticated'
                available = $true
                reason    = ''
            }
        }
        { $_ -in @('missing', 'unauthenticated', 'not_authenticated', 'not-authenticated') } {
            return [PSCustomObject]@{
                state     = 'missing'
                available = $false
                reason    = 'colab_auth_missing'
            }
        }
    }

    return [PSCustomObject]@{
        state     = 'unknown'
        available = $false
        reason    = 'colab_auth_unverified'
    }
}

function Resolve-WinsmuxColabGpuSelection {
    param(
        [AllowNull()]$GpuPreference = @(),
        [AllowNull()]$AvailableGpu = @()
    )

    $preference = @(ConvertTo-WinsmuxColabStringArray -Value $GpuPreference | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($preference.Count -eq 0) {
        $preference = @('H100', 'A100', 'L4', 'T4')
    }

    $fallback = [System.Collections.Generic.List[string]]::new()
    foreach ($gpu in @($preference + $script:WinsmuxColabDefaultGpuFallback)) {
        $normalized = ([string]$gpu).Trim().ToUpperInvariant()
        if (-not [string]::IsNullOrWhiteSpace($normalized) -and -not $fallback.Contains($normalized)) {
            $fallback.Add($normalized) | Out-Null
        }
    }
    if (-not $fallback.Contains('CPU')) {
        $fallback.Add('CPU') | Out-Null
    }

    $available = @(ConvertTo-WinsmuxColabStringArray -Value $AvailableGpu | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $selected = 'CPU'
    $reason = ''
    if ($available.Count -gt 0) {
        foreach ($candidate in @($fallback)) {
            if ($candidate -eq 'CPU' -or $available -contains $candidate) {
                $selected = $candidate
                break
            }
        }
        $reason = if ($selected -eq $preference[0]) { '' } elseif ($selected -eq 'CPU') { 'requested_gpu_unavailable' } else { 'gpu_fallback_selected' }
    }

    return [PSCustomObject]@{
        requested      = @($preference)
        available      = @($available)
        inventory_known = ($available.Count -gt 0)
        fallback_chain = @($fallback)
        selected       = $selected
        degraded       = (-not [string]::IsNullOrWhiteSpace($reason))
        reason         = $reason
    }
}

function Get-WinsmuxColabAvailableGpuOverride {
    return @(ConvertTo-WinsmuxColabStringArray -Value ([string]$env:WINSMUX_COLAB_AVAILABLE_GPUS))
}

function Get-WinsmuxColabConfiguredSlots {
    param([Parameter(Mandatory = $true)]$Settings)

    if ($Settings -is [System.Collections.IDictionary]) {
        if ($Settings.Contains('agent_slots')) {
            return @($Settings['agent_slots'])
        }

        return @()
    }

    if ($null -ne $Settings.PSObject -and ($Settings.PSObject.Properties.Name -contains 'agent_slots')) {
        return @($Settings.agent_slots)
    }

    return @()
}

function Get-WinsmuxColabSlotId {
    param([AllowNull()]$Slot)

    $slotId = [string](Get-WinsmuxColabValue -InputObject $Slot -Name 'slot_id' -Default '')
    if ([string]::IsNullOrWhiteSpace($slotId)) {
        $slotId = [string](Get-WinsmuxColabValue -InputObject $Slot -Name 'slot-id' -Default '')
    }

    return $slotId
}

function ConvertTo-WinsmuxColabStaleRecord {
    param(
        [Parameter(Mandatory = $true)]$ExistingRecord,
        [Parameter(Mandatory = $true)][string]$Now,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    return [ordered]@{
        slot_id         = [string](Get-WinsmuxColabValue -InputObject $ExistingRecord -Name 'slot_id' -Default '')
        worker_backend  = 'colab_cli'
        session_name    = [string](Get-WinsmuxColabValue -InputObject $ExistingRecord -Name 'session_name' -Default '')
        state           = 'stale'
        stale           = $true
        stale_reason    = $Reason
        stale_at        = $Now
        previous_state  = [string](Get-WinsmuxColabValue -InputObject $ExistingRecord -Name 'state' -Default '')
        checked_at      = [string](Get-WinsmuxColabValue -InputObject $ExistingRecord -Name 'checked_at' -Default '')
        updated_at      = $Now
        selected_gpu    = [string](Get-WinsmuxColabValue -InputObject $ExistingRecord -Name 'selected_gpu' -Default '')
        degraded_reason = [string](Get-WinsmuxColabValue -InputObject $ExistingRecord -Name 'degraded_reason' -Default '')
    }
}

function New-WinsmuxColabSessionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SlotId,
        [Parameter(Mandatory = $true)]$SlotAgentConfig,
        [AllowNull()]$PreviousRecord,
        [Parameter(Mandatory = $true)][string]$Now,
        [AllowEmptyString()][string]$StateReadError = ''
    )

    $sessionName = Resolve-WinsmuxColabSessionName -ProjectDir $ProjectDir -SlotId $SlotId -Template ([string]$SlotAgentConfig.SessionName)
    $cli = Get-WinsmuxColabCliAvailability
    $auth = Get-WinsmuxColabAuthState -CliAvailability $cli
    $gpu = Resolve-WinsmuxColabGpuSelection -GpuPreference @($SlotAgentConfig.GpuPreference) -AvailableGpu (Get-WinsmuxColabAvailableGpuOverride)

    $reasons = [System.Collections.Generic.List[string]]::new()
    foreach ($reason in @([string]$StateReadError, [string]$cli.reason, [string]$auth.reason, [string]$gpu.reason)) {
        if (-not [string]::IsNullOrWhiteSpace($reason) -and -not $reasons.Contains($reason)) {
            $reasons.Add($reason) | Out-Null
        }
    }

    $degraded = ($reasons.Count -gt 0)
    $previousState = ''
    if ($null -ne $PreviousRecord) {
        $previousState = [string](Get-WinsmuxColabValue -InputObject $PreviousRecord -Name 'state' -Default '')
    }

    return [ordered]@{
        slot_id          = $SlotId
        worker_backend   = 'colab_cli'
        session_name     = $sessionName
        state            = if ($degraded) { 'degraded' } else { 'available' }
        degraded         = $degraded
        degraded_reason  = ($reasons -join ';')
        stale            = $false
        reused_session   = ($null -ne $PreviousRecord)
        previous_state   = $previousState
        cli_command      = [string]$cli.command
        cli_path         = [string]$cli.path
        cli_available    = [bool]$cli.available
        auth_state       = [string]$auth.state
        auth_available   = [bool]$auth.available
        requested_gpu    = @($gpu.requested)
        available_gpu    = @($gpu.available)
        fallback_chain   = @($gpu.fallback_chain)
        selected_gpu     = [string]$gpu.selected
        packages         = @(ConvertTo-WinsmuxColabStringArray -Value $SlotAgentConfig.Packages)
        bootstrap        = [string]$SlotAgentConfig.Bootstrap
        task_script      = [string]$SlotAgentConfig.TaskScript
        checked_at       = $Now
        updated_at       = $Now
    }
}

function Update-WinsmuxColabSessionState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Settings
    )

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $existingStore = Read-WinsmuxColabSessionStore -ProjectDir $ProjectDir
    $existingSessions = @(Get-WinsmuxColabValue -InputObject $existingStore -Name 'sessions' -Default @())
    $stateReadError = [string](Get-WinsmuxColabValue -InputObject $existingStore -Name 'read_error' -Default '')
    $configuredSlots = @(Get-WinsmuxColabConfiguredSlots -Settings $Settings)
    $activeRecords = [System.Collections.Generic.List[object]]::new()
    $activeSlotIds = [System.Collections.Generic.List[string]]::new()
    $activeKeys = [System.Collections.Generic.List[string]]::new()
    $previousByKey = @{}

    foreach ($record in @($existingSessions)) {
        $slotId = [string](Get-WinsmuxColabValue -InputObject $record -Name 'slot_id' -Default '')
        $sessionName = [string](Get-WinsmuxColabValue -InputObject $record -Name 'session_name' -Default '')
        if ([string]::IsNullOrWhiteSpace($slotId) -or [string]::IsNullOrWhiteSpace($sessionName)) {
            continue
        }

        $key = "$slotId`n$sessionName"
        if (-not $previousByKey.ContainsKey($key)) {
            $previousByKey[$key] = $record
        }
    }

    foreach ($slot in $configuredSlots) {
        $slotId = Get-WinsmuxColabSlotId -Slot $slot
        if ([string]::IsNullOrWhiteSpace($slotId)) {
            continue
        }

        $slotConfig = Get-SlotAgentConfig -Role 'Worker' -SlotId $slotId -Settings $Settings -RootPath $ProjectDir
        if (-not [string]::Equals(([string]$slotConfig.WorkerBackend), 'colab_cli', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $sessionName = Resolve-WinsmuxColabSessionName -ProjectDir $ProjectDir -SlotId $slotId -Template ([string]$slotConfig.SessionName)
        $key = "$slotId`n$sessionName"
        $previous = if ($previousByKey.ContainsKey($key)) { $previousByKey[$key] } else { $null }
        $record = New-WinsmuxColabSessionRecord -ProjectDir $ProjectDir -SlotId $slotId -SlotAgentConfig $slotConfig -PreviousRecord $previous -Now $now -StateReadError $stateReadError
        $activeRecords.Add($record) | Out-Null
        if (-not $activeSlotIds.Contains($slotId)) {
            $activeSlotIds.Add($slotId) | Out-Null
        }
        if (-not $activeKeys.Contains($key)) {
            $activeKeys.Add($key) | Out-Null
        }
    }

    $nextSessions = [System.Collections.Generic.List[object]]::new()
    foreach ($record in @($existingSessions)) {
        $slotId = [string](Get-WinsmuxColabValue -InputObject $record -Name 'slot_id' -Default '')
        $sessionName = [string](Get-WinsmuxColabValue -InputObject $record -Name 'session_name' -Default '')
        if ([string]::IsNullOrWhiteSpace($slotId) -or [string]::IsNullOrWhiteSpace($sessionName)) {
            continue
        }

        $key = "$slotId`n$sessionName"
        if ($activeKeys.Contains($key)) {
            continue
        }

        $alreadyStale = [bool](Get-WinsmuxColabValue -InputObject $record -Name 'stale' -Default $false)
        if ($alreadyStale) {
            $nextSessions.Add($record) | Out-Null
            continue
        }

        $reason = if ($activeSlotIds.Contains($slotId)) { 'slot_session_name_changed' } else { 'slot_removed_or_backend_changed' }
        $nextSessions.Add((ConvertTo-WinsmuxColabStaleRecord -ExistingRecord $record -Now $now -Reason $reason)) | Out-Null
    }

    foreach ($record in @($activeRecords)) {
        $nextSessions.Add($record) | Out-Null
    }

    $path = Get-WinsmuxColabStatePath -ProjectDir $ProjectDir
    if ($activeRecords.Count -eq 0 -and $existingSessions.Count -eq 0) {
        return [PSCustomObject]@{
            version        = $script:WinsmuxColabStateVersion
            updated_at     = $now
            path           = $path
            sessions       = @()
            active_sessions = @()
            degraded_count = 0
        }
    }

    $store = [ordered]@{
        version    = $script:WinsmuxColabStateVersion
        updated_at = $now
        sessions   = @($nextSessions)
    }
    $path = Write-WinsmuxColabSessionStore -ProjectDir $ProjectDir -Store $store

    return [PSCustomObject]@{
        version        = $script:WinsmuxColabStateVersion
        updated_at     = $now
        path           = $path
        sessions       = @($nextSessions)
        active_sessions = @($activeRecords)
        degraded_count = @($activeRecords | Where-Object { [bool](Get-WinsmuxColabValue -InputObject $_ -Name 'degraded' -Default $false) }).Count
    }
}

function New-WinsmuxColabStateUpdateFailureRecords {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($slot in @(Get-WinsmuxColabConfiguredSlots -Settings $Settings)) {
        $slotId = Get-WinsmuxColabSlotId -Slot $slot
        if ([string]::IsNullOrWhiteSpace($slotId)) {
            continue
        }

        $slotConfig = Get-SlotAgentConfig -Role 'Worker' -SlotId $slotId -Settings $Settings -RootPath $ProjectDir
        if (-not [string]::Equals(([string]$slotConfig.WorkerBackend), 'colab_cli', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $records.Add([ordered]@{
            slot_id         = $slotId
            worker_backend  = 'colab_cli'
            session_name    = Resolve-WinsmuxColabSessionName -ProjectDir $ProjectDir -SlotId $slotId -Template ([string]$slotConfig.SessionName)
            state           = 'degraded'
            degraded        = $true
            degraded_reason = $Reason
            stale           = $false
            selected_gpu    = 'CPU'
            checked_at      = $now
            updated_at      = $now
        }) | Out-Null
    }

    return @($records)
}
