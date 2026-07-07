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
    [long]$MaxBytes = 0,
    [int]$RetentionCount = -1,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. "$PSScriptRoot/clm-safe-io.ps1"

$script:OrchestraLogDirName = '.winsmux\logs'
$script:OrchestraLogExtension = '.jsonl'
$script:OrchestraLogDefaultMaxBytes = 10MB
$script:OrchestraLogDefaultRetentionCount = 5
$script:WinsmuxLogProjectDir = (Get-Location).Path
$script:WinsmuxLogSessionName = 'winsmux-orchestra'

# Consumer contract: writers may rotate the active session log to a per-session
# history directory before an append. Consumers should keep tailing the active
# <session>.jsonl path and use Read-OrchestraLog when retained history is needed.

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

function Get-OrchestraLogMaxBytes {
    param([long]$MaxBytes = 0)

    if ($MaxBytes -gt 0) {
        return $MaxBytes
    }

    $parsed = 0L
    if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_ORCHESTRA_LOG_MAX_BYTES) -and [long]::TryParse($env:WINSMUX_ORCHESTRA_LOG_MAX_BYTES, [ref]$parsed) -and $parsed -gt 0) {
        return $parsed
    }

    return $script:OrchestraLogDefaultMaxBytes
}

function Get-OrchestraLogRetentionCount {
    param([int]$RetentionCount = -1)

    if ($RetentionCount -ge 0) {
        return $RetentionCount
    }

    $parsed = 0
    if (-not [string]::IsNullOrWhiteSpace($env:WINSMUX_ORCHESTRA_LOG_RETENTION_COUNT) -and [int]::TryParse($env:WINSMUX_ORCHESTRA_LOG_RETENTION_COUNT, [ref]$parsed) -and $parsed -ge 0) {
        return $parsed
    }

    return $script:OrchestraLogDefaultRetentionCount
}

function Test-OrchestraLogRotationNeeded {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$MaxBytes = 0,
        [AllowEmptyString()][string]$PendingContent = ''
    )

    $resolvedMaxBytes = Get-OrchestraLogMaxBytes -MaxBytes $MaxBytes
    if ($resolvedMaxBytes -le 0 -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $currentLength = (Get-Item -LiteralPath $Path).Length
    if ($currentLength -le 0) {
        return $false
    }

    $pendingBytes = 0
    if (-not [string]::IsNullOrEmpty($PendingContent)) {
        $pendingBytes = [System.Text.Encoding]::UTF8.GetByteCount($PendingContent) + 2
    }

    return (($currentLength + $pendingBytes) -gt $resolvedMaxBytes)
}

function Get-OrchestraLogRotationDir {
    param([Parameter(Mandatory = $true)][string]$Path)

    $directory = Split-Path -Parent $Path
    $activeFileName = [System.IO.Path]::GetFileName($Path)
    return Join-Path (Join-Path $directory '.rotated') $activeFileName
}

function New-OrchestraLogRotatedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [datetime]$Now = (Get-Date)
    )

    $directory = Get-OrchestraLogRotationDir -Path $Path
    $extension = [System.IO.Path]::GetExtension($Path)
    $stamp = $Now.ToString('yyyyMMddHHmmssfff')

    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    for ($sequence = 0; $sequence -lt 1000000; $sequence++) {
        $candidate = Join-Path $directory ('{0}.{1:D6}{2}' -f $stamp, $sequence, $extension)
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw "Unable to allocate rotated log path for $Path at $stamp."
}

function Get-OrchestraLogRotatedFiles {
    param([Parameter(Mandatory = $true)][string]$Path)

    $directory = Get-OrchestraLogRotationDir -Path $Path
    if ([string]::IsNullOrWhiteSpace($directory) -or -not (Test-Path -LiteralPath $directory -PathType Container)) {
        return @()
    }

    $extension = [regex]::Escape([System.IO.Path]::GetExtension($Path))
    $namePattern = '^\d{17}\.\d{6}' + $extension + '$'

    return @(Get-ChildItem -LiteralPath $directory -File | Where-Object { $_.Name -match $namePattern } | Sort-Object -Property @{ Expression = 'Name'; Descending = $true })
}

