#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(0, 100)]
    [int]$CoverageThreshold = 75,

    [switch]$Coverage,

    [switch]$Parallel = $true,

    [ValidateRange(1, 256)]
    [int]$MaxParallel = [Environment]::ProcessorCount,

    [string]$ResultsDirectory,

    [Parameter(DontShow = $true)]
    [string[]]$LineFilters = @(),

    [Parameter(DontShow = $true)]
    [string]$WorkerSpecPath,

    [Parameter(DontShow = $true)]
    [ValidateRange(1, 7200)]
    # The integration CI shard owns a 30-minute outer budget. The local aggregate
    # runner stays at 1800 seconds (equal to that budget). Do not raise this watchdog.
    [int]$WorkerTimeoutSeconds = 1800,

    [Parameter(DontShow = $true)]
    [string]$WorkerStdOutPath,

    [Parameter(DontShow = $true)]
    [string]$WorkerStdErrPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CoverageTargets {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$TestPaths
    )

    $targets = [System.Collections.Generic.List[string]]::new()

    foreach ($testPath in $TestPaths) {
        $testFile = Get-Item -LiteralPath $testPath -ErrorAction Stop
        if ($testFile.PSIsContainer -or -not $testFile.Name.EndsWith('.Tests.ps1', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Coverage input is not a Pester test file: $($testFile.FullName)"
        }
        $content = Get-Content -LiteralPath $testFile.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) {
            continue
        }

        $matches = [regex]::Matches($content, '(?im)(?:Join-Path\s+\$PSScriptRoot\s+[''\"](?<relative>\.\.[\\/][^''\"]+\.(?:ps1|psm1))[''\"]|(?<literal>\.\.[\\/][^\s''\"\"]+\.(?:ps1|psm1)))')
        foreach ($match in $matches) {
            $relativePath = if ($match.Groups['relative'].Success) {
                $match.Groups['relative'].Value
            } else {
                $match.Groups['literal'].Value
            }

            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                continue
            }

            $candidate = [System.IO.Path]::GetFullPath((Join-Path $testFile.DirectoryName $relativePath))
            if ((Test-Path -LiteralPath $candidate) -and ($candidate -notin $targets)) {
                [void]$targets.Add($candidate)
            }
        }
    }

    if ($targets.Count -gt 0) {
        return $targets.ToArray()
    }

    return Get-ChildItem -Path (Join-Path $RepositoryRoot 'scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'run-tests.ps1' } |
        Select-Object -ExpandProperty FullName
}

function Get-CoveragePercent {
    param([object]$CodeCoverage)

    if (-not $CodeCoverage) {
        return $null
    }

    if ($CodeCoverage.PSObject.Properties.Name -contains 'CoveragePercent') {
        return [double]$CodeCoverage.CoveragePercent
    }

    $analyzed = Get-PesterCoverageNumericCount -InputObject $CodeCoverage -Names @(
        'NumberOfCommandsAnalyzed', 'CommandsAnalyzedCount', 'CommandsAnalyzed'
    )
    $executed = Get-PesterCoverageNumericCount -InputObject $CodeCoverage -Names @(
        'NumberOfCommandsExecuted', 'CommandsExecutedCount'
    )
    if ($null -ne $analyzed -and $null -ne $executed) {
        if ([double]$analyzed -le 0) {
            return 0
        }

        return [math]::Round(([double]$executed / [double]$analyzed) * 100, 2)
    }

    return $null
}

function Write-TestSummary {
    param(
        [string]$Path,
        [int]$PassedCount,
        [int]$FailedCount,
        [int]$TotalCount,
        [Nullable[double]]$CoveragePercent,
        [int]$CoverageThreshold,
        [System.Collections.IDictionary]$Additional = @{}
    )

    $summary = [ordered]@{
        passed = $PassedCount
        failed = $FailedCount
        total = $TotalCount
        coveragePercent = $CoveragePercent
        coverageThreshold = $CoverageThreshold
    }
    foreach ($entry in $Additional.GetEnumerator()) {
        $summary[[string]$entry.Key] = $entry.Value
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-TestIdentity {
    param([Parameter(Mandatory = $true)]$Test)

    $file = ([string]$Test.ScriptBlock.File).Replace('\', '/')
    $testsMarker = '/tests/'
    $testsIndex = $file.LastIndexOf($testsMarker, [StringComparison]::OrdinalIgnoreCase)
    if ($testsIndex -ge 0) {
        $file = 'tests/' + $file.Substring($testsIndex + $testsMarker.Length)
    }
    # Use the unexpanded source name. Discovery intentionally retains <Case>
    # placeholders while execution expands them, so ExpandedName is not a
    # stable identity across the two phases. Repeated dynamic cases remain a
    # multiset because each source-line/name identity is kept once per case.
    return '{0}:{1}|{2}' -f $file, $Test.StartLine, [string]$Test.Name
}

function Get-IdentityHash {
    param([string[]]$Identities)

    $text = (@($Identities | Sort-Object) -join "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)))).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue = $null
    )

    if ($InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }
    return $DefaultValue
}

function Get-RunnerPlatformEnvironment {
    # Keep local Git and worker processes on the same non-secret platform allowlist.
    $allowedNames = @(
        'APPDATA', 'CI', 'COMPUTERNAME', 'ComSpec', 'GITHUB_ACTIONS',
        'GITHUB_EVENT_NAME', 'GITHUB_WORKSPACE', 'HOME', 'HOMEDRIVE',
        'HOMEPATH', 'LOCALAPPDATA', 'NO_PROXY', 'NUMBER_OF_PROCESSORS',
        'OS', 'Path', 'PATHEXT', 'PROCESSOR_ARCHITECTURE',
        'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION',
        'ProgramData', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432',
        'PSModulePath', 'RUNNER_ARCH', 'RUNNER_OS', 'RUNNER_TEMP',
        'SystemDrive', 'SystemRoot', 'TF_BUILD', 'USERDOMAIN', 'USERNAME',
        'USERPROFILE', 'windir'
    )
    $environment = [ordered]@{}
    foreach ($name in $allowedNames) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrEmpty($value)) {
            $environment[$name] = $value
        }
    }
    return $environment
}

function Get-RunnerGitEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$HooksPath,
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$CandidateTreeId
    )

    if ($CandidateTreeId -notmatch '\A[0-9a-f]{40}\z') {
        throw "Candidate tree ID is invalid: $CandidateTreeId"
    }
    $nullDevice = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'NUL' } else { '/dev/null' }
    return [ordered]@{
        GIT_CONFIG_GLOBAL = $nullDevice
        GIT_CONFIG_SYSTEM = $nullDevice
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_COUNT = '5'
        GIT_CONFIG_KEY_0 = 'init.defaultBranch'
        GIT_CONFIG_VALUE_0 = 'main'
        GIT_CONFIG_KEY_1 = 'core.hooksPath'
        GIT_CONFIG_VALUE_1 = [System.IO.Path]::GetFullPath($HooksPath)
        GIT_CONFIG_KEY_2 = 'commit.gpgSign'
        GIT_CONFIG_VALUE_2 = 'false'
        GIT_CONFIG_KEY_3 = 'tag.gpgSign'
        GIT_CONFIG_VALUE_3 = 'false'
        GIT_CONFIG_KEY_4 = 'core.autocrlf'
        GIT_CONFIG_VALUE_4 = 'false'
        GIT_TEMPLATE_DIR = [System.IO.Path]::GetFullPath($TemplatePath)
        GIT_ATTR_NOSYSTEM = '1'
        GIT_OPTIONAL_LOCKS = '0'
        GIT_TERMINAL_PROMPT = '0'
        GCM_INTERACTIVE = 'Never'
        WINSMUX_PESTER_CANDIDATE_TREE = $CandidateTreeId
    }
}

function Invoke-WithRunnerGitEnvironment {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    $callerEnvironment = [ordered]@{}
    foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
        $name = [string]$entry.Key
        if ($name -like 'GIT_*' -or $name -in @('GCM_INTERACTIVE', 'WINSMUX_PESTER_CANDIDATE_TREE')) {
            $callerEnvironment[$name] = [string]$entry.Value
        }
    }

    try {
        foreach ($name in @($callerEnvironment.Keys)) {
            Remove-Item -LiteralPath ('Env:' + [string]$name) -ErrorAction SilentlyContinue
        }
        foreach ($entry in $Environment.GetEnumerator()) {
            $name = [string]$entry.Key
            if ($name -notlike 'GIT_*' -and $name -notin @('GCM_INTERACTIVE', 'WINSMUX_PESTER_CANDIDATE_TREE')) {
                throw "Runner Git environment contains an unsupported variable: $name"
            }
            [Environment]::SetEnvironmentVariable($name, [string]$entry.Value, 'Process')
        }
        & $ScriptBlock
    } finally {
        foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
            $name = [string]$entry.Key
            if ($name -like 'GIT_*' -or $name -in @('GCM_INTERACTIVE', 'WINSMUX_PESTER_CANDIDATE_TREE')) {
                Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
            }
        }
        foreach ($entry in $callerEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
        }
    }
}

function Invoke-RunnerGit {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment,
        [System.Collections.IDictionary]$ExtraEnvironment = @{},
        [switch]$AllowFailure
    )

    $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $gitPath = if ($gitCommand.Path) { $gitCommand.Path } else { $gitCommand.Source }
    if ([string]::IsNullOrWhiteSpace($gitPath) -or -not (Test-Path -LiteralPath $gitPath -PathType Leaf)) {
        throw 'A concrete Git executable could not be resolved.'
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $gitPath
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.WorkingDirectory = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment.Clear()
    foreach ($entry in (Get-RunnerPlatformEnvironment).GetEnumerator()) {
        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
    }
    foreach ($entry in $ExtraEnvironment.GetEnumerator()) {
        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if (-not $AllowFailure -and $process.ExitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed ($($process.ExitCode)): $($stderr.Trim())"
        }
        return [PSCustomObject]@{
            ExitCode = [int]$process.ExitCode
            StdOut = $stdout.TrimEnd([char[]]"`r`n")
            StdErr = $stderr.TrimEnd([char[]]"`r`n")
        }
    } finally {
        $process.Dispose()
    }
}

function Resolve-RunnerGitPath {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$GitPath
    )

    if ([System.IO.Path]::IsPathRooted($GitPath)) {
        return [System.IO.Path]::GetFullPath($GitPath)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $GitPath))
}

function Get-RunnerCandidateTestPaths {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$CandidateTreeId,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
    )

    if ($CandidateTreeId -notmatch '\A[0-9a-f]{40}\z') {
        throw "Candidate tree ID is invalid: $CandidateTreeId"
    }
    $repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $repositoryPrefix = $repositoryRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $listed = Invoke-RunnerGit `
        -RepositoryRoot $repositoryRoot `
        -Arguments @('ls-tree', '-r', '--name-only', '-z', $CandidateTreeId, '--', 'tests') `
        -Environment $Environment
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in @($listed.StdOut -split "`0" | Where-Object { $_ })) {
        $normalized = ([string]$relativePath).Replace('\', '/')
        if ($normalized -notmatch '(?i)\Atests/(?:.+/)?[^/]+\.Tests\.ps1\z') {
            continue
        }
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $normalized))
        if (-not $fullPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Candidate Pester path escapes the repository root: $normalized"
        }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Candidate Pester test is missing from the working tree: $normalized"
        }
        if (-not $seen.Add($normalized)) {
            throw "Candidate Pester inventory contains a duplicate path: $normalized"
        }
        $paths.Add($fullPath)
    }
    return @($paths | Sort-Object)
}

function Get-RunnerFileState {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return [PSCustomObject]@{ Path = $fullPath; Exists = $false; Length = 0L; Sha256 = '' }
    }
    $item = Get-Item -LiteralPath $fullPath
    return [PSCustomObject]@{
        Path = $fullPath
        Exists = $true
        Length = [long]$item.Length
        Sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-RunnerTrackedBytesFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
    )

    $listed = Invoke-RunnerGit -RepositoryRoot $RepositoryRoot -Arguments @('ls-files', '-z', '--cached') -Environment $Environment
    $ledger = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in @($listed.StdOut -split "`0" | Where-Object { $_ })) {
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $relativePath))
        $repoPrefix = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if (-not $fullPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Tracked path escapes repository root: $relativePath"
        }
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $state = Get-RunnerFileState -Path $fullPath
            $ledger.Add("$relativePath`0$($state.Length)`0$($state.Sha256)")
        } else {
            $ledger.Add("$relativePath`0<absent-or-nonfile>")
        }
    }
    $diff = Invoke-RunnerGit -RepositoryRoot $RepositoryRoot -Arguments @('diff-files', '--raw', '--no-abbrev', '-z') -Environment $Environment -AllowFailure
    $ledger.Add("<diff-files>`0$($diff.ExitCode)`0$($diff.StdOut)")
    return Get-IdentityHash -Identities $ledger.ToArray()
}

function Get-RunnerRepositoryState {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
    )

    $indexText = (Invoke-RunnerGit -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--git-path', 'index') -Environment $Environment).StdOut
    $indexPath = Resolve-RunnerGitPath -RepositoryRoot $RepositoryRoot -GitPath $indexText
    $refResult = Invoke-RunnerGit -RepositoryRoot $RepositoryRoot -Arguments @('show-ref', '--head', '--dereference') -Environment $Environment -AllowFailure
    if ($refResult.ExitCode -notin @(0, 1)) { throw "git show-ref failed ($($refResult.ExitCode)): $($refResult.StdErr)" }
    $headResult = Invoke-RunnerGit -RepositoryRoot $RepositoryRoot -Arguments @('symbolic-ref', '-q', 'HEAD') -Environment $Environment -AllowFailure
    if ($headResult.ExitCode -notin @(0, 1)) { throw "git symbolic-ref failed ($($headResult.ExitCode)): $($headResult.StdErr)" }
    $configStates = [System.Collections.Generic.List[object]]::new()
    foreach ($configName in @('config', 'config.worktree')) {
        $pathText = (Invoke-RunnerGit -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--git-path', $configName) -Environment $Environment).StdOut
        $configStates.Add((Get-RunnerFileState -Path (Resolve-RunnerGitPath -RepositoryRoot $RepositoryRoot -GitPath $pathText)))
    }
    return [PSCustomObject]@{
        Index = Get-RunnerFileState -Path $indexPath
        TrackedBytesFingerprint = Get-RunnerTrackedBytesFingerprint -RepositoryRoot $RepositoryRoot -Environment $Environment
        RefsFingerprint = Get-IdentityHash -Identities @($refResult.StdOut, $headResult.StdOut)
        LocalConfigs = $configStates.ToArray()
    }
}

function Assert-RunnerFileStateEqual {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]$Expected.Path -cne [string]$Actual.Path -or
        [bool]$Expected.Exists -ne [bool]$Actual.Exists -or
        [long]$Expected.Length -ne [long]$Actual.Length -or
        [string]$Expected.Sha256 -cne [string]$Actual.Sha256) {
        throw "$Label changed during the Pester run."
    }
}

