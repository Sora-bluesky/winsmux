$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
. "$scriptDir/settings.ps1"
. "$scriptDir/vault.ps1"
. "$scriptDir/builder-worktree.ps1"
. "$scriptDir/logger.ps1"
. "$scriptDir/agent-readiness.ps1"
. "$scriptDir/orchestra-preflight.ps1"

Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$sessionName = 'winsmux-orchestra'
$bridgeScript = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..\..\scripts\winsmux-core.ps1'))
$layoutScript = [System.IO.Path]::GetFullPath((Join-Path $scriptDir 'orchestra-layout.ps1'))
$script:winsmuxBin = $null

function Write-OrchestraTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Content = '',
        [switch]$Append
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $escapedPath = $Path -replace '"', '""'
    if ([string]::IsNullOrEmpty($Content)) {
        if ($Append) {
            return
        }

        $writeCommand = 'type nul > "{0}"' -f $escapedPath
        cmd /d /c $writeCommand | Out-Null
    } else {
        $redirect = if ($Append) { '>>' } else { '>' }
        $writeCommand = 'more {0} "{1}"' -f $redirect, $escapedPath
        $Content | cmd /d /c $writeCommand | Out-Null
    }

    if ($LASTEXITCODE -ne 0) {
        throw "cmd.exe failed to write $Path"
    }
}

function Invoke-Winsmux {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$CaptureOutput
    )

    if ($CaptureOutput) {
        $output = & $script:winsmuxBin @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $message = ($output | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = 'unknown winsmux error'
            }

            throw "winsmux $($Arguments -join ' ') failed: $message"
        }

        return $output
    }

    & $script:winsmuxBin @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "winsmux $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Test-OrchestraServerSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionName
    )

    & $script:winsmuxBin has-session -t $SessionName 1>$null 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Ensure-OrchestraServer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionName,
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 2
    )

    if (Test-OrchestraServerSession -SessionName $SessionName) {
        return [ordered]@{
            SessionName    = $SessionName
            SessionCreated = $false
            ReadyChecks    = 1
        }
    }

    Invoke-Winsmux -Arguments @('new-session', '-d', '-s', $SessionName)

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        if (Test-OrchestraServerSession -SessionName $SessionName) {
            return [ordered]@{
                SessionName    = $SessionName
                SessionCreated = $true
                ReadyChecks    = $attempt
            }
        }

        if ($attempt -lt $RetryCount) {
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    throw "Orchestra server session '$SessionName' did not become ready after $RetryCount attempts. Verify the winsmux server can create sessions, then rerun orchestra-start.ps1."
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

            throw "winsmux $($Arguments -join ' ') failed: $message"
        }

        return [ordered]@{
            ExitCode = $exitCode
            Output   = $output
        }
    }

    & pwsh -NoProfile -File $script:bridgeScript @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "winsmux $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-ProjectDir {
    $scriptProjectDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if (-not [string]::IsNullOrWhiteSpace($scriptProjectDir)) {
        return $scriptProjectDir
    }

    try {
        $currentPath = Invoke-Winsmux -Arguments @('display-message', '-p', '#{pane_current_path}') -CaptureOutput
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
        return (Get-Item -LiteralPath $dotGitPath -Force).FullName
    }

    return $ProjectDir
}

function New-BuilderWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][int]$BuilderIndex
    )

    $branchName = "worktree-builder-$BuilderIndex"
    $worktreeRoot = Join-Path $ProjectDir '.worktrees'
    $worktreeRelativePath = ".worktrees/builder-$BuilderIndex"
    $worktreePath = Join-Path $ProjectDir '.worktrees' "builder-$BuilderIndex"

    New-Item -ItemType Directory -Path $worktreeRoot -Force | Out-Null

    if (Test-Path -LiteralPath $worktreePath) {
        throw "Builder worktree path already exists: $worktreePath. Clean it up before restarting orchestra."
    }

    $existingBranch = (& git -C $ProjectDir branch --list --format '%(refname:short)' $branchName 2>$null | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($existingBranch)) {
        throw "Builder worktree branch already exists: $branchName. Clean it up before restarting orchestra."
    }

    $output = (& git -C $ProjectDir worktree add $worktreeRelativePath -b $branchName 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        if ([string]::IsNullOrWhiteSpace($output)) {
            $output = 'unknown git worktree error'
        }

        throw "Failed to create Builder worktree $branchName at ${worktreePath}: $output"
    }

    return [ordered]@{
        BranchName     = $branchName
        WorktreePath   = $worktreePath
        GitWorktreeDir = Get-GitWorktreeDir -ProjectDir $worktreePath
    }
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

function Set-OrchestraSessionEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    Invoke-Winsmux -Arguments @('set-environment', '-t', $SessionName, $Name, $Value)
}

function Clear-OrchestraSessionEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Invoke-Winsmux -Arguments @('set-environment', '-u', '-t', $SessionName, $Name)
}

function Send-OrchestraBridgeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Text
    )

    Invoke-Bridge -Arguments @('send', $Target, $Text)
}

