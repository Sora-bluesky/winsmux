[CmdletBinding()]
param(
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'test-v03638-router-distribution: failed to determine repository root.'
}

$artifacts = @(
    [ordered]@{ source = 'winsmux-core/scripts/coordinator-router.ps1'; target = 'winsmux-core/scripts/coordinator-router.ps1'; installer_root = 'BRIDGE_SCRIPTS_DIR' },
    [ordered]@{ source = 'winsmux-core/scripts/local-router-shadow.ps1'; target = 'winsmux-core/scripts/local-router-shadow.ps1'; installer_root = 'BRIDGE_SCRIPTS_DIR' },
    [ordered]@{ source = 'winsmux-core/router/local-small-router-v03621.manifest.json'; target = 'winsmux-core/router/local-small-router-v03621.manifest.json'; installer_root = 'BRIDGE_ROUTER_DIR' },
    [ordered]@{ source = 'winsmux-core/router/local-small-router-v03621.weights.json'; target = 'winsmux-core/router/local-small-router-v03621.weights.json'; installer_root = 'BRIDGE_ROUTER_DIR' }
)

function ConvertTo-ForwardSlashPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return $Path.Replace('\', '/').TrimStart('/')
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-GitBlobSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Treeish,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $tempPath = Join-Path ([IO.Path]::GetTempPath()) ("winsmux-router-blob-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    $process = $null
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command git -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @('-C', $repoRoot, 'cat-file', 'blob', "${Treeish}:$RelativePath")) {
            $startInfo.ArgumentList.Add($argument)
        }

        $process = [Diagnostics.Process]::Start($startInfo)
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stream = [IO.FileStream]::new($tempPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $process.StandardOutput.BaseStream.CopyTo($stream)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        $process.WaitForExit()
        [void]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git cat-file failed for ${Treeish}:$RelativePath with exit $($process.ExitCode)."
        }
        return Get-Sha256 $tempPath
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction Stop
        }
    }
}

function Get-GitAttributeValue {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Attribute
    )

    $line = (& git -C $repoRoot check-attr $Attribute -- $RelativePath 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "git check-attr failed for $RelativePath ($Attribute)."
    }
    $prefix = "${RelativePath}: ${Attribute}: "
    if (-not $line.StartsWith($prefix, [StringComparison]::Ordinal)) {
        throw "git check-attr returned an unexpected record for $RelativePath ($Attribute)."
    }
    return $line.Substring($prefix.Length)
}

function Get-TauriResourceInventory {
    $configPath = Join-Path $repoRoot 'winsmux-app/src-tauri/tauri.conf.json'
    $configDirectory = Split-Path -Parent $configPath
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $inventory = @{}

    foreach ($mapping in $config.bundle.resources.PSObject.Properties) {
        $sourceSpec = Join-Path $configDirectory $mapping.Name
        $targetSpec = ConvertTo-ForwardSlashPath ([string]$mapping.Value)
        $usesWildcard = $mapping.Name.IndexOfAny([char[]]'*?') -ge 0
        $sourceFiles = if ($usesWildcard) {
            @(Get-ChildItem -Path $sourceSpec -File -ErrorAction SilentlyContinue)
        } elseif (Test-Path -LiteralPath $sourceSpec -PathType Leaf) {
            @(Get-Item -LiteralPath $sourceSpec)
        } else {
            @()
        }

        foreach ($sourceFile in $sourceFiles) {
            $targetPath = if ($usesWildcard) {
                ConvertTo-ForwardSlashPath (Join-Path $targetSpec $sourceFile.Name)
            } else {
                $targetSpec
            }
            $inventory[$targetPath] = [ordered]@{
                source = ConvertTo-ForwardSlashPath ([IO.Path]::GetRelativePath($repoRoot, $sourceFile.FullName))
                sha256 = Get-Sha256 $sourceFile.FullName
            }
        }
    }

    return $inventory
}

