# test-pane-border.ps1
# Verifies pane-border-format with a pane title after the psmux fork is built.
#
# What this script does:
#   1. Starts an isolated psmux session
#   2. Sets pane-border-status to top
#   3. Sets pane-border-format to '#{pane_title}'
#   4. Uses select-pane -T to set a pane title
#   5. Captures diagnostic output and verifies the resolved title
#   6. Cleans up the session
#
# Notes:
# - This script prefers an explicit binary path from $env:PSMUX_EXE.
# - If that is not set, it looks for a built fork in the sibling sora-psmux repo.
# - tmux/psmux capture-pane captures pane content, not the compositor's full screen.
#   For that reason the script verifies the rendered title via format expansion and
#   also saves a small pane capture as diagnostic context.
# - By default the session is always cleaned up. Use -KeepSession only if you want
#   to attach manually after the automated checks.

param(
    [switch]$KeepSession
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$script:SessionName = "test_pane_border_$PID`_$(Get-Random -Maximum 9999)"
$script:ExpectedTitle = 'builder-1'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:DiagnosticsDir = Join-Path $env:TEMP "winsmux-pane-border-$PID"
$script:DiagnosticsFile = Join-Path $script:DiagnosticsDir "pane-border-diagnostics.txt"

function Write-Step {
    param([string]$Message)
    Write-Host "[STEP] $Message" -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Resolve-PsmuxExe {
    $candidatePaths = New-Object System.Collections.Generic.List[string]

    if ($env:PSMUX_EXE) {
        $candidatePaths.Add($env:PSMUX_EXE)
    }

    $siblingForkRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'sora-psmux'
    $candidatePaths.Add((Join-Path $siblingForkRoot 'target\release\psmux.exe'))
    $candidatePaths.Add((Join-Path $siblingForkRoot 'target\debug\psmux.exe'))
    $candidatePaths.Add((Join-Path $script:RepoRoot 'target\release\psmux.exe'))
    $candidatePaths.Add((Join-Path $script:RepoRoot 'target\debug\psmux.exe'))

    try {
        $command = Get-Command psmux -ErrorAction Stop
        if ($command.Source -and $command.Source -match '\.exe$') {
            $candidatePaths.Add($command.Source)
        }
    } catch {
    }

    foreach ($candidate in $candidatePaths | Select-Object -Unique) {
        if ($candidate -and (Test-Path $candidate)) {
            $resolved = (Resolve-Path $candidate).Path
            try {
                $null = & $resolved -V 2>$null
                if ($LASTEXITCODE -eq 0) {
                    return $resolved
                }
            } catch {
            }
        }
    }

    throw @"
psmux.exe was not found.
Set PSMUX_EXE or build the fork first, for example:
  C:\Users\komei\Documents\Projects\apps\sora-psmux\target\release\psmux.exe
"@
}

function Invoke-Psmux {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $lines = & $script:PSMUX @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($lines | Out-String).TrimEnd("`r", "`n")

    if (-not $AllowFailure -and $exitCode -ne 0) {
        $renderedArgs = $Arguments -join ' '
        throw "psmux $renderedArgs failed with exit code $exitCode.`n$text"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Text     = $text
        Lines    = @($lines)
    }
}

function Remove-TestSession {
    Invoke-Psmux -Arguments @('kill-session', '-t', $script:SessionName) -AllowFailure | Out-Null

    $portFile = Join-Path $env:USERPROFILE ".psmux\$($script:SessionName).port"
    $keyFile = Join-Path $env:USERPROFILE ".psmux\$($script:SessionName).key"
    Remove-Item $portFile -Force -ErrorAction SilentlyContinue
    Remove-Item $keyFile -Force -ErrorAction SilentlyContinue
}

function Assert-Equal {
    param(
        [string]$Name,
        [string]$Actual,
        [string]$Expected
    )

    if ($Actual -ne $Expected) {
        throw "$Name mismatch. Expected '$Expected' but got '$Actual'."
    }

    Write-Pass "$Name = $Expected"
}

$script:PSMUX = Resolve-PsmuxExe
New-Item -ItemType Directory -Path $script:DiagnosticsDir -Force | Out-Null

Write-Host "Using psmux: $script:PSMUX" -ForegroundColor Yellow
Write-Host "Test session: $script:SessionName" -ForegroundColor Yellow

try {
    Write-Step "Starting detached test session"
    Remove-TestSession
    Invoke-Psmux -Arguments @('new-session', '-d', '-s', $script:SessionName, '-x', '120', '-y', '30') | Out-Null
    Start-Sleep -Seconds 2

    Write-Step "Creating a split so there is a visible pane border"
    $splitResult = Invoke-Psmux -Arguments @('split-window', '-t', "$($script:SessionName):0.0", '-h', '-d', '-P', '-F', '#{pane_id}')
    $newPaneId = $splitResult.Text.Trim()
    if ($newPaneId -notmatch '^%\d+$') {
        throw "split-window did not return a pane id. Output: '$($splitResult.Text)'"
    }
    Start-Sleep -Seconds 2

    $paneList = Invoke-Psmux -Arguments @('list-panes', '-t', $script:SessionName, '-F', '#{pane_id}')
    $paneIds = @($paneList.Lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^%\d+$' })
    if ($paneIds.Count -lt 2) {
        throw "Expected at least 2 panes, got $($paneIds.Count)."
    }

    $targetPane = $paneIds[0]
    Write-Pass "Created panes: $($paneIds -join ', ')"

    Write-Step "Configuring pane-border-status and pane-border-format"
    Invoke-Psmux -Arguments @('set-option', '-g', '-t', $script:SessionName, 'pane-border-status', 'top') | Out-Null
    Invoke-Psmux -Arguments @('set-option', '-g', '-t', $script:SessionName, 'pane-border-format', '#{pane_title}') | Out-Null

    $borderStatus = (Invoke-Psmux -Arguments @('show-options', '-g', '-t', $script:SessionName, '-v', 'pane-border-status')).Text.Trim()
    $borderFormat = (Invoke-Psmux -Arguments @('show-options', '-g', '-t', $script:SessionName, '-v', 'pane-border-format')).Text.Trim()
    Assert-Equal -Name 'pane-border-status' -Actual $borderStatus -Expected 'top'
    Assert-Equal -Name 'pane-border-format' -Actual $borderFormat -Expected '#{pane_title}'

    Write-Step "Setting pane title with select-pane -T"
    Invoke-Psmux -Arguments @('select-pane', '-t', $targetPane, '-T', $script:ExpectedTitle) | Out-Null
    Start-Sleep -Milliseconds 750

    Write-Step "Resolving pane title through tmux-compatible format expansion"
    $resolvedTitle = (Invoke-Psmux -Arguments @('display-message', '-t', $targetPane, '-p', '#{pane_title}')).Text.Trim()
    Assert-Equal -Name 'resolved pane title' -Actual $resolvedTitle -Expected $script:ExpectedTitle

    $listPaneTitle = (Invoke-Psmux -Arguments @('list-panes', '-t', $targetPane, '-F', '#{pane_title}')).Text.Trim()
    Assert-Equal -Name 'list-panes pane title' -Actual $listPaneTitle -Expected $script:ExpectedTitle

    Write-Step "Capturing pane output for diagnostics"
    $paneCapture = (Invoke-Psmux -Arguments @('capture-pane', '-t', $targetPane, '-p', '-e', '-S', '0', '-E', '2')).Text

    $diagnosticReport = @(
        "psmux: $script:PSMUX"
        "session: $script:SessionName"
        "targetPane: $targetPane"
        "secondaryPane: $newPaneId"
        "pane-border-status: $borderStatus"
        "pane-border-format: $borderFormat"
        "expectedTitle: $script:ExpectedTitle"
        "resolvedTitle: $resolvedTitle"
        "listPaneTitle: $listPaneTitle"
        ""
        "capture-pane -t $targetPane -p -e -S 0 -E 2"
        $paneCapture
    ) -join "`r`n"

    Set-Content -Path $script:DiagnosticsFile -Value $diagnosticReport -Encoding UTF8

    Write-Pass "Title resolution matches pane-border-format input"
    Write-Host "Diagnostics saved to: $script:DiagnosticsFile" -ForegroundColor Yellow

    if ($KeepSession) {
        Write-Host ""
        Write-Host "Session kept for manual follow-up:" -ForegroundColor Yellow
        Write-Host "  $script:PSMUX attach -t $script:SessionName" -ForegroundColor Yellow
        Write-Host "The active pane's top border should show: $script:ExpectedTitle" -ForegroundColor Yellow
    }
} finally {
    if ($KeepSession) {
        Write-Host "Skipping cleanup because -KeepSession was specified." -ForegroundColor Yellow
    } else {
        Write-Step "Cleaning up test session"
        Remove-TestSession
    }
}
