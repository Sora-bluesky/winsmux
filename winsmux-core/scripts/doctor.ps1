[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('repo')]
    [string]$Target = 'repo'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'planning-paths.ps1')
. (Join-Path $PSScriptRoot 'pane-env.ps1')
. (Join-Path $PSScriptRoot 'settings.ps1')
. (Join-Path $PSScriptRoot 'manifest.ps1')
. (Join-Path $PSScriptRoot 'worker-isolation.ps1')

function New-DoctorResult {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'warn', 'fail')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    return [PSCustomObject]@{
        Status = $Status
        Label  = $Label
        Detail = $Detail
    }
}

function Get-DoctorRepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Get-DoctorProcessSnapshot {
    try {
        $processes = @(Get-CimInstance Win32_Process -OperationTimeoutSec 10)
        $supportsCommandLine = $true
    } catch {
        $processes = @(Get-Process | ForEach-Object {
            [PSCustomObject]@{
                ProcessId       = $_.Id
                ParentProcessId = 0
                CommandLine     = ''
                Name            = $_.ProcessName
            }
        })
        $supportsCommandLine = $false
    }

    $byId = @{}
    foreach ($process in $processes) {
        $byId[[int]$process.ProcessId] = $process
    }

    return [PSCustomObject]@{
        Processes            = $processes
        ById                 = $byId
        SupportsCommandLine  = $supportsCommandLine
    }
}

function Get-DoctorAncestorProcessIds {
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

function Get-DoctorGitCommandPath {
    $command = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return $null
    }

    if ($command.Path) {
        return $command.Path
    }

    return $command.Source
}

function Get-DoctorNormalizedProcessName {
    param([AllowNull()][string]$Name)

    $normalized = ([string]$Name).Trim().ToLowerInvariant()
    if ($normalized.EndsWith('.exe')) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }

    return $normalized
}

function Get-DoctorObjectPropertyValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($Name)) {
        return $InputObject[$Name]
    }

    if ($null -ne $InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.PSObject.Properties[$Name].Value
    }

    return $Default
}

function Test-BasicYamlContent {
    param([Parameter(Mandatory = $true)][string]$Content)

    $lineNumber = 0
    $hasStructuredLine = $false
    $blockScalarIndent = $null

    foreach ($rawLine in ($Content -split "\r?\n")) {
        $lineNumber++

        if ($rawLine.Contains("`t")) {
            return [PSCustomObject]@{
                Valid   = $false
                Message = "tab indentation at line $lineNumber"
            }
        }

        if ($null -ne $blockScalarIndent -and -not [string]::IsNullOrWhiteSpace($rawLine)) {
            $currentIndent = ([regex]::Match($rawLine, '^\s*')).Value.Length
            if ($currentIndent -ge $blockScalarIndent) {
                $hasStructuredLine = $true
                continue
            }

            $blockScalarIndent = $null
        }

        $trimmed = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        $indent = ([regex]::Match($rawLine, '^\s*')).Value.Length
        if (($indent % 2) -ne 0) {
            return [PSCustomObject]@{
                Valid   = $false
                Message = "odd indentation at line $lineNumber"
            }
        }

        if ($trimmed -match '^- (.+)$') {
            $hasStructuredLine = $true
            $listItem = $Matches[1].Trim()
            if ([string]::IsNullOrWhiteSpace($listItem)) {
                return [PSCustomObject]@{
                    Valid   = $false
                    Message = "empty list item at line $lineNumber"
                }
            }

            if ($listItem -match ':\s*[>|]$') {
                $blockScalarIndent = $indent + 4
            }

            continue
        }

        if ($trimmed -notmatch '^[^:#][^:]*:\s*(.*)$') {
            return [PSCustomObject]@{
                Valid   = $false
                Message = "unrecognized YAML syntax at line $lineNumber"
            }
        }

        $hasStructuredLine = $true
        $value = $Matches[1]
        if ($value -match '^[>|]$') {
            $blockScalarIndent = $indent + 2
        }
    }

    if (-not $hasStructuredLine) {
        return [PSCustomObject]@{
            Valid   = $false
            Message = 'file is empty'
        }
    }

    return [PSCustomObject]@{
        Valid   = $true
        Message = 'basic YAML parse succeeded'
    }
}

