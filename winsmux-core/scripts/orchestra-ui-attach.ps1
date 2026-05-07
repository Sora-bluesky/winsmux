$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'clm-safe-io.ps1')
if (-not (Get-Command Invoke-WinsmuxBridgeCommand -ErrorAction SilentlyContinue)) {
    $settingsScript = Join-Path $PSScriptRoot 'settings.ps1'
    if (Test-Path -LiteralPath $settingsScript -PathType Leaf) {
        . $settingsScript
    }
}

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

function Get-OrchestraAttachRequestId {
    param([AllowNull()]$State)

    if ($null -eq $State) {
        return ''
    }

    foreach ($name in @('attach_request_id', 'request_id')) {
        if ($null -ne $State.PSObject.Properties[$name]) {
            $value = [string]$State.$name
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    return ''
}

function Get-OrchestraAttachStateString {
    param(
        [AllowNull()]$State,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $State) {
        return ''
    }

    if ($null -ne $State.PSObject.Properties[$Name]) {
        return [string]$State.$Name
    }

    return ''
}

function Get-OrchestraAttachStateStringArray {
    param(
        [AllowNull()]$State,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $State) {
        return @()
    }

    if ($null -ne $State.PSObject.Properties[$Name]) {
        return @($State.$Name | ForEach-Object { [string]$_ })
    }

    return @()
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

    if ($state.Contains('request_id') -and -not $state.Contains('attach_request_id')) {
        $state['attach_request_id'] = [string]$state['request_id']
    }

    $normalizedProperties = [ordered]@{}
    foreach ($key in $Properties.Keys) {
        $normalizedProperties[$key] = $Properties[$key]
    }

    if ($normalizedProperties.Contains('request_id') -and -not $normalizedProperties.Contains('attach_request_id')) {
        $normalizedProperties['attach_request_id'] = $normalizedProperties['request_id']
    }

    if ($normalizedProperties.Contains('attach_request_id')) {
        $normalizedProperties['request_id'] = $normalizedProperties['attach_request_id']
    }

    foreach ($key in $normalizedProperties.Keys) {
        $state[$key] = $normalizedProperties[$key]
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
        $clientLines = Invoke-WinsmuxBridgeCommand -WinsmuxBin $WinsmuxBin -Arguments @('list-clients', '-t', $SessionName) 2>&1
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

function ConvertTo-OrchestraQuotedArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Start-OrchestraWindowsTerminalVisibleAttach {
    param(
        [Parameter(Mandatory = $true)][string]$TerminalPath,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    $argumentList = @(
        '-w',
        '-1',
        'new-window',
        '-d',
        (ConvertTo-OrchestraQuotedArgument -Value $ProjectDir),
        '--title',
        'winsmux-orchestra',
        '--',
        'pwsh.exe'
    ) + (Get-OrchestraAttachEntryArgumentList | ForEach-Object {
        if ([string]$_ -match '[\s"]') {
            ConvertTo-OrchestraQuotedArgument -Value ([string]$_)
        } else {
            [string]$_
        }
    })

    $process = Start-Process -FilePath $TerminalPath -ArgumentList $argumentList -PassThru
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

function Get-OrchestraAttachTraceEntries {
    param([AllowNull()]$State)

    $traceEntries = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $State) {
        return @()
    }

    $rawEntries = @()
    if ($null -ne $State.PSObject.Properties['attach_adapter_trace']) {
        $rawEntries = @($State.attach_adapter_trace)
    }

    foreach ($rawEntry in $rawEntries) {
        if ($null -eq $rawEntry) {
            continue
        }

        $normalized = [ordered]@{}
        if ($rawEntry -is [System.Collections.IDictionary]) {
            foreach ($key in $rawEntry.Keys) {
                $normalized[[string]$key] = $rawEntry[$key]
            }
        } elseif ($rawEntry -is [string]) {
            $rawText = ([string]$rawEntry).Trim()
            if (-not [string]::IsNullOrWhiteSpace($rawText) -and $rawText.StartsWith('{') -and $rawText.EndsWith('}')) {
                try {
                    $jsonEntry = $rawText | ConvertFrom-Json -Depth 8
                    foreach ($property in $jsonEntry.PSObject.Properties) {
                        $normalized[$property.Name] = $property.Value
                    }
                } catch {
                }
            }
        } elseif ($null -ne $rawEntry.PSObject) {
            foreach ($property in $rawEntry.PSObject.Properties) {
                $normalized[$property.Name] = $property.Value
            }
        }

        if ($normalized.Count -gt 0) {
            $traceEntries.Add([PSCustomObject]$normalized) | Out-Null
        }
    }

    return @($traceEntries.ToArray())
}

function ConvertTo-OrchestraAttachTracePersistedEntries {
    param([AllowEmptyCollection()]$TraceEntries = @())

    $persistedEntries = [System.Collections.Generic.List[string]]::new()
    foreach ($traceEntry in @(Get-OrchestraAttachTraceEntries -State ([pscustomobject]@{ attach_adapter_trace = @($TraceEntries) }))) {
        $persistedEntries.Add(($traceEntry | ConvertTo-Json -Compress -Depth 8)) | Out-Null
    }

    return @($persistedEntries.ToArray())
}

function Add-OrchestraAttachTraceEntry {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][hashtable]$Entry
    )

    $state = Read-OrchestraAttachState -SessionName $SessionName
    $traceEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($existingEntry in @(Get-OrchestraAttachTraceEntries -State $state)) {
        $traceEntries.Add($existingEntry) | Out-Null
    }

    $normalizedEntry = [ordered]@{
        sequence = ($traceEntries.Count + 1)
    }

    foreach ($key in $Entry.Keys) {
        $normalizedEntry[$key] = $Entry[$key]
    }

    $traceEntries.Add([PSCustomObject]$normalizedEntry) | Out-Null
    $updatedState = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
        attach_adapter_trace = @($traceEntries.ToArray())
    }

    return [PSCustomObject][ordered]@{
        State = $updatedState
        Trace = @($traceEntries.ToArray())
        Entry = [PSCustomObject]$normalizedEntry
    }
}

function Get-OrchestraVisibleAttachHostCandidates {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $terminalInfo = Get-OrchestraWindowsTerminalInfo
    $windowsTerminalAvailable = [bool]$terminalInfo.Available
    $windowsTerminalReason = [string]$terminalInfo.Reason
    if ([string]$terminalInfo.PathSource -eq 'appx') {
        $windowsTerminalAvailable = $false
        $windowsTerminalReason = 'wt_appx_direct_launch_unsupported'
    }

    $powerShellPath = ''
    $powerShellReason = 'ready'
    $powerShellAvailable = $true
    try {
        $powerShellPath = Get-OrchestraPowerShellPath
    } catch {
        $powerShellAvailable = $false
        $powerShellReason = $_.Exception.Message
    }

    return @(
        [PSCustomObject][ordered]@{
            HostKind            = 'windows-terminal'
            Available           = $windowsTerminalAvailable
            Path                = [string]$terminalInfo.Path
            Reason              = $windowsTerminalReason
            PathSource          = [string]$terminalInfo.PathSource
            UseLaunchObservation = $true
            ProjectDir          = $ProjectDir
        },
        [PSCustomObject][ordered]@{
            HostKind            = 'powershell-window'
            Available           = $powerShellAvailable
            Path                = $powerShellPath
            Reason              = $powerShellReason
            PathSource          = 'command'
            UseLaunchObservation = $false
            ProjectDir          = $ProjectDir
        }
    )
}

function Start-OrchestraVisibleAttachHostCandidate {
    param([Parameter(Mandatory = $true)]$Candidate)

    switch ([string]$Candidate.HostKind) {
        'windows-terminal' {
            $null = Ensure-OrchestraAttachProfile -ProjectDir ([string]$Candidate.ProjectDir)
            return Start-OrchestraWindowsTerminalVisibleAttach -TerminalPath ([string]$Candidate.Path) -ProjectDir ([string]$Candidate.ProjectDir)
        }
        'powershell-window' {
            return Start-OrchestraPowerShellVisibleAttach
        }
        default {
            throw "Unknown visible attach host candidate '$($Candidate.HostKind)'."
        }
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

function Invoke-OrchestraVisibleAttachRequest {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [AllowEmptyString()][string]$ProjectDir = '',
        [AllowEmptyString()][string]$WinsmuxPathForAttach = ''
    )

    if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
        $ProjectDir = (Get-Location).Path
    }

    $ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)
    $resolvedWinsmuxPath = [string]$WinsmuxPathForAttach
    if (-not [string]::IsNullOrWhiteSpace($resolvedWinsmuxPath) -and -not [System.IO.Path]::IsPathRooted($resolvedWinsmuxPath)) {
        $commandSource = Get-Command $resolvedWinsmuxPath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($commandSource)) {
            $resolvedWinsmuxPath = $commandSource
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedWinsmuxPath) -or -not [System.IO.Path]::IsPathRooted($resolvedWinsmuxPath)) {
        return [PSCustomObject][ordered]@{
            Attempted                = $false
            Launched                 = $false
            Attached                 = $false
            AttachedClientCount      = 0
            Status                   = 'winsmux_unresolved'
            Reason                   = 'winsmux executable could not be resolved to an absolute path for UI attach.'
            Path                     = ''
            Source                   = 'none'
            attach_request_id        = ''
            attached_client_snapshot = @()
            ui_host_kind             = ''
            attach_adapter_trace     = @()
        }
    }

    $clientSnapshot = Get-OrchestraAttachedClientSnapshot -WinsmuxBin $resolvedWinsmuxPath -SessionName $SessionName
    $baselineClientCount = if ([bool]$clientSnapshot.Ok) { [int]$clientSnapshot.Count } else { 0 }
    $baselineClients = if ([bool]$clientSnapshot.Ok) { @($clientSnapshot.Clients) } else { @() }
    $existingAttachState = Read-OrchestraAttachState -SessionName $SessionName
    $existingAttachSource = if ($null -eq $existingAttachState) { '' } else { [string]$existingAttachState.ui_attach_source }
    if ([string]::IsNullOrWhiteSpace($existingAttachSource)) {
        $existingAttachSource = 'handshake'
    }

    $hasLiveVisibleAttach = (Test-OrchestraLiveVisibleAttachState -State $existingAttachState -SessionName $SessionName)
    if ($hasLiveVisibleAttach -and [bool]$clientSnapshot.Ok -and $baselineClientCount -ge 1) {
        $existingAttachState = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
            session_name        = $SessionName
            winsmux_path        = $resolvedWinsmuxPath
            attach_status       = 'attach_confirmed'
            attach_confirmed_at = (Get-Date).ToString('o')
            client_count_seen   = $baselineClientCount
            ui_attach_source    = $existingAttachSource
            error               = "Detected $baselineClientCount attached client(s) for session '$SessionName'."
        }

        return [PSCustomObject][ordered]@{
            Attempted                = $false
            Launched                 = $false
            Attached                 = $true
            AttachedClientCount      = $baselineClientCount
            Status                   = 'attach_already_present'
            Reason                   = "Detected an existing live visible attach for session '$SessionName'; skipped spawning another visible attach window."
            Path                     = ''
            Source                   = $existingAttachSource
            attach_request_id        = (Get-OrchestraAttachRequestId -State $existingAttachState)
            attached_client_snapshot = @(Get-OrchestraAttachStateStringArray -State $existingAttachState -Name 'attached_client_snapshot')
            ui_host_kind             = (Get-OrchestraAttachStateString -State $existingAttachState -Name 'ui_host_kind')
            attach_adapter_trace     = @(Get-OrchestraAttachTraceEntries -State $existingAttachState)
        }
    }

    $existingAttachStatus = if ($null -eq $existingAttachState) { '' } else { [string](Get-OrchestraAttachStateString -State $existingAttachState -Name 'attach_status') }
    $existingAttachedClientSnapshot = if ($null -eq $existingAttachState) { @() } else { @(Get-OrchestraAttachStateStringArray -State $existingAttachState -Name 'attached_client_snapshot') }
    if ($existingAttachStatus -eq 'attach_confirmed' -and [bool]$clientSnapshot.Ok -and (Test-OrchestraAttachClientSnapshotMatch -ExpectedClients $existingAttachedClientSnapshot -CurrentClients @($clientSnapshot.Clients))) {
        $existingAttachState = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
            session_name        = $SessionName
            winsmux_path        = $resolvedWinsmuxPath
            attach_status       = 'attach_confirmed'
            attach_confirmed_at = (Get-Date).ToString('o')
            client_count_seen   = $baselineClientCount
            attached_client_count = $baselineClientCount
            attached_client_snapshot = @($clientSnapshot.Clients)
            ui_attach_source    = 'attached-client-registry'
            error               = "Detected existing attached-client registry confirmation for session '$SessionName'."
        }

        return [PSCustomObject][ordered]@{
            Attempted                = $false
            Launched                 = $false
            Attached                 = $true
            AttachedClientCount      = $baselineClientCount
            Status                   = 'attach_already_present'
            Reason                   = "Detected an existing attached-client confirmation for session '$SessionName'; skipped spawning another visible attach window."
            Path                     = ''
            Source                   = 'attached-client-registry'
            attach_request_id        = (Get-OrchestraAttachRequestId -State $existingAttachState)
            attached_client_snapshot = @(Get-OrchestraAttachStateStringArray -State $existingAttachState -Name 'attached_client_snapshot')
            ui_host_kind             = (Get-OrchestraAttachStateString -State $existingAttachState -Name 'ui_host_kind')
            attach_adapter_trace     = @(Get-OrchestraAttachTraceEntries -State $existingAttachState)
        }
    }

    $attachRequestId = [guid]::NewGuid().ToString('N')
    $state = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
        session_name          = $SessionName
        winsmux_path          = $resolvedWinsmuxPath
        project_dir           = $ProjectDir
        requested_at          = (Get-Date).ToString('o')
        attach_request_id     = $attachRequestId
        baseline_client_count = $baselineClientCount
        baseline_clients      = @($baselineClients)
        client_count_seen     = $baselineClientCount
        attach_process_id     = 0
        attach_status         = 'attach_requested'
        attach_confirmed_at   = ''
        started_at            = ''
        ui_attach_source      = 'none'
        error                 = ''
        attach_adapter_trace  = @()
    }

    $attempted = $false
    $launched = $false
    $lastFailureReason = ''
    $lastLaunchPath = ''
    $hostCandidates = @(Get-OrchestraVisibleAttachHostCandidates -ProjectDir $ProjectDir)

    foreach ($candidate in $hostCandidates) {
        $attempted = $true

        if (-not [bool]$candidate.Available) {
            $traceUpdate = Add-OrchestraAttachTraceEntry -SessionName $SessionName -Entry @{
                host_kind           = [string]$candidate.HostKind
                path                = [string]$candidate.Path
                available           = $false
                availability_reason = [string]$candidate.Reason
                launch_result       = 'skipped_unavailable'
                fallback_reason     = 'adapter_unavailable'
            }
            $state = $traceUpdate.State
            $lastFailureReason = [string]$candidate.Reason
            continue
        }

        try {
            $attachLaunch = Start-OrchestraVisibleAttachHostCandidate -Candidate $candidate
            $lastLaunchPath = [string]$attachLaunch.Path
            $launched = $true
            if ($null -ne $attachLaunch.Process -and $null -ne $attachLaunch.Process.PSObject -and ($attachLaunch.Process.PSObject.Properties.Name -contains 'Id')) {
                $state = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                    attach_process_id = $attachLaunch.Process.Id
                    started_at        = (Get-Date).ToString('o')
                    ui_host_kind      = [string]$attachLaunch.HostKind
                }
            }
        } catch {
            $lastFailureReason = $_.Exception.Message
            $traceUpdate = Add-OrchestraAttachTraceEntry -SessionName $SessionName -Entry @{
                host_kind           = [string]$candidate.HostKind
                path                = [string]$candidate.Path
                available           = $true
                availability_reason = [string]$candidate.Reason
                launch_result       = 'launch_failed'
                fallback_reason     = $lastFailureReason
            }
            $state = $traceUpdate.State
            continue
        }

        if ([bool]$candidate.UseLaunchObservation) {
            $launchObserved = Wait-OrchestraAttachLaunchObservation -SessionName $SessionName -WinsmuxBin $resolvedWinsmuxPath -BaselineClientCount $baselineClientCount -BaselineClients $baselineClients
            if (-not [bool]$launchObserved.Observed) {
                $lastFailureReason = [string]$launchObserved.Reason
                $traceUpdate = Add-OrchestraAttachTraceEntry -SessionName $SessionName -Entry @{
                    host_kind           = [string]$candidate.HostKind
                    path                = [string]$candidate.Path
                    available           = $true
                    availability_reason = [string]$candidate.Reason
                    launch_result       = 'launch_unobserved'
                    fallback_reason     = $lastFailureReason
                }
                $state = $traceUpdate.State
                continue
            }
        }

        $confirmed = Wait-OrchestraAttachHandshake -SessionName $SessionName -WinsmuxBin $resolvedWinsmuxPath -BaselineClientCount $baselineClientCount -BaselineClients $baselineClients
        $confirmedState = if ($null -ne $confirmed.State) { $confirmed.State } else { $state }
        $traceUpdate = Add-OrchestraAttachTraceEntry -SessionName $SessionName -Entry @{
            host_kind           = [string]$candidate.HostKind
            path                = [string]$attachLaunch.Path
            available           = $true
            availability_reason = [string]$candidate.Reason
            launch_result       = if ([bool]$confirmed.Confirmed) { 'attach_confirmed' } else { 'attach_failed' }
            fallback_reason     = if ([bool]$confirmed.Confirmed) { '' } else { [string]$confirmed.Reason }
        }
        $traceState = $traceUpdate.State
        if ($null -ne $confirmedState) {
            $confirmedState = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                attach_request_id        = (Get-OrchestraAttachRequestId -State $confirmedState)
                attached_client_snapshot = @(Get-OrchestraAttachStateStringArray -State $confirmedState -Name 'attached_client_snapshot')
                ui_host_kind             = (Get-OrchestraAttachStateString -State $confirmedState -Name 'ui_host_kind')
                attach_adapter_trace     = @($traceUpdate.Trace)
            }
        } else {
            $confirmedState = $traceState
        }

        if (-not [bool]$confirmed.Confirmed) {
            $state = $confirmedState
            $lastFailureReason = [string]$confirmed.Reason
            continue
        }

        return [PSCustomObject][ordered]@{
            Attempted                = $true
            Launched                 = $launched
            Attached                 = [bool]$confirmed.Confirmed
            AttachedClientCount      = [int]$confirmed.AttachedClientCount
            Status                   = [string]$confirmed.Status
            Reason                   = [string]$confirmed.Reason
            Path                     = [string]$attachLaunch.Path
            Source                   = [string]$confirmed.Source
            attach_request_id        = (Get-OrchestraAttachRequestId -State $confirmedState)
            attached_client_snapshot = @(Get-OrchestraAttachStateStringArray -State $confirmedState -Name 'attached_client_snapshot')
            ui_host_kind             = (Get-OrchestraAttachStateString -State $confirmedState -Name 'ui_host_kind')
            attach_adapter_trace     = @(Get-OrchestraAttachTraceEntries -State $confirmedState)
        }
    }

    $failureReason = if ([string]::IsNullOrWhiteSpace($lastFailureReason)) {
        'No visible attach host adapters were available.'
    } else {
        $lastFailureReason
    }
    $failedState = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
        attach_status      = 'attach_failed'
        ui_attach_source   = 'none'
        client_count_seen  = $baselineClientCount
        error              = $failureReason
    }

    return [PSCustomObject][ordered]@{
        Attempted                = $attempted
        Launched                 = $launched
        Attached                 = $false
        AttachedClientCount      = $baselineClientCount
        Status                   = 'attach_failed'
        Reason                   = $failureReason
        Path                     = $lastLaunchPath
        Source                   = 'none'
        attach_request_id        = (Get-OrchestraAttachRequestId -State $failedState)
        attached_client_snapshot = @(Get-OrchestraAttachStateStringArray -State $failedState -Name 'attached_client_snapshot')
        ui_host_kind             = (Get-OrchestraAttachStateString -State $failedState -Name 'ui_host_kind')
        attach_adapter_trace     = @(Get-OrchestraAttachTraceEntries -State $failedState)
    }
}
