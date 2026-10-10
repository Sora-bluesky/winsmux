#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false, $true)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false, $true)
try {
    $request = ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd()) -AsHashtable
    $expectedKeys = @('archive', 'archive_sha256', 'executable_sha256', 'version', 'asset', 'target')
    if ($request -isnot [Collections.IDictionary] -or $request.Count -ne $expectedKeys.Count) { throw 'Invalid packet' }
    foreach ($key in $expectedKeys) {
        if (-not $request.Contains($key) -or $request[$key] -isnot [string]) { throw 'Invalid packet' }
    }
    $sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'
    $sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
    $source = [Text.UTF8Encoding]::new($false, $true).GetString($sourceBytes)
    if ($source.Length -eq 0 -or $source[0] -eq [char]0xfeff) { throw 'Invalid consumer encoding' }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Invalid consumer syntax' }
    foreach ($name in @('Get-WinsmuxBytesSha256', 'ConvertFrom-StrictWinsmuxJsonBytes',
        'Assert-WinsmuxLicenseObjectKeys', 'Assert-WinsmuxLicenseMemberPath', 'Read-WinsmuxLicenseSidecar')) {
        $definitions = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ieq $name }, $true))
        if ($definitions.Count -ne 1 -or $definitions[0].Name -cne $name) { throw 'Ambiguous consumer function' }
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $archive = [Convert]::FromBase64String($request.archive)
    $proof = Read-WinsmuxLicenseSidecar -ArchiveBytes $archive -ArchiveSha256 $request.archive_sha256 `
        -Version $request.version -ReleaseTag ('v' + $request.version) -AssetName $request.asset `
        -Target $request.target -ExecutableSha256 $request.executable_sha256
    [ordered]@{schema='core-sidecar-consumer-validation/v1'; accepted=$true;
        consumer_source_sha256=(Get-WinsmuxBytesSha256 $sourceBytes);
        archive_sha256=$proof.ArchiveSha256; files=$proof.Files.Count} | ConvertTo-Json -Compress
} catch {
    # No payload, private input or source code is reflected into failure output.
    [Console]::Error.WriteLine('Core sidecar consumer validation refused.')
    exit 1
}
