$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'clm-safe-io.ps1')

$script:OrchestraAttachProfileName = 'winsmux orchestra attach'

function Get-OrchestraAttachRoot {
    $localAppData = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $HOME 'AppData\Local'
    } else {
        $env:LOCALAPPDATA
    }

    return Join-Path $localAppData 'winsmux\ui-attach'
}

function Get-OrchestraAttachStatePath {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    return Join-Path (Get-OrchestraAttachRoot) ("{0}.json" -f $SessionName)
}

function Get-OrchestraAttachEntryScriptPath {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'orchestra-attach-entry.ps1'))
}

function Get-OrchestraAttachConfirmScriptPath {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'orchestra-attach-confirm.ps1'))
}

function Get-OrchestraAttachFragmentDir {
    $localAppData = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $HOME 'AppData\Local'
    } else {
        $env:LOCALAPPDATA
    }

    return Join-Path $localAppData 'Microsoft\Windows Terminal\Fragments\winsmux'
}

function Get-OrchestraAttachFragmentPath {
    return Join-Path (Get-OrchestraAttachFragmentDir) 'winsmux-orchestra-attach.json'
}

function Get-OrchestraPowerShellPath {
    $pwshPath = Get-Command 'pwsh' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
        throw 'pwsh executable could not be resolved.'
    }

    return [System.IO.Path]::GetFullPath($pwshPath)
}

function Read-OrchestraAttachState {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    $path = Get-OrchestraAttachStatePath -SessionName $SessionName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    try {
        return $raw | ConvertFrom-Json -Depth 8
    } catch {
        return $null
    }
}

function ConvertTo-OrchestraAttachProcessId {
    param([AllowNull()]$Value)

    $processId = 0
    if ($null -eq $Value) {
        return 0
    }

    if ([int]::TryParse(([string]$Value), [ref]$processId)) {
        return $processId
    }

    return 0
}

function Test-OrchestraProcessAlive {
    param([AllowNull()]$ProcessId)

    $resolvedProcessId = ConvertTo-OrchestraAttachProcessId -Value $ProcessId
    if ($resolvedProcessId -le 0) {
        return $false
    }

    try {
        return ($null -ne (Get-Process -Id $resolvedProcessId -ErrorAction SilentlyContinue))
    } catch {
        return $false
    }
}