function Test-YamlDocument {
    param([Parameter(Mandatory = $true)][string]$Content)

    $yamlCommand = Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue
    if ($null -ne $yamlCommand) {
        try {
            $null = $Content | ConvertFrom-Yaml -ErrorAction Stop
            return [PSCustomObject]@{
                Valid   = $true
                Message = 'valid YAML'
            }
        } catch {
            return [PSCustomObject]@{
                Valid   = $false
                Message = $_.Exception.Message
            }
        }
    }

    return Test-BasicYamlContent -Content $Content
}

function Test-VersionFileCheck {
    $repoRoot = Get-DoctorRepoRoot
    $versionPath = Join-Path $repoRoot 'VERSION'
    $installPath = Join-Path $repoRoot 'install.ps1'

    if (-not (Test-Path $versionPath)) {
        return New-DoctorResult -Status fail -Label 'VERSION file' -Detail 'VERSION not found'
    }

    if (-not (Test-Path $installPath)) {
        return New-DoctorResult -Status fail -Label 'VERSION file' -Detail 'install.ps1 not found'
    }

    $version = (Get-Content -Path $versionPath -Raw -Encoding UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($version)) {
        return New-DoctorResult -Status fail -Label 'VERSION file' -Detail 'VERSION is empty'
    }

    $installContent = Get-Content -Path $installPath -Raw -Encoding UTF8
    $match = [regex]::Match($installContent, '(?m)^\$VERSION\s*=\s*"([^"]+)"\s*$')
    if (-not $match.Success) {
        return New-DoctorResult -Status fail -Label 'VERSION file' -Detail 'install.ps1 version string not found'
    }

    $installVersion = $match.Groups[1].Value.Trim()
    if ($version -ne $installVersion) {
        return New-DoctorResult -Status fail -Label 'VERSION file' -Detail "VERSION=$version, install.ps1=$installVersion"
    }

    return New-DoctorResult -Status pass -Label 'VERSION file' -Detail $version
}

function Test-HookFilesCheck {
    $repoRoot = Get-DoctorRepoRoot
    $hooksDir = Join-Path $repoRoot '.claude/hooks'

    if (-not (Test-Path $hooksDir)) {
        return New-DoctorResult -Status fail -Label 'Hook files' -Detail '.claude/hooks not found'
    }

    $hookFiles = @(Get-ChildItem -Path $hooksDir -File -ErrorAction Stop)
    if ($hookFiles.Count -le 0) {
        return New-DoctorResult -Status fail -Label 'Hook files' -Detail '0 found'
    }

    return New-DoctorResult -Status pass -Label 'Hook files' -Detail "$($hookFiles.Count) found"
}

function Test-SettingsJsonCheck {
    $repoRoot = Get-DoctorRepoRoot
    $settingsPath = Join-Path $repoRoot '.claude/settings.json'

    if (-not (Test-Path $settingsPath)) {
        return New-DoctorResult -Status fail -Label 'settings.json' -Detail 'not found'
    }

    try {
        $raw = Get-Content -Path $settingsPath -Raw -Encoding UTF8
        $null = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return New-DoctorResult -Status fail -Label 'settings.json' -Detail $_.Exception.Message
    }

    return New-DoctorResult -Status pass -Label 'settings.json' -Detail 'valid JSON'
}

function Test-BacklogYamlCheck {
    $repoRoot = Get-DoctorRepoRoot
    $backlogPath = Resolve-WinsmuxPlanningFilePath -RepoRoot $repoRoot -LocalRelativePath 'tasks/backlog.yaml' -EnvironmentVariable 'WINSMUX_BACKLOG_PATH' -DefaultFileName 'backlog.yaml'

    if (-not (Test-Path $backlogPath)) {
        return New-DoctorResult -Status fail -Label 'backlog.yaml' -Detail "not found ($backlogPath)"
    }

    $content = Get-Content -Path $backlogPath -Raw -Encoding UTF8
    $validation = Test-YamlDocument -Content $content
    if (-not $validation.Valid) {
        return New-DoctorResult -Status fail -Label 'backlog.yaml' -Detail $validation.Message
    }

    return New-DoctorResult -Status pass -Label 'backlog.yaml' -Detail $validation.Message
}

