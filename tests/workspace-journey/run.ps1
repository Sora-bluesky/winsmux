#requires -Version 7.0

param(
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [string] $CliExe,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [string] $McpExe,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $CliSha256,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $McpSha256,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [string] $NativeTestExe,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $NativeTestSha256,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [string] $NativeMcpExe,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $NativeMcpSha256,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string] $CandidateTree,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [string] $StoreRoot,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [string] $FixturePath,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [string] $FixtureParentRoot,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [string] $ReceiptPath,
    [Parameter(ParameterSetName = 'SelfTest', Mandatory = $true)]
    [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class WorkspaceJourneyProcessTimes {
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessTimes(IntPtr process, out long created,
        out long exited, out long kernel, out long user);
    public static long CreationFiletime(IntPtr process) {
        long created, exited, kernel, user;
        if (!GetProcessTimes(process, out created, out exited, out kernel, out user))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return created;
    }
}
'@

function Assert-ExecutableIdentity {
    param([string] $Path, [string] $ExpectedSha256, [string] $Label)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "$Label path must be absolute" }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Extension -ine '.exe') { throw "$Label must be an executable file" }
    $actual = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    if ($actual -ine $ExpectedSha256) { throw "$Label SHA-256 mismatch" }
    return $item.FullName
}

function Write-AtomicBytes {
    param([string] $Path, [byte[]] $Bytes)
    if (Test-Path -LiteralPath $Path) { throw "Runner receipt already exists: $Path" }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($Bytes); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $Path)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Write-AtomicReceipt {
    param([string] $Path, [hashtable] $Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Compress -Depth 8))
    Write-AtomicBytes -Path $Path -Bytes $bytes
}

function Assert-CapturedStreams {
    param([string] $ReceiptBase)
    $receipt = Get-Content -LiteralPath "$ReceiptBase.eof.json" -Raw -Encoding utf8 |
        ConvertFrom-Json -AsHashtable
    if ($receipt.stage -cne 'streams_eof') { throw 'Stream EOF receipt is absent' }
    foreach ($name in @('stdout', 'stderr')) {
        $path = "$ReceiptBase.$name.bin"
        if (-not [IO.File]::Exists($path)) { throw "Captured $name is missing" }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Captured $name is redirected" }
        $bytes = [IO.File]::ReadAllBytes($path)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if ($receipt["${name}_bytes"] -ne $bytes.Length -or $receipt["${name}_sha256"] -cne $hash) {
            throw "Captured $name differs from EOF receipt"
        }
    }
}

function Invoke-NonPty {
    param([string] $Executable, [string[]] $Arguments, [string] $ExpectedSha256,
        [string] $ReceiptBase, [hashtable] $Environment = @{})
    if ((Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash -ine $ExpectedSha256) {
        throw 'Executable changed before non-PTY launch'
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $Arguments) { [void] $start.ArgumentList.Add($argument) }
    foreach ($key in $Environment.Keys) { $start.Environment[$key] = $Environment[$key] }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $started = @{
            stage = 'started'; pid = $process.Id
            creation_filetime_utc = [WorkspaceJourneyProcessTimes]::CreationFiletime($process.Handle)
            executable_sha256 = $ExpectedSha256.ToLowerInvariant()
            executable = $Executable
        }
        Write-AtomicReceipt -Path "$ReceiptBase.start.json" -Value $started
        $stdoutBuffer = [IO.MemoryStream]::new()
        $stderrBuffer = [IO.MemoryStream]::new()
        try {
            $process.StandardInput.Close()
            $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutBuffer)
            $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrBuffer)
            $process.WaitForExit()
            Write-AtomicReceipt -Path "$ReceiptBase.exit.json" -Value @{
                stage = 'exited'; pid = $process.Id
                creation_filetime_utc = $started.creation_filetime_utc
                executable_sha256 = $started.executable_sha256
                exit_code = $process.ExitCode
            }
            [void]($stdoutTask.GetAwaiter().GetResult())
            [void]($stderrTask.GetAwaiter().GetResult())
            $stdoutBytes = $stdoutBuffer.ToArray()
            $stderrBytes = $stderrBuffer.ToArray()
            Write-AtomicBytes -Path "$ReceiptBase.stdout.bin" -Bytes $stdoutBytes
            Write-AtomicBytes -Path "$ReceiptBase.stderr.bin" -Bytes $stderrBytes
            Write-AtomicReceipt -Path "$ReceiptBase.eof.json" -Value @{
                stage = 'streams_eof'; pid = $process.Id
                creation_filetime_utc = $started.creation_filetime_utc
                stdout_bytes = $stdoutBytes.Length
                stderr_bytes = $stderrBytes.Length
                stdout_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stdoutBytes)).ToLowerInvariant()
                stderr_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stderrBytes)).ToLowerInvariant()
            }
            Assert-CapturedStreams -ReceiptBase $ReceiptBase
            $utf8 = [Text.UTF8Encoding]::new($false, $true)
            return @{ ExitCode = $process.ExitCode; Stdout = $utf8.GetString($stdoutBytes);
                Stderr = $utf8.GetString($stderrBytes); Pid = $process.Id;
                CreationFiletimeUtc = $started.creation_filetime_utc }
        } finally {
            $stdoutBuffer.Dispose()
            $stderrBuffer.Dispose()
        }
    } finally {
        $process.Dispose()
    }
}

