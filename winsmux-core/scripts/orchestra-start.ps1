$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
. "$scriptDir/settings.ps1"
. "$scriptDir/vault.ps1"
. "$scriptDir/builder-worktree.ps1"
. "$scriptDir/logger.ps1"
. "$scriptDir/agent-readiness.ps1"
. "$scriptDir/orchestra-preflight.ps1"
. "$scriptDir/manifest.ps1"
. "$scriptDir/pane-env.ps1"
. "$scriptDir/orchestra-ui-attach.ps1"

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

    Write-WinsmuxTextFile -Path $Path -Content $Content -Append:$Append
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

function ConvertTo-CmdArgumentLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return '""'
    }

    if ($Value -notmatch '[\s"&<>|^]') {
        return $Value
    }

    return '"' + ($Value -replace '"', '""') + '"'
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
            Attempted = $true
            Launched  = $true
            Attached  = $false
            Status    = if ($attachStillRunning) { $LaunchedStatus } else { 'attach_exited_early' }
            Reason    = if ($attachStillRunning) { $LaunchedReason } else { $FallbackReason }
            Path      = $Path
        }
    } catch {
        return [PSCustomObject][ordered]@{
            Attempted = $true
            Launched  = $false
            Attached  = $false
            Status    = 'attach_failed'
            Reason    = $_.Exception.Message
            Path      = $Path
        }
    }
}

function Try-StartOrchestraUiAttach {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [int]$Width = 200,
        [int]$Height = 70
    )
    return Invoke-OrchestraVisibleAttachRequest -SessionName $SessionName -ProjectDir $projectDir -WinsmuxPathForAttach ([string]$script:winsmuxBin)
}

function Ensure-OrchestraBootstrapSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionName,
        [int]$TimeoutSeconds = 60,
        [int]$ExpectedPaneCount = 1
    )

    if (Test-OrchestraServerSession -SessionName $SessionName) {
        return [PSCustomObject][ordered]@{
            SessionName    = $SessionName
            BootstrapReady = $false
            StartupReady   = $false
            BootstrapMode  = 'existing'
            UiAttached     = $false
            UiAttachStatus = 'existing_session'
        }
    }

    Invoke-Winsmux -Arguments @('new-session', '-d', '-s', $SessionName)
    $readiness = Wait-OrchestraBootstrapReadiness -SessionName $SessionName -TimeoutSeconds $TimeoutSeconds -ExpectedPaneCount $ExpectedPaneCount
    if ($readiness.Ready) {
        return [PSCustomObject][ordered]@{
            SessionName    = $SessionName
            BootstrapReady = $true
            StartupReady   = $false
            BootstrapMode  = 'detached_primary'
            UiAttached     = $false
            UiAttachStatus = 'not_requested'
        }
    }

    throw "Orchestra session '$SessionName' did not reach bootstrap readiness within $TimeoutSeconds seconds after detached startup."
}

function Wait-OrchestraBootstrapReadiness {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [int]$TimeoutSeconds = 60,
        [int]$ExpectedPaneCount = 1
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $pollAttempt = 0
    while ((Get-Date) -lt $deadline) {
        $pollAttempt++
        $hasSession = Test-OrchestraServerSession -SessionName $SessionName
        if ($hasSession) {
            try {
                $paneCount = Get-OrchestraSessionPaneCount -SessionName $SessionName -WinsmuxBin $script:winsmuxBin
                if ($paneCount -eq $ExpectedPaneCount) {
                    Write-Host "Ensure-OrchestraBootstrapSession: bootstrap session available after $pollAttempt polls"
                    return [ordered]@{
                        Ready       = $true
                        PollAttempt = $pollAttempt
                    }
                }
            } catch {
                Write-Warning "Ensure-OrchestraBootstrapSession: poll $pollAttempt pane-count error: $($_.Exception.Message)"
            }
        } else {
            if ($pollAttempt -le 5 -or $pollAttempt % 10 -eq 0) {
                Write-Warning "Ensure-OrchestraBootstrapSession: poll $pollAttempt has-session=false"
            }
        }
        Start-Sleep -Milliseconds 500
    }

    return [ordered]@{
        Ready       = $false
        PollAttempt = $pollAttempt
    }
}

function Reset-OrchestraServerSession {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$WinsmuxBin,
        [AllowNull()][string]$ProjectDir = $null,
        [AllowNull()][string]$GitWorktreeDir = $null,
        [AllowNull()][string]$BridgeScript = $null,
        [string]$Reason = 'reset',
        [int]$ExpectedPaneCount = 1
    )

    if (Test-OrchestraServerSession -SessionName $SessionName) {
        try {
            Invoke-Winsmux -Arguments @('kill-session', '-t', $SessionName)
            Wait-OrchestraServerSessionAbsent -SessionName $SessionName -TimeoutSeconds 20 | Out-Null
        } catch {
            throw "Reset-OrchestraServerSession: failed to fully reset $SessionName during ${Reason}: $($_.Exception.Message)"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ProjectDir) -and -not [string]::IsNullOrWhiteSpace($GitWorktreeDir) -and -not [string]::IsNullOrWhiteSpace($BridgeScript)) {
        $cleanup = Stop-OrchestraBackgroundProcessesFromManifest -ProjectDir $ProjectDir -GitWorktreeDir $GitWorktreeDir -BridgeScript $BridgeScript -SessionName $SessionName
        foreach ($cleanupError in @($cleanup.Errors)) {
            Write-Warning "Reset-OrchestraServerSession: stale orchestra background cleanup error: $cleanupError"
        }
    }

    Clear-OrchestraSessionRegistration -SessionName $SessionName
    if (-not [string]::IsNullOrWhiteSpace($ProjectDir)) {
        [void](Clear-WinsmuxManifest -ProjectDir $ProjectDir)
    }
    $server = Ensure-OrchestraBootstrapSession -SessionName $SessionName -TimeoutSeconds 60 -ExpectedPaneCount $ExpectedPaneCount
    $bootstrapMode = if ($null -ne $server.PSObject -and $server.PSObject.Properties.Name -contains 'BootstrapMode') {
        [string]$server.BootstrapMode
    } else {
        'windows_terminal'
    }
    $health = 'BootstrapOnly'
    if ($bootstrapMode -eq 'detached_fallback') {
        Write-Warning "Reset-OrchestraServerSession: detached bootstrap fallback used for $SessionName; skipping strict health wait and continuing to layout startup."
    } else {
        Write-Warning "Reset-OrchestraServerSession: bootstrap mode $bootstrapMode used for $SessionName; skipping strict pre-layout health wait and continuing to layout startup."
    }

    return [PSCustomObject][ordered]@{
        SessionName    = $server.SessionName
        BootstrapReady = $server.BootstrapReady
        StartupReady   = $false
        BootstrapMode  = $bootstrapMode
        Health         = $health
    }
}

function Wait-OrchestraServerSessionAbsent {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $pollAttempt = 0
    while ((Get-Date) -lt $deadline) {
        $pollAttempt++
        if (-not (Test-OrchestraServerSession -SessionName $SessionName)) {
            return [ordered]@{
                Ready       = $true
                PollAttempt = $pollAttempt
            }
        }

        if ($pollAttempt -le 5 -or $pollAttempt % 10 -eq 0) {
            Write-Warning "Wait-OrchestraServerSessionAbsent: poll $pollAttempt still sees session $SessionName"
        }

        Start-Sleep -Milliseconds 500
    }

    throw "Timed out waiting for session '$SessionName' to disappear after kill-session."
}