function Test-ManifestYamlCheck {
    $repoRoot = Get-DoctorRepoRoot
    $manifestPath = Join-Path $repoRoot '.winsmux/manifest.yaml'

    if (-not (Test-Path $manifestPath)) {
        return New-DoctorResult -Status warn -Label 'manifest.yaml' -Detail 'not found (orchestra not started)'
    }

    return New-DoctorResult -Status pass -Label 'manifest.yaml' -Detail 'found'
}

function Test-StaleWorktreesCheck {
    $repoRoot = Get-DoctorRepoRoot
    $gitPath = Get-DoctorGitCommandPath

    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        return New-DoctorResult -Status warn -Label 'Stale worktrees' -Detail 'git not found'
    }

    try {
        $output = & $gitPath -C $repoRoot worktree list --porcelain 2>&1
        if ($LASTEXITCODE -ne 0) {
            $message = ($output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ }) -join '; '
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = 'git worktree list failed'
            }

            return New-DoctorResult -Status warn -Label 'Stale worktrees' -Detail $message
        }
    } catch {
        return New-DoctorResult -Status warn -Label 'Stale worktrees' -Detail $_.Exception.Message
    }

    $staleWorktrees = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($output)) {
        if ($line -match '^worktree (.+)$') {
            $worktreePath = $Matches[1].Trim()
            if (-not (Test-Path $worktreePath)) {
                $staleWorktrees.Add($worktreePath) | Out-Null
            }
        }
    }

    if ($staleWorktrees.Count -gt 0) {
        return New-DoctorResult -Status fail -Label 'Stale worktrees' -Detail "$($staleWorktrees.Count) found"
    }

    return New-DoctorResult -Status pass -Label 'Stale worktrees' -Detail '0 found'
}

function Test-WorkerGitDriftCheck {
    $repoRoot = Get-DoctorRepoRoot
    $manifestPath = Join-Path $repoRoot '.winsmux/manifest.yaml'

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return New-DoctorResult -Status warn -Label 'Worker isolation drift' -Detail 'manifest not found (orchestra not started)'
    }

    try {
        $manifest = Get-WinsmuxManifest -ProjectDir $repoRoot
    } catch {
        return New-DoctorResult -Status fail -Label 'Worker isolation drift' -Detail $_.Exception.Message
    }

    $gitPath = Get-DoctorGitCommandPath
    $report = Get-WinsmuxWorkerIsolationReport -ProjectDir $repoRoot -Manifest $manifest -GitPath $gitPath
    if ($report.ok) {
        return New-DoctorResult -Status pass -Label 'Worker isolation drift' -Detail $report.summary
    }

    $findingText = (@($report.findings) | ForEach-Object { "$($_.label): $($_.message)" }) -join '; '
    if (-not [string]::IsNullOrWhiteSpace($report.remediation)) {
        $findingText = "$findingText; $($report.remediation)"
    }

    return New-DoctorResult -Status fail -Label 'Worker isolation drift' -Detail $findingText
}

function Test-ZombieProcessesCheck {
    $repoRoot = Get-DoctorRepoRoot
    $snapshot = Get-DoctorProcessSnapshot

    if (-not $snapshot.SupportsCommandLine) {
        return New-DoctorResult -Status warn -Label 'Zombie processes' -Detail 'command line inspection unavailable'
    }

    $protectedIds = @(Get-DoctorAncestorProcessIds -Snapshot $snapshot -ProcessId $PID)
    $markerPaths = @(
        $repoRoot,
        (Join-Path $repoRoot '.worktrees'),
        (Join-Path $repoRoot 'winsmux-core'),
        (Join-Path $HOME '.winsmux')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $zombies = [System.Collections.Generic.List[object]]::new()
    foreach ($process in $snapshot.Processes) {
        $processId = [int]$process.ProcessId
        if ($protectedIds.Contains($processId)) {
            continue
        }

        $name = Get-DoctorNormalizedProcessName -Name $process.Name
        if ($name -notin @('codex', 'pwsh', 'powershell')) {
            continue
        }

        $commandLine = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            continue
        }

        $matchesWinsmuxPath = $false
        foreach ($marker in $markerPaths) {
            if ($commandLine.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $matchesWinsmuxPath = $true
                break
            }
        }

        if (-not $matchesWinsmuxPath) {
            continue
        }

        $parentId = [int]$process.ParentProcessId
        $parentMissing = ($parentId -le 0) -or (-not $snapshot.ById.ContainsKey($parentId))
        if ($parentMissing) {
            $zombies.Add($process) | Out-Null
        }
    }

    if ($zombies.Count -gt 0) {
        return New-DoctorResult -Status fail -Label 'Zombie processes' -Detail "$($zombies.Count) found"
    }

    return New-DoctorResult -Status pass -Label 'Zombie processes' -Detail '0 found'
}

