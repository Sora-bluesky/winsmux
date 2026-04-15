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
        if ([bool]$snapshot.Ok -and [int]$snapshot.Count -ge $targetClientCount) {
            $confirmedAt = (Get-Date).ToString('o')
            $updatedState = Write-OrchestraAttachState -SessionName $SessionName -Properties @{
                attach_status       = 'attach_confirmed'
                attach_confirmed_at = $confirmedAt
                client_count_seen   = [int]$snapshot.Count
                ui_attach_source    = 'client-probe'
                error               = "Visible attach confirmed for session '$SessionName' with $($snapshot.Count) attached client(s)."
            }

            return [PSCustomObject][ordered]@{
                Confirmed           = $true
                Source              = 'client-probe'
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