function New-RunnerCandidateContext {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ExecutionRoot,
        [string]$ProspectiveIndexPath
    )

    $repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $executionRoot = [System.IO.Path]::GetFullPath($ExecutionRoot)
    New-Item -ItemType Directory -Path $executionRoot -Force | Out-Null
    $hooksPath = Join-Path $executionRoot 'empty-hooks'
    $templatePath = Join-Path $executionRoot 'empty-template'
    New-Item -ItemType Directory -Path $hooksPath, $templatePath -Force | Out-Null

    $bootstrapEnvironment = Get-RunnerGitEnvironment -HooksPath $hooksPath -TemplatePath $templatePath -CandidateTreeId ('0' * 40)
    $sourceState = Get-RunnerRepositoryState -RepositoryRoot $repositoryRoot -Environment $bootstrapEnvironment
    $sourceIndexPath = if ([string]::IsNullOrWhiteSpace($ProspectiveIndexPath)) {
        [string]$sourceState.Index.Path
    } elseif ([System.IO.Path]::IsPathRooted($ProspectiveIndexPath)) {
        [System.IO.Path]::GetFullPath($ProspectiveIndexPath)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $ProspectiveIndexPath))
    }
    if (-not (Test-Path -LiteralPath $sourceIndexPath -PathType Leaf)) {
        throw "Candidate index does not exist: $sourceIndexPath"
    }
    $sourceIndexState = Get-RunnerFileState -Path $sourceIndexPath
    $candidateIndexPath = Join-Path $executionRoot 'candidate.index'
    if (Test-Path -LiteralPath $candidateIndexPath) {
        throw "Candidate index destination already exists: $candidateIndexPath"
    }
    Copy-Item -LiteralPath $sourceIndexPath -Destination $candidateIndexPath -ErrorAction Stop

    $candidateOverride = [ordered]@{ GIT_INDEX_FILE = $candidateIndexPath }
    $candidateTreeId = (Invoke-RunnerGit -RepositoryRoot $repositoryRoot -Arguments @('write-tree') -Environment $bootstrapEnvironment -ExtraEnvironment $candidateOverride).StdOut
    if ($candidateTreeId -notmatch '\A[0-9a-f]{40}\z') {
        throw "git write-tree returned an invalid candidate tree ID: $candidateTreeId"
    }
    $gitEnvironment = Get-RunnerGitEnvironment -HooksPath $hooksPath -TemplatePath $templatePath -CandidateTreeId $candidateTreeId
    $sourceDiff = Invoke-RunnerGit -RepositoryRoot $repositoryRoot -Arguments @('diff-files', '--quiet', '--no-ext-diff', '--ignore-submodules') -Environment $gitEnvironment -ExtraEnvironment $candidateOverride -AllowFailure
    if ($sourceDiff.ExitCode -eq 1) {
        throw 'Source tracked bytes do not match the candidate index.'
    }
    if ($sourceDiff.ExitCode -ne 0) {
        throw "Candidate/source comparison failed ($($sourceDiff.ExitCode)): $($sourceDiff.StdErr)"
    }
    $headInventory = Invoke-RunnerGit -RepositoryRoot $repositoryRoot -Arguments @('ls-tree', '-r', '--name-only', '-z', 'HEAD') -Environment $gitEnvironment -AllowFailure
    if ($headInventory.ExitCode -eq 128) {
        # Unborn HEAD has no committed paths that a staged deletion could leave behind.
    } elseif ($headInventory.ExitCode -ne 0) {
        throw "Candidate/HEAD path inventory failed ($($headInventory.ExitCode)): $($headInventory.StdErr)"
    } else {
        $candidateInventory = Invoke-RunnerGit -RepositoryRoot $repositoryRoot -Arguments @('ls-tree', '-r', '--name-only', '-z', $candidateTreeId) -Environment $gitEnvironment
        $candidatePaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($relativePath in @($candidateInventory.StdOut -split "`0" | Where-Object { $_ })) {
            [void]$candidatePaths.Add(([string]$relativePath).Replace('\', '/'))
        }
        $repositoryPrefix = $repositoryRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $leftovers = [System.Collections.Generic.List[string]]::new()
        foreach ($relativePath in @($headInventory.StdOut -split "`0" | Where-Object { $_ })) {
            $normalized = ([string]$relativePath).Replace('\', '/')
            if ($candidatePaths.Contains($normalized)) {
                continue
            }
            $fullPath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $normalized))
            if (-not $fullPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Staged-deletion path escapes repository root: $normalized"
            }
            if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                $leftovers.Add($normalized)
            }
        }
        if ($leftovers.Count -gt 0) {
            throw "Candidate index omits working-tree files that remain after staged deletion: $($leftovers -join ', ')"
        }
    }
    $objectPathText = (Invoke-RunnerGit -RepositoryRoot $repositoryRoot -Arguments @('rev-parse', '--git-path', 'objects') -Environment $gitEnvironment).StdOut
    $candidateEnvironment = [ordered]@{}
    foreach ($entry in $gitEnvironment.GetEnumerator()) {
        $candidateEnvironment[[string]$entry.Key] = [string]$entry.Value
    }
    $candidateEnvironment['GIT_INDEX_FILE'] = $candidateIndexPath

    $context = [PSCustomObject]@{
        RepositoryRoot = $repositoryRoot
        ExecutionRoot = $executionRoot
        HooksPath = $hooksPath
        TemplatePath = $templatePath
        CandidateTreeId = $candidateTreeId
        CandidateIndexPath = $candidateIndexPath
        CandidateSourceIndex = $sourceIndexState
        CandidateTrackedBytesFingerprint = Get-RunnerTrackedBytesFingerprint -RepositoryRoot $repositoryRoot -Environment $candidateEnvironment
        SourceObjectDirectory = Resolve-RunnerGitPath -RepositoryRoot $repositoryRoot -GitPath $objectPathText
        SourceState = $sourceState
        GitEnvironment = $gitEnvironment
        CandidateTestPaths = @(Get-RunnerCandidateTestPaths -RepositoryRoot $repositoryRoot -CandidateTreeId $candidateTreeId -Environment $gitEnvironment)
    }
    Assert-RunnerSourceState -Context $context
    return $context
}

function Assert-RunnerSourceState {
    param([Parameter(Mandatory = $true)]$Context)

    $actual = Get-RunnerRepositoryState -RepositoryRoot ([string]$Context.RepositoryRoot) -Environment $Context.GitEnvironment
    if ([string]$actual.TrackedBytesFingerprint -cne [string]$Context.SourceState.TrackedBytesFingerprint) {
        throw 'Runner source tracked bytes changed during the Pester run.'
    }
    Assert-RunnerFileStateEqual -Expected $Context.SourceState.Index -Actual $actual.Index -Label 'Runner source index'
    $candidateSourceNow = Get-RunnerFileState -Path ([string]$Context.CandidateSourceIndex.Path)
    Assert-RunnerFileStateEqual -Expected $Context.CandidateSourceIndex -Actual $candidateSourceNow -Label 'Runner candidate source index'
    $candidateEnvironment = [ordered]@{}
    foreach ($entry in $Context.GitEnvironment.GetEnumerator()) {
        $candidateEnvironment[[string]$entry.Key] = [string]$entry.Value
    }
    $candidateEnvironment['GIT_INDEX_FILE'] = [string]$Context.CandidateIndexPath
    $candidateTrackedBytesNow = Get-RunnerTrackedBytesFingerprint -RepositoryRoot ([string]$Context.RepositoryRoot) -Environment $candidateEnvironment
    if ([string]$candidateTrackedBytesNow -cne [string]$Context.CandidateTrackedBytesFingerprint) {
        throw 'Runner candidate tracked bytes changed during the Pester run.'
    }
    if ([string]$actual.RefsFingerprint -cne [string]$Context.SourceState.RefsFingerprint) {
        throw 'Runner source refs changed during the Pester run.'
    }
    if (@($actual.LocalConfigs).Count -ne @($Context.SourceState.LocalConfigs).Count) {
        throw 'Runner source local config set changed during the Pester run.'
    }
    for ($index = 0; $index -lt @($actual.LocalConfigs).Count; $index++) {
        Assert-RunnerFileStateEqual -Expected @($Context.SourceState.LocalConfigs)[$index] -Actual @($actual.LocalConfigs)[$index] -Label 'Runner source local config'
    }
}

function New-RunnerPrivateRepository {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $destinationPath = [System.IO.Path]::GetFullPath($DestinationPath)
    if ($destinationPath -eq [System.IO.Path]::GetFullPath([string]$Context.RepositoryRoot)) {
        throw 'Private Pester repository must not be the source repository.'
    }
    if (Test-Path -LiteralPath $destinationPath) {
        if (@(Get-ChildItem -LiteralPath $destinationPath -Force).Count -gt 0) {
            throw "Private Pester repository destination is not empty: $destinationPath"
        }
    } else {
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
    }

    [void](Invoke-RunnerGit -RepositoryRoot ([string]$Context.RepositoryRoot) -Arguments @('init', '--quiet', $destinationPath) -Environment $Context.GitEnvironment)
    $privateObjectsText = (Invoke-RunnerGit -RepositoryRoot $destinationPath -Arguments @('rev-parse', '--git-path', 'objects') -Environment $Context.GitEnvironment).StdOut
    $privateObjects = Resolve-RunnerGitPath -RepositoryRoot $destinationPath -GitPath $privateObjectsText
    $alternatesDirectory = Join-Path $privateObjects 'info'
    New-Item -ItemType Directory -Path $alternatesDirectory -Force | Out-Null
    $alternate = [System.IO.Path]::GetFullPath([string]$Context.SourceObjectDirectory).Replace('\', '/') + "`n"
    [System.IO.File]::WriteAllText((Join-Path $alternatesDirectory 'alternates'), $alternate, [System.Text.UTF8Encoding]::new($false))

    [void](Invoke-RunnerGit -RepositoryRoot $destinationPath -Arguments @('read-tree', [string]$Context.CandidateTreeId) -Environment $Context.GitEnvironment)
    [void](Invoke-RunnerGit -RepositoryRoot $destinationPath -Arguments @('checkout-index', '--all', '--force', '--index', '--ignore-skip-worktree-bits') -Environment $Context.GitEnvironment)
    $identityEnvironment = [ordered]@{
        GIT_AUTHOR_NAME = 'winsmux Pester fixture'
        GIT_AUTHOR_EMAIL = 'pester-fixture@example.invalid'
        GIT_AUTHOR_DATE = '2000-01-01T00:00:00Z'
        GIT_COMMITTER_NAME = 'winsmux Pester fixture'
        GIT_COMMITTER_EMAIL = 'pester-fixture@example.invalid'
        GIT_COMMITTER_DATE = '2000-01-01T00:00:00Z'
    }
    $commitId = (Invoke-RunnerGit -RepositoryRoot $destinationPath -Arguments @('commit-tree', [string]$Context.CandidateTreeId, '-m', 'winsmux Pester candidate') -Environment $Context.GitEnvironment -ExtraEnvironment $identityEnvironment).StdOut
    if ($commitId -notmatch '\A[0-9a-f]{40}\z') {
        throw "git commit-tree returned an invalid commit ID: $commitId"
    }
    [void](Invoke-RunnerGit -RepositoryRoot $destinationPath -Arguments @('update-ref', 'refs/heads/candidate', $commitId) -Environment $Context.GitEnvironment)
    [void](Invoke-RunnerGit -RepositoryRoot $destinationPath -Arguments @('symbolic-ref', 'HEAD', 'refs/heads/candidate') -Environment $Context.GitEnvironment)

    $privateIndexTree = (Invoke-RunnerGit -RepositoryRoot $destinationPath -Arguments @('write-tree') -Environment $Context.GitEnvironment).StdOut
    $privateHeadTree = (Invoke-RunnerGit -RepositoryRoot $destinationPath -Arguments @('rev-parse', 'HEAD^{tree}') -Environment $Context.GitEnvironment).StdOut
    if ($privateIndexTree -cne [string]$Context.CandidateTreeId -or $privateHeadTree -cne [string]$Context.CandidateTreeId) {
        throw 'Private Pester repository tree identity does not match the candidate tree.'
    }
    $privateDiff = Invoke-RunnerGit -RepositoryRoot $destinationPath -Arguments @('diff-files', '--quiet', '--no-ext-diff', '--ignore-submodules') -Environment $Context.GitEnvironment -AllowFailure
    if ($privateDiff.ExitCode -ne 0) {
        throw "Private Pester repository tracked bytes differ from its index ($($privateDiff.ExitCode))."
    }
    Assert-RunnerSourceState -Context $Context
    return $destinationPath
}

function Get-IsolatedChildEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$TempDirectory,
        [Parameter(Mandatory = $true)][string]$ProjectDirectory,
        [Parameter(Mandatory = $true)][string]$HooksPath,
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$CandidateTreeId
    )

    # Pass only non-secret platform/runtime context that tests need. In particular,
    # do not inherit credential carriers such as *_TOKEN, GIT_ASKPASS,
    # SSH_AUTH_SOCK, DOCKER_AUTH_CONFIG, or CI_JOB_JWT.
    $environment = Get-RunnerPlatformEnvironment
    $environment['TEMP'] = $TempDirectory
    $environment['TMP'] = $TempDirectory
    $environment['WINSMUX_ORCHESTRA_PROJECT_DIR'] = $ProjectDirectory
    $environment['WINSMUX_TEST_PROJECT_DIR'] = $ProjectDirectory
    $environment['NO_COLOR'] = '1'
    $gitEnvironment = Get-RunnerGitEnvironment -HooksPath $HooksPath -TemplatePath $TemplatePath -CandidateTreeId $CandidateTreeId
    foreach ($entry in $gitEnvironment.GetEnumerator()) {
        $environment[[string]$entry.Key] = [string]$entry.Value
    }
    return $environment
}