function Assert-LogicalEmpty {
    param([string] $Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Store snapshot is not a regular file'
    }
    $snapshot = Get-Content -LiteralPath $item.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($snapshot.schema_version -ne 1 -or $null -ne $snapshot.selected_project_id -or
        $null -ne $snapshot.selected_pane_id -or $snapshot.projects.Count -ne 0 -or
        $snapshot.panes.Count -ne 0 -or $snapshot.layouts.Count -ne 0) {
        throw 'Default store is not logically empty'
    }
    return (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
}

function Assert-FreshDirectChild {
    param([string] $ParentRoot, [string] $ChildPath)
    if (-not [IO.Path]::IsPathFullyQualified($ParentRoot) -or
        -not [IO.Path]::IsPathFullyQualified($ChildPath) -or
        $ParentRoot.StartsWith('\\?\', [StringComparison]::Ordinal) -or
        $ParentRoot.StartsWith('\\.\', [StringComparison]::Ordinal) -or
        $ChildPath.StartsWith('\\?\', [StringComparison]::Ordinal) -or
        $ChildPath.StartsWith('\\.\', [StringComparison]::Ordinal) -or
        @($ParentRoot -split '[\\/]' | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -ne 0 -or
        @($ChildPath -split '[\\/]' | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -ne 0) {
        throw 'Fixture path must use a normal absolute path without aliases'
    }
    $parent = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($ParentRoot))
    $child = [IO.Path]::GetFullPath($ChildPath)
    $name = [IO.Path]::GetFileName($child)
    if ([string]::IsNullOrWhiteSpace($name) -or $name.EndsWith(' ') -or $name.EndsWith('.') -or
        $name.Contains(':') -or
        [IO.Path]::GetDirectoryName($child) -ine $parent) {
        throw 'Fixture path must be a direct child of the canonical root'
    }
    $ancestor = $parent
    while ($null -ne $ancestor) {
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Fixture path has a reparse-point or non-directory ancestor'
        }
        $next = [IO.Path]::GetDirectoryName($ancestor)
        if ($next -eq $ancestor) { break }
        $ancestor = $next
    }
    if (Test-Path -LiteralPath $child) { throw 'Fixture path already exists' }
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($parent)) {
        if ([IO.Path]::GetFileName($entry) -ieq $name) {
            throw 'Fixture path already exists'
        }
    }
    return $child
}

function Assert-ProductReceipt {
    param([string] $Path, [string] $Tree, [string] $CliHash, [string] $McpPath, [string] $McpHash)
    $rows = @(Get-Content -LiteralPath $Path -Encoding utf8 | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
    if ($rows.Count -lt 4) { throw 'Native receipt is incomplete' }
    $start = @($rows | Where-Object { $_.stage -eq 'native start' -and $_.scope -eq 'product-control' -and $_.source_checkpoint -eq $Tree })
    $owner = @($rows | Where-Object { $_.stage -eq 'owner process created' -and $_.exe_sha256 -eq $CliHash })
    $adapters = @($rows | Where-Object { $_.stage -eq 'adapter spawned' -and $_.normal_binary -eq $true -and $_.binary_sha256 -eq $McpHash -and [IO.Path]::GetFullPath($_.binary) -ieq $McpPath })
    $control = @($rows | Where-Object { $_.stage -eq 'actual MCP owned control pane run created' })
    $shellExit = @($rows | Where-Object { $_.stage -eq 'actual MCP owned control shell actual exit' -and $_.public_run_interrupt -eq $true })
    $preStopSave = @($rows | Where-Object { $_.stage -eq 'pre-stop layout save accepted' -and
        $_.generation -eq 0 -and $_.topology_revision -gt 0 })
    $cleanup = @($rows | Where-Object { $_.stage -eq 'owned family cleanup terminated' -and $_.original_test_passed -eq $true -and $_.force_kill -eq $false -and $_.default_logical_preserved -eq $true -and $_.lease_released -eq $true })
    if ($start.Count -ne 1 -or $owner.Count -ne 1 -or $adapters.Count -lt 1 -or
        $control.Count -ne 1 -or $shellExit.Count -ne 1 -or $preStopSave.Count -ne 1 -or $cleanup.Count -ne 1) {
        throw 'Native identity, control, or cleanup receipt did not match'
    }
    return $rows.Count
}

function Assert-Result {
    param($Actual, [int] $ExitCode, [string] $Stderr)
    if ($Actual.ExitCode -ne $ExitCode -or $Actual.Stdout.Length -ne 0 -or $Actual.Stderr.Trim() -cne $Stderr) {
        throw "Unexpected non-PTY classification: exit=$($Actual.ExitCode), stdout-bytes=$([Text.Encoding]::UTF8.GetByteCount($Actual.Stdout)), stderr-classification-matched=$($Actual.Stderr.Trim() -ceq $Stderr)"
    }
}

if ($SelfTest) {
    $ownPath = $MyInvocation.MyCommand.Path
    $ownHash = (Get-FileHash -LiteralPath $ownPath -Algorithm SHA256).Hash
    $fakeExe = Join-Path $PSHOME 'pwsh.exe'
    $fakeHash = (Get-FileHash -LiteralPath $fakeExe -Algorithm SHA256).Hash
    if ((Assert-ExecutableIdentity -Path $fakeExe -ExpectedSha256 $fakeHash -Label 'self-test') -ne $fakeExe) {
        throw 'Self-test did not accept matching executable identity'
    }
    foreach ($case in @(
        @{ Path = 'relative.exe'; Hash = $ownHash },
        @{ Path = $ownPath; Hash = $ownHash },
        @{ Path = $fakeExe; Hash = ('0' * 64) }
    )) {
        $rejected = $false
        try { [void] (Assert-ExecutableIdentity -Path $case.Path -ExpectedSha256 $case.Hash -Label 'self-test') }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Self-test accepted a non-executable or mismatched input' }
    }
    $negative = $false
    try { Assert-ProductReceipt -Path $ownPath -Tree ('0' * 40) -CliHash ('0' * 64) -McpPath $fakeExe -McpHash ('0' * 64) | Out-Null }
    catch { $negative = $true }
    if (-not $negative) { throw 'Self-test accepted a non-receipt' }
    $testRoot = Join-Path $PSScriptRoot ('.self-test-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $testRoot) { throw 'Self-test root collision' }
    [void] (New-Item -ItemType Directory -Path $testRoot)
    $link = $null
    $junctionCheck = 'unavailable'
    try {
        $child = Join-Path $testRoot 'fresh'
        if ((Assert-FreshDirectChild -ParentRoot $testRoot -ChildPath $child) -ine $child) {
            throw 'Self-test rejected a fresh direct child'
        }
        $oldTemp = $env:TEMP
        $oldTmp = $env:TMP
        $oldRunnerTemp = $env:RUNNER_TEMP
        try {
            $differentTemp = Join-Path $testRoot 'ambient-temp'
            [void](New-Item -ItemType Directory -Path $differentTemp)
            $env:TEMP = $differentTemp
            $env:TMP = $differentTemp
            $env:RUNNER_TEMP = $testRoot
            $selectedTemp = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetTempPath())
            $tempFixture = Join-Path $differentTemp 'native-fixture'
            if ($selectedTemp -ine $differentTemp -or $selectedTemp -ieq $env:RUNNER_TEMP -or
                (Assert-FreshDirectChild -ParentRoot $selectedTemp -ChildPath $tempFixture) -ine $tempFixture) {
                throw 'Self-test did not use the native child temp root'
            }
            $rejected = $false
            try { Assert-FreshDirectChild -ParentRoot $selectedTemp -ChildPath (Join-Path $testRoot 'runner-fixture') | Out-Null }
            catch { $rejected = $true }
            if (-not $rejected) { throw 'Self-test accepted a runner-temp fixture outside child temp root' }
        } finally {
            if ($null -eq $oldTemp) { Remove-Item Env:TEMP -ErrorAction SilentlyContinue }
            else { $env:TEMP = $oldTemp }
            if ($null -eq $oldTmp) { Remove-Item Env:TMP -ErrorAction SilentlyContinue }
            else { $env:TMP = $oldTmp }
            if ($null -eq $oldRunnerTemp) { Remove-Item Env:RUNNER_TEMP -ErrorAction SilentlyContinue }
            else { $env:RUNNER_TEMP = $oldRunnerTemp }
        }
        $sibling = Join-Path ([IO.Path]::GetDirectoryName($testRoot)) ([IO.Path]::GetFileName($testRoot) + 'Extra')
        $rejected = $false
        try { Assert-FreshDirectChild -ParentRoot $testRoot -ChildPath (Join-Path $sibling 'fresh') | Out-Null }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Self-test accepted a sibling prefix' }
        $rejected = $false
        try { Assert-FreshDirectChild -ParentRoot $testRoot -ChildPath ('\\?\' + $child) | Out-Null }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Self-test accepted an extended-path alias' }
        $target = Join-Path $testRoot 'target'
        [void] (New-Item -ItemType Directory -Path $target)
        $link = Join-Path $testRoot 'link'
        try { [void] (New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop) }
        catch { $link = $null }
        if ($null -ne $link) {
            $rejected = $false
            try { Assert-FreshDirectChild -ParentRoot $link -ChildPath (Join-Path $link 'fresh') | Out-Null }
            catch { $rejected = $true }
            if (-not $rejected) { throw 'Self-test accepted a reparse-point ancestor' }
            $junctionCheck = 'pass'
        }
        $mockBase = Join-Path $testRoot 'mock'
        $mock = Invoke-NonPty -Executable $fakeExe -Arguments @('-NoProfile', '-Command', 'exit 7') `
            -ExpectedSha256 $fakeHash -ReceiptBase $mockBase
        $mockExit = Get-Content -LiteralPath "$mockBase.exit.json" -Raw | ConvertFrom-Json -AsHashtable
        $mockEof = Get-Content -LiteralPath "$mockBase.eof.json" -Raw | ConvertFrom-Json -AsHashtable
        if ($mock.ExitCode -ne 7 -or $mockExit.exit_code -ne 7 -or
            $mockExit.creation_filetime_utc -ne $mock.CreationFiletimeUtc -or
            $mockEof.creation_filetime_utc -ne $mock.CreationFiletimeUtc) {
            throw 'Self-test process identity, exit, or EOF receipt mismatch'
        }
        $rawBase = Join-Path $testRoot 'raw'
        $raw = Invoke-NonPty -Executable $fakeExe -Arguments @('-NoProfile', '-Command', '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); [Console]::Out.Write("RAW_日本語")') `
            -ExpectedSha256 $fakeHash -ReceiptBase $rawBase
        if ($raw.ExitCode -ne 0 -or $raw.Stdout -cne 'RAW_日本語' -or
            -not [IO.File]::Exists("$rawBase.stdout.bin") -or
            -not [IO.File]::Exists("$rawBase.stderr.bin")) {
            throw 'Raw stdout or stderr was not preserved'
        }
        Assert-CapturedStreams -ReceiptBase $rawBase
        $originalRaw = [IO.File]::ReadAllBytes("$rawBase.stdout.bin")
        Remove-Item -LiteralPath "$rawBase.stdout.bin" -Force
        $rejected = $false
        try { Assert-CapturedStreams -ReceiptBase $rawBase }
        catch { $rejected = $_.Exception.Message -ceq 'Captured stdout is missing' }
        if (-not $rejected) { throw 'Missing raw stdout was accepted' }
        Write-AtomicBytes -Path "$rawBase.stdout.bin" -Bytes $originalRaw
        [IO.File]::WriteAllBytes("$rawBase.stdout.bin", [byte[]]@(0x58))
        $rejected = $false
        try { Assert-CapturedStreams -ReceiptBase $rawBase }
        catch { $rejected = $_.Exception.Message -ceq 'Captured stdout differs from EOF receipt' }
        if (-not $rejected) { throw 'Corrupt raw stdout was accepted' }
    } finally {
        if ($null -ne $link -and (Test-Path -LiteralPath $link)) { Remove-Item -LiteralPath $link -Force }
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($testRoot)) -ine
            [IO.Path]::GetFullPath($PSScriptRoot)) { throw 'Self-test cleanup target escaped its directory' }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    @{ gate = 'workspace-journey/non-pty-boundaries'; self_test = 'pass'; sibling_prefix = 'rejected';
        separate_temp_roots = 'pass'; raw_stdout = 'preserved';
        raw_stdout_missing = 'rejected'; raw_stdout_corrupt = 'rejected';
        junction = $junctionCheck } | ConvertTo-Json -Compress
    exit 0
}

if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:WINSMUX_EPHEMERAL_RUNNER -cne 'github-hosted' -or
    [string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE) -or
    [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE) -ine [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))) {
    throw 'Non-PTY product journey requires the isolated GitHub Windows checkout'
}

$cli = Assert-ExecutableIdentity -Path $CliExe -ExpectedSha256 $CliSha256 -Label 'CLI'
$mcp = Assert-ExecutableIdentity -Path $McpExe -ExpectedSha256 $McpSha256 -Label 'MCP'
$nativeTest = Assert-ExecutableIdentity -Path $NativeTestExe -ExpectedSha256 $NativeTestSha256 -Label 'native test'
$nativeMcp = Assert-ExecutableIdentity -Path $NativeMcpExe -ExpectedSha256 $NativeMcpSha256 -Label 'native MCP'
if ($cli -ieq $mcp) { throw 'CLI and MCP must be different executable files' }
if ($nativeMcp -ieq $mcp) { throw 'Native debug MCP and release MCP must be different executable files' }

$expectedStoreRoot = Join-Path $env:LOCALAPPDATA 'winsmux/workspace/v1'
if ([IO.Path]::GetFullPath($StoreRoot) -ine [IO.Path]::GetFullPath($expectedStoreRoot)) {
    throw 'Store root is not the default Windows workspace store'
}
if ([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($FixtureParentRoot)) -ine
    [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))) {
    throw 'Fixture parent does not match native child temp root'
}
$fixture = Assert-FreshDirectChild -ParentRoot $FixtureParentRoot -ChildPath $FixturePath
if (-not [IO.Path]::IsPathFullyQualified($ReceiptPath) -or (Test-Path -LiteralPath $ReceiptPath)) {
    throw 'Receipt path must be a new absolute path'
}
$receiptParent = Split-Path -Parent $ReceiptPath
if (-not (Test-Path -LiteralPath $receiptParent -PathType Container)) {
    throw 'Receipt parent directory must already exist'
}
$confirmed = Join-Path $StoreRoot 'confirmed.json'
$backup = Join-Path $StoreRoot 'backup.json'
$confirmedBefore = Assert-LogicalEmpty -Path $confirmed
$backupBefore = Assert-LogicalEmpty -Path $backup

# Public host launch requires a real terminal. A redirected attempt must not
# create an owner, discovery, project, pane, or any persistent workspace state.
$hostResult = Invoke-NonPty -Executable $cli -Arguments @('workspace', 'host') -ExpectedSha256 $CliSha256 -ReceiptBase "$ReceiptPath.runner-host"
Assert-Result -Actual $hostResult -ExitCode 2 -Stderr 'winsmux workspace: interactive_required'
if ((Assert-LogicalEmpty -Path $confirmed) -cne $confirmedBefore -or
    (Assert-LogicalEmpty -Path $backup) -cne $backupBefore) {
    throw 'Non-PTY host refusal changed the default store'
}

# The MCP process rejects malformed startup arguments before opening transport.
$mcpResult = Invoke-NonPty -Executable $mcp -Arguments @() -ExpectedSha256 $McpSha256 -ReceiptBase "$ReceiptPath.runner-mcp"
Assert-Result -Actual $mcpResult -ExitCode 2 -Stderr 'winsmux workspace mcp: usage'
if ((Assert-LogicalEmpty -Path $confirmed) -cne $confirmedBefore -or
    (Assert-LogicalEmpty -Path $backup) -cne $backupBefore) {
    throw 'Invalid MCP startup changed the default store'
}

$nativeEnvironment = @{
    TEMP = [IO.Path]::GetFullPath($FixtureParentRoot)
    TMP = [IO.Path]::GetFullPath($FixtureParentRoot)
    TASK875_CLI_BIN = $cli
    TASK875_CLI_SHA256 = $CliSha256.ToLowerInvariant()
    TASK875_RELEASE_MCP_BIN = $mcp
    TASK875_NATIVE_CLASS = 'product-control'
    TASK875_STORE_ROOT = [IO.Path]::GetFullPath($StoreRoot)
    TASK875_NATIVE_PROJECT_PATH = $fixture
    TASK875_EXECUTION_RECEIPT = [IO.Path]::GetFullPath($ReceiptPath)
    TASK875_CHECKPOINT_SHA256 = $CandidateTree.ToLowerInvariant()
}
$preopenFixture = Assert-FreshDirectChild -ParentRoot $FixtureParentRoot -ChildPath (Join-Path $FixtureParentRoot 'workspace-journey-preopen')
$preopenReceipt = "$ReceiptPath.preopen.jsonl"
if (Test-Path -LiteralPath $preopenReceipt) { throw 'Pre-open receipt path is not fresh' }
$preopenEnvironment = $nativeEnvironment.Clone()
$preopenEnvironment.TASK875_NATIVE_CLASS = 'preopen-failure'
$preopenEnvironment.TASK875_NATIVE_PROJECT_PATH = $preopenFixture
$preopenEnvironment.TASK875_EXECUTION_RECEIPT = $preopenReceipt
$preopenResult = Invoke-NonPty -Executable $nativeTest -Arguments @() -ExpectedSha256 $NativeTestSha256 -ReceiptBase "$ReceiptPath.runner-preopen" -Environment $preopenEnvironment
if ($preopenResult.ExitCode -ne 101) { throw "Pre-open failure did not preserve the test failure: $($preopenResult.ExitCode)" }
$preopenRows = @(Get-Content -LiteralPath $preopenReceipt -Encoding utf8 | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
$injected = @($preopenRows | Where-Object { $_.stage -eq 'pre-open failure injected' -and
    $_.original_failure -ceq 'TASK875_PREOPEN_INJECTED' -and $_.topology_mutated -eq $false })
$preopenExit = @($preopenRows | Where-Object { $_.stage -eq 'owner terminated' -and
    $_.exit_code -eq 0 -and $_.force_kill -eq $false })
$preopenCleanup = @($preopenRows | Where-Object { $_.stage -eq 'owned family cleanup terminated' -and
    $_.original_test_passed -eq $false -and $_.lease_released -eq $true -and
    $_.root_identity_preserved -eq $true -and $_.force_kill -eq $false })
$preopenSave = @($preopenRows | Where-Object { $_.stage -eq 'pre-stop layout save requested' })
if ($injected.Count -ne 1 -or $preopenExit.Count -ne 1 -or $preopenCleanup.Count -ne 1 -or
    $preopenSave.Count -ne 0 -or (Test-Path -LiteralPath $preopenFixture)) {
    throw 'Pre-open failure did not complete owned recovery without a preparatory save'
}
foreach ($path in @($confirmed, $backup)) {
    Assert-LogicalEmpty -Path $path | Out-Null
    $snapshot = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($snapshot.generation -ne 0 -or $snapshot.topology_revision -ne 0) {
        throw 'Pre-open cleanup advanced the empty store'
    }
}
$nativeResult = Invoke-NonPty -Executable $nativeTest -Arguments @() -ExpectedSha256 $NativeTestSha256 -ReceiptBase "$ReceiptPath.runner-native" -Environment $nativeEnvironment
if ($nativeResult.ExitCode -ne 0) { throw "Native product-control exited $($nativeResult.ExitCode); receipt retained for diagnosis" }
if (-not [string]::IsNullOrWhiteSpace($nativeResult.Stderr)) { throw 'Native product-control wrote unexpected stderr' }
$nativeRows = @($nativeResult.Stdout -split "`r?`n" | Where-Object { $_ -match '^\{' } |
    ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
$nativeStart = @($nativeRows | Where-Object { $_.class -eq 'actual CLI/ConPTY native start' -and $_.default_logical_empty -eq $true })
$nativeEnd = @($nativeRows | Where-Object { $_.class -eq 'native family termination' -and
    $_.default_logical_preserved -eq $true -and $_.lease_released -eq $true -and $_.owner_normal_exit -eq $true })
$nativeSave = @($nativeRows | Where-Object { $_.class -eq 'native store save' -and
    $_.backup_matches_pre_stop_confirmed -eq $true -and $_.post_stop_confirmed_logical_empty -eq $true -and
    $_.positive_advanced_equal_revision -eq $true })
$controlOutput = @($nativeRows |
    Where-Object { $_.class -eq 'normal MCP actual operator-granted pane run resize input output and cleanup' -and
        $_.MCP_pane_close -eq $true -and $_.MCP_run_interrupt_actual_exit -eq $true -and
        $_.actual_console_cols -eq 100 -and $_.actual_console_rows -eq 28 -and
        $_.self_approval -eq $false -and $_.unrelated_canary_preserved -eq $true })
if ($nativeStart.Count -ne 1 -or $controlOutput.Count -ne 1 -or $nativeEnd.Count -ne 1 -or $nativeSave.Count -ne 1) {
    throw 'Native stdout lacks start, control, store save, or owned termination result'
}
$receiptLines = Assert-ProductReceipt -Path $ReceiptPath -Tree $CandidateTree.ToLowerInvariant() -CliHash $CliSha256.ToLowerInvariant() -McpPath $nativeMcp -McpHash $NativeMcpSha256.ToLowerInvariant()
Assert-LogicalEmpty -Path $confirmed | Out-Null
Assert-LogicalEmpty -Path $backup | Out-Null
if (Test-Path -LiteralPath $fixture) {
    throw 'Native journey did not remove its owned fixture'
}

@{
    gate = 'workspace-journey/non-pty-boundaries'
    status = 'pass'
    cli_sha256 = $CliSha256.ToLowerInvariant()
    mcp_sha256 = $McpSha256.ToLowerInvariant()
    cli_host_without_terminal = 'interactive_required'
    mcp_without_discovery = 'usage'
    native_test_sha256 = $NativeTestSha256.ToLowerInvariant()
    native_mcp_sha256 = $NativeMcpSha256.ToLowerInvariant()
    candidate_tree = $CandidateTree.ToLowerInvariant()
    receipt_sha256 = (Get-FileHash -LiteralPath $ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    receipt_lines = $receiptLines
    positive_journey = 'pass_product_control_cli_mcp'
} | ConvertTo-Json -Compress