function Get-InstallerInventory {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory = $true)][System.Management.Automation.Language.FunctionDefinitionAst]$InstallFunction
    )

    $inventory = @{}
    $downloadCommands = @($InstallFunction.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Download-File'
    }, $true))

    foreach ($artifact in $artifacts) {
        $matchingCommand = $downloadCommands | Where-Object {
            $_.CommandElements.Count -ge 3 -and
            $_.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $_.CommandElements[1].Value -ceq $artifact.source
        } | Select-Object -First 1
        $destinationMatches = $false
        if ($null -ne $matchingCommand) {
            $destinationText = $matchingCommand.CommandElements[2].Extent.Text
            $destinationMatches = $destinationText -match ('\$' + [regex]::Escape($artifact.installer_root) + '\b') -and
                $destinationText -match [regex]::Escape([IO.Path]::GetFileName($artifact.target))
        }
        $inventory[$artifact.target] = [ordered]@{
            source = $artifact.source
            declared = ($null -ne $matchingCommand)
            destination_matches = $destinationMatches
        }
    }

    return $inventory
}

$sourceInventory = @()
foreach ($artifact in $artifacts) {
    $sourcePath = Join-Path $repoRoot $artifact.source
    $present = Test-Path -LiteralPath $sourcePath -PathType Leaf
    $worktreeHash = if ($present) { Get-Sha256 $sourcePath } else { $null }
    $blobHash = Get-GitBlobSha256 -Treeish HEAD -RelativePath $artifact.source
    $requiresLfAttribute = $artifact.source -in @(
        'winsmux-core/scripts/coordinator-router.ps1',
        'winsmux-core/scripts/local-router-shadow.ps1'
    )
    $textAttribute = Get-GitAttributeValue -RelativePath $artifact.source -Attribute text
    $eolAttribute = Get-GitAttributeValue -RelativePath $artifact.source -Attribute eol
    $sourceInventory += , [ordered]@{
        path = $artifact.source
        present = $present
        blob_sha256 = $blobHash
        worktree_sha256 = $worktreeHash
        blob_matches_worktree = $present -and $blobHash -ceq $worktreeHash
        lf_attribute = -not $requiresLfAttribute -or ($textAttribute -ceq 'set' -and $eolAttribute -ceq 'lf')
    }
}
$sourceByPath = @{}
foreach ($item in $sourceInventory) { $sourceByPath[[string]$item.path] = $item }

$manifestResolvable = $false
$manifestError = $null
try {
    . (Join-Path $repoRoot 'winsmux-core/scripts/local-router-shadow.ps1')
    $resolvedArtifact = Resolve-WinsmuxLocalRouterArtifact
    $manifestResolvable =
        (Test-Path -LiteralPath $resolvedArtifact.manifest_path -PathType Leaf) -and
        (Test-Path -LiteralPath $resolvedArtifact.weights_path -PathType Leaf)
} catch {
    $manifestError = $_.Exception.Message
}

$tauriInventory = Get-TauriResourceInventory
$desktopItems = @($artifacts | ForEach-Object {
    $entry = $tauriInventory[$_.target]
    $sourceEntry = $sourceByPath[$_.source]
    [ordered]@{
        path = $_.target
        present = $null -ne $entry
        source_matches = $null -ne $entry -and [string]$entry.source -ceq $_.source
        sha256 = if ($null -ne $entry) { [string]$entry.sha256 } else { $null }
        blob_matches_resource = $null -ne $entry -and [string]$entry.sha256 -ceq [string]$sourceEntry.blob_sha256
    }
})

