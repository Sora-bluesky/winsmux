#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $ShardId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Task810AbsentModule {
    return [pscustomobject][ordered]@{
        present          = $false
        name             = [string]''
        semantic_version = [string]''
        manifest_path    = [string]''
    }
}

function New-Task810PresentModule {
    param([Parameter(Mandatory)][string]$ManifestPath)
    return [pscustomobject][ordered]@{
        present          = $true
        name             = [string]'Pester'
        semantic_version = [string]'5.7.1'
        manifest_path    = [string]$ManifestPath
    }
}

function Emit-Task810Envelope {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ShardIdValue,
        [Parameter(Mandatory)][string]$ResolutionStatus,
        [Parameter(Mandatory)][string]$ExecutionStatus,
        [Parameter(Mandatory)][string]$TestOutcome,
        [Parameter(Mandatory)][string]$FailureOrigin,
        [Parameter(Mandatory)][string]$WorkflowAction,
        [Parameter(Mandatory)][bool]$PesterInvoked,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ResultFile,
        [Parameter(Mandatory)][string]$ErrorCode,
        [Parameter(Mandatory)]$SelectedModule
    )
    $envelope = [pscustomobject][ordered]@{
        schema_version    = [string]'1'
        shard_id          = [string]$ShardIdValue
        resolution_status = [string]$ResolutionStatus
        execution_status  = [string]$ExecutionStatus
        test_outcome      = [string]$TestOutcome
        failure_origin    = [string]$FailureOrigin
        workflow_action   = [string]$WorkflowAction
        pester_invoked    = [bool]$PesterInvoked
        result_file       = [string]$ResultFile
        error_code        = [string]$ErrorCode
        selected_module   = $SelectedModule
    }
    $json = $envelope | ConvertTo-Json -Compress -Depth 5
    Write-Output -InputObject ([string]$json)
}

function Get-Task810FailureOrigin {
    param([Parameter(Mandatory)]$PesterResult)
    $failedTests = @()
    if ($null -ne $PesterResult.PSObject.Properties['Failed'] -and $null -ne $PesterResult.Failed) {
        $failedTests = @($PesterResult.Failed)
    }
    $failedBlocksCount = 0
    $failedContainersCount = 0
    if ($null -ne $PesterResult.PSObject.Properties['FailedBlocksCount']) { $failedBlocksCount = [int]$PesterResult.FailedBlocksCount }
    elseif ($null -ne $PesterResult.PSObject.Properties['FailedBlocks'] -and $null -ne $PesterResult.FailedBlocks) { $failedBlocksCount = @($PesterResult.FailedBlocks).Count }
    if ($null -ne $PesterResult.PSObject.Properties['FailedContainersCount']) { $failedContainersCount = [int]$PesterResult.FailedContainersCount }
    elseif ($null -ne $PesterResult.PSObject.Properties['FailedContainers'] -and $null -ne $PesterResult.FailedContainers) { $failedContainersCount = @($PesterResult.FailedContainers).Count }

    $A = $false
    $T = $false
    $B = ($failedBlocksCount -gt 0) -or ($failedContainersCount -gt 0)
    foreach ($test in $failedTests) {
        $shouldRun = $false
        $executed = $false
        if ($null -ne $test.PSObject.Properties['ShouldRun']) { $shouldRun = [bool]$test.ShouldRun }
        if ($null -ne $test.PSObject.Properties['Executed']) { $executed = [bool]$test.Executed }
        if ($shouldRun -and -not $executed) { $B = $true }
        $errors = @()
        if ($null -ne $test.PSObject.Properties['ErrorRecord'] -and $null -ne $test.ErrorRecord) { $errors = @($test.ErrorRecord) }
        foreach ($err in $errors) {
            $fqid = [string]$err.FullyQualifiedErrorId
            if ([System.StringComparer]::Ordinal.Equals($fqid, 'PesterAssertionFailed')) { $A = $true }
            elseif (-not (
                [System.StringComparer]::Ordinal.Equals($fqid, 'PesterTestSkipped') -or
                [System.StringComparer]::Ordinal.Equals($fqid, 'PesterTestInconclusive') -or
                [System.StringComparer]::Ordinal.Equals($fqid, 'PesterTestPending')
            )) { $T = $true }
        }
    }

    if (-not $A -and -not $T -and -not $B) { return [string]'none' }
    if ($A -and -not $T -and -not $B) { return [string]'assertion' }
    if (-not $A -and $T -and -not $B) { return [string]'test_runtime' }
    if (-not $A -and -not $T -and $B) { return [string]'block_or_container' }
    return [string]'mixed'
}

