$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'json-compat.ps1')
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
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [string]$ProjectDir = (Get-Location).Path
    )

    $namespace = Get-OrchestraAttachSessionNamespace -ProjectDir $ProjectDir
    if ([string]::IsNullOrWhiteSpace($namespace)) {
        return Join-Path (Get-OrchestraAttachRoot) ("{0}.json" -f $SessionName)
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($namespace))
    } finally {
        $sha256.Dispose()
    }
    $namespaceKey = ([System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()).Substring(0, 16)
    return Join-Path (Get-OrchestraAttachRoot) ("{0}.{1}.json" -f $SessionName, $namespaceKey)
}

function Get-OrchestraRenderReceiptPath {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$RequestId
    )

    if ([string]::IsNullOrWhiteSpace($RequestId)) {
        throw 'Attach request ID is required for a render receipt path.'
    }

    return Join-Path (Get-OrchestraAttachRoot) ("{0}.{1}.render.json" -f $SessionName, $RequestId)
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
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [string]$ProjectDir = (Get-Location).Path
    )

    $path = Get-OrchestraAttachStatePath -SessionName $SessionName -ProjectDir $ProjectDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    try {
        return $raw | ConvertFrom-WinsmuxJson -Depth 8
    } catch {
        return $null
    }
}

function Read-OrchestraRenderReceipt {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }
        return $raw | ConvertFrom-WinsmuxJson -Depth 8
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

function Get-OrchestraAttachSocketNamespaceBase {
    param(
        [Parameter(Mandatory = $true)][string]$SocketSelector,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    $selector = $SocketSelector.Trim()
    if ([string]::IsNullOrWhiteSpace($selector)) {
        return ''
    }
    $looksLikePath = $selector.Contains('\') -or $selector.Contains('/') -or [System.IO.Path]::HasExtension($selector)
    if (-not $looksLikePath) {
        return $selector
    }

    try {
        $path = if ([System.IO.Path]::IsPathRooted($selector)) { $selector } else { Join-Path $ProjectDir $selector }
        $normalized = [System.IO.Path]::GetFullPath($path).Replace('\', '/')
        if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
            $normalized = $normalized.ToLowerInvariant()
        }
    } catch {
        $normalized = $selector.Replace('\', '/').ToLowerInvariant()
    }

    $hash = [System.Numerics.BigInteger]::Parse('14695981039346656037')
    $prime = [System.Numerics.BigInteger]::Parse('1099511628211')
    $modulus = [System.Numerics.BigInteger]::Pow([System.Numerics.BigInteger]2, 64)
    foreach ($byte in [System.Text.Encoding]::UTF8.GetBytes($normalized)) {
        $hash = [System.Numerics.BigInteger]::Remainder(($hash -bxor [System.Numerics.BigInteger]$byte) * $prime, $modulus)
    }
    return ('socket-{0:x16}' -f [uint64]$hash)
}

function Get-OrchestraAttachSessionNamespace {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_BRIDGE_SOCKET_S)) {
        return Get-OrchestraAttachSocketNamespaceBase -SocketSelector $env:WINSMUX_BRIDGE_SOCKET_S -ProjectDir $ProjectDir
    }
    if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_BRIDGE_NAMESPACE_L)) {
        return $env:WINSMUX_BRIDGE_NAMESPACE_L.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_BRIDGE_SESSION_NAMESPACE)) {
        return $env:WINSMUX_BRIDGE_SESSION_NAMESPACE.Trim()
    }
    return ''
}

function Get-OrchestraRenderSessionIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    $namespace = Get-OrchestraAttachSessionNamespace -ProjectDir $ProjectDir
    if ([string]::IsNullOrWhiteSpace($namespace)) {
        return $SessionName
    }
    return ('{0}__{1}' -f $namespace, $SessionName)
}

