# One installer inventory contract shared by candidate, offline and public smoke.
Set-StrictMode -Version Latest

function Assert-DesktopInventoryCondition {
    param([bool]$Condition, [string]$Reason)
    if (-not $Condition) { throw $Reason }
}

function Assert-DesktopInventoryShape {
    param($Value, [AllowEmptyCollection()][string[]]$Keys)
    $reason = 'desktop_inventory_shape_invalid'
    Assert-DesktopInventoryCondition ($null -ne $Value -and $null -ne $Keys) $reason
    $dictionary = $Value -is [Collections.IDictionary]
    Assert-DesktopInventoryCondition ($dictionary -or $Value.GetType() -eq [System.Management.Automation.PSCustomObject]) $reason
    $actual = @(if ($dictionary) {
        foreach ($entry in $Value.GetEnumerator()) {
            Assert-DesktopInventoryCondition ($entry.Key -is [string]) $reason
            $entry.Key
        }
    } else {
        foreach ($property in $Value.PSObject.Properties) { $property.Name }
    })
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in $Keys) {
        Assert-DesktopInventoryCondition ($null -ne $key -and $expected.Add($key)) $reason
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in $actual) { Assert-DesktopInventoryCondition $names.Add($key) $reason }
    Assert-DesktopInventoryCondition ($names.SetEquals($expected)) $reason
}

function Read-DesktopStrictJson {
    param([string]$Path)
    Assert-DesktopPlainPath $Path
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-DesktopInventoryCondition ($bytes.Length -gt 0 -and -not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'desktop_inventory_encoding_invalid'
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    return (ConvertFrom-DesktopStrictJsonText $text)
}

function ConvertFrom-DesktopStrictJsonText {
    param([string]$Text)
    $document = [Text.Json.JsonDocument]::Parse($Text)
    function Assert-UniqueDesktopJson($Element) {
        if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                Assert-DesktopInventoryCondition $seen.Add($property.Name) 'desktop_inventory_duplicate_key'
                Assert-UniqueDesktopJson $property.Value
            }
        } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
            foreach ($item in $Element.EnumerateArray()) { Assert-UniqueDesktopJson $item }
        }
    }
    try {
        Assert-DesktopInventoryCondition ($document.RootElement.ValueKind -eq [Text.Json.JsonValueKind]::Object) 'desktop_inventory_shape_invalid'
        Assert-UniqueDesktopJson $document.RootElement
    } finally { $document.Dispose() }
    return ($Text | ConvertFrom-Json -Depth 30)
}

function Assert-DesktopPlainPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while (-not [string]::IsNullOrEmpty($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        Assert-DesktopInventoryCondition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'desktop_inventory_reparse_rejected'
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -ceq $current) { break }; $current = $parent
    }
    return
}

