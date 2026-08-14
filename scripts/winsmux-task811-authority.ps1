#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('library', 'controller', 'discovery', 'worker')]
    [string]$Task811InternalMode = 'library',
    [string]$Task811RepositoryRoot = '',
    [string]$Task811ReceiptPath = '',
    [string]$Task811WorkingRoot = '',
    [int]$Task811CiConsumerPid = 0,
    [string]$Task811CiConsumerImagePath = '',
    [string]$Task811CiConsumerEvidencePath = '',
    [string]$Task811TransactionNonce = '',
    [int]$Task811ControllerPid = 0,
    [string]$Task811TargetPath = '',
    [string]$Task811MeasureResultPath = '',
    [string]$Task811VerifySignalPath = '',
    [string]$Task811VerifyResultPath = '',
    [string]$Task811ReceiptSignalPath = '',
    [string]$Task811ReceiptAckPath = '',
    [switch]$Task811CrashBeforeReceiptWrite,
    [switch]$Task811TerminateWorkerBeforeReceiptWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Task811AuthorityPath = [IO.Path]::GetFullPath($PSCommandPath)
$script:Task811RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:Task811PesterModulePath = Join-Path $PSScriptRoot 'winsmux-pester.psm1'
$script:Task811ReceiptRelativePath = 'artifacts/operator-infra/task811-receipt.json'
$script:Task811ReceiptPath = [IO.Path]::GetFullPath((Join-Path $script:Task811RepoRoot $script:Task811ReceiptRelativePath))
$script:Task811ReceiptSchema = 'winsmux.task811.receipt.v1'
$script:Task811TransactionOrder = @(
    'measure_bytes'
    'spawn_graph'
    'child_entry'
    'write_receipt'
    'bind_artifact'
    'upload'
    'merge'
)
$script:Task811CompletedOrder = @(
    'measure_bytes'
    'spawn_graph'
    'child_entry'
    'write_receipt'
    'bind_artifact'
)

function Throw-Task811FailClosed {
    param([Parameter(Mandatory)][string]$Reason)
    throw [InvalidOperationException]::new("TASK811_FAIL_CLOSED $Reason")
}

function Assert-Task811Condition {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Reason
    )
    if (-not $Condition) {
        Throw-Task811FailClosed -Reason $Reason
    }
}

function Test-Task811SamePath {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [string]::Equals([IO.Path]::GetFullPath($Left), [IO.Path]::GetFullPath($Right), $comparison)
}

function Get-Task811Sha256Bytes {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-Task811FileEvidence {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-Task811Condition (Test-Path -LiteralPath $fullPath -PathType Leaf) 'byte_target_missing'
    $item = Get-Item -LiteralPath $fullPath -Force
    Assert-Task811Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'byte_target_reparse_point'

    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $length = [long]$stream.Length
        $hasher = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = [Convert]::ToHexString($hasher.ComputeHash($stream)).ToLowerInvariant()
        } finally {
            $hasher.Dispose()
        }
    } finally {
        $stream.Dispose()
    }

    Assert-Task811Condition ($length -gt 0) 'byte_target_empty'
    return [pscustomobject][ordered]@{
        path        = $fullPath
        sha256      = $hash
        byte_length = $length
    }
}

function Get-Task811ModuleBaseTreeEvidence {
    param([Parameter(Mandatory)][string]$ModuleBase)

    $base = [IO.Path]::GetFullPath($ModuleBase).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    Assert-Task811Condition (Test-Path -LiteralPath $base -PathType Container) 'pester_module_base_missing'
    $baseItem = Get-Item -LiteralPath $base -Force
    Assert-Task811Condition (($baseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'pester_module_base_reparse_point'

    $rootPrefix = $base + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $pathToEvidence = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $caseFoldedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($directory in @(Get-ChildItem -LiteralPath $base -Directory -Recurse -Force -ErrorAction Stop)) {
        Assert-Task811Condition (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'pester_tree_directory_reparse_point'
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $base -File -Recurse -Force -ErrorAction Stop)) {
        $fullPath = [IO.Path]::GetFullPath($file.FullName)
        Assert-Task811Condition ($fullPath.StartsWith($rootPrefix, $comparison)) 'pester_tree_path_escape'
        Assert-Task811Condition (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'pester_tree_reparse_point'
        $relativePath = [IO.Path]::GetRelativePath($base, $fullPath).Replace('\', '/')
        Assert-Task811Condition (-not [string]::IsNullOrWhiteSpace($relativePath)) 'pester_tree_empty_relative_path'
        Assert-Task811Condition ($relativePath.IndexOf("`t", [StringComparison]::Ordinal) -lt 0) 'pester_tree_tab_in_path'
        Assert-Task811Condition ($relativePath.IndexOf("`n", [StringComparison]::Ordinal) -lt 0) 'pester_tree_newline_in_path'
        Assert-Task811Condition (-not $pathToEvidence.ContainsKey($relativePath)) 'pester_tree_duplicate_path'
        Assert-Task811Condition ($caseFoldedPaths.Add($relativePath)) 'pester_tree_case_collision'
        $pathToEvidence.Add($relativePath, (Get-Task811FileEvidence -Path $fullPath))
    }

    Assert-Task811Condition ($pathToEvidence.Count -gt 0) 'pester_tree_empty'
    $relativePaths = [string[]]@($pathToEvidence.Keys)
    [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $incrementalHash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        foreach ($relativePath in $relativePaths) {
            $fileEvidence = $pathToEvidence[$relativePath]
            $line = '{0}{1}{2}{3}' -f $relativePath, "`t", ([string]$fileEvidence.sha256), "`n"
            $incrementalHash.AppendData($utf8.GetBytes($line))
        }
        $treeHash = [Convert]::ToHexString($incrementalHash.GetHashAndReset()).ToLowerInvariant()
    } finally {
        $incrementalHash.Dispose()
    }

    return [pscustomobject][ordered]@{
        module_base = $base
        file_count  = [int]$relativePaths.Count
        sha256      = $treeHash
    }
}

function ConvertTo-Task811CanonicalJsonBytes {
    param([Parameter(Mandatory)]$Value)
    $json = ($Value | ConvertTo-Json -Depth 32 -Compress) + "`n"
    return [Text.UTF8Encoding]::new($false, $true).GetBytes($json)
}

function Write-Task811AtomicBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Bytes
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $parentItem = Get-Item -LiteralPath $parent -Force
    Assert-Task811Condition (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'write_parent_reparse_point'
    $temporaryPath = Join-Path $parent ('.task811-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.FileStream]::new(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        Assert-Task811Condition (-not (Test-Path -LiteralPath $fullPath)) 'atomic_write_target_exists'
        Move-Item -LiteralPath $temporaryPath -Destination $fullPath
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Write-Task811JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    Write-Task811AtomicBytes -Path $Path -Bytes (ConvertTo-Task811CanonicalJsonBytes -Value $Value)
}

function Read-Task811JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    Assert-Task811Condition (Test-Path -LiteralPath $Path -PathType Leaf) 'json_file_missing'
    $bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path))
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        return ($text | ConvertFrom-Json -Depth 32 -ErrorAction Stop)
    } catch {
        Throw-Task811FailClosed -Reason 'json_file_malformed'
    }
}

function Get-Task811ParentProcessId {
    param([Parameter(Mandatory)][int]$ProcessId)
    Assert-Task811Condition $IsWindows 'process_graph_requires_windows'
    $rows = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop)
    Assert-Task811Condition ($rows.Count -eq 1) 'process_graph_pid_not_live'
    $parentProcessId = [int]$rows[0].ParentProcessId
    Assert-Task811Condition ($parentProcessId -gt 0) 'process_graph_parent_missing'
    return $parentProcessId
}