function Get-AgentLaunchCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [bool]$ExecMode = $false
    )

    switch ($Agent.Trim().ToLowerInvariant()) {
        'codex' {
            if ($ExecMode) {
                return ''
            }

            return "codex -c model=$Model --sandbox danger-full-access -C $(ConvertTo-PowerShellLiteral -Value $ProjectDir) --add-dir $(ConvertTo-PowerShellLiteral -Value $GitWorktreeDir)"
        }
        'claude' {
            return "claude --model $Model --permission-mode bypassPermissions"
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

function Test-VaultKeyExists {
    param([Parameter(Mandatory = $true)][string]$Key)

    $credTarget = "winsmux:$Key"
    $credPtr = [IntPtr]::Zero
    $ok = [WinCred]::CredRead($credTarget, [WinCred]::CRED_TYPE_GENERIC, 0, [ref]$credPtr)
    if ($ok) {
        [WinCred]::CredFree($credPtr) | Out-Null
        return $true
    }

    return $false
}

function Set-VaultKey {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $credTarget = "winsmux:$Key"
    $valueBytes = [System.Text.Encoding]::Unicode.GetBytes($Value)
    $blobPtr = [Runtime.InteropServices.Marshal]::AllocHGlobal($valueBytes.Length)
    [Runtime.InteropServices.Marshal]::Copy($valueBytes, 0, $blobPtr, $valueBytes.Length)

    $cred = New-Object WinCred+CREDENTIAL
    $cred.Type = [WinCred]::CRED_TYPE_GENERIC
    $cred.TargetName = $credTarget
    $cred.UserName = 'winsmux'
    $cred.CredentialBlobSize = $valueBytes.Length
    $cred.CredentialBlob = $blobPtr
    $cred.Persist = [WinCred]::CRED_PERSIST_LOCAL_MACHINE

    try {
        $ok = [WinCred]::CredWrite([ref]$cred, 0)
        if (-not $ok) {
            $errCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "CredWrite failed for '$Key' (error $errCode)"
        }
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($blobPtr)
    }
}

function Invoke-VaultPreflight {
    param([Parameter(Mandatory = $true)]$Settings)

    foreach ($key in @($Settings.vault_keys)) {
        if (Test-VaultKeyExists -Key $key) {
            continue
        }

        if ($key -eq 'GH_TOKEN') {
            try {
                $token = (& gh auth token 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
                    throw 'gh auth token returned empty or failed'
                }

                Set-VaultKey -Key 'GH_TOKEN' -Value $token
                Write-Output 'Preflight: auto-set GH_TOKEN from gh auth'
                Write-WinsmuxLog -Level INFO -Event 'preflight.vault.gh_token.auto_set' -Message 'Auto-set GH_TOKEN from gh auth.' -Data @{ key = 'GH_TOKEN' } | Out-Null
            } catch {
                Write-Warning "Preflight: failed to auto-set GH_TOKEN: $($_.Exception.Message)"
            }
        }
    }
}

function Invoke-VaultHealthCheck {
    <# TASK-119: Credential and vault health preflight with redacted diagnostics #>
    param([Parameter(Mandatory = $true)]$Settings)

    $results = @()
    foreach ($key in @($Settings.vault_keys)) {
        $exists = Test-VaultKeyExists -Key $key
        $redacted = if ($exists) {
            $val = (Get-VaultValue -Key $key)
            if ($val.Length -gt 4) { $val.Substring(0, 4) + '****' } else { '****' }
        } else { '(missing)' }

        $results += [ordered]@{
            Key      = $key
            Status   = if ($exists) { 'OK' } else { 'MISSING' }
            Preview  = $redacted
        }
    }

    # Check gh auth
    $ghAuth = 'UNKNOWN'
    try {
        $null = & gh auth status 2>&1
        $ghAuth = if ($LASTEXITCODE -eq 0) { 'OK' } else { 'FAILED' }
    } catch { $ghAuth = 'ERROR' }

    $results += [ordered]@{ Key = 'gh-auth'; Status = $ghAuth; Preview = '(cli)' }

    $missing = @($results | Where-Object { $_.Status -ne 'OK' })
    if ($missing.Count -gt 0) {
        Write-Warning "[vault-health] $($missing.Count) issue(s) detected:"
        foreach ($m in $missing) {
            Write-Warning "  $($m.Key): $($m.Status)"
        }
    } else {
        Write-Output "Preflight: vault health OK ($($results.Count) keys verified)"
    }

    return $results
}

function Invoke-CodexTrustPreflight {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $configPath = Join-Path $env:USERPROFILE '.codex' 'config.toml'
    if (-not (Test-Path $configPath)) {
        return
    }

    $normalizedDir = $ProjectDir.TrimEnd('\', '/')
    # In TOML double-quoted keys, each literal backslash is written as \\
    # The UNC prefix \\?\ becomes \\\\?\\ in TOML source text
    # Use [string]::Replace (not regex -replace) to double each backslash
    $tomlPath = $normalizedDir.Replace('\', '\\')
    $sectionHeader = '[projects."\\\\?\\' + $tomlPath + '"]'

    $content = Get-Content -Raw -Path $configPath -Encoding UTF8
    if ($content -match [regex]::Escape($sectionHeader)) {
        return
    }

    $newSection = "`n$sectionHeader`ntrust_level = `"trusted`"`n"
    $content = $content.TrimEnd() + "`n" + $newSection
    Write-OrchestraTextFile -Path $configPath -Content $content

    Write-Output "Preflight: registered Codex trust for $ProjectDir"
    Write-WinsmuxLog -Level INFO -Event 'preflight.codex_trust.registered' -Message "Registered Codex trust for $ProjectDir." -Data @{ project_dir = $ProjectDir } | Out-Null
}

function Invoke-ShieldHarnessInit {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $shDir = Join-Path $ProjectDir '.shield-harness'
    $sessionFile = Join-Path $shDir 'session.json'

    foreach ($sub in @('config', 'state', 'logs')) {
        $p = Join-Path $shDir $sub
        if (-not (Test-Path $p)) {
            New-Item -Path $p -ItemType Directory -Force | Out-Null
        }
    }

    $configDir = Join-Path $shDir 'config'
    $prodHosts = Join-Path $configDir 'production-hosts.json'
    if (-not (Test-Path $prodHosts)) {
        Write-OrchestraTextFile -Path $prodHosts -Content '{"blocked":["localhost","127.0.0.1","169.254.169.254"],"patterns":[]}'
    }

    $jurisdictions = Join-Path $configDir 'allowed-jurisdictions.json'
    if (-not (Test-Path $jurisdictions)) {
        Write-OrchestraTextFile -Path $jurisdictions -Content '{"allowed":["JP"],"default_action":"warn"}'
    }

    $session = [ordered]@{
        session_id     = [guid]::NewGuid().ToString()
        started_at     = (Get-Date -Format o)
        hook_count     = 0
        deny_count     = 0
        evidence_count = 0
    }
    Write-OrchestraTextFile -Path $sessionFile -Content ($session | ConvertTo-Json -Depth 2)

    Write-Output "Preflight: shield-harness initialized at $shDir"
    Write-WinsmuxLog -Level INFO -Event 'preflight.shield_harness.init' -Message "Shield-Harness initialized at $shDir." -Data @{ shield_dir = $shDir } | Out-Null
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

function Wait-PaneShellReady {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $snapshot = Invoke-Winsmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') -CaptureOutput
            $text = ($snapshot | Out-String).TrimEnd()
            if ($null -ne (Get-LastNonEmptyLine -Text $text)) {
                return
            }
        } catch {
        }

        Start-Sleep -Milliseconds 250
    }

    try {
        $finalSnapshot = Invoke-Winsmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') -CaptureOutput
        $finalText = ($finalSnapshot | Out-String).TrimEnd()
        throw "Timed out waiting for pane $PaneId shell prompt after respawn. Last output:`n$(Get-TailPreview -Text $finalText)"
    } catch {
        throw "Timed out waiting for pane $PaneId shell prompt after respawn: $($_.Exception.Message)"
    }
}

function ConvertTo-YamlScalar {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [bool]) {
        if ($Value) {
            return 'true'
        }

        return 'false'
    }

    $text = [string]$Value
    if ($text.Length -eq 0) {
        return "''"
    }

    return "'" + $text.Replace("'", "''") + "'"
}

function Get-OrchestraManifestPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return (Join-Path (Join-Path $ProjectDir '.winsmux') 'manifest.yaml')
}

function Save-OrchestraSessionState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [Parameter(Mandatory = $true)][System.Collections.IEnumerable]$PaneSummaries,
        [Nullable[int]]$CommanderPollPid = $null,
        [Nullable[int]]$WatchdogPid = $null,
        [Nullable[int]]$ServerWatchdogPid = $null
    )

    $manifestPath = Get-OrchestraManifestPath -ProjectDir $ProjectDir
    $manifestDir = Split-Path -Parent $manifestPath
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('version: 1') | Out-Null
    $lines.Add(('saved_at: {0}' -f (ConvertTo-YamlScalar -Value (Get-Date -Format o)))) | Out-Null
    $lines.Add('session:') | Out-Null
    $lines.Add(('  name: {0}' -f (ConvertTo-YamlScalar -Value $SessionName))) | Out-Null
    $lines.Add("  status: 'running'") | Out-Null
    $lines.Add(('  agent: {0}' -f (ConvertTo-YamlScalar -Value $Settings.agent))) | Out-Null
    $lines.Add(('  model: {0}' -f (ConvertTo-YamlScalar -Value $Settings.model))) | Out-Null
    $lines.Add(('  project_dir: {0}' -f (ConvertTo-YamlScalar -Value $ProjectDir))) | Out-Null
    $lines.Add(('  git_worktree_dir: {0}' -f (ConvertTo-YamlScalar -Value $GitWorktreeDir))) | Out-Null
    if ($null -ne $CommanderPollPid) {
        $lines.Add(('  commander_poll_pid: {0}' -f $CommanderPollPid)) | Out-Null
    } else {
        $lines.Add('  commander_poll_pid: null') | Out-Null
    }
    if ($null -ne $WatchdogPid) {
        $lines.Add(('  watchdog_pid: {0}' -f $WatchdogPid)) | Out-Null
    } else {
        $lines.Add('  watchdog_pid: null') | Out-Null
    }
    if ($null -ne $ServerWatchdogPid) {
        $lines.Add(('  server_watchdog_pid: {0}' -f $ServerWatchdogPid)) | Out-Null
    } else {
        $lines.Add('  server_watchdog_pid: null') | Out-Null
    }
    $lines.Add('panes:') | Out-Null

    foreach ($paneSummary in @($PaneSummaries)) {
        $lines.Add(('  - label: {0}' -f (ConvertTo-YamlScalar -Value $paneSummary.Label))) | Out-Null
        $lines.Add(('    pane_id: {0}' -f (ConvertTo-YamlScalar -Value $paneSummary.PaneId))) | Out-Null
        $lines.Add(('    role: {0}' -f (ConvertTo-YamlScalar -Value $paneSummary.Role))) | Out-Null
        $lines.Add(('    exec_mode: {0}' -f (ConvertTo-YamlScalar -Value $paneSummary.ExecMode))) | Out-Null
        $lines.Add(('    launch_dir: {0}' -f (ConvertTo-YamlScalar -Value $paneSummary.LaunchDir))) | Out-Null
        $lines.Add(('    builder_branch: {0}' -f (ConvertTo-YamlScalar -Value $paneSummary.BuilderBranch))) | Out-Null
        $lines.Add(('    builder_worktree_path: {0}' -f (ConvertTo-YamlScalar -Value $paneSummary.BuilderWorktreePath))) | Out-Null
        $lines.Add("    task: null") | Out-Null
    }

    Write-OrchestraTextFile -Path $manifestPath -Content ($lines -join [Environment]::NewLine)
    return $manifestPath
}

