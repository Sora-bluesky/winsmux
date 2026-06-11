param(
    [string]$ProjectDir = (Get-Location).Path,
    [string]$ReferenceDir = '',
    [string[]]$CasePath = @(),
    [string[]]$ConditionPath = @(),
    [string[]]$ConditionId = @(),
    [string]$OutputPath = '',
    [string]$SuiteId = 'harnessbench-upstream-reference',
    [int]$LimitCases = 0,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $script:Utf8NoBom
$OutputEncoding = $script:Utf8NoBom
$script:HbScriptDir = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Parent $PSCommandPath
} else {
    Join-Path $ProjectDir 'scripts'
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][string]$Value
    )

    [System.IO.File]::WriteAllText($Path, [string]$Value, $script:Utf8NoBom)
}

function ConvertTo-ProjectRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDir,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $baseFullPath = [System.IO.Path]::GetFullPath($BaseDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $targetFullPath = [System.IO.Path]::GetFullPath($Path)
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if ($targetFullPath.StartsWith($baseFullPath + [System.IO.Path]::DirectorySeparatorChar, $comparison) -or
        $targetFullPath.StartsWith($baseFullPath + [System.IO.Path]::AltDirectorySeparatorChar, $comparison)) {
        return [System.IO.Path]::GetRelativePath($baseFullPath, $targetFullPath)
    }

    return $targetFullPath
}

function ConvertTo-HbSafeId {
    param(
        [AllowNull()][string]$Value,
        [string]$Fallback = 'case'
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = $Fallback
    }
    $safe = $text.Trim() -replace '[^A-Za-z0-9._-]', '-'
    $safe = $safe.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return $Fallback
    }
    return $safe
}

function Get-HbArray {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary]) {
        return @($Value)
    }
    return @($Value)
}

function Get-HbValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Split-HbYamlKeyValue {
    param([Parameter(Mandatory = $true)][string]$Line)

    $index = $Line.IndexOf(':')
    if ($index -lt 0) {
        throw "unsupported HarnessBench YAML line: $Line"
    }
    return @($Line.Substring(0, $index).Trim(), $Line.Substring($index + 1).Trim())
}

function Get-HbNextMeaningfulLine {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][int]$Start
    )

    for ($index = $Start; $index -lt $Lines.Count; $index += 1) {
        $line = $Lines[$index]
        if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.Trim().StartsWith('#')) {
            return $line
        }
    }
    return $null
}

function ConvertFrom-HbYamlScalar {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return $null
    }
    $text = $Value.Trim()
    switch ($text) {
        '[]' { return @() }
        'null' { return $null }
        'true' { return $true }
        'false' { return $false }
    }
    if ($text -match '^-?\d+$') {
        $number = 0L
        if ([int64]::TryParse($text, [ref]$number)) {
            return $number
        }
        return $text
    }
    if ($text.StartsWith('[') -and $text.EndsWith(']')) {
        $inner = $text.Substring(1, $text.Length - 2).Trim()
        if ([string]::IsNullOrWhiteSpace($inner)) {
            return @()
        }
        return @($inner -split ',' | ForEach-Object { ConvertFrom-HbYamlScalar $_.Trim() })
    }
    if (($text.StartsWith('"') -and $text.EndsWith('"')) -or ($text.StartsWith("'") -and $text.EndsWith("'"))) {
        return $text.Substring(1, $text.Length - 2)
    }
    return $text
}