function Invoke-IsolatedPwshWorkers {
    param(
        [Parameter(Mandatory = $true)][string[]]$SpecPaths,
        [Parameter(Mandatory = $true)][string]$RunnerPath,
        [Parameter(Mandatory = $true)][string]$PwshPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][int]$ThrottleLimit,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $pending = [System.Collections.Generic.Queue[string]]::new()
    foreach ($specPath in $SpecPaths) {
        $pending.Enqueue($specPath)
    }
    $running = [System.Collections.Generic.List[object]]::new()
    $completed = [System.Collections.Generic.List[object]]::new()

    try {
        while (($pending.Count -gt 0) -or ($running.Count -gt 0)) {
            while (($pending.Count -gt 0) -and ($running.Count -lt $ThrottleLimit)) {
                $specPath = $pending.Dequeue()
                $spec = Get-Content -LiteralPath $specPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                $process = $null
                try {
                    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
                    $startInfo.FileName = $PwshPath
                    foreach ($argument in @(
                        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $RunnerPath,
                        '-WorkerSpecPath', $specPath,
                        '-WorkerTimeoutSeconds', [string]$TimeoutSeconds,
                        '-WorkerStdOutPath', [string]$spec.StdOutPath,
                        '-WorkerStdErrPath', [string]$spec.StdErrPath
                    )) {
                        $startInfo.ArgumentList.Add($argument)
                    }
                    $startInfo.WorkingDirectory = [System.IO.Path]::GetFullPath([string]$spec.WorkingDirectory)
                    $startInfo.UseShellExecute = $false
                    $startInfo.CreateNoWindow = $true
                    $startInfo.RedirectStandardInput = $true
                    $startInfo.Environment.Clear()
                    $childEnvironment = Get-IsolatedChildEnvironment `
                        -TempDirectory ([string]$spec.TempDirectory) `
                        -ProjectDirectory ([string]$spec.ProjectDirectory) `
                        -HooksPath ([string]$spec.HooksPath) `
                        -TemplatePath ([string]$spec.TemplatePath) `
                        -CandidateTreeId ([string]$spec.CandidateTreeId)
                    foreach ($entry in $childEnvironment.GetEnumerator()) {
                        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
                    }

                    $process = [System.Diagnostics.Process]::new()
                    $process.StartInfo = $startInfo
                    [void]$process.Start()
                    $process.StandardInput.Close()
                    $running.Add([PSCustomObject]@{
                        WorkerId = [string]$spec.WorkerId
                        SpecPath = $specPath
                        Process = $process
                        StdOutPath = [string]$spec.StdOutPath
                        StdErrPath = [string]$spec.StdErrPath
                        DeadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
                    })
                    $process = $null
                } catch {
                    if ($null -ne $process) {
                        try {
                            if (-not $process.HasExited) { $process.Kill($true) }
                        } catch {}
                        $process.Dispose()
                    }
                    $completed.Add([PSCustomObject]@{
                        WorkerId = [string]$spec.WorkerId
                        SpecPath = $specPath
                        ExitCode = -1
                        StdOut = ''
                        StdErr = ''
                        LaunchError = $_.Exception.Message
                    })
                }
            }

            foreach ($state in @($running)) {
                $timedOut = (-not $state.Process.HasExited) -and ([DateTime]::UtcNow -ge $state.DeadlineUtc)
                if ($timedOut) {
                    try { $state.Process.Kill($true) } catch {}
                }
                if ($timedOut -or $state.Process.HasExited) {
                    $stopped = $state.Process.WaitForExit(5000)
                    if (-not $stopped) {
                        try { $state.Process.Kill($true) } catch {}
                        $stopped = $state.Process.WaitForExit(5000)
                    }
                    $completed.Add([PSCustomObject]@{
                        WorkerId = [string]$state.WorkerId
                        SpecPath = [string]$state.SpecPath
                        ExitCode = $(if (-not $stopped) { -3 } elseif ($timedOut) { -2 } else { [int]$state.Process.ExitCode })
                        StdOut = $(if (Test-Path -LiteralPath $state.StdOutPath) { Get-Content -LiteralPath $state.StdOutPath -Raw -Encoding UTF8 } else { '' })
                        StdErr = $(if (Test-Path -LiteralPath $state.StdErrPath) { Get-Content -LiteralPath $state.StdErrPath -Raw -Encoding UTF8 } else { '' })
                        LaunchError = $(if (-not $stopped) { 'worker process tree could not be terminated' } elseif ($timedOut) { "worker exceeded ${TimeoutSeconds}s timeout" } else { '' })
                    })
                    $state.Process.Dispose()
                    [void]$running.Remove($state)
                }
            }
            if ($running.Count -gt 0) {
                Start-Sleep -Milliseconds 50
            }
        }
    } finally {
        foreach ($state in @($running)) {
            try {
                if (-not $state.Process.HasExited) { $state.Process.Kill($true) }
                if (-not $state.Process.WaitForExit(5000)) {
                    try { $state.Process.Kill($true) } catch {}
                    [void]$state.Process.WaitForExit(5000)
                }
            } catch {
            } finally {
                $state.Process.Dispose()
            }
        }
    }

    return $completed.ToArray()
}

function Invoke-PesterIsolated {
    param([Parameter(Mandatory = $true)]$Configuration)

    return & {
        # The runner's StrictMode must not leak into third-party test scopes.
        Set-StrictMode -Off
        Invoke-Pester -Configuration $Configuration
    }
}

function Get-PesterModule {
    $modulePath = Join-Path $PSScriptRoot 'winsmux-pester.psm1'
    Import-Module -Name $modulePath -Force -ErrorAction Stop | Out-Null
    $resolve = Resolve-WinsmuxPester571
    if ([string]$resolve.resolution_status -ne 'resolved') {
        return $null
    }
    return [pscustomobject]@{
        Name    = [string]'Pester'
        Version = [version]'5.7.1'
        Path    = [string]$resolve.manifest_path
        ModuleBase = [string]$resolve.module_base
    }
}

function Get-PrivatePesterFixtureRelativePaths {
    return @(
        'tests/HarnessContract.Tests.ps1'
        'tests/PublicSurfacePolicy.Tests.ps1'
    )
}

function Get-PesterExecutionPaths {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$PrivateRepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$CandidateTestPaths
    )

    $owners = @(Get-PrivatePesterFixtureRelativePaths)
    $paths = [System.Collections.Generic.List[string]]::new()
    $candidateRelativePaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidatePath in $CandidateTestPaths) {
        $fullPath = [System.IO.Path]::GetFullPath($candidatePath)
        $relative = [System.IO.Path]::GetRelativePath($RepositoryRoot, $fullPath).Replace('\', '/')
        if ($relative.StartsWith('../', [StringComparison]::Ordinal) -or [System.IO.Path]::IsPathRooted($relative)) {
            throw "Candidate Pester path escapes the source repository: $fullPath"
        }
        if (-not $candidateRelativePaths.Add($relative)) {
            throw "Candidate Pester execution path is duplicated: $relative"
        }
        if ($relative -in $owners) {
            $privatePath = Join-Path $PrivateRepositoryRoot $relative
            if (-not (Test-Path -LiteralPath $privatePath -PathType Leaf)) {
                throw "Private Pester owner path is missing: $relative"
            }
            $paths.Add([System.IO.Path]::GetFullPath($privatePath))
        } else {
            $paths.Add($fullPath)
        }
    }
    $missingOwners = @($owners | Where-Object { -not $candidateRelativePaths.Contains($_) })
    if ($missingOwners.Count -gt 0) {
        throw "Candidate Pester inventory is missing private fixture owners: $($missingOwners -join ', ')"
    }
    if ($paths.Count -eq 0) {
        throw 'Candidate Pester inventory is empty.'
    }
    return $paths.ToArray()
}

function Resolve-PesterLineFilter {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$LineFilter
    )

    $separator = $LineFilter.LastIndexOf(':')
    if ($separator -le 0 -or $separator -eq ($LineFilter.Length - 1)) {
        throw "Invalid Pester line filter: $LineFilter"
    }
    $lineNumber = 0
    if (-not [int]::TryParse($LineFilter.Substring($separator + 1), [ref]$lineNumber) -or $lineNumber -le 0) {
        throw "Invalid Pester line number: $LineFilter"
    }
    $pathText = $LineFilter.Substring(0, $separator)
    $fullPath = if ([System.IO.Path]::IsPathRooted($pathText)) {
        [System.IO.Path]::GetFullPath($pathText)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $pathText))
    }
    $repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $repositoryPrefix = $repositoryRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Pester line filter escapes the repository root: $LineFilter"
    }
    return [PSCustomObject]@{
        Path = $fullPath
        Line = $lineNumber
        Identity = '{0}:{1}' -f $fullPath.Replace('\', '/'), $lineNumber
        Filter = '{0}:{1}' -f $fullPath, $lineNumber
    }
}

function Convert-PesterExecutionLineFilters {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$PrivateRepositoryRoot,
        [string[]]$LineFilters = @()
    )

    $owners = @(Get-PrivatePesterFixtureRelativePaths)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    return @($LineFilters | ForEach-Object {
        $resolved = Resolve-PesterLineFilter -RepositoryRoot $RepositoryRoot -LineFilter ([string]$_)
        if (-not $seen.Add([string]$resolved.Identity)) {
            throw "Duplicate Pester line filter: $_"
        }
        $relative = [System.IO.Path]::GetRelativePath($RepositoryRoot, [string]$resolved.Path).Replace('\', '/')
        $executionPath = if ($relative -in $owners) {
            [System.IO.Path]::GetFullPath((Join-Path $PrivateRepositoryRoot $relative))
        } else {
            [string]$resolved.Path
        }
        '{0}:{1}' -f $executionPath, [int]$resolved.Line
    })
}

function Assert-PesterWorkerSpecCandidatePaths {
    param(
        [Parameter(Mandatory = $true)]$Spec,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
    )

    $repositoryRoot = [System.IO.Path]::GetFullPath([string]$Spec.RepositoryRoot)
    $repositoryPrefix = $repositoryRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $candidateTreeId = [string]$Spec.CandidateTreeId
    $candidatePaths = @(Get-RunnerCandidateTestPaths `
        -RepositoryRoot $repositoryRoot `
        -CandidateTreeId $candidateTreeId `
        -Environment $Environment)
    if ($candidatePaths.Count -eq 0) {
        throw 'Pester worker candidate test inventory is empty.'
    }
    $candidateSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidatePath in $candidatePaths) { [void]$candidateSet.Add([System.IO.Path]::GetFullPath($candidatePath)) }

    $specPaths = @($Spec.Paths | Where-Object { $null -ne $_ })
    if ($specPaths.Count -eq 0) {
        throw 'Pester worker spec has no test paths.'
    }
    $selectedPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($specPath in $specPaths) {
        $pathText = [string]$specPath
        if ([string]::IsNullOrWhiteSpace($pathText)) {
            throw 'Pester worker spec contains an empty test path.'
        }
        $fullPath = if ([System.IO.Path]::IsPathRooted($pathText)) {
            [System.IO.Path]::GetFullPath($pathText)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $pathText))
        }
        if (-not $fullPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Pester worker path escapes its repository: $pathText"
        }
        if (-not $candidateSet.Contains($fullPath)) {
            throw "Pester worker path is not in the candidate Pester test inventory: $pathText"
        }
        if (-not $selectedPaths.Add($fullPath)) {
            throw "Pester worker spec contains a duplicate path: $pathText"
        }
    }

    $lineFilters = @($Spec.LineFilters | Where-Object { $null -ne $_ })
    $seenFilters = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($lineFilter in $lineFilters) {
        $resolved = Resolve-PesterLineFilter -RepositoryRoot $repositoryRoot -LineFilter ([string]$lineFilter)
        if (-not $candidateSet.Contains([string]$resolved.Path)) {
            throw "Pester worker line filter is not in the candidate Pester test inventory: $lineFilter"
        }
        if (-not $selectedPaths.Contains([string]$resolved.Path)) {
            throw "Pester worker line filter is outside its declared paths: $lineFilter"
        }
        if (-not $seenFilters.Add([string]$resolved.Identity)) {
            throw "Duplicate Pester line filter: $lineFilter"
        }
    }

    $mode = [string]$Spec.Mode
    $requiresPrivateRepository = [bool](Get-ObjectProperty -InputObject $Spec -Name 'RequiresPrivateRepository' -DefaultValue $false)
    if ($mode -eq 'Discovery') {
        if ($requiresPrivateRepository -or $lineFilters.Count -gt 0 -or $selectedPaths.Count -ne $candidateSet.Count) {
            throw 'Pester discovery spec must contain the complete candidate inventory without line filters or private ownership.'
        }
        return
    }
    if ($mode -ne 'Test') {
        throw "Unsupported Pester worker mode: $mode"
    }

    $ownerSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($owner in Get-PrivatePesterFixtureRelativePaths) {
        [void]$ownerSet.Add([System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $owner)))
    }
    $selectedOwners = @($selectedPaths | Where-Object { $ownerSet.Contains([string]$_) })
    if ($requiresPrivateRepository) {
        if ($selectedPaths.Count -ne $ownerSet.Count -or $selectedOwners.Count -ne $ownerSet.Count) {
            throw 'Private Pester worker must own exactly both mutable fixture suites.'
        }
    } elseif ($selectedOwners.Count -gt 0) {
        throw 'Mutable Pester fixture suites cannot execute in the source repository.'
    }
}

