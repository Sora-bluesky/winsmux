param(
    [Parameter(Mandatory = $true)][string]$ReferenceDir,
    [Parameter(Mandatory = $true)][string]$CasePath,
    [Parameter(Mandatory = $true)][ValidateSet('core', 'regression')][string]$Group,
    [Parameter(Mandatory = $true)][string]$RepoDir
)

$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $script:Utf8NoBom
$OutputEncoding = $script:Utf8NoBom

function Resolve-HarnessBenchPath {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDir,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return (Resolve-Path -LiteralPath $Path).Path
    }
    return (Resolve-Path -LiteralPath (Join-Path $BaseDir $Path)).Path
}

function Disable-HarnessBenchYamlList {
    param(
        [Parameter(Mandatory = $true)][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $output = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $Lines.Count; $index += 1) {
        $line = [string]$Lines[$index]
        if ($line -notmatch "^(?<indent>\s*)$([regex]::Escape($Key)):\s*$") {
            $output.Add($line) | Out-Null
            continue
        }

        $indent = $Matches['indent']
        $output.Add("${indent}${Key}: []") | Out-Null
        $blockIndentLength = $indent.Length
        $index += 1
        while ($index -lt $Lines.Count) {
            $candidate = [string]$Lines[$index]
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                $index += 1
                continue
            }
            $candidateIndentLength = ([regex]::Match($candidate, '^\s*')).Value.Length
            if ($candidateIndentLength -le $blockIndentLength) {
                $index -= 1
                break
            }
            $index += 1
        }
    }

    return @($output)
}

$resolvedReferenceDir = (Resolve-Path -LiteralPath $ReferenceDir).Path
$resolvedCasePath = Resolve-HarnessBenchPath -BaseDir $resolvedReferenceDir -Path $CasePath
$resolvedRepoDir = (Resolve-Path -LiteralPath $RepoDir).Path
$runCaseScript = Join-Path $resolvedReferenceDir 'scripts\run-case.mjs'
if (-not (Test-Path -LiteralPath $runCaseScript -PathType Leaf)) {
    throw "HarnessBench run-case.mjs was not found: $runCaseScript"
}

$caseLines = @(Get-Content -LiteralPath $resolvedCasePath -Encoding UTF8)
if ($Group -eq 'core') {
    $caseLines = Disable-HarnessBenchYamlList -Lines $caseLines -Key 'regression_tests'
} else {
    $caseLines = Disable-HarnessBenchYamlList -Lines $caseLines -Key 'core_tests'
}

$tempCasePath = Join-Path ([System.IO.Path]::GetTempPath()) ('winsmux-harnessbench-{0}-{1}.yaml' -f $Group, [guid]::NewGuid().ToString('N'))
[System.IO.File]::WriteAllText($tempCasePath, (($caseLines -join "`n") + "`n"), $script:Utf8NoBom)
try {
    Push-Location $resolvedReferenceDir
    try {
        & node $runCaseScript --case $tempCasePath --mode verify-current --repoDir $resolvedRepoDir
        exit $LASTEXITCODE
    } finally {
        Pop-Location
    }
} finally {
    Remove-Item -LiteralPath $tempCasePath -Force -ErrorAction SilentlyContinue
}