function ConvertFrom-HbSimpleYaml {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$SourceName = 'case'
    )

    $root = [ordered]@{}
    $stack = [System.Collections.Generic.List[object]]::new()
    $stack.Add([pscustomobject]@{ Indent = -1; Value = [object]$root }) | Out-Null
    $lines = @($Text -split "`r?`n")

    for ($index = 0; $index -lt $lines.Count; $index += 1) {
        $raw = [string]$lines[$index]
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim().StartsWith('#')) {
            continue
        }
        $indent = ([regex]::Match($raw, '^ *')).Value.Length
        $line = $raw.Trim()

        while ($stack.Count -gt 1 -and $indent -le $stack[$stack.Count - 1].PSObject.Properties['Indent'].Value) {
            $stack.RemoveAt($stack.Count - 1)
        }
        $parent = $stack[$stack.Count - 1].PSObject.Properties['Value'].Value

        if ($line.StartsWith('- ')) {
            if ($parent -isnot [System.Collections.ArrayList]) {
                $previous = $null
                for ($lookback = $index - 1; $lookback -ge 0; $lookback -= 1) {
                    $candidate = [string]$lines[$lookback]
                    if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not $candidate.Trim().StartsWith('#')) {
                        $previous = $candidate.Trim()
                        break
                    }
                }
                if ($parent -is [System.Collections.IDictionary] -and $null -ne $previous -and $previous.EndsWith(':')) {
                    $implicitKey = $previous.Substring(0, $previous.Length - 1).Trim()
                    $implicitList = [System.Collections.ArrayList]::new()
                    $parent[$implicitKey] = $implicitList
                    $parent = $implicitList
                    $stack.Add([pscustomobject]@{ Indent = $indent - 2; Value = [object]$implicitList }) | Out-Null
                } else {
                    throw "unsupported HarnessBench YAML list in ${SourceName}:$($index + 1)"
                }
            }
            $itemText = $line.Substring(2)
            if ($itemText.Contains(': ')) {
                $item = [ordered]@{}
                [void]$parent.Add($item)
                $parts = Split-HbYamlKeyValue $itemText
                $item[$parts[0]] = ConvertFrom-HbYamlScalar $parts[1]
                $stack.Add([pscustomobject]@{ Indent = $indent; Value = [object]$item }) | Out-Null
            } else {
                [void]$parent.Add((ConvertFrom-HbYamlScalar $itemText))
            }
            continue
        }

        $keyValue = Split-HbYamlKeyValue $line
        $key = $keyValue[0]
        $value = $keyValue[1]
        if ($null -eq $value -or $value -eq '') {
            $next = Get-HbNextMeaningfulLine -Lines $lines -Start ($index + 1)
            if ($null -ne $next -and $next.Trim().StartsWith('- ')) {
                $container = [System.Collections.ArrayList]::new()
            } else {
                $container = [ordered]@{}
            }
            $parent[$key] = $container
            $stack.Add([pscustomobject]@{ Indent = $indent; Value = [object]$container }) | Out-Null
        } elseif ($value -eq '>') {
            $blockLines = [System.Collections.Generic.List[string]]::new()
            $next = Get-HbNextMeaningfulLine -Lines $lines -Start ($index + 1)
            $blockIndent = if ($null -ne $next) { ([regex]::Match($next, '^ *')).Value.Length } else { $indent + 2 }
            $index += 1
            while ($index -lt $lines.Count) {
                $blockRaw = [string]$lines[$index]
                $blockRawIndent = ([regex]::Match($blockRaw, '^ *')).Value.Length
                if (-not [string]::IsNullOrWhiteSpace($blockRaw) -and $blockRawIndent -lt $blockIndent) {
                    $index -= 1
                    break
                }
                $sliceStart = [Math]::Min($blockIndent, $blockRaw.Length)
                $blockLines.Add($blockRaw.Substring($sliceStart)) | Out-Null
                $index += 1
            }
            $parent[$key] = (($blockLines -join ' ') -replace '\s+', ' ').Trim()
        } else {
            $parent[$key] = ConvertFrom-HbYamlScalar $value
        }
    }
    return $root
}

function Resolve-HbReferencePath {
    param(
        [Parameter(Mandatory = $true)][string]$ReferenceDir,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return (Resolve-Path -LiteralPath $Path).Path
    }
    return (Resolve-Path -LiteralPath (Join-Path $ReferenceDir $Path)).Path
}

