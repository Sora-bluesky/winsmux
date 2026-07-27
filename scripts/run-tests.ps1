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
    [string]$WorkerSpecPath,

    [Parameter(DontShow = $true)]
    [ValidateRange(1, 7200)]
    # The integration CI shard owns a 25-minute budget. Keep the local aggregate
    # runner above that boundary because concurrent bridge workers add contention.
    [int]$WorkerTimeoutSeconds = 1800,

    [Parameter(DontShow = $true)]
    [string]$WorkerStdOutPath,

    [Parameter(DontShow = $true)]
    [string]$WorkerStdErrPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CoverageTargets {
    param([string]$RepositoryRoot)

    $testFiles = Get-ChildItem -Path (Join-Path $RepositoryRoot 'tests') -Filter '*.Tests.ps1' -File -Recurse -ErrorAction SilentlyContinue
    $targets = [System.Collections.Generic.List[string]]::new()

    foreach ($testFile in $testFiles) {
        $content = Get-Content -Path $testFile.FullName -Raw -ErrorAction SilentlyContinue
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

    if (($CodeCoverage.PSObject.Properties.Name -contains 'NumberOfCommandsAnalyzed') -and
        ($CodeCoverage.PSObject.Properties.Name -contains 'NumberOfCommandsExecuted')) {
        $analyzed = [double]$CodeCoverage.NumberOfCommandsAnalyzed
        if ($analyzed -le 0) {
            return 0
        }

        return [math]::Round(([double]$CodeCoverage.NumberOfCommandsExecuted / $analyzed) * 100, 2)
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

function Get-IsolatedGitEnvironment {
    $globalConfigPath = if ($IsWindows) { 'NUL' } else { '/dev/null' }
    return [ordered]@{
        GIT_CONFIG_GLOBAL     = $globalConfigPath
        GIT_CONFIG_NOSYSTEM   = '1'
        GIT_CONFIG_COUNT      = '1'
        GIT_CONFIG_KEY_0      = 'init.defaultBranch'
        GIT_CONFIG_VALUE_0    = 'main'
        GIT_CONFIG_PARAMETERS = ''
    }
}

function Invoke-WithIsolatedGitEnvironment {
    param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)

    $environment = Get-IsolatedGitEnvironment
    $previous = [ordered]@{}
    try {
        foreach ($entry in $environment.GetEnumerator()) {
            $name = [string]$entry.Key
            $previous[$name] = [PSCustomObject]@{
                Exists = Test-Path -LiteralPath "Env:$name"
                Value  = [Environment]::GetEnvironmentVariable($name, 'Process')
            }
            [Environment]::SetEnvironmentVariable(
                $name,
                [string]$entry.Value,
                'Process'
            )
        }
        return & $ScriptBlock
    } finally {
        foreach ($entry in $previous.GetEnumerator()) {
            $name = [string]$entry.Key
            if ($entry.Value.Exists) {
                [Environment]::SetEnvironmentVariable(
                    $name,
                    [string]$entry.Value.Value,
                    'Process'
                )
            } else {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-PesterGitCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [ValidateNotNullOrEmpty()][string]$FailureToken = 'PESTER_GIT_COMMAND_FAILED',
        [AllowEmptyString()][string]$IndexFile = '',
        [System.Collections.IDictionary]$AdditionalEnvironment = @{}
    )

    $repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    if (-not (Test-Path -LiteralPath $repositoryRoot -PathType Container)) {
        throw "$FailureToken exit=-1 stderr=repository root is missing"
    }
    $gitPath = (Get-Command git -CommandType Application -ErrorAction Stop |
        Select-Object -First 1).Source
    $commandArguments = @(
        '-c',
        "safe.directory=$repositoryRoot",
        '-C',
        $repositoryRoot,
        '-c',
        'core.autocrlf=false'
    ) + @($Arguments)
    $argumentBytes = [System.Text.Encoding]::UTF8.GetByteCount(
        ($commandArguments -join "`0")
    )
    if ($argumentBytes -gt 4096) {
        throw "$FailureToken exit=-1 stderr=bounded argv exceeds 4096 UTF-8 bytes"
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $gitPath
    foreach ($argument in $commandArguments) {
        $startInfo.ArgumentList.Add([string]$argument)
    }
    $startInfo.WorkingDirectory = $repositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.Environment.Clear()
    foreach ($name in @('Path', 'SystemRoot', 'TEMP', 'TMP')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrEmpty($value)) {
            $startInfo.Environment[$name] = $value
        }
    }
    $isolatedGitEnvironment = [ordered]@{
        GIT_CONFIG_GLOBAL = $(if ($IsWindows) { 'NUL' } else { '/dev/null' })
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_COUNT = '1'
        GIT_CONFIG_KEY_0 = 'init.defaultBranch'
        GIT_CONFIG_VALUE_0 = 'main'
        GIT_CONFIG_PARAMETERS = ''
    }
    foreach ($entry in $isolatedGitEnvironment.GetEnumerator()) {
        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
    }
    $startInfo.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $startInfo.Environment['GCM_INTERACTIVE'] = 'Never'
    if (-not [string]::IsNullOrWhiteSpace($IndexFile)) {
        $resolvedIndex = [System.IO.Path]::GetFullPath($IndexFile)
        if (-not (Test-Path -LiteralPath $resolvedIndex -PathType Leaf)) {
            throw "$FailureToken exit=-1 stderr=prospective index is missing"
        }
        $startInfo.Environment['GIT_INDEX_FILE'] = $resolvedIndex
    }
    foreach ($entry in $AdditionalEnvironment.GetEnumerator()) {
        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $process.StandardInput.Close()
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            try { $process.Kill($true) } catch {}
            [void]$process.WaitForExit(5000)
            throw "$FailureToken exit=-2 stderr=native Git command exceeded 60 seconds"
        }
        $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $diagnostic = $standardError.Trim()
            if ([string]::IsNullOrWhiteSpace($diagnostic)) {
                $diagnostic = $standardOutput.Trim()
            }
            throw "$FailureToken exit=$($process.ExitCode) stderr=$diagnostic"
        }
        if ([string]::IsNullOrEmpty($standardOutput)) {
            return @()
        }
        return @($standardOutput -split '\r?\n' | Where-Object { $_ -cne '' })
    } finally {
        $process.Dispose()
    }
}

function Assert-PesterCandidateTreeMatchesSource {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$CandidateTree,
        [AllowEmptyString()][string]$IndexFile = ''
    )

    $repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    if ($CandidateTree -cnotmatch '^[0-9a-f]{40}$') {
        throw 'SOURCE_CANDIDATE_TREE_MISMATCH invalid candidate tree identity'
    }
    $previousIndexExists = Test-Path -LiteralPath 'Env:GIT_INDEX_FILE'
    $previousIndex = [Environment]::GetEnvironmentVariable(
        'GIT_INDEX_FILE',
        'Process'
    )
    try {
        if (-not [string]::IsNullOrWhiteSpace($IndexFile)) {
            $env:GIT_INDEX_FILE = [System.IO.Path]::GetFullPath($IndexFile)
        }
        $output = @(
            & git -c "safe.directory=$repositoryRoot" -C $repositoryRoot `
                -c core.autocrlf=true `
                diff --no-ext-diff --binary --exit-code $CandidateTree -- . 2>&1
        )
        $exitCode = $LASTEXITCODE
    } finally {
        if ($previousIndexExists) {
            $env:GIT_INDEX_FILE = $previousIndex
        } else {
            Remove-Item -LiteralPath 'Env:GIT_INDEX_FILE' -ErrorAction SilentlyContinue
        }
    }
    if ($exitCode -eq 1) {
        throw 'SOURCE_CANDIDATE_TREE_MISMATCH normalized tracked bytes differ'
    }
    if ($exitCode -ne 0) {
        throw "SOURCE_CANDIDATE_TREE_MISMATCH inspection failed exit=$exitCode"
    }
}

function Get-PesterCandidateTree {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $candidateTree = ''
    $candidateWasAsserted = $false
    if (Test-Path -LiteralPath 'Env:GIT_INDEX_FILE') {
        $prospectiveIndex = [Environment]::GetEnvironmentVariable(
            'GIT_INDEX_FILE',
            'Process'
        )
        if ([string]::IsNullOrWhiteSpace($prospectiveIndex)) {
            throw 'SOURCE_CANDIDATE_TREE_MISMATCH GIT_INDEX_FILE is empty'
        }
        $prospectiveIndex = [System.IO.Path]::GetFullPath($prospectiveIndex)
        if (-not (Test-Path -LiteralPath $prospectiveIndex -PathType Leaf)) {
            throw 'SOURCE_CANDIDATE_TREE_MISMATCH GIT_INDEX_FILE is missing'
        }
        $indexCopy = Join-Path (
            [System.IO.Path]::GetTempPath()
        ) ('winsmux-candidate-index-' + [guid]::NewGuid().ToString('N'))
        try {
            [System.IO.File]::Copy($prospectiveIndex, $indexCopy, $false)
            $candidateTree = [string](
                Invoke-PesterGitCommand `
                    -RepositoryRoot $repositoryRoot `
                    -Arguments @('write-tree') `
                    -IndexFile $indexCopy `
                    -FailureToken 'SOURCE_CANDIDATE_TREE_MISMATCH' |
                    Select-Object -Last 1
            )
            $candidateTree = $candidateTree.Trim().ToLowerInvariant()
            if ($candidateTree -cnotmatch '^[0-9a-f]{40}$') {
                throw 'SOURCE_CANDIDATE_TREE_MISMATCH candidate tree is not a 40-character object ID'
            }
            Assert-PesterCandidateTreeMatchesSource `
                -RepositoryRoot $repositoryRoot `
                -CandidateTree $candidateTree `
                -IndexFile $indexCopy
            $candidateWasAsserted = $true
        } finally {
            if (Test-Path -LiteralPath $indexCopy -PathType Leaf) {
                Remove-Item -LiteralPath $indexCopy -Force
            }
        }
    } else {
        $candidateTree = [string](
            Invoke-PesterGitCommand `
                -RepositoryRoot $repositoryRoot `
                -Arguments @('rev-parse', 'HEAD^{tree}') `
                -FailureToken 'SOURCE_CANDIDATE_TREE_MISMATCH' |
                Select-Object -Last 1
        )
    }
    $candidateTree = $candidateTree.Trim().ToLowerInvariant()
    if ($candidateTree -cnotmatch '^[0-9a-f]{40}$') {
        throw 'SOURCE_CANDIDATE_TREE_MISMATCH candidate tree is not a 40-character object ID'
    }
    if (-not $candidateWasAsserted) {
        Assert-PesterCandidateTreeMatchesSource `
            -RepositoryRoot $repositoryRoot `
            -CandidateTree $candidateTree
    }
    return $candidateTree
}

function Get-PesterRepositoryStateIdentity {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $gitDirectory = [string](
        Invoke-PesterGitCommand `
            -RepositoryRoot $repositoryRoot `
            -Arguments @('rev-parse', '--absolute-git-dir') |
            Select-Object -Last 1
    )
    $configPath = [string](
        Invoke-PesterGitCommand `
            -RepositoryRoot $repositoryRoot `
            -Arguments @('rev-parse', '--path-format=absolute', '--git-path', 'config') |
            Select-Object -Last 1
    )
    $indexPath = Join-Path $gitDirectory.Trim() 'index'
    $configPath = $configPath.Trim()
    $indexIdentity = if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
        (
            [Convert]::ToHexString(
                [System.Security.Cryptography.SHA256]::HashData(
                    [System.IO.File]::ReadAllBytes($indexPath)
                )
            )
        ).ToLowerInvariant()
    } else {
        'absent'
    }
    $configIdentity = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        (
            [Convert]::ToHexString(
                [System.Security.Cryptography.SHA256]::HashData(
                    [System.IO.File]::ReadAllBytes($configPath)
                )
            )
        ).ToLowerInvariant()
    } else {
        'absent'
    }
    $trackedIdentity = @(
        Invoke-PesterGitCommand `
            -RepositoryRoot $repositoryRoot `
            -Arguments @(
                '-c',
                'core.autocrlf=true',
                'diff',
                '--no-ext-diff',
                '--binary',
                'HEAD',
                '--'
            )
    ) -join "`n"
    $refsIdentity = @(
        Invoke-PesterGitCommand `
            -RepositoryRoot $repositoryRoot `
            -Arguments @('for-each-ref', '--format=%(refname)%00%(objectname)')
    ) -join "`n"

    return [PSCustomObject]@{
        TrackedIdentity = $trackedIdentity
        IndexIdentity = $indexIdentity
        ConfigIdentity = $configIdentity
        RefsIdentity = $refsIdentity
    }
}