function Assert-DesktopInstallInventory {
    param($Inventory, [string]$Version, [string]$InstallerSha256, [string]$SourceCommit)
    Assert-DesktopInventoryShape $Inventory @('schema', 'version', 'source_commit', 'host', 'build_profile', 'installer_asset', 'installer_sha256', 'generation_manifest_sha256', 'files')
    foreach ($key in @('schema', 'version', 'source_commit', 'host', 'build_profile', 'installer_asset', 'installer_sha256', 'generation_manifest_sha256')) { Assert-DesktopInventoryCondition ($Inventory.$key -is [string]) 'desktop_inventory_identity_type_invalid' }
    Assert-DesktopInventoryCondition ($Inventory.schema -ceq 'winsmux-desktop-install-inventory/v1' -and $Inventory.version -ceq $Version -and $Inventory.host -ceq 'x86_64-pc-windows-msvc' -and $Inventory.build_profile -ceq 'release' -and $Inventory.installer_asset -ceq "winsmux_${Version}_x64-setup.exe" -and $InstallerSha256 -cmatch '^[a-f0-9]{64}$' -and $Inventory.installer_sha256 -ceq $InstallerSha256 -and $SourceCommit -cmatch '^[a-f0-9]{40}$' -and $Inventory.source_commit -ceq $SourceCommit -and $Inventory.generation_manifest_sha256 -cmatch '^[a-f0-9]{64}$') 'desktop_inventory_identity_mismatch'
    Assert-DesktopInventoryCondition ($Inventory.files -is [array] -and $Inventory.files.Count -ge 4) 'desktop_inventory_files_missing'
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $previous = ''
    foreach ($row in $Inventory.files) {
        Assert-DesktopInventoryShape $row @('path', 'bytes', 'sha256')
        $relative = [string]$row.path
        Assert-DesktopInventoryCondition ($row.path -is [string] -and $relative -cmatch '^(?:winsmux(?:-workspace-mcp)?\.exe|licenses/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)$' -and @($relative.Split('/') | Where-Object { $_ -in @('.', '..') -or $_.EndsWith('.') -or $_ -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)' }).Count -eq 0 -and $paths.Add($relative)) 'desktop_inventory_path_invalid'
        Assert-DesktopInventoryCondition (($row.bytes -is [long] -or $row.bytes -is [int]) -and $row.bytes -gt 0 -and $row.bytes -le 9007199254740991 -and $row.sha256 -is [string] -and $row.sha256 -cmatch '^[a-f0-9]{64}$') 'desktop_inventory_file_identity_invalid'
        Assert-DesktopInventoryCondition ([string]::IsNullOrEmpty($previous) -or [StringComparer]::Ordinal.Compare($previous, $relative) -lt 0) 'desktop_inventory_order_invalid'
        $previous = $relative
    }
    foreach ($required in @('winsmux.exe', 'winsmux-workspace-mcp.exe', 'licenses/manifest.json', 'licenses/THIRD_PARTY_NOTICES.txt')) {
        Assert-DesktopInventoryCondition $paths.Contains($required) 'desktop_inventory_required_file_missing'
    }
    return $Inventory
}

function New-DesktopInstallInventory {
    param([string]$RepositoryRoot, [string]$InstallerPath, [string]$OutputPath)
    $repo = [IO.Path]::GetFullPath($RepositoryRoot)
    $version = [IO.File]::ReadAllText((Join-Path $repo 'VERSION')).Trim()
    Assert-DesktopPlainPath $InstallerPath
    Assert-DesktopInventoryCondition ((Split-Path -Leaf $InstallerPath) -ceq "winsmux_${version}_x64-setup.exe") 'desktop_inventory_installer_name_invalid'
    $sourceCommit = (& git -C $repo rev-parse HEAD | Out-String).Trim().ToLowerInvariant()
    Assert-DesktopInventoryCondition ($LASTEXITCODE -eq 0) 'desktop_inventory_source_unavailable'
    $manifestPath = Join-Path $repo 'winsmux-app/src-tauri/binaries/distribution-manifest.json'
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $rustcOutput = & rustc -vV
    Assert-DesktopInventoryCondition ($LASTEXITCODE -eq 0) 'desktop_inventory_toolchain_unavailable'
    $rustcCommit = [string](@($rustcOutput | Where-Object { $_ -cmatch '^commit-hash: [a-f0-9]{40}$' }) -replace '^commit-hash: ', '')
    $validator = @'
import {pathToFileURL} from 'node:url';
const [repo,version,rustcCommit,expectedHash]=process.argv.slice(1);
const {assertCanonicalBundledDistribution}=await import(pathToFileURL(repo+'/scripts/stage-bundled-distribution.mjs'));
const proof=assertCanonicalBundledDistribution({repoRoot:repo,host:'x86_64-pc-windows-msvc',version,rustcCommit,projectOutput:repo+'/target/release'});
if(proof.manifest_sha256!==expectedHash)throw Error('Generation changed during inventory creation.');
'@
    & node --input-type=module -e $validator $repo $version $rustcCommit $manifestHash
    Assert-DesktopInventoryCondition ($LASTEXITCODE -eq 0) 'desktop_inventory_generation_unverified'
    $manifest = Read-DesktopStrictJson $manifestPath
    Assert-DesktopInventoryCondition ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $manifestHash -and $manifest.build_profile -ceq 'release' -and $manifest.version -ceq $version) 'desktop_inventory_generation_changed'
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($row in $manifest.files) {
        $relative = [string]$row.path
        if ($relative -ceq 'winsmux-x86_64-pc-windows-msvc.exe') { $relative = 'winsmux.exe' }
        elseif ($relative -ceq 'winsmux-workspace-mcp-x86_64-pc-windows-msvc.exe') { $relative = 'winsmux-workspace-mcp.exe' }
        elseif (-not $relative.StartsWith('licenses/', [StringComparison]::Ordinal)) { continue }
        $rows.Add([ordered]@{ path = $relative; bytes = [long]$row.bytes; sha256 = [string]$row.sha256 })
    }
    # Explicit ordinal ordering is independent of the runner's locale.
    $byPath = @{}; foreach ($row in $rows) { $byPath[$row.path] = $row }
    $orderedPaths = [string[]]@($byPath.Keys); [Array]::Sort($orderedPaths, [StringComparer]::Ordinal)
    $installerHash = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $inventory = [ordered]@{ schema = 'winsmux-desktop-install-inventory/v1'; version = $version; source_commit = $sourceCommit; host = 'x86_64-pc-windows-msvc'; build_profile = 'release'; installer_asset = "winsmux_${version}_x64-setup.exe"; installer_sha256 = $installerHash; generation_manifest_sha256 = $manifestHash; files = @($orderedPaths | ForEach-Object { $byPath[$_] }) }
    Assert-DesktopInstallInventory $inventory $version $installerHash $sourceCommit | Out-Null
    Assert-DesktopInventoryCondition (-not (Test-Path -LiteralPath $OutputPath)) 'desktop_inventory_output_exists'
    $outputBytes = [Text.UTF8Encoding]::new($false).GetBytes(($inventory | ConvertTo-Json -Depth 12) + "`n")
    $stream = [IO.FileStream]::new([IO.Path]::GetFullPath($OutputPath), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($outputBytes); $stream.Flush($true) } finally { $stream.Dispose() }
    Assert-DesktopInstallInventory (Read-DesktopStrictJson $OutputPath) $version $installerHash $sourceCommit | Out-Null
    return $OutputPath
}

function Get-DesktopInstalledInventory {
    param([string]$InstallRoot, $Inventory, [string]$InventorySha256)
    Assert-DesktopPlainPath $InstallRoot
    $actual = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expectedDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $Inventory.files) {
        $parts = $row.path.Split('/')
        for ($i = 1; $i -lt $parts.Length; $i++) { [void]$expectedDirectories.Add(($parts[0..($i - 1)] -join '/')) }
    }
    $directories = [Collections.Generic.Queue[string]]::new(); $directories.Enqueue([IO.Path]::GetFullPath($InstallRoot))
    while ($directories.Count -gt 0) {
        foreach ($entry in Get-ChildItem -LiteralPath $directories.Dequeue() -Force) {
            Assert-DesktopInventoryCondition (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'desktop_installed_reparse_rejected'
            $relative = [IO.Path]::GetRelativePath($InstallRoot, $entry.FullName).Replace('\', '/')
            if ($entry.PSIsContainer) {
                Assert-DesktopInventoryCondition $expectedDirectories.Contains($relative) 'desktop_installed_directory_mixed'
                $directories.Enqueue($entry.FullName); continue
            }
            if ($relative -cin @('winsmux-app.exe', 'uninstall.exe')) { continue }
            Assert-DesktopInventoryCondition $actual.Add($relative) 'desktop_installed_path_collision'
        }
    }
    Assert-DesktopInventoryCondition ($actual.Count -eq $Inventory.files.Count) 'desktop_installed_inventory_mixed'
    foreach ($row in $Inventory.files) {
        Assert-DesktopInventoryCondition $actual.Contains([string]$row.path) 'desktop_installed_file_missing'
        $path = Join-Path $InstallRoot $row.path; $file = Get-Item -LiteralPath $path -Force
        Assert-DesktopInventoryCondition ($file.Length -eq $row.bytes -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $row.sha256) 'desktop_installed_file_identity_mismatch'
    }
    return [ordered]@{ schema = 'winsmux-desktop-installed-inventory/v1'; installer_sha256 = $Inventory.installer_sha256; inventory_sha256 = $InventorySha256; generation_manifest_sha256 = $Inventory.generation_manifest_sha256; source_commit = $Inventory.source_commit; expected = $Inventory.files.Count; found = $actual.Count; sha256_match = $actual.Count; licenses = @($Inventory.files | Where-Object { $_.path.StartsWith('licenses/', [StringComparison]::Ordinal) }).Count; pair_verified = $true; complete = $true }
}

function Assert-DesktopInstallReceipt {
    param($Receipt, [string]$Version, [string]$InstallerSha256, [string]$SourceCommit, [string]$InventorySha256 = '')
    Assert-DesktopInventoryShape $Receipt @('ok', 'surface', 'version', 'release_tag', 'repository', 'evidence', 'attempts', 'retry_delay_seconds', 'cleanup', 'installed_inventory', 'desktop_runtime')
    Assert-DesktopInventoryShape $Receipt.evidence @('asset', 'sha256', 'version', 'page_url')
    Assert-DesktopInventoryCondition ($Receipt.ok -is [bool]) 'desktop_receipt_identity_type_invalid'
    foreach ($key in @('surface','version','release_tag','repository','cleanup')) { Assert-DesktopInventoryCondition ($Receipt.$key -is [string]) 'desktop_receipt_identity_type_invalid' }
    foreach ($key in @('asset','sha256','version','page_url')) { Assert-DesktopInventoryCondition ($Receipt.evidence.$key -is [string]) 'desktop_receipt_identity_type_invalid' }
    Assert-DesktopInventoryCondition ($Receipt.ok -eq $true -and $Receipt.surface -ceq 'Desktop' -and $Receipt.version -ceq $Version -and $Receipt.release_tag -ceq "v$Version" -and $Receipt.cleanup -ceq 'clean' -and $Receipt.evidence.version -ceq $Version -and $Receipt.evidence.asset -ceq "winsmux_${Version}_x64-setup.exe" -and $Receipt.evidence.sha256 -ceq $InstallerSha256 -and $Receipt.evidence.page_url -match '^(?:tauri://localhost|https?://tauri\.localhost)/?$') 'desktop_receipt_identity_invalid'
    $inventory = $Receipt.installed_inventory
    Assert-DesktopInventoryShape $inventory @('schema', 'installer_sha256', 'inventory_sha256', 'generation_manifest_sha256', 'source_commit', 'expected', 'found', 'sha256_match', 'licenses', 'pair_verified', 'complete')
    foreach ($key in @('expected','found','sha256_match','licenses')) { Assert-DesktopInventoryCondition (($inventory.$key -is [int] -or $inventory.$key -is [long]) -and $inventory.$key -ge 0) 'desktop_receipt_inventory_type_invalid' }
    foreach ($key in @('pair_verified','complete')) { Assert-DesktopInventoryCondition ($inventory.$key -is [bool]) 'desktop_receipt_inventory_type_invalid' }
    Assert-DesktopInventoryCondition ($inventory.schema -ceq 'winsmux-desktop-installed-inventory/v1' -and $inventory.installer_sha256 -ceq $InstallerSha256 -and $inventory.source_commit -ceq $SourceCommit -and $inventory.inventory_sha256 -cmatch '^[a-f0-9]{64}$' -and ([string]::IsNullOrEmpty($InventorySha256) -or $inventory.inventory_sha256 -ceq $InventorySha256) -and $inventory.generation_manifest_sha256 -cmatch '^[a-f0-9]{64}$' -and $inventory.expected -ge 4 -and $inventory.found -eq $inventory.expected -and $inventory.sha256_match -eq $inventory.expected -and $inventory.licenses -eq ($inventory.expected - 2) -and $inventory.pair_verified -eq $true -and $inventory.complete -eq $true) 'desktop_receipt_inventory_invalid'
    Assert-DesktopInventoryShape $Receipt.desktop_runtime @('workspace_read_verified', 'mcp_roundtrip_verified', 'mcp_eof_exit_verified', 'normal_close_requested', 'owned_processes_exited')
    foreach ($key in @('workspace_read_verified', 'mcp_roundtrip_verified', 'mcp_eof_exit_verified', 'normal_close_requested', 'owned_processes_exited')) {
        Assert-DesktopInventoryCondition ($Receipt.desktop_runtime.$key -is [bool] -and $Receipt.desktop_runtime.$key -eq $true) 'desktop_receipt_runtime_unconfirmed'
    }
    return $true
}