function Wait-AgentReady {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Agent,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $snapshot = Invoke-Winsmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') -CaptureOutput
        $text = ($snapshot | Out-String).TrimEnd()
        if (Test-AgentPromptText -Text $text -Agent $Agent) {
            return
        }

        Start-Sleep -Seconds 2
    }

    $finalSnapshot = Invoke-Winsmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') -CaptureOutput
    $finalText = ($finalSnapshot | Out-String).TrimEnd()
    throw "Timed out waiting for pane $PaneId to become ready. Last output:`n$(Get-TailPreview -Text $finalText)"
}

function Start-AgentWatchdogJob {
    param(
        [Parameter(Mandatory = $true)][string]$WatchdogScriptPath,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [int]$IdleThreshold = 120,
        [int]$PollInterval = 30
    )

    return (Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile',
            '-File',
            $WatchdogScriptPath,
            '-ManifestPath',
            $ManifestPath,
            '-SessionName',
            $SessionName,
            '-IdleThreshold',
            $IdleThreshold,
            '-PollInterval',
            $PollInterval
        ) -WindowStyle Hidden -PassThru)
}

function Start-CommanderPollJob {
    param(
        [Parameter(Mandatory = $true)][string]$CommanderPollScriptPath,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [int]$Interval = 20
    )

    return (Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile',
            '-File',
            $CommanderPollScriptPath,
            '-ManifestPath',
            $ManifestPath,
            '-Interval',
            $Interval
        ) -WindowStyle Hidden -PassThru)
}

function Start-ServerWatchdogJob {
    param(
        [Parameter(Mandatory = $true)][string]$WatchdogScriptPath,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [ValidateRange(5, 10)][int]$PollInterval = 5,
        [int]$MaxRestartAttempts = 3,
        [int]$RestartWindowMinutes = 10
    )

    return (Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile',
            '-File',
            $WatchdogScriptPath,
            '-ManifestPath',
            $ManifestPath,
            '-SessionName',
            $SessionName,
            '-PollInterval',
            $PollInterval,
            '-MaxRestartAttempts',
            $MaxRestartAttempts,
            '-RestartWindowMinutes',
            $RestartWindowMinutes
        ) -WindowStyle Hidden -PassThru)
}