function Get-OrchestraProcessStartedAtUnixMs {
    param([AllowNull()]$ProcessId)

    $resolvedProcessId = ConvertTo-OrchestraAttachProcessId -Value $ProcessId
    if ($resolvedProcessId -le 0) {
        return 0L
    }

    try {
        $process = Get-Process -Id $resolvedProcessId -ErrorAction Stop
        return ([DateTimeOffset]$process.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds()
    } catch {
        return 0L
    }
}

function Get-OrchestraLivePaneSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$WinsmuxBin,
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    if ([string]::IsNullOrWhiteSpace($WinsmuxBin)) {
        return [PSCustomObject][ordered]@{ Ok = $false; Count = 0; Error = 'winsmux executable could not be resolved.'; PaneIds = @() }
    }

    try {
        $paneLines = Invoke-WinsmuxBridgeCommand -WinsmuxBin $WinsmuxBin -Arguments @('list-panes', '-t', $SessionName, '-F', '#{pane_id}') 2>&1
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject][ordered]@{ Ok = $false; Count = 0; Error = ($paneLines | Out-String).Trim(); PaneIds = @() }
        }

        $rawPaneIds = @(
            $paneLines |
                ForEach-Object { ([string]$_).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $paneIds = @($rawPaneIds | Where-Object { $_ -match '^%[0-9]+$' } | Sort-Object -Unique)
        if ($rawPaneIds.Count -ne $paneIds.Count) {
            return [PSCustomObject][ordered]@{ Ok = $false; Count = 0; Error = 'list-panes returned malformed or duplicate pane IDs.'; PaneIds = @() }
        }
        return [PSCustomObject][ordered]@{ Ok = ($paneIds.Count -gt 0); Count = $paneIds.Count; Error = if ($paneIds.Count -gt 0) { '' } else { 'No live pane IDs were returned.' }; PaneIds = @($paneIds) }
    } catch {
        return [PSCustomObject][ordered]@{ Ok = $false; Count = 0; Error = $_.Exception.Message; PaneIds = @() }
    }
}