function Get-OrchestraStartupLockPath {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return Join-Path (Join-Path $ProjectDir '.winsmux') 'orchestra.lock'
}

function Acquire-OrchestraStartupLock {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    $lockFile = Get-OrchestraStartupLockPath -ProjectDir $ProjectDir
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
            # stale/corrupt lock; overwrite below
        }
    }

    $lockDir = Split-Path $lockFile -Parent
    if (-not (Test-Path $lockDir)) {
        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
    }

    $startupToken = [guid]::NewGuid().ToString('N')
    Write-OrchestraTextFile -Path $lockFile -Content ([ordered]@{
            pid           = $PID
            started_at    = (Get-Date).ToString('o')
            session_name  = $SessionName
            startup_token = $startupToken
        } | ConvertTo-Json)

    return [ordered]@{
        LockPath     = $lockFile
        StartupToken = $startupToken
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
        '^(?i)worker(?:$|[-_:/\s])' { return 'Worker' }
        '^(?i)builder(?:$|[-_:/\s])' { return 'Builder' }
        '^(?i)researcher(?:$|[-_:/\s])' { return 'Researcher' }
        '^(?i)reviewer(?:$|[-_:/\s])' { return 'Reviewer' }
        '^(?i)commander(?:$|[-_:/\s])' { return 'Commander' }
        default { throw "Unsupported pane role label: $AssignmentRole" }
    }
}

function Get-OrchestraLayoutSettings {
    param([Parameter(Mandatory = $true)]$Settings)

    $commanders = [int]$Settings.commanders
    $workers = [int]$Settings.worker_count
    $agentSlots = @()
    if ($Settings -is [System.Collections.IDictionary]) {
        if ($Settings.Contains('agent_slots')) {
            $agentSlots = @($Settings.agent_slots)
        }
    } elseif ($null -ne $Settings -and $null -ne $Settings.PSObject -and ($Settings.PSObject.Properties.Name -contains 'agent_slots')) {
        $agentSlots = @($Settings.agent_slots)
    }
    $builders = [int]$Settings.builders
    $researchers = [int]$Settings.researchers
    $reviewers = [int]$Settings.reviewers
    $externalCommander = [bool]$Settings.external_commander
    $legacyRoleLayout = [bool]$Settings.legacy_role_layout

    $legacyCount = $commanders + $builders + $researchers + $reviewers
    $useLegacyLayout = $legacyRoleLayout

    if ($legacyCount -gt 0 -and -not $useLegacyLayout) {
        throw 'Legacy role counts require legacy_role_layout=true. Set legacy_role_layout explicitly to opt into Commander/Builder/Researcher/Reviewer panes.'
    }

    if (-not $useLegacyLayout -and $agentSlots.Count -gt 0) {
        foreach ($slot in $agentSlots) {
            $slotId = ''
            $slotRole = ''
            $slotAgent = ''
            $slotModel = ''
            $slotWorktreeMode = ''

            if ($slot -is [System.Collections.IDictionary]) {
                if ($slot.Contains('slot_id')) {
                    $slotId = [string]$slot['slot_id']
                }
                if ($slot.Contains('runtime_role')) {
                    $slotRole = [string]$slot['runtime_role']
                }
                if ($slot.Contains('agent')) {
                    $slotAgent = [string]$slot['agent']
                }
                if ($slot.Contains('model')) {
                    $slotModel = [string]$slot['model']
                }
                if ($slot.Contains('worktree_mode')) {
                    $slotWorktreeMode = [string]$slot['worktree_mode']
                }
            } elseif ($null -ne $slot -and $null -ne $slot.PSObject) {
                if ($slot.PSObject.Properties.Name -contains 'slot_id') {
                    $slotId = [string]$slot.slot_id
                }
                if ($slot.PSObject.Properties.Name -contains 'runtime_role') {
                    $slotRole = [string]$slot.runtime_role
                }
                if ($slot.PSObject.Properties.Name -contains 'agent') {
                    $slotAgent = [string]$slot.agent
                }
                if ($slot.PSObject.Properties.Name -contains 'model') {
                    $slotModel = [string]$slot.model
                }
                if ($slot.PSObject.Properties.Name -contains 'worktree_mode') {
                    $slotWorktreeMode = [string]$slot.worktree_mode
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($slotRole) -and $slotRole -ne 'worker') {
                throw "agent_slots runtime_role overrides are not supported yet at runtime (slot '$slotId' requested '$slotRole')."
            }

            if (-not [string]::IsNullOrWhiteSpace($slotWorktreeMode) -and $slotWorktreeMode -ne 'managed') {
                throw "agent_slots worktree_mode overrides are not supported yet at runtime (slot '$slotId' requested '$slotWorktreeMode')."
            }

        }
    }

    if ($useLegacyLayout) {
        return [ordered]@{
            ExternalCommander = $false
            LegacyRoleLayout  = $true
            Commanders        = $commanders
            Workers           = 0
            Builders          = $builders
            Researchers       = $researchers
            Reviewers         = $reviewers
        }
    }

    $managedCommanders = if ($externalCommander) { 0 } else { 1 }
    if ($agentSlots.Count -gt 0) {
        $workers = $agentSlots.Count
    }
    if ($workers -lt 1) {
        throw "worker_count must be 1 or greater in external commander mode (got $workers)."
    }

    return [ordered]@{
        ExternalCommander = $externalCommander
        LegacyRoleLayout  = $false
        Commanders        = $managedCommanders
        Workers           = $workers
        Builders          = 0
        Researchers       = 0
        Reviewers         = 0
    }
}

function Get-OrchestraExpectedPaneCount {
    param([Parameter(Mandatory = $true)]$LayoutSettings)

    return [int]$LayoutSettings.Commanders +
        [int]$LayoutSettings.Workers +
        [int]$LayoutSettings.Builders +
        [int]$LayoutSettings.Researchers +
        [int]$LayoutSettings.Reviewers
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

function New-OrchestraPaneBootstrapPlan {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$StartupToken,
        [Parameter(Mandatory = $true)][string]$LaunchDir,
        [Parameter(Mandatory = $true)]$CleanPtyEnv,
        [Parameter(Mandatory = $true)][string]$LaunchCommand
    )

    $bootstrapDir = Join-Path (Join-Path $ProjectDir '.winsmux') 'orchestra-bootstrap'
    if (-not (Test-Path -LiteralPath $bootstrapDir)) {
        New-Item -ItemType Directory -Path $bootstrapDir -Force | Out-Null
    }

    $safePaneId = (($PaneId -replace '[^a-zA-Z0-9_-]', '_').Trim('_'))
    if ([string]::IsNullOrWhiteSpace($safePaneId)) {
        $safePaneId = 'pane'
    }

    $planPath = Join-Path $bootstrapDir ("{0}.json" -f $safePaneId)
    $readyMarkerPath = Join-Path $bootstrapDir ("{0}-{1}.ready.json" -f $safePaneId, $StartupToken)
    $plan = [ordered]@{
        pane_id        = $PaneId
        label          = $Label
        role           = $Role
        agent          = $Agent
        model          = $Model
        startup_token  = $StartupToken
        launch_dir     = $LaunchDir
        launch_command = $LaunchCommand
        ready_marker_path = $readyMarkerPath
        environment    = $CleanPtyEnv.Environment
    }

    $planJson = ($plan | ConvertTo-Json -Depth 8)
    Write-WinsmuxTextFile -Path $planPath -Content $planJson
    return $planPath
}

function Start-OrchestraPaneBootstrap {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$PlanPath
    )

    $bootstrapScriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'orchestra-pane-bootstrap.ps1'))
    Wait-PaneShellReady -PaneId $PaneId
    Invoke-Bridge -Arguments @('keys', $PaneId, 'C-c') -AllowFailure | Out-Null
    Start-Sleep -Milliseconds 200
    Send-OrchestraBridgeCommand -Target $PaneId -Text ("pwsh -NoProfile -File {0} -PlanFile {1}" -f (ConvertTo-PowerShellLiteral -Value $bootstrapScriptPath), (ConvertTo-PowerShellLiteral -Value $PlanPath))
    Start-Sleep -Milliseconds 500
}

