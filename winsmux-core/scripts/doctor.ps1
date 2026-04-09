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

function Test-ZombieProcessesCheck {
    $repoRoot = Get-DoctorRepoRoot
    $snapshot = Get-DoctorProcessSnapshot

    if (-not $snapshot.SupportsCommandLine) {
        return New-DoctorResult -Status warn -Label 'Zombie processes' -Detail 'command line inspection unavailable'
    }

    $protectedIds = Get-DoctorAncestorProcessIds -Snapshot $snapshot -ProcessId $PID
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

        $name = ([string]$process.Name).Trim().ToLowerInvariant()
        if ($name.EndsWith('.exe')) {
            $name = $name.Substring(0, $name.Length - 4)
        }

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

function Test-BridgeConfigCheck {
    $repoRoot = Get-DoctorRepoRoot
    $configPath = Join-Path $repoRoot '.winsmux.yaml'

    if (-not (Test-Path $configPath)) {
        return New-DoctorResult -Status fail -Label '.winsmux.yaml' -Detail 'not found'
    }

    return New-DoctorResult -Status pass -Label '.winsmux.yaml' -Detail 'found'
}

function Write-DoctorResult {
    param([Parameter(Mandatory = $true)]$Result)

    $status = $Result.Status.ToUpperInvariant()
    Write-Output ("[{0}] {1}: {2}" -f $status, $Result.Label, $Result.Detail)
}

$results = @(
    Test-VersionFileCheck
    Test-HookFilesCheck
    Test-SettingsJsonCheck
    Test-BacklogYamlCheck
    Test-ManifestYamlCheck
    Test-StaleWorktreesCheck
    Test-ZombieProcessesCheck
    Test-BridgeConfigCheck
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