function Test-OrchestraRenderReceipt {
    param(
        [AllowNull()]$Receipt,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [AllowEmptyCollection()][string[]]$LivePaneIds = @(),
        [long]$RequestedAtUnixMs = 0,
        [long]$MaxAgeMilliseconds = 5000
    )

    $result = [ordered]@{
        Confirmed = $false
        Reason = 'render_receipt_missing'
        RendererProcessId = 0
        RendererProcessStartedAtUnixMs = 0
        RenderedPaneIds = @()
        RenderedAtUnixMs = 0
    }
    if ($null -eq $Receipt) {
        return [PSCustomObject]$result
    }

    foreach ($requiredProperty in @('version', 'request_id', 'session_name', 'renderer_process_id', 'renderer_process_started_at_unix_ms', 'rendered_at_unix_ms', 'pane_ids')) {
        if ($null -eq $Receipt.PSObject.Properties[$requiredProperty]) {
            $result.Reason = 'render_receipt_malformed'
            return [PSCustomObject]$result
        }
    }
    $receiptVersion = 0
    if (-not [int]::TryParse(([string]$Receipt.version), [ref]$receiptVersion) -or $receiptVersion -ne 1) {
        $result.Reason = 'render_receipt_version_unsupported'
        return [PSCustomObject]$result
    }
    if ([string]$Receipt.request_id -ne $RequestId) {
        $result.Reason = 'render_receipt_request_mismatch'
        return [PSCustomObject]$result
    }
    if ([string]$Receipt.session_name -ne $SessionName) {
        $result.Reason = 'render_receipt_session_mismatch'
        return [PSCustomObject]$result
    }

    $rendererProcessId = ConvertTo-OrchestraAttachProcessId -Value $Receipt.renderer_process_id
    if (-not (Test-OrchestraProcessAlive -ProcessId $rendererProcessId)) {
        $result.Reason = 'render_receipt_renderer_not_live'
        return [PSCustomObject]$result
    }

    $rendererProcessStartedAtUnixMs = 0L
    if (-not [long]::TryParse(([string]$Receipt.renderer_process_started_at_unix_ms), [ref]$rendererProcessStartedAtUnixMs) -or $rendererProcessStartedAtUnixMs -le 0) {
        $result.Reason = 'render_receipt_malformed'
        return [PSCustomObject]$result
    }
    $liveProcessStartedAtUnixMs = Get-OrchestraProcessStartedAtUnixMs -ProcessId $rendererProcessId
    if ($liveProcessStartedAtUnixMs -le 0 -or $liveProcessStartedAtUnixMs -ne $rendererProcessStartedAtUnixMs) {
        $result.Reason = 'render_receipt_renderer_instance_mismatch'
        return [PSCustomObject]$result
    }

    $renderedAtUnixMs = 0L
    if (-not [long]::TryParse(([string]$Receipt.rendered_at_unix_ms), [ref]$renderedAtUnixMs) -or $renderedAtUnixMs -le 0 -or ($RequestedAtUnixMs -gt 0 -and $renderedAtUnixMs -lt $RequestedAtUnixMs)) {
        $result.Reason = 'render_receipt_not_fresh'
        return [PSCustomObject]$result
    }
    $nowUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($MaxAgeMilliseconds -le 0 -or $renderedAtUnixMs -gt ($nowUnixMs + $MaxAgeMilliseconds)) {
        $result.Reason = 'render_receipt_not_fresh'
        return [PSCustomObject]$result
    }
    if (($nowUnixMs - $renderedAtUnixMs) -gt $MaxAgeMilliseconds) {
        $result.Reason = 'render_receipt_expired'
        return [PSCustomObject]$result
    }

    $rawRenderedPaneIds = @($Receipt.pane_ids | ForEach-Object { ([string]$_).Trim() })
    $renderedPaneIds = @($rawRenderedPaneIds | Where-Object { $_ -match '^%[0-9]+$' } | Sort-Object -Unique)
    $rawLivePaneIds = @($LivePaneIds | ForEach-Object { ([string]$_).Trim() })
    $livePaneIds = @($rawLivePaneIds | Where-Object { $_ -match '^%[0-9]+$' } | Sort-Object -Unique)
    if ($rawRenderedPaneIds.Count -eq 0 -or $rawRenderedPaneIds.Count -ne $renderedPaneIds.Count -or $rawLivePaneIds.Count -ne $livePaneIds.Count -or $livePaneIds.Count -eq 0 -or (($renderedPaneIds -join "`n") -ne ($livePaneIds -join "`n"))) {
        $result.Reason = 'render_receipt_pane_set_mismatch'
        return [PSCustomObject]$result
    }

    $result.Confirmed = $true
    $result.Reason = 'render_receipt_confirmed'
    $result.RendererProcessId = $rendererProcessId
    $result.RendererProcessStartedAtUnixMs = $rendererProcessStartedAtUnixMs
    $result.RenderedPaneIds = @($renderedPaneIds)
    $result.RenderedAtUnixMs = $renderedAtUnixMs
    return [PSCustomObject]$result
}