$modulePath = Join-Path $PSScriptRoot 'winsmux-pester.psm1'
$resolvedModulePath = [System.IO.Path]::GetFullPath($modulePath)
$loadedModule = Get-Module -Name 'winsmux-pester' -ErrorAction SilentlyContinue | Select-Object -First 1
$needsImport = $true
if ($null -ne $loadedModule) {
    $loadedPath = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$loadedModule.Path) -and ([string]$loadedModule.Path).EndsWith('.psm1', [System.StringComparison]::OrdinalIgnoreCase)) {
        $loadedPath = [System.IO.Path]::GetFullPath([string]$loadedModule.Path)
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$loadedModule.ModuleBase)) {
        $loadedPath = [System.IO.Path]::GetFullPath((Join-Path ([string]$loadedModule.ModuleBase) 'winsmux-pester.psm1'))
    }
    if ($null -ne $loadedPath -and [System.StringComparer]::OrdinalIgnoreCase.Equals($loadedPath, $resolvedModulePath)) {
        $needsImport = $false
    }
}
if ($needsImport) {
    Import-Module -Name $modulePath -Force -ErrorAction Stop
}

$callerShardId = [string]$ShardId
$m0 = New-Task810AbsentModule

# P01: empty shard id
if ($callerShardId.Length -eq 0) {
    Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'empty' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$false -ResultFile '' -ErrorCode 'shard_id_empty' -SelectedModule $m0
    return
}

$match = Find-WinsmuxPesterShardMatch -ShardId $callerShardId
if ([int]$match.match_count -eq 0) {
    Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'unknown' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$false -ResultFile '' -ErrorCode 'shard_id_unknown' -SelectedModule $m0
    return
}
if ([int]$match.match_count -gt 1) {
    Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'duplicate' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$false -ResultFile '' -ErrorCode 'shard_registry_duplicate' -SelectedModule $m0
    return
}

$row = $match.matches[0]
$resultFile = [string]$row.result_file
if ([string]::IsNullOrWhiteSpace($resultFile) -or $resultFile.Contains('/') -or $resultFile.Contains('\') -or $resultFile.Contains(':') ) {
    Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'runtime_failure' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$false -ResultFile '' -ErrorCode 'resolver_runtime_failure' -SelectedModule $m0
    return
}

$resultPath = Join-Path (Get-Location).Path $resultFile
if (Test-Path -LiteralPath $resultPath) {
    # P03: preexisting result file — observe only
    Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'artifact_conflict' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$false -ResultFile $resultFile -ErrorCode 'preexisting_result_file' -SelectedModule $m0
    return
}

$resolve = & (Get-Module -Name 'winsmux-pester' -ErrorAction Stop) { Resolve-WinsmuxPester571 }
switch ([string]$resolve.resolution_status) {
    'missing' {
        Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'missing' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'install_once_then_rerun' -PesterInvoked:$false -ResultFile $resultFile -ErrorCode 'pester_5_7_1_missing' -SelectedModule $m0
        return
    }
    'ambiguous' {
        Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'ambiguous' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$false -ResultFile $resultFile -ErrorCode 'pester_5_7_1_ambiguous' -SelectedModule $m0
        return
    }
    'runtime_failure' {
        Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'runtime_failure' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$false -ResultFile $resultFile -ErrorCode 'resolver_runtime_failure' -SelectedModule $m0
        return
    }
    'resolved' { break }
    default {
        Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'runtime_failure' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$false -ResultFile $resultFile -ErrorCode 'resolver_runtime_failure' -SelectedModule $m0
        return
    }
}

$manifestPath = [string]$resolve.manifest_path
$m1 = New-Task810PresentModule -ManifestPath $manifestPath

try {
    $imported = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop
    if ($null -eq $imported -or [string]$imported.Name -cne 'Pester') { throw 'import identity name mismatch' }
    if ([string]$imported.Version -cne '5.7.1') { throw 'import identity version mismatch' }
    $importedPath = [System.IO.Path]::GetFullPath([string]$imported.Path)
    if (-not [System.StringComparer]::Ordinal.Equals($importedPath, [System.IO.Path]::GetFullPath($manifestPath))) {
        # Path may point to .psm1; accept ModuleBase match
        $base = [System.IO.Path]::GetFullPath([string]$imported.ModuleBase)
        $expectedBase = [System.IO.Path]::GetFullPath([string]$resolve.module_base)
        if (-not [System.StringComparer]::Ordinal.Equals($base, $expectedBase)) { throw 'import identity path mismatch' }
    }
} catch {
    Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'resolved' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$false -ResultFile $resultFile -ErrorCode 'pester_import_failure' -SelectedModule $m1
    return
}

try {
    $config = New-PesterConfiguration
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in @([string[]]$row.test_paths)) {
        $full = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $rel))
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "missing test path: $rel" }
        $paths.Add($full) | Out-Null
    }
    $config.Run.Path = [string[]]$paths.ToArray()
    $config.Run.PassThru = $true
    $config.Run.Exit = $false
    $config.Output.Verbosity = 'Normal'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = $resultPath
    $config.TestResult.OutputFormat = 'NUnitXml'
    $selector = [string]$row.selector_identity
    if (-not [string]::IsNullOrEmpty($selector)) {
        $config.Filter.FullName = [string[]]@([System.Management.Automation.WildcardPattern]::Escape($selector))
    }
} catch {
    Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'resolved' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$false -ResultFile $resultFile -ErrorCode 'pester_configuration_failure' -SelectedModule $m1
    return
}

