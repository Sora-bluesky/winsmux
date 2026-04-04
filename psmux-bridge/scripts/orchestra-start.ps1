$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
. "$scriptDir/settings.ps1"
. "$scriptDir/vault.ps1"
. "$scriptDir/logger.ps1"

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
    $scriptProjectDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if (-not [string]::IsNullOrWhiteSpace($scriptProjectDir)) {
        return $scriptProjectDir
    }

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
        return (Get-Item -LiteralPath $dotGitPath -Force).FullName
    }

    return $ProjectDir
}

function Get-ProcessSnapshot {
    $processes = @(Get-CimInstance Win32_Process)
    $byId = @{}
    $childrenByParent = @{}

    foreach ($process in $processes) {
        $byId[[int]$process.ProcessId] = $process
        $parentId = [int]$process.ParentProcessId
        if (-not $childrenByParent.ContainsKey($parentId)) {
            $childrenByParent[$parentId] = [System.Collections.Generic.List[object]]::new()
        }

        $childrenByParent[$parentId].Add($process)
    }

    return [PSCustomObject]@{
        Processes        = $processes
        ById             = $byId
        ChildrenByParent = $childrenByParent
    }
}

function Get-AncestorProcessIds {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][int]$ProcessId
    )

    $ids = [System.Collections.Generic.HashSet[int]]::new()
    $currentId = $ProcessId

    while ($currentId -gt 0 -and $Snapshot.ById.ContainsKey($currentId)) {
        if (-not $ids.Add($currentId)) {
            break
        }

        $currentId = [int]$Snapshot.ById[$currentId].ParentProcessId
    }

    return $ids
}