function Test-PesterPathUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPrefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-SerialPesterSlice {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)]$PesterModule,
        [Parameter(Mandatory = $true)][string]$TestResultPath,
        [string[]]$LineFilters = @(),
        [string[]]$CoverageTargets = @(),
        [string]$CoverageReportPath = '',
        [switch]$EnableCoverage
    )

    if ($Paths.Count -eq 0) {
        throw 'Serial Pester slice received no test paths.'
    }

    $previousLocationPath = (Get-Location).Path
    $result = $null
    try {
        Push-Location -LiteralPath $WorkingDirectory
        if ($PesterModule.Version.Major -ge 5) {
            Import-Module $PesterModule.Path -Force -ErrorAction Stop | Out-Null
            $configuration = [PesterConfiguration]::Default
            $configuration.Run.Path = @($Paths)
            $configuration.Run.PassThru = $true
            $configuration.Run.Exit = $false
            $configuration.Output.Verbosity = 'None'
            $configuration.TestResult.Enabled = $true
            $configuration.TestResult.OutputFormat = 'NUnitXml'
            $configuration.TestResult.OutputPath = $TestResultPath
            if ($LineFilters.Count -gt 0) {
                $configuration.Filter.Line = @($LineFilters)
            }
            $configuration.CodeCoverage.Enabled = [bool]$EnableCoverage
            if ($EnableCoverage) {
                $configuration.CodeCoverage.Path = @($CoverageTargets)
                $configuration.CodeCoverage.OutputPath = $CoverageReportPath
            }
            $result = Invoke-PesterIsolated -Configuration $configuration
        } else {
            if ($LineFilters.Count -gt 0) {
                throw 'Pester line filters require Pester 5 or newer.'
            }
            if ($EnableCoverage) {
                $result = Invoke-Pester @($Paths) -PassThru -Quiet -CodeCoverage @($CoverageTargets) -OutputFormat NUnitXml -OutputFile $TestResultPath
            } else {
                $result = Invoke-Pester @($Paths) -PassThru -Quiet -OutputFormat NUnitXml -OutputFile $TestResultPath
            }
        }
    } finally {
        Set-Location -LiteralPath $previousLocationPath
    }
    return $result
}

function Get-PesterCoverageNumericCount {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        $value = Get-ObjectProperty -InputObject $InputObject -Name $name
        if ($null -eq $value) {
            continue
        }
        if ($value -is [byte] -or $value -is [int16] -or $value -is [uint16] -or
            $value -is [int] -or $value -is [uint32] -or $value -is [long] -or
            $value -is [uint64] -or $value -is [decimal] -or $value -is [double] -or
            $value -is [single] -or $value -is [int64]) {
            return [int]$value
        }
    }
    return $null
}

function Get-PesterCoverageCommandRecords {
    param($CodeCoverage)

    if ($null -eq $CodeCoverage) {
        return @()
    }

    $names = @($CodeCoverage.PSObject.Properties.Name)
    if ($names -contains 'Commands') {
        $commands = @($CodeCoverage.Commands)
        if ($commands.Count -gt 0) {
            return $commands
        }
    }

    $hits = @()
    $misses = @()
    if ($names -contains 'CommandsExecuted') {
        $hits = @($CodeCoverage.CommandsExecuted)
    } elseif ($names -contains 'HitCommands') {
        $hits = @($CodeCoverage.HitCommands)
    }
    if ($names -contains 'CommandsMissed') {
        $misses = @($CodeCoverage.CommandsMissed)
    } elseif ($names -contains 'MissedCommands') {
        $misses = @($CodeCoverage.MissedCommands)
    }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($command in $hits) {
        $records.Add([PSCustomObject]@{
            File = [string](Get-ObjectProperty -InputObject $command -Name 'File' -DefaultValue '')
            Line = [int](Get-ObjectProperty -InputObject $command -Name 'Line' -DefaultValue 0)
            Command = [string](Get-ObjectProperty -InputObject $command -Name 'Command' -DefaultValue '')
            Executed = $true
            HitCount = [int](Get-ObjectProperty -InputObject $command -Name 'HitCount' -DefaultValue 1)
        })
    }
    foreach ($command in $misses) {
        $records.Add([PSCustomObject]@{
            File = [string](Get-ObjectProperty -InputObject $command -Name 'File' -DefaultValue '')
            Line = [int](Get-ObjectProperty -InputObject $command -Name 'Line' -DefaultValue 0)
            Command = [string](Get-ObjectProperty -InputObject $command -Name 'Command' -DefaultValue '')
            Executed = $false
            HitCount = [int](Get-ObjectProperty -InputObject $command -Name 'HitCount' -DefaultValue 0)
        })
    }
    return $records.ToArray()
}

function Get-JaCoCoCoveredInstructionCount {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return -1
    }
    try {
        [xml]$document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($document.DocumentElement.LocalName -ne 'report') {
            return -1
        }
        $counter = $document.DocumentElement.SelectSingleNode('counter[@type="INSTRUCTION"]')
        if ($null -eq $counter) {
            return 0
        }
        return [int]$counter.GetAttribute('covered')
    } catch {
        return -1
    }
}

function Publish-SerialPesterCoverageXml {
    param(
        [string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        return
    }
    $existing = @(
        $Paths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }
    )
    if ($existing.Count -eq 0) {
        return
    }
    $source = $existing[0]
    if ($existing.Count -gt 1) {
        $bestCovered = -1
        foreach ($path in $existing) {
            $covered = Get-JaCoCoCoveredInstructionCount -Path $path
            if ($covered -gt $bestCovered) {
                $bestCovered = $covered
                $source = $path
            }
        }
    }
    $sourceFull = [System.IO.Path]::GetFullPath($source)
    $outputFull = [System.IO.Path]::GetFullPath($OutputPath)
    if ($sourceFull -eq $outputFull) {
        return
    }
    Copy-Item -LiteralPath $source -Destination $OutputPath -Force
}

function Merge-SerialPesterCodeCoverage {
    param($First, $Second)

    if ($null -eq $First) { return $Second }
    if ($null -eq $Second) { return $First }

    $firstCommands = @(Get-PesterCoverageCommandRecords -CodeCoverage $First)
    $secondCommands = @(Get-PesterCoverageCommandRecords -CodeCoverage $Second)
    if ($firstCommands.Count -eq 0 -and $secondCommands.Count -eq 0) {
        $analyzed = Get-PesterCoverageNumericCount -InputObject $First -Names @('CommandsAnalyzedCount', 'NumberOfCommandsAnalyzed', 'CommandsAnalyzed')
        $executed = Get-PesterCoverageNumericCount -InputObject $First -Names @('CommandsExecutedCount', 'NumberOfCommandsExecuted')
        $analyzed2 = Get-PesterCoverageNumericCount -InputObject $Second -Names @('CommandsAnalyzedCount', 'NumberOfCommandsAnalyzed', 'CommandsAnalyzed')
        $executed2 = Get-PesterCoverageNumericCount -InputObject $Second -Names @('CommandsExecutedCount', 'NumberOfCommandsExecuted')
        if ($null -eq $analyzed) { $analyzed = 0 }
        if ($null -eq $executed) { $executed = 0 }
        if ($null -eq $analyzed2) { $analyzed2 = 0 }
        if ($null -eq $executed2) { $executed2 = 0 }
        $mergedAnalyzed = [math]::Max([int]$analyzed, [int]$analyzed2)
        $mergedExecuted = [math]::Max([int]$executed, [int]$executed2)
        $percent = if ($mergedAnalyzed -le 0) { 0 } else { [math]::Round(($mergedExecuted / [double]$mergedAnalyzed) * 100, 2) }
        return [PSCustomObject]@{
            CoveragePercent = $percent
            NumberOfCommandsAnalyzed = $mergedAnalyzed
            NumberOfCommandsExecuted = $mergedExecuted
            CommandsAnalyzedCount = $mergedAnalyzed
            CommandsExecutedCount = $mergedExecuted
        }
    }

    $hits = @{}
    foreach ($command in @($firstCommands + $secondCommands)) {
        $file = [string](Get-ObjectProperty -InputObject $command -Name 'File' -DefaultValue '')
        $line = [int](Get-ObjectProperty -InputObject $command -Name 'Line' -DefaultValue 0)
        $commandText = [string](Get-ObjectProperty -InputObject $command -Name 'Command' -DefaultValue '')
        $key = '{0}|{1}|{2}' -f $file, $line, $commandText
        $executed = [bool](Get-ObjectProperty -InputObject $command -Name 'Executed' -DefaultValue $false)
        if (-not $executed) {
            $hitCount = Get-PesterCoverageNumericCount -InputObject $command -Names @('HitCount')
            if ($null -ne $hitCount -and [int]$hitCount -gt 0) {
                $executed = $true
            }
        }
        if (-not $hits.ContainsKey($key)) {
            $hits[$key] = $executed
        } elseif ($executed) {
            $hits[$key] = $true
        }
    }
    $analyzed = $hits.Count
    $executedCount = @($hits.Values | Where-Object { $_ }).Count
    $percent = if ($analyzed -le 0) { 0 } else { [math]::Round(($executedCount / [double]$analyzed) * 100, 2) }
    return [PSCustomObject]@{
        CoveragePercent = $percent
        NumberOfCommandsAnalyzed = $analyzed
        NumberOfCommandsExecuted = $executedCount
        CommandsAnalyzedCount = $analyzed
        CommandsExecutedCount = $executedCount
    }
}

function Merge-SerialPesterSliceResults {
    param([Parameter(Mandatory = $true)][object[]]$Results)

    $results = @($Results | Where-Object { $null -ne $_ })
    if ($results.Count -eq 0) {
        throw 'Serial Pester produced no slice results.'
    }
    if ($results.Count -eq 1) {
        return $results[0]
    }

    $passed = 0
    $failed = 0
    $total = 0
    $skipped = 0
    $notRun = 0
    $failedBlocks = 0
    $failedContainers = 0
    $tests = [System.Collections.Generic.List[object]]::new()
    $coverage = $null
    foreach ($result in $results) {
        $passed += [int](Get-ObjectProperty -InputObject $result -Name 'PassedCount' -DefaultValue 0)
        $failed += [int](Get-ObjectProperty -InputObject $result -Name 'FailedCount' -DefaultValue 0)
        $total += [int](Get-ObjectProperty -InputObject $result -Name 'TotalCount' -DefaultValue 0)
        $skipped += [int](Get-ObjectProperty -InputObject $result -Name 'SkippedCount' -DefaultValue 0)
        $notRun += [int](Get-ObjectProperty -InputObject $result -Name 'NotRunCount' -DefaultValue 0)
        $failedBlocks += [int](Get-ObjectProperty -InputObject $result -Name 'FailedBlocksCount' -DefaultValue 0)
        $failedContainers += [int](Get-ObjectProperty -InputObject $result -Name 'FailedContainersCount' -DefaultValue 0)
        foreach ($test in @($result.Tests)) {
            $tests.Add($test)
        }
        $sliceCoverage = $null
        if ($result.PSObject.Properties.Name -contains 'CodeCoverage') {
            $sliceCoverage = $result.CodeCoverage
        }
        $coverage = Merge-SerialPesterCodeCoverage -First $coverage -Second $sliceCoverage
    }
    $outcome = if (($failed -gt 0) -or ($failedBlocks -gt 0) -or ($failedContainers -gt 0)) {
        'Failed'
    } else {
        'Passed'
    }
    return [PSCustomObject]@{
        PassedCount = $passed
        FailedCount = $failed
        TotalCount = $total
        SkippedCount = $skipped
        NotRunCount = $notRun
        FailedBlocksCount = $failedBlocks
        FailedContainersCount = $failedContainers
        Result = $outcome
        Tests = $tests.ToArray()
        CodeCoverage = $coverage
    }
}

