[CmdletBinding()]
param(
    [string]$ProjectDir = '',
    [string]$SessionName = 'winsmux-orchestra',
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($ProjectDir)) {
    $ProjectDir = (Get-Location).Path
}

$ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)
$scriptsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bootstrapScriptPath = Join-Path $scriptsRoot 'orchestra-bootstrap.ps1'

function Get-OrchestraWindowsTerminalInfo {
    $wtExe = Get-Command 'wt.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
    $canonicalWtExe = ''
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
    }
}

function Start-OrchestraAttachProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][object[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$LaunchedStatus,
        [Parameter(Mandatory = $true)][string]$LaunchedReason,
        [Parameter(Mandatory = $true)][string]$FallbackReason
    )

    try {
        $attachProcess = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru
        Start-Sleep -Milliseconds 500
        $attachStillRunning = -not $attachProcess.HasExited

        return [PSCustomObject][ordered]@{
            attempted = $true
            launched  = $true
            attached  = $false
            status    = if ($attachStillRunning) { $LaunchedStatus } else { 'attach_exited_early' }
            reason    = if ($attachStillRunning) { $LaunchedReason } else { $FallbackReason }
            path      = $Path
        }
    } catch {
        return [PSCustomObject][ordered]@{
            attempted = $true
            launched  = $false
            attached  = $false
            status    = 'attach_failed'
            reason    = $_.Exception.Message
            path      = $Path
        }
    }
}

function Get-OrchestraAttachedClientSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$WinsmuxPath,
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    $clients = @()
    $error = ''
    $ok = $false

    try {
        $clientLines = & $WinsmuxPath 'list-clients' '-t' $SessionName 2>&1
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
        Ok     = $ok
        Count  = $clients.Count
        Error  = $error
        Clients = @($clients)
    }
}

$winsmuxPath = Get-Command 'winsmux' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($winsmuxPath)) {
    $result = [ordered]@{
        session_name      = $SessionName
        session_exists    = $false
        requires_startup  = $true
        launched          = $false
        status            = 'winsmux_unresolved'
        reason            = 'winsmux executable could not be resolved.'
    }
} else {
    & $winsmuxPath 'has-session' '-t' $SessionName 1>$null 2>$null
    $sessionExists = ($LASTEXITCODE -eq 0)
    if (-not $sessionExists) {
        $result = [ordered]@{
            session_name      = $SessionName
            session_exists    = $false
            requires_startup  = $true
            launched          = $false
            status            = 'session_missing'
            reason            = "winsmux session '$SessionName' was not found. Run orchestra-start.ps1 first."
        }
    } else {
        $clientSnapshot = Get-OrchestraAttachedClientSnapshot -WinsmuxPath $winsmuxPath -SessionName $SessionName
        if ([bool]$clientSnapshot.Ok -and [int]$clientSnapshot.Count -gt 0) {
            $result = [ordered]@{
                session_name          = $SessionName
                session_exists        = $true
                requires_startup      = $false
                attempted             = $false
                launched              = $false
                attached              = $true
                attached_client_count = [int]$clientSnapshot.Count
                status                = 'attach_already_present'
                reason                = "Detected $($clientSnapshot.Count) attached client(s) for session '$SessionName'; skipped spawning another visible attach window."
                path                  = ''
            }
        } else {
        $pwshPath = Get-Command 'pwsh' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            $pwshPath = 'pwsh'
        }

        $bootstrapArguments = @(
            '-NoProfile', '-NoExit', '-File', $bootstrapScriptPath, '-SessionName', $SessionName, '-WinsmuxPath', $winsmuxPath, '-AttachOnly'
        )

        $result = Start-OrchestraAttachProcess `
            -FilePath $pwshPath `
            -ArgumentList $bootstrapArguments `
            -Path $pwshPath `
            -LaunchedStatus 'attach_launched_pwsh' `
            -LaunchedReason 'Launched orchestra bootstrap in a standalone PowerShell window.' `
            -FallbackReason 'Standalone PowerShell attach exited during the early-failure window.'

        if ($result.status -eq 'attach_exited_early' -or $result.status -eq 'attach_failed') {
            $terminalInfo = Get-OrchestraWindowsTerminalInfo
            if ([bool]$terminalInfo.Available) {
                $wtArguments = @(
                    '--size', '200,70',
                    'new-tab',
                    '--title', $SessionName,
                    '--',
                    $pwshPath
                ) + $bootstrapArguments

                $wtResult = Start-OrchestraAttachProcess `
                    -FilePath ([string]$terminalInfo.Path) `
                    -ArgumentList $wtArguments `
                    -Path ([string]$terminalInfo.Path) `
                    -LaunchedStatus 'attach_launched_wt_fallback' `
                    -LaunchedReason 'Standalone PowerShell attach failed; launched Windows Terminal attach child as a fallback.' `
                    -FallbackReason 'Windows Terminal attach child exited during the early-failure window.'

                if ([bool]$wtResult.launched) {
                    $result = $wtResult
                }
            }
        }

        $result = [ordered]@{
            session_name      = $SessionName
            session_exists    = $true
            requires_startup  = $false
            attempted         = $result.attempted
            launched          = $result.launched
            attached          = $result.attached
            attached_client_count = 0
            status            = $result.status
            reason            = $result.reason
            path              = $result.path
        }
        }
    }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
} else {
    $result.GetEnumerator() | ForEach-Object {
        '{0}: {1}' -f $_.Key, $_.Value
    }
}

if ($result.status -in @('attach_failed', 'attach_exited_early', 'session_missing', 'winsmux_unresolved')) {
    exit 1
}