function Test-OrchestraLiveVisibleAttachState {
    param(
        [AllowNull()]$State,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [AllowEmptyString()][string]$WinsmuxBin = ''
    )

    if ($null -eq $State -or [string]::IsNullOrWhiteSpace($WinsmuxBin)) {
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

    $requestId = Get-OrchestraAttachRequestId -State $State
    $receiptPath = Get-OrchestraAttachStateString -State $State -Name 'render_receipt_path'
    if ([string]::IsNullOrWhiteSpace($requestId) -or [string]::IsNullOrWhiteSpace($receiptPath)) {
        return $false
    }

    $projectDir = Get-OrchestraAttachStateString -State $State -Name 'project_dir'
    if ([string]::IsNullOrWhiteSpace($projectDir)) {
        $projectDir = (Get-Location).Path
    }
    $storedSessionIdentity = Get-OrchestraAttachStateString -State $State -Name 'render_session_identity'
    $currentSessionIdentity = Get-OrchestraRenderSessionIdentity -SessionName $SessionName -ProjectDir $projectDir
    if ([string]::IsNullOrWhiteSpace($storedSessionIdentity) -or $storedSessionIdentity -ne $currentSessionIdentity) {
        return $false
    }

    $requestedAtUnixMs = 0L
    $requestedAt = Get-OrchestraAttachStateString -State $State -Name 'requested_at'
    $parsedRequestedAt = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($requestedAt, [ref]$parsedRequestedAt)) {
        $requestedAtUnixMs = $parsedRequestedAt.ToUnixTimeMilliseconds()
    }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $livePanes = Get-OrchestraLivePaneSnapshot -WinsmuxBin $WinsmuxBin -SessionName $SessionName
        if (-not [bool]$livePanes.Ok) {
            return $false
        }
        $receipt = Read-OrchestraRenderReceipt -Path $receiptPath
        $validation = Test-OrchestraRenderReceipt -Receipt $receipt -SessionName $currentSessionIdentity -RequestId $requestId -LivePaneIds @($livePanes.PaneIds) -RequestedAtUnixMs $requestedAtUnixMs
        if ([bool]$validation.Confirmed) {
            return $true
        }
        if ([string]$validation.Reason -notin @('render_receipt_pane_set_mismatch', 'render_receipt_expired')) {
            return $false
        }
        if ($attempt -lt 2) {
            Start-Sleep -Milliseconds 50
        }
    }
    return $false
}

function Write-OrchestraAttachState {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][hashtable]$Properties,
        [string]$ProjectDir = (Get-Location).Path,
        [AllowEmptyString()][string]$ExpectedRequestId = ''
    )

    $existing = Read-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRequestId)) {
        $currentRequestId = Get-OrchestraAttachRequestId -State $existing
        if ($currentRequestId -ne $ExpectedRequestId) {
            return $existing
        }
    }
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

    $statePath = Get-OrchestraAttachStatePath -SessionName $SessionName -ProjectDir $ProjectDir
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