function Get-DoctorPowerShellProcessWarnThreshold {
    $threshold = 100
    $rawValue = [string]$env:WINSMUX_DOCTOR_POWERSHELL_PROCESS_WARN_THRESHOLD
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return $threshold
    }

    try {
        $parsed = [int]$rawValue
        if ($parsed -gt 0) {
            return $parsed
        }
    } catch {
        return $threshold
    }

    return $threshold
}

function Get-DoctorPowerShellStartupLowCountWarnThreshold {
    $threshold = 8
    $rawValue = [string]$env:WINSMUX_DOCTOR_POWERSHELL_STARTUP_LOW_COUNT_WARN_THRESHOLD
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return $threshold
    }

    try {
        $parsed = [int]$rawValue
        if ($parsed -gt 0) {
            return $parsed
        }
    } catch {
        return $threshold
    }

    return $threshold
}

function New-PowerShellProcessPressureResult {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)]$ProtectedIds,
        [Parameter(Mandatory = $true)][int]$WarnThreshold
    )

    $count = 0
    foreach ($process in $Snapshot.Processes) {
        $processId = [int]$process.ProcessId
        if ($ProtectedIds.Contains($processId)) {
            continue
        }

        $name = Get-DoctorNormalizedProcessName -Name $process.Name
        if ($name -in @('pwsh', 'powershell')) {
            $count++
        }
    }

    if ($count -ge $WarnThreshold) {
        return New-DoctorResult -Status warn -Label 'PowerShell process pressure' -Detail "$count found; close unneeded pwsh.exe or powershell.exe sessions before starting more winsmux panes"
    }

    return New-DoctorResult -Status pass -Label 'PowerShell process pressure' -Detail "$count found"
}

function Get-DoctorProcessParentCategory {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)]$Process
    )

    $parentId = [int]$Process.ParentProcessId
    if ($parentId -le 0 -or -not $Snapshot.ById.ContainsKey($parentId)) {
        return 'missing-parent'
    }

    $parent = $Snapshot.ById[$parentId]
    $name = Get-DoctorNormalizedProcessName -Name $parent.Name
    $commandLine = [string]$parent.CommandLine

    if ($name -in @('code', 'code-insiders')) {
        return 'vscode'
    }
    if ($name -in @('windowsterminal', 'wt')) {
        return 'windows-terminal'
    }
    if ($commandLine.IndexOf('WindowsTerminal', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return 'windows-terminal'
    }
    if ($name -eq 'codex') {
        return 'codex'
    }
    if ($name -in @('pwsh', 'powershell')) {
        return 'powershell'
    }
    if ($name -in @('conhost', 'openconsole')) {
        return 'console-host'
    }

    return 'other'
}