$pesterResult = $null
$invoked = $false
try {
    $invoked = $true
    $pesterResult = Invoke-Pester -Configuration $config
    if ($null -eq $pesterResult) { throw 'Invoke-Pester returned no result' }
} catch {
    $existsAfter = Test-Path -LiteralPath $resultPath
    Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'resolved' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$true -ResultFile $(if ($existsAfter) { $resultFile } else { $resultFile }) -ErrorCode 'pester_runtime_failure' -SelectedModule $m1
    return
}

# Validate/classify
try {
    $runResult = [string]$pesterResult.Result
    $failedCount = 0
    if ($null -ne $pesterResult.PSObject.Properties['FailedCount']) { $failedCount = [int]$pesterResult.FailedCount }
    $failedBlocksCount = 0
    $failedContainersCount = 0
    if ($null -ne $pesterResult.PSObject.Properties['FailedBlocksCount']) { $failedBlocksCount = [int]$pesterResult.FailedBlocksCount }
    if ($null -ne $pesterResult.PSObject.Properties['FailedContainersCount']) { $failedContainersCount = [int]$pesterResult.FailedContainersCount }
    $origin = Get-Task810FailureOrigin -PesterResult $pesterResult

    $isPassed = [System.StringComparer]::Ordinal.Equals($runResult, 'Passed')
    $isFailed = [System.StringComparer]::Ordinal.Equals($runResult, 'Failed')
    if ($isPassed) {
        if ($failedCount -ne 0 -or $failedBlocksCount -ne 0 -or $failedContainersCount -ne 0 -or $origin -cne 'none') { throw 'passed aggregate contradiction' }
        $outcome = 'passed'
    } elseif ($isFailed) {
        if ($failedCount -eq 0 -and $failedBlocksCount -eq 0 -and $failedContainersCount -eq 0) { throw 'failed aggregate with empty collections' }
        if ($origin -ceq 'none') { throw 'failed aggregate with no admissible origin' }
        $outcome = 'failed'
    } else {
        throw "unsupported Run.Result: $runResult"
    }
} catch {
    $existsAfter = Test-Path -LiteralPath $resultPath
    Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'resolved' -ExecutionStatus 'completed' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$true -ResultFile $resultFile -ErrorCode 'pester_result_invalid' -SelectedModule $m1
    return
}

$fileExists = Test-Path -LiteralPath $resultPath
if ($outcome -eq 'passed') {
    if ($fileExists) {
        Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'resolved' -ExecutionStatus 'completed' -TestOutcome 'passed' -FailureOrigin 'none' -WorkflowAction 'succeed' -PesterInvoked:$true -ResultFile $resultFile -ErrorCode 'none' -SelectedModule $m1
        return
    }
    Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'resolved' -ExecutionStatus 'completed' -TestOutcome 'passed' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$true -ResultFile $resultFile -ErrorCode 'pester_result_file_missing' -SelectedModule $m1
    return
}

# failed outcomes P12-P15 / P17-P20
if ($fileExists) {
    Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'resolved' -ExecutionStatus 'completed' -TestOutcome 'failed' -FailureOrigin $origin -WorkflowAction 'fail' -PesterInvoked:$true -ResultFile $resultFile -ErrorCode 'pester_tests_failed' -SelectedModule $m1
    return
}
Emit-Task810Envelope -ShardIdValue $callerShardId -ResolutionStatus 'resolved' -ExecutionStatus 'completed' -TestOutcome 'failed' -FailureOrigin $origin -WorkflowAction 'fail' -PesterInvoked:$true -ResultFile $resultFile -ErrorCode 'pester_result_file_missing' -SelectedModule $m1
return
