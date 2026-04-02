$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
. "$scriptDir/settings.ps1"
. "$scriptDir/vault.ps1"

Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$sessionName = 'winsmux-orchestra'
$bridgeScript = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..\..\scripts\psmux-bridge.ps1'))
$layoutScript = [System.IO.Path]::GetFullPath((Join-Path $scriptDir 'orchestra-layout.ps1'))
$psmuxBin = Get-PsmuxBin

if (-not $psmuxBin) {
    Write-Error 'Could not find a psmux binary. Tried: psmux, pmux, tmux.'
    exit 1
}

if (-not (Test-Path $bridgeScript)) {
    Write-Error "Bridge CLI not found: $bridgeScript"
    exit 1
}

function Invoke-Psmux {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$CaptureOutput
    )

    if ($CaptureOutput) {
        $output = & $script:psmuxBin @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $message = ($output | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = 'unknown psmux error'
            }

            throw "psmux $($Arguments -join ' ') failed: $message"
        }

        return $output
    }

    & $script:psmuxBin @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "psmux $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Invoke-Bridge {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$CaptureOutput,
        [switch]$AllowFailure
    )

    if ($CaptureOutput -or $AllowFailure) {
        $output = & pwsh -NoProfile -File $script:bridgeScript @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and -not $AllowFailure) {
            $message = ($output | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = 'unknown bridge error'
            }

            throw "psmux-bridge $($Arguments -join ' ') failed: $message"
        }

        return [PSCustomObject]@{
            ExitCode = $exitCode
            Output   = $output
        }
    }

    & pwsh -NoProfile -File $script:bridgeScript @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "psmux-bridge $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-ProjectDir {
    try {
        $currentPath = Invoke-Psmux -Arguments @('display-message', '-p', '#{pane_current_path}') -CaptureOutput
        $resolved = ($currentPath | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($resolved)) {
            return $resolved
        }
    } catch {
    }

    return (Get-Location).Path
}

function Get-GitWorktreeDir {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $dotGitPath = Join-Path $ProjectDir '.git'

    if (Test-Path $dotGitPath -PathType Leaf) {
        $raw = (Get-Content -Path $dotGitPath -Raw -Encoding UTF8).Trim()
        if ($raw -match '^gitdir:\s*(.+)$') {
            return [System.IO.Path]::GetFullPath($Matches[1].Trim())
        }
    }

    if (Test-Path $dotGitPath -PathType Container) {
        return (Get-Item -LiteralPath $dotGitPath).FullName
    }

    return $ProjectDir
}

function Get-CanonicalRole {
    param([Parameter(Mandatory = $true)][string]$AssignmentRole)

    switch -Regex ($AssignmentRole) {
        '^(?i)builder(?:$|[-_:/\s])' { return 'Builder' }
        '^(?i)researcher(?:$|[-_:/\s])' { return 'Researcher' }
        '^(?i)reviewer(?:$|[-_:/\s])' { return 'Reviewer' }
        '^(?i)commander(?:$|[-_:/\s])' { return 'Commander' }
        default { throw "Unsupported pane role label: $AssignmentRole" }
    }
}

function New-PaneEnvCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    return "`$env:${Name}=$(ConvertTo-PowerShellLiteral -Value $Value)"
}

function Invoke-PaneCommand {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$CommandText
    )

    Invoke-Psmux -Arguments @('send-keys', '-t', $PaneId, '-l', '--', $CommandText)
    Invoke-Psmux -Arguments @('send-keys', '-t', $PaneId, 'Enter')
}

function Get-AgentLaunchCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir
    )

    switch ($Agent.Trim().ToLowerInvariant()) {
        'codex' {
            return "codex -c model=$Model --full-auto -C $(ConvertTo-PowerShellLiteral -Value $ProjectDir) --add-dir $(ConvertTo-PowerShellLiteral -Value $GitWorktreeDir)"
        }
        'claude' {
            return 'claude --permission-mode bypassPermissions'
        }
        default {
            throw "Unsupported agent setting: $Agent"
        }
    }
}

function Get-VaultValue {
    param([Parameter(Mandatory = $true)][string]$Key)

    $result = Invoke-Bridge -Arguments @('vault', 'get', $Key) -CaptureOutput -AllowFailure
    if ($result.ExitCode -ne 0) {
        $message = ($result.Output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "credential not found: $Key"
        }

        throw $message
    }

    return ($result.Output | Out-String).TrimEnd()
}

function Get-LastNonEmptyLine {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $lines = $Text -split "\r?\n"
    for ($index = $lines.Length - 1; $index -ge 0; $index--) {
        if (-not [string]::IsNullOrWhiteSpace($lines[$index])) {
            return $lines[$index]
        }
    }

    return $null
}

function Get-TailPreview {
    param([AllowNull()][string]$Text, [int]$LineCount = 12)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return '(no output)'
    }

    $lines = $Text -split "\r?\n"
    if ($lines.Length -le $LineCount) {
        return ($lines -join [Environment]::NewLine)
    }

    return ($lines[($lines.Length - $LineCount)..($lines.Length - 1)] -join [Environment]::NewLine)
}

