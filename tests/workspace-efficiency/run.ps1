#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Comparison')]
param(
    [Parameter(ParameterSetName = 'Comparison', Mandatory = $true)][string] $BaselinePath,
    [Parameter(ParameterSetName = 'Comparison', Mandatory = $true)][string] $CandidatePath,
    [Parameter(ParameterSetName = 'Observer', Mandatory = $true)][string] $ObserverRoot,
    [Parameter(ParameterSetName = 'Observer', Mandatory = $true)][string] $Batches,
    [Parameter(ParameterSetName = 'SelfTest', Mandatory = $true)][switch] $SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$measurementTool = Join-Path $PSScriptRoot 'measure.py'
$measurementArguments = @($measurementTool)
switch ($PSCmdlet.ParameterSetName) {
    'SelfTest' { $measurementArguments += '--self-test' }
    'Observer' {
        $batchNumbers = @($Batches.Split(','))
        foreach ($batchNumber in $batchNumbers) {
            if ($batchNumber -cnotmatch '^[1-9][0-9]*$') { throw 'Batch selection must contain comma-separated positive integers' }
        }
        $measurementArguments += @('--observer-root', $ObserverRoot, '--batches') + $batchNumbers
    }
    'Comparison' { $measurementArguments += @('--baseline', $BaselinePath, '--candidate', $CandidatePath) }
    default { throw 'Unknown measurement mode' }
}
& python @measurementArguments
exit $LASTEXITCODE