function Invoke-OrchestraLogRetentionPrune {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$RetentionCount = -1
    )

    $resolvedRetentionCount = Get-OrchestraLogRetentionCount -RetentionCount $RetentionCount
    $rotatedFiles = @(Get-OrchestraLogRotatedFiles -Path $Path)
    if ($resolvedRetentionCount -lt 0 -or $rotatedFiles.Count -le $resolvedRetentionCount) {
        return
    }

    $rotatedFiles | Select-Object -Skip $resolvedRetentionCount | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
    }
}

function Invoke-OrchestraLogRotationIfNeeded {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$MaxBytes = 0,
        [int]$RetentionCount = -1,
        [AllowEmptyString()][string]$PendingContent = ''
    )

    if (-not (Test-OrchestraLogRotationNeeded -Path $Path -MaxBytes $MaxBytes -PendingContent $PendingContent)) {
        return $null
    }

    $rotatedPath = New-OrchestraLogRotatedPath -Path $Path
    try {
        Move-Item -LiteralPath $Path -Destination $rotatedPath -Force -ErrorAction Stop
    } catch {
        return $null
    }

    return $rotatedPath
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
        $escapedPath = $logPath -replace '"', '""'
        Invoke-WinsmuxWithFileLock -Path $logPath -Action {
            if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
                cmd /d /c ('type nul > "{0}"' -f $escapedPath) | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "cmd.exe failed to initialize active log $logPath"
                }
            }
        }
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
        [AllowNull()]$Data,
        [long]$MaxBytes = 0,
        [int]$RetentionCount = -1
    )

    $logPath = Initialize-OrchestraLogger -ProjectDir $ProjectDir -SessionName $SessionName
    $record = New-OrchestraLogRecord -SessionName $SessionName -Event $Event -Level $Level -Message $Message -Role $Role -PaneId $PaneId -Target $Target -Data $Data
    $line = ($record | ConvertTo-Json -Compress -Depth 10)
    $escapedPath = $logPath -replace '"', '""'
    Invoke-WinsmuxWithFileLock -Path $logPath -Action {
        $rotatedPath = Invoke-OrchestraLogRotationIfNeeded -Path $logPath -MaxBytes $MaxBytes -RetentionCount $RetentionCount -PendingContent $line
        $line | cmd /d /c ('more >> "{0}"' -f $escapedPath) | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "cmd.exe failed to append $logPath"
        }

        if (-not [string]::IsNullOrWhiteSpace($rotatedPath)) {
            try {
                Invoke-OrchestraLogRetentionPrune -Path $logPath -RetentionCount $RetentionCount
            } catch {
                # Retention cleanup must not drop the current log record.
            }
        }
    }

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
        [string]$SessionName,
        [long]$MaxBytes = 0,
        [int]$RetentionCount = -1
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

    return Write-OrchestraLog -ProjectDir $resolvedProjectDir -SessionName $resolvedSessionName -Event $Event -Level $normalizedLevel -Message $Message -Role $Role -PaneId $PaneId -Target $Target -Data $Data -MaxBytes $MaxBytes -RetentionCount $RetentionCount
}

function Read-OrchestraLog {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [string]$SessionName = 'winsmux-orchestra'
    )

    $records = [System.Collections.Generic.List[object]]::new()
    $logPath = Get-OrchestraLogPath -ProjectDir $ProjectDir -SessionName $SessionName
    Invoke-WinsmuxWithFileLock -Path $logPath -Action {
        $readPaths = @(
            Get-OrchestraLogRotatedFiles -Path $logPath |
                Sort-Object -Property @{ Expression = 'Name'; Descending = $false } |
                ForEach-Object { $_.FullName }
        )

        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            $readPaths += $logPath
        }

        foreach ($path in $readPaths) {
            try {
                $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop)
            } catch [System.Management.Automation.ItemNotFoundException] {
                continue
            } catch [System.IO.FileNotFoundException] {
                continue
            } catch [System.IO.DirectoryNotFoundException] {
                continue
            }

            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }

                $records.Add(($line | ConvertFrom-Json -ErrorAction Stop)) | Out-Null
            }
        }
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
            $record = Write-OrchestraLog -ProjectDir $ProjectDir -SessionName $SessionName -Event $Event -Level $Level -Message $Message -Role $Role -PaneId $PaneId -Target $Target -Data $data -MaxBytes $MaxBytes -RetentionCount $RetentionCount
            if ($AsJson) {
                $record | ConvertTo-Json -Depth 10
            } else {
                $record
            }
        }
    }
}
