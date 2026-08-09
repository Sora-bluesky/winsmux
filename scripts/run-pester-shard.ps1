[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$ShardId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'winsmux-pester.psm1'
Import-Module -Name $modulePath -ErrorAction Stop

function New-SelectedModuleAbsent {
    return [pscustomobject][ordered]@{
        present = $false
        name = ''
        semantic_version = ''
        manifest_path = ''
    }
}

function New-WinsmuxPesterEnvelope {
    param(
        [Parameter(Mandatory = $true)][string]$ResolutionStatus,
        [Parameter(Mandatory = $true)][string]$ExecutionStatus,
        [Parameter(Mandatory = $true)][string]$TestOutcome,
        [Parameter(Mandatory = $true)][string]$FailureOrigin,
        [Parameter(Mandatory = $true)][string]$WorkflowAction,
        [Parameter(Mandatory = $true)][bool]$PesterInvoked,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ResultFile,
        [Parameter(Mandatory = $true)][string]$ErrorCode,
        [Parameter(Mandatory = $true)][pscustomobject]$SelectedModule
    )

    return [pscustomobject][ordered]@{
        schema_version = '1'
        shard_id = $ShardId
        resolution_status = $ResolutionStatus
        execution_status = $ExecutionStatus
        test_outcome = $TestOutcome
        failure_origin = $FailureOrigin
        workflow_action = $WorkflowAction
        pester_invoked = $PesterInvoked
        result_file = $ResultFile
        error_code = $ErrorCode
        selected_module = $SelectedModule
    }
}

function Get-WinsmuxPesterFailureOrigin {
    param(
        [Parameter(Mandatory = $true)]$Run
    )

    $requiredProperties = @(
        'Result', 'Failed', 'FailedBlocks', 'FailedContainers', 'Passed', 'Skipped',
        'Inconclusive', 'NotRun', 'Tests', 'FailedCount', 'FailedBlocksCount',
        'FailedContainersCount', 'PassedCount', 'SkippedCount', 'InconclusiveCount',
        'NotRunCount', 'TotalCount'
    )
    foreach ($propertyName in $requiredProperties) {
        if ($null -eq $Run.PSObject.Properties[$propertyName]) {
            return $null
        }
    }

    $collections = [ordered]@{
        Failed = @($Run.Failed)
        FailedBlocks = @($Run.FailedBlocks)
        FailedContainers = @($Run.FailedContainers)
        Passed = @($Run.Passed)
        Skipped = @($Run.Skipped)
        Inconclusive = @($Run.Inconclusive)
        NotRun = @($Run.NotRun)
        Tests = @($Run.Tests)
    }
    $countProperties = [ordered]@{
        Failed = 'FailedCount'
        FailedBlocks = 'FailedBlocksCount'
        FailedContainers = 'FailedContainersCount'
        Passed = 'PassedCount'
        Skipped = 'SkippedCount'
        Inconclusive = 'InconclusiveCount'
        NotRun = 'NotRunCount'
    }
    foreach ($collectionName in $countProperties.Keys) {
        $countValue = $Run.($countProperties[$collectionName])
        if ($countValue -isnot [int] -or $countValue -ne $collections[$collectionName].Count) {
            return $null
        }
    }

    if ($Run.TotalCount -isnot [int] -or $Run.TotalCount -ne $collections.Tests.Count) {
        return $null
    }

    $terminalCount = $Run.FailedCount + $Run.PassedCount + $Run.SkippedCount + $Run.InconclusiveCount + $Run.NotRunCount
    if ($Run.TotalCount -ne $terminalCount) {
        return $null
    }

    $failedTests = $collections.Failed
    $failedBlocks = $collections.FailedBlocks
    $failedContainers = $collections.FailedContainers
    $hasAssertions = $false
    $hasTestRuntime = $false
    $hasBlockOrContainer = ($failedBlocks.Count -gt 0 -or $failedContainers.Count -gt 0)

    foreach ($test in $failedTests) {
        if ($null -eq $test) {
            return $null
        }

        $shouldRunProperty = $test.PSObject.Properties['ShouldRun']
        $executedProperty = $test.PSObject.Properties['Executed']
        $errorsProperty = $test.PSObject.Properties['ErrorRecord']
        if ($null -eq $shouldRunProperty -or $null -eq $executedProperty -or $null -eq $errorsProperty) {
            return $null
        }

        if ($test.ShouldRun -and -not $test.Executed) {
            $hasBlockOrContainer = $true
            continue
        }

        if (-not $test.Executed) {
            return $null
        }

        $admissibleError = $false
        foreach ($errorRecord in @($test.ErrorRecord)) {
            if ($null -eq $errorRecord -or $null -eq $errorRecord.PSObject.Properties['FullyQualifiedErrorId']) {
                return $null
            }

            $errorId = [string]$errorRecord.FullyQualifiedErrorId
            if ([System.StringComparer]::Ordinal.Equals($errorId, 'PesterAssertionFailed')) {
                $hasAssertions = $true
                $admissibleError = $true
            } elseif (
                -not [System.StringComparer]::Ordinal.Equals($errorId, 'PesterTestSkipped') -and
                -not [System.StringComparer]::Ordinal.Equals($errorId, 'PesterTestInconclusive') -and
                -not [System.StringComparer]::Ordinal.Equals($errorId, 'PesterTestPending')
            ) {
                $hasTestRuntime = $true
                $admissibleError = $true
            }
        }

        if (-not $admissibleError) {
            return $null
        }
    }

    $hasAnyFailure = $failedTests.Count -gt 0 -or $failedBlocks.Count -gt 0 -or $failedContainers.Count -gt 0
    if ($Run.Result -eq 'Passed') {
        if ($hasAnyFailure) {
            return $null
        }

        return 'none'
    }

    if ($Run.Result -ne 'Failed' -or -not $hasAnyFailure) {
        return $null
    }

    $flagCount = @($hasAssertions, $hasTestRuntime, $hasBlockOrContainer | Where-Object { $_ }).Count
    if ($flagCount -eq 0) {
        return $null
    }

    if ($flagCount -gt 1) {
        return 'mixed'
    }

    if ($hasAssertions) {
        return 'assertion'
    }

    if ($hasTestRuntime) {
        return 'test_runtime'
    }

    return 'block_or_container'
}

$absentModule = New-SelectedModuleAbsent
$envelope = $null
$shardResolution = Resolve-WinsmuxPesterShard -ShardId $ShardId

switch ($shardResolution.status) {
    'empty' {
        $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'empty' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked $false -ResultFile '' -ErrorCode 'shard_id_empty' -SelectedModule $absentModule
        break
    }
    'unknown' {
        $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'unknown' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked $false -ResultFile '' -ErrorCode 'shard_id_unknown' -SelectedModule $absentModule
        break
    }
    'duplicate' {
        $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'duplicate' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked $false -ResultFile '' -ErrorCode 'shard_registry_duplicate' -SelectedModule $absentModule
        break
    }
    'resolved' { }
    default { throw 'Unexpected shard resolver status.' }
}

if ($null -eq $envelope) {
    $shard = $shardResolution.shard
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $resultPath = Join-Path -Path $repositoryRoot -ChildPath $shard.result_file
    $resultExistsBeforeResolution = Test-Path -LiteralPath $resultPath

    if ($resultExistsBeforeResolution) {
        $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'artifact_conflict' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked $false -ResultFile $shard.result_file -ErrorCode 'preexisting_result_file' -SelectedModule $absentModule
    } else {
        $moduleResolution = Resolve-WinsmuxPesterModule
        switch ($moduleResolution.status) {
            'missing' {
                $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'missing' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'install_once_then_rerun' -PesterInvoked $false -ResultFile $shard.result_file -ErrorCode 'pester_5_7_1_missing' -SelectedModule $absentModule
            }
            'ambiguous' {
                $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'ambiguous' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked $false -ResultFile $shard.result_file -ErrorCode 'pester_5_7_1_ambiguous' -SelectedModule $absentModule
            }
            'runtime_failure' {
                $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'runtime_failure' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked $false -ResultFile $shard.result_file -ErrorCode 'resolver_runtime_failure' -SelectedModule $absentModule
            }
            'resolved' {
                $selectedModule = $moduleResolution.selected_module
                try {
                    $importedModule = Import-Module -Name $selectedModule.manifest_path -Force -PassThru -ErrorAction Stop
                    if ($importedModule.Name -ne 'Pester' -or $importedModule.Version -ne [version]'5.7.1') {
                        throw 'Exact Pester module import verification failed.'
                    }
                } catch {
                    $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'resolved' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked $false -ResultFile $shard.result_file -ErrorCode 'pester_import_failure' -SelectedModule $selectedModule
                    break
                }

                try {
                    $configuration = New-PesterConfiguration
                    $configuration.Run.Path = @($shard.paths | ForEach-Object { Join-Path -Path $repositoryRoot -ChildPath $_ })
                    $configuration.Run.PassThru = $true
                    $configuration.TestResult.Enabled = $true
                    $configuration.TestResult.OutputPath = $resultPath
                    $configuration.TestResult.OutputFormat = 'NUnitXml'
                } catch {
                    $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'resolved' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked $false -ResultFile $shard.result_file -ErrorCode 'pester_configuration_failure' -SelectedModule $selectedModule
                    break
                }

                try {
                    $pesterInvoked = $true
                    $run = Invoke-Pester -Configuration $configuration
                    if ($null -eq $run) {
                        $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'resolved' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked $pesterInvoked -ResultFile $shard.result_file -ErrorCode 'pester_runtime_failure' -SelectedModule $selectedModule
                        break
                    }
                } catch {
                    $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'resolved' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked $true -ResultFile $shard.result_file -ErrorCode 'pester_runtime_failure' -SelectedModule $selectedModule
                    break
                }

                $failureOrigin = Get-WinsmuxPesterFailureOrigin -Run $run
                if ($null -eq $failureOrigin) {
                    $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'resolved' -ExecutionStatus 'completed' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked $true -ResultFile $shard.result_file -ErrorCode 'pester_result_invalid' -SelectedModule $selectedModule
                    break
                }

                $testOutcome = if ($run.Result -eq 'Passed') { 'passed' } else { 'failed' }
                if (-not (Test-Path -LiteralPath $resultPath)) {
                    $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'resolved' -ExecutionStatus 'completed' -TestOutcome $testOutcome -FailureOrigin $failureOrigin -WorkflowAction 'fail' -PesterInvoked $true -ResultFile $shard.result_file -ErrorCode 'pester_result_file_missing' -SelectedModule $selectedModule
                    break
                }

                if ($testOutcome -eq 'passed') {
                    $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'resolved' -ExecutionStatus 'completed' -TestOutcome 'passed' -FailureOrigin 'none' -WorkflowAction 'succeed' -PesterInvoked $true -ResultFile $shard.result_file -ErrorCode 'none' -SelectedModule $selectedModule
                } else {
                    $envelope = New-WinsmuxPesterEnvelope -ResolutionStatus 'resolved' -ExecutionStatus 'completed' -TestOutcome 'failed' -FailureOrigin $failureOrigin -WorkflowAction 'fail' -PesterInvoked $true -ResultFile $shard.result_file -ErrorCode 'pester_tests_failed' -SelectedModule $selectedModule
                }
            }
            default { throw 'Unexpected module resolver status.' }
        }
    }
}

return ($envelope | ConvertTo-Json -Compress -Depth 4)
