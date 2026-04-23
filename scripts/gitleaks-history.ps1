[CmdletBinding()]
param(
    [string]$Source = '.',

    [string]$LogOpts = '',

    [string]$BaselineFile = 'scripts/gitleaks-history-baseline.txt',

    [switch]$Full,

    [switch]$UpdateBaseline
)

$ErrorActionPreference = 'Stop'

$gitleaks = Get-Command gitleaks -ErrorAction SilentlyContinue
if ($null -eq $gitleaks) {
    throw 'gitleaks is required for secret scanning. Install gitleaks and retry.'
}

$sourcePath = (Resolve-Path -LiteralPath $Source).Path

$repoRoot = (git rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'Failed to determine repository root for gitleaks scan.'
}

$resolvedLogOpts = $LogOpts
if ([string]::IsNullOrWhiteSpace($resolvedLogOpts)) {
    if ($Full) {
        $resolvedLogOpts = '--all'
    }
    else {
        $baselinePath = Join-Path $repoRoot $BaselineFile
        if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
            throw "Missing gitleaks baseline file: $BaselineFile. Run scripts/gitleaks-history.ps1 -Full -UpdateBaseline after a full-history scan."
        }

        $baselineCommit = (Get-Content -LiteralPath $baselinePath -Raw).Trim()
        if ($baselineCommit -notmatch '^[0-9a-fA-F]{40}$') {
            throw "Invalid gitleaks baseline commit in ${BaselineFile}: $baselineCommit"
        }

        git cat-file -e "$baselineCommit^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Gitleaks baseline commit was not found locally: $baselineCommit"
        }

        git merge-base --is-ancestor $baselineCommit HEAD 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Gitleaks baseline commit is not an ancestor of HEAD: $baselineCommit"
        }

        $commitCount = (git rev-list --count "$baselineCommit..HEAD").Trim()
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to count commits after the gitleaks baseline.'
        }

        if ($commitCount -eq '0') {
            Write-Output "gitleaks skipped: no commits after baseline $baselineCommit"
            exit 0
        }

        $resolvedLogOpts = "$baselineCommit..HEAD"
    }
}

Write-Output "gitleaks scanning git log range: $resolvedLogOpts"
& $gitleaks.Source detect --source $sourcePath --log-opts $resolvedLogOpts --redact --exit-code 1
if ($LASTEXITCODE -ne 0) {
    throw "gitleaks scan failed with exit code $LASTEXITCODE."
}

if ($Full -and $UpdateBaseline) {
    $headCommit = (git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($headCommit)) {
        throw 'Failed to determine HEAD for gitleaks baseline update.'
    }

    $baselinePath = Join-Path $repoRoot $BaselineFile
    [System.IO.File]::WriteAllText($baselinePath, ($headCommit + [Environment]::NewLine))
    Write-Output "gitleaks baseline updated: $headCommit"
}
