#Requires -Version 7.0
# TASK-810 behavioral contract suite (architecture-reset v03631).
# Normative: reset04 §5.2 identity multiset; reset07 choke-point B full-scalar executor;
# Find/P02/Test.Path dynamic proofs; late P-rows via fake-Pester module fixture driving product runner envelopes. Drafted from normative docs (not prior candidate bodies).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'TASK-810 Pester runner contract' {
    BeforeAll {
        $script:RepoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($script:RepoRoot)) { throw 'Failed to resolve repository root.' }

        $script:ModulePath = Join-Path $script:RepoRoot 'scripts/winsmux-pester.psm1'
        $script:RunnerPath = Join-Path $script:RepoRoot 'scripts/run-pester-shard.ps1'
        $script:WorkflowPath = Join-Path $script:RepoRoot '.github/workflows/test.yml'
        $script:RunTestsPath = Join-Path $script:RepoRoot 'scripts/run-tests.ps1'
        $script:ExactPesterManifest = 'C:\Users\sorab\Documents\PowerShell\Modules\Pester\5.7.1\Pester.psd1'

        $script:WorkflowText = Get-Content -LiteralPath $script:WorkflowPath -Raw -Encoding utf8
        $script:RunTestsText = Get-Content -LiteralPath $script:RunTestsPath -Raw -Encoding utf8

        $script:Task810IdentityLedger = @(
            'product-unmodified RED boundary'
            'registry export'
            'arbitrary primitive strings'
            'P02 replacement and restoration'
            'resolver shape'
            'Pester Test.Path identity'
            'workflow raw-byte extraction'
            'full Matrix/Desktop scalar requirement'
            'Find boundary case null'
            'Find boundary case int32'
            'Find boundary case pscustomobject'
            'Find boundary case custom-tostring'
            'Find boundary case object-array-empty'
            'Find boundary case object-array-one'
            'Find boundary case object-array-two'
            'Find boundary case empty-string'
            'Find boundary case registered-string'
            'P00'; 'P01'; 'P02'; 'P03'; 'P04'; 'P05'; 'P06'; 'P07'; 'P08'; 'P09'; 'P10'
            'P11'; 'P12'; 'P13'; 'P14'; 'P15'; 'P16'; 'P17'; 'P18'; 'P19'; 'P20'
            'A0T0B0'; 'A1T0B0'; 'A0T1B0'; 'A0T0B1'; 'A1T1B0'; 'A1T0B1'; 'A0T1B1'; 'A1T1B1'
            'decision:C00'; 'decision:C01'; 'decision:C02'; 'decision:C03'
            'decision:C04'
            'decision:C05'
            'decision:C06'
            'decision:C07'
            'decision:C08'
            'decision:C09'
            'decision:C10'
            'decision:C11'
            'decision:C12'
            'decision:C13'
            'kernel:C00'
            'kernel:C01'
            'kernel:C02'
            'kernel:C03'
            'kernel:C04'
            'kernel:C05'
            'kernel:C06'
            'kernel:C07'
            'kernel:C08'
            'kernel:C09'
            'kernel:C10'
            'kernel:C11'
            'kernel:C12'
            'kernel:C13'
            'Matrix:C07'
            'Matrix:C00'
            'Matrix:C05'
            'Desktop:C07'
            'Desktop:C00'
            'Desktop:C05'
        )

        $script:Task810RequiredExports = @(
            'Find-WinsmuxPesterShardMatch'
            'Get-WinsmuxPesterShardRegistry'
            'Resolve-WinsmuxPester571'
        )

        $script:RootExpectedKeys = @(
            'schema_version', 'shard_id', 'resolution_status', 'execution_status', 'test_outcome',
            'failure_origin', 'workflow_action', 'pester_invoked', 'result_file', 'error_code', 'selected_module'
        )
        $script:ModuleExpectedKeys = @('present', 'name', 'semantic_version', 'manifest_path')

        if (-not ('Task810CustomToString' -as [type])) {
            Add-Type -TypeDefinition @'
public class Task810CustomToString {
    public override string ToString() { return "bridge-foundation"; }
}
'@
        }

        if (-not ('Task810FixtureHost' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;

public sealed class Task810FixtureHost : PSHost {
    private readonly Guid _id = Guid.NewGuid();
    private readonly Task810FixtureHostUserInterface _ui = new Task810FixtureHostUserInterface();
    public readonly List<int> ExitCodes = new List<int>();
    public override CultureInfo CurrentCulture { get { return CultureInfo.InvariantCulture; } }
    public override CultureInfo CurrentUICulture { get { return CultureInfo.InvariantCulture; } }
    public override Guid InstanceId { get { return _id; } }
    public override string Name { get { return "Task810FixtureHost"; } }
    public override PSHostUserInterface UI { get { return _ui; } }
    public override Version Version { get { return new Version(1, 0); } }
    public override void EnterNestedPrompt() { }
    public override void ExitNestedPrompt() { }
    public override void NotifyBeginApplication() { }
    public override void NotifyEndApplication() { }
    public override void SetShouldExit(int exitCode) { ExitCodes.Add(exitCode); }
}

public sealed class Task810FixtureHostUserInterface : PSHostUserInterface {
    public override PSHostRawUserInterface RawUI { get { return null; } }
    public override Dictionary<string, PSObject> Prompt(string caption, string message, System.Collections.ObjectModel.Collection<FieldDescription> descriptions) { return null; }
    public override int PromptForChoice(string caption, string message, System.Collections.ObjectModel.Collection<ChoiceDescription> choices, int defaultChoice) { return defaultChoice; }
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) { return null; }
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options) { return null; }
    public override string ReadLine() { return string.Empty; }
    public override System.Security.SecureString ReadLineAsSecureString() { return new System.Security.SecureString(); }
    public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) { }
    public override void Write(string value) { }
    public override void WriteDebugLine(string message) { }
    public override void WriteErrorLine(string value) { }
    public override void WriteLine(string value) { }
    public override void WriteProgress(long sourceId, ProgressRecord record) { }
    public override void WriteVerboseLine(string message) { }
    public override void WriteWarningLine(string message) { }
}
'@
        }

        
        function script:Assert-Task810BindingValidationThrow {
            param([Parameter(Mandatory)][scriptblock]$Script)
            $threw = $false
            $typeName = ''
            try {
                & $Script
            } catch {
                $threw = $true
                $ex = $_.Exception
                while ($null -ne $ex.InnerException) {
                    if ($ex.GetType().FullName -match 'ParameterBindingValidationException|ValidationMetadataException') { break }
                    $ex = $ex.InnerException
                }
                $typeName = $ex.GetType().FullName
            }
            $threw | Should -BeTrue -Because 'Find must reject distinguishable non-string arguments'
            ($typeName -match 'ParameterBindingValidationException|ValidationMetadataException') | Should -BeTrue -Because ("expected binder validation exception, got $typeName")
        }

        function script:New-Task810FindArgumentCase {
            param([Parameter(Mandatory)][string]$CaseName)
            switch ($CaseName) {
                'null' { return [pscustomobject]@{ case_name = $CaseName; argument = $null; pre_call_type = 'null'; should_throw = $true } }
                'int32' {
                    $a = [int]0
                    return [pscustomobject]@{ case_name = $CaseName; argument = $a; pre_call_type = $a.GetType().FullName; should_throw = $true }
                }
                'pscustomobject' {
                    $a = [pscustomobject]@{ x = 1 }
                    return [pscustomobject]@{ case_name = $CaseName; argument = $a; pre_call_type = $a.GetType().FullName; should_throw = $true }
                }
                'custom-tostring' {
                    $a = [Task810CustomToString]::new()
                    return [pscustomobject]@{ case_name = $CaseName; argument = $a; pre_call_type = $a.GetType().FullName; should_throw = $true }
                }
                'object-array-empty' {
                    $a = [object[]]@()
                    return [pscustomobject]@{ case_name = $CaseName; argument = $a; pre_call_type = $a.GetType().FullName; should_throw = $true }
                }
                'object-array-one' {
                    $a = [object[]]@('bridge-foundation')
                    return [pscustomobject]@{ case_name = $CaseName; argument = $a; pre_call_type = $a.GetType().FullName; should_throw = $true }
                }
                'object-array-two' {
                    $a = [object[]]@('a', 'b')
                    return [pscustomobject]@{ case_name = $CaseName; argument = $a; pre_call_type = $a.GetType().FullName; should_throw = $true }
                }
                'empty-string' {
                    $a = [string]''
                    return [pscustomobject]@{ case_name = $CaseName; argument = $a; pre_call_type = $a.GetType().FullName; should_throw = $false }
                }
                'registered-string' {
                    $a = [string]'bridge-foundation'
                    return [pscustomobject]@{ case_name = $CaseName; argument = $a; pre_call_type = $a.GetType().FullName; should_throw = $false }
                }
                default { throw "unknown Find case: $CaseName" }
            }
        }

        function script:Assert-Task810EnvelopeShape {
            param($Envelope)
            $names = @($Envelope.PSObject.Properties.Name)
            $names | Should -Be $script:RootExpectedKeys -Because 'compact envelope root keys/order'
            $modNames = @($Envelope.selected_module.PSObject.Properties.Name)
            $modNames | Should -Be $script:ModuleExpectedKeys -Because 'selected_module keys/order'
            $Envelope.schema_version | Should -BeOfType ([string])
            $Envelope.pester_invoked | Should -BeOfType ([bool])
            $Envelope.selected_module.present | Should -BeOfType ([bool])
        }

        function script:Invoke-Task810RunnerEnvelope {
            param(
                [Parameter(Mandatory)][AllowEmptyString()][string]$ShardId,
                [string]$WorkingDirectory = $script:RepoRoot
            )
            Push-Location -LiteralPath $WorkingDirectory
            try {
                $raw = @(& $script:RunnerPath -ShardId $ShardId)
            } finally {
                Pop-Location
            }
            $raw.Count | Should -Be 1 -Because 'runner emits exactly one success-stream value'
            $raw[0] | Should -BeOfType ([string])
            ([string]$raw[0]).Contains([char]10) | Should -BeFalse
            ([string]$raw[0]).Contains([char]13) | Should -BeFalse
            $envObj = $raw[0] | ConvertFrom-Json -ErrorAction Stop
            Assert-Task810EnvelopeShape -Envelope $envObj
            return $envObj
        }

        function script:Get-Task810FailureOriginFromProduct {
            param($PesterResult)
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("task810-origin-" + [guid]::NewGuid().ToString('n') + '.ps1')
            $text = Get-Content -LiteralPath $script:RunnerPath -Raw -Encoding utf8
            if ($text -notmatch '(?s)(function Get-Task810FailureOrigin\s*\{.*?\n\})') {
                throw 'Get-Task810FailureOrigin not found in runner'
            }
            $fn = $Matches[1]
            Set-Content -LiteralPath $tmp -Value ($fn + "`nGet-Task810FailureOrigin -PesterResult `$args[0]`n") -Encoding utf8
            try {
                return & $tmp $PesterResult
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }

        function script:New-Task810SyntheticFailedTest {
            param(
                [bool]$ShouldRun = $true,
                [bool]$Executed = $true,
                [string[]]$ErrorIds = @()
            )
            $errors = [System.Collections.Generic.List[object]]::new()
            foreach ($id in $ErrorIds) {
                $errors.Add([pscustomobject]@{ FullyQualifiedErrorId = [string]$id }) | Out-Null
            }
            return [pscustomobject]@{
                ShouldRun   = [bool]$ShouldRun
                Executed    = [bool]$Executed
                ErrorRecord = @($errors.ToArray())
            }
        }

        function script:Install-Task810P02RegistryReplacement {
            param([Parameter(Mandatory)]$Module)
            $original = & $Module { ${function:Get-WinsmuxPesterShardRegistry} }
            $rows = @(Get-WinsmuxPesterShardRegistry | ForEach-Object {
                    if ($_.job_kind -eq 'matrix') {
                        [pscustomobject][ordered]@{
                            ordinal = [int]$_.ordinal; shard_id = [string]$_.shard_id; job_kind = [string]$_.job_kind
                            timeout_minutes = [int]$_.timeout_minutes; test_paths = [string[]]@($_.test_paths)
                            selector_identity = [string]$_.selector_identity; result_file = [string]$_.result_file
                        }
                    } else {
                        [pscustomobject][ordered]@{
                            ordinal = [int]$_.ordinal; shard_id = [string]$_.shard_id; job_kind = [string]$_.job_kind
                            test_paths = [string[]]@($_.test_paths); selector_identity = [string]$_.selector_identity
                            result_file = [string]$_.result_file
                        }
                    }
                })
            if ($rows.Count -lt 2) { throw 'registry too small for P02 duplicate fixture' }
            $rows[1].shard_id = 'BRIDGE-FOUNDATION'
            & $Module {
                param($fixtureRows)
                $script:task810P02Rows = @($fixtureRows)
                $script:task810P02ReplacementReached = 0
                Set-Item -LiteralPath 'Function:script:Get-WinsmuxPesterShardRegistry' -Value {
                    $script:task810P02ReplacementReached = [int]$script:task810P02ReplacementReached + 1
                    $copy = [System.Collections.Generic.List[object]]::new()
                    foreach ($r in @($script:task810P02Rows)) { $copy.Add($r) | Out-Null }
                    return $copy.ToArray()
                }
            } $rows
            return [pscustomobject]@{ Module = $Module; Original = $original }
        }

        function script:Restore-Task810P02RegistryReplacement {
            param([Parameter(Mandatory)]$State)
            & $State.Module {
                param($original)
                Set-Item -LiteralPath 'Function:script:Get-WinsmuxPesterShardRegistry' -Value $original
                Remove-Variable -Name task810P02Rows -Scope Script -ErrorAction SilentlyContinue
                Remove-Variable -Name task810P02ReplacementReached -Scope Script -ErrorAction SilentlyContinue
            } $State.Original
        }

        function script:Get-Task810P02ReachCount {
            param([Parameter(Mandatory)]$Module)
            return & $Module { [int]$script:task810P02ReplacementReached }
        }

        function script:Install-Task810ResolveReplacement {
            param(
                [Parameter(Mandatory)]$Module,
                [Parameter(Mandatory)][scriptblock]$Replacement
            )
            $original = & $Module { ${function:Resolve-WinsmuxPester571} }
            & $Module {
                param($sb)
                Set-Item -LiteralPath 'Function:script:Resolve-WinsmuxPester571' -Value $sb
            } $Replacement
            return [pscustomobject]@{ Module = $Module; Original = $original }
        }

        function script:Install-Task810ResolveStatusFixture {
            param(
                [Parameter(Mandatory)]$Module,
                [Parameter(Mandatory)][string]$Status,
                [string]$ManifestPath = ''
            )
            $original = & $Module { ${function:Resolve-WinsmuxPester571} }
            & $Module {
                param($st, $mp)
                $script:task810ResolveStatusFixture = [string]$st
                $script:task810ResolveManifestFixture = [string]$mp
                Set-Item -LiteralPath 'Function:script:Resolve-WinsmuxPester571' -Value {
                    $st = [string]$script:task810ResolveStatusFixture
                    if ($st -ceq 'resolved') {
                        return [pscustomobject][ordered]@{
                            resolution_status = 'resolved'
                            manifest_path     = [string]$script:task810ResolveManifestFixture
                            name              = 'Pester'
                            semantic_version  = '5.7.1'
                            module_base       = [string]([System.IO.Path]::GetDirectoryName([string]$script:task810ResolveManifestFixture))
                        }
                    }
                    return [pscustomobject][ordered]@{
                        resolution_status = $st
                        manifest_path     = ''
                        name              = ''
                        semantic_version  = ''
                        module_base       = ''
                    }
                }
            } $Status $ManifestPath
            return [pscustomobject]@{ Module = $Module; Original = $original }
        }

        function script:Restore-Task810ResolveReplacement {
            param([Parameter(Mandatory)]$State)
            & $State.Module {
                param($original)
                Set-Item -LiteralPath 'Function:script:Resolve-WinsmuxPester571' -Value $original
                Remove-Variable -Name task810ResolveStatusFixture -Scope Script -ErrorAction SilentlyContinue
                Remove-Variable -Name task810ResolveManifestFixture -Scope Script -ErrorAction SilentlyContinue
            } $State.Original
        }

        function script:Invoke-Task810IdentityControlRunspace {
            param(
                [Parameter(Mandatory)][string]$ManifestPath,
                [Parameter(Mandatory)][string]$ControlPath
            )
            $fixtureHost = [Task810FixtureHost]::new()
            $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            $fixtureRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($fixtureHost, $iss)
            $fixturePowerShell = $null
            try {
                $fixtureRunspace.Open()
                $fixturePowerShell = [PowerShell]::Create()
                $fixturePowerShell.Runspace = $fixtureRunspace
                $null = $fixturePowerShell.AddScript({
                        param($manifest, $control)
                        $imported = Import-Module -Name $manifest -Force -PassThru -ErrorAction Stop
                        $cfg = New-PesterConfiguration
                        $cfg.Run.Path = [string[]]@($control)
                        $cfg.Run.PassThru = $true
                        $cfg.Run.Exit = $false
                        $cfg.Filter.FullName = [string[]]@('*control identity')
                        $result = Invoke-Pester -Configuration $cfg
                        $tests = @($result.Tests | Where-Object { [bool]$_.ShouldRun })
                        if ($tests.Count -eq 0) { $tests = @($result.Tests) }
                        $t = if ($tests.Count -gt 0) { $tests[0] } else { $null }
                        $pathType = ''
                        $segments = @()
                        $joined = ''
                        if ($null -ne $t -and $null -ne $t.Path) {
                            $pathType = $t.Path.GetType().FullName
                            $segments = @($t.Path | ForEach-Object { [string]$_ })
                            $joined = [string]($t.Path -join '.')
                        }
                        $errIds = @()
                        if ($null -ne $t -and $null -ne $t.ErrorRecord) {
                            foreach ($er in @($t.ErrorRecord)) { $errIds += [string]$er.FullyQualifiedErrorId }
                        }
                        $fb = 0; $fc = 0
                        if ($null -ne $result.PSObject.Properties['FailedBlocksCount']) { $fb = [int]$result.FailedBlocksCount }
                        elseif ($null -ne $result.FailedBlocks) { $fb = @($result.FailedBlocks).Count }
                        if ($null -ne $result.PSObject.Properties['FailedContainersCount']) { $fc = [int]$result.FailedContainersCount }
                        elseif ($null -ne $result.FailedContainers) { $fc = @($result.FailedContainers).Count }
                        $payload = [ordered]@{
                            module_name       = [string]$imported.Name
                            module_version    = [string]$imported.Version
                            module_path       = [string]$imported.Path
                            module_base       = [string]$imported.ModuleBase
                            failed_blocks     = [int]$fb
                            failed_containers = [int]$fc
                            test_count        = [int]$tests.Count
                            path_clr_type     = [string]$pathType
                            path_segments     = [string[]]$segments
                            joined_identity   = [string]$joined
                            should_run        = [bool[]]@($tests | ForEach-Object { [bool]$_.ShouldRun })
                            executed          = [bool[]]@($tests | ForEach-Object { [bool]$_.Executed })
                            error_ids         = [string[]]$errIds
                            run_result        = [string]$result.Result
                            test_result       = if ($null -ne $t) { [string]$t.Result } else { '' }
                        }
                        return [string]($payload | ConvertTo-Json -Compress -Depth 5)
                    }).AddArgument($ManifestPath).AddArgument($ControlPath)
                $out = $fixturePowerShell.Invoke()
                if ($fixturePowerShell.HadErrors) {
                    $errs = @($fixturePowerShell.Streams.Error | ForEach-Object { $_.ToString() })
                    throw ("identity runspace failed: " + ($errs -join ' | '))
                }
                if ($out.Count -ne 1) { throw "identity runspace expected 1 object, got $($out.Count)" }
                $json = [string]$out[0]
                $obj = $json | ConvertFrom-Json -ErrorAction Stop
                return [pscustomobject]@{
                    module_name       = [string]$obj.module_name
                    module_version    = [string]$obj.module_version
                    module_path       = [string]$obj.module_path
                    module_base       = [string]$obj.module_base
                    failed_blocks     = [int]$obj.failed_blocks
                    failed_containers = [int]$obj.failed_containers
                    test_count        = [int]$obj.test_count
                    path_clr_type     = [string]$obj.path_clr_type
                    path_segments     = [string[]]@($obj.path_segments)
                    joined_identity   = [string]$obj.joined_identity
                    should_run        = @($obj.should_run | ForEach-Object { [bool]$_ })
                    executed          = @($obj.executed | ForEach-Object { [bool]$_ })
                    error_ids         = [string[]]@($obj.error_ids)
                    run_result        = [string]$obj.run_result
                    test_result       = [string]$obj.test_result
                }
            } finally {
                if ($null -ne $fixturePowerShell) { $fixturePowerShell.Dispose() }
                if ($null -ne $fixtureRunspace) { $fixtureRunspace.Dispose() }
            }
        }
        function script:Get-Task810ExtractedScalars {
            $rx = New-Object System.Text.RegularExpressions.Regex(
                '(?ms)^(?<indent> {10})# TASK810_CONSUMER_KERNEL_BEGIN\r?\n(?<body>.*?)^\k<indent># TASK810_CONSUMER_KERNEL_END\r?$',
                [System.Text.RegularExpressions.RegexOptions]::Multiline
            )
            $ms = $rx.Matches($script:WorkflowText)
            if ($ms.Count -ne 2) { throw "expected 2 kernel marker pairs, got $($ms.Count)" }
            $kernels = @()
            foreach ($m in $ms) {
                $body = $m.Groups['body'].Value
                $deindented = [regex]::Replace($body, '^ {10}', '', 'Multiline')
                $kernels += $deindented
            }
            if (-not [string]::Equals($kernels[0], $kernels[1], [StringComparison]::Ordinal)) {
                throw 'matrix/Desktop deindented kernels are not byte-identical'
            }

            # Full scalars: from shardId assignment through exit (matrix) / through finally+exit (Desktop)
            $matrixFull = @'
$ErrorActionPreference = 'Stop'
$shardId = '__TASK810_SHARD_ID__'
$staticResultPath = '__TASK810_STATIC_RESULT__'
$installUsed = __TASK810_INSTALL_USED__
__TASK810_KERNEL__
if ($null -ne $task810Diagnostic) { Write-Host $task810Diagnostic }
exit $task810ExitCode
'@
            $desktopFull = @'
$ErrorActionPreference = 'Stop'
$shardId = '__TASK810_SHARD_ID__'
$staticResultPath = '__TASK810_STATIC_RESULT__'
$installUsed = __TASK810_INSTALL_USED__
$env:WINSMUX_DBGGATE_APP_EXE = '__TASK810_APP__'
$env:WINSMUX_DBGGATE_PORT = '__TASK810_PORT__'
try {
__TASK810_KERNEL__
} finally {
  Remove-Item Env:WINSMUX_DBGGATE_APP_EXE -ErrorAction SilentlyContinue
  Remove-Item Env:WINSMUX_DBGGATE_PORT -ErrorAction SilentlyContinue
  $script:task810DesktopCleanup = $true
}
if ($null -ne $task810Diagnostic) { Write-Host $task810Diagnostic }
exit $task810ExitCode
'@
            return [pscustomobject]@{
                Kernel     = [string]$kernels[0]
                MatrixFull = [string]$matrixFull
                DesktopFull = [string]$desktopFull
            }
        }

        function script:Invoke-Task810ActualScalar {
            param(
                [Parameter(Mandatory)][ValidateSet('Matrix','Desktop')]$Adapter,
                [Parameter(Mandatory)][string]$ShardId,
                [Parameter(Mandatory)][string]$StaticResultFile,
                [Parameter(Mandatory)][AllowEmptyString()][string]$RunnerStdout,
                [bool]$RunnerThrow = $false,
                [bool]$InstallThrow = $false,
                [bool]$InstallUsedInitial = $false,
                [bool]$DeleteResultAfterFirst = $false,
                [string]$AppPath = 'C:\fixture\winsmux-app.exe',
                [string]$Port = '4242'
            )
            $extracted = Get-Task810ExtractedScalars
            $template = if ($Adapter -eq 'Matrix') { $extracted.MatrixFull } else { $extracted.DesktopFull }
            $installToken = if ($InstallUsedInitial) { '$true' } else { '$false' }
            $scriptText = $template.
                Replace('__TASK810_SHARD_ID__', $ShardId.Replace("'", "''")).
                Replace('__TASK810_STATIC_RESULT__', $StaticResultFile.Replace("'", "''")).
                Replace('__TASK810_KERNEL__', $extracted.Kernel).
                Replace('__TASK810_APP__', $AppPath.Replace("'", "''")).
                Replace('__TASK810_PORT__', $Port.Replace("'", "''")).
                Replace('__TASK810_INSTALL_USED__', $installToken)

            $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('task810-scalar-' + [guid]::NewGuid().ToString('n'))
            New-Item -Path $fixtureRoot -ItemType Directory | Out-Null
            $scriptsDir = Join-Path $fixtureRoot 'scripts'
            New-Item -Path $scriptsDir -ItemType Directory | Out-Null
            $fakeRunner = Join-Path $scriptsDir 'run-pester-shard.ps1'
            $runnerBody = @"
param([AllowEmptyString()][string]`$ShardId)
`$callLog = Join-Path `$PSScriptRoot '..\task810-runner-calls.log'
Add-Content -LiteralPath `$callLog -Value ([string]`$ShardId) -Encoding utf8
if (`$env:TASK810_FIXTURE_RUNNER_THROW -eq '1') { throw 'fixture-runner-throw' }
if (`$env:TASK810_FIXTURE_DELETE_RESULT -eq '1' -and (Test-Path -LiteralPath `$env:TASK810_FIXTURE_RESULT_PATH)) {
  Remove-Item -LiteralPath `$env:TASK810_FIXTURE_RESULT_PATH -Force
}
Write-Output -InputObject ([string]`$env:TASK810_FIXTURE_ENVELOPE)
"@
            Set-Content -LiteralPath $fakeRunner -Value $runnerBody -Encoding utf8

            $events = [System.Collections.Generic.List[string]]::new()
            $fixtureHost = [Task810FixtureHost]::new()
            $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            # Inject Install-Module / gallery commands as session functions
            $installSb = {
                param()
                $script:task810InstallCount = [int]$script:task810InstallCount + 1
                if ($env:TASK810_FIXTURE_INSTALL_THROW -eq '1') { throw 'fixture-install-throw' }
            }.GetNewClosure()
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry 'Install-Module', $installSb.ToString()))
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry 'Get-PSRepository', { param($Name) return [pscustomobject]@{ Name = 'PSGallery' } }.ToString()))
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry 'Register-PSRepository', { param() }.ToString()))
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry 'Set-PSRepository', { param() }.ToString()))

            $fixtureRunspace = [RunspaceFactory]::CreateRunspace($fixtureHost, $iss)
            $fixturePowerShell = $null
            $prevLoc = Get-Location
            try {
                Set-Location -LiteralPath $fixtureRoot
                $fixtureRunspace.Open()
                $fixtureRunspace.SessionStateProxy.Path.SetLocation($fixtureRoot)
                $fixtureRunspace.SessionStateProxy.SetVariable('task810InstallCount', 0)
                $fixtureRunspace.SessionStateProxy.SetVariable('task810RunnerInvocations', @())
                $fixtureRunspace.SessionStateProxy.SetVariable('task810DesktopCleanup', $false)
                
                if ($RunnerThrow) {
                    [Environment]::SetEnvironmentVariable('TASK810_FIXTURE_RUNNER_THROW', '1')
                } else {
                    [Environment]::SetEnvironmentVariable('TASK810_FIXTURE_RUNNER_THROW', '0')
                }
                if ($InstallThrow) {
                    [Environment]::SetEnvironmentVariable('TASK810_FIXTURE_INSTALL_THROW', '1')
                } else {
                    [Environment]::SetEnvironmentVariable('TASK810_FIXTURE_INSTALL_THROW', '0')
                }
                if ($DeleteResultAfterFirst) {
                    [Environment]::SetEnvironmentVariable('TASK810_FIXTURE_DELETE_RESULT', '1')
                } else {
                    [Environment]::SetEnvironmentVariable('TASK810_FIXTURE_DELETE_RESULT', '0')
                }
                [Environment]::SetEnvironmentVariable('TASK810_FIXTURE_ENVELOPE', $RunnerStdout)
                [Environment]::SetEnvironmentVariable('TASK810_FIXTURE_RESULT_PATH', (Join-Path $fixtureRoot $StaticResultFile))

                # Pre-create result file for C07/C09 existence checks when envelope claims file exists
                if ($RunnerStdout -match '"test_outcome":"(passed|failed)"' -and $RunnerStdout -notmatch 'pester_result_file_missing') {
                    Set-Content -LiteralPath (Join-Path $fixtureRoot $StaticResultFile) -Value '<ok/>' -Encoding utf8
                }

                $fixturePowerShell = [PowerShell]::Create()
                $fixturePowerShell.Runspace = $fixtureRunspace
                $null = $fixturePowerShell.AddScript($scriptText)
                $null = $fixturePowerShell.Invoke()
                $errText = @($fixturePowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join ' | '

                $installCount = [int]$fixtureRunspace.SessionStateProxy.GetVariable('task810InstallCount')
                $desktopCleanup = [bool]$fixtureRunspace.SessionStateProxy.GetVariable('task810DesktopCleanup')
                $exitCodes = @($fixtureHost.ExitCodes)
                $callLogPath = Join-Path $fixtureRoot 'task810-runner-calls.log'
                $runnerCalls = 0
                if (Test-Path -LiteralPath $callLogPath) {
                    $runnerCalls = @(Get-Content -LiteralPath $callLogPath -ErrorAction SilentlyContinue).Count
                }

                return [pscustomobject]@{
                    adapter          = [string]$Adapter
                    exit_codes       = [int[]]$exitCodes
                    exit_code        = $(if ($exitCodes.Count -gt 0) { [int]$exitCodes[-1] } else { -1 })
                    install_count    = [int]$installCount
                    runner_calls     = [int]$runnerCalls
                    desktop_cleanup  = [bool]$desktopCleanup
                    error_text       = [string]$errText
                    fixture_root     = [string]$fixtureRoot
                }
            } finally {
                [Environment]::SetEnvironmentVariable('TASK810_FIXTURE_RUNNER_THROW', $null)
                [Environment]::SetEnvironmentVariable('TASK810_FIXTURE_INSTALL_THROW', $null)
                [Environment]::SetEnvironmentVariable('TASK810_FIXTURE_DELETE_RESULT', $null)
                [Environment]::SetEnvironmentVariable('TASK810_FIXTURE_ENVELOPE', $null)
                [Environment]::SetEnvironmentVariable('TASK810_FIXTURE_RESULT_PATH', $null)
                if ($null -ne $fixturePowerShell) { $fixturePowerShell.Dispose() }
                if ($null -ne $fixtureRunspace) { $fixtureRunspace.Dispose() }
                Set-Location -LiteralPath $prevLoc.Path
                Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        function script:New-Task810CanonicalEnvelopeJson {
            param(
                [string]$ShardId = 'bridge-foundation',
                [string]$ResolutionStatus = 'resolved',
                [string]$ExecutionStatus = 'completed',
                [string]$TestOutcome = 'passed',
                [string]$FailureOrigin = 'none',
                [string]$WorkflowAction = 'succeed',
                [bool]$PesterInvoked = $true,
                [string]$ResultFile = 'test-results-bridge-foundation.xml',
                [string]$ErrorCode = 'none',
                [bool]$ModulePresent = $true,
                [string]$ManifestPath = $script:ExactPesterManifest
            )
            $mod = if ($ModulePresent) {
                [ordered]@{ present = $true; name = 'Pester'; semantic_version = '5.7.1'; manifest_path = $ManifestPath }
            } else {
                [ordered]@{ present = $false; name = ''; semantic_version = ''; manifest_path = '' }
            }
            $obj = [pscustomobject][ordered]@{
                schema_version    = '1'
                shard_id          = $ShardId
                resolution_status = $ResolutionStatus
                execution_status  = $ExecutionStatus
                test_outcome      = $TestOutcome
                failure_origin    = $FailureOrigin
                workflow_action   = $WorkflowAction
                pester_invoked    = [bool]$PesterInvoked
                result_file       = $ResultFile
                error_code        = $ErrorCode
                selected_module   = [pscustomobject]$mod
            }
            return ($obj | ConvertTo-Json -Compress -Depth 5)
        }


        function script:Invoke-Task810FakePesterEnvelope {
            param(
                [Parameter(Mandatory)]
                [ValidateSet('invalid', 'passed_no_file', 'passed_with_file', 'failed_no_file', 'failed_with_file', 'invoke_throw', 'invoke_null')]
                [string]$Mode,
                [ValidateSet('assertion', 'test_runtime', 'block_or_container', 'mixed', 'none')]
                [string]$FailureOrigin = 'assertion',
                [string]$ShardId = 'repo-audit-v03619',
                [string]$ResultFile = 'test-results-repo-audit-v03619.xml'
            )

            $realManifest = [string]$script:ExactPesterManifest
            $fx = Join-Path ([System.IO.Path]::GetTempPath()) ('task810-fakepester-' + [guid]::NewGuid().ToString('n'))
            $pesterDir = Join-Path $fx 'Pester'
            $testsDir = Join-Path $fx 'tests'
            New-Item -ItemType Directory -Path $pesterDir -Force | Out-Null
            New-Item -ItemType Directory -Path $testsDir -Force | Out-Null
            $manifest = Join-Path $pesterDir 'Pester.psd1'
            $psm1 = Join-Path $pesterDir 'Pester.psm1'
            $guid = [guid]::NewGuid().ToString()
            @(
                '@{'
                "  RootModule = 'Pester.psm1'"
                "  ModuleVersion = '5.7.1'"
                "  GUID = '$guid'"
                "  FunctionsToExport = @('Invoke-Pester','New-PesterConfiguration')"
                '}'
            ) | Set-Content -LiteralPath $manifest -Encoding utf8

            $failedTestsExpr = switch ($FailureOrigin) {
                'assertion' {
                    '@([pscustomobject]@{ ShouldRun = $true; Executed = $true; ErrorRecord = @([pscustomobject]@{ FullyQualifiedErrorId = ''PesterAssertionFailed'' }) })'
                }
                'test_runtime' {
                    '@([pscustomobject]@{ ShouldRun = $true; Executed = $true; ErrorRecord = @([pscustomobject]@{ FullyQualifiedErrorId = ''NativeCommandError'' }) })'
                }
                'block_or_container' { '@()' }
                'mixed' {
                    '@([pscustomobject]@{ ShouldRun = $true; Executed = $true; ErrorRecord = @([pscustomobject]@{ FullyQualifiedErrorId = ''PesterAssertionFailed'' }, [pscustomobject]@{ FullyQualifiedErrorId = ''NativeCommandError'' }) })'
                }
                default { '@()' }
            }
            $failedBlocksCount = if ($FailureOrigin -in @('block_or_container', 'mixed')) { '1' } else { '0' }
            $failedBlocksExpr = if ($FailureOrigin -in @('block_or_container', 'mixed')) { '@([pscustomobject]@{})' } else { '@()' }
            $failedCountExpr = if ($FailureOrigin -eq 'block_or_container') { '0' } else { '1' }
            if ($FailureOrigin -eq 'none') { $failedCountExpr = '0' }

            $invokeBody = switch ($Mode) {
                'invalid' {
                    @'
    return [pscustomobject]@{
        Result = 'Failed'
        FailedCount = 0
        FailedBlocksCount = 0
        FailedContainersCount = 0
        Failed = @()
        FailedBlocks = @()
        FailedContainers = @()
    }
'@
                }
                'passed_no_file' {
                    @'
    return [pscustomobject]@{
        Result = 'Passed'
        FailedCount = 0
        FailedBlocksCount = 0
        FailedContainersCount = 0
        Failed = @()
        FailedBlocks = @()
        FailedContainers = @()
    }
'@
                }
                'passed_with_file' {
                    @'
    $out = [string]$Configuration.TestResult.OutputPath
    if (-not [string]::IsNullOrWhiteSpace($out)) {
        Set-Content -LiteralPath $out -Value '<test-results/>' -Encoding utf8
    }
    return [pscustomobject]@{
        Result = 'Passed'
        FailedCount = 0
        FailedBlocksCount = 0
        FailedContainersCount = 0
        Failed = @()
        FailedBlocks = @()
        FailedContainers = @()
    }
'@
                }
                'failed_no_file' {
                    @"
    return [pscustomobject]@{
        Result = 'Failed'
        FailedCount = $failedCountExpr
        FailedBlocksCount = $failedBlocksCount
        FailedContainersCount = 0
        Failed = $failedTestsExpr
        FailedBlocks = $failedBlocksExpr
        FailedContainers = @()
    }
"@
                }
                'failed_with_file' {
                    @"
    `$out = [string]`$Configuration.TestResult.OutputPath
    if (-not [string]::IsNullOrWhiteSpace(`$out)) {
        Set-Content -LiteralPath `$out -Value '<test-results/>' -Encoding utf8
    }
    return [pscustomobject]@{
        Result = 'Failed'
        FailedCount = $failedCountExpr
        FailedBlocksCount = $failedBlocksCount
        FailedContainersCount = 0
        Failed = $failedTestsExpr
        FailedBlocks = $failedBlocksExpr
        FailedContainers = @()
    }
"@
                }
                'invoke_throw' {
                    @'
    throw 'task810-fake-invoke-throw'
'@
                }
                'invoke_null' {
                    @'
    return $null
'@
                }
            }

            $psm1Text = @"
function New-PesterConfiguration {
    return [pscustomobject]@{
        Run = [pscustomobject]@{ Path = `$null; PassThru = `$false; Exit = `$false }
        Output = [pscustomobject]@{ Verbosity = 'Normal' }
        TestResult = [pscustomobject]@{ Enabled = `$false; OutputPath = ''; OutputFormat = '' }
        Filter = [pscustomobject]@{ FullName = `$null }
    }
}
function Invoke-Pester {
    param(`$Configuration)
$invokeBody
}
Export-ModuleMember -Function New-PesterConfiguration, Invoke-Pester
"@
            Set-Content -LiteralPath $psm1 -Value $psm1Text -Encoding utf8
            Set-Content -LiteralPath (Join-Path $testsDir 'Pass.Tests.ps1') -Value "Describe 't' { It 'x' { `$true | Should -BeTrue } }" -Encoding utf8

            $mod = Get-Module -Name 'winsmux-pester' -ErrorAction Stop
            $origResolve = & $mod { ${function:Resolve-WinsmuxPester571} }
            $origReg = & $mod { ${function:Get-WinsmuxPesterShardRegistry} }
            & $mod {
                param($mp, $mb, $sid, $rf)
                $script:task810FakeResolveManifest = [string]$mp
                $script:task810FakeResolveBase = [string]$mb
                $script:task810FakeShardId = [string]$sid
                $script:task810FakeResultFile = [string]$rf
                Set-Item -LiteralPath 'Function:script:Resolve-WinsmuxPester571' -Value {
                    return [pscustomobject][ordered]@{
                        resolution_status = 'resolved'
                        manifest_path     = [string]$script:task810FakeResolveManifest
                        name              = 'Pester'
                        semantic_version  = '5.7.1'
                        module_base       = [string]$script:task810FakeResolveBase
                    }
                }
                Set-Item -LiteralPath 'Function:script:Get-WinsmuxPesterShardRegistry' -Value {
                    ,([pscustomobject][ordered]@{
                            ordinal           = 1
                            shard_id          = [string]$script:task810FakeShardId
                            job_kind          = 'matrix'
                            timeout_minutes   = 12
                            test_paths        = [string[]]@('tests/Pass.Tests.ps1')
                            selector_identity = ''
                            result_file       = [string]$script:task810FakeResultFile
                        })
                }
            } $manifest $pesterDir $ShardId $ResultFile

            try {
                $e = Invoke-Task810RunnerEnvelope -ShardId $ShardId -WorkingDirectory $fx
                return $e
            }
            finally {
                & $mod {
                    param($resolveOriginal, $regOriginal)
                    Set-Item -LiteralPath 'Function:script:Resolve-WinsmuxPester571' -Value $resolveOriginal
                    Set-Item -LiteralPath 'Function:script:Get-WinsmuxPesterShardRegistry' -Value $regOriginal
                    Remove-Variable -Name task810FakeResolveManifest -Scope Script -ErrorAction SilentlyContinue
                    Remove-Variable -Name task810FakeResolveBase -Scope Script -ErrorAction SilentlyContinue
                    Remove-Variable -Name task810FakeShardId -Scope Script -ErrorAction SilentlyContinue
                    Remove-Variable -Name task810FakeResultFile -Scope Script -ErrorAction SilentlyContinue
                } $origResolve $origReg
                Get-Module -Name 'Pester' -ErrorAction SilentlyContinue | Remove-Module -Force -ErrorAction SilentlyContinue
                Import-Module -Name $realManifest -Force -ErrorAction Stop | Out-Null
                Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        $script:Module = Import-Module -Name $script:ModulePath -Force -PassThru -ErrorAction Stop
    }

    Context 'allowlist publication and retained singletons' {
        It 'product-unmodified RED boundary' {
            $ledger = @($script:Task810IdentityLedger)
            $ledger.Count | Should -Be 80
            ($ledger | Select-Object -Unique).Count | Should -Be 80
            (Test-Path -LiteralPath $script:ModulePath) | Should -BeTrue
            (Test-Path -LiteralPath $script:RunnerPath) | Should -BeTrue
        }

        It 'registry export' {
            $exports = @($script:Module.ExportedCommands.Keys | Sort-Object)
            $exports | Should -Be ($script:Task810RequiredExports | Sort-Object)
            $reg = @(Get-WinsmuxPesterShardRegistry)
            $reg.Count | Should -Be 26
        }

        It 'arbitrary primitive strings' {
            $r1 = Find-WinsmuxPesterShardMatch -ShardId 'not-a-registered-shard-xyz'
            $r1.caller_shard_id | Should -BeExactly 'not-a-registered-shard-xyz'
            $r1.match_count | Should -Be 0
            $r2 = Find-WinsmuxPesterShardMatch -ShardId ("`t multibyte-日本語 `n")
            $r2.caller_shard_id | Should -BeExactly ("`t multibyte-日本語 `n")
            $r2.match_count | Should -Be 0
        }

        It 'P02 replacement and restoration' -Tag 'TASK810-Sentinel' {
            $mod = Get-Module -Name 'winsmux-pester'
            $mod | Should -Not -BeNullOrEmpty
            $state = $null
            try {
                $state = Install-Task810P02RegistryReplacement -Module $mod
                (Get-Task810P02ReachCount -Module $mod) | Should -Be 0
                $find = Find-WinsmuxPesterShardMatch -ShardId 'bridge-foundation'
                $find.match_count | Should -Be 2
                (Get-Task810P02ReachCount -Module $mod) | Should -Be 1
                $envObj = Invoke-Task810RunnerEnvelope -ShardId 'bridge-foundation'
                $envObj.resolution_status | Should -Be 'duplicate'
                $envObj.error_code | Should -Be 'shard_registry_duplicate'
                $envObj.execution_status | Should -Be 'not_started'
                $envObj.pester_invoked | Should -BeFalse
                (Get-Task810P02ReachCount -Module $mod) | Should -Be 2
            } finally {
                if ($null -ne $state) { Restore-Task810P02RegistryReplacement -State $state }
            }
            $same = Get-Module -Name 'winsmux-pester'
            [object]::ReferenceEquals($same, $mod) | Should -BeTrue
            $exports = @($same.ExportedCommands.Keys | Sort-Object)
            $exports | Should -Be ($script:Task810RequiredExports | Sort-Object)
            $after = Find-WinsmuxPesterShardMatch -ShardId 'bridge-foundation'
            $after.match_count | Should -Be 1
        }

        It 'resolver shape' {
            $resolve = Resolve-WinsmuxPester571
            $resolve.resolution_status | Should -Be 'resolved'
            $resolve.name | Should -Be 'Pester'
            $resolve.semantic_version | Should -Be '5.7.1'
            $resolve.manifest_path | Should -Not -BeNullOrEmpty
            (Test-Path -LiteralPath ([string]$resolve.manifest_path) -PathType Leaf) | Should -BeTrue
            [System.IO.Path]::GetFileName([string]$resolve.manifest_path) | Should -Be 'Pester.psd1'
            $full = [System.IO.Path]::GetFullPath([string]$resolve.manifest_path)
            $full.ToLowerInvariant().Contains('\pester\5.7.1\pester.psd1') | Should -BeTrue
        }

        It 'Pester Test.Path identity' -Tag 'TASK810-Sentinel' {
            $resolve = Resolve-WinsmuxPester571
            $resolve.resolution_status | Should -Be 'resolved'
            $controlDir = Join-Path ([System.IO.Path]::GetTempPath()) ('task810-id-' + [guid]::NewGuid().ToString('n'))
            New-Item -Path $controlDir -ItemType Directory | Out-Null
            $controlPath = Join-Path $controlDir 'Control.Tests.ps1'
            @(
                "Describe 'control' {"
                "    It 'control identity' { 1 | Should -Be 2 }"
                "}"
            ) -join "`n" | Set-Content -LiteralPath $controlPath -Encoding utf8
            try {
                $proj = Invoke-Task810IdentityControlRunspace -ManifestPath ([string]$resolve.manifest_path) -ControlPath $controlPath
                $proj.module_name | Should -Be 'Pester'
                $proj.module_version | Should -Be '5.7.1'
                $proj.failed_blocks | Should -Be 0
                $proj.failed_containers | Should -Be 0
                $proj.test_count | Should -Be 1
                ($proj.path_clr_type -match 'List' -or $proj.path_clr_type -match 'String') | Should -BeTrue -Because ("Path CLR type was $($proj.path_clr_type)")
                $proj.joined_identity | Should -Match 'control identity'
                @($proj.should_run) | Should -Contain $true
                @($proj.executed) | Should -Contain $true
                if (@($proj.error_ids).Count -gt 0) {
                    @($proj.error_ids) | Should -Contain 'PesterAssertionFailed'
                } else {
                    $proj.test_result | Should -Be 'Failed'
                    $proj.run_result | Should -Be 'Failed'
                }
            } finally {
                Remove-Item -LiteralPath $controlDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'workflow raw-byte extraction' {
            $ex = Get-Task810ExtractedScalars
            $ex.Kernel.Length | Should -BeGreaterThan 1000
            $ex.Kernel | Should -Match 'Get-Task810ConsumerDecision'
            $ex.Kernel | Should -Match 'Test-Task810OrdinalStringSequence'
            $ex.MatrixFull | Should -Match '__TASK810_KERNEL__'
            $ex.DesktopFull | Should -Match 'WINSMUX_DBGGATE'
        }

        It 'full Matrix/Desktop scalar requirement' {
            $script:RunTestsText | Should -Match 'Resolve-WinsmuxPester571'
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ResultFile 'test-results-bridge-foundation.xml'
            $m = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $m.exit_code | Should -Be 0
            $m.install_count | Should -Be 0
            $m.runner_calls | Should -Be 1
            $d = Invoke-Task810ActualScalar -Adapter Desktop -ShardId 'desktop-debug-process' -StaticResultFile 'test-results-desktop-debug-v03630.xml' -RunnerStdout (
                New-Task810CanonicalEnvelopeJson -ShardId 'desktop-debug-process' -ResultFile 'test-results-desktop-debug-v03630.xml'
            )
            $d.exit_code | Should -Be 0
            $d.desktop_cleanup | Should -BeTrue
            $d.exit_codes.Count | Should -Be 1
        }
    }

    Context 'module Find boundary cases' {
        It 'Find boundary case null' -Tag 'TASK810-Sentinel' {
            $h = New-Task810FindArgumentCase -CaseName 'null'
            $h.pre_call_type | Should -Be 'null'
            Assert-Task810BindingValidationThrow -Script { Find-WinsmuxPesterShardMatch -ShardId $h.argument }
        }
        It 'Find boundary case int32' -Tag 'TASK810-Sentinel' {
            $h = New-Task810FindArgumentCase -CaseName 'int32'
            $h.pre_call_type | Should -Be 'System.Int32'
            Assert-Task810BindingValidationThrow -Script { Find-WinsmuxPesterShardMatch -ShardId $h.argument }
        }
        It 'Find boundary case pscustomobject' -Tag 'TASK810-Sentinel' {
            $h = New-Task810FindArgumentCase -CaseName 'pscustomobject'
            $h.pre_call_type | Should -Match 'PSCustomObject|PSObject'
            Assert-Task810BindingValidationThrow -Script { Find-WinsmuxPesterShardMatch -ShardId $h.argument }
        }
        It 'Find boundary case custom-tostring' -Tag 'TASK810-Sentinel' {
            $h = New-Task810FindArgumentCase -CaseName 'custom-tostring'
            $h.pre_call_type | Should -Be 'Task810CustomToString'
            Assert-Task810BindingValidationThrow -Script { Find-WinsmuxPesterShardMatch -ShardId $h.argument }
        }
        It 'Find boundary case object-array-empty' -Tag 'TASK810-Sentinel' {
            $h = New-Task810FindArgumentCase -CaseName 'object-array-empty'
            $h.pre_call_type | Should -Be 'System.Object[]'
            Assert-Task810BindingValidationThrow -Script { Find-WinsmuxPesterShardMatch -ShardId $h.argument }
        }
        It 'Find boundary case object-array-one' -Tag 'TASK810-Sentinel' {
            $h = New-Task810FindArgumentCase -CaseName 'object-array-one'
            $h.pre_call_type | Should -Be 'System.Object[]'
            Assert-Task810BindingValidationThrow -Script { Find-WinsmuxPesterShardMatch -ShardId $h.argument }
        }
        It 'Find boundary case object-array-two' -Tag 'TASK810-Sentinel' {
            $h = New-Task810FindArgumentCase -CaseName 'object-array-two'
            $h.pre_call_type | Should -Be 'System.Object[]'
            Assert-Task810BindingValidationThrow -Script { Find-WinsmuxPesterShardMatch -ShardId $h.argument }
        }
        It 'Find boundary case empty-string' -Tag 'TASK810-Sentinel' {
            $h = New-Task810FindArgumentCase -CaseName 'empty-string'
            $h.pre_call_type | Should -Be 'System.String'
            $r = Find-WinsmuxPesterShardMatch -ShardId $h.argument
            $r.caller_shard_id | Should -BeExactly ''
            $r.match_count | Should -Be 0
        }
        It 'Find boundary case registered-string' -Tag 'TASK810-Sentinel' {
            $h = New-Task810FindArgumentCase -CaseName 'registered-string'
            $h.pre_call_type | Should -Be 'System.String'
            $r = Find-WinsmuxPesterShardMatch -ShardId $h.argument
            $r.caller_shard_id | Should -BeExactly 'bridge-foundation'
            $r.match_count | Should -Be 1
            $r.matches[0].shard_id | Should -Be 'bridge-foundation'
        }
    }

    Context 'runner producer rows' {
        It 'P00' {
            $e = Invoke-Task810RunnerEnvelope -ShardId 'definitely-not-registered-810'
            $e.shard_id | Should -BeExactly 'definitely-not-registered-810'
            $e.resolution_status | Should -Be 'unknown'
            $e.execution_status | Should -Be 'not_started'
            $e.test_outcome | Should -Be 'not_run'
            $e.failure_origin | Should -Be 'none'
            $e.workflow_action | Should -Be 'fail'
            $e.pester_invoked | Should -BeFalse
            $e.result_file | Should -BeExactly ''
            $e.error_code | Should -Be 'shard_id_unknown'
            $e.selected_module.present | Should -BeFalse
        }
        It 'P01' {
            $e = Invoke-Task810RunnerEnvelope -ShardId ''
            $e.shard_id | Should -BeExactly ''
            $e.resolution_status | Should -Be 'empty'
            $e.error_code | Should -Be 'shard_id_empty'
            $e.pester_invoked | Should -BeFalse
            $e.selected_module.present | Should -BeFalse
        }
        It 'P02' {
            $mod = Get-Module winsmux-pester
            $state = Install-Task810P02RegistryReplacement -Module $mod
            try {
                $e = Invoke-Task810RunnerEnvelope -ShardId 'bridge-foundation'
                $e.resolution_status | Should -Be 'duplicate'
                $e.error_code | Should -Be 'shard_registry_duplicate'
                $e.pester_invoked | Should -BeFalse
            } finally {
                Restore-Task810P02RegistryReplacement -State $state
            }
        }
        It 'P03' {
            $rf = 'test-results-repo-audit-v03619.xml'
            $path = Join-Path $script:RepoRoot $rf
            $created = $false
            if (-not (Test-Path -LiteralPath $path)) {
                Set-Content -LiteralPath $path -Value '<preexisting/>' -Encoding utf8
                $created = $true
            }
            try {
                $e = Invoke-Task810RunnerEnvelope -ShardId 'repo-audit-v03619'
                $e.resolution_status | Should -Be 'artifact_conflict'
                $e.error_code | Should -Be 'preexisting_result_file'
                $e.result_file | Should -Be $rf
                $e.pester_invoked | Should -BeFalse
                $e.selected_module.present | Should -BeFalse
            } finally {
                if ($created) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
        }
        It 'P04' {
            $mod = Get-Module winsmux-pester
            $rf = Join-Path $script:RepoRoot 'test-results-repo-audit-v03619.xml'
            if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $rf -Force }
            $state = Install-Task810ResolveStatusFixture -Module $mod -Status 'missing'
            try {
                $e = Invoke-Task810RunnerEnvelope -ShardId 'repo-audit-v03619'
                $e.resolution_status | Should -Be 'missing'
                $e.workflow_action | Should -Be 'install_once_then_rerun'
                $e.error_code | Should -Be 'pester_5_7_1_missing'
                $e.result_file | Should -Be 'test-results-repo-audit-v03619.xml'
                $e.pester_invoked | Should -BeFalse
                $e.selected_module.present | Should -BeFalse
            } finally {
                Restore-Task810ResolveReplacement -State $state
                if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue }
            }
        }
        It 'P05' {
            $mod = Get-Module winsmux-pester
            $rf = Join-Path $script:RepoRoot 'test-results-repo-audit-v03619.xml'
            if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $rf -Force }
            $state = Install-Task810ResolveStatusFixture -Module $mod -Status 'ambiguous'
            try {
                $e = Invoke-Task810RunnerEnvelope -ShardId 'repo-audit-v03619'
                $e.resolution_status | Should -Be 'ambiguous'
                $e.error_code | Should -Be 'pester_5_7_1_ambiguous'
                $e.workflow_action | Should -Be 'fail'
                $e.pester_invoked | Should -BeFalse
            } finally {
                Restore-Task810ResolveReplacement -State $state
                if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue }
            }
        }
        It 'P06' {
            $mod = Get-Module winsmux-pester
            $rf = Join-Path $script:RepoRoot 'test-results-repo-audit-v03619.xml'
            if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $rf -Force }
            $state = Install-Task810ResolveStatusFixture -Module $mod -Status 'runtime_failure'
            try {
                $e = Invoke-Task810RunnerEnvelope -ShardId 'repo-audit-v03619'
                $e.resolution_status | Should -Be 'runtime_failure'
                $e.error_code | Should -Be 'resolver_runtime_failure'
                $e.pester_invoked | Should -BeFalse
            } finally {
                Restore-Task810ResolveReplacement -State $state
                if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue }
            }
        }
        It 'P07' {
            $mod = Get-Module winsmux-pester
            $rf = Join-Path $script:RepoRoot 'test-results-repo-audit-v03619.xml'
            if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $rf -Force }
            $bad = Join-Path ([System.IO.Path]::GetTempPath()) ('not-pester-' + [guid]::NewGuid().ToString('n') + '.psd1')
            Set-Content -LiteralPath $bad -Value '@{ ModuleVersion = "0.0.0" }' -Encoding utf8
            $state = Install-Task810ResolveStatusFixture -Module $mod -Status 'resolved' -ManifestPath $bad
            try {
                $e = Invoke-Task810RunnerEnvelope -ShardId 'repo-audit-v03619'
                $e.resolution_status | Should -Be 'resolved'
                $e.error_code | Should -Be 'pester_import_failure'
                $e.pester_invoked | Should -BeFalse
                $e.selected_module.present | Should -BeTrue
            } finally {
                Restore-Task810ResolveReplacement -State $state
                Remove-Item -LiteralPath $bad -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue }
            }
        }
        It 'P08' {
            # Configuration failure: registry row points at missing test path under a temp cwd with module/runner copies.
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('task810-p08-' + [guid]::NewGuid().ToString('n'))
            New-Item -Path (Join-Path $root 'scripts') -ItemType Directory | Out-Null
            Copy-Item -LiteralPath $script:ModulePath -Destination (Join-Path $root 'scripts/winsmux-pester.psm1')
            Copy-Item -LiteralPath $script:RunnerPath -Destination (Join-Path $root 'scripts/run-pester-shard.ps1')
            # Import product module in this session already; invoke runner from fixture root so missing test path triggers config failure after resolve+import.
            # Use real registered shard but missing relative test file in fixture root.
            try {
                $e = Invoke-Task810RunnerEnvelope -ShardId 'repo-audit-v03619' -WorkingDirectory $root
                $e.resolution_status | Should -Be 'resolved'
                $e.error_code | Should -Be 'pester_configuration_failure'
                $e.pester_invoked | Should -BeFalse
                $e.selected_module.present | Should -BeTrue
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        It 'P09' {
            $e = Invoke-Task810FakePesterEnvelope -Mode invoke_throw
            $e.resolution_status | Should -Be 'resolved'
            $e.execution_status | Should -Be 'not_started'
            $e.test_outcome | Should -Be 'not_run'
            $e.failure_origin | Should -Be 'none'
            $e.workflow_action | Should -Be 'fail'
            $e.pester_invoked | Should -BeTrue
            $e.error_code | Should -Be 'pester_runtime_failure'
            $e.selected_module.present | Should -BeTrue
            $e.result_file | Should -Be 'test-results-repo-audit-v03619.xml'
        }
        It 'P10' {
            $e = Invoke-Task810FakePesterEnvelope -Mode invalid
            $e.resolution_status | Should -Be 'resolved'
            $e.execution_status | Should -Be 'completed'
            $e.test_outcome | Should -Be 'not_run'
            $e.failure_origin | Should -Be 'none'
            $e.workflow_action | Should -Be 'fail'
            $e.pester_invoked | Should -BeTrue
            $e.error_code | Should -Be 'pester_result_invalid'
            $e.selected_module.present | Should -BeTrue
            $e.selected_module.semantic_version | Should -Be '5.7.1'
            $e.result_file | Should -Be 'test-results-repo-audit-v03619.xml'
        }
        It 'P11' {
            $e = Invoke-Task810FakePesterEnvelope -Mode passed_no_file
            $e.resolution_status | Should -Be 'resolved'
            $e.execution_status | Should -Be 'completed'
            $e.test_outcome | Should -Be 'passed'
            $e.failure_origin | Should -Be 'none'
            $e.workflow_action | Should -Be 'fail'
            $e.pester_invoked | Should -BeTrue
            $e.error_code | Should -Be 'pester_result_file_missing'
            $e.selected_module.present | Should -BeTrue
            $e.result_file | Should -Be 'test-results-repo-audit-v03619.xml'
        }
        It 'P12' {
            $e = Invoke-Task810FakePesterEnvelope -Mode failed_no_file -FailureOrigin assertion
            $e.resolution_status | Should -Be 'resolved'
            $e.execution_status | Should -Be 'completed'
            $e.test_outcome | Should -Be 'failed'
            $e.failure_origin | Should -Be 'assertion'
            $e.workflow_action | Should -Be 'fail'
            $e.pester_invoked | Should -BeTrue
            $e.error_code | Should -Be 'pester_result_file_missing'
            $e.selected_module.present | Should -BeTrue
        }
        It 'P13' {
            $e = Invoke-Task810FakePesterEnvelope -Mode failed_no_file -FailureOrigin test_runtime
            $e.test_outcome | Should -Be 'failed'
            $e.failure_origin | Should -Be 'test_runtime'
            $e.error_code | Should -Be 'pester_result_file_missing'
            $e.pester_invoked | Should -BeTrue
            $e.workflow_action | Should -Be 'fail'
        }
        It 'P14' {
            $e = Invoke-Task810FakePesterEnvelope -Mode failed_no_file -FailureOrigin block_or_container
            $e.test_outcome | Should -Be 'failed'
            $e.failure_origin | Should -Be 'block_or_container'
            $e.error_code | Should -Be 'pester_result_file_missing'
            $e.pester_invoked | Should -BeTrue
        }
        It 'P15' {
            $e = Invoke-Task810FakePesterEnvelope -Mode failed_no_file -FailureOrigin mixed
            $e.test_outcome | Should -Be 'failed'
            $e.failure_origin | Should -Be 'mixed'
            $e.error_code | Should -Be 'pester_result_file_missing'
            $e.pester_invoked | Should -BeTrue
        }
        It 'P16' {
            $e = Invoke-Task810FakePesterEnvelope -Mode passed_with_file
            $e.resolution_status | Should -Be 'resolved'
            $e.execution_status | Should -Be 'completed'
            $e.test_outcome | Should -Be 'passed'
            $e.failure_origin | Should -Be 'none'
            $e.workflow_action | Should -Be 'succeed'
            $e.pester_invoked | Should -BeTrue
            $e.error_code | Should -Be 'none'
            $e.selected_module.present | Should -BeTrue
            $e.selected_module.semantic_version | Should -Be '5.7.1'
            $e.result_file | Should -Be 'test-results-repo-audit-v03619.xml'
        }
        It 'P17' {
            $e = Invoke-Task810FakePesterEnvelope -Mode failed_with_file -FailureOrigin assertion
            $e.test_outcome | Should -Be 'failed'
            $e.failure_origin | Should -Be 'assertion'
            $e.error_code | Should -Be 'pester_tests_failed'
            $e.workflow_action | Should -Be 'fail'
            $e.pester_invoked | Should -BeTrue
            $e.selected_module.present | Should -BeTrue
        }
        It 'P18' {
            $e = Invoke-Task810FakePesterEnvelope -Mode failed_with_file -FailureOrigin test_runtime
            $e.test_outcome | Should -Be 'failed'
            $e.failure_origin | Should -Be 'test_runtime'
            $e.error_code | Should -Be 'pester_tests_failed'
            $e.pester_invoked | Should -BeTrue
        }
        It 'P19' {
            $e = Invoke-Task810FakePesterEnvelope -Mode failed_with_file -FailureOrigin block_or_container
            $e.test_outcome | Should -Be 'failed'
            $e.failure_origin | Should -Be 'block_or_container'
            $e.error_code | Should -Be 'pester_tests_failed'
            $e.pester_invoked | Should -BeTrue
        }
        It 'P20' {
            $e = Invoke-Task810FakePesterEnvelope -Mode failed_with_file -FailureOrigin mixed
            $e.test_outcome | Should -Be 'failed'
            $e.failure_origin | Should -Be 'mixed'
            $e.error_code | Should -Be 'pester_tests_failed'
            $e.pester_invoked | Should -BeTrue
        }
    }

    Context 'failure-origin truth table' {
        # Authority proposal §6 defines the A/T/B classifier truth table on returned Pester result objects.
        # These rows prove Get-Task810FailureOrigin product bytes on synthetics (accepted classifier surface).
        # Full runner envelopes for failed origins are covered by producer rows P12-P15 / P17-P20 above.

        It 'A0T0B0' {
            $pr = [pscustomobject]@{ Failed=@(); FailedBlocksCount=0; FailedContainersCount=0; FailedBlocks=@(); FailedContainers=@() }
            (Get-Task810FailureOriginFromProduct -PesterResult $pr) | Should -Be 'none'
        }
        It 'A1T0B0' {
            $t = New-Task810SyntheticFailedTest -ErrorIds @('PesterAssertionFailed')
            $pr = [pscustomobject]@{ Failed=@($t); FailedBlocksCount=0; FailedContainersCount=0; FailedBlocks=@(); FailedContainers=@() }
            (Get-Task810FailureOriginFromProduct -PesterResult $pr) | Should -Be 'assertion'
        }
        It 'A0T1B0' {
            $t = New-Task810SyntheticFailedTest -ErrorIds @('RuntimeX')
            $pr = [pscustomobject]@{ Failed=@($t); FailedBlocksCount=0; FailedContainersCount=0; FailedBlocks=@(); FailedContainers=@() }
            (Get-Task810FailureOriginFromProduct -PesterResult $pr) | Should -Be 'test_runtime'
        }
        It 'A0T0B1' {
            $pr = [pscustomobject]@{ Failed=@(); FailedBlocksCount=1; FailedContainersCount=0; FailedBlocks=@([pscustomobject]@{}); FailedContainers=@() }
            (Get-Task810FailureOriginFromProduct -PesterResult $pr) | Should -Be 'block_or_container'
        }
        It 'A1T1B0' {
            $t = New-Task810SyntheticFailedTest -ErrorIds @('PesterAssertionFailed', 'RuntimeX')
            $pr = [pscustomobject]@{ Failed=@($t); FailedBlocksCount=0; FailedContainersCount=0; FailedBlocks=@(); FailedContainers=@() }
            (Get-Task810FailureOriginFromProduct -PesterResult $pr) | Should -Be 'mixed'
        }
        It 'A1T0B1' {
            $t = New-Task810SyntheticFailedTest -ErrorIds @('PesterAssertionFailed')
            $pr = [pscustomobject]@{ Failed=@($t); FailedBlocksCount=1; FailedContainersCount=0; FailedBlocks=@([pscustomobject]@{}); FailedContainers=@() }
            (Get-Task810FailureOriginFromProduct -PesterResult $pr) | Should -Be 'mixed'
        }
        It 'A0T1B1' {
            $t = New-Task810SyntheticFailedTest -ErrorIds @('RuntimeX')
            $pr = [pscustomobject]@{ Failed=@($t); FailedBlocksCount=0; FailedContainersCount=1; FailedBlocks=@(); FailedContainers=@([pscustomobject]@{}) }
            (Get-Task810FailureOriginFromProduct -PesterResult $pr) | Should -Be 'mixed'
        }
        It 'A1T1B1' {
            $t = New-Task810SyntheticFailedTest -ErrorIds @('PesterAssertionFailed', 'RuntimeX')
            $pr = [pscustomobject]@{ Failed=@($t); FailedBlocksCount=1; FailedContainersCount=1; FailedBlocks=@([pscustomobject]@{}); FailedContainers=@([pscustomobject]@{}) }
            (Get-Task810FailureOriginFromProduct -PesterResult $pr) | Should -Be 'mixed'
        }
    }

    Context 'consumer decision rows' {
        It 'decision:C00' {
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout '{}' -RunnerThrow:$true
            $r.exit_code | Should -Be 2
            $r.install_count | Should -Be 0
        }
        It 'decision:C01' {
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout 'not-json'
            $r.exit_code | Should -Be 2
            $r.install_count | Should -Be 0
        }
        It 'decision:C02' {
            $bad = '{"schema_version":"1"}'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $bad
            $r.exit_code | Should -Be 2
            $r.install_count | Should -Be 0
        }
        It 'decision:C03' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'other-id' -ResultFile 'test-results-bridge-foundation.xml'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 2
            $r.install_count | Should -Be 0
        }
        It 'decision:C04' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ResolutionStatus 'missing' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'install_once_then_rerun' -PesterInvoked:$false -ResultFile 'test-results-bridge-foundation.xml' -ErrorCode 'pester_5_7_1_missing' -ModulePresent:$false
            # After install, fake runner returns same P04 again -> C06 terminal; first decision is C04 path (install+rerun).
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.install_count | Should -Be 1
            $r.runner_calls | Should -Be 2
            $r.exit_code | Should -Be 2
        }
        It 'decision:C05' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ResolutionStatus 'missing' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'install_once_then_rerun' -PesterInvoked:$false -ResultFile 'test-results-bridge-foundation.xml' -ErrorCode 'pester_5_7_1_missing' -ModulePresent:$false
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json -InstallThrow:$true
            $r.exit_code | Should -Be 2
            $r.install_count | Should -Be 1
        }
        It 'decision:C06' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ResolutionStatus 'missing' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'install_once_then_rerun' -PesterInvoked:$false -ResultFile 'test-results-bridge-foundation.xml' -ErrorCode 'pester_5_7_1_missing' -ModulePresent:$false
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json -InstallUsedInitial:$true
            $r.exit_code | Should -Be 2
            $r.install_count | Should -Be 0
            $r.runner_calls | Should -Be 1
        }
        It 'decision:C07' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ResultFile 'test-results-bridge-foundation.xml'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 0
            $r.install_count | Should -Be 0
        }
        It 'decision:C08' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ResultFile 'test-results-bridge-foundation.xml'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json -DeleteResultAfterFirst:$true
            $r.exit_code | Should -Be 2
        }
        It 'decision:C09' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -TestOutcome 'failed' -FailureOrigin 'assertion' -WorkflowAction 'fail' -ErrorCode 'pester_tests_failed' -ResultFile 'test-results-bridge-foundation.xml'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 1
        }
        It 'decision:C10' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -TestOutcome 'failed' -FailureOrigin 'assertion' -WorkflowAction 'fail' -ErrorCode 'pester_tests_failed' -ResultFile 'test-results-bridge-foundation.xml'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json -DeleteResultAfterFirst:$true
            $r.exit_code | Should -Be 2
        }
        It 'decision:C11' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -TestOutcome 'passed' -FailureOrigin 'none' -WorkflowAction 'fail' -ErrorCode 'pester_result_file_missing' -ResultFile 'test-results-bridge-foundation.xml'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 2
            $r.install_count | Should -Be 0
        }
        It 'decision:C12' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ResolutionStatus 'unknown' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$false -ResultFile '' -ErrorCode 'shard_id_unknown' -ModulePresent:$false
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 2
            $r.install_count | Should -Be 0
        }
        It 'decision:C13' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$true -ErrorCode 'pester_runtime_failure' -ResultFile 'test-results-bridge-foundation.xml'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 2
        }
    }

    Context 'extracted-kernel rows' {
        It 'kernel:C00' {
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout '{}' -RunnerThrow:$true
            $r.exit_code | Should -Be 2
            $r.runner_calls | Should -Be 1
        }
        It 'kernel:C01' {
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout ''
            $r.exit_code | Should -Be 2
        }
        It 'kernel:C02' {
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout '{"schema_version":1,"shard_id":"x"}'
            $r.exit_code | Should -Be 2
        }
        It 'kernel:C03' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ResultFile 'wrong-file.xml'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 2
        }
        It 'kernel:C04' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ResolutionStatus 'missing' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'install_once_then_rerun' -PesterInvoked:$false -ResultFile 'test-results-bridge-foundation.xml' -ErrorCode 'pester_5_7_1_missing' -ModulePresent:$false
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.install_count | Should -Be 1
            $r.runner_calls | Should -Be 2
        }
        It 'kernel:C05' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ResolutionStatus 'missing' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'install_once_then_rerun' -PesterInvoked:$false -ResultFile 'test-results-bridge-foundation.xml' -ErrorCode 'pester_5_7_1_missing' -ModulePresent:$false
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json -InstallThrow:$true
            $r.exit_code | Should -Be 2
        }
        It 'kernel:C06' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ResolutionStatus 'missing' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'install_once_then_rerun' -PesterInvoked:$false -ResultFile 'test-results-bridge-foundation.xml' -ErrorCode 'pester_5_7_1_missing' -ModulePresent:$false
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json -InstallUsedInitial:$true
            $r.install_count | Should -Be 0
            $r.exit_code | Should -Be 2
        }
        It 'kernel:C07' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 0
        }
        It 'kernel:C08' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json -DeleteResultAfterFirst:$true
            $r.exit_code | Should -Be 2
        }
        It 'kernel:C09' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -TestOutcome 'failed' -FailureOrigin 'test_runtime' -WorkflowAction 'fail' -ErrorCode 'pester_tests_failed'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 1
        }
        It 'kernel:C10' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -TestOutcome 'failed' -FailureOrigin 'mixed' -WorkflowAction 'fail' -ErrorCode 'pester_tests_failed'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json -DeleteResultAfterFirst:$true
            $r.exit_code | Should -Be 2
        }
        It 'kernel:C11' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -TestOutcome 'failed' -FailureOrigin 'assertion' -WorkflowAction 'fail' -ErrorCode 'pester_result_file_missing'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 2
        }
        It 'kernel:C12' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ResolutionStatus 'ambiguous' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$false -ErrorCode 'pester_5_7_1_ambiguous' -ModulePresent:$false -ResultFile 'test-results-bridge-foundation.xml'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 2
        }
        It 'kernel:C13' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ExecutionStatus 'completed' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'fail' -PesterInvoked:$true -ErrorCode 'pester_result_invalid' -ResultFile 'test-results-bridge-foundation.xml'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 2
        }
    }

    Context 'full-adapter fixtures' {
        It 'Matrix:C07' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation'
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 0
            $r.desktop_cleanup | Should -BeFalse
            $r.exit_codes | Should -Be @([int]0)
        }
        It 'Matrix:C00' {
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout 'x' -RunnerThrow:$true
            $r.exit_code | Should -Be 2
            $r.install_count | Should -Be 0
        }
        It 'Matrix:C05' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'bridge-foundation' -ResolutionStatus 'missing' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'install_once_then_rerun' -PesterInvoked:$false -ResultFile 'test-results-bridge-foundation.xml' -ErrorCode 'pester_5_7_1_missing' -ModulePresent:$false
            $r = Invoke-Task810ActualScalar -Adapter Matrix -ShardId 'bridge-foundation' -StaticResultFile 'test-results-bridge-foundation.xml' -RunnerStdout $json -InstallThrow:$true
            $r.exit_code | Should -Be 2
            $r.install_count | Should -Be 1
        }
        It 'Desktop:C07' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'desktop-debug-process' -ResultFile 'test-results-desktop-debug-v03630.xml'
            $r = Invoke-Task810ActualScalar -Adapter Desktop -ShardId 'desktop-debug-process' -StaticResultFile 'test-results-desktop-debug-v03630.xml' -RunnerStdout $json
            $r.exit_code | Should -Be 0
            $r.desktop_cleanup | Should -BeTrue
            $r.exit_codes[-1] | Should -Be 0
        }
        It 'Desktop:C00' {
            $r = Invoke-Task810ActualScalar -Adapter Desktop -ShardId 'desktop-debug-process' -StaticResultFile 'test-results-desktop-debug-v03630.xml' -RunnerStdout '{}' -RunnerThrow:$true
            $r.exit_code | Should -Be 2
            $r.desktop_cleanup | Should -BeTrue
        }
        It 'Desktop:C05' {
            $json = New-Task810CanonicalEnvelopeJson -ShardId 'desktop-debug-process' -ResultFile 'test-results-desktop-debug-v03630.xml' -ResolutionStatus 'missing' -ExecutionStatus 'not_started' -TestOutcome 'not_run' -FailureOrigin 'none' -WorkflowAction 'install_once_then_rerun' -PesterInvoked:$false -ErrorCode 'pester_5_7_1_missing' -ModulePresent:$false
            $r = Invoke-Task810ActualScalar -Adapter Desktop -ShardId 'desktop-debug-process' -StaticResultFile 'test-results-desktop-debug-v03630.xml' -RunnerStdout $json -InstallThrow:$true
            $r.exit_code | Should -Be 2
            $r.desktop_cleanup | Should -BeTrue
            $r.install_count | Should -Be 1
        }
    }
}