function ConvertTo-WinsmuxWorker {
    param(
        [Parameter(Mandatory = $true)]$Condition,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $harness = ([string](Get-HbValue -Object $Condition -Name 'harness')).Trim()
    $model = [string](Get-HbValue -Object $Condition -Name 'model')
    $effort = [string](Get-HbValue -Object $Condition -Name 'effort')
    $conditionId = [string](Get-HbValue -Object $Condition -Name 'id')
    $displayOverride = [string](Get-HbValue -Object $Condition -Name 'display_model')

    switch ($harness.ToLowerInvariant()) {
        'codex' {
            $display = if ([string]::IsNullOrWhiteSpace($effort)) { "Codex / $model" } else { "Codex / $model ($effort)" }
            if (-not [string]::IsNullOrWhiteSpace($displayOverride)) {
                $display = $displayOverride
            }
            return [ordered]@{
                pane = "worker-$Index"
                role = 'solver'
                cli = 'Codex'
                model = $model
                effort = $effort
                display_model = $display
                harnessbench_condition_id = $conditionId
            }
        }
        'claude' {
            $display = if ([string]::IsNullOrWhiteSpace($effort)) { "Claude Code / $model" } else { "Claude Code / $model ($effort)" }
            if (-not [string]::IsNullOrWhiteSpace($displayOverride)) {
                $display = $displayOverride
            }
            return [ordered]@{
                pane = "worker-$Index"
                role = 'solver'
                cli = 'Claude Code'
                model = $model
                effort = $effort
                display_model = $display
                harnessbench_condition_id = $conditionId
            }
        }
        'antigravity' {
            $config = Get-HbValue -Object $Condition -Name 'antigravity_config'
            $configuredModel = [string](Get-HbValue -Object $config -Name 'model')
            if (-not [string]::IsNullOrWhiteSpace($configuredModel)) {
                $model = $configuredModel
            }
            $display = "Antigravity CLI / $model"
            if (-not [string]::IsNullOrWhiteSpace($displayOverride)) {
                $display = $displayOverride
            }
            return [ordered]@{
                pane = "worker-$Index"
                role = 'solver'
                cli = 'Antigravity CLI'
                model = $model
                effort = $effort
                display_model = $display
                harnessbench_condition_id = $conditionId
            }
        }
        default {
            return $null
        }
    }
}

function ConvertTo-WinsmuxCase {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][string]$CaseFile,
        [Parameter(Mandatory = $true)][string]$ReferenceDir,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    $caseId = ConvertTo-HbSafeId -Value ([string](Get-HbValue -Object $Case -Name 'id')) -Fallback ([System.IO.Path]::GetFileNameWithoutExtension($CaseFile))
    $repoUrl = [string](Get-HbValue -Object $Case -Name 'repo_url')
    $repo = if ([string]::IsNullOrWhiteSpace($repoUrl)) { [string](Get-HbValue -Object $Case -Name 'repo') } else { $repoUrl }
    $baseCommit = [string](Get-HbValue -Object $Case -Name 'base_commit')
    $instruction = [string](Get-HbValue -Object $Case -Name 'instruction')
    $title = [string](Get-HbValue -Object $Case -Name 'pr_title')
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = $caseId
    }
    $strategy = Get-HbValue -Object $Case -Name 'test_strategy'
    if ($null -eq $strategy) {
        throw "HarnessBench case $caseId must define test_strategy."
    }

    $hiddenCheckRunner = (Resolve-Path -LiteralPath (Join-Path $script:HbScriptDir 'invoke-harnessbench-hidden-check.ps1')).Path
    $casePathForCommand = (Resolve-Path -LiteralPath $CaseFile).Path
    $workspaceToken = '$env:WINSMUX_BAKEOFF_WORKSPACE'
    $hiddenChecks = [System.Collections.Generic.List[object]]::new()
    $coreIndex = 0
    foreach ($checkPath in (Get-HbArray (Get-HbValue -Object $strategy -Name 'core_tests'))) {
        $coreIndex += 1
        $hiddenChecks.Add([ordered]@{
            id = "core-$coreIndex"
            group = 'core'
            source_path = [string]$checkPath
            command = ('pwsh -NoLogo -NoProfile -File "{0}" -ReferenceDir "{1}" -CasePath "{2}" -Group core -RepoDir "{3}"' -f $hiddenCheckRunner, $ReferenceDir, $casePathForCommand, $workspaceToken)
            weight = 1.0
        }) | Out-Null
    }
    $regressionIndex = 0
    foreach ($checkPath in (Get-HbArray (Get-HbValue -Object $strategy -Name 'regression_tests'))) {
        $regressionIndex += 1
        $hiddenChecks.Add([ordered]@{
            id = "regression-$regressionIndex"
            group = 'regression'
            source_path = [string]$checkPath
            command = ('pwsh -NoLogo -NoProfile -File "{0}" -ReferenceDir "{1}" -CasePath "{2}" -Group regression -RepoDir "{3}"' -f $hiddenCheckRunner, $ReferenceDir, $casePathForCommand, $workspaceToken)
            weight = 1.0
        }) | Out-Null
    }
    if ($hiddenChecks.Count -eq 0) {
        throw "HarnessBench case $caseId must define at least one hidden core or regression test."
    }

    $setup = @(Get-HbArray (Get-HbValue -Object $Case -Name 'setup'))
    $publicTests = @(Get-HbArray (Get-HbValue -Object $Case -Name 'public_tests'))
    $publicChecks = @(($setup + $publicTests) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $successRule = [string](Get-HbValue -Object $strategy -Name 'success_rule')
    $successCriteria = @(
        'harnessbench_core_tests_pass',
        'harnessbench_regression_tests_pass'
    )
    if (-not [string]::IsNullOrWhiteSpace($successRule)) {
        $successCriteria += "harnessbench_success_rule:$successRule"
    }

    return [ordered]@{
        case_id = $caseId
        title = $title
        repo = $repo
        base_ref = $baseCommit
        difficulty = [string](Get-HbValue -Object $Case -Name 'difficulty')
        public_prompt = $instruction
        allowed_paths = @()
        public_checks = @($publicChecks)
        hidden_checks = @($hiddenChecks)
        success_criteria = @($successCriteria)
        harnessbench = [ordered]@{
            case_path = ConvertTo-ProjectRelativePath -BaseDir $ProjectDir -Path $CaseFile
            repo = [string](Get-HbValue -Object $Case -Name 'repo')
            pr_number = Get-HbValue -Object $Case -Name 'pr_number'
            pr_url = Get-HbValue -Object $Case -Name 'pr_url'
            original_pr_head_commit = Get-HbValue -Object $Case -Name 'original_pr_head_commit'
            fixed_commit = Get-HbValue -Object $Case -Name 'fixed_commit'
            success_rule = $successRule
        }
    }
}

$resolvedProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
if ([string]::IsNullOrWhiteSpace($ReferenceDir)) {
    $ReferenceDir = Join-Path (Join-Path $resolvedProjectDir '.references') 'nyosegawa\harness-bench'
}
$resolvedReferenceDir = (Resolve-Path -LiteralPath $ReferenceDir).Path

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Join-Path (Join-Path $resolvedProjectDir '.winsmux') 'private\cli-bakeoff\harnessbench-upstream') 'cases.json'
}
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $resolvedProjectDir $OutputPath
}
$outputDir = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

if ($ConditionPath.Count -eq 0) {
    $ConditionPath = @('benchmark/conditions/baseline.json')
}
$conditionDocuments = foreach ($path in $ConditionPath) {
    $resolvedPath = Resolve-HbReferencePath -ReferenceDir $resolvedReferenceDir -Path $path
    Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
}
$rawConditions = foreach ($document in $conditionDocuments) {
    if ($document -is [System.Array]) {
        @($document)
    } else {
        @(Get-HbArray $document.conditions)
    }
}
if ($ConditionId.Count -gt 0) {
    $wanted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $ConditionId) {
        [void]$wanted.Add($id)
    }
    $rawConditions = @($rawConditions | Where-Object { $wanted.Contains([string]$_.id) })
}
if (@($rawConditions).Count -eq 0) {
    throw 'No HarnessBench conditions matched the requested filters.'
}