function Test-OrchestraLiveVisibleAttachState {
    param(
        [AllowNull()]$State,
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    if ($null -eq $State) {
        return $false
    }

    $stateSessionName = [string]$State.session_name
    if (-not [string]::IsNullOrWhiteSpace($stateSessionName) -and $stateSessionName -ne $SessionName) {
        return $false
    }

    $status = [string]$State.attach_status
    if ($status -ne 'attach_confirmed') {
        return $false
    }

    return (Test-OrchestraProcessAlive -ProcessId $State.attach_process_id)
}

function Get-OrchestraBaselineClients {
    param(
        [AllowNull()]$BaselineClients,
        [AllowNull()]$State
    )

    $clients = @()
    if ($null -ne $BaselineClients) {
        $clients = @(
            @($BaselineClients) |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    if ($clients.Count -gt 0) {
        return $clients
    }

    if ($null -ne $State -and $State.PSObject.Properties.Name -contains 'baseline_clients') {
        return @(
            @($State.baseline_clients) |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    return @()
}

function Test-OrchestraAttachClientTransition {
    param(
        [AllowEmptyCollection()][string[]]$BaselineClients = @(),
        [AllowEmptyCollection()][string[]]$CurrentClients = @()
    )

    $baseline = @(
        @($BaselineClients) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $current = @(
        @($CurrentClients) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    if ($baseline.Count -eq 0) {
        return ($current.Count -gt 0)
    }

    if ($baseline.Count -ne $current.Count) {
        return $true
    }

    if ($baseline.Count -eq 0 -and $current.Count -eq 0) {
        return $false
    }

    return (($baseline -join "`n") -ne ($current -join "`n"))
}

function Test-OrchestraAttachClientSnapshotMatch {
    param(
        [AllowNull()]$ExpectedClients,
        [AllowNull()]$CurrentClients
    )

    $expected = @(
        @($ExpectedClients) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $current = @(
        @($CurrentClients) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    if ($expected.Count -eq 0) {
        return $false
    }

    return (($expected -join "`n") -eq ($current -join "`n"))
}

function Write-OrchestraAttachState {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][hashtable]$Properties
    )

    $existing = Read-OrchestraAttachState -SessionName $SessionName
    $state = [ordered]@{}
    if ($null -ne $existing) {
        foreach ($property in $existing.PSObject.Properties) {
            $state[$property.Name] = $property.Value
        }
    }

    foreach ($key in $Properties.Keys) {
        $state[$key] = $Properties[$key]
    }

    $statePath = Get-OrchestraAttachStatePath -SessionName $SessionName
    $json = ($state | ConvertTo-Json -Depth 8)
    Write-WinsmuxTextFile -Path $statePath -Content $json
    return [pscustomobject]$state
}

function Get-OrchestraAttachedClientSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$WinsmuxBin,
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    $clients = @()
    $error = ''
    $ok = $false

    if ([string]::IsNullOrWhiteSpace($WinsmuxBin)) {
        return [PSCustomObject][ordered]@{
            Ok      = $false
            Count   = 0
            Error   = 'winsmux executable could not be resolved.'
            Clients = @()
        }
    }

    try {
        $clientLines = & $WinsmuxBin 'list-clients' '-t' $SessionName 2>&1
        if ($LASTEXITCODE -eq 0) {
            $clients = @(
                $clientLines |
                    ForEach-Object { [string]$_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            $ok = $true
        } else {
            $error = ($clientLines | Out-String).Trim()
        }
    } catch {
        $error = $_.Exception.Message
    }

    [PSCustomObject][ordered]@{
        Ok      = $ok
        Count   = $clients.Count
        Error   = $error
        Clients = @($clients)
    }
}

function Get-OrchestraWindowsTerminalInfo {
    $wtExe = Get-Command 'wt.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
    $canonicalWtExe = ''
    $reason = 'wt_unavailable'
    $pathSource = ''
    $isAliasStub = $false

    if (-not [string]::IsNullOrWhiteSpace($wtExe)) {
        try {
            $wtItem = Get-Item -LiteralPath $wtExe -ErrorAction Stop
            $windowsAppsRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
            $normalizedWtExe = [System.IO.Path]::GetFullPath($wtExe)
            $normalizedWindowsAppsRoot = [System.IO.Path]::GetFullPath($windowsAppsRoot)
            if ($wtItem.Length -eq 0 -or $normalizedWtExe.StartsWith($normalizedWindowsAppsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isAliasStub = $true
            } else {
                $canonicalWtExe = $normalizedWtExe
                $reason = 'ready'
                $pathSource = 'command'
            }
        } catch {
        }
    }

    if ([string]::IsNullOrWhiteSpace($canonicalWtExe)) {
        foreach ($packageName in @('Microsoft.WindowsTerminal', 'Microsoft.WindowsTerminalPreview')) {
            try {
                $package = Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -eq $package -or [string]::IsNullOrWhiteSpace([string]$package.InstallLocation)) {
                    continue
                }

                $candidatePath = Join-Path ([string]$package.InstallLocation) 'wt.exe'
                if (-not (Test-Path -LiteralPath $candidatePath)) {
                    continue
                }

                $canonicalWtExe = [System.IO.Path]::GetFullPath($candidatePath)
                $reason = if ($isAliasStub) { 'resolved_from_appx' } else { 'ready' }
                $pathSource = 'appx'
                break
            } catch {
            }
        }
    }

    return [PSCustomObject][ordered]@{
        Available   = -not [string]::IsNullOrWhiteSpace($canonicalWtExe)
        Path        = $canonicalWtExe
        AliasPath   = if ($isAliasStub) { [string]$wtExe } else { '' }
        IsAliasStub = $isAliasStub
        PathSource  = $pathSource
        Reason      = if (-not [string]::IsNullOrWhiteSpace($canonicalWtExe)) { $reason } elseif ($isAliasStub) { 'wt_alias_stub' } else { 'wt_unavailable' }
    }
}

function Get-OrchestraAttachEntryArgumentList {
    $attachEntryScriptPath = Get-OrchestraAttachEntryScriptPath
    return @('-NoLogo', '-NoExit', '-File', $attachEntryScriptPath)
}

function Start-OrchestraWindowsTerminalVisibleAttach {
    param(
        [Parameter(Mandatory = $true)][string]$TerminalPath,
        [Parameter(Mandatory = $true)][string]$ProfileName
    )

    $process = Start-Process -FilePath $TerminalPath -ArgumentList @('-w', '-1', 'new-window', '-p', $ProfileName) -PassThru
    return [PSCustomObject][ordered]@{
        HostKind = 'windows-terminal'
        Path     = $TerminalPath
        Process  = $process
    }
}

function Start-OrchestraPowerShellVisibleAttach {
    $pwshPath = Get-OrchestraPowerShellPath
    $process = Start-Process -FilePath $pwshPath -ArgumentList (Get-OrchestraAttachEntryArgumentList) -PassThru
    return [PSCustomObject][ordered]@{
        HostKind = 'powershell-window'
        Path     = $pwshPath
        Process  = $process
    }
}

function Wait-OrchestraAttachLaunchObservation {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$WinsmuxBin,
        [Parameter(Mandatory = $true)][int]$BaselineClientCount,
        [AllowEmptyCollection()][string[]]$BaselineClients = @(),
        [int]$TimeoutMilliseconds = 2500,
        [int]$PollMilliseconds = 250
    )

    $deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds)
    do {
        $state = Read-OrchestraAttachState -SessionName $SessionName
        if ($null -ne $state) {
            $status = [string]$state.attach_status
            if ($status -in @('attach_entry_started', 'attach_confirming', 'attach_confirmed')) {
                return [PSCustomObject][ordered]@{
                    Observed = $true
                    Reason   = "Attach state advanced to '$status'."
                }
            }
        }

        $snapshot = Get-OrchestraAttachedClientSnapshot -WinsmuxBin $WinsmuxBin -SessionName $SessionName
        $effectiveBaselineClients = @(Get-OrchestraBaselineClients -BaselineClients $BaselineClients -State $state)
        $clientTransition = if ([bool]$snapshot.Ok) {
            Test-OrchestraAttachClientTransition -BaselineClients $effectiveBaselineClients -CurrentClients @($snapshot.Clients)
        } else {
            $false
        }

        if ([bool]$snapshot.Ok -and (([int]$snapshot.Count -ge ($BaselineClientCount + 1)) -or $clientTransition)) {
            return [PSCustomObject][ordered]@{
                Observed = $true
                Reason   = 'Attached client probe changed during attach launch.'
            }
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    } while ((Get-Date) -lt $deadline)

    return [PSCustomObject][ordered]@{
        Observed = $false
        Reason   = 'Attach launch did not advance state or change attached clients before timeout.'
    }
}

function Ensure-OrchestraAttachProfile {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $fragmentDir = Get-OrchestraAttachFragmentDir
    if (-not (Test-Path -LiteralPath $fragmentDir -PathType Container)) {
        New-Item -ItemType Directory -Path $fragmentDir -Force | Out-Null
    }

    $pwshPath = Get-OrchestraPowerShellPath
    $attachEntryScriptPath = Get-OrchestraAttachEntryScriptPath
    $commandline = '"{0}" -NoLogo -NoExit -File "{1}"' -f $pwshPath, $attachEntryScriptPath

    $fragment = @{
        profiles = @(
            @{
                name                    = $script:OrchestraAttachProfileName
                commandline             = $commandline
                tabTitle                = 'winsmux-orchestra'
                suppressApplicationTitle = $true
                startingDirectory       = $ProjectDir
                hidden                  = $false
            }
        )
    }

    $json = $fragment | ConvertTo-Json -Depth 6
    $fragmentPath = Get-OrchestraAttachFragmentPath
    Write-WinsmuxTextFile -Path $fragmentPath -Content $json

    return [PSCustomObject][ordered]@{
        ProfileName  = $script:OrchestraAttachProfileName
        FragmentPath = $fragmentPath
        Commandline  = $commandline
    }
}

function Wait-OrchestraAttachHandshake {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$WinsmuxBin,
        [Parameter(Mandatory = $true)][int]$BaselineClientCount,
        [AllowEmptyCollection()][string[]]$BaselineClients = @(),
        [int]$TimeoutMilliseconds = 12000,
        [int]$PollMilliseconds = 250
    )

    $targetClientCount = $BaselineClientCount + 1
    $deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds)
    $lastError = ''

    do {
        $state = Read-OrchestraAttachState -SessionName $SessionName
        if ($null -ne $state) {
            $status = [string]$state.attach_status
            if ($status -eq 'attach_confirmed') {
                return [PSCustomObject][ordered]@{
                    Confirmed           = $true
                    Source              = 'handshake'
                    Status              = 'attach_confirmed'
                    Reason              = [string]$state.error
                    AttachedClientCount = [int]$state.client_count_seen
                    State               = $state
                }
            }

            if ($status -eq 'attach_failed') {
                $lastError = [string]$state.error
            }
        }

        $snapshot = Get-OrchestraAttachedClientSnapshot -WinsmuxBin $WinsmuxBin -SessionName $SessionName
        $effectiveBaselineClients = Get-OrchestraBaselineClients -BaselineClients $BaselineClients -State $state
        $clientTransition = if ([bool]$snapshot.Ok) {
            Test-OrchestraAttachClientTransition -BaselineClients $effectiveBaselineClients -CurrentClients @($snapshot.Clients)
        } else {
            $false
        }
        $attachEntryObserved = $false
        if ($null -ne $state) {
            $currentStatus = [string]$state.attach_status
            $attachEntryObserved = $currentStatus -in @('attach_entry_started', 'attach_confirming', 'attach_confirmed')
        }
        $countAdvanced = [bool]$snapshot.Ok -and ([int]$snapshot.Count -ge $targetClientCount)
        $countBasedConfirmationAllowed = $countAdvanced -and (
            ($BaselineClientCount -gt 0) -or
            (@($effectiveBaselineClients).Count -gt 0) -or
            $attachEntryObserved
        )
        $identityBasedConfirmationAllowed = $clientTransition -and (@($effectiveBaselineClients).Count -gt 0)

        if ($countBasedConfirmationAllowed -or $identityBasedConfirmationAllowed) {
            $source = if ($attachEntryObserved) { 'handshake' } else { 'client-probe' }

            $confirmedAt = (Get-Date).ToString('o')
            $updatedState = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                attach_status       = 'attach_confirmed'
                attach_confirmed_at = $confirmedAt
                client_count_seen   = [int]$snapshot.Count
                attached_client_count = [int]$snapshot.Count
                attached_client_snapshot = @($snapshot.Clients)
                ui_attach_source    = $source
                error               = if ($identityBasedConfirmationAllowed -and [int]$snapshot.Count -lt $targetClientCount) {
                    "Visible attach confirmed for session '$SessionName' after attached client identity changed."
                } else {
                    "Visible attach confirmed for session '$SessionName' with $($snapshot.Count) attached client(s)."
                }
            }

            return [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = $source
                Status              = 'attach_confirmed'
                Reason              = [string]$updatedState.error
                AttachedClientCount = [int]$snapshot.Count
                State               = $updatedState
            }
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    } while ((Get-Date) -lt $deadline)

    $failedState = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
        attach_status     = 'attach_failed'
        ui_attach_source  = 'none'
        client_count_seen = $BaselineClientCount
        error             = if ([string]::IsNullOrWhiteSpace($lastError)) {
            "Attach confirmation timed out before client count reached $targetClientCount."
        } else {
            $lastError
        }
    }

    return [PSCustomObject][ordered]@{
        Confirmed           = $false
        Source              = 'none'
        Status              = 'attach_failed'
        Reason              = [string]$failedState.error
        AttachedClientCount = $BaselineClientCount
        State               = $failedState
    }
}
