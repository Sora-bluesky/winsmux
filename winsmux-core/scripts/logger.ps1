[CmdletBinding()]
param(
    [ValidateSet('init', 'write', 'read', 'path')]
    [string]$Command = 'write',
    [string]$ProjectDir = (Get-Location).Path,
    [string]$SessionName = 'winsmux-orchestra',
    [string]$Event,
    [ValidateSet('debug', 'info', 'warn', 'error')]
    [string]$Level = 'info',
    [string]$Message,
    [string]$Role,
    [string]$PaneId,
    [string]$Target,
    [string]$DataJson,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:OrchestraLogDirName = '.winsmux\logs'
$script:OrchestraLogExtension = '.jsonl'
$script:WinsmuxLogProjectDir = (Get-Location).Path
$script:WinsmuxLogSessionName = 'winsmux-orchestra'

function Get-OrchestraLogDir {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path $ProjectDir $script:OrchestraLogDirName
}

function Get-OrchestraLogPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [string]$SessionName = 'winsmux-orchestra'
    )

    $safeSessionName = if ([string]::IsNullOrWhiteSpace($SessionName)) {
        'winsmux-orchestra'
    } else {
        ($SessionName -replace '[^A-Za-z0-9._-]', '_')
    }

    return Join-Path (Get-OrchestraLogDir -ProjectDir $ProjectDir) ($safeSessionName + $script:OrchestraLogExtension)
}

function Initialize-OrchestraLogger {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [string]$SessionName = 'winsmux-orchestra'
    )

    $logDir = Get-OrchestraLogDir -ProjectDir $ProjectDir
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $logPath = Get-OrchestraLogPath -ProjectDir $ProjectDir -SessionName $SessionName
    if (-not (Test-Path $logPath)) {
        Set-Content -Path $logPath -Value '' -Encoding UTF8 -NoNewline
    }

    return $logPath
}

function Initialize-WinsmuxLog {
    param(
        [string]$ProjectDir = (Get-Location).Path,
        [string]$SessionName = 'winsmux-orchestra'
    )

    $script:WinsmuxLogProjectDir = $ProjectDir
    $script:WinsmuxLogSessionName = $SessionName

    return Initialize-OrchestraLogger -ProjectDir $ProjectDir -SessionName $SessionName
}

function ConvertTo-OrchestraLogData {
    param([AllowNull()]$Data)

    if ($null -eq $Data) {
        return [ordered]@{}
    }

    if ($Data -is [System.Collections.IDictionary]) {
        $clone = [ordered]@{}
        foreach ($entry in $Data.GetEnumerator()) {
            $clone[[string]$entry.Key] = $entry.Value
        }
        return $clone
    }

    if ($null -ne $Data.PSObject) {
        $clone = [ordered]@{}
        foreach ($property in $Data.PSObject.Properties) {
            $clone[$property.Name] = $property.Value
        }
        return $clone
    }

    return [ordered]@{ value = $Data }
}

function New-OrchestraLogRecord {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$Event,
        [ValidateSet('debug', 'info', 'warn', 'error')]
        [string]$Level = 'info',
        [string]$Message,
        [string]$Role,
        [string]$PaneId,
        [string]$Target,
        [AllowNull()]$Data
    )

    if ([string]::IsNullOrWhiteSpace($Event)) {
        throw 'Event is required.'
    }

    return [ordered]@{
        timestamp = [System.DateTimeOffset]::Now.ToString('o')
        session   = $SessionName
        event     = $Event
        level     = $Level
        message   = if ($null -eq $Message) { '' } else { $Message }
        role      = if ($null -eq $Role) { '' } else { $Role }
        pane_id   = if ($null -eq $PaneId) { '' } else { $PaneId }
        target    = if ($null -eq $Target) { '' } else { $Target }
        data      = ConvertTo-OrchestraLogData -Data $Data
    }
}

function Write-OrchestraLog {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [string]$SessionName = 'winsmux-orchestra',
        [Parameter(Mandatory = $true)][string]$Event,
        [ValidateSet('debug', 'info', 'warn', 'error')]
        [string]$Level = 'info',
        [string]$Message,
        [string]$Role,
        [string]$PaneId,
        [string]$Target,
        [AllowNull()]$Data
    )

    $logPath = Initialize-OrchestraLogger -ProjectDir $ProjectDir -SessionName $SessionName
    $record = New-OrchestraLogRecord -SessionName $SessionName -Event $Event -Level $Level -Message $Message -Role $Role -PaneId $PaneId -Target $Target -Data $Data
    $line = ($record | ConvertTo-Json -Compress -Depth 10)
    Add-Content -Path $logPath -Value $line -Encoding UTF8
    return [PSCustomObject]$record
}

function Write-WinsmuxLog {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$Message,
        [string]$Role,
        [string]$PaneId,
        [string]$Target,
        [AllowNull()]$Data,
        [string]$ProjectDir,
        [string]$SessionName
    )

    $resolvedProjectDir = if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
        $script:WinsmuxLogProjectDir
    } else {
        $ProjectDir
    }

    $resolvedSessionName = if ([string]::IsNullOrWhiteSpace($SessionName)) {
        $script:WinsmuxLogSessionName
    } else {
        $SessionName
    }

    $normalizedLevel = switch ($Level.Trim().ToLowerInvariant()) {
        'debug' { 'debug' }
        'info' { 'info' }
        'warn' { 'warn' }
        'warning' { 'warn' }
        'error' { 'error' }
        default { throw "Unsupported log level: $Level" }
    }

    return Write-OrchestraLog -ProjectDir $resolvedProjectDir -SessionName $resolvedSessionName -Event $Event -Level $normalizedLevel -Message $Message -Role $Role -PaneId $PaneId -Target $Target -Data $Data
}

function Read-OrchestraLog {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [string]$SessionName = 'winsmux-orchestra'
    )

    $logPath = Get-OrchestraLogPath -ProjectDir $ProjectDir -SessionName $SessionName
    if (-not (Test-Path $logPath -PathType Leaf)) {
        return @()
    }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($line in (Get-Content -Path $logPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $records.Add(($line | ConvertFrom-Json -ErrorAction Stop)) | Out-Null
    }

    return @($records)
}

function ConvertFrom-OrchestraLogDataJson {
    param([string]$DataJson)

    if ([string]::IsNullOrWhiteSpace($DataJson)) {
        return [ordered]@{}
    }

    $parsed = $DataJson | ConvertFrom-Json -ErrorAction Stop
    return ConvertTo-OrchestraLogData -Data $parsed
}

if ($MyInvocation.InvocationName -ne '.') {
    switch ($Command) {
        'path' {
            Get-OrchestraLogPath -ProjectDir $ProjectDir -SessionName $SessionName
        }
        'init' {
            Initialize-OrchestraLogger -ProjectDir $ProjectDir -SessionName $SessionName
        }
        'read' {
            $records = Read-OrchestraLog -ProjectDir $ProjectDir -SessionName $SessionName
            if ($AsJson) {
                $records | ConvertTo-Json -Depth 10
            } else {
                $records
            }
        }
        'write' {
            $data = ConvertFrom-OrchestraLogDataJson -DataJson $DataJson
            $record = Write-OrchestraLog -ProjectDir $ProjectDir -SessionName $SessionName -Event $Event -Level $Level -Message $Message -Role $Role -PaneId $PaneId -Target $Target -Data $data
            if ($AsJson) {
                $record | ConvertTo-Json -Depth 10
            } else {
                $record
            }
        }
    }
}