function Get-OrchestraPaneBootstrapMarkerPath {
    param(
        [Parameter(Mandatory = $true)][string]$PlanPath,
        [Parameter(Mandatory = $true)][string]$StartupToken
    )

    $planDirectory = Split-Path -Parent $PlanPath
    $planBaseName = [System.IO.Path]::GetFileNameWithoutExtension($PlanPath)
    return Join-Path $planDirectory ("{0}-{1}.ready.json" -f $planBaseName, $StartupToken)
}

function Get-AgentLaunchCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [string]$RootPath,
        [bool]$ExecMode = $false
    )

    return Get-BridgeProviderLaunchCommand `
        -ProviderId $Agent `
        -Model $Model `
        -ProjectDir $ProjectDir `
        -GitWorktreeDir $GitWorktreeDir `
        -RootPath $RootPath `
        -ExecMode $ExecMode
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
        [int]$TimeoutSeconds = 30
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
        [AllowEmptyString()][string]$StartupToken = '',
        [Nullable[int]]$CommanderPollPid = $null,
        [Nullable[int]]$WatchdogPid = $null,
        [Nullable[int]]$ServerWatchdogPid = $null,
        [AllowEmptyString()][string]$BootstrapMode = '',
        [bool]$SessionReady = $false,
        [bool]$UiAttachLaunched = $false,
        [bool]$UiAttached = $false,
        [AllowEmptyString()][string]$UiAttachStatus = '',
        [AllowEmptyString()][string]$UiAttachReason = '',
        [AllowEmptyString()][string]$UiAttachSource = 'none',
        [AllowEmptyString()][string]$UiHostKind = '',
        [AllowEmptyString()][string]$AttachRequestId = '',
        [AllowEmptyCollection()]$AttachAdapterTrace = @()
    )

    $manifestPath = Get-OrchestraManifestPath -ProjectDir $ProjectDir
    $paneMap = [ordered]@{}
    foreach ($paneSummary in @($PaneSummaries)) {
        $paneEntry = [PSCustomObject]@{
            pane_id               = $paneSummary.PaneId
            role                  = $paneSummary.Role
            exec_mode             = [bool]$paneSummary.ExecMode
            launch_dir            = $paneSummary.LaunchDir
            builder_branch        = $paneSummary.BuilderBranch
            builder_worktree_path = $paneSummary.BuilderWorktreePath
            task                  = $null
            status                = if ($paneSummary.Status) { $paneSummary.Status } else { 'ready' }
        }
        if ($paneSummary.Contains('BootstrapFailures') -and $paneSummary['BootstrapFailures']) {
            $paneEntry | Add-Member -NotePropertyName 'bootstrap_failures' -NotePropertyValue $paneSummary['BootstrapFailures']
        }
        $paneMap[[string]$paneSummary.Label] = $paneEntry
    }

    $manifest = [PSCustomObject]@{
        version  = 1
        saved_at = (Get-Date -Format o)
        session  = [PSCustomObject]@{
            name                = $SessionName
            status              = 'running'
            agent               = $Settings.agent
            model               = $Settings.model
            project_dir         = $ProjectDir
            git_worktree_dir    = $GitWorktreeDir
            startup_token       = $StartupToken
            commander_poll_pid  = $CommanderPollPid
            watchdog_pid        = $WatchdogPid
            server_watchdog_pid = $ServerWatchdogPid
            bootstrap_mode      = $BootstrapMode
            session_ready       = $SessionReady
            ui_attach_launched  = $UiAttachLaunched
            ui_attached         = $UiAttached
            ui_attach_status    = $UiAttachStatus
            ui_attach_reason    = $UiAttachReason
            ui_attach_source    = $UiAttachSource
            ui_host_kind        = $UiHostKind
            attach_request_id   = $AttachRequestId
            attach_adapter_trace = @(ConvertTo-OrchestraAttachTracePersistedEntries -TraceEntries @($AttachAdapterTrace))
        }
        panes     = $paneMap
        tasks     = [PSCustomObject]@{
            queued      = @()
            in_progress = @()
            completed   = @()
        }
        worktrees = [ordered]@{}
    }

    Save-WinsmuxManifest -ProjectDir $ProjectDir -Manifest $manifest
    return $manifestPath
}

function Stop-OrchestraBackgroundProcessesFromManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [Parameter(Mandatory = $true)][string]$BridgeScript,
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    $stopped = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $manifest = Get-WinsmuxManifest -ProjectDir $ProjectDir
    if ($null -eq $manifest -or $null -eq $manifest.session) {
        return [ordered]@{
            Stopped = @()
            Errors  = @()
        }
    }

    $startupToken = ''
    if ($manifest.session -is [System.Collections.IDictionary]) {
        if ($manifest.session.Contains('startup_token')) {
            $startupToken = [string]$manifest.session['startup_token']
        }
    } elseif ($null -ne $manifest.session.PSObject -and $manifest.session.PSObject.Properties.Name -contains 'startup_token') {
        $startupToken = [string]$manifest.session.startup_token
    }

    if ([string]::IsNullOrWhiteSpace($startupToken)) {
        $errors.Add('manifest does not contain startup_token; skipping targeted background cleanup') | Out-Null
        return [ordered]@{
            Stopped = @()
            Errors  = @($errors)
        }
    }

    $pidMap = [ordered]@{}
    foreach ($propertyName in @('commander_poll_pid', 'watchdog_pid', 'server_watchdog_pid')) {
        $rawPid = $null
        if ($manifest.session -is [System.Collections.IDictionary]) {
            if ($manifest.session.Contains($propertyName)) {
                $rawPid = $manifest.session[$propertyName]
            }
        } elseif ($null -ne $manifest.session.PSObject -and $manifest.session.PSObject.Properties.Name -contains $propertyName) {
            $rawPid = $manifest.session.$propertyName
        }

        $resolvedPid = 0
        if ($null -eq $rawPid -or -not [int]::TryParse(([string]$rawPid), [ref]$resolvedPid) -or $resolvedPid -lt 1) {
            continue
        }

        $resolvedPidKey = [string]$resolvedPid
        if (-not $pidMap.Contains($resolvedPidKey)) {
            $pidMap[$resolvedPidKey] = $propertyName
        }
    }

    $manifestPath = Get-OrchestraManifestPath -ProjectDir $ProjectDir
    $snapshot = Get-ProcessSnapshot
    foreach ($entry in $pidMap.GetEnumerator()) {
        $processId = [int]$entry.Key
        $label = [string]$entry.Value
        try {
            if (-not $snapshot.ById.ContainsKey($processId)) {
                continue
            }

            $process = $snapshot.ById[$processId]
            $commandLine = [string]$process.CommandLine
            $requiredScript = switch ($label) {
                'commander_poll_pid' { 'commander-poll.ps1' }
                'watchdog_pid' { 'agent-watchdog.ps1' }
                'server_watchdog_pid' { 'server-watchdog.ps1' }
                default { '' }
            }
            $matchesExactMarkers = -not [string]::IsNullOrWhiteSpace($commandLine)
            foreach ($marker in @($requiredScript, $manifestPath, $SessionName, $startupToken) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
                if ($commandLine.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    $matchesExactMarkers = $false
                    break
                }
            }

            if (-not $matchesExactMarkers -or -not (Test-OrchestraZombieProcessMatch -Process $process -ProjectDir $ProjectDir -GitWorktreeDir $GitWorktreeDir -BridgeScript $BridgeScript -SessionName $SessionName)) {
                $errors.Add("${label}(${processId}): process no longer matches the recorded orchestra background command line") | Out-Null
                continue
            }

            Stop-Process -Id $processId -Force -ErrorAction Stop
            $stopped.Add([ordered]@{
                pid   = $processId
                label = $label
            }) | Out-Null
        } catch {
            $errors.Add("${label}(${processId}): $($_.Exception.Message)") | Out-Null
        }
    }

    return [ordered]@{
        Stopped = @($stopped)
        Errors  = @($errors)
    }
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
        [AllowEmptyString()][string]$StartupToken = '',
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
            '-StartupToken',
            $StartupToken,
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
        [AllowEmptyString()][string]$StartupToken = '',
        [int]$Interval = 20
    )

    return (Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile',
            '-File',
            $CommanderPollScriptPath,
            '-ManifestPath',
            $ManifestPath,
            '-StartupToken',
            $StartupToken,
            '-Interval',
            $Interval
        ) -WindowStyle Hidden -PassThru)
}

