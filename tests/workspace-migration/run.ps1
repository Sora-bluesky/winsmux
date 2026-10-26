param([string]$OutputDirectory='', [switch]$SelfTestMutation)
. (Join-Path $PSScriptRoot '../workspace-privacy/gates.ps1')
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (!$OutputDirectory) { $OutputDirectory = Join-Path $repo ('.evidence/workspace-migration/'+[guid]::NewGuid().ToString('N')) }
$gateOutput = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($gateOutput)
$gateResults = [Collections.Generic.List[object]]::new()
$cargo = (Get-Command cargo -CommandType Application | Select-Object -First 1).Source
$savedNegative=$env:WINSMUX_MIGRATION_NEGATIVE
Push-Location $repo
try {
    if ($SelfTestMutation) { $env:WINSMUX_MIGRATION_NEGATIVE='1' } else { Remove-Item Env:WINSMUX_MIGRATION_NEGATIVE -ErrorAction SilentlyContinue }
    Invoke-RecordedGate -Name golden-preservation -File $cargo -Cargo -Arguments @('test','--offline','--manifest-path','tests/workspace-privacy/Cargo.toml','--test','migration_golden','--','--nocapture')
    if (!$SelfTestMutation) {
        Invoke-RecordedGate -Name layout-preservation -File $cargo -Cargo -Arguments @('test','--offline','-p','winsmux-workspace','--test','layout_restore')
    }
    $ok = Complete-Gates -Schema 'winsmux-workspace-migration-gates/v1' -Mode $(if($SelfTestMutation){'negative_control'}else{'automated_non_pty'}) -Separate @('RM-G21: legacy v0.36.38 process and GUI journeys')
} finally {
    $env:WINSMUX_MIGRATION_NEGATIVE=$savedNegative
    Pop-Location
}
if (!$ok) { exit 1 }