function New-PowerShellStartupEvidenceResult {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)]$ProtectedIds,
        [Parameter(Mandatory = $true)][int]$WarnThreshold,
        [int]$LowCountWarnThreshold = 8,
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'fail')][string]$SmokeStatus,
        [Parameter(Mandatory = $true)][string]$SmokeDetail
    )

    $count = 0
    $categoryCounts = @{}
    foreach ($process in $Snapshot.Processes) {
        $processId = [int]$process.ProcessId
        if ($ProtectedIds.Contains($processId)) {
            continue
        }

        $name = Get-DoctorNormalizedProcessName -Name $process.Name
        if ($name -notin @('pwsh', 'powershell')) {
            continue
        }

        $count++
        $category = Get-DoctorProcessParentCategory -Snapshot $Snapshot -Process $process
        if (-not $categoryCounts.ContainsKey($category)) {
            $categoryCounts[$category] = 0
        }
        $categoryCounts[$category]++
    }

    $categoryText = 'none'
    if ($categoryCounts.Count -gt 0) {
        $categoryText = (@($categoryCounts.Keys) | Sort-Object | ForEach-Object { "$_=$($categoryCounts[$_])" }) -join ','
    }

    $countState = if ($count -ge $WarnThreshold) { 'at_or_above_threshold' } else { 'below_threshold' }
    $startupRisk = 'normal'
    if ($SmokeStatus -eq 'fail') {
        $startupRisk = 'smoke_failed'
    } elseif ($count -ge $WarnThreshold) {
        $startupRisk = 'high_count'
    } elseif ($count -ge $LowCountWarnThreshold) {
        $startupRisk = 'low_count_risk'
    }
    $status = if ($startupRisk -eq 'normal') { 'pass' } else { 'warn' }
    $detail = "pwsh_count=$count; count_state=$countState; low_count_threshold=$LowCountWarnThreshold; startup_risk=$startupRisk; parent_categories=$categoryText; bare_pwsh=$SmokeStatus; smoke_detail=$SmokeDetail; scoped_cleanup=close related VS Code, Windows Terminal, or Codex shells first; command_lines=omitted"

    return New-DoctorResult -Status $status -Label 'PowerShell startup evidence' -Detail $detail
}

function Test-PowerShellProcessPressureCheck {
    $snapshot = Get-DoctorProcessSnapshot
    $protectedIds = @(Get-DoctorAncestorProcessIds -Snapshot $snapshot -ProcessId $PID)
    $warnThreshold = Get-DoctorPowerShellProcessWarnThreshold

    return New-PowerShellProcessPressureResult -Snapshot $snapshot -ProtectedIds $protectedIds -WarnThreshold $warnThreshold
}

function Invoke-DoctorPowerShellStartupSmoke {
    $command = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return [PSCustomObject]@{
            Status = 'fail'
            Detail = 'pwsh was not found on PATH'
        }
    }

    $pwshPath = $command.Path
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
        $pwshPath = $command.Source
    }

    try {
        $output = & $pwshPath -NoProfile -NoLogo -Command '$PSVersionTable.PSVersion.ToString()' 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        return [PSCustomObject]@{
            Status = 'fail'
            Detail = $_.Exception.Message
        }
    }

    $message = (@($output) | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ }) -join '; '
    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "pwsh exited with code $exitCode"
        } else {
            $message = "pwsh exited with code $exitCode; $message"
        }
        $message = "$message; check Windows Application event log for pwsh.exe initialization errors"

        return [PSCustomObject]@{
            Status = 'fail'
            Detail = $message
        }
    }

    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = $pwshPath
    } else {
        $message = "$message ($pwshPath)"
    }

    return [PSCustomObject]@{
        Status = 'pass'
        Detail = $message
    }
}

function Test-PowerShellStartupHealthCheck {
    $smoke = Invoke-DoctorPowerShellStartupSmoke
    return New-DoctorResult -Status $smoke.Status -Label 'PowerShell startup health' -Detail $smoke.Detail
}

function Test-PowerShellStartupEvidenceCheck {
    $snapshot = Get-DoctorProcessSnapshot
    $protectedIds = @(Get-DoctorAncestorProcessIds -Snapshot $snapshot -ProcessId $PID)
    $warnThreshold = Get-DoctorPowerShellProcessWarnThreshold
    $lowCountWarnThreshold = Get-DoctorPowerShellStartupLowCountWarnThreshold
    $smoke = Invoke-DoctorPowerShellStartupSmoke

    return New-PowerShellStartupEvidenceResult -Snapshot $snapshot -ProtectedIds $protectedIds -WarnThreshold $warnThreshold -LowCountWarnThreshold $lowCountWarnThreshold -SmokeStatus $smoke.Status -SmokeDetail $smoke.Detail
}

