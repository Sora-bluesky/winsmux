# Execute the actual frozen transaction body with one FileStream fault boundary.
param([Parameter(Mandatory)][string]$ProducerSource, [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$text = [IO.File]::ReadAllText($ProducerSource)
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Producer parse error' }
$definitions = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $false) |
    Where-Object Name -In @('Assert-PlainPath','Read-Generation','Assert-Generation','Publish-Generation'))
if ($definitions.Count -ne 4) { throw 'Transaction function inventory changed' }
$body = ($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
$boundary = '$marker = [IO.File]::Open($Barrier, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)'
if ([regex]::Matches($body, [regex]::Escape($boundary)).Count -ne 1) { throw 'FileStream boundary changed' }
$instrumented = $body.Replace($boundary, '$marker = New-FaultStream $Barrier')
. ([scriptblock]::Create($instrumented))
function New-FaultStream([string]$Path) {
    if ($script:FaultMode -eq 'create') { throw 'Controlled barrier creation failure' }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $wrapper = [pscustomobject]@{ Inner = $stream; Mode = $script:FaultMode }
    $wrapper | Add-Member -MemberType ScriptMethod -Name Write -Value {
        param([byte[]]$Bytes)
        if ($this.Mode -eq 'write') { throw 'Controlled barrier write failure' }
        $this.Inner.Write($Bytes)
    }
    $wrapper | Add-Member -MemberType ScriptMethod -Name Flush -Value {
        param([bool]$ToDisk)
        if ($this.Mode -eq 'flush') { throw 'Controlled barrier flush failure' }
        $this.Inner.Flush($ToDisk)
    }
    $wrapper | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Inner.Dispose() }
    return $wrapper
}
$results = @()
foreach ($mode in @('create','write','flush')) {
    $script:FaultMode = $mode
    $root = [IO.Path]::GetFullPath((Join-Path $OutputDirectory $mode))
    $canonical = Join-Path $root 'binaries'; $stage = Join-Path $root 'binaries.stage.test'
    $backup = Join-Path $root 'binaries.backup.test'; $marker = Join-Path $root 'binaries.recovery.pending'
    [void][IO.Directory]::CreateDirectory($canonical); [void][IO.Directory]::CreateDirectory($stage)
    [IO.File]::WriteAllText((Join-Path $canonical 'prior.txt'), 'original')
    [IO.File]::WriteAllText((Join-Path $stage 'next.txt'), 'new')
    $original = Read-Generation $canonical
    $failed = $false
    try { Publish-Generation $canonical $stage $backup $marker }
    catch { $failed = $true; if (-not $_.Exception.Message.Contains('Controlled barrier')) { throw } }
    if (-not $failed) { throw "Expected $mode failure" }
    Assert-Generation $canonical $original
    if ([IO.Directory]::Exists($backup)) { throw 'Canonical mutated before barrier succeeded' }
    if ([IO.File]::Exists($marker) -ne ($mode -ne 'create')) { throw 'Incorrect barrier state after failure' }
    $results += @{ name="barrier-$mode"; passed=$true; original_unchanged=$true; marker_retained=($mode -ne 'create') }
}
@{schema='companion-barrier-fault-proof/v1';passed=$true;source_sha256=(Get-FileHash -LiteralPath $ProducerSource).Hash.ToLowerInvariant();instrumentation='Only FileStream construction is replaced by a delegating wrapper; actual production transition body and private filesystem execute.';results=$results} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'result.json') -Encoding utf8NoBOM