function Get-Task811ProcessEvidence {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$ExpectedImagePath
    )
    Assert-Task811Condition ($ProcessId -gt 0) 'process_graph_pid_invalid'
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $imagePath = [string]$process.Path
    Assert-Task811Condition (-not [string]::IsNullOrWhiteSpace($imagePath)) 'process_graph_image_path_missing'
    Assert-Task811Condition (Test-Task811SamePath -Left $imagePath -Right $ExpectedImagePath) 'process_graph_image_path_mismatch'
    $imageEvidence = Get-Task811FileEvidence -Path $imagePath
    $cimRows = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop)
    Assert-Task811Condition ($cimRows.Count -eq 1) 'process_graph_pid_not_live'
    $parentProcessId = [int]$cimRows[0].ParentProcessId
    Assert-Task811Condition ($parentProcessId -gt 0) 'process_graph_parent_missing'
    $creationTimeUtcTicks = ([DateTime]$cimRows[0].CreationDate).ToUniversalTime().Ticks
    return [pscustomobject][ordered]@{
        pid            = $ProcessId
        image_path     = [string]$imageEvidence.path
        image_sha256   = [string]$imageEvidence.sha256
        parent_pid     = $parentProcessId
        start_time_utc_ticks = [long]$creationTimeUtcTicks
    }
}

function Assert-Task811ProcessEvidenceEqual {
    param(
        [Parameter(Mandatory)]$SelfObserved,
        [Parameter(Mandatory)]$ControllerObserved,
        [Parameter(Mandatory)][string]$Role
    )
    foreach ($field in @('pid', 'image_path', 'image_sha256', 'parent_pid', 'start_time_utc_ticks')) {
        Assert-Task811Condition ([string]$SelfObserved.$field -ceq [string]$ControllerObserved.$field) "process_graph_${Role}_${field}_mismatch"
    }
}

function Get-Task811PwshPath {
    $command = Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $source = [string]$command.Source
    Assert-Task811Condition (-not [string]::IsNullOrWhiteSpace($source)) 'pwsh_source_missing'
    return [IO.Path]::GetFullPath($source)
}

function Get-Task811GitTreeId {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $output = @(& git -C $RepositoryRoot write-tree 2>$null)
    Assert-Task811Condition ($LASTEXITCODE -eq 0) 'git_write_tree_failed'
    Assert-Task811Condition ($output.Count -eq 1) 'git_write_tree_shape_invalid'
    $treeId = ([string]$output[0]).Trim()
    Assert-Task811Condition ($treeId -cmatch '^[0-9a-f]{40}$') 'git_write_tree_id_invalid'
    return $treeId
}

function Get-Task811PesterSelection {
    Import-Module -Name $script:Task811PesterModulePath -Force -ErrorAction Stop
    $selection = Resolve-WinsmuxPester571
    Assert-Task811Condition ($null -ne $selection) 'pester_resolution_missing'
    Assert-Task811Condition ([string]$selection.resolution_status -ceq 'resolved') 'pester_resolution_not_resolved'
    Assert-Task811Condition (Test-Path -LiteralPath ([string]$selection.manifest_path) -PathType Leaf) 'pester_manifest_missing'
    Assert-Task811Condition (Test-Path -LiteralPath ([string]$selection.module_base) -PathType Container) 'pester_module_base_missing'
    return $selection
}

function Import-Task811SelectedPester {
    param([Parameter(Mandatory)]$Selection)
    $expectedBase = [IO.Path]::GetFullPath([string]$Selection.module_base)
    $loaded = @(Get-Module -Name Pester | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.ModuleBase) -and
        (Test-Task811SamePath -Left ([string]$_.ModuleBase) -Right $expectedBase)
    })
    if ($loaded.Count -eq 0) {
        Import-Module -Name ([string]$Selection.manifest_path) -Force -ErrorAction Stop
        $loaded = @(Get-Module -Name Pester | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.ModuleBase) -and
            (Test-Task811SamePath -Left ([string]$_.ModuleBase) -Right $expectedBase)
        })
    }
    Assert-Task811Condition ($loaded.Count -gt 0) 'pester_selected_package_not_loaded'
    foreach ($module in @(Get-Module -Name Pester)) {
        Assert-Task811Condition (Test-Task811SamePath -Left ([string]$module.ModuleBase) -Right $expectedBase) 'pester_loaded_package_mismatch'
    }
}

function Start-Task811PwshProcess {
    param(
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [switch]$RedirectOutput
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $PwshPath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    if ($RedirectOutput) {
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
    }
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    Assert-Task811Condition $process.Start() 'process_start_failed'
    if ($RedirectOutput) {
        return [pscustomobject]@{
            process     = $process
            stdout_task = $process.StandardOutput.ReadToEndAsync()
            stderr_task = $process.StandardError.ReadToEndAsync()
        }
    }
    return $process
}

function Wait-Task811ResultFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Diagnostics.Process]$Process
    )
    while (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $Process.Refresh()
        Assert-Task811Condition (-not $Process.HasExited) 'required_child_exited_before_result'
        [Threading.Thread]::Sleep(25)
    }
    $Process.Refresh()
    Assert-Task811Condition (-not $Process.HasExited) 'required_child_not_live_at_result'
    return Read-Task811JsonFile -Path $Path
}

function Wait-Task811SignalOrParentExit {
    param(
        [Parameter(Mandatory)][string]$SignalPath,
        [Parameter(Mandatory)][int]$ParentProcessId
    )
    while (-not (Test-Path -LiteralPath $SignalPath -PathType Leaf)) {
        $parent = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
        Assert-Task811Condition ($null -ne $parent) 'controller_parent_exited'
        [Threading.Thread]::Sleep(25)
    }
}