$installerPath = Join-Path $repoRoot 'install.ps1'
$parseTokens = $null
$parseErrors = $null
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$parseTokens, [ref]$parseErrors)
$functions = @($installerAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$installRouterFunction = $functions | Where-Object Name -CEQ 'Install-LocalRouterArtifacts' | Select-Object -First 1
$profileFunction = $functions | Where-Object Name -CEQ 'Get-InstallProfileContents' | Select-Object -First 1
$invokeInstallFunction = $functions | Where-Object Name -CEQ 'Invoke-Install' | Select-Object -First 1
$cleanupFunction = $functions | Where-Object Name -CEQ 'Remove-ProfileExcludedSupportScripts' | Select-Object -First 1

$installerInventory = @{}
if ($null -ne $installRouterFunction) {
    $installerInventory = Get-InstallerInventory -Ast $installerAst -InstallFunction $installRouterFunction
} else {
    foreach ($artifact in $artifacts) {
        $installerInventory[$artifact.target] = [ordered]@{
            source = $artifact.source
            declared = $false
            destination_matches = $false
        }
    }
}

$profileText = if ($null -ne $profileFunction) { $profileFunction.Extent.Text } else { '' }
$invokeInstallText = if ($null -ne $invokeInstallFunction) { $invokeInstallFunction.Extent.Text } else { '' }
$cleanupText = if ($null -ne $cleanupFunction) { $cleanupFunction.Extent.Text } else { '' }
$fullOwnsPayload = $profileText -match '(?m)^\s*"full"\s*\{[^\r\n]*"local_router_artifacts"'
$nonFullExcludePayload = @('core', 'orchestra', 'security') | ForEach-Object {
    $profileName = $_
    $lineMatch = [regex]::Match($profileText, ('(?m)^\s*"' + $profileName + '"\s*\{(?<body>[^\r\n]*)'))
    $lineMatch.Success -and $lineMatch.Groups['body'].Value -notmatch 'local_router_artifacts'
}
$installIsFullOnly = $invokeInstallText -match 'Test-InstallProfileContent\s+-Profile\s+\$resolvedInstallProfile\s+-Content\s+"local_router_artifacts"' -and
    $invokeInstallText -match 'Install-LocalRouterArtifacts'
$cleanupOwnsExactFiles = @($artifacts | Where-Object {
    $cleanupText -notmatch [regex]::Escape([IO.Path]::GetFileName($_.target))
}).Count -eq 0
$cleanupIsNonRecursive = $cleanupText -notmatch '(?s)Remove-Item[^\r\n]*(?:-Recurse|\s-r\b)'

$desktopFound = @($desktopItems | Where-Object { $_.present -and $_.source_matches -and $_.blob_matches_resource }).Count
$cliFound = @($installerInventory.Values | Where-Object { $_.declared -and $_.destination_matches }).Count
$sourceReady = @($sourceInventory | Where-Object {
    $_.present -and $_.blob_matches_worktree -and $_.lf_attribute -and
        -not [string]::IsNullOrWhiteSpace([string]$_.blob_sha256)
}).Count -eq $artifacts.Count
$profileReady = $fullOwnsPayload -and (@($nonFullExcludePayload | Where-Object { $_ }).Count -eq 3) -and $installIsFullOnly
$cleanupReady = $cleanupOwnsExactFiles -and $cleanupIsNonRecursive
$allPass = $sourceReady -and $manifestResolvable -and ($parseErrors.Count -eq 0) -and
    ($desktopFound -eq $artifacts.Count) -and ($cliFound -eq $artifacts.Count) -and
    $profileReady -and $cleanupReady

$result = [ordered]@{
    gate_id = 'v03638-router-distribution'
    all_pass = $allPass
    source = [ordered]@{
        found = @($sourceInventory | Where-Object present).Count
        expected = $artifacts.Count
        manifest_resolvable = $manifestResolvable
        manifest_error = $manifestError
        items = $sourceInventory
    }
    desktop = [ordered]@{
        found = $desktopFound
        expected = $artifacts.Count
        items = $desktopItems
    }
    cli_full = [ordered]@{
        found = $cliFound
        expected = $artifacts.Count
        profile_full_only = $profileReady
        exact_file_cleanup = $cleanupReady
        items = @($artifacts | ForEach-Object {
            $entry = $installerInventory[$_.target]
            [ordered]@{ path = $_.target; declared = $entry.declared; destination_matches = $entry.destination_matches }
        })
    }
    parse_error_count = $parseErrors.Count
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8 -Compress
} else {
    Write-Host ("source={0}/{1} manifest_resolvable={2}" -f $result.source.found, $result.source.expected, $result.source.manifest_resolvable)
    Write-Host ("desktop={0}/{1}" -f $result.desktop.found, $result.desktop.expected)
    Write-Host ("cli_full={0}/{1} profile_full_only={2} exact_file_cleanup={3}" -f $result.cli_full.found, $result.cli_full.expected, $result.cli_full.profile_full_only, $result.cli_full.exact_file_cleanup)
}

if (-not $allPass) {
    exit 1
}
