$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = (Get-Location).Path
$sourcePath = Join-Path $repo 'install.ps1'
$source = [IO.File]::ReadAllText($sourcePath, [Text.UTF8Encoding]::new($false, $true))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Product installer syntax is invalid.' }
foreach ($name in @('Get-WinsmuxBytesSha256', 'Get-WinsmuxExecutingInstallerSource', 'ConvertTo-WinsmuxLifecycleBytes', 'Get-WinsmuxBinaryVersionFromReleaseTag')) {
    $definition = @($ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name
    })
    if ($definition.Count -ne 1) { throw 'Product function is ambiguous.' }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
$root = Join-Path $repo ('.evidence/workspace-package/lifecycle-source-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$cases = [Collections.Generic.List[object]]::new()
function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Run-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $cases.Add(@{ name = $Name; passed = $true }) }
    catch { $cases.Add(@{ name = $Name; passed = $false; error = $_.Exception.Message }) }
}
$versionStatement = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$VERSION'
})[0]
$literal = $versionStatement.Right.Expression.Extent
Run-Case 'packaging-revision-keeps-native-version' {
    $version = Get-WinsmuxBinaryVersionFromReleaseTag 'v0.38.0.1'
    Assert-True ($version -ceq '0.38.0') 'Packaging revision leaked into the binary version.'
    $actual = [Text.UTF8Encoding]::new($false, $true).GetString((ConvertTo-WinsmuxLifecycleBytes $source $version))
    Assert-True ($actual -ceq $source) 'Packaging revision changed the current consumer beyond its native version.'
}
foreach ($version in @('0.38.0', '0.36.28', '0.36.29-preview.1')) {
    Run-Case ('version-only-' + $version) {
        $actual = [Text.UTF8Encoding]::new($false, $true).GetString((ConvertTo-WinsmuxLifecycleBytes $source $version))
        $expected = $source.Substring(0, $literal.StartOffset) + '"' + $version + '"' + $source.Substring($literal.EndOffset)
        Assert-True ($actual -ceq $expected) 'Bytes outside the VERSION literal changed.'
        $check = [Management.Automation.Language.Parser]::ParseInput($actual, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) 'Transformed source is invalid.'
    }
}
$badBodies = [ordered]@{
    partial = 'function Get-WinsmuxExecutingInstallerSource { return "fragment" }'
    missingVersion = $source.Remove($versionStatement.Extent.StartOffset, $versionStatement.Extent.EndOffset - $versionStatement.Extent.StartOffset)
    duplicateVersion = $source.Insert($versionStatement.Extent.StartOffset, '$VERSION="0.1.0"' + "`n")
    scopedVersion = $source.Insert($versionStatement.Extent.StartOffset, '$script:VERSION="0.1.0"' + "`n")
    computedVersion = $source.Substring(0, $literal.StartOffset) + '("0.38." + "0")' + $source.Substring($literal.EndOffset)
    missingMain = $source.Substring(0, $ast.EndBlock.Statements[-1].Extent.StartOffset)
    missingPairedPublisher = $source.Replace('function Publish-WinsmuxLifecycle {', 'function Unsupported-Publisher {')
    oldBootstrapMain = $source.Replace('"install"   { Invoke-Install }', '"install"   { Invoke-TargetInstallerBootstrap }')
    duplicateFunction = $source.Insert($ast.EndBlock.Statements[-1].Extent.StartOffset, 'function open-winsmuxinstalllease { }' + "`n")
    nullByte = $source + [char]0
}
foreach ($bodyCaseKey in $badBodies.Keys) {
    Run-Case ('reject-' + $bodyCaseKey) {
        $badSource = $badBodies[$bodyCaseKey]
        Assert-True (-not [string]::IsNullOrWhiteSpace($badSource)) 'Negative proof lost its actual input.'
        $refused = $false
        try { [void](ConvertTo-WinsmuxLifecycleBytes $badSource '0.38.0') } catch { $refused = $true }
        Assert-True $refused 'Incomplete or ambiguous source was accepted.'
    }
}
foreach ($version in @('0.38.0.1', '0.38.0";exit', 'v0.38.0', '0.38')) {
    Run-Case ('reject-version-' + ($version -replace '[^A-Za-z0-9.-]', '_')) {
        $refused = $false
        try { [void](ConvertTo-WinsmuxLifecycleBytes $source $version) } catch { $refused = $true }
        Assert-True $refused 'Invalid binary version was accepted.'
    }
}
# Run the real whole source in child PowerShell processes. Only the default
# action is changed to help and a diagnostic footer is appended: no installer,
# network, user PATH, profile, or OS mutation is executed by this capture proof.
$fixture = $source.Replace('[string]$Action = "install"', '[string]$Action = "help"') + @'