function Get-OrchestraEventsPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path (Join-Path $ProjectDir '.winsmux') 'events.jsonl'
}

function Get-OrchestraSessionPaneIds {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    $resolvedPaneIds = [System.Collections.Generic.List[string]]::new()
    $paneIds = Invoke-Winsmux -Arguments @('list-panes', '-t', $SessionName, '-F', '#{pane_id}') -CaptureOutput
    foreach ($paneId in @($paneIds)) {
        $resolvedPaneId = ([string]$paneId).Trim()
        if ($resolvedPaneId -match '^%\d+$' -and -not $resolvedPaneIds.Contains($resolvedPaneId)) {
            $resolvedPaneIds.Add($resolvedPaneId) | Out-Null
        }
    }

    return @($resolvedPaneIds)
}

function Get-OrchestraBootstrapPaneId {
    param([Parameter(Mandatory = $true)][string]$SessionName)

    foreach ($paneId in @(Get-OrchestraSessionPaneIds -SessionName $SessionName)) {
        return $paneId
    }

    throw "Could not resolve bootstrap pane id for session $SessionName."
}

function Remove-OrchestraCreatedWorktrees {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][System.Collections.IEnumerable]$CreatedWorktrees
    )

    $removedWorktrees = [System.Collections.Generic.List[object]]::new()
    foreach ($createdWorktree in @($CreatedWorktrees)) {
        if ($null -eq $createdWorktree) {
            continue
        }

        $worktreePath = [string]$createdWorktree.WorktreePath
        $branchName = [string]$createdWorktree.BranchName
        if ([string]::IsNullOrWhiteSpace($worktreePath) -and [string]::IsNullOrWhiteSpace($branchName)) {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($worktreePath) -and (Test-Path -LiteralPath $worktreePath)) {
            try {
                & git -C $ProjectDir worktree remove $worktreePath --force 2>$null | Out-Null
            } catch {
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($branchName)) {
            try {
                & git -C $ProjectDir branch -D $branchName 2>$null | Out-Null
            } catch {
            }
        }

        $removedWorktrees.Add([ordered]@{
            BranchName   = $branchName
            WorktreePath = $worktreePath
        }) | Out-Null
    }

    return @($removedWorktrees)
}

function Write-OrchestraStartupFailureEvent {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$FailureMessage,
        [AllowNull()][string]$BootstrapPaneId,
        [Parameter(Mandatory = $true)][System.Collections.IEnumerable]$RemovedPaneIds,
        [Parameter(Mandatory = $true)][System.Collections.IEnumerable]$RemovedWorktrees,
        [Parameter(Mandatory = $true)][bool]$BootstrapRespawned,
        [Parameter(Mandatory = $true)][System.Collections.IEnumerable]$RollbackErrors
    )

    try {
        $eventsPath = Get-OrchestraEventsPath -ProjectDir $ProjectDir
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $eventsPath)) | Out-Null

        $record = [ordered]@{
            timestamp   = (Get-Date).ToString('o')
            session     = $SessionName
            event       = 'orchestra.startup.failed'
            message     = $FailureMessage
            label       = ''
            pane_id     = if ($null -eq $BootstrapPaneId) { '' } else { $BootstrapPaneId }
            role        = ''
            status      = 'failed'
            exit_reason = 'startup_failed'
            data        = [ordered]@{
                bootstrap_pane_id   = if ($null -eq $BootstrapPaneId) { '' } else { $BootstrapPaneId }
                bootstrap_respawned = $BootstrapRespawned
                removed_pane_ids    = @($RemovedPaneIds)
                removed_worktrees   = @($RemovedWorktrees)
                rollback_errors     = @($RollbackErrors)
            }
        }

        $line = ($record | ConvertTo-Json -Compress -Depth 10)
        Write-OrchestraTextFile -Path $eventsPath -Content $line -Append
        return $record
    } catch {
        return $null
    }
}

