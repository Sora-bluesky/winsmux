[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [string]$InstallScriptPath = 'install.ps1',
    [string]$Treeish = 'HEAD'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}
$installerPath = if ([System.IO.Path]::IsPathRooted($InstallScriptPath)) {
    [System.IO.Path]::GetFullPath($InstallScriptPath)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $InstallScriptPath))
}

if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Installer script not found: $installerPath"
}

$treeObject = (& git -C $repoRoot rev-parse --verify --end-of-options "${Treeish}^{tree}" 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $treeObject -notmatch '^[0-9a-fA-F]{40,64}$') {
    throw "Installer verification treeish does not resolve to a Git tree: $Treeish"
}

$parseTokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath,
    [ref]$parseTokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
    throw "Installer script has parse errors: $messages"
}

function Get-EnclosingFunctionName {
    param([Parameter(Mandatory = $true)]$Ast)

    $current = $Ast.Parent
    while ($null -ne $current) {
        if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $current.Name
        }
        $current = $current.Parent
    }
    return ''
}

$downloadCommands = @($ast.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
        return $false
    }
    return @('Download-File', 'Download-OptionalFile') -contains $node.GetCommandName()
}, $true))

$declaredPaths = [System.Collections.Generic.List[string]]::new()
foreach ($command in $downloadCommands) {
    $enclosingFunction = Get-EnclosingFunctionName -Ast $command
    if ($enclosingFunction -eq 'Download-OptionalFile') {
        continue
    }
    if ($command.CommandElements.Count -lt 2 -or
        $command.CommandElements[1] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
        throw "Download declaration must use a static string literal at line $($command.Extent.StartLineNumber): $($command.Extent.Text)"
    }

    $relativePath = $command.CommandElements[1].Value.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relativePath) -or
        [System.IO.Path]::IsPathRooted($relativePath) -or
        $relativePath.Split('/') -contains '..' -or
        $relativePath.Contains('?') -or
        $relativePath.Contains('#') -or
        [Uri]::IsWellFormedUriString($relativePath, [UriKind]::Absolute)) {
        throw "Download declaration has an unsafe relative path at line $($command.Extent.StartLineNumber): $relativePath"
    }
    $declaredPaths.Add($relativePath)
}

$uniquePaths = @($declaredPaths | Sort-Object -Unique)
if ($uniquePaths.Count -eq 0) {
    throw 'Installer declares no downloadable repository files.'
}

$missingPaths = [System.Collections.Generic.List[string]]::new()
$nonBlobPaths = [System.Collections.Generic.List[string]]::new()
foreach ($relativePath in $uniquePaths) {
    $objectType = (& git -C $repoRoot cat-file -t "${treeObject}:$relativePath" 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        $missingPaths.Add($relativePath)
    } elseif ($objectType -ne 'blob') {
        $nonBlobPaths.Add("$relativePath ($objectType)")
    }
}
if ($missingPaths.Count -gt 0) {
    throw "Installer download targets missing from '$Treeish': $($missingPaths -join ', ')"
}
if ($nonBlobPaths.Count -gt 0) {
    throw "Installer download targets are not files in '$Treeish': $($nonBlobPaths -join ', ')"
}

[ordered]@{
    schema_version = 1
    treeish = $Treeish
    tree_object = $treeObject
    install_script = $installerPath
    download_target_count = $uniquePaths.Count
    download_targets = $uniquePaths
} | ConvertTo-Json -Depth 4