function Start-ServerWatchdogJob {
    param(
        [Parameter(Mandatory = $true)][string]$WatchdogScriptPath,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [AllowEmptyString()][string]$StartupToken = '',
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
            '-StartupToken',
            $StartupToken,
            '-PollInterval',
            $PollInterval,
            '-MaxRestartAttempts',
            $MaxRestartAttempts,
            '-RestartWindowMinutes',
            $RestartWindowMinutes
        ) -WindowStyle Hidden -PassThru)
}

function Assert-OrchestraBackgroundProcessStarted {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$StartupDelayMilliseconds = 300
    )

    if ($null -eq $Process) {
        throw "$Name did not start."
    }

    Start-Sleep -Milliseconds $StartupDelayMilliseconds
    try {
        if ($Process.HasExited) {
            $exitCode = 'unknown'
            try {
                $exitCode = [string]$Process.ExitCode
            } catch {
            }
            throw "$Name exited immediately (exit code $exitCode)."
        }
    } catch {
        if ($_.Exception.Message -like '*exited immediately*') {
            throw
        }
    }
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

function Assert-OrchestraSessionPaneCount {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][int]$ExpectedPaneCount,
        [Parameter(Mandatory = $true)][string]$StageName
    )

    $actualPaneCount = @(Get-OrchestraSessionPaneIds -SessionName $SessionName).Count
    if ($actualPaneCount -ne $ExpectedPaneCount) {
        throw "TASK-421: $StageName expected $ExpectedPaneCount pane(s) in session $SessionName but found $actualPaneCount."
    }
}

function Remove-OrchestraCreatedWorktrees {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][System.Collections.IEnumerable]$CreatedWorktrees
    )

    $removedWorktrees = [System.Collections.Generic.List[object]]::new()
    $cleanupErrors = [System.Collections.Generic.List[string]]::new()
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
                if ($LASTEXITCODE -ne 0) {
                    $cleanupErrors.Add("worktree remove $worktreePath failed with exit code $LASTEXITCODE.") | Out-Null
                }
            } catch {
                $cleanupErrors.Add("worktree remove $worktreePath failed: $($_.Exception.Message)") | Out-Null
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($branchName)) {
            try {
                & git -C $ProjectDir branch -D $branchName 2>$null | Out-Null
                $branchDeleteExitCode = $LASTEXITCODE
                if ($branchDeleteExitCode -ne 0) {
                    $cleanupErrors.Add("branch delete $branchName failed with exit code $branchDeleteExitCode.") | Out-Null
                }
            } catch {
                $cleanupErrors.Add("branch delete $branchName failed: $($_.Exception.Message)") | Out-Null
            }
        }

        $removedWorktrees.Add([ordered]@{
            BranchName   = $branchName
            WorktreePath = $worktreePath
        }) | Out-Null
    }

    return [ordered]@{
        RemovedWorktrees = @($removedWorktrees)
        Errors           = @($cleanupErrors)
    }
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
        try {
            [void](Clear-WinsmuxManifest -ProjectDir $ProjectDir)
        } catch {
            $rollbackErrors.Add("clear manifest failed: $($_.Exception.Message)") | Out-Null
        }
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
        $worktreeCleanup = Remove-OrchestraCreatedWorktrees -ProjectDir $ProjectDir -CreatedWorktrees $CreatedWorktrees
        $hasStructuredCleanup = $false
        $cleanupResultRemoved = @()
        $cleanupResultErrors = @()
        if ($worktreeCleanup -is [System.Collections.IDictionary]) {
            $hasStructuredCleanup = $worktreeCleanup.Contains('RemovedWorktrees')
            if ($hasStructuredCleanup) {
                $cleanupResultRemoved = @($worktreeCleanup['RemovedWorktrees'])
                $cleanupResultErrors = @($worktreeCleanup['Errors'])
            }
        } elseif (($null -ne $worktreeCleanup) -and ($null -ne $worktreeCleanup.PSObject) -and ($worktreeCleanup.PSObject.Properties.Name -contains 'RemovedWorktrees')) {
            $hasStructuredCleanup = $true
            $cleanupResultRemoved = @($worktreeCleanup.RemovedWorktrees)
            $cleanupResultErrors = @($worktreeCleanup.Errors)
        }

        if ($hasStructuredCleanup) {
            $removedWorktrees = @($cleanupResultRemoved)
            foreach ($cleanupError in @($cleanupResultErrors)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$cleanupError)) {
                    $rollbackErrors.Add([string]$cleanupError) | Out-Null
                }
            }
        } else {
            $removedWorktrees = @($worktreeCleanup)
        }
        $null = Write-OrchestraStartupFailureEvent -ProjectDir $ProjectDir -SessionName $SessionName -FailureMessage $FailureMessage -BootstrapPaneId $BootstrapPaneId -RemovedPaneIds @($removedPaneIds) -RemovedWorktrees $removedWorktrees -BootstrapRespawned $bootstrapRespawned -RollbackErrors @($rollbackErrors)
    }

    return [ordered]@{
        RemovedPaneIds    = @($removedPaneIds)
        RemovedWorktrees  = @($removedWorktrees)
        BootstrapRespawned = $bootstrapRespawned
        RollbackErrors    = @($rollbackErrors)
    }
}

function Assert-OrchestraBootstrapVerification {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$PaneSummaries,

        [Parameter(Mandatory = $true)]
        [int]$InvalidCount,

        [Parameter(Mandatory = $true)]
        [int]$ReadyCount
    )

    if ($ReadyCount -eq 0) {
        throw "TASK-240: no panes passed bootstrap verification. All $InvalidCount pane(s) are bootstrap_invalid."
    }

    if ($InvalidCount -gt 0) {
        throw "TASK-240: startup aborted because $InvalidCount pane(s) are bootstrap_invalid and only $ReadyCount of $($PaneSummaries.Count) expected pane(s) are ready."
    }
}

