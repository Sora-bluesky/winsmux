param(
    [ValidateRange(0, 100)]
    [int]$CoverageThreshold = 75
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CoverageTargets {
    param([string]$RepositoryRoot)

    $testFiles = Get-ChildItem -Path (Join-Path $RepositoryRoot 'tests') -Filter '*.Tests.ps1' -File -ErrorAction SilentlyContinue
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
        [int]$CoverageThreshold
    )

    $summary = [ordered]@{
        passed = $PassedCount
        failed = $FailedCount
        total = $TotalCount
        coveragePercent = $CoveragePercent
        coverageThreshold = $CoverageThreshold
    }

    $summary | ConvertTo-Json | Set-Content -Path $Path -Encoding UTF8
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resultsDirectory = Join-Path $repositoryRoot 'artifacts\test-results'
$testResultPath = Join-Path $resultsDirectory 'pester-results.xml'
$coverageReportPath = Join-Path $resultsDirectory 'coverage.xml'
$summaryPath = Join-Path $resultsDirectory 'summary.json'

New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null

$coverageTargets = @(Get-CoverageTargets -RepositoryRoot $repositoryRoot)

if ($coverageTargets.Count -eq 0) {
    Write-TestSummary -Path $summaryPath -PassedCount 0 -FailedCount 1 -TotalCount 0 -CoveragePercent $null -CoverageThreshold $CoverageThreshold
    Write-Output 'Pester: no coverage targets found'
    Write-Output 'Coverage: unavailable'
    exit 1
}

$pesterModule = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pesterModule) {
    Write-TestSummary -Path $summaryPath -PassedCount 0 -FailedCount 1 -TotalCount 0 -CoveragePercent $null -CoverageThreshold $CoverageThreshold
    Write-Output 'Pester: module not found'
    Write-Output 'Coverage: unavailable'
    exit 1
}

$result = $null

if ($pesterModule.Version.Major -ge 5) {
    Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
    $configuration = [PesterConfiguration]::Default
    $configuration.Run.Path = @((Join-Path $repositoryRoot 'tests'))
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'None'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'NUnitXml'
    $configuration.TestResult.OutputPath = $testResultPath
    $configuration.CodeCoverage.Enabled = $true
    $configuration.CodeCoverage.Path = $coverageTargets
    $configuration.CodeCoverage.OutputPath = $coverageReportPath
    $result = Invoke-Pester -Configuration $configuration
} else {
    $result = Invoke-Pester (Join-Path $repositoryRoot 'tests') -PassThru -Quiet -CodeCoverage $coverageTargets -OutputFormat NUnitXml -OutputFile $testResultPath
}

$passedCount = [int]($result.PassedCount ?? 0)
$failedCount = [int]($result.FailedCount ?? 0)
$totalCount = [int]($result.TotalCount ?? ($passedCount + $failedCount))
$coveragePercent = Get-CoveragePercent -CodeCoverage $result.CodeCoverage
$thresholdMet = ($null -ne $coveragePercent) -and ($coveragePercent -ge $CoverageThreshold)

Write-TestSummary -Path $summaryPath -PassedCount $passedCount -FailedCount $failedCount -TotalCount $totalCount -CoveragePercent $coveragePercent -CoverageThreshold $CoverageThreshold

Write-Output ('Pester: Passed={0} Failed={1} Total={2}' -f $passedCount, $failedCount, $totalCount)
if ($null -ne $coveragePercent) {
    Write-Output ('Coverage: {0:N2}% (threshold: {1}%)' -f $coveragePercent, $CoverageThreshold)
} else {
    Write-Output ('Coverage: unavailable (threshold: {0}%)' -f $CoverageThreshold)
}

if (($failedCount -eq 0) -and $thresholdMet) {
    exit 0
}

exit 1