function Invoke-DoctorOrchestraSmokeJson {
    $repoRoot = Get-DoctorRepoRoot
    $smokePath = Join-Path $PSScriptRoot 'orchestra-smoke.ps1'
    if (-not (Test-Path -LiteralPath $smokePath -PathType Leaf)) {
        return [PSCustomObject]@{
            Ok       = $false
            ExitCode = 1
            Data     = $null
            Error    = 'orchestra-smoke.ps1 not found'
        }
    }

    $command = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return [PSCustomObject]@{
            Ok       = $false
            ExitCode = 1
            Data     = $null
            Error    = 'pwsh was not found on PATH'
        }
    }

    $pwshPath = if ($command.Path) { $command.Path } else { $command.Source }
    try {
        $output = & $pwshPath -NoProfile -NoLogo -File $smokePath -ProjectDir $repoRoot -AsJson 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        return [PSCustomObject]@{
            Ok       = $false
            ExitCode = 1
            Data     = $null
            Error    = $_.Exception.Message
        }
    }

    $text = (@($output) | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    $jsonMatch = [regex]::Match($text, '(?s)\{.*\}')
    if (-not $jsonMatch.Success) {
        return [PSCustomObject]@{
            Ok       = $false
            ExitCode = $exitCode
            Data     = $null
            Error    = 'orchestra-smoke did not return JSON'
        }
    }

    try {
        $data = $jsonMatch.Value | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{
            Ok       = $false
            ExitCode = $exitCode
            Data     = $null
            Error    = $_.Exception.Message
        }
    }

    return [PSCustomObject]@{
        Ok       = $true
        ExitCode = $exitCode
        Data     = $data
        Error    = ''
    }
}