function Assert-PesterRepositoryStateIdentity {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual
    )

    $drift = [System.Collections.Generic.List[string]]::new()
    if ([string]$Expected.TrackedIdentity -cne [string]$Actual.TrackedIdentity) {
        $drift.Add('tracked')
    }
    if ([string]$Expected.IndexIdentity -cne [string]$Actual.IndexIdentity) {
        $drift.Add('index')
    }
    if ([string]$Expected.ConfigIdentity -cne [string]$Actual.ConfigIdentity) {
        $drift.Add('config')
    }
    if ([string]$Expected.RefsIdentity -cne [string]$Actual.RefsIdentity) {
        $drift.Add('refs')
    }
    if ($drift.Count -gt 0) {
        throw "SOURCE_REPOSITORY_DRIFT $($drift -join ',')"
    }
}

function New-PesterPrivateRepository {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRepositoryRoot,
        [Parameter(Mandatory = $true)][string]$CandidateTree,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    $sourceRoot = [System.IO.Path]::GetFullPath($SourceRepositoryRoot)
    $destinationRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    if ($CandidateTree -cnotmatch '^[0-9a-f]{40}$') {
        throw 'PRIVATE_REPOSITORY_MATERIALIZATION_FAILED invalid candidate tree'
    }
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw 'PRIVATE_REPOSITORY_MATERIALIZATION_FAILED source repository is missing'
    }
    if (Test-Path -LiteralPath $destinationRoot) {
        throw 'PRIVATE_REPOSITORY_MATERIALIZATION_FAILED destination already exists'
    }
    if (
        [string]::Equals(
            $destinationRoot,
            [System.IO.Path]::GetPathRoot($destinationRoot),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        [string]::Equals(
            $destinationRoot,
            $sourceRoot,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'PRIVATE_REPOSITORY_MATERIALIZATION_FAILED unsafe destination'
    }
    $destinationParent = Split-Path -Parent $destinationRoot
    [System.IO.Directory]::CreateDirectory($destinationParent) | Out-Null
    $archivePath = Join-Path $destinationParent (
        '.winsmux-pester-' + [guid]::NewGuid().ToString('N') + '.zip'
    )
    $destinationCreated = $false
    try {
        Invoke-PesterGitCommand `
            -RepositoryRoot $sourceRoot `
            -Arguments @(
                'archive',
                '--format=zip',
                '--output',
                $archivePath,
                $CandidateTree
            ) `
            -FailureToken 'PRIVATE_REPOSITORY_ARCHIVE_FAILED' | Out-Null
        $destinationCreated = $true
        [System.IO.Compression.ZipFile]::ExtractToDirectory(
            $archivePath,
            $destinationRoot
        )
        Invoke-PesterGitCommand `
            -RepositoryRoot $destinationRoot `
            -Arguments @('init') `
            -FailureToken 'PRIVATE_REPOSITORY_INIT_FAILED' | Out-Null
        Invoke-PesterGitCommand `
            -RepositoryRoot $destinationRoot `
            -Arguments @('add', '-f', '--all') `
            -FailureToken 'PRIVATE_REPOSITORY_INDEX_FAILED' | Out-Null

        $treeEntries = @(
            Invoke-PesterGitCommand `
                -RepositoryRoot $sourceRoot `
                -Arguments @('ls-tree', '-r', '--full-tree', $CandidateTree) `
                -FailureToken 'PRIVATE_REPOSITORY_MODE_READ_FAILED'
        )
        foreach ($entry in $treeEntries) {
            $match = [regex]::Match([string]$entry, '^(?<mode>[0-9]{6})\s+\w+\s+[0-9a-f]{40}\t(?<path>.+)$')
            if ($match.Success -and [string]$match.Groups['mode'].Value -ceq '100755') {
                Invoke-PesterGitCommand `
                    -RepositoryRoot $destinationRoot `
                    -Arguments @(
                        'update-index',
                        '--chmod=+x',
                        '--',
                        [string]$match.Groups['path'].Value
                    ) `
                    -FailureToken 'PRIVATE_REPOSITORY_MODE_WRITE_FAILED' | Out-Null
            }
        }

        $privateTree = [string](
            Invoke-PesterGitCommand `
                -RepositoryRoot $destinationRoot `
                -Arguments @('write-tree') `
                -FailureToken 'PRIVATE_REPOSITORY_TREE_FAILED' |
                Select-Object -Last 1
        )
        $privateTree = $privateTree.Trim().ToLowerInvariant()
        if ($privateTree -cne $CandidateTree) {
            throw "PRIVATE_REPOSITORY_TREE_MISMATCH expected=$CandidateTree actual=$privateTree"
        }

        $commitEnvironment = [ordered]@{
            GIT_AUTHOR_NAME = 'winsmux Pester'
            GIT_AUTHOR_EMAIL = 'pester@winsmux.invalid'
            GIT_AUTHOR_DATE = '2000-01-01T00:00:00Z'
            GIT_COMMITTER_NAME = 'winsmux Pester'
            GIT_COMMITTER_EMAIL = 'pester@winsmux.invalid'
            GIT_COMMITTER_DATE = '2000-01-01T00:00:00Z'
        }
        $privateCommit = [string](
            Invoke-PesterGitCommand `
                -RepositoryRoot $destinationRoot `
                -Arguments @('commit-tree', $privateTree, '-m', 'winsmux Pester candidate') `
                -AdditionalEnvironment $commitEnvironment `
                -FailureToken 'PRIVATE_REPOSITORY_COMMIT_FAILED' |
                Select-Object -Last 1
        )
        $privateCommit = $privateCommit.Trim()
        Invoke-PesterGitCommand `
            -RepositoryRoot $destinationRoot `
            -Arguments @('update-ref', 'refs/heads/main', $privateCommit) `
            -FailureToken 'PRIVATE_REPOSITORY_REF_FAILED' | Out-Null
        Invoke-PesterGitCommand `
            -RepositoryRoot $destinationRoot `
            -Arguments @('symbolic-ref', 'HEAD', 'refs/heads/main') `
            -FailureToken 'PRIVATE_REPOSITORY_HEAD_FAILED' | Out-Null

        $headTree = [string](
            Invoke-PesterGitCommand `
                -RepositoryRoot $destinationRoot `
                -Arguments @('rev-parse', 'HEAD^{tree}') `
                -FailureToken 'PRIVATE_REPOSITORY_HEAD_FAILED' |
                Select-Object -Last 1
        )
        if ($headTree.Trim().ToLowerInvariant() -cne $CandidateTree) {
            throw 'PRIVATE_REPOSITORY_HEAD_TREE_MISMATCH'
        }
        $markerPath = Join-Path (
            Join-Path $destinationRoot '.git'
        ) 'winsmux-pester-private-owner.json'
        $marker = [ordered]@{
            repositoryRoot = $destinationRoot
            tree = $CandidateTree
        }
        [System.IO.File]::WriteAllText(
            $markerPath,
            ($marker | ConvertTo-Json -Compress),
            [System.Text.UTF8Encoding]::new($false)
        )
        return [PSCustomObject]@{
            RepositoryRoot = $destinationRoot
            Tree = $CandidateTree
            Commit = $privateCommit
        }
    } catch {
        $materializationFailure = $_
        if ($destinationCreated -and (Test-Path -LiteralPath $destinationRoot)) {
            try {
                Remove-Item -LiteralPath $destinationRoot -Recurse -Force -ErrorAction Stop
            } catch {
                throw (
                    'PRIVATE_REPOSITORY_CLEANUP_FAILED materialization={0} cleanup={1}' -f
                    $materializationFailure.Exception.Message,
                    $_.Exception.Message
                )
            }
        }
        throw $materializationFailure
    } finally {
        if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-PesterPrivateRepository {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    if (
        [string]::Equals(
            $repositoryRoot,
            [System.IO.Path]::GetPathRoot($repositoryRoot),
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'PRIVATE_REPOSITORY_CLEANUP_FAILED unsafe repository root'
    }
    $markerPath = Join-Path (
        Join-Path $repositoryRoot '.git'
    ) 'winsmux-pester-private-owner.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw 'PRIVATE_REPOSITORY_CLEANUP_FAILED ownership marker is missing'
    }
    $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if (
        -not [string]::Equals(
            [System.IO.Path]::GetFullPath([string]$marker.repositoryRoot),
            $repositoryRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        [string]$marker.tree -cnotmatch '^[0-9a-f]{40}$'
    ) {
        throw 'PRIVATE_REPOSITORY_CLEANUP_FAILED ownership marker is invalid'
    }
    try {
        Remove-Item -LiteralPath $repositoryRoot -Recurse -Force -ErrorAction Stop
    } catch {
        throw "PRIVATE_REPOSITORY_CLEANUP_FAILED $($_.Exception.Message)"
    }
    if (Test-Path -LiteralPath $repositoryRoot) {
        throw 'PRIVATE_REPOSITORY_CLEANUP_FAILED repository still exists'
    }
}

function Invoke-WithPesterPrivateRepository {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRepositoryRoot,
        [Parameter(Mandatory = $true)][string]$CandidateTree,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    $privateRepository = $null
    $result = $null
    $bodyFailure = $null
    $cleanupFailure = $null
    try {
        $privateRepository = New-PesterPrivateRepository `
            -SourceRepositoryRoot $SourceRepositoryRoot `
            -CandidateTree $CandidateTree `
            -DestinationRoot $DestinationRoot
        try {
            $result = & $ScriptBlock $privateRepository
        } catch {
            $bodyFailure = $_
        }
    } catch {
        $bodyFailure = $_
    } finally {
        if ($null -ne $privateRepository) {
            try {
                Remove-PesterPrivateRepository `
                    -RepositoryRoot ([string]$privateRepository.RepositoryRoot)
            } catch {
                $cleanupFailure = $_
            }
        }
    }
    if ($null -ne $cleanupFailure) {
        $bodyMessage = if ($null -ne $bodyFailure) {
            [string]$bodyFailure.Exception.Message
        } else {
            'none'
        }
        throw (
            'PRIVATE_REPOSITORY_CLEANUP_FAILED body={0} cleanup={1}' -f
            $bodyMessage,
            $cleanupFailure.Exception.Message
        )
    }
    if ($null -ne $bodyFailure) {
        throw $bodyFailure
    }
    return $result
}

function New-PesterDiscoverySpec {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ResultRoot,
        [Parameter(Mandatory = $true)][string]$TempDirectory,
        [Parameter(Mandatory = $true)][string]$ProjectDirectory,
        [Parameter(Mandatory = $true)][string]$PesterModulePath
    )

    $repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $resultRoot = [System.IO.Path]::GetFullPath($ResultRoot)
    return [PSCustomObject][ordered]@{
        Mode = 'Discovery'
        WorkerId = 'discovery'
        RepositoryRoot = $repositoryRoot
        TestsPath = Join-Path $repositoryRoot 'tests'
        ResultPath = Join-Path $resultRoot 'result.json'
        StdOutPath = Join-Path $resultRoot 'stdout.log'
        StdErrPath = Join-Path $resultRoot 'stderr.log'
        TempDirectory = [System.IO.Path]::GetFullPath($TempDirectory)
        ProjectDirectory = [System.IO.Path]::GetFullPath($ProjectDirectory)
        PesterModulePath = $PesterModulePath
    }
}

function Get-IsolatedChildEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$TempDirectory,
        [Parameter(Mandatory = $true)][string]$ProjectDirectory
    )

    # Pass only non-secret platform/runtime context that tests need. In particular,
    # do not inherit credential carriers such as *_TOKEN, GIT_ASKPASS,
    # SSH_AUTH_SOCK, DOCKER_AUTH_CONFIG, or CI_JOB_JWT.
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
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($value)) {
            $environment[$name] = $value
        }
    }
    $environment['TEMP'] = $TempDirectory
    $environment['TMP'] = $TempDirectory
    $environment['WINSMUX_ORCHESTRA_PROJECT_DIR'] = $ProjectDirectory
    $environment['WINSMUX_TEST_PROJECT_DIR'] = $ProjectDirectory
    $environment['NO_COLOR'] = '1'
    $environment['GIT_TERMINAL_PROMPT'] = '0'
    $environment['GCM_INTERACTIVE'] = 'Never'
    foreach ($entry in (Get-IsolatedGitEnvironment).GetEnumerator()) {
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
                    if (
                        $spec.PSObject.Properties.Name -notcontains 'RepositoryRoot' -or
                        [string]::IsNullOrWhiteSpace([string]$spec.RepositoryRoot)
                    ) {
                        throw "Pester worker $($spec.WorkerId) has no repository root."
                    }
                    $workerRepositoryRoot = [System.IO.Path]::GetFullPath(
                        [string]$spec.RepositoryRoot
                    )
                    if (-not (Test-Path -LiteralPath $workerRepositoryRoot -PathType Container)) {
                        throw "Pester worker $($spec.WorkerId) repository root is missing."
                    }
                    $startInfo.WorkingDirectory = $workerRepositoryRoot
                    $startInfo.UseShellExecute = $false
                    $startInfo.CreateNoWindow = $true
                    $startInfo.RedirectStandardInput = $true
                    $startInfo.Environment.Clear()
                    $childEnvironment = Get-IsolatedChildEnvironment -TempDirectory ([string]$spec.TempDirectory) -ProjectDirectory ([string]$spec.ProjectDirectory)
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
    return Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
}

function Invoke-SerialSuite {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$TestResultPath,
        [Parameter(Mandatory = $true)][string]$CoverageReportPath,
        [Parameter(Mandatory = $true)]$PesterModule,
        [switch]$EnableCoverage
    )

    $coverageTargets = @()
    if ($EnableCoverage) {
        $coverageTargets = @(Get-CoverageTargets -RepositoryRoot $RepositoryRoot)
        if ($coverageTargets.Count -eq 0) {
            throw 'Pester coverage was requested, but no coverage targets were found.'
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($PesterModule.Version.Major -ge 5) {
        Import-Module $PesterModule.Path -Force -ErrorAction Stop | Out-Null
        $configuration = [PesterConfiguration]::Default
        $configuration.Run.Path = @((Join-Path $RepositoryRoot 'tests'))
        $configuration.Run.PassThru = $true
        $configuration.Run.Exit = $false
        $configuration.Output.Verbosity = 'None'
        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = 'NUnitXml'
        $configuration.TestResult.OutputPath = $TestResultPath
        $configuration.CodeCoverage.Enabled = [bool]$EnableCoverage
        if ($EnableCoverage) {
            $configuration.CodeCoverage.Path = $coverageTargets
            $configuration.CodeCoverage.OutputPath = $CoverageReportPath
        }
        $result = Invoke-PesterIsolated -Configuration $configuration
    } else {
        if ($EnableCoverage) {
            $result = Invoke-Pester (Join-Path $RepositoryRoot 'tests') -PassThru -Quiet -CodeCoverage $coverageTargets -OutputFormat NUnitXml -OutputFile $TestResultPath
        } else {
            $result = Invoke-Pester (Join-Path $RepositoryRoot 'tests') -PassThru -Quiet -OutputFormat NUnitXml -OutputFile $TestResultPath
        }
    }
    $stopwatch.Stop()

    return [PSCustomObject]@{
        Result = $result
        DurationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    }
}

function Invoke-PesterWorker {
    param([Parameter(Mandatory = $true)][string]$SpecPath)

    $spec = Get-Content -LiteralPath $SpecPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    New-Item -ItemType Directory -Path $spec.TempDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $spec.ProjectDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $spec.ResultPath) -Force | Out-Null

    try {
        if ([string]$spec.Mode -eq 'Discovery') {
            $discovery = Invoke-TestDiscovery -TestsPath ([string]$spec.TestsPath) -PesterModulePath ([string]$spec.PesterModulePath)
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
            expectedCount = [int]$spec.ExpectedCount
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
        $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $spec.ResultPath -Encoding UTF8

        if (($payload.failed -eq 0) -and ($payload.failedBlocks -eq 0) -and ($payload.failedContainers -eq 0)) {
            return 0
        }
        return 1
    } catch {
        $failure = [ordered]@{
            workerId = [string]$spec.WorkerId
            expectedCount = [int]$spec.ExpectedCount
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
        [Parameter(Mandatory = $true)][string]$TestsPath,
        [Parameter(Mandatory = $true)][string]$PesterModulePath
    )

    Import-Module $PesterModulePath -Force -ErrorAction Stop | Out-Null
    $configuration = [PesterConfiguration]::Default
    $configuration.Run.Path = @($TestsPath)
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
        [Parameter(Mandatory = $true)]$DiscoveryResult
    )

    $testsPath = Join-Path $RepositoryRoot 'tests'
    $testFiles = @(Get-ChildItem -LiteralPath $testsPath -Filter '*.Tests.ps1' -File -Recurse | Sort-Object FullName)
    if ($testFiles.Count -eq 0) {
        throw 'No Pester test files were found.'
    }

    $testsByFile = @{}
    foreach ($test in $DiscoveryResult.tests) {
        $file = [System.IO.Path]::GetFullPath([string]$test.file)
        if (-not $testsByFile.ContainsKey($file)) {
            $testsByFile[$file] = [System.Collections.Generic.List[object]]::new()
        }
        $testsByFile[$file].Add($test)
    }

    $units = [System.Collections.Generic.List[object]]::new()
    $shards = @(Get-BridgeShards -RepositoryRoot $RepositoryRoot)
    $bridgePaths = @($shards.Paths | ForEach-Object { [System.IO.Path]::GetFullPath([string]$_) } | Sort-Object -Unique)
    $mutableNames = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    [void]$mutableNames.Add('HarnessContract.Tests.ps1')
    [void]$mutableNames.Add('PublicSurfacePolicy.Tests.ps1')
    $mutablePaths = [System.Collections.Generic.List[string]]::new()
    $mutableExpectedCount = 0
    foreach ($file in $testFiles | Where-Object { [System.IO.Path]::GetFullPath($_.FullName) -notin $bridgePaths }) {
        $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
        if (-not $testsByFile.ContainsKey($fullPath)) {
            throw "Pester discovery did not return tests for $fullPath"
        }
        if ($mutableNames.Contains($file.Name)) {
            $mutablePaths.Add($fullPath)
            $mutableExpectedCount += [int]$testsByFile[$fullPath].Count
            continue
        }
        $units.Add([PSCustomObject]@{
            WorkerId = 'file-' + [System.IO.Path]::GetFileNameWithoutExtension($file.Name).ToLowerInvariant().Replace('.', '-')
            Paths = @($fullPath)
            LineFilters = @()
            ExpectedCount = [int]$testsByFile[$fullPath].Count
            RepositoryMode = 'source'
        })
    }

    if ($mutablePaths.Count -ne $mutableNames.Count) {
        throw (
            'Mutable Pester owner coverage mismatch: expected={0} actual={1}' -f
            $mutableNames.Count,
            $mutablePaths.Count
        )
    }
    $units.Add([PSCustomObject]@{
        WorkerId = 'mutable-repository'
        Paths = @($mutablePaths | Sort-Object)
        LineFilters = @()
        ExpectedCount = $mutableExpectedCount
        RepositoryMode = 'private'
    })

    foreach ($shard in $shards) {
        $count = 0
        foreach ($path in $shard.Paths) {
            $fullPath = [System.IO.Path]::GetFullPath([string]$path)
            if ($mutableNames.Contains((Split-Path -Leaf $fullPath))) {
                throw "Mutable Pester owner cannot belong to bridge shard $($shard.Name): $fullPath"
            }
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
            RepositoryMode = 'source'
        })
    }

    $expected = [int](($units | Measure-Object ExpectedCount -Sum).Sum)
    if ($expected -ne [int]$DiscoveryResult.total) {
        throw "Pester work-unit coverage mismatch: units=$expected discovery=$($DiscoveryResult.total)"
    }
    return $units.ToArray()
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
        [Parameter(Mandatory = $true)][string]$ResultsRoot,
        [Parameter(Mandatory = $true)][string]$TestResultPath,
        [Parameter(Mandatory = $true)]$PesterModule,
        [Parameter(Mandatory = $true)][int]$ThrottleLimit,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
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
    $sourceStateBefore = $null
    $suiteResult = $null
    try {
        $sourceStateBefore = Get-PesterRepositoryStateIdentity `
            -RepositoryRoot $RepositoryRoot
        $candidateTree = Get-PesterCandidateTree -RepositoryRoot $RepositoryRoot
        $runnerPath = $PSCommandPath
        $pwshPath = (Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source
        $discoveryRoot = Join-Path $workerResultsRoot '000-discovery'
        $discoveryTemp = Join-Path $executionRoot '000-discovery'
        $discoveryProject = Join-Path $discoveryTemp 'project'
        New-Item -ItemType Directory -Path $discoveryRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $discoveryProject -Force | Out-Null
        $discoveryPrivateRoot = Join-Path $executionRoot 'discovery-repository'
        $discovery = Invoke-WithPesterPrivateRepository `
            -SourceRepositoryRoot $RepositoryRoot `
            -CandidateTree $candidateTree `
            -DestinationRoot $discoveryPrivateRoot `
            -ScriptBlock {
                param($privateRepository)

                $privateRoot = [string]$privateRepository.RepositoryRoot
                $discoverySpec = New-PesterDiscoverySpec `
                    -RepositoryRoot $privateRoot `
                    -ResultRoot $discoveryRoot `
                    -TempDirectory $discoveryTemp `
                    -ProjectDirectory $discoveryProject `
                    -PesterModulePath ([string]$PesterModule.Path)
                $discoverySpecPath = Join-Path $discoveryRoot 'spec.json'
                $discoverySpec |
                    ConvertTo-Json -Depth 8 |
                    Set-Content -LiteralPath $discoverySpecPath -Encoding UTF8
                $discoveryLaunch = @(
                    Invoke-IsolatedPwshWorkers `
                        -SpecPaths @($discoverySpecPath) `
                        -RunnerPath $runnerPath `
                        -PwshPath $pwshPath `
                        -RepositoryRoot $privateRoot `
                        -ThrottleLimit 1 `
                        -TimeoutSeconds $TimeoutSeconds
                )
                if (
                    ($discoveryLaunch.Count -ne 1) -or
                    ($discoveryLaunch[0].ExitCode -ne 0) -or
                    (-not [string]::IsNullOrWhiteSpace(
                        [string]$discoveryLaunch[0].LaunchError
                    ))
                ) {
                    $detail = if ($discoveryLaunch.Count -eq 1) {
                        "$($discoveryLaunch[0].LaunchError) $($discoveryLaunch[0].StdErr)"
                    } else {
                        'no launch result'
                    }
                    throw "Isolated Pester discovery failed: $detail"
                }
                if (
                    -not (
                        Test-Path `
                            -LiteralPath $discoverySpec.ResultPath `
                            -PathType Leaf
                    )
                ) {
                    throw 'Isolated Pester discovery did not write result JSON.'
                }
                $observedDiscovery = Get-Content `
                    -LiteralPath $discoverySpec.ResultPath `
                    -Raw `
                    -Encoding UTF8 |
                    ConvertFrom-Json -ErrorAction Stop
                if (
                    ([string]$observedDiscovery.mode -ne 'discovery') -or
                    ([int]$observedDiscovery.total -le 0)
                ) {
                    throw 'Isolated Pester discovery returned an invalid payload.'
                }
                foreach ($test in @($observedDiscovery.tests)) {
                    $privateFile = [System.IO.Path]::GetFullPath(
                        [string]$test.file
                    )
                    $relativeFile = [System.IO.Path]::GetRelativePath(
                        $privateRoot,
                        $privateFile
                    )
                    if (
                        [System.IO.Path]::IsPathRooted($relativeFile) -or
                        $relativeFile -eq '..' -or
                        $relativeFile.StartsWith(
                            '..' + [System.IO.Path]::DirectorySeparatorChar,
                            [StringComparison]::Ordinal
                        ) -or
                        -not $relativeFile.StartsWith(
                            'tests' + [System.IO.Path]::DirectorySeparatorChar,
                            [StringComparison]::OrdinalIgnoreCase
                        )
                    ) {
                        throw "Discovery path escaped the private tests root: $privateFile"
                    }
                    $test.file = [System.IO.Path]::GetFullPath(
                        (Join-Path $RepositoryRoot $relativeFile)
                    )
                }
                return $observedDiscovery
            }

        $expectedIdentities = @($discovery.tests.identity | ForEach-Object { [string]$_ } | Sort-Object)
        $units = @(New-PesterWorkUnits -RepositoryRoot $RepositoryRoot -DiscoveryResult $discovery)
        $mutablePrivateRoot = Join-Path $executionRoot 'mutable-repository'
        $aggregate = Invoke-WithPesterPrivateRepository `
            -SourceRepositoryRoot $RepositoryRoot `
            -CandidateTree $candidateTree `
            -DestinationRoot $mutablePrivateRoot `
            -ScriptBlock {
                param($privateRepository)

                $privateRoot = [string]$privateRepository.RepositoryRoot
                $specs = [System.Collections.Generic.List[object]]::new()
                $specPaths = [System.Collections.Generic.List[string]]::new()
                $index = 0
                foreach ($unit in $units) {
                    $index++
                    $workerRoot = Join-Path $workerResultsRoot (
                        '{0:d3}-{1}' -f $index, $unit.WorkerId
                    )
                    $workerTemp = Join-Path $executionRoot ('{0:d3}' -f $index)
                    $projectDirectory = Join-Path $workerTemp 'project'
                    New-Item -ItemType Directory -Path $workerRoot -Force | Out-Null
                    New-Item -ItemType Directory -Path $projectDirectory -Force | Out-Null
                    $unitRepositoryRoot = if (
                        [string]$unit.RepositoryMode -ceq 'private'
                    ) {
                        $privateRoot
                    } else {
                        $RepositoryRoot
                    }
                    $unitPaths = @(
                        foreach ($path in @($unit.Paths)) {
                            $sourcePath = [System.IO.Path]::GetFullPath([string]$path)
                            if ([string]$unit.RepositoryMode -ceq 'private') {
                                $relativePath = [System.IO.Path]::GetRelativePath(
                                    $RepositoryRoot,
                                    $sourcePath
                                )
                                if (
                                    [System.IO.Path]::IsPathRooted($relativePath) -or
                                    $relativePath -eq '..' -or
                                    $relativePath.StartsWith(
                                        '..' + [System.IO.Path]::DirectorySeparatorChar,
                                        [StringComparison]::Ordinal
                                    )
                                ) {
                                    throw "Mutable Pester path escaped source root: $sourcePath"
                                }
                                [System.IO.Path]::GetFullPath(
                                    (Join-Path $privateRoot $relativePath)
                                )
                            } else {
                                $sourcePath
                            }
                        }
                    )
                    $spec = [ordered]@{
                        Mode = 'Test'
                        WorkerId = [string]$unit.WorkerId
                        RepositoryRoot = $unitRepositoryRoot
                        RepositoryMode = [string]$unit.RepositoryMode
                        Paths = $unitPaths
                        LineFilters = @($unit.LineFilters)
                        ExpectedCount = [int]$unit.ExpectedCount
                        ResultPath = Join-Path $workerRoot 'result.json'
                        NUnitPath = Join-Path $workerRoot 'result.xml'
                        StdOutPath = Join-Path $workerRoot 'stdout.log'
                        StdErrPath = Join-Path $workerRoot 'stderr.log'
                        TempDirectory = $workerTemp
                        ProjectDirectory = $projectDirectory
                        PesterModulePath = [string]$PesterModule.Path
                    }
                    $specPath = Join-Path $workerRoot 'spec.json'
                    $spec |
                        ConvertTo-Json -Depth 8 |
                        Set-Content -LiteralPath $specPath -Encoding UTF8
                    $specs.Add([PSCustomObject]$spec)
                    $specPaths.Add($specPath)
                }

                if (
                    @($specs.TempDirectory | Sort-Object -Unique).Count -ne
                    $specs.Count
                ) {
                    throw 'Pester worker TEMP directories are not unique.'
                }
                if (
                    @($specs.ProjectDirectory | Sort-Object -Unique).Count -ne
                    $specs.Count
                ) {
                    throw 'Pester worker project directories are not unique.'
                }

                $launches = @(
                    Invoke-IsolatedPwshWorkers `
                        -SpecPaths $specPaths.ToArray() `
                        -RunnerPath $runnerPath `
                        -PwshPath $pwshPath `
                        -RepositoryRoot $RepositoryRoot `
                        -ThrottleLimit (
                            [math]::Min($ThrottleLimit, $specPaths.Count)
                        ) `
                        -TimeoutSeconds $TimeoutSeconds
                )

                $workerPayloads = [System.Collections.Generic.List[object]]::new()
                foreach ($launch in $launches | Sort-Object WorkerId) {
                    if (
                        -not [string]::IsNullOrWhiteSpace(
                            [string]$launch.LaunchError
                        )
                    ) {
                        $harnessFailures.Add(
                            "$($launch.WorkerId): launch failed: $($launch.LaunchError)"
                        )
                        continue
                    }
                    $spec = Get-Content `
                        -LiteralPath $launch.SpecPath `
                        -Raw `
                        -Encoding UTF8 |
                        ConvertFrom-Json
                    if (-not (Test-Path -LiteralPath $spec.ResultPath -PathType Leaf)) {
                        $harnessFailures.Add(
                            "$($launch.WorkerId): result JSON is missing"
                        )
                        continue
                    }
                    try {
                        $payload = Get-Content `
                            -LiteralPath $spec.ResultPath `
                            -Raw `
                            -Encoding UTF8 |
                            ConvertFrom-Json -ErrorAction Stop
                    } catch {
                        $harnessFailures.Add(
                            "$($launch.WorkerId): result JSON is invalid: $($_.Exception.Message)"
                        )
                        continue
                    }
                    if ([string]$payload.workerId -ne [string]$launch.WorkerId) {
                        $harnessFailures.Add(
                            "$($launch.WorkerId): result worker identity mismatch"
                        )
                    }
                    if ([int]$payload.total -ne [int]$spec.ExpectedCount) {
                        $harnessFailures.Add(
                            "$($launch.WorkerId): expected $($spec.ExpectedCount) tests, got $($payload.total)"
                        )
                    }
                    if (-not (Test-Path -LiteralPath $payload.nunitPath -PathType Leaf)) {
                        $harnessFailures.Add(
                            "$($launch.WorkerId): NUnit XML is missing"
                        )
                    } else {
                        try {
                            [xml](
                                Get-Content `
                                    -LiteralPath $payload.nunitPath `
                                    -Raw `
                                    -Encoding UTF8
                            ) | Out-Null
                        } catch {
                            $harnessFailures.Add(
                                "$($launch.WorkerId): NUnit XML is invalid: $($_.Exception.Message)"
                            )
                        }
                    }
                    if ([int]$launch.ExitCode -ne 0) {
                        $detail = if (
                            $payload.PSObject.Properties.Name -contains 'harnessError'
                        ) {
                            [string]$payload.harnessError
                        } else {
                            [string]$launch.StdErr
                        }
                        $harnessFailures.Add(
                            "$($launch.WorkerId): child exit $($launch.ExitCode) $detail"
                        )
                    }
                    $workerPayloads.Add($payload)
                }

                $totalCount = [int](
                    ($workerPayloads | Measure-Object total -Sum).Sum
                )
                $passedCount = [int](
                    ($workerPayloads | Measure-Object passed -Sum).Sum
                )
                $failedCount = [int](
                    ($workerPayloads | Measure-Object failed -Sum).Sum
                )
                $skippedCount = [int](
                    ($workerPayloads | Measure-Object skipped -Sum).Sum
                )
                $notRunCount = [int](
                    ($workerPayloads | Measure-Object notRun -Sum).Sum
                )
                $inconclusiveCount = [int](
                    ($workerPayloads | Measure-Object inconclusive -Sum).Sum
                )
                $failedBlocks = [int](
                    ($workerPayloads | Measure-Object failedBlocks -Sum).Sum
                )
                $failedContainers = [int](
                    ($workerPayloads | Measure-Object failedContainers -Sum).Sum
                )
                $actualIdentities = @(
                    $workerPayloads.identities |
                        ForEach-Object { [string]$_ } |
                        Sort-Object
                )
                if ($totalCount -ne [int]$discovery.total) {
                    $harnessFailures.Add(
                        "aggregate total $totalCount does not match discovery total $($discovery.total)"
                    )
                }
                if ($actualIdentities.Count -ne $expectedIdentities.Count) {
                    $harnessFailures.Add(
                        "identity count $($actualIdentities.Count) does not match discovery $($expectedIdentities.Count)"
                    )
                } else {
                    for (
                        $identityIndex = 0;
                        $identityIndex -lt $expectedIdentities.Count;
                        $identityIndex++
                    ) {
                        if (
                            $expectedIdentities[$identityIndex] -cne
                            $actualIdentities[$identityIndex]
                        ) {
                            $harnessFailures.Add(
                                "test identity multiset mismatch at index $identityIndex"
                            )
                            break
                        }
                    }
                }

                return [PSCustomObject]@{
                    WorkerPayloads = $workerPayloads
                    TotalCount = $totalCount
                    PassedCount = $passedCount
                    FailedCount = $failedCount
                    SkippedCount = $skippedCount
                    NotRunCount = $notRunCount
                    InconclusiveCount = $inconclusiveCount
                    FailedBlocks = $failedBlocks
                    FailedContainers = $failedContainers
                    ActualIdentities = $actualIdentities
                }
            }

        $stopwatch.Stop()
        $nunitPaths = @(
            $aggregate.WorkerPayloads.nunitPath |
                ForEach-Object { [string]$_ }
        )
        if ($nunitPaths.Count -eq $aggregate.WorkerPayloads.Count) {
            Merge-NUnitResults `
                -Paths $nunitPaths `
                -OutputPath $TestResultPath `
                -TotalCount $aggregate.TotalCount `
                -FailedCount $aggregate.FailedCount `
                -ErrorsCount (
                    $aggregate.FailedBlocks + $aggregate.FailedContainers
                ) `
                -SkippedCount $aggregate.SkippedCount `
                -NotRunCount $aggregate.NotRunCount `
                -InconclusiveCount $aggregate.InconclusiveCount `
                -DurationSeconds $stopwatch.Elapsed.TotalSeconds
        }

        $suiteResult = [PSCustomObject]@{
            RunId = $runId
            DurationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
            WorkerCount = $units.Count
            TotalCount = $aggregate.TotalCount
            PassedCount = $aggregate.PassedCount
            FailedCount = $aggregate.FailedCount
            SkippedCount = $aggregate.SkippedCount
            NotRunCount = $aggregate.NotRunCount
            FailedBlocksCount = $aggregate.FailedBlocks
            FailedContainersCount = $aggregate.FailedContainers
            IdentityHash = Get-IdentityHash -Identities $aggregate.ActualIdentities
            DiscoveryIdentityHash = Get-IdentityHash -Identities $expectedIdentities
            HarnessFailures = @()
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
        if ($null -ne $sourceStateBefore) {
            try {
                $sourceStateAfter = Get-PesterRepositoryStateIdentity `
                    -RepositoryRoot $RepositoryRoot
                Assert-PesterRepositoryStateIdentity `
                    -Expected $sourceStateBefore `
                    -Actual $sourceStateAfter
            } catch {
                $harnessFailures.Add([string]$_.Exception.Message)
                if ($null -eq $suiteResult) {
                    throw
                }
            }
        }
    }
    if ($null -eq $suiteResult) {
        throw 'Pester parallel suite completed without an aggregate result.'
    }
    $suiteResult.HarnessFailures = @($harnessFailures)
    return $suiteResult
}

if (-not [string]::IsNullOrWhiteSpace($WorkerSpecPath)) {
    $workerExitCode = 2
    if (-not [string]::IsNullOrWhiteSpace($WorkerStdOutPath) -and -not [string]::IsNullOrWhiteSpace($WorkerStdErrPath)) {
        $WorkerStdOutPath = [System.IO.Path]::GetFullPath($WorkerStdOutPath)
        $WorkerStdErrPath = [System.IO.Path]::GetFullPath($WorkerStdErrPath)
        New-Item -ItemType Directory -Path (Split-Path -Parent $WorkerStdOutPath) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $WorkerStdErrPath) -Force | Out-Null
        & {
            $script:workerExitCode = Invoke-PesterWorker -SpecPath ([System.IO.Path]::GetFullPath($WorkerSpecPath))
        } 1> $WorkerStdOutPath 2> $WorkerStdErrPath
    } else {
        $workerExitCode = Invoke-PesterWorker -SpecPath ([System.IO.Path]::GetFullPath($WorkerSpecPath))
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

$pesterModule = Get-PesterModule
if (-not $pesterModule) {
    Write-TestSummary -Path $summaryPath -PassedCount 0 -FailedCount 1 -TotalCount 0 -CoveragePercent $null -CoverageThreshold $CoverageThreshold -Additional @{ mode = 'unavailable' }
    Write-Output 'Pester: module not found'
    Write-Output 'Coverage: unavailable'
    exit 1
}

$useParallel = [bool]$Parallel -and -not [bool]$Coverage -and ($pesterModule.Version.Major -ge 5)
if ($env:WINSMUX_UPDATE_GOLDEN -eq '1') {
    $useParallel = $false
    Write-Output 'Pester: parallel execution disabled because WINSMUX_UPDATE_GOLDEN=1'
}

try {
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
        $parallelResult = Invoke-ParallelSuite -RepositoryRoot $repositoryRoot -ResultsRoot $ResultsDirectory -TestResultPath $testResultPath -PesterModule $pesterModule -ThrottleLimit $MaxParallel -TimeoutSeconds $WorkerTimeoutSeconds
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
            harnessFailures = @($parallelResult.HarnessFailures)
        }
        Write-TestSummary -Path $summaryPath -PassedCount $parallelResult.PassedCount -FailedCount $parallelResult.FailedCount -TotalCount $parallelResult.TotalCount -CoveragePercent $null -CoverageThreshold $CoverageThreshold -Additional $additional
        Write-Output ('Pester: Passed={0} Failed={1} Total={2}' -f $parallelResult.PassedCount, $parallelResult.FailedCount, $parallelResult.TotalCount)
        Write-Output 'Coverage: disabled'
        Write-Output ('Parallel: Workers={0} Duration={1:N3}s MaxParallel={2}' -f $parallelResult.WorkerCount, $parallelResult.DurationSeconds, $MaxParallel)
        foreach ($failure in @($parallelResult.HarnessFailures)) {
            Write-Warning $failure
        }
        if (($parallelResult.FailedCount -eq 0) -and
            ($parallelResult.FailedBlocksCount -eq 0) -and
            ($parallelResult.FailedContainersCount -eq 0) -and
            (@($parallelResult.HarnessFailures).Count -eq 0)) {
            exit 0
        }
        exit 1
    }

    $serial = Invoke-WithIsolatedGitEnvironment -ScriptBlock {
        $serial = Invoke-SerialSuite -RepositoryRoot $repositoryRoot -TestResultPath $testResultPath -CoverageReportPath $coverageReportPath -PesterModule $pesterModule -EnableCoverage:$Coverage
        return $serial
    }
    $result = $serial.Result
    $passedCount = [int](Get-ObjectProperty -InputObject $result -Name 'PassedCount' -DefaultValue 0)
    $failedCount = [int](Get-ObjectProperty -InputObject $result -Name 'FailedCount' -DefaultValue 0)
    $totalCount = [int](Get-ObjectProperty -InputObject $result -Name 'TotalCount' -DefaultValue ($passedCount + $failedCount))
    $skippedCount = [int](Get-ObjectProperty -InputObject $result -Name 'SkippedCount' -DefaultValue 0)
    $notRunCount = [int](Get-ObjectProperty -InputObject $result -Name 'NotRunCount' -DefaultValue 0)
    $failedBlocksCount = [int](Get-ObjectProperty -InputObject $result -Name 'FailedBlocksCount' -DefaultValue 0)
    $failedContainersCount = [int](Get-ObjectProperty -InputObject $result -Name 'FailedContainersCount' -DefaultValue 0)
    $resultTests = @(Get-ObjectProperty -InputObject $result -Name 'Tests' -DefaultValue @())
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

    if (($failedCount -eq 0) -and
        ($failedBlocksCount -eq 0) -and
        ($failedContainersCount -eq 0) -and
        $thresholdMet) {
        exit 0
    }
    exit 1
} catch {
    Write-TestSummary -Path $summaryPath -PassedCount 0 -FailedCount 1 -TotalCount 0 -CoveragePercent $null -CoverageThreshold $CoverageThreshold -Additional @{ mode = 'harness-error'; error = $_.Exception.Message }
    Write-Output 'Pester: Passed=0 Failed=1 Total=0'
    Write-Output $(if ($Coverage) { 'Coverage: unavailable' } else { 'Coverage: disabled' })
    Write-Error $_
    exit 1
}