$captured = Get-WinsmuxExecutingInstallerSource
Write-Output (ConvertTo-Json @{ captured_sha256 = Get-WinsmuxBytesSha256 ([Text.UTF8Encoding]::new($false).GetBytes($captured)); characters = $captured.Length } -Compress)
'@
$fixturePath = Join-Path $root 'capture.ps1'
[IO.File]::WriteAllText($fixturePath, $fixture, [Text.UTF8Encoding]::new($false))
$fixtureHash = Get-WinsmuxBytesSha256 ([Text.UTF8Encoding]::new($false).GetBytes($fixture))
foreach ($mode in @('saved', 'piped')) {
    Run-Case ('actual-body-capture-' + $mode) {
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        foreach ($key in @('GITHUB_ACTIONS', 'WINSMUX_INSTALL_E2E', 'WINSMUX_INSTALL_STATE_ROOT', 'WINSMUX_INSTALL_SOURCE_REF')) {
            [void]$start.Environment.Remove($key)
        }
        foreach ($argument in @('-NoLogo', '-NoProfile')) { $start.ArgumentList.Add($argument) }
        if ($mode -eq 'saved') {
            $start.ArgumentList.Add('-File'); $start.ArgumentList.Add($fixturePath)
        } else {
            $start.ArgumentList.Add('-Command')
            $start.ArgumentList.Add("Get-Content -LiteralPath '" + $fixturePath.Replace("'", "''") + "' -Raw | Invoke-Expression")
        }
        $process = [Diagnostics.Process]::Start($start)
        $outTask = $process.StandardOutput.ReadToEndAsync(); $errTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $outTask.GetAwaiter().GetResult(); $stderr = $errTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $root ($mode + '-stdout.txt')), $stdout, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root ($mode + '-stderr.txt')), $stderr, [Text.UTF8Encoding]::new($false))
        Assert-True ($process.ExitCode -eq 0) ('Capture process failed: ' + $stderr)
        $last = @($stdout.TrimEnd() -split '\r?\n')[-1] | ConvertFrom-Json
        Assert-True ($last.captured_sha256 -ceq $fixtureHash -and $last.characters -eq $fixture.Length) 'Captured body differs from the actual complete executing input.'
    }
}
$result = @{ schema = 'winsmux-lifecycle-source-proof/v1'; installer_sha256 = (Get-FileHash $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant();
    fixture_sha256 = $fixtureHash; completed = (@($cases | Where-Object { -not $_.passed }).Count -eq 0);
    passed = @($cases | Where-Object passed).Count; failed = @($cases | Where-Object { -not $_.passed }).Count;
    scope = 'Whole executing-body capture and VERSION-only transform; no lifecycle publication or product adoption'; cases = $cases.ToArray() }
[IO.File]::WriteAllText((Join-Path $root 'result.json'), (ConvertTo-Json $result -Depth 10) + "`n", [Text.UTF8Encoding]::new($false))
Write-Output (ConvertTo-Json @{ root = $root; passed = $result.passed; failed = $result.failed } -Compress)
if (-not $result.completed) { exit 1 }
