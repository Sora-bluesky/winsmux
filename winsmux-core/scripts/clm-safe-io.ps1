$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-WinsmuxFileLockDir {
    param([Parameter(Mandatory = $true)][string]$Path)

    return "$Path.lock"
}

function Get-WinsmuxFileLockMetadataPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return Join-Path (Get-WinsmuxFileLockDir -Path $Path) 'owner.json'
}

function Test-WinsmuxFileLockStale {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$StaleAfterSeconds = 60
    )

    $lockDir = Get-WinsmuxFileLockDir -Path $Path
    if (-not (Test-Path -LiteralPath $lockDir -PathType Container)) {
        return $false
    }

    $metadataPath = Get-WinsmuxFileLockMetadataPath -Path $Path
    $metadata = $null
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            $metadata = $null
        }
    }

    if ($null -ne $metadata) {
        $ownerPid = 0
        if ($metadata.PSObject.Properties.Name -contains 'pid') {
            $ownerPid = [int]$metadata.pid
        }

        if ($ownerPid -gt 0) {
            return ($null -eq (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue))
        }

        if ($metadata.PSObject.Properties.Name -contains 'started_at') {
            try {
                [void][datetime]$metadata.started_at
            } catch {
                return $true
            }
        }

        return $false
    }

    try {
        $lockAge = ((Get-Date) - (Get-Item -LiteralPath $lockDir).LastWriteTime).TotalSeconds
        return ($lockAge -ge $StaleAfterSeconds)
    } catch {
        return $false
    }
}

function Remove-WinsmuxFileLock {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lockDir = Get-WinsmuxFileLockDir -Path $Path
    if (-not (Test-Path -LiteralPath $lockDir -PathType Container)) {
        return
    }

    $escapedLockDir = $lockDir -replace '"', '""'
    cmd /d /c ('rmdir /s /q "{0}"' -f $escapedLockDir) 1>$null 2>$null
}

function Invoke-WinsmuxWithFileLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [int]$TimeoutMilliseconds = 120000,
        [int]$StaleAfterSeconds = 60
    )

    $lockDir = Get-WinsmuxFileLockDir -Path $Path
    $escapedLockDir = $lockDir -replace '"', '""'
    $deadline = (Get-Date).AddMilliseconds($TimeoutMilliseconds)
    $hasLock = $false
    $metadataPath = Get-WinsmuxFileLockMetadataPath -Path $Path
    $escapedMetadataPath = $metadataPath -replace '"', '""'
    try {
        while ((Get-Date) -lt $deadline) {
            cmd /d /c ('mkdir "{0}"' -f $escapedLockDir) 1>$null 2>$null
            if ($LASTEXITCODE -eq 0) {
                $hasLock = $true
                $metadataJson = ([ordered]@{
                        pid        = $PID
                        started_at = (Get-Date).ToString('o')
                        path       = $Path
                    } | ConvertTo-Json)
                $metadataJson | cmd /d /c ('more > "{0}"' -f $escapedMetadataPath) | Out-Null
                break
            }

            if (Test-WinsmuxFileLockStale -Path $Path -StaleAfterSeconds $StaleAfterSeconds) {
                Remove-WinsmuxFileLock -Path $Path
                continue
            }

            Start-Sleep -Milliseconds 100
        }

        if (-not $hasLock) {
            throw "Timed out waiting for file lock for $Path"
        }

        & $Action
    } finally {
        if ($hasLock) {
            Remove-WinsmuxFileLock -Path $Path
        }
    }
}

function Write-WinsmuxTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Content = '',
        [switch]$Append
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $escapedPath = $Path -replace '"', '""'
    Invoke-WinsmuxWithFileLock -Path $Path -Action {
        if ($Append) {
            if ([string]::IsNullOrEmpty($Content)) {
                return
            }

            $Content | cmd /d /c ('more >> "{0}"' -f $escapedPath) | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "cmd.exe failed to append $Path"
            }

            return
        }

        $tempPath = "$Path.tmp-$((New-Guid).Guid)"
        $escapedTempPath = $tempPath -replace '"', '""'
        try {
            if ([string]::IsNullOrEmpty($Content)) {
                cmd /d /c ('type nul > "{0}"' -f $escapedTempPath) | Out-Null
            } else {
                $Content | cmd /d /c ('more > "{0}"' -f $escapedTempPath) | Out-Null
            }

            if ($LASTEXITCODE -ne 0) {
                throw "cmd.exe failed to write temporary file for $Path"
            }

            cmd /d /c ('move /y "{0}" "{1}"' -f $escapedTempPath, $escapedPath) | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "cmd.exe failed to replace $Path"
            }
        } finally {
            if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
                cmd /d /c ('del /f /q "{0}"' -f $escapedTempPath) 1>$null 2>$null
            }
        }
    }
}
