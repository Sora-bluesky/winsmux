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
        $gitCommand = Get-Command git -CommandType Application -TotalCount 1 -ErrorAction Stop
        $gitPath = [string]$gitCommand.Source
        $startInfo.FileName = $gitPath
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

function Test-DesktopWorkspaceDistributionContract {
    param([Parameter(Mandatory = $true)][object]$Config)

    # The workspace desktop carries paired native companions and checked licenses.
    # Legacy router support remains in the full script install profile only.
    try {
        $bins = @($Config.bundle.externalBin)
        $resources = @($Config.bundle.resources.PSObject.Properties)
        return $bins.Count -eq 2 -and
            (@($bins | Sort-Object) -join '|') -ceq 'binaries/winsmux|binaries/winsmux-workspace-mcp' -and
            $resources.Count -eq 1 -and
            $resources[0].Name -ceq 'binaries/licenses' -and
            $resources[0].Value -ceq 'licenses' -and
            $Config.build.beforeBuildCommand -ceq 'npm run prepare:companion-cli:release && npm run build' -and
            $Config.build.beforeBundleCommand -ceq 'node ./src-tauri/scripts/check-bundled-distribution.mjs'
    } catch {
        return $false
    }
}

function Test-InstallerRouterProfileContract {
    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$InstallerAst)

    # Follow the adopted support-stage call chain; router payload remains full-only.
    try {
        $definitions = @{}
        foreach ($name in @('Get-InstallProfileContents', 'Invoke-Install', 'Invoke-WinsmuxInstallLifecycle', 'Install-WinsmuxBinary', 'New-WinsmuxSupportStage')) {
            $found = @($InstallerAst.FindAll({ param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $true))
            if ($found.Count -ne 1) { return $false }
            $definitions[$name] = $found[0]
        }
        $profile = $definitions['Get-InstallProfileContents'].Extent.Text
        if ($profile -notmatch '(?m)^\s*"full"\s*\{[^\r\n]*"local_router_artifacts"') { return $false }
        foreach ($name in @('core', 'orchestra', 'security')) {
            $row = [regex]::Match($profile, ('(?m)^\s*"' + $name + '"\s*\{(?<body>[^\r\n]*)'))
            if (-not $row.Success -or $row.Groups['body'].Value -match 'local_router_artifacts') { return $false }
        }
        foreach ($edge in @(
            @('Invoke-Install', 'Invoke-WinsmuxInstallLifecycle'),
            @('Invoke-WinsmuxInstallLifecycle', 'Install-WinsmuxBinary'),
            @('Install-WinsmuxBinary', 'New-WinsmuxSupportStage')
        )) {
            $calls = @($definitions[$edge[0]].FindAll({ param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq $edge[1]
            }, $true))
            if ($calls.Count -ne 1) { return $false }
            if ($edge[0] -ceq 'Invoke-WinsmuxInstallLifecycle' -and $calls[0].Extent.Text -notmatch '-SupportProfile\s+\$profile\b') { return $false }
            if ($edge[0] -ceq 'Install-WinsmuxBinary' -and
                ($calls[0].CommandElements.Count -ne 4 -or $calls[0].CommandElements[2].Extent.Text -cne '$SupportProfile')) { return $false }
        }
        $routerCalls = @($InstallerAst.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Install-LocalRouterArtifacts'
        }, $true))
        $stageCalls = @($definitions['New-WinsmuxSupportStage'].FindAll({ param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Install-LocalRouterArtifacts'
        }, $true))
        if ($routerCalls.Count -ne 1 -or $stageCalls.Count -ne 1) { return $false }
        $guard = $stageCalls[0].Parent
        while ($guard -and $guard -isnot [System.Management.Automation.Language.IfStatementAst]) { $guard = $guard.Parent }
        if (-not $guard -or $guard.Clauses.Count -ne 1 -or $null -ne $guard.ElseClause) { return $false }
        $condition = $guard.Clauses[0].Item1.PipelineElements
        if ($condition.Count -ne 1 -or $condition[0] -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
        $command = $condition[0]
        return $command.GetCommandName() -ceq 'Test-InstallProfileContent' -and
            $command.CommandElements.Count -eq 3 -and
            $command.CommandElements[1].Extent.Text -ceq '$Profile' -and
            $command.CommandElements[2] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $command.CommandElements[2].Value -ceq 'local_router_artifacts'
    } catch { return $false }
}

function Get-TauriResourceInventory {
    $configPath = Join-Path $repoRoot 'winsmux-app/src-tauri/tauri.conf.json'
    $configDirectory = Split-Path -Parent $configPath
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:tauriConfig = $config
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

$cleanupText = if ($null -ne $cleanupFunction) { $cleanupFunction.Extent.Text } else { '' }
$cleanupOwnsExactFiles = @($artifacts | Where-Object {
    $cleanupText -notmatch [regex]::Escape([IO.Path]::GetFileName($_.target))
}).Count -eq 0
$cleanupIsNonRecursive = $cleanupText -notmatch '(?s)Remove-Item[^\r\n]*(?:-Recurse|\s-r\b)'

$desktopReady = (Test-DesktopWorkspaceDistributionContract -Config $script:tauriConfig) -and
    @($desktopItems | Where-Object present).Count -eq 0
$nativeFound = @($script:tauriConfig.bundle.externalBin | Where-Object { $_ -cin @('binaries/winsmux', 'binaries/winsmux-workspace-mcp') } | Sort-Object -Unique).Count
$cliFound = @($installerInventory.Values | Where-Object { $_.declared -and $_.destination_matches }).Count
$sourceReady = @($sourceInventory | Where-Object {
    $_.present -and $_.blob_matches_worktree -and $_.lf_attribute -and
        -not [string]::IsNullOrWhiteSpace([string]$_.blob_sha256)
}).Count -eq $artifacts.Count
$profileReady = Test-InstallerRouterProfileContract -InstallerAst $installerAst
$cleanupReady = $cleanupOwnsExactFiles -and $cleanupIsNonRecursive
$allPass = $sourceReady -and $manifestResolvable -and ($parseErrors.Count -eq 0) -and
    $desktopReady -and ($cliFound -eq $artifacts.Count) -and
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
        found = $nativeFound
        expected = 2
        paired_native_contract = $desktopReady
        legacy_resources_absent = @($desktopItems | Where-Object present).Count -eq 0
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