function Invoke-SerialSuite {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$PrivateRepositoryRoot,
        [Parameter(Mandatory = $true)][string]$TestResultPath,
        [Parameter(Mandatory = $true)][string]$CoverageReportPath,
        [Parameter(Mandatory = $true)]$PesterModule,
        [Parameter(Mandatory = $true)][string[]]$CandidateTestPaths,
        [string[]]$LineFilters = @(),
        [switch]$EnableCoverage
    )

    $coverageTargets = @()
    if ($EnableCoverage) {
        $coverageTargets = @(Get-CoverageTargets -RepositoryRoot $RepositoryRoot -TestPaths $CandidateTestPaths)
        if ($coverageTargets.Count -eq 0) {
            throw 'Pester coverage was requested, but no coverage targets were found.'
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $executionPaths = @(Get-PesterExecutionPaths `
        -RepositoryRoot $RepositoryRoot `
        -PrivateRepositoryRoot $PrivateRepositoryRoot `
        -CandidateTestPaths $CandidateTestPaths)
    $executionLineFilters = @()
    if ($LineFilters.Count -gt 0) {
        $executionLineFilters = @(Convert-PesterExecutionLineFilters `
            -RepositoryRoot $RepositoryRoot `
            -PrivateRepositoryRoot $PrivateRepositoryRoot `
            -LineFilters $LineFilters)
    }

    $mutablePaths = [System.Collections.Generic.List[string]]::new()
    $immutablePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $executionPaths) {
        if (Test-PesterPathUnderRoot -Path $path -Root $PrivateRepositoryRoot) {
            $mutablePaths.Add($path)
        } else {
            $immutablePaths.Add($path)
        }
    }
    $mutableFilters = [System.Collections.Generic.List[string]]::new()
    $immutableFilters = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $executionLineFilters) {
        $separator = ([string]$line).LastIndexOf(':')
        $filterPath = if ($separator -gt 0) { ([string]$line).Substring(0, $separator) } else { [string]$line }
        if (Test-PesterPathUnderRoot -Path $filterPath -Root $PrivateRepositoryRoot) {
            $mutableFilters.Add([string]$line)
        } else {
            $immutableFilters.Add([string]$line)
        }
    }
    if ($executionLineFilters.Count -gt 0) {
        if ($mutableFilters.Count -eq 0) { $mutablePaths.Clear() }
        if ($immutableFilters.Count -eq 0) { $immutablePaths.Clear() }
    }
    if (($mutablePaths.Count -eq 0) -and ($immutablePaths.Count -eq 0)) {
        throw 'Serial Pester inventory has no executable slices.'
    }

    $previousLocationPath = (Get-Location).Path
    $sliceResults = [System.Collections.Generic.List[object]]::new()
    $nunitPaths = [System.Collections.Generic.List[string]]::new()
    $coverageXmlPaths = [System.Collections.Generic.List[string]]::new()
    $result = $null
    try {
        if ($mutablePaths.Count -gt 0) {
            $mutableResultPath = if ($immutablePaths.Count -gt 0) { "$TestResultPath.mutable.xml" } else { $TestResultPath }
            $mutableCoveragePath = if ($immutablePaths.Count -gt 0) { "$CoverageReportPath.mutable.xml" } else { $CoverageReportPath }
            $sliceResults.Add((Invoke-SerialPesterSlice `
                -WorkingDirectory $PrivateRepositoryRoot `
                -Paths @($mutablePaths) `
                -PesterModule $PesterModule `
                -TestResultPath $mutableResultPath `
                -LineFilters @($mutableFilters) `
                -CoverageTargets $coverageTargets `
                -CoverageReportPath $mutableCoveragePath `
                -EnableCoverage:$EnableCoverage))
            $nunitPaths.Add($mutableResultPath)
            if ($EnableCoverage) {
                $coverageXmlPaths.Add($mutableCoveragePath)
            }
        }
        if ($immutablePaths.Count -gt 0) {
            $immutableResultPath = if ($mutablePaths.Count -gt 0) { "$TestResultPath.immutable.xml" } else { $TestResultPath }
            $immutableCoveragePath = if ($mutablePaths.Count -gt 0) { "$CoverageReportPath.immutable.xml" } else { $CoverageReportPath }
            $sliceResults.Add((Invoke-SerialPesterSlice `
                -WorkingDirectory $RepositoryRoot `
                -Paths @($immutablePaths) `
                -PesterModule $PesterModule `
                -TestResultPath $immutableResultPath `
                -LineFilters @($immutableFilters) `
                -CoverageTargets $coverageTargets `
                -CoverageReportPath $immutableCoveragePath `
                -EnableCoverage:$EnableCoverage))
            $nunitPaths.Add($immutableResultPath)
            if ($EnableCoverage) {
                $coverageXmlPaths.Add($immutableCoveragePath)
            }
        }
        $result = Merge-SerialPesterSliceResults -Results @($sliceResults)
        if ($nunitPaths.Count -gt 1) {
            $mergedFailed = [int](Get-ObjectProperty -InputObject $result -Name 'FailedCount' -DefaultValue 0)
            $mergedSkipped = [int](Get-ObjectProperty -InputObject $result -Name 'SkippedCount' -DefaultValue 0)
            $mergedNotRun = [int](Get-ObjectProperty -InputObject $result -Name 'NotRunCount' -DefaultValue 0)
            $mergedTotal = [int](Get-ObjectProperty -InputObject $result -Name 'TotalCount' -DefaultValue 0)
            $mergedBlocks = [int](Get-ObjectProperty -InputObject $result -Name 'FailedBlocksCount' -DefaultValue 0)
            $mergedContainers = [int](Get-ObjectProperty -InputObject $result -Name 'FailedContainersCount' -DefaultValue 0)
            Merge-NUnitResults `
                -Paths @($nunitPaths) `
                -OutputPath $TestResultPath `
                -TotalCount $mergedTotal `
                -FailedCount $mergedFailed `
                -ErrorsCount ($mergedBlocks + $mergedContainers) `
                -SkippedCount $mergedSkipped `
                -NotRunCount $mergedNotRun `
                -InconclusiveCount 0 `
                -DurationSeconds $stopwatch.Elapsed.TotalSeconds
        }
        if ($EnableCoverage) {
            Publish-SerialPesterCoverageXml -Paths @($coverageXmlPaths) -OutputPath $CoverageReportPath
        }
    } finally {
        Set-Location -LiteralPath $previousLocationPath
    }
    $stopwatch.Stop()
    $selectedTests = if ($executionLineFilters.Count -gt 0) {
        $selectedLines = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($line in $executionLineFilters) {
            [void]$selectedLines.Add(([string]$line).Replace('\', '/'))
        }
        @($result.Tests | Where-Object {
            $lineIdentity = '{0}:{1}' -f ([string]$_.ScriptBlock.File).Replace('\', '/'), [int]$_.StartLine
            $selectedLines.Contains($lineIdentity)
        })
    } else {
        @($result.Tests)
    }
    if ($executionLineFilters.Count -gt 0) {
        $matchedLines = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($test in @($selectedTests)) {
            $lineIdentity = '{0}:{1}' -f ([string]$test.ScriptBlock.File).Replace('\', '/'), [int]$test.StartLine
            [void]$matchedLines.Add($lineIdentity)
        }
        $unmatched = @($executionLineFilters | Where-Object {
            -not $matchedLines.Contains(([string]$_).Replace('\', '/'))
        })
        if ($unmatched.Count -gt 0) {
            throw "Pester line filters matched no executed test: $($unmatched -join ', ')"
        }
    }

    return [PSCustomObject]@{
        Result = $result
        SelectedTests = @($selectedTests)
        DurationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    }
}

function Invoke-PesterWorker {
    param([Parameter(Mandatory = $true)][string]$SpecPath)

    $spec = Get-Content -LiteralPath $SpecPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $candidateTreeId = [string](Get-ObjectProperty -InputObject $spec -Name 'CandidateTreeId' -DefaultValue '')
    if ($candidateTreeId -notmatch '\A[0-9a-f]{40}\z') {
        throw 'Pester worker spec has no valid candidate tree ID.'
    }
    if ([Environment]::GetEnvironmentVariable('WINSMUX_PESTER_CANDIDATE_TREE', 'Process') -cne $candidateTreeId) {
        throw 'Pester worker candidate tree ID does not match its controlled environment.'
    }
    $expectedCount = [int](Get-ObjectProperty -InputObject $spec -Name 'ExpectedCount' -DefaultValue -1)
    if ($expectedCount -lt 0) {
        throw 'Pester worker spec has no valid expected test count.'
    }
    $requiresPrivateRepository = [bool](Get-ObjectProperty -InputObject $spec -Name 'RequiresPrivateRepository' -DefaultValue $false)
    $workerGitEnvironment = Get-RunnerGitEnvironment -HooksPath ([string]$spec.HooksPath) -TemplatePath ([string]$spec.TemplatePath) -CandidateTreeId $candidateTreeId
    New-Item -ItemType Directory -Path $spec.TempDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $spec.ProjectDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $spec.ResultPath) -Force | Out-Null

    try {
        Assert-PesterWorkerSpecCandidatePaths -Spec $spec -Environment $workerGitEnvironment
        if ($requiresPrivateRepository) {
            $workerTreeId = (Invoke-RunnerGit -RepositoryRoot ([string]$spec.RepositoryRoot) -Arguments @('rev-parse', 'HEAD^{tree}') -Environment $workerGitEnvironment).StdOut
            if ($workerTreeId -cne $candidateTreeId) {
                throw 'Private Pester worker repository does not match the candidate tree ID.'
            }
        }
        if ([string]$spec.Mode -eq 'Discovery') {
            $discovery = Invoke-TestDiscovery -Paths @($spec.Paths) -PesterModulePath ([string]$spec.PesterModulePath)
            $tests = @($discovery.Tests | ForEach-Object {
                $pathParts = @($_.Path | ForEach-Object { [string]$_ })
                $expandedName = if ($_.PSObject.Properties.Name -contains 'ExpandedName') { [string]$_.ExpandedName } else { [string]$_.Name }
                [PSCustomObject]@{
                    file = [System.IO.Path]::GetFullPath([string]$_.ScriptBlock.File)
                    startLine = [int]$_.StartLine
                    identity = Get-TestIdentity -Test $_
                    topLevelName = $(if ($pathParts.Count -gt 0) { [string]$pathParts[0] } else { $expandedName })
                    fullNameCandidates = @(
                        $expandedName
                        ([string]$_.ExpandedPath)
                        ($pathParts -join ' ')
                        ($pathParts -join ' > ')
                    )
                    skipped = $(
                        (($_.PSObject.Properties.Name -contains 'Skipped') -and [bool]$_.Skipped) -or
                        (($_.PSObject.Properties.Name -contains 'Skip') -and [bool]$_.Skip)
                    )
                }
            })
            $payload = [ordered]@{
                mode = 'discovery'
                workerId = [string]$spec.WorkerId
                candidateTreeId = $candidateTreeId
                total = [int]$discovery.TotalCount
                failedBlocks = [int]$discovery.FailedBlocksCount
                failedContainers = [int]$discovery.FailedContainersCount
                identityHash = Get-IdentityHash -Identities @($tests.identity)
                tests = $tests
            }
            $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $spec.ResultPath -Encoding UTF8
            return 0
        }

        Import-Module ([string]$spec.PesterModulePath) -Force -ErrorAction Stop | Out-Null
        $configuration = [PesterConfiguration]::Default
        $configuration.Run.Path = @($spec.Paths)
        $configuration.Run.PassThru = $true
        $configuration.Run.Exit = $false
        $configuration.Output.Verbosity = 'None'
        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = 'NUnitXml'
        $configuration.TestResult.OutputPath = [string]$spec.NUnitPath
        $configuration.CodeCoverage.Enabled = $false
        if (@($spec.LineFilters).Count -gt 0) {
            $configuration.Filter.Line = @($spec.LineFilters)
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-PesterIsolated -Configuration $configuration
        $stopwatch.Stop()

        $selectedTests = if (@($spec.LineFilters).Count -gt 0) {
            $selectedLines = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($line in @($spec.LineFilters)) { [void]$selectedLines.Add(([string]$line).Replace('\', '/')) }
            @($result.Tests | Where-Object {
                $lineIdentity = '{0}:{1}' -f ([string]$_.ScriptBlock.File).Replace('\', '/'), [int]$_.StartLine
                $selectedLines.Contains($lineIdentity)
            })
        } else {
            @($result.Tests)
        }
        $selectedTests = @($selectedTests)
        $identities = @($selectedTests | ForEach-Object { Get-TestIdentity -Test $_ })
        $passed = @($selectedTests | Where-Object { [string]$_.Result -eq 'Passed' }).Count
        $failed = @($selectedTests | Where-Object { [string]$_.Result -eq 'Failed' }).Count
        $skipped = @($selectedTests | Where-Object { [string]$_.Result -eq 'Skipped' }).Count
        $notRun = @($selectedTests | Where-Object { [string]$_.Result -eq 'NotRun' }).Count
        $inconclusive = @($selectedTests | Where-Object { [string]$_.Result -eq 'Inconclusive' }).Count
        $payload = [ordered]@{
            workerId = [string]$spec.WorkerId
            candidateTreeId = $candidateTreeId
            requiresPrivateRepository = $requiresPrivateRepository
            expectedCount = $expectedCount
            total = [int]$selectedTests.Count
            passed = [int]$passed
            failed = [int]$failed
            skipped = [int]$skipped
            notRun = [int]$notRun
            inconclusive = [int]$inconclusive
            failedBlocks = [int]$result.FailedBlocksCount
            failedContainers = [int]$result.FailedContainersCount
            result = [string]$result.Result
            durationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
            pesterVersion = [string]$result.Version
            nunitPath = [string]$spec.NUnitPath
            tempDirectory = [string]$spec.TempDirectory
            projectDirectory = [string]$spec.ProjectDirectory
            identityHash = Get-IdentityHash -Identities $identities
            identities = $identities
        }
        $countMismatch = $payload.total -ne $expectedCount
        if ($countMismatch) {
            $payload['harnessError'] = "Pester worker expected $expectedCount tests, got $($payload.total)."
        }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $spec.ResultPath -Encoding UTF8

        if ($countMismatch) {
            return 2
        }
        if (($payload.failed -eq 0) -and ($payload.failedBlocks -eq 0) -and ($payload.failedContainers -eq 0)) {
            return 0
        }
        return 1
    } catch {
        $failure = [ordered]@{
            workerId = [string]$spec.WorkerId
            candidateTreeId = $candidateTreeId
            requiresPrivateRepository = $requiresPrivateRepository
            expectedCount = $expectedCount
            total = 0
            passed = 0
            failed = 0
            skipped = 0
            notRun = 0
            inconclusive = 0
            failedBlocks = 0
            failedContainers = 1
            result = 'HarnessError'
            durationSeconds = 0
            pesterVersion = ''
            nunitPath = [string]$spec.NUnitPath
            tempDirectory = [string]$spec.TempDirectory
            projectDirectory = [string]$spec.ProjectDirectory
            identityHash = ''
            identities = @()
            harnessError = $_.Exception.Message
        }
        $failure | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $spec.ResultPath -Encoding UTF8
        [Console]::Error.WriteLine(('Pester worker {0} failed: {1}' -f $spec.WorkerId, $_.Exception.Message))
        return 2
    }
}

function Invoke-TestDiscovery {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$PesterModulePath
    )

    if ($Paths.Count -eq 0) {
        throw 'Pester discovery received an empty candidate test inventory.'
    }
    Import-Module $PesterModulePath -Force -ErrorAction Stop | Out-Null
    $configuration = [PesterConfiguration]::Default
    $configuration.Run.Path = @($Paths)
    $configuration.Run.PassThru = $true
    $configuration.Run.Exit = $false
    $configuration.Run.SkipRun = $true
    $configuration.Output.Verbosity = 'None'
    $configuration.TestResult.Enabled = $false
    $configuration.CodeCoverage.Enabled = $false
    $result = Invoke-PesterIsolated -Configuration $configuration

    if (($result.FailedBlocksCount -gt 0) -or ($result.FailedContainersCount -gt 0)) {
        throw "Pester discovery failed: blocks=$($result.FailedBlocksCount) containers=$($result.FailedContainersCount)"
    }
    return $result
}

function Get-BridgeShards {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $workflowPath = Join-Path $RepositoryRoot '.github\workflows\test.yml'
    if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) {
        throw "Bridge shard source is missing: $workflowPath"
    }
    $workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
    $matches = [regex]::Matches(
        $workflow,
        '(?ms)^\s{10}- name:\s+(?<name>bridge-[^\r\n]+)\r?\n(?<body>.*?)(?=^\s{10}- name:|^\s{6}[a-zA-Z_-]+:|\z)'
    )
    $shards = [System.Collections.Generic.List[object]]::new()
    $owners = @{}
    foreach ($match in $matches) {
        $name = [string]$match.Groups['name'].Value
        $pathsMatch = [regex]::Match($match.Groups['body'].Value, '(?m)^\s+paths:\s*(?<value>[^\r\n]+)$')
        if (-not $pathsMatch.Success) {
            throw "Bridge shard $name has no paths entry."
        }
        $patterns = @($pathsMatch.Groups['value'].Value.Trim().Trim('''', '"') -split ';' |
            ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $paths = [System.Collections.Generic.List[string]]::new()
        foreach ($pattern in $patterns) {
            $resolved = @(Resolve-Path -Path (Join-Path $RepositoryRoot $pattern) -ErrorAction Stop)
            if ($resolved.Count -eq 0) {
                throw "Bridge shard $name pattern matched no files: $pattern"
            }
            foreach ($item in $resolved) {
                $path = [System.IO.Path]::GetFullPath($item.ProviderPath)
                if ($owners.ContainsKey($path)) {
                    throw "Bridge test file $path belongs to both $($owners[$path]) and $name."
                }
                $owners[$path] = $name
                $paths.Add($path)
            }
        }
        $shards.Add([PSCustomObject]@{
            Name = $name
            Paths = @($paths | Sort-Object -Unique)
        })
    }
    if ($shards.Count -ne 13) {
        throw "Expected 13 bridge CI shards, found $($shards.Count)."
    }
    $actualBridgeFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'tests\bridge') -Filter '*.Tests.ps1' -File -Recurse |
        ForEach-Object { [System.IO.Path]::GetFullPath($_.FullName) } | Sort-Object -Unique)
    $assignedBridgeFiles = @($owners.Keys | Sort-Object -Unique)
    $unassigned = @($actualBridgeFiles | Where-Object { $_ -notin $assignedBridgeFiles })
    $missing = @($assignedBridgeFiles | Where-Object { $_ -notin $actualBridgeFiles })
    if ($unassigned.Count -gt 0 -or $missing.Count -gt 0) {
        throw "Bridge shard coverage mismatch. unassigned=[$($unassigned -join ', ')] missing=[$($missing -join ', ')]"
    }
    return $shards.ToArray()
}

function New-PesterWorkUnits {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$CandidateRepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$CandidateTestPaths,
        [Parameter(Mandatory = $true)]$DiscoveryResult
    )

    $testFiles = @($CandidateTestPaths | ForEach-Object { [System.IO.Path]::GetFullPath($_) } | Sort-Object -Unique)
    if ($testFiles.Count -eq 0) {
        throw 'Candidate Pester inventory is empty.'
    }
    if ($testFiles.Count -ne $CandidateTestPaths.Count) {
        throw 'Candidate Pester inventory contains duplicate paths.'
    }

    $candidateFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($testFile in $testFiles) { [void]$candidateFiles.Add($testFile) }
    $testsByFile = @{}
    foreach ($test in $DiscoveryResult.tests) {
        $file = [System.IO.Path]::GetFullPath([string]$test.file)
        if (-not $candidateFiles.Contains($file)) {
            throw "Pester discovery returned a test outside the candidate inventory: $file"
        }
        if (-not $testsByFile.ContainsKey($file)) {
            $testsByFile[$file] = [System.Collections.Generic.List[object]]::new()
        }
        $testsByFile[$file].Add($test)
    }

    $units = [System.Collections.Generic.List[object]]::new()
    $shards = @(Get-BridgeShards -RepositoryRoot $CandidateRepositoryRoot | ForEach-Object {
        $candidateShard = $_
        $sourcePaths = @($candidateShard.Paths | ForEach-Object {
            $relative = [System.IO.Path]::GetRelativePath($CandidateRepositoryRoot, [string]$_)
            if ($relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)", [StringComparison]::Ordinal) -or
                [System.IO.Path]::IsPathRooted($relative)) {
                throw "Candidate bridge shard path escapes its repository: $_"
            }
            $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $relative))
            if (-not $candidateFiles.Contains($sourcePath)) {
                throw "Candidate bridge shard path is absent from the candidate test inventory: $relative"
            }
            $sourcePath
        })
        [PSCustomObject]@{ Name = [string]$candidateShard.Name; Paths = $sourcePaths }
    })
    $bridgePaths = @($shards.Paths | ForEach-Object { [System.IO.Path]::GetFullPath([string]$_) } | Sort-Object -Unique)
    $privatePaths = @(Get-PrivatePesterFixtureRelativePaths | ForEach-Object {
        [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $_))
    })
    if (@($privatePaths | Where-Object { $_ -in $bridgePaths }).Count -gt 0) {
        throw 'A private Pester fixture owner is also assigned to a bridge shard.'
    }
    foreach ($file in $testFiles | Where-Object {
        $candidate = [System.IO.Path]::GetFullPath($_)
        $candidate -notin $bridgePaths -and $candidate -notin $privatePaths
    }) {
        $fullPath = [System.IO.Path]::GetFullPath($file)
        if (-not $testsByFile.ContainsKey($fullPath)) {
            throw "Pester discovery did not return tests for $fullPath"
        }
        $units.Add([PSCustomObject]@{
            WorkerId = 'file-' + [System.IO.Path]::GetFileNameWithoutExtension($fullPath).ToLowerInvariant().Replace('.', '-')
            Paths = @($fullPath)
            LineFilters = @()
            ExpectedCount = [int]$testsByFile[$fullPath].Count
            RequiresPrivateRepository = $false
        })
    }

    $privateCount = 0
    foreach ($privatePath in $privatePaths) {
        if (-not $testsByFile.ContainsKey($privatePath)) {
            throw "Pester discovery did not return private fixture tests for $privatePath"
        }
        $privateCount += [int]$testsByFile[$privatePath].Count
    }
    if ($privateCount -eq 0) {
        throw 'Private Pester fixture resolved to zero tests.'
    }
    $units.Add([PSCustomObject]@{
        WorkerId = 'private-git-fixture'
        Paths = $privatePaths
        LineFilters = @()
        ExpectedCount = $privateCount
        RequiresPrivateRepository = $true
    })

    foreach ($shard in $shards) {
        $count = 0
        foreach ($path in $shard.Paths) {
            $fullPath = [System.IO.Path]::GetFullPath([string]$path)
            if (-not $testsByFile.ContainsKey($fullPath)) {
                throw "Pester discovery did not return bridge tests for $fullPath"
            }
            $count += [int]$testsByFile[$fullPath].Count
        }
        if ($count -eq 0) {
            throw "Bridge CI shard $($shard.Name) resolved to zero tests."
        }
        $units.Add([PSCustomObject]@{
            WorkerId = [string]$shard.Name
            Paths = @($shard.Paths)
            LineFilters = @()
            ExpectedCount = $count
            RequiresPrivateRepository = $false
        })
    }

    $expected = [int](($units | Measure-Object ExpectedCount -Sum).Sum)
    if ($expected -ne [int]$DiscoveryResult.total) {
        throw "Pester work-unit coverage mismatch: units=$expected discovery=$($DiscoveryResult.total)"
    }
    return $units.ToArray()
}

function Select-PesterWorkUnitsByLineFilter {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][object[]]$Units,
        [Parameter(Mandatory = $true)]$DiscoveryResult,
        [string[]]$LineFilters = @()
    )

    if ($LineFilters.Count -eq 0) {
        return [PSCustomObject]@{
            Units = $Units
            Tests = @($DiscoveryResult.tests)
            Total = [int]$DiscoveryResult.total
        }
    }

    $requested = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($lineFilter in $LineFilters) {
        $resolved = Resolve-PesterLineFilter -RepositoryRoot $RepositoryRoot -LineFilter ([string]$lineFilter)
        if ($requested.ContainsKey([string]$resolved.Identity)) {
            throw "Duplicate Pester line filter: $lineFilter"
        }
        $requested[[string]$resolved.Identity] = $resolved
    }

    $selectedTests = [System.Collections.Generic.List[object]]::new()
    $matched = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($test in @($DiscoveryResult.tests)) {
        $identity = '{0}:{1}' -f ([System.IO.Path]::GetFullPath([string]$test.file)).Replace('\', '/'), [int]$test.startLine
        if ($requested.ContainsKey($identity)) {
            $selectedTests.Add($test)
            [void]$matched.Add($identity)
        }
    }
    $unmatched = @($requested.Keys | Where-Object { -not $matched.Contains([string]$_) })
    if ($unmatched.Count -gt 0) {
        throw "Pester line filters matched no discovered test: $($unmatched -join ', ')"
    }

    $boundedUnits = [System.Collections.Generic.List[object]]::new()
    foreach ($unit in $Units) {
        $unitPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in @($unit.Paths)) {
            [void]$unitPaths.Add([System.IO.Path]::GetFullPath([string]$path))
        }
        $unitTests = @($selectedTests | Where-Object {
            $unitPaths.Contains([System.IO.Path]::GetFullPath([string]$_.file))
        })
        if ($unitTests.Count -eq 0) {
            continue
        }
        $unitLineFilters = @($unitTests | ForEach-Object {
            '{0}:{1}' -f [System.IO.Path]::GetFullPath([string]$_.file), [int]$_.startLine
        } | Sort-Object -Unique)
        $boundedUnits.Add([PSCustomObject]@{
            WorkerId = [string]$unit.WorkerId
            Paths = @($unit.Paths)
            LineFilters = $unitLineFilters
            ExpectedCount = [int]$unitTests.Count
            RequiresPrivateRepository = [bool]$unit.RequiresPrivateRepository
        })
    }
    $covered = [int](($boundedUnits | Measure-Object ExpectedCount -Sum).Sum)
    if ($covered -ne $selectedTests.Count) {
        throw "Bounded Pester work-unit coverage mismatch: units=$covered selected=$($selectedTests.Count)"
    }
    return [PSCustomObject]@{
        Units = $boundedUnits.ToArray()
        Tests = $selectedTests.ToArray()
        Total = $selectedTests.Count
    }
}

function Merge-NUnitResults {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][int]$TotalCount,
        [Parameter(Mandatory = $true)][int]$FailedCount,
        [Parameter(Mandatory = $true)][int]$ErrorsCount,
        [Parameter(Mandatory = $true)][int]$SkippedCount,
        [Parameter(Mandatory = $true)][int]$NotRunCount,
        [Parameter(Mandatory = $true)][int]$InconclusiveCount,
        [Parameter(Mandatory = $true)][double]$DurationSeconds
    )

    if ($Paths.Count -eq 0) {
        throw 'No NUnit result files were supplied for merge.'
    }
    [xml]$merged = Get-Content -LiteralPath $Paths[0] -Raw -Encoding UTF8
    if ($merged.DocumentElement.LocalName -ne 'test-results') {
        throw "Unexpected NUnit root in $($Paths[0])"
    }
    $mergedSuite = $merged.DocumentElement.SelectSingleNode('test-suite')
    $mergedResults = $mergedSuite.SelectSingleNode('results')
    if ($null -eq $mergedResults) {
        throw "NUnit result has no test-suite/results node: $($Paths[0])"
    }
    $mergedResults.RemoveAll()

    foreach ($path in $Paths) {
        [xml]$worker = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ($worker.DocumentElement.LocalName -ne 'test-results') {
            throw "Unexpected NUnit root in $path"
        }
        $workerResults = $worker.DocumentElement.SelectSingleNode('test-suite/results')
        if ($null -eq $workerResults) {
            throw "NUnit result has no test-suite/results node: $path"
        }
        foreach ($node in @($workerResults.ChildNodes)) {
            [void]$mergedResults.AppendChild($merged.ImportNode($node, $true))
        }
    }

    $executedCount = $TotalCount - $NotRunCount
    $suiteResult = if (($FailedCount -gt 0) -or ($ErrorsCount -gt 0)) {
        'Failure'
    } elseif ($SkippedCount -gt 0) {
        'Ignored'
    } elseif ($InconclusiveCount -gt 0) {
        'Inconclusive'
    } else {
        'Success'
    }
    $success = ($FailedCount -eq 0) -and ($ErrorsCount -eq 0)
    $merged.DocumentElement.SetAttribute('name', 'Pester')
    $merged.DocumentElement.SetAttribute('total', [string]$executedCount)
    $merged.DocumentElement.SetAttribute('errors', [string]$ErrorsCount)
    $merged.DocumentElement.SetAttribute('failures', [string]$FailedCount)
    $merged.DocumentElement.SetAttribute('not-run', [string]$NotRunCount)
    $merged.DocumentElement.SetAttribute('inconclusive', [string]$InconclusiveCount)
    $merged.DocumentElement.SetAttribute('ignored', '0')
    $merged.DocumentElement.SetAttribute('skipped', [string]$SkippedCount)
    $merged.DocumentElement.SetAttribute('invalid', '0')
    $merged.DocumentElement.SetAttribute('date', (Get-Date).ToString('yyyy-MM-dd'))
    $merged.DocumentElement.SetAttribute('time', (Get-Date).ToString('HH:mm:ss'))
    $mergedSuite.SetAttribute('name', 'Pester')
    $mergedSuite.SetAttribute('executed', 'True')
    $mergedSuite.SetAttribute('result', $suiteResult)
    $mergedSuite.SetAttribute('success', $(if ($success) { 'True' } else { 'False' }))
    $mergedSuite.SetAttribute('time', $DurationSeconds.ToString('0.000', [System.Globalization.CultureInfo]::InvariantCulture))

    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $settings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($OutputPath, $settings)
    try {
        $merged.Save($writer)
    } finally {
        $writer.Dispose()
    }

    [xml]$verification = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8
    if ([int]$verification.DocumentElement.GetAttribute('total') -ne $executedCount -or
        [int]$verification.DocumentElement.GetAttribute('not-run') -ne $NotRunCount -or
        [int]$verification.DocumentElement.GetAttribute('skipped') -ne $SkippedCount) {
        throw 'Merged NUnit result counts do not match the aggregate.'
    }
}

function Invoke-ParallelSuite {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$PrivateRepositoryRoot,
        [Parameter(Mandatory = $true)]$CandidateContext,
        [Parameter(Mandatory = $true)][string]$ResultsRoot,
        [Parameter(Mandatory = $true)][string]$TestResultPath,
        [Parameter(Mandatory = $true)]$PesterModule,
        [Parameter(Mandatory = $true)][int]$ThrottleLimit,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [string[]]$LineFilters = @()
    )

    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $workerResultsRoot = Join-Path $ResultsRoot 'pester-workers'
    if (Test-Path -LiteralPath $workerResultsRoot) {
        Remove-Item -LiteralPath $workerResultsRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $workerResultsRoot -Force | Out-Null
    $executionRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-pester-' + $runId)
    New-Item -ItemType Directory -Path $executionRoot -Force | Out-Null

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $harnessFailures = [System.Collections.Generic.List[string]]::new()
    try {
        $runnerPath = $PSCommandPath
        $pwshPath = (Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source
        $discoveryRoot = Join-Path $workerResultsRoot '000-discovery'
        $discoveryTemp = Join-Path $executionRoot '000-discovery'
        $discoveryProject = Join-Path $discoveryTemp 'project'
        New-Item -ItemType Directory -Path $discoveryRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $discoveryProject -Force | Out-Null
        $discoverySpec = [ordered]@{
            Mode = 'Discovery'
            WorkerId = 'discovery'
            RepositoryRoot = $RepositoryRoot
            WorkingDirectory = $RepositoryRoot
            Paths = @($CandidateContext.CandidateTestPaths)
            LineFilters = @()
            ExpectedCount = 0
            ResultPath = Join-Path $discoveryRoot 'result.json'
            StdOutPath = Join-Path $discoveryRoot 'stdout.log'
            StdErrPath = Join-Path $discoveryRoot 'stderr.log'
            TempDirectory = $discoveryTemp
            ProjectDirectory = $discoveryProject
            PesterModulePath = [string]$PesterModule.Path
            CandidateTreeId = [string]$CandidateContext.CandidateTreeId
            HooksPath = [string]$CandidateContext.HooksPath
            TemplatePath = [string]$CandidateContext.TemplatePath
            RequiresPrivateRepository = $false
        }
        $discoverySpecPath = Join-Path $discoveryRoot 'spec.json'
        $discoverySpec | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $discoverySpecPath -Encoding UTF8
        $discoveryLaunch = @(Invoke-IsolatedPwshWorkers -SpecPaths @($discoverySpecPath) -RunnerPath $runnerPath -PwshPath $pwshPath -RepositoryRoot $RepositoryRoot -ThrottleLimit 1 -TimeoutSeconds $TimeoutSeconds)
        if (($discoveryLaunch.Count -ne 1) -or ($discoveryLaunch[0].ExitCode -ne 0) -or (-not [string]::IsNullOrWhiteSpace([string]$discoveryLaunch[0].LaunchError))) {
            $detail = if ($discoveryLaunch.Count -eq 1) { "$($discoveryLaunch[0].LaunchError) $($discoveryLaunch[0].StdErr)" } else { 'no launch result' }
            throw "Isolated Pester discovery failed: $detail"
        }
        if (-not (Test-Path -LiteralPath $discoverySpec.ResultPath -PathType Leaf)) {
            throw 'Isolated Pester discovery did not write result JSON.'
        }
        $discovery = Get-Content -LiteralPath $discoverySpec.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if (([string]$discovery.mode -ne 'discovery') -or ([int]$discovery.total -le 0)) {
            throw 'Isolated Pester discovery returned an invalid payload.'
        }
        if ([string]$discovery.candidateTreeId -cne [string]$CandidateContext.CandidateTreeId) {
            throw 'Isolated Pester discovery candidate tree ID mismatch.'
        }
        $allUnits = @(New-PesterWorkUnits `
            -RepositoryRoot $RepositoryRoot `
            -CandidateRepositoryRoot $PrivateRepositoryRoot `
            -CandidateTestPaths @($CandidateContext.CandidateTestPaths) `
            -DiscoveryResult $discovery)
        $selection = Select-PesterWorkUnitsByLineFilter -RepositoryRoot $RepositoryRoot -Units $allUnits -DiscoveryResult $discovery -LineFilters $LineFilters
        $units = @($selection.Units)
        $expectedTotal = [int]$selection.Total
        $expectedIdentities = @($selection.Tests.identity | ForEach-Object { [string]$_ } | Sort-Object)
        $specs = [System.Collections.Generic.List[object]]::new()
        $specPaths = [System.Collections.Generic.List[string]]::new()
        $index = 0
        foreach ($unit in $units) {
            $index++
            $workerRoot = Join-Path $workerResultsRoot ('{0:d3}-{1}' -f $index, $unit.WorkerId)
            $workerTemp = Join-Path $executionRoot ('{0:d3}' -f $index)
            $projectDirectory = Join-Path $workerTemp 'project'
            New-Item -ItemType Directory -Path $workerRoot -Force | Out-Null
            New-Item -ItemType Directory -Path $projectDirectory -Force | Out-Null
            $requiresPrivateRepository = [bool]$unit.RequiresPrivateRepository
            $workerRepositoryRoot = if ($requiresPrivateRepository) { $PrivateRepositoryRoot } else { $RepositoryRoot }
            $workerPaths = if ($requiresPrivateRepository) {
                @($unit.Paths | ForEach-Object {
                    $relative = [System.IO.Path]::GetRelativePath($RepositoryRoot, [string]$_)
                    $mapped = [System.IO.Path]::GetFullPath((Join-Path $PrivateRepositoryRoot $relative))
                    if (-not (Test-Path -LiteralPath $mapped -PathType Leaf)) {
                        throw "Private Pester worker path is missing: $relative"
                    }
                    $mapped
                })
            } else {
                @($unit.Paths)
            }
            $workerLineFilters = @(Convert-PesterExecutionLineFilters -RepositoryRoot $RepositoryRoot -PrivateRepositoryRoot $PrivateRepositoryRoot -LineFilters @($unit.LineFilters))
            $spec = [ordered]@{
                Mode = 'Test'
                WorkerId = [string]$unit.WorkerId
                RepositoryRoot = $workerRepositoryRoot
                WorkingDirectory = $workerRepositoryRoot
                Paths = $workerPaths
                LineFilters = $workerLineFilters
                ExpectedCount = [int]$unit.ExpectedCount
                ResultPath = Join-Path $workerRoot 'result.json'
                NUnitPath = Join-Path $workerRoot 'result.xml'
                StdOutPath = Join-Path $workerRoot 'stdout.log'
                StdErrPath = Join-Path $workerRoot 'stderr.log'
                TempDirectory = $workerTemp
                ProjectDirectory = $projectDirectory
                PesterModulePath = [string]$PesterModule.Path
                CandidateTreeId = [string]$CandidateContext.CandidateTreeId
                HooksPath = [string]$CandidateContext.HooksPath
                TemplatePath = [string]$CandidateContext.TemplatePath
                RequiresPrivateRepository = $requiresPrivateRepository
            }
            $specPath = Join-Path $workerRoot 'spec.json'
            $spec | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $specPath -Encoding UTF8
            $specs.Add([PSCustomObject]$spec)
            $specPaths.Add($specPath)
        }

        if (@($specs.TempDirectory | Sort-Object -Unique).Count -ne $specs.Count) {
            throw 'Pester worker TEMP directories are not unique.'
        }
        if (@($specs.ProjectDirectory | Sort-Object -Unique).Count -ne $specs.Count) {
            throw 'Pester worker project directories are not unique.'
        }

        $launches = @(Invoke-IsolatedPwshWorkers -SpecPaths $specPaths.ToArray() -RunnerPath $runnerPath -PwshPath $pwshPath -RepositoryRoot $RepositoryRoot -ThrottleLimit ([math]::Min($ThrottleLimit, $specPaths.Count)) -TimeoutSeconds $TimeoutSeconds)

        $workerPayloads = [System.Collections.Generic.List[object]]::new()
        foreach ($launch in $launches | Sort-Object WorkerId) {
            if (-not [string]::IsNullOrWhiteSpace([string]$launch.LaunchError)) {
                $harnessFailures.Add("$($launch.WorkerId): launch failed: $($launch.LaunchError)")
                continue
            }
            $spec = Get-Content -LiteralPath $launch.SpecPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not (Test-Path -LiteralPath $spec.ResultPath -PathType Leaf)) {
                $harnessFailures.Add("$($launch.WorkerId): result JSON is missing")
                continue
            }
            try {
                $payload = Get-Content -LiteralPath $spec.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $harnessFailures.Add("$($launch.WorkerId): result JSON is invalid: $($_.Exception.Message)")
                continue
            }
            if ([string]$payload.workerId -ne [string]$launch.WorkerId) {
                $harnessFailures.Add("$($launch.WorkerId): result worker identity mismatch")
            }
            if ([string]$payload.candidateTreeId -cne [string]$CandidateContext.CandidateTreeId) {
                $harnessFailures.Add("$($launch.WorkerId): result candidate tree identity mismatch")
            }
            if ([bool]$payload.requiresPrivateRepository -ne [bool]$spec.RequiresPrivateRepository) {
                $harnessFailures.Add("$($launch.WorkerId): result private fixture ownership mismatch")
            }
            if ([int]$payload.total -ne [int]$spec.ExpectedCount) {
                $harnessFailures.Add("$($launch.WorkerId): expected $($spec.ExpectedCount) tests, got $($payload.total)")
            }
            if (-not (Test-Path -LiteralPath $payload.nunitPath -PathType Leaf)) {
                $harnessFailures.Add("$($launch.WorkerId): NUnit XML is missing")
            } else {
                try {
                    [xml](Get-Content -LiteralPath $payload.nunitPath -Raw -Encoding UTF8) | Out-Null
                } catch {
                    $harnessFailures.Add("$($launch.WorkerId): NUnit XML is invalid: $($_.Exception.Message)")
                }
            }
            if ([int]$launch.ExitCode -ne 0) {
                $detail = if ($payload.PSObject.Properties.Name -contains 'harnessError') { [string]$payload.harnessError } else { [string]$launch.StdErr }
                $harnessFailures.Add("$($launch.WorkerId): child exit $($launch.ExitCode) $detail")
            }
            $workerPayloads.Add($payload)
        }

        $totalCount = [int](($workerPayloads | Measure-Object total -Sum).Sum)
        $passedCount = [int](($workerPayloads | Measure-Object passed -Sum).Sum)
        $failedCount = [int](($workerPayloads | Measure-Object failed -Sum).Sum)
        $skippedCount = [int](($workerPayloads | Measure-Object skipped -Sum).Sum)
        $notRunCount = [int](($workerPayloads | Measure-Object notRun -Sum).Sum)
        $inconclusiveCount = [int](($workerPayloads | Measure-Object inconclusive -Sum).Sum)
        $failedBlocks = [int](($workerPayloads | Measure-Object failedBlocks -Sum).Sum)
        $failedContainers = [int](($workerPayloads | Measure-Object failedContainers -Sum).Sum)
        $actualIdentities = @($workerPayloads.identities | ForEach-Object { [string]$_ } | Sort-Object)
        if ($totalCount -ne $expectedTotal) {
            $harnessFailures.Add("aggregate total $totalCount does not match selected discovery total $expectedTotal")
        }
        if ($actualIdentities.Count -ne $expectedIdentities.Count) {
            $harnessFailures.Add("identity count $($actualIdentities.Count) does not match discovery $($expectedIdentities.Count)")
        } else {
            for ($identityIndex = 0; $identityIndex -lt $expectedIdentities.Count; $identityIndex++) {
                if ($expectedIdentities[$identityIndex] -cne $actualIdentities[$identityIndex]) {
                    $harnessFailures.Add("test identity multiset mismatch at index $identityIndex")
                    break
                }
            }
        }

        $stopwatch.Stop()
        $nunitPaths = @($workerPayloads.nunitPath | ForEach-Object { [string]$_ })
        if ($nunitPaths.Count -eq $workerPayloads.Count) {
            Merge-NUnitResults -Paths $nunitPaths -OutputPath $TestResultPath -TotalCount $totalCount -FailedCount $failedCount -ErrorsCount ($failedBlocks + $failedContainers) -SkippedCount $skippedCount -NotRunCount $notRunCount -InconclusiveCount $inconclusiveCount -DurationSeconds $stopwatch.Elapsed.TotalSeconds
        }

        return [PSCustomObject]@{
            RunId = $runId
            DurationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
            WorkerCount = $units.Count
            TotalCount = $totalCount
            PassedCount = $passedCount
            FailedCount = $failedCount
            SkippedCount = $skippedCount
            NotRunCount = $notRunCount
            FailedBlocksCount = $failedBlocks
            FailedContainersCount = $failedContainers
            IdentityHash = Get-IdentityHash -Identities $actualIdentities
            DiscoveryIdentityHash = Get-IdentityHash -Identities $expectedIdentities
            CandidateTreeId = [string]$CandidateContext.CandidateTreeId
            HarnessFailures = $harnessFailures
        }
    } finally {
        if ($stopwatch.IsRunning) {
            $stopwatch.Stop()
        }
        if (Test-Path -LiteralPath $executionRoot) {
            try {
                Remove-Item -LiteralPath $executionRoot -Recurse -Force -ErrorAction Stop
            } catch {
                $harnessFailures.Add("worker TEMP cleanup failed: $($_.Exception.Message)")
            }
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($WorkerSpecPath)) {
    $workerExitCode = 2
    try {
        $workerSpecFullPath = [System.IO.Path]::GetFullPath($WorkerSpecPath)
        $workerSpec = Get-Content -LiteralPath $workerSpecFullPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $workerRepositoryRoot = [System.IO.Path]::GetFullPath([string]$workerSpec.RepositoryRoot)
        $workerWorkingDirectory = [System.IO.Path]::GetFullPath([string]$workerSpec.WorkingDirectory)
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals($workerRepositoryRoot, $workerWorkingDirectory)) {
            throw 'Pester worker working directory must equal its repository root.'
        }
        $workerGitEnvironment = Get-RunnerGitEnvironment `
            -HooksPath ([string]$workerSpec.HooksPath) `
            -TemplatePath ([string]$workerSpec.TemplatePath) `
            -CandidateTreeId ([string]$workerSpec.CandidateTreeId)
        $workerAction = {
            Push-Location -LiteralPath $workerRepositoryRoot
            try {
                Invoke-WithRunnerGitEnvironment -Environment $workerGitEnvironment -ScriptBlock {
                    Invoke-PesterWorker -SpecPath $workerSpecFullPath
                }
            } finally {
                Pop-Location
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($WorkerStdOutPath) -and -not [string]::IsNullOrWhiteSpace($WorkerStdErrPath)) {
            $WorkerStdOutPath = [System.IO.Path]::GetFullPath($WorkerStdOutPath)
            $WorkerStdErrPath = [System.IO.Path]::GetFullPath($WorkerStdErrPath)
            New-Item -ItemType Directory -Path (Split-Path -Parent $WorkerStdOutPath) -Force | Out-Null
            New-Item -ItemType Directory -Path (Split-Path -Parent $WorkerStdErrPath) -Force | Out-Null
            & {
                $script:workerExitCode = & $workerAction
            } 1> $WorkerStdOutPath 2> $WorkerStdErrPath
        } else {
            $workerExitCode = & $workerAction
        }
    } catch {
        [Console]::Error.WriteLine("Pester worker setup failed: $($_.Exception.Message)")
        $workerExitCode = 2
    }
    exit $workerExitCode
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ResultsDirectory)) {
    $ResultsDirectory = Join-Path $repositoryRoot 'artifacts\test-results'
} else {
    $ResultsDirectory = [System.IO.Path]::GetFullPath($ResultsDirectory)
}
$testResultPath = Join-Path $ResultsDirectory 'pester-results.xml'
$coverageReportPath = Join-Path $ResultsDirectory 'coverage.xml'
$summaryPath = Join-Path $ResultsDirectory 'summary.json'
New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
foreach ($stalePath in @($testResultPath, $coverageReportPath, $summaryPath)) {
    if (Test-Path -LiteralPath $stalePath) {
        Remove-Item -LiteralPath $stalePath -Force
    }
}