function Test-PaneCaptureContainsLaunchDir {
    param(
        [AllowNull()][string]$CaptureText,
        [Parameter(Mandatory = $true)][string]$ExpectedLaunchDir
    )

    if ([string]::IsNullOrWhiteSpace($CaptureText) -or [string]::IsNullOrWhiteSpace($ExpectedLaunchDir)) {
        return $false
    }

    $normalizedCapture = $CaptureText.Replace('/', '\').ToLowerInvariant()
    $normalizedExpected = $ExpectedLaunchDir.Replace('/', '\').ToLowerInvariant()
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add($normalizedExpected) | Out-Null

    $userProfile = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
        $normalizedUserProfile = $userProfile.Replace('/', '\').ToLowerInvariant()
        if ($normalizedExpected.StartsWith($normalizedUserProfile)) {
            $candidates.Add(("~" + $normalizedExpected.Substring($normalizedUserProfile.Length))) | Out-Null
        }
    }

    $worktreeMarker = '\.worktrees\'
    $worktreeIndex = $normalizedExpected.IndexOf($worktreeMarker, [System.StringComparison]::Ordinal)
    if ($worktreeIndex -ge 0) {
        $candidates.Add($normalizedExpected.Substring($worktreeIndex)) | Out-Null
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and $normalizedCapture.Contains($candidate)) {
            return $true
        }
    }

    return $false
}

function Test-OrchestraBootstrapMarker {
    param(
        [AllowNull()][string]$BootstrapMarkerPath,
        [Parameter(Mandatory = $true)][string]$ExpectedLaunchDir
    )

    if ([string]::IsNullOrWhiteSpace($BootstrapMarkerPath) -or -not (Test-Path -LiteralPath $BootstrapMarkerPath)) {
        return $false
    }

    try {
        $marker = Get-Content -LiteralPath $BootstrapMarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 6
        $normalizedExpected = $ExpectedLaunchDir.Replace('/', '\').ToLowerInvariant()
        foreach ($candidate in @([string]$marker.launch_dir, [string]$marker.current_dir)) {
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                if ($candidate.Replace('/', '\').ToLowerInvariant() -eq $normalizedExpected) {
                    return $true
                }
            }
        }
    } catch {
    }

    return $false
}

function Test-PaneBootstrapInvariants {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$ExpectedRole,
        [Parameter(Mandatory = $true)][string]$ExpectedLaunchDir,
        [string]$ExpectedWorktreePath = '',
        [string]$BootstrapMarkerPath = ''
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    # Check pane is alive
    try {
        Invoke-Winsmux -Arguments @('display-message', '-t', $PaneId, '-p', '#{pane_id}') -CaptureOutput | Out-Null
    } catch {
        $failures.Add("pane $PaneId does not exist")
        return $failures
    }

    # Check cwd by sending pwd and reading capture-pane
    try {
        $cwdOutput = Invoke-Winsmux -Arguments @('display-message', '-t', $PaneId, '-p', '#{pane_current_path}') -CaptureOutput
        $actualCwd = ([string]$cwdOutput).Trim().Replace('\', '/')
        $expectedCwd = $ExpectedLaunchDir.Replace('\', '/')
        if ($actualCwd -and $expectedCwd -and ($actualCwd.ToLowerInvariant() -ne $expectedCwd.ToLowerInvariant())) {
            if (-not (Test-OrchestraBootstrapMarker -BootstrapMarkerPath $BootstrapMarkerPath -ExpectedLaunchDir $ExpectedLaunchDir)) {
                $snapshot = Invoke-Winsmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') -CaptureOutput
                $snapshotText = ($snapshot | Out-String).TrimEnd()
                if (-not (Test-PaneCaptureContainsLaunchDir -CaptureText $snapshotText -ExpectedLaunchDir $ExpectedLaunchDir)) {
                    $failures.Add("cwd mismatch: expected=$ExpectedLaunchDir actual=$actualCwd")
                }
            }
        }
    } catch {
        $failures.Add("could not read pane cwd: $($_.Exception.Message)")
    }

    if (-not [string]::IsNullOrWhiteSpace($BootstrapMarkerPath) -and -not (Test-Path -LiteralPath $BootstrapMarkerPath)) {
        $failures.Add("bootstrap marker missing: $BootstrapMarkerPath")
    }

    return $failures
}

if ($MyInvocation.InvocationName -ne '.') {
    $commanderPollProcess = $null
    $watchdogProcess = $null
    $serverWatchdogProcess = $null
    $projectDir = $null
    $gitWorktreeDir = $null
    $startupToken = ''
    $orchestraServer = $null
    $createdPaneIds = @()
    $bootstrapPaneId = $null
    $createdWorktrees = @()
    try {
        $script:winsmuxBin = Get-WinsmuxBin
        $winsmuxBin = $script:winsmuxBin
        if (-not $winsmuxBin) {
            Write-Error (Get-WinsmuxOperatorNotFoundMessage)
            exit 1
        }

        if (-not (Test-Path $bridgeScript)) {
            Write-Error "Bridge CLI not found: $bridgeScript"
            exit 1
        }

        $projectDir = Get-ProjectDir
        $settings = Get-BridgeSettings -RootPath $projectDir
        $layoutSettings = Get-OrchestraLayoutSettings -Settings $settings
        $bootstrapPaneCount = 1
        $expectedPaneCount = Get-OrchestraExpectedPaneCount -LayoutSettings $layoutSettings
        Initialize-WinsmuxLog -ProjectDir $projectDir -SessionName $sessionName | Out-Null
        Write-WinsmuxLog -Level INFO -Event 'preflight.settings.loaded' -Message 'Loaded orchestra settings.' -Data @{
            agent              = $settings.agent
            model              = $settings.model
            external_commander = $layoutSettings.ExternalCommander
            legacy_role_layout = $layoutSettings.LegacyRoleLayout
            workers            = $layoutSettings.Workers
            commanders         = $layoutSettings.Commanders
            builders           = $layoutSettings.Builders
            researchers        = $layoutSettings.Researchers
            reviewers          = $layoutSettings.Reviewers
        } | Out-Null
        Write-WinsmuxLog -Level INFO -Event 'preflight.winsmux_bin.ready' -Message "Using winsmux binary: $winsmuxBin." -Data @{ winsmux_bin = $winsmuxBin } | Out-Null
        Write-WinsmuxLog -Level INFO -Event 'preflight.bridge_script.ready' -Message "Using bridge script: $bridgeScript." -Data @{ bridge_script = $bridgeScript } | Out-Null
        Write-WinsmuxLog -Level INFO -Event 'preflight.project_dir.resolved' -Message "Resolved project directory: $projectDir." -Data @{ project_dir = $projectDir } | Out-Null
        $gitWorktreeDir = Get-GitWorktreeDir -ProjectDir $projectDir
        Write-WinsmuxLog -Level INFO -Event 'preflight.git_worktree.resolved' -Message "Resolved git worktree directory: $gitWorktreeDir." -Data @{ git_worktree_dir = $gitWorktreeDir } | Out-Null
        $startupLock = Acquire-OrchestraStartupLock -ProjectDir $projectDir -SessionName $sessionName
        $startupToken = [string]$startupLock.StartupToken
        Write-WinsmuxLog -Level INFO -Event 'preflight.startup_lock.acquired' -Message "Acquired orchestra startup lock for $sessionName." -Data @{ session_name = $sessionName; startup_token = $startupToken } | Out-Null
        $sessionExistedAtStart = Test-OrchestraServerSession -SessionName $sessionName
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

        if (-not $sessionExistedAtStart) {
            Write-WinsmuxLog -Level INFO -Event 'preflight.manifest_cleanup.start' -Message 'Stopping stale orchestra background processes and clearing stale manifest before fresh startup.' | Out-Null
            $manifestBackgroundCleanup = Stop-OrchestraBackgroundProcessesFromManifest -ProjectDir $projectDir -GitWorktreeDir $gitWorktreeDir -BridgeScript $bridgeScript -SessionName $sessionName
            foreach ($stoppedProcess in @($manifestBackgroundCleanup.Stopped)) {
                Write-WinsmuxLog -Level INFO -Event 'preflight.manifest_cleanup.process_stopped' -Message "Stopped stale orchestra background process $($stoppedProcess.label) ($($stoppedProcess.pid))." -Data ([ordered]@{
                    label = $stoppedProcess.label
                    pid   = $stoppedProcess.pid
                }) | Out-Null
            }
            foreach ($cleanupError in @($manifestBackgroundCleanup.Errors)) {
                Write-Warning "Preflight: stale orchestra background cleanup error: $cleanupError"
                Write-WinsmuxLog -Level WARN -Event 'preflight.manifest_cleanup.process_error' -Message "Stale orchestra background cleanup error: $cleanupError" -Data ([ordered]@{
                    error = $cleanupError
                }) | Out-Null
            }
            if (Clear-WinsmuxManifest -ProjectDir $projectDir) {
                Write-WinsmuxLog -Level INFO -Event 'preflight.manifest_cleanup.cleared' -Message "Cleared stale orchestra manifest for $projectDir." -Data ([ordered]@{
                    project_dir = $projectDir
                }) | Out-Null
            }
        }

        Write-WinsmuxLog -Level INFO -Event 'preflight.zombie_cleanup.start' -Message 'Removing orchestra zombie processes.' | Out-Null
        $zombieCleanup = Remove-OrchestraZombieProcesses -SessionName $sessionName -ProjectDir $projectDir -GitWorktreeDir $gitWorktreeDir -BridgeScript $bridgeScript -WinsmuxBin $winsmuxBin
        if (@($zombieCleanup.Killed).Count -gt 0) {
            Write-WinsmuxLog -Level INFO -Event 'preflight.git_worktree.prune_after_zombie_cleanup' -Message 'Pruning git worktree metadata after zombie cleanup.' -Data @{ killed_count = @($zombieCleanup.Killed).Count } | Out-Null
            Invoke-BuilderWorktreeGit -ProjectDir $projectDir -Arguments @('worktree', 'prune') | Out-Null
        }

        $orchestraServer = Ensure-OrchestraBootstrapSession -SessionName $sessionName -TimeoutSeconds 60
        Write-Warning ("Bootstrap ensure result type: " + $orchestraServer.GetType().FullName + " BootstrapReady=" + $orchestraServer.BootstrapReady + " Mode=" + $orchestraServer.BootstrapMode)

    # Clean up any leftover orchestra panes in default session (#213)
    try {
        $existingPanes = & $winsmuxBin list-panes -F '#{pane_id} #{pane_title}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $existingPanes) {
                    $orchestraLabels = @('worker-', 'builder-', 'researcher-', 'reviewer-')
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

    if (-not [bool]$orchestraServer.BootstrapReady) {
        Write-WinsmuxLog -Level INFO -Event 'preflight.session.check' -Message "Checking for existing session $sessionName." -Data @{ session_name = $sessionName } | Out-Null
        $sessionHealth = Test-OrchestraServerHealth -SessionName $sessionName -WinsmuxBin $winsmuxBin -ExpectedPaneCount $expectedPaneCount
        Write-WinsmuxLog -Level INFO -Event 'preflight.session.health' -Message "Session health for ${sessionName}: $sessionHealth." -Data @{ session_name = $sessionName; health = $sessionHealth } | Out-Null
        switch ($sessionHealth) {
            'Healthy' {
                Write-WinsmuxLog -Level INFO -Event 'preflight.session.reset' -Message "Resetting existing healthy session $sessionName before startup." -Data @{ session_name = $sessionName; health = $sessionHealth } | Out-Null
                $orchestraServer = Reset-OrchestraServerSession -SessionName $sessionName -WinsmuxBin $winsmuxBin -ProjectDir $projectDir -GitWorktreeDir $gitWorktreeDir -BridgeScript $bridgeScript -Reason 'healthy_existing_session' -ExpectedPaneCount $bootstrapPaneCount
            }
            'Unhealthy' {
                Write-Warning "Preflight: removing stale session registration for $sessionName"
                Write-WinsmuxLog -Level WARN -Event 'preflight.session.registration_cleared' -Message "Cleared stale session registration for $sessionName." -Data @{ session_name = $sessionName } | Out-Null
                $orchestraServer = Reset-OrchestraServerSession -SessionName $sessionName -WinsmuxBin $winsmuxBin -ProjectDir $projectDir -GitWorktreeDir $gitWorktreeDir -BridgeScript $bridgeScript -Reason 'unhealthy_existing_session' -ExpectedPaneCount $bootstrapPaneCount
            }
            default {
                Write-Warning "Preflight: session $sessionName is missing strict health metadata; recreating it"
                Write-WinsmuxLog -Level WARN -Event 'preflight.session.reset' -Message "Resetting session $sessionName after missing strict health metadata." -Data @{ session_name = $sessionName; health = $sessionHealth } | Out-Null
                $orchestraServer = Reset-OrchestraServerSession -SessionName $sessionName -WinsmuxBin $winsmuxBin -ProjectDir $projectDir -GitWorktreeDir $gitWorktreeDir -BridgeScript $bridgeScript -Reason 'missing_strict_health' -ExpectedPaneCount $bootstrapPaneCount
            }
        }
    } else {
        $bootstrapMode = if ($null -ne $orchestraServer.PSObject -and $orchestraServer.PSObject.Properties.Name -contains 'BootstrapMode') {
            [string]$orchestraServer.BootstrapMode
        } else {
            'windows_terminal'
        }
        if ($bootstrapMode -eq 'detached_fallback') {
            Write-Warning "Preflight: detached bootstrap fallback active for $sessionName; proceeding without strict pre-layout health metadata gate."
        } else {
            Write-Warning "Preflight: bootstrap mode $bootstrapMode active for $sessionName; proceeding without strict pre-layout health metadata gate."
        }
        Write-WinsmuxLog -Level INFO -Event 'preflight.session.reuse' -Message "Reusing server-created session $sessionName." -Data ([ordered]@{
            session_name    = $sessionName
            session_created = $true
            bootstrap_mode  = $bootstrapMode
        }) | Out-Null
    }

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

        Write-WinsmuxLog -Level INFO -Event 'preflight.bootstrap.ready' -Message "Bootstrap session $sessionName created by Ensure-OrchestraBootstrapSession." -Data ([ordered]@{
            session_name    = $sessionName
            session_created = [bool]$orchestraServer.BootstrapReady
            bootstrap_mode  = [string]$orchestraServer.BootstrapMode
            expected_panes  = $bootstrapPaneCount
        }) | Out-Null
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
                Write-Warning "DEBUG: layout start session=$sessionName external=$($layoutSettings.ExternalCommander) legacy=$($layoutSettings.LegacyRoleLayout) C=$($layoutSettings.Commanders) W=$($layoutSettings.Workers) B=$($layoutSettings.Builders) R=$($layoutSettings.Researchers) Rev=$($layoutSettings.Reviewers)"
                $layout = . $layoutScript -SessionName $sessionName -Commanders $layoutSettings.Commanders -Workers $layoutSettings.Workers -Builders $layoutSettings.Builders -Researchers $layoutSettings.Researchers -Reviewers $layoutSettings.Reviewers
                Write-Warning "DEBUG: layout done, panes=$($layout.Panes.Count)"
                foreach ($sessionPaneId in @(Get-OrchestraSessionPaneIds -SessionName $sessionName)) {
                    if ($createdPaneIds -notcontains $sessionPaneId) {
                        $createdPaneIds += $sessionPaneId
                    }
                }
                Assert-OrchestraSessionPaneCount -SessionName $sessionName -ExpectedPaneCount $layout.Panes.Count -StageName 'layout'
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
    $sessionRoleMapJson = ($sessionRoleMap | ConvertTo-Json -Compress)
    $environmentContract = Get-WinsmuxEnvironmentContract -ProjectDir $projectDir
    Set-OrchestraSessionEnvironment -SessionName $sessionName -Name 'WINSMUX_ORCHESTRA_SESSION' -Value $sessionName
    Set-OrchestraSessionEnvironment -SessionName $sessionName -Name 'WINSMUX_ORCHESTRA_PROJECT_DIR' -Value $projectDir
    Set-OrchestraSessionEnvironment -SessionName $sessionName -Name 'WINSMUX_ROLE_MAP' -Value $sessionRoleMapJson
    Set-OrchestraSessionEnvironment -SessionName $sessionName -Name 'WINSMUX_HOOK_PROFILE' -Value ([string]$environmentContract['hook_profile'])
    Set-OrchestraSessionEnvironment -SessionName $sessionName -Name 'WINSMUX_GOVERNANCE_MODE' -Value ([string]$environmentContract['governance_mode'])

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

        if ($canonicalRole -in @('Builder', 'Worker')) {
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

        $slotAgentConfig = Get-SlotAgentConfig -Role $canonicalRole -SlotId $label -Settings $settings -RootPath $projectDir
        $execMode = ([string]$slotAgentConfig.Agent).Trim().ToLowerInvariant() -eq 'codex'
        $launchCommand = Get-AgentLaunchCommand -Agent $slotAgentConfig.Agent -Model $slotAgentConfig.Model -ProjectDir $launchDir -GitWorktreeDir $launchGitWorktreeDir -RootPath $projectDir -ExecMode $false

        Invoke-Bridge -Arguments @('name', $paneId, $label)
        try {
            $paneEnvironment = Get-WinsmuxPaneEnvironment -Role $canonicalRole -PaneId $paneId -SessionName $sessionName -ProjectDir $projectDir -RoleMapJson $sessionRoleMapJson -BuilderWorktreePath $builderWorktreePath
            $cleanPtyEnv = Get-CleanPtyEnv -AllowedEnvironment $paneEnvironment
            foreach ($entry in $paneEnvironment.GetEnumerator()) {
                if ($entry.Key -in @('WINSMUX_ROLE', 'WINSMUX_PANE_ID')) {
                    Set-OrchestraSessionEnvironment -SessionName $sessionName -Name ([string]$entry.Key) -Value ([string]$entry.Value)
                }
            }
            Invoke-Winsmux -Arguments @('respawn-pane', '-k', '-t', $paneId, '-c', $launchDir)
            if ([string]::IsNullOrWhiteSpace($launchCommand)) {
                Write-Warning "TASK-231: empty launch command for pane $paneId ($label, role=$canonicalRole, execMode=$execMode). Agent will not start automatically."
            } else {
                $bootstrapPlanPath = New-OrchestraPaneBootstrapPlan `
                    -ProjectDir $projectDir `
                    -PaneId $paneId `
                    -Label $label `
                    -Role $canonicalRole `
                    -Agent ([string]$slotAgentConfig.Agent) `
                    -Model ([string]$slotAgentConfig.Model) `
                    -StartupToken $startupToken `
                    -LaunchDir $launchDir `
                    -CleanPtyEnv $cleanPtyEnv `
                    -LaunchCommand $launchCommand
                Start-OrchestraPaneBootstrap -PaneId $paneId -PlanPath $bootstrapPlanPath
                # TASK-231: verify pane exists after respawn
                try {
                    Invoke-Winsmux -Arguments @('display-message', '-t', $paneId, '-p', '#{pane_id}') -CaptureOutput | Out-Null
                } catch {
                    Write-Warning "TASK-231: pane $paneId ($label) not found after respawn-pane."
                }
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
            Agent = [string]$slotAgentConfig.Agent
            Model = [string]$slotAgentConfig.Model
            ExecMode = $false
            LaunchDir = $launchDir
            BuilderBranch = $builderBranch
            BuilderWorktreePath = $builderWorktreePath
            BootstrapMarkerPath = if ([string]::IsNullOrWhiteSpace($bootstrapPlanPath)) { '' } else { Get-OrchestraPaneBootstrapMarkerPath -PlanPath $bootstrapPlanPath -StartupToken $startupToken }
            Status = 'ready'
        })
    }

    foreach ($paneSummary in $paneSummaries) {
        try {
            Wait-AgentReady -PaneId $paneSummary.PaneId -Agent $paneSummary.Agent -TimeoutSeconds 60
        } catch {
            Write-Error "Agent readiness timeout for $($paneSummary.Label) [$($paneSummary.PaneId)]: $($_.Exception.Message)"
            exit 1
        }
    }

    # TASK-240: bootstrap verification — verify invariants and mark failures
    $validPaneSummaries = [System.Collections.Generic.List[object]]::new()
    $invalidCount = 0
    foreach ($paneSummary in $paneSummaries) {
        $failures = @(Test-PaneBootstrapInvariants `
            -PaneId $paneSummary.PaneId `
            -Label $paneSummary.Label `
            -ExpectedRole $paneSummary.Role `
            -ExpectedLaunchDir $paneSummary.LaunchDir `
            -ExpectedWorktreePath ([string]$paneSummary.BuilderWorktreePath) `
            -BootstrapMarkerPath ([string]$paneSummary.BootstrapMarkerPath))

        if ($failures.Count -gt 0) {
            $failureText = $failures -join '; '
            Write-Warning "TASK-240: pane $($paneSummary.PaneId) ($($paneSummary.Label)) bootstrap_invalid: $failureText"
            $invalidEntry = [ordered]@{}
            foreach ($key in $paneSummary.Keys) {
                $invalidEntry[$key] = $paneSummary[$key]
            }
            $invalidEntry['Status'] = 'bootstrap_invalid'
            $invalidEntry['BootstrapFailures'] = $failureText
            $validPaneSummaries.Add($invalidEntry)
            $invalidCount++
        } else {
            $validPaneSummaries.Add($paneSummary)
        }
    }
    $readyCount = $validPaneSummaries.Count - $invalidCount
    Assert-OrchestraBootstrapVerification -PaneSummaries @($paneSummaries) -InvalidCount $invalidCount -ReadyCount $readyCount

    $uiAttachResult = Try-StartOrchestraUiAttach -SessionName $sessionName
    $successfulAttachStatuses = @('attach_confirmed', 'attach_already_present')
    if ($successfulAttachStatuses -notcontains [string]$uiAttachResult.Status) {
        Write-Warning "Orchestra UI attach status for ${sessionName}: $($uiAttachResult.Status) ($($uiAttachResult.Reason))"
    }

    $manifestPath = Save-OrchestraSessionState -ProjectDir $projectDir -SessionName $sessionName -Settings $settings -GitWorktreeDir $gitWorktreeDir -PaneSummaries $validPaneSummaries -StartupToken $startupToken -BootstrapMode ([string]$orchestraServer.BootstrapMode) -SessionReady $false -UiAttachLaunched ([bool]$uiAttachResult.Launched) -UiAttached ([bool]$uiAttachResult.Attached) -UiAttachStatus ([string]$uiAttachResult.Status) -UiAttachReason ([string]$uiAttachResult.Reason) -UiAttachSource ([string]$uiAttachResult.Source) -UiHostKind ([string]$uiAttachResult.ui_host_kind) -AttachRequestId ([string]$uiAttachResult.attach_request_id) -AttachAdapterTrace @($uiAttachResult.attach_adapter_trace)
    $commanderPollScriptPath = Join-Path $scriptDir 'commander-poll.ps1'
    $commanderPollProcess = Start-CommanderPollJob -CommanderPollScriptPath $commanderPollScriptPath -ManifestPath $manifestPath -StartupToken $startupToken -Interval 20
    Write-WinsmuxLog -Level INFO -Event 'preflight.commander_poll.started' -Message "Started commander poll for session $sessionName." -Data @{ session_name = $sessionName; manifest_path = $manifestPath; commander_poll_pid = $commanderPollProcess.Id; process_name = $commanderPollProcess.ProcessName } | Out-Null
    $watchdogScriptPath = Join-Path $scriptDir 'agent-watchdog.ps1'
    $watchdogProcess = Start-AgentWatchdogJob -WatchdogScriptPath $watchdogScriptPath -ManifestPath $manifestPath -SessionName $sessionName -StartupToken $startupToken
    $serverWatchdogScriptPath = Join-Path $scriptDir 'server-watchdog.ps1'
    $serverWatchdogProcess = Start-ServerWatchdogJob -WatchdogScriptPath $serverWatchdogScriptPath -ManifestPath $manifestPath -SessionName $sessionName -StartupToken $startupToken
    Assert-OrchestraBackgroundProcessStarted -Process $commanderPollProcess -Name 'Commander poll job'
    Assert-OrchestraBackgroundProcessStarted -Process $watchdogProcess -Name 'Agent watchdog job'
    Assert-OrchestraBackgroundProcessStarted -Process $serverWatchdogProcess -Name 'Server watchdog job'
    $manifestPath = Save-OrchestraSessionState -ProjectDir $projectDir -SessionName $sessionName -Settings $settings -GitWorktreeDir $gitWorktreeDir -PaneSummaries $validPaneSummaries -StartupToken $startupToken -CommanderPollPid $commanderPollProcess.Id -WatchdogPid $watchdogProcess.Id -ServerWatchdogPid $serverWatchdogProcess.Id -BootstrapMode ([string]$orchestraServer.BootstrapMode) -SessionReady $true -UiAttachLaunched ([bool]$uiAttachResult.Launched) -UiAttached ([bool]$uiAttachResult.Attached) -UiAttachStatus ([string]$uiAttachResult.Status) -UiAttachReason ([string]$uiAttachResult.Reason) -UiAttachSource ([string]$uiAttachResult.Source) -UiHostKind ([string]$uiAttachResult.ui_host_kind) -AttachRequestId ([string]$uiAttachResult.attach_request_id) -AttachAdapterTrace @($uiAttachResult.attach_adapter_trace)
    Write-WinsmuxLog -Level INFO -Event 'preflight.watchdog.started' -Message "Started agent watchdog for session $sessionName." -Data @{ session_name = $sessionName; manifest_path = $manifestPath; watchdog_pid = $watchdogProcess.Id; process_name = $watchdogProcess.ProcessName } | Out-Null
    Write-WinsmuxLog -Level INFO -Event 'preflight.server_watchdog.started' -Message "Started server watchdog for session $sessionName." -Data @{ session_name = $sessionName; manifest_path = $manifestPath; server_watchdog_pid = $serverWatchdogProcess.Id; process_name = $serverWatchdogProcess.ProcessName } | Out-Null
    Write-WinsmuxLog -Level INFO -Event 'orchestra.startup.session_ready' -Message "Orchestra session $sessionName reached session-ready; UI attach remains a separate state." -Data ([ordered]@{
        session_name       = $sessionName
        expected_panes     = $expectedPaneCount
        actual_panes       = @($layout.Panes).Count
        bootstrap_verified = $true
        ui_attach_launched = [bool]$uiAttachResult.Launched
        ui_attach_status   = [string]$uiAttachResult.Status
        ui_attached        = [bool]$uiAttachResult.Attached
        ui_attach_source   = [string]$uiAttachResult.Source
    }) | Out-Null

    Write-Output "Orchestra session: $sessionName"
    $defaultAgent = ''
    $defaultModel = ''
    if ($settings -is [System.Collections.IDictionary]) {
        if ($settings.Contains('agent')) {
            $defaultAgent = [string]$settings['agent']
        }
        if ($settings.Contains('model')) {
            $defaultModel = [string]$settings['model']
        }
    } elseif ($null -ne $settings -and $null -ne $settings.PSObject) {
        if ($settings.PSObject.Properties.Name -contains 'agent') {
            $defaultAgent = [string]$settings.agent
        }
        if ($settings.PSObject.Properties.Name -contains 'model') {
            $defaultModel = [string]$settings.model
        }
    }
    Write-Output "Agent: $(if ([string]::IsNullOrWhiteSpace($defaultAgent)) { 'per-slot / override only' } else { $defaultAgent })"
    Write-Output "Model: $(if ([string]::IsNullOrWhiteSpace($defaultModel)) { 'per-slot / override only' } else { $defaultModel })"
    if ($layoutSettings.LegacyRoleLayout) {
        Write-Output "Mode: legacy role layout"
    } elseif ($layoutSettings.ExternalCommander) {
        Write-Output "Mode: external commander + $($layoutSettings.Workers) workers"
    } else {
        Write-Output "Mode: managed commander + $($layoutSettings.Workers) workers"
    }
    Write-Output "ProjectDir: $projectDir"
    Write-Output "GitWorktreeDir: $gitWorktreeDir"
    Write-Output "SessionReady: true"
    Write-Output "UI Attach Launched: $([bool]$uiAttachResult.Launched)"
    Write-Output "UI Attach: $($uiAttachResult.Status)"
    Write-Output ''
    Write-Output 'Panes:'
    foreach ($paneSummary in $paneSummaries) {
        Write-Output ("  {0,-14} {1,-8} {2}" -f $paneSummary.Label, $paneSummary.PaneId, $paneSummary.Role)
    }

    $builderPaneSummaries = @($paneSummaries | Where-Object { $_.Role -in @('Builder', 'Worker') -and -not [string]::IsNullOrWhiteSpace($_.BuilderWorktreePath) })
    if ($builderPaneSummaries.Count -gt 0) {
        Write-Output ''
        Write-Output 'Cleanup: remove managed worktrees after the session ends.'
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
    Write-Warning "STARTUP ERROR: $($_.Exception.Message)"
    Write-Warning "AT: $($_.ScriptStackTrace)"
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
    $lockFile = Get-OrchestraStartupLockPath -ProjectDir $lockProjectDir
    if (Test-Path $lockFile) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue }
}
}