$workers = [System.Collections.Generic.List[object]]::new()
$skippedConditions = [System.Collections.Generic.List[object]]::new()
$workerIndex = 0
foreach ($condition in $rawConditions) {
    $worker = ConvertTo-WinsmuxWorker -Condition $condition -Index ($workerIndex + 1)
    if ($null -eq $worker) {
        $skippedConditions.Add([ordered]@{
            id = [string]$condition.id
            harness = [string]$condition.harness
            reason = 'unsupported_by_winsmux_worker_adapter'
        }) | Out-Null
        continue
    }
    $workerIndex += 1
    $workers.Add($worker) | Out-Null
}
if ($workers.Count -eq 0) {
    throw 'No supported HarnessBench conditions remained after filtering.'
}

if ($CasePath.Count -eq 0) {
    $caseRoot = Join-Path $resolvedReferenceDir 'benchmark\cases'
    $CasePath = @(Get-ChildItem -LiteralPath $caseRoot -Recurse -Filter '*.yaml' -File |
        Where-Object { $_.FullName -notmatch '[\\/]' + [regex]::Escape('hidden-tests') + '[\\/]' } |
        Sort-Object FullName |
        ForEach-Object { $_.FullName })
}
$resolvedCasePaths = foreach ($path in $CasePath) {
    Resolve-HbReferencePath -ReferenceDir $resolvedReferenceDir -Path $path
}
if ($LimitCases -gt 0) {
    $resolvedCasePaths = @($resolvedCasePaths | Select-Object -First $LimitCases)
}
if (@($resolvedCasePaths).Count -eq 0) {
    throw 'No HarnessBench cases matched the requested filters.'
}

$cases = [System.Collections.Generic.List[object]]::new()
foreach ($caseFile in $resolvedCasePaths) {
    $caseText = Get-Content -LiteralPath $caseFile -Raw -Encoding UTF8
    $caseData = ConvertFrom-HbSimpleYaml -Text $caseText -SourceName (Split-Path -Leaf $caseFile)
    $cases.Add((ConvertTo-WinsmuxCase -Case $caseData -CaseFile $caseFile -ReferenceDir $resolvedReferenceDir -ProjectDir $resolvedProjectDir)) | Out-Null
}

$sourceConditionPaths = @($ConditionPath | ForEach-Object {
    ConvertTo-ProjectRelativePath -BaseDir $resolvedProjectDir -Path (Resolve-HbReferencePath -ReferenceDir $resolvedReferenceDir -Path $_)
})
$payload = [ordered]@{
    version = 1
    suite_id = $SuiteId
    source = [ordered]@{
        name = 'nyosegawa/harness-bench'
        reference_dir = ConvertTo-ProjectRelativePath -BaseDir $resolvedProjectDir -Path $resolvedReferenceDir
        conditions = @($sourceConditionPaths)
        skipped_conditions = @($skippedConditions)
    }
    default_workers = @($workers)
    cases = @($cases)
}

Write-Utf8File -Path $OutputPath -Value (($payload | ConvertTo-Json -Depth 64) + "`n")

$output = [ordered]@{
    output_path = $OutputPath
    suite_id = $SuiteId
    worker_count = $workers.Count
    case_count = $cases.Count
    skipped_condition_count = $skippedConditions.Count
    reference_dir = $resolvedReferenceDir
}

if ($Json) {
    $output | ConvertTo-Json -Depth 8
} else {
    Write-Output "created HarnessBench reference cases: $OutputPath"
}