function Test-OrchestraTruthyEnvValue {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return ($Value.Trim().ToLowerInvariant() -in @('1', 'true', 'yes', 'on'))
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
                    $jsonEntry = $rawText | ConvertFrom-WinsmuxJson -Depth 8
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
        [Parameter(Mandatory = $true)][hashtable]$Entry,
        [string]$ProjectDir = (Get-Location).Path
    )

    $state = Read-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir
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
    $updatedState = Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -Properties @{
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
    if (Test-OrchestraTruthyEnvValue -Value $env:WINSMUX_ORCHESTRA_DISABLE_WINDOWS_TERMINAL_ATTACH) {
        $windowsTerminalAvailable = $false
        $windowsTerminalReason = 'windows_terminal_attach_disabled'
    }
    if ([string]$terminalInfo.PathSource -eq 'appx') {
        $windowsTerminalAvailable = $false
        $windowsTerminalReason = 'wt_appx_direct_launch_unsupported'
    }

    $powerShellPath = ''
    $powerShellReason = 'ready'
    $powerShellAvailable = $true
    if (Test-OrchestraTruthyEnvValue -Value $env:WINSMUX_ORCHESTRA_DISABLE_POWERSHELL_ATTACH) {
        $powerShellAvailable = $false
        $powerShellReason = 'powershell_attach_disabled'
    }
    try {
        if ($powerShellAvailable) {
            $powerShellPath = Get-OrchestraPowerShellPath
        }
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
        [string]$ProjectDir = (Get-Location).Path,
        [int]$TimeoutMilliseconds = 2500,
        [int]$PollMilliseconds = 250
    )

    $deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds)
    do {
        $state = Read-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir
        if ($null -ne $state) {
            $status = [string]$state.attach_status
            if ($status -in @('attach_entry_started', 'attach_confirming', 'attach_confirmed')) {
                return [PSCustomObject][ordered]@{
                    Observed = $true
                    Reason   = "Attach state advanced to '$status'."
                }
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

function New-OrchestraAttachSupersededResult {
    param(
        [AllowNull()]$State,
        [Parameter(Mandatory = $true)][string]$ExpectedRequestId,
        [Parameter(Mandatory = $true)][int]$AttachedClientCount
    )

    $currentRequestId = Get-OrchestraAttachRequestId -State $State
    return [PSCustomObject][ordered]@{
        Confirmed           = $false
        Source              = 'none'
        Status              = 'attach_superseded'
        Reason              = "Attach request '$ExpectedRequestId' was superseded by '$currentRequestId'."
        AttachedClientCount = $AttachedClientCount
        State               = $State
    }
}

function Wait-OrchestraAttachHandshake {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$WinsmuxBin,
        [Parameter(Mandatory = $true)][int]$BaselineClientCount,
        [AllowEmptyCollection()][string[]]$BaselineClients = @(),
        [string]$ProjectDir = (Get-Location).Path,
        [AllowEmptyString()][string]$ExpectedRequestId = '',
        [int]$TimeoutMilliseconds = 12000,
        [int]$PollMilliseconds = 250
    )

    $deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds)
    $lastError = 'render_receipt_missing'

    do {
        $state = Read-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir
        if (-not [string]::IsNullOrWhiteSpace($ExpectedRequestId) -and (Get-OrchestraAttachRequestId -State $state) -ne $ExpectedRequestId) {
            return New-OrchestraAttachSupersededResult -State $state -ExpectedRequestId $ExpectedRequestId -AttachedClientCount $BaselineClientCount
        }
        if ($null -ne $state) {
            $status = [string]$state.attach_status
            if ($status -eq 'attach_failed') {
                $lastError = [string]$state.error
            }
        }

        $snapshot = Get-OrchestraAttachedClientSnapshot -WinsmuxBin $WinsmuxBin -SessionName $SessionName
        $requestId = Get-OrchestraAttachRequestId -State $state
        $receiptPath = Get-OrchestraAttachStateString -State $state -Name 'render_receipt_path'
        $livePanes = Get-OrchestraLivePaneSnapshot -WinsmuxBin $WinsmuxBin -SessionName $SessionName
        if (-not [string]::IsNullOrWhiteSpace($requestId) -and -not [string]::IsNullOrWhiteSpace($receiptPath) -and [bool]$livePanes.Ok) {
            $requestedAtUnixMs = 0L
            $requestedAt = Get-OrchestraAttachStateString -State $state -Name 'requested_at'
            $parsedRequestedAt = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($requestedAt, [ref]$parsedRequestedAt)) {
                $requestedAtUnixMs = $parsedRequestedAt.ToUnixTimeMilliseconds()
            }
            $receipt = Read-OrchestraRenderReceipt -Path $receiptPath
            $storedSessionIdentity = Get-OrchestraAttachStateString -State $state -Name 'render_session_identity'
            $currentSessionIdentity = Get-OrchestraRenderSessionIdentity -SessionName $SessionName -ProjectDir $ProjectDir
            if ([string]::IsNullOrWhiteSpace($storedSessionIdentity) -or $storedSessionIdentity -ne $currentSessionIdentity) {
                $receiptValidation = [PSCustomObject]@{ Confirmed = $false; Reason = 'render_receipt_session_mismatch' }
            } else {
                $receiptValidation = Test-OrchestraRenderReceipt -Receipt $receipt -SessionName $currentSessionIdentity -RequestId $requestId -LivePaneIds @($livePanes.PaneIds) -RequestedAtUnixMs $requestedAtUnixMs
            }
            $lastError = [string]$receiptValidation.Reason
        } else {
            $receiptValidation = [PSCustomObject]@{ Confirmed = $false; Reason = if (-not [bool]$livePanes.Ok) { 'render_receipt_live_panes_unavailable' } else { 'render_receipt_missing' } }
            $lastError = [string]$receiptValidation.Reason
        }

        if ([bool]$receiptValidation.Confirmed) {
            $confirmedAt = (Get-Date).ToString('o')
            $updatedState = Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -ExpectedRequestId $ExpectedRequestId -Properties @{
                attach_status             = 'attach_confirmed'
                attach_confirmed_at       = $confirmedAt
                client_count_seen         = if ([bool]$snapshot.Ok) { [int]$snapshot.Count } else { 0 }
                attached_client_count     = if ([bool]$snapshot.Ok) { [int]$snapshot.Count } else { 0 }
                attached_client_snapshot = @($snapshot.Clients)
                renderer_process_id       = [int]$receiptValidation.RendererProcessId
                renderer_process_started_at_unix_ms = [long]$receiptValidation.RendererProcessStartedAtUnixMs
                rendered_pane_ids         = @($receiptValidation.RenderedPaneIds)
                rendered_at_unix_ms       = [long]$receiptValidation.RenderedAtUnixMs
                ui_attach_source          = 'render-receipt'
                error                     = "Visible attach confirmed for session '$SessionName' by a post-draw render receipt."
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedRequestId) -and (Get-OrchestraAttachRequestId -State $updatedState) -ne $ExpectedRequestId) {
                return New-OrchestraAttachSupersededResult -State $updatedState -ExpectedRequestId $ExpectedRequestId -AttachedClientCount $BaselineClientCount
            }

            return [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'render-receipt'
                Status              = 'attach_confirmed'
                Reason              = [string]$updatedState.error
                AttachedClientCount = if ([bool]$snapshot.Ok) { [int]$snapshot.Count } else { 0 }
                State               = $updatedState
            }
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    } while ((Get-Date) -lt $deadline)

    $failedState = Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -ExpectedRequestId $ExpectedRequestId -Properties @{
        attach_status     = 'attach_failed'
        ui_attach_source  = 'none'
        client_count_seen = $BaselineClientCount
        error             = "Attach confirmation timed out: $lastError."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRequestId) -and (Get-OrchestraAttachRequestId -State $failedState) -ne $ExpectedRequestId) {
        return New-OrchestraAttachSupersededResult -State $failedState -ExpectedRequestId $ExpectedRequestId -AttachedClientCount $BaselineClientCount
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
    if ([string]::Equals([string]$env:WINSMUX_ORCHESTRA_ATTACH_MODE, 'desktop-app', [System.StringComparison]::OrdinalIgnoreCase)) {
        $desktopPid = 0
        [void][int]::TryParse(([string]$env:WINSMUX_DESKTOP_APP_PID), [ref]$desktopPid)
        $desktopAlive = $desktopPid -gt 0 -and (Test-OrchestraProcessAlive -ProcessId $desktopPid)
        $reason = if ($desktopAlive) { 'Desktop app is live, but it did not provide a nonce-bound post-draw render receipt.' } else { 'WINSMUX_ORCHESTRA_ATTACH_MODE=desktop-app requires a live WINSMUX_DESKTOP_APP_PID.' }
        $stateProperties = @{
            session_name        = $SessionName
            winsmux_path        = [string]$WinsmuxPathForAttach
            project_dir         = $ProjectDir
            requested_at        = (Get-Date).ToString('o')
            attach_request_id   = [guid]::NewGuid().ToString('N')
            attach_process_id   = $desktopPid
            attach_status       = 'attach_failed'
            attach_confirmed_at = ''
            client_count_seen   = 0
            attached_client_count = 0
            attached_client_snapshot = @()
            ui_attach_source    = 'desktop-app'
            ui_host_kind        = 'desktop-app'
            error               = $reason
            attach_adapter_trace = @()
        }
        $state = Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -Properties $stateProperties

        return [PSCustomObject][ordered]@{
            Attempted                = $true
            Launched                 = $false
            Attached                 = $false
            AttachedClientCount      = 0
            Status                   = 'attach_failed'
            Reason                   = $reason
            Path                     = ''
            Source                   = 'desktop-app'
            attach_request_id        = (Get-OrchestraAttachRequestId -State $state)
            attached_client_snapshot = @()
            ui_host_kind             = 'desktop-app'
            attach_adapter_trace     = @()
        }
    }

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
    $existingAttachState = Read-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir
    $hasLiveVisibleAttach = (Test-OrchestraLiveVisibleAttachState -State $existingAttachState -SessionName $SessionName -WinsmuxBin $resolvedWinsmuxPath)
    if ($hasLiveVisibleAttach) {
        $existingAttachState = Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -Properties @{
            session_name        = $SessionName
            winsmux_path        = $resolvedWinsmuxPath
            attach_status       = 'attach_confirmed'
            attach_confirmed_at = (Get-Date).ToString('o')
            client_count_seen   = $baselineClientCount
            ui_attach_source    = 'render-receipt'
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
            Source                   = 'render-receipt'
            attach_request_id        = (Get-OrchestraAttachRequestId -State $existingAttachState)
            attached_client_snapshot = @(Get-OrchestraAttachStateStringArray -State $existingAttachState -Name 'attached_client_snapshot')
            ui_host_kind             = (Get-OrchestraAttachStateString -State $existingAttachState -Name 'ui_host_kind')
            attach_adapter_trace     = @(Get-OrchestraAttachTraceEntries -State $existingAttachState)
        }
    }

    $attachRequestId = [guid]::NewGuid().ToString('N')
    $renderReceiptPath = Get-OrchestraRenderReceiptPath -SessionName $SessionName -RequestId $attachRequestId
    $bridgeNamespaceL = [string]$env:WINSMUX_BRIDGE_NAMESPACE_L
    $bridgeSocketS = [string]$env:WINSMUX_BRIDGE_SOCKET_S
    $bridgeSessionNamespace = Get-OrchestraAttachSessionNamespace -ProjectDir $ProjectDir
    $renderSessionIdentity = Get-OrchestraRenderSessionIdentity -SessionName $SessionName -ProjectDir $ProjectDir
    $state = Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -Properties @{
        session_name          = $SessionName
        render_session_identity = $renderSessionIdentity
        bridge_namespace_l    = $bridgeNamespaceL
        bridge_socket_s       = $bridgeSocketS
        bridge_session_namespace = $bridgeSessionNamespace
        winsmux_path          = $resolvedWinsmuxPath
        project_dir           = $ProjectDir
        requested_at          = (Get-Date).ToString('o')
        attach_request_id     = $attachRequestId
        baseline_client_count = $baselineClientCount
        baseline_clients      = @($baselineClients)
        client_count_seen     = $baselineClientCount
        attach_process_id     = 0
        renderer_process_id   = 0
        renderer_process_started_at_unix_ms = 0
        render_receipt_path   = $renderReceiptPath
        rendered_pane_ids     = @()
        rendered_at_unix_ms   = 0
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
            $traceUpdate = Add-OrchestraAttachTraceEntry -SessionName $SessionName -ProjectDir $ProjectDir -Entry @{
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

        $attachRequestId = [guid]::NewGuid().ToString('N')
        $renderReceiptPath = Get-OrchestraRenderReceiptPath -SessionName $SessionName -RequestId $attachRequestId
        $state = Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -Properties @{
            requested_at          = (Get-Date).ToString('o')
            attach_request_id     = $attachRequestId
            attach_process_id     = 0
            renderer_process_id   = 0
            renderer_process_started_at_unix_ms = 0
            render_receipt_path   = $renderReceiptPath
            rendered_pane_ids     = @()
            rendered_at_unix_ms   = 0
            attach_status         = 'attach_requested'
            attach_confirmed_at   = ''
            ui_attach_source      = 'none'
            error                 = ''
        }

        try {
            $previousLaunchRequestId = $env:WINSMUX_ATTACH_REQUEST_ID
            $previousLaunchProjectDir = $env:WINSMUX_ATTACH_PROJECT_DIR
            try {
                $env:WINSMUX_ATTACH_REQUEST_ID = $attachRequestId
                $env:WINSMUX_ATTACH_PROJECT_DIR = $ProjectDir
                $attachLaunch = Start-OrchestraVisibleAttachHostCandidate -Candidate $candidate
            } finally {
                if ($null -eq $previousLaunchRequestId) { Remove-Item Env:WINSMUX_ATTACH_REQUEST_ID -ErrorAction SilentlyContinue } else { $env:WINSMUX_ATTACH_REQUEST_ID = $previousLaunchRequestId }
                if ($null -eq $previousLaunchProjectDir) { Remove-Item Env:WINSMUX_ATTACH_PROJECT_DIR -ErrorAction SilentlyContinue } else { $env:WINSMUX_ATTACH_PROJECT_DIR = $previousLaunchProjectDir }
            }
            $lastLaunchPath = [string]$attachLaunch.Path
            $launched = $true
            if ($null -ne $attachLaunch.Process -and $null -ne $attachLaunch.Process.PSObject -and ($attachLaunch.Process.PSObject.Properties.Name -contains 'Id')) {
                $state = Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -Properties @{
                    attach_process_id = $attachLaunch.Process.Id
                    started_at        = (Get-Date).ToString('o')
                    ui_host_kind      = [string]$attachLaunch.HostKind
                }
            }
        } catch {
            $lastFailureReason = $_.Exception.Message
            $traceUpdate = Add-OrchestraAttachTraceEntry -SessionName $SessionName -ProjectDir $ProjectDir -Entry @{
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
            $launchObserved = Wait-OrchestraAttachLaunchObservation -SessionName $SessionName -WinsmuxBin $resolvedWinsmuxPath -BaselineClientCount $baselineClientCount -BaselineClients $baselineClients -ProjectDir $ProjectDir
            if (-not [bool]$launchObserved.Observed) {
                $lastFailureReason = [string]$launchObserved.Reason
                $traceUpdate = Add-OrchestraAttachTraceEntry -SessionName $SessionName -ProjectDir $ProjectDir -Entry @{
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

        $confirmed = Wait-OrchestraAttachHandshake -SessionName $SessionName -WinsmuxBin $resolvedWinsmuxPath -BaselineClientCount $baselineClientCount -BaselineClients $baselineClients -ProjectDir $ProjectDir -ExpectedRequestId $attachRequestId
        $confirmedState = if ($null -ne $confirmed.State) { $confirmed.State } else { $state }
        $traceUpdate = Add-OrchestraAttachTraceEntry -SessionName $SessionName -ProjectDir $ProjectDir -Entry @{
            host_kind           = [string]$candidate.HostKind
            path                = [string]$attachLaunch.Path
            available           = $true
            availability_reason = [string]$candidate.Reason
            launch_result       = if ([bool]$confirmed.Confirmed) { 'attach_confirmed' } else { 'attach_failed' }
            fallback_reason     = if ([bool]$confirmed.Confirmed) { '' } else { [string]$confirmed.Reason }
        }
        $traceState = $traceUpdate.State
        if ($null -ne $confirmedState) {
            $confirmedState = Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -Properties @{
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
    $failedState = Write-OrchestraAttachState -SessionName $SessionName -ProjectDir $ProjectDir -Properties @{
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