function Write-Task811Signal {
    param([Parameter(Mandatory)][string]$Path)
    Write-Task811AtomicBytes -Path $Path -Bytes ([Text.UTF8Encoding]::new($false).GetBytes("continue`n"))
}

function Stop-Task811OwnedProcess {
    param([AllowNull()][Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            $Process.Kill($true)
            $Process.WaitForExit()
        }
    } catch {
        # Best-effort cleanup of a process object created by this transaction only.
    }
}

function Remove-Task811ReceiptIfPresent {
    if (-not (Test-Path -LiteralPath $script:Task811ReceiptPath)) { return }
    $item = Get-Item -LiteralPath $script:Task811ReceiptPath -Force
    Assert-Task811Condition (-not $item.PSIsContainer) 'receipt_path_is_directory'
    Assert-Task811Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'receipt_path_reparse_point'
    Remove-Item -LiteralPath $script:Task811ReceiptPath -Force
}

function Remove-Task811OwnedWorkingRoot {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    Assert-Task811Condition ($fullPath.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) 'working_root_outside_temp'
    Assert-Task811Condition ([IO.Path]::GetFileName($fullPath).StartsWith('winsmux-task811-', [StringComparison]::Ordinal)) 'working_root_name_invalid'
    $item = Get-Item -LiteralPath $fullPath -Force
    Assert-Task811Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'working_root_reparse_point'
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function Invoke-Task811MeasurementChild {
    param([Parameter(Mandatory)][ValidateSet('discovery', 'worker')][string]$Kind)

    Assert-Task811Condition ($Task811ControllerPid -gt 0) 'child_controller_pid_invalid'
    Assert-Task811Condition ($Task811TransactionNonce -cmatch '^[0-9a-f]{32}$') 'child_transaction_nonce_invalid'
    Assert-Task811Condition ((Get-Task811ParentProcessId -ProcessId $PID) -eq $Task811ControllerPid) 'child_parent_mismatch'
    $selfProcessEvidence = Get-Task811ProcessEvidence -ProcessId $PID -ExpectedImagePath ([Environment]::ProcessPath)
    $measure = if ($Kind -ceq 'discovery') {
        Get-Task811ModuleBaseTreeEvidence -ModuleBase $Task811TargetPath
    } else {
        Get-Task811FileEvidence -Path $Task811TargetPath
    }
    Write-Task811JsonFile -Path $Task811MeasureResultPath -Value ([ordered]@{
        pid                    = $PID
        kind                   = $Kind
        transaction_nonce      = $Task811TransactionNonce
        self_process_evidence  = $selfProcessEvidence
        evidence               = $measure
    })

    Wait-Task811SignalOrParentExit -SignalPath $Task811VerifySignalPath -ParentProcessId $Task811ControllerPid
    $verified = if ($Kind -ceq 'discovery') {
        Get-Task811ModuleBaseTreeEvidence -ModuleBase $Task811TargetPath
    } else {
        Get-Task811FileEvidence -Path $Task811TargetPath
    }
    Write-Task811JsonFile -Path $Task811VerifyResultPath -Value ([ordered]@{
        pid               = $PID
        kind              = $Kind
        transaction_nonce = $Task811TransactionNonce
        evidence          = $verified
    })

    Wait-Task811SignalOrParentExit -SignalPath $Task811ReceiptSignalPath -ParentProcessId $Task811ControllerPid
    Assert-Task811Condition (Test-Task811SamePath -Left $Task811ReceiptPath -Right $script:Task811ReceiptPath) 'child_receipt_path_mismatch'
    $receiptBytes = [IO.File]::ReadAllBytes($Task811ReceiptPath)
    Write-Task811JsonFile -Path $Task811ReceiptAckPath -Value ([ordered]@{
        pid                 = $PID
        kind                = $Kind
        transaction_nonce   = $Task811TransactionNonce
        receipt_path        = $script:Task811ReceiptRelativePath
        receipt_file_sha256 = Get-Task811Sha256Bytes -Bytes $receiptBytes
        receipt_byte_length = [long]$receiptBytes.LongLength
    })
}

function Assert-Task811EvidenceEqual {
    param(
        [Parameter(Mandatory)]$Initial,
        [Parameter(Mandatory)]$Verified,
        [Parameter(Mandatory)][ValidateSet('discovery', 'worker')][string]$Kind
    )
    if ($Kind -ceq 'discovery') {
        Assert-Task811Condition ([string]$Initial.module_base -ceq [string]$Verified.module_base) 'pester_tree_module_base_changed'
        Assert-Task811Condition ([int]$Initial.file_count -eq [int]$Verified.file_count) 'pester_tree_file_count_changed'
        Assert-Task811Condition ([string]$Initial.sha256 -ceq [string]$Verified.sha256) 'pester_tree_hash_changed'
        return
    }
    Assert-Task811Condition ([string]$Initial.path -ceq [string]$Verified.path) 'pwsh_path_changed'
    Assert-Task811Condition ([long]$Initial.byte_length -eq [long]$Verified.byte_length) 'pwsh_byte_length_changed'
    Assert-Task811Condition ([string]$Initial.sha256 -ceq [string]$Verified.sha256) 'pwsh_hash_changed'
}

function Invoke-Task811Controller {
    Assert-Task811Condition $IsWindows 'controller_requires_windows'
    Assert-Task811Condition (Test-Task811SamePath -Left $Task811RepositoryRoot -Right $script:Task811RepoRoot) 'controller_repository_root_mismatch'
    Assert-Task811Condition (Test-Task811SamePath -Left $Task811ReceiptPath -Right $script:Task811ReceiptPath) 'controller_receipt_path_mismatch'
    Assert-Task811Condition ($Task811CiConsumerPid -gt 0) 'ci_consumer_pid_invalid'
    Assert-Task811Condition ($Task811TransactionNonce -cmatch '^[0-9a-f]{32}$') 'controller_transaction_nonce_invalid'
    $consumerSelfReport = Read-Task811JsonFile -Path $Task811CiConsumerEvidencePath
    Assert-Task811Condition ([string]$consumerSelfReport.transaction_nonce -ceq $Task811TransactionNonce) 'ci_consumer_nonce_mismatch'
    Assert-Task811Condition ([int]$consumerSelfReport.process.pid -eq $Task811CiConsumerPid) 'ci_consumer_self_pid_mismatch'
    Remove-Task811ReceiptIfPresent

    $pwshPath = Get-Task811PwshPath
    $pwshEvidence = Get-Task811FileEvidence -Path $pwshPath
    $selection = Get-Task811PesterSelection
    $moduleBase = [IO.Path]::GetFullPath([string]$selection.module_base)

    $discoveryMeasurePath = Join-Path $Task811WorkingRoot 'discovery.measure.json'
    $discoveryVerifySignalPath = Join-Path $Task811WorkingRoot 'discovery.verify.signal'
    $discoveryVerifyPath = Join-Path $Task811WorkingRoot 'discovery.verify.json'
    $discoveryReceiptSignalPath = Join-Path $Task811WorkingRoot 'discovery.receipt.signal'
    $discoveryAckPath = Join-Path $Task811WorkingRoot 'discovery.receipt.json'
    $workerMeasurePath = Join-Path $Task811WorkingRoot 'worker.measure.json'
    $workerVerifySignalPath = Join-Path $Task811WorkingRoot 'worker.verify.signal'
    $workerVerifyPath = Join-Path $Task811WorkingRoot 'worker.verify.json'
    $workerReceiptSignalPath = Join-Path $Task811WorkingRoot 'worker.receipt.signal'
    $workerAckPath = Join-Path $Task811WorkingRoot 'worker.receipt.json'
    $controllerResultPath = Join-Path $Task811WorkingRoot 'controller.result.json'

    $discoveryProcess = $null
    $workerProcess = $null
    $success = $false
    try {
        $commonArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Task811AuthorityPath)
        $discoveryProcess = Start-Task811PwshProcess -PwshPath $pwshPath -WorkingDirectory $script:Task811RepoRoot -Arguments @(
            $commonArguments + @(
                '-Task811InternalMode', 'discovery',
                '-Task811RepositoryRoot', $script:Task811RepoRoot,
                '-Task811ReceiptPath', $script:Task811ReceiptPath,
                '-Task811ControllerPid', [string]$PID,
                '-Task811TransactionNonce', $Task811TransactionNonce,
                '-Task811TargetPath', $moduleBase,
                '-Task811MeasureResultPath', $discoveryMeasurePath,
                '-Task811VerifySignalPath', $discoveryVerifySignalPath,
                '-Task811VerifyResultPath', $discoveryVerifyPath,
                '-Task811ReceiptSignalPath', $discoveryReceiptSignalPath,
                '-Task811ReceiptAckPath', $discoveryAckPath
            )
        )
        $workerProcess = Start-Task811PwshProcess -PwshPath $pwshPath -WorkingDirectory $script:Task811RepoRoot -Arguments @(
            $commonArguments + @(
                '-Task811InternalMode', 'worker',
                '-Task811RepositoryRoot', $script:Task811RepoRoot,
                '-Task811ReceiptPath', $script:Task811ReceiptPath,
                '-Task811ControllerPid', [string]$PID,
                '-Task811TransactionNonce', $Task811TransactionNonce,
                '-Task811TargetPath', $pwshPath,
                '-Task811MeasureResultPath', $workerMeasurePath,
                '-Task811VerifySignalPath', $workerVerifySignalPath,
                '-Task811VerifyResultPath', $workerVerifyPath,
                '-Task811ReceiptSignalPath', $workerReceiptSignalPath,
                '-Task811ReceiptAckPath', $workerAckPath
            )
        )

        $discoveryMeasure = Wait-Task811ResultFile -Path $discoveryMeasurePath -Process $discoveryProcess
        $workerMeasure = Wait-Task811ResultFile -Path $workerMeasurePath -Process $workerProcess
        Assert-Task811Condition ([int]$discoveryMeasure.pid -eq $discoveryProcess.Id) 'discovery_measure_pid_mismatch'
        Assert-Task811Condition ([int]$workerMeasure.pid -eq $workerProcess.Id) 'worker_measure_pid_mismatch'
        Assert-Task811Condition ([string]$discoveryMeasure.transaction_nonce -ceq $Task811TransactionNonce) 'discovery_measure_nonce_mismatch'
        Assert-Task811Condition ([string]$workerMeasure.transaction_nonce -ceq $Task811TransactionNonce) 'worker_measure_nonce_mismatch'

        $controllerNode = Get-Task811ProcessEvidence -ProcessId $PID -ExpectedImagePath $pwshPath
        $discoveryControllerObservation = Get-Task811ProcessEvidence -ProcessId $discoveryProcess.Id -ExpectedImagePath $pwshPath
        $workerControllerObservation = Get-Task811ProcessEvidence -ProcessId $workerProcess.Id -ExpectedImagePath $pwshPath
        $consumerControllerObservation = Get-Task811ProcessEvidence -ProcessId $Task811CiConsumerPid -ExpectedImagePath $Task811CiConsumerImagePath
        Assert-Task811ProcessEvidenceEqual -SelfObserved $discoveryMeasure.self_process_evidence -ControllerObserved $discoveryControllerObservation -Role discovery
        Assert-Task811ProcessEvidenceEqual -SelfObserved $workerMeasure.self_process_evidence -ControllerObserved $workerControllerObservation -Role worker
        Assert-Task811ProcessEvidenceEqual -SelfObserved $consumerSelfReport.process -ControllerObserved $consumerControllerObservation -Role ci_consumer
        $discoveryNode = $discoveryMeasure.self_process_evidence
        $workerNode = $workerMeasure.self_process_evidence
        $consumerNode = $consumerSelfReport.process
        Assert-Task811Condition ($controllerNode.parent_pid -eq $Task811CiConsumerPid) 'controller_parent_mismatch'
        Assert-Task811Condition ($discoveryNode.parent_pid -eq $PID) 'discovery_parent_mismatch'
        Assert-Task811Condition ($workerNode.parent_pid -eq $PID) 'worker_parent_mismatch'
        $nodePids = @($controllerNode.pid, $discoveryNode.pid, $workerNode.pid, $consumerNode.pid)
        Assert-Task811Condition ((@($nodePids | Sort-Object -Unique)).Count -eq 4) 'process_graph_pid_not_unique'

        $selectionAfterGraph = Get-Task811PesterSelection
        Assert-Task811Condition (Test-Task811SamePath -Left ([string]$selectionAfterGraph.module_base) -Right $moduleBase) 'pester_resolution_changed'
        Import-Task811SelectedPester -Selection $selectionAfterGraph
        Write-Task811Signal -Path $discoveryVerifySignalPath
        Write-Task811Signal -Path $workerVerifySignalPath
        $discoveryVerify = Wait-Task811ResultFile -Path $discoveryVerifyPath -Process $discoveryProcess
        $workerVerify = Wait-Task811ResultFile -Path $workerVerifyPath -Process $workerProcess
        Assert-Task811EvidenceEqual -Initial $discoveryMeasure.evidence -Verified $discoveryVerify.evidence -Kind discovery
        Assert-Task811EvidenceEqual -Initial $workerMeasure.evidence -Verified $workerVerify.evidence -Kind worker

        if ($Task811TerminateWorkerBeforeReceiptWrite) {
            $workerProcess.Kill($true)
            $workerProcess.WaitForExit()
        }
        if ($Task811CrashBeforeReceiptWrite) {
            [Environment]::Exit(87)
        }

        foreach ($requiredPid in $nodePids) {
            Assert-Task811Condition ($null -ne (Get-Process -Id $requiredPid -ErrorAction SilentlyContinue)) 'required_process_dead_before_receipt'
        }

        $treeId = Get-Task811GitTreeId -RepositoryRoot $script:Task811RepoRoot
        Assert-Task811Condition (Test-Path -LiteralPath (Join-Path $script:Task811RepoRoot 'scripts/test-public-release.ps1') -PathType Leaf) 'release_verifier_missing'
        $receipt = [pscustomobject][ordered]@{
            schema             = $script:Task811ReceiptSchema
            authority          = 'TASK-811'
            status             = 'ok'
            fail_closed_reason = ''
            tree_id            = $treeId
            pwsh               = [pscustomobject][ordered]@{
                path        = [string]$workerVerify.evidence.path
                sha256      = [string]$workerVerify.evidence.sha256
                byte_length = [long]$workerVerify.evidence.byte_length
            }
            pester_package     = [pscustomobject][ordered]@{
                representation = 'module_base_tree'
                module_base    = [string]$discoveryVerify.evidence.module_base
                file_count     = [int]$discoveryVerify.evidence.file_count
                sha256         = [string]$discoveryVerify.evidence.sha256
                resolver_status = 'resolved'
            }
            process_graph      = [pscustomobject][ordered]@{
                controller  = $controllerNode
                discovery   = $discoveryNode
                worker      = $workerNode
                ci_consumer = $consumerNode
            }
            transaction        = [pscustomobject][ordered]@{
                nonce           = $Task811TransactionNonce
                order           = [string[]]$script:Task811TransactionOrder
                completed       = [string[]]$script:Task811CompletedOrder
                deferred_hooks  = [string[]]@('upload', 'merge')
            }
            artifact_bind      = [pscustomobject][ordered]@{
                receipt_path        = $script:Task811ReceiptRelativePath
                receipt_sha256      = ''
                receipt_hash_scope  = 'canonical_json_with_empty_artifact_bind.receipt_sha256'
                tree_id             = $treeId
            }
            release            = [pscustomobject][ordered]@{
                owner            = 'TASK-811'
                target           = 'v0.36.31'
                do_not_overwrite = 'v0.36.30.1'
                verifier         = 'scripts/test-public-release.ps1'
                surfaces         = [string[]]@('Core', 'Desktop', 'Npm')
                tag_created      = $false
            }
        }
        $receipt.artifact_bind.receipt_sha256 = Get-Task811Sha256Bytes -Bytes (ConvertTo-Task811CanonicalJsonBytes -Value $receipt)
        $receiptBytes = ConvertTo-Task811CanonicalJsonBytes -Value $receipt
        Write-Task811AtomicBytes -Path $script:Task811ReceiptPath -Bytes $receiptBytes

        $controllerReceiptBytes = [IO.File]::ReadAllBytes($script:Task811ReceiptPath)
        $controllerReceiptHash = Get-Task811Sha256Bytes -Bytes $controllerReceiptBytes
        Write-Task811Signal -Path $discoveryReceiptSignalPath
        Write-Task811Signal -Path $workerReceiptSignalPath
        $discoveryAck = Wait-Task811ResultFile -Path $discoveryAckPath -Process $discoveryProcess
        $workerAck = Wait-Task811ResultFile -Path $workerAckPath -Process $workerProcess
        foreach ($ack in @($discoveryAck, $workerAck)) {
            Assert-Task811Condition ([string]$ack.transaction_nonce -ceq $Task811TransactionNonce) 'receipt_reader_nonce_mismatch'
            Assert-Task811Condition ([string]$ack.receipt_path -ceq $script:Task811ReceiptRelativePath) 'receipt_reader_path_mismatch'
            Assert-Task811Condition ([string]$ack.receipt_file_sha256 -ceq $controllerReceiptHash) 'receipt_reader_hash_mismatch'
            Assert-Task811Condition ([long]$ack.receipt_byte_length -eq [long]$controllerReceiptBytes.LongLength) 'receipt_reader_length_mismatch'
        }

        $discoveryProcess.WaitForExit()
        $workerProcess.WaitForExit()
        Assert-Task811Condition ($discoveryProcess.ExitCode -eq 0) 'discovery_reader_failed'
        Assert-Task811Condition ($workerProcess.ExitCode -eq 0) 'worker_reader_failed'
        Write-Task811JsonFile -Path $controllerResultPath -Value ([ordered]@{
            status               = 'ok'
            transaction_nonce    = $Task811TransactionNonce
            tree_id              = $treeId
            receipt_path         = $script:Task811ReceiptRelativePath
            receipt_file_sha256  = $controllerReceiptHash
            receipt_byte_length  = [long]$controllerReceiptBytes.LongLength
            reader_hashes        = [ordered]@{
                controller = $controllerReceiptHash
                discovery  = [string]$discoveryAck.receipt_file_sha256
                worker     = [string]$workerAck.receipt_file_sha256
            }
        })
        $success = $true
    } finally {
        Stop-Task811OwnedProcess -Process $discoveryProcess
        Stop-Task811OwnedProcess -Process $workerProcess
        if (-not $success) {
            Remove-Task811ReceiptIfPresent
        }
    }
}