function New-OrchestraProcessContractDoctorResult {
    param([Parameter(Mandatory = $true)]$Contract)

    $budgets = Get-DoctorObjectPropertyValue -InputObject $Contract -Name 'budgets'
    $workerCount = [int](Get-DoctorObjectPropertyValue -InputObject $Contract -Name 'worker_shell_count' -Default 0)
    $helperCount = [int](Get-DoctorObjectPropertyValue -InputObject $Contract -Name 'background_helper_count' -Default 0)
    $attachHostCount = [int](Get-DoctorObjectPropertyValue -InputObject $Contract -Name 'attach_host_count' -Default 0)
    $warmProcessCount = [int](Get-DoctorObjectPropertyValue -InputObject $Contract -Name 'warm_process_count' -Default 0)
    $staleProcessCount = [int](Get-DoctorObjectPropertyValue -InputObject $Contract -Name 'stale_process_count' -Default 0)
    $workerBudget = [int](Get-DoctorObjectPropertyValue -InputObject $budgets -Name 'max_worker_shells' -Default 0)
    $helperBudget = [int](Get-DoctorObjectPropertyValue -InputObject $budgets -Name 'max_background_helpers' -Default 0)
    $attachHostBudget = [int](Get-DoctorObjectPropertyValue -InputObject $budgets -Name 'max_attach_hosts' -Default 0)
    $warmProcessBudget = [int](Get-DoctorObjectPropertyValue -InputObject $budgets -Name 'max_warm_processes' -Default 0)
    $staleProcessBudget = [int](Get-DoctorObjectPropertyValue -InputObject $budgets -Name 'max_stale_processes' -Default 0)

    $detail = "workers=$workerCount/$workerBudget; background_helpers=$helperCount/$helperBudget; attach_hosts=$attachHostCount/$attachHostBudget; warm_processes=$warmProcessCount/$warmProcessBudget; stale_processes=$staleProcessCount/$staleProcessBudget"
    if ([bool](Get-DoctorObjectPropertyValue -InputObject $Contract -Name 'ok' -Default $false)) {
        return New-DoctorResult -Status pass -Label 'Orchestra process contract' -Detail $detail
    }

    $warnings = @(
        @(Get-DoctorObjectPropertyValue -InputObject $Contract -Name 'warnings' -Default @()) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($warnings.Count -gt 0) {
        $detail = "$detail; $($warnings -join '; ')"
    }

    return New-DoctorResult -Status fail -Label 'Orchestra process contract' -Detail $detail
}

function Test-OrchestraProcessContractCheck {
    $smoke = Invoke-DoctorOrchestraSmokeJson
    if (-not [bool]$smoke.Ok) {
        return New-DoctorResult -Status warn -Label 'Orchestra process contract' -Detail "unavailable; $($smoke.Error)"
    }

    $contract = Get-DoctorObjectPropertyValue -InputObject $smoke.Data -Name 'process_contract'
    if ($null -eq $contract) {
        return New-DoctorResult -Status warn -Label 'Orchestra process contract' -Detail 'unavailable; orchestra-smoke did not include process_contract'
    }

    return New-OrchestraProcessContractDoctorResult -Contract $contract
}

function Test-BridgeConfigCheck {
    $repoRoot = Get-DoctorRepoRoot
    $configPath = Join-Path $repoRoot '.winsmux.yaml'

    if (-not (Test-Path $configPath)) {
        return New-DoctorResult -Status fail -Label '.winsmux.yaml' -Detail 'not found'
    }

    return New-DoctorResult -Status pass -Label '.winsmux.yaml' -Detail 'found'
}

function Test-BridgeConfigMetadataCheck {
    $repoRoot = Get-DoctorRepoRoot
    $configPath = Join-Path $repoRoot '.winsmux.yaml'

    if (-not (Test-Path $configPath)) {
        return New-DoctorResult -Status fail -Label 'Bridge config metadata' -Detail '.winsmux.yaml not found'
    }

    try {
        $metadata = Get-BridgeSettingsMetadata -RootPath $repoRoot
    } catch {
        return New-DoctorResult -Status fail -Label 'Bridge config metadata' -Detail $_.Exception.Message
    }

    $detail = "config_version=$($metadata.ConfigVersion); migration_status=$($metadata.MigrationStatus); slot_count=$($metadata.SlotCount); legacy_role_layout=$($metadata.LegacyRoleLayout)"
    return New-DoctorResult -Status pass -Label 'Bridge config metadata' -Detail $detail
}

function Test-HookProfileCheck {
    $repoRoot = Get-DoctorRepoRoot

    try {
        $profile = Resolve-WinsmuxHookProfile -ProjectDir $repoRoot
    } catch {
        return New-DoctorResult -Status fail -Label 'Hook profile' -Detail $_.Exception.Message
    }

    return New-DoctorResult -Status pass -Label 'Hook profile' -Detail $profile
}

function Test-GovernanceModeCheck {
    $repoRoot = Get-DoctorRepoRoot

    try {
        $mode = Resolve-WinsmuxGovernanceMode -ProjectDir $repoRoot
    } catch {
        return New-DoctorResult -Status fail -Label 'Governance mode' -Detail $_.Exception.Message
    }

    return New-DoctorResult -Status pass -Label 'Governance mode' -Detail $mode
}

function Test-WinsmuxEnvContractCheck {
    $repoRoot = Get-DoctorRepoRoot

    try {
        $contract = Get-WinsmuxEnvironmentContract -ProjectDir $repoRoot
    } catch {
        return New-DoctorResult -Status fail -Label 'WINSMUX env contract' -Detail $_.Exception.Message
    }

    $detail = "hook_profile=$($contract['hook_profile']); governance_mode=$($contract['governance_mode']); vars=$((@($contract['variable_names']) -join ','))"
    return New-DoctorResult -Status pass -Label 'WINSMUX env contract' -Detail $detail
}

function Write-DoctorResult {
    param([Parameter(Mandatory = $true)]$Result)

    $status = $Result.Status.ToUpperInvariant()
    Write-Output ("[{0}] {1}: {2}" -f $status, $Result.Label, $Result.Detail)
}

$functionsOnlyVariable = Get-Variable -Name __winsmux_doctor_functions_only -Scope Script -ErrorAction SilentlyContinue
$functionsOnly = $false
if ($null -ne $functionsOnlyVariable) {
    $functionsOnly = [bool]$functionsOnlyVariable.Value
}

if (-not $functionsOnly) {
    $results = @(
        Test-VersionFileCheck
        Test-HookFilesCheck
        Test-SettingsJsonCheck
        Test-BacklogYamlCheck
        Test-ManifestYamlCheck
        Test-StaleWorktreesCheck
        Test-WorkerGitDriftCheck
        Test-ZombieProcessesCheck
        Test-PowerShellProcessPressureCheck
        Test-PowerShellStartupHealthCheck
        Test-PowerShellStartupEvidenceCheck
        Test-OrchestraProcessContractCheck
        Test-BridgeConfigCheck
        Test-BridgeConfigMetadataCheck
        Test-HookProfileCheck
        Test-GovernanceModeCheck
        Test-WinsmuxEnvContractCheck
    )

    $hasFail = $false
    foreach ($result in $results) {
        Write-DoctorResult -Result $result
        if ($result.Status -eq 'fail') {
            $hasFail = $true
        }
    }

    if ($hasFail) {
        exit 1
    }

    exit 0
}