$prospectiveIndexPath = [Environment]::GetEnvironmentVariable('GIT_INDEX_FILE', 'Process')
$controllerId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$runnerControlRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-pester-controller-' + $controllerId)
$candidateContext = $null
$privateRepositoryRoot = $null
$runnerExitCode = 1
$postflightFailure = ''

try {
    $contextParameters = @{
        RepositoryRoot = $repositoryRoot
        ExecutionRoot = $runnerControlRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($prospectiveIndexPath)) {
        $contextParameters['ProspectiveIndexPath'] = $prospectiveIndexPath
    }
    $candidateContext = New-RunnerCandidateContext @contextParameters
    $privateRepositoryRoot = New-RunnerPrivateRepository -Context $candidateContext -DestinationPath (Join-Path $runnerControlRoot 'private-repository')

    Invoke-WithRunnerGitEnvironment -Environment $candidateContext.GitEnvironment -ScriptBlock {
        $pesterModule = Get-PesterModule
        if (-not $pesterModule) {
            Write-TestSummary -Path $summaryPath -PassedCount 0 -FailedCount 1 -TotalCount 0 -CoveragePercent $null -CoverageThreshold $CoverageThreshold -Additional @{
                mode = 'unavailable'
                candidateTreeId = [string]$candidateContext.CandidateTreeId
            }
            Write-Output 'Pester: module not found'
            Write-Output 'Coverage: unavailable'
            $script:runnerExitCode = 1
        } else {
            $useParallel = [bool]$Parallel -and -not [bool]$Coverage -and ($pesterModule.Version.Major -ge 5)
            if ($env:WINSMUX_UPDATE_GOLDEN -eq '1') {
                $useParallel = $false
                Write-Output 'Pester: parallel execution disabled because WINSMUX_UPDATE_GOLDEN=1'
            }

            if ($useParallel) {
                Import-Module $pesterModule.Path -Force -ErrorAction Stop | Out-Null
                $probe = [PesterConfiguration]::Default
                $requiredRunProperties = @('Path', 'PassThru', 'Exit', 'SkipRun')
                if (@($requiredRunProperties | Where-Object { $probe.Run.PSObject.Properties.Name -notcontains $_ }).Count -gt 0 -or
                    $probe.Filter.PSObject.Properties.Name -notcontains 'Line') {
                    $useParallel = $false
                    Write-Output 'Pester: parallel features unavailable; using serial execution'
                }
            }

            if ($useParallel) {
                $parallelResult = Invoke-ParallelSuite `
                    -RepositoryRoot $repositoryRoot `
                    -PrivateRepositoryRoot $privateRepositoryRoot `
                    -CandidateContext $candidateContext `
                    -ResultsRoot $ResultsDirectory `
                    -TestResultPath $testResultPath `
                    -PesterModule $pesterModule `
                    -ThrottleLimit $MaxParallel `
                    -TimeoutSeconds $WorkerTimeoutSeconds `
                    -LineFilters $LineFilters
                $additional = [ordered]@{
                    skipped = $parallelResult.SkippedCount
                    notRun = $parallelResult.NotRunCount
                    failedBlocks = $parallelResult.FailedBlocksCount
                    failedContainers = $parallelResult.FailedContainersCount
                    parallel = $true
                    durationSeconds = $parallelResult.DurationSeconds
                    workerCount = $parallelResult.WorkerCount
                    runId = $parallelResult.RunId
                    identityHash = $parallelResult.IdentityHash
                    discoveryIdentityHash = $parallelResult.DiscoveryIdentityHash
                    candidateTreeId = $parallelResult.CandidateTreeId
                    privateFixtureOwnerCount = 2
                    boundedLineFilterCount = $LineFilters.Count
                    harnessFailures = @($parallelResult.HarnessFailures)
                }
                Write-TestSummary -Path $summaryPath -PassedCount $parallelResult.PassedCount -FailedCount $parallelResult.FailedCount -TotalCount $parallelResult.TotalCount -CoveragePercent $null -CoverageThreshold $CoverageThreshold -Additional $additional
                Write-Output ('Pester: Passed={0} Failed={1} Total={2}' -f $parallelResult.PassedCount, $parallelResult.FailedCount, $parallelResult.TotalCount)
                Write-Output 'Coverage: disabled'
                Write-Output ('Parallel: Workers={0} Duration={1:N3}s MaxParallel={2}' -f $parallelResult.WorkerCount, $parallelResult.DurationSeconds, $MaxParallel)
                foreach ($failure in @($parallelResult.HarnessFailures)) {
                    Write-Warning $failure
                }
                $script:runnerExitCode = if (($parallelResult.FailedCount -eq 0) -and
                    ($parallelResult.FailedBlocksCount -eq 0) -and
                    ($parallelResult.FailedContainersCount -eq 0) -and
                    (@($parallelResult.HarnessFailures).Count -eq 0)) { 0 } else { 1 }
            } else {
                $serial = Invoke-SerialSuite `
                    -RepositoryRoot $repositoryRoot `
                    -PrivateRepositoryRoot $privateRepositoryRoot `
                    -TestResultPath $testResultPath `
                    -CoverageReportPath $coverageReportPath `
                    -PesterModule $pesterModule `
                    -CandidateTestPaths @($candidateContext.CandidateTestPaths) `
                    -LineFilters $LineFilters `
                    -EnableCoverage:$Coverage
                $result = $serial.Result
                $resultTests = @($serial.SelectedTests)
                if ($LineFilters.Count -gt 0) {
                    $passedCount = @($resultTests | Where-Object { [string]$_.Result -eq 'Passed' }).Count
                    $failedCount = @($resultTests | Where-Object { [string]$_.Result -eq 'Failed' }).Count
                    $skippedCount = @($resultTests | Where-Object { [string]$_.Result -eq 'Skipped' }).Count
                    $notRunCount = @($resultTests | Where-Object { [string]$_.Result -eq 'NotRun' }).Count
                    $totalCount = $resultTests.Count
                } else {
                    $passedCount = [int](Get-ObjectProperty -InputObject $result -Name 'PassedCount' -DefaultValue 0)
                    $failedCount = [int](Get-ObjectProperty -InputObject $result -Name 'FailedCount' -DefaultValue 0)
                    $totalCount = [int](Get-ObjectProperty -InputObject $result -Name 'TotalCount' -DefaultValue ($passedCount + $failedCount))
                    $skippedCount = [int](Get-ObjectProperty -InputObject $result -Name 'SkippedCount' -DefaultValue 0)
                    $notRunCount = [int](Get-ObjectProperty -InputObject $result -Name 'NotRunCount' -DefaultValue 0)
                }
                $failedBlocksCount = [int](Get-ObjectProperty -InputObject $result -Name 'FailedBlocksCount' -DefaultValue 0)
                $failedContainersCount = [int](Get-ObjectProperty -InputObject $result -Name 'FailedContainersCount' -DefaultValue 0)
                $coveragePercent = Get-CoveragePercent -CodeCoverage (Get-ObjectProperty -InputObject $result -Name 'CodeCoverage')
                $thresholdMet = (-not $Coverage) -or (($null -ne $coveragePercent) -and ($coveragePercent -ge $CoverageThreshold))
                $identities = @($resultTests | ForEach-Object { Get-TestIdentity -Test $_ })
                $additional = [ordered]@{
                    skipped = $skippedCount
                    notRun = $notRunCount
                    failedBlocks = $failedBlocksCount
                    failedContainers = $failedContainersCount
                    parallel = $false
                    durationSeconds = $serial.DurationSeconds
                    workerCount = 1
                    identityHash = Get-IdentityHash -Identities $identities
                    candidateTreeId = [string]$candidateContext.CandidateTreeId
                    privateFixtureOwnerCount = 2
                    boundedLineFilterCount = $LineFilters.Count
                }
                Write-TestSummary -Path $summaryPath -PassedCount $passedCount -FailedCount $failedCount -TotalCount $totalCount -CoveragePercent $coveragePercent -CoverageThreshold $CoverageThreshold -Additional $additional
                Write-Output ('Pester: Passed={0} Failed={1} Total={2}' -f $passedCount, $failedCount, $totalCount)
                if ($Coverage) {
                    if ($null -ne $coveragePercent) {
                        Write-Output ('Coverage: {0:N2}% (threshold: {1}%)' -f $coveragePercent, $CoverageThreshold)
                    } else {
                        Write-Output ('Coverage: unavailable (threshold: {0}%)' -f $CoverageThreshold)
                    }
                } else {
                    Write-Output 'Coverage: disabled'
                }
                Write-Output ('Parallel: disabled Duration={0:N3}s' -f $serial.DurationSeconds)
                $script:runnerExitCode = if (($failedCount -eq 0) -and
                    ($failedBlocksCount -eq 0) -and
                    ($failedContainersCount -eq 0) -and
                    $thresholdMet) { 0 } else { 1 }
            }
        }
    }
} catch {
    $runnerExitCode = 1
    Write-TestSummary -Path $summaryPath -PassedCount 0 -FailedCount 1 -TotalCount 0 -CoveragePercent $null -CoverageThreshold $CoverageThreshold -Additional @{
        mode = 'harness-error'
        error = $_.Exception.Message
        candidateTreeId = $(if ($null -ne $candidateContext) { [string]$candidateContext.CandidateTreeId } else { '' })
    }
    Write-Output 'Pester: Passed=0 Failed=1 Total=0'
    Write-Output $(if ($Coverage) { 'Coverage: unavailable' } else { 'Coverage: disabled' })
    [Console]::Error.WriteLine($_.Exception.Message)
} finally {
    if ($null -ne $candidateContext) {
        try {
            Assert-RunnerSourceState -Context $candidateContext
        } catch {
            $postflightFailure = $_.Exception.Message
        }
    }
    if (Test-Path -LiteralPath $runnerControlRoot) {
        $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $resolvedControlRoot = [System.IO.Path]::GetFullPath($runnerControlRoot)
        if (-not $resolvedControlRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $postflightFailure = 'Runner controller cleanup target escaped the system TEMP directory.'
        } else {
            try {
                Remove-Item -LiteralPath $resolvedControlRoot -Recurse -Force -ErrorAction Stop
            } catch {
                $postflightFailure = "Runner private fixture cleanup failed: $($_.Exception.Message)"
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($postflightFailure)) {
        $runnerExitCode = 1
        Write-TestSummary -Path $summaryPath -PassedCount 0 -FailedCount 1 -TotalCount 0 -CoveragePercent $null -CoverageThreshold $CoverageThreshold -Additional @{
            mode = 'harness-postflight-error'
            error = $postflightFailure
            candidateTreeId = $(if ($null -ne $candidateContext) { [string]$candidateContext.CandidateTreeId } else { '' })
        }
        [Console]::Error.WriteLine($postflightFailure)
    }
}

exit $runnerExitCode