function Get-DescendantProcessIds {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][int[]]$RootProcessIds
    )

    $ids = [System.Collections.Generic.HashSet[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()

    foreach ($rootId in $RootProcessIds) {
        if ($rootId -gt 0) {
            $queue.Enqueue($rootId)
        }
    }

    while ($queue.Count -gt 0) {
        $currentId = $queue.Dequeue()
        if (-not $ids.Add($currentId)) {
            continue
        }

        if (-not $Snapshot.ChildrenByParent.ContainsKey($currentId)) {
            continue
        }

        foreach ($child in $Snapshot.ChildrenByParent[$currentId]) {
            $queue.Enqueue([int]$child.ProcessId)
        }
    }

    return $ids
}

function Remove-OrchestraZombieProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GitWorktreeDir,
        [Parameter(Mandatory = $true)][string]$BridgeScript,
        [Parameter(Mandatory = $true)][string]$PsmuxBin
    )

    $snapshot = Get-ProcessSnapshot
    $protectedIds = Get-AncestorProcessIds -Snapshot $snapshot -ProcessId $PID
    $candidateIds = [System.Collections.Generic.HashSet[int]]::new()

    & $PsmuxBin has-session -t $SessionName 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) {
        $panePidOutput = & $PsmuxBin list-panes -t $SessionName -F '#{pane_pid}' 2>$null
        $paneRootIds = @(
            $panePidOutput |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -match '^\d+$' } |
                ForEach-Object { [int]$_ }
        )

        if ($paneRootIds.Count -gt 0) {
            $descendantIds = Get-DescendantProcessIds -Snapshot $snapshot -RootProcessIds $paneRootIds
            foreach ($descendantId in $descendantIds) {
                if (-not $snapshot.ById.ContainsKey($descendantId)) {
                    continue
                }

                $process = $snapshot.ById[$descendantId]
                if ($process.Name -in @('codex.exe', 'node.exe')) {
                    [void]$candidateIds.Add($descendantId)
                }
            }
        }
    }

    foreach ($process in $snapshot.Processes) {
        if ($process.Name -notin @('codex.exe', 'node.exe')) {
            continue
        }

        $processId = [int]$process.ProcessId
        $commandLine = [string]$process.CommandLine
        $parentId = [int]$process.ParentProcessId
        $parentMissing = ($parentId -le 0) -or (-not $snapshot.ById.ContainsKey($parentId))
        $matchesOrchestraContext =
            $commandLine.IndexOf($ProjectDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $commandLine.IndexOf($GitWorktreeDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $commandLine.IndexOf($BridgeScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $commandLine.IndexOf($SessionName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

        if ($parentMissing -and $matchesOrchestraContext) {
            [void]$candidateIds.Add($processId)
        }
    }

    $victims = @(
        $candidateIds |
            Where-Object { $_ -ne $PID -and -not $protectedIds.Contains($_) -and $snapshot.ById.ContainsKey($_) } |
            Sort-Object -Unique |
            ForEach-Object { $snapshot.ById[$_] }
    )

    foreach ($victim in $victims) {
        try {
            Stop-Process -Id ([int]$victim.ProcessId) -Force -ErrorAction Stop
            Write-Output ("Preflight: killed zombie process {0} ({1})" -f $victim.Name, $victim.ProcessId)
            Write-WinsmuxLog -Level INFO -Event 'preflight.zombie_process.killed' -Message ("Killed zombie process {0} ({1})." -f $victim.Name, $victim.ProcessId) -Data @{ process_name = $victim.Name; process_id = [int]$victim.ProcessId } | Out-Null
        } catch {
            Write-Warning ("Preflight: failed to kill zombie process {0} ({1}): {2}" -f $victim.Name, $victim.ProcessId, $_.Exception.Message)
        }
    }
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

    return [PSCustomObject]@{
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

    Invoke-Psmux -Arguments @('set-environment', '-t', $SessionName, $Name, $Value)
}

function Clear-OrchestraSessionEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Invoke-Psmux -Arguments @('set-environment', '-u', '-t', $SessionName, $Name)
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
    Set-Content -Path $configPath -Value $content -Encoding UTF8 -NoNewline

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
        '{"blocked":["localhost","127.0.0.1","169.254.169.254"],"patterns":[]}' | Set-Content -Path $prodHosts -Encoding UTF8
    }

    $jurisdictions = Join-Path $configDir 'allowed-jurisdictions.json'
    if (-not (Test-Path $jurisdictions)) {
        '{"allowed":["JP"],"default_action":"warn"}' | Set-Content -Path $jurisdictions -Encoding UTF8
    }

    $session = [ordered]@{
        session_id     = [guid]::NewGuid().ToString()
        started_at     = (Get-Date -Format o)
        hook_count     = 0
        deny_count     = 0
        evidence_count = 0
    }
    ($session | ConvertTo-Json -Depth 2) | Set-Content -Path $sessionFile -Encoding UTF8

    Write-Output "Preflight: shield-harness initialized at $shDir"
    Write-WinsmuxLog -Level INFO -Event 'preflight.shield_harness.init' -Message "Shield-Harness initialized at $shDir." -Data @{ shield_dir = $shDir } | Out-Null
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

function Wait-PaneShellReady {
    param(
        [Parameter(Mandatory = $true)][string]$PaneId,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $snapshot = Invoke-Psmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') -CaptureOutput
            $text = ($snapshot | Out-String).TrimEnd()
            if ($null -ne (Get-LastNonEmptyLine -Text $text)) {
                return
            }
        } catch {
        }

        Start-Sleep -Milliseconds 250
    }

    try {
        $finalSnapshot = Invoke-Psmux -Arguments @('capture-pane', '-t', $PaneId, '-p', '-J', '-S', '-80') -CaptureOutput
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
        [Parameter(Mandatory = $true)][System.Collections.IEnumerable]$PaneSummaries
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
    $lines.Add('panes:') | Out-Null

    foreach ($paneSummary in @($PaneSummaries)) {
        $lines.Add(('  - label: {0}' -f (ConvertTo-YamlScalar -Value $paneSummary.Label))) | Out-Null
        $lines.Add(('    pane_id: {0}' -f (ConvertTo-YamlScalar -Value $paneSummary.PaneId))) | Out-Null
        $lines.Add(('    role: {0}' -f (ConvertTo-YamlScalar -Value $paneSummary.Role))) | Out-Null
        $lines.Add(('    launch_dir: {0}' -f (ConvertTo-YamlScalar -Value $paneSummary.LaunchDir))) | Out-Null
        $lines.Add(('    builder_branch: {0}' -f (ConvertTo-YamlScalar -Value $paneSummary.BuilderBranch))) | Out-Null
        $lines.Add(('    builder_worktree_path: {0}' -f (ConvertTo-YamlScalar -Value $paneSummary.BuilderWorktreePath))) | Out-Null
        $lines.Add("    task: null") | Out-Null
    }

    Set-Content -Path $manifestPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8 -NoNewline
    return $manifestPath
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
    Initialize-WinsmuxLog -ProjectDir $projectDir -SessionName $sessionName | Out-Null
    Write-WinsmuxLog -Level INFO -Event 'preflight.settings.loaded' -Message 'Loaded orchestra settings.' -Data @{ agent = $settings.agent; model = $settings.model } | Out-Null
    Write-WinsmuxLog -Level INFO -Event 'preflight.psmux_bin.ready' -Message "Using psmux binary: $psmuxBin." -Data @{ psmux_bin = $psmuxBin } | Out-Null
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
    Remove-OrchestraZombieProcesses -SessionName $sessionName -ProjectDir $projectDir -GitWorktreeDir $gitWorktreeDir -BridgeScript $bridgeScript -PsmuxBin $psmuxBin

    Write-WinsmuxLog -Level INFO -Event 'preflight.session.check' -Message "Checking for existing session $sessionName." -Data @{ session_name = $sessionName } | Out-Null
    & $psmuxBin has-session -t $sessionName 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-WinsmuxLog -Level INFO -Event 'preflight.session.kill' -Message "Removing existing session $sessionName." -Data @{ session_name = $sessionName } | Out-Null
        Invoke-Psmux -Arguments @('kill-session', '-t', $sessionName)
    }

    Write-WinsmuxLog -Level INFO -Event 'preflight.session.create' -Message "Creating session $sessionName." -Data @{ session_name = $sessionName } | Out-Null
    Invoke-Psmux -Arguments @('new-session', '-d', '-s', $sessionName)

    Write-WinsmuxLog -Level INFO -Event 'preflight.session_env.start' -Message 'Publishing vault values to session environment.' -Data @{ key_count = $vaultValues.Count } | Out-Null
    foreach ($entry in $vaultValues.GetEnumerator()) {
        Invoke-Psmux -Arguments @('set-environment', '-t', $sessionName, $entry.Key, $entry.Value)
    }

    $previousTargetSession = $env:WINSMUX_ORCHESTRA_SESSION
    $previousProjectDir = $env:WINSMUX_ORCHESTRA_PROJECT_DIR
    $env:WINSMUX_ORCHESTRA_SESSION = $sessionName
    $env:WINSMUX_ORCHESTRA_PROJECT_DIR = $projectDir

    try {
        $layout = . $layoutScript -SessionName $sessionName -Builders $settings.builders -Researchers $settings.researchers -Reviewers $settings.reviewers
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
            $launchDir = $builderWorktree.WorktreePath
            $launchGitWorktreeDir = $builderWorktree.GitWorktreeDir
            $builderBranch = $builderWorktree.BranchName
            $builderWorktreePath = $builderWorktree.WorktreePath
        }

        $roleAgentConfig = Get-RoleAgentConfig -Role $canonicalRole -Settings $settings
        $launchCommand = Get-AgentLaunchCommand -Agent $roleAgentConfig.Agent -Model $roleAgentConfig.Model -ProjectDir $launchDir -GitWorktreeDir $launchGitWorktreeDir

        Invoke-Bridge -Arguments @('name', $paneId, $label)
        try {
            Set-OrchestraSessionEnvironment -SessionName $sessionName -Name 'WINSMUX_ROLE' -Value $canonicalRole
            Set-OrchestraSessionEnvironment -SessionName $sessionName -Name 'WINSMUX_PANE_ID' -Value $paneId
            Invoke-Psmux -Arguments @('respawn-pane', '-k', '-t', $paneId, '-c', $launchDir)
            Wait-PaneShellReady -PaneId $paneId
            Send-OrchestraBridgeCommand -Target $paneId -Text $launchCommand
        } finally {
            foreach ($envName in @('WINSMUX_ROLE', 'WINSMUX_PANE_ID')) {
                try {
                    Clear-OrchestraSessionEnvironment -SessionName $sessionName -Name $envName
                } catch {
                }
            }
        }

        $paneSummaries.Add([PSCustomObject]@{
            Label = $label
            PaneId = $paneId
            Role = $canonicalRole
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

    $manifestPath = Save-OrchestraSessionState -ProjectDir $projectDir -SessionName $sessionName -Settings $settings -GitWorktreeDir $gitWorktreeDir -PaneSummaries $paneSummaries
    Write-Output ''
    Write-Output "Manifest: $manifestPath"
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