function Invoke-OrchestraStartupRollback {
    param(
        [AllowNull()][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [AllowNull()][string]$BootstrapPaneId,
        [Parameter(Mandatory = $true)][System.Collections.IEnumerable]$CreatedPaneIds,
        [Parameter(Mandatory = $true)][System.Collections.IEnumerable]$CreatedWorktrees,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    $removedPaneIds = [System.Collections.Generic.List[string]]::new()
    $rollbackErrors = [System.Collections.Generic.List[string]]::new()
    $bootstrapRespawned = $false
    $removedWorktrees = @()
    $trackedPaneIds = [System.Collections.Generic.List[string]]::new()

    foreach ($paneId in @($CreatedPaneIds)) {
        $resolvedPaneId = [string]$paneId
        if ([string]::IsNullOrWhiteSpace($resolvedPaneId) -or $trackedPaneIds.Contains($resolvedPaneId)) {
            continue
        }

        $trackedPaneIds.Add($resolvedPaneId) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($BootstrapPaneId)) {
        try {
            foreach ($sessionPaneId in @(Get-OrchestraSessionPaneIds -SessionName $SessionName)) {
                if (-not $trackedPaneIds.Contains($sessionPaneId)) {
                    $trackedPaneIds.Add($sessionPaneId) | Out-Null
                }
            }
        } catch {
            $rollbackErrors.Add("list-panes failed: $($_.Exception.Message)") | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ProjectDir)) {
        $journalPath = Join-Path $ProjectDir '.winsmux' 'startup-journal.log'
        $journalDir = Split-Path $journalPath -Parent
        if (-not (Test-Path $journalDir)) {
            New-Item -ItemType Directory -Path $journalDir -Force | Out-Null
        }

        $timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
        Write-OrchestraTextFile -Path $journalPath -Content "[$timestamp] FAILED: $FailureMessage" -Append
    }

    foreach ($trackedPaneId in @($trackedPaneIds)) {
        if ([string]::IsNullOrWhiteSpace($trackedPaneId) -or $trackedPaneId -eq $BootstrapPaneId) {
            continue
        }

        try {
            Invoke-Winsmux -Arguments @('kill-pane', '-t', $trackedPaneId)
            $removedPaneIds.Add($trackedPaneId) | Out-Null
        } catch {
            $rollbackErrors.Add("kill-pane $trackedPaneId failed: $($_.Exception.Message)") | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($BootstrapPaneId) -and -not [string]::IsNullOrWhiteSpace($ProjectDir)) {
        try {
            Invoke-Winsmux -Arguments @('respawn-pane', '-k', '-t', $BootstrapPaneId, '-c', $ProjectDir)
            Wait-PaneShellReady -PaneId $BootstrapPaneId
            $bootstrapRespawned = $true
        } catch {
            $rollbackErrors.Add("respawn-pane $BootstrapPaneId failed: $($_.Exception.Message)") | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ProjectDir)) {
        $removedWorktrees = @(Remove-OrchestraCreatedWorktrees -ProjectDir $ProjectDir -CreatedWorktrees $CreatedWorktrees)
        $null = Write-OrchestraStartupFailureEvent -ProjectDir $ProjectDir -SessionName $SessionName -FailureMessage $FailureMessage -BootstrapPaneId $BootstrapPaneId -RemovedPaneIds @($removedPaneIds) -RemovedWorktrees $removedWorktrees -BootstrapRespawned $bootstrapRespawned -RollbackErrors @($rollbackErrors)
    }

    return [ordered]@{
        RemovedPaneIds    = @($removedPaneIds)
        RemovedWorktrees  = @($removedWorktrees)
        BootstrapRespawned = $bootstrapRespawned
        RollbackErrors    = @($rollbackErrors)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $commanderPollProcess = $null
    $watchdogProcess = $null
    $serverWatchdogProcess = $null
    $projectDir = $null
    $gitWorktreeDir = $null
    $orchestraServer = $null
    $createdPaneIds = @()
    $bootstrapPaneId = $null
    $createdWorktrees = @()
    try {
        $script:winsmuxBin = Get-WinsmuxBin
        $winsmuxBin = $script:winsmuxBin
        if (-not $winsmuxBin) {
            Write-Error 'Could not find a winsmux binary. Tried: winsmux, pmux, tmux.'
            exit 1
        }

        $orchestraServer = Ensure-OrchestraServer -SessionName $sessionName

        if (-not (Test-Path $bridgeScript)) {
            Write-Error "Bridge CLI not found: $bridgeScript"
            exit 1
        }

        $settings = Get-BridgeSettings
        $projectDir = Get-ProjectDir
        Initialize-WinsmuxLog -ProjectDir $projectDir -SessionName $sessionName | Out-Null
        Write-WinsmuxLog -Level INFO -Event 'preflight.settings.loaded' -Message 'Loaded orchestra settings.' -Data @{ agent = $settings.agent; model = $settings.model } | Out-Null
        Write-WinsmuxLog -Level INFO -Event 'preflight.winsmux_bin.ready' -Message "Using winsmux binary: $winsmuxBin." -Data @{ winsmux_bin = $winsmuxBin } | Out-Null
        Write-WinsmuxLog -Level INFO -Event 'preflight.bridge_script.ready' -Message "Using bridge script: $bridgeScript." -Data @{ bridge_script = $bridgeScript } | Out-Null
        Write-WinsmuxLog -Level INFO -Event 'preflight.project_dir.resolved' -Message "Resolved project directory: $projectDir." -Data @{ project_dir = $projectDir } | Out-Null
        $gitWorktreeDir = Get-GitWorktreeDir -ProjectDir $projectDir
        Write-WinsmuxLog -Level INFO -Event 'preflight.git_worktree.resolved' -Message "Resolved git worktree directory: $gitWorktreeDir." -Data @{ git_worktree_dir = $gitWorktreeDir } | Out-Null

        Write-WinsmuxLog -Level INFO -Event 'preflight.vault.start' -Message 'Running vault preflight.' | Out-Null
        Invoke-VaultPreflight -Settings $settings
        Write-WinsmuxLog -Level INFO -Event 'preflight.codex_trust.start' -Message 'Running Codex trust preflight.' | Out-Null
        Invoke-CodexTrustPreflight -ProjectDir $projectDir
        Invoke-ShieldHarnessInit -ProjectDir $projectDir

        $vaultValues = [ordered]@{}

        Write-WinsmuxLog -Level INFO -Event 'preflight.vault_values.start' -Message 'Resolving required vault values.' -Data @{ key_count = @($settings.vault_keys).Count } | Out-Null
        Invoke-VaultHealthCheck -Settings $settings | Out-Null
        foreach ($key in @($settings.vault_keys)) {
            try {
                $vaultValues[$key] = Get-VaultValue -Key $key
                Write-WinsmuxLog -Level INFO -Event 'preflight.vault_value.loaded' -Message "Resolved vault key $key." -Data @{ key = $key } | Out-Null
            } catch {
                Write-Error "Missing required vault key '$key': $($_.Exception.Message)"
                exit 1
            }
        }

        Write-WinsmuxLog -Level INFO -Event 'preflight.zombie_cleanup.start' -Message 'Removing orchestra zombie processes.' | Out-Null
        $zombieCleanup = Remove-OrchestraZombieProcesses -SessionName $sessionName -ProjectDir $projectDir -GitWorktreeDir $gitWorktreeDir -BridgeScript $bridgeScript -WinsmuxBin $winsmuxBin
        if (@($zombieCleanup.Killed).Count -gt 0) {
            Write-WinsmuxLog -Level INFO -Event 'preflight.git_worktree.prune_after_zombie_cleanup' -Message 'Pruning git worktree metadata after zombie cleanup.' -Data @{ killed_count = @($zombieCleanup.Killed).Count } | Out-Null
            Invoke-BuilderWorktreeGit -ProjectDir $projectDir -Arguments @('worktree', 'prune') | Out-Null
        }

    # Clean up any leftover orchestra panes in default session (#213)
    try {
        $existingPanes = & $winsmuxBin list-panes -F '#{pane_id} #{pane_title}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $existingPanes) {
            $orchestraLabels = @('builder-', 'researcher-', 'reviewer-')
            foreach ($line in ($existingPanes -split "`n")) {
                $parts = $line.Trim() -split '\s+', 2
                if ($parts.Count -ge 2) {
                    $paneId = $parts[0]
                    $title = $parts[1]
                    foreach ($label in $orchestraLabels) {
                        if ($title -like "$label*") {
                            Write-WinsmuxLog -Level INFO -Event 'preflight.default_pane.kill' -Message "Removing leftover orchestra pane $paneId ($title) from default session." -Data @{ pane_id = $paneId; title = $title } | Out-Null
                            & $winsmuxBin kill-pane -t $paneId 2>$null
                            break
                        }
                    }
                }
            }
        }
    } catch { }

    if (-not [bool]$orchestraServer.SessionCreated) {
        Write-WinsmuxLog -Level INFO -Event 'preflight.session.check' -Message "Checking for existing session $sessionName." -Data @{ session_name = $sessionName } | Out-Null
        $sessionHealth = Test-OrchestraServerHealth -SessionName $sessionName -WinsmuxBin $winsmuxBin
        Write-WinsmuxLog -Level INFO -Event 'preflight.session.health' -Message "Session health for ${sessionName}: $sessionHealth." -Data @{ session_name = $sessionName; health = $sessionHealth } | Out-Null
        switch ($sessionHealth) {
            'Healthy' {
                Write-WinsmuxLog -Level INFO -Event 'preflight.session.kill' -Message "Removing existing session $sessionName." -Data @{ session_name = $sessionName } | Out-Null
                Invoke-Winsmux -Arguments @('kill-session', '-t', $sessionName)
            }
            'Unhealthy' {
                Write-Warning "Preflight: removing stale session registration for $sessionName"
                Write-WinsmuxLog -Level WARN -Event 'preflight.session.registration_cleared' -Message "Cleared stale session registration for $sessionName." -Data @{ session_name = $sessionName } | Out-Null
                Clear-OrchestraSessionRegistration -SessionName $sessionName
            }
        }
    } else {
        Write-WinsmuxLog -Level INFO -Event 'preflight.session.reuse' -Message "Reusing server-created session $sessionName." -Data ([ordered]@{
            session_name    = $sessionName
            session_created = $true
        }) | Out-Null
    }

    # --- Startup lock (TASK-117) ---
    $lockFile = Join-Path $projectDir '.winsmux' 'orchestra.lock'
    if (Test-Path $lockFile) {
        try {
            $lockData = Get-Content $lockFile -Raw | ConvertFrom-Json
            $lockAge = ((Get-Date) - [datetime]$lockData.started_at).TotalSeconds
            $lockPid = $lockData.pid
            $processAlive = $null -ne (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)
            if ($processAlive -and $lockAge -lt 300) {
                throw "Orchestra already starting (lock PID=$lockPid, age=${lockAge}s). Remove $lockFile to force."
            }
        } catch [System.Management.Automation.RuntimeException] {
            throw
        } catch {
            # Stale/corrupt lock — overwrite
        }
    }
    $lockDir = Split-Path $lockFile -Parent
    if (-not (Test-Path $lockDir)) { New-Item -ItemType Directory -Path $lockDir -Force | Out-Null }
    Write-OrchestraTextFile -Path $lockFile -Content ([ordered]@{ pid = $PID; started_at = (Get-Date).ToString('o') } | ConvertTo-Json)

    Write-WinsmuxLog -Level INFO -Event 'preflight.builder_worktree_cleanup.start' -Message 'Cleaning stale Builder worktrees.' | Out-Null
    $builderCleanup = Invoke-StaleBuilderWorktreeCleanup -ProjectDir $projectDir
    foreach ($removedWorktreePath in @($builderCleanup.RemovedWorktreePaths)) {
        Write-Output "Preflight: removed stale Builder worktree $removedWorktreePath"
        Write-WinsmuxLog -Level INFO -Event 'preflight.builder_worktree_cleanup.worktree_removed' -Message "Removed stale Builder worktree $removedWorktreePath." -Data ([ordered]@{ worktree_path = $removedWorktreePath }) | Out-Null
    }
    foreach ($removedDirectoryPath in @($builderCleanup.RemovedDirectoryPaths)) {
        Write-Output "Preflight: removed stale Builder directory $removedDirectoryPath"
        Write-WinsmuxLog -Level INFO -Event 'preflight.builder_worktree_cleanup.directory_removed' -Message "Removed stale Builder directory $removedDirectoryPath." -Data ([ordered]@{ directory_path = $removedDirectoryPath }) | Out-Null
    }
    foreach ($removedBranch in @($builderCleanup.RemovedBranches)) {
        Write-Output "Preflight: removed stale Builder branch $removedBranch"
        Write-WinsmuxLog -Level INFO -Event 'preflight.builder_worktree_cleanup.branch_removed' -Message "Removed stale Builder branch $removedBranch." -Data ([ordered]@{ branch_name = $removedBranch }) | Out-Null
    }

        # Ensure-OrchestraServer may already have created the detached session.
        if ([bool]$orchestraServer.SessionCreated) {
            Write-WinsmuxLog -Level INFO -Event 'preflight.session.ready' -Message "Session $sessionName was already created by Ensure-OrchestraServer." -Data ([ordered]@{
                session_name    = $sessionName
                session_created = $true
            }) | Out-Null
        } else {
            Write-WinsmuxLog -Level INFO -Event 'preflight.session.create' -Message "Creating session $sessionName." -Data ([ordered]@{ session_name = $sessionName }) | Out-Null
            Invoke-Winsmux -Arguments @('new-session', '-d', '-s', $sessionName)
        }
        $bootstrapPaneId = Get-OrchestraBootstrapPaneId -SessionName $sessionName
        $createdPaneIds = @($bootstrapPaneId)

        # TASK-231: preserve failed panes for debug inspection
        try {
            Invoke-Winsmux -Arguments @('set-option', '-t', $sessionName, 'remain-on-exit', 'on')
        } catch {
            Write-Warning "Could not set remain-on-exit for session ${sessionName}: $($_.Exception.Message)"
        }

        Write-WinsmuxLog -Level INFO -Event 'preflight.session_env.start' -Message 'Publishing vault values to session environment.' -Data ([ordered]@{ key_count = $vaultValues.Count }) | Out-Null
        foreach ($entry in $vaultValues.GetEnumerator()) {
            Invoke-Winsmux -Arguments @('set-environment', '-t', $sessionName, $entry.Key, $entry.Value)
        }
        Invoke-Winsmux -Arguments @('set-environment', '-t', $sessionName, 'GIT_EDITOR', 'true')
        Write-WinsmuxLog -Level INFO -Event 'preflight.session_env.git_editor_set' -Message 'Set GIT_EDITOR=true for orchestra session.' -Data ([ordered]@{ session_name = $sessionName; key = 'GIT_EDITOR'; value = 'true' }) | Out-Null

    $previousTargetSession = $env:WINSMUX_ORCHESTRA_SESSION
    $previousProjectDir = $env:WINSMUX_ORCHESTRA_PROJECT_DIR
    $env:WINSMUX_ORCHESTRA_SESSION = $sessionName
    $env:WINSMUX_ORCHESTRA_PROJECT_DIR = $projectDir

        try {
            try {
                $layout = . $layoutScript -SessionName $sessionName -Builders $settings.builders -Researchers $settings.researchers -Reviewers $settings.reviewers
                foreach ($sessionPaneId in @(Get-OrchestraSessionPaneIds -SessionName $sessionName)) {
                    if ($createdPaneIds -notcontains $sessionPaneId) {
                        $createdPaneIds += $sessionPaneId
                    }
                }
            } catch {
                if (-not [string]::IsNullOrWhiteSpace($bootstrapPaneId)) {
                    foreach ($sessionPaneId in @(Get-OrchestraSessionPaneIds -SessionName $sessionName)) {
                        if ($createdPaneIds -notcontains $sessionPaneId) {
                            $createdPaneIds += $sessionPaneId
                        }
                    }
                }

                throw
            }
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

    $sessionRoleMap = [ordered]@{}
    foreach ($pane in @($layout.Panes)) {
        $sessionRoleMap[[string]$pane.PaneId] = Get-CanonicalRole -AssignmentRole ([string]$pane.Role)
    }
    Set-OrchestraSessionEnvironment -SessionName $sessionName -Name 'WINSMUX_ROLE_MAP' -Value (($sessionRoleMap | ConvertTo-Json -Compress))

    $paneSummaries = [System.Collections.Generic.List[object]]::new()
    $builderIndex = 0

    foreach ($pane in @($layout.Panes)) {
        $assignmentLabel = [string]$pane.Role
        $canonicalRole = Get-CanonicalRole -AssignmentRole $assignmentLabel
        $label = $assignmentLabel.ToLowerInvariant()
        $paneId = [string]$pane.PaneId
        $launchDir = $projectDir
        $launchGitWorktreeDir = $gitWorktreeDir
        $builderBranch = $null
        $builderWorktreePath = $null

        if ($canonicalRole -eq 'Builder') {
            $builderIndex++
            $builderWorktree = New-BuilderWorktree -ProjectDir $projectDir -BuilderIndex $builderIndex
            $createdWorktrees += [ordered]@{
                BranchName   = $builderWorktree.BranchName
                WorktreePath = $builderWorktree.WorktreePath
            }
            $launchDir = $builderWorktree.WorktreePath
            $launchGitWorktreeDir = $builderWorktree.GitWorktreeDir
            $builderBranch = $builderWorktree.BranchName
            $builderWorktreePath = $builderWorktree.WorktreePath
        }

        $roleAgentConfig = Get-RoleAgentConfig -Role $canonicalRole -Settings $settings
        $execMode = ([string]$roleAgentConfig.Agent).Trim().ToLowerInvariant() -eq 'codex'
        $launchCommand = Get-AgentLaunchCommand -Agent $roleAgentConfig.Agent -Model $roleAgentConfig.Model -ProjectDir $launchDir -GitWorktreeDir $launchGitWorktreeDir -ExecMode $false

        Invoke-Bridge -Arguments @('name', $paneId, $label)
        try {
            Set-OrchestraSessionEnvironment -SessionName $sessionName -Name 'WINSMUX_ROLE' -Value $canonicalRole
            Set-OrchestraSessionEnvironment -SessionName $sessionName -Name 'WINSMUX_PANE_ID' -Value $paneId
            Invoke-Winsmux -Arguments @('respawn-pane', '-k', '-t', $paneId, '-c', $launchDir)
            Wait-PaneShellReady -PaneId $paneId
            # TASK-236: set cwd via cd (respawn-pane -c unreliable on Windows)
            Send-OrchestraBridgeCommand -Target $paneId -Text "cd $(ConvertTo-PowerShellLiteral -Value $launchDir)"
            Start-Sleep -Milliseconds 500
            # TASK-236: inject role and pane_id into pane process
            Send-OrchestraBridgeCommand -Target $paneId -Text "`$env:WINSMUX_ROLE = '$canonicalRole'"
            Send-OrchestraBridgeCommand -Target $paneId -Text "`$env:WINSMUX_PANE_ID = '$paneId'"
            # TASK-234: inject worktree path for Builder isolation (#347)
            if ($canonicalRole -eq 'Builder' -and -not [string]::IsNullOrWhiteSpace($builderWorktreePath)) {
                Send-OrchestraBridgeCommand -Target $paneId -Text "`$env:WINSMUX_BUILDER_WORKTREE = '$builderWorktreePath'"
            }
            Start-Sleep -Milliseconds 300
            # TASK-231: verify pane exists after respawn
            try {
                Invoke-Winsmux -Arguments @('display-message', '-t', $paneId, '-p', '#{pane_id}') -CaptureOutput | Out-Null
            } catch {
                Write-Warning "TASK-231: pane $paneId ($label) not found after respawn-pane."
            }
            if (-not [string]::IsNullOrWhiteSpace($launchCommand)) {
                Send-OrchestraBridgeCommand -Target $paneId -Text $launchCommand
            } else {
                Write-Warning "TASK-231: empty launch command for pane $paneId ($label, role=$canonicalRole, execMode=$execMode). Agent will not start automatically."
            }
        } finally {
            foreach ($envName in @('WINSMUX_ROLE', 'WINSMUX_PANE_ID')) {
                try {
                    Clear-OrchestraSessionEnvironment -SessionName $sessionName -Name $envName
                } catch {
                }
            }
        }

        $paneSummaries.Add([ordered]@{
            Label = $label
            PaneId = $paneId
            Role = $canonicalRole
            ExecMode = $false
            LaunchDir = $launchDir
            BuilderBranch = $builderBranch
            BuilderWorktreePath = $builderWorktreePath
        })
    }

    foreach ($paneSummary in $paneSummaries) {
        try {
            $roleAgentConfig = Get-RoleAgentConfig -Role $paneSummary.Role -Settings $settings
            Wait-AgentReady -PaneId $paneSummary.PaneId -Agent $roleAgentConfig.Agent -TimeoutSeconds 60
        } catch {
            Write-Error "Agent readiness timeout for $($paneSummary.Label) [$($paneSummary.PaneId)]: $($_.Exception.Message)"
            exit 1
        }
    }

    # TASK-236: validate all panes are alive before saving manifest
    $validPaneSummaries = [System.Collections.Generic.List[object]]::new()
    foreach ($paneSummary in $paneSummaries) {
        try {
            Invoke-Winsmux -Arguments @('display-message', '-t', $paneSummary.PaneId, '-p', '#{pane_id}') -CaptureOutput | Out-Null
            $validPaneSummaries.Add($paneSummary)
        } catch {
            Write-Warning "TASK-236: pane $($paneSummary.PaneId) ($($paneSummary.Label)) is dead before manifest save. Excluding from manifest."
        }
    }
    if ($validPaneSummaries.Count -eq 0) {
        Write-Error "TASK-236: no living panes found. Cannot save manifest."
        exit 1
    }

    $manifestPath = Save-OrchestraSessionState -ProjectDir $projectDir -SessionName $sessionName -Settings $settings -GitWorktreeDir $gitWorktreeDir -PaneSummaries $validPaneSummaries
    $commanderPollScriptPath = Join-Path $scriptDir 'commander-poll.ps1'
    $commanderPollProcess = Start-CommanderPollJob -CommanderPollScriptPath $commanderPollScriptPath -ManifestPath $manifestPath -Interval 20
    Write-WinsmuxLog -Level INFO -Event 'preflight.commander_poll.started' -Message "Started commander poll for session $sessionName." -Data @{ session_name = $sessionName; manifest_path = $manifestPath; commander_poll_pid = $commanderPollProcess.Id; process_name = $commanderPollProcess.ProcessName } | Out-Null
    $watchdogScriptPath = Join-Path $scriptDir 'agent-watchdog.ps1'
    $watchdogProcess = Start-AgentWatchdogJob -WatchdogScriptPath $watchdogScriptPath -ManifestPath $manifestPath -SessionName $sessionName
    $serverWatchdogScriptPath = Join-Path $scriptDir 'server-watchdog.ps1'
    $serverWatchdogProcess = Start-ServerWatchdogJob -WatchdogScriptPath $serverWatchdogScriptPath -ManifestPath $manifestPath -SessionName $sessionName
    $manifestPath = Save-OrchestraSessionState -ProjectDir $projectDir -SessionName $sessionName -Settings $settings -GitWorktreeDir $gitWorktreeDir -PaneSummaries $validPaneSummaries -CommanderPollPid $commanderPollProcess.Id -WatchdogPid $watchdogProcess.Id -ServerWatchdogPid $serverWatchdogProcess.Id
    Write-WinsmuxLog -Level INFO -Event 'preflight.watchdog.started' -Message "Started agent watchdog for session $sessionName." -Data @{ session_name = $sessionName; manifest_path = $manifestPath; watchdog_pid = $watchdogProcess.Id; process_name = $watchdogProcess.ProcessName } | Out-Null
    Write-WinsmuxLog -Level INFO -Event 'preflight.server_watchdog.started' -Message "Started server watchdog for session $sessionName." -Data @{ session_name = $sessionName; manifest_path = $manifestPath; server_watchdog_pid = $serverWatchdogProcess.Id; process_name = $serverWatchdogProcess.ProcessName } | Out-Null

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

    $builderPaneSummaries = @($paneSummaries | Where-Object { $_.Role -eq 'Builder' -and -not [string]::IsNullOrWhiteSpace($_.BuilderWorktreePath) })
    if ($builderPaneSummaries.Count -gt 0) {
        Write-Output ''
        Write-Output 'Cleanup: remove Builder worktrees after the session ends.'
        foreach ($paneSummary in $builderPaneSummaries) {
            $relativeWorktree = [System.IO.Path]::GetRelativePath($projectDir, $paneSummary.BuilderWorktreePath)
            Write-Output ("  git -C {0} worktree remove {1} ; git -C {0} branch -D {2}" -f $projectDir, $relativeWorktree, $paneSummary.BuilderBranch)
        }
    }

    Write-Output ''
    Write-Output "Manifest: $manifestPath"
    Write-Output "Commander Poll PID: $($commanderPollProcess.Id)"
    Write-Output "Watchdog PID: $($watchdogProcess.Id)"
    Write-Output "Server Watchdog PID: $($serverWatchdogProcess.Id)"
    Write-Output 'Cleanup: stop the commander poll and watchdogs after the session ends.'
    Write-Output ("  Stop-Process -Id {0}" -f $commanderPollProcess.Id)
    Write-Output ("  Stop-Process -Id {0},{1}" -f $watchdogProcess.Id, $serverWatchdogProcess.Id)
} catch {
    if ($null -ne $commanderPollProcess) {
        try { Stop-Process -Id $commanderPollProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($null -ne $watchdogProcess) {
        try { Stop-Process -Id $watchdogProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($null -ne $serverWatchdogProcess) {
        try { Stop-Process -Id $serverWatchdogProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
    }

    $rollback = Invoke-OrchestraStartupRollback -ProjectDir $projectDir -SessionName $sessionName -BootstrapPaneId $bootstrapPaneId -CreatedPaneIds $createdPaneIds -CreatedWorktrees $createdWorktrees -FailureMessage $_.Exception.Message
    $rollbackSuffix = if ($rollback.BootstrapRespawned) { 'session preserved' } else { 'rollback attempted' }
    Write-Error "Orchestra startup failed ($rollbackSuffix): $($_.Exception.Message)"
    exit 1
} finally {
    # Release startup lock (TASK-117)
    $lockProjectDir = if ([string]::IsNullOrWhiteSpace($projectDir)) { (Get-Location).Path } else { $projectDir }
    $lockFile = Join-Path $lockProjectDir '.winsmux' 'orchestra.lock'
    if (Test-Path $lockFile) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue }
}
}