function Test-AgentPromptText {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Agent
    )

    $lastLine = Get-LastNonEmptyLine -Text $Text
    if ($null -eq $lastLine) {
        return $false
    }

    $trimmed = $lastLine.TrimStart()
    $rightChevron = [string][char]8250
    if ($trimmed.StartsWith('>') -or $trimmed.StartsWith($rightChevron)) {
        return $true
    }

    if ($Agent.Trim().ToLowerInvariant() -eq 'codex' -and $Text -match '(?im)\bgpt-[A-Za-z0-9._-]+\b.*\b\d+% left\b') {
        return $true
    }

    return $false
}

function Wait-AgentReady {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Agent,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $snapshot = Invoke-Psmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') -CaptureOutput
        $text = ($snapshot | Out-String).TrimEnd()
        if (Test-AgentPromptText -Text $text -Agent $Agent) {
            return
        }

        Start-Sleep -Seconds 2
    }

    $finalSnapshot = Invoke-Psmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') -CaptureOutput
    $finalText = ($finalSnapshot | Out-String).TrimEnd()
    throw "Timed out waiting for pane $PaneId to become ready. Last output:`n$(Get-TailPreview -Text $finalText)"
}

try {
    $settings = Get-BridgeSettings
    $projectDir = Get-ProjectDir
    $gitWorktreeDir = Get-GitWorktreeDir -ProjectDir $projectDir
    $vaultValues = [ordered]@{}

    foreach ($key in @($settings.vault_keys)) {
        try {
            $vaultValues[$key] = Get-VaultValue -Key $key
        } catch {
            Write-Error "Missing required vault key '$key': $($_.Exception.Message)"
            exit 1
        }
    }

    & $psmuxBin has-session -t $sessionName 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) {
        Invoke-Psmux -Arguments @('kill-session', '-t', $sessionName)
    }

    Invoke-Psmux -Arguments @('new-session', '-d', '-s', $sessionName)

    foreach ($entry in $vaultValues.GetEnumerator()) {
        Invoke-Psmux -Arguments @('set-environment', '-t', $sessionName, $entry.Key, $entry.Value)
    }

    $previousTargetSession = $env:WINSMUX_ORCHESTRA_SESSION
    $previousProjectDir = $env:WINSMUX_ORCHESTRA_PROJECT_DIR
    $env:WINSMUX_ORCHESTRA_SESSION = $sessionName
    $env:WINSMUX_ORCHESTRA_PROJECT_DIR = $projectDir

    try {
        $layout = . $layoutScript -Builders $settings.builders -Researchers $settings.researchers -Reviewers $settings.reviewers
    } finally {
        if ($null -eq $previousTargetSession) {
            Remove-Item Env:WINSMUX_ORCHESTRA_SESSION -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_ORCHESTRA_SESSION = $previousTargetSession
        }

        if ($null -eq $previousProjectDir) {
            Remove-Item Env:WINSMUX_ORCHESTRA_PROJECT_DIR -ErrorAction SilentlyContinue
        } else {
            $env:WINSMUX_ORCHESTRA_PROJECT_DIR = $previousProjectDir
        }
    }

    if ($null -eq $layout -or $null -eq $layout.Panes -or $layout.Panes.Count -lt 1) {
        Write-Error 'orchestra-layout did not return any panes.'
        exit 1
    }

    $launchCommand = Get-AgentLaunchCommand -Agent $settings.agent -Model $settings.model -ProjectDir $projectDir -GitWorktreeDir $gitWorktreeDir
    $paneSummaries = [System.Collections.Generic.List[object]]::new()

    foreach ($pane in @($layout.Panes)) {
        $assignmentLabel = [string]$pane.Role
        $canonicalRole = Get-CanonicalRole -AssignmentRole $assignmentLabel
        $label = $assignmentLabel.ToLowerInvariant()
        $paneId = [string]$pane.PaneId

        Invoke-Bridge -Arguments @('name', $paneId, $label)
        Invoke-PaneCommand -PaneId $paneId -CommandText (New-PaneEnvCommand -Name 'WINSMUX_ROLE' -Value $canonicalRole)
        Invoke-PaneCommand -PaneId $paneId -CommandText (New-PaneEnvCommand -Name 'WINSMUX_PANE_ID' -Value $paneId)
        Invoke-PaneCommand -PaneId $paneId -CommandText $launchCommand

        $paneSummaries.Add([PSCustomObject]@{
            Label = $label
            PaneId = $paneId
            Role = $canonicalRole
        })
    }

    foreach ($paneSummary in $paneSummaries) {
        try {
            Wait-AgentReady -PaneId $paneSummary.PaneId -Agent $settings.agent -TimeoutSeconds 60
        } catch {
            Write-Error "Agent readiness timeout for $($paneSummary.Label) [$($paneSummary.PaneId)]: $($_.Exception.Message)"
            exit 1
        }
    }

    Write-Output "Orchestra session: $sessionName"
    Write-Output "Agent: $($settings.agent)"
    Write-Output "Model: $($settings.model)"
    Write-Output "ProjectDir: $projectDir"
    Write-Output "GitWorktreeDir: $gitWorktreeDir"
    Write-Output ''
    Write-Output 'Panes:'
    foreach ($paneSummary in $paneSummaries) {
        Write-Output ("  {0,-14} {1,-8} {2}" -f $paneSummary.Label, $paneSummary.PaneId, $paneSummary.Role)
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