function Get-Task811RequiredProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Reason
    )
    $property = $Object.PSObject.Properties[$Name]
    Assert-Task811Condition ($null -ne $property) $Reason
    return $property.Value
}

function Assert-Task811NoBannedEvidenceFields {
    param([Parameter(Mandatory)]$Value)
    if ($null -eq $Value) { return }
    if ($Value -is [string] -or $Value -is [ValueType]) { return }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [Management.Automation.PSCustomObject]) {
        foreach ($entry in $Value) { Assert-Task811NoBannedEvidenceFields -Value $entry }
        return
    }
    $banned = @('semantic_version', 'file_version', 'version_text', 'workerid', 'worker_id', 'token', 'mock', 'proxy_path')
    foreach ($property in $Value.PSObject.Properties) {
        Assert-Task811Condition ([string]$property.Name -cnotin $banned) 'banned_evidence_field'
        Assert-Task811NoBannedEvidenceFields -Value $property.Value
    }
}

function Assert-WinsmuxTask811Receipt {
    [CmdletBinding()]
    param([switch]$ArtifactBindingOnly)

    try {
        Assert-Task811Condition (Test-Path -LiteralPath $script:Task811ReceiptPath -PathType Leaf) 'receipt_missing'
        $receiptItem = Get-Item -LiteralPath $script:Task811ReceiptPath -Force
        Assert-Task811Condition (($receiptItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'receipt_reparse_point'
        $receiptBytes = [IO.File]::ReadAllBytes($script:Task811ReceiptPath)
        try {
            $receiptText = [Text.UTF8Encoding]::new($false, $true).GetString($receiptBytes)
            $receipt = $receiptText | ConvertFrom-Json -Depth 32 -ErrorAction Stop
        } catch {
            Throw-Task811FailClosed -Reason 'receipt_malformed'
        }

        Assert-Task811Condition ([Convert]::ToBase64String((ConvertTo-Task811CanonicalJsonBytes -Value $receipt)) -ceq [Convert]::ToBase64String($receiptBytes)) 'receipt_not_canonical_json'
        Assert-Task811NoBannedEvidenceFields -Value $receipt
        Assert-Task811Condition ([string](Get-Task811RequiredProperty -Object $receipt -Name schema -Reason 'receipt_schema_missing') -ceq $script:Task811ReceiptSchema) 'receipt_schema_invalid'
        Assert-Task811Condition ([string](Get-Task811RequiredProperty -Object $receipt -Name authority -Reason 'receipt_authority_missing') -ceq 'TASK-811') 'receipt_authority_invalid'
        $status = [string](Get-Task811RequiredProperty -Object $receipt -Name status -Reason 'receipt_status_missing')
        Assert-Task811Condition ($status -cin @('ok', 'fail_closed')) 'receipt_status_invalid'
        if ($status -ceq 'fail_closed') {
            Throw-Task811FailClosed -Reason 'receipt_status_fail_closed'
        }
        Assert-Task811Condition ([string](Get-Task811RequiredProperty -Object $receipt -Name fail_closed_reason -Reason 'fail_closed_reason_missing') -ceq '') 'ok_receipt_has_fail_closed_reason'

        $treeId = [string](Get-Task811RequiredProperty -Object $receipt -Name tree_id -Reason 'tree_id_missing')
        Assert-Task811Condition ($treeId -cmatch '^[0-9a-f]{40}$') 'tree_id_invalid'
        Assert-Task811Condition ((Get-Task811GitTreeId -RepositoryRoot $script:Task811RepoRoot) -ceq $treeId) 'tree_id_mismatch'

        $pwsh = Get-Task811RequiredProperty -Object $receipt -Name pwsh -Reason 'pwsh_evidence_missing'
        $pwshPath = [string](Get-Task811RequiredProperty -Object $pwsh -Name path -Reason 'pwsh_path_missing')
        $pwshHash = [string](Get-Task811RequiredProperty -Object $pwsh -Name sha256 -Reason 'pwsh_hash_missing')
        $pwshLength = [long](Get-Task811RequiredProperty -Object $pwsh -Name byte_length -Reason 'pwsh_byte_length_missing')
        Assert-Task811Condition (-not [string]::IsNullOrWhiteSpace($pwshPath)) 'pwsh_path_invalid'
        Assert-Task811Condition ($pwshHash -cmatch '^[0-9a-f]{64}$') 'pwsh_hash_invalid'
        Assert-Task811Condition ($pwshLength -gt 0) 'pwsh_byte_length_invalid'

        $pester = Get-Task811RequiredProperty -Object $receipt -Name pester_package -Reason 'pester_evidence_missing'
        Assert-Task811Condition ([string](Get-Task811RequiredProperty -Object $pester -Name representation -Reason 'pester_representation_missing') -ceq 'module_base_tree') 'pester_representation_invalid'
        $moduleBase = [string](Get-Task811RequiredProperty -Object $pester -Name module_base -Reason 'pester_module_base_missing')
        $pesterFileCount = [int](Get-Task811RequiredProperty -Object $pester -Name file_count -Reason 'pester_file_count_missing')
        $pesterHash = [string](Get-Task811RequiredProperty -Object $pester -Name sha256 -Reason 'pester_hash_missing')
        Assert-Task811Condition (-not [string]::IsNullOrWhiteSpace($moduleBase)) 'pester_module_base_invalid'
        Assert-Task811Condition ($pesterFileCount -gt 1) 'pester_file_count_invalid'
        Assert-Task811Condition ($pesterHash -cmatch '^[0-9a-f]{64}$') 'pester_hash_invalid'
        Assert-Task811Condition ([string](Get-Task811RequiredProperty -Object $pester -Name resolver_status -Reason 'pester_resolver_status_missing') -ceq 'resolved') 'pester_resolver_status_invalid'

        $graph = Get-Task811RequiredProperty -Object $receipt -Name process_graph -Reason 'process_graph_missing'
        $nodes = [ordered]@{}
        foreach ($role in @('controller', 'discovery', 'worker', 'ci_consumer')) {
            $node = Get-Task811RequiredProperty -Object $graph -Name $role -Reason "process_graph_${role}_missing"
            $pidValue = [int](Get-Task811RequiredProperty -Object $node -Name pid -Reason "process_graph_${role}_pid_missing")
            $imagePath = [string](Get-Task811RequiredProperty -Object $node -Name image_path -Reason "process_graph_${role}_image_path_missing")
            $imageHash = [string](Get-Task811RequiredProperty -Object $node -Name image_sha256 -Reason "process_graph_${role}_image_hash_missing")
            $parentPid = [int](Get-Task811RequiredProperty -Object $node -Name parent_pid -Reason "process_graph_${role}_parent_pid_missing")
            $startTimeUtcTicks = [long](Get-Task811RequiredProperty -Object $node -Name start_time_utc_ticks -Reason "process_graph_${role}_start_time_missing")
            Assert-Task811Condition ($pidValue -gt 0 -and $parentPid -gt 0) 'process_graph_pid_invalid'
            Assert-Task811Condition (-not [string]::IsNullOrWhiteSpace($imagePath)) 'process_graph_image_path_invalid'
            Assert-Task811Condition ($imageHash -ceq $pwshHash) 'process_graph_image_hash_mismatch'
            Assert-Task811Condition (Test-Task811SamePath -Left $imagePath -Right $pwshPath) 'process_graph_image_path_mismatch'
            Assert-Task811Condition ($startTimeUtcTicks -gt 0) 'process_graph_start_time_invalid'
            $nodes[$role] = [pscustomobject]@{ pid = $pidValue; parent_pid = $parentPid }
        }
        Assert-Task811Condition ((@($nodes.Values.pid | Sort-Object -Unique)).Count -eq 4) 'process_graph_pid_not_unique'
        Assert-Task811Condition ($nodes.controller.parent_pid -eq $nodes.ci_consumer.pid) 'process_graph_controller_parent_invalid'
        Assert-Task811Condition ($nodes.discovery.parent_pid -eq $nodes.controller.pid) 'process_graph_discovery_parent_invalid'
        Assert-Task811Condition ($nodes.worker.parent_pid -eq $nodes.controller.pid) 'process_graph_worker_parent_invalid'

        $transaction = Get-Task811RequiredProperty -Object $receipt -Name transaction -Reason 'transaction_missing'
        $transactionNonce = [string](Get-Task811RequiredProperty -Object $transaction -Name nonce -Reason 'transaction_nonce_missing')
        Assert-Task811Condition ($transactionNonce -cmatch '^[0-9a-f]{32}$') 'transaction_nonce_invalid'
        $order = @((Get-Task811RequiredProperty -Object $transaction -Name order -Reason 'transaction_order_missing') | ForEach-Object { [string]$_ })
        $completed = @((Get-Task811RequiredProperty -Object $transaction -Name completed -Reason 'transaction_completed_missing') | ForEach-Object { [string]$_ })
        $deferredHooks = @((Get-Task811RequiredProperty -Object $transaction -Name deferred_hooks -Reason 'transaction_deferred_hooks_missing') | ForEach-Object { [string]$_ })
        Assert-Task811Condition ([string]::Join('|', $order) -ceq [string]::Join('|', $script:Task811TransactionOrder)) 'transaction_order_invalid'
        Assert-Task811Condition ([string]::Join('|', $completed) -ceq [string]::Join('|', $script:Task811CompletedOrder)) 'transaction_completed_invalid'
        Assert-Task811Condition ([string]::Join('|', $deferredHooks) -ceq 'upload|merge') 'transaction_deferred_hooks_invalid'

        $artifactBind = Get-Task811RequiredProperty -Object $receipt -Name artifact_bind -Reason 'artifact_bind_missing'
        Assert-Task811Condition ([string](Get-Task811RequiredProperty -Object $artifactBind -Name receipt_path -Reason 'artifact_receipt_path_missing') -ceq $script:Task811ReceiptRelativePath) 'artifact_receipt_path_invalid'
        Assert-Task811Condition ([string](Get-Task811RequiredProperty -Object $artifactBind -Name tree_id -Reason 'artifact_tree_id_missing') -ceq $treeId) 'artifact_tree_id_mismatch'
        Assert-Task811Condition ([string](Get-Task811RequiredProperty -Object $artifactBind -Name receipt_hash_scope -Reason 'artifact_hash_scope_missing') -ceq 'canonical_json_with_empty_artifact_bind.receipt_sha256') 'artifact_hash_scope_invalid'
        $bindingHash = [string](Get-Task811RequiredProperty -Object $artifactBind -Name receipt_sha256 -Reason 'artifact_receipt_hash_missing')
        Assert-Task811Condition ($bindingHash -cmatch '^[0-9a-f]{64}$') 'artifact_receipt_hash_invalid'
        $artifactBind.receipt_sha256 = ''
        $expectedBindingHash = Get-Task811Sha256Bytes -Bytes (ConvertTo-Task811CanonicalJsonBytes -Value $receipt)
        $artifactBind.receipt_sha256 = $bindingHash
        Assert-Task811Condition ($bindingHash -ceq $expectedBindingHash) 'artifact_receipt_hash_mismatch'

        $release = Get-Task811RequiredProperty -Object $receipt -Name release -Reason 'release_binding_missing'
        Assert-Task811Condition ([string](Get-Task811RequiredProperty -Object $release -Name owner -Reason 'release_owner_missing') -ceq 'TASK-811') 'release_owner_invalid'
        Assert-Task811Condition ([string](Get-Task811RequiredProperty -Object $release -Name target -Reason 'release_target_missing') -ceq 'v0.36.31') 'release_target_invalid'
        Assert-Task811Condition ([string](Get-Task811RequiredProperty -Object $release -Name do_not_overwrite -Reason 'release_preserved_tag_missing') -ceq 'v0.36.30.1') 'release_preserved_tag_invalid'
        Assert-Task811Condition ([string](Get-Task811RequiredProperty -Object $release -Name verifier -Reason 'release_verifier_missing') -ceq 'scripts/test-public-release.ps1') 'release_verifier_invalid'
        $surfaces = @((Get-Task811RequiredProperty -Object $release -Name surfaces -Reason 'release_surfaces_missing') | ForEach-Object { [string]$_ })
        Assert-Task811Condition ([string]::Join('|', $surfaces) -ceq 'Core|Desktop|Npm') 'release_surfaces_invalid'
        Assert-Task811Condition ([bool](Get-Task811RequiredProperty -Object $release -Name tag_created -Reason 'release_tag_created_missing') -eq $false) 'release_tag_created'
        Assert-Task811Condition (Test-Path -LiteralPath (Join-Path $script:Task811RepoRoot 'scripts/test-public-release.ps1') -PathType Leaf) 'release_verifier_missing'

        if (-not $ArtifactBindingOnly) {
            $currentPwsh = Get-Task811FileEvidence -Path (Get-Task811PwshPath)
            Assert-Task811Condition (Test-Task811SamePath -Left $currentPwsh.path -Right $pwshPath) 'local_pwsh_path_mismatch'
            Assert-Task811Condition ([string]$currentPwsh.sha256 -ceq $pwshHash) 'local_pwsh_hash_mismatch'
            Assert-Task811Condition ([long]$currentPwsh.byte_length -eq $pwshLength) 'local_pwsh_byte_length_mismatch'
            $selection = Get-Task811PesterSelection
            Assert-Task811Condition (Test-Task811SamePath -Left ([string]$selection.module_base) -Right $moduleBase) 'local_pester_module_base_mismatch'
            Import-Task811SelectedPester -Selection $selection
            $currentPester = Get-Task811ModuleBaseTreeEvidence -ModuleBase ([string]$selection.module_base)
            Assert-Task811Condition ([int]$currentPester.file_count -eq $pesterFileCount) 'local_pester_file_count_mismatch'
            Assert-Task811Condition ([string]$currentPester.sha256 -ceq $pesterHash) 'local_pester_hash_mismatch'
        }

        return [pscustomobject][ordered]@{
            status              = 'ok'
            tree_id             = $treeId
            receipt_path        = $script:Task811ReceiptRelativePath
            receipt_file_sha256 = Get-Task811Sha256Bytes -Bytes $receiptBytes
            receipt_byte_length = [long]$receiptBytes.LongLength
        }
    } catch {
        if ($_.Exception.Message.StartsWith('TASK811_FAIL_CLOSED ', [StringComparison]::Ordinal)) {
            throw
        }
        Throw-Task811FailClosed -Reason 'receipt_validation_error'
    }
}

function Stop-Task811RecordedChildren {
    param(
        [Parameter(Mandatory)][string]$WorkingRoot,
        [Parameter(Mandatory)][int]$ControllerProcessId,
        [Parameter(Mandatory)][string]$ExpectedPwshPath
    )
    foreach ($name in @('discovery.measure.json', 'worker.measure.json')) {
        $resultPath = Join-Path $WorkingRoot $name
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { continue }
        try {
            $result = Read-Task811JsonFile -Path $resultPath
            $childPid = [int]$result.pid
            $child = Get-Process -Id $childPid -ErrorAction SilentlyContinue
            if ($null -eq $child) { continue }
            $childPath = [string]$child.Path
            if ((Get-Task811ParentProcessId -ProcessId $childPid) -ne $ControllerProcessId) { continue }
            if (-not (Test-Task811SamePath -Left $childPath -Right $ExpectedPwshPath)) { continue }
            $child.Kill($true)
            $child.WaitForExit()
        } catch {
            # Never broaden cleanup beyond a live, path-checked child owned by this controller.
        }
    }
}

function Invoke-WinsmuxTask811Transaction {
    [CmdletBinding()]
    param(
        [switch]$TestCrashBeforeReceiptWrite,
        [switch]$TestTerminateWorkerBeforeReceiptWrite
    )

    Assert-Task811Condition $IsWindows 'transaction_requires_windows'
    Remove-Task811ReceiptIfPresent
    $pwshPath = Get-Task811PwshPath
    $consumerEvidence = Get-Task811ProcessEvidence -ProcessId $PID -ExpectedImagePath $pwshPath
    $transactionNonce = [guid]::NewGuid().ToString('N')
    $workingRoot = Join-Path ([IO.Path]::GetTempPath()) ('winsmux-task811-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workingRoot | Out-Null
    $consumerEvidencePath = Join-Path $workingRoot 'ci-consumer.evidence.json'
    Write-Task811JsonFile -Path $consumerEvidencePath -Value ([ordered]@{
        transaction_nonce = $transactionNonce
        process           = $consumerEvidence
    })
    $controllerHandle = $null
    $transactionSucceeded = $false
    try {
        $arguments = [Collections.Generic.List[string]]::new()
        foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Task811AuthorityPath,
            '-Task811InternalMode', 'controller',
            '-Task811RepositoryRoot', $script:Task811RepoRoot,
            '-Task811ReceiptPath', $script:Task811ReceiptPath,
            '-Task811WorkingRoot', $workingRoot,
            '-Task811CiConsumerPid', [string]$PID,
            '-Task811CiConsumerImagePath', [string]$consumerEvidence.image_path,
            '-Task811CiConsumerEvidencePath', $consumerEvidencePath,
            '-Task811TransactionNonce', $transactionNonce
        )) {
            $arguments.Add([string]$argument)
        }
        if ($TestCrashBeforeReceiptWrite) { $arguments.Add('-Task811CrashBeforeReceiptWrite') }
        if ($TestTerminateWorkerBeforeReceiptWrite) { $arguments.Add('-Task811TerminateWorkerBeforeReceiptWrite') }
        $controllerHandle = Start-Task811PwshProcess -PwshPath $pwshPath -Arguments $arguments.ToArray() -WorkingDirectory $script:Task811RepoRoot -RedirectOutput
        $controllerHandle.process.WaitForExit()
        $controllerStdout = $controllerHandle.stdout_task.GetAwaiter().GetResult()
        $controllerStderr = $controllerHandle.stderr_task.GetAwaiter().GetResult()
        if ($controllerHandle.process.ExitCode -ne 0) {
            $diagnosticMatch = [regex]::Match($controllerStderr.Trim(), '^TASK811_FAIL_CLOSED (?<reason>[a-z0-9_]+)$')
            if ($diagnosticMatch.Success) {
                Throw-Task811FailClosed -Reason ("controller_{0}" -f $diagnosticMatch.Groups['reason'].Value)
            }
            Throw-Task811FailClosed -Reason ("controller_exit_{0}" -f $controllerHandle.process.ExitCode)
        }
        Assert-Task811Condition ([string]::IsNullOrWhiteSpace($controllerStdout)) 'controller_stdout_not_empty'
        Assert-Task811Condition ([string]::IsNullOrWhiteSpace($controllerStderr)) 'controller_stderr_not_empty'
        $controllerResultPath = Join-Path $workingRoot 'controller.result.json'
        $controllerResult = Read-Task811JsonFile -Path $controllerResultPath
        Assert-Task811Condition ([string]$controllerResult.status -ceq 'ok') 'controller_result_not_ok'
        Assert-Task811Condition ([string]$controllerResult.transaction_nonce -ceq $transactionNonce) 'controller_result_nonce_mismatch'
        $receiptBytes = [IO.File]::ReadAllBytes($script:Task811ReceiptPath)
        $consumerHash = Get-Task811Sha256Bytes -Bytes $receiptBytes
        Assert-Task811Condition ([string]$controllerResult.receipt_file_sha256 -ceq $consumerHash) 'ci_consumer_receipt_hash_mismatch'
        Assert-Task811Condition ([long]$controllerResult.receipt_byte_length -eq [long]$receiptBytes.LongLength) 'ci_consumer_receipt_length_mismatch'
        $assertion = Assert-WinsmuxTask811Receipt
        Assert-Task811Condition ([string]$assertion.receipt_file_sha256 -ceq $consumerHash) 'ci_consumer_assertion_hash_mismatch'
        $readerHashes = [ordered]@{
            controller  = [string]$controllerResult.reader_hashes.controller
            discovery   = [string]$controllerResult.reader_hashes.discovery
            worker      = [string]$controllerResult.reader_hashes.worker
            ci_consumer = $consumerHash
        }
        Assert-Task811Condition ((@($readerHashes.Values | Sort-Object -Unique)).Count -eq 1) 'receipt_reader_hashes_not_identical'
        $transactionSucceeded = $true
        return [pscustomobject][ordered]@{
            status              = 'ok'
            tree_id             = [string]$controllerResult.tree_id
            receipt_path        = $script:Task811ReceiptRelativePath
            receipt_file_sha256 = $consumerHash
            receipt_byte_length = [long]$receiptBytes.LongLength
            reader_hashes       = [pscustomobject]$readerHashes
        }
    } finally {
        if ($null -ne $controllerHandle) {
            Stop-Task811OwnedProcess -Process $controllerHandle.process
            Stop-Task811RecordedChildren -WorkingRoot $workingRoot -ControllerProcessId $controllerHandle.process.Id -ExpectedPwshPath $pwshPath
        }
        if (-not $transactionSucceeded) {
            Remove-Task811ReceiptIfPresent
        }
        Remove-Task811OwnedWorkingRoot -Path $workingRoot
    }
}

if ($Task811InternalMode -cne 'library') {
    try {
        switch ($Task811InternalMode) {
            'controller' { Invoke-Task811Controller }
            'discovery' { Invoke-Task811MeasurementChild -Kind discovery }
            'worker' { Invoke-Task811MeasurementChild -Kind worker }
        }
        exit 0
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}
